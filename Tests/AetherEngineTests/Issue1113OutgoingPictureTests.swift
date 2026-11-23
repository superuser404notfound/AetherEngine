import Testing
import Foundation
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif
@testable import AetherEngine

/// AE#1113: a host keeps the outgoing episode's picture on a still view of its own across its next
/// `load()`, and takes it down itself. The software-path tests run everywhere; the native ones read a
/// paused frame, which the macOS CI runner never vends (see `ItemSwapStillTests.vendsPausedFrames`).
@Suite("AE#1113: the outgoing picture held across the host's next load", .serialized,
       .timeLimit(.minutes(3)))
@MainActor
struct Issue1113OutgoingPictureTests {

    private func softwareOptions() -> LoadOptions {
        var options = LoadOptions()
        options.preferredDecodePath = .software
        return options
    }

    private func loadSoftware(_ engine: AetherEngine, _ file: URL) async throws {
        _ = try await engine.load(url: file, options: softwareOptions())
        #expect(engine.playbackBackend == .software)
        try await waitFor { engine.hasFirstFrameReadyForDisplay }
    }

    @Test("the hold survives the next load, route change included, and comes down when the host says")
    func survivesTheNextLoadUntilTheHostReleases() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await loadSoftware(engine, file)

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile))
        #expect(tile.isHoldingStill)
        #expect(engine.state == .paused)
        #expect(engine.outgoingPictureLastRoute == "software renderer")

        // Software to native: the hold watches the engine's first-frame edge, not one host's.
        _ = try await engine.load(url: file)
        #expect(tile.isHoldingStill)
        try await waitFor { engine.hasFirstFrameReadyForDisplay }
        try await waitFor { engine.outgoingPictureSawNextFrame }
        #expect(tile.isHoldingStill)

        engine.releaseOutgoingPicture()
        #expect(!tile.isHoldingStill)
        #expect(engine.outgoingPictureLastRelease == "released by the host")
        #expect(engine.outgoingPictureView == nil)
    }

    @Test("native to software: the paused native read holds into a software load",
          .enabled(if: ItemSwapStillTests.vendsPausedFrames))
    func nativeIntoSoftware() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: file)
        try await waitFor { engine.hasFirstFrameReadyForDisplay }

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile))
        #expect(engine.outgoingPictureLastRoute == "native output")

        try await loadSoftware(engine, file)
        try await waitFor { engine.outgoingPictureSawNextFrame }
        #expect(tile.isHoldingStill)
    }

    @Test("an episode that already ended still hands over its last picture",
          .enabled(if: ItemSwapStillTests.vendsPausedFrames))
    func endedNativeItemHolds() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: file)
        try await waitFor { engine.state == .ended }

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile),
                "skipped: \(engine.heldPictureLastSkip ?? "no skip recorded")")
    }

    @Test("an ended software episode hands over its last picture")
    func endedSoftwareItemHolds() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await loadSoftware(engine, file)
        try await waitFor { engine.state == .ended }

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile),
                "skipped: \(engine.heldPictureLastSkip ?? "no skip recorded")")
    }

    @Test("a host that never releases gets the picture taken down a grace period after the next first frame")
    func safetyNetAfterTheNextFrame() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await loadSoftware(engine, file)
        engine.outgoingPictureGraceSeconds = 0.3

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile))
        try await loadSoftware(engine, file)
        try await waitFor { !tile.isHoldingStill }
        #expect(engine.outgoingPictureLastRelease == "timeout after the next first frame")
    }

    @Test("a hold with no load after it comes down at the cap")
    func capWithoutANextPicture() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await loadSoftware(engine, file)
        engine.outgoingPictureCapSeconds = 0.3

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile))
        try await waitFor { !tile.isHoldingStill }
        #expect(engine.outgoingPictureLastRelease == "no next picture")
    }

    @Test("stop takes the hold down")
    func stopReleases() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        try await loadSoftware(engine, file)

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile))
        engine.stop()
        #expect(!tile.isHoldingStill)
        #expect(engine.outgoingPictureLastRelease == "stop")
    }

    @Test("a next load that fails takes the hold down")
    func failedLoadReleases() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await loadSoftware(engine, file)

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile))
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae1113-missing-\(UUID().uuidString).mp4")
        _ = try? await engine.load(url: missing)
        try await waitFor { !tile.isHoldingStill }
        #expect(engine.outgoingPictureLastRelease == "next load failed")
    }

    @Test("an audio switch holds on the bound still view and leaves the host's tile alone")
    func audioSwitchKeepsToItsOwnSurface() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let bound = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bindStillView(bound)
        try await loadSoftware(engine, file)

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 128, height: 72))
        #expect(await engine.holdOutgoingPicture(on: tile))
        let audioIndex = try #require(engine.activeAudioTrackIndex)
        let failure = await engine.reloadWithAudioOverride(
            url: file, audioStreamIndex: Int32(audioIndex), expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
        try await waitFor { engine.heldPictureView == nil }
        #expect(tile.isHoldingStill)
        #expect(engine.outgoingPictureView === tile)
        #expect(!bound.isHoldingStill)
    }

    @Test("a load its caller cancels takes the hold down instead of leaving it for the cap")
    func cancelledLoadReleases() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await loadSoftware(engine, file)

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: tile))
        // An origin that accepts and never answers, so the load is still opening when it is cancelled.
        let (fd, port) = try #require(LoopbackPort.listen(backlog: 4))
        defer { close(fd) }
        let silent = try #require(URL(string: "http://127.0.0.1:\(port)/next.mkv"))
        let next = Task { @MainActor in _ = try? await engine.load(url: silent) }
        try await waitFor { engine.state == .loading }
        next.cancel()
        try await waitFor { !tile.isHoldingStill }
        #expect(engine.outgoingPictureLastRelease == "next load ended without a picture")
    }

    @Test("handed the bound still view, the hold keeps it, and an audio switch holds nothing there")
    func boundViewStaysWithTheHost() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let bound = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bindStillView(bound)
        try await loadSoftware(engine, file)

        #expect(await engine.holdOutgoingPicture(on: bound))
        let audioIndex = try #require(engine.activeAudioTrackIndex)
        let failure = await engine.reloadWithAudioOverride(
            url: file, audioStreamIndex: Int32(audioIndex), expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
        #expect(engine.heldPictureLastSkip == "surface holds the host's outgoing picture")
        try await waitFor { engine.hasFirstFrameReadyForDisplay }
        #expect(bound.isHoldingStill)
        #expect(engine.outgoingPictureView === bound)
    }

    @Test("a new hold replaces the old one")
    func secondHoldReplacesTheFirst() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await loadSoftware(engine, file)

        let first = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let second = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        #expect(await engine.holdOutgoingPicture(on: first))
        #expect(await engine.holdOutgoingPicture(on: second))
        #expect(!first.isHoldingStill)
        #expect(second.isHoldingStill)
    }

    #if !DolbyVisionStillReshaping
    /// Profile 5 has no displayable base layer, so the tile gets the compositor route: a player
    /// layer of the still view's own, in its own subview like the sample-buffer still.
    @Test("a Profile 5 episode holds its picture through the compositor on the host's tile",
          .enabled(if: FileManager.default.fileExists(atPath: ItemSwapStillTests.profile5URL.path)))
    func profile5HoldsOnTheTile() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: ItemSwapStillTests.profile5URL)
        try await waitFor { engine.hasFirstFrameReadyForDisplay }
        try await Task.sleep(for: .seconds(1))

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 512, height: 288))
        #expect(await engine.holdOutgoingPicture(on: tile))
        if AetherEngine.heldPictureNeedsReshaping(videoFormat: engine.videoFormat, dolbyVisionProfile: engine.sourceDVProfile) {
            #expect(engine.outgoingPictureLastRoute == "Dolby Vision compositor")
            #expect(tile.heldStillMountView?.layer is AVPlayerLayer)
        } else {
            #expect(engine.outgoingPictureLastRoute == "native output")
        }
        _ = try await engine.load(url: ItemSwapStillTests.profile5URL)
        #expect(tile.isHoldingStill)
    }
    #endif

    #if canImport(AppKit)
    /// The tile shrinks by its frame. The still has to follow without a layout pass of its own,
    /// which is what lets it ride inside the host's animation instead of Core Animation's default.
    @Test("resizing the still view carries the picture along")
    func resizeCarriesThePicture() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await loadSoftware(engine, file)

        let tile = AetherStillView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(await engine.holdOutgoingPicture(on: tile))
        let mounted = try #require(tile.heldStillMountView)
        #expect(mounted.frame == tile.bounds)
        tile.setFrameSize(NSSize(width: 512, height: 288))
        #expect(mounted.frame == CGRect(x: 0, y: 0, width: 512, height: 288))
        #expect(mounted.layer is AVSampleBufferDisplayLayer)
        engine.releaseOutgoingPicture()
        #expect(mounted.superview == nil)
    }
    #endif
}
