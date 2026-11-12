# Host guide

How to build a player on AetherEngine, from the first frame to live TV. Each section shows the code first and explains it after. The complete API, including every contract the host must answer, is in [api.md](api.md). Installing the package is in [installation.md](installation.md).

- [First player](#first-player)
- [Loading](#loading)
- [Transport](#transport)
- [Reading the session state](#reading-the-session-state)
- [Time](#time)
- [Audio and subtitle tracks](#audio-and-subtitle-tracks)
- [Discs and chapters](#discs-and-chapters)
- [Now Playing](#now-playing)
- [Drawing your own overlay in sync](#drawing-your-own-overlay-in-sync)
- [Custom input](#custom-input)
- [SMB shares](#smb-shares)
- [Live TV and DVR](#live-tv-and-dvr)
- [IPTV timeshift and catch-up archives](#iptv-timeshift-and-catch-up-archives)
- [tvOS host setup](#tvos-host-setup)
- [Diagnostics](#diagnostics)
- [Samples](#samples)

## First player

```swift
import AetherEngine
import SwiftUI

struct PlayerScreen: View {
    let player: AetherEngine   // one engine for the app's lifetime: `try AetherEngine()`
    let videoURL: URL

    var body: some View {
        AetherPlayerSurface(engine: player)
            .task { try? await player.load(url: videoURL) }   // plays on its own: `autoplay` defaults to true
    }
}
```

In UIKit / AppKit, create an `AetherPlayerView`, call `player.bind(view:)` with it, then `load`. The complete runnable app is [`Examples/MinimalPlayer`](../Examples/MinimalPlayer/MinimalPlayerApp.swift).

The engine gives you one view (`AetherPlayerView` for UIKit / AppKit, `AetherPlayerSurface` for SwiftUI) and a set of `async` methods. There is no `AVPlayerViewController`, no built-in controls and no analytics. You bind the view, load, and read the published properties for state. Create the engine once and reuse it for every title. Call `play()` yourself only after a load with `autoplay: false`. You build the transport bar and menus.

The view adapts by itself: per session the engine swaps the hosted layer (`AVPlayerLayer` on the native AVPlayer path, `AVSampleBufferDisplayLayer` on the software dav1d path). The host does not need to know which one is active.

## Loading

```swift
try await player.load(url: videoURL)
try await player.load(url: videoURL, startPosition: 347.5)       // resume position
try await player.load(url: videoURL, options: .init(
    httpHeaders: headers,              // sent with every demux and segment fetch
    matchContentEnabled: matchContent  // tvOS Match Content master switch
))
try await player.load(url: trackURL, options: .init(audioOnly: true))   // lean audio path
try await player.reloadAtCurrentPosition()   // reopen in the background, keeps options and transport
```

A `CancellationError` out of `load()` means a newer load replaced this one. It is not a failure. How every other failure arrives is in [api.md › How a load ends](api.md#how-a-load-ends).

## Transport

```swift
player.play()
player.pause()
player.togglePlayPause()
player.setRate(1.5)        // clamped to player.maxSupportedRate (2x video, 3x audio-only)
await player.seek(to: 120)
player.stop()
```

## Reading the session state

All of these are Combine `@Published` properties on the engine.

| Property | What it tells you |
| --- | --- |
| `$state` | `.idle`, `.loading`, `.playing`, `.paused`, `.seeking`, `.ended`, `.error(String)` |
| `$errorInfo` | `PlaybackErrorInfo?`, the machine-readable half of `.error` |
| `$playbackPhase` | One status for a spinner: `.idle`, `.loading`, `.playing`, `.paused`, `.seeking`, `.rebuffering`, `.stalled(reconnecting:)`, `.ended`, `.error` |
| `$duration` | Length of the media |
| `$videoFormat` | `.sdr`, `.hdr10`, `.hdr10Plus`, `.dolbyVision`, `.hlg` |
| `$isSeeking`, `$seekTarget`, `seekEvents` | Seek progress (see below) |
| `$videoRoute` | Which pipeline serves the session |
| `$audioDelivery` | How the audio reaches the renderer |
| `$hasFirstFrameReadyForDisplay` | A first picture is ready, the moment to remove a black cover |
| `$startupProgress` | Progress for a determinate loading bar |
| `$currentAVPlayer` | The active AVPlayer, for `MPNowPlayingSession` |

**`state`.** `.idle` means before a load or after `stop()`. `.ended` means the media played to the end (on any backend) and is **terminal**: seeks are rejected and `play()` does not revive it, so a replay is another `load()`. A VOD that is only parked at its final frame is a different case, and `play()` rewinds it.

**`errorInfo`.** Classify errors on this, not on the message. It holds a stable `PlaybackErrorKind` plus the underlying NSError domain and code. The message on the native paths is `AVPlayerItem.error.localizedDescription` passed through unchanged, so it is in the device's language, and a substring rule over it files every non-English device as unknown. `errorInfo` is set before `.error` is published and cleared when the state leaves it.

**`playbackPhase`** is derived from state, `isBuffering`, `isSeeking` and source reconnects. Prefer it to stitching the raw signals together or matching `EngineLog` text.

**Seeking.** `$isSeeking` stays true until a seek physically lands. That covers programmatic seeks, native scrubs, and seeks stashed before the session could take them. `$seekTarget` is the destination of the seek in flight (source PTS), otherwise nil. Use `seekEvents` (`AnyPublisher<SeekEvent, Never>`) where the end of a seek matters. It reports `.began`, `.landed(renderedTime:)`, `.stalled`, `.superseded` and `.rejected`, each with its target. `$isSeeking` alone cannot tell you whether a seek landed, gave up or was replaced, and a seek that gave up can still land minutes later on a stalled source.

**`videoRoute`** is `.remoteBypass` (AVPlayer on the origin URL), `.loopback`, `.software`, `.audio` or `.none`. `LoadOptions.nativeRemoteHLS` is only a request: the carriage watchdog, the remembered verdict and the HLS reroutes move a session between the bypass and the loopback, also mid-session. Branch on `videoRoute` where behaviour differs per pipeline, above all for who draws subtitles: on `.remoteBypass` AVPlayer renders the origin's renditions, everywhere else the host does.

**`audioDelivery`** is `.streamCopy`, `.bridged`, `.decoded`, `.noAudioInSource`, `.playerManaged` (AVFoundation owns it), `.none`, or `.droppedNoPipeline`. The last one means the source has audio but none of it could be delivered (no decoder in this build, or the bridge could not be built), so the session plays video-only and silent. A fallback ladder demotes on that value, the same way it demotes on `PlaybackErrorKind.audioBridgeProducedNoOutput`. Classify on `audioDelivery`; `$activeAudioDecoder` is a label for humans and cannot tell a source without audio from one that lost it.

**`hasFirstFrameReadyForDisplay`** turns true when the running path has a first frame ready for the media this load opened. Lift a black cover on this edge. `readyToPlay` is not that edge: AVFoundation reaches it before the layer holds a picture, and it stays true across a seek, so a cover lifted on `isSessionReady` reveals black. The value is latched for the load and goes back to false at the next `load()` or `stop()`. To know whether a seek has reached the screen, use `seekEvents` `.landed`.

**`startupProgress`** (`StartupProgress?`) drives a determinate loading bar: `.completed` of `.total` checkpoints, `.fraction`, and `.stage` naming the work in flight.

- Every value is work that actually finished, never a timer or an estimate. A slow stretch holds, a skipped one jumps.
- It covers the two stretches a host cannot otherwise see: opening the source (connection, container, stream analysis) and the display-criteria handshake.
- It is scoped to `.generation`, which counts the startups a user waited through rather than teardowns. An engine-initiated reroute continues the bar instead of resetting it.
- Monotonic and deduplicated. nil before the first load and after `stop()`. A load that fails never reaches the last checkpoint.

**`currentAVPlayer`** is re-emitted on every reload. It is nil on the `.software` route, because that pipeline renders into its own display layer and AVKit must not hold a player nothing feeds. So a host that only hands `currentAVPlayer` to an `AVPlayerViewController` gets audio and AVKit's spinner over an empty picture on that route (#298). Bind a surface for it, and choose the presentation from `$videoRoute`, not from the source codec.

## Time

```swift
player.clock.$currentTime       // ~10 Hz playback clock (transport, scrubbing, resume)
player.clock.$sourceTime        // source PTS of the displayed frame (render subtitles against this)
player.clock.$bufferedPosition  // source-axis position buffered ahead; buffer bar = bufferedPosition / duration
```

Time lives on `player.clock`, a separate `ObservableObject`. The ~10 Hz ticks therefore never fire `objectWillChange` on the engine: views that show track lists or state do not re-render per tick, and native tvOS `Menu` dropdowns stay stable. The 1 Hz diagnostics snapshot lives on `player.diagnostics.liveTelemetry`, apart from the engine for the same reason.

## Audio and subtitle tracks

```swift
// Tracks
player.audioTracks                        // [TrackInfo]
player.selectAudioTrack(index: trackID)
player.subtitleTracks                     // [TrackInfo]: text, bitmap and external in one list
player.selectSubtitleTrack(index: streamID)
player.clearSubtitle()
player.$subtitleCues                      // [SubtitleCue]: .text(String), .richText([SubtitleTextRun]) or .image(SubtitleImage)
```

### Styled text

```swift
for cue in player.subtitleCues {
    if case .richText(let runs) = cue.body { render(runs, at: cue.placement) }
}
```

Styled text arrives as `.richText` (#233). A run carries colour, bold, italic, underline, strikeout, font face and an ASS-relative font size. The cue carries the placement it asks for: numpad alignment plus an optional [0, 1] anchor.

- This covers SRT, WebVTT, teletext and ASS alike, because libavcodec turns them all into ASS event lines before the engine sees them.
- A cue without styling still arrives as `.text`, so code that handles only that case keeps working.
- Exception: libavcodec does not convert WebVTT cue settings, so VTT positioning does not arrive. Its inline bold, italic and underline do.

Cues are stamped in raw source PTS. Render the overlay against `player.sourceTime` ([formats.md › Subtitles](formats.md#subtitles)).

### External subtitle files

```swift
let track = player.addExternalSubtitleTrack(
    ExternalSubtitleTrack(url: srtURL, name: "English", language: "en"))
player.selectSubtitleTrack(index: track.id)

// Declared at load, external tracks also join the native WebVTT renditions (PiP):
LoadOptions(prepareNativeSubtitles: true,
            externalSubtitles: [ExternalSubtitleTrack(url: srtURL, language: "en")])

// A container holding several subtitle streams: one track per stream, with its absolute AVStream index
ExternalSubtitleTrack(url: mkvURL, name: "Spanish", language: "es", sourceStreamIndex: 3)
```

External files are first-class tracks (#88). They appear in `subtitleTracks` with `isExternal == true` and a synthetic id, and you select them with the same call as embedded streams. Tracks that share a URL are decoded in one pass (#266).

### Native subtitle renditions (PiP, AirPlay, external display)

```swift
player.$nativeSubtitleTracks               // [NativeSubtitleTrack]: ordinal, language, displayName
player.setNativeSubtitleSelected(track: 2) // engage a rendition (for example on PiP entry); nil deselects
```

Opt in with `LoadOptions.prepareNativeSubtitles`. Details in [formats.md](formats.md#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display).

### Captions the system turned on

```swift
player.systemCaptionRequest   // PassthroughSubject<SystemCaptionRequest, Never>, subscribe per session
```

iOS 26 can turn captions on by itself (Settings > Accessibility > Subtitles & Captioning > Automatic Subtitles: when muted, on skip back, on a language mismatch). Those settings have no read API, so the selection is the only sign of the request. The engine deselects the option, because a rendition drawn in fullscreen puts a caption box over the host's own subtitles, and forwards the request here. A host that wants the behaviour picks its own matching track.

### A second subtitle track at the same time

```swift
player.selectSecondarySubtitleTrack(index: streamID)
player.selectSecondarySidecarSubtitle(url: srt2URL)
player.clearSecondarySubtitle()
player.$secondarySubtitleCues        // [SubtitleCue] for the secondary track
player.$isSecondarySubtitleActive    // Bool
```

For bilingual viewing and language learning.

## Discs and chapters

```swift
// DVD-Video / Blu-ray ISO (empty for other sources)
player.$discTitles             // [TitleInfo]: id, name, durationSeconds, chapterCount, playlist (Blu-ray .mpls), titleSet (DVD VTS) (longest first, id 0 is the main feature)
player.$selectedDiscTitle      // TitleInfo?
player.selectTitle(id: titleID)       // switch title (rebuilds from the new title's start)
player.$discChapters           // [ChapterInfo] for the selected title
player.selectChapter(id: chapterID)   // seek to a chapter (disc chapters only)

// Matroska / MP4 chapters (empty for discs, which publish discChapters instead)
player.$mediaChapters          // [ChapterInfo]; startSeconds are seek(to:) values, 0-based like currentTime
```

## Now Playing

```swift
// Info panel (AVPlayerViewController hosts; AVKit also republishes it as Now Playing)
player.setExternalMetadata([ AVMetadataItem(/* title, artwork, ... */) ])

// System Now Playing for hosts with their own transport, on every platform. Set before load().
player.ownsVideoNowPlayingSession = true        // native video
player.ownsVideoNowPlayingCommands = true       // the engine also answers the remote commands
player.ownsSoftwareNowPlaying = true            // software host (no AVPlayer)
player.ownsAudioNowPlaying = true               // audio-only sessions
player.setNowPlayingInfo([ /* MPMediaItemProperty... */ ])   // identity for whichever route load() picks
```

Every opt-in is off by default. A host using `AVPlayerViewController` already gets Now Playing from AVKit and must **not** set `ownsVideoNowPlayingSession`. A host with its own transport sets the ones it needs before `load()` and stages the item's identity with `setNowPlayingInfo`. Without `ownsVideoNowPlayingCommands`, the host registers the commands itself on `videoNowPlayingSession.remoteCommandCenter`. Playlists, command interception and several engines in one process: [api.md › Now Playing and the audio session](api.md#now-playing-and-the-audio-session).

## Drawing your own overlay in sync

Hosts that composite their own overlay (libass and similar) need to know exactly when each frame is shown. Both paths offer this, and both return nothing rather than a guess when no axis is established yet, because a default value would look the same as a measured one.

### Native path

```swift
player.presentationAxisMap                       // converts both ways, readable off the main actor
player.presentationAxisMap.itemSeconds(forSourceSeconds: cue.startTime)    // stamp an overlay sample
player.presentationAxisMap.sourceSeconds(forItemSeconds: item.currentTime().seconds)
player.$currentAVPlayerItem                      // items are swapped in place; this signals it

player.setNativeVideoFrameTimeObserver { frame in
    frame.source; frame.item; frame.segmentIndex; frame.isKeyframe; frame.epoch
}
```

Cue times, chapters and `sourceTime` are on the **source** axis. `AVPlayerItem.currentTime()` and its timebase read the **item** axis. The two differ by the producer shift, which changes at every producer epoch (a seek restart, a live program boundary) (#260). The compositor pairs its samples on the item axis, so a host overlay needs it too.

The frame observer is called per muxed video frame, with both axes at once. It runs on the producer's pump thread in **decode** order, so `source` is not monotonic with B-frames: sort before using it as a list of frame boundaries. `epoch` rises strictly and process-wide. A restart and a `load()` both continue the sequence, so "a higher epoch retires my older entries" separates one item's frames from the next.

### Software path

```swift
player.softwarePresentationTimebase              // the master clock, on the source axis
player.setSoftwareVideoFrameTimeObserver { frame in
    frame.presentation; frame.generation
}
player.softwareDisplaySize                       // CGSize?, @Published
```

Here the engine decodes itself and enqueues the source timestamp unchanged (#311). There is one axis and no segments, and reports arrive after the reorder buffer, in **ascending** presentation order. `generation` changes on every renderer flush (that is, on a seek) and rises across a `load()` the same way `epoch` does.

`softwareDisplaySize` is the rectangle the frames land in (#353): the coded size under the pixel aspect ratio the decoder attached, read from the format description the renderer enqueues. Do not lay out against `sourceVideoWidth` / `sourceVideoHeight`: those are the coded size, so anamorphic content is off by the pixel aspect (720x576 at 64:45 presents as 1024x576). nil off the software path and before the first frame. It follows a mid-stream format change and is cleared with the session. The native path measures its own rectangle on `AVPlayerLayer.videoRect`.

## Custom input

```swift
final class MyArchiveReader: IOReader {
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { /* ... */ }
    func seek(offset: Int64, whence: Int32) -> Int64 { /* ... */ }  // AVSEEK_SIZE (65536) returns the total size
    func close() { /* ... */ }

    // Optional, with defaults. Override them to unlock more features:
    func cancel() { /* unblock a blocked read at teardown; do NOT invalidate the reader */ }
    func makeIndependentReader() -> IOReader? { /* a fresh cursor over the same source, or nil */ }

    // Optional, defaults to true. Return false when this is known to be an
    // ordinary media file rather than a raw ISO/UDF disc image.
    var discImageProbeEnabled: Bool { false }
}

let probe = try await engine.load(source: .custom(MyArchiveReader(), formatHint: "mp4"))
// load() returns the probe metadata it gathered (discardable).
// AetherEngine.probe(source:) probes once without starting playback.
```

What a reader unlocks:

| Reader | Features |
| --- | --- |
| Seekable | Playback, seeking, audio-track switching, background reload |
| Seekable with `makeIndependentReader()` (a second cursor) | Also embedded subtitles and scrub-preview thumbnails |
| Forward-only | Plain playback and seeking (VOD on the software path; live sessions stay native) |

**Security note.** On the native path, a custom reader's bytes are re-muxed to cleartext fMP4 in the loopback cache. That is fine for archives encrypted at rest, but it exposes content-protected sources in cleartext. Full contract in [formats.md › Custom byte sources](formats.md#custom-byte-sources-ioreader).

## SMB shares

```swift
import AetherEngineSMB

let smb = try await SMBConnection.connect(
    server: URL(string: "smb://nas.local")!, share: "media",
    path: "Movies/film.mkv", user: "alice", password: "s3cret"
)
try await engine.load(source: .custom(
    SMBIOReader(source: smb, discImageProbeEnabled: false),   // an ordinary file, not a disc image
    formatHint: "matroska"
))
```

SMB support is a ready-made `IOReader` in the separate `AetherEngineSMB` product. Add that product next to `AetherEngine` only if you need it; hosts without SMB link only the core. It uses [SMBClient](https://github.com/kishikawakatsumi/SMBClient) (MIT, pure Swift, built on `NWConnection` over Network.framework), not libsmb2, which fails with `EPERM` on tvOS and iOS.

- **Ordinary media files:** construct the reader with `discImageProbeEnabled: false` to skip the ISO/UDF signature reads. Keep the default for raw disc images, so DVD and Blu-ray recognition still works.
- **Auth:** read-only, NTLMv2, guest or anonymous (an empty user tries guest, then anonymous). No Kerberos.
- **tvOS:** the host must declare `NSLocalNetworkUsageDescription` and the local-network entitlement to reach a LAN share.
- **Testing a share from macOS:** [`aetherctl smbtest`](cli.md#smbtest).
- **Known limit:** SMBClient negotiates only SMB 2.0.2 and 2.1. There is no SMB3 transport encryption or AES-CMAC signing, so servers set to SMB3-only or `smb encrypt = required` do not connect. (libsmb2 spoke 3.1.1, but does not work on tvOS / iOS at all.)

## Live TV and DVR

### Playing a channel

```swift
// Live only (seek() does nothing), or live with timeshift:
try await player.load(url: streamURL, options: LoadOptions(isLive: true))
try await player.load(url: streamURL, options: LoadOptions(isLive: true, dvrWindowSeconds: 1800))

// Lean-back live that may wait for the full 3 x TARGETDURATION holdback before the first picture:
try await player.load(url: streamURL, options: LoadOptions(isLive: true, liveJoinProfile: .standard))

// Scrubber fields (they tick, so they live on player.clock):
player.clock.$seekableLiveRange   // ClosedRange<Double>?, session-relative; nil when DVR is off
player.clock.$behindLiveSeconds   // seconds behind the live edge; 0 at the edge
player.clock.$liveEdgeTime
await player.seekToLiveEdge()
await player.seek(to: player.liveEdgeTime - 300)   // 5 minutes back

// The retune request: the engine stopped the session and only a fresh URL can revive it
player.liveSourceReset            // PassthroughSubject<Void, Never>; subscribe per session

// Ingest a live HLS upstream directly, with no media server in between:
try await player.load(
    source: .custom(HLSLiveIngestReader(playlistURL: upstreamM3U8), formatHint: "mpegts"),
    options: LoadOptions(isLive: true, dvrWindowSeconds: 600)
)
```

### Fast channel start: `liveJoinProfile`

`liveJoinProfile` defaults to `.fastZap` (#195, #208). It trades a little robustness for a faster first picture.

- It cuts live segments at every keyframe after 0.5 s instead of the standard ~4 s. The served `TARGETDURATION` drops to 1.5 x the source GOP length (1 s GOPs serve 2, and so do segments up to 1.666 s; the headroom covers a broadcast's irregular GOPs, #670).
- The live-edge holdback (`HOLD-BACK` = 3 x `TARGETDURATION`, the RFC 8216bis floor, #189) shrinks with it.
- The first manifest still prefers the full holdback. After two finalized segments, a strict-realtime source gets one observed-segment grace, clamped to 0.5...2.0 s. Then a shallow first window may be served so startup stays bounded. This can cause one early `-16832` or a short rebuffer.
- A smaller `TARGETDURATION` also makes AVPlayer less patient with an unchanged playlist and keeps a smaller live-edge buffer. Origins that stall or burst mid-stream rebuffer more easily.

`.standard` keeps the full-holdback guarantee. Pick it for lean-back viewing that can afford the full wait.

### The retune request: `liveSourceReset`

**A host that plays live must subscribe to `liveSourceReset`.** It is live's version of a terminal `state = .error`. It fires when the session cannot be revived from inside the engine and only a new URL can help:

- the source restarted from byte 0 (a Jellyfin transcode respawn),
- the playlist is still frozen after the stall ladder's last reload step (#65),
- an in-engine reopen transport has used up its budget (#199),
- a verified replay cannot reach new media (unless you opt into `hostRetriesExhaustedLiveReplay`, which publishes `liveSourceReplayExhausted` instead; see [api.md › Live: exhausted verified replay](api.md#live-exhausted-verified-replay)).

In each case the engine stops production first, so a dead provider no longer advertises blocking reloads behind the host's back.

How to answer it:

1. After your own backoff, call `retryLiveSourceRecovery()`. It renews the source in place and keeps the DVR window.
2. If it returns `false`, negotiate a fresh URL and call `load` again.
3. Guard the answer: one recovery in flight, a minimum spacing, a bounded count per session. Otherwise a permanently dead upstream turns into a retune loop.
4. When the bound runs out, show it the way you would show a terminal `.error`. A retune ladder that ends on a silent `return` leaves the dead channel on screen behind a counter.

**A host with a fixed URL** (an IPTV channel) answers by loading the same URL again. That is cheap, not a no-op. The #168 carriage verdict (a master advertising HEVC while delivering MPEG-TS) is remembered per exact absolute URL for six hours, 32 entries, so the retune goes straight onto the live ingest and skips the doomed native mount and its watchdog grace. A URL with a rotated per-session token misses that memory and pays the one-time discovery again on every retune. Keep that in mind if you measure a first-frame budget against the retune.

**If you do not subscribe,** a channel can stop while the engine still reports a session. From the outside that looks exactly like a slow channel.

### Recording a channel

```swift
try await player.startRecording(to: fileURL)
await player.stopRecording()
player.$recordingState            // .idle / .recording / .ended / .failed
```

`startRecording(to:)` (#560) writes the live source to an MPEG-TS file, fed from the connection the session already holds. That is the point of it: IPTV plans often allow only 1 to 3 simultaneous connections, so a host that opens its own connection to record either fails or knocks the viewer off the channel.

- It is a stream copy of the source packets, taken before any audio bridging. A TrueHD or DTS channel records its original audio while playback uses the bridged version.
- A file cut short by a crash still plays up to the cut.
- Recording follows the source, not the playhead. Pausing or scrubbing back inside the DVR window does not interrupt it.
- A `liveSourceReset` ends it cleanly instead of writing past a seam the codecs may not survive.
- It cannot record on `nativeRemoteHLS` (`.remoteBypass`), where AVFoundation holds the connection and the engine never sees a byte. `startRecording` throws `.unsupportedRoute` there instead of writing an empty file.

Full contract in [api.md › Recording a live stream](api.md#recording-a-live-stream).

### Direct HLS ingest

The ingest covers MPEG-TS with demuxed-audio and packed-audio renditions, in-line AES-128 clear-key decryption, and SSAI ad-pod direct play (versioned init segments, audio re-anchoring, no-cut watchdog). Unsupported encryption and fMP4 playlists throw a typed `HLSIngestError`, so the host can fall back. Details in [formats.md › Live ingest](formats.md#live-ingest-aes-128-ssai).

**Subtitle renditions** (#359). If a channel's master declares an `EXT-X-MEDIA:TYPE=SUBTITLES` group, those renditions show up as ordinary entries in `subtitleTracks`. The ingest only demuxes the chosen video variant, so the engine reads the group from the master. Once `selectSubtitleTrack(index:)` picks one, it fetches that rendition's WebVTT segments and publishes the cues on the host-overlay surface, placed by the shared `EXT-X-PROGRAM-DATE-TIME` timing rather than by `X-TIMESTAMP-MAP`. Nothing is fetched until a track is selected. Details in [formats.md › Live HLS subtitle renditions](formats.md#live-hls-subtitle-renditions-host-overlay).

### Which route a remote HLS source takes

| Source | What happens |
| --- | --- |
| A standard remote `master.m3u8` (for example a Jellyfin live channel) with `LoadOptions.nativeRemoteHLS` | Goes straight to AVPlayer, skipping the demuxer probe and the loopback server. AVPlayer handles the live edge and reconnects. |
| A live master that advertises HEVC (or Dolby Vision / AV1) but delivers MPEG-TS | Rerouted onto the live ingest (#168) |
| A live `nativeRemoteHLS` bypass that the origin refuses (HTTP 401 / 403) | Handed to the live ingest (#363) |
| A live remote `m3u8` on the default (loopback) path | Rerouted onto the live ingest (#363) |
| A non-live remote `m3u8` on the default (loopback) path | Rerouted onto the AVPlayer bypass (#154) |

**`nativeRemoteHLS`.** Pair it with `isLive: true`. `LoadOptions.httpHeaders` go into the `AVURLAsset` on this path, so origins that require per-stream `Referer`, `User-Agent` or `Authorization` headers (common for IPTV) work too.

**HEVC in MPEG-TS** (#168). AVFoundation builds no video track for this carriage, so the bypass would play audio over black. The engine recognizes the pattern and moves the session to the live ingest. The check runs alongside the mount: the playlist and the head of one segment are read while AVPlayer starts, so the reroute does not wait out a grace window. A media playlist URL with no master is covered too (#293). Only a codec the HLS Authoring Spec allows in fMP4 alone triggers that read, so an H.264 channel spends no extra request on it.

**Refused by the origin** (#363). HTTP 401 and 403 reach the item as `NSURLError` -1013 / -1102. Instead of failing the load, the engine hands the session to the ingest. The ingest fetcher behaves differently at the origin: it sends the configured headers on every request, limits itself to four concurrent fetches, and sends no AVFoundation user agent. So a user-agent filter or a per-token connection limit that turned AVPlayer away may still serve it. This refusal is not remembered for the next load (unlike the carriage verdict), because a token expires and a connection limit frees up.

`LoadOptions.nativeRemoteHLSIngestFallback = false` turns off both recoveries above.

**Live `m3u8` on the loopback path** (#363). The raw live path reads bytes, not playlists. It used to reject an `.m3u8` with a typed `hlsPlaylistOnRawLivePath` error that named the reader the host should have built. Now it builds that reader itself, with `LoadOptions.httpHeaders` on the playlist, every segment and every AES key, which is what a tokenized IPTV origin checks per request. Credential headers stay with the playlist's own origin: a segment or key on another host, or on http:// behind an https:// playlist, gets the other headers but not the token. A custom `IOReader` with the same mistake still gets the typed error, because it has no playlist URL to ingest from.

**Non-live `m3u8` on the loopback path** (#154). The bundled FFmpeg is built without network support, so the playlist can never be demuxed locally, and remote HLS is AVPlayer's job anyway. On the bypass, the engine lists the stream's external WebVTT renditions (the legible `AVMediaSelectionGroup`) as `subtitleTracks`. `selectSubtitleTrack(index:)` and `clearSubtitle()` drive AVPlayer's media selection, and AVPlayer draws the cues.

**Sidecar subtitles on the bypass** (#316). Files declared in `LoadOptions.externalSubtitles` become renditions here too. Media selection on an HLS asset only comes from the playlist, so for a VOD source the engine:

1. fetches the origin master,
2. rewrites every variant, audio and key URI to an absolute origin URL,
3. adds one `EXT-X-MEDIA:TYPE=SUBTITLES` entry per sidecar,
4. serves that master from the loopback origin.

AVPlayer still fetches all audio and video straight from the origin, so E-AC-3 / Atmos passthrough is untouched; only the master and the WebVTT renditions are local. The tracks keep their external ids, and selecting one drives media selection instead of the host overlay, so the subtitle survives PiP, AirPlay and a wired external display. Live sources (no `EXT-X-ENDLIST`), bitmap sidecars, a playlist that cannot be rewritten and a slow origin all fall back to the origin URL with host-overlay subtitles (the behaviour before #316). The load never fails because of this.

## IPTV timeshift and catch-up archives

```swift
// An origin that answers every Range with a plausible 206 whose body is not at that offset:
try await player.load(url: archiveURL, options: LoadOptions(
    sequentialOrigin: true,             // only byte 0 is addressable
    declaredDurationSeconds: 8100       // required on VOD; there is no tail read to estimate it
))
```

Timeshift and catch-up archives often fake range answers: `Range: bytes=X-` returns `206` with a body that really starts at a coarse internal chunk boundary. No header reveals this, so the host declares it (#346). The engine then:

- runs one long-lived unranged GET, with no ranged probes, no byte-offset reconnects and no tail read;
- treats the demuxer's pb as non-seekable;
- reports a dropped connection as a read error, not end-of-media, so the host can request again;
- keeps the native path instead of forcing software;
- serves an append-only `EVENT` playlist with the durations actually muxed, completed with `ENDLIST` at the real end of the source.

Every producer reposition is refused by design. A seek lands only inside what the session already holds (on the native path, the resident span that reaches the producer's frontier). For any other target, and for an audio track switch, request the archive again with a shifted start timestamp and pass `audioSourceStreamIndex` for the chosen track (#958). To reproduce one from macOS: `aetherctl play --sequential-origin --declared-duration`.

## tvOS host setup

### Let the engine drive the display switch

On tvOS 26.5+, HDR and Dolby Vision sources only play reliably when the engine sets `AVDisplayManager.preferredDisplayCriteria` itself, synchronously, before it assigns the `AVPlayerItem`.

```swift
// In your AVPlayerViewController subclass
playerVC.appliesPreferredDisplayCriteriaAutomatically = false

// When loading
try await engine.load(url: url, options: LoadOptions(
    displayCriteriaOwner: .engine,       // default; the engine writes the criteria
    matchContentEnabled: matchContent,   // tvOS Match Content master switch
    panelIsInHDRMode: panelInHDRMode,    // assertion: the panel is presenting HDR now
    panelPresentsDolbyVision: false      // assertion: this display presents Dolby Vision
))
```

Why: Apple Tech Talk 503 has prescribed this order since 2017, and tvOS 26.5 enforces it during HLS variant validation. The validator rejects variants whose `VIDEO-RANGE` the panel cannot show right now with `AVFoundationErrorDomain -11868`, before it even fetches the `EXT-X-MAP` init segment. The result is `item.status = .failed` with zero `errorLog().events`. SDR variants are not affected.

AVKit's automatic criteria (`appliesPreferredDisplayCriteriaAutomatically = true`) cannot solve this for HLS multivariant HDR sources. AVKit reads the criteria from `AVAsset.preferredDisplayCriteria`, which comes from the chosen variant's format description, which exists only after `init.mp4` is parsed, which only happens after the variant passed the validator. A chicken-and-egg problem. The engine as the sole writer of the criteria is the pattern that works.

`displayCriteriaOwner` defaults to `.engine`, so this is the default. The engine writes the criteria before it assigns the item and waits up to about 2 s for the switch to start and settle. A VOD load keeps producing segments meanwhile; a live load waits behind it. `play()` is then held until the switch ends, and `isAwaitingDisplaySwitch` is true during that hold.

`displayCriteriaOwner` has three values ([AE#842](https://github.com/superuser404notfound/AetherEngine/issues/842)):

| Owner | Who writes the criteria | Pick it when |
| --- | --- | --- |
| `.engine` (default) | The engine, before the item loads | Almost always, for the reason above |
| `.avKit` | AVKit, from the item (`appliesPreferredDisplayCriteriaAutomatically = true`). The engine holds `play()` up to a second for that write on HDR and Dolby Vision content | You keep AVKit's automatic criteria |
| `.host` | You, before `load()`, or nobody. The engine never writes and waits only for a switch it sees running | The panel should stay in the output format the user chose in tvOS Settings, or you write rate-only criteria yourself |

`suppressDisplayCriteria: true` is the older spelling of `.avKit` and still works.

### The two panel flags

**Both flags are assertions, not readings, and both default to `false`.** An assertion only ever adds, so neither flag can hide a capability the system reports. A wrong one costs a single in-place media-playlist fallback (`-11868` / `-11848`) at the same position, not the item.

- **`panelIsInHDRMode`** is OR-ed with the engine's own EDR-headroom reading. That reading only answers around a dynamic-range change, so an Apple TV whose output is locked to HDR never makes one and reads as an SDR panel forever ([#459](https://github.com/superuser404notfound/AetherEngine/issues/459)).
- **`panelPresentsDolbyVision`** covers what the engine cannot observe at all on macOS: there is no `AVPlayer.availableHDRModes`, and HDR eligibility answers HDR10 and HLG but not Dolby Vision ([#493](https://github.com/superuser404notfound/AetherEngine/issues/493)).

**What `panelPresentsDolbyVision` still changes.** For a Profile 5, 8.1 or 8.4 source nothing in the packaging: since 6.72.0 / 6.73.0 those serve the same manifests and segments with or without the claim. It still gates the Profile 7 to 8.1 conversion, the AV1 Dolby Vision record, and HDR readiness on the route. The `-15628` stall an HDR10-only panel once showed on Dolby Vision packaging ([#4](https://github.com/superuser404notfound/AetherEngine/issues/4)) did not reproduce on tvOS 26.6.

**`attemptsHDRMasterOnUnprovenPanel`** (default `true`) is the engine's own answer to the unreliable headroom reading above: it serves the HDR master to an HDR-eligible display whose mode is unproven and lets AVFoundation's acceptance or refusal decide. A refusal costs one in-place fallback, once per process.

**Dolby Vision on a panel without it.** `forceDolbyVisionOnNonDVDisplay` is **experimental** and off by default. It serves a Profile 8.1 (or converted Profile 7) source as Profile 5, so AVPlayer composes the Dolby Vision itself instead of handing the panel the HDR10 base layer ([#455](https://github.com/superuser404notfound/AetherEngine/issues/455)). The risk: a tvOS build that reads the base layer's colours from the profile field would show a green / violet cast. Asserting `panelPresentsDolbyVision` turns it off. Details in [api.md › forceDolbyVisionOnNonDVDisplay](api.md#forcedolbyvisiononnondvdisplay).

### Between items

Back-to-back `load()` calls keep the applied criteria across the seam. A follow-up in the same mode (a Dolby Vision episode after a Dolby Vision episode) overwrites them in place with one handshake, instead of bouncing the panel through SDR.

If your host calls `stop()` between items, use `stop(resetDisplayCriteria: false)` for the same result ([#128](https://github.com/superuser404notfound/AetherEngine/pull/128)). The plain `stop()` returns the panel to its default mode, which is right when leaving playback for the app UI. Audio-only sessions and suppressed hosts clear leftover criteria automatically.

### Who owns the audio session

The engine sets the audio session category at the first load but never activates it on the native path. AVKit activates it per playback, and that is what lets tvOS negotiate the HDMI route ([#24](https://github.com/superuser404notfound/AetherEngine/issues/24)). So the engine never releases it either. On an E-AC-3 / Atmos passthrough route the sink can then keep looping the last MAT frame after the player is gone.

If your app owns the session (no UI sounds, TTS or `AVAudioEngine` of its own competing with playback), set `engine.deactivatesAudioSessionOnStop = true`. The engine then releases the session on a real final teardown, meaning `stop()`, never on a reload, handoff or live retune. It is off by default, because an app that plays its own audio would otherwise lose its session when playback ends.

### SwiftUI `Menu` in custom player controls

On tvOS 26 the focused row of an open SwiftUI `Menu` blinks on any render transaction in the tree. Build the menu button in UIKit (`UIButton.menu` + `showsMenuAsPrimaryAction`) and guard `updateUIView` so the open dropdown never rebuilds. The pattern is in [architecture.md › SwiftUI Menu](architecture.md#swiftui-menu-in-custom-player-chrome).

## Diagnostics

### Where the log goes

Every diagnostic line goes to `os.Logger` under the subsystem `de.superuser404.AetherEngine`, with one category per area: `engine`, `session`, `demux`, `muxer`, `hls.server`, `audio.bridge`, `sw.playback`, `scrub`, `ffmpeg`. Release builds log too. Console.app with the device attached, or `log stream --predicate 'subsystem == "de.superuser404.AetherEngine"'`, shows the lines without a debugger.

### Mirroring the log into your app

os_log is not stdout. A test rig that only captures stdout / stderr (`devicectl device process launch --console`, CI harnesses) sees none of it. Mirror the lines with a handler:

```swift
EngineLog.handler = { print($0) }   // every info-level line, verbatim

// Or with the category, for a viewer that files lines by area:
EngineLog.structuredHandler = { line, category, level in viewer.append(line, from: category.rawValue) }
```

- The handler fires on whatever thread logged the line (demuxer, producer pump, local server, audio bridge). It must be thread-safe and non-blocking; serialize onto a queue before writing to a file.
- Per-segment trace lines are logged at `.verbose`. They only reach os_log's debug level, never the handler, so the mirrored stream stays readable.
- `aetherctl` installs exactly this handler, which is why the CLI prints what the app hides.

**Write the log to a file in GUI apps, on every build.** An app launched from Finder or `open` has no stdout you can read, so `print` goes nowhere (this cost a reporter on #493 most of a measurement session). Write each line to a file you can name, flushing per line:

```swift
EngineLog.handler = { line in DiagnosticFile.shared.append(line) }  // your own serial queue + flush
```

**Reading os_log afterwards** works as a fallback, but needs a time window: `log show --last 10m --predicate 'subsystem == "de.superuser404.AetherEngine"'` returns the session's lines (macOS 26.5). Without `--last`, or with a bare `log show`, the same predicate looks as if the engine never logged. Lines are logged with `.public` privacy, so they arrive whole rather than as `<private>`. That is also why [`LogRedaction`](../Sources/AetherEngine/Diagnostics/LogRedaction.swift) removes credentials at the source: what reaches your file also reaches a sysdiagnose.

### Which FFmpeg answered

The first line of every session names the FFmpeg in use:

```
[FFmpeg] libavcodec 62.28.102, libavformat 62.6.100, libavutil 60.13.100, libswresample 6.0.100
```

Which FFmpeg answers is decided by your executable's link, not by the package graph. If a second FFmpeg in the app takes over those symbols, this line becomes an `ERROR:` that names the mismatch and how to find it. Read it once per integration: a wrong FFmpeg produces failures that look like engine bugs (one cost a reporter five fixtures and two devices). Details in [api.md › One FFmpeg](api.md#one-ffmpeg-and-it-has-to-be-the-engines) and [licensing.md › Linking](licensing.md#linking-the-engine-statically).

## Samples

Three samples ship in `Examples/`:

- [`MinimalPlayer/`](../Examples/MinimalPlayer/MinimalPlayerApp.swift): a single-file SwiftUI player with a transport bar. Copy it into a new tvOS, iOS or macOS app, point it at a URL, run.
- [`LiveHost/`](../Examples/LiveHost/LiveChannelHost.swift): the live-TV contracts no compiler checks for you: the `liveSourceReset` retune and its guard, `CancellationError` out of a replaced `load`, and the audio tap that ends with its session.
- [`DemoPlayerMac/`](../Examples/DemoPlayerMac/README.md): a standalone macOS app for testers. Drop a file on the window and it plays. A notarized universal `.dmg` is attached to every [GitHub Release](https://github.com/superuser404notfound/AetherEngine/releases/latest).
