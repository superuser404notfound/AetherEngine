import Foundation
import Testing
@testable import AetherEngine

/// #93 stage-2 reload: the recovery item reload swaps AVPlayerItems, and legible selection is
/// per-item, so an active native subtitle rendition silently disappeared (worst in PiP, where
/// the native rendition is the only subtitle path). The engine remembers the last requested
/// ordinal so the reload can re-apply it; selecting nil (deselect) clears the memory so a
/// reload never resurrects subtitles the user turned off.
@MainActor
struct NativeSubtitleReapplyTests {

    @Test("the last requested native ordinal is remembered; deselect clears it")
    func remembersRequestedOrdinal() throws {
        let engine = try AetherEngine()
        #expect(engine.nativeSubtitleReapplyOrdinal == nil)
        engine.setNativeSubtitleSelected(track: 2)
        #expect(engine.nativeSubtitleReapplyOrdinal == 2)
        engine.setNativeSubtitleSelected(track: 0)
        #expect(engine.nativeSubtitleReapplyOrdinal == 0)
        engine.setNativeSubtitleSelected(track: nil)
        #expect(engine.nativeSubtitleReapplyOrdinal == nil)
    }
}

/// #93 PiP skips: AVKit-side seeks (PiP +-15s buttons) never pass through the engine's seek API,
/// so the native subtitle readers kept reading FORWARD from the old region while the playhead
/// jumped far back; AVKit's selection burst then fetched empty .vtt windows for the new region
/// and cached them forever (#32). A settled far jump outside reader coverage with an active
/// rendition re-anchors the readers and replays the selection (whose deselect/reselect busts
/// the cached empties).
@MainActor
struct NativeSubtitleReanchorTests {

    @Test("a jump qualifies only at the threshold distance, in both directions")
    func jumpDecision() {
        #expect(!AetherEngine.isSubtitleReanchorJump(from: 100, to: 130))
        #expect(!AetherEngine.isSubtitleReanchorJump(from: 100, to: 159.9))
        #expect(AetherEngine.isSubtitleReanchorJump(from: 100, to: 160))
        #expect(AetherEngine.isSubtitleReanchorJump(from: 1693, to: 1333))
        #expect(AetherEngine.isSubtitleReanchorJump(from: 100, to: 900))
    }

    @Test("coverage spans reader anchor to readMax plus catch-up slack; no readers = uncovered")
    func coverageDecision() {
        // Device shape: readers anchored at 1691.5, read to 1725.9, playhead jumped to 1333.
        #expect(!AetherEngine.nativeSubtitleReadersCover(
            position: 1333, coverageStart: 1691.5, readMax: 1725.9))
        // Inside the read span.
        #expect(AetherEngine.nativeSubtitleReadersCover(
            position: 1700, coverageStart: 1691.5, readMax: 1725.9))
        // Slightly ahead of readMax: the parked reader catches up on its own.
        #expect(AetherEngine.nativeSubtitleReadersCover(
            position: 1780, coverageStart: 1691.5, readMax: 1725.9))
        // Far ahead of readMax: sequential catch-up over WAN is worse than a re-anchor.
        #expect(!AetherEngine.nativeSubtitleReadersCover(
            position: 2400, coverageStart: 1691.5, readMax: 1725.9))
        // No readers running.
        #expect(!AetherEngine.nativeSubtitleReadersCover(
            position: 1700, coverageStart: nil, readMax: 0))
    }
}
