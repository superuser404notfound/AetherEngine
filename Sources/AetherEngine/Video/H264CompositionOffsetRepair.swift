import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

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
///     PTS = (DTS of the picture that opened this coded video sequence) + shift + displayIndex * step
///     DTS = DTS + shift - videoDelay * step
///
/// Both forms are expressed relative to the packet's own timestamps, never to a counter, so a demuxer
/// that starts mid-file (a resume seek) and one that starts at byte 0 produce the same axis for the
/// same picture. Pulling DTS back by the decode lead is what keeps `PTS >= DTS`, the invariant the
/// fMP4 muxer and its output sanitizer enforce; a healthy file carries exactly the same negative head
/// (the twin's first packet is `pts=0 dts=-2002`), so this is the shape the pipeline already handles.
///
/// A picture is not always a whole number of ticks long, and then no `step` describes the ladder: the
/// sample table has to alternate between the two neighbouring tick counts, and the file's second
/// report against this issue was exactly that (`200202/5` ticks at a 1200000 timescale). Such a ladder
/// carries something a uniform one cannot, its rounding pattern, which is the phase of the lattice it
/// was quantized from. Reading that phase turns `displayIndex * step` into a place on the lattice and
/// the arithmetic above into its whole-tick special case. The one thing the ladder cannot say is how
/// far it runs ahead of presentation, so that still comes from the container header.
///
/// Verified against four fixture pairs (498 packets, both edit-list shapes, both whole and fractional
/// cadences, 10 IDR boundaries): every repaired packet matches its healthy twin's PTS and DTS exactly.
enum H264CompositionOffsetRepair {

    /// One sampled picture. Deliberately values only, so the decision is testable without FFmpeg.
    struct Sample: Equatable, Sendable {
        var dts: Int64
        var pts: Int64
        var pictureOrderCount: Int64
        var isKeyframe: Bool
    }

    /// A frame cadence that is constant but does not land on a whole number of ticks. #409's second
    /// asset is one: at `time_base=1/1200000` its pictures are `200202/5` ticks apart, so the sample
    /// table can only alternate between 40040 and 40041 in a five-picture cycle. Nothing about the
    /// defect changes, only the ladder the repair has to read.
    struct Cadence: Equatable, Sendable {
        let numerator: Int64
        let denominator: Int64

        init?(numerator: Int64, denominator: Int64) {
            guard numerator > 0, denominator > 0 else { return nil }
            let divisor = H264CompositionOffsetRepair.greatestCommonDivisor(numerator, denominator)
            self.numerator = numerator / divisor
            self.denominator = denominator / divisor
        }

        /// Whole ticks per picture, rounded down.
        var wholeTicks: Int64 { numerator / denominator }

        /// Where the picture with this ordinal sits, relative to ordinal zero. Ties round away from
        /// zero, which is how FFmpeg rescales, so the lattice reproduces what a healthy muxer wrote
        /// for the same source rather than something a half tick beside it.
        func timestamp(at ordinal: Int64) -> Int64? {
            Self.roundedQuotient(ordinal, times: numerator, dividedBy: denominator)
        }

        /// The inverse, and it is exact for every point the lattice produced: a lattice value is at
        /// most half a tick away from the real product, so dividing it by a cadence of two ticks or
        /// more can never reach the neighbouring ordinal. Cadences below that are refused for this
        /// reason, not for a lack of precision in the multiply.
        func ordinal(at timestamp: Int64) -> Int64? {
            Self.roundedQuotient(timestamp, times: denominator, dividedBy: numerator)
        }

        /// `round(value * factor / divisor)` at full width, so a long timeline cannot overflow the
        /// intermediate product and land the repair on a wrapped timestamp.
        private static func roundedQuotient(_ value: Int64, times factor: Int64, dividedBy divisor: Int64) -> Int64? {
            guard value != Int64.min, factor > 0, divisor > 0 else { return nil }
            let negative = value < 0
            let magnitude = UInt64(negative ? -value : value)
            let product = magnitude.multipliedFullWidth(by: UInt64(factor))
            guard product.high < UInt64(divisor) else { return nil }
            let division = UInt64(divisor).dividingFullWidth(product)
            var quotient = division.quotient
            if division.remainder * 2 >= UInt64(divisor) {
                let (rounded, overflow) = quotient.addingReportingOverflow(1)
                guard !overflow else { return nil }
                quotient = rounded
            }
            guard quotient <= UInt64(Int64.max) else { return nil }
            return negative ? -Int64(quotient) : Int64(quotient)
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
        /// Set only when the ladder is a quantization of a fractional cadence. `step` then carries
        /// the rounded cadence and still describes the stream to within a tick, which is what the
        /// arithmetic falls back to; the lattice is what reproduces the muxer exactly.
        var cadence: Cadence?
        /// Where lattice ordinal 0 sits on this timeline, and which lattice ordinal the first
        /// sampled picture sits on. A whole-tick ladder has no phase to speak of; a quantized one
        /// does, and its rounding pattern is the only place that phase is written down. It is not
        /// implied by anything else: the reporting asset for this case sits on phase 2 while its
        /// reorder delay is 1.
        var latticeOrigin: Int64 = 0
        var ladderPhase: Int64 = 0
        /// How many ordinals the decode ladder runs ahead of presentation: 0 when the writer left the
        /// ladder on the presentation axis, `videoDelay` when it kept the edit list that trims the
        /// reorder head, and the values between when it trims part of one. The ladder cannot say
        /// which, so this is read from the container the same way `shift` is.
        var ladderOrdinalOffset: Int64 = 0
        /// Set when the writer's decode ladder is not a ladder at all and `step` came from the stream's
        /// average frame rate instead (`nominalStep`). DTS is then rebuilt from the decode ordinal as
        /// well, because the container's DTS of a B picture can sit after the presentation time it
        /// belongs to.
        var synthesizesDecodeLadder = false
        /// The exact picture length of a synthesized ladder, when the rate is known as a fraction (23 fps
        /// is 90000/23 ticks at 90 kHz). Offsets inside a sequence and the length of a sequence are read
        /// off it, so a rounded `step` never adds up across a long file.
        var pictureCadence: Cadence?
        /// The reorder delay in pictures, which `decodeLead` is the length of. Only a synthesized
        /// ladder reads it; 0 on every other plan.
        var decodeLeadPictures: Int64 = 0

        /// The most a synthesized ladder places a keyframe before its written decode time: the reorder
        /// delay plus two and a half pictures, which is how late the writers this ladder describes
        /// were measured to push an IDR (four pictures on the 29 fps reporting asset). Continuing a
        /// sequence and landing on a seek both stay inside it, so the container index, read on the
        /// written axis, names every keyframe to within this many ticks. 0 for every other plan,
        /// which keeps each keyframe exactly where the index says.
        var keyframeAdvanceLimit: Int64 {
            guard synthesizesDecodeLadder else { return 0 }
            let (pictures, pictureOverflow) = step.multipliedReportingOverflow(by: 2)
            let (limit, limitOverflow) = decodeLead.addingReportingOverflow(pictures)
            let (total, totalOverflow) = limit.addingReportingOverflow(step / 2)
            return pictureOverflow || limitOverflow || totalOverflow ? 0 : total
        }

        /// Ticks from a sequence's anchor to its picture `ordinal`, on `pictureCadence` when there is one.
        func pictureOffset(_ ordinal: Int64) -> Int64? {
            if let pictureCadence { return pictureCadence.timestamp(at: ordinal) }
            let (offset, overflow) = ordinal.multipliedReportingOverflow(by: step)
            return overflow ? nil : offset
        }

        /// The timestamp of a presentation ordinal, nil unless this plan carries a lattice.
        func presentationTimestamp(ordinal: Int64) -> Int64? {
            guard let cadence else { return nil }
            let (phased, phaseOverflow) = ordinal.addingReportingOverflow(ladderPhase)
            let (placed, placeOverflow) = phased.addingReportingOverflow(ladderOrdinalOffset)
            guard !phaseOverflow, !placeOverflow, let offset = cadence.timestamp(at: placed) else {
                return nil
            }
            let (timestamp, overflow) = latticeOrigin.addingReportingOverflow(offset)
            return overflow ? nil : timestamp
        }

        /// Reads a ladder timestamp back into the presentation ordinal of the picture it belongs to.
        /// nil when the timestamp is not on the lattice, which is deliberate: a ladder that drifted
        /// off its own cadence must fall back to the scalar anchor instead of being placed a whole
        /// picture away from where it belongs.
        func presentationOrdinal(ladderTimestamp: Int64) -> Int64? {
            guard let cadence else { return nil }
            let (offset, offsetOverflow) = ladderTimestamp.subtractingReportingOverflow(latticeOrigin)
            guard !offsetOverflow, let ordinal = cadence.ordinal(at: offset),
                  cadence.timestamp(at: ordinal) == offset else { return nil }
            let (presentation, overflow) = ordinal.subtractingReportingOverflow(ladderPhase)
            return overflow ? nil : presentation
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
    /// How far the sample may grow when the first `sampleTarget` pictures never reorder. A writer can
    /// open every GOP on a run of P pictures (measured: twelve, then the first B picture), and without
    /// a regression the head proves nothing either way.
    static let extendedSampleTarget = 48
    /// Pictures a seek onto a synthesized ladder holds before it places the landing. The writer only
    /// ever pushes a picture later, so the earliest of `written time - offset of its display slot` over
    /// the first pictures is a better start than the keyframe alone: measured on the three reporting
    /// files, 8 pictures cut the spread of the landing from 0.5 to 4.3 pictures to -0.9 to 1.3.
    static let landingEnvelopePictures = 8
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
        nominalStep: Int64? = nil,
        rateCadence: Cadence? = nil
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

        // A ladder that advances by one constant is what lets a rank be turned back into a timestamp
        // without buffering packets. A picture whose length is not a whole number of ticks cannot
        // produce such a ladder at all: the sample table has to alternate between the two
        // neighbouring counts, and the cycle it repeats names the fraction it is quantizing (#409's
        // retest asset: 200202/5 ticks at a 1200000 timescale, cycling 40041,40040,40040,40041,40040).
        // Everything else, genuine variable frame timing included, is left alone rather than guessed at.
        var deltas: [Int64] = []
        deltas.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            let (delta, overflow) = samples[index].dts
                .subtractingReportingOverflow(samples[index - 1].dts)
            guard !overflow, delta > 0 else {
                return .inconclusive("decode timestamps do not advance")
            }
            deltas.append(delta)
        }
        guard let shortestStep = deltas.min(), let longestStep = deltas.max() else {
            return .inconclusive("no ladder step")
        }
        var cadence: Cadence?
        var step = shortestStep
        var synthesizesDecodeLadder = false
        if shortestStep != longestStep {
            if longestStep - shortestStep == 1,
               let quantized = quantizedCadence(deltas: deltas),
               let roundedStep = quantized.timestamp(at: 1) {
                cadence = quantized
                step = roundedStep
            } else if let nominalStep,
                      nominalLadderFits(samples: samples, step: nominalStep, videoDelay: videoDelay) {
                // A writer that dropped `ctts` and then forced its decode-order presentation times to
                // be monotonic (each B picture pushed one third of a frame past the anchor decoded
                // before it) leaves no ladder to read a step from, but the pictures still come at the
                // stream's constant rate.
                step = nominalStep
                synthesizesDecodeLadder = true
            } else {
                return .inconclusive("decode ladder is not uniform")
            }
        }
        guard step > 0 else { return .inconclusive("no ladder step") }

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
        // A hierarchical mini-GOP longer than the reorder delay sends its anchor further ahead than
        // that allowance (#699's HEVC stream: POC 15 decoded while 11 to 14 are still to come, at
        // delay 2), so the window may instead prove itself by a decode-order prefix of at least
        // `minimumSamples` pictures that fills its display range exactly, which is the stricter test.
        guard let maxIndex = displayIndices.max(), let minIndex = displayIndices.min(),
              maxIndex - minIndex + 1 <= Int64(samples.count + videoDelay + 1)
                || hasContiguousPrefix(samples.map { $0.pictureOrderCount / pocStep }) else {
            return .inconclusive("display indices do not fill the sampled window")
        }

        // The average frame rate is only an estimate (short files, rounded durations: a 60-picture
        // 29.97 clip reports 29.80). When the writer left its anchors on the presentation axis they give
        // the exact step. The reporting file pushed its anchors as well (a P picture 1001 ticks after the
        // P before it), so they agree on nothing; the step is then the stream's picture rate
        // (`rateCadence`), and a head with neither is left alone.
        var pictureCadence: Cadence?
        if synthesizesDecodeLadder {
            if let measured = anchorStep(samples: samples, pocStep: pocStep) {
                step = measured
                pictureCadence = Cadence(numerator: measured, denominator: 1)
            } else if let rateCadence, let rounded = rateCadence.timestamp(at: 1), rounded >= 2 {
                step = rounded
                pictureCadence = rateCadence
            } else {
                return .inconclusive("anchors do not agree on a step")
            }
        }

        // The reorder head is one decode lead long, and with a fractional cadence that lead is a
        // rounded distance on the lattice rather than a multiple of a whole step.
        let ladderOrigin = ladderStart == Int64.min ? (samples.first?.dts ?? Int64.min) : ladderStart
        let decodeLead: Int64
        if let cadence {
            guard let head = cadence.timestamp(at: -Int64(videoDelay)), head < 0 else {
                return .inconclusive("cadence does not describe a reorder head")
            }
            decodeLead = -head
        } else if let pictureCadence {
            guard let lead = pictureCadence.timestamp(at: Int64(videoDelay)) else {
                return .inconclusive("reorder head does not fit the timeline")
            }
            decodeLead = lead
        } else {
            let (lead, overflow) = Int64(videoDelay).multipliedReportingOverflow(by: step)
            guard !overflow else { return .inconclusive("reorder head does not fit the timeline") }
            decodeLead = lead
        }
        guard decodeLead > 0 else { return .inconclusive("no decode lead") }
        // A synthesized ladder anchors every coded video sequence on its keyframe's DTS, so the shift
        // is simply what puts the first keyframe on the presentation start. The writer that produces
        // this shape can leave that keyframe more than one decode lead ahead (measured: 12012 ticks at
        // a 3003 step and delay 2), so it is bounded by a generous number of pictures instead of the
        // decode lead.
        let shift = synthesizesDecodeLadder
            ? nominalShift(streamStartTime: streamStartTime, ladderStart: ladderOrigin, step: step)
            : presentationShift(
                streamStartTime: streamStartTime, ladderStart: ladderOrigin, decodeLead: decodeLead)

        // A fractional cadence is read back off a lattice, so the lattice has to be located first,
        // and that takes two readings the ladder cannot both give. The phase and the origin come from
        // the ladder itself: its rounding pattern is the phase, and only one phase of the period can
        // reproduce the sampled window picture for picture. How far the ladder runs ahead of
        // presentation does NOT come from the ladder, because every alignment fits it equally well;
        // that is the same question `presentationShift` already answers from the container header,
        // and here it has to resolve to a whole number of ordinals to be usable at all.
        var latticeOrigin: Int64 = 0
        var ladderPhase: Int64 = 0
        var ladderOrdinalOffset: Int64 = 0
        if let cadence {
            guard let fit = latticeFit(samples: samples, cadence: cadence) else {
                return .inconclusive(
                    "ladder does not follow one \(cadence.numerator)/\(cadence.denominator) phase")
            }
            ladderPhase = fit.phase
            latticeOrigin = fit.origin
            let alignment = (0...Int64(videoDelay)).first { candidate in
                cadence.timestamp(at: -candidate).map { -$0 } == shift
            }
            guard let alignment else {
                return .inconclusive("reorder head is not a whole number of pictures")
            }
            ladderOrdinalOffset = alignment
        }

        return .repair(
            Plan(
                step: step,
                decodeLead: decodeLead,
                shift: shift,
                pocStep: pocStep,
                cadence: cadence,
                latticeOrigin: latticeOrigin,
                ladderPhase: ladderPhase,
                ladderOrdinalOffset: ladderOrdinalOffset,
                synthesizesDecodeLadder: synthesizesDecodeLadder,
                pictureCadence: pictureCadence,
                decodeLeadPictures: synthesizesDecodeLadder ? Int64(videoDelay) : 0
            )
        )
    }

    /// Ticks per picture from the stream's average frame rate, rounded. nil when the rate is missing or
    /// describes a picture shorter than two ticks.
    static func nominalFrameStep(frameRate: AVRational, timeBase: AVRational) -> Int64? {
        guard frameRate.num > 0, frameRate.den > 0, timeBase.num > 0, timeBase.den > 0 else { return nil }
        let ticks = (Double(timeBase.den) * Double(frameRate.den)) / (Double(timeBase.num) * Double(frameRate.num))
        guard ticks.isFinite, ticks >= 2, ticks < Double(Int64.max / 4) else { return nil }
        return Int64(ticks.rounded())
    }

    /// Frame rates a camera, encoder or broadcast chain actually produces: every whole rate up to 240,
    /// and the NTSC ones (`n * 1000 / 1001`).
    static let standardFrameRates: [(num: Int64, den: Int64)] =
        (1...240).map { (Int64($0), 1) } + [24, 30, 48, 60, 120, 240].map { (Int64($0) * 1000, 1001) }

    /// The picture length, as an exact fraction of a tick, of the standard frame rate closest to
    /// `estimate`, within 1%. 29.97 and 30 are both that close to either, so the nearer one wins and a
    /// tie names neither. nil when no standard rate is that close.
    static func standardFrameCadence(near estimate: Int64, timeBase: AVRational) -> Cadence? {
        guard estimate >= 2, timeBase.num > 0, timeBase.den > 0 else { return nil }
        let ranked = standardFrameRates.map { rate -> (rate: (num: Int64, den: Int64), distance: Double) in
            let ticks = Double(timeBase.den) * Double(rate.den) / (Double(timeBase.num) * Double(rate.num))
            return (rate, abs(ticks - Double(estimate)))
        }.sorted { $0.distance < $1.distance }
        guard let nearest = ranked.first, nearest.distance * 100 <= Double(estimate) else { return nil }
        if ranked.count > 1, ranked[1].distance == nearest.distance { return nil }
        return pictureCadence(rate: nearest.rate, timeBase: timeBase)
    }

    /// The picture rate a synthesized ladder is rebuilt at. The bitstream states it (the H.264 or HEVC
    /// VUI timing the parser reads into the codec context): on all three reporting files it named the
    /// exact rate (23, 29.97, 29.0002 fps), where the average rate of a short file with a pushed tail
    /// cannot tell 24 from 23.976. It is trusted only within 1% of the average rate, and snapped to the
    /// nearest standard rate within 0.01% (29.97 and 30 are 0.1% apart and must stay apart). Without
    /// it, the standard rate nearest the average rate.
    static func rateCadence(bitstreamRate: AVRational?, estimate: Int64, timeBase: AVRational) -> Cadence? {
        guard timeBase.num > 0, timeBase.den > 0 else { return nil }
        if let rate = bitstreamRate, rate.num > 0, rate.den > 0,
           let stated = pictureCadence(rate: (Int64(rate.num), Int64(rate.den)), timeBase: timeBase) {
            let ticks = Double(stated.numerator) / Double(stated.denominator)
            if abs(ticks - Double(estimate)) * 100 <= Double(estimate) {
                let distance = { (cadence: Cadence) in abs(Double(cadence.numerator) / Double(cadence.denominator) - ticks) }
                let standard = standardFrameRates.compactMap { pictureCadence(rate: $0, timeBase: timeBase) }
                    .filter { distance($0) * 10_000 <= ticks }
                    .min { distance($0) < distance($1) }
                return standard ?? stated
            }
        }
        return standardFrameCadence(near: estimate, timeBase: timeBase)
    }

    /// Ticks per picture at `rate` in `timeBase`, as a reduced fraction. nil when it overflows or is
    /// shorter than two ticks, which the lattice arithmetic refuses.
    static func pictureCadence(rate: (num: Int64, den: Int64), timeBase: AVRational) -> Cadence? {
        let (numerator, overflow) = Int64(timeBase.den).multipliedReportingOverflow(by: rate.den)
        let (denominator, denominatorOverflow) = Int64(timeBase.num).multipliedReportingOverflow(by: rate.num)
        guard !overflow, !denominatorOverflow, let cadence = Cadence(numerator: numerator, denominator: denominator),
              cadence.wholeTicks >= 2 else { return nil }
        return cadence
    }

    /// Whether a non-uniform sampled ladder still spans the time its pictures would take at `step`. The
    /// writer's forced-monotonic ladder runs ahead of that by at most the reorder head plus the anchor
    /// it pushed past (measured 3.5 pictures on the reporting file at delay 2), and falls behind only
    /// by what the next anchor has not yet reclaimed; a genuinely variable-rate head misses it by far
    /// more. `step` is rounded, so each bound also gives a tick per picture: a third reporting file at
    /// 29 fps (3103.45 ticks) ran exactly that four pictures ahead and missed the upper bound by 3.
    static func nominalLadderFits(samples: [Sample], step: Int64, videoDelay: Int) -> Bool {
        guard step >= 2, let first = samples.first?.dts, let last = samples.last?.dts, last > first else {
            return false
        }
        let pictures = Int64(samples.count - 1)
        let slack = Int64(videoDelay + 2)
        let (span, overflow) = last.subtractingReportingOverflow(first)
        let (low, lowOverflow) = max(0, pictures - slack).multipliedReportingOverflow(by: step)
        let (high, highOverflow) = (pictures + slack).multipliedReportingOverflow(by: step)
        guard !overflow, !lowOverflow, !highOverflow else { return false }
        return span >= low - pictures && span <= high + pictures
    }

    /// Ticks per picture read off the sampled anchors, the pictures that display later than everything
    /// decoded before them. A forced-monotonic writer leaves their timestamps on the presentation axis,
    /// so each one sits `displayIndex * step` after the opening keyframe. nil unless every anchor
    /// agrees to within a tick per picture.
    static func anchorStep(samples: [Sample], pocStep: Int64) -> Int64? {
        guard pocStep > 0, let first = samples.first, first.pictureOrderCount == 0 else { return nil }
        var anchors: [(index: Int64, offset: Int64)] = []
        var latest: Int64 = 0
        for sample in samples.dropFirst() where sample.pictureOrderCount > latest {
            latest = sample.pictureOrderCount
            let (offset, overflow) = sample.dts.subtractingReportingOverflow(first.dts)
            guard !overflow, offset > 0, sample.pictureOrderCount % pocStep == 0 else { return nil }
            anchors.append((sample.pictureOrderCount / pocStep, offset))
        }
        guard let farthest = anchors.last, farthest.index > 0 else { return nil }
        let step = (farthest.offset + farthest.index / 2) / farthest.index
        guard step >= 2 else { return nil }
        for anchor in anchors {
            let (expected, overflow) = anchor.index.multipliedReportingOverflow(by: step)
            guard !overflow, abs(anchor.offset - expected) <= anchor.index + 1 else { return nil }
        }
        return step
    }

    /// Pictures a synthesized ladder's presentation shift may reach (`nominalShift`).
    static let maximumNominalShiftPictures: Int64 = 16

    /// The presentation shift for a synthesized ladder, clamped to
    /// `[0, maximumNominalShiftPictures * step]` so a malformed header cannot drag the video off its
    /// audio.
    static func nominalShift(streamStartTime: Int64, ladderStart: Int64, step: Int64) -> Int64 {
        guard streamStartTime != Int64.min, ladderStart != Int64.min else { return 0 }
        let (raw, overflow) = streamStartTime.subtractingReportingOverflow(ladderStart)
        let (limit, limitOverflow) = maximumNominalShiftPictures.multipliedReportingOverflow(by: step)
        guard !overflow, !limitOverflow else { return 0 }
        return min(max(raw, 0), limit)
    }

    /// True when some decode-order prefix of at least `minimumSamples` display indices covers its
    /// own range without a gap, i.e. a whole number of mini-GOPs closed inside the window.
    static func hasContiguousPrefix(_ indices: [Int64]) -> Bool {
        guard var low = indices.first else { return false }
        var high = low
        for (offset, index) in indices.enumerated() {
            low = min(low, index)
            high = max(high, index)
            if offset + 1 >= minimumSamples, high - low == Int64(offset) { return true }
        }
        return false
    }

    /// Which phase of the cadence the sampled ladder starts on, and where that puts lattice ordinal
    /// zero. Every sampled picture has to land exactly, and the answer has to be the only phase in
    /// the period that does, or the ladder is not evidence of a lattice at all. This is what lets a
    /// sample taken anywhere describe the same axis as a sample taken at the head.
    static func latticeFit(samples: [Sample], cadence: Cadence) -> (phase: Int64, origin: Int64)? {
        guard let head = samples.first?.dts else { return nil }
        var found: (phase: Int64, origin: Int64)?
        for phase in 0..<cadence.denominator {
            guard let headOffset = cadence.timestamp(at: phase) else { continue }
            let (origin, originOverflow) = head.subtractingReportingOverflow(headOffset)
            guard !originOverflow else { continue }
            var fits = true
            for (index, sample) in samples.enumerated() {
                let (ordinal, ordinalOverflow) = phase.addingReportingOverflow(Int64(index))
                guard !ordinalOverflow, let offset = cadence.timestamp(at: ordinal) else {
                    fits = false
                    break
                }
                let (predicted, overflow) = origin.addingReportingOverflow(offset)
                guard !overflow, predicted == sample.dts else {
                    fits = false
                    break
                }
            }
            guard fits else { continue }
            guard found == nil else { return nil }
            found = (phase, origin)
        }
        return found
    }

    /// The cadence a two-valued ladder is quantizing, read from the cycle it repeats. A cycle has to
    /// be seen through twice before it counts, because one pass of a pattern is not evidence that it
    /// is a pattern: a short run of jitter can hold any shape once. The cycle also has to be
    /// primitive, so that the ticks it spans really are its period and not a multiple of a shorter
    /// one, and a picture has to be at least two ticks long, which is what makes reading a timestamp
    /// back into its ordinal exact.
    static func quantizedCadence(deltas: [Int64]) -> Cadence? {
        guard deltas.count >= 4 else { return nil }
        for period in 2...(deltas.count / 2) {
            guard deltas.indices.allSatisfy({ deltas[$0] == deltas[$0 % period] }) else { continue }
            var ticks: Int64 = 0
            for delta in deltas.prefix(period) {
                let (sum, overflow) = ticks.addingReportingOverflow(delta)
                guard !overflow else { return nil }
                ticks = sum
            }
            guard let cadence = Cadence(numerator: ticks, denominator: Int64(period)),
                  cadence.denominator == Int64(period), cadence.wholeTicks >= 2 else { continue }
            return cadence
        }
        return nil
    }

    static func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Applies a confirmed plan packet by packet. Holds exactly one piece of state, the decode
    /// timestamp of the picture that opened the current coded video sequence, because picture order
    /// counts restart at every IDR.
    struct Rewriter {
        let plan: Plan
        /// Set at the first keyframe seen, and again whenever the picture order restarts.
        private(set) var sequenceAnchorDTS: Int64?
        /// The presentation ordinal this sequence starts at, read back off the lattice. Only a
        /// fractional cadence has one; without it the scalar anchor above carries the sequence.
        private(set) var sequenceBaseOrdinal: Int64?
        /// A seek leaves the parser and the sequence anchor behind; the next keyframe re-anchors.
        private var awaitingReanchor = true
        /// Pictures that follow the landing keyframe in decode order but precede it in display
        /// order (an open GOP's leading pictures). The landing is displayed that many slots after
        /// the one it is decoded in, so the re-anchor has to know the count.
        private var landingLeadingPictures: Int64 = 0
        /// The decode slot of the next picture in the current sequence, counted from its anchor. Only a
        /// synthesized ladder reads it.
        private var decodeOrdinal: Int64 = 0
        /// The current sequence was anchored on a seek landing rather than an IDR. The parser was reset
        /// for the seek, so an H.264 open-GOP landing reads its picture order relative to itself (a
        /// non-IDR I picture can come out at -4), and only differences within the sequence mean anything.
        private var anchoredOnLanding = false
        /// The highest display index placed in the current sequence. A synthesized ladder's next IDR
        /// is expected right after it.
        private var sequenceLastDisplayIndex: Int64?
        /// The earliest sequence origin the pictures held after a seek point to (`noteLandingEnvelope`).
        private var landingEnvelopeAnchor: Int64?
        /// The earliest origin, `written DTS - pictureOffset(display index)`, any picture of the
        /// current sequence pointed to. The writer only ever pushes a picture later, so this is the
        /// best reading of where the sequence really started (`continuedSequenceAnchor`).
        private var sequenceEnvelopeOrigin: Int64?
        /// Pictures emitted untouched because no anchor was available or the arithmetic did not
        /// close. Surfaced so a stream this repair does not describe is visible as a number.
        private(set) var unrepairedPictures = 0
        private(set) var repairedPictures = 0

        init(plan: Plan) { self.plan = plan }

        mutating func noteSeek() {
            awaitingReanchor = true
            sequenceAnchorDTS = nil
            sequenceBaseOrdinal = nil
            landingLeadingPictures = 0
            decodeOrdinal = 0
            anchoredOnLanding = false
            sequenceLastDisplayIndex = nil
            landingEnvelopeAnchor = nil
            sequenceEnvelopeOrigin = nil
        }

        /// The earliest origin the held landing pictures imply, `written DTS - pictureOffset(display
        /// index)`, which the landing takes when it is earlier than its keyframe's own. Synthesized
        /// ladders only.
        mutating func noteLandingEnvelope(anchor: Int64?) {
            landingEnvelopeAnchor = plan.synthesizesDecodeLadder ? anchor : nil
        }

        mutating func noteLanding(leadingPictures: Int64) {
            landingLeadingPictures = max(0, leadingPictures)
        }

        /// nil when the picture cannot be placed; the caller then emits it untouched.
        mutating func rewrite(
            dts: Int64,
            pictureOrderCount: Int64,
            isKeyframe: Bool
        ) -> (pts: Int64, dts: Int64)? {
            guard dts != Int64.min, plan.pocStep > 0 else {
                unrepairedPictures += 1
                return nil
            }
            // A picture order of 0 on a keyframe is an IDR: a new coded video sequence starts here
            // and its first picture is also the first to be displayed. After a seek the landing
            // keyframe anchors even if its count is not 0, which is the only way an open-GOP entry
            // point can be placed at all; mid-sequence keyframes must not re-anchor, or every open
            // GOP would restart the display axis under a picture that has not moved.
            if isKeyframe, pictureOrderCount == 0 {
                sequenceAnchorDTS = awaitingReanchor ? dts : continuedSequenceAnchor(keyframeDTS: dts)
                sequenceBaseOrdinal = plan.presentationOrdinal(ladderTimestamp: dts)
                awaitingReanchor = false
                decodeOrdinal = 0
                anchoredOnLanding = false
                sequenceLastDisplayIndex = nil
                sequenceEnvelopeOrigin = nil
            } else if awaitingReanchor, isKeyframe {
                guard pictureOrderCount % plan.pocStep == 0 else {
                    unrepairedPictures += 1
                    return nil
                }
                let landingIndex = pictureOrderCount / plan.pocStep
                // The landing is decoded in slot k and displayed in slot k + leading, so the
                // sequence origin sits `landingIndex - leading` slots before its decode time.
                let (anchorSlots, slotsOverflow) = landingIndex.subtractingReportingOverflow(landingLeadingPictures)
                // A synthesized ladder's keyframe kept its own presentation time (the writer only
                // pushed the B pictures), so its origin is `landingIndex` slots back, not its decode slot.
                let originSlots = plan.synthesizesDecodeLadder ? landingIndex : anchorSlots
                // Audit BIT-101: a 64-bit `tfdt` step and a landing order near -2^31 leave Int64.
                let (landingTicks, productOverflow): (Int64, Bool) = slotsOverflow
                    ? (0, true)
                    : plan.synthesizesDecodeLadder
                        ? plan.pictureOffset(originSlots).map { ($0, false) } ?? (0, true)
                        : originSlots.multipliedReportingOverflow(by: plan.step)
                let (anchor, anchorOverflow) = dts.subtractingReportingOverflow(landingTicks)
                guard !productOverflow, !anchorOverflow else {
                    unrepairedPictures += 1
                    return nil
                }
                // Never further back than a continued sequence could have put it, so the segment plan
                // built from the index still finds this keyframe (`keyframeAdvanceLimit`).
                sequenceAnchorDTS = landingEnvelopeAnchor.map {
                    max(min($0, anchor), anchor &- plan.keyframeAdvanceLimit)
                } ?? anchor
                landingEnvelopeAnchor = nil
                sequenceBaseOrdinal = plan.presentationOrdinal(ladderTimestamp: dts)
                    .flatMap { ordinal -> Int64? in
                        let (base, overflow) = ordinal.subtractingReportingOverflow(originSlots)
                        return overflow ? nil : base
                    }
                awaitingReanchor = false
                decodeOrdinal = anchorSlots
                anchoredOnLanding = true
                sequenceEnvelopeOrigin = nil
                sequenceLastDisplayIndex = nil
            }
            guard let anchor = sequenceAnchorDTS, !awaitingReanchor else {
                unrepairedPictures += 1
                return nil
            }
            let slot = decodeOrdinal
            decodeOrdinal &+= 1
            let acceptsRelativeOrder = plan.synthesizesDecodeLadder && anchoredOnLanding
            guard pictureOrderCount >= 0 || acceptsRelativeOrder, pictureOrderCount % plan.pocStep == 0 else {
                unrepairedPictures += 1
                return nil
            }
            let displayIndex = pictureOrderCount / plan.pocStep
            sequenceLastDisplayIndex = max(sequenceLastDisplayIndex ?? displayIndex, displayIndex)
            if plan.synthesizesDecodeLadder, !anchoredOnLanding, displayIndex >= 0,
               let offset = plan.pictureOffset(displayIndex) {
                let (origin, overflow) = dts.subtractingReportingOverflow(offset)
                if !overflow { sequenceEnvelopeOrigin = min(sequenceEnvelopeOrigin ?? origin, origin) }
            }
            // On a lattice the picture is placed by its ordinal, which reproduces the muxer exactly
            // even where the fraction rounds the other way. Without one, or when the sequence could
            // not be read back onto the lattice, the rounded step still describes the stream to
            // within a tick, and a tick beside the twin beats a picture left in decode order.
            let pts = sequenceBaseOrdinal
                .flatMap { base -> Int64? in
                    let (ordinal, overflow) = base.addingReportingOverflow(displayIndex)
                    return overflow ? nil : plan.presentationTimestamp(ordinal: ordinal)
                }
                ?? plan.pictureOffset(displayIndex).map { anchor &+ plan.shift &+ $0 }
                ?? (anchor &+ plan.shift &+ displayIndex &* plan.step)
            // A synthesized DTS sits `decodeLeadPictures` pictures behind its decode slot on the same
            // lattice as the presentation times, so rounding cannot put it a tick past its own picture.
            let newDTS = plan.synthesizesDecodeLadder
                ? plan.pictureOffset(slot &- plan.decodeLeadPictures).map { anchor &+ plan.shift &+ $0 }
                    ?? (anchor &+ plan.shift &+ slot &* plan.step &- plan.decodeLead)
                : dts &+ plan.shift &- plan.decodeLead
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

        /// Where the IDR that follows a placed sequence starts. A forced-monotonic writer pushes the
        /// keyframe too, and only ever later: on both reporting files the keyframes sat 0 to 4 pictures
        /// after the end of the sequence before them, which left a gap or put the next GOP in front of
        /// the last pictures of this one. A later keyframe therefore continues the sequence right after
        /// its last picture, measured on `pictureCadence`. One that comes earlier than that is the better
        /// reading, because the chain itself started on a pushed keyframe (a seek lands on whatever the
        /// writer left there) and moves back each time a keyframe was pushed less. Within half a tick per
        /// picture of the sequence the keyframe keeps its own time too: the writer's clock does not run
        /// at exactly the stated rate (the third reporting file states 29.0002 fps and writes 29.003),
        /// and following an on-time keyframe is what keeps the chain on it; a chain that only counted
        /// drifted 57 ms behind over 19 minutes and then overlapped where an earlier keyframe pulled it
        /// back. One later than the reorder head plus two and a half pictures is a real
        /// discontinuity: the same file kept its keyframes four pictures (plus up to 31 ticks) past the
        /// sequence before them for a hundred seconds.
        private func continuedSequenceAnchor(keyframeDTS dts: Int64) -> Int64 {
            guard plan.synthesizesDecodeLadder, let previous = sequenceAnchorDTS,
                  let last = sequenceLastDisplayIndex, last >= 0 else { return dts }
            let (pictures, countOverflow) = last.addingReportingOverflow(1)
            guard !countOverflow, let length = plan.pictureOffset(pictures) else { return dts }
            let (expected, expectedOverflow) = previous.addingReportingOverflow(length)
            let (drift, driftOverflow) = dts.subtractingReportingOverflow(expected)
            guard !expectedOverflow, !driftOverflow else { return dts }
            guard drift > pictures / 2 + 1, drift <= plan.keyframeAdvanceLimit else { return dts }
            // Counting alone drifts with the writer's clock, so the continued sequence also leans
            // toward where the pictures it follows say it ends, by at most an eighth of a picture per
            // sequence: too little to see as a gap, enough to follow a clock 0.01% off the stated rate.
            guard let origin = sequenceEnvelopeOrigin else { return expected }
            let (envelope, envelopeOverflow) = origin.addingReportingOverflow(length)
            guard !envelopeOverflow else { return expected }
            let slew = plan.step / 8
            let leaned = expected &+ min(max(envelope &- expected, -slew), slew)
            return min(dts, max(dts &- plan.keyframeAdvanceLimit, leaned))
        }
    }
}

/// Reads a picture order count per packet with libavcodec's H.264 or HEVC parser. No decoder is
/// opened and no picture is reconstructed: the parser walks the slice header, which is where display
/// order lives. It takes MP4's length-prefixed AVCC / HVCC payload directly as long as the codec
/// context carries the `avcC` / `hvcC` extradata, so no Annex-B conversion sits in the packet path.
final class H264PictureOrderReader {
    private var parser: UnsafeMutablePointer<AVCodecParserContext>?
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private let codecID: AVCodecID
    var isFramePicture: Bool { parser?.pointee.picture_structure == AV_PICTURE_STRUCTURE_FRAME }
    /// The picture rate the bitstream's VUI timing states, once the parser has read a parameter set.
    var frameRate: AVRational? {
        guard let rate = context?.pointee.framerate, rate.num > 0, rate.den > 0 else { return nil }
        return rate
    }

    init?(codecParameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational) {
        codecID = codecParameters.pointee.codec_id
        guard codecID == AV_CODEC_ID_H264 || codecID == AV_CODEC_ID_HEVC,
              let codec = avcodec_find_decoder(codecID),
              let context = avcodec_alloc_context3(codec) else { return nil }
        self.context = context
        guard avcodec_parameters_to_context(context, codecParameters) >= 0 else { return nil }
        context.pointee.pkt_timebase = timeBase
        guard let parser = av_parser_init(Int32(codecID.rawValue)) else { return nil }
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
        self.parser = av_parser_init(Int32(codecID.rawValue))
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

/// Per-demuxer runtime for #409. The original all-missing policy decides at the head;
/// a corroborated healthy head also enables bounded detection of later partial-ctts regions.
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
    private let codecName: String
    /// Ticks per picture at the stream's average frame rate, for a head whose decode ladder has no step
    /// of its own.
    private let nominalStep: Int64?
    private let timeBase: AVRational
    private var reader: H264PictureOrderReader?
    private var rewriter: H264CompositionOffsetRepair.Rewriter?
    private let partialRepairCandidate: H264PartialCompositionRepairSession?
    private var monitorsPartialOffsets = false
    private var samples: [H264CompositionOffsetRepair.Sample] = []
    private var sampledFramePictures = true
    private var held: [(packet: UnsafeMutablePointer<AVPacket>, pictureOrderCount: Int64?)] = []
    private var heldBytes = 0
    private var verdictDescription = "sampling"
    /// After a seek on a repaired stream: nil until the landing keyframe arrives, then its picture
    /// order while the packets behind it are held to count its leading pictures.
    private var relanding = false
    private var landingPictureOrder: Int64?
    /// Index in `held` of the first picture displayed after the landing; the leading pictures are the
    /// ones before it.
    private var landingTrailingIndex: Int?

    /// nil unless this stream is the exact shape the defect needs: ISO-BMFF, H.264 or HEVC, and a
    /// bitstream that declares reordered pictures. Everything else never sees a parser or a held
    /// packet. HEVC carries the same loss (#699: a CUVA conformance stream with B pictures and no
    /// `ctts`), and its slice header carries the same picture order count.
    init?(
        containerFormatName: String?,
        stream: UnsafeMutablePointer<AVStream>,
        streamIndex: Int32,
        ladderStart: Int64
    ) {
        let containers = containerFormatName?.split(separator: ",") ?? []
        guard containers.contains("mov") || containers.contains("mp4") else { return nil }
        guard let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_id == AV_CODEC_ID_H264 || codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
              codecpar.pointee.video_delay > 0,
              let reader = H264PictureOrderReader(
                codecParameters: codecpar, timeBase: stream.pointee.time_base)
        else { return nil }
        self.streamIndex = streamIndex
        self.videoDelay = Int(codecpar.pointee.video_delay)
        self.streamStartTime = stream.pointee.start_time
        self.ladderStart = ladderStart
        self.nominalStep = H264CompositionOffsetRepair.nominalFrameStep(
            frameRate: stream.pointee.avg_frame_rate, timeBase: stream.pointee.time_base)
        self.timeBase = stream.pointee.time_base
        self.reader = reader
        let (lead, overflow) = stream.pointee.start_time.subtractingReportingOverflow(ladderStart)
        // The partial-region repair reads H.264 NAL types to find its IDRs, so HEVC gets the
        // all-missing repair only.
        self.codecName = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC ? "HEVC" : "H.264"
        partialRepairCandidate = codecpar.pointee.codec_id == AV_CODEC_ID_H264
            && !overflow && stream.pointee.start_time != Int64.min && ladderStart != Int64.min
            ? H264PartialCompositionRepairSession(stream: stream, streamIndex: streamIndex, presentationLead: lead)
            : nil
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

    /// Ticks every decode timestamp moves by, so the container's own index can be read on the same
    /// axis as the packets. nil while sampling or when nothing is repaired. The plan built from the
    /// index and the packets that fill it have to agree: measured, a plan on the raw ladder against
    /// repaired packets cut segment 2 one picture past its keyframe, which is a segment AVPlayer
    /// cannot start at.
    var decodeTimestampOffset: Int64? {
        guard phase == .repairing, let rewriter else { return nil }
        return rewriter.plan.shift - rewriter.plan.decodeLead
    }

    /// How far before its index entry (read through `decodeTimestampOffset`) a repaired keyframe can
    /// be placed. 0 when every keyframe stays on the index. Measured on the 23 fps reporting asset: a
    /// cutter that wanted the keyframe at or past its entry missed 25 of 40 segments, which then
    /// opened on audio mid-GOP.
    var keyframeAdvanceTicks: Int64 {
        guard phase == .repairing, let rewriter else { return 0 }
        return rewriter.plan.keyframeAdvanceLimit
    }

    /// Returns true when the packet was taken over by the session and must not be emitted yet.
    /// A packet the session keeps is owned by it until `dequeue()` hands it back.
    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        switch phase {
        case .off:
            return monitorsPartialOffsets ? partialRepairCandidate?.ingest(packet) ?? false : false
        case .repairing:
            if relanding { return ingestAfterSeek(packet) }
            guard packet.pointee.stream_index == streamIndex else { return false }
            applyRepair(to: packet, pictureOrderCount: reader?.pictureOrderCount(for: packet))
            return false
        case .sampling:
            var pictureOrderCount: Int64?
            if packet.pointee.stream_index == streamIndex {
                pictureOrderCount = reader?.pictureOrderCount(for: packet)
                sampledFramePictures = sampledFramePictures && reader?.isFramePicture == true
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
            if (samples.count >= H264CompositionOffsetRepair.sampleTarget && !awaitsReordering)
                || heldBytes >= H264CompositionOffsetRepair.sampleByteBudget
                || held.count >= H264CompositionOffsetRepair.heldPacketCeiling
                || earlyHealthyVerdict {
                decide()
            }
            return true
        }
    }

    /// A seek lands on a keyframe that may be an open GOP's entry point, displayed after the leading
    /// pictures decoded behind it. Their number is only known at the first picture that follows the
    /// landing in display order (leading pictures all precede the trailing ones in decode order), so
    /// everything from the landing up to that picture is held, every stream, and then repaired with
    /// the count. Without it the post-seek axis sat that many slots early, which put B pictures
    /// below their own decode time and left them in decode order (#699, resume onto a CRA).
    private func ingestAfterSeek(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        var pictureOrderCount: Int64?
        if packet.pointee.stream_index == streamIndex {
            pictureOrderCount = reader?.pictureOrderCount(for: packet)
            if landingPictureOrder == nil {
                // Pictures before the landing keyframe cannot be placed; the rewriter passes them
                // through untouched, as it did before.
                guard (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0, let pictureOrderCount else {
                    applyRepair(to: packet, pictureOrderCount: pictureOrderCount)
                    return false
                }
                landingPictureOrder = pictureOrderCount
            } else if landingTrailingIndex == nil, let landing = landingPictureOrder, let pictureOrderCount,
                      pictureOrderCount > landing {
                landingTrailingIndex = held.count
            }
        } else if landingPictureOrder == nil {
            return false
        }
        held.append((packet, pictureOrderCount))
        heldBytes += Int(max(0, packet.pointee.size))
        // A synthesized ladder holds a few pictures more to read the landing's envelope off them.
        let wantsEnvelope = rewriter?.plan.synthesizesDecodeLadder == true
            && held.lazy.filter { $0.packet.pointee.stream_index == self.streamIndex }.count
                < H264CompositionOffsetRepair.landingEnvelopePictures
        if (landingTrailingIndex != nil && !wantsEnvelope)
            || heldBytes >= H264CompositionOffsetRepair.sampleByteBudget
            || held.count >= H264CompositionOffsetRepair.heldPacketCeiling {
            finishLanding()
        }
        return true
    }

    private func finishLanding() {
        relanding = false
        guard var rewriter else { return }
        if let landing = landingPictureOrder {
            let leading = held.prefix(landingTrailingIndex ?? held.count).filter {
                $0.packet.pointee.stream_index == streamIndex
                    && ($0.pictureOrderCount.map { $0 < landing } ?? false)
            }.count
            rewriter.noteLanding(leadingPictures: Int64(leading))
            rewriter.noteLandingEnvelope(anchor: landingEnvelope(plan: rewriter.plan))
        }
        landingTrailingIndex = nil
        for entry in held where entry.packet.pointee.stream_index == streamIndex {
            applyRepair(to: entry.packet, pictureOrderCount: entry.pictureOrderCount, using: &rewriter)
        }
        self.rewriter = rewriter
        landingPictureOrder = nil
    }

    /// The earliest origin the held landing pictures imply: each was written no earlier than its own
    /// time, so `DTS - pictureOffset(display index)` over the landing's sequence bounds where the
    /// sequence really starts. Stops at the next IDR, whose picture order starts over.
    private func landingEnvelope(plan: H264CompositionOffsetRepair.Plan) -> Int64? {
        guard plan.synthesizesDecodeLadder, plan.pocStep > 0 else { return nil }
        var earliest: Int64?
        var first = true
        for entry in held where entry.packet.pointee.stream_index == streamIndex {
            let isKeyframe = (entry.packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
            guard let pictureOrderCount = entry.pictureOrderCount else { continue }
            if !first, isKeyframe, pictureOrderCount == 0 { break }
            first = false
            let dts = entry.packet.pointee.dts
            guard dts != Int64.min, pictureOrderCount % plan.pocStep == 0,
                  let offset = plan.pictureOffset(pictureOrderCount / plan.pocStep) else { continue }
            let (origin, overflow) = dts.subtractingReportingOverflow(offset)
            guard !overflow else { continue }
            earliest = min(earliest ?? origin, origin)
        }
        return earliest
    }

    /// The sample is past `sampleTarget` without a picture-order regression, every picture so far reports
    /// `PTS == DTS`, and it may still grow: keep sampling until the first regression plus the rest of
    /// its mini-GOP (the reorder delay and two pictures, which is what the window checks need to see
    /// it close). A head that already reordered inside `sampleTarget` decides there, as before.
    private var awaitsReordering: Bool {
        guard samples.count < H264CompositionOffsetRepair.extendedSampleTarget,
              samples.allSatisfy({ $0.dts != Int64.min && $0.pts == $0.dts && $0.pictureOrderCount >= 0 })
        else { return false }
        guard let regression = samples.indices.dropFirst().first(where: {
            samples[$0].pictureOrderCount < samples[$0 - 1].pictureOrderCount
        }) else { return true }
        guard regression >= H264CompositionOffsetRepair.sampleTarget else { return false }
        return samples.count - regression < videoDelay + 2
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
        if relanding { finishLanding() }
        if monitorsPartialOffsets { partialRepairCandidate?.endOfStream() }
    }

    func noteSeek() {
        // The held packets belong to the position that was abandoned, in EVERY phase, not just while
        // the sample is still open: a settled verdict leaves the sample it read in the queue, and
        // `dequeue()` hands that queue out ahead of anything read after the seek. Dropping it only
        // during `.sampling` republished the old position's packets at the landing, which on a healthy
        // file (verdict `.off`, sample still held) put two duplicate pictures into the stream a
        // producer had already emitted.
        dropHeldPackets()
        partialRepairCandidate?.noteSeek()
        switch phase {
        case .sampling:
            // The sample restarts where the source now stands.
            samples.removeAll(keepingCapacity: true)
            sampledFramePictures = true
        case .repairing:
            rewriter?.noteSeek()
            reader?.reset()
            relanding = true
            landingPictureOrder = nil
            landingTrailingIndex = nil
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
        guard phase != .sampling, !relanding else { return nil }
        if !held.isEmpty { return held.removeFirst().packet }
        return monitorsPartialOffsets ? partialRepairCandidate?.dequeue() : nil
    }

    var summary: String {
        if monitorsPartialOffsets, let partialRepairCandidate, partialRepairCandidate.hasDecision {
            return partialRepairCandidate.summary
        }
        var text = "phase=\(phase) verdict=\(verdictDescription)"
        if let rewriter {
            text += " repaired=\(rewriter.repairedPictures) unrepaired=\(rewriter.unrepairedPictures)"
        }
        return text
    }

    private func decide() {
        decide(using: nil)
    }

    /// `nominalStep` is nil on the first pass, so the missing-head partial repair below keeps first
    /// claim on a non-uniform ladder; only when it declines does the nominal-rate rebuild get a turn.
    private func decide(using nominalStep: Int64?) {
        let rate = nominalStep.flatMap {
            H264CompositionOffsetRepair.rateCadence(bitstreamRate: reader?.frameRate, estimate: $0, timeBase: timeBase)
        }
        let verdict = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: videoDelay,
            streamStartTime: streamStartTime,
            ladderStart: ladderStart,
            // The span check reads the rate too, and the stated one is the better reading of it.
            nominalStep: rate?.timestamp(at: 1) ?? nominalStep,
            rateCadence: rate
        )
        switch verdict {
        case .repair(let plan):
            // The cadence and its phase belong in the line: on a fractional ladder they are the
            // reading the verdict rests on, and a repair that reports only a rounded step cannot be
            // told apart from one that measured the ladder wrong.
            let cadenceDescription = plan.cadence.map {
                " cadence=\($0.numerator)/\($0.denominator) phase=\(plan.ladderPhase)"
                    + " ladderAhead=\(plan.ladderOrdinalOffset)"
            } ?? ""
            verdictDescription = "repair step=\(plan.step) lead=\(plan.decodeLead) "
                + "shift=\(plan.shift) pocStep=\(plan.pocStep)" + cadenceDescription
                + (plan.synthesizesDecodeLadder ? " ladder=nominal-rate" : "")
            phase = .repairing
            var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
            for entry in held where entry.packet.pointee.stream_index == streamIndex {
                applyRepair(to: entry.packet, pictureOrderCount: entry.pictureOrderCount, using: &rewriter)
            }
            self.rewriter = rewriter
            EngineLog.emit(
                "[Demuxer] #409 missing \(codecName) composition offsets confirmed on stream \(streamIndex): "
                + "\(verdictDescription) samples=\(samples.count)",
                category: .demux
            )
        case .healthy:
            // An actual healthy origin corroborates the container's edit/index lead. A random
            // nonzero B-picture offset is not evidence for retiming a later region.
            if let first = samples.first, first.isKeyframe, first.pictureOrderCount == 0,
               first.dts == ladderStart, first.pts == streamStartTime {
                monitorsPartialOffsets = partialRepairCandidate != nil
            }
            verdictDescription = "healthy"
            disarm()
        case .inconclusive(let reason):
            if reason == "decode ladder is not uniform", nominalStep == nil, sampledFramePictures,
               let candidate = partialRepairCandidate,
               let forwardDepth = H264PartialCompositionRepair.missingHeadForwardDepth(
                   dts: samples.map(\.dts), pts: samples.map(\.pts),
                   pocs: samples.map(\.pictureOrderCount), keys: samples.map(\.isKeyframe),
                   streamStart: streamStartTime, ladderStart: ladderStart, reorderDepth: videoDelay),
               let firstPacket = held.first(where: { $0.packet.pointee.stream_index == streamIndex })?.packet,
               candidate.enableMissingHead(forwardDepth: forwardDepth, firstPacket: firstPacket) {
                // Reuse #513's streaming slots. Hand over each interleaved packet once;
                // leading non-video packets remain ahead of the candidate's queue.
                monitorsPartialOffsets = true
                disarm()
                let input = held
                held.removeAll(keepingCapacity: false)
                heldBytes = 0
                for entry in input where !candidate.ingest(entry.packet) { held.append(entry) }
                samples.removeAll(keepingCapacity: false)
                return
            }
            if reason == "decode ladder is not uniform", nominalStep == nil, let step = self.nominalStep {
                decide(using: step)
                return
            }
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
        guard let pictureOrderCount,
              let repaired = rewriter.rewrite(
                dts: packet.pointee.dts,
                pictureOrderCount: pictureOrderCount,
                isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0)
        else { return }
        packet.pointee.pts = repaired.pts
        packet.pointee.dts = repaired.dts
    }
}
