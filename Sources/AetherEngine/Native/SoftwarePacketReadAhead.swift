import Foundation

/// Compressed VOD packet prefetch, independent of renderer pacing. The producer owns source reads;
/// the consumer gets byte-identical packet envelopes from a bounded disk FIFO. No main-thread I/O.
/// Cached seeks move only the consumer cursor. A source reposition has a separate epoch, so an
/// in-flight producer packet is neither lost nor duplicated when replaying retained data.
final class SoftwarePacketReadAhead: @unchecked Sendable {
    struct Stream: Sendable {
        let index: Int32
        let numerator: Int32
        let denominator: Int32
    }
    struct Snapshot: Sendable {
        let packetCount: Int
        let bytes: Int
        let residentBytes: Int
        let frontier: Double?
        let generation: UInt64
        let seeking: Bool
        let sourceEnded: Bool
        let sourceEpoch: UInt64
        let cacheSeekHits: UInt64
        let cacheSeekMisses: UInt64
    }
    enum ReadError: Error { case interrupted, closed, corruptFIFO }

    private let condition = NSCondition()
    /// Never acquired by a main-thread API. Serializes reset with append/pop, including the
    /// generation check, so an old consumer cannot pop and discard the first NEW-generation packet.
    private let operations = NSLock()
    private let fifo: SoftwarePacketDiskFIFO
    private let readSource: @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?
    private let beforeConsumerOperation: (@Sendable () -> Void)?
    private let video: Stream
    private let audio: Stream?
    private let byteBudget: Int
    /// [MovieClaw P20] 可在运行中放大（`setForwardSeconds`）：线路跟不上时宿主把读前从 40 秒放到 3 分钟，暂停能多攒。
    /// 停泊判断在 `condition` 里读、调度等级在生产者线程上读，单独一把锁
    private var forwardSeconds: Double {
        forwardSecondsLock.lock(); defer { forwardSecondsLock.unlock() }
        return _forwardSeconds
    }
    private var _forwardSeconds: Double
    private let forwardSecondsLock = NSLock()

    func setForwardSeconds(_ seconds: Double) {
        forwardSecondsLock.lock()
        _forwardSeconds = max(1, seconds)
        forwardSecondsLock.unlock()
        condition.lock(); condition.broadcast(); condition.unlock()   // 停着的生产者按新窗口重判
    }
    /// Producer thread only. See `start()` for why this is a class the producer moves itself.
    private var producerQoS: qos_class_t = QOS_CLASS_USER_INITIATED
    /// Mirror of `producerQoS` for the consumer's diagnostics, under `condition`.
    private var reportedProducerQoS: qos_class_t = QOS_CLASS_USER_INITIATED
    /// Consumer threads currently parked in `read()`. Producer-visible, under `condition`.
    private var waitingConsumers = 0
    private var consumerWaitEvents: UInt64 = 0
    private var consumerBlockedSeconds: Double = 0
    private var lastStarvationLog: DispatchTime?
    private var generation: UInt64 = 0
    private var sourceEpoch: UInt64 = 0
    private var sourceRepositioning = false
    private var cacheSeekHits: UInt64 = 0
    private var cacheSeekMisses: UInt64 = 0
    private var resetPending = false
    private var seeking = false
    private var closed = false
    private var started = false
    private var ended = false
    private var failure: Error?
    private var count = 0
    private var bytes = 0
    private var residentBytes = 0
    private var sourceClock: Double
    /// Newest video presentation time handed to the store, and the one the consumer last took out
    /// of it. Their distance is the reservoir the producer is filling, and unlike the coverage
    /// frontier it survives a hole and a late timestamp, which is what keeps the forward-second
    /// limit in force on material the coverage model cannot describe.
    private var storedVideoSeconds: Double?
    private var consumedVideoSeconds: Double?
    private var videoCoverage: SoftwarePacketCoverage
    private var audioCoverage: SoftwarePacketCoverage
    private var presentationCoverage: SoftwareVideoPacketCoverage?
    private struct Keyframe {
        let seconds: Double
        let cursor: SoftwarePacketDiskFIFO.Cursor
    }
    private var keyframes: [Keyframe] = []
    private let maximumKeyframes = 65_536

    /// Construct only off-main: creating the FIFO touches the temporary volume.
    init(video: Stream, audio: Stream?, byteBudget: Int, forwardSeconds: Double,
         initialSourceClock: Double, fifo: SoftwarePacketDiskFIFO,
         videoReorderDepth: Int? = nil,
         coverageRangeCap: Int = 4096,
         beforeConsumerOperation: (@Sendable () -> Void)? = nil,
         readSource: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?) {
        self.video = video
        self.audio = audio
        self.byteBudget = max(1, byteBudget)
        self._forwardSeconds = max(1, forwardSeconds)
        self.sourceClock = initialSourceClock
        self.fifo = fifo
        self.videoCoverage = SoftwarePacketCoverage(maximumRangeCount: coverageRangeCap)
        self.audioCoverage = SoftwarePacketCoverage(maximumRangeCount: coverageRangeCap)
        self.presentationCoverage = videoReorderDepth.map {
            SoftwareVideoPacketCoverage(timeBaseNumerator: video.numerator,
                timeBaseDenominator: video.denominator, reorderDepth: $0,
                maximumRangeCount: coverageRangeCap)
        }
        self.beforeConsumerOperation = beforeConsumerOperation
        self.readSource = readSource
    }

    func start() {
        condition.lock()
        guard !started, !closed else { condition.unlock(); return }
        started = true
        condition.unlock()
        // AE#519: a thread we own rather than a DispatchQueue, because a queue's QoS is fixed at
        // creation and this producer's urgency changes INSIDE one long-running loop: elective while
        // the reservoir is deep, latency-critical the moment the consumer can reach it. The consumer
        // blocks on `condition` whenever the store runs dry and `NSCondition` donates no priority,
        // so a permanently demoted producer is an inversion dispatch cannot see, and one that was
        // measured failing to drain the link it had been given.
        let thread = Thread { self.produce() }
        thread.name = "AetherEngine.SoftwarePacketReadAhead.producer"
        thread.stackSize = 1 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        return Snapshot(packetCount: count, bytes: bytes, residentBytes: residentBytes,
                        frontier: sourceRepositioning || closed ? nil : frontierLocked(),
                        generation: generation, seeking: seeking, sourceEnded: ended,
                        sourceEpoch: sourceEpoch, cacheSeekHits: cacheSeekHits,
                        cacheSeekMisses: cacheSeekMisses)
    }

    /// Main-thread safe: metadata only. Decode/render backpressure still belongs to the old loop.
    func updatePlayhead(_ seconds: Double) {
        guard seconds.isFinite else { return }
        condition.lock()
        sourceClock = seconds
        // Presentation history stays useful for backward cached seeks. Coverage has a fixed range
        // cap; retained keyframe cursors, not a guessed timestamp floor, decide cache eligibility.
        condition.broadcast()
        condition.unlock()
    }

    /// Legacy explicit cold seek. Production first uses beginSeek(to:) + prepareSeek off-main.
    @discardableResult
    func beginSeek() -> UInt64 {
        condition.lock(); defer { condition.unlock() }
        generation &+= 1
        sourceEpoch &+= 1
        sourceRepositioning = true
        seeking = true
        resetPending = true
        clearSourceMetadataLocked()
        condition.broadcast()
        return generation
    }

    /// Main-thread safe: freeze only the decoder/consumer, not the source reader or retained data.
    @discardableResult
    func beginSeek(to seconds: Double) -> UInt64 {
        condition.lock(); defer { condition.unlock() }
        generation &+= 1
        seeking = true
        if seconds.isFinite { sourceClock = seconds }
        condition.broadcast()
        return generation
    }

    /// Off-main, BEFORE any actual demuxer reposition. true means the target is already retained.
    /// A hit does not change sourceEpoch: an in-flight source read must still be stored afterwards.
    func prepareSeek(_ token: UInt64, to seconds: Double) throws -> Bool {
        operations.lock(); defer { operations.unlock() }
        condition.lock()
        guard token == generation, seeking, !closed else {
            condition.unlock(); throw ReadError.interrupted
        }
        let hasCoverage = !sourceRepositioning && !resetPending && failure == nil
            && seconds.isFinite && (frontierLocked(at: seconds).map { $0 > seconds } ?? false)
        let candidates = hasCoverage ? keyframes.filter { $0.seconds <= seconds }
            .sorted { $0.seconds < $1.seconds } : []
        // A previous recovery/key picture supplies open-GOP/audio preroll when still retained.
        let anchor = candidates.isEmpty ? nil : candidates[max(0, candidates.count - 2)]
        condition.unlock()

        if let anchor {
            do {
                try fifo.restore(to: anchor.cursor)
                let state = fifo.snapshot
                condition.lock(); defer { condition.unlock() }
                guard token == generation, !closed else { throw ReadError.interrupted }
                copyDiskStateLocked(state)
                sourceClock = seconds
                // The cursor moved, so the reservoir is measured from the target again. Left at
                // the old high-water mark, a backward hit would read as a full reservoir and a
                // forward one as an empty one.
                consumedVideoSeconds = seconds
                cacheSeekHits &+= 1
                condition.broadcast()
                return true
            } catch SoftwarePacketDiskFIFO.Failure.invalidCursor {
                // An expired bookmark is a cache miss, never a playback/disk failure.
            } catch SoftwarePacketDiskFIFO.Failure.retentionDisabled {
                // Keeps callers using the legacy destructive FIFO safe during migration.
            }
        }

        condition.lock()
        guard token == generation, !closed else {
            condition.unlock(); throw ReadError.interrupted
        }
        sourceEpoch &+= 1
        sourceRepositioning = true
        // Discarding the spool is the WORKER's job, not the seek's. Reset removes every retained
        // chunk one by one, so its cost grows with what the session has kept: measured 4.5 ms at
        // 64 MB, 18.9 ms at 256 MB, 60.9 ms at 512 MB, on a ceiling of 2 GiB. Done inline, a miss
        // got slower the longer the session had been running, for work no seek waits on: the
        // producer parks on `sourceRepositioning` until `endSeek`, and takes the reset first.
        resetPending = true
        clearSourceMetadataLocked()
        sourceClock = seconds
        cacheSeekMisses &+= 1
        condition.broadcast()
        condition.unlock()
        return false
    }

    /// AE#605: the retained video packets a scrub still at `seconds` needs, keyframe first, or nil
    /// when the store cannot answer it. Any thread except main: it reads the disk.
    ///
    /// Eligibility is the cached seek's own rule, coverage past the target plus a retained keyframe
    /// at or before it, so a still is offered exactly where a commit to that position would be a
    /// cache hit, and the card never shows a picture the seek then has to fetch. Unlike the live
    /// ring there is no clamp at the end: a VOD target past the frontier has a real frame the store
    /// does not hold yet, and the frame before it is the wrong answer. The consumer cursor is not
    /// touched, so playback reads on from where it stood.
    func stillRun(atSeconds seconds: Double, maxPackets: Int, maxSpanSeconds: Double,
                  reorderTail: Int) -> [SoftwareStoredPacket]? {
        guard seconds.isFinite, maxPackets > 0 else { return nil }
        condition.lock()
        let eligible = !closed && !sourceRepositioning && !resetPending && failure == nil
            && (frontierLocked(at: seconds).map { $0 > seconds } ?? false)
        let anchor = eligible
            ? keyframes.filter { $0.seconds <= seconds }.max { $0.seconds < $1.seconds } : nil
        condition.unlock()
        guard let anchor, seconds - anchor.seconds <= maxSpanSeconds else { return nil }

        var run: [SoftwareStoredPacket] = []
        var reached = false
        var tail = reorderTail
        var overflow = false
        do {
            try fifo.readHistory(from: anchor.cursor) { data in
                let packet = try SoftwareStoredPacket.decode(data)
                guard packet.streamIndex == video.index else { return true }
                if run.isEmpty, packet.flags & 1 == 0 { overflow = true; return false }
                run.append(packet)
                if run.count > maxPackets { overflow = true; return false }
                if reached {
                    tail -= 1
                    return tail > 0
                }
                if let pts = videoSeconds(pts: packet.pts), pts >= seconds {
                    reached = true
                    return tail > 0
                }
                return true
            }
        } catch {
            return nil
        }
        guard reached, !overflow else { return nil }
        return run
    }

    func endSeek(_ token: UInt64, sourceClock: Double) {
        condition.lock(); defer { condition.unlock() }
        guard token == generation, !closed else { return }
        self.sourceClock = sourceClock
        seeking = false
        sourceRepositioning = false
        condition.broadcast()
    }

    /// Does not wait for a remote read or a disk operation. The host closes the Demuxer as usual,
    /// unblocking its reader; the worker then releases only its own unique FIFO directory.
    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        generation &+= 1
        sourceEpoch &+= 1
        clearSourceMetadataLocked()
        let needsCleanup = !started
        condition.broadcast()
        condition.unlock()
        if needsCleanup { DispatchQueue.global(qos: .utility).async { try? self.fifo.close() } }
    }

    /// Consumer thread only. nil means true EOF; a seek wake is explicitly different from EOF.
    func read(isCurrent: @Sendable () -> Bool = { true }) throws -> SoftwareStoredPacket? {
        condition.lock()
        let token = generation
        var waitStart: DispatchTime?
        var starvationLine: String?
        while count == 0, !ended, failure == nil, !closed, !seeking,
              token == generation, isCurrent() {
            if waitStart == nil {
                waitStart = .now()
                waitingConsumers += 1
                // Wake a parked producer so it can see the waiter at its next retune point.
                condition.broadcast()
            }
            condition.wait()
        }
        if let waitStart {
            waitingConsumers -= 1
            consumerWaitEvents &+= 1
            consumerBlockedSeconds += Double(DispatchTime.now().uptimeNanoseconds
                - waitStart.uptimeNanoseconds) / 1_000_000_000
            starvationLine = starvationLineLocked()
        }
        if closed { condition.unlock(); throw ReadError.closed }
        let hadPackets = count > 0
        condition.unlock()
        if let starvationLine { EngineLog.emit(starvationLine, category: .swPlayback) }

        if hadPackets { beforeConsumerOperation?() }
        operations.lock()
        defer { operations.unlock() }
        condition.lock()
        guard !closed else { condition.unlock(); throw ReadError.closed }
        // Admission belongs to the HOST generation too. Capturing only our generation at read()
        // entry can let an old host iteration steal the first packet of a completed new seek.
        guard !seeking, token == generation, isCurrent() else {
            condition.unlock(); throw ReadError.interrupted
        }
        if count == 0 {
            let error = failure
            condition.unlock()
            if let error { throw error }
            return nil
        }
        condition.unlock()
        guard let data = try fifo.pop() else { throw ReadError.corruptFIFO }
        let packet = try SoftwareStoredPacket.decode(data)
        // Equality parks the producer too. Reclaim an eligible consumed chunk at the exact ceiling,
        // otherwise it can remain asleep with unread packets until the queue drains completely.
        try fifo.trimConsumed(toByteBudget: max(0, byteBudget - 1))
        let state = fifo.snapshot
        condition.lock()
        defer { condition.unlock() }
        guard !closed, !seeking, token == generation, isCurrent() else { throw ReadError.interrupted }
        copyDiskStateLocked(state)
        if packet.streamIndex == video.index, let seconds = videoSeconds(pts: packet.pts) {
            consumedVideoSeconds = seconds
        }
        condition.broadcast()
        return packet
    }

    private func frontierLocked(at seconds: Double? = nil) -> Double? {
        let clock = seconds ?? sourceClock
        let videoEnd: Double?
        if let presentationCoverage {
            videoEnd = presentationCoverage.frontierSeconds(containing: clock,
                timeBaseNumerator: video.numerator, timeBaseDenominator: video.denominator)
        } else {
            videoEnd = videoCoverage.frontierSeconds(containing: clock,
                timeBaseNumerator: video.numerator, timeBaseDenominator: video.denominator)
        }
        let audioEnd = audio.flatMap { stream in
            audioCoverage.frontierSeconds(containing: clock,
                timeBaseNumerator: stream.numerator, timeBaseDenominator: stream.denominator)
        }
        return SoftwarePacketCoverage.combinedFrontier(
            video: videoEnd, audio: audioEnd, requiresAudio: audio != nil)
    }

    /// The playhead in a stream's ticks, rounded down so a prune never reaches past it.
    ///
    /// #613: coverage keeps its history behind the playhead for backward cached seeks, so a long
    /// session fills the range cap. A full coverage used to stop describing new packets (duration
    /// model) or invalidate itself (successor model), which left every frontier after the cap nil.
    /// Forgetting what lies wholly behind the playhead instead costs a backward cached seek into that
    /// history, which then goes cold.
    private func playheadTick(_ stream: Stream) -> Int64? {
        guard stream.numerator > 0, stream.denominator > 0 else { return nil }
        let ticks = (sourceClock * Double(stream.denominator) / Double(stream.numerator))
            .rounded(.down)
        guard ticks.isFinite, ticks > -9.0e18, ticks < 9.0e18 else { return nil }
        return Int64(ticks)
    }

    private func clearSourceMetadataLocked() {
        count = 0; bytes = 0; residentBytes = 0
        ended = false; failure = nil
        videoCoverage.reset(); audioCoverage.reset(); presentationCoverage?.reset()
        storedVideoSeconds = nil; consumedVideoSeconds = nil
        keyframes.removeAll(keepingCapacity: true)
    }

    /// Presentation seconds of a stored packet, or nil when this stream cannot express them.
    private func videoSeconds(pts: Int64) -> Double? {
        guard pts != Int64.min, video.numerator > 0, video.denominator > 0 else { return nil }
        let seconds = Double(pts) * Double(video.numerator) / Double(video.denominator)
        return seconds.isFinite ? seconds : nil
    }

    private func copyDiskStateLocked(_ state: SoftwarePacketDiskFIFO.Snapshot) {
        count = state.count
        bytes = state.byteCount
        residentBytes = state.residentByteCount
        if let floor = state.oldestRetainedChunkID {
            keyframes.removeAll { $0.cursor.chunkID < floor }
        } else { keyframes.removeAll(keepingCapacity: true) }
    }

    private func produce() {
        // AE#519: a started producer is latency-critical by construction. Nothing is stored for
        // this epoch yet, and both entry reasons, cold start and a seek landing, have the consumer
        // waiting on the first packet it delivers.
        applyProducerQoS(QOS_CLASS_USER_INITIATED, reservoir: nil, waiting: 0)
        defer { try? fifo.close() }
        while true {
            condition.lock()
            while !closed && !resetPending && (sourceRepositioning || ended || failure != nil || shouldParkLocked()) {
                condition.wait()
            }
            if closed { condition.unlock(); return }
            let token = sourceEpoch
            let reset = resetPending
            let reservoir = reservoirSecondsLocked()
            let waiting = waitingConsumers
            condition.unlock()
            // Both a packet boundary and a park wake are cheap and are points where the answer can
            // have changed. A parked producer costs nothing in any class, so nothing is lost by
            // only deciding here.
            retuneProducerQoS(reservoir: reservoir, waiting: waiting)

            if reset {
                operations.lock()
                do {
                    try fifo.reset()
                    condition.lock()
                    if token == sourceEpoch { resetPending = false }
                    condition.broadcast()
                    condition.unlock()
                } catch { recordFailure(error, token: token) }
                operations.unlock()
                continue
            }

            autoreleasepool {
                producePacket(token: token)
            }
        }
    }

    private func producePacket(token: UInt64) {
        do {
            let packet = try readSource { [self] in
                condition.lock(); defer { condition.unlock() }
                return token == sourceEpoch && !closed && !sourceRepositioning
            }
            guard let packet else {
                condition.lock()
                if token == sourceEpoch, !sourceRepositioning, !closed {
                    presentationCoverage?.finish()
                    ended = true
                }
                condition.broadcast()
                condition.unlock()
                return
            }
            let data = try packet.encoded()
            operations.lock()
            condition.lock()
            let valid = token == sourceEpoch && !closed && !sourceRepositioning
            condition.unlock()
            if valid {
                do {
                    let recordReservation = min(byteBudget, data.count)
                        + min(8, byteBudget - min(byteBudget, data.count))
                    try fifo.trimConsumed(toByteBudget: byteBudget - recordReservation)
                    let cursor = try fifo.append(data)
                    let state = fifo.snapshot
                    condition.lock()
                    if token == sourceEpoch, !closed, !sourceRepositioning {
                        copyDiskStateLocked(state)
                        if packet.streamIndex == video.index {
                            if presentationCoverage != nil {
                                if presentationCoverage?.isFull == true, let tick = playheadTick(video) {
                                    presentationCoverage?.prune(before: tick)
                                }
                                presentationCoverage?.insert(pts: packet.pts)
                            } else {
                                if videoCoverage.isFull, let tick = playheadTick(video) {
                                    videoCoverage.prune(before: tick)
                                }
                                videoCoverage.insert(pts: packet.pts, duration: packet.duration)
                            }
                            if let seconds = videoSeconds(pts: packet.pts) { storedVideoSeconds = seconds }
                            if packet.flags & 1 != 0, let seconds = videoSeconds(pts: packet.pts) {
                                keyframes.append(Keyframe(seconds: seconds, cursor: cursor))
                                if keyframes.count > maximumKeyframes {
                                    keyframes.removeFirst(min(1024, keyframes.count))
                                }
                            }
                        } else if let audio, packet.streamIndex == audio.index {
                            if audioCoverage.isFull, let tick = playheadTick(audio) {
                                audioCoverage.prune(before: tick)
                            }
                            audioCoverage.insert(pts: packet.pts, duration: packet.duration)
                        }
                    }
                    condition.broadcast()
                    condition.unlock()
                } catch { recordFailure(error, token: token) }
            }
            operations.unlock()
        } catch { recordFailure(error, token: token) }
    }

    /// [MovieClaw P23] 宿主要求暂停下载（蜂窝网 / 低数据模式下用户按了暂停）：已读到的留着，不再往前读
    private var prefetchSuspended = false

    func setPrefetchSuspended(_ suspended: Bool) {
        condition.lock()
        prefetchSuspended = suspended
        condition.broadcast()
        condition.unlock()
    }

    private func shouldParkLocked() -> Bool {
        // One source record can cross the budget. A consumed active chunk cannot be deleted before
        // cursor rollover, so residency also includes bounded protected chunk slack (not an
        // unbounded batch). Unknown time coverage is never guessed from bitrate.
        guard count > 0 else { return false }
        if prefetchSuspended { return true }   // [MovieClaw P23]
        if residentBytes >= byteBudget { return true }
        // The forward limit is measured on the RESERVOIR, from the packet the consumer last took
        // to the newest one stored, because that is what the producer is actually building and it
        // is knowable from two timestamps. The coverage frontier answers a stricter question (is
        // this stretch continuously playable) and returns nothing at all once a hole or one late
        // presentation timestamp invalidates it; keyed on that alone, the seconds limit stopped
        // existing there and only the disk budget still bounded the read-ahead. Measured on a
        // 10 s window: 283 packets read with clean timestamps, 1316 with a single late one, which
        // in a session is the difference between a window and the whole file.
        if let reservoir = reservoirSecondsLocked(), reservoir >= forwardSeconds { return true }
        return frontierLocked().map { $0 - sourceClock >= forwardSeconds } ?? false
    }

    private func recordFailure(_ error: Error, token: UInt64) {
        condition.lock(); defer { condition.unlock() }
        guard token == sourceEpoch, !closed else { return }
        failure = error
        resetPending = false
        condition.broadcast()
    }

    /// Seconds of video the producer has built ahead of the consumer: from the packet the consumer
    /// last took out of the store to the newest one put into it. nil when no stored timestamp can
    /// express it, which is a reason to stay responsive, never a reason to relax.
    private func reservoirSecondsLocked() -> Double? {
        guard let stored = storedVideoSeconds else { return nil }
        let seconds = stored - (consumedVideoSeconds ?? sourceClock)
        return seconds.isFinite ? max(0, seconds) : nil
    }

    /// AE#519: the producer may only drop to the efficiency class while the consumer provably
    /// cannot reach it. Two facts decide it, and both fail closed: a consumer parked in `read()` is
    /// waiting on this producer right now, and a reservoir that cannot be expressed in seconds is
    /// not a deep one. The depth rule is what keeps the inversion window from opening at all, rather
    /// than reacting once a consumer is already blocked: the boost lands when the reserve is down to
    /// a quarter of the window, which is still many seconds of playback away from a dry store.
    ///
    /// The two depths differ on purpose. A single threshold retunes once per packet for as long as a
    /// source sits on it, and each retune is a `pthread` call and a log line; with this band the
    /// reserve has to drain a quarter of the window to change the answer.
    static func producerMayRelax(currentlyRelaxed: Bool, consumersWaiting: Int,
                                 reservoirSeconds: Double?, forwardSeconds: Double) -> Bool {
        guard consumersWaiting == 0 else { return false }
        guard let reservoirSeconds, reservoirSeconds.isFinite else { return false }
        let depth = currentlyRelaxed
            ? boostReservoirSeconds(forwardSeconds: forwardSeconds)
            : relaxReservoirSeconds(forwardSeconds: forwardSeconds)
        return reservoirSeconds >= depth
    }

    /// Half the forward window. The steady state sits just under the window (the producer parks AT
    /// it and the consumer drains it), so a source that keeps up stays in the efficiency class.
    static func relaxReservoirSeconds(forwardSeconds: Double) -> Double {
        guard forwardSeconds.isFinite, forwardSeconds > 0 else { return .infinity }
        return max(2, forwardSeconds * 0.5)
    }

    /// A quarter of the window: the depth at which a relaxed producer becomes responsive again.
    static func boostReservoirSeconds(forwardSeconds: Double) -> Double {
        guard forwardSeconds.isFinite, forwardSeconds > 0 else { return .infinity }
        return max(1, forwardSeconds * 0.25)
    }

    private func retuneProducerQoS(reservoir: Double?, waiting: Int) {
        let relax = Self.producerMayRelax(currentlyRelaxed: producerQoS == QOS_CLASS_UTILITY,
                                          consumersWaiting: waiting, reservoirSeconds: reservoir,
                                          forwardSeconds: forwardSeconds)
        applyProducerQoS(relax ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED,
                         reservoir: reservoir, waiting: waiting)
    }

    private func applyProducerQoS(_ requested: qos_class_t, reservoir: Double?, waiting: Int) {
        guard requested != producerQoS else { return }
        producerQoS = requested
        pthread_set_qos_class_self_np(requested, 0)
        condition.lock(); reportedProducerQoS = requested; condition.unlock()
        // Read the class back: a thread opted out of the QoS system keeps the old one silently, and
        // then the whole mechanism is a no-op that still looks configured.
        EngineLog.emit(
            "[SWReadAhead] producer qos -> \(QoSClass.name(requested)) "
            + "(now=\(QoSClass.name(qos_class_self())) "
            + "reservoir=\(reservoir.map { String(format: "%.1f", $0) } ?? "n/a")s "
            + "relax=\(String(format: "%.1f", Self.relaxReservoirSeconds(forwardSeconds: forwardSeconds)))s "
            + "boost=\(String(format: "%.1f", Self.boostReservoirSeconds(forwardSeconds: forwardSeconds)))s "
            + "waiting=\(waiting))",
            category: .swPlayback
        )
    }

    /// Consumer starvation is the observable for "the source cannot keep up", and it is the same
    /// window in which the producer must not be elective. Rate-limited to one line a second, and
    /// returned rather than emitted: the caller holds `condition` and the handler formats, redacts
    /// and locks on its own side.
    private func starvationLineLocked() -> String? {
        let now = DispatchTime.now()
        if let last = lastStarvationLog,
           now.uptimeNanoseconds - last.uptimeNanoseconds < 1_000_000_000 { return nil }
        lastStarvationLog = now
        return "[SWReadAhead] consumer starved: waits=\(consumerWaitEvents) "
            + "blocked=\(String(format: "%.2f", consumerBlockedSeconds))s "
            + "reservoir=\(reservoirSecondsLocked().map { String(format: "%.1f", $0) } ?? "n/a")s "
            + "qos=\(QoSClass.name(reportedProducerQoS))"
    }
}
