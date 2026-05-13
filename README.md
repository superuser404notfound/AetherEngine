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

A player engine that gets the hard parts right (HDR, Dolby Vision, Dolby Atmos, container coverage, codec coverage) and exposes either a SwiftUI `AetherPlayerView` or the raw `AVPlayerLayer` plus a handful of `async` methods. No `AVPlayerViewController`. No opinionated controls. No analytics. Bind the view, call `play()`, read the published properties for state.

You provide the transport bar. You provide the dropdowns. You provide the pretty.

## What it handles

| Area        | Details                                                                                                                     |
| ----------- | --------------------------------------------------------------------------------------------------------------------------- |
| Containers  | MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV (demux side; AVPlayer plays the engine's HLS-fMP4 wrapper)                           |
| HW decode   | H.264, HEVC, HEVC Main10 via VideoToolbox; VP9 on A12+ (Apple TV 4K Gen 2+); AV1 on any chip with HW AV1 (none on Apple TV as of 2026) |
| SW decode   | AetherEngine ships no SW decoder. Apple's bundled dav1d in VideoToolbox covers AV1 on iOS 17+ / macOS 14+ but is **not** on tvOS — `VTCapabilityProbe` gates AV1 strictly on `VTIsHardwareDecodeSupported` and refuses AV1 up front when VT won't decode it |
| HDR10       | BT.2020 + PQ signaled via the HLS-fMP4 wrapper; AVPlayer hands the bitstream to the system HDR pipeline                     |
| HDR10+      | Per-frame ST 2094-40 dynamic metadata preserved through stream-copy into the HLS-fMP4 wrapper                               |
| Dolby Vision| Profile 5 / 8.1 / 8.4. Stream-copied into HLS-fMP4 with `dvh1` / `dvhe` track type and the source's `dvcC` box intact, so tvOS triggers the HDMI DV handshake and DV-capable TVs switch into DV mode |
| HLG         | Transfer function detected and signaled                                                                                     |
| HDR to SDR  | Handled by AVPlayer / system compositor based on the connected display; no host-side tonemap                                |
| Audio       | AAC, AC3, EAC3, FLAC, MP3, Opus, Vorbis, TrueHD, DTS, DTS-HD MA, ALAC, PCM                                                  |
| Dolby Atmos | EAC3+JOC stream-copied through the HLS-fMP4 wrapper, played back by AVPlayer with Dolby MAT 2.0 unwrap downstream            |
| Surround    | 5.1 / 7.1 with correct `AudioChannelLayout` preserved through the wrapper                                                   |
| Subtitles   | SubRip / ASS / SSA / WebVTT / mov_text streamed inline; PGS / HDMV PGS / DVB / DVD rendered as `CGImage` with normalised position; sidecar `.srt` / `.ass` / `.vtt` URLs decoded via short-lived context |
| Seek        | Producer teardown + restart for backward / far-forward scrubs; short-range forward scrubs ride the cached segment window    |
| Streaming   | HTTP Range + chunked delegate reads via `URLSession`                                                                        |
| Resilience  | Exponential backoff on transient network errors, background pause, display-link aware lifecycle                             |

## Quick start

```swift
import AetherEngine
import SwiftUI

let player = try AetherEngine()

// SwiftUI: drop AetherPlayerSurface anywhere in the view tree
var body: some View {
    AetherPlayerSurface(engine: player)
}

// UIKit / AppKit: bind an AetherPlayerView directly
let surface = AetherPlayerView()
player.bind(view: surface)

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
player.$videoFormat   // .sdr, .hdr10, .hdr10Plus, .dolbyVision, .hlg

player.audioTracks    // [TrackInfo]
player.selectAudioTrack(index: trackID)

// Subtitles, text and bitmap, one published list
player.subtitleTracks                          // [TrackInfo] for the loaded source
player.selectSubtitleTrack(index: streamID)    // embedded, text or bitmap
player.selectSidecarSubtitle(url: srtURL)      // .srt / .ass / .vtt next to the media
player.clearSubtitle()
player.$subtitleCues                           // [SubtitleCue], body is .text(String) or .image(SubtitleImage)
player.$isSubtitleActive                       // host mirror gate
player.$isLoadingSubtitles                     // sidecar fetch + decode in progress
```

Install via Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", branch: "main")
```

## Playback pipeline

AetherEngine takes a remote video source (typically a Jellyfin MKV), demuxes it with libavformat, and re-muxes the elementary streams on the fly into HLS-fMP4. Local HTTP server on `127.0.0.1:<port>` serves the rolling playlist. `AVPlayer` plays the local URL. Apple's stack does all decode, all HDR / Dolby Vision signaling over HDMI, and all audio routing.

```
Source URL ──► Demuxer ──► HLSSegmentProducer ──► SegmentCache ──► HLSLocalServer
                                                                         │
                                                                         ▼
                                                                     AVPlayer
                                                                         │
                                                                         ├─► VideoToolbox (HW or system dav1d)
                                                                         └─► AVR / speakers (Atmos via MAT 2.0)
```

Why HLS-fMP4 instead of feeding `AVPlayer` the source URL directly: AVPlayer's progressive-download path won't accept arbitrary MKV containers, and even for MP4 sources it's brittle around Dolby Vision sample-description quirks and EAC3 `dec3` box variants. The HLS-fMP4 wrapper is the most permissive surface AVPlayer exposes; libavformat's `hls` muxer produces bytes byte-identical to `ffmpeg -f hls -hls_segment_type fmp4`, which is what Apple's HLS spec is defined against.

### Dolby Atmos

EAC3+JOC packets are stream-copied through the muxer with the original `dec3` extradata preserved. AVPlayer reads the segment, recognises JOC from the `dec3` box (`numDepSub=1`, `depChanLoc=0x0100`), and hands the bitstream to the HDMI output as Dolby MAT 2.0. The AVR lights up the Atmos indicator.

For codecs that fMP4 doesn't accept directly (TrueHD, DTS, DTS-HD MA, sometimes EAC3 from MKV when the `dec3` extradata can't be reconstructed), `AudioBridge` decodes to PCM and re-encodes losslessly as FLAC. This preserves bit-exact channel data for 5.1 / 7.1 surround but, by definition, loses spatial Atmos / TrueHD-MA metadata (it's a PCM derivative). The trade-off is per-source: keep the spatial mix when the wrapper can carry it, fall back to lossless 5.1 / 7.1 when it can't.

## HDR routing

| Source                              | Wrapper signaling                                                 |
| ----------------------------------- | ----------------------------------------------------------------- |
| H.264, HEVC (SDR)                   | BT.709                                                            |
| HEVC Main10 (HDR10)                 | BT.2020 / PQ                                                      |
| HEVC Main10 (HDR10+)                | BT.2020 / PQ + per-frame ST 2094-40 SEI stream-copied             |
| HEVC Main10 (DV P5 / P8.1 / P8.4)   | `dvh1` / `dvhe` track type with the source's `dvcC` box preserved |
| HEVC Main10 (HLG)                   | BT.2020 / HLG                                                     |
| AV1 HDR                             | BT.2020 / PQ                                                      |

HDR-to-SDR mapping is handled by AVPlayer and the system compositor according to the connected display. AetherEngine doesn't tonemap on the host; it tells the system "this is BT.2020 PQ" (or DV, or HLG) via the HLS-fMP4 sample description and lets tvOS / iOS pick the right path.

`DisplayCriteriaController` issues the HDMI content-frame-rate and dynamic-range hint via `AVDisplayManager` before the first segment is fetched, so the receiver-side handshake is in flight by the time `AVPlayer` is ready to render.

### Dolby Vision signaling

For DV streams the demuxer surfaces the source's `AVDOVIDecoderConfigurationRecord`. `HLSVideoEngine` writes the matching ISO BMFF `dvcC` box into the HLS-fMP4 sample description and promotes the track type from `hvc1` to `dvh1` (Profile 5, no HDR10 base) or `dvhe` (Profile 8.1 / 8.4 with HDR10 / HLG backward-compatible base layer). Profile 5 plays only on DV-capable displays; profiles 8.1 / 8.4 fall back to their base layer when the TV doesn't advertise DV.

### HDR10+ dynamic metadata

ST 2094-40 metadata stays attached to the HEVC bitstream as user-data-registered ITU-T T.35 SEI NALs. The HLS-fMP4 stream-copy preserves the SEI through to `AVPlayer`, which forwards it to the system compositor. HDR10+-capable TVs apply the per-scene tone-mapping curves; HDR10-only TVs fall back to the static HDR10 base.

## Subtitles

Subtitle packets are routed through the same demux loop as audio and video. No second AVIO connection, no full-file scan. Each packet decodes inline through `avcodec_decode_subtitle2`, the result lands in a single `[SubtitleCue]` published list:

- **Text codecs** (SubRip / ASS / SSA / WebVTT / mov_text) → `SubtitleCue.body = .text(String)`. ASS dialogue headers and override blocks (`{\an8}`, `{\b1}`, ...) are stripped; `\N` becomes a real newline so the host can render with regular text layout.
- **Bitmap codecs** (PGS / HDMV PGS / DVB / DVD) → `.image(SubtitleImage)`. The indexed pixel plane is walked through its palette, premultiplied against alpha, and wrapped as a `CGImage`. Position is normalised in `[0..1]` against the source video frame so the host scales to any on-screen rect.
- **Sidecar files** (a separate `.srt` / `.ass` / `.vtt` URL) → `selectSidecarSubtitle(url:)` opens its own short-lived `AVFormatContext`, decodes the whole file once, atomically swaps the result into `subtitleCues`.

A single packet that carries multiple rects (PGS often emits signs/songs at the top alongside dialogue at the bottom) becomes multiple cues at the same time range, and the host renders all of them. Cues are inserted in sorted order; backward seeks dedupe by `start|end` so the list doesn't grow on rewind.

The host stays in charge of the actual paint: text styling, overlay layout, fade transitions, position scaling against the on-screen video rect.

## Architecture

```
Sources/AetherEngine/
├── AetherEngine.swift                       Public API + orchestration + subtitle stream decode
├── PlayerState.swift                        PlaybackState, VideoFormat, TrackInfo, SubtitleCue, SubtitleImage
├── Audio/
│   └── AudioBridge.swift                    Stream-copy or lossless FLAC transcode per source audio codec
├── Decoder/
│   ├── EmbeddedSubtitleDecoder.swift        Inline subtitle decode from demuxed packets
│   └── SubtitleDecoder.swift                Sidecar URL one-shot decode (text only)
├── Demuxer/
│   ├── AVIOReader.swift                     URLSession → avio_alloc_context
│   └── Demuxer.swift                        libavformat wrapper
├── Diagnostics/
│   └── EngineLog.swift                      Gated OSLog emission
├── Display/
│   ├── DisplayCriteriaController.swift      AVDisplayManager content-rate / dynamic-range hints
│   └── FrameRateSnap.swift                  Snap to standard rates (23.976, 24, 25, 29.97, 30, 50, 59.94, 60)
├── Native/
│   └── NativeAVPlayerHost.swift             AVPlayer host bound to the loopback HLS-fMP4 URL
├── Network/
│   └── HLSLocalServer.swift                 Local HTTP server (127.0.0.1) serving playlist + segments
├── Video/
│   ├── HLSVideoEngine.swift                 Session orchestrator: muxer wiring, DV signaling, scrub teardown
│   ├── HLSSegmentProducer.swift             Drives libavformat's hls-fmp4 muxer; custom io_open hooks segment writes
│   ├── SegmentCache.swift                   Producer/consumer segment store with backpressure + scrub-aware eviction
│   └── VTCapabilityProbe.swift              VP9 / AV1 system support probe (registers supplemental decoders)
└── View/
    └── AetherPlayerView.swift               SwiftUI wrapper around the AVPlayerLayer the engine owns
```

## Dependencies

| Package                                                            | License   | Purpose                                                                  |
| ------------------------------------------------------------------ | --------- | ------------------------------------------------------------------------ |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL-3.0  | Slim FFmpeg 7.1 (avcodec / avformat / avutil / swresample) for demux + HLS-fMP4 mux + AudioBridge FLAC encode |
| VideoToolbox                                                       | System    | All video decode (HW + Apple's bundled software AV1)                     |
| AVFoundation                                                       | System    | AVPlayer playback, AVDisplayManager HDMI handshake                       |
| CoreMedia                                                          | System    | Sample descriptions, format-description tagging                          |

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

- [Sodalite](https://github.com/superuser404notfound/Sodalite): native Jellyfin client for Apple TV.

## Built with

AetherEngine is vibe-coded, designed and shipped by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.

## License

[LGPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause grants explicit permission to distribute through application stores (Apple App Store, TestFlight, etc.) whose terms otherwise conflict with LGPL §4–6. Modifications to the engine itself still have to be released under LGPL.
