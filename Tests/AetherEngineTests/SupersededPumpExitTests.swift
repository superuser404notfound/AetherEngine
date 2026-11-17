import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit HLS-1: a producer the session already replaced (the #79 wedge abort, or `stop()`)
/// reports its aborted read as a read error. That exit must not reach the session's recovery
/// arms: no revive-gate spend, no seek-state or failure signal to the host.
@Suite("Superseded pump exit")
struct SupersededPumpExitTests {
    @Test("host retry preserves the session and coalesces before stop revokes it")
    func retainedRecoveryCanResumeWithoutReplacingCache() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/live.ts"),
            dvModeAvailable: false, isLiveSession: true)
        let producer = try makeProducer(codecpar: codecpar!)
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 4)
        engine.producer = producer
        engine.cache = cache
        let calls = Recorder()
        engine.onLiveSourceReopening = { calls.seek() }
        #expect(!engine.retryLiveSourceRecovery(), "unrelated source loss cannot masquerade as retained replay")
        engine.liveRecoveryHasVerifiedReplay = true
        engine.barrenReopenCycles = 3
        let provider = VideoSegmentProvider(
            cache: cache, segments: [], codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 25.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000, isLive: true)
        engine.provider = provider
        let runningRetry = engine.retryLiveSourceRecovery()
        #expect(runningRetry, "a retry on a session that is not parked coalesces as a success")
        #expect(calls.seekSignals == 0, "audit HLS-202: and does not touch the running producer")
        #expect(engine.liveRecoveryProducer == nil)
        provider.markLiveProductionHalted()
        #expect(engine.retryLiveSourceRecovery())
        #expect(engine.retryLiveSourceRecovery())
        #expect(calls.seekSignals == 1, "duplicate calls cannot launch another source connection")
        #expect(engine.cache === cache)
        #expect(engine.producer === producer)
        #expect(engine.barrenReopenCycles == 0)
        #expect(engine.liveRecoveryProducer === producer)
        engine.stop()
        #expect(!engine.retryLiveSourceRecovery(), "a stopped session cannot reopen")
        #expect(engine.liveRecoveryProducer == nil)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _failures = 0
        private var _seekSignals = 0
        var failures: Int { lock.lock(); defer { lock.unlock() }; return _failures }
        var seekSignals: Int { lock.lock(); defer { lock.unlock() }; return _seekSignals }
        func fail() { lock.lock(); _failures += 1; lock.unlock() }
        func seek() { lock.lock(); _seekSignals += 1; lock.unlock() }
    }

    private func makeProducer(codecpar: UnsafeMutablePointer<AVCodecParameters>) throws -> HLSSegmentProducer {
        HLSSegmentProducer(
            demuxer: Demuxer(),
            videoStreamIndex: 0,
            video: .init(codecpar: UnsafePointer(codecpar),
                         timeBase: AVRational(num: 1, den: 90_000),
                         codecTagOverride: nil),
            cache: SegmentCache(forwardWindow: 4, backwardWindow: 4),
            videoFallbackDurationPts: 3_000,
            desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [0, 540_000]
        )
    }

    private func makeEngine(_ recorder: Recorder) -> HLSVideoEngine {
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/superseded.mkv"),
                                    dvModeAvailable: false)
        engine.onVODSourceFailed = { _, _, _ in recorder.fail() }
        engine.onSeekStateChanged = { _, _ in recorder.seek() }
        return engine
    }

    @Test("a read error from a replaced producer spends nothing and signals nothing")
    func supersededReadErrorIsIgnored() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO

        let recorder = Recorder()
        let engine = makeEngine(recorder)
        let stale = try makeProducer(codecpar: codecpar!)
        let current = try makeProducer(codecpar: codecpar!)
        engine.producer = current

        engine.handlePumpFinished(stale, reason: .readError(code: -1))
        engine.producer = nil
        engine.handlePumpFinished(stale, reason: .readError(code: -1))

        #expect(engine.readErrorReviveGate.attempts == 0)
        #expect(!engine.mainDemuxerSuspectDead)
        #expect(recorder.failures == 0)
        #expect(recorder.seekSignals == 0)
    }

    @Test("a replay exit retunes only the current producer, never a superseded channel")
    func replayExitRequiresCurrentProducer() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        let recorder = Recorder()
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/live.ts"),
                                    dvModeAvailable: false, isLiveSession: true, sourceReopenableByURL: false)
        engine.onLiveSourceReset = { recorder.fail() }
        let stale = try makeProducer(codecpar: codecpar!)
        let current = try makeProducer(codecpar: codecpar!)
        engine.producer = current
        engine.handlePumpFinished(stale, reason: .sourceReplay)
        #expect(recorder.failures == 0)
        engine.handlePumpFinished(current, reason: .sourceReplay)
        #expect(recorder.failures == 1, "the current session still requests fresh negotiation")
        engine.producer = nil
        engine.handlePumpFinished(current, reason: .sourceReplay)
        #expect(recorder.failures == 1, "a torn-down session cannot retune its successor")
    }

    @Test("verified replay exhaustion cannot silently request a reload that loses its history")
    func replayExhaustionHasSeparateHostEvidence() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        let resets = Recorder(), rejected = Recorder()
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/live.ts"),
            dvModeAvailable: false, isLiveSession: true, sourceReopenableByURL: false)
        engine.onLiveSourceReset = { resets.fail() }
        engine.onLiveSourceReplayExhausted = { rejected.fail() }
        let producer = try makeProducer(codecpar: codecpar!)
        engine.producer = producer
        engine.handlePumpFinished(producer, reason: .sourceReplay)
        #expect(rejected.failures == 1)
        #expect(resets.failures == 0)
        engine.producer = nil
        engine.handlePumpFinished(producer, reason: .sourceReplay)
        #expect(rejected.failures == 1, "a retired source cannot fail its successor")

        engine.liveRecoveryHasVerifiedReplay = true
        engine.escalateLiveReopenExhaustion(transport: .url)
        #expect(rejected.failures == 2, "an open failure after verified replay must not bypass history either")
        #expect(resets.failures == 0)
        engine.escalateLiveReopenExhaustion(transport: .url, replayRejected: false)
        #expect(resets.failures == 1, "a changed track layout still requests fresh negotiation")
    }

    @Test("without a host that owns the retry, exhausted replay is a source reset")
    func replayExhaustionFallsBackToSourceReset() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        let resets = Recorder()
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/live.ts"),
            dvModeAvailable: false, isLiveSession: true, sourceReopenableByURL: false)
        engine.onLiveSourceReset = { resets.fail() }
        let producer = try makeProducer(codecpar: codecpar!)
        engine.producer = producer
        engine.handlePumpFinished(producer, reason: .sourceReplay)
        #expect(resets.failures == 1, "a host that only knows liveSourceReset must still be told to retune")
        engine.liveRecoveryHasVerifiedReplay = true
        engine.escalateLiveReopenExhaustion(transport: .url)
        #expect(resets.failures == 2)
    }

    @Test("the same read error from the session's own producer still reaches the recovery arms")
    func currentReadErrorIsHandled() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO

        let recorder = Recorder()
        let engine = makeEngine(recorder)
        let current = try makeProducer(codecpar: codecpar!)
        engine.producer = current

        engine.handlePumpFinished(current, reason: .readError(code: -1))

        #expect(recorder.failures == 1)
    }
}
