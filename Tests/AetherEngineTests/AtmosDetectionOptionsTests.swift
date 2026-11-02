import Testing
import Foundation
@testable import AetherEngine

/// Pure unit tests for the bounded EAC3/JOC decode pass's control-flow logic (cap selection, track-target
/// resolution, and the authoritative-Atmos truth table). No real media / decoder needed: these exercise the
/// same seams `AetherEngine.detectAtmos` calls internally, per the "no redistributable Atmos fixture" note --
/// the actual decode plumbing is covered separately in `AtmosDetectionProbeIntegrationTests` against a
/// synthesized (non-Atmos) EAC3 fixture.
@Suite("AtmosDetectionOptions defaults + bounded decode cap selection")
struct AtmosDetectionOptionsTests {

    // MARK: - AtmosDetectionOptions defaults

    @Test("default options: no explicit track, generous-but-finite caps")
    func defaultOptions() {
        let options = AtmosDetectionOptions()
        #expect(options.targetTrackID == nil)
        #expect(options.maxPackets == 64)
        #expect(options.maxBytes == 8 * 1024 * 1024)
        #expect(options.timeBudget == 2.0)
    }

    @Test("options are independently overridable")
    func customOptions() {
        let options = AtmosDetectionOptions(targetTrackID: 3, maxPackets: 10, maxBytes: 1024, timeBudget: 0.5)
        #expect(options.targetTrackID == 3)
        #expect(options.maxPackets == 10)
        #expect(options.maxBytes == 1024)
        #expect(options.timeBudget == 0.5)
    }

    // MARK: - atmosDecodeTargetIndex (explicit override vs demuxer default)

    @Test("nil targetTrackID resolves the demuxer's own default audio stream")
    func targetIndexDefaultsToDemuxerPick() {
        let options = AtmosDetectionOptions()
        let resolved = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: 2)
        #expect(resolved == 2)
    }

    @Test("an explicit targetTrackID always wins over the demuxer default")
    func explicitTargetWinsOverDefault() {
        let options = AtmosDetectionOptions(targetTrackID: 5)
        let resolved = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: 2)
        #expect(resolved == 5)
    }

    @Test("an explicit targetTrackID of 0 still wins (not confused with the nil/default case)")
    func explicitZeroTargetWins() {
        let options = AtmosDetectionOptions(targetTrackID: 0)
        let resolved = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: 4)
        #expect(resolved == 0)
    }

    @Test("a targetTrackID outside Int32 folds to -1 instead of trapping")
    func outOfInt32RangeTargetFoldsToNoTrack() {
        for id in [Int(Int32.max) + 1, Int(Int32.min) - 1, Int.max, Int.min] {
            let resolved = AetherEngine.atmosDecodeTargetIndex(
                options: AtmosDetectionOptions(targetTrackID: id), defaultAudioStreamIndex: 2)
            #expect(resolved == -1, "\(id) must degrade to the no-track sentinel")
        }
    }

    // MARK: - atmosForeignPacketFuse (AVDISCARD_ALL escape hatch, overflow-safe)

    @Test("the foreign-packet fuse is a plain multiple of maxPackets in the ordinary range")
    func foreignPacketFuseIsMultiple() {
        #expect(AetherEngine.atmosForeignPacketFuse(maxPackets: 64) == 64 * 8)
        #expect(AetherEngine.atmosForeignPacketFuse(maxPackets: 0) == 0)
    }

    @Test("the foreign-packet fuse saturates instead of trapping on Int.max")
    func foreignPacketFuseSaturates() {
        #expect(AetherEngine.atmosForeignPacketFuse(maxPackets: Int.max) == Int.max)
    }

    @Test("the input byte budget covers interleaved UHD video and saturates instead of trapping")
    func inputByteBudgetIsBoundedAndSaturates() {
        #expect(AetherEngine.atmosInputByteBudget(maxBytes: 8 * 1024 * 1024) == 128 * 1024 * 1024)
        #expect(AetherEngine.atmosInputByteBudget(maxBytes: 0) == 64 * 1024 * 1024)
        #expect(AetherEngine.atmosInputByteBudget(maxBytes: -1) == 64 * 1024 * 1024)
        #expect(AetherEngine.atmosInputByteBudget(maxBytes: .max) == .max)
    }

    @Test("no default audio stream (-1) surfaces unchanged when no override is given")
    func noAudioStreamPropagatesAsNegativeOne() {
        let options = AtmosDetectionOptions()
        let resolved = AetherEngine.atmosDecodeTargetIndex(options: options, defaultAudioStreamIndex: -1)
        #expect(resolved == -1)
    }

    // MARK: - atmosDecodeCapReached (packet / byte / time cap priority)

    @Test("no cap reached while within every budget")
    func noCapWithinBudget() {
        let options = AtmosDetectionOptions(maxPackets: 64, maxBytes: 1_000_000, timeBudget: 2.0)
        let cap = AetherEngine.atmosDecodeCapReached(packetsRead: 5, bytesRead: 1000, elapsed: 0.1, options: options)
        #expect(cap == nil)
    }

    @Test("packet cap fires at the exact threshold, checked first")
    func packetCapFiresAtThreshold() {
        let options = AtmosDetectionOptions(maxPackets: 10, maxBytes: 1_000_000, timeBudget: 100)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 9, bytesRead: 0, elapsed: 0, options: options) == nil)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 10, bytesRead: 0, elapsed: 0, options: options) == .packetCap)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 11, bytesRead: 0, elapsed: 0, options: options) == .packetCap)
    }

    @Test("byte cap fires at the exact threshold when packets are still under budget")
    func byteCapFiresAtThreshold() {
        let options = AtmosDetectionOptions(maxPackets: 1000, maxBytes: 4096, timeBudget: 100)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 4095, elapsed: 0, options: options) == nil)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 4096, elapsed: 0, options: options) == .byteCap)
    }

    @Test("time cap fires at the exact threshold when packets and bytes are still under budget")
    func timeCapFiresAtThreshold() {
        let options = AtmosDetectionOptions(maxPackets: 1000, maxBytes: 1_000_000, timeBudget: 1.5)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 0, elapsed: 1.49, options: options) == nil)
        #expect(AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 0, elapsed: 1.5, options: options) == .timeCap)
    }

    @Test("packet cap takes priority over byte and time caps when several are simultaneously exceeded")
    func packetCapHasPriority() {
        let options = AtmosDetectionOptions(maxPackets: 5, maxBytes: 10, timeBudget: 0.01)
        let cap = AetherEngine.atmosDecodeCapReached(packetsRead: 5, bytesRead: 100, elapsed: 10, options: options)
        #expect(cap == .packetCap)
    }

    @Test("byte cap takes priority over time cap when both are exceeded but packets are not")
    func byteCapHasPriorityOverTime() {
        let options = AtmosDetectionOptions(maxPackets: 1000, maxBytes: 10, timeBudget: 0.01)
        let cap = AetherEngine.atmosDecodeCapReached(packetsRead: 1, bytesRead: 100, elapsed: 10, options: options)
        #expect(cap == .byteCap)
    }

    // MARK: - AtmosDetectionOutcome.confirmedAtmos truth table

    @Test("confirmedAtmos is true only for a decoded frame with profile 30")
    func confirmedAtmosTrueOnJOCProfile() {
        let outcome = AtmosDetectionOutcome(stopReason: .frameDecoded, packetsRead: 3, bytesRead: 900, decodedProfile: 30)
        #expect(outcome.confirmedAtmos == true)
    }

    @Test("a decoded frame with a non-30 profile (plain EAC3) is never Atmos")
    func confirmedAtmosFalseOnPlainEAC3Profile() {
        // -99 == AV_PROFILE_UNKNOWN; a real plain-EAC3 decode reports this or another non-JOC value.
        let outcome = AtmosDetectionOutcome(stopReason: .frameDecoded, packetsRead: 2, bytesRead: 400, decodedProfile: -99)
        #expect(outcome.confirmedAtmos == false)
    }

    @Test("hitting any cap without a decoded frame is never Atmos, regardless of decodedProfile")
    func confirmedAtmosFalseWhenCapReachedBeforeDecode() {
        for reason: AtmosDetectionOutcome.StopReason in [.packetCap, .byteCap, .timeCap, .demuxEOF, .demuxError] {
            let outcome = AtmosDetectionOutcome(stopReason: reason, packetsRead: 64, bytesRead: 8_000_000, decodedProfile: nil)
            #expect(outcome.confirmedAtmos == false, "\(reason) must never confirm Atmos")
        }
    }

    @Test("a non-EAC3 / no-audio / decoder-open-failure source is never Atmos")
    func confirmedAtmosFalseForSkippedOrFailedSources() {
        for reason: AtmosDetectionOutcome.StopReason in [.noAudioTrack, .notEAC3, .decoderOpenFailed] {
            let outcome = AtmosDetectionOutcome(stopReason: reason, packetsRead: 0, bytesRead: 0, decodedProfile: nil)
            #expect(outcome.confirmedAtmos == false, "\(reason) must never confirm Atmos")
        }
    }

    @Test("eac3JOCProfile mirrors FFmpeg's AV_PROFILE_EAC3_DDP_ATMOS (30)")
    func jocProfileConstant() {
        #expect(AtmosDetectionOutcome.eac3JOCProfile == 30)
    }

    // MARK: - enrichAtmos: the feature's actual output path
    //
    // enrichAtmos hand-copies all 13 TrackInfo fields and all 14 SourceProbe fields, so a dropped field
    // compiles fine and silently ships. These pin the positive path the integration tests can't reach
    // without a redistributable Atmos fixture.

    private func makeTrack(
        id: Int, isAtmos: Bool = false, assHeader: String? = nil, name: String = "Surround"
    ) -> TrackInfo {
        TrackInfo(
            id: id, name: name, codec: "eac3", language: "eng", channels: 6, bitrate: 768_000,
            isDefault: true, isForced: false, isHearingImpaired: false, isCommentary: false,
            isVisualImpaired: true, isAtmos: isAtmos, assHeader: assHeader, isExternal: false
        )
    }

    private func makeProbe(audioTracks: [TrackInfo]) -> SourceProbe {
        SourceProbe(
            url: URL(string: "file:///tmp/movie.mkv")!, durationSeconds: 7261.5,
            videoFormat: .dolbyVision, videoCodecID: 173, videoCodecName: "hevc",
            videoWidth: 3840, videoHeight: 2160, videoFrameRate: 23.976,
            isDolbyVision: true, dvProfile: 7,
            audioTracks: audioTracks,
            subtitleTracks: [makeTrack(id: 9, name: "English SDH")],
            metadata: MediaMetadata(title: "T", artist: "A", album: "Al", artworkData: Data([0x1])),
            isLive: false
        )
    }

    @Test("enrichAtmos flips only the confirmed track and leaves its siblings alone")
    func enrichFlipsOnlyConfirmedTrack() {
        let probe = makeProbe(audioTracks: [makeTrack(id: 1), makeTrack(id: 2), makeTrack(id: 3)])
        let out = AetherEngine.enrichAtmos(base: probe, confirmedTrackID: 2)
        #expect(out.audioTracks.map(\.isAtmos) == [false, true, false])
    }

    @Test("enrichAtmos never overwrites a track the base probe already marked Atmos")
    func enrichIsAdditiveOnly() {
        let probe = makeProbe(audioTracks: [makeTrack(id: 1, isAtmos: true)])
        let out = AetherEngine.enrichAtmos(base: probe, confirmedTrackID: 1)
        #expect(out.audioTracks[0].isAtmos)
    }

    @Test("enrichAtmos with an id matching no track is a no-op")
    func enrichNoMatchingTrack() {
        let probe = makeProbe(audioTracks: [makeTrack(id: 1), makeTrack(id: 2)])
        let out = AetherEngine.enrichAtmos(base: probe, confirmedTrackID: 99)
        #expect(out.audioTracks.allSatisfy { !$0.isAtmos })
    }

    @Test("enrichAtmos round-trips every other SourceProbe and TrackInfo field unchanged")
    func enrichPreservesAllOtherFields() {
        let probe = makeProbe(audioTracks: [makeTrack(id: 1, assHeader: "[Script Info]")])
        let out = AetherEngine.enrichAtmos(base: probe, confirmedTrackID: 1)

        // SourceProbe fields.
        #expect(out.url == probe.url)
        #expect(out.durationSeconds == probe.durationSeconds)
        #expect(out.videoFormat == probe.videoFormat)
        #expect(out.videoCodecID == probe.videoCodecID)
        #expect(out.videoCodecName == probe.videoCodecName)
        #expect(out.videoWidth == probe.videoWidth)
        #expect(out.videoHeight == probe.videoHeight)
        #expect(out.videoFrameRate == probe.videoFrameRate)
        #expect(out.isDolbyVision == probe.isDolbyVision)
        #expect(out.dvProfile == probe.dvProfile)
        #expect(out.isLive == probe.isLive)
        #expect(out.subtitleTracks.map(\.id) == probe.subtitleTracks.map(\.id))
        #expect(out.metadata.title == probe.metadata.title)
        #expect(out.metadata.artworkData == probe.metadata.artworkData)

        // TrackInfo fields on the flipped track: everything except isAtmos survives.
        let before = probe.audioTracks[0]
        let after = out.audioTracks[0]
        #expect(after.isAtmos)
        #expect(after.id == before.id)
        #expect(after.name == before.name)
        #expect(after.codec == before.codec)
        #expect(after.language == before.language)
        #expect(after.channels == before.channels)
        #expect(after.bitrate == before.bitrate)
        #expect(after.isDefault == before.isDefault)
        #expect(after.isForced == before.isForced)
        #expect(after.isHearingImpaired == before.isHearingImpaired)
        #expect(after.isCommentary == before.isCommentary)
        #expect(after.isVisualImpaired == before.isVisualImpaired)
        #expect(after.assHeader == before.assHeader)
        #expect(after.isExternal == before.isExternal)
    }
}
