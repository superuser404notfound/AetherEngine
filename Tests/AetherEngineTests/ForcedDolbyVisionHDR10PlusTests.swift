import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Sodalite#245 (Tchet33): a Samsung with HDR10+ and no Dolby Vision. With the AE#455 route on, a
/// Profile 8.1 file that also carries HDR10+ was packaged as Profile 5, so the panel got composed HDR10
/// and never the HDR10+ the file holds. `preferHDR10PlusOverForcedDolbyVision` lets that HDR10+ win.
@Suite("Sodalite#245: HDR10+ outranks the forced Dolby Vision route", .timeLimit(.minutes(3)))
struct ForcedDolbyVisionHDR10PlusTests {

    private final class DVCodecpar {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        init(profile: UInt8, blCompatibilityID: UInt8) {
            ptr = avcodec_parameters_alloc()
            ptr.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            ptr.pointee.codec_id = AV_CODEC_ID_HEVC
            ptr.pointee.width = 3840
            ptr.pointee.height = 2160
            ptr.pointee.level = 153
            ptr.pointee.color_primaries = AVCOL_PRI_BT2020
            ptr.pointee.color_trc = AVCOL_TRC_SMPTE2084
            ptr.pointee.color_space = AVCOL_SPC_BT2020_NCL
            let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            guard let sd = av_packet_side_data_new(
                &ptr.pointee.coded_side_data, &ptr.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF, size, 0
            ) else {
                fatalError("could not attach a DOVI configuration record")
            }
            memset(sd.pointee.data, 0, size)
            sd.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_version_major = 1
                rec.pointee.dv_profile = profile
                rec.pointee.dv_level = 6
                rec.pointee.rpu_present_flag = 1
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_bl_signal_compatibility_id = blCompatibilityID
            }
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    private static func route(
        profile: UInt8, compat: UInt8, dvDisplay: Bool = false, forceDV: Bool = true, yields: Bool
    ) throws -> HLSVideoEngine.CodecRoute {
        let par = DVCodecpar(profile: profile, blCompatibilityID: compat)
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/dev/null"),
            dvModeAvailable: dvDisplay,
            forceDolbyVisionOnNonDVDisplay: forceDV,
            forcedDolbyVisionYieldsToHDR10Plus: yields
        )
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par.ptr))
    }

    // MARK: - The route

    @Test("a Profile 8.1 with HDR10+ keeps the native route, record and SUPPLEMENTAL as without the opt-in")
    func profile81YieldsToHDR10Plus() throws {
        let r = try Self.route(profile: 8, compat: 1, yields: true)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.primaryCodecs == "hvc1.2.4.L153")
        #expect(r.supplementalCodecs == "dvh1.08.06/db1p")
        #expect(r.doviConfig == .keep)
    }

    @Test("a Profile 8.1 without HDR10+ still takes the forced Profile 5 packaging")
    func profile81WithoutHDR10PlusStaysForced() throws {
        let r = try Self.route(profile: 8, compat: 1, yields: false)
        #expect(r.codecTagOverride == "dvh1")
        #expect(r.primaryCodecs == "dvh1.05.06")
        #expect(r.doviConfig == .rewriteToProfile5)
    }

    @Test("a Profile 7 with HDR10+ keeps its 8.1 conversion and the native packaging")
    func profile7YieldsToHDR10Plus() throws {
        let r = try Self.route(profile: 7, compat: 6, yields: true)
        #expect(r.codecTagOverride == "hvc1")
        #expect(r.doviConfig == .rewriteToProfile81)
        #expect(r.convertP7ToProfile81)
    }

    @Test("a display with Dolby Vision is untouched by either flag")
    func dvDisplayIgnoresTheYield() throws {
        let yielded = try Self.route(profile: 8, compat: 1, dvDisplay: true, yields: true)
        let plain = try Self.route(profile: 8, compat: 1, dvDisplay: true, forceDV: false, yields: false)
        #expect(yielded.codecTagOverride == plain.codecTagOverride)
        #expect(yielded.primaryCodecs == plain.primaryCodecs)
        #expect(yielded.supplementalCodecs == plain.supplementalCodecs)
        #expect(yielded.doviConfig == plain.doviConfig)
    }

    // MARK: - When the load reads the head

    private static func scans(
        force: Bool = true, prefer: Bool = true, dvDisplay: Bool = false,
        handling: DolbyVisionHandling = .automatic, codec: AVCodecID = AV_CODEC_ID_HEVC,
        profile: Int? = 8, compat: Int? = 1, isLive: Bool = false, seekable: Bool = true
    ) -> Bool {
        ForcedDolbyVisionHDR10Plus.scansHead(
            forceDolbyVisionOnNonDVDisplay: force, preferHDR10Plus: prefer, displayTakesDolbyVision: dvDisplay,
            dolbyVisionHandling: handling, codecID: codec, dvProfile: profile, dvBLCompatID: compat,
            isLive: isLive, isSourceSeekable: seekable)
    }

    @Test("the scan runs exactly where the forced route could be taken")
    func scanGate() {
        #expect(Self.scans())
        #expect(Self.scans(profile: 7, compat: 6))
        #expect(Self.scans(compat: 6))
        #expect(!Self.scans(force: false))
        #expect(!Self.scans(prefer: false))
        #expect(!Self.scans(dvDisplay: true))
        #expect(!Self.scans(handling: .baseLayerOnly))
        #expect(!Self.scans(codec: AV_CODEC_ID_AV1))
        #expect(!Self.scans(profile: 5, compat: 0))
        #expect(!Self.scans(profile: nil, compat: nil))
        #expect(!Self.scans(compat: 4))
        #expect(!Self.scans(compat: 2))
        #expect(!Self.scans(isLive: true))
        #expect(!Self.scans(seekable: false))
    }

    @Test("the route yields only when the host prefers HDR10+ and the source carries it")
    func yieldNeedsBoth() {
        #expect(ForcedDolbyVisionHDR10Plus.yieldsToHDR10Plus(preferHDR10Plus: true, sourceCarriesHDR10Plus: true))
        #expect(!ForcedDolbyVisionHDR10Plus.yieldsToHDR10Plus(preferHDR10Plus: true, sourceCarriesHDR10Plus: false))
        #expect(!ForcedDolbyVisionHDR10Plus.yieldsToHDR10Plus(preferHDR10Plus: false, sourceCarriesHDR10Plus: true))
    }

    // MARK: - The head scan on real bytes

    private static func headScan(_ base64: String) throws -> Bool {
        let data = try ProbeTestFixtures.decode(base64)
        return try ProbeTestFixtures.withFile(data) { url in
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: url)
            return ForcedDolbyVisionHDR10Plus.headCarriesHDR10Plus(
                demuxer: demuxer, streamIndex: demuxer.videoStreamIndex)
        }
    }

    @Test("the head scan finds the ST 2094-40 SEI in the HDR10+ fixture")
    func headScanFindsHDR10Plus() throws {
        #expect(try Self.headScan(HDR10PlusProbeIntegrationTests.hdr10PlusBase64))
    }

    @Test("the head scan reports nothing for the same picture without the SEI")
    func headScanIgnoresPlainHDR10() throws {
        #expect(try !Self.headScan(HDR10PlusProbeIntegrationTests.hdr10Base64))
    }

    @Test("the option is a known LoadOptions field")
    func knownField() {
        #expect(SessionOptionCorrection.knownFields.contains("preferHDR10PlusOverForcedDolbyVision"))
        #expect(!LoadOptions().preferHDR10PlusOverForcedDolbyVision)
    }
}
