import Testing
import AetherLibavcodec
@testable import AetherEngine

/// AE#1070: interlaced H.264 sent to the software deinterlacer played sound only on an Apple TV picked
/// from the AirPlay button, because the software host's layer stays on the device.
@Suite("AE#1070 interlaced H.264 follows an AirPlay video receiver")
struct Issue1070AirPlayInterlaceTests {

    private func declaredInterlaceRoutes(_ codec: AVCodecID, _ order: AVFieldOrder, sps: Bool = false) -> Bool {
        VideoRoutingPolicy.requiresSoftwarePath(
            codecID: codec, fieldOrder: order, av1Available: true, spsIndicatesInterlaced: sps)
            && VideoRoutingPolicy.routesSoftwareForDeclaredInterlace(
                codecID: codec, fieldOrder: order, spsIndicatesInterlaced: sps)
    }

    @Test("1080i H.264 takes the native route while a video receiver holds the wireless route")
    func interlacedYieldsToVideoReceiver() {
        for (order, sps) in [(AV_FIELD_TT, false), (AV_FIELD_BB, false), (AV_FIELD_UNKNOWN, true)] {
            let routes = declaredInterlaceRoutes(AV_CODEC_ID_H264, order, sps: sps)
            #expect(routes)
            #expect(VideoRoutingPolicy.declaredInterlaceYieldsToAirPlayReceiver(
                declaredInterlaceRoutesSoftware: routes,
                airPlayVideoReceiver: AetherEngine.airPlayVideoReceiverHoldsRoute(
                    wirelessAirPlayRoute: true, receiverShowsVideo: true)))
        }
    }

    @Test("an audio-only or unknown receiver keeps the software deinterlacer")
    func audioOnlyReceiverKeepsDeinterlacer() {
        for (wireless, shows) in [(true, false), (false, true), (false, false)] {
            #expect(!VideoRoutingPolicy.declaredInterlaceYieldsToAirPlayReceiver(
                declaredInterlaceRoutesSoftware: true,
                airPlayVideoReceiver: AetherEngine.airPlayVideoReceiverHoldsRoute(
                    wirelessAirPlayRoute: wireless, receiverShowsVideo: shows)))
        }
    }

    @Test("MPEG-2 and VC-1 have no native route, so interlace is not what routes them")
    func softwareOnlyCodecsNeverYield() {
        for codec in [AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1] {
            #expect(!declaredInterlaceRoutes(codec, AV_FIELD_TT))
        }
    }

    @Test("the host's 'show it on the TV' action is offered only where it moves the picture")
    func canMoveToReceiver() {
        #expect(AetherEngine.airPlayPictureCanMoveToReceiver(
            staysLocal: true, interlaceReceiverAtLoad: false, reopensAtPosition: true))
        // VP9, MPEG-2, a host-forced software path: interlace did not decide the route.
        #expect(!AetherEngine.airPlayPictureCanMoveToReceiver(
            staysLocal: true, interlaceReceiverAtLoad: nil, reopensAtPosition: true))
        // Already on the native route for the receiver, or the picture is not local at all.
        #expect(!AetherEngine.airPlayPictureCanMoveToReceiver(
            staysLocal: true, interlaceReceiverAtLoad: true, reopensAtPosition: true))
        #expect(!AetherEngine.airPlayPictureCanMoveToReceiver(
            staysLocal: false, interlaceReceiverAtLoad: false, reopensAtPosition: true))
        // Forward-only VOD or a custom source.
        #expect(!AetherEngine.airPlayPictureCanMoveToReceiver(
            staysLocal: true, interlaceReceiverAtLoad: false, reopensAtPosition: false))
    }

    @Test("reload only on a real change of a settled, reopenable session the interlace rule routed")
    func reloadDecision() {
        // Viewer picks the Apple TV mid-session, then lets go again.
        #expect(AetherEngine.interlaceRouteNeedsReload(
            receiverAtLoad: false, receiverNow: true, sessionSettled: true, reopensAtPosition: true))
        #expect(AetherEngine.interlaceRouteNeedsReload(
            receiverAtLoad: true, receiverNow: false, sessionSettled: true, reopensAtPosition: true))
        // Route notifications that change nothing about the receiver.
        #expect(!AetherEngine.interlaceRouteNeedsReload(
            receiverAtLoad: true, receiverNow: true, sessionSettled: true, reopensAtPosition: true))
        // Interlace had no say (progressive, refuted by the #232 sample, other codec).
        #expect(!AetherEngine.interlaceRouteNeedsReload(
            receiverAtLoad: nil, receiverNow: true, sessionSettled: true, reopensAtPosition: true))
        // Loading or mid-reload: that load decides with the current receiver itself.
        #expect(!AetherEngine.interlaceRouteNeedsReload(
            receiverAtLoad: false, receiverNow: true, sessionSettled: false, reopensAtPosition: true))
        // Forward-only VOD or a custom source cannot reopen at the playhead.
        #expect(!AetherEngine.interlaceRouteNeedsReload(
            receiverAtLoad: false, receiverNow: true, sessionSettled: true, reopensAtPosition: false))
    }

    /// Audit LOAD-207: the catch restored the old answer whenever the field still read the new one.
    /// A host load that superseded the reload and routed with no receiver writes that same value, and
    /// the restore then told the new session it was loaded under a receiver, so picking an Apple TV
    /// later never moved its picture.
    @Test("a failed reload restores the old receiver answer only when no load ran since the decision")
    func failedReloadRestore() {
        // Threw before its teardown (a refused reload): the session is the one the decision saw.
        #expect(AetherEngine.interlaceReloadFailureRestoresReceiver(
            generationAtDecision: 7, generationNow: 7, receiverAtLoadNow: false, receiverNow: false))
        // A host load superseded it and decided the route itself, with the same answer.
        #expect(!AetherEngine.interlaceReloadFailureRestoresReceiver(
            generationAtDecision: 7, generationNow: 9, receiverAtLoadNow: false, receiverNow: false))
        // The reload's own load failed after its teardown.
        #expect(!AetherEngine.interlaceReloadFailureRestoresReceiver(
            generationAtDecision: 7, generationNow: 8, receiverAtLoadNow: nil, receiverNow: true))
        // Something else wrote another answer meanwhile.
        #expect(!AetherEngine.interlaceReloadFailureRestoresReceiver(
            generationAtDecision: 7, generationNow: 7, receiverAtLoadNow: true, receiverNow: false))
    }
}
