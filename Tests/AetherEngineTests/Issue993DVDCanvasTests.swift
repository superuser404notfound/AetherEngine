import CoreGraphics
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#993 (secunit404): a VobSub track keeps the DVD's 720x480 plane, which has non-square pixels, and
/// the decoder reported it as the canvas. Mapped width-aligned onto 1280x720 video it was 853 lines
/// tall, so a cue at the bottom of the DVD frame drew up to 67 px low and was clipped.
///
/// One hand-built subpicture: a 540x40 region at 90,400, every line filled with opaque colour 1.
struct Issue993DVDCanvasTests {

    private static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    private static func subpicture() -> [UInt8] {
        let (x1, x2, y1, y2) = (90, 629, 400, 439)
        // Per line: four zero nibbles then colour 1, "fill the rest of the line". Both fields share it.
        let pixels = Array([[UInt8]](repeating: [0x00, 0x01], count: 20).joined())
        let controlAt = 4 + pixels.count
        var control: [UInt8] = [0x00, 0x00] + be16(controlAt)
        control += [0x03, 0x00, 0x10]                        // colormap: colour 1 -> palette 1
        control += [0x04, 0x00, 0xF0]                        // alpha: colour 1 opaque, 0 transparent
        control += [0x05, UInt8(x1 >> 4), UInt8((x1 & 0xF) << 4 | x2 >> 8), UInt8(x2 & 0xFF),
                    UInt8(y1 >> 4), UInt8((y1 & 0xF) << 4 | y2 >> 8), UInt8(y2 & 0xFF)]
        control += [0x06] + be16(4) + be16(4)
        control += [0x01, 0xFF]
        let total = controlAt + control.count
        return be16(total) + be16(controlAt) + pixels + control
    }

    private static func decodeImage(extradataSize: String?,
                                    videoWidth: Int32, videoHeight: Int32) throws -> SubtitleImage {
        var parOpt = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parOpt) }
        let par = try #require(parOpt)
        par.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        par.pointee.codec_id = AV_CODEC_ID_DVD_SUBTITLE
        if let extradataSize {
            let text = Array("size: \(extradataSize)\n".utf8)
            let buf = try #require(av_mallocz(text.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            text.withUnsafeBytes { _ = memcpy(buf, $0.baseAddress, text.count) }
            par.pointee.extradata = buf.assumingMemoryBound(to: UInt8.self)
            par.pointee.extradata_size = Int32(text.count)
        }
        let decoder = try #require(EmbeddedSubtitleDecoder(codecpar: par, sourceVideoWidth: videoWidth,
                                                           sourceVideoHeight: videoHeight))

        let bytes = subpicture()
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

    @Test("a 720x480 plane on 1280x720 video reports the video frame and lands inside it")
    func rescaledEncode() throws {
        let image = try Self.decodeImage(extradataSize: "720x480", videoWidth: 1280, videoHeight: 720)
        Self.expectNear(image.position.minX, 90.0 / 720, "x")
        Self.expectNear(image.position.minY, 400.0 / 480, "y")
        Self.expectNear(image.position.height, 40.0 / 480, "h")
        #expect(image.canvasSize == CGSize(width: 1280, height: 720))
        // Through the in-engine compositor: the bottom edge sits at 440/480 of the frame, not 67 px lower.
        let rect = SubtitleFrameCompositor.imageRect(position: image.position, canvasSize: image.canvasSize,
                                                     frameWidth: 1280, frameHeight: 720)
        #expect(abs(rect.maxY - 720 * 440.0 / 480) < 1, "bottom \(rect.maxY)")
    }

    @Test("a rip that kept the DVD width keeps the decoder's canvas (cropped, width-aligned is right)")
    func croppedOnly() throws {
        let image = try Self.decodeImage(extradataSize: "720x480", videoWidth: 720, videoHeight: 432)
        #expect(image.canvasSize == CGSize(width: 720, height: 480))
    }

    @Test("without a size line the plane is the video's own grid")
    func noExtradataSize() throws {
        let image = try Self.decodeImage(extradataSize: nil, videoWidth: 720, videoHeight: 480)
        #expect(image.canvasSize == CGSize(width: 720, height: 480))
    }

    @Test("rescale rules by video shape", arguments: [
        // Whole 16:9 or 4:3 display, or anything up to 2% wider than 16:9: cover the frame.
        (CGSize(width: 720, height: 480), CGSize(width: 1280, height: 720), CGSize(width: 1280, height: 720)),
        (CGSize(width: 720, height: 576), CGSize(width: 1024, height: 576), CGSize(width: 1024, height: 576)),
        (CGSize(width: 720, height: 480), CGSize(width: 640, height: 480), CGSize(width: 640, height: 480)),
        (CGSize(width: 720, height: 480), CGSize(width: 848, height: 480), CGSize(width: 848, height: 480)),
        // Cropped wider than 16:9 before scaling: the 16:9 frame at the video's width.
        (CGSize(width: 720, height: 480), CGSize(width: 1280, height: 544), CGSize(width: 1280, height: 720)),
        (CGSize(width: 720, height: 576), CGSize(width: 1920, height: 800), CGSize(width: 1920, height: 1080)),
        (CGSize(width: 720, height: 480), CGSize(width: 1280, height: 692), CGSize(width: 1280, height: 720)),
    ])
    func rescaleRules(canvas: CGSize, video: CGSize, expected: CGSize) {
        #expect(EmbeddedSubtitleDecoder.dvdReportedCanvas(canvas: canvas, video: video) == expected)
    }

    @Test("same width or unknown dims keep the decoder's canvas")
    func keepsCanvas() {
        #expect(EmbeddedSubtitleDecoder.dvdReportedCanvas(canvas: CGSize(width: 720, height: 480),
                                                          video: CGSize(width: 720, height: 360)) == nil)
        #expect(EmbeddedSubtitleDecoder.dvdReportedCanvas(canvas: CGSize(width: 720, height: 480),
                                                          video: .zero) == nil)
    }
}
