import Foundation
import Testing
@testable import AetherEngine

@Suite("Live DVR resource contract", .timeLimit(.minutes(3)))
struct LiveDVRLimitsTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Double = 0
        var now: Double { lock.lock(); defer { lock.unlock() }; return instant }
        func advance(_ seconds: Double) { lock.lock(); instant += seconds; lock.unlock() }
    }

    @Test("capacity lifetime is caller-owned and missing deadlines deny history")
    func explicitCapacityLifetime() {
        let clock = Clock()
        let policy = LiveDVRRetentionPolicy(now: { clock.now })
        policy.update(.init(windowSeconds: 60, maximumBytes: 1024, minimumFreeBytes: 0),
                      availableBytes: 8192, residentBytes: 0)
        #expect(policy.snapshot?.retentionBytes == 0)
        policy.update(.init(windowSeconds: 60, maximumBytes: 1024, minimumFreeBytes: 0,
                            capacityValidUntil: 10), availableBytes: 8192, residentBytes: 0)
        clock.advance(5)
        #expect(policy.snapshot?.retentionBytes == 1024)
        clock.advance(6)
        #expect(policy.snapshot?.retentionBytes == 0)
    }

    @Test("unknown capacity denies history; overflow and explicit budgets remain finite")
    func capacityBounds() {
        let value = LiveDVRLimits(windowSeconds: .infinity, maximumBytes: .max, minimumFreeBytes: -1, capacityValidUntil: 3)
        #expect(value.windowSeconds == nil)
        #expect(value.maximumBytes == Int64.max)
        #expect(value.minimumFreeBytes == 0)
        #expect(value.retentionBytes(availableBytes: nil, residentBytes: .max) == 0)
        #expect(value.retentionBytes(availableBytes: .max, residentBytes: .max) == 0)
        let unlimited = LiveDVRLimits(windowSeconds: 7200, maximumBytes: .max, minimumFreeBytes: 0)
        #expect(unlimited.windowSeconds == 7200)
        #expect(unlimited.retentionBytes(availableBytes: .max, residentBytes: .max) == Int.max / 4 * 2)
        let fixed = LiveDVRLimits(windowSeconds: 2700, maximumBytes: 128 * 1024 * 1024,
                                       minimumFreeBytes: 256 * 1024 * 1024, capacityValidUntil: 3)
        #expect(fixed.retentionBytes(availableBytes: fixed.minimumFreeBytes - 1, residentBytes: 999) == 0)
        #expect(fixed.retentionBytes(availableBytes: fixed.minimumFreeBytes + 100, residentBytes: 50) == 150)
    }

    @Test("native expansion expires and renews without resetting the session timeline")
    func measurementLeaseAndRoute() {
        let clock = Clock()
        let policy = LiveDVRRetentionPolicy(now: { clock.now })
        #expect(policy.snapshot == nil)
        let limits = LiveDVRLimits(windowSeconds: 2700, maximumBytes: 512 * 1024 * 1024,
                                        minimumFreeBytes: 256 * 1024 * 1024, capacityValidUntil: 3)
        policy.update(limits, availableBytes: 2 * 1024 * 1024 * 1024, residentBytes: 0)
        var timeline = LiveWindow(windowSeconds: 85.9)
        timeline.noteEdge(100)
        timeline.noteResidentFloor(0)
        timeline.setWindowSeconds(policy.snapshot?.windowSeconds)
        #expect(timeline.seekableRange?.lowerBound == 0)
        clock.advance(3 + 0.001)
        #expect(policy.snapshot?.retentionBytes == 0)
        timeline.setWindowSeconds(policy.snapshot?.windowSeconds)
        #expect(timeline.seekableRange == nil)
        policy.update(limits, availableBytes: 2 * 1024 * 1024 * 1024, residentBytes: 0)
        #expect(policy.snapshot?.windowSeconds == nil, "Reusing an expired sample must not renew its lease")
        let renewed = LiveDVRLimits(windowSeconds: limits.windowSeconds,
                                   maximumBytes: limits.maximumBytes,
                                   minimumFreeBytes: limits.minimumFreeBytes,
                                   capacityValidUntil: clock.now + 3)
        policy.update(renewed, availableBytes: 2 * 1024 * 1024 * 1024, residentBytes: 0)
        #expect(policy.snapshot?.windowSeconds == 2700)
        timeline.setWindowSeconds(policy.snapshot?.windowSeconds)
        #expect(timeline.edgeTime == 100)
        #expect(timeline.seekableRange == 0...100)
    }

    @Test("delayed caller capacity expires at its original deadline without a subsequent probe")
    func delayedCapacityDeadline() {
        let clock = Clock()
        clock.advance(12.9)
        let policy = LiveDVRRetentionPolicy(now: { clock.now })
        let limits = LiveDVRLimits(windowSeconds: 2700, maximumBytes: 32 * 1024 * 1024,
                                        minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: 13)
        policy.update(limits, availableBytes: 1024 * 1024 * 1024, residentBytes: 0)
        let cache = SegmentCache(forwardWindow: 1, backwardWindow: 1, nativeLiveDVRPolicy: policy)
        defer { cache.close() }
        for index in 0..<20 { cache.store(index: index, data: Data(repeating: 1, count: 10)) }
        #expect(cache.count == 20)
        #expect(policy.snapshot?.windowSeconds == 2700)
        clock.advance(0.101)
        // No caller renewal/disable, playlist poll, source finalization or pending-probe completion.
        #expect(policy.snapshot?.windowSeconds == nil)
        #expect(policy.snapshot?.retentionBytes == 0)
        // The existing independent expiry timer invokes this exact cleanup path.
        #expect(cache.reconcileExpiredNativeLiveDVRRetention())
        #expect(cache.count == LiveWindowSizing.minSafeSegments)
        let invalid = LiveDVRLimits(windowSeconds: 2700, maximumBytes: 32 * 1024 * 1024,
                                         minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: .nan)
        policy.update(invalid, availableBytes: 1024 * 1024 * 1024, residentBytes: 0)
        #expect(policy.snapshot?.retentionBytes == 0)
    }

    @Test("retention keeps a playable suffix and bounds pinned overshoot, even without playlist polls")
    func finalizedPayloadBounds() {
        let policy = LiveDVRRetentionPolicy(now: { 0 })
        policy.update(LiveDVRLimits(windowSeconds: 2700, maximumBytes: 32 * 1024 * 1024,
                                         minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: 3),
                      availableBytes: 1024 * 1024 * 1024, residentBytes: 0)
        let cache = SegmentCache(forwardWindow: 1, backwardWindow: 1, nativeLiveDVRPolicy: policy)
        defer { cache.close() }
        cache.declareTarget(0)
        let payload = Data(repeating: 0xAA, count: 5 * 1024 * 1024)
        for index in 0..<20 { cache.store(index: index, data: payload) }
        // Eight newest segments + the finite consumer band; never all future entries.
        #expect(cache.count <= 10)
        #expect(cache.totalBytes <= max(32 * 1024 * 1024, cache.nativeLiveMandatoryBytes))
        #expect(cache.contiguousBackwardFloor(from: 19) == 12)
        cache.applyNativeLiveRetentionFloor(19)
        #expect(cache.peek(index: 19) != nil)
        #expect(cache.peek(index: 7) == nil)
    }

    @Test("time and byte tightening applies without discarding cache/session identity")
    func tightening() {
        let policy = LiveDVRRetentionPolicy(now: { 0 })
        let value = LiveDVRLimits(windowSeconds: 2700, maximumBytes: 32 * 1024 * 1024,
                                       minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: 3)
        policy.update(value, availableBytes: 1024 * 1024 * 1024, residentBytes: 0)
        let cache = SegmentCache(forwardWindow: 1, backwardWindow: 1, nativeLiveDVRPolicy: policy)
        defer { cache.close() }
        let identity = cache.sessionDir
        for index in 0..<20 { cache.store(index: index, data: Data(repeating: 1, count: 10)) }
        #expect(cache.count == 20)
        cache.applyNativeLiveRetentionFloor(15)
        #expect(cache.contiguousBackwardFloor(from: 19) == 12) // eight mandatory edge segments
        policy.update(value, availableBytes: nil, residentBytes: cache.totalBytes)
        cache.applyNativeLiveRetentionFloor(15)
        #expect(cache.sessionDir == identity)
        #expect(cache.count == LiveWindowSizing.minSafeSegments)
        #expect(policy.snapshot?.windowSeconds == nil)
    }
    @Test("playlist and producer cap grow in the same live session, then tighten to the actual suffix")
    func sharedProviderContract() {
        let policy = LiveDVRRetentionPolicy(now: { 0 })
        let initial = LiveDVRLimits(windowSeconds: 60, maximumBytes: 32 * 1024 * 1024,
                                         minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: 3)
        policy.update(initial, availableBytes: 1024 * 1024 * 1024, residentBytes: 0)
        let cache = SegmentCache(forwardWindow: 1, backwardWindow: 1, nativeLiveDVRPolicy: policy)
        defer { cache.close() }
        let provider = VideoSegmentProvider(cache: cache, segments: [], codecsString: "avc1.640028",
                                            supplementalCodecs: nil, resolution: (1920, 1080),
                                            videoRange: .sdr, frameRate: 25, hdcpLevel: nil,
                                            sourceBitrate: 1_000_000, isLive: true,
                                            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 4,
                                                                               dvrWindowSeconds: 60),
                                            nativeLiveDVRPolicy: policy)
        for index in 0..<10 {
            cache.store(index: index, data: Data(repeating: 1, count: 100))
            provider.appendLiveSegment(index: index, startSeconds: Double(index * 4), durationSeconds: 4)
        }
        #expect(provider.notePlaylistBuild().firstVisible == 0)
        let oldCap = provider.liveResidentParkCap()
        policy.update(LiveDVRLimits(windowSeconds: 2700, maximumBytes: 32 * 1024 * 1024,
                                         minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: 3),
                      availableBytes: 1024 * 1024 * 1024, residentBytes: cache.totalBytes)
        provider.applyNativeLiveDVRRetention()
        #expect(provider.liveResidentParkCap() > oldCap)
        #expect(provider.notePlaylistBuild().firstVisible == 0)
        for index in 10..<25 {
            cache.store(index: index, data: Data(repeating: 1, count: 100))
            provider.appendLiveSegment(index: index, startSeconds: Double(index * 4), durationSeconds: 4)
        }
        #expect(provider.residentFloorOutputSeconds() == 0)
        policy.update(LiveDVRLimits(windowSeconds: 16, maximumBytes: 32 * 1024 * 1024,
                                         minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: 3),
                      availableBytes: 1024 * 1024 * 1024, residentBytes: cache.totalBytes)
        provider.applyNativeLiveDVRRetention()
        #expect(provider.notePlaylistBuild().firstVisible == 17) // eight safe playback segments
        #expect(provider.residentFloorOutputSeconds() == 68)
    }

    @Test("expiry between the last finalized prune and headroom check cannot park on stale history")
    func expiryBeforeHeadroomAdmission() {
        let clock = Clock()
        let policy = LiveDVRRetentionPolicy(now: { clock.now })
        policy.update(LiveDVRLimits(windowSeconds: 2700, maximumBytes: 32 * 1024 * 1024,
                                         minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: 3),
                      availableBytes: 1024 * 1024 * 1024, residentBytes: 0)
        let cache = SegmentCache(forwardWindow: 1, backwardWindow: 1, nativeLiveDVRPolicy: policy)
        defer { cache.close() }
        let provider = VideoSegmentProvider(cache: cache, segments: [], codecsString: "avc1.640028",
                                            supplementalCodecs: nil, resolution: (1920, 1080),
                                            videoRange: .sdr, frameRate: 25, hdcpLevel: nil,
                                            sourceBitrate: 1_000_000, isLive: true,
                                            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 4,
                                                                               dvrWindowSeconds: 85.9),
                                            nativeLiveDVRPolicy: policy)
        for index in 0..<220 {
            cache.store(index: index, data: Data(repeating: 1, count: 100))
            provider.appendLiveSegment(index: index, startSeconds: Double(index * 4), durationSeconds: 4)
        }
        provider.applyNativeLiveDVRRetention() // the last real finalized-segment prune is still valid
        #expect(cache.count == 220)
        #expect(cache.count < max(180, provider.liveResidentParkCap()))
        clock.advance(3 + 0.001)
        // No new segment, playlist request or timer delivery intervenes. Use the exact cache
        // admission method called by both producer park checks, after computing the shrunken cap.
        let expiredCap = max(180, provider.liveResidentParkCap())
        #expect(cache.count >= expiredCap)
        #expect(cache.reconcileExpiredNativeLiveDVRRetention(headroomCap: expiredCap))
        #expect(cache.count == LiveWindowSizing.minSafeSegments)
        #expect(provider.residentFloorOutputSeconds() == Double((220 - 8) * 4))
        #expect(policy.snapshot?.windowSeconds == nil)
    }

    @Test("the production expiry timer reclaims idle paused history without source or consumer progress")
    func independentIdleExpiry() async throws {
        let clock = Clock()
        let policy = LiveDVRRetentionPolicy(now: { clock.now })
        policy.update(LiveDVRLimits(windowSeconds: 2700, maximumBytes: 32 * 1024 * 1024,
                                         minimumFreeBytes: 128 * 1024 * 1024, capacityValidUntil: 3),
                      availableBytes: 1024 * 1024 * 1024, residentBytes: 0)
        let expired = ProbeTestBox(false)
        let cache = SegmentCache(forwardWindow: 1, backwardWindow: 1, nativeLiveDVRPolicy: policy,
                                 onResidentSetChanged: {
                                     let instant = clock.now
                                     if instant > 3 && instant < 4 {
                                         expired.update { $0 = true }
                                     }
                                 })
        defer { cache.close() }
        for index in 0..<220 { cache.store(index: index, data: Data(repeating: 1, count: 100)) }
        #expect(cache.count == 220)
        cache.startNativeLiveDVRExpiryChecks() // the same timer armed by the engine's public setter
        cache.startNativeLiveDVRExpiryChecks() // idempotent; no second timer/resource owner
        clock.advance(3 + 0.001)
        // Only the actual DispatchSource callback can fulfill this observer. No direct prune,
        // headroom check, segment append or playlist build is made after expiry.
        try await waitFor { expired.value }
        #expect(cache.count == LiveWindowSizing.minSafeSegments)
        clock.advance(10) // exclude the ordinary close resident-set notification from the expectation
        cache.close()
        #expect(!cache.reconcileExpiredNativeLiveDVRRetention(headroomCap: 180))
        #expect(cache.count == 0) // a late queued handler cannot resurrect a closed cache
    }

}
