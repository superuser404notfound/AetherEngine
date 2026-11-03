#if DualLayerDolbyVision
import Foundation
@_spi(Diagnostics) import AetherEngine

/// Runs the FEL compose route over a Profile 7 source with the per-frame display-metadata digest on, then
/// prints what it found: for every frame, the source RPU's display metadata (all levels, all fields) against
/// the RPU read back from the pixel buffer at the hand-off point. Exit 0 when every frame passes (a frame whose only
/// extra differences are mode 2's reset of the colour matrices counts as passing and is reported as normalised), 1 otherwise.
/// `--out` writes one JSON object per frame (both readings and both RPU byte strings, hex).
func runDmPass(url: URL, maxFrames: Int, out: String?) -> Int32 {
    setenv("AETHER_DM_DIGEST", "log", 1)
    // AETHER_DM_PRINT=1 (or hex, with both RPU byte strings) echoes the per-frame digest lines, as a host log overlay would show them on a device.
    let print_ = ProcessInfo.processInfo.environment["AETHER_DM_PRINT"]
    if print_ == "hex" { setenv("AETHER_DM_DIGEST", "hex", 1) }
    if print_ == "1" || print_ == "hex" {
        EngineLog.handler = { line in if line.hasPrefix("[dm-digest]") { print(line) } }
    }
    if let out {
        try? FileManager.default.removeItem(atPath: out)
        setenv("AETHER_DM_DIGEST_FILE", out, 1)
    }
    print("aetherctl dmpass: \(url.lastPathComponent)")
    let probe: FelProbeResult
    do { probe = try AetherEngine.felDecodeProbe(url: url, maxPackets: maxFrames) } catch {
        print("ERROR: felDecodeProbe failed: \(error)")
        return 2
    }
    let r = AetherEngine.dmPassthroughReport()
    print("")
    print("packets \(probe.packetsProcessed), delivered \(probe.framesReconstructed), composed \(probe.composedFrames), FEL \(probe.isFEL)")
    print("frames observed \(r.frames), with attachment \(r.withAttachment), with source RPU \(r.withSource), pass \(r.passing), unreadable \(r.unreadable)")
    print("levels in the attached RPU (frames): " + r.levelFrames.sorted { $0.key < $1.key }.map { "L\($0.key)=\($0.value)" }.joined(separator: " "))
    print("CM version of the attached RPU (frames): " + r.cmVersions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    print("fields changed (expected for mode 2): " + (r.changedFields.keys.filter { r.unexpectedFields[$0] == nil && r.normalisedFields[$0] == nil }.sorted().joined(separator: ", ")))
    print("fields NORMALISED by mode 2 (colour matrices / signal colour space reset to the Profile 8.1 values; frames \(r.normalisedFrames)): "
          + (r.normalisedFields.isEmpty ? "none" : r.normalisedFields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))
    print("fields changed UNEXPECTEDLY: " + (r.unexpectedFields.isEmpty ? "none" : r.unexpectedFields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))
    let ok = r.frames > 0 && r.passing == r.frames && probe.composedFrames > 0
    print(ok ? "VERDICT: PASS" : "VERDICT: FAIL")
    return ok ? 0 : 1
}
#endif
