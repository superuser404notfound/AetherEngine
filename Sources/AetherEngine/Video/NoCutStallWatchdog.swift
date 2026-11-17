import Foundation

/// AE#406: the live no-cut stall decision, held off the read thread it judges.
///
/// The decision used to be evaluated inline at the top of `HLSSegmentProducer`'s read loop, which
/// meant it could only run between `av_read_frame` calls. `av_read_frame` does not return before a
/// whole packet is assembled and carries no `interrupt_callback`, so an origin too slow to complete
/// one packet inside the watchdog window did not make the watchdog late, it made it unable to run:
/// measured on a trickling origin, a 35 s window fired at 48 s, 30 ms after a 46.9 s read finally
/// returned. Same shape as the reader-side defect #309, where the precondition that had to go was
/// "a consumer must be blocked on it".
///
/// So the window lives here instead. The pump thread reports what it reads (`note…`), a timer asks
/// for a verdict (`evaluate`), and both meet under one lock. The classifier itself is unchanged and
/// still `HLSSegmentProducer.noCutStallAction`.
///
/// Two properties the caller depends on:
///
/// - **The exit is a latch.** `evaluate` returns `.exitForRetune` exactly once, and nothing clears
///   it afterwards. A finalize that lands in the microseconds between the verdict and the abort
///   does not un-decide it: the pump is already on its way out, and a retune one segment late is
///   the same outcome the inline watchdog produced.
/// - **A parked pump is not judged.** The live headroom park sleeps the read thread on purpose,
///   for a consumer that stopped polling. Counting that time would report a dead consumer as a
///   dead source, so the park brackets it with `setReading(false:)` / `setReading(true:)` and the
///   window re-anchors on release.
final class NoCutStallWatchdog: @unchecked Sendable {

    /// One verdict's view of the window, for the line the caller logs. Carries every number the
    /// inline watchdog used to print, so the log vocabulary does not change with the position.
    struct Window: Equatable {
        var stalledFor: TimeInterval
        var packetsRead: Int
        var progress: Int
        var readRate: Double
        var videoPtsAdvanceSeconds: Double
        var videoPackets: Int
        var videoKeyframes: Int
        /// AE#432: how many of `videoPackets` reached the pump without a timestamp of their own, so
        /// `videoPtsAdvanceSeconds` is measuring a clock the engine synthesized rather than the
        /// source's. A window that is all synthesized cannot be read as a statement about delivery.
        var synthesizedVideoPackets: Int
        var audioPackets: Int
        var foreignPackets: Int
        var lastForeignStreamIndex: Int32
        var consecutiveHolds: Int
        /// AE#446 round 8: whether anything has ever been cut on this producer. False for the window
        /// a join is armed with, and the two shapes read differently: "nothing since the last
        /// segment" is a source that stopped, "nothing at all" is a join that never started.
        var everProduced: Bool = true

        /// Reads at full rate with nothing cut: a wedged cutter rather than a starved source.
        ///
        /// AE#446 round 8: only once something has been cut. A cutter that has not reached its first
        /// keyframe is indistinguishable from one that cannot cut what it is given, so a join is
        /// never read as a wedge.
        var isWedge: Bool {
            everProduced && readRate >= HLSSegmentProducer.liveWedgeProgressRateThreshold
        }
    }

    enum Decision: Equatable {
        case holdForSlowDelivery(Window)
        /// AE#446 round 3: a starved source whose closed window is still feeding the consumer. The
        /// exit would tear down the read that is the only thing able to see the source come back, and
        /// a session that is still delivering pictures with it.
        case holdForOutageRunway(Window)
        case exitForRetune(Window)
    }

    private let lock = NSLock()
    private let videoTimeBaseSeconds: Double

    /// Wall-clock of the last finalized live segment, or of the join this producer was armed at.
    /// Nil until one of the two: before that there is no window and nothing to judge.
    private var lastFinalizeAt: Date?
    /// AE#446 round 8: whether a real finalize has ever landed, as opposed to the join arming.
    private var everFinalized = false
    /// #177 hold: the window measures from here once a slow-delivery hold has re-armed it.
    private var holdRearmedAt: Date?
    private var consecutiveHolds = 0
    private var reading = true
    private var replayChecking = false
    private var replayLastPacketAt: Date?
    private var exitLatched = false

    private var packetsRead = 0
    private var packetsReadAtWindowStart = 0
    private var videoPackets = 0
    private var videoKeyframes = 0
    private var synthesizedVideoPackets = 0
    private var audioPackets = 0
    private var foreignPackets = 0
    private var lastForeignStreamIndex: Int32 = -1
    private var firstVideoPts: Int64 = Int64.min
    private var lastVideoPts: Int64 = Int64.min

    /// The exit's abort and the pump's retirement meet under their own lock, not `lock`: the abort
    /// closes the demuxer, and the pump's `note…` calls must not queue behind that.
    private let exitGate = NSLock()
    private var retired = false

    init(videoTimeBaseSeconds: Double) {
        self.videoTimeBaseSeconds = videoTimeBaseSeconds
    }

    // MARK: - Exit gate

    /// The pump calls this on its way out, before it reports its exit. Returns only once an abort
    /// already running has finished, and no abort runs after it. A live producer rebuilt in place
    /// reads the same demuxer, so an abort that landed after this would close the successor's read
    /// (audit 03, cross-slice to the segment pipeline).
    func retire() {
        exitGate.lock()
        retired = true
        exitGate.unlock()
    }

    /// Runs the exit's `abort` unless the pump has already retired this watchdog. False when it did
    /// not run.
    @discardableResult
    func performExit(_ abort: () -> Void) -> Bool {
        exitGate.lock()
        defer { exitGate.unlock() }
        guard !retired else { return false }
        abort()
        return true
    }

    // MARK: - Pump thread

    /// A live segment was finalized: the window starts over from this instant.
    func noteFinalize(at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        lastFinalizeAt = now
        everFinalized = true
        holdRearmedAt = nil
        consecutiveHolds = 0
        resetWindowCounters()
    }

    /// AE#446 round 8: the live pump began reading and nothing has been cut yet.
    ///
    /// Without this the first deadline of a session is set by its first cut, so a source that stops
    /// at the join is never judged at all: `evaluate` returns on the nil window for as long as the
    /// session lasts. Never moves a window a finalize already owns, so a producer that starts its
    /// pump again after cutting keeps measuring from the cut.
    func armForJoin(at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard lastFinalizeAt == nil else { return }
        lastFinalizeAt = now
        holdRearmedAt = nil
        consecutiveHolds = 0
        resetWindowCounters()
    }

    func notePacketRead() {
        lock.lock()
        packetsRead += 1
        lock.unlock()
    }

    /// A verified-overlap scan intentionally cannot cut a segment. Keep watching the source for
    /// starvation without classifying those packets as a stuck cutter.
    func setReplayChecking(_ checking: Bool, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard replayChecking != checking else { return }
        replayChecking = checking
        replayLastPacketAt = checking ? now : nil
        holdRearmedAt = now
        consecutiveHolds = 0
        resetWindowCounters()
    }

    func noteReplayPacketRead(at now: Date) {
        lock.lock()
        packetsRead += 1
        replayLastPacketAt = now
        lock.unlock()
    }

    func noteVideoPacket(pts: Int64, isKeyframe: Bool, synthesizedTimestamp: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        videoPackets += 1
        if isKeyframe { videoKeyframes += 1 }
        if synthesizedTimestamp { synthesizedVideoPackets += 1 }
        guard pts != Int64.min else { return }
        if firstVideoPts == Int64.min { firstVideoPts = pts }
        lastVideoPts = pts
    }

    func noteAudioPacket() {
        lock.lock()
        audioPackets += 1
        lock.unlock()
    }

    func noteForeignPacket(streamIndex: Int32) {
        lock.lock()
        foreignPackets += 1
        lastForeignStreamIndex = streamIndex
        lock.unlock()
    }

    /// Brackets a deliberate park of the read thread. Releasing re-anchors the window: the pump was
    /// not reading because it was told not to, which is not a statement about the source.
    func setReading(_ isReading: Bool, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard isReading != reading else { return }
        reading = isReading
        if isReading {
            holdRearmedAt = now
            resetWindowCounters()
        }
    }

    // MARK: - Timer thread

    var hasLatchedExit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitLatched
    }

    /// One evaluation. Returns nil while there is nothing to say: not armed, parked, already
    /// latched, or simply healthy.
    ///
    /// `servingOutageRunway` is read by the caller at verdict time rather than tracked here: it is a
    /// fact about the CONSUMER (how far into a closed window it has walked), which this watchdog
    /// knows nothing about and which changes while the window is being judged.
    func evaluate(now: Date, servingOutageRunway: Bool = false) -> Decision? {
        lock.lock()
        defer { lock.unlock() }
        guard !exitLatched, reading, let finalizeAt = lastFinalizeAt else { return nil }
        if replayChecking {
            // The producer is checking an already-muxed overlap and cannot finalize yet. A dead
            // source must still be interruptible while it is parked inside av_read_frame.
            let quietFor = now.timeIntervalSince(replayLastPacketAt ?? finalizeAt)
            guard quietFor > HLSSegmentProducer.liveSourceStarvationTimeoutSeconds else { return nil }
            exitLatched = true
            return .exitForRetune(makeWindow(stalledFor: quietFor,
                                             progress: packetsRead - packetsReadAtWindowStart,
                                             readRate: 0, ptsAdvance: -1))
        }
        let stalledFor = now.timeIntervalSince(holdRearmedAt ?? finalizeAt)
        let progress = packetsRead - packetsReadAtWindowStart
        let readRate = stalledFor > 0 ? Double(progress) / stalledFor : 0
        let ptsAdvance = (firstVideoPts != Int64.min && lastVideoPts != Int64.min
                          && videoTimeBaseSeconds > 0)
            ? Double(SourceTimestampBounds.difference(lastVideoPts, firstVideoPts)) * videoTimeBaseSeconds
            : -1
        switch HLSSegmentProducer.noCutStallAction(
            stalledFor: stalledFor,
            readRate: readRate,
            videoPtsAdvanceSeconds: ptsAdvance,
            consecutiveHolds: consecutiveHolds,
            servingOutageRunway: servingOutageRunway,
            hasEverProduced: everFinalized
        ) {
        case .keepReading:
            return nil
        case .holdForSlowDelivery:
            consecutiveHolds += 1
            let window = makeWindow(stalledFor: stalledFor, progress: progress,
                                    readRate: readRate, ptsAdvance: ptsAdvance)
            holdRearmedAt = now
            resetWindowCounters()
            // #177's hold is a WEDGE whose PTS is still advancing, so a held window that is not one
            // can only be the outage deferral: the two never overlap and the line can name which ran.
            return window.isWedge ? .holdForSlowDelivery(window) : .holdForOutageRunway(window)
        case .exitForRetune:
            exitLatched = true
            return .exitForRetune(makeWindow(stalledFor: stalledFor, progress: progress,
                                             readRate: readRate, ptsAdvance: ptsAdvance))
        }
    }

    // MARK: - Private

    private func makeWindow(stalledFor: TimeInterval, progress: Int,
                            readRate: Double, ptsAdvance: Double) -> Window {
        Window(
            stalledFor: stalledFor,
            packetsRead: packetsRead,
            progress: progress,
            readRate: readRate,
            videoPtsAdvanceSeconds: ptsAdvance,
            videoPackets: videoPackets,
            videoKeyframes: videoKeyframes,
            synthesizedVideoPackets: synthesizedVideoPackets,
            audioPackets: audioPackets,
            foreignPackets: foreignPackets,
            lastForeignStreamIndex: lastForeignStreamIndex,
            consecutiveHolds: consecutiveHolds,
            everProduced: everFinalized
        )
    }

    private func resetWindowCounters() {
        packetsReadAtWindowStart = packetsRead
        videoPackets = 0
        videoKeyframes = 0
        synthesizedVideoPackets = 0
        audioPackets = 0
        foreignPackets = 0
        lastForeignStreamIndex = -1
        firstVideoPts = Int64.min
        lastVideoPts = Int64.min
    }
}
