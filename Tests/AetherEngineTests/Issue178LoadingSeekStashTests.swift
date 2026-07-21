import Foundation
import Testing
@testable import AetherEngine

/// #178 mechanism 1 (YangHanqing): `seek(to:)` unconditionally no-oped while `state == .loading`,
/// silently discarding any seek issued in the multi-second initial-load window. Hosts that render
/// the target optimistically then watch playback snap back to the pre-seek position. The fix
/// stashes the latest loading-window seek in `pendingPreReadySeekSeconds` (the #127 slot) and
/// resolves it on the transition out of `.loading`: replay into a playable state, discard into a
/// terminal one. The `.loading` state itself is never left early (spinner hold, see #127 notes).
struct Issue178LoadingSeekStashTests {

    @MainActor
    @Test("a seek issued while load is in progress is stashed, not dropped")
    func loadingSeekStashes() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        await engine.seek(to: 42)
        #expect(engine.pendingPreReadySeekSeconds == 42)
        #expect(engine.state == .loading)          // spinner hold intact
        #expect(engine.clock.currentTime == 42)    // optimistic scrub clock follows the target
    }

    @MainActor
    @Test("the latest of several loading-window seeks wins")
    func loadingSeekLatestWins() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        await engine.seek(to: 42)
        await engine.seek(to: 97)
        #expect(engine.pendingPreReadySeekSeconds == 97)
    }

    @MainActor
    @Test("the stashed seek replays once loading settles into a playable state")
    func stashReplaysOnSettle() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        await engine.seek(to: 42)
        engine.state = .playing   // autostart path: timeControlStatus sink flips .loading -> .playing
        for _ in 0..<50 {
            if engine.pendingPreReadySeekSeconds == nil { break }
            await Task.yield()
        }
        #expect(engine.pendingPreReadySeekSeconds == nil)
        #expect(engine.clock.currentTime == 42)
    }

    @MainActor
    @Test("a load that dies discards the stash instead of leaking it into the next session")
    func stashDiscardedOnTerminalTransition() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        await engine.seek(to: 42)
        engine.state = .error("load failed")
        #expect(engine.pendingPreReadySeekSeconds == nil)
    }

    @Test("stash resolution: replay into playable, discard into terminal, hold otherwise")
    func stashResolutionPolicy() {
        #expect(AetherEngine.loadingStashResolution(oldState: .loading, newState: .playing) == .replay)
        #expect(AetherEngine.loadingStashResolution(oldState: .loading, newState: .paused) == .replay)
        #expect(AetherEngine.loadingStashResolution(oldState: .loading, newState: .idle) == .discard)
        #expect(AetherEngine.loadingStashResolution(oldState: .loading, newState: .ended) == .discard)
        #expect(AetherEngine.loadingStashResolution(oldState: .loading, newState: .error("x")) == .discard)
        #expect(AetherEngine.loadingStashResolution(oldState: .loading, newState: .loading) == .hold)
        // Non-loading transitions belong to the #127 readiness sink, not the loading resolver.
        #expect(AetherEngine.loadingStashResolution(oldState: .playing, newState: .paused) == .hold)
        #expect(AetherEngine.loadingStashResolution(oldState: .paused, newState: .idle) == .hold)
    }
}
