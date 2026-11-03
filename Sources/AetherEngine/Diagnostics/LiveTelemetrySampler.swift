import Foundation
import AVFoundation

/// Bounded ring buffer exposing the sum of the most recent `capacity` values.
/// Used for 10-second rolling windows of byte counts (instant bitrate) and frame counts (observed FPS).
struct RollingWindow<T: AdditiveArithmetic> {
    private var buffer: [T]
    private var index: Int = 0
    private var filled: Bool = false
    let capacity: Int

    init(capacity: Int, zero: T) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.buffer = Array(repeating: zero, count: capacity)
    }

    mutating func push(_ value: T) {
        buffer[index] = value
        index = (index + 1) % capacity
        if index == 0 { filled = true }
    }

    var sum: T {
        let active = filled ? buffer : Array(buffer.prefix(index))
        return active.reduce(.zero, +)
    }

    /// Populated slot count; sampler keeps instant-bitrate nil until count >= 2 (one sample = zero-second delta).
    var count: Int { filled ? capacity : index }

    /// Populated slots carrying a non-zero sample. The playback reader fetches a large range and then
    /// parks on backpressure until low water, so on a fast link most slots in the window are empty and
    /// a mean over `count` measures the park rather than the link (#306 follow-up).
    var activeCount: Int {
        let active = filled ? buffer : Array(buffer.prefix(index))
        return active.filter { $0 != .zero }.count
    }

    mutating func reset() {
        for i in 0..<buffer.count { buffer[i] = .zero }
        index = 0
        filled = false
    }
}

/// Value snapshot of every AVFoundation property the native-path tick consumes. Each getter is a
/// synchronous XPC round-trip to mediaserverd; a busy media server (display-mode change on an HDR
/// start) turns any main-actor read into a fully blocked main thread and, past the watchdog
/// threshold, a process kill (#134). The whole set is therefore read as one coalesced batch on
/// `LiveTelemetrySampler.readQueue`, never on the main actor.
struct NativeAVFReadings: Sendable {
    var droppedFrameCount: Int? = nil
    var networkThroughputMbps: Double? = nil
    var networkTransferredBytes: Int64? = nil
    var forwardBufferSeconds: Double? = nil
    /// Raw (unclamped) loaded-range end, for the #169 tail-park loadedEnd guard. On a resume/seek into
    /// the tail the playhead jumps ahead of loaded media, so the clamped `forwardBufferSeconds` (>= 0)
    /// hides that the final segment has not arrived; the decision needs the true loaded end vs duration.
    var loadedRangeEndSeconds: Double? = nil
    /// AE#520 round 2: how long this consumer can keep playing without being handed anything else, which
    /// is the range the playhead is INSIDE and not the last one loaded. `forwardBufferSeconds` above
    /// reads the last range's end, so on an item with a hole in front of the playhead it names content
    /// the consumer cannot reach without stalling first. A decision that spends this depth needs the
    /// half it can actually walk; nil when no loaded range contains the playhead at all.
    var contiguousForwardBufferSeconds: Double? = nil
    /// The current variant's declared BANDWIDTH and AVERAGE-BANDWIDTH, in bits per second, from the
    /// latest access-log entry. The log reports an undeclared value as negative.
    var indicatedBitrate: Double = -1
    var indicatedAverageBitrate: Double = -1
    var currentTimeSeconds: Double = .nan
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var rate: Float = 0
    var reasonForWaitingToPlay: String? = nil
    var isPlaybackLikelyToKeepUp: Bool = false
    var isPlaybackBufferEmpty: Bool = false
}

/// #306: everything the software branch of a tick reads off the software host, as one value. Mirrors
/// `NativeAVFReadings` in intent: the sampler reaches the host through a single injectable read, so
/// that branch is exercisable without a decoding session, and the tick keeps no host state of its own.
struct SoftwareReadings: Sendable {
    /// Decoded video queued ahead of the clock (#303). Nil before the first enqueued frame.
    var displayCushionSeconds: Double? = nil
    /// Undrained forward extent of the pump reader's window. Nil for sources with no `AVIOReader`.
    var readerWindowAheadBytes: Int? = nil
    /// Frames the render synchronizer dropped, nil where the metrics cannot be asked for (pre-18 OS).
    var droppedFrameCount: Int? = nil
    /// Cumulative late-frame delay from the same metrics read.
    var accumulatedFrameDelaySeconds: Double? = nil
}

/// Drives engine.diagnostics.liveTelemetry at 1 Hz. Reads existing engine counters; owns no playback state.
/// Started with the memprobe task; stopped in stopInternal.
@MainActor
final class LiveTelemetrySampler {
    typealias NativeRead = @Sendable (AVPlayer, AVPlayerItem) -> NativeAVFReadings
    typealias SoftwareRead = @MainActor (AetherEngine) async -> SoftwareReadings

    private weak var engine: AetherEngine?
    private var task: Task<Void, Never>?
    private let nativeRead: NativeRead
    private let softwareRead: SoftwareRead

    /// Dedicated + serial: the sync XPC reads may block for seconds, which must not tie up the
    /// shared cooperative pool, and serial means a stalled tick back-pressures the next one
    /// instead of piling up concurrent reads against an already busy media server. Per instance,
    /// not static: a wedged read from a stopped sampler must not queue ahead of the next
    /// session's sampler (or another engine's).
    private let readQueue = DispatchQueue(label: "engine.telemetry.avfread", qos: .utility)

    private var byteWindow = RollingWindow<Int64>(capacity: 10, zero: 0)   // 10-second rolling window
    private var frameWindow = RollingWindow<Int>(capacity: 10, zero: 0)
    private var bridgeByteWindow = RollingWindow<Int64>(capacity: 10, zero: 0)

    private var lastDemuxerBytes: Int64 = 0
    private var lastBridgeBytes: Int64 = 0
    private var lastFramesEnqueued: Int = 0

    /// AE#514: both bitrate fields, metered over what the playhead crossed. Readable so a test can pin
    /// that the tick feeds it, not only that the meter is right.
    private(set) var playedMeter = PlayedBitrateMeter()

    /// The ledger the meter was last advanced against. A different one is a different session, whose
    /// playhead and bytes have nothing to do with the old meter's.
    private var meterLedger: ObjectIdentifier?

    /// Timestamp of the previous tick: the wall time the playhead had to cover its step in.
    private var lastTickTime: Date?

    /// [LagDiag] tick-over-tick state (#93 post-recovery lag diagnosis).
    private var lagLastClock: Double?
    private var lagLastDroppedSum: Int?

    /// #169 tail-park end-of-media synthesis state.
    private var eomParkFrozenTicks: Int = 0
    private var eomParkLastPlayhead: Double?
    private var didSynthesizeEomPark = false

    /// A playhead moving less than this between 1 Hz ticks is "frozen" for #169 (well under a single
    /// 23.976 fps frame of ~42 ms of legitimate forward progress).
    private static let eomParkFrozenEpsilonSeconds: Double = 0.05

    init(engine: AetherEngine,
         nativeRead: @escaping NativeRead = LiveTelemetrySampler.batchReadNativeAVF,
         softwareRead: @escaping SoftwareRead = LiveTelemetrySampler.readSoftwareHost) {
        self.engine = engine
        self.nativeRead = nativeRead
        self.softwareRead = softwareRead
    }

    func start() {
        stop()
        byteWindow.reset()
        frameWindow.reset()
        bridgeByteWindow.reset()
        // Seed from CURRENT counters: a zero seed pushes all pre-start prefetch bytes into tick 1, inflating instant bitrate for ~10 s.
        lastDemuxerBytes = engine?.demuxerBytesFetched ?? 0
        lastBridgeBytes = engine?.audioBridgeOutputBytesLifetime ?? 0
        lastFramesEnqueued = 0
        playedMeter = PlayedBitrateMeter()
        meterLedger = nil
        lastTickTime = nil
        lagLastClock = nil
        lagLastDroppedSum = nil
        eomParkFrozenTicks = 0
        eomParkLastPlayhead = nil
        didSynthesizeEomPark = false
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// #306 follow-up: the rate the link delivers at, measured over the seconds bytes actually arrived
    /// in rather than over wall-clock seconds.
    ///
    /// The playback reader fetches a large range and then parks on backpressure until low water, so on
    /// a fast link most ticks of a window carry nothing at all: measured over a local origin, a healthy
    /// 2.8 Mbps VP9 session pulled 16.4 MB in one tick and then sat at exactly zero for the next 23,
    /// while the reader's runway drained from 16.0 to 8.3 MB. A wall-clock mean reports 0.00 Mbps
    /// through all of that, which is the false-with-confidence zero #306 was filed about, one field
    /// over. Dividing by the active seconds instead reports the link, and under-reports it at worst,
    /// since a burst that finishes inside a tick is still charged the whole second.
    ///
    /// nil when the window holds fewer than two samples (a single sample spans no time) or when nothing
    /// arrived in it at all. That mirrors the native path, where `observedBitrate` is published only
    /// when it is finite and positive: "not measurable right now" is a gap, never a zero.
    static func observedTransferMbps(windowBytes: Int64, activeSeconds: Int, samples: Int) -> Double? {
        guard samples >= 2, activeSeconds > 0, windowBytes > 0 else { return nil }
        return Double(windowBytes) * 8.0 / Double(activeSeconds) / 1_000_000.0
    }

    /// Which cumulative counter the two bitrate fields are metered from.
    enum BitrateCounter: Equatable {
        /// Bytes the engine's demuxer pulled from the source (loopback and software).
        case demuxer
        /// The bitrate the playing variant declares, from AVPlayer's access log. The remote-HLS bypass has no
        /// demuxer, and what AVPlayer transferred is not the stream's rate: a buffer filling after a start or
        /// a seek pulls at link speed (22.6 Mbps measured for a 3.7 Mbps transcode). The transfer stays in the
        /// network fields.
        case declaredVariant
    }

    nonisolated static func bitrateCounter(for route: VideoRoute) -> BitrateCounter {
        route == .remoteBypass ? .declaredVariant : .demuxer
    }

    /// Both bitrate fields from the access log's declarations, in Mbps: instant is BANDWIDTH, average is
    /// AVERAGE-BANDWIDTH, falling back to BANDWIDTH where the master omits it. Undeclared reads nil.
    nonisolated static func declaredBitrates(indicated: Double, indicatedAverage: Double)
        -> (instant: Double?, average: Double?) {
        func mbps(_ bps: Double) -> Double? { bps.isFinite && bps > 0 ? bps / 1_000_000.0 : nil }
        let instant = mbps(indicated)
        return (instant, mbps(indicatedAverage) ?? instant)
    }

    /// Whether the native branch has the loopback pipeline behind it. On the bypass the producer's A/V gap
    /// does not exist (its getter reads 0, which would publish as a measured zero), and the #169 tail-park
    /// synthesis stays with the route whose EXTINF overshoot it was built for.
    nonisolated static func readsLoopbackPipeline(_ route: VideoRoute) -> Bool {
        route != .remoteBypass
    }

    /// AE#514: where the playhead stands on the axis the played-media ledger is keyed on, the source
    /// axis the pumps read packets on. Native folds AVPlayer's clock back with the producer's shift
    /// (`source_pts - playlistShiftSeconds`) rather than reading `sourceTime`, which publishes the item
    /// axis on a sequential origin (#368). nil where there is no ledger-fed pipeline to read it off.
    nonisolated static func ledgerPlayhead(backend: PlaybackBackend, nativeClock: Double?, playlistShift: Double,
                               softwareSourceClock: Double?) -> Double? {
        switch backend {
        case .native:
            guard let nativeClock, nativeClock.isFinite else { return nil }
            return nativeClock + playlistShift
        case .software:
            return softwareSourceClock
        case .aether, .none, .audio:
            return nil
        }
    }

    private func tick() async {
        guard let engine = engine else { return }

        let tickTime = Date()
        let wallSeconds = lastTickTime.map { tickTime.timeIntervalSince($0) } ?? 0
        lastTickTime = tickTime

        let route = engine.videoRoute

        // What the reader pulled from the source. Transfer, not media rate: it feeds the network fields
        // and [LagDiag], never the bitrate fields (AE#514, see `playedMeter`).
        let demuxerBytes = engine.demuxerBytesFetched
        let bytesThisTick = max(0, demuxerBytes - lastDemuxerBytes)
        lastDemuxerBytes = demuxerBytes
        byteWindow.push(bytesThisTick)

        let transferMbps: Double? = byteWindow.count >= 2
            ? Double(byteWindow.sum) * 8.0 / Double(byteWindow.count) / 1_000_000.0
            : nil

        let observedTransferMbps = Self.observedTransferMbps(
            windowBytes: byteWindow.sum,
            activeSeconds: byteWindow.activeCount,
            samples: byteWindow.count)

        // Live audio-bridge output bitrate from the bridge's cumulative encoded-byte counter. 0 on the
        // stream-copy / AVPlayer-native / video-only paths (no bridge), which surfaces as nil.
        let bridgeBytes = engine.audioBridgeOutputBytesLifetime
        let bridgeBytesThisTick = max(0, bridgeBytes - lastBridgeBytes)
        lastBridgeBytes = bridgeBytes
        bridgeByteWindow.push(bridgeBytesThisTick)
        let audioBridgeBitrateMbps: Double?
        if bridgeBytes > 0, bridgeByteWindow.count >= 2 {
            audioBridgeBitrateMbps = Double(bridgeByteWindow.sum) * 8.0 / Double(bridgeByteWindow.count) / 1_000_000.0
        } else {
            audioBridgeBitrateMbps = nil
        }

        // Per-path: FPS, dropped frames, network throughput, A/V sync gap
        let observedFps: Double?
        let droppedFrameCount: Int?
        let networkThroughputMbps: Double?
        let networkTransferredBytes: Int64?
        let avSyncGapMs: Double?
        let forwardBufferSeconds: Double?
        // #306: software-path fields. Nil on every other backend, so a host reading them knows it is
        // looking at the software pipeline and not at a zero that means "healthy".
        let displayCushionSeconds: Double?
        let accumulatedFrameDelaySeconds: Double?
        var readerWindowAheadBytes: Int? = engine.pumpIOWindow?.aheadBytes
        var nativeReadings: NativeAVFReadings?

        switch engine.playbackBackend {
        case .native:
            observedFps = nil
            displayCushionSeconds = nil
            accumulatedFrameDelaySeconds = nil
            // HLSSegmentProducer audio-gate-open vs video-gate-open, loopback only.
            avSyncGapMs = Self.readsLoopbackPipeline(route) ? engine.lastAVGapMs : nil
            if let player = engine.currentAVPlayer, let item = player.currentItem {
                var readings = await readNativeOffMain(player: player, item: item)
                // stop() may have cancelled this tick, or a reload seam may have swapped the
                // player/item, while the read was in flight; publishing now would leak a stale
                // snapshot and yield-gate tick into the current session.
                guard !Task.isCancelled,
                      engine.currentAVPlayer === player,
                      player.currentItem === item else { return }
                engine.nativeHost?.recordItemCounters(
                    ItemLogCounters(transferredBytes: readings.networkTransferredBytes,
                                    droppedFrames: readings.droppedFrameCount), item: item)
                // AE#443: the read above covers this item; the host carries what the items before it
                // transferred. Read after the guard, so the two halves describe the same swap state.
                readings.networkTransferredBytes = Self.foldRetired(
                    readings.networkTransferredBytes, retired: engine.nativeHost?.retiredItemTransferredBytes ?? 0)
                readings.droppedFrameCount = Self.foldRetired(
                    readings.droppedFrameCount, retired: engine.nativeHost?.retiredItemDroppedFrames ?? 0)
                nativeReadings = readings
                droppedFrameCount = readings.droppedFrameCount
                networkThroughputMbps = readings.networkThroughputMbps
                networkTransferredBytes = readings.networkTransferredBytes
                forwardBufferSeconds = readings.forwardBufferSeconds
                // AE#520 round 2: the outage close spends the depth this consumer can still walk, and
                // it is decided on a playlist-build thread that must not hop the main actor to ask.
                engine.consumerContiguousBufferMirror.set(readings.contiguousForwardBufferSeconds)
            } else {
                // AE#443: an item swap has a gap where the host holds no current item, and reporting
                // nothing through it reads as "the counter is gone" rather than "nothing new since".
                droppedFrameCount = Self.foldRetired(nil, retired: engine.nativeHost?.retiredItemDroppedFrames ?? 0)
                networkThroughputMbps = nil
                networkTransferredBytes = Self.foldRetired(nil, retired: engine.nativeHost?.retiredItemTransferredBytes ?? 0)
                forwardBufferSeconds = nil
                // Between items there is no consumer to read a depth off, and reporting the last one
                // would hand the close a figure about an item that is gone.
                engine.consumerContiguousBufferMirror.set(nil)
            }

        case .software:
            let frames = engine.softwareHostFramesEnqueued
            let framesThisTick = max(0, frames - lastFramesEnqueued)
            lastFramesEnqueued = frames
            frameWindow.push(framesThisTick)
            if frameWindow.count >= 2 {
                let totalFrames = frameWindow.sum
                let seconds = Double(frameWindow.count)
                observedFps = Double(totalFrames) / seconds
            } else {
                observedFps = nil
            }
            // #306: the render-metrics read is async, so the session can end or be replaced under it
            // exactly like the native batch above; publishing then would carry a dead session's
            // numbers into the next one.
            let hostBeforeRead = engine.softwareHost
            let software = await softwareRead(engine)
            guard !Task.isCancelled,
                  engine.playbackBackend == .software,
                  engine.softwareHost === hostBeforeRead else { return }
            droppedFrameCount = software.droppedFrameCount
            displayCushionSeconds = software.displayCushionSeconds
            accumulatedFrameDelaySeconds = software.accumulatedFrameDelaySeconds
            readerWindowAheadBytes = software.readerWindowAheadBytes
            // SW: the demuxer pulls the bytes itself, so the rate comes from its counter rather than
            // from an access log. Over active seconds, not wall-clock ones: see observedTransferMbps.
            networkThroughputMbps = observedTransferMbps
            networkTransferredBytes = demuxerBytes
            avSyncGapMs = nil          // HLSSegmentProducer doesn't run on SW path
            // Deliberately nil, see LiveTelemetry: the software pump is renderer-back-pressured, so
            // there is no arrived-but-unplayed reservoir in seconds. displayCushionSeconds and
            // readerWindowAheadBytes carry what this path actually holds.
            forwardBufferSeconds = nil

        case .aether, .none, .audio:
            observedFps = nil
            droppedFrameCount = nil
            networkThroughputMbps = nil
            networkTransferredBytes = nil
            avSyncGapMs = nil
            forwardBufferSeconds = nil
            displayCushionSeconds = nil
            accumulatedFrameDelaySeconds = nil
        }

        // AE#514: the bitrate fields are the media the playhead crossed, never the transfer.
        var instantBitrateMbps: Double?
        var averageBitrateMbps: Double?
        if let ledger = engine.playedMediaLedger {
            let identity = ObjectIdentifier(ledger)
            if meterLedger != identity {
                meterLedger = identity
                playedMeter = PlayedBitrateMeter()
            }
            playedMeter.advance(
                to: Self.ledgerPlayhead(
                    backend: engine.playbackBackend,
                    nativeClock: nativeReadings?.currentTimeSeconds,
                    playlistShift: engine.playlistShiftSeconds,
                    softwareSourceClock: engine.softwareHost?.sourceClockSeconds),
                wallSeconds: wallSeconds,
                ledger: ledger)
            instantBitrateMbps = playedMeter.instantMbps
            averageBitrateMbps = playedMeter.averageMbps
        }

        // Remote-HLS bypass: no demuxer, so both rates are what the playing variant declares.
        if Self.bitrateCounter(for: route) == .declaredVariant {
            let declared = Self.declaredBitrates(
                indicated: nativeReadings?.indicatedBitrate ?? -1,
                indicatedAverage: nativeReadings?.indicatedAverageBitrate ?? -1)
            instantBitrateMbps = declared.instant
            averageBitrateMbps = declared.average
        }

        // Feed the extractor yield gate (#93 startup): nil on non-native paths keeps the
        // gate conservative there, but those paths have no active session to gate anyway.
        engine.extractorYieldState.setForwardBuffer(forwardBufferSeconds)

        if let readings = nativeReadings {
            emitLagDiag(engine: engine, readings: readings, netMbps: transferMbps)
            if Self.readsLoopbackPipeline(route) {
                evaluateEndOfMediaPark(engine: engine, readings: readings)
            }
        }

        let softwareCache = engine.softwarePacketCacheSnapshot
        let snapshot = LiveTelemetry(
            instantBitrateMbps: instantBitrateMbps,
            averageBitrateMbps: averageBitrateMbps,
            audioBridgeBitrateMbps: audioBridgeBitrateMbps,
            objectAudio: engine.objectAudioActivity,
            observedFps: observedFps,
            droppedFrameCount: droppedFrameCount,
            forwardBufferSeconds: forwardBufferSeconds,
            displayCushionSeconds: displayCushionSeconds,
            readerWindowAheadBytes: readerWindowAheadBytes,
            accumulatedFrameDelaySeconds: accumulatedFrameDelaySeconds,
            cachedBytes: engine.cachedBytes,
            softwareCacheSeekHits: softwareCache?.cacheSeekHits,
            softwareCacheSeekMisses: softwareCache?.cacheSeekMisses,
            softwareCacheSourceEpoch: softwareCache?.sourceEpoch,
            networkThroughputMbps: networkThroughputMbps,
            networkTransferredBytes: networkTransferredBytes,
            avSyncGapMs: avSyncGapMs,
            producerRestartCount: engine.producerRestartCount,
            muxedBytesLifetime: engine.muxedBytesLifetime,
            serverBytesSentLifetime: engine.serverBytesSentLifetime,
            serverRequestCount: engine.serverRequestCount,
            demuxerBytesFetched: demuxerBytes,
            audioBridgeLiveBytes: engine.audioBridgeLiveBytes,
            rssMb: AetherEngine.residentMemoryMB()
        )
        engine.applyLiveTelemetry(snapshot)
        engine.refreshNativeBufferedPosition()
        engine.tickKeyframeStillLadder()
        await engine.refreshSessionCacheStatus()
    }

    /// One line per tick on the native path (#93 post-recovery lag diagnosis). Discriminates
    /// buffer starvation (fwd/keepUp/empty + dclk pauses) from render-side stutter (drop
    /// climbing while tcs=playing and dclk~1.0) from thermal throttling (thermal field).
    /// All AVFoundation inputs arrive pre-read from the off-main batch (#134); only engine
    /// state and the tick-over-tick lag counters are touched here.
    private func emitLagDiag(engine: AetherEngine, readings: NativeAVFReadings, netMbps: Double?) {
        let clock = readings.currentTimeSeconds
        let dclk = (clock.isFinite && lagLastClock != nil) ? clock - lagLastClock! : nil
        if clock.isFinite { lagLastClock = clock }

        let droppedSum = readings.droppedFrameCount
        let dDrop = droppedSum.flatMap { total in lagLastDroppedSum.map { total - $0 } }
        lagLastDroppedSum = droppedSum

        let tcs: String
        switch readings.timeControlStatus {
        case .paused:                       tcs = "paused"
        case .waitingToPlayAtSpecifiedRate: tcs = "waiting"
        case .playing:                      tcs = "playing"
        @unknown default:                   tcs = "unknown"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:    thermal = "nominal"
        case .fair:       thermal = "fair"
        case .serious:    thermal = "serious"
        case .critical:   thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let fmt2 = { (v: Double) in String(format: "%.2f", v) }
        EngineLog.emit(
            "[LagDiag] clk=\(clock.isFinite ? fmt2(clock) : "-") dclk=\(dclk.map(fmt2) ?? "-") "
            + "tcs=\(tcs) rate=\(fmt2(Double(readings.rate))) wait=\(readings.reasonForWaitingToPlay ?? "-") "
            + "fwd=\(readings.forwardBufferSeconds.map { String(format: "%.1f", $0) } ?? "-") "
            + "keepUp=\(readings.isPlaybackLikelyToKeepUp ? "y" : "n") empty=\(readings.isPlaybackBufferEmpty ? "y" : "n") "
            + "drop=\(droppedSum.map(String.init) ?? "-")+\(dDrop.map(String.init) ?? "-") videoFrames=unavailable stall=\(engine.nativeHost?.stallCount ?? 0) "
            + "ready=\((engine.nativeHost?.playerLayer.isReadyForDisplay ?? false) ? "y" : "n") "
            + "thermal=\(thermal) net=\(netMbps.map { String(format: "%.1f", $0) } ?? "-") "
            + "restarts=\(engine.producerRestartCount)",
            category: .engine, level: .verbose
        )
    }

    /// Grace-thresholded synthesis of organic end-of-media when a native VOD parks a hair short of its
    /// advertised duration with the final segment loaded (AetherEngine#169: the final segment's EXTINF,
    /// derived from the container duration, overshoots the last real video sample, so AVPlayer sits in
    /// WaitingToMinimizeStalls a few frames from the end and never fires didPlayToEndTime). Reuses the
    /// already-read native batch; owns no AVFoundation reads of its own. Fires at most once per session.
    private func evaluateEndOfMediaPark(engine: AetherEngine, readings: NativeAVFReadings) {
        guard !didSynthesizeEomPark else { return }
        let playhead = readings.currentTimeSeconds
        guard playhead.isFinite else { eomParkFrozenTicks = 0; return }
        let waitingToPlay = readings.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let minimizingStalls = readings.reasonForWaitingToPlay == AVPlayer.WaitingReason.toMinimizeStalls.rawValue
        // Raw loaded end; on a resume/seek into the tail the playhead runs ahead of loaded media, so
        // default to the playhead (loadedEnd == playhead) which fails the final-segment-loaded guard.
        let loadedEnd = readings.loadedRangeEndSeconds ?? playhead
        let qualifies = AetherEngine.endOfMediaParkTickQualifies(
            isLive: engine.isLive,
            duration: engine.duration,
            playhead: playhead,
            loadedEnd: loadedEnd,
            waitingToPlay: waitingToPlay,
            minimizingStalls: minimizingStalls)
        let frozen = eomParkLastPlayhead.map { abs(playhead - $0) < Self.eomParkFrozenEpsilonSeconds } ?? false
        eomParkLastPlayhead = playhead
        eomParkFrozenTicks = AetherEngine.endOfMediaParkFrozenTicks(
            previous: eomParkFrozenTicks, tickQualifies: qualifies, playheadFrozen: frozen)
        if AetherEngine.shouldSynthesizeEndOfMediaFromPark(frozenTicks: eomParkFrozenTicks) {
            didSynthesizeEomPark = true
            engine.synthesizeEndOfMediaFromTailPark(playhead: playhead, loadedEnd: loadedEnd)
        }
    }

    /// #306: the real software read. `videoPerformanceMetrics` is an ASYNC AVFoundation accessor, so
    /// the main actor suspends on it rather than blocking, which is the distinction #134 turns on: the
    /// sync accessors are the ones that must never be touched here. Cushion and reader window are
    /// lock-guarded in-process snapshots and cost nothing.
    @MainActor
    private static func readSoftwareHost(_ engine: AetherEngine) async -> SoftwareReadings {
        guard let host = engine.softwareHost else { return SoftwareReadings() }
        let metrics = await host.loadRenderMetrics()
        return SoftwareReadings(
            displayCushionSeconds: host.displayCushionSeconds,
            readerWindowAheadBytes: engine.pumpIOWindow?.aheadBytes,
            droppedFrameCount: metrics?.dropped,
            accumulatedFrameDelaySeconds: metrics?.accumulatedDelay)
    }

    /// Hops the AVFoundation batch onto the dedicated read queue and back. The main actor only
    /// suspends here; a stalled mediaserverd reply parks a GCD thread, not the main thread.
    private func readNativeOffMain(player: AVPlayer, item: AVPlayerItem) async -> NativeAVFReadings {
        let read = nativeRead
        return await AVFoundationOffMain.read((player, item), on: readQueue) { player, item in
            read(player, item)
        }
    }

    /// AE#443: fold a per-entry access-log counter into the session total a reader takes it for.
    ///
    /// `AVPlayerItemAccessLogEvent` counts within its own entry, and AVFoundation opens a new one every
    /// time the playback session changes under it. Measured on the live loopback harness across a rewind
    /// and a return to the edge, one origin connection for the whole run and no producer restart at all:
    /// `rx` went 3.4 MB -> 2.2 MB and `drop` 44 -> 0 while the session played on. A number that falls in
    /// the middle of a healthy session invites exactly one reading, that something under it was replaced,
    /// and the reporter of #443 spent two rounds on that reading before the logs refused it.
    ///
    /// Entries that report the field as unavailable (negative) are skipped rather than clamped, and the
    /// result is nil when none of them carried it, so "not measurable" stays distinguishable from zero.
    nonisolated static func sessionTotal<T: BinaryInteger>(perEntry values: [T]) -> T? {
        let known = values.filter { $0 >= 0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// AE#443: adds what the session's retired items carried to what the current one reports.
    ///
    /// nil + nothing retired stays nil, because "this path cannot report it" is not zero. nil with a
    /// retired total is the swap gap, and the honest reading there is the total so far, not silence.
    nonisolated static func foldRetired<T: BinaryInteger>(_ current: T?, retired: T) -> T? {
        guard let current else { return retired > 0 ? retired : nil }
        return current + retired
    }

    /// The real batch, run on `readQueue`: one accessLog() shared by the snapshot fields and the
    /// LagDiag lifetime drop sum, one currentTime() shared by the forward-buffer math and the
    /// LagDiag clock (previously two of each per tick, all on the main actor).
    private nonisolated static func batchReadNativeAVF(player: AVPlayer, item: AVPlayerItem) -> NativeAVFReadings {
        var readings = NativeAVFReadings()
        let events = item.accessLog()?.events
        // The rate is a `.last` read on purpose: it describes the link right now.
        if let event = events?.last {
            let observed = event.observedBitrate
            readings.networkThroughputMbps = observed.isFinite && observed > 0
                ? observed / 1_000_000.0 : nil
            readings.indicatedBitrate = event.indicatedBitrate
            readings.indicatedAverageBitrate = event.indicatedAverageBitrate
        }
        // AE#443: the counters are not. They are totals PER ENTRY, and AVFoundation opens a new entry
        // whenever the playback session changes under it, so reading `.last` publishes a number that
        // falls BACK mid-session, with nothing in the line to say it did.
        if let events {
            readings.networkTransferredBytes = Self.sessionTotal(perEntry: events.map(\.numberOfBytesTransferred))
            readings.droppedFrameCount = Self.sessionTotal(perEntry: events.map(\.numberOfDroppedVideoFrames))
        }

        let now = player.currentTime().seconds
        readings.currentTimeSeconds = now
        if let last = item.loadedTimeRanges.last?.timeRangeValue {
            let end = CMTimeGetSeconds(CMTimeAdd(last.start, last.duration))
            if end.isFinite {
                readings.loadedRangeEndSeconds = end
                if now.isFinite {
                    readings.forwardBufferSeconds = max(0, end - now)
                }
            }
        }
        if now.isFinite {
            for value in item.loadedTimeRanges {
                let range = value.timeRangeValue
                let start = range.start.seconds
                let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
                guard start.isFinite, end.isFinite, start <= now, end > now else { continue }
                readings.contiguousForwardBufferSeconds = end - now
                break
            }
        }

        readings.timeControlStatus = player.timeControlStatus
        readings.rate = player.rate
        readings.reasonForWaitingToPlay = player.reasonForWaitingToPlay?.rawValue
        readings.isPlaybackLikelyToKeepUp = item.isPlaybackLikelyToKeepUp
        readings.isPlaybackBufferEmpty = item.isPlaybackBufferEmpty
        return readings
    }
}
