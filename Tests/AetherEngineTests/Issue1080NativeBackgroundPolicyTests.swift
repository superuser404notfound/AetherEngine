import AVFoundation
import Testing
@testable import AetherEngine

/// AE#1080: the native AVPlayer's background policy follows `backgroundPlaybackEnabled`. Whether audio
/// really keeps going in the background needs an iPhone; this pins the choice the engine makes.
@MainActor
@Suite("AE#1080 native AVPlayer background policy", .timeLimit(.minutes(3)))
struct Issue1080NativeBackgroundPolicyTests {

    @Test("enabled continues if possible, disabled stays automatic")
    func policySelection() {
        #expect(NativeAVPlayerHost.backgroundPlaybackPolicy(allowed: true) == .continuesIfPossible)
        #expect(NativeAVPlayerHost.backgroundPlaybackPolicy(allowed: false) == .automatic)
    }

    @Test("a fresh host keeps the system default until told otherwise")
    func freshHostIsAutomatic() {
        let host = NativeAVPlayerHost()
        #expect(host.backgroundAudioAllowed == false)
        #expect(host.avPlayer.audiovisualBackgroundPlaybackPolicy == .automatic)
    }

    @Test("the engine hands its setting to the host it builds and to one it already holds")
    func engineForwardsSetting() throws {
        let engine = try AetherEngine()
        engine.backgroundPlaybackEnabled = true
        let host = engine.makeNativeHost()
        #expect(host.backgroundAudioAllowed == true)
        engine.nativeHost = host
        engine.backgroundPlaybackEnabled = false
        #expect(host.backgroundAudioAllowed == false)
        engine.backgroundPlaybackEnabled = true
        #expect(host.backgroundAudioAllowed == true)
        #if os(iOS)
        #expect(host.avPlayer.audiovisualBackgroundPlaybackPolicy == .continuesIfPossible)
        #endif
        engine.nativeHost = nil
    }
}
