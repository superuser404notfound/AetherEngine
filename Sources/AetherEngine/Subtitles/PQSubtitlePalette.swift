import Foundation

/// AE#1006: a UHD Blu-ray with HDR video codes its PGS palette in BT.2100 PQ with BT.2020 primaries,
/// so read as sRGB its white (PQ 0.62, about 294 nits) came out as 62 % grey. A palette entry is
/// taken back to Y'CbCr through the BT.709 matrix pgssubdec used on a 1080p canvas, rebuilt as
/// BT.2020 R'G'B', decoded to nits, placed against the BT.2408 graphics white of 203 nits, moved to
/// BT.709 primaries and clipped to SDR. An SDR-authored track in an HDR file only brightens a
/// little: 255 stays white, black stays black.
enum PQSubtitlePalette {
    static let graphicsWhiteNits = 203.0

    static func sRGB(fromPQ r: UInt8, _ g: UInt8, _ b: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
        let r709 = Double(r) / 255, g709 = Double(g) / 255, b709 = Double(b) / 255
        let y = 0.2126 * r709 + 0.7152 * g709 + 0.0722 * b709
        let cb = (b709 - y) / 1.8556
        let cr = (r709 - y) / 1.5748

        let r2020 = y + 1.4746 * cr
        let b2020 = y + 1.8814 * cb
        let g2020 = (y - 0.2627 * r2020 - 0.0593 * b2020) / 0.6780

        let lr = nits(pq: r2020) / graphicsWhiteNits
        let lg = nits(pq: g2020) / graphicsWhiteNits
        let lb = nits(pq: b2020) / graphicsWhiteNits

        return (encode(1.6605 * lr - 0.5876 * lg - 0.0728 * lb),
                encode(-0.1246 * lr + 1.1329 * lg - 0.0083 * lb),
                encode(-0.0182 * lr - 0.1006 * lg + 1.1187 * lb))
    }

    /// SMPTE ST 2084 EOTF.
    static func nits(pq value: Double) -> Double {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let p = pow(min(max(value, 0), 1), 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    private static func encode(_ linear: Double) -> UInt8 {
        let v = min(max(linear, 0), 1)
        let e = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8((e * 255).rounded())
    }
}
