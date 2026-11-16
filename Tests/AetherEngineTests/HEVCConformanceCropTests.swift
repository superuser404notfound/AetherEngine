// Apple TV (AppleTV18,1, tvOS 27.2.1) restarts on hardware-decoded HEVC coded 3840x2176 and cropped to
// 2160 by a conformance window. The native tvOS remux clears that window and crops with a clap box
// instead; everything else passes.
//
// The SPS bytes are from the recording that reproduced the restart. `cropFree` is what FFmpeg's
// hevc_metadata filter writes for the same SPS with crop_bottom=0, which played on the device.
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("3840x2176 HEVC loses its padding crop in the tvOS native remux")
struct HEVCConformanceCropTests {

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(hex.dropFirst($0).prefix(2), radix: 16) }
    }

    private var cropped: [UInt8] {
        bytes("420101016000000300900000030000030099a001e02002207c4e595529084645d50c05a808080820000003002000"
              + "00064c00bbca20000e4e1c00007270e080")
    }
    private var cropFree: [UInt8] {
        bytes("420101016000000300900000030000030099a001e02002207f96554a4211917543016a020202080000030008000"
              + "0030193002ef2880003938700001c9c3820")
    }
    /// 3840x2160 with no conformance window (x265).
    private var uncropped2160: [UInt8] {
        bytes("420101016000000300900000030000030099a001e020021c59644d29349c05a808080f080000030008000003019040")
    }
    private let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01]
    private let pps: [UInt8] = [0x44, 0x01, 0xC0, 0x72]
    private let idr: [UInt8] = [0x26, 0x01, 0xAF, 0x08]

    private func record(_ sps: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 23)
        out[0] = 1
        out[22] = 3
        for (type, nal) in [(UInt8(32), vps), (33, sps), (34, pps)] {
            out += [0x80 | type, 0, 1, UInt8(nal.count >> 8), UInt8(nal.count & 0xFF)] + nal
        }
        return out
    }

    @Test("The SPS matches FFmpeg's crop-free rewrite and is stable on a second pass")
    func rewritesSPS() {
        #expect(HEVCConformanceCrop.removingUHDPaddingCrop(fromSPS: cropped) == cropFree)
        #expect(HEVCConformanceCrop.removingUHDPaddingCrop(fromSPS: cropFree) == nil)
    }

    @Test("Other geometries, other NAL types and damaged headers pass untouched")
    func leavesOthersAlone() {
        #expect(HEVCConformanceCrop.removingUHDPaddingCrop(fromSPS: uncropped2160) == nil)
        #expect(HEVCConformanceCrop.removingUHDPaddingCrop(fromSPS: Array(cropped.prefix(20))) == nil)
        #expect(HEVCConformanceCrop.removingUHDPaddingCrop(fromSPS: pps) == nil)
        #expect(HEVCConformanceCrop.removingUHDPaddingCrop(fromConfiguration: record(uncropped2160)) == nil)
    }

    @Test("hvcC records and Annex-B configurations are both rewritten")
    func rewritesConfigurations() {
        #expect(HEVCConformanceCrop.removingUHDPaddingCrop(fromConfiguration: record(cropped)) == record(cropFree))
        let annexB: [UInt8] = [0, 0, 0, 1] + vps + [0, 0, 1] + cropped + [0, 0, 0, 1] + pps
        let expected: [UInt8] = [0, 0, 0, 1] + vps + [0, 0, 0, 1] + cropFree + [0, 0, 0, 1] + pps
        #expect(HEVCConformanceCrop.removingUHDPaddingCrop(fromConfiguration: annexB) == expected)
    }

    @Test("An in-band cropped SPS is replaced and every other NAL is kept")
    func replacesInBandCopy() throws {
        let sample: [UInt8] = [vps, cropped, pps, idr].flatMap { [0, 0, 1] + $0 }
        var packet: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let pkt = try #require(packet)
        try #require(av_new_packet(pkt, Int32(sample.count)) == 0)
        sample.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress, sample.count) }
        #expect(AnnexBSampleConverter.convertToLengthPrefixed(pkt, removeUHDPaddingCrop: true))
        let out = Array(UnsafeBufferPointer(start: pkt.pointee.data, count: Int(pkt.pointee.size)))
        let expected: [UInt8] = [vps, cropFree, pps, idr].flatMap { [0, 0, 0, UInt8($0.count)] + $0 }
        #expect(out == expected)
    }

    @Test("A length-prefixed sample (hev1, Matroska) loses the crop from its in-band SPS too")
    func rewritesLengthPrefixedSample() {
        func chain(_ units: [[UInt8]], width: Int) -> [UInt8] {
            units.flatMap { unit in (0..<width).reversed().map { UInt8(truncatingIfNeeded: unit.count >> (8 * $0)) } + unit }
        }
        for width in [2, 4] {
            let sample = chain([vps, cropped, pps, idr], width: width)
            let rewritten = sample.withUnsafeBytes {
                HEVCConformanceCrop.removingUHDPaddingCrop(fromLengthPrefixed: $0, prefixSize: width)
            }
            #expect(rewritten == chain([vps, cropFree, pps, idr], width: width))
        }
        let clean = chain([vps, uncropped2160, idr], width: 4)
        #expect(clean.withUnsafeBytes { HEVCConformanceCrop.removingUHDPaddingCrop(fromLengthPrefixed: $0, prefixSize: 4) } == nil)
        let broken = Array(chain([cropped, idr], width: 4).dropLast())
        #expect(broken.withUnsafeBytes { HEVCConformanceCrop.removingUHDPaddingCrop(fromLengthPrefixed: $0, prefixSize: 4) } == nil)
    }

    // A real x265 VPS and PPS (from ShortHEVCHeaderTests' fixture), so movenc can parse the record.
    private let realVPS: [UInt8] = [0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90,
                                    0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x1E, 0x95, 0x98, 0x09]
    private let realPPS: [UInt8] = [0x44, 0x01, 0xC1, 0x72, 0xB4, 0x22, 0x40]

    private func codecpar(extradata: [UInt8], codec: AVCodecID = AV_CODEC_ID_HEVC) throws -> UnsafeMutablePointer<AVCodecParameters> {
        let par = try #require(avcodec_parameters_alloc())
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = codec
        par.pointee.width = 3840
        par.pointee.height = 2160
        let buffer = try #require(av_mallocz(extradata.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
        extradata.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress!, extradata.count) }
        par.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
        par.pointee.extradata_size = Int32(extradata.count)
        return par
    }

    private func hvcC(vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 23)
        out[0] = 1
        out[21] = 0x0F
        out[22] = 3
        for (type, nal) in [(UInt8(32), vps), (33, sps), (34, pps)] {
            out += [0x80 | type, 0, 1, UInt8(nal.count >> 8), UInt8(nal.count & 0xFF)] + nal
        }
        return out
    }

    @Test("The muxer reads the override before the source, and only when the config asks for it")
    func muxerChoosesTheConfiguration() throws {
        var source: UnsafeMutablePointer<AVCodecParameters>? = try codecpar(extradata: record(cropped))
        defer { avcodec_parameters_free(&source) }
        let timeBase = AVRational(num: 1, den: 90_000)
        func config(override: [UInt8]? = nil, enabled: Bool = true) -> MP4SegmentMuxer.VideoConfig {
            .init(codecpar: UnsafePointer(source!), timeBase: timeBase, codecTagOverride: "hvc1",
                  extradataOverride: override, clearsUHDPaddingCrop: enabled)
        }
        #expect(MP4SegmentMuxer.cropFreeConfiguration(for: config()) == record(cropFree))
        #expect(MP4SegmentMuxer.cropFreeConfiguration(for: config(override: record(uncropped2160))) == nil)
        #expect(MP4SegmentMuxer.cropFreeConfiguration(for: config(enabled: false)) == nil)
        var h264: UnsafeMutablePointer<AVCodecParameters>? = try codecpar(extradata: record(cropped), codec: AV_CODEC_ID_H264)
        defer { avcodec_parameters_free(&h264) }
        let h264Config = MP4SegmentMuxer.VideoConfig(codecpar: UnsafePointer(h264!), timeBase: timeBase,
                                                     codecTagOverride: nil, clearsUHDPaddingCrop: true)
        #expect(MP4SegmentMuxer.cropFreeConfiguration(for: h264Config) == nil)
        #expect(MP4SegmentMuxer.VideoConfig(codecpar: UnsafePointer(source!), timeBase: timeBase, codecTagOverride: nil)
            .clearsUHDPaddingCrop == MP4SegmentMuxer.VideoConfig.clearsUHDPaddingCropByDefault)
    }

    private final class InitBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func set(_ data: Data) { lock.withLock { bytes = data } }
        func get() -> Data { lock.withLock { bytes } }
    }

    @Test("The init segment carries the crop-free SPS, 2176 lines and a tvOS-signed clap of 2160; so does the sample")
    func muxerWritesCropFreeStreamWithClap() throws {
        var source: UnsafeMutablePointer<AVCodecParameters>? = try codecpar(extradata: hvcC(vps: realVPS, sps: cropped, pps: realPPS))
        defer { avcodec_parameters_free(&source) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("uhd-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = InitBytes()
        let muxer = try MP4SegmentMuxer(initialSegmentIndex: 0, sessionDir: directory,
            video: .init(codecpar: UnsafePointer(source!), timeBase: AVRational(num: 1, den: 90_000),
                         codecTagOverride: "hvc1", nalFramingLatch: NALFramingLatch(confirmed: true),
                         clearsUHDPaddingCrop: true),
            audio: nil, onInitCaptured: { initial.set($0) })

        func lengthPrefixed(_ units: [[UInt8]]) -> [UInt8] {
            units.flatMap { [0, 0, UInt8($0.count >> 8), UInt8($0.count & 0xFF)] + $0 }
        }
        let sample = lengthPrefixed([cropped, idr])
        var packet: UnsafeMutablePointer<AVPacket>? = try #require(trackedPacketAlloc())
        defer { trackedPacketFree(&packet) }
        #expect(av_new_packet(packet!, Int32(sample.count)) >= 0)
        sample.withUnsafeBytes { _ = memcpy(packet!.pointee.data!, $0.baseAddress!, $0.count) }
        packet!.pointee.pts = 0; packet!.pointee.dts = 0; packet!.pointee.duration = 1800
        packet!.pointee.flags = AV_PKT_FLAG_KEY
        packet!.pointee.stream_index = muxer.videoOutputStreamIndex
        #expect(muxer.writePacket(packet!).rc >= 0)
        guard case .completed(let path, _) = muxer.cutFragmentForNextSegment(1) else {
            Issue.record("No fragment was written")
            return
        }
        let fragment = try Data(contentsOf: path)
        let initSegment = initial.get()
        // 3840x2160 with a vertical offset of +8: the sign tvOS needs, the opposite of the spec's.
        let clapAt = try #require(initSegment.range(of: Data("clap".utf8)))
        let clapWords = (0..<8).map { index in
            initSegment[clapAt.upperBound + index * 4 ..< clapAt.upperBound + index * 4 + 4]
                .reduce(Int32(0)) { $0 << 8 | Int32($1) }
        }
        #expect(clapWords == [3840, 1, 2160, 1, 0, 1, 8, 1])
        #expect(initSegment.range(of: Data(cropFree)) != nil)
        #expect(initSegment.range(of: Data(cropped)) == nil)

        let result = Demuxer()
        defer { result.close() }
        try result.open(reader: DataIOReader(data: initSegment + fragment), formatHint: "mp4")
        let stream = try #require(result.stream(at: result.videoStreamIndex))
        #expect(stream.pointee.codecpar.pointee.height == 2176)
        let crop = try #require(av_packet_side_data_get(stream.pointee.codecpar.pointee.coded_side_data,
                                                        stream.pointee.codecpar.pointee.nb_coded_side_data,
                                                        AV_PKT_DATA_FRAME_CROPPING))
        let cropWords = (0..<4).map { index in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(crop.pointee.data[index * 4 + $1]) << (8 * $1) }
        }
        #expect(cropWords == [16, 0, 0, 0])
        var written: UnsafeMutablePointer<AVPacket>? = try #require(try result.readPacket())
        defer { trackedPacketFree(&written) }
        let writtenBytes = Array(UnsafeBufferPointer(start: written!.pointee.data, count: Int(written!.pointee.size)))
        #expect(writtenBytes == lengthPrefixed([cropFree, idr]))
    }
}
