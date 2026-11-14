import Foundation

/// HDR10 static metadata as CoreVideo carries it: the mastering display colour volume and the content
/// light level, in the byte layout of the HEVC SEI messages (big endian). Builds and describes the two
/// attachments; `HDR10StaticMetadataSEI` finds a stream's own values.
struct HDR10StaticMetadata: Equatable, Sendable {
    var maxCLL: Int
    var maxFALL: Int
    var masteringPeakNits: Double
    var masteringMinNits: Double

    /// BT.2020 primaries in the SEI's order (green, blue, red), then the D65 white point, in 0.00002 units.
    static let bt2020Chromaticities: [UInt16] = [8500, 39850, 6550, 2300, 35400, 14600, 15635, 16450]

    /// `kCVImageBufferMasteringDisplayColorVolumeKey`: 24 bytes, BT.2020 primaries, luminance in 0.0001 nit.
    var masteringDisplayColorVolume: Data {
        var bytes: [UInt8] = []
        for value in Self.bt2020Chromaticities { bytes += [UInt8(value >> 8), UInt8(value & 0xFF)] }
        for nits in [masteringPeakNits, masteringMinNits] {
            let units = UInt32((nits * 10_000).rounded())
            bytes += [UInt8(units >> 24), UInt8((units >> 16) & 0xFF), UInt8((units >> 8) & 0xFF), UInt8(units & 0xFF)]
        }
        return Data(bytes)
    }

    /// `kCVImageBufferContentLightLevelInfoKey`: MaxCLL then MaxFALL, two bytes each.
    var contentLightLevel: Data {
        Data([UInt8(maxCLL >> 8), UInt8(maxCLL & 0xFF), UInt8(maxFALL >> 8), UInt8(maxFALL & 0xFF)])
    }

    /// "peak 1000 min 0.0050" from mastering display bytes, nil when they are not 24 bytes.
    static func describe(masteringDisplayColorVolume data: Data?) -> String? {
        guard let data, data.count == 24 else { return nil }
        let b = [UInt8](data)
        func u32(_ i: Int) -> Double {
            Double(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
        }
        return String(format: "peak %g min %.4f", u32(16) / 10_000, u32(20) / 10_000)
    }

    /// "1000/400" (MaxCLL/MaxFALL) from content light level bytes, nil when they are not 4 bytes.
    static func describe(contentLightLevel data: Data?) -> String? {
        guard let data, data.count == 4 else { return nil }
        let b = [UInt8](data)
        return "\(Int(b[0]) << 8 | Int(b[1]))/\(Int(b[2]) << 8 | Int(b[3]))"
    }
}
