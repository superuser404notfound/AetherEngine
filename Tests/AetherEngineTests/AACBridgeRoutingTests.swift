import Testing
@testable import AetherEngine

/// Routing decision for AAC sources: HE-AAC / HE-AACv2 only needs the
/// `AudioBridge` when the source carries no AudioSpecificConfig (live
/// ADTS/MPEG-TS). With an ASC present (any movie container) it stream-
/// copies and AVPlayer decodes it natively (AetherEngine#33).
///
/// libavcodec FF_PROFILE constants: AAC_LOW = 1, AAC_HE = 4, AAC_HE_V2 = 28.
@Suite("AAC bridge routing")
struct AACBridgeRoutingTests {

    @Test("HE-AAC with an ASC stream-copies (issue #33)")
    func heAacWithASCStreamCopies() {
        #expect(HLSVideoEngine.aacRequiresBridge(profile: 4, frameSize: 2048, hasASC: true) == false)
    }

    @Test("HE-AACv2 with an ASC stream-copies (issue #33)")
    func heAacV2WithASCStreamCopies() {
        #expect(HLSVideoEngine.aacRequiresBridge(profile: 28, frameSize: 2048, hasASC: true) == false)
    }

    @Test("HE-AAC without an ASC (live ADTS) bridges")
    func heAacWithoutASCBridges() {
        #expect(HLSVideoEngine.aacRequiresBridge(profile: 4, frameSize: 2048, hasASC: false) == true)
    }

    @Test("HE-AACv2 without an ASC bridges")
    func heAacV2WithoutASCBridges() {
        #expect(HLSVideoEngine.aacRequiresBridge(profile: 28, frameSize: 2048, hasASC: false) == true)
    }

    @Test("SBR frame_size of 2048 without an ASC bridges even with an unset profile")
    func sbrFrameSizeWithoutASCBridges() {
        #expect(HLSVideoEngine.aacRequiresBridge(profile: -99, frameSize: 2048, hasASC: false) == true)
    }

    @Test("AAC-LC stream-copies with or without an ASC")
    func aacLowComplexityStreamCopies() {
        #expect(HLSVideoEngine.aacRequiresBridge(profile: 1, frameSize: 1024, hasASC: true) == false)
        #expect(HLSVideoEngine.aacRequiresBridge(profile: 1, frameSize: 1024, hasASC: false) == false)
    }
}
