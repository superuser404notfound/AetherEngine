import Foundation
import AetherLibavcodec
import AetherLibavutil

/// AE#957: a stream's HDR10 static metadata, for the frames the software path decodes.
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
