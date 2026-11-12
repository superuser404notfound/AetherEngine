# Host guide

How to build a player on AetherEngine, in the order you build one: first frame, state, tracks, tvOS setup, live TV, custom sources, then the optional parts. Each section shows the code first and explains it after. The complete API, including every contract the host must answer, is in [api.md](api.md). Installing the package is in [installation.md](installation.md).

- **Get started:** [First player](#first-player), [Samples](#samples)
- **Play a file:** [Loading](#loading), [Transport](#transport)
- **State and errors:** [Reading the session state](#reading-the-session-state), [Time](#time)
- **Tracks and subtitles:** [Audio and subtitle tracks](#audio-and-subtitle-tracks), [Discs and chapters](#discs-and-chapters)
- **tvOS:** [tvOS host setup](#tvos-host-setup)
- **Live TV:** [Live TV and DVR](#live-tv-and-dvr), [IPTV timeshift and catch-up archives](#iptv-timeshift-and-catch-up-archives)
- **Custom sources:** [Custom input](#custom-input), [SMB shares](#smb-shares)
- **Optional features:** [Now Playing](#now-playing), [Picture in Picture](#picture-in-picture), [Scrub previews](#scrub-previews), [Drawing your own overlay in sync](#drawing-your-own-overlay-in-sync), [more opt-in options](#optional-features)
- **Diagnostics:** [Diagnostics](#diagnostics)

## First player

The fastest start is the sample: [`Examples/MinimalPlayer`](../Examples/MinimalPlayer/MinimalPlayerApp.swift) is a complete single-file SwiftUI player with a transport bar. Copy it into a new tvOS, iOS or macOS app, point it at a URL and run. The core of it:

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

In UIKit / AppKit, create an `AetherPlayerView`, call `player.bind(view:)` with it, then `load`.

- **One engine per app.** Create it once and reuse it for every title.
- **No built-in UI.** There is no `AVPlayerViewController` and no controls. You build the transport bar and menus, and read the published properties for state.
- **`play()` is not needed after a load.** Call it yourself only after a load with `autoplay: false`.

The view adapts by itself: per session the engine swaps the hosted layer (`AVPlayerLayer` on the native AVPlayer path, `AVSampleBufferDisplayLayer` on the software dav1d path). The host does not need to know which one is active.

## Samples

Three samples ship in `Examples/`:

- [`MinimalPlayer/`](../Examples/MinimalPlayer/MinimalPlayerApp.swift): the single-file SwiftUI player above.
- [`LiveHost/`](../Examples/LiveHost/LiveChannelHost.swift): the live-TV contracts no compiler checks for you: the `liveSourceReset` retune and its guard, `CancellationError` out of a replaced `load`, and the audio tap that ends with its session.
- [`DemoPlayerMac/`](../Examples/DemoPlayerMac/README.md): a standalone macOS app for testers. Drop a file on the window and it plays. A notarized universal `.dmg` is attached to every [GitHub Release](https://github.com/superuser404notfound/AetherEngine/releases/latest).

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
| `$isAwaitingDisplaySwitch` | The start is held for the TV's mode switch, not for the source |
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

**`isAwaitingDisplaySwitch`** is true while a loaded session holds its start until the TV finishes a mode switch (Match Content, a change of dynamic range). The first frame can already be up and `playbackPhase` reads `.loading` throughout, so this is what tells you the wait is the panel's. A host that keeps its spinner off during a display switch keys on it (AE#1000). It clears when the hold ends and at every `load()` / `stop()`.

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

### Choosing tracks at load

```swift
try await player.load(url: videoURL, options: LoadOptions(
    preferredAudioLanguages: ["de", "en"],     // first match wins, in this order
    preferredSubtitleLanguages: ["de"]
))
try await player.load(url: videoURL, audioSourceStreamIndex: 2)   // an explicit pick wins over the languages
```

Pick the audio at load rather than right after it. The first frame is muxed with the chosen track, and a later `selectAudioTrack` costs a reload. `initialSubtitleTrackID` selects a subtitle track by id the same way. Full list: [api.md › LoadOptions](api.md#loadoptions).

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
- A host that renders ASS itself (libass) sets `LoadOptions(preserveASSMarkup: true)`. ASS and SSA tracks then arrive as raw event lines, and `TrackInfo.assHeader` carries the script header the styles refer to.

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
player.systemCaptionRequest   // PassthroughSubject<SystemCaptionRequest, Never>, one subscription per engine
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
// DVD-Video / Blu-ray ISO, local or remote, or a BDMV / VIDEO_TS folder (empty for other sources)
player.$discTitles             // [TitleInfo]: id, name, durationSeconds, chapterCount, playlist (Blu-ray .mpls), titleSet (DVD VTS) (longest first, id 0 is the main feature)
player.$selectedDiscTitle      // TitleInfo?
player.selectTitle(id: titleID)       // switch title (rebuilds from the new title's start)
player.$discChapters           // [ChapterInfo] for the selected title
player.selectChapter(id: chapterID)   // seek to a chapter (disc chapters only)

// Matroska / MP4 chapters (empty for discs, which publish discChapters instead)
player.$mediaChapters          // [ChapterInfo]; startSeconds are seek(to:) values, 0-based like currentTime
```

A ripped disc folder plays through `MediaSource.custom` with a `DiscDirectoryReader`, which lists the folder's files and opens one on request; `HTTPDiscDirectoryReader` is the ready-made one for files on a web server. A remote ISO plays from its URL, on an origin that honours `Range`. To come back to the same title later, store `TitleInfo.playlist` (Blu-ray) or `titleSet` (DVD), not `id`, which is only the title's place in the current scan. Details in [formats.md › Blu-ray folders](formats.md#blu-ray-folders) and [Remote disc images](formats.md#remote-disc-images-ae860).

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

**Why.** tvOS 26.5 validates HLS variants against the panel's current mode. A variant whose `VIDEO-RANGE` the panel cannot show right now is rejected with `AVFoundationErrorDomain -11868`, before its `EXT-X-MAP` init segment is even fetched: `item.status = .failed`, with no `errorLog()` events. SDR variants are not affected. This is the order Apple Tech Talk 503 has prescribed since 2017.

AVKit's automatic criteria (`appliesPreferredDisplayCriteriaAutomatically = true`) cannot help with HDR multivariant HLS: they come from `AVAsset.preferredDisplayCriteria`, which exists only after a variant has passed that validator. So the engine writes the criteria itself, before the item exists.

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

On tvOS 26 the focused row of an open SwiftUI `Menu` blinks on any render transaction in the tree. Build the menu button in UIKit (`UIButton.menu` + `showsMenuAsPrimaryAction`) and guard `updateUIView` so the open dropdown never rebuilds.

**The problem.** On tvOS 26, the focused row of an open SwiftUI `Menu` blinks whenever any SwiftUI render transaction runs in the hosting tree, even one contained in an unrelated leaf view (a `TimelineView(.periodic)` wall clock, a playbar observing `engine.clock`, a subtitle overlay).

Minimal repro: put a `Menu` next to a `TimelineView(.periodic(from: .now, by: 1))` and open the menu. The focused item blinks once per second. This is a SwiftUI issue, not an engine one. An AetherEngine adopter reported it to Apple (see [AetherEngine#29](https://github.com/superuser404notfound/AetherEngine/issues/29)).

**What the engine does.** It keeps its own surfaces out of the way by splitting every continuously ticking value off the engine's `ObservableObject`: `engine.clock` at ~10 Hz, `engine.diagnostics` at 1 Hz. But a player UI always has something ticking.

**What to do.** If your custom chrome needs a dropdown during playback, build the menu button in UIKit and let SwiftUI host it. `UIButton` with `button.menu` + `showsMenuAsPrimaryAction` renders the same system menu as SwiftUI's `Menu` (public API since tvOS 17), and a `UIViewRepresentable` wrapper can make sure the open dropdown is never rebuilt:

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

SwiftUI may call `updateUIView` as often as it likes. The guard means an open menu only rebuilds when the items really change. Credit to [@ohjey](https://github.com/ohjey) for isolating the mechanism and the pattern (AetherEngine#29).

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
player.liveSourceReset            // PassthroughSubject<Void, Never>; one subscription per engine, before the first load

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

**To retry on your own schedule** without losing the DVR window, set `LoadOptions(hostRetriesExhaustedLiveReplay: true)`. A replay the engine could not recover then publishes `liveSourceReplayExhausted` instead of `liveSourceReset`, and you call `retryLiveSourceRecovery()` under your own backoff. Subscribe to both: the other three causes above still arrive as `liveSourceReset`.

### A resume that moved: `liveResumeClamped`

```swift
player.liveResumeClamped           // PassthroughSubject<LiveResumeClamp, Never>; no replay, subscribe before load
    .sink { clamp in showToast("Skipped \(Int(clamp.skippedSeconds)) s") }
    .store(in: &cancellables)
```

A viewer who pauses longer than the DVR window has lost the paused position: the window slid past it. The resume then starts at the oldest retained point, or at the live edge without DVR, and this event fires. Without it, the program just continues somewhere else with nothing on screen to say why. `skippedSeconds` is what the viewer missed, `behindLiveSeconds` is where the resume landed. A host that wants to decide itself sets `clampsLiveResumeToWindow: false`. Details in [api.md › Live: a resume that had to move](api.md#live-a-resume-that-had-to-move).

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
| A finished MPEG-TS playlist AVPlayer refuses, or one loaded with `preferredDecodePath: .software` | Played on the software host from the seekable TS ingest, seeks included (AE#990) |

**`nativeRemoteHLS`.** Pair it with `isLive: true`. `LoadOptions.httpHeaders` go into the `AVURLAsset` on this path, so origins that require per-stream `Referer`, `User-Agent` or `Authorization` headers (common for IPTV) work too.

`LoadOptions.nativeRemoteHLSIngestFallback = false` turns off two of these recoveries: the HEVC-in-MPEG-TS reroute (#168) and the hand-over of a refused bypass (#363).

How each reroute works (the carriage check, the refused bypass, live and non-live playlists on the loopback path) is in [formats.md › Remote HLS](formats.md#remote-hls). Sidecar subtitles on the bypass become renditions there too: [formats.md › Renditions on the nativeRemoteHLS bypass](formats.md#renditions-on-the-nativeremotehls-bypass-316).

## IPTV timeshift and catch-up archives

```swift
// An origin that answers every Range with a plausible 206 whose body is not at that offset:
try await player.load(url: archiveURL, options: LoadOptions(
    sequentialOrigin: true,             // only byte 0 is addressable
    declaredDurationSeconds: 8100       // required on VOD; there is no tail read to estimate it
))
```

Timeshift and catch-up archives often fake range answers: `Range: bytes=X-` returns `206` with a body that really starts at a coarse internal chunk boundary. No header reveals this up front, so the host declares it when it knows (#346). The engine then:

- runs one long-lived unranged GET, with no ranged probes, no byte-offset reconnects and no tail read;
- treats the demuxer's pb as non-seekable;
- reports a dropped connection as a read error, not end-of-media, so the host can request again;
- keeps the native path instead of forcing software;
- serves an append-only `EVENT` playlist with the durations actually muxed, completed with `ENDLIST` at the real end of the source.

**If you did not know in advance,** the engine catches it at the first ranged reconnect into bytes it already holds: it asks 4 KB early and compares them. The session then fails with `errorInfo?.kind == .sourceFabricatesRanges` before any wrong byte plays, at open or mid-session (AE#958). Answer it by loading the source again with `sequentialOrigin: true` and `declaredDurationSeconds`, and remember that for the provider.

Every producer reposition is refused by design. A seek lands only inside what the session already holds (on the native path, the resident span that reaches the producer's frontier). For any other target, and for an audio track switch, request the archive again with a shifted start timestamp and pass `audioSourceStreamIndex` for the chosen track (#958). To reproduce one from macOS: `aetherctl play --sequential-origin --declared-duration`.

### Providers that allow one connection

```swift
LoadOptions(maxConcurrentSourceRequests: 1)   // the plan allows one request at a time
LoadOptions(heldSourceConnection: true)       // the origin refuses repeated requests, but serves an open one
```

Many IPTV and debrid plans cap simultaneous connections. Set `maxConcurrentSourceRequests` to the provider's limit; `1` also turns off the engine's speculative side requests. Some origins instead punish the request cadence: they refuse new requests for minutes while serving one that is already open. `heldSourceConnection` asks once and keeps pulling from that one connection (HTTP/1.1 only, no system proxy). Both are in [api.md › maxConcurrentSourceRequests](api.md#maxconcurrentsourcerequests) and [heldSourceConnection](api.md#heldsourceconnection).

## Custom input

```swift
final class MyArchiveReader: IOReader, @unchecked Sendable {   // guard your own state
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

let probe = try await player.load(source: .custom(MyArchiveReader(), formatHint: "mp4"))
// load() returns the probe metadata it gathered (discardable).
// AetherEngine.probe(source:) probes once without starting playback.
```

**Threading.** `IOReader` is `Sendable`, and a reader with mutable state is not one the compiler can check, hence `@unchecked Sendable`. `read` and `seek` run on the engine's demux thread, never on main. `cancel()` can arrive from another thread while a `read` blocks, and probes call it too, so guard your state with a lock and make `cancel()` interrupt the blocked read promptly. `close()` is called exactly once.

What a reader unlocks:

| Reader | Features |
| --- | --- |
| Seekable | Playback, seeking, audio-track switching, background reload |
| Seekable with `makeIndependentReader()` (a second cursor) | Also embedded subtitles and scrub-preview thumbnails |
| Forward-only | Plain playback and seeking (VOD on the software path; live sessions stay native) |

**Security note.** On the native path, a custom reader's bytes are re-muxed to cleartext fMP4 in the loopback cache. That is fine for archives encrypted at rest, but it exposes content-protected sources in cleartext. Full contract in [api.md › Custom byte sources](api.md#custom-byte-sources-ioreader).

## SMB shares

```swift
import AetherEngineSMB

let smb = try await SMBConnection.connect(
    server: URL(string: "smb://nas.local")!, share: "media",
    path: "Movies/film.mkv", user: "alice", password: "s3cret"
)
try await player.load(source: .custom(
    SMBIOReader(source: smb, discImageProbeEnabled: false),   // an ordinary file, not a disc image
    formatHint: "matroska"
))
```

SMB support is a ready-made `IOReader` in the separate `AetherEngineSMB` product. Add that product next to `AetherEngine` only if you need it; hosts without SMB link only the core. It uses [SMBClient](https://github.com/kishikawakatsumi/SMBClient) (MIT, pure Swift, built on `NWConnection` over Network.framework), not libsmb2, which fails with `EPERM` on tvOS and iOS.

- **Ordinary media files:** construct the reader with `discImageProbeEnabled: false` to skip the ISO/UDF signature reads. Keep the default for raw disc images, so DVD and Blu-ray recognition still works.
- **Auth:** read-only, NTLMv2, guest or anonymous (an empty user tries guest, then anonymous). No Kerberos.
- **How it reads:** `SMBConnection` is a `ByteRangeSource`, and `SMBIOReader` adapts it to the engine's `IOReader`, bridging each synchronous demux-thread read to SMBClient's async API across a happens-before semaphore edge. The connection is persistent (`SMBClient` plus a `FileReader`) and reads are serialised per connection, which clears typical media bitrates comfortably.
- **Seekable:** audio-track switching, background reload, embedded subtitles and scrub previews all work, because `makeIndependentReader()` opens a second cursor over the same connection.
- **Read-only:** no writing, locking or directory browsing.
- **tvOS:** the host must declare `NSLocalNetworkUsageDescription` and the local-network entitlement to reach a LAN share.
- **Testing a share from macOS:** [`aetherctl smbtest`](cli.md#smbtest).
- **Known limit:** SMBClient negotiates only SMB 2.0.2 and 2.1. There is no SMB3 transport encryption or AES-CMAC signing, so servers set to SMB3-only or `smb encrypt = required` do not connect. (libsmb2 spoke 3.1.1, but does not work on tvOS / iOS at all.)

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

## Picture in Picture

```swift
// Native route: build the controller around the engine's own layer
if let layer = player.nativePlayerLayer {
    pip = AVPictureInPictureController(playerLayer: layer)
}

// Software route: the engine builds the controller; rebuild it on every change
player.$softwarePiPSource
    .sink { source in pip = source?.makePictureInPictureController() }
    .store(in: &cancellables)

// Both routes: report the window's state from the controller's delegate
player.pictureInPictureActive = true    // in willStart; false in didStop
```

Which one applies depends on `$videoRoute`. `nativePlayerLayer` is nil on the software route, and `softwarePiPSource` is nil everywhere else, so the nil check is also the right test for showing a PiP button. A host on `AVPlayerViewController` gets PiP from AVKit on the native route and needs neither.

- **Set `pictureInPictureActive`.** It keeps the pipeline alive in the background and, on the software route, turns on the frame compositor that draws subtitles into the window.
- **Rebuild on every change of `softwarePiPSource`.** Each software load builds a new display layer, so any load ends PiP on that route, and the old controller points at nothing. When the source becomes nil the engine stops the controller it made and resets `pictureInPictureActive`.
- **tvOS:** AVKit accepts the software route's source but does not show sample-buffer content, so software PiP works in practice on iOS and macOS only.
- **Subtitles in the window** come from native renditions (`prepareNativeSubtitles`) on the native route and from the frame compositor on the software route, never from your overlay.

Full contract, including layer geometry and the macOS window: [api.md › Picture in Picture on the software path](api.md#picture-in-picture-on-the-software-path).

## Scrub previews

```swift
if player.supportsCacheBackedStills {
    let image = await player.scrubThumbnail(atSeconds: target)   // CGImage?, nil means "time only"
}
```

`scrubThumbnail` decodes bytes the session already holds, so it opens no second connection and works on sources that allow only one. Gate the preview on `supportsCacheBackedStills`, and treat a nil as "no image for this position yet", not as an error. A host on `AVPlayerViewController` sets `LoadOptions(serveIFramePlaylist: true)` instead and gets AVKit's own thumbnails. A host that shows no previews at all sets `generatesBackgroundScrubPreviews: false`, so the engine builds no still ladder in idle time. Details in [api.md › Stills and thumbnails](api.md#stills-and-thumbnails).

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

## Optional features

Everything here is off (or at its old behaviour) until you set it. The ones that change what the viewer sees or hears come first.

### Upscaling low-resolution video

```swift
LoadOptions(upscalesLowResolutionVideo: true)                        // SDR below 1080p, to the display's size
LoadOptions(upscalesLowResolutionVideo: true, upscaleScaler: .lineArt) // animation only, also takes 1080p and 10-bit SDR
player.$activeUpscale   // UpscaleStatus?: what the stage is doing, nil while none runs
```

SDR video below 1080p is scaled to the display's native size, with VideoToolbox super resolution and MetalFX (#846). `.lineArt` runs a line-art network made for drawn content instead (AE#1039). Set it per title, from the genre or a per-show switch: on live action it looks wrong.

- **It moves the title onto the software path,** so that route's rules apply: PiP through `softwarePiPSource`, no native subtitle renditions.
- HDR, Dolby Vision, a display no larger than the source and any AirPlay route keep their usual route. The load logs one `[Upscale]` line saying why.
- It never stops playback. A stage that falls behind degrades, then switches itself off; `$activeUpscale` then carries `degraded` or `disabledReason`.

Details in [api.md › upscalesLowResolutionVideo](api.md#upscaleslowresolutionvideo) and [upscaleScaler](api.md#upscalescaler).

### Subtitle offset reach

```swift
player.maximumSubtitleOffsetSeconds = 0       // no subtitle offset control in this app
player.maximumSubtitleDelaySeconds = 30       // or per direction: LATER offsets up to 30 s
player.maximumSubtitleAdvanceSeconds = 0      // and no EARLIER ones
```

These tell the engine the largest subtitle offset your overlay applies. The default of 60 s each way costs memory and data: bitmap subtitles (PGS, DVB, DVD) are kept as decoded images, and an earlier offset needs a second reader that downloads a remote source a second time (AE#929, AE#1015, AE#1031).

- **No offset control:** set `maximumSubtitleOffsetSeconds = 0`. On a dense PGS track that keeps about 15 s of decoded images on each side instead of a protected 120 s plus up to 64 MiB of history, and on a remote MKV it stops the second download.
- **Later only:** set `maximumSubtitleAdvanceSeconds = 0` and your range in `maximumSubtitleDelaySeconds`. A later offset only needs cues already read, so it costs no second download.
- Each edge stays at least 15 s, so a short nudge or a seek back still finds its cue.

Details in [api.md › Cue retention](api.md#cue-retention).

### Loudness target

```swift
player.setAudioShaping(AudioShaping(loudnessTargetLUFS: -23))   // raise quiet films to -23 LUFS
```

A quietly mastered film is measured as it plays (BS.1770 / EBU R128) and lifted by the difference, at most 18 dB, never lowered (AE#1036). The target is clamped to -36 to -12 LUFS.

- **Any active shaping needs PCM.** A stream-copied track (Atmos and every lossless bitstream included) is decoded while it is on, so Atmos leaves as a channel bed. Offer it as a choice, not a default, on a receiver setup.
- Every change is a session-preserving reload. `$audioShapingState` says whether it applies; on `.remoteBypass` it reads `.unavailable`.
- The same `AudioShaping` carries the channel cap, the dialogue lift and night mode.

Details in [api.md › Audio shaping](api.md#audio-shaping).

### More options

| Option | What it gives you | Default |
| --- | --- | --- |
| `skipsContainerAttachments` | Opens a Matroska file without reading its attached fonts, tens of MB on anime releases (AE#956). Leave it off if you render ASS with those fonts | false |
| `audioBridgeMode` | `.lossless` sends FLAC up to 7.1 for a sink that takes multichannel PCM, instead of E-AC-3 | `.surroundCompat` |
| `objectAudioRendering` | Keeps the heights of TrueHD Atmos and DTS:X. Needs the package traits ([installation.md](installation.md#optional-components)) | `.off` |
| `audioDelaySeconds` | Starts the session with a lip-sync offset; `setAudioDelay(_:)` changes it later | 0 |
| `liveDVRByteBudget` | Lifts the software live DVR ring past 2 GiB, for hours of rewind | nil |
| `foldsDolbyVisionFEL` | Turns the FEL curve fold off for one load, with the `DolbyVisionFelCurves` trait ([dolby-vision-fel.md](dolby-vision-fel.md#7-curve-fold-on-the-native-route)) | true |
| `$sourceVideoScan` | Read-only: progressive or interlaced, so a panel can say 1080i instead of guessing 1080p (AE#983) | |

Every option with its contract: [api.md › LoadOptions](api.md#loadoptions).

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

**Register secrets the engine cannot recognise.** The engine strips tokens, passwords in named parameters and userinfo, and the Xtream Codes path layout by itself. A password that sits as a bare path segment in a provider URL looks like any other text, so name it:

```swift
EngineLog.registerSecret(account.password)     // false, and nothing registered, under four bytes
EngineLog.unregisterSecret(account.password)   // on logout; registrations are counted
```

Every line reaching os_log or your handler then has that value replaced, raw or percent-encoded. Details in [api.md › Log redaction](api.md#log-redaction).

**Write the log to a file in GUI apps, on every build.** An app launched from Finder or `open` has no stdout you can read, so `print` goes nowhere (#493). Write each line to a file you can name, flushing per line:

```swift
EngineLog.handler = { line in DiagnosticFile.shared.append(line) }  // your own serial queue + flush
```

**Reading os_log afterwards** works as a fallback, but needs a time window: `log show --last 10m --predicate 'subsystem == "de.superuser404.AetherEngine"'` returns the session's lines (macOS 26.5). Without `--last`, or with a bare `log show`, the same predicate looks as if the engine never logged. Lines are logged with `.public` privacy, so they arrive whole rather than as `<private>`. That is also why [`LogRedaction`](../Sources/AetherEngine/Diagnostics/LogRedaction.swift) removes credentials at the source: what reaches your file also reaches a sysdiagnose.

### Which FFmpeg answered

The first line of every session names the FFmpeg in use:

```
[FFmpeg] libavcodec 62.28.102, libavformat 62.6.100, libavutil 60.13.100, libswresample 6.0.100
```

Which FFmpeg answers is decided by your executable's link, not by the package graph. If a second FFmpeg in the app takes over those symbols, this line becomes an `ERROR:` that names the mismatch and how to find it. Read it once per integration: a wrong FFmpeg produces failures that look like engine bugs. Details in [installation.md › One FFmpeg](installation.md#one-ffmpeg-and-it-has-to-be-the-engines) and [licensing.md › Linking](licensing.md#linking-the-engine-statically).
