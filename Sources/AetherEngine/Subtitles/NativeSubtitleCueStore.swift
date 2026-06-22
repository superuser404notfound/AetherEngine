// Sources/AetherEngine/Subtitles/NativeSubtitleCueStore.swift
import Foundation

/// A single native mov_text subtitle track exposed to hosts after load (#55).
/// Ordinal is the 0-based index into the muxer's declared text tracks and
/// matches the `group.options` position in the AVPlayer legible group.
/// `language` is the ISO 639 tag from the source stream metadata (nil when
/// absent). `displayName` is a human-readable label suitable for a track
/// picker (the locale display name of `language`, or "Subtitle <n>" as
/// the fallback when language is nil).
public struct NativeSubtitleTrack: Sendable, Equatable {
    public let ordinal: Int
    public let language: String?
    public let displayName: String

    /// Returns how many tracks in `tracks[0..<ordinal]` share the same
    /// language as `tracks[ordinal]`. This rank is used by
    /// `setNativeSubtitleSelected` to pick the correct AVMediaSelectionOption
    /// when two tracks carry the same language tag (e.g. eng "Full" and eng "SDH").
    ///
    /// Returns 0 when `ordinal` is out of range or the track has no language.
    public static func sameLanguageRank(of ordinal: Int, in tracks: [NativeSubtitleTrack]) -> Int {
        guard ordinal < tracks.count, let lang = tracks[ordinal].language else { return 0 }
        return tracks[0..<ordinal].filter { $0.language == lang }.count
    }
}

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
