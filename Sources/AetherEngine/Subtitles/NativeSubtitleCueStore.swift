// Sources/AetherEngine/Subtitles/NativeSubtitleCueStore.swift
import Foundation

/// Sole owner of the bounded decoded-cue array backing the native
/// mov_text subtitle track (#55). Holds only text `SubtitleCue`s, never
/// packet data, so its footprint is bounded by cue count (leak guard).
/// The producer drains `cuesInWindow` per segment cut to build mov_text
/// samples on the AVPlayer axis.
final class NativeSubtitleCueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [SubtitleCue] = []
    private var shiftSeconds: Double = 0

    init() {}

    func setShiftSeconds(_ s: Double) { lock.lock(); shiftSeconds = s; lock.unlock() }

    func replaceCues(_ newCues: [SubtitleCue]) {
        lock.lock(); defer { lock.unlock() }
        cues = newCues.filter { if case .text = $0.body { return true } else { return false } }
    }

    func appendCues(_ extra: [SubtitleCue]) {
        lock.lock(); defer { lock.unlock() }
        for c in extra { if case .text = c.body { cues.append(c) } }
    }

    func clear() { lock.lock(); cues.removeAll(keepingCapacity: false); lock.unlock() }

    var cueCount: Int { lock.lock(); defer { lock.unlock() }; return cues.count }

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
}
