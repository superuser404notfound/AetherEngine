import Testing
@testable import AetherEngine

@Suite("Local rendered-frame evidence", .timeLimit(.minutes(3)))
@MainActor
struct RenderedVideoFrameTests {
    private let presented = SampleBufferRenderer.RenderMetrics(
        total: 2, dropped: 1, corrupted: 0, accumulatedDelay: 0)

    @Test("No session has no presented frame")
    func idleEngine() async throws {
        let engine = try AetherEngine()
        #expect(await engine.hasRenderedVideoFrame() == false)
    }

    @Test("A retained software host cannot answer for a non-software backend",
          arguments: [PlaybackBackend.none, .audio, .aether, .native])
    func inactiveHost(backend: PlaybackBackend) async throws {
        let engine = try AetherEngine()
        engine.softwareHost = SoftwarePlaybackHost()
        engine.playbackBackend = backend
        let result = await engine.hasRenderedVideoFrame { _ in
            Issue.record("Inactive software metrics must not be read")
            return presented
        }
        #expect(!result)
    }

    @Test("An unavailable metrics read does not turn enqueue readiness into presentation")
    func unavailableMetrics() async throws {
        let engine = try AetherEngine()
        engine.softwareHost = SoftwarePlaybackHost()
        engine.playbackBackend = .software
        engine.hasFirstFrameReadyForDisplay = true
        #expect(await engine.hasRenderedVideoFrame { _ in nil } == false)
    }

    @Test("Only a non-dropped frame is evidence of presentation",
          arguments: [(0, 0, false), (2, 2, false), (2, 1, true), (1, 0, true)])
    func rendererVerdict(total: Int, dropped: Int, expected: Bool) async throws {
        let engine = try AetherEngine()
        let host = SoftwarePlaybackHost()
        engine.softwareHost = host
        engine.playbackBackend = .software
        let result = await engine.hasRenderedVideoFrame { queriedHost in
            #expect(queriedHost === host)
            return .init(total: total, dropped: dropped, corrupted: 0, accumulatedDelay: 0)
        }
        #expect(result == expected)
    }

    @Test("A metrics completion cannot outlive its load, host, backend or caller",
          arguments: ["load", "host", "backend", "cancel"])
    func supersededRead(change: String) async throws {
        let engine = try AetherEngine()
        engine.softwareHost = SoftwarePlaybackHost()
        engine.playbackBackend = .software
        var continuation: CheckedContinuation<SampleBufferRenderer.RenderMetrics?, Never>?
        let read = Task { @MainActor in
            await engine.hasRenderedVideoFrame { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        try await waitFor { continuation != nil }
        switch change {
        case "load": engine.loadGeneration &+= 1
        case "host": engine.softwareHost = SoftwarePlaybackHost()
        case "backend": engine.playbackBackend = .audio
        default: read.cancel()
        }
        continuation?.resume(returning: presented)
        #expect(await read.value == false)
    }
}
