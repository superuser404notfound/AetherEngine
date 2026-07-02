import Testing
import Foundation
@testable import AetherEngine

/// AetherEngine#88: registry semantics for external subtitle tracks. IDs are synthetic
/// (base + registration ordinal, monotonic per load), tracks appear in subtitleTracks, and
/// removal cleans registry + list + an active selection.
@MainActor
struct ExternalSubtitleRegistryTests {

    private func makeTrack(_ name: String = "x", lang: String? = "de") -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(string: "https://s/\(name).srt")!, name: name, language: lang)
    }

    @Test("add assigns base-offset monotonic ids and appends to subtitleTracks")
    func addAssignsIDs() throws {
        let engine = try AetherEngine()
        let a = engine.addExternalSubtitleTrack(makeTrack("a"))
        let b = engine.addExternalSubtitleTrack(makeTrack("b"))
        #expect(a.id == AetherEngine.externalSubtitleTrackIDBase)
        #expect(b.id == AetherEngine.externalSubtitleTrackIDBase + 1)
        #expect(engine.subtitleTracks.map(\.id) == [a.id, b.id])
        #expect(engine.subtitleTracks.allSatisfy { $0.isExternal })
        #expect(engine.externalSubtitleRegistry.count == 2)
    }

    @Test("remove delists the track and drops the registry entry; ordinals are not reused")
    func removeDelists() throws {
        let engine = try AetherEngine()
        let a = engine.addExternalSubtitleTrack(makeTrack("a"))
        _ = engine.addExternalSubtitleTrack(makeTrack("b"))
        engine.removeExternalSubtitleTrack(id: a.id)
        #expect(engine.subtitleTracks.count == 1)
        #expect(engine.externalSubtitleRegistry[a.id] == nil)
        let c = engine.addExternalSubtitleTrack(makeTrack("c"))
        #expect(c.id == AetherEngine.externalSubtitleTrackIDBase + 2)
    }

    @Test("removing the ACTIVE external track clears the primary subtitle")
    func removeActiveClears() throws {
        let engine = try AetherEngine()
        let a = engine.addExternalSubtitleTrack(makeTrack("a"))
        engine.isSubtitleActive = true
        engine.activeSubtitleTrackIndex = a.id
        engine.removeExternalSubtitleTrack(id: a.id)
        #expect(!engine.isSubtitleActive)
        #expect(engine.activeSubtitleTrackIndex == nil)
    }

    @Test("removing an embedded id no-ops")
    func removeEmbeddedNoop() throws {
        let engine = try AetherEngine()
        _ = engine.addExternalSubtitleTrack(makeTrack("a"))
        engine.removeExternalSubtitleTrack(id: 3)
        #expect(engine.subtitleTracks.count == 1)
    }

    @Test("stop clears the registry and resets ordinals")
    func stopClears() throws {
        let engine = try AetherEngine()
        _ = engine.addExternalSubtitleTrack(makeTrack("a"))
        engine.stop()
        #expect(engine.externalSubtitleRegistry.isEmpty)
        #expect(engine.subtitleTracks.isEmpty)
        let b = engine.addExternalSubtitleTrack(makeTrack("b"))
        #expect(b.id == AetherEngine.externalSubtitleTrackIDBase)
    }

    @Test("LoadOptions carries external declarations")
    func loadOptionsField() {
        let opts = LoadOptions(externalSubtitles: [makeTrack("a")])
        #expect(opts.externalSubtitles.count == 1)
    }
}
