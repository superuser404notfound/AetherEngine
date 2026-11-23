import CoreGraphics
import Foundation
import Vision

/// Phase D: on-device recognition of bitmap subtitle images (PGS / DVB / DVD) into plain-text
/// cues for the native WebVTT rendition (PiP / AirPlay / external display). Lossy by design;
/// a failed or empty recognition drops that cue and the rendition just misses the line, the
/// fullscreen overlay keeps the pixel-accurate bitmaps.
enum SubtitleImageOCR {
    private static let executor = Executor()

    /// One Vision observation as the engine keeps it: the top candidate, its confidence, and its box
    /// in Vision's own space (normalized, bottom-left origin).
    struct Observation: Sendable {
        let text: String
        let confidence: Float
        let visionBox: CGRect
    }

    /// Vision's boxes have a bottom-left origin, so reading order is descending midY. Blank fragments
    /// drop. AE#1114: each line keeps its confidence, and its box moves to a top-left origin, the
    /// convention `SubtitleImage.position` uses.
    nonisolated static func recognizedLines(_ observations: [Observation]) -> [SubtitleRecognizedText.Line] {
        observations
            .map { (obs: $0, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.obs.visionBox.midY > $1.obs.visionBox.midY }
            .map { item in
                let box = item.obs.visionBox
                return SubtitleRecognizedText.Line(
                    text: item.text, confidence: item.obs.confidence,
                    boundingBox: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            }
    }

    /// Track tags are ISO 639-1/2 ("ger"), Vision wants BCP-47 primary codes ("de"). The engine's
    /// synonym classes resolve the bibliographic 639-2/B forms Foundation cannot ("ger", "fre").
    nonisolated static func recognitionLanguage(forTrackLanguage tag: String?) -> String? {
        guard let raw = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if let set = AetherEngine.languageSynonyms.first(where: { $0.contains(raw) }),
           let twoLetter = set.first(where: { $0.count == 2 }) {
            return twoLetter
        }
        return Locale.LanguageCode(raw).identifier(.alpha2) ?? raw
    }

    /// Subtitle bitmaps are white glyphs with an outline on transparency; an opaque black
    /// backing gives Vision stable contrast.
    nonisolated static func flattenedOntoBlack(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Vision synchronously waits for work of its own. Keep that wait on a real thread, not a
    /// Swift cooperative worker (including Task.detached), so recognition cannot exhaust the
    /// executor. Admission is process-wide and stays occupied until the native call returns,
    /// even if its caller is cancelled.
    nonisolated static func recognizeText(
        in image: CGImage, language: String?,
        recognition: @escaping @Sendable (CGImage, String?) -> String? = recognizeSynchronously
    ) async -> String? {
        await executor.run {
            recognition(image, language)
        }
    }

    /// AE#1114: the overlay's reading, with lines, confidences and boxes. Shares the native worker's
    /// thread and admission, so the two never run Vision at the same time. nil only when cancelled
    /// before it ran; a picture with nothing readable comes back with no lines.
    nonisolated static func recognizeDetailed(
        in image: CGImage, language: String?,
        recognition: @escaping @Sendable (CGImage, String?) -> SubtitleRecognizedText = recognizeDetailedSynchronously
    ) async -> SubtitleRecognizedText? {
        await executor.run {
            recognition(image, language)
        }
    }

    /// One synchronous Vision pass, called only by the recognition thread.
    ///
    /// `.accurate` is the better reader and it is also an OPTIONAL system model: it runs on the
    /// Neural Engine and a given OS build may be unable to hand it over. Measured on macOS 27.0,
    /// the first accurate request in a process spends about a minute precompiling it and then
    /// throws `e5rtError(…precompiled_compute_operation…, 13)` roughly half the time, after which
    /// every later accurate request in that process fails in milliseconds (#552).
    ///
    /// Pinning it alone meant the whole bitmap-to-text stage yielded nothing wherever that happens,
    /// so PGS / DVB / DVD subtitles were simply absent in PiP, on AirPlay and on an external
    /// display, while `.fast` read the very same frame correctly in 30 ms. So a failed pass drops
    /// to `.fast` instead of dropping the cue.
    ///
    /// The drop is remembered for the process. A single accurate failure is not a fluke on this
    /// evidence, it is the state the process stays in, and the alternative is paying a minute of
    /// stall per cue to learn it again.
    private nonisolated static func recognizeSynchronously(_ image: CGImage, language: String?) -> String? {
        recognizeDetailedSynchronously(image, language: language).text
    }

    /// Both readers go through here, so the fallback and the language pin behave the same for the
    /// native rendition and the overlay.
    nonisolated static func recognizeDetailedSynchronously(_ image: CGImage, language: String?) -> SubtitleRecognizedText {
        guard let flat = flattenedOntoBlack(image) else {
            return SubtitleRecognizedText(lines: [], language: nil, level: accurateIsUnavailable ? .fast : .accurate)
        }
        if !accurateIsUnavailable, let read = recognize(flat, at: .accurate, language: language) {
            return SubtitleRecognizedText(lines: recognizedLines(read.observations),
                                          language: read.pinned, level: .accurate)
        }
        markAccurateUnavailable()
        guard let read = recognize(flat, at: .fast, language: language) else {
            return SubtitleRecognizedText(lines: [], language: nil, level: .fast)
        }
        return SubtitleRecognizedText(lines: recognizedLines(read.observations),
                                      language: read.pinned, level: .fast)
    }

    /// nil when the REQUEST failed, which is what the fallback turns on. An empty array is a
    /// request that ran and read nothing, which is an ordinary outcome for a subtitle bitmap and
    /// says nothing about the model.
    ///
    /// The language is resolved per level on purpose: `.fast` supports six languages against the
    /// accurate model's thirty-three, so outside those six the pin is simply dropped. Unpinned
    /// recognition of a line beats no line.
    private nonisolated static func recognize(_ image: CGImage,
                                              at level: VNRequestTextRecognitionLevel,
                                              language: String?) -> (observations: [Observation], pinned: String?)? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        var pinned: String?
        if let language,
           let supported = try? request.supportedRecognitionLanguages(),
           let match = supported.first(where: {
               let s = $0.lowercased()
               return s == language || s.hasPrefix(language + "-")
           }) {
            request.recognitionLanguages = [match]
            pinned = language
        }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            logFailureOnce("Vision \(level == .accurate ? "accurate" : "fast") perform failed: \(error)")
            return nil
        }
        let observations = (request.results ?? []).compactMap { obs -> Observation? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return Observation(text: top.string, confidence: top.confidence, visionBox: obs.boundingBox)
        }
        return (observations, pinned)
    }

    /// Recognize a batch of CLOSED cues and append the text results to a native store. Image
    /// cues become text cues at the same times; text cues pass through (mixed external files).
    /// The worker/fill task awaits each recognition; Vision itself runs on a dedicated thread.
    nonisolated static func appendRecognized(
        cues: [SubtitleCue], language trackLanguage: String?, to store: NativeSubtitleCueStore,
        recognition: @escaping @Sendable (CGImage, String?) -> String? = recognizeSynchronously
    ) async {
        let language = recognitionLanguage(forTrackLanguage: trackLanguage)
        var out: [SubtitleCue] = []
        for cue in cues {
            if Task.isCancelled { break }
            switch cue.body {
            case .image(let image):
                if let text = await recognizeText(in: image.cgImage, language: language,
                                                  recognition: recognition) {
                    out.append(cue.with(body: .text(text)))
                }
            case .text, .richText:
                out.append(cue)
            }
        }
        if !out.isEmpty { store.appendCues(out) }
    }

    /// Waiters suspend; only the admitted operation owns a thread. Cancellation removes a queued
    /// request, but cannot release an active request's slot while Vision is still using it.
    actor Executor {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Bool, Never>
        }

        private var busy = false
        private var waiting: [Waiter] = []
        var pendingCount: Int { waiting.count }

        func run<Result: Sendable>(_ recognition: @escaping @Sendable () -> Result?) async -> Result? {
            guard await acquire() else { return nil }
            guard !Task.isCancelled else {
                release()
                return nil
            }
            let result = await withCheckedContinuation { continuation in
                let worker = Thread {
                    let result = autoreleasepool(invoking: recognition)
                    continuation.resume(returning: result)
                }
                worker.name = "com.aetherengine.subtitle.ocr"
                worker.qualityOfService = .utility
                worker.start()
            }
            release()
            return result
        }

        private func acquire() async -> Bool {
            let id = UUID()
            return await withTaskCancellationHandler {
                guard !Task.isCancelled else { return false }
                if !busy {
                    busy = true
                    return true
                }
                return await withCheckedContinuation {
                    waiting.append(Waiter(id: id, continuation: $0))
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
            waiting.remove(at: index).continuation.resume(returning: false)
        }

        private func release() {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().continuation.resume(returning: true)
            }
        }
    }

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var loggedFailure = false
    nonisolated(unsafe) private static var accurateFailed = false

    private nonisolated static var accurateIsUnavailable: Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        return accurateFailed
    }

    private nonisolated static func markAccurateUnavailable() {
        failureLock.lock()
        accurateFailed = true
        failureLock.unlock()
    }

    /// The fallback cannot be reached on a machine whose accurate model works, and a machine whose
    /// model is broken cannot be asked for on demand. So the state it turns on is settable, and the
    /// test drives the fallback rather than the weather.
    nonisolated static func setAccurateUnavailableForTesting(_ unavailable: Bool) {
        failureLock.lock()
        accurateFailed = unavailable
        failureLock.unlock()
    }

    private nonisolated static func logFailureOnce(_ reason: String) {
        failureLock.lock()
        let first = !loggedFailure
        loggedFailure = true
        failureLock.unlock()
        if first { EngineLog.emit("[SubtitleOCR] degraded: \(reason)", category: .engine) }
    }
}
