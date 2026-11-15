import Foundation
import AetherLibavformat
import AetherLibavutil

/// #957: the load's side of the picture processing. The decision reads the probe and the display once per
/// load; the published status follows the stage's own events.
extension AetherEngine {

    func videoProcessingRouteDecision(
        options: LoadOptions, videoStream: UnsafeMutablePointer<AVStream>?, dvProfile: Int?,
        displayTakesHDR10: Bool, wirelessAirPlayRoute: Bool, demuxedAudioLive: Bool
    ) -> VideoProcessingRouteDecision {
        guard options.videoProcessing != nil else { return .notTaken(.preferenceOff) }

        var width = 0, height = 0
        var isPQ = false
        var isFourTwoZero = false
        var declared: HDR10StaticMetadata?
        var frameRate: Double?
        if let stream = videoStream, let cp = stream.pointee.codecpar {
            width = Int(cp.pointee.width)
            height = Int(cp.pointee.height)
            isPQ = cp.pointee.color_trc == AVCOL_TRC_SMPTE2084
            isFourTwoZero = UpscaleRouteDecision.isEightBit420(
                    pixelFormat: cp.pointee.format, bitsPerRawSample: cp.pointee.bits_per_raw_sample)
                || UpscaleRouteDecision.isTenBit420(
                    pixelFormat: cp.pointee.format, bitsPerRawSample: cp.pointee.bits_per_raw_sample)
            let values = HDR10StaticMetadataSEI.declared(by: cp).values
            declared = HDR10StaticMetadata(masteringDisplayColorVolume: values.masteringDisplay,
                                           contentLightLevel: values.contentLightLevel)
            frameRate = Self.detectFrameRate(stream: stream)
        }

        var osSupportsStage = false
        #if !targetEnvironment(simulator)
        if #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *) { osSupportsStage = true }
        #endif

        sourceVideoProcessingFrameRate = frameRate
        return VideoProcessingRouteDecision.decide(
            options: options.videoProcessing, osSupportsStage: osSupportsStage, isPQ: isPQ,
            isDolbyVision: dvProfile != nil, carriesHDR10Plus: sourceCarriesHDR10PlusMetadata,
            displayTakesHDR10: displayTakesHDR10, declared: declared, width: width, height: height,
            isFourTwoZero: isFourTwoZero, wirelessAirPlayRoute: wirelessAirPlayRoute,
            demuxedAudioLive: demuxedAudioLive,
            stageFailedEarlier: { VideoProcessingFailureMemory.contains($0, frameRate: frameRate) })
    }

    /// Connects the stage `host`'s load built to `activeVideoProcessing`. The host's load can already have
    /// run it (the first frame decodes under pause), so what the stage did before the handler existed is
    /// caught up. A disable is latched for the session (`sourceVideoProcessingDisabled`), so no later host
    /// builds the stage again.
    func wireVideoProcessingStatus(from host: SoftwarePlaybackHost) {
        #if !targetEnvironment(simulator)
        guard #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *),
              let stage = host.frameToneMapper as? FrameToneMapper, let plan = host.videoProcessingPlan else { return }
        // Weak both ways: the host owns the stage, which owns this handler.
        stage.onEvent = { [weak self, weak host] event in
            Task { @MainActor in
                guard let self, let host, self.softwareHost === host else { return }
                switch event {
                case let .firstFrame(status):
                    self.activeVideoProcessing = VideoProcessingStatus.afterFirstFrame(
                        status, current: self.activeVideoProcessing)
                case let .disabled(reason: reason, cause: cause, stats: _):
                    self.latchVideoProcessingDisabled(reason: reason, anyFrameRate: cause == .hdr10Plus, plan: plan)
                }
            }
        }
        if let delivered = stage.delivered {
            activeVideoProcessing = VideoProcessingStatus.afterFirstFrame(delivered, current: activeVideoProcessing)
        }
        if let disabled = stage.disabled {
            latchVideoProcessingDisabled(reason: disabled.reason, anyFrameRate: disabled.cause == .hdr10Plus, plan: plan)
        }
        #endif
    }

    private func latchVideoProcessingDisabled(reason: String, anyFrameRate: Bool, plan: VideoProcessingPlan) {
        guard sourceVideoProcessingDisabled == nil else { return }
        let status = VideoProcessingStatus.afterDisable(reason: reason, current: activeVideoProcessing, plan: plan)
        activeVideoProcessing = status
        sourceVideoProcessingDisabled = status
        VideoProcessingFailureMemory.record(plan, frameRate: anyFrameRate ? nil : sourceVideoProcessingFrameRate)
        // The upscaler's rule, for the same reasons: a URL VOD session the processing alone moved.
        guard Self.upscaleDisableReturnsToNative(
            softwareOnlyForUpscale: sourceSoftwareOnlyForVideoProcessing, isCustomSource: isCustomSource,
            isLive: loadedOptions.isLive)
        else { return }
        guard upscaleNativeReturnOwed != loadGeneration else { return }
        upscaleNativeReturnOwed = loadGeneration
        nativeReturnOwedBy = "[VideoProcessing] processing"
        settleOwedUpscaleNativeReturn()
    }
}
