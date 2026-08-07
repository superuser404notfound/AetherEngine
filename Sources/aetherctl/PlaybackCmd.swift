import Foundation
import Combine
import CoreMedia
import AetherEngine

// MARK: - play

/// Full playback-session smoke test: load a URL exactly like a host app (VOD by
/// default, `--live` for the live path), autoplay, print 1 Hz transport telemetry,
/// and optionally activate an embedded subtitle track (`--subs <codec-or-lang>`)
/// and log every overlay cue that arrives. Repro harness for "loads but never
/// plays" reports and for live teletext end-to-end validation (#107).
func runPlay(url: URL, seconds: Double, live: Bool, nativeHLS: Bool = false, dvrWindow: Double?, subsPick: String?, hostCalls: [String], audioStats: Bool = false, seekEvery: Double? = nil, seekPattern: [Double] = [], startPosition: Double? = nil, mallocCensus: Bool = false, forceSoftware: Bool = false,
                    censusThresholdMB: Int? = nil, censusHz: Double? = nil, frameTimes: Bool = false,
                    sidecars: [ExternalSubtitleTrack] = []) -> Int32 {
    EngineLog.handler = { print($0) }
    if mallocCensus {
        AetherEngine.setLargeAllocationCensusEnabled(
            true,
            triggerThresholdMB: censusThresholdMB ?? 32,
            triggerPollHz: censusHz ?? 8)
    }
    if forceSoftware { AetherEngine.setForceSoftwarePathForTesting(true) }
    print("aetherctl play: \(url.absoluteString) (seconds=\(seconds) live=\(live) nativeHLS=\(nativeHLS) dvrWindow=\(dvrWindow.map { String($0) } ?? "nil") subs=\(subsPick ?? "off") hostCalls=\(hostCalls.isEmpty ? "none" : hostCalls.joined(separator: "+")) audioStats=\(audioStats) seekEvery=\(seekEvery.map { String($0) } ?? "off") seekPattern=\(seekPattern.isEmpty ? "off" : seekPattern.map { String($0) }.joined(separator: "/")) startPosition=\(startPosition.map { String($0) } ?? "0"))")
    print("")
    // CFRunLoopRun, not a blocking semaphore: AetherEngine is @MainActor, so parking the main thread would deadlock the executor.
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await playSmokeTest(url: url, seconds: seconds, live: live, nativeHLS: nativeHLS, dvrWindow: dvrWindow, subsPick: subsPick, hostCalls: hostCalls, audioStats: audioStats, seekEvery: seekEvery, seekPattern: seekPattern, startPosition: startPosition, frameTimes: frameTimes, sidecars: sidecars)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

/// #306: the network half of the 1 Hz snapshot, appended to the transport line. Every field is
/// omitted where the snapshot has none, so the software path's numbers can be read off a run instead
/// of inferred from a memprobe half a minute wide. `rx` is the reader's lifetime pull, `ahead` the
/// part of it the demuxer has not consumed, and `cushion` the decoded video queued past the clock.
@MainActor
private func networkTelemetryFragment(_ telemetry: LiveTelemetry?) -> String {
    guard let telemetry else { return "" }
    var out = ""
    if let mbps = telemetry.networkThroughputMbps { out += String(format: " net=%.2fMbps", mbps) }
    if let rx = telemetry.networkTransferredBytes { out += String(format: " rx=%.1fMB", Double(rx) / 1_048_576) }
    if let ahead = telemetry.readerWindowAheadBytes { out += String(format: " ahead=%.1fMB", Double(ahead) / 1_048_576) }
    if let cushion = telemetry.displayCushionSeconds { out += String(format: " cushion=%.2fs", cushion) }
    if let fwd = telemetry.forwardBufferSeconds { out += String(format: " fwd=%.1fs", fwd) }
    if let dropped = telemetry.droppedFrameCount { out += " drop=\(dropped)" }
    if let delay = telemetry.accumulatedFrameDelaySeconds { out += String(format: " delay=%.2fs", delay) }
    return out
}

/// #311: records the software path's per-frame reports, from the decode thread. Also checks the
/// API's own claim while it is at it: these arrive past the reorder buffer, so `ooo` (a report whose
/// presentation time precedes its predecessor within one generation) must stay 0 on real media.
final class FrameTimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var sinceTick = 0
    private var last: CMTime?
    private var lastInGeneration: CMTime?
    private var generation: UInt64 = 0
    private var generations: Set<UInt64> = []
    private var outOfOrder = 0

    func record(_ frame: SoftwareVideoFrameTime) {
        lock.lock()
        defer { lock.unlock() }
        total += 1
        sinceTick += 1
        generations.insert(frame.generation)
        if frame.generation != generation {
            generation = frame.generation
            lastInGeneration = nil
        }
        if let previous = lastInGeneration, CMTimeCompare(frame.presentation, previous) < 0 {
            outOfOrder += 1
        }
        lastInGeneration = frame.presentation
        last = frame.presentation
    }

    /// Frames since the previous call, and the state at this instant.
    func drainTick() -> (frames: Int, last: CMTime?, generation: UInt64, outOfOrder: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = sinceTick
        sinceTick = 0
        return (n, last, generation, outOfOrder)
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "frames=\(total) outOfOrder=\(outOfOrder) generations=\(generations.sorted())"
    }
}

/// Decoded-PCM continuity monitor fed by the engine audio tap (#95 infrastructure).
/// Tracks per-buffer source-PTS abutment (gap = next.start - prev.end) and the running
/// end-of-enqueued-audio position, so the telemetry loop can print the audio lead
/// (decoded-ahead-of-clock). A chopping report shows up as AGAP lines (decode-side holes)
/// or as the lead collapsing to ~0 (feeder starvation); a clean run shows neither.
@MainActor
private final class AudioContinuityMonitor {
    private(set) var bufferCount = 0
    private(set) var gapCount = 0
    private(set) var discontinuityCount = 0
    private(set) var maxGapMs = 0.0
    private(set) var lastEndPTS: Double?
    private var totalFrames = 0

    func consume(_ buf: AudioTapBuffer) {
        let start = buf.sourceTime
        let frames = Int(buf.buffer.frameLength)
        if let prevEnd = lastEndPTS {
            let gapMs = (start - prevEnd) * 1000
            if buf.discontinuity { discontinuityCount += 1 }
            if abs(gapMs) > 2.0 {
                gapCount += 1
                maxGapMs = max(maxGapMs, abs(gapMs))
                print(String(format: "  AGAP #%d at src=%.3f gap=%+.1fms frames=%d%@",
                             gapCount, start, gapMs, frames, buf.discontinuity ? " (disc)" : ""))
            }
        }
        lastEndPTS = start + Double(frames) / buf.buffer.format.sampleRate
        bufferCount += 1
        totalFrames += frames
    }

    var summary: String {
        String(format: "buffers=%d frames=%d gaps>2ms=%d maxGap=%.1fms discFlags=%d",
               bufferCount, totalFrames, gapCount, maxGapMs, discontinuityCount)
    }
}

/// #292 drill: issue a seek and make a transport call while its reposition is still in flight, then
/// report what the landing did with that intent.
///
/// The software and audio hosts park their loops for the duration of a seek by clearing `isPlaying`,
/// and since #254 the reposition that follows is awaited off the main actor, so a transport call
/// (another seek, `pause()`, `play()`) can land inside that window. `seektest` cannot reach any of
/// this: it awaits every seek, so its bursts are strictly serial.
///
/// `inWindow` is the precondition. Without it the call arrived after the landing and the run proves
/// nothing, so it reports INCONCLUSIVE rather than a green PASS.
///
/// Every drill opens by healing the session with the report's own manual workaround (pause + play)
/// and then settling into `startPlaying`, so a defect one drill provokes cannot be inherited by the
/// next: before the fix each of these leaves the session wedged, and drills run back to back on a
/// wedged session are unattributable.
@MainActor
private func seekIntentDrill(
    engine: AetherEngine,
    label: String,
    target: Double,
    startPlaying: Bool,
    expectPlaying: Bool,
    extraPrecondition: @MainActor () -> Bool = { true },
    duringReposition: @MainActor @escaping () async -> Void
) async -> String {
    engine.pause()
    engine.play()
    let healClock = engine.currentTime
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let healAdvance = engine.currentTime - healClock
    if healAdvance < 0.5 {
        return String(format: "INCONCLUSIVE %@: session did not play at drill start (%+.2fs in 1.5s)",
                      label, healAdvance)
    }
    if !startPlaying {
        engine.pause()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    print(String(format: "  #292 DRILL %@: from %@, seek(to: %.2f), transport call mid-reposition",
                 label, startPlaying ? "playing" : "paused", target))
    let seekTask = Task { @MainActor in await engine.seek(to: target) }
    await Task.yield()                                   // let the seek reach its off-main await
    try? await Task.sleep(nanoseconds: 2_000_000)
    let inWindow = engine.isSeeking
    await duringReposition()
    _ = await seekTask.value
    let stateAtLanding = engine.state
    let clockAtLanding = engine.currentTime
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let advanced = engine.currentTime - clockAtLanding
    let playing = advanced >= 1.0
    print(String(format: "    inWindow=%@ landed state=%@ clock=%.2f -> %.2f (%+.2fs in 3s)",
                 inWindow ? "yes" : "NO", String(describing: stateAtLanding),
                 clockAtLanding, engine.currentTime, advanced))
    guard inWindow, extraPrecondition() else {
        return "INCONCLUSIVE \(label): the transport call did not land inside the reposition window"
    }
    guard playing == expectPlaying else {
        return String(format: "FAIL %@: expected the landing to be %@, clock advanced %+.2fs",
                      label, expectPlaying ? "playing" : "paused", advanced)
    }
    guard (stateAtLanding == .playing) == expectPlaying else {
        return "FAIL \(label): engine reported \(stateAtLanding) over a host that landed "
            + (playing ? "playing" : "paused")
    }
    return "PASS \(label)"
}

@MainActor
private func playSmokeTest(url: URL, seconds: Double, live: Bool, nativeHLS: Bool = false, dvrWindow: Double?, subsPick: String?, hostCalls: [String], audioStats: Bool, seekEvery: Double? = nil, seekPattern: [Double] = [], startPosition: Double? = nil, frameTimes: Bool = false, sidecars: [ExternalSubtitleTrack] = []) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("engine init failed: \(error.localizedDescription)")
        return 1
    }

    var cancellables = Set<AnyCancellable>()
    var seenCueEnds: [Int: Double] = [:]
    var cueCount = 0
    engine.$subtitleCues.sink { cues in
        for cue in cues {
            if let prevEnd = seenCueEnds[cue.id] {
                if prevEnd != cue.endTime {
                    seenCueEnds[cue.id] = cue.endTime
                    print(String(format: "  TRIM #%d -> end=%.2f", cue.id, cue.endTime))
                }
                continue
            }
            seenCueEnds[cue.id] = cue.endTime
            cueCount += 1
            let body: String
            switch cue.body {
            case .text(let text): body = "'\(text.replacingOccurrences(of: "\n", with: " | "))'"
            case .richText(let runs):
                let flat = runs.map(\.text).joined().replacingOccurrences(of: "\n", with: " | ")
                let colours = runs.filter { $0.color != nil }.count
                body = "'\(flat)' [\(colours) colour run(s)]"
            case .image: body = "[bitmap]"
            }
            print(String(format: "  CUE #%d %.2f-%.2f %@", cue.id, cue.startTime, cue.endTime, body))
        }
    }.store(in: &cancellables)

    // #315: the cover-lift edge, stamped from the load call. Both transitions are printed: the
    // false is the load un-latching it, the true is the running path reporting a first frame ready
    // for display. Nothing here binds a render surface, so a true means the pipeline is ready, not
    // that anything is on screen (that distinction is the property's own documentation).
    let loadStart = DispatchTime.now()
    engine.$hasFirstFrameReadyForDisplay
        .dropFirst()
        .sink { ready in
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1e9
            print(String(format: "  FIRSTFRAME hasFirstFrameReadyForDisplay=%@ t+%.2fs",
                         ready ? "true" : "false", elapsed))
        }
        .store(in: &cancellables)

    let options = LoadOptions(
        suppressDisplayCriteria: true,
        isLive: live,
        dvrWindowSeconds: dvrWindow,
        nativeRemoteHLS: nativeHLS,
        externalSubtitles: sidecars
    )
    // #311: installed BEFORE the load on purpose. The engine holds it and arms the host it builds,
    // which is the documented usage and the part a host would otherwise have to re-do per load.
    let frameProbe = frameTimes ? FrameTimeProbe() : nil
    if let frameProbe {
        engine.setSoftwareVideoFrameTimeObserver { [weak frameProbe] frame in
            frameProbe?.record(frame)
        }
    }

    do {
        let probe = try await engine.load(url: url, startPosition: startPosition, options: options)
        // Mirror AetherPlayer's Open URL flow: a probe-flagged live source is reloaded
        // back-to-back on the live path (same engine instance, stopInternal in between).
        if hostCalls.contains("reloadlive"), let probe, probe.isLive, !engine.isLive {
            print("  HOSTCALL reload as live (probe.isLive)")
            var liveOptions = options
            liveOptions.isLive = true
            liveOptions.dvrWindowSeconds = 1800
            try await engine.load(url: url, options: liveOptions)
        }
    } catch {
        print("LOAD FAILED: \(error)")
        return 1
    }
    if !sidecars.isEmpty {
        // #316: what the declaration actually became. On the bypass an id in the external range means
        // the track survived the branch at all; whether it is ALSO a rendition is in the engine's own
        // "serving N external subtitle rendition(s)" line above.
        print("  SIDECARS declared=\(sidecars.count) -> tracks: "
              + engine.subtitleTracks.map { "#\($0.id) \($0.name)(\($0.language ?? "?"))" }
                .joined(separator: ", "))
    }
    // Mimic host-app post-load calls (AetherPlayer openInternal order) to reproduce
    // host-triggered transport races the bare harness would miss.
    var frameExtractor: FrameExtractor?
    for call in hostCalls {
        switch call {
        case "play":
            print("  HOSTCALL play()")
            engine.play()
        case "extractor":
            frameExtractor = engine.makeFrameExtractor()
            print("  HOSTCALL makeFrameExtractor() -> \(frameExtractor == nil ? "nil" : "instance")")
        case "setrate":
            print("  HOSTCALL setRate(1.0)")
            engine.setRate(1.0)
        case "reloadlive", "seekback", "overlapseek":
            break  // reloadlive handled at load time, seekback/overlapseek in the telemetry loop
        default:
            print("  HOSTCALL unknown '\(call)' (use play,extractor,setrate,reloadlive,seekback,overlapseek)")
        }
    }
    defer { if let frameExtractor { Task { await frameExtractor.shutdown() } } }

    var monitor: AudioContinuityMonitor?
    var tapTask: Task<Void, Never>?
    if audioStats {
        let mon = AudioContinuityMonitor()
        monitor = mon
        let stream = engine.installAudioTap()
        print("  AUDIOTAP installed (deliverySource=\(engine.audioTapHasDeliverySource))")
        tapTask = Task { @MainActor in
            for await buf in stream { mon.consume(buf) }
        }
    }

    print("")
    // #321: route, not just backend. `.native` covers both the loopback and the remote bypass, and an
    // internal reroute can have moved this run off the route the flags asked for.
    print("backend=\(engine.playbackBackend.rawValue) route=\(engine.videoRoute.rawValue) "
          + "duration=\(String(format: "%.1f", engine.duration))s isLive=\(engine.isLive)")
    if frameTimes {
        if let timebase = engine.softwarePresentationTimebase {
            print(String(format: "  timebase: present, time=%.3fs rate=%.2f", timebase.time.seconds, timebase.rate))
        } else {
            print("  timebase: nil (not the software path)")
        }
    }
    for track in engine.audioTracks {
        print("  audio    id=\(track.id) codec=\(track.codec) lang=\(track.language ?? "?") ch=\(track.channels)\(track.isDefault ? " default" : "")")
    }
    for track in engine.subtitleTracks {
        print("  subtitle id=\(track.id) codec=\(track.codec) lang=\(track.language ?? "?")\(track.isDefault ? " default" : "")")
    }
    print("")

    var subsSelected = false
    var seekPatternIndex = 0
    var seekLandings: [Double] = []

    // #292 drill state. `supersededSeeks` is the PRECONDITION: without an observed supersede the two
    // seeks never interleaved and the run proves nothing, so it reports INCONCLUSIVE rather than PASS.
    let supersededSeeks = UncheckedBox<Int>(0)
    var seekEventSub: AnyCancellable?
    if hostCalls.contains("overlapseek") {
        seekEventSub = engine.seekEvents.sink { event in
            if event.outcome == .superseded { supersededSeeks.value += 1 }
        }
    }
    defer { seekEventSub?.cancel() }
    var overlapVerdicts: [String] = []

    let ticks = max(1, Int(seconds))
    for tick in 1...ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var line = String(format: "  t=%02d state=%@ phase=%@ cur=%.2f src=%.2f buf=%.2f dur=%.1f",
                          tick,
                          String(describing: engine.state),
                          String(describing: engine.playbackPhase),
                          engine.currentTime,
                          engine.sourceTime,
                          engine.bufferedPosition,
                          engine.duration)
        line += " rfd=\(engine.hasFirstFrameReadyForDisplay ? "y" : "n")"
        if let monitor, let end = monitor.lastEndPTS {
            // Decoded-audio lead over the master clock (source axis). Near-zero = renderer starving.
            line += String(format: " alead=%.2f abufs=%d", end - engine.sourceTime, monitor.bufferCount)
        }
        line += networkTelemetryFragment(engine.liveTelemetry)
        if let frameProbe {
            let tick = frameProbe.drainTick()
            line += " ft=\(tick.frames)"
            if let last = tick.last { line += String(format: " ftLast=%.3fs", last.seconds) }
            line += " ftGen=\(tick.generation) ooo=\(tick.outOfOrder)"
            // The clock the frames are presented against, read through the public property. Its
            // proximity to ftLast is the point: one axis, no conversion between them.
            if let timebase = engine.softwarePresentationTimebase {
                line += String(format: " tb=%.3fs", timebase.time.seconds)
            }
        }
        print(line)
        // DVR-seek smoke: rewind 20 s mid-session, then live-edge return 15 s later, so the
        // telemetry shows whether the clock and the audio look-ahead recover from both.
        if hostCalls.contains("seekback"), tick == 15 {
            let target = max(0, engine.currentTime - 20)
            print(String(format: "  HOSTCALL seek(to: %.2f) (currentTime - 20)", target))
            await engine.seek(to: target)
        }
        if hostCalls.contains("seekback"), tick == 30 {
            print("  HOSTCALL seekToLiveEdge()")
            await engine.seekToLiveEdge()
        }
        // #292: three transport calls that can land inside a seek's reposition window. A is the
        // reported case (a scrub arriving as two same-target seeks, the second superseding the first);
        // B and C are its siblings, a pause and a play issued while the reposition is still running.
        if hostCalls.contains("overlapseek"), tick == 8 {
            let targetA = engine.duration * 0.25
            overlapVerdicts.append(await seekIntentDrill(
                engine: engine, label: "A superseded scrub while playing", target: targetA,
                startPlaying: true, expectPlaying: true,
                extraPrecondition: { supersededSeeks.value > 0 },
                duringReposition: { await engine.seek(to: targetA) }))

            let targetB = engine.duration * 0.45
            overlapVerdicts.append(await seekIntentDrill(
                engine: engine, label: "B pause during the reposition", target: targetB,
                startPlaying: true, expectPlaying: false,
                duringReposition: { engine.pause() }))
            // The report's manual workaround: play() after the landing must resume from the target.
            let clockBeforeResume = engine.currentTime
            engine.play()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let resumed = engine.currentTime - clockBeforeResume
            print(String(format: "    B resume: play() advanced the clock %+.2fs in 2s", resumed))
            if resumed < 0.5 { overlapVerdicts.append("FAIL B resume: play() did not restart the clock") }

            let targetC = engine.duration * 0.65
            overlapVerdicts.append(await seekIntentDrill(
                engine: engine, label: "C play during the reposition", target: targetC,
                startPlaying: false, expectPlaying: true,
                duringReposition: { engine.play() }))
        }
        // #220 repro affordance: a periodic short backward seek drives the subtitle drain
        // through .resetAndDecode and re-anchors the #151 forward prefetcher, the churn a
        // rebuffering remote source produces on its own. Steady-state runs cannot reach it.
        if let seekEvery, seekEvery > 0, tick > 10, Double(tick).truncatingRemainder(dividingBy: seekEvery) == 0 {
            // #240: `--seek-pattern` walks a list of absolute targets instead of the short
            // backward hop, because the two exercise different machinery. A 6 s rewind lands in
            // the segment cache and never restarts the producer; a far seek restarts it, and the
            // landing budget it then runs against is what the #240 report is about. The elapsed
            // time is printed per seek, which is the number under test.
            let target: Double
            if !seekPattern.isEmpty {
                target = seekPattern[seekPatternIndex % seekPattern.count]
                seekPatternIndex += 1
            } else {
                target = max(0, engine.currentTime - 6)
            }
            print(String(format: "  SEEKCHURN seek(to: %.2f)", target))
            let began = DispatchTime.now()
            await engine.seek(to: target)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e6
            seekLandings.append(ms)
            print(String(format: "  SEEKLANDED target=%.2f in %.0fms (clock=%.2f)",
                         target, ms, engine.currentTime))
        }
        // Give the session a few seconds to settle before activating subtitles,
        // mirroring a user picking a track from the menu.
        if let subsPick, !subsSelected, tick >= 5 {
            let match: TrackInfo?
            if let wanted = Int(subsPick) {
                match = engine.subtitleTracks.first { $0.id == wanted }
            } else {
                match = engine.subtitleTracks.first {
                    $0.codec.localizedCaseInsensitiveContains(subsPick)
                        || ($0.language?.localizedCaseInsensitiveContains(subsPick) ?? false)
                }
            }
            if let match {
                print("  SELECT subtitle id=\(match.id) codec=\(match.codec) lang=\(match.language ?? "?")")
                engine.selectSubtitleTrack(index: match.id)
                subsSelected = true
            } else if tick == 5 {
                print("  SELECT subtitle: no track matching '\(subsPick)' (have: \(engine.subtitleTracks.map(\.codec).joined(separator: ", ")))")
            }
        }
    }

    let finalTime = engine.currentTime
    let endState = engine.state
    // #316: the settled list, after any late rendition discovery. Read it rather than the load-time
    // one when the question is what a host's picker ends up showing.
    let finalSubtitleTracks = engine.subtitleTracks
    let finalActiveSubtitle = engine.activeSubtitleTrackIndex
    engine.stop()
    tapTask?.cancel()
    print("")
    print("=== PLAY RESULT ===")
    if !seekLandings.isEmpty {
        let sorted = seekLandings.sorted()
        print(String(format: "seek landings: n=%d min=%.0fms median=%.0fms max=%.0fms (%@)",
                     sorted.count, sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1],
                     sorted.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
    }
    if let monitor {
        print("audio continuity: \(monitor.summary)")
    }
    if let frameProbe {
        print("frame times: \(frameProbe.summary())")
    }
    if !finalSubtitleTracks.isEmpty {
        let listed = finalSubtitleTracks
            .map { "#\($0.id) \($0.name)(\($0.language ?? "?"))\($0.isExternal ? "*" : "")" }
            .joined(separator: ", ")
        print("subtitle tracks (* = external): \(listed)")
        print("active subtitle: \(finalActiveSubtitle.map(String.init) ?? "none")")
    }
    print("final t=\(String(format: "%.2f", finalTime))s state=\(String(describing: endState)) cues=\(cueCount)")
    if case .error(let message) = endState {
        print("VERDICT: session ended in error: \(message)")
        return 2
    }
    if hostCalls.contains("overlapseek") {
        print("#292 seek-window drills:")
        for verdict in overlapVerdicts { print("  \(verdict)") }
        if overlapVerdicts.isEmpty { print("  not run (session ended before tick 8)") }
        if overlapVerdicts.contains(where: { $0.hasPrefix("FAIL") }) {
            print("VERDICT: #292 reproduced (the seek window swallowed a transport call)")
            return 4
        }
        if overlapVerdicts.isEmpty || overlapVerdicts.contains(where: { $0.hasPrefix("INCONCLUSIVE") }) {
            print("VERDICT: #292 drill inconclusive; widen the reposition window (--throttle-kbps, remote source)")
            return 5
        }
    }
    if finalTime <= 3.0 {
        print("VERDICT: clock did not advance (t=\(String(format: "%.2f", finalTime))s); transport stalled after load")
        return 2
    }
    if subsPick != nil && !subsSelected {
        print("VERDICT: playback OK but requested subtitle track was never found")
        return 3
    }
    if subsPick != nil && cueCount == 0 {
        print("VERDICT: playback OK, subtitle track selected, but no cues arrived")
        return 3
    }
    print("VERDICT: OK")
    return 0
}
