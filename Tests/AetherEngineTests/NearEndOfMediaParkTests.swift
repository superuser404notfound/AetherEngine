// End-of-media tail-park completion (AetherEngine#169).
//
// A long loopback-HLS VOD's FINAL segment advertises an EXTINF derived from the container duration
// (`sourceDurationSeconds`), which overshoots the last real video sample when the audio track runs a
// few frames longer or the container duration is rounded up. The final segment serves and plays, but
// the video renderer has no frame for the last fraction of a second, so AVPlayer parks in
// WaitingToMinimizeStalls ~0.1 s from the advertised end, never fires didPlayToEndTime, and after ~43 s
// dies with CoreMediaErrorDomain -12889. The engine detects this tail park from its 1 Hz native tick
// and synthesizes organic end-of-media so the session finishes cleanly (mark-watched / autoplay-next)
// instead of hanging then erroring.
//
// These pure cases pin the discriminator: a genuine video-exhausted tail (final segment loaded to the
// end, playhead frozen a hair short of duration, waiting to minimize stalls) qualifies; a live source,
// an actually-playing item, a deliberate pause, a mid-stream position, or an unfinished final-segment
// download (loadedEnd short of duration = a recoverable network stall) do NOT.
import Foundation
import Testing
@testable import AetherEngine

@Suite("End-of-media tail park (#169)")
struct NearEndOfMediaParkTests {

    // The reporter's exact shape: 48-min DV title, engine.duration 2881.3, park at 2881.202, final
    // segment loaded right to the advertised end.
    let duration = 2881.3
    let parkPlayhead = 2881.202
    let loadedToEnd = 2881.3

    @Test("A video-exhausted tail park with the final segment fully loaded qualifies")
    func qualifiesOnExhaustedTail() {
        #expect(AetherEngine.endOfMediaParkTickQualifies(
            isLive: false,
            duration: duration,
            playhead: parkPlayhead,
            loadedEnd: loadedToEnd,
            waitingToPlay: true,
            minimizingStalls: true))
    }

    @Test("A live source never qualifies (no fixed end to reach)")
    func liveNeverQualifies() {
        #expect(!AetherEngine.endOfMediaParkTickQualifies(
            isLive: true,
            duration: duration,
            playhead: parkPlayhead,
            loadedEnd: loadedToEnd,
            waitingToPlay: true,
            minimizingStalls: true))
    }

    @Test("An actually-playing item does not qualify")
    func playingDoesNotQualify() {
        #expect(!AetherEngine.endOfMediaParkTickQualifies(
            isLive: false,
            duration: duration,
            playhead: parkPlayhead,
            loadedEnd: loadedToEnd,
            waitingToPlay: false,
            minimizingStalls: false))
    }

    @Test("Waiting for a reason other than minimizing stalls does not qualify")
    func otherWaitReasonDoesNotQualify() {
        // e.g. WaitingWhileEvaluatingBufferingRate / no-item-to-play: not the exhausted-video signature.
        #expect(!AetherEngine.endOfMediaParkTickQualifies(
            isLive: false,
            duration: duration,
            playhead: parkPlayhead,
            loadedEnd: loadedToEnd,
            waitingToPlay: true,
            minimizingStalls: false))
    }

    @Test("A mid-stream park (playhead far from the end) does not qualify")
    func midStreamDoesNotQualify() {
        // Symptom 2's resume-into-tail lands at 2878.5, ~2.8 s from the end: outside the end-of-media
        // epsilon, so tail completion must not fire (that path needs producer/readiness handling).
        #expect(!AetherEngine.endOfMediaParkTickQualifies(
            isLive: false,
            duration: duration,
            playhead: 2878.5,
            loadedEnd: 2877.5,
            waitingToPlay: true,
            minimizingStalls: true))
    }

    @Test("An unfinished final-segment download (loadedEnd short of duration) does not qualify")
    func unloadedTailDoesNotQualify() {
        // Resume/seek into the tail (Symptom 2): AVPlayer's currentTime jumps to the target (2881.0,
        // within the end epsilon) before the final segment downloads, so the raw loaded range still ends
        // at the previous boundary (~2877.5). That is a recoverable download-in-progress, not exhausted
        // video; leaving it lets the producer/readiness path serve the final segment.
        #expect(!AetherEngine.endOfMediaParkTickQualifies(
            isLive: false,
            duration: duration,
            playhead: 2881.0,
            loadedEnd: 2877.5,   // final segment not yet loaded; well short of duration - 0.5
            waitingToPlay: true,
            minimizingStalls: true))
    }

    @Test("Frozen-tick count accumulates only while a qualifying tick keeps a frozen playhead")
    func frozenTicksAccumulate() {
        var ticks = 0
        // Three consecutive qualifying, frozen ticks.
        ticks = AetherEngine.endOfMediaParkFrozenTicks(previous: ticks, tickQualifies: true, playheadFrozen: true)
        #expect(ticks == 1)
        ticks = AetherEngine.endOfMediaParkFrozenTicks(previous: ticks, tickQualifies: true, playheadFrozen: true)
        #expect(ticks == 2)
        ticks = AetherEngine.endOfMediaParkFrozenTicks(previous: ticks, tickQualifies: true, playheadFrozen: true)
        #expect(ticks == 3)
    }

    @Test("The frozen-tick count resets when a tick stops qualifying or the playhead advances")
    func frozenTicksReset() {
        // A momentary near-end stall that then resumes (playhead advances) must not accumulate.
        #expect(AetherEngine.endOfMediaParkFrozenTicks(previous: 2, tickQualifies: true, playheadFrozen: false) == 0)
        // Conditions no longer hold (e.g. recovered to playing).
        #expect(AetherEngine.endOfMediaParkFrozenTicks(previous: 2, tickQualifies: false, playheadFrozen: true) == 0)
    }

    @Test("End-of-media is synthesized only after the grace threshold of frozen ticks")
    func synthesizesAfterGrace() {
        #expect(!AetherEngine.shouldSynthesizeEndOfMediaFromPark(frozenTicks: 0))
        #expect(!AetherEngine.shouldSynthesizeEndOfMediaFromPark(frozenTicks: AetherEngine.endOfMediaParkGraceTicks - 1))
        #expect(AetherEngine.shouldSynthesizeEndOfMediaFromPark(frozenTicks: AetherEngine.endOfMediaParkGraceTicks))
        #expect(AetherEngine.shouldSynthesizeEndOfMediaFromPark(frozenTicks: AetherEngine.endOfMediaParkGraceTicks + 1))
    }
}
