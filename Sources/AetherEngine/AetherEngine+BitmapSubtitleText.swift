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
    /// The sidecar is named by an install count, not by its address: a freed source and its successor
    /// can share one.
    struct BitmapTextSource: Equatable {
        let trackID: Int?
        let drainTarget: Int32?
        let sidecarEpoch: UInt64
    }

    struct BitmapTextJob {
        let channel: SubtitleChannel
        let cueID: Int
        let startTime: Double
        let image: SubtitleImage
        let language: String?
        let source: BitmapTextSource
        let recognition: @Sendable (CGImage, String?) -> SubtitleRecognizedText

        /// The cue this reading is for, under its own id or under the id a re-decode gave its picture.
        func covers(_ cue: SubtitleCue, image other: SubtitleImage, on channel: SubtitleChannel) -> Bool {
            guard channel == self.channel else { return false }
            return cue.id == cueID || (cue.startTime == startTime && other.isSameComposition(as: image))
        }
    }

    /// Readings are written back in batches, so a burst (the whole lead window at selection) costs a
    /// few publications instead of one per cue (#271). A cue about to show goes out at once.
    nonisolated static let bitmapTextFlushInterval: TimeInterval = 0.25
    nonisolated static let bitmapTextUrgentLeadSeconds: Double = 1

    /// Called on every publish of either cue array. Starts the loop only when there is something to
    /// read, so a text track publishing at caption rate costs a scan and no task. A running loop picks
    /// its next cue fresh after each reading, so it sees whatever this publish added.
    func scheduleBitmapTextRecognition() {
        guard loadedOptions.recognizesBitmapSubtitleText, bitmapTextRecognitionTask == nil,
              nextBitmapTextJob(pending: []) != nil else { return }
        let generation = bitmapTextRecognitionGeneration
        // Weak across the reading: a released engine must not wait for Vision to let go of it.
        bitmapTextRecognitionTask = Task { [weak self] in
            var pending: [(job: BitmapTextJob, read: SubtitleRecognizedText)] = []
            var lastFlush = Date()
            var next = self?.nextBitmapTextJob(generation: generation, pending: [])
            while let job = next {
                let started = Date()
                let read = await SubtitleImageOCR.recognizeDetailed(in: job.image.cgImage, language: job.language,
                                                                     recognition: job.recognition)
                guard let self, !Task.isCancelled, generation == self.bitmapTextRecognitionGeneration
                else { return }
                guard let read else { break }
                self.noteFirstBitmapTextRead(read, after: Date().timeIntervalSince(started))
                pending.append((job, read))
                next = self.nextBitmapTextJob(generation: generation, pending: pending.map(\.job))
                let urgent = job.startTime <= self.sourceTime + Self.bitmapTextUrgentLeadSeconds
                if next == nil || urgent || Date().timeIntervalSince(lastFlush) >= Self.bitmapTextFlushInterval {
                    self.applyBitmapTexts(pending)
                    pending.removeAll()
                    lastFlush = Date()
                    // The write-back republished, which may have changed what is unread.
                    next = self.nextBitmapTextJob(generation: generation, pending: [])
                }
            }
            guard let self, generation == self.bitmapTextRecognitionGeneration else { return }
            if !pending.isEmpty { self.applyBitmapTexts(pending) }
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

    private func nextBitmapTextJob(generation: UInt64, pending: [BitmapTextJob]) -> BitmapTextJob? {
        guard !Task.isCancelled, generation == bitmapTextRecognitionGeneration else { return nil }
        return nextBitmapTextJob(pending: pending)
    }

    private func noteFirstBitmapTextRead(_ read: SubtitleRecognizedText, after seconds: TimeInterval) {
        guard !bitmapTextFirstReadLogged else { return }
        bitmapTextFirstReadLogged = true
        EngineLog.emit("[SubtitleOCR] overlay text: first cue read in " + String(format: "%.2f", seconds) + "s, "
                       + "lines=\(read.lines.count) level=\(read.level) "
                       + "language=\(read.language ?? "unpinned")", category: .engine)
    }

    /// The next unread picture across both channels. First the earliest one still on screen or ahead
    /// of the playhead. Then, behind it, the latest one inside `maximumSubtitleDelaySeconds`: a host
    /// that shows cues later than their time still draws those. Further back nothing is read; after
    /// a backward seek those cues are due again and get read then.
    ///
    /// `pending` are readings done but not yet written back. Their cues are skipped by id and by
    /// picture, since a re-decode in between gives the same picture a new id.
    func nextBitmapTextJob(pending: [BitmapTextJob], playhead: Double? = nil) -> BitmapTextJob? {
        let playhead = playhead ?? sourceTime
        let floor = playhead - maximumSubtitleDelaySeconds
        var ahead: (channel: SubtitleChannel, cue: SubtitleCue, image: SubtitleImage)?
        var behind: (channel: SubtitleChannel, cue: SubtitleCue, image: SubtitleImage)?
        for channel in [SubtitleChannel.primary, .secondary] {
            for cue in retainedSubtitleCues(for: channel) {
                if let ahead, cue.startTime >= ahead.cue.startTime { break }
                guard cue.endTime > floor, case .image(let image) = cue.body, image.recognizedText == nil,
                      !pending.contains(where: { $0.covers(cue, image: image, on: channel) }) else { continue }
                if cue.endTime > playhead {
                    ahead = (channel, cue, image)
                    break
                }
                if behind.map({ cue.startTime > $0.cue.startTime }) ?? true { behind = (channel, cue, image) }
            }
        }
        guard let pick = ahead ?? behind else { return nil }
        return BitmapTextJob(channel: pick.channel, cueID: pick.cue.id, startTime: pick.cue.startTime,
                             image: pick.image, language: bitmapTextLanguage(for: pick.channel),
                             source: bitmapTextSource(for: pick.channel), recognition: bitmapTextRecognizer)
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
            sidecarEpoch: sidecarBitmapSourceEpochs[channel, default: 0])
    }

    /// The channel's track language as Vision wants it, nil when unknown (unpinned recognition).
    func bitmapTextLanguage(for channel: SubtitleChannel) -> String? {
        guard let id = channel == .primary ? activeSubtitleTrackIndex : activeSecondarySubtitleTrackIndex
        else { return nil }
        let tag = subtitleTracks.first(where: { $0.id == id })?.language
            ?? externalSubtitleRegistry[id]?.language
        return SubtitleImageOCR.recognitionLanguage(forTrackLanguage: tag)
    }

    /// Writes readings onto their cues, one publication per channel. A cue is found by id, or, when a
    /// re-decode replaced it meanwhile (a new id for the same picture), by the composition key
    /// `insertCueSorted` uses too.
    func applyBitmapTexts(_ readings: [(job: BitmapTextJob, read: SubtitleRecognizedText)]) {
        for channel in [SubtitleChannel.primary, .secondary] {
            let source = bitmapTextSource(for: channel)
            let mine = readings.filter { $0.job.channel == channel && $0.job.source == source }
            guard !mine.isEmpty else { continue }
            var cues = retainedSubtitleCues(for: channel)
            var changed = false
            for (job, read) in mine {
                let index = cues.firstIndex(where: { $0.id == job.cueID })
                    ?? cues.firstIndex(where: { cue in
                        guard case .image(let image) = cue.body else { return false }
                        return job.covers(cue, image: image, on: channel)
                    })
                guard let index, case .image(let image) = cues[index].body, image.recognizedText == nil else { continue }
                cues[index] = cues[index].with(body: .image(image.with(recognizedText: read)))
                changed = true
            }
            if changed { publishRetainedSubtitleCues(cues, for: channel) }
        }
    }
}
