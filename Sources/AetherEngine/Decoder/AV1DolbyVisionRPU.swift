import Foundation
import CoreMedia
import CoreVideo
import IOSurface
import Dovi
import AetherLibavformat

/// The Dolby Vision RPU of an AV1 temporal unit, in the form the system's Dolby Vision display
/// management reads off a decoded frame (`DolbyVisionRPUData`).
///
/// AV1 carries the RPU in an ITU-T T.35 metadata OBU (Profile 10). AVFoundation and VideoToolbox
/// ignore it, so an AV1 Profile 10.1 source plays as its HDR10 base layer on every Apple route. The
/// RPU of a 10.1 stream is the RPU of an HEVC 8.1 stream in another wrapper (libdovi guesses profile
/// 8 for it), and VideoToolbox attaches an HEVC 8.1 RPU to its frames as the `unspec62` NAL minus
/// its two header bytes, emulation-prevention bytes kept (see `DoviDisplayMetadata`). Rewrapping
/// the T.35 payload into that form and attaching it to the decoded frame gets the frame the same
/// display management an HEVC 8.1 frame gets. Measured on macOS 27 (M5 Pro): a pulse clip whose
/// pixels are constant and whose RPU alternates is composited identically, to 0.0001 PQ, whether it
/// is played as HEVC 8.1 through AVPlayer or as AV1 10.1 through this path.
enum AV1DolbyVisionRPU {

    /// Backs `AetherEngine.attachesAV1DolbyVisionRPU`. Read once per frame; a torn read
    /// costs one frame its RPU, nothing else.
    nonisolated(unsafe) static var attachEnabled = true

    /// Backs `AetherEngine.decodesAV1DolbyVisionInSoftware`. Read when a session opens its decoder.
    nonisolated(unsafe) static var softwareDecodeForced = false

    /// AV1 Dolby Vision Profile 10.1, the profile whose RPU this route attaches. 10.0 has no base layer
    /// to present and the HLG base of 10.4 is unmeasured, so both keep the plain libavcodec path.
    static func carriesProfile10_1(stream: UnsafeMutablePointer<AVStream>) -> Bool {
        guard let codecpar = stream.pointee.codecpar, codecpar.pointee.codec_id == AV_CODEC_ID_AV1,
              let dv = AetherEngine.dvConfig(stream: stream) else { return false }
        return dv.profile == 10 && dv.blCompatID == 1
    }

    /// The attachment payload for the temporal unit in `data`, or nil when it carries no Dolby
    /// Vision T.35 metadata OBU or libdovi cannot parse it.
    static func attachmentPayload(temporalUnit data: UnsafePointer<UInt8>, size: Int) -> Data? {
        var i = 0
        while i < size {
            let header = data[i]
            let obuType = (header >> 3) & 0x0F
            let hasExtension = Int((header >> 2) & 1)
            let hasSizeField = (header >> 1) & 1
            var payloadStart = i + 1 + hasExtension
            var payloadSize = size - payloadStart
            if hasSizeField == 1 {
                guard let (value, length) = leb128(data, size: size, at: payloadStart) else { return nil }
                payloadSize = value
                payloadStart += length
            }
            guard payloadStart + payloadSize <= size else { return nil }
            // OBU_METADATA (5) of metadata_type METADATA_TYPE_ITUT_T35 (4).
            if obuType == 5, let (metadataType, length) = leb128(data, size: size, at: payloadStart), metadataType == 4 {
                // libdovi takes the T.35 payload from itu_t_t35_country_code on.
                let t35 = payloadStart + length
                if let payload = rewrap(data + t35, count: payloadStart + payloadSize - t35) {
                    return payload
                }
            }
            i = payloadStart + payloadSize
        }
        return nil
    }

    private static func rewrap(_ t35: UnsafePointer<UInt8>, count: Int) -> Data? {
        guard count > 0, let rpu = DoviRpuGuard.parseAV1(t35, count) else { return nil }
        defer { dovi_rpu_free(rpu) }
        // A T.35 OBU from another provider (HDR10+ is T.35 too) fails the parse here, and libdovi
        // (panic=abort) never sees an RPU that is corrupt or steers it into a panic (DoviRpuGuard).
        guard dovi_rpu_get_error(rpu) == nil, let nal = dovi_write_unspec62_nalu(rpu) else { return nil }
        defer { dovi_data_free(nal) }
        guard dovi_rpu_get_error(rpu) == nil, nal.pointee.len > 2,
              nal.pointee.data[0] == 0x7C, nal.pointee.data[1] == 0x01 else { return nil }
        return Data(bytes: nal.pointee.data + 2, count: Int(nal.pointee.len) - 2)
    }

    private static func leb128(_ data: UnsafePointer<UInt8>, size: Int, at offset: Int) -> (Int, Int)? {
        var value = 0
        for n in 0..<8 where offset + n < size {
            let byte = data[offset + n]
            value |= Int(byte & 0x7F) << (7 * n)
            if byte & 0x80 == 0 { return (value, n + 1) }
        }
        return nil
    }
}

extension AetherEngine {
    /// Default on: whether the AV1 Dolby Vision 10.1 route attaches the RPU to the frames it decodes.
    /// Off shows that route's HDR10 base layer for A/B viewing, from the next frame on.
    @_spi(Diagnostics)
    public nonisolated static var attachesAV1DolbyVisionRPU: Bool {
        get { AV1DolbyVisionRPU.attachEnabled }
        set { AV1DolbyVisionRPU.attachEnabled = newValue }
    }

    /// Default off: decode AV1 Dolby Vision 10.1 with dav1d even where VideoToolbox decodes AV1 in
    /// hardware, the route a device without hardware AV1 (every Apple TV up to the 3rd generation)
    /// takes, so a Mac can reproduce it. The RPU is attached either way. Applies to the next load.
    @_spi(Diagnostics)
    public nonisolated static var decodesAV1DolbyVisionInSoftware: Bool {
        get { AV1DolbyVisionRPU.softwareDecodeForced }
        set { AV1DolbyVisionRPU.softwareDecodeForced = newValue }
    }
}

/// The RPU of each AV1 temporal unit, from the packet a decoder is sent to the frame it delivers.
/// Keyed by presentation time rather than carried through the decoder, so a frame the decoder drops
/// or fails costs a missing attachment, never a mismatched one.
final class AV1DolbyVisionRPUTable: @unchecked Sendable {
    private struct Key: Hashable {
        let value: Int64
        let timescale: Int32
        init(_ time: CMTime) { value = time.value; timescale = time.timescale }
    }

    private let lock = NSLock()
    private var pending: [Key: Data] = [:]
    private var attached = 0
    private var missing = 0
    private let logPrefix: String

    init(logPrefix: String) { self.logPrefix = logPrefix }

    /// Before the send: a decoder can deliver the frame before its decode call returns.
    func store(temporalUnit data: UnsafePointer<UInt8>, size: Int, pts: CMTime) {
        guard let rpu = AV1DolbyVisionRPU.attachmentPayload(temporalUnit: data, size: size) else { return }
        lock.lock()
        defer { lock.unlock() }
        // Entries are taken on delivery and cleared by flush; this bounds what frames the decoder never
        // returned (decode errors) can leave behind.
        if pending.count > 256 { pending.removeAll(keepingCapacity: true) }
        pending[Key(pts)] = rpu
    }

    func take(for pts: CMTime) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let rpu = pending.removeValue(forKey: Key(pts))
        if rpu == nil { missing += 1 } else { attached += 1 }
        if (rpu != nil && attached == 1) || (rpu == nil && missing == 1) || (attached + missing) % 2400 == 0 {
            EngineLog.emit(
                "\(logPrefix) AV1 Dolby Vision RPU: \(attached) frame(s) attached, \(missing) without an RPU"
                + (rpu.map { " (latest \($0.count) bytes)" } ?? ""),
                category: .swPlayback
            )
        }
        return rpu
    }

    /// A frame the decoder refused to take leaves no entry behind, and counts as nothing.
    func discard(for pts: CMTime) {
        lock.lock()
        pending.removeValue(forKey: Key(pts))
        lock.unlock()
    }

    /// Frames of a flushed run that never came out leave their RPU behind.
    func removeAll() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// The hardware route must own the buffer before either setting or removing RPU metadata.
    /// The normalizer may already have copied it; otherwise a failed copy preserves the original
    /// frame and all of its attachments, rather than writing into a decoder-owned reference picture.
    static func attachingToOwnedOutput(
        _ rpu: Data?,
        normalized: CVPixelBuffer,
        original: CVPixelBuffer,
        copyOriginal: (CVPixelBuffer) -> CVPixelBuffer?
    ) -> CVPixelBuffer {
        let output: CVPixelBuffer
        if normalized !== original {
            output = normalized
        } else {
            guard let copy = copyOriginal(original), copy !== original else { return original }
            output = copy
        }
        attach(rpu, to: output)
        return output
    }

    /// The two keys VideoToolbox sets on a frame it decodes as HEVC Dolby Vision, on the buffer and
    /// its IOSurface, as it sets them. Cleared on a frame without an RPU: output buffers are recycled
    /// from a pool, and a stale RPU would grade the frame with another frame's metadata.
    static func attach(_ rpu: Data?, to buffer: CVImageBuffer) {
        let rpuKey = DoviDisplayMetadata.rpuDataKey as CFString
        let compatibilityKey = DoviDisplayMetadata.compatibilityIDKey as CFString
        let compatibilityID = DoviDisplayMetadata.profile81CompatibilityID as CFString
        let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        if let rpu {
            // A CFString, never a number: tvOS parses it with CFStringGetIntValue (DoviDisplayMetadata).
            CVBufferSetAttachment(buffer, rpuKey, rpu as CFData, .shouldPropagate)
            CVBufferSetAttachment(buffer, compatibilityKey, compatibilityID, .shouldPropagate)
            if let surface {
                IOSurfaceSetValue(surface, rpuKey, rpu as CFData)
                IOSurfaceSetValue(surface, compatibilityKey, compatibilityID)
            }
        } else {
            CVBufferRemoveAttachment(buffer, rpuKey)
            CVBufferRemoveAttachment(buffer, compatibilityKey)
            if let surface {
                IOSurfaceRemoveValue(surface, rpuKey)
                IOSurfaceRemoveValue(surface, compatibilityKey)
            }
        }
    }
}

/// Copies a decoded frame into a buffer from a pool of our own: the pixels, and the propagated
/// attachments the decoder put on it. The AV1 Dolby Vision route attaches its RPU to the copy, see
/// `HardwareVideoDecoder.handleDecodedFrame`. Called on VideoToolbox's output queue, one frame at a time.
final class FrameCopier: @unchecked Sendable {
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?

    func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        lock.lock()
        if pool == nil || poolKey.map({ $0 != (width, height, format) }) ?? true {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 12] as CFDictionary,
                                    attributes as CFDictionary, &created)
            pool = created
            poolKey = (width, height, format)
        }
        let pool = self.pool
        lock.unlock()

        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
              let destination else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
            let fromRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let rowBytes = min(fromRow, toRow)
            for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                memcpy(to + row * toRow, from + row * fromRow, rowBytes)
            }
        }
        // Replaces rather than adds: a recycled pool buffer can still hold the previous frame's tags.
        CVBufferRemoveAllAttachments(destination)
        CVBufferPropagateAttachments(source, destination)
        return destination
    }
}
