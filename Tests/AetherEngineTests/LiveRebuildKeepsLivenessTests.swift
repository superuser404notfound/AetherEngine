import Foundation
import Testing
@testable import AetherEngine

/// An audio-track rebuild runs `stopInternal`, which clears the session's liveness, and reopens through
/// `loadNative`/`loadSoftware` rather than `load`. Measured in an IPTV host on 7.53.1 and on main after
/// 7.68.0: a live MPEG-TS channel switched to its second audio track came back with `isLive == false`
/// and no live window, so every later `startRecording` threw `.notLive` until the next `load`.
@Suite("A rebuild keeps the session's liveness", .timeLimit(.minutes(3)))
@MainActor
struct LiveRebuildKeepsLivenessTests {

    private static func rebuild(_ engine: AetherEngine) async throws {
        let url = try #require(engine.loadedURL)
        let failure = await engine.reloadWithAudioOverride(
            url: url, audioStreamIndex: nil, expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
    }

    @Test("a live channel is still live after an audio-track rebuild, with its window, and records")
    func liveChannelStaysLive() async throws {
        let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data, contentType: "video/mp2t"))
        defer { origin.stop() }
        let source = try #require(URL(string: "http://127.0.0.1:\(origin.port)/live.ts"))
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions(isLive: true, dvrWindowSeconds: 60, liveJoinProfile: .fastZap)
        options.suppressDisplayCriteria = true
        try await engine.load(url: source, options: options)
        #expect(engine.isLive)
        #expect(engine.liveWindow != nil)

        try await Self.rebuild(engine)
        try await waitFor { engine.state != .loading }

        #expect(engine.isLive)
        #expect(engine.liveWindow != nil)
        #expect(!engine.isSequentialOrigin)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rebuild-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: file) }
        try await engine.startRecording(to: file)
        guard case .recording = engine.recordingState else {
            Issue.record("the rebuilt live session did not start recording: \(engine.recordingState)")
            return
        }
        await engine.stopRecording()
    }

    @Test("a film stays a film after the same rebuild")
    func filmStaysAFilm() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"))
        #expect(!engine.isLive)

        try await Self.rebuild(engine)

        #expect(!engine.isLive)
        #expect(engine.liveWindow == nil)
    }
}
