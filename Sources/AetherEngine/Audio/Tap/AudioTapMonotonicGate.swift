import Foundation
import AVFAudio

/// #95 follow-up: enforces a strictly monotonic, non-overlapping `sourceTime` timeline on
/// consecutive non-`discontinuity` tap buffers. SpeechAnalyzer terminates its input loop on the
/// first overlap; segment-seam decoder priming produces sub-threshold backward overlaps that this
/// trims. Shared by all backends via `AudioTapController`.
enum AudioTapGateDecision: Equatable {
    case pass                       // emit unchanged
    case forceDiscontinuity         // large unflagged backward jump: emit with discontinuity=true, reset
    case drop                       // buffer lies entirely before lastEnd
    case trim(dropFrames: Int)      // small overlap: drop leading frames, restamp to lastEnd
}

enum AudioTapMonotonicGate {
    static func decide(sourceTime: Double, frameLength: Int, discontinuity: Bool,
                       lastEnd: Double?, sampleRate: Double,
                       overlapTrimThreshold: Double) -> AudioTapGateDecision {
        guard !discontinuity, let lastEnd else { return .pass }
        let epsilon = 0.5 / sampleRate
        if sourceTime >= lastEnd - epsilon { return .pass }
        let overlap = lastEnd - sourceTime
        if overlap > overlapTrimThreshold { return .forceDiscontinuity }
        let duration = Double(frameLength) / sampleRate
        if overlap >= duration - epsilon { return .drop }
        let dropFrames = min(frameLength, max(0, Int((overlap * sampleRate).rounded())))
        return dropFrames == 0 ? .pass : .trim(dropFrames: dropFrames)
    }
}

/// Stateful wrapper: holds `lastEnd`, applies the decision, performs the PCM trim, forwards to the
/// stream continuation. Called from a single delivery source at a time but locked for safety since
/// its `accept` is handed out as a `@Sendable` closure.
///
/// `downstream` returns false when it could not take the buffer (the stream queue was full); the
/// next buffer it does take then carries `discontinuity`, so a consumer that fell behind sees the
/// gap instead of inferring contiguous PCM across it (#864 follow-up).
final class AudioTapMonotonicFilter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEnd: Double?
    private var pendingDiscontinuity = false
    private let sampleRate = AudioTapDefaults.sampleRate
    private let threshold = AudioTapDefaults.overlapTrimThreshold
    private let downstream: @Sendable (AudioTapBuffer) -> Bool

    init(downstream: @escaping @Sendable (AudioTapBuffer) -> Bool) {
        self.downstream = downstream
    }

    func accept(_ buf: AudioTapBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let frames = Int(buf.buffer.frameLength)
        let decision = AudioTapMonotonicGate.decide(
            sourceTime: buf.sourceTime, frameLength: frames, discontinuity: buf.discontinuity,
            lastEnd: lastEnd, sampleRate: sampleRate, overlapTrimThreshold: threshold)
        switch decision {
        case .pass:
            emit(buf, sourceTime: buf.sourceTime, discontinuity: buf.discontinuity, frames: frames)
        case .forceDiscontinuity:
            emit(buf, sourceTime: buf.sourceTime, discontinuity: true, frames: frames)
        case .drop:
            break
        case .trim(let dropFrames):
            guard let trimmed = Self.trimmedBuffer(buf.buffer, dropFrames: dropFrames),
                  let anchor = lastEnd else { break }
            emit(buf.restamped(buffer: trimmed, discontinuity: false), sourceTime: anchor,
                 discontinuity: false, frames: frames - dropFrames)
        }
    }

    private func emit(_ buf: AudioTapBuffer, sourceTime: Double, discontinuity: Bool, frames: Int) {
        lastEnd = sourceTime + Double(frames) / sampleRate
        let accepted = downstream(buf.restamped(sourceTime: sourceTime,
                                                discontinuity: discontinuity || pendingDiscontinuity))
        if !accepted, !pendingDiscontinuity {
            EngineLog.emit("[AudioTap] consumer behind, stream full, dropping from \(sourceTime)s",
                           category: .engine)
        }
        pendingDiscontinuity = !accepted
    }

    /// Copy the trailing `frameLength - dropFrames` mono Float32 frames into a fresh buffer.
    static func trimmedBuffer(_ buffer: AVAudioPCMBuffer, dropFrames: Int) -> AVAudioPCMBuffer? {
        let remaining = Int(buffer.frameLength) - dropFrames
        guard remaining > 0,
              let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(remaining))
        else { return nil }
        out.frameLength = AVAudioFrameCount(remaining)
        out.floatChannelData![0].update(from: src[0] + dropFrames, count: remaining)
        return out
    }
}
