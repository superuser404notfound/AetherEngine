import Foundation
import AVFAudio

/// One decoded tap buffer (#95). Handed to exactly one consumer via `AsyncStream`; the engine
/// never touches `buffer` after yielding it, which is the invariant behind `@unchecked Sendable`.
public struct AudioTapBuffer: @unchecked Sendable {
    /// Mono Float32 48 kHz PCM (see `AetherEngine.audioTapFormat`).
    public let buffer: AVAudioPCMBuffer
    /// Source-PTS seconds of the first sample, same axis as `AetherEngine.sourceTime`.
    public let sourceTime: Double
    /// True when this buffer does not abut the previous one (seek, gap, drop, track switch).
    /// Non-discontinuity buffers are guaranteed strictly increasing and non-overlapping on
    /// `sourceTime` (AudioTapMonotonicFilter trims sub-`overlapTrimThreshold` seam overlaps),
    /// which SpeechAnalyzer's input timeline requires.
    public let discontinuity: Bool
}

public extension AetherEngine {
    /// The fixed output format of the audio tap. Computed per call because `AVAudioFormat`
    /// is not Sendable and cannot be a stored static under strict concurrency.
    nonisolated static var audioTapFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    }
}

enum AudioTapDefaults {
    static let leadSeconds: Double = 10
    static let toleranceSeconds: Double = 2
    static let minSamplesPerChunk = 4800   // 100 ms at 48 kHz
    static let sampleRate: Double = 48_000
    /// Max backward PTS overlap (seconds) the monotonic gate trims silently. Segment-seam
    /// decoder priming is tens of ms; a larger backward jump is a real seek and is passed
    /// through as a discontinuity instead.
    static let overlapTrimThreshold: Double = 0.25
    /// Tap buffers the consumer stream holds before dropping the oldest. A reader emits a whole
    /// segment in one burst (a 10 s segment is 100 buffers of 100 ms), so this holds one long
    /// segment with room to spare while the consumer drains it: 25.6 s of audio, about 4.9 MB.
    static let streamBufferChunks = 256
}

/// Pure pacing decision for the loopback reader (#95). Playlist-axis seconds on both inputs.
enum AudioTapPacing {
    enum Decision: Equatable {
        case decodeNext   // decode the segment after the last decoded one
        case sleep        // full lead decoded; idle and recheck
        case reanchor     // playhead moved away; jump to the playhead's segment
    }

    /// `lastDecodedStartPTS` is where the most recently decoded segment starts. The playhead
    /// counts as having jumped back only when that start is more than the lead (plus tolerance)
    /// ahead of it: a segment is only ever decoded while the decoded end is within the lead, so
    /// its start is within the lead too, while its end can reach a whole segment further. Judged
    /// by the end, any segment longer than the tolerance read as a backward jump the moment it
    /// was decoded, and the reader re-decoded the same two segments in a loop.
    static func decide(lastDecodedStartPTS: Double?, lastDecodedEndPTS: Double?, playhead: Double,
                       leadSeconds: Double, toleranceSeconds: Double) -> Decision {
        guard let last = lastDecodedEndPTS else { return .decodeNext }
        if last < playhead - toleranceSeconds { return .reanchor }
        if let start = lastDecodedStartPTS, start - playhead > leadSeconds + toleranceSeconds { return .reanchor }
        if last - playhead >= leadSeconds { return .sleep }
        return .decodeNext
    }
}
