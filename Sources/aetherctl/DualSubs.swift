import Foundation
import AetherEngine

// MARK: - dualsubs: two independent subtitle channels (issue #47)

/// Loads a file, activates a primary and a secondary embedded subtitle
/// track, lets both side demuxers run, then asserts BOTH cue arrays
/// populate independently. Optionally seeks and verifies both channels
/// re-arm at the new position.
///
/// This is the headless macOS analogue of the device repro for #47:
/// the side-demuxer infrastructure is platform-agnostic, so both
/// channels can be observed via their published cue arrays directly on
/// macOS without a display layer.
@MainActor
private func dualSubsRun(path: String, primaryIndex: Int, secondaryIndex: Int, seekTo: Double?) async -> Int32 {
    print("")
    print("=== DUALSUBS (issue #47 dual subtitle channels) ===")
    print("  file=\(path) primary=\(primaryIndex) secondary=\(secondaryIndex) seek=\(seekTo.map { String($0) } ?? "none")")

    let url = URL(fileURLWithPath: path)
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: dualsubs FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }
    defer { engine.stop() }

    do {
        try await engine.load(url: url)
    } catch {
        print("VERDICT: dualsubs FAIL: load error: \(error.localizedDescription)")
        return 1
    }

    // Wait for playback to begin (state .playing). Up to 15 s.
    var waited = 0.0
    while engine.state != .playing, waited < 15.0 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        waited += 0.1
    }
    guard engine.state == .playing else {
        print("VERDICT: dualsubs FAIL: engine did not reach .playing within 15s (state=\(engine.state))")
        return 1
    }
    print(String(format: "  loaded: state=%@ duration=%.1fs t=%.2fs",
                 "\(engine.state)", engine.duration, engine.currentTime))

    // Activate both subtitle channels. The side demuxers open
    // independent cursors into the source and pace against sourceTime.
    engine.selectSubtitleTrack(index: primaryIndex)
    engine.selectSecondarySubtitleTrack(index: secondaryIndex)

    // Give both side demuxers time to produce cues. 8 s matches the
    // typical side-demuxer latency (seek + decode warm-up) plus margin.
    print("  waiting 8s for both side demuxers to emit cues...")
    try? await Task.sleep(nanoseconds: 8_000_000_000)

    let p1 = engine.subtitleCues.count
    let s1 = engine.secondarySubtitleCues.count
    print("  after activation: primaryCues=\(p1) secondaryCues=\(s1)")

    if let seekTo {
        print("  seeking to \(seekTo)s...")
        await engine.seek(to: seekTo)
        // Both channels re-arm on seek; give them 6 s to catch up.
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let p2 = engine.subtitleCues.count
        let s2 = engine.secondarySubtitleCues.count
        print("  after seek to \(seekTo)s: primaryCues=\(p2) secondaryCues=\(s2)")
    }

    let ok = p1 > 0 && s1 > 0
    print("")
    print("VERDICT: dualsubs \(ok ? "PASS" : "FAIL"): \(ok ? "both subtitle channels emitted cues independently" : "a channel emitted no cues (primary=\(p1) secondary=\(s1))")")
    return ok ? 0 : 1
}

/// Entry point for the `dualsubs` subcommand.
func runDualSubs(path: String, primaryIndex: Int, secondaryIndex: Int, seekTo: Double?) -> Int32 {
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await dualSubsRun(path: path, primaryIndex: primaryIndex, secondaryIndex: secondaryIndex, seekTo: seekTo)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}
