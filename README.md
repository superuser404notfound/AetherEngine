> [!NOTE]
> This is the public Atlas-patched fork of
> [superuser404notfound/AetherEngine](https://github.com/superuser404notfound/AetherEngine). Atlas
> release tags carry two focused request-rate patches on top of the matching upstream tag.

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
  <a href="https://discord.gg/P7NvpzNqnG"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white"></a>
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

---

## What it is

A player engine that gets the hard parts right (HDR, Dolby Vision, Dolby Atmos, container coverage, codec coverage) and exposes a single `AetherPlayerView` (UIKit / AppKit) or `AetherPlayerSurface` (SwiftUI) plus a handful of `async` methods. No `AVPlayerViewController`. No opinionated controls. No analytics. Bind the view, call `play()`, read the published properties for state.

The view is polymorphic: under the hood the engine swaps the hosted CALayer (`AVPlayerLayer` for the native AVPlayer path, `AVSampleBufferDisplayLayer` for the SW dav1d fallback path) per session without the host having to know.

You provide the transport bar. You provide the dropdowns. You provide the pretty.

## Used by

<!-- used-by:start -->
- [Sodalite](https://github.com/superuser404notfound/Sodalite): native Jellyfin client for Apple TV.
- [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer): native macOS media player.
- [NowSeen](https://discord.com/invite/7AFh3Hy8p4): IPTV / Manifest app for tvOS.
- [KSKPix](https://ksktech.dev/kskpix): KSKPix is a premium IPTV player for Live TV, Movies & Series.
- [Syravo](https://syravo.app): Xtream Codes, Jellyfin and radio client for iPhone, iPad and Apple TV.
<!-- used-by:end -->

Shipping something on AetherEngine? [Submit it](https://github.com/superuser404notfound/AetherEngine/issues/new?template=used-by-submission.yml) to get listed here and on [aetherengine.superuser404.de](https://aetherengine.superuser404.de).

## What it handles

A scannable summary; the depth for each row lives in **[docs/formats.md](docs/formats.md)**.

| Area | Summary |
| --- | --- |
| Containers | MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV |
| Disc | DVD-Video and Blu-ray ISO (decrypted): selectable titles and chapters, demuxed through the normal path |
| Video (HW) | H.264, HEVC, HEVC Main10 via VideoToolbox; AV1 where HW AV1 exists |
| Video (SW) | AV1 (dav1d) without HW, VP9 / VP8, MPEG-4 Part 2 / MPEG-2 / VC-1, QuickTime RLE and anything else the FFmpeg build carries a decoder for (software is the default route; only HEVC, H.264 and HW-decodable AV1 go native), H.264 High 4:2:2 / 4:4:4 / 10 and HEVC Rext where VideoToolbox has no HW decoder (Intel Macs, older chips), interlaced H.264 (AVPlayer does not deinterlace; on VOD the declared field order is verified against decoded frames, so progressive-in-interlaced-carriage keeps hardware decode); GPU deinterlace (yadif_videotoolbox, Metal, field-rate by default) with a CPU bwdif fallback |
| HDR | HDR10, HDR10+ (per-frame ST 2094-40), Dolby Vision (P5, P7 as single-layer 8.1, P8.1, P8.4, AV1 P10.x), HLG |
| Audio | AAC, AC3, EAC3, FLAC, ALAC stream-copy lossless; TrueHD / MLP / DTS / DTS-HD MA / MP3 / MP2 / Opus / Vorbis / LPCM (incl. Blu-ray) bridge to EAC3 5.1 (default) or lossless FLAC |
| Dolby Atmos | EAC3+JOC stream-copied on every route (HDMI MAT 2.0, AirPods spatial, BT downmix). No container reliably declares JOC pre-decode, so an honest `TrackInfo.isAtmos` needs a bounded decode: `AetherEngine.probeDetectingAtmos(url:/source:)` answers for a details screen without starting playback, and `LoadOptions.confirmAtmos` has the running session confirm its own tracks in the background and republish `audioTracks`. Both are opt-in and neither sits on the playback-start path |
| Surround | 5.1 / 7.1 with correct `AudioChannelLayout` |
| Audio-only | `LoadOptions.audioOnly`: lean pipeline, no video machinery, system Now-Playing on tvOS / iOS |
| Background audio | Audio keeps playing when the app backgrounds on iOS: native AVPlayer stays alive, the software path drops video and keeps decoding audio (`backgroundPlaybackEnabled` / `pictureInPictureActive`); a paused session survives quick app switches for a grace window (`backgroundTeardownGraceSeconds`, default 15 s) before the wedge-safe teardown runs. tvOS tears down immediately (wedge-safe) unless a PiP window is active, which keeps the pipeline and loopback server alive; with PiP the software path keeps decoding video too (the window needs frames). Hosts gate corrective actions on the published `isSessionReady` |
| Picture in Picture | Native path: hosts build `AVPictureInPictureController` around `currentAVPlayer`, or around the session's own `nativePlayerLayer` when they render through `bind(view:)` rather than AVKit; while `pictureInPictureActive` a native->native load hands the AVPlayerItem over in place so the window survives next-episode transitions. Software path: published `softwarePiPSource` carries the `AVSampleBufferDisplayLayer` plus transport answers on the enqueued frames' PTS axis for sample-buffer PiP. While PiP is active the software path also composites active subtitle cues (text and PGS/DVB bitmaps) into the decoded frames, so the window shows subtitles the host overlay cannot reach. On the native path, a selected bitmap track's compositions are OCR-recognized into its WebVTT rendition, so PGS subtitles render in the PiP window there as well. iOS renders sample-buffer PiP; tvOS AVKit does not evaluate sample-buffer content sources (Apple FB9751461, verified through tvOS 26) |
| Subtitles | Text (SRT / ASS / SSA / VTT / mov_text) inline, bitmap (PGS / DVB / DVD) as `CGImage`, in-band CEA-608 closed captions (field-1, from an `eia_608`/`c608` demuxable track or extracted from A53 `cc_data` embedded in the video bitstream: H.264/HEVC SEI on the native path, decoded-frame side data such as MPEG-2 on the software path, with the caption track surfacing lazily on first real caption data), DVB teletext decoded to text cues with broadcaster colour preserved and a selectable caption page (libzvbi, `LoadOptions.teletextPage` at load, `setTeletextPage(_:)` while the channel plays), external files as first-class tracks (registered, listed, selected like embedded streams), a live channel's own HLS `SUBTITLES` renditions surfaced as tracks and fetched only once one is selected, opt-in raw ASS markup + fonts; embedded-text cues harvested from the producer's own read (instant enable, no side-channel bandwidth); opt-in native WebVTT renditions (one per text track incl. load-declared external files, language-tagged) so subtitles survive PiP / AirPlay / external display (`LoadOptions.prepareNativeSubtitles`); bitmap tracks (PGS / DVB / DVD, embedded and external .sup) join as OCR-fed renditions: on-device Vision text recognition runs while the track is selected and fills a language-tagged text rendition, so bitmap subtitles survive PiP / AirPlay / external display on the native path too (lossy by design; fullscreen keeps the pixel-accurate overlay) |
| Frames | Off-playback `FrameExtractor`: `thumbnail` (scrub preview) + `snapshot` (frame-accurate) |
| Audio tap | Opt-in `installAudioTap()`: decoded playback audio as mono Float32 48 kHz PCM with source-PTS timestamps, off the render path (live transcription, ShazamKit); delivers on the loopback, remote-HLS (VOD + live), and software paths. The stream is bound to its session, so a session-preserving reload (audio / subtitle / disc-title switch, `reloadAtCurrentPosition`) finishes it and the host re-installs on stream end |
| Metadata | `MediaMetadata` (title / artist / album + cover) parsed on load; a container's album artist folds into `artist` as a fallback |
| Seek | VOD seeks into watched content are restart-free cache hits (byte-budgeted retention, 2 GiB cap); short forward scrubs ride the cached window; only never-produced targets restart the producer |
| Streaming | One long-lived forward-streaming connection, reconnect-on-drop; CDN-stutter resilient; optional caller-bounded open-time probe budget (`LoadOptions.probesize` / `maxAnalyzeDuration`) to cut first-frame latency on sparse remote remuxes; configurable forward-buffer window (`LoadOptions.forwardBufferSegments`), from the 40 s default up to an opt-in whole-source pre-buffer that is bounded in bytes by the session's disk budget rather than in segments |
| Live / DVR | Unbounded live + optional timeshift; direct HLS ingest with AES-128 clear-key and SSAI ad-pod handling |
| Custom input | Play any byte source via the `IOReader` protocol (`load(source:)`) |
| Network | SMB2/3 shares via the optional `AetherEngineSMB` product (NTLMv2 / guest, read-only) |

## How it compares

On Apple platforms the real choice is between AVPlayer, with deep OS integration but only the formats Apple ships, and a VLC- or mpv-derived engine, which plays almost anything but renders its own frames and bypasses the system's Dolby Vision, Atmos, and HDR handling. AetherEngine is built to give you both: FFmpeg's format breadth layered on top of VideoToolbox and AVPlayer, so Dolby Vision, Atmos, and Match Content keep working. KSPlayer is the closest analog, it reaches the same outcome through the same AVPlayer route, but it ships as a full player with its own UI, and its free build is GPL while a paid LGPL tier unlocks AV1 hardware decoding, the full demuxer and decoder set, and a list of playback features its own feature matrix enumerates; AetherEngine is an embeddable engine you drive from your own SwiftUI, with that codec and HDR breadth in the open-source core.

| | AetherEngine | KSPlayer | AVPlayer | VLCKit | libmpv |
| --- | --- | --- | --- | --- | --- |
| **Approach** | Embeddable engine, Apple-only | Full player with bundled UI, FFmpeg + AVPlayer, Apple-only | Apple's built-in player | libVLC wrapped for Apple | libmpv, cross-platform |
| **Container & codec breadth** | Wide, FFmpeg demux | Wide, FFmpeg demux | Narrow, Apple's set | Wide | Wide |
| **Hardware decode** | VideoToolbox, dav1d SW fallback | VideoToolbox, FFmpeg SW fallback | VideoToolbox | VideoToolbox plus software | VideoToolbox plus software |
| **Dolby Vision** | P5, P7 as 8.1, P8.1, P8.4, AV1 P10.x, real display switch | P5, P8 via AVPlayer; their matrix lists P5 HDR display without overheating as paid LGPL | P5 and P8.1 only | Tone-maps, no DV display | Tone-maps, no DV display |
| **Dolby Atmos** | EAC3+JOC stream-copied (HDMI MAT, spatial) | EAC3+JOC via AVPlayer | EAC3+JOC passthrough | Decodes to PCM, no object passthrough | No Atmos passthrough on Apple |
| **HDR on tvOS** | Native Match Content switch | Native Match Content on AVPlayer path, else Metal tone-map | Native Match Content | Software tone-mapping | Software tone-mapping |
| **Rendering & UI** | OS-native, you ship SwiftUI | Own Metal renderer, bundled controls | OS-native, you ship UI | Own renderer, bundled controls | Own renderer, bundled OSC |
| **Apple TV / App Store** | Yes, LGPL plus store exception | Free build GPL, paid LGPL tier for AV1 hardware decode and the full decoder set | Yes | Yes, LGPL | Not practical, GPL, no tvOS |

The engine leans on the platform where the platform is best (hardware decode, Dolby Vision display, Atmos passthrough) and only falls back to its own software path (dav1d, libavcodec) for the formats VideoToolbox cannot handle.

### Measured

The table above is qualitative. The numbers below are measured, on a 4K HDR HEVC file in Matroska, the container media servers actually serve. They are produced by [aetherengine-bench](https://github.com/superuser404notfound/aetherengine-bench), which is run by this project's author, so its method, its raw data and the cases where AetherEngine does not win are all in that repository.

Measured on Apple-M1 (MacBookAir10,1), macOS 26.5.2, hevc-4k-hdr10.mkv, windowed, 3840x2160 px rendered, 60 s, median of 2.
MacBookAir10,1 is fanless: sustained decode can reach thermal pressure, which is why the protocol has cooldowns between runs and discards throttled windows.

| | GPU power | CPU load | RSS | Plays |
| --- | --- | --- | --- | --- |
| **AetherEngine** | 63 mW | 5.2% of a core | 325 MB | Yes |
| **KSPlayer** | 149 mW | 6.6% of a core | 331 MB | Yes |
| **AVPlayer** | | | | n/a (refuses hevc-4k-hdr10.mkv: This media format is not supported.) |
| **VLCKit** | 362 mW | 14.3% of a core | 102 MB | Yes |
| **libmpv** | 887 mW | 18.1% of a core | 373 MB | Yes |

Launch failures on hevc-4k-hdr10.mkv (crashes that were retried, not refusals, see the README): KSPlayer 1.

Frame delivery and output (median; resolution, bit depth and HDR transfer are informational per engine only, shown as 'varies across repeats' when they disagree, see the README):
- **AetherEngine**: 1440/1438 delivered/expected, dropped 0, 3840x1714, 10-bit, hdr10, rendered into 3840x2160.
- **KSPlayer**: 1440/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, SMPTE_ST_2084_PQ, rendered into 3840x2160. Served via **KSMEPlayer**.
- **VLCKit**: 1442/1440 delivered/expected, dropped 0, 3840x1714, bit depth and color transfer not reported by this engine, rendered into 3840x2160.
- **libmpv**: 1442/1440 delivered/expected, dropped 0, 3840x1714, 10-bit, pq, rendered into 3840x2160.

Versions: AetherEngine 6.26.0, KSPlayer 2.3.4, AVPlayer macOS 26.5.2, VLCKit 4.0.0-alpha.21, libmpv mpv v0.41.0.

Power figures are package power with an idle baseline subtracted, so they are attributable to the run and not to the machine.
CPU package power was measured for every run but is not published above: the idle baseline drifts with load enough that one engine's own repeats can disagree more than the column would be used to show between engines. For example, on hevc-4k-hdr10.mkv libmpv measured 100 to 372 mW of CPU package power across its own repeats, a 3.7x range. Recorded for every run in Results/; see "Known gaps" in the README for the full reasoning.
libmpv is measured with --hwdec=auto-safe (hardware decode), not mpv's own software-decode default, see "Fairness decisions" in the README.
libmpv's rows come from a separate run of the same protocol on the same day and the same machine. Its rows in the main run were lost to a defect in the mpv report writer (a missing import), not to anything about mpv itself. The GPU idle baseline on this machine is under 1 mW, and CPU load and RSS are not baseline-subtracted at all, so a separate baseline does not move the three published columns.
Method and raw results: https://github.com/superuser404notfound/aetherengine-bench

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
player.$state          // .idle, .loading, .playing, .paused, .seeking, .ended, .error(String)
                       // .ended = played to completion (any backend); .idle = pre-load / stopped.
                       // .ended is TERMINAL: seek is rejected and play() does not revive it, so a
                       // replay is another load(). A VOD merely parked at its final frame is the
                       // other case and play() rewinds it. How every other failure arrives, and
                       // why a CancellationError out of load() is not one, is in docs/api.md.
player.$errorInfo      // PlaybackErrorInfo?, the machine-readable half of .error: a stable
                       // PlaybackErrorKind plus the underlying NSError domain and code. Classify on
                       // this. The message cannot: on the native paths it is AVPlayerItem.error
                       // .localizedDescription forwarded verbatim, so it is in the device's
                       // language, and a substring rule over it buckets every non-English device as
                       // unknown. Set before .error is published, cleared when the state leaves it.
player.$duration
player.$videoFormat    // .sdr, .hdr10, .hdr10Plus, .dolbyVision, .hlg
player.$isSeeking      // true until a seek physically lands (programmatic + native scrubs, and
                       // seeks stashed before the session can take them)
player.$seekTarget     // in-flight seek destination (source-PTS), nil otherwise
player.seekEvents      // AnyPublisher<SeekEvent, Never>: .began / .landed(renderedTime:) /
                       // .stalled / .superseded / .rejected, each with the target it belongs to.
                       // Use this where the FALLING edge of $isSeeking matters: the level cannot
                       // say whether a seek landed, gave up, or was superseded, and a seek that
                       // gave up can still land minutes later on a stalled source.
player.$playbackPhase  // unified: .idle/.loading/.playing/.paused/.seeking/.rebuffering/
                       // .stalled(reconnecting:)/.ended/.error. One source of truth for a status
                       // spinner; derived from state + isBuffering + isSeeking + source reconnect.
                       // Prefer this over stitching the raw signals or matching EngineLog text.
player.$videoRoute     // pipeline actually serving the session: .remoteBypass (AVPlayer on the
                       // origin URL) / .loopback / .software / .audio / .none. LoadOptions
                       // .nativeRemoteHLS is only the request: the carriage watchdog, the
                       // remembered verdict and the HLS reroutes move a session between the
                       // bypass and the loopback, mid-session too. Branch on this where behaviour
                       // differs per pipeline, above all who draws subtitles: on .remoteBypass
                       // AVPlayer renders the origin's renditions, elsewhere the host renders.
player.$hasFirstFrameReadyForDisplay
                       // the running path has a first frame ready for display, for the media THIS
                       // load opened: the edge a black cover comes off on. readyToPlay is not that
                       // edge (AVFoundation reaches it before the layer holds a picture, and it
                       // stays true across a seek), so a cover lifted on isSessionReady lifts onto
                       // black. Latched for the load, false again at the next load() / stop().
                       // For "has this seek reached the screen" use seekEvents .landed instead.
player.$startupProgress // StartupProgress?, for a determinate loading bar: .completed of .total
                       // checkpoints, .fraction, and .stage naming the work in flight. Every value
                       // is work some part of the load actually finished, never a timer and never an
                       // estimate, so a slow stretch holds and a skipped one jumps. It covers the
                       // two stretches a host cannot otherwise see: the source open (connection,
                       // container, stream analysis) and the display-criteria handshake. Scoped to
                       // .generation, which counts the startups a user waited through rather than
                       // teardowns, so an engine-initiated reroute continues the bar instead of
                       // resetting it. Monotonic and deduped; nil before the first load and after
                       // stop(); a load that fails simply never reaches the last checkpoint.
player.$currentAVPlayer // active AVPlayer, re-emitted on every reload (MPNowPlayingSession).
                       // nil on the .software route: that pipeline renders into its own display
                       // layer, and the property is cleared so AVKit cannot hold a player nothing
                       // feeds any more. A host that only ever hands currentAVPlayer to an
                       // AVPlayerViewController therefore gets audio and AVKit's own spinner over an
                       // empty video plane on that route (#298). Bind a surface for it, and pick the
                       // presentation off $videoRoute rather than off the source's codec.

// System Now-Playing on the native video path (tvOS / iOS). Off by default: an
// AVPlayerViewController host already gets this from AVKit and must NOT opt in.
// Custom-transport hosts set it before load(), then register commands on the
// session and stage identity through setVideoNowPlayingInfo.
player.ownsVideoNowPlayingSession = true
player.videoNowPlayingSession                  // MPNowPlayingSession?, nil unless opted in
player.setVideoNowPlayingInfo([ /* MPMediaItemProperty… */ ])

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
player.$subtitleCues                           // [SubtitleCue]: .text(String), .richText([SubtitleTextRun]), or .image(SubtitleImage)

// #233: styled text arrives as .richText. A run carries colour, bold, italic, underline,
// strikeout, font face and an ASS-relative font size; the cue carries the placement it asks
// for (numpad alignment plus an optional [0, 1] anchor). This covers SRT, WebVTT, teletext
// and ASS alike, because libavcodec converts them all to ASS event lines before the engine
// sees them. A cue with no styling still arrives as .text, so handling only that case keeps
// working. WebVTT cue settings are the exception: libavcodec does not convert them, so VTT
// positioning does not arrive (its inline bold/italic/underline does).
for cue in player.subtitleCues {
    if case .richText(let runs) = cue.body { render(runs, at: cue.placement) }
}

// External subtitle files are first-class tracks (#88): they appear in subtitleTracks
// (isExternal == true, synthetic id) and select through the same call as embedded streams.
let track = player.addExternalSubtitleTrack(
    ExternalSubtitleTrack(url: srtURL, name: "English", language: "en"))
player.selectSubtitleTrack(index: track.id)
// Declared at load instead, external tracks also join the native WebVTT renditions (PiP):
// LoadOptions(prepareNativeSubtitles: true, externalSubtitles: [ExternalSubtitleTrack(url: srtURL, language: "en")])
// When the URL is a container holding several subtitle streams, register one track per stream
// with its absolute AVStream index; tracks sharing a URL are decoded in one pass (#266).
ExternalSubtitleTrack(url: mkvURL, name: "Spanish", language: "es", sourceStreamIndex: 3)

// Native WebVTT subtitle renditions (subtitles in PiP / AirPlay / external display; opt-in
// via LoadOptions.prepareNativeSubtitles, details in docs/formats.md)
player.$nativeSubtitleTracks                   // [NativeSubtitleTrack]: ordinal, language, displayName
player.setNativeSubtitleSelected(track: 2)     // engage a rendition (e.g. on PiP entry); nil deselects

// The SYSTEM turned captions on by itself: iOS 26 Settings > Accessibility > Subtitles & Captioning
// > Automatic Subtitles (show when muted, on skip back, on a language mismatch). Those toggles have
// no read API, so the selection is the only way to see the ask. The engine deselects the option (a
// rendition rendered in fullscreen draws a caption box over the host's own subtitles) and forwards
// the request; a host that wants the behaviour picks its own matching track. Subscribe per session.
player.systemCaptionRequest                    // PassthroughSubject<SystemCaptionRequest, Never>

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
player.selectChapter(id: chapterID)            // seek to a chapter (disc chapters only)

// Container chapters (Matroska / MP4; empty for disc sources, which publish discChapters instead)
player.$mediaChapters                          // [ChapterInfo]; startSeconds are seek(to:) timestamps

// Info panel / Now Playing (iOS / tvOS)
player.setExternalMetadata([ AVMetadataItem(/* title, artwork, etc. */) ])

// Frame-accurate host rendering on the native path (#260). Cue times, chapters and sourceTime live on
// the SOURCE axis; AVPlayerItem.currentTime() and its timebase read the ITEM axis. They differ by the
// producer shift, which steps at every producer epoch (a seek restart, a live program boundary).
player.presentationAxisMap                        // conversion both ways, readable off the main actor
player.presentationAxisMap.itemSeconds(forSourceSeconds: cue.startTime)   // stamp an overlay sample
player.presentationAxisMap.sourceSeconds(forItemSeconds: item.currentTime().seconds)
player.$currentAVPlayerItem                       // items swap in place; this is the signal for it

// Per muxed video frame, on both axes at once. Called on the producer's pump thread in DECODE order,
// so `source` is not monotonic under B-frames; sort before using it as a frame-boundary list.
// `epoch` rises strictly, process-wide: a restart and a load() both continue the sequence, so
// "a higher epoch retires my older entries" separates one item's frames from the next's.
player.setNativeVideoFrameTimeObserver { frame in
    frame.source; frame.item; frame.segmentIndex; frame.isKeyframe; frame.epoch
}

// The same question on the software path (#311), where the engine decodes and enqueues the source
// timestamp unchanged: one axis, no segments, and the reports arrive past the reorder buffer in
// ASCENDING presentation order. `generation` moves on every renderer flush, i.e. on a seek, and
// rises across a load() the same way `epoch` does.
player.softwarePresentationTimebase               // the master clock, on the source axis
player.setSoftwareVideoFrameTimeObserver { frame in
    frame.presentation; frame.generation
}

// The rectangle those frames land in (#353): coded dimensions under the pixel aspect ratio the
// decoder attached, read off the format description the renderer enqueues. `sourceVideoWidth` and
// `sourceVideoHeight` are the CODED size, so anamorphic content laid out against them is off by the
// pixel aspect (720x576 at 64:45 presents as 1024x576). nil off the software path and before the
// first frame; it follows a mid-stream format change and is cleared with the session.
player.softwareDisplaySize                        // CGSize?, @Published
```

Subtitle cues land in raw source PTS; render the overlay against `player.sourceTime` (see [docs/formats.md › Subtitles](docs/formats.md#subtitles)). A host compositing its own overlay onto the native path (libass and friends) needs the item axis too, since that is what the compositor pairs its samples against: `presentationAxisMap` converts arbitrary positions, `setNativeVideoFrameTimeObserver` reports the frames themselves. On the software path neither is needed: `softwarePresentationTimebase` hands out the clock the frames are presented against and `setSoftwareVideoFrameTimeObserver` reports them, both on the same axis as the cues, and `softwareDisplaySize` gives the rectangle to lay the overlay out in (the native path measures its own on `AVPlayerLayer.videoRect`). Both return nothing rather than a guess when no axis is established, because a defaulted shift is indistinguishable from a measured one at the call site. The 1 Hz diagnostics snapshot lives on `player.diagnostics.liveTelemetry`, off-the-engine for the same render-stability reason. Frame extraction and authored-ASS styling are documented in [docs/formats.md](docs/formats.md); the full published surface, including the contracts that require the host to act rather than to read, is [docs/api.md](docs/api.md).

Install via Swift Package Manager:

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "6.60.0")
```

Three samples ship in `Examples/`:

- [`MinimalPlayer/`](Examples/MinimalPlayer/MinimalPlayerApp.swift): a single-file SwiftUI drop-in, transport bar included. Copy it into a new tvOS / iOS / macOS app, point at a URL, run.
- [`LiveHost/`](Examples/LiveHost/LiveChannelHost.swift): the live-TV half, the four contracts a channel needs that no compiler asks about (the `liveSourceReset` retune and its guard, `CancellationError` out of a superseded `load`, the audio tap that ends with its session).
- [`DemoPlayerMac/`](Examples/DemoPlayerMac/README.md): a standalone macOS app for testers. Drop a file on the window, it plays. A notarized universal `.dmg` is attached to every [GitHub Release](https://github.com/superuser404notfound/AetherEngine/releases/latest).

### Custom input source

```swift
final class MyArchiveReader: IOReader {
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { /* ... */ }
    func seek(offset: Int64, whence: Int32) -> Int64 { /* ... */ }  // AVSEEK_SIZE (65536) returns total size
    func close() { /* ... */ }

    // Optional requirements have defaults. Override to unlock extra features:
    func cancel() { /* unblock a blocked read at teardown, do NOT invalidate the reader */ }
    func makeIndependentReader() -> IOReader? { /* a fresh cursor over the same source, or nil */ }

    // Optional, defaults to true. Return false when this is known to be an
    // ordinary media file rather than a raw ISO/UDF disc image.
    var discImageProbeEnabled: Bool { false }
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
try await engine.load(source: .custom(
    SMBIOReader(source: smb),
    formatHint: "matroska"
))
```

When the SMB path is known to be an ordinary media file, construct the reader with
`discImageProbeEnabled: false` to skip ISO/UDF signature reads. Keep the default for raw disc
images so DVD/Blu-ray recognition remains available.

Read-only, NTLMv2 / guest auth (no Kerberos). On tvOS the host must declare `NSLocalNetworkUsageDescription` + the local-network entitlement to reach a LAN share. See [`aetherctl smbtest`](docs/cli.md#smbtest) to validate a share from macOS.

Known limitation: SMBClient negotiates only SMB 2.0.2 and 2.1, so there is no SMB3 transport encryption or AES-CMAC signing. Servers configured SMB3-only or with `smb encrypt = required` won't connect (libsmb2 spoke 3.1.1 here, but was itself unusable on tvOS/iOS, see above).

### Live TV / DVR

```swift
// Live-only (seek() is a no-op), or live + timeshift:
try await player.load(url: streamURL, options: LoadOptions(isLive: true))
try await player.load(url: streamURL, options: LoadOptions(isLive: true, dvrWindowSeconds: 1800))

// IPTV channel zapping: join in ~3-6s instead of 10-18s on strict-realtime origins by letting
// TARGETDURATION (and the live-edge holdback derived from it) track the source keyframe cadence:
try await player.load(url: streamURL, options: LoadOptions(isLive: true, liveJoinProfile: .fastZap))

// Drive a scrubber from the live-edge fields (they tick, so they live on player.clock):
player.clock.$seekableLiveRange   // ClosedRange<Double>?, session-relative; nil when DVR off
player.clock.$behindLiveSeconds   // seconds behind the edge; 0 at the edge
player.clock.$liveEdgeTime
await player.seekToLiveEdge()
await player.seek(to: player.liveEdgeTime - 300)   // 5 minutes back

// The retune contract: the engine parked the session and only a fresh URL revives it.
player.liveSourceReset            // PassthroughSubject<Void, Never>; subscribe per session

// Ingest a live HLS upstream directly, no media server in the data path:
try await player.load(
    source: .custom(HLSLiveIngestReader(playlistURL: upstreamM3U8), formatHint: "mpegts"),
    options: LoadOptions(isLive: true, dvrWindowSeconds: 600)
)
```

`liveJoinProfile: .fastZap` (AetherEngine#195/#208) cuts live segments at every keyframe past 0.5 s instead of the standard ~4 s, so the served `TARGETDURATION` collapses to the source GOP length and its live-edge holdback (`HOLD-BACK` = 3 x `TARGETDURATION`, the RFC 8216bis floor; AetherEngine#189) shrinks with it. The first manifest still prefers the full holdback. After two finalized segments, a strict-realtime source gets one observed-segment grace clamped to 0.5...2.0 s, then a shallow first window may be served so startup stays bounded. This can produce one early `-16832` or a short rebuffer. `.standard` retains the full-holdback guarantee. The smaller `TARGETDURATION` also tightens AVPlayer's unchanged-playlist patience and live-edge buffer, so origins that stall or burst mid-stream rebuffer more readily; opt in for zapping UX, keep `.standard` for lean-back viewing.

`liveSourceReset` is live's counterpart to a terminal `state = .error`, and a host that plays live has to subscribe to it. It fires where the session cannot be revived from inside the engine and only a new URL can: a source that restarted from byte 0 (a Jellyfin transcode respawn), a playlist still frozen after the stall ladder's last reload rung (#65), or an in-engine reopen transport whose budget is spent (#199). Each of those halts production first, so a dead provider stops advertising blocking reloads behind the host's back. Answer it by negotiating a fresh URL and calling `load` again, and guard that answer (one retune in flight, a minimum spacing, a bounded count per session) or a permanently dead upstream turns into a retune loop. Spend that bound out loud: a retune ladder that ends on a silent `return` leaves the same dead channel behind a counter, so surface the exhaustion the way a terminal `.error` would be surfaced.

A host with no negotiation to do, an IPTV channel whose URL is fixed, answers by loading the same URL again, and that is the cheap path rather than a no-op. The #168 carriage verdict (a master advertising HEVC while delivering MPEG-TS) is remembered per exact absolute URL for six hours, 32 entries, so the retune routes straight onto the live ingest instead of re-paying the doomed native mount and its watchdog grace. A URL carrying a rotated per-session token misses that memory and re-pays the one-time discovery per retune, which is worth knowing where a first-frame budget is measured against the retune as well.

Left unsubscribed it costs a channel that stops while the engine still reports a session, which from the outside is indistinguishable from a slow one.

Direct ingest covers MPEG-TS with demuxed-audio and packed-audio renditions, in-line AES-128 clear-key decryption, and SSAI ad-pod direct play (versioned init segments, audio re-anchoring, no-cut watchdog). Unsupported encryption / fMP4 playlists surface a typed `HLSIngestError` so the host can fall back. Details in [docs/formats.md › Live ingest](docs/formats.md#live-ingest-aes-128-ssai).

A channel whose master declares an `EXT-X-MEDIA:TYPE=SUBTITLES` group gets those renditions as ordinary entries in `subtitleTracks` (#359). The ingest demuxes the picked video variant only, so the group never reaches the demuxer; the engine reads it off the master instead and, once `selectSubtitleTrack(index:)` picks one, fetches that rendition's WebVTT segments and publishes the cues on the host-overlay surface, placed against the picture by the shared `EXT-X-PROGRAM-DATE-TIME` geometry rather than by `X-TIMESTAMP-MAP`. Nothing is fetched until a track is selected. Details in [docs/formats.md › Live HLS subtitle renditions](docs/formats.md#live-hls-subtitle-renditions-host-overlay).

For an upstream AVPlayer can play natively (a standard remote `master.m3u8`, e.g. a Jellyfin live channel), `LoadOptions.nativeRemoteHLS` skips the demuxer probe and the loopback server entirely and hands the URL straight to AVPlayer, which manages the live edge and reconnect itself. Pair it with `isLive: true`. `LoadOptions.httpHeaders` rides into the `AVURLAsset` on this path, so origins that enforce per-stream `Referer` / `User-Agent` / `Authorization` headers (common for IPTV channels) work too.

A live channel whose master advertises HEVC (or Dolby Vision / AV1) while delivering MPEG-TS segments is carriage AVFoundation builds no video track for, so the bypass would play it as audio over black. The engine recognizes that signature and reroutes the session onto the live ingest above (#168). The recognition runs alongside the mount: the playlist and the head of one segment are read while AVPlayer starts, so the reroute does not wait out a grace window, and a media playlist URL with no master to judge is covered too (#293). Only a codec the HLS Authoring Spec sanctions in fMP4 alone reaches that read, so an H.264 channel spends no extra request on it. `LoadOptions.nativeRemoteHLSIngestFallback = false` turns the whole recovery off.

A LIVE remote `m3u8` handed to the default (loopback) path routes the other way, onto the live ingest above (#363). The raw live path reads bytes, not playlists, so it used to reject an `.m3u8` with a typed `hlsPlaylistOnRawLivePath` error naming the reader the host should have built. It builds that reader itself now, with `LoadOptions.httpHeaders` on the playlist, on every segment and on every AES key, which is what a tokenized IPTV origin enforces per request. A custom `IOReader` carrying the same misroute still gets the typed error: it has no playlist URL to ingest from.

If a live `nativeRemoteHLS` bypass is refused by the origin outright (HTTP 401 or 403, which reach the item as `NSURLError` -1013 / -1102), the engine hands that session to the same ingest instead of failing the load (#363). The ingest fetcher is a different client at that origin: it carries the configured headers on every request, caps itself at four concurrent fetches, and sends no AVFoundation user agent, so a UA filter or a per-token connection cap that turned AVPlayer away can still serve it. The refusal is not remembered for the next load the way a carriage verdict is; a token expires, a cap frees up. `LoadOptions.nativeRemoteHLSIngestFallback = false` turns this off along with the carriage recovery.

A non-live remote `m3u8` handed to the default (loopback) path reroutes onto the AVPlayer bypass instead: the bundled FFmpeg is built without network support, so the playlist can never be demuxed locally, and remote HLS is AVPlayer's native domain anyway (#154). On the bypass the engine surfaces the stream's external WebVTT subtitle renditions (the legible `AVMediaSelectionGroup`) as `subtitleTracks`; `selectSubtitleTrack(index:)` and `clearSubtitle()` drive AVPlayer's media selection, and AVPlayer renders the cues itself.

Sidecar subtitles declared in `LoadOptions.externalSubtitles` become renditions on this bypass too (#316). Media selection on an HLS asset comes from the playlist and nowhere else, so for a VOD source the engine fetches the origin master, rewrites every variant, audio and key URI to an absolute origin URL, adds one `EXT-X-MEDIA:TYPE=SUBTITLES` entry per sidecar, and serves that master from the loopback origin. AVPlayer still fetches all A/V bytes straight from the origin, so E-AC-3 / Atmos passthrough is untouched; only the master and the WebVTT renditions are local. The tracks keep the external ids they were registered under, and selecting one drives media selection instead of the host overlay, so the subtitle survives PiP, AirPlay and a wired external display. Live sources (no `EXT-X-ENDLIST`), bitmap sidecars, a playlist that will not rewrite and a slow origin all fall back to playing the origin URL with host-overlay subtitles, which is the behaviour before #316; the load is never failed over this.

### IPTV timeshift / catch-up archives

```swift
// An origin that answers every Range with a plausible 206 whose body is not at that offset:
try await player.load(url: archiveURL, options: LoadOptions(
    sequentialOrigin: true,             // only byte 0 is addressable
    declaredDurationSeconds: 8100       // required on VOD; the tail-read estimate is gone
))
```

Timeshift and catch-up archives commonly fabricate range answers: `Range: bytes=X-` returns `206`
with a body that actually sits on a coarse internal chunk boundary. No header exposes that, so the
caller declares it (#346). The reader then runs one long-lived unranged GET with no ranged probes,
no byte-offset reconnects and no tail read, the demuxer's pb is non-seekable, and a dropped
connection surfaces as a read error rather than end-of-media so the host can re-request. Such a
source keeps the native path instead of being forced to software, and the session serves an
append-only `EVENT` playlist carrying the durations actually muxed, completed with `ENDLIST` at
true source EOF. Every producer reposition is refused by construction, so **seeking is
unavailable**: re-request the archive with a shifted start timestamp instead. `aetherctl play`
gains `--sequential-origin` / `--declared-duration` for reproducing one from macOS.

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

**Who owns the audio session:** the engine declares the category at init but deliberately never activates it on the native path, because AVKit activates per playback and that is what lets tvOS negotiate the HDMI route (issue [#24](https://github.com/superuser404notfound/AetherEngine/issues/24)). It therefore never releases it either, and on an E-AC-3 / Atmos bitstream-passthrough route the sink can keep looping the last MAT frame after the player is gone. If your app owns the session (no UI sounds, TTS, or `AVAudioEngine` of its own competing with playback), set `engine.deactivatesAudioSessionOnStop = true` and the engine releases the session on a genuine final teardown, meaning `stop()`, never a reload, handoff, or live retune. It is off by default: an app that plays its own audio would otherwise have its session torn out from under it when playback ends.

> **Custom chrome with a SwiftUI `Menu`?** On tvOS 26 an open `Menu`'s focused row blinks on any render transaction in the tree. Build the menu button in UIKit (`UIButton.menu` + `showsMenuAsPrimaryAction`) and guard `updateUIView` so the open dropdown never rebuilds. Pattern in [docs/architecture.md › SwiftUI Menu](docs/architecture.md#swiftui-menu-in-custom-player-chrome).

## Diagnostics

Every diagnostic line the engine emits goes to `os.Logger` under the subsystem `de.superuser404.AetherEngine`, one category per subsystem (`engine`, `session`, `demux`, `muxer`, `hls.server`, `audio.bridge`, `sw.playback`, `scrub`, `ffmpeg`). Release builds keep emitting; Console.app against the attached device, or `log stream --predicate 'subsystem == "de.superuser404.AetherEngine"'`, shows them without a debugger attached.

A test rig that only captures stdout / stderr (`devicectl device process launch --console`, CI harnesses) sees none of that, because os_log is not stdio. Mirror the same lines into your own capture path with the host handler:

```swift
EngineLog.handler = { print($0) }   // every info-level line, verbatim
```

The first line of any session names the FFmpeg that answered, because which one does is decided by your executable's link rather than by the package graph:

```
[FFmpeg] libavcodec 62.28.102, libavformat 62.6.100, libavutil 60.13.100, libswresample 6.0.100
```

If a second FFmpeg in the app takes those symbols, that line turns into an `ERROR:` naming the mismatch and how to find it. Worth reading once per integration: the failures a wrong FFmpeg produces look like engine defects, and one cost a reporter five fixtures and two devices before anyone looked at the link. Details in [docs/api.md › One FFmpeg](docs/api.md#one-ffmpeg-and-it-has-to-be-the-engines).

The handler fires from whatever thread emitted the line (demuxer, producer pump, local server, audio bridge), so it must be thread-safe and non-blocking; serialize onto a queue before writing to a file. Per-segment trace lines are emitted at `.verbose` and reach os_log's debug level only, never the handler, so the mirrored stream stays readable. `aetherctl` installs exactly this handler, which is why the CLI prints what the app hides.

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

- **[docs/api.md](docs/api.md)**: every public surface a host consumes, and the contracts that require it to act (how a load ends, `.ended`, the live retune, the audio tap, what must be set before `load`, and which FFmpeg your link hands the engine). A test fails the build when a host-facing public symbol is named nowhere in the docs.
- **[docs/architecture.md](docs/architecture.md)**: the three playback pipelines, the source-file map, dependencies, the SwiftUI `Menu` pattern.
- **[docs/formats.md](docs/formats.md)**: codec / container coverage, HDR routing, audio bridging, subtitles, frame extraction, disc playback, live ingest, and known limitations.
- **[docs/cli.md](docs/cli.md)**: the `aetherctl` repro CLI (twenty-one subcommands).
- **[CHANGELOG.md](CHANGELOG.md)**: per-release index.

## Stability and versioning

AetherEngine uses [Semantic Versioning](https://semver.org). The public API surface, every `public` declaration in `Sources/AetherEngine/`, is the stability contract. **Major** removes / renames public symbols or breaks adopters; **Minor** adds public API or codec / format support; **Patch** fixes bugs with no public API change. `internal` types are not part of the contract.

```swift
.package(url: "https://github.com/superuser404notfound/AetherEngine", from: "6.60.0")
```

Pin to `.upToNextMinor(from: "6.60.0")` for stricter teams that prefer to opt into minor bumps explicitly.

## Requirements

| | Min |
| --- | --- |
| iOS | 16.0 |
| tvOS | 17.0 |
| macOS | 14.0 |
| visionOS | 1.0 |
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

The exception covers AetherEngine's own code; it does not extend to its dependencies.

**FFmpeg** reaches your app through [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) as dynamically linked frameworks under plain LGPL-2.1-or-later (no GPL components), which keeps the relink requirement satisfiable for closed-source App Store apps. See FFmpegBuild's README for the per-component licenses and the concrete adopter steps (embed dynamically, ship the license texts, link the build's source). Its [LICENSES/](https://github.com/superuser404notfound/FFmpegBuild/tree/main/LICENSES) folder is the set to reproduce, one file per component.

**libdovi** reaches your app through [LibDovi](https://github.com/superuser404notfound/LibDovi) as a static library. It is the compiled `dolby_vision` crate from [dovi_tool](https://github.com/quietvoid/dovi_tool), Copyright (c) quietvoid and contributors, dual-licensed MIT OR Apache-2.0 and consumed here under the MIT option. MIT asks for that copyright notice to travel with the binary, and it is quietvoid's notice that belongs on the acknowledgements screen. The MIT text in LibDovi's own `LICENSE` covers the packaging and build scripts only; both parts are in that one file.

**SMBClient** ([kishikawakatsumi/SMBClient](https://github.com/kishikawakatsumi/SMBClient), MIT) reaches your app only if you link the `AetherEngineSMB` product. Linking `AetherEngine` alone pulls in none of its symbols, even though SwiftPM still records the package in `Package.resolved`, which describes the resolved graph rather than what the linker kept.

### Linking the engine statically

An SPM library product links statically by default, and for the engine itself that is the intended shape on the App Store path. LGPL-3.0 section 4(d)(0) would otherwise ask for your application's object code in a relinkable form; the exception's fourth bullet names end-user re-linking explicitly, so that half does not apply. What the exception does not waive is the source side: point at the exact tag you built against rather than the repository root, and if you patched the engine, publish the patched source under LGPL. No separate written offer is needed while that pointer resolves. The dependencies above keep their own terms either way, which is why the FFmpeg frameworks have to stay dynamically embedded in `YourApp.app/Frameworks/` instead of merged into the app binary.

Being dynamic is not the same as being reached. The engine calls `avcodec_*` as ordinary external symbols, so a second FFmpeg elsewhere in the app can serve them instead: a static archive pulled in with `-force_load` becomes a definition inside your executable and beats every dylib, and a dependency that exports the same symbols (libVLC does, and CocoaPods sorts a pod ahead of a vendored framework) wins on order alone. Link AetherEngine's frameworks first. `nm -m <executable> | grep _avcodec_find_encoder` says who currently wins; the engine's own startup line says the same thing from the inside.
