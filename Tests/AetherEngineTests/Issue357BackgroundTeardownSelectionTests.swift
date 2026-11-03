import Foundation
import Testing
@testable import AetherEngine

/// AetherEngine#357: the paused-background teardown (#127) and the foreground-return reload are
/// minutes apart, but every reload path snapshots the session state it wants to restore at reload
/// time (`captureSubtitleSessionCarryover`, `activeAudioTrackIndex`, `activeDiscTitleID`). The
/// teardown's `stopInternal` has wiped all of it by then, so the reload restored nothing: no
/// subtitle selection, hence no drain target, hence total silence on the delivery instrument
/// (rrgomes' report, no `#357` / `#250` / `applySubtitleEvent` line after the reload).
///
/// `hostExplicitSubtitleAction` was the only survivor, and it suppressed the preferred-language
/// auto-selection that would otherwise have re-armed a track, which is why only an EXPLICITLY
/// picked track died: an auto-picked one came back through the re-run auto-selection.
@MainActor
struct Issue357BackgroundTeardownSelectionTests {

    private static let base = AetherEngine.externalSubtitleTrackIDBase

    private func makeTrack(_ name: String) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(fileURLWithPath: "/tmp/\(name).srt"), name: name)
    }

    /// Runs exactly what `teardownVideoForBackground` / `expireBackgroundGraceNow` do.
    private func backgroundTeardown(_ engine: AetherEngine) {
        engine.captureBackgroundTeardownSelection()
        engine.stopInternal(resetDisplayCriteria: false, keepNativeHost: true, keepCustomReader: true)
    }

    @Test("foreground restore is owed only after video teardown")
    func restoreRequiresTeardown() throws {
        let engine = try AetherEngine()
        #expect(!engine.needsForegroundVideoRestore)
        backgroundTeardown(engine)
        #expect(engine.needsForegroundVideoRestore)
        _ = engine.consumeReloadSelection()
        #expect(!engine.needsForegroundVideoRestore)
    }

    @Test("the selection stopInternal wipes is still there for the reload that follows minutes later")
    func teardownHandsSelectionToReload() throws {
        let engine = try AetherEngine()
        let track = engine.addExternalSubtitleTrack(makeTrack("picked"))
        engine.selectSubtitleTrack(index: track.id)
        engine.activeAudioTrackIndex = 2
        engine.activeDiscTitleID = 7

        backgroundTeardown(engine)
        // The wipe itself is correct: the session is gone. Documented so a future reader sees why
        // the reload's own snapshot cannot be the source of truth on this path.
        #expect(engine.activeSubtitleTrackIndex == nil)
        #expect(engine.activeAudioTrackIndex == nil)
        #expect(engine.activeDiscTitleID == nil)

        let selection = engine.consumeReloadSelection()
        #expect(selection.subtitles.activeSubtitleTrackIndex == track.id)
        #expect(selection.subtitles.hostExplicitSubtitleAction)
        #expect(selection.audioTrackIndex == 2)
        #expect(selection.discTitleID == 7)
    }

    @Test("restoring the carried selection re-arms the drain target, which is what went silent")
    func restoredSelectionRearmsTheDrain() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(fileURLWithPath: "/tmp/pgs.mkv")
        engine.selectSubtitleTrack(index: 3)
        #expect(engine.subtitleDrainTargets[.primary] == 3)

        backgroundTeardown(engine)
        #expect(engine.subtitleDrainTargets.isEmpty)

        // The reload reopens the same URL, then replays the carried selection.
        engine.loadedURL = URL(fileURLWithPath: "/tmp/pgs.mkv")
        let selection = engine.consumeReloadSelection()
        engine.restoreSubtitleSelection(from: selection.subtitles, resumeAnchor: nil)
        #expect(engine.subtitleDrainTargets[.primary] == 3)
        #expect(engine.isSubtitleActive)
    }

    @Test("a secondary channel and a native rendition ordinal ride along")
    func secondaryAndOrdinalRideAlong() throws {
        let engine = try AetherEngine()
        engine.nativeSubtitleTrackTable = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 3, externalID: nil, language: "en", isForced: false),
        ]
        engine.loadedURL = URL(fileURLWithPath: "/tmp/pgs.mkv")
        engine.selectSubtitleTrack(index: 3)
        engine.selectSecondarySubtitleTrack(index: 5)
        engine.setNativeSubtitleSelected(track: 0)

        backgroundTeardown(engine)

        let selection = engine.consumeReloadSelection()
        #expect(selection.subtitles.secondaryTrackIndex == 5)
        #expect(selection.subtitles.nativeReapplyOrdinal == 0)
        #expect(selection.subtitles.reapplyOrdinalMatchesActiveTrack)
    }

    /// Audit CORE-3: on iOS a `pause()` while backgrounded re-arms the grace window after the first
    /// teardown, and its expiry tears down again. That second capture reads what `stopInternal`
    /// already wiped and used to replace the good snapshot with it.
    @Test("a second teardown before the reload keeps the selection the first one parked")
    func secondTeardownKeepsParkedSelection() throws {
        let engine = try AetherEngine()
        let track = engine.addExternalSubtitleTrack(makeTrack("picked"))
        engine.selectSubtitleTrack(index: track.id)
        engine.activeAudioTrackIndex = 2
        engine.activeDiscTitleID = 7

        backgroundTeardown(engine)
        backgroundTeardown(engine)

        let selection = engine.consumeReloadSelection()
        #expect(selection.subtitles.activeSubtitleTrackIndex == track.id)
        #expect(selection.subtitles.hostExplicitSubtitleAction)
        #expect(selection.audioTrackIndex == 2)
        #expect(selection.discTitleID == 7)
    }

    @Test("a pick made after the teardown is newer intent and wins over the snapshot")
    func newerIntentWins() throws {
        let engine = try AetherEngine()
        let old = engine.addExternalSubtitleTrack(makeTrack("old"))
        engine.selectSubtitleTrack(index: old.id)
        backgroundTeardown(engine)

        // Host picks a different track while the session is down (or the reload's own load already
        // auto-selected one); the snapshot must not undo it.
        let new = engine.addExternalSubtitleTrack(makeTrack("new"))
        engine.selectSubtitleTrack(index: new.id)

        let selection = engine.consumeReloadSelection()
        #expect(selection.subtitles.activeSubtitleTrackIndex == new.id)
    }

    @Test("the live registry stays authoritative, so a track added after the teardown survives")
    func registryComesFromTheLiveSession() throws {
        let engine = try AetherEngine()
        let before = engine.addExternalSubtitleTrack(makeTrack("before"))
        engine.selectSubtitleTrack(index: before.id)
        backgroundTeardown(engine)
        let after = engine.addExternalSubtitleTrack(makeTrack("after"))

        let selection = engine.consumeReloadSelection()
        #expect(selection.subtitles.externalTracks.map(\.id) == [before.id, after.id])
        #expect(selection.subtitles.activeSubtitleTrackIndex == before.id)
    }

    @Test("the snapshot is consumed once; a second reload does not resurrect a dead selection")
    func consumedOnce() throws {
        let engine = try AetherEngine()
        let track = engine.addExternalSubtitleTrack(makeTrack("once"))
        engine.selectSubtitleTrack(index: track.id)
        backgroundTeardown(engine)

        _ = engine.consumeReloadSelection()
        let second = engine.consumeReloadSelection()
        #expect(second.subtitles.activeSubtitleTrackIndex == nil)
    }

    @Test("stop() drops the snapshot: a host leaving playback is not a reload")
    func stopDropsTheSnapshot() throws {
        let engine = try AetherEngine()
        let track = engine.addExternalSubtitleTrack(makeTrack("gone"))
        engine.selectSubtitleTrack(index: track.id)
        engine.playbackBackend = .software
        engine.lastRequiresDeinterlaceWarmup = true
        backgroundTeardown(engine)
        #expect(engine.backgroundTeardownSelection?.requiresDeinterlaceWarmup == true)

        engine.stop()
        let selection = engine.consumeReloadSelection()
        #expect(selection.subtitles.activeSubtitleTrackIndex == nil)
        #expect(selection.audioTrackIndex == nil)
        #expect(selection.requiresDeinterlaceWarmup == nil)
    }

    // MARK: - The host the teardown keeps (Sodalite#149)

    @Test("the teardown keeps the host, and the load on the way back keeps it too (Sodalite#149)")
    func reloadAfterBackgroundTeardownKeepsTheNativeHost() throws {
        let engine = try AetherEngine()
        engine.nativeHost = NativeAVPlayerHost()
        engine.playbackBackend = .native
        let surface = AetherPlayerView(frame: .zero)
        engine.bind(view: surface)
        let layer = engine.nativePlayerLayer
        #expect(layer?.superlayer != nil)

        backgroundTeardown(engine)

        // The teardown preserves the host on purpose: AVKit registers its Now-Playing client once
        // per AVPlayer instance (issue #15), so the instance has to outlive the suspension.
        #expect(engine.nativeHost != nil)
        #expect(engine.nativePlayerLayer === layer)
        #expect(layer?.superlayer != nil)
        #expect(!engine.isSessionReady)
        #expect(!engine.hasFirstFrameReadyForDisplay)
        // And it resets the backend, which is the state the foreground reload's load() reads.
        #expect(engine.playbackBackend == .none)
        // Reading the backend alone answered "nothing native here" and threw the kept host away.
        #expect(AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: engine.playbackBackend,
            nativeHostSurvives: engine.nativeHost != nil) == true)
    }

    @Test("a running native session still preserves its host across a load seam")
    func runningNativeSessionPreservesItsHost() {
        #expect(AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .native, nativeHostSurvives: true) == true)
    }

    @Test("nothing to keep: a load with no native host behind it preserves nothing")
    func nothingToPreserve() {
        #expect(AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .none, nativeHostSurvives: false) == false)
        #expect(AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .software, nativeHostSurvives: false) == false)
    }

    @Test("no teardown snapshot: the reload reads the live session, unchanged from before #357")
    func liveSessionPathUnchanged() throws {
        let engine = try AetherEngine()
        let track = engine.addExternalSubtitleTrack(makeTrack("live"))
        engine.selectSubtitleTrack(index: track.id)
        engine.activeAudioTrackIndex = 4
        engine.activeDiscTitleID = 9

        let selection = engine.consumeReloadSelection()
        #expect(selection.subtitles.activeSubtitleTrackIndex == track.id)
        #expect(selection.audioTrackIndex == 4)
        #expect(selection.discTitleID == 9)
    }
}
