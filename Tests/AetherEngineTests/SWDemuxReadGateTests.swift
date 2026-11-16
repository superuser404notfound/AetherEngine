import Testing
@testable import AetherEngine

/// `SoftwarePlaybackHost.shouldHoldDemuxRead`: when the combined SW demux loop stops pulling
/// packets so the renderer can drain the parked video FIFO. The lead is the pacing rule and the
/// packet cap is only a memory backstop - pacing on the cap alone makes the effective audio lead
/// a function of frame rate (256 packets is ~10 s at 25 fps and ~5 s at 50 fps).
@Suite("SW demux read gate")
struct SWDemuxReadGateTests {

    private let cap = 256

    @Test("audio at its target lead holds the read")
    func holdsAtTargetLead() {
        let clock = 100.0
        let atTarget = clock + AudioLookaheadPolicy.targetLeadSeconds
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: atTarget, clockSeconds: clock) == true)
    }

    @Test("audio below its target lead keeps reading, however deep the FIFO is under the cap")
    func readsBelowTargetLead() {
        let clock = 100.0
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 200, parkedCap: cap, clockArmed: true,
            lastAudioPts: clock + 1.0, clockSeconds: clock) == false)
    }

    @Test("the packet cap holds the read on its own")
    func capIsTheBackstop() {
        let clock = 100.0
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: cap, parkedCap: cap, clockArmed: true,
            lastAudioPts: clock + 0.1, clockSeconds: clock) == true)
    }

    /// #337: before the clock is armed the lead is meaningless and the loop is the only reader.
    /// Holding here parks forever - the clock waits for an audio buffer that only a further read
    /// can produce. Only the cap may hold, and the parked-video arming exit runs at that point.
    @Test("an unarmed clock never holds on the lead, only on the cap")
    func unarmedClockKeepsReading() {
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 10, parkedCap: cap, clockArmed: false,
            lastAudioPts: 1_000, clockSeconds: 0) == false)
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: cap, parkedCap: cap, clockArmed: false,
            lastAudioPts: 1_000, clockSeconds: 0) == true)
    }

    @Test("no audio enqueued yet and an unreadable clock both keep reading")
    func nonFiniteInputsKeepReading() {
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: .nan, clockSeconds: 100) == false)
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 4, parkedCap: cap, clockArmed: true,
            lastAudioPts: 104, clockSeconds: .nan) == false)
    }

    // MARK: - Source interleave (AE#1079)

    /// The DASH virtual MP4 interleaves whole subsegments by start time, so audio can sit a whole
    /// audio subsegment ahead of the next video in read order, and video a whole video subsegment
    /// ahead of the next audio. A 4 s lead or a 256-packet cap below that geometry froze the picture
    /// (10 s audio, 4 s video) or stalled the clock (10 s video, 2 s audio) every subsegment.
    @Test("an ordinary source keeps the 4 s lead and the 256-packet cap")
    func ordinarySourceBudget() {
        let budget = SoftwareReadGateBudget(audioReadLeadSeconds: 0, videoSubsegmentSeconds: 0, frameRate: 24)
        #expect(budget.audioLeadSeconds == AudioLookaheadPolicy.targetLeadSeconds)
        #expect(budget.parkedVideoCap == 256)
    }

    @Test("audio laid out ahead of video raises the lead by that interleave")
    func audioAheadRaisesTheLead() {
        let budget = SoftwareReadGateBudget(audioReadLeadSeconds: 10, videoSubsegmentSeconds: 4, frameRate: 60)
        #expect(budget.audioLeadSeconds == AudioLookaheadPolicy.targetLeadSeconds + 10)
        // The issue's state: empty FIFO, audio 10 s over the clock. It must keep reading now.
        #expect(!SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 0, parkedCap: budget.parkedVideoCap, clockArmed: true,
            lastAudioPts: 110, clockSeconds: 100, targetLeadSeconds: budget.audioLeadSeconds))
        #expect(SoftwarePlaybackHost.shouldHoldDemuxRead(
            parkedCount: 0, parkedCap: budget.parkedVideoCap, clockArmed: true,
            lastAudioPts: 114, clockSeconds: 100, targetLeadSeconds: budget.audioLeadSeconds))
    }

    @Test("a long video subsegment raises the cap so the whole subsegment parks before the next audio")
    func longVideoSubsegmentRaisesTheCap() {
        let budget = SoftwareReadGateBudget(audioReadLeadSeconds: 2, videoSubsegmentSeconds: 10, frameRate: 60)
        // 10 s of 60 fps is 600 packets, more than 256 can hold.
        #expect(budget.parkedVideoCap >= 600 + 256)
        #expect(budget.audioLeadSeconds == AudioLookaheadPolicy.targetLeadSeconds + 2)
    }

    @Test("an unknown frame rate budgets for 60 fps, never for fewer packets")
    func unknownFrameRate() {
        let unknown = SoftwareReadGateBudget(audioReadLeadSeconds: 0, videoSubsegmentSeconds: 10, frameRate: nil)
        let sixty = SoftwareReadGateBudget(audioReadLeadSeconds: 0, videoSubsegmentSeconds: 10, frameRate: 60)
        #expect(unknown.parkedVideoCap == sixty.parkedVideoCap)
        #expect(SoftwareReadGateBudget(audioReadLeadSeconds: 0, videoSubsegmentSeconds: 10, frameRate: .nan)
            .parkedVideoCap == sixty.parkedVideoCap)
    }

    @Test("an absurd interleave is clamped, so a broken sidx cannot buy unbounded memory")
    func interleaveIsClamped() {
        let ceiling = SoftwareReadGateBudget.interleaveCeilingSeconds
        let huge = SoftwareReadGateBudget(audioReadLeadSeconds: 600, videoSubsegmentSeconds: 600, frameRate: 60)
        let atCeiling = SoftwareReadGateBudget(audioReadLeadSeconds: ceiling, videoSubsegmentSeconds: ceiling, frameRate: 60)
        #expect(huge == atCeiling)
        #expect(SoftwareReadGateBudget(audioReadLeadSeconds: -3, videoSubsegmentSeconds: .nan, frameRate: 60)
            == SoftwareReadGateBudget(audioReadLeadSeconds: 0, videoSubsegmentSeconds: 0, frameRate: 60))
    }

    @Test("the parked wait measures the gate against the raised lead")
    func waitUsesTheRaisedLead() {
        #expect(abs(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 114.012, clockSeconds: 100, rate: 1, targetLeadSeconds: 14) - 0.012) < 1e-9)
    }

    // MARK: - Parked wait (audit PERF-110)

    @Test("a lead just over the target wakes when the gate opens, not before the floor")
    func waitFollowsTheGateOpening() {
        let clock = 100.0
        let target = AudioLookaheadPolicy.targetLeadSeconds
        #expect(abs(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: clock + target + 0.012, clockSeconds: clock, rate: 1) - 0.012) < 1e-9)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: clock + target + 0.001, clockSeconds: clock, rate: 1) == 0.005)
    }

    @Test("a lead far over the target is capped at 20 ms so parked video keeps reaching the decoder")
    func waitIsCapped() {
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 110, clockSeconds: 100, rate: 1) == 0.020)
    }

    @Test("a gate that is already open, an unarmed clock and unreadable inputs poll at the 5 ms floor")
    func waitFloor() {
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 101, clockSeconds: 100, rate: 1) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: false, lastAudioPts: 110, clockSeconds: 100, rate: 1) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: .nan, clockSeconds: 100, rate: 1) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 110, clockSeconds: .nan, rate: 1) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 110, clockSeconds: 100, rate: 0) == 0.005)
        #expect(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: .infinity, clockSeconds: 100, rate: 1) == 0.005)
    }

    @Test("the rate shortens the wait the same way it shortens the time to the gate")
    func waitScalesWithRate() {
        let target = AudioLookaheadPolicy.targetLeadSeconds
        let excess = 0.016
        #expect(abs(SoftwarePlaybackHost.parkedRendererWaitSeconds(
            clockArmed: true, lastAudioPts: 100 + target + excess, clockSeconds: 100, rate: 2) - 0.008) < 1e-9)
    }

    @Test("whatever the inputs, the wait stays between 5 and 20 ms")
    func waitIsAlwaysBounded() {
        for lead in stride(from: -2.0, through: 12.0, by: 0.37) {
            for rate: Float in [0.25, 0.5, 1, 1.5, 2, 4, 8] {
                let w = SoftwarePlaybackHost.parkedRendererWaitSeconds(
                    clockArmed: true, lastAudioPts: 100 + lead, clockSeconds: 100, rate: rate)
                #expect(w >= 0.005 && w <= 0.020)
            }
        }
    }
}
