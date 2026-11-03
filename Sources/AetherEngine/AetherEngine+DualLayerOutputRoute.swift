import AVFoundation
import Foundation

/// The lifecycle of `DualLayerOutputRoute` for a session (`LoadOptions.dualLayerRoute == .avPlayerOutput`).
extension AetherEngine {

    /// The layer the route draws the composed picture in, over the player layer; nil on every other session.
    var dualLayerOutputLayer: CALayer? {
        #if DualLayerDolbyVision
        return dualLayerOutputRoute?.displayLayer
        #else
        return nil
        #endif
    }

    /// Builds the route for the session `loadNative` is about to start and hands its tap to the session, so
    /// the first producer already feeds it. A no-op unless the load's route decision chose the route.
    ///
    /// Every rebuild of the session passes here, not only the first load: the reload an AirPlay or
    /// external-display edge starts decides again, and when another screen holds the picture the route
    /// stays off and AVPlayer plays the 8.1 base layer.
    func prepareDualLayerOutputRoute(session: HLSVideoEngine) {
        #if DualLayerDolbyVision
        stopDualLayerOutputRoute()
        guard let frameRate = outputRouteFrameRate else { return }
        guard DualLayerRouteDecision.outputRouteMayStart(
            frameRate: frameRate, externalPlaybackHoldsThePicture: airPlayActive || externalPlaybackHoldsThePicture) else {
            EngineLog.emit("[DualLayerOutputRoute] another screen holds the picture (AirPlay or an external display); "
                           + "AVPlayer shows the 8.1 base layer and the enhancement layer is not composed",
                           category: .engine)
            return
        }
        // In place by default, as on the software host: the composer writes into the buffer the video output
        // vended instead of a pool buffer of its own, and still takes the pool for a frame it cannot compose
        // in place. `AETHER_FEL_OUTPUT_INPLACE=0` turns it off for an A/B run.
        let inPlace = ProcessInfo.processInfo.environment["AETHER_FEL_OUTPUT_INPLACE"] != "0"
        guard let route = DualLayerOutputRoute(frameRate: frameRate, composeInPlace: inPlace) else {
            EngineLog.emit("[AetherEngine] DV P7 dual-layer: the AVPlayer-output route could not start "
                           + "(no Metal composer); the session plays the 8.1 base layer", category: .engine)
            return
        }
        dualLayerOutputRoute = route
        route.setVideoGravity(_videoGravity)
        session.setVideoPacketTap(route.tap)
        EngineLog.emit("[AetherEngine] DV P7 dual-layer: AVPlayer-output route (AVPlayer plays the base layer "
                       + "and audio, the enhancement layer is composed onto its frames"
                       + (inPlace ? ", in place" : "") + ")", category: .engine)
        #endif
    }

    /// The forward-buffer window the session is built with. On the AVPlayer-output route the producer's
    /// lead over the playhead is also the lead of the enhancement-layer ring's newest packet, and the ring
    /// keeps the newest bytes: a lead longer than the ring holds leaves the playhead without an
    /// enhancement layer (the picture is the base layer). The window is therefore capped at
    /// `DualLayerRouteDecision.maxForwardBufferSegments` (the default is 10) while the route is in use.
    func forwardBufferSegmentsForSession(_ requested: Int?) -> Int? {
        #if DualLayerDolbyVision
        let capped = DualLayerRouteDecision.forwardBufferSegments(
            requested: requested, usesOutputRoute: outputRouteFrameRate != nil)
        if capped != requested, let requested, let capped {
            EngineLog.emit("[DualLayerOutputRoute] forwardBufferSegments \(requested) capped to \(capped): the "
                           + "enhancement-layer ring holds the newest packets, so a longer lead would leave the "
                           + "playhead without them", category: .engine)
        }
        return capped
        #else
        return requested
        #endif
    }

    /// Starts following the player once the native host exists.
    func startDualLayerOutputRoute(player: AVPlayer) {
        #if DualLayerDolbyVision
        guard let route = dualLayerOutputRoute else { return }
        route.start(player: player)
        presentCurrentLayer()
        #endif
    }

    /// The running route as an opaque object, for `stopDualLayerOutputRoute(ifStill:)`; nil without one.
    var dualLayerOutputRouteObject: AnyObject? {
        #if DualLayerDolbyVision
        return dualLayerOutputRoute
        #else
        return nil
        #endif
    }

    /// Stops the route only while it is still `route`, so a load that gives up cannot stop a newer load's.
    func stopDualLayerOutputRoute(ifStill route: AnyObject?) {
        guard let route, route === dualLayerOutputRouteObject else { return }
        stopDualLayerOutputRoute()
    }

    func stopDualLayerOutputRoute() {
        #if DualLayerDolbyVision
        guard let route = dualLayerOutputRoute else { return }
        dualLayerOutputRoute = nil
        boundView?.attachOverlay(nil)
        nativeVideoSession?.setVideoPacketTap(nil)
        route.stop()
        #endif
    }

    /// An external screen (AirPlay or a wired display) took the picture while the route was running: stop
    /// the route, so AVPlayer's own picture, the 8.1 base layer the engine serves, is what the receiver
    /// gets. The route is decided again at the next load or rebuild of the session.
    func handDualLayerOutputRouteToPlayer() {
        #if DualLayerDolbyVision
        guard dualLayerOutputRoute != nil else { return }
        stopDualLayerOutputRoute()
        EngineLog.emit("[DualLayerOutputRoute] another screen took the picture (AirPlay or an external display); "
                       + "the route stopped and AVPlayer shows the 8.1 base layer, without the enhancement layer, "
                       + "until the session is rebuilt", category: .engine)
        #endif
    }
}
