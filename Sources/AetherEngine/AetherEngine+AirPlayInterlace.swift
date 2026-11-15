import Foundation

// AE#1070: a session the declared-interlace rule routed follows the AirPlay receiver mid-session. The
// viewer starts on the device (software deinterlacer), then picks an Apple TV: without a reload the
// receiver keeps playing the sound of a picture it never gets. The reload's load path decides the route
// again (`VideoRoutingPolicy.declaredInterlaceYieldsToAirPlayReceiver`), so this only has to notice that
// the answer would differ from the one the session loaded with.
extension AetherEngine {

    /// Whether a session loaded under `receiverAtLoad` should reload now that a video receiver does (or
    /// does not) hold the route. nil `receiverAtLoad` means interlace did not decide the route.
    nonisolated static func interlaceRouteNeedsReload(
        receiverAtLoad: Bool?,
        receiverNow: Bool,
        sessionSettled: Bool,
        reopensAtPosition: Bool
    ) -> Bool {
        guard let receiverAtLoad, sessionSettled, reopensAtPosition else { return false }
        return receiverAtLoad != receiverNow
    }

    /// Only a session the interlace rule put on the software host because no video receiver was
    /// reported moves; a FEL source or a codec with no native route stays where it is.
    nonisolated static func airPlayPictureCanMoveToReceiver(
        staysLocal: Bool, interlaceReceiverAtLoad: Bool?, reopensAtPosition: Bool
    ) -> Bool {
        staysLocal && interlaceReceiverAtLoad == false && reopensAtPosition
    }

    /// A URL source reopens at the playhead, a live one rejoins its edge. A forward-only VOD source would
    /// restart from byte 0, and a custom source keeps its route until the next load.
    var interlaceRouteReopensAtPosition: Bool {
        !isCustomSource && loadedURL != nil && (loadedOptions.isLive || isSourceSeekable == true)
    }

    func recheckInterlaceRouteForAirPlayReceiver() {
        #if os(iOS)
        let receiverNow = Self.airPlayVideoReceiverHoldsRoute(
            wirelessAirPlayRoute: Self.isWirelessAirPlayRoute(),
            receiverShowsVideo: airPlayReceiverShowsVideo)
        let settled: Bool = switch state {
        case .playing, .paused: !sessionPreservingReloadInFlight
        default: false
        }
        guard Self.interlaceRouteNeedsReload(
            receiverAtLoad: interlaceRouteReceiverAtLoad, receiverNow: receiverNow,
            sessionSettled: settled, reopensAtPosition: interlaceRouteReopensAtPosition) else { return }
        // Written now so a burst of route notifications reloads once.
        let receiverBefore = interlaceRouteReceiverAtLoad
        interlaceRouteReceiverAtLoad = receiverNow
        EngineLog.emit(
            "[AirPlay] AE#1070 interlaced H.264: a video receiver \(receiverNow ? "now holds" : "let go of") "
            + "the route; reloading onto the \(receiverNow ? "native route so it gets the picture" : "software deinterlacer")",
            category: .engine)
        Task {
            do {
                try await reloadAtCurrentPosition()
            } catch {
                // A reload that threw before its load decided the route again leaves the session where it
                // was, so the next route change has to see the old answer and try again.
                if interlaceRouteReceiverAtLoad == receiverNow { interlaceRouteReceiverAtLoad = receiverBefore }
                EngineLog.emit("[AirPlay] AE#1070 interlace route reload failed: \(error)", category: .engine)
            }
        }
        #endif
    }
}
