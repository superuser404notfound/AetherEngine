import Foundation
import Testing

@testable import AetherEngine

@Suite("Truncated HEVC header at a transport-stream tail")
struct ShortHEVCHeaderTests {
    private func unit(_ bytes: [UInt8], width: Int = 4) -> [UInt8] {
        (0..<width).reversed().map { UInt8((bytes.count >> ($0 * 8)) & 0xff) } + bytes
    }
    private func ranges(_ bytes: [UInt8], width: Int = 4, confirmed: Bool = true) -> [Range<Int>] {
        bytes.withUnsafeBytes {
            NALUnitChain.shortHEVCHeaderRanges($0, lengthPrefixSize: width, framingConfirmed: confirmed)
        }
    }

    @Test("A complete length chain can still contain a truncated EOS header")
    func damagedEOSIsRemovedWithoutLosingThePictureOrFollowingRPU() {
        let picture = unit([0x26, 0x01, 0x80])
        let eos = unit([0x48])
        let rpu = unit([0x7c, 0x01, 0x80])
        let sample = picture + eos + rpu
        #expect(
            sample.withUnsafeBytes { NALUnitChain.completeRunLength($0, lengthPrefixSize: 4, framingConfirmed: true) }
                == nil)
        #expect(ranges(sample) == [picture.count..<(picture.count + eos.count)])
        let removed = ranges(sample)
        let cleaned = sample.enumerated().filter { entry in
            !removed.contains { $0.contains(entry.offset) }
        }.map(\.element)
        #expect(cleaned == picture + rpu)
    }

    @Test("Valid HEVC delimiters and pictures remain byte-for-byte unchanged")
    func validUnitsSurvive() {
        #expect(ranges(unit([0x26, 0x01, 0x80]) + unit([0x48, 0x01, 0x80])) == [])
    }

    @Test("Framing and bounds fail closed, and all prefix widths are supported")
    func framingBoundsAndWidths() {
        #expect(ranges([0, 0, 0, 1, 0x48], confirmed: false) == [])
        #expect(ranges(unit([0x48]) + [0, 0, 2]) == [])
        for width in 1...4 { #expect(ranges(unit([0x48], width: width), width: width) == [0..<(width + 1)]) }
    }
}
