import Foundation

/// AE#1079: how far the software VOD demux loop reads ahead before its read gate holds, sized from
/// the source's own interleave.
///
/// The gate holds once decoded audio leads the clock by `AudioLookaheadPolicy.targetLeadSeconds`, or
/// once 256 video packets are parked. Both assume a source that interleaves tightly. The DASH virtual
/// MP4 interleaves whole subsegments by start time instead, so in read order audio can sit one whole
/// audio subsegment ahead of the next video, and video one whole video subsegment ahead of the next
/// audio. Measured on a 60 fps fixture: 10 s audio against 4 s video froze the picture for 3 to 5 s
/// every subsegment while the sound played on (the lead was reached before the next video piece),
/// and 10 s video against 2 s audio held the clock at 10 s (the cap filled inside one video piece).
///
/// Sized from that geometry, the gate reaches the next piece of the other track before the clock
/// needs it: the lead target grows by the audio interleave, and the cap by one video subsegment on
/// top of the ordinary lead. An ordinary source passes 0 for both and keeps 4 s and 256 packets.
struct SoftwareReadGateBudget: Equatable, Sendable {
    /// A subsegment longer than this is clamped. DASH-IF guidance tops out around 10 s, so this only
    /// bounds what a broken sidx could make the loop hold in memory.
    static let interleaveCeilingSeconds = 15.0
    static let ordinaryParkedVideoCap = 256
    /// Unknown frame rate: budget for 60 fps, the upper end a software session decodes.
    static let fallbackFrameRate = 60.0
    /// Room for the frames still parked from the previous piece when a new one starts.
    static let parkedVideoMargin = 64

    let audioLeadSeconds: Double
    let parkedVideoCap: Int

    init(audioReadLeadSeconds: Double, videoSubsegmentSeconds: Double, frameRate: Double?) {
        func clamped(_ seconds: Double) -> Double {
            seconds.isFinite ? min(max(seconds, 0), Self.interleaveCeilingSeconds) : 0
        }
        let audioLead = clamped(audioReadLeadSeconds)
        let videoSpan = clamped(videoSubsegmentSeconds)
        audioLeadSeconds = AudioLookaheadPolicy.targetLeadSeconds + audioLead
        guard videoSpan > 0 else {
            parkedVideoCap = Self.ordinaryParkedVideoCap
            return
        }
        let fps = frameRate.flatMap { $0.isFinite && $0 > 0 ? min($0, 240) : nil } ?? Self.fallbackFrameRate
        // When audio runs low, the clock is at most one ordinary lead short of the next audio piece,
        // and everything in front of that piece is video up to one subsegment past it.
        let packets = Int(((AudioLookaheadPolicy.targetLeadSeconds + videoSpan) * fps).rounded(.up))
        parkedVideoCap = max(Self.ordinaryParkedVideoCap, packets + Self.parkedVideoMargin)
    }

    static let ordinary = SoftwareReadGateBudget(audioReadLeadSeconds: 0, videoSubsegmentSeconds: 0, frameRate: nil)
}
