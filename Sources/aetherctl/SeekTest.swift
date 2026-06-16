import Foundation
import AetherEngine

// MARK: - seektest: rapid-seek burst repro (issue #35)

/// Drives a real AVPlayer (native loopback-HLS path) through a burst of
/// rapid seeks and measures the producer-restart behavior, the longest
/// "wedge" (state == .playing but the clock frozen), the final settle
/// accuracy, and any non-monotonic clock jumps.
///
/// This is the headless macOS analogue of the device repro for #35: the
/// restart machinery (`requestRestart` / `performRestart` / the segment
/// provider's restart handler) is platform-agnostic, so the cascade-vs-
/// coalesced difference is directly observable here via the engine log
/// tallies, even though macOS AVPlayer's HLS tuning differs from tvOS.
@MainActor
private func seekTestRun(url: URL, seeks: Int, gapMs: Int, settleSeconds: Double) async -> Int32 {
    // Tally the restart / coalesce log lines that distinguish the cascade
    // (pre-#35) from the coalesced behavior (post-#35).
    let tally = UncheckedBox<[String: Int]>([:])
    EngineLog.handler = { line in
        let t = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(t)] \(line)")
        func bump(_ key: String, _ needle: String) {
            if line.contains(needle) { tally.value[key, default: 0] += 1 }
        }
        bump("fullRestart",   "producer restarted at idx")
        bump("coalesced",     "coalesced behind in-flight")
        bump("settleAdvance", "advancing to settled target")
        bump("abandon",       "abandoning it")
    }

    print("")
    print("=== SEEKTEST (issue #35 rapid-seek burst) ===")
    print("  url=\(url.absoluteString) seeks=\(seeks) gapMs=\(gapMs) settle=\(settleSeconds)s")

    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: seektest FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }
    defer { engine.stop() }

    var options = LoadOptions()
    options.suppressDisplayCriteria = true
    options.matchContentEnabled = false

    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: seektest FAIL: load error: \(error.localizedDescription)")
        return 1
    }

    // Wait for playback to begin AND for AVPlayer's item duration to
    // propagate (it lags state == .playing by a beat, arriving via the
    // host.$duration sink once the item is ready). Up to 15 s.
    var waited = 0.0
    while (engine.state != .playing || engine.duration <= 0), waited < 15.0 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        waited += 0.1
    }
    let duration = engine.duration
    print(String(format: "  loaded: state=%@ duration=%.1fs t=%.2fs",
                 "\(engine.state)", duration, engine.currentTime))
    guard duration > 30 else {
        print("VERDICT: seektest FAIL: duration too short (\(duration)s); need > 30s of seekable VOD")
        return 1
    }
    // Let playback settle for a moment before the burst.
    try? await Task.sleep(nanoseconds: 1_500_000_000)

    // ---- #37/#38 probe: single backward seek with a concurrent sampler ----
    // A 20 ms sampler records (currentTime, isSeeking) across one backward
    // seek. Pre-fix the engine clock bounces back through the pre-seek
    // position before AVPlayer's seek physically lands (the 100 ms time
    // observer overwrites the optimistic target with the stale clock);
    // post-fix the host suppresses that stale publish so the clock holds the
    // target, and isSeeking spans the real landing. Runs the sampler for a
    // fixed window so it catches both the in-flight hold (post-fix, inside
    // the await) and the post-return bounce (pre-fix, after the await).
    let probeHi = duration * 0.85
    let probeLo = duration * 0.10
    await engine.seek(to: probeHi)
    try? await Task.sleep(nanoseconds: 800_000_000)
    let preSeekCt = engine.currentTime
    struct Probe { let ct: Double; let seeking: Bool }
    let probeBox = UncheckedBox<[Probe]>([])
    let sampler = Task { @MainActor in
        for _ in 0..<200 {   // ~4 s at 20 ms
            probeBox.value.append(Probe(ct: engine.currentTime, seeking: engine.isSeeking))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    await engine.seek(to: probeLo)
    _ = await sampler.value
    let probes = probeBox.value
    let tol = max(2.0, duration * 0.02)
    var firstTargetIdx: Int?
    var bounceAfterTarget = false
    for (i, p) in probes.enumerated() {
        if firstTargetIdx == nil, abs(p.ct - probeLo) <= tol { firstTargetIdx = i }
        if let ft = firstTargetIdx, i > ft, abs(p.ct - preSeekCt) <= tol { bounceAfterTarget = true }
    }
    let sawSeeking = probes.contains { $0.seeking }
    let endedCleared = !(probes.last?.seeking ?? true)
    print("")
    print("=== #37/#38 PROBE (single backward seek, concurrent sampler) ===")
    print(String(format: "  preSeek=%.1f target=%.1f tol=%.1f samples=%d", preSeekCt, probeLo, tol, probes.count))
    print("  #37 clock bounce back through pre-seek after reaching target: "
          + (bounceAfterTarget ? "YES  <-- FAIL" : "no  <-- PASS"))
    print("  #38 isSeeking observed in-flight=\(sawSeeking ? "yes" : "NO") ended-cleared=\(endedCleared ? "yes" : "NO")  "
          + ((sawSeeking && endedCleared) ? "<-- PASS" : "<-- FAIL"))

    struct Sample { let wall: Double; let ct: Double; let playing: Bool }
    var samples: [Sample] = []
    let t0 = Date()
    func sample() {
        samples.append(Sample(
            wall: Date().timeIntervalSince(t0),
            ct: engine.currentTime,
            playing: engine.state == .playing
        ))
    }

    // Back-and-forth scrub between a low and a high anchor. Backward jumps
    // (hi -> lo) land outside the resident cache window and force a
    // producer restart, which is exactly the cascade trigger. A small
    // per-iteration offset keeps every target distinct so no two seeks
    // dedupe to a no-op.
    let lo = duration * 0.10
    let hi = duration * 0.85
    print(String(format: "  burst: %d seeks alternating ~%.1f <-> ~%.1f, gap=%dms", seeks, lo, hi, gapMs))

    for i in 0..<seeks {
        let base = (i % 2 == 0) ? lo : hi
        let target = base + Double(i % 7)
        await engine.seek(to: target)
        sample()
        var slept = 0
        let step = max(1, min(gapMs, 10))
        while slept < gapMs {
            try? await Task.sleep(nanoseconds: UInt64(step) * 1_000_000)
            slept += step
            sample()
        }
    }

    // One final settle seek to mid-file, then sample the clock as it
    // recovers.
    let finalTarget = (duration * 0.5).rounded()
    print(String(format: "  settle: final seek to %.1f, sampling %.1fs", finalTarget, settleSeconds))
    await engine.seek(to: finalTarget)
    var st = 0.0
    while st < settleSeconds {
        try? await Task.sleep(nanoseconds: 100_000_000)
        st += 0.1
        sample()
    }

    // ---- Analysis ----
    // Longest wedge: the longest contiguous wall-clock interval where the
    // engine reported .playing but the clock did not advance (>= 0.05 s).
    var maxWedge = 0.0
    var runStart: Double?
    for k in 1..<max(1, samples.count) {
        let cur = samples[k]
        let advanced = abs(cur.ct - samples[k - 1].ct) >= 0.05
        if cur.playing, !advanced {
            if runStart == nil { runStart = samples[k - 1].wall }
        } else if let rs = runStart {
            maxWedge = max(maxWedge, cur.wall - rs)
            runStart = nil
        }
    }
    if let rs = runStart, let last = samples.last {
        maxWedge = max(maxWedge, last.wall - rs)
    }

    // Non-monotonic jumps during the settle phase: the clock stepping
    // BACKWARD by more than 1 s between consecutive samples (the #35
    // "146.7 -> 271.9" signature is a forward jump, but any large
    // unexpected step is suspect; we report both directions).
    var backwardJumps = 0
    var maxForwardStep = 0.0
    for k in 1..<max(1, samples.count) {
        let step = samples[k].ct - samples[k - 1].ct
        if step < -1.0 { backwardJumps += 1 }
        maxForwardStep = max(maxForwardStep, step)
    }

    let finalCt = samples.last?.ct ?? engine.currentTime
    let settleError = abs(finalCt - finalTarget)

    let fullRestart   = tally.value["fullRestart"]   ?? 0
    let coalesced     = tally.value["coalesced"]     ?? 0
    let settleAdvance = tally.value["settleAdvance"] ?? 0
    let abandon       = tally.value["abandon"]       ?? 0

    print("")
    print("=== SEEKTEST RESULTS ===")
    print(String(format: "  samples=%d", samples.count))
    print(String(format: "  maxWedge (playing but clock frozen) = %.2fs", maxWedge))
    print(String(format: "  finalSeekTarget=%.1f finalClock=%.2f settleError=%.2fs",
                 finalTarget, finalCt, settleError))
    print(String(format: "  clock backwardJumps(>1s)=%d  maxForwardStep=%.2fs", backwardJumps, maxForwardStep))
    print("  --- restart-machinery log tally ---")
    print("  producer restarted (full restarts) = \(fullRestart)")
    print("  coalesced behind in-flight         = \(coalesced)")
    print("  advancing to settled target        = \(settleAdvance)")
    print("  old producer abandoned (5s timeout)= \(abandon)")
    print("")
    print("  INTERPRETATION: a high 'full restarts' with ZERO 'coalesced' is the")
    print("  pre-#35 cascade. Post-#35 should show 'coalesced' > 0 and far fewer")
    print("  full restarts for the same burst; 'abandoned' should trend to 0.")
    print("")
    print("VERDICT: seektest DONE (comparison harness; compare tallies old vs new build)")
    return 0
}

/// Entry point for the `seektest` subcommand.
func runSeekTest(url: URL, seeks: Int, gapMs: Int, settleSeconds: Double) -> Int32 {
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await seekTestRun(url: url, seeks: seeks, gapMs: gapMs, settleSeconds: settleSeconds)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}
