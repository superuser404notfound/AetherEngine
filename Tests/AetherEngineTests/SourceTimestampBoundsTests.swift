import CoreMedia
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Audit SEG-1: a crafted Matroska cluster time or a garbage live tfdt must degrade a packet, not
/// trap the pump on Int64 overflow.
struct SourceTimestampBoundsTests {

    private func withPacket(pts: Int64, dts: Int64, duration: Int64 = 0,
                            _ body: (UnsafeMutablePointer<AVPacket>) -> Void) throws {
        let packet = try #require(av_packet_alloc())
        defer {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
        }
        packet.pointee.pts = pts
        packet.pointee.dts = dts
        packet.pointee.duration = duration
        body(packet)
    }

    @Test func extremeSourceTimestampsBecomeUnset() throws {
        try withPacket(pts: Int64(1) << 62, dts: -(Int64(1) << 62), duration: -5) { packet in
            #expect(SourceTimestampBounds.sanitize(packet))
            #expect(packet.pointee.pts == Int64.min)
            #expect(packet.pointee.dts == Int64.min)
            #expect(packet.pointee.duration == 0)
        }
    }

    @Test func plausibleTimestampsPassUntouched() throws {
        // An epoch-anchored live tfdt at a 10 MHz timescale sits near 1.8e16.
        let epochTfdt: Int64 = 1_790_000_000 * 10_000_000
        try withPacket(pts: epochTfdt + 400_000, dts: epochTfdt, duration: 400_000) { packet in
            #expect(!SourceTimestampBounds.sanitize(packet))
            #expect(packet.pointee.pts == epochTfdt + 400_000)
            #expect(packet.pointee.dts == epochTfdt)
            #expect(packet.pointee.duration == 400_000)
        }
        try withPacket(pts: Int64.min, dts: -1800) { packet in
            #expect(!SourceTimestampBounds.sanitize(packet))
            #expect(packet.pointee.pts == Int64.min)
        }
    }

    @Test func tickArithmeticSaturatesInsteadOfTrapping() {
        let big = Int64(1) << 62
        #expect(SourceTimestampBounds.difference(big, -big) == Int64.max)
        #expect(SourceTimestampBounds.difference(-big, big) == Int64.min + 1)
        #expect(SourceTimestampBounds.sum(Int64.max, 1) == Int64.max)
        #expect(SourceTimestampBounds.sum(Int64.min + 1, -2) == Int64.min + 1)
        #expect(SourceTimestampBounds.difference(90_000, 1800) == 88_200)
    }

    @Test func rebaseMathSurvivesOppositeSignExtremes() {
        let big = Int64(1) << 62
        let shifted = HLSSegmentProducer.rebasedVideoShift(
            srcDts: -big, lastSrcDts: big, oldShift: -big, fallbackDurationPts: 1800)
        #expect(shifted.continuationDts == Int64.max)
        #expect(HLSSegmentProducer.seamDerivedAudioShift(audioBoundarySrcDts: big, seamOutAudioTb: -big) == Int64.max)
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 0, dts: big, nextDts: -big, fallback: 1800, capTicks: 90_000) == 1800)
    }

    /// Audit SEG-R202: one rule for the inherit and the override rebase branches.
    @Test func audioRebaseKeepsACandidateUnlessItOverlapsByMoreThanHalfASecond() {
        let tb = AVRational(num: 1, den: 48_000)
        let kept = HLSSegmentProducer.reanchoredAudioShift(
            lastOutputDts: 100_000, boundarySrcDts: 500_000, packetDts: 500_000, candidateShift: 400_100, timeBase: tb)
        #expect(!kept.reanchored && kept.shift == 400_100 && kept.maxOverlapTicks == 24_000)
        let reset = HLSSegmentProducer.reanchoredAudioShift(
            lastOutputDts: 100_000, boundarySrcDts: 500_000, packetDts: 500_000, candidateShift: 460_000, timeBase: tb)
        #expect(reset.reanchored && reset.overlapTicks == 60_000 && reset.shift == 399_999)
        let extreme = HLSSegmentProducer.reanchoredAudioShift(
            lastOutputDts: Int64.max, boundarySrcDts: Int64.min + 1, packetDts: 0, candidateShift: Int64.max, timeBase: tb)
        #expect(extreme.reanchored)
    }

    // MARK: - The demuxer funnel (audit NAT-101 / DEC-101 / FEA-101 / SUB-105)

    private func sanitized(pts: Int64, dts: Int64, duration: Int64 = 0, _ timeBase: AVRational)
        throws -> (changed: Bool, pts: Int64, dts: Int64, duration: Int64) {
        var result: (Bool, Int64, Int64, Int64) = (false, 0, 0, 0)
        try withPacket(pts: pts, dts: dts, duration: duration) { packet in
            let changed = SourceTimestampBounds.sanitize(packet, timeBase: timeBase)
            result = (changed, packet.pointee.pts, packet.pointee.dts, packet.pointee.duration)
        }
        return result
    }

    @Test func epochAnchoredTimestampsPassTheFunnel() throws {
        let nanos = try sanitized(pts: 1_790_000_000_000_000_000, dts: 1_790_000_000_000_000_000,
                                  duration: 40_000_000, AVRational(num: 1, den: 1_000_000_000))
        #expect(!nanos.changed)
        #expect(nanos.pts == 1_790_000_000_000_000_000)
        let hundreds = try sanitized(pts: 18_000_000_000_000_000, dts: 18_000_000_000_000_000,
                                     duration: 400_000, AVRational(num: 1, den: 10_000_000))
        #expect(!hundreds.changed)
        let mpegts = try sanitized(pts: 8_589_934_591, dts: 8_589_934_590, duration: 3003,
                                   AVRational(num: 1, den: 90_000))
        #expect(!mpegts.changed)
    }

    @Test func secondsRuleCatchesWhatTheTickRuleLetsThrough() throws {
        let nonUnit = try sanitized(pts: (Int64(1) << 62) - 1, dts: 1000, AVRational(num: 3, den: 1_000_000_000))
        #expect(nonUnit.changed)
        #expect(nonUnit.pts == Int64.min)
        #expect(nonUnit.dts == 1000)
        let ninety = try sanitized(pts: Int64(1) << 61, dts: Int64(1) << 61, AVRational(num: 1, den: 90_000))
        #expect(ninety.pts == Int64.min && ninety.dts == Int64.min)
        let coarse = try sanitized(pts: 5_000_000_000, dts: -5_000_000_000, AVRational(num: 1, den: 1))
        #expect(coarse.pts == Int64.min && coarse.dts == Int64.min)
    }

    @Test func tickRuleHoldsOnADegenerateTimeBase() throws {
        let fine = try sanitized(pts: Int64(1) << 62, dts: (Int64(1) << 62) - 1, AVRational(num: 0, den: 0))
        #expect(fine.pts == Int64.min)
        #expect(fine.dts == (Int64(1) << 62) - 1)
        let extremes = try sanitized(pts: Int64.max, dts: Int64.min + 1, duration: Int64.max,
                                     AVRational(num: 1, den: 1_000_000_000))
        #expect(extremes.pts == Int64.min && extremes.dts == Int64.min && extremes.duration == 0)
    }

    @Test func durationFollowsTheSameRulesAndNeverGoesNegative() throws {
        let negative = try sanitized(pts: 0, dts: 0, duration: -1, AVRational(num: 1, den: 1000))
        #expect(negative.duration == 0)
        let huge = try sanitized(pts: 0, dts: 0, duration: 10_000_000_000_000, AVRational(num: 1, den: 1000))
        #expect(huge.duration == 0)
        let kept = try sanitized(pts: 0, dts: 0, duration: 1_000_000, AVRational(num: 1, den: 1000))
        #expect(!kept.changed && kept.duration == 1_000_000)
    }

    @Test func secondPassIsIdempotent() throws {
        try withPacket(pts: Int64(1) << 61, dts: 1000, duration: Int64.max) { packet in
            let tb = AVRational(num: 1, den: 90_000)
            #expect(SourceTimestampBounds.sanitize(packet, timeBase: tb))
            #expect(!SourceTimestampBounds.sanitize(packet, timeBase: tb))
            #expect(packet.pointee.dts == 1000)
        }
    }

    /// `ticks * num == seconds * den` and 4e9 x (2^31 - 1) < 2^63: the largest tick that passes, times
    /// the numerator, stays inside Int64 for every time base libavformat can report.
    @Test func noPassingTickOverflowsTheNumerator() {
        let values: [Int32] = [1, 3, 1000, 1001, 90_000, 1_000_000_000, Int32.max]
        for num in values {
            for den in values {
                let tb = AVRational(num: num, den: den)
                var passing: Int64 = 0
                var failing = SourceTimestampBounds.demuxedMagnitude
                while failing - passing > 1 {
                    let mid = passing + (failing - passing) / 2
                    if SourceTimestampBounds.plausible(mid, timeBase: tb) == mid { passing = mid } else { failing = mid }
                }
                #expect(!passing.multipliedReportingOverflow(by: Int64(num)).overflow, "\(num)/\(den)")
                #expect(!(-passing).multipliedReportingOverflow(by: Int64(num)).overflow, "\(num)/\(den)")
                #expect(SourceTimestampBounds.plausible(-passing, timeBase: tb) == -passing)
            }
        }
    }

    // MARK: - Checked helpers for values produced after the funnel

    @Test func cmTimeIsInvalidInsteadOfTrapping() {
        let nonUnit = AVRational(num: 3, den: 1_000_000_000)
        #expect(!SourceTimestampBounds.cmTime(ticks: Int64(1) << 62, timeBase: nonUnit).isValid)
        #expect(!SourceTimestampBounds.cmTime(ticks: Int64.min, timeBase: nonUnit).isValid)
        #expect(!SourceTimestampBounds.cmTime(ticks: 1, timeBase: AVRational(num: 1, den: 0)).isValid)
        let ok = SourceTimestampBounds.cmTime(ticks: 1001, timeBase: nonUnit)
        #expect(ok.value == 3003 && ok.timescale == 1_000_000_000)
    }

    @Test func roundedTicksRefusesWhatInt64CannotHold() {
        #expect(SourceTimestampBounds.roundedTicks(.nan) == nil)
        #expect(SourceTimestampBounds.roundedTicks(.infinity) == nil)
        #expect(SourceTimestampBounds.roundedTicks(-.infinity) == nil)
        #expect(SourceTimestampBounds.roundedTicks(1e300) == nil)
        #expect(SourceTimestampBounds.roundedTicks(9.223372036854775807e18) == nil)
        #expect(SourceTimestampBounds.roundedTicks(-9.223372036854775808e18) == nil)
        #expect(SourceTimestampBounds.roundedTicks(4_999.5) == 5_000)
        #expect(SourceTimestampBounds.roundedTicks(-1.4) == -1)
    }

    /// Audit NAT-101: the software host's fold. Video at 5 s on 1/1000, then a seam whose offset
    /// no stream base can hold, and an offset that converts but walks a far-side packet out of Int64.
    @Test func foldShiftDegradesToUnsetInsteadOfTrapping() {
        let offsetSeconds = Double(Int64.min + 256) * 0.001 - 5
        let offsetTicks = SourceTimestampBounds.roundedTicks(offsetSeconds / 0.001)
        #expect(offsetTicks == nil)
        #expect(SourceTimestampBounds.shifted(5000, back: offsetTicks) == Int64.min)

        let audioOffset = SourceTimestampBounds.roundedTicks(8e9 / 1e-9)
        #expect(audioOffset == 8_000_000_000_000_000_000)
        #expect(SourceTimestampBounds.shifted(-(Int64(1) << 62), back: audioOffset) == Int64.min)
        #expect(SourceTimestampBounds.shifted(Int64.min, back: 0) == Int64.min)
        #expect(SourceTimestampBounds.shifted(90_000, back: 45_000) == 45_000)
    }

    @Test func clampedSecondsPinsNonFiniteAndHugeTimes() {
        #expect(SourceTimestampBounds.clampedSeconds(.nan) == 0)
        #expect(SourceTimestampBounds.clampedSeconds(.infinity) == SourceTimestampBounds.maxPlausibleSeconds)
        #expect(SourceTimestampBounds.clampedSeconds(-.infinity) == -SourceTimestampBounds.maxPlausibleSeconds)
        #expect(SourceTimestampBounds.clampedSeconds(12.5) == 12.5)
    }
}
