import Foundation

/// #316: serves the sidecar renditions the remote-HLS subtitle proxy injects into the origin master.
///
/// It is an `HLSSegmentProvider` that owns no media at all. The A/V variants in the rewritten master
/// point straight at the origin, so AVPlayer never asks this server for a segment; only `/master.m3u8`
/// (verbatim, via `staticMasterPlaylistBody`), `/subs_{n}.m3u8` and `/subs_{n}_0.vtt` are ever fetched.
/// The single reported segment exists so `buildSubtitleMediaPlaylistText`'s whole-program shape can read
/// the program duration off the usual `segmentDuration(at:)` path (Sodalite#32) without a special case.
final class RemoteHLSSubtitleProvider: HLSSegmentProvider, @unchecked Sendable {

    /// One declared sidecar, tied back to the engine-side external track id it was registered under.
    struct Track: Sendable {
        let externalID: Int
        let source: ExternalSubtitleTrack
    }

    let tracks: [Track]

    /// Settable because the relay can only rewrite this once the server it is mounted on has a
    /// port and a token, which is after the provider exists. Written once during build, before
    /// the server has answered anything.
    private(set) var staticMasterPlaylistBody: String?

    /// Total program seconds, summed from the origin's own variant playlist. TARGETDURATION and the
    /// single EXTINF of every subtitle rendition are built from it.
    private let programDuration: Double
    private let stores: [NativeSubtitleCueStore]
    private let defaultHeaders: [String: String]
    private let mediaURL: URL?
    /// Guards the fill queue below. The fill is started from the proxy's build (off the main actor),
    /// reordered by a pick and cancelled from the engine's teardown (both on it), so it is shared.
    private let fillLock = NSLock()
    /// AE#984 R2: fills not started yet, in the order they run. One job runs at a time: each is an
    /// extraction from the file the server may be transcoding at the same moment.
    private var queuedJobs: [AetherEngine.ExternalSubtitleFillJob] = []
    private var running: (job: AetherEngine.ExternalSubtitleFillJob, task: Task<Void, Never>, id: UInt64)?
    private var nextRunID: UInt64 = 0
    /// AE#984 R2: the rendition the host picked last. Its job runs before any other and takes over
    /// from a running job that does not serve it.
    private var pickedOrdinal: Int?
    /// AE#984 R2: while set, only the picked rendition's job runs. The engine lifts it once the item
    /// is ready to play, so the other extractions do not compete with the transcode's spin-up.
    private var holdsUnpickedFills = false
    private var fillCancelled = false

    init(tracks: [Track], masterBody: String, programDuration: Double,
         defaultHeaders: [String: String], mediaURL: URL?) {
        self.tracks = tracks
        self.staticMasterPlaylistBody = masterBody
        // `RemoteHLSSubtitleProxy.sumSegmentDurations` already refuses a non-finite, negative or
        // absurd EXTINF sum before it reaches here; this is the last stop before the value leaves
        // the provider (`segmentDuration(at:)`) for `wholeSecondsCovering`'s `Int(Double)`, which
        // traps on `+inf` (audit NAT-1). Bounded again here so a caller that builds this provider
        // directly, bypassing the proxy, cannot reintroduce the trap.
        let finiteDuration = programDuration.isFinite ? programDuration : 1
        self.programDuration = min(max(1, finiteDuration), RemoteHLSSubtitleProxy.maxProgramDurationSeconds)
        self.defaultHeaders = defaultHeaders
        self.mediaURL = mediaURL
        self.stores = tracks.map { _ in NativeSubtitleCueStore() }
    }

    /// Replaces the served master. Only the relay calls this, to send the origin's variants back
    /// through the engine once the server's address is known.
    func setMasterPlaylistBody(_ body: String) {
        staticMasterPlaylistBody = body
    }

    /// The renditions as the rewriter needs to declare them, in `subs_{ordinal}` order.
    static func renditions(for tracks: [Track]) -> [RemoteHLSMasterRewrite.Rendition] {
        tracks.enumerated().map { ordinal, track in
            RemoteHLSMasterRewrite.Rendition(
                ordinal: ordinal,
                name: track.source.makeTrackInfo(id: track.externalID, fallbackNumber: ordinal + 1).name,
                language: track.source.language,
                isForced: track.source.isForced,
                isSDH: track.source.isHearingImpaired)
        }
    }

    /// Decode every sidecar into its store, off the main actor. Same one-pass-per-container machinery
    /// the loopback path uses (#266), so a container holding several subtitle streams is read once and
    /// a single bad stream index cannot blank its siblings.
    ///
    /// AE#984 R2: with `holdingUnpicked` nothing runs until the host picks a rendition
    /// (`prioritizeFill`) or the engine lifts the hold (`releaseHeldFills`). Every store is marked
    /// pending at once either way, so a `.vtt` request that comes first is answered "not yet".
    func startFill(holdingUnpicked: Bool = false) {
        cancelFill()
        let jobs = Self.fillJobs(tracks: tracks, stores: stores, defaultHeaders: defaultHeaders, mediaURL: mediaURL)
        guard !jobs.isEmpty else { return }
        jobs.forEach { $0.markPending() }
        fillLock.lock()
        fillCancelled = false
        queuedJobs = jobs
        pickedOrdinal = nil
        holdsUnpickedFills = holdingUnpicked
        fillLock.unlock()
        runNextFill()
    }

    func cancelFill() {
        fillLock.lock()
        fillCancelled = true
        queuedJobs = []
        let task = running?.task
        running = nil
        fillLock.unlock()
        task?.cancel()
    }

    /// AE#984 R2: the host picked `ordinal`. Its fill moves to the front, takes over from a running
    /// fill that serves only other renditions (that one goes back in the queue), and a fill that
    /// failed earlier (a 120 s idle timeout on a server still extracting) is tried once more.
    func prioritizeFill(ordinal: Int) {
        guard ordinal >= 0, ordinal < stores.count else { return }
        let store = stores[ordinal]
        var preempted: Task<Void, Never>?
        fillLock.lock()
        guard !fillCancelled else { fillLock.unlock(); return }
        pickedOrdinal = ordinal
        if let index = queuedJobs.firstIndex(where: { Self.job($0, serves: store) }) {
            queuedJobs.insert(queuedJobs.remove(at: index), at: 0)
        } else if store.externalFillState == .failed,
                  running.map({ !Self.job($0.job, serves: store) }) ?? true,
                  let retry = retryJob(for: ordinal) {
            retry.markPending()
            queuedJobs.insert(retry, at: 0)
            EngineLog.emit("[AetherEngine] AE#984: subtitle rendition ord=\(ordinal) was picked after its "
                           + "sidecar failed; fetching it once more", category: .hlsServer)
        }
        if let current = running, !Self.job(current.job, serves: store),
           queuedJobs.first.map({ Self.job($0, serves: store) }) == true {
            preempted = current.task
            queuedJobs.append(current.job)
            running = nil
        }
        fillLock.unlock()
        preempted?.cancel()
        runNextFill()
    }

    /// AE#984 R2: the item is ready to play; the renditions nobody picked may fill now.
    func releaseHeldFills() {
        fillLock.lock()
        let wasHeld = holdsUnpickedFills
        holdsUnpickedFills = false
        fillLock.unlock()
        if wasHeld { runNextFill() }
    }

    /// AE#984 R2: the ordinal of the rendition registered under the host's external track id.
    func ordinal(forExternalID id: Int) -> Int? {
        tracks.firstIndex { $0.externalID == id }
    }

    /// AE#984 R2: what a `.vtt` request for this rendition would get right now.
    func renditionServe(ordinal: Int) -> NativeSubtitleCueStore.WholeProgramServe? {
        guard ordinal >= 0, ordinal < stores.count else { return nil }
        return stores[ordinal].wholeProgramServe
    }

    /// Wait for every fill that can run to finish. Nothing in the session waits for it, the `.vtt`
    /// handler reads the store's state instead; this exists so a test can assert on a finished store
    /// without racing the wall clock (a saturated cooperative pool can leave the detached decode without
    /// a thread for a long time). Fills held for a pick or for readiness are not waited for.
    func awaitFill() async {
        while let task = currentFillTask() {
            await task.value
        }
    }

    private static func job(_ job: AetherEngine.ExternalSubtitleFillJob, serves store: NativeSubtitleCueStore) -> Bool {
        job.targets.contains { $0.store === store }
    }

    /// The failed renditions that share the picked one's source, as one job, so a container is still
    /// read once. Called under `fillLock`.
    private func retryJob(for ordinal: Int) -> AetherEngine.ExternalSubtitleFillJob? {
        let url = tracks[ordinal].source.url
        let picked = tracks.indices.filter {
            tracks[$0].source.url == url && stores[$0].externalFillState == .failed
        }
        let jobs = Self.fillJobs(tracks: picked.map { tracks[$0] }, stores: picked.map { stores[$0] },
                                 defaultHeaders: defaultHeaders, mediaURL: mediaURL)
        return jobs.first { Self.job($0, serves: stores[ordinal]) }
    }

    /// Starts the next job the queue allows, unless one is running. A job whose every store finished
    /// meanwhile (a preempted decode that completed anyway) is dropped instead of fetched again.
    private func runNextFill() {
        fillLock.lock()
        defer { fillLock.unlock() }
        guard !fillCancelled, running == nil else { return }
        queuedJobs.removeAll { $0.targets.allSatisfy { $0.store.isFinished } }
        let pickedStore = pickedOrdinal.map { stores[$0] }
        let index = pickedStore.flatMap { store in queuedJobs.firstIndex { Self.job($0, serves: store) } }
            ?? (holdsUnpickedFills || queuedJobs.isEmpty ? nil : 0)
        guard let index else { return }
        let job = queuedJobs.remove(at: index)
        nextRunID &+= 1
        let id = nextRunID
        // Assigned under the same lock hold, so `fillEnded` can never see the run before it exists.
        let task = BlockingWork.detached(priority: .utility) { [weak self] in
            await AetherEngine.runExternalSubtitleFill(job: job)
            self?.fillEnded(id: id)
        }
        running = (job: job, task: task, id: id)
    }

    private func fillEnded(id: UInt64) {
        fillLock.lock()
        if running?.id == id { running = nil }
        fillLock.unlock()
        runNextFill()
    }

    /// AE#616: every sidecar's decode has finished, so `allCueStarts()` is the whole program.
    var isFillFinished: Bool { stores.allSatisfy(\.isFinished) }

    /// AE#616: cue starts and texts across every injected rendition, on the axis the `.vtt` serves.
    func allCueStarts() -> [(start: Double, text: String)] {
        stores.flatMap { $0.allCues().map { (start: $0.start, text: $0.text) } }
    }

    /// Reading the handle stays synchronous: `NSLock` is unavailable from an async context.
    private func currentFillTask() -> Task<Void, Never>? {
        fillLock.lock()
        defer { fillLock.unlock() }
        return running?.task
    }

    /// One job per (url, headers) pair, in first-appearance order. Mirrors
    /// `AetherEngine.externalSubtitleFillJobs`, which keys off the loopback's rendition table.
    static func fillJobs(tracks: [Track],
                         stores: [NativeSubtitleCueStore],
                         defaultHeaders: [String: String], mediaURL: URL?) -> [AetherEngine.ExternalSubtitleFillJob] {
        struct Key: Hashable {
            let url: URL
            let headers: [String: String]
        }
        var order: [Key] = []
        var targetsByKey: [Key: [AetherEngine.ExternalSubtitleFillJob.Target]] = [:]
        var hintByKey: [Key: String] = [:]
        for (ordinal, track) in tracks.enumerated() where ordinal < stores.count {
            let key = Key(url: track.source.url, headers: AetherEngine.resolvedSubtitleHeaders(
                for: track.source.url, explicit: track.source.httpHeaders, mediaURL: mediaURL,
                mediaHeaders: defaultHeaders))
            if targetsByKey[key] == nil { order.append(key) }
            targetsByKey[key, default: []].append(
                .init(streamIndex: track.source.sourceStreamIndex, store: stores[ordinal]))
            if hintByKey[key] == nil, let hint = track.source.formatHint { hintByKey[key] = hint }
        }
        return order.map {
            AetherEngine.ExternalSubtitleFillJob(url: $0.url, headers: $0.headers,
                                                 targets: targetsByKey[$0] ?? [],
                                                 formatHint: hintByKey[$0])
        }
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? { nil }
    func mediaSegment(at index: Int) -> Data? { nil }

    /// This provider owns no media, and says so: a `/seg{N}.mp4` that reaches this origin is answered 404
    /// rather than "not yet, retry", because it never will exist. The served master's only variants are
    /// the origin's own.
    var segmentCount: Int { 0 }

    /// The subtitle playlist builder derives the whole-program TARGETDURATION and EXTINF from one visible
    /// segment (Sodalite#32). Reporting it here, instead of through `segmentCount`, keeps the duration
    /// math working without also claiming a media segment exists.
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int,
                                 endlistAdded: Bool, discontinuitySequence: Int) {
        (visibleCount: 1, firstVisible: 0, refreshCounter: 0, endlistAdded: true, discontinuitySequence: 0)
    }

    func segmentDuration(at index: Int) -> Double { programDuration }
    var playlistType: HLSPlaylistType { .vod }
    var nativeSubtitleWholeProgram: Bool { true }

    /// Empty on purpose: `nativeSubtitleRenditions` only feeds the master BUILDER, and this provider
    /// serves a finished master instead. The EXT-X-MEDIA tags were written by `RemoteHLSMasterRewrite`.
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] { [] }

    /// Whole-program WebVTT for one sidecar. Cue times are used verbatim: this bypass has no loopback
    /// producer and therefore no playlist shift, and AVPlayer places the cues by media timestamp, so
    /// the sidecar's own absolute seconds line up with the frames. They do NOT line up with item time
    /// where an origin's segments start before their playlist slot; AE#616 measures that gap off them.
    ///
    /// AE#984: never held. A request held for the fill also held AVPlayer's media loading, so a slow
    /// sidecar froze the picture of a healthy stream. While the fill runs the answer is a 404, which
    /// AVPlayer retries every few seconds while A/V keeps loading; a failed fill is served empty at once.
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> String? {
        guard ordinal >= 0, ordinal < stores.count else { return nil }
        let store = stores[ordinal]
        let serve = store.wholeProgramServe
        if serve == .retryLater {
            EngineLog.emit(
                "[AetherEngine] AE#984: subtitle rendition ord=\(ordinal) requested before its sidecar is "
                + "decoded; answering 404 so AVPlayer asks again", category: .hlsServer)
            return nil
        }
        let cues = store.allCues()
        if serve != .complete {
            let why = serve == .failedFill ? "could not be read" : "has no decode running"
            EngineLog.emit(
                "[AetherEngine] AE#984: the sidecar for subtitle rendition ord=\(ordinal) \(why); "
                + "serving it as it stands so the A/V session is not held for it", category: .hlsServer)
        } else {
            EngineLog.emit(
                "[AetherEngine] #316: whole-program rendition ord=\(ordinal) cues=\(cues.count)",
                category: .hlsServer, level: .verbose)
        }
        return WebVTTBuilder.body(cues: cues)
    }
}
