import Foundation
import Testing
@testable import AetherEngine

/// A Matroska source's attachments are read after the first frame on a second reader, so the fonts no
/// longer sit in front of the startup (AE#1129). The session's own open passes over them; where a
/// second reader is not possible, the open reads them as before.
@Suite(.timeLimit(.minutes(3)))
struct AttachmentReadPlanTests {

    private func plan(skips: Bool = false, readsAtOpen: Bool = false, isLive: Bool = false,
                      sequential: Bool = false, held: Bool = false, serial: Bool = false,
                      canFork: Bool? = nil) -> AttachmentReadPlan {
        AetherEngine.attachmentReadPlan(
            skips: skips, readsAtOpen: readsAtOpen, isLive: isLive, sequentialOrigin: sequential,
            heldSourceConnection: held, originSerial: serial, customReaderCanFork: canFork)
    }

    @Test("AE#1129: a URL source reads after the first frame")
    func urlSourceReadsLater() {
        #expect(plan() == .afterFirstFrame)
        #expect(plan(canFork: true) == .afterFirstFrame)
        #expect(!plan().readsAtOpen)
    }

    @Test("AE#1129: skipping wins over every other input")
    func skippingWins() {
        #expect(plan(skips: true, readsAtOpen: true, isLive: true, canFork: false) == .skip)
        #expect(!AttachmentReadPlan.skip.readsAtOpen)
    }

    @Test("AE#1129: a source that cannot take a second reader reads at open")
    func noSecondReaderReadsAtOpen() {
        #expect(plan(readsAtOpen: true).readsAtOpen)
        #expect(plan(isLive: true).readsAtOpen)
        #expect(plan(sequential: true).readsAtOpen)
        #expect(plan(held: true).readsAtOpen)
        #expect(plan(serial: true).readsAtOpen)
        #expect(plan(canFork: false).readsAtOpen)
    }

    @Test("AE#1129: only Matroska has attachments the open passed over")
    func onlyMatroska() {
        #expect(AetherEngine.deferredAttachmentReadApplies(plan: .afterFirstFrame, containerFormat: "matroska,webm"))
        #expect(!AetherEngine.deferredAttachmentReadApplies(plan: .afterFirstFrame, containerFormat: "mov,mp4,m4a,3gp,3g2,mj2"))
        #expect(!AetherEngine.deferredAttachmentReadApplies(plan: .afterFirstFrame, containerFormat: nil))
        #expect(!AetherEngine.deferredAttachmentReadApplies(plan: .atOpen(reason: "x"), containerFormat: "matroska,webm"))
        #expect(!AetherEngine.deferredAttachmentReadApplies(plan: .skip, containerFormat: "matroska,webm"))
    }

    @Test("AE#1129: the read waits for the first frame and a buffer cushion")
    func startGate() {
        func may(_ picture: Bool, _ frame: Bool, _ now: Double, _ buffered: Double, _ duration: Double = 600) -> Bool {
            AetherEngine.attachmentReadMayStart(hasPicture: picture, firstFrame: frame, currentTime: now,
                                                bufferedPosition: buffered, duration: duration)
        }
        #expect(!may(true, false, 0, 60))     // no picture yet
        #expect(!may(true, true, 0, 10))      // picture, thin buffer
        #expect(may(true, true, 0, 15))       // picture and the cushion
        #expect(may(true, true, 0, 9.6, 10))  // a short file, all of it buffered
        #expect(may(false, false, 0, 20))     // no picture to wait for
        #expect(!may(false, false, 0, 5))
    }

    @Test("AE#1129: the side reader reads the attachments and skips the stream analysis")
    func sideReaderReadsAttachments() throws {
        let profile = DemuxerOpenProfile.attachmentSideReader
        #expect(profile.skipStreamInfo)
        #expect(!profile.skipsAttachments)
        #expect(profile.readerLabel == "attachments")
        let url = try writeAttachmentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try #require(AetherEngine.readAttachments(
            demuxer: Demuxer(), url: url, reader: nil, formatHint: nil, headers: [:]))
        #expect(result.fonts.map(\.filename) == ["a.ttf", "b.otf"])
        #expect(result.fonts.first?.data == Data("AE1129-FONT-A".utf8))
    }
}

@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct MatroskaAttachmentsAfterFirstFrameTests {

    @Test("AE#1129: a session gets its fonts after load() returns")
    func fontsArriveAfterTheLoad() async throws {
        let url = try writeAttachmentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.volume = 0
        engine.deferredAttachmentCushionWaitNanos = 0
        _ = try await engine.load(url: url, options: LoadOptions())
        #expect(engine.attachmentReadPlan == .afterFirstFrame)
        // The side read starts at the end of the load and publishes after a hop, so the load returns
        // without the fonts; reading them at open had them here.
        #expect(engine.fontAttachments.isEmpty)
        try await waitFor { !engine.fontAttachments.isEmpty }
        #expect(engine.fontAttachments.map(\.filename) == ["a.ttf", "b.otf"])
    }

    @Test("AE#1129: readsContainerAttachmentsAtOpen has them when load() returns")
    func readAtOpen() async throws {
        let url = try writeAttachmentFixture()
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

    @Test("AE#1129: skipsContainerAttachments starts no side read")
    func skippingStartsNothing() async throws {
        let url = try writeAttachmentFixture()
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

    /// The seam holds the read after it registered its demuxer, so the stop lands inside the read, and
    /// the finished task is awaited. Two guards keep the fonts out: the stop's `markClosed()` aborts the
    /// open, and the token check drops a read that finished anyway. Without both they are published.
    @Test("AE#1129: a side read that outlives its session publishes nothing")
    func stoppedSessionGetsNothing() async throws {
        let url = try writeAttachmentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        engine.volume = 0
        engine.deferredAttachmentCushionWaitNanos = 0
        engine.deferredAttachmentReadDelayNanosForTesting = 500_000_000
        _ = try await engine.load(url: url, options: LoadOptions())
        try await waitFor { engine.deferredAttachmentDemuxer != nil }
        let task = try #require(engine.deferredAttachmentTask)
        engine.stop()
        await task.value
        #expect(engine.fontAttachments.isEmpty)
        #expect(engine.deferredAttachmentToken == nil)
    }
}

private func writeAttachmentFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ae1129b-\(UUID().uuidString).mkv")
    try Issue1129AttachmentProbeTests.fixture().write(to: url)
    return url
}
