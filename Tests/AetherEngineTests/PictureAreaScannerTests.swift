import CoreGraphics
import Foundation
import Testing
@testable import AetherEngine

/// Scripted still source: a frame per timestamp window, yields on demand, and a record of every ask.
private actor ScriptedStills: StillSource {
    var asked: [Double] = []
    private let frameAt: @Sendable (Double) -> CGImage?
    private var yieldsLeft: [Double: Int]

    init(yields: [Double: Int] = [:], frameAt: @escaping @Sendable (Double) -> CGImage?) {
        self.frameAt = frameAt
        self.yieldsLeft = yields
    }

    func thumbnailOutcome(at seconds: Double, maxWidth: Int) async -> StillOutcome {
        asked.append(seconds)
        let key = (seconds * 1000).rounded() / 1000
        if let n = yieldsLeft[key], n > 0 {
            yieldsLeft[key] = n - 1
            return .yielded
        }
        guard let image = frameAt(seconds) else { return .unavailable }
        return .image(image)
    }
}

private let scope = SyntheticFrame.make(picture: SyntheticFrame.centred(ratio: 2.39))
private let fullPicture = SyntheticFrame.make(picture: CGRect(x: 0, y: 0, width: 1, height: 1))
private let dark = SyntheticFrame.make(picture: CGRect(x: 0, y: 0, width: 1, height: 1), pictureLuma: 0.02)

@Suite("Picture area scanner")
struct PictureAreaScannerTests {
    private let aspect = 16.0 / 9.0

    @Test("the first pass samples twelve points from 10 % to 90 % (Sodalite#118)", .timeLimit(.minutes(3)))
    func firstPassSamplesTwelveEvenly() async throws {
        let stills = ScriptedStills { _ in scope }
        let scanner = PictureAreaScanner(source: stills, duration: 1100, displayAspect: aspect)
        let area = try #require(await scanner.firstPass())
        // 2.39 and 2.40 are one row apart at the analysis height; either is the right zoom.
        #expect(area.snappedRatio.map { (2.39...2.40).contains($0) } == true)
        let asked = await stills.asked
        #expect(asked.count == 12)
        #expect(abs(asked.first! - 110) < 0.001)
        #expect(abs(asked.last! - 990) < 0.001)
        #expect(abs(asked[1] - 190) < 0.001)
    }

    @Test("a yielded sample is asked again (Sodalite#118)", .timeLimit(.minutes(3)))
    func yieldedSamplesAreRetried() async throws {
        let stills = ScriptedStills(yields: [110: 2]) { _ in scope }
        let scanner = PictureAreaScanner(source: stills, duration: 1100, displayAspect: aspect,
                                         retryDelay: .milliseconds(10))
        _ = try #require(await scanner.firstPass())
        let asked = await stills.asked
        #expect(asked.filter { abs($0 - 110) < 0.001 }.count == 3)
    }

    @Test("a seed skips the first pass (Sodalite#118)", .timeLimit(.minutes(3)))
    func seedSkipsFirstPass() async throws {
        let stills = ScriptedStills { _ in scope }
        let seed = PictureArea(rect: SyntheticFrame.centred(ratio: 2.39), snappedRatio: 2.39)
        let scanner = PictureAreaScanner(source: stills, duration: 1100, displayAspect: aspect, seed: seed)
        #expect(await scanner.firstPass() == seed)
        #expect(await stills.asked.isEmpty)
    }

    @Test("the look-ahead widens the area before the playhead reaches the wider passage (Sodalite#118)",
          .timeLimit(.minutes(3)))
    func advanceWidensBeforePlayheadArrives() async throws {
        let stills = ScriptedStills { t in (600...640).contains(t) ? fullPicture : scope }
        let scanner = PictureAreaScanner(source: stills, duration: 1100, displayAspect: aspect)
        _ = try #require(await scanner.firstPass())
        var widened: PictureArea?
        for _ in 0..<8 where widened == nil {
            widened = await scanner.advance(playhead: 450)
        }
        let area = try #require(widened)
        #expect(area.isFullFrame)
        let asked = await stills.asked.dropFirst(12)
        #expect(asked.allSatisfy { $0 > 450 && $0 <= 630 })
    }

    @Test("the look-ahead never narrows the area (Sodalite#118)", .timeLimit(.minutes(3)))
    func advanceNeverNarrows() async throws {
        let narrower = SyntheticFrame.make(picture: SyntheticFrame.centred(ratio: 2.76))
        let stills = ScriptedStills { t in t < 1000 ? scope : narrower }
        let scanner = PictureAreaScanner(source: stills, duration: 1100, displayAspect: aspect)
        let first = try #require(await scanner.firstPass())
        for _ in 0..<4 { #expect(await scanner.advance(playhead: 990) == nil) }
        #expect(await scanner.current == first)
        #expect(await stills.asked.contains { $0 > 1000 })
    }

    @Test("a full-frame area stops the look-ahead (Sodalite#118)", .timeLimit(.minutes(3)))
    func stopsAtFullFrame() async throws {
        let stills = ScriptedStills { _ in fullPicture }
        let scanner = PictureAreaScanner(source: stills, duration: 1100, displayAspect: aspect)
        #expect(await scanner.firstPass()?.isFullFrame == true)
        #expect(await scanner.advance(playhead: 100) == nil)
        #expect(await stills.asked.count == 12)
    }

    @Test("a dark first pass gives no answer, the look-ahead finishes the job (Sodalite#118)", .timeLimit(.minutes(3)))
    func lookAheadCompletesAfterThinFirstPass() async throws {
        // Three usable first-pass frames (the last three), the rest dark until 1000 s.
        let stills = ScriptedStills { t in t >= 750 ? scope : dark }
        let scanner = PictureAreaScanner(source: stills, duration: 1100, displayAspect: aspect)
        #expect(await scanner.firstPass() == nil)
        var area: PictureArea?
        for step in 0..<12 where area == nil {
            area = await scanner.advance(playhead: 700 + Double(step) * 10)
        }
        #expect(area?.snappedRatio.map { (2.39...2.40).contains($0) } == true)
    }

    @Test("cancelling the task ends the first pass (Sodalite#118)", .timeLimit(.minutes(3)))
    func cancellationStopsFirstPass() async throws {
        let stills = ScriptedStills(yields: [110: 1_000_000]) { _ in scope }
        let scanner = PictureAreaScanner(source: stills, duration: 1100, displayAspect: aspect,
                                         retryDelay: .milliseconds(5))
        let task = Task { await scanner.firstPass() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
    }
}
