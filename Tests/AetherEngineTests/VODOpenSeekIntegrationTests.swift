import AVFoundation
import Combine
import Foundation
import Testing
@testable import AetherEngine

/// Real AVPlayer witness with a synthetic H.264/AAC MKV, served only over loopback.
/// Scripts/test-vod-open-seek.sh supplies the fixture; no provider credentials are needed.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct VODOpenSeekIntegrationTests {
    private func fixture() throws -> Data {
        let path = try #require(ProcessInfo.processInfo.environment["AETHER_VOD_FIXTURE"])
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    @Test("A silent first request recovers once, then native forward and backward seeks land",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_VOD_FIXTURE"] != nil))
    func recoveredSourceSeeks() async throws {
        let origin = try ProbeHTTPTestOrigin(data: fixture(), stage: .headers)
        let engine = try AetherEngine()
        defer { engine.stop(); origin.stop() }
        var options = LoadOptions(sourceOpenPolicy: .init(firstByteTimeout: 0.2, sizeProbeTimeout: 2))
        options.maxConcurrentSourceRequests = 1
        options.prepareNativeSubtitles = true
        options.preferredSubtitleLanguages = ["en"]
        options.suppressDisplayCriteria = true
        let started = ContinuousClock.now
        try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!, options: options)
        try await waitFor { engine.canSeek && engine.currentTime > 0.5 }
        #expect(engine.videoRoute == .loopback)
        #expect(!engine.subtitleTracks.isEmpty)
        // The primary packet harvest must still supply subtitles with serial source I/O.
        try await waitFor { !engine.subtitleCues.isEmpty }
        let elapsed = started.duration(to: .now)
        print("VOD_RECOVERY_READY=\(elapsed) requests=\(origin.requests.count)")
        #expect(elapsed < .seconds(5), "a recovered open must not repeat the probe/reconnect ladder")
        #expect(origin.requests.allSatisfy { $0.method == "GET" && $0.range != nil })
        let player = try #require(engine.currentAVPlayer)
        var events: [SeekEvent] = []
        let observer = engine.seekEvents.sink { events.append($0) }
        defer { observer.cancel() }
        for target in [12.0, 4.0] {
            await engine.seek(to: target)
            let actual = player.currentTime().seconds
            print("VOD_SEEK target=\(target) item=\(actual) engine=\(engine.currentTime) source=\(engine.sourceTime)")
            #expect(abs(actual - target) < 1)
            #expect(abs(engine.currentTime - target) < 1)
            let landed = events.contains { event in
                if case .landed(let rendered) = event.outcome { return abs(rendered - target) < 1 }
                return false
            }
            #expect(landed)
            try await waitFor { engine.currentTime > target + 1 }
            #expect(player.currentItem?.error == nil)
        }
        engine.pause()
        await engine.seek(to: 6)
        #expect(abs(player.currentTime().seconds - 6) < 0.25)
        #expect(engine.state == .paused)
        #expect(player.rate == 0)
        let source = URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.peakInflight == 1)
    }

    @Test("A forward-only VOD ignores saved position, rejects a seek past its resident tail, lands one inside it",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_VOD_FIXTURE"] != nil))
    func sequentialSourceHasHonestClock() async throws {
        let origin = try ProbeHTTPTestOrigin(data: fixture())
        let engine = try AetherEngine()
        defer { engine.stop(); origin.stop() }
        var options = LoadOptions()
        options.sequentialOrigin = true
        options.declaredDurationSeconds = 20
        options.maxConcurrentSourceRequests = 1
        options.prepareNativeSubtitles = true
        options.preferredSubtitleLanguages = ["en"]
        options.suppressDisplayCriteria = true
        try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!, startPosition: 12, options: options)
        try await waitFor { engine.isSessionReady && engine.currentTime > 0.5 }
        #expect(engine.isSourceSeekable == false)
        #expect(!engine.canSeek)
        #expect(engine.currentTime < 5)
        var events: [SeekEvent] = []
        let observer = engine.seekEvents.sink { events.append($0) }
        defer { observer.cancel() }
        // AE#958: a loopback seek inside the span that reaches the producer's frontier lands;
        // anything past what is held is still refused without moving the clock.
        let frontier = try #require(engine.residentRanges.max { $0.upperBound < $1.upperBound })
        await engine.seek(to: frontier.upperBound + 30)
        #expect(events.map(\.outcome) == [.rejected(.sourceNotSeekable)])
        #expect(engine.currentTime < 5)
        #expect(!engine.isSeeking)
        let inside = min(frontier.upperBound - 1, 12)
        #expect(inside > engine.currentTime + 1, "the fixture must hold a resident target ahead of the clock")
        events.removeAll()
        await engine.seek(to: inside)
        #expect(events.contains { event in
            if case .landed(let rendered) = event.outcome { return abs(rendered - inside) < 1 }
            return false
        })
        #expect(abs(engine.currentTime - inside) < 1)
        print("VOD_SEQUENTIAL clock=\(engine.currentTime) frontier=\(frontier) seekable=\(engine.canSeek) events=\(events)")
    }
}
