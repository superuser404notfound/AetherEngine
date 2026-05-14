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
      aetherctl serve <url>
      aetherctl validate <url>
      aetherctl <url>             (alias for `serve`)

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

private func runServe(url: URL) -> Never {
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

    print("aetherctl serve: \(url.absoluteString)")
    print("")

    let engine = HLSVideoEngine(url: url)
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

private func runValidate(url: URL) -> Int32 {
    EngineLog.handler = { line in
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withTime, .withFractionalSeconds]
        )
        print("[\(timestamp)] \(line)")
    }

    print("aetherctl validate: \(url.absoluteString)")
    print("")

    let engine = HLSVideoEngine(url: url)
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

// Subcommand path: explicit subcommand + url argument.
if ["probe", "serve", "validate"].contains(first) {
    guard args.count >= 3 else {
        print("ERROR: \(first) requires a <url> argument")
        print("")
        printUsage()
        exit(64)
    }
    let url = parseSourceURL(args[2])
    switch first {
    case "probe":
        exit(runProbe(url: url))
    case "serve":
        runServe(url: url)  // never returns
    case "validate":
        exit(runValidate(url: url))
    default:
        printUsage()
        exit(64)
    }
}

// Bare URL: backwards-compatible `aetherctl <url>` == `aetherctl serve <url>`.
let url = parseSourceURL(first)
runServe(url: url)
