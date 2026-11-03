import Testing
import Foundation
@testable import AetherEngine

/// Sodalite#175 spike: every stop that released the audio session paused the OTHER engine within
/// 10 ms (4 of 4 on an Apple TV). The coordinator is the one place that knows whether anyone is left.
@Suite("Shared output coordinator (Sodalite#175)")
@MainActor
struct SharedOutputCoordinatorTests {

    private final class Token {}
    // Held, not temporary: an ObjectIdentifier of a freed object can be reused by the next allocation.
    private let tokenA = Token()
    private let tokenB = Token()
    private var a: ObjectIdentifier { ObjectIdentifier(tokenA) }
    private var b: ObjectIdentifier { ObjectIdentifier(tokenB) }

    @Test("a lone engine leaving is last out and releases as it did before")
    func loneLeaveReleases() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        #expect(c.leave(a, releasesSession: true) == .lastOut(releaseSession: true))
        #expect(c.isEmpty)
    }

    @Test("leaving while another engine plays keeps the session")
    func leaveWithOthersRemainingKeepsSession() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .secondary, tag: "tile2")
        #expect(c.leave(b, releasesSession: true) == .othersRemain(1))
        #expect(!c.isEmpty)
    }

    @Test("an opt-in from an earlier leaver is owed to the last one out")
    func releaseOwedToLastOut() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .secondary, tag: "tile2")
        _ = c.leave(a, releasesSession: true)
        #expect(c.leave(b, releasesSession: false) == .lastOut(releaseSession: true))
    }

    @Test("the flag at leave time counts, not the one at join")
    func releaseFlagAtLeaveCounts() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        #expect(c.leave(a, releasesSession: false) == .lastOut(releaseSession: false))
    }

    @Test("the owed release does not survive into the next round")
    func owedReleaseResetsWhenEmpty() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        _ = c.leave(a, releasesSession: true)
        c.join(b, role: .primary, tag: nil)
        #expect(c.leave(b, releasesSession: false) == .lastOut(releaseSession: false))
    }

    @Test("leaving twice, or without joining, does nothing")
    func leaveOfNonMemberIsInert() {
        let c = SharedOutputCoordinator()
        #expect(c.leave(a, releasesSession: true) == .notMember)
        c.join(a, role: .primary, tag: nil)
        _ = c.leave(a, releasesSession: true)
        #expect(c.leave(a, releasesSession: true) == .notMember)
    }

    @Test("joining twice is one membership")
    func joinIsIdempotent() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        c.join(a, role: .primary, tag: nil)
        #expect(c.leave(a, releasesSession: true) == .lastOut(releaseSession: true))
    }

    @Test("the preferred channel count is the widest source, so a stereo tile cannot downmix 5.1")
    func channelsAreMax() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .secondary, tag: "tile2")
        #expect(c.preferredSourceChannels == nil)
        c.noteSourceChannels(6, for: a)
        c.noteSourceChannels(2, for: b)
        #expect(c.preferredSourceChannels == 6)
        _ = c.leave(a, releasesSession: true)
        #expect(c.preferredSourceChannels == 2)
    }

    @Test("channels noted for a non-member are ignored")
    func channelsOfNonMemberIgnored() {
        let c = SharedOutputCoordinator()
        c.noteSourceChannels(8, for: a)
        #expect(c.preferredSourceChannels == nil)
    }

    @Test("a deferred criteria reset runs when the last engine leaves")
    func deferredResetRunsOnLastOut() {
        let c = SharedOutputCoordinator()
        var resets = 0
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .secondary, tag: "tile2")
        #expect(c.othersActive(besides: a))
        _ = c.leave(a, releasesSession: true)
        c.deferCriteriaReset(for: a) { resets += 1 }
        #expect(resets == 0)
        _ = c.leave(b, releasesSession: true)
        #expect(resets == 1)
    }

    @Test("an engine that loads again cancels its own deferred reset")
    func rejoinCancelsDeferredReset() {
        let c = SharedOutputCoordinator()
        var resets = 0
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .secondary, tag: "tile2")
        _ = c.leave(a, releasesSession: true)
        c.deferCriteriaReset(for: a) { resets += 1 }
        c.join(a, role: .primary, tag: nil)
        _ = c.leave(b, releasesSession: true)
        #expect(resets == 0)
    }

    @Test("a secondary rejoin keeps the deferred reset")
    func secondaryRejoinKeepsDeferredReset() {
        let c = SharedOutputCoordinator()
        var resets = 0
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .primary, tag: nil)
        _ = c.leave(a, releasesSession: true)
        c.deferCriteriaReset(for: a) { resets += 1 }
        c.join(a, role: .secondary, tag: nil)
        _ = c.leave(b, releasesSession: true)
        #expect(resets == 0)
        _ = c.leave(a, releasesSession: true)
        #expect(resets == 1)
    }

    @Test("a reset deferred when nobody else is playing runs at once instead of leaking into a later round")
    func deferWithNobodyLeftRunsImmediately() {
        let c = SharedOutputCoordinator()
        var resets = 0
        c.join(a, role: .primary, tag: nil)
        _ = c.leave(a, releasesSession: true)
        c.deferCriteriaReset(for: a) { resets += 1 }
        #expect(resets == 1)
        c.join(b, role: .primary, tag: nil)
        _ = c.leave(b, releasesSession: true)
        #expect(resets == 1)
    }

    private actor Journal {
        private(set) var entries: [String] = []
        func note(_ entry: String) { entries.append(entry) }
    }

    @Test("transitions from any engine run in the order they were asked for")
    func transitionsAreOrderedAcrossEngines() async {
        let c = SharedOutputCoordinator()
        let journal = Journal()
        _ = c.enqueueTransition {
            try? await Task.sleep(for: .milliseconds(100)) // hygiene: allow one-shot delay inside the transition under test, not a wait
            await journal.note("activation by A")
        }
        let release = c.enqueueTransition { await journal.note("release by B") }
        await release.value
        #expect(await journal.entries == ["activation by A", "release by B"])
    }

    // Nonisolated probe: LeaveOutcome must be usable from a nonisolated context (Task 3 needs this)
    @Test("LeaveOutcome is usable from nonisolated context")
    func leaveOutcomeIsUsableNonisolated() {
        #expect(Self.isRelease(.lastOut(releaseSession: true)))
        #expect(!Self.isRelease(.lastOut(releaseSession: false)))
        #expect(!Self.isRelease(.notMember))
        #expect(!Self.isRelease(.othersRemain(2)))
    }

    nonisolated static func isRelease(_ o: SharedOutputCoordinator.LeaveOutcome) -> Bool {
        o == .lastOut(releaseSession: true)
    }

    @Test("an engine released without stop() no longer holds the session for everyone else")
    func releasedOwnerIsPruned() {
        let c = SharedOutputCoordinator()
        var dropped: Token? = Token()
        let droppedID = ObjectIdentifier(dropped!)
        c.join(droppedID, role: .secondary, tag: "tile2", owner: dropped)
        c.join(a, role: .primary, tag: nil, owner: tokenA)
        dropped = nil
        #expect(!c.othersActive(besides: a))
        #expect(c.leave(a, releasesSession: true) == .lastOut(releaseSession: true))
    }

    @Test("a member joined without an owner is never pruned")
    func ownerlessMemberStays() {
        let c = SharedOutputCoordinator()
        c.join(a, role: .primary, tag: nil)
        c.join(b, role: .secondary, tag: "tile2")
        #expect(c.leave(a, releasesSession: true) == .othersRemain(1))
    }
    private actor ConfigurationProbe {
        var calls = 0
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func run(hold: Bool = false) async {
            calls += 1
            if hold {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    waiting = true
                }
            }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("concurrent category requests share work, and a success is never repeated", .timeLimit(.minutes(3)))
    func categoryRequestsCoalesceOnce() async throws {
        let coordinator = SharedOutputCoordinator()
        let probe = ConfigurationProbe()
        let first = Task { await coordinator.configureAudioSessionCategory { await probe.run(hold: true); return true } }
        try await waitFor { await probe.waiting }
        var joined = false
        let second = Task {
            joined = true
            await coordinator.configureAudioSessionCategory { await probe.run(); return true }
        }
        try await waitFor { joined }
        await probe.release()
        await first.value
        await second.value
        #expect(await probe.calls == 1)
        // A host that changed the mode since (music on `.default`) must not be overwritten by the next load.
        await coordinator.configureAudioSessionCategory { await probe.run(); return true }
        #expect(await probe.calls == 1)
    }

    @Test("a failed category declaration is retried by the next load", .timeLimit(.minutes(3)))
    func categoryFailureRetries() async {
        let coordinator = SharedOutputCoordinator()
        let probe = ConfigurationProbe()
        await coordinator.configureAudioSessionCategory { await probe.run(); return false }
        await coordinator.configureAudioSessionCategory { await probe.run(); return true }
        await coordinator.configureAudioSessionCategory { await probe.run(); return true }
        #expect(await probe.calls == 2)
    }

    @Test("the category declaration waits behind a pending release", .timeLimit(.minutes(3)))
    func categoryWaitsForPendingTransition() async throws {
        let coordinator = SharedOutputCoordinator()
        let probe = ConfigurationProbe()
        let release = coordinator.enqueueTransition { await probe.run(hold: true) }
        try await waitFor { await probe.waiting }
        let configure = Task { await coordinator.configureAudioSessionCategory { await probe.run(); return true } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.calls == 1)
        await probe.release()
        await release.value
        await configure.value
        #expect(await probe.calls == 2)
    }

    @Test("renderer activation belongs to the host when disabled", .timeLimit(.minutes(3)))
    func rendererActivationOwnership() async throws {
        let engine = try AetherEngine()
        let probe = ConfigurationProbe()
        #expect(engine.rendererAudioSessionActivationEnabled)
        engine.rendererAudioSessionActivationEnabled = false
        await engine.performRendererAudioSessionActivation { await probe.run() }
        #expect(await probe.calls == 0)
        engine.rendererAudioSessionActivationEnabled = true
        await engine.performRendererAudioSessionActivation { await probe.run() }
        #expect(await probe.calls == 1)
    }

}
