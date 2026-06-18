# aetherctl

A standalone macOS CLI shipped alongside the library for repro work without going through TestFlight + Apple TV. Most subcommands operate on a media source URL (`file://` or `http(s)://`); `live`, `dvr`, and `hlsfixture` run against built-in synthetic fixtures.

```bash
swift run aetherctl probe <url>          # dump container + streams + duration, exit
swift run aetherctl serve <url>          # park the engine's loopback HLS-fMP4 server
swift run aetherctl validate <url>       # serve + run mediastreamvalidator, exit
swift run aetherctl swdecode <url>       # open SoftwareVideoDecoder, decode N packets, report
swift run aetherctl dovitest <url>       # convert a DV Profile 7 stream to 8.1, dump for dovi_tool
swift run aetherctl extract <url>        # FrameExtractor still-image extraction + leak testing
swift run aetherctl audio [--seconds N] <url>   # audio-only pipeline smoke test (default 10 s)
swift run aetherctl customio <path>      # exercise the custom IOReader path end-to-end
swift run aetherctl live                 # live MPEG-TS session against the built-in fixture
swift run aetherctl dvr                  # DVR rewind matrix across native + SW paths
swift run aetherctl hlsfixture <ts>      # local HLS live fixture with fault knobs + ingest self-test
swift run aetherctl seektest <url>       # rapid-seek burst repro + clock-bounce / isSeeking probe
swift run aetherctl hlslive              # SSAI live-direct-play repro against a synthetic ad-pod feed
swift run aetherctl smbtest <smb-url>    # play a file off an SMB2/3 share via the AetherEngineSMB reader
swift run aetherctl <url>                # alias for serve (backwards compat)
```

Fourteen subcommands plus the bare-URL `serve` alias.

## probe

Opens the demuxer, prints the codec / resolution / frame rate of the video track, the audio track list (codec, channels, language, Atmos flag), the subtitle track list, the parsed container metadata (`MediaMetadata`: title / artist / album / albumArtist + embedded cover art presence), then exits. No HLS server is started.

## serve

The original behavior. The CLI prints the loopback URL and parks until Ctrl-C; from another terminal you can:

```bash
curl -i  http://127.0.0.1:<port>/master.m3u8
curl -o  /tmp/init.mp4   http://127.0.0.1:<port>/init.mp4
mediastreamvalidator http://127.0.0.1:<port>/master.m3u8
mp4dump --verbosity 1 /tmp/init.mp4
ffprobe -v debug /tmp/seg0.mp4
open 'http://127.0.0.1:<port>/master.m3u8'   # macOS QuickTime
```

`--no-dv` forces the SDR / HDR10 route even for a Dolby Vision source (compare the two playlists).

## validate

`serve` plus an inline `xcrun mediastreamvalidator` run against the loopback manifest, with the report printed and the engine torn down on completion.

## swdecode

Opens `SoftwareVideoDecoder` for the source's video stream, feeds up to N packets (default 100, override with `--frames N`), and reports counters plus first-frame metadata (pixel format, dimensions). Tests the SW-pipeline decode path end-to-end without needing a render layer. Useful for legacy codecs (MPEG-4 Part 2, MPEG-2, VC-1) and AV1 / VP9 on platforms where the native AVPlayer path doesn't accept them. Verdict distinguishes three failure modes:

- decoder open failed (FFmpegBuild gate or malformed extradata)
- decoder opened but no frames produced (pixel-format conversion, no IDR in window)
- SW decode end-to-end healthy (if real playback still hangs, the failure is downstream in `SoftwarePlaybackHost` frame-enqueue, display-layer attach, or audio-clock sync)

Backed by the public `AetherEngine.swDecodeProbe(url:maxPackets:options:)` static API returning `SoftwareDecodeProbeResult`. Hosts can use the same probe in their own diagnostic overlays.

## dovitest

Runs the Dolby Vision Profile 7 to 8.1 converter over every video packet of the source and writes the converted elementary stream (Annex B) to `/tmp/aetherctl-dovitest.hevc`, reporting packets processed, conversions, and failures. Lets you confirm the in-engine `DoviRpuConverter` (libdovi) output matches the `dovi_tool -m 2` ground truth offline, without a DV panel:

```bash
swift run aetherctl dovitest <p7-source>
dovi_tool extract-rpu -i /tmp/aetherctl-dovitest.hevc -o out.rpu
dovi_tool info -i out.rpu -f 0   # expect dovi_profile 8, disable_residual_flag true
```

## extract

Opens a `FrameExtractor` against the source and pulls a still frame. Thumbnail mode (default) snaps to the nearest keyframe and downscales to `--width` (default 320); `--snapshot` decodes frame-accurately at full resolution. `--at <sec>` sets the seek position (default 60.0). The first frame is written to `/tmp/aetherctl-extract-<mode>.png`. `--loops N` repeats the extraction across eight cycling positions, which pairs with `leaks --atExit` to validate the decode-context teardown is clean:

```bash
swift run aetherctl extract --at 612 --snapshot <url>          # frame-accurate still
swift run aetherctl extract --width 480 <url>                  # keyframe thumbnail
leaks --atExit -- .build/debug/aetherctl extract --loops 8 <url>   # leak sweep
```

## audio

Plays a source through the audio-only pipeline (default ten seconds, `--seconds N` to override) and reports which host took it (bare AVPlayer vs the FFmpeg renderer path), exercising the same dispatch a music host sees.

## customio

Wraps a local file in a custom `IOReader` and plays it through `load(source:)`. `--memory` reads via `DataIOReader`, `--forward-only` drops the seek capability, and `--reload` / `--switch-audio` / `--select-subs` / `--extract` exercise the optional capabilities (background reload, audio-track switch, embedded subtitles, scrub preview) end-to-end.

## live

Runs a live MPEG-TS session against a built-in fixture that serves an endless broadcast by looping a seed `.ts` with rewritten timestamps. Flags simulate the failure modes the live path hardens against: `--drop-after N` (mid-stream connection drop + reconnect), `--discontinuity-at N` (program-boundary PTS / PCR jump), `--realtime` (1x wall-clock pacing), `--dvr-window N` (timeshift), `--measure-rss` (sliding-window retention), `--reload-test` (live rejoin end to end, including the full-backlog replay shape some origins serve on reconnect). `--seed <ts>` overrides the seed clip, `--sw` forces the software live path, `--report-cache-bytes` tracks on-disk DVR footprint.

## dvr

Runs the rewind matrix across the native and SW paths (`--path native|sw|both`). `--seconds N` and `--dvr-window N` size the run.

## hlsfixture

Slices a local `.ts` into a sliding live HLS playlist and serves it over loopback, with fault knobs (`--master` indirection, `--discontinuity-at`, `--slow-refresh`, `--drop-segment`, `--encrypted`, `--fmp4`, `--port`, `--segment-seconds`) and a `--self-test` mode that runs `HLSLiveIngestReader` against it end to end.

## seektest

Drives a real AVPlayer (native loopback-HLS path) through a burst of rapid seeks and reports the producer-restart coalescing behavior, the longest "wedge" (state `.playing` but the clock frozen), and final settle accuracy (AetherEngine#35). A concurrent sampler probe also checks the seek clock-bounce / `isSeeking` signal (AetherEngine#37 / #38): a single backward seek must not bounce the clock back through the pre-seek position, and `isSeeking` must span the real landing. `--seeks N`, `--gap-ms N`, `--settle N` shape the burst; needs `> 30 s` of seekable VOD.

## hlslive

Replays a synthetic SSAI ad-pod feed through the live-direct-play path to repro the FAST-channel ad-break handling (program-switch detection, muxer rotation with versioned `#EXT-X-MAP`, audio re-anchor, no-cut watchdog). `--segments N`, `--seconds N`, `--segment-seconds N` size the run; `--disc` injects discontinuities at the ad boundaries.

## smbtest

Connects to an SMB2/3 share with `SMBConnection` (AMSMB2 backend), wraps the file in `SMBIOReader`, and runs a sequential-throughput pass plus a random-seek consistency check. macOS-only; needs the optional `AetherEngineSMB` product (`swift build --product aetherctl` pulls it in). Validates the SMB byte source without a device:

```bash
swift run aetherctl smbtest "smb://user:pass@host/share/path/to/file.mkv" --reads 128
```

`--reads N` sets the random-seek count (default 64). Credentials default to guest when omitted from the URL; URL-encode special characters in the password.

## Fixtures

For repeatable runs, `Scripts/fetch-fixtures.sh` generates a small set of synthetic FFmpeg test clips in `./Fixtures/` (H.264 SDR, HEVC HDR10, AV1, VP9) covering both the native AVPlayer path and the software fallback. Real-world DV / Atmos / multichannel sources go in `./Fixtures/user/` (gitignored).
