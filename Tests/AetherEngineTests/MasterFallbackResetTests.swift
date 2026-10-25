import Foundation
import Testing
@testable import AetherEngine

/// #849: the master->media fallback (#98) single-shot is per SESSION. A session-preserving rebuild (an
/// audio-track switch, `reloadAtCurrentPosition`) tears down through `stopInternal` and rebuilds a
/// fresh `HLSVideoEngine` with its own master, so the new session deserves its own single-shot.
/// The reset used to live only in `loadSession`'s prologue, which the reload path never passes
/// through: a fallback spent on the outgoing session's master (a DV P8.1 source's one -11868 +
/// media fallback at mount) leaked into the reload, and the reload's own master rejection then
/// surfaced `.masterPlaylistRejected` ("Cannot open") instead of falling back to the media
/// playlist. The rejection was classified and signalled; the mount never came.
@Suite("#849: the master-fallback single-shot resets across a session-preserving reload")
@MainActor
struct MasterFallbackResetTests {

    /// The shared teardown every rebuild passes through must reset the latch, so the reload's
    /// fresh master can fall back once on its own rejection.
    @Test("stopInternal resets the master-fallback single-shot")
    func stopInternalResetsTheLatch() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "http://127.0.0.1:9/source.mkv")
        // Simulate a session that already spent its fallback on its own master rejection.
        engine.masterFallbackUsed = true

        engine.stop()

        #expect(engine.masterFallbackUsed == false)
    }

    /// A reload re-arms the single-shot, so the reactive gate admits a rejection of the NEW
    /// session's master exactly as `MasterFallbackDecision` already documents for a first fallback.
    @Test("A reset latch re-admits the new session's master rejection")
    func resetLatchReadmitsFallback() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "http://127.0.0.1:9/source.mkv")
        engine.masterFallbackUsed = true

        engine.stop()

        // What fallBackToMediaPlaylist asks on the reload's -11868: serving a master, not yet
        // fallen back on THIS session.
        #expect(MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11868,
            servingMasterPlaylist: true,
            alreadyFellBack: engine.masterFallbackUsed))
    }

    @Test("stopInternal resets the display-refusal fact with the latch")
    func stopInternalResetsTheRefusal() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "http://127.0.0.1:9/source.mkv")
        engine.masterRefusedByDisplay = true

        engine.stop()

        #expect(engine.masterRefusedByDisplay == false)
    }

    /// The audio switch keeps the media playlist only when the outgoing session is on it because the
    /// display refused its HDR master. Still on the master, or on media for another reason (a
    /// parse failure, an SDR refusal, a route that never served a master), it routes afresh.
    @Test("An audio switch keeps the media route only after a display refusal",
          arguments: [
            (servingMaster: false, refusedByDisplay: true, keeps: true),
            (servingMaster: false, refusedByDisplay: false, keeps: false),
            (servingMaster: true, refusedByDisplay: true, keeps: false),
            (servingMaster: true, refusedByDisplay: false, keeps: false),
          ])
    func audioSwitchKeepsMediaRoute(
        _ c: (servingMaster: Bool, refusedByDisplay: Bool, keeps: Bool)
    ) {
        #expect(MasterFallbackDecision.audioSwitchKeepsMediaRoute(
            outgoingServingMaster: c.servingMaster,
            outgoingMasterRefusedByDisplay: c.refusedByDisplay) == c.keeps)
    }
}
