import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// AE#1060: since 7.66.1 DTS:X asked into a small bed renders as 7.1.4. A host that wants TrueHD Atmos
/// in the listener's 5.1.2 but DTS:X on the 7.1 channel bridge sets `rendersDTSXObjectAudio = false`,
/// and one load covers a file that carries both tracks.
struct Issue1060DTSXOptOutTests {

    @Test("the default leaves object rendering as it was")
    func defaultIsOn() {
        #expect(LoadOptions().rendersDTSXObjectAudio)
        #expect(LoadOptions(objectAudioRendering: .render(.l512)).rendersDTSXObjectAudio)
    }

    @Test("opting out turns rendering off for DTS only")
    func perCodec() {
        let asked = ObjectAudioRendering.render(.l512)
        #expect(HLSVideoEngine.objectAudioRendering(asked, codecID: AV_CODEC_ID_DTS, rendersDTSX: false) == .off)
        #expect(HLSVideoEngine.objectAudioRendering(asked, codecID: AV_CODEC_ID_DTS, rendersDTSX: true) == asked)
        #expect(HLSVideoEngine.objectAudioRendering(asked, codecID: AV_CODEC_ID_TRUEHD, rendersDTSX: false) == asked)
        #expect(HLSVideoEngine.objectAudioRendering(asked, codecID: AV_CODEC_ID_EAC3, rendersDTSX: false) == asked)
    }

    #if DTSXObjectAudio
    @Test("an opted-out DTS:X track keeps the bridge instead of 7.1.4")
    func dtsxKeepsBridge() {
        let asked = ObjectAudioRendering.apac(.l512)
        #expect(HLSVideoEngine.spatialRenderingLayout(
            rendering: asked, codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X, sampleRate: 48_000) == .l714)
        let optedOut = HLSVideoEngine.objectAudioRendering(asked, codecID: AV_CODEC_ID_DTS, rendersDTSX: false)
        #expect(HLSVideoEngine.spatialRenderingLayout(
            rendering: optedOut, codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X, sampleRate: 48_000) == nil)
        #expect(SoftwareAtmosRoute.route(
            codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X, sampleRate: 48_000, channels: 8,
            framesPerPacket: 512, isLive: false, rendering: optedOut, confirmedJOC: false,
            osSupportsAPAC: true, routeFormat: .lpcm) == .pcm)
    }
    #endif

    #if TrueHDObjectAudio
    @Test("TrueHD Atmos in the same load still renders into the asked bed")
    func trueHDStillRenders() {
        let asked = ObjectAudioRendering.apac(.l512)
        let trueHD = HLSVideoEngine.objectAudioRendering(asked, codecID: AV_CODEC_ID_TRUEHD, rendersDTSX: false)
        #expect(HLSVideoEngine.spatialRenderingLayout(
            rendering: trueHD, codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, sampleRate: 48_000) == .l512)
    }
    #endif

    private func audio(_ id: Int, codec: String, codecID: AVCodecID, profile: Int32) -> TrackInfo {
        TrackInfo(id: id, name: "a\(id)", codec: codec, language: "eng", channels: 8, isDefault: id == 1,
                  profile: VideoStreamFormat.profileName(codecID: codecID, profile: profile))
    }

    @Test("an opted-out load does not pick a DTS:X track for its heights",
          .enabled(if: AetherEngine.linksDTSXObjectDecoder))
    func pickSkipsDTSX() {
        let tracks = [TrackInfo(id: 1, name: "a1", codec: "ac3", language: "eng", channels: 6, isDefault: true),
                      audio(2, codec: "dca", codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 2)
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true, rendersDTSX: false) == 1)
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, rendersDTSX: false, defaultIndex: 1) == nil)
    }

    @Test("an opted-out load still picks TrueHD Atmos", .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func pickKeepsTrueHD() {
        let tracks = [audio(1, codec: "dca", codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X),
                      audio(2, codec: "truehd", codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true, rendersDTSX: false) == 2)
    }
}
