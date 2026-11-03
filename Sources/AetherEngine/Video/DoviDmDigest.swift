// Only with the DualLayerDolbyVision trait (off by default): the digest reads RPUs with libdovi, which the dual-layer route links.
#if DualLayerDolbyVision
import Foundation
import CoreVideo
import Dovi

/// A flat, ordered reading of one Dolby Vision RPU: the header, the mapping summary and every display
/// management field (all levels), as `name -> value` strings, so two RPUs can be compared field by field.
///
/// This is a measuring tool for the question "does the converted RPU the engine attaches to a composed
/// frame still carry all the display-management metadata of the source RPU". It reads with libdovi's own
/// parser (`DoviRpuGuard.parse` first, so a corrupt RPU never reaches it) and changes nothing.
struct DoviDmReading: Sendable, Equatable {
    /// Insertion-ordered fields; names are unique.
    private(set) var fields: [(name: String, value: String)] = []
    private var index: [String: Int] = [:]

    static func == (lhs: DoviDmReading, rhs: DoviDmReading) -> Bool {
        lhs.fields.count == rhs.fields.count && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    mutating func set(_ name: String, _ value: CustomStringConvertible) {
        let v = String(describing: value)
        if let i = index[name] { fields[i].value = v } else { index[name] = fields.count; fields.append((name, v)) }
    }

    subscript(name: String) -> String? { index[name].map { fields[$0].value } }

    /// The levels carried, as numbers ("1", "2", "3", ...), ascending.
    var levels: [Int] {
        var out = Set<Int>()
        for (name, _) in fields where name.hasPrefix("L") {
            let digits = name.dropFirst().prefix(while: \.isNumber)
            if let n = Int(digits) { out.insert(n) }
        }
        return out.sorted()
    }
}

/// One field that differs between the source reading and the attached reading.
struct DoviDmDifference: Sendable, Equatable {
    let name: String
    let source: String?
    let output: String?
}

enum DoviDmDigest {

    // MARK: Reading

    /// Reads a Dolby Vision RPU given as an unspec62 NAL (`7C 01` header, emulation bytes in place) or as the
    /// header-less payload that rides on a pixel buffer (starts with `0x19`). nil when the RPU is corrupt.
    static func read(rpu bytes: [UInt8]) -> DoviDmReading? {
        var nal = bytes
        if nal.first == 0x19 { nal.insert(contentsOf: [0x7C, 0x01], at: 0) }
        return nal.withUnsafeBufferPointer { buf -> DoviDmReading? in
            guard let base = buf.baseAddress, buf.count > 2, let rpu = DoviRpuGuard.parse(base, buf.count) else { return nil }
            defer { dovi_rpu_free(rpu) }
            return read(parsed: rpu)
        }
    }

    static func read(parsed rpu: OpaquePointer) -> DoviDmReading {
        var r = DoviDmReading()

        if let h = dovi_rpu_get_header(rpu) {
            defer { dovi_rpu_free_header(h) }
            let hp = h.pointee
            r.set("hdr.guessed_profile", hp.guessed_profile)
            r.set("hdr.el_type", hp.el_type.map { String(cString: $0) } ?? "none")
            r.set("hdr.rpu_type", hp.rpu_type)
            r.set("hdr.rpu_format", hp.rpu_format)
            r.set("hdr.vdr_rpu_profile", hp.vdr_rpu_profile)
            r.set("hdr.vdr_rpu_level", hp.vdr_rpu_level)
            r.set("hdr.vdr_seq_info_present", hp.vdr_seq_info_present_flag)
            r.set("hdr.coefficient_data_type", hp.coefficient_data_type)
            r.set("hdr.coefficient_log2_denom", hp.coefficient_log2_denom)
            r.set("hdr.vdr_rpu_normalized_idc", hp.vdr_rpu_normalized_idc)
            r.set("hdr.bl_full_range", hp.bl_video_full_range_flag)
            r.set("hdr.bl_bit_depth", hp.bl_bit_depth_minus8 + 8)
            r.set("hdr.el_bit_depth", hp.el_bit_depth_minus8 + 8)
            r.set("hdr.vdr_bit_depth", hp.vdr_bit_depth_minus8 + 8)
            r.set("hdr.spatial_resampling", hp.spatial_resampling_filter_flag)
            r.set("hdr.el_spatial_resampling", hp.el_spatial_resampling_filter_flag)
            r.set("hdr.disable_residual", hp.disable_residual_flag)
            r.set("hdr.vdr_dm_metadata_present", hp.vdr_dm_metadata_present_flag)
            r.set("hdr.use_prev_vdr_rpu", hp.use_prev_vdr_rpu_flag)
        }

        if let m = dovi_rpu_get_data_mapping(rpu) {
            defer { dovi_rpu_free_data_mapping(m) }
            let mp = m.pointee
            r.set("map.present", true)
            r.set("map.nlq", mp.nlq != nil)
            r.set("map.nlq_method_idc", mp.nlq_method_idc)
            r.set("map.mapping_color_space", mp.mapping_color_space)
            r.set("map.chroma_format_idc", mp.mapping_chroma_format_idc)
            withUnsafePointer(to: mp.curves) { curvesPtr in
                curvesPtr.withMemoryRebound(to: DoviReshapingCurve.self, capacity: 3) { curves in
                    for c in 0..<3 {
                        let cv = curves[c]
                        r.set("map.c\(c).idc", cv.mapping_idc)
                        r.set("map.c\(c).pivots", pivots(cv.pivots))
                        var h = FNV()
                        if let poly = cv.polynomial {
                            r.set("map.c\(c).poly_order_minus1", ints(poly.pointee.poly_order_minus1))
                            h.mix(ints2D: poly.pointee.poly_coef_int)
                            h.mix(u64s2D: poly.pointee.poly_coef)
                        }
                        if let mmr = cv.mmr {
                            r.set("map.c\(c).mmr_order_minus1", bytes(mmr.pointee.mmr_order_minus1))
                            h.mix(i64: mmr.pointee.mmr_constant_int)
                            h.mix(u64: mmr.pointee.mmr_constant)
                        }
                        r.set("map.c\(c).coef_hash", String(h.value, radix: 16))
                    }
                }
            }
        } else {
            r.set("map.present", false)
        }

        guard let dmPtr = dovi_rpu_get_vdr_dm_data(rpu) else {
            r.set("dm.present", false)
            return r
        }
        defer { dovi_rpu_free_vdr_dm_data(dmPtr) }
        let d = dmPtr.pointee
        r.set("dm.present", true)
        r.set("dm.compressed", d.compressed)
        r.set("dm.affected_dm_metadata_id", d.affected_dm_metadata_id)
        r.set("dm.current_dm_metadata_id", d.current_dm_metadata_id)
        r.set("dm.scene_refresh_flag", d.scene_refresh_flag)
        r.set("dm.ycc_to_rgb_coef", [d.ycc_to_rgb_coef0, d.ycc_to_rgb_coef1, d.ycc_to_rgb_coef2, d.ycc_to_rgb_coef3, d.ycc_to_rgb_coef4,
                                     d.ycc_to_rgb_coef5, d.ycc_to_rgb_coef6, d.ycc_to_rgb_coef7, d.ycc_to_rgb_coef8].map(String.init).joined(separator: ","))
        r.set("dm.ycc_to_rgb_offset", "\(d.ycc_to_rgb_offset0),\(d.ycc_to_rgb_offset1),\(d.ycc_to_rgb_offset2)")
        r.set("dm.rgb_to_lms_coef", [d.rgb_to_lms_coef0, d.rgb_to_lms_coef1, d.rgb_to_lms_coef2, d.rgb_to_lms_coef3, d.rgb_to_lms_coef4,
                                     d.rgb_to_lms_coef5, d.rgb_to_lms_coef6, d.rgb_to_lms_coef7, d.rgb_to_lms_coef8].map(String.init).joined(separator: ","))
        r.set("dm.signal_eotf", "\(d.signal_eotf),\(d.signal_eotf_param0),\(d.signal_eotf_param1),\(d.signal_eotf_param2)")
        r.set("dm.signal_bit_depth", d.signal_bit_depth)
        r.set("dm.signal_color_space", d.signal_color_space)
        r.set("dm.signal_chroma_format", d.signal_chroma_format)
        r.set("dm.signal_full_range", d.signal_full_range_flag)
        r.set("dm.source_min_pq", d.source_min_pq)
        r.set("dm.source_max_pq", d.source_max_pq)
        r.set("dm.source_diagonal", d.source_diagonal)
        let e = d.dm_data
        r.set("dm.num_ext_blocks", e.num_ext_blocks)

        if let b = e.level1?.pointee { r.set("L1", "\(b.min_pq)/\(b.max_pq)/\(b.avg_pq)") }
        if let list = e.level2.list {
            for i in 0..<Int(e.level2.len) {
                guard let b = list[i]?.pointee else { continue }
                r.set("L2[\(i)]", "target_max_pq=\(b.target_max_pq) slope=\(b.trim_slope) offset=\(b.trim_offset) power=\(b.trim_power) chroma_weight=\(b.trim_chroma_weight) sat_gain=\(b.trim_saturation_gain) ms_weight=\(b.ms_weight)")
            }
        }
        if let b = e.level3?.pointee { r.set("L3", "min_pq_offset=\(b.min_pq_offset) max_pq_offset=\(b.max_pq_offset) avg_pq_offset=\(b.avg_pq_offset)") }
        if let b = e.level4?.pointee { r.set("L4", "anchor_pq=\(b.anchor_pq) anchor_power=\(b.anchor_power)") }
        if let b = e.level5?.pointee { r.set("L5", "left=\(b.active_area_left_offset) right=\(b.active_area_right_offset) top=\(b.active_area_top_offset) bottom=\(b.active_area_bottom_offset)") }
        if let b = e.level6?.pointee { r.set("L6", "max_mdl=\(b.max_display_mastering_luminance) min_mdl=\(b.min_display_mastering_luminance) maxcll=\(b.max_content_light_level) maxfall=\(b.max_frame_average_light_level)") }
        if let list = e.level8.list {
            for i in 0..<Int(e.level8.len) {
                guard let b = list[i]?.pointee else { continue }
                r.set("L8[\(i)]", "len=\(b.length) target=\(b.target_display_index) slope=\(b.trim_slope) offset=\(b.trim_offset) power=\(b.trim_power) chroma_weight=\(b.trim_chroma_weight) sat_gain=\(b.trim_saturation_gain) ms_weight=\(b.ms_weight) mid_contrast=\(b.target_mid_contrast) clip_trim=\(b.clip_trim) sat_vec=\(b.saturation_vector_field0),\(b.saturation_vector_field1),\(b.saturation_vector_field2),\(b.saturation_vector_field3),\(b.saturation_vector_field4),\(b.saturation_vector_field5) hue_vec=\(b.hue_vector_field0),\(b.hue_vector_field1),\(b.hue_vector_field2),\(b.hue_vector_field3),\(b.hue_vector_field4),\(b.hue_vector_field5)")
            }
        }
        if let b = e.level9?.pointee {
            r.set("L9", "len=\(b.length) index=\(b.source_primary_index) r=\(b.source_primary_red_x),\(b.source_primary_red_y) g=\(b.source_primary_green_x),\(b.source_primary_green_y) b=\(b.source_primary_blue_x),\(b.source_primary_blue_y) w=\(b.source_primary_white_x),\(b.source_primary_white_y)")
        }
        if let list = e.level10.list {
            for i in 0..<Int(e.level10.len) {
                guard let b = list[i]?.pointee else { continue }
                r.set("L10[\(i)]", "len=\(b.length) target=\(b.target_display_index) max_pq=\(b.target_max_pq) min_pq=\(b.target_min_pq) primary=\(b.target_primary_index) r=\(b.target_primary_red_x),\(b.target_primary_red_y) g=\(b.target_primary_green_x),\(b.target_primary_green_y) b=\(b.target_primary_blue_x),\(b.target_primary_blue_y) w=\(b.target_primary_white_x),\(b.target_primary_white_y)")
            }
        }
        if let b = e.level11?.pointee { r.set("L11", "content_type=\(b.content_type) whitepoint=\(b.whitepoint) reference_mode=\(b.reference_mode_flag) reserved=\(b.reserved_byte2),\(b.reserved_byte3)") }
        if let b = e.level254?.pointee { r.set("L254", "dm_mode=\(b.dm_mode) dm_version_index=\(b.dm_version_index)") }
        if let b = e.level255?.pointee { r.set("L255", "run_mode=\(b.dm_run_mode) run_version=\(b.dm_run_version) debug=\(b.dm_debug0),\(b.dm_debug1),\(b.dm_debug2),\(b.dm_debug3)") }
        return r
    }

    // MARK: Comparison

    /// Fields a conversion to Profile 8.1 with the mapping removed is DEFINED to change because the RPU describes a
    /// picture the composer has already reshaped and added the residual to: the profile and enhancement-layer
    /// labels the header derives (`guessed_profile`, `el_type`), the two flags mode 2 writes (`el_spatial_resampling`,
    /// `disable_residual`), and everything about the mapping (`map.` prefix). Nothing else in the header is touched
    /// by mode 2, so any other header difference is a regression and fails.
    ///
    /// The set is exact names or the `map.` prefix; measured on real dual-layer and single-layer clips.
    static let expectedModeTwoChanges: Set<String> = [
        "hdr.guessed_profile", "hdr.el_type", "hdr.el_spatial_resampling", "hdr.disable_residual",
    ]

    static func isExpectedChange(_ name: String) -> Bool {
        name.hasPrefix("map.") || expectedModeTwoChanges.contains(name)
    }

    /// Display-management fields that libdovi's mode 2 (`convert_to_p81`) OVERWRITES with the Profile 8.1 constants
    /// on every RPU: the YCC to RGB matrix and offsets, the RGB to LMS matrix and the signal colour space. They
    /// describe the composed BT.2020 signal the output carries, so rewriting them is correct, but it is a change of
    /// display metadata, so it is reported as its own "normalised" category: neither hidden nor a bare failure.
    /// A source that already carries these values (every clip in the corpus) shows no change here.
    static let normalisedByModeTwo: [String: String] = [
        "dm.ycc_to_rgb_coef": "9574,0,13802,9574,-1540,-5348,9574,17610,0",
        "dm.ycc_to_rgb_offset": "16777216,134217728,134217728",
        "dm.rgb_to_lms_coef": "7222,8771,390,2654,12430,1300,0,422,15962",
        "dm.signal_color_space": "0",
    ]

    /// True when `difference` is a mode 2 normalisation: the field is one of the reset ones AND the output holds
    /// exactly the Profile 8.1 constant. A reset field with any other output value is still unexpected.
    static func isNormalisedChange(_ difference: DoviDmDifference) -> Bool {
        guard let constant = normalisedByModeTwo[difference.name] else { return false }
        return difference.output == constant
    }

    /// Field-by-field differences, source order first, then fields only the output has.
    static func differences(source: DoviDmReading, output: DoviDmReading) -> [DoviDmDifference] {
        var out: [DoviDmDifference] = []
        for (name, value) in source.fields where output[name] != value {
            out.append(.init(name: name, source: value, output: output[name]))
        }
        for (name, value) in output.fields where source[name] == nil {
            out.append(.init(name: name, source: nil, output: value))
        }
        return out
    }

    // MARK: Compact line

    /// The per-frame digest of an attached RPU: the levels and the values worth eyeballing.
    static func compact(_ r: DoviDmReading) -> String {
        var parts: [String] = []
        parts.append("prof=\(r["hdr.guessed_profile"] ?? "?")")
        parts.append("cm=\(cmVersion(r))")
        parts.append("lv=" + r.levels.map(String.init).joined(separator: ","))
        for key in ["L1", "L3", "L5", "L6", "L9", "L11", "L254", "L255"] { if let v = r[key] { parts.append("\(key){\(v)}") } }
        for (name, value) in r.fields where name.hasPrefix("L2[") || name.hasPrefix("L8[") || name.hasPrefix("L10[") {
            parts.append("\(name){\(value)}")
        }
        return parts.joined(separator: " ")
    }

    /// "v4.0" when the RPU carries the CM v4.0 marker (Level 254) and "v2.9" when it carries display management
    /// without it; "none" without display management. The C API hands over one block list, so this is read from
    /// the blocks present, and cross-checked against `dovi_tool export` (which splits `cmv29_metadata` and
    /// `cmv40_metadata`) in offline testing.
    static func cmVersion(_ r: DoviDmReading) -> String {
        guard r["dm.present"] == "true" else { return "none" }
        return r["L254"] != nil ? "v4.0" : "v2.9"
    }

    // MARK: Small helpers

    private struct FNV {
        var value: UInt64 = 0xcbf29ce484222325
        mutating func mix(_ x: UInt64) { value = (value ^ x) &* 0x100000001b3 }
        mutating func mix(i64 d: DoviI64Data) { if let p = d.data { for i in 0..<d.len { mix(UInt64(bitPattern: p[i])) } }; mix(UInt64(d.len)) }
        mutating func mix(u64 d: DoviU64Data) { if let p = d.data { for i in 0..<d.len { mix(p[i]) } }; mix(UInt64(d.len)) }
        mutating func mix(ints2D d: DoviI64Data2D) {
            if let l = d.list { for i in 0..<d.len { if let row = l[i]?.pointee { mix(i64: row) } } }
            mix(UInt64(d.len))
        }
        mutating func mix(u64s2D d: DoviU64Data2D) {
            if let l = d.list { for i in 0..<d.len { if let row = l[i]?.pointee { mix(u64: row) } } }
            mix(UInt64(d.len))
        }
    }

    private static func pivots(_ d: DoviU16Data) -> String {
        guard let p = d.data else { return "" }
        return (0..<d.len).map { String(p[$0]) }.joined(separator: ",")
    }
    private static func ints(_ d: DoviU64Data) -> String {
        guard let p = d.data else { return "" }
        return (0..<d.len).map { String(p[$0]) }.joined(separator: ",")
    }
    private static func bytes(_ d: DoviData) -> String {
        guard let p = d.data else { return "" }
        return (0..<d.len).map { String(p[$0]) }.joined(separator: ",")
    }

    // MARK: CRC for a payload fingerprint

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }
}
#endif
