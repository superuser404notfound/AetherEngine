import Foundation
import Testing
@testable import AetherEngine

/// AE#1141: a host following AVKit's subtitle menu reads an empty legible selection both while the
/// engine fills a rendition before selecting it and when the viewer picks Off. The published state
/// tells the two apart, and says when a pick was refused.
@MainActor
struct Issue1141NativeSubtitleSelectionStateTests {

    @Test("an empty selection means Off only while idle or selected", .timeLimit(.minutes(3)))
    func emptySelectionRule() {
        #expect(NativeSubtitleSelectionState.idle.emptySelectionMeansOff)
        #expect(NativeSubtitleSelectionState.selected(ordinal: 0).emptySelectionMeansOff)
        #expect(!NativeSubtitleSelectionState.preparing(ordinal: 0).emptySelectionMeansOff)
        #expect(!NativeSubtitleSelectionState.refused(ordinal: 0).emptySelectionMeansOff)
        #expect(NativeSubtitleSelectionState.idle.ordinal == nil)
        #expect(NativeSubtitleSelectionState.refused(ordinal: 3).ordinal == 3)
    }

    @Test("a select that lands reads selected, one that does not reads refused", .timeLimit(.minutes(3)))
    func afterSelect() {
        #expect(AetherEngine.nativeSelectionStateAfterSelect(ordinal: 2, landed: true) == .selected(ordinal: 2))
        #expect(AetherEngine.nativeSelectionStateAfterSelect(ordinal: 2, landed: false) == .refused(ordinal: 2))
    }

    @Test("a pick with no item to land on is refused, and nil goes back to idle", .timeLimit(.minutes(3)))
    func noItemRefuses() throws {
        let engine = try AetherEngine()
        #expect(engine.nativeSubtitleSelectionState == .idle)
        engine.setNativeSubtitleSelected(track: 1)
        #expect(engine.nativeSubtitleSelectionState == .refused(ordinal: 1))
        engine.setNativeSubtitleSelected(track: nil)
        #expect(engine.nativeSubtitleSelectionState == .idle)
        engine.setNativeSubtitleSelected(track: 0, markerOnly: true)
        #expect(engine.nativeSubtitleSelectionState == .refused(ordinal: 0))
    }

    @Test("stop resets to idle", .timeLimit(.minutes(3)))
    func stopResets() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleSelected(track: 1)
        engine.stop()
        #expect(engine.nativeSubtitleSelectionState == .idle)
    }

    /// The reload's own stop wiped the pick and its replay comes only after the rebuilt item is up.
    /// Idle in between would read the rebuilt item's empty selection as Off.
    @Test("a reload carrying a pick reads preparing through its stop", .timeLimit(.minutes(3)))
    func reloadCarry() throws {
        let engine = try AetherEngine()
        let previous = engine.beginNativeSubtitleSelectionCarry(2)
        #expect(previous == nil)
        engine.stop()
        #expect(engine.nativeSubtitleSelectionState == .preparing(ordinal: 2))
        engine.endNativeSubtitleSelectionCarry(restoring: previous)
        #expect(engine.nativeSubtitleSelectionCarry == nil)
        #expect(engine.nativeSubtitleSelectionState == .idle)
    }

    @Test("a replay that ran keeps its own state when the carry ends", .timeLimit(.minutes(3)))
    func carryEndKeepsReplay() throws {
        let engine = try AetherEngine()
        let previous = engine.beginNativeSubtitleSelectionCarry(1)
        engine.stop()
        // No item in a unit test, so the replay is refused, which is a state of its own.
        engine.setNativeSubtitleSelected(track: 1)
        engine.endNativeSubtitleSelectionCarry(restoring: previous)
        #expect(engine.nativeSubtitleSelectionState == .refused(ordinal: 1))
    }

    @Test("a nested reload hands the outer carry back", .timeLimit(.minutes(3)))
    func nestedCarry() throws {
        let engine = try AetherEngine()
        let outer = engine.beginNativeSubtitleSelectionCarry(3)
        let inner = engine.beginNativeSubtitleSelectionCarry(nil)
        #expect(inner == 3)
        engine.stop()
        #expect(engine.nativeSubtitleSelectionState == .preparing(ordinal: 3))
        engine.endNativeSubtitleSelectionCarry(restoring: inner)
        #expect(engine.nativeSubtitleSelectionState == .preparing(ordinal: 3))
        engine.endNativeSubtitleSelectionCarry(restoring: outer)
        #expect(engine.nativeSubtitleSelectionState == .idle)
    }

    @Test("stop moves the generation, so a select from the old session writes nothing", .timeLimit(.minutes(3)))
    func resetDropsStaleSelect() throws {
        let engine = try AetherEngine()
        let stale = engine.nativeSubtitleSelectGeneration
        engine.stop()
        #expect(engine.nativeSubtitleSelectGeneration != stale)
        engine.publishNativeSubtitleSelectionState(.refused(ordinal: 1), generation: stale)
        #expect(engine.nativeSubtitleSelectionState == .idle)
    }

    /// Review finding: a refused or preparing pick has nothing on the item, so the deselect branch of
    /// `clearSubtitle()` never ran for it and the state stayed where Off is ignored.
    @Test("subtitles off while the rendition is the display ends a refused pick", .timeLimit(.minutes(3)))
    func offEndsRefusedPick() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleRendering(true)
        engine.setNativeSubtitleSelected(track: 1)
        #expect(engine.nativeSubtitleSelectionState == .refused(ordinal: 1))
        let generation = engine.nativeSubtitleSelectGeneration
        engine.clearSubtitle()
        #expect(engine.nativeSubtitleSelectionState == .idle)
        #expect(engine.nativeSubtitleSelectGeneration != generation)
    }

    /// Review finding: the off supersedes the select that would have lifted an outgoing marker's
    /// silence, so the off lifts it.
    @Test("subtitles off lifts a silence the superseded select handed back", .timeLimit(.minutes(3)))
    func offLiftsPendingSilence() throws {
        let engine = try AetherEngine()
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae1141.mkv"))
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        session.nativeSubtitleCueStoresForSession = stores
        engine.nativeVideoSession = session
        defer { engine.nativeVideoSession = nil }
        engine.setNativeSubtitleRendering(true)
        engine.setNativeSubtitleSelected(track: 1)
        stores[0].servesSilently = true   // the old marker, still waiting for its lift
        engine.clearSubtitle()
        #expect(!stores.contains { $0.servesSilently })
    }

    @Test("an in-app selection is left alone by subtitles off", .timeLimit(.minutes(3)))
    func offInAppKeepsState() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleSelected(track: 0)
        let generation = engine.nativeSubtitleSelectGeneration
        engine.clearSubtitle()
        #expect(engine.nativeSubtitleSelectGeneration == generation)
    }
}
