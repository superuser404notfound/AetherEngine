import Testing
import Foundation
@testable import AetherEngine

/// AE#406: the no-cut stall decision used to be evaluated inline in the pump's read loop, so it
/// could only run between `av_read_frame` calls. An origin too slow to complete one packet inside
/// the watchdog window left the watchdog unable to run at all (measured: a 35 s window fired at
/// 48 s, 30 ms after a 46.9 s read returned). The window state now lives here, mutated by the read
/// thread and evaluated by a timer, so the decision no longer depends on the call it is timing out.
///
/// The clock is injected: every test below decides against wall-clock instants it names, never
/// against elapsed real time.
@Suite("No-cut stall watchdog, off the read thread (AE#406)")
struct Issue406NoCutWatchdogTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    /// 90 kHz, the MPEG-TS video time base of the reported trace.
    private func makeWatchdog() -> NoCutStallWatchdog {
        NoCutStallWatchdog(videoTimeBaseSeconds: 1.0 / 90_000)
    }

    // MARK: - Arming

    @Test("an unarmed watchdog decides nothing")
    func unarmedDecidesNothing() {
        let w = makeWatchdog()
        #expect(w.evaluate(now: t0.addingTimeInterval(600)) == nil)
    }

    @Test("arming starts the window at the finalize, not at construction")
    func armingStartsAtFinalize() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0.addingTimeInterval(300))
        #expect(w.evaluate(now: t0.addingTimeInterval(320)) == nil)
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(340)) else {
            Issue.record("expected an exit 40s after the finalize")
            return
        }
        #expect(Int(window.stalledFor) == 40)
    }

    // MARK: - Source starvation (the reported shape)

    @Test("a trickling source exits once its 35s window passes")
    func starvedSourceExits() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        for _ in 0..<110 { w.notePacketRead() }
        #expect(w.evaluate(now: t0.addingTimeInterval(30)) == nil)
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected an exit past the starvation timeout")
            return
        }
        #expect(window.packetsRead == 110)
        #expect(window.progress == 110)
        #expect(window.readRate < HLSSegmentProducer.liveWedgeProgressRateThreshold)
        #expect(window.isWedge == false)
    }

    @Test("the decision does not need a packet to have been read")
    func decidesWithoutAnyRead() {
        // The measured failure: nothing arrives at all, so nothing on the read thread can drive a
        // decision. This is the whole point of evaluating from a timer.
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected an exit with an empty window")
            return
        }
        #expect(window.progress == 0)
        #expect(window.readRate == 0)
        #expect(window.videoPtsAdvanceSeconds == -1)
    }

    // MARK: - Finalize resets the window

    @Test("a finalize inside the window resets the clock")
    func finalizeResetsWindow() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        for _ in 0..<50 { w.notePacketRead() }
        w.noteFinalize(at: t0.addingTimeInterval(30))
        #expect(w.evaluate(now: t0.addingTimeInterval(36)) == nil)
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(70)) else {
            Issue.record("expected an exit 40s after the second finalize")
            return
        }
        #expect(window.progress == 0)  // no packet read since the finalize
    }

    // MARK: - Wedge and hold

    @Test("a cutter wedge exits on the tight timeout with frozen video PTS")
    func wedgeExitsEarly() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        for _ in 0..<1000 {
            w.notePacketRead()
            w.noteVideoPacket(pts: 90_000, isKeyframe: false)
        }
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(11)) else {
            Issue.record("expected a wedge exit at the tight timeout")
            return
        }
        #expect(window.isWedge)
        #expect(window.videoPackets == 1000)
        #expect(window.videoPtsAdvanceSeconds == 0)
    }

    @Test("slow delivery holds, re-arms from the hold, and exits once the budget is spent")
    func slowDeliveryHoldsThenExits() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        var now = t0
        var pts: Int64 = 0
        func deliverBurst() {
            for _ in 0..<1000 {
                w.notePacketRead()
                pts += 90_000 / 100          // 10 ms of video per packet
                w.noteVideoPacket(pts: pts, isKeyframe: false)
            }
        }
        for hold in 1...HLSSegmentProducer.liveSlowDeliveryMaxHolds {
            deliverBurst()
            now = now.addingTimeInterval(11)
            guard case .holdForSlowDelivery(let window)? = w.evaluate(now: now) else {
                Issue.record("expected hold \(hold)")
                return
            }
            #expect(window.consecutiveHolds == hold)
            #expect(window.videoPtsAdvanceSeconds > 2)
            // The next window measures from the hold, not from the finalize.
            #expect(w.evaluate(now: now.addingTimeInterval(5)) == nil)
        }
        deliverBurst()
        guard case .exitForRetune(let window)? = w.evaluate(now: now.addingTimeInterval(11)) else {
            Issue.record("expected an exit once the hold budget is spent")
            return
        }
        #expect(window.consecutiveHolds == HLSSegmentProducer.liveSlowDeliveryMaxHolds)
    }

    // MARK: - Parked pump

    @Test("a replay scan is not a cutter wedge while packets keep arriving")
    func replayScanTracksSourceProgress() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        w.setReplayChecking(true, at: t0.addingTimeInterval(1))
        for second in stride(from: 2, through: 50, by: 2) {
            w.noteReplayPacketRead(at: t0.addingTimeInterval(Double(second)))
            #expect(w.evaluate(now: t0.addingTimeInterval(Double(second) + 1)) == nil)
        }
        w.setReplayChecking(false, at: t0.addingTimeInterval(51))
        #expect(w.evaluate(now: t0.addingTimeInterval(60)) == nil)
    }

    @Test("a replay scan still aborts a source that stops delivering packets")
    func replayScanSourceStarvation() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        w.setReplayChecking(true, at: t0.addingTimeInterval(1))
        w.noteReplayPacketRead(at: t0.addingTimeInterval(2))
        #expect(w.evaluate(now: t0.addingTimeInterval(36)) == nil)
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(38)) else {
            Issue.record("expected a timeout after the last replay packet")
            return
        }
        #expect(window.progress == 1)
        #expect(window.isWedge == false)
    }

    @Test("a parked pump is not judged, and resuming re-arms the window")
    func parkedPumpIsNotJudged() {
        // The live headroom park sleeps the read thread on purpose (a consumer that stopped
        // polling). Inline, the watchdog simply could not run there; on a timer it must not count
        // the park as starvation, or a dead consumer would be reported as a dead source.
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        w.setReading(false, at: t0.addingTimeInterval(5))
        #expect(w.evaluate(now: t0.addingTimeInterval(300)) == nil)
        w.setReading(true, at: t0.addingTimeInterval(300))
        #expect(w.evaluate(now: t0.addingTimeInterval(320)) == nil)
        #expect(w.evaluate(now: t0.addingTimeInterval(340)) != nil)
    }

    // MARK: - The latch

    @Test("the exit latch is terminal and fires exactly once")
    func exitLatchIsTerminal() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        #expect(w.hasLatchedExit == false)
        #expect(w.evaluate(now: t0.addingTimeInterval(36)) != nil)
        #expect(w.hasLatchedExit)
        // A second tick must not log or abort a second time.
        #expect(w.evaluate(now: t0.addingTimeInterval(37)) == nil)
        // A finalize that lands in the microseconds between the decision and the abort does not
        // un-decide it: the pump is already on its way out.
        w.noteFinalize(at: t0.addingTimeInterval(37))
        #expect(w.hasLatchedExit)
        #expect(w.evaluate(now: t0.addingTimeInterval(80)) == nil)
    }

    // MARK: - Window accounting

    @Test("the window reports what the log line prints")
    func windowAccounting() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        for i in 0..<10 {
            w.notePacketRead()
            w.noteVideoPacket(pts: Int64(i) * 3600, isKeyframe: i == 0)
        }
        for _ in 0..<4 { w.notePacketRead(); w.noteAudioPacket() }
        w.notePacketRead()
        w.noteForeignPacket(streamIndex: 7)
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected an exit")
            return
        }
        #expect(window.videoPackets == 10)
        #expect(window.videoKeyframes == 1)
        #expect(window.audioPackets == 4)
        #expect(window.foreignPackets == 1)
        #expect(window.lastForeignStreamIndex == 7)
        #expect(window.packetsRead == 15)
        #expect(abs(window.videoPtsAdvanceSeconds - 0.36) < 0.001)  // 9 * 3600 ticks at 90 kHz
    }

    @Test("a PTS advance across opposite ends of Int64 saturates instead of trapping (audit SEG-101)")
    func ptsAdvanceSaturates() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        w.notePacketRead()
        w.noteVideoPacket(pts: Int64.min + 1, isKeyframe: true)
        w.notePacketRead()
        w.noteVideoPacket(pts: Int64.max, isKeyframe: false)
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected an exit")
            return
        }
        #expect(window.videoPtsAdvanceSeconds > 0)
        #expect(window.videoPtsAdvanceSeconds.isFinite)
    }

    @Test("a video packet without a PTS does not open the advance window")
    func noptsVideoIsNotAnAdvance() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        for _ in 0..<5 { w.notePacketRead(); w.noteVideoPacket(pts: Int64.min, isKeyframe: false) }
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected an exit")
            return
        }
        #expect(window.videoPackets == 5)
        #expect(window.videoPtsAdvanceSeconds == -1)
    }

    // MARK: - Two threads

    @Test("packet accounting survives concurrent notes and evaluations")
    func concurrentNotesAreNotLost() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        let tick = t0.addingTimeInterval(1)
        let evaluator = Thread {
            for _ in 0..<2_000 { _ = w.evaluate(now: tick) }
        }
        evaluator.start()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<500 { w.notePacketRead(); w.noteAudioPacket() }
        }
        while !evaluator.isFinished { usleep(1000) }
        guard case .exitForRetune(let window)? = w.evaluate(now: t0.addingTimeInterval(36)) else {
            Issue.record("expected an exit")
            return
        }
        #expect(window.packetsRead == 4_000)
        #expect(window.audioPackets == 4_000)
    }

    // MARK: - Exit gate (audit 03 cross-slice)

    /// The pump reported its exit before its watchdog stopped, and cancelling the timer does not stop
    /// a tick already running. A live producer rebuilt in place on the same demuxer could then have
    /// that demuxer closed under it by the old producer's exit.
    @Test("a retired watchdog runs no exit abort")
    func retiredWatchdogAbortsNothing() {
        let w = makeWatchdog()
        var aborts = 0
        #expect(w.performExit { aborts += 1 })
        w.retire()
        #expect(!w.performExit { aborts += 1 })
        #expect(aborts == 1)
    }

    /// R-P3-2: the pump retires the watchdog before it decides its exit reason, and reads the latch
    /// after. The latch must survive the retirement, and a verdict that lands later must not abort.
    @Test("the latch stays readable after retire, and a later verdict aborts nothing")
    func latchSurvivesRetire() {
        let w = makeWatchdog()
        w.noteFinalize(at: t0)
        var aborts = 0
        #expect(w.evaluate(now: t0.addingTimeInterval(36)) != nil)
        #expect(w.performExit { aborts += 1 })
        w.retire()
        #expect(w.hasLatchedExit)
        #expect(!w.performExit { aborts += 1 })
        #expect(aborts == 1)

        let late = makeWatchdog()
        late.noteFinalize(at: t0)
        late.retire()
        #expect(late.evaluate(now: t0.addingTimeInterval(36)) != nil)
        #expect(!late.performExit { aborts += 1 })
        #expect(aborts == 1)
    }

    @Test("retire waits for an abort already running", .timeLimit(.minutes(3)))
    func retireWaitsForRunningAbort() async throws {
        let w = makeWatchdog()
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let order = OrderLog()
        Thread.detachNewThread {
            w.performExit {
                entered.signal()
                finish.wait()
                order.append("abort finished")
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                entered.wait()
                Thread.detachNewThread {
                    // Lets the abort go only once retire() is already waiting on it.
                    while !order.contains("retire called") { usleep(1_000) }
                    usleep(20_000)
                    finish.signal()
                }
                order.append("retire called")
                w.retire()
                order.append("retire returned")
                done.resume()
            }
        }
        #expect(order.entries == ["retire called", "abort finished", "retire returned"])
    }

    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func append(_ entry: String) { lock.withLock { log.append(entry) } }
        func contains(_ entry: String) -> Bool { lock.withLock { log.contains(entry) } }
        var entries: [String] { lock.withLock { log } }
    }
}
