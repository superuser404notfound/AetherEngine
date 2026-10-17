// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import Dovi
@testable import AetherEngine

/// An RPU whose enhancement layer is not 10-bit is refused (the composer then falls back to the base layer),
/// the same as one whose base layer is not 10-bit.
struct DoviElBitDepthTests {

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = c & 0x8000_0000 != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    private static func unescape(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](), zeros = 0
        for x in b {
            if zeros >= 2 && x == 3 { zeros = 0; continue }
            out.append(x)
            zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Rewrites the CRC of an unescaped RPU (header 7C 01, payload, CRC32, 0x80) after a mutation.
    private static func repairCrc(_ u: inout [UInt8]) {
        let tailAt = u.count - 5
        var crc: UInt32 = 0xFFFF_FFFF
        for i in 3..<tailAt { crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(u[i]))] }
        u[tailAt] = UInt8(crc >> 24); u[tailAt + 1] = UInt8((crc >> 16) & 0xFF)
        u[tailAt + 2] = UInt8((crc >> 8) & 0xFF); u[tailAt + 3] = UInt8(crc & 0xFF)
    }

    private static func header(_ nal: [UInt8]) -> (bl: Int, el: Int, vdr: Int)? {
        // Through the guard: a mutated stream can reach paths in libdovi that abort the process.
        guard let rpu = nal.withUnsafeBufferPointer({ DoviRpuGuard.parse($0.baseAddress!, $0.count) }) else { return nil }
        defer { dovi_rpu_free(rpu) }
        guard dovi_rpu_get_error(rpu) == nil, let h = dovi_rpu_get_header(rpu) else { return nil }
        defer { dovi_rpu_free_header(h) }
        return (Int(h.pointee.bl_bit_depth_minus8) + 8, Int(h.pointee.el_bit_depth_minus8) + 8, Int(h.pointee.vdr_bit_depth_minus8) + 8)
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
    }

    /// The header codes el_bit_depth_minus8 = 2 as the exp-Golomb string 011; flipping its last bit gives 010,
    /// which is el_bit_depth_minus8 = 1 (9-bit) in the same number of bits, so nothing after it shifts. Find that
    /// bit by trying the first bytes and keeping the flip libdovi reports as an el_bit_depth error.
    private static func rpuWithNineBitEl(from hex: String) -> [UInt8]? {
        let base = unescape(bytes(hex))
        guard let original = header(bytes(hex)), original.el == 10 else { return nil }
        for byte in 3..<min(24, base.count - 5) {
            for bit in 0..<8 {
                var m = base
                m[byte] ^= UInt8(1 << bit)
                repairCrc(&m)
                let escaped = DoviCrcValidFuzzTests.escape(m)
                // Through the guard: a mutated stream can reach paths in libdovi that abort the process.
                guard let rpu = escaped.withUnsafeBufferPointer({ DoviRpuGuard.parse($0.baseAddress!, $0.count) }) else { continue }
                defer { dovi_rpu_free(rpu) }
                if let e = dovi_rpu_get_error(rpu), String(cString: e).contains("el_bit_depth_minus8") { return escaped }
            }
        }
        return nil
    }

    @Test("the real RPUs carry a 10-bit EL and are accepted",
          arguments: [DoviFelMathTests.clipARpuHex, DoviFelMathTests.clipCRpuHex])
    func tenBitElIsAccepted(hex: String) throws {
        let nal = Self.bytes(hex)
        let rpu = try #require(dovi_parse_unspec62_nalu(nal, nal.count))
        defer { dovi_rpu_free(rpu) }
        #expect(DoviFelComposer.parseRpuParameters(rpu: rpu) != nil)
    }

    /// The composer's own depth check, reached directly: libdovi never hands it an RPU that gets this far.
    @Test("only a 10-bit base layer with a 10-bit enhancement layer passes the composer's depth check")
    func layerDepthCheck() {
        #expect(DoviFelComposer.layerBitDepthsSupported(bl: 10, el: 10))
        #expect(!DoviFelComposer.layerBitDepthsSupported(bl: 10, el: 9))
        #expect(!DoviFelComposer.layerBitDepthsSupported(bl: 10, el: 12))
        #expect(!DoviFelComposer.layerBitDepthsSupported(bl: 8, el: 10))
    }

    /// libdovi 3.4 itself rejects `el_bit_depth_minus8 != 2` ("should be 2") for a Profile 7 RPU, and reports 2
    /// for a converted 8.1 one, so no RPU it accepts reaches the composer's own EL check today (`layerDepthCheck` covers
    /// that check). This pins the end-to-end behaviour:
    /// the composer gets no parameters, so the caller presents the base layer.
    @Test("a Profile 7 RPU with a 9-bit EL (everything else unchanged) is refused",
          arguments: [DoviFelMathTests.clipARpuHex, DoviFelMathTests.clipCRpuHex])
    func nonTenBitElIsRefused(hex: String) throws {
        let nal = try #require(Self.rpuWithNineBitEl(from: hex), "could not craft a 9-bit-EL variant")
        let rpu = try #require(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) })
        defer { dovi_rpu_free(rpu) }
        #expect(dovi_rpu_get_error(rpu) != nil, "libdovi should flag the EL depth")
        #expect(DoviFelComposer.parseRpuParameters(rpu: rpu) == nil)
    }
}
#endif
