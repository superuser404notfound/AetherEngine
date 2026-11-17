import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit 2026-11-17, package P1: values from a hostile file or host that used to trap (or allocate
/// a gigabyte) must now end in a graceful result. Each test feeds the value that crashed.
@Suite("Hostile input ends gracefully", .serialized)
struct HostileInputTests {

    // MARK: - BIT-201 H.264 SPS size

    private struct Bits {
        var bits: [Int] = []
        mutating func u(_ value: Int, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bits.append((value >> i) & 1) } }
        mutating func ue(_ value: Int) {
            let v = value + 1
            let n = Int.bitWidth - v.leadingZeroBitCount
            u(0, n - 1); u(v, n)
        }
        var bytes: [UInt8] {
            var padded = bits + [1]
            while padded.count % 8 != 0 { padded.append(0) }
            return stride(from: 0, to: padded.count, by: 8).map { i in
                UInt8(padded[i..<(i + 8)].reduce(0) { ($0 << 1) | $1 })
            }
        }
    }

    /// A baseline-profile SPS NAL with the given macroblock counts and no cropping.
    private func sps(widthMbsMinus1: Int, heightMapUnitsMinus1: Int, frameMbsOnly: Bool = true) -> [UInt8] {
        var w = Bits()
        w.ue(0); w.ue(0); w.ue(2); w.ue(1); w.u(0, 1)
        w.ue(widthMbsMinus1); w.ue(heightMapUnitsMinus1)
        w.u(frameMbsOnly ? 1 : 0, 1)
        if !frameMbsOnly { w.u(0, 1) }
        w.u(1, 1); w.u(0, 1); w.u(0, 1)
        return [0x67, 66, 0, 30] + w.bytes
    }

    @Test("BIT-201: an SPS far above 16384 samples is rejected, a normal one still parses")
    func absurdSPSDimensions() {
        let ok = H264SPS.dimensions(fromNAL: sps(widthMbsMinus1: 79, heightMapUnitsMinus1: 44))
        #expect(ok?.width == 1280)
        #expect(ok?.height == 720)
        #expect(H264SPS.dimensions(fromNAL: sps(widthMbsMinus1: 1 << 28, heightMapUnitsMinus1: 44)) == nil)
        #expect(H264SPS.dimensions(fromNAL: sps(widthMbsMinus1: 79, heightMapUnitsMinus1: 1 << 28)) == nil)
        #expect(H264SPS.dimensions(fromNAL: sps(widthMbsMinus1: 1024, heightMapUnitsMinus1: 44)) == nil)
        #expect(H264SPS.dimensions(fromNAL: sps(widthMbsMinus1: 79, heightMapUnitsMinus1: 600, frameMbsOnly: false)) == nil)
        #expect(H264SPS.dimensions(fromNAL: sps(widthMbsMinus1: 1023, heightMapUnitsMinus1: 44))?.width == 16384)
    }

    // MARK: - BIT-204 layer times 2^63 apart

    @Test("BIT-204: layer times exactly 2^63 apart do not trap the Dolby Vision join")
    func joinWithOppositeExtremeTimes() {
        var join = DolbyVisionLayerJoin<String>()
        join.addBase(.init(unit: "b", pts: 1 << 62, isIRAP: true))
        join.addEnhancement(.init(unit: "e", pts: -(1 << 62), isIRAP: true))
        var steps = 0
        while join.next(atEnd: true) != nil, steps < 8 { steps += 1 }
        _ = join.takeRetired()
        #expect(steps < 8)
    }

    @Test("BIT-204: the Blu-ray layer pairing does not trap on times 2^63 apart")
    func pairingWithOppositeExtremeTimes() {
        var pairing = DolbyVisionLayerPairing<Int>(tolerance: 2_000)
        pairing.addBase(1, pts: 1 << 62) { _, _ in true }
        pairing.addRPU([1], pts: -(1 << 62)) { _, _ in true }
        let released = pairing.release(atEnd: true)
        #expect(released?.paired == false)
    }

    // MARK: - AUD-202 non-finite samples

    private func loudnessNormalizer() -> (LoudnessNormalizer, () -> Void) {
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, 2)
        let normalizer = LoudnessNormalizer(targetLUFS: -16, maxGainDB: 18, sampleRate: 48_000, layout: &layout)
        return (normalizer, { av_channel_layout_uninit(&layout) })
    }

    private func sine(seconds: Double) -> [Float] {
        let frames = Int(seconds * 48_000)
        var out = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            let v = 0.01 * Float(sin(2 * .pi * 997 * Double(f) / 48_000))
            out[f * 2] = v; out[f * 2 + 1] = v
        }
        return out
    }

    private func feed(_ normalizer: LoudnessNormalizer, _ samples: [Float]) {
        var output = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer {
                normalizer.process(input.baseAddress!, into: $0.baseAddress!, frames: samples.count / 2)
            }
        }
    }

    @Test("AUD-202: an infinite sample on a step boundary does not trap the loudness bins")
    func infiniteSampleIsIgnored() {
        let (normalizer, release) = loudnessNormalizer()
        defer { release() }
        var hostile = sine(seconds: 0.4)
        hostile[hostile.count - 2] = .infinity
        feed(normalizer, hostile)
        feed(normalizer, sine(seconds: 3))
        #expect(normalizer.gainDB > 0)
    }

    @Test("AUD-202: a NaN sample does not freeze the measurement for good")
    func nanSampleDoesNotPoisonTheFilter() {
        let (normalizer, release) = loudnessNormalizer()
        defer { release() }
        var hostile = sine(seconds: 0.4)
        hostile[1000] = .nan
        feed(normalizer, hostile)
        feed(normalizer, sine(seconds: 3))
        #expect(normalizer.gainDB > 0)
    }

    // MARK: - NET-205 CLPI fine range

    @Test("NET-205: a coarse entry pointing past the fine table yields no entries instead of trapping")
    func clpiFineRangePastTable() {
        var clpi = BluRayEPMapSeekTests.clpi([(pid: 0x1011, entries: [
            CLPIEntryPoint(pts45k: 0, spn: 0), CLPIEntryPoint(pts45k: 256, spn: 1)])])
        // The first coarse entry starts at 64: ref_to_EP_fine_id 50 and 60, with a fine count of 2.
        clpi.replaceSubrange(64..<68, with: [0x00, 0x0C, 0x80, 0x00])
        clpi.replaceSubrange(72..<76, with: [0x00, 0x0F, 0x00, 0x00])
        #expect(CLPIParser.entryPoints(clpi).isEmpty)
    }

    // MARK: - DMX-202 disc bit rate

    @Test("DMX-202: a huge declared size over a short title falls back instead of trapping")
    func discBitRateOverflow() {
        #expect(Demuxer.discBitRate(sizeBytes: 1 << 62, titleSeconds: 1, fallback: 77) == 77)
        #expect(Demuxer.discBitRate(sizeBytes: Int64.max, titleSeconds: 0.001, fallback: 77) == 77)
        #expect(Demuxer.discBitRate(sizeBytes: 1_000_000, titleSeconds: 8, fallback: 77) == 1_000_000)
    }

    // MARK: - Disc seek targets

    @Test("An infinite or absurd seek target does not trap the DVD time map or the Blu-ray seek table")
    func discSeekTargets() {
        let map = DVDTimeMap(unitSec: 1, titleStartByte: 5, byteOffsets: [10, 20, 30])
        #expect(map.byteOffset(forTitleSeconds: .infinity) == 30)
        #expect(map.byteOffset(forTitleSeconds: 1e300) == 30)
        #expect(map.byteOffset(forTitleSeconds: .nan) == 5)
        #expect(map.byteOffset(forTitleSeconds: 2.5) == 20)

        let table = DiscSeekTable(clips: [.init(concatByteStart: 0, cumulativeBeforeSec: 0, inTimeSec: 0,
                                                entries: [CLPIEntryPoint(pts45k: 0, spn: 1),
                                                          CLPIEntryPoint(pts45k: 45_000, spn: 9)])])
        #expect(table.keyframe(forSourceSeconds: .infinity, base0Sec: 0) == nil)
        #expect(table.keyframe(forSourceSeconds: 1e300, base0Sec: 0)?.offset == Int64(9 * 192))
        #expect(table.keyframe(forSourceSeconds: 5, base0Sec: 0)?.offset == Int64(9 * 192))
        let wrapped = DiscSeekTable(clips: [.init(concatByteStart: Int64.max, cumulativeBeforeSec: 0, inTimeSec: 0,
                                                  entries: [CLPIEntryPoint(pts45k: 0, spn: 1)])])
        #expect(wrapped.keyframe(forSourceSeconds: 0, base0Sec: 0) == nil)
    }

    @Test("Host-declared segment sizes that add past Int64.max do not trap the concatenating reader")
    func concatSizesSaturate() {
        let reader = MultiFileConcatIOReader(
            segments: [.init(path: "a", size: Int64.max), .init(path: "b", size: Int64.max)],
            opener: { _ in nil })
        #expect(reader.seek(offset: 0, whence: 65536) == Int64.max)
    }

    // MARK: - SEG-201 live packet without PTS

    @Test("SEG-201: a live packet without a PTS cuts on its DTS, and one with neither has no time")
    func liveCutTimestampFallsBackToDTS() {
        #expect(HLSSegmentProducer.liveCutTimestamp(pts: 900, dts: 800) == 900)
        #expect(HLSSegmentProducer.liveCutTimestamp(pts: Int64.min, dts: 800) == 800)
        #expect(HLSSegmentProducer.liveCutTimestamp(pts: Int64.min, dts: Int64.min) == nil)
    }

    // MARK: - SUB-207 subtitle index

    @MainActor
    @Test("SUB-207: a subtitle index outside Int32 is ignored on both channels and arms no drain target")
    func subtitleIndexOutsideInt32() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        for index in [Int(Int32.min) - 1, Int(Int32.max) + 1, -5] {
            engine.selectSubtitleTrack(index: index)
            engine.selectSecondarySubtitleTrack(index: index)
        }
        #expect(engine.subtitleDrainTargets.isEmpty)
        #expect(engine.isSubtitleActive == false)
        #expect(engine.isSecondarySubtitleActive == false)
    }

    // MARK: - DEC-201 subtitle and video pixel caps

    @Test("DEC-201: a bitmap canvas seeded from 8K video keeps its size, a seed past the video cap does not")
    func seededSubtitleCanvasFollowsTheVideoCap() throws {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE))
        func openSeeded(width: Int32, height: Int32) throws -> UnsafeMutablePointer<AVCodecContext> {
            let codecpar = try #require(avcodec_parameters_alloc())
            defer { var local: UnsafeMutablePointer<AVCodecParameters>? = codecpar; avcodec_parameters_free(&local) }
            codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            codecpar.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
            return try FFmpegDecoderContext.open(codec: codec, codecpar: codecpar,
                                                 maxPixels: FFmpegDecoderContext.maxSubtitlePixels) { ctx in
                ctx.pointee.width = width
                ctx.pointee.height = height
            }
        }
        var eightK: UnsafeMutablePointer<AVCodecContext>? = try openSeeded(width: 7680, height: 4320)
        defer { avcodec_free_context(&eightK) }
        #expect(eightK?.pointee.width == 7680)
        #expect(eightK?.pointee.height == 4320)
        // avcodec_open2 refuses a size above max_pixels outright (EINVAL), so a hostile seed fails the open.
        #expect(throws: FFmpegDecoderContext.Failure.self) { _ = try openSeeded(width: 16_384, height: 16_384) }
    }

    @Test("DEC-201: a PGS composition of 16000x16000 is refused by the decoder context's pixel cap")
    func hostilePGSCanvasIsRefused() throws {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE))
        let codecpar = try #require(avcodec_parameters_alloc())
        defer { var local: UnsafeMutablePointer<AVCodecParameters>? = codecpar; avcodec_parameters_free(&local) }
        codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        codecpar.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
        let ctx = try FFmpegDecoderContext.open(codec: codec, codecpar: codecpar,
                                                maxPixels: FFmpegDecoderContext.maxSubtitlePixels)
        var owned: UnsafeMutablePointer<AVCodecContext>? = ctx
        defer { avcodec_free_context(&owned) }
        #expect(ctx.pointee.max_pixels == FFmpegDecoderContext.maxSubtitlePixels)

        // PCS (0x16): width, height, frame rate, composition number, state, palette update, palette id, 0 objects. Then END.
        let width = 16_000
        var payload: [UInt8] = [0x16, 0x00, 0x0B,
                                UInt8(width >> 8), UInt8(width & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF),
                                0x10, 0x00, 0x01, 0x80, 0x00, 0x00, 0x00]
        payload += [0x80, 0x00, 0x00]
        var allocated: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&allocated) }
        let packet = try #require(allocated)
        #expect(av_new_packet(packet, Int32(payload.count)) >= 0)
        payload.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: payload.count) }
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        _ = avcodec_decode_subtitle2(ctx, &subtitle, &got, packet)
        avsubtitle_free(&subtitle)
        #expect(ctx.pointee.width != 16_000)
    }

    @Test("DEC-201: a bitmap rect above the subtitle pixel cap yields no image")
    func oversizedBitmapRectIsRefused() {
        var pixels = [UInt8](repeating: 1, count: 16)
        var palette = [UInt8](repeating: 255, count: 1024)
        pixels.withUnsafeMutableBufferPointer { px in
            palette.withUnsafeMutableBufferPointer { pal in
                var rect = AVSubtitleRect()
                rect.type = SUBTITLE_BITMAP
                rect.w = 16_384
                rect.h = 16_000
                rect.data.0 = px.baseAddress
                rect.data.1 = pal.baseAddress
                rect.linesize.0 = 16_384
                withUnsafeMutablePointer(to: &rect) {
                    #expect(EmbeddedSubtitleDecoder.imageForSubtitleRect($0, videoWidth: 1920, videoHeight: 1080) == nil)
                }
            }
        }
    }
}
