import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("HDR10PlusMetadataScan: structural metadata, not byte markers")
struct HDR10PlusMetadataScanTests {
    private static let header: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

    private struct BitWriter {
        var bits: [UInt8] = []
        mutating func write(_ value: Int, width: Int) {
            for shift in (0..<width).reversed() { bits.append(UInt8((value >> shift) & 1)) }
        }
        var bytes: [UInt8] {
            stride(from: 0, to: bits.count, by: 8).map { (start: Int) -> UInt8 in
                (0..<8).reduce(UInt8(0)) { (byte: UInt8, bit: Int) -> UInt8 in
                    let index: Int = start + bit
                    let nextBit: UInt8 = index < bits.count ? bits[index] : 0
                    let shiftedByte: UInt8 = byte << 1
                    return shiftedByte | nextBit
                }
            }
        }
    }

    /// A complete ST 2094-40 body, independently encoded rather than using the FFmpeg
    /// writer (which normalizes application_version and some optional fields).
    private static func t35(windows: Int = 1, grids: Bool = false, toneMapping: Bool = false) -> [UInt8] {
        var writer = BitWriter()
        writer.write(0, width: 8)
        writer.write(windows, width: 2)
        for _ in 1..<windows {
            for value in [0, 0, 1920, 1080, 960, 540] { writer.write(value, width: 16) }
            writer.write(0, width: 8)
            for value in [100, 200, 100] { writer.write(value, width: 16) }
            writer.write(0, width: 1)
        }
        writer.write(500, width: 27)
        func grid(_ writer: inout BitWriter) {
            writer.write(grids ? 1 : 0, width: 1)
            if grids {
                writer.write(25, width: 5)
                writer.write(25, width: 5)
                for _ in 0..<625 { writer.write(8, width: 4) }
            }
        }
        grid(&writer)
        for _ in 0..<windows {
            for value in [17000, 16000, 15000, 12000] { writer.write(value, width: 17) }
            writer.write(1, width: 4)
            writer.write(50, width: 7)
            writer.write(10000, width: 17)
            writer.write(100, width: 10)
        }
        grid(&writer)
        for _ in 0..<windows {
            writer.write(toneMapping ? 1 : 0, width: 1)
            if toneMapping {
                writer.write(1000, width: 12)
                writer.write(1200, width: 12)
                writer.write(2, width: 4)
                writer.write(100, width: 10)
                writer.write(200, width: 10)
            }
            writer.write(0, width: 1)
        }
        return header + writer.bytes
    }

    private static func escaped(_ rbsp: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 { bytes.append(3); zeros = 0 }
            bytes.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return bytes
    }

    private static func extended(_ value: Int) -> [UInt8] {
        Array(repeating: 255, count: value / 255) + [UInt8(value % 255)]
    }

    private static func message(_ payload: [UInt8], type: Int = 4) -> [UInt8] {
        extended(type) + extended(payload.count) + payload
    }

    private static func sei(_ payload: [UInt8]? = nil, hevc: Bool = true, suffix: Bool = false) -> [UInt8] {
        let header: [UInt8] = hevc ? [suffix ? 0x50 : 0x4E, 0x01] : [0x06]
        return header + escaped(message(payload ?? t35()) + [0x80])
    }

    private static func annexB(_ nal: [UInt8], fourBytes: Bool = true) -> [UInt8] {
        (fourBytes ? [0, 0, 0, 1] : [0, 0, 1]) + nal
    }

    private static func lengthPrefixed(_ nal: [UInt8], width: Int) -> [UInt8] {
        (0..<width).reversed().map { UInt8(truncatingIfNeeded: nal.count >> ($0 * 8)) } + nal
    }

    private static func leb128(_ value: Int) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            bytes.append(byte | (value == 0 ? 0 : 0x80))
        } while value > 0
        return bytes
    }

    private static func obu(_ payload: [UInt8], type: UInt8 = 5, sized: Bool = true,
                            extensionByte: UInt8? = nil) -> [UInt8] {
        let sizeFlag: UInt8 = sized ? 2 : 0
        let extensionFlag: UInt8 = extensionByte == nil ? 0 : 4
        let header: UInt8 = (type << 3) | sizeFlag | extensionFlag
        var bytes: [UInt8] = [header]
        if let extensionByte { bytes.append(extensionByte) }
        if sized { bytes.append(contentsOf: leb128(payload.count)) }
        bytes.append(contentsOf: payload)
        return bytes
    }

    private func scan(_ bytes: [UInt8], codecID: AVCodecID = AV_CODEC_ID_HEVC,
                      framing: VideoNALFraming = .annexB) -> Bool {
        bytes.withUnsafeBufferPointer {
            HDR10PlusMetadataScan.bytesCarryHDR10Plus(
                $0.baseAddress, size: $0.count, codecID: codecID, framing: framing)
        }
    }

    @Test("HEVC prefix/suffix and H.264 SEI work with either Annex B start-code width")
    func annexBMetadata() {
        for fourBytes in [false, true] {
            #expect(scan(Self.annexB(Self.sei(), fourBytes: fourBytes)))
            #expect(scan(Self.annexB(Self.sei(suffix: true), fourBytes: fourBytes)))
            #expect(scan(Self.annexB(Self.sei(hevc: false), fourBytes: fourBytes), codecID: AV_CODEC_ID_H264))
        }
        let aud: [UInt8] = [0x46, 0x01, 0x50]
        #expect(scan(Self.annexB(aud) + Self.annexB(Self.sei()) + [0, 0, 0]))
    }

    @Test("All supported length-prefix widths delimit metadata", arguments: [1, 2, 3, 4])
    func lengthPrefixedMetadata(width: Int) {
        for hevc in [true, false] {
            let payload = Self.lengthPrefixed(Self.sei(hevc: hevc), width: width)
            #expect(scan(payload, codecID: hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264,
                         framing: .lengthPrefixed(size: width)))
        }
    }

    @Test("EPB removal, extended SEI types/sizes, multiple messages and optional ST2094 fields")
    func completeSEIWalk() {
        let large = Self.t35(windows: 3, grids: true, toneMapping: true)
        #expect(large.count > 255)
        let rbsp = Self.message(Array(repeating: 0xAA, count: 260), type: 300)
            + Self.message(large) + [0x80]
        let escaped = Self.escaped(rbsp)
        #expect(escaped.count > rbsp.count)
        #expect(scan(Self.annexB([0x4E, 0x01] + escaped)))
    }

    /// Audit BIT-4: the prefilter must never hide a payload the full walk would confirm, in any
    /// framing, and must turn away a packet that has no T.35 header at all.
    @Test("The T.35 header prefilter keeps every carriage and rejects packets without the header")
    func t35PrefilterIsExact() {
        let carriers: [[UInt8]] = [
            Self.annexB(Self.sei()),
            Self.annexB(Self.sei(hevc: false), fourBytes: true),
            Self.lengthPrefixed(Self.sei(), width: 4),
            Self.annexB([0x4E, 0x01] + Self.escaped(
                Self.message(Self.t35(windows: 3, grids: true, toneMapping: true)) + [0x80])),
        ]
        for bytes in carriers {
            #expect(bytes.withUnsafeBufferPointer {
                HDR10PlusMetadataScan.mayContainT35Header($0.baseAddress!, size: $0.count)
            })
        }
        let slice = Self.annexB([0x26, 0x01] + [UInt8](repeating: 0x5A, count: 4096))
        #expect(!slice.withUnsafeBufferPointer {
            HDR10PlusMetadataScan.mayContainT35Header($0.baseAddress!, size: $0.count)
        })
        #expect(!scan(slice))
    }

    @Test("Raw markers, slices, parameter sets, and unregistered SEI never confirm")
    func nonMetadataMarkers() {
        #expect(!scan(Self.header))
        #expect(!scan(Self.t35()))
        for header in [[0x26, 0x01], [0x42, 0x01], [0x7C, 0x01]] as [[UInt8]] {
            #expect(!scan(Self.annexB(header + Self.escaped(Self.message(Self.t35()) + [0x80]))))
        }
        #expect(!scan(Self.annexB([0x65] + Self.escaped(Self.message(Self.t35()) + [0x80])),
                      codecID: AV_CODEC_ID_H264))
        #expect(!scan(Self.annexB([0x4E, 0x01] + Self.escaped(Self.message(Self.t35(), type: 5) + [0x80]))))
        #expect(!scan(Self.annexB(Self.sei()), codecID: AV_CODEC_ID_VP9))
        #expect(!scan(Self.annexB(Self.sei()), codecID: AV_CODEC_ID_MPEG2VIDEO))
    }

    @Test("Every registered T35 identifier is checked at the start of the SEI payload")
    func registeredIdentifiers() {
        for index in Self.header.indices {
            var payload = Self.t35()
            payload[index] ^= 1
            #expect(!scan(Self.annexB(Self.sei(payload))))
        }
        #expect(!scan(Self.annexB(Self.sei([0xAA] + Self.t35()))))
        #expect(!scan(Self.annexB(Self.sei(Self.header + [0x01]))))
        var wrongVersion = Self.t35()
        wrongVersion[6] = 255
        #expect(!scan(Self.annexB(Self.sei(wrongVersion))))
        wrongVersion[6] = 1
        #expect(scan(Self.annexB(Self.sei(wrongVersion))))
    }

    @Test("The complete ST2094 body must be present without extra bytes or nonzero padding")
    func bodyLengthAndPadding() {
        for payload in [Self.t35(), Self.t35(windows: 3, grids: true, toneMapping: true)] {
            for cut in 0..<payload.count {
                #expect(!scan(Self.annexB(Self.sei(Array(payload.prefix(cut))))))
            }
            #expect(!scan(Self.annexB(Self.sei(payload + [0]))))
        }
        var padding = Self.t35()
        padding[padding.count - 1] |= 1
        #expect(!scan(Self.annexB(Self.sei(padding))))
        var noWindows = Self.t35()
        noWindows[7] &= 0x3F
        #expect(!scan(Self.annexB(Self.sei(noWindows))))
    }

    @Test("NAL and SEI lengths, trailing bits, headers and escapes must be valid")
    func malformedNALs() {
        let nal = Self.sei()
        let packet = Self.lengthPrefixed(nal, width: 4)
        for cut in 0..<packet.count {
            #expect(!scan(Array(packet.prefix(cut)), framing: .lengthPrefixed(size: 4)))
        }
        for width in [0, -1, 5, Int.max] {
            #expect(!scan(packet, framing: .lengthPrefixed(size: width)))
        }
        #expect(!scan(Self.annexB(Array(nal.dropLast()))))
        #expect(!scan(Self.annexB([0xCE, 0x01] + nal.dropFirst(2))))
        #expect(!scan(Self.annexB([0x4E, 0x00] + nal.dropFirst(2))))
        #expect(!scan(Self.annexB([0x66] + Self.sei(hevc: false).dropFirst()), codecID: AV_CODEC_ID_H264))
        #expect(!scan([0xAA] + Self.annexB(nal)))
        for badRBSP in [[4, 255], [255], [4, 100, 0xB5, 0x80], [0, 0, 3], [0, 0, 3, 4]] as [[UInt8]] {
            #expect(!scan(Self.annexB([0x4E, 0x01] + badRBSP)))
        }
        #expect(!scan(Self.annexB([0x4E, 0x01] + Self.message(Self.t35(windows: 2)) + [0x80])))
        #expect(!HDR10PlusMetadataScan.bytesCarryHDR10Plus(nil, size: 10, codecID: AV_CODEC_ID_HEVC))
        #expect(!scan([]))
    }

    @Test("AV1 T35 metadata supports OBU size fields, extensions and an unsized final OBU")
    func av1Metadata() {
        for sized in [true, false] {
            for extensionByte in [nil, 0x28] as [UInt8?] {
                let packet = Self.obu([], type: 2)
                    + Self.obu([4] + Self.t35() + [0x80], sized: sized, extensionByte: extensionByte)
                #expect(scan(packet, codecID: AV_CODEC_ID_AV1))
            }
        }
        #expect(scan(Self.obu([0x84, 0] + Self.t35() + [0x80]), codecID: AV_CODEC_ID_AV1))
        #expect(scan(Self.obu([4] + Self.t35() + [0x80, 0, 0, 0]), codecID: AV_CODEC_ID_AV1))
        #expect(scan(Self.obu([4] + Self.t35(windows: 3, grids: true) + [0x80]), codecID: AV_CODEC_ID_AV1))
    }

    @Test("AV1 frame/tile/other metadata payloads are not T35 metadata")
    func av1NonMetadata() {
        for type in [1, 3, 4, 6, 15] as [UInt8] {
            #expect(!scan(Self.obu([4] + Self.t35() + [0x80], type: type), codecID: AV_CODEC_ID_AV1))
        }
        #expect(!scan(Self.obu([1] + Self.t35() + [0x80]), codecID: AV_CODEC_ID_AV1))
        #expect(!scan(Self.obu([4, 0xAA] + Self.t35() + [0x80]), codecID: AV_CODEC_ID_AV1))
    }

    @Test("AV1 truncation, invalid headers, LEB128 overflow and missing trailing bits fail closed")
    func av1Malformed() {
        let packet = Self.obu([4] + Self.t35() + [0x80])
        for cut in 0..<packet.count {
            #expect(!scan(Array(packet.prefix(cut)), codecID: AV_CODEC_ID_AV1))
        }
        for header in [0xAA, 0x2B] as [UInt8] {
            #expect(!scan([header] + packet.dropFirst(), codecID: AV_CODEC_ID_AV1))
        }
        #expect(!scan(Self.obu([4] + Self.t35() + [0x80], extensionByte: 1), codecID: AV_CODEC_ID_AV1))
        #expect(!scan(Self.obu([4] + Self.t35()), codecID: AV_CODEC_ID_AV1))
        #expect(!scan(Self.obu([4] + Self.t35() + [0]), codecID: AV_CODEC_ID_AV1))
        #expect(!scan([0x2A] + Array(repeating: 0x80, count: 8), codecID: AV_CODEC_ID_AV1))
        #expect(!scan([0x2A, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F], codecID: AV_CODEC_ID_AV1))
        #expect(!scan(Self.obu([0x80]), codecID: AV_CODEC_ID_AV1))
    }

    /// The scan answers ONE question: is validated ST 2094-40 metadata present. Damage further along a
    /// packet says nothing about a message already parsed in full, and treating it as a retraction is a
    /// false negative on real media, where a vendor SEI or a trailing byte next to the HDR10+ message is
    /// ordinary. Nothing here can invent a positive: only `validT35` ever sets one.
    @Test("A message validated in full outranks malformed framing that follows it")
    func damageAfterAValidatedMessage() {
        let nal = Self.sei()
        let lengthPrefixed = Self.lengthPrefixed(nal, width: 4)
        for junk in [[0], [0, 0, 0, 0], [0xFF, 0xFF, 0xFF, 0xFF]] as [[UInt8]] {
            #expect(scan(lengthPrefixed + junk, framing: .lengthPrefixed(size: 4)))
        }
        // A second NAL the walk cannot read: forbidden_zero_bit set, then temporal_id zero.
        for bad in [[0x82, 0x01, 0xAA], [0x4E, 0x00, 0xAA]] as [[UInt8]] {
            #expect(scan(Self.annexB(nal) + Self.annexB(bad)))
        }
        // rbsp_trailing_bits missing. Length-prefixed framing, because Annex B strips the zero bytes
        // ahead of a start code and the payload's own zero padding goes with them, which truncates the
        // message rather than damaging what follows it.
        #expect(scan(Self.lengthPrefixed(Array(nal.dropLast()), width: 4), framing: .lengthPrefixed(size: 4)))
        // A start code with nothing behind it.
        #expect(scan(Self.annexB(nal) + [0, 0, 1]))
        // A second SEI message whose declared size runs off the end of the same NAL.
        let overrunAfterMetadata = Self.message(Self.t35()) + [4, 100, 0x80]
        #expect(scan(Self.annexB([0x4E, 0x01] + Self.escaped(overrunAfterMetadata))))
        // AV1: a metadata OBU that validated, followed by an OBU with an unreadable size field.
        #expect(scan(Self.obu([4] + Self.t35() + [0x80]) + [0x2A], codecID: AV_CODEC_ID_AV1))
    }

    private func withPacket(
        _ payload: [UInt8] = [], _ body: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
        let packet = try #require(av_packet_alloc())
        defer {
            packet.pointee.data = nil
            packet.pointee.size = 0
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
        }
        try payload.withUnsafeBufferPointer {
            packet.pointee.data = UnsafeMutablePointer(mutating: $0.baseAddress)
            packet.pointee.size = Int32($0.count)
            try body(packet)
        }
    }

    private func addSideData(
        _ packet: UnsafeMutablePointer<AVPacket>, payload: [UInt8] = Self.t35(),
        mutate: (UnsafeMutablePointer<AVDynamicHDRPlus>) -> Void = { _ in }
    ) throws {
        var size = 0
        let metadata = try #require(av_dynamic_hdr_plus_alloc(&size))
        let parsed = payload.withUnsafeBufferPointer {
            av_dynamic_hdr_plus_from_t35(metadata, $0.baseAddress! + 6, $0.count - 6)
        }
        guard parsed >= 0 else {
            av_free(metadata)
            Issue.record("Independent ST2094 fixture did not parse: \(parsed)")
            return
        }
        mutate(metadata)
        let added = av_packet_add_side_data(
            packet, AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
            UnsafeMutableRawPointer(metadata).assumingMemoryBound(to: UInt8.self), size)
        if added < 0 {
            av_free(metadata)
            Issue.record("av_packet_add_side_data failed: \(added)")
        }
    }

    @Test("Real parsed Matroska side data is valid for VP9 and AV1 without a T35 header")
    func parsedPacketSideData() throws {
        for payload in [Self.t35(), Self.t35(windows: 3, grids: true, toneMapping: true)] {
            try withPacket { packet in
                try addSideData(packet, payload: payload)
                #expect(HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecID: AV_CODEC_ID_VP9))
                #expect(HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecID: AV_CODEC_ID_AV1))
                #expect(!HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecID: AV_CODEC_ID_AAC))
            }
        }
    }

    @Test("A side-data type alone, a raw T35 payload, and truncated or oversized structs are not proof")
    func malformedSideDataStorage() throws {
        var size = 0
        let metadata = try #require(av_dynamic_hdr_plus_alloc(&size))
        av_free(metadata)
        for length in [1, Self.t35().count, size - 1, size, size + 1] {
            try withPacket { packet in
                let bytes = try #require(av_packet_new_side_data(packet, AV_PKT_DATA_DYNAMIC_HDR10_PLUS, length))
                memset(bytes, 0, length)
                if length == Self.t35().count {
                    Self.t35().withUnsafeBufferPointer { _ = memcpy(bytes, $0.baseAddress!, $0.count) }
                }
                #expect(!HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecID: AV_CODEC_ID_AV1))
            }
        }
    }

    @Test("Malformed active side-data fields are rejected without invoking FFmpeg's unsafe writer")
    func malformedSideDataFields() throws {
        let mutations: [(UnsafeMutablePointer<AVDynamicHDRPlus>) -> Void] = [
            { $0.pointee.num_windows = 0 },
            { $0.pointee.num_windows = 4 },
            { $0.pointee.application_version = 255 },
            { $0.pointee.itu_t_t35_country_code = 0xB4 },
            { $0.pointee.targeted_system_display_maximum_luminance.den = 0 },
            { $0.pointee.params.0.maxscl.0.den = 0 },
            { $0.pointee.params.0.average_maxrgb.num = -1 },
            { $0.pointee.params.0.num_distribution_maxrgb_percentiles = 16 },
            { $0.pointee.params.0.distribution_maxrgb.0.percentage = 101 },
            { $0.pointee.params.0.fraction_bright_pixels.den = 0 },
            { $0.pointee.params.0.tone_mapping_flag = 2 },
            { $0.pointee.params.0.tone_mapping_flag = 1 },
            { $0.pointee.params.0.color_saturation_mapping_flag = 1 },
            { $0.pointee.targeted_system_display_actual_peak_luminance_flag = 1 },
            { $0.pointee.mastering_display_actual_peak_luminance_flag = 2 },
        ]
        for mutate in mutations {
            try withPacket { packet in
                try addSideData(packet, mutate: mutate)
                #expect(!HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecID: AV_CODEC_ID_AV1))
            }
        }
        let optionalMutations: [(UnsafeMutablePointer<AVDynamicHDRPlus>) -> Void] = [
            { $0.pointee.params.1.window_upper_left_corner_x.den = 0 },
            { $0.pointee.params.1.rotation_angle = 181 },
            { $0.pointee.params.0.num_bezier_curve_anchors = 16 },
            { $0.pointee.params.0.bezier_curve_anchors.0.den = 0 },
            { $0.pointee.params.0.knee_point_x.den = 0 },
            { $0.pointee.num_rows_targeted_system_display_actual_peak_luminance = 26 },
            { $0.pointee.num_cols_mastering_display_actual_peak_luminance = 1 },
            { $0.pointee.targeted_system_display_actual_peak_luminance.0.0.den = 0 },
            { $0.pointee.mastering_display_actual_peak_luminance.0.0.num = 16 },
        ]
        for mutate in optionalMutations {
            try withPacket { packet in
                try addSideData(packet, payload: Self.t35(windows: 3, grids: true, toneMapping: true),
                                mutate: mutate)
                #expect(!HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecID: AV_CODEC_ID_VP9))
            }
        }
        try withPacket(Self.annexB(Self.sei())) { packet in
            try addSideData(packet) { $0.pointee.num_windows = 0 }
            #expect(HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecID: AV_CODEC_ID_HEVC))
        }
    }

    @Test("Packet entry point derives avcC/hvcC framing and honors the playback override")
    func packetCodecParameters() throws {
        for hevc in [true, false] {
            let codec = hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264
            let parameters = try #require(avcodec_parameters_alloc())
            defer {
                parameters.pointee.extradata = nil
                parameters.pointee.extradata_size = 0
                var owned: UnsafeMutablePointer<AVCodecParameters>? = parameters
                avcodec_parameters_free(&owned)
            }
            parameters.pointee.codec_id = codec
            var extra = [UInt8](repeating: 0, count: hevc ? 23 : 7)
            extra[0] = 1
            extra[hevc ? 21 : 4] = 1 // two-byte NAL lengths, not the four-byte default
            try extra.withUnsafeMutableBufferPointer { buffer in
                parameters.pointee.extradata = buffer.baseAddress
                parameters.pointee.extradata_size = Int32(buffer.count)
                try withPacket(Self.lengthPrefixed(Self.sei(hevc: hevc), width: 2)) { packet in
                    #expect(HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecParameters: parameters))
                }
                try withPacket(Self.annexB(Self.sei(hevc: hevc))) { packet in
                    #expect(!HDR10PlusMetadataScan.packetCarriesHDR10Plus(packet, codecParameters: parameters))
                    #expect(HDR10PlusMetadataScan.packetCarriesHDR10Plus(
                        packet, codecParameters: parameters, framing: .annexB))
                }
            }
        }
    }

    @Test("Core Media's per-frame payload starts at the T.35 country code, from SEI and from side data")
    func coreMediaPayload() throws {
        // SEI: the validated message, verbatim and header first, whatever the framing.
        for hevc in [true, false] {
            let codec = hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264
            try withPacket(Self.lengthPrefixed(Self.sei(hevc: hevc), width: 4)) { packet in
                let payload = HDR10PlusMetadataScan.coreMediaPayload(
                    packet, codecID: codec, framing: .lengthPrefixed(size: 4))
                #expect(payload.map { [UInt8]($0) } == Self.t35())
            }
            try withPacket(Self.annexB(Self.sei(hevc: hevc))) { packet in
                let payload = HDR10PlusMetadataScan.coreMediaPayload(packet, codecID: codec, framing: .annexB)
                #expect(payload.map { [UInt8]($0) } == Self.t35())
            }
        }
        // Side data: libavutil's serialiser omits the six header bytes, which have to come back.
        for source in [Self.t35(), Self.t35(windows: 3, grids: true, toneMapping: true)] {
            try withPacket { packet in
                try addSideData(packet, payload: source)
                let payload = try #require(HDR10PlusMetadataScan.coreMediaPayload(
                    packet, codecID: AV_CODEC_ID_VP9, framing: .annexB))
                #expect(Array(payload.prefix(6)) == Self.header)
                #expect(payload.count == source.count)
                let metadata = try #require(av_dynamic_hdr_plus_alloc(nil))
                defer { av_free(metadata) }
                let parsed = payload.withUnsafeBytes {
                    av_dynamic_hdr_plus_from_t35(
                        metadata, $0.bindMemory(to: UInt8.self).baseAddress! + 6, payload.count - 6)
                }
                #expect(parsed >= 0)
            }
        }
        // Nothing to attach: a packet without the message, and a slice that only looks like one.
        try withPacket(Self.annexB([0x26, 0x01] + Self.header)) { packet in
            #expect(HDR10PlusMetadataScan.coreMediaPayload(packet, codecID: AV_CODEC_ID_HEVC, framing: .annexB) == nil)
        }
    }
}
