import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

/// Audio output via AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer. The synchronizer is the
/// **master clock** for the whole player: video frames check synchronizer.currentTime() to decide presentation.
final class AudioOutput: @unchecked Sendable {

    let renderer: AVSampleBufferAudioRenderer
    let synchronizer: AVSampleBufferRenderSynchronizer

    /// AE#395: the renderers' axis. Every time this object takes or returns is on the source axis;
    /// the conversion happens here, at the renderer and synchronizer calls, and in the video renderer
    /// that shares this timeline.
    let timeline = RendererTimeline()

    private let lock = NSLock()
    /// Explicit host pause owns every clock write, including stale feeder work that carries no
    /// command revision. Buffering pauses leave this intent alone. Guarded by `lock`.
    private var playbackEnabled = true
    @MainActor private var attachedVideoLayer: AVSampleBufferDisplayLayer?
    @MainActor private var videoLayerRemovalTask: Task<Void, Never>?

    /// External clock commands retire queued arm corrections. Compared under the same lock as
    /// the rate change so a later feeder rebuffer pause cannot be overwritten by a stale correction.
    /// Preroll completion belongs to its initiating command and does not advance this revision.
    private var _clockCommandRevision: UInt64 = 0
    var clockCommandRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _clockCommandRevision
    }

    /// AE#464: the host's audio presentation offset, applied to every buffer on its way into the
    /// renderer. Guarded because the host writes it from the main actor while the demux thread reads
    /// it in `enqueue`.
    private var presentationOffset: CMTime = .zero

    /// One line per offset change, not per buffer. Reset by `setPresentationOffset`.
    private var loggedOffsetInEffect = false

    /// Audit DEC-106: retired by every `flush()` and `stop()`, under `lock`. A feed loop reads it before
    /// it reads a packet and enqueues through `enqueue(sampleBuffer:ifEpoch:)`, which compares under the
    /// same lock, so a buffer decided on before a seek's flush can no longer land after it.
    private var _epoch: UInt64 = 0
    var epoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _epoch
    }

    init() {
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)

        // Spatial audio for AirPods Pro/Max and HomePod: renderer spatializes multichannel when system-enabled.
        renderer.allowedAudioSpatializationFormats = .multichannel

        // Rate changes ride the synchronizer timebase, and this renderer's algorithm is what decides
        // whether they keep pitch (#434). Pinned here, while the timebase is still stopped.
        AudioRatePolicy.apply(to: renderer)
        observeAutomaticFlush()
    }

    deinit {
        if let automaticFlushObserver {
            NotificationCenter.default.removeObserver(automaticFlushObserver)
        }
    }

    /// The synchronizer's rate. A stopped clock and a running clock whose timebase has stalled read
    /// differently here and nowhere else, which is the whole reason AE#549 needs it (see
    /// `RendererClockResume`).
    var rate: Float {
        synchronizer.rate
    }

    /// AE#395: the renderer's own view of its queue, for the diagnostic line: `status/sufficient/error`.
    /// A session that is silent on one route while its clock runs at 1.00 has nothing else that could
    /// say whether the renderer is playing what it was given, and the renderer error was only ever
    /// logged in DEBUG builds.
    var diagRendererState: String {
        let status: String
        switch renderer.status {
        case .rendering: status = "rendering"
        case .failed: status = "failed"
        case .unknown: status = "unknown"
        @unknown default: status = "?"
        }
        let sufficient = renderer.hasSufficientMediaDataForReliablePlaybackStart ? "y" : "n"
        let error = (renderer.error as NSError?).map { "\($0.domain)/\($0.code)" } ?? "-"
        return "\(status)/\(sufficient)/\(error)"
    }

    /// AE#549: how often this renderer has flushed itself, for the diagnostic line.
    var automaticFlushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _automaticFlushCount
    }

    private var automaticFlushObserver: NSObjectProtocol?
    private var _automaticFlushCount = 0

    /// Where the AE#549 flush runs. The posting thread must never wait on `lock`: `enqueue` holds it
    /// across `renderer.enqueue` (DEC-106), and a renderer that posts from inside that call would make the
    /// feed thread wait on a lock it already holds, with every `flush()` / `stop()` / `seekClock()` behind it.
    private let automaticFlushQueue = DispatchQueue(label: "engine.audio.autoflush")

    /// AE#549: the renderer throws its queue away when the route changes under it, and posts the
    /// timestamp of the first sample it dropped. Nothing in the engine observed that, so the lead
    /// that was discarded was neither re-fed nor mentioned anywhere.
    ///
    /// Two things happen here, both out of the header's own guidance. The second flush is its stated
    /// best practice: the notification arrives on an arbitrary thread, so a buffer enqueued
    /// concurrently with it survives, and a survivor sits in the queue stamped far ahead of the
    /// timebase, muting the session for as long as it takes the clock to reach it. Re-feeding from
    /// the timebase is deliberately NOT attempted, on any source: the demuxer stands at the audio lead
    /// by then, so it would take a seek, which cuts the audio that is still playing, to put the dropped
    /// lead back. The outcome is a gap of up to that lead, and then sync as before. The video queue is
    /// not touched by this flush, so the host does not react to it; it repositions only when its own
    /// video queue was flushed and the picture would stay frozen for longer than the audio lead
    /// (`FlushRecoveryPolicy`).
    ///
    /// The line is also the witness the field log lacked. Across an automatic flush the timebase
    /// keeps RUNNING at its rate, so a session that froze did not freeze because of this, and only a
    /// log carrying both can tell the two apart.
    private func observeAutomaticFlush() {
        automaticFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let flushedFrom = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)
                .map { self.timeline.sourceTime(forRenderer: $0.timeValue).seconds }
            automaticFlushQueue.async { [weak self] in
                guard let self else { return }
                lock.lock()
                _automaticFlushCount += 1
                let count = _automaticFlushCount
                renderer.flush()
                lock.unlock()
                EngineLog.emit(
                    "[AudioOutput] AE#549 renderer flushed itself (#\(count)): "
                    + "dropped from \(flushedFrom.map { String(format: "%.3f", $0) } ?? "unknown")s, "
                    + "clock at \(String(format: "%.3f", currentTimeSeconds))s rate=\(rate); "
                    + "audio returns once the feed reaches the clock",
                    category: .swPlayback
                )
            }
        }
    }

    /// Add the video renderer to the synchronizer for automatic A/V sync + frame pacing. The display layer's
    /// `sampleBufferRenderer`, never the layer: addRenderer(layer) still type-checks but on tvOS 26+ fails with
    /// FigVideoQueueRemote err=-12080 after the first enqueue. The layer is main-actor isolated in the 27 SDKs,
    /// hence the isolation here (#351).
    @MainActor
    func attachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        precondition(videoLayerRemovalTask == nil, "Await video layer removal before attaching again")
        guard attachedVideoLayer !== displayLayer else { return }
        precondition(attachedVideoLayer == nil, "An audio output owns only one video layer")
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        attachedVideoLayer = displayLayer
    }

    /// Retire the old session's layer without blocking the caller. SoftwarePlaybackHost creates a
    /// fresh renderer for every new session, so the retired layer is never reused by its successor. The task
    /// retains this output, its synchronizer, and the layer until AVFoundation finishes removal; cancellation
    /// must not release them early. A caller that needs to reuse this same layer must await the returned task.
    /// The injected operation lets tests hold the completion while checking main-actor responsiveness/lifetime.
    @MainActor
    @discardableResult
    func detachVideoLayer(
        _ displayLayer: AVSampleBufferDisplayLayer,
        removeRenderer: @escaping @MainActor (AVSampleBufferRenderSynchronizer, AVSampleBufferDisplayLayer) async -> Void = AudioOutput.removeVideoRenderer
    ) -> Task<Void, Never>? {
        guard attachedVideoLayer === displayLayer else { return nil }
        if let videoLayerRemovalTask { return videoLayerRemovalTask }
        let task = Task { @MainActor [self, displayLayer] in
            await removeRenderer(synchronizer, displayLayer)
            attachedVideoLayer = nil
            videoLayerRemovalTask = nil
            withExtendedLifetime((self, displayLayer)) {}
        }
        videoLayerRemovalTask = task
        return task
    }

    @MainActor
    private static func removeVideoRenderer(
        from synchronizer: AVSampleBufferRenderSynchronizer,
        displayLayer: AVSampleBufferDisplayLayer
    ) async {
        await withCheckedContinuation { continuation in
            // Invalid time requests immediate removal, independent of a stopped/reset timebase.
            // Only the continuation crosses into AVFoundation's completion queue.
            // AVFoundation reports false for an absent renderer or a superseded removal.
            // This is the attachment's only remover and duplicate requests share its task,
            // so no second removal can supersede it; either result finishes retirement.
            synchronizer.removeRenderer(displayLayer.sampleBufferRenderer, at: .invalid) { _ in
                continuation.resume()
            }
        }
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Update transport authority without starting an unanchored clock. A disabled output can
    /// still seek at rate zero; only an explicit play enables positive rates again.
    func setPlaybackEnabled(_ enabled: Bool) {
        lock.lock()
        playbackEnabled = enabled
        // Enabling owns no clock write. A feeder may already hold the revision for an arm
        // whose latch play() has not seen yet; that correction still owes the initial start.
        guard !enabled else { lock.unlock(); return }
        _clockCommandRevision &+= 1
        endPreroll()
        let at = synchronizer.currentTime()
        let sourceSeconds = timeline.sourceSeconds(forRenderer: at.seconds)
        // Unconditional: `synchronizer.rate` reads back asynchronously, and a start issued just
        // before this can still read 0 here. Skipping the stop on that read let it commit later.
        synchronizer.setRate(0, time: at)
        lock.unlock()
        EngineLog.emit("[AudioOutput] pause at t=\(String(format: "%.3f", sourceSeconds)) (host transport disabled)",
                       category: .swPlayback)
    }

    /// Set playback speed (0.5-2.0). Hosts retain their preferred speed; explicit pause wins.
    /// A queued correction supplies `ifRevision`; normal transport commands omit it.
    func setRate(_ rate: Float, ifRevision revision: UInt64? = nil) {
        // A host resumes right after it arms the clock; while a preroll waits, that rate is the one
        // the preroll starts at, not a start of its own.
        if rate > 0, updatePrerollRate(rate, ifRevision: revision) { return }
        // A clock that stands still starts through the preroll on a session that has one: a seek
        // landed while paused anchors at rate 0 and never asks the gate, so the play that follows
        // would otherwise start it with nothing queued.
        if rate > 0, synchronizer.rate == 0, videoPrerollSatisfied?(currentTime.seconds) != nil {
            seekClock(to: currentTime, rate: rate, ifRevision: revision)
            return
        }
        lock.lock()
        if (rate != 0 && !playbackEnabled) || (revision != nil && revision != _clockCommandRevision) {
            lock.unlock()
            return
        }
        _clockCommandRevision &+= 1
        endPreroll()
        let at = synchronizer.currentTime()
        let sourceSeconds = timeline.sourceSeconds(forRenderer: at.seconds)
        synchronizer.setRate(rate, time: at)
        lock.unlock()
        EngineLog.emit("[AudioOutput] setRate \(rate) at t=\(String(format: "%.3f", sourceSeconds))", category: .swPlayback)
    }

    /// Pause audio (and the master clock). Hosts resume via setRate (pausedByHost pattern); deliberately no resume() here.
    func pause() {
        lock.lock()
        _clockCommandRevision &+= 1
        endPreroll()
        let at = synchronizer.currentTime()
        let sourceSeconds = timeline.sourceSeconds(forRenderer: at.seconds)
        synchronizer.setRate(0.0, time: at)
        lock.unlock()
        EngineLog.emit("[AudioOutput] pause at t=\(String(format: "%.3f", sourceSeconds))", category: .swPlayback)
    }

    /// Pause the master clock, at `latest` if it has already run past it. A park deferred to the last
    /// sample runs whenever its task is scheduled, and on a starved main actor that is after the clock
    /// has walked on (#694: 1.149 s on a 1.0 s source on a CI runner).
    func pause(notAfter latest: Double) {
        lock.lock()
        _clockCommandRevision &+= 1
        endPreroll()
        let now = timeline.sourceTime(forRenderer: synchronizer.currentTime())
        let seconds = SoftwareEndOfMediaClock.parkSeconds(clockSeconds: CMTimeGetSeconds(now), notAfter: latest)
        let at = seconds.map { CMTime(seconds: $0, preferredTimescale: 90000) } ?? now
        synchronizer.setRate(0.0, time: timeline.rendererTime(forSource: at))
        lock.unlock()
        EngineLog.emit("[AudioOutput] pause at t=\(String(format: "%.3f", at.seconds))", category: .swPlayback)
    }

    /// AE#464: set the audio presentation offset. Positive presents audio later than video, which on
    /// this path means stamping its samples further ahead on the synchronizer's timeline: at clock
    /// time t the renderer then plays what was recorded at t minus the offset, while the video layer
    /// still presents t. Applied to buffers enqueued from here on; the samples already inside the
    /// renderer keep the previous offset until something flushes them.
    func setPresentationOffset(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        presentationOffset = seconds == 0 ? .zero : CMTime(seconds: seconds, preferredTimescale: 90000)
        loggedOffsetInEffect = false
    }

    /// Enqueue a decoded audio CMSampleBuffer. Always enqueues (renderer buffers internally); gating on
    /// isReadyForMoreMediaData dropped early samples before the synchronizer started, giving silence.
    ///
    /// Audit DEC-106: with `epoch`, the buffer is enqueued only if no flush has retired that epoch, and the
    /// comparison and the enqueue happen under the lock `flush` takes. Returns false, enqueuing nothing,
    /// for a buffer that predates a flush.
    ///
    /// AE#464: this is where a lip-sync offset is applied, and the position is the point. It is past
    /// the audio tap (whose `sourceTime` is documented as the SOURCE axis and feeds transcription),
    /// past the decoder's gapless clock (which would absorb a sub-100 ms offset as rounding), and
    /// past the caller's `lastEnqueuedAudioPtsSec` bookkeeping (whose lead is measured against the
    /// synchronizer clock, i.e. against the source axis too). Only the renderer sees the shift.
    @discardableResult
    func enqueue(sampleBuffer: CMSampleBuffer, ifEpoch epoch: UInt64? = nil) -> Bool {
        lock.lock()
        if let epoch, epoch != _epoch {
            lock.unlock()
            return false
        }
        let offset = presentationOffset
        // AE#395: the lip-sync offset and the move onto the renderer axis are one retime, not two copies.
        let shift = CMTimeSubtract(offset, timeline.offset(latchingFrom: sampleBuffer))
        let delivered = shift == .zero ? sampleBuffer : Self.retimed(sampleBuffer, by: shift)
        var offsetLine: String?
        if offset != .zero, !loggedOffsetInEffect, delivered !== sampleBuffer {
            loggedOffsetInEffect = true
            // Release-visible, once per offset change: an offset that was set and an offset that is being
            // DELIVERED are different claims, and without this line the difference is only measurable with
            // a capture card. The two timestamps are the whole proof.
            let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            offsetLine = "[AudioOutput] AE#464 audio delay in effect: "
                + String(format: "%+.0f ms", offset.seconds * 1000)
                + String(format: " (sample at %.3fs delivered at %.3fs)", source, source + offset.seconds)
        }
        renderer.enqueue(delivered)
        #if DEBUG
        afterRendererEnqueueForTesting?()
        #endif
        lock.unlock()
        if let offsetLine { EngineLog.emit(offsetLine, category: .swPlayback) }

        #if DEBUG
        // Once per session: first enqueue + any renderer rejection, to distinguish "nothing enqueued" from
        // "renderer rejected our format".
        if !_loggedFirstEnqueue {
            _loggedFirstEnqueue = true
            let fmt = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let sr = fmt.map { "\($0.mSampleRate)Hz" } ?? "?"
            let ch = fmt.map { "\($0.mChannelsPerFrame)ch" } ?? "?"
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            EngineLog.emit("[AudioOutput] first enqueue: \(sr) \(ch), \(count) samples, renderer.error=\(String(describing: renderer.error))", category: .swPlayback)
        }
        #endif
        // Unconditional: a format the renderer refuses (a compressed or APAC route) otherwise plays
        // silence with nothing in a release log to say why.
        if !_loggedRendererError, let err = renderer.error {
            _loggedRendererError = true
            let fmt = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let id = fmt.map { String(format: "0x%08x", $0.mFormatID) } ?? "?"
            EngineLog.emit("[AudioOutput] ERROR: renderer error on format \(id): \(err)", category: .swPlayback)
        }
        return true
    }

    #if DEBUG
    /// Test-only: runs inside `enqueue`'s locked section, right after the renderer took the buffer, which
    /// is where a renderer that posts its notifications from inside `enqueue` would post them.
    var afterRendererEnqueueForTesting: (@Sendable () -> Void)?

    /// Holds a pending start without its timeout, so transport tests exercise cancellation
    /// independently of how long the main actor takes to run on a loaded test runner.
    func holdPrerollForTesting(rate: Float) {
        lock.lock()
        defer { lock.unlock() }
        _clockCommandRevision &+= 1
        endPreroll()
        prerollRate = rate
    }

    var prerollRateForTesting: Float? {
        lock.lock()
        defer { lock.unlock() }
        return prerollRate
    }

    private var _loggedFirstEnqueue = false
    #endif
    private var _loggedRendererError = false

    /// The shift itself, pure so it can be checked without a renderer. Every timing entry moves
    /// by `offset`, presentation and decode alike; an entry with no valid presentation stamp is left
    /// alone rather than given one. A copy that cannot be made is delivered unshifted: an audible
    /// lip-sync error is a far better outcome than a dropped buffer, which is silence.
    static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        guard offset != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0 else { return sampleBuffer }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: Int(count))
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: nil) == noErr else {
            return sampleBuffer
        }
        for i in timings.indices where timings[i].presentationTimeStamp.isValid {
            timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, offset)
            }
        }
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &shifted) == noErr,
              let shifted else { return sampleBuffer }
        return shifted
    }

    var currentTime: CMTime {
        timeline.sourceTime(forRenderer: synchronizer.currentTime())
    }

    /// AE#395: the master clock on the source axis, for an overlay paced against it (#311). The
    /// synchronizer's own timebase until the origin latches at a non-zero value, then a child of it
    /// shifted by that origin, which follows every rate change of its parent by construction. Read it
    /// per use rather than holding it across a session start.
    var sourceTimebase: CMTimebase {
        guard let origin = timeline.origin, origin != 0 else { return synchronizer.timebase }
        lock.lock()
        defer { lock.unlock() }
        if let shiftedTimebase { return shiftedTimebase }
        var child: CMTimebase?
        guard CMTimebaseCreateWithSourceTimebase(allocator: kCFAllocatorDefault,
                                                 sourceTimebase: synchronizer.timebase,
                                                 timebaseOut: &child) == noErr,
              let child,
              CMTimebaseSetRateAndAnchorTime(child, rate: 1, anchorTime: RendererTimeline.cmTime(origin),
                                             immediateSourceTime: .zero) == noErr else {
            return synchronizer.timebase
        }
        shiftedTimebase = child
        return child
    }
    private var shiftedTimebase: CMTimebase?

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
    }

    /// Whether the audio renderer can accept more samples. The combined demux loop normally paces on the
    /// video renderer; in background-audio-only mode (video dropped) it paces on this instead, so it does
    /// not buffer the rest of the file unbounded.
    var isReadyForMoreMediaData: Bool {
        renderer.isReadyForMoreMediaData
    }

    /// Flush the audio renderer (call on seek).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        _clockCommandRevision &+= 1
        _epoch &+= 1
        renderer.flush()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        _clockCommandRevision &+= 1
        _epoch &+= 1
        playbackEnabled = false
        endPreroll()
        // Hosts discard the output after stop. An already-paused clock needs no time reset;
        // its native rate is updated synchronously even while the timebase settles.
        if synchronizer.rate != 0 {
            synchronizer.setRate(0.0, time: .zero)
        }
        renderer.flush()
    }

    /// Atomically jump the master clock to a time and resume at a rate. The ONLY way the clock is (re)anchored:
    /// demux loops call it once on the first decoded packet, seek paths call it directly. Avoids the
    /// falling-through-time races that pause -> flush -> setRate would expose.
    func seekClock(to time: CMTime, rate: Float, ifRevision revision: UInt64? = nil) {
        // Asked before taking `lock`: the gate reads the video renderer's state under its own lock.
        let preroll = rate > 0 ? videoPrerollSatisfied?(time.seconds) : nil
        let progress = preroll == false ? videoPrerollProgress?() : nil
        lock.lock()
        defer { lock.unlock() }
        if let revision, revision != _clockCommandRevision { return }
        let rate = playbackEnabled ? rate : 0
        _clockCommandRevision &+= 1
        EngineLog.emit("[AudioOutput] seekClock to=\(String(format: "%.3f", time.seconds)) rate=\(rate)", category: .swPlayback)
        endPreroll()
        switch rate > 0 ? preroll : nil {
        case nil:
            synchronizer.setRate(rate, time: timeline.rendererTime(forSource: time))
        case true?:
            startAfterPreroll(rate: rate, time: time)
        case false?:
            synchronizer.setRate(0, time: timeline.rendererTime(forSource: time))
            let gen = prerollGeneration
            prerollRate = rate
            let started = CACurrentMediaTime()
            _onPrerollTransition?(PrerollTransition(generation: gen, event: .began))
            let wait = PrerollWait(gen: gen, time: time, started: started,
                                   progress: progress, progressAt: started)
            prerollQueue.async { [weak self] in self?.pollPreroll(wait) }
        }
    }

    // MARK: - Video preroll

    /// Whether the video renderer holds enough to start the clock at a source time: nil when this
    /// session does not preroll, so the clock starts at once as it always has. Set by the software
    /// host (`SampleBufferRenderer.prerollSatisfied(clock:live:)`): the FEL route since #774, every
    /// other VOD route since #800.
    ///
    /// The video queue is filled with the timebase stopped and the clock starts only once that is done,
    /// the same idea as `AVPlayer.preroll(atRate:)`. Starting at full rate the moment
    /// the first packet arrives made the first composed FEL frames late on arrival: five dropped
    /// frames at every start and every seek on an Apple TV 4K (A12). With the preroll, `seekClock`
    /// anchors at rate 0, and the clock starts at the requested rate and the same source time once
    /// the renderer is ready, or after `prerollTimeout`. A pause, a rate change or another seek in the
    /// meantime cancels the start; `stop()` too.
    var videoPrerollSatisfied: (@Sendable (Double) -> Bool?)? {
        get { lock.lock(); defer { lock.unlock() }; return _videoPrerollSatisfied }
        set { lock.lock(); _videoPrerollSatisfied = newValue; lock.unlock() }
    }
    private var _videoPrerollSatisfied: (@Sendable (Double) -> Bool?)?  // guarded by lock

    /// The decoder's progress for the preroll (`VideoDecodingPipeline.framesDecoded`): a hold whose
    /// decoder keeps producing frames, the ones it skips on the way to the target included, may outlast
    /// `prerollTimeout` up to `prerollProgressCap`. nil, or a count that never moves, keeps the plain
    /// timeout.
    var videoPrerollProgress: (@Sendable () -> UInt64)? {
        get { lock.lock(); defer { lock.unlock() }; return _videoPrerollProgress }
        set { lock.lock(); _videoPrerollProgress = newValue; lock.unlock() }
    }
    private var _videoPrerollProgress: (@Sendable () -> UInt64)?  // guarded by lock

    /// Every hold of the clock and its end, in order (`AetherEngine.clockHoldEvents`). Called off main
    /// with `lock` held, so it must not call back into this object.
    var onPrerollTransition: (@Sendable (PrerollTransition) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onPrerollTransition }
        set { lock.lock(); _onPrerollTransition = newValue; lock.unlock() }
    }
    private var _onPrerollTransition: (@Sendable (PrerollTransition) -> Void)?  // guarded by lock

    struct PrerollTransition: Sendable, Equatable {
        let generation: Int
        let event: ClockHoldEvent
    }

    /// How long a preroll may hold the clock with the decoder producing nothing. A decoder that never
    /// delivers must not freeze playback.
    static let prerollTimeout: Double = 2

    /// How long a preroll may hold the clock while the decoder is still producing frames. 4K AV1 in
    /// libdav1d on an Apple TV 4K (A15) took 2.9 to 3.9 s from a seek to its first frame at the target,
    /// so a plain 2 s timeout started the clock 0.6 to 1.6 s ahead of the picture and dropped what it
    /// owed (#800).
    static let prerollProgressCap: Double = 6

    /// How far ahead of now a prerolled start is scheduled. On tvOS the synchronizer lives in another
    /// process, and the display path learns of a rate change about as late as the audio route's output
    /// latency (138 ms measured on HDMI): a clock started "now" has already run that far when the first
    /// frames are judged, and the ones due inside that window drop (3 to 5 a start on the A12 even with
    /// the queue full). Scheduling the start 250 ms out took starts and seeks to 0 drops in every run
    /// (8 of 8, 150 s soaks with 5 seeks; 500 ms was no better).
    static let prerollStartLead: Double = 0.25

    private var prerollGeneration = 0  // guarded by lock
    private var prerollRate: Float?  // guarded by lock; non-nil while a preroll waits: the rate it starts at
    private let prerollQueue = DispatchQueue(label: "aether.audio.preroll", qos: .userInteractive)

    /// Whether a preroll holds the clock at rate 0 to start it later. A host must not read that
    /// standing clock as stalled (AE#549) and restart it.
    var prerollPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return prerollRate != nil
    }

    private struct PrerollWait: Sendable {
        let gen: Int
        let time: CMTime
        let started: CFTimeInterval
        var progress: UInt64?
        var progressAt: CFTimeInterval
    }

    /// Whether a hold that is not ready yet waits on: inside `prerollTimeout` of its start or of the
    /// decoder's last frame, and never past `prerollProgressCap`.
    static func prerollKeepsWaiting(waited: Double, sinceProgress: Double) -> Bool {
        waited < prerollProgressCap && sinceProgress < prerollTimeout
    }

    private func pollPreroll(_ wait: PrerollWait) {
        // A pause, seek or stop since: this chain is over. Without the check every cancelled preroll
        // polled on at 500 Hz, taking both locks, until its gate opened or it timed out.
        lock.lock()
        let current = prerollGeneration == wait.gen && prerollRate != nil
        lock.unlock()
        guard current else { return }
        let ready = videoPrerollSatisfied?(wait.time.seconds) != false
        let now = CACurrentMediaTime()
        var wait = wait
        if let count = videoPrerollProgress?(), count != wait.progress {
            if wait.progress != nil { wait.progressAt = now }
            wait.progress = count
        }
        let waited = now - wait.started
        if !ready, Self.prerollKeepsWaiting(waited: waited, sinceProgress: now - wait.progressAt) {
            let next = wait
            prerollQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                self?.pollPreroll(next)
            }
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard playbackEnabled, prerollGeneration == wait.gen, let rate = prerollRate else { return }
        prerollRate = nil
        EngineLog.emit("[AudioOutput] preroll \(ready ? "ready" : "timed out") after "
                       + "\(String(format: "%.0f", waited * 1000)) ms; starting at t=\(String(format: "%.3f", wait.time.seconds)) rate=\(rate)",
                       category: .swPlayback)
        startAfterPreroll(rate: rate, time: wait.time)
        let release: ClockHoldRelease = ready ? .ready(waitedSeconds: waited) : .timedOut(waitedSeconds: waited)
        _onPrerollTransition?(PrerollTransition(generation: wait.gen, event: .released(release)))
    }

    /// Starts the clock `prerollStartLead` from now. Called with `lock` held.
    private func startAfterPreroll(rate: Float, time: CMTime) {
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let host = CMTimeAdd(hostNow, CMTime(seconds: Self.prerollStartLead, preferredTimescale: 1_000_000_000))
        synchronizer.setRate(rate, time: timeline.rendererTime(forSource: time), atHostTime: host)
    }

    /// Retires the current preroll chain, and reports a hold that was still waiting as cancelled.
    /// Called with `lock` held.
    private func endPreroll() {
        if prerollRate != nil {
            _onPrerollTransition?(PrerollTransition(generation: prerollGeneration, event: .released(.cancelled)))
        }
        prerollGeneration &+= 1
        prerollRate = nil
    }

    private func updatePrerollRate(_ rate: Float, ifRevision revision: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let revision, revision != _clockCommandRevision { return false }
        // A stale feeder resume is handled even without a pending preroll. The final clock
        // write checks again in case an explicit pause lands after this preflight.
        guard playbackEnabled else { return true }
        guard prerollRate != nil else { return false }
        _clockCommandRevision &+= 1
        prerollRate = rate
        return true
    }
}
