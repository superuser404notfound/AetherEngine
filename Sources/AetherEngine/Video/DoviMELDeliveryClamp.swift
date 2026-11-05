import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi

/// A title-level hypothesis for MEL deliveries whose base layer has a lower mastering peak.
/// Kept on StreamConfig so a seek cannot choose a new policy from a different scene's RPU.
struct DoviMELDeliveryClamp: Sendable, Equatable {
    let targetNits: UInt16
    let targetPQ: UInt16

    /// The environment switch can disable an explicit request, never enable a default load.
    static func shouldProbe(requested: Bool, override: String?) -> Bool {
        requested && override != "0"
    }

    static func pqCode(nits: Double) -> UInt16 {
        let p = pow(min(10000, max(0, nits)) / 10000, 2610.0 / 16384)
        return UInt16((4095 * pow((3424.0 / 4096 + 2413.0 / 128 * p)
            / (1 + 2392.0 / 128 * p), 2523.0 / 32)).rounded())
    }

    static func select(profile: Int, elType: String?, masteringNits: Double?, sourceMaxPQ: UInt16,
                       enabled: Bool) -> Self? {
        guard enabled, profile == 7, elType == "MEL", let peak = masteringNits,
              peak.isFinite, peak >= 1, peak <= 1000,
              sourceMaxPQ >= pqCode(nits: 4000) else { return nil }
        return Self(targetNits: UInt16(peak.rounded(.down)), targetPQ: pqCode(nits: peak))
    }

    static func profile(_ par: UnsafePointer<AVCodecParameters>) -> Int? {
        guard let side = par.pointee.coded_side_data else { return nil }
        for i in 0..<Int(par.pointee.nb_coded_side_data) {
            let item = side[i]
            guard item.type == AV_PKT_DATA_DOVI_CONF, item.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size,
                  let data = item.data else { continue }
            return Int(UnsafeRawPointer(data).assumingMemoryBound(to: AVDOVIDecoderConfigurationRecord.self).pointee.dv_profile)
        }
        return nil
    }

    static func firstRPU(_ data: UnsafePointer<UInt8>, _ size: Int,
                         framing: VideoNALFraming) -> (found: Bool, elType: String?, sourceMaxPQ: UInt16) {
        var found = false
        var elType: String?
        var sourceMaxPQ: UInt16 = 0
        A53SEIParser.forEachNAL(data, size, framing) { nal, count in
            guard !found, (nal[0] >> 1) & 63 == 62 else { return }
            found = true
            guard let rpu = DoviRpuGuard.parse(nal, count) else { return }
            defer { dovi_rpu_free(rpu) }
            if let header = dovi_rpu_get_header(rpu) {
                defer { dovi_rpu_free_header(header) }
                if let type = header.pointee.el_type { elType = String(cString: type) }
            }
            if let dm = dovi_rpu_get_vdr_dm_data(rpu) {
                defer { dovi_rpu_free_vdr_dm_data(dm) }
                sourceMaxPQ = dm.pointee.source_max_pq
            }
        }
        return (found, elType, sourceMaxPQ)
    }

    static func containerPeak(_ par: UnsafePointer<AVCodecParameters>) -> Double? {
        guard let side = par.pointee.coded_side_data else { return nil }
        for i in 0..<Int(par.pointee.nb_coded_side_data) {
            let item = side[i]
            guard item.type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA,
                  item.size >= MemoryLayout<AVMasteringDisplayMetadata>.size, let data = item.data else { continue }
            let meta = UnsafeRawPointer(data).assumingMemoryBound(to: AVMasteringDisplayMetadata.self).pointee
            guard meta.has_luminance != 0, meta.max_luminance.den > 0 else { return nil }
            return Double(meta.max_luminance.num) / Double(meta.max_luminance.den)
        }
        return nil
    }

    static func masteringPeak(_ data: UnsafePointer<UInt8>, _ size: Int, framing: VideoNALFraming) -> Double? {
        var peak: Double?
        A53SEIParser.forEachSEIRBSP(data, size, codec: .hevc, framing: framing) { rbsp in
            A53SEIParser.forEachSEIPayload(rbsp) { type, offset, count in
                guard type == 137, count == 24 else { return false }
                let i = offset + 16
                let value = (UInt32(rbsp[i]) << 24) | (UInt32(rbsp[i + 1]) << 16)
                    | (UInt32(rbsp[i + 2]) << 8) | UInt32(rbsp[i + 3])
                peak = Double(value) / 10000
                return true
            }
            return peak != nil
        }
        return peak
    }

    /// The pinned libdovi C API exposes DM snapshots, not setters. Edit only fixed-width fields in
    /// its serialized P8.1 output, then restore the checksum and HEVC emulation prevention.
    func rewrite(_ nal: UnsafePointer<UInt8>, count: Int) -> [UInt8]? {
        guard var bytes = DoviRpuGuard.verifiedUnescaped(nal, count),
              let start = DoviRpuGuard.displayMetadataStart(bytes) else { return nil }
        let end = (bytes.count - 5) * 8
        var position = start.offset
        func read(_ offset: Int, _ width: Int) -> UInt64? {
            guard offset >= 0, width >= 0, width <= 64, offset + width <= end else { return nil }
            var value: UInt64 = 0
            for bit in offset..<(offset + width) {
                value = value << 1 | UInt64((bytes[bit / 8] >> (7 - bit % 8)) & 1)
            }
            return value
        }
        func ue() -> UInt64? {
            var zeros = 0
            while read(position, 1) == 0 {
                position += 1; zeros += 1
                if zeros >= 32 { return nil }
            }
            guard read(position, 1) == 1 else { return nil }
            position += 1
            guard let suffix = read(position, zeros) else { return nil }
            position += zeros
            return (UInt64(1) << zeros) - 1 + suffix
        }
        func write(_ offset: Int, _ width: Int, _ value: UInt64) {
            for i in 0..<width {
                let bit = offset + i, mask = UInt8(1 << (7 - bit % 8))
                bytes[bit / 8] = (bytes[bit / 8] & ~mask)
                    | (((value >> (width - i - 1)) & 1) == 1 ? mask : 0)
            }
        }
        func clamp(_ offset: Int, _ width: Int, _ limit: UInt16) -> Bool {
            guard let old = read(offset, width) else { return false }
            write(offset, width, min(old, UInt64(limit)))
            return true
        }
        guard ue() != nil, ue() != nil, ue() != nil else { return nil }
        if !start.compressed {
            guard position + 509 <= end,
                  clamp(position + 487, 12, targetPQ) else { return nil }
            position += 509
        }
        // L1 and L6 live in CM v2.9. The following CM v4.0 section, including L8 trims, stays intact.
        guard let blocks = ue(), blocks <= UInt64(max(0, end - position) / 9) else { return nil }
        position = (position + 7) & ~7
        for _ in 0..<blocks {
            guard let length = ue(), let level = read(position, 8), length <= UInt64(max(0, end - position - 8) / 8) else { return nil }
            position += 8
            if level == 1 {
                guard length == 5, clamp(position + 12, 12, targetPQ) else { return nil }
            } else if level == 6 {
                guard length == 8, read(position, 64) != nil else { return nil }
                write(position, 16, UInt64(targetNits))
                guard clamp(position + 32, 16, targetNits), clamp(position + 48, 16, targetNits) else { return nil }
            }
            position += Int(length) * 8
        }
        var crc: UInt32 = 0xFFFF_FFFF
        let crcAt = bytes.count - 5
        for byte in bytes[3..<crcAt] {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 == 0 ? crc << 1 : (crc << 1) ^ 0x04C1_1DB7 }
        }
        for i in 0..<4 { bytes[crcAt + i] = UInt8(truncatingIfNeeded: crc >> (24 - 8 * i)) }
        var escaped: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros == 2, byte <= 3 { escaped.append(3); zeros = 0 }
            escaped.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return escaped
    }
}
