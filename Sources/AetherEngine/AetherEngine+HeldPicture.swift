import Foundation
import AVFoundation
import Combine

extension AetherEngine {

    /// The longest a held picture stays up when the next item never reports a first frame. The
    /// rebuild has its own failure paths; this only keeps a frozen frame from outliving them.
    static let heldPictureTimeoutSeconds: Double = 8

    /// The longest an audio switch waits for a reshaped Dolby Vision still before it rebuilds without
    /// one. The outgoing picture stays on screen, paused, for as long as the decode runs.
    static let heldPictureDolbyVisionBudgetSeconds: Double = 3

    /// The reshaped still's size. The RPU reshaping runs per output pixel on the CPU and dominates the
    /// cost (measured on an M1 Pro, Profile 5 UHD: 1.53 s at 1920 wide, 0.40 s at 960, 0.11 s at 480,
    /// plus ~0.24 s of decode per second the frame sits into its segment). The still stands for a few
    /// hundred milliseconds under the host's loading scrim, where 960 does not read as soft.
    static let heldPictureReshapedSize = CGSize(width: 960, height: 540)

    /// AE#711 follow-up: hold the picture on screen across the rebuild of an audio switch.
    ///
    /// Native: #711 keeps the old item mounted while the source reopens, but `replaceCurrentItem`
    /// still drops the player layer to black until the next item decodes its first frame. The frame
    /// is read from the paused old item (about 20 ms paused; a playing one needs ~300 ms before a
    /// fresh output sees anything, which is why the caller pauses first). Dolby Vision without a
    /// displayable base layer (Profile 5, AV1 Profile 10) cannot be taken from that output, which
    /// vends the base layer; it is decoded from the resident segment instead, frame-accurately and
    /// through the same RPU reshaping the scrub stills use (`DolbyVisionStillConverter`), which only a
    /// build with the `DolbyVisionStillReshaping` trait has; without it the hold is skipped.
    ///
    /// Software: the rebuild replaces host and layer, and the old host's `stop()` flushes its layer to
    /// black for the whole startup of the new one. The frame is read back from the renderer.
    ///
    /// Either way the picture is laid over the video until the next host reports one. Call before
    /// `stopInternal`.
    func holdPictureAcrossItemSwap() async {
        releaseHeldPicture(reason: nil)
        // A bound still view first: a host that binds one renders the native path through AVKit, and
        // its `AetherPlayerView`, if any, is not what is on screen.
        let surface: (any HeldStillSurface)? = boundStillView ?? boundView
        let nativeSource = nativeHost
        let softwareSource = nativeSource == nil ? softwareHost : nil
        if let skip = surface == nil ? "no surface bound"
            : (nativeSource == nil && softwareSource == nil) ? "no video host"
            : Self.heldPictureSkipReason(
                pictureInPictureActive: pictureInPictureActive,
                externalPlaybackActive: Self.externalPlaybackActive(nativeSource)) {
            heldPictureLastSkip = skip
            EngineLog.emit("[AetherEngine] held picture: skipped (\(skip))", category: .engine)
            return
        }
        guard let view = surface else { return }
        heldPictureLastSkip = nil
        let generation = loadGeneration
        let started = ContinuousClock.now

        let held: (frame: CVPixelBuffer, isHDR: Bool, route: String)?
        if let host = nativeSource {
            if Self.heldPictureNeedsReshaping(videoFormat: videoFormat, dolbyVisionProfile: sourceDVProfile) {
                // Without the reshaping there is no correct picture to hold, so nothing is decoded.
                guard OptionalComponent.dolbyVisionStillReshaping.isBuiltIn else {
                    heldPictureLastSkip = "Dolby Vision still reshaping not built in"
                    EngineLog.emit("[AetherEngine] held picture: skipped (Dolby Vision still reshaping not built in, "
                                   + "DolbyVisionStillReshaping trait off)", category: .engine)
                    return
                }
                held = await reshapedDolbyVisionStill(itemSeconds: host.avPlayer.currentTime().seconds)
                    .map { ($0, false, "Dolby Vision reshaped") }
            } else {
                held = await host.captureDisplayedFrame()
                    .map { ($0, Self.heldPictureIsHDR(videoFormat), "native output") }
            }
        } else if let host = softwareSource {
            held = host.displayedFrame().map { ($0, Self.heldPictureIsHDR(videoFormat), "software renderer") }
        } else {
            held = nil
        }
        guard let held else {
            heldPictureLastSkip = "no frame from the outgoing picture"
            EngineLog.emit("[AetherEngine] held picture: no frame from the outgoing picture", category: .engine)
            return
        }
        guard loadGeneration == generation, nativeHost === nativeSource, softwareHost === softwareSource,
              (boundStillView ?? boundView) === view else {
            heldPictureLastSkip = "superseded while the frame was read"
            EngineLog.emit("[AetherEngine] held picture: superseded while the frame was read", category: .engine)
            return
        }
        guard view.showStill(held.frame, gravity: videoGravity, isHDR: held.isHDR) else {
            heldPictureLastSkip = "frame could not be wrapped for display"
            EngineLog.emit("[AetherEngine] held picture: frame could not be wrapped for display", category: .engine)
            return
        }
        heldPictureView = view
        heldPictureLastRoute = held.route
        heldPictureShownAt = .now
        heldPictureToken &+= 1
        let token = heldPictureToken
        if let host = nativeSource {
            let heldSession = host.sessionID
            heldPictureRelease = host.$isVideoReadyForDisplay
                .filter { [weak host] ready in ready && (host?.sessionID ?? heldSession) != heldSession }
                .first()
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.releaseHeldPicture(reason: "first frame of the next item") }
                }
        } else {
            heldPictureAwaitsSoftwareHost = true
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.heldPictureTimeoutSeconds))
            guard let self, self.heldPictureToken == token, self.heldPictureView != nil else { return }
            self.releaseHeldPicture(reason: "timeout")
        }
        EngineLog.emit(
            "[AetherEngine] held picture: up after \(Self.milliseconds(ContinuousClock.now - started))ms "
            + "(\(held.route), \(CVPixelBufferGetWidth(held.frame))x\(CVPixelBufferGetHeight(held.frame)), "
            + "hdr=\(held.isHDR))",
            category: .engine)
    }

    /// visionOS has no external playback, and no `isExternalPlaybackActive` to ask.
    private static func externalPlaybackActive(_ host: NativeAVPlayerHost?) -> Bool {
        #if os(visionOS)
        return false
        #else
        return host?.avPlayer.isExternalPlaybackActive ?? false
        #endif
    }

    /// Called where `loadSoftware` installs its host: a picture held over a software rebuild comes
    /// down at that host's first frame.
    func armHeldPictureRelease(onSoftwareHost host: SoftwarePlaybackHost) {
        guard heldPictureAwaitsSoftwareHost, heldPictureView != nil else { return }
        heldPictureAwaitsSoftwareHost = false
        heldPictureRelease = host.$isVideoReadyForDisplay
            .first(where: { $0 })
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseHeldPicture(reason: "first frame of the next host") }
            }
    }

    /// The current native frame decoded from the resident segment and reshaped through its RPU. nil
    /// when the segment is not resident, the decode fails, or it outruns
    /// `heldPictureDolbyVisionBudgetSeconds`.
    private func reshapedDolbyVisionStill(itemSeconds: Double) async -> CVPixelBuffer? {
        guard !isLive, itemSeconds.isFinite, let session = nativeVideoSession,
              let source = session.scrubThumbnailSource(atSeconds: itemSeconds),
              let reader = source.makeReader() else { return nil }
        let extractor = FrameExtractor(reader: reader, formatHint: "mp4")
        let offset = max(0, itemSeconds - source.startSeconds)
        let image = await withTaskGroup(of: CGImage?.self) { group -> CGImage? in
            group.addTask { await extractor.snapshot(afterFirstFrameBy: offset, maxSize: Self.heldPictureReshapedSize) }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.heldPictureDolbyVisionBudgetSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        Task { await extractor.shutdown() }
        return image.flatMap(Self.pixelBuffer(from:))
    }

    /// An sRGB still as an IOSurface-backed BGRA buffer, the shape a sample-buffer layer displays.
    nonisolated static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buffer
    }

    /// Dolby Vision whose base layer has no displayable colour of its own: Profile 5, and AV1
    /// Profile 10, whose compatibility id is not known here (the reshaping path falls back to the
    /// base layer itself when it finds no RPU). Every other profile's base layer is HDR10, HLG or
    /// SDR and is held as the output vends it.
    nonisolated static func heldPictureNeedsReshaping(videoFormat: VideoFormat, dolbyVisionProfile: Int?) -> Bool {
        videoFormat == .dolbyVision && (dolbyVisionProfile == 5 || dolbyVisionProfile == 10)
    }

    nonisolated static func heldPictureIsHDR(_ format: VideoFormat) -> Bool {
        format != .sdr
    }

    /// Takes the held picture down. `reason` nil is a silent clear (nothing was up, or a new hold
    /// replaces it); every other release is logged with how long the picture stood.
    func releaseHeldPicture(reason: String?) {
        heldPictureRelease?.cancel()
        heldPictureRelease = nil
        heldPictureAwaitsSoftwareHost = false
        guard let view = heldPictureView else { return }
        view.clearStill()
        heldPictureView = nil
        heldPictureLastRelease = reason
        if let reason, let shownAt = heldPictureShownAt {
            EngineLog.emit(
                "[AetherEngine] held picture: released after \(Self.milliseconds(ContinuousClock.now - shownAt))ms (\(reason))",
                category: .engine)
        }
        heldPictureShownAt = nil
    }

    /// Why no picture is held. PiP and external playback: the picture is not in this view.
    nonisolated static func heldPictureSkipReason(
        pictureInPictureActive: Bool, externalPlaybackActive: Bool
    ) -> String? {
        if pictureInPictureActive { return "picture in picture" }
        if externalPlaybackActive { return "external playback" }
        return nil
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
