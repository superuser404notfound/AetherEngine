import AVFoundation
import Combine
import Testing
@testable import AetherEngine

@Suite("SampleBufferRenderer FEL look-ahead")
struct SampleBufferRendererLookaheadTests {
    @Test("FEL admits the capped number of frame intervals, parks the next, and resumes as the clock advances",
          arguments: [24.0, 24000.0 / 1001.0, 30.0, 60.0])
    func frameCap(rate: Double) {
        let n = Double(SampleBufferRenderer.felVideoLookaheadFrames)
        #expect(SampleBufferRenderer.felVideoLookaheadFrames == 9)
        #expect(mayEnqueue(rate: rate, pts: n / rate, clock: 0))
        #expect(!mayEnqueue(rate: rate, pts: (n + 1) / rate, clock: 0))
        #expect(mayEnqueue(rate: rate, pts: (n + 1) / rate, clock: 2 / rate))
        #expect(mayEnqueue(rate: rate, pts: 9, clock: 10))
    }

    @Test("Non-FEL pacing depends only on queue readiness")
    func nonFEL() {
        #expect(mayEnqueue(rate: nil, pts: 100, clock: 0))
        #expect(!mayEnqueue(rate: nil, pts: 0, clock: 0, ready: false))
    }

    @Test("FEL still respects Apple's queue readiness")
    func queueFull() {
        #expect(!mayEnqueue(rate: 24, pts: 0, clock: 0, ready: false))
        #expect(!mayEnqueue(rate: 24, pts: 0, clock: 0, ready: false, armed: false))
    }

    @Test("Startup and unavailable timing do not prevent clock arming")
    func startup() {
        #expect(mayEnqueue(rate: 24, pts: 100, clock: 0, armed: false))
        #expect(mayEnqueue(rate: 24, pts: 100, clock: .nan))
        #expect(mayEnqueue(rate: 24, pts: .nan, clock: 0))
    }

    @Test("Lead uses the source axis, including after a backward seek")
    func sourceAxis() {
        #expect(mayEnqueue(rate: 24, pts: 100.3, clock: 100))   // 9 frames = 0.375 s
        #expect(!mayEnqueue(rate: 24, pts: 100.4, clock: 100))
        #expect(mayEnqueue(rate: 24, pts: 10.3, clock: 10))
        #expect(!mayEnqueue(rate: 24, pts: 10.4, clock: 10))
    }

    @Test("Enabling FEL applies the cap and disabling it restores queue-only pacing")
    @MainActor func configuration() throws {
        let renderer = SampleBufferRenderer()
        // The negative checks below only mean something while Apple's readiness gate is open.
        try #require(renderer.isReadyForMoreMediaData)
        renderer.setFELLookahead(enabled: true, frameRate: 60)
        #expect(!renderer.mayEnqueueVideoFrame(ptsSeconds: 0.2, clockSeconds: 0, clockArmed: true))   // 9 frames at 60 fps = 0.15 s
        renderer.setFELLookahead(enabled: false, frameRate: 60)
        #expect(renderer.mayEnqueueVideoFrame(ptsSeconds: 100, clockSeconds: 0, clockArmed: true)
                == renderer.isReadyForMoreMediaData)
        renderer.setFELLookahead(enabled: true, frameRate: nil)
        #expect(renderer.mayEnqueueVideoFrame(ptsSeconds: 0.37, clockSeconds: 0, clockArmed: true)
                == renderer.isReadyForMoreMediaData)   // nil rate falls back to 24 fps: 0.375 s
        #expect(!renderer.mayEnqueueVideoFrame(ptsSeconds: 0.4, clockSeconds: 0, clockArmed: true))
    }

    @Test("Decode-order packet PTS is corrected by the measured reorder lead")
    func displayOrder() {
        // I P B B: PTS 0, 4, 2, 1 (in frames) arriving in decode order, 3-deep lead.
        var maxSeen: Double? = nil
        var lead = 0.0
        var out: [Double] = []
        for pts in [0.0, 4, 2, 1, 8, 6, 5] {
            let d = SampleBufferRenderer.displayOrderPTS(packetPTS: pts, maxSeenPTS: maxSeen, reorderLead: lead)
            maxSeen = d.maxSeen; lead = d.lead; out.append(d.pts)
        }
        #expect(lead == 3)
        // Once the lead is known, the reference packet (PTS 8) is gated as the frame 5 ahead it must wait behind.
        #expect(out[4] == 5)
        // Monotonic streams are untouched.
        let m = SampleBufferRenderer.displayOrderPTS(packetPTS: 3, maxSeenPTS: 2, reorderLead: 0)
        #expect(m.pts == 3 && m.lead == 0)
    }

    @Test("A glitch inside the reorder window cannot grow the learned lead past the reorder depth")
    func glitchLeadIsBounded() {
        let frame = 1.0 / 24
        let bound = SampleBufferRenderer.maxLearnedReorderFrames * frame
        let maxLead = SampleBufferRenderer.maxReorderPictures * frame
        // One packet 12 frames below the highest PTS: inside the 16-picture window, so not a discontinuity.
        let d = SampleBufferRenderer.displayOrderPTS(packetPTS: 100 - 12 * frame, maxSeenPTS: 100, reorderLead: 0,
                                                     maxLead: maxLead, maxLearnedLead: bound)
        #expect(abs(d.lead - bound) < 1e-9)
        // The gated PTS is therefore at most `bound` below the packet's own: the admitted look-ahead
        // grows by at most 8 frames, not 12 (at the 24 fps used here).
        #expect(abs(d.pts - (100 - 12 * frame - bound)) < 1e-9)
        // And a later, ordinary packet does not raise it further.
        let n = SampleBufferRenderer.displayOrderPTS(packetPTS: 100.5, maxSeenPTS: d.maxSeen, reorderLead: d.lead,
                                                     maxLead: maxLead, maxLearnedLead: bound)
        #expect(abs(n.lead - bound) < 1e-9)
    }

    @Test("The gate itself stays bounded after a 12-frame backward glitch")
    @MainActor func gateGlitchIsBounded() throws {
        let renderer = SampleBufferRenderer()
        try #require(renderer.isReadyForMoreMediaData)
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        let frame = 1.0 / 24
        #expect(renderer.mayEnqueueVideoFrame(ptsSeconds: 100, clockSeconds: 100, clockArmed: true))
        #expect(renderer.mayEnqueueVideoFrame(ptsSeconds: 100 - 12 * frame, clockSeconds: 100, clockArmed: true))
        // The glitch teaches 8 frames (the bound, not 12): 9 + 8 = 17 frames ahead is admitted, 18 is not.
        #expect(renderer.mayEnqueueVideoFrame(ptsSeconds: 100 + 17 * frame, clockSeconds: 100, clockArmed: true))
        #expect(!renderer.mayEnqueueVideoFrame(ptsSeconds: 100 + 18 * frame, clockSeconds: 100, clockArmed: true))
    }

    /// Teaches the gate a 4-frame lead with the highest packet PTS at 100, then runs `interrupt`. If the
    /// lead or the highest PTS survived it, the first packet below 100 would be read as reordering and
    /// the 10-frame check would pass (stale lead 4 or 3: gated 6 or 7 frames ahead); with both forgotten
    /// it is the first packet of a new stream and a frame 10 ahead is refused.
    @MainActor private func expectGateForgotten(after interrupt: (SampleBufferRenderer) -> Void) throws {
        let renderer = SampleBufferRenderer()
        try #require(renderer.isReadyForMoreMediaData)
        let frame = 1.0 / 24
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        _ = renderer.mayEnqueueVideoFrame(ptsSeconds: 100, clockSeconds: 100, clockArmed: true)
        _ = renderer.mayEnqueueVideoFrame(ptsSeconds: 100 - 4 * frame, clockSeconds: 100, clockArmed: true)   // learns 4 frames
        interrupt(renderer)
        let clock = 100 - 3 * frame
        // 3 frames below the old highest PTS: a stale highest PTS would teach a lead of 3 here.
        #expect(renderer.mayEnqueueVideoFrame(ptsSeconds: clock, clockSeconds: clock, clockArmed: true))
        #expect(renderer.mayEnqueueVideoFrame(ptsSeconds: clock + 9 * frame, clockSeconds: clock, clockArmed: true))
        #expect(!renderer.mayEnqueueVideoFrame(ptsSeconds: clock + 10 * frame, clockSeconds: clock, clockArmed: true))
    }

    @Test("Disabling and re-enabling the look-ahead forgets the learned lead and highest PTS")
    @MainActor func disableResetsGateState() throws {
        try expectGateForgotten { renderer in
            renderer.setFELLookahead(enabled: false, frameRate: nil)
            renderer.setFELLookahead(enabled: true, frameRate: 24)
        }
    }

    @Test("A seek (flush) forgets the learned lead and highest PTS")
    @MainActor func flushResetsGateState() throws {
        try expectGateForgotten { renderer in renderer.flush(removingDisplayedImage: false) }
    }

    @Test("A hierarchical-B GOP of 8 learns a lead of exactly 7 frames, and a glitch is bounded at 8")
    func hierarchicalBLead() {
        let frame = 1.0 / 24
        let maxLead = SampleBufferRenderer.maxReorderPictures * frame
        let cap = SampleBufferRenderer.maxLearnedReorderFrames * frame
        // Decode order I0 P8 B4 B2 B1 B3 B6 B5 B7, repeated every 8 frames.
        var maxSeen: Double? = nil
        var lead = 0.0
        for gop in 0..<4 {
            for offset in [0, 8, 4, 2, 1, 3, 6, 5, 7] where gop == 0 || offset != 0 {
                let d = SampleBufferRenderer.displayOrderPTS(packetPTS: Double(gop * 8 + offset) * frame, maxSeenPTS: maxSeen,
                                                             reorderLead: lead, maxLead: maxLead, maxLearnedLead: cap)
                maxSeen = d.maxSeen; lead = d.lead
            }
        }
        #expect(abs(lead - 7 * frame) < 1e-9)
        // A 12-frame glitch inside the window is bounded at 8.
        let g = SampleBufferRenderer.displayOrderPTS(packetPTS: (maxSeen ?? 0) - 12 * frame, maxSeenPTS: maxSeen,
                                                     reorderLead: lead, maxLead: maxLead, maxLearnedLead: cap)
        #expect(abs(g.lead - 8 * frame) < 1e-9)
    }

    @Test("A backward timestamp jump is a discontinuity, not reorder lead")
    func discontinuityDoesNotGrowLead() {
        // 24 fps, B-frame lead of 3 frames already learned.
        let frame = 1.0 / 24
        var maxSeen: Double? = 100
        var lead = 3 * frame
        let maxLead = SampleBufferRenderer.maxReorderPictures * frame
        // A packet 10 s below the highest PTS seen.
        let d = SampleBufferRenderer.displayOrderPTS(packetPTS: 90, maxSeenPTS: maxSeen, reorderLead: lead, maxLead: maxLead)
        maxSeen = d.maxSeen; lead = d.lead
        #expect(lead == 3 * frame)
        #expect(maxSeen == 90)
        // The gate still refuses a frame a second ahead of the clock, which a lead of 10 s would not.
        let next = SampleBufferRenderer.displayOrderPTS(packetPTS: 90.5, maxSeenPTS: maxSeen, reorderLead: lead, maxLead: maxLead)
        #expect(!mayEnqueue(rate: 24, pts: next.pts, clock: 89))
        // Ordinary reordering inside the limit still teaches the lead.
        let r = SampleBufferRenderer.displayOrderPTS(packetPTS: 90.5 - 4 * frame, maxSeenPTS: next.maxSeen, reorderLead: lead, maxLead: maxLead)
        #expect(abs(r.lead - 4 * frame) < 1e-9)
    }

    @Test("A frame 100 s ahead of the clock is held until the clock reaches it")
    func forwardJumpIsHeld() {
        let frame = 1.0 / 24
        let maxLead = SampleBufferRenderer.maxReorderPictures * frame
        let lead = 3 * frame
        // 100 s on from the highest PTS seen: the lead is kept and the gate refuses the frame.
        let d = SampleBufferRenderer.displayOrderPTS(packetPTS: 200, maxSeenPTS: 100, reorderLead: lead, maxLead: maxLead)
        #expect(d.maxSeen == 200)
        #expect(d.lead == lead)
        #expect(!mayEnqueue(rate: 24, pts: d.pts, clock: 100))
        #expect(mayEnqueue(rate: 24, pts: d.pts, clock: 200))
    }

    #if DualLayerDolbyVision
    @Test("The pool threshold follows the look-ahead cap")
    func poolFollowsCap() {
        #expect(DoviFelComposer.outputPoolAllocationThreshold == SampleBufferRenderer.felVideoLookaheadFrames + 2 + DoviFelComposer.maxFramesInFlight + 1)
    }
    #endif

    private func mayEnqueue(rate: Double?, pts: Double, clock: Double,
                            ready: Bool = true, armed: Bool = true) -> Bool {
        SampleBufferRenderer.mayEnqueueAnotherFrame(
            rendererReady: ready, felFrameRate: rate, framePTS: pts,
            clockSeconds: clock, clockArmed: armed)
    }
    @MainActor
    @Test("resume flushes a failed queue before publishing play")
    func failedQueueRecoversBeforePlay() {
        var events: [String] = []
        let renderer = SampleBufferRenderer(resumeQueue: .init(
            status: { .failed }, flush: { events.append("flush") }))
        let host = SoftwarePlaybackHost(renderer: renderer)
        let observation = host.$rate.dropFirst().sink { rate in
            if rate > 0 { events.append("play") }
        }
        host.play()
        #expect(events == ["flush", "play"])
        #expect(host.isPlaying)
        observation.cancel()
        host.stop()
    }

    @MainActor
    @Test("resume preserves a healthy full queue's frames", arguments: [AVQueuedSampleBufferRenderingStatus.unknown, .rendering])
    func healthyQueueIsNotFlushed(status: AVQueuedSampleBufferRenderingStatus) {
        var flushes = 0
        let renderer = SampleBufferRenderer(resumeQueue: .init(
            status: { status }, flush: { flushes += 1 }))
        renderer.recoverAfterSuspensionIfNeeded()
        #expect(flushes == 0)
    }

}
