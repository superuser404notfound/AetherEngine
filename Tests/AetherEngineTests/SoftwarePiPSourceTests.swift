import Testing
import CoreMedia
@testable import AetherEngine

/// SW-PiP Phase A: the sample-buffer PiP UI needs the playable range on the PTS axis of the
/// enqueued frames, which is the SOURCE axis (sourceTime = currentTime + source offset).
@Suite("Software PiP time range")
struct SoftwarePiPSourceTests {
    @Test("VOD zero-based source: range starts at 0 for the full duration")
    func vodZeroBased() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, sourceTime: 12.0, currentTime: 12.0, duration: 3600)
        #expect(abs(r.start.seconds - 0) < 0.001)
        #expect(abs(r.duration.seconds - 3600) < 0.001)
    }

    @Test("VOD with source offset: range starts at the container start PTS")
    func vodWithOffset() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, sourceTime: 152.5, currentTime: 2.5, duration: 600)
        #expect(abs(r.start.seconds - 150.0) < 0.001)
        #expect(abs(r.duration.seconds - 600) < 0.001)
    }

    @Test("live: indefinite range")
    func liveIndefinite() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: true, sourceTime: 500, currentTime: 100, duration: 0)
        #expect(r.start == .negativeInfinity)
        #expect(r.duration == .positiveInfinity)
    }

    @Test("unknown duration falls back to indefinite")
    func unknownDurationIndefinite() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, sourceTime: 5, currentTime: 5, duration: 0)
        #expect(r.start == .negativeInfinity)
    }
}
