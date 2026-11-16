// Apple TV (AppleTV18,1, tvOS 27.2.1) restarts on hardware-decoded HEVC coded 3840x2176 and cropped to
// 2160 by a conformance window. The native tvOS remux clears that window; everything else passes.
//
// The SPS bytes are from the recording that reproduced the restart. `cropFree` is what FFmpeg's
// hevc_metadata filter writes for the same SPS with crop_bottom=0, which played on the device.
import Foundation
import Testing
import AetherLibavcodec
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
}
