import Testing
import Foundation
import AVFoundation
@testable import AetherEngine

@Suite("AE#711 follow-up: the native picture held across an in-place item swap", .serialized,
       .timeLimit(.minutes(1)))
@MainActor
struct ItemSwapStillTests {

    /// The macOS CI runner's `AVPlayerItemVideoOutput` vends no frame for a paused item, not even
    /// after a zero-tolerance seek to where it stands (CI on a3852899 and on #722); a playing one it
    /// does. A Mac and an Apple TV answer paused in ~20 ms, and the hold reads paused by design, so
    /// the tests that need a paused read run everywhere but there.
    nonisolated static let vendsPausedFrames = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil

    /// Four seconds of H.264 plus silent AAC, long enough to still be playing when the capture runs
    /// and with an audio stream for the audio-switch rebuild to name. The shared fixtures end after
    /// 0.2 s, before an output attached to them sees a frame.
    static func fixtureURL() async throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae711-still-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 72,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 72,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        writer.add(video)
        writer.add(audio)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var formatOut: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &formatOut)
        let audioFormat = try #require(formatOut)

        // One loop feeds both tracks, each whenever IT is ready, and never waits on either. The
        // writer interleaves: it stops taking video once video is far enough ahead of audio, and
        // then takes nothing more until audio catches up. With a `requestMediaDataWhenReady` block
        // per track that catching up depends on AVFoundation calling the audio block again, and on
        // a loaded CI runner it did not: `video 88/120 ready=false, audio 21/40 ready=true`, the
        // audio block called once in total, until the deadline. A loop that waits on one
        // track at a time deadlocks the same way from the other side.
        let chunk = 4800
        var frame = 0
        var chunks = 0
        var videoDone = false
        var audioDone = false
        // A stall deadline, not a total one: under load the writer can be slow and still moving
        // (`video 4/120 ready=true, audio 24/40 ready=true` after a fixed 20 s on CI), and only a
        // writer that takes nothing for 20 s is the deadlock described above. Both tracks reading
        // ready at the end of such a run says the loop itself had not run: a starved task sleeps
        // through the deadline, so a stall also needs the polls to show it.
        var lastProgress = ContinuousClock.now
        var idlePolls = 0
        while !(videoDone && audioDone), writer.status == .writing,
              ContinuousClock.now - lastProgress < .seconds(20) || idlePolls < 1_000 {
            var fed = false
            if !videoDone, video.isReadyForMoreMediaData {
                // Our own buffer, not one from the adaptor's pool: that pool belongs to the
                // writer, and drawing from it under load segfaulted the whole test process
                // inside CVPixelBufferPoolCreatePixelBuffer.
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, 128, 72, kCVPixelFormatType_32BGRA, nil, &buffer)
                if let pixels = buffer {
                    CVPixelBufferLockBaseAddress(pixels, [])
                    memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 2 % 256),
                           CVPixelBufferGetDataSize(pixels))
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    if adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) {
                        frame += 1
                        fed = true
                    }
                }
                if frame >= 120 {
                    video.markAsFinished()
                    videoDone = true
                }
            }
            if !audioDone, audio.isReadyForMoreMediaData {
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: chunk * 2, blockAllocator: nil,
                    customBlockSource: nil, offsetToData: 0, dataLength: chunk * 2,
                    flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                var sample: CMSampleBuffer?
                if let data = block {
                    CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
                                               dataLength: chunk * 2)
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                        allocator: nil, dataBuffer: data, formatDescription: audioFormat,
                        sampleCount: chunk,
                        presentationTimeStamp: CMTime(value: CMTimeValue(chunks * chunk), timescale: 48_000),
                        packetDescriptions: nil, sampleBufferOut: &sample)
                }
                if let sample, audio.append(sample) {
                    chunks += 1
                    fed = true
                }
                if chunks >= 40 {
                    audio.markAsFinished()
                    audioDone = true
                }
            }
            if fed {
                lastProgress = .now
                idlePolls = 0
            } else {
                idlePolls += 1
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        guard videoDone, audioDone else {
            let state = "video \(frame)/120 ready=\(video.isReadyForMoreMediaData), "
                + "audio \(chunks)/40 ready=\(audio.isReadyForMoreMediaData)"
            writer.cancelWriting()
            throw FixtureWriterFailed(status: writer.status.rawValue, error: writer.error, state: state)
        }
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return file
    }

    @Test("a playing native item hands over the frame on screen")
    func playingCapture() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        #expect(engine.state == .playing)
        // A playing item needs ~300 ms before a fresh output sees a frame (measured here); the
        // rebuild pauses first for that reason, but the playing read still has to work. The timeout
        // only has to catch an output that never vends: 2 s ran out once in a starved CI run (this
        // test took 22.7 s) with the item still playing.
        let frame = await host.captureDisplayedFrame(timeout: .seconds(15))
        #expect(frame != nil, "no frame while \(engine.state)")
        #expect(engine.state == .playing)
    }

    @Test("a paused native item still hands over the frame on screen", .enabled(if: ItemSwapStillTests.vendsPausedFrames))
    func pausedCapture() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        let started = ContinuousClock.now
        let frame = await host.captureDisplayedFrame()
        #expect(ContinuousClock.now - started < .milliseconds(500))
        #expect(frame != nil)
    }

    @Test("an audio-switch rebuild holds the picture over the swap and drops it at the next first frame", .enabled(if: ItemSwapStillTests.vendsPausedFrames))
    func rebuildHoldsThePicture() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        let audioIndex = try #require(engine.activeAudioTrackIndex)

        var held = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if view.isHoldingStill { held = true }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let failure = await engine.reloadWithAudioOverride(
            url: file, audioStreamIndex: Int32(audioIndex), expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
        try await waitFor { !view.isHoldingStill }
        watcher.cancel()

        #expect(held)
        #expect(engine.heldPictureLastRelease == "first frame of the next item")
        #expect(engine.nativeHost === host)
        #expect(engine.heldPictureView == nil)
    }

    @Test("stop takes a held picture down", .enabled(if: ItemSwapStillTests.vendsPausedFrames))
    func stopReleasesTheHold() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        await engine.holdPictureAcrossItemSwap()
        #expect(view.isHoldingStill)
        engine.stop()
        #expect(!view.isHoldingStill)
        #expect(engine.heldPictureLastRelease == "stop")
        #expect(engine.heldPictureView == nil)
    }

    /// A host shaped like Sodalite: AVKit renders the native path, no `AetherPlayerView` is bound,
    /// and a still view is the only surface the engine has. Before it existed the hold returned
    /// without a trace (device log 2026-10-07: no `held picture` line at all).
    @Test("an AVKit host's still view carries the hold through the rebuild", .enabled(if: ItemSwapStillTests.vendsPausedFrames))
    func stillViewCarriesTheHold() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let still = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bindStillView(still)
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        let audioIndex = try #require(engine.activeAudioTrackIndex)

        var held = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if still.isHoldingStill { held = true }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let failure = await engine.reloadWithAudioOverride(
            url: file, audioStreamIndex: Int32(audioIndex), expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
        try await waitFor { !still.isHoldingStill }
        watcher.cancel()

        #expect(held)
        #expect(engine.heldPictureLastSkip == nil)
        #expect(engine.heldPictureLastRelease == "first frame of the next item")
    }

    @Test("with no surface bound the hold says so instead of returning silently")
    func noSurfaceIsLogged() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        await engine.holdPictureAcrossItemSwap()
        #expect(engine.heldPictureLastSkip == "no surface bound")
        #expect(engine.heldPictureView == nil)
    }

    @Test("a bound still view wins over the player view, and unbinding it takes the picture down", .enabled(if: ItemSwapStillTests.vendsPausedFrames))
    func stillViewWinsAndUnbindReleases() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let still = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        engine.bindStillView(still)
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        await engine.holdPictureAcrossItemSwap()
        #expect(still.isHoldingStill)
        #expect(!view.isHoldingStill)
        engine.unbindStillView(still)
        #expect(!still.isHoldingStill)
        #expect(engine.heldPictureLastRelease == "still view unbound")
    }

    @Test("PiP and external playback hold nothing")
    func skipReasons() {
        #expect(AetherEngine.heldPictureSkipReason(
            pictureInPictureActive: false, externalPlaybackActive: false) == nil)
        #expect(AetherEngine.heldPictureSkipReason(
            pictureInPictureActive: true, externalPlaybackActive: false) != nil)
        #expect(AetherEngine.heldPictureSkipReason(
            pictureInPictureActive: false, externalPlaybackActive: true) != nil)
    }

    @Test("only Dolby Vision without a displayable base layer is reshaped from the segment")
    func reshapingRule() {
        #expect(AetherEngine.heldPictureNeedsReshaping(videoFormat: .dolbyVision, dolbyVisionProfile: 5))
        #expect(AetherEngine.heldPictureNeedsReshaping(videoFormat: .dolbyVision, dolbyVisionProfile: 10))
        #expect(!AetherEngine.heldPictureNeedsReshaping(videoFormat: .dolbyVision, dolbyVisionProfile: 8))
        #expect(!AetherEngine.heldPictureNeedsReshaping(videoFormat: .hdr10, dolbyVisionProfile: 5))
    }

    /// The fixture paints frame n at grey level 2n, so the frame a still came from can be read off it.
    @Test("a still measured from the first frame lands on the frame it names")
    func snapshotAfterFirstFrameIsFrameAccurate() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let extractor = FrameExtractor(url: file)
        defer { Task { await extractor.shutdown() } }
        // This file's first frame sits at 0, so both axes name the same frame. Grey 2n per frame
        // n means a frame off reads two (plus colour conversion) levels off.
        let relative = try #require(await extractor.snapshot(afterFirstFrameBy: 1.0))
        let absolute = try #require(await extractor.snapshot(at: 1.0))
        let earlier = try #require(await extractor.snapshot(afterFirstFrameBy: 0.5))
        let grey = try #require(Self.centreGrey(relative))
        #expect(grey == Self.centreGrey(absolute))
        #expect(grey > (Self.centreGrey(earlier) ?? .max))
    }

    @Test("a software-path audio rebuild holds the renderer's picture until the next host's first frame")
    func softwareRebuildHoldsThePicture() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        var options = LoadOptions()
        options.preferredDecodePath = .software
        _ = try await engine.load(url: file, options: options)
        #expect(engine.playbackBackend == .software)
        let host = try #require(engine.softwareHost)
        try await waitFor { host.isVideoReadyForDisplay }
        let audioIndex = try #require(engine.activeAudioTrackIndex)

        var held = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if view.isHoldingStill { held = true }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let failure = await engine.reloadWithAudioOverride(
            url: file, audioStreamIndex: Int32(audioIndex), expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
        try await waitFor { !view.isHoldingStill }
        watcher.cancel()

        #expect(held)
        #expect(engine.heldPictureLastRoute == "software renderer")
        #expect(engine.heldPictureLastRelease == "first frame of the next host")
        #expect(engine.softwareHost !== host)
    }

    nonisolated private static let userFixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/user")
    nonisolated static let profile5URL = userFixtures
        .appendingPathComponent("Patterns_Of_Nature_DoVi_24_P5_UHD_HEVC-10mbps_DD+JOC-768kbps_iOS.mp4")
    nonisolated static let profile81URL = userFixtures
        .appendingPathComponent("Patterns_Of_Nature_HDR10-P8.1_UHD_24_H265-10Mbps_DD+JOC-768Kbps.mp4")

    #if DolbyVisionStillReshaping
    /// Dolby's own Profile 5 signal, which cannot be committed: the base layer is IPTPQc2 and only
    /// the RPU makes it a picture, so the hold must come from the reshaping path.
    @Test("a Profile 5 title holds a reshaped still",
          .enabled(if: FileManager.default.fileExists(atPath: ItemSwapStillTests.profile5URL.path)))
    func profile5HoldsAReshapedStill() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        _ = try await engine.load(url: Self.profile5URL)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        try await Task.sleep(for: .seconds(1))
        engine.pause()
        let started = ContinuousClock.now
        await engine.holdPictureAcrossItemSwap()
        #expect(ContinuousClock.now - started < .seconds(AetherEngine.heldPictureDolbyVisionBudgetSeconds))
        #expect(engine.videoFormat == .dolbyVision)
        #expect(engine.heldPictureLastRoute == "Dolby Vision reshaped")
        #expect(view.isHoldingStill)
    }
    #else
    /// Without the reshaping a Profile 5 picture cannot be made into a still, so where the hold needs
    /// one (the output presents Dolby Vision) the engine plays the frame out of the resident segment
    /// through a player of the surface's own, and the system compositor colours it. Where AVPlayer
    /// presents the source as HDR10 (a Mac without a Dolby Vision display), the output's own picture
    /// is correct and is held as before.
    @Test("without the reshaping trait a Profile 5 title holds its frame through the compositor",
          .enabled(if: FileManager.default.fileExists(atPath: ItemSwapStillTests.profile5URL.path)))
    func profile5WithoutReshapingHoldsThroughCompositor() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        _ = try await engine.load(url: Self.profile5URL)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        try await Task.sleep(for: .seconds(1))
        engine.pause()
        // No scrub still either; the compositor preview stands in, and the capabilities say so up front.
        #expect(!engine.supportsCacheBackedStills)
        #expect(engine.scrubPreviewDrawsInView)
        #expect(await engine.scrubThumbnail(atSeconds: 0.5, maxWidth: 160) == nil)
        let started = ContinuousClock.now
        await engine.holdPictureAcrossItemSwap()
        #expect(ContinuousClock.now - started < .seconds(AetherEngine.heldPictureDolbyVisionBudgetSeconds + 0.5))
        if AetherEngine.heldPictureNeedsReshaping(videoFormat: engine.videoFormat, dolbyVisionProfile: engine.sourceDVProfile) {
            #expect(engine.heldPictureLastRoute == "Dolby Vision compositor")
            #expect(view.isHoldingStill)
        } else {
            #expect(engine.heldPictureLastRoute == "native output")
        }
        #expect(engine.heldPictureLastRoute != "Dolby Vision reshaped")
    }
    #endif

    @Test("a Profile 8.1 title holds its HDR10 base layer from the output",
          .enabled(if: FileManager.default.fileExists(atPath: ItemSwapStillTests.profile81URL.path)))
    func profile81HoldsTheBaseLayer() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        _ = try await engine.load(url: Self.profile81URL)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        await engine.holdPictureAcrossItemSwap()
        #expect(engine.heldPictureLastSkip == nil)
        #expect(engine.heldPictureLastRoute == "native output")
        #expect(view.isHoldingStill)
    }

    static func centreGrey(_ image: CGImage) -> Int? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let x = image.width / 2, y = image.height / 2
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[1])
    }
}

private struct FixtureWriterFailed: Error {
    let status: Int
    let error: Error?
    /// Where each track stood when the wait gave up, read the instant before the cancel.
    let state: String
}
