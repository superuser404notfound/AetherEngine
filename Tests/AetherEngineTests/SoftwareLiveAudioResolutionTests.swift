import Testing
import Libavcodec
@testable import AetherEngine

/// #133 follow-up: interlaced live H.264 now routes to the SoftwarePlaybackHost (#150), exposing that
/// the SW path resolved its audio stream purely through `av_find_best_stream`, which returns -1 for a
/// live-MPEG-TS AAC stream whose codecpar the probe left empty (sample_rate/channels=0). The native
/// path (HLSVideoEngine) already falls back to the first audio-type stream and repairs the codecpar;
/// these cover the SW host's mirror of that decision in isolation.
@Suite("SoftwarePlaybackHost live audio resolution")
struct SoftwareLiveAudioResolutionTests {

    // MARK: - Stream index fallback

    @Test("explicit override wins over both best-stream and by-type")
    func explicitOverrideWins() {
        #expect(SoftwarePlaybackHost.resolveAudioStreamIndex(
            explicit: 3, bestStream: 1, firstByType: 2, isLive: true) == 3)
    }

    @Test("best stream is used when no explicit override")
    func bestStreamUsed() {
        #expect(SoftwarePlaybackHost.resolveAudioStreamIndex(
            explicit: nil, bestStream: 1, firstByType: 2, isLive: true) == 1)
    }

    @Test("live source with empty-codecpar best stream falls back to first audio-type stream")
    func liveFallsBackToByType() {
        #expect(SoftwarePlaybackHost.resolveAudioStreamIndex(
            explicit: nil, bestStream: -1, firstByType: 2, isLive: true) == 2)
    }

    @Test("VOD does not fall back to by-type (keeps av_find_best_stream semantics)")
    func vodDoesNotFallBack() {
        #expect(SoftwarePlaybackHost.resolveAudioStreamIndex(
            explicit: nil, bestStream: -1, firstByType: 2, isLive: false) == -1)
    }

    @Test("no audio stream available resolves to -1")
    func noAudioResolvesToMinusOne() {
        #expect(SoftwarePlaybackHost.resolveAudioStreamIndex(
            explicit: nil, bestStream: -1, firstByType: -1, isLive: true) == -1)
    }

    @Test("a negative explicit index is treated as no override")
    func negativeExplicitIgnored() {
        #expect(SoftwarePlaybackHost.resolveAudioStreamIndex(
            explicit: -1, bestStream: 1, firstByType: 2, isLive: true) == 1)
    }

    // MARK: - AAC codecpar repair trigger

    @Test("live AAC with sample_rate=0 triggers codecpar repair")
    func liveAACZeroRateRepairs() {
        #expect(SoftwarePlaybackHost.shouldRepairLiveAACCodecpar(
            isLive: true, codecID: AV_CODEC_ID_AAC, sampleRate: 0) == true)
    }

    @Test("live AAC with a real sample_rate is left alone")
    func liveAACFilledRateNoRepair() {
        #expect(SoftwarePlaybackHost.shouldRepairLiveAACCodecpar(
            isLive: true, codecID: AV_CODEC_ID_AAC, sampleRate: 48000) == false)
    }

    @Test("VOD AAC with sample_rate=0 is not repaired (VOD probes fully)")
    func vodAACNoRepair() {
        #expect(SoftwarePlaybackHost.shouldRepairLiveAACCodecpar(
            isLive: false, codecID: AV_CODEC_ID_AAC, sampleRate: 0) == false)
    }

    @Test("live non-AAC with sample_rate=0 is not repaired")
    func liveNonAACNoRepair() {
        #expect(SoftwarePlaybackHost.shouldRepairLiveAACCodecpar(
            isLive: true, codecID: AV_CODEC_ID_AC3, sampleRate: 0) == false)
    }
}
