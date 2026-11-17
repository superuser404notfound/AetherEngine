import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit HLS-2: a live reopen that slept through a zap must not open the old channel.
@Suite("Live reopen after teardown")
struct LiveReopenAfterTeardownTests {

    @Test("a reopen demuxer is only registered while the failed producer is still the session's")
    func registrationRequiresCurrentProducer() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/live.ts"),
                                    dvModeAvailable: false)
        let failed = HLSSegmentProducer(
            demuxer: Demuxer(), videoStreamIndex: 0,
            video: .init(codecpar: UnsafePointer(codecpar!),
                         timeBase: AVRational(num: 1, den: 90_000), codecTagOverride: nil),
            cache: SegmentCache(forwardWindow: 4, backwardWindow: 4),
            videoFallbackDurationPts: 3_000, desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [0, 540_000])

        engine.producer = failed
        #expect(engine.registerReopenDemuxer(Demuxer(), failedProducer: failed))
        engine.stop()
        #expect(!engine.registerReopenDemuxer(Demuxer(), failedProducer: failed),
                "after stop() the reopen must not register (and so must not open)")
    }

    private final class CountingReader: IOReader, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        private var _position = 0
        private var _cancels = 0
        var cancels: Int { lock.withLock { _cancels } }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            lock.lock(); _reads += 1; lock.unlock()
            guard let buffer else { return 0 }
            return lock.withLock {
                let bytes = TinyTransportStreamFixture.data
                let count = min(Int(size), bytes.count - _position)
                guard count > 0 else { return 0 }
                bytes.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress! + _position, count) }
                _position += count
                return Int32(count)
            }
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        func cancel() { lock.withLock { _cancels += 1 } }
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    @Test("a demuxer marked closed before its open never touches the source")
    func markClosedBeforeOpenAbortsTheOpen() {
        let demuxer = Demuxer()
        let reader = CountingReader()
        demuxer.markClosed()
        #expect(throws: DemuxerError.self) {
            try demuxer.open(reader: reader, formatHint: "mpegts", isLive: true)
        }
        #expect(reader.reads == 0)
    }
    @Test("source retirement cancels the old reader while preserving codec parameters")
    func retirementReleasesOwnedReaderBeforeReplacement() throws {
        let reader = CountingReader()
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts", isLive: true)
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        let video = HLSSegmentProducer.StreamConfig(codecpar: UnsafePointer(stream.pointee.codecpar),
            timeBase: stream.pointee.time_base, codecTagOverride: "avc1")
        let cache = SegmentCache(forwardWindow: 4, backwardWindow: 4)
        let producer = HLSSegmentProducer(demuxer: demuxer, videoStreamIndex: index,
            video: video, cache: cache, videoFallbackDurationPts: 45_000,
            desiredFirstVideoTfdtPts: 0, segmentBoundaries: [], isLive: true)
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/live.ts"),
            dvModeAvailable: false, isLiveSession: true)
        engine.demuxer = demuxer
        engine.producer = producer
        engine.videoStreamIndex = index
        engine.savedVideoConfig = video
        defer { engine.stop(); cache.close() }

        #expect(reader.cancels == 0)
        #expect(engine.retireLiveSourceConnection(failedProducer: producer))
        #expect(reader.cancels == 1, "the old owned source must release its connection before reopening")
        #expect(demuxer.stream(at: index) != nil, "muxer configuration stays alive until the validated swap")

        let fresh = Demuxer()
        defer { fresh.close() }
        try fresh.open(reader: CountingReader(), formatHint: "mpegts", isLive: true)
        #expect(engine.reopenedTrackLayoutMatches(fresh, failedProducer: producer))
        let freshStream = try #require(fresh.stream(at: fresh.videoStreamIndex))
        freshStream.pointee.time_base.den += 1
        #expect(!engine.reopenedTrackLayoutMatches(fresh, failedProducer: producer),
                "a changed clock must be renegotiated, not spliced using saved muxer parameters")
        freshStream.pointee.time_base = video.timeBase
        freshStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_HEVC
        #expect(!engine.reopenedTrackLayoutMatches(fresh, failedProducer: producer))
        engine.producer = nil
        #expect(!engine.retireLiveSourceConnection(failedProducer: producer))
        #expect(reader.cancels == 1, "a superseded callback must not retire another source")
    }

}
