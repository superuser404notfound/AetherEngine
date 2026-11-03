#if DualLayerDolbyVision
import Foundation
@_spi(Diagnostics) import AetherEngine

/// Writes one Profile 7 FEL frame composed with and without its residual into `outDir`: fel_y.bin,
/// fel_uv.bin, mel_y.bin, mel_uv.bin (full-precision P010 planes, little-endian 16-bit) and frame.json.
func runElFrame(url: URL, seconds: Double, outDir: URL) -> Int32 {
    do {
        let d = try AetherEngine.doviFrameDump(url: url, at: seconds)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try d.felLuma.write(to: outDir.appendingPathComponent("fel_y.bin"))
        try d.felChroma.write(to: outDir.appendingPathComponent("fel_uv.bin"))
        try d.melLuma.write(to: outDir.appendingPathComponent("mel_y.bin"))
        try d.melChroma.write(to: outDir.appendingPathComponent("mel_uv.bin"))
        let meta: [String: Any] = ["seconds": d.seconds, "width": d.width, "height": d.height,
                                   "l1_avg_pq": d.l1AvgPQ, "l1_max_pq": d.l1MaxPQ,
                                   "residual_disabled_by_rpu": d.residualDisabledByRpu]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: outDir.appendingPathComponent("frame.json"))
        print("wrote \(d.width)x\(d.height) frame at \(String(format: "%.3f", d.seconds)) s to \(outDir.path)")
        if d.residualDisabledByRpu { print("note: the RPU disables the residual for this frame, so FEL and MEL are identical") }
        return 0
    } catch {
        print("ERROR: \(error)")
        return 1
    }
}
#endif
