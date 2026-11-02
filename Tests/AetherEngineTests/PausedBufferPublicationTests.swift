import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

@MainActor
@Suite("Paused native buffer publication", .timeLimit(.minutes(2)))
struct PausedBufferPublicationTests {
    private func fixture() throws -> (AetherEngine, NativeAVPlayerHost, SegmentCache) {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/paused-buffer.mkv"))
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        session.segmentPlan = [
            .init(startPts: 0, endPts: 5, startSeconds: 0, durationSeconds: 5),
            .init(startPts: 5, endPts: 12, startSeconds: 5, durationSeconds: 7),
            .init(startPts: 12, endPts: 20, startSeconds: 12, durationSeconds: 8),
            .init(startPts: 20, endPts: 30, startSeconds: 20, durationSeconds: 10),
        ]
        session.cache = cache
        engine.playbackBackend = .native
        engine.nativeHost = host
        engine.nativeVideoSession = session
        engine.currentAVPlayer = host.avPlayer
        engine.state = .paused
        return (engine, host, cache)
    }

    @Test("cache grows without a rendered-time tick or playback mutation")
    func pausedGrowth() throws {
        let (engine, host, cache) = try fixture()
        defer { engine.nativeVideoSession = nil; cache.close() }
        let position = engine.currentTime
        let state = engine.state
        cache.store(index: 0, data: Data([0]))
        engine.refreshNativeBufferedPosition()
        try #require(engine.bufferedPosition == 5)
        cache.store(index: 1, data: Data([0]))
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 12)
        #expect(host.renderedTime == 0)
        #expect(host.avPlayer.rate == 0)
        #expect(engine.currentTime == position)
        #expect(engine.state == state)
    }

    @Test("disconnected cache islands are excluded and eviction is reflected")
    func holesAndEviction() throws {
        let (engine, _, cache) = try fixture()
        defer { engine.nativeVideoSession = nil; cache.close() }
        for index in [0, 1, 3] { cache.store(index: index, data: Data([0])) }
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 12)
        cache.store(index: 2, data: Data([0]))
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 30)
        cache.evictBelow(1)
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 0)
    }

    @Test("refresh uses the rendered position's display-axis seam")
    func displayAxis() throws {
        let (engine, host, cache) = try fixture()
        defer { engine.nativeVideoSession = nil; cache.close() }
        engine.sourcePresentationOrigin = 100
        engine.playlistShiftSeconds = 103
        cache.store(index: 0, data: Data([0]))
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 8)
        var map = PresentationAxisMap.anchored(shiftSeconds: 101)
        map.appendSeam(shiftSeconds: 103, activatingAtItemSeconds: 20)
        engine.setPresentationAxis(map)
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 6)
        #expect(host.renderedTime == 0)
    }

    @Test("a pending seek measures the buffer from its target, not from the frame it left")
    func pendingSeekAnchorsOnTarget() throws {
        let (engine, host, cache) = try fixture()
        defer { engine.setPendingRecoverySeekTarget(nil); engine.nativeVideoSession = nil; cache.close() }
        for index in [0, 1] { cache.store(index: index, data: Data([0])) }
        engine.refreshNativeBufferedPosition()
        try #require(engine.bufferedPosition == 12)
        engine.clock.currentTime = 20
        engine.setPendingRecoverySeekTarget(20)
        engine.refreshNativeBufferedPosition()
        #expect(host.renderedTime == 0)
        #expect(engine.bufferedPosition == 20)
        cache.store(index: 3, data: Data([0]))
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 30)
    }

    @Test("the buffer never trails the published playhead")
    func neverTrailsPlayhead() throws {
        let (engine, _, cache) = try fixture()
        defer { engine.nativeVideoSession = nil; cache.close() }
        cache.store(index: 0, data: Data([0]))
        engine.clock.currentTime = 9
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 9)
    }

    @Test("teardown or absent host does not overwrite another path's buffer")
    func lifecycleGuards() throws {
        let (engine, _, cache) = try fixture()
        defer { cache.close() }
        engine.clock.bufferedPosition = 42
        engine.nativeHost = nil
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 42)
        engine.nativeVideoSession = nil
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 42)
    }

    @Test("the existing wall-clock sampler publishes growth while AVPlayer is paused")
    func independentSampler() async throws {
        let (engine, host, cache) = try fixture()
        host.avPlayer.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/paused-buffer.mp4")))
        let sampler = LiveTelemetrySampler(engine: engine, nativeRead: { _, _ in
            NativeAVFReadings(forwardBufferSeconds: 1)
        })
        defer { sampler.stop(); engine.nativeVideoSession = nil; cache.close() }
        cache.store(index: 0, data: Data([0]))
        sampler.start()
        try await waitFor { engine.diagnostics.liveTelemetry != nil }
        #expect(engine.diagnostics.liveTelemetry != nil)
        try #require(engine.bufferedPosition == 5)
        cache.store(index: 1, data: Data([0]))
        try await waitFor { engine.bufferedPosition == 12 }
        #expect(engine.bufferedPosition == 12)
        #expect(host.renderedTime == 0)
        #expect(host.avPlayer.rate == 0)
    }
}
