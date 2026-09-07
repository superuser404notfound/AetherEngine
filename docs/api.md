# Public API reference

Every public surface a host consumes, in one place. The README teaches the shape of an integration; this file is the list you check an integration against.

Two things it exists for. The first is coverage: a symbol that is public is part of the [stability contract](../README.md#stability-and-versioning), and a contract nobody wrote down is one adopters discover by accident. `Tests/AetherEngineTests/PublicAPIDocumentationTests.swift` fails the build when a host-facing public declaration is named nowhere in the documentation, so this file cannot silently fall behind the code.

The second is the class of thing an API tour organized by property type loses: the surfaces that require the host to **act**. Those come first, because they are the ones that cost a shipped app a bug report rather than a compile error.

A working shape for the live contracts below, compiled against the engine: [`Examples/LiveHost/LiveChannelHost.swift`](../Examples/LiveHost/LiveChannelHost.swift).

- [The contracts a host has to answer](#the-contracts-a-host-has-to-answer)
- [Constructing and binding](#constructing-and-binding)
- [Loading](#loading)
- [Transport](#transport)
- [Time](#time)
- [What the session is doing](#what-the-session-is-doing)
- [Audio tracks](#audio-tracks)
- [Subtitles](#subtitles)
- [Live and DVR](#live-and-dvr)
- [Picture, layers and PiP](#picture-layers-and-pip)
- [Now Playing and the audio session](#now-playing-and-the-audio-session)
- [Stills and thumbnails](#stills-and-thumbnails)
- [Diagnostics](#diagnostics)
- [LoadOptions](#loadoptions)
- [Value types](#value-types)
- [Public but not host API](#public-but-not-host-api)

## The contracts a host has to answer

### How a load ends

`load(...)` reports failure twice, on purpose, and a host that counts both counts one failure as two.

| What happened | `load()` | `state` |
| --- | --- | --- |
| The source could not be opened, probed, or routed | throws | `.error(message)` is published as well |
| A newer `load()` or a `stop()` superseded this one | throws `CancellationError` | belongs to the successor, untouched |
| A custom `IOReader` whose initial probe failed | throws | `.error` |
| Dolby Vision with no compatible base layer on the software path | throws `AetherEngineError.dolbyVisionUnplayableOnSoftwarePath` | `.error` |
| An HLS playlist handed to the raw live path by a custom reader | throws `AetherEngineError.hlsPlaylistOnRawLivePath` | `.error` |
| The session died after the load returned (source loss, a reload that never became ready, a track switch that failed) | already returned | `.error(message)` only |
| A live session the engine cannot revive | already returned | no `.error`; `liveSourceReset` fires instead |

**`CancellationError` is not a playback failure.** It is what a superseded load throws at its first checkpoint, so every channel zap, every next-episode call and every `stop()` during a load produces one. A host that retries, falls back to a second engine, or shows an error on "load threw" reacts to its own navigation unless it lets `CancellationError` through untouched.

The message inside `.error` is worth logging verbatim, and it comes from two different places. Some are the engine's own sentence and name the cause rather than the symptom (`"AVFoundation built no track for it within 45s and the source's carriage could not be identified"`, `"Live source unavailable"`, the Dolby Vision hardware refusal); a host timeout that fires first replaces that sentence with its own. The rest are forwarded from the failure underneath, and on the native paths that is `AVPlayerItem.error.localizedDescription` verbatim, which AVFoundation localizes into the device language and whose `NSError` domain and code reach the host only as whatever the localized text happens to embed.

So the string is a payload, not a key, and `$errorInfo` is the key. It publishes a `PlaybackErrorInfo` beside the state: a `PlaybackErrorKind` naming what failed in a form that survives a locale and a release, plus the underlying `NSError` domain and code wherever a Foundation / AVFoundation failure is involved. A non-nil `underlyingDomain` also marks the messages whose text the OS has localized.

Two kinds carry a number a host will want to read, and both mean the same thing happened: the origin answered the source request with an HTTP status instead of media, and `underlyingCode` is that status. `.sourceRefused` is the origin's verdict on the resource or on itself (a 401/403 refusal, which on a connection-capped IPTV panel most often means "the slot is still held", a 404, a 5xx). `.sourceRateLimited` is the same answer in the rate-limit shapes (429/503/509), split off because the recovery differs: the source is being metered, not lost, so the same request is expected to work later and a handoff to a second player meets the same meter (AE#377). Both are distinct from `.sourceOpenFailed`, which is what a corrupt or unreadable source produces; before `.sourceRefused` existed a refusal and a corrupt file arrived alike as "Invalid data found when processing input".

`.sourceCertificateRejected` is the same argument one layer lower: the transport was refused over certificate trust, so there was never a response to carry a status. `underlyingCode` is the `NSURLErrorDomain` code (-1200 through -1206), and the message is the engine's own English sentence rather than the OS one, so a pasted report says the same thing on every device. It reaches a host from either path: on the FFmpeg path the reader types the failed open, and on the native path the URL error is found under AVFoundation's own error, which is where it sits and where nothing used to look. Nothing about the media is wrong and no retry helps; a self-signed or private-CA origin needs a trust decision the host makes (AE#495).

```swift
player.$state
    .sink { state in
        guard case .error = state, let info = player.errorInfo else { return }
        analytics.record(failure: info.kind.rawValue,          // stable token, carries no origin
                         domain: info.underlyingDomain,
                         code: info.underlyingCode,
                         route: player.videoRoute.rawValue,
                         checkpoint: player.startupProgress?.checkpoint.rawValue)
        log(info.message)                                      // for a human, not for a bucket
    }
```

It is assigned before `state`, so a `$state` sink reads this failure's own info rather than the previous one's, and it is cleared by the state's move away from `.error`, so the two cannot drift. Substring rules over the message instead bucket every non-English device into "other".

### `.ended` is terminal

`.ended` means the source played to completion, on any backend. It is not a pause at the last frame:

- `seek(to:)` is rejected with `SeekEvent.Rejection.noActiveSession`
- `play()` and `togglePlayPause()` do not revive the session

To replay, call `load(...)` again. The engine keeps `.ended` terminal deliberately: a play press racing a host's end card must not silently restart a finished session (#63/#164). A VOD **parked at its final frame** without having ended (scrubbed there, paused there) is the other case and does resume: `play()` rewinds to the start first.

The clock stops with it, on both backends: `clock.currentTime` and `clock.sourceTime` settle on the last sample and stay there, so a progress bar bound to them holds at the end instead of walking past `duration`. Through 6.28.0 the software path was the exception: its master clock kept its rate past end of media, so a session left standing published a position that grew without bound (20.13 s on a 12.0 s source after 20 s, against 11.97 s from a native session on the same file). A host reading the clock after `.ended` on one of those builds is reading that, not a drifting session (AE#374).

### Live: the retune request

```swift
player.liveSourceReset            // PassthroughSubject<Void, Never>; subscribe per session
```

Live's counterpart to a terminal `.error`, and a host that plays live has to subscribe. It fires where the session cannot be revived from inside the engine and only a new `load` can: a source restarted from byte 0 (a transcode respawn), a playlist still frozen after the stall ladder's last reload rung (#65), an in-engine reopen transport whose budget is spent (#199). Production is halted before it fires.

Answering it: negotiate a fresh URL and `load` again, or, where the URL is fixed (an IPTV channel), load the same one again. Guard the answer with one retune in flight, a minimum spacing and a bounded count per session, then surface the exhausted case the way a terminal `.error` would be surfaced, because a ladder that ends on a silent `return` leaves the same dead channel behind a counter.

The same-URL answer is the cheap one rather than a no-op: the #168 carriage verdict (a master advertising HEVC while delivering MPEG-TS) is remembered per exact absolute URL for six hours, 32 entries, so the retune routes straight onto the live ingest instead of re-paying the doomed native mount and its watchdog grace. A URL carrying a rotated per-session token misses that memory and re-pays the one-time discovery per retune, which is worth knowing where a first-frame budget is measured against the retune as well.

Where the token rotates, the key the memory cannot have is one the host does have: the channel. `$videoRoute` publishes the reroute as it happens (`.remoteBypass` becomes `.loopback`), so a host can record that verdict against its own channel id and open the channel's next session on the ingest directly, either with `nativeRemoteHLS: false` (an `m3u8` on the raw live path is routed onto the ingest reader from 6.24.0, at the cost of one failed open) or by handing `HLSLiveIngestReader` to `.custom(_:formatHint: "mpegts")` itself, which costs nothing at all. Either skips the native mount and up to 4 s of carriage-watchdog grace per retune, whatever the URL looks like that time.

Left unsubscribed it costs a channel that stops while the engine still reports a session, which from the outside is indistinguishable from a slow one. The guard, written out: [`Examples/LiveHost/LiveChannelHost.swift`](../Examples/LiveHost/LiveChannelHost.swift).

### The system asks for captions

```swift
player.systemCaptionRequest       // PassthroughSubject<SystemCaptionRequest, Never>; subscribe per session
```

iOS 26's Automatic Subtitles (show when muted, on skip back, on a language mismatch) turn captions on with no read API behind them, so the selection is the only observable ask. The engine deselects its own rendition, because one rendered in fullscreen draws a caption box over the host's overlay, and forwards the request with the language it named. A host that wants the behaviour answers by selecting its own matching track.

### The audio tap ends with its session

`installAudioTap()` returns an `AsyncStream<AudioTapBuffer>` bound to the session it was installed against. It finishes on `load()`, on `stop()`, and on a **session-preserving reload**: an audio-track switch, a subtitle-track switch, a disc-title switch, `reloadAtCurrentPosition()`. Re-install on stream end to follow the new session (#356). This is deliberate rather than a gap: each install gets a fresh monotonic filter, so the new session's timeline starts clean instead of stitched across a reload that resumes slightly behind the old position.

Read `audioTapHasDeliverySource` synchronously after installing: false means the stream will finish without yielding (no session, a video-only source, a backend with no tap path), which is the moment to fail loudly rather than await an empty stream.

### Correcting a `LoadOption` without restarting the item

`reloadAtCurrentPosition(applying:)` is the session-preserving rebuild with the options it replays
taken from the host rather than from the session (#460).

```swift
try await player.reloadAtCurrentPosition { $0.httpHeaders["Authorization"] = "Bearer \(fresh)" }
```

The closure is seeded with the options the session is CURRENTLY running on, which is not always what
was passed to `load`: the engine rewrites its own routing fields on a reroute. Change what needs
correcting and leave the rest alone. The change is installed into the session before the rebuild, so
every internal reopen that follows (an audio switch, a background reload) replays the correction
instead of reverting to the load-time value.

A fresh `load()` is not the same thing, which is the whole reason this exists. `load` cannot reach
`subtitleSessionCarryover` or `isLiveRejoin`, both settable only from inside the engine, so it wipes
the id-exact external-subtitle registry, every mid-session `addExternalSubtitleTrack`, the host's
explicit subtitle authority (subtitles explicitly OFF included) and the live rejoin contract, and
re-derives them by auto-selection. This reload keeps all of it, at the same teardown cost the plain
`reloadAtCurrentPosition()` already pays.

`autoplay` is the one listed field this cannot change. The rebuild comes back in the transport state
the session is actually in (AE#464 round 2), so a correction that sets it is overwritten rather than
refused; use `play()` / `pause()` around the correction if the rebuild should change the transport.

Two refusals, both raised BEFORE any teardown, so a refused correction leaves the session playing:

| Thrown | When |
| --- | --- |
| `AetherEngineError.loadIdentityNotCorrectable(fields:)` | the closure changed `isLive`, `audioOnly`, `nativeRemoteHLS` or `sequentialOrigin`. These name the session rather than tune it (each opens the source on a different pipeline, and the engine writes the last two itself), so changing one is a different item, not a correction of this one. Load the source again. |
| `AetherEngineError.sessionNotReloadable(_:)` | there is no session, or the source is a custom `IOReader` that reported itself non-seekable and cannot be reopened at the current position. It carries a `SessionReloadRefusal` (`.noActiveSession` / `.customSourceNotSeekable`) saying which. |
| `AetherEngineError.sessionNotReloadable(.softwarePathCannotRepresentSource)` | the correction moves a native session onto the software path, and this source's only signal is IPT-PQ-c2 (Dolby Vision HEVC Profile 5, AV1 Profile 10.0). The software decoders hand that on as YCbCr, so the picture would render green/purple. |
| `AetherEngineError.sessionNotReloadable(.demuxedAudioLiveIsNativeOnly)` | the correction moves a demuxed-audio live session onto the software path, where the side-audio merge does not exist, so it would play silent. |

Both are all-or-nothing: a correction refused for one field installs none of it.

**Where a correction lands.** A URL source rebuilds through the full `load`, so every field applies.
A custom `IOReader` source rebuilds through the narrower reopen that keeps the retained reader, and
that path replays `loadedOptions` field by field instead of passing a struct through `load`: the
routing, probe-budget, live-join, deinterlace and subtitle-preparation fields all apply there, but
the four consumed by `load` itself (`preferredAudioLanguages`, `externalSubtitles`,
`maxConcurrentSourceRequests`, `autoplay`) are installed and take effect at the next load. The
custom reload carries the session's explicit audio pick and its own subtitle re-arm, so the two
language lists have nothing to decide on that path anyway.

`preferredDecodePath` is in the first group and was briefly in neither: the reopen picked its host
from the backend the session was already on, so a decode-path correction on a custom source was
accepted, named in the log and then ignored. It now asks the same routing policy `load` asks, seeded
with that backend, so the correction lands on both source shapes. The direction is what makes that
safe: `DecodePath` has no `.native`, so the only flip the reopen can make is native to software, and
the software path is the general one. What the software path cannot REPRESENT is refused before any
teardown instead (the two rows above), because the guards that catch it inside `load` run after the
routing decision, and reaching them on a correction would mean failing a session already torn down.

Unlike `reloadAtCurrentPosition()`, which returns silently when there is nothing to rebuild, this one
throws, because a host correcting a session has to tell "corrected" from "did nothing" to decide
whether to fall through to a fresh load. `sessionReloadRefusal` returns the same `SessionReloadRefusal` for
either reload without attempting one, and nil when a rebuild would happen.

A rebuild that FAILS also throws, on both source shapes. The custom-source branch used to publish its
error and return as if the session had come back, so a correction could report success while the
session sat in `.error`; it now throws what the rebuild threw, the way the URL branch always has. A
rebuild superseded by a newer `load` or `stop` is not a failure and still returns normally, because
the newer load owns the session.

### Overriding the decode path

`LoadOptions.preferredDecodePath` is the per-session escape onto `SoftwarePlaybackHost` (#461).

```swift
// at load
options.preferredDecodePath = .software
// or on a session that is already playing, through the #460 reload
try await player.reloadAtCurrentPosition { $0.preferredDecodePath = .software }
```

`VTCapabilityProbe.canHardwareDecode` **fails open by design**: four classes it cannot classify
(no extradata, Annex-B extradata, in-band parameter sets, a format-description build failure) keep
the native path. That is the right default, and occasionally wrong. When VideoToolbox then cannot
build a decoder for what arrives, the item reaches `readyToPlay` and renders nothing, and in-band
parameter sets (`hev1` / `avc1` with an empty config record) are the class where the deciding
evidence genuinely is not present at load time. A live load never reaches that gate at all: the
capability check is VOD-only, so a live session keeps the native path with no classification step.

Detecting the symptom is a host's own job and is not hard (`AVPlayerItemVideoOutput.hasNewPixelBuffer`
against `softwareHostFramesEnqueued`, both already exposed). The escape was the missing half. Before
this the two levers were `setForceSoftwarePathForTesting`, which is process-global and therefore
drags every concurrent session on a shared engine, and presenting a custom `IOReader` whose seek
fails, which reaches the software host by costing the source its seeks, its mid-session audio
switch, its title switch and `reloadAtCurrentPosition` itself.

Three properties worth knowing:

- **One-way.** `DecodePath` has `.automatic` and `.software`, and no `.native`. Every route the
  engine sends to software it sends there because the native path cannot serve it (AV1 without
  hardware decode, VP9, a forward-only source, MVC carriage), so forcing native past those buys a
  black screen. A host's evidence is only ever "this native session is not decoding".
- **It does not suspend what the software path cannot represent.** A source whose only signal is
  IPT-PQ-c2 (Dolby Vision HEVC Profile 5, AV1 Profile 10.0) still fails the load with
  `dolbyVisionUnplayableOnSoftwarePath` rather than decoding as YCbCr and rendering green/purple,
  and a demuxed-audio live source still fails rather than playing silent. An override says which
  host serves the session, not what that host can do.
- **`nativeRemoteHLS` is a different route.** AVPlayer plays the remote playlist and the engine
  demuxes and decodes nothing, so there is no decode path to prefer. The engine logs that it
  ignored the preference rather than letting it look applied.
- **A mid-play correction lands on both source shapes**, URL and custom `IOReader` alike, and moves
  the session at its own playhead without a restart. On a source the software path cannot represent
  the correction is refused before any teardown, with `SessionReloadRefusal`
  `.softwarePathCannotRepresentSource` or `.demuxedAudioLiveIsNativeOnly`, so the session it refuses
  is still the session that was playing. Measured on the Dolby browser test kit, which carries the
  discriminator: the Profile 5 cut of a clip is refused and left playing on VideoToolbox, while the
  Profile 8.1 cut of the SAME material and grading is honoured and rebuilds on `libavcodec HEVC (SW)`.

### Reading whether the audio was delivered

`$audioDelivery` publishes an `AudioDelivery`: how this session's audio reaches the renderer, as a
typed fact rather than as something to reconstruct (AE#462).

| Value | Meaning |
| --- | --- |
| `.none` | no session |
| `.noAudioInSource` | the source carries no audio track, or none was selected |
| `.streamCopy` | the source bitstream is muxed into fMP4 unchanged (Atmos, DTS-HD and everything else reach the renderer as authored) |
| `.bridged` | decoded and re-encoded to FLAC or E-AC-3 for the fMP4 pipeline; lossless for the bed channels, object metadata does not survive the PCM intermediate |
| `.decoded` | libavcodec decodes and the engine renders it (the software path, the FFmpeg audio-only host) |
| `.droppedNoPipeline` | the source HAS audio and none of it could be delivered: no decoder for it in this build, or the bridge could not be built or could not write its header. The session plays video-only and silently |
| `.playerManaged` | AVFoundation owns the audio (the remote-HLS bypass, the native audio-only host). The engine has no pipeline of its own to classify and does not answer on AVFoundation's behalf |

**`.droppedNoPipeline` is the one a fallback ladder acts on**, the same way it demotes on
`PlaybackErrorKind.audioBridgeProducedNoOutput`. The two are the same user outcome from opposite
ends of the cascade: that kind fails loudly when a bridge WAS built and then decoded nothing, this
value reports a bridge that could never be built at all. Neither ends a ladder: re-serving the
source with audio the pipeline can carry (a server-side transcode, a second player that decodes it
itself) plays it.

It is not a `PlaybackErrorKind` because that taxonomy is terminal: `state` moves to `.error` and
`errorInfo` is cleared by the state's own move away from it. Video-only playback is neither
terminal nor an error for every host.

```swift
player.$audioDelivery
    .filter { $0 == .droppedNoPipeline }
    .sink { _ in ladder.demote(reason: .silentVideo) }
```

`$activeAudioDecoder` is the same fact for a human ("Stream-copy (EAC3+JOC Atmos)",
`"TrueHD → FLAC bridge"`, `"libavcodec AC3 → CoreAudio"`) and stays the right thing to show in a
stats overlay. Do not classify on it: it cannot separate a source with no audio from a source whose
audio was dropped, and before AE#462 it was outright wrong on the software path, where it was built
from the probe's track list and so named a decoder that had refused to open. Both publishers are
now written from the pipeline that serves the session, so `.droppedNoPipeline` and a nil label
arrive together.

### What must be set before `load()`

| Set before the load | Why |
| --- | --- |
| `ownsVideoNowPlayingSession` | read when the native host is created; a host preserved across a native to native reload keeps what it was created with |
| `LoadOptions.preferredAudioLanguages` | the picked audio track is muxed at the first frame; a later `selectAudioTrack` costs a reload |
| `LoadOptions.prepareNativeSubtitles`, `externalSubtitles` | the native renditions are declared in the init segment |
| `LoadOptions.panelIsInHDRMode`, `panelPresentsDolbyVision`, `matchContentEnabled` | the display-criteria handshake and the format clamp both run synchronously inside `load` |
| `pictureInPictureActive` | governs the background teardown decision at the moment it happens |

### Isolation, and what runs off the main actor

`AetherEngine` is `@MainActor`. Every method and property in this reference is main-actor isolated unless it says otherwise, so a host drives it from the main actor and gets its published values there too.

Four exceptions, and each is an exception for a reason:

- **`AetherEngine.probe(...)` and `probeDetectingAtmos(...)` are `nonisolated` and synchronous**, and they open the source: a HEAD plus an initial range on a network URL, a real decode pass for the Atmos variant. Call them from a detached task or a background queue. On the main actor they block it for as long as the origin takes, which on a slow one is seconds.
- **`presentationAxisMap` is `nonisolated`**, precisely so a compositor pairing samples off the main actor can convert without hopping.
- **The two frame-time observers are `@Sendable` and are called on the pipeline's own threads**: the producer pump for `NativeVideoFrameTimeObserver` (in decode order), the renderer for `SoftwareVideoFrameTimeObserver` (in presentation order). They must not block and must not assume the main actor.
- **`EngineLog.handler` fires from whatever thread emitted the line** (demuxer, producer, local server, audio bridge). Serialize onto your own queue before writing anywhere.

`player.clock` is a separate `@MainActor ObservableObject` on purpose: its ~10 Hz ticks would otherwise fire `objectWillChange` on the engine and re-render every view observing it, which on tvOS rebuilds open `Menu` dropdowns mid-interaction. Time-driven UI observes `clock`, everything else observes the engine. `diagnostics` is split out for the same reason at 1 Hz.

`FrameExtractor` is an `actor`, so its `thumbnail` / `snapshot` / `prewarm` / `shutdown` are `await`ed from anywhere. The audio tap's `AsyncStream` is likewise consumed from any task; only `installAudioTap()` itself is main-actor.

### One FFmpeg, and it has to be the engine's

AetherEngine calls `avcodec_*`, `avformat_*`, `avutil_*` and `swr_*` as ordinary external symbols. Which binary serves them is decided by the host executable's link, not by the package graph, so a second FFmpeg anywhere in the app can take the calls. Two shapes do it, and neither announces itself:

- **A static FFmpeg pulled in with `-force_load`.** Its symbols become ordinary definitions inside the executable, and a definition in a `.o` beats a dylib for every other object in the same link.
- **A dependency that exports the same symbols.** libVLC is the common one, and it is a reasonable thing to have beside AetherEngine, since the fallback ladder the API is built around invites exactly that pairing. CocoaPods sorts a pod ahead of a vendored framework, so libVLC's libavcodec wins by default.

The engine then runs against headers it was never compiled against: struct layouts, codec ids and the encoder set are all whatever the other build decided. Symptoms do not look like a linking problem. They look like a defect in the engine, and specifically like a defect in whatever the other build happens to be missing.

Every session says which FFmpeg answered, once, at `init`:

```
[FFmpeg] libavcodec 62.28.102, libavformat 62.6.100, libavutil 60.13.100, libswresample 6.0.100
```

and when a major does not match the headers the engine compiled against, that line becomes an `ERROR:` naming the mismatch, the likely cause and the two commands that show it:

```
$ nm -m <executable> | grep _avcodec_find_encoder     # which binary wins
(__TEXT,__text) external _avcodec_find_encoder        #   a definition in the executable itself
(undefined) external _avcodec_find_encoder (from MobileVLCKit)   #   or someone else's dylib

$ otool -L <executable>                               # and in what order
```

The fix is the host's, because nothing inside a library can reach it: link AetherEngine's frameworks ahead of the other FFmpeg, or drop the second copy. The majors the engine expects are the ones FFmpegBuild's headers declare for the pinned version; the line above prints both sides, so there is nothing to look up.

This is not hypothetical. AE#396 was reported as an audio-bridge defect, reproduced on five fixtures and two devices, and was a second FFmpeg one major behind: the engine's only trace was `flac bridge encoder absent from this FFmpeg build`, a true sentence about a build that was not the engine's. That line now names the libavcodec that answered.

### Holding a second player beside the engine

A ladder that keeps KSPlayer, mpv or MobileVLCKit for the formats it already covers is a normal shape, and since FFmpegBuild 3.0.0 the engine's FFmpeg is named so it can live there. The frameworks ship as `AetherLibavcodec`, `AetherLibavformat`, `AetherLibavutil`, `AetherLibswresample`, `AetherLibswscale`, `AetherLibavfilter`, `AetherLibdav1d`, `AetherLibzimg` and `AetherLibzvbi`, and the install names follow (`@rpath/AetherLibavcodec.framework/AetherLibavcodec`). SwiftPM target names are unique across the whole dependency graph and two framework bundles cannot share one path in `App.app/Frameworks/`, so before the prefix a package graph holding both simply did not resolve.

If the other FFmpeg is itself a set of **dynamic** frameworks, that is the whole fix. The two-level namespace records per reference which dylib a symbol came from, so the engine reaches its libavcodec and the other player reaches its own, in one process, with no link-order argument to win.

If the other FFmpeg is **static**, the rename is not enough, and no rename could be: `_avcodec_open2` is `_avcodec_open2` in every FFmpeg there is. Its symbols become definitions inside the executable, and the engine, statically linked beside them, binds to those. The remedy is to stop linking the engine into the executable:

1. Add a dynamic framework target to your project, say `PlayerEngineKit`, and link the `AetherEngine` product into that target instead of into the app.
2. Embed the `AetherLib*` frameworks in the app as usual (Xcode does this for you when the package is linked).
3. Have the app talk only to `PlayerEngineKit`.

The engine's `_av*` references are then resolved when that framework links, against `AetherLibavcodec.framework`, and recorded as coming from it. Whatever the executable defines for its own player no longer participates. This is the same construction that lets MobileVLCKit's FFmpeg and FFmpegKit coexist today.

Two commands confirm it, and they are worth running once rather than trusting the arrangement:

```
$ nm -m PlayerEngineKit.framework/PlayerEngineKit | grep _avcodec_open2
(undefined) external _avcodec_open2 (from AetherLibavcodec)   # right: it comes from ours

$ otool -L PlayerEngineKit.framework/PlayerEngineKit | grep -i libavcodec
@rpath/AetherLibavcodec.framework/AetherLibavcodec
```

And the engine says it itself: the `[FFmpeg] libavcodec …` line at `init` reports the versions that actually answered, not the ones it was built against, so a wrong binding shows up in the log before it shows up as a defect.


## Constructing and binding

```swift
let player = try AetherEngine()
```

| Symbol | What it is |
| --- | --- |
| `AetherEngine()` | `public init() throws`, `@MainActor`, an `ObservableObject`. One engine per playback surface, and several against one origin cost that origin one long-lived request each (see `maxConcurrentSourceRequests`). The audio-session category is declared off-main and never activated here, because AVKit activates per playback and that is what lets tvOS negotiate the HDMI route (#24). |
| `AetherPlayerSurface(engine:)` | SwiftUI view. Drop it in the tree; it mounts and binds an `AetherPlayerView` for you. |
| `AetherPlayerView` | UIKit / AppKit view (`PlatformBaseView` is `UIView` or `NSView`). Hosts the engine's layer. |
| `bind(view:)` | Attach a view. The engine swaps the hosted `CALayer` per session (`AVPlayerLayer` or `AVSampleBufferDisplayLayer`), so a bound host needs no per-route branch. |
| `unbind(view:)` | Detach. The engine holds the view weakly, so this is for hosts that reuse one engine across surfaces. |

## Loading

```swift
try await player.load(url: url)
try await player.load(url: url, startPosition: 347.5, options: LoadOptions(...))
try await player.load(source: .custom(reader, formatHint: "matroska"), options: ...)
try await player.reloadAtCurrentPosition()
```

| Symbol | Contract |
| --- | --- |
| `load(url:startPosition:options:audioSourceStreamIndex:discTitleID:)` | `async throws -> SourceProbe?`. Discardable. Tears down any running session first. |
| `load(source:startPosition:options:audioSourceStreamIndex:discTitleID:)` | Same, for `MediaSource.url` or `.custom(IOReader, formatHint:)`. A custom source whose initial probe fails throws, since it cannot be reopened by URL. |
| `reloadAtCurrentPosition()` | `async throws`. Background reopen at the current position, preserving options. Session-preserving: it finishes an installed audio tap and keeps the native host where it can. It also preserves the session's TRANSPORT rather than replaying `autoplay`, so a session that was playing comes back playing and one that was paused comes back paused, whatever the mount was given (AE#464 round 2). The one exception is the resume after a background teardown, which has no transport left to read and is the host's call, so there the mount flag still decides. |
| `prepareForItemReplacement()` | One-shot. Keeps the current native `AVPlayerItem` attached until the next `load()` replaces it atomically, for a host that mounts the engine's own player layer and would otherwise show a black layer across the nil-item gap of a foreground episode or playlist change. Consumed by the next `load()`, cancelled by `stop()`, no effect when the outgoing session is not native. PiP hosts do not need it: an active PiP window already forces the handover (AE#158). |
| `stop(resetDisplayCriteria:finalTeardown:)` | Ends the session, `state` becomes `.idle`, `startupProgress` becomes nil. `resetDisplayCriteria: false` keeps the panel in its current mode across an item handoff. |
| `AetherEngine.probe(url:options:)` / `probe(source:options:)` | `nonisolated static throws -> SourceProbe`. Demux-only metadata read, no decoders, no session. `options` is read for `httpHeaders` only. For a custom reader the caller keeps ownership, `close()` is not called, and the cursor is left unspecified. |
| `AetherEngine.probeDetectingAtmos(url:options:atmosDetection:)` | `probe` plus a bounded decode pass that authoritatively resolves E-AC-3 JOC for an Atmos badge. Strictly more expensive; never on the playback-start path. Decode-side failures degrade to "not confirmed" rather than throwing. |
| `AetherEngine.externalSubtitleTrackIDBase` | `100_000`. Synthetic ids of external subtitle tracks start here. |

`IOReader` is the custom-source protocol: `read`, `seek`, `close` are required; `cancel()`, `makeIndependentReader()` and `discImageProbeEnabled` have defaults that unlock teardown-unblocking, embedded subtitles plus scrub stills, and ISO/UDF probing respectively. Calls arrive on the engine's demux thread, each inside an autorelease pool the engine opens, so a reader built on `FileHandle` or `NSData` does not strand one autoreleased object per read for the length of a session. Full contract in [formats.md](formats.md).

## Transport

| Symbol | Notes |
| --- | --- |
| `play()` | Rewinds first when parked at the final frame of a VOD; a no-op on `.ended`. |
| `pause()`, `togglePlayPause()` | |
| `seek(to:)` | `async`. Source-axis seconds. Rejected when idle, errored, ended, or live without a DVR window. |
| `seek(toSourceTime:)` | Deprecated alias for `seek(to:)`. The clock is unified onto source PTS, so the two are the same call. |
| `setRate(_:)` | Clamped to `maxSupportedRate`; `0` pauses. The speed holds across pause and resume and across the host rebuilds a session makes on its own (reload at position, audio-track switch, AirPlay LAN swap, background return), and it belongs to the item: loading a different source, or `stop()`, returns to 1.0. Pitch-preserving on both decode routes: `audioTimePitchAlgorithm` is pinned to TimeDomain on the native player item and on the software path's audio renderer, so a speed control never has to be gated on which route a title took. |
| `audioDelaySeconds`, `setAudioDelay(_:)` | Lip-sync correction for the viewer's chain, in seconds; positive presents audio later than video. Clamped to +/-2 s and, like `setRate`, it holds across the rebuilds a session makes on its own and belongs to the session. Applied where the engine still holds the timestamps: the stamped sample PTS on `.software`, the audio track of the fMP4 segments on `.loopback`. AVFoundation exposes no equivalent on either surface a host can reach, so on `.remoteBypass` and on audio-only sessions the value is kept for the next load and the no-op is logged rather than faked. Not free the way `setRate` is: the audio already decoded or already fetched is committed to the previous value and cannot be re-timed in place, so a change re-anchors at the playhead. On `.software` that is a seek to the current position; on `.loopback` it is the session-preserving reload, because seeking to the position AVPlayer already holds is a buffer hit and plays the old-offset segments out anyway. Measured on a 30 fps H.264 fixture: about 0.3 s of held picture on the loopback route, position preserved. A live session without a DVR window has no position to return to and takes the new value at the next seam it makes on its own. |
| `maxSupportedRate` | 2.0 for video, 3.0 audio-only. Query after load; returns 2.0 while idle. Size a speed picker against it. |
| `volume` | 0.0 to 1.0. A write before a session exists is remembered and applied at load. |
| `selectTitle(id:)`, `selectChapter(id:)` | Disc titles and chapters. |

## Time

Time lives on `player.clock`, a separate `ObservableObject`, so ~10 Hz ticks never fire `objectWillChange` on the engine.

| Symbol | Axis |
| --- | --- |
| `clock.$currentTime` | playback clock, the scrubber axis |
| `clock.$sourceTime` | source PTS of the displayed frame; render subtitle overlays against this |
| `clock.$progress` | `currentTime / duration` |
| `clock.$bufferedPosition` | source-axis position buffered ahead |
| `clock.$liveEdgeTime`, `clock.$seekableLiveRange`, `clock.$behindLiveSeconds`, `clock.$isAtLiveEdge` | live-window surfaces. `seekableLiveRange` is the intersection of the DVR window (policy) and what the segment cache actually holds and can play forward from (fact), so it is honest to scale a rewind strip on and `seek(to:)` clamps to the same floor (AE#441). The two diverge for the whole first `dvrWindowSeconds` of a session and again whenever retention evicts faster than the window slides. Software live sessions have no such cache and keep the arithmetic bound. |
| `$residentRanges` | where the loopback segment cache holds picture right now, as disjoint ascending spans on the `currentTime` axis. This is the cache's own truth, not AVPlayer's `loadedTimeRanges`: a measured session held 64 segments over four minutes across several islands while AVPlayer exposed roughly twelve seconds around the playhead and forgot a seeked-ahead island as soon as the playhead left it. Empty is the nil-equivalent, and a live session publishes empty always (its rewind depth is `seekableLiveRange`, which answers a different question). Residency is not a promise that a seek inside a span is instant: the player may still re-anchor and decode at the target, and a segment can start mid-GOP (AE#412). Coalesced to at most four updates a second, cleared on `load()` and teardown. |
| `player.currentTime`, `sourceTime`, `progress`, `bufferedPosition`, `liveEdgeTime`, `seekableLiveRange`, `behindLiveSeconds`, `isAtLiveEdge` | non-published mirrors of the same values for one-shot reads |
| `$duration` | seconds; a `LoadOptions.declaredDurationSeconds` outranks the container's |

## What the session is doing

| Symbol | Reading |
| --- | --- |
| `$state` | `.idle`, `.loading`, `.playing`, `.paused`, `.seeking`, `.ended`, `.error(String)`. |
| `$errorInfo` | `PlaybackErrorInfo?`, the machine-readable half of `.error`: a `PlaybackErrorKind` token, plus the underlying `NSError` domain and code where one is involved. Non-nil exactly while `state` is `.error`, assigned before it. Classify on this, never on the message. |
| `$playbackPhase` | The derived one-source-of-truth status, and **the only one of these that tracks motion**: `state` is transport INTENT and turns `.playing` the moment the engine has called `play()`, which on a live join can be seconds before the rate rolls (AE#440). Until the transport has moved once in a load, the phase stays `.loading`, and it turns `.playing` on the roll itself. Adds `.rebuffering` and `.stalled(reconnecting:)`. Prefer it over stitching `state` + `isBuffering` + `isSeeking`, and over matching log text. Precedence, highest first: `error > ended > idle > loading > stalled > seeking > rebuffering > playing/paused` - a source that stopped delivering stays visible while a seek is in flight, because no seek can land over it and `isSeeking` / `seekEvents` still carry the seek (#410). `.stalled(reconnecting: true)` is a reader that is retrying, `false` a reader whose ladder is spent and whose recovery has passed to the producer's reopen; both mean the source is down. `.rebuffering` is published on the AVPlayer-backed paths: the native loopback session, direct remote HLS, and the bare-AVPlayer audio host (a starved progressive stream, once the item has played), where `.stalled` cannot occur because there is no reader. The FFmpeg-backed hosts (software video, FFmpeg audio) have no AVPlayer to wait, so a starving source reads as `.stalled` there instead. |
| `$isBuffering`, `$isSeeking`, `$seekTarget` | The raw axes `playbackPhase` folds. |
| `seekEvents` | `AnyPublisher<SeekEvent, Never>`: `.began`, `.landed(renderedTime:)`, `.stalled`, `.superseded`, `.rejected(SeekEvent.Rejection)`, each with its `target`, an `id` that spans the seek, and a `SeekEvent.Origin` (`.programmatic`, `.nativeScrub`, `.deferred`; a deferred seek is one the session could not take yet, which is where the engine publishes an optimistic `currentTime` for a position nothing has reached). Use it where the falling edge of `$isSeeking` matters: a level cannot say whether a seek landed, gave up, or was superseded, and a `.stalled` seek can still land later under the same id. |
| `$isSessionReady` | The session is ready in the AVFoundation sense. Not the edge a black cover comes off on. |
| `$hasFirstFrameReadyForDisplay` | The picture for **this** load is up. A picture, not motion: a live join presents its first frame and can then hold it bit-static for seconds while AVPlayer decides whether to start (AE#440), so a host dropping a spinner here drops it onto a frozen frame. Use `$playbackPhase` for "it is moving". Latched for the load, cleared at the next `load()` / `stop()`. Audio-only sessions never arm it. On an external screen (`isExternalPlaybackActive`) the local layer never reaches readiness, so the item's readiness is the honest edge and the flag latches there (#315). |
| `$startupProgress` | `StartupProgress?` for a determinate loading bar. |
| `$videoRoute` | `VideoRoute`: which pipeline is actually serving, one of `.none`, `.remoteBypass`, `.loopback`, `.software`, `.audio`. `LoadOptions.nativeRemoteHLS` is only the request; the carriage watchdog, the remembered verdict and the HLS reroutes move a session between routes, mid-session too. Branch on this, above all for who draws subtitles. |
| `$audioDelivery` | `AudioDelivery`: how the audio reaches the renderer, one of `.none`, `.noAudioInSource`, `.streamCopy`, `.bridged`, `.decoded`, `.droppedNoPipeline`, `.playerManaged`. `.droppedNoPipeline` is a source that HAS audio playing video-only because no pipeline could be built for it: the value a fallback ladder demotes on. See [Reading whether the audio was delivered](#reading-whether-the-audio-was-delivered). |
| `$videoFormat` | The format being presented: `.sdr`, `.hdr10`, `.hdr10Plus`, `.dolbyVision`, `.hlg`. |
| `$sourceVideoFormat` | The format the **source** carries, before any panel-driven mapping. The pair is what an honest badge needs: HDR content on an SDR panel differs between the two. |
| `$sourceDVProfile`, `$sourceVideoFrameRate`, `$sourceVideoBitrate` | Source detail for an info panel. |
| `$sourceVideoCodecName` | The source video codec in the libavcodec spelling ("hevc", "h264", "av1"), nil when the source carries no video. The probe-free remote-HLS bypass maps it back from the item's video sample type, so the field answers on every route rather than going quiet on one of them. Not the same question as `$activeVideoDecoder`: a codec has several decoders, and which one runs depends on the hardware. |
| `$sourceContainerFormat` | The container libavformat opened ("matroska,webm", "mpegts"), nil on the remote-HLS bypass, where AVFoundation opens the source and there is no libav context to ask. This is the container that ARRIVED, which on a remux or transcode session is not the one a host's library metadata describes. |
| `$activeVideoDecoder`, `$activeAudioDecoder` | The decoder names actually in use, for a stats overlay. This is the honest "what is decoding this" surface; `playbackBackend` is not. Show `$activeAudioDecoder`, classify on `$audioDelivery`: a label cannot separate a source without audio from a source whose audio was dropped. |
| `$metadata` | `MediaMetadata` parsed at load (title / artist / album / cover). |
| `$mediaChapters`, `$discChapters`, `$discTitles`, `$selectedDiscTitle` | Container chapters, and disc titles / chapters for DVD and Blu-ray ISO sources. |
| `$currentAVPlayer`, `$currentAVPlayerItem` | The live AVFoundation objects, re-emitted on every reload. Both nil on `.software`, which renders into its own layer. A host that only ever hands `currentAVPlayer` to an `AVPlayerViewController` gets audio over an empty video plane on that route (#298). |
| `AetherEngine.displayCapabilities` | `static DisplayCapabilities`: `supportsHDR`, `supportsDolbyVision`, `supportsHDR10`, `supportsHLG` for the current display. What a settings screen should read instead of guessing from the device model. On macOS the table comes from `AVPlayer.eligibleForHDRPlayback` (there is no per-mode API there) and leaves Dolby Vision unclaimed, which is what `LoadOptions.panelPresentsDolbyVision` is for. |

`StartupProgress` carries `checkpoint`, `completed`, `total`, `fraction`, `stage` (a `StartupStage` naming the work in flight, for a label beside the bar), `generation`, `isComplete`. Every value is work some part of the load finished, never a timer and never an estimate, so a slow stretch holds and a skipped one jumps. The ladder, in order:

| `StartupCheckpoint` | Finished work |
| --- | --- |
| `.dispatched` | `load()` accepted the request; the previous session is torn down |
| `.sourceOpened` | the source is open and its first bytes arrived (connection, redirects, size probe) |
| `.containerOpened` | `avformat_open_input` returned: the container is identified |
| `.streamsProbed` | `avformat_find_stream_info` returned. On a slow origin the longest single stretch, and the one nothing else exposes |
| `.displayPrepared` | the display-criteria handshake settled, or the path had none |
| `.routed` | native, software, audio or remote-HLS bypass is chosen |
| `.sessionConstructed` | the backend host is built and holds its item |
| `.ready` | the session reports itself ready |
| `.presenting` | the first frame is on screen. The end of the ladder, deliberately not `.playing` |

`.dispatched` is the origin of the axis rather than progress along it, so a fresh sequence publishes `completed == 0` and `total` is eight. A path that legitimately skips work records the checkpoint it does reach and the ones behind it are credited by that alone, so nothing ever waits for a checkpoint its path will never emit. `generation` counts the startups a user waited through rather than teardowns, so an engine-initiated reroute continues the bar instead of resetting it. Sampling the furthest checkpoint at the moment a host gives up turns a failure counter into a map of where loads die.

## Audio tracks

| Symbol | Notes |
| --- | --- |
| `$audioTracks` | `[TrackInfo]`. Republished when `LoadOptions.confirmAtmos` confirms a track. |
| `$activeAudioTrackIndex` | The selected track's id. |
| `selectAudioTrack(index:)` | Session-preserving reload, roughly 0.5 to 1 s of black. `index` is `TrackInfo.id`. A no-op when out of range, already active, or on a forward-only custom source (live ingest included), which cannot rebuild its pipeline: there a track change is a fresh `load` naming the stream. Every refusal is logged, so a picker that does nothing is explainable. |
| `installAudioTap()`, `removeAudioTap()`, `audioTapHasDeliverySource`, `AetherEngine.audioTapFormat` | Opt-in decoded PCM, mono Float32 48 kHz with source-PTS stamps, off the render path. See the contract above. |

## Subtitles

| Symbol | Notes |
| --- | --- |
| `$subtitleTracks` | `[TrackInfo]`: embedded text, embedded bitmap, external files and a live channel's HLS renditions in one list. |
| `selectSubtitleTrack(index:)`, `clearSubtitle()` | Drives the host-overlay path, or AVPlayer's media selection on `.remoteBypass`. `clearSubtitle()` keeps `nativeSubtitleTracks` listed; only `load` / `stop` reset that. |
| `$subtitleCues` | `[SubtitleCue]`: `.text`, `.richText([SubtitleTextRun])`, or `.image(SubtitleImage)`, with an optional `SubtitleTextPlacement`. Cues carry raw source PTS. |
| `$isSubtitleActive`, `$isLoadingSubtitles` | State for a subtitle toggle: active is the selection, loading is a sidecar or side-demuxer pass in flight. |
| `$activeSubtitleTrackIndex` | The selected id, including one resolved by `preferredSubtitleLanguages`. |
| `$sidecarASSHeader` | The ASS header for the active sidecar, for hosts rendering authored styling. |
| `selectSecondarySubtitleTrack(index:)`, `selectSecondarySidecarSubtitle(url:httpHeaders:)`, `clearSecondarySubtitle()`, `$secondarySubtitleCues`, `$isSecondarySubtitleActive`, `$isLoadingSecondarySubtitles` | The independent second track (bilingual / language learning). |
| `addExternalSubtitleTrack(_:)`, `removeExternalSubtitleTrack(id:)` | Register or unregister an `ExternalSubtitleTrack` at runtime. Returns the `TrackInfo` it was listed as. Tracks added after load are overlay-only; declare them in `LoadOptions.externalSubtitles` to have them join the native renditions. |
| `selectSidecarSubtitle(url:httpHeaders:)` | One-shot sidecar decode without listing a track. Prefer `addExternalSubtitleTrack` + `selectSubtitleTrack`, which keeps the track listed and `activeSubtitleTrackIndex` populated. nil headers forward `LoadOptions.httpHeaders`. |
| `$nativeSubtitleTracks`, `setNativeSubtitleSelected(track:)` | The WebVTT renditions declared by `prepareNativeSubtitles`, for PiP / AirPlay / external display. nil deselects. |
| `$nativeSubtitleDefaultOrdinal` | The rendition marked `DEFAULT=YES`, resolved from `nativeSubtitlePreferredLanguages`. A programmatic legible selection only renders if it is the default, so select **this** ordinal. |
| `$nativeSubtitleRenditionAvailable` | At least one cue exists for the native track. Gate the AVMediaSelection picker on it. |
| `$nativeSubtitleRenditionsServed` | Whether the served playlist is the master. A reload signal and a diagnostic, nothing more: whether a legible rendition reaches a wired external display is AVKit's business and is not observable from here. |
| `setNativeSubtitleRendering(_:)` | Hand subtitle drawing to AVKit while the video leaves the host's view hierarchy (PiP, AirPlay, wired external display) and take it back on return. No-op when the active subtitle has no native text equivalent (bitmap, or a track added after load). |
| `teletextPage`, `setTeletextPage(_:)` | The DVB teletext caption page, at load and while the channel plays. |

## Live and DVR

| Symbol | Notes |
| --- | --- |
| `$isLive` | Mirrors `LoadOptions.isLive` for the session. |
| `seekToLiveEdge()` | `async`. |
| `liveSourceReset` | The retune contract above. |
| `liveScrubThumbnail(atSessionSeconds:maxWidth:)` | Cache-backed still on the live session axis. |
| `$playlistShiftSeconds` | Seconds the producer subtracted from source PTS. Published values already fold it back; exposed for hosts pairing their own samples against AVPlayer's raw clock. |
| `HLSLiveIngestReader(playlistURL:)`, `HLSLiveIngestReader(playlistURL:httpHeaders:)` | The ready-made `IOReader` for ingesting an upstream HLS playlist directly, with AES-128 clear-key and SSAI handling. The headers ride the playlist, every segment and every AES key, which is what a tokenized IPTV origin enforces per request. Unsupported shapes surface a typed `HLSIngestError`. |

### Where a live start's seconds go

On the loopback live path (a raw stream, or an HLS source the engine ingests itself) the join cost is
not probe or decode work, it is one withheld response. The engine serves AVPlayer a playlist of its own,
and AVPlayer starts a live session at the edge minus a holdback of `3 x TARGETDURATION`, the RFC 8216bis
floor that the served playlist advertises. So the first `/media.m3u8` is held until the window carries
that much content behind the edge: serving earlier puts AVPlayer's opening seek inside its own
stall-danger zone, where it restarts in a loop instead of playing (#189). An origin that hands over a
backlog satisfies it at I/O speed, and a strict-realtime origin pays it in wall clock. The native bypass
has no such gate, which is why a host measuring both sees it only on the paths that ingest.

Two things report it, and both are worth reading before a slow live start is treated as a decode
problem. `startupProgress` stalls at `sessionConstructed` for the whole wait, so the checkpoint at the
slow moment tells this apart from the demux probe (`streamsProbed`) and the display handshake
(`routed`). And the first serve logs the interval it held, the window it served, and the holdback it was
measured against, whether it waited or was satisfied immediately.

`LoadOptions.liveJoinProfile` is the lever. `.fastZap` collapses `TARGETDURATION` to the source keyframe
cadence and the holdback follows it down, so the win belongs to the source GOP rather than to the flag:
`TARGETDURATION` can never fall below `ceil(max EXTINF)`, and a long-GOP source therefore keeps most of
its runway under either profile.

### The tail after the first serve, and which signal survives it

A serve is not motion. Past it AVPlayer can present the first frame, publish
`waitingToPlayAtSpecifiedRate` with `AVPlayerWaitingToMinimizeStallsReason`, and hold that frame
perfectly still while it decides whether the cushion it has will sustain playback. A host measured 1.5 to
2.8 s of bit-static picture there on 9 of 11 consecutive tunes on an Apple TV 4K, confirmed against an
HDMI capture, with the engine's clock advancing throughout (AE#440). Nothing on the item shortens it:
`preferredForwardBufferDuration` measured inert, because the wait is a rate evaluation and not a buffer
target. It does not reproduce on a macOS loopback harness in any window geometry, so treat it as a policy
of the player on the device rather than as something the served playlist can be shaped out of.

Two consequences for a host.

**Key chrome on `$playbackPhase`, not on `state` or `$hasFirstFrameReadyForDisplay`.** Both of those fire
before the rate rolls, and honestly so: one is intent and the other is a picture. `playbackPhase` is
`.loading` for the whole hold and turns `.playing` on the roll.

**`liveJoinStartsImmediately` cuts the hold short**, once per load, on a live session, over a buffer
AVPlayer reports as non-empty and that carries at least 1.5 s ahead of the playhead. It is the other half
of the trade `.fastZap` already prices: playback begins on a thinner cushion, so a source that hiccups
just after the join rebuffers where it would otherwise have started later and played through. Every later
hold in the session keeps AVPlayer's own policy, so a mid-stream rebuffer is untouched.

**It is on by default since 6.55.0**, on a device A/B rather than an argument. Two runs of ten channel
changes on the reported stack, control then lever:

| | control | lever |
|---|---|---|
| press to moving picture, warm | 6.4 / 6.5 / 7.2 s | 4.3 / 4.8 / 5.1 / 5.6 s |
| press to first PICTURE | 3.4-3.9 s | 3.4-3.9 s |
| stalls / dropped frames | 0 / 0 | 0 / 0 |
| cold joins | ~6.5 s | ~6.5 s |

First picture is unchanged, so what the lever removes is exactly the frozen tail and nothing else, and
the cold case is untouched because the guards keep it out of a starved join. Set it `false` to keep
AVPlayer's own policy for the join.

**Why a depth and not just the empty flag.** `isPlaybackBufferEmpty` is the precondition `AVPlayer.h`
documents, not a measure of safety: one served fragment reads `false` exactly as a four-second cushion
does. Sampling the buffer across every hold in the control run above read non-empty with **3.7 to 4.9 s**
ahead of the playhead for the hold's whole duration, which says the hold on that stack is always AVPlayer
waiting on its own rate estimate and never starvation at the edge. That is why cutting it short cost
nothing there, and it is also why the guard reads the depth: behind the same `false`, a genuinely starved
join holds a fraction of a second, and starting there would trade a still picture for an immediate stall.
The depth is the contiguous span ahead of the playhead, so an island past a gap does not count. When the
floor is not met the engine says so once per load (`leaving the stall-avoidance wait alone (buffer ahead
...s, ...)`), which is what separates the two mechanisms in a report after the fact.

### The rewind depth a live session really has

`seekableLiveRange` used to be `max(0, edgeTime - dvrWindowSeconds) ... edgeTime`, pure arithmetic that
never asked the cache. Two regimes where that over-promises, both measured on the loopback harness:

- **The session's own start.** A session that joins a source already 181 s into its timeline advertised a
  floor of 0.00 for its whole run; a seek to 0.20 landed at 181.66, the first position ever written. The
  over-promise is exactly the join offset, so it is small on a source whose timeline starts with the
  session and large on one that does not.
- **Retention shallower than the window.** With `dvrWindowSeconds: 30` on 1 s segments the cache kept
  24 s, and the advertised bound claimed 30.

The bound is now the intersection of the two, and `seek(to:)` clamps to it, so a target the range accepts
is a target the seek reaches. The floor is a backward-contiguous walk from the newest resident segment
rather than the cache's lowest index: a minimum index is not proof of coverage, and a rewind advertised
below an interior hole cannot play forward.

Resuming a session that has fallen behind, `play()` recovers a playhead that no longer exists: it snaps a
live-only source more than 45 s back to the edge, and lands a DVR session whose window has slid past the
playhead just above the retained floor. Both are recoveries, not opinions about where a viewer should be,
and both are silent. A host with live-pause semantics of its own (a long pause that re-tunes, say) sets
`clampsLiveResumeToWindow: false`, after which `play()` moves nothing and `seekToLiveEdge()` performs the
same recovery on request. The engine keeps reporting; the host decides.

For "where did this seek actually land", the honest signal is `SeekEvent.landed(renderedTime:)` on
`$seekEvents`. `await seek(to:)` returns no position, so a harness that records its own requested target
reports an intention rather than an outcome.

## Picture, layers and PiP

| Symbol | Notes |
| --- | --- |
| `videoGravity` | Fill mode of whichever layer is mounted (`AVPlayerLayer` or the software display layer). Settable; this is the aspect-fit / aspect-fill control. |
| `nativePlayerLayer` | The engine's own `AVPlayerLayer`, for a host building `AVPictureInPictureController` around a layer rather than around `currentAVPlayer`. |
| `$softwarePiPSource` | `SoftwarePiPSource` for sample-buffer PiP on the software path: the display layer plus transport answers on the enqueued frames' axis. iOS only in practice; tvOS AVKit does not evaluate sample-buffer content sources (FB9751461). |
| `$softwareDisplaySize` | The rectangle the software path's picture presents at: coded size under the decoder's pixel aspect. Mirrored, not latched, so a mid-stream resolution change re-shapes it. nil on every other path. |
| `sourceVideoWidth`, `sourceVideoHeight`, `sourceVideoPixelAspectRatio` | The source's CODED size and the multiplier that turns it into the presented one (`width * ratio`), read once from the probe. The ratio is 1 on square pixels and on a declared ratio the engine refuses (#290), never a guess; on the paths that draw, prefer what is on screen (`softwareDisplaySize`, `AVPlayerLayer.videoRect`) over recomputing it here. |
| `pictureInPictureActive` | Host-set. Keeps the pipeline and the loopback server alive across a background transition, and keeps the software path decoding video for the window. |
| `backgroundPlaybackEnabled`, `backgroundTeardownGraceSeconds` | Background audio policy; the grace window (15 s default) is what lets a paused session survive a quick app switch. |
| `presentationAxisMap` | `PresentationAxisMap`: `sourceSeconds(forItemSeconds:)`, `itemSeconds(forSourceSeconds:)`, `shiftSeconds(atItemSeconds:)`, `seams` (each a `PresentationAxisMap.Seam` of `itemSeconds` and `shiftSeconds`), `isEmpty`. Readable off the main actor. Cue times and `sourceTime` live on the source axis; `AVPlayerItem.currentTime()` lives on the item axis, and they differ by the producer shift. Returns nil rather than a guess where no axis is established. |
| `setNativeVideoFrameTimeObserver(_:)` | Takes a `NativeVideoFrameTimeObserver`, called per muxed frame on both axes (`NativeVideoFrameTime`: `source`, `item`, `segmentIndex`, `isKeyframe`, `epoch`). Called on the producer pump thread in **decode** order, so `source` is not monotonic under B-frames. `epoch` rises process-wide. |
| `setSoftwareVideoFrameTimeObserver(_:)`, `softwarePresentationTimebase` | The software-path equivalent, a `SoftwareVideoFrameTimeObserver` over `SoftwareVideoFrameTime` (`presentation`, `generation`), in ascending presentation order, on the same axis as the cues. `generation` moves on every renderer flush. |
| `FrameExtractor` | Off-playback stills: `thumbnail(at:maxWidth:)`, `snapshot(at:maxSize:)`, `prewarm()`, `shutdown()`, over a URL or an `IOReader`. Opens its own demuxer, so it needs a source that tolerates a second connection. |

## Now Playing and the audio session

| Symbol | Notes |
| --- | --- |
| `ownsVideoNowPlayingSession` | Opt in to owning system Now-Playing on the native **video** path. Off by default and that default is load-bearing: an `AVPlayerViewController` host already gets this from AVKit, and opting in costs it AVKit's card, its `externalMetadata` and its transport commands. Read at host creation, so set it before `load()`. |
| `videoNowPlayingSession`, `setVideoNowPlayingInfo(_:)` | The session and its staged identity dictionary. Elapsed / rate / duration are merged from the player; do not stage them. |
| `audioNowPlayingSession`, `setAudioNowPlayingInfo(_:)` | The same pair for the audio-only path, which owns its session unconditionally (there is no AVKit fork there). Pass an empty dictionary to clear. |
| `setExternalMetadata(_:)` | AVKit's on-screen info pane on the video path. Safe before `load()`; replayed at host creation. |
| `deactivatesAudioSessionOnStop` | Off by default. The engine declares the audio-session category at init and never activates it on the native path, because AVKit activates per playback and that is what lets tvOS negotiate the HDMI route (#24), so it never deactivates it either. Set true only when the app owns the session outright; the engine then releases it on a genuine final teardown, meaning `stop()` and never a reload, handoff or live retune. |

## Stills and thumbnails

| Symbol | Notes |
| --- | --- |
| `scrubThumbnail(atSeconds:maxWidth:)` | Cache-backed still for the active native session, live or VOD. Decodes bytes already produced, so it opens no second connection and works on single-connection sources (debrid / torrent links) where a second demuxer is refused. |
| `vodScrubThumbnail(atSeconds:maxWidth:)`, `liveScrubThumbnail(atSessionSeconds:maxWidth:)` | The two arms, for callers that know which axis they hold. |
| `supportsCacheBackedStills` | True while a native session exists. Gate the scrub-preview affordance on it: it reports capability, not per-frame availability, so a transient nil from `scrubThumbnail` while a segment is still being produced is expected and means "time only, no image". |

## Certificate trust

A media server behind a self-signed or private-CA certificate is common in self-hosted setups, and
URLSession refuses it where the in-demuxer network stacks the engine replaces never did. A host whose
own API layer bypasses trust therefore lands in a split state: browsing works and every engine fetch
fails its handshake before a byte is read.

| Symbol | Notes |
| --- | --- |
| `EngineTLS` | Trust policy for the engine's outbound HTTP connections. Off by default, in the sense that no evaluator is set and every challenge keeps the system's default handling. |
| `EngineTLS.serverTrustEvaluator` | `(@Sendable (URLProtectionSpace) -> Bool)?`, asked per challenge about the origin the challenge came from. nil, the default, keeps default handling everywhere. Read per challenge, so replacing it applies from the next connection without rebuilding sessions. Called off the main actor from whichever queue raised the challenge, so it has to be thread-safe. |

```swift
EngineTLS.serverTrustEvaluator = { $0.host == "media.lan" }
```

Answering per origin is the point of the closure rather than a flag: a host commonly holds a LAN
address behind a private certificate and a WAN address with a real one, and accepting the first must
not quietly relax the second. A host that pins an SPKI hash reads the protection space and decides.
Returning true for everything is the blunt version and is one line.

This governs the sessions the engine owns, and the one route where AVPlayer does its own networking
is covered too. On native remote HLS the origin URL would go to `AVURLAsset`, which asks no delegate
about the certificate and which an ATS exception does not reach, so the engine stands a loopback
relay in front of the origin and makes the request itself. That happens only for an origin the
system actually refuses (one handshake decides, since an origin the system trusts is one AVPlayer
reaches unaided), and media is relayed as it arrives rather than read whole, so the player's first
byte and its throughput estimate are the origin's rather than the loopback's. Nothing about this is
configurable: setting an evaluator is the whole opt-in.

A certificate the host does not accept still reaches the host as
`PlaybackErrorKind.sourceCertificateRejected` rather than as unreadable media, on the relayed route
as well.

## Diagnostics

| Symbol | Notes |
| --- | --- |
| `diagnostics.liveTelemetry` | 1 Hz `LiveTelemetry?` snapshot while playing or paused, nil while idle. On a separate `ObservableObject` so its ticks cannot re-render a host observing the engine. |
| `diagnostics.h264RecoveryPointKeyCount` | Positive non-IDR immediate/exact recovery keys in the bounded H.264 VOD routing sample. `nil` when no sample was taken; cleared on stop. Three positive samples select software compatibility; this count is not a decode-performance measurement. |
| `EngineLog.handler` | Mirror every info-level line into a host capture path. Fires from whatever thread emitted it, so it must be thread-safe and non-blocking. |
| `EngineLog.subsystem`, `EngineLog.Category` | `de.superuser404.AetherEngine`, one category per subsystem: `engine`, `ffmpeg`, `session`, `muxer`, `demux`, `hls.server`, `audio.bridge`, `sw.playback`, `scrub`. |
| `EngineLog.Level` | `.info` reaches os_log and the host handler; `.verbose` is per-segment trace and reaches os_log's debug level **only**, never the handler, which is what keeps a mirrored stream readable. Read the verbose ones with `log stream --level debug`. |
| `EngineLog.emit(_:category:level:)` | Emit a host line into the same stream, for a host that wants its own events interleaved with the engine's. |
| `segmentCacheDiskBytes`, `softwareHostFramesEnqueued` | Point reads for a stats overlay. |
| `activeProducerShiftSeconds`, `frameAhead`, `clockLeadSeconds` | Divergence diagnostics for tracing a clock that disagrees with the picture. Not for production playback logic. |

## LoadOptions

All flags default to safe values; the table is the full set. Depth for the media-shaped ones is in [formats.md](formats.md).

| Option | Default | What it does |
| --- | --- | --- |
| `httpHeaders` | empty | Extra headers on every probe, range and segment fetch. On `nativeRemoteHLS` they ride into the `AVURLAsset`, so header-enforcing IPTV origins work. Forwarded to sidecar subtitle fetches unless overridden. |
| `isLive` | false | Treat the source as live. Set it explicitly; duration-based auto-detection is too noisy. |
| `dvrWindowSeconds` | nil | Timeshift window. nil means live-only and `seek` is a no-op. |
| `liveJoinProfile` | `.standard` | A `LiveJoinProfile`. `.fastZap` collapses TARGETDURATION to the source GOP so an IPTV join costs seconds instead of a full holdback. |
| `clampsLiveResumeToWindow` | true | Whether `play()` may move a behind-live playhead by itself (edge snap on a live-only source more than 45 s behind, or a landing above the retained floor when a DVR window has slid past it). `false` hands the whole decision to the host, which then also owns the eviction case. |
| `liveJoinStartsImmediately` | true | Cuts AVPlayer's stall-avoidance wait short once at the live join, over a buffer that is non-empty and at least 1.5 s deep. The join tail no host can otherwise reach; default since 6.55.0 on a device A/B, see the live-join section. |
| `liveBlockingReload` | nil (auto) | LL-HLS blocking-reload override for loopback live sessions. Auto derives eligibility from observed upstream cadence, which is what keeps a bursty relay off a `-15410` loop. |
| `nativeRemoteHLS` | false | Hand a remote `master.m3u8` straight to AVPlayer: no demuxer probe, no loopback. Pair with `isLive: true`. |
| `nativeRemoteHLSIngestFallback` | true | The #168 / #293 carriage recovery and the #363 401/403 bypass refusal recovery. Setting it false turns both off. |
| `audioOnly` | false | Lean audio pipeline, no video machinery. Also set automatically when the probe finds no video stream. |
| `audioBridgeMode` | `.surroundCompat` | Bridge encoder for codecs that cannot stream-copy into fMP4. `.surroundCompat` uses EAC3 for a source with more than two channels and FLAC for one with two or fewer (no surround to carry). `.lossless` uses FLAC up to 7.1 throughout and needs a sink that accepts multichannel LPCM. |
| `confirmAtmos` | false | Background per-track JOC confirmation, republishing `audioTracks` as tracks confirm. Never on the start path; skipped for live and forward-only readers. |
| `preferredAudioLanguages` | empty | First-frame audio pick from the engine's single probe. An explicit `audioSourceStreamIndex` still wins. |
| `preferredSubtitleLanguages` | empty | Post-load subtitle activation on the host-overlay path. Pure convenience: no reload and no pre-probe, unlike the audio equivalent. |
| `externalSubtitles` | empty | Sidecar files registered at load, so they rank in the language preference and can join the native renditions. |
| `prepareNativeSubtitles` | false | Declare WebVTT renditions so subtitles survive PiP / AirPlay / external display. |
| `eagerNativeSubtitleReaders` | false | Populate those renditions at load instead of on first selection, for playlists AVKit auto-selects. Only meaningful with `prepareNativeSubtitles`. |
| `nativeSubtitlePreferredLanguages` | empty | Which rendition is marked `DEFAULT=YES`. Read back as `nativeSubtitleDefaultOrdinal`. Does not activate the overlay path, so it cannot double up with the native render. |
| `preserveASSMarkup` | false | Emit raw ASS event lines instead of extracted text; pair with `TrackInfo.assHeader`. |
| `teletextPage` | nil | Fix the DVB teletext caption page instead of letting libzvbi auto-detect. |
| `audioDelaySeconds` | 0 | Start the session with a lip-sync offset already in force; positive presents audio later. Same value `setAudioDelay(_:)` reads and writes, and a `reloadAtCurrentPosition(applying:)` can correct it. |
| `suppressDisplayCriteria` | false | Skip the display-criteria handshake entirely. For previews and headless runs. |
| `matchContentEnabled` | true | Mirror of `AVDisplayManager.isDisplayCriteriaMatchingEnabled`. False routes HDR through the auto-tonemap path. |
| `panelIsInHDRMode` | false | **Host assertion** that the panel is presenting HDR right now, and the gate on whether the HDR10-to-DV upgrade is accepted upfront. It is an OR term over the engine's own readout on every platform, not a replacement for it and no longer confined to `suppressDisplayCriteria` hosts (AE#459). The readout it backs up is `currentEDRHeadroom > 1`, which answers only around a dynamic-range transition: an Apple TV whose output format is locked to HDR never makes one and reads as an SDR panel forever, and on tvOS 27 the property has stopped answering at all on at least one box. A wrong assertion costs one in-place media-playlist fallback (`-11848`), not the item. |
| `panelPresentsDolbyVision` | false | **Host assertion** that this display presents Dolby Vision, for the platforms where the engine cannot observe it (AE#493). `AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`, so a Mac has no per-mode table at all, and `eligibleForHDRPlayback` answers HDR10 and HLG but not this: it proves EDR, not that AVFoundation will accept a DV variant here. Setting it serves the DV route (`dvh1` sample entry, `SUPPLEMENTAL-CODECS`, master playlist) and publishes `videoFormat = .dolbyVision`; HDR support rides along because DV is an HDR format, while HDR10 and HLG capability are not implied. An assertion only ever adds, so `false` cannot hide a capability the system reports. A wrong assertion costs one in-place media-playlist fallback (`-11868` / `-11848`) at the same position, where AVPlayer tone-maps the base layer, and it is correctable mid-session through `reloadAtCurrentPosition(applying:)`. |
| `omitCriteriaColorExtensions` | false | Diagnostic lever: leave colour out of `AVDisplayCriteria` so AVPlayer re-reads it from the bitstream. |
| `keepDvh1TagWithoutDV` | false | Diagnostic lever: force dvh1 tags and a master playlist regardless of display capability. |
| `forceDolbyVisionOnNonDVDisplay` | false | **Experimental (AE#455).** On a display with no Dolby Vision of its own, serve an HEVC Profile 8.1 source the way a Profile 5 source is served (`dvh1` sample entry, `dvcC` rewritten to profile 5 / compatibility 0, `CODECS="dvh1.05.LL"`), so AVPlayer composes the RPU itself instead of handing the panel the static-metadata HDR10 base layer. The bitstream is untouched; only the container's claim about it changes. Ignored on a display that does Dolby Vision, and Profile 8.1 only. See [formats.md](formats.md#dolby-vision-signaling) for what it buys and what it risks. |
| `preferredDecodePath` | `.automatic` | A `DecodePath`. `.software` serves this source through `SoftwarePlaybackHost` whatever the routing concluded, scoped to this session and costing the source nothing (seeks, the audio switch and the title switch all keep working). The escape for the formats `VTCapabilityProbe` deliberately cannot classify, and for live, which never reaches that gate at all. One-way: there is no `.native`. See [Overriding the decode path](#overriding-the-decode-path). |
| `deinterlaceMode` | `.auto` | A `DeinterlaceMode` for the software path: the Metal / VideoToolbox graph with a CPU bwdif fallback, or `.software` to force the CPU path. |
| `deinterlaceFieldRate` | `.field` | A `DeinterlaceFieldRate`: the hardware deinterlacer emits one frame per field (25i to 50p) or per frame. The software fallback is always frame rate, because doubling a CPU bwdif is the wrong trade and a fallback should not change cost class. |
| `probesize`, `maxAnalyzeDuration` | nil | Caller-bounded open-time probe budget (defaults 50 MB / 60 s). They fail **open**: an over-tight budget loads with late-resolving tracks silently missing rather than throwing, so validate track presence if you tighten them. Do not pass `0` for `maxAnalyzeDuration`; FFmpeg maps it to a shorter heuristic. |
| `forwardBufferSegments` | nil (10, about 40 s) | How far the producer may race ahead and how much the cache keeps resident. Clamped to 4...2700; past the historical 150 the real bound is the session's disk budget, so a "buffer without limit" option can pass `Int.max`. Ignored on `nativeRemoteHLS`. What it actually retains is readable as `$residentRanges` (see Time). |
| `sequentialOrigin` | false | Declare an origin that fabricates range answers: one long-lived unranged GET, no ranged probes, non-seekable pb. **Seeking is unavailable**; re-request the archive at a shifted start instead. |
| `declaredDurationSeconds` | nil | Trusted duration, overriding the container's. Required alongside `sequentialOrigin` on VOD, where the tail read is gone. |
| `maxConcurrentSourceRequests` | nil | Most requests the reader may have open against this origin at once, across every path it fetches on (pump ranges, detour blocks, size probes, tail prefetch, subtitle side reader). nil counts without capping and lowers the ceiling on its own after a 429/503/509. Set it when the provider states a limit; `1` also switches off the speculative parallel paths, which exist only to overlap with the pump. Counts **requests**, not TCP connections, because over HTTP/2 a session multiplexes every request onto one connection while the origin still counts each one (AE#377). It is also the only ceiling: several engines playing from one origin are bounded by this value and by what the origin refuses, not by a transport pool underneath it (AE#450). |
| `autoplay` | true | False mounts paused: the load skips the terminal `play()` and settles at `.paused` for a host that resumes later. It describes THIS MOUNT and nothing after it: the rebuilds a session makes on its own (`reloadAtCurrentPosition`, an option correction, the AirPlay LAN swap, an audio-delay nudge) come back in the transport state the session is in, not in this one. Correcting it through `reloadAtCurrentPosition(applying:)` therefore does nothing; call `play()` or `pause()` instead. |

## Value types

| Type | Carries |
| --- | --- |
| `SourceProbe` | `url`, `durationSeconds`, `videoFormat`, `videoCodecID` / `videoCodecName`, `videoWidth` / `videoHeight`, `videoFrameRate`, `isDolbyVision`, `dvProfile`, `audioTracks`, `subtitleTracks`, `metadata`, `isLive`. |
| `TrackInfo` | `id`, `name`, `codec`, `language`, `channels`, `bitrate`, `isDefault`, `isForced`, `isHearingImpaired`, `isCommentary`, `isAtmos`, `assHeader`, `isExternal`, `isNativelyRenderedSubtitle`. The last one marks a subtitle the playback backend draws itself (a remote-HLS rendition AVFoundation renders), so no cue reaches `subtitleCues` and an overlay control (position, delay, styling) has nothing to act on. |
| `MediaMetadata` | `title`, `artist`, `album`, `artworkData`, `hasDisplayMetadata`. There is no separate album-artist field: a container's album artist is a fallback the parser folds into `artist`. |
| `SubtitleCue` | `id`, `startTime`, `endTime`, `body` (a `SubtitleCue.Body`: `.text`, `.richText`, `.image`), `placement`, plus `text` and `isForced` conveniences. |
| `SubtitleTextRun` | `text`, `color`, `isBold`, `isItalic`, `isUnderlined`, `isStruckThrough`, `fontName`, `fontSize`, `isStyled`. |
| `SubtitleTextPlacement` | `alignment` (numpad), `position` (a [0, 1] anchor). |
| `SubtitleImage` | `cgImage`, `position`, `canvasSize`, `isForced`. |
| `ExternalSubtitleTrack` | `url`, `name`, `language`, `isForced`, `isHearingImpaired`, `isDefault`, `httpHeaders` (nil forwards `LoadOptions.httpHeaders`), `formatHint` for URLs whose path hides the format, and `sourceStreamIndex` for a container holding several subtitle streams. That index addresses the container at `url`, not the played media. |
| `NativeSubtitleTrack` | `ordinal`, `language`, `displayName`, plus `sameLanguageRank(of:in:)` for disambiguating same-language options (eng Full against eng SDH). |
| `TitleInfo` | `id` (0-based, longest first, id 0 is the main feature and the key for `selectTitle`), `name`, `durationSeconds`, `chapterCount`. |
| `ChapterInfo` | `id`, `name`, `startSeconds`, `durationSeconds`. The two publishers differ in axis: `discChapters` are title-relative and seeked through `selectChapter(id:)`, `mediaChapters` carry content timestamps a host passes straight to `seek(to:)` and `selectChapter` no-ops for them. |
| `AudioTapBuffer` | `buffer` (`AVAudioPCMBuffer`), `sourceTime`, `discontinuity`. Non-discontinuity buffers are strictly increasing and non-overlapping, which is what SpeechAnalyzer's input timeline requires. |
| `LiveTelemetry` | The 1 Hz snapshot: bitrates, observed fps, dropped frames, cache and network bytes, A/V gap, RSS. |
| `PlaybackErrorInfo` | `kind`, `underlyingDomain`, `underlyingCode`, `message`. Published as `$errorInfo` beside a `.error` state. |
| `PlaybackErrorKind` | The stable token inside it: `.sourceOpenFailed`, `.sourceRefused` (the origin answered an HTTP status other than a rate limit instead of media; `underlyingCode` is the status), `.customSourceProbeFailed`, `.liveSourceUnavailable`, `.hlsPlaylistOnRawLivePath`, `.dolbyVisionRequiresHardware`, `.demuxedAudioLiveUnsupported`, `.nativeItemFailed`, `.noPlayableTrackWithinBudget`, `.masterPlaylistRejected`, `.vodSourceFailed`, `.sourceRateLimited`, `.softwarePipelineFailed`, `.audioSessionFailed`, `.reloadFailed`, `.liveReloadNeverReady`, `.audioTrackSwitchFailed`, `.audioBridgeProducedNoOutput`, `.sourceCertificateRejected` (the transport was refused over certificate trust; `underlyingCode` is the `NSURLErrorDomain` code, AE#495). `.sourceRateLimited` is the one to branch on separately: the source is being metered, not lost, so the same request is expected to work later and a handoff to a second player will meet the same refusal (AE#377). `.audioBridgeProducedNoOutput` is the other: a source whose audio has to be transcoded into fMP4 (MP3, MP2, DTS, TrueHD, Vorbis, PCM) produced no encoded audio at all, so the mp4 muxer could not build the sample entry it derives from a written packet (AE#396). It used to arrive as `.vodSourceFailed`, which reads as a dead source and ends a fallback ladder; the source is neither gone nor unreadable here, and a second player that decodes the track itself plays the file, so this is a DEMOTE, not a stop. A string-backed struct rather than an enum, so a kind added in a minor release cannot break a host's switch; raw values are API and do not change. |
| `DisplayCapabilities`, `StartupProgress`, `SeekEvent`, `PresentationAxisMap`, `NativeVideoFrameTime`, `SoftwareVideoFrameTime`, `SoftwarePiPSource`, `SystemCaptionRequest`, `AetherEngineError`, `HLSIngestError` | Covered in their sections above. |
| `FontAttachment` | Attached font files for authored ASS rendering: `filename`, `mimeType`, `data`. |

## Public but not host API

Public for the CLI, the test suite, or a diagnostic overlay, and outside the shape this reference documents. They stay source-compatible under semver like everything else, but nothing here should carry playback logic:

- **Test hooks**: `setForceSoftwarePathForTesting`, `setSourceThrottleKbpsForTesting`, `setSoftwareBackgroundAudioOnlyForTesting`, `softwareVideoFramesEnqueuedForTesting`, `setLargeAllocationCensusEnabled`, `forceStalledConsumerReloadForTesting`.
- **`playbackBackend`**: the internal rendering backend, exposed read-only for overlays. Hosts must not branch on it; `videoRoute` is the surface that answers the same question honestly.
- **`HLSVideoEngine`** and its `DiagnosticStats`: the loopback session's own machinery, public because `aetherctl` drives it directly.
- **`DiscInspector` / `DiscInspection`**, `DoviRpuConverter` and its probe, `AudioTapProbe`, `SoftwareDecodeProbeResult`, `A53SEIParser`: repro and inspection surfaces behind `aetherctl` subcommands.
- **`HLSLiveIngestReader`'s internals** (`terminalError`, `upstreamTargetDuration`, `observedLiveCadenceSeconds`, `closedLiveCadenceSeconds`, `upstreamSegmentDurationSeconds`, `companionAudioReader`): fixture and diagnostic reads. The last two are the closed evidence the served TARGETDURATION is sealed from (AE#447); `upstreamTargetDuration` is the upstream's own claim, reported in the seal line and derived from nowhere.
- **`SubtitleChannel`**: the primary / secondary selector on the engine's internal subtitle routing. No public signature takes one; a host picks the channel by calling the primary or the secondary method.
