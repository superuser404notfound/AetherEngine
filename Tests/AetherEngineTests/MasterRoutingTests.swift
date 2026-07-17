import Testing
@testable import AetherEngine

/// Master-vs-media playlist routing matrix (#4, #15, #63, on-demand gate). The decision is pure
/// so the platform matrix is testable offline: tvOS gates HDR masters on the panel being ALREADY
/// in HDR mode (an SDR-parked external panel rejects an HDR master with -11848), while iOS and
/// macOS built-in panels engage EDR on demand, so HDR-eligibility
/// (AVPlayer.eligibleForHDRPlayback) is the readiness signal there (#98). Without the iOS gate
/// every HDR/DV film on iPhone routed media-direct, whose playlist has no SUBTITLES renditions,
/// so PiP subtitles silently never worked for them.
@MainActor
struct MasterRoutingTests {

    private func route(videoRange: HLSVideoRange,
                       effectiveDvMode: Bool = false, panelHDR: Bool = false,
                       displayHDR: Bool = false, nativeSubs: Bool = false,
                       panelEngagesOnDemand: Bool = false,
                       frameRateKnown: Bool = true) -> Bool {
        HLSVideoEngine.resolveUseMasterPlaylist(
            videoRange: videoRange, effectiveDvMode: effectiveDvMode,
            panelIsInHDRMode: panelHDR, displaySupportsHDR: displayHDR,
            hasNativeSubs: nativeSubs, builtInPanelEngagesOnDemand: panelEngagesOnDemand,
            frameRateKnown: frameRateKnown)
    }

    @Test("tvOS: HDR source on an SDR-parked panel stays media-direct (-11848 guard)")
    func tvOSHDROnSDRPanel() {
        #expect(!route(videoRange: .pq, displayHDR: true))
        #expect(!route(videoRange: .pq, displayHDR: true, nativeSubs: true))
    }

    @Test("tvOS: HDR source on an HDR-active panel routes master")
    func tvOSHDROnHDRPanel() {
        #expect(route(videoRange: .pq, panelHDR: true, displayHDR: true))
    }

    @Test("iOS: HDR source on an HDR-eligible built-in panel routes master (PiP subs)")
    func iOSHDREligible() {
        #expect(route(videoRange: .pq, displayHDR: true, nativeSubs: true, panelEngagesOnDemand: true))
        #expect(route(videoRange: .pq, displayHDR: true, panelEngagesOnDemand: true))
    }

    @Test("iOS: HDR source on a non-HDR-eligible device stays media-direct")
    func iOSHDRIneligible() {
        #expect(!route(videoRange: .pq, displayHDR: false, panelEngagesOnDemand: true))
    }

    @Test("SDR with native subs forces the master on any panel")
    func sdrSubsMaster() {
        #expect(route(videoRange: .sdr, nativeSubs: true))
        #expect(route(videoRange: .sdr, nativeSubs: true, panelEngagesOnDemand: true))
    }

    @Test("SDR without native subs stays media-direct")
    func sdrNoSubs() {
        #expect(!route(videoRange: .sdr))
    }

    // P5/P8.x route by videoRange (.pq) + panel readiness, with NO per-variant special-case. The
    // P5 rows below stand in for a bare dvh1.05 master (non-DV panel, effectiveDvMode=false): it is
    // accepted and tonemapped from 26.5 (#98), so P5 masters on a ready HDR panel exactly like plain
    // HDR10. Do not reinstate the old always-media-direct P5 guard; it was compensating for an
    // earlier malformed master, not a platform limitation.

    @Test("DV P5 (non-DV panel) routes master on a ready HDR panel, media-direct on an SDR route (#98)")
    func dv5RoutesByPanelReadiness() {
        // tvOS handshake done (panelHDR) or iOS/macOS engage-on-demand + eligible: master.
        #expect(route(videoRange: .pq, effectiveDvMode: false, panelHDR: true, displayHDR: true))
        #expect(route(videoRange: .pq, effectiveDvMode: false,
                      displayHDR: true, panelEngagesOnDemand: true))
        // SDR route (DrHurt's external SDR monitor): media-direct, no HDR master to reject.
        #expect(!route(videoRange: .pq, effectiveDvMode: false, panelHDR: false, displayHDR: false))
    }

    @Test("DV P8.x with DV mode active routes master when the panel is ready")
    func dv81Master() {
        #expect(route(videoRange: .pq, effectiveDvMode: true, panelHDR: true))
        #expect(route(videoRange: .pq, effectiveDvMode: true,
                      displayHDR: true, panelEngagesOnDemand: true))
    }

    // #130: AVPlayer hard-rejects a VIDEO-RANGE=PQ/HLG EXT-X-STREAM-INF that carries no
    // FRAME-RATE attribute with NSURLErrorDomain -1002 (variant filtered at master parse,
    // media.m3u8 never fetched; byte-exact repro against the served 213-byte master). A live
    // MPEG-TS probe can leave avg/r_frame_rate unset, so an HDR master without a known frame
    // rate must route media-direct instead of serving a master AVPlayer provably rejects.
    // SDR masters (VIDEO-RANGE=SDR) are accepted without FRAME-RATE, so the subs-forced SDR
    // master keeps working for frame-rate-less sources.

    @Test("#130: HDR master requires a known frame rate; unknown routes media-direct")
    func hdrMasterRequiresFrameRate() {
        #expect(!route(videoRange: .pq, panelHDR: true, displayHDR: true, frameRateKnown: false))
        #expect(!route(videoRange: .hlg, panelHDR: true, displayHDR: true, frameRateKnown: false))
        #expect(!route(videoRange: .pq, displayHDR: true, panelEngagesOnDemand: true,
                       frameRateKnown: false))
        #expect(!route(videoRange: .pq, effectiveDvMode: true, panelHDR: true,
                       frameRateKnown: false))
    }

    @Test("#130: subs-forced master obeys the same frame-rate invariant on HDR sources")
    func subsMasterObeysFrameRateInvariant() {
        #expect(!route(videoRange: .pq, panelHDR: true, displayHDR: true, nativeSubs: true,
                       frameRateKnown: false))
        // SDR master carries VIDEO-RANGE=SDR, which AVPlayer accepts without FRAME-RATE.
        #expect(route(videoRange: .sdr, nativeSubs: true, frameRateKnown: false))
    }

    @Test("macOS built-in panels count as engage-on-demand (#98); tvOS keeps the handshake path")
    func platformOnDemandGate() {
        #if os(macOS) || os(iOS)
        #expect(HLSVideoEngine.builtInPanelEngagesOnDemand)
        #elseif os(tvOS)
        #expect(!HLSVideoEngine.builtInPanelEngagesOnDemand)
        #endif
    }
}
