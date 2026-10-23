import Testing
import CoreGraphics
import Foundation
@testable import AetherEngine

/// A software session that plays a local file keeps no packet cache (re-reading the file is free), so
/// it used to report no cache-backed stills and answer every scrub request with nil. It now decodes
/// them from the file, through the same `scrubThumbnail` / `scrubPreviewFrame` calls the native
/// session answers.
@Suite("Scrub stills on a software session playing a local file", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SoftwareLocalScrubStillTests {

    /// The 4 s fixture, built once per process and left for the temporary directory to reclaim.
    private static let fixture = Task { try await ItemSwapStillTests.fixtureURL() }

    private func loadSoftware(_ file: URL, dolbyVisionHandling: DolbyVisionHandling = .automatic) async throws -> AetherEngine {
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.preferredDecodePath = .software
        options.dolbyVisionHandling = dolbyVisionHandling
        _ = try await engine.load(url: file, options: options)
        #expect(engine.playbackBackend == .software)
        return engine
    }

    @Test("there is nothing to serve before a session is loaded")
    func nothingBeforeLoad() throws {
        let engine = try AetherEngine()
        #expect(!engine.supportsCacheBackedStills)
        #expect(!engine.softwareStillsFromLocalFile)
    }

    @Test("a local software session advertises stills and decodes the frame it was asked for")
    func stillsFollowTheTarget() async throws {
        // The fixture paints frame n at grey level 2n, 30 frames a second, so brightness names the time.
        let file = try await Self.fixture.value
        let engine = try await loadSoftware(file)
        defer { engine.stop() }
        #expect(engine.supportsCacheBackedStills)

        let early = try #require(await engine.scrubThumbnail(atSeconds: 0.5, maxWidth: 64))
        let late = try #require(await engine.scrubThumbnail(atSeconds: 3.0, maxWidth: 64))
        #expect(early.width <= 64)
        let earlyGrey = try #require(ItemSwapStillTests.centreGrey(early))
        let lateGrey = try #require(ItemSwapStillTests.centreGrey(late))
        #expect(lateGrey > earlyGrey + 40)
    }

    @Test("the preview call answers too, refined or not, and honours cancellation")
    func previewFrames() async throws {
        let file = try await Self.fixture.value
        let engine = try await loadSoftware(file)
        defer { engine.stop() }

        let coarse = try #require(await engine.scrubPreviewFrame(
            atSeconds: 2.0, refined: false, maxWidth: 64, isCancelled: { false }))
        #expect(!coarse.refined)
        // The decoded frame's own time: the keyframe at or before the target, never after it.
        #expect(coarse.actualSeconds <= 2.0 && coarse.actualSeconds >= 0)

        let exact = try #require(await engine.scrubPreviewFrame(
            atSeconds: 2.0, refined: true, maxWidth: 64, isCancelled: { false }))
        #expect(exact.refined)
        #expect(abs(exact.actualSeconds - 2.0) < 0.1, "actual \(exact.actualSeconds)")
        let earlier = try #require(await engine.scrubPreviewFrame(
            atSeconds: 1.0, refined: true, maxWidth: 64, isCancelled: { false }))
        // A second apart is 30 frames, 60 grey levels; colour conversion shifts both by the same
        // amount, so the difference is what names the frame.
        let delta = try #require(ItemSwapStillTests.centreGrey(exact.image))
            - (try #require(ItemSwapStillTests.centreGrey(earlier.image)))
        #expect(abs(delta - 60) <= 8, "delta \(delta)")

        #expect(await engine.scrubPreviewFrame(
            atSeconds: 2.0, refined: false, maxWidth: 64, isCancelled: { true }) == nil)
        #expect(await engine.scrubPreviewFrame(
            atSeconds: .nan, refined: false, maxWidth: 64, isCancelled: { false }) == nil)
    }

    @Test("one extractor serves every request and is released with the session")
    func extractorIsKeptAndReleased() async throws {
        let file = try await Self.fixture.value
        let engine = try await loadSoftware(file)
        _ = await engine.scrubThumbnail(atSeconds: 1, maxWidth: 64)
        _ = await engine.scrubThumbnail(atSeconds: 2, maxWidth: 64)
        #expect(engine.scrubThumbnailExtractors.map { $0.segmentIndex } == [AetherEngine.localSoftwareStillKey])
        engine.stop()
        #expect(engine.scrubThumbnailExtractors.isEmpty)
        #expect(!engine.supportsCacheBackedStills)
    }

    @Test("a Dolby Vision Profile 5 file advertises stills only where its frames can become one")
    func profile5FollowsTheStillVerdict() async throws {
        // A Profile 5 record over an HDR10 VUI: the one Profile 5 the software path plays, as its base
        // layer (`.baseLayerOnly`). Every still decode still reads the record and refuses the stream.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("software-p5-still-\(UUID().uuidString).mp4")
        try SupersededProbeGeometryTests.dolbyVisionProfile5OverHDR10().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try await loadSoftware(file, dolbyVisionHandling: .baseLayerOnly)
        defer { engine.stop() }
        // Without the reshaping trait `FrameDecodeContext` refuses every still of this stream, so the
        // capability must say so instead of promising previews that never come.
        let yields = FrameDecodeContext.yieldsStill(dolbyVisionNoBaseLayer: true)
        #expect(engine.supportsCacheBackedStills == yields)
        if !yields {
            #expect(await engine.scrubThumbnail(atSeconds: 0, maxWidth: 64) == nil)
        }
    }
}
