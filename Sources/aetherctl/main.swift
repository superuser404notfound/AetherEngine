// aetherctl: standalone reproduction harness for AetherEngine on macOS.
//
// Twenty-one subcommands, most operating on a media source URL (file://
// or http(s)://), a few on built-in synthetic fixtures. The full list
// with flags and examples lives in docs/cli.md; the three original modes:
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
      aetherctl serve [--no-dv] [--force-dv] [--dv-base-layer] [--start-position S] <url>
      aetherctl validate [--no-dv] [--force-dv] [--dv-base-layer] <url>
      aetherctl swdecode [--frames N] <url>
      aetherctl play [--seconds N] [--live] [--fast-zap] [--live-start-immediately] [--dvr-window N] [--subs <codec-or-lang>]
                 [--assert-dv] [--dv-base-layer]
                 [--start-position S] [--switch-audio <index>[@ms]]
                 [--teletext-page N] [--switch-teletext-page <page|auto>[@ms]]
                 [--audio-delay <ms>] [--switch-audio-delay <ms>[@ms]]... [--paused]
                 [--reload-applying <key>=<value>]... [--reload-applying-at <ms>]
                 [--drop-audio]
                 [--sequential-origin] [--declared-duration S]
             [--max-concurrent-requests N]
                     [--audio-stats] [--host-calls play,extractor,setrate,pausestart,reloadlive,seekback,seekfar,pauseseek] <url>
                     (full load+play session smoke test; --subs activates the first
                      matching embedded subtitle track and logs overlay cues;
                      --audio-stats taps decoded PCM and prints per-second audio lead
                      plus PTS-continuity gaps; seekback rewinds 20 s at t=15 and
                      returns to the live edge at t=30; seekfar (or seekfar@N)
                      seeks past the produced window at t=15 (or t=N), so the landing
                      needs a producer restart; --switch-audio replays a host
                      applying a language preference just after play, default +20 ms;
                      --teletext-page fixes the caption page at load, while
                      --switch-teletext-page changes it on the playing channel
                      --drop-audio forces the audio pipeline to fail (AE#462), so
                      the video-only drop and its published audioDelivery can be
                      observed without a source this build cannot decode
                      (default +20 s, i.e. after --subs has a track showing);
                      --reload-applying corrects a LoadOption on the playing
                      session through #460's session-preserving reload, repeatable;
                      keys header.<Name>, audio-bridge, preferred-audio,
                      decode-path, dolby-vision, is-live
                      (is-live is there to show the refusal: a field that names the
                      session is refused, not silently ignored), default +20 s;
                      --sequential-origin declares a fake-range origin (one unranged
                      GET, no ranged probes) and needs --declared-duration on VOD
                      since the tail estimate is skipped)
      aetherctl segverify [--from N] [--count K] [--no-dv] [--force-dv] [--dv-base-layer] [--dump <dir>] <url>
                          (#92: SW-decode each segment in isolation; framesDecoded==0 => not independent)
      aetherctl disc-inspect <disc.iso>
      aetherctl dovitest <file>
      aetherctl extract [--at <sec>] [--snapshot] [--width <px>] [--loops <n>] <url>
      aetherctl audio [--seconds N] <url>
      aetherctl audiotap [--duration S] [--out PATH.wav] [--remote | --software] <url>
                         (#95: decode the loopback audio track to mono 48k WAV, print continuity stats;
                          --software runs a real session through the SW sink, exit 3 if it yields no audible PCM)
      aetherctl customio [--memory] [--forward-only] [--audio-only] [--reload] [--switch-audio] [--select-subs] [--extract] [--audio-index N] [--reload-decode-path automatic|software] <file>
      aetherctl customio --live [--rate-kbps N] [--seconds N] [--dvr-window N] [--report-size] [--no-wrap] [--malloc-census] [--foundation-reader] [--host-carry none|removeFirst|subdata] [--reload-at S] [--cancel-latches] [--reload-decode-path automatic|software] [--reader-axis absolute|join|mismatched] [--join-offset-mb N] <file.ts>
                         (AE#445: a host-owned live spool behind MediaSource.custom, paced at the mux rate,
                          never EOF, unknown size; prints physFP and its slope against that rate)
      aetherctl live [--seconds N] [--seed <path>] [--dvr-window N] [--serve-only] [--measure-rss] [--report-cache-bytes] [--rewind-test] [--reload-test] [--sw] [--drop-after N] [--discontinuity-at N] [--realtime] [--realtime-rate X] [--fast-zap] [--preroll N] [--rewind-hold N] [--gen-highbitrate-seed]
                     [--freeze-after N] [--unfreeze-after N] [--rewind-before-freeze N] [--force-recovery-reload-at N] [--live-only] [--no-blocking-reload] [--force-master]
                     [--freeze-after N] [--unfreeze-after N] [--rewind-before-freeze N] [--force-recovery-reload-at N]
                     [--no-blocking-reload]
      aetherctl dvr [--path native|sw|both] [--seconds N] [--dvr-window N]
      aetherctl dualsubs <file> --primary <streamIndex> --secondary <streamIndex> [--seek <seconds>]
      aetherctl hlsfixture <input.ts> [--port N] [--segment-seconds N] [--target-duration N] [--window N]
                           [--master] [--discontinuity-at N] [--slow-refresh]
                           [--drop-segment N] [--encrypted] [--fmp4] [--self-test]
      aetherctl hlslive --segments a.ts,b.ts,c.ts [--seconds N] [--segment-seconds N] [--disc i,j]
                        (SSAI ad-pod replay through the live direct-play path)
      aetherctl seektest [--seeks N] [--gap-ms N] [--settle N] [--throttle-kbps N] <url>
                         (#35/#37/#38: rapid-seek burst, wedge report, seek-event ledger)
      aetherctl pktdump [--at S] [--count N] [--profile playback|restartReopen|stillExtraction] <url>
                        (raw demuxer packet timing, before dts repair and muxing)
      aetherctl bgaudio [--fg N] [--bg N] <url>
                        (SW-path background audio headless on macOS; DEBUG builds only)
      aetherctl smbtest [--reads N] <smb-url>
                        (SMB byte source: throughput pass + random-seek consistency; macOS)
      aetherctl <url>             (alias for `serve`)

    Flags (serve / validate only):
      --no-dv        Pin HLSVideoEngine to dvModeAvailable=false, i.e.
                     pretend the display can't render Dolby Vision.
                     Mirrors what AetherEngine.loadNative passes on a
                     non-DV TV / on macOS (where displayCapabilities
                     reports supportsDolbyVision=false unless the
                     session asserts it, see `play --assert-dv`).
      --force-dv     AE#455: serve a DV Profile 8.1 source as Profile 5
                     (dvh1 + dvcC profile=5, CODECS=dvh1.05.LL) so
                     AVPlayer composes the RPU itself. Only has an
                     effect together with --no-dv; a display that does
                     Dolby Vision keeps the P8.1 route.
      --dv-base-layer
                     LoadOptions.dolbyVisionHandling = .baseLayerOnly:
                     present the HDR10 / HLG base layer of a Dolby
                     Vision source and leave the DV out of the container
                     (plain hvc1 / av01, dvcC stripped, no
                     SUPPLEMENTAL-CODECS), on any display. Covers HEVC
                     P7 / P8.1 / P8.4, AV1 P10.1 / P10.4, and a P5
                     record over a BT.2020 YCbCr VUI (a relabelled P7 /
                     P8 remux); a genuine P5 has no base layer and keeps
                     its route. Also accepted by `play`.

    Flags (play only):
      --assert-dv    AE#493: set LoadOptions.panelPresentsDolbyVision,
                     the host's assertion that this display presents
                     Dolby Vision. macOS has no per-mode capability API
                     (AVPlayer.availableHDRModes is unavailable there)
                     and HDR eligibility answers HDR10 and HLG but not
                     DV, so a DV source otherwise plays as its HDR10
                     base layer with effective-format=hdr10. The flag
                     moves that label and the tvOS criteria request; it
                     no longer moves the packaging of a P5 / P8.1 / P8.4
                     source, which since 6.72.0 / 6.73.0 carries its
                     dvcC and SUPPLEMENTAL-CODECS on every display (the
                     served master, media playlist, init.mp4 and
                     segments are byte-identical either way). P7 and AV1
                     DV are still gated on it. A wrong claim costs one
                     in-place media-playlist fallback (-11868 / -11848),
                     not the item.

    Flags (play only, AE#551):
      --prewarm      Warm the source before loading it, the way a host
                     warms the next episode. Takes the engine's default
                     budget (8 MB).
      --prewarm-bytes N
                     Warm N bytes instead. Measure this against a REAL
                     origin: on loopback the round trip it removes costs
                     nothing, which is the trap #281 was built out of.

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
    let forceDV = takeFlag("--force-dv", from: &rest)
    let dvBaseLayer = takeFlag("--dv-base-layer", from: &rest)
    let dumpDir = takeStringFlag("--dump", from: &rest)
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: segverify requires a <url> argument")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "segverify")
    exit(runSegVerify(url: parseSourceURL(urlArg), from: fromIdx, count: count, dvModeAvailable: !noDV,
                      forceDVWithoutDisplay: forceDV,
                      dolbyVisionHandling: dvBaseLayer ? .baseLayerOnly : .automatic,
                      dumpDir: dumpDir))
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
    let software = rest.contains("--software")
    rest.removeAll { $0 == "--software" }
    guard let urlArg = rest.first(where: { !$0.hasPrefix("--") }) else {
        print("ERROR: audiotap requires a <url> argument")
        print("Usage: aetherctl audiotap [--duration S] [--out PATH.wav] [--remote | --software] <url>")
        exit(64)
    }
    rest.removeAll { $0 == urlArg }
    rejectStrayFlags(rest, subcommand: "audiotap")
    exit(runAudioTap(url: parseSourceURL(urlArg), duration: duration, outPath: outPath,
                 remote: remote, software: software))
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
    // --fast-zap: LoadOptions.liveJoinProfile = .fastZap (AE#195 low-latency live join).
    let fastZap = takeFlag("--fast-zap", from: &rest)
    // --preroll N: backlog seconds the paced fixture bursts before 1x pacing (default 30).
    // 0 models a strict-realtime origin with no backlog (the AE#195 slow-join case).
    let preroll = takeDoubleFlag("--preroll", from: &rest)
    // --realtime-rate X: pace at X times wall clock after the preroll (implies --realtime). 1x is
    // `--realtime`; unpaced is a burst that ENDS. Neither covers an origin that keeps running ahead
    // for the whole session, which is what makes a live edge outrun the client that tracks it.
    let realtimeRate = takeDoubleFlag("--realtime-rate", from: &rest)
    // --origin-lead N: how far ahead of the wall clock the paced origin is allowed to run, which is
    // the standing distance a raw live client ends up reading behind. A tuner or a transcode route
    // hands over seconds at a time and keeps that lead; the built-in 2 s sits exactly on the old
    // edge tolerance and hides everything either side of it (Sodalite#104 round 2).
    let originLead = takeDoubleFlag("--origin-lead", from: &rest)
    // --gen-highbitrate-seed: generate ~22 Mbps 1080p H.264 MPEG-TS seed for RSS-retention measurement.
    if takeFlag("--gen-highbitrate-seed", from: &rest) {
        let path = seed ?? "Fixtures/user/highbitrate-1080p.ts"
        exit(ensureHighBitrateSeed(path: path) ? 0 : 1)
    }
    // AE#442: --freeze-after N freezes the upstream (connection open, no bytes) after N seconds, and
    // --rewind-before-freeze N parks the playhead N seconds inside the DVR window first. Together they
    // are the reporter's shape: a viewer minutes behind live when the source dies.
    let freezeAfter = takeDoubleFlag("--freeze-after", from: &rest)
    let rewindBeforeFreeze = takeDoubleFlag("--rewind-before-freeze", from: &rest)
    // AE#446 round 2: let the frozen upstream start delivering again after N seconds, which is the
    // only way to drive the recovery-after-an-outage path (a window closed with ENDLIST re-opening).
    let unfreezeAfter = takeDoubleFlag("--unfreeze-after", from: &rest)
    // AE#442: drive the stage-2 recovery reload at N seconds instead of waiting for a real item death,
    // so where a parked live session comes back from it is measurable in one run.
    let forceRecoveryReloadAt = takeDoubleFlag("--force-recovery-reload-at", from: &rest)
    // AE#441 follow-up: --rewind-hold N parks the playhead N seconds behind the edge and HOLDS it there
    // for the rest of the run, which is the regime that separates a floor doing its job from a window
    // outrunning the reader. --freeze-after kills the source; --rewind-test samples five seconds.
    let rewindHold = takeDoubleFlag("--rewind-hold", from: &rest)
    // AE#446: force LoadOptions.liveBlockingReload. --no-blocking-reload never advertises
    // CAN-BLOCK-RELOAD, which is the arm that separates "AVPlayer stopped fetching because the
    // playlist stopped changing" from "AVPlayer stopped fetching because it is in low-latency mode".
    let noBlockingReload = takeFlag("--no-blocking-reload", from: &rest)
    // AE#446 round 4: --live-only loads with no DVR window, the shape of a client that keeps its
    // rewind outside the engine. The freeze leg then measures the only timeshift such a session can
    // have, the backlog an outage puts between the closed window's end and the source's return.
    let liveOnly = takeFlag("--live-only", from: &rest)
    // AE#454: --force-master routes the live session behind its master playlist and sets
    // LoadOptions.prepareNativeSubtitles the way a real host does (unconditionally). That pairing is
    // the device's own route, and every live leg before this ran media-direct, so nothing here had
    // ever exercised it.
    let liveForceMaster = takeFlag("--force-master", from: &rest)
    // AE#509: --start-position S loads the live session with a resume anchor, the same one
    // `load(url:startPosition:)` takes. Live callers normally pass nil, so the anchor's own live
    // handling had never been drivable from here.
    let liveStartPosition = takeDoubleFlag("--start-position", from: &rest)
    // --sliding: accepted but ignored; sliding is now unconditional for live sessions.
    _ = takeFlag("--sliding", from: &rest)
    rejectStrayFlags(rest, subcommand: "live")
    exit(runLive(seconds: seconds, seed: seed, dvrWindow: dvrWindow,
                 serveOnly: serveOnly, measureRSS: measureRSS,
                 reportCacheBytes: reportCacheBytes, rewindTest: rewindTest,
                 reloadTest: reloadTest,
                 forceSoftware: forceSW, dropAfter: dropAfter,
                 discontinuityAt: discontinuityAt, realtime: realtime || realtimeRate != nil,
                 fastZap: fastZap, pacingPreroll: preroll, pacingRate: realtimeRate,
                 originLead: originLead,
                 freezeAfter: freezeAfter, unfreezeAfter: unfreezeAfter,
                 rewindBeforeFreeze: rewindBeforeFreeze,
                 forceRecoveryReloadAt: forceRecoveryReloadAt,
                 rewindHold: rewindHold,
                 blockingReload: noBlockingReload ? false : nil,
                 liveOnly: liveOnly, forceMaster: liveForceMaster,
                 startPosition: liveStartPosition))
}

if first == "play" {
    var rest = Array(args.dropFirst(2))
    let seconds = takeDoubleFlag("--seconds", from: &rest) ?? 30.0
    let live = takeFlag("--live", from: &rest)
    // AE#293: the nativeRemoteHLS bypass, the path the #168 carriage watchdog and the carriage probe
    // live on. Pair with --live; without it the m3u8 goes to the raw live path, which rejects it.
    let nativeHLS = takeFlag("--native-hls", from: &rest)
    // AE#495: stand in for a host that has answered `EngineTLS.serverTrustEvaluator`, which is what
    // decides whether a remote https master is relayed through the loopback origin instead of being
    // handed to AVPlayer (which asks no delegate and cannot be told about a private certificate).
    // Without it the relay had no harness at all: every run here reaches an origin the system
    // already trusts, which is the one case the relay is deliberately not used for.
    let trustAnyCertificate = takeFlag("--trust-any-certificate", from: &rest)
    let liveIngest = takeFlag("--live-ingest", from: &rest)
    // AE#374: the join profile a host ships, against an origin of its own rather than the built-in
    // fixture `live` carries. fastZap plus an external HLS origin is the shape a downstream player
    // actually runs, and it could not be driven from here at all: the TARGETDURATION floor comes from
    // the UPSTREAM's observed cadence, so what a fastZap start costs depends on an origin the raw-TS
    // fixture does not have.
    let playFastZap = takeFlag("--fast-zap", from: &rest)
    // AE#440: LoadOptions.liveJoinStartsImmediately. The join tail after the first serve, where AVPlayer
    // holds a presented frame still while it evaluates whether its cushion will sustain playback. The
    // hold does not reproduce on this harness (loopback answers at memory speed, so the evaluation
    // concludes immediately); these flags drive the OTHER end of the A/B on a device.
    //
    // On by default in the engine since 6.55.0, so this mirrors that default rather than passing a
    // literal `false` and silently making the CLI the one place the lever is off. The positive flag
    // stays accepted, since the device A/B script passes it explicitly.
    let playLiveStartImmediately = takeFlag("--live-start-immediately", from: &rest)
    let playNoLiveStartImmediately = takeFlag("--no-live-start-immediately", from: &rest)
    let liveStartImmediately = playLiveStartImmediately ? true : !playNoLiveStartImmediately
    let dvrWindow = takeDoubleFlag("--dvr-window", from: &rest)
    let subsPick = takeStringFlag("--subs", from: &rest)
    let hostCalls = takeStringFlag("--host-calls", from: &rest).map { $0.split(separator: ",").map(String.init) } ?? []
    let audioStats = takeFlag("--audio-stats", from: &rest)
    let seekEvery = takeDoubleFlag("--seek-every", from: &rest)
    // #240: absolute far-seek targets, cycled one per --seek-every tick (e.g. 600,30,302,640).
    let seekPattern = takeStringFlag("--seek-pattern", from: &rest)
        .map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } } ?? []
    // #362: stop seeking after N seeks, so a run can be a BURST and then play. The reported
    // shape needs both halves: the burst leaves the store in the state under test, and only the
    // playing half shows what the overlay carries through it.
    let seekCount = takeIntFlag("--seek-count", from: &rest)
    let mallocCensus = takeFlag("--malloc-census", from: &rest)
    let playForceSW = takeFlag("--sw", from: &rest)
    // AE#493: `LoadOptions.panelPresentsDolbyVision`, the host assertion. macOS has no per-mode display
    // capability API, so DV is unclaimable from inside the engine and a Mac run routes every DV source
    // as its HDR10 base layer until the host says otherwise.
    let playAssertDV = takeFlag("--assert-dv", from: &rest)
    // `LoadOptions.dolbyVisionHandling = .baseLayerOnly`: the base layer of a Dolby Vision source, the
    // Dolby Vision left out of the container. The harness for a record the bitstream contradicts.
    let playDVHandling: DolbyVisionHandling = takeFlag("--dv-base-layer", from: &rest) ? .baseLayerOnly : .automatic
    // AE#560: record the live source to a file from the session's existing connection.
    let playRecord = takeStringFlag("--record", from: &rest).map { URL(fileURLWithPath: $0) }
    // AE#492: `LoadOptions.deinterlaceFieldRate`. `send_field` (the default) emits one frame per
    // FIELD, so a 29.97i source hands the layer 59.94 frames per second against 23.976 for a
    // progressive one. That is the confound in every per-seek drop count taken across the two, and
    // `--deinterlace-field-rate frame` is the A/B that separates the rate from the path.
    let playFieldRateSpec = takeStringFlag("--deinterlace-field-rate", from: &rest)
    let playFieldRate: DeinterlaceFieldRate
    if let playFieldRateSpec {
        guard let parsed = DeinterlaceFieldRate(rawValue: playFieldRateSpec) else {
            print("ERROR: --deinterlace-field-rate takes field|frame, got '\(playFieldRateSpec)'")
            exit(64)
        }
        playFieldRate = parsed
    } else {
        playFieldRate = .field
    }
    // AE#462: force the audio pipeline to fail so the video-only drop is observable end to end.
    // There is no fixture for it: the drop needs a codec this build has no decoder for (AC-4 is the
    // realistic one), and a threshold that plausible is worth less than the real published value.
    if takeFlag("--drop-audio", from: &rest) {
        AetherEngine.setForceAudioPipelineFailureForTesting(true)
        print("[aetherctl] TEST-ONLY: audio pipeline forced to fail (AE#462 video-only drop)")
    }
    let censusThresholdMB = takeIntFlag("--census-threshold-mb", from: &rest)
    let censusHz = takeDoubleFlag("--census-hz", from: &rest)
    // Slow-CDN simulation, same hook as `serve` / `seektest`: a local file lets the producer race
    // minutes ahead, which is the one regime where producer scheduling cannot matter (AE#286).
    let playThrottleKbps = takeIntFlag("--throttle-kbps", from: &rest)
    // Resume anchor, the same one load(startPosition:) takes. AE#287 needs it: the reporter's hard
    // park only reproduces when a rebuilt session opens exactly at the video-exhaustion boundary.
    let playStartPosition = takeDoubleFlag("--start-position", from: &rest)
    // Sequential-origin declaration (LoadOptions.sequentialOrigin): fake-range archives get one
    // unranged GET and no ranged probes; pair with --declared-duration on VOD because the tail
    // duration estimate is skipped along with the other ranged reads.
    let sequentialOrigin = takeFlag("--sequential-origin", from: &rest)
    // #377: LoadOptions.maxConcurrentSourceRequests. Caps how many requests the reader may have
    // open against the origin at once across every path it fetches on. `1` also switches off the
    // speculative parallel paths. This is the knob for reproducing a connection-metered CDN.
    let maxConcurrentRequests = takeIntFlag("--max-concurrent-requests", from: &rest)
    // #377: LoadOptions.heldSourceConnection. The reader asks the origin once and pulls the file
    // over that one connection, instead of ending at the window high water and asking again every
    // drain cycle. This is the knob for an origin that refuses new requests in windows: run it
    // against one and count the ranges in its own log, or read `conn start ... held` here.
    let heldConnection = takeFlag("--held-connection", from: &rest)
    let declaredDuration = takeDoubleFlag("--declared-duration", from: &rest)
    // #311: install the software frame-time observer and read the presentation timebase, so the
    // per-frame boundaries and the clock a host would pace an overlay against are both observable.
    let frameTimes = takeFlag("--frame-times", from: &rest)
    let presentTimes = takeFlag("--present-times", from: &rest)
    let pictureProbe = takeFlag("--picture-probe", from: &rest)
    // #316: declare sidecar subtitles at load, the LoadOptions.externalSubtitles a host passes.
    // Comma-separated `lang=path-or-url` entries, e.g. --sidecar en=/tmp/en.srt,de=/tmp/de.srt.
    // On the nativeRemoteHLS bypass this is what makes the engine stand up its rewritten master.
    let sidecars: [ExternalSubtitleTrack] = (takeStringFlag("--sidecar", from: &rest) ?? "")
        .split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            let (language, path) = parts.count == 2 ? (parts[0], parts[1]) : (nil, parts[0])
            let url = parseSourceURL(path)
            return ExternalSubtitleTrack(
                url: url,
                name: language.map { $0.uppercased() } ?? url.deletingPathExtension().lastPathComponent,
                language: language)
        }
    // #337: a host's post-play audio pick, `index[@ms]` (default 20 ms, the field case). Selecting a
    // stream whose first packet sits past the renderer's fill point is what wedges the rebuilt
    // session, so the delay has to be short enough that the rebuild still resumes at 0.
    let audioSwitch: AudioSwitchRequest? = takeStringFlag("--switch-audio", from: &rest).flatMap { spec in
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        guard let index = Int(parts[0]) else {
            print("ERROR: --switch-audio takes <index>[@ms], got '\(spec)'")
            exit(64)
        }
        return AudioSwitchRequest(index: index,
                                  delayMilliseconds: parts.count == 2 ? (Int(parts[1]) ?? 20) : 20)
    }
    let teletextPage = takeIntFlag("--teletext-page", from: &rest)
    // #364: `<page|auto>[@ms]`. The default delay is 20 s, not the audio switch's 20 ms: this one has
    // to land on a channel that is already showing a teletext track, else the run proves nothing the
    // load option did not already prove.
    let teletextSwitch: TeletextPageSwitchRequest? = takeStringFlag("--switch-teletext-page", from: &rest).flatMap { spec in
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        let page: Int?
        if parts[0].lowercased() == "auto" {
            page = nil
        } else if let parsed = Int(parts[0]) {
            page = parsed
        } else {
            print("ERROR: --switch-teletext-page takes <page|auto>[@ms], got '\(spec)'")
            exit(64)
        }
        return TeletextPageSwitchRequest(page: page,
                                        delayMilliseconds: parts.count == 2 ? (Int(parts[1]) ?? 20_000) : 20_000)
    }
    // AE#464: `--audio-delay <ms>` is the load option, `--switch-audio-delay <ms>[@ms]` is the
    // runtime setter. Same 20 s default as the teletext switch and for the same reason: it has to
    // land on a session that is playing, or it only re-proves the load option.
    let audioDelayMs = takeIntFlag("--audio-delay", from: &rest) ?? 0
    // Round 2: repeatable, so a run can press the stepper more than once. The `@ms` suffixes are
    // what put two presses inside one runloop turn.
    var audioDelaySwitches: [AudioDelaySwitchRequest] = []
    while let spec = takeStringFlag("--switch-audio-delay", from: &rest) {
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        guard let ms = Int(parts[0]) else {
            print("ERROR: --switch-audio-delay takes <ms>[@ms], got '\(spec)'")
            exit(64)
        }
        audioDelaySwitches.append(AudioDelaySwitchRequest(
            milliseconds: ms,
            delayMilliseconds: parts.count == 2 ? (Int(parts[1]) ?? 20_000) : 20_000))
    }
    // AE#464 round 2: mount with `autoplay = false`, the shape of a host that owns transport.
    let pausedMount = takeFlag("--paused", from: &rest)
    // #460: `--reload-applying <key>=<value>`, repeatable, with one shared delay. The delay is a
    // separate flag rather than teletext's `@ms` suffix because a header value can carry an `@`.
    // Default +20 s for the same reason the teletext switch uses it: the correction has to land on
    // a session that is already playing.
    var optionChanges: [LoadOptionChange] = []
    while let spec = takeStringFlag("--reload-applying", from: &rest) {
        guard let eq = spec.firstIndex(of: "=") else {
            print("ERROR: --reload-applying expects <key>=<value>, got '\(spec)'")
            exit(64)
        }
        let key = String(spec[..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(spec[spec.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("header.") {
            optionChanges.append(.header(name: String(key.dropFirst("header.".count)), value: value))
        } else if key == "audio-bridge" {
            guard let mode = AudioBridgeMode(rawValue: value) else {
                print("ERROR: --reload-applying audio-bridge takes \(AudioBridgeMode.allCases.map(\.rawValue).joined(separator: "|")), got '\(value)'")
                exit(64)
            }
            optionChanges.append(.audioBridgeMode(mode))
        } else if key == "preferred-audio" {
            optionChanges.append(.preferredAudioLanguages(
                value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
        } else if key == "decode-path" {
            guard let path = DecodePath(rawValue: value) else {
                print("ERROR: --reload-applying decode-path takes \(DecodePath.allCases.map(\.rawValue).joined(separator: "|")), got '\(value)'")
                exit(64)
            }
            optionChanges.append(.decodePath(path))
        } else if key == "dolby-vision" {
            guard let handling = DolbyVisionHandling(rawValue: value) else {
                print("ERROR: --reload-applying dolby-vision takes \(DolbyVisionHandling.allCases.map(\.rawValue).joined(separator: "|")), got '\(value)'")
                exit(64)
            }
            optionChanges.append(.dolbyVisionHandling(handling))
        } else if key == "is-live" {
            guard let flag = Bool(value) else {
                print("ERROR: --reload-applying is-live takes true|false, got '\(value)'")
                exit(64)
            }
            optionChanges.append(.isLive(flag))
        } else if key == "autoplay" {
            guard let flag = Bool(value) else {
                print("ERROR: --reload-applying autoplay takes true|false, got '\(value)'")
                exit(64)
            }
            optionChanges.append(.autoplay(flag))
        } else {
            print("ERROR: --reload-applying key '\(key)' is not one of header.<Name>, audio-bridge, preferred-audio, decode-path, dolby-vision, is-live, autoplay")
            exit(64)
        }
    }
    let optionCorrectionDelay = takeIntFlag("--reload-applying-at", from: &rest) ?? 20_000
    let optionCorrection: LoadOptionCorrectionRequest? = optionChanges.isEmpty
        ? nil
        : LoadOptionCorrectionRequest(changes: optionChanges, delayMilliseconds: optionCorrectionDelay)
    // AE#363: LoadOptions.httpHeaders, repeatable as `--header "Name: Value"`. Header-enforcing
    // origins (IPTV STB profiles, Referer-locked CDNs) had no CLI harness at all, so neither the
    // AVPlayer bypass nor the ingest reader could be driven against one from here.
    var playHeaders: [String: String] = [:]
    while let spec = takeStringFlag("--header", from: &rest) {
        guard let colon = spec.firstIndex(of: ":") else {
            print("ERROR: --header expects \"Name: Value\", got '\(spec)'")
            exit(64)
        }
        playHeaders[String(spec[..<colon]).trimmingCharacters(in: .whitespaces)] =
            String(spec[spec.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    // AE#551: warm the source before loading it, which is what a host does for the next episode.
    // Bare `--prewarm` takes the engine's default budget, `--prewarm-bytes N` names one. Measuring
    // this needs a real origin: against loopback the round trip it removes costs nothing to begin
    // with, which is the trap #281 was built out of.
    let prewarmRequested = takeFlag("--prewarm", from: &rest)
    let prewarmBytes = takeIntFlag("--prewarm-bytes", from: &rest)
    rejectStrayFlags(rest, subcommand: "play")
    if let playThrottleKbps {
        AetherEngine.setSourceThrottleKbpsForTesting(playThrottleKbps)
        print("[aetherctl] source throttle: \(playThrottleKbps) kbit/s (slow-CDN simulation)")
    }
    guard let urlArg = rest.first else {
        print("ERROR: play requires a <url> argument")
        print("")
        printUsage()
        exit(64)
    }
    if trustAnyCertificate {
        // The blunt answer the engine documents, which is the one a harness wants: every origin.
        EngineTLS.serverTrustEvaluator = { _ in true }
        print("[aetherctl] AE#495: accepting any server certificate for this run")
    }
    if prewarmRequested || prewarmBytes != nil {
        let target = parseSourceURL(urlArg)
        let budget = prewarmBytes ?? AetherEngine.defaultPrewarmByteBudget
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        Task {
            let report = await AetherEngine.prewarm(url: target, httpHeaders: playHeaders,
                                                    byteBudget: budget)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let declined = report.declined {
                print("[aetherctl] prewarm declined after \(ms)ms: \(declined)")
            } else {
                print("[aetherctl] prewarm retained \(report.retainedBytes)B of "
                      + "\(report.contentLength.map(String.init) ?? "?")B in \(ms)ms")
            }
            done.signal()
        }
        done.wait()
    }
    exit(runPlay(url: parseSourceURL(urlArg), seconds: seconds, live: live, nativeHLS: nativeHLS, liveIngest: liveIngest, fastZap: playFastZap, liveStartImmediately: liveStartImmediately, dvrWindow: dvrWindow, subsPick: subsPick, hostCalls: hostCalls, audioStats: audioStats, seekEvery: seekEvery, seekPattern: seekPattern, seekCount: seekCount, startPosition: playStartPosition, mallocCensus: mallocCensus, forceSoftware: playForceSW,
                 censusThresholdMB: censusThresholdMB, censusHz: censusHz, frameTimes: frameTimes, presentTimes: presentTimes, pictureProbe: pictureProbe, sidecars: sidecars,
                 audioSwitch: audioSwitch,
                 teletextPage: teletextPage, teletextSwitch: teletextSwitch,
                 audioDelayMs: audioDelayMs, audioDelaySwitches: audioDelaySwitches,
                 pausedMount: pausedMount,
                 optionCorrection: optionCorrection,
                 sequentialOrigin: sequentialOrigin, maxConcurrentRequests: maxConcurrentRequests,
                 heldConnection: heldConnection,
                 declaredDuration: declaredDuration,
                 httpHeaders: playHeaders,
                 deinterlaceFieldRate: playFieldRate,
                 assertDolbyVision: playAssertDV,
                 dolbyVisionHandling: playDVHandling,
                 record: playRecord))
}

if ["probe", "serve", "validate", "swdecode", "extract", "audio", "customio"].contains(first) {
    var rest = Array(args.dropFirst(2))
    let noDV = takeFlag("--no-dv", from: &rest)
    // AE#455: opt-in P8.1-as-P5 routing, which only has an effect alongside --no-dv.
    let forceDV = takeFlag("--force-dv", from: &rest)
    // The base layer of a Dolby Vision source, the Dolby Vision left out of the container.
    let dvHandling: DolbyVisionHandling = takeFlag("--dv-base-layer", from: &rest) ? .baseLayerOnly : .automatic
    let framesOverride = takeIntFlag("--frames", from: &rest)
    let atSeconds = takeDoubleFlag("--at", from: &rest) ?? 60.0
    let extractLoops = takeIntFlag("--loops", from: &rest) ?? 1
    let extractWidth = takeIntFlag("--width", from: &rest) ?? 320
    let snapshotMode = takeFlag("--snapshot", from: &rest)
    let inMemory = takeFlag("--memory", from: &rest)
    let forwardOnly = takeFlag("--forward-only", from: &rest)
    let customAudioIndex = takeIntFlag("--audio-index", from: &rest).map(Int32.init)
    let audioOnlyFlag = takeFlag("--audio-only", from: &rest)
    // AE#445: the custom-source live shape had no harness at all, so a retention question about it
    // could only be reasoned about. These four flags are the reporter's reader in parameters.
    let customLive = takeFlag("--live", from: &rest)
    let customRateKbps = takeIntFlag("--rate-kbps", from: &rest) ?? 8000
    let customDvrWindow = takeDoubleFlag("--dvr-window", from: &rest)
    let customReportsSize = takeFlag("--report-size", from: &rest)
    let customNoWrap = takeFlag("--no-wrap", from: &rest)
    let customMallocCensus = takeFlag("--malloc-census", from: &rest)
    // AE#445 round 2: the reader arm is the measurement's subject, so it is a flag rather than a
    // fixed choice. Default reads with pread and allocates nothing, which is the reporter's shape
    // and measures the ENGINE; --foundation-reader restores the FileHandle arm, which allocates one
    // autoreleased Data per read and is now the control that proves the bridge pool drains it.
    let customFoundationReader = takeFlag("--foundation-reader", from: &rest)
    // AE#445 round 3: a positive control for the reporter's own shape. removeFirst puts an
    // ingest-side Data carry back on the delivery path (bounded count, unbounded backing store);
    // subdata is the same carry re-based, i.e. the fix. Default none measures the engine alone.
    // AE#460 follow-up: fire an in-place option correction on the live spool N seconds in, so the
    // custom-source reload branch can be watched on a reader that has run past its base.
    let customReloadAt = takeDoubleFlag("--reload-at", from: &rest)
    // The non-conforming arm: a reader that reads `cancel()` as terminal, which is what a network
    // reader's in-flight-request cancel becomes. Contract says unblock only; this measures the cost
    // of the other reading rather than leaving it to be discovered on a host.
    let customCancelLatches = takeFlag("--cancel-latches", from: &rest)
    // AE#460 round 3: which byte axis the harness reader speaks. `join` is the reporter's shape (a
    // spool that counts from where its stream joined), `mismatched` the non-conforming control that
    // reports one axis and takes the other. `--join-offset-mb` is where in the file the join sits,
    // so the two axes are far enough apart for a disagreement to show as bytes rather than as noise.
    let customReaderAxis: ReaderAxis = takeStringFlag("--reader-axis", from: &rest).map { value in
        guard let axis = ReaderAxis(rawValue: value) else {
            print("ERROR: --reader-axis takes absolute|join|mismatched, got '\(value)'")
            exit(64)
        }
        return axis
    } ?? .absolute
    let customJoinOffsetMB = takeIntFlag("--join-offset-mb", from: &rest) ?? 4
    // AE#461 follow-up: drive the decode-path correction on a CUSTOM source. `--reload-at`'s own
    // correction (an httpHeaders probe) is inert on this shape by design, so it measures the rebuild
    // and cannot measure this field; this one is the field.
    let customReloadDecodePath: DecodePath? = takeStringFlag("--reload-decode-path", from: &rest).flatMap { value in
        guard let path = DecodePath(rawValue: value) else {
            print("ERROR: --reload-decode-path takes \(DecodePath.allCases.map(\.rawValue).joined(separator: "|")), got '\(value)'")
            exit(64)
        }
        return path
    }
    let customHostCarry = takeStringFlag("--host-carry", from: &rest) ?? "none"
    guard let customCarryTrim = HostCarryTrim(rawValue: customHostCarry) else {
        print("ERROR: --host-carry expects none|removeFirst|subdata, got '\(customHostCarry)'")
        exit(64)
    }
    let reloadFlag = takeFlag("--reload", from: &rest)
    let switchAudioFlag = takeFlag("--switch-audio", from: &rest)
    let selectSubsFlag = takeFlag("--select-subs", from: &rest)
    let extractFlag = takeFlag("--extract", from: &rest)
    let secondsFlag = takeDoubleFlag("--seconds", from: &rest)
    let audioSeconds = secondsFlag ?? 10
    // --native-subs: diagnostics affordance for mov_text subtitle track (#55); serve only.
    let nativeSubsIndex = takeIntFlag("--native-subs", from: &rest)
    // --throttle-kbps: slow-CDN simulation; starves the producer below real-time to provoke rebuffers.
    let throttleKbps = takeIntFlag("--throttle-kbps", from: &rest)
    // --start-position: anchor the first producer at a resume position like load(startPosition:) (#99); serve only.
    let startPosition = takeDoubleFlag("--start-position", from: &rest)
    // AE#464: park the server with an audio offset already in the muxer, so the delivered offset can
    // be read straight off the segments (ffprobe the audio and video first-packet PTS) instead of
    // being judged by ear.
    let serveAudioDelayMs = takeIntFlag("--audio-delay", from: &rest) ?? 0
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
        runServe(url: url, dvModeAvailable: dvModeAvailable, forceDVWithoutDisplay: forceDV,
                 dolbyVisionHandling: dvHandling,
                 nativeSubsIndex: nativeSubsIndex, startPosition: startPosition,
                 audioDelayMs: serveAudioDelayMs)
    case "validate":
        exit(runValidate(url: url, dvModeAvailable: dvModeAvailable, forceDVWithoutDisplay: forceDV,
                         dolbyVisionHandling: dvHandling))
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
        if customLive {
            exit(runCustomLiveSpool(path: urlArg, seconds: secondsFlag ?? 720, rateKbps: customRateKbps,
                                    dvrWindow: customDvrWindow, reportsSize: customReportsSize,
                                    wraps: !customNoWrap, mallocCensus: customMallocCensus,
                                    foundationReader: customFoundationReader,
                                    carryTrim: customCarryTrim, reloadAt: customReloadAt,
                                    cancelLatches: customCancelLatches,
                                    reloadDecodePath: customReloadDecodePath,
                                    axis: customReaderAxis, joinOffsetMB: customJoinOffsetMB))
        }
        exit(runCustomIO(path: urlArg, inMemory: inMemory, forwardOnly: forwardOnly, audioOnly: audioOnlyFlag, reload: reloadFlag, switchAudio: switchAudioFlag, selectSubs: selectSubsFlag, extract: extractFlag, audioIndex: customAudioIndex, reloadDecodePath: customReloadDecodePath))
    default:
        printUsage()
        exit(64)
    }
}

// Bare URL: backwards-compat alias for `serve`.
let url = parseSourceURL(first)
runServe(url: url, dvModeAvailable: true)
