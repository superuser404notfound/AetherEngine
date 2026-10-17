import Foundation
import AetherLibavcodec
import AetherLibavutil

/// Shared, decoder-free HDR10+ confirmation for playback and the detail probe.
///
/// Only registered T.35 messages in H.264/HEVC SEI or AV1 metadata OBUs are candidates.
/// FFmpeg validates their complete ST 2094-40 body. Matroska's already-decoded packet
/// side data is checked separately; neither a byte marker nor a side-data type is proof.
enum HDR10PlusMetadataScan {
    private static let t35Header: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    static func packetCarriesHDR10Plus(
        _ packet: UnsafePointer<AVPacket>,
        codecParameters: UnsafePointer<AVCodecParameters>,
        framing: VideoNALFraming? = nil
    ) -> Bool {
        let parameters = codecParameters.pointee
        let resolvedFraming = framing ?? NALUnitChain.lengthPrefixSize(
            codecID: parameters.codec_id,
            extradata: parameters.extradata,
            extradataSize: Int(parameters.extradata_size)
        ).map { .lengthPrefixed(size: $0) } ?? .annexB
        return packetCarriesHDR10Plus(packet, codecID: parameters.codec_id, framing: resolvedFraming)
    }

    static func packetCarriesHDR10Plus(
        _ packet: UnsafePointer<AVPacket>, codecID: AVCodecID, framing: VideoNALFraming = .annexB
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_AV1, AV_CODEC_ID_VP9:
            break
        default:
            return false
        }
        var sideDataSize = 0
        if let sideData = av_packet_get_side_data(packet, AV_PKT_DATA_DYNAMIC_HDR10_PLUS, &sideDataSize),
           validSideData(sideData, size: sideDataSize) {
            return true
        }
        return bytesCarryHDR10Plus(
            packet.pointee.data, size: Int(packet.pointee.size), codecID: codecID, framing: framing)
    }

    static func bytesCarryHDR10Plus(
        _ data: UnsafePointer<UInt8>?, size: Int, codecID: AVCodecID, framing: VideoNALFraming = .annexB
    ) -> Bool {
        guard let data, size > 0, mayContainT35Header(data, size: size) else { return false }
        let bytes = UnsafeBufferPointer(start: data, count: size)
        switch codecID {
        case AV_CODEC_ID_H264, AV_CODEC_ID_HEVC:
            return scanNALs(bytes, codecID: codecID, framing: framing, payload: validT35)
        case AV_CODEC_ID_AV1:
            return scanOBUs(bytes)
        default:
            return false
        }
    }

    /// The packet's ST 2094-40 message in the shape `kCMSampleAttachmentKey_HDR10PlusPerFrameData`
    /// documents: the registered T.35 bytes from `itu_t_t35_country_code` (0xB5) on. The VideoToolbox
    /// route decodes into a pixel buffer and builds the display layer's sample buffer itself, so the
    /// per-frame metadata reaches the layer only through this attachment. H.264 / HEVC SEI and
    /// Matroska's packet side data; the first message the full validation accepts wins.
    static func coreMediaPayload(
        _ packet: UnsafePointer<AVPacket>, codecID: AVCodecID, framing: VideoNALFraming
    ) -> Data? {
        var sideDataSize = 0
        if let sideData = av_packet_get_side_data(packet, AV_PKT_DATA_DYNAMIC_HDR10_PLUS, &sideDataSize),
           validSideData(sideData, size: sideDataSize) {
            var allocationSize = 0
            guard let metadata = av_dynamic_hdr_plus_alloc(&allocationSize) else { return nil }
            defer { av_free(metadata) }
            memcpy(metadata, sideData, allocationSize)
            return coreMediaPayload(metadata)
        }
        guard codecID == AV_CODEC_ID_H264 || codecID == AV_CODEC_ID_HEVC,
              let data = packet.pointee.data, packet.pointee.size > 0,
              mayContainT35Header(data, size: Int(packet.pointee.size)) else { return nil }
        var payload: Data?
        _ = scanNALs(
            UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)),
            codecID: codecID, framing: framing
        ) { bytes, size in
            guard validT35(bytes, size) else { return false }
            if payload == nil { payload = Data(bytes: bytes, count: size) }
            return true
        }
        return payload
    }

    /// `av_dynamic_hdr_plus_to_t35` writes the message from the application version on, without the
    /// six header bytes Core Media's attachment has to start with, so they go back in front here.
    static func coreMediaPayload(_ metadata: UnsafePointer<AVDynamicHDRPlus>) -> Data? {
        var buffer: UnsafeMutablePointer<UInt8>?
        var size = 0
        guard av_dynamic_hdr_plus_to_t35(metadata, &buffer, &size) >= 0, let buffer, size > 0 else {
            return nil
        }
        defer { av_free(buffer) }
        var payload = Data(t35Header)
        payload.append(buffer, count: size)
        return payload
    }

    /// Audit BIT-4: exact prefilter. The playback scan runs on every video packet until its first hit,
    /// so a source without HDR10+ paid a byte-wise NAL walk for the whole session. The T.35 header
    /// holds no `00 00` pair, so no emulation-prevention byte can land inside it and AV1 does not
    /// escape at all: a payload that carries HDR10+ in-band carries these six bytes verbatim.
    static func mayContainT35Header(_ data: UnsafePointer<UInt8>, size: Int) -> Bool {
        guard size >= t35Header.count else { return false }
        return t35Header.withUnsafeBufferPointer { memmem(data, size, $0.baseAddress, $0.count) != nil }
    }

    // MARK: - H.264 / HEVC

    /// A walk that runs into malformed framing stops and reports what it had already VALIDATED, rather
    /// than discarding it. Only `validT35` ever sets the answer, so an aborted walk cannot invent one;
    /// abandoning a confirmed payload because a later NAL in the same packet is malformed would be a
    /// false negative on the one carriage this scan exists to find. `payload` validates one registered
    /// T.35 message (its bytes start at the country code), so HDR Vivid shares this walk.
    static func scanNALs(
        _ bytes: UnsafeBufferPointer<UInt8>, codecID: AVCodecID, framing: VideoNALFraming,
        payload: (UnsafePointer<UInt8>, Int) -> Bool
    ) -> Bool {
        var found = false
        func visit(_ start: Int, _ end: Int) -> Bool {
            let headerSize = codecID == AV_CODEC_ID_HEVC ? 2 : 1
            guard end - start >= headerSize, bytes[start] & 0x80 == 0 else { return false }
            let isSEI: Bool
            if codecID == AV_CODEC_ID_HEVC {
                guard bytes[start + 1] & 7 != 0 else { return false }
                let type = (bytes[start] >> 1) & 0x3F
                isSEI = type == 39 || type == 40
            } else {
                isSEI = bytes[start] & 0x1F == 6
                if isSEI, bytes[start] & 0x60 != 0 { return false }
            }
            guard isSEI else { return true }
            guard let rbsp = unescape(bytes, start: start + headerSize, end: end),
                  let carriesMetadata = scanSEI(rbsp, payload: payload) else { return false }
            found = found || carriesMetadata
            return true
        }

        switch framing {
        case .lengthPrefixed(let width):
            guard (1...4).contains(width) else { return false }
            var offset = 0
            while offset < bytes.count, !found {
                guard bytes.count - offset >= width else { return found }
                var count = 0
                for index in offset..<(offset + width) { count = (count << 8) | Int(bytes[index]) }
                offset += width
                guard count > 0, count <= bytes.count - offset,
                      visit(offset, offset + count) else { return found }
                offset += count
            }
        case .annexB:
            var nalStart: Int?
            var zeros = 0
            for index in bytes.indices {
                let byte = bytes[index]
                if byte == 1, zeros >= 2 {
                    let end = index - zeros
                    if let start = nalStart {
                        guard visit(start, end) else { return found }
                        if found { return true }
                    } else if end != 0 {
                        return found
                    }
                    nalStart = index + 1
                }
                zeros = byte == 0 ? zeros + 1 : 0
            }
            guard let start = nalStart, visit(start, bytes.count - zeros) else { return found }
        }
        return found
    }

    /// Reject malformed escapes as well as unescaped start-code emulation in an SEI NAL.
    private static func unescape(
        _ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int
    ) -> [UInt8]? {
        var rbsp: [UInt8] = []
        var zeros = 0
        for index in start..<end {
            let byte = bytes[index]
            if zeros >= 2 {
                if byte == 3 {
                    guard index + 1 < end, bytes[index + 1] <= 3 else { return nil }
                    zeros = 0
                    continue
                }
                if byte < 3 { return nil }
            }
            rbsp.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return rbsp
    }

    /// Nil denotes malformed SEI framing; false is a well-formed SEI without HDR10+. A message this
    /// walk has already VALIDATED outranks framing it cannot finish reading, so nil is only ever the
    /// answer when nothing was confirmed.
    private static func scanSEI(_ bytes: [UInt8], payload: (UnsafePointer<UInt8>, Int) -> Bool) -> Bool? {
        var offset = 0
        var found = false
        func extendedValue() -> Int? {
            var value = 0
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                let (sum, overflow) = value.addingReportingOverflow(Int(byte))
                guard !overflow else { return nil }
                value = sum
                if byte != 255 { return value }
            }
            return nil
        }
        while offset < bytes.count {
            if offset == bytes.count - 1, bytes[offset] == 0x80 { return found }
            guard let type = extendedValue(), let size = extendedValue(),
                  size <= bytes.count - offset else { return found ? true : nil }
            if type == 4 {
                let valid = bytes.withUnsafeBufferPointer {
                    payload($0.baseAddress! + offset, size)
                }
                found = found || valid
            }
            offset += size
        }
        return found ? true : nil // rbsp_trailing_bits is mandatory.
    }

    // MARK: - AV1 low-overhead OBU stream (demuxed packet framing)

    /// Same contract as `scanNALs`: an aborted walk reports what it validated, never less.
    private static func scanOBUs(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var offset = 0
        var found = false
        while offset < bytes.count, !found {
            let header = bytes[offset]
            offset += 1
            guard header & 0x81 == 0 else { return found }
            let type = (header >> 3) & 15
            if header & 4 != 0 {
                guard offset < bytes.count, bytes[offset] & 7 == 0 else { return found }
                offset += 1
            }
            let size: Int
            if header & 2 != 0 {
                guard let declared = leb128(bytes, offset: &offset, end: bytes.count),
                      declared <= bytes.count - offset else { return found }
                size = declared
            } else {
                size = bytes.count - offset
            }
            let end = offset + size
            if type == 5 {
                guard let metadataType = leb128(bytes, offset: &offset, end: end) else { return found }
                if metadataType == 4 {
                    // AV1 permits arbitrarily many trailing zero bytes after the stop bit.
                    // They belong to the OBU, not to the byte-aligned T.35 payload.
                    var trailing = end
                    while trailing > offset, bytes[trailing - 1] == 0 { trailing -= 1 }
                    guard trailing > offset, bytes[trailing - 1] == 0x80 else { return found }
                    found = validT35(bytes.baseAddress! + offset, trailing - offset - 1) || found
                }
            }
            offset = end
        }
        return found
    }

    private static func leb128(
        _ bytes: UnsafeBufferPointer<UInt8>, offset: inout Int, end: Int
    ) -> Int? {
        var value: UInt64 = 0
        for index in 0..<8 {
            guard offset < end else { return nil }
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 {
                // AV1 restricts leb128 values to 32 bits, even with an eight-byte encoding.
                return value <= UInt32.max ? Int(value) : nil
            }
        }
        return nil
    }

    // MARK: - Complete ST 2094-40 validation

    private static func validT35(_ bytes: UnsafePointer<UInt8>, _ size: Int) -> Bool {
        guard size > t35Header.count, size - t35Header.count <= Int(AV_HDR_PLUS_MAX_PAYLOAD_SIZE),
              t35Header.indices.allSatisfy({ bytes[$0] == t35Header[$0] }),
              let metadata = av_dynamic_hdr_plus_alloc(nil) else { return false }
        defer { av_free(metadata) }
        let body = bytes + t35Header.count
        let bodySize = size - t35Header.count
        guard av_dynamic_hdr_plus_from_t35(metadata, body, bodySize) >= 0,
              let bitCount = validatedBitCount(metadata.pointee),
              (bitCount + 7) / 8 == bodySize else { return false }
        let padding = bodySize * 8 - bitCount
        return body[bodySize - 1] & UInt8((1 << padding) - 1) == 0
    }

    private static func validSideData(_ bytes: UnsafePointer<UInt8>, size: Int) -> Bool {
        var allocationSize = 0
        guard let metadata = av_dynamic_hdr_plus_alloc(&allocationSize) else { return false }
        defer { av_free(metadata) }
        guard size == allocationSize else { return false }
        // Packet side data is not required to have the alignment of AVDynamicHDRPlus.
        memcpy(metadata, bytes, size)
        // matroskadec validates and strips the T.35 header, leaving this field zero.
        guard metadata.pointee.itu_t_t35_country_code == 0 ||
              metadata.pointee.itu_t_t35_country_code == 0xB5 else { return false }
        return validatedBitCount(metadata.pointee) != nil
    }

    /// Check every active field before trusting a decoded struct. In particular, FFmpeg's
    /// serializer is not a validator: invalid counts can read out of bounds, and a zero
    /// rational denominator can divide by zero. Do not feed untrusted side data to it.
    private static func validatedBitCount(_ metadata: AVDynamicHDRPlus) -> Int? {
        let windows = Int(metadata.num_windows)
        guard (1...3).contains(windows), metadata.application_version <= 1,
              rational(metadata.targeted_system_display_maximum_luminance, scale: 1, maximum: 0x7FFFFFF),
              metadata.targeted_system_display_actual_peak_luminance_flag <= 1,
              metadata.mastering_display_actual_peak_luminance_flag <= 1 else { return nil }
        var bits = 8 + 2 + 153 * (windows - 1) + 27 + 1 + 1

        func grid<T>(_ flag: UInt8, _ rows: UInt8, _ columns: UInt8, _ values: T) -> Bool {
            guard flag != 0 else { return true }
            guard (2...25).contains(rows), (2...25).contains(columns) else { return false }
            bits += 10 + Int(rows) * Int(columns) * 4
            return withUnsafeBytes(of: values) { storage in
                let entries = storage.bindMemory(to: AVRational.self)
                for row in 0..<Int(rows) {
                    for column in 0..<Int(columns) {
                        if !rational(entries[row * 25 + column], scale: 15, maximum: 15) { return false }
                    }
                }
                return true
            }
        }
        guard grid(metadata.targeted_system_display_actual_peak_luminance_flag,
                   metadata.num_rows_targeted_system_display_actual_peak_luminance,
                   metadata.num_cols_targeted_system_display_actual_peak_luminance,
                   metadata.targeted_system_display_actual_peak_luminance),
              grid(metadata.mastering_display_actual_peak_luminance_flag,
                   metadata.num_rows_mastering_display_actual_peak_luminance,
                   metadata.num_cols_mastering_display_actual_peak_luminance,
                   metadata.mastering_display_actual_peak_luminance) else { return nil }

        let valid = withUnsafeBytes(of: metadata.params) { storage in
            let params = storage.bindMemory(to: AVHDRPlusColorTransformParams.self)
            for index in 0..<windows {
                let window = params[index]
                if index > 0 {
                    guard rational(window.window_upper_left_corner_x, scale: 1, maximum: 65535),
                          rational(window.window_upper_left_corner_y, scale: 1, maximum: 65535),
                          rational(window.window_lower_right_corner_x, scale: 1, maximum: 65535),
                          rational(window.window_lower_right_corner_y, scale: 1, maximum: 65535),
                          window.rotation_angle <= 180,
                          window.semimajor_axis_internal_ellipse > 0,
                          window.semimajor_axis_external_ellipse >= window.semimajor_axis_internal_ellipse,
                          window.semiminor_axis_external_ellipse > 0,
                          (window.overlap_process_option.rawValue == 0 ||
                           window.overlap_process_option.rawValue == 1) else { return false }
                }
                let percentiles = Int(window.num_distribution_maxrgb_percentiles)
                guard percentiles <= 15,
                      rational(window.maxscl.0, scale: 100000, maximum: 100000),
                      rational(window.maxscl.1, scale: 100000, maximum: 100000),
                      rational(window.maxscl.2, scale: 100000, maximum: 100000),
                      rational(window.average_maxrgb, scale: 100000, maximum: 100000),
                      rational(window.fraction_bright_pixels, scale: 1000, maximum: 1000),
                      window.tone_mapping_flag <= 1,
                      window.color_saturation_mapping_flag <= 1 else { return false }
                let validPercentiles = withUnsafeBytes(of: window.distribution_maxrgb) { storage in
                    storage.bindMemory(to: AVHDRPlusPercentile.self).prefix(percentiles).allSatisfy {
                        $0.percentage <= 100 && rational($0.percentile, scale: 100000, maximum: 100000)
                    }
                }
                guard validPercentiles else { return false }
                bits += 82 + percentiles * 24 + 1 + 1
                if window.tone_mapping_flag != 0 {
                    let anchors = Int(window.num_bezier_curve_anchors)
                    guard anchors <= 15,
                          rational(window.knee_point_x, scale: 4095, maximum: 4095),
                          rational(window.knee_point_y, scale: 4095, maximum: 4095) else { return false }
                    let validAnchors = withUnsafeBytes(of: window.bezier_curve_anchors) { storage in
                        storage.bindMemory(to: AVRational.self).prefix(anchors).allSatisfy {
                            rational($0, scale: 1023, maximum: 1023)
                        }
                    }
                    guard validAnchors else { return false }
                    bits += 28 + anchors * 10
                }
                if window.color_saturation_mapping_flag != 0 {
                    guard rational(window.color_saturation_weight, scale: 8, maximum: 63) else { return false }
                    bits += 6
                }
            }
            return true
        }
        return valid ? bits : nil
    }

    private static func rational(_ value: AVRational, scale: Int64, maximum: Int64) -> Bool {
        guard value.den > 0, value.num >= 0 else { return false }
        let scaled = Int64(value.num) * scale
        return scaled % Int64(value.den) == 0 && scaled / Int64(value.den) <= maximum
    }
}
