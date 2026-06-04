// aetherctl: standalone reproduction harness for AetherEngine on macOS.
//
// Three subcommands, all operating on a media source URL (file:// or
// http(s)://):
//
//   probe <url>     - Open the demuxer, print container + stream
//                     metadata, exit. No HLS server, no decoders.
//
//   serve <url>     - Spin up HLSVideoEngine + loopback HLS-fMP4
//                     server, park the process so curl /
//                     mediastreamvalidator / mp4dump / ffprobe can
//                     poke at the manifests + segments. Same shape
//                     the tvOS app's native render path consumes.
//
//   validate <url>  - Same as `serve` for a few seconds, then run
//                     Apple's `mediastreamvalidator` against the
//                     loopback manifest and print the report. Tears
//                     down on completion.
//
// Backwards compatibility: `aetherctl <url>` with no subcommand is
// treated as `serve <url>`, since that was the only mode the CLI
// used to support.

import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AetherEngine

// Disable stdout buffering so `swift run aetherctl ... > log.txt` or
// `2>&1 | grep` pipelines see engine prints in real time. Swift's
// `print()` block-buffers when stdout isn't a tty, which masked the
// engine's EngineLog output and only let FFmpeg's stderr through on
// the first run.
setbuf(stdout, nil)

// MARK: - Usage

private func printUsage() {
    print("""
    aetherctl: standalone AetherEngine repro harness

    Usage:
      aetherctl probe <url>
      aetherctl serve [--no-dv] <url>
      aetherctl validate [--no-dv] <url>
      aetherctl swdecode [--frames N] <url>
      aetherctl extract [--at <sec>] [--snapshot] [--width <px>] [--loops <n>] <url>
      aetherctl audio <url>
      aetherctl <url>             (alias for `serve`)

    Flags (serve / validate only):
      --no-dv        Pin HLSVideoEngine to dvModeAvailable=false, i.e.
                     pretend the display can't render Dolby Vision.
                     Mirrors what AetherEngine.loadNative passes on a
                     non-DV TV / on macOS (where displayCapabilities
                     reports supportsDolbyVision=false anyway).

    Flags (swdecode only):
      --frames N     Max packets to read / frames to wait for.
                     Default 100.

    Flags (extract only):
      --at <sec>     Seek position in seconds (default 60.0).
      --snapshot     Frame-accurate decode at full resolution instead
                     of nearest-keyframe thumbnail.
      --width <px>   Max output width for thumbnail mode (default 320).
      --loops <n>    Repeat extraction N times, cycling through 8
                     positions. Useful with `leaks --atExit`.

    Subcommands:
      probe     Open the demuxer, dump format + streams + duration, exit.
                No HLS server is started. Fastest way to answer
                "what's in this file?".

      serve     Spin up the engine and park the loopback HLS-fMP4
                server. Prints the local URL it served. Use curl /
                mediastreamvalidator / mp4dump / ffprobe from another
                terminal:

                  curl -i  http://127.0.0.1:<port>/master.m3u8
                  curl -o  /tmp/init.mp4  http://127.0.0.1:<port>/init.mp4
                  curl -o  /tmp/seg0.mp4  http://127.0.0.1:<port>/seg0.mp4
                  mediastreamvalidator http://127.0.0.1:<port>/master.m3u8
                  mp4dump --verbosity 1 /tmp/init.mp4
                  ffprobe -v debug /tmp/seg0.mp4
                  open 'http://127.0.0.1:<port>/master.m3u8'

                Ctrl-C to tear down.

      validate  Spin up the engine, run Apple's `mediastreamvalidator`
                against the loopback manifest, print the report, tear
                down. Requires Xcode (xcrun) on the PATH.

      swdecode  Open SoftwareVideoDecoder for the source's video
                stream, feed packets, report counters + first-frame
                metadata. Tests the SW-pipeline path without needing
                a display layer. Use for AV1, VP9, MPEG-4 Part 2,
                MPEG-2, VC-1 sources.

      extract   Extract a still frame from a source. Thumbnail mode
                (default) seeks to the nearest keyframe and downscales
                to --width. Snapshot mode (--snapshot) decodes
                frame-accurately at full resolution. Use --loops N
                with `leaks --atExit` to detect memory leaks.
                Writes the first frame to /tmp/aetherctl-extract-<mode>.png.

      audio     Load a source through the engine's audio-only path
                (LoadOptions.audioOnly=true), play for ~10 seconds,
                print the synchronizer clock once a second, and report
                OK if the clock advanced or FAIL if it stayed silent.
                Smoke-tests the FFmpeg decode -> AVSampleBufferAudioRenderer
                pipeline end-to-end on macOS without a display layer.
    """)
}

// MARK: - URL parsing

private func parseSourceURL(_ raw: String) -> URL {
    if let parsed = URL(string: raw), parsed.scheme != nil {
        return parsed
    }
    return URL(fileURLWithPath: raw)
}

// MARK: - probe

private func runProbe(url: URL) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl probe: \(url.absoluteString)")
    print("")
    let probe: SourceProbe
    do {
        probe = try AetherEngine.probe(url: url)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    let duration = String(format: "%.3f", probe.durationSeconds)
    let res = probe.videoWidth > 0 ? "\(probe.videoWidth)x\(probe.videoHeight)" : "n/a"
    let rate = probe.videoFrameRate.map { String(format: "%.3f", $0) } ?? "n/a"
    let codec = probe.videoCodecName ?? "(unknown)"

    print("Duration:    \(duration)s")
    print("Video:       codec=\(codec) resolution=\(res) fps=\(rate)")
    print("  format:    \(probe.videoFormat)")
    if probe.isDolbyVision {
        print("  HDR/DV:    Dolby Vision signaled")
    }
    print("")

    if probe.audioTracks.isEmpty {
        print("Audio:       (none)")
    } else {
        print("Audio tracks:")
        for track in probe.audioTracks {
            let lang = track.language ?? "und"
            let atmos = track.isAtmos ? " [Atmos]" : ""
            let def = track.isDefault ? " (default)" : ""
            print("  [\(track.id)] codec=\(track.codec) channels=\(track.channels) lang=\(lang)\(atmos)\(def)")
            print("       title=\(track.name)")
        }
    }
    print("")

    if probe.subtitleTracks.isEmpty {
        print("Subtitles:   (none)")
    } else {
        print("Subtitle tracks:")
        for track in probe.subtitleTracks {
            let lang = track.language ?? "und"
            let def = track.isDefault ? " (default)" : ""
            print("  [\(track.id)] codec=\(track.codec) lang=\(lang)\(def)")
            print("       title=\(track.name)")
        }
    }
    return 0
}

// MARK: - serve

private func runServe(url: URL, dvModeAvailable: Bool) -> Never {
    // Mirror what the tvOS app does: route every engine log to stdout
    // instead of into a host overlay buffer, so the CLI session reads
    // linearly.
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    let flagSuffix = dvModeAvailable ? "" : " [--no-dv]"
    print("aetherctl serve: \(url.absoluteString)\(flagSuffix)")
    print("")

    let engine = HLSVideoEngine(
        url: url,
        dvModeAvailable: dvModeAvailable
    )
    let playbackURL: URL
    do {
        playbackURL = try engine.start()
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }

    print("")
    print("=== PLAYBACK URL ===")
    print(playbackURL.absoluteString)
    print("====================")
    print("")
    print("Engine is parked. Hit Ctrl-C to tear down.")
    print("")

    // Trap SIGINT to clean up so the next run can rebind the same
    // (ephemeral) port if needed and so the demuxer's HTTP session
    // doesn't leak.
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("")
        print("aetherctl: SIGINT, stopping engine")
        engine.stop()
        exit(0)
    }
    sigintSource.resume()

    RunLoop.main.run()
    exit(0)  // unreachable, RunLoop.main.run() never returns
}

// MARK: - validate

private func runValidate(url: URL, dvModeAvailable: Bool) -> Int32 {
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    let flagSuffix = dvModeAvailable ? "" : " [--no-dv]"
    print("aetherctl validate: \(url.absoluteString)\(flagSuffix)")
    print("")

    let engine = HLSVideoEngine(
        url: url,
        dvModeAvailable: dvModeAvailable
    )
    let playbackURL: URL
    do {
        playbackURL = try engine.start()
    } catch {
        print("ERROR: \(error)")
        return 1
    }
    defer { engine.stop() }

    print("")
    print("=== PLAYBACK URL ===")
    print(playbackURL.absoluteString)
    print("====================")
    print("")
    print("Running mediastreamvalidator...")
    print("")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["mediastreamvalidator", playbackURL.absoluteString]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
    } catch {
        print("ERROR: failed to launch xcrun mediastreamvalidator: \(error)")
        print("Hint: install Xcode + run `xcode-select --install`.")
        return 1
    }

    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
        print(text)
    }

    print("")
    print("mediastreamvalidator exit code: \(process.terminationStatus)")
    return process.terminationStatus
}

// MARK: - swdecode

private func runSWDecode(url: URL, maxPackets: Int) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl swdecode: \(url.absoluteString) (maxPackets=\(maxPackets))")
    print("")

    let result: SoftwareDecodeProbeResult
    do {
        result = try AetherEngine.swDecodeProbe(url: url, maxPackets: maxPackets)
    } catch {
        print("ERROR: \(error)")
        return 1
    }

    print("")
    print("=== SW DECODER RESULT ===")
    print("Codec:                \(result.codecName) (id=\(result.codecID))")
    print("Source resolution:    \(result.width)x\(result.height)")
    print("Decoder open:         \(result.openSucceeded ? "OK" : "FAILED")")
    if let err = result.openError {
        print("Open error:           \(err)")
    }
    print("Packets read:         \(result.packetsRead)")
    print("Packets fed (video):  \(result.packetsFedToDecoder)")
    print("Frames decoded:       \(result.framesDecoded)")
    if let fmt = result.firstFramePixelFormat {
        print("First frame pixfmt:   \(fmt)")
        print("First frame size:     \(result.firstFrameWidth)x\(result.firstFrameHeight)")
    } else {
        print("First frame:          (none decoded)")
    }
    if let err = result.firstError {
        print("First demux error:    \(err)")
    }
    print("=========================")
    print("")

    // Verdict
    if !result.openSucceeded {
        print("VERDICT: decoder open failed (libavcodec rejected the stream).")
        print("         Check FFmpegBuild --enable-decoder=\(result.codecName) +")
        print("         codec-private extradata in the source.")
        return 2
    }
    if result.framesDecoded == 0 {
        print("VERDICT: decoder opened but produced no frames from \(result.packetsFedToDecoder) packets.")
        print("         Suggests pixel-format conversion failure or no key-frame")
        print("         in the first \(result.packetsFedToDecoder) packets. Bump --frames")
        print("         if the source has a long GOP.")
        return 3
    }
    print("VERDICT: SW decode end-to-end healthy. \(result.framesDecoded) frames")
    print("         produced into \(result.firstFramePixelFormat ?? "?") pixel buffers.")
    print("         If real playback still hangs, the failure is downstream")
    print("         (SoftwarePlaybackHost frame-enqueue, AVSampleBufferDisplayLayer")
    print("         attach, audio-clock sync).")
    return 0
}

// MARK: - audio

/// Load a source through the engine's audio-only path and play it,
/// printing the synchronizer clock once a second. Confirms FFmpeg
/// decode -> AVSampleBufferAudioRenderer works end-to-end on macOS.
private func runAudio(url: URL, seconds playSeconds: Double) -> Int32 {
    print("aetherctl audio: \(url.absoluteString) (play \(playSeconds)s)")
    // AetherEngine is @MainActor, so it must be driven on the main thread
    // under a live run loop, NOT through the main-thread-blocking
    // `runBlocking` semaphore: that would deadlock the instant the engine
    // needs the main actor (the main thread would be parked on the
    // semaphore and could never service the MainActor executor). Running
    // CFRunLoopRun keeps the main actor executor AND the
    // Timer.publish(on: .main) clock mirror alive while the @MainActor
    // task drives playback, then the task stops the run loop when done.
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await audioSmokeTest(url: url, seconds: playSeconds)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func audioSmokeTest(url: URL, seconds playSeconds: Double) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("engine init failed: \(error.localizedDescription)")
        return 1
    }
    do {
        try await engine.load(url: url, options: LoadOptions(audioOnly: true))
    } catch {
        print("load failed: \(error.localizedDescription)")
        return 1
    }
    let backend = engine.playbackBackend
    print("backend=\(backend.rawValue) duration=\(String(format: "%.1f", engine.duration))s")
    guard backend == .audio else {
        print("FAIL: expected backend .audio, got \(backend.rawValue)")
        return 1
    }
    let duration = engine.duration
    let ticks = max(1, Int(playSeconds))
    for _ in 0..<ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        print(String(format: "  t=%.2fs", engine.currentTime))
    }
    let finalTime = engine.currentTime
    let endState = engine.state
    engine.stop()
    if finalTime <= 0.5 {
        print("FAIL: clock did not advance (t=\(finalTime)); decode or render path is silent")
        return 1
    }
    // If we stopped sampling well before the file's end, the engine MUST
    // still be playing. If it already reached .idle, the demuxer raced to
    // EOF and ended the track early (the missing-back-pressure regression).
    if duration > 0, playSeconds < duration - 1.0 {
        if case .playing = endState {
            // expected
        } else {
            print("FAIL: engine left .playing early (state=\(endState)) at t=\(String(format: "%.2f", finalTime))s of \(String(format: "%.1f", duration))s; demuxer raced to EOF")
            return 1
        }
    }
    print("OK: audio path advanced the clock to \(String(format: "%.2f", finalTime))s (state=\(endState), duration=\(String(format: "%.1f", duration))s)")
    return 0
}

// MARK: - extract

/// Drive an async actor call to completion from the synchronous CLI.
private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = UncheckedBox<T?>(nil)
    Task {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func writePNG(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

private func runExtract(url: URL, at seconds: Double, mode: FrameMode, loops: Int, maxWidth: Int) -> Int32 {
    EngineLog.handler = { print($0) }
    print("aetherctl extract: \(url.absoluteString) at=\(seconds)s mode=\(mode) loops=\(loops)")
    print("")

    let extractor = FrameExtractor(url: url, httpHeaders: [:])

    var produced = 0
    let start = Date()
    let effectiveLoops = max(1, loops)
    for i in 0..<effectiveLoops {
        // Cycle positions within a bounded in-range window so every
        // iteration really decodes (and short clips do not run past
        // EOF). 8 distinct 1 s buckets is enough to defeat trivial
        // cache short-circuiting, especially in snapshot mode where the
        // cache holds only 2 entries.
        let pos = seconds + Double(i % 8) * 1.0
        let image: CGImage? = runBlocking {
            switch mode {
            case .thumbnail: return await extractor.thumbnail(at: pos, maxWidth: maxWidth)
            case .snapshot:  return await extractor.snapshot(at: pos, maxSize: nil)
            }
        }
        if let image {
            produced += 1
            if i == 0 {
                let out = "/tmp/aetherctl-extract-\(mode).png"
                if writePNG(image, to: out) {
                    print("Wrote \(image.width)x\(image.height) -> \(out)")
                } else {
                    print("ERROR: could not write \(out)")
                }
            }
        } else {
            print("Frame \(i) [\(mode)] at \(pos)s: (nil)")
        }
    }
    let elapsed = Date().timeIntervalSince(start)

    // Deterministic teardown so a `leaks --atExit` run sees a fully
    // released context (no lingering demuxer / connection / FFmpeg alloc).
    runBlocking { await extractor.shutdown() }

    print("")
    print("=== EXTRACT RESULT ===")
    print("Frames produced:  \(produced)/\(effectiveLoops)")
    print("Elapsed:          \(String(format: "%.2f", elapsed))s")
    print("Avg per frame:    \(String(format: "%.1f", elapsed / Double(effectiveLoops) * 1000))ms")
    print("======================")
    return produced > 0 ? 0 : 1
}

// MARK: - Dispatch

let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(64)
}

let first = args[1]

if first == "--help" || first == "-h" || first == "help" {
    printUsage()
    exit(0)
}

/// Pluck a boolean flag out of the rest-args list, returning whether
/// it was present. Modifies `rest` in place. Unknown args stay in
/// `rest` so the URL positional ends up there.
private func takeFlag(_ name: String, from rest: inout [String]) -> Bool {
    guard let idx = rest.firstIndex(of: name) else { return false }
    rest.remove(at: idx)
    return true
}

/// Pluck a `--key value` pair out of the rest-args list, returning
/// the value as Int. Returns nil if absent or unparseable.
private func takeIntFlag(_ name: String, from rest: inout [String]) -> Int? {
    guard let idx = rest.firstIndex(of: name),
          idx + 1 < rest.count,
          let value = Int(rest[idx + 1]) else { return nil }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

/// Pluck a `--key value` pair out of the rest-args list, returning
/// the value as Double. Returns nil if absent or unparseable.
private func takeDoubleFlag(_ name: String, from rest: inout [String]) -> Double? {
    guard let idx = rest.firstIndex(of: name),
          idx + 1 < rest.count,
          let value = Double(rest[idx + 1]) else { return nil }
    rest.removeSubrange(idx...(idx + 1))
    return value
}

// Subcommand path: explicit subcommand + flags + url.
if ["probe", "serve", "validate", "swdecode", "extract", "audio"].contains(first) {
    var rest = Array(args.dropFirst(2))
    let noDV = takeFlag("--no-dv", from: &rest)
    let framesOverride = takeIntFlag("--frames", from: &rest)
    let atSeconds = takeDoubleFlag("--at", from: &rest) ?? 60.0
    let extractLoops = takeIntFlag("--loops", from: &rest) ?? 1
    let extractWidth = takeIntFlag("--width", from: &rest) ?? 320
    let snapshotMode = takeFlag("--snapshot", from: &rest)
    guard let urlArg = rest.first else {
        print("ERROR: \(first) requires a <url> argument")
        print("")
        printUsage()
        exit(64)
    }
    let url = parseSourceURL(urlArg)
    let dvModeAvailable = !noDV
    switch first {
    case "probe":
        exit(runProbe(url: url))
    case "serve":
        runServe(url: url, dvModeAvailable: dvModeAvailable)
    case "validate":
        exit(runValidate(url: url, dvModeAvailable: dvModeAvailable))
    case "swdecode":
        exit(runSWDecode(url: url, maxPackets: framesOverride ?? 100))
    case "extract":
        exit(runExtract(
            url: url,
            at: atSeconds,
            mode: snapshotMode ? .snapshot : .thumbnail,
            loops: extractLoops,
            maxWidth: extractWidth
        ))
    case "audio":
        exit(runAudio(url: url, seconds: 10))
    default:
        printUsage()
        exit(64)
    }
}

// Bare URL: backwards-compatible `aetherctl <url>` == `aetherctl serve <url>`.
let url = parseSourceURL(first)
runServe(url: url, dvModeAvailable: true)
