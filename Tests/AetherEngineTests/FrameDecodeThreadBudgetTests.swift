import Testing
@testable import AetherEngine

/// Issue #27 (Sodalite): FrameDecodeContext requested thread_count = activeProcessorCount,
/// so the disposable scrub-thumbnail decoder grabbed all 6 A12 cores at the same QoS as the
/// real-time software playback decode (and, with subs on, a third context), starving the
/// preview. The still-extraction thumbnail has no clock deadline, so its thread budget must be
/// capped well below the core count to leave headroom for playback.
struct FrameDecodeThreadBudgetTests {

    @Test("still-extraction thread count is capped below the core count")
    func capsThreads() {
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 8) <= 2)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 6) <= 2)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 6) < 6)
    }

    @Test("still-extraction thread count stays at least 1 on constrained hosts")
    func atLeastOne() {
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 1) >= 1)
        #expect(FrameDecodeContext.stillExtractionThreadCount(activeProcessorCount: 0) >= 1)
    }

    // MARK: - Playback

    /// Every frame thread past the first holds a decoded frame back until more packets arrive.
    /// Uncapped, an 18-core Mac (Mac17,6) held 17 and delivered 23 of the 40 frames the #220
    /// fixture (`Issue220SoftwareDecoderDrainTests`) decodes; capped it holds 15 and delivers 25.
    @Test("playback decodes on one thread per core, at most libavcodec's 16",
          arguments: [(1, 1), (6, 6), (16, 16), (18, 16), (32, 16)])
    func playbackThreadCountStopsAt16(cores: Int, threads: Int) {
        #expect(SoftwareVideoDecoder.playbackThreadCount(activeProcessorCount: cores) == threads)
    }

    @Test("playback decodes on at least one thread when the core count reads 0")
    func playbackThreadCountAtLeastOne() {
        #expect(SoftwareVideoDecoder.playbackThreadCount(activeProcessorCount: 0) == 1)
    }
}
