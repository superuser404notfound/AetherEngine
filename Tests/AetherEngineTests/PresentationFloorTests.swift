import Foundation
import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import AetherEngine

/// The FEL path hands frames to the renderer in decode order and promises it a floor on the
/// timestamps still to come (`PresentationFloor`). The promise is only useful if it is never broken:
/// a frame that arrives below it may be dropped. These walk real decode orders (hierarchical-B GOPs
/// of 4, 8 and 16, as VideoToolbox emits them) and check the floor never passes a frame still to come.
@Suite("Presentation floor for arrival-order handover")
struct PresentationFloorTests {

    static let fps = 24.0
    static let interval = 1 / fps

    /// Display indices in decode order for a hierarchical-B GOP of `gop`: anchor first, then bisection.
    static func decodeOrder(gop: Int, frames: Int, startingAt base0: Int = 0) -> [Int] {
        var out = [base0]
        func bisect(_ lo: Int, _ hi: Int) {
            guard hi - lo >= 2 else { return }
            let mid = (lo + hi) / 2
            out.append(mid); bisect(lo, mid); bisect(mid, hi)
        }
        var base = base0
        while base + gop < base0 + frames {
            out.append(base + gop); bisect(base, base + gop); base += gop
        }
        for i in (base + 1)..<(base0 + frames) { out.append(i) }
        return out
    }

    /// Feeds `order` (display indices) and checks, after every frame, that nothing still to come sits
    /// below the floor. Returns the floor and the display-order spacing it reported.
    static func walk(_ order: [Int], start: Double? = nil, clock: (Int) -> Double? = { _ in nil },
                     timestamp: (Int) -> Double = { Double($0) * interval })
        -> (floor: PresentationFloor, shown: [Double], violations: Int) {
        var floor = PresentationFloor(interval: interval)
        floor.reset(start: start)
        var shown: [Double] = []
        var violations = 0
        for (k, index) in order.enumerated() {
            let step = floor.record(timestamp(index), clockSeconds: clock(k))
            if step.belowFloor { violations += 1 }
            shown += step.contiguous
            let stillToCome = order[(k + 1)...].map(timestamp)
            if let lowest = stillToCome.min(), lowest < floor.floor { violations += 1 }
        }
        return (floor, shown, violations)
    }

    @Test("In display or decode order the floor never passes a frame still to come", arguments: [0, 4, 8, 16])
    func neverPassesAFrameStillToCome(gop: Int) {
        let order = gop == 0 ? Array(0..<96) : Self.decodeOrder(gop: gop, frames: 96)
        #expect(Set(order) == Set(0..<96), "the generator covers every frame once")
        let r = Self.walk(order)
        #expect(r.violations == 0)
        // Every frame joins the frontier exactly once, in display order.
        #expect(r.shown == (0..<96).map { Double($0) * Self.interval })
        #expect(abs(r.floor.floor - (95.5 * Self.interval)) < 1e-9)
        #expect(r.floor.ahead.isEmpty)
    }

    @Test("The floor rises within a GOP, not only at its end")
    func risesInsideTheGOP() {
        // GOP of 8: 0, 8, 4, 2, 1, 3, 6, 5, 7. Once 1 arrives, 0..2 are contiguous.
        var floor = PresentationFloor(interval: Self.interval)
        var raised: [Double?] = []
        for i in [0, 8, 4, 2, 1] { raised.append(floor.record(Double(i) * Self.interval, clockSeconds: nil).raisedFloor) }
        #expect(raised[1] == nil && raised[2] == nil && raised[3] == nil, "8, 4 and 2 leave a gap below them")
        #expect(abs((raised[4] ?? 0) - 2.5 * Self.interval) < 1e-9, "1 closes the gap up to 2")
    }

    @Test("After a seek the floor starts at the threshold, not at the first frame past it")
    func startsAtTheSeekThreshold() {
        // Decoding restarts at the GOP's anchor below the target; frames below the target are skipped
        // before they reach the floor, so the first one it sees is the next anchor, ABOVE B-frames
        // that arrive after it.
        let target = 100
        let order = Self.decodeOrder(gop: 8, frames: 48, startingAt: 96).filter { $0 >= target }
        #expect(order.first == 104, "the anchor past the target arrives before 100...103")
        let seeded = Self.walk(order, start: Double(target) * Self.interval)
        #expect(seeded.violations == 0)
        let unseeded = Self.walk(order)
        #expect(unseeded.violations > 0, "seeding from the first frame would promise past 100...103")
    }

    @Test("Millisecond-rounded 23.976 timestamps stay contiguous")
    func roundedTimestamps() {
        let rate = 24000.0 / 1001
        var floor = PresentationFloor(interval: 1 / rate)
        var shown = 0
        for i in Self.decodeOrder(gop: 8, frames: 240) {
            let ms = (Double(i) * 1001 / 24000 * 1000).rounded()
            let step = floor.record(ms / 1000, clockSeconds: nil)
            #expect(!step.belowFloor)
            shown += step.contiguous.count
        }
        #expect(shown == 240)
        #expect(floor.ahead.isEmpty)
    }

    @Test("A frame that never comes is given up once the clock passes it")
    func clockPassesAHole() {
        // Frame 3 is lost. Without the clock the floor would wait below it forever.
        let order = [0, 1, 2, 4, 5, 6, 7, 8]
        let stuck = Self.walk(order)
        #expect(abs(stuck.floor.floor - 2.5 * Self.interval) < 1e-9)
        let moving = Self.walk(order, clock: { k in k >= 5 ? 3.6 * Self.interval : nil })
        #expect(abs(moving.floor.floor - 8.5 * Self.interval) < 1e-9)
        #expect(moving.violations == 0)
    }

    @Test("After an off-grid seek a running clock never promises past a frame not yet due",
          arguments: [0.1, 0.25, 0.51, 0.75, 0.9])
    func offGridSeekWithARunningClock(phase: Double) {
        let target = (100 + phase) * Self.interval
        let order = Self.decodeOrder(gop: 8, frames: 48, startingAt: 96).filter { Double($0) * Self.interval >= target }
        for lag in stride(from: 0.0, through: 0.9, by: 0.05) {
            // The clock was seeked to the target and runs while the first frames past it arrive. Only a
            // frame the clock has not reached yet is owed; one it has passed is late with or without
            // the floor.
            var floor = PresentationFloor(interval: Self.interval)
            floor.reset(start: target)
            var owedBelowFloor = 0
            for (k, index) in order.enumerated() {
                let clock = target + (lag + Double(k) * 0.1) * Self.interval
                _ = floor.record(Double(index) * Self.interval, clockSeconds: clock)
                owedBelowFloor += order[(k + 1)...].filter {
                    let t = Double($0) * Self.interval
                    return t >= clock && t < floor.floor
                }.count
            }
            #expect(owedBelowFloor == 0, "phase \(phase), lag \(lag)")
        }
    }

    @Test("A hole the clock can no longer reach is given up once enough frames pile up behind it")
    func holePastTheClockGap() {
        var floor = PresentationFloor(interval: Self.interval)
        for i in 0..<3 { _ = floor.record(Double(i) * Self.interval, clockSeconds: nil) }
        // Frame 3 is lost and the clock is far past the frontier, so it does not count.
        for i in 4..<200 { _ = floor.record(Double(i) * Self.interval, clockSeconds: 1000) }
        #expect(floor.ahead.count <= PresentationFloor.maxAhead + 1)
        #expect(abs(floor.floor - 199.5 * Self.interval) < 1e-9)
    }

    @Test("A frame below the promised floor is flagged and does not move it")
    func belowFloorIsFlagged() {
        var floor = PresentationFloor(interval: Self.interval)
        for i in 0..<5 { _ = floor.record(Double(i) * Self.interval, clockSeconds: nil) }
        let before = floor.floor
        let late = floor.record(1 * Self.interval, clockSeconds: nil)
        #expect(late.belowFloor)
        #expect(late.raisedFloor == nil)
        #expect(floor.floor == before)
    }

    @Test("A reset forgets the promise")
    func resetForgets() {
        var floor = PresentationFloor(interval: Self.interval)
        for i in 0..<10 { _ = floor.record(Double(i) * Self.interval, clockSeconds: nil) }
        floor.reset()
        #expect(floor.floor == -.infinity)
        #expect(floor.frontier == nil)
        #expect(!floor.record(0, clockSeconds: nil).belowFloor, "a seek back starts over")
    }
}

/// The renderer side: on the arrival-order path frames reach the layer the moment they arrive, in the
/// order they arrived, and nothing is held, dropped as out of order or counted below the floor.
@Suite("Arrival-order handover in the software renderer")
struct ArrivalOrderHandoverTests {

    private final class Handed: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        var seconds: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ t: SoftwareVideoFrameTime) { lock.lock(); storage.append(t.presentation.seconds); lock.unlock() }
    }

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb!
    }

    private static func time(_ index: Int) -> CMTime { CMTime(value: Int64(index) * 1000, timescale: 24000) }

    @Test("Decode-order frames are handed over immediately, in arrival order")
    @MainActor
    func handsOverImmediately() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(forHardwareDecoder: true))
        renderer.setArrivalOrderHandover(frameRate: 24)
        #expect(renderer.handsOverInArrivalOrder)
        let handed = Handed()
        renderer.setFrameEnqueuedObserver { handed.append($0) }
        let pixels = Self.makePixelBuffer()
        let order = PresentationFloorTests.decodeOrder(gop: 8, frames: 48)
        for (k, i) in order.enumerated() {
            renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i))
            #expect(handed.seconds.count == k + 1, "frame \(k) is not held")
        }
        #expect(renderer.heldFrameCount == 0)
        #expect(handed.seconds == order.map { Self.time($0).seconds })
        #expect(renderer.outOfOrderFramesDropped == 0)
        #expect(renderer.framesBelowFloor == 0)
        #expect(renderer.enqueueCount == order.count)
    }

    @Test("Spacing is measured in display order, so decode order does not read as a reordering fault")
    @MainActor
    func spacingInDisplayOrder() {
        let renderer = SampleBufferRenderer()
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        for i in PresentationFloorTests.decodeOrder(gop: 8, frames: 48) {
            renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i))
        }
        let cadence = renderer.takeCadence()
        let interval = 1 / 24.0
        #expect(abs((cadence.minDeltaSeconds ?? 0) - interval) < 1e-6)
        #expect(abs((cadence.maxDeltaSeconds ?? 0) - interval) < 1e-6)
    }

    @Test("A seek seeds the floor at the threshold, and frames below it are still skipped")
    @MainActor
    func seekSeedsTheFloor() {
        let renderer = SampleBufferRenderer()
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        for i in 0..<20 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        renderer.flush(removingDisplayedImage: false)
        renderer.setSkipThreshold(Self.time(100))
        let handed = Handed()
        renderer.setFrameEnqueuedObserver { handed.append($0) }
        for i in PresentationFloorTests.decodeOrder(gop: 8, frames: 48, startingAt: 96) {
            renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i))
        }
        #expect(handed.seconds.allSatisfy { $0 >= Self.time(100).seconds })
        #expect(handed.seconds.count == 44)
        #expect(renderer.framesBelowFloor == 0)
        // The anchor at 96 is refused by the seek threshold itself, and the three B-frames below the
        // target that follow the first frame past it by the floor; all four are counted, so every one
        // of the 48 frames fed in is either handed over or counted.
        #expect(renderer.arrivalSkippedFramesDropped == 4)
        #expect(renderer.arrivalSkippedFramesDropped + handed.seconds.count == 48)
        #expect(renderer.takeCadence().lostBeforeLayer == 0, "a seek's discard is a decision, not a loss")
    }

    @Test("The first skipped frame of each seek is logged once, not once per renderer")
    @MainActor
    func firstSkipLogsOncePerSeek() {
        let capture = EngineLogCapture()
        defer { capture.end() }
        let renderer = SampleBufferRenderer()
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        // Targets no other test uses, matched on the threshold in the line itself: the capture sees
        // every test that logs at the same time.
        let first = 300   // 12.500 s
        let second = 400  // 16.667 s
        let firstLines = { capture.matching("threshold 12.500s") }
        let secondLines = { capture.matching("threshold 16.667s") }

        renderer.flush(removingDisplayedImage: false)
        renderer.setSkipThreshold(Self.time(first))
        for i in PresentationFloorTests.decodeOrder(gop: 8, frames: 16, startingAt: first - 4) {
            renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i))
        }
        #expect(firstLines().count == 1)

        // A seek sets the same threshold again after the landing: still one seek, still one line,
        // even though more frames below the target arrive.
        // (The first frame at or past the threshold clears the renderer's own refusal; the frames
        // below it that follow are the floor's, and are counted but not logged again.)
        renderer.setSkipThreshold(Self.time(first))
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(first))
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(first - 2))
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(first - 1))
        #expect(firstLines().count == 1, "the same target again is not a new seek")

        // A new target without a flush in between is a new seek: its first skipped frame is logged.
        renderer.setSkipThreshold(Self.time(second))
        #expect(secondLines().isEmpty)
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(second))
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(second - 2))
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(second - 1))
        #expect(secondLines().count == 1)
        #expect(firstLines().count == 1)
        #expect(renderer.arrivalSkippedFramesDropped >= 7, "the counter stays cumulative across seeks")
    }

    @Test("Without a frame rate the renderer keeps its reorder buffer")
    @MainActor
    func offWithoutARate() {
        let renderer = SampleBufferRenderer()
        renderer.setArrivalOrderHandover(frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: nil)
        #expect(!renderer.handsOverInArrivalOrder)
        renderer.setArrivalOrderHandover(frameRate: .nan)
        #expect(!renderer.handsOverInArrivalOrder)
        renderer.setArrivalOrderHandover(frameRate: 90_000)
        #expect(!renderer.handsOverInArrivalOrder, "a bogus rate is not a grid")
        renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(forHardwareDecoder: true))
        let pixels = Self.makePixelBuffer()
        for i in [0, 4, 2, 1, 3] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.heldFrameCount == 4, "the reorder buffer holds as before")
    }
}
