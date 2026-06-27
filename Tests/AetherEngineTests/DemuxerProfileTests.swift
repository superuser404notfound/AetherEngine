import Testing
@testable import AetherEngine

struct DemuxerProfileTests {
    @Test("playback profile keeps the large probe budget + prefetch")
    func playbackDefaults() {
        let p = DemuxerOpenProfile.playback
        #expect(p.probesize == 50 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 60 * 1_000_000)
        #expect(p.avioPrefetch == true)
        #expect(p.avioChunkSize == 4 * 1024 * 1024)
    }

    @Test("stillExtraction profile is random-access tuned")
    func stillExtractionTuned() {
        let p = DemuxerOpenProfile.stillExtraction
        #expect(p.avioPrefetch == false)
        #expect(p.avioChunkSize < DemuxerOpenProfile.playback.avioChunkSize)
        #expect(p.probesize < DemuxerOpenProfile.playback.probesize)
        #expect(p.maxAnalyzeDuration < DemuxerOpenProfile.playback.maxAnalyzeDuration)
    }

    /// Issue #27 (Sodalite): a stalled still-extraction chunk read could ride a
    /// ~35s syncRequest park times up to 3 retries times 2 URL passes, freezing the
    /// scrub-preview. The disposable thumbnail fetch must cap its per-chunk budget
    /// and retries far below the playback path.
    @Test("stillExtraction caps the per-chunk request budget below playback")
    func stillExtractionReadBudget() {
        let still = DemuxerOpenProfile.stillExtraction
        let playback = DemuxerOpenProfile.playback
        #expect(still.avioRequestTimeout < playback.avioRequestTimeout)
        #expect(still.avioMaxRetries < playback.avioMaxRetries)
        #expect(still.avioMaxRetries >= 1)
    }

    // MARK: - withProbeBudget (#68: caller-bounded probe budget)

    @Test("withProbeBudget(nil, nil) leaves every field untouched")
    func withProbeBudgetNilKeepsDefault() {
        let base = DemuxerOpenProfile.playback
        let p = base.withProbeBudget(probesize: nil, maxAnalyzeDuration: nil)
        #expect(p.probesize == base.probesize)
        #expect(p.maxAnalyzeDuration == base.maxAnalyzeDuration)
        #expect(p.avioPrefetch == base.avioPrefetch)
        #expect(p.avioChunkSize == base.avioChunkSize)
        #expect(p.avioRequestTimeout == base.avioRequestTimeout)
        #expect(p.avioMaxRetries == base.avioMaxRetries)
    }

    @Test("withProbeBudget overrides only probesize when maxAnalyzeDuration is nil")
    func withProbeBudgetProbesizeOnly() {
        let base = DemuxerOpenProfile.playback
        let p = base.withProbeBudget(probesize: 4 * 1024 * 1024, maxAnalyzeDuration: nil)
        #expect(p.probesize == 4 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == base.maxAnalyzeDuration)
    }

    @Test("withProbeBudget overrides only maxAnalyzeDuration when probesize is nil")
    func withProbeBudgetAnalyzeOnly() {
        let base = DemuxerOpenProfile.playback
        let p = base.withProbeBudget(probesize: nil, maxAnalyzeDuration: 5 * 1_000_000)
        #expect(p.probesize == base.probesize)
        #expect(p.maxAnalyzeDuration == 5 * 1_000_000)
    }

    @Test("withProbeBudget overrides both probe knobs but never disturbs AVIO tuning")
    func withProbeBudgetBothKeepsAVIO() {
        let base = DemuxerOpenProfile.playback
        let p = base.withProbeBudget(probesize: 1 * 1024 * 1024, maxAnalyzeDuration: 1 * 1_000_000)
        #expect(p.probesize == 1 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 1 * 1_000_000)
        // The two probe knobs are the ONLY thing a caller may tweak; the AVIO
        // tuning (prefetch / chunk size / read budget) must ride through unchanged.
        #expect(p.avioPrefetch == base.avioPrefetch)
        #expect(p.avioChunkSize == base.avioChunkSize)
        #expect(p.avioRequestTimeout == base.avioRequestTimeout)
        #expect(p.avioMaxRetries == base.avioMaxRetries)
    }

    @Test("withProbeBudget is receiver-agnostic and never promotes to playback AVIO")
    func withProbeBudgetReceiverAgnostic() {
        let still = DemuxerOpenProfile.stillExtraction
        let p = still.withProbeBudget(probesize: 9, maxAnalyzeDuration: nil)
        #expect(p.probesize == 9)
        // Applied to .stillExtraction it must keep stillExtraction's AVIO knobs,
        // not silently inherit the playback profile.
        #expect(p.avioPrefetch == false)
        #expect(p.avioChunkSize == still.avioChunkSize)
        #expect(p.avioMaxRetries == still.avioMaxRetries)
    }

    // MARK: - subtitleSideDemuxer (#76: bounded embedded-subtitle open)

    @Test("subtitleSideDemuxer caps the probe far below playback but keeps playback AVIO tuning")
    func subtitleSideDemuxerCapsProbe() {
        let playback = DemuxerOpenProfile.playback
        let p = DemuxerOpenProfile.subtitleSideDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil)
        // The whole point of #76: do not chase sparse PGS/DVB tracks to the 50 MB budget.
        #expect(p.probesize == 4 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 5 * 1_000_000)
        #expect(p.probesize < playback.probesize)
        #expect(p.maxAnalyzeDuration < playback.maxAnalyzeDuration)
        // The reader does sustained paced reads, so it must NOT inherit stillExtraction's
        // aggressive single-attempt / short-timeout AVIO tuning; it keeps playback's.
        #expect(p.avioPrefetch == playback.avioPrefetch)
        #expect(p.avioChunkSize == playback.avioChunkSize)
        #expect(p.avioRequestTimeout == playback.avioRequestTimeout)
        #expect(p.avioMaxRetries == playback.avioMaxRetries)
    }

    @Test("subtitleSideDemuxer honors an even tighter caller budget (#68)")
    func subtitleSideDemuxerTighterCallerWins() {
        let p = DemuxerOpenProfile.subtitleSideDemuxer(
            callerProbesize: 1 * 1024 * 1024, callerMaxAnalyzeDuration: 2 * 1_000_000)
        #expect(p.probesize == 1 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 2 * 1_000_000)
    }

    @Test("subtitleSideDemuxer never widens past its ceiling for a looser caller budget")
    func subtitleSideDemuxerLooserCallerIgnored() {
        let p = DemuxerOpenProfile.subtitleSideDemuxer(
            callerProbesize: 40 * 1024 * 1024, callerMaxAnalyzeDuration: 60 * 1_000_000)
        #expect(p.probesize == 4 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 5 * 1_000_000)
    }
}
