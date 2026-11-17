import Foundation
import Testing
@testable import AetherEngine

// BIT-R201: one Annex-B scanner, empty NALs dropped everywhere.
@Suite("Annex-B NAL scanner")
struct AnnexBScannerTests {
    /// Back-to-back start codes around an empty NAL, leading garbage, and trailing zeros.
    private static let hostile: [UInt8] =
        [0x55, 0xAA]
        + [0, 0, 0, 1, 0, 0, 0, 1]
        + [0x40, 0x01, 0xAA, 0, 0]
        + [0, 0, 1, 0, 0, 1]
        + [0x42, 0x01, 0xBB, 0, 0, 0]

    @Test("nalRanges drops empty NALs, trims zeros and skips leading bytes", .timeLimit(.minutes(3)))
    func rangesDropEmpty() {
        let ranges = AnnexB.nalRanges(Self.hostile)
        let nals = ranges.map { Array(Self.hostile[$0]) }
        #expect(nals == [[0x40, 0x01, 0xAA], [0x42, 0x01, 0xBB]])
    }

    @Test("forEachNAL never hands out an empty NAL", .timeLimit(.minutes(3)))
    func forEachNALSkipsEmpty() {
        var sizes: [Int] = []
        Self.hostile.withUnsafeBufferPointer { buf in
            A53SEIParser.forEachNAL(buf.baseAddress!, buf.count, .annexB) { _, len in sizes.append(len) }
        }
        #expect(sizes == [3, 3])
    }

    @Test("compose writes no length-0 unit for back-to-back start codes", .timeLimit(.minutes(3)))
    func composeHasNoEmptyUnit() {
        let out = Self.hostile.withUnsafeBytes {
            DolbyVisionLayerUnits.compose(base: $0, baseFraming: .annexB, enhancement: nil, enhancementFraming: .annexB)
        }
        var offset = 0
        var lengths: [Int] = []
        while offset + 4 <= out.count {
            let len = out[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            lengths.append(len)
            offset += 4 + len
        }
        #expect(lengths == [3, 3])
        #expect(offset == out.count)
    }

    @Test("the other scanners agree with it", .timeLimit(.minutes(3)))
    func otherScannersAgree() {
        #expect(VideoConfigRecord.splitAnnexBNALs(Self.hostile) == [[0x40, 0x01, 0xAA], [0x42, 0x01, 0xBB]])
        let rpuUnit: [UInt8] = [0, 0, 1, 0, 0, 1, 0x7C, 0x01, 0x19, 0xFF, 0, 0]
        let rpu = rpuUnit.withUnsafeBytes { BluRayDolbyVisionLayers.rpu(inAnnexB: $0) }
        #expect(rpu == [0, 0, 1, 0x7C, 0x01, 0x19, 0xFF])
    }
}
