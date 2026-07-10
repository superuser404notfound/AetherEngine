#if os(iOS) || os(tvOS)
import AVFoundation
import XCTest
@testable import AetherEngine

/// Issue #116: `.longFormAudio` marks the process as a long-form audio client. On iOS that makes
/// `AVPictureInPictureController.isPictureInPicturePossible` permanently false for hosts that build
/// a PiP controller around the engine's player layer, and since the engine re-declares the policy on
/// every init (from a detached task, #114), hosts cannot durably opt out. The policy is therefore
/// platform-split: tvOS keeps `.longFormAudio` (HDMI route negotiation, #24), iOS declares `.default`.
final class AudioSessionRouteSharingPolicyTests: XCTestCase {

    private var expected: AVAudioSession.RouteSharingPolicy {
        #if os(tvOS)
        return .longFormAudio
        #else
        return .default
        #endif
    }

    @MainActor
    func testEngineDeclaresPlatformSplitRouteSharingPolicy() async throws {
        XCTAssertEqual(AetherEngine.audioSessionRouteSharingPolicy, expected,
                       "iOS must not declare .longFormAudio, it disables AVKit PiP for hosts (#116)")

        let engine = try AetherEngine()
        await engine.awaitAudioSessionCategoryConfigured()
        XCTAssertEqual(AVAudioSession.sharedInstance().routeSharingPolicy, expected,
                       "init() must declare the platform policy on the shared session")
    }
}
#endif
