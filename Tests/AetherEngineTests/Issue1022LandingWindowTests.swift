import Foundation
import Testing
import AetherLibavformat
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

/// AE#1022 (Desima-AP): with `maximumSubtitleOffsetSeconds = 0` the forward prefetch stopped
/// (AE#1015), and nothing read or vouched for the ground behind a seek landing any more. A PGS line
/// a seek landed inside was refused by the #416 ground check, or never read at all when it began
/// before the pump's keyframe, and stayed dark until the next composition.
@MainActor
struct Issue1022LandingWindowTests {

    // MARK: - Read loop

    @Test("a landing session reads to just past the landing and stays parked while the playhead moves",
          .timeLimit(.minutes(2)))
    func landingSessionParksPastTheLanding() async throws {
        let fixture = MatroskaSubtitleFixture.make(
            durationMs: 130_000,
            events: [(ms: 50_000, durationMs: 1_000), (ms: 55_000, durationMs: 1_000),
                     (ms: 63_000, durationMs: 1_000), (ms: 90_000, durationMs: 1_000),
                     (ms: 120_000, durationMs: 1_000)])
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: fixture), formatHint: "matroska")
        defer { demuxer.close() }

        let store = SubtitlePacketStore()
        let playhead = Box(0.0)
        let reads = Box(0)
        let task = Task {
            await SubtitleForwardPrefetcher.run(
                demuxer: demuxer, store: store,
                streamIndices: [0], assemblyIndices: [],
                pacingIndex: -1,
                leadSeconds: 75, parkPollNanoseconds: 10_000_000,
                landingWindow: .init(behindSeconds: 15, aheadSeconds: 2),
                landing: 60,
                landingWindowRead: { reads.update { $0 + 1 } },
                playhead: { playhead.value })
        }
        defer { task.cancel() }

        // 63 s is the first packet past landing + 2: it is read, and the read parks behind it.
        try await waitFor { store.frontier(streamIndex: 0) == 63 && reads.value == 1 }
        // A read-ahead session would now follow the playhead to 90 and 120.
        playhead.set(200)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(store.frontier(streamIndex: 0) == 63,
                "a landing session must not follow the playhead (frontier=\(store.frontier(streamIndex: 0) ?? -1))")
        #expect(reads.value == 1, "the window is reported read once per landing")
        #expect(store.hasReadSpan(from: 55, through: 63),
                "the park position is claimed, not just the last coverage step below it")
    }

    // MARK: - Landing reconstruction

    @Test("a refused landing is reconstructed once its ground reads, and abandoned once out of reach")
    func landingGroundStep() {
        let read: (Double, Double) -> Bool = { _, _ in true }
        let unread: (Double, Double) -> Bool = { _, _ in false }
        #expect(AetherEngine.landingGroundStep(awaitingStart: 62, playhead: 63, isRead: unread) == .keepWaiting)
        #expect(AetherEngine.landingGroundStep(awaitingStart: 62, playhead: 63, isRead: read) == .reconstruct)
        #expect(AetherEngine.landingGroundStep(awaitingStart: 62, playhead: 61, isRead: read) == .abandon)
        #expect(AetherEngine.landingGroundStep(
            awaitingStart: 62, playhead: 62 + AetherEngine.subtitleDrainBackscanSeconds + 0.1,
            isRead: read) == .abandon)
    }

    @Test("a PGS line the landing could not prove comes back once the landing window is read",
          .timeLimit(.minutes(2)))
    func refusedLandingComesBack() async throws {
        let format = try #require(avformat_alloc_context())
        defer { avformat_free_context(format) }
        let stream = try #require(avformat_new_stream(format, nil))
        stream.pointee.time_base = AVRational(num: 1, den: 90_000)
        stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE

        let engine = try AetherEngine()
        defer { engine.clearSubtitle() }
        engine.loadedURL = URL(string: "https://example.invalid/movie.mkv")!
        let store = SubtitlePacketStore()
        engine.softwareSubtitlePacketStore = store
        engine.subtitleDrainDecoderFactoryForTesting = { index in
            index == 0 ? EmbeddedSubtitleDecoder(stream: stream, sourceVideoWidth: 1920,
                                                 sourceVideoHeight: 1080) : nil
        }
        func drain() async {
            engine.requestSubtitleDrainTick()
            while let pending = engine.subtitleDrainTickInFlight { await pending.value }
        }
        func onScreen(at time: Double) -> Bool {
            engine.subtitleCues.contains { $0.startTime <= time && $0.endTime > time }
        }

        // The pump re-opened at the landing and read the set that began a second before it, but
        // nothing read the ground between the two.
        store.noteHarvestAnchor(.pump, at: 63)
        store.harvestChunk(streamIndex: 0, ptsSeconds: 62, durationSeconds: 0, flags: 0,
                           payload: SecondaryBitmapSubtitleTests.displaySet(x: 100, luminance: 235),
                           assembleSplitDisplaySets: true)
        store.harvestChunk(streamIndex: 0, ptsSeconds: 65, durationSeconds: 0, flags: 0,
                           payload: SecondaryBitmapSubtitleTests.pcs(x: 100, state: 0, clear: true)
                               + SecondaryBitmapSubtitleTests.segment(0x80, []),
                           assembleSplitDisplaySets: true)
        engine.clock.sourceTime = 63.5
        engine.selectSubtitleTrack(index: 0)
        await drain()
        #expect(!onScreen(at: 63.5), "the unproven landing line is still refused")
        #expect(engine.subtitleLandingAwaitingGround[.primary] == 62)

        // The landing window reads the ground behind the landing.
        store.noteHarvestAnchor(.prefetch, at: 48)
        store.noteHarvestProgress(.prefetch, through: 65.5)
        await drain()
        #expect(onScreen(at: 63.5), "the landing line comes back once its ground is read")
        #expect(engine.subtitleLandingAwaitingGround[.primary] == nil)
    }

    // MARK: - Seek

    @Test("a set left open before a seek is closed at the departure, not drawn over the landing")
    func openSetClosedAtSeekDeparture() throws {
        let engine = try AetherEngine()
        let open = SubtitleCue(id: 1, startTime: 72, endTime: 72 + 4_294_967, body: .text("old"))
        let ahead = SubtitleCue(id: 2, startTime: 82, endTime: 82 + 4_294_967, body: .text("next"))
        engine.subtitleCues = [open, ahead]
        engine.closeOpenEndedSubtitleCues(atSeekFrom: 73.1, to: 79.4)
        #expect(engine.subtitleCues.first { $0.id == 1 }?.endTime == 73.1)
        #expect(engine.subtitleCues.first { $0.id == 2 }?.endTime == ahead.endTime,
                "a set after the landing is the reconstruction's to decide")
    }

    // Round 2 (retest on 7.63.0): closing at the landing claimed the whole jumped-over stretch.

    @Test("a set closed by a forward seek is not drawn when a later seek lands back inside the jump")
    func forwardSeekDoesNotClaimTheJumpedStretch() {
        var cues = [SubtitleCue(id: 1, startTime: 0, endTime: 4_294_967, body: .text("only set"))]
        #expect(AetherEngine.closeOpenEndedCues(&cues, seekFrom: 1.2, to: 58))
        #expect(cues[0].endTime == 1.2)
        #expect(!cues.contains { $0.startTime <= 54 && $0.endTime > 54 },
                "nothing covers the later landing at 54 s")
        #expect(!AetherEngine.closeOpenEndedCues(&cues, seekFrom: 58, to: 54),
                "once closed it is no longer open, and a later seek leaves it alone")
    }

    @Test("an open set the playhead never reached is closed at its own start on a forward seek")
    func unseenSetBeforeForwardLandingClosedAtItsStart() {
        var cues = [SubtitleCue(id: 1, startTime: 5, endTime: 5 + 4_294_967, body: .text("read ahead"))]
        #expect(AetherEngine.closeOpenEndedCues(&cues, seekFrom: 3, to: 50))
        #expect(cues[0].endTime == 5)
        #expect(!cues.contains { $0.startTime <= 35 && $0.endTime > 35 })
    }

    @Test("a backward seek keeps a set that was on screen at the departure over its own stretch")
    func backwardSeekKeepsTheSeenStretch() {
        var cues = [SubtitleCue(id: 1, startTime: 10, endTime: 10 + 4_294_967, body: .text("on screen")),
                    SubtitleCue(id: 2, startTime: 30, endTime: 30 + 4_294_967, body: .text("ahead"))]
        #expect(AetherEngine.closeOpenEndedCues(&cues, seekFrom: 20, to: 15))
        #expect(cues[0].endTime == 20, "its clear was still unread, so it lasted at least to 20 s")
        #expect(cues[1].endTime == 30 + 4_294_967, "a set ahead of a backward landing stays open")
    }

    @Test("an authored end and a departure without a frame are handled")
    func authoredEndAndNoDeparture() {
        var authored = [SubtitleCue(id: 1, startTime: 10, endTime: 14, body: .text("authored"))]
        #expect(!AetherEngine.closeOpenEndedCues(&authored, seekFrom: 12, to: 60))
        var cues = [SubtitleCue(id: 1, startTime: 72, endTime: 72 + 4_294_967, body: .text("old"))]
        #expect(AetherEngine.closeOpenEndedCues(&cues, seekFrom: .nan, to: 79.4))
        #expect(cues[0].endTime == 79.4, "no departure falls back to the landing")
    }

    @Test("the drain's jump after a seek does not resend the reader, a later seek's jump does")
    func seekRequestDedupesTheDrainJumpOfThatSeekOnly() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.subtitleTracks = [TrackInfo(id: 3, name: "PGS", codec: "hdmv_pgs_subtitle",
                                           language: "en", isDefault: false)]
        engine.subtitleDrainTargets[.primary] = 3
        engine.maximumSubtitleOffsetSeconds = 0
        let box = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorStreamIndex: 3, fallbackDuration: 150, seekTimeout: 1)
        engine.subtitleForwardPrefetchReanchor = box
        defer { engine.cancelSubtitleForwardPrefetcher(reason: .sessionStopped) }

        _ = engine.advanceSeekGeneration()
        engine.requestSubtitlePrefetchLanding(at: 79.4)
        #expect(box.take()?.seconds == 79.4)
        engine.startSubtitleForwardPrefetcher(startAt: 79.6)
        #expect(box.take() == nil, "the seek already sent the reader to this landing")

        // A later seek to nearly the same place, on a path that sends nothing with the seek: the
        // jump is all there is, and it must move the reader.
        _ = engine.advanceSeekGeneration()
        engine.startSubtitleForwardPrefetcher(startAt: 80.1)
        #expect(box.take()?.seconds == 80.1)
    }

    // MARK: - Engine gating

    @Test("zero reach keeps the prefetch alive for a bitmap track, in the landing role")
    func zeroReachKeepsLandingRoleForBitmap() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.subtitleTracks = [TrackInfo(id: 3, name: "PGS", codec: "hdmv_pgs_subtitle",
                                           language: "en", isDefault: false)]
        engine.subtitleDrainTargets[.primary] = 3
        #expect(engine.wantedSubtitleForwardPrefetchRole == .readAhead)
        engine.maximumSubtitleOffsetSeconds = 0
        #expect(engine.wantedSubtitleForwardPrefetchRole == .landingWindow)
        #expect(engine.subtitleForwardPrefetchActiveRole == .landingWindow)
        #expect(engine.subtitleForwardPrefetchTask != nil)
        engine.cancelSubtitleForwardPrefetcher(reason: .sessionStopped)
    }

    // MARK: - Helpers

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("condition not met within 20 s")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func set(_ value: T) {
        lock.lock(); stored = value; lock.unlock()
    }
    func update(_ change: (T) -> T) {
        lock.lock(); stored = change(stored); lock.unlock()
    }
}
