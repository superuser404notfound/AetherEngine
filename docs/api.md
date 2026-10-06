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
| The Task awaiting it was cancelled while it ran (Sodalite#173) | throws `CancellationError` | `.idle`; the native host is kept for the next load, as a newer `load()` would keep it |
| AVPlayer refused the media during startup and the engine rebuilt the session on the software path (AE#561) | keeps waiting, then returns (or throws what the rebuild threw) | whatever the rebuilt session reaches; `softwarePathEscalations` fires with `duringStartup` |
| A custom `IOReader` whose initial probe failed | throws | `.error` |
| Dolby Vision with no compatible base layer on the software path | throws `AetherEngineError.dolbyVisionUnplayableOnSoftwarePath` | `.error` |
| An HLS playlist handed to the raw live path by a custom reader | throws `AetherEngineError.hlsPlaylistOnRawLivePath` | `.error` |
| The session died after the load returned (source loss, a reload that never became ready, a track switch that failed) | already returned | `.error(message)` only |
| A live session the engine cannot revive | already returned | no `.error`; `liveSourceReset` fires instead |

**`CancellationError` is not a playback failure.** It is what a superseded load throws at its first checkpoint, so every channel zap, every next-episode call and every `stop()` during a load produces one. A load the ENGINE superseded does not throw it: the software-path rebuild below takes over the startup, and the `load()` the host is awaiting follows it, the way a #361 reroute keeps its wait (AE#629). A host that retries, falls back to a second engine, or shows an error on "load threw" reacts to its own navigation unless it lets `CancellationError` through untouched.

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

The clock stops with it, on both backends: `clock.currentTime` and `clock.sourceTime` settle on the last sample and stay there, so a progress bar bound to them holds at the end instead of walking past `duration`. Through 6.28.0 the software path was the exception: its master clock kept its rate past end of media, so a session left standing published a position that grew without bound (20.13 s on a 12.0 s source after 20 s, against 11.97 s from a native session on the same file). A host reading the clock after `.ended` on one of those builds is reading that, not a drifting session (AE#374). The audio-only path (a source without a video track decoded through FFmpeg) had the same defect through 7.27.0 and parks the same way since (AE#694).

### Live: the retune request

```swift
player.liveSourceReset            // PassthroughSubject<Void, Never>; subscribe per session
```

Live's counterpart to a terminal `.error`, and a host that plays live has to subscribe. It fires where the session cannot be revived from inside the engine and only a new `load` can: a source restarted from byte 0 (a transcode respawn), a playlist still frozen after the stall ladder's last reload rung (#65), an in-engine reopen transport whose budget is spent (#199). Production is halted before it fires.

Answering it: negotiate a fresh URL and `load` again, or, where the URL is fixed (an IPTV channel), load the same one again. Guard the answer with one retune in flight, a minimum spacing and a bounded count per session, then surface the exhausted case the way a terminal `.error` would be surfaced, because a ladder that ends on a silent `return` leaves the same dead channel behind a counter.

### Live: a resume that had to move

```swift
player.liveResumeClamped          // PassthroughSubject<LiveResumeClamp, Never>; subscribe per session

public struct LiveResumeClamp {
    public let skippedSeconds: Double      // content the sliding window took while the session was paused
    public let behindLiveSeconds: Double   // where the resume landed; 0 for an edge snap
}
```

A session paused for longer than its own DVR depth has had the position it was parked on evicted by the sliding window, so the resume cannot start where the pause stopped. `clampsLiveResumeToWindow` (default on) moves it to the retained floor, or snaps to the edge on a live-only session; this fires when it does.

It exists so a host can SAY so. Measured on the harness with a 30 s window and a 70 s pause, the playhead sat at 93881.2 while the window slid to 93890.0...93920.0 underneath it and the resume landed at 93895.0 without a word: a viewer who paused a match and came back saw it continue somewhere else, with nothing on screen to say why. Neither number requires arithmetic against a window the host cannot see, so a host can phrase either "you missed fourteen seconds" or "continuing twenty-five seconds behind live".

Hosts that own the decision set `LoadOptions.clampsLiveResumeToWindow = false` instead and get a log line naming the deferral; nothing fires then.

The same-URL answer is the cheap one rather than a no-op: the #168 carriage verdict (a master advertising HEVC while delivering MPEG-TS) is remembered per exact absolute URL for six hours, 32 entries, so the retune routes straight onto the live ingest instead of re-paying the doomed native mount and its watchdog grace. A URL carrying a rotated per-session token misses that memory and re-pays the one-time discovery per retune, which is worth knowing where a first-frame budget is measured against the retune as well.

Where the token rotates, the key the memory cannot have is one the host does have: the channel. `$videoRoute` publishes the reroute as it happens (`.remoteBypass` becomes `.loopback`), so a host can record that verdict against its own channel id and open the channel's next session on the ingest directly, either with `nativeRemoteHLS: false` (an `m3u8` on the raw live path is routed onto the ingest reader from 6.24.0, at the cost of one failed open) or by handing `HLSLiveIngestReader` to `.custom(_:formatHint: "mpegts")` itself, which costs nothing at all. Either skips the native mount and up to 4 s of carriage-watchdog grace per retune, whatever the URL looks like that time.

Left unsubscribed it costs a channel that stops while the engine still reports a session, which from the outside is indistinguishable from a slow one. The guard, written out: [`Examples/LiveHost/LiveChannelHost.swift`](../Examples/LiveHost/LiveChannelHost.swift).

### The system asks for captions

```swift
player.systemCaptionRequest       // PassthroughSubject<SystemCaptionRequest, Never>; subscribe per session
```

iOS 26's Automatic Subtitles (show when muted, on skip back, on a language mismatch) turn captions on with no read API behind them, so the selection is the only observable ask. The engine deselects its own rendition, because one rendered in fullscreen draws a caption box over the host's overlay, and forwards the request with the language it named. A host that wants the behaviour answers by selecting its own matching track.

### The engine moves a refused session onto the software path

```swift
player.softwarePathEscalations   // PassthroughSubject<SoftwarePathEscalationEvent, Never>; subscribe per session
options.escalatesToSoftwarePath  // default true; false declines the rebuild
```

When AVPlayer fails a native item with a verdict on the MEDIA (`CoreMediaErrorDomain`, typically `-19602` on a sample Apple's parser refuses), every native recovery reloads the same bytes, so the engine spends one rebuild per session on `SoftwarePlaybackHost` at the session's playhead instead of making the failure terminal (AE#561). libavcodec skips the frame Apple refused and plays on. It is not taken on the remote-HLS bypass, on a session already asked onto `.software`, or for a URL-loading failure, which both paths would read through the same reader; whether the software path can serve the source at all is the same check a `preferredDecodePath` correction runs.

The event fires the moment the rebuild is taken and carries the failure it absorbed, in the `PlaybackErrorInfo` shape it would have surfaced in (`kind` `.nativeItemFailed`), plus the position and whether a `load()` was still waiting. If the rebuild then fails, the original failure is published as `.error` the usual way; if it succeeds, `videoRoute` moves to `.software`. A startup take does not end the host's `load()` with a `CancellationError`: that call keeps waiting across the rebuild and returns the probe it already assembled.

A host that re-plans a failing title with a ladder of its own (a transcode rung, a second player) sets `escalatesToSoftwarePath = false` and gets the failure as `.error` instead, as before 7.9.0. It is a tuning field, correctable through `reloadAtCurrentPosition(applying:)`.

A live join takes the same rung when the source delivers video for the whole keyframe wait (15 s) and none of it is a picture the native route can open a segment on: no IDR and no recovery point with `recovery_frame_cnt` 0, which is what a feed carrying only gradual intra refresh looks like (AE#627). Reopening would join the same bitstream, so the first join does not spend its reopen cycles on it. The absorbed failure carries the domain `AetherEngine.LiveJoin`. With `escalatesToSoftwarePath = false`, or when the rung is not on offer, the join ends as `liveSourceReset` at that point, as the reopen cycles would have ended it a minute later. A starvation after the session has produced segments keeps its reopens.

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
The log says so rather than leaving it to this paragraph: the field is not named in
`#460: reload applying ...`, it gets its own `#460: autoplay not applied, the session owns it` line
(AE#464 round 3). The two read very differently while a correction is happening, which is when a
host is reading. The one rebuild that DOES apply the flag is the resume after a background teardown
(#357), which has no session transport left to preserve; there it is named as applied, as it is.

**The call answers in three ways, and the third one is returned rather than logged at.** It hands
back a `SessionOptionCorrectionOutcome`: `applied` and `sessionOwned` are the same two lists the log
names, and `rebuilt` says whether the session was torn down at all. A field the session owns costs no
rebuild (AE#464 round 4): there is nothing for one to carry, and the teardown it used to spend was a
visible restart bought for a field the rebuild decides for itself. The session keeps its value, which
is where the rebuild left it too, so `autoplay` remains uncorrectable through this call in exactly
the sense above. Two lists empty with `rebuilt` true is the other quiet answer, a correction the
session was already running on, and that one does rebuild.

```swift
let outcome = try await player.reloadAtCurrentPosition { $0.autoplay = false }
// outcome.applied == [], outcome.sessionOwned == ["autoplay"], outcome.rebuilt == false
```

The result is `@discardableResult`, so a host that only needs the refusals can keep ignoring it.

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
evidence genuinely is not present at load time. A live H.264 / HEVC load never reaches that gate at
all: for those codecs the capability check is VOD-only, so a live session keeps the native path with
no classification step. Live AV1 is judged by profile like VOD (High and Professional go software).

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
| `.noAudioInSource` | the source carries no audio track |
| `.streamCopy` | the source bitstream is muxed into fMP4 unchanged (Atmos, DTS-HD and everything else reach the renderer as authored) |
| `.bridged` | decoded and re-encoded to FLAC or E-AC-3 for the fMP4 pipeline; lossless for the bed channels, object metadata does not survive the PCM intermediate |
| `.decoded` | libavcodec decodes and the engine renders it (the software path, the FFmpeg audio-only host) |
| `.droppedNoPipeline` | the source HAS audio and none of it could be delivered: no decoder for it in this build, the bridge could not be built or could not write its header, the probe left its parameters empty so no stream could be picked, or (live only) the bridge was built and its decoder produced nothing, after which the engine rebuilds the session without the track (AE#641). The session plays video-only and silently |
| `.playerManaged` | AVFoundation owns the audio (the remote-HLS bypass, the native audio-only host). The engine has no pipeline of its own to classify and does not answer on AVFoundation's behalf |

**`.droppedNoPipeline` is the one a fallback ladder acts on**, the same way it demotes on
`PlaybackErrorKind.audioBridgeProducedNoOutput`. The two are the same user outcome from opposite
ends of the cascade: that kind fails loudly when a VOD bridge WAS built and then decoded nothing
(on the FLAC route as well since AE#641, which used to play silently while reporting `.bridged`),
this value reports a bridge that could never be built at all. A live session whose bridge decodes
nothing arrives here as well rather than at the error: its video is playable and a live source has
no position to hand to a second player, so the engine rebuilds it video-only by itself and the
value changes from `.bridged` to `.droppedNoPipeline` (AE#641). Neither ends a ladder: re-serving the
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
| `logTag` | entered into the shared-output book when the load joins it, so a tag set later is missing from those log lines until the next `load()` |

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

### Running several engines at once

Each `AetherEngine` has its own loopback server, caches and lifecycle, so two or more can play side by side (a multiview grid). What they share is the process: the audio session, its channel preference and the panel's display criteria. The engine keeps one book of who is still playing (`SharedOutputCoordinator`, internal) and acts on it:

- The audio session is released only by the last engine to stop, and only if some engine in that round had `deactivatesAudioSessionOnStop`.
- The preferred output channel count is the widest source among the playing engines, so a muted stereo tile cannot downmix a 5.1 one.
- A display-criteria reset waits until the last engine stops, the ones a load runs to clear stale criteria included; an engine that loads again as `.primary` in the meantime cancels its own pending reset, one that loads again as `.secondary` keeps it.
- The disk allowance for seek and timeshift history (a quarter of the free space, at most 2 GiB per session) is taken from what the other running engines have not already claimed, so side-by-side engines cannot claim the same space twice. A claim ends with the session.
- Stop every engine before you let go of it. An engine counts as playing from `load()` until `stop()`, whatever its state, `.error` and `.ended` included, so an engine kept for reuse must be stopped when its tile ends or fails, or the last real stop will not release the session. An engine released without `stop()` is noticed and dropped the next time another engine asks, but until then it counts as playing.

Load one engine as `.primary` and the others with `LoadOptions(sharedOutputRole: .secondary)`, set `logTag` (set before `load()`) on each, and control what is audible with `volume`. Every engine keeps decoding its audio, so switching the audible one is a volume change and not a reload.


## Constructing and binding

```swift
let player = try AetherEngine()
```

| Symbol | What it is |
| --- | --- |
| `AetherEngine()` | `public init() throws`, `@MainActor`, an `ObservableObject`. One engine per playback surface, and several against one origin cost that origin one long-lived request each (see `maxConcurrentSourceRequests`). The audio-session category is declared off-main and never activated here, because AVKit activates per playback and that is what lets tvOS negotiate the HDMI route (#24). |
| `AetherPlayerSurface(engine:)` | SwiftUI view. Drop it in the tree; it mounts and binds an `AetherPlayerView` for you. |
| `AetherPlayerView` | UIKit / AppKit view (`PlatformBaseView` is `UIView` or `NSView`). Hosts the engine's layer. |
| `bind(view:)` | Attach a view. The engine swaps the hosted `CALayer` per session (`AVPlayerLayer` or `AVSampleBufferDisplayLayer`), so a bound host needs no per-route branch. The layer is presented on the most recently bound view that is still alive; an earlier view stays a fallback until it is unbound or released, which is what keeps the picture when a surface is remounted by identity on the same engine (AE#536). |
| `unbind(view:)` | Detach. The engine holds its views weakly, so this is for hosts that reuse one engine across surfaces. Unbinding the view the layer is on moves the layer to the most recently bound view still alive. |

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
| `AetherEngine.probe(url:options:)` / `probe(source:options:)` | `nonisolated static throws -> SourceProbe`. Container/stream metadata read, no detail-pass decoder or session. `options` is read for `httpHeaders` only. Optional trailing `limits` and `cancellation` control the whole operation (below). For a custom reader the caller keeps ownership, `close()` is not called, and the cursor is left unspecified. |
| `AetherEngine.probeDetectingAtmos(url:options:atmosDetection:)` | `probe` plus a bounded decode pass that authoritatively resolves E-AC-3 JOC for an Atmos badge. Strictly more expensive; never on the playback-start path. Decode-side failures degrade to "not confirmed" rather than throwing. Same thing as `probe(url:detecting: .atmos)`. |
| `AetherEngine.probe(url:options:detecting:atmosDetection:hdr10PlusDetection:)` / `probe(source:...)` | `probe` plus the opt-in passes named in `ProbeDetail`, over one demuxer: `.atmos` (the bounded JOC decode above), `.hdr10Plus` (structurally validated ST 2094-40 carriage) and `.hdrVivid` (structurally validated CUVA HDR Vivid carriage in HEVC, scanned in the same packet pass as `.hdr10Plus`). Both passes share the optional trailing `limits` and `cancellation`. Empty set is the header probe with the same controls. The passes only ever SET `isAtmos` / `carriesHDR10PlusMetadata` / `carriesHDRVividMetadata`; ordinary pass failures and per-pass caps leave the detail unconfirmed. A whole-probe stop throws, with no partial result. |
| `ProbeDetail` | `OptionSet`: `.atmos`, `.hdr10Plus`, `.hdrVivid`. |
| `HDR10PlusDetectionOptions` | Bounds for the HDR10+ / HDR Vivid packet scan (one pass for both): `maxPackets` (32), `maxBytes` (16 MiB), `timeBudget` (2 s). The byte cap is the one that binds on UHD remuxes, where a single keyframe runs to several MB. It also bounds the total source read to four times `maxBytes` (at least 4 MiB), below the demuxer, so blocks of dropped streams count. |
| `ProbeLimits` | Optional whole-probe controls: `maxInputBytes` (8 MiB), `maxPackets` (128), `maxPacketBytes` (2 MiB), `timeBudget` (5 s). Nonnegative values required; the time budget must be finite. |
| `ProbeCancellation` | Thread-safe, one-shot token: `init()`, `isCancelled`, `cancel()`. Available on every URL/custom header, detail and `probeDetectingAtmos` overload. Cancellation is a request, not a completion notification. |
| `ProbeError` | `invalidLimits`, `inputLimit`, `packetLimit`, `packetSizeLimit`, `timedOut`, `invalidReaderResult`, `unsupportedURL`, `sourceBusy`; `errorDescription` describes the stop. Explicit caller cancellation throws `CancellationError` instead. |
| `AetherEngine.externalSubtitleTrackIDBase` | `100_000`. Synthetic ids of external subtitle tracks start here. |

Cancelling the Task that awaits `load()` ends the load at once: it throws `CancellationError` instead of running its connect, open, retry and probe budgets to the end (an unreachable live origin used to hold it for about 19 s). A blocked network read, `avformat_open_input` / `find_stream_info`, a size probe, an `HLSLiveIngestReader` retry and a custom reader's blocking `read` are all aborted, typically within tens of milliseconds; the one stretch it cannot cut short is the AE#532 Dolby Vision record audit, a detached read the load waits out before it throws. The load is left the way a newer `load()` leaves it: the generation moves on, a custom reader is closed, `state` becomes `.idle`, and the native host and AVPlayer (#15), an AE#158 handover item and the panel mode are kept for the next load. Until that next `load()` or a `stop()`, the engine reads `.idle` but still holds the native host and its AVPlayer with the item unloaded, Now Playing may stay registered, the audio session stays active, and with an AE#158 handover the previous item can keep playing in PiP; a host that LEAVES on cancel (a dismissed view, say) must call `stop()`. A cancellation only ends the load it belongs to: one that arrives after a newer `load()` or `stop()` took over, or after the load returned, changes nothing. A load that follows an engine rebuild (AE#629) ends that rebuild when cancelled. A `load()` called from a Task that is already cancelled throws before it touches the running session. A real failure that coincides with the cancellation is reported as `CancellationError` too, and `state` ends `.idle`, though a transient `.error` may have been published on the way. The same holds for a `reloadAtCurrentPosition()` of a URL source, which goes through `load()`. A load that returned before the cancellation is not undone; on the `nativeRemoteHLS` bypass `load()` returns at the mount, so a host leaving that startup calls `stop()`. Not cancelling changes nothing.

### Whole-probe limits and cancellation

Existing calls retain their open policy: `limits: nil, cancellation: nil`. Passing `limits: .init()`
starts a monotonic deadline before opening the source, shares the input budget across disc recognition,
container open, `avformat_find_stream_info`, the HDR scan, the Atmos rewind and decode, and disables
speculative HTTP prefetch. Passing only `cancellation` enables interruption without installing numeric
limits. The open keeps the ordinary playback analysis budget, with `probesize` clamped to
`maxInputBytes`, so a controlled probe does not answer from a shallower read than the same call
without limits. Controlled URL probes support files, HTTP and HTTPS; other transports can
use an independent `.custom` reader. Container-declared Dolby Vision remains primary even when HDR10+
is also confirmed.

`maxInputBytes` counts cumulative bytes the underlying reader delivers to the probe, including bytes
read again after a seek. Reads are clipped to the remaining allowance **before** calling the reader.
It is **not a network/wire cap**: HTTP headers, transport buffers, requests used to resolve length, and
reader-internal prefetch can consume more. `maxPackets` counts all packets returned for inspection across
both passes, including foreign streams; FFmpeg-internal packets during open/seek are bounded by input
and time, not that counter. `maxPacketBytes` rejects an oversized packet payload before parsing/decode,
after FFmpeg has allocated it. None of these is a hard native-memory ceiling. The separate per-pass byte
caps also reject a packet that would exceed the remaining allowance, rather than accepting an overshoot.

The deadline and token interrupt HTTP requests and call a custom `IOReader.cancel()` concurrently,
including during open/seek. A blocking custom reader must implement thread-safe cancellation, unblock
promptly, and handle cancellation racing an operation's start; the default no-op cannot do that.
FFmpeg also gets an interrupt callback. This is cooperative interruption, **not a hard real-time return
guarantee**: native computation and a noncooperating reader cannot be forcibly terminated. The call waits
for native work to return before freeing its state, drains interruption callbacks before returning the
reader, and never publishes a positive obtained after a stop. Cancelled HTTP requests finish their task
callbacks before the probe releases their origin slots or returns. A controlled HTTP probe waits for an
origin request slot until its own deadline and then gives up with `sourceBusy`; a slot wait is the one
wait the deadline watchdog cannot interrupt, so the deadline bounds it directly. Normal playback's
redirect, cookie, authentication and response policies are unchanged.

**One detail a controlled probe cannot reach.** The recordless Dolby Vision audit (AE#567) opens the
source a SECOND time by URL to read its first RPU, traffic this probe's budget and cancellation do not
police, so a controlled probe does not run it. An untagged 10-bit HEVC source whose container carries no
Dolby Vision record therefore comes back without one from `probe(url:limits:)` while `probe(url:)`
synthesizes it. Probe that class of source without limits, or treat the absence as unconfirmed.

```swift
let cancellation = ProbeCancellation()
let worker = Task.detached {
    try AetherEngine.probe(
        url: mediaURL, options: .init(httpHeaders: headers),
        detecting: [.hdr10Plus, .atmos],
        limits: .init(), cancellation: cancellation)
}
let result = try await withTaskCancellationHandler {
    try await worker.value // completion means the synchronous native call actually returned
} onCancel: {
    cancellation.cancel()
}
```

Cancelling an awaiting Swift task alone does not cancel synchronous probing; wire the handler as above.
Do not share a custom reader's cursor with playback. The caller still owns and closes it. A successful
probe with `carriesHDR10PlusMetadata == false` or an unconfirmed Atmos track means **not confirmed within
the requested passes/budgets**, never proof of absence. Atmos detection means E-AC-3 JOC, not TrueHD Atmos.
These are source-metadata answers, not evidence of HDMI output or display mode.

### Warming a source before it is loaded

```swift
await AetherEngine.prewarm(url: nextEpisodeURL, httpHeaders: headers)
```

A cold open is not free. On a non-fast-start MP4 it is two to three sequential round trips before the first sample read, and on a slow origin the first byte of the data connection is the whole perceived start time. A host whose UI knows what is coming next can spend those seconds in advance.

| Symbol | Contract |
| --- | --- |
| `AetherEngine.prewarm(url:httpHeaders:byteBudget:)` | `nonisolated static async -> SourcePrewarmReport`. Discardable. Fetches the opening bytes of a source the engine is not playing, so the next `load()` of that exact URL adopts them instead of fetching them. No engine instance, no audio session, no layer: a host warms while its player is still on the current item. Cancelling the task cancels the fetch and stores nothing. |
| `AetherEngine.isPrewarmed(url:)` | `nonisolated static -> Bool`. Whether that URL is warm right now, without consuming it. False again after the load that adopted it. |
| `AetherEngine.discardPrewarmedSources()` | `nonisolated static`. Drops every warmed source, for a host leaving the context they were made for. |
| `AetherEngine.defaultPrewarmByteBudget` | `8 * 1024 * 1024`. A byte budget and not a duration, because a duration needs the bitrate, which is known only after the probe this is trying to get ahead of. |
| `SourcePrewarmReport` | `retainedBytes`, `contentLength`, `declined`, `isWarm`. `declined` is one sentence naming why nothing was retained, and the engine logs it either way. |

What it fetches: one ranged GET from byte zero for the budget, plus a second one for the trailing object only where the head says the session that opens this source will go looking for it. Two layouts do: an MP4 whose `moov` sits behind the media, and a Matroska whose SeekHead names a level-1 object past the warm head (its Cues, usually). The Matroska span runs from that object to the end of the source and is declined above 1 MB, because a trailing object that large is a download rather than an index.

A warm also hands the load **where the bytes live**. A resolver URL that answers 302 with a temporary edge target is resolved once, by the warm, and the session starts at that target instead of resolving the chain again; a lease that has since run out falls back to the source URL through the same ladder a mid-session expiry uses. Credential headers (`Authorization`, `Cookie`, `X-Emby-Token` and the rest of the #126 set) never travel to a cross-origin target, whether it was reached through a redirect or pinned from a warm.

Remote disc images (`.iso` / `.img` / `.udf` over HTTP) adopt a warm too (#647). The disc reader takes the size from the warm instead of probing for it, answers the disc layer's structure reads and the title's opening extents out of the head, and starts its first request at the warm frontier; its forks (the subtitle side reader, the forward prefetcher) share the same bytes without a copy. It does not pin the warm's redirect target, because that reader follows redirects per request. A disc-image URL that turns out not to be a disc hands the warm on to the streaming reader.

Three limits are part of the contract rather than implementation detail:

- **It never queues for the origin.** A warm takes a request slot only if one is free right now, and declines when the origin is metered down to one request at a time or is pacing the engine (`maxConcurrentSourceRequests`, #377). A prewarm that would have to wait for the playing session's uplink has stopped helping.
- **The bytes live in memory and only until they are used.** They do not survive the app, and the first `load()` of that URL takes them rather than copying them. This is a head start, not an offline download, and there is no disk cache behind it.
- **`LoadOptions.nativeRemoteHLS` is out of scope.** On that route AVPlayer issues the requests and the engine sees none of them, so there is nothing to adopt. Warming helps the paths the engine fetches on itself: the loopback native path, the software host, and the side demuxers.

The URL is the key, matched exactly, **and so are the headers**. A signed URL warmed under one signature is not adopted under another, and a warm fetched with different `httpHeaders` than the load carries is not adopted either: an origin that varies on Referer, User-Agent or Authorization answers a different body, and a different size, under one URL, and nothing about the bytes themselves would show it. Pass the load's headers to the warm.

Warms are serialised, one at a time across the process. A second `prewarm` while one is in flight waits its turn rather than being refused, which costs the origin nothing because a queued warm holds no request slot and has issued nothing. What never queues is a request against the origin.

`IOReader` is the custom-source protocol: `read`, `seek`, `close` are required; `cancel()`, `makeIndependentReader()` and `discImageProbeEnabled` have defaults that unlock teardown-unblocking, embedded subtitles plus scrub stills, and ISO/UDF probing respectively. Calls arrive on the engine's demux thread, each inside an autorelease pool the engine opens, so a reader built on `FileHandle` or `NSData` does not strand one autoreleased object per read for the length of a session. Full contract in [formats.md](formats.md).

## Transport

| Symbol | Notes |
| --- | --- |
| `play()` | Rewinds first when parked at the final frame of a VOD; a no-op on `.ended`. |
| `pause()`, `togglePlayPause()` | |
| `seek(to:)` | `async`. Source-axis seconds. Rejected when idle, errored, ended, or live without a DVR window. |
| `seek(toSourceTime:)` | Deprecated alias for `seek(to:)`. The clock is unified onto source PTS, so the two are the same call. |
| `setRate(_:)` | Clamped to `maxSupportedRate`; `0` pauses. The speed holds across pause and resume and across the host rebuilds a session makes on its own (reload at position, audio-track switch, AirPlay LAN swap, background return), and it belongs to the item: loading a different source, or `stop()`, returns to 1.0. Pitch-preserving on both decode routes: `audioTimePitchAlgorithm` is pinned to TimeDomain on the native player item and on the software path's audio renderer, so a speed control never has to be gated on which route a title took. |
| `audioDelaySeconds`, `setAudioDelay(_:)` | Lip-sync correction for the viewer's chain, in seconds; positive presents audio later than video. Clamped to +/-2 s and, like `setRate`, it holds across the rebuilds a session makes on its own and belongs to the session. Applied where the engine still holds the timestamps: the stamped sample PTS on `.software`, the audio track of the fMP4 segments on `.loopback`. AVFoundation exposes no equivalent on either surface a host can reach, so on `.remoteBypass` and on audio-only sessions the value is kept for the next load and the no-op is logged rather than faked. Not free the way `setRate` is: the audio already decoded or already fetched is committed to the previous value and cannot be re-timed in place, so a change re-anchors at the playhead. On `.software` that is a seek to the current position; on `.loopback` it is the session-preserving reload, because seeking to the position AVPlayer already holds is a buffer hit and plays the old-offset segments out anyway. Measured on a 30 fps H.264 fixture: about 0.3 s of held picture on the loopback route, position preserved. A live session without a DVR window has no position to return to and takes the new value at the next seam it makes on its own. Presses arriving while a re-anchor is running are folded into it rather than stacking one re-anchor per press (AE#464 round 3), and a press that lands after the in-flight re-anchor read the value gets exactly one catch-up pass; the value does not ride the call, so the rebuild in flight delivers the newest one. Presses at a human cadence arrive after a re-anchor has finished and are each their own. A re-anchor or a `reloadAtCurrentPosition(applying:)` raised the moment a previous rebuild returned, before the new host has published a position, rebuilds at the position that rebuild was mounted at, not at the head (round 5). A call landing while the session is being rebuilt at all is neither applied nor refused: it is kept in the options the load in flight reads, and says so. |
| `maxSupportedRate` | 2.0 for video, 3.0 audio-only. Query after load; returns 2.0 while idle. Size a speed picker against it. |
| `volume` | 0.0 to 1.0. A write before a session exists is remembered and applied at load. |
| `selectTitle(id:)`, `selectChapter(id:)` | Disc titles and chapters. |

## Time

Time lives on `player.clock`, a separate `ObservableObject`, so ~10 Hz ticks never fire `objectWillChange` on the engine.

| Symbol | Axis |
| --- | --- |
| `clock.$currentTime` | playback clock, the scrubber axis |
| `clock.$sourceTime` | source PTS of the displayed frame; render subtitle overlays against this. On `nativeRemoteHLS` it is item time, corrected by the lead over the picture the engine measures on its injected #316 renditions while one is selected (AE#616); see below the table. |
| `clock.$sourceTimeFollowsPicture` | whether `sourceTime` is known to follow the displayed frame. Always true except on `nativeRemoteHLS`, where it is true only while the lead is measured since the last time jump (AE#616); see below the table. |
| `clock.$progress` | `currentTime / duration` |
| `clock.$bufferedPosition` | source-axis position buffered ahead |
| `clock.$liveEdgeTime`, `clock.$seekableLiveRange`, `clock.$behindLiveSeconds`, `clock.$isAtLiveEdge` | live-window surfaces. `seekableLiveRange` is the intersection of the DVR window (policy) and what the segment cache actually holds and can play forward from (fact), so it is honest to scale a rewind strip on and `seek(to:)` clamps to the same floor (AE#441). The two diverge for the whole first `dvrWindowSeconds` of a session and again whenever retention evicts faster than the window slides. Software live sessions hold a packet ring instead, which evicts by the same byte budget as the native cache (a quarter of the volume's free space, at most 2 GiB, at least 64 MiB), so the range's floor follows the ring once eviction has moved it past the window. |
| `$residentRanges` | where the loopback segment cache holds picture right now, as disjoint ascending spans on the `currentTime` axis. This is the cache's own truth, not AVPlayer's `loadedTimeRanges`: a measured session held 64 segments over four minutes across several islands while AVPlayer exposed roughly twelve seconds around the playhead and forgot a seeked-ahead island as soon as the playhead left it. Empty is the nil-equivalent, and a live session publishes empty always (its rewind depth is `seekableLiveRange`, which answers a different question). Residency is not a promise that a seek inside a span is instant: the player may still re-anchor and decode at the target, and a segment can start mid-GOP (AE#412). Coalesced to at most four updates a second, cleared on `load()` and teardown. |
| `player.currentTime`, `sourceTime`, `sourceTimeFollowsPicture`, `progress`, `bufferedPosition`, `liveEdgeTime`, `seekableLiveRange`, `behindLiveSeconds`, `isAtLiveEdge` | non-published mirrors of the same values for one-shot reads |
| `$duration` | seconds; a `LoadOptions.declaredDurationSeconds` outranks the container's |

**`sourceTime` on `nativeRemoteHLS` (AE#616).** The engine sees no segment on that route, so the clock is
AVPlayer's item time. An origin whose playlist places a segment at its slot while the segment starts at
the keyframe before it (a Jellyfin transcode restarted by `-ss <slot> -noaccurate_seek -copyts`) makes
item time lead the frame on screen, by a different amount after every seek: 1.1 s to 8.3 s measured, and
AVPlayer keeps the anchor of the first segment it loaded after the seek. The WebVTT renditions the
engine injects for `LoadOptions.externalSubtitles` are placed by media timestamp, so each line reaches
AVPlayer's legible output at its cue start plus that lead. The engine watches its own renditions with a
non-suppressing legible output, matches each presented line back to the cue it wrote, and publishes
`sourceTime` as item time less the measured lead (log line `AE#616: item time leads the presented
frame by ...`). It re-measures on every line; between a seek and the next line it keeps the previous
value, and `clock.sourceTimeFollowsPicture` is false from the time jump until that line, so a host can
hold its overlay instead of detecting seeks itself. Without an injected rendition selected nothing is
measured, `sourceTime` is item time and `sourceTimeFollowsPicture` stays false.
`currentTime`, `seek(to:)` and the scrubber stay on item time throughout, so a seek round-trips. A host
drawing its own overlay from `sourceTime` (libass) can keep the rendition selected behind its own
suppressing `AVPlayerItemLegibleOutput` to keep the measurement running.

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
| `softwarePathEscalations`, `SoftwarePathEscalationEvent` | A native session AVPlayer refused, rebuilt on the software path, with the failure it absorbed. See [The engine moves a refused session onto the software path](#the-engine-moves-a-refused-session-onto-the-software-path). |
| `$videoRoute` | `VideoRoute`: which pipeline is actually serving, one of `.none`, `.remoteBypass`, `.loopback`, `.software`, `.audio`. `LoadOptions.nativeRemoteHLS` is only the request; the carriage watchdog, the remembered verdict and the HLS reroutes move a session between routes, mid-session too. Branch on this, above all for who draws subtitles. |
| `$airPlayPictureStaysLocal` | iOS: true while a wireless AirPlay receiver holds the audio route but the session runs on the software host (VP9, AV1 without hardware decode, deinterlaced MPEG-2 / VC-1 / H.264, `preferredDecodePath = .software`). That host draws into an `AVSampleBufferDisplayLayer`, and only its audio renderer follows the route, so the receiver plays sound only. Nothing fails, which is why the engine says so: show the viewer that this title's picture stays on the device. False on the native paths, where the receiver gets the stream, and everywhere off iOS. |
| `$audioDelivery` | `AudioDelivery`: how the audio reaches the renderer, one of `.none`, `.noAudioInSource`, `.streamCopy`, `.bridged`, `.decoded`, `.droppedNoPipeline`, `.playerManaged`. `.droppedNoPipeline` is a source that HAS audio playing video-only because no pipeline could be built for it, or because a live bridge decoded nothing (AE#641): the value a fallback ladder demotes on. See [Reading whether the audio was delivered](#reading-whether-the-audio-was-delivered). |
| `$videoFormat` | The format being presented: `.sdr`, `.hdr10`, `.hdr10Plus`, `.dolbyVision`, `.hlg`. On a platform with no per-mode capability table (macOS), a Dolby Vision session the clamp sent to `.hdr10` is upgraded back to `.dolbyVision` once the item AVFoundation is playing turns out to carry a `dvh1` / `dvhe` sample entry (AE#515). On tvOS the panel term behind it no longer comes from the headroom alone: a session serving an HDR master that AVFoundation has not refused publishes the presented format half a second in, because a display that takes an HDR master is presenting HDR while one that is not refuses in 54 to 61 ms, and `currentEDRHeadroom` has been measured reading 1.00 through exactly that acceptance (AE#459). |
| `$sourceVideoFormat` | The format the **source** carries, before any panel-driven mapping. The pair is what an honest badge needs: HDR content on an SDR panel differs between the two. |
| `$sourceDVProfile`, `$sourceVideoFrameRate`, `$sourceVideoBitrate` | Source detail for an info panel. |
| `$dolbyVisionConversion` | A `DolbyVisionConversion?`: the Dolby Vision profile rewrite applied to the served stream, nil when the session serves the source's own profile or no Dolby Vision. `.profile7ToProfile81` is a Profile 7 source played on a display presenting Dolby Vision, where `$videoFormat` reads `.dolbyVision` and `$sourceDVProfile` keeps 7, so a label can say "P7 -> P8.1". The enhancement layer is dropped by that conversion. Set when the loopback session starts, cleared on stop. |
| `$sourceVideoCodecName` | The source video codec in the libavcodec spelling ("hevc", "h264", "av1"), nil when the source carries no video. The probe-free remote-HLS bypass maps it back from the item's video sample type, so the field answers on every route rather than going quiet on one of them. Not the same question as `$activeVideoDecoder`: a codec has several decoders, and which one runs depends on the hardware. |
| `$sourceContainerFormat` | The container libavformat opened ("matroska,webm", "mpegts"), nil on the remote-HLS bypass, where AVFoundation opens the source and there is no libav context to ask. This is the container that ARRIVED, which on a remux or transcode session is not the one a host's library metadata describes. |
| `$sourceVideoStreamFormat` | A `VideoStreamFormat?` (AE#658): the source video stream's `pixelFormat` ("yuv420p10le"), `bitDepth`, `colorPrimaries`, `transfer`, `matrix`, `range` and `profile` ("Main 10"), in libav's names as the container and the probe's decoder declared them. A field the stream leaves unspecified is nil, never a guessed BT.709. `colorPrimariesLabel`, `transferLabel`, `matrixLabel` and `rangeLabel` give the names a viewer reads ("BT.2020", "PQ (SMPTE ST 2084)", "BT.2020 NCL", "Limited"). nil before load and without video. On the probe-free remote-HLS bypass it is the DELIVERED stream, read back from AVPlayer's item video track once it resolves: colour and range from the format description, `profile`, `bitDepth` and `pixelFormat` from its avcC / hvcC record (nil where the codec has none of those, AV1 and VP9 included). Under a server-side transcode that is the transcode, not the library's file, which is the point of reading it there. |
| `$decodedVideoFormat` | A `DecodedVideoFormat?` (AE#658): what the engine's own decoder actually produced. `frame` is a `VideoStreamFormat` for the decoded picture (libavcodec's output pixel format, or the libav name of the VideoToolbox buffer on the software host's hardware decoder), `pixelBufferFormat` the CoreVideo buffer it was displayed from (`420v`, `x420`; `pixelBufferLabel` reads "P010 (x420)"). Republished when either changes mid-stream. **nil on every native route**: AVPlayer decodes there and its frames never pass through the engine, so a panel shows `$sourceVideoStreamFormat` and names AVPlayer as the decoder instead of inferring a pixel format it never saw. |
| `$activeVideoDecoder`, `$activeAudioDecoder` | The decoder names actually in use, for a stats overlay. This is the honest "what is decoding this" surface; `playbackBackend` is not. Show `$activeAudioDecoder`, classify on `$audioDelivery`: a label cannot separate a source without audio from a source whose audio was dropped. |
| `$metadata` | `MediaMetadata` parsed at load (title / artist / album / cover). |
| `$mediaChapters`, `$discChapters`, `$discTitles`, `$selectedDiscTitle` | Container chapters, and disc titles / chapters for DVD and Blu-ray ISO sources. |
| `$currentAVPlayer`, `$currentAVPlayerItem` | The live AVFoundation objects, re-emitted on every reload. Both nil on `.software`, which renders into its own layer. A host that only ever hands `currentAVPlayer` to an `AVPlayerViewController` gets audio over an empty video plane on that route (#298). |
| `AetherEngine.displayCapabilities` | `static DisplayCapabilities`: `supportsHDR`, `supportsDolbyVision`, `supportsHDR10`, `supportsHLG` for the current display. What a settings screen should read instead of guessing from the device model. On macOS the table comes from `AVPlayer.eligibleForHDRPlayback` (there is no per-mode API there) and leaves Dolby Vision unclaimed, which is what `LoadOptions.panelPresentsDolbyVision` is for. On tvOS and iOS the per-mode table is `AVPlayer.availableHDRModes`, but since 6.82.0 it may only ADD: `supportsHDR10` and `supportsHLG` take eligibility as their floor, because the table under-reports HLG over HDMI against a panel whose EDID advertises it (AE#459). Dolby Vision still comes from the table alone on those platforms, where it is measured correct in both directions. It answers at CALL TIME, so a host that stores it stores a moment: on tvOS a backgrounded process is answered for its own state and every term reads false until the app returns. A session reads it once, at the load, and every route and rebuild of that session answers to that one table (AE#535). |

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
| `$audioTracks` | `[TrackInfo]`. Republished when `LoadOptions.confirmAtmos` confirms a track. On `.remoteBypass` it lists the audio tracks AVPlayer built for the item (normally just the one playing), read from their format descriptions: `codec` in libavcodec's spelling (`eac3`, `ac3`, `aac`), `channels`, `sampleRate`, `profile` (AAC's object type; "Dolby Digital Plus + Dolby Atmos" with `isAtmos` when the E-AC-3 dec3 record announces JOC) and `language` from the track or the selected audible option. The ids are synthetic (from 400000 up) because there is no stream index on that route; compare them only with `activeAudioTrackIndex`. |
| `$activeAudioTrackIndex` | The selected track's id. On `.remoteBypass`, the enabled item track's. |
| `selectAudioTrack(index:)` | Session-preserving reload, roughly 0.5 to 1 s of black. It comes back in the session's transport like `reloadAtCurrentPosition()`: a paused session stays paused. `index` is `TrackInfo.id`. A no-op when out of range, already active, or on a forward-only custom source (live ingest included), which cannot rebuild its pipeline: there a track change is a fresh `load` naming the stream. Every refusal is logged, so a picker that does nothing is explainable. Also a no-op on `.remoteBypass`, where AVPlayer owns the audio selection and the list above is informational; a different language there is a different URL. |
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
| `$isSequentialOrigin` | True while a VOD session is served as a sequential origin, declared (`LoadOptions.sequentialOrigin`) or found by the reader (the origin ignores `Range`, or refused the ranged open twice and served a plain GET, AE#693). The session plays from the start, so a `startPosition` given to `load()` was not honoured, and a seek lands only inside what `$residentRanges` already holds. A host that needs the position reopens the source or tells the user. Set during `load()`, cleared on stop. |
| `seekToLiveEdge()` | `async`. |
| `liveSourceReset` | The retune contract above. |
| `liveResumeClamped`, `LiveResumeClamp` | A resume that found the playhead outside the window and moved it; see above. |
| `liveScrubThumbnail(atSessionSeconds:maxWidth:)` | Still on the live session axis, decoded from what the session already holds. A native session reads its DVR segment cache; a software session reads its DVR packet ring (#544), so a tuner channel the box decodes in software has a scrub preview too. |
| `$playlistShiftSeconds` | Seconds the producer subtracted from source PTS. Published values already fold it back; exposed for hosts pairing their own samples against AVPlayer's raw clock. |
| `HLSLiveIngestReader(playlistURL:)`, `HLSLiveIngestReader(playlistURL:httpHeaders:)` | The ready-made `IOReader` for ingesting an upstream HLS playlist directly, with AES-128 clear-key and SSAI handling. The headers ride the playlist, every segment and every AES key, which is what a tokenized IPTV origin enforces per request. Credential headers (`Authorization`, `Cookie`, `X-Emby-Token` and the like) go only to the playlist's own origin with no https to http downgrade; a URI the playlist points at another host gets the other headers without them, the rule a redirect already follows. Unsupported shapes surface a typed `HLSIngestError`. |

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
its runway under either profile. Where the engine cuts the segments itself, each one is a whole GOP and
the value is sealed from the first few, so it carries headroom for a GOP 1.5 x the longest seen: a
broadcast whose GOPs run 1.0 to 2.4 s sealed TARGETDURATION 1 on its first three and then broke
`EXTINF <= TD` on every longer one (AE#670). The headroom is the smallest value under which that longer
GOP still lists (RFC 8216 rounds EXTINF to the nearest integer) and finishes inside AVPlayer's
`1.5 x TARGETDURATION` patience with 0.5 s to spare, so 1 s GOPs serve TARGETDURATION 2 and a 6 s
holdback, and so does a 59.94 fps stream whose scene-cut keyframes merge GOPs into 80 to 89-frame
segments (up to 1.666 s seal 2).

**An ingested HLS upstream seals over the segment it is delivered in, as far as its join pays for it,
under either profile (AE#684).** The engine re-cuts an upstream segment (at its GOPs under `.fastZap`,
at about 4 s under `.standard`), but the window still changes once per UPSTREAM segment, so what the
seal asks for is the longest segment the upstream has served, whole, where `ceil(segment / 1.5)` used
to leave the client a patience of exactly one delivery. The upstream's advertised target duration is
still not read. What it gets is bounded three ways:

- **By the join, which is not deepened for it on an upstream of uniform segment length.** A seal is a
  holdback of `3 x` itself, and the join there is the three upstream segments it was before (one more
  would be one more download before the first picture on every zap, which AE#678 measured and
  declined). Their last GOP stays open until the next delivery, so three 6 s segments are 18 s joined
  and 16 s cut: the seal is 5, the largest value whose holdback that window holds, not 6. Three 10 s
  segments cut 28 s and seal 9. The one addition is that the join is equalised over the PHASES of an
  upstream whose segment lengths alternate: a tune never loads more than the deepest tune of the same
  channel already did. Alternating 6 s and 4 s segments used to join four (20 s listed, 18 s cut,
  seal 6) with a 4 s one newest and three (16 s listed, 14 s cut, seal 4, as in 7.25.1) with a 6 s
  one newest, so the same channel behaved differently from one tune to the next. The depth is now the
  deepest the coverage rule takes over the tune itself and the tunes one, two, ... segments earlier
  that its own join still reaches, at most one segment above its own: both phases join four and seal
  6. That costs the three-segment phase (about four tunes in ten on that shape) one additional short
  segment at the join, which the other six already load: 3.47 s to 4.23 s to first picture behind an
  8 Mbit/s link, median of five, against 4.27 s in the other phase on either build. Shapes whose
  phases already joined alike keep their join and what it pays: 10 s / 8 s stays at three segments
  and seals 8 (7 before), 6 s / 6 s / 4 s stays at three and seals 4, unchanged, and a shape like
  6 s / 5 s keeps a seal that follows the phase (5 in one, 4 in the other), because equalising is
  about how much a tune loads, not about what it seals. The seal line says what was paid
  (`of which the join pays 5s of 6s (16.000s cut of the 18.000s it listed)`), and "the join has no
  more to give" is a fact the reader states (its join batch is handed over and its consumer is
  waiting), not arithmetic on EXTINF, which a playlist that rounds its durations up would fail.
  With a demuxed audio rendition the fact is the cutter's rather than one reader's: both join
  batches handed over and the cutter waiting on either of them, because an audio rendition whose
  segments end a little before the video's runs dry first and the video reader is then never the
  one being waited on (three runs per arm on three listed segments, audio aligned and audio 0.2 s
  short: first picture 0.18 to 0.21 s against 0.17 to 0.36 s on 7.25.1, TD 5 on 6 s and 9 on 10 s
  under both profiles). A join that is SLOWER than the `.fastZap` grace, a single-connection
  provider or a slow link, takes the bounded start before it is spent and then seals the full
  value (6 or 10, not 5 or 9) over a window shorter than its holdback, which AVPlayer notes with a
  `-16832` warning at the start; measured one request at a time behind a 4 to 5 Mbit/s link that
  start is not worse than 7.25.1's (first picture 5.05 to 6.08 s against 7.05 to 8.26 s, no
  `-12888` where 7.25.1 drew 1 to 3).
- **By a ceiling.** Segments longer than 10 s (`LiveEdgePolicy.upstreamSegmentSealCeilingSeconds`) are
  not asked for whole: a 20 s one seals 14, as it did before, because the live-only window is 60 s.
- **Never under what it was.** Where the old value already covered the segment nothing moves: 2 s
  segments keep 2 and a 6 s holdback, and `.standard` keeps its 6 on anything up to 6 s.

So on a provider of uniform 6 s segments under `.fastZap` the seal goes from 4 to 5 (holdback 12 to
15 s), on a uniform 10 s one under either profile from 7 to 9 (21 to 27 s), and on alternating
6 s / 4 s segments from 4 to 6 (12 to 18 s) in both phases. A provider of 3 s segments with 1 s GOPs is
unchanged at 2: three joined segments cut 8 s, which pays for no more, so the patience of one
delivery this issue is about stays as it is there. On uniform upstreams the join, and with a host that
fetches in parallel the time to the first picture, is what it was: behind an 8 Mbit/s link, three runs
per arm, 3.81 to 4.04 s before and 3.80 to 3.85 s after on 6 s segments, 6.15 to 6.36 s and 6.18 to
6.28 s on 10 s ones. A host that allows fewer parallel requests than the join has segments
(`maxConcurrentSourceRequests` of 3 or less) sees its first picture later than before, because the
gate now waits for the join to be handed over where it used to serve at 12 s of cut content: one
request at a time behind 14 Mbit/s on the mixed shape, three runs per arm, 2.79 to 3.08 s before and
3.27 to 3.28 s after in the four-segment phase, 2.80 to 2.83 s and 3.44 to 3.49 s in the phase that
now also loads the extra segment. The other cost is standing latency: 3 s more behind the upstream's
edge on uniform 6 s segments, 6 s on alternating 6 s / 4 s and on 10 s ones, 3 s on 10 s / 8 s.

Measured on loopback against `Scripts/hls-burst-origin.py` (deliveries 3 to 9.3 s apart on 6 s
segments), 60 s per run, three runs per arm and row, 7.25.1 against this; first picture is 0.17 to
0.51 s in both arms wherever a row does not say otherwise:

| upstream, profile, segments listed | 7.25.1 | now |
|---|---|---|
| 6 s, `.fastZap`, 3 | TD 4, 1 x `-12888` per run, 2 stalls in 3 runs | TD 5, none |
| 6 s, `.fastZap`, 4 | TD 4, 2 x `-12888` per run, 2 stalls in 3 runs | TD 5, 1 to 2 x `-12888`, no stall |
| 6 s, `.fastZap`, 8 | TD 4, 1 to 3 x `-12888`, 3 stalls in 3 runs | TD 5, 0 to 2 x `-12888`, no stall |
| 10 s, `.fastZap`, 3 / 4 / 8 | TD 7, 1 x `-12888` in 7 of 9 runs, window closed and item rebuilt in 4 of 9 | TD 9, none in 9 of 9 |
| 10 s, `.standard`, 3 / 8 | TD 7, item rebuilt in 6 of 6 runs | TD 9, none in 6 of 6 |
| 6 s, `.standard`, 3 / 8 | TD 6, first picture 6.18 to 6.53 s | unchanged: TD 6, 6.28 to 6.46 s |

Two things this does not do, said plainly. On a 6 s provider `-12888` still comes: over one 180 s run
5 of them and a stall before, 3 and no stall after, because 7.5 s of patience still loses to a 9 s gap
and what changed is the holdback under it. (A join one segment deeper seals 6 and drew none in three
such runs; it was measured and not shipped, for the download it costs.) And `.standard` on 6 s segments
still takes about 6.3 s to its first picture, waiting for the next upstream segment, exactly as it did:
its seal there is its own `1.5 x cut target` floor, which three joined segments never covered. A real
outage longer than the holdback's low point stalls under any of these; the capture that started this
had 10 of its 110 delivery gaps above 9 s.

**An HLS source with a window of its own now fills that cushion at the join rather than in wall clock**
(6.77.0). The ingest used to enter a live playlist three segments behind the edge, and three joined
segments finalize only two downstream, because the last one stays open until the next arrives. The
cushion wants three, so the gate then waited one upstream segment duration for content the origin was
already holding in its window. The join now takes the coverage its own policy always targeted, which on
short segments is several times three. Measured against `hlsfixture --window 8` with `play --live
--fast-zap`, three runs per row: first picture on a 2 s-segment channel **2.22 s before, 0.20 s after**;
on 1 s segments **0.41 to 1.22 s before, 0.18 to 0.20 s after**, and the spread is the second half of
the finding, since before the change the number depended on where in the upstream segment cycle the tune
landed. A window at the three-segment floor has nothing deeper to offer and is unchanged, and so is a
long-segment provider, whose coverage target was already met inside the old bound. The deeper entry is
not paid back later: both arms fetch up to the same upstream segment number at the same wall clock, so
it is caught up at I/O speed instead of becoming a standing lag behind the live edge. What it does not
touch is a source with no playlist at all (raw MPEG-TS over HTTP), where there is no window to enter
further back into and the content genuinely does not exist yet.

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

**And the item has to be able to play (AE#684).** The depth is measured from the item's own
`currentTime()`, and before `readyToPlay` that is where the loader began fetching, not where playback
will begin. Under an `EXT-X-START` placement, which is how a rejoin lands a fresh item at the place the
session held, AVPlayer fetches from about 6 s below the target first, so the reading is the lookback
itself: one device capture shows `buffer ahead 4.00s` from a playhead of 48.00 s on an item placed at
53.908 s, every second of it behind the start, and `playImmediately` 36 ms before the item was ready. It
was the one item of five in that capture to be forced and the one its viewer reported out of sync, which
is a correlation and not yet a mechanism. A hold on an item that cannot play yet is now left alone
(`leaving the stall-avoidance wait alone on an item that cannot play yet ...; asked again at readiness`)
and decided again when the item becomes ready, from the playhead it really starts on.

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

## Recording a live stream

| Symbol | Notes |
| --- | --- |
| `startRecording(to:)` | `async throws`. Records the live source to a file, fed from the connection the session already holds. |
| `stopRecording()` | `async`. Ends the recording and closes the file. Idempotent, and a no-op when nothing is recording. |
| `$recordingState` | A `RecordingState`: `.idle`, `.recording(RecordingProgress)`, `.ended(RecordingEndReason)`, `.failed(RecordingFailure)`. Progress republishes at 1 Hz, not per packet. |

No second connection is opened. That is the whole point of the feature rather than a detail of it:
an IPTV plan commonly caps an account at 1 to 3 simultaneous connections, so a host that opens its
own connection to record either fails outright or knocks the viewer off the channel. The engine
already holds the one permitted connection and already demuxes every packet.

The recording is a **stream copy of the source packets into MPEG-TS**, taken before any audio
bridging. Nothing is decoded and nothing is re-encoded. A TrueHD or DTS channel therefore records
its original audio while playback is listening to the bridged FLAC rendition, and a file cut short
by a crash or a kill is still playable up to the truncation, which is why the container is MPEG-TS
rather than fragmented MP4. The file opens on the first video keyframe after the call, so it starts
on a decodable picture rather than mid-GOP.

It follows the source, not the playhead. Pausing, or scrubbing back inside the DVR window, does not
interrupt it.

**Which routes can record.** Only the two where the engine owns the byte path:

| `videoRoute` | Who holds the source connection | Recordable |
| --- | --- | --- |
| `.loopback` | The engine: demuxer, segment producer, local server | yes |
| `.software` | The engine: demuxer, software playback host | yes |
| `.remoteBypass` | AVFoundation, directly against the origin | no |

On `.remoteBypass` (`LoadOptions.nativeRemoteHLS`) the engine never sees a byte, so there is nothing
to record without opening the second connection the feature exists to avoid. `startRecording(to:)`
throws `.unsupportedRoute(.remoteBypass)` rather than recording nothing. The escape is the one
described under [Where the token rotates](#loading): reload with `nativeRemoteHLS: false` and the
session moves onto the ingest reader and `.loopback`. The engine does not perform that reroute by
itself, because it would visibly interrupt the picture as a side effect of pressing Record, and the
routing decision belongs to the host.

**The two reporting channels are disjoint.** A condition a host can act on before anything is
written is thrown out of `startRecording(to:)`: `.notLive`, `.unsupportedRoute`, `.alreadyRecording`,
`.cannotCreateFile`. A condition that can only be discovered while writing arrives through
`$recordingState` as `.failed`, because by then the call has long returned: `.diskFull`,
`.writeFailed`, `.writeTooSlow`. One failure is never reported through both.

`.writeTooSlow` is a contract worth reading twice: writes are handed to a bounded queue drained off
the demux thread, and when that queue fills, **the engine drops the recording rather than the
picture**. A recording that cannot keep up ends and says so; a demux thread parked on a slow disk
would stall playback, which is not a trade the engine makes.

**A reset ends the recording.** When `liveSourceReset` fires, or the host calls
`reloadAtCurrentPosition`, the file is closed cleanly and `$recordingState` publishes
`.ended(.sourceReset)`. The recording does not carry on into the same file: a reset can bring back
different codecs, different parameter sets or a different program, and writing that into streams
declared from the old source produces a file that is unplayable or silently wrong past the seam. The
host has the event and starts part two if it wants one. `stop()` and a new `load()` end it the same
way with `.ended(.sessionEnded)`; a recording never outlives its session.

`.ended` is published once the file is closed. The queued tail and the trailer are written off the
main actor, so it can arrive a moment after the call that ended the recording; `stopRecording()`
returns only after it, and a `startRecording(to:)` issued in that moment waits for it first. If a
`stopRecording()` or a new `load()` overtakes that wait, the start throws `CancellationError` and
records nothing. A stop that lands while the writer is already tearing itself down after a failure
(`.writeTooSlow`, `.diskFull`, `.writeFailed`) waits for that teardown and publishes the failure, not
`.ended`.

**Not implemented: recording from the start of what is already buffered.** A recording begins at the
call, not at the back of the DVR window. On `.loopback` what is retained is remuxed fMP4 with
**bridged** audio, not source packets, so prepending it would produce one file whose audio codec
changes in the middle. On `.software` the packet ring does hold source packets, but shipping the
behaviour on one route and not the other under one API is worse than not shipping it. If you need it,
say so on the tracker rather than working around it.

## Picture, layers and PiP

| Symbol | Notes |
| --- | --- |
| `videoGravity` | Fill mode of whichever layer is mounted (`AVPlayerLayer` or the software display layer). Settable; this is the aspect-fit / aspect-fill control. |
| `nativePlayerLayer` | The engine's own `AVPlayerLayer`, for a host building `AVPictureInPictureController` around a layer rather than around `currentAVPlayer`. |
| `$softwarePiPSource` | `SoftwarePiPSource` for sample-buffer PiP on the software path: the display layer plus transport answers on the enqueued frames' axis. iOS only in practice; tvOS AVKit does not evaluate sample-buffer content sources (FB9751461). |
| `$softwareDisplaySize` | The rectangle the software path's picture presents at: coded size under the decoder's pixel aspect. Mirrored, not latched, so a mid-stream resolution change re-shapes it. nil on every other path. |
| `sourceVideoWidth`, `sourceVideoHeight`, `sourceVideoPixelAspectRatio` | The source's CODED size and the multiplier that turns it into the presented one (`width * ratio`), read once from the probe (on `.remoteBypass`, from AVPlayer's item video track once it resolves: the delivered size). The ratio is 1 on square pixels and on a declared ratio the engine refuses (#290), never a guess; on the paths that draw, prefer what is on screen (`softwareDisplaySize`, `AVPlayerLayer.videoRect`) over recomputing it here. |
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
| `deactivatesAudioSessionOnStop` | Off by default. The engine declares the audio-session category at init and never activates it on the native path, because AVKit activates per playback and that is what lets tvOS negotiate the HDMI route (#24), so it never deactivates it either. Set true only when the app owns the session outright; the engine then releases it on a genuine final teardown, meaning `stop()` and never a reload, handoff or live retune. With several engines in one process the release belongs to the last one out: a stop while another engine is still active keeps the session and logs `[SharedOutput] ... still active, session kept`. |
| `logTag` | A short name for this instance (`tile2`), carried by the `[SharedOutput]` lines and a `[AetherEngine:<tag>] state=` line per transition. Set it before `load()` (the tag is captured when the engine joins), on every engine of a host that runs several at once. |

## Stills and thumbnails

| Symbol | Notes |
| --- | --- |
| `scrubThumbnail(atSeconds:maxWidth:)` | Cache-backed still for the active session, live or VOD. Decodes bytes the session already holds, so it opens no second connection and works on single-connection sources (debrid / torrent links, IPTV accounts capped at one request) where a second demuxer is refused. A native session decodes from its segment cache, a software session from its packet cache (VOD, AE#605) or its DVR packet ring (live, #544). A VOD target outside what is retained returns nil rather than the nearest retained frame. |
| `vodScrubThumbnail(atSeconds:maxWidth:)`, `liveScrubThumbnail(atSessionSeconds:maxWidth:)` | The two arms, for callers that know which axis they hold. Both arms also serve software sessions: the live arm out of the DVR packet ring (#544), the VOD arm out of the packet cache its seeks land in (AE#605), keyframe to target, on the same axis `seek(to:)` takes. |
| `supportsCacheBackedStills` | True while the session can serve `scrubThumbnail` without a second connection: any native session, a software live session, and a software VOD session reading a remote source. Gate the scrub-preview affordance on it: it reports capability, not per-frame availability, so a transient nil from `scrubThumbnail` while a segment is still being produced, or for a position the cache does not hold, is expected and means "time only, no image". False on a software session playing a local file, which keeps no cache because re-reading the file is free; `makeFrameExtractor()` serves that case. Before AE#605 this was false on every software session, live included. |

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
| `AetherEngine.version` | The engine release this source descends from, as the string a published tag carries. SwiftPM resolves a package to a revision rather than to a tag, so an About panel or the header of a diagnostic log has nothing else to name the engine with. Between releases, and under a pin on an unreleased commit, it names the last published version the checkout descends from. |
| `diagnostics.liveTelemetry` | 1 Hz `LiveTelemetry?` snapshot while playing or paused, nil while idle. On a separate `ObservableObject` so its ticks cannot re-render a host observing the engine. On the loopback and software routes `instantBitrateMbps` and `averageBitrateMbps` are the rate of the MEDIA played, not of the transfer (AE#514): the bytes of the played video and audio packets the playhead crossed, over the media seconds it crossed, about the last 10 s for the first and the whole session for the second. Read-ahead, a re-fetch after a seek and a paused live source draining into its DVR window do not move them, and both stand still through a pause; the transfer is `networkThroughputMbps`. On `.remoteBypass` it is fed from AVPlayer's access log alone: `instantBitrateMbps` and `averageBitrateMbps` are what the playing variant declares (BANDWIDTH, and AVERAGE-BANDWIDTH or BANDWIDTH where the master omits it), because the bytes AVPlayer transferred are buffer fill at link speed rather than the stream's rate, `networkThroughputMbps` is the access log's `observedBitrate`, `networkTransferredBytes` and `droppedFrameCount` its session totals, `forwardBufferSeconds` the loaded range ahead of the playhead. `avSyncGapMs` and `observedFps` are nil, and the loopback counters (`producerRestartCount`, `muxedBytesLifetime`, `serverBytesSentLifetime`, `serverRequestCount`, `demuxerBytesFetched`) read 0 because there is no loopback. |
| `LiveTelemetry.softwareCacheSeekHits`, `softwareCacheSeekMisses`, `softwareCacheSourceEpoch` | Optional cumulative software-VOD packet-cache counters. A hit repositions the retained consumer cursor without changing the source epoch; a miss repositions the demuxer and advances it. `nil` on other paths. `cachedBytes` includes retained compressed packet records on software VOD, distinct from decoded `displayCushionSeconds` and the underlying byte-reader window. |
| `EngineLog.handler` | Mirror every info-level line into a host capture path. Fires from whatever thread emitted it, so it must be thread-safe and non-blocking. |
| `EngineLog.subsystem`, `EngineLog.Category` | `de.superuser404.AetherEngine`, one category per subsystem: `engine`, `ffmpeg`, `session`, `muxer`, `demux`, `hls.server`, `audio.bridge`, `sw.playback`, `scrub`. |
| `EngineLog.Level` | `.info` reaches os_log and the host handler; `.verbose` is per-segment trace and reaches os_log's debug level **only**, never the handler, which is what keeps a mirrored stream readable. Read the verbose ones with `log stream --level debug`. |
| `EngineLog.registerSecret(_:)`, `EngineLog.unregisterSecret(_:)`, `EngineLog.redacted(_:)` | Name a value that must never be logged, such as an IPTV password the host holds. Every line reaching os_log or the handler has it replaced, raw or percent-encoded, wherever it sits. The engine already strips named parameters, `Bearer` / `Basic` credentials, userinfo, encoded payloads and the Xtream Codes path layout on its own, also inside a URL carried percent-encoded in another URL's query; this covers what only the host can know, such as a provider URL carrying the password as a bare path segment. Registrations are counted: a value registered twice stays redacted until it is unregistered twice. Returns false for a value under four bytes. `redacted(_:)` returns a line as the handler would receive it, for a line a host or tool prints itself next to the engine's. |
| `EngineLog.emit(_:category:level:)` | Emit a host line into the same stream, for a host that wants its own events interleaved with the engine's. |
| `segmentCacheDiskBytes`, `softwareHostFramesEnqueued` | Point reads for a stats overlay. |
| `activeProducerShiftSeconds`, `frameAhead`, `clockLeadSeconds` | Divergence diagnostics for tracing a clock that disagrees with the picture. Not for production playback logic. |
| `nativeItemReading()` -> `NativeItemReading?` | AE#509. The native item's own account of itself: `playhead` (`AVPlayerItem.currentTime()`, on the ITEM axis), `loadedRangeCount` (0 = nothing has been PLACED, which no buffer depth can say) and `status` (0 unknown, 1 ready, 2 failed). Async, read off the main actor. nil when no native item is mounted. The engine's published clock is `item + playlistShiftSeconds`, so on a live source hours into an encoder clock the two are thousands of seconds apart in a healthy session: quote both or neither. |

## LoadOptions

All flags default to safe values; the table is the full set. Depth for the media-shaped ones is in [formats.md](formats.md).

| Option | Default | What it does |
| --- | --- | --- |
| `httpHeaders` | empty | Extra headers on every probe, range and segment fetch. On `nativeRemoteHLS` they ride into the `AVURLAsset`, so header-enforcing IPTV origins work. Forwarded to sidecar subtitle fetches unless overridden. **Scoping differs by route.** On the plain `nativeRemoteHLS` bypass AVFoundation itself sends them to every host the playlists name (cross-host variants, segments and `EXT-X-KEY` URIs) and carries them across 302 redirects, so credential headers there reach every such host and the engine cannot narrow that. The per-origin credential scoping described for `HLSLiveIngestReader` applies only on the routes the engine fetches itself: the ingest, the disc reader, the origin relay, the subtitle proxy, the audio tap and the live subtitle renditions. A credential that must not reach every host a playlist names should not ride in `httpHeaders` on the bypass. |
| `isLive` | false | Treat the source as live. Set it explicitly; duration-based auto-detection is too noisy. |
| `dvrWindowSeconds` | nil | Timeshift window. nil means live-only and `seek` is a no-op. The window is a ceiling: the disk budget (a quarter of the free space, at most 2 GiB) bounds what is actually kept, so a long window on a high-bitrate channel or a small volume holds less than it asks for. With several engines running, each one's quarter is taken from the free space the others have not already claimed, so a tile added on a tight volume holds less history than the first one (AE#687). |
| `liveJoinProfile` | `.standard` | A `LiveJoinProfile`. `.fastZap` collapses TARGETDURATION to the source GOP plus headroom for one 1.5 x longer (AE#670) so an IPTV join costs seconds instead of a full holdback. |
| `clampsLiveResumeToWindow` | true | Whether `play()` may move a behind-live playhead by itself (edge snap on a live-only source more than 45 s behind, or a landing above the retained floor when a DVR window has slid past it). `false` hands the whole decision to the host, which then also owns the eviction case. |
| `liveJoinStartsImmediately` | true | Cuts AVPlayer's stall-avoidance wait short once at the live join, over a buffer that is non-empty and at least 1.5 s deep, on an item that has reached `readyToPlay` (AE#684). The join tail no host can otherwise reach; default since 6.55.0 on a device A/B, see the live-join section. |
| `liveBlockingReload` | nil (auto) | LL-HLS blocking-reload override for loopback live sessions. Auto derives eligibility from observed upstream cadence, which is what keeps a bursty relay off a `-15410` loop. |
| `nativeRemoteHLS` | false | Hand a remote `master.m3u8` straight to AVPlayer: no demuxer probe, no loopback. Built for `isLive: true`; a remote HLS VOD URL reaches this route regardless (AE#154). The clock here is item time, see `clock.$sourceTime` (AE#616). |
| `nativeRemoteHLSIngestFallback` | true | The #168 / #293 carriage recovery and the #363 401/403 bypass refusal recovery. Setting it false turns both off. |
| `audioOnly` | false | Lean audio pipeline, no video machinery. Also set automatically when the probe finds no video stream. |
| `audioBridgeMode` | `.surroundCompat` | Bridge encoder for codecs that cannot stream-copy into fMP4. `.surroundCompat` uses EAC3 for a source with more than two channels and FLAC for one with two or fewer (no surround to carry). `.lossless` uses FLAC up to 7.1 throughout and needs a sink that accepts multichannel LPCM. |
| `confirmAtmos` | false | Background per-track JOC confirmation, republishing `audioTracks` as tracks confirm. Never on the start path; skipped for live and forward-only readers. |
| `preferredAudioLanguages` | empty | First-frame audio pick from the engine's single probe. Ordered BCP-47 / ISO 639 tags; region and script are normalized and rank within one preference (#590). An explicit `audioSourceStreamIndex` still wins. |
| `preferredSubtitleLanguages` | empty | Post-load subtitle activation on the host-overlay path. Ranks language specificity (an explicitly opposite script is rejected, not demoted) before the descriptor axis. Pure convenience: no reload and no pre-probe, unlike the audio equivalent. |
| `externalSubtitles` | empty | Sidecar files registered at load, so they rank in the language preference and can join the native renditions. |
| `prepareNativeSubtitles` | false | Declare WebVTT renditions so subtitles survive PiP / AirPlay / external display. |
| `eagerNativeSubtitleReaders` | false | Populate those renditions at load instead of on first selection, for playlists AVKit auto-selects. Only meaningful with `prepareNativeSubtitles`. |
| `serveIFramePlaylist` | false | Serve an I-frame rendition next to the master, so a stock `AVPlayerViewController` shows scrub thumbnails and scans on I-frames with no host code. One keyframe per segment at full resolution; opens a second reader on the source. Absent (one log line says why) for live, sources without a keyframe index, `sequentialOrigin`, `heldSourceConnection`, single-request origins, discs and media-playlist routing. Hosts with their own transport bar use `scrubThumbnail`. |
| `nativeSubtitlePreferredLanguages` | empty | Which rendition is marked `DEFAULT=YES`. Resolved by the same BCP-47 matching as the overlay pick, so inline and PiP / AirPlay agree (#590). Read back as `nativeSubtitleDefaultOrdinal`. Does not activate the overlay path, so it cannot double up with the native render. |
| `preserveASSMarkup` | false | Emit raw ASS event lines instead of extracted text; pair with `TrackInfo.assHeader`. ASS / SSA codecs only, embedded and sidecar alike, so a session mixing an ASS track with a SubRip one needs no reload to cross between them (AE#587). |
| `teletextPage` | nil | Fix the DVB teletext caption page instead of letting libzvbi auto-detect. |
| `audioDelaySeconds` | 0 | Start the session with a lip-sync offset already in force; positive presents audio later. Same value `setAudioDelay(_:)` reads and writes, and a `reloadAtCurrentPosition(applying:)` can correct it. |
| `suppressDisplayCriteria` | false | Skip the display-criteria handshake entirely. For previews and headless runs. A host that clears `preferredDisplayCriteria` itself between loads (leaving full screen for a preview) no longer strands the engine's same-format skip: the next non-suppressed load reads the display manager, finds nothing set and writes again (AE#678). Clearing through `stop()` stays the cleaner path, because it resets the engine's record in the same step. |
| `matchContentEnabled` | true | Mirror of `AVDisplayManager.isDisplayCriteriaMatchingEnabled`. False routes HDR through the auto-tonemap path. |
| `panelIsInHDRMode` | false | **Host assertion** that the panel is presenting HDR right now, and the gate on whether the HDR10-to-DV upgrade is accepted upfront. It is an OR term over the engine's own readout on every platform, not a replacement for it and no longer confined to `suppressDisplayCriteria` hosts (AE#459). The readout it backs up is `currentEDRHeadroom > 1`, which answers only around a dynamic-range transition: an Apple TV whose output format is locked to HDR never makes one and reads as an SDR panel forever, and on tvOS 27 the property has stopped answering at all on at least one box. A wrong assertion costs one in-place media-playlist fallback (`-11848`), not the item. An in-place rebuild (an audio pick, a custom-source reload) runs no handshake, so it routes on the load's readout and display eligibility together with the session's current assertion and the refusal latch, rather than on this option alone (AE#541). |
| `attemptsHDRMasterOnUnprovenPanel` | true | Serve the HDR master to an HDR-eligible display whose panel state is unproven, and let AVFoundation's acceptance or refusal be the readout `UIScreen` will not give (AE#459). VOD only. The proxy this replaces is `currentEDRHeadroom`, which is measurably unreliable: on one Apple TV 4K 3rd gen on tvOS 26.6 it read a flat 1.00 across 46 samples of HDR content while the TV's own info display reported HDR, and later the same day, same box, same output format, same title, it read 1.20. The panel was presenting HDR and the property was wrong about it; what moves it is not established. What media-direct costs there is not the picture but the manifest: the SUBTITLES rendition, the AUDIO rendition that is the only place AVFoundation reads an HLS language from, and SUPPLEMENTAL-CODECS. A panel that proves itself through the headroom short-circuits and attempts nothing. A refusal costs one in-place media fallback, measured at 223 ms end to end (`-11868` after 54 ms, zero `errorLog` events, position kept, no visible black frame), and is latched for the process, so a genuinely SDR display pays it once rather than per title. Set it false on a host that knows its display is SDR. Live never attempts regardless: a live fallback is a rejoin at the edge rather than a restored position, and that cost is unmeasured. The published `videoFormat` is not moved by an ATTEMPT. It is moved by an ACCEPTANCE: a master AVFoundation has not refused after the settle window publishes the presented format, which is a stronger reading than the headroom rather than a substitute for it. |
| `panelPresentsDolbyVision` | false | **Host assertion** that this display presents Dolby Vision, for the platforms where the engine cannot observe it (AE#493). `AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`, so a Mac has no per-mode table at all, and `eligibleForHDRPlayback` answers HDR10 and HLG but not this: it proves EDR, not that AVFoundation will accept a DV variant here. Setting it publishes `videoFormat = .dolbyVision` and asks the tvOS display-criteria handshake for `dvh1`; HDR support rides along because DV is an HDR format, while HDR10 and HLG capability are not implied. It does not decide the packaging of a Profile 5, 8.1 or 8.4 source: 6.72.0 gave the non-DV branch its `dvcC` back and 6.73.0 its `SUPPLEMENTAL-CODECS`, so those three serve byte-identical manifests and segments either way (measured on macOS against the matched Dolby grades). Profile 7 and AV1 Dolby Vision are still gated on it. An assertion only ever adds, so `false` cannot hide a capability the system reports. A wrong assertion costs one in-place media-playlist fallback (`-11868` / `-11848`) at the same position, where AVPlayer tone-maps the base layer, and it is correctable mid-session through `reloadAtCurrentPosition(applying:)`. That net covers the item-failure class only, and the `-15628` an HDR10-only panel showed on the DV packaging in May 2026 (AE#4) is a stall rather than an item failure. It is no longer the claim's to own either: the same packaging reaches such a panel with or without it since 6.72.0 / 6.73.0, and it did not reproduce on tvOS 26.6. What the claim still moves on the route is HDR readiness, since `supportsHDR` rides along. Asserting also disables `forceDolbyVisionOnNonDVDisplay`, the tvOS route for that panel class (AE#455). |
| `omitCriteriaColorExtensions` | false | Diagnostic lever: leave colour out of `AVDisplayCriteria` so AVPlayer re-reads it from the bitstream. |
| `keepDvh1TagWithoutDV` | false | Diagnostic lever: force dvh1 tags and a master playlist regardless of display capability. |
| `forceDolbyVisionOnNonDVDisplay` | false | **Experimental (AE#455).** On a display with no Dolby Vision of its own, serve an HEVC Profile 8.1 source the way a Profile 5 source is served (`dvh1` sample entry, `dvcC` rewritten to profile 5 / compatibility 0, `CODECS="dvh1.05.LL"`), so AVPlayer composes the RPU itself instead of handing the panel the static-metadata HDR10 base layer. The bitstream is untouched; only the container's claim about it changes. Ignored on a display that does Dolby Vision, and Profile 8.1 only. See [formats.md](formats.md#dolby-vision-signaling) for what it buys and what it risks. |
| `dolbyVisionHandling` | `.automatic` | A `DolbyVisionHandling`. `.baseLayerOnly` presents the HDR10 / HLG base layer of a Dolby Vision source and leaves the Dolby Vision out of the container on every display: plain `hvc1` / `av01` sample entry, `dvcC` stripped, no `SUPPLEMENTAL-CODECS`, HDR10 / HLG display criteria, `videoFormat` reads the base layer's format while `sourceVideoFormat` and `sourceDVProfile` keep saying what the file carries. The route a host offers as "Dolby Vision: off (HDR10)", for a source whose Dolby Vision is wrong and whose base layer is right: the reported shape is a remux carrying a Profile 7 RPU under a container record claiming Profile 5, where a player that believes the record decodes YCbCr as IPT and the picture comes out green / violet. Applies to HEVC Profile 7 / 8.1 / 8.4, AV1 Profile 10.1 / 10.4, and a Profile 5 (or AV1 10.0) record whose VUI declares a BT.2020 YCbCr PQ or HLG base; a Profile 5 whose VUI is unspecified carries IPT-PQ-c2, has no base layer to present, keeps its route, and the engine says so in the log. Takes precedence over `forceDolbyVisionOnNonDVDisplay`. A tuning field, correctable through `reloadAtCurrentPosition(applying:)`; a Profile 5 record the VUI contradicts also stops refusing the software path under it. See [formats.md](formats.md#dolby-vision-signaling). |
| `preferredDecodePath` | `.automatic` | A `DecodePath`. `.software` serves this source through `SoftwarePlaybackHost` whatever the routing concluded, scoped to this session and costing the source nothing (seeks, the audio switch and the title switch all keep working). The escape for the formats `VTCapabilityProbe` deliberately cannot classify, and for live H.264 / HEVC, which never reaches that gate at all. One-way: there is no `.native`. See [Overriding the decode path](#overriding-the-decode-path). |
| `escalatesToSoftwarePath` | `true` | Whether a native session AVPlayer refuses on its merits (`CoreMediaErrorDomain`), or a live join without an entry point the native route can open (`AetherEngine.LiveJoin`, AE#627), may be rebuilt once on the software path (AE#561). `false` surfaces the failure as `.error` instead, for a host with its own fallback ladder (AE#629). Correctable. |
| `sharedOutputRole` | `.primary` (default) or `.secondary` | A `SharedOutputRole`. A secondary engine never writes display criteria and never owns Now Playing, whatever `suppressDisplayCriteria` and `ownsVideoNowPlayingSession` say, on the audio-only path too. It also skips the play gate's wait for a criteria write and the panel readout (`criteriaPanelReadout` is nil, as for any suppressed load), so its HDR labelling relies on `panelIsInHDRMode`. The role is fixed for a session, but a later `load()` may change it: as an identity field it only blocks corrections (Sodalite#175). A host that opted into `ownsVideoNowPlayingSession` and changes the role without a `stop()` keeps the native host's original Now Playing ownership until the next stop. |
| `deinterlaceMode` | `.auto` | A `DeinterlaceMode` for the software path: the Metal / VideoToolbox graph with a CPU bwdif fallback, or `.software` to force the CPU path. |
| `deinterlaceFieldRate` | `.field` | A `DeinterlaceFieldRate`: the hardware deinterlacer emits one frame per field (25i to 50p) or per frame. The software fallback is always frame rate, because doubling a CPU bwdif is the wrong trade and a fallback should not change cost class. |
| `probesize`, `maxAnalyzeDuration` | nil | Caller-bounded open-time probe budget (defaults 50 MB / 60 s). They fail **open**: an over-tight budget loads with late-resolving tracks silently missing rather than throwing, so validate track presence if you tighten them. Do not pass `0` for `maxAnalyzeDuration`; FFmpeg maps it to a shorter heuristic. |
| `forwardBufferSegments` | nil (10, about 40 s) | How far the producer may race ahead and how much the cache keeps resident. Clamped to 4...2700; past the historical 150 the real bound is the session's disk budget, so a "buffer without limit" option can pass `Int.max`. Ignored on `nativeRemoteHLS`. Native HLS retention is readable as `$residentRanges` (see Time). Software VOD uses the same forward-window and volume-budget policy for compressed packet read-ahead; its continuous selected A/V frontier is `bufferedPosition`, not native `residentRanges`. |
| `sequentialOrigin` | false | Declare an origin that fabricates range answers: one long-lived unranged GET, no ranged probes, non-seekable pb. **Seeking is unavailable**; re-request the archive at a shifted start instead. A URL source the reader finds forward-only by itself (`Range` ignored, so it can only stream front to back; the open confirms a 200 answer with a one byte range, because some CDNs answer a cache miss that way) is served this way without the declaration when its container states a duration, which a stated `Content-Length` lets an MPEG-TS source estimate; `loadedOptions` then reads `true` with that duration declared, and without a duration it stays on the software path. An AirPlay hop on such a session swaps the item onto the LAN address instead of reopening the source, since a reopen could only start again from byte 0. |
| `declaredDurationSeconds` | nil | Trusted duration, overriding the container's. Required alongside `sequentialOrigin` on VOD, where the tail read is gone. |
| `maxConcurrentSourceRequests` | nil | Most requests the reader may have open against this origin at once, across every path it fetches on (pump ranges, detour blocks, size probes, tail prefetch, subtitle side reader, and the HLS live ingest's playlist, segment and key fetches, whose prefetch window narrows to it, AE#678). nil counts without capping and lowers the ceiling on its own after a 429/503/509. Set it when the provider states a limit; `1` also switches off the speculative parallel paths, which exist only to overlap with the pump. Counts **requests**, not TCP connections, because over HTTP/2 a session multiplexes every request onto one connection while the origin still counts each one (AE#377). It is also the only ceiling: several engines playing from one origin are bounded by this value and by what the origin refuses, not by a transport pool underneath it (AE#450). |
| `heldSourceConnection` | false | Ask the source **once** and pull it, instead of ending the connection at the reader's window high water and asking again every 8 to 16 MB of drain (AE#377). For an origin that punishes repeated requests rather than concurrency: some CDNs refuse new requests for minutes at a stretch while serving an already open connection at full rate, and against one of those the request cadence is the defect, at any range size (measured at the reporting origin: 32 MB ranges raised to 256 MB, eight times fewer requests, the refusals unchanged). Where `maxConcurrentSourceRequests` bounds how many requests are in flight, this removes the second request. The read path is the engine's own HTTP/1.1 over a demand-driven stream task, so: **HTTP/1.1 only** (no ALPN, an HTTP/2-only origin is out of scope), the **system proxy configuration does not apply**, and TLS is the OS's through the same host trust decision as every other engine session but has not been exercised against a self-signed origin. A viewer who pauses ends the connection after five seconds and resuming costs one request at the frontier, because a held flow nobody reads is the process-wide Network.framework starvation of AE#310. Applies to the playback reader; the subtitle and enrichment side readers keep the default transport, since they park for minutes at a time. The open-time detection of an origin that ignores `Range` (see `sequentialOrigin`) does not cover it, because its open is open-ended. **Names the session**: the transport is chosen at open, so a reload that changes it is refused. |
| `autoplay` | true | False mounts paused: the load skips the terminal `play()` and settles at `.paused` for a host that resumes later. It describes THIS MOUNT and nothing after it: the rebuilds a session makes on its own (`reloadAtCurrentPosition`, an option correction, the AirPlay LAN swap, an audio-delay nudge) come back in the transport state the session is in, not in this one. Correcting it through `reloadAtCurrentPosition(applying:)` therefore does nothing (the log names it as not applied rather than as applied, AE#464 round 3, and the call returns it as `sessionOwned` with `rebuilt` false rather than spending a teardown on it, AE#464 round 4); call `play()` or `pause()` instead. |

## Value types

| Type | Carries |
| --- | --- |
| `SourceProbe` | `url`, `durationSeconds`, `videoFormat`, `videoCodecID` / `videoCodecName`, `videoWidth` / `videoHeight`, `videoFrameRate`, `isDolbyVision`, `dvProfile`, `carriesHDR10PlusMetadata`, `carriesHDRVividMetadata`, `audioTracks`, `subtitleTracks`, `metadata`, `isLive`, `videoStreamFormat` (the same `VideoStreamFormat` a session publishes as `$sourceVideoStreamFormat`). `carriesHDR10PlusMetadata` is `false` unless the probe was asked for `.hdr10Plus`, and a `false` means "not asked, or not seen inside the budget", never "proven absent". When it is true and the container said HDR10, `videoFormat` reads `.hdr10Plus`; a Dolby Vision source keeps `.dolbyVision` and carries the flag alongside. `carriesHDRVividMetadata` follows the same contract for `.hdrVivid` (#699) and never moves `videoFormat`: HDR Vivid rides an HLG or PQ base, which stays the label. |
| `TrackInfo` | `id`, `name`, `codec`, `language`, `channels`, `bitrate`, `isDefault`, `isForced`, `isHearingImpaired`, `isCommentary`, `isAtmos`, `assHeader`, `isExternal`, `isNativelyRenderedSubtitle`, and for audio `sampleRate`, `bitsPerSample`, `sampleFormat`, `channelLayout`, plus `profile` for every track (AE#658). `bitsPerSample` is 0 where the codec has no fixed depth (AAC, AC-3, E-AC-3 and Opus decode to float); `sampleFormat` is the probe decoder's output in libav's names ("fltp", "s32"); `profile` is libavcodec's profile name and the place DTS:X ("DTS-HD MA + DTS:X") and TrueHD Atmos ("Dolby TrueHD + Dolby Atmos") show up, where `isAtmos` covers E-AC-3 JOC only. `isNativelyRenderedSubtitle` marks a subtitle the playback backend draws itself (a remote-HLS rendition AVFoundation renders), so no cue reaches `subtitleCues` and an overlay control (position, delay, styling) has nothing to act on. |
| `MediaMetadata` | `title`, `artist`, `album`, `artworkData`, `hasDisplayMetadata`. There is no separate album-artist field: a container's album artist is a fallback the parser folds into `artist`. |
| `SubtitleCue` | `id`, `startTime`, `endTime`, `body` (a `SubtitleCue.Body`: `.text`, `.richText`, `.image`), `placement`, plus `text` and `isForced` conveniences. |
| `SubtitleTextRun` | `text`, `color`, `isBold`, `isItalic`, `isUnderlined`, `isStruckThrough`, `fontName`, `fontSize`, `isStyled`. |
| `SubtitleTextPlacement` | `alignment` (numpad), `position` (a [0, 1] anchor). |
| `SubtitleImage` | `cgImage`, `position`, `canvasSize`, `isForced`. |
| `ExternalSubtitleTrack` | `url`, `name`, `language`, `isForced`, `isHearingImpaired`, `isDefault`, `httpHeaders` (nil forwards `LoadOptions.httpHeaders`), `formatHint` for URLs whose path hides the format, and `sourceStreamIndex` for a container holding several subtitle streams. That index addresses the container at `url`, not the played media. |
| `NativeSubtitleTrack` | `ordinal`, `language`, `displayName`, plus `sameLanguageRank(of:in:)` for disambiguating same-language options (eng Full against eng SDH). |
| `RecordingState` | `.idle`, `.recording(RecordingProgress)`, `.ended(RecordingEndReason)`, `.failed(RecordingFailure)`. What the session's live recording is doing. |
| `RecordingProgress` | `url`, `startedAt`, `bytesWritten`, `durationSeconds`. Republished at 1 Hz while recording. |
| `RecordingEndReason` | `.stoppedByHost`, `.sourceReset`, `.sessionEnded`. Why a recording stopped without failing; the file is closed and playable in every case. |
| `RecordingFailure` | `.unsupportedRoute(VideoRoute)`, `.notLive`, `.alreadyRecording(URL)`, `.cannotCreateFile`, `.diskFull`, `.writeFailed`, `.writeTooSlow`, `.noStreamsToCopy`. The first four are thrown out of `startRecording(to:)`; the rest arrive through `$recordingState`. |
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

- **Test hooks**: `setForceSoftwarePathForTesting`, `setSourceThrottleKbpsForTesting`, `setSoftwareBackgroundAudioOnlyForTesting`, `softwareVideoFramesEnqueuedForTesting`, `setLargeAllocationCensusEnabled`, `forceStalledConsumerReloadForTesting`, `stallRendererClockForTesting`, `rendererClockRateForTesting`.
- **`playbackBackend`**: the internal rendering backend, exposed read-only for overlays. Hosts must not branch on it; `videoRoute` is the surface that answers the same question honestly.
- **`HLSVideoEngine`** and its `DiagnosticStats`: the loopback session's own machinery, public because `aetherctl` drives it directly.
- **`DiscInspector` / `DiscInspection`**, `DoviRpuConverter` and its probe, `AudioTapProbe`, `SoftwareDecodeProbeResult`, `A53SEIParser`: repro and inspection surfaces behind `aetherctl` subcommands.
- **`HLSLiveIngestReader`'s internals** (`terminalError`, `upstreamTargetDuration`, `observedLiveCadenceSeconds`, `closedLiveCadenceSeconds`, `upstreamSegmentDurationSeconds`, `companionAudioReader`): fixture and diagnostic reads. The last two are the closed evidence the served TARGETDURATION is sealed from (AE#447); `upstreamTargetDuration` is the upstream's own claim, reported in the seal line and derived from nowhere.
- **`SubtitleChannel`**: the primary / secondary selector on the engine's internal subtitle routing. No public signature takes one; a host picks the channel by calling the primary or the secondary method.


## MovieClaw downstream extensions

These extensions come from the MovieClaw downstream engine, based on AetherEngine 7.28.0.
The source remains under the repository's existing license. The complete patch inventory and
measured host regressions are in [PATCHES.md](../PATCHES.md).

### Host integration contracts

- `LoadOptions.vodStartsImmediately` opts VOD into a one-time `playImmediately` kick after sufficient
  startup buffering. It defaults to false.
- `LoadOptions.audioTrackOrdinal` selects the zero-based audio-track ordinal during the initial
  probe, avoiding a post-start track-switch rebuild. `audioSourceStreamIndex` still takes precedence.
- `LoadOptions.sourceCacheKey` identifies the underlying, immutable source across refreshed signed
  URLs. Hosts must change the key when the source changes; a changed content length invalidates it.
  For custom disc readers, call `bindSourceCacheKey(url:key:)` for each file before opening it.
- `LoadOptions.matroskaCues` accepts `MatroskaHostCues(offset:data:)`, a complete compact video Cues
  element at the original tail Cues offset. The offset must match the container's SeekHead; invalid
  or mismatched hints are ignored. Subtitle side readers retain the original source index.
- `LoadOptions.backwardBufferSegments` sets the retained backward segment window alongside the
  existing forward window, so hosts can reduce both when storage is low.
- `snapsNextStartToKeyframe` is a one-shot host request consumed and reset at the next `load()`.
  It applies to a user's initial/resume load; internal reloads keep their exact position.
- `setForwardBufferDuration(_:)` grows the loopback or software read-ahead window at runtime,
  subject to storage limits. `setPrefetchSuspended(_:)` suspends speculative downloading separately
  from playback pause, and the requested state survives in-place engine rebuilds.
- `hostManagesAudioSessionCategory` lets an iOS/tvOS host declare the audio-session category,
  policy and multichannel support before constructing its first engine. It defaults to false;
  setting it to true transfers that category declaration to the host.
- `PlaybackErrorKind.storageExhausted` distinguishes failed segment storage from codec/muxer errors,
  allowing a host to reduce its window and reopen at the current position.
- Bitmap-to-text OCR and its long subtitle prefetch window are armed when the host requests native
  subtitle rendering through `setNativeSubtitleRendering(_:)`, for PiP, AirPlay or external displays.
  Hosts rendering bitmap subtitles in their own overlay avoid the extra OCR reader.

### Remote disc directories

`DiscDirectoryReader` extends `IOReader` with `discFiles`, `preferredPlaylist`, and `openDiscFile(_:)`.
`HTTPDiscDirectoryReader(files:preferredPlaylist:httpHeaders:)` accepts entries of
`HTTPDiscDirectoryReader.File(path:size:url:)` and serves Blu-ray BDMV or DVD VIDEO_TS directories
without a server-side concat/remux. Pass the directory reader as a custom source; the engine
recognizes the title, concatenates its clips, and uses Blu-ray CLPI entry-point maps or DVD time maps
for seeking. `Demuxer.discImageFragment` marks extensionless URLs as disc images locally; the URL
fragment is not sent in the HTTP request.

### Source cache lifecycle and prefetch

Call `sweepStaleSessionCaches()` off the main thread during app startup, and
`flushSourceByteCacheIndexes()` when the host enters the background. `preconnect(url:httpHeaders:)`
warms origin connections without downloading media. `prefetchSourceRanges(url:cacheKey:ranges:httpHeaders:)`
accepts `[SourceByteRange]` and returns `SourceRangePrefetchReport`, including fetched bytes,
already-cached bytes, or a decline reason. Cancellation stops fetching while retaining bytes already
written. Bind a stable source key before spending the prefetched ranges in a load.

### Downstream tuning switches

Configure process-wide tuning before playback, rather than racing mutations against active loads.

| Member | Downstream behavior |
| --- | --- |
| `vodSegmentTargetSeconds` | VOD remux target duration; clamped to the supported range, with keyframe spacing still controlling actual cuts. |
| `servesSegmentsProgressively`, `progressiveFragmentSeconds` | Progressive VOD segment delivery and its fragment duration. |
| `declaresIndependentMediaSegments` | Advertise independently decodable media segments when the downstream producer emits them. |
| `parkSecondaryTrueHDDuringProbe` | Keep secondary TrueHD tracks out of the initial stream-info probe, then restore them. |
| `cuePrewarmTargetsStart` | Warm an MKV index at the requested start rather than the midpoint. |
| `prefetchesMatroskaCues`, `usesHostMatroskaCues` | Enable index-first Cues prefetch and host-provided compact Cues respectively. |
| `prioritizesIndexPrefetch` | Use a short initial header request and yield speculative head reads to the index prefetch. |
| `waitsOnProgressingPrefetch`, `skipsDetourOnSlowLink` | Wait for productive prefetch work, and avoid costly detours on a slow link. |
| `persistsSourceByteCache` | Retain source ranges across launches; set before the shared cache is first used. |
| `sourceByteCacheKeepsSpareRuns`, `sourceByteCacheTrimKeepsMetadata` | Retain disjoint runs within a block, and prefer metadata ranges during startup trimming. |
| `sourceByteCacheWritesInBackground` | Dispatch source-cache writes and eviction to the cache's serial I/O queue. |
| `removePersistedSourceByteCache()` | Clear the persistent cache directory before the shared cache is first used. |
| `temporaryVolumeAvailableBytes(importantUsage:)` | Query cached available storage for host and engine budgeting. |
| `volumeAvailableBytesOverrideForTesting`, `simulateStorageFullUntilUptimeForTesting` | Test-only hooks for constrained storage and ENOSPC recovery. |
