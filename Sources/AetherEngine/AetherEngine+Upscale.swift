import Foundation
#if !targetEnvironment(simulator)
import Metal
import MetalFX
#endif
import AetherLibavformat
import AetherLibavutil

/// #846: the load's side of the low-resolution upscale stage. The decision reads the probe, the display
/// and the device once per load; the published status follows the stage's own events.
extension AetherEngine {

    func upscaleRouteDecision(
        options: LoadOptions, videoStream: UnsafeMutablePointer<AVStream>?, dvProfile: Int?,
        wirelessAirPlayRoute: Bool, demuxedAudioLive: Bool
    ) -> UpscaleRouteDecision {
        // Spares the off case the Metal device and the display read below.
        guard options.upscalesLowResolutionVideo else { return .notTaken(.preferenceOff) }

        var source = SourceGeometry(width: 0, height: 0, sarNum: 0, sarDen: 0)
        var frameRate: Double?
        var isSDR = true
        var isEightBit420 = true
        var isTenBit420 = false
        if let stream = videoStream, let cp = stream.pointee.codecpar {
            let sar = PixelAspectPolicy.declaredPixelAspect(
                bitstream: cp.pointee.sample_aspect_ratio, container: stream.pointee.sample_aspect_ratio,
                width: cp.pointee.width, height: cp.pointee.height)
            source = SourceGeometry(width: Int(cp.pointee.width), height: Int(cp.pointee.height),
                                    sarNum: Int(sar?.num ?? 0), sarDen: Int(sar?.den ?? 0))
            frameRate = Self.detectFrameRate(stream: stream)
            isSDR = UpscaleRouteDecision.isSDR(colorTransfer: cp.pointee.color_trc)
            isEightBit420 = UpscaleRouteDecision.isEightBit420(
                pixelFormat: cp.pointee.format, bitsPerRawSample: cp.pointee.bits_per_raw_sample)
            isTenBit420 = UpscaleRouteDecision.isTenBit420(
                pixelFormat: cp.pointee.format, bitsPerRawSample: cp.pointee.bits_per_raw_sample)
        }

        var osSupportsStage = false
        var metalFXSupported = false
        var mlScaleFactors: (Int, Int) -> [Float] = { _, _ in [] }
        if #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *) {
            osSupportsStage = true
            // The stage is not built for the simulator, which therefore counts as a device without it.
            #if !targetEnvironment(simulator)
            if #available(tvOS 27.1, *) {
                metalFXSupported = MTLCreateSystemDefaultDevice().map { MTLFXSpatialScalerDescriptor.supportsDevice($0) }
                    ?? false
            }
            mlScaleFactors = FrameUpscaler.mlScaleFactors
            #endif
        }

        sourceUpscaleFrameRate = frameRate
        let display = DisplayPixelSize.current() ?? .zero
        func decide(_ scaler: UpscaleScaler) -> UpscaleRouteDecision {
            UpscaleRouteDecision.decide(
                preference: true, osSupportsStage: osSupportsStage, metalFXSupported: metalFXSupported,
                source: source, isSDR: isSDR, isDolbyVision: dvProfile != nil, isEightBit420: isEightBit420,
                display: display,
                wirelessAirPlayRoute: wirelessAirPlayRoute, demuxedAudioLive: demuxedAudioLive,
                mlScaleFactors: mlScaleFactors, scaler: scaler, isTenBit420: isTenBit420,
                stageFailedEarlier: { UpscaleFailureMemory.contains($0, frameRate: frameRate) })
        }
        let decision = decide(options.upscaleScaler)
        // AE#1039: line art that overran here before starts on the rung it fell back to.
        if let plan = decision.plan, plan.scaler == .lineArt,
           let overrun = LineArtCostMemory.overrun(covering: plan, frameInterval: frameRate.map { 1 / $0 }, rung: .upscale) {
            let fallback = UpscaleRouteDecision.lineArtFallback(for: plan, mlScaleFactors: mlScaleFactors) != nil
                ? decide(.automatic) : .notTaken(.stageFailedEarlier)
            EngineLog.emit(String(format: "[Upscale] line art overran on this device earlier (%.1f ms at %.1f ms), %@",
                                  overrun.meanMs, overrun.frameInterval * 1000,
                                  fallback.plan != nil ? "using the automatic scaler" : "not upscaling"),
                           category: .engine)
            return fallback
        }
        return decision
    }

    /// Connects the stage `host`'s load built to `activeUpscale`. The host's load can already have run it
    /// (the first frame decodes under pause), so what the stage did before the handler existed is caught up.
    /// A disable is latched for the session (`sourceUpscaleDisabled`), so no later host builds the stage again.
    func wireUpscaleStatus(from host: SoftwarePlaybackHost) {
        #if !targetEnvironment(simulator)
        guard #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *),
              let upscaler = host.frameUpscaler as? FrameUpscaler, let plan = host.upscalePlan else { return }
        // Weak both ways: the host owns the stage, which owns this handler.
        upscaler.onEvent = { [weak self, weak host] event in
            Task { @MainActor in
                guard let self, let host, self.softwareHost === host else { return }
                switch event {
                case let .firstFrame(framePlan, degraded):
                    self.activeUpscale = UpscaleStatus.afterFirstFrame(
                        framePlan, degraded: degraded, current: self.activeUpscale)
                case let .degraded(framePlan, reason: _, stats: _):
                    self.activeUpscale = UpscaleStatus.afterFirstFrame(
                        framePlan, degraded: true, current: self.activeUpscale)
                case let .disabled(reason: reason, stats: _):
                    self.latchUpscaleDisabled(reason: reason, plan: plan)
                }
            }
        }
        if let delivered = upscaler.delivered {
            activeUpscale = UpscaleStatus.afterFirstFrame(delivered.plan, degraded: delivered.degraded, current: activeUpscale)
        }
        if let reason = upscaler.disabledReason {
            latchUpscaleDisabled(reason: reason, plan: plan)
        }
        #endif
    }

    private func latchUpscaleDisabled(reason: String, plan: UpscalePlan) {
        let status = UpscaleStatus.afterDisable(reason: reason, current: activeUpscale, plan: plan)
        activeUpscale = status
        sourceUpscaleDisabled = status
        UpscaleFailureMemory.record(plan, frameRate: sourceUpscaleFrameRate)
        guard Self.upscaleDisableReturnsToNative(
            softwareOnlyForUpscale: sourceSoftwareOnlyForUpscale, isCustomSource: isCustomSource,
            isLive: loadedOptions.isLive)
        else { return }
        guard upscaleNativeReturnOwed != loadGeneration else { return }
        upscaleNativeReturnOwed = loadGeneration
        settleOwedUpscaleNativeReturn()
    }

    /// Whether a disabled stage hands the session back to the native path. Only a session the stage alone
    /// put on the software path, and only a URL VOD source: its rebuild re-runs `load()`, which no longer
    /// takes the route (`UpscaleFailureMemory`), while a custom source's rebuild keeps its backend and a
    /// live one rejoins at the edge.
    nonisolated static func upscaleDisableReturnsToNative(
        softwareOnlyForUpscale: Bool, isCustomSource: Bool, isLive: Bool
    ) -> Bool {
        softwareOnlyForUpscale && !isCustomSource && !isLive
    }

    /// Runs the owed return once no load is in flight and the session is playing or paused; called again
    /// from the load's own exit and from every state change, so a disable during a seek is not lost.
    func settleOwedUpscaleNativeReturn() {
        guard let owed = upscaleNativeReturnOwed else { return }
        guard owed == loadGeneration else { upscaleNativeReturnOwed = nil; return }
        guard !loadInFlight, state == .playing || state == .paused else { return }
        upscaleNativeReturnOwed = nil
        EngineLog.emit("[Upscale] stage disabled on a session it alone put on the software path: "
                       + "reloading at the current position on the native path", category: .engine)
        Task { @MainActor [weak self] in
            guard let self, self.loadGeneration == owed else { return }
            do {
                try await self.reloadAtCurrentPosition()
            } catch {
                EngineLog.emit("[Upscale] native return failed: \(error)", category: .engine)
            }
        }
    }
}
