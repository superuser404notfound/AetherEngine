import Foundation
import AetherLibavcodec
import AetherLibavutil

/// AE#957: a stream's HDR10 static metadata, for the frames the software path decodes. HEVC carries it
/// in SEI, AV1 in metadata OBUs, and a decoded libavcodec frame as side data.
///
/// VideoToolbox attaches no mastering display colour volume and no content light level to the frames
/// it decodes, though the HEVC stream carries both (measured on tvOS 27.2, A12, with the SEI in every
/// IRAP and in the `hvcC`). Without them the television receives HDR10 with no static metadata. The
/// HDR10 pass-through probe showed that the attachments on the frames given to the display layer do
/// reach the television, so the decoder sets the stream's own values there.
///
/// Sources, first found wins: the container (`mdcv` / `clli` boxes, Matroska's colour metadata, both
/// as `codecpar` side data), then the SEI in the `hvcC`, then the SEI in the first key frames. The SEI
/// payloads (types 137 and 144) are byte for byte what Core Video's attachments hold, so they are
/// copied as they are. Pure and stateless; malformed input yields nil.
enum HDR10StaticMetadataSEI {

    static let masteringDisplayPayloadType = 137
    static let contentLightLevelPayloadType = 144
    /// `kCVImageBufferMasteringDisplayColorVolumeKey`: G, B, R primaries and the white point as x, y
    /// pairs in 0.00002 units, then peak and minimum luminance in 0.0001 nit, all big endian.
    static let masteringDisplaySize = 24
    /// `kCVImageBufferContentLightLevelInfoKey`: MaxCLL then MaxFALL, two bytes each, big endian.
    static let contentLightLevelSize = 4
    /// Key frames the in-band scan reads before it gives up on a stream that has no such SEI.
    static let keyFramesToScan = 3

    struct Values: Equatable, Sendable {
        var masteringDisplay: Data?
        var contentLightLevel: Data?

        static let none = Values()
        var isEmpty: Bool { masteringDisplay == nil && contentLightLevel == nil }
        var isComplete: Bool { masteringDisplay != nil && contentLightLevel != nil }

        /// Keeps what is already known and fills the rest from `other`.
        func filling(from other: Values) -> Values {
            Values(masteringDisplay: masteringDisplay ?? other.masteringDisplay,
                   contentLightLevel: contentLightLevel ?? other.contentLightLevel)
        }
    }

    /// The two SEI messages in one packet (an access unit) of an HEVC or H.264 stream.
    static func scan(
        _ data: UnsafePointer<UInt8>, size: Int,
        codec: A53SEIParser.CodecKind, framing: A53SEIParser.NALFraming
    ) -> Values {
        var found = Values.none
        A53SEIParser.forEachSEIRBSP(data, size, codec: codec, framing: framing) { rbsp in
            A53SEIParser.forEachSEIPayload(rbsp) { type, offset, payloadSize in
                if type == masteringDisplayPayloadType, payloadSize >= masteringDisplaySize,
                   found.masteringDisplay == nil, offset + masteringDisplaySize <= rbsp.count {
                    found.masteringDisplay = Data(rbsp[offset ..< offset + masteringDisplaySize])
                } else if type == contentLightLevelPayloadType, payloadSize >= contentLightLevelSize,
                          found.contentLightLevel == nil, offset + contentLightLevelSize <= rbsp.count {
                    found.contentLightLevel = Data(rbsp[offset ..< offset + contentLightLevelSize])
                }
                return found.isComplete
            }
            return found.isComplete
        }
        return found
    }

    /// The SEI NAL units an `hvcC` record carries in its arrays (x265 writes the HDR10 SEI there).
    static func scanHEVCConfigRecord(_ record: UnsafePointer<UInt8>, size: Int) -> Values {
        guard size >= 23, record[0] == 1 else { return .none }
        // Re-framed as 2-byte length-prefixed NAL units, which is what the arrays hold after their headers.
        var seiNALs: [UInt8] = []
        var offset = 23
        for _ in 0 ..< Int(record[22]) {
            guard offset + 3 <= size else { return .none }
            let nalType = Int(record[offset]) & 0x3F
            let count = Int(record[offset + 1]) << 8 | Int(record[offset + 2])
            offset += 3
            for _ in 0 ..< count {
                guard offset + 2 <= size else { return .none }
                let length = Int(record[offset]) << 8 | Int(record[offset + 1])
                guard offset + 2 + length <= size else { return .none }
                if nalType == 39 || nalType == 40 {
                    seiNALs.append(contentsOf: UnsafeBufferPointer(start: record + offset, count: 2 + length))
                }
                offset += 2 + length
            }
        }
        guard !seiNALs.isEmpty else { return .none }
        return seiNALs.withUnsafeBufferPointer {
            scan($0.baseAddress!, size: $0.count, codec: .hevc, framing: .lengthPrefixed(size: 2))
        }
    }

    /// The container's declaration, from the stream's coded side data.
    static func fromCodedSideData(_ codecpar: UnsafePointer<AVCodecParameters>) -> Values {
        var found = Values.none
        let count = Int(codecpar.pointee.nb_coded_side_data)
        guard count > 0, let sideData = codecpar.pointee.coded_side_data else { return found }
        for i in 0 ..< count {
            let item = sideData[i]
            guard let raw = item.data else { continue }
            if item.type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
               item.size >= MemoryLayout<AVMasteringDisplayMetadata>.size {
                let metadata = raw.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { $0.pointee }
                found.masteringDisplay = masteringDisplay(metadata)
            } else if item.type == AV_PKT_DATA_CONTENT_LIGHT_LEVEL,
                      item.size >= MemoryLayout<AVContentLightMetadata>.size {
                let metadata = raw.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) { $0.pointee }
                found.contentLightLevel = contentLightLevel(maxCLL: metadata.MaxCLL, maxFALL: metadata.MaxFALL)
            }
        }
        return found
    }

    /// A decoded frame's own values (libavcodec exports them from the SEI, and libdav1d from the AV1
    /// metadata OBUs), in Core Video's byte layout.
    static func fromFrameSideData(_ frame: UnsafePointer<AVFrame>) -> Values {
        var found = Values.none
        guard frame.pointee.nb_side_data > 0 else { return found }
        if let item = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA),
           let raw = item.pointee.data, item.pointee.size >= MemoryLayout<AVMasteringDisplayMetadata>.size {
            found.masteringDisplay = masteringDisplay(
                raw.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { $0.pointee })
        }
        if let item = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL),
           let raw = item.pointee.data, item.pointee.size >= MemoryLayout<AVContentLightMetadata>.size {
            let metadata = raw.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) { $0.pointee }
            found.contentLightLevel = contentLightLevel(maxCLL: metadata.MaxCLL, maxFALL: metadata.MaxFALL)
        }
        return found
    }

    // MARK: - AV1 metadata OBUs

    static let av1MetadataOBUType: UInt8 = 5
    static let av1MetadataTypeContentLightLevel = 1
    static let av1MetadataTypeMasteringDisplay = 2

    /// The HDR10 metadata OBUs in one AV1 temporal unit (FFmpeg's demuxed packets use the low-overhead
    /// format, every OBU with its size). CLL is laid out as Core Video's attachment; MDCV is not (red
    /// first, 0.16 fixed point chromaticity, 24.8 and 18.14 fixed point luminance), so it is converted.
    static func scanAV1(_ data: UnsafePointer<UInt8>, size: Int) -> Values {
        var found = Values.none
        var offset = 0
        while offset < size, !found.isComplete {
            let header = data[offset]
            offset += 1
            guard header & 0x80 == 0 else { return found } // obu_forbidden_bit
            let type = (header >> 3) & 15
            if header & 4 != 0 { offset += 1 } // obu_extension_header
            let payloadSize: Int
            if header & 2 != 0 {
                guard let declared = leb128(data, size: size, offset: &offset) else { return found }
                payloadSize = declared
            } else {
                payloadSize = size - offset
            }
            guard offset <= size, payloadSize <= size - offset else { return found }
            let end = offset + payloadSize
            if type == av1MetadataOBUType {
                var cursor = offset
                if let metadataType = leb128(data, size: end, offset: &cursor) {
                    let body = UnsafeBufferPointer(start: data + cursor, count: end - cursor)
                    if metadataType == av1MetadataTypeContentLightLevel, found.contentLightLevel == nil,
                       body.count >= contentLightLevelSize {
                        found.contentLightLevel = Data(body.prefix(contentLightLevelSize))
                    } else if metadataType == av1MetadataTypeMasteringDisplay, found.masteringDisplay == nil {
                        found.masteringDisplay = av1MasteringDisplay(body)
                    }
                }
            }
            offset = end
        }
        return found
    }

    /// The configuration OBUs of an `av1C` record (after its 4-byte header), which may hold the metadata.
    static func scanAV1ConfigRecord(_ record: UnsafePointer<UInt8>, size: Int) -> Values {
        guard size > 4, record[0] == 0x81 else { return .none } // marker and version 1
        return scanAV1(record + 4, size: size - 4)
    }

    /// `metadata_hdr_mdcv` (AV1 section 5.8.4) in Core Video's layout, or nil when it is short or out of range.
    static func av1MasteringDisplay(_ body: UnsafeBufferPointer<UInt8>) -> Data? {
        guard body.count >= masteringDisplaySize else { return nil }
        func u16(_ at: Int) -> UInt32 { UInt32(body[at]) << 8 | UInt32(body[at + 1]) }
        func u32(_ at: Int) -> UInt64 { UInt64(u16(at)) << 16 | UInt64(u16(at + 2)) }
        // 0.16 fixed point to 0.00002 units, rounded; at most 50000, so it fits two bytes.
        func chromaticity(_ at: Int) -> UInt32 { (u16(at) * 50_000 + 32_768) >> 16 }
        // Red, green, blue in the OBU; green, blue, red in Core Video.
        let order = [4, 8, 0, 12]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(masteringDisplaySize)
        for pair in order {
            for value in [chromaticity(pair), chromaticity(pair + 2)] {
                bytes += [UInt8(value >> 8), UInt8(value & 0xFF)]
            }
        }
        // 24.8 and 18.14 fixed point nits to 0.0001 nit.
        let peak = (u32(16) * 10_000 + 128) >> 8
        let minimum = (u32(20) * 10_000 + 8_192) >> 14
        for value in [peak, minimum] {
            guard value <= UInt64(UInt32.max) else { return nil }
            bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
        return Data(bytes)
    }

    /// AV1 leb128, read up to `size`; values are limited to 32 bits.
    private static func leb128(_ data: UnsafePointer<UInt8>, size: Int, offset: inout Int) -> Int? {
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            guard offset < size else { return nil }
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 { return value <= UInt64(UInt32.max) ? Int(value) : nil }
        }
        return nil
    }

    /// FFmpeg's struct in Core Video's byte layout. nil unless it has both primaries and luminance, the
    /// way the SEI always does: a half-filled volume would claim a gamut or a peak nobody declared.
    static func masteringDisplay(_ m: AVMasteringDisplayMetadata) -> Data? {
        guard m.has_primaries != 0, m.has_luminance != 0 else { return nil }
        func units(_ q: AVRational, _ scale: Double, max: Double) -> Double? {
            guard q.den != 0 else { return nil }
            let value = (av_q2d(q) * scale).rounded()
            return value >= 0 && value <= max ? value : nil
        }
        // FFmpeg stores red, green, blue; the SEI and Core Video order is green, blue, red.
        let p = m.display_primaries
        let chromaticities = [p.1.0, p.1.1, p.2.0, p.2.1, p.0.0, p.0.1, m.white_point.0, m.white_point.1]
        var bytes: [UInt8] = []
        for q in chromaticities {
            guard let v = units(q, 50_000, max: Double(UInt16.max)) else { return nil }
            let u = UInt16(v)
            bytes += [UInt8(u >> 8), UInt8(u & 0xFF)]
        }
        for q in [m.max_luminance, m.min_luminance] {
            guard let v = units(q, 10_000, max: Double(UInt32.max)) else { return nil }
            let u = UInt32(v)
            bytes += [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
        }
        return Data(bytes)
    }

    static func contentLightLevel(maxCLL: UInt32, maxFALL: UInt32) -> Data {
        let cll = UInt16(min(maxCLL, UInt32(UInt16.max)))
        let fall = UInt16(min(maxFALL, UInt32(UInt16.max)))
        return Data([UInt8(cll >> 8), UInt8(cll & 0xFF), UInt8(fall >> 8), UInt8(fall & 0xFF)])
    }
}
