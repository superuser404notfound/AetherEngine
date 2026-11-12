import Testing
@testable import AetherEngine

/// #180: the native video path can own an `MPNowPlayingSession`, but only when the host asks for it.
///
/// The audio path owns one unconditionally because it is always a bare AVPlayer. The native video
/// player is also consumed by `AVPlayerViewController` hosts, where AVKit owns Now-Playing through
/// private MediaRemote, so claiming a session by default would cost those hosts AVKit's card, its
/// `externalMetadata` and its transport commands. These cover the opt-in gate and the staging
/// semantics; the session object itself is compiled out on macOS, where the suite runs.
@Suite("Issue 180: video Now-Playing session opt-in")
@MainActor
struct VideoNowPlayingOptInTests {

    // MARK: - Opt-in gate

    @Test("A host owns no session by default")
    func hostDefaultsToNoSession() {
        #expect(!NativeAVPlayerHost().ownsNowPlayingSession)
    }

    @Test("A host owns one only when asked")
    func hostOwnsWhenAsked() {
        #expect(NativeAVPlayerHost(ownsNowPlayingSession: true).ownsNowPlayingSession)
    }

    @Test("The engine defaults to leaving Now-Playing to the host's UI layer")
    func engineDefaultsToOff() throws {
        let engine = try AetherEngine()
        #expect(!engine.ownsVideoNowPlayingSession)
        #expect(!engine.ownsVideoNowPlayingCommands)
        #expect(!engine.ownsAudioNowPlaying)
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @Test("The engine builds hosts carrying its current ownership choice")
    func engineThreadsTheChoiceIntoHosts() throws {
        let engine = try AetherEngine()
        #expect(!engine.makeNativeHost().ownsNowPlayingSession)
        engine.ownsVideoNowPlayingSession = true
        #expect(engine.makeNativeHost().ownsNowPlayingSession)
    }

    @Test("No session exists before a native host does")
    func noSessionWithoutHost() throws {
        let engine = try AetherEngine()
        engine.ownsVideoNowPlayingSession = true
        #expect(engine.videoNowPlayingSession == nil)
    }
    #endif

    // MARK: - Staging semantics

    @Test("Identity staged before load survives until a host can take it")
    func infoStagesWithoutHost() throws {
        let engine = try AetherEngine()
        engine.setVideoNowPlayingInfo(["title": "Staged"])
        #expect(engine.pendingVideoNowPlayingInfo.count == 1)
    }

    @Test("Identity is staged even with ownership off, so opting in later keeps it")
    func infoStagesWhileOptedOut() throws {
        let engine = try AetherEngine()
        #expect(!engine.ownsVideoNowPlayingSession)
        engine.setVideoNowPlayingInfo(["title": "Staged"])
        #expect(engine.pendingVideoNowPlayingInfo.count == 1)
    }

    @Test("An empty dictionary clears the staged identity")
    func emptyInfoClears() throws {
        let engine = try AetherEngine()
        engine.setVideoNowPlayingInfo(["title": "Staged"])
        engine.setVideoNowPlayingInfo([:])
        #expect(engine.pendingVideoNowPlayingInfo.isEmpty)
    }

    @Test("stop() clears the staged identity so the next session starts without a stale card")
    func stopClearsStagedInfo() throws {
        let engine = try AetherEngine()
        engine.setVideoNowPlayingInfo(["title": "Staged"])
        engine.stop()
        #expect(engine.pendingVideoNowPlayingInfo.isEmpty)
    }
}
