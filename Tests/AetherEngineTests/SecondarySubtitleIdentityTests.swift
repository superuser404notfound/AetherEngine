import Combine
import Foundation
import Testing
@testable import AetherEngine

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SecondarySubtitleIdentityTests {
    private func player() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.loadedURL = URL(fileURLWithPath: "/nonexistent/identity-test.mkv")
        engine.state = .paused
        return engine
    }

    private func assertIdentity(_ engine: AetherEngine, _ expected: Int?) {
        let internalID = engine.activeSecondaryExternalSubtitleTrackID
            ?? (engine.activeSecondaryEmbeddedSubtitleStreamIndex >= 0
                ? Int(engine.activeSecondaryEmbeddedSubtitleStreamIndex) : nil)
        #expect(engine.activeSecondarySubtitleTrackIndex == expected)
        #expect(engine.activeSecondarySubtitleTrackIndex == internalID)
    }

    @Test func embeddedIdentityIsIndependentAndDeduplicated() throws {
        let engine = try player()
        defer { engine.stop() }
        var received: [Int?] = []
        let sub = engine.$activeSecondarySubtitleTrackIndex.sink { received.append($0) }
        defer { sub.cancel() }
        engine.selectSubtitleTrack(index: 3)
        engine.selectSecondarySubtitleTrack(index: 3)
        assertIdentity(engine, 3)
        #expect(engine.activeSubtitleTrackIndex == 3)
        engine.selectSecondarySubtitleTrack(index: 3)
        engine.clearSubtitle()
        assertIdentity(engine, 3)
        engine.clearSecondarySubtitle()
        assertIdentity(engine, nil)
        #expect(received == [nil, 3, nil])
    }

    @Test func registeredSelectionRestoreRemoveAndOneShot() async throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try player()
        defer { engine.stop() }
        let track = engine.registerExternalSubtitleTrack(.init(
            url: url, sourceStreamIndex: MultiSubtitleContainerFixture.spanishStreamIndex))
        engine.selectSecondarySubtitleTrack(index: track.id)
        assertIdentity(engine, track.id)
        await engine.secondarySidecarTask?.value
        assertIdentity(engine, track.id)
        #expect(!engine.secondarySubtitleCues.isEmpty)
        engine.stopInternal(resetDisplayCriteria: false)
        assertIdentity(engine, nil)
        engine.restoreSecondarySubtitleAfterRebuild(externalID: track.id, sidecarURL: url,
                                                    embeddedIndex: -1, startAt: 0)
        await engine.secondarySidecarTask?.value
        assertIdentity(engine, track.id)
        engine.selectSecondarySidecarSubtitle(url: url)
        await engine.secondarySidecarTask?.value
        assertIdentity(engine, nil)
        #expect(engine.isSecondarySubtitleActive)
        engine.selectSecondarySubtitleTrack(index: track.id)
        engine.removeExternalSubtitleTrack(id: track.id)
        assertIdentity(engine, nil)
        #expect(!engine.isSecondarySubtitleActive)
    }

    @Test func ordinaryFailureRetainsSelectedIdentityUntilClear() async throws {
        let engine = try player()
        defer { engine.stop() }
        let track = engine.registerExternalSubtitleTrack(.init(
            url: URL(fileURLWithPath: "/nonexistent/identity-failure.srt")))
        engine.selectSecondarySubtitleTrack(index: track.id)
        assertIdentity(engine, track.id)
        await engine.secondarySidecarTask?.value
        assertIdentity(engine, track.id)
        #expect(!engine.isLoadingSecondarySubtitles)
        engine.clearSecondarySubtitle()
        assertIdentity(engine, nil)
    }

    @Test func preparedIdentityPublishesOnlyAtCommit() async throws {
        let engine = try player()
        defer { engine.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        try Data("1\n00:00:00,000 --> 00:00:02,000\nIdentity\n\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        engine.selectSecondarySubtitleTrack(index: 2)
        let prepared = try await engine.prepareExternalSubtitle(.init(url: url))
        assertIdentity(engine, 2)
        let info = try engine.commitExternalSubtitle(prepared, secondary: true)
        assertIdentity(engine, info.id)
        engine.stop()
        assertIdentity(engine, nil)
    }

    @Test func synchronousSubscriberMayClearWithoutRestoringStaleIdentity() throws {
        let engine = try player()
        defer { engine.stop() }
        var received: [Int?] = []
        let sub = engine.$activeSecondarySubtitleTrackIndex.sink { id in
            received.append(id)
            if id != nil { engine.clearSecondarySubtitle() }
        }
        defer { sub.cancel() }
        engine.selectSecondarySubtitleTrack(index: 3)
        assertIdentity(engine, nil)
        #expect(!engine.isSecondarySubtitleActive)
        let external = engine.registerExternalSubtitleTrack(.init(
            url: URL(fileURLWithPath: "/nonexistent/identity-reentry.srt")))
        engine.selectSecondarySubtitleTrack(index: external.id)
        assertIdentity(engine, nil)
        #expect(!engine.isSecondarySubtitleActive)
        #expect(engine.secondarySidecarTask == nil)
        #expect(received == [nil, 3, nil, external.id, nil])
    }

    @Test func newLoadAndCancelledOldDecodeCannotRestoreIdentity() async throws {
        let engine = try player()
        defer { engine.stop() }
        engine.selectSecondarySubtitleTrack(index: 3)
        var options = LoadOptions(autoplay: false)
        options.preferredDecodePath = .software
        try await engine.load(source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()),
                                             formatHint: "mp4"), options: options)
        assertIdentity(engine, nil)
        #expect(!engine.isSecondarySubtitleActive)
    }
}
