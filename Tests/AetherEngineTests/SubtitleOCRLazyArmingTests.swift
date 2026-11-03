import Testing
import Foundation
@testable import AetherEngine

// The OCR worker, and the 270 s prefetch lead that comes with it, follow the NATIVE selection
// (PiP / AirPlay / external display), not the overlay selection. Measured on a 4K remux before this:
// 434 MB of prefetch in 90 s with the OCR armed at selection, 17 MB without.
@Suite("Subtitle OCR armed on native selection only", .serialized)
struct SubtitleOCRLazyArmingTests {

    @MainActor
    private func engineWithBitmapTrack() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: 3, language: "ger"),
            .init(sourceStreamIndex: 4, language: "ger", isForced: true, needsOCR: true),
        ]
        engine.testHookInstallNativeStores([NativeSubtitleCueStore(), NativeSubtitleCueStore()])
        engine.activeEmbeddedSubtitleStreamIndex = 4
        return engine
    }

    @MainActor
    @Test("selecting the bitmap rendition arms the worker, deselecting disarms it")
    func armsAndDisarmsWithNativeSelection() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        #expect(engine.subtitleOCRArmedOrdinal == nil)
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        #expect(engine.subtitleOCRArmedOrdinal == 1)
        engine.syncSubtitleOCRWithNativeSelection(ordinal: nil)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @MainActor
    @Test("a text rendition never arms the worker and disarms a bitmap one")
    func textRenditionDisarms() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 0)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @MainActor
    @Test("a bitmap rendition that is not the active overlay track does not arm")
    func otherBitmapTrackDoesNotArm() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        engine.activeEmbeddedSubtitleStreamIndex = 7
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        #expect(engine.subtitleOCRArmedOrdinal == nil)
    }

    @MainActor
    @Test("re-selecting the armed ordinal keeps the running worker")
    func reselectKeepsWorker() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        let task = engine.subtitleOCRWorkerTask
        engine.syncSubtitleOCRWithNativeSelection(ordinal: 1)
        #expect(engine.subtitleOCRWorkerTask != nil)
        #expect(engine.subtitleOCRWorkerTask == task)
    }

    @Test("the window counts as covered only when read and fully decoded")
    func coverageRule() {
        #expect(AetherEngine.subtitleOCRWindowCovered(harvestRead: true, undecodedPackets: 0))
        #expect(!AetherEngine.subtitleOCRWindowCovered(harvestRead: false, undecodedPackets: 0))
        #expect(!AetherEngine.subtitleOCRWindowCovered(harvestRead: true, undecodedPackets: 2))
    }

    // AE#955: a host re-asserting its pick next to `setNativeSubtitleRendering(true)` restarted the
    // worker on every call, and a restart with a batch in flight drops that batch's cursor, so the
    // pre-fill gate waited on coverage that kept being thrown away.
    @Test("re-picking the armed track keeps the worker, any other pick re-arms")
    func rePickKeepsTheWorker() {
        #expect(AetherEngine.subtitleOCRWorkerSurvivesPick(armedOrdinal: 1, pickedOrdinal: 1, pickIsEmbedded: true))
        #expect(!AetherEngine.subtitleOCRWorkerSurvivesPick(armedOrdinal: 1, pickedOrdinal: 0, pickIsEmbedded: true))
        #expect(!AetherEngine.subtitleOCRWorkerSurvivesPick(armedOrdinal: nil, pickedOrdinal: 1, pickIsEmbedded: true))
        #expect(!AetherEngine.subtitleOCRWorkerSurvivesPick(armedOrdinal: 1, pickedOrdinal: nil, pickIsEmbedded: true))
        // An external .sup shares no worker with an embedded track, whatever its ordinal says.
        #expect(!AetherEngine.subtitleOCRWorkerSurvivesPick(armedOrdinal: 1, pickedOrdinal: 1, pickIsEmbedded: false))
    }

    // AE#955: a host that never asks left the receiver with its rendition pinned off.
    @Test("a wireless receiver raises the rendering request the host did not, and withdraws only its own")
    func airPlayImpliesRendering() {
        #expect(AetherEngine.airPlayImpliedRenderingAction(wirelessActive: true, hostRequested: false, impliedByEngine: false) == true)
        #expect(AetherEngine.airPlayImpliedRenderingAction(wirelessActive: true, hostRequested: true, impliedByEngine: false) == nil)
        #expect(AetherEngine.airPlayImpliedRenderingAction(wirelessActive: false, hostRequested: true, impliedByEngine: true) == false)
        // The host's own request outlives the receiver; it takes it down itself.
        #expect(AetherEngine.airPlayImpliedRenderingAction(wirelessActive: false, hostRequested: true, impliedByEngine: false) == nil)
        #expect(AetherEngine.airPlayImpliedRenderingAction(wirelessActive: false, hostRequested: false, impliedByEngine: false) == nil)
        // The remote-HLS bypass has no rendition of ours; a request there would deselect the origin's.
        #expect(AetherEngine.airPlayImpliedRenderingAction(wirelessActive: true, servesOwnRenditions: false, hostRequested: false, impliedByEngine: false) == nil)
    }

    @MainActor
    @Test("any host call takes the request over from the engine")
    func hostCallOwnsTheRequest() throws {
        let engine = try engineWithBitmapTrack()
        defer { engine.cancelSubtitleOCRWorker() }
        engine.nativeRenderingImpliedByAirPlay = true
        engine.setNativeSubtitleRendering(true)
        #expect(!engine.nativeRenderingImpliedByAirPlay)
        #expect(engine.nativeSubtitleRenderingRequested)
    }
}
