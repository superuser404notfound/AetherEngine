import Testing
import AetherLibavcodec
@testable import AetherEngine

/// An AirPlay receiver that shows video takes a stream, not a composed picture: a Profile 7 FEL source
/// keeps the native route (8.1) while one holds the audio route, an audio-only output does not change the
/// route, and a mirrored screen is not a local-only picture.
@Suite("AirPlay and the software host")
struct AirPlayParityTests {

    @Test("only a wireless route whose receiver shows video yields; a speaker on the route does not")
    func audioOnlyOutputKeepsFEL() {
        #expect(AetherEngine.airPlayVideoReceiverHoldsRoute(wirelessAirPlayRoute: true, receiverShowsVideo: true))
        #expect(!AetherEngine.airPlayVideoReceiverHoldsRoute(wirelessAirPlayRoute: true, receiverShowsVideo: false))
        #expect(!AetherEngine.airPlayVideoReceiverHoldsRoute(wirelessAirPlayRoute: false, receiverShowsVideo: true))
    }

    @Test("a mirrored screen carries the software picture to the receiver")
    func mirroringIsNotLocalOnly() {
        #expect(AetherEngine.airPlayPictureStaysLocal(
            backend: .software, wirelessAirPlayRoute: true, screenMirrored: false))
        #expect(!AetherEngine.airPlayPictureStaysLocal(
            backend: .software, wirelessAirPlayRoute: true, screenMirrored: true))
        #expect(!AetherEngine.airPlayPictureStaysLocal(
            backend: .software, wirelessAirPlayRoute: false, screenMirrored: true))
    }

    @Test("the host-reported flags default off and the setters store them")
    @MainActor func hostFlags() throws {
        let engine = try AetherEngine()
        #expect(!engine.airPlayReceiverShowsVideo)
        #expect(!engine.screenMirrored)
        engine.setAirPlayReceiverShowsVideo(true)
        engine.setScreenMirrored(true)
        #expect(engine.airPlayReceiverShowsVideo)
        #expect(engine.screenMirrored)
        engine.setScreenMirrored(false)
        #expect(!engine.screenMirrored)
        // Off iOS the route is never wireless, so the flag cannot turn on from these inputs alone.
        #expect(!engine.airPlayPictureStaysLocal)
    }

    @Test("the software play gate expects no inbound write for a host that leaves the write to AVKit")
    func softwareGateGrace() {
        // The software host has no AVPlayerItem for AVKit to read criteria from.
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: false, criteriaWrittenBeforeLoad: false, formatKnown: true,
            effectiveFormat: .dolbyVision, noWriterExpected: true) == .skip)
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: false, criteriaWrittenBeforeLoad: true, formatKnown: true,
            effectiveFormat: .dolbyVision, noWriterExpected: false) == .brief)
    }
}

#if DualLayerDolbyVision
/// The decision cases need the composer built in: without the trait every Profile 7 decision is `notBuiltIn`.
@Suite("AirPlay video receiver and the dual-layer route")
struct AirPlayDualLayerDecisionTests {

    private let uhd24 = DualLayerRouteDecision.Geometry(width: 3840, height: 2160, frameRate: 24000.0 / 1001.0)

    private func decide(videoReceiver: Bool) -> DualLayerRouteDecision {
        DualLayerRouteDecision.decide(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true, isLive: false, isSourceSeekable: true,
            canHardwareDecode: { true }, elType: "FEL", geometry: uhd24,
            airPlayVideoReceiver: videoReceiver)
    }

    private func blockingReason(videoReceiver: Bool, preference: Bool = true,
                                hardware: (() -> Bool)? = { true }) -> DualLayerRouteDecision.Reason? {
        DualLayerRouteDecision.blockingReasonBeforeProbe(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: preference, isLive: false, isSourceSeekable: true,
            canHardwareDecode: hardware, airPlayVideoReceiver: videoReceiver)
    }

    @Test("a FEL source keeps the dual-layer route off an AirPlay video receiver and takes it otherwise")
    func felYieldsToTheVideoReceiver() {
        #expect(decide(videoReceiver: false).isTaken)
        #expect(decide(videoReceiver: true) == .notTaken(.airPlayVideoReceiver))
        #expect(decide(videoReceiver: true).logLine?
            .hasSuffix(DualLayerRouteDecision.Reason.nativeRouteFallback) == true)
    }

    @Test("the receiver check is a pre-probe reason, so the el_type scan is skipped for it")
    func receiverBlocksBeforeTheProbe() {
        #expect(blockingReason(videoReceiver: true) == .airPlayVideoReceiver)
        #expect(blockingReason(videoReceiver: false) == nil)
    }

    @Test("every earlier reason outranks the receiver")
    func earlierReasonsOutrankTheReceiver() {
        #expect(blockingReason(videoReceiver: true, preference: false) == .preferenceOff)
        #expect(blockingReason(videoReceiver: true, hardware: { false }) == .noHardwareHEVC)
    }
}
#endif
