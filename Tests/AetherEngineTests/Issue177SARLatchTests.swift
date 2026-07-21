import Testing
import Foundation
import CoreMedia
import CoreVideo
import Libavutil
@testable import AetherEngine

/// #177 issue 3: anamorphic content on the software path rendered at coded dimensions (a thin
/// strip) because the renderer's cached CMVideoFormatDescription was created from whatever the
/// FIRST pixel buffer carried and the cache key omitted PAR, freezing a PAR-less description
/// for the whole stream. Aggravators: AVCodecContext.sample_aspect_ratio can be garbage
/// (1088:1) or oscillate per-field on interlaced content, and no upper-bound sanity gate
/// existed. The decoder now resolves SAR frame -> codec ctx -> stream (first sane wins),
/// latches the first non-square SAR per stream, and the renderer keys its format-description
/// cache on PAR as well.
@Suite("Software-path SAR resolution, latch, and PAR-keyed format cache (#177)")
struct Issue177SARLatchTests {

    private func rational(_ num: Int32, _ den: Int32) -> AVRational {
        AVRational(num: num, den: den)
    }

    // MARK: - Sanity gate

    @Test("garbage codec-context SAR (1088:1) is rejected by the sanity gate")
    func garbageSARRejected() {
        #expect(SoftwareVideoDecoder.saneSAR(rational(1088, 1)) == nil)
        #expect(SoftwareVideoDecoder.saneSAR(rational(1, 1088)) == nil)
        #expect(SoftwareVideoDecoder.saneSAR(rational(0, 1)) == nil)
        #expect(SoftwareVideoDecoder.saneSAR(rational(-4, 3)) == nil)
        #expect(SoftwareVideoDecoder.saneSAR(rational(4, 0)) == nil)
    }

    @Test("legit anamorphic SARs pass the gate")
    func legitSARsPass() {
        for sar in [rational(64, 45), rational(8, 9), rational(32, 27), rational(16, 11), rational(1, 1)] {
            let sane = SoftwareVideoDecoder.saneSAR(sar)
            #expect(sane?.num == sar.num)
            #expect(sane?.den == sar.den)
        }
    }

    // MARK: - Resolution order

    @Test("frame SAR wins over codec context and stream")
    func frameWins() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(16, 11), codecCtx: rational(4, 3), stream: rational(1, 1))
        #expect(resolved?.num == 16)
        #expect(resolved?.den == 11)
    }

    @Test("garbage frame and ctx fall through to the stream SAR")
    func fallsThroughToStream() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(0, 1), codecCtx: rational(1088, 1), stream: rational(64, 45))
        #expect(resolved?.num == 64)
        #expect(resolved?.den == 45)
    }

    @Test("codec context SAR is consulted between frame and stream")
    func ctxBetweenFrameAndStream() {
        let resolved = SoftwareVideoDecoder.resolveSAR(
            frame: rational(0, 0), codecCtx: rational(8, 9), stream: rational(1, 1))
        #expect(resolved?.num == 8)
        #expect(resolved?.den == 9)
    }

    @Test("nothing sane anywhere resolves to nil")
    func nothingSaneIsNil() {
        #expect(SoftwareVideoDecoder.resolveSAR(
            frame: rational(0, 1), codecCtx: rational(1088, 1), stream: rational(0, 0)) == nil)
    }

    // MARK: - Per-stream latch

    @Test("first non-square SAR latches and suppresses later oscillation")
    func latchSuppressesOscillation() {
        // Frame 1: anamorphic 64:45 -> attach and latch.
        let first = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(64, 45), latched: nil)
        #expect(first.attach?.num == 64)
        #expect(first.latch?.num == 64)

        // Frame 2 (other field) reports 1:1 -> the latch wins, no flicker.
        let second = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(1, 1), latched: first.latch)
        #expect(second.attach?.num == 64)
        #expect(second.attach?.den == 45)

        // Frame 3 reports a different non-square value -> the latch still wins.
        let third = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(32, 27), latched: first.latch)
        #expect(third.attach?.num == 64)
    }

    @Test("square or unknown SAR before any latch attaches nothing")
    func squareBeforeLatchAttachesNothing() {
        let square = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(1, 1), latched: nil)
        #expect(square.attach == nil)
        #expect(square.latch == nil)

        let unknown = SoftwareVideoDecoder.sarForAttachment(resolved: nil, latched: nil)
        #expect(unknown.attach == nil)
        #expect(unknown.latch == nil)
    }

    @Test("late-appearing anamorphic SAR still latches after square frames")
    func lateSARLatches() {
        let square = SoftwareVideoDecoder.sarForAttachment(resolved: rational(1, 1), latched: nil)
        let late = SoftwareVideoDecoder.sarForAttachment(
            resolved: rational(64, 45), latched: square.latch)
        #expect(late.attach?.num == 64)
        #expect(late.latch?.num == 64)
    }

    // MARK: - Renderer format-description cache keyed on PAR

    private func makeBuffer(par: (Int, Int)?) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 720, 576,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as NSDictionary,
            &pb
        )
        let buffer = pb!
        if let par {
            let aspect: NSDictionary = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: par.0,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: par.1,
            ]
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        }
        return buffer
    }

    @Test("a PAR change at identical geometry invalidates the cached format description")
    func parChangeInvalidatesFormatCache() throws {
        let renderer = SampleBufferRenderer()

        // First frame carries no PAR: description is created and cached without the extension.
        let plain = try #require(renderer.createSampleBuffer(
            from: makeBuffer(par: nil), pts: CMTime(value: 0, timescale: 90000)))
        let plainDesc = try #require(CMSampleBufferGetFormatDescription(plain))
        #expect(CMFormatDescriptionGetExtension(
            plainDesc, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) == nil)

        // Second frame at the same geometry carries 64:45: the PAR-less description must NOT
        // be reused (the pre-#177 cache key omitted PAR and froze it).
        let anamorphic = try #require(renderer.createSampleBuffer(
            from: makeBuffer(par: (64, 45)), pts: CMTime(value: 3600, timescale: 90000)))
        let anaDesc = try #require(CMSampleBufferGetFormatDescription(anamorphic))
        let ext = try #require(CMFormatDescriptionGetExtension(
            anaDesc, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? NSDictionary)
        #expect(ext[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int == 64)
        #expect(ext[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int == 45)

        // Same PAR again is a cache hit (identical description object, not just an equal one).
        let repeated = try #require(renderer.createSampleBuffer(
            from: makeBuffer(par: (64, 45)), pts: CMTime(value: 7200, timescale: 90000)))
        let repeatDesc = try #require(CMSampleBufferGetFormatDescription(repeated))
        #expect(repeatDesc === anaDesc)
    }
}
