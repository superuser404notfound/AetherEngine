import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// #409: some MP4 writers drop the `ctts` table while keeping a bitstream that reorders pictures.
/// Every sample then reports `PTS == DTS`, so the container hands decode order out as presentation
/// order. Nothing downstream can recover from that on its own: stream-copying those timestamps into
/// fMP4 makes AVPlayer show each future reference picture before the B pictures it precedes, and a
/// software decode has the same axis on its frames. Measured on a 66-frame twin pair (identical
/// bitstream, `ctts` removed from one), 45 of 66 pictures were presented at a time belonging to a
/// different picture and the content order stepped backwards 30 times.
///
/// The information the container lost is still in the bitstream: each slice header carries a picture
/// order count, which is display order. libavcodec's H.264 *parser* reads it without decoding
/// anything (`output_picture_number`), and it reads MP4's length-prefixed AVCC packets directly, so
/// the repair costs one slice-header parse per video packet and no pixels.
///
/// The rewrite reproduces what the muxer should have written:
///
///     raw(i) = firstDTS + round((phase + i) * cadence) - round(phase * cadence)
///     PTS = presentation(sequenceBaseOrdinal + displayIndex)
///     DTS = presentation(decodeOrdinal - videoDelay)
///
/// The first packet or seek landing is placed exactly on the sampled rational lattice; decode order
/// then advances its ordinal continuously, so one late one-tick container anomaly cannot mix a raw
/// timestamp back into the repaired axis. Pulling DTS back by the decode lead is what keeps
/// `PTS >= DTS`, the invariant the fMP4 muxer and its output sanitizer enforce; a healthy file carries
/// exactly the same negative head (the twin's first packet is `pts=0 dts=-2002`).
///
/// Verified against three fixture pairs (432 packets, both edit-list shapes, 7 IDR boundaries): every
/// repaired packet matches its healthy twin's PTS and DTS exactly.
enum H264CompositionOffsetRepair {

    /// One sampled picture. Deliberately values only, so the decision is testable without FFmpeg.
    struct Sample: Equatable, Sendable {
        var dts: Int64
        var pts: Int64
        var pictureOrderCount: Int64
        var isKeyframe: Bool
    }

    /// A constant frame cadence expressed exactly in stream-timebase ticks. Integer timestamp
    /// ladders quantize this rational with FFmpeg's nearest/away-from-zero rule, so a legitimate
    /// CFR stream may alternate between the floor and ceiling tick counts (for example 40040/40041).
    struct Cadence: Equatable, Sendable {
        let numerator: Int64
        let denominator: Int64

        init?(numerator: Int64, denominator: Int64) {
            guard numerator > 0, denominator > 0 else { return nil }
            let divisor = H264CompositionOffsetRepair.greatestCommonDivisor(numerator, denominator)
            self.numerator = numerator / divisor
            self.denominator = denominator / divisor
        }

        init?(timeBase: AVRational, frameRate: AVRational) {
            guard timeBase.num > 0, timeBase.den > 0,
                  frameRate.num > 0, frameRate.den > 0 else { return nil }
            let (numerator, numeratorOverflow) = Int64(timeBase.den)
                .multipliedReportingOverflow(by: Int64(frameRate.den))
            let (denominator, denominatorOverflow) = Int64(timeBase.num)
                .multipliedReportingOverflow(by: Int64(frameRate.num))
            guard !numeratorOverflow, !denominatorOverflow else { return nil }
            self.init(numerator: numerator, denominator: denominator)
        }

        var floorStep: Int64 { numerator / denominator }
        var ceilStep: Int64 {
            let quotient = numerator / denominator
            return numerator % denominator == 0 ? quotient : quotient + 1
        }

        /// Reduced denominator is the tick-pattern period. Requiring two observed periods before a
        /// fractional plan is accepted keeps short VFR/jitter runs from masquerading as quantization.
        var period: Int64 { denominator }

        /// Stream rates are advisory here: `r_frame_rate` is commonly a rounded nominal rate and
        /// `avg_frame_rate` is duration-derived. The STTS cycle remains the exact authority. An
        /// approximate declared rate is accepted only when its exact rational error cannot add up
        /// to more than half a tick across the known stream span; without that span it fails closed.
        func isConsistent(with metadata: Cadence, maximumFrameSpan: Int64?) -> Bool {
            if self == metadata { return true }
            guard let maximumFrameSpan, maximumFrameSpan > 0 else { return false }

            // 2 * frames * |a/b - c/d| <= 1, evaluated with fixed-width limbs so neither
            // cross-multiplication nor the accumulated error can overflow or round toward a pass.
            let observedProduct = UInt64(numerator)
                .multipliedFullWidth(by: UInt64(metadata.denominator))
            let metadataProduct = UInt64(metadata.numerator)
                .multipliedFullWidth(by: UInt64(denominator))
            let difference = Self.absoluteDifference(observedProduct, metadataProduct)
            let denominatorProduct = UInt64(denominator)
                .multipliedFullWidth(by: UInt64(metadata.denominator))
            let (scale, scaleOverflow) = UInt64(maximumFrameSpan)
                .multipliedReportingOverflow(by: 2)
            guard !scaleOverflow else { return false }

            let lowProduct = difference.low.multipliedFullWidth(by: scale)
            let highProduct = difference.high.multipliedFullWidth(by: scale)
            let (middle, middleCarry) = lowProduct.high
                .addingReportingOverflow(highProduct.low)
            let (top, topOverflow) = highProduct.high
                .addingReportingOverflow(middleCarry ? 1 : 0)
            guard !topOverflow, top == 0 else { return false }
            return Self.isLessThanOrEqual(
                (high: middle, low: lowProduct.low),
                denominatorProduct
            )
        }

        private static func absoluteDifference(
            _ lhs: (high: UInt64, low: UInt64),
            _ rhs: (high: UInt64, low: UInt64)
        ) -> (high: UInt64, low: UInt64) {
            let (larger, smaller) = isLessThanOrEqual(lhs, rhs) ? (rhs, lhs) : (lhs, rhs)
            let (low, borrow) = larger.low.subtractingReportingOverflow(smaller.low)
            let (partialHigh, highUnderflow) = larger.high
                .subtractingReportingOverflow(smaller.high)
            let (high, borrowUnderflow) = partialHigh
                .subtractingReportingOverflow(borrow ? 1 : 0)
            precondition(!highUnderflow && !borrowUnderflow)
            return (high, low)
        }

        private static func isLessThanOrEqual(
            _ lhs: (high: UInt64, low: UInt64),
            _ rhs: (high: UInt64, low: UInt64)
        ) -> Bool {
            lhs.high < rhs.high || (lhs.high == rhs.high && lhs.low <= rhs.low)
        }

        /// `round_near_away(frameOrdinal * numerator / denominator)`, without overflowing an Int64
        /// intermediate. The sign-symmetric form is important for the negative reorder head.
        func timestamp(at frameOrdinal: Int64) -> Int64? {
            guard frameOrdinal != Int64.min else { return nil }
            let negative = frameOrdinal < 0
            let magnitude = UInt64(negative ? -frameOrdinal : frameOrdinal)
            guard let scaled = scaledMagnitude(magnitude), scaled <= UInt64(Int64.max) else {
                return nil
            }
            let value = Int64(scaled)
            return negative ? -value : value
        }

        /// Exact inverse for timestamps known to lie on this cadence. Used for container-index
        /// folding and after seek, so rounding phase is recovered from the global ladder instead of
        /// being restarted at each IDR. nil means the timestamp is not on the declared CFR lattice.
        func frameOrdinal(forTimestamp timestamp: Int64) -> Int64? {
            guard timestamp != Int64.min else { return nil }
            if timestamp == 0 { return 0 }
            let negative = timestamp < 0
            let magnitude = UInt64(negative ? -timestamp : timestamp)
            let product = magnitude.multipliedFullWidth(by: UInt64(denominator))
            let divisor = UInt64(numerator)
            guard product.high < divisor else { return nil }
            let approximateMagnitude = divisor.dividingFullWidth(product).quotient
            guard approximateMagnitude <= UInt64(Int64.max - 3) else { return nil }
            let approximate = negative ? -Int64(approximateMagnitude) : Int64(approximateMagnitude)
            for adjustment in -2...2 {
                let (candidate, overflow) = approximate.addingReportingOverflow(Int64(adjustment))
                guard !overflow else { continue }
                if self.timestamp(at: candidate) == timestamp { return candidate }
            }
            return nil
        }

        private func scaledMagnitude(_ magnitude: UInt64) -> UInt64? {
            let product = magnitude.multipliedFullWidth(by: UInt64(numerator))
            let divisor = UInt64(denominator)
            guard product.high < divisor else { return nil }
            let division = divisor.dividingFullWidth(product)
            let threshold = (divisor >> 1) + (divisor & 1)
            guard division.remainder >= threshold else { return division.quotient }
            let (rounded, overflow) = division.quotient.addingReportingOverflow(1)
            return overflow ? nil : rounded
        }
    }

    /// What the rewrite needs, all of it derived once at the head of the session.
    struct Plan: Equatable, Sendable {
        /// Ticks between two consecutive pictures in decode order.
        var step: Int64
        /// `videoDelay * step`: how far DTS runs ahead of presentation in a well-formed file.
        var decodeLead: Int64
        /// Ticks between the sampled DTS ladder and the presentation timeline. 0 when the broken
        /// writer left the ladder on the presentation axis; `decodeLead` when it kept the edit list
        /// that trims the reorder head (both shapes occur, see `presentationShift`).
        var shift: Int64
        /// Ticks a picture order count advances per displayed picture. 2 for frame coding, but
        /// measured rather than assumed.
        var pocStep: Int64

        /// Fractional-CFR fields. nil together for the original exact-integer path. `rawFrameOffset`
        /// describes the broken ladder: `-videoDelay` when the edit list retained the decode head,
        /// or 0 when the writer left that ladder on the presentation axis. `rawPhase` is independent:
        /// it identifies where the sampled first DTS sits in the cadence's quantization period.
        var cadence: Cadence?
        var presentationOrigin: Int64?
        var rawFrameOffset: Int64?
        var videoDelay: Int64?
        var rawTimestampAnchor: Int64?
        var rawPhase: Int64?

        init(step: Int64, decodeLead: Int64, shift: Int64, pocStep: Int64) {
            self.step = step
            self.decodeLead = decodeLead
            self.shift = shift
            self.pocStep = pocStep
            cadence = nil
            presentationOrigin = nil
            rawFrameOffset = nil
            videoDelay = nil
            rawTimestampAnchor = nil
            rawPhase = nil
        }

        /// Compatibility constructor for a phase-zero presentation lattice. Classification uses the
        /// anchor constructor below because a real MP4's STTS phase need not coincide with semantic
        /// frame offset (the affected physical file starts at phase 2 with videoDelay 1).
        init?(
            cadence: Cadence,
            presentationOrigin: Int64,
            ladderStart: Int64,
            rawFrameOffset: Int64,
            videoDelay: Int64,
            pocStep: Int64
        ) {
            let phase = H264CompositionOffsetRepair.positiveModulo(
                rawFrameOffset,
                modulus: cadence.period
            )
            self.init(
                cadence: cadence,
                rawTimestampAnchor: ladderStart,
                rawPhase: phase,
                rawFrameOffset: rawFrameOffset,
                videoDelay: videoDelay,
                pocStep: pocStep
            )
            guard self.presentationOrigin == presentationOrigin else { return nil }
        }

        init?(
            cadence: Cadence,
            rawTimestampAnchor: Int64,
            rawPhase: Int64,
            rawFrameOffset: Int64,
            videoDelay: Int64,
            pocStep: Int64
        ) {
            // With fewer than two ticks per frame, a tolerated one-tick container defect can be the
            // exact timestamp of an adjacent ordinal. Packets and indexes cannot distinguish those
            // meanings, so this cadence is not safe to repair at all.
            guard cadence.floorStep >= 2,
                  rawPhase >= 0, rawPhase < cadence.period,
                  rawFrameOffset == 0 || rawFrameOffset == -videoDelay,
                  videoDelay > 0,
                  let oneFrame = cadence.timestamp(at: 1),
                  let presentationOrigin = Self.anchoredTimestamp(
                    cadence: cadence,
                    anchor: rawTimestampAnchor,
                    phase: rawPhase,
                    decodeOrdinal: -rawFrameOffset
                  ),
                  let firstDecodeTimestamp = Self.anchoredTimestamp(
                    cadence: cadence,
                    anchor: rawTimestampAnchor,
                    phase: rawPhase,
                    decodeOrdinal: -videoDelay - rawFrameOffset
                  ) else { return nil }
            let (decodeLead, leadOverflow) = presentationOrigin
                .subtractingReportingOverflow(firstDecodeTimestamp)
            let (shift, shiftOverflow) = presentationOrigin
                .subtractingReportingOverflow(rawTimestampAnchor)
            guard !leadOverflow, !shiftOverflow, decodeLead > 0 else { return nil }
            self.step = oneFrame
            self.decodeLead = decodeLead
            self.shift = shift
            self.pocStep = pocStep
            self.cadence = cadence
            self.presentationOrigin = presentationOrigin
            self.rawFrameOffset = rawFrameOffset
            self.videoDelay = videoDelay
            self.rawTimestampAnchor = rawTimestampAnchor
            self.rawPhase = rawPhase
        }

        var isRational: Bool { cadence != nil }

        func decodeOrdinal(forRawTimestamp timestamp: Int64) -> Int64? {
            guard let cadence, let rawTimestampAnchor, let rawPhase,
                  let phaseTimestamp = cadence.timestamp(at: rawPhase) else { return nil }
            let (relative, relativeOverflow) = timestamp
                .subtractingReportingOverflow(rawTimestampAnchor)
            let (absolute, absoluteOverflow) = relative
                .addingReportingOverflow(phaseTimestamp)
            guard !relativeOverflow, !absoluteOverflow,
                  let cadenceOrdinal = cadence.frameOrdinal(forTimestamp: absolute) else { return nil }
            let (decodeOrdinal, ordinalOverflow) = cadenceOrdinal
                .subtractingReportingOverflow(rawPhase)
            return ordinalOverflow ? nil : decodeOrdinal
        }

        /// A seek may land on the same isolated one-tick container defect tolerated during a
        /// continuous read. Re-anchor only when exactly one lattice point exists within that bound;
        /// a tight cadence that makes the answer ambiguous remains unplaceable.
        func decodeOrdinal(forRawTimestampWithinOneTick timestamp: Int64) -> Int64? {
            var match: Int64?
            for adjustment in -1...1 {
                let (candidateTimestamp, overflow) = timestamp
                    .addingReportingOverflow(Int64(adjustment))
                guard !overflow,
                      let candidate = decodeOrdinal(forRawTimestamp: candidateTimestamp) else {
                    continue
                }
                if let match, match != candidate { return nil }
                match = candidate
            }
            return match
        }

        func presentationTimestamp(frameOrdinal: Int64) -> Int64? {
            guard let rawFrameOffset else { return nil }
            let (decodeOrdinal, overflow) = frameOrdinal
                .subtractingReportingOverflow(rawFrameOffset)
            return overflow ? nil : rawTimestamp(decodeOrdinal: decodeOrdinal)
        }

        /// Maps a packet/index timestamp from the broken raw ladder onto the repaired decode axis.
        /// The exact-integer path preserves its historical constant-offset behavior.
        func repairedDecodeTimestamp(_ timestamp: Int64) -> Int64? {
            guard isRational else {
                let (shifted, shiftOverflow) = timestamp.addingReportingOverflow(shift)
                guard !shiftOverflow else { return nil }
                let (result, leadOverflow) = shifted.subtractingReportingOverflow(decodeLead)
                return leadOverflow ? nil : result
            }
            guard let decodeOrdinal = decodeOrdinal(forRawTimestamp: timestamp) else {
                return nil
            }
            return repairedDecodeTimestamp(decodeOrdinal: decodeOrdinal)
        }

        func repairedDecodeTimestamp(decodeOrdinal: Int64) -> Int64? {
            guard let videoDelay else { return nil }
            let (targetOrdinal, overflow) = decodeOrdinal.subtractingReportingOverflow(videoDelay)
            return overflow ? nil : presentationTimestamp(frameOrdinal: targetOrdinal)
        }

        func rawTimestamp(decodeOrdinal: Int64) -> Int64? {
            guard let cadence, let rawTimestampAnchor, let rawPhase else { return nil }
            return Self.anchoredTimestamp(
                cadence: cadence,
                anchor: rawTimestampAnchor,
                phase: rawPhase,
                decodeOrdinal: decodeOrdinal
            )
        }

        private static func anchoredTimestamp(
            cadence: Cadence,
            anchor: Int64,
            phase: Int64,
            decodeOrdinal: Int64
        ) -> Int64? {
            let (cadenceOrdinal, ordinalOverflow) = phase
                .addingReportingOverflow(decodeOrdinal)
            guard !ordinalOverflow,
                  let phaseTimestamp = cadence.timestamp(at: phase),
                  let targetTimestamp = cadence.timestamp(at: cadenceOrdinal) else { return nil }
            let (relative, relativeOverflow) = targetTimestamp
                .subtractingReportingOverflow(phaseTimestamp)
            let (timestamp, timestampOverflow) = anchor.addingReportingOverflow(relative)
            return relativeOverflow || timestampOverflow ? nil : timestamp
        }
    }

    enum Verdict: Equatable, Sendable {
        /// The container carries composition offsets: nothing to repair, and the cheapest, most
        /// common outcome (one packet decides it for a healthy reordered file).
        case healthy
        /// Not this defect, or not enough evidence to act. Never repairs.
        case inconclusive(String)
        case repair(Plan)
    }

    /// Video packets to sample before deciding. A healthy file leaves after the first packet that
    /// shows an offset; only the broken shape pays the full window, which has to span at least one
    /// mini-GOP for the picture order to prove reordering at all.
    static let sampleTarget = 12
    /// Below this the ladder and the reorder evidence are too thin to trust; sampling stops early
    /// only on a healthy verdict or EOF.
    static let minimumSamples = 9
    /// Held-packet ceiling while sampling. A UHD intra head could otherwise park tens of megabytes
    /// waiting for a verdict that a broken file reaches in twelve packets.
    static let sampleByteBudget = 8 << 20
    /// Packets of any kind the sample may hold. A demuxer whose video stream is discarded (the
    /// subtitle side reader does exactly that) would otherwise never reach its video quota and hold
    /// the whole interleave waiting for pictures that are not coming.
    static let heldPacketCeiling = 96

    /// The presentation axis a repaired stream lands on.
    ///
    /// Two writers produce this defect and they differ by one decode lead. One drops `ctts` and
    /// leaves the sample ladder where presentation starts (first reported DTS 0); the other keeps
    /// the edit list that trims the reorder head, so the same ladder is reported from `-decodeLead`.
    /// The container states which one it is: `AVStream.start_time` is the presentation start after
    /// edit-list handling, and the first index entry is where the ladder starts. The difference is
    /// the shift, clamped to `[0, decodeLead]` because no honest file needs more and a malformed
    /// header must not be able to drag the video off its audio by an arbitrary amount.
    static func presentationShift(
        streamStartTime: Int64,
        ladderStart: Int64,
        decodeLead: Int64
    ) -> Int64 {
        guard streamStartTime != Int64.min, ladderStart != Int64.min, decodeLead > 0 else { return 0 }
        let (raw, overflow) = streamStartTime.subtractingReportingOverflow(ladderStart)
        guard !overflow else { return 0 }
        return min(max(raw, 0), decodeLead)
    }

    /// Fail-closed decision over the sampled head. Anything unproven returns `.inconclusive`, which
    /// leaves the stream exactly as the container delivered it.
    static func classify(
        samples: [Sample],
        videoDelay: Int,
        streamStartTime: Int64,
        ladderStart: Int64,
        streamFrameCount: Int64 = 0,
        averageCadence: Cadence? = nil,
        nominalCadence: Cadence? = nil
    ) -> Verdict {
        guard videoDelay > 0, videoDelay <= 16 else {
            return .inconclusive("reorder delay \(videoDelay) outside 1...16")
        }
        // One composition offset is proof the writer emitted the table, and it ends the sampling
        // before the window fills.
        if samples.contains(where: { $0.pts != Int64.min && $0.dts != Int64.min && $0.pts != $0.dts }) {
            return .healthy
        }
        guard samples.count >= minimumSamples else {
            return .inconclusive("only \(samples.count) sampled pictures")
        }
        guard samples.allSatisfy({ $0.dts != Int64.min && $0.pts == $0.dts }) else {
            return .inconclusive("timestamps are not uniformly PTS == DTS")
        }
        guard let first = samples.first, first.isKeyframe, first.pictureOrderCount == 0 else {
            return .inconclusive("sample does not start on a picture-order origin")
        }

        // An exact integer ladder keeps the original scalar fast path. A fractional constant-rate
        // cadence is also repairable, but only when stream metadata predicts the observed adjacent
        // tick pattern exactly for at least two full periods. Merely seeing max-min == 1 is not
        // enough: a short VFR/jitter run can have the same range.
        var decodeSteps: [Int64] = []
        decodeSteps.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            let (delta, overflow) = samples[index].dts
                .subtractingReportingOverflow(samples[index - 1].dts)
            guard !overflow else { return .inconclusive("decode ladder is not uniform") }
            guard delta > 0 else { return .inconclusive("decode timestamps do not advance") }
            decodeSteps.append(delta)
        }
        guard let minimumStep = decodeSteps.min(), let maximumStep = decodeSteps.max() else {
            return .inconclusive("no ladder step")
        }

        let fixedStep: Int64?
        var rationalPlan: Plan?
        if minimumStep == maximumStep {
            fixedStep = minimumStep
        } else {
            fixedStep = nil
            let (stepSpread, spreadOverflow) = maximumStep.subtractingReportingOverflow(minimumStep)
            guard !spreadOverflow, stepSpread == 1,
                  streamStartTime != Int64.min, ladderStart != Int64.min,
                  samples.first?.dts == ladderStart else {
                return .inconclusive("decode ladder is not uniform")
            }

            guard let observed = observedCadence(
                decodeSteps: decodeSteps,
                maximumFrameSpan: maximumFrameSpan(
                    streamFrameCount: streamFrameCount,
                    videoDelay: videoDelay
                ),
                // avg_frame_rate reflects the complete stream and must veto a short sampled alias.
                // r_frame_rate is only a fallback when that stronger evidence is absent.
                metadataCadence: averageCadence ?? nominalCadence
            ), let firstDTS = samples.first?.dts else {
                return .inconclusive("decode ladder is not uniform")
            }
            let semanticOffsets = [Int64.zero, -Int64(videoDelay)]
            let plans = semanticOffsets.compactMap { rawFrameOffset -> Plan? in
                guard let plan = Plan(
                    cadence: observed.cadence,
                    rawTimestampAnchor: firstDTS,
                    rawPhase: observed.phase,
                    rawFrameOffset: rawFrameOffset,
                    videoDelay: Int64(videoDelay),
                    pocStep: 1
                ), plan.presentationOrigin == streamStartTime else { return nil }
                return plan
            }
            guard plans.count == 1 else {
                return .inconclusive("decode ladder is not uniform")
            }
            rationalPlan = plans[0]
        }

        // Without a picture-order regression the file presents in decode order and there is nothing
        // to repair, whatever its reorder delay claims.
        let pocs = samples.map(\.pictureOrderCount)
        guard zip(pocs, pocs.dropFirst()).contains(where: { $1 < $0 }) else {
            return .inconclusive("picture order never regresses")
        }
        guard pocs.allSatisfy({ $0 >= 0 }) else { return .inconclusive("negative picture order count") }

        // The step is measured, not assumed: frame coding advances the count by 2, but a stream that
        // uses a different increment stays repairable as long as it is consistent.
        var pocStep: Int64 = 0
        for value in pocs where value > 0 { pocStep = greatestCommonDivisor(pocStep, value) }
        guard pocStep > 0 else { return .inconclusive("picture order does not advance") }

        // The strongest available self-check: the display indices the plan would produce must be a
        // bijection onto the sampled window. A wrong picture-order step or a stream this arithmetic
        // does not describe collapses two pictures onto one time, and that is caught here rather
        // than on screen.
        var displayIndices: Set<Int64> = []
        for sample in samples {
            let index = sample.pictureOrderCount / pocStep
            guard sample.pictureOrderCount % pocStep == 0 else {
                return .inconclusive("picture order is not a multiple of its step")
            }
            guard displayIndices.insert(index).inserted else {
                return .inconclusive("two pictures share display index \(index)")
            }
        }
        // Distinct is not enough. A single picture order that is not on the common step drags the
        // measured step down (a stray 17 among even counts makes it 1), and the indices that follow
        // are then spread over twice the ladder while still being distinct. Ranks have to FILL the
        // window they came from: the span may exceed the sample only by the pictures still in flight
        // at its ragged edge, which is the reorder delay.
        guard let maxIndex = displayIndices.max(), let minIndex = displayIndices.min() else {
            return .inconclusive("display indices do not fill the sampled window")
        }
        let (displaySpan, spanOverflow) = maxIndex.subtractingReportingOverflow(minIndex)
        let (inclusiveSpan, inclusiveOverflow) = displaySpan.addingReportingOverflow(1)
        guard !spanOverflow, !inclusiveOverflow,
              inclusiveSpan <= Int64(samples.count + videoDelay + 1) else {
            return .inconclusive("display indices do not fill the sampled window")
        }

        let plan: Plan
        if var rationalPlan {
            rationalPlan.pocStep = pocStep
            plan = rationalPlan
        } else {
            guard let step = fixedStep, step > 0 else { return .inconclusive("no ladder step") }
            let (decodeLead, leadOverflow) = Int64(videoDelay).multipliedReportingOverflow(by: step)
            guard !leadOverflow, decodeLead > 0 else {
                return .inconclusive("decode ladder is not uniform")
            }
            plan = Plan(
                step: step,
                decodeLead: decodeLead,
                shift: presentationShift(
                    streamStartTime: streamStartTime,
                    ladderStart: ladderStart == Int64.min ? (samples.first?.dts ?? Int64.min) : ladderStart,
                    decodeLead: decodeLead
                ),
                pocStep: pocStep
            )
        }

        // The structural checks above derive a candidate; the held head must also prove that the
        // exact Rewriter can place every sampled picture. This catches a malformed/misreported
        // videoDelay whose POC ranks look bijective but would make PTS precede DTS for only part of
        // the window, which would otherwise mix repaired and raw axes as the held queue drains.
        var dryRun = Rewriter(plan: plan)
        for sample in samples {
            guard dryRun.rewrite(
                dts: sample.dts,
                pictureOrderCount: sample.pictureOrderCount,
                isKeyframe: sample.isKeyframe
            ) != nil else {
                return .inconclusive("sample cannot be rewritten safely")
            }
        }
        return .repair(plan)
    }

    static func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    static func positiveModulo(_ value: Int64, modulus: Int64) -> Int64 {
        guard modulus > 0 else { return 0 }
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private static func maximumFrameSpan(
        streamFrameCount: Int64,
        videoDelay: Int
    ) -> Int64? {
        // AVStream.duration may be estimated, and converting it with a step sampled only from the
        // head would assume the very full-stream CFR property this gate is meant to prove. Only the
        // container's explicit frame count is strong enough to bound accumulated cadence error.
        guard streamFrameCount > 0 else { return nil }
        let (withReorderHead, headOverflow) = streamFrameCount
            .addingReportingOverflow(Int64(videoDelay))
        let (conservativeSpan, safetyOverflow) = withReorderHead.addingReportingOverflow(2)
        guard !headOverflow, !safetyOverflow, conservativeSpan > 0 else { return nil }
        return conservativeSpan
    }

    private static func observedCadence(
        decodeSteps: [Int64],
        maximumFrameSpan: Int64?,
        metadataCadence: Cadence?
    ) -> (cadence: Cadence, phase: Int64)? {
        let maximumPeriod = decodeSteps.count / 2
        guard maximumPeriod >= 2 else { return nil }
        var matches: [(cadence: Cadence, phase: Int64)] = []

        for period in 2...maximumPeriod {
            guard decodeSteps.indices.allSatisfy({ index in
                decodeSteps[index] == decodeSteps[index % period]
            }) else { continue }
            var periodTicks: Int64 = 0
            var overflowed = false
            for step in decodeSteps.prefix(period) {
                let (sum, overflow) = periodTicks.addingReportingOverflow(step)
                if overflow { overflowed = true; break }
                periodTicks = sum
            }
            guard !overflowed,
                  let cadence = Cadence(
                    numerator: periodTicks,
                    denominator: Int64(period)
                  ), cadence.period == Int64(period),
                  let metadataCadence,
                  cadence.isConsistent(
                    with: metadataCadence,
                    maximumFrameSpan: maximumFrameSpan
                  ) else {
                continue
            }

            for phase in 0..<cadence.period {
                let fits = decodeSteps.enumerated().allSatisfy { index, observedStep in
                    let (startOrdinal, startOverflow) = phase
                        .addingReportingOverflow(Int64(index))
                    let (endOrdinal, endOverflow) = startOrdinal.addingReportingOverflow(1)
                    guard !startOverflow, !endOverflow,
                          let start = cadence.timestamp(at: startOrdinal),
                          let end = cadence.timestamp(at: endOrdinal) else { return false }
                    let (step, stepOverflow) = end.subtractingReportingOverflow(start)
                    return !stepOverflow && step == observedStep
                }
                if fits { matches.append((cadence, phase)) }
            }
        }

        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// Applies a confirmed plan packet by packet. Picture order restarts at every IDR; fractional
    /// cadence additionally keeps one globally anchored decode ordinal across each continuous read.
    struct Rewriter {
        let plan: Plan
        /// Set at the first keyframe seen, and again whenever the picture order restarts.
        private(set) var sequenceAnchorDTS: Int64?
        /// Global presentation-frame ordinal for display index 0 of the current coded sequence.
        /// Fractional cadence needs this instead of restarting its rounding phase at each IDR.
        private var sequenceBaseOrdinal: Int64?
        /// Last consumed decode ordinal once the first packet (or seek landing) is placed exactly.
        /// An exact later timestamp may resynchronize across an unparseable/dropped picture; only an
        /// off-lattice timestamp advances by continuity, which prevents a one-tick container anomaly
        /// from mixing an untouched raw packet into the already repaired axis.
        private var lastRationalDecodeOrdinal: Int64?
        /// A seek leaves the parser and the sequence anchor behind; the next keyframe re-anchors.
        private var awaitingReanchor = true
        /// Pictures emitted untouched because no anchor was available or the arithmetic did not
        /// close. Surfaced so a stream this repair does not describe is visible as a number.
        private(set) var unrepairedPictures = 0
        private(set) var repairedPictures = 0

        init(plan: Plan) { self.plan = plan }

        mutating func noteSeek() {
            awaitingReanchor = true
            sequenceAnchorDTS = nil
            sequenceBaseOrdinal = nil
            lastRationalDecodeOrdinal = nil
        }

        /// nil when the picture cannot be placed; the caller then emits it untouched.
        mutating func rewrite(
            dts: Int64,
            pictureOrderCount: Int64?,
            isKeyframe: Bool
        ) -> (pts: Int64, dts: Int64)? {
            guard dts != Int64.min, plan.pocStep > 0 else {
                unrepairedPictures += 1
                return nil
            }
            if plan.isRational {
                return rewriteRational(
                    dts: dts,
                    pictureOrderCount: pictureOrderCount,
                    isKeyframe: isKeyframe
                )
            }
            guard let pictureOrderCount,
                  pictureOrderCount >= 0,
                  pictureOrderCount % plan.pocStep == 0 else {
                unrepairedPictures += 1
                return nil
            }
            let displayIndex = pictureOrderCount / plan.pocStep
            // A picture order of 0 on a keyframe is an IDR: a new coded video sequence starts here
            // and its first picture is also the first to be displayed. After a seek the landing
            // keyframe anchors even if its count is not 0, which is the only way an open-GOP entry
            // point can be placed at all; mid-sequence keyframes must not re-anchor, or every open
            // GOP would restart the display axis under a picture that has not moved.
            if isKeyframe, pictureOrderCount == 0 {
                sequenceAnchorDTS = dts
                awaitingReanchor = false
            } else if awaitingReanchor, isKeyframe {
                let (anchorOffset, offsetOverflow) = displayIndex
                    .multipliedReportingOverflow(by: plan.step)
                let (anchor, anchorOverflow) = dts.subtractingReportingOverflow(anchorOffset)
                guard !offsetOverflow, !anchorOverflow else {
                    unrepairedPictures += 1
                    return nil
                }
                sequenceAnchorDTS = anchor
                awaitingReanchor = false
            }
            guard let anchor = sequenceAnchorDTS, !awaitingReanchor else {
                unrepairedPictures += 1
                return nil
            }
            let (presentationOffset, offsetOverflow) = displayIndex
                .multipliedReportingOverflow(by: plan.step)
            let (shiftedAnchor, shiftOverflow) = anchor.addingReportingOverflow(plan.shift)
            let (pts, ptsOverflow) = shiftedAnchor.addingReportingOverflow(presentationOffset)
            guard !offsetOverflow, !shiftOverflow, !ptsOverflow,
                  let newDTS = plan.repairedDecodeTimestamp(dts) else {
                unrepairedPictures += 1
                return nil
            }
            // The muxer invariant. A picture that lands before its own decode time means the
            // arithmetic no longer describes this stream, and passing it through unchanged is
            // better than handing the muxer something it will silently clamp.
            guard pts >= newDTS else {
                unrepairedPictures += 1
                return nil
            }
            repairedPictures += 1
            return (pts, newDTS)
        }

        private mutating func rewriteRational(
            dts: Int64,
            pictureOrderCount: Int64?,
            isKeyframe: Bool
        ) -> (pts: Int64, dts: Int64)? {
            let exactDecodeOrdinal = plan.decodeOrdinal(forRawTimestamp: dts)
            let decodeOrdinal: Int64
            var mayAdvanceAfterUnplacedPicture = false
            if let lastRationalDecodeOrdinal {
                let (expected, overflow) = lastRationalDecodeOrdinal.addingReportingOverflow(1)
                guard !overflow else {
                    unrepairedPictures += 1
                    return nil
                }
                guard let expectedTimestamp = plan.rawTimestamp(decodeOrdinal: expected) else {
                    unrepairedPictures += 1
                    return nil
                }
                if Self.isWithinOneTick(dts, of: expectedTimestamp) {
                    // Near the expected point, tolerance is safe only when the entire +/-1 window
                    // identifies that one ordinal. A dense cadence may place an adjacent exact
                    // lattice point in the same window, in which case choosing either would be a
                    // silent one-frame jump.
                    guard plan.decodeOrdinal(forRawTimestampWithinOneTick: dts) == expected else {
                        unrepairedPictures += 1
                        return nil
                    }
                    decodeOrdinal = expected
                } else if let exactDecodeOrdinal {
                    // An exact forward ordinal is stronger than packet counting: it preserves a
                    // legitimate gap and resynchronizes after a preceding parser miss. A backward
                    // exact timestamp is a discontinuity this session was not told about.
                    guard exactDecodeOrdinal >= expected else {
                        unrepairedPictures += 1
                        return nil
                    }
                    decodeOrdinal = exactDecodeOrdinal
                } else {
                    unrepairedPictures += 1
                    return nil
                }
                mayAdvanceAfterUnplacedPicture = decodeOrdinal == expected
            } else {
                let landingOrdinal = plan.decodeOrdinal(forRawTimestampWithinOneTick: dts)
                guard awaitingReanchor, isKeyframe, let landingOrdinal else {
                    unrepairedPictures += 1
                    return nil
                }
                decodeOrdinal = landingOrdinal
            }
            guard let pictureOrderCount,
                  pictureOrderCount >= 0,
                  pictureOrderCount % plan.pocStep == 0 else {
                // A parser miss on precisely the expected next packet still consumed one decode
                // position. A larger exact jump is not committed until full placement succeeds,
                // otherwise one bad-but-on-lattice timestamp can poison every packet behind it.
                if mayAdvanceAfterUnplacedPicture {
                    lastRationalDecodeOrdinal = decodeOrdinal
                }
                if isKeyframe {
                    sequenceAnchorDTS = nil
                    sequenceBaseOrdinal = nil
                    awaitingReanchor = true
                }
                unrepairedPictures += 1
                return nil
            }
            let displayIndex = pictureOrderCount / plan.pocStep
            if isKeyframe, pictureOrderCount == 0 {
                sequenceBaseOrdinal = decodeOrdinal
                sequenceAnchorDTS = dts
                awaitingReanchor = false
            } else if awaitingReanchor, isKeyframe {
                let (baseOrdinal, overflow) = decodeOrdinal
                    .subtractingReportingOverflow(displayIndex)
                guard !overflow else {
                    unrepairedPictures += 1
                    return nil
                }
                sequenceBaseOrdinal = baseOrdinal
                sequenceAnchorDTS = dts
                awaitingReanchor = false
            }
            guard let sequenceBaseOrdinal, !awaitingReanchor else {
                unrepairedPictures += 1
                return nil
            }
            let (presentationOrdinal, ordinalOverflow) = sequenceBaseOrdinal
                .addingReportingOverflow(displayIndex)
            guard !ordinalOverflow,
                  let pts = plan.presentationTimestamp(frameOrdinal: presentationOrdinal),
                  let newDTS = plan.repairedDecodeTimestamp(decodeOrdinal: decodeOrdinal),
                  pts >= newDTS else {
                unrepairedPictures += 1
                return nil
            }
            lastRationalDecodeOrdinal = decodeOrdinal
            repairedPictures += 1
            return (pts, newDTS)
        }

        private static func isWithinOneTick(_ value: Int64, of expected: Int64) -> Bool {
            if value >= expected {
                let (difference, overflow) = value.subtractingReportingOverflow(expected)
                return !overflow && difference <= 1
            }
            let (difference, overflow) = expected.subtractingReportingOverflow(value)
            return !overflow && difference <= 1
        }
    }
}

/// Reads a picture order count per packet with libavcodec's H.264 parser. No decoder is opened and
/// no picture is reconstructed: the parser walks the slice header, which is where display order
/// lives. It takes MP4's length-prefixed AVCC payload directly as long as the codec context carries
/// the `avcC` extradata, so no Annex-B conversion sits in the packet path.
final class H264PictureOrderReader {
    private var parser: UnsafeMutablePointer<AVCodecParserContext>?
    private var context: UnsafeMutablePointer<AVCodecContext>?

    init?(codecParameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational) {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264),
              let context = avcodec_alloc_context3(codec) else { return nil }
        self.context = context
        guard avcodec_parameters_to_context(context, codecParameters) >= 0 else { return nil }
        context.pointee.pkt_timebase = timeBase
        guard let parser = av_parser_init(Int32(AV_CODEC_ID_H264.rawValue)) else { return nil }
        self.parser = parser
        // MP4 samples are whole access units; without this the parser hunts for start codes that
        // length-prefixed payloads do not contain.
        parser.pointee.flags |= Int32(PARSER_FLAG_COMPLETE_FRAMES)
    }

    deinit {
        if let parser { av_parser_close(parser) }
        var owned = context
        avcodec_free_context(&owned)
    }

    /// Drops the parser's carried state after a discontinuity, the way libavformat's own seek does
    /// (`ff_read_frame_flush` closes the stream parser). A picture order count is computed against
    /// the previous picture's, so a parser that survived a jump can answer for the wrong sequence.
    func reset() {
        guard let parser else { return }
        av_parser_close(parser)
        self.parser = av_parser_init(Int32(AV_CODEC_ID_H264.rawValue))
        self.parser?.pointee.flags |= Int32(PARSER_FLAG_COMPLETE_FRAMES)
    }

    /// nil when the parser could not resolve this access unit.
    func pictureOrderCount(for packet: UnsafeMutablePointer<AVPacket>) -> Int64? {
        guard let parser, let context, let data = packet.pointee.data, packet.pointee.size > 0 else {
            return nil
        }
        var outData: UnsafeMutablePointer<UInt8>?
        var outSize: Int32 = 0
        let consumed = av_parser_parse2(
            parser, context, &outData, &outSize,
            data, packet.pointee.size,
            packet.pointee.pts, packet.pointee.dts, packet.pointee.pos
        )
        guard consumed >= 0, outSize > 0 else { return nil }
        return Int64(parser.pointee.output_picture_number)
    }
}

/// Per-demuxer runtime for the #409 repair: samples the head, decides once, then rewrites.
///
/// Sampling holds packets instead of rewinding the source. A rewind is not available to every
/// session (a custom source cannot be reopened, and a probe demuxer handed to playback must not be
/// left at an unknown position), and it would pay for the read twice; holding the first packets
/// costs one small queue and keeps the decision on the same bytes playback is about to consume.
/// Every packet is held, not just video, so the interleaving the container chose survives the
/// verdict.
final class H264CompositionOffsetRepairSession {

    enum Phase: Equatable { case sampling, repairing, off }

    private(set) var phase: Phase = .sampling
    private let streamIndex: Int32
    private let videoDelay: Int
    private let streamStartTime: Int64
    private let ladderStart: Int64
    private let streamFrameCount: Int64
    private let averageCadence: H264CompositionOffsetRepair.Cadence?
    private let nominalCadence: H264CompositionOffsetRepair.Cadence?
    private var reader: H264PictureOrderReader?
    private var rewriter: H264CompositionOffsetRepair.Rewriter?
    private var samples: [H264CompositionOffsetRepair.Sample] = []
    private var held: [(packet: UnsafeMutablePointer<AVPacket>, pictureOrderCount: Int64?)] = []
    private var heldBytes = 0
    private var verdictDescription = "sampling"

    /// nil unless this stream is the exact shape the defect needs: ISO-BMFF, H.264, and a bitstream
    /// that declares reordered pictures. Everything else never sees a parser or a held packet.
    init?(
        containerFormatName: String?,
        stream: UnsafeMutablePointer<AVStream>,
        streamIndex: Int32,
        ladderStart: Int64
    ) {
        let containers = containerFormatName?.split(separator: ",") ?? []
        guard containers.contains("mov") || containers.contains("mp4") else { return nil }
        guard let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_id == AV_CODEC_ID_H264,
              codecpar.pointee.video_delay > 0,
              let reader = H264PictureOrderReader(
                codecParameters: codecpar, timeBase: stream.pointee.time_base)
        else { return nil }
        self.streamIndex = streamIndex
        self.videoDelay = Int(codecpar.pointee.video_delay)
        self.streamStartTime = stream.pointee.start_time
        self.ladderStart = ladderStart
        self.streamFrameCount = stream.pointee.nb_frames
        // avg_frame_rate summarizes the complete stream and can expose a long-period cadence that a
        // short STTS prefix aliases. r_frame_rate is a nominal coded rate, so it is only a fallback
        // when the average is unavailable; classification still requires two exact sampled periods.
        averageCadence = H264CompositionOffsetRepair.Cadence(
            timeBase: stream.pointee.time_base,
            frameRate: stream.pointee.avg_frame_rate
        )
        nominalCadence = H264CompositionOffsetRepair.Cadence(
            timeBase: stream.pointee.time_base,
            frameRate: stream.pointee.r_frame_rate
        )
        self.reader = reader
    }

    deinit {
        for entry in held {
            var owned: UnsafeMutablePointer<AVPacket>? = entry.packet
            trackedPacketFree(&owned)
        }
    }

    var hasHeldPackets: Bool { !held.isEmpty }

    /// True once the sample has produced a verdict; until then no consumer may read an axis from
    /// this demuxer, because the repair may still be about to move it.
    var isDecided: Bool { phase != .sampling }

    var isRepairing: Bool { phase == .repairing }

    /// Maps the container's own keyframe index onto exactly the same decode axis as packets. A
    /// scalar offset is sufficient for an integer cadence; fractional cadence must recover the
    /// global frame ordinal or an index/packet pair can disagree by one tick at a rounding boundary.
    func repairedDecodeTimestamp(_ timestamp: Int64) -> Int64? {
        guard phase == .repairing, let rewriter else { return nil }
        return rewriter.plan.repairedDecodeTimestamp(timestamp)
    }

    /// Returns true when the packet was taken over by the session and must not be emitted yet.
    /// A packet the session keeps is owned by it until `dequeue()` hands it back.
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        switch phase {
        case .off:
            return false
        case .repairing:
            guard packet.pointee.stream_index == streamIndex else { return false }
            applyRepair(to: packet, pictureOrderCount: reader?.pictureOrderCount(for: packet))
            return false
        case .sampling:
            var pictureOrderCount: Int64?
            if packet.pointee.stream_index == streamIndex {
                pictureOrderCount = reader?.pictureOrderCount(for: packet)
                samples.append(
                    H264CompositionOffsetRepair.Sample(
                        dts: packet.pointee.dts,
                        pts: packet.pointee.pts,
                        pictureOrderCount: pictureOrderCount ?? -1,
                        isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                    )
                )
            }
            held.append((packet, pictureOrderCount))
            heldBytes += Int(max(0, packet.pointee.size))
            if samples.count >= H264CompositionOffsetRepair.sampleTarget
                || heldBytes >= H264CompositionOffsetRepair.sampleByteBudget
                || held.count >= H264CompositionOffsetRepair.heldPacketCeiling
                || earlyHealthyVerdict {
                decide()
            }
            return true
        }
    }

    /// A healthy file usually proves itself on its first packet, and paying twelve packets of hold
    /// for it would tax every well-formed MP4 with B-frames on the platform.
    private var earlyHealthyVerdict: Bool {
        guard let last = samples.last else { return false }
        return last.pts != Int64.min && last.dts != Int64.min && last.pts != last.dts
    }

    /// EOF during sampling. Decides on what is there, so the held packets are still delivered.
    func endOfStream() {
        if phase == .sampling { decide() }
    }

    func noteSeek() {
        // The held packets belong to the position that was abandoned, in EVERY phase, not just while
        // the sample is still open: a settled verdict leaves the sample it read in the queue, and
        // `dequeue()` hands that queue out ahead of anything read after the seek. Dropping it only
        // during `.sampling` republished the old position's packets at the landing, which on a healthy
        // file (verdict `.off`, sample still held) put two duplicate pictures into the stream a
        // producer had already emitted.
        dropHeldPackets()
        switch phase {
        case .sampling:
            // The sample restarts where the source now stands.
            samples.removeAll(keepingCapacity: true)
        case .repairing:
            rewriter?.noteSeek()
            reader?.reset()
        case .off:
            break
        }
    }

    private func dropHeldPackets() {
        for entry in held {
            var owned: UnsafeMutablePointer<AVPacket>? = entry.packet
            trackedPacketFree(&owned)
        }
        held.removeAll(keepingCapacity: true)
        heldBytes = 0
    }

    /// Puts a packet at the head of the queue. Used by the demuxer when a sample ends on a packet
    /// the session did not take over, so decode order survives the handover.
    func enqueueFront(_ packet: UnsafeMutablePointer<AVPacket>) {
        held.insert((packet, nil), at: 0)
    }

    func dequeue() -> UnsafeMutablePointer<AVPacket>? {
        guard phase != .sampling, !held.isEmpty else { return nil }
        return held.removeFirst().packet
    }

    var summary: String {
        var text = "phase=\(phase) verdict=\(verdictDescription)"
        if let rewriter {
            text += " repaired=\(rewriter.repairedPictures) unrepaired=\(rewriter.unrepairedPictures)"
        }
        return text
    }

    private func decide() {
        let verdict = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: videoDelay,
            streamStartTime: streamStartTime,
            ladderStart: ladderStart,
            streamFrameCount: streamFrameCount,
            averageCadence: averageCadence,
            nominalCadence: nominalCadence
        )
        switch verdict {
        case .repair(let plan):
            verdictDescription = "repair step=\(plan.step) lead=\(plan.decodeLead) "
                + "shift=\(plan.shift) pocStep=\(plan.pocStep)"
            phase = .repairing
            var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
            for entry in held where entry.packet.pointee.stream_index == streamIndex {
                applyRepair(to: entry.packet, pictureOrderCount: entry.pictureOrderCount, using: &rewriter)
            }
            self.rewriter = rewriter
            EngineLog.emit(
                "[Demuxer] #409 missing H.264 composition offsets confirmed on stream \(streamIndex): "
                + "\(verdictDescription) samples=\(samples.count)",
                category: .demux
            )
        case .healthy:
            verdictDescription = "healthy"
            disarm()
        case .inconclusive(let reason):
            verdictDescription = "inconclusive (\(reason))"
            // Only worth a line when the stream looked like a candidate: a file that simply carries
            // composition offsets is the normal case and says nothing.
            EngineLog.emit(
                "[Demuxer] #409 composition-offset probe on stream \(streamIndex) left the stream "
                + "untouched: \(reason) (samples=\(samples.count))",
                category: .demux
            )
            disarm()
        }
        samples.removeAll(keepingCapacity: false)
    }

    private func disarm() {
        phase = .off
        reader = nil
    }

    private func applyRepair(
        to packet: UnsafeMutablePointer<AVPacket>,
        pictureOrderCount: Int64?
    ) {
        guard var rewriter else { return }
        applyRepair(to: packet, pictureOrderCount: pictureOrderCount, using: &rewriter)
        self.rewriter = rewriter
    }

    private func applyRepair(
        to packet: UnsafeMutablePointer<AVPacket>,
        pictureOrderCount: Int64?,
        using rewriter: inout H264CompositionOffsetRepair.Rewriter
    ) {
        guard let repaired = rewriter.rewrite(
            dts: packet.pointee.dts,
            pictureOrderCount: pictureOrderCount,
            isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0)
        else { return }
        packet.pointee.pts = repaired.pts
        packet.pointee.dts = repaired.dts
    }
}
