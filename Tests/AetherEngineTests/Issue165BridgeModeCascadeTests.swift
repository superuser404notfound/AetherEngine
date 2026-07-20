import Testing
@testable import AetherEngine

/// #165: on an FFmpeg build missing the configured bridge encoder (e.g. no --enable-encoder=eac3),
/// `AudioBridge.init(mode:)` throws `.encoderNotFound` and the single-attempt route dropped straight to
/// silent video-only. The fix cascades to the other bridge mode's encoder before giving up. These cover
/// the ordering decision (`bridgeModeCascade`) in isolation; the encoder-absent runtime path itself can't
/// be unit-tested because CI's FFmpeg build carries both encoders (verified on hardware by the reporter).
@Suite("Issue #165 audio bridge-mode cascade")
struct Issue165BridgeModeCascadeTests {

    @Test("surroundCompat (EAC3) cascades to lossless (FLAC)")
    func surroundCompatCascadesToLossless() {
        #expect(HLSVideoEngine.bridgeModeCascade(configured: .surroundCompat) == [.surroundCompat, .lossless])
    }

    @Test("lossless (FLAC) cascades to surroundCompat (EAC3)")
    func losslessCascadesToSurroundCompat() {
        #expect(HLSVideoEngine.bridgeModeCascade(configured: .lossless) == [.lossless, .surroundCompat])
    }

    @Test("the configured mode is always attempted first")
    func configuredModeFirst() {
        for mode in AudioBridgeMode.allCases {
            #expect(HLSVideoEngine.bridgeModeCascade(configured: mode).first == mode)
        }
    }

    @Test("cascade covers every mode exactly once (no repeats, no silent gaps)")
    func cascadeIsAPermutationOfAllModes() {
        for mode in AudioBridgeMode.allCases {
            let cascade = HLSVideoEngine.bridgeModeCascade(configured: mode)
            #expect(cascade.count == AudioBridgeMode.allCases.count)
            #expect(Set(cascade).count == cascade.count)
            #expect(Set(cascade) == Set(AudioBridgeMode.allCases))
        }
    }
}
