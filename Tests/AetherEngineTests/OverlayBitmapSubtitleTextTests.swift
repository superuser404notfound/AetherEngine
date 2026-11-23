import Testing
import Foundation
import CoreGraphics
import Combine
@testable import AetherEngine

// AE#1114: with `recognizesBitmapSubtitleText` on, the overlay's bitmap cues come back republished
// with the text Vision read in them. Vision is stood in for through the engine's seam: these tests
// are about where the text lands and when it must not, not about the OS's model cache.

private final class RecognizerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String?] = []
    private var gate: DispatchSemaphore?
    private var enteredCount = 0

    init(blocking: Bool = false) {
        gate = blocking ? DispatchSemaphore(value: 0) : nil
    }

    var callCount: Int { lock.withLock { calls.count } }
    var languages: [String?] { lock.withLock { calls } }
    var entered: Int { lock.withLock { enteredCount } }

    func release() { gate?.signal() }

    func recognizer(text: String) -> @Sendable (CGImage, String?) -> SubtitleRecognizedText {
        { [self] _, language in
            lock.withLock {
                calls.append(language)
                enteredCount += 1
            }
            gate?.wait()
            return SubtitleRecognizedText(
                lines: [.init(text: text, confidence: 1, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6))],
                language: language, level: .accurate)
        }
    }
}

private func picture(width: Int = 40, height: Int = 10) -> CGImage {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

private func bitmapCue(_ id: Int, _ start: Double, _ end: Double,
                       position: CGRect = CGRect(x: 0.2, y: 0.8, width: 0.6, height: 0.1),
                       width: Int = 40) -> SubtitleCue {
    SubtitleCue(id: id, startTime: start, endTime: end,
                body: .image(SubtitleImage(cgImage: picture(width: width), position: position)))
}

@MainActor
private func engine(recognizing: Bool, probe: RecognizerProbe, text: String = "HELLO") throws -> AetherEngine {
    let engine = try AetherEngine()
    var options = LoadOptions()
    options.recognizesBitmapSubtitleText = recognizing
    engine.setLoadedOptionsForTesting(options)
    engine.bitmapTextRecognizerForTesting = probe.recognizer(text: text)
    return engine
}

@Suite("AE#1114 overlay bitmap subtitle text", .serialized, .timeLimit(.minutes(3)))
struct Issue1114OverlayBitmapTextTests {

    @MainActor
    @Test("off by default: publishing a bitmap cue starts no recognition")
    func offByDefault() throws {
        #expect(LoadOptions().recognizesBitmapSubtitleText == false)
        let probe = RecognizerProbe()
        let engine = try engine(recognizing: false, probe: probe)
        engine.subtitleCues = [bitmapCue(1, 10, 12)]
        #expect(engine.bitmapTextRecognitionTask == nil)
        #expect(engine.subtitleCues[0].recognizedText == nil)
        #expect(probe.callCount == 0)
    }

    @MainActor
    @Test("on: every bitmap cue is republished with its text, in start order, text cues untouched")
    func readsEveryBitmapCue() async throws {
        let probe = RecognizerProbe()
        let engine = try engine(recognizing: true, probe: probe)
        let text = SubtitleCue(id: 2, startTime: 11, endTime: 13, body: .text("plain"))
        engine.subtitleCues = [bitmapCue(1, 10, 12), text, bitmapCue(3, 14, 16, width: 50)]
        let before = engine.subtitleCues

        try await waitFor { engine.subtitleCues.allSatisfy { $0.text != nil || $0.recognizedText != nil } }
        #expect(engine.subtitleCues[0].recognizedText?.text == "HELLO")
        #expect(engine.subtitleCues[2].recognizedText?.lines.first?.confidence == 1)
        #expect(engine.subtitleCues[1].recognizedText == nil)
        #expect(probe.callCount == 2)
        // Same id, same window: only the text tells a host the cue changed.
        #expect(engine.subtitleCues[0].id == before[0].id)
        #expect(engine.subtitleCues[0] != before[0], "a republish with text must not compare equal")
        try await waitFor { engine.bitmapTextRecognitionTask == nil }
    }

    @MainActor
    @Test("the secondary channel is read too, and the earlier cue of the two goes first")
    func secondaryChannel() async throws {
        let probe = RecognizerProbe()
        let engine = try engine(recognizing: true, probe: probe)
        engine.subtitleCues = [bitmapCue(1, 20, 22)]
        engine.secondarySubtitleCues = [bitmapCue(2, 5, 7)]
        let first = try #require(engine.nextBitmapTextJob(pending: []))
        #expect(first.channel == .secondary)
        try await waitFor {
            engine.subtitleCues[0].recognizedText != nil && engine.secondarySubtitleCues[0].recognizedText != nil
        }
    }

    @MainActor
    @Test("the track language goes to Vision as its alpha-2 code")
    func passesTrackLanguage() async throws {
        let probe = RecognizerProbe()
        let engine = try engine(recognizing: true, probe: probe)
        engine.subtitleTracks = [TrackInfo(id: 4, name: "German", codec: "hdmv_pgs_subtitle", language: "ger", isDefault: false)]
        engine.activeSubtitleTrackIndex = 4
        engine.subtitleCues = [bitmapCue(1, 10, 12)]
        try await waitFor { engine.subtitleCues[0].recognizedText != nil }
        #expect(probe.languages == ["de"])
    }

    /// A seek rebuilds the overlay decoder, and its backscan re-decodes a retained picture under a
    /// new id. A reading that was in flight for the old id still belongs to that picture.
    @MainActor
    @Test("a reading lands on the re-decoded picture that replaced its cue")
    func landsOnReplacedCue() async throws {
        let probe = RecognizerProbe(blocking: true)
        let engine = try engine(recognizing: true, probe: probe)
        engine.subtitleCues = [bitmapCue(1, 10, 12)]
        try await waitFor { probe.entered == 1 }

        var cues = engine.subtitleCues
        var nextID = 50
        AetherEngine.insertCueSorted(bitmapCue(99, 10, 12), into: &cues, nextID: &nextID)
        #expect(cues.count == 1 && cues[0].id == 50)
        engine.subtitleCues = cues

        probe.release()
        try await waitFor { engine.subtitleCues[0].recognizedText != nil }
        #expect(engine.subtitleCues[0].id == 50)
        #expect(probe.callCount == 1, "the replacement must not be read a second time")
    }

    @MainActor
    @Test("a reading whose track was switched away writes nothing")
    func trackSwitchDropsReading() async throws {
        let probe = RecognizerProbe(blocking: true)
        let engine = try engine(recognizing: true, probe: probe)
        engine.activeSubtitleTrackIndex = 3
        engine.subtitleCues = [bitmapCue(1, 10, 12)]
        try await waitFor { probe.entered == 1 }

        // The new track happens to carry a picture with the same start, place and size.
        engine.activeSubtitleTrackIndex = 4
        engine.subtitleCues = [bitmapCue(7, 10, 12)]
        probe.release()
        // The loop goes on to read the new track's picture for itself.
        try await waitFor { probe.entered == 2 }
        probe.release()
        try await waitFor { engine.subtitleCues[0].recognizedText != nil }
        #expect(probe.callCount == 2)
    }

    @MainActor
    @Test("stop drops a reading still in flight")
    func stopDropsReading() async throws {
        let probe = RecognizerProbe(blocking: true)
        let engine = try engine(recognizing: true, probe: probe)
        engine.subtitleCues = [bitmapCue(1, 10, 12)]
        try await waitFor { probe.entered == 1 }
        let cues = engine.subtitleCues
        engine.resetBitmapTextRecognition()
        // A cue array that survives the reset (as across a session-preserving reload) must not
        // receive the old session's result.
        engine.setLoadedOptionsForTesting(LoadOptions())
        engine.subtitleCues = cues
        probe.release()
        let landed = try await waitFor(upTo: .milliseconds(500)) { engine.subtitleCues[0].recognizedText != nil }
        #expect(!landed)
    }

    /// A host that shows cues later than their time still draws a cue that ended before the
    /// playhead, so the reading has to reach back as far as the host says it delays.
    @MainActor
    @Test("cues behind the playhead are read inside the delay reach, the on-screen one first")
    func readsBehindWithinDelayReach() throws {
        let probe = RecognizerProbe()
        let engine = try engine(recognizing: false, probe: probe)
        engine.maximumSubtitleDelaySeconds = 10
        engine.subtitleCues = [bitmapCue(1, 20, 22), bitmapCue(2, 41, 43), bitmapCue(3, 44, 46)]
        let behind = try #require(engine.nextBitmapTextJob(pending: [], playhead: 50))
        #expect(behind.cueID == 3, "the latest cue inside the reach goes first among the ones behind")
        let second = try #require(engine.nextBitmapTextJob(pending: [behind], playhead: 50))
        #expect(second.cueID == 2)
        #expect(engine.nextBitmapTextJob(pending: [behind, second], playhead: 50) == nil,
                "20-22 is beyond a 10 s reach")
        engine.subtitleCues.append(bitmapCue(4, 49, 51))
        #expect(engine.nextBitmapTextJob(pending: [], playhead: 50)?.cueID == 4)
    }

    /// #271: each publication makes every consumer walk the whole array. A burst of readings (the
    /// lead window at selection) must not cost one each.
    @MainActor
    @Test("a burst of readings is written back in batches, not one publication per cue")
    func batchesWriteBack() async throws {
        let probe = RecognizerProbe()
        let engine = try engine(recognizing: true, probe: probe)
        var publications = 0
        let watch = engine.$subtitleCues.sink { cues in
            if cues.contains(where: { $0.recognizedText != nil }) { publications += 1 }
        }
        defer { watch.cancel() }
        engine.subtitleCues = (0..<20).map { bitmapCue($0, 10 + Double($0) * 3, 12 + Double($0) * 3) }
        try await waitFor { engine.subtitleCues.allSatisfy { $0.recognizedText != nil } }
        #expect(probe.callCount == 20)
        #expect(publications < 20, "\(publications) publications for 20 readings")
    }

    @MainActor
    @Test("a publication with nothing to read starts no task")
    func noTaskWithoutBitmaps() throws {
        let probe = RecognizerProbe()
        let engine = try engine(recognizing: true, probe: probe)
        engine.subtitleCues = [SubtitleCue(id: 1, startTime: 10, endTime: 12, body: .text("caption"))]
        #expect(engine.bitmapTextRecognitionTask == nil)
    }

    /// Two URL-only sidecars in a row have no track id, and a freed source's address can come back
    /// for its successor. The install count tells them apart.
    @MainActor
    @Test("a reading from a replaced sidecar writes nothing")
    func replacedSidecarDropsReading() async throws {
        let probe = RecognizerProbe(blocking: true)
        let engine = try engine(recognizing: true, probe: probe)
        engine.subtitleCues = [bitmapCue(1, 10, 12)]
        try await waitFor { probe.entered == 1 }
        engine.sidecarBitmapSourceEpochs[.primary, default: 0] &+= 1
        engine.subtitleCues = [bitmapCue(7, 10, 12)]
        probe.release()
        try await waitFor { probe.entered == 2 }
        probe.release()
        try await waitFor { engine.subtitleCues[0].recognizedText != nil }
        #expect(probe.callCount == 2)
    }

    @Test("pieces on one baseline are one line, read left to right")
    func baselineGrouping() {
        let lines = SubtitleImageOCR.recognizedLines([
            .init(text: "- No.", confidence: 0.5, visionBox: CGRect(x: 0.6, y: 0.11, width: 0.3, height: 0.3)),
            .init(text: "- Yes.", confidence: 1, visionBox: CGRect(x: 0.1, y: 0.10, width: 0.3, height: 0.3)),
            .init(text: "Above", confidence: 1, visionBox: CGRect(x: 0.2, y: 0.6, width: 0.6, height: 0.3)),
        ])
        #expect(lines.map(\.text) == ["Above", "- Yes. - No."])
        #expect(lines[1].confidence == 0.5)
        #expect(lines[1].boundingBox.minX.isApproximately(0.1))
        #expect(lines[1].boundingBox.maxX.isApproximately(0.9))
    }

    @Test("a re-decoded picture keeps the text its predecessor already had")
    func replaceCarriesText() {
        let read = SubtitleRecognizedText(lines: [.init(text: "kept", confidence: 0.5, boundingBox: .zero)],
                                          language: "en", level: .fast)
        let original = bitmapCue(1, 10, 12)
        guard case .image(let image) = original.body else { Issue.record("not a picture"); return }
        var cues = [original.with(body: .image(image.with(recognizedText: read)))]
        var nextID = 10
        AetherEngine.insertCueSorted(bitmapCue(2, 10, 12), into: &cues, nextID: &nextID)
        #expect(cues.count == 1)
        #expect(cues[0].id == 10)
        #expect(cues[0].recognizedText == read)
    }

    @Test("lines read top first, blanks drop, boxes move to a top-left origin")
    func lineGeometry() {
        let lines = SubtitleImageOCR.recognizedLines([
            .init(text: " bottom ", confidence: 0.5, visionBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3)),
            .init(text: "  ", confidence: 1, visionBox: CGRect(x: 0, y: 0.9, width: 1, height: 0.1)),
            .init(text: "top", confidence: 1, visionBox: CGRect(x: 0.2, y: 0.6, width: 0.6, height: 0.3)),
        ])
        #expect(lines.map(\.text) == ["top", "bottom"])
        #expect(lines[0].boundingBox.minY.isApproximately(0.1))
        #expect(lines[1].boundingBox.minY.isApproximately(0.6))
        #expect(lines[1].confidence == 0.5)
        #expect(SubtitleRecognizedText(lines: lines, language: nil, level: .accurate).text == "top\nbottom")
        #expect(SubtitleRecognizedText(lines: [], language: nil, level: .fast).text == nil)
    }
}

private extension CGFloat {
    func isApproximately(_ other: CGFloat) -> Bool { abs(self - other) < 1e-9 }
}
