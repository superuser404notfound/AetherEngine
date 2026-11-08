#if DolbyVisionFelCurves
import Foundation
@_spi(Diagnostics) import AetherEngine

/// `aetherctl felcurves <url> <out.rpu>`: runs a Profile 7 FEL source through the curve fold and writes the
/// Profile 8.1 RPUs it produced as a dovi_tool RPU file (presentation order), for `dovi_tool inject-rpu`.
func runFelCurves(url: URL, outPath: String) -> Int32 {
    do {
        let r = try AetherEngine.felCurveFold(url: url)
        var file = Data()
        for rpu in r.rpus {
            file.append(contentsOf: [0, 0, 0, 1])
            file.append(contentsOf: rpu)
        }
        try file.write(to: URL(fileURLWithPath: outPath))
        print("frames \(r.rpus.count) scenes fitted \(r.scenesFitted) without residual \(r.scenesWithoutResidual) "
              + "failed \(r.scenesFailed) in \(String(format: "%.1f", r.seconds)) s")
        return 0
    } catch {
        print("felcurves failed: \(error)")
        return 1
    }
}
#endif
