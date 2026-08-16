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

### What must be set before `load()`

| Set before the load | Why |
| --- | --- |
| `ownsVideoNowPlayingSession` | read when the native host is created; a host preserved across a native to native reload keeps what it was created with |
| `LoadOptions.preferredAudioLanguages` | the picked audio track is muxed at the first frame; a later `selectAudioTrack` costs a reload |
| `LoadOptions.prepareNativeSubtitles`, `externalSubtitles` | the native renditions are declared in the init segment |
| `LoadOptions.panelIsInHDRMode`, `matchContentEnabled` | the display-criteria handshake runs synchronously inside `load` |
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

## Constructing and binding

```swift
let player = try AetherEngine()
```

| Symbol | What it is |
| --- | --- |
| `AetherEngine()` | `public init() throws`, `@MainActor`, an `ObservableObject`. One engine per playback surface. The audio-session category is declared off-main and never activated here, because AVKit activates per playback and that is what lets tvOS negotiate the HDMI route (#24). |
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
| `reloadAtCurrentPosition()` | `async throws`. Background reopen at the current position, preserving options. Session-preserving: it finishes an installed audio tap and keeps the native host where it can. |
| `stop(resetDisplayCriteria:finalTeardown:)` | Ends the session, `state` becomes `.idle`, `startupProgress` becomes nil. `resetDisplayCriteria: false` keeps the panel in its current mode across an item handoff. |
| `AetherEngine.probe(url:options:)` / `probe(source:options:)` | `nonisolated static throws -> SourceProbe`. Demux-only metadata read, no decoders, no session. `options` is read for `httpHeaders` only. For a custom reader the caller keeps ownership, `close()` is not called, and the cursor is left unspecified. |
| `AetherEngine.probeDetectingAtmos(url:options:atmosDetection:)` | `probe` plus a bounded decode pass that authoritatively resolves E-AC-3 JOC for an Atmos badge. Strictly more expensive; never on the playback-start path. Decode-side failures degrade to "not confirmed" rather than throwing. |
| `AetherEngine.externalSubtitleTrackIDBase` | `100_000`. Synthetic ids of external subtitle tracks start here. |

`IOReader` is the custom-source protocol: `read`, `seek`, `close` are required; `cancel()`, `makeIndependentReader()` and `discImageProbeEnabled` have defaults that unlock teardown-unblocking, embedded subtitles plus scrub stills, and ISO/UDF probing respectively. Full contract in [formats.md](formats.md).

## Transport

| Symbol | Notes |
| --- | --- |
| `play()` | Rewinds first when parked at the final frame of a VOD; a no-op on `.ended`. |
| `pause()`, `togglePlayPause()` | |
| `seek(to:)` | `async`. Source-axis seconds. Rejected when idle, errored, ended, or live without a DVR window. |
| `seek(toSourceTime:)` | Deprecated alias for `seek(to:)`. The clock is unified onto source PTS, so the two are the same call. |
| `setRate(_:)` | Clamped to `maxSupportedRate`. |
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
| `clock.$liveEdgeTime`, `clock.$seekableLiveRange`, `clock.$behindLiveSeconds`, `clock.$isAtLiveEdge` | live-window surfaces |
| `player.currentTime`, `sourceTime`, `progress`, `bufferedPosition`, `liveEdgeTime`, `seekableLiveRange`, `behindLiveSeconds`, `isAtLiveEdge` | non-published mirrors of the same values for one-shot reads |
| `$duration` | seconds; a `LoadOptions.declaredDurationSeconds` outranks the container's |

## What the session is doing

| Symbol | Reading |
| --- | --- |
| `$state` | `.idle`, `.loading`, `.playing`, `.paused`, `.seeking`, `.ended`, `.error(String)`. |
| `$errorInfo` | `PlaybackErrorInfo?`, the machine-readable half of `.error`: a `PlaybackErrorKind` token, plus the underlying `NSError` domain and code where one is involved. Non-nil exactly while `state` is `.error`, assigned before it. Classify on this, never on the message. |
| `$playbackPhase` | The derived one-source-of-truth status: adds `.rebuffering` and `.stalled(reconnecting:)`. Prefer it over stitching `state` + `isBuffering` + `isSeeking`, and over matching log text. |
| `$isBuffering`, `$isSeeking`, `$seekTarget` | The raw axes `playbackPhase` folds. |
| `seekEvents` | `AnyPublisher<SeekEvent, Never>`: `.began`, `.landed(renderedTime:)`, `.stalled`, `.superseded`, `.rejected(SeekEvent.Rejection)`, each with its `target`, an `id` that spans the seek, and a `SeekEvent.Origin` (`.programmatic`, `.nativeScrub`, `.deferred`; a deferred seek is one the session could not take yet, which is where the engine publishes an optimistic `currentTime` for a position nothing has reached). Use it where the falling edge of `$isSeeking` matters: a level cannot say whether a seek landed, gave up, or was superseded, and a `.stalled` seek can still land later under the same id. |
| `$isSessionReady` | The session is ready in the AVFoundation sense. Not the edge a black cover comes off on. |
| `$hasFirstFrameReadyForDisplay` | The picture for **this** load is up. Latched for the load, cleared at the next `load()` / `stop()`. Audio-only sessions never arm it. On an external screen (`isExternalPlaybackActive`) the local layer never reaches readiness, so the item's readiness is the honest edge and the flag latches there (#315). |
| `$startupProgress` | `StartupProgress?` for a determinate loading bar. |
| `$videoRoute` | `VideoRoute`: which pipeline is actually serving, one of `.none`, `.remoteBypass`, `.loopback`, `.software`, `.audio`. `LoadOptions.nativeRemoteHLS` is only the request; the carriage watchdog, the remembered verdict and the HLS reroutes move a session between routes, mid-session too. Branch on this, above all for who draws subtitles. |
| `$videoFormat` | The format being presented: `.sdr`, `.hdr10`, `.hdr10Plus`, `.dolbyVision`, `.hlg`. |
| `$sourceVideoFormat` | The format the **source** carries, before any panel-driven mapping. The pair is what an honest badge needs: HDR content on an SDR panel differs between the two. |
| `$sourceDVProfile`, `$sourceVideoFrameRate`, `$sourceVideoBitrate` | Source detail for an info panel. |
| `$activeVideoDecoder`, `$activeAudioDecoder` | The decoder names actually in use, for a stats overlay. This is the honest "what is decoding this" surface; `playbackBackend` is not. |
| `$metadata` | `MediaMetadata` parsed at load (title / artist / album / cover). |
| `$mediaChapters`, `$discChapters`, `$discTitles`, `$selectedDiscTitle` | Container chapters, and disc titles / chapters for DVD and Blu-ray ISO sources. |
| `$currentAVPlayer`, `$currentAVPlayerItem` | The live AVFoundation objects, re-emitted on every reload. Both nil on `.software`, which renders into its own layer. A host that only ever hands `currentAVPlayer` to an `AVPlayerViewController` gets audio over an empty video plane on that route (#298). |
| `AetherEngine.displayCapabilities` | `static DisplayCapabilities`: `supportsHDR`, `supportsDolbyVision`, `supportsHDR10`, `supportsHLG` for the current display. What a settings screen should read instead of guessing from the device model. |

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

## Picture, layers and PiP

| Symbol | Notes |
| --- | --- |
| `videoGravity` | Fill mode of whichever layer is mounted (`AVPlayerLayer` or the software display layer). Settable; this is the aspect-fit / aspect-fill control. |
| `nativePlayerLayer` | The engine's own `AVPlayerLayer`, for a host building `AVPictureInPictureController` around a layer rather than around `currentAVPlayer`. |
| `$softwarePiPSource` | `SoftwarePiPSource` for sample-buffer PiP on the software path: the display layer plus transport answers on the enqueued frames' axis. iOS only in practice; tvOS AVKit does not evaluate sample-buffer content sources (FB9751461). |
| `$softwareDisplaySize` | The rectangle the software path's picture presents at: coded size under the decoder's pixel aspect. Mirrored, not latched, so a mid-stream resolution change re-shapes it. nil on every other path. |
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

## Diagnostics

| Symbol | Notes |
| --- | --- |
| `diagnostics.liveTelemetry` | 1 Hz `LiveTelemetry?` snapshot while playing or paused, nil while idle. On a separate `ObservableObject` so its ticks cannot re-render a host observing the engine. |
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
| `liveBlockingReload` | nil (auto) | LL-HLS blocking-reload override for loopback live sessions. Auto derives eligibility from observed upstream cadence, which is what keeps a bursty relay off a `-15410` loop. |
| `nativeRemoteHLS` | false | Hand a remote `master.m3u8` straight to AVPlayer: no demuxer probe, no loopback. Pair with `isLive: true`. |
| `nativeRemoteHLSIngestFallback` | true | The #168 / #293 carriage recovery and the #363 401/403 bypass refusal recovery. Setting it false turns both off. |
| `audioOnly` | false | Lean audio pipeline, no video machinery. Also set automatically when the probe finds no video stream. |
| `audioBridgeMode` | `.surroundCompat` | Bridge encoder for codecs that cannot stream-copy into fMP4. `.lossless` uses FLAC up to 7.1 and needs a sink that accepts multichannel LPCM. |
| `confirmAtmos` | false | Background per-track JOC confirmation, republishing `audioTracks` as tracks confirm. Never on the start path; skipped for live and forward-only readers. |
| `preferredAudioLanguages` | empty | First-frame audio pick from the engine's single probe. An explicit `audioSourceStreamIndex` still wins. |
| `preferredSubtitleLanguages` | empty | Post-load subtitle activation on the host-overlay path. Pure convenience: no reload and no pre-probe, unlike the audio equivalent. |
| `externalSubtitles` | empty | Sidecar files registered at load, so they rank in the language preference and can join the native renditions. |
| `prepareNativeSubtitles` | false | Declare WebVTT renditions so subtitles survive PiP / AirPlay / external display. |
| `eagerNativeSubtitleReaders` | false | Populate those renditions at load instead of on first selection, for playlists AVKit auto-selects. Only meaningful with `prepareNativeSubtitles`. |
| `nativeSubtitlePreferredLanguages` | empty | Which rendition is marked `DEFAULT=YES`. Read back as `nativeSubtitleDefaultOrdinal`. Does not activate the overlay path, so it cannot double up with the native render. |
| `preserveASSMarkup` | false | Emit raw ASS event lines instead of extracted text; pair with `TrackInfo.assHeader`. |
| `teletextPage` | nil | Fix the DVB teletext caption page instead of letting libzvbi auto-detect. |
| `suppressDisplayCriteria` | false | Skip the display-criteria handshake entirely. For previews and headless runs. |
| `matchContentEnabled` | true | Mirror of `AVDisplayManager.isDisplayCriteriaMatchingEnabled`. False routes HDR through the auto-tonemap path. |
| `panelIsInHDRMode` | false | Mirror of `currentEDRHeadroom > 1`. Governs whether the HDR10-to-DV upgrade is accepted upfront. |
| `omitCriteriaColorExtensions` | false | Diagnostic lever: leave colour out of `AVDisplayCriteria` so AVPlayer re-reads it from the bitstream. |
| `keepDvh1TagWithoutDV` | false | Diagnostic lever: force dvh1 tags and a master playlist regardless of display capability. |
| `deinterlaceMode` | `.auto` | A `DeinterlaceMode` for the software path: the Metal / VideoToolbox graph with a CPU bwdif fallback, or `.software` to force the CPU path. |
| `deinterlaceFieldRate` | `.field` | A `DeinterlaceFieldRate`: the hardware deinterlacer emits one frame per field (25i to 50p) or per frame. The software fallback is always frame rate, because doubling a CPU bwdif is the wrong trade and a fallback should not change cost class. |
| `probesize`, `maxAnalyzeDuration` | nil | Caller-bounded open-time probe budget (defaults 50 MB / 60 s). They fail **open**: an over-tight budget loads with late-resolving tracks silently missing rather than throwing, so validate track presence if you tighten them. Do not pass `0` for `maxAnalyzeDuration`; FFmpeg maps it to a shorter heuristic. |
| `forwardBufferSegments` | nil (10, about 40 s) | How far the producer may race ahead and how much the cache keeps resident. Clamped to 4...2700; past the historical 150 the real bound is the session's disk budget, so a "buffer without limit" option can pass `Int.max`. Ignored on `nativeRemoteHLS`. |
| `sequentialOrigin` | false | Declare an origin that fabricates range answers: one long-lived unranged GET, no ranged probes, non-seekable pb. **Seeking is unavailable**; re-request the archive at a shifted start instead. |
| `declaredDurationSeconds` | nil | Trusted duration, overriding the container's. Required alongside `sequentialOrigin` on VOD, where the tail read is gone. |
| `autoplay` | true | False mounts paused: the load skips the terminal `play()` and settles at `.paused` for a host that resumes later. |

## Value types

| Type | Carries |
| --- | --- |
| `SourceProbe` | `url`, `durationSeconds`, `videoFormat`, `videoCodecID` / `videoCodecName`, `videoWidth` / `videoHeight`, `videoFrameRate`, `isDolbyVision`, `dvProfile`, `audioTracks`, `subtitleTracks`, `metadata`, `isLive`. |
| `TrackInfo` | `id`, `name`, `codec`, `language`, `channels`, `bitrate`, `isDefault`, `isForced`, `isHearingImpaired`, `isCommentary`, `isAtmos`, `assHeader`, `isExternal`. |
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
| `PlaybackErrorKind` | The stable token inside it: `.sourceOpenFailed`, `.customSourceProbeFailed`, `.liveSourceUnavailable`, `.hlsPlaylistOnRawLivePath`, `.dolbyVisionRequiresHardware`, `.demuxedAudioLiveUnsupported`, `.nativeItemFailed`, `.noPlayableTrackWithinBudget`, `.masterPlaylistRejected`, `.vodSourceFailed`, `.softwarePipelineFailed`, `.audioSessionFailed`, `.reloadFailed`, `.liveReloadNeverReady`, `.audioTrackSwitchFailed`. A string-backed struct rather than an enum, so a kind added in a minor release cannot break a host's switch; raw values are API and do not change. |
| `DisplayCapabilities`, `StartupProgress`, `SeekEvent`, `PresentationAxisMap`, `NativeVideoFrameTime`, `SoftwareVideoFrameTime`, `SoftwarePiPSource`, `SystemCaptionRequest`, `AetherEngineError`, `HLSIngestError` | Covered in their sections above. |
| `FontAttachment` | Attached font files for authored ASS rendering: `filename`, `mimeType`, `data`. |

## Public but not host API

Public for the CLI, the test suite, or a diagnostic overlay, and outside the shape this reference documents. They stay source-compatible under semver like everything else, but nothing here should carry playback logic:

- **Test hooks**: `setForceSoftwarePathForTesting`, `setSourceThrottleKbpsForTesting`, `setSoftwareBackgroundAudioOnlyForTesting`, `softwareVideoFramesEnqueuedForTesting`, `setLargeAllocationCensusEnabled`.
- **`playbackBackend`**: the internal rendering backend, exposed read-only for overlays. Hosts must not branch on it; `videoRoute` is the surface that answers the same question honestly.
- **`HLSVideoEngine`** and its `DiagnosticStats`: the loopback session's own machinery, public because `aetherctl` drives it directly.
- **`DiscInspector` / `DiscInspection`**, `DoviRpuConverter` and its probe, `AudioTapProbe`, `SoftwareDecodeProbeResult`, `A53SEIParser`: repro and inspection surfaces behind `aetherctl` subcommands.
- **`HLSLiveIngestReader`'s internals** (`terminalError`, `upstreamTargetDuration`, `observedLiveCadenceSeconds`, `companionAudioReader`): fixture and diagnostic reads.
- **`SubtitleChannel`**: the primary / secondary selector on the engine's internal subtitle routing. No public signature takes one; a host picks the channel by calling the primary or the secondary method.
