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

    private func route(videoRange: HLSVideoRange, dvVariant: HLSVideoEngine.DVVariant = .none,
                       effectiveDvMode: Bool = false, panelHDR: Bool = false,
                       displayHDR: Bool = false, nativeSubs: Bool = false,
                       panelEngagesOnDemand: Bool = false) -> Bool {
        HLSVideoEngine.resolveUseMasterPlaylist(
            videoRange: videoRange, dvVariant: dvVariant, effectiveDvMode: effectiveDvMode,
            panelIsInHDRMode: panelHDR, displaySupportsHDR: displayHDR,
            hasNativeSubs: nativeSubs, builtInPanelEngagesOnDemand: panelEngagesOnDemand)
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

    @Test("DV Profile 5 on a non-DV panel is always media-direct (-11868 guard)")
    func dv5NonDVPanel() {
        #expect(!route(videoRange: .pq, dvVariant: .profile5, effectiveDvMode: false,
                       panelHDR: true, displayHDR: true))
        #expect(!route(videoRange: .pq, dvVariant: .profile5, displayHDR: true,
                       nativeSubs: true, panelEngagesOnDemand: true))
    }

    @Test("DV P8.1 with DV mode active routes master when the panel is ready")
    func dv81Master() {
        #expect(route(videoRange: .pq, dvVariant: .profile81, effectiveDvMode: true, panelHDR: true))
        #expect(route(videoRange: .pq, dvVariant: .profile81, effectiveDvMode: true,
                      displayHDR: true, panelEngagesOnDemand: true))
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
