import Testing
import CoreMedia
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#739 follow-up: a rebuild that VideoToolbox refused while the picture is on screen is retried at each
/// following keyframe: quickly at first, then at a slower spacing, so a session the system gives back recovers.
@Suite("Video session retry", .serialized, .timeLimit(.minutes(3)))
struct VideoSessionRetryTests {

    // MARK: - Policy

    @Test("the first retries are quick, then the retries slow down instead of stopping")
    func quickThenSlow() {
        var policy = VideoSessionRetryPolicy()
        var decisions: [VideoSessionRetryPolicy.Decision] = []
        // Four keyframes three seconds apart are all quick attempts; the slow spacing then holds the next back.
        for i in 0..<VideoSessionRetryPolicy.maxAttempts {
            decisions.append(policy.onKeyframe(owed: true, now: Double(i) * 3))
        }
        // The last quick attempt was at 9 s: 15 s is inside the slow spacing, 39 s is exactly at it.
        decisions.append(policy.onKeyframe(owed: true, now: 15))
        decisions.append(policy.onKeyframe(owed: true, now: 39))
        let expected: [VideoSessionRetryPolicy.Decision] =
            (1...VideoSessionRetryPolicy.maxAttempts).map { .retry(attempt: $0) } + [.none, .retry(attempt: 5)]
        #expect(decisions == expected)
    }

    @Test("a keyframe with nothing owed does nothing and spends no attempt")
    func nothingOwed() {
        var policy = VideoSessionRetryPolicy()
        #expect(policy.onKeyframe(owed: false, now: 0) == .none)
        #expect(policy.attempts == 0)
        #expect(policy.onKeyframe(owed: true, now: 0) == .retry(attempt: 1))
    }

    @Test("keyframes in a burst spend one attempt, then wait out the spacing")
    func spacing() {
        var policy = VideoSessionRetryPolicy()
        #expect(policy.onKeyframe(owed: true, now: 10) == .retry(attempt: 1))
        #expect(policy.onKeyframe(owed: true, now: 10.1) == .none)
        #expect(policy.onKeyframe(owed: true, now: 11.9) == .none)
        #expect(policy.attempts == 1)
        #expect(policy.onKeyframe(owed: true, now: 12.0) == .retry(attempt: 2))
    }

    @Test("a reset gives the next loss a fresh quick budget, even after the retries had slowed down")
    func resetRestoresTheBudget() {
        var policy = VideoSessionRetryPolicy()
        for i in 0..<VideoSessionRetryPolicy.maxAttempts { _ = policy.onKeyframe(owed: true, now: Double(i) * 3) }
        #expect(policy.attempts == VideoSessionRetryPolicy.maxAttempts)
        policy.reset()
        #expect(policy.attempts == 0)
        #expect(policy.onKeyframe(owed: true, now: 0) == .retry(attempt: 1))
    }

    // MARK: - Host: the picture off screen, the slow retries and the foreground return

    @MainActor
    @Test("a keyframe with the picture off screen in the background spends no retry")
    func backgroundSpendsNoRetry() {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        host.noteAppInBackground(true)
        host.setVideoSessionRecoveryOwedForTesting()
        for _ in 0..<(VideoSessionRetryPolicy.maxAttempts + 2) {
            host.keyframeWhileSessionLostForTesting()
        }
        #expect(host.videoSessionRetryAttemptsForTesting == 0)
        #expect(host.failure == nil)
    }

    @MainActor
    @Test("with the picture still on screen in the background (picture-in-picture), a keyframe retries")
    func pictureInPictureRetries() {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        // The engine reports no off-screen background while a picture-in-picture window shows the picture.
        host.noteAppInBackground(false)
        host.setVideoSessionRecoveryOwedForTesting()
        host.keyframeWhileSessionLostForTesting()
        #expect(host.videoSessionRetryAttemptsForTesting == 1)
    }

    @MainActor
    @Test("a spent quick budget keeps retrying at the slow spacing and publishes no failure")
    func slowRetriesPublishNoFailure() {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        host.spendVideoSessionRetriesForTesting()
        host.setVideoSessionRecoveryOwedForTesting()
        host.keyframeWhileSessionLostForTesting()
        #expect(host.videoSessionRetryAttemptsForTesting == VideoSessionRetryPolicy.maxAttempts + 1)
        #expect(host.failure == nil)
    }

    @MainActor
    @Test("coming back on screen starts a fresh quick budget, and the next keyframe retries at once")
    func foregroundReturnStartsFreshBudget() {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        host.spendVideoSessionRetriesForTesting()
        host.noteAppInBackground(true)
        #expect(host.videoSessionRetryAttemptsForTesting == VideoSessionRetryPolicy.maxAttempts)
        host.noteAppInBackground(false)
        #expect(host.videoSessionRetryAttemptsForTesting == 0)
        host.setVideoSessionRecoveryOwedForTesting()
        host.keyframeWhileSessionLostForTesting()
        #expect(host.videoSessionRetryAttemptsForTesting == 1)
    }

    // MARK: - Decoder reports keyframes while lost

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private static func withPacket(key: Bool, _ body: (UnsafeMutablePointer<AVPacket>) -> Void) {
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let p = packet else { return }
        p.pointee.flags = key ? AV_PKT_FLAG_KEY : 0
        body(p)
    }

    #if DEBUG
    @Test("a hardware decoder with a lost session reports each keyframe it is fed, and no other packet")
    func hardwareDecoderReportsKeyframes() {
        let decoder = HardwareVideoDecoder()
        let seen = Counter()
        decoder.onKeyframeWhileLost = { seen.bump() }
        // Not lost: nothing to report.
        Self.withPacket(key: true) { decoder.decode(packet: $0, epoch: nil) }
        #expect(seen.value == 0)
        decoder.markSessionLostForTesting()
        #expect(decoder.isSessionLost)
        Self.withPacket(key: false) { decoder.decode(packet: $0, epoch: nil) }
        #expect(seen.value == 0)
        Self.withPacket(key: true) { decoder.decode(packet: $0, epoch: nil) }
        Self.withPacket(key: true) { decoder.decode(packet: $0, epoch: nil) }
        #expect(seen.value == 2)
    }
    #endif
}
