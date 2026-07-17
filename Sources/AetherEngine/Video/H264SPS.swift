import Foundation

/// Minimal H.264 SPS reader for SSAI direct play: ad creatives arrive mid-stream on a new PID with unparsed codecpar (width/height==0); calling avformat_find_stream_info would block the live pump. Field order per ITU-T H.264 §7.3.2.1.1.
enum H264SPS {

    /// Parse cropped dimensions from a raw SPS NAL (with 1-byte NAL header, e.g. 0x67). Returns nil on malformed input.
    static func dimensions(fromNAL nal: [UInt8]) -> (width: Int, height: Int)? {
        guard nal.count > 1, (nal[0] & 0x1f) == 7 else { return nil }
        let rbsp = unescape(Array(nal[1...]))  // strip NAL header + emulation-prevention (00 00 03 -> 00 00)
        var r = BitReader(rbsp)

        guard let profileIdc = r.u(8) else { return nil }
        _ = r.u(8)                  // constraint flags + reserved
        _ = r.u(8)                  // level_idc
        guard r.ue() != nil else { return nil } // seq_parameter_set_id

        var chromaFormatIdc = 1
        let highProfiles: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        if highProfiles.contains(profileIdc) {
            guard let cf = r.ue() else { return nil }
            chromaFormatIdc = cf
            if cf == 3 { _ = r.flag() }            // separate_colour_plane_flag
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

        guard r.ue() != nil else { return nil }     // log2_max_frame_num_minus4
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

        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Scan Annex-B for the first SPS (NAL type 7) and PPS (NAL type 8), returned with their 1-byte NAL header.
    static func extractSPSandPPS(fromAnnexB data: UnsafeBufferPointer<UInt8>) -> (sps: [UInt8], pps: [UInt8])? {
        var sps: [UInt8]?
        var pps: [UInt8]?
        var i = 0
        let n = data.count
        func startCode(at p: Int) -> Int {
            if p + 3 < n, data[p] == 0, data[p+1] == 0, data[p+2] == 0, data[p+3] == 1 { return 4 }
            if p + 2 < n, data[p] == 0, data[p+1] == 0, data[p+2] == 1 { return 3 }
            return 0
        }
        while i < n {
            let sc = startCode(at: i)
            if sc == 0 { i += 1; continue }
            let start = i + sc
            guard start < n else { break }
            var j = start
            while j < n, startCode(at: j) == 0 { j += 1 }
            let type = data[start] & 0x1f
            if type == 7, sps == nil { sps = Array(data[start..<j]) }
            else if type == 8, pps == nil { pps = Array(data[start..<j]) }
            if sps != nil, pps != nil { break }
            i = j
        }
        if let sps, let pps { return (sps, pps) }
        return nil
    }

    /// Scan Annex-B for a coded IDR slice NAL (type 5). #133: a mid-stream live join must open on a true
    /// IDR, not an open-GOP recovery-point I-slice (type 1) whose references precede the join point; starting
    /// there renders garbage (green frames) until the next real IDR. Cheap NAL-header walk, no RBSP parse.
    static func containsIDR(fromAnnexB data: UnsafeBufferPointer<UInt8>) -> Bool {
        var i = 0
        let n = data.count
        func startCode(at p: Int) -> Int {
            if p + 3 < n, data[p] == 0, data[p+1] == 0, data[p+2] == 0, data[p+3] == 1 { return 4 }
            if p + 2 < n, data[p] == 0, data[p+1] == 0, data[p+2] == 1 { return 3 }
            return 0
        }
        while i < n {
            let sc = startCode(at: i)
            if sc == 0 { i += 1; continue }
            let start = i + sc
            guard start < n else { break }
            if (data[start] & 0x1f) == 5 { return true }
            i = start
        }
        return false
    }

    /// Build Annex-B extradata the mov muxer accepts directly; ff_isom_write_avcc sniffs the start code and packs avcC.
    static func annexBExtradata(sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        let sc: [UInt8] = [0, 0, 0, 1]
        return sc + sps + sc + pps
    }

    private static func unescape(_ b: [UInt8]) -> [UInt8] {  // remove emulation-prevention bytes (00 00 03 -> 00 00)
        var out = [UInt8](); out.reserveCapacity(b.count)
        var zeros = 0
        var i = 0
        while i < b.count {
            let v = b[i]
            if zeros >= 2 && v == 0x03 && i + 1 < b.count && b[i + 1] <= 0x03 {
                zeros = 0; i += 1; continue // drop the 0x03
            }
            out.append(v)
            zeros = (v == 0) ? zeros + 1 : 0
            i += 1
        }
        return out
    }

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
