import Testing
@testable import AetherEngine

// #133 Issue A: joining a live MPEG-TS H.264 broadcast mid-stream, the existing keyframe gate opened on
// any AV_PKT_FLAG_KEY packet without confirming a decodable IDR access unit (in-band SPS+PPS+IDR). That
// produced green frames (params not yet seen) or, when the probe never resolved dimensions, a 0x0 muxer
// whose avformat_write_header failed (-22) and dead-ended the channel with no live recovery arm.
//
// The stricter join gate only engages where it is both needed and safe: live H.264 with Annex-B framing
// (MPEG-TS ingest). fMP4 live carries valid out-of-band avcC so its keyframes are already decodable, and
// VOD probes the whole file up front. This suite covers that scoping DECISION.
@Suite("Live H.264 mid-stream join gate scoping")
struct LiveH264JoinGateTests {

    @Test("Engages for live H.264 Annex-B ingest (the MPEG-TS join case)")
    func engagesForLiveH264AnnexB() {
        #expect(HLSSegmentProducer.liveH264JoinRequiresParameterSets(
            isLive: true, codecIsH264: true, framingIsAnnexB: true) == true)
    }

    @Test("Does not engage for VOD (full-file probe already resolved dimensions)")
    func skipsForVOD() {
        #expect(HLSSegmentProducer.liveH264JoinRequiresParameterSets(
            isLive: false, codecIsH264: true, framingIsAnnexB: true) == false)
    }

    @Test("Does not engage for length-prefixed (fMP4 / avcC) live H.264")
    func skipsForLengthPrefixedFraming() {
        #expect(HLSSegmentProducer.liveH264JoinRequiresParameterSets(
            isLive: true, codecIsH264: true, framingIsAnnexB: false) == false)
    }

    @Test("Does not engage for non-H.264 codecs (HEVC keeps the existing keyframe gate)")
    func skipsForNonH264() {
        #expect(HLSSegmentProducer.liveH264JoinRequiresParameterSets(
            isLive: true, codecIsH264: false, framingIsAnnexB: true) == false)
    }
}

// #133 follow-up: the join gate absorbs the INITIAL join, but the same "non-existing PPS/SPS" condition recurs
// mid-stream on some UK-DVB-via-Xtream channels (encoder restart / regional splice on the SAME video PID) long
// after readyToPlay, as recurring green frames. The fMP4 avcC froze at write_header, so new in-band SPS/PPS need
// a versioned-init muxer rotation. This suite covers the DECISION of when a keyframe's sets diverge from the ones
// backing the current muxer's avcC.
@Suite("Same-PID in-band parameter-set change detection")
struct SamePIDParameterSetChangeTests {

    @Test("No baseline yet: the first keyframe establishes it, never a false rotation")
    func noBaselineDoesNotDiverge() {
        #expect(HLSSegmentProducer.parameterSetsDiverged(active: nil, incoming: [0, 0, 0, 1, 0x67]) == false)
    }

    @Test("Byte-identical sets (routine per-IDR SPS/PPS repetition) do not diverge")
    func identicalSetsDoNotDiverge() {
        let sets: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f, 0, 0, 0, 1, 0x68, 0xce]
        #expect(HLSSegmentProducer.parameterSetsDiverged(active: sets, incoming: sets) == false)
    }

    @Test("Changed sets (encoder restart / splice) diverge and trigger a rotation")
    func changedSetsDiverge() {
        let active: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1f, 0, 0, 0, 1, 0x68, 0xce]
        let incoming: [UInt8] = [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x28, 0, 0, 0, 1, 0x68, 0xee]
        #expect(HLSSegmentProducer.parameterSetsDiverged(active: active, incoming: incoming) == true)
    }

    @Test("Same SPS/PPS content, different length also diverges")
    func differentLengthDiverges() {
        let active: [UInt8] = [0, 0, 0, 1, 0x67, 0x42]
        let incoming: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0x00]
        #expect(HLSSegmentProducer.parameterSetsDiverged(active: active, incoming: incoming) == true)
    }
}
