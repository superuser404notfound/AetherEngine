#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import AetherLibavcodec
import AVFoundation
@testable import AetherEngine

/// `DualLayerOutputRoute` drives AVPlayer's frames and the enhancement-layer history into the composer and
/// the display layer. These tests run the route itself with a manual clock, a scripted frame source and
/// recording doubles for the decoder and the display sink, one `feedTick` and `pullTick` at a time, so the
/// seek, the uncovered-position and the stale-frame paths are exercised without AVPlayer or a timer.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DualLayerOutputRouteTests {

    private static let fps = 24.0
    private static let interval = 1 / 24.0

    // MARK: Doubles

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _seconds = 0.0
        private var _rate = 1.0
        var seconds: Double {
            get { lock.lock(); defer { lock.unlock() }; return _seconds }
            set { lock.lock(); _seconds = newValue; lock.unlock() }
        }
        var rate: Double {
            get { lock.lock(); defer { lock.unlock() }; return _rate }
            set { lock.lock(); _rate = newValue; lock.unlock() }
        }
        func sample() -> OutputRouteClockSample { .init(seconds: seconds, rate: rate) }
    }

    private final class RecordingDecoder: OutputRouteDecoder, @unchecked Sendable {
        struct Submit { let pts: Double; let epoch: UInt64?; let accepted: Bool; let buffer: CVPixelBuffer }
        private let lock = NSLock()
        private var _epoch: UInt64 = 1
        private(set) var decoded: [Double] = []
        private(set) var submits: [Submit] = []
        private(set) var flushes = 0
        private(set) var closed = false
        var onFlush: (() -> Void)?
        var onFatalDecodeError: (@Sendable (Error) -> Void)?
        /// Called from `submitBaseLayerFrame` with no lock held; a test blocks here to stand in for the
        /// composer waiting on a GPU slot.
        var onSubmit: (() -> Void)?
        var feedEpoch: UInt64 { lock.lock(); defer { lock.unlock() }; return _epoch }
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {
            lock.lock(); decoded.append(Double(packet.pointee.pts) / 90000); lock.unlock()
        }
        func submitBaseLayerFrame(_ buffer: CVPixelBuffer, pts: CMTime, hdr10Data: Data?, epoch: UInt64?) {
            lock.lock()
            // The real decoder drops a frame stamped with an older epoch than its own.
            submits.append(Submit(pts: pts.seconds, epoch: epoch, accepted: epoch == nil || epoch == _epoch, buffer: buffer))
            lock.unlock()
            onSubmit?()
        }
        func flush() {
            lock.lock(); _epoch += 1; flushes += 1; lock.unlock()
            onFlush?()
        }
        func close() { lock.lock(); closed = true; lock.unlock() }
        var accepted: [Double] { lock.lock(); defer { lock.unlock() }; return submits.filter(\.accepted).map(\.pts) }
        func clearRecords() { lock.lock(); decoded = []; submits = []; lock.unlock() }
    }

    private final class RecordingSink: OutputRouteSink, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var frames: [Double] = []
        private(set) var buffers: [CVPixelBuffer] = []
        private(set) var flushes = 0
        func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data?) {
            lock.lock(); frames.append(pts.seconds); buffers.append(pixelBuffer); lock.unlock()
        }
        func flushOutput(removingDisplayedImage: Bool) { lock.lock(); flushes += 1; lock.unlock() }
        func clearRecords() { lock.lock(); frames = []; buffers = []; lock.unlock() }
    }

    /// AVPlayer's video output in miniature: frame `n` shows `n / 24` s, is "new" once until the player
    /// redelivers (a seek), and exists only in the ranges the test says were decoded.
    private final class ScriptedFrames: OutputRouteFrameSource, @unchecked Sendable {
        private let lock = NSLock()
        private var delivered = Set<Int>()
        private var decoded: [ClosedRange<Int>] = [0...100_000]
        var onCopy: ((Double) -> Void)?
        private let buffer: CVPixelBuffer
        init(format: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) throws {
            var out: CVPixelBuffer?
            // IOSurface-backed, as the player's buffers are: the route passes only x420 ones on untouched.
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, format,
                                      [kCVPixelBufferIOSurfacePropertiesKey: [String: String]()] as CFDictionary,
                                      &out) == kCVReturnSuccess, let out else { throw CocoaError(.fileWriteUnknown) }
            buffer = out
        }
        private func index(_ time: CMTime) -> Int { Int((time.seconds * DualLayerOutputRouteTests.fps + 1e-6).rounded(.down)) }
        func redeliver() { lock.lock(); delivered.removeAll(); lock.unlock() }
        func setDecoded(_ ranges: [ClosedRange<Int>]) { lock.lock(); decoded = ranges; lock.unlock() }
        func hasNewFrame(at time: CMTime) -> Bool {
            let n = index(time)
            lock.lock(); defer { lock.unlock() }
            return decoded.contains { $0.contains(n) } && !delivered.contains(n)
        }
        func copyFrame(at time: CMTime) -> (buffer: CVPixelBuffer, display: CMTime)? {
            let n = index(time)
            lock.lock()
            guard decoded.contains(where: { $0.contains(n) }), delivered.insert(n).inserted else { lock.unlock(); return nil }
            lock.unlock()
            onCopy?(Double(n) / DualLayerOutputRouteTests.fps)
            return (buffer, CMTime(seconds: Double(n) / DualLayerOutputRouteTests.fps, preferredTimescale: 90000))
        }
    }

    private struct Rig {
        let route: DualLayerOutputRoute
        let decoder: RecordingDecoder
        let sink: RecordingSink
        let frames: ScriptedFrames
        let clock: ClockBox
    }

    private static func rig(packetsUntil seconds: Double = 60, skipping skipped: ClosedRange<Double>? = nil,
                            historyBytes: Int = 1 << 20, converter: BaseLayerConverting? = nil,
                            frameFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) throws -> Rig {
        let history = try #require(VideoPacketHistory(capacityBytes: historyBytes))
        let decoder = RecordingDecoder()
        let sink = RecordingSink()
        let clock = ClockBox()
        let route = DualLayerOutputRoute(decoder: decoder, sink: sink, history: history, frameRate: fps,
                                         clock: { clock.sample() },
                                         baseLayerConverter: converter ?? BaseLayerFormatConverter())
        let frames = try ScriptedFrames(format: frameFormat)
        route.attachFrameSource(frames)
        let rig = Rig(route: route, decoder: decoder, sink: sink, frames: frames, clock: clock)
        store(rig, from: 0, until: seconds, skipping: skipped)
        return rig
    }

    /// Packets for every frame in `[from, until)`, a keyframe every half second.
    private static func store(_ rig: Rig, from: Double, until: Double, skipping skipped: ClosedRange<Double>? = nil) {
        var n = Int((from * fps).rounded())
        while Double(n) / fps < until {
            let t = Double(n) / fps
            if skipped?.contains(t) != true {
                let time = CMTime(seconds: t, preferredTimescale: 90000)
                [UInt8(truncatingIfNeeded: n)].withUnsafeBytes {
                    rig.route.store($0, item: time, decode: time, epoch: 1, isKeyframe: n % 12 == 0)
                }
            }
            n += 1
        }
    }

    /// One step of a clock moving at 1x: the feed and the pull the timers would run.
    private static func tick(_ rig: Rig, at seconds: Double, times: Int = 1) {
        rig.clock.seconds = seconds
        for _ in 0..<times {
            rig.route.feedTick()
            rig.route.pullTick()
        }
    }

    private static func play(_ rig: Rig, from: Double, to: Double) {
        var t = from
        while t <= to {
            tick(rig, at: t)
            t += interval / 2
        }
    }

    // MARK: Linear play

    @Test("plain play composes every frame in order and never falls back")
    func linearPlayComposesEveryFrame() throws {
        let rig = try Self.rig()
        Self.play(rig, from: 0, to: 3)
        let pts = rig.decoder.accepted
        #expect(pts.count >= 70, "about 72 frames in three seconds")
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $1 > $0 }, "in presentation order, none twice")
        #expect(rig.sink.frames.isEmpty, "no frame bypassed the composer")
        #expect(rig.decoder.flushes == 0)
        #expect(rig.route.counters.fallback == 0)
        // The enhancement layer runs ahead of the frames it belongs to.
        #expect((rig.decoder.decoded.last ?? 0) > pts.last ?? 0)
    }

    // MARK: Seeks

    @Test("a short seek either way is handled like a seek", arguments: [-1.0, -0.5, 0.5, 1.0])
    func shortSeekFlushesAndResumes(delta: Double) throws {
        let rig = try Self.rig()
        Self.play(rig, from: 0, to: 5)
        let before = rig.decoder.flushes
        let target = 5 + delta
        rig.frames.redeliver()
        rig.clock.seconds = target
        rig.route.clockDidJump()
        rig.decoder.clearRecords()
        Self.play(rig, from: target, to: target + 1)
        #expect(rig.decoder.flushes == before + 1, "the composer is flushed once")
        #expect(rig.sink.flushes == before + 1, "so is the display layer")
        let pts = rig.decoder.accepted
        #expect(pts.first.map { abs($0 - target) <= Self.interval * 1.5 } == true,
                "the first frame after the seek is at the new position, not later")
        #expect(pts.count >= 20, "and the picture keeps moving (no frozen wait for the old cursor)")
        #expect(rig.sink.frames.isEmpty, "every frame was composed, none went out as the base layer")
        // The enhancement layer restarted at a keyframe at or before the target.
        #expect((rig.decoder.decoded.first ?? 99) <= target)
    }

    @Test("a long jump is a seek even when the player did not say so")
    func farClockJumpIsASeek() throws {
        let rig = try Self.rig()
        Self.play(rig, from: 0, to: 4)
        rig.frames.redeliver()
        rig.decoder.clearRecords()
        Self.play(rig, from: 30, to: 31)
        #expect(rig.decoder.flushes == 1)
        #expect(rig.decoder.accepted.first.map { abs($0 - 30) <= Self.interval * 1.5 } == true)
    }

    // MARK: Uncovered positions

    @Test("a position the history does not hold shows AVPlayer's frames, flushes once, and composes when covered")
    func uncoveredPositionShowsTheBaseLayer() throws {
        let rig = try Self.rig(packetsUntil: 10)
        Self.play(rig, from: 0, to: 2)
        rig.frames.redeliver()
        rig.decoder.clearRecords()
        rig.sink.clearRecords()
        rig.clock.seconds = 40
        rig.route.clockDidJump()
        Self.play(rig, from: 40, to: 41)
        #expect(rig.decoder.flushes == 1, "one flush for the seek, not one per tick")
        #expect(rig.decoder.accepted.isEmpty, "nothing to compose without an enhancement layer")
        #expect(rig.sink.frames.count >= 20, "AVPlayer's frames reach the display layer: no frozen picture")
        #expect(zip(rig.sink.frames, rig.sink.frames.dropFirst()).allSatisfy { $1 > $0 })
        #expect(rig.sink.frames.first.map { abs($0 - 40) <= Self.interval * 1.5 } == true)
        #expect(rig.route.counters.fallback == rig.sink.frames.count)

        // The producer reaches the position: the route composes again, with one more flush at most.
        Self.store(rig, from: 41, until: 50)
        rig.decoder.clearRecords()
        rig.sink.clearRecords()
        Self.play(rig, from: 41.5, to: 43)
        #expect(!rig.decoder.accepted.isEmpty, "composition resumes once the history covers the clock")
        #expect(rig.decoder.flushes <= 2)
        #expect(rig.sink.frames.count <= 3, "only the frames that were already due when the packets arrived")
    }

    @Test("a forward seek whose old keyframe is still inside the look-back does not loop")
    func forwardSeekPastTheNewestPacketDoesNotLoop() throws {
        let rig = try Self.rig(packetsUntil: 30)
        Self.play(rig, from: 0, to: 2)
        rig.frames.redeliver()
        rig.decoder.clearRecords()
        rig.sink.clearRecords()
        rig.clock.seconds = 38
        rig.route.clockDidJump()
        Self.play(rig, from: 38, to: 40)
        #expect(rig.decoder.flushes == 1, "one flush, however long the producer takes")
        #expect(rig.sink.frames.count >= 30, "the base layer meanwhile; the picture does not freeze")
        // The producer restarts at the target: its packets sit far from the old ones in the history.
        Self.store(rig, from: 38, until: 48)
        rig.decoder.clearRecords()
        Self.play(rig, from: 40, to: 42)
        #expect(!rig.decoder.accepted.isEmpty)
        #expect(rig.decoder.flushes <= 2)
    }

    @Test("packets the history never stored play as the base layer and the run recovers after them")
    func missingPacketsDoNotFreeze() throws {
        let rig = try Self.rig(packetsUntil: 20, skipping: 3.0...4.5)
        Self.play(rig, from: 0, to: 6)
        let composed = Set(rig.decoder.accepted.map { Int(($0 * Self.fps).rounded()) })
        let bypassed = Set(rig.sink.frames.map { Int(($0 * Self.fps).rounded()) })
        let expected = Set(0..<Int(5.9 * Self.fps))
        let missing = expected.subtracting(composed).subtracting(bypassed)
        #expect(missing.isEmpty, "every frame was shown one way or the other: \(missing.sorted().prefix(5))")
        #expect(!bypassed.isEmpty)
        #expect(bypassed.allSatisfy { $0 >= Int(3.0 * Self.fps) && $0 <= Int(5.1 * Self.fps) },
                "only from the hole to the first keyframe after it, where the composer starts again")
        #expect(composed.contains(Int(5.5 * Self.fps)), "composition resumes after the hole")
        #expect(rig.decoder.flushes == 1, "the composer restarts once at the gap, not on every tick")
    }

    @Test("a long hole in the history does not loop the resync or freeze the picture")
    func longHoleDoesNotLoopResync() throws {
        let rig = try Self.rig(packetsUntil: 20, skipping: 3.0...9.0)
        Self.play(rig, from: 0, to: 11)
        let composed = Set(rig.decoder.accepted.map { Int(($0 * Self.fps).rounded()) })
        let bypassed = Set(rig.sink.frames.map { Int(($0 * Self.fps).rounded()) })
        let expected = Set(0..<Int(10.9 * Self.fps))
        let missing = expected.subtracting(composed).subtracting(bypassed)
        #expect(missing.isEmpty, "every frame was shown one way or the other: \(missing.sorted().prefix(5))")
        #expect(rig.decoder.flushes <= 2, "the composer restarts at the hole, not on every tick: \(rig.decoder.flushes)")
    }

    // MARK: Stale frames

    @Test("a frame copied before a flush carries the old epoch and is not accepted")
    func staleFrameIsRejectedByEpoch() throws {
        let rig = try Self.rig()
        Self.play(rig, from: 0, to: 2)
        // A seek lands while the pull side is inside copyPixelBuffer.
        let route = rig.route
        rig.frames.onCopy = { _ in
            rig.frames.onCopy = nil
            route.clockDidJump()
            route.feedTick()
        }
        rig.frames.redeliver()
        rig.decoder.clearRecords()
        Self.tick(rig, at: 2.0 + Self.interval)
        let stale = rig.decoder.submits.filter { !$0.accepted }
        #expect(stale.count == 1, "the frame taken before the flush went to the decoder with its old epoch")
        #expect(rig.decoder.flushes == 1)
    }

    // MARK: Teardown

    /// `stop()` returns before the teardown queue is done; its completion lands on main, so the caller
    /// awaits it instead of blocking main.
    @MainActor static func finishStop(_ route: DualLayerOutputRoute) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in route.stop { done.resume() } }
    }

    /// A semaphore wait the async tests can call: blocking is the point here, the tick under test runs elsewhere.
    static func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + seconds)
    }

    @Test("stop closes the decoder, flushes the display layer and ends the ticks")
    @MainActor func stopClosesTheDecoder() async throws {
        let rig = try Self.rig()
        Self.play(rig, from: 0, to: 1)
        let sinkFlushes = rig.sink.flushes
        await Self.finishStop(rig.route)
        #expect(rig.decoder.closed)
        #expect(rig.sink.flushes == sinkFlushes + 1)
    }

    @Test("stop does not wait for ever on a tick blocked in the decoder")
    @MainActor func stopDoesNotWaitForeverOnABlockedTick() async throws {
        let rig = try Self.rig()
        Self.play(rig, from: 0, to: 1)
        // The composition runs on the caller's thread, so a pull tick can sit in `submitBaseLayerFrame`
        // waiting for a GPU slot. Closing the decoder does not end that wait.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        rig.decoder.onSubmit = { entered.signal(); release.wait() }
        rig.route.stopWaitSeconds = 0.3
        rig.frames.redeliver()
        rig.route.clockDidJump()
        rig.route.start(player: AVPlayer())
        defer { for _ in 0..<16 { release.signal() } }
        #expect(Self.wait(entered, seconds: 10) == .success, "a pull tick reached the decoder and blocks there")
        let started = ProcessInfo.processInfo.systemUptime
        let teardown = AsyncStream<Void>.makeStream()
        rig.route.stop { teardown.continuation.finish() }
        let returned = ProcessInfo.processInfo.systemUptime - started
        #expect(returned < 0.2, "stop returned to main without waiting for the tick (\(returned) s)")
        for await _ in teardown.stream {}
        let waited = ProcessInfo.processInfo.systemUptime - started
        #expect(rig.decoder.closed)
        #expect(waited < 5, "the teardown ended after its own bound (\(waited) s) instead of waiting for the tick")
    }

    @Test("a fallback tick released after stop hands nothing to the display layer")
    @MainActor func lateFallbackTickAfterStopHandsNothingOn() async throws {
        // The history has a hole from 3.0 s to 4.5 s, so frames in it go out as AVPlayer's own frame (the
        // fallback path, no composer) once the packet has been missing for a moment.
        let rig = try Self.rig(packetsUntil: 20, skipping: 3.0...4.5)
        Self.play(rig, from: 0, to: 2.5)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Blocks after a frame inside the hole was taken and before it is handed on, so `stop()` lands in between.
        rig.frames.onCopy = { time in
            if time >= 3.1 { rig.frames.onCopy = nil; entered.signal(); release.wait() }
        }
        let ticksDone = DispatchSemaphore(value: 0)
        let ticks = Thread {
            var t = 2.5
            while t <= 4.4 { Self.tick(rig, at: t); t += Self.interval / 2 }
            ticksDone.signal()
        }
        ticks.start()
        defer { for _ in 0..<16 { release.signal() } }
        #expect(Self.wait(entered, seconds: 10) == .success, "a pull tick took a fallback frame and blocks before delivering it")
        let teardown = AsyncStream<Void>.makeStream()
        rig.route.stop { teardown.continuation.finish() }
        let framesAtStop = rig.sink.frames.count
        for _ in 0..<16 { release.signal() }
        #expect(Self.wait(ticksDone, seconds: 10) == .success, "the released ticks ended")
        for await _ in teardown.stream {}
        #expect(rig.sink.frames.count == framesAtStop, "the released tick hands nothing to the display layer")
    }

    // MARK: Conversion of the player's frames

    /// A converter whose answer the test sets: hand the buffer on as it is, hand a given one on, refuse, or fail.
    private final class ScriptedConverter: BaseLayerConverting, @unchecked Sendable {
        enum Mode { case passThrough, replace(CVPixelBuffer), refuse, fail }
        private let lock = NSLock()
        private var _mode: Mode
        private var _prepared = 0, _trims = 0, _tornDown = 0, _preparedAfterTearDown = 0
        /// Called from `tearDown` with no lock held.
        var onTearDown: (() -> Void)?
        init(_ mode: Mode) { _mode = mode }
        var mode: Mode {
            get { lock.lock(); defer { lock.unlock() }; return _mode }
            set { lock.lock(); _mode = newValue; lock.unlock() }
        }
        var prepared: Int { lock.lock(); defer { lock.unlock() }; return _prepared }
        var trims: Int { lock.lock(); defer { lock.unlock() }; return _trims }
        var tornDown: Int { lock.lock(); defer { lock.unlock() }; return _tornDown }
        var preparedAfterTearDown: Int { lock.lock(); defer { lock.unlock() }; return _preparedAfterTearDown }
        func prepare(_ buffer: CVPixelBuffer) -> BaseLayerPreparation {
            lock.lock(); _prepared += 1; let mode = _mode
            // The contract of the real converter: once torn down it converts nothing and fails the frame.
            let closed = _tornDown > 0
            if closed { _preparedAfterTearDown += 1 }
            lock.unlock()
            if closed { return .failed("the converter is closed") }
            switch mode {
            case .passThrough: return .ready(buffer)
            case .replace(let other): return .ready(other)
            case .refuse: return .refused
            case .fail: return .failed("scripted")
            }
        }
        func trimIfIdle() { lock.lock(); _trims += 1; lock.unlock() }
        func tearDown() { lock.lock(); _tornDown += 1; lock.unlock(); onTearDown?() }
        var statistics: BaseLayerConversionStatistics { BaseLayerConversionStatistics() }
    }

    private static func makeBuffer() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [String: String]()] as CFDictionary,
                                  &out) == kCVReturnSuccess, let out else { throw CocoaError(.fileWriteUnknown) }
        return out
    }

    @Test("the composer is handed the converted buffer, never the player's",
          arguments: [false, true])
    func composerGetsTheConvertedBuffer(uncovered: Bool) throws {
        let converted = try Self.makeBuffer()
        let rig = try Self.rig(packetsUntil: uncovered ? 0 : 60, converter: ScriptedConverter(.replace(converted)))
        Self.play(rig, from: 0, to: 2)
        let handedOn = uncovered ? rig.sink.buffers : rig.decoder.submits.map(\.buffer)
        #expect(handedOn.count >= 20, "frames went on")
        #expect(handedOn.allSatisfy { $0 === converted }, "every frame handed on is the converter's output")
    }

    @Test("a frame that cannot be converted never reaches the composer or the display layer, and the route hands back once",
          arguments: [false, true])
    func failedConversionHandsNothingOnAndHandsBack(uncovered: Bool) throws {
        let converter = ScriptedConverter(.fail)
        // Uncovered: no packets at all, so every frame is the fallback path that goes to the display layer.
        let rig = try Self.rig(packetsUntil: uncovered ? 0 : 60, converter: converter)
        let reports = Counter()
        rig.route.onConversionFailure = { _ in reports.bump() }
        Self.play(rig, from: 0, to: 0.5)
        #expect(reports.count == 0, "a failure run shorter than the bound hands nothing back")
        Self.play(rig, from: 0.5, to: 3)
        #expect(converter.prepared >= 40, "the conversion was tried on the frames")
        #expect(rig.decoder.submits.isEmpty, "the composer was handed nothing")
        #expect(rig.sink.frames.isEmpty, "the display layer was handed nothing")
        #expect(reports.count == 1, "handed back once, not once per frame")
    }

    @Test("a refusal of the conversion pool skips the frame and never hands the route back")
    func refusalIsBackpressureNotAFault() throws {
        let converter = ScriptedConverter(.refuse)
        let rig = try Self.rig(converter: converter)
        let reports = Counter()
        rig.route.onConversionFailure = { _ in reports.bump() }
        // Far longer than the failure bound.
        Self.play(rig, from: 0, to: 3)
        #expect(rig.decoder.submits.isEmpty)
        #expect(reports.count == 0)
        // The pool frees up: the route composes again with no help.
        converter.mode = .passThrough
        Self.play(rig, from: 3, to: 4)
        #expect(rig.decoder.accepted.count >= 15)
        #expect(reports.count == 0)
    }

    @Test("two failure runs, each shorter than the bound, with a success between them hand nothing back")
    func successEndsAFailureRun() throws {
        let converter = ScriptedConverter(.fail)
        let rig = try Self.rig(converter: converter)
        let reports = Counter()
        rig.route.onConversionFailure = { _ in reports.bump() }
        Self.play(rig, from: 0, to: 0.6)
        converter.mode = .passThrough
        Self.play(rig, from: 0.6, to: 0.7)
        converter.mode = .fail
        Self.play(rig, from: 0.7, to: 1.3)
        #expect(reports.count == 0)
        // The same failure without the success in between is a run of 1.4 s.
        Self.play(rig, from: 1.3, to: 2.4)
        #expect(reports.count == 1)
    }

    @Test("a failure run is cut off by a seek")
    func seekEndsAFailureRun() throws {
        let converter = ScriptedConverter(.fail)
        let failing = try Self.rig(converter: converter)
        let reports = Counter()
        failing.route.onConversionFailure = { _ in reports.bump() }
        Self.play(failing, from: 0, to: 0.6)
        failing.frames.redeliver()
        failing.clock.seconds = 30
        failing.route.clockDidJump()
        Self.play(failing, from: 30, to: 30.6)
        #expect(reports.count == 0, "0.6 s before the seek and 0.6 s after are two runs, not one of 1.2 s")
    }

    @Test("the pull tick lets the converter give back idle buffers")
    func pullTickTrimsTheConverter() throws {
        let converter = ScriptedConverter(.passThrough)
        let rig = try Self.rig(converter: converter)
        Self.play(rig, from: 0, to: 0.5)
        #expect(converter.trims >= 20)
    }

    @Test("the stop path tears the converter down once, after the decoder is closed and the ticks have ended")
    @MainActor func stopTearsTheConverterDown() async throws {
        let converter = ScriptedConverter(.passThrough)
        let rig = try Self.rig(converter: converter)
        Self.play(rig, from: 0, to: 0.5)
        #expect(converter.tornDown == 0)
        let decoderClosedAtTearDown = Counter()
        converter.onTearDown = { if rig.decoder.closed { decoderClosedAtTearDown.bump() } }
        await Self.finishStop(rig.route)
        #expect(converter.tornDown == 1)
        #expect(decoderClosedAtTearDown.count == 1, "the converter outlives the decoder's close")
    }

    @Test("a tick that outlasts the stop's bounded wait finds the converter closed and hands nothing on")
    @MainActor func lateTickAfterTearDownConvertsNothing() async throws {
        let converter = ScriptedConverter(.passThrough)
        let rig = try Self.rig(converter: converter)
        Self.play(rig, from: 0, to: 0.5)
        // A pull tick sits in the composer's submit (a GPU slot wait) when the stop comes; the wait for it is
        // bounded, so the teardown runs under it. Frames are waiting, so the tick goes on to convert the next
        // one once released.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        rig.decoder.onSubmit = { entered.signal(); release.wait() }
        rig.route.stopWaitSeconds = 0.2
        rig.frames.redeliver()
        rig.route.clockDidJump()
        let reports = Counter()
        rig.route.onConversionFailure = { _ in reports.bump() }
        rig.route.start(player: AVPlayer())
        defer { for _ in 0..<16 { release.signal() } }
        #expect(Self.wait(entered, seconds: 10) == .success, "a pull tick reached the composer and blocks there")
        await Self.finishStop(rig.route)
        #expect(converter.tornDown == 1, "the teardown ran although the tick is still inside the composer")
        let submitsAtStop = rig.decoder.submits.count
        let framesAtStop = rig.sink.frames.count
        rig.decoder.onSubmit = nil
        for _ in 0..<16 { release.signal() }
        // The released tick takes its next frame from the source and asks the converter for it.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while converter.preparedAfterTearDown == 0, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(converter.preparedAfterTearDown >= 1, "the released tick asked the converter for another frame")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.decoder.submits.count == submitsAtStop, "the composer was handed nothing after the teardown")
        #expect(rig.sink.frames.count == framesAtStop, "the display layer was handed nothing after the teardown")
        #expect(reports.count == 0, "a stopped route does not report a conversion failure")
    }


    // MARK: The counters and the stop

    @Test("stop() returns while a transfer is blocked, and the summary it logs does not wait for the transfer")
    func stopDoesNotWaitOnABlockedTransfer() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let converter = BaseLayerFormatConverter(transfer: { _, _, _ in entered.signal(); release.wait(); return noErr })
        // 8-bit frames: every one needs a conversion, so the pull tick goes into the (blocked) transfer.
        let rig = try Self.rig(converter: converter, frameFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        defer { for _ in 0..<8 { release.signal() } }
        rig.clock.seconds = 0
        rig.route.feedTick()
        let tickDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { rig.route.pullTick(); tickDone.signal() }
        #expect(Self.wait(entered, seconds: 10) == .success, "the pull tick never reached the transfer")
        let summaryRead = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = rig.route.summary; summaryRead.signal() }
        #expect(Self.wait(summaryRead, seconds: 3) == .success, "summary waited on the transfer")
        rig.route.stopWaitSeconds = 0.2
        let stopped = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        Task { @MainActor in rig.route.stop { completed.signal() }; stopped.signal() }
        #expect(Self.wait(stopped, seconds: 3) == .success, "stop() on the main actor waited on the transfer in progress")
        for _ in 0..<8 { release.signal() }
        #expect(Self.wait(tickDone, seconds: 10) == .success)
        #expect(Self.wait(completed, seconds: 10) == .success, "the teardown finished once the transfer did")
    }

    @Test("a run of pool refusals is logged when it starts, once per run, and a conversion that heals it ends the run")
    func refusalRunsAreLoggedOnce() throws {
        let converter = ScriptedConverter(.refuse)
        let rig = try Self.rig(converter: converter)
        let capture = EngineLogCapture()
        defer { capture.end() }
        Self.play(rig, from: 0, to: 2)
        #expect(rig.route.refusalRunsLogged == 1, "one line for a run of many refusals")
        #expect(!capture.matching("the conversion pool is full").isEmpty)
        converter.mode = .passThrough
        Self.play(rig, from: 2, to: 3)
        converter.mode = .refuse
        Self.play(rig, from: 3, to: 4)
        #expect(rig.route.refusalRunsLogged == 2, "a second run after a conversion is a new line")
        for run in 0..<(DualLayerOutputRoute.refusalRunLogLimit + 3) {
            converter.mode = .passThrough
            Self.play(rig, from: 4 + Double(run) * 2, to: 4.5 + Double(run) * 2)
            converter.mode = .refuse
            Self.play(rig, from: 4.5 + Double(run) * 2, to: 5.5 + Double(run) * 2)
        }
        #expect(rig.route.refusalRunsLogged == DualLayerOutputRoute.refusalRunLogLimit, "the lines are bounded")
    }

    // MARK: A decoder that cannot produce video

    @Test("a fatal decoder error reaches the route's owner once, however often the decoder reports it")
    func decoderFailureIsReportedOnce() throws {
        let rig = try Self.rig()
        let reports = Counter()
        rig.route.onDecoderFailure = { _ in reports.bump() }
        let fire = try #require(rig.decoder.onFatalDecodeError, "the route never installed its handler")
        fire(VideoDecoderError.composerStalled)
        fire(VideoDecoderError.composerStalled)
        #expect(reports.count == 1)
    }

    @Test("a decoder error that arrives after the route stopped is not reported")
    @MainActor func decoderFailureAfterStopIsIgnored() async throws {
        let rig = try Self.rig()
        let reports = Counter()
        rig.route.onDecoderFailure = { _ in reports.bump() }
        let fire = try #require(rig.decoder.onFatalDecodeError)
        await Self.finishStop(rig.route)
        fire(VideoDecoderError.composerStalled)
        #expect(reports.count == 0)
    }

    @Test("the engine hands the picture back to AVPlayer when the decoder fails, and only for its own route")
    @MainActor func engineHandsBackOnDecoderFailure() async throws {
        let engine = try AetherEngine()
        let failingRig = try Self.rig()
        let failing = failingRig.route
        engine.dualLayerOutputRoute = failing
        engine.handBackOnDecoderFailure(of: failing)
        let fire = try #require(failingRig.decoder.onFatalDecodeError)
        fire(VideoDecoderError.composerStalled)
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.dualLayerOutputRoute != nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(engine.dualLayerOutputRoute == nil, "the failed route was stopped")

        // A report of a route that is no longer the engine's stops nothing.
        let oldRig = try Self.rig()
        engine.handBackOnDecoderFailure(of: oldRig.route)
        let successor = try Self.rig().route
        engine.dualLayerOutputRoute = successor
        let staleFire = try #require(oldRig.decoder.onFatalDecodeError)
        staleFire(VideoDecoderError.composerStalled)
        await Task { @MainActor in }.value
        #expect(engine.dualLayerOutputRoute === successor)
        engine.stopDualLayerOutputRoute()
    }

    @Test("the engine hands the picture back to AVPlayer when the conversion fails, and only for its own route")
    @MainActor func engineHandsBackOnConversionFailure() async throws {
        let engine = try AetherEngine()
        let failing = try Self.rig().route
        engine.dualLayerOutputRoute = failing
        engine.handBackOnConversionFailure(of: failing)
        let report = try #require(failing.onConversionFailure)
        report("scripted")
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.dualLayerOutputRoute != nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(engine.dualLayerOutputRoute == nil, "the failed route was stopped")

        // A report of a route that is no longer the engine's stops nothing.
        let old = try Self.rig().route
        engine.handBackOnConversionFailure(of: old)
        let successor = try Self.rig().route
        engine.dualLayerOutputRoute = successor
        let staleReport = try #require(old.onConversionFailure)
        staleReport("scripted")
        await Task { @MainActor in }.value
        #expect(engine.dualLayerOutputRoute === successor)
        engine.stopDualLayerOutputRoute()
    }

    @Test("a wait for a packet starts again after a seek: the time spent at the old position does not count")
    func seekRestartsTheWaitForAPacket() throws {
        let rig = try Self.rig()
        // The pull side runs ahead of the feed: no packet has been fed, so frames wait for theirs.
        rig.clock.seconds = 1.0
        rig.route.pullTick()
        rig.clock.seconds = 1.05
        rig.route.pullTick()
        // The clock jumps forward by less than the route's own seek threshold, before the feed has run.
        rig.clock.seconds = 2.0
        rig.route.pullTick()
        #expect(rig.sink.frames.isEmpty, "the frame waits for its packet; the 1 s spent at the old position is not its wait")
        Self.tick(rig, at: 2.0)
        Self.play(rig, from: 2.0, to: 3.0)
        #expect(rig.sink.frames.isEmpty, "every frame was composed")
        #expect(rig.decoder.accepted.count >= 20)
    }

    @Test("a frame whose own packet is not fed yet is not composed, even when its neighbour's packet was fed")
    func frameWithoutItsOwnPacketGoesOutAsTheBaseLayer() throws {
        // Frame 50 has no packet in the history; its neighbours do. The clock is a fraction into frame 50,
        // so the probe time sits within reach of frame 51's packet.
        let hole = 50.0 / Self.fps
        let rig = try Self.rig(skipping: hole...hole)
        Self.tick(rig, at: 50.4 / Self.fps)
        let sent = Set(rig.decoder.accepted.map { Int(($0 * Self.fps).rounded()) })
        let shown = Set(rig.sink.frames.map { Int(($0 * Self.fps).rounded()) })
        #expect(shown.contains(50), "the frame without a packet went out as the player's frame")
        #expect(!sent.contains(50), "it was not composed without its RPU")
        #expect(sent.contains(51), "its neighbour, which has a packet, was composed")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }
}
#endif
