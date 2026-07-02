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
