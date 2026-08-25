import Foundation
import Libavcodec
import Testing
@testable import AetherEngine

/// #409. The two MP4 fixtures are @orut34iop's, from the report and PR #411: one encode, muxed twice,
/// with the composition-offset table present in one and stream-copied away in the other. That pairing
/// is what makes the property here checkable at all, because the healthy twin IS the expected answer:
/// a repair is correct exactly when it reproduces its timestamps, packet for packet.
@Suite("H.264 missing composition offsets (#409)")
struct H264CompositionOffsetRepairTests {

    // MARK: - the decision

    /// The reported shape: twelve pictures, no composition offsets, a uniform ladder, and a picture
    /// order that regresses inside every mini-GOP.
    private func malformedSamples() -> [H264CompositionOffsetRepair.Sample] {
        let pocs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        return pocs.enumerated().map { index, poc in
            H264CompositionOffsetRepair.Sample(
                dts: Int64(index) * 1001,
                pts: Int64(index) * 1001,
                pictureOrderCount: poc,
                isKeyframe: index == 0
            )
        }
    }

    private var quantizedCadence: H264CompositionOffsetRepair.Cadence {
        H264CompositionOffsetRepair.Cadence(numerator: 200202, denominator: 5)!
    }

    private func quantizedMalformedSamples(videoDelay: Int64 = 2)
        -> [H264CompositionOffsetRepair.Sample]
    {
        let pocs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        return pocs.enumerated().map { index, poc in
            let dts = quantizedCadence.timestamp(at: Int64(index) - videoDelay)!
            return H264CompositionOffsetRepair.Sample(
                dts: dts, pts: dts, pictureOrderCount: poc, isKeyframe: index == 0)
        }
    }

    /// Identity-free timing evidence from the affected physical Apple TV source. The DTS ladder is
    /// exact; the POC ranks model the logged videoDelay=1 and three regressions without exposing the
    /// source's full bitstream order. The nominal coded rate rounds to a 40040-tick integer cadence,
    /// while the duration-derived average rate is nearly 200202/5 and the actual STTS pattern repeats
    /// that five-frame quantization twice.
    private func physicalQuantizedSamples() -> [H264CompositionOffsetRepair.Sample] {
        let pocs: [Int64] = [0, 4, 2, 6, 8, 12, 10, 14, 16, 20, 18, 22]
        let steps: [Int64] = [
            40040, 40041, 40040, 40040, 40041,
            40040, 40041, 40040, 40040, 40041, 40040,
        ]
        var dts: Int64 = -40040
        return pocs.enumerated().map { index, poc in
            defer { if index < steps.count { dts += steps[index] } }
            return H264CompositionOffsetRepair.Sample(
                dts: dts, pts: dts, pictureOrderCount: poc, isKeyframe: index == 0)
        }
    }

    private var physicalAverageCadence: H264CompositionOffsetRepair.Cadence {
        H264CompositionOffsetRepair.Cadence(
            numerator: 34_597_562_400_000,
            denominator: 864_066_353
        )!
    }

    private func verdict(
        _ samples: [H264CompositionOffsetRepair.Sample],
        videoDelay: Int = 2,
        streamStartTime: Int64 = 0,
        ladderStart: Int64 = 0
    ) -> H264CompositionOffsetRepair.Verdict {
        H264CompositionOffsetRepair.classify(
            samples: samples, videoDelay: videoDelay,
            streamStartTime: streamStartTime, ladderStart: ladderStart)
    }

    @Test("the reported shape is repaired, with the ladder and picture-order step measured")
    func confirmedShape() {
        #expect(verdict(malformedSamples())
            == .repair(H264CompositionOffsetRepair.Plan(
                step: 1001, decodeLead: 2002, shift: 0, pocStep: 2)))
    }

    @Test("one composition offset ends it: the writer emitted the table")
    func oneOffsetIsHealthy() {
        var samples = malformedSamples()
        samples[3].pts = samples[3].dts + 1001
        #expect(verdict(samples) == .healthy)
    }

    @Test("a stream that presents in decode order is left alone")
    func noReorderNoRepair() {
        let samples = (0..<12).map { index in
            H264CompositionOffsetRepair.Sample(
                dts: Int64(index) * 1001, pts: Int64(index) * 1001,
                pictureOrderCount: Int64(index) * 2, isKeyframe: index == 0)
        }
        #expect(verdict(samples) == .inconclusive("picture order never regresses"))
    }

    @Test("variable frame timing is not repairable by rank arithmetic and stays untouched")
    func nonUniformLadder() {
        var samples = malformedSamples()
        for index in 6..<samples.count { samples[index].dts += 500; samples[index].pts += 500 }
        #expect(verdict(samples) == .inconclusive("decode ladder is not uniform"))
    }

    @Test("nearest rounding is symmetric across the negative decode head and exactly invertible")
    func rationalCadenceRoundingAndInverse() {
        let expected: [(Int64, Int64)] = [
            (-2, -80081), (-1, -40040), (0, 0), (1, 40040),
            (2, 80081), (3, 120121), (4, 160162),
        ]
        for (ordinal, timestamp) in expected {
            #expect(quantizedCadence.timestamp(at: ordinal) == timestamp)
            #expect(quantizedCadence.frameOrdinal(forTimestamp: timestamp) == ordinal)
        }
        #expect(quantizedCadence.frameOrdinal(forTimestamp: 40041) == nil)
    }

    @Test("an exact two-period adjacent-tick ladder uses the declared rational cadence")
    func quantizedLadderClassification() {
        let samples = quantizedMalformedSamples()
        let result = H264CompositionOffsetRepair.classify(
            samples: samples, videoDelay: 2,
            streamStartTime: 0, ladderStart: samples[0].dts,
            cadenceCandidates: [quantizedCadence])
        if case .repair(let plan) = result {
            #expect(plan.cadence == quantizedCadence)
            #expect(plan.rawFrameOffset == -2)
            #expect(plan.step == 40040)
            #expect(plan.decodeLead == 80081)
            #expect(plan.shift == 80081)
        } else {
            #expect(Bool(false), "the exact rational lattice must be repairable")
        }
    }

    @Test("adjacent steps in the wrong phase remain inconclusive")
    func rejectsWrongQuantizationPattern() {
        var samples = quantizedMalformedSamples()
        let originalSteps = zip(samples, samples.dropFirst()).map { $1.dts - $0.dts }
        var wrongSteps = originalSteps
        wrongSteps.swapAt(0, 1)
        var timestamp = samples[0].dts
        for index in 1..<samples.count {
            timestamp += wrongSteps[index - 1]
            samples[index].dts = timestamp
            samples[index].pts = timestamp
        }
        #expect(Set(wrongSteps) == Set([40040, 40041]))
        #expect(H264CompositionOffsetRepair.classify(
            samples: samples, videoDelay: 2,
            streamStartTime: 0, ladderStart: samples[0].dts,
            cadenceCandidates: [quantizedCadence])
            == .inconclusive("decode ladder is not uniform"))
    }

    @Test("an adjacent ladder without matching frame-rate metadata is not guessed")
    func quantizedLadderRequiresMetadata() {
        let samples = quantizedMalformedSamples()
        #expect(H264CompositionOffsetRepair.classify(
            samples: samples, videoDelay: 2,
            streamStartTime: 0, ladderStart: samples[0].dts)
            == .inconclusive("decode ladder is not uniform"))
    }

    @Test("the physical five-frame phase is recovered independently of nominal frame-rate metadata")
    func physicalQuantizationPhaseClassification() {
        let samples = physicalQuantizedSamples()
        let result = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: 1,
            streamStartTime: 0,
            ladderStart: -40040,
            cadenceCandidates: [
                H264CompositionOffsetRepair.Cadence(numerator: 40040, denominator: 1)!,
                physicalAverageCadence,
            ]
        )
        guard case .repair(let physicalPlan) = result else {
            #expect(Bool(false), "the repeated physical STTS phase must be repairable")
            return
        }
        #expect(physicalPlan.cadence == quantizedCadence)
        #expect(physicalPlan.rawFrameOffset == -1)

        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: physicalPlan)
        let first = rewriter.rewrite(
            dts: samples[0].dts,
            pictureOrderCount: samples[0].pictureOrderCount,
            isKeyframe: true
        )
        #expect(first?.pts == 0)
        #expect(first?.dts == -40040)
        for sample in samples.dropFirst() {
            #expect(rewriter.rewrite(
                dts: sample.dts,
                pictureOrderCount: sample.pictureOrderCount,
                isKeyframe: sample.isKeyframe
            ) != nil)
        }
        #expect(rewriter.repairedPictures == 12)
        #expect(rewriter.unrepairedPictures == 0)
    }

    @Test("classification refuses a POC depth that the declared reorder delay cannot rewrite")
    func rejectsUnsafePhysicalPlanBeforeRepairStarts() {
        var samples = physicalQuantizedSamples()
        let tooDeepPOCs: [Int64] = [0, 8, 4, 2, 6, 16, 12, 10, 14, 24, 20, 18]
        for index in samples.indices {
            samples[index].pictureOrderCount = tooDeepPOCs[index]
        }
        #expect(H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: 1,
            streamStartTime: 0,
            ladderStart: -40040,
            cadenceCandidates: [physicalAverageCadence]
        ) == .inconclusive("sample cannot be rewritten safely"))
    }

    @Test(
        "a one-tick timestamp error stays on the repaired axis in either direction",
        arguments: [Int64(-1), Int64(1)]
    )
    func rationalRepairRectifiesLateTimestampNoise(offset: Int64) {
        let samples = physicalQuantizedSamples()
        let result = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: 1,
            streamStartTime: 0,
            ladderStart: -40040,
            cadenceCandidates: [physicalAverageCadence]
        )
        guard case .repair(let physicalPlan) = result else {
            #expect(Bool(false), "expected the physical rational plan")
            return
        }
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: physicalPlan)
        for sample in samples {
            _ = rewriter.rewrite(
                dts: sample.dts,
                pictureOrderCount: 0,
                isKeyframe: true
            )
        }

        // Decode ordinal 12 should land on the CFR grid even when its container DTS is one tick off.
        let noisyDTS: Int64 = 440445 + offset
        let nextIDR = rewriter.rewrite(
            dts: noisyDTS,
            pictureOrderCount: 0,
            isKeyframe: true
        )
        #expect(nextIDR?.pts == 480485)
        #expect(nextIDR?.dts == 440445)
        #expect(rewriter.unrepairedPictures == 0)
    }

    @Test("an unparsed packet is counted and the next exact timestamp resynchronizes decode order")
    func rationalRepairResynchronizesAfterParserMiss() {
        let samples = physicalQuantizedSamples()
        let result = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: 1,
            streamStartTime: 0,
            ladderStart: -40040,
            cadenceCandidates: [physicalAverageCadence]
        )
        guard case .repair(let physicalPlan) = result else {
            #expect(Bool(false), "expected the physical rational plan")
            return
        }
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: physicalPlan)
        _ = rewriter.rewrite(
            dts: samples[0].dts,
            pictureOrderCount: samples[0].pictureOrderCount,
            isKeyframe: true
        )
        #expect(rewriter.rewrite(
            dts: samples[1].dts,
            pictureOrderCount: nil,
            isKeyframe: false
        ) == nil)

        let resynchronized = rewriter.rewrite(
            dts: samples[2].dts,
            pictureOrderCount: samples[2].pictureOrderCount,
            isKeyframe: false
        )
        #expect(resynchronized?.pts == 40041)
        #expect(resynchronized?.dts == 40041)
        #expect(rewriter.repairedPictures == 2)
        #expect(rewriter.unrepairedPictures == 1)
    }

    @Test("a rejected exact forward jump does not poison the following normal timestamp")
    func rationalRepairDoesNotCommitUnplaceableForwardJump() {
        let samples = physicalQuantizedSamples()
        let result = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: 1,
            streamStartTime: 0,
            ladderStart: -40040,
            cadenceCandidates: [physicalAverageCadence]
        )
        guard case .repair(let physicalPlan) = result else {
            #expect(Bool(false), "expected the physical rational plan")
            return
        }
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: physicalPlan)
        _ = rewriter.rewrite(
            dts: samples[0].dts,
            pictureOrderCount: samples[0].pictureOrderCount,
            isKeyframe: true
        )

        #expect(rewriter.rewrite(
            dts: physicalPlan.rawTimestamp(decodeOrdinal: 100)!,
            pictureOrderCount: 4,
            isKeyframe: false
        ) == nil)
        let resumed = rewriter.rewrite(
            dts: samples[2].dts,
            pictureOrderCount: samples[2].pictureOrderCount,
            isKeyframe: false
        )
        #expect(resumed?.pts == 40041)
        #expect(resumed?.dts == 40041)
        #expect(rewriter.repairedPictures == 2)
        #expect(rewriter.unrepairedPictures == 1)
    }

    @Test(
        "a timestamp beyond one tick is refused and a later exact timestamp resynchronizes",
        arguments: [Int64(-10), Int64(-2), Int64(2), Int64(10)]
    )
    func rationalRepairRejectsLargeTimestampNoise(offset: Int64) {
        let samples = physicalQuantizedSamples()
        let result = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: 1,
            streamStartTime: 0,
            ladderStart: -40040,
            cadenceCandidates: [physicalAverageCadence]
        )
        guard case .repair(let physicalPlan) = result else {
            #expect(Bool(false), "expected the physical rational plan")
            return
        }
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: physicalPlan)
        for sample in samples {
            _ = rewriter.rewrite(
                dts: sample.dts,
                pictureOrderCount: 0,
                isKeyframe: true
            )
        }

        #expect(rewriter.rewrite(
            dts: 440445 + offset,
            pictureOrderCount: 0,
            isKeyframe: false
        ) == nil)
        let nextExactDTS = physicalPlan.rawTimestamp(decodeOrdinal: 13)!
        let resynchronized = rewriter.rewrite(
            dts: nextExactDTS,
            pictureOrderCount: 0,
            isKeyframe: true
        )
        #expect(resynchronized?.dts == nextExactDTS)
        #expect(rewriter.unrepairedPictures == 1)
    }

    @Test(
        "a seek keyframe uniquely reanchors across a one-tick timestamp error",
        arguments: [Int64(-1), Int64(1)]
    )
    func rationalSeekReanchorsWithinOneTick(offset: Int64) {
        let samples = physicalQuantizedSamples()
        let result = H264CompositionOffsetRepair.classify(
            samples: samples,
            videoDelay: 1,
            streamStartTime: 0,
            ladderStart: -40040,
            cadenceCandidates: [physicalAverageCadence]
        )
        guard case .repair(let physicalPlan) = result else {
            #expect(Bool(false), "expected the physical rational plan")
            return
        }
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: physicalPlan)
        _ = rewriter.rewrite(
            dts: samples[0].dts,
            pictureOrderCount: 0,
            isKeyframe: true
        )
        rewriter.noteSeek()

        let landing = rewriter.rewrite(
            dts: 440445 + offset,
            pictureOrderCount: 0,
            isKeyframe: true
        )
        #expect(landing?.pts == 480485)
        #expect(landing?.dts == 440445)
        #expect(rewriter.unrepairedPictures == 0)
    }

    @Test("a sample that does not start on a picture-order origin cannot be anchored")
    func mustStartOnOrigin() {
        var samples = malformedSamples()
        samples[0].isKeyframe = false
        #expect(verdict(samples) == .inconclusive("sample does not start on a picture-order origin"))
    }

    @Test("too few pictures fails closed")
    func tooFewSamples() {
        let samples = Array(malformedSamples().prefix(8))
        #expect(verdict(samples) == .inconclusive("only 8 sampled pictures"))
    }

    @Test("no declared reorder delay means the container is not describing this defect")
    func requiresReorderDelay() {
        #expect(verdict(malformedSamples(), videoDelay: 0)
            == .inconclusive("reorder delay 0 outside 1...16"))
    }

    @Test("two pictures may never land on one display index")
    func rejectsCollidingDisplayIndices() {
        var samples = malformedSamples()
        samples[4].pictureOrderCount = 4  // already taken by sample 2
        #expect(verdict(samples) == .inconclusive("two pictures share display index 2"))
    }

    /// The step is measured from the sample, so one picture order off the common step would halve it
    /// and spread every following rank over twice the ladder. Distinctness does not catch that;
    /// filling the window does.
    @Test("a picture order that does not advance one rank per picture is refused")
    func rejectsUnalignedPictureOrder() {
        var samples = malformedSamples()
        samples[5].pictureOrderCount = 17
        #expect(verdict(samples) == .inconclusive("display indices do not fill the sampled window"))
    }

    // MARK: - which axis the presentation lands on

    @Test("a writer that left the ladder on the presentation axis needs no shift")
    func shiftWithoutEditList() {
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: 0, ladderStart: 0, decodeLead: 2002) == 0)
    }

    @Test("a retained edit list reports the ladder from minus one decode lead, and that is the shift")
    func shiftWithRetainedEditList() {
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: 0, ladderStart: -2002, decodeLead: 2002) == 2002)
    }

    @Test("the shift can never drag the picture further than one decode lead off its audio")
    func shiftIsClamped() {
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: 0, ladderStart: -100_000, decodeLead: 2002) == 2002)
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: 90_000, ladderStart: 0, decodeLead: 2002) == 2002)
        #expect(H264CompositionOffsetRepair.presentationShift(
            streamStartTime: Int64.min, ladderStart: 0, decodeLead: 2002) == 0)
    }

    // MARK: - the rewrite

    private var plan: H264CompositionOffsetRepair.Plan {
        H264CompositionOffsetRepair.Plan(step: 1001, decodeLead: 2002, shift: 0, pocStep: 2)
    }

    @Test("the first mini-GOP lands on the ladder in display order, with DTS pulled back by the lead")
    func rewritesFirstMiniGOP() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        let pocs: [Int64] = [0, 8, 4, 2, 6]
        let expected: [(Int64, Int64)] = [(0, -2002), (4004, -1001), (2002, 0), (1001, 1001), (3003, 2002)]
        for (index, poc) in pocs.enumerated() {
            let out = rewriter.rewrite(
                dts: Int64(index) * 1001, pictureOrderCount: poc, isKeyframe: index == 0)
            #expect(out?.pts == expected[index].0)
            #expect(out?.dts == expected[index].1)
        }
        #expect(rewriter.repairedPictures == 5)
        #expect(rewriter.unrepairedPictures == 0)
    }

    @Test("a new coded video sequence re-anchors on its own IDR")
    func reanchorsAtEverySequence() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        _ = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        // Second IDR, 30 pictures in: its picture order restarts at 0 and it is the first of its
        // sequence to be displayed, so it keeps its own decode time as its presentation time.
        let idr = rewriter.rewrite(dts: 30030, pictureOrderCount: 0, isKeyframe: true)
        let idrPTS: Int64 = idr?.pts ?? -1
        let idrDTS: Int64 = idr?.dts ?? -1
        #expect(idrPTS == 30030)
        #expect(idrDTS == 28028)
        let following = rewriter.rewrite(dts: 31031, pictureOrderCount: 8, isKeyframe: false)
        let followingPTS: Int64 = following?.pts ?? -1
        #expect(followingPTS == 34034)
    }

    @Test("a seek re-anchors on the landing keyframe instead of trusting the abandoned sequence")
    func seekReanchors() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        _ = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        rewriter.noteSeek()
        let landing = rewriter.rewrite(dts: 500500, pictureOrderCount: 0, isKeyframe: true)
        let landingPTS: Int64 = landing?.pts ?? -1
        let landingDTS: Int64 = landing?.dts ?? -1
        #expect(landingPTS == 500500)
        #expect(landingDTS == 498498)
    }

    @Test("a rational seek landing recovers global cadence phase from raw DTS")
    func rationalSeekReanchorsWithoutPhaseReset() {
        let samples = quantizedMalformedSamples()
        let result = H264CompositionOffsetRepair.classify(
            samples: samples, videoDelay: 2,
            streamStartTime: 0, ladderStart: samples[0].dts,
            cadenceCandidates: [quantizedCadence])
        guard case .repair(let rationalPlan) = result else {
            #expect(Bool(false), "expected a rational repair plan")
            return
        }
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: rationalPlan)
        _ = rewriter.rewrite(dts: samples[0].dts, pictureOrderCount: 0, isKeyframe: true)
        rewriter.noteSeek()

        // Decode ordinal 7 is not a period boundary. An open-GOP landing picture with display rank
        // 2 must map to global presentation ordinal 7, not restart a fresh phase at this keyframe.
        let rawDTS = quantizedCadence.timestamp(at: 5)!
        let landing = rewriter.rewrite(dts: rawDTS, pictureOrderCount: 4, isKeyframe: true)
        #expect(landing?.pts == quantizedCadence.timestamp(at: 7))
        #expect(landing?.dts == quantizedCadence.timestamp(at: 5))
        #expect(rewriter.unrepairedPictures == 0)
    }

    @Test("a rational presentation-axis ladder maps indexes with the same phase as packets")
    func rationalIndexTimestampMapping() {
        let presentationAxisPlan = H264CompositionOffsetRepair.Plan(
            cadence: quantizedCadence,
            presentationOrigin: 0,
            ladderStart: 0,
            rawFrameOffset: 0,
            videoDelay: 2,
            pocStep: 2)!
        let rawIndexTimestamp = quantizedCadence.timestamp(at: 7)!
        #expect(presentationAxisPlan.repairedDecodeTimestamp(rawIndexTimestamp)
            == quantizedCadence.timestamp(at: 5))
        #expect(presentationAxisPlan.repairedDecodeTimestamp(rawIndexTimestamp + 1) == nil)
    }

    @Test("without an anchor a picture is emitted untouched rather than guessed at")
    func passesThroughWithoutAnchor() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        rewriter.noteSeek()
        #expect(rewriter.rewrite(dts: 4004, pictureOrderCount: 8, isKeyframe: false) == nil)
        #expect(rewriter.unrepairedPictures == 1)
    }

    @Test("a picture that would land before its own decode time is refused")
    func refusesPTSBeforeDTS() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        _ = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        // A picture order far behind the anchor would place this picture before its own DTS.
        #expect(rewriter.rewrite(dts: 100 * 1001, pictureOrderCount: 2, isKeyframe: false) == nil)
        #expect(rewriter.unrepairedPictures == 1)
    }

    @Test("an unparseable picture order leaves the packet alone")
    func refusesUnalignedOrder() {
        var rewriter = H264CompositionOffsetRepair.Rewriter(plan: plan)
        _ = rewriter.rewrite(dts: 0, pictureOrderCount: 0, isKeyframe: true)
        #expect(rewriter.rewrite(dts: 1001, pictureOrderCount: 3, isKeyframe: false) == nil)
    }

    // MARK: - end to end, against the twin

    private struct Timestamps: Equatable, CustomStringConvertible {
        var pts: Int64
        var dts: Int64
        var description: String { "pts=\(pts) dts=\(dts)" }
    }

    private static func videoTimestamps(base64: String) throws -> [Timestamps] {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        var result: [Timestamps] = []
        while let packet = try? demuxer.readPacket() {
            if packet.pointee.stream_index == videoIndex {
                result.append(Timestamps(pts: packet.pointee.pts, dts: packet.pointee.dts))
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
        }
        return result
    }

    private static func indexedKeyframes(base64: String) throws -> [Int64] {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        demuxer.decideCompositionOffsetRepair()
        return demuxer.indexedKeyframes(streamIndex: demuxer.videoStreamIndex)
    }

    @Test("the repaired twin carries the healthy twin's timestamps, packet for packet")
    func repairedTwinMatchesHealthyTwin() throws {
        let healthy = try Self.videoTimestamps(base64: Self.healthyCTTSFixtureBase64)
        let repaired = try Self.videoTimestamps(base64: Self.missingCTTSFixtureBase64)
        #expect(healthy.count == 66)
        #expect(repaired.count == healthy.count)
        #expect(repaired == healthy)
    }

    /// Physical-device regression: a rational frame cadence may quantize to two adjacent integer
    /// DTS steps even though it is constant-frame-rate. This twin uses 30 fps in a 1/1,201,212
    /// timebase, so one frame is exactly 200202/5 ticks and the packet ladder alternates between
    /// 40040 and 40041. Treating that normal quantization as VFR leaves the missing-ctts file in
    /// decode order and reproduces the visible judder from #409.
    @Test("an adjacent-tick rational ladder is repaired exactly, across multiple IDRs")
    func quantizedRationalTwinMatchesHealthyTwin() throws {
        let healthy = try Self.videoTimestamps(base64: Self.quantizedHealthyCTTSFixtureBase64)
        let repaired = try Self.videoTimestamps(base64: Self.quantizedMissingCTTSFixtureBase64)
        #expect(healthy.count == 66)
        #expect(repaired.count == healthy.count)
        #expect(repaired == healthy)
    }

    @Test("rational repair folds container keyframe indexes onto the healthy decode axis")
    func quantizedRationalIndexesMatchHealthyTwin() throws {
        let healthy = try Self.indexedKeyframes(base64: Self.quantizedHealthyCTTSFixtureBase64)
        let repaired = try Self.indexedKeyframes(base64: Self.quantizedMissingCTTSFixtureBase64)
        #expect(healthy.count == 3)
        #expect(repaired == healthy)
    }

    @Test("the healthy twin is delivered exactly as the container wrote it")
    func healthyTwinIsUntouched() throws {
        let healthy = try Self.videoTimestamps(base64: Self.healthyCTTSFixtureBase64)
        // Composition offsets present: reordered pictures, and a decode head one lead below zero.
        #expect(healthy.first == Timestamps(pts: 0, dts: -2002))
        #expect(healthy.contains { $0.pts != $0.dts })
        #expect(zip(healthy, healthy.dropFirst()).allSatisfy { $1.dts - $0.dts == 1001 })
    }

    @Test("the repaired stream presents every picture exactly once, in order")
    func repairedStreamIsABijection() throws {
        let repaired = try Self.videoTimestamps(base64: Self.missingCTTSFixtureBase64)
        let presentation = repaired.map(\.pts).sorted()
        #expect(Set(presentation).count == repaired.count)
        #expect(zip(presentation, presentation.dropFirst()).allSatisfy { $1 - $0 == 1001 })
        #expect(repaired.allSatisfy { $0.pts >= $0.dts })
        #expect(zip(repaired, repaired.dropFirst()).allSatisfy { $1.dts > $0.dts })
    }

    /// 96x64 H.264 Main, 30000/1001 fps, 66 frames, three B-frames per group, from PR #411.
    ///
    ///     ffmpeg -f lavfi -i 'color=c=red:s=96x64:r=30000/1001:d=2.2' -frames:v 66 \
    ///       -c:v libx264 -preset ultrafast -pix_fmt yuv420p -bf 3 -b_strategy 0 -g 66 \
    ///       -sc_threshold 0 -movflags +faststart healthy.mp4
    ///     ffmpeg -i healthy.mp4 -map 0:v:0 -c:v copy -bsf:v 'setts=pts=DTS' \
    ///       -movflags +faststart missing.mp4
    private static let healthyCTTSFixtureBase64 = """
        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
        b25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEu
        MDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpv
        bmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9MCB0aHJlYWRzPTIgbG9va2FoZWFkX3RocmVhZHM9MSBzbGlj
        ZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJh
        PTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MCBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTAgb3Blbl9nb3A9MCB3
        ZWlnaHRwPTAga2V5aW50PTY2IGtleWludF9taW49NiBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAg
        Y3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgcGJfcmF0aW89MS4zMCBh
        cT0wAIAAAAAmZYiEAOhGKAAIY8cAAQPY4AAh5ScnJycnXXXXXXXXXXXXXXXXXXgAAAAHQZokAOoMwAAAAAdBnkJANoMwAAAABwGe
        YUBdBmAAAAAHAZ5jQF0GYAAAAAhBmmg0QHUGYAAAAAlBnoZFEShtBmAAAAAHAZ6lQGUGYAAAAAcBnqdAZQZgAAAACEGarDRAfQZg
        AAAACUGeykUVKG0GYAAAAAcBnulAZQZgAAAABwGe60BlBmAAAAAIQZrwNEB9BmAAAAAJQZ8ORRUodQZgAAAABwGfLUBlBmAAAAAH
        AZ8vQG0GYAAAAAhBmzQ0QH0GYAAAAAlBn1JFFSh1BmAAAAAHAZ9xQG0GYAAAAAcBn3NAbQZgAAAACEGbeDRAfQZgAAAACUGflkUV
        KHUGYAAAAAcBn7VAbQZgAAAABwGft0BtBmAAAAAIQZu8NEB9BmAAAAAJQZ/aRRUodQZgAAAABwGf+UBtBmAAAAAHAZ/7QG0GYAAA
        AAhBm+A0QH0GYAAAAAlBnh5FFSh1BmAAAAAHAZ49QG0GYAAAAAcBnj9AbQZgAAAACEGaJDRAfQZgAAAACUGeQkUVKHUGYAAAAAcB
        nmFAbQZgAAAABwGeY0BtBmAAAAAIQZpoNEB9BmAAAAAJQZ6GRRUodQZgAAAABwGepUBtBmAAAAAHAZ6nQG0GYAAAAAhBmqw0QH0G
        YAAAAAlBnspFFSh1BmAAAAAHAZ7pQG0GYAAAAAcBnutAbQZgAAAACEGa8DRAfQZgAAAACUGfDkUVKHUGYAAAAAcBny1AbQZgAAAA
        BwGfL0BtBmAAAAAIQZs0NEB9BmAAAAAJQZ9SRRUodQZgAAAABwGfcUBtBmAAAAAHAZ9zQG0GYAAAAAhBm3g0QH0GYAAAAAlBn5ZF
        FSh1BmAAAAAHAZ+1QG0GYAAAAAcBn7dAbQZgAAAACEGbvDRAfQZgAAAACUGf2kUVKHUGYAAAAAcBn/lAbQZgAAAABwGf+0BtBmAA
        AAAIQZvgNEB9BmAAAAAJQZ4eRRUodQZgAAAABwGePUBtBmAAAAAHAZ4/QG0GYAAAAAhBmiE0QH0GYA==
        """

    private static let missingCTTSFixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAQpbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAACFgAAQAAAQAA
        AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
        A1N0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAACFgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
        AAAAAAAAAAAAAABAAAAAAGAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAhYAAAH0gABAAAAAALLbWRpYQAAACBtZGhk
        AAAAAAAAAAAAAAAAAAB1MAABAhJVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAACdm1p
        bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAjZzdGJsAAAAtnN0c2QA
        AAAAAAAAAQAAAKZhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAGAAQABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGli
        eDI2NAAAAAAAAAAAAAAAGP//AAAALGF2Y0MBTUAK/+EAFWdNQArsoxNgIgAAB9IAAdTAHiRLLAEABGjOD8gAAAAQcGFzcAAAAAEA
        AAABAAAAFGJ0cnQAAAAAAAAU8QAAFPEAAAAYc3R0cwAAAAAAAAABAAAAQgAAA+kAAAAUc3RzcwAAAAAAAAABAAAAAQAAABxzdHNj
        AAAAAAAAAAEAAAABAAAAQgAAAAEAAAEcc3RzegAAAAAAAAAAAAAAQgAAAssAAAALAAAACwAAAAsAAAALAAAADAAAAA0AAAALAAAA
        CwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAA
        AAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwA
        AAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAAL
        AAAADAAAABRzdGNvAAAAAAAAAAEAAARZAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAA
        AAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAABcxtZGF0AAACnQYF//+Z3EXp
        vebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHls
        ZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEg
        ZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0w
        IG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lw
        PTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBk
        ZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJh
        bWlkPTIgYl9hZGFwdD0wIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MCBvcGVuX2dvcD0wIHdlaWdodHA9MCBrZXlpbnQ9NjYg
        a2V5aW50X21pbj02IHNjZW5lY3V0PTAgaW50cmFfcmVmcmVzaD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYw
        IHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBwYl9yYXRpbz0xLjMwIGFxPTAAgAAAACZliIQA6EYoAAhj
        xwABA9jgACHlJycnJyddddddddddddddddddeAAAAAdBmiQA6gzAAAAAB0GeQkA2gzAAAAAHAZ5hQF0GYAAAAAcBnmNAXQZgAAAA
        CEGaaDRAdQZgAAAACUGehkURKG0GYAAAAAcBnqVAZQZgAAAABwGep0BlBmAAAAAIQZqsNEB9BmAAAAAJQZ7KRRUobQZgAAAABwGe
        6UBlBmAAAAAHAZ7rQGUGYAAAAAhBmvA0QH0GYAAAAAlBnw5FFSh1BmAAAAAHAZ8tQGUGYAAAAAcBny9AbQZgAAAACEGbNDRAfQZg
        AAAACUGfUkUVKHUGYAAAAAcBn3FAbQZgAAAABwGfc0BtBmAAAAAIQZt4NEB9BmAAAAAJQZ+WRRUodQZgAAAABwGftUBtBmAAAAAH
        AZ+3QG0GYAAAAAhBm7w0QH0GYAAAAAlBn9pFFSh1BmAAAAAHAZ/5QG0GYAAAAAcBn/tAbQZgAAAACEGb4DRAfQZgAAAACUGeHkUV
        KHUGYAAAAAcBnj1AbQZgAAAABwGeP0BtBmAAAAAIQZokNEB9BmAAAAAJQZ5CRRUodQZgAAAABwGeYUBtBmAAAAAHAZ5jQG0GYAAA
        AAhBmmg0QH0GYAAAAAlBnoZFFSh1BmAAAAAHAZ6lQG0GYAAAAAcBnqdAbQZgAAAACEGarDRAfQZgAAAACUGeykUVKHUGYAAAAAcB
        nulAbQZgAAAABwGe60BtBmAAAAAIQZrwNEB9BmAAAAAJQZ8ORRUodQZgAAAABwGfLUBtBmAAAAAHAZ8vQG0GYAAAAAhBmzQ0QH0G
        YAAAAAlBn1JFFSh1BmAAAAAHAZ9xQG0GYAAAAAcBn3NAbQZgAAAACEGbeDRAfQZgAAAACUGflkUVKHUGYAAAAAcBn7VAbQZgAAAA
        BwGft0BtBmAAAAAIQZu8NEB9BmAAAAAJQZ/aRRUodQZgAAAABwGf+UBtBmAAAAAHAZ/7QG0GYAAAAAhBm+A0QH0GYAAAAAlBnh5F
        FSh1BmAAAAAHAZ49QG0GYAAAAAcBnj9AbQZgAAAACEGaITRAfQZg
        """

    /// 96x64 H.264 Main, 30 fps, 66 frames, three IDR sequences. The deliberately unusual
    /// 1,201,212 track timescale makes one frame 200202/5 ticks, so the valid CFR ladder uses both
    /// 40040- and 40041-tick steps. Generated with:
    ///
    ///     ffmpeg -f lavfi -i 'color=c=red:s=96x64:r=30:d=2.2' -frames:v 66 \
    ///       -c:v libx264 -preset ultrafast -pix_fmt yuv420p -bf 3 -b_strategy 0 \
    ///       -g 22 -keyint_min 22 -sc_threshold 0 -video_track_timescale 1201212 \
    ///       -movflags +faststart healthy.mp4
    ///     ffmpeg -i healthy.mp4 -map 0:v:0 -c:v copy -bsf:v 'setts=pts=DTS' \
    ///       -movflags +faststart missing.mp4
    private static let quantizedHealthyCTTSFixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAfjbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAACJgAAQAAAQAAAAAAAAAA
        AAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAABw10cmFrAAAAXHRr
        aGQAAAADAAAAAAAAAAAAAAABAAAAAAAACJgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAGAA
        AABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAiYAAE40QABAAAAAAaFbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAABJUPAAoUupVxAAA
        AAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAGMG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5m
        AAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAABfBzdGJsAAAAuHN0c2QAAAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAA
        AAAAAGAAQABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBTUAK/+EAF2dNQArsoxNg
        IgAAAwACAAADAHgeJEssAQAEaM4PyAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABXKAAAAAAAAAbBzdHRzAAAAAAAAADQAAAABAACc
        aQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnGkAAAACAACcaAAAAAEAAJxp
        AAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnGkA
        AAACAACcaAAAAAEAAJxpAAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAA
        AAEAAJxoAAAAAQAAnGkAAAACAACcaAAAAAEAAJxpAAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAA
        AgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnGkAAAACAACcaAAAAAEAAJxpAAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAAC
        AACcaAAAABxzdHNzAAAAAAAAAAMAAAABAAAAFwAAAC0AAAIYY3R0cwAAAAAAAABBAAAAAQABONEAAAABAAMOCgAAAAEAATjRAAAAAQAAAAAA
        AAABAACcaAAAAAEAAw4KAAAAAQABONAAAAABAAAAAAAAAAEAAJxpAAAAAQADDgoAAAABAAE40QAAAAEAAAAAAAAAAQAAnGgAAAABAAMOCgAA
        AAEAATjRAAAAAQAAAAAAAAABAACcaAAAAAEAAw4KAAAAAQABONEAAAABAAAAAAAAAAEAAJxpAAAAAQABONAAAAABAAE40QAAAAEAAw4KAAAA
        AQABONEAAAABAAAAAAAAAAEAAJxoAAAAAQADDgoAAAABAAE40QAAAAEAAAAAAAAAAQAAnGkAAAABAAMOCgAAAAEAATjRAAAAAQAAAAAAAAAB
        AACcaAAAAAEAAw4KAAAAAQABONAAAAABAAAAAAAAAAEAAJxpAAAAAQADDgoAAAABAAE40QAAAAEAAAAAAAAAAQAAnGgAAAACAAE40QAAAAEA
        Aw4KAAAAAQABONAAAAABAAAAAAAAAAEAAJxpAAAAAQADDgoAAAABAAE40QAAAAEAAAAAAAAAAQAAnGgAAAABAAMOCgAAAAEAATjRAAAAAQAA
        AAAAAAABAACcaAAAAAEAAw4KAAAAAQABONEAAAABAAAAAAAAAAEAAJxpAAAAAQADDgoAAAABAAE40QAAAAEAAAAAAAAAAQAAnGgAAAABAAE4
        0QAAABxzdHNjAAAAAAAAAAEAAAABAAAAQgAAAAEAAAEcc3RzegAAAAAAAAAAAAAAQgAAAswAAAALAAAACwAAAAsAAAALAAAADAAAAA0AAAAL
        AAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAArAAAACwAAAAsAAAALAAAACwAAAAwA
        AAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAAKwAAAAsAAAALAAAACwAA
        AAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAABRzdGNvAAAA
        AAAAAAEAAAgTAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAA
        HWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAABgZtZGF0AAACngYF//+a3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2
        NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9s
        YW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9
        MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBj
        cW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0x
        IHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9
        MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0wIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MCBvcGVuX2dvcD0wIHdlaWdodHA9
        MCBrZXlpbnQ9MjIga2V5aW50X21pbj0xMiBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTIzLjAgcWNv
        bXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgcGJfcmF0aW89MS4zMCBhcT0wAIAAAAAmZYiEAOhGKAAI
        Y8cAAQPY4AAh5ScnJycnXXXXXXXXXXXXXXXXXXgAAAAHQZokAOoMwAAAAAdBnkJANoMwAAAABwGeYUBdBmAAAAAHAZ5jQF0GYAAAAAhBmmg0
        QHUGYAAAAAlBnoZFEShtBmAAAAAHAZ6lQGUGYAAAAAcBnqdAZQZgAAAACEGarDRAfQZgAAAACUGeykUVKG0GYAAAAAcBnulAZQZgAAAABwGe
        60BlBmAAAAAIQZrwNEB9BmAAAAAJQZ8ORRUodQZgAAAABwGfLUBlBmAAAAAHAZ8vQG0GYAAAAAhBmzQ0QH0GYAAAAAlBn1JFFSh1BmAAAAAH
        AZ9xQG0GYAAAAAcBn3NAbQZgAAAACEGbdTRAfQZgAAAAJ2WIggAEKEYoAAoSxwABGVjgACnhJycnJyddddddddddddddddddeAAAAAdBmiQA
        6gzAAAAAB0GeQkA2gzAAAAAHAZ5hQGUGYAAAAAcBnmNAZQZgAAAACEGaaDRAdQZgAAAACUGehkURKG0GYAAAAAcBnqVAZQZgAAAABwGep0Bl
        BmAAAAAIQZqsNEB9BmAAAAAJQZ7KRRUobQZgAAAABwGe6UBlBmAAAAAHAZ7rQGUGYAAAAAhBmvA0QH0GYAAAAAlBnw5FFSh1BmAAAAAHAZ8t
        QGUGYAAAAAcBny9AbQZgAAAACEGbNDRAfQZgAAAACUGfUkUVKHUGYAAAAAcBn3FAbQZgAAAABwGfc0BtBmAAAAAIQZt1NEB9BmAAAAAnZYiE
        ABChGKAAKEscAARlY4AAp4ScnJycnXXXXXXXXXXXXXXXXXXgAAAAB0GaJADqDMAAAAAHQZ5CQDaDMAAAAAcBnmFAZQZgAAAABwGeY0BlBmAA
        AAAIQZpoNEB1BmAAAAAJQZ6GRREobQZgAAAABwGepUBlBmAAAAAHAZ6nQGUGYAAAAAhBmqw0QH0GYAAAAAlBnspFFShtBmAAAAAHAZ7pQGUG
        YAAAAAcBnutAZQZgAAAACEGa8DRAfQZgAAAACUGfDkUVKHUGYAAAAAcBny1AZQZgAAAABwGfL0BtBmAAAAAIQZs0NEB9BmAAAAAJQZ9SRRUo
        dQZgAAAABwGfcUBtBmAAAAAHAZ9zQG0GYAAAAAhBm3U0QH0GYA==
        """

    private static let quantizedMissingCTTSFixtureBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAXLbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAACFYAAQAAAQAAAAAAAAAA
        AAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAABPV0cmFrAAAAXHRr
        aGQAAAADAAAAAAAAAAAAAAABAAAAAAAACFYAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAGAA
        AABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAhVAAE40QABAAAAAARtbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAABJUPAAoUupVxAAA
        AAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAEGG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5m
        AAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAA9hzdGJsAAAAuHN0c2QAAAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAA
        AAAAAGAAQABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBTUAK/+EAF2dNQArsoxNg
        IgAAAwACAAADAHgeJEssAQAEaM4PyAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABXKAAAVygAAAbBzdHRzAAAAAAAAADQAAAABAACc
        aQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnGkAAAACAACcaAAAAAEAAJxp
        AAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnGkA
        AAACAACcaAAAAAEAAJxpAAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAAAgAAnGgAAAABAACcaQAA
        AAEAAJxoAAAAAQAAnGkAAAACAACcaAAAAAEAAJxpAAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAABAACcaAAAAAEAAJxpAAAA
        AgAAnGgAAAABAACcaQAAAAEAAJxoAAAAAQAAnGkAAAACAACcaAAAAAEAAJxpAAAAAQAAnGgAAAABAACcaQAAAAIAAJxoAAAAAQAAnGkAAAAC
        AACcaAAAABxzdHNzAAAAAAAAAAMAAAABAAAAFwAAAC0AAAAcc3RzYwAAAAAAAAABAAAAAQAAAEIAAAABAAABHHN0c3oAAAAAAAAAAAAAAEIA
        AALMAAAACwAAAAsAAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAA
        AAsAAAAMAAAAKwAAAAsAAAALAAAACwAAAAsAAAAMAAAADQAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAA
        DQAAAAsAAAALAAAADAAAACsAAAALAAAACwAAAAsAAAALAAAADAAAAA0AAAALAAAACwAAAAwAAAANAAAACwAAAAsAAAAMAAAADQAAAAsAAAAL
        AAAADAAAAA0AAAALAAAACwAAAAwAAAAUc3RjbwAAAAAAAAABAAAF+wAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJh
        cHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAyAAAACGZyZWUAAAYGbWRhdAAAAp4GBf//
        mtxF6b3m2Ui3lizYINkj7u94MjY0IC0gY29yZSAxNjUgcjMyMjIgYjM1NjA1YSAtIEguMjY0L01QRUctNCBBVkMgY29kZWMgLSBDb3B5bGVm
        dCAyMDAzLTIwMjUgLSBodHRwOi8vd3d3LnZpZGVvbGFuLm9yZy94MjY0Lmh0bWwgLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9
        MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBj
        aHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAgY3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYV9xcF9vZmZzZXQ9
        MCB0aHJlYWRzPTIgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1
        cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MCBiX2JpYXM9MCBkaXJlY3Q9
        MSB3ZWlnaHRiPTAgb3Blbl9nb3A9MCB3ZWlnaHRwPTAga2V5aW50PTIyIGtleWludF9taW49MTIgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNo
        PTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIHBi
        X3JhdGlvPTEuMzAgYXE9MACAAAAAJmWIhADoRigACGPHAAED2OAAIeUnJycnJ1111111111111111114AAAAB0GaJADqDMAAAAAHQZ5CQDaD
        MAAAAAcBnmFAXQZgAAAABwGeY0BdBmAAAAAIQZpoNEB1BmAAAAAJQZ6GRREobQZgAAAABwGepUBlBmAAAAAHAZ6nQGUGYAAAAAhBmqw0QH0G
        YAAAAAlBnspFFShtBmAAAAAHAZ7pQGUGYAAAAAcBnutAZQZgAAAACEGa8DRAfQZgAAAACUGfDkUVKHUGYAAAAAcBny1AZQZgAAAABwGfL0Bt
        BmAAAAAIQZs0NEB9BmAAAAAJQZ9SRRUodQZgAAAABwGfcUBtBmAAAAAHAZ9zQG0GYAAAAAhBm3U0QH0GYAAAACdliIIABChGKAAKEscAARlY
        4AAp4ScnJycnXXXXXXXXXXXXXXXXXXgAAAAHQZokAOoMwAAAAAdBnkJANoMwAAAABwGeYUBlBmAAAAAHAZ5jQGUGYAAAAAhBmmg0QHUGYAAA
        AAlBnoZFEShtBmAAAAAHAZ6lQGUGYAAAAAcBnqdAZQZgAAAACEGarDRAfQZgAAAACUGeykUVKG0GYAAAAAcBnulAZQZgAAAABwGe60BlBmAA
        AAAIQZrwNEB9BmAAAAAJQZ8ORRUodQZgAAAABwGfLUBlBmAAAAAHAZ8vQG0GYAAAAAhBmzQ0QH0GYAAAAAlBn1JFFSh1BmAAAAAHAZ9xQG0G
        YAAAAAcBn3NAbQZgAAAACEGbdTRAfQZgAAAAJ2WIhAAQoRigAChLHAAEZWOAAKeEnJycnJ1111111111111111114AAAAAdBmiQA6gzAAAAA
        B0GeQkA2gzAAAAAHAZ5hQGUGYAAAAAcBnmNAZQZgAAAACEGaaDRAdQZgAAAACUGehkURKG0GYAAAAAcBnqVAZQZgAAAABwGep0BlBmAAAAAI
        QZqsNEB9BmAAAAAJQZ7KRRUobQZgAAAABwGe6UBlBmAAAAAHAZ7rQGUGYAAAAAhBmvA0QH0GYAAAAAlBnw5FFSh1BmAAAAAHAZ8tQGUGYAAA
        AAcBny9AbQZgAAAACEGbNDRAfQZgAAAACUGfUkUVKHUGYAAAAAcBn3FAbQZgAAAABwGfc0BtBmAAAAAIQZt1NEB9BmA=
        """
}
