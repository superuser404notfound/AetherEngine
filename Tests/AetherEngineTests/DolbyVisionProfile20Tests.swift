import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Dolby Vision Profile 20: Dolby Vision on MV-HEVC (3D). The base view is a Profile 5 base view with a
/// Profile 5 RPU, the second view travels in NAL units of its own layer, and the record says version 3.0.
/// Measured against a real 4K sample (dvcC + dvvC 3.0 / profile 20 / level 6, `dovi_tool` reading its
/// RPU as Profile 5): served in 2D as Profile 5 it decodes and the RPU reshapes it to the right colour,
/// but only once the record's version is 1.0. A Profile 5 record that says 3.0 is refused (-12910).
@Suite("Dolby Vision Profile 20 (MV-HEVC)")
struct DolbyVisionProfile20Tests {

    /// An `AVCodecParameters` carrying a Profile 20 record the way the sample's MP4 hands it over.
    private final class P20Codecpar {
        let ptr: UnsafeMutablePointer<AVCodecParameters>
        init(profile: UInt8 = 20, versionMajor: UInt8 = 3) {
            ptr = avcodec_parameters_alloc()
            ptr.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            ptr.pointee.codec_id = AV_CODEC_ID_HEVC
            ptr.pointee.width = 3840
            ptr.pointee.height = 2160
            ptr.pointee.level = 150
            ptr.pointee.color_primaries = AVCOL_PRI_BT2020
            ptr.pointee.color_trc = AVCOL_TRC_SMPTE2084
            ptr.pointee.color_space = AVCOL_SPC_IPT_C2
            ptr.pointee.color_range = AVCOL_RANGE_JPEG
            let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            guard let sd = av_packet_side_data_new(
                &ptr.pointee.coded_side_data, &ptr.pointee.nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF, size, 0) else {
                fatalError("could not attach a DOVI configuration record")
            }
            memset(sd.pointee.data, 0, size)
            sd.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_version_major = versionMajor
                rec.pointee.dv_profile = profile
                rec.pointee.dv_level = 6
                rec.pointee.rpu_present_flag = 1
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_bl_signal_compatibility_id = 0
            }
        }
        var record: AVDOVIDecoderConfigurationRecord {
            ptr.pointee.coded_side_data!.pointee.data.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        }
        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    private static func route(_ par: P20Codecpar, dvDisplay: Bool, stereo: Bool) throws -> HLSVideoEngine.CodecRoute {
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/dev/null"), dvModeAvailable: dvDisplay)
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par.ptr), stereoMultiview: stereo)
    }

    @Test("in 2D it is served as Profile 5, on a display with and without Dolby Vision",
          arguments: [true, false])
    func twoDServesProfile5(dvDisplay: Bool) throws {
        let r = try Self.route(P20Codecpar(), dvDisplay: dvDisplay, stereo: false)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.primaryCodecs == "dvh1.05.06")
        #expect(r.supplementalCodecs == nil)
        #expect(r.videoRange == .pq)
        #expect(r.doviConfig == .rewriteToProfile5)
        #expect(r.convertP7ToProfile81 == false)
        #expect(r.dvVariant == .profile20)
    }

    @Test("in 3D the source goes out as it is: dvh1.20 and its own record")
    func threeDKeepsProfile20() throws {
        let r = try Self.route(P20Codecpar(), dvDisplay: true, stereo: true)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.primaryCodecs == "dvh1.20.06")
        #expect(r.supplementalCodecs == nil)
        #expect(r.doviConfig == .keep)
        #expect(r.dvVariant == .profile20)
    }

    @Test("a Profile 5 source is not moved by the stereo flag")
    func profile5IgnoresStereo() throws {
        let r = try Self.route(P20Codecpar(profile: 5, versionMajor: 1), dvDisplay: true, stereo: true)
        #expect(r.primaryCodecs == "dvh1.05.06")
        #expect(r.dvVariant == .profile5)
    }

    @Test("the Profile 5 rewrite writes a version 1.0 record")
    func rewriteSetsVersionOne() {
        let par = P20Codecpar()
        MP4SegmentMuxer.rewriteDoviConfig(par.ptr, profile: 5, blCompatibilityID: 0)
        let rec = par.record
        #expect(rec.dv_profile == 5)
        #expect(rec.dv_version_major == 1)
        #expect(rec.dv_version_minor == 0)
        #expect(rec.dv_bl_signal_compatibility_id == 0)
        #expect(rec.rpu_present_flag == 1)
        #expect(rec.bl_present_flag == 1)
        #expect(rec.dv_level == 6)
    }

    @Test("every IPT-base guard treats 20 like 5")
    func iptBaseGuards() {
        #expect(VideoRoutingPolicy.hevcDolbyVisionHasIPTBase(5))
        #expect(VideoRoutingPolicy.hevcDolbyVisionHasIPTBase(20))
        #expect(!VideoRoutingPolicy.hevcDolbyVisionHasIPTBase(8))
        #expect(!VideoRoutingPolicy.hevcDolbyVisionHasIPTBase(nil))

        // Native even when the VT probe says no (it probes a plain hvcC, not what dvh1 plays).
        #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 20, canHardwareDecode: { false }))
        // And never the software path, which would show IPT as YCbCr.
        #expect(VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 20, dvBlCompatID: 0))
        #expect(AetherEngine.heldPictureNeedsReshaping(videoFormat: .dolbyVision, dolbyVisionProfile: 20))
    }

    @MainActor
    @Test("arming the 2D fallback is per mount and starts without a refusal")
    func stereoFallbackArming() {
        let host = NativeAVPlayerHost()
        #expect(!host.stereoRefusalFallbackArmed)
        host.armStereoRefusalFallback(true)
        #expect(host.stereoRefusalFallbackArmed)
        #expect(host.pendingStereoRefusal == nil)
        host.armStereoRefusalFallback(false)
        #expect(!host.stereoRefusalFallbackArmed)
    }

    @Test("stills reshape a Profile 20 frame")
    func stillsReshape() {
        let par = P20Codecpar()
        #expect(FrameDecodeContext.isDVNoBaseLayer(codecpar: UnsafePointer(par.ptr)))
    }
}
