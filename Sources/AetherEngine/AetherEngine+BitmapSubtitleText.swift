import CoreGraphics
import Foundation

// AE#1114: read the text of the overlay's bitmap cues for hosts that draw picture subtitles in their
// own caption style (`LoadOptions.recognizesBitmapSubtitleText`). The text lands on the cue itself
// (`SubtitleImage.recognizedText`), so it follows the cue through every trim, eviction and clear
// the retained stores already do, and a re-decode after a seek keeps it (`insertCueSorted`).
//
// No reader of its own: the loop only looks at cues the overlay drain has already published, which
// is the window it decodes anyway (`subtitleDrainLeadSeconds`). Vision runs on the same thread and
// admission as the native rendition's worker, so the two never compete for the Neural Engine.
extension AetherEngine {

    /// What a pending reading belongs to. A result whose channel moved to another track, sidecar or
    /// drain target since is dropped rather than written onto a cue that happens to share a start.
    struct BitmapTextSource: Equatable {
        let trackID: Int?
        let drainTarget: Int32?
        let sidecar: ObjectIdentifier?
    }

    struct BitmapTextJob {
        let channel: SubtitleChannel
        let cueID: Int
        let startTime: Double
        let image: SubtitleImage
        let language: String?
        let source: BitmapTextSource
        let recognition: @Sendable (CGImage, String?) -> SubtitleRecognizedText
    }

    /// Called on every publish of either cue array. Cheap when the option is off or a loop is
    /// already running: the loop picks its next cue fresh after each reading, so it sees whatever
    /// this publish added.
    func scheduleBitmapTextRecognition() {
        guard loadedOptions.recognizesBitmapSubtitleText, bitmapTextRecognitionTask == nil else { return }
        let generation = bitmapTextRecognitionGeneration
        // Weak across the reading: a released engine must not wait for Vision to let go of it.
        bitmapTextRecognitionTask = Task { [weak self] in
            while let job = self?.nextBitmapTextJob(generation: generation) {
                let started = Date()
                let read = await SubtitleImageOCR.recognizeDetailed(in: job.image.cgImage, language: job.language,
                                                                     recognition: job.recognition)
                guard let self, !Task.isCancelled, generation == self.bitmapTextRecognitionGeneration
                else { return }
                guard let read else { break }
                self.noteFirstBitmapTextRead(read, after: Date().timeIntervalSince(started))
                self.applyBitmapText(read, for: job)
            }
            guard let self, generation == self.bitmapTextRecognitionGeneration else { return }
            self.bitmapTextRecognitionTask = nil
        }
    }

    /// Load and stop: a reading still on the recognition thread finishes there, its result is dropped.
    func resetBitmapTextRecognition() {
        bitmapTextRecognitionGeneration &+= 1
        bitmapTextRecognitionTask?.cancel()
        bitmapTextRecognitionTask = nil
        bitmapTextFirstReadLogged = false
    }

    private func nextBitmapTextJob(generation: UInt64) -> BitmapTextJob? {
        guard !Task.isCancelled, generation == bitmapTextRecognitionGeneration else { return nil }
        return nextBitmapTextJob()
    }

    private func noteFirstBitmapTextRead(_ read: SubtitleRecognizedText, after seconds: TimeInterval) {
        guard !bitmapTextFirstReadLogged else { return }
        bitmapTextFirstReadLogged = true
        EngineLog.emit("[SubtitleOCR] overlay text: first cue read in " + String(format: "%.2f", seconds) + "s, "
                       + "lines=\(read.lines.count) level=\(read.level) "
                       + "language=\(read.language ?? "unpinned")", category: .engine)
    }

    /// The earliest unread picture that is still on screen or ahead of the playhead, across both
    /// channels. Behind the playhead nothing is read: after a backward seek those cues are due
    /// again (retained or re-decoded) and get read then.
    func nextBitmapTextJob() -> BitmapTextJob? {
        let playhead = sourceTime
        var best: BitmapTextJob?
        for channel in [SubtitleChannel.primary, .secondary] {
            let cues = retainedSubtitleCues(for: channel)
            for cue in cues {
                if let best, cue.startTime >= best.startTime { break }
                guard cue.endTime > playhead, case .image(let image) = cue.body,
                      image.recognizedText == nil else { continue }
                best = BitmapTextJob(channel: channel, cueID: cue.id, startTime: cue.startTime,
                                     image: image, language: bitmapTextLanguage(for: channel),
                                     source: bitmapTextSource(for: channel),
                                     recognition: bitmapTextRecognizer)
                break
            }
        }
        return best
    }

    private var bitmapTextRecognizer: @Sendable (CGImage, String?) -> SubtitleRecognizedText {
        #if DEBUG
        if let recognizer = bitmapTextRecognizerForTesting { return recognizer }
        #endif
        return SubtitleImageOCR.recognizeDetailedSynchronously
    }

    func bitmapTextSource(for channel: SubtitleChannel) -> BitmapTextSource {
        BitmapTextSource(
            trackID: channel == .primary ? activeSubtitleTrackIndex : activeSecondarySubtitleTrackIndex,
            drainTarget: subtitleDrainTargets[channel],
            sidecar: sidecarBitmapSources[channel].map(ObjectIdentifier.init))
    }

    /// The channel's track language as Vision wants it, nil when unknown (unpinned recognition).
    func bitmapTextLanguage(for channel: SubtitleChannel) -> String? {
        guard let id = channel == .primary ? activeSubtitleTrackIndex : activeSecondarySubtitleTrackIndex
        else { return nil }
        let tag = subtitleTracks.first(where: { $0.id == id })?.language
            ?? externalSubtitleRegistry[id]?.language
        return SubtitleImageOCR.recognitionLanguage(forTrackLanguage: tag)
    }

    /// Writes the reading onto its cue and republishes the channel. The cue is found by id, or, when
    /// a re-decode replaced it meanwhile (a new id for the same picture), by the key `insertCueSorted`
    /// uses to call two pictures the same: start, position and pixel size.
    func applyBitmapText(_ read: SubtitleRecognizedText, for job: BitmapTextJob) {
        guard bitmapTextSource(for: job.channel) == job.source else { return }
        var cues = retainedSubtitleCues(for: job.channel)
        let index = cues.firstIndex(where: { $0.id == job.cueID })
            ?? cues.firstIndex(where: { cue in
                guard cue.startTime == job.startTime, case .image(let image) = cue.body else { return false }
                return image.position == job.image.position
                    && image.cgImage.width == job.image.cgImage.width
                    && image.cgImage.height == job.image.cgImage.height
            })
        guard let index, case .image(let image) = cues[index].body, image.recognizedText == nil else { return }
        cues[index] = cues[index].with(body: .image(image.with(recognizedText: read)))
        publishRetainedSubtitleCues(cues, for: job.channel)
    }
}
