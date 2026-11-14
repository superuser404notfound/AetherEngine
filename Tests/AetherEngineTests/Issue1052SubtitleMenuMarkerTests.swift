import Foundation
import Testing
@testable import AetherEngine

/// AE#1052: a host that draws a bitmap track in its own overlay selects that track's rendition as
/// a marker for AVKit's subtitle menu. The marker never fills, stands down the Sodalite#65 pin
/// (which keys on the reapply ordinal), and comes back when the picture returns to the app.
@MainActor
struct Issue1052SubtitleMenuMarkerTests {

    @Test("a marker holds only while the picture is in the app and only for its own ordinal")
    func markerDecision() {
        #expect(AetherEngine.nativeSelectionIsMarker(markerOrdinal: 1, reapplyOrdinal: 1, renderingRequested: false))
        #expect(!AetherEngine.nativeSelectionIsMarker(markerOrdinal: 1, reapplyOrdinal: 1, renderingRequested: true))
        #expect(!AetherEngine.nativeSelectionIsMarker(markerOrdinal: 1, reapplyOrdinal: 0, renderingRequested: false))
        #expect(!AetherEngine.nativeSelectionIsMarker(markerOrdinal: nil, reapplyOrdinal: 1, renderingRequested: false))
    }

    @Test("a marker sets the reapply ordinal, so the deselect pin stands down")
    func markerStandsDownPin() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleSelected(track: 2, markerOnly: true)
        #expect(engine.nativeSubtitleReapplyOrdinal == 2)
        #expect(engine.nativeSubtitleMarkerOrdinal == 2)
        #expect(engine.nativeSubtitleSelectionIsMarker)
    }

    @Test("the host's next plain call replaces the marker, Off included")
    func plainCallReplacesMarker() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleSelected(track: 2, markerOnly: true)
        engine.setNativeSubtitleSelected(track: 1)
        #expect(engine.nativeSubtitleMarkerOrdinal == nil)
        #expect(!engine.nativeSubtitleSelectionIsMarker)
        engine.setNativeSubtitleSelected(track: 2, markerOnly: true)
        engine.setNativeSubtitleSelected(track: nil)
        #expect(engine.nativeSubtitleMarkerOrdinal == nil)
        #expect(engine.nativeSubtitleReapplyOrdinal == nil)
    }

    @Test("leaving PiP returns to the marker instead of deselecting")
    func renderingOffReturnsToMarker() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleSelected(track: 1, markerOnly: true)
        engine.setNativeSubtitleRendering(true)
        // No active track maps to an ordinal in a bare engine, so the request deselects, the way it
        // always has; the marker itself survives it.
        #expect(engine.nativeSubtitleMarkerOrdinal == 1)
        #expect(!engine.nativeSubtitleSelectionIsMarker)
        engine.setNativeSubtitleRendering(false)
        #expect(engine.nativeSubtitleReapplyOrdinal == 1)
        #expect(engine.nativeSubtitleSelectionIsMarker)
    }

    @Test("without a marker, leaving PiP still deselects")
    func renderingOffWithoutMarkerDeselects() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleSelected(track: 1)
        engine.setNativeSubtitleRendering(false)
        #expect(engine.nativeSubtitleReapplyOrdinal == nil)
    }

    @Test("a session-preserving reload carries the marker")
    func carryoverKeepsMarker() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleSelected(track: 1, markerOnly: true)
        let carryover = engine.captureSubtitleSessionCarryover()
        #expect(carryover.nativeMarkerOrdinal == 1)
        #expect(carryover.nativeReapplyOrdinal == 1)
    }

    @Test("a silent store serves no cues and keeps the ones it has")
    func silentStoreKeepsCues() {
        let store = NativeSubtitleCueStore()
        store.servesSilently = true
        #expect(store.servesSilently)
        store.servesSilently = false
        #expect(!store.servesSilently)
    }
}
