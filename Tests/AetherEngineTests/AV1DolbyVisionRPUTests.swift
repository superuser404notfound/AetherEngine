import Testing
import Foundation
import CoreMedia
import CoreVideo
import IOSurface
import Dovi
@testable import AetherEngine

/// AV1 Dolby Vision 10.1: the RPU a temporal unit carries in its ITU-T T.35 metadata OBU, rewrapped into
/// the payload VideoToolbox attaches to an HEVC 8.1 frame, carried from packet to frame by presentation
/// time, and attached to the frame under the two keys tvOS's compositor reads.
struct AV1DolbyVisionRPUTests {

    /// First `unspec62` NAL of a real Profile 8.1 remux (139 B), the one `DolbyVisionRecordAuditTests` pins.
    /// An AV1 10.1 RPU is an 8.1 RPU in another wrapper, so libdovi writes it as the T.35 OBU of a 10.1 encode.
    private static let profile81NAL = bytes(
        "7c0119080908406136506f003ff801ffc00fffd000000800000680000040000034000003" +
        "0200000301a2566000035ea2566f9fceb1c256644ca00000100000030080000003008000" +
        "000301c36224301860a5e308e0514000001a63e5affff000000300000300000300060200" +
        "f80e1530100a0000030000030000030024180fa000040fa00640a3c503f380")

    private static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private static func leb128(_ value: Int) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    /// An OBU_METADATA (type 5, with a size field) of `metadata_type` ITU-T T.35 (4) around `t35`, which
    /// runs from `itu_t_t35_country_code` on.
    private static func t35OBU(_ t35: [UInt8]) -> [UInt8] {
        let body = [0x04] + t35
        return [0x2A] + leb128(body.count) + body
    }

    private static let temporalDelimiter: [UInt8] = [0x12, 0x00]

    /// A temporal unit as a 10.1 encode carries it, and the payload the route must make of it: libdovi's
    /// `unspec62` NAL of the same RPU minus its two header bytes, the form VideoToolbox attaches.
    private static func temporalUnit() throws -> (unit: [UInt8], expected: [UInt8]) {
        let nal = profile81NAL
        let rpu = try #require(dovi_parse_unspec62_nalu(nal, nal.count))
        defer { dovi_rpu_free(rpu) }
        let t35 = try #require(dovi_write_av1_rpu_metadata_obu_t35_complete(rpu))
        defer { dovi_data_free(t35) }
        let unspec62 = try #require(dovi_write_unspec62_nalu(rpu))
        defer { dovi_data_free(unspec62) }
        let unit = temporalDelimiter + t35OBU(Array(UnsafeBufferPointer(start: t35.pointee.data, count: Int(t35.pointee.len))))
        let expected = Array(UnsafeBufferPointer(start: unspec62.pointee.data + 2, count: Int(unspec62.pointee.len) - 2))
        return (unit, expected)
    }

    private static func payload(_ unit: [UInt8]) -> Data? {
        unit.withUnsafeBufferPointer { AV1DolbyVisionRPU.attachmentPayload(temporalUnit: $0.baseAddress!, size: $0.count) }
    }

    @Test("the T.35 RPU of a temporal unit comes out as the unspec62 payload VideoToolbox attaches")
    func rewrapsTheT35RPU() throws {
        let (unit, expected) = try Self.temporalUnit()
        let payload = Self.payload(unit)
        #expect(payload.map(Array.init) == expected)
        #expect(payload?.first == 0x19, "the payload starts at the RPU prefix, the NAL header stripped")
    }

    @Test("an OBU before the metadata, or another provider's T.35 OBU (HDR10+ is T.35 too), is passed over")
    func passesOverOtherOBUs() throws {
        let (unit, expected) = try Self.temporalUnit()
        // HDR10+: country 0xB5, provider 0x003C, provider-oriented code 0x0001, application identifier 4.
        let hdr10Plus = Self.t35OBU([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01, 0x40, 0x00])
        #expect(Self.payload(Self.temporalDelimiter + hdr10Plus) == nil)
        let withHDR10PlusFirst = Self.temporalDelimiter + hdr10Plus + unit.dropFirst(Self.temporalDelimiter.count)
        #expect(Self.payload(Array(withHDR10PlusFirst)).map(Array.init) == expected)
    }

    @Test("a temporal unit without the metadata OBU, or with a size that overruns it, yields no RPU")
    func yieldsNothingWithoutAnRPU() {
        // Temporal delimiter, then an OBU_FRAME (type 6) of three bytes.
        #expect(Self.payload(Self.temporalDelimiter + [0x32, 0x03, 0x01, 0x02, 0x03]) == nil)
        // An OBU_METADATA claiming 64 bytes with two left.
        #expect(Self.payload(Self.temporalDelimiter + [0x2A, 0x40, 0x04, 0xB5]) == nil)
    }

    /// The T.35 payload libdovi writes for `profile81NAL`, from `itu_t_t35_country_code` on.
    private static func t35Payload() throws -> [UInt8] {
        let nal = profile81NAL
        let rpu = try #require(dovi_parse_unspec62_nalu(nal, nal.count))
        defer { dovi_rpu_free(rpu) }
        let t35 = try #require(dovi_write_av1_rpu_metadata_obu_t35_complete(rpu))
        defer { dovi_data_free(t35) }
        return Array(UnsafeBufferPointer(start: t35.pointee.data, count: Int(t35.pointee.len)))
    }

    @Test("the guard takes the RPU out of its EMDF container as libdovi does, CRC and final byte intact")
    func guardUnwrapsTheEMDFContainer() throws {
        let t35 = try Self.t35Payload()
        let rpu = try #require(t35.withUnsafeBufferPointer { DoviRpuGuard.av1RPU($0.baseAddress!, $0.count) })
        let unescaped = try #require(Self.profile81NAL.withUnsafeBufferPointer {
            DoviRpuGuard.verifiedUnescaped($0.baseAddress!, $0.count)
        })
        #expect(rpu == Array(unescaped.dropFirst(2)))
    }

    @Test("a corrupt RPU never reaches libdovi, which is built panic=abort")
    func refusesACorruptRPU() throws {
        let t35 = try Self.t35Payload()
        // One flipped bit in the middle of the RPU body: the CRC32 catches every single-bit error.
        var corrupt = t35
        corrupt[t35.count / 2] ^= 0x10
        #expect(corrupt.withUnsafeBufferPointer { DoviRpuGuard.av1RPU($0.baseAddress!, $0.count) } != nil,
                "the container still parses")
        #expect(corrupt.withUnsafeBufferPointer { DoviRpuGuard.parseAV1($0.baseAddress!, $0.count) } == nil)
        #expect(Self.payload(Self.temporalDelimiter + Self.t35OBU(corrupt)) == nil)
        // An EMDF payload size that overruns what is left.
        let truncated = Array(t35.prefix(40))
        #expect(truncated.withUnsafeBufferPointer { DoviRpuGuard.av1RPU($0.baseAddress!, $0.count) } == nil)
    }

    @Test("an RPU reaches the frame of its presentation time, once, and a flush drops what is left")
    func carriesTheRPUByPresentationTime() throws {
        let (unit, expected) = try Self.temporalUnit()
        let table = AV1DolbyVisionRPUTable(logPrefix: "[AV1DolbyVisionRPUTests]")
        let pts = CMTime(value: 1001, timescale: 24000)
        unit.withUnsafeBufferPointer { table.store(temporalUnit: $0.baseAddress!, size: $0.count, pts: pts) }
        #expect(table.take(for: CMTime(value: 2002, timescale: 24000)) == nil, "another frame's time gets none")
        #expect(table.take(for: pts).map(Array.init) == expected)
        #expect(table.take(for: pts) == nil, "taken once")
        unit.withUnsafeBufferPointer { table.store(temporalUnit: $0.baseAddress!, size: $0.count, pts: pts) }
        table.removeAll()
        #expect(table.take(for: pts) == nil)
    }

    private static func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        #expect(status == kCVReturnSuccess)
        let b = try #require(buffer)
        #expect(CVPixelBufferGetIOSurface(b) != nil, "the buffer must be IOSurface-backed")
        return b
    }

    private static func surfaceValue(_ buffer: CVPixelBuffer, _ key: String) -> CFTypeRef? {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        return IOSurfaceCopyValue(surface, key as CFString)
    }

    @Test("a failed owned copy cannot set or clear RPU metadata on the decoder's original",
          arguments: [false, true])
    func copyFailurePreservesOriginal(clearsRPU: Bool) throws {
        let original = try Self.makeBuffer()
        let previousRPU = Data([0x19, 0x08, 0x09, 0xAA])
        AV1DolbyVisionRPUTable.attach(previousRPU, to: original)
        let requestedRPU: Data? = clearsRPU ? nil : Data([0x19, 0x08, 0x09, 0xBB])
        var copyCalls = 0
        let result = AV1DolbyVisionRPUTable.attachingToOwnedOutput(
            requestedRPU, normalized: original, original: original,
            copyOriginal: { source in
                #expect(source === original)
                copyCalls += 1
                return nil
            })
        #expect(result === original)
        #expect(copyCalls == 1)
        let rpuKey = DoviDisplayMetadata.rpuDataKey, idKey = DoviDisplayMetadata.compatibilityIDKey
        #expect(CVBufferCopyAttachment(original, rpuKey as CFString, nil) as? Data == previousRPU)
        #expect(Self.surfaceValue(original, rpuKey) as? Data == previousRPU)
        #expect(CVBufferCopyAttachment(original, idKey as CFString, nil) as? String
                == DoviDisplayMetadata.profile81CompatibilityID)
        #expect(Self.surfaceValue(original, idKey) as? String == DoviDisplayMetadata.profile81CompatibilityID)
    }

    @Test("an existing normalized copy receives RPU changes without a second copy",
          arguments: [false, true])
    func normalizedCopyIsReused(clearsRPU: Bool) throws {
        let original = try Self.makeBuffer()
        let owned = try Self.makeBuffer()
        let previousRPU = Data([0x19, 0x08, 0x09, 0xAA])
        AV1DolbyVisionRPUTable.attach(previousRPU, to: original)
        AV1DolbyVisionRPUTable.attach(previousRPU, to: owned)
        let requestedRPU: Data? = clearsRPU ? nil : Data([0x19, 0x08, 0x09, 0xBB])
        let result = AV1DolbyVisionRPUTable.attachingToOwnedOutput(
            requestedRPU, normalized: owned, original: original,
            copyOriginal: { _ in
                Issue.record("the normalized output is already owned")
                return nil
            })
        let rpuKey = DoviDisplayMetadata.rpuDataKey
        #expect(result === owned)
        #expect(CVBufferCopyAttachment(owned, rpuKey as CFString, nil) as? Data == requestedRPU)
        #expect(Self.surfaceValue(owned, rpuKey) as? Data == requestedRPU)
        #expect(CVBufferCopyAttachment(original, rpuKey as CFString, nil) as? Data == previousRPU)
        #expect(Self.surfaceValue(original, rpuKey) as? Data == previousRPU)
    }

    @Test("a successful frame copy receives the RPU without modifying the source")
    func successfulOwnedCopy() throws {
        let original = try Self.makeBuffer()
        let rpu = Data([0x19, 0x08, 0x09, 0xAA])
        let copier = FrameCopier()
        let result = AV1DolbyVisionRPUTable.attachingToOwnedOutput(
            rpu, normalized: original, original: original, copyOriginal: copier.copy)
        let rpuKey = DoviDisplayMetadata.rpuDataKey
        #expect(result !== original)
        #expect(CVBufferCopyAttachment(result, rpuKey as CFString, nil) as? Data == rpu)
        #expect(Self.surfaceValue(result, rpuKey) as? Data == rpu)
        #expect(CVBufferCopyAttachment(original, rpuKey as CFString, nil) == nil)
        #expect(Self.surfaceValue(original, rpuKey) == nil)
    }

    @Test("attach sets the RPU and a CFString compatibility ID on the buffer and its IOSurface; nil clears both")
    func attachesAndClears() throws {
        let buffer = try Self.makeBuffer()
        let rpu = Data([0x19, 0x08, 0x09, 0xAA])
        let rpuKey = DoviDisplayMetadata.rpuDataKey, idKey = DoviDisplayMetadata.compatibilityIDKey
        AV1DolbyVisionRPUTable.attach(rpu, to: buffer)
        #expect(CVBufferCopyAttachment(buffer, rpuKey as CFString, nil) as? Data == rpu)
        let id = try #require(CVBufferCopyAttachment(buffer, idKey as CFString, nil))
        // tvOS parses it with CFStringGetIntValue; a CFNumber takes the render server down.
        #expect(CFGetTypeID(id) == CFStringGetTypeID())
        #expect(id as? String == DoviDisplayMetadata.profile81CompatibilityID)
        #expect(Self.surfaceValue(buffer, rpuKey) as? Data == rpu)
        #expect(Self.surfaceValue(buffer, idKey) as? String == DoviDisplayMetadata.profile81CompatibilityID)

        // A pool buffer is recycled: a frame without an RPU must not keep the previous tenant's.
        AV1DolbyVisionRPUTable.attach(nil, to: buffer)
        #expect(CVBufferCopyAttachment(buffer, rpuKey as CFString, nil) == nil)
        #expect(CVBufferCopyAttachment(buffer, idKey as CFString, nil) == nil)
        #expect(Self.surfaceValue(buffer, rpuKey) == nil)
        #expect(Self.surfaceValue(buffer, idKey) == nil)
    }
}
