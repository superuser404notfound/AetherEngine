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
        struct Submit { let pts: Double; let epoch: UInt64?; let accepted: Bool }
        private let lock = NSLock()
        private var _epoch: UInt64 = 1
        private(set) var decoded: [Double] = []
        private(set) var submits: [Submit] = []
        private(set) var flushes = 0
        private(set) var closed = false
        var onFlush: (() -> Void)?
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
            submits.append(Submit(pts: pts.seconds, epoch: epoch, accepted: epoch == nil || epoch == _epoch))
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
        private(set) var flushes = 0
        func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data?) {
            lock.lock(); frames.append(pts.seconds); lock.unlock()
        }
        func flushOutput(removingDisplayedImage: Bool) { lock.lock(); flushes += 1; lock.unlock() }
        func clearRecords() { lock.lock(); frames = []; lock.unlock() }
    }

    /// AVPlayer's video output in miniature: frame `n` shows `n / 24` s, is "new" once until the player
    /// redelivers (a seek), and exists only in the ranges the test says were decoded.
    private final class ScriptedFrames: OutputRouteFrameSource, @unchecked Sendable {
        private let lock = NSLock()
        private var delivered = Set<Int>()
        private var decoded: [ClosedRange<Int>] = [0...100_000]
        var onCopy: ((Double) -> Void)?
        private let buffer: CVPixelBuffer
        init() throws {
            var out: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                      nil, &out) == kCVReturnSuccess, let out else { throw CocoaError(.fileWriteUnknown) }
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
                            historyBytes: Int = 1 << 20) throws -> Rig {
        let history = try #require(VideoPacketHistory(capacityBytes: historyBytes))
        let decoder = RecordingDecoder()
        let sink = RecordingSink()
        let clock = ClockBox()
        let route = DualLayerOutputRoute(decoder: decoder, sink: sink, history: history, frameRate: fps,
                                         clock: { clock.sample() })
        let frames = try ScriptedFrames()
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
}
#endif
