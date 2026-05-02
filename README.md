<h1 align="center">AetherEngine</h1>

<p align="center">
  <b>A video player engine for Apple platforms.</b><br>
  FFmpeg demuxes. VideoToolbox decodes. AVPlayer handles Dolby Atmos.<br>
  You ship the UI.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-16%2B-black?logo=apple">
  <img src="https://img.shields.io/badge/tvOS-16%2B-black?logo=apple">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white">
  <img src="https://img.shields.io/badge/license-LGPL--3.0%20%2B%20App%20Store%20Exception-lightgrey">
</p>

---

## What it is

A player engine that gets the hard parts right — HDR, Dolby Vision, Dolby Atmos, A/V sync across multiple clocks — and exposes a `CALayer` plus a handful of `async` methods. No `AVPlayerViewController`. No opinionated controls. No analytics. Embed the layer, call `play()`, read the published properties for state.

You provide the transport bar. You provide the dropdowns. You provide the pretty.

## What it handles

| Area        | Details                                                                                                                     |
| ----------- | --------------------------------------------------------------------------------------------------------------------------- |
| Containers  | MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV                                                                                      |
| HW decode   | H.264, HEVC, HEVC Main10 via VideoToolbox                                                                                   |
| SW decode   | AV1 (dav1d), VP9 fallback — pooled pixel buffers, no per-frame allocations                                                  |
| HDR10       | 10-bit P010 output, BT.2020 + PQ color tagging on every frame                                                               |
| Dolby Vision| Profile 5 / 8.1 / 8.4 on DV-capable displays; HDR10 fallback on HDR10-only TVs                                              |
| HLG         | Transfer function detected and forwarded                                                                                    |
| HDR → SDR   | Software tonemap via `VTPixelTransferSession` when Match Dynamic Range is off                                               |
| Audio       | AAC, AC3, EAC3, FLAC, MP3, Opus, Vorbis, TrueHD, DTS, ALAC, PCM                                                             |
| Dolby Atmos | EAC3+JOC passthrough — local HLS + AVPlayer → Dolby MAT 2.0 wrapping                                                       |
| Surround    | 5.1 / 7.1 with correct `AudioChannelLayout` tagging                                                                         |
| Subtitles   | SubRip / ASS / SSA / WebVTT / mov_text streamed inline; PGS / HDMV PGS / DVB / DVD rendered as `CGImage` with normalised position; sidecar `.srt` / `.ass` / `.vtt` URLs decoded via short-lived context |
| Seek        | Decoder + renderer flush, pre-target frame skip — no "fast forward from keyframe" artifact                                 |
| Streaming   | HTTP Range + chunked delegate reads via `URLSession`                                                                        |
| Resilience  | Exponential backoff on transient network errors, background pause, display-link aware lifecycle                             |

## Quick start

```swift
import AetherEngine

let player = try AetherEngine()
view.layer.addSublayer(player.videoLayer)

try await player.load(url: videoURL)                 // or
try await player.load(url: videoURL, startPosition: 347.5)

player.play()
player.pause()
player.setRate(1.5)
await player.seek(to: 120)
player.stop()

// Observe (Combine @Published)
player.$state         // .idle, .loading, .playing, .paused, .seeking, .error
player.$currentTime
player.$duration
player.$videoFormat   // .sdr, .hdr10, .dolbyVision, .hlg

player.audioTracks    // [TrackInfo]
player.selectAudioTrack(index: trackID)

// Subtitles — text and bitmap, one published list
player.subtitleTracks                          // [TrackInfo] for the loaded source
player.selectSubtitleTrack(index: streamID)    // embedded — text or bitmap
player.selectSidecarSubtitle(url: srtURL)      // .srt / .ass / .vtt next to the media
player.clearSubtitle()
player.$subtitleCues                           // [SubtitleCue] — body is .text(String) or .image(SubtitleImage)
player.$isSubtitleActive                       // host mirror gate
player.$isLoadingSubtitles                     // sidecar fetch + decode in progress
```

Install via Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", branch: "main")
```

## Dolby Atmos pipeline

`AVSampleBufferAudioRenderer` ignores Atmos metadata. `AVPlayer` doesn't — so for EAC3+JOC streams, AetherEngine demuxes the EAC3 packets, wraps them into fMP4 with a `dec3` box that declares JOC (`numDepSub=1`, `depChanLoc=0x0100`), serves the segments from a local HLS server on `127.0.0.1:<port>`, and points `AVPlayer` at the playlist. `AVPlayer` wraps the bitstream as Dolby MAT 2.0 and the receiver lights up the Atmos indicator.

```
Demux ──┬─ Video packets ──► Decode queue ──► AVSampleBufferDisplayLayer
        │                                              │
        │                                              │ controlTimebase synced
        │                                              │ to AVPlayer clock
        │                                              │
        └─ EAC3 packets ───► fMP4 muxer ──► HLS server ──► AVPlayer
                                                         │
                                                         └─► receiver / speaker
```

The `AVSampleBufferDisplayLayer` is driven by a `CMTimebase` whose source is bound directly to `AVPlayerItem.timebase` via `CMTimebaseSetSourceTimebase`. The HLS pipe takes 2-4 seconds to buffer; during that window the timebase is paused and video holds on frame 1. Once `AVPlayer.timeControlStatus` flips to `.playing` and the item timebase is live, the bind is established and from that moment on video and audio share the same hardware-aware clock — including AVR / soundbar Atmos decoder latency, MAT 2.0 unpack delay, pre-roll, and pause/resume — without any periodic drift correction.

If the active output route can't take multichannel — Bluetooth A2DP, HFP, LE, or any route reporting fewer than 6 output channels — AetherEngine skips the Atmos pipeline entirely and routes EAC3 through the regular FFmpeg PCM decoder, so you still get sound instead of silence. If a TV advertises Atmos in EDID but `AVPlayer` stalls anyway (some AVRs do this), a 5-second watchdog falls back to PCM automatically.

## HDR routing

| Source                          | Output pixel format   | Tagged as        |
| ------------------------------- | --------------------- | ---------------- |
| H.264, HEVC (SDR)               | 8-bit NV12            | BT.709           |
| HEVC Main10 (HDR10), HDR display| 10-bit P010           | BT.2020 / PQ     |
| HEVC Main10 (DV P8), DV display | 10-bit P010           | BT.2020 / PQ + RPU |
| HEVC Main10, SDR display        | 8-bit NV12 (tonemapped) | BT.709          |
| AV1 HDR                         | 10-bit P010           | BT.2020 / PQ     |

HDR → SDR tonemapping runs through a dedicated `VTPixelTransferSession` with a pre-allocated `CVPixelBufferPool` — separate from the decompression session so it doesn't interfere with the `controlTimebase`-driven display path used by Atmos.

On tvOS, the display layer opts into `preferredDynamicRange = .high` so the compositor doesn't silently clip BT.2020 pixels to Rec.709 after the TV has been told to switch to HDR.

## Subtitles

Subtitle packets are routed through the same demux loop as audio and video — no second AVIO connection, no full-file scan. Each packet decodes inline through `avcodec_decode_subtitle2`, the result lands in a single `[SubtitleCue]` published list:

- **Text codecs** (SubRip / ASS / SSA / WebVTT / mov_text) → `SubtitleCue.body = .text(String)`. ASS dialogue headers and override blocks (`{\an8}`, `{\b1}`, ...) are stripped; `\N` becomes a real newline so the host can render with regular text layout.
- **Bitmap codecs** (PGS / HDMV PGS / DVB / DVD) → `.image(SubtitleImage)`. The indexed pixel plane is walked through its palette, premultiplied against alpha, and wrapped as a `CGImage`. Position is normalised in `[0..1]` against the source video frame so the host scales to any on-screen rect.
- **Sidecar files** (a separate `.srt` / `.ass` / `.vtt` URL) → `selectSidecarSubtitle(url:)` opens its own short-lived `AVFormatContext`, decodes the whole file once, atomically swaps the result into `subtitleCues`.

A single packet that carries multiple rects (PGS often emits signs/songs at the top alongside dialogue at the bottom) becomes multiple cues at the same time range — the host renders all of them. Cues are inserted in sorted order; backward seeks dedupe by `start|end` so the list doesn't grow on rewind.

The host stays in charge of the actual paint: text styling, overlay layout, fade transitions, position scaling against the on-screen video rect.

## Architecture

```
Sources/AetherEngine/
├── AetherEngine.swift             Public API + demux/decode orchestration + subtitle stream decode
├── PlayerState.swift              PlaybackState, VideoFormat, TrackInfo, SubtitleCue, SubtitleImage
├── Demuxer/
│   ├── Demuxer.swift              libavformat wrapper
│   └── AVIOReader.swift           URLSession → avio_alloc_context
├── Decoder/
│   ├── VideoDecoder.swift         VideoToolbox + HDR tonemap
│   ├── SoftwareVideoDecoder.swift dav1d / libavcodec fallback
│   └── SubtitleDecoder.swift      Sidecar URL one-shot decode (text only)
├── Renderer/
│   └── SampleBufferRenderer.swift Display layer + B-frame reorder
└── Audio/
    ├── AudioDecoder.swift         libswresample → PCM
    ├── AudioOutput.swift          AVSampleBufferAudioRenderer
    ├── HLSAudioEngine.swift       AVPlayer driver for Atmos passthrough
    ├── HLSAudioServer.swift       Local HLS HTTP server
    └── FMP4AudioMuxer.swift       EAC3 → fMP4 with dec3/JOC
```

## Dependencies

| Package                                                            | License   | Purpose                      |
| ------------------------------------------------------------------ | --------- | ---------------------------- |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL-3.0  | Slim FFmpeg 7.1 + dav1d 1.5  |
| VideoToolbox                                                       | System    | Hardware decode, tonemap     |
| AVFoundation                                                       | System    | Audio renderer, AVPlayer, sync |
| CoreMedia                                                          | System    | Sample buffers, timing       |

## Non-goals

Things AetherEngine deliberately doesn't do, so you don't have to read the source to find out:

- No built-in UI. No controls, no transport bar, no pretty HUD.
- No analytics, telemetry, or session reporting. Wire your own to the `@Published` state.
- No playlist / queue management. Call `load(url:)` when you want the next one.
- No subtitle overlay. The engine decodes packets and emits `SubtitleCue` (text or `CGImage` with normalised position); your UI paints them with whatever style and animation you want.
- No Metal shaders. Everything renders through Apple's native display stack.
- No third-party networking. `URLSession` handles bytes; TLS / HTTP-3 / proxies / MDM rules ride for free.

## Requirements

| | Min |
| --- | --- |
| iOS | 16.0 |
| tvOS | 16.0 |
| macOS | 14.0 |
| Swift | 6.0 |
| Xcode | 16.0 |

## Used by

- [Sodalite](https://github.com/superuser404notfound/Sodalite) — native Jellyfin client for Apple TV.

## Built with

AetherEngine is vibe-coded — designed and shipped by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.

## License

[LGPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause grants explicit permission to distribute through application stores (Apple App Store, TestFlight, etc.) whose terms otherwise conflict with LGPL §4–6 — modifications to the engine itself still have to be released under LGPL.
