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

    /// The default of `heldPictureFrameWaitSeconds`.
    static let defaultHeldPictureFrameWaitSeconds: Double = 0.5

    /// How long the native read waits once a read has come back empty. Some apps' outputs vend no
    /// paused frame at all (Playova on macOS 26, the macOS CI runner), so every switch stood still
    /// for the full wait. Where a frame does arrive it takes about 85 ms (PR #1082), so a short probe
    /// still catches it.
    static let heldPictureProbeAfterMissSeconds: Double = 0.15

    /// The wait the native read runs with: the host's value, capped at the Dolby Vision budget so a
    /// huge value cannot freeze the switch (or overflow), and a negative or non-finite one read as
    /// "do not wait". After a miss it only probes, never longer than the host asked for.
    static func heldPictureFrameWait(seconds: Double, afterMiss: Bool = false) -> Duration {
        guard seconds.isFinite, seconds > 0 else { return .zero }
        var capped = min(seconds, heldPictureDolbyVisionBudgetSeconds)
        if afterMiss { capped = min(capped, heldPictureProbeAfterMissSeconds) }
        return .milliseconds(Int64((capped * 1000).rounded()))
    }

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
        guard let view: any HeldStillSurface = boundStillView ?? boundView else {
            heldPictureLastSkip = "no surface bound"
            EngineLog.emit("[AetherEngine] held picture: skipped (no surface bound)", category: .engine)
            return
        }
        guard let shown = await showOutgoingPicture(
            on: view, logLabel: "held picture",
            isCurrent: { [weak self] in (self?.boundStillView ?? self?.boundView) === view })
        else { return }
        armHeldPicture(on: view, route: shown.route, nativeSource: shown.nativeSource)
    }

    /// Reads the picture the running video host shows and puts it on `view`, by whichever route the
    /// source needs (see `holdPictureAcrossItemSwap`). nil, with `heldPictureLastSkip` saying why,
    /// when nothing went up. `isCurrent` is asked once the frame is in hand: a hold whose surface
    /// was replaced meanwhile is dropped, as is one a load or stop overtook.
    private func showOutgoingPicture(
        on view: any HeldStillSurface, logLabel: String, pausesFirst: Bool = false,
        isCurrent: @escaping () -> Bool
    ) async -> (route: String, nativeSource: NativeAVPlayerHost?)? {
        let nativeSource = nativeHost
        let softwareSource = nativeSource == nil ? softwareHost : nil
        if let skip = (nativeSource == nil && softwareSource == nil) ? "no video host"
            : Self.heldPictureSkipReason(
                pictureInPictureActive: pictureInPictureActive,
                externalPlaybackActive: Self.externalPlaybackActive(nativeSource)) {
            heldPictureLastSkip = skip
            EngineLog.emit("[AetherEngine] \(logLabel): skipped (\(skip))", category: .engine)
            return nil
        }
        heldPictureLastSkip = nil
        // The native output vends a paused frame in ~20 ms and a playing one in ~300 ms, and a picture
        // still moving (and still sounding) under its own still would contradict it.
        if pausesFirst { pause() }
        let generation = loadGeneration
        let started = ContinuousClock.now

        if let host = nativeSource,
           Self.heldPictureNeedsReshaping(videoFormat: videoFormat, dolbyVisionProfile: sourceDVProfile),
           !OptionalComponent.dolbyVisionStillReshaping.isBuiltIn {
            let shown = await holdThroughCompositor(host: host, view: view, generation: generation,
                                                    started: started, logLabel: logLabel, isCurrent: isCurrent)
            return shown ? ("Dolby Vision compositor", host) : nil
        }

        let held: (frame: CVPixelBuffer, isHDR: Bool, route: String)?
        if let host = nativeSource {
            if Self.heldPictureNeedsReshaping(videoFormat: videoFormat, dolbyVisionProfile: sourceDVProfile) {
                held = await reshapedDolbyVisionStill(itemSeconds: host.avPlayer.currentTime().seconds)
                    .map { ($0, false, "Dolby Vision reshaped") }
            } else {
                let wait = Self.heldPictureFrameWait(seconds: heldPictureFrameWaitSeconds,
                                                     afterMiss: heldPictureNativeReadMissed)
                let frame = wait > .zero ? await host.captureDisplayedFrame(timeout: wait) : nil
                // Only a read that ran its whole wait on the same item counts as a miss; one cut short
                // by a superseding load says nothing about the output.
                if frame != nil {
                    heldPictureNativeReadMissed = false
                } else if wait > .zero, ContinuousClock.now - started >= wait, nativeHost === host {
                    heldPictureNativeReadMissed = true
                }
                held = frame.map { ($0, Self.heldPictureIsHDR(videoFormat), "native output") }
            }
        } else if let host = softwareSource {
            held = host.displayedFrame().map { ($0, Self.heldPictureIsHDR(videoFormat), "software renderer") }
        } else {
            held = nil
        }
        guard let held else {
            heldPictureLastSkip = "no frame from the outgoing picture"
            EngineLog.emit("[AetherEngine] \(logLabel): no frame from the outgoing picture", category: .engine)
            return nil
        }
        guard loadGeneration == generation, nativeHost === nativeSource, softwareHost === softwareSource,
              isCurrent() else {
            heldPictureLastSkip = "superseded while the frame was read"
            EngineLog.emit("[AetherEngine] \(logLabel): superseded while the frame was read", category: .engine)
            return nil
        }
        guard view.showStill(held.frame, gravity: videoGravity, isHDR: held.isHDR) else {
            heldPictureLastSkip = "frame could not be wrapped for display"
            EngineLog.emit("[AetherEngine] \(logLabel): frame could not be wrapped for display", category: .engine)
            return nil
        }
        EngineLog.emit(
            "[AetherEngine] \(logLabel): up after \(Self.milliseconds(ContinuousClock.now - started))ms "
            + "(\(held.route), \(CVPixelBufferGetWidth(held.frame))x\(CVPixelBufferGetHeight(held.frame)), "
            + "hdr=\(held.isHDR))",
            category: .engine)
        return (held.route, nativeSource)
    }

    /// Dolby Vision without a displayable base layer and without the still reshaping: the frame under
    /// the playhead, played out of the resident segment by a player of the surface's own, so the
    /// system compositor colours it as it colours playback. Waits at most
    /// `heldPictureDolbyVisionBudgetSeconds`, the outgoing picture paused meanwhile.
    private func holdThroughCompositor(host: NativeAVPlayerHost, view: any HeldStillSurface,
                                       generation: UInt64, started: ContinuousClock.Instant,
                                       logLabel: String, isCurrent: () -> Bool) async -> Bool {
        let itemSeconds = host.avPlayer.currentTime().seconds
        guard let session = nativeVideoSession else { return false }
        let built = await BlockingWork.detached(priority: .userInitiated) { [session] in
            session.compositorHoldFile(atSeconds: itemSeconds)
        }.value
        guard let hold = built else {
            heldPictureLastSkip = "no frame from the outgoing picture"
            EngineLog.emit("[AetherEngine] \(logLabel): no resident segment for the compositor hold", category: .engine)
            return false
        }
        let spent = Double((ContinuousClock.now - started).components.seconds)
            + Double((ContinuousClock.now - started).components.attoseconds) / 1e18
        let budget = max(0.2, Self.heldPictureDolbyVisionBudgetSeconds - spent)
        let shown = await view.showCompositorStill(file: hold.url, pastFirstFrameBy: hold.offsetSeconds,
                                                   gravity: videoGravity, budgetSeconds: budget)
        guard shown else {
            heldPictureLastSkip = "no frame from the outgoing picture"
            EngineLog.emit("[AetherEngine] \(logLabel): the compositor hold did not become displayable", category: .engine)
            return false
        }
        guard loadGeneration == generation, nativeHost === host, isCurrent() else {
            view.clearStill()
            heldPictureLastSkip = "superseded while the frame was read"
            EngineLog.emit("[AetherEngine] \(logLabel): superseded while the frame was read", category: .engine)
            return false
        }
        EngineLog.emit(
            "[AetherEngine] \(logLabel): up after \(Self.milliseconds(ContinuousClock.now - started))ms "
            + "(Dolby Vision compositor, item \(String(format: "%.3f", itemSeconds))s)",
            category: .engine)
        return true
    }

    /// AE#1113: the longest a host's hold stands while no next picture arrives. A host that holds and
    /// then never loads, or whose load never shows a frame, does not keep a frozen picture forever.
    static let outgoingPictureCapSecondsDefault: Double = 60

    /// Keep the picture on screen across the host's own next `load()`, on a surface the host places.
    ///
    /// Meant for an episode change: the outgoing episode's last picture shrinks to a tile and fades
    /// while the next one loads behind it. The engine pauses playback, reads the frame on screen by the
    /// routes an audio-track switch uses (native output, software renderer, and for Dolby Vision
    /// without a displayable base layer the reshaped or compositor still), and shows it on `view`, as
    /// HDR where the source is HDR. Await it, then call `load()`.
    ///
    /// The hold is the host's. It survives every `load()`, whichever route the next item takes, and
    /// the engine never lays an audio-switch hold on `view`. It comes down when:
    ///
    /// - the host calls `releaseOutgoingPicture()` (the usual end, once its fade is done);
    /// - `stop()` runs, or a newer `holdOutgoingPicture(on:)` replaces it;
    /// - the next load fails (`state` turns `.error`);
    /// - `outgoingPictureGraceSeconds` (8 s) after the next item's first frame, as a safety net;
    /// - 60 s pass without a next first frame.
    ///
    /// The next item's picture is up when `hasFirstFrameReadyForDisplay` turns true after the `load()`.
    /// That is the edge to start a fade on.
    ///
    /// Do not combine it with `prepareForItemReplacement()` when the still shrinks: that keeps the
    /// outgoing item's paused picture full size under the tile until the next item mounts.
    ///
    /// - Returns: whether a picture went up. False in Picture in Picture, on external playback, with
    ///   no video, or when no frame could be read. Nothing is held then. Playback was paused if the
    ///   read ran at all, so a host that does not load after all calls `play()`.
    @discardableResult
    public func holdOutgoingPicture(on view: AetherStillView) async -> Bool {
        releaseOutgoingPicture(reason: nil)
        let token = outgoingPictureToken
        guard let shown = await showOutgoingPicture(
            on: view, logLabel: "outgoing picture", pausesFirst: true,
            isCurrent: { [weak self] in self?.outgoingPictureToken == token })
        else { return false }
        armOutgoingPicture(on: view, token: token, route: shown.route)
        return true
    }

    /// Take down the picture `holdOutgoingPicture(on:)` put up. Idempotent, and it also drops a hold
    /// whose frame is still being read.
    public func releaseOutgoingPicture() {
        releaseOutgoingPicture(reason: "released by the host")
    }

    /// `reason` nil is a silent clear (a new hold replaces this one).
    func releaseOutgoingPicture(reason: String?) {
        // Moving the token also drops a read in flight and any release still sleeping.
        outgoingPictureToken &+= 1
        outgoingPictureWatches.removeAll()
        outgoingPictureSawNextFrame = false
        guard let view = outgoingPictureView else { return }
        view.clearStill()
        outgoingPictureView = nil
        outgoingPictureLastRelease = reason
        if let reason, let shownAt = outgoingPictureShownAt {
            EngineLog.emit(
                "[AetherEngine] outgoing picture: released after \(Self.milliseconds(ContinuousClock.now - shownAt))ms (\(reason))",
                category: .engine)
        }
        outgoingPictureShownAt = nil
    }

    /// Watches for the next item's first frame (any route: `hasFirstFrameReadyForDisplay` is reset by
    /// every `load()` and latched by whichever host shows the picture) and for a failed next load.
    private func armOutgoingPicture(on view: AetherStillView, token: Int, route: String) {
        outgoingPictureView = view
        outgoingPictureShownAt = .now
        outgoingPictureLastRoute = route
        outgoingPictureLastRelease = nil
        let heldGeneration = loadGeneration
        $hasFirstFrameReadyForDisplay
            .sink { [weak self] ready in
                MainActor.assumeIsolated {
                    guard let self, ready, self.loadGeneration != heldGeneration,
                          self.outgoingPictureToken == token, !self.outgoingPictureSawNextFrame else { return }
                    self.outgoingPictureSawNextFrame = true
                    if let shownAt = self.outgoingPictureShownAt {
                        EngineLog.emit(
                            "[AetherEngine] outgoing picture: next item's first frame after "
                            + "\(Self.milliseconds(ContinuousClock.now - shownAt))ms, left to the host",
                            category: .engine)
                    }
                    self.scheduleOutgoingPictureRelease(token: token, after: self.outgoingPictureGraceSeconds,
                                                        reason: "timeout after the next first frame")
                }
            }
            .store(in: &outgoingPictureWatches)
        $state
            .sink { [weak self] state in
                guard case .error = state else { return }
                MainActor.assumeIsolated {
                    guard let self, self.loadGeneration != heldGeneration,
                          self.outgoingPictureToken == token else { return }
                    self.releaseOutgoingPicture(reason: "next load failed")
                }
            }
            .store(in: &outgoingPictureWatches)
        scheduleOutgoingPictureRelease(token: token, after: outgoingPictureCapSeconds,
                                       reason: "no next picture", onlyBeforeNextFrame: true)
    }

    private func scheduleOutgoingPictureRelease(token: Int, after seconds: Double, reason: String,
                                                onlyBeforeNextFrame: Bool = false) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.outgoingPictureToken == token, self.outgoingPictureView != nil,
                  !(onlyBeforeNextFrame && self.outgoingPictureSawNextFrame) else { return }
            self.releaseOutgoingPicture(reason: reason)
        }
    }

    /// Records the hold and arms its release: the next item's first frame (native), the next host's
    /// (software), or `heldPictureTimeoutSeconds`.
    private func armHeldPicture(on view: any HeldStillSurface, route: String, nativeSource: NativeAVPlayerHost?) {
        heldPictureView = view
        heldPictureLastRoute = route
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

    /// Dolby Vision whose base layer has no displayable colour of its own: Profile 5 and 20, and AV1
    /// Profile 10, whose compatibility id is not known here (the reshaping path falls back to the
    /// base layer itself when it finds no RPU). Every other profile's base layer is HDR10, HLG or
    /// SDR and is held as the output vends it.
    nonisolated static func heldPictureNeedsReshaping(videoFormat: VideoFormat, dolbyVisionProfile: Int?) -> Bool {
        videoFormat == .dolbyVision
            && (VideoRoutingPolicy.hevcDolbyVisionHasIPTBase(dolbyVisionProfile) || dolbyVisionProfile == 10)
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
