import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit HLS-104, HLS-105, SEG-104 (B): a producer the session has already replaced, or an action
/// scheduled on its behalf, used to act on whatever producer was current by then. A gate open from a
/// superseded restart rewrote the epoch table, the delayed #377 revive re-anchored the producer that
/// had replaced the dead one, and a re-cut lost its mark to the seek's 2 s wait while the restart it
/// marked was still running.
@Suite("A superseded producer leaves the current session alone", .serialized, .offCooperativePool)
struct SupersededProducerReportTests {

    private final class Session {
        let engine: HLSVideoEngine
        private var codecpar: UnsafeMutablePointer<AVCodecParameters>?
        private let cache = SegmentCache(forwardWindow: 20, backwardWindow: 20)

        init() throws {
            engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/superseded.mkv"),
                                    dvModeAvailable: false)
            codecpar = avcodec_parameters_alloc()
            codecpar!.pointee.codec_id = AV_CODEC_ID_H264
            codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            let plan = (0..<10).map { i in
                HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                       startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
            }
            engine.segmentPlan = plan
            engine.cache = cache
            engine.demuxer = Demuxer()
            engine.savedVideoConfig = .init(codecpar: UnsafePointer(codecpar!),
                                            timeBase: AVRational(num: 1, den: 1000),
                                            codecTagOverride: nil)
            engine.provider = VideoSegmentProvider(
                cache: cache, segments: plan, codecsString: "avc1.42C00A", supplementalCodecs: nil,
                resolution: (16, 16), videoRange: .sdr, frameRate: 2, hdcpLevel: nil,
                sourceBitrate: 100_000)
        }

        deinit {
            engine.stop()
            avcodec_parameters_free(&codecpar)
        }

        /// A stored segment that opens on no random-access point, so a seek into it has to re-cut.
        func storeWithoutSyncSample(_ index: Int) throws {
            let staging = cache.sessionDir.appendingPathComponent("staging-\(index).tmp")
            try Data(repeating: 0xAA, count: 64).write(to: staging)
            cache.adopt(index: index, stagingPath: staging, byteCount: 64, videoReach: SegmentCache.VideoReach.none)
        }

        /// The producer reports its gate open, as the pump does: the item-axis tfdt of its first frame
        /// is the start of the segment it was anchored at (plan time base 1/1000).
        func openGate(of producer: HLSSegmentProducer, at index: Int, backoffMs: Int64 = 3000) {
            producer.onVideoShiftKnown?(backoffMs, Int64(index) * 4000, 0)
        }
    }

    private final class Restarts: @unchecked Sendable {
        private let lock = NSLock()
        private var _began = 0
        func note(_ began: Bool) { if began { lock.withLock { _began += 1 } } }
        var began: Int { lock.withLock { _began } }
    }

    // MARK: - The gate open of a replaced producer (SEG-104 B)

    @Test("a gate open from a producer the session replaced records nothing")
    func supersededGateOpenRecordsNothing() throws {
        let session = try Session()
        let engine = session.engine
        let stale = try engine.makeProducer(baseIndex: 2)
        engine.producer = stale
        engine.producer = nil   // performRestart tears it down before building the next one

        session.openGate(of: stale, at: 2)
        #expect(engine.epochAxisByIndex.opening(at: 2) == nil,
                "the stale epoch dropped the table at and above its own index")

        let current = try engine.makeProducer(baseIndex: 5)
        engine.producer = current
        session.openGate(of: stale, at: 2)
        session.openGate(of: current, at: 5)
        #expect(engine.epochAxisByIndex.opening(at: 2) == nil)
        #expect(engine.epochAxisByIndex.opening(at: 5) != nil, "the installed producer's gate still records")
    }

    // MARK: - The re-cut mark (HLS-105)

    @Test("a re-cut whose gate opens after the seek stopped waiting is still recorded as a re-cut",
          .timeLimit(.minutes(3)))
    func lateRecutGateKeepsItsMark() async throws {
        let session = try Session()
        let engine = session.engine
        for i in 0...4 { try session.storeWithoutSyncSample(i) }

        // Nothing here ever opens a gate on its own, so the seek's wait runs out.
        let landing = await BlockingWork.detached { engine.preparedSeekLanding(itemSeconds: 14) }.value
        #expect(landing == 14)
        try await waitFor { engine.producer?.anchoredBaseIndex == 3 }
        let recut = try #require(engine.producer)

        session.openGate(of: recut, at: 3)
        #expect(engine.epochAxisByIndex.opening(at: 3)?.isRecut == true,
                "the late gate open composed the re-cut's backoff into the axis")
    }

    @Test("a mark belongs to the restart it asked for, not to whatever restart runs next")
    func markBindsOnlyItsOwnRestart() throws {
        let session = try Session()
        let engine = session.engine

        engine.markRecut(at: 3)
        engine.requestRestart(at: 6, authoritative: true)
        let other = try #require(engine.producer)
        session.openGate(of: other, at: 6)
        #expect(engine.epochAxisByIndex.opening(at: 6)?.isRecut == false)

        engine.requestRestart(at: 3, authoritative: true)
        let recut = try #require(engine.producer)
        engine.requestRestart(at: 7, authoritative: true)   // supersedes the re-cut before its gate opened
        let next = try #require(engine.producer)
        session.openGate(of: recut, at: 3)
        session.openGate(of: next, at: 7)
        #expect(engine.epochAxisByIndex.opening(at: 3) == nil)
        #expect(engine.epochAxisByIndex.opening(at: 7)?.isRecut == false)
    }

    @Test("the mark's lifecycle: bound by its own restart, kept past others, dropped once superseded")
    func recutMarkLifecycle() {
        let mark = HLSVideoEngine.RecutMark(index: 3)
        #expect(!mark.isOpened(byProducerEpoch: 7, at: 3), "unbound, no gate can claim it")

        let pending = mark.installing(producerEpoch: 5, at: 6)
        #expect(pending == mark, "a restart elsewhere ran first; the marked one is still to come")

        let bound = pending?.installing(producerEpoch: 7, at: 3)
        #expect(bound?.isOpened(byProducerEpoch: 7, at: 3) == true)
        #expect(bound?.isOpened(byProducerEpoch: 5, at: 3) == false)
        #expect(bound?.installing(producerEpoch: 8, at: 3)?.isOpened(byProducerEpoch: 8, at: 3) == true,
                "a second restart at the same index re-cuts the same landing")
        #expect(bound?.installing(producerEpoch: 9, at: 6) == nil)
    }

    // MARK: - The delayed #377 revive (HLS-104)

    @Test("the metered revive is owed only while its session and its dead producer are both still current")
    func meteredReviveOwedMatrix() {
        #expect(HLSVideoEngine.meteredReviveStillOwed(sessionUnchanged: true, deadProducerInstalled: true))
        #expect(!HLSVideoEngine.meteredReviveStillOwed(sessionUnchanged: true, deadProducerInstalled: false))
        #expect(!HLSVideoEngine.meteredReviveStillOwed(sessionUnchanged: false, deadProducerInstalled: true))
        #expect(!HLSVideoEngine.meteredReviveStillOwed(sessionUnchanged: false, deadProducerInstalled: false))
    }

    @Test("a revive that woke after another restart replaced its dead producer restarts nothing",
          .timeLimit(.minutes(3)))
    func meteredReviveYieldsToAReplacement() async throws {
        let session = try Session()
        let engine = session.engine
        let restarts = Restarts()
        engine.onSeekStateChanged = { began, _ in restarts.note(began) }
        let dead = try engine.makeProducer(baseIndex: 2)
        engine.producer = dead
        dead.start()
        try await waitFor { dead.didFinish }
        let epoch = engine.sessionEpochSnapshot()

        // A segment-driven restart during the backoff already put a working producer in.
        engine.producer = try engine.makeProducer(baseIndex: 6)
        engine.fireMeteredRevive(at: 2, deadProducer: dead, sessionEpoch: epoch)
        #expect(restarts.began == 0, "the revive re-anchored the producer that replaced the dead one")

        // Its own dead producer still in place, it runs.
        engine.producer = dead
        engine.fireMeteredRevive(at: 2, deadProducer: dead, sessionEpoch: epoch)
        #expect(restarts.began == 1)
    }
}
