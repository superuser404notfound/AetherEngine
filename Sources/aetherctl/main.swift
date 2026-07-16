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

/// Physical footprint in bytes (task_vm_info). Jetsam-relevant on tvOS; excludes kernel-shared pages unlike resident_size. Returns -1 on failure.
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

/// Resident memory in bytes (mach_task_basic_info). Includes kernel-shared pages; noisier than phys_footprint. Matches `ps RSS`.
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

// Disable stdout buffering so pipe/redirect pipelines see engine prints in real time (Swift print() block-buffers when stdout is not a tty).
setbuf(stdout, nil)

// MARK: - Usage

func printUsage() {
    print("""
    aetherctl: standalone AetherEngine repro harness

    Usage:
      aetherctl probe <url>
      aetherctl serve [--no-dv] [--start-position S] <url>
      aetherctl validate [--no-dv] <url>
      aetherctl swdecode [--frames N] <url>
      aetherctl play [--seconds N] [--live] [--dvr-window N] [--subs <codec-or-lang>]
                     [--audio-stats] [--host-calls play,extractor,setrate,reloadlive,seekback] <url>
                     (full load+play session smoke test; --subs activates the first
                      matching embedded subtitle track and logs overlay cues;
                      --audio-stats taps decoded PCM and prints per-second audio lead
                      plus PTS-continuity gaps; seekback rewinds 20 s at t=15 and
                      returns to the live edge at t=30)
      aetherctl segverify [--from N] [--count K] [--no-dv] [--dump <dir>] <url>
                          (#92: SW-decode each segment in isolation; framesDecoded==0 => not independent)
      aetherctl disc-inspect <disc.iso>
      aetherctl dovitest <file>
      aetherctl extract [--at <sec>] [--snapshot] [--width <px>] [--loops <n>] <url>
      aetherctl audio [--seconds N] <url>
      aetherctl audiotap [--duration S] [--out PATH.wav] [--remote] <url>
                         (#95: decode the loopback audio track to mono 48k WAV, print continuity stats)
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

    Flags (serve / seektest):
      --throttle-kbps N
                     TEST-ONLY slow-CDN simulation: cap source-IO
                     delivery to N kbit/s. Set below the stream bitrate
                     to starve the producer below real-time and provoke
                     AVPlayer rebuffers (e.g. the #92 open-GOP repro).

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

      dovitest  Walk the source's HEVC video stream, convert each
                packet's Dolby Vision RPU from Profile 7 to Profile
                8.1 (and drop the enhancement layer) via
                DoviRpuConverter, and write the result to
                /tmp/aetherctl-dovitest.hevc in Annex-B form. Feed
                that to `dovi_tool extract-rpu` + `info` to validate
                the rewritten RPU against ground truth.

      swdecode  Open SoftwareVideoDecoder for the source's video
                stream, feed packets, report counters + first-frame
                metadata. Tests the SW-pipeline path without needing
                a display layer. Use for AV1, VP9, MPEG-4 Part 2,
                MPEG-2, VC-1 sources.

      disc-inspect
                Walk a local disc image (.iso) at the filesystem
                layer, FFmpeg-free, and report what DiscReader makes
                of it: ISO9660/UDF signatures, UDF root + BDMV tree,
                parsed .mpls playlists, selected main title, and the
                resolved m2ts extents. Prints where recognition bails
                when it returns nil. Exit 0 if recognized, else 1.

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

// #92 verifier: SW-decode each segment in isolation; framesDecoded==0 => not independently decodable.
if first == "segverify" {
    var rest = Array(args.dropFirst(2))
    let fromIdx = takeIntFlag("--from", from: &rest) ?? 0
    let count   = takeIntFlag("--count", from: &rest) ?? 12
    let noDV    = takeFlag("--no-dv", from: &rest)
    let dumpDir = takeStringFlag("--dump", from: &rest)
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: segverify requires a <url> argument")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "segverify")
    exit(runSegVerify(url: parseSourceURL(urlArg), from: fromIdx, count: count, dvModeAvailable: !noDV, dumpDir: dumpDir))
}

// Rapid-seek burst repro (issue #35).
if first == "seektest" {
    var rest = Array(args.dropFirst(2))
    let seeks   = takeIntFlag("--seeks", from: &rest) ?? 40
    let gapMs   = takeIntFlag("--gap-ms", from: &rest) ?? 60
    let settle  = takeDoubleFlag("--settle", from: &rest) ?? 5.0
    let throttleKbps = takeIntFlag("--throttle-kbps", from: &rest)
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: seektest requires a <url> argument")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "seektest")
    if let throttleKbps {
        AetherEngine.setSourceThrottleKbpsForTesting(throttleKbps)
        print("[aetherctl] source throttle: \(throttleKbps) kbit/s (slow-CDN simulation)")
    }
    exit(runSeekTest(url: parseSourceURL(urlArg), seeks: seeks, gapMs: gapMs, settleSeconds: settle))
}

// SW-path background-audio keepalive harness (iOS background audio on the software decode path).
if first == "bgaudio" {
    var rest = Array(args.dropFirst(2))
    let fg = takeDoubleFlag("--fg", from: &rest) ?? 3.0
    let bg = takeDoubleFlag("--bg", from: &rest) ?? 6.0
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: bgaudio requires a <url> argument")
        print("Usage: aetherctl bgaudio [--fg N] [--bg N] <url>")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "bgaudio")
    exit(runBackgroundAudio(url: parseSourceURL(urlArg), fgSeconds: fg, bgSeconds: bg))
}

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

// Disc filesystem inspector (DVD-Video / Blu-ray ISO recognition triage).
if first == "disc-inspect" {
    var rest = Array(args.dropFirst(2))
    let dump = takeFlag("--dump", from: &rest)
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: disc-inspect requires a <file> argument")
        print("Usage: aetherctl disc-inspect [--dump] <disc.iso>")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "disc-inspect")
    exit(runDiscInspect(url: parseSourceURL(urlArg), dump: dump))
}

// DV P7 -> 8.1 converter validation harness.
if first == "dovitest" {
    var rest = Array(args.dropFirst(2))
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: dovitest requires a <file> argument")
        print("Usage: aetherctl dovitest <file>")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "dovitest")
    exit(runDoviTest(url: parseSourceURL(urlArg)))
}

// #93 post-recovery judder: raw video packet timing per demuxer open profile.
if first == "pktdump" {
    var rest = Array(args.dropFirst(2))
    let atSeconds = takeDoubleFlag("--at", from: &rest) ?? 0
    let count = takeIntFlag("--count", from: &rest) ?? 200
    let profileName = takeStringFlag("--profile", from: &rest) ?? "playback"
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: pktdump requires a <url> argument")
        print("Usage: aetherctl pktdump [--at S] [--count N] [--profile playback|restartReopen|stillExtraction] <url>")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "pktdump")
    exit(runPktDump(url: parseSourceURL(urlArg), at: atSeconds, count: count, profileName: profileName))
}

// #95 audio tap: decode the loopback audio track to a WAV, print continuity stats.
if first == "audiotap" {
    var rest = Array(args.dropFirst(2))
    let duration = takeDoubleFlag("--duration", from: &rest) ?? 30
    let outPath = takeStringFlag("--out", from: &rest) ?? "/tmp/audiotap.wav"
    let remote = rest.contains("--remote")
    rest.removeAll { $0 == "--remote" }
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: audiotap requires a <url> argument")
        print("Usage: aetherctl audiotap [--duration S] [--out PATH.wav] [--remote] <url>")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "audiotap")
    exit(runAudioTap(url: parseSourceURL(urlArg), duration: duration, outPath: outPath, remote: remote))
}

if first == "hlsfixture" {
    let rest = Array(args.dropFirst(2))
    exit(runHLSFixture(args: rest))
}

// SSAI repro via HLSLiveIngestReader (hlslive).
if first == "hlslive" {
    let rest = Array(args.dropFirst(2))
    exit(runHLSLiveRepro(args: rest))
}

if first == "live" {
    var rest = Array(args.dropFirst(2))
    let seconds = takeDoubleFlag("--seconds", from: &rest) ?? 20.0
    let dvrWindow = takeDoubleFlag("--dvr-window", from: &rest)
    let seed = takeStringFlag("--seed", from: &rest)
    let serveOnly = takeFlag("--serve-only", from: &rest)
    let measureRSS = takeFlag("--measure-rss", from: &rest)
    let reportCacheBytes = takeFlag("--report-cache-bytes", from: &rest)
    let rewindTest = takeFlag("--rewind-test", from: &rest)
    // --reload-test: macOS repro for tvOS live-reload frozen-frame stall; see liveReloadTest in LiveCmd.
    let reloadTest = takeFlag("--reload-test", from: &rest)
    // --sw: TEST-ONLY force-SoftwarePlaybackHost routing for the H.264 fixture.
    let forceSW = takeFlag("--sw", from: &rest)
    // --drop-after N: close the first connection after N seconds (recoverable drop); AVIOReader reconnects.
    let dropAfter = takeDoubleFlag("--drop-after", from: &rest)
    // --discontinuity-at N: one-shot PTS/PCR forward jump after N seconds (program boundary); engine must keep the session timeline monotonic.
    let discontinuityAt = takeDoubleFlag("--discontinuity-at", from: &rest)
    // --realtime paces fixture output at ~1x wall-clock; default is as-fast-as-socket-drains.
    let realtime = takeFlag("--realtime", from: &rest)
    // --gen-highbitrate-seed: generate ~22 Mbps 1080p H.264 MPEG-TS seed for RSS-retention measurement.
    if takeFlag("--gen-highbitrate-seed", from: &rest) {
        let path = seed ?? "Fixtures/user/highbitrate-1080p.ts"
        exit(ensureHighBitrateSeed(path: path) ? 0 : 1)
    }
    // --sliding: accepted but ignored; sliding is now unconditional for live sessions.
    _ = takeFlag("--sliding", from: &rest)
    rejectStrayFlags(rest, subcommand: "live")
    exit(runLive(seconds: seconds, seed: seed, dvrWindow: dvrWindow,
                 serveOnly: serveOnly, measureRSS: measureRSS,
                 reportCacheBytes: reportCacheBytes, rewindTest: rewindTest,
                 reloadTest: reloadTest,
                 forceSoftware: forceSW, dropAfter: dropAfter,
                 discontinuityAt: discontinuityAt, realtime: realtime))
}

if first == "play" {
    var rest = Array(args.dropFirst(2))
    let seconds = takeDoubleFlag("--seconds", from: &rest) ?? 30.0
    let live = takeFlag("--live", from: &rest)
    let dvrWindow = takeDoubleFlag("--dvr-window", from: &rest)
    let subsPick = takeStringFlag("--subs", from: &rest)
    let hostCalls = takeStringFlag("--host-calls", from: &rest).map { $0.split(separator: ",").map(String.init) } ?? []
    let audioStats = takeFlag("--audio-stats", from: &rest)
    rejectStrayFlags(rest, subcommand: "play")
    guard let urlArg = rest.first else {
        print("ERROR: play requires a <url> argument")
        print("")
        printUsage()
        exit(64)
    }
    exit(runPlay(url: parseSourceURL(urlArg), seconds: seconds, live: live, dvrWindow: dvrWindow, subsPick: subsPick, hostCalls: hostCalls, audioStats: audioStats))
}

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
    // --native-subs: diagnostics affordance for mov_text subtitle track (#55); serve only.
    let nativeSubsIndex = takeIntFlag("--native-subs", from: &rest)
    // --throttle-kbps: slow-CDN simulation; starves the producer below real-time to provoke rebuffers.
    let throttleKbps = takeIntFlag("--throttle-kbps", from: &rest)
    // --start-position: anchor the first producer at a resume position like load(startPosition:) (#99); serve only.
    let startPosition = takeDoubleFlag("--start-position", from: &rest)
    rejectStrayFlags(rest, subcommand: first)
    guard let urlArg = rest.first else {
        print("ERROR: \(first) requires a <url> argument")
        print("")
        printUsage()
        exit(64)
    }
    let url = parseSourceURL(urlArg)
    let dvModeAvailable = !noDV
    if let throttleKbps {
        AetherEngine.setSourceThrottleKbpsForTesting(throttleKbps)
        print("[aetherctl] source throttle: \(throttleKbps) kbit/s (slow-CDN simulation)")
    }
    switch first {
    case "probe":
        exit(runProbe(url: url))
    case "serve":
        runServe(url: url, dvModeAvailable: dvModeAvailable, nativeSubsIndex: nativeSubsIndex,
                 startPosition: startPosition)
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
        exit(runCustomIO(path: urlArg, inMemory: inMemory, forwardOnly: forwardOnly, audioOnly: audioOnlyFlag, reload: reloadFlag, switchAudio: switchAudioFlag, selectSubs: selectSubsFlag, extract: extractFlag))
    default:
        printUsage()
        exit(64)
    }
}

// Bare URL: backwards-compat alias for `serve`.
let url = parseSourceURL(first)
runServe(url: url, dvModeAvailable: true)
