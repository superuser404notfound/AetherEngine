import Foundation
import AetherEngine

// MARK: - seektest: rapid-seek burst repro (issue #35)

/// Headless macOS analogue of the #35 device repro: drives AVPlayer through a rapid-seek burst and tallies producer restarts vs. RestartCoalescer coalesces to measure cascade-vs-coalesced behavior.
@MainActor
private func seekTestRun(url: URL, seeks: Int, gapMs: Int, settleSeconds: Double) async -> Int32 {
    // Tally log lines distinguishing cascade (pre-#35) vs. RestartCoalescer behavior (post-#35).
    let tally = UncheckedBox<[String: Int]>([:])
    // #65 discriminator: collect the sequence of published host shifts (one per producer restart) and the raw
    // producer gate-open shifts. Two distinct values across a burst => cross-epoch shift divergence (Root A).
    let publishedShifts = UncheckedBox<[Double]>([])
    let gateOpenShifts = UncheckedBox<[Int]>([])
    // #65 ledger: largest |drift| (actual source content minus planned source per opened segment). A multi-second
    // value POSITIVELY confirms a content-vs-clock offset (Root B). Near-zero across a real restart cascade
    // redirects the 6s symptom to the producer wedge. parkCount = abnormal backpressure parks (VOD wedge signature).
    let maxLedgerDriftAbs = UncheckedBox<Double>(0)
    let ledgerCount = UncheckedBox<Int>(0)
    let parkCount = UncheckedBox<Int>(0)
    // #65 fix signals: did the VOD wedge breaker fire and recover (Piece A producer re-anchor + Piece B
    // engine seek-deadline clock reconcile)? A wedge that is BROKEN + re-anchored is the fix engaging.
    let wedgeBrokenCount = UncheckedBox<Int>(0)
    let reanchorCount = UncheckedBox<Int>(0)
    let seekReconcileCount = UncheckedBox<Int>(0)
    // EngineLog.handler fires from many threads concurrently (demuxer, producer, server, audio). Serialize the
    // whole body: unsynchronized append to the Swift arrays below corrupts the heap (SIGTRAP) under load.
    let handlerLock = NSLock()
    // @Sendable so the closure is NOT inferred @MainActor from this @MainActor function: EngineLog invokes it
    // synchronously from the HLSSegmentProducer.pump thread, and a MainActor-isolated body traps in Swift 6's
    // executor check (_dispatch_assert_queue_fail) the moment it makes an isolation-crossing call (prefix(while:)).
    EngineLog.handler = { @Sendable line in
        handlerLock.lock()
        defer { handlerLock.unlock() }
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
        // "[AetherEngine] #65 VOD shift published: <X>s (prev ...". Parse the published seconds value.
        if let r = line.range(of: "#65 VOD shift published: ") {
            let tail = line[r.upperBound...]
            if let sEnd = tail.range(of: "s "), let v = Double(tail[tail.startIndex..<sEnd.lowerBound]) {
                publishedShifts.value.append(v)
            }
        }
        // "[HLSSegmentProducer] video gate open: ... shift=<int>". Parse the raw producer shift (source ticks).
        if let r = line.range(of: "shift="), line.contains("video gate open") {
            let tail = line[r.upperBound...]
            let digits = tail.prefix { $0 == "-" || $0.isNumber }
            if let v = Int(digits) { gateOpenShifts.value.append(v) }
        }
        // "[HLSSegmentProducer] #65 ledger seg-... drift=<X>s ...". Track the largest magnitude content drift.
        if line.contains("#65 ledger ") {
            ledgerCount.value += 1
            if let r = line.range(of: "drift=") {
                let token = line[r.upperBound...].prefix { $0 == "-" || $0 == "." || $0.isNumber }
                if let v = Double(token) { maxLedgerDriftAbs.value = max(maxLedgerDriftAbs.value, abs(v)) }
            }
        }
        // "[HLSSegmentProducer] #65 backpressure PARK ...". Count abnormal parks (VOD wedge signature).
        if line.contains("#65 backpressure PARK") { parkCount.value += 1 }
        // Fix engaging: the wedge breaker exited the pump, the host re-anchored, and/or the seek deadline reconciled.
        if line.contains("#65 backpressure WEDGE BROKEN") { wedgeBrokenCount.value += 1 }
        if line.contains("#65 backpressure wedge: re-anchoring") { reanchorCount.value += 1 }
        if line.contains("#65 seek did not land") { seekReconcileCount.value += 1 }
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

    // Wait for state .playing AND duration > 0 (duration lags .playing via the host.$duration sink). Up to 15s.
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
    try? await Task.sleep(nanoseconds: 1_500_000_000) // brief settle before burst

    // #37/#38 probe: single backward seek with a 20ms concurrent sampler.
    // Pre-fix: clock bounces back through pre-seek position (100ms observer overwrites optimistic target).
    // Post-fix: host suppresses stale publish so clock holds target; isSeeking spans real landing.
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

    struct Sample { let wall: Double; let ct: Double; let src: Double; let playing: Bool }
    var samples: [Sample] = []
    let t0 = Date()
    func sample() {
        samples.append(Sample(
            wall: Date().timeIntervalSince(t0),
            ct: engine.currentTime,
            src: engine.sourceTime, // ct - src = clockLead (issue #49); ~0 on headless, meaningful on device
            playing: engine.state == .playing
        ))
    }

    // Back-and-forth hi<->lo scrub: backward jumps (hi->lo) fall outside the cache window, forcing a producer restart. Per-iteration offset avoids seek deduplication.
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

    let finalTarget = (duration * 0.5).rounded()
    print(String(format: "  settle: final seek to %.1f, sampling %.1fs", finalTarget, settleSeconds))
    await engine.seek(to: finalTarget)
    var st = 0.0
    while st < settleSeconds {
        try? await Task.sleep(nanoseconds: 100_000_000)
        st += 0.1
        sample()
    }

    // Longest contiguous interval where state=.playing but clock did not advance by >= 0.05s.
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

    // Clock stepping backward by > 1s between samples, or large forward leaps; both reported.
    var backwardJumps = 0
    var maxForwardStep = 0.0
    for k in 1..<max(1, samples.count) {
        let step = samples[k].ct - samples[k - 1].ct
        if step < -1.0 { backwardJumps += 1 }
        maxForwardStep = max(maxForwardStep, step)
    }

    // clockLead (issue #49): peak and post-settle residual of ct ahead of rendered frame.
    var maxClockLead = 0.0
    for s in samples { maxClockLead = max(maxClockLead, s.ct - s.src) }
    let settleClockLead = (samples.last.map { $0.ct - $0.src }) ?? 0

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
    print(String(format: "  clockLead (currentTime ahead of sourceTime/picture) peak=%.2fs settle=%.2fs",
                 maxClockLead, settleClockLead))
    print("  --- restart-machinery log tally ---")
    print("  producer restarted (full restarts) = \(fullRestart)")
    print("  coalesced behind in-flight         = \(coalesced)")
    print("  advancing to settled target        = \(settleAdvance)")
    print("  old producer abandoned (5s timeout)= \(abandon)")
    print("")
    print("  INTERPRETATION: a high 'full restarts' with ZERO 'coalesced' is the")
    print("  pre-#35 cascade. Post-#35 should show 'coalesced' > 0 and far fewer")
    print("  full restarts for the same burst; 'abandoned' should trend to 0.")

    // #65 discriminator: did the producer shift VARY across the burst's restart epochs?
    let pubShifts = publishedShifts.value
    let rawShifts = gateOpenShifts.value
    let distinctPub = Set(pubShifts.map { ($0 * 1000).rounded() / 1000 })
    let distinctRaw = Set(rawShifts)
    print("")
    print("  --- #65 cross-epoch shift discriminator ---")
    print("  producer gate-open shifts (raw ticks) = \(rawShifts)  distinct=\(distinctRaw.count)")
    print(String(format: "  host shifts published (seconds)       = %@  distinct=%d",
                 "[" + pubShifts.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]",
                 distinctPub.count))
    print("  clockLead settle = \(String(format: "%.2f", settleClockLead))s  (headless ~0 by design; #65 is presented-vs-clock, invisible to ct-src)")
    print("  ledger segments opened = \(ledgerCount.value)  maxContentDrift = \(String(format: "%.3f", maxLedgerDriftAbs.value))s  (the POSITIVE Root-B signal)")
    print("  abnormal backpressure parks (VOD wedge signature) = \(parkCount.value)")
    print("  #65 FIX signals: wedge breaks=\(wedgeBrokenCount.value)  producer re-anchors=\(reanchorCount.value)  seek-deadline reconciles=\(seekReconcileCount.value)")
    let fixEngaged = wedgeBrokenCount.value > 0 || reanchorCount.value > 0 || seekReconcileCount.value > 0
    if fixEngaged {
        print("  >> #65 FIX ENGAGED: the VOD wedge breaker / seek-deadline reconcile fired during the burst. A")
        print("     non-zero break+re-anchor with playback resuming afterward (clock advancing, no sustained PARK")
        print("     escalation) is the recovery the fix is meant to produce. Confirm on device that picture resumes.")
    }
    if fullRestart == 0 {
        print("  >> INCONCLUSIVE: 0 producer restarts. The file was fully produced before the burst, so")
        print("     every seek hit the cache and the cross-epoch cascade never fired. Re-run with a LONGER")
        print("     file (seek targets must land beyond the producer write head) to exercise #65.")
    } else if maxLedgerDriftAbs.value >= 0.5 {
        print("  >> ROOT B CONFIRMED (content-vs-clock): a segment was muxed with source content offset")
        print("     \(String(format: "%.2f", maxLedgerDriftAbs.value))s from its planned/EXTINF position, so the presented frame leads the")
        print("     clock by that much. Fix the content-drift source (off-plan seek landing / uniform-plan stride),")
        print("     NOT a seam port. Grep '#65 ledger' for the exact seg/epoch.")
    } else if distinctRaw.count > 1 || distinctPub.count > 1 {
        print("  >> ROOT A (cross-epoch shift divergence): the producer published MORE THAN ONE shift across")
        print("     the burst. Buffered bytes from a superseded epoch fold with the latest scalar -> picture")
        print("     leads the clock. The live seam-history port is the fix.")
    } else if parkCount.value > 0 {
        if fixEngaged {
            print("  >> PRODUCER WEDGE DETECTED AND BROKEN: \(parkCount.value) abnormal park(s) but the breaker fired")
            print("     (\(wedgeBrokenCount.value) break(s), \(reanchorCount.value) re-anchor(s), \(seekReconcileCount.value) seek reconcile(s)).")
            print("     This is the #65 fix recovering the livelock; verify on device that playback actually resumes.")
        } else {
            print("  >> PRODUCER WEDGE (UNRECOVERED): invariant shift AND ~zero ledger drift, but \(parkCount.value) abnormal")
            print("     backpressure park(s) and the breaker did NOT fire. The 6s symptom is the frozen-clock/stall")
            print("     artifact. Either the park stayed under the break threshold or the fix is not in this build.")
        }
    } else {
        print("  >> NO ENGINE-LEVEL DIVERGENCE REPRODUCED: invariant shift, ledger drift ~0, no wedge. The headless")
        print("     harness did not surface #65 in any engine signal. The avBufAhead+zeros from #65's earlier diag")
        print("     are consistent with healthy playback, so they do NOT confirm Root B on their own. Re-run with a")
        print("     LONGER high-bitrate file, or rely on the reporter device trace ('#65 ledger' + 'PARK' lines).")
    }
    print("")
    print("VERDICT: seektest DONE (comparison harness; compare tallies old vs new build)")
    return 0
}

func runSeekTest(url: URL, seeks: Int, gapMs: Int, settleSeconds: Double) -> Int32 {
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await seekTestRun(url: url, seeks: seeks, gapMs: gapMs, settleSeconds: settleSeconds)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}
