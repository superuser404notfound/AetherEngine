import Foundation

/// What can ask the software host to put a flushed or failed output queue back to work. The system
/// is free to throw a queue away or fail it under the app: the video renderer says it
/// `requiresFlushToResumeDecoding` (and its status turns `.failed`) when the app loses the right to
/// use decoder resources, and either renderer can end up `.failed`. AVPlayer recovers from these on
/// its own; the host owns its queues, so the recovery is its job.
///
/// The audio renderer flushing itself on a route change (AE#549) is deliberately not a trigger: it
/// leaves the video queue alone, so the picture is not behind anything, and re-feeding the audio it
/// dropped would mean a seek that cuts the audio still playing.
enum FlushRecoveryTrigger: String, Sendable, CaseIterable {
    /// `AVSampleBufferVideoRenderer.requiresFlushToResumeDecoding` turned true.
    case videoQueueRequiresFlush
    /// The video renderer's status was `.failed` when a frame was handed to it, or a decode failure left it so.
    case videoQueueFailed
    /// The audio renderer's status reads `.failed`.
    case audioRendererFailed
}

/// The rules, pure so they can be checked without a renderer.
///
/// A flushed video queue is refilled from the decoder, which restarts on the next keyframe. The
/// picture is frozen from the playhead until that keyframe is shown; the audio keeps playing the
/// whole time, as it did before any of this (AE#549). Waiting for the keyframe is enough when the
/// keyframe lies within the audio already queued: the freeze then ends before the audio lead does.
/// When the keyframe lies beyond it, or none has been read yet, the freeze outlasts the audio lead
/// and only a reposition puts a picture back at the playhead: both queues and both decoders
/// flushed, the demuxer put back on the keyframe before the playhead, the skip threshold hiding the
/// preroll and the clock re-anchored there. That is the one case where the audio is cut. A DVR session's
/// live feeder keeps no keyframe ledger, so its gap is always unknown, and the rule reads an unknown gap
/// as beyond the audio lead: a video recovery there repositions, the conservative choice (the backoff and
/// no-presented-frame rules below can still degrade that to a plain flush).
///
/// On the decoupled route (a VOD source with its own audio decoder) the demuxer reads video up to
/// the audio lead target and parks it, so the keyframe gap is mostly settled by one question: is a
/// keyframe parked at all? With one parked, it lies inside the lead and the rule reduces to
/// "reposition only if no keyframe is parked". The freeze the rule accepts can then run as long as
/// the audio lead target itself (several seconds), which is what a plain flush costs when the next
/// keyframe sits at the far end of the parked packets.
///
/// Two backstops keep a queue the system keeps failing from freezing the picture or cutting the
/// audio over and over: a flush or reposition that is followed by no presented frame is not repeated
/// (a reposition degrades to a flush), and a reposition is not repeated within
/// `repositionBackoffSeconds` of the last one, whatever the frames did in between. A failed audio
/// renderer is flushed at most `maxAudioFlushesPerWindow` times within `audioFlushWindowSeconds`; one
/// that fails again past that is left alone, since a renderer that refuses the same input again and
/// again is not helped by one more flush.
enum FlushRecoveryPolicy {
    enum Action: Equatable, Sendable {
        /// Nothing to do: the session is gone, a seek already owns the queues, a recovery is under
        /// way, or the last one has not been followed by a presented frame yet.
        case ignore
        /// Flush everything and put the demuxer back at the playhead (a seek to the current time).
        case reposition
        /// Flush the video queue and the decoder and carry on from the next keyframe, with the audio
        /// playing on.
        case flushVideoOnly
        /// Flush the audio queue; it is refilled as the feed reaches the clock.
        case flushAudioOnly
        /// The app cannot decode video right now (background); the recovery is paid on the foreground return.
        case deferToForeground
    }

    struct State: Sendable {
        var stopRequested = false
        var hasSource = true
        var seekInFlight = false
        var recoveryPending = false
        var backgroundAudioOnly = false
        /// The queue took a frame at some point. Before that it holds nothing worth recovering, and
        /// the failed-enqueue path has already flushed and revived it.
        var firstFramePresented = true
        /// False for a live source with no rewind ring: there is nothing to reposition to.
        var canReposition = true
        /// Frames the queue accepted since the last video recovery; nil if there has been none.
        var framesPresentedSinceLastVideoRecovery: Int?
        /// What the last video recovery did.
        var lastVideoRecovery: Action?
        /// From the playhead to the next keyframe the decoder has not seen, in seconds; nil when no
        /// such keyframe has been read yet.
        var videoGapSeconds: Double?
        /// Audio queued ahead of the playhead, in seconds.
        var audioLeadSeconds: Double = 0
        /// Seconds since the last reposition this rule asked for; nil if there has been none.
        var secondsSinceLastReposition: Double?
        /// The shortest time between two repositions.
        var repositionBackoffSeconds = FlushRecoveryPolicy.repositionBackoffSeconds
        /// Audio flushes this rule asked for within the last `audioFlushWindowSeconds`.
        var audioFlushesInWindow = 0
    }

    /// The shortest time between two repositions, whatever happened in between.
    static let repositionBackoffSeconds: Double = 3

    /// The window an audio flush counts in, and how many it may take: a failed audio renderer that
    /// keeps failing is flushed 3 times in 10 s, then left until the window has emptied.
    static let audioFlushWindowSeconds: Double = 10
    static let maxAudioFlushesPerWindow = 3

    /// Whether the picture would stay frozen for longer than the audio keeps playing from its queue.
    /// A keyframe that has not been read yet lies beyond everything read, so it counts as longer.
    static func videoGapOutlastsAudioLead(gap: Double?, lead: Double) -> Bool {
        guard let gap else { return true }
        return gap > lead
    }

    static func decide(_ trigger: FlushRecoveryTrigger, _ s: State) -> Action {
        guard !s.stopRequested, s.hasSource, !s.seekInFlight, !s.recoveryPending else { return .ignore }
        switch trigger {
        case .audioRendererFailed:
            return s.audioFlushesInWindow >= maxAudioFlushesPerWindow ? .ignore : .flushAudioOnly
        case .videoQueueRequiresFlush, .videoQueueFailed:
            if s.backgroundAudioOnly { return .deferToForeground }
            guard s.firstFramePresented else { return .ignore }
            // No frame was presented since the last recovery: it did not help, and repeating it cannot.
            // A reposition that came to nothing degrades to a plain flush, which the system gets to
            // fail once more; a plain flush that came to nothing is not repeated.
            if s.framesPresentedSinceLastVideoRecovery == 0 {
                return s.lastVideoRecovery == .reposition ? .flushVideoOnly : .ignore
            }
            guard s.canReposition,
                  videoGapOutlastsAudioLead(gap: s.videoGapSeconds, lead: s.audioLeadSeconds)
            else { return .flushVideoOnly }
            if let since = s.secondsSinceLastReposition, since < s.repositionBackoffSeconds { return .flushVideoOnly }
            return .reposition
        }
    }

    /// Whether the video queue needs the flush, from what the renderer reports.
    static func videoQueueNeedsFlush(requiresFlush: Bool, failed: Bool) -> Bool { requiresFlush || failed }
}

/// The video keyframes the demux loop has read and parked for the decoder but not yet handed to it,
/// and the "decode again from a keyframe" gate a recovery flush raises.
///
/// After a flush the decoder restarts on the first keyframe, so its time is where the picture
/// comes back. Fed by the reading side and the decode hand-off, read by the main actor.
///
/// A plain recovery flush leaves the demuxer where it stood, so the packets that follow are usually
/// delta frames of a group of pictures whose keyframe went into the flushed decoder. Handed over,
/// they decode against nothing: the software decoder errors, and the hardware one needs a rebuilt
/// session to refuse them. The gate makes the demux thread drop video packets until a keyframe
/// comes, at both decoder hand-offs.
final class SWKeyframeLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Double] = []
    private var awaitingKeyframe = false
    private var droppedWhileAwaiting = 0

    /// A keyframe sits in the parked-packet FIFO of at most `parkedVideoCap` packets (256), so no more
    /// than that many can be pending; the bound only guards a decoder that stops taking packets.
    static let capacity = 256

    /// A source whose keyframes carry no flag would otherwise lose its video for good; after this many
    /// dropped packets the gate lets the next one through.
    static let gateDropLimit = 4096

    func noteKeyframeRead(pts: Double) {
        guard pts.isFinite else { return }
        lock.lock()
        pending.append(pts)
        if pending.count > Self.capacity { pending.removeFirst(pending.count - Self.capacity) }
        lock.unlock()
    }

    /// A packet went into the decoder. Keyframes are in order, so a keyframe handed over retires
    /// every earlier one too.
    func noteHandedToDecoder(pts: Double, isKeyframe: Bool) {
        guard isKeyframe, pts.isFinite else { return }
        lock.lock()
        pending.removeAll { $0 <= pts }
        lock.unlock()
    }

    /// A keyframe that was noted when it was read and then discarded without reaching the decoder.
    func noteDropped(pts: Double, isKeyframe: Bool) {
        guard isKeyframe, pts.isFinite else { return }
        lock.lock()
        if let index = pending.firstIndex(of: pts) { pending.remove(at: index) }
        lock.unlock()
    }

    /// The next keyframe the decoder has not seen, or nil when none has been read.
    var nextKeyframe: Double? {
        lock.lock()
        defer { lock.unlock() }
        return pending.first
    }

    /// What the gate says about a video packet about to go to the decoder.
    enum GateVerdict: Equatable, Sendable {
        /// Hand it over; no recovery is waiting for a keyframe.
        case pass
        /// A recovery is waiting for a keyframe and this is not one: drop it.
        case drop
        /// The keyframe the recovery was waiting for: hand it over. If the decoder refuses it (a
        /// flush landed during the hand-off), the caller raises the gate again.
        case passAndOpen
    }

    /// A recovery flushed the video decoder: drop video until the next keyframe. Raised before the
    /// flush and again after it, so a keyframe handed over in between, and thrown away by the flush,
    /// does not count as the one that was waited for.
    func requireKeyframe() {
        lock.lock()
        awaitingKeyframe = true
        droppedWhileAwaiting = 0
        lock.unlock()
    }

    var isAwaitingKeyframe: Bool {
        lock.lock()
        defer { lock.unlock() }
        return awaitingKeyframe
    }

    func gate(isKeyframe: Bool) -> GateVerdict {
        lock.lock()
        defer { lock.unlock() }
        guard awaitingKeyframe else { return .pass }
        if isKeyframe || droppedWhileAwaiting >= Self.gateDropLimit {
            awaitingKeyframe = false
            return .passAndOpen
        }
        droppedWhileAwaiting += 1
        return .drop
    }

    /// The parked packets were thrown away (video not wanted in the background, a seam, a seek
    /// noticed by the reading side). The gate is a decoder-side matter and stays as it was.
    func discardPending() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    /// A reposition emptied the parked packets and restarts the decoder on a keyframe of its own.
    func reset() {
        lock.lock()
        pending.removeAll()
        awaitingKeyframe = false
        droppedWhileAwaiting = 0
        lock.unlock()
    }
}
