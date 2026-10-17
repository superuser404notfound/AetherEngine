// Only with the DualLayerDolbyVision trait: the dual-layer route is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import IOSurface
@testable import AetherEngine

/// `DoviDisplayMetadata`: the RPU payload form, and the two attachments tvOS's compositor reads, on the
/// CVBuffer and on its backing IOSurface (where tvOS actually reads them).
struct DoviDisplayMetadataTests {

    private static let nal: [UInt8] = [0x7C, 0x01, 0x19, 0x08, 0x09, 0xAA, 0xBB]

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

    private static func surfaceValue(_ b: CVPixelBuffer, _ key: String) -> CFTypeRef? {
        guard let s = CVPixelBufferGetIOSurface(b)?.takeUnretainedValue() else { return nil }
        return IOSurfaceCopyValue(s, key as CFString)
    }

    // MARK: payload(fromNAL:)

    @Test("payload strips the 0x7C 0x01 NAL header and leaves emulation-prevention bytes alone")
    func payloadStripsHeader() {
        let withEpb: [UInt8] = [0x7C, 0x01, 0x19, 0x00, 0x00, 0x03, 0x01]
        #expect(DoviDisplayMetadata.payload(fromNAL: withEpb) == Data([0x19, 0x00, 0x00, 0x03, 0x01]))
        #expect(DoviDisplayMetadata.payload(fromNAL: Self.nal) == Data([0x19, 0x08, 0x09, 0xAA, 0xBB]))
    }

    @Test("payload passes a header-less RPU (leading 0x19) through unchanged")
    func payloadPassesThroughHeaderless() {
        let raw: [UInt8] = [0x19, 0x08, 0x09, 0x01]
        #expect(DoviDisplayMetadata.payload(fromNAL: raw) == Data(raw))
    }

    @Test("payload returns nil for nil, for too-short input and for anything else")
    func payloadRejectsOthers() {
        #expect(DoviDisplayMetadata.payload(fromNAL: nil) == nil)
        #expect(DoviDisplayMetadata.payload(fromNAL: []) == nil)
        #expect(DoviDisplayMetadata.payload(fromNAL: [0x7C, 0x01]) == nil)
        #expect(DoviDisplayMetadata.payload(fromNAL: [0x40, 0x01, 0x19, 0x00]) == nil)
        #expect(DoviDisplayMetadata.payload(fromNAL: [0x7C, 0x02, 0x19, 0x00]) == nil)
        #expect(DoviDisplayMetadata.payload(fromNAL: [0x18, 0x00, 0x00]) == nil)
    }

    // MARK: attach

    @Test("attach sets the RPU as CFData and the compatibility ID as a CFString, on the CVBuffer and the IOSurface")
    func attachSetsBothKeys() throws {
        let b = try Self.makeBuffer()
        DoviDisplayMetadata.attach(rpuNAL: Self.nal, to: b)

        let rpu = try #require(CVBufferCopyAttachment(b, DoviDisplayMetadata.rpuDataKey as CFString, nil))
        #expect(CFGetTypeID(rpu) == CFDataGetTypeID())
        #expect((rpu as? Data) == Data([0x19, 0x08, 0x09, 0xAA, 0xBB]))

        // tvOS parses this with CFStringGetIntValue: a CFNumber here aborts backboardd.
        let id = try #require(CVBufferCopyAttachment(b, DoviDisplayMetadata.compatibilityIDKey as CFString, nil))
        #expect(CFGetTypeID(id) == CFStringGetTypeID(), "compatibility ID must be a CFString")
        #expect((id as? String) == "1")

        // Mirrored onto the backing surface, with the same types.
        let surfaceRpu = try #require(Self.surfaceValue(b, DoviDisplayMetadata.rpuDataKey))
        #expect(CFGetTypeID(surfaceRpu) == CFDataGetTypeID())
        let surfaceId = try #require(Self.surfaceValue(b, DoviDisplayMetadata.compatibilityIDKey))
        #expect(CFGetTypeID(surfaceId) == CFStringGetTypeID())
    }

    @Test("attach(nil) clears both keys from the CVBuffer and from the backing IOSurface")
    func attachNilClearsEverywhere() throws {
        let b = try Self.makeBuffer()
        DoviDisplayMetadata.attach(rpuNAL: Self.nal, to: b)
        #expect(Self.surfaceValue(b, DoviDisplayMetadata.rpuDataKey) != nil, "precondition: mirrored to the surface")

        DoviDisplayMetadata.attach(rpuNAL: nil, to: b)

        #expect(CVBufferCopyAttachment(b, DoviDisplayMetadata.rpuDataKey as CFString, nil) == nil)
        #expect(CVBufferCopyAttachment(b, DoviDisplayMetadata.compatibilityIDKey as CFString, nil) == nil)
        #expect(Self.surfaceValue(b, DoviDisplayMetadata.rpuDataKey) == nil, "stale RPU left on the IOSurface")
        #expect(Self.surfaceValue(b, DoviDisplayMetadata.compatibilityIDKey) == nil, "stale compatibility ID left on the IOSurface")
    }

    @Test("an unusable NAL clears a previous tenant's attachments too")
    func attachUnusableClears() throws {
        let b = try Self.makeBuffer()
        DoviDisplayMetadata.attach(rpuNAL: Self.nal, to: b)
        DoviDisplayMetadata.attach(rpuNAL: [0x00, 0x00, 0x00], to: b)
        #expect(CVBufferCopyAttachment(b, DoviDisplayMetadata.rpuDataKey as CFString, nil) == nil)
        #expect(Self.surfaceValue(b, DoviDisplayMetadata.rpuDataKey) == nil)
    }
}
#endif
