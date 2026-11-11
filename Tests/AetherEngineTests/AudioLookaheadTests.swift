import Testing
@testable import AetherEngine

@Suite("AudioLookaheadPolicy (#107 audio chopping: SW live feeder audio decoupled from video pace)")
struct AudioLookaheadPolicyTests {

    @Test("pre-arm feeds within the packet budget so the first buffers can arm the clock")
    func preArmFeedsWithinBudget() {
        let v = AudioLookaheadPolicy.decide(
            clockArmed: false, preArmPacketsFed: 0,
            lastFedAudioPTS: .nan, clockSeconds: 0)
        #expect(v == .feed)
    }

    @Test("pre-arm stops at the packet budget (broken track never races through the ring)")
    func preArmStopsAtBudget() {
        let v = AudioLookaheadPolicy.decide(
            clockArmed: false, preArmPacketsFed: AudioLookaheadPolicy.preArmPacketBudget,
            lastFedAudioPTS: .nan, clockSeconds: 0)
        #expect(v == .stop)
    }

    @Test("armed with no fed PTS yet treats lead as zero and feeds")
    func armedNaNLeadFeeds() {
        let v = AudioLookaheadPolicy.decide(
            clockArmed: true, preArmPacketsFed: 0,
            lastFedAudioPTS: .nan, clockSeconds: 12000)
        #expect(v == .feed)
    }

    @Test("armed below target lead feeds")
    func belowTargetFeeds() {
        let v = AudioLookaheadPolicy.decide(
            clockArmed: true, preArmPacketsFed: 0,
            lastFedAudioPTS: 12001.0, clockSeconds: 12000)
        #expect(v == .feed)
    }

    @Test("armed at or above target lead stops")
    func atTargetStops() {
        let v = AudioLookaheadPolicy.decide(
            clockArmed: true, preArmPacketsFed: 0,
            lastFedAudioPTS: 12000 + AudioLookaheadPolicy.targetLeadSeconds, clockSeconds: 12000)
        #expect(v == .stop)
    }

    @Test("dry ring at the edge with collapsed lead pauses the clock to rebuffer")
    func underrunPausesClock() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: false, lastFedAudioPTS: 12000.1, clockSeconds: 12000,
            atRingEnd: true, sourceEnded: false)
        #expect(a == .pauseForRebuffer)
    }

    @Test("low lead with packets still in the ring is decode lag, not an underrun")
    func lowLeadNotAtEndDoesNothing() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: false, lastFedAudioPTS: 12000.1, clockSeconds: 12000,
            atRingEnd: false, sourceEnded: false)
        #expect(a == .none)
    }

    @Test("healthy lead at the edge does not touch the clock")
    func healthyLeadDoesNothing() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: false, lastFedAudioPTS: 12003.0, clockSeconds: 12000,
            atRingEnd: true, sourceEnded: false)
        #expect(a == .none)
    }

    @Test("rebuffering resumes once the lead recovers past the resume threshold")
    func rebufferResumesOnRecoveredLead() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: true,
            lastFedAudioPTS: 12000 + AudioLookaheadPolicy.rebufferResumeLeadSeconds, clockSeconds: 12000,
            atRingEnd: false, sourceEnded: false)
        #expect(a == .resume)
    }

    @Test("rebuffering holds while the lead is still below the resume threshold")
    func rebufferHoldsBelowThreshold() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: true, lastFedAudioPTS: 12001.0, clockSeconds: 12000,
            atRingEnd: true, sourceEnded: false)
        #expect(a == .none)
    }

    @Test("rebuffering resumes at source end so the queued tail drains")
    func rebufferResumesAtSourceEnd() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: true, lastFedAudioPTS: 12000.5, clockSeconds: 12000,
            atRingEnd: true, sourceEnded: true)
        #expect(a == .resume)
    }

    @Test("a dry edge at source end is EOF, not an underrun")
    func sourceEndNoPause() {
        let a = AudioLookaheadPolicy.clockAction(
            rebuffering: false, lastFedAudioPTS: 12000.05, clockSeconds: 12000,
            atRingEnd: true, sourceEnded: true)
        #expect(a == .none)
    }
}

@Suite("AudioLookaheadState (cursor + fed-PTS discipline shared with seek resets)")
struct AudioLookaheadStateTests {

    @Test("align raises the cursor to the combined cursor and clears the stale fed PTS")
    func alignRaisesAndClears() {
        let s = AudioLookaheadState()
        #expect(s.advance(from: 0, fedPTS: 100.0))
        #expect(s.align(to: 5) == 5)
        #expect(s.lastFedAudioPTS.isNaN)
    }

    @Test("align never lowers the cursor and keeps the fed PTS")
    func alignNeverLowers() {
        let s = AudioLookaheadState()
        _ = s.align(to: 5)
        #expect(s.advance(from: 5, fedPTS: 100.0))
        #expect(s.align(to: 2) == 6)
        #expect(s.lastFedAudioPTS == 100.0)
    }

    @Test("AE#1025: the pause arm stays shut at a realtime origin's start offset")
    func pauseArmShutAtStartOffset() {
        #expect(!AudioLookaheadPolicy.pauseArmOpens(wasOpen: false, lead: 0.1))
        #expect(!AudioLookaheadPolicy.pauseArmOpens(wasOpen: false, lead: -0.4))
    }

    @Test("AE#1025: a source that once built the resume lead opens the pause arm")
    func pauseArmOpensOnRealLead() {
        #expect(AudioLookaheadPolicy.pauseArmOpens(
            wasOpen: false, lead: AudioLookaheadPolicy.rebufferResumeLeadSeconds))
    }

    @Test("AE#1025: a source slower than real time from the first byte opens the pause arm")
    func pauseArmOpensOnStarvedLead() {
        // Measured: a 70 % origin peaked at 0.83 s of lead and then fell through -1 s at clk 5.7.
        #expect(AudioLookaheadPolicy.pauseArmOpens(
            wasOpen: false, lead: AudioLookaheadPolicy.starvedLeadSeconds))
        #expect(AudioLookaheadPolicy.pauseArmOpens(wasOpen: true, lead: 0.1))
    }

    @Test("advance is compare-and-set: a concurrent reset wins and the fed PTS is not committed")
    func advanceCASLosesToReset() {
        let s = AudioLookaheadState()
        _ = s.align(to: 3)
        s.reset(to: 10)  // concurrent DVR seek repositioned the cursors
        #expect(!s.advance(from: 3, fedPTS: 100.0))
        #expect(s.current == 10)
        #expect(s.lastFedAudioPTS.isNaN)
    }

    @Test("reset repositions the cursor and clears the fed PTS")
    func resetClears() {
        let s = AudioLookaheadState()
        #expect(s.advance(from: 0, fedPTS: 55.5))
        s.reset(to: 42)
        #expect(s.current == 42)
        #expect(s.lastFedAudioPTS.isNaN)
    }
}
