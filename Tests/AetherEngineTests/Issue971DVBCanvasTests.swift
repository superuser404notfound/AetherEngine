import CoreGraphics
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#971 (l984-451, Rivulet#487): DVB subtitles authored on a 720x576 display landed left of centre,
/// above the middle and too small on 1080p video. The decoder seeded the canvas from the video, and
/// dvbsubdec only takes its canvas from a display definition segment, or the EN 300 743 default of
/// 720x576, while the context has no size.
///
/// One hand-built display set: a 540x40 region at 90,500, filled opaque, so the cropped image is the
/// whole region.
struct Issue971DVBCanvasTests {

    private static func segment(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [0x0F, type, 0x00, 0x01, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    private static func displaySet(dds: (width: Int, height: Int)?) -> [UInt8] {
        var bytes: [UInt8] = []
        if let dds {
            bytes += segment(0x14, [0x00] + be16(dds.width - 1) + be16(dds.height - 1))
        }
        // Page: time-out, version 0 / mode change, region 0 at 90,500.
        bytes += segment(0x10, [10, 0x08, 0x00, 0x00] + be16(90) + be16(500))
        // Region 0: 540x40, 8-bit, CLUT 0, background index 1, object 0 at 0,0.
        bytes += segment(0x11, [0x00, 0x08] + be16(540) + be16(40) + [0x0C, 0x00, 0x01, 0x00]
                         + [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        // CLUT 0: 8-bit entry 1, full range, opaque white.
        bytes += segment(0x12, [0x00, 0x00, 0x01, 0x21, 235, 128, 128, 0])
        // Object 0: one pixel of index 1, then end of line; the bottom field repeats the top.
        let pixels: [UInt8] = [0x12, 0x01, 0x00, 0x00, 0xF0]
        bytes += segment(0x13, [0x00, 0x00, 0x00] + be16(pixels.count) + be16(0) + pixels)
        bytes += segment(0x80, [])
        return bytes
    }

    private static func decodeImage(dds: (width: Int, height: Int)?,
                                    videoWidth: Int32, videoHeight: Int32) throws -> SubtitleImage {
        var parOpt = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parOpt) }
        let par = try #require(parOpt)
        par.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        par.pointee.codec_id = AV_CODEC_ID_DVB_SUBTITLE
        let decoder = try #require(EmbeddedSubtitleDecoder(codecpar: par, sourceVideoWidth: videoWidth,
                                                           sourceVideoHeight: videoHeight))

        let bytes = displaySet(dds: dds)
        var pktOpt = av_packet_alloc()
        defer { av_packet_free(&pktOpt) }
        let pkt = try #require(pktOpt)
        #expect(av_new_packet(pkt, Int32(bytes.count)) == 0)
        bytes.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress, bytes.count) }
        pkt.pointee.pts = 90_000

        let event = try #require(decoder.decode(packet: pkt, streamTimeBase: AVRational(num: 1, den: 90_000)))
        let cue = try #require(event.cues.first)
        guard case .image(let image) = cue.body else {
            Issue.record("expected a bitmap cue, got \(cue.body)")
            throw CancellationError()
        }
        return image
    }

    private static func expectNear(_ a: CGFloat, _ b: Double, _ label: String) {
        #expect(abs(Double(a) - b) < 0.002, "\(label): \(a) vs \(b)")
    }

    @Test("an SD canvas, default or from a DDS, places the region against 720x576, not the HD video",
          arguments: [false, true])
    func sdCanvasOnHDVideo(withSDDDS: Bool) throws {
        let image = try Self.decodeImage(dds: withSDDDS ? (720, 576) : nil, videoWidth: 1920, videoHeight: 1080)
        Self.expectNear(image.position.minX, 90.0 / 720, "x")
        Self.expectNear(image.position.minY, 500.0 / 576, "y")
        Self.expectNear(image.position.width, 540.0 / 720, "w")
        Self.expectNear(image.position.height, 40.0 / 576, "h")
        // The display covers the whole picture: hosts stretch it onto the video, not aspect-fit 5:4.
        #expect(image.canvasSize == CGSize(width: 1920, height: 1080))
    }

    @Test("an HD DDS keeps its 1920x1080 canvas")
    func hdCanvas() throws {
        let image = try Self.decodeImage(dds: (1920, 1080), videoWidth: 1920, videoHeight: 1080)
        Self.expectNear(image.position.minX, 90.0 / 1920, "x")
        Self.expectNear(image.position.minY, 500.0 / 1080, "y")
        Self.expectNear(image.position.width, 540.0 / 1920, "w")
        #expect(image.canvasSize == CGSize(width: 1920, height: 1080))
    }

    @Test("without video dims the canvas falls back to the decoder's own")
    func noVideoDims() throws {
        let image = try Self.decodeImage(dds: nil, videoWidth: 0, videoHeight: 0)
        Self.expectNear(image.position.minX, 90.0 / 720, "x")
        #expect(image.canvasSize == CGSize(width: 720, height: 576))
    }
}
