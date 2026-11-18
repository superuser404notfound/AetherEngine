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

    /// The tvOS stall: a bitmap-only file arms no pump tap, and subtitles-off used to empty the
    /// session's store list while the provider kept serving the old stores. The marker then silenced
    /// nothing, and every .vtt after a seek waited 3 s on a store no OCR worker fills.
    @Test("a marker after subtitles-off still silences the store the server reads",
          .timeLimit(.minutes(3)))
    func markerAfterClearSilencesServedStore() throws {
        let engine = try AetherEngine()
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae1052-pgs-only.mkv"))
        let served = NativeSubtitleCueStore()
        session.nativeSubtitleCueStoresForSession = [served]
        engine.nativeVideoSession = session
        defer { engine.nativeVideoSession = nil }
        #expect(!session.subtitleTapActive)

        engine.clearSubtitle()
        #expect(engine.nativeStore(atOrdinal: 0) === served)

        engine.setNativeSubtitleSelected(track: 0, markerOnly: true)
        #expect(served.servesSilently)
    }

    /// Reporter's follow-up: after a pick, AVKit fetched the previous marker's rendition once more
    /// before the new select landed, found it loud, and the request sat in the 3 s readiness wait
    /// on a store nothing fills. The outgoing marker stays silent until the select has landed.
    @Test("a marker left for another track or Off stays silent until the select lands",
          .timeLimit(.minutes(3)))
    func outgoingMarkerStaysSilentUntilSelectLands() throws {
        let engine = try AetherEngine()
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae1052-five-pgs.mkv"))
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        session.nativeSubtitleCueStoresForSession = stores
        engine.nativeVideoSession = session
        defer { engine.nativeVideoSession = nil }

        #expect(engine.silenceNativeRendition(ordinal: 0, displaying: nil).isEmpty)
        let toOther = engine.silenceNativeRendition(ordinal: 1, displaying: nil)
        #expect(toOther.count == 1 && toOther[0] === stores[0])
        #expect(stores[0].servesSilently && stores[1].servesSilently && !stores[2].servesSilently)

        let toOff = engine.silenceNativeRendition(ordinal: nil, displaying: nil)
        #expect(toOff.count == 2)
        #expect(stores[0].servesSilently && stores[1].servesSilently && !stores[2].servesSilently)
        AetherEngine.liftNativeSilence(toOff)
        #expect(!stores.contains { $0.servesSilently })
    }

    @Test("a marker that becomes its own display goes loud at once, so the first fetch has cues",
          .timeLimit(.minutes(3)))
    func markerBecomingDisplayLiftsAtOnce() throws {
        let engine = try AetherEngine()
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae1052-pip.mkv"))
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        session.nativeSubtitleCueStoresForSession = stores
        engine.nativeVideoSession = session
        defer { engine.nativeVideoSession = nil }

        _ = engine.silenceNativeRendition(ordinal: 1, displaying: nil)
        #expect(engine.silenceNativeRendition(ordinal: nil, displaying: 1).isEmpty)
        #expect(!stores[1].servesSilently)
    }

    @Test("with no player item, Off lifts the marker at once", .timeLimit(.minutes(3)))
    func offWithoutItemLiftsAtOnce() throws {
        let engine = try AetherEngine()
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae1052-no-item.mkv"))
        let store = NativeSubtitleCueStore()
        session.nativeSubtitleCueStoresForSession = [store]
        engine.nativeVideoSession = session
        defer { engine.nativeVideoSession = nil }

        engine.setNativeSubtitleSelected(track: 0, markerOnly: true)
        #expect(store.servesSilently)
        engine.setNativeSubtitleSelected(track: nil)
        #expect(!store.servesSilently)
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
