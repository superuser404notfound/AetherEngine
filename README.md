<p align="center">
  <img src=".github/aetherengine-logo.png" alt="AetherEngine" width="180">
</p>

<h1 align="center">AetherEngine</h1>

<p align="center">
  <b>A media player engine for Apple platforms.</b><br>
  FFmpeg demuxes. VideoToolbox decodes. AVPlayer handles Dolby Atmos.<br>
  Video, live TV with DVR timeshift, or a lean audio-only path with system Now-Playing. You ship the UI.
</p>

<p align="center">
  <a href="https://github.com/superuser404notfound/AetherEngine/releases/latest"><img src="https://img.shields.io/github/v/release/superuser404notfound/AetherEngine?label=release&color=blue"></a>
  <a href="https://github.com/superuser404notfound/AetherEngine/actions/workflows/ci.yml"><img src="https://github.com/superuser404notfound/AetherEngine/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/AetherEngine"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FAetherEngine%2Fbadge%3Ftype%3Dswift-versions"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/AetherEngine"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FAetherEngine%2Fbadge%3Ftype%3Dplatforms"></a>
  <img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white">
  <img src="https://img.shields.io/badge/license-LGPL--3.0%20%2B%20App%20Store%20Exception-lightgrey">
  <a href="https://aetherengine.superuser404.de"><img src="https://img.shields.io/badge/docs-aetherengine.superuser404.de-4a6eff"></a>
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

---

## What it is

A player engine that gets the hard parts right (HDR, Dolby Vision, Dolby Atmos, container coverage, codec coverage) and exposes a single `AetherPlayerView` (UIKit / AppKit) or `AetherPlayerSurface` (SwiftUI) plus a handful of `async` methods. No `AVPlayerViewController`. No opinionated controls. No analytics. Bind the view, call `play()`, read the published properties for state.

The view is polymorphic: under the hood the engine swaps the hosted CALayer (`AVPlayerLayer` for the native AVPlayer path, `AVSampleBufferDisplayLayer` for the SW dav1d fallback path) per session without the host having to know.

You provide the transport bar. You provide the dropdowns. You provide the pretty.

## What it handles

A scannable summary; the depth for each row lives in **[docs/formats.md](docs/formats.md)**.

| Area | Summary |
| --- | --- |
| Containers | MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV |
| Disc | DVD-Video and Blu-ray ISO (decrypted): selectable titles and chapters, demuxed through the normal path |
| Video (HW) | H.264, HEVC, HEVC Main10 via VideoToolbox; AV1 where HW AV1 exists |
| Video (SW) | AV1 (dav1d) without HW, VP9 / VP8, MPEG-4 Part 2 / MPEG-2 / VC-1, H.264 High 4:2:2 / 4:4:4 / 10 and HEVC Rext where VideoToolbox has no HW decoder (Intel Macs, older chips), interlaced H.264 (AVPlayer does not deinterlace); GPU deinterlace (yadif_videotoolbox, Metal, field-rate by default) with a CPU bwdif fallback |
| HDR | HDR10, HDR10+ (per-frame ST 2094-40), Dolby Vision (P5, P7 as single-layer 8.1, P8.1, P8.4, AV1 P10.x), HLG |
| Audio | AAC, AC3, EAC3, FLAC, ALAC stream-copy lossless; TrueHD / DTS / DTS-HD MA / MP3 / Opus bridge to EAC3 5.1 (default) or lossless FLAC |
| Dolby Atmos | EAC3+JOC stream-copied on every route (HDMI MAT 2.0, AirPods spatial, BT downmix) |
| Surround | 5.1 / 7.1 with correct `AudioChannelLayout` |
| Audio-only | `LoadOptions.audioOnly`: lean pipeline, no video machinery, system Now-Playing on tvOS / iOS |
| Background audio | Audio keeps playing when the app backgrounds on iOS: native AVPlayer stays alive, the software path drops video and keeps decoding audio (`backgroundPlaybackEnabled` / `pictureInPictureActive`); a paused session survives quick app switches for a grace window (`backgroundTeardownGraceSeconds`, default 15 s) before the wedge-safe teardown runs. tvOS tears down immediately (wedge-safe) unless a PiP window is active, which keeps the pipeline and loopback server alive; with PiP the software path keeps decoding video too (the window needs frames). Hosts gate corrective actions on the published `isSessionReady` |
| Picture in Picture | Native path: hosts build `AVPictureInPictureController` around `currentAVPlayer`; while `pictureInPictureActive` a native->native load hands the AVPlayerItem over in place so the window survives next-episode transitions. Software path: published `softwarePiPSource` carries the `AVSampleBufferDisplayLayer` plus transport answers on the enqueued frames' PTS axis for sample-buffer PiP. While PiP is active the software path also composites active subtitle cues (text and PGS/DVB bitmaps) into the decoded frames, so the window shows subtitles the host overlay cannot reach. iOS renders sample-buffer PiP; tvOS AVKit does not evaluate sample-buffer content sources (Apple FB9751461, verified through tvOS 26) |
| Subtitles | Text (SRT / ASS / SSA / VTT / mov_text) inline, bitmap (PGS / DVB / DVD) as `CGImage`, in-band CEA-608 closed captions (field-1, from an `eia_608`/`c608` demuxable track or extracted from A53 `cc_data` embedded in the video bitstream: H.264/HEVC SEI on the native path, decoded-frame side data such as MPEG-2 on the software path, with the caption track surfacing lazily on first real caption data), DVB teletext decoded to text cues with broadcaster colour preserved and a selectable caption page (libzvbi, `LoadOptions.teletextPage`), external files as first-class tracks (registered, listed, selected like embedded streams), opt-in raw ASS markup + fonts; embedded-text cues harvested from the producer's own read (instant enable, no side-channel bandwidth); opt-in native WebVTT renditions (one per text track incl. load-declared external files, language-tagged) so subtitles survive PiP / AirPlay / external display (`LoadOptions.prepareNativeSubtitles`) |
| Frames | Off-playback `FrameExtractor`: `thumbnail` (scrub preview) + `snapshot` (frame-accurate) |
| Audio tap | Opt-in `installAudioTap()`: decoded playback audio as mono Float32 48 kHz PCM with source-PTS timestamps, off the render path (live transcription, ShazamKit); delivers on the loopback, remote-HLS (VOD + live), and software paths |
| Metadata | `MediaMetadata` (title / artist / album / albumArtist + cover) parsed on load |
| Seek | VOD seeks into watched content are restart-free cache hits (byte-budgeted retention, 2 GiB cap); short forward scrubs ride the cached window; only never-produced targets restart the producer |
| Streaming | One long-lived forward-streaming connection, reconnect-on-drop; CDN-stutter resilient; optional caller-bounded open-time probe budget (`LoadOptions.probesize` / `maxAnalyzeDuration`) to cut first-frame latency on sparse remote remuxes; configurable forward-buffer window (`LoadOptions.forwardBufferSegments`) |
| Live / DVR | Unbounded live + optional timeshift; direct HLS ingest with AES-128 clear-key and SSAI ad-pod handling |
| Custom input | Play any byte source via the `IOReader` protocol (`load(source:)`) |
| Network | SMB2/3 shares via the optional `AetherEngineSMB` product (NTLMv2 / guest, read-only) |

## How it compares

On Apple platforms the real choice is between AVPlayer, with deep OS integration but only the formats Apple ships, and a VLC- or mpv-derived engine, which plays almost anything but renders its own frames and bypasses the system's Dolby Vision, Atmos, and HDR handling. AetherEngine is built to give you both: FFmpeg's format breadth layered on top of VideoToolbox and AVPlayer, so Dolby Vision, Atmos, and Match Content keep working. KSPlayer is the closest analog, it reaches the same outcome through the same AVPlayer route, but it ships as a full player with its own UI and gates MKV, Dolby Vision, and Atmos behind a paid LGPL tier (the free build is GPL); AetherEngine is an embeddable engine you drive from your own SwiftUI, with that codec and HDR breadth in the open-source core.

| | AetherEngine | KSPlayer | AVPlayer | VLCKit | libmpv |
| --- | --- | --- | --- | --- | --- |
| **Approach** | Embeddable engine, Apple-only | Full player with bundled UI, FFmpeg + AVPlayer, Apple-only | Apple's built-in player | libVLC wrapped for Apple | libmpv, cross-platform |
| **Container & codec breadth** | Wide, FFmpeg demux | Wide, FFmpeg demux | Narrow, Apple's set | Wide | Wide |
| **Hardware decode** | VideoToolbox, dav1d SW fallback | VideoToolbox, FFmpeg SW fallback | VideoToolbox | VideoToolbox plus software | VideoToolbox plus software |
| **Dolby Vision** | P5, P7 as 8.1, P8.1, P8.4, AV1 P10.x, real display switch | P5, P8 via AVPlayer, paid LGPL tier | P5 and P8.1 only | Tone-maps, no DV display | Tone-maps, no DV display |
| **Dolby Atmos** | EAC3+JOC stream-copied (HDMI MAT, spatial) | EAC3+JOC via AVPlayer, paid LGPL tier | EAC3+JOC passthrough | Decodes to PCM, no object passthrough | No Atmos passthrough on Apple |
| **HDR on tvOS** | Native Match Content switch | Native Match Content on AVPlayer path, else Metal tone-map | Native Match Content | Software tone-mapping | Software tone-mapping |
| **Rendering & UI** | OS-native, you ship SwiftUI | Own Metal renderer, bundled controls | OS-native, you ship UI | Own renderer, bundled controls | Own renderer, bundled OSC |
| **Apple TV / App Store** | Yes, LGPL plus store exception | Free tier GPL, DV / Atmos / MKV need paid LGPL | Yes | Yes, LGPL | Not practical, GPL, no tvOS |

The engine leans on the platform where the platform is best (hardware decode, Dolby Vision display, Atmos passthrough) and only falls back to its own software path (dav1d, libavcodec) for the formats VideoToolbox cannot handle.

## Quick start

```swift
import AetherEngine
import SwiftUI

let player = try AetherEngine()

// SwiftUI: drop AetherPlayerSurface anywhere in the view tree
var body: some View { AetherPlayerSurface(engine: player) }

// UIKit / AppKit: bind an AetherPlayerView directly
let surface = AetherPlayerView()
player.bind(view: surface)

try await player.load(url: videoURL)                            // or with a resume position
try await player.load(url: videoURL, startPosition: 347.5)
try await player.load(url: videoURL, options: .init(
    httpHeaders: headers,              // attached to every demux + segment fetch
    matchContentEnabled: matchContent  // tvOS Match Content master toggle
))
try await player.reloadAtCurrentPosition()                      // background reopen, preserves options
try await player.load(url: trackURL, options: .init(audioOnly: true))   // lean audio path

// Transport
player.play()
player.pause()
player.togglePlayPause()
player.setRate(1.5)                    // clamped to player.maxSupportedRate (2x video, 3x audio-only)
await player.seek(to: 120)
player.stop()

// State (Combine @Published)
player.$state          // .idle, .loading, .playing, .paused, .seeking, .ended, .error
                       // .ended = played to completion (any backend); .idle = pre-load / stopped
player.$duration
player.$videoFormat    // .sdr, .hdr10, .hdr10Plus, .dolbyVision, .hlg
player.$isSeeking      // true until a seek physically lands (programmatic + native scrubs)
player.$seekTarget     // in-flight seek destination (source-PTS), nil otherwise
player.$playbackPhase  // unified: .idle/.loading/.playing/.paused/.seeking/.rebuffering/
                       // .stalled(reconnecting:)/.ended/.error. One source of truth for a status
                       // spinner; derived from state + isBuffering + isSeeking + source reconnect.
                       // Prefer this over stitching the raw signals or matching EngineLog text.
player.$currentAVPlayer // active AVPlayer, re-emitted on every reload (MPNowPlayingSession)

// Time lives on player.clock, a SEPARATE ObservableObject, so the ~10 Hz
// ticks never fire objectWillChange on the engine (track lists / state views
// don't re-render per tick; native tvOS Menu dropdowns stay stable).
player.clock.$currentTime      // ~10 Hz playback clock (transport / scrub / resume)
player.clock.$sourceTime       // source PTS of the displayed frame (render subtitles against this)
player.clock.$bufferedPosition // source-axis position buffered ahead; draw a buffer bar as bufferedPosition / duration

// Tracks
player.audioTracks                             // [TrackInfo]
player.selectAudioTrack(index: trackID)
player.subtitleTracks                          // [TrackInfo], text + bitmap + external, one list
player.selectSubtitleTrack(index: streamID)
player.clearSubtitle()
player.$subtitleCues                           // [SubtitleCue]: .text(String), .richText([SubtitleTextRun]) (coloured teletext), or .image(SubtitleImage)

// External subtitle files are first-class tracks (#88): they appear in subtitleTracks
// (isExternal == true, synthetic id) and select through the same call as embedded streams.
let track = player.addExternalSubtitleTrack(
    ExternalSubtitleTrack(url: srtURL, name: "English", language: "en"))
player.selectSubtitleTrack(index: track.id)
// Declared at load instead, external tracks also join the native WebVTT renditions (PiP):
// LoadOptions(prepareNativeSubtitles: true, externalSubtitles: [ExternalSubtitleTrack(url: srtURL, language: "en")])

// Native WebVTT subtitle renditions (subtitles in PiP / AirPlay / external display; opt-in
// via LoadOptions.prepareNativeSubtitles, details in docs/formats.md)
player.$nativeSubtitleTracks                   // [NativeSubtitleTrack]: ordinal, language, displayName
player.setNativeSubtitleSelected(track: 2)     // engage a rendition (e.g. on PiP entry); nil deselects

// Second simultaneous subtitle track (bilingual / language learning)
player.selectSecondarySubtitleTrack(index: streamID)
player.selectSecondarySidecarSubtitle(url: srt2URL)
player.clearSecondarySubtitle()
player.$secondarySubtitleCues                  // [SubtitleCue] for the secondary track
player.$isSecondarySubtitleActive             // Bool

// Disc titles + chapters (DVD-Video / Blu-ray ISO; empty for non-disc sources)
player.$discTitles                             // [TitleInfo]: id, name, durationSeconds, chapterCount (longest first, id 0 is the main feature)
player.$selectedDiscTitle                      // TitleInfo?
player.selectTitle(id: titleID)                // switch title (rebuilds from the new title's head)
player.$discChapters                           // [ChapterInfo] for the selected title
player.selectChapter(id: chapterID)            // seek to a chapter

// Info panel / Now Playing (iOS / tvOS)
player.setExternalMetadata([ AVMetadataItem(/* title, artwork, etc. */) ])
```

Subtitle cues land in raw source PTS; render the overlay against `player.sourceTime` (see [docs/formats.md › Subtitles](docs/formats.md#subtitles)). The 1 Hz diagnostics snapshot lives on `player.diagnostics.liveTelemetry`, off-the-engine for the same render-stability reason. Frame extraction, authored-ASS styling, and the full published surface are documented in [docs/formats.md](docs/formats.md).

Install via Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "5.8.6")
```

Two complementary samples ship in `Examples/`:

- [`MinimalPlayer/`](Examples/MinimalPlayer/MinimalPlayerApp.swift): a 90-line SwiftUI drop-in. Copy the file into a new tvOS / iOS / macOS app, point at a URL, run.
- [`DemoPlayerMac/`](Examples/DemoPlayerMac/README.md): a standalone macOS app for testers. Drop a file on the window, it plays. A notarized universal `.dmg` is attached to every [GitHub Release](https://github.com/superuser404notfound/AetherEngine/releases/latest).

### Custom input source

```swift
final class MyArchiveReader: IOReader {
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { /* ... */ }
    func seek(offset: Int64, whence: Int32) -> Int64 { /* ... */ }  // AVSEEK_SIZE (65536) returns total size
    func close() { /* ... */ }

    // Optional (both have defaults). Override to unlock extra features:
    func cancel() { /* unblock a blocked read at teardown, do NOT invalidate the reader */ }
    func makeIndependentReader() -> IOReader? { /* a fresh cursor over the same source, or nil */ }
}

let probe = try await engine.load(source: .custom(MyArchiveReader(), formatHint: "mp4"))
// load() returns the probe metadata it gathered (discardable). A one-shot
// AetherEngine.probe(source:) without starting playback works too.
```

Seekable readers support audio-track switching and background reload; embedded subtitles and scrub-preview thumbnails additionally need `makeIndependentReader()` (a second cursor). Forward-only readers support plain playback + seeking (VOD on the software path; live sessions stay native). On the native path a custom reader's bytes are re-muxed to cleartext fMP4 on the loopback cache, fine for encrypted-at-rest archives, a cleartext exposure for content-protected sources. Full contract in [docs/formats.md](docs/formats.md).

#### SMB shares (optional `AetherEngineSMB` product)

Playing media off an SMB2/3 share is a ready-made `IOReader`, shipped as a separate product so the SMB dependency ([SMBClient](https://github.com/kishikawakatsumi/SMBClient), MIT, pure Swift, `NWConnection`-based) only enters consumers that opt in. Add the `AetherEngineSMB` product alongside `AetherEngine`; hosts that do not need SMB link only the core. The transport is pure Swift over Network.framework rather than libsmb2, which fails with `EPERM` on tvOS/iOS.

```swift
import AetherEngineSMB

let smb = try await SMBConnection.connect(
    server: URL(string: "smb://nas.local")!, share: "media",
    path: "Movies/film.mkv", user: "alice", password: "s3cret"
)
try await engine.load(source: .custom(SMBIOReader(source: smb), formatHint: "matroska"))
```

Read-only, NTLMv2 / guest auth (no Kerberos). On tvOS the host must declare `NSLocalNetworkUsageDescription` + the local-network entitlement to reach a LAN share. See [`aetherctl smbtest`](docs/cli.md#smbtest) to validate a share from macOS.

Known limitation: SMBClient negotiates only SMB 2.0.2 and 2.1, so there is no SMB3 transport encryption or AES-CMAC signing. Servers configured SMB3-only or with `smb encrypt = required` won't connect (libsmb2 spoke 3.1.1 here, but was itself unusable on tvOS/iOS, see above).

### Live TV / DVR

```swift
// Live-only (seek() is a no-op), or live + timeshift:
try await player.load(url: streamURL, options: LoadOptions(isLive: true))
try await player.load(url: streamURL, options: LoadOptions(isLive: true, dvrWindowSeconds: 1800))

// Drive a scrubber from the live-edge fields (they tick, so they live on player.clock):
player.clock.$seekableLiveRange   // ClosedRange<Double>?, session-relative; nil when DVR off
player.clock.$behindLiveSeconds   // seconds behind the edge; 0 at the edge
player.clock.$liveEdgeTime
await player.seekToLiveEdge()
await player.seek(to: player.liveEdgeTime - 300)   // 5 minutes back

// Ingest a live HLS upstream directly, no media server in the data path:
try await player.load(
    source: .custom(HLSLiveIngestReader(playlistURL: upstreamM3U8), formatHint: "mpegts"),
    options: LoadOptions(isLive: true, dvrWindowSeconds: 600)
)
```

Direct ingest covers MPEG-TS with demuxed-audio and packed-audio renditions, in-line AES-128 clear-key decryption, and SSAI ad-pod direct play (versioned init segments, audio re-anchoring, no-cut watchdog). Unsupported encryption / fMP4 playlists surface a typed `HLSIngestError` so the host can fall back. Details in [docs/formats.md › Live ingest](docs/formats.md#live-ingest-aes-128-ssai).

For an upstream AVPlayer can play natively (a standard remote `master.m3u8`, e.g. a Jellyfin live channel), `LoadOptions.nativeRemoteHLS` skips the demuxer probe and the loopback server entirely and hands the URL straight to AVPlayer, which manages the live edge and reconnect itself. Pair it with `isLive: true`. `LoadOptions.httpHeaders` rides into the `AVURLAsset` on this path, so origins that enforce per-stream `Referer` / `User-Agent` / `Authorization` headers (common for IPTV channels) work too.

A non-live remote `m3u8` handed to the default (loopback) path reroutes onto this bypass automatically: the bundled FFmpeg is built without network support, so the playlist can never be demuxed locally, and remote HLS is AVPlayer's native domain anyway (#154). On the bypass the engine surfaces the stream's external WebVTT subtitle renditions (the legible `AVMediaSelectionGroup`) as `subtitleTracks`; `selectSubtitleTrack(index:)` and `clearSubtitle()` drive AVPlayer's media selection, and AVPlayer renders the cues itself.

## Used by

<!-- used-by:start -->
- [Sodalite](https://github.com/superuser404notfound/Sodalite): native Jellyfin client for Apple TV.
- [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer): native macOS media player.
<!-- used-by:end -->

Shipping something on AetherEngine? [Submit it](https://github.com/superuser404notfound/AetherEngine/issues/new?template=used-by-submission.yml) to get listed.

## Host setup on tvOS

For HDR / Dolby Vision sources to play reliably on tvOS 26.5+, the engine must drive `AVDisplayManager.preferredDisplayCriteria` itself (synchronously, before the AVPlayerItem assignment). Apple Tech Talk 503 has prescribed this ordering since 2017, and tvOS 26.5 now enforces it synchronously at HLS variant validation: the validator rejects variants whose `VIDEO-RANGE` the panel can't currently host with `AVFoundationErrorDomain -11868`, before fetching the `EXT-X-MAP` init segment, producing `item.status = .failed` with zero `errorLog().events`. SDR variants are unaffected.

AVKit-auto criteria (`appliesPreferredDisplayCriteriaAutomatically = true`) cannot satisfy this for HLS multivariant HDR sources, because AVKit reads criteria from `AVAsset.preferredDisplayCriteria`, which is synthesized from the chosen variant's format description, which only exists after `init.mp4` is parsed, which only happens after the variant passes the validator. Chicken-and-egg. Engine-driven sole-writer is the working pattern:

```swift
// In your AVPlayerViewController subclass
playerVC.appliesPreferredDisplayCriteriaAutomatically = false

// When loading
try await engine.load(url: url, options: LoadOptions(
    suppressDisplayCriteria: false,      // default; engine writes criteria
    matchContentEnabled: matchContent,   // tvOS Match Content master toggle
    panelIsInHDRMode: panelInHDRMode     // current EDR-headroom > 1.0
))
```

`suppressDisplayCriteria` defaults to `false`, so the engine-driven path is the default: `apply()` runs synchronously inside `load(url:)`, `waitForSwitch` blocks until the panel reaches the target mode (or 5 s timeout), then `replaceCurrentItem` runs against an already-correct panel.

**Handoffs between items:** back-to-back `load()` calls preserve the applied criteria across the seam, so a same-mode follow-up (Dolby Vision episode to Dolby Vision episode) overwrites it in place with a single handshake instead of bouncing the panel through SDR. If your host calls `stop()` between items, pass `stop(resetDisplayCriteria: false)` to get the same behavior ([#128](https://github.com/superuser404notfound/AetherEngine/pull/128)); the plain `stop()` returns the panel to its default mode, which is what you want when leaving playback for the app UI. Audio-only sessions and suppressed hosts clear a leftover criteria automatically.

> **Custom chrome with a SwiftUI `Menu`?** On tvOS 26 an open `Menu`'s focused row blinks on any render transaction in the tree. Build the menu button in UIKit (`UIButton.menu` + `showsMenuAsPrimaryAction`) and guard `updateUIView` so the open dropdown never rebuilds. Pattern in [docs/architecture.md › SwiftUI Menu](docs/architecture.md#swiftui-menu-in-custom-player-chrome).

## Non-goals

Things AetherEngine deliberately doesn't do, so you don't have to read the source to find out:

- No built-in UI: no controls, transport bar, or HUD.
- No external analytics or session reporting. A 1 Hz `engine.diagnostics.liveTelemetry` surface is provided for host UIs that render runtime stats locally; nothing leaves the device.
- No playlist / queue management. Call `load(url:)` for the next one.
- No subtitle overlay. The engine emits `SubtitleCue` (text or `CGImage`); your UI paints them.
- No Metal shaders. Everything renders through Apple's native display stack.
- No third-party networking. `URLSession` handles bytes; TLS / HTTP-3 / proxies / MDM rules ride for free.

## Documentation

Browse all of this as a searchable site at **[aetherengine.superuser404.de](https://aetherengine.superuser404.de)**, or read the source Markdown here:

- **[docs/architecture.md](docs/architecture.md)**: the three playback pipelines, the source-file map, dependencies, the SwiftUI `Menu` pattern.
- **[docs/formats.md](docs/formats.md)**: codec / container coverage, HDR routing, audio bridging, subtitles, frame extraction, disc playback, live ingest, and known limitations.
- **[docs/cli.md](docs/cli.md)**: the `aetherctl` repro CLI (twenty-one subcommands).
- **[CHANGELOG.md](CHANGELOG.md)**: per-release index.

## Stability and versioning

AetherEngine uses [Semantic Versioning](https://semver.org). The public API surface, every `public` declaration in `Sources/AetherEngine/`, is the stability contract. **Major** removes / renames public symbols or breaks adopters; **Minor** adds public API or codec / format support; **Patch** fixes bugs with no public API change. `internal` types are not part of the contract.

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "5.8.6")
```

Pin to `.upToNextMinor(from: "5.8.6")` for stricter teams that prefer to opt into minor bumps explicitly.

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

Big thanks to [@DrHurt](https://github.com/DrHurt) for the relentless on-device DV / HDR matrix testing in [#4](https://github.com/superuser404notfound/AetherEngine/issues/4), which exposed the timing race in `DisplayCriteriaController.waitForSwitch` that the two-stage poll now fixes. Thanks to [@ohjey](https://github.com/ohjey) for the SwiftUI render-storm investigation in [#29](https://github.com/superuser404notfound/AetherEngine/issues/29) that drove the `engine.clock` split and the UIKit menu-button pattern.

## License

[LGPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause grants explicit permission to distribute through application stores (Apple App Store, TestFlight, etc.) whose terms otherwise conflict with LGPL sections 4 to 6. Modifications to the engine itself still have to be released under LGPL.

The exception covers AetherEngine's own code; it does not extend to FFmpeg. FFmpeg reaches your app through [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) as dynamically linked frameworks under plain LGPL-2.1-or-later (no GPL components), which keeps the relink requirement satisfiable for closed-source App Store apps. See FFmpegBuild's README for the per-component licenses and the concrete adopter steps (embed dynamically, ship the license texts, link the build's source).
