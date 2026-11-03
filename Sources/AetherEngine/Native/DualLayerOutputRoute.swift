// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import AetherLibavcodec
import AetherLibavutil

// MARK: - Seams

/// What the route needs from the decoder that pairs and composes. `DualLayerVideoDecoder` is the one
/// implementation; the route's tests stand a recording double in its place.
protocol OutputRouteDecoder: AnyObject {
    var feedEpoch: UInt64 { get }
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?)
    func submitBaseLayerFrame(_ buffer: CVPixelBuffer, pts: CMTime, hdr10Data: Data?, epoch: UInt64?)
    func flush()
    func close()
}

extension DualLayerVideoDecoder: OutputRouteDecoder {}

/// Where the route's frames go: the display layer's renderer.
protocol OutputRouteSink: AnyObject {
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data?)
    func flushOutput(removingDisplayedImage: Bool)
}

extension SampleBufferRenderer: OutputRouteSink {
    func flushOutput(removingDisplayedImage: Bool) { flush(removingDisplayedImage: removingDisplayedImage) }
}

/// Where the base-layer frames come from: the player's video output.
protocol OutputRouteFrameSource: AnyObject {
    func hasNewFrame(at time: CMTime) -> Bool
    func copyFrame(at time: CMTime) -> (buffer: CVPixelBuffer, display: CMTime)?
}

final class VideoOutputFrameSource: OutputRouteFrameSource, @unchecked Sendable {
    let output: AVPlayerItemVideoOutput
    init(_ output: AVPlayerItemVideoOutput) { self.output = output }
    func hasNewFrame(at time: CMTime) -> Bool { output.hasNewPixelBuffer(forItemTime: time) }
    func copyFrame(at time: CMTime) -> (buffer: CVPixelBuffer, display: CMTime)? {
        var display = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &display),
              display.isNumeric else { return nil }
        return (buffer, display)
    }
}

/// The item's time in seconds and its effective rate (0 while paused).
struct OutputRouteClockSample {
    var seconds: Double
    var rate: Double
}

// MARK: - Route

/// The second Profile 7 FEL route (`LoadOptions.dualLayerRoute == .avPlayerOutput`).
///
/// AVPlayer plays the engine's loopback HLS stream: the base layer, converted to 8.1, and the audio. It
/// owns the clock and every transport call. This route takes AVPlayer's decoded base-layer frames from an
/// `AVPlayerItemVideoOutput`, pairs them with the enhancement layer from `VideoPacketTap` and composes
/// them in `DualLayerVideoDecoder`, the code the software host runs (pairing, the composer, the RPU and
/// the display metadata), and shows the result in a display layer whose timebase is a child of the item's.
/// Hiding AVPlayer's own picture is `suppressesPlayerRendering`, public API.
///
/// One clock: the item's timebase. Nothing here keeps a position of its own except the cursor of what has
/// been fed and pulled. A seek is the player's own signal (`AVPlayerItem.timeJumpedNotification`) at any
/// distance, with the clock's distance from the feed as a second net; either one flushes the composer and
/// the display layer and re-derives both cursors from the clock.
///
/// Where no enhancement layer covers the position (a seek further back than the history reaches, a packet
/// the history could not store, a producer that has not got there yet), the picture is AVPlayer's base-layer
/// frame passed straight to the display layer, so the screen never freezes while the audio plays.
///
/// AVPlayer and AVPlayerItem are touched on the main thread only (`attachOnMain`); the timer queues read
/// the item's timebase, the video output and the history, which are safe from any thread.
final class DualLayerOutputRoute: VideoPacketTapReceiver, @unchecked Sendable {

    /// How far ahead of the clock base-layer frames are taken from the video output.
    static let pullAheadSeconds = 0.15
    /// The enhancement layer is fed this many frame intervals beyond the pull window, so it is decoded
    /// before its base frame arrives and never so far ahead that the decoder's queue prunes it.
    static let feedLeadFrames = 6.0
    /// A clock further than this from what was last fed is a seek even without the player's signal.
    static let jumpSeconds = 1.5
    /// A base-layer frame that has waited this long for its enhancement-layer packet goes out as it is.
    static let lateFrameSeconds = 0.1
    static let activeTick: DispatchTimeInterval = .milliseconds(5)
    static let idleTick: DispatchTimeInterval = .milliseconds(100)
    /// Seconds after the last activity (a seek, an item change, playback) before the timers slow down.
    static let idleAfterSeconds = 3.0

    private enum FeedState {
        /// Waiting for a keyframe the history holds at the clock.
        case needsRestart
        /// Feeding packets from `nextSeq` on.
        case following
        /// The history holds packets but none that covers the clock.
        case uncovered
    }

    /// What the pull side may rely on.
    private enum Coverage {
        /// Not decided yet (the start, or a seek the feed has not answered): a frame waits briefly.
        case pending
        /// The feed follows packets at the clock: a frame waits briefly for its packet.
        case covered
        /// The history does not cover the clock: AVPlayer's frame goes out as it is.
        case uncovered
    }

    private let sink: OutputRouteSink
    private let renderer: SampleBufferRenderer?
    private let decoder: OutputRouteDecoder
    private let concreteDecoder: DualLayerVideoDecoder?
    let history: VideoPacketHistory
    private(set) var tap: VideoPacketTap!

    private let frameInterval: Double
    private let composeInPlace: Bool
    private let clockOverride: (@Sendable () -> OutputRouteClockSample?)?

    private let lock = NSLock()
    /// Serialises the pull side's direct hand-over of a base-layer frame against a resync's flush, so an
    /// old position's frame cannot land after the flush that was meant to remove it.
    private let deliverLock = NSLock()
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var frameSource: OutputRouteFrameSource?
    private var output: AVPlayerItemVideoOutput?
    private var timebaseSource: CMTimebase?
    private var childTimebase: CMTimebase?
    private var jumpObserver: NSObjectProtocol?
    private var mainTimer: DispatchSourceTimer?
    private var opened = false
    private var stopped = false
    /// Moves on every resync; the pull side drops its cursor when it sees a new one.
    private var generation: UInt64 = 0
    /// Counts the player's seek signals; the feed side compares it with the last one it handled.
    private var jumpMark: UInt64 = 0
    private var lastActivity: Double = ProcessInfo.processInfo.systemUptime
    private var coverage: Coverage = .pending

    // Feed state, owned by the feed queue.
    private var state: FeedState = .needsRestart
    private var handledJumpMark: UInt64 = 0
    private var nextSeq: UInt64?
    private var lastFedItem: Double?
    private var uncoveredLogged = false
    /// After a gap in the history, restarts must not land in front of it. Cleared by a seek.
    private var restartFloor: UInt64 = 0
    private var lastLookupNewest: UInt64?
    private var lastLookupClock: Double?
    private var failedWritesLogged = 0
    /// Served times of the packets fed to the composer lately, for the pull side. A base frame is composed
    /// only once its own packet has been fed: the composer reads the frame's RPU and display metadata when
    /// the frame arrives, and a frame that arrives before its packet goes out without them.
    private var fedItems: [Double] = []
    private var fedCount = 0
    private var resyncCount = 0

    // Pull state, owned by the pull queue.
    private var pullGeneration: UInt64 = 0
    private var cursor: Double?
    private var waitingSince: Double?
    private var degraded = false
    private var pulledCount = 0
    private var composedSubmitted = 0
    private var fallbackCount = 0
    private var staleDropped = 0

    private let feedQueue = DispatchQueue(label: "com.aetherengine.fel-output.feed", qos: .userInteractive)
    private let pullQueue = DispatchQueue(label: "com.aetherengine.fel-output.pull", qos: .userInteractive)
    private var feedTimer: DispatchSourceTimer?
    private var pullTimer: DispatchSourceTimer?
    private var feedFast = true
    private var pullFast = true

    /// The designated initialiser: every dependency injected. The route's tests use it with doubles; the
    /// production initialiser below builds the real ones. A decoder that is not a `DualLayerVideoDecoder`
    /// needs no open call, so the route counts it as opened.
    init(decoder: OutputRouteDecoder, sink: OutputRouteSink, history: VideoPacketHistory, frameRate: Double,
         composeInPlace: Bool = false, clock: (@Sendable () -> OutputRouteClockSample?)? = nil) {
        self.decoder = decoder
        self.concreteDecoder = decoder as? DualLayerVideoDecoder
        self.sink = sink
        self.renderer = sink as? SampleBufferRenderer
        self.history = history
        self.frameInterval = 1 / frameRate
        self.composeInPlace = composeInPlace
        self.clockOverride = clock
        self.opened = concreteDecoder == nil
        self.tap = VideoPacketTap(receiver: self)
    }

    /// `frameRate` must be known and positive: the dither parity of the composition and the pull step both
    /// follow it, so a guessed rate would skew them.
    @MainActor
    convenience init?(frameRate: Double, composeInPlace: Bool = false,
                      historyCapacityBytes: Int = VideoPacketHistory.defaultCapacityBytes) {
        guard frameRate > 0, frameRate.isFinite,
              let composer = DoviFelComposer(), let history = VideoPacketHistory(capacityBytes: historyCapacityBytes) else {
            return nil
        }
        let renderer = SampleBufferRenderer()
        // The frames reach the renderer in presentation order, one decode at a time.
        renderer.setReorderDepth(SampleBufferRenderer.presentationOrderReorderDepth)
        renderer.setHDROutput(true)
        self.init(decoder: DualLayerVideoDecoder(composer: composer), sink: renderer, history: history,
                  frameRate: frameRate, composeInPlace: composeInPlace)
    }

    var displayLayer: AVSampleBufferDisplayLayer? { renderer?.displayLayer }

    /// Where the base-layer frames come from. The player's output in production; a double in tests.
    func attachFrameSource(_ source: OutputRouteFrameSource?) {
        lock.lock(); frameSource = source; lock.unlock()
    }

    // MARK: - Lifecycle

    /// Starts following `player`'s current item. The route re-attaches itself when the item changes.
    @MainActor
    func start(player: AVPlayer) {
        lock.lock()
        self.player = player
        lock.unlock()
        concreteDecoder?.setRenderClock({ [weak self] in
            guard let self, let sample = self.readClock() else { return nil }
            return .init(seconds: sample.seconds, running: sample.rate > 0, prerolling: false,
                         rate: sample.rate > 0 ? sample.rate : 1)
        }, frameRate: 1 / frameInterval)
        attachOnMain()
        let main = DispatchSource.makeTimerSource(queue: .main)
        main.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
        main.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.attachOnMain() }
        }
        mainTimer = main
        main.resume()
        startTimers()
    }

    private func startTimers() {
        let feed = DispatchSource.makeTimerSource(queue: feedQueue)
        feed.schedule(deadline: .now(), repeating: Self.activeTick, leeway: .milliseconds(1))
        feed.setEventHandler { [weak self] in self?.feedTick() }
        feedTimer = feed
        feed.resume()
        let pull = DispatchSource.makeTimerSource(queue: pullQueue)
        pull.schedule(deadline: .now(), repeating: Self.activeTick, leeway: .milliseconds(1))
        pull.setEventHandler { [weak self] in self?.pullTick() }
        pullTimer = pull
        pull.resume()
    }

    /// Detaches the route on main and returns; closing the decoder and waiting for the ticks run on
    /// `teardownQueue`, so a pull tick waiting for a GPU slot cannot park main (#735 was a teardown hang
    /// there). The display layer is flushed back on main once that is done; it is already off screen,
    /// because the engine detaches the overlay before calling this. `completion` runs on main after it.
    @MainActor
    func stop(completion: (@MainActor () -> Void)? = nil) {
        lock.lock()
        stopped = true
        let item = self.item, output = self.output
        self.item = nil; self.output = nil; self.frameSource = nil
        self.player = nil
        let observer = jumpObserver
        jumpObserver = nil
        lock.unlock()
        mainTimer?.cancel(); mainTimer = nil
        feedTimer?.cancel(); pullTimer?.cancel()
        feedTimer = nil; pullTimer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let item, let output { item.remove(output) }
        tap.discardPending()
        // Logged here, not after the teardown below: a process that exits right after `stop()` (the CLI) would
        // otherwise lose it. The timers are cancelled, so only a tick already running can still move a counter.
        // The display layer's own report (frames it was given, dropped, corrupted: the presented pipeline, not
        // AVPlayer's suppressed one) follows when it answers.
        EngineLog.emit("[DualLayerOutputRoute] \(summary)", category: .engine)
        Self.teardownQueue.async { [self] in
            // The decoder first, so a tick still inside it finds it closed and hands nothing on. A composition
            // runs on the thread that hands the decoder the frame: the pull thread, or VideoToolbox's callback
            // thread when the enhancement layer arrives last. A pull tick can be waiting for a free GPU slot, a
            // wait that ends when the GPU completes one and that closing the decoder does not cut short. Only
            // the wait for the ticks below is bounded; closing the decoder itself still waits for the
            // enhancement-layer session, as on the software host, so a GPU that never completes can still hold
            // this queue, not main.
            decoder.close()
            waitForTicksToEnd()
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    if let renderer {
                        Task { @MainActor in
                            let metrics = await renderer.loadRenderMetrics()
                            EngineLog.emit("[DualLayerOutputRoute] presented: "
                                           + (metrics.map { "total=\($0.total) dropped=\($0.dropped) corrupted=\($0.corrupted) "
                                              + "delaySeconds=\(String(format: "%.3f", $0.accumulatedDelay))" } ?? "unavailable"),
                                           category: .engine)
                        }
                    }
                    sink.flushOutput(removingDisplayedImage: true)
                    if let layer = renderer?.displayLayer { layer.controlTimebase = nil }
                    completion?()
                }
            }
        }
    }

    private static let teardownQueue = DispatchQueue(label: "com.aetherengine.fel-output.teardown", qos: .userInitiated)

    /// How long `stop()` waits for a tick that is still running on a timer queue.
    static let defaultStopWaitSeconds = 2.0
    var stopWaitSeconds = defaultStopWaitSeconds

    /// Waits until the feed and pull queues have finished the tick they are in, up to `stopWaitSeconds`
    /// in all. A tick that outlasts that is left to finish by itself: the decoder is closed, so it hands
    /// nothing on.
    private func waitForTicksToEnd() {
        let ended = DispatchGroup()
        for queue in [feedQueue, pullQueue] { queue.async(group: ended) {} }
        if ended.wait(timeout: .now() + stopWaitSeconds) == .timedOut {
            EngineLog.emit("[DualLayerOutputRoute] a tick was still running \(String(format: "%.1f", stopWaitSeconds)) s after the "
                           + "decoder closed (waiting for a GPU slot?); stopping without it", category: .engine)
        }
    }

    /// One line for the end of a session: what the route did, and whether it ever fell back.
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return "summary: fed=\(fedCount) pulled=\(pulledCount) composed=\(composedSubmitted) "
            + "baseLayerOnly=\(fallbackCount) resyncs=\(resyncCount) stale=\(staleDropped) "
            + "history=\(history.count) failedWrites=\(history.failedWrites)"
    }

    /// Counters for tests and probes.
    var counters: (fed: Int, pulled: Int, composed: Int, fallback: Int, resyncs: Int, stale: Int) {
        lock.lock(); defer { lock.unlock() }
        return (fedCount, pulledCount, composedSubmitted, fallbackCount, resyncCount, staleDropped)
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        guard let layer = renderer?.displayLayer else { return }
        DispatchQueue.main.async { layer.videoGravity = gravity }
    }

    // MARK: - Clock and seeks

    /// The item timebase's time and effective rate. The timebase is thread-safe; the player and the item
    /// are not read here.
    private func readClock() -> OutputRouteClockSample? {
        if let clockOverride { return clockOverride() }
        lock.lock()
        let timebase = timebaseSource
        let isStopped = stopped
        lock.unlock()
        guard !isStopped, let timebase else { return nil }
        let time = CMTimebaseGetTime(timebase)
        guard time.isNumeric else { return nil }
        return .init(seconds: time.seconds, rate: CMTimebaseGetEffectiveRate(timebase))
    }

    /// The player reported a discontinuous change of the item's time (a seek, either way, any distance).
    /// Also the entry the tests use. Safe from any thread.
    func clockDidJump() {
        lock.lock()
        jumpMark &+= 1
        lastActivity = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// True while the timers should run at full rate: playing, or shortly after something happened.
    private func wantsFastTicks(rate: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if rate > 0 { lastActivity = now; return true }
        return now - lastActivity < Self.idleAfterSeconds
    }

    // MARK: - AVPlayer binding (main thread)

    /// Attaches the video output and the timebase to whatever item the player holds now.
    @MainActor
    private func attachOnMain() {
        lock.lock()
        let isStopped = stopped
        let player = self.player
        let attached = self.item
        lock.unlock()
        guard !isStopped, let player, let current = player.currentItem else { return }
        if attached !== current {
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            // Public API: AVPlayer decodes and times the item but does not draw it.
            output.suppressesPlayerRendering = true
            current.add(output)
            lock.lock()
            let oldOutput = self.output
            let oldObserver = jumpObserver
            lock.unlock()
            if let attached, let oldOutput { attached.remove(oldOutput) }
            if let oldObserver { NotificationCenter.default.removeObserver(oldObserver) }
            let observer = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.timeJumpedNotification, object: current, queue: nil
            ) { [weak self] _ in self?.clockDidJump() }
            lock.lock()
            item = current
            self.output = output
            frameSource = VideoOutputFrameSource(output)
            childTimebase = nil
            timebaseSource = nil
            jumpObserver = observer
            lock.unlock()
            // A replacement item is a new position: the same flush a seek asks for. The first item has nothing
            // fed yet, so there is nothing to flush.
            if attached != nil { clockDidJump() }
        }
        // The item's timebase appears once it has a player; the display layer follows it from then on.
        lock.lock()
        let needsTimebase = childTimebase == nil
        lock.unlock()
        if needsTimebase, let source = current.timebase {
            var child: CMTimebase?
            if CMTimebaseCreateWithSourceTimebase(allocator: kCFAllocatorDefault, sourceTimebase: source,
                                                  timebaseOut: &child) == noErr, let child {
                // A new child is stopped and at zero. Rate 1 makes it run as its source does, and the anchor
                // makes its time the source's, so a pause, a rate change or a seek of the item moves both.
                let now = CMTimebaseGetTime(source)
                CMTimebaseSetAnchorTime(child, timebaseTime: now, immediateSourceTime: now)
                CMTimebaseSetRate(child, rate: 1)
                lock.lock()
                childTimebase = child
                timebaseSource = source
                lock.unlock()
                renderer?.displayLayer.controlTimebase = child
            }
        }
    }

    // MARK: - VideoPacketTapReceiver

    func tapDidStart(codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational, epoch: UInt64) {
        lock.lock()
        let alreadyOpen = opened
        opened = true
        lock.unlock()
        guard !alreadyOpen, let concreteDecoder else { return }
        do {
            try concreteDecoder.openExternalBaseLayer(
                codecpar: codecpar, timeBase: AVRational(num: 1, den: 90000), frameRate: 1 / frameInterval,
                composeInPlace: composeInPlace,
                onFrame: { [weak self] buffer, pts, extra in
                    self?.sink.enqueue(pixelBuffer: buffer, pts: pts, hdr10PlusData: extra)
                })
        } catch {
            EngineLog.emit("[DualLayerOutputRoute] could not open the composer: \(error)", category: .swPlayback)
        }
    }

    func tapDidReceive(_ unit: TappedVideoPacket) {
        var packet: UnsafeMutablePointer<AVPacket>? = unit.packet
        defer { trackedPacketFree(&packet) }
        guard let data = unit.packet.pointee.data else { return }
        store(UnsafeRawBufferPointer(start: data, count: Int(unit.packet.pointee.size)),
              item: unit.item, decode: unit.decode, epoch: unit.epoch, isKeyframe: unit.isKeyframe)
    }

    /// Appends one source packet to the history. A packet the history could not store is a hole in the
    /// enhancement layer: its frame, and any run of them, goes out as the base layer.
    func store(_ bytes: UnsafeRawBufferPointer, item: CMTime, decode: CMTime, epoch: UInt64, isKeyframe: Bool) {
        guard history.append(bytes, item: item, decode: decode, epoch: epoch, isKeyframe: isKeyframe) == nil else { return }
        let failed = history.failedWrites
        lock.lock()
        let first = failedWritesLogged == 0 && failed > 0
        failedWritesLogged = failed
        lock.unlock()
        if first {
            EngineLog.emit("[DualLayerOutputRoute] the packet history could not store a packet (disk full?); "
                           + "frames without their enhancement layer play as the base layer",
                           category: .swPlayback)
        }
    }

    // MARK: - Feed (enhancement layer)

    private var feedLead: Double { Self.pullAheadSeconds + Self.feedLeadFrames * frameInterval }

    /// One feed step. Internal so the tests can drive it without timers.
    func feedTick() {
        guard let sample = readClock() else { return }
        let clock = sample.seconds
        adaptCadence(timer: feedTimer, fast: &feedFast, rate: sample.rate)
        lock.lock()
        let isOpen = opened
        let mark = jumpMark
        lock.unlock()
        guard isOpen else { return }
        if mark != handledJumpMark {
            handledJumpMark = mark
            beginResync(flushing: true, floor: 0)
        } else if state == .following, clockIsFarFromFeed(clock) {
            beginResync(flushing: true, floor: 0)
        }
        if state != .following { tryRestart(clock: clock) }
        if state == .following { feedPackets(clock: clock) }
    }

    private func clockIsFarFromFeed(_ clock: Double) -> Bool {
        guard let seq = nextSeq, let last = lastFedItem else { return false }
        if clock < last - feedLead - Self.jumpSeconds { return true }
        // Ahead of the feed with newer packets waiting means the feed fell behind; with none waiting it is
        // the producer that has not reached the clock yet, and the pull side shows the base layer meanwhile.
        if clock > last + Self.jumpSeconds, let waiting = history.entry(seq: seq), waiting.item <= clock + feedLead { return true }
        return false
    }

    /// Drops the feed position and everything composed for the old one. `flushing` also empties the
    /// composer and the display layer (the first start has nothing to empty).
    private func beginResync(flushing: Bool, floor: UInt64) {
        restartFloor = floor
        if flushing {
            // The decoder first: once its epoch moved, a composed frame still in flight is dropped, so
            // nothing of the old position reaches the display layer after the flush below.
            decoder.flush()
            deliverLock.lock()
            lock.lock()
            generation &+= 1
            coverage = .pending
            lock.unlock()
            sink.flushOutput(removingDisplayedImage: false)
            deliverLock.unlock()
        }
        lock.lock()
        resyncCount += 1
        fedItems.removeAll()
        lock.unlock()
        state = .needsRestart
        nextSeq = nil
        lastFedItem = nil
        lastLookupNewest = nil
        lastLookupClock = nil
    }

    private func setCoverage(_ value: Coverage) {
        lock.lock(); coverage = value; lock.unlock()
    }

    private func tryRestart(clock: Double) {
        // An uncovered position is looked up again only when something changed: a packet arrived, or the
        // clock moved on. Otherwise the answer would be the same.
        let newest = history.newestSeq
        if state == .uncovered, newest == lastLookupNewest, let last = lastLookupClock, abs(clock - last) < 0.25 { return }
        lastLookupNewest = newest
        lastLookupClock = clock
        let point = history.restartPoint(atOrBefore: clock, notBefore: restartFloor)
            ?? history.restartPoint(atOrBefore: clock + 0.5, notBefore: restartFloor).flatMap { $0.item - clock <= 0.5 ? $0 : nil }
        guard let point else {
            // An empty history has not been written to yet (the start); anything else that holds nothing at
            // the clock is a position the history does not cover.
            guard newest != nil else { state = .needsRestart; return }
            state = .uncovered
            setCoverage(.uncovered)
            if !uncoveredLogged {
                uncoveredLogged = true
                EngineLog.emit(
                    "[DualLayerOutputRoute] no held keyframe for \(String(format: "%.2f", clock))s "
                    + "(history \(history.coveredSeconds.map { "\(Int($0.lowerBound))-\(Int($0.upperBound))s" } ?? "empty")); "
                    + "base layer only until the playhead reaches packets the history holds",
                    category: .swPlayback)
            }
            return
        }
        uncoveredLogged = false
        state = .following
        nextSeq = point.seq
        lastFedItem = nil
        setCoverage(.covered)
    }

    private func feedPackets(clock: Double) {
        guard var seq = nextSeq else { return }
        var guardCount = 0
        while guardCount < 64, let entry = history.entry(seq: seq), entry.item <= clock + feedLead {
            guardCount += 1
            if let last = lastFedItem, abs(entry.item - last) > Self.jumpSeconds {
                // The next packet written is from somewhere else (a producer restart, or a stretch the
                // history never stored): the enhancement-layer stream is not continuous, so the composer
                // starts again at a keyframe past the gap, and the clock decides which.
                beginResync(flushing: true, floor: entry.seq)
                return
            }
            guard let data = history.read(entry) else { beginResync(flushing: true, floor: 0); return }
            feed(entry: entry, data: data)
            seq += 1
            nextSeq = seq
            lastFedItem = entry.item
        }
    }

    private func feed(entry: VideoPacketHistory.Entry, data: Data) {
        guard let packet = trackedPacketAlloc() else { return }
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { trackedPacketFree(&owned) }
        guard av_new_packet(packet, Int32(data.count)) >= 0, let target = packet.pointee.data else { return }
        data.withUnsafeBytes { memcpy(target, $0.baseAddress!, data.count) }
        let ticks = Int64((entry.item * 90000).rounded())
        packet.pointee.pts = ticks
        packet.pointee.dts = Int64((entry.decode * 90000).rounded())
        packet.pointee.flags = entry.isKeyframe ? AV_PKT_FLAG_KEY : 0
        decoder.decode(packet: packet, epoch: nil)
        lock.lock()
        fedCount += 1
        fedItems.append(entry.item)
        if fedItems.count > 160 { fedItems.removeFirst(fedItems.count - 160) }
        lock.unlock()
    }

    // MARK: - Pull (base layer)

    private func hasFedPacket(near seconds: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fedItems.contains { abs($0 - seconds) <= frameInterval * 0.7 }
    }

    /// One pull step. Internal so the tests can drive it without timers.
    func pullTick() {
        guard let sample = readClock() else { return }
        adaptCadence(timer: pullTimer, fast: &pullFast, rate: sample.rate)
        lock.lock()
        let source = frameSource
        let gen = generation
        let currentCoverage = coverage
        lock.unlock()
        guard let source else { return }
        if gen != pullGeneration {
            pullGeneration = gen
            cursor = nil
            waitingSince = nil
            degraded = false
        }
        let clock = sample.seconds
        let limit = clock + Self.pullAheadSeconds
        var guardCount = 0
        while guardCount < 8 {
            guardCount += 1
            // The next frame is one interval past the last. A frame that is already due (the pull fell
            // behind the clock) is taken at the clock instead. A frame not decoded yet is waited for, never
            // replaced by a later one, which would skip the frames between.
            let probe = max(cursor.map { $0 + frameInterval * 1.2 } ?? clock, clock)
            if probe > limit { return }
            let time = CMTime(seconds: probe, preferredTimescale: 90000)
            // Compose a frame whose packet was fed. One without it waits for the feed, but only so long: an
            // uncovered position goes out as AVPlayer's frame at once, and so does any frame whose packet is
            // still missing `lateFrameSeconds` later (a packet the history never stored, a feed that fell
            // behind). Once one has, the next unfed ones do not wait again until a fed one shows up.
            let composes = hasFedPacket(near: probe)
            if composes {
                waitingSince = nil
                degraded = false
            } else if currentCoverage != .uncovered && !degraded {
                let since = waitingSince ?? clock
                waitingSince = since
                if clock - since <= Self.lateFrameSeconds { return }
                degraded = true
            }
            guard source.hasNewFrame(at: time) else { return }
            // The epoch is read before the frame is taken: a flush after this point makes it stale.
            let epoch = decoder.feedEpoch
            guard let (buffer, display) = source.copyFrame(at: time) else { return }
            let seconds = display.seconds
            if let cursor, seconds <= cursor { continue }
            if seconds < clock - 0.75 || seconds > clock + 1.5 {
                // Left over from before a seek: it belongs to another position.
                lock.lock(); staleDropped += 1; lock.unlock()
                continue
            }
            cursor = seconds
            if composes {
                lock.lock(); pulledCount += 1; composedSubmitted += 1; lock.unlock()
                decoder.submitBaseLayerFrame(buffer, pts: display, hdr10Data: nil, epoch: epoch)
            } else {
                deliverBaseLayer(buffer, display: display, generation: gen)
            }
        }
    }

    /// Hands AVPlayer's own frame to the display layer. Its attachments are the player's: the 8.1 RPU of the
    /// stream the engine serves, or none, never a composed picture's.
    private func deliverBaseLayer(_ buffer: CVPixelBuffer, display: CMTime, generation gen: UInt64) {
        deliverLock.lock()
        lock.lock()
        let current = generation == gen && !stopped
        if current { pulledCount += 1; fallbackCount += 1 }
        lock.unlock()
        if current { sink.enqueue(pixelBuffer: buffer, pts: display, hdr10PlusData: nil) }
        deliverLock.unlock()
    }

    // MARK: - Cadence

    /// Runs the timers at full rate while the picture can change and at a low rate while paused and quiet.
    private func adaptCadence(timer: DispatchSourceTimer?, fast: inout Bool, rate: Double) {
        guard clockOverride == nil, let timer else { return }
        let wantFast = wantsFastTicks(rate: rate)
        guard wantFast != fast else { return }
        fast = wantFast
        timer.schedule(deadline: .now(), repeating: wantFast ? Self.activeTick : Self.idleTick,
                       leeway: .milliseconds(wantFast ? 1 : 20))
    }
}
#endif
