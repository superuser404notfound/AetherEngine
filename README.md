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
| Disc | DVD-Video and Blu-ray ISO (decrypted): main title only, demuxed through the normal path |
| Video (HW) | H.264, HEVC, HEVC Main10 via VideoToolbox; AV1 where HW AV1 exists |
| Video (SW) | AV1 (dav1d) without HW, VP9 / VP8, MPEG-4 Part 2 / MPEG-2 / VC-1; bwdif deinterlace |
| HDR | HDR10, HDR10+ (per-frame ST 2094-40), Dolby Vision (P5, P7 as single-layer 8.1, P8.1, P8.4, AV1 P10.x), HLG |
| Audio | AAC, AC3, EAC3, FLAC, ALAC stream-copy lossless; TrueHD / DTS / MP3 / Opus bridge to EAC3 5.1 (default) or lossless FLAC |
| Dolby Atmos | EAC3+JOC stream-copied on every route (HDMI MAT 2.0, AirPods spatial, BT downmix) |
| Surround | 5.1 / 7.1 with correct `AudioChannelLayout` |
| Audio-only | `LoadOptions.audioOnly`: lean pipeline, no video machinery, system Now-Playing on tvOS / iOS |
| Subtitles | Text (SRT / ASS / SSA / VTT / mov_text) inline, bitmap (PGS / DVB / DVD) as `CGImage`, sidecar files, opt-in raw ASS markup + fonts |
| Frames | Off-playback `FrameExtractor`: `thumbnail` (scrub preview) + `snapshot` (frame-accurate) |
| Metadata | `MediaMetadata` (title / artist / album + cover) parsed on load |
| Seek | Producer restart for backward / far-forward; short forward scrubs ride the cached window |
| Streaming | One long-lived forward-streaming connection, reconnect-on-drop; CDN-stutter resilient |
| Live / DVR | Unbounded live + optional timeshift; direct HLS ingest with AES-128 clear-key and SSAI ad-pod handling |
| Custom input | Play any byte source via the `IOReader` protocol (`load(source:)`) |
| Network | SMB2/3 shares via the optional `AetherEngineSMB` product (NTLMv2 / guest, read-only) |

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
player.$state          // .idle, .loading, .playing, .paused, .seeking, .error
player.$duration
player.$videoFormat    // .sdr, .hdr10, .hdr10Plus, .dolbyVision, .hlg
player.$isSeeking      // true until a seek physically lands (programmatic + native scrubs)
player.$seekTarget     // in-flight seek destination (source-PTS), nil otherwise
player.$currentAVPlayer // active AVPlayer, re-emitted on every reload (MPNowPlayingSession)

// Time lives on player.clock, a SEPARATE ObservableObject, so the ~10 Hz
// ticks never fire objectWillChange on the engine (track lists / state views
// don't re-render per tick; native tvOS Menu dropdowns stay stable).
player.clock.$currentTime   // ~10 Hz playback clock (transport / scrub / resume)
player.clock.$sourceTime    // source PTS of the displayed frame (render subtitles against this)

// Tracks
player.audioTracks                             // [TrackInfo]
player.selectAudioTrack(index: trackID)
player.subtitleTracks                          // [TrackInfo], text + bitmap, one list
player.selectSubtitleTrack(index: streamID)
player.selectSidecarSubtitle(url: srtURL)      // .srt / .ass / .vtt next to the media
player.clearSubtitle()
player.$subtitleCues                           // [SubtitleCue]: .text(String) or .image(SubtitleImage)

// Info panel / Now Playing (iOS / tvOS)
player.setExternalMetadata([ AVMetadataItem(/* title, artwork, etc. */) ])
```

Subtitle cues land in raw source PTS; render the overlay against `player.sourceTime` (see [docs/formats.md › Subtitles](docs/formats.md#subtitles)). The 1 Hz diagnostics snapshot lives on `player.diagnostics.liveTelemetry`, off-the-engine for the same render-stability reason. Frame extraction, authored-ASS styling, and the full published surface are documented in [docs/formats.md](docs/formats.md).

Install via Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "3.10.0")
```

Two complementary samples ship in `Examples/`:

- [`MinimalPlayer/`](Examples/MinimalPlayer/MinimalPlayerApp.swift) — 90-line SwiftUI drop-in. Copy the file into a new tvOS / iOS / macOS app, point at a URL, run.
- [`DemoPlayerMac/`](Examples/DemoPlayerMac/README.md) — standalone macOS app for testers. Drop a file on the window, it plays. A notarized universal `.dmg` is attached to every [GitHub Release](https://github.com/superuser404notfound/AetherEngine/releases/latest).

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

Playing media off an SMB2/3 share is a ready-made `IOReader`, shipped as a separate product so the SMB dependency ([AMSMB2](https://github.com/amosavian/AMSMB2), LGPL-2.1) only enters consumers that opt in. Add the `AetherEngineSMB` product alongside `AetherEngine`; hosts that do not need SMB link only the core and never pull libsmb2.

```swift
import AetherEngineSMB

let smb = try await SMBConnection.connect(
    server: URL(string: "smb://nas.local")!, share: "media",
    path: "Movies/film.mkv", user: "alice", password: "s3cret"
)
try await engine.load(source: .custom(SMBIOReader(source: smb), formatHint: "matroska"))
```

Read-only, NTLMv2 / guest auth (no Kerberos). On tvOS the host must declare `NSLocalNetworkUsageDescription` + the local-network entitlement to reach a LAN share. See [`aetherctl smbtest`](docs/cli.md#smbtest) to validate a share from macOS.

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

- **[docs/architecture.md](docs/architecture.md)** — the three playback pipelines, the source-file map, dependencies, the SwiftUI `Menu` pattern.
- **[docs/formats.md](docs/formats.md)** — codec / container coverage, HDR routing, audio bridging, subtitles, frame extraction, disc playback, live ingest, and known limitations.
- **[docs/cli.md](docs/cli.md)** — the `aetherctl` repro CLI (twelve subcommands).
- **[CHANGELOG.md](CHANGELOG.md)** — per-release index.

## Stability and versioning

AetherEngine uses [Semantic Versioning](https://semver.org). The public API surface — every `public` declaration in `Sources/AetherEngine/` — is the stability contract. **Major** removes / renames public symbols or breaks adopters; **Minor** adds public API or codec / format support; **Patch** fixes bugs with no public API change. `internal` types are not part of the contract.

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "3.10.0")
```

Pin to `.upToNextMinor(from: "3.10.0")` for stricter teams that prefer to opt into minor bumps explicitly.

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

[LGPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause grants explicit permission to distribute through application stores (Apple App Store, TestFlight, etc.) whose terms otherwise conflict with LGPL §4–6. Modifications to the engine itself still have to be released under LGPL.
