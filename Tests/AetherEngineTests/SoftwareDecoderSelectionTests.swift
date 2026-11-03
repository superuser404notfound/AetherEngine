import Testing
import Foundation
import CoreMedia
import VideoToolbox
import Synchronization
import AetherLibavformat
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

@Suite("SoftwarePlaybackHost decoder selection")
struct SoftwareDecoderSelectionTests {

    @MainActor
    @Test("P7 FEL with default options keeps the base layer on HardwareVideoDecoder: dual-layer is opt-in")
    func felDefaultIsOptIn() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        #expect(host.dolbyVisionHandling == .automatic)
        #expect(host.preferDualLayerDolbyVision == false)

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    #if DualLayerDolbyVision
    @MainActor
    @Test("P7 FEL opted in selects DualLayerVideoDecoder")
    func felOptedInSelectsDualLayer() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.preferDualLayerDolbyVision = true
        #expect(host.dolbyVisionHandling == .automatic)

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is DualLayerVideoDecoder)
    }
    #else
    @MainActor
    @Test("P7 FEL opted in keeps HardwareVideoDecoder in a build without the DualLayerDolbyVision trait")
    func felOptedInWithoutTraitKeepsBaseLayer() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.preferDualLayerDolbyVision = true

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
    }
    #endif

    @MainActor
    @Test("P7 MEL selects HardwareVideoDecoder across all option combinations")
    func melSelectsHardwareDecoder() {
        let handlings: [DolbyVisionHandling] = [.automatic, .baseLayerOnly]
        for handling in handlings {
            for prefer in [true, false] {
                let host = SoftwarePlaybackHost()
                host.elType = "MEL"
                host.dolbyVisionHandling = handling
                host.preferDualLayerDolbyVision = prefer

                let decoder = host.selectVideoDecoder(
                    codecID: AV_CODEC_ID_HEVC,
                    canHardwareDecode: true,
                    dvProfile: 7
                )
                #expect(
                    decoder is HardwareVideoDecoder,
                    "MEL with handling=\(handling) prefer=\(prefer) must pick HardwareVideoDecoder"
                )
            }
        }
    }

    @MainActor
    @Test("P7 FEL with baseLayerOnly selects HardwareVideoDecoder")
    func felBaseLayerOnlySelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.dolbyVisionHandling = .baseLayerOnly
        host.preferDualLayerDolbyVision = true

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    @MainActor
    @Test("P7 FEL with preferDualLayerDolbyVision=false selects HardwareVideoDecoder")
    func felPreferFalseSelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.dolbyVisionHandling = .automatic
        host.preferDualLayerDolbyVision = false

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    @MainActor
    @Test("P7 without elType (nil) selects HardwareVideoDecoder")
    func nilElTypeSelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        #expect(host.elType == nil)

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 7
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    @MainActor
    @Test("P8 or other DV profiles select HardwareVideoDecoder regardless of FEL settings")
    func p8SelectsHardwareDecoder() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"
        host.preferDualLayerDolbyVision = true
        host.dolbyVisionHandling = .automatic

        let decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: true,
            dvProfile: 8
        )
        #expect(decoder is HardwareVideoDecoder)
    }

    @MainActor
    @Test("AV1 and unsupported hardware decode use SoftwareVideoDecoder")
    func nonHardwareFallback() {
        let host = SoftwarePlaybackHost()
        host.elType = "FEL"

        let av1Decoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_AV1,
            canHardwareDecode: true,
            dvProfile: nil
        )
        #expect(av1Decoder is SoftwareVideoDecoder)

        let noHwDecoder = host.selectVideoDecoder(
            codecID: AV_CODEC_ID_HEVC,
            canHardwareDecode: false,
            dvProfile: 7
        )
        #expect(noHwDecoder is SoftwareVideoDecoder)
    }

    @Test("SoftwarePlaybackHost.shouldUseDualLayerDecoder static predicate matches table")
    func shouldUseDualLayerDecoderPredicate() {
        // Section 5.2 table: only dvProfile == 7 && elType == "FEL" && preferDualLayerDolbyVision && .automatic
        #expect(SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ) == DualLayerRouteDecision.isBuiltIn)
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .baseLayerOnly
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "FEL", preferDualLayerDolbyVision: false, dolbyVisionHandling: .automatic
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: "MEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 7, elType: nil, preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: 8, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
        #expect(!SoftwarePlaybackHost.shouldUseDualLayerDecoder(
            dvProfile: nil, elType: "FEL", preferDualLayerDolbyVision: true, dolbyVisionHandling: .automatic
        ))
    }
    @MainActor
    @Test("VP9 tries hardware without changing the software presentation route")
    func vp9SelectsHardwareCandidate() {
        let host = SoftwarePlaybackHost()
        #expect(host.selectVideoDecoder(codecID: AV_CODEC_ID_VP9,
            canHardwareDecode: true, dvProfile: nil) is HardwareVideoDecoder)
        #expect(host.selectVideoDecoder(codecID: AV_CODEC_ID_VP9,
            canHardwareDecode: false, dvProfile: nil) is SoftwareVideoDecoder)
    }

    private func withVP9Stream(_ body: (UnsafeMutablePointer<AVStream>) throws -> Void) throws {
        let context = try #require(avformat_alloc_context())
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        let parameters = try #require(stream.pointee.codecpar)
        parameters.pointee.codec_id = AV_CODEC_ID_VP9
        parameters.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        parameters.pointee.width = 1920
        parameters.pointee.height = 1080
        parameters.pointee.profile = 0
        parameters.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        parameters.pointee.color_primaries = AVCOL_PRI_BT709
        parameters.pointee.color_trc = AVCOL_TRC_BT709
        parameters.pointee.color_space = AVCOL_SPC_BT709
        parameters.pointee.chroma_location = AVCHROMA_LOC_LEFT
        stream.pointee.avg_frame_rate = AVRational(num: 24, den: 1)
        stream.pointee.time_base = AVRational(num: 1, den: 1000)
        try body(stream)
    }

    @Test("WebM VP9 produces vpcC without codec extradata")
    func webMVP9Configuration() throws {
        try withVP9Stream { stream in
            #expect(stream.pointee.codecpar.pointee.extradata == nil)
            let configuration = try VideoToolboxVideoFormat.make(stream: stream)
            #expect(configuration.codecName == "VP9")
            #expect(configuration.bitDepth == 8)
            let atoms = try #require(configuration.extensions[
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary)
            #expect(atoms["vpcC"] as? Data == Data([1, 0, 0, 0, 0, 40, 0x80, 1, 1, 1, 0, 0]))
        }
    }

    @Test("VP9 profile 2 preserves ten-bit HDR and full-range signaling")
    func vp9TenBitConfiguration() throws {
        try withVP9Stream { stream in
            let parameters = stream.pointee.codecpar!
            parameters.pointee.profile = 2
            parameters.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
            parameters.pointee.color_range = AVCOL_RANGE_JPEG
            parameters.pointee.color_primaries = AVCOL_PRI_BT2020
            parameters.pointee.color_trc = AVCOL_TRC_SMPTE2084
            parameters.pointee.color_space = AVCOL_SPC_BT2020_NCL
            parameters.pointee.chroma_location = AVCHROMA_LOC_TOPLEFT
            let configuration = try VideoToolboxVideoFormat.vp9Configuration(
                codecpar: parameters, frameRate: stream.pointee.avg_frame_rate)
            #expect(configuration.configurationBoxPayload == Data([1, 0, 0, 0, 2, 40, 0xa3, 9, 16, 9, 0, 0]))
        }
    }

    @Test("unsupported VP9 chroma and bit depth refuse the hardware candidate")
    func vp9UnsupportedConfiguration() throws {
        try withVP9Stream { stream in
            let parameters = stream.pointee.codecpar!
            for (profile, format) in [(Int32(1), AV_PIX_FMT_YUV444P),
                                      (Int32(2), AV_PIX_FMT_YUV420P12LE),
                                      (Int32(0), AV_PIX_FMT_YUV422P),
                                      (Int32(2), AV_PIX_FMT_NONE)] {
                parameters.pointee.profile = profile
                parameters.pointee.format = format.rawValue
                #expect(throws: VideoDecoderError.self) {
                    try VideoToolboxVideoFormat.make(stream: stream)
                }
            }
        }
    }

    @Test("VP9 does not relabel chroma siting or RGB as hardware 4:2:0")
    func vp9UnrepresentableMetadata() throws {
        try withVP9Stream { stream in
            let parameters = stream.pointee.codecpar!
            parameters.pointee.chroma_location = AVCHROMA_LOC_CENTER
            #expect(throws: VideoDecoderError.self) {
                try VideoToolboxVideoFormat.make(stream: stream)
            }
            parameters.pointee.chroma_location = AVCHROMA_LOC_LEFT
            parameters.pointee.color_space = AVCOL_SPC_RGB
            #expect(throws: VideoDecoderError.self) {
                try VideoToolboxVideoFormat.make(stream: stream)
            }
        }
    }

    /// Packs a VP9 uncompressed header MSB first, as the bitstream writes it.
    private static func vp9Header(_ fields: [(value: UInt32, bits: Int)]) -> [UInt8] {
        var bytes: [UInt8] = []
        var accumulator: UInt32 = 0
        var pending = 0
        for (value, bits) in fields {
            for shift in stride(from: bits - 1, through: 0, by: -1) {
                accumulator = accumulator << 1 | (value >> UInt32(shift) & 1)
                pending += 1
                if pending == 8 { bytes.append(UInt8(accumulator)); accumulator = 0; pending = 0 }
            }
        }
        if pending > 0 { bytes.append(UInt8(accumulator << UInt32(8 - pending))) }
        return bytes
    }

    private static func vp9KeyFrame(profile: UInt32, width: UInt32, height: UInt32,
                                    frameType: UInt32 = 0, showExisting: UInt32 = 0) -> [UInt8] {
        var fields: [(value: UInt32, bits: Int)] = [(2, 2), (profile & 1, 1), (profile >> 1, 1)]
        if profile == 3 { fields.append((0, 1)) }
        fields += [(showExisting, 1), (frameType, 1), (1, 1), (0, 1), (0x49_83_42, 24)]
        if profile >= 2 { fields.append((0, 1)) }
        fields += [(2, 3), (0, 1)]
        if profile == 1 || profile == 3 { fields.append((0, 3)) }
        fields += [(width - 1, 16), (height - 1, 16), (0, 8)]
        return vp9Header(fields)
    }

    private static func keyFrameSize(_ bytes: [UInt8]) -> (width: Int32, height: Int32)? {
        bytes.withUnsafeBufferPointer { VideoToolboxVideoFormat.vp9KeyFrameSize($0) }
    }

    @Test("a VP9 key frame header yields its coded size for every profile")
    func vp9KeyFrameSize() {
        for profile: UInt32 in 0...3 {
            let size = Self.keyFrameSize(Self.vp9KeyFrame(profile: profile, width: 1280, height: 720))
            #expect(size?.width == 1280 && size?.height == 720, "profile \(profile)")
        }
        let odd = Self.keyFrameSize(Self.vp9KeyFrame(profile: 2, width: 3839, height: 1607))
        #expect(odd?.width == 3839 && odd?.height == 1607)
    }

    @Test("inter frames, shown existing frames and truncated headers declare no size")
    func vp9KeyFrameSizeRefusals() {
        #expect(Self.keyFrameSize(Self.vp9KeyFrame(profile: 0, width: 640, height: 360, frameType: 1)) == nil)
        #expect(Self.keyFrameSize(Self.vp9KeyFrame(profile: 0, width: 640, height: 360, showExisting: 1)) == nil)
        let full = Self.vp9KeyFrame(profile: 0, width: 640, height: 360)
        #expect(Self.keyFrameSize(Array(full.prefix(6))) == nil)
        var badSync = full
        badSync[1] ^= 0xFF
        #expect(Self.keyFrameSize(badSync) == nil)
    }

    private static var hardwareVP9Available: Bool {
        if #available(macOS 11.0, iOS 26.2, tvOS 26.2, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
    }

    @Test("a retired VP9 keyframe cannot resize the current hardware session",
          .enabled(if: hardwareVP9Available))
    func staleVP9KeyframeDoesNotReplaceSession() throws {
        try withVP9Stream { stream in
            let parameters = try #require(stream.pointee.codecpar)
            parameters.pointee.width = 640
            parameters.pointee.height = 360
            let decoder = HardwareVideoDecoder()
            defer { decoder.close() }
            let widths = Mutex<[Int]>([])
            try decoder.open(stream: stream) { buffer, _, _ in
                widths.withLock { $0.append(CVPixelBufferGetWidth(buffer)) }
            }
            let staleEpoch = decoder.feedEpoch
            decoder.flush()
            let currentEpoch = decoder.feedEpoch

            func feed(_ bytes: [UInt8], keyframe: Bool, pts: Int64, epoch: UInt64) throws {
                let packet = try #require(av_packet_alloc())
                defer { var pointer: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&pointer) }
                try #require(av_new_packet(packet, Int32(bytes.count)) == 0)
                let destination = try #require(packet.pointee.data)
                bytes.withUnsafeBytes { destination.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count) }
                packet.pointee.flags = keyframe ? AV_PKT_FLAG_KEY : 0
                packet.pointee.pts = pts
                packet.pointee.dts = pts
                decoder.decode(packet: packet, epoch: epoch)
                decoder.flushKeepingEpoch()
            }

            // Actual first two packets from a three-frame black 640x360 VP9 clip. The second needs
            // the first reference picture; rebuilding the session between them makes it fail.
            // ffmpeg -f lavfi -i color=c=black:size=640x360:rate=24:duration=0.125 -c:v libvpx-vp9
            //   -threads 1 -row-mt 0 -g 999 -lag-in-frames 0 -auto-alt-ref 0 -pix_fmt yuv420p out.webm
            let keyframe: [UInt8] = [
                0x82, 0x49, 0x83, 0x42, 0x00, 0x27, 0xf0, 0x16, 0x76, 0x00, 0x38, 0x24, 0x1c, 0x18, 0x4a, 0x10,
                0x00, 0x50, 0x61, 0xf6, 0x3a, 0xf6, 0x80, 0x5c, 0xd1, 0xee, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0f,
                0x67, 0x1a, 0x9a, 0xe0, 0x62, 0x23, 0x7e, 0x44, 0x78, 0xf0, 0xe3, 0xc7, 0x8f, 0x1d, 0x00, 0x67,
                0x1a, 0x9a, 0xe0, 0x62, 0x23, 0x7e, 0x44, 0x78, 0xf0, 0xe3, 0xc7, 0x8f, 0x1d, 0x00,
            ]
            let interframe: [UInt8] = [
                0x86, 0x00, 0x40, 0x92, 0x9c, 0x00, 0x50, 0x01, 0x00, 0x02, 0x00, 0x26, 0xac, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x04, 0x58, 0x40, 0xf4, 0xe0, 0x58, 0x40, 0xf4, 0xe0,
            ]
            try feed(keyframe, keyframe: true, pts: 0, epoch: currentEpoch)
            #expect(widths.withLock { $0 } == [640])
            // Only the header matters: this packet is already retired and must cause no work.
            try feed(Self.vp9KeyFrame(profile: 0, width: 1280, height: 720),
                     keyframe: true, pts: 100, epoch: staleEpoch)
            try feed(interframe, keyframe: false, pts: 200, epoch: currentEpoch)
            #expect(widths.withLock { $0 } == [640, 640])
        }
    }

    @Test("a rejected hardware open closes its state and opens libavcodec before returning")
    func failedHardwareOpenFallsBack() throws {
        try withVP9Stream { stream in
            // Profile 1 is valid VP9, but intentionally outside this hardware route.
            stream.pointee.codecpar.pointee.profile = 1
            stream.pointee.codecpar.pointee.format = AV_PIX_FMT_YUV444P.rawValue
            let preferred = HardwareVideoDecoder()
            let opened = try VideoDecoderOpener.openPreferredOrFallback(
                preferred: preferred, makeFallback: { SoftwareVideoDecoder() },
                stream: stream, onFrame: { _, _, _ in })
            defer { opened.decoder.close() }
            #expect(opened.usedFallback)
            #expect(opened.decoder is SoftwareVideoDecoder)
            #expect(preferred.onFrame == nil)
        }
    }

    @Test("a failed software fallback is closed and its error reaches the caller")
    func failedFallbackIsClosed() throws {
        try withVP9Stream { stream in
            stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_NONE
            let preferred = HardwareVideoDecoder()
            let fallback = SoftwareVideoDecoder()
            #expect(throws: VideoDecoderError.self) {
                try VideoDecoderOpener.openPreferredOrFallback(
                    preferred: preferred, makeFallback: { fallback },
                    stream: stream, onFrame: { _, _, _ in })
            }
            #expect(preferred.onFrame == nil)
            #expect(fallback.onFrame == nil)
        }
    }

}
