import Foundation
import Testing
@testable import AetherEngine

/// AE#1129: a Matroska source's attachments are read after the first frame on a second reader, so the
/// fonts no longer sit in front of the startup. The session's own open passes over them; where a
/// second reader is not possible, the open reads them as before.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct Issue1129DeferredAttachmentTests {

    private func plan(skips: Bool = false, readsAtOpen: Bool = false, isLive: Bool = false,
                      sequential: Bool = false, held: Bool = false, serial: Bool = false,
                      canFork: Bool? = nil) -> AttachmentReadPlan {
        AetherEngine.attachmentReadPlan(
            skips: skips, readsAtOpen: readsAtOpen, isLive: isLive, sequentialOrigin: sequential,
            heldSourceConnection: held, originSerial: serial, customReaderCanFork: canFork)
    }

    @Test func aURLSourceReadsAfterTheFirstFrame() {
        #expect(plan() == .afterFirstFrame)
        #expect(plan(canFork: true) == .afterFirstFrame)
        #expect(!plan().readsAtOpen)
    }

    @Test func skippingWinsOverEverything() {
        #expect(plan(skips: true, readsAtOpen: true, isLive: true, canFork: false) == .skip)
        #expect(!AttachmentReadPlan.skip.readsAtOpen)
    }

    @Test func aSourceThatCannotTakeASecondReaderReadsAtOpen() {
        #expect(plan(readsAtOpen: true).readsAtOpen)
        #expect(plan(isLive: true).readsAtOpen)
        #expect(plan(sequential: true).readsAtOpen)
        #expect(plan(held: true).readsAtOpen)
        #expect(plan(serial: true).readsAtOpen)
        #expect(plan(canFork: false).readsAtOpen)
    }

    @Test func onlyMatroskaHasSomethingToFetch() {
        #expect(AetherEngine.deferredAttachmentReadApplies(plan: .afterFirstFrame, containerFormat: "matroska,webm"))
        #expect(!AetherEngine.deferredAttachmentReadApplies(plan: .afterFirstFrame, containerFormat: "mov,mp4,m4a,3gp,3g2,mj2"))
        #expect(!AetherEngine.deferredAttachmentReadApplies(plan: .afterFirstFrame, containerFormat: nil))
        #expect(!AetherEngine.deferredAttachmentReadApplies(plan: .atOpen(reason: "x"), containerFormat: "matroska,webm"))
        #expect(!AetherEngine.deferredAttachmentReadApplies(plan: .skip, containerFormat: "matroska,webm"))
    }

    @Test func theSideReaderReadsTheAttachmentsAndNothingElse() throws {
        let profile = DemuxerOpenProfile.attachmentSideReader
        #expect(profile.skipStreamInfo)
        #expect(!profile.skipsAttachments)
        #expect(profile.readerLabel == "attachments")
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try #require(AetherEngine.readAttachments(
            demuxer: Demuxer(), url: url, reader: nil, formatHint: nil, headers: [:]))
        #expect(result.fonts.map(\.filename) == ["a.ttf", "b.otf"])
        #expect(result.fonts.first?.data == Data("AE1129-FONT-A".utf8))
    }

    @Test func aSessionGetsItsFontsAfterTheLoad() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.volume = 0
        _ = try await engine.load(url: url, options: LoadOptions())
        #expect(engine.attachmentReadPlan == .afterFirstFrame)
        // The side read starts at the end of the load and publishes after a hop, so the load returns
        // without the fonts; reading them at open had them here.
        #expect(engine.fontAttachments.isEmpty)
        try await waitFor { !engine.fontAttachments.isEmpty }
        #expect(engine.fontAttachments.map(\.filename) == ["a.ttf", "b.otf"])
    }

    @Test func readingAtOpenHasThemWhenTheLoadReturns() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.volume = 0
        var options = LoadOptions()
        options.readsContainerAttachmentsAtOpen = true
        _ = try await engine.load(url: url, options: options)
        #expect(engine.attachmentReadPlan.readsAtOpen)
        #expect(engine.fontAttachments.map(\.filename) == ["a.ttf", "b.otf"])
        #expect(engine.deferredAttachmentTask == nil)
    }

    @Test func skippingStartsNoSideRead() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.volume = 0
        var options = LoadOptions()
        options.skipsContainerAttachments = true
        _ = try await engine.load(url: url, options: options)
        #expect(engine.attachmentReadPlan == .skip)
        #expect(engine.deferredAttachmentTask == nil)
        #expect(engine.fontAttachments.isEmpty)
    }

    @Test func stoppingCancelsTheSideRead() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        engine.volume = 0
        _ = try await engine.load(url: url, options: LoadOptions())
        engine.stop()
        #expect(engine.deferredAttachmentTask == nil)
        #expect(engine.deferredAttachmentToken == nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(engine.fontAttachments.isEmpty)
    }

    private func writeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ae1129b-\(UUID().uuidString).mkv")
        try Issue1129AttachmentProbeTests.fixture().write(to: url)
        return url
    }

    /// No deadline of its own; the suite's time limit catches a hang.
    private func waitFor(_ condition: () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
