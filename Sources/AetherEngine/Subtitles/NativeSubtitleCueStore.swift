// Sources/AetherEngine/Subtitles/NativeSubtitleCueStore.swift
import Foundation

/// A native mov_text subtitle track exposed to hosts after load (#55). `ordinal` is the 0-based index into the muxer's text tracks and matches the `group.options` position in the AVPlayer legible group. `language` is the ISO 639 tag (nil when absent); `displayName` is the locale display name of `language`, or "Subtitle <n>" fallback.
public struct NativeSubtitleTrack: Sendable, Equatable {
    public let ordinal: Int
    public let language: String?
    public let displayName: String

    /// Count of tracks in `tracks[0..<ordinal]` sharing `tracks[ordinal]`'s language; used by `setNativeSubtitleSelected` to disambiguate same-language AVMediaSelectionOptions (e.g. eng "Full" vs eng "SDH"). Returns 0 when out of range or no language.
    public static func sameLanguageRank(of ordinal: Int, in tracks: [NativeSubtitleTrack]) -> Int {
        guard ordinal < tracks.count, let lang = tracks[ordinal].language else { return 0 }
        return tracks[0..<ordinal].filter { $0.language == lang }.count
    }
}

/// Sole owner of the decoded-cue array backing the native mov_text track (#55). Text `SubtitleCue`s only, never packet data, so footprint is bounded by cue count (leak guard). Producer drains `cuesInWindow` per segment cut to build mov_text samples on the AVPlayer axis.
final class NativeSubtitleCueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [SubtitleCue] = []
    private var shiftSeconds: Double = 0
    private var finished = false
    /// Sodalite#32: the pump tap and a side reader can feed the same store concurrently (and a producer
    /// restart re-reads a region), so appends dedup on (start, end, text) instead of trusting the source.
    private var seenKeys: Set<String> = []
    /// Highest cue end appended (source axis). `cues.last` stopped being the read head once two feeders
    /// with different positions share the store.
    private var maxCueEndSeconds: Double = 0

    init() {}

    private static func key(start: Double, end: Double, text: String) -> String {
        "\(Int((start * 1000).rounded()))|\(Int((end * 1000).rounded()))|\(text)"
    }

    func setShiftSeconds(_ s: Double) { lock.lock(); shiftSeconds = s; lock.unlock() }

    /// Set once the reader has read the track to EOF, so a whole-program .vtt consumer knows every cue is present (Sodalite#32).
    func markFinished() { lock.lock(); finished = true; lock.unlock() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func replaceCues(_ newCues: [SubtitleCue]) {
        lock.lock(); defer { lock.unlock() }
        cues.removeAll(keepingCapacity: true)
        seenKeys.removeAll(keepingCapacity: true)
        maxCueEndSeconds = 0
        appendLocked(newCues)
    }

    func appendCues(_ extra: [SubtitleCue]) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(extra)
    }

    private func appendLocked(_ extra: [SubtitleCue]) {
        for c in extra {
            guard case .text(let t) = c.body else { continue }
            guard seenKeys.insert(Self.key(start: c.startTime, end: c.endTime, text: t)).inserted else { continue }
            cues.append(c)
            if c.endTime > maxCueEndSeconds { maxCueEndSeconds = c.endTime }
        }
    }

    func clear() {
        lock.lock()
        cues.removeAll(keepingCapacity: false)
        seenKeys.removeAll(keepingCapacity: false)
        maxCueEndSeconds = 0
        finished = false
        lock.unlock()
    }

    var cueCount: Int { lock.lock(); defer { lock.unlock() }; return cues.count }

    /// Snapshot of all text cues sorted by start, source axis (the overlay backfill on selection,
    /// Sodalite#32 Phase 2: the tap has already harvested the produced region when the user enables
    /// subtitles, so the overlay starts fully populated instead of waiting on a side demuxer).
    func snapshotCues() -> [SubtitleCue] {
        lock.lock(); defer { lock.unlock() }
        return cues.sorted { $0.startTime < $1.startTime }
    }

    /// Cues overlapping `[start, end)` in AVPlayer-axis seconds, text only,
    /// sorted by start.
    func cuesInWindow(start: Double, end: Double) -> [(start: Double, end: Double, text: String)] {
        lock.lock()
        let snapshot = cues
        let shift = shiftSeconds
        lock.unlock()
        var out: [(start: Double, end: Double, text: String)] = []
        for c in snapshot {
            guard case .text(let t) = c.body else { continue }
            let s = c.startTime - shift
            let e = c.endTime - shift
            if e > start && s < end { out.append((max(0, s), max(0, e), t)) }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// All text cues, shift-applied, sorted by start (whole-program VOD .vtt source). #15.
    func allCues() -> [(start: Double, end: Double, text: String)] {
        cuesInWindow(start: 0, end: .greatestFiniteMagnitude)
    }

    /// Highest cue end seen (shift-applied AVPlayer seconds), or 0 if empty. Marks how far ANY feeder
    /// (pump tap or side reader) has covered; the .vtt handler waits on this so AVPlayer gets cues
    /// instead of an empty segment when it fetches ahead of the coverage (#15).
    func readMaxCueEnd() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard !cues.isEmpty else { return 0 }
        return maxCueEndSeconds - shiftSeconds
    }
}
