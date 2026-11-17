import Foundation

/// H.265 picture order count (ITU-T H.265 §8.3.1) for one layer, read from the parameter sets and
/// the first slice segment header of each picture. Nothing is decoded: the POC is what puts a
/// picture in display order, and the two layers of a Dolby Vision profile 7 stream are paired by it.
///
/// Feed every NAL of the layer in decode order. Anything it cannot follow (a slice whose PPS or SPS
/// it has not seen, a truncated header, pictures before the first IRAP) answers nil rather than a guess.
struct HEVCPictureOrderCount {

    struct Picture: Equatable {
        let poc: Int
        /// An IRAP with NoRaslOutputFlag = 1 (IDR, BLA, or a CRA that opens the bitstream, follows an
        /// end of sequence, or follows a seek): POC numbering restarts here.
        let startsSequence: Bool
    }

    private struct SPS { let pocLsbBits: Int; let separateColourPlane: Bool }
    private struct PPS { let sps: Int; let outputFlagPresent: Bool; let extraSliceHeaderBits: Int }

    private var sps: [Int: SPS] = [:]
    private var pps: [Int: PPS] = [:]
    private var prevTid0POC = 0
    /// True until an IRAP has opened a sequence; set again by `reset()` and by an end of sequence.
    private var awaitingIRAP = true
    /// True while the most recent IRAP had NoRaslOutputFlag = 1 and can have RASL pictures: those
    /// reference pictures before the IRAP that a decoder starting here never had, so they are not
    /// output (§8.1.3) and get no POC here. A CRA that follows a picture in the same sequence has
    /// NoRaslOutputFlag = 0, and its RASL pictures are ordinary output pictures.
    private var skippingRASL = false

    /// After a seek: the next IRAP is handled as the first picture of the bitstream (HandleCraAsBlaFlag)
    /// and pictures before it get no POC. Parameter sets are kept.
    mutating func reset() {
        awaitingIRAP = true
    }

    /// Feeds one NAL (2-byte header included, emulation prevention bytes intact). Returns the POC when
    /// the NAL is the first slice segment of a picture.
    mutating func feed(_ nal: UnsafePointer<UInt8>, _ len: Int) -> Picture? {
        guard len > 2 else { return nil }
        let type = Int((nal[0] >> 1) & 0x3F)
        switch type {
        case 33: parseSPS(nal, len); return nil
        case 34: parsePPS(nal, len); return nil
        case 36, 37: awaitingIRAP = true; return nil      // end of sequence / end of bitstream
        case 0...9, 16...21: return parseSlice(type: type, temporalId: Int(nal[1] & 7) - 1, nal, len)
        default: return nil
        }
    }

    /// Parameter sets carried outside the stream (the hvcC arrays).
    mutating func feedParameterSets(_ nals: [[UInt8]]) {
        for nal in nals {
            nal.withUnsafeBufferPointer { b in
                if let base = b.baseAddress { _ = feed(base, b.count) }
            }
        }
    }

    // MARK: - Parsing

    private static func reader(_ nal: UnsafePointer<UInt8>, _ len: Int, limit: Int) -> H264SPS.BitReader {
        // The fields read here sit well inside the first bytes; cap the unescape at `limit`.
        H264SPS.BitReader(A53SEIParser.unescapeRBSP(nal + 2, min(len, limit) - 2))
    }

    private mutating func parseSPS(_ nal: UnsafePointer<UInt8>, _ len: Int) {
        var r = Self.reader(nal, len, limit: 256)
        guard r.u(4) != nil, let subLayers = r.u(3), r.u(1) != nil,
              r.skip(88), r.skip(8) else { return }             // general profile_tier_level, level_idc
        var present: [(profile: Bool, level: Bool)] = []
        for _ in 0..<subLayers {
            guard let p = r.flag(), let l = r.flag() else { return }
            present.append((p, l))
        }
        if subLayers > 0 { guard r.skip(2 * (8 - subLayers)) else { return } }
        for p in present {
            guard r.skip(p.profile ? 88 : 0), r.skip(p.level ? 8 : 0) else { return }
        }
        // sps_seq_parameter_set_id is at most 15 and pps_pic_parameter_set_id at most 63 (7.4.3.2,
        // 7.4.3.3): a stream naming more would otherwise grow these maps by one entry per NAL.
        guard let id = r.ue(), id <= 15, let chroma = r.ue() else { return }
        var separate = false
        if chroma == 3 { guard let f = r.flag() else { return }; separate = f }
        guard r.ue() != nil, r.ue() != nil, let window = r.flag() else { return }   // width, height
        if window { for _ in 0..<4 { guard r.ue() != nil else { return } } }
        guard r.ue() != nil, r.ue() != nil, let lsb = r.ue(), lsb <= 12 else { return }   // bit depths
        sps[id] = SPS(pocLsbBits: lsb + 4, separateColourPlane: separate)
    }

    private mutating func parsePPS(_ nal: UnsafePointer<UInt8>, _ len: Int) {
        var r = Self.reader(nal, len, limit: 32)
        guard let id = r.ue(), id <= 63, let spsID = r.ue(), spsID <= 15, r.flag() != nil,   // dependent_slice_segments_enabled
              let outputFlag = r.flag(), let extra = r.u(3) else { return }
        pps[id] = PPS(sps: spsID, outputFlagPresent: outputFlag, extraSliceHeaderBits: extra)
    }

    private mutating func parseSlice(type: Int, temporalId: Int, _ nal: UnsafePointer<UInt8>, _ len: Int) -> Picture? {
        let irap = (16...23).contains(type)
        var r = Self.reader(nal, len, limit: 64)
        guard r.flag() == true else { return nil }                    // first_slice_segment_in_pic_flag
        if irap { guard r.flag() != nil else { return nil } }        // no_output_of_prior_pics_flag
        guard let ppsID = r.ue(), let p = pps[ppsID], let s = sps[p.sps] else { return nil }
        guard r.skip(p.extraSliceHeaderBits), r.ue() != nil else { return nil }   // slice_reserved_flag, slice_type
        if p.outputFlagPresent { guard r.flag() != nil else { return nil } }
        if s.separateColourPlane { guard r.skip(2) else { return nil } }

        let idr = type == 19 || type == 20
        var lsb = 0
        if !idr { guard let v = r.u(s.pocLsbBits) else { return nil }; lsb = v }

        if awaitingIRAP && !irap { return nil }                       // not decodable before an IRAP
        let startsSequence = idr || (16...18).contains(type) || (irap && awaitingIRAP)
        // NoRaslOutputFlag of an IRAP is 1 for IDR, BLA and a CRA that starts the sequence; an IDR
        // has no RASL pictures at all. RASL_N / RASL_R (8, 9) of such an IRAP are skipped.
        if irap { skippingRASL = startsSequence && !idr }
        if skippingRASL && (type == 8 || type == 9) { return nil }
        let msb: Int
        if startsSequence {
            msb = 0
            awaitingIRAP = false
        } else {
            let maxLsb = 1 << s.pocLsbBits
            let prevLsb = prevTid0POC & (maxLsb - 1)
            let prevMsb = prevTid0POC - prevLsb
            if lsb < prevLsb && prevLsb - lsb >= maxLsb / 2 {
                msb = prevMsb + maxLsb
            } else if lsb > prevLsb && lsb - prevLsb > maxLsb / 2 {
                msb = prevMsb - maxLsb
            } else {
                msb = prevMsb
            }
        }
        let poc = msb + lsb
        // prevTid0Pic: TemporalId 0 and not a RASL, RADL or sub-layer non-reference picture.
        let leading = (6...9).contains(type)
        let subLayerNonReference = type <= 14 && type % 2 == 0
        if temporalId == 0 && !leading && !subLayerNonReference {
            prevTid0POC = poc
        }
        return Picture(poc: poc, startsSequence: startsSequence)
    }
}
