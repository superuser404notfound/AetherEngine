import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import os
import Testing
@testable import AetherEngine

/// The software path's start: the clock waits at rate 0 until frames are in the layer, then starts a
/// fixed lead from now (`AudioOutput.videoPrerollSatisfied`, `prerollStartLead`,
/// `SampleBufferRenderer.prerollSatisfied(clock:live:)`). On an Apple TV 4K a clock started the moment
/// the first packet arrived dropped 3 to 7 frames at every start and seek; with both, none on FEL
/// (#774). Every other VOD route since #800.
@Suite("Video preroll before the clock starts")
struct VideoPrerollTests {

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb!
    }

    private static func time(_ index: Int) -> CMTime { CMTime(value: Int64(index) * 1000, timescale: 24000) }

    // MARK: - Renderer gate

    @Test("Off the FEL path the gate opens once frames reach videoPrerollSeconds past the clock")
    @MainActor
    func singleLayerGate() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.presentationOrderReorderDepth)
        let pixels = Self.makePixelBuffer()
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false, "nothing handed over yet")
        // One frame stays held for its duration, so 0 to 3 hands over 0 to 2.
        for i in 0...3 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false)
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(4))
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == true)
        #expect(renderer.prerollSatisfied(clock: Self.time(2).seconds, live: false) == false)
    }

    @Test("Off the FEL path a live stream does not preroll")
    @MainActor
    func singleLayerLiveHasNoGate() {
        let renderer = SampleBufferRenderer()
        #expect(renderer.prerollSatisfied(clock: 0, live: true) == nil)
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        #expect(renderer.prerollSatisfied(clock: 0, live: true) == false, "the FEL route still does")
    }

    @Test("A resume between keyframes counts from the target, not from the GOP decoded up to it")
    @MainActor
    func singleLayerGateAfterAResume() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.presentationOrderReorderDepth)
        let pixels = Self.makePixelBuffer()
        // #800: the keyframe sits 3 s before the target; everything up to it is decoded and skipped.
        let target = Self.time(2078).seconds
        renderer.setSkipThreshold(Self.time(2078))
        for i in 2000..<2078 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: target, live: false) == false)
        for i in 2078...2082 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: target, live: false) == true)
    }

    @Test("The gate opens once the contiguous frames reach the preroll past the clock")
    @MainActor
    func gateCountsContiguousFrames() {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false, "nothing handed over yet")
        // A frame past a gap does not count: 0, 1, 2 and then 6 leave the frontier at frame 2.
        for i in [0, 1, 2, 6] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false)
        // 0 to 3 is four frames, 0.1667 s: just short of the preroll.
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(3))
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == false)
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(4))
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == true)
        // The same frames are not enough for a clock further on.
        #expect(renderer.prerollSatisfied(clock: Self.time(4).seconds, live: false) == false)
    }

    @Test("After a seek the gate counts from the seek target, not from the frames before it")
    @MainActor
    func gateRestartsAtTheSeekTarget() {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        for i in 0..<20 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        renderer.flush(removingDisplayedImage: false)
        renderer.setSkipThreshold(Self.time(100))
        let target = Self.time(100).seconds
        #expect(renderer.prerollSatisfied(clock: target, live: false) == false)
        for i in 100..<105 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.prerollSatisfied(clock: target, live: false) == true)
    }

    @Test("After a seek to a target between two frames the gate still opens without a running clock",
          arguments: [0.1, 0.4, 0.6, 0.9])
    @MainActor
    func gateOpensAfterAnOffGridSeek(phase: Double) {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        let target = (100 + phase) / 24
        renderer.setSkipThreshold(CMTime(seconds: target, preferredTimescale: 90000))
        // Decode order from the GOP's anchor below the target, as the decoder delivers it after a seek.
        for i in PresentationFloorTests.decodeOrder(gop: 8, frames: 24, startingAt: 96) {
            renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i))
        }
        #expect(renderer.prerollSatisfied(clock: target, live: false) == true)
        #expect(renderer.framesBelowFloor == 0)
    }

    @Test("At 60 fps the preroll fits inside the look-ahead window")
    @MainActor
    func prerollFitsTheLookaheadAt60() {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 60)
        renderer.setArrivalOrderHandover(frameRate: 60)
        let pixels = Self.makePixelBuffer()
        // Everything the look-ahead admits with the clock held at 0.
        var admitted = 0
        while SampleBufferRenderer.mayEnqueueAnotherFrame(
            rendererReady: true, felFrameRate: 60, framePTS: Double(admitted) / 60,
            clockSeconds: 0, clockArmed: true) {
            renderer.enqueue(pixelBuffer: pixels, pts: CMTime(value: Int64(admitted), timescale: 60))
            admitted += 1
        }
        #expect(renderer.prerollSatisfied(clock: 0, live: false) == true, "\(admitted) frames admitted")
    }

    // MARK: - Clock

    /// A gate the test opens by hand.
    private final class Gate: Sendable {
        private let open = OSAllocatedUnfairLock(initialState: false)
        func set(_ value: Bool) { open.withLock { $0 = value } }
        var isOpen: Bool { open.withLock { $0 } }
    }

    @Test("Without a gate seekClock starts the clock at once", .timeLimit(.minutes(1)))
    func startsAtOnceWithoutAGate() {
        let output = AudioOutput()
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 1)
    }

    @Test("A closed gate holds the clock at rate 0 and the start follows when it opens",
          .timeLimit(.minutes(1)))
    func holdsUntilTheGateOpens() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 0)
        #expect(abs(output.synchronizer.currentTime().seconds - 5) < 0.001)
        let opened = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        gate.set(true)
        try await waitFor { output.synchronizer.rate == 1 }
        // The start was scheduled `prerollStartLead` after the gate opened, so however late this
        // runs, the clock has not run longer than the time since then minus the lead.
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let ran = max(0, now - opened - AudioOutput.prerollStartLead)
        #expect(output.synchronizer.currentTime().seconds <= 5 + ran + 0.02)
    }

    @Test("A rate set while the preroll waits is the rate it starts at", .timeLimit(.minutes(1)))
    func setRateDuringPrerollIsTheStartRate() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.setRate(1.5)
        #expect(output.synchronizer.rate == 0, "the rate does not start the clock early")
        gate.set(true)
        try await waitFor { output.synchronizer.rate == 1.5 }
    }

    @Test("A pause cancels the pending start", .timeLimit(.minutes(1)))
    func pauseCancelsThePreroll() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.pause()
        gate.set(true)
        let started = try await waitFor(upTo: .milliseconds(300)) { output.synchronizer.rate != 0 }
        #expect(!started)
    }

    @Test("A play after a seek landed while paused starts through the preroll", .timeLimit(.minutes(1)))
    func playAfterAPausedSeekPrerolls() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 0)
        #expect(!output.prerollPending, "a paused seek does not ask the gate")
        output.setRate(1)
        #expect(output.synchronizer.rate == 0, "nothing is queued yet")
        #expect(output.prerollPending, "the host must not read this clock as stalled")
        gate.set(true)
        try await waitFor { output.synchronizer.rate == 1 }
        #expect(!output.prerollPending)
    }

    @Test("A gate that never opens starts the clock after the timeout", .timeLimit(.minutes(1)))
    func timesOut() async throws {
        let output = AudioOutput()
        output.videoPrerollSatisfied = { _ in false }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 0)
        try await waitFor { output.synchronizer.rate == 1 }
    }

    // MARK: - Decoder progress (#800)

    @Test("A hold waits on while the decoder produces frames, up to the cap")
    func progressExtendsTheTimeout() {
        #expect(AudioOutput.prerollKeepsWaiting(waited: 1.9, sinceProgress: 1.9))
        #expect(!AudioOutput.prerollKeepsWaiting(waited: 2.0, sinceProgress: 2.0), "no progress: the plain timeout")
        #expect(AudioOutput.prerollKeepsWaiting(waited: 3.5, sinceProgress: 0.1), "4K AV1 still decoding up to the target")
        #expect(!AudioOutput.prerollKeepsWaiting(waited: 3.5, sinceProgress: 2.0), "the decoder stopped")
        #expect(!AudioOutput.prerollKeepsWaiting(waited: AudioOutput.prerollProgressCap, sinceProgress: 0))
    }

    /// A frame counter the test advances by hand.
    private final class Progress: Sendable {
        private let count = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        func tick() { count.withLock { $0 &+= 1 } }
        var value: UInt64 { count.withLock { $0 } }
    }

    /// Every hold transition `AudioOutput` reports.
    private final class Transitions: Sendable {
        private let list = OSAllocatedUnfairLock<[AudioOutput.PrerollTransition]>(initialState: [])
        func append(_ transition: AudioOutput.PrerollTransition) { list.withLock { $0.append(transition) } }
        var events: [ClockHoldEvent] { list.withLock { $0.map(\.event) } }
        var generations: [Int] { list.withLock { $0.map(\.generation) } }
    }

    @Test("A decoder still producing frames holds the clock past the plain timeout", .timeLimit(.minutes(1)))
    func decoderProgressHoldsPastTheTimeout() async throws {
        let output = AudioOutput()
        let progress = Progress()
        // Both run in the hold's own poll, off the cooperative pool: a loop of `Task.sleep` ticks
        // starved past `prerollTimeout` on CI's one-thread pool and read as a decoder that stopped.
        let opensAt = CACurrentMediaTime() + AudioOutput.prerollTimeout + 0.5
        output.videoPrerollSatisfied = { _ in CACurrentMediaTime() >= opensAt }
        output.videoPrerollProgress = { progress.tick(); return progress.value }
        let transitions = Transitions()
        output.onPrerollTransition = { transitions.append($0) }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        // The release is reported right after the start, so waiting on the rate can read between them.
        try await waitFor { transitions.events.count == 2 }
        #expect(output.synchronizer.rate == 1)
        guard case .released(.ready(let waited))? = transitions.events.last else {
            Issue.record("expected a ready release, got \(transitions.events)")
            return
        }
        #expect(waited > AudioOutput.prerollTimeout)
        #expect(transitions.events.first == .began)
    }

    @Test("A hold reports its start and a timed-out release", .timeLimit(.minutes(1)))
    func reportsATimedOutHold() async throws {
        let output = AudioOutput()
        let transitions = Transitions()
        output.videoPrerollSatisfied = { _ in false }
        output.onPrerollTransition = { transitions.append($0) }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(transitions.events == [.began])
        try await waitFor { transitions.events.count == 2 }
        #expect(output.synchronizer.rate == 1)
        guard transitions.events.count == 2, case .released(.timedOut)? = transitions.events.last else {
            Issue.record("expected began then timedOut, got \(transitions.events)")
            return
        }
    }

    @Test("A newer seek and a pause release a waiting hold as cancelled", .timeLimit(.minutes(1)))
    func cancelledHoldsAreReported() {
        let output = AudioOutput()
        let transitions = Transitions()
        output.videoPrerollSatisfied = { _ in false }
        output.onPrerollTransition = { transitions.append($0) }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.seekClock(to: CMTime(seconds: 9, preferredTimescale: 90000), rate: 1)
        output.pause()
        output.pause()
        #expect(transitions.events == [.began, .released(.cancelled), .began, .released(.cancelled)])
        let gens = transitions.generations
        #expect(gens.count == 4 && gens[0] == gens[1] && gens[2] == gens[3] && gens[2] > gens[0])
    }

    @Test("A start whose frames are already queued does not report a hold", .timeLimit(.minutes(1)))
    func readyStartIsNoHold() {
        let output = AudioOutput()
        let transitions = Transitions()
        output.videoPrerollSatisfied = { _ in true }
        output.onPrerollTransition = { transitions.append($0) }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.stop()
        #expect(transitions.events.isEmpty)
    }
}
