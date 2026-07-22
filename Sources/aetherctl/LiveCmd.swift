import Foundation
import AetherEngine

// MARK: - high-bitrate seed generation

/// Ensure a ~22 Mbps 1080p H.264 MPEG-TS seed exists at `path`, generating it with ffmpeg if absent. A high bitrate is required to surface AVPlayer's retain-everything memory behaviour in resident_size. Returns true on success.
func ensureHighBitrateSeed(path: String) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: path) {
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > 5_000_000 { // ~22 Mbps x 10s = ~25 MB; anything smaller is suspect
            print("high-bitrate seed present: \(path) (\(size) bytes, \(String(format: "%.1f", Double(size) / 1_048_576.0)) MB)")
            return true
        }
        print("high-bitrate seed at \(path) is only \(size) bytes; regenerating")
    }

    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpeg = ffmpegCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
        print("ERROR: ffmpeg not found on \(ffmpegCandidates). Install it (brew install ffmpeg) to generate the high-bitrate seed.")
        return false
    }

    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    print("generating high-bitrate seed via ffmpeg (\(ffmpeg)) -> \(path) ...")

    // Two-stage seed: cheap 1.5 Mbps 6s intro + 22 Mbps 24s body, both 1080p H.264 with 5s GOP (-g 150 at 30fps).
    // The intro keeps seg-0 small enough to publish before AVPlayer's 1.5*target stall timer (CoreMedia -12888).
    // The 22 Mbps body stresses AVPlayer retain-everything; H.264 routes the native AVPlayer path.
    // Raw MPEG-TS is byte-concatenable; LiveFixture loops the whole seed.
    let tmp = NSTemporaryDirectory()
    let introPath = (tmp as NSString).appendingPathComponent("aetherctl-seed-intro.ts")
    let bodyPath  = (tmp as NSString).appendingPathComponent("aetherctl-seed-body.ts")

    func runFFmpeg(_ args: [String], label: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            print("ERROR: failed to launch ffmpeg (\(label)): \(error.localizedDescription)")
            return false
        }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            print("ERROR: ffmpeg (\(label)) exited \(proc.terminationStatus). Output tail:")
            if let text = String(data: out, encoding: .utf8) { print(String(text.suffix(2000))) }
            return false
        }
        return true
    }

    let introArgs = [
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=6",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=6",
        "-c:v", "libx264", "-b:v", "1500k", "-maxrate", "1500k", "-bufsize", "3M",
        "-g", "150", "-keyint_min", "150", "-sc_threshold", "0",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
        "-muxrate", "2M", "-f", "mpegts", introPath, "-y"
    ]
    let bodyArgs = [
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=24",
        "-c:v", "libx264", "-b:v", "22M", "-maxrate", "22M", "-bufsize", "44M",
        "-g", "150", "-keyint_min", "150", "-sc_threshold", "0",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
        "-muxrate", "24M", "-f", "mpegts", bodyPath, "-y"
    ]
    guard runFFmpeg(introArgs, label: "intro"), runFFmpeg(bodyArgs, label: "body") else {
        return false
    }

    guard let introData = try? Data(contentsOf: URL(fileURLWithPath: introPath)),
          let bodyData  = try? Data(contentsOf: URL(fileURLWithPath: bodyPath)) else {
        print("ERROR: could not read generated intro/body TS files")
        return false
    }
    var combined = introData
    combined.append(bodyData)
    do {
        try combined.write(to: URL(fileURLWithPath: path))
    } catch {
        print("ERROR: could not write combined seed to \(path): \(error.localizedDescription)")
        return false
    }
    try? fm.removeItem(atPath: introPath)
    try? fm.removeItem(atPath: bodyPath)

    let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    guard size > 5_000_000 else {
        print("ERROR: generated seed at \(path) is only \(size) bytes; ffmpeg may have failed silently.")
        return false
    }
    print("generated high-bitrate seed: \(path) (\(size) bytes, \(String(format: "%.1f", Double(size) / 1_048_576.0)) MB; ~1.5 Mbps 6 s intro + 22 Mbps 24 s body)")
    return true
}

// MARK: - live

/// Start a LiveFixture, load it with LoadOptions(isLive: true), play for `playSeconds`, and verdict on clock advancement. `dvrWindow` sets LoadOptions.dvrWindowSeconds; nil = live-only floor.
func runLive(
    seconds playSeconds: Double,
    seed seedPath: String?,
    dvrWindow: Double?,
    serveOnly: Bool,
    measureRSS: Bool,
    reportCacheBytes: Bool,
    rewindTest: Bool = false,
    reloadTest: Bool = false,
    forceSoftware: Bool = false,
    dropAfter: Double? = nil,
    discontinuityAt: Double? = nil,
    realtime: Bool = false,
    fastZap: Bool = false,
    pacingPreroll: Double? = nil
) -> Int32 {
    // Relative timestamps make join latency (readyToPlay et al.) readable off the log (AE#195).
    let logEpoch = Date()
    EngineLog.handler = { print(String(format: "[+%6.2fs] ", Date().timeIntervalSince(logEpoch)) + $0) }

    // TEST-ONLY: force SoftwarePlaybackHost routing; cleared on exit to avoid in-process bleed.
    AetherEngine.setForceSoftwarePathForTesting(forceSoftware)
    if forceSoftware {
        print("aetherctl live: --sw set, forcing SoftwarePlaybackHost routing")
    }
    defer { AetherEngine.setForceSoftwarePathForTesting(false) }

    let resolvedSeed = seedPath ?? "Fixtures/user/h264-ts-sample.ts" // relative to CWD under `swift run`
    print("aetherctl live: seed=\(resolvedSeed) seconds=\(playSeconds)" +
          (dvrWindow.map { " dvr-window=\($0)" } ?? " dvr-window=none (live-only floor)") +
          (dropAfter.map { " drop-after=\($0)s" } ?? "") +
          (discontinuityAt.map { " discontinuity-at=\($0)s" } ?? "") +
          (measureRSS ? " measure-rss=true" : "") +
          (reportCacheBytes ? " report-cache-bytes=true" : ""))

    let fixture: LiveFixture
    do {
        fixture = try LiveFixture(seedPath: resolvedSeed)
    } catch {
        print("ERROR: \(error)")
        return 1
    }
    fixture.dropAfterSeconds = dropAfter
    fixture.discontinuityAfterSeconds = discontinuityAt
    fixture.paced = realtime
    if realtime {
        print("aetherctl live: --realtime set, pacing fixture output at ~1x")
    }
    if let preroll = pacingPreroll {
        fixture.pacingPrerollSeconds = preroll
        print("aetherctl live: --preroll \(preroll)s (0 = strict-realtime origin, no backlog burst)")
    }
    if fastZap {
        print("aetherctl live: --fast-zap set, LoadOptions.liveJoinProfile = .fastZap (AE#195)")
    }

    let liveURL: URL
    do {
        liveURL = try fixture.start()
    } catch {
        print("ERROR: \(error)")
        return 1
    }
    print("=== LIVE URL ===")
    print(liveURL.absoluteString)
    print("================")

    // --serve-only: park the fixture for curl/ffprobe inspection without the engine attached.
    //   curl -s http://127.0.0.1:<port>/live.ts | head -c 3000000 > /tmp/x.ts
    //   ffprobe -v error -show_entries packet=pts -of csv /tmp/x.ts
    if serveOnly {
        print("Fixture parked (--serve-only). Ctrl-C to stop.")
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            fixture.stop()
            exit(0)
        }
        src.resume()
        RunLoop.main.run()
        return 0 // unreachable
    }

    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        if rewindTest {
            box.value = await liveRewindTest(url: liveURL, seconds: playSeconds,
                                             dvrWindow: dvrWindow ?? 60)
            fixture.stop()
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        if reloadTest {
            box.value = await liveReloadTest(url: liveURL, seconds: playSeconds,
                                             dvrWindow: dvrWindow ?? 600)
            fixture.stop()
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        box.value = await liveSmokeTest(url: liveURL, seconds: playSeconds, fastZap: fastZap,
                                        dvrWindow: dvrWindow, measureRSS: measureRSS,
                                        reportCacheBytes: reportCacheBytes,
                                        checkMonotonic: discontinuityAt != nil)
        fixture.stop()
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func liveSmokeTest(url: URL, seconds playSeconds: Double,
                           fastZap: Bool = false,
                           dvrWindow: Double? = nil,
                           measureRSS: Bool = false,
                           reportCacheBytes: Bool = false,
                           checkMonotonic: Bool = false) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: live FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow
    options.liveJoinProfile = fastZap ? .fastZap : .standard

    // AE#195: load elapsed includes the startup-cushion gate, so this is the join-latency metric
    // a --realtime fixture A/Bs between profiles.
    let loadStartedAt = Date()
    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: live FAIL: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }
    print(String(format: "  JOIN: load returned in %.2fs (profile=%@; live load does not await readiness)",
                 Date().timeIntervalSince(loadStartedAt), fastZap ? "fastZap" : "standard"))

    print(String(format: "  post-load state=%@ isLive=%@ t=%.2fs",
                 "\(engine.state)", "\(engine.isLive)", engine.currentTime))
    // AE#195 join metric: two consecutive advancing 1 Hz ticks = playback really rendering. A single
    // advance is not enough (currentTime presets to the initial position before readiness and freezes
    // there until readyToPlay). Reported with up to ~2s quantization; the timestamped readyToPlay log
    // line is the precise signal.
    var joinPrevT = engine.currentTime
    var joinCandidateElapsed: Double? = nil
    var joinReported = false

    if measureRSS {
        print("RSS_HEADER: elapsed_s  phys_footprint_mb  resident_mb")
    }
    if reportCacheBytes {
        print("CACHE_HEADER: elapsed_s  disk_bytes  disk_mb")
        // Emit an initial sample at t=0 so the plateau has a baseline.
        let b0 = engine.segmentCacheDiskBytes ?? 0
        print(String(format: "CACHE_BYTES: elapsed=0s  disk=%lld B  disk=%.2f MB",
                     b0, Double(b0) / 1_048_576.0))
    }

    let startTime = Date()
    var lastRSSTick: Double = 0
    var lastCacheTick: Double = 0

    // Monotonicity tracking for --discontinuity-at: currentTime and live edge must never jump backward, and never leap forward by the raw PTS delta.
    var monotonicViolation = false
    var maxForwardStep: Double = 0
    var prevCurrentTime = engine.currentTime
    var prevEdgeTime = engine.liveEdgeTime
    let leapCeiling: Double = 100.0 // fixture races ahead, so single-tick steps can be large; any raw-PTS leap (1000s) dwarfs this

    let ticks = max(1, Int(playSeconds))
    for tick in 0..<ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let elapsed = Date().timeIntervalSince(startTime)
        if !joinReported {
            let t = engine.currentTime
            let advancing = t > joinPrevT + 0.2
            joinPrevT = t
            if advancing, let first = joinCandidateElapsed {
                joinReported = true
                print(String(format: "  JOIN: sustained clock advance from %.1fs after load start (profile=%@)",
                             first, fastZap ? "fastZap" : "standard"))
            } else {
                joinCandidateElapsed = advancing ? Date().timeIntervalSince(loadStartedAt) : nil
            }
        }
        if checkMonotonic {
            let ct = engine.currentTime
            let et = engine.liveEdgeTime
            if ct + 0.5 < prevCurrentTime || et + 0.5 < prevEdgeTime { // backward jump
                monotonicViolation = true
                print(String(format: "  MONOTONIC VIOLATION (backward): "
                             + "currentTime %.2f->%.2f edge %.2f->%.2f",
                             prevCurrentTime, ct, prevEdgeTime, et))
            }
            let ctStep = ct - prevCurrentTime
            let etStep = et - prevEdgeTime
            maxForwardStep = max(maxForwardStep, max(ctStep, etStep))
            if ctStep > leapCeiling || etStep > leapCeiling {
                monotonicViolation = true
                print(String(format: "  MONOTONIC VIOLATION (raw-PTS leap): "
                             + "currentTime step=%.2f edge step=%.2f",
                             ctStep, etStep))
            }
            prevCurrentTime = ct
            prevEdgeTime = et
        }
        print(String(format: "  state=%@ isLive=%@ t=%.2fs edge=%.2fs",
                     "\(engine.state)", "\(engine.isLive)", engine.currentTime, engine.liveEdgeTime))
        // Print RSS sample every 30 s when --measure-rss is set.
        if measureRSS && (elapsed - lastRSSTick >= 30.0 || tick == ticks - 1) { // RSS sample every 30s
            let phys = physFootprintBytes()
            let res  = residentBytes()
            let physMB = phys >= 0 ? Double(phys) / 1_048_576.0 : -1
            let resMB  = res  >= 0 ? Double(res)  / 1_048_576.0 : -1
            print(String(format: "RSS_SAMPLE: elapsed=%.0fs  phys=%.1fMB  resident=%.1fMB",
                         elapsed, physMB, resMB))
            lastRSSTick = elapsed
        }
        if reportCacheBytes && (elapsed - lastCacheTick >= 60.0 || tick == ticks - 1) { // cache sample every 60s + final
            let bytes = engine.segmentCacheDiskBytes ?? 0
            print(String(format: "CACHE_BYTES: elapsed=%.0fs  disk=%lld B  disk=%.2f MB",
                         elapsed, bytes, Double(bytes) / 1_048_576.0))
            lastCacheTick = elapsed
        }
    }

    let finalState = engine.state
    let finalIsLive = engine.isLive
    let finalTime = engine.currentTime
    let finalEdge = engine.liveEdgeTime
    engine.stop()

    // Scale the advance target to the play window, with warm-up allowance for first-segment latency.
    let advanceTarget = playSeconds >= 20 ? 15.0 : max(1.0, playSeconds * 0.6)

    let playing: Bool
    if case .playing = finalState { playing = true } else { playing = false }

    // SW video-only path advances edge but not currentTime; take the max of both.
    let advanced = max(finalTime, finalEdge)

    if checkMonotonic && monotonicViolation {
        print(String(format: "VERDICT: live FAIL (monotonic violation across "
                     + "discontinuity; maxForwardStep=%.2fs, t=%.2fs, edge=%.2fs)",
                     maxForwardStep, finalTime, finalEdge))
        return 1
    }

    if finalIsLive, playing, advanced >= advanceTarget {
        let mono = checkMonotonic
            ? String(format: " monotonic OK maxStep=%.2fs", maxForwardStep)
            : ""
        print(String(format: "VERDICT: live playing (isLive=%@, state=%@, t=%.2fs, edge=%.2fs >= %.2fs)%@",
                     "\(finalIsLive)", "\(finalState)", finalTime, finalEdge, advanceTarget, mono))
        return 0
    }
    print(String(format: "VERDICT: live FAIL (isLive=%@, state=%@, t=%.2fs, edge=%.2fs, needed >=%.2fs)",
                 "\(finalIsLive)", "\(finalState)", finalTime, finalEdge, advanceTarget))
    return 1
}

/// macOS repro for the tvOS live-reload frozen-frame stall (background-return reloadAtCurrentPosition). Load the fixture (DVR 600s), play ~10s, reload, then verify the rejoined clock advances. FAIL = .error or clock frozen.
@MainActor
private func liveReloadTest(url: URL, seconds playSeconds: Double,
                            dvrWindow: Double) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: live-reload FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow

    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: live-reload FAIL: initial load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }

    let warmup = max(8.0, min(playSeconds, 20.0)) // warm up to match device repro's resumeAt=25s
    print(String(format: "  warmup %.0fs before reload ...", warmup))
    for i in 0..<Int(warmup) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if i % 4 == 0 {
            print(String(format: "    +%2ds state=%@ t=%.2f edge=%.2f",
                         i + 1, "\(engine.state)", engine.currentTime, engine.liveEdgeTime))
        }
    }
    let preReloadTime = engine.currentTime
    guard case .playing = engine.state else {
        print("VERDICT: live-reload FAIL: warmup never reached .playing (state=\(engine.state))")
        engine.stop()
        return 1
    }

    print(String(format: "  RELOAD at t=%.2fs (reloadAtCurrentPosition, live rejoin)", preReloadTime))
    do {
        try await engine.reloadAtCurrentPosition()
    } catch {
        print("VERDICT: live-reload FAIL: reload threw: \(error.localizedDescription)")
        engine.stop()
        return 1
    }

    // Verdict keys on clock movement, not state: the historical wedge showed .playing with AVPlayer clock frozen at 0.00. 25s gives the 10s readiness watchdog room to fire.
    var baseline: Double? = nil
    var advanced = false
    for i in 0..<25 {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let state = engine.state
        let t = engine.currentTime
        print(String(format: "    +%2ds state=%@ t=%.2f edge=%.2f behind=%.2f",
                     i + 1, "\(state)", t, engine.liveEdgeTime, engine.behindLiveSeconds))
        if case .error(let msg) = state {
            print("VERDICT: live-reload FAIL: rejoin errored: \(msg)")
            engine.stop()
            return 1
        }
        if case .playing = state {
            if baseline == nil { baseline = t } // first playing tick post-reload; movement judged relative to this
            if let b = baseline, t - b >= 3.0 {
                advanced = true
                break
            }
        }
    }

    let finalState = engine.state
    let finalTime = engine.currentTime
    engine.stop()

    if advanced {
        print(String(format: "VERDICT: live-reload OK (rejoined, state=%@, clock advanced to %.2fs)",
                     "\(finalState)", finalTime))
        return 0
    }
    print(String(format: "VERDICT: live-reload FAIL (state=%@, t=%.2fs, clock never advanced "
                 + ">=3s past the rejoin baseline %@, the frozen-frame wedge signature)",
                 "\(finalState)", finalTime,
                 baseline.map { String(format: "%.2fs", $0) } ?? "n/a"))
    return 1
}

/// Play ~40s with a DVR window, rewind 20s off the live edge, assert behindLiveSeconds ~= 20, return to edge, assert isAtLiveEdge. Prints per-step PASS/FAIL.
@MainActor
private func liveRewindTest(url: URL, seconds playSeconds: Double,
                            dvrWindow: Double) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: live FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow

    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: live FAIL: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }
    print(String(format: "  post-load state=%@ isLive=%@ dvrWindow=%.0fs t=%.2fs",
                 "\(engine.state)", "\(engine.isLive)", dvrWindow, engine.currentTime))

    // Warm up ~40s so the DVR window has enough history to rewind into.
    // Sample behindLiveSeconds every ~4s: on a 1x (--realtime) feed it should be stable and small, not the ~30-40s racing artifact an unpaced fixture produces.
    let warmup = max(playSeconds, 40.0)
    var normalBehindSamples: [Double] = []
    print("  NORMAL_PLAYBACK behindLiveSeconds series (every ~4s, 1x feed):")
    for i in 0..<Int(warmup) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if i % 4 == 0 || i == Int(warmup) - 1 {
            let b = engine.behindLiveSeconds
            normalBehindSamples.append(b)
            print(String(format: "    +%2ds  t=%.2f  edge=%.2f  behind=%.2f",
                         i + 1, engine.currentTime, engine.liveEdgeTime, b))
        }
    }
    // Skip the first sample (may be mid warm-up); a 1x feed holds behind in a narrow band.
    let settled = normalBehindSamples.count > 1 ? Array(normalBehindSamples.dropFirst()) : normalBehindSamples
    let normalMin = settled.min() ?? 0
    let normalMax = settled.max() ?? 0
    let normalSpread = normalMax - normalMin
    print(String(format: "  NORMAL_PLAYBACK behind: min=%.2f max=%.2f spread=%.2f (stable if spread small and max not ~30-40)",
                 normalMin, normalMax, normalSpread))
    print(String(format: "  pre-rewind edge=%.2fs t=%.2fs behind=%.2fs range=%@",
                 engine.liveEdgeTime, engine.currentTime, engine.behindLiveSeconds,
                 engine.seekableLiveRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil"))

    // Rewind 20s off the live edge. Post-seek invariant: behindLiveSeconds ~= 20 (absolute currentTime comparison is wrong; edge lurches in discrete segment steps).
    let edgeBefore = engine.liveEdgeTime
    let timeBefore = engine.currentTime
    await engine.seek(to: edgeBefore - 20)
    var behindSamples: [Double] = []
    var timeAfter = engine.currentTime
    for i in 0..<5 {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        timeAfter = engine.currentTime
        let b = engine.behindLiveSeconds
        behindSamples.append(b)
        print(String(format: "    +%ds t=%.2f edge=%.2f behind=%.2f", i + 1,
                     timeAfter, engine.liveEdgeTime, b))
    }
    let behindAfter = behindSamples.min() ?? engine.behindLiveSeconds // minimum is the true rewind depth (before edge lurch)
    let movedBack = timeAfter < edgeBefore
    let behindOK = abs(behindAfter - 20) <= 5
    let rewindPass = movedBack && behindOK
    print(String(format: "  REWIND: edgeBefore=%.2f tBefore=%.2f -> tAfter=%.2f settledBehind=%.2f (belowEdge=%@, behind~20=%@)",
                 edgeBefore, timeBefore, timeAfter, behindAfter,
                 "\(movedBack)", "\(behindOK)"))
    print("  REWIND: \(rewindPass ? "PASS" : "FAIL")")

    // --- Return to the live edge ---
    await engine.seekToLiveEdge()
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let atEdge = engine.isAtLiveEdge
    print(String(format: "  RETURN: behind=%.2fs isAtLiveEdge=%@",
                 engine.behindLiveSeconds, "\(atEdge)"))
    print("  RETURN: \(atEdge ? "PASS" : "FAIL")")

    engine.stop()

    // Normal-playback stability: spread <= 15s and max < 30s on a 1x feed. Folded into PASS/FAIL.
    let normalStable = normalSpread <= 15.0 && normalMax < 30.0
    print(String(format: "  NORMAL_STABLE: %@ (spread=%.2f max=%.2f)",
                 normalStable ? "PASS" : "FAIL", normalSpread, normalMax))

    if rewindPass && atEdge && normalStable {
        print("VERDICT: native DVR rewind+return OK; behind stable at 1x")
        return 0
    }
    print(String(format: "VERDICT: native DVR rewind+return FAIL (rewind=%@ return=%@ normalStable=%@)",
                 "\(rewindPass)", "\(atEdge)", "\(normalStable)"))
    return 1
}
