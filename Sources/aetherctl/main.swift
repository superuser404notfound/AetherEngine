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

// Subcommand path: explicit subcommand + flags + url.
if ["probe", "serve", "validate", "swdecode"].contains(first) {
    var rest = Array(args.dropFirst(2))
    let noDV = takeFlag("--no-dv", from: &rest)
    let framesOverride = takeIntFlag("--frames", from: &rest)
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
    default:
        printUsage()
        exit(64)
    }
}

// Bare URL: backwards-compatible `aetherctl <url>` == `aetherctl serve <url>`.
let url = parseSourceURL(first)
runServe(url: url, dvModeAvailable: true)
