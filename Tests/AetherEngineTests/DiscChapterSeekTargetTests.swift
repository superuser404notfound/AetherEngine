import Testing
import Foundation
import Combine
@testable import AetherEngine

/// `selectChapter(id:)` turns a title-relative disc chapter into a `seek(to:)` target. On the software
/// route the target is on the session axis (source PTS minus the clock's session zero), and the host adds
/// that zero back before the seek reaches the demuxer. A disc title whose container start is past the 2 s
/// anchor tolerance gets that start as its session zero, so the start must not be added a second time.
/// Pure logic: the container start and the session zero are injected, no media is read.
@Suite("Disc chapter seek target")
struct DiscChapterSeekTargetTests {

    /// What the host does with a session-axis target: carry it back onto the source axis.
    private func hostSourceSeconds(forSession target: Double, zero: Double) -> Double {
        SWClockAnchorPolicy.sourceSeconds(forSession: target, sessionZeroSeconds: zero)
    }

    @Test("A disc title that starts at 600 s lands on the chapter, not one start late")
    func softwareTitlePastToleranceDoesNotShiftTwice() {
        // Start 600 s: the host predicts session zero 600 and reports it.
        let zero = SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: 600)
        #expect(zero == 600)
        let target = PresentationAxis.discChapterSeekTarget(
            chapterStart: 120, backend: .software, sourceStartSeconds: 600,
            playlistShiftSeconds: 0, softwareClockZero: zero)
        #expect(target == 120)
        // The chapter's source PTS is start + 120; the host's conversion reaches exactly it.
        #expect(hostSourceSeconds(forSession: target, zero: zero) == 720)
    }

    @Test("The former rule (add the whole start) overshoots by the start on that title")
    func formerRuleOvershoots() {
        let zero = 600.0
        let formerTarget = 120 + 600.0
        #expect(hostSourceSeconds(forSession: formerTarget, zero: zero) == 1320)
    }

    @Test("A disc title that starts inside the 2 s tolerance keeps the whole start in the target")
    func softwareTitleInsideToleranceAddsStart() {
        // Start 1.4 s: zero stays 0 (the host never reports one), so the session axis is the raw axis.
        let zero = SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: 1.4)
        #expect(zero == 0)
        let target = PresentationAxis.discChapterSeekTarget(
            chapterStart: 120, backend: .software, sourceStartSeconds: 1.4,
            playlistShiftSeconds: 0, softwareClockZero: nil)
        #expect(abs(target - 121.4) < 1e-9)
        #expect(abs(hostSourceSeconds(forSession: target, zero: zero) - 121.4) < 1e-9)
    }

    @Test("A zero not reported yet is predicted from the start, so a selection racing the load is right")
    func nilZeroIsPredictedFromStart() {
        let target = PresentationAxis.discChapterSeekTarget(
            chapterStart: 120, backend: .software, sourceStartSeconds: 600,
            playlistShiftSeconds: 0, softwareClockZero: nil)
        #expect(target == 120)
    }

    @Test("A start inside the tolerance: a nil zero and an explicit zero of 0 give the same target")
    func nilZeroEqualsZero() {
        let nilZero = PresentationAxis.discChapterSeekTarget(
            chapterStart: 30, backend: .software, sourceStartSeconds: 0.28,
            playlistShiftSeconds: 0, softwareClockZero: nil)
        let zeroZero = PresentationAxis.discChapterSeekTarget(
            chapterStart: 30, backend: .software, sourceStartSeconds: 0.28,
            playlistShiftSeconds: 0, softwareClockZero: 0)
        #expect(nilZero == zeroZero)
        #expect(abs(nilZero - 30.28) < 1e-9)
    }

    @Test("The clock's own zero wins when it re-anchored on a first sample past the start")
    func softwareAnchoredZeroPastStart() {
        // Container start 600, first sample at 600.4: still inside the tolerance, zero stays the predicted
        // 600. A late first sample at 603 re-anchors the zero at 603; the chapter then sits 3 s before
        // the zero in session terms and the target stays on the title.
        let target = PresentationAxis.discChapterSeekTarget(
            chapterStart: 120, backend: .software, sourceStartSeconds: 600,
            playlistShiftSeconds: 0, softwareClockZero: 603)
        #expect(target == 117)
        #expect(hostSourceSeconds(forSession: target, zero: 603) == 720)
    }

    @Test("A zero a little past the container start never produces a negative target")
    func targetIsNeverNegative() {
        // The host takes its zero from the video stream's own start, which can sit just past the
        // container start; chapter 1 at 0 would be -0.1 without the floor.
        let target = PresentationAxis.discChapterSeekTarget(
            chapterStart: 0, backend: .software, sourceStartSeconds: 599.9,
            playlistShiftSeconds: 0, softwareClockZero: 600)
        #expect(target == 0)
    }

    @Test("A container with no stated start uses the video stream's start as the origin, like the host")
    func softwareTitleWithNoFormatStart() {
        // The reporter's remote ISO: format start NOPTS, video stream start 54000000 in 1/90000 (600 s).
        // The host predicts zero 600 from the same origin, so the chapter lands on chapter + 600 in
        // source terms, never 600 s early.
        let origin = Demuxer.sourceStartOrigin(
            formatStartUs: Int64.min, videoStreamStart: 54_000_000,
            videoTimeBaseNum: 1, videoTimeBaseDen: 90_000)
        #expect(origin == 600)
        let reported = PresentationAxis.discChapterSeekTarget(
            chapterStart: 120, backend: .software, sourceStartSeconds: origin,
            playlistShiftSeconds: 0, softwareClockZero: 600)
        #expect(reported == 120)
        #expect(hostSourceSeconds(forSession: reported, zero: 600) == 720)
        let predicted = PresentationAxis.discChapterSeekTarget(
            chapterStart: 120, backend: .software, sourceStartSeconds: origin,
            playlistShiftSeconds: 0, softwareClockZero: nil)
        #expect(predicted == reported)
    }

    @Test("A native disc title is seeked on the 0-based display axis, with no base added")
    func nativeTitleUsesDisplayAxis() {
        // The playlist shift of a disc title is its clip 0 base (for example 599 s); the display
        // axis already has it taken off, so the target is the chapter start itself.
        let target = PresentationAxis.discChapterSeekTarget(
            chapterStart: 120, backend: .native, sourceStartSeconds: 599,
            playlistShiftSeconds: 599, softwareClockZero: nil)
        #expect(target == 120)
    }

    @Test("Backends without an established axis keep the playlist shift as their base")
    func otherBackendsKeepPlaylistShift() {
        for backend in [PlaybackBackend.audio, .none] {
            let target = PresentationAxis.discChapterSeekTarget(
                chapterStart: 120, backend: backend, sourceStartSeconds: 600,
                playlistShiftSeconds: 3.5, softwareClockZero: 600)
            #expect(target == 123.5, "backend \(backend)")
        }
    }
}

/// The engine feeds its own state into the same rule.
@Suite("Disc chapter seek target engine wiring", .timeLimit(.minutes(3)))
@MainActor
struct DiscChapterSeekTargetEngineTests {

    @Test("The engine's software state gives the title-relative start when the zero took the container start")
    func engineStateGivesTitleRelativeStart() throws {
        let engine = try AetherEngine()
        engine.playbackBackend = .software
        engine.sourceStartSeconds = 600
        engine.softwareClockSessionZero = 600
        #expect(PresentationAxis.discChapterSeekTarget(
            chapterStart: 45, backend: engine.playbackBackend,
            sourceStartSeconds: engine.sourceStartSeconds,
            playlistShiftSeconds: engine.playlistShiftSeconds,
            softwareClockZero: engine.softwareClockSessionZero) == 45)
    }

    @Test("selectChapter seeks to the title-relative chapter start on a software title")
    func selectChapterDrivesTheHelper() async throws {
        let engine = try AetherEngine()
        engine.playbackBackend = .software
        engine.sourceStartSeconds = 600
        engine.softwareClockSessionZero = 600
        engine.discChapters = [ChapterInfo(id: 3, name: "Chapter 3", startSeconds: 45, durationSeconds: 60)]
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        engine.selectChapter(id: 3)
        // The seek runs in a main-actor task; the idle engine rejects it with the target it was given.
        try await waitFor { !events.isEmpty }

        #expect(events.count == 1)
        #expect(events.first?.outcome == .rejected(.noActiveSession))
        #expect(events.first?.target == 45)
    }
}
