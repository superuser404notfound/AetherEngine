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

| Area        | Details                                                                                                                     |
| ----------- | --------------------------------------------------------------------------------------------------------------------------- |
| Containers  | MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV (demux side)                                                                         |
| Disc        | DVD-Video ISO (decrypted): reads the ISO9660 bridge filesystem, selects the longest title set, and demuxes its concatenated VOBs as MPEG-PS through the normal decode path. Blu-ray ISO (decrypted) also plays: a read-only UDF 2.50 reader resolves BDMV (including the metadata partition and fragmented files), the longest `.mpls` playlist selects the main title, and its `.m2ts` clips are concatenated and demuxed as MPEG-TS. Both: no decryption (CSS / AACS retail discs must be ripped decrypted first), no menus / multi-angle, main title only |
| HW decode   | H.264, HEVC, HEVC Main10 via VideoToolbox in AVPlayer's HLS-fMP4 path. AV1 on devices with HW AV1 (M3+ Mac, iPhone 15 Pro+, future Apple TV chips) also routes natively |
| SW decode   | AV1 (libavcodec/dav1d) on devices without HW AV1 — currently all Apple TVs, M1/M2 Macs, pre-A17-Pro iPhones. VP9 and VP8 (libavcodec native) unconditionally, since AVPlayer's HLS pipeline rejects the `vp09` / `vp08` CODECS attributes even where VT can HW-decode them. MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, and VC-1 also route SW since AVPlayer's HLS-fMP4 pipeline does not accept them; libavcodec ships native decoders for all three. All render through `SoftwareVideoDecoder` + `AVSampleBufferDisplayLayer`; interlaced sources (DVD-rip MPEG-2, SD broadcast) are deinterlaced through a persistent bwdif graph (yadif fallback) that engages on the first interlaced frame and costs nothing on progressive content. Dispatch decision lives in `AetherEngine.load`, gated per source on `VTCapabilityProbe` and codec id |
| HDR10       | BT.2020 + PQ signaled via the HLS-fMP4 wrapper; AVPlayer hands the bitstream to the system HDR pipeline                     |
| HDR10+      | Per-frame ST 2094-40 dynamic metadata preserved through stream-copy into the HLS-fMP4 wrapper                               |
| Dolby Vision| HEVC P5 / P8.1 / P8.4 with `dvh1` / `hvc1` track type + `dvcC` box. AV1 P10.0 / P10.1 / P10.4 with `dav1` / `av01` track type + `dvvC` box (per Apple HLS Authoring Spec + Dolby ETSI TS 103 572). Both engage the tvOS HDMI DV handshake on DV-capable displays |
| HLG         | Transfer function detected and signaled                                                                                     |
| HDR to SDR  | Handled by AVPlayer / system compositor based on the connected display; no host-side tonemap                                |
| Audio       | AAC, AC3, EAC3, FLAC, MP2, MP3, Opus, Vorbis, TrueHD, MLP, DTS, DTS-HD MA, ALAC, PCM. Codecs that stream-copy into fMP4 (AAC-LC, AC3, EAC3, FLAC, ALAC) pass through losslessly; HE-AAC / HE-AACv2 also stream-copy when the source carries an AudioSpecificConfig (any movie container), and route through the bridge only without one (live ADTS / MPEG-TS, where a synthesized ASC would mis-signal the SBR payload). LATM/LOAS-framed AAC (DVB broadcast framing) always bridges. Non-streamable codecs route through `AudioBridge` in one of two modes (`AudioBridgeMode`): `.surroundCompat` (default, EAC3 at 128 kbps per channel — 256 kbps stereo, 768 kbps 5.1 — lossy but surround works on every modern soundbar via the bitstream tunnel) or `.lossless` (FLAC up to 7.1, lossless, needs an AVR that accepts multichannel LPCM over HDMI). |
| Dolby Atmos | EAC3+JOC stream-copied through the HLS-fMP4 wrapper on every output route: AVPlayer unwraps Dolby MAT 2.0 over HDMI, renders spatially on AirPods, and downmixes natively on plain Bluetooth (no re-encode for a route reason). TrueHD-MAT object metadata is not preserved through the bridge in either mode (FFmpeg's EAC3 encoder doesn't produce JOC, which is the Dolby-licensed Atmos-in-EAC3 extension).        |
| Surround    | 5.1 / 7.1 with correct `AudioChannelLayout` preserved through the wrapper                                                   |
| Audio-only  | `LoadOptions.audioOnly` routes a source into a lean audio pipeline (no loopback server, no display layer, no video producer). Native-first: whitelisted codecs hand the URL straight to a bare `AVPlayer`, the rest decode through FFmpeg into `AVSampleBufferAudioRenderer`. Persistent per-player `MPNowPlayingSession` on tvOS / iOS keeps the system Now-Playing overlay live across a background pause |
| Subtitles   | SubRip / ASS / SSA / WebVTT / mov_text streamed inline; PGS / HDMV PGS / DVB / DVD rendered as `CGImage` with normalised position; sidecar `.srt` / `.ass` / `.vtt` URLs decoded via short-lived context, with custom HTTP headers (session headers forwarded by default) for authenticated hosts. Opt-in raw ASS markup + script header + embedded font attachments for host-side styled rendering (`preserveASSMarkup`, `ASSScriptBuilder`, `fontAttachments`) |
| Frames      | Still-image extraction off-playback via `FrameExtractor`: `thumbnail` (nearest keyframe, downscaled, fast, for scrub previews / Recents) and `snapshot` (frame-accurate, full resolution, for user stills), both as `CGImage`. Isolated FFmpeg decode context, bounded LRU cache, idle-close lifecycle |
| Metadata    | `MediaMetadata` parsed from the container on `load`: normalised title / artist / album / albumArtist tags plus embedded cover art. Published on the engine and carried in `SourceProbe`, so a host gets track info without its own tag parser. `aetherctl probe` prints it |
| Seek        | Producer teardown + restart for backward / far-forward scrubs; short-range forward scrubs ride the cached segment window    |
| Streaming   | Playback reads the source over one long-lived forward-streaming `URLSession` connection (VLC-style): bytes stream into a sliding window, a new request is issued only on a seek outside that window. Still extraction uses discrete Range chunks for random access; live sources ride the same persistent connection (reconnect-capable even without a Content-Length); only non-live sources without a known length fall back to a single sequential GET |
| Live / DVR  | Unbounded live playback with optional in-session timeshift (DVR). `LoadOptions.isLive` opts the session in; `dvrWindowSeconds` (e.g. `1800`) enables rewind. Native path (H.264 / HEVC / AV1-with-HW): a forward-only live producer cuts segments into a sliding HLS playlist served to AVPlayer; timeshift uses AVPlayer's native seekable range. Software path (AV1-without-HW / VP9 / MPEG-2 / VC-1): unbounded live with a disk-spooled `PacketRingBuffer` for rewind. Both paths share a session-relative timeline (seconds since first frame) so a host draws one scrubber regardless of backend. Engine publishes `liveEdgeTime`, `seekableLiveRange`, `isAtLiveEdge`, and `behindLiveSeconds`; `seekToLiveEdge()` snaps to the edge. The live playlist advertises LL-HLS blocking reload (`CAN-BLOCK-RELOAD`) so AVPlayer receives each segment the instant it is cut; broadcast program boundaries (PTS resets, PCR wraps) are rebased onto a continuous output timeline with `#EXT-X-DISCONTINUITY` / `#EXT-X-DISCONTINUITY-SEQUENCE` bookkeeping and A/V-paired shifts; a lost live source (dead tuner, killed transcode) auto-reopens with capped backoff and resumes on the same timeline. Live HLS upstreams can be ingested directly via `HLSLiveIngestReader` (public forward-only `IOReader`): master-playlist variant selection (highest bandwidth), duration-capped live-edge join, sequential segment fetch flattened into one TS stream, in-line AES-128 clear-key decryption, and typed `HLSIngestError`s (unsupported encryption / fMP4 / unreachable / stalled) so hosts can fall back to a server-mediated path. Server-side-ad-inserted (SSAI) ad pods play through the direct path: the producer re-points the video stream on the ad's PID, parses its SPS to rotate the muxer with a versioned `#EXT-X-MAP`, and re-anchors audio per creative boundary, with a read-rate no-cut watchdog as the fall-back net. Demuxed-audio variants (`EXT-X-MEDIA` audio groups) play via a companion rendition reader whose packets merge with the video by DTS, and packed-audio renditions (raw ADTS framed by ID3 timestamps) are wrapped on the fly, so broadcasters like ARD direct-play with sound instead of failing fast; transient playlist-refresh failures retry inside a bounded budget before going terminal. Live reloads (audio-track switch, background return) rejoin at the live edge rather than resuming a stale clock, guarded by a readiness watchdog that fails a wedged rejoin into the host's retune surface; the local playlist adapts `TARGETDURATION` and LL-HLS blocking-reload eligibility to the upstream's real segment cadence, and a terminal ingest loss fires the host retune surface instead of a doomed URL reopen |
| Resilience  | Direct-URL playback survives CDN stutters: a dropped connection, socket stall, or early close reconnects at the last byte delivered instead of ending playback (only the real end of file reports EOF). `429` / `503` honour `Retry-After`, expired signed URLs re-resolve against the source, and a progress-aware cap stops a dead or flapping origin from hammering the CDN. Plus background pause and a display-link aware lifecycle |
| Custom input | Play from any byte source via the `IOReader` protocol, passed as `MediaSource.custom` to `load(source:)`: memory buffers, encrypted-at-rest archives, proprietary containers. Seekable readers work on both the native and software playback paths (forward-only readers: software path for VOD, native loopback for live sessions), with audio-track switching, background reload, embedded subtitles, and scrub preview for readers that vend a second cursor |

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
try await player.load(
    url: trackURL,
    options: .init(audioOnly: true)         // lean audio path, system Now-Playing (tvOS / iOS)
)

player.play()
player.pause()
player.setRate(1.5)
await player.seek(to: 120)
player.stop()

// Observe (Combine @Published)
player.$state         // .idle, .loading, .playing, .paused, .seeking, .error
player.$duration
player.$videoFormat   // .sdr, .hdr10, .hdr10Plus, .dolbyVision, .hlg
player.$currentAVPlayer  // active AVPlayer, re-emitted on every reload (MPNowPlayingSession)

// Time observation lives on `player.clock`, a SEPARATE ObservableObject,
// so the ~10 Hz ticks never fire `objectWillChange` on the engine itself
// (a SwiftUI view observing the engine for track lists / state does not
// re-render per tick; native tvOS Menu dropdowns stay stable). Observe
// the clock only in the leaf views that render time.
player.clock.$currentTime   // ~10 Hz playback clock (transport / scrub / resume)
player.clock.$sourceTime    // source PTS of the displayed frame (subtitle alignment)
player.currentTime          // read-only polling access stays on the engine

// Same split for timer-sampled diagnostics: the 1 Hz telemetry snapshot
// lives on `player.diagnostics`, observed only by stats overlays.
player.diagnostics.$liveTelemetry   // 1 Hz bitrate / buffer / FPS / sync snapshot
player.liveTelemetry                // read-only polling access stays on the engine

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

// ASS / SSA styling: by default the engine strips override tags and
// emits plain text. Hosts that render ASS styling themselves opt into
// raw event lines via LoadOptions(preserveASSMarkup: true) and read
// the track's script header ([Script Info] + [V4+ Styles]) from
// TrackInfo.assHeader to resolve style references.
// ASSScriptBuilder reassembles those raw event lines + assHeader into a
// complete script for whole-file renderers (e.g. swift-ass-renderer's
// loadTrack(content:)), deduped by event content (real files hardcode
// ReadOrder 0); engine.fontAttachments carries the container's embedded
// fonts for the renderer's font dir.

// Still frames, off-playback (scrub preview, snapshot, Recents thumbnail)
let frames = player.makeFrameExtractor()           // for the currently loaded URL, or nil
// or, for an arbitrary item: FrameExtractor(url:httpHeaders:)
await frames?.prewarm()                            // open the decode context ahead of a scrub
let thumb = await frames?.thumbnail(at: 612.0)     // nearest keyframe, downscaled (maxWidth: 320)
let still = await frames?.snapshot(at: 612.0)      // frame-accurate, full resolution
await frames?.shutdown()                           // prompt teardown (else idle-closes after 10 s)
```

Subtitle cues land in raw source PTS. On the native path, AVPlayer's HLS clock sits at `source_pts - producer.videoShiftPts` (the producer applies a per-session shift to align the first segment's tfdt with the playlist origin, and the shift can change on every restart). Render the overlay against `player.sourceTime` so cues match the spoken audio regardless of which producer session is active.

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

try await engine.load(source: .custom(MyArchiveReader(), formatHint: "mp4"))

// load() returns the probe metadata it gathered anyway (discardable):
// video size, codec, duration, tracks, container tags. nil on the
// nativeRemoteHLS bypass or when the probe failed.
let probe = try await engine.load(source: .custom(MyArchiveReader(), formatHint: "mp4"))
probe?.videoWidth   // also live on the engine: engine.sourceVideoWidth / Height

// One-shot probe without starting playback works for custom sources
// too. The caller keeps reader ownership: probe() seeks/reads through
// it and does NOT close() it; hand load() a fresh or rewound reader.
let info = try AetherEngine.probe(source: .custom(MyArchiveReader(), formatHint: "mp4"))
```

> **Security.** On the native path, bytes supplied by a custom `IOReader` are re-muxed to cleartext fMP4 and served via the loopback HLS cache (disk + `127.0.0.1`) to AVPlayer. This is fine for encrypted-at-rest archives (the source is decrypted in memory, never written to disk in original form), but is a cleartext exposure if the source is encrypted for content protection.
>
> **Capability.** Seekable readers support audio-track switching and background
> reload (the pipeline rebuilds on the same reader, so `cancel()` must only
> unblock the in-flight read, never invalidate the reader). Embedded subtitles
> and scrub-preview thumbnails require the reader to implement
> `makeIndependentReader()` (a second independent cursor); they are skipped when
> it returns nil. Forward-only readers support plain playback and seeking only;
> for VOD they run on the software path, while live sessions
> (`LoadOptions.isLive`) keep them eligible for the native loopback path (the
> live producer never seeks the source backward).

### Live TV / DVR

```swift
// Live-only: seek() is a no-op; no rewind.
try await player.load(
    url: streamURL,
    options: LoadOptions(isLive: true)
)

// Live + timeshift (DVR): 30-minute rewind window.
try await player.load(
    url: streamURL,
    options: LoadOptions(isLive: true, dvrWindowSeconds: 1800)
)

// Drive a scrubber from the DVR range and lag indicator. The live-edge
// fields tick continuously, so they live on `player.clock` (see the
// time-observation note above).
player.clock.$seekableLiveRange   // ClosedRange<Double>?, session-relative seconds; nil when DVR off
player.clock.$behindLiveSeconds   // seconds behind the live edge; 0 when at the edge
player.clock.$liveEdgeTime        // current live edge in session-relative seconds

// Snap back to live.
await player.seekToLiveEdge()

// Rewind within the window (same seek API as VOD, clamped to seekableLiveRange).
await player.seek(to: player.liveEdgeTime - 300)    // 5 minutes back

// isAtLiveEdge is anchored on the buffered edge and is generally false during
// normal playback. Use seekToLiveEdge() to snap rather than waiting for this
// flag to flip true.
player.clock.$isAtLiveEdge
```

A live HLS upstream can be ingested directly, no media server in the data path:

```swift
try await player.load(
    source: .custom(HLSLiveIngestReader(playlistURL: upstreamM3U8), formatHint: "mpegts"),
    options: LoadOptions(isLive: true, dvrWindowSeconds: 600)
)
```

Ingest contract: MPEG-TS segments, including demuxed-audio variants
(`EXT-X-MEDIA` audio groups, fetched by a companion reader and merged by
DTS) and packed-audio renditions (raw ADTS framed by ID3 timestamps).
AES-128 clear-key segments (`EXT-X-KEY:METHOD=AES-128`, the standard
FAST-channel scheme) are decrypted in-line: the key is fetched once per
clip and memoised, and each segment is decrypted (AES-128-CBC / PKCS7)
before demux. SAMPLE-AES / keyless AES-128 (no `URI`), fMP4 playlists
(`EXT-X-MAP`), and a key fetch / decrypt failure terminate with a typed
`HLSIngestError` so the host can fall back to a server-mediated URL. This
is standard HLS clear-key, not FairPlay / Widevine.

Server-side ad insertion (SSAI) plays through the direct path instead of
bouncing to a server transcode at the ad break. FAST channels (Pluto and
similar) splice ad creatives that restart the source clock and often carry
a different video PID, resolution, and SPS than the program. The producer
detects the program switch, parses the ad's SPS/PPS by hand to build a
fresh codec config, rotates the fMP4 muxer, and emits a versioned
`#EXT-X-MAP` per discontinuity so AVPlayer resyncs cleanly across the init
and resolution change; audio is re-anchored to the video timeline at every
creative boundary (including amux creatives that mux audio on a separate
source clock) so it cannot accumulate drift. A no-cut stall watchdog sits
underneath as a safety net: it tells a genuinely wedged pod (reading at
full rate but unable to cut) from a slow source (a trickle) by read rate,
escalating only the former to a host retune.


Format coverage follows the engine's native-first / software-fallback split. H.264 / HEVC / AV1-with-HW route through the native AVPlayer pipeline; AV1-without-HW / VP9 / MPEG-2 / VC-1 route through the software pipeline with a disk-spooled `PacketRingBuffer` backing the rewind. Both paths present the same session-relative timeline to the host.

Install via Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "3.7.0")
```

Two complementary samples ship in `Examples/`:

- [`MinimalPlayer/`](Examples/MinimalPlayer/MinimalPlayerApp.swift) — 90-line SwiftUI drop-in for developers integrating the engine. Copy the file into a new Xcode tvOS / iOS / macOS app, point at a URL, run.
- [`DemoPlayerMac/`](Examples/DemoPlayerMac/README.md) — standalone macOS app for testers wanting to exercise the engine against their own media without writing host code. Drop a file onto the window, it plays. Pre-built universal `.dmg` is attached to every [GitHub Release](https://github.com/superuser404notfound/AetherEngine/releases/latest) (notarized, runs cleanly through Gatekeeper).

## Used by

<!-- used-by:start -->
- [Sodalite](https://github.com/superuser404notfound/Sodalite): native Jellyfin client for Apple TV.
- [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer): native macOS media player.
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

### SwiftUI `Menu` in custom player chrome

On tvOS 26, the focused row of an open SwiftUI `Menu` blinks whenever
any SwiftUI render transaction runs in the hosting tree, even one fully
contained in an unrelated leaf view (a `TimelineView(.periodic)` wall
clock, a playbar observing `engine.clock`, a subtitle overlay).
Minimal repro: a `Menu` next to a `TimelineView(.periodic(from: .now,
by: 1))`, open the menu, the focused item blinks once per second. This
is a SwiftUI issue, not an engine one; reported to Apple by an
AetherEngine adopter (see AetherEngine#29).

The engine keeps its own surfaces out of the blast radius by splitting
every continuously ticking value off the engine's `ObservableObject`
(`engine.clock` at ~10 Hz, `engine.diagnostics` at 1 Hz). But a player
UI always has something ticking, so if your custom chrome needs a
dropdown while playback runs, build the menu button in UIKit and let
SwiftUI host it. `UIButton` with `button.menu` +
`showsMenuAsPrimaryAction` renders the same system menu as SwiftUI's
`Menu` (public API since tvOS 17), and a `UIViewRepresentable` wrapper
can guarantee the open dropdown is never rebuilt:

```swift
struct TrackMenuButton: UIViewRepresentable {
    let items: [TrackMenuItem]

    func makeUIView(context: Context) -> UIButton { /* configure once */ }

    func updateUIView(_ button: UIButton, context: Context) {
        // Same-value reassignment tears down an open dropdown. Only
        // replace the UIMenu when the items actually changed.
        if context.coordinator.currentItems != items {
            context.coordinator.currentItems = items
            button.menu = buildMenu(from: items)
        }
    }
}
```

SwiftUI diffing can re-run `updateUIView` as often as it likes; the
guard means an open menu only rebuilds on a real item change. Credit
to @ohjey for isolating the mechanism and the pattern (AetherEngine#29).

## Playback pipeline

AetherEngine has three playback pipelines, picked once at `load(url:)`: the audio-only path when `LoadOptions.audioOnly` is set, otherwise the native or software video path based on the source's video codec:

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

**Audio-only pipeline (music, podcasts, audiobooks).** When the host sets `LoadOptions.audioOnly`, the engine skips the video machinery entirely: no HLS loopback server, no segment producer, no display layer. Decode is native-first. Codecs on the `avPlayerCanDecodeAudio` whitelist hand the source URL straight to a bare `AVPlayer` (`AudioAVPlayerHost`); everything else demuxes through libavformat and decodes through libavcodec into an `AVSampleBufferAudioRenderer` (`AudioPlaybackHost`). Transport (`play` / `pause` / `seek`) routes to the active host, and `stopInternal` tears it down for a clean handoff back to the video path on the next load.

```
audioOnly == true
   ├─ whitelisted codec ──► AVPlayer (AudioAVPlayerHost) ──► AVR / speakers
   └─ otherwise          ──► Demuxer ──► AudioDecoder ──► AVSampleBufferAudioRenderer ──► AVR / speakers
```

On tvOS and iOS the AVPlayer audio host owns a persistent per-player `MPNowPlayingSession` (exposed via `audioNowPlayingSession`) so the system Now-Playing overlay stays bound to the app across a background pause, auto-publishes now-playing info from the player, and carries `externalMetadata`. The host survives across tracks and does not pause when the app backgrounds. All of this is gated `#if os(tvOS) || os(iOS)`; on macOS the path compiles and plays without the system session (a macOS host drives Now-Playing through the shared centers itself).

Why HLS-fMP4 for the native path instead of feeding `AVPlayer` the source URL directly: AVPlayer's progressive-download path won't accept arbitrary MKV containers, and even for MP4 sources it's brittle around Dolby Vision sample-description quirks and EAC3 `dec3` box variants. The HLS-fMP4 wrapper is the most permissive surface AVPlayer exposes; libavformat's `hls` muxer produces bytes byte-identical to `ffmpeg -f hls -hls_segment_type fmp4`, which is what Apple's HLS spec is defined against.

### Dolby Atmos

EAC3+JOC packets are stream-copied through the muxer untouched, on every output route. AVPlayer reads the segment, recognises JOC from the `dec3` box (`numDepSub=1`, `depChanLoc=0x0100`), and lets the downstream renderer decide what to do with the bitstream: over HDMI it tunnels out as Dolby MAT 2.0 and the AVR lights up the Atmos indicator; over AirPods it renders spatially; over plain Bluetooth A2DP / LE it downmixes the bed channels to stereo natively. The route never changes the engine's decision (a JOC track is signaled in the playlist as `ec-3`, the same CODECS string as a non-JOC EAC3 5.1 track, so AVPlayer accepts it everywhere and the bitstream is never re-encoded for a route reason). The engine emits an explicit `[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged; ...` diagnostic on every Atmos session so the path is unambiguous in the log.

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
- **Sidecar files** (a separate `.srt` / `.ass` / `.vtt` URL) → `selectSidecarSubtitle(url:httpHeaders:)` opens its own short-lived `AVFormatContext`, decodes the whole file once, atomically swaps the result into `subtitleCues`. The fetch forwards the session's `LoadOptions.httpHeaders` by default (WebDAV auth and friends); pass the call's own `httpHeaders` to override per fetch.

A single packet that carries multiple rects (PGS often emits signs/songs at the top alongside dialogue at the bottom) becomes multiple cues at the same time range, and the host renders all of them. Cues are inserted in sorted order; re-emitted events after a seek dedupe by time range plus content (so two simultaneous speaker lines with identical timing both survive) and the list doesn't grow on rewind.

Hosts that render authored ASS styling themselves (positioning, speaker colours, karaoke) opt out of the stripping with `LoadOptions(preserveASSMarkup: true)`: cues then carry the raw event line (override tags, style references, escapes intact), `TrackInfo.assHeader` carries the track's script header (`[Script Info]` + `[V4+ Styles]`), and `engine.fontAttachments` carries the container's embedded fonts (TTF / OTF) for the renderer's font directory. `ASSScriptBuilder` reassembles raw event cues + header into a complete script for whole-file renderers such as swift-ass-renderer's `loadTrack(content:)`, hardened against real-world Matroska tracks (synthesized `[Events]` section, NUL stripping, content-keyed dedupe since real files hardcode `ReadOrder: 0`).

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

HDR sources come out looking right: PQ / HLG BT.2020 frames are tone-mapped to SDR BT.709 through a zscale + tonemap libavfilter graph before the `CGImage` is built, so HDR10 / HLG / DV P8.x stills match what the user sees on screen instead of washed-out grey. (DV Profile 5 is the documented exception, see Known limitations.)

`FrameExtractor` is an `actor`. Blocking FFmpeg work runs on a dedicated serial queue, never on the cooperative thread pool. The decode context opens lazily on first use; a superseded request (the common case during an active scrub) cancels the in-flight decode so the latest position wins. Results land in a bounded LRU cache (snapshots and thumbnails kept in separate stores, thumbnails bucketed by second). After 10 s idle the context closes and the cache drops automatically; the next request reopens lazily. `shutdown()` is the explicit, permanent teardown: it awaits release of the FFmpeg demuxer / codec / sws resources and refuses further work. The engine does not retain the extractor returned by `makeFrameExtractor()`; the caller owns its lifecycle.

## Architecture

```
Sources/AetherEngine/
├── AetherEngine.swift                       Engine core: stored state, load dispatch, transport, stop/seek, track selection
├── AetherEngine+Probe.swift                 Static probe machinery: probe(url:/source:), swDecodeProbe, format / frame-rate / codec-label detection
├── AetherEngine+Loading.swift               The five per-backend loaders (remote-HLS, native, software, audio, audio-native) + reload
├── AetherEngine+Subtitles.swift             Embedded + sidecar subtitle pipeline (side demuxer task, cue apply / prune)
├── AetherEngine+Live.swift                  Live window publishing, edge snap, resume clamp, scrub thumbnails
├── AetherEngine+Diagnostics.swift           Memory probe + live-telemetry bridge
├── PlaybackClock.swift                      engine.clock: the ~10 Hz ticking values (currentTime, sourceTime, progress, live-edge fields) as a separate ObservableObject
├── PlayerState.swift                        PlaybackState, VideoFormat, PlaybackBackend, LoadOptions, SourceProbe, TrackInfo, FontAttachment, MediaMetadata, SubtitleCue, SubtitleImage
├── LiveReloadPolicy.swift                   Pure decision functions for live reloads: rejoin at the live edge (no stale resume position), skip the pre-readiness zero seek
├── TransportControllable.swift              Common transport surface of the four playback hosts (single active-host dispatch)
├── FFmpegErrorConstants.swift               AVERROR sentinels Swift can't import from the C macros
├── Audio/
│   ├── AudioAVPlayerHost.swift              Audio-only path: bare AVPlayer host for whitelisted codecs, owns the persistent per-player MPNowPlayingSession (tvOS / iOS)
│   ├── AudioBridge.swift                    Native path: decode + re-encode per `AudioBridgeMode` (EAC3 5.1 default or lossless FLAC opt-in) for source codecs that can't stream-copy into fMP4
│   ├── AudioDecoder.swift                   SW path: libavcodec → PCM → CMSampleBuffer with channel-layout tagging
│   ├── AudioOutput.swift                    SW path: AVSampleBufferAudioRenderer + Synchronizer (master clock)
│   └── AudioPlaybackHost.swift              Audio-only path: FFmpeg demux + decode into AVSampleBufferAudioRenderer for codecs off the whitelist
├── Decoder/
│   ├── DeinterlaceFilter.swift              SW path: persistent bwdif / yadif libavfilter graph, engages on the first interlaced frame
│   ├── EmbeddedSubtitleDecoder.swift        Inline subtitle decode from demuxed packets
│   ├── HardwareVideoDecoder.swift           SW path: VideoToolbox HW HEVC / AV1 decoder for sources routed away from AVPlayer
│   ├── SoftwareVideoDecoder.swift           SW path: libavcodec/dav1d → CVPixelBuffer (NV12 / P010), HDR10+ side data
│   ├── SubtitleDecoder.swift                Sidecar URL one-shot decode (text only)
│   └── VideoDecoderTypes.swift              DecodedFrameHandler typealias + VideoDecoderError
├── Demuxer/
│   ├── AVIOProvider.swift                   Internal seam over a custom-AVIO byte source; AVIOReader and CustomIOReaderBridge both plug into the Demuxer through it
│   ├── AVIOReader.swift                     URLSession-backed avio_alloc_context, three modes: persistent forward-streaming connection with reconnect-on-drop (playback, incl. live), discrete Range chunks (still extraction), single sequential GET with backpressure (non-live sources without Content-Length)
│   ├── CustomIOReaderBridge.swift           Bridges a host-supplied IOReader into avio_alloc_context read / seek callbacks
│   └── Demuxer.swift                        libavformat wrapper
├── Diagnostics/
│   ├── EngineDiagnostics.swift              engine.diagnostics: timer-sampled values (liveTelemetry) as a separate ObservableObject
│   ├── EngineLog.swift                      Gated OSLog emission
│   ├── FFmpegLogBridge.swift                av_log_set_callback funnel: FFmpeg's internal warnings surface through EngineLog
│   ├── LiveTelemetry.swift                  Value type emitted at 1 Hz: instant / avg bitrate, buffer, network, dropped frames, observed FPS, A/V sync gap, plus subsystem byte counters
│   ├── FourCC.swift                         Printable FourCC rendering for codec-tag diagnostics
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
│   ├── FrameTypes.swift                     FrameMode (.thumbnail / .snapshot)
│   └── HDRToneMapper.swift                  zscale + tonemap libavfilter graph: HDR (PQ / HLG, BT.2020) stills → SDR BT.709
├── IO/
│   ├── IOReader.swift                       Public custom byte-source protocol + MediaSource (load(source:) input)
│   ├── DataIOReader.swift                   Ready-made in-memory IOReader over an immutable Data buffer
│   └── HLSIngest/
│       ├── HLSLiveIngestReader.swift        Public forward-only IOReader ingesting a live HLS upstream (resolver, playlist poller, segment fetcher, companion audio-rendition reader)
│       ├── HLSPlaylist.swift                Line-oriented RFC 8216 subset parser (master / media playlists)
│       ├── HLSPlaylistTracker.swift         Pure segment cursor: duration-capped edge join, window-slide rejoin, stall budget
│       ├── PackedAudioSegments.swift        Packed-audio rendition support: LiveSegmentFormat classification + ID3 PRIV timestamp parser (raw ADTS segments)
│       ├── ByteFIFO.swift                   Bounded blocking byte queue between the fetch loop and the demux thread
│       ├── HLSIngestError.swift             Typed terminal errors (encrypted, fMP4, unreachable, invalid, stalled)
│       └── LiveIngestSourceInfo.swift       Internal seam: upstream segment cadence (shapes TARGETDURATION + blocking-reload eligibility) and DualSourceMergeOrder for the dual-source DTS merge
├── Native/
│   ├── NativeAVPlayerHost.swift             Native path: AVPlayer host bound to the loopback HLS-fMP4 URL
│   └── SoftwarePlaybackHost.swift           SW path: demux loop + decoders + renderer + synchronizer orchestration
├── Network/
│   └── HLSLocalServer.swift                 Native path: local HTTP server (127.0.0.1) serving playlist + segments
├── Renderer/
│   └── SampleBufferRenderer.swift           SW path: AVSampleBufferDisplayLayer + B-frame reorder, HDR10+ attachments
├── Subtitles/
│   ├── ASSScriptBuilder.swift               Reassembles raw ASS event cues + TrackInfo.assHeader into a complete script for whole-file renderers
│   └── SubtitleRectText.swift               Plain-text extraction from subtitle rects (ASS dialogue parsing), shared by the inline and sidecar decoders
├── Video/
│   ├── HLSVideoEngine.swift                 Native path: session orchestrator (start/stop, producer construction + restart, shift handling)
│   ├── HLSVideoEngine+AudioRoute.swift      Native path: stream-copy -> FLAC-bridge -> video-only audio cascade
│   ├── HLSVideoEngine+SegmentPlanning.swift Native path: keyframe / uniform segment plans, extradata + AAC fixups
│   ├── HLSVideoEngine+LiveReopen.swift      Native path: live source-loss recovery (capped-backoff reopen on the same timeline)
│   ├── CodecRoutePolicy.swift               Native path: DV / HDR / codec routing decisions (track types, CODECS strings, VIDEO-RANGE)
│   ├── VideoSegmentProvider.swift           Native path: playlist-facing segment provider (live sliding window, restart heuristics)
│   ├── HLSSegmentProducer.swift             Native path: pump loop reading from Demuxer, feeding MP4SegmentMuxer, cutting fragments at segment-plan boundaries
│   ├── LiveWindow.swift                     Live path: session-relative DVR timeline (seconds since first frame), shared by the native and SW live paths
│   ├── MP4SegmentMuxer.swift                Native path: session-long fragmented-MP4 muxer (+empty_moov+default_base_moof+frag_custom+delay_moov)
│   ├── FragmentSplitter.swift               Native path: routes mp4 muxer's avio output stream into init.mp4 (ftyp+moov) vs per-segment moof+mdat files
│   ├── PacketRingBuffer.swift               Live path: keyframe-indexed, disk-spooled packet ring backing the SW-path DVR rewind
│   ├── SegmentCache.swift                   Native path: producer/consumer segment store with backpressure + scrub-aware eviction
│   └── VTCapabilityProbe.swift              AV1 system-decode probe (gates codec routing; VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 always route SW)
└── View/
    └── AetherPlayerView.swift               Polymorphic surface: hosts either AVPlayerLayer (native) or AVSampleBufferDisplayLayer (SW)
```

## Dependencies

| Package                                                            | License   | Purpose                                                                  |
| ------------------------------------------------------------------ | --------- | ------------------------------------------------------------------------ |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL-3.0  | Slim FFmpeg 8.1 (avcodec / avformat / avutil / swresample / swscale / avfilter + zimg) for demux + HLS-fMP4 mux + AudioBridge FLAC encode + SW-path dav1d decode + sws_scale YUV → NV12 / P010. avfilter ships a trimmed filter set: zscale + tonemap + colorspace (HDR → SDR still extraction), bwdif + yadif (SW-path deinterlacing) |
| VideoToolbox                                                       | System    | Native path video decode (HW where available, Apple's bundled SW dav1d on iOS / macOS) |
| AVFoundation                                                       | System    | AVPlayer + AVDisplayManager (native path); AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer (SW path) |
| CoreMedia                                                          | System    | Sample descriptions, format-description tagging, CMTimebase                |

## aetherctl

A standalone macOS CLI is shipped alongside the library for repro
work without going through TestFlight + Apple TV. Ten subcommands;
most operate on a media source URL (`file://` or `http(s)://`),
`live` and `dvr` run against a built-in synthetic broadcast fixture:

```bash
swift run aetherctl probe <url>          # dump container + streams + duration, exit
swift run aetherctl serve <url>          # park the engine's loopback HLS-fMP4 server
swift run aetherctl validate <url>       # serve + run mediastreamvalidator, exit
swift run aetherctl swdecode <url>       # open SoftwareVideoDecoder, decode N packets, report
swift run aetherctl extract <url>        # FrameExtractor still-image extraction + leak testing
swift run aetherctl audio [--seconds N] <url>   # audio-only pipeline smoke test (default 10 s)
swift run aetherctl customio <path>      # exercise the custom IOReader path end-to-end
swift run aetherctl live                 # live MPEG-TS session against the built-in fixture
swift run aetherctl dvr                  # DVR rewind matrix across native + SW paths
swift run aetherctl hlsfixture <ts>      # local HLS live fixture with fault knobs + ingest self-test
swift run aetherctl <url>                # alias for serve (backwards compat)
```

`probe` opens the demuxer, prints the codec / resolution / frame rate
of the video track, the audio track list (codec, channels, language,
Atmos flag), the subtitle track list, the parsed container metadata
(`MediaMetadata`: title / artist / album / albumArtist + embedded cover
art presence), then exits. No HLS server is started.

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

`audio` plays a source through the audio-only pipeline (default ten
seconds, `--seconds N` to override) and reports which host took it
(bare AVPlayer vs the FFmpeg renderer path), exercising the same
dispatch a music host sees.

`customio` wraps a local file in a custom `IOReader` and plays it
through `load(source:)`. `--memory` reads via `DataIOReader`,
`--forward-only` drops the seek capability, and `--reload` /
`--switch-audio` / `--select-subs` / `--extract` exercise the optional
capabilities (background reload, audio-track switch, embedded
subtitles, scrub preview) end-to-end.

`hlsfixture` slices a local `.ts` into a sliding live HLS playlist and
serves it over loopback, with fault knobs (`--master` indirection,
`--discontinuity-at`, `--slow-refresh`, `--drop-segment`, `--encrypted`,
`--fmp4`) and a `--self-test` mode that runs `HLSLiveIngestReader`
against it end to end.

`live` runs a live MPEG-TS session against a built-in fixture that
serves an endless broadcast by looping a seed `.ts` with rewritten
timestamps. Flags simulate the failure modes the live path hardens
against: `--drop-after N` (mid-stream connection drop + reconnect),
`--discontinuity-at N` (program-boundary PTS / PCR jump),
`--realtime` (1x wall-clock pacing), `--dvr-window N` (timeshift),
`--measure-rss` (sliding-window retention), `--reload-test` (live
rejoin end to end, including the full-backlog replay shape some
origins serve on reconnect). `dvr` runs the rewind
matrix across the native and SW paths (`--path native|sw|both`).

For repeatable runs, `Scripts/fetch-fixtures.sh` generates a small
set of synthetic FFmpeg test clips in `./Fixtures/` (H.264 SDR,
HEVC HDR10, AV1, VP9) covering both the native AVPlayer path and
the software fallback. Real-world DV / Atmos / multichannel sources
go in `./Fixtures/user/` (gitignored).

## Non-goals

Things AetherEngine deliberately doesn't do, so you don't have to read the source to find out:

- No built-in UI. No controls, no transport bar, no pretty HUD.
- No external analytics or session reporting. A 1 Hz `engine.diagnostics.liveTelemetry` surface is provided for host UIs that want to render runtime stats locally; nothing leaves the device.
- No playlist / queue management. Call `load(url:)` when you want the next one.
- No subtitle overlay. The engine decodes packets and emits `SubtitleCue` (text or `CGImage` with normalised position); your UI paints them with whatever style and animation you want.
- No Metal shaders. Everything renders through Apple's native display stack.
- No third-party networking. `URLSession` handles bytes; TLS / HTTP-3 / proxies / MDM rules ride for free.

## Known limitations

Things that work today but have a documented edge case, or are deferred behind an upstream dependency:

- **TrueHD-MAT Atmos object metadata is not preserved.** TrueHD / MLP sources route through the AudioBridge (FFmpeg's EAC3 encoder doesn't produce JOC, which is the Dolby-licensed Atmos-in-EAC3 extension). Bed channels and surround layout survive; object metadata is dropped. EAC3+JOC stream-copy from MKV / MP4 sources is intact.
- **`.surroundCompat` audio bridge caps 7.1 sources to 5.1.** FFmpeg's EAC3 encoder currently caps at 6 channels. Once [FFmpeg PR 21668](https://github.com/FFmpeg/FFmpeg/pull/21668) lands the cap and the dynamic bitrate auto-scale to 1024 kbps engage without a code change here. Use `.lossless` (FLAC) today if 7.1 matters.
- **Manual `MPNowPlayingInfoCenter` writes race the HLS-loopback path on tvOS 26.** The combination produces a `libdispatch` race. Only `AVPlayerViewController` with its standard transport bar safely surfaces Now Playing. Hosts that need a custom transport should use `MPNowPlayingSession` against the engine's `currentAVPlayer` publisher instead of `MPNowPlayingInfoCenter.default().nowPlayingInfo`.
- **Audio session is activated per playback, not at process launch.** The engine declares the `AVAudioSession` category (`.playback` / `.moviePlayback` / `.longFormAudio`) and multichannel support at init, but does NOT activate the session there. Activating once at launch used to pin the route to whatever the HDMI link reported at that instant: with tvOS Continuous Audio Connection off the link idles at stereo, so the launch-time activation negotiated the route to 2 channels and pinned it, downmixing non-Atmos multichannel for the whole session (AetherEngine #24). The native video path now lets the host's `AVPlayerViewController` activate the session per playback, so tvOS negotiates the route against the live sink once playback actually starts; the renderer paths (software decode, audio-only) activate it themselves. Hosts that mount the engine's bare `AVPlayerLayer` instead of an `AVPlayerViewController` should ensure the session is active at playback. A genuine sink-side ch=2 (an AVR caching its HDMI EDID incorrectly after standby) can still force a downmix; power-cycling the sink restores it. Atmos passthrough is unaffected either way because EAC3+JOC ships as MAT 2.0 over a 2-channel carrier.
- **Live MPEG-TS sliding-window eviction and DVR rewind are verified off-device, pending on-device confirmation.** The sliding playlist bounds the resident footprint (no retention growth tracking consumed bytes) and `behindLiveSeconds` is stable at real-time pacing, both measured via the `aetherctl` harness. Confirmation on Apple TV with a real broadcast feed (where the tvOS jetsam budget and real tuner timing apply) is still recommended before relying on it in production.
- **AV1 on Apple TV is software-decoded.** No current Apple TV chip ships HW AV1. The `SoftwarePlaybackHost` + dav1d path handles it, but CPU use is meaningfully higher than HW HEVC. On iOS 17+ / macOS 14+ AV1 routes through Apple's HW pipeline transparently. Future Apple TV chips with HW AV1 will be picked up automatically by `VTCapabilityProbe`.
- **AV1 Dolby Vision Profile 10.0 has wrong colours when software-decoded.** dav1d / libavcodec cannot decode the proprietary DV colour space, so a Profile 10.0 source (DV-only, no fallback base layer) renders with incorrect colours on the SW path. Profiles 10.1 and 10.4 are unaffected because they carry an HDR10 / HLG base layer that the decoder reads correctly. Profile 10.0 only renders correctly through the native AVPlayer path on hosts with HW AV1 decode (M3+ Mac, iPhone 15 Pro+, future Apple TV chips); on software-decode hosts (all current Apple TVs) it is a known colour limitation.
- **Dolby Vision Profile 5 thumbnails (FrameExtractor) have wrong colours.** `FrameExtractor` tone-maps HDR10 / HLG / DV P8.x stills correctly via its zscale + tonemap path, but DV Profile 5 is IPT-PQ with no HDR10 base layer, so the software decode the extractor uses cannot resolve its colour space (same root cause as the AV1 Profile 10.0 limitation above). Full playback of P5 is unaffected: it routes through the native AVPlayer path, which engages the display's DV pipeline.

## Stability and versioning

AetherEngine uses [Semantic Versioning](https://semver.org). The public API surface — every `public` declaration in `Sources/AetherEngine/` — is the stability contract:

- **Major (`X.0.0`)**: removes or renames public symbols, changes method signatures, changes default behaviour in a way that breaks adopters.
- **Minor (`X.Y.0`)**: adds public API, adds codec / format support, fixes behaviour that adopters could not reasonably have depended on.
- **Patch (`X.Y.Z`)**: fixes bugs and reliability issues. No public API changes.

`internal` types and properties are not part of the contract and may change in any release. `@testable import AetherEngine` reaches them for the package's own tests, not for production use.

Pin `from: "3.7.0"` in your `Package.swift` to allow patch + minor updates while excluding breaking changes:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "3.7.0")
```

Pin to `.upToNextMinor(from: "3.7.0")` for stricter teams that prefer to opt into minor bumps explicitly. See [CHANGELOG.md](CHANGELOG.md) for the per-release index.

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

Thanks to [@ohjey](https://github.com/ohjey) for the SwiftUI render-storm investigation in [#29](https://github.com/superuser404notfound/AetherEngine/issues/29): the report drove the `engine.clock` split (3.0.0), the elimination repro isolating the tvOS 26 `Menu` blink, the follow-up that caught the remaining 1 Hz publisher (`engine.diagnostics`, 3.2.0), and the UIKit menu-button pattern now documented under Host setup on tvOS.

## License

[LGPL-3.0 with Apple Store / DRM Exception](LICENSE). The exception clause grants explicit permission to distribute through application stores (Apple App Store, TestFlight, etc.) whose terms otherwise conflict with LGPL §4–6. Modifications to the engine itself still have to be released under LGPL.
