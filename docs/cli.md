# aetherctl

`aetherctl` is a macOS command-line tool that ships with the library. It runs the real engine headless, so you can reproduce a playback problem on a Mac instead of going through TestFlight and an Apple TV. This page lists every subcommand, its flags and defaults, and what its output means.

**Contents**

- [Building with optional components](#building-with-optional-components)
- [Subcommands at a glance](#subcommands-at-a-glance)
- Inspect a source: [probe](#probe), [pktdump](#pktdump), [disc-inspect](#disc-inspect)
- Serve over loopback HLS: [serve](#serve), [validate](#validate), [segverify](#segverify)
- Play and measure: [play](#play), [swdecode](#swdecode), [seektest](#seektest), [extract](#extract), [scrubpreview](#scrubpreview), [dualsubs](#dualsubs), [audio](#audio), [audiotap](#audiotap), [bgaudio](#bgaudio)
- Custom byte sources: [customio](#customio), [smbtest](#smbtest)
- Live: [live](#live), [dvr](#dvr), [hlsfixture](#hlsfixture), [hlslive](#hlslive)
- Dolby Vision: [dovitest](#dovitest), [feltest](#feltest), [dvsurvey](#dvsurvey), [eltype](#eltype), [elsurvey](#elsurvey), [elframe](#elframe), [felcurves](#felcurves), [dmpass](#dmpass)
- [Fixtures](#fixtures)

## Building with optional components

`aetherctl` builds with the package's traits. The optional components ([Installation › Optional components](installation.md#optional-components)) are in it only when you build it with them:

```bash
swift run --traits TrueHDObjectAudio,DTSXObjectAudio,DualLayerDolbyVision,DolbyVisionStillReshaping aetherctl …
```

| Trait | Needed for |
|---|---|
| `TrueHDObjectAudio`, `DTSXObjectAudio` | `--atmos-bed` |
| `DualLayerDolbyVision` | `play --fel`, `--cycle-el`, `--dv-pin`, `feltest`, `elsurvey`, `elframe`, `dmpass` |
| `DolbyVisionStillReshaping` | Profile 5 / 10.0 stills in `extract` and `play --host-calls` (without it those stills print as nil) |
| `DolbyVisionFelCurves` | `felcurves` |

Some drills (`bgaudio`, `play --host-calls stallclock`, `play --dv-pin`) use DEBUG-only engine hooks. Build a debug binary for them with `swift build --product aetherctl`.

Most subcommands take a media source URL (`file://` or `http(s)://`). `live`, `dvr`, `hlsfixture` and `hlslive` run against built-in synthetic fixtures.

## Subcommands at a glance

Twenty-nine subcommands plus the bare-URL `serve` alias.

| Subcommand | Purpose |
|---|---|
| [`probe <url>`](#probe) | Dump container, streams and duration, then exit. |
| [`pktdump <url>`](#pktdump) | Dump raw demuxer packet timing (dts / pts / keyframe) per open profile. |
| [`disc-inspect <path>`](#disc-inspect) | Walk a local DVD / Blu-ray ISO: titles, chapters, recognition stages. |
| [`serve <url>`](#serve) | Park the engine's loopback HLS-fMP4 server. |
| [`validate <url>`](#validate) | Serve, run `mediastreamvalidator`, exit. |
| [`segverify <url>`](#segverify) | SW-decode each loopback segment in isolation and report independence (#92). |
| [`play <url>`](#play) | Full load + play session smoke test: 1 Hz telemetry, cue log, host-call mimicry. |
| [`swdecode <url>`](#swdecode) | Open `SoftwareVideoDecoder`, decode N packets, report. |
| [`seektest <url>`](#seektest) | Rapid-seek burst repro plus clock-bounce / `isSeeking` probe. |
| [`extract <url>`](#extract) | `FrameExtractor` still-image extraction and leak testing. |
| [`scrubpreview <url>`](#scrubpreview) | Dolby Vision Profile 5 / 10.0 compositor scrub previews, resident and from the source. |
| [`dualsubs <file> ...`](#dualsubs) | Dual subtitle-track render probe (`--primary` / `--secondary` stream index). |
| [`audio [--seconds N] <url>`](#audio) | Audio-only pipeline smoke test (default 10 s). |
| [`audiotap <url>`](#audiotap) | Decode the PCM audio tap headless and write a mono 48 kHz WAV (#95). |
| [`bgaudio <url>`](#bgaudio) | SW-path background-audio keepalive probe (iOS background behavior). |
| [`customio <path>`](#customio) | Exercise the custom `IOReader` path end to end. |
| [`smbtest <smb-url>`](#smbtest) | Play a file off an SMB2/3 share through the `AetherEngineSMB` reader. |
| [`live`](#live) | Live MPEG-TS session against the built-in fixture. |
| [`dvr`](#dvr) | DVR rewind matrix across the native and SW paths. |
| [`hlsfixture <ts>`](#hlsfixture) | Local HLS live fixture with fault knobs and an ingest self-test. |
| [`hlslive`](#hlslive) | SSAI live-direct-play repro against a synthetic ad-pod feed. |
| [`dovitest <url>`](#dovitest) | Convert a DV Profile 7 stream to 8.1 and dump it for `dovi_tool`. |
| [`feltest <url>`](#feltest) | Test Dolby Vision Profile 7 FEL dual-layer Metal reconstruction. |
| [`dvsurvey <url>`](#dvsurvey) | Survey per-frame Dolby Vision L1 / L2 metadata and pick a `--dv-pin` frame. |
| [`eltype`](#eltype) | Tell FEL from MEL for a list of Profile 7 sources on stdin. |
| [`elsurvey`](#elsurvey) | Measure what each title's enhancement layer does to the picture. |
| [`elframe <url>`](#elframe) | Write one FEL keyframe composed with and without its residual. |
| [`felcurves <url> <out.rpu>`](#felcurves) | Fold a FEL source into per-scene Profile 8.1 curves. |
| [`dmpass <url>`](#dmpass) | Check that the FEL route keeps the display-management metadata. |
| `<url>` | Alias for `serve` (backwards compatibility). |

```bash
swift run aetherctl probe <url>
swift run aetherctl play <url>
swift run aetherctl <url>                # same as serve
```

## probe

Opens the demuxer, prints what it finds, then exits. No HLS server is started. It prints:

- the video track's codec, resolution and frame rate,
- the audio track list (codec, channels, language, Atmos flag),
- the subtitle track list,
- the parsed container metadata (`MediaMetadata`: title / artist / album / albumArtist, and whether embedded cover art is present).

**Usage:** `aetherctl probe [--detect-hdr10plus] [--detect-hdr-vivid] [--detect-dv-el] [--detect-atmos] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--detect-hdr10plus` | Adds the HDR10+ detail pass of `AetherEngine.probe(url:detecting:)`. | off |
| `--detect-atmos` | Adds the Atmos detail pass. | off |
| `--detect-hdr-vivid` | Adds the HDR Vivid (CUVA) check to the same packet pass. Prints `HDR Vivid: CUVA metadata seen`. | off |
| `--detect-dv-el` | Adds the Dolby Vision enhancement-layer check to the same packet pass (#1030). Prints `DV EL: FEL` or `DV EL: MEL`; `not Profile 7` when the container declares no Profile 7, `no RPU seen` when none turned up in the budget. | off |

```bash
swift run aetherctl probe --detect-hdr10plus /path/to/hdr10plus.mkv
```

Notes:

- The detail flags can be combined. They share one open and one connection.
- HDR10+ is the one to watch. The bare `probe` reads only what the container declares, and ST 2094-40 is declared nowhere. So a source that carries it prints `format: hdr10` without the flag, and `format: hdr10Plus` plus `HDR10+: ST 2094-40 metadata seen` with it.
- `not seen` means "not inside the scan budget", not "proven absent".
- With `--detect-hdr-vivid`, `format:` stays `hlg` / `hdr10`, because Vivid rides on that base (#699).

**Fixtures.** `Scripts/make-hdr10plus-fixture.py <dir>` builds a ~1 KB HEVC/PQ fixture that carries a real ST 2094-40 T.35 SEI, and prints it as base64 (that is how the two fixtures embedded in `HDR10PlusProbeIntegrationTests` were made). It checks itself: it only writes the file when `ffprobe -show_frames` reports `HDR Dynamic Metadata SMPTE2094-40` on it, so the payload is one FFmpeg's own parser accepts, not a byte pattern that merely looks like one. With `--vivid` it builds an HEVC/HLG fixture carrying a CUVA HDR Vivid SEI instead, checked the same way against ffprobe's `CUVA` side data (the fixture in `HDRVividProbeTests`).

## pktdump

Opens the demuxer under a chosen open profile, optionally seeks, and dumps raw video packet timing exactly as the demuxer delivers it. That is before any producer-side dts repair and before muxing. It prints:

- per-packet samples of dts / pts / duration / keyframe flag,
- counts of NOPTS and non-monotonic dts,
- dts-delta and duration histograms,
- the stream fields that `find_stream_info` fills (`avg_frame_rate`, `codecpar.video_delay`).

**Usage:** `aetherctl pktdump [--at S] [--count N] [--profile playback|restartReopen|stillExtraction] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--at S` | Seek to S seconds first. | 0 |
| `--count N` | Packets to dump. | 200 |
| `--profile P` | Open profile: `playback`, `restartReopen` or `stillExtraction`. `stillExtraction` is the one `FrameExtractor` uses (a short-range AVIO with its own thread count). | `playback` |

```bash
swift run aetherctl pktdump --at 660 --count 300 --profile playback        <url>
swift run aetherctl pktdump --at 660 --count 300 --profile restartReopen   <url>
swift run aetherctl pktdump --at 660 --count 300 --profile stillExtraction <url>
```

**Reading it.** Compare profiles. If one profile shows `video_delay=0` plus NOPTS or non-monotonic dts while another is clean, that profile's open path cannot rebuild decode-order dts for B-frame content. That was the root cause of the #93 post-recovery judder. Use `stillExtraction` to compare what a still-extraction open resolves against what playback resolves.

Backed by the public `PacketTimingProbe.run(url:seekSeconds:packetCount:profileName:)`.

## disc-inspect

Walks a local DVD-Video or Blu-ray ISO at the filesystem layer (no FFmpeg) and reports what `DiscReader.wrap` makes of it. A disc that fails to play becomes debuggable instead of surfacing a bare `INVALIDDATA`.

It prints:

- the recognition verdict and the stages it went through (ISO9660 / UDF signatures, BDMV / VIDEO_TS contents, resolved extents),
- the full selectable-title list with each title's duration and chapter offsets (the same titles and chapters the engine exposes through `discTitles` / `discChapters`),
- the track languages the disc's navigation data declares per title, keyed by stream id (MPEG-TS PID on Blu-ray, MPEG-PS stream / substream id on DVD). A title with no `languages:` line declares none, which is why its tracks stay undetermined.

**Usage:** `aetherctl disc-inspect [--dump] <disc.iso>`

| Flag | Meaning | Default |
|---|---|---|
| `--dump` | Adds the verbose UDF volume structure under the `.demux` log. | off |

Exit 0 when the image is recognized as playable, else 1.

## serve

Starts the engine and parks the loopback HLS server until Ctrl-C. This is the original behavior of the tool.

**Usage:** `aetherctl serve [flags] <url>` (or just `aetherctl <url>`)

The CLI prints the loopback URL under `=== PLAYBACK URL ===`. The server listens on all interfaces, so an AirPlay receiver can reach it. It answers only paths that start with a per-session token; anything else is a 404. So the printed URL carries the token: `http://127.0.0.1:<port>/<token>/...`. Copy the `<port>/<token>` prefix from that line, then from another terminal:

```bash
curl -i  http://127.0.0.1:<port>/<token>/master.m3u8
curl -o  /tmp/init.mp4   http://127.0.0.1:<port>/<token>/init.mp4
mediastreamvalidator http://127.0.0.1:<port>/<token>/master.m3u8
mp4dump --verbosity 1 /tmp/init.mp4
curl -o  /tmp/seg0.mp4   http://127.0.0.1:<port>/<token>/seg0.mp4
ffprobe -v debug /tmp/seg0.mp4
open 'http://127.0.0.1:<port>/<token>/master.m3u8'   # macOS QuickTime
```

| Flag | Meaning | Default |
|---|---|---|
| `--no-dv` | Forces the SDR / HDR10 route even for a Dolby Vision source. | off |
| `--force-dv` | `LoadOptions.forceDolbyVisionOnNonDVDisplay` (AE#455). Works only together with `--no-dv`. | off |
| `--dv-base-layer` | `LoadOptions.dolbyVisionHandling = .baseLayerOnly`. | off |
| `--native-subs <index>` | Turns on the native WebVTT subtitle renditions. `<index>` is ignored. | off |
| `--iframes` | Lists an I-frame rendition in the master (AE#682). | off |
| `--start-position S` | Starts the session at S seconds. | 0 |
| `--throttle-kbps N` | TEST-ONLY: caps source-IO delivery to N kbit/s. | no cap |
| `--atmos-bed <layout>` | Renders TrueHD Atmos or DTS:X into a speaker bed. | off |
| `--bed-format apac\|lpcm` | How the bed is delivered. | `apac` |
| `--audio-index <n>` | Serves source audio stream `n`. | engine choice |
| `--stereo auto\|mono\|sbs\|ou` | `LoadOptions.stereoPresentation` for a 3D source. | what this system gets |
| `--audio-delay <ms>` | Parks the server with the AE#464 audio offset in its muxer. | 0 |

Flags shared with other subcommands: `--force-dv` also works on `validate` and `segverify`. `--dv-base-layer` also works on `validate`, `segverify` and `play`. `--throttle-kbps` also works on `seektest`, `play` and `scrubpreview`. `--start-position` also works on `play` and `live`.

### Dolby Vision routes

**`--no-dv`** forces the SDR / HDR10 route. Serve the same file with and without it and compare the two playlists.

**`--force-dv`** serves a Profile 8.1 source as Profile 5 (AE#455). The master then reads `CODECS="dvh1.05.LL"`, and `init.mp4` carries a `dvh1` sample entry with a `dvcC` claiming profile 5. It only has an effect together with `--no-dv`. To see the sample entry and the record move, serve the same file twice and diff `mp4dump --verbosity 1 init.mp4`.

**`--dv-base-layer`** serves a Dolby Vision source that has a presentable base layer as that base layer alone. The master then reads a plain `hvc1` / `av01` `CODECS` with no `SUPPLEMENTAL-CODECS`, and `init.mp4` carries no `dvcC`. It is independent of `--no-dv`, and it wins over `--force-dv`.

It is the harness for a Profile 5 record that the bitstream contradicts (a relabelled Profile 7 remux):

- `probe` shows the record and the VUI side by side.
- `serve` logs `DV Profile 5 record over a BT.2020 YCbCr VUI` on the default route, and `presenting the ... base layer only` with the flag.
- `play --reload-applying dolby-vision=baseLayerOnly` applies it to a playing session through #460.

**The AE#532 record audit.** `serve`, `validate` and `segverify` run this audit before they build the engine, the same way a session runs it off its own probe. A Profile 5 record over a BT.2020 YCbCr PQ or HLG VUI has its first RPU read, and the route follows the RPU, not the record (`AE#532: DV Profile 5 record contradicted by its own RPU`). Every other source is opened, found uncontradicted and left alone. To see both halves on one file, serve it twice and diff: the default route now reads `CODECS="hvc1.2.4.LXX"` with a DV `SUPPLEMENTAL-CODECS` where it used to read `dvh1.05.LL`, and `--dv-base-layer` still overrides both.

### Native subtitle renditions (`--native-subs`)

`--native-subs <index>` turns on the native WebVTT subtitle renditions. This is the `LoadOptions.prepareNativeSubtitles` path a full session uses: the engine calls `requestNativeSubtitleTrack()` before `start()`, then `attachAllNativeSubtitleStores()` after start.

What you get:

- Every non-bitmap text track is served as a language-tagged `EXT-X-MEDIA:TYPE=SUBTITLES` rendition (`DEFAULT=NO,AUTOSELECT=NO`) in the master playlist.
- Each rendition is backed by a per-track `subs_N.m3u8` WebVTT media playlist.

The `<index>` value is legacy and ignored. It stays only for CLI compatibility. Every non-bitmap track is always declared, and real track selection happens through the host API in a full session, not through this flag.

To check: `curl` the `master.m3u8` (or open it in QuickTime) and confirm the `SUBTITLES` group and the `subs_N.m3u8` endpoints list every language as a legible `AVMediaSelection` group. Without the flag you get the default behavior: no renditions, output identical to before.

History: an earlier design muxed `mov_text`/tx3g traks into the fMP4. In-band timed text is not HLS-conformant and AVPlayer rejected it, so the WebVTT rendition replaced it. See [formats.md › Native subtitle renditions](formats.md#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display).

### I-frame rendition (`--iframes`)

`--iframes` lists an I-frame rendition in the master. This is the `LoadOptions.serveIFramePlaylist` path a full session uses (AE#682): the engine calls `requestIFramePlaylist()` before `start()`.

The master then carries `#EXT-X-I-FRAME-STREAM-INF`, and the server answers `iframe.m3u8`, `iframe_init.mp4` and `iframe<N>.mp4`, one still per segment:

- SDR: the source's keyframe.
- HDR and Dolby Vision: a tone-mapped Motion JPEG (`CODECS="mjpg"`).

The log line says which it was: `[HLSVideoEngine] i-frame rendition: served segments=<n> format=keyframes|jpeg`, or `absent reason=<reason>`. `curl` the playlist and a fragment next to the printed playback URL to look at them.

### Throttle and start position

**`--throttle-kbps N`** is a TEST-ONLY slow-CDN simulation. It caps source-IO delivery to N kbit/s. Set it below the stream bitrate to starve the producer below real time and provoke AVPlayer rebuffers (for example the #92 open-GOP repro). Also available on `seektest` and `play`.

**`--start-position S`** starts the session at S seconds. This is the resume anchor a host passes to `load(url:startPosition:)`. Also available on `play`.

### Object audio (`--atmos-bed`)

`--atmos-bed <layout>` sets `LoadOptions.objectAudioRendering = .apac(layout)`. A TrueHD Atmos or DTS:X track is rendered into that bed and served as APAC. Layouts: `5.1.2`, `5.1.4`, `7.1.2`, `7.1.4` or `9.1.6` (#731, #744). It renders only in a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` traits.

- The master reads `CODECS="…,apac.31.03"` (up to 12 channels) or `apac.31.04` (16).
- The log carries `TrueHD Atmos: objects rendered into …` (or `DTS:X: bed and heights routed one to one into …`) and the `[SpatialAudioBridge] bed levels` lines.
- A DTS-HD MA track whose frames do not decode as DTS:X logs `DTS-HD MA track is not DTS:X this engine renders (…); keeping the channel bridge` instead.

With `--bed-format lpcm` it sets `.lpcm(layout)` instead, which serves the bed as 24-bit PCM (`CODECS="…,ipcm"`, log `delivered as ipcm (lossless 24-bit PCM)`).

`--audio-index <n>` serves source stream `n`, the way a host's audio picker would. Example with Dolby's Unfold demo, whose TrueHD Atmos track is stream 1:

```bash
aetherctl serve --no-dv --atmos-bed 7.1.4 --audio-index 1 unfold.m2ts
```

### Stereo 3D (`--stereo`)

`--stereo auto|mono|sbs|ou` serves a 3D source the way visionOS gets it, from any system (`LoadOptions.stereoPresentation`):

- `auto` keeps an MV-HEVC stream's second view (`lhvC` in the init), or presents the frame packing a Matroska `StereoMode` declares.
- `sbs` / `ou` say what a file's name says.
- `mono` plays it 2D.

The log's `[HLSVideoEngine] stereo:` line names what was chosen and why. A stereo master carries `REQ-VIDEO-LAYOUT="CH-STEREO"` at `EXT-X-VERSION:12`, and a packed HEVC init carries a `vexu` with `eyes` and `pack`. H.264 stays 2D, because AVPlayer refuses it packed over HLS. Without the flag the session is what this system gets: 2D everywhere except visionOS.

### Audio delay (`--audio-delay`)

`--audio-delay <ms>` parks the server with the AE#464 audio offset already in its muxer. This measures the DELIVERED offset instead of arguing about it:

1. Fetch the media playlist and walk its segments.
2. Read the first audio and video packet timestamps out of `init.mp4` plus a segment with `ffprobe -show_entries packet=stream_index,pts_time`.

On a 30 fps H.264 + AAC fixture the source's own alignment is +21.8 ms. `--audio-delay 200` reads +221.8 ms and `--audio-delay -150` reads -128.2 ms, exactly the offset asked for. The video timestamp is unchanged in every arm.

## validate

Runs `serve`, then runs `xcrun mediastreamvalidator` against the loopback manifest, prints the report, and tears the engine down. Needs Xcode (`xcrun`) on the PATH.

**Usage:** `aetherctl validate [--no-dv] [--force-dv] [--dv-base-layer] <url>`

The flags mean the same as on [serve](#dolby-vision-routes). `validate` also runs the AE#532 record audit first.

## segverify

Checks that every loopback segment can be decoded on its own. It fetches `init.mp4`, then each media segment in turn, and SW-decodes each segment **in isolation**: a fresh decoder per segment, no carried reference frames. It reports how many are independently decodable.

A segment that yields `framesDecoded == 0` is not self-contained. Its first sample is not an IRAP (a random-access picture), so it depends on a predecessor. That is the open-GOP / B-frame boundary defect (#92). This is the ground-truth check the #92 fix was validated against (ffmpeg's `hls` muxer scores every segment independent).

**Usage:** `aetherctl segverify [--from N] [--count K] [--no-dv] [--force-dv] [--dv-base-layer] [--dump <dir>] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--from N` | First segment to test. | 0 |
| `--count K` | Number of segments to test. | 12 |
| `--no-dv` | Forces the SDR route. | off |
| `--force-dv`, `--dv-base-layer` | As on [serve](#dolby-vision-routes). | off |
| `--dump <dir>` | Writes each fetched segment for offline inspection. | off |

Exit 0 when every tested segment is independent, 2 when any is not.

**Checking contiguity.** `--dump` also feeds `Scripts/segment-spans.py`, which answers the neighbouring question: not whether each segment stands alone, but whether the run of them is contiguous. For every `moof` it prints `[tfdt, tfdt + sum(sample_duration)]` per track, and flags any gap or overlap against the previous segment of the same track.

```bash
swift run aetherctl segverify --from 0 --count 12 --dump /tmp/segs <url>
python3 Scripts/segment-spans.py /tmp/segs/segverify_seg{0..11}.mp4
```

A healthy run prints `contiguous` on every line. AE#561 is the case it exists for: a reported session where seg7's video ran to 34.034 s while seg8 opened at 33.492 s, half a second of overlap. Segments grabbed bare with curl carry no `moov`, so prepend `init.mp4` before passing them in.

## play

Runs a full `load()` + `play()` session exactly like a host app and prints 1 Hz transport telemetry. Where `swdecode` proves the decoder, `play` proves the transport. It fails loudly on the silent failures of a session that "loads fine" but never actually plays (#107).

**Usage:** `aetherctl play [flags] <url>`

```bash
swift run aetherctl play <url>                                  # VOD load, 30 s telemetry
swift run aetherctl play --seconds 60 <url>                     # longer window
swift run aetherctl play --live --dvr-window 1800 <url>         # live path with a DVR ring
swift run aetherctl play --subs teletext <url>                  # activate the first matching subtitle track, log every cue + trim
swift run aetherctl play --host-calls reloadlive,play,extractor,setrate <url>   # mimic a host's post-load call sequence
swift run aetherctl play --live --dvr-window 1800 --audio-stats <url>           # decoded-PCM continuity + per-second audio lead
swift run aetherctl play --live --native-hls <master.m3u8>      # nativeRemoteHLS bypass (carriage watchdog + #293 probe)
swift run aetherctl play --sidecar de=/tmp/de.srt --subs de <master.m3u8>   # declare a sidecar at load (#316)
swift run aetherctl play --native-hls --trust-any-certificate <https master.m3u8>  # the AE#495 origin relay
swift run aetherctl play --atmos-bed 7.1.4 <truehd-atmos.mkv>  # render TrueHD Atmos or DTS:X into a bed as APAC (LoadOptions.objectAudioRendering); the 1 Hz line adds obj=<active>/<declared> up=<overhead> bed=<layout>, and hch=<n> for height channels
swift run aetherctl play --fel <p7-file.mkv>                    # opt in to the Profile 7 FEL dual-layer route (off by default, like LoadOptions.preferDualLayerDolbyVision)
swift run aetherctl play --fel --fel-output <p7-file.mkv>      # compose it on AVPlayer's frames instead (LoadOptions.dualLayerRoute = .avPlayerOutput)
swift run aetherctl play --fel --surface --cycle-el 10 <p7-file.mkv>   # flip the residual off and on every 10 s over a visible window (--window is the same flag)
swift run aetherctl play --fel --surface --dv-pin 'darkest:240,period:2' <url>   # DEBUG: pulse a pinned frame's DV metadata (from dvsurvey)
swift run aetherctl play --upscale <sd-or-720p-url>           # opt in to upscaling sub-1080p SDR video to the display (LoadOptions.upscalesLowResolutionVideo, #846); logs one [Upscale] line and an UPSCALE line once the first frame is upscaled
```

### Telemetry

Each 1 Hz line shows the transport state: state, phase, currentTime, sourceTime, buffered frontier and duration. It also shows the network half of the same `liveTelemetry` snapshot a host reads:

| Field | Meaning |
|---|---|
| `net` | Throughput. |
| `rx` | What the playback consumer pulled over its own link. |
| `origin` | What the session pulled from the SOURCE. |
| `ahead` | Fetched but not yet consumed. |
| `cushion` | Decoded video past the clock (software path). |
| `fwd` | Native forward buffer (native path). |
| `drop` / `delay` | Dropped and delayed frames. |

Things to know when reading them:

- Fields absent on the running path are omitted. A software session shows `cushion` where a native one shows `fwd`.
- `drop` climbs steadily in a CLI run. Nothing binds a render surface, so the renderer drops what it cannot present.
- `rx` and `origin` are two different links and often disagree. On the native path `rx` counts what AVPlayer fetched from the engine's own loopback server. A live session whose source has gone quiet can keep raising `rx` out of the segment cache while `origin` stays flat. An origin question is an `origin` question (AE#443, where a fall in `rx` was misread as an origin socket event).
- Both `rx` and `origin` are session totals. They are summed across AVFoundation's access-log entries and across the subsystems a live reopen replaces, so neither falls back mid-session.

Other lines `play` prints:

- **`PHASE <phase> t+Ns`** on every `playbackPhase` edge, stamped from the load call on the same clock as `FIRSTFRAME`. The 1 Hz tick only samples the phase, which is far too coarse to tell a start signal from the moment the rate rolls. A healthy native join is exactly two edges: `loading` at the load and `playing` at the roll (AE#440).
- **`ESCALATION at <s> duringStartup=<bool> absorbed=<domain>/<code> <kind>`** whenever the AE#561 rebuild onto the software path is taken.
- **`subtitle tracks`** at the end of the run: the settled list a host's picker would show, with `*` marking external ids.

### Exit codes and verdicts

| Exit | Meaning |
|---|---|
| 0 | `VERDICT: OK`. |
| 2 | The clock does not advance. |
| 2 | A native session with a video track runs its clock but never has a frame ready for display (black picture with audio, #938). |
| 2 | A resume lands more than a second behind its anchor: `VERDICT: resume clock fell behind its anchor` (AE#724, see [Resume landing](#resume-landing-ae724)). |
| 2 | The session goes to `.error` (for example the declining arm of `--no-sw-escalation`). |
| 3 | A selected subtitle track produces no cues. |
| 3 | A requested `--record` was refused, produced no bytes, or ended `.failed`. |
| 4 | An `overlapseek` drill failed, or a reload drill (`pausereload`, `playreload`, `extplayreload`) moved the clock when it should not or stood still when it should not. |
| 5 | An `overlapseek` drill was inconclusive, or the `still` drill's session ended before its first aim. |
| 6 | The `still` drill: nothing hit. |
| 64 | A flag the build cannot honour: `--cycle-el` without the `DualLayerDolbyVision` trait, `--dv-pin` in a release build or without the trait, or a `--dv-pin` spec with no capture rule. |

"Does not advance" is measured as how far the clock RAN over the run (each tick counts at most 2 s), not where it ended. A session resumed with `--start-position 120` that never left loading ends at 120.00, and used to pass the old check against the final time (AE#909). A `--paused` mount with no `play` host call is meant to stand still and is not judged.

### Flags

**Session and transport**

| Flag | Meaning | Default |
|---|---|---|
| `--seconds N` | Run length. | 30 |
| `--start-position S` | Resume anchor, as on `serve`. Also judged, see [Resume landing](#resume-landing-ae724). | none |
| `--paused` | Mounts with `autoplay = false`. | off |
| `--host-calls <list>` | Replays host calls against the session. See [Host calls](#host-calls). | none |
| `--seek-every N` | Seeks once every N ticks past tick 10. | off |
| `--seek-pattern <abs,...>` | Absolute targets `--seek-every` walks through. | a short backward hop |
| `--seek-count K` | Stops after K seeks. | unlimited |
| `--throttle-kbps N` | TEST-ONLY slow-CDN simulation, as on `serve`. | no cap |
| `--prewarm` | Warms the source before the load (AE#551) with the engine's default budget (8 MB). | off |
| `--prewarm-bytes N` | Warms N bytes instead. | none |

**Live**

| Flag | Meaning | Default |
|---|---|---|
| `--live` | Loads on the live path. | off |
| `--dvr-window N` | DVR ring size in seconds. | none (live-only) |
| `--live-ingest` | Loads through `HLSLiveIngestReader` as a custom source. | off |
| `--native-hls` | `LoadOptions.nativeRemoteHLS`. | off |
| `--standard-join` | `LoadOptions.liveJoinProfile = .standard`. | `.fastZap` |
| `--fast-zap` | Accepted and ignored, kept for older scripts. | |
| `--live-cushion SECONDS` | `LoadOptions.liveEdgeCushionSeconds`. | engine default |
| `--live-start-immediately` / `--no-live-start-immediately` | `LoadOptions.liveJoinStartsImmediately` (AE#440). | on |
| `--header "Name: Value"` | `LoadOptions.httpHeaders`, repeatable. | none |
| `--trust-any-certificate` | Answers `EngineTLS.serverTrustEvaluator` for every origin (AE#495). | off |
| `--record <path>` | Records the live source to a file (AE#560). | off |

**Subtitles**

| Flag | Meaning | Default |
|---|---|---|
| `--subs <codec-or-lang>` | Activates the first track whose libavcodec name or language matches, and logs every overlay cue and cue trim. | off |
| `--sidecar <lang>=<path-or-url>[,...]` | Fills `LoadOptions.externalSubtitles`. | none |
| `--teletext-page N` | `LoadOptions.teletextPage`. | none |
| `--switch-teletext-page <page\|auto>[@ms]` | Changes the teletext page on a playing channel. | +20 s |
| `--subtitle-offset-reach SECONDS` | Sets `maximumSubtitleOffsetSeconds` before the load (0 to 600). | engine default |
| `--preserve-ass-markup` | `LoadOptions.preserveASSMarkup`. | off |
| `--skip-attachments` | `LoadOptions.skipsContainerAttachments` (AE#956). | off |

**Audio**

| Flag | Meaning | Default |
|---|---|---|
| `--switch-audio <index>[@ms]` | Switches the audio stream just after playback starts (#337). | +20 ms |
| `--audio-delay <ms>` | `LoadOptions.audioDelaySeconds` at load. | 0 |
| `--switch-audio-delay <ms>[@ms]` | Calls `setAudioDelay(_:)` mid-session. Repeatable. | +20 s |
| `--audio-shaping <spec>` | `LoadOptions.audioShaping` at load. | off |
| `--switch-audio-shaping <spec>[@ms]` | Calls `setAudioShaping(_:)` mid-session. Repeatable. | +20 s |
| `--atmos-bed <layout>`, `--bed-format apac\|lpcm` | Object-audio bed, as on [serve](#object-audio---atmos-bed). | off, `apac` |
| `--drop-audio` | Forces every audio pipeline to fail (AE#462). | off |
| `--audio-stats` | Installs the audio tap and reports PCM continuity and audio lead. | off |

**Decode path and video**

| Flag | Meaning | Default |
|---|---|---|
| `--sw` | `LoadOptions.preferredDecodePath = .software` (#461). | off |
| `--no-sw-escalation` | `LoadOptions.escalatesToSoftwarePath = false` (AE#629). | escalation on |
| `--assert-dv` | `LoadOptions.panelPresentsDolbyVision` (AE#493). | off |
| `--dv-base-layer` | `LoadOptions.dolbyVisionHandling = .baseLayerOnly`. | off |
| `--fel` | `LoadOptions.preferDualLayerDolbyVision = true`. | off |
| `--fel-output` | `LoadOptions.dualLayerRoute = .avPlayerOutput`. Needs `--fel`. | off |
| `--surface` / `--window` | Presents into a 1280x720 window (macOS only). Same flag. | off |
| `--cycle-el <seconds>` | Flips the FEL residual off and on every period (at least 0.1). | off |
| `--dv-pin <spec>` | DEBUG: pulses a pinned frame's DV metadata. | off |
| `--upscale` | `LoadOptions.upscalesLowResolutionVideo` (#846). | off |
| `--deinterlace-field-rate field\|frame` | `LoadOptions.deinterlaceFieldRate` (AE#492). | `field` |
| `--native-video-frame-diagnostics` | `LoadOptions.nativeVideoFrameDiagnostics`. | off |
| `--native-video-frame-recovery` | Bounded SDR native decoded-output repair. | off |

**Source shape**

| Flag | Meaning | Default |
|---|---|---|
| `--sequential-origin` | `LoadOptions.sequentialOrigin` (#346, AE#958). | off |
| `--declared-duration S` | `LoadOptions.declaredDurationSeconds`. Needed with `--sequential-origin` on VOD. | none |
| `--held-connection` | `LoadOptions.heldSourceConnection` (#377). | off |
| `--progressive-segments` | `LoadOptions.progressiveSegmentDelivery`. | off |
| `--max-concurrent-requests N` | `LoadOptions.maxConcurrentSourceRequests` (#377). | engine default |

**Corrections and reloads**

| Flag | Meaning | Default |
|---|---|---|
| `--reload-applying <key>=<value>` | Corrects a `LoadOption` on the playing session through `reloadAtCurrentPosition(applying:)` (#460). Repeatable. | none |
| `--reload-applying-at <ms>` | When the corrections fire. One value shared by all of them. | +20 s |

**Measurement**

| Flag | Meaning | Default |
|---|---|---|
| `--served-url` | Prints `SERVED <url>` with the loopback token in clear. | off |
| `--frame-times` | Installs the #311 software frame-time observer. | off |
| `--present-times` | Counts distinct frames presented on the native path. | off |
| `--picture-probe` | Decodes the source time out of the picture itself. | off |
| `--picture-origin S` | Where the source's timeline starts, for `--picture-probe` (AE#534). | 0 |
| `--malloc-census` | Large-allocation census for the run. | off |
| `--census-hz N` | Poll rate of the census jump trigger. Needs `--malloc-census`. | |
| `--census-threshold-mb N` | Jump size above the running high-water that triggers a zone walk. Needs `--malloc-census`. | |

### Host calls

`--host-calls <a,b,...>` replays host behavior against the fresh session. Several calls can be combined. Calls that take `@N` fire at tick N. Replaying a host's call sequence this way is how the pre-arming `setRate` wedge was isolated.

| Call | What it does |
|---|---|
| `play` | Calls `play()`. With `--paused`, this is a host that owns transport. |
| `extractor` | Calls `makeFrameExtractor`. |
| `setrate` | Calls `setRate(1.0)`. |
| `pausestart` | `pause()` the instant load returns, before any frame exists, then `play()` at t=8 (Sodalite#104 round 4). See below. |
| `ratehold` | Sets rate 1.5, pauses at tick 3, resumes at tick 5, then reads the rate back off the transport. Fails the run if the resume came back at 1.0 (#436). |
| `reloadlive` | Reloads the URL on the live path when the probe flags it live (the AetherPlayer Open URL flow). |
| `reloadnext` | A host's episode seam. See below. |
| `seekback` | Rewinds 20 s into the DVR window at t=15, returns to the live edge at t=30. |
| `seekfar` / `seekfar@N` | Seeks past the produced window at t=15 (or t=N), so the landing needs a producer restart (#433). |
| `overlapseek` | Three transport calls inside a seek's reposition window (#292). See [overlapseek](#overlapping-seeks---host-calls-overlapseek). |
| `pausehold` | Pause at t=10 and hold. See below. |
| `pauseseek` | Pause at t=12, seek at t=15 while paused, resume at t=20. |
| `still` | Asks for scrub stills at three aims (#544, AE#605). See below. |
| `stallclock` | Stops the master clock behind the host's back (AE#549). See below. |
| `pausereload`, `playreload`, `extplayreload` | Force the stage-2 item reload (#623). See below. |
| `nativesubs` | Sets `LoadOptions.prepareNativeSubtitles`. |
| `nativerender@N` | The host call a player makes when the picture leaves its own layer (PiP, AirPlay, a wired display). |
| `subsoff@N`, `subson@N` | The viewer turning subtitles off and back on while the picture is away. |
| `subsatload` | Picks the `--subs` track the moment `load` returns, before the first frame, like a host restoring a remembered track. The default pick at t=5 is a mid-session start, which the prefetch and the drain handle differently (#1021). `CUE` lines end in `at=<clock>`, so the lead a cue arrived with is readable. |
| `lanreload@N` | Fires `reloadAtCurrentPosition()` (AE#955). |

**`pausestart`.** This is the shape of a host that holds a fresh load paused. A software session used to answer it with eight ticks of `enq=+0 status=unknown r4d=n`: a black picture under a paused clock. Now the `[SWHost] #104` lines show the first frame presented at a stopped clock, and `startup 8/8 presenting` arrives while paused.

**`reloadnext`.** The same URL is loaded again at t=4 on the still-playing engine, with no `stop()` in between, so the native host is reused. Every published `state` prints as `STATE <state> t=<s>`. The second load must go `loading`, `playing` with no `paused` between them. It did not while the reused host still carried the outgoing item's `.playing` status, and every host raised its transport over the next episode.

**`pausehold`** (Sodalite#104). Pauses at t=10 and HOLDS until ten seconds before the end, printing the playhead, the edge and the resident depth every second. This measures a session paused longer than its own DVR window without waiting out a real one. Pair it with `--dvr-window 30` and `--seconds 90`, and the ninety-minute question becomes a ninety-second run.

**`pauseseek`.** With `--sw`, the paused ticks between landing and resume show the landed frame being decoded at the stopped clock (AE#1023): `[SWHost] AE#1023 paused landing` at the seek, then `#104 first frame in under the pause` with the frame's timestamp, and `enq=+N r4d=y` on the next `[SWDiag]` line while `cur=` stays on the target. Before AE#1023 those ticks read `enq=+0 r4d=n` until `play()`. After the frame is in the pump parks again, so the remaining ticks still show the AE#479 shape of a pump that reads nothing.

**`still`** (#544). On a live session it asks for a scrub still at three aims: 20 s behind the playhead at t=15, 5 s behind at t=20, and at the edge at t=25. Each is written to `aetherctl-still-<tick>.png` in aetherctl's private per-user temporary directory (the path is printed), with hit or MISS and the decode time.

- Pair it with `--sw --dvr-window N`. The picture then comes out of the DVR packet ring, not a segment cache.
- Read the FILE as well as the count. The bundled seed burns its own second into the frame, so a still asked for at 14.85 s that shows `14` proves it decoded the right moment, not merely an image.
- Exit 6 when nothing hit, 5 when the session ended before the first aim.
- On a VOD session (AE#605) the three aims go through `scrubThumbnail`: 10.5 s behind the playhead, 4.5 s ahead of it, and 600 s past it. The third is EXPECTED to miss, because a frame the cache does not hold yet must not be answered with the one before it. `--sw` against an HTTP source is the software packet-cache case. The testsrc fixture's counter in the PNG proves the still decoded to the target instead of snapping to its keyframe.

**`stallclock`** (AE#549). Stops the master clock at t=4 behind the host's back, the way an interrupted audio session does. It then calls a plain `play()` at t=7 and reads whether the playhead moves again. The interruption itself cannot be staged on macOS, but its outcome can. Without the `RendererClockResume` branch the run ends with the clock standing exactly where the stall left it, which is the field log's shape. The drill drives DEBUG-only engine hooks, so a Release `aetherctl` prints a notice and ends inconclusive. Build it with `swift build --product aetherctl`.

**`pausereload`, `playreload`, `extplayreload`** (#623). Each forces the #93/#65 stage-2 item reload at t=10:

- `pausereload`: on a session paused at t=6.
- `playreload`: on a session left playing.
- `extplayreload`: on a session paused through the engine at t=6 and resumed at t=8 straight on the `AVPlayer`, the way AVKit's transport does. That leaves the engine's intent reading paused while the player runs.

The run fails with exit 4 if the clock moves after the paused reload, or stands still after either playing one. Before #623, `pausereload` ended `+7.20 s, state=playing`.

### Native subtitle rendition drills

`--host-calls nativesubs,nativerender@N,subsoff@N,subson@N,lanreload@N` drives the NATIVE SUBTITLE RENDITION path for VOD (Sodalite#156). `serve --native-subs` stands the renditions up and `live --force-master` routes a channel behind them, but before this no VOD session loaded with `prepareNativeSubtitles`. So the part that matters was untestable: whether AVPlayer actually HOLDS a legible selection, and whether the engine keeps feeding the one it holds.

**The observable is a `LEGIBLE` line**, printed one tick AFTER each transition, never inside it. Both calls finish on a detached task, and the select first waits on a cue pre-fill, so an immediate read would report what the host ASKED for, not what the item ended up with. The line shows the selection AVPlayer holds next to the track the engine thinks is active. Those two coming apart is the defect class.

```bash
aetherctl play --subs ger --seconds 30 \
  --host-calls nativesubs,nativerender@8,subsoff@14,subson@20 file://$PWD/subs.mkv
```

| Reading | Meaning |
|---|---|
| `selected=German engineActive=2`, then `selected=none engineActive=nil` after the off, then `selected=German engineActive=2` after the on | Healthy. |
| `selected=German engineActive=nil` | A rendition nobody fills any more. On an AirPlay receiver that is an empty caption box. |
| `selected=none engineActive=2` | Subtitles that never came back. |

**`lanreload@N`** fires `reloadAtCurrentPosition()` at tick N. That is the session-preserving rebuild a wireless AirPlay receiver starts (AE#955). It prints `activeSubtitleTrackIndex` on both sides of it, plus a `LEGIBLE` and `VTT` readout four ticks later. A Mac has no receiver to flip the route, so this is the reload without the route. With a bitmap track it also drives the OCR-fed rendition through the rebuild:

```bash
aetherctl play --subs eng --seconds 30 \
  --host-calls nativesubs,lanreload@8,nativerender@14,subson@15 file://$PWD/pgs.mkv
```

A healthy run arms `[SubtitleOCR] worker armed` once, logs `OCR pre-fill done ... exit=covered`, and reads `selected=English engineActive=4` after the on. The first Vision call in a process can take about a minute while the system compiles its model, so judge a slow pre-fill from a second run. The `VTT` readout fetches the first rendition when none is selected, so its empty segments before the select are the harness asking, not a receiver.

### Sidecar subtitles (`--sidecar`)

`--sidecar <lang>=<path-or-url>[,<lang>=<path>...]` fills `LoadOptions.externalSubtitles`, the load-time declaration a host makes. On a remote `m3u8` this makes the engine stand up its rewritten master (#316), so it shows the whole chain from the CLI:

- the served `master.m3u8` body is logged,
- the engine reports how many renditions it injected,
- selecting the track (`--subs <lang>` matches the external track by language) shows the `subs_N.m3u8` and `subs_N_0.vtt` fetches arriving.

In the end-of-run `subtitle tracks` line, `cues=0` and "no cues arrived" are CORRECT here. AVPlayer renders a rendition itself, so the overlay pipeline stays empty (same as AE#154).

### Served URL (`--served-url`)

`--served-url` prints `SERVED <url>` whenever the session mounts a native item, with the loopback path token in clear. Every other line redacts it, which is right for a log but leaves no way to look at what was actually served.

With the URL, `init.mp4` is one `curl` away. The fMP4 segments are already on disk under `$TMPDIR/aether-segments/<session>/seg-N-M.m4s`. `cat init.mp4 seg-26-27.m4s > s.mp4` gives a file `ffprobe -show_packets` reads; that is how AE#684 measured the sound against the picture in the bytes instead of in the log. Fetch the init segment only: a second client asking for the playlist or for segments is a consumer the session then accounts for.

### Seek bursts (`--seek-every`)

`--seek-every N` seeks once every N ticks past tick 10. It walks `--seek-pattern <abs,abs,...>` if given, otherwise it makes a short backward hop. `--seek-count K` stops after K seeks, so a run can be a BURST and then play.

You need both halves to study what a seek sequence leaves behind: the burst puts the store in the state under test, and only the playing half shows what the overlay carries through it. That pairing made AE#362's second mechanism reproducible: a hole between a restarted pump and the island the previous run left ahead of it, decoded across and then never re-read.

### Overlapping seeks (`--host-calls overlapseek`)

Pair it with `--sw`. It runs three drills at t=8. Each makes a transport call while a seek's demuxer reposition is still in flight. #254 opened that window by moving the reposition off the main actor.

- **A**: a second seek to the same target (the #292 report: a scrub arriving as two seeks, the second superseding the first).
- **B**: a `pause()`.
- **C**: a `play()` from paused.

`seektest` cannot reach this, because it awaits every seek, so its bursts are strictly serial.

Each drill first heals the session with pause + play, so a defect one drill provokes is not inherited by the next. Each reports its own PASS / FAIL / INCONCLUSIVE. `inWindow=NO` means the call arrived after the landing and the run proves nothing. Exit 4 when any drill fails, 5 when any is inconclusive. Before the #292 fix, A and C landed the clock at `rate=0.0` while the engine reported `.playing`, and B silently kept playing through the pause.

### Live loads

**`--live-ingest`** loads the URL through `HLSLiveIngestReader` as a custom source. That is the shape a host uses for a live channel it ingests and re-serves itself (Sodalite's direct live path). Pair it with `--live`.

- It reaches the reader DIRECTLY, which a repro of the reader itself needs.
- Since AE#363 plain `--live` also ends up at the reader, but through the engine's own route: the raw live path detects the playlist and hands it to the ingest. So use `--live-ingest` when the reader is the subject, and plain `--live` when the routing is.
- `hlslive` only serves local `.ts` files.
- AE#359 (the master's SUBTITLES renditions were parsed away) survived precisely because this path had no harness. `--live-ingest --subs <lang>` reproduces and verifies it in 40 s against a public broadcaster URL.

**`--native-hls`** sets `LoadOptions.nativeRemoteHLS`, the path a host uses for a live channel AVPlayer can play itself. It is the only way to exercise the #168 carriage watchdog, the #293 carriage probe and the AE#363 origin-refusal reroute from the CLI (`hlslive` loads the ingest reader directly and never mounts natively). Pair it with `--live`. Without `--live` the m3u8 takes the raw live path, which since AE#363 routes it onto the ingest instead of mounting AVPlayer at all.

**`--standard-join`** loads with `LoadOptions.liveJoinProfile = .standard`. Without it the load takes the engine default, `.fastZap`. `--fast-zap` is still accepted (and does nothing) so older scripts keep running. Pair it with `--live`, and read the first-serve line (AE#374), not a first-frame stopwatch.

Why it exists: `live` has carried the profile switch for its own raw-TS fixture since AE#195, but that fixture has no upstream playlist. The served `#EXT-X-TARGETDURATION` is floored by the UPSTREAM's observed arrival cadence (`LiveCadencePolicy`), which sizes the holdback the first serve waits for. So fastZap against an origin of one's own, the shape a downstream player actually ships, could not be driven from here at all. Measured on the same 1 s-GOP seed, `--preroll 0 --realtime`:

- Raw TS with no playlist serves at 1.325 s on TARGETDURATION 1 (holdback 3 s, full cushion). Since AE#670 the engine's own GOP-bound cut carries 1.5x headroom, so that row now seals at 2.
- The same content behind an `hlsfixture` origin cutting 2 s segments serves on TARGETDURATION **2** (holdback 6 s), although the engine re-cut it at 1 s.

**`--live-cushion SECONDS`** sets `LoadOptions.liveEdgeCushionSeconds`, how far behind the live edge the session plays. Read:

- the first-serve line (AE#374), which names the holdback the first manifest waited for,
- the `AE#851 first live window ready after` line that follows it (the wait now ends before the item is attached, so `repeat live manifest request held 0.000s` is the healthy reading),
- on the software path, the `live join placed` line.

**`--live-start-immediately` / `--no-live-start-immediately`** set `LoadOptions.liveJoinStartsImmediately`, which cuts AVPlayer's stall-avoidance hold short once at the live join (AE#440). It is **on by default** since 6.55.0, so `--no-live-start-immediately` is the flag that drives the control arm now. The positive one is still accepted.

**The hold it addresses does not reproduce on this harness**, and that is itself the finding. Measured on 6 window geometries against the raw-TS fixture at `--realtime --preroll 0` (a shallow window under the holdback, a window exactly at it, and a deep window from `--preroll 6/12/30`): the gap between `layer.isReadyForDisplay=true` and `timeControlStatus=playing` stayed between 10 and 60 ms every time, against 1.5 to 2.8 s reported on an Apple TV 4K over the same shape. Loopback answers at memory speed, so AVPlayer's buffering-rate evaluation concludes at once. The flag drives the engine end of a device A/B; it proves nothing from a Mac. That A/B has since run (AE#440, on 6.53.0) and is what turned the default on. See the live-join section of `api.md` for its numbers.

**`--header "Name: Value"`** (repeatable) fills `LoadOptions.httpHeaders` and, with `--live-ingest`, the reader's own fetches. Before AE#363, origins that enforce a per-request `User-Agent` / `Referer` / `Authorization` (tokenized IPTV, STB profiles) could not be driven from the CLI at all. Pair it with [`hlsfixture --require-header`](#the-header-enforcing-origin-ae363) to have both ends of the contract in one run.

**`--trust-any-certificate`** answers `EngineTLS.serverTrustEvaluator` for every origin. That is what a host does for a media server behind a self-signed or private-CA certificate (AE#495). It is the only way to reach the loopback ORIGIN RELAY from the CLI. The relay stands up when the system refuses the origin's certificate and a host has answered for it, because `AVURLAsset` asks no delegate and cannot be told about that certificate. Every other run here reaches an origin the system already trusts, which is the one case the relay deliberately does not handle. Serve an HLS master over https with a self-signed certificate and the two arms read:

- without the flag: `The system does not trust the origin's certificate`
- with it: `AE#495: routing <host> through the relay so the handshake runs where the evaluator is asked`

### Audio stream switch (`--switch-audio`)

`--switch-audio <index>[@ms]` replays a host applying a viewer's language preference just after playback starts (default +20 ms, the #337 field case). The engine rebuilds the session with the new stream at `resumeAt = 0`. That is the only shape where the rebuilt session's video renderer can fill before the newly selected stream's first packet arrives.

- Pick a stream whose first packet sits late in the mux. Before the fix the run read `state=playing cur=0.00` for its whole length with a first frame on screen. The end-of-run verdict names it.
- `--audio-stats` with it re-installs the tap after the switch. The tap is bound to the software host the switch replaces, and would otherwise report silence for a session that is playing fine.

Build a fixture with a late track by offsetting one input:

```bash
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30:duration=40 -f lavfi -i sine=frequency=440:duration=40 -itsoffset 12 -f lavfi -i sine=frequency=660:duration=28 -map 0:v -map 1:a -map 2:a -c:v libx264 -c:a libopus late-audio.mkv
```

### Teletext pages

`--teletext-page N` sets `LoadOptions.teletextPage` for the load. `--switch-teletext-page <page|auto>[@ms]` changes it on a channel that is already playing. The default is +20 s, deliberately long: the switch has to land after `--subs` has a teletext track showing, or the run only measures the load option it could already measure.

The engine states what the change reached: `re-decoding N channel(s)` or `no active teletext track to re-decode`. So a page that does nothing can be told apart from a page that never arrived. Real teletext needs a broadcast transport stream, and ffmpeg cannot synthesise one. The CLI check covers the wiring and the gate; the decode itself is confirmed against a live DVB channel (#364).

### Subtitle offset reach

`--subtitle-offset-reach SECONDS` sets `maximumSubtitleOffsetSeconds` before the load. Every tick line then carries `bmp=<count>/<MB>`: the decoded bitmap cues `$subtitleCues` retains. With `--malloc-census` or the memprobe line, this is the A/B for AE#929. On a 300 s fixture with an opaque 1120x900 PGS image every 3 s:

- the default retains 41 images (165 MB),
- a declared reach of 0 or 10 keeps only the 15 s on each side, 11 images (44 MB), with the landing cue of a seek back still in the next tick.

`play` with `--subs` also prints `ONSCREEN <starts> at=<playhead>` whenever the set of cues covering the playhead changes, sampled four times a second (`-` for none). That is what a host overlay draws, and it is the observable for a landing: a `CUE` line only says a cue arrived, and a cue kept across a seek or one that arrives after its own end never shows up as one. AE#1022 was measured this way, at reach 0 on a 150 s MKV with a 3 s PGS set every 5 s:

```bash
aetherctl play --sw --subs pgssub --subtitle-offset-reach 0 --seconds 40 \
  --seek-every 6 --seek-count 4 --seek-pattern 63,79.4,93.2,33.9 file://$PWD/film.mkv
```

Before the fix no landing line was shown and the set before the seek was drawn over two landings. After it, `ONSCREEN` names the landing set within 0.0 to 0.4 s of each landing, the same as the default reach.

### ASS markup (`--preserve-ass-markup`)

`--preserve-ass-markup` sets `LoadOptions.preserveASSMarkup` for the load, so the cue log shows which codecs the flag reaches. An ASS track prints the raw nine-field event line (`0,0,Default,,0,0,0,,{\i1}line{\i0}`); every other text codec prints extracted text, in the same session.

Why it matters: libavcodec normalises SubRip, WebVTT and mov_text through `ff_ass_add_rect`, so all of them carry an ASS payload the engine could emit. The codec gate is the only thing between a host and nine stray header fields. AE#587 reported the gate missing on the embedded path and could only be argued from the source, because no harness had ever set the flag.

Fixture: mux an SRT and an ASS file into one container and select each in turn.

```bash
aetherctl play --preserve-ass-markup --subs eng --seconds 7 file://$PWD/ass-srt.mkv   # subrip: plain text
aetherctl play --preserve-ass-markup --subs ger --seconds 7 file://$PWD/ass-srt.mkv   # ass: raw event lines
```

### Audio shaping (`--audio-shaping`)

`--audio-shaping <spec>` sets `LoadOptions.audioShaping` for the load. `--switch-audio-shaping <spec>[@ms]` calls `setAudioShaping(_:)` mid-session (repeatable, default +20 s). A spec is `off`, or a comma list of `ch=N`, `dialogue=DB` and `night`.

The run prints `shaping=` next to the audio delivery, and the log names the pipeline each rebuild chose (AE#923). On an E-AC-3 5.1 source:

- `--switch-audio-shaping ch=2,dialogue=6,night@4000` moves a `streamCopy` session to `[AudioBridge] init: ... encoder=flac ... encoderChannels=2 ... AE#923 shaping ...` and `audio shaping applied`.
- `--switch-audio-shaping off@9000` takes it back to `streamCopy`.

### Audio delay (`--audio-delay`, `--switch-audio-delay`)

`--audio-delay <ms>` sets `LoadOptions.audioDelaySeconds` for the load. `--switch-audio-delay <ms>[@ms]` calls `setAudioDelay(_:)` on a session that is already playing (default +20 s, same reason as the teletext switch).

The runtime half is the interesting one. At load the offset is just a number handed to a muxer or a renderer. Mid-session it has to reach media the session already committed under the previous value, and the two routes pay differently: a seek on `.software`, the session-preserving reload on `.loopback`. The engine states the delivered offset, not the requested one (AE#464):

- software path: `[AudioOutput] AE#464 audio delay in effect: +200 ms (sample at 3.994s delivered at 4.194s)`
- loopback path: `[MP4SegmentMuxer] AE#464 cutting seg1+ with audio delay -150 ms`

**Ordering of presses.** `--switch-audio-delay` presses that share a delay are delivered by ONE task in argument order, with no await between them. That is what "inside one runloop turn" means below. A task per press put a 50/100/150 series on the wire as 100, 150, 50 (measured), so the engine delivered 50 and the arm read as a defect that was really the harness. Presses at different delays stay ordered by time.

**Round 2 (`--paused`, three presses in one turn).** `--switch-audio-delay` is repeatable and `--paused` mounts with `autoplay = false`; together they reproduce the round-2 pair of AE#464 without hardware.

- `--paused --host-calls play` is a host that owns transport (mounts paused, plays next to its own load). The rebuild the engine raises for a nudge has no such caller. Before the fix, item #2 settled `timeControlStatus=paused reason=- t+0.00s`, never reached `playing`, and the producer parked on `#65 backpressure PARK (advance) ... (consumer paused)`, while the run still ended `VERDICT: OK`. After it: `#2 timeControlStatus=playing t+0.06s`.
- Three presses inside one runloop turn (`--switch-audio-delay 50@15000 --switch-audio-delay 100@15003 --switch-audio-delay 150@15006`) stack three reloads, two superseded by generation. Before the fix the survivor loaded `startPos=nil` and cut `seg0+` on a session 14.90 s in. After it: `startPos=14.90s`, `initial producer anchored at idx=3` and `seg3+`.

**Round 3 (three presses at the SAME delay).** `--switch-audio-delay 50@15000 --switch-audio-delay 100@15000 --switch-audio-delay 150@15000` is the in-flight latch's arm.

- Before: four loads dispatched, two `load superseded`, and two `AE#464: the re-cut at the playhead failed (CancellationError())` lines naming values (+50 ms, +100 ms) that were already superseded. The session then sat at `state=paused cur=14.90` from t=15 to t=19 and still ended `VERDICT: OK`.
- After: two loads, zero superseded, two `folded into the re-anchor already in flight` lines, the same `cutting seg3+ with audio delay +150 ms`, and the session playing through.
- The paused half was the transport park: a rebuild stacked behind one in flight read `.loading` and had no host to ask, so it wrote `autoplay = false` onto a session that was playing.

**`--reload-applying autoplay=false`** drives the third answer a correction can give: neither applied nor refused. Before round 3 the field was named inside `#460: reload applying httpHeaders, autoplay` and then overwritten. Now it gets `#460: autoplay not applied, the session owns it`. The run prints the returned partition next to it (`#460 outcome applied=[] sessionOwned=[autoplay] rebuilt=false`). Since round 4 no rebuild follows: the session plays on without a `#361 startup` line, where it used to pay a full one for a field it decides itself.

**Pressing into a rebuild window.** `--reload-applying-at 14990 --switch-audio-delay 150@15000` aims a press squarely into a rebuild window, where `videoRoute` is `.none` because there is no route to ask. That used to answer `this session's audio timestamps are not the engine's to move (route=none)` one line above the muxer cutting with the value. Now it answers `set while the session is being rebuilt; the load in flight reads it from the options and delivers it`.

**Round 5 (two presses a re-anchor apart).** `--switch-audio-delay 50@15000 --switch-audio-delay 100@15060`; the band is 50 to 90 ms on an M1 against a 300 s H.264 + AAC fixture. The second press arrives after the first rebuild has returned and written `.playing`, but before the new host has published a position.

- Before the fix it read the zero `load()` had written and rebuilt at the head: `#3 mount seek: item axis 0.00s`, `cutting seg0+`, on every run from 15050 to 15090.
- After it: `#3 mount seek: item axis 14.90s` and `cutting seg3+` on every run.
- Control: `--start-position 100 --seek-every 12 --seek-count 1 --seek-pattern 0 --switch-audio-delay 50@12450`. A seek retires the parked position, so the rebuild after a genuine seek to 0 still mounts at `0.00s`, not at the 100 s the load was handed.

**Live-only sessions.** `play --live` without `--dvr-window` is the live-only shape, and it shows the re-anchor gate: `AE#464: audio delay = +150 ms stands, but this session cannot re-anchor at the playhead (state=playing, live=true); it arrives at the next seam`. With `--dvr-window 1800` the same run takes the re-anchor and re-cuts. Before round 2 the gate read `liveWindow != nil`, which is true for both, so the live-only session took a rebuild that rejoins at the edge.

### Load-option corrections (`--reload-applying`)

`--reload-applying <key>=<value>` (repeatable, with one shared `--reload-applying-at <ms>`, default +20 s) corrects a `LoadOption` on the playing session through `reloadAtCurrentPosition(applying:)` (#460).

| Key | Value | Field |
|---|---|---|
| `header.<Name>` | header value | `httpHeaders` |
| `audio-bridge` | an `AudioBridgeMode` raw value | audio bridge mode |
| `preferred-audio` | comma list of languages | preferred audio languages |
| `decode-path` | a `DecodePath` raw value, for example `software` | `preferredDecodePath` |
| `dolby-vision` | a `DolbyVisionHandling` raw value, for example `baseLayerOnly` | `dolbyVisionHandling` |
| `prefer-dual-layer-dv` (alias `fel-mode`) | `true\|false` | `LoadOptions.preferDualLayerDolbyVision`, so a running session can move on or off the Profile 7 FEL route |
| `is-live` | | Drives the refusal: a field that names the session must be observably refused, not observably ignored. |
| `autoplay` | `true\|false` | Drives the third answer: a field the session owns, neither refused nor applied. |

Both outcomes print, which is the pair a host's recovery ladder has to tell apart. Pair it with a header-logging origin to read the correction from the other end. With `--header "X-Auth: stale"` at load and `--reload-applying header.X-Auth=fresh`, the origin log shows three requests carrying the stale value, then three carrying the fresh one, and the transport telemetry carries straight through the rebuild (`resumed at 10.90s from 9.90s`).

### Decode path (`--sw`, `--no-sw-escalation`)

**`play --sw`** sets `LoadOptions.preferredDecodePath = .software` (#461), the shipping per-session lever. It used to drive the process-global `setForceSoftwarePathForTesting`; that hook is still what `live --sw` and `dvr` use, since those harnesses run several sessions and want every one on the software host. `--sw` forces the software path for a source that would route native, which is how a native-only fixture exercises the SW pipeline.

`--reload-applying decode-path=software` is the same lever applied to a session that is already playing. On the 300 s H.264 fixture the run dispatches `codec=27 → native`, takes the correction at t=9.90 s, and comes back `codec=27 → software` at 10.81 s, playing. On a live load the override reaches the same routing decision, which is the case with no alternative: the #2 capability gate is VOD-only for H.264 / HEVC, and such a live session is never classified at all.

**Finite MPEG-TS HLS (AE#990).** On a finite MPEG-TS HLS playlist, `play --sw` takes the AE#990 route. The AE#154 reroute logs `AE#990: finite MPEG-TS HLS with preferredDecodePath=.software`, the session dispatches `codec=27 → software` off the seekable TS ingest, and `--start-position` and `--seek-pattern` land (30.00 s and 41.29 s on a 60 s 1080i H.264 fixture with 5 reference frames, MP2 plus AC-3).

The refusal half needs a native mount that fails on its media, and macOS AVPlayer plays that fixture. The way to get one: an origin that serves AVFoundation (`User-Agent` containing `AppleCoreMedia`) the segments with every PES payload byte scrambled, and serves the engine's own fetcher the real ones. Plain `play` then prints `#561 AVPlayer refused the media (CoreMediaErrorDomain/-12976)`, `ESCALATION at 0.00s`, the AE#990 line and `VERDICT: OK`, where main ends in `.error` with exit 2.

**`play --no-sw-escalation`** sets `LoadOptions.escalatesToSoftwarePath = false` (AE#629). Together with the `ESCALATION` line, this is the A/B for a host's own fallback ladder. On a 40 s HEVC fixture from `Scripts/nal-overrun-fixture.py --after 20`, played with `AETHER_DISABLE_NAL_SANITIZER=1`:

- the default arm prints `ESCALATION at 12.00s duringStartup=false absorbed=CoreMediaErrorDomain/-19602 nativeItemFailed`, rebuilds on the software path and plays to the end (`VERDICT: OK`);
- the declining arm prints no escalation, goes to `.error` with `-19602` at 12.00 s and exits 2.

### Dolby Vision (`--fel`, `--assert-dv`)

**`play --fel`** sets `LoadOptions.preferDualLayerDolbyVision = true`, the opt-in to the Profile 7 FEL dual-layer route. A build without the `DualLayerDolbyVision` trait accepts and ignores it. It is off by default, as in the engine, so a plain `play` runs the route a host gets.

**`play --fel --fel-output`** also sets `LoadOptions.dualLayerRoute = .avPlayerOutput`: AVPlayer plays the base layer and the audio, and the engine composes the enhancement layer onto its frames (see [dolby-vision-fel.md](dolby-vision-fel.md#524-the-avplayer-output-route)). It needs `--fel`, and is ignored where the route is not available (a build without the trait, a MEL source).

**`--surface`** (or `--window`, the same flag) presents into a 1280x720 window, macOS only, so you can look at the picture.

**`--cycle-el <seconds>`** (at least 0.1) flips the FEL residual off and on every period, starting with the full result. It posts the current mode as a label over the picture and in the window title. The off phase is what a minimal enhancement layer decodes to, so the window is an A/B of the residual on the same frames. It changes only a session on the dual-layer route, so it wants `--fel` (without it `play` prints a note) and a surface to be seen on. It exits 64 in a build without the `DualLayerDolbyVision` trait.

**`--dv-pin <spec>`** arms the on-device consumption test in a DEBUG build of `aetherctl` with the `DualLayerDolbyVision` trait. A release build, or one without the trait, refuses the flag with exit 64. After composition it substitutes a captured frame's Dolby Vision metadata on a duty cycle and leaves the pixels untouched, so a visible pulse can only come from the metadata. The spec is the grammar `dvsurvey` prints, such as `darkest:240,period:2`. A spec with no capture rule is refused with exit 64. See [dolby-vision-fel.md](dolby-vision-fel.md).

**`--assert-dv`** sets `LoadOptions.panelPresentsDolbyVision` (AE#493), the host's claim that its display presents Dolby Vision. macOS has no per-mode display capability API, so a Mac run plays a Dolby Vision source as its HDR10 base layer (`effective-format=hdr10`) until the host says otherwise. The flag moves that label and the tvOS criteria request.

- It does not change the packaging of a Profile 5 / 8.1 / 8.4 source. Those carry their `dvcC` and `SUPPLEMENTAL-CODECS` on every display since 6.72.0 / 6.73.0.
- Profile 7 and AV1 Dolby Vision are still gated on it.
- A wrong claim costs one in-place media-playlist fallback, not the item.

### Upscaling (`--upscale`)

`--upscale` opts in to upscaling sub-1080p SDR video to the display (`LoadOptions.upscalesLowResolutionVideo`, #846). It logs one `[Upscale]` line, and an `UPSCALE` line once the first frame is upscaled.

### Dropped audio (`--drop-audio`)

`--drop-audio` forces every audio pipeline to fail, so the AE#462 video-only drop can be observed without a source this build has no decoder for. The loopback cascade skips both the stream-copy probe and the bridge, and `SoftwarePlaybackHost` refuses its decoder open.

The run then prints `audio delivery=droppedNoPipeline pipeline=none`, the pair a host reads (the typed fact plus the human label). Without the flag the same source prints `delivery=streamCopy` / `bridged` / `decoded`. The flag is loud in the log on purpose, in both the CLI line and the engine's own, because a forced classification read as a real one would be worse than no harness.

### Deinterlace field rate

`--deinterlace-field-rate field|frame` sets `LoadOptions.deinterlaceFieldRate` (AE#492). `send_field`, the default, emits one output frame per FIELD, so a 29.97i source hands the layer 59.94 frames per second against 23.976 for a progressive one. That factor confounds every per-seek counter taken across the two, and this flag is the only way to remove it: same file, same seeks, half the output rate, nothing else changed.

Measured on a 480i fixture through the hardware chain, four runs per arm: 59.9 fps and 17.47 drops/s at `field`, against 30.0 fps and 7.49 at `frame`. That is 0.291 against 0.250 per frame delivered, with the progressive arm at 0.254. Nothing binds a render surface in a CLI run, so the absolute level belongs to the harness; only the ratio between arms is a measurement.

### Frame times (`--frame-times`, `--present-times`)

**`--frame-times`** installs the #311 software frame-time observer BEFORE `load()` (the documented usage: the engine re-arms each new host with it) and reads `softwarePresentationTimebase`. Each tick appends:

| Field | Meaning |
|---|---|
| `ft` | Frames reported since the last tick. |
| `ftLast` | Newest reported presentation time. |
| `ftGen` | Renderer flush generation (a seek moves it). |
| `ooo` | Reports that arrived out of presentation order. These are reported after the reorder buffer, so it must stay 0. This is the API's own claim under test. |
| `tb` | The timebase read at the same instant. Its closeness to `ftLast` is the point: both are on the source axis with nothing to convert between them. |

**`--present-times`** counts what actually reached the screen on the NATIVE path, which had no frame observable at all. `--frame-times` reads the software renderer's own reports. On the AVPlayer route a judder report could only be argued from `AVPlayerItemTrack.currentVideoFrameRate`, which AVFoundation documents as an estimate, not a frame count (and which reads 0 in a CLI run, where nothing binds a render surface).

- It attaches an `AVPlayerItemVideoOutput` to the engine's own item and counts DISTINCT presentation times.
- Each tick appends `pres` (frames presented since the last tick).
- The run closes with `presented frames: total=N perSecond min/median/max=.. largestGap=Ss at Ts`.
- `largestGap` is the field that earns the flag. It separates "the picture is late" from "only the random access points survive": a 29.97 fps session presenting nothing but its container keys shows a gap of one GOP, not one frame.
- Seeks are bracketed out of the gap accounting. That has to happen around the call, not after it: the landing frame arrives before `seek(to:)` returns, so the first version reported the seek jump as the session's largest gap on every run.
- Attaching an output gives AVPlayer a pixel-buffer consumer it would not otherwise have, so a run with the flag is not byte-for-byte the run without it. It is the same decode path either way. `--picture-probe` attaches a second one if both are on.

### Source shapes

**`--sequential-origin`** declares `LoadOptions.sequentialOrigin`, the IPTV timeshift / catch-up shape whose `206` answers are fabricated (#346). The reader makes one long-lived unranged GET, no ranged probes and no tail read. A seek lands only inside the resident span that reaches the producer's frontier; every other target is rejected (AE#958). On VOD it needs `--declared-duration S`, which fills `LoadOptions.declaredDurationSeconds`, because the estimate the tail read would have produced is gone with the tail read.

**`--skip-attachments`** sets `LoadOptions.skipsContainerAttachments` (AE#956): a Matroska source opens without reading its attached files, the fonts of its ASS subtitles. The observable is the open itself. Against a throttled origin and an MKV that carries fonts, the time to the first `[AetherEngine]` load line drops by the fonts' transfer time, and the `[AVIOReader]` byte counts drop by their size.

**`--held-connection`** declares `LoadOptions.heldSourceConnection` (#377). The reader asks the origin once and pulls the whole file over that connection, instead of ending at the window high water and asking again every drain cycle.

- The observable is the range count, in the origin's own log or in the `[AVIOReader] pump conn start ... held` lines. Against an origin that refuses in windows, the point is that there is no second ask to refuse.
- Run two shapes deliberately, because the flag has to survive both: a long uninterrupted read, and a PAUSE. A pause must end the connection after five seconds and cost exactly one re-request at the frontier when playback resumes.
- On a finite HEVC-in-MPEG-TS HLS VOD (the AE#268 ingest) the same flag puts the playlist and every segment on one persistent HTTP/1.1 connection (AE#732). The observable is the `[HLSVODIngest] AE#732 connection ... open` and `... closed after N requests reason=...` lines, one pair per connection.
- A seek mid-body logs `draining abandoned body, <received>/<expected> bytes` and then `drained, kept for the next request`, or closes with `abandoned mid-body`.
- A stalled body ends the session with `body stalled, no bytes for 30 s after ...`.
- The engine's own repositions onto segment 0 right after the open still cost one connection each.
- Slow-origin case: serve 11 MB HEVC-in-TS segments from a keep-alive origin at 200 KB/s shared across its connections. Each segment then takes about 58 s, longer than the 45 s a whole exchange used to be allowed (#732).

**`--progressive-segments`** sets `LoadOptions.progressiveSegmentDelivery`: each VOD segment is served while it is written. Run it against a throttled origin and compare the `FIRSTFRAME` and first `PHASE playing` times with and without the flag. The session log shows `serving while it is written` for every segment that went out that way. On a local or fast source the segments are cut before AVPlayer asks, and the two runs look the same.

**`--max-concurrent-requests N`** sets `LoadOptions.maxConcurrentSourceRequests` (#377): the most requests the reader may have open against the origin at once, across every path it fetches on. `1` also switches off the speculative parallel paths, which is the shape of a connection-metered CDN. Count the requests in the origin's own log, or read the `[AVIOReader]` connection lines, with and without the flag.

**`--prewarm` / `--prewarm-bytes N`** (AE#551) warm the source before the load, the way a host warms the next episode, and print what was retained and how long it took. Bare `--prewarm` takes the engine's default budget (8 MB). The load that follows adopts those bytes: its reads inside the warm head cost no request, and its data connection starts at the warm frontier instead of byte zero. Measure it against a REAL origin. On loopback the round trip it removes costs nothing to begin with, which is exactly the trap the #281 tail prefetch was built on.

### Native decoded-output diagnostics

`--native-video-frame-diagnostics` enables the opt-in SDR native-loopback decoded-output observer from `LoadOptions.nativeVideoFrameDiagnostics`. It logs progress, output gaps and observation delays. It does not suppress the player layer, and it does not claim physical display proof.

`play --native-video-frame-recovery` separately enables bounded SDR native decoded-output repair. It is off by default and is not turned on by enabling diagnostics. See [diagnostics](api.md#diagnostics).

### Picture probe (`--picture-probe`)

`--picture-probe` attaches an `AVPlayerItemVideoOutput` to the running item and decodes the source time out of the picture itself. It answers the one axis question nothing else here can: every other observable (`#260` frame times, `prodShift` / `hostShift`) describes what the engine WROTE, not where AVPlayer then PUT it. Each tick appends:

| Field | Meaning |
|---|---|
| `pic` | Source seconds decoded from the frame. |
| `picItem` | AVPlayer's own `itemTimeForDisplay` for that frame. |
| `axisErr` | Their difference. 0 on an honest axis. |
| `capErr` | The error a host placing a cue at `sourceTime` would make. |
| `capFr` | `capErr` in frames. |

**Fixtures.** It needs a fixture whose picture states its own frame number, which `Scripts/timecode-fixture.sh` writes. Against anything else it prints `pic=none` or nonsense. `pic=none` is also the normal reading before the first frame and during a stall, so it is not reported as a zero.

**`--picture-origin S`** (AE#534) tells it where the SOURCE's timeline starts, for a container whose timeline does not start at zero. The picture states a frame index, which an `-output_ts_offset` remux does not move, while `sourceTime` is on the container's own axis. So on a 600 s twin `capErr` reads about `-599.942` while everything works correctly, and the honest value is `+0.017`. `axisErr` needs no such lift, since both of its terms are on the item axis. Measured on the pair `tc-cues-lie.mkv` and `tc-cues-lie-600.mkv` at `--start-position 53`: both read `capErr +0.017` and `axisErr -9.000` once the origin is given, and the twin reads `-599.942` without it.

Build the twin with `Scripts/timecode-fixture.sh <dir> 600`, which writes an offset copy of each fixture. ORDER matters when the run also needs a lying Cues table: offset first, inject after, because a matroska remux regenerates Cues from the real keyframes and would undo the lie.

**Resolution.** The two errors do NOT have the same resolution, which is why `capFr` is printed.

- `axisErr` differences two frame-grid values read out of one `copyPixelBuffer` call. It is a whole number of frames, and every digit of it is a reading.
- `capErr` differences that same grid value against the engine's continuous clock. Below one frame it carries the sub-frame phase of the sampling instant: `capFr=+0.40` is the same frame, `capFr=+1.80` is not.
- Two runs whose `capErr` differs by less than a frame have not been shown to differ.
- Read the verdict per axis in `capFr`, whole frames. A single tick carries up to two frames of the probe's own quantisation. A mean of `|capErr|` over ticks does NOT buy resolution below that quantum; it averages the sampling phase (AE#418 round 11).

#### What the picture probe settled (AE#418, AE#481)

This is the measurement history of segment placement on the native path. Each round is listed with what it found and the log lines it added.

**The first finding.** AVPlayer presents a segment at the position the PLAYLIST gives it, not at the tfdt it carries, and then plays continuously from there. So a gate that opened below its boundary shifts the whole run by the re-aim (`axisErr=-13.583` on a 13.583 s re-aim, constant for the run).

**Round 3: a second oracle that works on a device with no capture card.** `AVPlayerItem.loadedTimeRanges`: the range holding the playhead begins where AVPlayer PLACED that run, so `advertised - rangeStart` is the axis it composed onto, measured instead of assumed. The engine reads it after every VOD seam and says what it found: `#418 segN placement confirmed`, or `#418 segN placed on base Xs, not Ys`. The second is a placement this side counted that AVPlayer discarded (a fetch during a seek burst, which is a fetch and not a placement). Against the picture probe the two oracles agree exactly: a resume predicting a seam at `52.000` reads `loaded [52.000-64.958]`, and a far seek predicting `21.000` reads `[21.000-38.622]`.

**Round 4: the reading WINS.** Round 3 collapsed the measured base onto the nearest axis the session had already published. That made the prediction the yardstick for the measurement meant to check it:

- a base matching no prediction was refused (a reporter's session composed to `-26.152` while two readings 400 s of media apart both said `-10.93`, and ended 42.6 s out);
- a base a frame or two off was called a confirmation, so that difference stayed in the axis and the next placement composed on top of it.

What decides now is where the reading came from: a run that overlaps nothing the item held when the placement was recorded, or one that opened ABOVE it. A start that walked DOWNWARD is the same run backfilling, which AVPlayer does after a run opens, and is never read. The lines are:

- `#418 segN placement confirmed` (residual under a millisecond)
- `#418 segN placed on base Xs, not Ys (... residual Zs)`
- `#418 segN opened no run of its own to measure`
- `#418 segN superseded before it was measured`

Round 4 also needs a fixture with B-FRAMES, and `Scripts/timecode-fixture.sh` now writes one (`tc-bframes.mkv`). `-preset ultrafast` disables them, so on `tc-drought.mkv` a segment's dts and pts are one number and the gate's offset is the same either way. On real content they are not: the gate opens on a random-access point in DECODE order, and taking the offset there put the axis `video_delay` frames under the truth on every epoch. The pair isolates exactly that.

**Round 8: how far a placement sits below its axis is MEASURED, in seconds.** Rounds 5, 6 and 7 read that distance as a multiple of the epoch's presentation lead: round 5 shipped the multiple as arithmetic, round 6 measured it per source, round 7 held the median of its readings. The premise was that the distance is a geometry of the source. It is not. `Scripts/timecode-fixture.sh` writes three clips identical except for their reorder depth. Same burst arm over a throttled origin (`Scripts/slowrange.py`, 3200 kbps + 100 ms), `--picture-probe` reading the axis off AVPlayer's own video output, 2 runs each, every run identical:

| clip | gate lead | placement 2 sits | placement 3 sits |
|---|---|---|---|
| `tc-cues-lie.mkv` | 0.000 (no reordering) | 0.000 below its axis | **0.042 below its axis** |
| `tc-bf1-cues-lie.mkv` | 0.042 (one frame) | 0.000 | 0.083 |
| `tc-bf-cues-lie.mkv` | 0.083 (two frames) | 0.083 | 0.125 |

The bold cell retires the model. That clip has `has_b_frames=0` and every gate opens with `lead=0`, yet its third placement still sits a frame below its axis. A quantity that is nonzero where the lead is exactly zero is not a multiple of the lead, and no coefficient can express it. The middle row retires the source-law premise separately: one source, two placements, 0.000 then 0.083.

So the session now carries the distance in the units it corrects, reads it off the same placement reading that already measures the base, and every reading teaches it, a confirmation included. That also fixes the starvation round 7 shipped: only a placement carrying a lead could teach, and on a source without reordering, or on any session whose placements are AE#412 re-cuts (worth 0 and lead 0 by construction), there never is one. Measured on `tc-wide-cues-lie.mkv`: 13 of 13 placements across two runs carried `lead 0.000s`, so the parameter could not move at all.

Each `placed` line names what it composed with (`sitting 0.083s below its axis`), and a reading that moves it says so: `#418 segN sat Xs below the axis it composed on, not Ys; the next composition starts there`. An item's FIRST placement is no longer a special case: with nothing measured yet the distance is zero, which is what AVPlayer does there (measured base 0.000 on every arm of every fixture). The gate-open line still prints `lead=`, now purely as a source fact.

**Round 9: the lesson on the reading's own line.** Round 8 printed only the MOVES, and two different things were silent under that. Every verdict line now ends in one of three clauses:

- `taught the distance Xs`: an own-run reading that moved it, with the `sat` line under it.
- `taught the standing distance Xs again`: an own-run reading that agreed with it.
- `taught nothing, read off a rebuilt timeline; the distance stays Xs`. This is the useful one. A rebuilt-timeline reading corrects the axis like any other (by 28.000 s on `tc-wide-cues-lie.mkv`), and round 7 refuses it the parameter on purpose, so its correction line was otherwise indistinguishable from one that had just taught a 28 s lesson.

**AE#481: the axis belongs to the RUN.** A seek burst heals this case inside a second, so those ten rounds could not see it. The axis belongs to the RUN a re-aimed segment opened, not to the timeline from its advertised start on. Run the same chain with the re-anchoring seek LAST (`--seek-count 5 --seek-pattern 65,60,70,58,75`, served through `Scripts/slowrange.py` at 600 kbps / 300 ms): the picture reads `pic - picItem` of -9.000 at item 53.000 and 0.000 everywhere the landing goes, while the session keeps mapping with -9.000 and `capErr` sits at +9.017 to the end of the run.

A seek landing now reads what its run carries, and says so: `#481 the run holding the landing at item Xs opens at Ys, which is segN's own playlist position, so it carries Zs and not the Ws this session was mapping with`.

- The discriminator is that opening, asked of ONE segment: the first one the local server answered after the seek, whose content opens that run. It goes into a timeline carrying an axis at the seam that axis predicts, and into a timeline carrying nothing at its own position. Those are round 7's two admissible answers.
- Asked of the whole plan, the same rule publishes on a coincidence (31 boundaries over 120 s against a half-second tolerance: measured, a 0.000 axis written into a timeline carrying -27.875 s).
- Measured on the arm above, `capErr` goes from +9.037 to +0.037: 216 frames, and the only unambiguous number in the set. The 24-seek arms it must not touch are unchanged (10 placements, axis -34.376, no reading fired in 2 of 2 runs).
- On the two slow arms the `capErr` tail moves onto the same one-frame lattice pair the fast arm sits on (`+0.009` / `-0.033`). That is a sub-frame move and carries no accuracy claim either way. An earlier revision of this paragraph read it as an improvement from 0.0230 and 0.0411 to 0.0162, which is the mistake AE#418 round 11 documents on both sides of that thread.

### Resume landing (AE#724)

A run with `--start-position` and nothing else that repositions (no `--seek-every`, no host calls besides `play`, no audio switch) is also judged on where the resume LANDS. A clock that reads more than a second behind the anchor in the first three ticks exits 2 with `VERDICT: resume clock fell behind its anchor`.

That is AE#724. The plain clock-advances check could not see it, because the broken session kept advancing, only from the wrong place. A resume on a long-GOP source repositions to the keyframe before its target, so its first decoded audio sample arrives up to a GOP early, and the software host used to move its clock back onto that sample. Ten-second GOPs reproduce it; two-second ones never do:

```bash
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=24 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 30 -c:v libx264 -preset ultrafast -g 240 -keyint_min 240 -sc_threshold 0 -c:a aac gop240.mp4
aetherctl play --sw --start-position 17.3 --seconds 5 file://$PWD/gop240.mp4
aetherctl play --sw --paused --host-calls play --start-position 17.3 --seconds 5 file://$PWD/gop240.mp4
```

Before the fix both read `clock re-anchored to first sample: anchor=9.984s (load anchor 17.300s ...)` and `cur=10.8` at the first tick. After it: `cur=18.2` and no re-anchor.

`--paused` alone (no `play`) is not judged, but its ticks are the observable for the second half of the same report. A paused resume read `cur=0.00` until play, because the host published its still unarmed synchronizer over the anchor. It now reads `cur=17.30`.

### Memory census (`--malloc-census`)

`--malloc-census` turns on the large-allocation census (`AetherEngine.setLargeAllocationCensusEnabled`) for the run. Use it to trace a footprint that grows where the segment budget says it should not.

Besides the 30 s sample it arms a jump trigger. The 30 s memprobe cannot catch a failure that completes inside one sample (every kill on #220 had that shape). A counter polled at `--census-hz N` runs the zone walk once it climbs `--census-threshold-mb N` above its running high-water. Both flags do nothing without `--malloc-census`.

### Audio stats (`--audio-stats`)

`--audio-stats` installs the engine audio tap and watches the decoded PCM itself:

- an `AGAP` line for every source-PTS discontinuity > 2 ms between consecutive buffers;
- per second, appended to the telemetry: `alead` (last decoded audio PTS minus the synchronizer clock) and `abufs` (buffers delivered).

`alead` is the audio renderer's safety margin. On the SW live path the look-ahead pump holds it near `AudioLookaheadPolicy.targetLeadSeconds`. A collapse toward zero means the source or the feeder cannot keep real time. This is how the #107 audio-chopping report was diagnosed.

### Recording (`--record`)

`--record <path>` records the live source to a file from the connection the session already holds (AE#560). It calls the same `AetherEngine.startRecording(to:)` a host calls. The output is MPEG-TS, a stream copy of the SOURCE packets taken before any audio bridging. So a bridged channel plays as FLAC and records as its original TrueHD or DTS. This arm proves the tap sits on the right side of the bridge:

```bash
aetherctl play --live --live-ingest --seconds 60 --record /tmp/rec.ts <master.m3u8>
ffprobe -v error -show_streams -select_streams a /tmp/rec.ts | grep codec_name   # NOT flac
```

Only `.loopback` and `.software` can record. On the remote-HLS bypass AVFoundation holds the source connection and the engine never sees a byte, so the run prints `RECORD refused: unsupportedRoute(remoteBypass)` and exits 3 instead of producing an empty file. A requested recording that produces no bytes, or that ends `.failed`, is also exit 3. A capability the flag asked for and did not get is a machine-checkable failure, not a green run somebody has to read the log for.

A truncated MPEG-TS stays playable, so the kill case is a real arm:

```bash
aetherctl play --live --live-ingest --seconds 120 --record /tmp/killed.ts <master.m3u8> &
sleep 30; kill -9 %1
ffprobe -v error -show_format /tmp/killed.ts    # readable, duration near 30 s
```

## swdecode

Opens `SoftwareVideoDecoder` for the source's video stream, feeds it packets, and reports counters plus first-frame metadata: pixel format, dimensions, and `firstFrameColor` (the colour tags the picture reaches the display layer with, AE#654). It tests the SW decode path end to end without a render layer. Useful for legacy codecs (MPEG-4 Part 2, MPEG-2, VC-1), and for AV1 / VP9 on platforms where the native AVPlayer path does not accept them.

**Usage:** `aetherctl swdecode [--frames N] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--frames N` | Most packets to read / frames to wait for. | 100 |

The verdict tells three outcomes apart:

| Verdict | Likely cause |
|---|---|
| Decoder open failed | FFmpegBuild gate, or malformed extradata. |
| Decoder opened but no frames produced | Pixel-format conversion, or no IDR in the window. |
| SW decode end-to-end healthy | If real playback still hangs, the failure is downstream: `SoftwarePlaybackHost` frame enqueue, display-layer attach, or audio-clock sync. |

Backed by the public static API `AetherEngine.swDecodeProbe(url:maxPackets:options:)`, which returns `SoftwareDecodeProbeResult`. Hosts can use the same probe in their own diagnostic overlays.

## seektest

Drives a real AVPlayer (native loopback-HLS path) through a burst of rapid seeks (AetherEngine#35). It reports the producer-restart coalescing behavior, the longest "wedge" (state `.playing` but the clock frozen), and the final settle accuracy. Needs `> 30 s` of seekable VOD.

**Usage:** `aetherctl seektest [--seeks N] [--gap-ms N] [--settle N] [--throttle-kbps N] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--seeks N` | Seeks in the burst. | 40 |
| `--gap-ms N` | Gap between seeks. | 60 |
| `--settle N` | Seconds to settle after the burst. | 5.0 |
| `--throttle-kbps N` | Caps source-IO delivery to simulate a slow CDN and force rebuffers during the burst (see [serve](#throttle-and-start-position)). | no cap |

**Clock bounce and `isSeeking`.** A concurrent sampler checks the seek clock-bounce / `isSeeking` signal (AetherEngine#37 / #38). A single backward seek must not bounce the clock back through the pre-seek position, and `isSeeking` must span the real landing.

**The seek event ledger.** The run ends with a `#38 SEEK EVENT LEDGER`:

- every `.began` must reach a terminal event (an unpaired one is a stranded in-flight window);
- `.stalled` seeks are listed with any late `.landed` that followed them;
- **seek latency** is printed per seek (`.began` to its first terminal event) with min / median / max. Read an A/B about the cost of work ON the seek path off this. Quote the median and the max, never a mean, because the tail belongs to the source, not to the change under test.

The burst is serialised, so every seek here ends before the next is issued. To put a seek on top of an unsettled one, use `play --seek-every 1 --seek-count N` against an origin below media rate: `phase=seeking` then holds across the run and the ledger shows supersedes.

**Exit code.** 1 when a printed `<-- FAIL` line is among the `#37` bounce, the `#38` `isSeeking` window, the `#38` event pair and the unpaired-`began` ledger, or when the `#65` block ends in `PRODUCER WEDGE (UNRECOVERED)`. The final `VERDICT` line then names them. The restart tallies are informational: they are for comparing two builds, and a run that only prints them exits 0.

**Parks versus wedges (the `#65` block).** It separates two parks that look alike in a log and mean opposite things (AE#528):

- A park whose `PARK` line reads `stuck=0s` is backpressure behind a consumer that is still declaring fetch targets. That is what a viewer scrubbing backwards through resident content looks like, and the wedge breaker correctly stays quiet.
- `stuck=` counts seconds since the consumer last declared a target. `idle=` counts only those in which it did not render either. The breaker trips on `idle=` (AE#649).
- A park that reads `(consumer quiet, still playing)` with `stuck=` climbing and `idle=0s` is AVPlayer playing out a deep forward buffer between fetch bursts. A cellular iPhone does that for up to a minute at a time, and it does not trip the breaker either.
- When every park of the run logged `idle=0s`, the run says `PARKED BEHIND A LIVE CONSUMER (not a wedge)`.
- A wedge is a park whose `idle=` climbs. That one still breaks and re-anchors.

## extract

Opens a `FrameExtractor` against the source and pulls a still frame. The first frame is written to `aetherctl-extract-<mode>.png` in aetherctl's private per-user temporary directory (the path is printed).

**Usage:** `aetherctl extract [--at <sec>] [--preview|--snapshot] [--width <px>] [--loops <n>] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--at <sec>` | Seek position. | 60.0 |
| `--width <px>` | Max output width in thumbnail and preview mode. | 320 |
| `--preview` | Frame-accurate decode, downscaled to `--width`. | off |
| `--snapshot` | Frame-accurate decode at full resolution. | off |
| `--loops <n>` | Repeats the extraction, cycling through eight positions. | 1 |

Thumbnail mode (the default) snaps to the nearest keyframe and downscales to `--width`. `--preview` and `--snapshot` are mutually exclusive. `--loops` pairs with `leaks --atExit` to check that the decode-context teardown is clean:

```bash
swift run aetherctl extract --at 612 --snapshot <url>          # frame-accurate still
swift run aetherctl extract --at 612 --preview --width 480 <url> # accurate downscaled preview
swift run aetherctl extract --width 480 <url>                  # keyframe thumbnail
leaks --atExit -- .build/debug/aetherctl extract --loops 8 <url>   # leak sweep
```

## scrubpreview

Tests scrub previews. By default it covers Dolby Vision Profile 5 / 10.0 sources, whose previews the compositor draws in a view. With `--stills` it covers any source.

**Usage:** `aetherctl scrubpreview [--warm S] [--at s1,s2,...] [--keep DIR] [--stills] [--throttle-kbps N] [--max-concurrent-requests N] [--forward-buffer-segments N] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--warm S` | Seconds to play before asking. | 4 |
| `--at s1,s2,...` | Positions to ask for. | `2,5,30,50,65` |
| `--keep DIR` | Copies the session's preview files out before teardown. | off |
| `--throttle-kbps N` | Caps source delivery, which keeps the producer close to the playhead. | no cap |
| `--stills` | Asks `scrubPreviewFrame` instead, for any source. | off |
| `--max-concurrent-requests N` | Passes through to `LoadOptions`. | engine default |
| `--forward-buffer-segments N` | Passes through to `LoadOptions`. | engine default |

**Default mode.** Loads the source on the native path, plays it for `--warm` seconds, then asks `showScrubPreview(atSeconds:in:)` for each position. For each it prints whether a picture came, how long it took, the span it stands for, and whether the position was resident.

- A position inside the resident window is cut from the segment cache.
- A position outside it is read off the source as the keyframe that opens its plan segment.
- So `--throttle-kbps N` lets one run cover both.
- With `--keep DIR`, `seg<N>-*.mp4` came from the cache and `plan<N>-*.mp4` from the source. Compare them with `ffprobe -show_data_hash` against the source's own keyframes for a byte-for-byte check.

Exit codes: `0` every position showed a picture, `1` load failed or the source does not draw its previews in a view, `2` at least one position showed none.

```bash
swift run aetherctl scrubpreview --throttle-kbps 20000 --at 2,30,50,65 --keep /tmp/previews <p5-source>
```

**`--stills` mode.** Asks `scrubPreviewFrame` and prints, for each position, whether it was resident, the `actualSeconds` of the still, and the span it names. A position outside the resident window is answered by the keyframe still ladder, so warm long enough for it: 15 s grace, then one rung every 2 s while the origin is idle. `--max-concurrent-requests 1` is the one-connection plan the ladder exists for. Put a Range-logging origin in front and read it alongside: every rung must arrive with nothing else in flight.

```bash
swift run aetherctl scrubpreview --stills --max-concurrent-requests 1 --warm 75 --at 20,300,610,1150 http://127.0.0.1:8931/movie.mkv
```

## dualsubs

Activates two subtitle tracks at once on one source (primary + secondary) and prints both cue lists. It exercises the dual / bilingual subtitle path.

**Usage:** `aetherctl dualsubs <file> --primary <streamIndex> --secondary <streamIndex> [--seek <seconds>]`

| Flag | Meaning | Default |
|---|---|---|
| `--primary <streamIndex>` | Primary subtitle track. | required |
| `--secondary <streamIndex>` | Secondary subtitle track. | required |
| `--seek <seconds>` | Jumps first, so you can confirm both channels re-resolve after a seek. | no seek |

## audio

Plays a source through the audio-only pipeline (`LoadOptions.audioOnly`) and reports which host took it: bare AVPlayer, or the FFmpeg renderer path. It exercises the same dispatch a music host sees.

**Usage:** `aetherctl audio [--seconds N] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--seconds N` | Run length. | 10 |

## audiotap

Verifies the PCM audio tap (#95) across the stream-copy, bridge and software audio paths.

**Usage:** `aetherctl audiotap [--duration S] [--out PATH.wav] [--remote | --software] [--dialogue] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--duration S` | Seconds of audio to decode. | 30 |
| `--out PATH.wav` | Output path. | `audiotap.wav` in aetherctl's private per-user temporary directory |
| `--remote` | Drives the remote-HLS delivery path. | off (loopback) |
| `--software` | Drives the SW sink through a real session. | off |
| `--dialogue` | Installs the tap with `channels: .dialogue` (#908). | off |

**Default (loopback).** Brings up the loopback session headless and decodes the audio tap as fast as segments are produced. It writes mono Float32 48 kHz WAV and prints buffer count, PCM seconds, discontinuity count, and the covered `sourceTime` span. A clean run reports exactly one discontinuity (the install itself).

**`--remote`** drives the remote-HLS delivery path instead: direct AVPlayer ingest of an HLS URL, no loopback. That covers rendition / variant resolution, segment fetch + decrypt, and playhead-follow decode.

**`--software`** drives the third delivery path, the SW sink (`AudioTapPCMConverter`). The other two modes cannot reach it: they drive their readers directly, while the sink only exists inside a real session. So this mode loads the source through the whole engine, fails if it did not route to the software host, installs the tap through the public `installAudioTap()`, and plays. The sink then runs exactly as it does in a host.

- It is bound to the wall clock (the SW host decodes in real time).
- It reports `peak` next to the buffer count, because the two ways this path fails otherwise look identical in a report. **Exit 3 covers both no buffers at all and buffers of digital silence**, which a consumer cannot tell from a muted source.
- That gap is real: with no harness here, a force unwrap that trapped on the FIRST buffer of any multichannel track shipped in 6.1.3 and survived to main (#400). The silent-downmix defect under it only showed once the trap was gone.

Software routing needs a source the native path declines:

```bash
ffmpeg -f lavfi -i testsrc2 -f lavfi -i sine -c:v libvpx-vp9 -c:a aac -shortest clip.mkv
```

Add `-af "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0"` for the multichannel case, and `-af "pan=quad|c0=c0|c1=c0|c2=c0|c3=c0"` for the layout AVAudioConverter refuses to mix.

**`--dialogue`** works on any of the three paths and adds `dialogue=N/M` to the report: how many buffers carried the centre channel alone, not the downmix fallback. A fixture that tells the two apart puts one tone in the centre and another everywhere else:

```bash
ffmpeg -f lavfi -i testsrc2=duration=20 -f lavfi -i sine=frequency=440:duration=20 -f lavfi -i sine=frequency=220:duration=20 -filter_complex "[1:a][2:a]amerge=inputs=2,pan=5.1|FL=c1|FR=c1|FC=0.5*c0|LFE=c1|BL=c1|BR=c1[a]" -map 0:v -map "[a]" -c:v libx264 -pix_fmt yuv420p -c:a aac fc51.mp4
```

The dialogue WAV must carry the 440 Hz tone and none of the 220 Hz one.

## bgaudio

Verifies SW-path background audio (the iOS keepalive) headless on macOS, where the `UIApplication` background lifecycle that normally drives it does not exist. The flag and counters are exposed through DEBUG-only engine hooks, so this command is not available in a Release build.

**Usage:** `aetherctl bgaudio [--fg N] [--bg N] [--lose-session] <url>`

| Flag | Meaning | Default |
|---|---|---|
| `--fg N` | Foreground seconds. | 3 |
| `--bg N` | Background seconds. | 6 |
| `--lose-session` | Invalidates the VideoToolbox session as an iOS screen lock does (AE#739). | off |

**What it does.** Loads a software-routed source through the full engine, plays a foreground baseline, switches the SW host into background-audio-only, then returns to foreground. Each tick reports the audio clock, the SW video-frame count and the process memory footprint, and the run ends with a verdict. A healthy run shows:

- the clock advancing through the background phase (audio alive),
- the video-frame count flat (video dropped),
- the footprint roughly flat (the loop paces on the audio renderer instead of buffering the rest of the file),
- the video-frame count rising again on foreground return (resync at the next keyframe).

Make a quick software-path clip with:

```bash
ffmpeg -f lavfi -i testsrc2 -f lavfi -i sine -c:v libvpx-vp9 -c:a aac -shortest clip.mkv
```

**`--lose-session`** (AE#739) reproduces what an iOS screen lock does to the SW host's VideoToolbox session. Halfway through the foreground phase, and again right after entering background-audio-only, it invalidates the session in place. The next decode then returns `kVTInvalidSessionErr` (-12903), exactly as in a field log.

- It forces the software path and needs an HEVC source, since only HEVC reaches the hardware decoder there: `ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=24 -f lavfi -i sine -t 30 -c:v libx265 -x265-params keyint=48 -tag:v hvc1 -c:a aac clip.mp4`.
- It prints the engine log, so the loss, rebuild and reposition lines are visible.
- It fails unless video frames rise again after the foreground loss (the host rebuilds the session and repositions to the playhead) and after the foreground return (rebuilt unconditionally, resumes at the next keyframe). Before the fix both counts stayed at +0.

## customio

Wraps a local file in a custom `IOReader` and plays it through `load(source:)`.

**Usage:**

- `aetherctl customio [--memory] [--forward-only] [--audio-only] [--reload] [--switch-audio] [--select-subs] [--extract] [--audio-index N] [--reload-decode-path automatic|software] <file>`
- `aetherctl customio --live [live flags] <file.ts>` (see [The `--live` spool](#the---live-spool-ae445))

| Flag | Meaning | Default |
|---|---|---|
| `--memory` | Reads through `DataIOReader`. | off |
| `--forward-only` | Drops the seek capability. | off |
| `--audio-only` | Routes through the audio-only pipeline. | off |
| `--reload` | Exercises background reload. | off |
| `--switch-audio` | Exercises an audio-track switch. | off |
| `--select-subs` | Exercises embedded subtitles. | off |
| `--extract` | Exercises scrub preview. | off |
| `--audio-index N` | Names the audio stream at LOAD, and prints what it asked for next to what it got. | none |
| `--reload-decode-path automatic\|software` | Makes the reload's correction the decode path (AE#461). Works with `--reload`, and with `--live --reload-at`. | none |

**`--audio-index` with `--forward-only`.** This pair answers the one question a live host has: `selectAudioTrack` refuses such a source (it would mean rebuilding a drained FIFO), so naming the stream at load is the only way onto another track. This is where that was measured, not assumed (Sodalite#64).

### The `--live` spool (AE#445)

`customio --live <file.ts>` puts the same file behind a reader shaped like a live host's. It measures the memory a host-owned live spool costs.

The reader:

- is paced at `--rate-kbps` against the wall clock,
- blocks at the edge instead of ever returning EOF,
- answers `AVSEEK_SIZE` negative,
- is seekable by logical offset.

| Flag | Meaning | Default |
|---|---|---|
| `--rate-kbps N` | Pacing rate. | 8000 |
| `--seconds N` | Run length. | 720 |
| `--dvr-window N` | Timeshift. | none |
| `--report-size` | Makes the size known. | off |
| `--no-wrap` | Stops it looping the file. | off (loops) |
| `--malloc-census` | Large-allocation census, as on `play`. | off |
| `--foundation-reader` | Swaps in a `FileHandle.readData` reader arm. | off (POSIX `pread`) |
| `--host-carry none\|removeFirst\|subdata` | Adds a host parse carry on the delivery path. | `none` |
| `--reload-at S` | Rebuilds the live session in place S seconds in. | off |
| `--cancel-latches` | A reader that treats `cancel()` as terminal. | off |
| `--reload-decode-path automatic\|software` | Makes the rebuild's correction the decode path. | none |
| `--reader-axis absolute\|join\|mismatched` | Which byte axis the reader speaks (AE#460 round 3). | `absolute` |
| `--join-offset-mb N` | Where the join sits, for `join` and `mismatched`. | 4 |

**The measurement.** Every ten seconds it prints `physFP` and its slope. It closes with that slope stated against the source's own mux rate:

```
VERDICT: physFP 105 -> 402 MB over 240s = 1.24 MB/s (source mux rate 0.95 MB/s, retention ratio 1.30)
```

A ratio near 1 means the session keeps one byte for every byte it plays, which on a source that never EOFs is unbounded by construction. Near 0 means the footprint is the session's, not the stream's. Before AE#445 the custom-source live shape had no harness at all. The defect it found (host reader callbacks ran on the pump's undrained thread) was reachable by every custom reader and visible to none of the engine's own buckets.

**Which reader arm runs decides what the ratio is about.**

- The default arm reads with `pread` straight into the engine's buffer and allocates nothing. Whatever it retains is the ENGINE's.
- `--foundation-reader` uses `FileHandle.readData`, which strands one autoreleased `Data` per read on any thread that never drains a pool. Whatever it retains is the HOST's.

Run both. The Foundation arm is the control that proves the pool drains; the POSIX arm measures the engine. History: AE#445 round 1 shipped only the Foundation arm and measured ratio 1.00 before the bridge pool and 0.00 after, which looked like the reporter's defect reproduced and fixed. It was not: his adapter `pread`s and allocates nothing, so the run had reproduced the harness's own retention with his signature. A harness that brings the cause with it matches the shape and answers a different question. Only a second arm that allocates nothing can tell those apart.

**Read the retention ratio over a long run, not a short one.** The slope anchors at 60 s to skip the load step, which is exactly where `--reload-at 60` puts a SECOND step: the software pipeline's own baseline. A 100 s run reads ratio 1.31 and means nothing by it. A 260 s run shows `physFP` stepping 25 to 66 MB across the switch and then flat at 67 for 140 s: ratio 0.18 and still falling, which is a step being amortized, not a session retaining anything.

#### `--reload-at` and `--cancel-latches`

`--reload-at S` rebuilds the live session in place S seconds in. The correction it applies (`httpHeaders`) is inert on a custom source on purpose: the arm measures the REBUILD, not the field. It reports the playhead and the reader's cursor on both sides of it, and the closing `LOOKBACK` line states how far back the rebuild reached:

```
  RELOAD at t=60s: playhead=41.52s cursor=15.0MB edge=15.0MB
  RELOAD done: playhead 41.52s -> 0.00s, reader cursor 15.0 -> 15.8 MB, edge 15.0 -> 15.8 MB
LOOKBACK: 7 seeks, deepest reach-back 0.0 MB behind the live edge (0 s of source at this rate)
```

A reach-back of 0 MB is the rebuild rejoining at the edge. Before the AE#460 follow-up the same run reported 15.0 MB (61 s of source) and a playhead of 1.90 s: the reopen rewound the host's spool to its base and re-read the whole delivered window.

`--cancel-latches` is a control, not a defect. A reader that treats `cancel()` as terminal cannot serve the rebuild that reuses it, so the reopen dies on stream info and the correction throws. Which death it dies depends on the reader's own convention: this arm returns a negative value and gets libavformat's `Operation not permitted`, while a reader that answers a closed stream with 0 is mapped to `AVERROR_EOF` and ends the session instead of failing it.

#### `--reader-axis` (AE#460 round 3)

`--reader-axis absolute|join|mismatched` decides which byte axis the harness reader speaks. `--join-offset-mb N` (default 4) places the join.

- **`absolute`** (default) is the harness's own shape: every offset is a position in the file.
- **`join`** is the shape of a host spool that joined a running stream. The reader reports and takes offsets counted from that join, so the cursor the alignment reads and the `SEEK_SET` it hands back compose to the identity. This arm turns that claim from a code read into a measurement:

```
  RELOAD at t=45s: playhead=38.82s cursor=11.5MB edge=11.5MB backend=native
[Demuxer] live reopen aligned to the reader's cursor at 9994240 bytes
LOOKBACK: 8 seeks, deepest reach-back 0.0 MB behind the live edge (0 s of source at this rate)
```

The aligned offset is 9.5 MB, not the 11.5 MB cursor the run prints: it is bytes since the join. Reading it as a file position is the mistake this arm makes visible.

- **`mismatched`** is the non-conforming control, in the spirit of `--cancel-latches`. It reports absolute positions while taking `SEEK_SET` from the join. Each half is defensible alone, but together they move the source by the join offset every time the engine asks where it is:

```
[Demuxer] custom source: the reader reported byte 2097152 and answered a seek back to it with 4194304,
so its position report and its SEEK_SET argument are not on the same axis; the source has been
repositioned by the seekability probe
[Demuxer] live reopen aligned the axis to 4194304 bytes, but the reader then reported 6291456: ...
```

On that arm: 2 MB at load and 2 MB more at the reload, after which the session sat 20 s in `loading` reading a stretch the host had not delivered yet.

#### `--reload-decode-path` (AE#461 follow-up)

`--reload-decode-path automatic|software` makes the correction the decode path itself, on `customio` with `--reload` and on `customio --live` with `--reload-at`. The header probe those arms apply by default is inert on a custom source on purpose, so it measures the rebuild and can never measure this field; this field is what a host actually corrects. Both arms print the backend on each side of the rebuild, which is the whole observable:

```
  RELOAD applying preferredDecodePath=software: playhead=0.00s backend=native
[AetherEngine] #461: reload re-routing this session native -> software on the host's preference (custom source: true)
  RELOAD done: playhead 0.00s -> 0.33s, backend native -> software, decoder=libavcodec H264 (SW)
```

Before the follow-up the same run logged `#460: reload applying preferredDecodePath` and then `backend native -> native, decoder=VideoToolbox H264 (HW)`: accepted, named in the log, ignored.

On a source the software path cannot represent, the arm measures the OTHER half: that a refusal costs nothing. It reports the state the refusal left behind instead of exiting on the throw. The Dolby browser test kit is the fixture, because it carries its own control:

```
# Profile 5 (IPT-only): refused, and the session is untouched
  REFUSED state=playing backend=native playhead=0.00s (was 0.00s) decoder=VideoToolbox HEVC (HW)
VERDICT: correction refused, session untouched and still playing
# Profile 8.1, same material and grading: honoured
  RELOAD done: playhead 0.00s -> 0.26s, backend native -> software, decoder=libavcodec HEVC (SW)
```

#### `--host-carry` (a host-side cause)

`--host-carry removeFirst|subdata` is the third arm. It names a cause instead of measuring the engine.

Round 3's census on the reporter's device pinned his footprint to ONE `REALLOC`-tagged block, growing on an exact x1.25 ladder and holding every byte the session had consumed. That factor is Foundation's: `Data` grows a large buffer by `newLength >> 2`, while `av_fast_realloc` adds a sixteenth and FFmpeg's AVIO dynamic buffer a half. So the block is a Swift `Data`. The one `Data` shape that grows like that while its `count` stays tiny is a parse carry consumed from the front with `removeFirst`. That only advances the slice's lower bound and leaves the backing store holding everything below it.

- `--host-carry removeFirst` puts exactly that carry on the harness's delivery path, so the tool that measures the engine at ratio 0.00 can also produce ratio 1.00 on demand.
- `--host-carry subdata` is the same carry re-based, i.e. the fix.

Both arms print the tell every ten seconds:

```
  t=240s ... physFP=447MB srcMB=417.2 growthMBps=1.67 carryCount=112B carryStart=417.1MB
```

A carry whose `count` is under one TS packet while its slice's lower bound tracks the consumed stream is riding a backing allocation that large. `startIndex` is the cheapest probe there is for this defect, in any host, without Instruments.

## smbtest

Connects to an SMB2/3 share with `SMBConnection` (SMBClient backend), wraps the file in `SMBIOReader`, and runs a sequential-throughput pass plus a random-seek check. It validates the SMB byte source without a device. macOS only. Needs the optional `AetherEngineSMB` product (`swift build --product aetherctl` pulls it in).

**Usage:** `aetherctl smbtest [--reads N] <smb-url>`

| Flag | Meaning | Default |
|---|---|---|
| `--reads N` | Number of random seeks. | 64 |

```bash
swift run aetherctl smbtest "smb://user:pass@host/share/path/to/file.mkv" --reads 128
```

How the seek check works: the offsets are drawn first, the sequential pass records the 16 bytes at each, and every seeked read must come back whole and equal to those bytes. A failed or short read fails the run.

Credentials default to guest when they are not in the URL. URL-encode special characters in the password.

## live

Runs a live MPEG-TS session against a built-in fixture. The fixture serves an endless broadcast by looping a seed `.ts` with rewritten timestamps. Flags simulate the failure modes the live path hardens against.

**Usage:** `aetherctl live [flags]`

| Flag | Meaning | Default |
|---|---|---|
| `--seconds N` | Run length. | 20 |
| `--seed <ts>` | Overrides the seed clip. | `Fixtures/user/h264-ts-sample.ts` |
| `--sw` | Forces the software live path. | off |
| `--dvr-window N` | Timeshift (`LoadOptions.dvrWindowSeconds`). | none (live-only, bounded by the 60 s floor) |
| `--live-only` | Loads with no DVR window at all. | off |
| `--start-position S` | Loads with a resume anchor. | none |
| `--standard-join` | `LoadOptions.liveJoinProfile = .standard`. | `.fastZap` |
| `--fast-zap` | Accepted and ignored. | |
| `--live-cushion N` | `LoadOptions.liveEdgeCushionSeconds`. | engine default |
| `--no-blocking-reload` | `LoadOptions.liveBlockingReload = false` (AE#446). | off |
| `--force-master` | Routes the session behind its master playlist with `LoadOptions.prepareNativeSubtitles` (AE#454). | off |
| `--sliding` | Accepted and ignored. | |
| **Origin shape** | | |
| `--realtime` | 1x wall-clock pacing. | off |
| `--realtime-rate X` | Holds the origin at X times wall clock. Implies `--realtime`. | |
| `--preroll N` | Backlog seconds the paced fixture bursts before 1x pacing. | 30 |
| `--origin-lead N` | How far ahead of the wall clock the paced origin may run. | 2 |
| `--drop-after N` | Mid-stream connection drop + reconnect. | off |
| `--discontinuity-at N` | Program-boundary PTS / PCR jump. | off |
| `--freeze-after N` | Freezes the upstream with the connection still open. | off |
| `--unfreeze-after N` | Lets the frozen upstream deliver again after N seconds. | off |
| `--rewind-before-freeze N` | Parks the playhead inside the DVR window first. | off |
| **Tests and measurement** | | |
| `--reload-test` | Live rejoin end to end, including the full-backlog replay shape some origins serve on reconnect. | off |
| `--rewind-test` | The DVR rewind-and-return matrix variant. | off |
| `--rewind-hold N` | Parks the playhead N seconds behind the edge and HOLDS it there. | off |
| `--force-recovery-reload-at N` | Drives the stage-2 recovery reload without waiting for a real item death. | off |
| `--measure-rss` | Sliding-window retention: prints phys_footprint + resident_size every 30 s. | off |
| `--report-cache-bytes` | Tracks the on-disk DVR footprint every 60 s. | off |
| `--serve-only` | Parks the fixture without attaching an engine (for raw `curl` / `ffprobe` inspection). | off |
| `--gen-highbitrate-seed` | Generates a ~22 Mbps 1080p H.264 MPEG-TS seed (for RSS-retention measurement), then exits. | off |

Without `--serve-only` and the test flags, the run reports whether `isLive` is true, state is `.playing`, and currentTime advanced past ~15 s.

### Origin pacing

- **`--preroll N`**: `0` models a strict-realtime origin with no backlog.
- **`--origin-lead N`** is the standing distance a raw live client ends up reading behind the origin. The built-in 2 s sits exactly on the old live-edge tolerance and hides both sides of it. `--origin-lead 6` joins a session six seconds behind the reader's frontier, and its post-rejoin distance then sawtooths 1.4 to 2.6 s (the Sodalite#104 round 2 measurement).
- **`--realtime-rate X`** covers the shape that `--realtime` at 1x and an unpaced fixture bracket without covering. A restreamer serving from a standing buffer keeps handing over faster than the content happens, so the live edge outruns the client tracking it for the whole session, not just for the length of one burst.
- **`--standard-join`**: the default `.fastZap` first serve prefers the full holdback, but is bounded after two finalized segments plus a 0.5...2.0 s observed-segment grace. That grace ends early once the source reads at 1x and the open segment cannot reach its next keyframe inside it (AE#936).
- **`--no-blocking-reload`**: the live playlist never advertises `CAN-BLOCK-RELOAD`. That separates "AVPlayer stopped fetching because the playlist stopped changing" from "AVPlayer stopped fetching because it is in low-latency mode".
- **`--sliding`** is still accepted and does nothing. The sliding window is unconditional for live sessions now; the flag stays only so an older script does not fail.

### Rewind hold

`--rewind-hold N` is the regime that separates a resident floor doing its job from a window outrunning the reader. It reports the floor-minus-playhead inversion, stalled ticks, and any `live window slid past the consumer` line.

### Resume anchor

`--start-position S` loads the live session with a resume anchor, the same one `load(url:startPosition:)` takes. Live callers normally pass nil, so what the anchor does on a live join had never been drivable from here. Measured on a seed offset to 95173 s:

- The mount seek is spent on the ITEM axis, while a host only ever sees the published clock (item + shift).
- AVPlayer CLAMPS an anchor past the end of a 15 s item and joins normally (`item=0.74s`, playing). So an anchor on the wrong axis is not by itself a wedge.

### Tick line

The 1 Hz tick prints `item=<s> ranges=<n> status=<n>` beside `t=` and `edge=` (AE#509).

- `t=` is the PUBLISHED clock, which includes `playlistShiftSeconds`.
- `item=` is `AVPlayerItem.currentTime()` on the item axis, the field a host's own diagnostic dumps. On a live source whose axis is hours into an encoder clock, the two differ by the whole shift in a perfectly healthy session (`t=95173.70s item=0.75s ranges=1 status=1`). So a report quoting one cannot be read against a harness printing the other.
- `ranges=0` is the deciding fact behind a live join that fetches a whole window and presents none of it. It says nothing has been PLACED, which `isPlaybackBufferEmpty` cannot say (AE#418: a fetch is not a placement).

With the freeze leg the tick also carries:

- `item=`: the item's own playhead, which is the session clock less the session's shift. The two disagree by a constant, and only `item=` is the consumer's place.
- `buf=`: how long that consumer can keep playing out of what it already holds.

### The freeze leg

`--freeze-after N` freezes the upstream with the connection still open. `--rewind-before-freeze N` parks the playhead inside the DVR window first. `--unfreeze-after N` lets the frozen upstream deliver again after N seconds. That is the only way to drive the recovery half: a window closed with ENDLIST re-opening, and where the rejoin puts a timeshifted viewer.

**Two healthy outcomes** (since AE#446 round 7):

- `VERDICT: live-freeze position held`: a window that was closed and rejoined.
- `VERDICT: live-freeze gap absorbed`: a gap short enough that the window was never closed. No item was swapped and the viewer saw nothing.

**Close or absorb.** `item=` and `buf=` make an outage decision readable: the close spends a DEPTH, and the segments the window lists above the consumer's fetch point are only half of one. Since AE#523 round 2 the CONTENT decides. A freeze is absorbed for as long as the consumer still holds more than one target duration of runway ahead of its own fetch point, whatever the clock says. The clock keeps only the ceiling at which the producer gives a silent source up: `35 s` less a patience, so 26.0 s at the fixture's TARGETDURATION 6. Examples with the built-in fixture:

- `--freeze-after 60 --unfreeze-after 22 --rewind-before-freeze 30`: 24.0 s of runway carries a 20.1 s silence and is absorbed. Before that round it closed and swapped the item.
- Drop the rewind to 0 and the same 12 s freeze is absorbed too, since AE#520 round 2, because the edge viewer's own buffer is counted: 8.0 s listed plus 3.9 s in hand against a 6.0 s reserve. The listed half alone closed the window 1.84 s before the source delivered again.
- A 30 s freeze at the same depth still closes, at 16.07 s of silence with 6.0 s of depth left and nothing still to fetch. The old gate could not close that case at all.

**`--live-only`** loads with no DVR window: the shape of a client that keeps its rewind outside the engine (where AE#446 round 4 came from). The freeze leg then measures the only timeshift such a session can have, the backlog an outage puts between the closed window's end and the source's return. The sliding 60 s live-only retention makes the fresh item's own axis observable.

**The verdict counts SEGMENTS, not seconds.** A forward step in seconds cannot tell a lost position from a source discontinuity the session correctly folded. A client that reconnects during the freeze is served from a fresh loop of the seed. A connection always starts at a loop boundary, so the rest of the loop the parked connection had not reached is skipped. That is a real jump in the source (28.8 s on the bundled seed, 49.1 s reported on a 93 s capture), and it shows up as a legitimate step in the playhead.

So the verdict reads which segments the consumer fetched before and after the rejoin: any the window listed, that it had not reached, and that the rejoin then jumped over. It also fails:

- a rejoin that re-enters further below the place it held than the landing's own backward buffering explains (a re-fetch is not a re-watch; the allowance is computed from the cut size, because AVPlayer's lookback is a fixed 6 to 8 s of content);
- a run where the source delivered again and the session never went live at all. Every seconds-based number reads that as healthy (the playhead had not moved, so it had not moved wrong).

## dvr

Runs the DVR rewind matrix across the native and SW paths.

**Usage:** `aetherctl dvr [--path native|sw|both] [--seconds N] [--dvr-window N]`

| Flag | Meaning | Default |
|---|---|---|
| `--path native\|sw\|both` | Which paths to run. | `both` |
| `--seconds N` | Run length. | 120 |
| `--dvr-window N` | DVR window size. | 60 |

## hlsfixture

Slices a local `.ts` into a sliding live HLS playlist and serves it over loopback, with fault knobs. `--self-test` runs `HLSLiveIngestReader` against it end to end. Every request is logged as one `[HLSFixture] REQ <path>` line, so what a load actually costs the origin can be counted.

**Usage:** `aetherctl hlsfixture <input.ts> [flags]`

| Flag | Meaning | Default |
|---|---|---|
| `--port N` | Listening port. | 8090 |
| `--segment-seconds N` | Slice length. | 4 |
| `--target-duration N` | Advertised `#EXT-X-TARGETDURATION`, independent of the real cut size. | from the cut |
| `--window N` | Segments the sliding window keeps visible (minimum 3). | 6 |
| `--segments-dir <dir>` | Serves pre-cut segments instead of byte slices. | off |
| `--master` | Adds a master playlist with two variants: low (404) and high (the media playlist). | off |
| `--codecs <list>` | Writes `CODECS=` onto both `EXT-X-STREAM-INF` lines. | none |
| `--resolution WxH` | Writes `RESOLUTION=` onto both `EXT-X-STREAM-INF` lines. | none |
| `--discontinuity-at N` | Inserts `#EXT-X-DISCONTINUITY` before segment N whenever N is in the window. | off |
| `--slow-refresh` | Holds every `/media.m3u8` response for 8 s (stall exercise). | off |
| `--drop-segment N` | Answers 404 for segment N. | off |
| `--encrypted` | Adds `EXT-X-KEY:METHOD=AES-128` to the media playlist. | off |
| `--fmp4` | Adds `EXT-X-MAP:URI="init.mp4"` to the media playlist. | off |
| `--self-test` | Runs `HLSLiveIngestReader` against the fixture end to end. | off |
| **Header-enforcing origin** | See [below](#the-header-enforcing-origin-ae363). | |
| `--require-header "Name: Value"` | Refuses requests without this header. | off |
| `--deny-status N` | Status for a refused request. | 403 |
| `--deny-segments-only` | Refuses after readyToPlay instead of at the master. | off |
| `--deny-user-agent S` | Refuses requests whose User-Agent contains S. | off |
| `--redirect-entry` | The entry URL becomes `/entry.m3u8` and answers with a 302. | off |
| `--redirect-host H` | Host name for the redirect target. | `localhost` |
| `--redirect-port N` | Port for the redirect target. | the fixture's bound port |
| `--media-origin H:P` | Master's variants point at a second origin absolutely. | off |

**Pre-cut segments.** `--segments-dir <dir>` serves pre-cut segments instead of byte slices, sorted numerically. Make them with:

```bash
ffmpeg -i in.ts -c copy -f hls -hls_time 4 -hls_flags independent_segments -hls_segment_filename seg%d.ts out.m3u8
```

Byte slicing is not keyframe-aligned, so segments start mid-GOP and the decoder logs parameter-set errors on the rerouted ingest. That is fine for routing and plumbing questions ("did it route"), but useless for "did it play": the run rebuffers forever because nothing decodes. Use the directory whenever the question is playthrough.

**`--codecs` / `--resolution`.** Without them AVFoundation reports no `videoAttributes` for the variants. Everything that reads master evidence (the #168 watchdog, the #293 probe gate) then sees a master advertising no video at all, and the fixture quietly stops carrying the case under test.

### The advertised TARGETDURATION and the window depth (AE#374)

`--target-duration N` advertises a `#EXT-X-TARGETDURATION` independent of the real cut size. `--window N` sets how many segments the sliding window keeps visible. Packagers commonly pad the target duration (`segment + 1`) to widen a client's patience for an unchanged playlist. A downstream host asked whether that padding was what its live joins were paying for. Neither shape could be expressed here before, so the question could not be answered by measurement.

Measured against pre-cut GOP-aligned segments, `play --live --fast-zap` entering on a saturated window, three passes per row, engine 6.34.1:

| origin cut | advertised TD | window | served TD | first serve held |
|---|---|---|---|---|
| 2 s | 3 (padded) | 3 | 3 | 2.004 / 2.010 / 2.010 s |
| 2 s | 2 (`ceil(max EXTINF)`) | 3 | **3** | 2.010 s, three times |
| 2 s | 3 | 5 | 3 | 2.001 / 2.007 / 2.010 s |
| 2 s | 5 (over-padded) | 3 | **5** | 2.010 s, three times |
| 1 s | 2 (padded) | 3 | 2 | 1.001 / 1.010 / 1.010 s |
| 1 s | 1 (`ceil(max EXTINF)`) | 3 | **2** | 1.005 / 1.007 / 1.010 s |
| 1 s | 2 | 7 | 2 | 1.003 / 1.005 / 1.010 s |
| 0.5 s GOP inside 1 s segments | 2 | 3 | 2 | **0.510 s, three times** |

**At 6.34.1, removing the padding changed nothing.** That finding is what AE#447 later turned out to be. The served TARGETDURATION was `max(advertised, ceil(observed arrival cadence), ceil(max own EXTINF), ceil(1.5 x cut target))`. A strict-realtime origin's real inter-arrival gap is always a hair above the nominal cut, so the `ceil` landed on `cut + 1` whether or not the origin advertised it. "The padding is not what you pay for" was right; "there is nothing to pay" was not. Both terms were wrong for the same reason: an arrival interval is a cadence, and `ceil` treats it as a segment duration.

**From 6.56.0** the advertised value is not read at all (it is printed in the seal line and nowhere else). A measured cadence enters as the TARGETDURATION its patience actually needs, `ceil(gap / 1.5)`, because `1.5 x TD` is the unchanged-playlist tolerance the floor exists to satisfy. On the same 2 s origin advertising 3, measured on this harness:

- before: served TD **3, then 4, then 4** across three joins, holdback 9 s then 12 s twice. It escalated because the gate's own wait was being measured as the source's cadence.
- after: served TD **2** on every join, holdback 6 s, measured floor 2.019 to 2.141 s.

Deepening the window changes nothing either. The ingest joins exactly three segments behind the edge at window 3, 5 and 7, so a deeper upstream window never becomes a deeper cushion. What moves is the cut, because the fastZap grace is `min(2.0, max(0.5, own cut duration))` and the engine re-cuts at the source GOP.

**Over-padding costs elsewhere.** TD 5 on 2 s cuts still serves in 2.010 s, because the bounded fastZap exit fires on the grace either way. But the served playlist then carries a 15 s holdback, so AVPlayer targets that far behind the live edge for the rest of the session. Since 6.56.0 an over-padded advert cannot produce that: only the source's own segments and its closed inter-arrival gaps can.

**The seal line** shows the whole derivation, once per session:

```
[HLSVideoEngine] live TARGETDURATION sealed at 2s (holdback 6.000s): max EXTINF 2.000s,
  1.5 x cut target 0.750s, measured floor 2.069s needs 2s of patience;
  upstream advertises 3.000s (reported, not used)
```

**This harness cannot reproduce the last term (AE#447 round 2).** After the four fixes above, the reporter's device still sealed at 3 while that same line printed `max EXTINF 2.000s`. A live EXTINF is `nextStart - startSeconds`, a difference of two accumulated item-axis doubles. So a strictly 2.000 s GOP whose first segment starts at 0.060 s yields the odd `2.0000000000000004`. `ceil` charges a whole second for it, and the seal takes the max over the window, so one such segment is enough (6 of his 80 were). The fixture here starts its first segment at exactly 0 and cuts at a binary-exact duration, so its differences are exactly 2.0, and five joins in a row sealed at 2. The case lives in `Issue447TargetDurationEvidenceTests` instead, built by accumulating the way the producer accumulates. Since **6.56.0** every term is taken at the resolution the playlist serves (`#EXTINF` is written with `%.3f`), so the seal line can be checked against itself: what it prints is what decided it.

### Pricing the bounded start (AE#594)

`fastZap`'s bounded start serves once two segments exist plus a clamped grace. That window can be shallower than the holdback the same manifest advertises. `AETHER_BOUNDED_START_FLOOR=1` is a measurement arm, not a policy: it skips the bounded branch, so the wait ends at the full cushion or at the 30 s outer deadline.

Both arms against an `hlsfixture` origin of pre-cut GOP-aligned segments, `play --live --fast-zap --seconds 45`, two passes per row (three for 6 s / A):

| origin cut | arm | gate held | first manifest | first picture | `-16832` |
|---|---|---|---|---|---|
| 1 s | A (bounded) | 3.028 s | 2 segs / 2.000 s **<** 3 s holdback | 3.47 s | 0 |
| 1 s | B (floored) | 3.068 s | 3 segs / 3.000 s >= 3 s holdback | 3.26 s | 0 |
| 3 s | A | 8.252 s | 2 segs / 6.000 s **<** 9 s holdback | 9.64 s | 0 |
| 3 s | B | 9.458 s | 3 segs / 9.000 s >= 9 s holdback | 9.65 s | 0 |
| 6 s | A | 14.342 s | 2 segs / 12.000 s **<** 18 s holdback | 16.72 s | 0 |
| 6 s | B | 18.597 s | 3 segs / 18.000 s >= 18 s holdback | 18.79 s | 0 |

**The floor costs exactly one more segment minus the grace.** The gate deltas: +0.04 s at a 1 s cut (the 1.0 s grace covers the whole wait), +1.21 s at 3 s and +4.26 s at 6 s, where the grace clamps to 2.0 s. At the picture: +0.00, +0.01 and +2.07 s. So the trade is real only at coarse cadences, and free at fine ones.

**This harness cannot price the other half.** `-16832` never appeared, in any cadence, in either arm, across thirteen runs. Do not read that as "the shallow window is safe". The session here joins at the HEAD of the served window (`cur` starts at the window's first sample and advances 1x) instead of seeking to edge-minus-holdback, so the state the issue is about is never entered. The per-tick `edge=` and `behind=` cannot check that either: `edge` stays pinned at its first value for the whole run and `behind` is derived from it, with or without `--dvr-window`. The stall half needs a field capture or an origin that reproduces the seek, not this table.

### An origin that delivers late (AE#684)

`hlsfixture` publishes on a metronome, and a metronome is the one thing an IPTV origin is not. The defect AE#684 reported only exists when a delivery arrives later than the segment is long, so it could be read off a device log and reproduced nowhere.

`Scripts/hls-burst-origin.py` serves a sliding playlist over pre-cut segments and publishes segment k at `end of k - prefill + delays[k % n]`. The MEAN cadence stays the segment duration (the origin never falls behind real time), while the gap between two deliveries follows the cycle. Options:

| Option | Meaning |
|---|---|
| `--delays a,b,...` | The delivery delay cycle. |
| `--freeze-at K --freeze-seconds F` | An outage, with the backlog landing at once. |
| `--durs 6,4` | Alternating segment lengths. |
| `--dur 6.3` | Over 6 s of media: a playlist that rounds its EXTINF up. |
| `--window` / `--prefill` | How many segments the upstream lists. |
| `--rate-kbps` / `--latency-ms` | A link shared by every in-flight response. |

Its docstring carries the fixture command: 720x576 at 25 fps, 2 s GOPs, 6 s segments, and a white frame plus a 40 ms beep on every whole second. That makes the sound measurable against the picture afterwards.

```bash
Scripts/hls-burst-origin.py --dir seg6 --delays 0,0.3,2.6,0.2,0.6,2.4,0.1,0.5 &
aetherctl play --live --live-ingest --fast-zap --seconds 180 http://127.0.0.1:8684/live.m3u8
```

That cycle makes the origin's own gaps run 3.6 to 8.3 s. On the loopback they arrive 3.0 to 9.3 s apart, because the ingest reloads the upstream playlist every half segment, and a delivery that just missed a reload waits for the next. **The served window changes once per UPSTREAM segment, up to one and a half of them apart, however finely the engine re-cuts it.**

Under `.fastZap` the cut is the 2 s GOP and `max EXTINF` reads 2.000 s. Through 7.25.1 the upstream's 6 s entered only through the cadence floor, as `ceil(6 / 1.5)` = 4. That division is right for a MEASURED gap, which is a robust maximum. A segment duration is the other end of the distribution: the period the source delivers at when nothing is late. So the client's patience (`1.5 x 4` = 6.0 s) was exactly one period, and the 12 s holdback left 2.7 s at the low point of the sawtooth.

The cost is not the `-12888` itself, but what AVPlayer does next: it skips a reload. Measured here and on an Apple TV alike: polls every 2.00 s, then 4.00 s (macOS) or 5.03 s (tvOS) of nothing after the error. The stall lands inside that hole, with the next delivery already listed 1.9 to 2.6 s earlier.

**The seal now asks for the upstream segment whole** and takes as much of it as the join pays for. On an upstream of uniform segment length the join itself is not deepened: one more upstream segment would be one more download before the first picture on every zap, which AE#678 measured and declined. So three 6 s segments are 18 s joined, 16 s cut, and a seal of 5:

```
[HLSVideoEngine] live TARGETDURATION sealed at 5s (holdback 15.000s): max EXTINF 2.000s,
  1.5 x cut target 0.750s, measured floor 6.000s needs 4s of patience,
  upstream segment 6.000s (one delivery, however finely it is cut here), of which the join
  pays 5s of 6s (16.000s cut of the 18.000s it listed); upstream advertises 6.000s (reported, not used)
```

One 180 s run per arm on that origin, same deliveries (four gaps above 9.0 s in each):

| | sealed | join | `-12888` | `playbackStalled` | `#524` running thin |
|---|---|---|---|---|---|
| 7.25.1 | TD 4, holdback 12 s | 3 segments | 5 | 1 | 4 |
| join-bound seal | TD 5, holdback 15 s | 3 segments | 3 | 0 | 0 |

That is fewer, not none, and it is the honest size of what a seal one second higher buys. 7.5 s of patience still loses to a 9 s gap, but the 15 s holdback leaves 5.7 s at the low point where 12 s left 2.7 s. That is the difference between surviving AVPlayer's skipped reload and not. A join one segment deeper (TD 6, holdback 18 s) drew none of either in three such runs and was not shipped: it cost 3.81 s against 4.98 s to the first picture behind an 8 Mbit/s link. The device capture this came from had 10 of its 110 gaps above 9 s and 5 above 12 s. So the field expectation is fewer `-12888` and far fewer stalls, not zero.

**Mixed segment lengths (`--durs 6,4`): both phases must read alike.** The join counts seconds back from the newest segment. So `--prefill 8` (a 4 s segment newest) joined four segments and sealed 6, while `--prefill 7` (a 6 s one newest) met the 16 s coverage at three, cut 14 s and sealed 4 (7.25.1's value), on about four tunes in ten.

The join is now equalised over the phases of one listing: a tune never loads more than the deepest tune of the same channel already did. That is the deepest the coverage rule takes over this tune and the tunes one, two, ... segments earlier that its own join still reaches, at most one above its own depth. `--window 8`, mild jitter (`--delays 0.2,0.5,0.3,0.8,0.25,0.6`), three 60 s runs per arm and phase:

| `--durs` | phase | | sealed | join | `-12888` | first picture behind 8 Mbit/s (median) |
|---|---|---|---|---|---|---|
| 6,4 | `--prefill 7` | 7.25.1 | TD 4, holdback 12 s | 3 segments, 16 s | 1 / 0 / 1 | 3.47 s |
| 6,4 | `--prefill 7` | now | TD 6, holdback 18 s | 4 segments, 20 s | 0 / 0 / 0 | 4.23 s |
| 6,4 | `--prefill 8` | 7.25.1 | TD 4, holdback 12 s | 4 segments, 20 s | 1 / 1 / 0 | 4.27 s |
| 6,4 | `--prefill 8` | now | TD 6, holdback 18 s | 4 segments, 20 s | 0 / 0 / 0 | 4.26 s |
| 10,8 | both | 7.25.1 | TD 7, holdback 21 s | 3 segments, 28 or 26 s | 0 / 0 / 0, 1 / 1 / 1 | 5.86 s, 5.52 s |
| 10,8 | both | now | TD 8, holdback 24 s | 3 segments, 28 or 26 s | 0 / 0 / 0, 1 / 1 / 1 | 5.88 s, 5.59 s |
| 6,6,4 | all three | 7.25.1 | TD 4, holdback 12 s | 3 segments, 16 s | 0 to 2 per run | 3.45 s, 3.43 s, 3.46 s |
| 6,6,4 | all three | now | TD 4, holdback 12 s | 3 segments, 16 s | 0 to 1 per run | 3.47 s, 3.47 s, 3.48 s |

No run stalled in either arm. The extra segment on 6,4 is the short one, and the other phase already loads it. The equalising stops there on purpose:

- 10,8 and 6,6,4 join three in every phase, so nothing is added and their first picture is main's.
- 10,8 seals what its three segments pay (8). 6,6,4 cuts 14 s in every phase and keeps 4, so it is not helped.
- A first version took one segment more on any mixed-length join that could not pay its seal. That cost those two shapes a segment on every tune (6.19 s to 8.12 s, and 3.81 s to 4.98 s).
- Uniform upstreams keep their three segments (`--dur 6`: TD 5, `--dur 10`: TD 9).
- A demuxed audio rendition is joined by the same rule (6,4 behind a master: 4 + 4 in both phases).

One start does get slower. A host that fetches fewer segments at a time than the join has (`play --max-concurrent-requests 1 ... --rate-kbps 14000`) used to be served at 12 s of cut content, and now waits for the join to be handed over or for the grace: 2.79 to 3.08 s before and 3.27 to 3.28 s after with `--prefill 8`, 2.80 to 2.83 s and 3.44 to 3.49 s with `--prefill 7`.

**Whether a join is spent is a fact, not arithmetic.** The seal may only be taken short once the join has nothing more to give. "Cut content plus one segment reaches the summed EXTINF" is not that fact: `--dur 6.3` over 6 s of media never adds up, and a first version built on the sum sealed the full value there and took the bounded start (2.23 s to first picture against 0.20 s). The reader states the fact instead: the whole join batch is committed, its FIFO is empty, and the cutter is parked waiting for the next delivery. Three runs per arm on each inflated shape with three segments listed: served at once in all six (0.000 to 0.034 s of hold), TD 5 on 6 s media and TD 9 on 10 s.

Two more shapes belong to the same fact:

- **Demuxed audio.** Run the origin twice, video-only and audio-only segments behind a master. The cutter parks on the AUDIO reader when the audio ends a little before the video, so the fact is stated for the cutter, not the video reader: both join batches committed and either reader dry. Read off the video reader alone it never became true: 2.2 s to first picture under `.fastZap` and 10.4 s under `.standard`. Now 0.18 to 0.21 s in all six cells (6 s and 10 s `.fastZap`, 10 s `.standard`, audio aligned and 0.2 s short, three runs each), as on 7.25.1.
- **A join slower than the `.fastZap` grace** (`play --max-concurrent-requests 1` behind `--rate-kbps 4000`). It is served by the bounded start before it is spent, seals the full 6 or 10 over a window under its holdback, and draws a `-16832` warning at the start. First picture 5.05 to 6.08 s against 7.05 to 8.26 s on 7.25.1 (which still pays the second grace there), and no `-12888` against 1 to 3.

**The gate held the second playlist request too.** AVPlayer opens with two `/media.m3u8` requests. Each re-enters `waitForFirstLiveSegment`, and on a bounded start each waited its own grace (`GET /media.m3u8` at 2.81 s, `GET /init.mp4` at 4.83 s). On an ingest the gate now opens for good once a manifest has gone out. On a source the engine cuts itself it did not until 7.28.2 (next paragraph). That second grace is the "+2.07 s at the picture" of the AE#594 table above; removing it there also leaves the session up to 2 s closer to the producing edge, which is that issue's open question. The raw-TS control (`live --fast-zap --realtime --preroll 0`, two seeds, two runs per arm) reads the same in both arms: first manifest at 3.84 to 3.96 s, `init.mp4` at 6.11 to 6.33 s, first picture at 6.20 to 6.58 s, playhead 6.3 to 6.8 s behind the wall clock. The AE#594 table stands as printed.

**AE#686 applies the same latch to a source the engine cuts itself, by default since 7.28.2.** It started as a measurement arm (`AETHER_FIRST_SERVE_LATCH_ALL=1`, 7.26.3), because what it may cost (a session closer to the producing edge for its whole life) needs a device that seeks to edge-minus-holdback, which this harness does not. The reporter's Apple TV A/B answered that. On 1080p59.94 raw TS with 1.001 s segments, every bounded start reached its picture 1.003 to 1.039 s sooner with the latch, the session sat 0.5 to 1.5 s nearer the edge after 60 s, and 18 latched launches logged no stall, `-16832` or `-12888`. A rebuild from a backlog served a full cushion in both arms, so the latch had nothing to skip there. `AETHER_FIRST_SERVE_LATCH_ALL=0` restores the old gate, read once per process. Both arms print how long AVPlayer's second plain request waited, once per session:

```
[HLSVideoEngine] repeat live manifest request held 2.003s, fastZap bounded start after 2.000s grace
[HLSVideoEngine] repeat live manifest request held 0.000s, first-serve latch
```

`live --fast-zap --realtime --preroll 0 --seconds 40`, two runs per arm, interleaved:

| seed | arm | first manifest | second request held | `GET /init.mp4` | sustained advance | `item=` at the end | stalls |
|---|---|---|---|---|---|---|---|
| `h264-ts-sample.ts` (2 s cuts) | off | 3.76 to 3.94 s, 2 segments | 2.003 s | 6.10 to 6.14 s | 7.4 to 7.7 s | 34.78 to 34.95 s | 0 |
| `h264-ts-sample.ts` | on | 3.94 s, 2 segments | 0.000 s | 4.08 s | 5.2 to 5.3 s | 36.57 to 37.20 s | 0 |
| 1080p59.94, 1 s GOP | off | 1.22 to 1.23 s, 3 segments | 1.011 s | 2.43 s | 3.2 s | 38.30 to 38.40 s | 0 |
| 1080p59.94, 1 s GOP | on | 1.24 s, 3 segments | 0.000 s | 1.41 to 1.44 s | 1.1 s | 39.19 to 39.30 s | 0 |

The latch removes exactly the grace, and the session ends that much closer to the edge. On the device that cost no stall.

The full matrix (6 s and 10 s segments, 3, 4 and 8 listed, both profiles, three runs per arm) is in `api.md` under the live join. `.standard` adds `--standard-join` to the `play` line.

**Sound against picture, in the bytes.** `play --served-url` hands over the init segment, the cache holds the rest, and decoding their concatenation gives the presentation time of every flash and every beep onset. 147 of 148 seconds of a served session read **-0.3 ms** (the very first beep reads +19.7 ms, the decoder starting), across a 12 s outage, with no audio frame of any duration but 1024 samples and no gap at any segment seam. A fresh item re-fetches the same cached segments, so a rebuild cannot change that.

What a rebuild does change is which segment the item starts on and where in it. A segment's sound does not begin where its picture does: the cut is taken on the video keyframe, and a transport stream interleaves audio behind video. On this fixture the sound opens between 11 ms after and 208 ms before the picture, segment by segment. Each item now says what it started on:

```
[AetherEngine] #684 item #1 starts at its own 4.000s: segment 2 + 0.000s, whose picture
  opens at 4.000s and whose sound runs 3.979..5.963s (it opens 21 ms before the picture)
```

Each `live seg-N finalized` line carries `sound=first..last`.

The PICTURE half is measurable here: the same origin over a 24 fps twin that carries `Scripts/timecode-fixture.sh`'s block row, `play --picture-probe`, and an outage long enough to close the window (`--freeze-at 14 --freeze-seconds 14`). Four runs, each rebuilt with `#EXT-X-START:TIME-OFFSET=41.95,PRECISE=YES` at `segment 34 + 1.95s`, each fetching seg31 first, whose sound opens 208 ms before its picture. `axisErr` reads +12.000 on all 70 ticks of the first item, and +40.000 on all 38 of the rebuilt one, whose playlist begins 28 s later. The picture sits on the item clock to the frame on both. So AVPlayer does not anchor an item on the earliest sample of the first segment it loads, and a mid-segment placement moves nothing on the video side.

**What AVPlayer's audio renderer makes of it is not observable from a Mac.** An `MTAudioProcessingTap` on an HLS item is created without error and never called (0 callbacks in 12 s), and capturing the output needs a grant no headless run has. A report of sound and picture drifting apart after a rebuild therefore needs:

- a device,
- this fixture (a beep that should land on a flash is the one sync test a viewer can read without instruments),
- the three log lines: the `#454 placing` line, the `#684 item` line, and the AE#440 line that says whether the start was forced.

### The header-enforcing origin (AE#363)

A tokenized IPTV origin refuses anything that arrives without its per-request header. None of the fixtures could produce that shape, so neither live client could be driven against one.

```bash
# portal on 8099 answers /entry.m3u8 with a 302 to the "CDN edge" on 8100, both enforcing the header
aetherctl hlsfixture --segments-dir ./segs --master --codecs "avc1.4d401f,mp4a.40.2" \
  --resolution 1280x720 --require-header "User-Agent: Mozilla/5.0 (QtEmbedded; TestSTB)" \
  --redirect-entry --redirect-port 8100 --port 8099
aetherctl play --live --header "User-Agent: Mozilla/5.0 (QtEmbedded; TestSTB)" \
  --seconds 60 http://127.0.0.1:8099/entry.m3u8
```

The REQ log then carries the verdict per request (`auth=ok` / `auth=MISSING -> 403`). That makes "who lost the header, and on which hop" a measurement.

| Knob | Meaning |
|---|---|
| `--require-header "Name: Value"` | The header every request must carry. |
| `--deny-status N` | Status for a refusal. 401 and 403 reach the engine as different `NSURLError` codes. |
| `--deny-segments-only` | Refuses after readyToPlay instead of at the master. |
| `--deny-user-agent S` | Refuses `AppleCoreMedia` (for example) and serves everyone else. This is the one origin shape that tells the AVPlayer bypass and the engine's own ingest fetcher apart. |
| `--redirect-entry` / `--redirect-host` / `--redirect-port` | Portal-to-edge 302, cross-origin by host name and port while staying on loopback. Without `--redirect-port`, a redirect uses the fixture's bound port, read under the same lifecycle lock that updates it on start and stop. |
| `--media-origin H:P` | The master's variants point at a second origin absolutely. |

Worth knowing before you suspect the engine (measured before AE#363 was written): `LoadOptions.httpHeaders` survive BOTH shapes on the AVPlayer bypass on macOS, the cross-origin 302 and the absolutely referenced second origin. Every request arrived with the header and the session played through.

## hlslive

Replays a synthetic SSAI ad-pod feed through the live-direct-play path to reproduce FAST-channel ad-break handling: program-switch detection, muxer rotation with versioned `#EXT-X-MAP`, audio re-anchor, and the no-cut watchdog.

**Usage:** `aetherctl hlslive --segments a.ts,b.ts,c.ts [--seconds N] [--segment-seconds N] [--disc i,j]`

| Flag | Meaning | Default |
|---|---|---|
| `--segments a.ts,b.ts,c.ts` | Required. Real `.ts` segment files served in order (content / ad / content), without timestamp rewriting. | |
| `--seconds N` | Run length. | 40 |
| `--segment-seconds N` | Segment length. | 5 |
| `--disc i,j` | Segment indices that carry a leading `#EXT-X-DISCONTINUITY`. | auto-detected on every file change |

## dovitest

Runs the Dolby Vision Profile 7 to 8.1 converter over every video packet of the source and writes the converted elementary stream (Annex B). It reports packets processed, conversions and failures. Use it to confirm offline, without a DV panel, that the in-engine `DoviRpuConverter` (libdovi) output matches the `dovi_tool -m 2` ground truth.

**Usage:** `aetherctl dovitest [--out PATH.hevc] <p7-source>`

| Flag | Meaning | Default |
|---|---|---|
| `--out PATH.hevc` | Output path. | `aetherctl-dovitest.hevc` in aetherctl's private per-user temporary directory |

The temporary directory is `$TMPDIR/aetherctl-<uid>`, mode 0700, the same on every run. The next run overwrites the file instead of leaving a second copy of the film. The path is printed.

```bash
swift run aetherctl dovitest [--out PATH.hevc] <p7-source>
dovi_tool extract-rpu -i <printed output path> -o out.rpu
dovi_tool info -i out.rpu -f 0   # expect dovi_profile 8, disable_residual_flag true
```

## feltest

Runs the Dolby Vision Profile 7 FEL dual-layer pipeline over a real clip and audits the output. Needs the `DualLayerDolbyVision` trait; without it the subcommand exits 64 and says so.

**Usage:** `aetherctl feltest [--frames N] <p7-source>`

| Flag | Meaning | Default |
|---|---|---|
| `--frames N` | Packets to feed. | 100 |

```bash
swift run aetherctl feltest [--frames N] <p7-source>
```

**What it does.** Demuxes, splits each packet into the base layer, the enhancement layer (typically 1080p) and the RPU, decodes both layers in hardware `VTDecompressionSession`s, and composes each frame with `DoviFelComposer` on Metal. Then it audits the output twice:

- **Pixel audit:** mean and standard deviation of Y / Cb / Cr, so a black picture or collapsed chroma fails.
- **Metadata audit:** every delivered frame must carry a `DolbyVisionRPUData` attachment. It warns (without failing) when the payload never changes, since a static-metadata clip is valid.

The verdict also requires at least one frame the composer actually reconstructed. A bypassed frame comes out as its base layer and counts as output, but not as composed.

| Exit | Meaning |
|---|---|
| 0 | Verified. |
| 1 | Probe error. |
| 2 | No frames output. |
| 3 | Chroma collapsed to a flat 64. |
| 4 | Frames emitted without per-frame Dolby Vision metadata. |
| 5 | No frame was composed. |

See [dolby-vision-fel.md](dolby-vision-fel.md).

## dvsurvey

Walks a title's RPUs with no decoders and no GPU, and converts each to Profile 8.1 exactly as the FEL path attaches it. It reports:

- the L1 distribution (`min_pq`, `max_pq`, `avg_pq`),
- the scene cuts,
- the frame whose L1 sits furthest from the title's median, with the `aetherctl play --dv-pin` spec that pins it for the on-device consumption test. A host app passes the same spec to `armDolbyVisionPinTest`.

Candidates rank on distance from the median across all three L1 fields, not `max_pq` alone. Pinning changes only the attached metadata, never the decoded pixels, so a visible pulse on the TV proves the attachment is being consumed.

**Usage:** `aetherctl dvsurvey [--frames N] [--list K] <p7-source>`

| Flag | Meaning | Default |
|---|---|---|
| `--frames N` | Bounds the scan. | 2000 |
| `--list K` | Also dumps the first K frames. | 0 |

| Exit | Meaning |
|---|---|
| 0 | OK. |
| 1 | Probe error. |
| 2 | No RPUs. |
| 3 | No pin candidate. |
| 4 | The title's L1 range is too flat for a pinned frame to be visible on a panel. |

```bash
swift run aetherctl dvsurvey --frames 6000 <p7-source>
```

## eltype

Reads `label<TAB>url` lines from stdin and prints, for each source, whether its Dolby Vision Profile 7 enhancement layer is FEL or MEL (`AetherEngine.probeDolbyVisionEnhancementLayer`, no decode). Does not need the `DualLayerDolbyVision` trait.

**Usage:** `aetherctl eltype [--parallel N] < titles.tsv`

| Flag | Meaning | Default |
|---|---|---|
| `--parallel N` | Most sources open at once. The work runs on `concurrentPerform`, so the effective width is also capped by the core count. | 8 |

```bash
printf 'title\t/path/to/p7.mkv\n' | swift run aetherctl eltype --parallel 4
```

## elsurvey

Reads `label<TAB>url` lines from stdin and measures what each title's enhancement layer does to its picture at sampled keyframes (`AetherEngine.doviResidualSurvey`). Per title it reports, taken before the composer's range clamp:

- the mean and p99 residual in 12-bit codes,
- the share of pixels moved by a 10-bit step or more,
- the nits change at the average and peak levels.

A TSV row prints as each title finishes. Needs the `DualLayerDolbyVision` trait.

**Usage:** `aetherctl elsurvey [--points N] [--parallel N] < titles.tsv`

| Flag | Meaning | Default |
|---|---|---|
| `--points N` | Keyframes sampled per title. | 48 |
| `--parallel N` | Most titles measured at once, capped by the core count like `eltype`. | 8 |

```bash
swift run aetherctl elsurvey --points 24 --parallel 4 < titles.tsv
```

## elframe

Composes one Profile 7 FEL keyframe twice on the dual-layer composer, with and without its residual. It writes `frame.json` and the full-precision P010 planes to a directory: `fel_y.bin`, `fel_uv.bin`, `mel_y.bin`, `mel_uv.bin` (little-endian 16-bit words, the 10-bit code in the top bits and the finer bits below). Needs the `DualLayerDolbyVision` trait.

**Usage:** `aetherctl elframe --at SECONDS --out DIR <p7-source>`

| Flag | Meaning | Default |
|---|---|---|
| `--at SECONDS` | Picks the keyframe at or before that time. | 0 |
| `--out DIR` | Destination directory. | required |

When the RPU itself switches the residual off for the frame, it prints a note and sets `residual_disabled_by_rpu` in `frame.json` (FEL and MEL are then identical).

```bash
swift run aetherctl elframe --at 600 --out /tmp/elframe <p7-source>
```

## felcurves

Runs a whole Profile 7 FEL source through the curve fold the segment producer uses (`AetherEngine.felCurveFold`, [Dolby Vision FEL › Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route)). It writes the Profile 8.1 RPUs it produced (stream mapping kept, luma residual folded in), in presentation order, as a dovi_tool RPU file. `dovi_tool inject-rpu` puts them into the base layer for playback through the platform decoder. It prints how many scenes were fitted, had no residual or failed, and the time taken. Needs the `DolbyVisionFelCurves` trait.

**Usage:** `aetherctl felcurves <p7-fel-source> <out.rpu>`

```bash
swift run --traits DolbyVisionFelCurves aetherctl felcurves <p7-fel-source> /tmp/folded.rpu
```

## dmpass

Checks whether the Dolby Vision Profile 7 FEL route keeps the source's display-management metadata when it converts the RPU to Profile 8.1 and attaches it to the composed frame. Needs the `DualLayerDolbyVision` trait.

**Usage:** `aetherctl dmpass [--frames N] [--out PATH.jsonl] <p7-source>`

| Flag | Meaning | Default |
|---|---|---|
| `--frames N` | Packets to feed. | 300 |
| `--out PATH.jsonl` | Writes one JSON object per frame with both readings and both RPU byte strings in hex, for an independent cross-check with `dovi_tool`. | off |

```bash
swift run --traits DualLayerDolbyVision aetherctl dmpass --frames 120 --out /tmp/dm.jsonl /path/to/p7.mkv
```

**How it compares.** For every composed frame it reads the source RPU (as the demuxer delivered it) with libdovi, reads the RPU back from the pixel buffer attachment at the hand-off point, and compares the two field by field:

- the header,
- a summary of the mapping,
- the display-management scalars,
- every level (L1 to L6, L8 to L11, L254, L255),
- the Content Mapping version (v4.0 when an L254 block is present, else v2.9).

**Verdict.**

- Fields the profile conversion is defined to change (the profile and enhancement-layer labels, the two residual flags, the mapping) are listed as expected.
- Mode 2 also resets the YCC to RGB matrix and offsets, the RGB to LMS matrix and the signal colour space to the Profile 8.1 values. That is reported as a separate "normalised" category: the frame still passes, and the field names and counts are printed. It shows nothing when the source already carries those values.
- Any other difference fails the run. The exit code is 0 when every frame passes.

**Environment variables.** All of these exist only with the `DualLayerDolbyVision` trait. They are off by default and cost nothing then.

| Variable | Effect |
|---|---|
| `AETHER_DM_PRINT=1` (or `hex`) | Echoes the per-frame `[dm-digest]` lines in `dmpass`. |
| `AETHER_DM_DIGEST` = `1`, `log` or `hex` | Runs the same digest inside any host. `hex` adds both RPU byte strings to each line. |
| `AETHER_DM_DIGEST_FILE` | Appends the JSON form to a file. |

## Fixtures

For repeatable runs, `Scripts/fetch-fixtures.sh` generates a small set of synthetic FFmpeg test clips in `./Fixtures/` (H.264 SDR, HEVC HDR10, AV1, VP9). They cover both the native AVPlayer path and the software fallback. Real-world DV / Atmos / multichannel sources go in `./Fixtures/user/` (gitignored).
