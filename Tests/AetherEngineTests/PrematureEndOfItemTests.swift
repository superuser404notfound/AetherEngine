// Premature end-of-item recovery (AetherEngine#287).
//
// When a VOD's selected audio track outruns its video track, AVPlayer ends the item the moment the
// video renderer runs dry, tens of seconds short of the advertised duration. Measured on the
// reporter's shape (video 60.0 s, audio 113.0 s, one loopback fMP4 rendition): `didPlayToEndTime` at
// 60.03 s of a 113.02 s presentation, reproducing identically for a 2 s, an 8 s and a 53 s tail, so
// it is the video exhaustion that triggers it and not the length of the tail. The playlist is not
// the culprit either: its EXTINF sum equals the container duration to the millisecond.
//
// `.ended` is terminal (#63/#164), so forwarding that event as an organic finish makes the tail
// unreachable for the rest of the session. The discriminator is AVPlayer contradicting itself: it
// ended the item well inside a presentation it still reports as SEEKABLE. The loaded range cannot
// serve here (unlike #169): at that instant AVPlayer has already trimmed it back to the exhaustion
// point, so it agrees with the mistake.
//
// These pure cases pin that discriminator and the bounds that keep a futile retry from looping.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Premature end-of-item recovery (#287)")
struct PrematureEndOfItemTests {

    // The reporter's exact shape: video ends 1431.971 s, selected AAC ends 1484.935 s, container
    // duration 1484.936 s, end fired at 1432.000 s.
    let duration = 1484.936
    let boundary = 1432.0
    let seekableToEnd = 1484.936

    @Test("An end fired at video exhaustion inside the seekable range is contradicted")
    func qualifiesInsideSeekableRange() {
        #expect(AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: boundary,
            seekableEnd: seekableToEnd,
            attemptsUsed: 0,
            lastAttemptPlayhead: nil))
    }

    @Test("An end at the edge of the seekable range is a real finish, not a contradiction")
    func rejectsEndAtSeekableEdge() {
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: boundary,
            seekableEnd: boundary,
            attemptsUsed: 0,
            lastAttemptPlayhead: nil))
    }

    @Test("A missing seekable range is never a contradiction")
    func rejectsMissingSeekableRange() {
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: boundary,
            seekableEnd: nil,
            attemptsUsed: 0,
            lastAttemptPlayhead: nil))
    }

    @Test("A genuine finish at the advertised duration is forwarded unchanged")
    func rejectsOrganicEnd() {
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: duration - 0.05,
            seekableEnd: seekableToEnd,
            attemptsUsed: 0,
            lastAttemptPlayhead: nil))
    }

    // The #169 tail park completes within `endOfMediaEpsilonSeconds` of duration; this recovery must
    // not reach into that window, or the two would fight over the same last half second.
    @Test("The #169 tail-park window is disjoint from this recovery")
    func disjointFromTailParkWindow() {
        #expect(AetherEngine.prematureEndShortfallSeconds > AetherEngine.endOfMediaEpsilonSeconds)
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: duration - AetherEngine.endOfMediaEpsilonSeconds,
            seekableEnd: seekableToEnd,
            attemptsUsed: 0,
            lastAttemptPlayhead: nil))
    }

    @Test("A live source never qualifies (no fixed end to fall short of)")
    func rejectsLive() {
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: true,
            duration: duration,
            playhead: boundary,
            seekableEnd: seekableToEnd,
            attemptsUsed: 0,
            lastAttemptPlayhead: nil))
    }

    @Test("An unknown duration never qualifies")
    func rejectsUnknownDuration() {
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: 0,
            playhead: boundary,
            seekableEnd: seekableToEnd,
            attemptsUsed: 0,
            lastAttemptPlayhead: nil))
    }

    @Test("A non-finite playhead never qualifies")
    func rejectsNonFinitePlayhead() {
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: .nan,
            seekableEnd: seekableToEnd,
            attemptsUsed: 0,
            lastAttemptPlayhead: nil))
    }

    // A recovery that did not move the playhead is a recovery that cannot work on this item. Accept
    // the end rather than re-seek the same position forever.
    @Test("A repeat end at the same position after a recovery is accepted")
    func rejectsStalledRetry() {
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: boundary + 0.01,
            seekableEnd: seekableToEnd,
            attemptsUsed: 1,
            lastAttemptPlayhead: boundary))
    }

    @Test("A repeat end further along the item still qualifies")
    func acceptsRetryAfterProgress() {
        #expect(AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: boundary + 40,
            seekableEnd: seekableToEnd,
            attemptsUsed: 1,
            lastAttemptPlayhead: boundary))
    }

    @Test("Attempts are bounded")
    func boundsAttempts() {
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false,
            duration: duration,
            playhead: boundary,
            seekableEnd: seekableToEnd,
            attemptsUsed: AetherEngine.prematureEndRecoveryMaxAttempts,
            lastAttemptPlayhead: nil))
    }

    // AE#962: a session that joined inside the audio-only tail never loaded a video sample. At the
    // REAL end AVPlayer publishes its clock back at the end of the video track (126.9 s, then 60.000
    // and 60.008, still at rate 1.0, then didPlayToEndTime), and every reading agrees with it: the
    // item, the player, the observer. Read alone, that is a premature end, and the tail played twice.
    @Test("A clock that just reached the end outranks the position AVPlayer snaps back to")
    func freshPeakOutranksSnappedPlayhead() {
        let playhead = AetherEngine.prematureEndPlayhead(read: 60.008, peak: 126.9, peakAgeSeconds: 0.2)
        #expect(playhead == 126.9)
        #expect(!AetherEngine.prematureEndRecoveryQualifies(
            isLive: false, duration: 127.039, playhead: playhead, seekableEnd: 127.039,
            attemptsUsed: 0, lastAttemptPlayhead: nil))
    }

    @Test("A peak left behind by an earlier backward scrub is not a witness")
    func stalePeakIsIgnored() {
        #expect(AetherEngine.prematureEndPlayhead(read: boundary, peak: 1480, peakAgeSeconds: 600) == boundary)
    }

    @Test("The premature end itself keeps its reading")
    func prematureEndKeepsReading() {
        #expect(AetherEngine.prematureEndPlayhead(read: boundary, peak: boundary - 0.1, peakAgeSeconds: 0.1) == boundary)
        #expect(AetherEngine.prematureEndPlayhead(read: boundary, peak: nil, peakAgeSeconds: nil) == boundary)
    }

    // AE#962: the reporter's session sat behind a black picture for over two minutes on an in-place
    // re-seek that never landed. The seek is bounded; what happens after it is decided here.
    @Test("A re-seek that lands resumes, one that does not accepts the end, a newer seek owns the transport")
    func recoveryOutcome() {
        #expect(AetherEngine.prematureEndRecoveryOutcome(landed: true, superseded: false) == .resume)
        #expect(AetherEngine.prematureEndRecoveryOutcome(landed: false, superseded: false) == .acceptEnd)
        #expect(AetherEngine.prematureEndRecoveryOutcome(landed: false, superseded: true) == .yield)
    }

    // Failure modes:
    // - A slow AVFoundation read ages a fresh end witness out and replays an already-finished tail.
    // - A peak already stale at notification time incorrectly replaces the reported playhead.
    // - A late read starts recovery or changes time after a session replacement or a newer seek.

    /// Read latency cannot invalidate the peak that was fresh when this end was observed.
    @Test(.timeLimit(.minutes(3)))
    @MainActor
    func test_endReading_freshPeakBeforeSlowRead_acceptsRealEnd() async throws {
        // Arrange — the observer reached the real end 0.2 seconds before the notification.
        let host = NativeAVPlayerHost()
        defer {
            host.prematureEndReadForTesting = nil
            host.tearDown()
        }
        host.prematureEndUptimeForTesting = 100_000_000_000
        host.preparePrematureEndForTesting(
            duration: 127.039, playhead: 60.008,
            peak: (seconds: 126.9, uptimeNanos: 99_800_000_000)
        )
        host.prematureEndReadForTesting = {
            await Task.yield()
            host.prematureEndUptimeForTesting = 113_300_000_000
            return PrematureEndReading(playhead: 60.008, seekableEnd: 127.039, loadedEnd: 60)
        }

        // Act — use the actual host recovery after a simulated 13.3-second asynchronous read.
        let suppressed = await host.recoverFromPrematureEndForTesting()

        // Assert — accept the real end at its witnessed position, without seeking back into the tail.
        #expect(!suppressed)
        #expect(host.currentTime == 126.9)
        #expect(host.prematureEndAttemptsForTesting == 0)
    }

    /// Capturing before the read must not revive a witness already stale when the end arrived.
    @Test(.timeLimit(.minutes(3)))
    @MainActor
    func test_endReading_peakAlreadyStale_keepsReportedEnd() async throws {
        // Arrange — this older peak belongs to playback before the current end boundary.
        let host = NativeAVPlayerHost()
        defer {
            host.prematureEndReadForTesting = nil
            host.tearDown()
        }
        host.prematureEndUptimeForTesting = 100_000_000_000
        host.preparePrematureEndForTesting(
            duration: 127.039, playhead: 60.008,
            peak: (seconds: 126.9, uptimeNanos: 98_000_000_000)
        )
        host.prematureEndReadForTesting = {
            await Task.yield()
            host.prematureEndUptimeForTesting = 113_300_000_000
            return PrematureEndReading(playhead: 60.008, seekableEnd: 60.008, loadedEnd: 60)
        }

        // Act — the source's seekable end agrees with its clock after the delayed reading.
        let suppressed = await host.recoverFromPrematureEndForTesting()

        // Assert — the old peak cannot move this end or authorize a recovery seek.
        #expect(!suppressed)
        #expect(host.currentTime == 60.008)
        #expect(host.prematureEndAttemptsForTesting == 0)
    }

    /// An old notification cannot update or recover a replacement session after its read completes.
    @Test(.timeLimit(.minutes(3)))
    @MainActor
    func test_endReading_sessionReplaced_yieldsWithoutMutatingReplacement() async throws {
        // Arrange — replace the session while its asynchronous end reading is suspended.
        let host = NativeAVPlayerHost()
        defer {
            host.prematureEndReadForTesting = nil
            host.tearDown()
        }
        host.prematureEndUptimeForTesting = 100_000_000_000
        host.preparePrematureEndForTesting(duration: 127.039, playhead: 60.008, peak: nil)
        host.prematureEndReadForTesting = {
            await Task.yield()
            host.preparePrematureEndForTesting(duration: 200, playhead: 20, peak: nil)
            return PrematureEndReading(playhead: 60.008, seekableEnd: 127.039, loadedEnd: 60)
        }

        // Act — resolve the retired session's reading against the live host object.
        let suppressed = await host.recoverFromPrematureEndForTesting()

        // Assert — suppress the retired event and preserve the replacement's transport state.
        #expect(suppressed)
        #expect(host.currentTime == 20)
        #expect(host.prematureEndAttemptsForTesting == 0)
        #expect(!host.didReachEnd)
    }

    /// A newer seek owns the transport even when the item and session identity stay the same.
    @Test(.timeLimit(.minutes(3)))
    @MainActor
    func test_endReading_newerSeek_yieldsWithoutStartingRecovery() async throws {
        // Arrange — an actual seek advances the host generation during the suspended reading.
        let host = NativeAVPlayerHost()
        defer {
            host.prematureEndReadForTesting = nil
            host.tearDown()
        }
        host.prematureEndUptimeForTesting = 100_000_000_000
        host.preparePrematureEndForTesting(duration: 127.039, playhead: 60.008, peak: nil)
        host.prematureEndReadForTesting = {
            _ = await host.seek(to: 20, deadlineSeconds: 0.05)
            return PrematureEndReading(playhead: 60.008, seekableEnd: 127.039, loadedEnd: 60)
        }

        // Act — resume the end recovery after the newer seek has taken ownership.
        let suppressed = await host.recoverFromPrematureEndForTesting()

        // Assert — suppress the old notification rather than seeking again or accepting its end.
        #expect(suppressed)
        #expect(host.prematureEndAttemptsForTesting == 0)
        #expect(!host.didReachEnd)
    }

}
