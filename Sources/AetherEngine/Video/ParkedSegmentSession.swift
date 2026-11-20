import Darwin
import Foundation

/// AE#1095: the segment cache of the last native session a host stopped with
/// `LoadOptions.retainsSessionCacheAfterStop`, kept on disk for the next `load()` of the same source.
///
/// One per process at most (`ParkedSegmentSessionStore`). It lives in its own directory beside the
/// sessions' (`aether-segments/<uuid>`) and holds that directory's live marker, so a sibling's stale
/// sweep leaves it alone while the process runs and takes it an hour after a crash or a kill.
///
/// The bytes alone do not describe the segments. Where AVPlayer places each one depends on the epoch
/// that cut it (`EpochAxisTable`, AE#418), and the provider reads each one's cold-arrival reach
/// (AE#412) and the folds the producer passed over (#358). All of it travels with the files.
final class ParkedSegmentSession: @unchecked Sendable {

    /// Everything a new session has to share with the parked one before its segments are its own.
    /// The segment plan is compared separately, because it only exists once the new session has
    /// read the source's index.
    struct Key: Equatable, Sendable {
        let url: URL
        /// The host's load options, without the fields that only label a load.
        let options: LoadOptions
        /// What the engine derived for the session on top of the options (display, audio stream, ...).
        let output: HLSVideoEngine.ParkingOutputConfiguration

        /// The first component that differs, for the log line that explains a discard.
        func firstDifference(from other: Key) -> String? {
            if url != other.url { return "source URL" }
            if options != other.options { return "load options" }
            if output != other.output { return "session output configuration" }
            return nil
        }
    }

    let key: Key
    let plan: [HLSVideoEngine.Segment]
    let segments: SegmentCache.ParkedSegments
    let epochAxis: EpochAxisTable
    let playlistShiftSeconds: Double
    /// What the parked session's readers harvested of the embedded subtitles. The adopting pump
    /// starts past the parked segments and never reads that span, so without it every embedded cue
    /// there was missing (measured: none between the resume point and the pump's start). In RAM
    /// while parked; text tracks are kilobytes, bitmap tracks stay under the store's own caps.
    let subtitles: SubtitlePacketStore
    /// Set when the parked session's cue prewarm ran into its cap and its plan fell back to the
    /// uniform stride. The next load of the same file skips that prewarm, because it would end the
    /// same way: on a remote MKV without Cues it cost the whole 10 s cap before every Resume.
    let unindexedSource: UnindexedSource?

    /// The file a capped prewarm was measured on. A different size or duration under the same URL is
    /// a different file, and that load runs its prewarm again.
    struct UnindexedSource: Equatable, Sendable {
        let byteSize: Int64
        let durationSeconds: Double

        func describes(byteSize: Int64?, durationSeconds: Double) -> Bool {
            byteSize == self.byteSize && durationSeconds == self.durationSeconds
        }
    }

    private let lock = NSLock()
    private var markerFD: Int32
    private var released = false

    init(key: Key, plan: [HLSVideoEngine.Segment], segments: SegmentCache.ParkedSegments,
         epochAxis: EpochAxisTable, playlistShiftSeconds: Double, subtitles: SubtitlePacketStore,
         unindexedSource: UnindexedSource? = nil, markerFD: Int32) {
        self.key = key
        self.plan = plan
        self.segments = segments
        self.epochAxis = epochAxis
        self.playlistShiftSeconds = playlistShiftSeconds
        self.subtitles = subtitles
        self.unindexedSource = unindexedSource
        self.markerFD = markerFD
    }

    deinit { release(removingDirectory: true, reason: nil) }

    var directory: URL { segments.directory }
    var totalBytes: Int { segments.totalBytes }

    /// A fresh directory for a parked session, created with its live marker already held, so no
    /// sweep can read it as a crash remnant between creation and the first file moved in.
    static func makeDirectory(besides sessionDir: URL) -> (url: URL, markerFD: Int32)? {
        let url = sessionDir.deletingLastPathComponent()
            .appendingPathComponent("parked-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            EngineLog.emit("[SegmentCache] parked directory create failed at \(url.path): \(error)",
                           category: .session)
            return nil
        }
        let fd = SessionDirectoryLiveness.acquire(sessionDir: url, logPrefix: "[SegmentCache]")
        return (url, fd)
    }

    /// Deletes the parked files and lets go of the marker. Idempotent.
    func discard(reason: String) {
        release(removingDirectory: true, reason: reason)
    }

    /// The adopting session moved what it wanted; the rest goes with the directory.
    func finishAdoption(segments: Int, bytes: Int, frontier: Int) {
        release(removingDirectory: true, reason: nil)
        EngineLog.emit(
            "[SegmentCache] adopted \(segments) parked segment(s), \(bytes / (1 << 20)) MiB; "
            + "the producer starts at idx=\(frontier) (AE#1095)",
            category: .session)
    }

    private func release(removingDirectory: Bool, reason: String?) {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        let fd = markerFD
        markerFD = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        if removingDirectory { try? FileManager.default.removeItem(at: segments.directory) }
        if let reason {
            EngineLog.emit(
                "[SegmentCache] discarded the parked session (\(segments.files.count) segment(s), "
                + "\(segments.totalBytes / (1 << 20)) MiB): \(reason) (AE#1095)",
                category: .session)
        }
    }
}

/// AE#1095: the process-wide slot for the one parked session.
final class ParkedSegmentSessionStore: @unchecked Sendable {
    static let shared = ParkedSegmentSessionStore()

    private let lock = NSLock()
    private var parked: ParkedSegmentSession?
    private var exitHookInstalled = false
    /// Moves at every look into the slot: a session start, a load, a host discard.
    private var looks: UInt64 = 0

    /// What a stop reads before its detached cleanup, so the park can tell whether anyone looked
    /// for a parked session in between.
    var lookCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return looks
    }

    /// A newer park replaces an older one: one parked session at most. A park whose stop was followed
    /// by a look into the slot (a `stop()` and an immediate `load()`) is dropped instead: the session
    /// that looked found nothing and will never look again, so the files would only hold disk.
    func park(_ session: ParkedSegmentSession, ifNoLookSince stopLook: UInt64) {
        lock.lock()
        guard looks == stopLook else {
            lock.unlock()
            session.discard(reason: "a session started before the stop finished parking")
            return
        }
        let previous = parked
        parked = session
        let installHook = !exitHookInstalled
        exitHookInstalled = true
        lock.unlock()
        if installHook {
            // A normal exit (macOS quit, `aetherctl`) deletes the files now; a kill leaves them to
            // the stale sweep, which takes an unmarked directory after an hour.
            atexit { ParkedSegmentSessionStore.shared.discard(reason: "the process is exiting") }
        }
        previous?.discard(reason: "replaced by a newer stop")
        EngineLog.emit(
            "[SegmentCache] parked \(session.segments.files.count) segment(s), "
            + "\(session.totalBytes / (1 << 20)) MiB, for the next load of the same source (AE#1095)",
            category: .session)
    }

    /// Hands the parked session to a load whose key matches, and discards it otherwise: a load of
    /// anything else ends the parking.
    func take(matching key: ParkedSegmentSession.Key) -> ParkedSegmentSession? {
        lock.lock()
        looks &+= 1
        let candidate = parked
        parked = nil
        lock.unlock()
        guard let candidate else { return nil }
        if let difference = candidate.key.firstDifference(from: key) {
            candidate.discard(reason: "the next load differs in its \(difference)")
            return nil
        }
        return candidate
    }

    /// For a load that will not look for a parked session at all (another route, the option off):
    /// keeps nothing but a session parked for exactly `url`, which a later load may still want.
    func discard(unlessParkedFor url: URL?, reason: String) {
        lock.lock()
        looks &+= 1
        guard let candidate = parked, candidate.key.url != url else { lock.unlock(); return }
        parked = nil
        lock.unlock()
        candidate.discard(reason: reason)
    }

    func discard(reason: String) {
        lock.lock()
        looks &+= 1
        let candidate = parked
        parked = nil
        lock.unlock()
        candidate?.discard(reason: reason)
    }

    var parkedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return parked?.totalBytes ?? 0
    }
}
