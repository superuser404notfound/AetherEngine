import Foundation
@_spi(Diagnostics) import AetherEngine

/// Surveys a title's Dolby Vision display metadata and names the frame worth pinning for the
/// on-device consumption test. See `DoviDisplayMetadataDebug` for what the pin is for.
func runDvSurvey(url: URL, maxFrames: Int, listFrames: Int) -> Int32 {
    print("aetherctl dvsurvey: \(url.path)")
    print("Scanning up to \(maxFrames) RPU-bearing frames...")
    print("")

    let result: DoviRpuSurveyResult
    do {
        result = try AetherEngine.doviRpuSurvey(url: url, maxFrames: maxFrames)
    } catch {
        print("ERROR: doviRpuSurvey failed: \(error)")
        return 1
    }

    guard !result.frames.isEmpty else {
        print("VERDICT: no Dolby Vision RPUs found in \(result.packetsProcessed) video packet(s).")
        print("         Either this is not a Dolby Vision source, or the RPUs failed to parse")
        print("         (\(result.rpuFailures) failure(s) recorded).")
        return 2
    }

    let maxPQs = result.frames.map(\.l1MaxPQ).sorted()
    let avgPQs = result.frames.map(\.l1AvgPQ).sorted()
    func pct(_ sorted: [UInt16], _ p: Double) -> UInt16 { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
    func nits(_ code: UInt16) -> String { String(format: "%.1f", DoviRpuSurvey.pqCodeToNits(code)) }

    print("=== TITLE SUMMARY ===")
    print("Video packets:        \(result.packetsProcessed)")
    print("Frames with RPU:      \(result.frames.count)")
    print("RPU parse failures:   \(result.rpuFailures)")
    print("Enhancement layer:    \(result.enhancementLayerType ?? "n/a (not profile 7)")")
    print("Scene changes:        \(result.frames.filter(\.sceneRefresh).count)")
    print("L2 trims per frame:   \(Set(result.frames.map(\.l2Trims.count)).sorted().map(String.init).joined(separator: "/"))")
    print("Attached payload:     \(Set(result.frames.map(\.payloadBytes)).sorted().map(String.init).joined(separator: "/")) bytes")
    if let first = result.frames.first {
        print("Source mastering:     min_pq \(first.sourceMinPQ) (\(nits(first.sourceMinPQ)) nits), max_pq \(first.sourceMaxPQ) (\(nits(first.sourceMaxPQ)) nits)")
    }
    print("")

    // `String(format:)` with %s takes a C string, not a Swift String, so pad by hand.
    func col(_ s: String, _ w: Int) -> String { String(repeating: " ", count: max(0, w - s.count)) + s }
    func row(_ label: String, _ v: [UInt16]) -> String {
        ([label.padding(toLength: 10, withPad: " ", startingAt: 0)]
         + [v.first!, pct(v, 0.1), pct(v, 0.5), pct(v, 0.9), v.last!].map { col(String($0), 8) }).joined(separator: " ")
    }
    print("=== L1 DISTRIBUTION (12-bit PQ codes) ===")
    print((["field".padding(toLength: 10, withPad: " ", startingAt: 0)]
           + ["min", "p10", "median", "p90", "max"].map { col($0, 8) }).joined(separator: " "))
    print(row("max_pq", maxPQs))
    print(row("avg_pq", avgPQs))
    print("           in nits: \(nits(maxPQs.first!)) ... \(nits(maxPQs.last!)) (max_pq)")
    print("")

    if listFrames > 0 {
        print("=== FIRST \(min(listFrames, result.frames.count)) FRAMES ===")
        print([col("frame", 6), col("sc", 3), col("min_pq", 7), col("max_pq", 7), col("avg_pq", 7)]
              .joined(separator: " ") + "   L2 trims (target_max_pq: slope/offset/power)")
        for f in result.frames.prefix(listFrames) {
            let trims = f.l2Trims.map { "\($0.targetMaxPQ): \($0.slope)/\($0.offset)/\($0.power)" }.joined(separator: "  ")
            print([col(String(f.frameIndex), 6), col(f.sceneRefresh ? "*" : "", 3),
                   col(String(f.l1MinPQ), 7), col(String(f.l1MaxPQ), 7), col(String(f.l1AvgPQ), 7)]
                  .joined(separator: " ") + "   " + trims)
        }
        print("")
    }

    print("=== PIN CANDIDATES FOR THE CONSUMPTION TEST ===")
    if let dark = result.darkestFrame {
        print("Darkest   frame \(dark.frameIndex): avg_pq \(dark.l1AvgPQ) (\(nits(dark.l1AvgPQ)) nits), max_pq \(dark.l1MaxPQ)")
    }
    if let bright = result.brightestFrame {
        print("Brightest frame \(bright.frameIndex): avg_pq \(bright.l1AvgPQ) (\(nits(bright.l1AvgPQ)) nits), max_pq \(bright.l1MaxPQ)")
    }
    print("")

    guard let poison = result.strongestPoison, let median = result.medianL1 else {
        print("VERDICT: surveyed \(result.frames.count) frame(s) but could not pick a pin.")
        return 3
    }

    // Name the pin by whichever field carries most of its distance from the median, so the
    // threshold rule below selects the same frame the scan would.
    let onAvg = poison.dominantField == "avg_pq"
    let pinnedValue = onAvg ? poison.frame.l1AvgPQ : poison.frame.l1MaxPQ
    let medianValue = onAvg ? median.avg : median.max
    let isDark = pinnedValue < medianValue
    let rule = "\(onAvg ? "avgpq" : "maxpq")\(isDark ? "<=" : ">=")\(pinnedValue)"
    // The scan window has to reach the frame it is being told to find. Playback frame order is
    // presentation order and the survey counts in decode order, so leave headroom for reordering.
    let scanWindow = max(240, poison.frame.frameIndex + 60)
    let scanRule = "\(isDark ? "darkest" : "brightest"):\(scanWindow)"

    print("Strongest pin is frame \(poison.frame.frameIndex):")
    print("  L1      min \(poison.frame.l1MinPQ)  max \(poison.frame.l1MaxPQ)  avg \(poison.frame.l1AvgPQ)")
    print("  median  min \(median.min)  max \(median.max)  avg \(median.avg)")
    print("  total distance \(poison.deltaPQ) PQ codes, mostly in \(poison.dominantField)")
    print("  (\(nits(pinnedValue)) nits vs \(nits(medianValue)) nits on \(poison.dominantField))")
    print("")
    print("Arm the device with either of:")
    print("    aetherctl play --fel --surface --dv-pin '\(scanRule),period:2' <url>")
    print("        scans the first \(scanWindow) frames as they play and pins the most extreme one it saw")
    print("    aetherctl play --fel --surface --dv-pin '\(rule),period:2' <url>")
    print("        pins the first frame matching this exact threshold")
    print("")
    print("`aetherctl play` runs on this Mac. To test the panel, arm the same pin string in a host app on")
    print("the Apple TV (AetherEngine.armDolbyVisionPinTest) and play this title there. The decoded")
    print("pixels are bit-identical in both phases, so a 2-second brightness or saturation pulse")
    print("means the attachment reached the panel. A flat picture means it did not.")
    print("")

    // Below roughly a quarter-stop of combined L1 movement the panel's own tone mapping absorbs the
    // difference, so say so rather than sending the operator to stare at a TV for nothing.
    if poison.deltaPQ < 300 {
        print("VERDICT: WEAK - the strongest pin moves L1 by only \(poison.deltaPQ) PQ codes in total.")
        print("         This title is too flat for a reliable visual test; pick one with a")
        print("         dark-to-bright range, or survey more frames with --frames.")
        return 4
    }
    print("VERDICT: surveyed \(result.frames.count) frame(s); strongest pin moves L1 by \(poison.deltaPQ) PQ codes.")
    return 0
}
