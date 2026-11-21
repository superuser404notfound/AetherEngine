import Testing
@testable import AetherEngine

/// #853: the decision half of the inverse telecine probe, on hand-made sample sequences. Film needs both
/// signals: `idet` progressive after matching AND the repeated frame of each five at a steady phase.
/// Either alone is fooled by real material (a still stretch of video reads progressive; video with a
/// near-duplicate frame now and then has low differences), which is what the cases below pin.
@Suite("Telecine cadence decision")
struct TelecineCadenceAnalyzerTests {

    private typealias Analyzer = TelecineCadenceAnalyzer
    private typealias Sample = TelecineCadenceAnalyzer.Sample

    /// Deterministic noise in [0, 1) so the "video" sequences are irregular but repeatable.
    private struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Matched film: every frame progressive, one frame per five repeats its neighbour (low difference)
    /// at `phase`.
    private func film(_ count: Int, phase: Int = 2, moving: Double = 3.0, repeated: Double = 0.4,
                      startIndex: Int = 0) -> [Sample] {
        (0..<count).map { i in
            Sample(fieldClass: .progressive, difference: (startIndex + i) % 5 == phase ? repeated : moving)
        }
    }

    private func analyzer(_ samples: [Sample]) -> Analyzer {
        var a = Analyzer()
        for s in samples { a.append(s) }
        return a
    }

    /// The first index at which `.start` decides, and what.
    private func adaptive(_ samples: [Sample]) -> (index: Int, decision: Analyzer.Decision)? {
        var a = Analyzer()
        for (i, s) in samples.enumerated() {
            a.append(s)
            if let (decision, _) = a.adaptiveDecision() { return (i, decision) }
        }
        return nil
    }

    @Test("clean film decides as soon as the trailing window holds its decided frames")
    func cleanFilmDecidesAtTheWindow() {
        let decided = adaptive(film(200))
        #expect(decided?.decision == .film)
        #expect(decided?.index == Analyzer.decidedWindow - 1)
    }

    @Test("film behind a black opening and a fade made at video rate still decides, after the fade")
    func filmAfterBlackAndFade() {
        // Measured shape of a Friends S1 opening: ~1 s black (undetermined, no motion), a fade-in that
        // stays combed after matching, then film.
        var samples = (0..<29).map { _ in Sample(fieldClass: .undetermined, difference: 0) }
        samples += (0..<14).map { _ in Sample(fieldClass: .interlaced, difference: 1.5) }
        samples += film(200, startIndex: 43)
        let decided = adaptive(samples)
        #expect(decided?.decision == .film)
        #expect((decided?.index ?? 0) > 43, "never on the fade itself")
        #expect((decided?.index ?? .max) < 43 + 140, "within a few cycles of the window filling with film")
    }

    @Test("a short stretch of combed frames inside film does not stop the decision")
    func filmWithATitleOverlay() {
        var samples = film(60)
        samples += (0..<10).map { _ in Sample(fieldClass: .interlaced, difference: 2.5) }
        samples += film(140, startIndex: 70)
        #expect(adaptive(samples)?.decision == .film)
    }

    @Test("a cadence break at an edit costs one pair, not the decision")
    func cadenceBreakAtAnEdit() {
        let samples = film(100, phase: 2) + film(100, phase: 4, startIndex: 100)
        #expect(adaptive(samples)?.decision == .film)
    }

    @Test("realistic interlaced video (still stretches that match) never reads as film")
    func realisticVideoIsNeverFilm() {
        // Measured shape of interlaced video made from a sitcom scene: half the frames read progressive
        // after matching (long still runs), and the lowest difference of a cycle wanders.
        var noise = Noise()
        var samples: [Sample] = []
        for block in 0..<10 {
            let still = block % 2 == 0
            for _ in 0..<30 {
                samples.append(Sample(fieldClass: still ? .progressive : .interlaced,
                                      difference: (still ? 0.8 : 2.0) + noise.next()))
            }
        }
        #expect(adaptive(samples)?.decision != .film)
        #expect(analyzer(samples).finalDecision().0 == .video)
    }

    @Test("a fully still video sample reads progressive but has no cadence, so it is not film")
    func stillVideoIsNotFilm() {
        var noise = Noise()
        let samples = (0..<300).map { _ in Sample(fieldClass: .progressive, difference: 1.0 + 0.2 * noise.next()) }
        #expect(adaptive(samples)?.decision != .film)
        #expect(analyzer(samples).finalDecision().0 != .film)
    }

    @Test("video whose near-duplicates fall at random phases is not film")
    func randomDuplicatesAreNotACadence() {
        var noise = Noise()
        let samples = (0..<300).map { _ -> Sample in
            let duplicate = noise.next() < 0.2
            return Sample(fieldClass: .progressive, difference: duplicate ? 0.3 : 3.0 + noise.next())
        }
        let e = analyzer(samples).evidence(from: 0)
        #expect(e.cadenceShare < Analyzer.filmCadenceShare, "\(e)")
        #expect(adaptive(samples)?.decision != .film)
    }

    @Test("overwhelmingly combed video with no cadence decides early as video")
    func combedVideoDecidesEarly() {
        let samples = (0..<200).map { i in Sample(fieldClass: .interlaced, difference: 3.0 + Double(i % 3)) }
        let decided = adaptive(samples)
        #expect(decided?.decision == .video)
        #expect(decided?.index == Analyzer.decidedWindow - 1)
    }

    @Test("video where every frame moves and none repeats decides early, even when it reads progressive")
    func progressiveVideoWithoutCadenceDecidesEarly() {
        var noise = Noise()
        let samples = (0..<300).map { _ in Sample(fieldClass: .progressive, difference: 12.0 + 4 * noise.next()) }
        let decided = adaptive(samples)
        #expect(decided?.decision == .video)
        #expect((decided?.index ?? .max) < 120, "20 cycles of motion, not the whole ceiling")
    }

    @Test("quiet film whose repeats drown in noise is not called video early")
    func quietFilmIsNotVideoEarly() {
        // S01E12 from 5:00: low motion and grain, so the repeat is not clear (lowest about 6, next about
        // 10) and no cycle shows motion in every frame. It must keep reading, never decide video.
        var noise = Noise()
        let samples = (0..<300).map { i in
            Sample(fieldClass: .progressive, difference: i % 5 == 2 ? 5.5 + noise.next() : 9.0 + 2 * noise.next())
        }
        #expect(adaptive(samples)?.decision != .video)
    }

    @Test("too few decided frames is no evidence either way")
    func shortSampleIsUndecided() {
        let samples = film(40)
        #expect(adaptive(samples) == nil)
        guard case .undecided = analyzer(samples).finalDecision().0 else {
            Issue.record("expected .undecided")
            return
        }
    }

    @Test("black and frozen cycles carry no cadence evidence")
    func stillCyclesAreSkipped() {
        let samples = (0..<50).map { _ in Sample(fieldClass: .undetermined, difference: 0) }
        let e = analyzer(samples).evidence(from: 0)
        #expect(e.movingCycles == 0)
        #expect(e.decided == 0)
    }

    @Test("the trailing window starts where the last decided frames it holds begin")
    func trailingWindowSkipsUndetermined() {
        var samples = film(100)
        samples += (0..<20).map { _ in Sample(fieldClass: .undetermined, difference: 0) }
        samples += film(30, startIndex: 120)
        let a = analyzer(samples)
        // 30 decided frames after the gap, so the window reaches back over it for the other 30.
        #expect(Analyzer.decidedWindow == 60)
        #expect(a.trailingWindowStart() == 70)
    }
}
