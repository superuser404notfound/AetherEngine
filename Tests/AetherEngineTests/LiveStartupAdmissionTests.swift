import Foundation
import Testing
@testable import AetherEngine

@Suite(.timeLimit(.minutes(3)), .offCooperativePool)
struct LiveStartupAdmissionTests {
    /// A parked job ends on an append or `cancelWaiters()`, never on its own deadline: past it the
    /// gate takes the undersized-cushion exit and returns true, which a test task resumed late
    /// read as an admission the policy never made (CI, 2026-10-08, with a 30 s deadline).
    private static let parkedJobTimeout: TimeInterval = 86_400

    private func provider(grace: Double? = nil, fast: Bool = true, singleSegmentMinimum: Double? = nil, holdbackFloor: Bool = false) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let provider = VideoSegmentProvider(cache: cache, segments: [],
            codecsString: "avc1.640029,mp4a.40.2", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 25,
            hdcpLevel: nil, sourceBitrate: 4_000_000, isLive: true,
            liveWindowSizing: .init(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: nil),
            allowsBoundedDegradedStart: fast, startupGraceSeconds: grace,
            singleSegmentStartupMinimumSeconds: singleSegmentMinimum, boundedStartFloorsAtHoldback: holdbackFloor,
            firstServeLatchCoversEngineCut: true)
        return (provider, cache)
    }

    private func append(_ provider: VideoSegmentProvider, _ index: Int) {
        provider.appendLiveSegment(index: index, startSeconds: Double(index * 10), durationSeconds: 10)
    }

    @Test("A later plain playlist refresh does not pay the startup grace again")
    func repeatedRequest() {
        let (provider, cache) = provider()
        defer { cache.close() }
        append(provider, 0); append(provider, 1)
        #expect(provider.waitForFirstLiveSegment(timeout: 5))
        let started = ContinuousClock.now
        #expect(provider.waitForFirstLiveSegment(timeout: 5))
        #expect(started.duration(to: .now) < .seconds(0.5))
        #expect(provider.sealedLiveTargetDurationSeconds == 15)
        provider.cancelWaiters()
        #expect(!provider.waitForFirstLiveSegment(timeout: 5), "cancellation wins over admission")
    }

    @Test("Zero grace admits two complete segments without weakening the advertised holdback")
    func zeroGrace() {
        let (provider, cache) = provider(grace: 0)
        defer { cache.close() }
        append(provider, 0); append(provider, 1)
        let started = ContinuousClock.now
        #expect(provider.waitForFirstLiveSegment(timeout: 5))
        #expect(started.duration(to: .now) < .seconds(0.5))
        #expect(provider.sealedLiveTargetDurationSeconds == 15)
        #expect(HLSLocalServer.buildMediaPlaylistText(provider: provider).contains("HOLD-BACK=45.000"))
    }

    @Test("An empty timed-out request does not latch admission")
    func emptyWindow() {
        let (provider, cache) = provider(grace: 0)
        defer { cache.close() }
        #expect(!provider.waitForFirstLiveSegment(timeout: 0))
        #expect(!provider.waitForFirstLiveSegment(timeout: 0))
        append(provider, 0); append(provider, 1)
        #expect(provider.waitForFirstLiveSegment(timeout: 1))
    }

    @Test("Zero grace still waits for the second segment")
    func minimumSegments() async throws {
        let (provider, cache) = provider(grace: 0)
        defer { provider.cancelWaiters(); cache.close() }
        append(provider, 0)
        let job = ProbeTestJob { provider.waitForFirstLiveSegment(timeout: Self.parkedJobTimeout) }
        try await waitFor { provider.parkedWaiterCount == 1 }
        #expect(!(try await waitFor(upTo: .milliseconds(100)) { job.isFinished }))
        append(provider, 1)
        #expect(try await job.outcome().get())
    }

    @Test("A grace override never bypasses standard joins")
    func standardJoin() async throws {
        let (provider, cache) = provider(grace: 0, fast: false)
        defer { provider.cancelWaiters(); cache.close() }
        append(provider, 0); append(provider, 1)
        let job = ProbeTestJob { provider.waitForFirstLiveSegment(timeout: Self.parkedJobTimeout) }
        try await waitFor { provider.parkedWaiterCount == 1 }
        #expect(!(try await waitFor(upTo: .milliseconds(100)) { job.isFinished }))
        provider.cancelWaiters()
        #expect(try await !job.outcome().get())
    }

    @Test("A caller may admit one sufficiently long completed segment without changing holdback")
    func longSingleSegment() {
        let (provider, cache) = provider(grace: 0, singleSegmentMinimum: 5)
        defer { provider.cancelWaiters(); cache.close() }
        append(provider, 0)
        let started = ContinuousClock.now
        #expect(provider.waitForFirstLiveSegment(timeout: 5))
        #expect(started.duration(to: .now) < .seconds(0.5))
        #expect(provider.sealedLiveTargetDurationSeconds == 15)
        #expect(HLSLocalServer.buildMediaPlaylistText(provider: provider).contains("HOLD-BACK=45.000"))
    }

    @Test("A short first segment still waits, even when single-segment startup is enabled")
    func shortSingleSegment() async throws {
        let (provider, cache) = provider(grace: 0, singleSegmentMinimum: 5)
        defer { provider.cancelWaiters(); cache.close() }
        provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 2)
        let job = ProbeTestJob { provider.waitForFirstLiveSegment(timeout: Self.parkedJobTimeout) }
        try await waitFor { provider.parkedWaiterCount == 1 }
        #expect(!(try await waitFor(upTo: .milliseconds(100)) { job.isFinished }))
        provider.appendLiveSegment(index: 1, startSeconds: 2, durationSeconds: 2)
        #expect(try await job.outcome().get())
    }

    @Test("An invalid threshold keeps the two-segment default", arguments: [0.0, -1.0, .infinity, .nan])
    func invalidSingleSegmentThreshold(_ threshold: Double) async throws {
        let (provider, cache) = provider(grace: 0, singleSegmentMinimum: threshold)
        defer { provider.cancelWaiters(); cache.close() }
        append(provider, 0)
        let job = ProbeTestJob { provider.waitForFirstLiveSegment(timeout: Self.parkedJobTimeout) }
        try await waitFor { provider.parkedWaiterCount == 1 }
        #expect(!(try await waitFor(upTo: .milliseconds(100)) { job.isFinished }))
        provider.cancelWaiters()
        #expect(try await !job.outcome().get())
    }

    @Test("A single-segment threshold does not bypass a standard join")
    func standardIgnoresSingleSegmentThreshold() async throws {
        let (provider, cache) = provider(grace: 0, fast: false, singleSegmentMinimum: 5)
        defer { provider.cancelWaiters(); cache.close() }
        append(provider, 0)
        let job = ProbeTestJob { provider.waitForFirstLiveSegment(timeout: Self.parkedJobTimeout) }
        try await waitFor { provider.parkedWaiterCount == 1 }
        #expect(!(try await waitFor(upTo: .milliseconds(100)) { job.isFinished }))
        provider.cancelWaiters()
        #expect(try await !job.outcome().get())
    }

    @Test("Single-segment admission still observes the configured grace")
    func singleSegmentGrace() {
        let (provider, cache) = provider(grace: 0.2, singleSegmentMinimum: 5)
        defer { provider.cancelWaiters(); cache.close() }
        append(provider, 0)
        let started = ContinuousClock.now
        #expect(provider.waitForFirstLiveSegment(timeout: 5))
        #expect(started.duration(to: .now) >= .milliseconds(190))
        provider.cancelWaiters()
        #expect(!provider.waitForFirstLiveSegment(timeout: 1))
    }

    @Test("Single-segment opt-in cannot bypass an explicit holdback floor")
    func singleSegmentRespectsHoldbackFloor() async throws {
        let (provider, cache) = provider(grace: 0, singleSegmentMinimum: 5, holdbackFloor: true)
        defer { provider.cancelWaiters(); cache.close() }
        append(provider, 0)
        let job = ProbeTestJob { provider.waitForFirstLiveSegment(timeout: Self.parkedJobTimeout) }
        try await waitFor { provider.parkedWaiterCount == 1 }
        #expect(!(try await waitFor(upTo: .milliseconds(100)) { job.isFinished }))
        provider.cancelWaiters()
        #expect(try await !job.outcome().get())
    }

}
