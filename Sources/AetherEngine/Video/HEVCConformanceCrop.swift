import Foundation

/// Removes the bottom padding crop from a 3840x2176 HEVC sequence parameter set.
///
/// Apple TV (AppleTV18,1, tvOS 27.2.1) restarts about 60 to 160 ms after AVPlayer
/// starts a hardware-decoded HEVC stream whose SPS codes 3840x2176 and crops it to 3840x2160 with a
/// conformance window. Measured on device with one variable changed at a time: the same pictures play
/// once the window's offsets are zero, an ordinary x265 encode reboots as soon as it carries this
/// window, and the level, HRD, SEI, delimiters and coding tools make no difference. With the window
/// gone the decoder hands out all 2176 lines, so the muxer crops the 16 padding lines in the container
/// instead (a `clap` box, which the same device also played).
///
/// Only that one geometry is rewritten. Every other SPS passes through byte for byte.
enum HEVCConformanceCrop {

    /// The SPS with its conformance window offsets set to zero, or nil when the NAL is not a base-layer
    /// SPS of exactly this geometry. `nal` is the raw NAL unit: header first, emulation prevention in
    /// place, no start code and no length prefix.
    static func removingUHDPaddingCrop(fromSPS nal: [UInt8]) -> [UInt8]? {
        guard nal.count > 16, nal[0] == 0x42, nal[1] & 0xF8 == 0, nal[1] & 7 != 0 else { return nil }
        let rbsp = A53SEIParser.unescapeRBSP(Array(nal[2...]))
        var reader = H264SPS.BitReader(rbsp)

        guard reader.skip(4), let maxSubLayersMinus1 = reader.u(3), reader.skip(1) else { return nil }
        // general profile_tier_level: 88 bits of profile, 8 of level.
        guard reader.skip(96) else { return nil }
        if maxSubLayersMinus1 > 0 {
            var profilePresent: [Bool] = []
            var levelPresent: [Bool] = []
            for _ in 0..<maxSubLayersMinus1 {
                guard let profile = reader.u(1), let level = reader.u(1) else { return nil }
                profilePresent.append(profile == 1)
                levelPresent.append(level == 1)
            }
            guard reader.skip(2 * (8 - maxSubLayersMinus1)) else { return nil }
            for index in 0..<maxSubLayersMinus1 {
                if profilePresent[index], !reader.skip(88) { return nil }
                if levelPresent[index], !reader.skip(8) { return nil }
            }
        }
        guard reader.ue() != nil, let chromaFormat = reader.ue() else { return nil }
        // 4:2:0 only: the window's vertical unit is two luma lines there.
        guard chromaFormat == 1 else { return nil }
        guard let width = reader.ue(), let height = reader.ue(),
              width == 3840, height == 2176 else { return nil }
        guard reader.u(1) == 1 else { return nil }
        let offsetsStart = reader.position
        guard let left = reader.ue(), let right = reader.ue(),
              let top = reader.ue(), let bottom = reader.ue(),
              left == 0, right == 0, top == 0, bottom == 8 else { return nil }
        let offsetsEnd = reader.position

        guard let stopBit = reader.lastSetBit, stopBit >= offsetsEnd else { return nil }
        var writer = BitWriter()
        writer.append(rbsp, from: 0, to: offsetsStart)
        // Four ue(v) zeros: the window stays declared and crops nothing.
        for _ in 0..<4 { writer.append(bit: 1) }
        writer.append(rbsp, from: offsetsEnd, to: stopBit)
        writer.append(bit: 1)
        return [nal[0], nal[1]] + escaped(writer.alignedBytes())
    }

    /// A video configuration (an `hvcC` record or Annex-B parameter sets) with the padding crop removed
    /// from every SPS it holds, or nil when it holds none of that geometry.
    static func removingUHDPaddingCrop(fromConfiguration bytes: [UInt8]) -> [UInt8]? {
        if bytes.first == 1 { return rewritingRecord(bytes) }
        return bytes.withUnsafeBytes { removingUHDPaddingCrop(fromAnnexB: $0) }
    }

    /// An Annex-B buffer with the padding crop removed from every SPS it holds, or nil when it holds
    /// none of that geometry. Start codes come out four bytes long.
    static func removingUHDPaddingCrop(fromAnnexB bytes: UnsafeRawBufferPointer) -> [UInt8]? {
        let ranges = AnnexB.nalRanges(bytes)
        return removingUHDPaddingCrop(fromAnnexB: bytes, ranges: ranges)
    }

    /// As above, with the NAL ranges the caller already scanned.
    static func removingUHDPaddingCrop(fromAnnexB bytes: UnsafeRawBufferPointer,
                                       ranges: [Range<Int>]) -> [UInt8]? {
        var replacements: [Int: [UInt8]] = [:]
        for (index, range) in ranges.enumerated() where bytes[range.lowerBound] == 0x42 {
            if let sps = removingUHDPaddingCrop(fromSPS: [UInt8](bytes[range])) {
                replacements[index] = sps
            }
        }
        guard !replacements.isEmpty else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + ranges.count)
        for (index, range) in ranges.enumerated() {
            out.append(contentsOf: [0, 0, 0, 1])
            if let sps = replacements[index] {
                out.append(contentsOf: sps)
            } else {
                out.append(contentsOf: bytes[range])
            }
        }
        return out
    }

    /// The bottom crop the SPS window carried, in luma lines. The muxer writes it as a `clap` box.
    static let paddingLines = 16

    /// A length-prefixed sample (an `hev1` or Matroska source) with the padding crop removed from every
    /// in-band SPS, or nil when it holds none of that geometry or its length chain does not add up.
    static func removingUHDPaddingCrop(fromLengthPrefixed bytes: UnsafeRawBufferPointer,
                                       prefixSize: Int) -> [UInt8]? {
        guard (1...4).contains(prefixSize) else { return nil }
        var units: [(range: Range<Int>, sps: [UInt8]?)] = []
        var cursor = 0
        while cursor < bytes.count {
            guard cursor + prefixSize <= bytes.count else { return nil }
            var length = 0
            for index in 0..<prefixSize { length = length << 8 | Int(bytes[cursor + index]) }
            cursor += prefixSize
            guard length > 0, length <= bytes.count - cursor else { return nil }
            let range = cursor..<cursor + length
            let sps = bytes[cursor] == 0x42 ? removingUHDPaddingCrop(fromSPS: [UInt8](bytes[range])) : nil
            units.append((range, sps))
            cursor += length
        }
        guard units.contains(where: { $0.sps != nil }) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + units.count)
        for unit in units {
            let nal = unit.sps ?? [UInt8](bytes[unit.range])
            guard nal.count < 1 << (8 * prefixSize) else { return nil }
            for index in (0..<prefixSize).reversed() { out.append(UInt8(truncatingIfNeeded: nal.count >> (8 * index))) }
            out.append(contentsOf: nal)
        }
        return out
    }

    private static func rewritingRecord(_ record: [UInt8]) -> [UInt8]? {
        let walk = record.withUnsafeBufferPointer { VideoConfigRecord.hvccArrays($0) }
        guard walk.isComplete, walk.end == record.count else { return nil }
        var out = [UInt8](record[0..<23])
        var changed = false
        for array in walk.arrays {
            out.append(contentsOf: record[array.header])
            for range in array.nals {
                var nal = [UInt8](record[range])
                if array.type == 33, let sps = removingUHDPaddingCrop(fromSPS: nal) {
                    nal = sps
                    changed = true
                }
                // The rewrite re-escapes and can grow the NAL past the 16-bit record field (audit BIT-202).
                guard nal.count <= 0xFFFF else { return nil }
                out.append(UInt8(nal.count >> 8))
                out.append(UInt8(nal.count & 0xFF))
                out.append(contentsOf: nal)
            }
        }
        return changed ? out : nil
    }

    private static func escaped(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    private struct BitWriter {
        private var bytes: [UInt8] = []
        private var count = 0

        mutating func append(bit: UInt8) {
            if count & 7 == 0 { bytes.append(0) }
            if bit != 0 { bytes[count >> 3] |= 0x80 >> UInt8(count & 7) }
            count += 1
        }

        mutating func append(_ source: [UInt8], from start: Int, to end: Int) {
            for position in start..<end {
                append(bit: source[position >> 3] >> (7 - UInt8(position & 7)) & 1)
            }
        }

        /// The bits written so far, zero-padded to a whole byte.
        func alignedBytes() -> [UInt8] { bytes }
    }
}
