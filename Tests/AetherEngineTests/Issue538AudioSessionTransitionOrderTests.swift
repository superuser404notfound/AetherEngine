import Testing
import Foundation
@testable import AetherEngine

/// AE#538 moved the renderer activation off the main actor, next to the #215 release that already ran
/// there. While the activation was synchronous on the main actor a `stop()` could not land inside it, so
/// the release always came after it. Two detached tasks have no such order: a stop during a software or
/// audio-only load's activation could send `setActive(false)` first and leave the session active after a
/// final teardown, which is the passthrough ring #215 exists to close. Both now go through one queue.
/// The session itself cannot be driven on macOS, so these tests lock the queue the two calls share.
@Suite("Audio session activation and release keep their order off the main actor (AE#538)")
struct Issue538AudioSessionTransitionOrderTests {

    private actor Journal {
        private(set) var entries: [String] = []
        func note(_ entry: String) { entries.append(entry) }
    }

    @MainActor
    @Test("A release asked for while an activation is still running lands after it")
    func releaseWaitsForRunningActivation() async throws {
        let engine = try AetherEngine()
        let journal = Journal()

        let activation = engine.enqueueAudioSessionTransition {
            await journal.note("activation begins")
            try? await Task.sleep(for: .milliseconds(100)) // hygiene: allow one-shot delay inside the transition under test, not a wait
            await journal.note("activation ends")
        }
        let release = engine.enqueueAudioSessionTransition {
            await journal.note("release")
        }
        await release.value
        await activation.value

        #expect(await journal.entries == ["activation begins", "activation ends", "release"])
    }

    @MainActor
    @Test("A cancelled release keeps its place, so the activation of the load that cancelled it runs last")
    func cancelledReleaseStillHoldsItsPlace() async throws {
        let engine = try AetherEngine()
        let journal = Journal()

        _ = engine.enqueueAudioSessionTransition {
            try? await Task.sleep(for: .milliseconds(100)) // hygiene: allow one-shot delay inside the transition under test, not a wait
            await journal.note("previous activation")
        }
        let release = engine.enqueueAudioSessionTransition {
            await journal.note(Task.isCancelled ? "release dropped" : "release")
        }
        release.cancel()   // stopInternal of the load that follows the stop
        let activation = engine.enqueueAudioSessionTransition {
            await journal.note("activation")
        }
        await activation.value

        #expect(await journal.entries == ["previous activation", "release dropped", "activation"])
    }
}
