<p align="center">
  <img src=".github/aetherengine-logo.png" alt="AetherEngine" width="180">
</p>

<h1 align="center">AetherEngine</h1>

<p align="center">
  <b>A video player engine for Apple platforms.</b><br>
  FFmpeg demuxes. VideoToolbox decodes. AVPlayer handles Dolby Atmos.<br>
  You ship the UI.
</p>

<p align="center">
  <a href="https://github.com/superuser404notfound/AetherEngine/releases/latest"><img src="https://img.shields.io/github/v/release/superuser404notfound/AetherEngine?label=release&color=blue"></a>
  <a href="https://github.com/superuser404notfound/AetherEngine/actions/workflows/ci.yml"><img src="https://github.com/superuser404notfound/AetherEngine/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/AetherEngine"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FAetherEngine%2Fbadge%3Ftype%3Dswift-versions"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/AetherEngine"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FAetherEngine%2Fbadge%3Ftype%3Dplatforms"></a>
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white">
  <img src="https://img.shields.io/badge/license-LGPL--3.0%20%2B%20App%20Store%20Exception-lightgrey">
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

---

## What it is

A player engine that gets the hard parts right (HDR, Dolby Vision, Dolby Atmos, container coverage, codec coverage) and exposes a single `AetherPlayerView` (UIKit / AppKit) or `AetherPlayerSurface` (SwiftUI) plus a handful of `async` methods. No `AVPlayerViewController`. No opinionated controls. No analytics. Bind the view, call `play()`, read the published properties for state.

The view is polymorphic: under the hood the engine swaps the hosted CALayer (`AVPlayerLayer` for the native AVPlayer path, `AVSampleBufferDisplayLayer` for the SW dav1d fallback path) per session without the host having to know.

You provide the transport bar. You provide the dropdowns. You provide the pretty.

## What it handles

| Area        | Details                                                                                                                     |
| ----------- | --------------------------------------------------------------------------------------------------------------------------- |
| Containers  | MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV (demux side)                                                                         |
| HW decode   | H.264, HEVC, HEVC Main10 via VideoToolbox in AVPlayer's HLS-fMP4 path. AV1 on devices with HW AV1 (M3+ Mac, iPhone 15 Pro+, future Apple TV chips) also routes natively |
| SW decode   | AV1 (libavcodec/dav1d) on devices without HW AV1 — currently all Apple TVs, M1/M2 Macs, pre-A17-Pro iPhones. VP9 and VP8 (libavcodec native) unconditionally, since AVPlayer's HLS pipeline rejects the `vp09` / `vp08` CODECS attributes even where VT can HW-decode them. MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, and VC-1 also route SW since AVPlayer's HLS-fMP4 pipeline does not accept them; libavcodec ships native decoders for all three. All render through `SoftwareVideoDecoder` + `AVSampleBufferDisplayLayer`. Dispatch decision lives in `AetherEngine.load`, gated per source on `VTCapabilityProbe` and codec id |
| HDR10       | BT.2020 + PQ signaled via the HLS-fMP4 wrapper; AVPlayer hands the bitstream to the system HDR pipeline                     |
| HDR10+      | Per-frame ST 2094-40 dynamic metadata preserved through stream-copy into the HLS-fMP4 wrapper                               |
| Dolby Vision| HEVC P5 / P8.1 / P8.4 with `dvh1` / `hvc1` track type + `dvcC` box. AV1 P10.0 / P10.1 / P10.4 with `dav1` / `av01` track type + `dvvC` box (per Apple HLS Authoring Spec + Dolby ETSI TS 103 572). Both engage the tvOS HDMI DV handshake on DV-capable displays |
| HLG         | Transfer function detected and signaled                                                                                     |
| HDR to SDR  | Handled by AVPlayer / system compositor based on the connected display; no host-side tonemap                                |
| Audio       | AAC, AC3, EAC3, FLAC, MP2, MP3, Opus, Vorbis, TrueHD, MLP, DTS, DTS-HD MA, ALAC, PCM. Codecs that stream-copy into fMP4 (AAC, AC3, EAC3, FLAC, ALAC) pass through losslessly. Non-streamable codecs route through `AudioBridge` in one of two modes (`AudioBridgeMode`): `.surroundCompat` (default, EAC3 at 128 kbps per channel — 256 kbps stereo, 768 kbps 5.1 — lossy but surround works on every modern soundbar via the bitstream tunnel) or `.lossless` (FLAC up to 7.1, lossless, needs an AVR that accepts multichannel LPCM over HDMI). |
| Dolby Atmos | EAC3+JOC stream-copied through the HLS-fMP4 wrapper, played back by AVPlayer with Dolby MAT 2.0 unwrap downstream. TrueHD-MAT object metadata is not preserved through the bridge in either mode (FFmpeg's EAC3 encoder doesn't produce JOC, which is the Dolby-licensed Atmos-in-EAC3 extension).        |
| Surround    | 5.1 / 7.1 with correct `AudioChannelLayout` preserved through the wrapper                                                   |
| Subtitles   | SubRip / ASS / SSA / WebVTT / mov_text streamed inline; PGS / HDMV PGS / DVB / DVD rendered as `CGImage` with normalised position; sidecar `.srt` / `.ass` / `.vtt` URLs decoded via short-lived context |
| Frames      | Still-image extraction off-playback via `FrameExtractor`: `thumbnail` (nearest keyframe, downscaled, fast, for scrub previews / Recents) and `snapshot` (frame-accurate, full resolution, for user stills), both as `CGImage`. Isolated FFmpeg decode context, bounded LRU cache, idle-close lifecycle |
| Seek        | Producer teardown + restart for backward / far-forward scrubs; short-range forward scrubs ride the cached segment window    |
| Streaming   | HTTP Range + chunked delegate reads via `URLSession`                                                                        |
| Live        | Scaffold-level: `LoadOptions.isLive` opts the session in; engine publishes `@Published var isLive` for hosts, ignores `seek()`. H.264 / HEVC inside MPEG-TS routes through the native AVPlayer pipeline; MPEG-2 / MPEG-4 / VC-1 / VP8 / VP9 inside MPEG-TS routes through the SW pipeline. Sliding-window segment eviction for unbounded sessions is not yet implemented (long native-path sessions will accumulate cached segments) |
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

try await player.load(url: videoURL)                                        // or
try await player.load(url: videoURL, startPosition: 347.5)                  // resume
try await player.load(
    url: videoURL,
    options: .init(
        httpHeaders: headers,             // attached to every demux + segment fetch
        matchContentEnabled: matchContent // tvOS Match Content master toggle
    )
)
try await player.reloadAtCurrentPosition()  // background reopen, preserves options

player.play()
player.pause()
player.setRate(1.5)
await player.seek(to: 120)
player.stop()

// Observe (Combine @Published)
player.$state         // .idle, .loading, .playing, .paused, .seeking, .error
player.$currentTime   // AVPlayer's HLS clock (use for transport / scrub / resume)
player.$sourceTime    // source PTS of the displayed frame (use for subtitle alignment)
player.$duration
player.$videoFormat   // .sdr, .hdr10, .hdr10Plus, .dolbyVision, .hlg
player.$currentAVPlayer  // active AVPlayer, re-emitted on every reload (MPNowPlayingSession)

player.audioTracks    // [TrackInfo]
player.selectAudioTrack(index: trackID)

// Info panel / Now Playing (iOS / tvOS)
player.setExternalMetadata([
    AVMetadataItem(/* title, artwork, etc. */)
])

// Subtitles, text and bitmap, one published list
player.subtitleTracks                          // [TrackInfo] for the loaded source
player.selectSubtitleTrack(index: streamID)    // embedded, text or bitmap
player.selectSidecarSubtitle(url: srtURL)      // .srt / .ass / .vtt next to the media
player.clearSubtitle()
player.$subtitleCues                           // [SubtitleCue], body is .text(String) or .image(SubtitleImage)
player.$isSubtitleActive                       // host mirror gate
player.$isLoadingSubtitles                     // sidecar fetch + decode in progress

// Still frames, off-playback (scrub preview, snapshot, Recents thumbnail)
let frames = player.makeFrameExtractor()           // for the currently loaded URL, or nil
// or, for an arbitrary item: FrameExtractor(url:httpHeaders:)
await frames?.prewarm()                            // open the decode context ahead of a scrub
let thumb = await frames?.thumbnail(at: 612.0)     // nearest keyframe, downscaled (maxWidth: 320)
let still = await frames?.snapshot(at: 612.0)      // frame-accurate, full resolution
await frames?.shutdown()                           // prompt teardown (else idle-closes after 10 s)
```

Subtitle cues land in raw source PTS. On the native path, AVPlayer's HLS clock sits at `source_pts - producer.videoShiftPts` (the producer applies a per-session shift to align the first segment's tfdt with the playlist origin, and the shift can change on every restart). Render the overlay against `player.sourceTime` so cues match the spoken audio regardless of which producer session is active.

Install via Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "2.0.0")
```

Two complementary samples ship in `Examples/`:

- [`MinimalPlayer/`](Examples/MinimalPlayer/MinimalPlayerApp.swift) — 90-line SwiftUI drop-in for developers integrating the engine. Copy the file into a new Xcode tvOS / iOS / macOS app, point at a URL, run.
- [`DemoPlayerMac/`](Examples/DemoPlayerMac/README.md) — standalone macOS app for testers wanting to exercise the engine against their own media without writing host code. Drop a file onto the window, it plays. Pre-built universal `.dmg` is attached to every [GitHub Release](https://github.com/superuser404notfound/AetherEngine/releases/latest) (notarized, runs cleanly through Gatekeeper).

## Used by

<!-- used-by:start -->
- [Sodalite](https://github.com/superuser404notfound/Sodalite): native Jellyfin client for Apple TV.
- [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer): native macOS media player.
- [Testarossa Player](https://example.com/testarossa-e2e): throwaway end-to-end test, safe to delete.
<!-- used-by:end -->

Shipping something on AetherEngine? [Submit it](https://github.com/superuser404notfound/AetherEngine/issues/new?template=used-by-submission.yml) to get listed.

## Host setup on tvOS

For HDR / Dolby Vision sources to play reliably on tvOS 26.5+, the
engine must drive `AVDisplayManager.preferredDisplayCriteria` itself
(synchronously, before the AVPlayerItem assignment). Apple Tech Talk
503 has prescribed this ordering since 2017, and tvOS 26.5 now
enforces it synchronously at HLS variant validation: the validator
rejects variants whose `VIDEO-RANGE` the panel can't currently host
with `AVFoundationErrorDomain -11868 / AVErrorNoCompatibleAlternatesForExternalDisplay`,
before fetching the `EXT-X-MAP` init segment, producing
`item.status = .failed` with zero `errorLog().events`. SDR variants
are unaffected since SDR is universally supported.

AVKit-auto criteria (`appliesPreferredDisplayCriteriaAutomatically = true`)
cannot satisfy this contract for HLS multivariant HDR sources because
AVKit reads criteria from `AVAsset.preferredDisplayCriteria`, which
is synthesized from the chosen variant's `CMVideoFormatDescription`,
which only exists after `init.mp4` is parsed, which only happens
after the variant passes the validator. Chicken-and-egg.

Engine-driven sole-writer is the working pattern:

```swift
// In your AVPlayerViewController subclass
playerVC.appliesPreferredDisplayCriteriaAutomatically = false

// When loading
try await engine.load(
    url: url,
    options: LoadOptions(
        suppressDisplayCriteria: false,      // default; engine writes criteria
        matchContentEnabled: matchContent,   // tvOS Match Content master toggle
        panelIsInHDRMode: panelInHDRMode     // current EDR-headroom > 1.0
    )
)
```

`LoadOptions.suppressDisplayCriteria` defaults to `false` so the
engine-driven path is the default. The engine's `apply()` runs
synchronously inside `load(url:)`, then `waitForSwitch` blocks
until the panel reaches the target mode or 5 s timeout, then
`replaceCurrentItem` runs against an already-correct panel mode.

## Playback pipeline

AetherEngine has two playback pipelines, picked once at `load(url:)` based on the source's video codec:

**Native AVPlayer pipeline (default).** Demux the source with libavformat, re-mux the elementary streams on the fly into HLS-fMP4, serve them from a local HTTP server on `127.0.0.1:<port>`, point `AVPlayer` at the playlist. Apple's stack does all decode, all HDR / Dolby Vision signaling over HDMI, all audio routing. This is the path for HEVC and H.264, which is what AVPlayer's HLS-fMP4 pipeline reliably accepts. Atmos passthrough, DV HDMI handshake, HDR10 / HDR10+ system-side tone-mapping all live on this path.

```
Source URL ──► Demuxer ──► HLSSegmentProducer ──► SegmentCache ──► HLSLocalServer
                                                                         │
                                                                         ▼
                                                                     AVPlayer
                                                                         │
                                                                         ├─► VideoToolbox (HW decode)
                                                                         └─► AVR / speakers (Atmos via MAT 2.0)
```

**Software decoder pipeline (AV1 + VP9 + VP8 + legacy fallback).** Demux the source, run video packets through libavcodec (dav1d for AV1, FFmpeg's native decoder for VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1) into `CVPixelBuffer`s, run audio through libavcodec into `CMSampleBuffer`s, render via `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` as the master clock. Used for codecs AVPlayer's HLS-fMP4 pipeline doesn't accept: AV1 (no AV1 decoder on tvOS at all; Apple ships dav1d on iOS / macOS only, no Apple TV chip has HW AV1), VP9 / VP8 (AVPlayer parses the HLS manifest, sees `vp09` / `vp08` in the CODECS attribute, then silently stops fetching — `item.status` never leaves `.unknown`. VideoToolbox HW-decodes VP9 fine, but only outside the HLS pipeline), and legacy MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, and VC-1 (none of `mp4v.20.X` / `mp2v` / `vc-1` are in Apple's HLS Authoring Spec CODECS list).

```
Source URL ──► Demuxer ──┬─► SoftwareVideoDecoder (dav1d) ──► SampleBufferRenderer
                          │                                            │
                          │                                            ▼
                          │                            AVSampleBufferDisplayLayer
                          │                                            ▲
                          └─► AudioDecoder ──► AudioOutput ────────────┘
                                                  │             (synchronizer drives the layer's
                                                  ▼              control timebase → A/V sync)
                                              AVR / speakers
```

AV1+DV (Profile 10.0 / 10.1 / 10.4) routes through the native path on hardware-AV1 hosts via the `dav1` / `av01` track type plus the source's `dvvC` box. AV1+Atmos is genuinely rare in the wild (mastering still runs in HEVC overwhelmingly), so the SW pipeline's lack of Atmos passthrough is a theoretical limitation rather than a real one. The dispatch happens once at load time; hosts see a unified `@Published` state surface either way.

Why HLS-fMP4 for the native path instead of feeding `AVPlayer` the source URL directly: AVPlayer's progressive-download path won't accept arbitrary MKV containers, and even for MP4 sources it's brittle around Dolby Vision sample-description quirks and EAC3 `dec3` box variants. The HLS-fMP4 wrapper is the most permissive surface AVPlayer exposes; libavformat's `hls` muxer produces bytes byte-identical to `ffmpeg -f hls -hls_segment_type fmp4`, which is what Apple's HLS spec is defined against.

### Dolby Atmos

EAC3+JOC packets are stream-copied through the muxer untouched. AVPlayer reads the segment, recognises JOC from the `dec3` box (`numDepSub=1`, `depChanLoc=0x0100`), and hands the bitstream to the HDMI output as Dolby MAT 2.0. The AVR lights up the Atmos indicator. The engine emits an explicit `[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged, MAT 2.0 passthrough intact` diagnostic on every Atmos session so the path is unambiguous in the log.

Matroska CodecPrivate doesn't usually carry the pre-parsed `dec3` / `dac3` box content the mov muxer needs at `avformat_write_header` time, so the muxer is configured with `+delay_moov` (alongside `+empty_moov+default_base_moof+frag_custom`). The moov atom is deferred until the first fragment-cut flush, by which point packets have flowed through `mov_write_packet` and libavformat's `handle_eac3` / `handle_ac3` have populated the sample-entry boxes from the actual packet bitstream. The first cut emits the deferred ftyp+moov (routed by `FragmentSplitter` to init.mp4); subsequent cuts emit normal moof+mdat for the segment files. Net effect: EAC3 / AC3 from matroska direct-play stream-copies cleanly with valid sample-entries, no manual bitstream parsing on the host side.

For codecs that fMP4 doesn't accept directly (TrueHD, DTS, DTS-HD MA, MP3, Opus), `AudioBridge` decodes to PCM and re-encodes in one of two modes. By default (`AudioBridgeMode.surroundCompat`) it produces lossy EAC3 at 128 kbps per channel (256 kbps stereo, 768 kbps 5.1): AVPlayer hands the encoded bitstream to HDMI and the sink decodes its own 5.1 mix, so surround works on essentially every modern AVR and soundbar (Sonos Arc, Samsung HW-Q, Bose). The opt-in alternative (`.lossless`) produces FLAC up to 7.1 lossless, which AVPlayer decodes to LPCM. The lossless path needs an AVR that accepts multichannel LPCM via HDMI (Denon, Marantz, NAD); on soundbars and basic AVRs that handle multichannel only via bitstream codecs the LPCM gets downmixed to stereo at the route. Hosts pick the mode through `LoadOptions.audioBridgeMode`; `.surroundCompat` is the default because the soundbar / basic-AVR install base is the majority. Atmos / TrueHD-MA object metadata is lost in either mode: FFmpeg's EAC3 encoder doesn't produce JOC (Dolby-licensed Atmos-in-EAC3 extension), and FLAC has no object channel concept. If a JOC source ever falls through to the bridge for whatever reason the engine logs a loud `WARNING: Atmos downgrade — ...` so the silent quality regression doesn't go unnoticed.

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

For DV streams the demuxer surfaces the source's `AVDOVIDecoderConfigurationRecord`. On DV-capable displays, `HLSVideoEngine` writes the matching ISO BMFF `dvcC` box into the HLS-fMP4 sample description and emits a bare `dvh1.<profile>.<dvLevel>` codec tag for Profile 5, 8.1, and 8.4 so AVKit's auto-criteria reads `dvh1` from the sample entries and engages DV mode directly. On non-DV displays the engine downgrades to plain `hvc1`: Profile 5 is unplayable there (no HDR10 base), and Profiles 8.1 / 8.4 fall back to their HDR10 / HLG base layer with AVPlayer's tone-mapping path. AV1+DV (Profile 10.0 / 10.1 / 10.4) uses the parallel `dav1` / `av01` track type plus `dvvC` box on hardware-AV1 hosts.

### HDR10+ dynamic metadata

ST 2094-40 metadata stays attached to the HEVC bitstream as user-data-registered ITU-T T.35 SEI NALs. The HLS-fMP4 stream-copy preserves the SEI through to `AVPlayer`, which forwards it to the system compositor. HDR10+-capable TVs apply the per-scene tone-mapping curves; HDR10-only TVs fall back to the static HDR10 base.

The published `videoFormat` starts at `.hdr10` for any BT.2020 / PQ source and flips to `.hdr10Plus` the first time a packet's T.35 SEI signature is seen in the producer's scan. Debounced across producer restarts so a scrub doesn't re-fire. Hosts can drive an HDR10+ badge or analytics hook off the `$videoFormat` transition.

## Subtitles

Subtitle packets are routed through the same demux loop as audio and video. No second AVIO connection, no full-file scan. Each packet decodes inline through `avcodec_decode_subtitle2`, the result lands in a single `[SubtitleCue]` published list:

- **Text codecs** (SubRip / ASS / SSA / WebVTT / mov_text) → `SubtitleCue.body = .text(String)`. ASS dialogue headers and override blocks (`{\an8}`, `{\b1}`, ...) are stripped; `\N` becomes a real newline so the host can render with regular text layout.
- **Bitmap codecs** (PGS / HDMV PGS / DVB / DVD) → `.image(SubtitleImage)`. The indexed pixel plane is walked through its palette, premultiplied against alpha, and wrapped as a `CGImage`. Position is normalised in `[0..1]` against the source video frame so the host scales to any on-screen rect.
- **Sidecar files** (a separate `.srt` / `.ass` / `.vtt` URL) → `selectSidecarSubtitle(url:)` opens its own short-lived `AVFormatContext`, decodes the whole file once, atomically swaps the result into `subtitleCues`.

A single packet that carries multiple rects (PGS often emits signs/songs at the top alongside dialogue at the bottom) becomes multiple cues at the same time range, and the host renders all of them. Cues are inserted in sorted order; backward seeks dedupe by `start|end` so the list doesn't grow on rewind.

The host stays in charge of the actual paint: text styling, overlay layout, fade transitions, position scaling against the on-screen video rect.

## Frame extraction

`FrameExtractor` produces still `CGImage`s from a media URL through an FFmpeg decode context that is fully isolated from playback. It never touches the playback pipeline, the HLS loopback server, or the engine's shared state, so a scrub-preview decode can't perturb the frame on screen. Two modes share one decode core:

- **`thumbnail(at:maxWidth:)`**: seeks to the nearest keyframe, no forward decode, downscaled to `maxWidth` (default 320). Cheap and fast; built for scrub previews and Recents lists.
- **`snapshot(at:maxSize:)`**: decodes forward to the exact PTS, full or `maxSize`-clamped resolution. Built for user-triggered stills.

```swift
// For the currently-playing item:
let frames = engine.makeFrameExtractor()           // nil if nothing is loaded

// For an arbitrary item (e.g. a Recents row), construct directly:
let frames = FrameExtractor(url: url, httpHeaders: headers)

await frames.prewarm()                             // optional: hide cold-start at gesture begin
let preview = await frames.thumbnail(at: 612.0)    // CGImage?, nearest keyframe
let still   = await frames.snapshot(at: 612.0)     // CGImage?, frame-accurate
await frames.shutdown()                            // prompt teardown of the decode context
```

`FrameExtractor` is an `actor`. Blocking FFmpeg work runs on a dedicated serial queue, never on the cooperative thread pool. The decode context opens lazily on first use; a superseded request (the common case during an active scrub) cancels the in-flight decode so the latest position wins. Results land in a bounded LRU cache (snapshots and thumbnails kept in separate stores, thumbnails bucketed by second). After 10 s idle the context closes and the cache drops automatically; the next request reopens lazily. `shutdown()` is the explicit, permanent teardown: it awaits release of the FFmpeg demuxer / codec / sws resources and refuses further work. The engine does not retain the extractor returned by `makeFrameExtractor()`; the caller owns its lifecycle.

## Architecture

```
Sources/AetherEngine/
├── AetherEngine.swift                       Public API + codec dispatch + subtitle stream decode
├── PlayerState.swift                        PlaybackState, VideoFormat, PlaybackBackend, TrackInfo, SubtitleCue, SubtitleImage
├── Audio/
│   ├── AudioBridge.swift                    Native path: decode + re-encode per `AudioBridgeMode` (EAC3 5.1 default or lossless FLAC opt-in) for source codecs that can't stream-copy into fMP4
│   ├── AudioDecoder.swift                   SW path: libavcodec → PCM → CMSampleBuffer with channel-layout tagging
│   └── AudioOutput.swift                    SW path: AVSampleBufferAudioRenderer + Synchronizer (master clock)
├── Decoder/
│   ├── EmbeddedSubtitleDecoder.swift        Inline subtitle decode from demuxed packets
│   ├── HardwareVideoDecoder.swift           SW path: VideoToolbox HW HEVC / AV1 decoder for sources routed away from AVPlayer
│   ├── SoftwareVideoDecoder.swift           SW path: libavcodec/dav1d → CVPixelBuffer (NV12 / P010), HDR10+ side data
│   ├── SubtitleDecoder.swift                Sidecar URL one-shot decode (text only)
│   └── VideoDecoderTypes.swift              DecodedFrameHandler typealias + VideoDecoderError
├── Demuxer/
│   ├── AVIOReader.swift                     URLSession-backed avio_alloc_context with 4 MB Range-fetch chunks via delegate-based incremental reads
│   └── Demuxer.swift                        libavformat wrapper
├── Diagnostics/
│   ├── EngineLog.swift                      Gated OSLog emission
│   ├── LiveTelemetry.swift                  Value type emitted at 1 Hz: instant / avg bitrate, buffer, network, dropped frames, observed FPS, A/V sync gap, plus subsystem byte counters
│   ├── LiveTelemetrySampler.swift           @MainActor 1 Hz sampler that reads existing subsystem counters and assembles LiveTelemetry snapshots
│   └── PacketBalanceTracker.swift           Process-wide AVPacket alloc/free balance counter for leak diagnostics
├── Display/
│   ├── DisplayCriteriaController.swift      AVDisplayManager content-rate / dynamic-range hints (native path)
│   └── FrameRateSnap.swift                  Snap to standard rates (23.976, 24, 25, 29.97, 30, 50, 59.94, 60)
├── FrameExtractor/
│   ├── AetherEngine+FrameExtractor.swift    makeFrameExtractor() convenience for the currently loaded URL
│   ├── FrameExtractor.swift                 Off-playback still extraction actor: serial decode queue, cancel-supersede, idle-close
│   ├── FrameDecodeContext.swift             Isolated FFmpeg demux + decode + sws_scale → CGImage (thumbnail / snapshot)
│   ├── FrameCache.swift                     Bounded LRU: mode-isolated stores, second-bucketed thumbnails
│   └── FrameTypes.swift                     FrameMode (.thumbnail / .snapshot)
├── Native/
│   ├── NativeAVPlayerHost.swift             Native path: AVPlayer host bound to the loopback HLS-fMP4 URL
│   └── SoftwarePlaybackHost.swift           SW path: demux loop + decoders + renderer + synchronizer orchestration
├── Network/
│   └── HLSLocalServer.swift                 Native path: local HTTP server (127.0.0.1) serving playlist + segments
├── Renderer/
│   └── SampleBufferRenderer.swift           SW path: AVSampleBufferDisplayLayer + B-frame reorder, HDR10+ attachments
├── Video/
│   ├── HLSVideoEngine.swift                 Native path: session orchestrator (muxer wiring, audio cascade, DV signaling, scrub teardown)
│   ├── HLSSegmentProducer.swift             Native path: pump loop reading from Demuxer, feeding MP4SegmentMuxer, cutting fragments at segment-plan boundaries
│   ├── MP4SegmentMuxer.swift                Native path: session-long fragmented-MP4 muxer (+empty_moov+default_base_moof+frag_custom+delay_moov)
│   ├── FragmentSplitter.swift               Native path: routes mp4 muxer's avio output stream into init.mp4 (ftyp+moov) vs per-segment moof+mdat files
│   ├── SegmentCache.swift                   Native path: producer/consumer segment store with backpressure + scrub-aware eviction
│   └── VTCapabilityProbe.swift              AV1 system-decode probe (gates codec routing; VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 always route SW)
└── View/
    └── AetherPlayerView.swift               Polymorphic surface: hosts either AVPlayerLayer (native) or AVSampleBufferDisplayLayer (SW)
```

## Dependencies

| Package                                                            | License   | Purpose                                                                  |
| ------------------------------------------------------------------ | --------- | ------------------------------------------------------------------------ |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL-3.0  | Slim FFmpeg 8.1 (avcodec / avformat / avutil / swresample / swscale) for demux + HLS-fMP4 mux + AudioBridge FLAC encode + SW-path dav1d decode + sws_scale YUV → NV12 / P010 |
| VideoToolbox                                                       | System    | Native path video decode (HW where available, Apple's bundled SW dav1d on iOS / macOS) |
| AVFoundation                                                       | System    | AVPlayer + AVDisplayManager (native path); AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer (SW path) |
| CoreMedia                                                          | System    | Sample descriptions, format-description tagging, CMTimebase                |

## aetherctl

A standalone macOS CLI is shipped alongside the library for repro
work without going through TestFlight + Apple TV. Five subcommands,
all operating on a media source URL (`file://` or `http(s)://`):

```bash
swift run aetherctl probe <url>          # dump container + streams + duration, exit
swift run aetherctl serve <url>          # park the engine's loopback HLS-fMP4 server
swift run aetherctl validate <url>       # serve + run mediastreamvalidator, exit
swift run aetherctl swdecode <url>       # open SoftwareVideoDecoder, decode N packets, report
swift run aetherctl extract <url>        # FrameExtractor still-image extraction + leak testing
swift run aetherctl <url>                # alias for serve (backwards compat)
```

`probe` opens the demuxer, prints the codec / resolution / frame rate
of the video track, the audio track list (codec, channels, language,
Atmos flag), the subtitle track list, then exits. No HLS server is
started.

`serve` is the original behavior. The CLI prints the loopback URL and
parks until Ctrl-C; from another terminal you can:

```bash
curl -i  http://127.0.0.1:<port>/master.m3u8
curl -o  /tmp/init.mp4   http://127.0.0.1:<port>/init.mp4
mediastreamvalidator http://127.0.0.1:<port>/master.m3u8
mp4dump --verbosity 1 /tmp/init.mp4
ffprobe -v debug /tmp/seg0.mp4
open 'http://127.0.0.1:<port>/master.m3u8'   # macOS QuickTime
```

`validate` is the same plus an inline `xcrun mediastreamvalidator`
run against the loopback manifest, with the report printed and the
engine torn down on completion.

`swdecode` opens `SoftwareVideoDecoder` for the source's video stream,
feeds up to N packets (default 100, override with `--frames N`),
and reports counters plus first-frame metadata (pixel format,
dimensions). Tests the SW-pipeline decode path end-to-end without
needing a render layer. Useful for legacy codecs (MPEG-4 Part 2,
MPEG-2, VC-1) and AV1 / VP9 on platforms where the native AVPlayer
path doesn't accept them. Verdict distinguishes between three
failure modes:

- decoder open failed (FFmpegBuild gate or malformed extradata)
- decoder opened but no frames produced (pixel-format conversion,
  no IDR in window)
- SW decode end-to-end healthy (if real playback still hangs, the
  failure is downstream in `SoftwarePlaybackHost` frame-enqueue,
  display-layer attach, or audio-clock sync)

Backed by the public `AetherEngine.swDecodeProbe(url:maxPackets:options:)`
static API returning `SoftwareDecodeProbeResult`. Hosts can use the
same probe in their own diagnostic overlays.

`extract` opens a `FrameExtractor` against the source and pulls a
still frame. Thumbnail mode (default) snaps to the nearest keyframe
and downscales to `--width` (default 320); `--snapshot` decodes
frame-accurately at full resolution. `--at <sec>` sets the seek
position (default 60.0). The first frame is written to
`/tmp/aetherctl-extract-<mode>.png`. `--loops N` repeats the
extraction across eight cycling positions, which pairs with
`leaks --atExit` to validate the decode-context teardown is clean:

```bash
swift run aetherctl extract --at 612 --snapshot <url>          # frame-accurate still
swift run aetherctl extract --width 480 <url>                  # keyframe thumbnail
leaks --atExit -- .build/debug/aetherctl extract --loops 8 <url>   # leak sweep
```

For repeatable runs, `Scripts/fetch-fixtures.sh` generates a small
set of synthetic FFmpeg test clips in `./Fixtures/` (H.264 SDR,
HEVC HDR10, AV1, VP9) covering both the native AVPlayer path and
the software fallback. Real-world DV / Atmos / multichannel sources
go in `./Fixtures/user/` (gitignored).

## Non-goals

Things AetherEngine deliberately doesn't do, so you don't have to read the source to find out:

- No built-in UI. No controls, no transport bar, no pretty HUD.
- No external analytics or session reporting. A 1 Hz `@Published liveTelemetry: LiveTelemetry?` surface is provided for host UIs that want to render runtime stats locally; nothing leaves the device.
- No playlist / queue management. Call `load(url:)` when you want the next one.
- No subtitle overlay. The engine decodes packets and emits `SubtitleCue` (text or `CGImage` with normalised position); your UI paints them with whatever style and animation you want.
- No Metal shaders. Everything renders through Apple's native display stack.
- No third-party networking. `URLSession` handles bytes; TLS / HTTP-3 / proxies / MDM rules ride for free.

## Known limitations

Things that work today but have a documented edge case, or are deferred behind an upstream dependency:

- **TrueHD-MAT Atmos object metadata is not preserved.** TrueHD / MLP sources route through the AudioBridge (FFmpeg's EAC3 encoder doesn't produce JOC, which is the Dolby-licensed Atmos-in-EAC3 extension). Bed channels and surround layout survive; object metadata is dropped. EAC3+JOC stream-copy from MKV / MP4 sources is intact.
- **`.surroundCompat` audio bridge caps 7.1 sources to 5.1.** FFmpeg's EAC3 encoder currently caps at 6 channels. Once [FFmpeg PR 21668](https://github.com/FFmpeg/FFmpeg/pull/21668) lands the cap and the dynamic bitrate auto-scale to 1024 kbps engage without a code change here. Use `.lossless` (FLAC) today if 7.1 matters.
- **Manual `MPNowPlayingInfoCenter` writes race the HLS-loopback path on tvOS 26.** The combination produces a `libdispatch` race. Only `AVPlayerViewController` with its standard transport bar safely surfaces Now Playing. Hosts that need a custom transport should use `MPNowPlayingSession` against the engine's `currentAVPlayer` publisher instead of `MPNowPlayingInfoCenter.default().nowPlayingInfo`.
- **HDMI route reports ch=2 → multichannel plays as stereo.** When the sink reports a 2-channel audio route (`AVAudioSession.outputNumberOfChannels == 2`), all non-Atmos multichannel material downmixes to stereo. This is a sink-side issue (some AVRs cache HDMI EDID incorrectly after standby). Power-cycling the sink restores the correct route. Atmos passthrough still works on these routes because EAC3+JOC ships as MAT 2.0 over a 2-channel carrier.
- **Live MPEG-TS sliding-window segment eviction is not yet implemented.** `LoadOptions.isLive` enables the scaffold (no-op seek, `@Published isLive`), but long-running live sessions on the native AVPlayer path accumulate cached segments. Live VOD playback works; multi-hour IPTV / broadcaster feeds will grow memory until the source ends.
- **AV1 on Apple TV is software-decoded.** No current Apple TV chip ships HW AV1. The `SoftwarePlaybackHost` + dav1d path handles it, but CPU use is meaningfully higher than HW HEVC. On iOS 17+ / macOS 14+ AV1 routes through Apple's HW pipeline transparently. Future Apple TV chips with HW AV1 will be picked up automatically by `VTCapabilityProbe`.
- **AV1 Dolby Vision Profile 10.0 has wrong colours when software-decoded.** dav1d / libavcodec cannot decode the proprietary DV colour space, so a Profile 10.0 source (DV-only, no fallback base layer) renders with incorrect colours on the SW path. Profiles 10.1 and 10.4 are unaffected because they carry an HDR10 / HLG base layer that the decoder reads correctly. Profile 10.0 only renders correctly through the native AVPlayer path on hosts with HW AV1 decode (M3+ Mac, iPhone 15 Pro+, future Apple TV chips); on software-decode hosts (all current Apple TVs) it is a known colour limitation.
- **Dolby Vision Profile 5 thumbnails (FrameExtractor) have wrong colours.** `FrameExtractor` tone-maps HDR10 / HLG / DV P8.x stills correctly via its zscale + tonemap path, but DV Profile 5 is IPT-PQ with no HDR10 base layer, so the software decode the extractor uses cannot resolve its colour space (same root cause as the AV1 Profile 10.0 limitation above). Full playback of P5 is unaffected: it routes through the native AVPlayer path, which engages the display's DV pipeline.

## Stability and versioning

AetherEngine uses [Semantic Versioning](https://semver.org). The public API surface — every `public` declaration in `Sources/AetherEngine/` — is the stability contract:

- **Major (`X.0.0`)**: removes or renames public symbols, changes method signatures, changes default behaviour in a way that breaks adopters.
- **Minor (`X.Y.0`)**: adds public API, adds codec / format support, fixes behaviour that adopters could not reasonably have depended on.
- **Patch (`X.Y.Z`)**: fixes bugs and reliability issues. No public API changes.

`internal` types and properties are not part of the contract and may change in any release. `@testable import AetherEngine` reaches them for the package's own tests, not for production use.

Pin `from: "2.0.0"` in your `Package.swift` to allow patch + minor updates while excluding breaking changes:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "2.0.0")
```

Pin to `.upToNextMinor(from: "2.0.0")` for stricter teams that prefer to opt into minor bumps explicitly. See [CHANGELOG.md](CHANGELOG.md) for the per-release index.

## Requirements

| | Min |
| --- | --- |
| iOS | 16.0 |
| tvOS | 16.0 |
| macOS | 14.0 |
| Swift | 6.0 |
| Xcode | 16.0 |

## Support

If the engine is useful to you and you'd like to support its development, there's a [Ko-fi](https://ko-fi.com/superuser404).

## Built with

AetherEngine is vibe-coded, designed and shipped by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.

## Testing and feedback

Big thanks to [@DrHurt](https://github.com/DrHurt) for the relentless on-device DV / HDR matrix testing in [#4](https://github.com/superuser404notfound/AetherEngine/issues/4). The empirical builds 159-172 sweeps across panel modes (SDR / HDR10 / DV) cross-matched with Match Content states exposed the timing race in `DisplayCriteriaController.waitForSwitch` that the 1.4.0 two-stage poll now fixes.

## License

[LGPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause grants explicit permission to distribute through application stores (Apple App Store, TestFlight, etc.) whose terms otherwise conflict with LGPL §4–6. Modifications to the engine itself still have to be released under LGPL.
