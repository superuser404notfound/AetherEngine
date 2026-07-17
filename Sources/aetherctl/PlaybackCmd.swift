import Foundation
import Combine
import AetherEngine

// MARK: - play

/// Full playback-session smoke test: load a URL exactly like a host app (VOD by
/// default, `--live` for the live path), autoplay, print 1 Hz transport telemetry,
/// and optionally activate an embedded subtitle track (`--subs <codec-or-lang>`)
/// and log every overlay cue that arrives. Repro harness for "loads but never
/// plays" reports and for live teletext end-to-end validation (#107).
func runPlay(url: URL, seconds: Double, live: Bool, dvrWindow: Double?, subsPick: String?, hostCalls: [String], audioStats: Bool = false) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl play: \(url.absoluteString) (seconds=\(seconds) live=\(live) dvrWindow=\(dvrWindow.map { String($0) } ?? "nil") subs=\(subsPick ?? "off") hostCalls=\(hostCalls.isEmpty ? "none" : hostCalls.joined(separator: "+")) audioStats=\(audioStats))")
    print("")
    // CFRunLoopRun, not a blocking semaphore: AetherEngine is @MainActor, so parking the main thread would deadlock the executor.
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await playSmokeTest(url: url, seconds: seconds, live: live, dvrWindow: dvrWindow, subsPick: subsPick, hostCalls: hostCalls, audioStats: audioStats)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
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

@MainActor
private func playSmokeTest(url: URL, seconds: Double, live: Bool, dvrWindow: Double?, subsPick: String?, hostCalls: [String], audioStats: Bool) async -> Int32 {
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

    let options = LoadOptions(
        suppressDisplayCriteria: true,
        isLive: live,
        dvrWindowSeconds: dvrWindow
    )
    do {
        let probe = try await engine.load(url: url, options: options)
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
        case "reloadlive", "seekback":
            break  // reloadlive handled at load time, seekback in the telemetry loop
        default:
            print("  HOSTCALL unknown '\(call)' (use play,extractor,setrate,reloadlive,seekback)")
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
    print("backend=\(engine.playbackBackend.rawValue) duration=\(String(format: "%.1f", engine.duration))s isLive=\(engine.isLive)")
    for track in engine.audioTracks {
        print("  audio    id=\(track.id) codec=\(track.codec) lang=\(track.language ?? "?") ch=\(track.channels)\(track.isDefault ? " default" : "")")
    }
    for track in engine.subtitleTracks {
        print("  subtitle id=\(track.id) codec=\(track.codec) lang=\(track.language ?? "?")\(track.isDefault ? " default" : "")")
    }
    print("")

    var subsSelected = false
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
        if let monitor, let end = monitor.lastEndPTS {
            // Decoded-audio lead over the master clock (source axis). Near-zero = renderer starving.
            line += String(format: " alead=%.2f abufs=%d", end - engine.sourceTime, monitor.bufferCount)
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
        // Give the session a few seconds to settle before activating subtitles,
        // mirroring a user picking a track from the menu.
        if let subsPick, !subsSelected, tick >= 5 {
            let match = engine.subtitleTracks.first {
                $0.codec.localizedCaseInsensitiveContains(subsPick)
                    || ($0.language?.localizedCaseInsensitiveContains(subsPick) ?? false)
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
    engine.stop()
    tapTask?.cancel()
    print("")
    print("=== PLAY RESULT ===")
    if let monitor {
        print("audio continuity: \(monitor.summary)")
    }
    print("final t=\(String(format: "%.2f", finalTime))s state=\(String(describing: endState)) cues=\(cueCount)")
    if case .error(let message) = endState {
        print("VERDICT: session ended in error: \(message)")
        return 2
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
