import Foundation
import Testing
@testable import AetherEngine

/// AetherEngine#170: the AirPlay LAN-swap reload (and any other engine-initiated
/// `reloadAtCurrentPosition`) is a from-scratch `load()` that rebuilt the session from
/// `LoadOptions` alone, destroying session state the host accumulated since load:
/// mid-session `addExternalSubtitleTrack` registrations, the explicit audio/subtitle
/// selection (including subtitles explicitly OFF), and `nativeSubtitleReapplyOrdinal`.
/// The fix snapshots a `SubtitleSessionCarryover` before the reload, seeds the fresh
/// session's registry id-exactly, and restores the selection instead of re-running
/// preferred-language auto-selection.
@MainActor
struct Issue170CarryoverCaptureTests {

    private static let base = AetherEngine.externalSubtitleTrackIDBase

    private func makeTrack(_ name: String, lang: String? = nil) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(fileURLWithPath: "/tmp/\(name).srt"), name: name, language: lang)
    }

    @Test("capture preserves mid-session external tracks with exact ids, including removal gaps")
    func captureExternalRegistry() throws {
        let engine = try AetherEngine()
        let first = engine.addExternalSubtitleTrack(makeTrack("one"))
        let second = engine.addExternalSubtitleTrack(makeTrack("two"))
        #expect(first.id == Self.base)
        #expect(second.id == Self.base + 1)
        engine.removeExternalSubtitleTrack(id: first.id)

        let carryover = engine.captureSubtitleSessionCarryover()
        #expect(carryover.externalTracks.map(\.id) == [Self.base + 1])
        #expect(carryover.externalTracks.first?.track.name == "two")
        #expect(carryover.nextExternalOrdinal == 2)
    }

    @Test("capture records the host's explicit subtitle authority and active pick")
    func captureExplicitSelection() throws {
        let engine = try AetherEngine()
        let track = engine.addExternalSubtitleTrack(makeTrack("mid"))
        engine.selectSubtitleTrack(index: track.id)

        let carryover = engine.captureSubtitleSessionCarryover()
        #expect(carryover.activeSubtitleTrackIndex == track.id)
        #expect(carryover.hostExplicitSubtitleAction)
    }

    @Test("capture records explicit subtitles-off with no active pick")
    func captureExplicitOff() throws {
        let engine = try AetherEngine()
        engine.clearSubtitle()

        let carryover = engine.captureSubtitleSessionCarryover()
        #expect(carryover.activeSubtitleTrackIndex == nil)
        #expect(carryover.hostExplicitSubtitleAction)
    }

    @Test("capture flags whether the reapply ordinal maps to the active track (rendering-derived vs host-positional)")
    func captureOrdinalDerivation() throws {
        let engine = try AetherEngine()
        engine.nativeSubtitleTrackTable = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 4, externalID: nil, language: "en", isForced: false),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 6, externalID: nil, language: "de", isForced: false),
        ]
        engine.activeSubtitleTrackIndex = 6
        engine.setNativeSubtitleSelected(track: 1)
        let derived = engine.captureSubtitleSessionCarryover()
        #expect(derived.nativeReapplyOrdinal == 1)
        #expect(derived.reapplyOrdinalMatchesActiveTrack)

        engine.setNativeSubtitleSelected(track: 0)   // positional pick diverging from the active track
        let positional = engine.captureSubtitleSessionCarryover()
        #expect(positional.nativeReapplyOrdinal == 0)
        #expect(!positional.reapplyOrdinalMatchesActiveTrack)
    }
}

@MainActor
struct Issue170CarryoverSeedTests {

    private static let base = AetherEngine.externalSubtitleTrackIDBase

    private func makeTrack(_ name: String) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(fileURLWithPath: "/tmp/\(name).srt"), name: name)
    }

    @Test("seeding restores registry entries id-exactly, the ordinal counter, and the authority flag")
    func seedRestoresRegistry() throws {
        let engine = try AetherEngine()
        var carryover = SubtitleSessionCarryover()
        carryover.externalTracks = [
            .init(id: Self.base + 1, track: makeTrack("survivor")),
            .init(id: Self.base + 3, track: makeTrack("late")),
        ]
        carryover.nextExternalOrdinal = 4
        carryover.hostExplicitSubtitleAction = true

        engine.applySubtitleSessionCarryoverRegistrations(carryover)

        #expect(engine.externalSubtitleRegistry[Self.base + 1]?.name == "survivor")
        #expect(engine.externalSubtitleRegistry[Self.base + 3]?.name == "late")
        #expect(engine.subtitleTracks.map(\.id) == [Self.base + 1, Self.base + 3])
        #expect(engine.nextExternalSubtitleOrdinal == 4)
        #expect(engine.hostExplicitSubtitleAction)

        // Future adds continue after the restored counter, no id collision with the gap history.
        let next = engine.addExternalSubtitleTrack(makeTrack("after"))
        #expect(next.id == Self.base + 4)
    }

    @Test("an empty carryover seeds nothing and leaves auto-selection authority untouched")
    func emptySeedIsInert() throws {
        let engine = try AetherEngine()
        engine.applySubtitleSessionCarryoverRegistrations(SubtitleSessionCarryover())
        #expect(engine.externalSubtitleRegistry.isEmpty)
        #expect(engine.subtitleTracks.isEmpty)
        #expect(engine.nextExternalSubtitleOrdinal == 0)
        #expect(!engine.hostExplicitSubtitleAction)
    }
}

/// Pure restore decisions: what the post-reload session must do to return to the
/// pre-reload selection instead of the reload's re-run auto-selection.
struct Issue170RestoreDecisionTests {

    @Test("a previously active track is re-selected on the fresh session")
    func reselectPreviousTrack() {
        let action = AetherEngine.subtitleSelectionRestoreAction(
            previousActiveIndex: 7, previousSidecarURL: nil, hostHadExplicitAction: true,
            postLoadActiveIndex: nil, postLoadSubtitleActive: false)
        #expect(action == .reselect(index: 7))
    }

    @Test("no reselect churn when the reload already landed on the same track")
    func skipWhenAlreadyActive() {
        let action = AetherEngine.subtitleSelectionRestoreAction(
            previousActiveIndex: 7, previousSidecarURL: nil, hostHadExplicitAction: false,
            postLoadActiveIndex: 7, postLoadSubtitleActive: true)
        #expect(action == .none)
    }

    @Test("explicit subtitles-off clears a reload auto-pick instead of letting it override the user")
    func explicitOffClearsAutoPick() {
        let action = AetherEngine.subtitleSelectionRestoreAction(
            previousActiveIndex: nil, previousSidecarURL: nil, hostHadExplicitAction: true,
            postLoadActiveIndex: 3, postLoadSubtitleActive: true)
        #expect(action == .clear)
    }

    @Test("explicit off with nothing auto-picked needs no action")
    func explicitOffNothingPicked() {
        let action = AetherEngine.subtitleSelectionRestoreAction(
            previousActiveIndex: nil, previousSidecarURL: nil, hostHadExplicitAction: true,
            postLoadActiveIndex: nil, postLoadSubtitleActive: false)
        #expect(action == .none)
    }

    @Test("without explicit host action the reload's auto-selection stands")
    func autoSelectionStands() {
        let action = AetherEngine.subtitleSelectionRestoreAction(
            previousActiveIndex: nil, previousSidecarURL: nil, hostHadExplicitAction: false,
            postLoadActiveIndex: 3, postLoadSubtitleActive: true)
        #expect(action == .none)
    }

    @Test("a one-shot sidecar selection (no track id) is restored by URL")
    func sidecarRestoredByURL() {
        let url = URL(fileURLWithPath: "/tmp/oneshot.srt")
        let action = AetherEngine.subtitleSelectionRestoreAction(
            previousActiveIndex: nil, previousSidecarURL: url, hostHadExplicitAction: true,
            postLoadActiveIndex: nil, postLoadSubtitleActive: false)
        #expect(action == .sidecar(url))
    }
}

/// Pure replay decision for `nativeSubtitleReapplyOrdinal` across the reload, mirroring the
/// #65 recovery replay but table-aware: the carryover-seeded session can grow the rendition
/// table (mid-session externals become load-declared), shifting ordinals.
struct Issue170OrdinalReplayTests {

    private let grownTable = [
        AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_001, language: "de", isForced: false),
        AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 4, externalID: nil, language: "en", isForced: false),
        AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 6, externalID: nil, language: "de", isForced: false),
    ]

    @Test("nothing to replay when no ordinal was set before the reload")
    func nothingToReplay() {
        #expect(AetherEngine.nativeOrdinalToReplay(
            previousOrdinal: nil, matchesActiveTrack: false, previousActiveTrack: nil,
            currentOrdinal: nil, table: grownTable) == nil)
    }

    @Test("a newer host request that landed mid-reload wins over the snapshot")
    func midReloadIntentWins() {
        #expect(AetherEngine.nativeOrdinalToReplay(
            previousOrdinal: 1, matchesActiveTrack: true, previousActiveTrack: 4,
            currentOrdinal: 0, table: grownTable) == nil)
    }

    @Test("a rendering-derived ordinal is recomputed against the grown table")
    func semanticRecompute() {
        // Pre-reload: track 6 was ordinal 1 in a table without the seeded external.
        // Post-reload the seeded external occupies ordinal 0, shifting track 6 to ordinal 2.
        #expect(AetherEngine.nativeOrdinalToReplay(
            previousOrdinal: 1, matchesActiveTrack: true, previousActiveTrack: 6,
            currentOrdinal: nil, table: grownTable) == 2)
    }

    @Test("a host-positional ordinal replays positionally, like the #65 recovery")
    func positionalReplay() {
        #expect(AetherEngine.nativeOrdinalToReplay(
            previousOrdinal: 1, matchesActiveTrack: false, previousActiveTrack: 6,
            currentOrdinal: nil, table: grownTable) == 1)
    }

    @Test("a rendering-derived ordinal whose track vanished falls back to positional replay")
    func recomputeMissFallsBack() {
        #expect(AetherEngine.nativeOrdinalToReplay(
            previousOrdinal: 1, matchesActiveTrack: true, previousActiveTrack: 99,
            currentOrdinal: nil, table: grownTable) == 1)
    }
}

/// The AirPlay flip triggers BOTH the engine's reload and the host's documented
/// `setNativeSubtitleRendering(true)` reaction. If the host call lands while the reload is
/// mid-flight (active track transiently nil), the old path mapped it to a deselect and the
/// receiver rendered no subtitles. The request is latched instead and applied by the restore.
@MainActor
struct Issue170PendingRenderingLatchTests {

    @Test("setNativeSubtitleRendering during a session-preserving reload is deferred, not misread as deselect")
    func latchDefersRequest() throws {
        let engine = try AetherEngine()
        engine.sessionPreservingReloadInFlight = true
        engine.setNativeSubtitleRendering(true)
        #expect(engine.nativeSubtitleReapplyOrdinal == nil)
        #expect(engine.pendingNativeRenderingRequest == true)

        engine.setNativeSubtitleRendering(false)
        #expect(engine.pendingNativeRenderingRequest == false)
    }

    @Test("outside a reload the request maps immediately (deselect when nothing is active)")
    func normalPathUnaffected() throws {
        let engine = try AetherEngine()
        engine.setNativeSubtitleSelected(track: 1)
        engine.setNativeSubtitleRendering(true)   // no active track -> deselect, documented contract
        #expect(engine.nativeSubtitleReapplyOrdinal == nil)
        #expect(engine.pendingNativeRenderingRequest == nil)
    }
}
