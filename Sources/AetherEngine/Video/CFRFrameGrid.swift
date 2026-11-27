import Foundation
import AetherLibavutil

/// AE#886: the exact frame grid of a constant-frame-rate video track whose container time base is
/// too coarse to carry it. Matroska stores 1 ms ticks, so a 23.976 fps track arrives as 41 and 42 ms
/// steps, and the fMP4 the native path builds kept that quantization (the muxer adopted the source
/// time base as 1/16000). At a 59.94 Hz output every second 23.976 frame sits exactly on a refresh
/// boundary, so up to half a millisecond of rounding moves frames to the neighbouring vsync and the
/// 3:2 cadence breaks into 3, 2, 2, 3 bursts.
///
/// The grid gives the muxer a time base that holds one frame in a whole number of ticks
/// (1/24000 with 1001 ticks a frame for 23.976) and puts every timestamp that lies within one
/// source tick of a grid slot onto that slot. Anything farther away keeps its own time, so a
/// variable-rate or edited stretch is passed through rather than bent onto a grid it does not have.
struct CFRFrameGrid {
    let sourceTimeBase: AVRational
    /// Source-axis PTS of slot 0, the stream's start time.
    let originPts: Int64
    /// The muxer's video time base: 1 / (frame rate numerator scaled to at least 10000).
    let outputTimeBase: AVRational
    /// One frame in `outputTimeBase` ticks.
    let frameTicks: Int64

    /// Where a track's frames really sit against the grid, followed as they arrive.
    ///
    /// The grid is anchored at the stream's start, and a real track's frame is not always exactly
    /// 1001/24000 s: a Blu-ray remux measured 41.70839 ms a frame against 41.70833, which is 1.3 ms
    /// of drift 12 minutes in and 6 ms after an hour. Anchored, such a track ends up more than one
    /// source tick from every slot, most of its frames pass through unsnapped between neighbours
    /// that did snap, and the fragments the muxer cuts from that mix join a frame apart: the first
    /// frame of a fragment is pulled a frame early, on top of its neighbour, with a hole behind it.
    ///
    /// The phase is that offset, in the units of `snap`'s exact fraction. It is taken from the first
    /// frame a producer sees and then follows each frame that lands near a slot, so the test stays
    /// "within one source tick of a slot" while the slots move with the track. Frames keep their
    /// own slot numbers (the phase is a few milliseconds, a slot is tens), so two producers of one
    /// session still place a frame on the same output time. Pump thread only.
    final class Phase: @unchecked Sendable {
        var offset: Int64 = 0
        var isSet = false
        /// Never follow further than this many source ticks from the anchored grid: past it the
        /// picture would run visibly out of step with the sound, and the track is left as it is.
        static let maximumTicks: Int64 = 40
    }

    /// Nil: the anchored grid, exactly as before. Set by `trackingCopy()`.
    private(set) var phase: Phase?

    /// This grid, following the track's drift from here on. One per producer: a producer that
    /// starts after a seek takes its phase from its own first frame.
    func trackingCopy() -> CFRFrameGrid {
        var copy = self
        copy.phase = Phase()
        return copy
    }

    /// The rates the grid is built for, as exact rationals.
    static let standardRates: [AVRational] = [
        AVRational(num: 24000, den: 1001), AVRational(num: 24, den: 1), AVRational(num: 25, den: 1),
        AVRational(num: 30000, den: 1001), AVRational(num: 30, den: 1),
        AVRational(num: 48000, den: 1001), AVRational(num: 48, den: 1), AVRational(num: 50, den: 1),
        AVRational(num: 60000, den: 1001), AVRational(num: 60, den: 1),
    ]

    /// A probe has to sit this close (relative) to a standard rate: a tenth of the 0.1% gap
    /// between 24 and 23.976, so the two are never confused.
    static let rateTolerance = 1e-4

    /// The coarsest tick that still carries a frame exactly enough to leave alone (0.1 ms). MPEG-TS
    /// (90 kHz) and MP4 (usually 1/framerate multiples) are finer and never get a grid.
    static let coarseTickSeconds = 1e-4

    /// Nil unless `frameRate` is a standard rate, the source tick is coarse, and one frame is not
    /// a whole number of source ticks (25 and 50 fps fit 1 ms exactly and need nothing).
    static func make(sourceTimeBase tb: AVRational, frameRate: AVRational, startPts: Int64) -> CFRFrameGrid? {
        guard tb.num > 0, tb.den > 0, frameRate.num > 0, frameRate.den > 0 else { return nil }
        guard Double(tb.num) / Double(tb.den) >= coarseTickSeconds else { return nil }
        let measured = Double(frameRate.num) / Double(frameRate.den)
        guard let rate = standardRates.first(where: {
            let exact = Double($0.num) / Double($0.den)
            return abs(measured - exact) / exact <= rateTolerance
        }) else { return nil }
        // One frame = rate.den / rate.num seconds = rate.den * tb.den / (rate.num * tb.num) source ticks.
        let frameNumerator = Int64(rate.den) * Int64(tb.den)
        let frameDenominator = Int64(rate.num) * Int64(tb.num)
        guard frameNumerator % frameDenominator != 0 else { return nil }
        let scale: Int64 = rate.num < 10000 ? 1000 : 1
        return CFRFrameGrid(
            sourceTimeBase: tb,
            originPts: startPts == Int64.min ? 0 : startPts,
            outputTimeBase: AVRational(num: 1, den: Int32(Int64(rate.num) * scale)),
            frameTicks: Int64(rate.den) * scale
        )
    }

    /// `ticks` (source time base) in `outputTimeBase`, rounded to the nearest tick.
    func rescale(_ ticks: Int64) -> Int64 {
        av_rescale_q_rnd(ticks, sourceTimeBase, outputTimeBase, AV_ROUND_NEAR_INF)
    }

    /// The grid slot for a source-axis timestamp, in `outputTimeBase`, or nil when it lies more
    /// than one source tick from every slot (or is NOPTS).
    func snap(_ sourcePts: Int64) -> Int64? {
        guard sourcePts != Int64.min else { return nil }
        // Offset from the origin in output ticks, kept as the exact fraction N / D.
        let scale = Int64(sourceTimeBase.num) * Int64(outputTimeBase.den)
        let d = Int64(sourceTimeBase.den)
        let (delta, o1) = sourcePts.subtractingReportingOverflow(originPts)
        let (n, o2) = delta.multipliedReportingOverflow(by: scale)
        let (slotSpan, o3) = d.multipliedReportingOverflow(by: frameTicks)
        guard !o1, !o2, !o3, slotSpan > 0 else { return nil }
        if let phase {
            if !phase.isSet {
                // The producer's first frame says where the track sits now.
                let nearest = Self.roundedQuotient(n, slotSpan)
                let (base, overflow) = nearest.multipliedReportingOverflow(by: slotSpan)
                if !overflow, abs(n - base) <= Phase.maximumTicks * scale {
                    phase.offset = n - base
                    phase.isSet = true
                }
            }
            let adjusted = n - phase.offset
            let slot = Self.roundedQuotient(adjusted, slotSpan)
            let (onGrid, o4) = slot.multipliedReportingOverflow(by: slotSpan)
            guard !o4 else { return nil }
            let error = adjusted - onGrid
            // Follow frames that are near a slot (rounding and drift), not ones that are somewhere else.
            if abs(error) <= 2 * scale {
                let step = error / 16
                let moved = phase.offset + (step != 0 ? step : (abs(error) * 4 > scale ? error.signum() : 0))
                if abs(moved) <= Phase.maximumTicks * scale { phase.offset = moved }
            }
            guard abs(error) <= scale else { return nil }
            return rescale(originPts) &+ slot &* frameTicks
        }
        let slot = Self.roundedQuotient(n, slotSpan)
        let (onGrid, o4) = slot.multipliedReportingOverflow(by: slotSpan)
        guard !o4 else { return nil }
        // One source tick is `scale` in the N / D fraction.
        guard abs(n - onGrid) <= scale else { return nil }
        return rescale(originPts) &+ slot &* frameTicks
    }

    /// A video packet on the output axis: `pts` and `dts` are item-axis (source minus `shift`), in
    /// the source time base. Nil when the PTS is off the grid, in which case the caller rescales
    /// the packet as it always did. The DTS takes its slot when it has one and never passes the PTS;
    /// a duration within one source tick of a frame becomes exactly one frame.
    func place(pts: Int64, dts: Int64, duration: Int64, shift: Int64) -> (pts: Int64, dts: Int64, duration: Int64)? {
        let unshift = shift == Int64.min ? 0 : shift
        guard pts != Int64.min, let gridPts = snap(pts &+ unshift) else { return nil }
        let shiftOut = rescale(unshift)
        let outPts = gridPts &- shiftOut
        var outDts = dts
        if dts != Int64.min {
            outDts = (snap(dts &+ unshift).map { $0 &- shiftOut } ?? rescale(dts))
            outDts = min(outDts, outPts)
        }
        let durationOut = rescale(duration)
        let oneTick = rescale(1)
        let outDuration = duration > 0 && abs(durationOut - frameTicks) <= oneTick ? frameTicks : durationOut
        return (outPts, outDts, outDuration)
    }

    static func roundedQuotient(_ n: Int64, _ d: Int64) -> Int64 {
        let q = n / d
        let r = n % d
        if 2 * abs(r) >= d { return r < 0 ? q - 1 : q + 1 }
        return q
    }
}
