import Foundation

/// Minimal H.264 SPS reader for SSAI direct play: ad creatives arrive mid-stream on a new PID with unparsed codecpar (width/height==0); calling avformat_find_stream_info would block the live pump. Field order per ITU-T H.264 §7.3.2.1.1.
enum H264SPS {

    static let maxDimension = 16384

    /// Parse cropped dimensions from a raw SPS NAL (with 1-byte NAL header, e.g. 0x67). Returns nil on malformed input.
    static func dimensions(fromNAL nal: [UInt8]) -> (width: Int, height: Int)? {
        parse(fromNAL: nal).map { ($0.width, $0.height) }
    }

    /// frame_mbs_only_flag from a raw SPS NAL. false = the stream may code interlaced pictures (PAFF or
    /// MBAFF). #150: consulted as routing fallback when the demuxer's field_order probe stays UNKNOWN.
    static func frameMbsOnly(fromNAL nal: [UInt8]) -> Bool? {
        parse(fromNAL: nal)?.frameMbsOnly
    }

    /// The part of an SPS a decoder session is built from: profile_idc and every field from
    /// chroma_format_idc through the cropping window, packed bit for bit. Constraint flags, level_idc,
    /// the set's ID and the VUI are left out, since a change confined to them plays on the native
    /// route with the original sample description (#785 follow-up, measured on macOS).
    static func decoderSignature(fromNAL nal: [UInt8]) -> [UInt8]? {
        parse(fromNAL: nal)?.signature
    }

    /// What a slice header parser needs from the SPS to reach `field_pic_flag` (AE#1070).
    struct SliceContext: Equatable, Sendable {
        let separateColourPlane: Bool
        let log2MaxFrameNum: Int
        let frameMbsOnly: Bool
    }

    static func sliceContext(fromNAL nal: [UInt8]) -> SliceContext? {
        parse(fromNAL: nal)?.slice
    }

    /// First SPS NAL (incl. 1-byte header) from codecpar extradata, accepting both layouts: Annex-B
    /// (MPEG-TS, start-code delimited) and avcC (MP4/MKV, configurationVersion byte 0x01 then
    /// length-prefixed parameter sets). Returns nil when neither layout yields an SPS.
    static func spsNAL(fromExtradata extradata: [UInt8]) -> [UInt8]? {
        guard extradata.count > 1 else { return nil }
        if extradata[0] == 0x01 {
            // avcC: version, profile, compat, level, lengthSizeMinusOne, numSPS (low 5 bits), then
            // per-SPS 2-byte length + NAL.
            guard extradata.count > 8, (extradata[5] & 0x1f) >= 1 else { return nil }
            let len = (Int(extradata[6]) << 8) | Int(extradata[7])
            guard len > 0, extradata.count >= 8 + len else { return nil }
            let nal = Array(extradata[8..<(8 + len)])
            return (nal[0] & 0x1f) == 7 ? nal : nil
        }
        return extradata.withUnsafeBufferPointer { extractSPSandPPS(fromAnnexB: $0)?.sps }
    }

    private static func parse(fromNAL nal: [UInt8]) -> (width: Int, height: Int, frameMbsOnly: Bool, signature: [UInt8], slice: SliceContext)? {
        guard nal.count > 1, (nal[0] & 0x1f) == 7 else { return nil }
        let rbsp = unescape(Array(nal[1...]))  // strip NAL header + emulation-prevention (00 00 03 -> 00 00)
        var r = BitReader(rbsp)

        guard let profileIdc = r.u(8) else { return nil }
        _ = r.u(8)                  // constraint flags + reserved
        _ = r.u(8)                  // level_idc
        guard r.ue() != nil else { return nil } // seq_parameter_set_id
        let coreStart = r.position

        var chromaFormatIdc = 1
        var separateColourPlane = false
        let highProfiles: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        if highProfiles.contains(profileIdc) {
            guard let cf = r.ue() else { return nil }
            chromaFormatIdc = cf
            if cf == 3 { separateColourPlane = r.flag() == true }
            guard r.ue() != nil, r.ue() != nil else { return nil } // bit_depth_luma/chroma -8
            _ = r.flag()                            // qpprime_y_zero_transform_bypass
            if r.flag() == true {                   // seq_scaling_matrix_present
                let count = (chromaFormatIdc != 3) ? 8 : 12
                for i in 0..<count {
                    if r.flag() == true {           // scaling_list_present
                        skipScalingList(&r, size: i < 6 ? 16 : 64)
                    }
                }
            }
        }

        guard let log2MaxFrameNumMinus4 = r.ue() else { return nil }
        guard let pocType = r.ue() else { return nil }
        if pocType == 0 {
            guard r.ue() != nil else { return nil }  // log2_max_pic_order_cnt_lsb_minus4
        } else if pocType == 1 {
            _ = r.flag()                             // delta_pic_order_always_zero
            guard r.se() != nil, r.se() != nil else { return nil } // offset_for_non_ref / top_to_bottom
            guard let n = r.ue() else { return nil } // num_ref_frames_in_poc_cycle
            for _ in 0..<n { guard r.se() != nil else { return nil } }
        }
        guard r.ue() != nil else { return nil }      // max_num_ref_frames
        _ = r.flag()                                 // gaps_in_frame_num_value_allowed

        guard let widthMbsMinus1 = r.ue(),
              let heightMapUnitsMinus1 = r.ue() else { return nil }
        guard let frameMbsOnly = r.flag() else { return nil }

        // 16384 matches H264ConfigurationTracker; level 6.2 tops out at 8192x4320 (audit BIT-201).
        guard widthMbsMinus1 < Self.maxDimension / 16, heightMapUnitsMinus1 < Self.maxDimension / 16 else { return nil }
        let mbWidth = widthMbsMinus1 + 1
        let mbHeight = (heightMapUnitsMinus1 + 1) * (frameMbsOnly ? 1 : 2)
        var width = mbWidth * 16
        var height = mbHeight * 16

        if !frameMbsOnly { _ = r.flag() }            // mb_adaptive_frame_field
        _ = r.flag()                                 // direct_8x8_inference

        if r.flag() == true {                        // frame_cropping_flag
            guard let cl = r.ue(), let cr = r.ue(),
                  let ct = r.ue(), let cb = r.ue() else { return nil }
            // Crop units in luma samples. 4:2:0 -> (2,2); 4:2:2 -> (2,1);
            // 4:4:4 / monochrome -> (1,1). frame_mbs_only adds a y factor.
            let subW: Int, subH: Int
            switch chromaFormatIdc {
            case 1: subW = 2; subH = 2     // 4:2:0
            case 2: subW = 2; subH = 1     // 4:2:2
            default: subW = 1; subH = 1    // 4:4:4 / monochrome
            }
            let stepX = subW
            let stepY = subH * (frameMbsOnly ? 1 : 2)
            width -= (cl + cr) * stepX
            height -= (ct + cb) * stepY
        }

        guard width > 0, height > 0, width <= Self.maxDimension, height <= Self.maxDimension else { return nil }
        var core = BitReader(rbsp), signature = [UInt8(profileIdc)], packed = 0, count = 0
        _ = core.u(coreStart)
        for _ in coreStart..<r.position {
            guard let b = core.u(1) else { return nil }
            packed = (packed << 1) | b; count += 1
            if count == 8 { signature.append(UInt8(packed)); packed = 0; count = 0 }
        }
        if count > 0 { signature.append(UInt8(packed << (8 - count))) }
        let slice = SliceContext(separateColourPlane: separateColourPlane,
                                 log2MaxFrameNum: log2MaxFrameNumMinus4 + 4, frameMbsOnly: frameMbsOnly)
        return (width, height, frameMbsOnly, signature, slice)
    }

    private static func nalRanges(_ data: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        AnnexB.nalRanges(UnsafeRawBufferPointer(data))
    }

    /// Scan Annex-B for the first SPS (NAL type 7) and PPS (NAL type 8), returned with their 1-byte NAL header.
    static func extractSPSandPPS(fromAnnexB data: UnsafeBufferPointer<UInt8>) -> (sps: [UInt8], pps: [UInt8])? {
        var sps: [UInt8]?
        var pps: [UInt8]?
        for range in nalRanges(data) {
            let type = data[range.lowerBound] & 0x1f
            if type == 7, sps == nil { sps = Array(data[range]) }
            else if type == 8, pps == nil { pps = Array(data[range]) }
            if sps != nil, pps != nil { break }
        }
        if let sps, let pps { return (sps, pps) }
        return nil
    }

    /// AE#627: whether a decoder can start at this access unit. An IDR slice qualifies, and so does a
    /// picture coded only in I/SI slices behind a recovery point SEI with `recovery_frame_cnt == 0`:
    /// every picture from it on in output order decodes exactly (H.264 D.2.8), and the leading
    /// pictures that do not are dropped behind the gate. Some broadcast encoders never send an IDR,
    /// so on those feeds a gate that required one never opened. A recovery point with a later
    /// recovery frame (gradual refresh) is not an entry point and stays refused.
    static func isRandomAccessEntry(fromAnnexB data: UnsafeBufferPointer<UInt8>) -> Bool {
        var recoversHere = false
        var sawSlice = false
        var allIntra = true
        for range in nalRanges(data) {
            let start = range.lowerBound, j = range.upperBound
            switch data[start] & 0x1f {
            case 5:
                return true
            case 1:
                sawSlice = true
                // first_mb_in_slice and slice_type sit in the first few bytes.
                let head = unescape(Array(data[(start + 1)..<min(j, start + 17)]))
                var r = BitReader(head)
                guard r.ue() != nil, let sliceType = r.ue() else { return false }
                if sliceType % 5 != 2 && sliceType % 5 != 4 { allIntra = false }
            case 6:
                if recoveryFrameCount(seiRBSP: unescape(Array(data[(start + 1)..<j]))) == 0 {
                    recoversHere = true
                }
            default:
                break
            }
        }
        return recoversHere && sawSlice && allIntra
    }

    /// `recovery_frame_cnt` of the recovery point message in one SEI NAL payload (header stripped), nil if absent.
    static func recoveryFrameCount(seiRBSP rbsp: [UInt8]) -> Int? {
        var p = 0
        func sei() -> Int? {
            var v = 0
            while p < rbsp.count, rbsp[p] == 0xff { v += 255; p += 1 }
            guard p < rbsp.count else { return nil }
            v += Int(rbsp[p]); p += 1
            return v
        }
        while p < rbsp.count, rbsp[p] != 0x80 {
            guard let type = sei(), let size = sei(), p + size <= rbsp.count else { return nil }
            if type == 6 {
                var r = BitReader(Array(rbsp[p..<(p + size)]))
                return r.ue()
            }
            p += size
        }
        return nil
    }

    /// Build Annex-B extradata the mov muxer accepts directly; ff_isom_write_avcc sniffs the start code and packs avcC.
    static func annexBExtradata(sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        let sc: [UInt8] = [0, 0, 0, 1]
        return sc + sps + sc + pps
    }

    /// Remove emulation-prevention bytes (00 00 03 -> 00 00), by the one rule every parser here shares.
    static func unescape(_ b: [UInt8]) -> [UInt8] { A53SEIParser.unescapeRBSP(b) }

    private static func skipScalingList(_ r: inout BitReader, size: Int) {
        var lastScale = 8, nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                guard let delta = r.se() else { return }
                nextScale = (lastScale + delta + 256) % 256
            }
            lastScale = (nextScale == 0) ? lastScale : nextScale
        }
    }

    struct BitReader {  // big-endian bit reader with Exp-Golomb (ue/se) support
        private let bytes: [UInt8]
        private var bit = 0
        init(_ b: [UInt8]) { bytes = b }
        var position: Int { bit }

        mutating func u(_ n: Int) -> Int? {
            var v = 0
            for _ in 0..<n {
                let byteIdx = bit >> 3
                guard byteIdx < bytes.count else { return nil }
                let b = (Int(bytes[byteIdx]) >> (7 - (bit & 7))) & 1
                v = (v << 1) | b
                bit += 1
            }
            return v
        }

        mutating func flag() -> Bool? { u(1).map { $0 == 1 } }

        /// Skips `n` bits; false when that runs past the end.
        mutating func skip(_ n: Int) -> Bool {
            guard bit + n <= bytes.count * 8 else { return false }
            bit += n
            return true
        }

        /// The RBSP stop bit: the last bit set in the payload.
        var lastSetBit: Int? {
            guard let index = bytes.lastIndex(where: { $0 != 0 }) else { return nil }
            return index * 8 + 7 - bytes[index].trailingZeroBitCount
        }

        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let b = u(1) else { return nil }
                if b == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            if zeros == 0 { return 0 }
            guard let suffix = u(zeros) else { return nil }
            return (1 << zeros) - 1 + suffix
        }

        mutating func se() -> Int? {
            guard let k = ue() else { return nil }
            if k == 0 { return 0 }
            let mag = (k + 1) / 2
            return (k & 1) == 1 ? mag : -mag
        }
    }
}
