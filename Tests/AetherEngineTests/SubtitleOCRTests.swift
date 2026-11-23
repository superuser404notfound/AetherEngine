import Testing
import Foundation
import CoreGraphics
import CoreText
@testable import AetherEngine

// The fallback tests temporarily change the process-wide accurate-model availability flag.
@Suite("Subtitle image OCR", .serialized, .timeLimit(.minutes(3)))
struct SubtitleOCRTests {
    @Test("track languages normalize to alpha-2 for Vision, unknown tags pass through")
    func languageMapping() {
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "ger") == "de")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "eng") == "en")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "de") == "de")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: nil) == nil)
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "") == nil)
    }

    @Test("flatten produces an opaque black canvas with the source drawn on top")
    func flatten() throws {
        // 2x1 image: left pixel white opaque, right pixel fully transparent.
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let src = ctx.makeImage()!
        let flat = try #require(SubtitleImageOCR.flattenedOntoBlack(src))
        let out = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        out.draw(flat, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let p = out.data!.assumingMemoryBound(to: UInt8.self)
        #expect(p[0] > 200)   // white pixel survives
        #expect(p[4] < 30)    // transparent pixel is now opaque black
    }

    @Test("Vision recognizes clean synthetic subtitle text")
    func visionSynthetic() async throws {
        let width = 480, height = 96
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(kCFAllocatorDefault, "HELLO 123" as CFString, attrs as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 24, y: 28)
        CTLineDraw(line, ctx)
        let image = ctx.makeImage()!
        let recognized = await SubtitleImageOCR.recognizeText(in: image, language: "en")
        let text = try #require(recognized)
        #expect(text.contains("HELLO"))
        #expect(text.contains("123"))
    }

    /// AE#1114: the box a host places the line with has to come out top-left, like the picture's.
    /// Text drawn in the upper half of a tall picture must read as the upper half.
    @Test("a real reading reports lines, the pinned language, and a top-left box")
    func detailedReadingGeometry() async throws {
        let ctx = CGContext(data: nil, width: 480, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(kCFAllocatorDefault, "HELLO 123" as CFString, attrs as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 24, y: 170)   // CoreGraphics: y up, so this is near the top
        CTLineDraw(line, ctx)

        let read = try #require(await SubtitleImageOCR.recognizeDetailed(in: ctx.makeImage()!, language: "en"))
        let first = try #require(read.lines.first, "nothing read")
        #expect(first.text.contains("HELLO"))
        #expect(first.boundingBox.midY < 0.5, "box \(first.boundingBox) is not in the upper half")
        #expect((0...1).contains(first.confidence))
        #expect(read.language == "en")
    }

    /// #552: the accurate model is an OPTIONAL system model. On macOS 27 it spends about a minute
    /// precompiling for the Neural Engine on first use in a process and then throws about half the
    /// time, and a process that has seen it fail once sees it fail forever. Pinned alone, that took
    /// PGS / DVB / DVD subtitles out of PiP, AirPlay and the external display entirely.
    ///
    /// Driven through the seam rather than the weather: a machine whose model works cannot reach
    /// the fallback, and a machine whose model is broken cannot be asked for on demand.
    @Test("a subtitle is still read when the accurate model is unavailable")
    func fallsBackToFastRecognition() async throws {
        SubtitleImageOCR.setAccurateUnavailableForTesting(true)
        defer { SubtitleImageOCR.setAccurateUnavailableForTesting(false) }

        let width = 480, height = 96
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(kCFAllocatorDefault, "HELLO 123" as CFString, attrs as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 24, y: 28)
        CTLineDraw(line, ctx)
        let image = ctx.makeImage()!

        let recognized = await SubtitleImageOCR.recognizeText(in: image, language: "en")
        let text = try #require(recognized,
                                "the fallback read nothing, so the cue would have been dropped")
        #expect(text.contains("HELLO"))
        #expect(text.contains("123"))
        // Deliberately no assertion on how LONG this took, though the cost is half the point of
        // the sticky flag. Measured on this machine, the same test took 0.24 s, then 6.9 s, then
        // 61.4 s across three runs of the same code, because the fast model gets its own Neural
        // Engine precompile on a cold system cache exactly as the accurate one does. A wall clock
        // here measures the OS's cache, not the engine, and any bound over it is a coin toss that
        // fails for reasons that have nothing to do with its subject. What the flag guarantees is
        // structural and is visible in the code instead: with it set, the accurate request is
        // never constructed.
    }

    /// A language the fast model does not speak must not take the line down with it. Vision's fast
    /// list is six languages; the accurate one is thirty-three.
    @Test("a language the fallback does not support drops the pin, not the line")
    func fallbackDropsUnsupportedLanguagePin() async throws {
        SubtitleImageOCR.setAccurateUnavailableForTesting(true)
        defer { SubtitleImageOCR.setAccurateUnavailableForTesting(false) }

        let ctx = CGContext(data: nil, width: 480, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(kCFAllocatorDefault, "HELLO 123" as CFString, attrs as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 24, y: 28)
        CTLineDraw(line, ctx)

        // Japanese: on the accurate list, not on the fast one.
        let text = await SubtitleImageOCR.recognizeText(in: ctx.makeImage()!, language: "ja")
        #expect(text?.contains("HELLO") == true,
                "an unsupported language pin took the whole recognition down: \(text ?? "nil")")
    }
}

@Suite("Subtitle recognition executor", .timeLimit(.minutes(3)))
struct SubtitleOCRExecutorTests {
    @Test("a blocked recognition leaves the cooperative executor free")
    func blockedRecognitionAllowsProgress() async throws {
        let executor = SubtitleImageOCR.Executor()
        let entered = AtomicBool(false)
        let onTask = AtomicBool(true)
        let onMain = AtomicBool(true)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let recognition = Task {
            await executor.run {
                onTask.set(withUnsafeCurrentTask { $0 != nil })
                onMain.set(Thread.isMainThread)
                entered.set(true)
                release.wait()
                return "recognized"
            }
        }
        defer { recognition.cancel() }
        try await waitFor { entered.get() }
        #expect(!onTask.get(), "Vision must not synchronously occupy a Swift task's executor")
        #expect(!onMain.get())
        release.signal()
        #expect(await recognition.value == "recognized")
    }

    @Test("cancellation keeps active admission occupied and removes queued work")
    func cancellationKeepsAdmissionUntilNativeReturn() async throws {
        let executor = SubtitleImageOCR.Executor()
        let entered = AtomicBool(false)
        let queuedRan = AtomicBool(false)
        let replacementRan = AtomicBool(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let recognition = Task {
            await executor.run {
                entered.set(true)
                release.wait()
                return "completed cue"
            }
        }
        defer { recognition.cancel() }
        try await waitFor { entered.get() }
        let queued = Task {
            await executor.run { queuedRan.set(true); return "cancelled cue" }
        }
        defer { queued.cancel() }
        try await waitFor { await executor.pendingCount == 1 }
        queued.cancel()
        #expect(await queued.value == nil)
        #expect(!queuedRan.get())
        recognition.cancel()
        let replacement = Task {
            await executor.run { replacementRan.set(true); return "replacement" }
        }
        defer { replacement.cancel() }
        try await waitFor { await executor.pendingCount == 1 }
        #expect(!replacementRan.get(), "cancellation must not free a running native operation's slot")
        release.signal()
        #expect(await recognition.value == "completed cue")
        #expect(await replacement.value == "replacement")
    }

    @Test("concurrent callers never overlap native recognition")
    func concurrentRecognitionIsBounded() async throws {
        let executor = SubtitleImageOCR.Executor()
        let counter = RecognitionCounter()
        let entered = AtomicBool(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            await executor.run {
                counter.begin()
                defer { counter.end() }
                entered.set(true)
                release.wait()
                return "recognized"
            }
        }
        defer { first.cancel() }
        try await waitFor { entered.get() }
        let queued = (0..<19).map { _ in
            Task {
                await executor.run {
                    counter.begin()
                    defer { counter.end() }
                    return "recognized"
                }
            }
        }
        defer { queued.forEach { $0.cancel() } }
        try await waitFor { await executor.pendingCount == 19 }
        #expect(counter.maximum == 1)
        release.signal()
        #expect(await first.value == "recognized")
        for task in queued { #expect(await task.value == "recognized") }
        #expect(counter.maximum == 1)
    }

    @MainActor
    @Test("cancelling an unfinished embedded batch invalidates only its advanced coverage")
    func cancelledBatchIsCollectedAgain() throws {
        let engine = try AetherEngine()
        engine.subtitleOCRArmedOrdinal = 0
        engine.subtitleOCRBatchInFlight = true
        engine.subtitleOCRCursors[0] = SubtitleDrainCursor(lastDecodedPts: 120, lastPlayhead: 100)
        engine.subtitleOCRPendingStates[0] = SubtitleOCRPendingState()
        engine.subtitleOCRCursors[1] = SubtitleDrainCursor(lastDecodedPts: 80, lastPlayhead: 60)
        engine.cancelSubtitleOCRWorker()
        #expect(engine.subtitleOCRCursors[0] == nil)
        #expect(engine.subtitleOCRPendingStates[0] == nil)
        #expect(engine.subtitleOCRCursors[1]?.lastDecodedPts == 80)
        #expect(!engine.subtitleOCRBatchInFlight)
        engine.subtitleOCRArmedOrdinal = 1
        engine.cancelSubtitleOCRWorker()
        #expect(engine.subtitleOCRCursors[1]?.lastDecodedPts == 80,
                "completed coverage must survive re-selection")
    }

    @Test("cancelling a batch retains its completed cue in the originally captured store")
    func cancellationRetainsCompletedCue() async throws {
        let original = NativeSubtitleCueStore()
        let replacement = NativeSubtitleCueStore()
        let entered = AtomicBool(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fill = Task {
            await SubtitleImageOCR.appendRecognized(
                cues: [imageCue(1, 10, 12), imageCue(2, 12, 14)], language: "eng",
                to: original
            ) { _, _ in
                entered.set(true)
                release.wait()
                return "completed cue"
            }
        }
        defer { fill.cancel() }
        try await waitFor { entered.get() }
        fill.cancel()
        release.signal()
        await fill.value
        let retained = original.snapshotCues()
        #expect(retained.count == 1)
        #expect(retained.first?.text == "completed cue")
        #expect(retained.first?.startTime == 10)
        #expect(replacement.cueCount == 0)
    }
}

private final class RecognitionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var highWater = 0

    func begin() {
        lock.lock()
        active += 1
        highWater = max(highWater, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        lock.unlock()
    }

    var maximum: Int {
        lock.lock()
        defer { lock.unlock() }
        return highWater
    }
}

private func imageCue(_ id: Int, _ start: Double, _ end: Double) -> SubtitleCue {
    // Minimal 1x1 image body; only timing matters for the pending state.
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = SubtitleImage(cgImage: ctx.makeImage()!, position: .zero, canvasSize: .zero)
    return SubtitleCue(id: id, startTime: start, endTime: end, body: .image(image))
}

@Suite("OCR pending-composition end clamp")
struct SubtitleOCRPendingStateTests {
    @Test("the next event closes an open composition at its PTS; earlier real ends survive")
    func clampSemantics() {
        var state = SubtitleOCRPendingState()
        // Placeholder end (start+5) still open at the next event: clamps to event PTS.
        #expect(state.consume(eventPts: 10, cues: [imageCue(1, 10, 15)], trimAt: nil).isEmpty)
        let closed = state.consume(eventPts: 12, cues: [imageCue(2, 12, 17)], trimAt: nil)
        #expect(closed.map(\.id) == [1])
        #expect(closed[0].endTime == 12)
        // Real earlier end survives a later successor.
        var s2 = SubtitleOCRPendingState()
        _ = s2.consume(eventPts: 10, cues: [imageCue(3, 10, 11.5)], trimAt: nil)
        let c2 = s2.consume(eventPts: 20, cues: [], trimAt: 20)
        #expect(c2[0].endTime == 11.5)
    }

    @Test("a clear event closes via trimAt; expired emits with the decoder end at EOF")
    func clearAndExpiry() {
        var state = SubtitleOCRPendingState()
        _ = state.consume(eventPts: 10, cues: [imageCue(1, 10, 15)], trimAt: nil)
        let cleared = state.consume(eventPts: 13, cues: [], trimAt: 13)
        #expect(cleared[0].endTime == 13)
        _ = state.consume(eventPts: 30, cues: [imageCue(2, 30, 35)], trimAt: nil)
        #expect(state.expired(asOf: 36).isEmpty)          // margin not yet passed
        let expired = state.expired(asOf: 38)             // 35 + 2s margin crossed, no successor
        #expect(expired.map(\.id) == [2])
        #expect(expired[0].endTime == 35)
        #expect(state.expired(asOf: 60).isEmpty)          // emitted only once
    }
}
