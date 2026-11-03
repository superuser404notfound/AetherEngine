import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

// Two-track detection and the base layer's extradata swap, on a format context built in memory, so they run without
// the fixture files the dual-track play tests need.
@Suite("Separate Dolby Vision track detection")
struct SeparateDolbyVisionTrackDetectionTests {

    private struct TrackSpec {
        var width: Int32 = 3840
        var height: Int32 = 2160
        var profile: UInt8 = 7
        var el: UInt8 = 0
        var bl: UInt8 = 1
        var withRecord = true
        var hvccLengthSizeBits: UInt8 = 3  // lengthSizeMinusOne
    }

    /// A 23-byte hvcC header with no arrays; byte 21 carries lengthSizeMinusOne.
    private static func hvcc(lengthSizeMinusOne: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 23)
        b[0] = 1
        b[21] = 0xFC | lengthSizeMinusOne
        return b
    }

    private static func makeContext(format: String, _ specs: [TrackSpec]) -> UnsafeMutablePointer<AVFormatContext> {
        let ctx = avformat_alloc_context()!
        ctx.pointee.iformat = av_find_input_format(format)
        for spec in specs {
            let stream = avformat_new_stream(ctx, nil)!
            let par = stream.pointee.codecpar!
            par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            par.pointee.codec_id = AV_CODEC_ID_HEVC
            par.pointee.width = spec.width
            par.pointee.height = spec.height
            let bytes = hvcc(lengthSizeMinusOne: spec.hvccLengthSizeBits)
            _ = Demuxer.replaceExtradata(of: par, with: bytes)
            guard spec.withRecord else { continue }
            let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            let item = av_packet_side_data_new(&par.pointee.coded_side_data, &par.pointee.nb_coded_side_data,
                                               AV_PKT_DATA_DOVI_CONF, size, 0)!
            memset(item.pointee.data, 0, size)
            item.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_profile = spec.profile
                rec.pointee.el_present_flag = spec.el
                rec.pointee.bl_present_flag = spec.bl
                rec.pointee.rpu_present_flag = 1
            }
        }
        return ctx
    }

    private static func free(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        avformat_free_context(ctx)
    }

    private static let base = TrackSpec()
    private static let enhancement = TrackSpec(width: 1920, height: 1080, el: 1, bl: 0)

    @Test("a Matroska file with a base track and a smaller enhancement track is a split source")
    func detectsTwoTracks() throws {
        let ctx = Self.makeContext(format: "matroska", [Self.base, Self.enhancement])
        defer { Self.free(ctx) }
        let found = try #require(SeparateDolbyVisionLayers.detectTracks(ctx))
        #expect(found == SeparateDolbyVisionLayers(base: 0, enhancement: 1, carriage: .track))
        // The order of the tracks does not matter.
        let swapped = Self.makeContext(format: "mov", [Self.enhancement, Self.base])
        defer { Self.free(swapped) }
        #expect(SeparateDolbyVisionLayers.detectTracks(swapped) == SeparateDolbyVisionLayers(base: 1, enhancement: 0, carriage: .track))
    }

    @Test("sources that are not a linked layer pair are left alone")
    func rejectsOthers() {
        let cases: [(String, [TrackSpec])] = [
            ("matroska", [Self.base]),                                                          // single track
            ("matroska", [Self.base, Self.base]),                                               // two bases
            ("matroska", [Self.base, Self.enhancement, Self.enhancement]),                      // two enhancements
            ("matroska", [Self.base, TrackSpec(width: 1920, height: 1080, withRecord: false)]), // unlinked second track
            ("matroska", [Self.base, TrackSpec(width: 7680, height: 4320, el: 1, bl: 0)]),      // enhancement larger than base
            ("matroska", [TrackSpec(profile: 8), Self.enhancement]),                            // base is not Profile 7
            ("mpegts", [Self.base, Self.enhancement]),                                          // not a track container
        ]
        for (format, specs) in cases {
            let ctx = Self.makeContext(format: format, specs)
            defer { Self.free(ctx) }
            #expect(SeparateDolbyVisionLayers.detectTracks(ctx) == nil, "\(format) \(specs.count) track(s)")
        }
    }

    @Test("the base layer is declared a single-track Profile 7 stream, keeping its own record")
    func declaresProfile7() throws {
        let ctx = Self.makeContext(format: "matroska", [TrackSpec(profile: 7, el: 0, bl: 1), Self.enhancement])
        defer { Self.free(ctx) }
        let stream = try #require(ctx.pointee.streams[0])
        #expect(SeparateDolbyVisionLayers.declareSingleTrackProfile7(stream))
        let par = try #require(stream.pointee.codecpar)
        let rec = par.pointee.coded_side_data[0].data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        #expect(rec.dv_profile == 7 && rec.el_present_flag == 1 && rec.bl_present_flag == 1 && rec.rpu_present_flag == 1)
        #expect(par.pointee.nb_coded_side_data == 1)
    }

    @Test("framing follows the hvcC length size, and only four-byte lengths can be joined")
    func framingFromRecord() throws {
        for (bits, size, joinable) in [(UInt8(3), 4, true), (UInt8(1), 2, false)] {
            let ctx = Self.makeContext(format: "mov", [TrackSpec(hvccLengthSizeBits: bits)])
            defer { Self.free(ctx) }
            let framing = SeparateDolbyVisionLayers.framing(of: try #require(ctx.pointee.streams[0]))
            #expect(framing == .lengthPrefixed(size: size))
            #expect(SeparateDolbyVisionLayers.canJoin(baseFraming: framing) == joinable)
        }
    }

    @Test("swapping the base layer's extradata for a joined record and back restores the original bytes")
    func extradataRoundTrip() throws {
        let ctx = Self.makeContext(format: "matroska", [Self.base, Self.enhancement])
        defer { Self.free(ctx) }
        let par = try #require(ctx.pointee.streams[0]?.pointee.codecpar)
        func bytes() -> [UInt8] { [UInt8](UnsafeBufferPointer(start: par.pointee.extradata, count: Int(par.pointee.extradata_size))) }
        let original = bytes()
        let joined = original + [0xDE, 0xAD, 0xBE, 0xEF]
        #expect(Demuxer.replaceExtradata(of: par, with: joined))
        #expect(bytes() == joined)
        #expect(Demuxer.replaceExtradata(of: par, with: original))
        #expect(bytes() == original)
        // The padding after the bytes is zeroed, as the decoders require.
        #expect(par.pointee.extradata[original.count] == 0)
    }
}
