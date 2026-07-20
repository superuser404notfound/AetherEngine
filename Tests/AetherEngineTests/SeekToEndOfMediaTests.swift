import Testing
@testable import AetherEngine

/// Covers the seek-to-end-of-media park + replay contract (AetherEngine#164).
///
/// A programmatic `seek(to: duration)` never fires `AVPlayerItem.didPlayToEndTime` (that is
/// organic-forward-playback only), so before this change the seek settled to a phantom `.playing`
/// while AVPlayer sat frozen on the final frame, and `play()` / `togglePlayPause()` could not revive
/// it. The fix parks a VOD scrubbed to its end at `.paused` (honest, non-terminal, scrubber stays
/// live) and rewinds to the start on the next `play()` / `togglePlayPause()`.
///
/// `.ended` (organic completion, #63) is deliberately untouched: it stays terminal so a play press
/// racing the host's end card / next-episode countdown cannot silently restart a finished session.
@Suite("Seek to end-of-media park + replay (#164)")
struct SeekToEndOfMediaTests {

    // MARK: - isAtEndOfMedia

    @Test("At-end is true at the exact duration and past it")
    func atEndAtOrPastDuration() {
        #expect(AetherEngine.isAtEndOfMedia(currentTime: 100, duration: 100, isLive: false))
        #expect(AetherEngine.isAtEndOfMedia(currentTime: 101, duration: 100, isLive: false))
    }

    @Test("At-end absorbs the sub-frame gap below the duration")
    func atEndWithinEpsilon() {
        // A scrub-to-end target / frame-granular clock can land just short of the declared duration.
        #expect(AetherEngine.isAtEndOfMedia(currentTime: 99.8, duration: 100, isLive: false))
    }

    @Test("At-end is false a comfortable margin before the end")
    func notAtEndMidStream() {
        #expect(!AetherEngine.isAtEndOfMedia(currentTime: 50, duration: 100, isLive: false))
        // A deliberate pause a second before the credits is not "at end".
        #expect(!AetherEngine.isAtEndOfMedia(currentTime: 98.5, duration: 100, isLive: false))
    }

    @Test("At-end is false for live sources (no fixed end)")
    func notAtEndWhenLive() {
        #expect(!AetherEngine.isAtEndOfMedia(currentTime: 100, duration: 100, isLive: true))
    }

    @Test("At-end is false when duration is unknown (zero)")
    func notAtEndWhenDurationUnknown() {
        #expect(!AetherEngine.isAtEndOfMedia(currentTime: 0, duration: 0, isLive: false))
    }

    // MARK: - seekEndParkState

    @Test("A VOD seek landing at end-of-media parks .paused")
    func seekEndParkParksPaused() {
        #expect(AetherEngine.seekEndParkState(target: 100, duration: 100, isLive: false) == .paused)
    }

    @Test("A mid-stream seek keeps the normal landing reconcile (nil)")
    func seekMidStreamKeepsReconcile() {
        #expect(AetherEngine.seekEndParkState(target: 42, duration: 100, isLive: false) == nil)
    }

    @Test("A live seek never parks (nil)")
    func liveSeekNeverParks() {
        #expect(AetherEngine.seekEndParkState(target: 100, duration: 100, isLive: true) == nil)
    }

    // MARK: - shouldRewindBeforePlay

    @Test("Rewind before play when parked at end-of-media")
    func rewindWhenParkedAtEnd() {
        #expect(AetherEngine.shouldRewindBeforePlay(state: .paused, currentTime: 100, duration: 100, isLive: false))
        #expect(AetherEngine.shouldRewindBeforePlay(state: .playing, currentTime: 100, duration: 100, isLive: false))
    }

    @Test(".ended never rewinds (terminal, #63 end-card must not be revived)")
    func endedNeverRewinds() {
        #expect(!AetherEngine.shouldRewindBeforePlay(state: .ended, currentTime: 100, duration: 100, isLive: false))
    }

    @Test("No rewind mid-stream or when live")
    func noRewindMidStreamOrLive() {
        #expect(!AetherEngine.shouldRewindBeforePlay(state: .paused, currentTime: 50, duration: 100, isLive: false))
        #expect(!AetherEngine.shouldRewindBeforePlay(state: .paused, currentTime: 100, duration: 100, isLive: true))
    }

    // MARK: - Integration: real seek() / play() paths (no hosts)

    @MainActor
    @Test("seek(to: duration) parks .paused instead of a phantom .playing")
    func seekToEndParksPaused() async throws {
        let engine = try AetherEngine()
        engine.duration = 100
        engine.state = .playing
        await engine.seek(to: 100)
        #expect(engine.state == .paused)
        #expect(engine.currentTime == 100)
    }

    @MainActor
    @Test("A mid-stream seek still settles .playing")
    func seekMidStreamStaysPlaying() async throws {
        let engine = try AetherEngine()
        engine.duration = 100
        engine.state = .playing
        await engine.seek(to: 50)
        #expect(engine.state == .playing)
        #expect(engine.currentTime == 50)
    }

    @MainActor
    @Test("play() after an end-of-media park rewinds to 0 and resumes")
    func playAfterEndParkRewinds() async throws {
        let engine = try AetherEngine()
        engine.duration = 100
        engine.state = .playing
        await engine.seek(to: 100)
        #expect(engine.state == .paused)

        engine.play()
        // play() dispatches the rewind on a MainActor Task; yield until it lands (no wall-clock wait).
        var spins = 0
        while engine.currentTime != 0 && spins < 200 {
            await Task.yield()
            spins += 1
        }
        #expect(engine.currentTime == 0)
        #expect(engine.state == .playing)
    }

    @MainActor
    @Test("play() at .ended stays terminal, no rewind (#63)")
    func playWhenEndedStaysTerminal() async throws {
        let engine = try AetherEngine()
        engine.duration = 100
        engine.state = .ended
        engine.play()
        await Task.yield()
        #expect(engine.state == .ended)
    }
}
