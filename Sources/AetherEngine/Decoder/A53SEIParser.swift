import Foundation

/// NAL framing of a packet payload: Annex B start codes (MPEG-TS) or length-prefixed
/// (avcC/hvcC extradata, e.g. Matroska/MP4 recordings).
///
/// Public because the DV P7 rewrite takes it (#365): a walker handed the wrong framing does not
/// fail, it reads NAL boundaries at arbitrary offsets and reports that it found nothing.
public enum VideoNALFraming: Equatable, Sendable {
    case annexB
    case lengthPrefixed(size: Int)
}

/// Extracts ATSC A/53 `cc_data` triplets from H.264 / HEVC video packet bitstreams (#131).
///
/// US broadcast/cable-sourced streams carry closed captions inside the picture as
/// `user_data_registered_itu_t_t35` SEI messages (country 0xB5, provider 0x0031,
/// user_identifier "GA94", user_data_type_code 0x03); FFmpeg's mpegts demuxer never synthesizes
/// a caption stream for them, so packet SEI is the only place they exist on the native remux
/// path. Pure and stateless; every length is bounds-checked and malformed input returns `[]`.
enum A53SEIParser {

    enum CodecKind {
        case h264
        case hevc
    }

    typealias NALFraming = VideoNALFraming

    /// "GA94" as raw bytes; static so the per-packet prefilter allocates nothing.
    private static let ga94Needle: [UInt8] = [0x47, 0x41, 0x39, 0x34]

    /// Resolve the framing once per session from codec extradata: avcC/hvcC config records start
    /// with configurationVersion 0x01 and carry lengthSizeMinusOne; Annex B extradata (or none,
    /// the MPEG-TS case) starts with a start code.
    static func nalFraming(codec: CodecKind, extradata: UnsafePointer<UInt8>?, size: Int) -> NALFraming {
        guard let ed = extradata, size >= 7, ed[0] == 0x01 else { return .annexB }
        switch codec {
        case .h264:
            return .lengthPrefixed(size: Int(ed[4] & 0x03) + 1)
        case .hevc:
            guard size >= 22 else { return .annexB }
            return .lengthPrefixed(size: Int(ed[21] & 0x03) + 1)
        }
    }

    /// Cheap prefilter so packets without captions skip the NAL walk. "GA94" contains no zero
    /// pair, so no emulation-prevention byte can split it; false positives (slice data) are
    /// rejected by the structural parse in `triplets(in:...)`.
    static func mayContainA53(_ data: UnsafePointer<UInt8>, _ size: Int) -> Bool {
        guard size >= 4 else { return false }
        return ga94Needle.withUnsafeBufferPointer { memmem(data, size, $0.baseAddress, $0.count) != nil }
    }

    /// All A53 `cc_data` triplets in the packet, in bitstream (decode) order.
    static func triplets(
        in data: UnsafePointer<UInt8>, size: Int, codec: CodecKind, framing: NALFraming
    ) -> [CCDataParser.CCTriplet] {
        guard mayContainA53(data, size) else { return [] }
        var out: [CCDataParser.CCTriplet] = []
        forEachSEIRBSP(data, size, codec: codec, framing: framing) { rbsp in
            forEachSEIPayload(rbsp) { type, offset, payloadSize in
                if type == 4, payloadSize > 0 {   // user_data_registered_itu_t_t35
                    parseT35(rbsp, offset: offset, size: payloadSize, into: &out)
                }
                return false
            }
            return false
        }
        return out
    }

    /// The unescaped RBSP of every SEI NAL in the packet, in bitstream order, until `body` returns
    /// true. Shared with the alternative-transfer scan (AE#839), which reads a different payload out of
    /// the same NALs.
    static func forEachSEIRBSP(
        _ data: UnsafePointer<UInt8>, _ size: Int, codec: CodecKind, framing: NALFraming,
        _ body: ([UInt8]) -> Bool
    ) {
        var done = false
        forEachNAL(data, size, framing) { nal, nalSize in
            guard !done else { return }
            let headerLen: Int
            let isSEI: Bool
            switch codec {
            case .h264:
                headerLen = 1
                isSEI = nalSize > 1 && (nal[0] & 0x1F) == 6
            case .hevc:
                headerLen = 2
                let type = nalSize > 2 ? (nal[0] >> 1) & 0x3F : 0xFF
                isSEI = type == 39 || type == 40   // prefix / suffix SEI
            }
            guard isSEI else { return }
            done = body(unescapeRBSP(nal + headerLen, nalSize - headerLen))
        }
    }

    // MARK: - NAL iteration

    /// Shared by the DV P7 RPU rewrite (#365), which has to walk the same NALs in the same framing.
    static func forEachNAL(
        _ data: UnsafePointer<UInt8>, _ size: Int, _ framing: NALFraming,
        _ body: (UnsafePointer<UInt8>, Int) -> Void
    ) {
        switch framing {
        case .annexB:
            AnnexB.forEachNALRange(data, count: size) { body(data + $0.lowerBound, $0.count) }
        case .lengthPrefixed(let lenSize):
            var i = 0
            while i + lenSize <= size {
                var nalLen = 0
                for k in 0..<lenSize { nalLen = (nalLen << 8) | Int(data[i + k]) }
                i += lenSize
                guard nalLen > 0, i + nalLen <= size else { return }
                body(data + i, nalLen)
                i += nalLen
            }
        }
    }

    /// Strip emulation-prevention bytes (00 00 03 -> 00 00). In a valid stream, a 0x03 after two
    /// zeros is always an EPB, so the unconditional drop matches FFmpeg's h2645 unescape.
    static func unescapeRBSP(_ p: UnsafePointer<UInt8>, _ n: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(n)
        var zeros = 0
        for i in 0..<max(0, n) {
            let b = p[i]
            if zeros >= 2, b == 0x03 {
                zeros = 0
            } else {
                out.append(b)
                zeros = b == 0x00 ? zeros + 1 : 0
            }
        }
        return out
    }

    static func unescapeRBSP(_ bytes: [UInt8]) -> [UInt8] {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return [] }
            return unescapeRBSP(base, buffer.count)
        }
    }

    // MARK: - SEI payload walk

    /// Every `sei_message` in one SEI RBSP as (payloadType, offset, payloadSize), until `body` returns
    /// true. Stops at the first message whose header or size runs past the RBSP.
    static func forEachSEIPayload(_ rbsp: [UInt8], _ body: (Int, Int, Int) -> Bool) {
        var i = 0
        let n = rbsp.count
        while i + 2 <= n {
            var payloadType = 0
            while i < n, rbsp[i] == 0xFF { payloadType += 255; i += 1 }
            guard i < n else { return }
            payloadType += Int(rbsp[i]); i += 1
            var payloadSize = 0
            while i < n, rbsp[i] == 0xFF { payloadSize += 255; i += 1 }
            guard i < n else { return }
            payloadSize += Int(rbsp[i]); i += 1
            guard i + payloadSize <= n else { return }
            if body(payloadType, i, payloadSize) { return }
            i += payloadSize
        }
    }

    private static func parseT35(
        _ rbsp: [UInt8], offset: Int, size: Int, into out: inout [CCDataParser.CCTriplet]
    ) {
        var i = offset
        let end = offset + size
        guard i + 8 <= end,
              rbsp[i] == 0xB5,                          // itu_t_t35_country_code: United States
              rbsp[i + 1] == 0x00, rbsp[i + 2] == 0x31, // provider: ATSC
              rbsp[i + 3] == 0x47, rbsp[i + 4] == 0x41, // "GA94"
              rbsp[i + 5] == 0x39, rbsp[i + 6] == 0x34,
              rbsp[i + 7] == 0x03                       // user_data_type_code: cc_data
        else { return }
        i += 8
        guard i + 2 <= end else { return }
        let flags = rbsp[i]                             // em_data(1) cc_data(1) additional(1) cc_count(5)
        guard (flags & 0x40) != 0 else { return }       // process_cc_data_flag
        let ccCount = Int(flags & 0x1F)
        i += 2                                          // flags + em_data byte
        guard ccCount > 0, i + ccCount * 3 <= end else { return }
        rbsp.withUnsafeBufferPointer { buf in
            out.append(contentsOf: CCDataParser.parseCCDataTriplets(
                bytes: buf.baseAddress! + i, count: ccCount * 3))
        }
    }
}
