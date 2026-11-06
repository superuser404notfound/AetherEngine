import Foundation
import Dovi

/// libdovi is built panic=abort and parses before it checks the CRC, so a corrupt RPU that
/// reaches an `unimplemented!()` / `unreachable!()` branch (libdovi 3.4 has no `todo!()` on these
/// paths) kills the process. Every RPU is CRC-checked here first; a
/// payload with a bad CRC never reaches the Rust parser. A crafted RPU with a valid CRC can still
/// reach a panic in the parser or, after `dovi_convert_rpu_with_mode`, in the writer;
/// `reachesUnimplementedPath` refuses the ones that are known (see there).
enum DoviRpuGuard {

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = c & 0x8000_0000 != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
        return c
    }

    /// `nal` starts at the 2-byte HEVC NAL header (type 62), emulation prevention still in place.
    /// Returns the unescaped RPU (header included) when its CRC32 is right, else nil.
    /// Layout after unescaping: header(2) 0x19 payload... crc32(4) 0x80.
    static func verifiedUnescaped(_ nal: UnsafePointer<UInt8>, _ len: Int) -> [UInt8]? {
        guard len >= 8 else { return nil }
        var u = [UInt8]()
        u.reserveCapacity(len)
        var zeros = 0
        for i in 0..<len {
            let b = nal[i]
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            u.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return verified(u)
    }

    /// `u` is an unescaped RPU, header(2) 0x19 payload... crc32(4) 0x80, possibly with trailing zeros.
    /// Returns it trimmed when its CRC32 is right, else nil.
    private static func verified(_ unescaped: [UInt8]) -> [UInt8]? {
        var u = unescaped
        while let last = u.last, last == 0 { u.removeLast() }   // cabac_zero_words / trailing zeros
        guard u.count >= 8, u[2] == 0x19, u[u.count - 1] == 0x80 else { return nil }
        let tailAt = u.count - 5
        var crc: UInt32 = 0xFFFF_FFFF
        for i in 3..<tailAt { crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(u[i]))] }
        let stored = (UInt32(u[tailAt]) << 24) | (UInt32(u[tailAt + 1]) << 16)
            | (UInt32(u[tailAt + 2]) << 8) | UInt32(u[tailAt + 3])
        return crc == stored ? u : nil
    }

    static func crcIsValid(_ nal: UnsafePointer<UInt8>, _ len: Int) -> Bool {
        verifiedUnescaped(nal, len) != nil
    }

    /// MSB-first bit reader. Every read returns nil past the end instead of trapping.
    private struct Bits {
        let bytes: [UInt8]
        let end: Int          // in bits
        var pos: Int

        mutating func bit() -> UInt64? {
            guard pos < end else { return nil }
            let v = (bytes[pos >> 3] >> UInt8(7 - (pos & 7))) & 1
            pos += 1
            return UInt64(v)
        }
        mutating func bits(_ n: Int) -> UInt64? {
            guard n >= 0, n <= 64, pos + n <= end else { return nil }
            var v: UInt64 = 0
            for _ in 0..<n { v = (v << 1) | bit()! }
            return v
        }
        /// Set when an Exp-Golomb code has `hostileLeadingZeros` or more leading zeros, i.e. a value of
        /// 2^32 - 1 or more. No RPU field comes near that (ids are 0...15, depths and counts are tiny,
        /// the widest is `el_bit_depth_minus8` with its 8 extension bits above 8 bits). libdovi decodes
        /// such a code without complaint but does not survive it: at exactly 64 zeros its release-mode
        /// shift wraps where a plain Swift shift does not, so the two readers disagree on the value, and
        /// `write_ue(u64::MAX)` unary-codes 2^32 - 1 zeros, an allocation of about 0.5 GB. The reader
        /// stops there and flags the RPU as hostile instead of guessing at the value.
        var hostile = false
        static let hostileLeadingZeros = 32

        mutating func ue() -> UInt64? {
            var zeros = 0
            while true {
                guard let b = bit() else { return nil }   // out of bits: libdovi errors on the same read
                if b == 1 { break }
                zeros += 1
                if zeros >= Self.hostileLeadingZeros { hostile = true; return nil }
            }
            guard let rest = bits(zeros) else { return nil }
            return ((UInt64(1) << UInt64(zeros)) - 1) + rest   // zeros < 32: no overflow
        }
        mutating func skipSE() -> Bool { ue() != nil }
    }

    /// True when the RPU steers libdovi 3.4 into a panic, which aborts the process because the library is
    /// built panic=abort. Mirrors `RpuDataHeader::parse`, `RpuDataMapping::parse` and the DM payload far
    /// enough to see these, each of which parses and survives to the writer or aborts in the parser:
    ///
    /// - a polynomial piece with `poly_order_minus1 == 0 && linear_interp_flag` (`unimplemented!()` in
    ///   both the parser and the writer);
    /// - a curve whose pieces do not all share one `mapping_idc`. The parser accepts the mix and keeps
    ///   one coefficient list per method, but the writer emits the curve's last `mapping_idc` for every
    ///   piece and indexes the polynomial list per piece, which is shorter than the piece count:
    ///   an out-of-bounds panic in `dovi_write_unspec62_nalu`. Mode 2 conversion drops the mapping only
    ///   for an FEL stream, so a MEL or residual-free RPU reaches the writer with the mix intact;
    /// - a pivot or block count the payload cannot hold (an allocation abort), and a level 8, 9 or 10
    ///   block of a length the spec does not define (`unreachable!()` in `required_bits`).
    ///
    /// An Exp-Golomb code with 32 or more leading zeros anywhere the scan reads one is hostile (see
    /// `Bits.hostile`) and answers true.
    ///
    /// Otherwise conservative, and every `false` is on a path where libdovi itself returns an error
    /// before reaching any panic: running out of bits (libdovi's reads fail on the same field, the
    /// scan mirrors its read order), a value libdovi's header or mapping parser rejects with `ensure!`
    /// or `bail!` (`rpu_type`, `coefficient_data_type`, the bit depths and denominator checked by
    /// `RpuDataHeader::validate`, `mapping_idc` other than 0 or 1, `poly_order_minus1` above 1,
    /// `mmr_order_minus1` above 2, a non-zero `nlq_method_idc`), or a DM block level the CM version
    /// does not allow.
    static func reachesUnimplementedPath(_ u: [UInt8]) -> Bool {
        // libdovi's reader runs to the end of the trimmed data, CRC and final byte included, so a mutated
        // piece count can make it read the linear flag out of the CRC bytes. Mirror that bound.
        var r = Bits(bytes: u, end: u.count * 8, pos: 3 * 8)   // after NAL header + 0x19
        return scan(&r) || r.hostile
    }

    private static func scan(_ r: inout Bits, dmStart: ((Int, Bool) -> Void)? = nil) -> Bool {
        guard r.bits(6) == 2, let format = r.bits(11) else { return false }
        guard r.bits(4) != nil, r.bits(4) != nil, let seqInfo = r.bit() else { return false }
        guard seqInfo == 1 else { return false }
        guard r.bit() != nil, let dataType = r.bits(2) else { return false }
        var denom: UInt64 = 0
        if dataType == 0 { guard let d = r.ue() else { return false }; denom = d }
        guard r.bits(2) != nil, r.bit() != nil else { return false }
        var blDepth: UInt64 = 0, elDepth: UInt64 = 0, reserved3: UInt64 = 0
        var disableResidual = false
        if format & 0x700 == 0 {
            guard let bl = r.ue(), let el = r.ue(), r.ue() != nil, r.bit() != nil, let res = r.bits(3),
                  r.bit() != nil, let dr = r.bit() else { return false }
            blDepth = bl
            elDepth = el & 0xFF
            reserved3 = res
            disableResidual = dr == 1
        }
        let coefLen: Int
        if dataType == 0 { guard denom <= 32 else { return false }; coefLen = Int(denom) }
        else if dataType == 1 { coefLen = 32 } else { return false }
        // libdovi rejects anything but 10-bit base layers and denom > 23 before reading the mapping.
        guard blDepth == 2, denom <= 23 else { return false }
        guard let dmPresent = r.bit(), let usePrev = r.bit() else { return false }
        if usePrev == 1 {
            // libdovi reads prev_vdr_rpu_id and skips only the mapping (curves and NLQ); the DM payload
            // is still parsed when vdr_dm_metadata_present_flag is set, so an invalid block must be
            // caught here too.
            guard r.ue() != nil, dmPresent == 1 else { return false }
            dmStart?(r.pos, reserved3 == 1)
            return reachesInvalidDmBlock(&r, compressed: reserved3 == 1)
        }
        guard r.ue() != nil, r.ue() != nil, r.ue() != nil else { return false }
        let depth = Int(blDepth) + 8
        var pieces = [Int](repeating: 0, count: 3)
        for c in 0..<3 {
            guard let n = r.ue() else { return false }
            // libdovi sizes its pivot and piece vectors from this count before reading them, so a count the
            // payload cannot hold aborts on allocation instead of failing: reject it here.
            if n > UInt64(r.end - r.pos) / UInt64(depth) { return true }
            pieces[c] = Int(n) + 1
            for _ in 0..<(Int(n) + 2) { guard r.bits(depth) != nil else { return false } }
        }
        if format & 0x700 == 0 && !disableResidual {
            guard r.bits(3) == 0 else { return false }
            for _ in 0..<2 { guard r.bits(depth) != nil else { return false } }   // NLQ_NUM_PIVOTS == 2 (guarded by the bounds above)
        }
        guard r.ue() != nil, r.ue() != nil else { return false }
        for c in 0..<3 {
            var curveIdc: UInt64?
            for _ in 0..<pieces[c] {
                guard let idc = r.ue() else { return false }
                // The writer cannot represent a curve that mixes methods (see above).
                if let curveIdc, idc <= 1, idc != curveIdc { return true }
                curveIdc = idc
                if idc == 0 {
                    guard let order = r.ue(), order <= 1 else { return false }
                    if order == 0 {
                        guard let linear = r.bit() else { return false }
                        if linear == 1 { return true }
                    }
                    for _ in 0..<(Int(order) + 2) {
                        if dataType == 0 { guard r.skipSE() else { return false } }
                        guard r.bits(coefLen) != nil else { return false }
                    }
                } else if idc == 1 {
                    guard let order = r.bits(2), order <= 2 else { return false }
                    if dataType == 0 { guard r.skipSE() else { return false } }
                    guard r.bits(coefLen) != nil else { return false }
                    for _ in 0...Int(order) {
                        for _ in 0..<7 {   // MMR_MAX_COEFFS
                            if dataType == 0 { guard r.skipSE() else { return false } }
                            guard r.bits(coefLen) != nil else { return false }
                        }
                    }
                } else { return false }
            }
        }
        // NLQ parameters (profile 7 with a residual).
        if format & 0x700 == 0 && !disableResidual {
            guard elDepth == 2 else { return false }
            for _ in 0..<3 {
                guard r.bits(Int(elDepth) + 8) != nil else { return false }
                if dataType == 0 { guard r.skipSE() else { return false } }
                guard r.bits(coefLen) != nil else { return false }
                for _ in 0..<2 {   // deadzone slope, threshold
                    if dataType == 0 { guard r.skipSE() else { return false } }
                    guard r.bits(coefLen) != nil else { return false }
                }
            }
        }
        guard dmPresent == 1 else { return false }
        dmStart?(r.pos, reserved3 == 1)
        return reachesInvalidDmBlock(&r, compressed: reserved3 == 1)
    }

    /// Only used after libdovi has successfully parsed and serialized the RPU.
    static func displayMetadataStart(_ bytes: [UInt8]) -> (offset: Int, compressed: Bool)? {
        var reader = Bits(bytes: bytes, end: bytes.count * 8, pos: 24)
        var result: (Int, Bool)?
        let unsafe = scan(&reader) { result = ($0, $1) }
        return unsafe || reader.hostile ? nil : result
    }

    /// libdovi's `required_bits()` for level 8, 9 and 10 blocks is `unreachable!()` for any length the
    /// spec does not define, and the parser only checks the length against itself, so a CRC-valid RPU
    /// with such a block aborts the process. Walks the DM payload (CM v2.9 list, then CM v4.0 list)
    /// far enough to see every block's level and length.
    private static func reachesInvalidDmBlock(_ r: inout Bits, compressed: Bool) -> Bool {
        guard r.ue() != nil, r.ue() != nil, r.ue() != nil else { return false }
        if !compressed {   // fixed fields of VdrDmData::parse
            guard r.pos + 509 <= r.end else { return false }
            r.pos += 509
        }
        for section in 0..<2 {
            if section == 1 && r.end - r.pos < 56 { return false }   // DM_DATA_PAYLOAD2_MIN_BITS
            guard let count = r.ue() else { return false }
            if count > UInt64(r.end - r.pos) / 9 { return true }   // allocated up front by libdovi, like the pivot count
            while r.pos & 7 != 0 { guard r.bit() != nil else { return false } }
            for _ in 0..<count {
                guard let length = r.ue(), let level = r.bits(8) else { return false }
                if section == 1 {
                    switch level {
                    case 8: if ![10, 12, 13, 19, 25].contains(length) { return true }
                    case 9: if ![1, 17].contains(length) { return true }
                    case 10: if ![5, 21].contains(length) { return true }
                    case 3, 11, 254: break
                    default: return false   // libdovi errors on the rest
                    }
                } else if ![1, 2, 4, 5, 6, 255].contains(level) { return false }
                guard length < 1 << 20, r.pos + Int(length) * 8 <= r.end else { return false }
                r.pos += Int(length) * 8
            }
        }
        return false
    }

    /// `dovi_parse_unspec62_nalu` behind the CRC check and the panic-path check; nil when the
    /// RPU is corrupt or would abort the library.
    static func parse(_ nal: UnsafePointer<UInt8>, _ len: Int) -> OpaquePointer? {
        guard let u = verifiedUnescaped(nal, len), !reachesUnimplementedPath(u) else { return nil }
        return dovi_parse_unspec62_nalu(nal, len)
    }

    /// The AV1 (Profile 10) form: `t35` runs from `itu_t_t35_country_code` (or the provider code) on.
    /// `dovi_parse_itu_t35_dovi_metadata_obu` behind the same two checks as `parse`: the RPU is taken
    /// out of its EMDF container the way libdovi's `convert_av1_rpu_payload_to_regular` does, then
    /// checked as the unspec62 RPU it is. nil when it is not a Dolby Vision RPU, is corrupt, or would
    /// abort the library.
    static func parseAV1(_ t35: UnsafePointer<UInt8>, _ len: Int) -> OpaquePointer? {
        guard let rpu = av1RPU(t35, len), let u = verified([0x7C, 0x01] + rpu),
              !reachesUnimplementedPath(u) else { return nil }
        return dovi_parse_itu_t35_dovi_metadata_obu(t35, len)
    }

    /// libdovi's fixed T.35 header: provider code 0x003B, provider-oriented code 0x800, and the first
    /// EMDF bits (`emdf_version` 0, `key_id` 6, `emdf_payload_id` 31 extended to 225, the four flags 0,
    /// `discard_unknown_payload` 1), which end three bits into the last byte.
    private static let av1Header: [UInt8] = [0x00, 0x3B, 0x00, 0x00, 0x08, 0x00, 0x37, 0xCD, 0x08]

    /// The RPU (0x19 payload..., no NAL header, no emulation prevention) inside an AV1 T.35 payload.
    static func av1RPU(_ t35: UnsafePointer<UInt8>, _ len: Int) -> [UInt8]? {
        // libdovi's own minimum, and the optional country code it skips.
        guard len >= 34 else { return nil }
        var bytes = Array(UnsafeBufferPointer(start: t35, count: len))
        if bytes[0] == 0xB5 { bytes.removeFirst() }
        guard bytes.count >= av1Header.count, Array(bytes[..<av1Header.count]) == av1Header else { return nil }
        var r = Bits(bytes: bytes, end: bytes.count * 8, pos: 48)
        // Mirrors `parse_emdf_container`, `emdf_payload_size` included.
        guard r.bits(2) == 0, r.bits(3) == 6, r.bits(5) == 31, variableBits(&r, 5) == 225,
              r.bits(4) == 0, r.bit() == 1,
              let size = variableBits(&r, 8), r.pos + Int(size) * 8 <= r.end else { return nil }
        var rpu = [UInt8](repeating: 0, count: Int(size) + 1)
        rpu[0] = 0x19
        for i in 0..<Int(size) { rpu[i + 1] = UInt8(r.bits(8)!) }
        return rpu
    }

    /// EMDF `variable_bits`. Capped at four groups: a payload size that needs more is larger than
    /// any T.35 payload can carry, and libdovi's u32 would overflow on it.
    private static func variableBits(_ r: inout Bits, _ n: Int) -> UInt64? {
        var value: UInt64 = 0
        for _ in 0..<4 {
            guard let group = r.bits(n), let more = r.bit() else { return nil }
            value += group
            if more == 0 { return value }
            value = (value << UInt64(n)) + (1 << UInt64(n))
        }
        return nil
    }
}
