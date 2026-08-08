import Testing
@testable import AetherEngine

/// #334: a settled carriage verdict is conclusive on its own, so it must not wait for a readiness
/// anchor that a source AVFoundation can build no track for never reaches.
@Suite("Carriage verdict acts without readiness (#334)")
struct SettledCarriageEvidenceTests {

    @Test("a settled HEVC-in-MPEG-TS verdict reroutes on its own")
    func settledVerdictFires() {
        #expect(RemoteHLSIngestFallback.shouldRerouteOnSettledEvidence(
            carriageEvidence: .transportStreamHEVC, videoTrackCount: 0,
            armed: true, alreadyRejected: false))
    }

    @Test("evidence that is not positive never reroutes")
    func onlyPositiveEvidenceFires() {
        #expect(RemoteHLSIngestFallback.shouldRerouteOnSettledEvidence(
            carriageEvidence: .pending, videoTrackCount: 0,
            armed: true, alreadyRejected: false) == false)
        #expect(RemoteHLSIngestFallback.shouldRerouteOnSettledEvidence(
            carriageEvidence: .nativeCapable, videoTrackCount: 0,
            armed: true, alreadyRejected: false) == false)
    }

    /// A built track is the source itself contradicting the probe, and reality outranks the probe.
    @Test("a video track that exists outranks the verdict")
    func existingTrackOutranksVerdict() {
        #expect(RemoteHLSIngestFallback.shouldRerouteOnSettledEvidence(
            carriageEvidence: .transportStreamHEVC, videoTrackCount: 1,
            armed: true, alreadyRejected: false) == false)
    }

    @Test("a session that never armed the fallback is left alone")
    func unarmedSessionIsLeftAlone() {
        #expect(RemoteHLSIngestFallback.shouldRerouteOnSettledEvidence(
            carriageEvidence: .transportStreamHEVC, videoTrackCount: 0,
            armed: false, alreadyRejected: false) == false)
    }

    @Test("the reroute is one-shot: a verdict republished after it does not fire again")
    func rejectionIsOneShot() {
        #expect(RemoteHLSIngestFallback.shouldRerouteOnSettledEvidence(
            carriageEvidence: .transportStreamHEVC, videoTrackCount: 0,
            armed: true, alreadyRejected: true) == false)
    }
}

/// #334: the bypass had no terminal state. A source that serves every segment but produces no track
/// leaves AVPlayer neither failing nor becoming ready, so `state` stayed `.loading` forever.
@Suite("Bypass readiness deadline (#334)")
struct RemoteHLSReadinessDeadlineTests {

    @Test("budget in seconds becomes whole ticks")
    func budgetConvertsToTicks() {
        #expect(RemoteHLSReadinessDeadline(budgetSeconds: 45, tickSeconds: 0.5).budgetTicks == 90)
    }

    @Test("readiness disarms it, which is the common case")
    func readinessDisarms() {
        var deadline = RemoteHLSReadinessDeadline(budgetSeconds: 2, tickSeconds: 0.5)
        #expect(deadline.tick(isReady: true, carriageRerouted: false, hasFailed: false) == .disarm)
    }

    @Test("a carriage reroute disarms it: that session is being rebuilt elsewhere")
    func rerouteDisarms() {
        var deadline = RemoteHLSReadinessDeadline(budgetSeconds: 2, tickSeconds: 0.5)
        #expect(deadline.tick(isReady: false, carriageRerouted: true, hasFailed: false) == .disarm)
    }

    @Test("an AVPlayer failure already published a terminal state; do not publish a second one")
    func existingFailureDisarms() {
        var deadline = RemoteHLSReadinessDeadline(budgetSeconds: 2, tickSeconds: 0.5)
        #expect(deadline.tick(isReady: false, carriageRerouted: false, hasFailed: true) == .disarm)
    }

    @Test("it waits out the whole budget before failing")
    func failsOnlyAfterTheFullBudget() {
        var deadline = RemoteHLSReadinessDeadline(budgetSeconds: 2, tickSeconds: 0.5)   // 4 ticks
        #expect(deadline.tick(isReady: false, carriageRerouted: false, hasFailed: false) == .keepWaiting)
        #expect(deadline.tick(isReady: false, carriageRerouted: false, hasFailed: false) == .keepWaiting)
        #expect(deadline.tick(isReady: false, carriageRerouted: false, hasFailed: false) == .keepWaiting)
        #expect(deadline.tick(isReady: false, carriageRerouted: false, hasFailed: false) == .fail)
    }

    /// A source that becomes ready late still cancels the deadline: the budget is a ceiling on
    /// silence, not on how long a slow origin may take.
    @Test("readiness on the last tick still wins over the expiry")
    func lateReadinessStillDisarms() {
        var deadline = RemoteHLSReadinessDeadline(budgetSeconds: 1.5, tickSeconds: 0.5)  // 3 ticks
        _ = deadline.tick(isReady: false, carriageRerouted: false, hasFailed: false)
        _ = deadline.tick(isReady: false, carriageRerouted: false, hasFailed: false)
        #expect(deadline.tick(isReady: true, carriageRerouted: false, hasFailed: false) == .disarm)
    }

    @MainActor
    @Test("the budget the bypass ships with clears the deferred probe's own ceiling")
    func shippedBudgetOutlastsTheDeferredProbe() {
        // The deferred segment-head probe waits 400 x 0.05 s for readiness and then reads the head
        // anyway; failing the session before that verdict can arrive would defeat it.
        let probeCeiling = Double(NativeAVPlayerHost.carriageProbeReadinessTicks)
            * NativeAVPlayerHost.carriageProbeReadinessTickSeconds
        #expect(RemoteHLSReadinessDeadline.defaultBudgetSeconds > probeCeiling + 10)
    }
}
