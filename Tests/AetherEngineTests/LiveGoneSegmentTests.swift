import Testing
import Foundation
@testable import AetherEngine

/// Audit HLS-204: a live segment that is still listed but no longer resident answers at once with a
/// 404 instead of parking 30 s and answering a retriable 503. Also pins the slice-11 note that a
/// missing segment must not be counted by `mediaSegmentURL` as well as by the serve path.
@Suite("Live segment gone from the window")
struct LiveGoneSegmentTests {

    private func makeLiveProvider(cache: SegmentCache) -> VideoSegmentProvider {
        let provider = VideoSegmentProvider(
            cache: cache, segments: [], codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 25.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000, isLive: true)
        for i in 0..<5 {
            provider.appendLiveSegment(index: i, startSeconds: Double(i) * 4, durationSeconds: 4)
        }
        return provider
    }

    @Test("an evicted listed index is served as gone, not parked")
    func evictedListedIndexIsGone() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let provider = makeLiveProvider(cache: cache)
        for i in [0, 1, 3] { cache.store(index: i, data: Data(repeating: 1, count: 8)) }

        #expect(provider.liveSegmentIsGone(2), "stored 3 proves 2 was produced and dropped")
        #expect(!provider.liveSegmentIsGone(3))
        #expect(!provider.liveSegmentIsGone(4), "above the stored front it can still arrive")

        let start = DispatchTime.now()
        let served = provider.mediaSegmentSource(at: 2, onSlow: nil)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(served == nil)
        #expect(elapsed < 10, "the old path waited the full 30 s forward-backpressure bound")

        #expect(HLSLocalServer.classifySegmentResponse(
            index: 2, segmentCount: 5, hasData: false, liveGone: true) == .notFound)
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 2, segmentCount: 5, hasData: false) == .retryLater)
    }

    @Test("a missing segment does not count as a media fetch twice")
    func missCountsOnce() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let provider = makeLiveProvider(cache: cache)
        for i in [0, 1, 3] { cache.store(index: i, data: Data(repeating: 1, count: 8)) }

        #expect(provider.mediaSegmentURL(at: 2) == nil)
        _ = provider.mediaSegmentSource(at: 2, onSlow: nil)
        #expect(provider.mediaFetchCount == 1, "URL probe plus serve path is one request, not two")
        #expect(provider.mediaSegmentURL(at: 3) != nil)
        #expect(provider.mediaFetchCount == 2)
    }
}
