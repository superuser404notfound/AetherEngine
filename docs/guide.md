# Host guide

This guide shows how to build a player on AetherEngine, in the order you build one: first frame, state, tracks, tvOS setup, live TV, custom sources, then the optional parts. Each section shows the code first and explains it after.

"Host" means your app: the code that owns the engine and draws the controls. The complete API, including every contract the host must answer, is in [api.md](api.md). Installing the package is in [installation.md](installation.md).

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

The fastest start is the sample. [`Examples/MinimalPlayer`](../Examples/MinimalPlayer/MinimalPlayerApp.swift) is a complete SwiftUI player with a transport bar, in one file. Copy it into a new tvOS, iOS or macOS app, point it at a URL and run. The core of it:

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

In UIKit or AppKit, create an `AetherPlayerView`, pass it to `player.bind(view:)`, then call `load`.

Three rules to start with:

- **One engine per app.** Create it once and reuse it for every title.
- **No built-in UI.** There is no `AVPlayerViewController` and there are no controls. You build the transport bar and the menus, and you read the engine's published properties for state.
- **No `play()` after a load.** Playback starts by itself. Call `play()` yourself only after a load with `autoplay: false`.

### The two paths

The engine plays every title on one of two paths. You rarely need to care which, but the words come up throughout this guide:

- **The native path** hands the video to AVPlayer. For most files the engine first repackages the media and serves it to AVPlayer as HLS from a small web server inside your app (the "loopback").
- **The software path** decodes the video itself (with dav1d for AV1, for example) and draws the frames into its own layer. It covers what AVPlayer cannot play.

The view adapts by itself. Per session the engine swaps the layer it hosts: `AVPlayerLayer` on the native AVPlayer path, `AVSampleBufferDisplayLayer` on the software dav1d path. Your code does not need to know which one is active.

## Samples

Three samples ship in `Examples/`:

- [`MinimalPlayer/`](../Examples/MinimalPlayer/MinimalPlayerApp.swift): the single-file SwiftUI player above.
- [`LiveHost/`](../Examples/LiveHost/LiveChannelHost.swift): the live-TV rules no compiler checks for you. It shows the `liveSourceReset` retune and its guard, the `CancellationError` out of a replaced `load`, and an audio tap that ends with its session.
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

A `CancellationError` out of `load()` is not a failure. It means a newer load replaced this one, so ignore it. How every other failure arrives is in [api.md › How a load ends](api.md#how-a-load-ends).

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

All of these are Combine `@Published` properties on the engine. Subscribe to the ones your UI needs.

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

### state

`.idle` means before a load or after `stop()`.

`.ended` means the media played to the end (on any backend). It is **terminal**: seeks are rejected and `play()` does not revive it. To play again, call `load()` again.

A VOD title that is only parked at its final frame is a different case. There `play()` rewinds it.

### errorInfo

**Classify errors on `errorInfo`, never on the message text.** It holds a stable `PlaybackErrorKind` plus the underlying NSError domain and code.

The reason: on the native paths the message is `AVPlayerItem.error.localizedDescription`, passed through unchanged. It is in the device's language, so a rule that searches the text files every non-English device as unknown.

`errorInfo` is set before `.error` is published, and cleared when the state leaves `.error`.

### playbackPhase

`playbackPhase` combines state, `isBuffering`, `isSeeking` and source reconnects into one value. Use it for your spinner instead of stitching the raw signals together or matching `EngineLog` text.

### Seeking

`$isSeeking` stays true until a seek has really landed. That covers seeks from your code, native scrubs, and seeks stored before the session could take them.

`$seekTarget` is where the running seek goes, otherwise nil. It is a source PTS (the timestamp the file itself stores for a frame).

Use `seekEvents` (`AnyPublisher<SeekEvent, Never>`) wherever the end of a seek matters. Each event carries its target:

- `.began`
- `.landed(renderedTime:)`
- `.stalled`
- `.superseded`
- `.rejected`

`$isSeeking` alone cannot tell you whether a seek landed, gave up or was replaced. And on a stalled source, a seek that gave up can still land minutes later.

### videoRoute

`videoRoute` says which pipeline plays the session:

| Value | Meaning |
| --- | --- |
| `.remoteBypass` | AVPlayer plays the origin URL directly |
| `.loopback` | AVPlayer plays the engine's local HLS server (the default video route) |
| `.software` | The engine decodes and draws itself |
| `.audio` | Audio-only session |
| `.none` | Nothing loaded, or the session was torn down |

`LoadOptions.nativeRemoteHLS` only asks for the bypass. The engine can still move a session between the bypass and the loopback, also mid-session: its carriage watchdog, its remembered verdicts and its HLS reroutes all do that.

So branch on `videoRoute` wherever behaviour differs per pipeline. The most important case is subtitles: on `.remoteBypass` AVPlayer draws the origin's subtitle renditions; on every other route your app draws them.

### audioDelivery

`audioDelivery` says how the audio reaches the speakers:

| Value | Meaning |
| --- | --- |
| `.streamCopy` | The original bitstream, passed through as authored |
| `.bridged` | Decoded and re-encoded (FLAC or E-AC-3), because AVPlayer cannot take the original |
| `.decoded` | Decoded to PCM and played by the engine itself |
| `.noAudioInSource` | The file has no audio |
| `.playerManaged` | AVFoundation owns it |
| `.none` | No session: before a load, or torn down |
| `.droppedNoPipeline` | The source has audio, but none of it could be delivered |

`.droppedNoPipeline` means there is no decoder in this build, or the bridge could not be built. The session then plays video only, silent. A fallback ladder (your app's list of retry options) should demote on that value, the same way it demotes on `PlaybackErrorKind.audioBridgeProducedNoOutput`.

Classify on `audioDelivery`. `$activeAudioDecoder` is a label for humans, and it cannot tell a source without audio from one that lost it.

### hasFirstFrameReadyForDisplay

**Lift your black cover when `hasFirstFrameReadyForDisplay` turns true.** It turns true when the running path has a first frame ready for the media this load opened.

Do not use `readyToPlay` for this. AVFoundation reaches it before the layer holds a picture, and it stays true across a seek. A cover lifted on `isSessionReady` therefore reveals black.

The value is latched for the whole load. It goes back to false at the next `load()` or `stop()`. To know whether a seek has reached the screen, use the `.landed` event of `seekEvents`.

### startupProgress

`startupProgress` (`StartupProgress?`) drives a loading bar that shows real progress. It offers `.completed` of `.total` checkpoints, `.fraction`, and `.stage`, which names the work in flight.

- Every value is work that actually finished, never a timer or an estimate. A slow stretch holds, a skipped one jumps.
- It covers the two stretches your app cannot otherwise see: opening the source (connection, container, stream analysis) and the display-criteria handshake (the TV switching its picture mode, see [tvOS host setup](#tvos-host-setup)).
- It is scoped to `.generation`, which counts the startups a user waited through, not internal teardowns. When the engine reroutes a session on its own, the bar continues instead of starting over.
- It only moves forward and never repeats a value. It is nil before the first load and after `stop()`. A load that fails never reaches the last checkpoint.

### isAwaitingDisplaySwitch

`isAwaitingDisplaySwitch` is true while a loaded session holds its start until the TV finishes a mode switch (Match Content, or a change between SDR and HDR).

During that hold the first frame may already be visible, and `playbackPhase` reads `.loading` the whole time. This flag is how you know the wait is the TV's, not the source's. A host that hides its spinner during a display switch keys on it (AE#1000). It clears when the hold ends, and at every `load()` / `stop()`.

### currentAVPlayer

`currentAVPlayer` is published again on every reload.

It is nil on the `.software` route. That route draws into its own display layer, and AVKit must not hold a player that nothing feeds. So a host that only hands `currentAVPlayer` to an `AVPlayerViewController` gets audio and AVKit's spinner over an empty picture on that route (#298).

Bind a surface for it instead, and choose the presentation from `$videoRoute`, not from the source codec.

## Time

```swift
player.clock.$currentTime       // ~10 Hz playback clock (transport, scrubbing, resume)
player.clock.$sourceTime        // source PTS of the displayed frame (render subtitles against this)
player.clock.$bufferedPosition  // source-axis position buffered ahead; buffer bar = bufferedPosition / duration
```

Time lives on `player.clock`, a separate `ObservableObject`, not on the engine.

That keeps re-renders down. The ticks at about 10 Hz never fire the engine's `objectWillChange`, so views that show track lists or state do not re-render on every tick, and native tvOS `Menu` dropdowns stay stable. The diagnostics snapshot, which updates once per second (1 Hz), lives apart from the engine for the same reason, on `player.diagnostics.liveTelemetry`.

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

**Pick the audio track at load, not right after it.** The first frame is packaged together with the chosen track, so a later `selectAudioTrack` costs a reload.

`initialSubtitleTrackID` selects a subtitle track by id the same way. Full list: [api.md › LoadOptions](api.md#loadoptions).

### Styled text

```swift
for cue in player.subtitleCues {
    if case .richText(let runs) = cue.body { render(runs, at: cue.placement) }
}
```

Styled subtitles arrive as `.richText`. Each run carries colour, bold, italic, underline, strikeout, font face and a font size relative to ASS (the Advanced SubStation Alpha subtitle format). The cue carries the placement it asks for: a numpad alignment (1 is bottom left, 9 is top right) plus an optional anchor in [0, 1].

- This covers SRT, WebVTT, teletext and ASS alike. libavcodec turns all of them into ASS event lines before the engine sees them.
- A cue without styling still arrives as `.text`, so code that handles only that case keeps working.
- Exception: libavcodec does not convert WebVTT cue settings, so VTT positioning does not arrive. Its inline bold, italic and underline do.
- A host that renders ASS itself (with libass) sets `LoadOptions(preserveASSMarkup: true)`. ASS and SSA tracks then arrive as raw event lines, and `TrackInfo.assHeader` carries the script header the styles refer to.

Cues are stamped in raw source PTS. Draw your overlay against `player.sourceTime` ([formats.md › Subtitles](formats.md#subtitles)).

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

External files behave like any other track. They appear in `subtitleTracks` with `isExternal == true` and a synthetic id, and you select them with the same call as embedded streams. Tracks that share a URL are decoded in one pass.

### Native subtitle renditions (PiP, AirPlay, external display)

```swift
player.$nativeSubtitleTracks               // [NativeSubtitleTrack]: ordinal, language, displayName
player.setNativeSubtitleSelected(track: 2) // engage a rendition (for example on PiP entry); nil deselects
player.setNativeSubtitleSelected(track: 2, markerOnly: true) // tick it in AVKit's menu, draw nothing
```

Your own overlay cannot reach a Picture in Picture window, an AirPlay receiver or an external display. For those, the engine can hand AVPlayer the subtitles as WebVTT renditions that AVPlayer draws itself. Opt in with `LoadOptions.prepareNativeSubtitles`.

If you draw a bitmap track yourself inside `AVPlayerViewController`, `markerOnly: true` makes AVKit's subtitle menu show that track as selected without drawing it or running OCR. PiP and AirPlay still get the OCR text once you call `setNativeSubtitleRendering(true)`. Details in [formats.md](formats.md#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display).

### Captions the system turned on

```swift
player.systemCaptionRequest   // PassthroughSubject<SystemCaptionRequest, Never>, one subscription per engine
```

iOS 26 can turn captions on by itself: Settings > Accessibility > Subtitles & Captioning > Automatic Subtitles (when muted, on skip back, on a language mismatch). These settings have no read API, so the system's selection is the only sign of the request.

The engine deselects that selection, because a rendition drawn in fullscreen puts a caption box over your own subtitles. It forwards the request to this subject instead. If you want the behaviour, pick your own matching track.

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

- **A ripped disc folder** plays through `MediaSource.custom` with a `DiscDirectoryReader`, which lists the folder's files and opens one on request. `HTTPDiscDirectoryReader` is the ready-made one for files on a web server.
- **A remote ISO** plays from its URL, on a server that honours `Range` requests.
- **To come back to the same title later**, store `TitleInfo.playlist` (Blu-ray) or `titleSet` (DVD), not `id`. The `id` is only the title's place in the current scan.

Details in [formats.md › Blu-ray folders](formats.md#blu-ray-folders) and [Remote disc images](formats.md#remote-disc-images-ae860).

## tvOS host setup

On Apple TV the engine switches the TV's picture mode for you. This section explains the setup and the few switches around it.

### Let the engine drive the display switch

**The short version:** turn AVKit's automatic display switching off and leave `displayCriteriaOwner` at its default. Then HDR and Dolby Vision play reliably on tvOS 26.5 and later.

Some background. "Display criteria" is the request that asks the TV to switch to the title's frame rate and dynamic range (SDR, HDR10, Dolby Vision). Apple calls the user setting for this "Match Content". On tvOS 26.5+, HDR and Dolby Vision sources only play reliably when the engine sets `AVDisplayManager.preferredDisplayCriteria` itself, synchronously, before it assigns the `AVPlayerItem`.

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

**Why the engine has to do it.** tvOS 26.5 checks each HLS variant (one quality level of a stream) against the TV's current mode. A variant whose `VIDEO-RANGE` the TV cannot show right now is rejected with `AVFoundationErrorDomain -11868`. That happens before even its `EXT-X-MAP` init segment is fetched: `item.status = .failed`, with no `errorLog()` events. SDR variants are not affected. Setting the criteria first is the order Apple Tech Talk 503 has prescribed since 2017.

AVKit's automatic criteria (`appliesPreferredDisplayCriteriaAutomatically = true`) cannot help with HDR HLS that has several variants. They come from `AVAsset.preferredDisplayCriteria`, which only exists after a variant has passed that check. So the engine writes the criteria itself, before the item exists.

**What happens during a load.** `displayCriteriaOwner` defaults to `.engine`, so this is the default behaviour:

1. The engine writes the criteria before it assigns the item.
2. It waits up to about 2 s for the switch to start and settle. A VOD load keeps producing segments meanwhile; a live load waits behind it.
3. `play()` is then held until the switch ends. `isAwaitingDisplaySwitch` is true during that hold.

`displayCriteriaOwner` has three values ([AE#842](https://github.com/superuser404notfound/AetherEngine/issues/842)):

| Owner | Who writes the criteria | Pick it when |
| --- | --- | --- |
| `.engine` (default) | The engine, before the item loads | Almost always, for the reason above |
| `.avKit` | AVKit, from the item (`appliesPreferredDisplayCriteriaAutomatically = true`). The engine holds `play()` up to a second for that write on HDR and Dolby Vision content | You keep AVKit's automatic criteria |
| `.host` | You, before `load()`, or nobody. The engine never writes and waits only for a switch it sees running | The panel should stay in the output format the user chose in tvOS Settings, or you write rate-only criteria yourself |

`suppressDisplayCriteria: true` is the older spelling of `.avKit` and still works.

### The two panel flags

**Both flags are assertions, not readings, and both default to `false`.** You use them to tell the engine something it cannot measure reliably.

An assertion only ever adds a capability, so neither flag can hide one the system reports. A wrong one is cheap: it costs a single in-place fallback to another media playlist (`-11868` / `-11848`) at the same position, not the item.

- **`panelIsInHDRMode`** is combined (OR) with the engine's own reading of the display's HDR headroom (EDR). That reading only answers around a change of dynamic range. An Apple TV whose output is locked to HDR never makes that change, so without the flag it reads as an SDR panel forever ([#459](https://github.com/superuser404notfound/AetherEngine/issues/459)).
- **`panelPresentsDolbyVision`** covers what the engine cannot observe at all on macOS. There is no `AVPlayer.availableHDRModes` there, and the HDR eligibility check answers for HDR10 and HLG but not for Dolby Vision ([#493](https://github.com/superuser404notfound/AetherEngine/issues/493)).

**What `panelPresentsDolbyVision` still changes.** Dolby Vision comes in numbered profiles (5, 7, 8.1, 8.4 and so on), which package the picture differently.

- For a Profile 5, 8.1 or 8.4 source it changes nothing in the packaging. Since 6.72.0 / 6.73.0 those serve the same manifests and segments with or without the claim.
- It still gates three things: the Profile 7 to 8.1 conversion, the AV1 Dolby Vision record, and HDR readiness on the route.
- The `-15628` stall that an HDR10-only panel once showed on Dolby Vision packaging ([#4](https://github.com/superuser404notfound/AetherEngine/issues/4)) did not reproduce on tvOS 26.6.

**`attemptsHDRMasterOnUnprovenPanel`** (default `true`) is the engine's own answer to the unreliable headroom reading. On an HDR-capable display whose current mode is unknown, it serves the HDR version anyway and lets AVFoundation accept or refuse it. A refusal costs one in-place fallback, once per process.

**Dolby Vision on a TV without it.** `forceDolbyVisionOnNonDVDisplay` is **experimental** and off by default.

- What it does: it serves a Profile 8.1 (or converted Profile 7) source as Profile 5. AVPlayer then composes the Dolby Vision picture itself, instead of handing the TV only the HDR10 base layer ([#455](https://github.com/superuser404notfound/AetherEngine/issues/455)).
- The risk: a tvOS build that reads the base layer's colours from the profile field would show a green / violet cast.
- Asserting `panelPresentsDolbyVision` turns it off.

Details in [api.md › forceDolbyVisionOnNonDVDisplay](api.md#forcedolbyvisiononnondvdisplay).

### Between items

**Back-to-back `load()` calls keep the TV in its mode.** The applied criteria carry across the seam. A follow-up in the same mode (a Dolby Vision episode after a Dolby Vision episode) overwrites them in place with one handshake, instead of bouncing the TV through SDR.

If your app calls `stop()` between items, use `stop(resetDisplayCriteria: false)` for the same result ([#128](https://github.com/superuser404notfound/AetherEngine/pull/128)). The plain `stop()` returns the TV to its default mode, which is right when leaving playback for the app UI.

Audio-only sessions and hosts that turned the engine's criteria off clear leftover criteria automatically.

### Who owns the audio session

**If your app plays no audio of its own, set `engine.deactivatesAudioSessionOnStop = true`.**

The background: the engine sets the audio session category at the first load, but never activates the session on the native path. AVKit activates it for each playback, and that is what lets tvOS negotiate the HDMI audio route ([#24](https://github.com/superuser404notfound/AetherEngine/issues/24)). So by default the engine never releases it either.

On a route that passes E-AC-3 / Atmos through to a receiver, the receiver can then keep looping the last MAT frame (the packet format Atmos travels in over HDMI) after the player is gone.

With the flag set, the engine releases the session on a real final teardown, meaning `stop()`. It never releases it on a reload, a handoff or a live retune.

It is off by default, because an app that plays its own audio (UI sounds, TTS or an `AVAudioEngine` competing with playback) would otherwise lose its session when playback ends. Set it only if your app owns the session alone.

### SwiftUI `Menu` in custom player controls

**On tvOS 26 an open SwiftUI `Menu` blinks during playback. Build the menu button in UIKit instead** (`UIButton.menu` + `showsMenuAsPrimaryAction`) and guard `updateUIView` so the open dropdown never rebuilds.

**The problem.** The focused row of an open SwiftUI `Menu` blinks whenever any SwiftUI render transaction runs in the hosting tree. Even one inside an unrelated leaf view triggers it: a `TimelineView(.periodic)` wall clock, a playbar observing `engine.clock`, a subtitle overlay.

Minimal repro: put a `Menu` next to a `TimelineView(.periodic(from: .now, by: 1))` and open the menu. The focused item blinks once per second. This is a SwiftUI issue, not an engine one. An AetherEngine adopter reported it to Apple (see [AetherEngine#29](https://github.com/superuser404notfound/AetherEngine/issues/29)).

**What the engine does.** It keeps its own values out of the way: every value that ticks continuously lives off the engine's `ObservableObject`, on `engine.clock` (about 10 Hz) and `engine.diagnostics` (1 Hz). But a player UI always has something ticking, so that alone is not enough.

**What to do.** If your custom controls need a dropdown during playback, build the menu button in UIKit and let SwiftUI host it. A `UIButton` with `button.menu` + `showsMenuAsPrimaryAction` shows the same system menu as SwiftUI's `Menu` (public API since tvOS 17). A `UIViewRepresentable` wrapper then makes sure the open dropdown is never rebuilt:

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

A few live terms used below:

- **Live edge:** the newest moment of the broadcast.
- **DVR window:** how far back a viewer can rewind (`dvrWindowSeconds`).
- **Segment:** HLS cuts a stream into short files; the playlist lists them.
- **`TARGETDURATION`:** the longest segment the playlist promises.
- **Holdback:** how far behind the live edge the player starts, so it has segments in reserve.
- **GOP:** the distance between two keyframes (pictures a decoder can start from).

### Fast channel start: `liveJoinProfile`

**`liveJoinProfile` defaults to `.fastZap`, which gives a faster first picture at the cost of a little robustness.** Pick `.standard` for lean-back viewing that can afford the full wait; it keeps the full-holdback guarantee.

What `.fastZap` changes:

- **Shorter segments.** Live segments are cut at every keyframe after 0.5 s instead of the standard ~4 s. The served `TARGETDURATION` drops to 1.5 x the source GOP length: 1 s GOPs serve 2, and so do segments up to 1.666 s. The headroom covers a broadcast's irregular GOPs (#670).
- **Smaller holdback.** The live-edge holdback (`HOLD-BACK` = 3 x `TARGETDURATION`, the RFC 8216bis minimum, #189) shrinks with it.
- **A bounded start.** The first manifest still prefers the full holdback. After two finished segments, a source that delivers strictly in real time gets one grace period of one observed segment, clamped to 0.5...2.0 s. After that, a shallow first window may be served so startup stays bounded. This can cause one early `-16832` error or a short rebuffer.
- **Less patience.** A smaller `TARGETDURATION` also makes AVPlayer less patient with an unchanged playlist, and keeps a smaller buffer at the live edge. Origins that stall or deliver in bursts mid-stream rebuffer more easily.

### The retune request: `liveSourceReset`

**A host that plays live must subscribe to `liveSourceReset`.** It is the live version of a terminal `state = .error`.

It fires when the engine cannot revive the session itself and only a new URL can help:

- the source restarted from byte 0 (a Jellyfin transcode respawn),
- the playlist is still frozen after the stall ladder's last reload step,
- the engine's own reopen attempts have used up their budget,
- a verified replay cannot reach new media (unless you opt into `hostRetriesExhaustedLiveReplay`, which publishes `liveSourceReplayExhausted` instead; see [api.md › Live: exhausted verified replay](api.md#live-exhausted-verified-replay)).

In each case the engine stops production first. A dead provider then no longer advertises blocking reloads behind your back.

**If you do not subscribe,** a channel can stop while the engine still reports a session. From the outside that looks exactly like a slow channel.

How to answer it:

1. After your own backoff, call `retryLiveSourceRecovery()`. It renews the source in place and keeps the DVR window.
2. If it returns `false`, get a fresh URL and call `load` again.
3. Guard the answer: one recovery in flight, a minimum spacing, a bounded count per session. Otherwise a permanently dead upstream turns into a retune loop.
4. When the bound runs out, show it the way you would show a terminal `.error`. A retune ladder that ends on a silent `return` leaves the dead channel on screen behind a counter.

**A host with a fixed URL** (an IPTV channel) answers by loading the same URL again. That is cheap, and it is not a no-op.

The engine remembers one expensive finding per URL: a master playlist that advertises HEVC while delivering MPEG-TS (the #168 carriage verdict). It is remembered per exact absolute URL for six hours, 32 entries. So the retune goes straight onto the live ingest and skips the doomed native attempt and its watchdog wait.

A URL with a token that rotates per session misses that memory and pays the one-time discovery again on every retune. Keep that in mind if you measure a first-frame budget against the retune.

**To retry on your own schedule** without losing the DVR window, set `LoadOptions(hostRetriesExhaustedLiveReplay: true)`. A replay the engine could not recover then publishes `liveSourceReplayExhausted` instead of `liveSourceReset`, and you call `retryLiveSourceRecovery()` under your own backoff. Subscribe to both: the other three causes above still arrive as `liveSourceReset`.

### A resume that moved: `liveResumeClamped`

```swift
player.liveResumeClamped           // PassthroughSubject<LiveResumeClamp, Never>; no replay, subscribe before load
    .sink { clamp in showToast("Skipped \(Int(clamp.skippedSeconds)) s") }
    .store(in: &cancellables)
```

**Subscribe to this to tell the viewer why the program jumped.**

A viewer who pauses longer than the DVR window loses the paused position: the window slid past it. The resume then starts at the oldest point still kept, or at the live edge without DVR, and this event fires. Without it, the program just continues somewhere else, with nothing on screen to say why.

- `skippedSeconds` is what the viewer missed.
- `behindLiveSeconds` is where the resume landed.

A host that wants to decide itself sets `clampsLiveResumeToWindow: false`. Details in [api.md › Live: a resume that had to move](api.md#live-a-resume-that-had-to-move).

### Recording a channel

```swift
try await player.startRecording(to: fileURL)
await player.stopRecording()
player.$recordingState            // .idle / .recording / .ended / .failed
```

`startRecording(to:)` writes the live source to an MPEG-TS file, fed from the connection the session already holds.

That is the point of it. IPTV plans often allow only 1 to 3 simultaneous connections, so an app that opens its own connection to record either fails or knocks the viewer off the channel.

- It copies the source packets unchanged, taken before any audio conversion. A TrueHD or DTS channel records its original audio while playback uses the converted version.
- A file cut short by a crash still plays up to the cut.
- Recording follows the source, not the playhead. Pausing or scrubbing back inside the DVR window does not interrupt it.
- A `liveSourceReset` ends it cleanly, instead of writing past a seam the codecs may not survive.
- It cannot record on `nativeRemoteHLS` (`.remoteBypass`). There AVFoundation holds the connection and the engine never sees a byte. `startRecording` throws `.unsupportedRoute` there instead of writing an empty file.

Full contract in [api.md › Recording a live stream](api.md#recording-a-live-stream).

### Direct HLS ingest

`HLSLiveIngestReader` (the "live ingest") reads a live HLS stream straight from its source, with no media server in between. It covers:

- MPEG-TS, with demuxed-audio and packed-audio renditions (audio delivered separately from the video),
- in-line AES-128 clear-key decryption,
- SSAI ad pods (ads the server stitches into the stream), played directly: versioned init segments, audio re-anchoring, a no-cut watchdog.

Unsupported encryption and fMP4 playlists throw a typed `HLSIngestError`, so your app can fall back. Details in [formats.md › Live ingest](formats.md#live-ingest-aes-128-ssai).

**Subtitle renditions.** If a channel's master playlist declares an `EXT-X-MEDIA:TYPE=SUBTITLES` group, those subtitles show up as ordinary entries in `subtitleTracks`.

- The ingest only reads the chosen video variant, so the engine reads the subtitle group from the master.
- Nothing is fetched until a track is selected.
- Once `selectSubtitleTrack(index:)` picks one, the engine fetches that rendition's WebVTT segments and publishes the cues for your overlay. It places them by the shared `EXT-X-PROGRAM-DATE-TIME` timing, not by `X-TIMESTAMP-MAP`.

Details in [formats.md › Live HLS subtitle renditions](formats.md#live-hls-subtitle-renditions-host-overlay).

### Which route a remote HLS source takes

For most remote HLS you do not choose the route; the engine does. This table shows what happens:

| Source | What happens |
| --- | --- |
| A standard remote `master.m3u8` (for example a Jellyfin live channel) with `LoadOptions.nativeRemoteHLS` | Goes straight to AVPlayer, skipping the demuxer probe and the loopback server. AVPlayer handles the live edge and reconnects. |
| A live master that advertises HEVC (or Dolby Vision / AV1) but delivers MPEG-TS | Rerouted onto the live ingest (#168) |
| A live `nativeRemoteHLS` bypass that the origin refuses (HTTP 401 / 403) | Handed to the live ingest (#363) |
| A live remote `m3u8` on the default (loopback) path | Rerouted onto the live ingest (#363) |
| A non-live remote `m3u8` on the default (loopback) path | Rerouted onto the AVPlayer bypass (#154) |
| A finished MPEG-TS playlist AVPlayer refuses, or one loaded with `preferredDecodePath: .software` | Played on the software host from the seekable TS ingest, seeks included (AE#990) |

**`nativeRemoteHLS`.** Pair it with `isLive: true`. On this path `LoadOptions.httpHeaders` go into the `AVURLAsset`, so origins that require per-stream `Referer`, `User-Agent` or `Authorization` headers (common for IPTV) work too.

`LoadOptions.nativeRemoteHLSIngestFallback = false` turns off two of these recoveries: the HEVC-in-MPEG-TS reroute (#168) and the hand-over of a refused bypass (#363).

How each reroute works is in [formats.md › Remote HLS](formats.md#remote-hls). Sidecar subtitles on the bypass become renditions there too: [formats.md › Renditions on the nativeRemoteHLS bypass](formats.md#renditions-on-the-nativeremotehls-bypass-316).

## IPTV timeshift and catch-up archives

```swift
// An origin that answers every Range with a plausible 206 whose body is not at that offset:
try await player.load(url: archiveURL, options: LoadOptions(
    sequentialOrigin: true,             // only byte 0 is addressable
    declaredDurationSeconds: 8100       // required on VOD; there is no tail read to estimate it
))
```

**If a provider's archive only plays correctly from the start, declare it with `sequentialOrigin: true`.**

Timeshift and catch-up archives often fake their answers to range requests. `Range: bytes=X-` returns `206`, but the body really starts at a coarse internal chunk boundary, not at byte X. No header reveals this up front, so you declare it when you know.

With `sequentialOrigin` the engine:

- runs one long-lived unranged GET, with no ranged probes, no reconnects at a byte offset and no read of the file's tail;
- treats the demuxer's input (FFmpeg's pb) as non-seekable;
- reports a dropped connection as a read error, not end-of-media, so your app can request again;
- keeps the native path instead of forcing software;
- serves an append-only `EVENT` playlist with the durations actually muxed, completed with `ENDLIST` at the real end of the source.

**If you did not know in advance,** the engine catches it. At the first ranged reconnect into bytes it already holds, it asks 4 KB early and compares them. The session then fails with `errorInfo?.kind == .sourceFabricatesRanges` before any wrong byte plays, at open or mid-session (AE#958). Answer it by loading the source again with `sequentialOrigin: true` and `declaredDurationSeconds`, and remember that for the provider.

**Seeking is limited by design.** Every attempt to reposition the source is refused. A seek lands only inside what the session already holds (on the native path, the resident span that reaches the producer's frontier). For any other target, and for an audio track switch, request the archive again with a shifted start timestamp, and pass `audioSourceStreamIndex` for the chosen track.

To reproduce one from macOS: `aetherctl play --sequential-origin --declared-duration`.

### Providers that allow one connection

```swift
LoadOptions(maxConcurrentSourceRequests: 1)   // the plan allows one request at a time
LoadOptions(heldSourceConnection: true)       // the origin refuses repeated requests, but serves an open one
```

Many IPTV and debrid plans cap simultaneous connections. Two options cover the two kinds of limit:

- **`maxConcurrentSourceRequests`**: set it to the provider's limit. `1` also turns off the engine's speculative side requests.
- **`heldSourceConnection`**: for origins that punish the request rate instead. They refuse new requests for minutes while still serving one that is already open. The engine asks once and keeps reading from that one connection (HTTP/1.1 only, no system proxy).

Both are in [api.md › maxConcurrentSourceRequests](api.md#maxconcurrentsourcerequests) and [heldSourceConnection](api.md#heldsourceconnection).

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

An `IOReader` lets the engine play bytes from anywhere: an encrypted archive, a network protocol, a file inside a container. You supply read, seek and close; the engine does the rest.

**Threading.** Make your reader thread-safe with a lock.

- `IOReader` is `Sendable`. The compiler cannot check a reader with mutable state, hence `@unchecked Sendable`.
- `read` and `seek` run on the engine's demux thread, never on main.
- `cancel()` can arrive from another thread while a `read` blocks, and probes call it too. Make it interrupt the blocked read promptly.
- `close()` is called exactly once.

What a reader unlocks:

| Reader | Features |
| --- | --- |
| Seekable | Playback, seeking, audio-track switching, background reload |
| Seekable with `makeIndependentReader()` (a second cursor) | Also embedded subtitles and scrub-preview thumbnails |
| Forward-only | Plain playback and seeking (VOD on the software path; live sessions stay native) |

**Security note.** On the native path, the engine repackages a custom reader's bytes into unencrypted fMP4 in the loopback cache. That is fine for archives encrypted at rest. It is not fine for content-protected sources, because it exposes them in cleartext. Full contract in [api.md › Custom byte sources](api.md#custom-byte-sources-ioreader).

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

To play from a Windows or NAS file share, use the ready-made `IOReader` in the separate `AetherEngineSMB` product. Add that product next to `AetherEngine` only if you need it; apps without SMB link only the core.

It uses [SMBClient](https://github.com/kishikawakatsumi/SMBClient) (MIT, pure Swift, built on `NWConnection` over Network.framework). It does not use libsmb2, which fails with `EPERM` on tvOS and iOS.

- **Ordinary media files:** create the reader with `discImageProbeEnabled: false` to skip the ISO/UDF signature reads. Keep the default for raw disc images, so DVD and Blu-ray recognition still works.
- **Auth:** NTLMv2, guest or anonymous (an empty user tries guest, then anonymous). No Kerberos.
- **Read-only:** no writing, locking or directory browsing.
- **Seekable:** audio-track switching, background reload, embedded subtitles and scrub previews all work, because `makeIndependentReader()` opens a second cursor over the same connection.
- **tvOS:** your app must declare `NSLocalNetworkUsageDescription` and the local-network entitlement to reach a share on the local network.
- **Testing a share from macOS:** [`aetherctl smbtest`](cli.md#smbtest).
- **Known limit:** SMBClient negotiates only SMB 2.0.2 and 2.1. There is no SMB3 transport encryption or AES-CMAC signing, so servers set to SMB3-only or `smb encrypt = required` do not connect. (libsmb2 spoke 3.1.1, but does not work on tvOS / iOS at all.)
- **How it reads:** `SMBConnection` is a `ByteRangeSource`, and `SMBIOReader` adapts it to the engine's `IOReader`. Each synchronous read on the demux thread waits on a semaphore for SMBClient's async API, which gives a clean happens-before edge between the two. The connection is persistent (`SMBClient` plus a `FileReader`), and reads are serialised per connection. That comfortably keeps up with typical media bitrates.

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

Now Playing is the system's "what is playing" display (Control Center, the lock screen, the Siri Remote). Every opt-in here is off by default.

- **With `AVPlayerViewController`:** AVKit already provides Now Playing. Do **not** set `ownsVideoNowPlayingSession`.
- **With your own transport:** set the opt-ins you need before `load()`, and stage the item's identity (title, artwork) with `setNowPlayingInfo`.
- **Remote commands:** without `ownsVideoNowPlayingCommands`, your app registers the commands itself on `videoNowPlayingSession.remoteCommandCenter`.

Playlists, command interception and several engines in one process: [api.md › Now Playing and the audio session](api.md#now-playing-and-the-audio-session).

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

Which one applies depends on `$videoRoute`. `nativePlayerLayer` is nil on the software route, and `softwarePiPSource` is nil everywhere else. So the nil check is also the right test for showing a PiP button. A host on `AVPlayerViewController` gets PiP from AVKit on the native route and needs neither.

- **Set `pictureInPictureActive`.** It keeps the pipeline alive in the background. On the software route it also turns on the frame compositor that draws subtitles into the window.
- **Rebuild on every change of `softwarePiPSource`.** Each software load builds a new display layer, so any load ends PiP on that route and the old controller points at nothing. When the source becomes nil, the engine stops the controller it made and resets `pictureInPictureActive`.
- **tvOS:** AVKit accepts the software route's source but does not show sample-buffer content. In practice software PiP works on iOS and macOS only.
- **Subtitles in the window** come from native renditions (`prepareNativeSubtitles`) on the native route, and from the frame compositor on the software route. Never from your overlay.

Full contract, including layer geometry and the macOS window: [api.md › Picture in Picture on the software path](api.md#picture-in-picture-on-the-software-path).

## Scrub previews

```swift
if player.supportsCacheBackedStills {
    let image = await player.scrubThumbnail(atSeconds: target)   // CGImage?, nil means "time only"
}
```

`scrubThumbnail` gives you a preview image while the user scrubs. It decodes bytes the session already holds, so it opens no second connection and works on sources that allow only one.

- Show the preview only when `supportsCacheBackedStills` is true.
- A nil means "no image for this position yet", not an error. Show the time only.
- A host on `AVPlayerViewController` sets `LoadOptions(serveIFramePlaylist: true)` instead and gets AVKit's own thumbnails.
- A host that shows no previews at all sets `generatesBackgroundScrubPreviews: false`. The engine then builds no set of preview images in idle time.

Details in [api.md › Stills and thumbnails](api.md#stills-and-thumbnails).

## Drawing your own overlay in sync

Apps that draw their own overlay (with libass or similar) need to know exactly when each frame is shown. Both paths offer this.

Both return nothing rather than a guess while no timeline is established yet. A default value would look the same as a measured one.

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

**On the native path there are two timelines ("axes"), and you have to convert between them.**

- Cue times, chapters and `sourceTime` are on the **source** axis (the file's own timestamps).
- `AVPlayerItem.currentTime()` and its timebase read the **item** axis (AVPlayer's timeline).

The two differ by a shift that changes at every restart of the engine's repackaging (an "epoch": a seek restart, a live program boundary). AVPlayer's compositor pairs its samples on the item axis, so your overlay needs it too. `presentationAxisMap` does the conversion.

The frame observer is called once per packaged video frame, with both axes at once.

- It runs on the producer's pump thread, in **decode** order. With B-frames, `source` is therefore not monotonic: sort before using it as a list of frame boundaries.
- `epoch` rises strictly and process-wide. A restart and a `load()` both continue the sequence. So "a higher epoch retires my older entries" separates one item's frames from the next.

### Software path

```swift
player.softwarePresentationTimebase              // the master clock, on the source axis
player.setSoftwareVideoFrameTimeObserver { frame in
    frame.presentation; frame.generation
}
player.softwareDisplaySize                       // CGSize?, @Published
```

The software path is simpler. The engine decodes itself and passes the source timestamp through unchanged, so there is one axis and there are no segments.

- Reports arrive after the reorder buffer, in **ascending** presentation order.
- `generation` changes on every renderer flush (that is, on a seek) and rises across a `load()` the same way `epoch` does.

**Lay out against `softwareDisplaySize`**, the rectangle the frames land in. It is the coded size corrected by the pixel aspect ratio the decoder attached, read from the format description the renderer enqueues.

Do not lay out against `sourceVideoWidth` / `sourceVideoHeight`. Those are the coded size, so anamorphic content (stored with non-square pixels) is off by the pixel aspect: 720x576 at 64:45 presents as 1024x576.

`softwareDisplaySize` is nil off the software path and before the first frame. It follows a format change mid-stream and is cleared with the session. The native path measures its own rectangle on `AVPlayerLayer.videoRect`.

## Optional features

Everything here is off (or keeps its old behaviour) until you set it. The options that change what the viewer sees or hears come first.

### Upscaling low-resolution video

```swift
LoadOptions(upscalesLowResolutionVideo: true)                        // SDR below 1080p, to the display's size
LoadOptions(upscalesLowResolutionVideo: true, upscaleScaler: .lineArt) // animation only, also takes 1080p and 10-bit SDR
player.$activeUpscale   // UpscaleStatus?: what the stage is doing, nil while none runs
```

SDR video below 1080p is scaled up to the display's native size, with VideoToolbox super resolution and MetalFX (#846).

`.lineArt` runs a network made for drawn content instead (AE#1039). Set it per title, from the genre or a per-show switch: on live action it looks wrong.

- **It moves the title onto the software path,** so that path's rules apply: PiP through `softwarePiPSource`, no native subtitle renditions.
- **Some titles keep their usual route:** HDR, Dolby Vision, a display no larger than the source, and any AirPlay route. The load logs one `[Upscale]` line saying why.
- **It never stops playback.** A stage that falls behind degrades, then switches itself off. `$activeUpscale` then carries `degraded` or `disabledReason`.

Details in [api.md › upscalesLowResolutionVideo](api.md#upscaleslowresolutionvideo) and [upscaleScaler](api.md#upscalescaler).

### Subtitle offset reach

```swift
player.maximumSubtitleOffsetSeconds = 0       // no subtitle offset control in this app
player.maximumSubtitleDelaySeconds = 30       // or per direction: LATER offsets up to 30 s
player.maximumSubtitleAdvanceSeconds = 0      // and no EARLIER ones
```

**Tell the engine the largest subtitle offset your app lets the user set.** The default allows 60 s each way, and that costs memory and data:

- Bitmap subtitles (PGS, DVB, DVD) are kept as decoded images.
- An earlier offset needs a second reader, which downloads a remote source a second time (AE#929, AE#1015, AE#1031).

Pick the setting that matches your app:

- **No offset control:** set `maximumSubtitleOffsetSeconds = 0`. On a dense PGS track that keeps about 15 s of decoded images on each side, instead of a protected 120 s plus up to 64 MiB of history. On a remote MKV it stops the second download.
- **Later only:** set `maximumSubtitleAdvanceSeconds = 0` and your range in `maximumSubtitleDelaySeconds`. A later offset only needs cues already read, so it costs no second download.

Each edge stays at least 15 s, so a short nudge or a seek back still finds its cue. Details in [api.md › Cue retention](api.md#cue-retention).

### Loudness target

```swift
player.setAudioShaping(AudioShaping(loudnessTargetLUFS: -23))   // raise quiet films to -23 LUFS
```

**This lifts quietly mastered films to a target loudness.** The film is measured as it plays (BS.1770 / EBU R128) and raised by the difference, at most 18 dB. It is never lowered (AE#1036). The target is clamped to -36 to -12 LUFS.

- **Any active shaping needs PCM** (decoded audio). A stream-copied track, Atmos and every lossless bitstream included, is decoded while shaping is on, so Atmos leaves as a plain channel bed. On a setup with a receiver, offer it as a choice, not as a default.
- **Every change is a reload** that keeps the session. `$audioShapingState` says whether shaping applies; on `.remoteBypass` it reads `.unavailable`.
- The same `AudioShaping` also carries the channel cap, the dialogue lift and night mode.

Details in [api.md › Audio shaping](api.md#audio-shaping).

### Stereo downmix for a 2.1 system

```swift
player.setAudioShaping(AudioShaping(maxChannels: 2, lfeMixDB: 0))   // fold 5.1/7.1 to stereo, keep the LFE
```

**A stereo downmix drops the LFE by default.** On a 2.1 system behind a stereo link (TV to a stereo streamer or DAC with a subwoofer) that leaves the sub quiet in exactly the scenes a film puts its weight into. `lfeMixDB` mixes the LFE into left and right instead, 3 dB below the value on each side (AE#1044).

- It needs the cap. Without `maxChannels` nothing is folded, and the value alone does not count as active shaping.
- It costs what any active shaping costs: the track is decoded to PCM, so Atmos leaves as its channel bed. Offer it as an off-by-default switch.

Details in [formats.md › Audio shaping](formats.md#audio-shaping).

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

Every diagnostic line goes to `os.Logger` under the subsystem `de.superuser404.AetherEngine`, with one category per area: `engine`, `session`, `demux`, `muxer`, `hls.server`, `audio.bridge`, `sw.playback`, `scrub`, `ffmpeg`.

Release builds log too. To see the lines without a debugger, use Console.app with the device attached, or `log stream --predicate 'subsystem == "de.superuser404.AetherEngine"'`.

### Mirroring the log into your app

os_log is not stdout. A test rig that only captures stdout / stderr (`devicectl device process launch --console`, CI harnesses) sees none of it. Mirror the lines with a handler:

```swift
EngineLog.handler = { print($0) }   // every info-level line, verbatim

// Or with the category, for a viewer that files lines by area:
EngineLog.structuredHandler = { line, category, level in viewer.append(line, from: category.rawValue) }
```

- **The handler must be thread-safe and must not block.** It fires on whatever thread logged the line (demuxer, producer pump, local server, audio bridge). Hand lines to a serial queue before writing to a file.
- Per-segment trace lines are logged at `.verbose`. They only reach os_log's debug level, never the handler, so the mirrored stream stays readable.
- `aetherctl` installs exactly this handler, which is why the CLI prints what the app hides.

**Register secrets the engine cannot recognise.** The engine already strips tokens, passwords in named parameters and in the URL's user info, and the Xtream Codes path layout. A password that sits as a bare path segment in a provider URL looks like any other text, so name it:

```swift
EngineLog.registerSecret(account.password)     // false, and nothing registered, under four bytes
EngineLog.unregisterSecret(account.password)   // on logout; registrations are counted
```

Every line that reaches os_log or your handler then has that value replaced, raw or percent-encoded. Details in [api.md › Log redaction](api.md#log-redaction).

**In GUI apps, write the log to a file, on every build.** An app launched from Finder or `open` has no stdout you can read, so `print` goes nowhere (#493). Write each line to a file you can name, and flush per line:

```swift
EngineLog.handler = { line in DiagnosticFile.shared.append(line) }  // your own serial queue + flush
```

**Reading os_log afterwards** works as a fallback, but needs a time window. `log show --last 10m --predicate 'subsystem == "de.superuser404.AetherEngine"'` returns the session's lines (macOS 26.5). Without `--last`, or with a bare `log show`, the same predicate makes it look as if the engine never logged.

Lines are logged with `.public` privacy, so they arrive whole rather than as `<private>`. That is also why [`LogRedaction`](../Sources/AetherEngine/Diagnostics/LogRedaction.swift) removes credentials at the source: what reaches your file also reaches a sysdiagnose.

### Which FFmpeg answered

The first line of every session names the FFmpeg in use:

```
[FFmpeg] libavcodec 62.28.102, libavformat 62.6.100, libavutil 60.13.100, libswresample 6.0.100
```

**Read this line once per integration.** A wrong FFmpeg produces failures that look like engine bugs.

Which FFmpeg answers is decided by your executable's link, not by the package graph. If a second FFmpeg in the app takes over those symbols, this line becomes an `ERROR:` that names the mismatch and how to find it. Details in [installation.md › One FFmpeg](installation.md#one-ffmpeg-and-it-has-to-be-the-engines) and [licensing.md › Linking](licensing.md#linking-the-engine-statically).
