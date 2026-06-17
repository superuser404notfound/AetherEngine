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

// MARK: - RSS / footprint samplers (keeper for regression tracking)

/// Physical footprint in bytes from task_vm_info. This is the
/// jetsam-relevant metric on tvOS: it counts compressed + uncompressed
/// memory the process actually occupies, unlike resident_size which
/// can include kernel-shared pages. Returns -1 on failure.
func physFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

/// Resident memory in bytes from mach_task_basic_info. Secondary
/// metric: includes kernel-shared pages, so it's noisier than
/// phys_footprint but historically what `ps RSS` reports.
func residentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size
    ) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.resident_size) : -1
}

// Disable stdout buffering so `swift run aetherctl ... > log.txt` or
// `2>&1 | grep` pipelines see engine prints in real time. Swift's
// `print()` block-buffers when stdout isn't a tty, which masked the
// engine's EngineLog output and only let FFmpeg's stderr through on
// the first run.
setbuf(stdout, nil)

// MARK: - Usage

func printUsage() {
    print("""
    aetherctl: standalone AetherEngine repro harness

    Usage:
      aetherctl probe <url>
      aetherctl serve [--no-dv] <url>
      aetherctl validate [--no-dv] <url>
      aetherctl swdecode [--frames N] <url>
      aetherctl extract [--at <sec>] [--snapshot] [--width <px>] [--loops <n>] <url>
      aetherctl audio [--seconds N] <url>
      aetherctl customio [--memory] [--forward-only] [--audio-only] [--reload] [--switch-audio] [--select-subs] [--extract] <file>
      aetherctl live [--seconds N] [--seed <path>] [--dvr-window N] [--serve-only] [--measure-rss] [--report-cache-bytes] [--rewind-test] [--reload-test] [--sw] [--drop-after N] [--discontinuity-at N] [--realtime] [--gen-highbitrate-seed]
      aetherctl dvr [--path native|sw|both] [--seconds N] [--dvr-window N]
      aetherctl dualsubs <file> --primary <streamIndex> --secondary <streamIndex> [--seek <seconds>]
      aetherctl hlsfixture <input.ts> [--port N] [--segment-seconds N]
                           [--master] [--discontinuity-at N] [--slow-refresh]
                           [--drop-segment N] [--encrypted] [--fmp4] [--self-test]
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

      live      Start a synthetic endless MPEG-TS source (LiveFixture,
                loopback HTTP, no Content-Length, monotonic PTS / PCR
                across loop boundaries), load it with
                LoadOptions(isLive: true), play for --seconds (default
                20), and report whether isLive is true, state is
                .playing, and currentTime advanced past ~15s. --seed
                overrides the seed .ts (default
                Fixtures/user/h264-ts-sample.ts). --dvr-window N sets
                LoadOptions.dvrWindowSeconds (the sliding-live window size);
                omit it for a live-only run bounded by the 60 s floor.
                --measure-rss prints phys_footprint + resident_size every
                30 s (spike measurement harness, kept for regression
                tracking). --report-cache-bytes prints the segment cache's
                on-disk footprint every 60 s to verify the live window keeps
                disk bounded. --sliding is accepted but ignored (sliding is
                now the unconditional behaviour for a live session).
    """)
}

// MARK: - URL parsing

private func parseSourceURL(_ raw: String) -> URL {
    if let parsed = URL(string: raw), parsed.scheme != nil {
        return parsed
    }
    return URL(fileURLWithPath: raw)
}

// MARK: - Shared async-bridge box

final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
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


// DVR matrix subcommand.
if first == "dvr" {
    var rest = Array(args.dropFirst(2))
    let path    = takeStringFlag("--path",       from: &rest) ?? "both"
    let seconds = takeDoubleFlag("--seconds",    from: &rest) ?? 120.0
    let dvrWin  = takeDoubleFlag("--dvr-window", from: &rest) ?? 60.0
    guard ["native", "sw", "both"].contains(path) else {
        print("ERROR: --path must be native, sw, or both (got '\(path)')")
        exit(64)
    }
    rejectStrayFlags(rest, subcommand: "dvr")
    exit(runDVR(path: path, seconds: seconds, dvrWindow: dvrWin))
}

// Rapid-seek burst repro (issue #35).
if first == "seektest" {
    var rest = Array(args.dropFirst(2))
    let seeks   = takeIntFlag("--seeks", from: &rest) ?? 40
    let gapMs   = takeIntFlag("--gap-ms", from: &rest) ?? 60
    let settle  = takeDoubleFlag("--settle", from: &rest) ?? 5.0
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: seektest requires a <url> argument")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "seektest")
    exit(runSeekTest(url: parseSourceURL(urlArg), seeks: seeks, gapMs: gapMs, settleSeconds: settle))
}

// SMB2/3 throughput + random-seek correctness harness.
if first == "smbtest" {
    var rest = Array(args.dropFirst(2))
    let reads = takeIntFlag("--reads", from: &rest) ?? 64
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: smbtest requires a <smb-url> argument")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "smbtest")
    exit(runSMBTest([urlArg, "--reads", "\(reads)"]))
}

// Dual subtitle channel harness (issue #47).
if first == "dualsubs" {
    var rest = Array(args.dropFirst(2))
    let primaryIndex   = takeIntFlag("--primary",   from: &rest)
    let secondaryIndex = takeIntFlag("--secondary", from: &rest)
    let seekTo         = takeDoubleFlag("--seek",   from: &rest)
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: dualsubs requires a <file> argument")
        print("Usage: aetherctl dualsubs <file> --primary <streamIndex> --secondary <streamIndex> [--seek <seconds>]")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    guard let primary = primaryIndex else {
        print("ERROR: dualsubs requires --primary <streamIndex>")
        print("Usage: aetherctl dualsubs <file> --primary <streamIndex> --secondary <streamIndex> [--seek <seconds>]")
        exit(64)
    }
    guard let secondary = secondaryIndex else {
        print("ERROR: dualsubs requires --secondary <streamIndex>")
        print("Usage: aetherctl dualsubs <file> --primary <streamIndex> --secondary <streamIndex> [--seek <seconds>]")
        exit(64)
    }
    rejectStrayFlags(rest, subcommand: "dualsubs")
    exit(runDualSubs(path: urlArg, primaryIndex: primary, secondaryIndex: secondary, seekTo: seekTo))
}

// HLS live fixture subcommand.
if first == "hlsfixture" {
    let rest = Array(args.dropFirst(2))
    exit(runHLSFixture(args: rest))
}

// SSAI repro: serve real content+ad .ts segments through the actual
// HLSLiveIngestReader → engine direct path.
if first == "hlslive" {
    let rest = Array(args.dropFirst(2))
    exit(runHLSLiveRepro(args: rest))
}

// Live subcommand: no URL positional (the fixture supplies its own URL).
if first == "live" {
    var rest = Array(args.dropFirst(2))
    let seconds = takeDoubleFlag("--seconds", from: &rest) ?? 20.0
    let dvrWindow = takeDoubleFlag("--dvr-window", from: &rest)
    let seed = takeStringFlag("--seed", from: &rest)
    let serveOnly = takeFlag("--serve-only", from: &rest)
    let measureRSS = takeFlag("--measure-rss", from: &rest)
    let reportCacheBytes = takeFlag("--report-cache-bytes", from: &rest)
    let rewindTest = takeFlag("--rewind-test", from: &rest)
    // --reload-test: warm up a live session, then exercise the live
    // REJOIN path (reloadAtCurrentPosition) and verdict on whether the
    // rejoined clock advances. Manual macOS repro for the tvOS
    // live-reload frozen-frame stall; see liveReloadTest in LiveCmd.
    let reloadTest = takeFlag("--reload-test", from: &rest)
    // --sw forces the live source through SoftwarePlaybackHost regardless
    // of codec (TEST-ONLY routing override). Lets the H.264 fixture
    // exercise the SW live + DVR path end-to-end.
    let forceSW = takeFlag("--sw", from: &rest)
    // --drop-after N: instruct LiveFixture to close the first client
    // connection after N seconds, simulating a single recoverable mid-stream
    // drop. AVIOReader should reconnect and playback should resume.
    let dropAfter = takeDoubleFlag("--drop-after", from: &rest)
    // --discontinuity-at N: after ~N seconds of serving, the fixture jumps
    // its rewritten PTS / PCR forward by a large delta ONCE, then continues
    // monotonically (simulating a program boundary). The engine must keep
    // playing and keep the session timeline monotonic.
    let discontinuityAt = takeDoubleFlag("--discontinuity-at", from: &rest)
    // --realtime paces the fixture output at ~1x wall-clock so the producer /
    // AVPlayer cannot race ahead of real time, matching a genuine live feed.
    // Default (absent): serve as fast as the socket drains (today's behaviour).
    let realtime = takeFlag("--realtime", from: &rest)
    // --gen-highbitrate-seed: ensure a ~22 Mbps 1080p H.264 MPEG-TS seed exists
    // in Fixtures/user/ (generating it with ffmpeg if absent) and exit. Used to
    // prep the RSS-retention measurement seed. Honours --seed for the path.
    if takeFlag("--gen-highbitrate-seed", from: &rest) {
        let path = seed ?? "Fixtures/user/highbitrate-1080p.ts"
        exit(ensureHighBitrateSeed(path: path) ? 0 : 1)
    }
    // --sliding is accepted-and-ignored for backward compat: sliding is now
    // the unconditional behaviour for a live session, so the flag is a no-op.
    _ = takeFlag("--sliding", from: &rest)
    rejectStrayFlags(rest, subcommand: "live")
    exit(runLive(seconds: seconds, seed: seed, dvrWindow: dvrWindow,
                 serveOnly: serveOnly, measureRSS: measureRSS,
                 reportCacheBytes: reportCacheBytes, rewindTest: rewindTest,
                 reloadTest: reloadTest,
                 forceSoftware: forceSW, dropAfter: dropAfter,
                 discontinuityAt: discontinuityAt, realtime: realtime))
}

// Subcommand path: explicit subcommand + flags + url.
if ["probe", "serve", "validate", "swdecode", "extract", "audio", "customio"].contains(first) {
    var rest = Array(args.dropFirst(2))
    let noDV = takeFlag("--no-dv", from: &rest)
    let framesOverride = takeIntFlag("--frames", from: &rest)
    let atSeconds = takeDoubleFlag("--at", from: &rest) ?? 60.0
    let extractLoops = takeIntFlag("--loops", from: &rest) ?? 1
    let extractWidth = takeIntFlag("--width", from: &rest) ?? 320
    let snapshotMode = takeFlag("--snapshot", from: &rest)
    let inMemory = takeFlag("--memory", from: &rest)
    let forwardOnly = takeFlag("--forward-only", from: &rest)
    let audioOnlyFlag = takeFlag("--audio-only", from: &rest)
    let reloadFlag = takeFlag("--reload", from: &rest)
    let switchAudioFlag = takeFlag("--switch-audio", from: &rest)
    let selectSubsFlag = takeFlag("--select-subs", from: &rest)
    let extractFlag = takeFlag("--extract", from: &rest)
    let audioSeconds = takeDoubleFlag("--seconds", from: &rest) ?? 10
    rejectStrayFlags(rest, subcommand: first)
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
        exit(runAudio(url: url, seconds: audioSeconds))
    case "customio":
        // urlArg is a filesystem path, not a URL; use rest.first directly.
        exit(runCustomIO(path: urlArg, inMemory: inMemory, forwardOnly: forwardOnly, audioOnly: audioOnlyFlag, reload: reloadFlag, switchAudio: switchAudioFlag, selectSubs: selectSubsFlag, extract: extractFlag))
    default:
        printUsage()
        exit(64)
    }
}

// Bare URL: backwards-compatible `aetherctl <url>` == `aetherctl serve <url>`.
let url = parseSourceURL(first)
runServe(url: url, dvModeAvailable: true)
