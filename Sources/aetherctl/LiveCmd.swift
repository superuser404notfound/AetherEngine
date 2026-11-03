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
    liveCushion: Double? = nil,
    pacingPreroll: Double? = nil,
    pacingRate: Double? = nil,
    originLead: Double? = nil,
    freezeAfter: Double? = nil,
    unfreezeAfter: Double? = nil,
    rewindBeforeFreeze: Double? = nil,
    forceRecoveryReloadAt: Double? = nil,
    rewindHold: Double? = nil,
    blockingReload: Bool? = nil,
    liveOnly: Bool = false,
    forceMaster: Bool = false,
    startPosition: Double? = nil
) -> Int32 {
    // Relative timestamps make join latency (readyToPlay et al.) readable off the log (AE#195).
    let logEpoch = Date()
    EngineLog.handler = { print(String(format: "[+%6.2fs] ", Date().timeIntervalSince(logEpoch)) + $0) }

    // TEST-ONLY: force SoftwarePlaybackHost routing; cleared on exit to avoid in-process bleed.
    AetherEngine.setForceSoftwarePathForTesting(forceSoftware)
    // AE#454: the device's own manifest route, which no live leg had ever taken.
    AetherEngine.setForceMasterPlaylistForTesting(forceMaster)
    if forceMaster {
        print("aetherctl live: --force-master set, routing behind the master playlist")
    }
    if forceSoftware {
        print("aetherctl live: --sw set, forcing SoftwarePlaybackHost routing")
    }
    defer { AetherEngine.setForceSoftwarePathForTesting(false) }
    defer { AetherEngine.setForceMasterPlaylistForTesting(false) }

    let resolvedSeed = seedPath ?? "Fixtures/user/h264-ts-sample.ts" // relative to CWD under `swift run`
    print("aetherctl live: seed=\(resolvedSeed) seconds=\(playSeconds)" +
          (dvrWindow.map { " dvr-window=\($0)" } ?? " dvr-window=none (live-only floor)") +
          (dropAfter.map { " drop-after=\($0)s" } ?? "") +
          (freezeAfter.map { " freeze-after=\($0)s" } ?? "") +
          (unfreezeAfter.map { " unfreeze-after=\($0)s" } ?? "") +
          (rewindBeforeFreeze.map { " rewind-before-freeze=\($0)s" } ?? "") +
          (forceRecoveryReloadAt.map { " force-recovery-reload-at=\($0)s" } ?? "") +
          (rewindHold.map { " rewind-hold=\($0)s" } ?? "") +
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
    fixture.freezeAfterSeconds = freezeAfter
    fixture.unfreezeAfterSeconds = unfreezeAfter
    fixture.discontinuityAfterSeconds = discontinuityAt
    fixture.paced = realtime
    if realtime {
        print("aetherctl live: --realtime set, pacing fixture output at ~1x")
    }
    if let preroll = pacingPreroll {
        fixture.pacingPrerollSeconds = preroll
        print("aetherctl live: --preroll \(preroll)s (0 = strict-realtime origin, no backlog burst)")
    }
    if let lead = originLead {
        fixture.pacingLeadSeconds = lead
        print("aetherctl live: --origin-lead \(lead)s (the paced origin runs up to \(lead)s of media "
              + "ahead of the wall clock, which is the distance a raw live client reads behind it)")
    }
    if let rate = pacingRate {
        fixture.pacingRateMultiple = rate
        print("aetherctl live: --realtime-rate \(rate)x (origin keeps handing over "
              + "\(rate)x faster than the content happens, for the whole run)")
    }
    print("aetherctl live: LoadOptions.liveJoinProfile = \(fastZap ? ".fastZap (default)" : ".standard (--standard-join)")")

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
        if let behind = rewindHold {
            box.value = await liveRewindHoldTest(url: liveURL, seconds: playSeconds,
                                                 dvrWindow: dvrWindow ?? 60,
                                                 rewindBehind: behind)
            fixture.stop()
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        if let freezeAt = freezeAfter {
            box.value = await liveFreezeTest(url: liveURL, seconds: playSeconds,
                                             dvrWindow: dvrWindow ?? 1800,
                                             freezeAt: freezeAt,
                                             rewindBehind: rewindBeforeFreeze ?? 300,
                                             expectsRecovery: unfreezeAfter != nil,
                                             forceRecoveryReloadAt: forceRecoveryReloadAt,
                                             blockingReload: blockingReload,
                                             liveOnly: liveOnly,
                                             forceMaster: forceMaster)
            fixture.stop()
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        box.value = await liveSmokeTest(url: liveURL, seconds: playSeconds, fastZap: fastZap,
                                        liveCushion: liveCushion,
                                        dvrWindow: dvrWindow, measureRSS: measureRSS,
                                        reportCacheBytes: reportCacheBytes,
                                        checkMonotonic: discontinuityAt != nil,
                                        startPosition: startPosition)
        fixture.stop()
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func liveSmokeTest(url: URL, seconds playSeconds: Double,
                           fastZap: Bool = false,
                           liveCushion: Double? = nil,
                           dvrWindow: Double? = nil,
                           measureRSS: Bool = false,
                           reportCacheBytes: Bool = false,
                           checkMonotonic: Bool = false,
                           startPosition: Double? = nil) async -> Int32 {
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
    options.liveEdgeCushionSeconds = liveCushion

    // AE#195: load elapsed includes the startup-cushion gate, so this is the join-latency metric
    // a --realtime fixture A/Bs between profiles.
    let loadStartedAt = Date()
    do {
        // AE#509: a live join with a host-supplied resume anchor had no harness. The anchor a host
        // holds is on the PUBLISHED axis (the only one it is shown), the mount seek spends it on the
        // ITEM axis, and on a live source the two are `playlistShiftSeconds` apart.
        try await engine.load(url: url, startPosition: startPosition, options: options)
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
        var tickLine = String(format: "  state=%@ isLive=%@ t=%.2fs edge=%.2fs",
                              "\(engine.state)", "\(engine.isLive)", engine.currentTime, engine.liveEdgeTime)
        // AE#443: the two session totals a live reopen used to reset. `--drop-after` drives exactly that
        // recovery, so this is the run where they have to stay monotonic.
        if let telemetry = engine.liveTelemetry {
            tickLine += String(format: " origin=%.1fMB restarts=%d",
                               Double(telemetry.demuxerBytesFetched) / 1_048_576,
                               telemetry.producerRestartCount)
        }
        // AE#509: `t=` is the published clock, which carries the shift. `item=` is what AVPlayer
        // says about its own item, which is the field a reporter's dump prints. A session where
        // those two do not differ by the shift is a session where something put the item somewhere
        // it cannot reach, and that difference is invisible from either number alone.
        if let itemReading = await engine.nativeItemReading() {
            tickLine += String(format: " item=%.2fs ranges=%d status=%d",
                               itemReading.playhead, itemReading.loadedRangeCount, itemReading.status)
        }
        print(tickLine)
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

// MARK: - live freeze (AE#442)

/// Counts the recovery lines the freeze leg is about, so the verdict can name the path that ran
/// instead of leaving it to whoever reads the scrollback.
private final class FreezeRecoveryCounters: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var itemDeaths = 0
    private(set) var edgeRejoins = 0
    private(set) var keptPlace = 0
    private(set) var reopenAttempts = 0
    private(set) var fullReloads = 0
    private(set) var unsatisfiable = 0
    private(set) var segmentFetches = 0
    private(set) var lastSegmentFetched = -1
    private(set) var playlistPolls = 0
    private(set) var withdrewBlockingReload = false
    /// AE#446 round 3: the axis-free half of the verdict. A forward step in seconds cannot separate a
    /// lost position from a source discontinuity the session correctly folded (a reconnect that
    /// restarts the seed loop leaves a seam, and the playhead legitimately steps by it). Which
    /// SEGMENTS the consumer fetched is a statement about content, and it survives any axis.
    private(set) var fetchedBeforeSwap: Set<Int> = []
    private(set) var fetchedAfterSwap: Set<Int> = []
    private(set) var segmentDuration: Double = 0
    /// AE#446 round 3: the engine gave the source read up and handed the session to the host. That is
    /// the honest end of a long outage, so a run with no rejoin means two different things depending
    /// on WHEN it happened: after the runway ran out it is the documented ceiling, and while the
    /// closed window was still feeding the consumer it is the defect this round fixed.
    private(set) var handedToHost = false
    private(set) var handedWhileRunwayPlaying = false
    /// AE#446 round 7: whether the window was ever closed, and whether the source came back inside the
    /// close deadline. A run where the source went late and returned without an ENDLIST is not a run
    /// with a missing rejoin, it is a run with nothing to rejoin, and the leg used to fail it.
    private(set) var windowClosed = false
    private(set) var gapAbsorbed = false
    private var runwayEnded = false
    private var didSwap = false
    /// AE#454: the two stamps the hand-off is argued from. The rejoin names the place it is coming
    /// back to BEFORE it swaps, so everything the session reports between that line and the placement
    /// landing is a position nobody decided. A 1 Hz tick cannot see it; the reporter measured 140 to
    /// 220 ms in the field.
    private(set) var swapAt: Date?
    private(set) var heldPlace: Double?
    /// AE#454: the FIRST thing the fresh item asked for. A sampler can miss a 41 ms excursion; a
    /// request cannot be missed, and it is a statement about content rather than about an axis. A
    /// rejoin that comes back to the place it held asks for the segment the consumer was on; one that
    /// joins the edge first asks for the segment the window ends on, tens of indices up.
    private(set) var firstFetchAfterSwap: Int?
    /// AE#454: when the placement landed. The hand-off is exactly the interval between the swap and
    /// this; after it the session is playing on from where it was placed, and counting that as an
    /// excursion would call every healthy rejoin a flash.
    private(set) var placementLandedAt: Date?

    /// AE#446 round 3: segments the window listed, that the consumer had not reached, and that the
    /// rejoin then jumped over. nil when no rejoin happened.
    ///
    /// Measured against the LOWEST index fetched after the swap, not the highest. A fresh item probes
    /// its own live edge before the stashed seek lands (one fetch, tens of segments up), so the
    /// highest index says where the playlist ends rather than where the viewer resumed, and counting
    /// the holes below it invents a skip out of a run that ended.
    var segmentsSkippedAcrossSwap: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let last = fetchedBeforeSwap.max(), let resume = fetchedAfterSwap.min() else {
            return nil
        }
        return Swift.max(0, resume - (last + 1))
    }

    /// AE#446 round 3: how far BELOW the place it held the rejoin re-entered, in segments, against
    /// what a landing is entitled to re-fetch.
    ///
    /// A re-fetch is not a re-watch: AVPlayer buffers backward around any landing, by a fixed 6 to 8 s
    /// of content whatever the segment size, so the allowance is that lookback rounded up to whole
    /// segments plus the one the landing sits in, and it has to be computed from the cut size rather
    /// than fixed in seconds. Three 5 s segments below a landing is that buffering; ten 1.3 s segments
    /// is a viewer watching the same minute twice.
    var rejoinBacktrack: (segments: Int, allowance: Int, seconds: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let last = fetchedBeforeSwap.max(), let resume = fetchedAfterSwap.min(),
              segmentDuration > 0 else { return nil }
        let depth = Swift.max(0, (last + 1) - resume)
        let allowance = Int((8.0 / segmentDuration).rounded(.up)) + 1
        return (depth, allowance, Double(depth) * segmentDuration)
    }

    /// AE#446: the whole question after a source freeze is whether the CONSUMER keeps asking for the
    /// runway the cache already holds. Counted from the server's own arrival line, so a silent client
    /// and an unanswered request are different numbers rather than the same stall.
    func armPostFreeze() {
        lock.lock(); defer { lock.unlock() }
        segmentFetches = 0
        lastSegmentFetched = -1
        playlistPolls = 0
    }

    func note(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if line.contains("[HLSLocalServer] GET"), let r = line.range(of: "/seg"),
           let dot = line[r.upperBound...].firstIndex(of: "."),
           let idx = Int(line[r.upperBound..<dot]) {
            segmentFetches += 1
            lastSegmentFetched = max(lastSegmentFetched, idx)
            if didSwap {
                if firstFetchAfterSwap == nil { firstFetchAfterSwap = idx }
                fetchedAfterSwap.insert(idx)
            } else {
                fetchedBeforeSwap.insert(idx)
            }
        }
        // The swap is the moment the session goes back to being live; everything fetched from here on
        // is the rejoin's choice of where to come back.
        if line.contains("#446 the window ran out and the source is delivering again")
            || line.contains("nudge did not revive the consumer") {
            didSwap = true
            // AE#454: both rejoin lines end their position with the same clause, so one parser covers
            // the outage swap and the #65 reload. Stamped here rather than at the fetch, because the
            // hand-off starts when the item is replaced, not when the fresh one asks for something.
            if swapAt == nil, let marker = line.range(of: "s, the place it held"),
               let at = line[..<marker.lowerBound].range(of: "at ", options: .backwards),
               let held = Double(String(line[at.upperBound..<marker.lowerBound])) {
                swapAt = Date()
                heldPlace = held
            }
        }
        if line.contains("#446 the window ran out") { runwayEnded = true }
        if line.contains("serving the rest of the window as a finished asset") { windowClosed = true }
        if line.contains("#446 the source is cutting again and the window was never closed") {
            gapAbsorbed = true
        }
        if line.contains("requesting host retune") || line.contains("publishing liveSourceReset") {
            handedToHost = true
            if !runwayEnded { handedWhileRunwayPlaying = true }
        }
        // The cut size the run is actually producing, so a backtrack can be stated in seconds
        // rather than in segments (a segment count means nothing without it).
        if line.contains("finalized:"), let r = line.range(of: "dur="),
           let d = Double(line[r.upperBound...].prefix(while: { $0.isNumber || $0 == "." })), d > 0 {
            segmentDuration = d
        }
        if line.contains("[HLSLocalServer] GET"), line.contains("media.m3u8") { playlistPolls += 1 }
        if line.contains("#446 source stopped delivering") { withdrewBlockingReload = true }
        if line.contains("item death (failedToPlayToEndTime)") { itemDeaths += 1 }
        if line.contains("nudge did not revive the consumer") {
            if line.contains("the place it held") { keptPlace += 1 } else { edgeRejoins += 1 }
        }
        // The hand-off closes when the placement is settled, whichever way it settled: the correcting
        // seek landing, or the engine reading that the playlist had already done it.
        if didSwap, placementLandedAt == nil,
           line.contains("programmatic landed") || line.contains("#454 the playlist already placed") {
            placementLandedAt = Date()
        }
        if line.contains("live reopen attempt") { reopenAttempts += 1 }
        if line.contains("reload: stopInternal start") { fullReloads += 1 }
        if line.contains("blocking reload msn=") { unsatisfiable += 1 }
    }
}

/// AE#454: what the session REPORTED, sampled fast enough to see a hand-off.
///
/// The freeze leg's own loop ticks at 1 Hz, which is the cadence a rejoin's placement is decided and
/// landed inside of. The reporter measured the whole excursion at 140 to 220 ms, so a leg sampling
/// once a second can only ever find the session already settled and call the run healthy.
private final class HandoffSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [(at: Date, t: Double)] = []

    func add(at: Date, t: Double) {
        lock.lock(); defer { lock.unlock() }
        rows.append((at, t))
    }

    /// Everything reported in the `window` seconds after `start`, oldest first.
    func after(_ start: Date, window: Double) -> [(at: Date, t: Double)] {
        lock.lock(); defer { lock.unlock() }
        return rows.filter { $0.at >= start && $0.at.timeIntervalSince(start) <= window }
    }
}

/// AE#442 repro: rewind into the DVR window, then freeze the upstream (connection stays open, no
/// further bytes). The edge stops advancing, the local playlist server answers the blocking reloads
/// `503 unsatisfiable`, and the question this leg exists to settle is what happens to a playhead that
/// is minutes behind while its segment cache still holds every second ahead of it.
///
/// Two numbers carry the verdict: whether the playhead SNAPPED forward (the reported loss), and
/// whether the clock kept advancing afterwards (whether the cache runway was actually playable).
@MainActor
private func liveFreezeTest(url: URL, seconds playSeconds: Double, dvrWindow: Double,
                            freezeAt: Double, rewindBehind: Double,
                            expectsRecovery: Bool = false,
                            forceRecoveryReloadAt: Double? = nil,
                            blockingReload: Bool? = nil,
                            liveOnly: Bool = false,
                            forceMaster: Bool = false) async -> Int32 {
    let counters = FreezeRecoveryCounters()
    let prior = EngineLog.handler
    EngineLog.handler = { line in counters.note(line); prior?(line) }

    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: live-freeze FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    // AE#446 round 4: `--live-only` is the reported stack, a client whose rewind lives outside the
    // engine and which therefore loads with no DVR window at all. There is nothing to rewind into
    // here, so the timeshift the rejoin has to carry is the one the OUTAGE makes: the consumer plays
    // the closed window to its end while the source, once it returns, has moved a backlog ahead of it.
    options.dvrWindowSeconds = liveOnly ? nil : dvrWindow
    if liveOnly {
        print("  live-only: LoadOptions.dvrWindowSeconds = nil (the session advertises no rewind)")
    }
    // AE#454: the master route is the DEVICE default for a live session with any subtitle track (and
    // on tvOS for every HEVC one), and it is the route the harness never exercised: `useMaster=false`
    // on every live leg so far. Whether a client honours a media playlist's placement when it arrived
    // through a master is a different question from whether it honours one it fetched directly.
    options.prepareNativeSubtitles = forceMaster
    options.liveBlockingReload = blockingReload
    if let blockingReload {
        print("  blocking reload forced \(blockingReload ? "ON" : "OFF") for this leg")
    }
    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: live-freeze FAIL: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }

    // AE#454: 20 ms, for the whole run rather than only around the swap, because nothing announces a
    // hand-off early enough to arm a sampler at it. A MainActor property read is cheap next to the
    // engine's own work, and the rows are only read after the run.
    let handoff = HandoffSamples()
    let handoffSampler = Task { @MainActor in
        while !Task.isCancelled {
            handoff.add(at: Date(), t: engine.currentTime)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // The fixture arms its freeze from the moment its serve loop starts, which is the reader's
    // connect, not this clock. Same order of magnitude, and every printed tick carries both.
    let startTime = Date()
    let rewindAt = max(5.0, freezeAt - 12.0)
    var didRewind = false
    var behindAtFreeze: Double? = nil
    var playheadAtFreeze: Double? = nil
    var maxForwardSnap: Double = 0
    var advanceAfterFreeze: Double = 0
    var prevT = engine.currentTime
    var firstPostFreezeT: Double? = nil
    var lastT = engine.currentTime
    var didForceReload = false
    var playheadBeforeForcedReload: Double? = nil

    let ticks = max(1, Int(playSeconds))
    for _ in 0..<ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let elapsed = Date().timeIntervalSince(startTime)

        if !didRewind, liveOnly, elapsed >= rewindAt {
            didRewind = true
            print("  REWIND: skipped, this session advertises no rewind to seek into")
        }
        if !didRewind, elapsed >= rewindAt {
            didRewind = true
            let target = max(0, engine.liveEdgeTime - rewindBehind)
            print(String(format: "  REWIND: edge=%.2fs target=%.2fs (%.0fs behind)",
                         engine.liveEdgeTime, target, rewindBehind))
            await engine.seek(to: target)
            print(String(format: "  REWIND: landed t=%.2fs behind=%.2fs",
                         engine.currentTime, engine.liveEdgeTime - engine.currentTime))
            prevT = engine.currentTime
        }

        if !didForceReload, let forceAt = forceRecoveryReloadAt, elapsed >= forceAt {
            didForceReload = true
            playheadBeforeForcedReload = engine.currentTime
            print(String(format: "  FORCE: driving the #93/#65 stage-2 recovery reload at t=%.2fs "
                         + "(%.2fs behind the edge)",
                         engine.currentTime, engine.liveEdgeTime - engine.currentTime))
            engine.forceStalledConsumerReloadForTesting()
        }

        let t = engine.currentTime
        let edge = engine.liveEdgeTime
        if elapsed >= freezeAt {
            if behindAtFreeze == nil {
                behindAtFreeze = edge - t
                playheadAtFreeze = t
                counters.armPostFreeze()
                print(String(format: "  FREEZE: playhead=%.2fs edge=%.2fs behind=%.2fs runway=%.2fs", t, edge, edge - t,
                             (engine.seekableLiveRange?.upperBound ?? edge) - t))
            } else {
                if firstPostFreezeT == nil { firstPostFreezeT = t }
                // AE#520 round 2: this step is dominated by the FIXTURE on thaw, not by the session.
                // The paced origin gates on wall clock, so it hands over everything the freeze owed at
                // I/O speed the moment it thaws, and the client follows an edge that jumped. Measured
                // on one arm at two prerolls, same code: 28.98 s at `--preroll 30` and 58.98 s at 60,
                // which is enough to flip the no-rejoin verdict below. Compare arms at one preroll, and
                // read the step as a property of the origin unless the ARMS differ at the same one.
                maxForwardSnap = max(maxForwardSnap, t - prevT)
                advanceAfterFreeze = t - (firstPostFreezeT ?? t)
            }
        }
        prevT = t
        lastT = t

        let range = engine.seekableLiveRange.map {
            String(format: "%.1f...%.1f", $0.lowerBound, $0.upperBound)
        } ?? "nil"
        // AE#520 round 2: `t` is the published SESSION clock, which is item time plus the session's
        // shift, so it says nothing on its own about how long this consumer can keep playing. The
        // close decision spends the segments it has not fetched yet; what it can still play is those
        // PLUS what AVPlayer already holds, and only the item can report the second half.
        let item = await engine.nativeItemReading()
        let buffered = engine.liveTelemetry?.forwardBufferSeconds
        print(String(format: "  state=%@ t=%.2fs edge=%.2fs behind=%.2fs range=%@ deaths=%d rejoins=%d"
                     + " item=%@ buf=%@",
                     "\(engine.state)", t, edge, max(0, edge - t), range,
                     counters.itemDeaths, counters.edgeRejoins + counters.keptPlace,
                     item.map { String(format: "%.2fs", $0.playhead) } ?? "none",
                     buffered.map { String(format: "%.2fs", $0) } ?? "none"))
    }

    let finalState = engine.state
    handoffSampler.cancel()
    engine.stop()
    EngineLog.handler = prior

    print("")
    print("=== AE#442 FREEZE LEG ===")
    print(String(format: "  playhead at freeze:   %.2fs (%.2fs behind the edge)",
                 playheadAtFreeze ?? -1, behindAtFreeze ?? -1))
    print(String(format: "  playhead at the end:  %.2fs", lastT))
    print(String(format: "  largest forward step: %.2fs", maxForwardSnap))
    print(String(format: "  advance after freeze: %.2fs", advanceAfterFreeze))
    if let before = playheadBeforeForcedReload {
        print(String(format: "  forced recovery reload: playhead %.2fs before", before))
    }
    print("  after the freeze: segment fetches=\(counters.segmentFetches) "
          + "(last seg\(counters.lastSegmentFetched)) playlist polls=\(counters.playlistPolls) "
          + "blocking-reload withdrawn=\(counters.withdrewBlockingReload)")
    let skipped = counters.segmentsSkippedAcrossSwap
    let backtrack = counters.rejoinBacktrack
    if let last = counters.fetchedBeforeSwap.max(), !counters.fetchedAfterSwap.isEmpty {
        print("  across the swap: consumed through seg\(last), resumed into seg"
              + counters.fetchedAfterSwap.sorted().map(String.init).prefix(4).joined(separator: ",")
              + ", never fetched \(skipped ?? 0) segment(s) in between"
              + (backtrack.map {
                    String(format: ", re-fetched %d segment(s) below it (%.1fs, lookback allows %d)",
                           $0.segments, $0.seconds, $0.allowance)
                 } ?? ""))
    }
    // AE#454: the hand-off, in the terms the viewer experiences it. The rejoin names the place it is
    // coming back to before it swaps, so every position the session reports between that line and the
    // placement landing is one nobody decided: the fresh item's own join (above the held place) and,
    // while its axis is still unmeasured, the retired item's zero (below it).
    var handoffFlash: (above: Double, below: Double, spanMS: Int)? = nil
    var handoffJoinedElsewhere: (first: Int, lastBefore: Int)? = nil
    if let swapAt = counters.swapAt, let held = counters.heldPlace {
        // The excursion, not the window it happens in. A fixed window after the swap also contains
        // the session playing on legitimately from the place it landed, and counting that as a
        // departure would call every healthy rejoin a flash. So: the first sample that LEAVES the
        // held place, through the first one that comes back to it.
        let tolerance = Swift.max(1.0, counters.segmentDuration * 0.5)
        // The hand-off, bounded at both ends by events rather than by a guessed duration: it opens at
        // the swap and closes when the placement lands. A fixed window would either miss a slow
        // landing or count the session playing on afterwards.
        let handoffSeconds = counters.placementLandedAt.map { $0.timeIntervalSince(swapAt) } ?? 1.5
        let rows = handoff.after(swapAt, window: handoffSeconds)
        let departure = rows.firstIndex { abs($0.t - held) > tolerance }
        print("")
        print("=== AE#454 HAND-OFF ===")
        print(String(format: "  the place it held:    %.2fs (tolerance %.2fs)", held, tolerance))
        print(String(format: "  hand-off lasted:      %dms (swap to placement landing)",
                     Int(handoffSeconds * 1000)))
        if let departure {
            let tail = rows[departure...]
            let back = tail.firstIndex { abs($0.t - held) <= tolerance }
            let excursion = Array(rows[departure..<(back ?? rows.endIndex)])
            let highest = excursion.map(\.t).max() ?? held
            let lowest = excursion.map(\.t).min() ?? held
            var spanMS = 0
            if let first = excursion.first, let last = excursion.last {
                spanMS = Int(last.at.timeIntervalSince(first.at) * 1000) + 20
            }
            print(String(format: "  left it for:          %.2fs .. %.2fs over %dms (%d sample(s) at 20ms)",
                         lowest, highest, spanMS, excursion.count))
            print(String(format: "  above / below:        %.2fs / %.2fs",
                         Swift.max(0, highest - held), Swift.max(0, held - lowest)))
            print("  came back to it:      " + (back == nil ? "not within 6s" : "yes"))
            handoffFlash = (Swift.max(0, highest - held), Swift.max(0, held - lowest), spanMS)
        } else {
            print("  left it:              never (\(rows.count) sample(s) at 20ms)")
        }
        if let first = counters.firstFetchAfterSwap, let lastBefore = counters.fetchedBeforeSwap.max() {
            let joinedElsewhere = first > lastBefore + 1
            print("  fresh item asked for: seg\(first) first (the consumer had consumed through "
                  + "seg\(lastBefore))"
                  + (joinedElsewhere ? "  <- joined its own edge before it was told where to go" : ""))
            if joinedElsewhere { handoffJoinedElsewhere = (first, lastBefore) }
        }
    }

    print("  recovery lines: itemDeath=\(counters.itemDeaths) edgeRejoin=\(counters.edgeRejoins) "
          + "keptPlace=\(counters.keptPlace) "
          + "reopen=\(counters.reopenAttempts) fullReload=\(counters.fullReloads) "
          + "unsatisfiable503=\(counters.unsatisfiable)")
    print("  final state: \(finalState)")

    // The reported defect, in the terms the content is in: segments the window listed, that the
    // consumer had not reached, and that the rejoin then jumped over. A forward step in seconds is
    // printed alongside but does not decide: a fixture reconnect that restarts its seed loop leaves a
    // real source seam, and a playhead legitimately steps by it without skipping a single segment.
    // AE#446 round 3: a source that comes back and is never noticed is the failure this leg could
    // not see. It read as healthy on every seconds-based number (the playhead had not moved, so it
    // had not moved WRONG) while the session sat on its last frame for the rest of the run, because
    // the no-cut watchdog had abandoned the read the recovery was waiting on 35 s in.
    // AE#446 round 7: the source went late and came back before the window's close deadline. Nothing
    // was committed, so there is nothing to rejoin and the item that was playing is still playing; the
    // position checks below decide the run exactly as they do for any other.
    let absorbedGap = counters.gapAbsorbed && !counters.windowClosed
    if absorbedGap {
        print("  the gap was absorbed: the source came back inside the close deadline, the window was "
              + "never closed as a finished asset, and no item was swapped")
    }
    if expectsRecovery, counters.fetchedAfterSwap.isEmpty, !absorbedGap {
        if counters.handedWhileRunwayPlaying {
            print("VERDICT: live-freeze NO REJOIN (the source read was given up while the closed "
                  + "window was still feeding the consumer, so the source coming back was never "
                  + "seen; final state \(finalState))")
            return 1
        }
        if counters.handedToHost {
            // The ceiling, not a defect: the outage outlived the runway and the hold budget, so the
            // engine handed the session over. aetherctl subscribes no retune, which is why the run
            // ends here rather than on a fresh tune.
            print("VERDICT: live-freeze handed to the host after the runway ran out "
                  + "(no in-CLI retune handler; final state \(finalState))")
            return 0
        }
        print("VERDICT: live-freeze NO REJOIN (the source delivered again and the session never "
              + "went live; final state \(finalState))")
        return 1
    }
    if let skipped, skipped > 0 {
        print("VERDICT: live-freeze POSITION LOST (\(skipped) segment(s) skipped across the rejoin)")
        return 1
    }
    // The other direction, and the one a seconds-only verdict reads as healthy: the rejoin lands
    // BELOW the place it held and the viewer re-watches. Bounded by what AVPlayer buffers backward
    // around any landing, which is content and therefore scales with the cut size.
    if let backtrack, backtrack.segments > backtrack.allowance {
        print(String(format: "VERDICT: live-freeze POSITION LOST (re-entered %d segments / %.1fs of "
                     + "already-played content, past the %d the landing's lookback explains)",
                     backtrack.segments, backtrack.seconds, backtrack.allowance))
        return 1
    }
    // No swap in the run at all (no thaw, or the runway outlived it): fall back to the step, which is
    // all there is to read when nothing rejoined.
    if counters.fetchedAfterSwap.isEmpty, maxForwardSnap > 30.0 {
        print(String(format: "VERDICT: live-freeze POSITION LOST (forward step %.2fs, no rejoin in this run)",
                     maxForwardSnap))
        return 1
    }
    // AE#454: a rejoin that LANDS on the place it held and RENDERS somewhere else on the way there is
    // not a held position, it is a held position the viewer never saw. The tolerance is one segment,
    // which is the smallest excursion the content itself can explain.
    if let joined = handoffJoinedElsewhere {
        print("VERDICT: live-freeze HAND-OFF JOINED ELSEWHERE (the fresh item's first request was "
              + "seg\(joined.first), \(joined.first - joined.lastBefore) segment(s) above the "
              + "seg\(joined.lastBefore) the consumer had reached, before the placement landed)")
        return 1
    }
    if let flash = handoffFlash, max(flash.above, flash.below) > max(1.0, counters.segmentDuration) {
        print(String(format: "VERDICT: live-freeze HAND-OFF FLASHED (%.2fs above / %.2fs below the place "
                     + "it held, for %dms, before the placement landed)",
                     flash.above, flash.below, flash.spanMS))
        return 1
    }
    if absorbedGap {
        print(String(format: "VERDICT: live-freeze gap absorbed (no ENDLIST, no swap; largest step "
                     + "%.2fs, advanced %.2fs after the freeze)", maxForwardSnap, advanceAfterFreeze))
        return 0
    }
    print(String(format: "VERDICT: live-freeze position held (largest step %.2fs, advanced %.2fs after the freeze)",
                 maxForwardSnap, advanceAfterFreeze))
    return 0
}

/// AE#441 follow-up: park the playhead just above the resident floor and HOLD there, which is the one
/// live regime the harness could not drive (`--freeze-after` kills the source, `--rewind-test` samples
/// five seconds). The retest reported the advertised `lowerBound` sitting a few seconds ABOVE the
/// rendered playhead for minutes on end while playback stayed clean, and asked whether that inversion
/// is the bound doing its job or the bound outrunning the reader.
///
/// The two are separable, and only one of them is a defect. `residentFloorOutputSeconds()` walks what
/// is on DISK; `notePlayhead` records what is RENDERED, and everything between them was already handed
/// to AVPlayer through the segment-serve path. The malign version is the window overtaking the
/// consumer's FETCH point, which `noteWindowSlideRelativeToConsumer` already names and latches. So this
/// leg samples the inversion and counts that line.
@MainActor
private func liveRewindHoldTest(url: URL, seconds playSeconds: Double, dvrWindow: Double,
                                rewindBehind: Double) async -> Int32 {
    let slides = SlideCounter()
    let prior = EngineLog.handler
    EngineLog.handler = { line in slides.note(line); prior?(line) }
    defer { EngineLog.handler = prior }

    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: live-rewind-hold FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow
    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: live-rewind-hold FAIL: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }

    // Fill the window before rewinding, and fill it PAST full. A floor below a window that has not
    // filled yet is the session's own start, which never moves, so a park against it measures a
    // regime that has no eviction in it at all. The first version of this leg filled `window * 0.6`
    // and therefore reported a clean bill of health for a regime it could not reach.
    let fillFor = dvrWindow + 12.0
    print(String(format: "  FILL: %.0fs before the rewind (window=%.0fs, filled past full)",
                 fillFor, dvrWindow))
    if playSeconds < fillFor + 30.0 {
        print(String(format: "  WARNING: --seconds %.0f leaves %.0fs of hold after a %.0fs fill; "
                     + "the window will not be sliding for long enough to read anything",
                     playSeconds, playSeconds - fillFor, fillFor))
    }
    let startTime = Date()
    while Date().timeIntervalSince(startTime) < fillFor {
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    let target = max(0, engine.liveEdgeTime - rewindBehind)
    print(String(format: "  REWIND: edge=%.2fs target=%.2fs (%.0fs behind)",
                 engine.liveEdgeTime, target, rewindBehind))
    await engine.seek(to: target)
    print(String(format: "  REWIND: landed t=%.2fs behind=%.2fs range=%@",
                 engine.currentTime, engine.liveEdgeTime - engine.currentTime,
                 engine.seekableLiveRange.map { String(format: "%.2f...%.2f", $0.lowerBound, $0.upperBound) } ?? "nil"))

    var maxInversion: Double = 0
    var invertedTicks = 0
    var stalledTicks = 0
    var prevT = engine.currentTime
    let holdTicks = max(1, Int(playSeconds - fillFor))
    for _ in 0..<holdTicks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let t = engine.currentTime
        let edge = engine.liveEdgeTime
        let range = engine.seekableLiveRange
        let floor = range?.lowerBound ?? 0
        let inversion = floor - t
        if inversion > 0.05 { invertedTicks += 1; maxInversion = max(maxInversion, inversion) }
        if t <= prevT + 0.05 { stalledTicks += 1 }
        prevT = t
        print(String(format: "  t=%.2fs edge=%.2fs behind=%.2fs floor=%.2fs floor-t=%+.2fs buffered=%.2fs",
                     t, edge, max(0, edge - t), floor, inversion, engine.bufferedPosition))
    }

    let finalState = engine.state
    engine.stop()
    EngineLog.handler = prior

    print("")
    print("=== AE#441 REWIND-HOLD LEG ===")
    print(String(format: "  ticks with floor above the playhead: %d/%d (max %.2fs)",
                 invertedTicks, holdTicks, maxInversion))
    print(String(format: "  ticks where the clock did not advance: %d/%d", stalledTicks, holdTicks))
    print("  'live window slid past the consumer': \(slides.count)"
          + (slides.count > 0
             ? " (max firstVisible-consumerTarget gap \(slides.maxGap), \(slides.gapsAboveOne) above one segment)"
             : ""))
    print("  final state: \(finalState)")

    // The inversion alone is not the defect; the window passing the consumer's FETCH point is.
    if slides.count > 0 {
        print("VERDICT: live-rewind-hold WINDOW PASSED THE CONSUMER (\(slides.count) latched line(s))")
        return 1
    }
    print(String(format: "VERDICT: live-rewind-hold reader stayed above the floor "
                 + "(max inversion %.2fs, %d stalled tick(s))", maxInversion, stalledTicks))
    return 0
}

/// Counts the latched slide line AND reads its shape. The gap `firstVisible - consumerTarget` is the
/// whole reading: a gap of 1 means the consumer's next fetch is the new first visible segment, which
/// is still resident, while a gap above 1 means the segment it will ask for next is already deleted.
private final class SlideCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var maxGap = 0
    private(set) var gapsAboveOne = 0
    func note(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard line.contains("live window slid past the consumer") else { return }
        count += 1
        guard let first = Self.intField("firstVisible=", in: line),
              let target = Self.intField("consumerTarget=", in: line) else { return }
        let gap = first - target
        maxGap = max(maxGap, gap)
        if gap > 1 { gapsAboveOne += 1 }
    }
    private static func intField(_ key: String, in line: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        let rest = line[r.upperBound...].prefix { $0 == "-" || $0.isNumber }
        return Int(rest)
    }
}
