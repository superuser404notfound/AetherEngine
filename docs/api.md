# Public API reference

This file lists every public surface a host app uses, and the contracts that require the host to act. The README shows the shape of an integration. Use this file to check an integration against.

Every public symbol is part of the [stability contract](installation.md#stability-and-versioning). `Tests/AetherEngineTests/PublicAPIDocumentationTests.swift` fails the build when a host-facing public declaration is named nowhere in the documentation, so this file cannot silently fall behind the code.

The host contracts come first, because a mistake there costs a shipped app a bug report rather than a compile error. A working example of the live contracts, compiled against the engine: [`Examples/LiveHost/LiveChannelHost.swift`](../Examples/LiveHost/LiveChannelHost.swift).

- [The contracts a host has to answer](#the-contracts-a-host-has-to-answer)
- [Constructing and binding](#constructing-and-binding)
- [Loading](#loading)
- [Transport](#transport)
- [Time](#time)
- [What the session is doing](#what-the-session-is-doing)
- [Audio tracks](#audio-tracks)
- [Subtitles](#subtitles)
- [Live and DVR](#live-and-dvr)
- [Recording a live stream](#recording-a-live-stream)
- [Picture, layers and PiP](#picture-layers-and-pip)
- [Now Playing and the audio session](#now-playing-and-the-audio-session)
- [Stills and thumbnails](#stills-and-thumbnails)
- [Certificate trust](#certificate-trust)
- [Diagnostics](#diagnostics)
- [Optional components](#optional-components)
- [LoadOptions](#loadoptions)
- [Value types](#value-types)
- [Public but not host API](#public-but-not-host-api)

## The contracts a host has to answer

| Contract | What the host does |
| --- | --- |
| [How a load ends](#how-a-load-ends) | Let `CancellationError` through, count a failure once, classify on `$errorInfo` |
| [`.ended` is terminal](#ended-is-terminal) | Call `load(...)` again to replay |
| [Live: the retune request](#live-the-retune-request) | Subscribe to `liveSourceReset`, retry with `retryLiveSourceRecovery()` |
| [Live: exhausted verified replay](#live-exhausted-verified-replay) | With `hostRetriesExhaustedLiveReplay`, retry on `liveSourceReplayExhausted` |
| [Live: a resume that had to move](#live-a-resume-that-had-to-move) | Tell the viewer when `liveResumeClamped` fires |
| [The system asks for captions](#the-system-asks-for-captions) | Select a matching track on `systemCaptionRequest` |
| [The engine moves a refused session onto the software path](#the-engine-moves-a-refused-session-onto-the-software-path) | Observe `softwarePathEscalations`, or opt out |
| [The audio tap ends with its session](#the-audio-tap-ends-with-its-session) | Re-install the tap when its stream ends |
| [Correcting a `LoadOption` without restarting the item](#correcting-a-loadoption-without-restarting-the-item) | Use `reloadAtCurrentPosition(applying:)`, handle its refusals |
| [Rotating a credential without a rebuild](#rotating-a-credential-without-a-rebuild) | Call `updateRequestHeaders(_:)`, watch `sourceAuthorizationRefused` |
| [Overriding the decode path](#overriding-the-decode-path) | Set `preferredDecodePath = .software` when a native session shows nothing |
| [Reading whether the audio was delivered](#reading-whether-the-audio-was-delivered) | Demote on `.droppedNoPipeline` |
| [What must be set before `load()`](#what-must-be-set-before-load) | Set those fields first |
| [Isolation, and what runs off the main actor](#isolation-and-what-runs-off-the-main-actor) | Call the blocking and threaded APIs from the right place |
| [One FFmpeg, and it has to be the engine's](#one-ffmpeg-and-it-has-to-be-the-engines) | Keep a second FFmpeg from taking the engine's symbols |
| [Holding a second player beside the engine](#holding-a-second-player-beside-the-engine) | Link the engine into its own dynamic framework when the other FFmpeg is static |
| [Running several engines at once](#running-several-engines-at-once) | Use `.secondary` roles, `logTag`, and always `stop()` |

### How a load ends

**What the host must do:** let `CancellationError` pass without treating it as a failure, count a failure once (it is reported twice), and classify failures on `$errorInfo`, never on the message text.

`load(...)` reports a failure twice on purpose: it throws, and `state` publishes `.error`. A host that counts both counts one failure as two.

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

#### `CancellationError` is not a playback failure

A superseded load throws `CancellationError` at its first checkpoint. So every channel zap, every next-episode call and every `stop()` during a load produces one. A host that retries, falls back to a second engine, or shows an error whenever "load threw" ends up reacting to its own navigation. Let `CancellationError` through untouched.

A load the ENGINE superseded does not throw it. The software-path rebuild (below) takes over the startup, and the `load()` the host is awaiting follows it, the way a #361 reroute keeps its wait (AE#629).

#### The message is a payload, `errorInfo` is the key

Log the message inside `.error` verbatim, but do not classify on it. It comes from two places:

- **The engine's own sentence.** It names the cause rather than the symptom, for example `"AVFoundation built no track for it within 45s and the source's carriage could not be identified"`, `"Live source unavailable"`, or the Dolby Vision hardware refusal. A host timeout that fires first replaces that sentence with its own.
- **Forwarded from the failure underneath.** On the native paths this is `AVPlayerItem.error.localizedDescription` verbatim. AVFoundation localizes it into the device language, and the `NSError` domain and code reach the host only as whatever the localized text happens to embed.

`$errorInfo` publishes a `PlaybackErrorInfo` beside the state:

- a `PlaybackErrorKind` naming what failed, in a form that survives a locale and a release
- the underlying `NSError` domain and code wherever a Foundation / AVFoundation failure is involved. A non-nil `underlyingDomain` also marks the messages whose text the OS has localized.

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

`errorInfo` is assigned before `state`, so a `$state` sink reads this failure's own info rather than the previous one's. It is cleared when the state moves away from `.error`, so the two cannot drift. Substring rules over the message put every non-English device into "other".

#### Which kind a failed source open publishes

- **Custom source probe failed:** `.customSourceProbeFailed`, with the probe error's `underlyingDomain` and `underlyingCode` when available. This is set before the terminal `.error` state is delivered, so a state observer can read the cause from `errorInfo` without parsing the message.
- **The engine's own live HLS ingest** (`HLSLiveIngestReader`, which a known HLS playlist URL on the live path loads through) is the exception. When the probe failed because the live playlist was refused, the load publishes the origin's answer the way an HTTP reader's failed open does: `.sourceRateLimited` (429/503/509) or `.sourceRefused` with the status in `underlyingCode`. It publishes `.liveSourceUnavailable` when the playlist could not be reached at all. So a host does not read a refusal as a stream it cannot play.
- **A plain-URL live open** (`isLive`) that the origin answers with a status fails the same way (#796; a 500 or 502 is asked once more first). So does one answered 2xx with a short text notice instead of media, the shape an Xtream panel at its connection cap uses: that publishes `.sourceRateLimited` with 509 (#925).
- **A TLS trust refusal** on either publishes `.sourceCertificateRejected`.
- **Only a live open that reaches nothing** publishes `.liveSourceUnavailable`. A transport failure there is first ridden out by the reconnect ladder. When the start gives up, the last connection's URL error domain and code are carried in `underlyingDomain` / `underlyingCode`. A transport failure does not establish that the media format is unsupported.

#### Origin refusals: `.sourceRefused` and `.sourceRateLimited`

Both kinds mean the origin answered the source request with an HTTP status instead of media. `underlyingCode` is that status.

- `.sourceRefused` is the origin's verdict on the resource or on itself: a 401/403 refusal (on a connection-capped IPTV panel this most often means "the slot is still held"), a 404, a 5xx.
- `.sourceRateLimited` is the same answer in the rate-limit shapes (429/503/509). It is split off because the recovery differs: the source is being metered, not lost. The same request is expected to work later, and a handoff to a second player meets the same meter (AE#377).

Both differ from `.sourceOpenFailed`, which is what a corrupt or unreadable source produces. Before `.sourceRefused` existed, a refusal and a corrupt file both arrived as "Invalid data found when processing input".

#### Certificate refusals: `.sourceCertificateRejected`

The transport was refused over certificate trust, so there was never a response to carry a status.

- `underlyingCode` is the `NSURLErrorDomain` code (-1200 through -1206).
- The message is the engine's own English sentence rather than the OS one, so a pasted report says the same thing on every device.
- It reaches a host from either path. On the FFmpeg path the reader types the failed open. On the native path the engine finds the URL error under AVFoundation's own error, which is where it sits and where nothing used to look.

Nothing about the media is wrong and no retry helps. A self-signed or private-CA origin needs a trust decision the host makes (AE#495, see [Certificate trust](#certificate-trust)).

#### HLS ingest failures

Outside live startup:

- `.hlsFormatUnsupported` identifies an HLS segment, encryption or demuxed-audio layout the ingest cannot handle.
- `.hlsIngestFailed` identifies invalid playlists, invalid responses, decryption failures or an ingest stall.

Both keep the underlying `HLSIngestError`; use the optional subreason below for diagnosis. These kinds describe the failure. They do not select a host's retry or fallback policy. Live startup keeps `.liveSourceUnavailable` except for HTTP and TLS refusals; the original cause remains available as described under [Diagnostics](#diagnostics).

`PlaybackErrorInfo.hlsDiagnosticReason` keeps an optional finite `HLSIngestDiagnosticReason` from an underlying `HLSIngestError`, including through Foundation error wrappers. `HLSIngestError.diagnosticReason` exposes the same value directly.

- These causes have distinct stable raw values: missing EXTM3U, missing TARGETDURATION, an empty segment list, invalid response/encoding, an `EXT-X-BYTERANGE` the playlist or the origin's answer cannot satisfy (`invalidByteRange`), unsupported encryption, and key/decryption failures.
- An unknown playlist or decryption message becomes a finite fallback, never a new token containing that message.
- This adds diagnostic detail without changing the failure's classification or recovery policy.
- Explicit `HLSIngestError` NSError codes match the historical Swift bridge; its error domain and human-readable descriptions are kept.
- The message is still arbitrary payload and is not safe structured telemetry.

#### FFmpeg error codes

`PlaybackErrorInfo.ffmpegErrorCode` optionally carries the original negative FFmpeg result from a demux failure, including through an NSError wrapper. It is separate from `underlyingCode`: the historical `AetherEngine.DemuxerError` case codes remain
0 (open), 1 (stream information), and 2 (read).

- A thrown demux NSError carries the same FFmpeg value under `AetherFFmpegErrorCode` in `userInfo`.
- Missing or invalid metadata leaves the optional field nil. The existing error domain, message and case code keep their meaning.
- An app that needs FFmpeg-specific diagnostics or compatibility decisions should use this field, not read a case code as an FFmpeg result.

#### Software live read failures

Software live source read failures, including an interrupted verified replay, report `liveSourceUnavailable` rather than `softwarePipelineFailed`. This is a source continuity failure, not evidence that the codec needs a different engine. Hosts choose retry timing through their existing live recovery policy. The software route's error remains available through `$errorInfo` and `.error`.

### `.ended` is terminal

**What the host must do:** to replay, call `load(...)` again.

`.ended` means the source played to completion, on any backend. It is not a pause at the last frame:

- `seek(to:)` is rejected with `SeekEvent.Rejection.noActiveSession`
- `play()` and `togglePlayPause()` do not revive the session

The engine keeps `.ended` terminal on purpose: a play press racing a host's end card must not silently restart a finished session (#63/#164).

A VOD **parked at its final frame** without having ended (scrubbed there, paused there) is a different case and does resume: `play()` rewinds to the start first.

The clock stops too, on both backends. `clock.currentTime` and `clock.sourceTime` settle on the last sample and stay there, so a progress bar bound to them holds at the end instead of walking past `duration`.

History:

- Through 6.28.0 the software path's master clock kept its rate past end of media, so a session left standing published a position that grew without bound (20.13 s on a 12.0 s source after 20 s, against 11.97 s from a native session on the same file). A host reading the clock after `.ended` on those builds sees that, not a drifting session (AE#374).
- The audio-only path (a source without a video track, decoded through FFmpeg) had the same defect through 7.27.0 and parks the same way since (AE#694).

### Live: the retune request

**What the host must do:** subscribe to `liveSourceReset` for every live session. When it fires, back off, then call `retryLiveSourceRecovery()`. If that returns `false`, run a bounded full-load policy. Keep one recovery in flight.

```swift
player.liveSourceReset            // PassthroughSubject<Void, Never>; subscribe per session
```

Left unsubscribed, a channel stops while the engine still reports a session, which from the outside looks like a slow one. The guard, written out: [`Examples/LiveHost/LiveChannelHost.swift`](../Examples/LiveHost/LiveChannelHost.swift).

**When it fires.** The event asks the host to negotiate the source again. It fires when:

- acquisition cannot continue under the engine's bounded recovery round, for example a changed track layout, or ordinary source loss that exhausts in-engine recovery
- the stalled consumer requests renewed source acquisition
- verified replay cannot reach new media (by default; see [exhausted verified replay](#live-exhausted-verified-replay) for the opt-in alternative)

**What the engine tries first.** An interrupted exact replay first tries the bounded in-engine source reopen, when there is a URL or a fresh-reader factory. The reopen:

- keeps the same cache, player item and bounded exact-packet history, so media already in the DVR window is not appended again, even when the viewer is behind live
- retires the failed connection before opening the replacement
- continues in place on a complete overlap; an ambiguous clock reset keeps ordinary discontinuity handling

Fresh-source recovery ends an active recording with `sourceReset` rather than silently splicing a new source into the old file.

**How to answer.** After your own backoff, first try `retryLiveSourceRecovery()`. A previously productive native live session can renew its source while keeping its DVR timeline, even before any replay has been detected. A `false` return means fresh negotiation is needed (for example a changed track layout, or a custom reader without a reopen factory); use a bounded full-load policy for that case. Do not turn ordinary source loss into a decoder compatibility failure just because an origin stays unavailable.

**A same-URL retune is cheap.** The #168 carriage verdict (a master advertising HEVC while delivering MPEG-TS) is remembered per exact absolute URL for six hours, 32 entries. So the retune routes straight onto the live ingest instead of paying again for the doomed native mount and its watchdog grace.

A URL carrying a rotated per-session token misses that memory and pays the one-time discovery again on every retune. That matters where a first-frame budget is measured against the retune too.

**Where the token rotates**, the host has a key the memory cannot have: the channel. `$videoRoute` publishes the reroute as it happens (`.remoteBypass` becomes `.loopback`). A host can record that verdict against its own channel id and open the channel's next session on the ingest directly, in one of two ways:

- with `nativeRemoteHLS: false` (from 6.24.0 an `m3u8` on the raw live path is routed onto the ingest reader, at the cost of one failed open)
- by handing `HLSLiveIngestReader` to `.custom(_:formatHint: "mpegts")` itself, which costs nothing at all

Either skips the native mount and up to 4 s of carriage-watchdog grace per retune, whatever the URL looks like that time.

### Live: exhausted verified replay

**What the host must do:** only if it sets `LoadOptions.hostRetriesExhaustedLiveReplay = true`, subscribe to `liveSourceReplayExhausted` and retry with `retryLiveSourceRecovery()` under its own backoff.

`liveSourceReplayExhausted` is a per-session subject for native HLS recovery that cannot reach new media after verifying previously admitted packets.

- It fires only for a session loaded with `LoadOptions.hostRetriesExhaustedLiveReplay = true`. Without it, the same exhaustion publishes `liveSourceReset`, so a host that only knows that event still retunes.
- Production parks while cached DVR media and replay history remain available.
- It is a source recovery event, not a codec failure, and not a requirement to show an error.

`retryLiveSourceRecovery() -> Bool` resumes source acquisition into the same cache and consumer item.

| Returns | When |
| --- | --- |
| `true` | the retained session accepts the request, or has a retry in flight |
| `false` | after stop/replacement, on unsupported routes, or when a changed track layout requires fresh negotiation |

- Concurrent calls coalesce.
- A stalled live producer can also be renewed this way: its reader is cancelled, and its pump must finish before history is transferred to a replacement.
- A new exhaustion publishes the subject again. Retry delays, cancellation and any overall limit belong to the host.
- Calling `load` or switching decoders instead discards this history and can replay the old broadcast.

Once a session has verified replay, later source-open exhaustion keeps this same retained recovery contract, even if an earlier reconnect produced new media. A changed track layout still uses `liveSourceReset` for fresh negotiation.

### Live: a resume that had to move

**What the host must do:** subscribe to `liveResumeClamped` and tell the viewer that the resume moved, or set `clampsLiveResumeToWindow = false` and own the decision.

```swift
player.liveResumeClamped          // PassthroughSubject<LiveResumeClamp, Never>; subscribe per session

public struct LiveResumeClamp {
    public let skippedSeconds: Double      // content the sliding window took while the session was paused
    public let behindLiveSeconds: Double   // where the resume landed; 0 for an edge snap
}
```

A session paused for longer than its own DVR depth has lost the position it was parked on: the sliding window evicted it. So the resume cannot start where the pause stopped. `clampsLiveResumeToWindow` (default on) moves it to the retained floor, or snaps to the edge on a live-only session. This event fires when it does.

It exists so a host can say so. Measured on the harness with a 30 s window and a 70 s pause: the playhead sat at 93881.2, the window slid to 93890.0...93920.0 underneath it, and the resume landed at 93895.0 without a word. A viewer who paused a match came back to it continuing somewhere else, with nothing on screen to say why. Neither field needs arithmetic against a window the host cannot see, so a host can say "you missed fourteen seconds" or "continuing twenty-five seconds behind live".

Hosts that own the decision set `LoadOptions.clampsLiveResumeToWindow = false` instead. They get a log line naming the deferral, and nothing fires.

### The system asks for captions

**What the host must do:** subscribe to `systemCaptionRequest` and answer by selecting its own matching track, if it wants the behaviour.

```swift
player.systemCaptionRequest       // PassthroughSubject<SystemCaptionRequest, Never>; subscribe per session
```

iOS 26's Automatic Subtitles (show when muted, on skip back, on a language mismatch) turn captions on with no read API behind them, so the selection is the only observable request. The engine deselects its own rendition, because one rendered in fullscreen draws a caption box over the host's overlay. It then forwards the request with the language the system named.

### The engine moves a refused session onto the software path

**What the host must do:** nothing, unless it runs its own fallback ladder. Then set `escalatesToSoftwarePath = false` and handle the failure as `.error`. Either way, `softwarePathEscalations` reports each rebuild.

```swift
player.softwarePathEscalations   // PassthroughSubject<SoftwarePathEscalationEvent, Never>; subscribe per session
options.escalatesToSoftwarePath  // default true; false declines the rebuild
```

**What it does.** When AVPlayer fails a native item with a verdict on the MEDIA (`CoreMediaErrorDomain`, typically `-19602` on a sample Apple's parser refuses), every native recovery would reload the same bytes. So instead of making the failure terminal, the engine spends one rebuild per session on `SoftwarePlaybackHost`, at the session's playhead (AE#561). libavcodec skips the frame Apple refused and plays on.

**Where it applies.**

- On the remote-HLS bypass, only for a finite playlist (AE#990). The rebuild is the same load with `.software`. A playlist of MPEG-TS segments plays from the seekable TS ingest; any other playlist mounts on AVPlayer once more and surfaces that failure.
- A live bypass keeps its own reroutes onto the live ingest.
- Not on a session already asked onto `.software`.
- Not for a URL-loading failure, which both paths would read through the same reader.
- Whether the software path can serve the source at all is the same check a `preferredDecodePath` correction runs.

**What the event carries.** It fires the moment the rebuild is taken. It carries the failure it absorbed in the `PlaybackErrorInfo` shape it would have surfaced in (`kind` `.nativeItemFailed`), plus the position, and whether a `load()` was still waiting.

- If the rebuild fails, the original failure is published as `.error` the usual way.
- If it succeeds, `videoRoute` moves to `.software`.
- A take during startup does not end the host's `load()` with a `CancellationError`. That call keeps waiting across the rebuild and returns the probe it already assembled.

**Opting out.** A host that re-plans a failing title with its own ladder (a transcode rung, a second player) sets `escalatesToSoftwarePath = false` and gets the failure as `.error`, as before 7.9.0. It is a tuning field, correctable through `reloadAtCurrentPosition(applying:)`.

**Live joins.** A live join takes the same rung when the source delivers video for the whole keyframe wait (15 s) and none of it is a picture the native route can open a segment on: no IDR, and no recovery point with `recovery_frame_cnt` 0. That is what a feed carrying only gradual intra refresh looks like (AE#627). Reopening would join the same bitstream, so the first join does not spend its reopen cycles on it.

- The absorbed failure carries the domain `AetherEngine.LiveJoin`.
- With `escalatesToSoftwarePath = false`, or when the rung is not on offer, the join ends as `liveSourceReset` at that point, as the reopen cycles would have ended it a minute later.
- A starvation after the session has produced segments keeps its reopens.

### The audio tap ends with its session

**What the host must do:** re-install the tap whenever its stream ends, and check `audioTapHasDeliverySource` right after installing.

`installAudioTap()` returns an `AsyncStream<AudioTapBuffer>` bound to the session it was installed against. It finishes on:

- `load()`
- `stop()`
- a **session-preserving reload**: an audio-track switch, a subtitle-track switch, a disc-title switch, `reloadAtCurrentPosition()`

Re-install on stream end to follow the new session (#356). This is on purpose: each install gets a fresh monotonic filter, so the new session's timeline starts clean instead of being stitched across a reload that resumes slightly behind the old position.

Read `audioTapHasDeliverySource` synchronously after installing. `false` means the stream will finish without yielding (no session, a video-only source, a backend with no tap path). That is the moment to fail loudly rather than await an empty stream.

**Dialogue only.** `installAudioTap(channels: .dialogue)` builds the mono output from the front-centre channel alone instead of every channel (#908). On a 5.1 or 7.1 mix that is where the dialogue sits, and a speech recognizer working on the downmix hears it under the score and effects of the other channels.

- The format does not change.
- A source with no centre (mono, stereo, 2.1, a discrete layout) is delivered as the downmix. Every `AudioTapBuffer` says which it carries in `channels`, so a host can tell an isolated centre from the fallback.
- A source that states only a channel count is read in the default order for that count.
- Dialogue that lives only in Atmos objects is not in the centre channel and is missed either way.

### Correcting a `LoadOption` without restarting the item

**What the host must do:** to change an option on a playing session, call `reloadAtCurrentPosition(applying:)`, not a fresh `load()`. Handle its two refusals, and do not use it to change `autoplay`.

`reloadAtCurrentPosition(applying:)` is the session-preserving rebuild, with the options it replays taken from the host rather than from the session (#460).

```swift
try await player.reloadAtCurrentPosition { $0.httpHeaders["Authorization"] = "Bearer \(fresh)" }
```

The closure is seeded with the options the session is CURRENTLY running on. That is not always what was passed to `load`, because the engine rewrites its own routing fields on a reroute. Change what needs correcting and leave the rest alone. The change is installed into the session before the rebuild, so every internal reopen that follows (an audio switch, a background reload) replays the correction instead of going back to the load-time value.

**Why not a fresh `load()`.** `load` cannot reach `subtitleSessionCarryover` or `isLiveRejoin`, both settable only from inside the engine. So a fresh load wipes, and re-derives by auto-selection:

- the id-exact external-subtitle registry
- every mid-session `addExternalSubtitleTrack`
- the host's explicit subtitle authority (subtitles explicitly OFF included)
- the live rejoin contract

This reload keeps all of it, at the same teardown cost the plain `reloadAtCurrentPosition()` already pays.

#### What the call returns

The call hands back a `SessionOptionCorrectionOutcome`:

- `applied`: the fields the correction applied
- `sessionOwned`: the fields the session owns and kept
- `rebuilt`: whether the session was torn down at all

A field the session owns costs no rebuild (AE#464 round 4): there is nothing for a rebuild to carry. Two empty lists with `rebuilt` true means the session was already running on that correction, and that one does rebuild.

```swift
let outcome = try await player.reloadAtCurrentPosition { $0.autoplay = false }
// outcome.applied == [], outcome.sessionOwned == ["autoplay"], outcome.rebuilt == false
```

The result is `@discardableResult`, so a host that only needs the refusals can ignore it.

**`autoplay` cannot be changed this way.** The rebuild comes back in the transport state the session is actually in (AE#464 round 2), so a correction that sets `autoplay` is overwritten rather than refused. Use `play()` / `pause()` around the correction if the rebuild should change the transport.

- The log says so: the field is not named in `#460: reload applying ...`; it gets its own `#460: autoplay not applied, the session owns it` line (AE#464 round 3).
- It costs no teardown and is returned as `sessionOwned` (round 4). Before, the teardown it spent was a visible restart bought for a field the rebuild decides for itself.
- The one rebuild that DOES apply the flag is the resume after a background teardown (#357), which has no session transport left to preserve. There the field is named as applied.

#### Refusals

Both refusals are raised BEFORE any teardown, so a refused correction leaves the session playing. Both are all-or-nothing: a correction refused for one field installs none of it.

| Thrown | When |
| --- | --- |
| `AetherEngineError.loadIdentityNotCorrectable(fields:)` | the closure changed `isLive`, `audioOnly`, `nativeRemoteHLS` or `sequentialOrigin`. These name the session rather than tune it: each opens the source on a different pipeline, and the engine writes the last two itself. Changing one is a different item, not a correction. Load the source again. Changing `sourceDiagnosticsContext` also throws this, because it identifies the original load and its requests; pass a different context to a fresh `load()`. A tuning correction that keeps the context is allowed. |
| `AetherEngineError.sessionNotReloadable(_:)` | there is no session, or the source is a custom `IOReader` that reported itself non-seekable and cannot be reopened at the current position. It carries a `SessionReloadRefusal` saying which: `.noActiveSession` / `.customSourceNotSeekable`, and from a correction also the cases in the rows below. |
| `AetherEngineError.sessionNotReloadable(.softwarePathCannotRepresentSource)` | the correction moves a native session onto the software path, and this source's only signal is IPT-PQ-c2 (Dolby Vision HEVC Profile 5, AV1 Profile 10.0). The software decoders hand that on as YCbCr, so the picture would render green/purple. |
| `AetherEngineError.sessionNotReloadable(.dualLayerRouteNeedsFreshLoad)` | the correction changes `preferDualLayerDolbyVision` (or `dolbyVisionHandling` or `dualLayerRoute` while the preference is on) on a custom `IOReader` Profile 7 session. The in-place rebuild keeps the route the session was loaded with, so the change could not take effect. Call `load()` again with the new option. |
| `AetherEngineError.sessionNotReloadable(.upscaleRouteNeedsFreshLoad)` | the correction turns `upscalesLowResolutionVideo` on for a custom `IOReader` session. The route is decided by `load()`, which the in-place rebuild does not re-run. Call `load()` again with the new option. Turning it off is honoured in place: the rebuilt session stays on the software path, delivers frames as decoded and clears `$activeUpscale`. URL sources re-run `load()` and are not refused. |
| `AetherEngineError.sessionNotReloadable(.demuxedAudioLiveIsNativeOnly)` | the correction moves a demuxed-audio live session onto the software path, where the side-audio merge does not exist, so it would play silent. |

`SessionReloadRefusal` is a public enum. `.dualLayerRouteNeedsFreshLoad` and `.upscaleRouteNeedsFreshLoad` are new cases, so a host that switches over it exhaustively must handle them (a `default:` or a new `case`).

`sessionReloadRefusal` returns the same `SessionReloadRefusal` for either reload without attempting one, and nil when a rebuild would happen.

#### Where a correction lands

- **A URL source** rebuilds through the full `load`, so every field applies.
- **A custom `IOReader` source** rebuilds through the narrower reopen that keeps the retained reader. That path replays `loadedOptions` field by field instead of passing a struct through `load`:
  - The routing, probe-budget, live-join, deinterlace and subtitle-preparation fields all apply.
  - The four fields consumed by `load` itself (`preferredAudioLanguages`, `externalSubtitles`, `maxConcurrentSourceRequests`, `autoplay`) are installed and take effect at the next load. The custom reload carries the session's explicit audio pick and its own subtitle re-arm, so the two language lists have nothing to decide on that path anyway.

`preferredDecodePath` is in the first group. The reopen asks the same routing policy `load` asks, seeded with the session's current backend, so the correction lands on both source shapes. (It was briefly in neither group: the reopen picked its host from the backend the session was already on, so a decode-path correction on a custom source was accepted, logged and then ignored.)

This is safe because of the direction. `DecodePath` has no `.native`, so the only flip the reopen can make is native to software, and the software path is the general one. What the software path cannot REPRESENT is refused before any teardown (the `.softwarePathCannotRepresentSource` and `.demuxedAudioLiveIsNativeOnly` rows above). The guards that catch it inside `load` run after the routing decision, and reaching them on a correction would mean failing a session already torn down.

#### Errors

- Unlike `reloadAtCurrentPosition()`, which returns silently when there is nothing to rebuild, this one throws. A host correcting a session has to tell "corrected" from "did nothing" to decide whether to fall through to a fresh load.
- A rebuild that FAILS also throws, on both source shapes. (The custom-source branch used to publish its error and return as if the session had come back, so a correction could report success while the session sat in `.error`. It now throws what the rebuild threw, as the URL branch always has.)
- A rebuild superseded by a newer `load` or `stop` is not a failure and returns normally, because the newer load owns the session.

### Rotating a credential without a rebuild

**What the host must do:** when a bearer token is about to expire, call `updateRequestHeaders(_:)` with the new set. Subscribe to `sourceAuthorizationRefused` to renew as soon as the origin refuses one.

A media server that requires a bearer token on every request, with tokens that expire while a title plays, needs the next request to carry a new header and nothing else to change. `updateRequestHeaders(_:)` does that without the teardown `reloadAtCurrentPosition(applying:)` pays (AE#792):

```swift
let outcome = player.updateRequestHeaders(["Authorization": "Bearer \(fresh)"])
```

How it works:

- **The set replaces the session's headers**, the way `LoadOptions.httpHeaders` sets them at `load`. It is not merged.
- **The next request carries it.** The session's source readers read their headers per request from one store the session creates at `load`: the playback demuxer, the producer's reopens and revives, the I-frame and embedded-subtitle side readers, and the still extractor `makeFrameExtractor()` returns for the session's own source.
- **A request already in flight** finishes with the headers it was sent with.
- **A reconnect already backing off** after a refusal sends the new set on its next attempt. So a session stalled over a lapsed credential (`.stalled(reconnecting: true)`) recovers without a rebuild once the host supplies a current one. Renewing ahead of the expiry avoids the stall entirely.
- **Rebuilds keep it.** The set is also installed into the session's options, so every rebuild that replays them (an audio switch, a background return, `reloadAtCurrentPosition()`) opens with it.
- **Redirect scoping is unchanged:** a credential still does not follow a cross-origin redirect.
- The log names the header names it replaced, never their values.

The call returns a `RequestHeaderUpdateOutcome`:

| Outcome | When |
| --- | --- |
| `.appliedToLiveRequests` | every source request is made by the session's own readers: the `.loopback`, `.software` and FFmpeg `.audio` routes, and a load still opening. |
| `.installedForNextRebuild` | the requests are made by something that fixed its headers when the session was built: AVFoundation on `.remoteBypass` or an AVPlayer-hosted audio item, a custom `IOReader` the host built, a remote disc image, a DASH manifest. Call `reloadAtCurrentPosition()` if the set is needed now. |
| `.noActiveSession` | nothing is loaded; nothing was installed. |

#### When the credential lapses anyway

A 401 or 403 mid-session is not treated as a dropped connection.

1. The reader gives it a short ladder of its own: the refused request, then two retries, about 3 s. The first retry re-resolves an expired signed redirect through the source. (Before, twelve unproductive reconnects took about 80 s with the same refused header.)
2. The first refusal of a header set is published on `sourceAuthorizationRefused` (`AnyPublisher<Int, Never>`, the status). A host can renew right away instead of waiting on a timer derived from the token's expiry, which does not cover a token an admin revoked early.
3. A renewal that arrives while the reader is still retrying gives it a fresh ladder.
4. Once the reader has given up, the native loopback session waits up to 10 s for new headers. A renewal within that time rebuilds the producer at the playhead (up to three times per session). Otherwise the session ends with `PlaybackErrorKind.sourceRefused` and the status as `underlyingCode`, not `vodSourceFailed`.
5. The software path has no producer to rebuild. It reports the same `sourceRefused` when its reader's last answer was a refusal.

```swift
player.sourceAuthorizationRefused
    .sink { _ in
        Task { @MainActor in
            if let fresh = try? await auth.renewedHeaders() { player.updateRequestHeaders(fresh) }
        }
    }
    .store(in: &cancellables)
```

### Overriding the decode path

**What the host must do:** if a native session reaches `readyToPlay` but renders nothing, move it to the software path with `LoadOptions.preferredDecodePath = .software`.

`LoadOptions.preferredDecodePath` is the per-session escape onto `SoftwarePlaybackHost` (#461).

```swift
// at load
options.preferredDecodePath = .software
// or on a session that is already playing, through the #460 reload
try await player.reloadAtCurrentPosition { $0.preferredDecodePath = .software }
```

**Why it is needed.** `VTCapabilityProbe.canHardwareDecode` **fails open by design**. Four classes it cannot classify keep the native path: no extradata, Annex-B extradata, in-band parameter sets, and a format-description build failure. That is the right default, and occasionally wrong. When VideoToolbox then cannot build a decoder for what arrives, the item reaches `readyToPlay` and renders nothing. In-band parameter sets (`hev1` / `avc1` with an empty config record) are the class where the deciding evidence really is not present at load time.

A live H.264 / HEVC load never reaches that gate: for those codecs the capability check is VOD-only, so a live session keeps the native path with no classification step. Live AV1 is judged by profile like VOD (High and Professional go software).

**Detecting the symptom** is the host's job and is not hard: compare `AVPlayerItemVideoOutput.hasNewPixelBuffer` against `softwareHostFramesEnqueued`, both already exposed. Before this option the only levers were:

- `setForceSoftwarePathForTesting`, which is process-global and so drags every concurrent session on a shared engine
- presenting a custom `IOReader` whose seek fails, which reaches the software host by costing the source its seeks, its mid-session audio switch, its title switch and `reloadAtCurrentPosition` itself

What to know:

- **One-way.** `DecodePath` has `.automatic` and `.software`, and no `.native`. Every route the engine sends to software it sends there because the native path cannot serve it (AV1 without hardware decode, VP9, a forward-only source, MVC carriage). Forcing native past those buys a black screen. A host's evidence is only ever "this native session is not decoding".
- **It does not override what the software path cannot represent.** A source whose only signal is IPT-PQ-c2 (Dolby Vision HEVC Profile 5, AV1 Profile 10.0) still fails the load with `dolbyVisionUnplayableOnSoftwarePath` rather than decoding as YCbCr and rendering green/purple. A demuxed-audio live source still fails rather than playing silent. An override says which host serves the session, not what that host can do.
- **`nativeRemoteHLS` is a different route, with one exception.** AVPlayer plays the remote playlist and the engine demuxes and decodes nothing, so there is usually no decode path to prefer. The engine logs that it ignored the preference rather than letting it look applied. The exception (AE#990) is a finite, unencrypted playlist of MPEG-TS segments: with `.software` it moves onto the seekable TS ingest the AE#268 HEVC route uses and decodes in software, whatever the codec, with `startPosition` and seeks served by the ingest. That covers a playlist reached through the AE#154 reroute of a `.url` load too. fMP4, live and encrypted playlists keep the bypass.
- **An audio-only session honours it too.** With `audioOnly`, `.software` sends a codec AVPlayer could play (FLAC, ALAC, AAC, MP3, LPCM...) to the FFmpeg host (`AudioPlaybackHost`) instead of `AudioAVPlayerHost`. The audio dispatch line in the log says the host asked for it. The trade is the system Now-Playing session: as for every audio-only source the FFmpeg host plays, `audioNowPlayingSession` is nil there. A host that registers its transport commands on that session drives Now Playing through `MPNowPlayingInfoCenter.default()` and `MPRemoteCommandCenter.shared()` itself for such a session.
- **A mid-play correction lands on both source shapes**, URL and custom `IOReader` alike, and moves the session at its own playhead without a restart. On a source the software path cannot represent, the correction is refused before any teardown with `SessionReloadRefusal` `.softwarePathCannotRepresentSource` or `.demuxedAudioLiveIsNativeOnly`, so the session keeps playing. Measured on the Dolby browser test kit, which carries the discriminator: the Profile 5 cut of a clip is refused and left playing on VideoToolbox, while the Profile 8.1 cut of the SAME material and grading is honoured and rebuilds on `libavcodec HEVC (SW)`.

### Reading whether the audio was delivered

**What the host must do:** a fallback ladder demotes on `$audioDelivery == .droppedNoPipeline`. Show `$activeAudioDecoder` to people, but never classify on it.

`$audioDelivery` publishes an `AudioDelivery`: how this session's audio reaches the renderer, as a typed fact (AE#462).

| Value | Meaning |
| --- | --- |
| `.none` | no session |
| `.noAudioInSource` | the source carries no audio track |
| `.streamCopy` | the source bitstream reaches the renderer unchanged: muxed into fMP4 (Atmos, DTS-HD and everything else as authored), or, on the software host under `objectAudioRendering`, an E-AC-3 JOC track handed to the sample-buffer renderer compressed |
| `.bridged` | decoded and re-encoded for the fMP4 pipeline. Either by the channel bridge to FLAC or E-AC-3 (lossless for the bed channels, object metadata lost in the PCM intermediate), or, under `objectAudioRendering` in a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default), rendered with its objects and heights into a speaker bed and encoded as APAC (lossy), on the loopback route and on the software host alike |
| `.decoded` | libavcodec decodes to PCM and the engine renders it (the software path without an object-audio route, the FFmpeg audio-only host) |
| `.droppedNoPipeline` | the source HAS audio and none of it could be delivered. The session plays video-only and silently. Causes: no decoder for it in this build; the bridge could not be built or could not write its header; the probe left its parameters empty so no stream could be picked; or (live only) the bridge was built and its decoder produced nothing, after which the engine rebuilds the session without the track (AE#641) |
| `.playerManaged` | AVFoundation owns the audio (the remote-HLS bypass, the native audio-only host). The engine has no pipeline of its own to classify and does not answer on AVFoundation's behalf |

```swift
player.$audioDelivery
    .filter { $0 == .droppedNoPipeline }
    .sink { _ in ladder.demote(reason: .silentVideo) }
```

**`.droppedNoPipeline` is the value a fallback ladder acts on**, the same way it demotes on `PlaybackErrorKind.audioBridgeProducedNoOutput`. The two are the same user outcome from opposite ends:

- `audioBridgeProducedNoOutput` fails loudly when a VOD bridge WAS built and then decoded nothing. Since AE#641 that includes the FLAC route, which used to play silently while reporting `.bridged`.
- `.droppedNoPipeline` reports a bridge that could never be built at all.
- A live session whose bridge decodes nothing arrives at `.droppedNoPipeline` too, not at the error. Its video is playable and a live source has no position to hand to a second player, so the engine rebuilds it video-only by itself and the value changes from `.bridged` to `.droppedNoPipeline` (AE#641).

Neither ends a ladder: re-serving the source with audio the pipeline can carry (a server-side transcode, a second player that decodes it itself) plays it.

It is not a `PlaybackErrorKind` because that taxonomy is terminal: `state` moves to `.error`, and `errorInfo` is cleared when the state moves away. Video-only playback is neither terminal nor an error for every host.

**`$activeAudioDecoder`** is the same fact for a human (`"Stream-copy (EAC3+JOC Atmos)"`, `"TrueHD → FLAC bridge"`, `"libavcodec AC3 → CoreAudio"`), and stays the right thing to show in a stats overlay. Do not classify on it: it cannot tell a source with no audio from a source whose audio was dropped. Before AE#462 it was also wrong on the software path, where it was built from the probe's track list and so named a decoder that had refused to open. Both publishers are now written from the pipeline that serves the session, so `.droppedNoPipeline` and a nil label arrive together.

### What must be set before `load()`

**What the host must do:** set these before calling `load()`. A later change does not reach the running session.

| Set before the load | Why |
| --- | --- |
| `ownsVideoNowPlayingSession` | read when the native host is created; a host preserved across a native to native reload keeps what it was created with |
| `ownsSoftwareNowPlaying`, `remoteSkipInterval` | read when the software host is built |
| `LoadOptions.preferredAudioLanguages` | the picked audio track is muxed at the first frame; a later `selectAudioTrack` costs a reload |
| `LoadOptions.prepareNativeSubtitles`, `externalSubtitles` | the native renditions are declared in the init segment |
| `LoadOptions.panelIsInHDRMode`, `panelPresentsDolbyVision`, `matchContentEnabled` | the display-criteria handshake and the format clamp both run synchronously inside `load` |
| `pictureInPictureActive` | governs the background teardown decision at the moment it happens |
| `logTag` | entered into the shared-output book when the load joins it, so a tag set later is missing from those log lines until the next `load()` |
| `rendererAudioSessionActivationEnabled` | read by software and audio-renderer loads; see [Host-managed renderer audio activation](#host-managed-renderer-audio-activation) |

### Isolation, and what runs off the main actor

**What the host must do:** drive the engine from the main actor. Call `probe` from a background queue, and make the frame-time observers and log handlers thread-safe.

`AetherEngine` is `@MainActor`. Every method and property in this reference is main-actor isolated unless it says otherwise, so a host drives it from the main actor and gets its published values there.

Four exceptions:

- **`AetherEngine.probe(...)` and `probeDetectingAtmos(...)` are `nonisolated` and synchronous**, and they open the source: a HEAD plus an initial range on a network URL, and a real decode pass for the Atmos variant. Call them from a detached task or a background queue. On the main actor they block it for as long as the origin takes, which on a slow one is seconds.
- **`presentationAxisMap` is `nonisolated`**, so a compositor pairing samples off the main actor can convert without hopping.
- **The two frame-time observers are `@Sendable` and are called on the pipeline's own threads**: the producer pump for `NativeVideoFrameTimeObserver` (in decode order), the renderer for `SoftwareVideoFrameTimeObserver` (in presentation order). They must not block and must not assume the main actor.
- **`EngineLog.handler` and `EngineLog.structuredHandler` fire from whatever thread emitted the line** (demuxer, producer, local server, audio bridge). Serialize onto your own queue before writing anywhere.

`player.clock` is a separate `@MainActor ObservableObject` on purpose. Its ~10 Hz ticks would otherwise fire `objectWillChange` on the engine and re-render every view observing it, which on tvOS rebuilds open `Menu` dropdowns mid-interaction. Time-driven UI observes `clock`; everything else observes the engine. `diagnostics` is split out for the same reason, at 1 Hz.

`FrameExtractor` is an `actor`, so its `thumbnail` / `preview` / `snapshot` / `prewarm` / `shutdown` are `await`ed from anywhere. The audio tap's `AsyncStream` can be consumed from any task too; only `installAudioTap()` itself is main-actor.

### One FFmpeg, and it has to be the engine's

**What the host must do:** make sure no second FFmpeg in the app serves the engine's FFmpeg calls. Check the `[FFmpeg]` line at `init`.

AetherEngine calls `avcodec_*`, `avformat_*`, `avutil_*` and `swr_*` as ordinary external symbols. Which binary serves them is decided by the host executable's link, not by the package graph, so a second FFmpeg anywhere in the app can take the calls. Two shapes do it, and neither announces itself:

- **A static FFmpeg pulled in with `-force_load`.** Its symbols become ordinary definitions inside the executable, and a definition in a `.o` beats a dylib for every other object in the same link.
- **A dependency that exports the same symbols.** libVLC is the common one. It is a reasonable thing to have beside AetherEngine, since the fallback ladder the API is built around invites exactly that pairing. CocoaPods sorts a pod ahead of a vendored framework, so libVLC's libavcodec wins by default.

The engine then runs against headers it was never compiled against: struct layouts, codec ids and the encoder set are whatever the other build decided. The symptoms do not look like a linking problem. They look like an engine defect, specifically in whatever the other build happens to be missing. For example, AE#396 was reported as an audio-bridge defect on five fixtures and two devices, and was a second FFmpeg one major version behind. The engine's only trace was `flac bridge encoder absent from this FFmpeg build`, a true sentence about a build that was not the engine's. That line now names the libavcodec that answered.

Every session says which FFmpeg answered, once, at `init`:

```
[FFmpeg] libavcodec 62.28.102, libavformat 62.6.100, libavutil 60.13.100, libswresample 6.0.100
```

When a major version does not match the headers the engine compiled against, that line becomes an `ERROR:` naming the mismatch, the likely cause, and the two commands that show it:

```
$ nm -m <executable> | grep _avcodec_find_encoder     # which binary wins
(__TEXT,__text) external _avcodec_find_encoder        #   a definition in the executable itself
(undefined) external _avcodec_find_encoder (from MobileVLCKit)   #   or someone else's dylib

$ otool -L <executable>                               # and in what order
```

The fix is the host's, because nothing inside a library can reach it: link AetherEngine's frameworks ahead of the other FFmpeg, or drop the second copy. The majors the engine expects are the ones FFmpegBuild's headers declare for the pinned version. The line above prints both sides, so there is nothing to look up.

### Holding a second player beside the engine

**What the host must do:** nothing if the other player's FFmpeg is dynamic. If it is static, link the engine into a dynamic framework of your own instead of into the app.

A ladder that keeps KSPlayer, mpv or MobileVLCKit for the formats it already covers is a normal shape. Since FFmpegBuild 3.0.0 the engine's FFmpeg is named so it can live beside another:

- The frameworks ship as `AetherLibavcodec`, `AetherLibavformat`, `AetherLibavutil`, `AetherLibswresample`, `AetherLibswscale`, `AetherLibavfilter`, `AetherLibdav1d`, `AetherLibzimg` and `AetherLibzvbi`.
- The install names follow (`@rpath/AetherLibavcodec.framework/AetherLibavcodec`).

Before the prefix, a package graph holding both did not resolve: SwiftPM target names are unique across the whole dependency graph, and two framework bundles cannot share one path in `App.app/Frameworks/`.

**If the other FFmpeg is a set of dynamic frameworks**, that is the whole fix. The two-level namespace records per reference which dylib a symbol came from. So the engine reaches its libavcodec and the other player reaches its own, in one process, with no link order to win.

**If the other FFmpeg is static**, the rename is not enough, and no rename could be: `_avcodec_open2` is `_avcodec_open2` in every FFmpeg. Its symbols become definitions inside the executable, and the engine, statically linked beside them, binds to those. The fix is to stop linking the engine into the executable:

1. Add a dynamic framework target to your project, say `PlayerEngineKit`, and link the `AetherEngine` product into that target instead of into the app.
2. Embed the `AetherLib*` frameworks in the app as usual (Xcode does this for you when the package is linked).
3. Have the app talk only to `PlayerEngineKit`.

The engine's `_av*` references are then resolved when that framework links, against `AetherLibavcodec.framework`, and recorded as coming from it. Whatever the executable defines for its own player no longer takes part. This is the same construction that lets MobileVLCKit's FFmpeg and FFmpegKit coexist today.

Run these two commands once to confirm it, rather than trusting the arrangement:

```
$ nm -m PlayerEngineKit.framework/PlayerEngineKit | grep _avcodec_open2
(undefined) external _avcodec_open2 (from AetherLibavcodec)   # right: it comes from ours

$ otool -L PlayerEngineKit.framework/PlayerEngineKit | grep -i libavcodec
@rpath/AetherLibavcodec.framework/AetherLibavcodec
```

The engine also reports it: the `[FFmpeg] libavcodec …` line at `init` shows the versions that actually answered, not the ones it was built against, so a wrong binding shows up in the log before it shows up as a defect.

### Running several engines at once

**What the host must do:** load one engine as `.primary` and the others as `.secondary`, set `logTag` on each before `load()`, switch the audible one with `volume`, and `stop()` every engine before letting go of it.

Each `AetherEngine` has its own loopback server, caches and lifecycle, so two or more can play side by side (a multiview grid). What they share is the process: the audio session, its channel preference, and the panel's display criteria. The engine keeps one book of who is still playing (`SharedOutputCoordinator`, internal) and acts on it:

- **Audio session.** It is released only by the last engine to stop, and only if some engine in that round had `deactivatesAudioSessionOnStop`.
- **Channel count.** The preferred output channel count is the widest source among the playing engines, so a muted stereo tile cannot downmix a 5.1 one.
- **Display criteria.** A reset waits until the last engine stops, including the resets a load runs to clear stale criteria. An engine that loads again as `.primary` in the meantime cancels its own pending reset; one that loads again as `.secondary` keeps it.
- **Disk.** The allowance for seek and timeshift history (a quarter of the free space, at most 2 GiB per session) is taken from what the other running engines have not already claimed, so side-by-side engines cannot claim the same space twice. A claim ends with the session.
- **Stop every engine before you let go of it.** An engine counts as playing from `load()` until `stop()`, whatever its state, `.error` and `.ended` included. An engine kept for reuse must be stopped when its tile ends or fails, or the last real stop will not release the session. An engine released without `stop()` is noticed and dropped the next time another engine asks, but until then it counts as playing.

Load one engine as `.primary` and the others with `LoadOptions(sharedOutputRole: .secondary)`. Set `logTag` on each (before `load()`), and control what is audible with `volume`. Every engine keeps decoding its audio, so switching the audible one is a volume change, not a reload.

## Constructing and binding

```swift
let player = try AetherEngine()
```

| Symbol | What it is |
| --- | --- |
| `AetherEngine()` | `public init() throws`, `@MainActor`, an `ObservableObject`. Use one engine per playback surface. Several engines against one origin cost that origin one long-lived request each (see `maxConcurrentSourceRequests`). The audio-session category is validated off-main at load and never activated here, because AVKit activates per playback and that is what lets tvOS negotiate the HDMI route (#24). |
| `AetherPlayerSurface(engine:)` | SwiftUI view. Drop it in the tree; it mounts and binds an `AetherPlayerView` for you. |
| `AetherPlayerView` | UIKit / AppKit view (`PlatformBaseView` is `UIView` or `NSView`). Hosts the engine's layer. |
| `bind(view:)` | Attach a view. The engine swaps the hosted `CALayer` per session (`AVPlayerLayer` or `AVSampleBufferDisplayLayer`), so a bound host needs no per-route branch. The layer is shown on the most recently bound view that is still alive. An earlier view stays a fallback until it is unbound or released, which keeps the picture when a surface is remounted by identity on the same engine (AE#536). |
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
| `DiscDirectoryReader`, `HTTPDiscDirectoryReader` | A Blu-ray ripped as a `BDMV` folder, or a DVD-Video as a `VIDEO_TS` folder, for `.custom(reader)`. `discFiles` lists the files (root-relative path and size), `openDiscFile(_:)` opens one, `preferredPlaylist` optionally names the title's `.mpls`. `HTTPDiscDirectoryReader(files:preferredPlaylist:httpHeaders:)` serves each `File` (path, size, url) from its own `Range` origin. See [Blu-ray folders](formats.md#disc-dvd--blu-ray-iso). |
| `reloadAtCurrentPosition()` | `async throws`. Background reopen at the current position, keeping the options. See [below](#reloading-at-the-current-position). |
| `prepareForItemReplacement()` | One-shot. Keeps the current native `AVPlayerItem` attached until the next `load()` replaces it atomically. For a host that mounts the engine's own player layer and would otherwise show a black layer across the nil-item gap of a foreground episode or playlist change. Consumed by the next `load()`, cancelled by `stop()`, no effect when the outgoing session is not native. PiP hosts do not need it: an active PiP window already forces the handover (AE#158). |
| `stop(resetDisplayCriteria:finalTeardown:)` | Ends the session: `state` becomes `.idle`, `startupProgress` becomes nil. `resetDisplayCriteria: false` keeps the panel in its current mode across an item handoff. |
| `AetherEngine.externalSubtitleTrackIDBase` | `100_000`. Synthetic ids of external subtitle tracks start here. |

`IOReader` is the custom-source protocol. `read`, `seek` and `close` are required. `cancel()`, `makeIndependentReader()` and `discImageProbeEnabled` have defaults; implementing them unlocks, respectively, teardown unblocking, embedded subtitles plus scrub stills, and ISO/UDF probing. Calls arrive on the engine's demux thread, each inside an autorelease pool the engine opens, so a reader built on `FileHandle` or `NSData` does not strand one autoreleased object per read for the length of a session. Full contract in [formats.md](formats.md).

### Reloading at the current position

`reloadAtCurrentPosition()` is session-preserving:

- It finishes an installed audio tap and keeps the native host where it can.
- It keeps the session's TRANSPORT rather than replaying `autoplay`. A session that was playing comes back playing, and one that was paused comes back paused, whatever the mount was given (AE#464 round 2).
- A `play()` or `pause()` that arrives while it runs is the newer word and decides how it comes back.
- The one exception is the resume after a background teardown, which has no transport left to read and is the host's call. There the mount flag still decides.

To change options at the same time, use [`reloadAtCurrentPosition(applying:)`](#correcting-a-loadoption-without-restarting-the-item).

### Cancelling a load

Cancelling the Task that awaits `load()` ends the load at once: it throws `CancellationError` instead of running its connect, open, retry and probe budgets to the end. (An unreachable live origin used to hold it for about 19 s.)

**What is aborted.** A blocked network read, `avformat_open_input` / `find_stream_info`, a size probe, an `HLSLiveIngestReader` retry and a custom reader's blocking `read` are all aborted, typically within tens of milliseconds. The one stretch it cannot cut short is the AE#532 Dolby Vision record audit, a detached read the load waits out before it throws.

**What is left.** The load is left the way a newer `load()` leaves it: the generation moves on, a custom reader is closed, and `state` becomes `.idle`. The native host and AVPlayer (#15), an AE#158 handover item and the panel mode are kept for the next load. Until that next `load()` or a `stop()`:

- the engine reads `.idle` but still holds the native host and its AVPlayer, with the item unloaded
- Now Playing may stay registered
- the audio session stays active
- with an AE#158 handover, the previous item can keep playing in PiP

A host that LEAVES on cancel (a dismissed view, say) must call `stop()`.

**Edge cases.**

- A cancellation only ends the load it belongs to. One that arrives after a newer `load()` or `stop()` took over, or after the load returned, changes nothing.
- A load that follows an engine rebuild (AE#629) ends that rebuild when cancelled.
- A `load()` called from a Task that is already cancelled throws before it touches the running session.
- A real failure that coincides with the cancellation is reported as `CancellationError` too, and `state` ends `.idle`, though a transient `.error` may have been published on the way.
- The same holds for a `reloadAtCurrentPosition()` of a URL source, which goes through `load()`.
- A load that returned before the cancellation is not undone. On the `nativeRemoteHLS` bypass `load()` returns at the mount, so a host leaving that startup calls `stop()`.
- Not cancelling changes nothing.

### Probing without playing

The probe functions read a source's metadata without starting a session. They are `nonisolated static` and synchronous, and they open the source, so call them off the main actor (see [Isolation](#isolation-and-what-runs-off-the-main-actor)).

| Symbol | Contract |
| --- | --- |
| `AetherEngine.probe(url:options:)` / `probe(source:options:)` | `nonisolated static throws -> SourceProbe`. Container/stream metadata read, no detail-pass decoder or session. `options` is read for `httpHeaders` and `skipsContainerAttachments` only. Optional trailing `limits` and `cancellation` control the whole operation (below). For a custom reader the caller keeps ownership, `close()` is not called, and the cursor is left unspecified. |
| `AetherEngine.probeDetectingAtmos(url:options:atmosDetection:)` | `probe` plus a bounded decode pass that settles E-AC-3 JOC for an Atmos badge. Strictly more expensive; never on the playback-start path. Decode-side failures degrade to "not confirmed" rather than throwing. Same as `probe(url:detecting: .atmos)`. |
| `AetherEngine.probeDolbyVisionEnhancementLayer(url:options:)` | `nonisolated static throws -> DolbyVisionEnhancementLayer?`. Synchronous and opens the source (call it from a detached task or a background queue). Single-track sources only: an enhancement layer on its own PID or track is not joined here. Reads the first RPU's `el_type` within the load path's own packet and byte ceilings, with no decode and no session, for a details screen or badge. `options` is read for `httpHeaders` only. Nil when the source is not Profile 7 or no RPU turns up in the budget. Not for the playback-start path. URL only and not bounded by the caller: for a custom source, a byte budget or cancellation, ask `probe(source:detecting: .dolbyVisionEnhancementLayer, limits:cancellation:)` instead. |
| `AetherEngine.probe(url:options:detecting:atmosDetection:hdr10PlusDetection:)` / `probe(source:...)` | `probe` plus the opt-in passes named in `ProbeDetail`, over one demuxer: `.atmos` (the bounded JOC decode above for E-AC-3; for TrueHD the first major sync, #1035), `.hdr10Plus` (structurally validated ST 2094-40 carriage) `.hdrVivid` (structurally validated CUVA HDR Vivid carriage in HEVC, scanned in the same packet pass as `.hdr10Plus`) and `.dolbyVisionEnhancementLayer` (FEL or MEL from the first RPU of a single-track Profile 7 source, same pass and budget, skipped without a read when `dvProfile` is not 7; #1030). All passes share the optional trailing `limits` and `cancellation`, so `probe(source: .custom(...))` answers the enhancement layer for a source behind an `IOReader`, under the caller's byte budget and stoppable. An empty set is the header probe with the same controls. The passes only ever SET `isAtmos` / `trueHDAtmos` / `carriesHDR10PlusMetadata` / `carriesHDRVividMetadata` / `dolbyVisionEnhancementLayer`; ordinary pass failures and per-pass caps leave the detail unconfirmed. A whole-probe stop throws, with no partial result. |
| `ProbeDetail` | `OptionSet`: `.atmos`, `.hdr10Plus`, `.hdrVivid`, `.dolbyVisionEnhancementLayer`. |
| `HDR10PlusDetectionOptions` | Bounds for the HDR10+ / HDR Vivid packet scan (one pass for both): `maxPackets` (32), `maxBytes` (16 MiB), `timeBudget` (2 s). The byte cap is the one that binds on UHD remuxes, where a single keyframe runs to several MB. It also bounds the total source read to four times `maxBytes` (at least 4 MiB), below the demuxer, so blocks of dropped streams count. |
| `ProbeLimits` | Optional whole-probe controls: `maxInputBytes` (8 MiB), `maxPackets` (128), `maxPacketBytes` (2 MiB), `timeBudget` (5 s). Values must be nonnegative; the time budget must be finite. |
| `ProbeCancellation` | Thread-safe, one-shot token: `init()`, `isCancelled`, `cancel()`. Available on every URL/custom header, detail and `probeDetectingAtmos` overload. Cancellation is a request, not a completion notification. |
| `ProbeError` | `invalidLimits`, `inputLimit`, `packetLimit`, `packetSizeLimit`, `timedOut`, `invalidReaderResult`, `unsupportedURL`, `sourceBusy`; `errorDescription` describes the stop. Explicit caller cancellation throws `CancellationError` instead. |

A successful probe with `carriesHDR10PlusMetadata == false`, or an unconfirmed Atmos track, means **not confirmed within the requested passes/budgets**, never proof of absence. `isAtmos` means E-AC-3 JOC only. TrueHD Atmos answers in `TrackInfo.trueHDAtmos` instead (#1035), a `TrueHDAtmosVerdict` that IS three-state: `.atmos`, `.noAtmos` (a major sync was read and declares no Atmos presentation) or `.unsettled` (no major sync of the track within `AtmosDetectionOptions`). It is nil when the pass did not run for the track. The pass needs no decoder and runs only for the targeted track (`AtmosDetectionOptions.targetTrackID`, else the default audio track); a profile the header probe already named Atmos costs no read. `.atmos` also sets `profile` to "Dolby TrueHD + Dolby Atmos". Under `ProbeLimits`, the byte budget covers this pass as well: a TrueHD track that starts beyond `maxInputBytes` stops the probe with `ProbeError.inputLimit` rather than answering `.noAtmos`, so a host that wants that answer for a late track sizes the budget to reach it. These are source-metadata answers, not evidence of HDMI output or display mode. Container-declared Dolby Vision stays primary even when HDR10+ is also confirmed.

### Whole-probe limits and cancellation

**Defaults.** Existing calls keep their open policy: `limits: nil, cancellation: nil`.

- Passing `limits: .init()` starts a monotonic deadline before opening the source, shares the input budget across disc recognition, container open, `avformat_find_stream_info`, the HDR scan, the Atmos rewind and decode, and disables speculative HTTP prefetch.
- Passing only `cancellation` enables interruption without installing numeric limits.
- The open keeps the ordinary playback analysis budget, with `probesize` clamped to `maxInputBytes`, so a controlled probe does not answer from a shallower read than the same call without limits.
- Controlled URL probes support files, HTTP and HTTPS. Other transports can use an independent `.custom` reader.

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

Cancelling an awaiting Swift task alone does not cancel synchronous probing; wire the handler as above. Do not share a custom reader's cursor with playback. The caller still owns and closes it.

**Threads.** `probe` blocks its thread until the native call returns. A detached task is not a background thread: it runs on the Swift cooperative pool, one thread per core. A host that probes several sources at once is better served by a GCD queue or a `TaskExecutor` of its own. The engine's own detached work goes through one (see Architecture, "Blocking work and the cooperative pool").

#### What the limits count

- **`maxInputBytes`** counts cumulative bytes the underlying reader delivers to the probe, including bytes read again after a seek. Reads are clipped to the remaining allowance **before** calling the reader. It is **not a network/wire cap**: HTTP headers, transport buffers, requests used to resolve length, and reader-internal prefetch can consume more.
- **HTTP range sizes.** An HTTP probe reads in byte ranges that start at 64 KiB and double while each one continues the last in full, up to 4 MiB. A seek starts over at 64 KiB, and no range is longer than the input allowance still left (AE#927). A grown range gets a request budget in proportion to its size, so it needs the same throughput a 64 KiB range needs in 2 s; the 2 s idle timeout still ends a stalled one. The 50 MiB playback analysis depth therefore costs a few dozen round trips rather than ~800, so the deadline is spent on the origin's bandwidth instead of its latency.
- **`maxPackets`** counts all packets returned for inspection across both passes, including foreign streams. FFmpeg-internal packets during open/seek are bounded by input and time, not by that counter.
- **`maxPacketBytes`** rejects an oversized packet payload before parsing/decode, after FFmpeg has allocated it.
- None of these is a hard native-memory ceiling. The separate per-pass byte caps also reject a packet that would exceed the remaining allowance, rather than accepting an overshoot.

#### How interruption works

- The deadline and token interrupt HTTP requests and call a custom `IOReader.cancel()` concurrently, including during open/seek. A blocking custom reader must implement thread-safe cancellation, unblock promptly, and handle cancellation racing an operation's start. The default no-op cannot do that.
- FFmpeg also gets an interrupt callback.
- This is cooperative interruption, **not a hard real-time return guarantee**: native computation and a noncooperating reader cannot be forcibly terminated.
- The call waits for native work to return before freeing its state, drains interruption callbacks before returning the reader, and never publishes a positive obtained after a stop.
- Cancelled HTTP requests finish their task callbacks before the probe releases their origin slots or returns.
- A controlled HTTP probe waits for an origin request slot until its own deadline and then gives up with `sourceBusy`. A slot wait is the one wait the deadline watchdog cannot interrupt, so the deadline bounds it directly.
- Normal playback's redirect, cookie, authentication and response policies are unchanged.

**One detail a controlled probe cannot reach.** The recordless Dolby Vision audit (AE#567) opens the source a SECOND time by URL to read its first RPU. This probe's budget and cancellation do not police that traffic, so a controlled probe does not run it. An untagged 10-bit HEVC source whose container carries no Dolby Vision record therefore comes back without one from `probe(url:limits:)`, while `probe(url:)` synthesizes it. Probe that class of source without limits, or treat the absence as unconfirmed.

### Warming a source before it is loaded

```swift
await AetherEngine.prewarm(url: nextEpisodeURL, httpHeaders: headers)
```

A cold open is not free. On a non-fast-start MP4 it is two to three sequential round trips before the first sample read, and on a slow origin the first byte of the data connection is the whole perceived start time. A host whose UI knows what is coming next can spend those seconds in advance.

| Symbol | Contract |
| --- | --- |
| `AetherEngine.prewarm(url:httpHeaders:byteBudget:)` | `nonisolated static async -> SourcePrewarmReport`. Discardable. Fetches the opening bytes of a source the engine is not playing, so the next `load()` of that exact URL adopts them instead of fetching them. No engine instance, no audio session, no layer: a host warms while its player is still on the current item. Cancelling the task cancels the fetch and stores nothing. |
| `AetherEngine.prewarmDualLayerDolbyVision()` | `nonisolated static async -> Bool`. Discardable. Compiles the Profile 7 FEL composer's Metal shaders now (about 300 ms cold) so the first composed frame does not wait for them. Once per process, safe concurrently with playback. False without the `DualLayerDolbyVision` trait, with no Metal device, or when the shaders fail to compile. |
| `AetherEngine.isPrewarmed(url:)` | `nonisolated static -> Bool`. Whether that URL is warm right now, without consuming it. False again after the load that adopted it. |
| `AetherEngine.discardPrewarmedSources()` | `nonisolated static`. Drops every warmed source, for a host leaving the context they were made for. |
| `AetherEngine.defaultPrewarmByteBudget` | `8 * 1024 * 1024`. A byte budget and not a duration, because a duration needs the bitrate, which is known only after the probe this is trying to get ahead of. |
| `SourcePrewarmReport` | `retainedBytes`, `contentLength`, `declined`, `isWarm`. `declined` is one sentence naming why nothing was retained; the engine logs it either way. |

**What it fetches.** One ranged GET from byte zero for the budget. Plus a second one for the trailing object, only where the head says the session that opens this source will go looking for it. Two layouts do:

- an MP4 whose `moov` sits behind the media
- a Matroska whose SeekHead names a level-1 object past the warm head (usually its Cues). The Matroska span runs from that object to the end of the source and is declined above 1 MB, because a trailing object that large is a download rather than an index.

**Where the bytes live.** A warm also hands the load the resolved location:

- A resolver URL that answers 302 with a temporary edge target is resolved once, by the warm, and the session starts at that target instead of resolving the chain again. A lease that has since run out falls back to the source URL through the same ladder a mid-session expiry uses.
- Credential headers (`Authorization`, `Cookie`, `X-Emby-Token` and the rest of the #126 set) never travel to a cross-origin target, whether reached through a redirect or pinned from a warm.
- An https source that redirects to plain http on a public name is followed over https instead (#954), since App Transport Security would refuse the http hop. Local names, IP literals and hosts the app's own `NSAppTransportSecurity` already allows over http keep the redirect as sent. The engine's own HTTP/1.1 transports are not bound by ATS and follow the hop as sent, without credentials.

**Remote disc images** (`.iso` / `.img` / `.udf` over HTTP) adopt a warm too (#647). The disc reader takes the size from the warm instead of probing for it, answers the disc layer's structure reads and the title's opening extents out of the head, and starts its first request at the warm frontier. Its forks (the subtitle side reader, the forward prefetcher) share the same bytes without a copy. It does not pin the warm's redirect target, because that reader follows redirects per request. A disc-image URL that turns out not to be a disc hands the warm on to the streaming reader.

**Limits that are part of the contract:**

- **It never queues for the origin.** A warm takes a request slot only if one is free right now. It declines when the origin is metered down to one request at a time or is pacing the engine (`maxConcurrentSourceRequests`, #377). A prewarm that would have to wait for the playing session's uplink has stopped helping.
- **The bytes live in memory, and only until they are used.** They do not survive the app, and the first `load()` of that URL takes them rather than copying them. This is a head start, not an offline download, and there is no disk cache behind it.
- **`LoadOptions.nativeRemoteHLS` is out of scope.** On that route AVPlayer issues the requests and the engine sees none of them, so there is nothing to adopt. Warming helps the paths the engine fetches on itself: the loopback native path, the software host, and the side demuxers.
- **The URL is the key, matched exactly, and so are the headers.** A signed URL warmed under one signature is not adopted under another. A warm fetched with different `httpHeaders` than the load carries is not adopted either: an origin that varies on Referer, User-Agent or Authorization answers a different body, and a different size, under one URL, and nothing in the bytes would show it. Pass the load's headers to the warm.

When an adopted head already covers the entire source, opening it issues neither a data connection nor a speculative suffix request. A partial warm still fetches missing data and, when needed, the tail.

Warms are serialised, one at a time across the process. A second `prewarm` while one is in flight waits its turn rather than being refused. That costs the origin nothing, because a queued warm holds no request slot and has issued nothing. What never queues is a request against the origin.

## Transport

| Symbol | Notes |
| --- | --- |
| `play()` | Rewinds first when parked at the final frame of a VOD; a no-op on `.ended`. |
| `pause()`, `togglePlayPause()` | |
| `seek(to:)` | `async`. Source-axis seconds. See [Seeking](#seeking). |
| `seek(to:exact:)` | `async`. `seek(to:)` is this with `exact: false`. See [Seeking](#seeking). |
| `canSeek` | Whether the ready session accepts a seek. Live needs retained DVR history, remote HLS a measured item range, VOD a byte source proven seekable: a container duration alone is not proof. |
| `isSourceSeekable` | `@Published Bool?` for this load: nil is unknown or AVFoundation-owned, false forward-only, true a seekable byte source. A forward-only VOD ignores a saved `startPosition` and mounts at 0. Cleared by `stop()`. |
| `seek(toSourceTime:)` | Deprecated alias for `seek(to:)`. The clock is unified onto source PTS, so the two are the same call. |
| `setRate(_:)` | Playback speed. See [Playback speed](#playback-speed). |
| `maxSupportedRate` | 2.0 for video, 3.0 audio-only. Query after load; returns 2.0 while idle. Size a speed picker against it. |
| `audioDelaySeconds`, `setAudioDelay(_:)` | Lip-sync correction. See [Audio delay](#audio-delay). |
| `volume` | 0.0 to 1.0. A write before a session exists is remembered and applied at load. |
| `selectTitle(id:)`, `selectChapter(id:)` | Disc titles and chapters. |

### Seeking

`seek(to:)` is rejected when the session is idle, errored, ended, live without a DVR window, or on a forward-only VOD source. The forward-only case rejects with `SeekEvent.Rejection.sourceNotSeekable`, without a false landing; a seek queued during load drops its optimistic clock too.

- **Native.** A seek reports a landing only when AVPlayer completed it within 0.75 s of the target. An interrupted or clamped seek is not a landing.
- **Software host, AV1 decoded by dav1d.** The seek lands on the keyframe nearest the target, within 10 s (and within half the seek's own distance) and never on the far side of the playhead, out of those the packet cache retains or the container's index lists. `.landed` reports that keyframe's position. Without such a keyframe at or after the target, the seek stays exact ([formats › Containers and codecs](formats.md#containers-and-codecs)).
- **`seek(to:exact: true)`** lands on the target on that software AV1 route too, for a chapter mark or the end of an intro. It costs decoding from the keyframe before the target up to it. Every other route is exact either way. A seek stashed during load keeps the flag.

### Playback speed

`setRate(_:)` is clamped to `maxSupportedRate`; `0` pauses.

- While the session is paused, a non-zero rate does not resume it. It becomes the rate the next `play()` starts at, and `state` stays `.paused` (#730).
- The speed holds across pause and resume, and across the host rebuilds a session makes on its own (reload at position, audio-track switch, AirPlay LAN swap, background return).
- It belongs to the item: loading a different source, or `stop()`, returns to 1.0.
- Pitch-preserving on both decode routes: `audioTimePitchAlgorithm` is pinned to TimeDomain on the native player item and on the software path's audio renderer, so a speed control never has to be gated on which route a title took.

### Audio delay

`audioDelaySeconds` / `setAudioDelay(_:)` correct lip sync for the viewer's chain, in seconds. Positive presents audio later than video.

- Clamped to +/-2 s. Like `setRate`, it holds across the rebuilds a session makes on its own and belongs to the session.
- **Where it applies.** Where the engine still holds the timestamps: the stamped sample PTS on `.software`, and the audio track of the fMP4 segments on `.loopback`. AVFoundation exposes no equivalent on either surface a host can reach, so on `.remoteBypass` and on audio-only sessions the value is kept for the next load, and the no-op is logged rather than faked.
- **A change re-anchors at the playhead.** Unlike `setRate`, it is not free: the audio already decoded or fetched is committed to the previous value and cannot be re-timed in place. On `.software` the re-anchor is a seek to the current position. On `.loopback` it is the session-preserving reload, because seeking to the position AVPlayer already holds is a buffer hit and plays the old-offset segments out anyway. Measured on a 30 fps H.264 fixture: about 0.3 s of held picture on the loopback route, position kept.
- A live session without a DVR window has no position to return to. It takes the new value at the next seam it makes on its own.
- **Rapid presses.** Presses arriving while a re-anchor is running are folded into it rather than stacking one re-anchor per press (AE#464 round 3). A press that lands after the in-flight re-anchor read the value gets exactly one catch-up pass. The value does not ride the call, so the rebuild in flight delivers the newest one. Presses at a human pace arrive after a re-anchor has finished and are each their own.
- A re-anchor or a `reloadAtCurrentPosition(applying:)` raised the moment a previous rebuild returned, before the new host has published a position, rebuilds at the position that rebuild was mounted at, not at the head (round 5).
- A call landing while the session is being rebuilt at all is neither applied nor refused: it is kept in the options the load in flight reads, and the log says so.

## Time

Time lives on `player.clock`, a separate `ObservableObject`, so its ~10 Hz ticks never fire `objectWillChange` on the engine.

| Symbol | Axis |
| --- | --- |
| `clock.$currentTime` | playback clock, the scrubber axis |
| `clock.$sourceTime` | source PTS of the displayed frame; render subtitle overlays against this. On `nativeRemoteHLS` it is item time, corrected by the lead over the picture the engine measures on its injected #316 renditions while one is selected (AE#616); see [below](#sourcetime-on-nativeremotehls). |
| `clock.$sourceTimeFollowsPicture` | whether `sourceTime` is known to follow the displayed frame. Always true except on `nativeRemoteHLS`, where it is true only while the lead is measured since the last time jump (AE#616). |
| `clock.$progress` | `currentTime / duration` |
| `clock.$bufferedPosition` | source-axis position buffered ahead. Never below `currentTime`. While a native seek is pending it is measured from the seek target, which is where `currentTime` already stands, not from the frame AVPlayer still shows. |
| `clock.$liveEdgeTime`, `clock.$seekableLiveRange`, `clock.$behindLiveSeconds`, `clock.$isAtLiveEdge` | live-window surfaces. See [The rewind depth a live session really has](#the-rewind-depth-a-live-session-really-has). |
| `$residentRanges` | where the loopback segment cache or software VOD packet cache holds picture right now, as disjoint ascending spans on the `currentTime` axis. See [Resident ranges](#resident-ranges). |
| `player.currentTime`, `sourceTime`, `sourceTimeFollowsPicture`, `progress`, `bufferedPosition`, `liveEdgeTime`, `seekableLiveRange`, `behindLiveSeconds`, `isAtLiveEdge` | non-published mirrors of the same values for one-shot reads |
| `$duration` | seconds; a `LoadOptions.declaredDurationSeconds` outranks the container's |

**`seekableLiveRange`** is the intersection of the DVR window (policy) and what the segment cache actually holds and can play forward from (fact). So it is honest to scale a rewind strip on, and `seek(to:)` clamps to the same floor (AE#441). The two differ for the whole first `dvrWindowSeconds` of a session, and again whenever retention evicts faster than the window slides. Software live sessions hold a packet ring instead, which evicts by the same byte budget as the native cache (a quarter of the volume's free space, at most 2 GiB, at least 64 MiB). So the range's floor follows the ring once eviction has moved it past the window.

**`bufferedPosition`.** On native loopback playback it also refreshes while paused, as segments arrive or are evicted. It describes the contiguous frontier from the rendered position, not the sum of disconnected cached ranges; this refresh does not advance playback. On `.remoteBypass` there is no engine segment cache, so it is the end of AVPlayer's own loaded range contiguous with the playhead (`AVPlayerItem.loadedTimeRanges`), refreshed on every change of those ranges, including while paused (AE#935).

### Resident ranges

`$residentRanges` is the cache's own truth, not AVPlayer's `loadedTimeRanges`. One measured session held 64 segments over four minutes across several islands, while AVPlayer exposed roughly twelve seconds around the playhead and forgot a seeked-ahead island as soon as the playhead left it.

- Empty is the nil-equivalent.
- A live session always publishes empty. Its rewind depth is `seekableLiveRange`, which answers a different question.
- Residency is not a promise that a seek inside a span is instant: the player may still re-anchor and decode at the target, and a segment can start mid-GOP (AE#412).
- Coalesced to at most four updates a second, cleared on `load()` and teardown.
- Display these spans directly on the `currentTime` axis. `bufferedPosition` alone is a forward frontier and cannot establish a backward cache start.

**Software VOD.** `residentRanges` intersects video presentation coverage with the selected audio stream, even if muted; a video-only source does not require audio.

- H.264/HEVC, VC-1 and [WMV1/2](wmv-cache-coverage.md) use verified successor-PTS intervals, so the final picture with no known successor does not get an invented end.
- Ranges are clipped against retained keyframes and discarded packet timestamps. Unknown or invalid coverage stays empty. Metadata limits can conservatively omit old spans rather than claim packets that no longer exist.
- AVI MPEG-4 sessions that suppress generated packet PTS can qualify a separate cache presentation axis from the existing MPEG-4 parser and the same decoder's repaired frame timestamps. The packet delivered to the decoder is unchanged. Unqualified or ambiguous packet ownership stays uncovered; retiring temporary timing pairs does not itself evict confirmed ranges or retained seek anchors. See the [synthetic reproduction and scope](avi-mpeg4-cache-repro.md).
- The software sampler computes an immutable snapshot in the background and publishes on the main actor, including while paused. Cached seeks keep retained spans; a cache miss clears them when the old store is discarded. Seek, replacement and teardown guards reject a late snapshot.
- Live playback keeps exposing its separate seekable window rather than VOD resident ranges.

### Software VOD positioning and read failures

A source read failure keeps already committed software packets and their verified ranges. Cached seeks may replay them, but draining those packets still throws the original read failure: the error does not become EOF and does not flush unresolved successor timestamps. Storage or packet-envelope failures invalidate usability instead. A cold seek starts a new source lifetime.

Software VOD resume and cache-miss seek positioning run off the main actor with a **30 s positioning
budget**, measured after acquiring demux access.

- Waiting for an earlier read can add to the total call time.
- A deadline-bounded cold byte probe uses the existing streaming reconnect immediately. Already resident detour blocks stay usable, and ordinary unbounded parsing keeps its detour policy.
- This lets multi-probe keyframe searches on slow remote storage complete while keeping a finite I/O deadline. An unavailable source can consequently take longer to report failure.

Failures:

- A failed software resume throws before readiness or a requested clock anchor is published.
- A failed software seek reports `.stalled` and `.softwarePipelineFailed`, clears the in-flight state, and does not resume decoding or finalize the target as landed. Unlike an AVPlayer seek that stays pending for a late landing, this software failure is terminal for the host.
- Stop, cancellation and newer seeks still prevent stale completions from changing the active session.

### `sourceTime` on `nativeRemoteHLS`

(AE#616.) The engine sees no segment on this route, so the clock is AVPlayer's item time.

**The problem.** Some origins place a segment at its slot in the playlist while the segment itself starts at the keyframe before it (for example a Jellyfin transcode restarted by `-ss <slot> -noaccurate_seek -copyts`). Item time then leads the frame on screen, by a different amount after every seek: 1.1 s to 8.3 s measured. AVPlayer keeps the anchor of the first segment it loaded after the seek.

**How the engine corrects it.** The WebVTT renditions the engine injects for `LoadOptions.externalSubtitles` are placed by media timestamp, so each line reaches AVPlayer's legible output at its cue start plus that lead. The engine watches its own renditions with a non-suppressing legible output, matches each presented line back to the cue it wrote, and publishes `sourceTime` as item time less the measured lead. Log line: `AE#616: item time leads the presented frame by ...`.

- It re-measures on every line. Between a seek and the next line it keeps the previous value.
- `clock.sourceTimeFollowsPicture` is false from the time jump until that line, so a host can hold its overlay instead of detecting seeks itself.
- Without an injected rendition selected, nothing is measured: `sourceTime` is item time and `sourceTimeFollowsPicture` stays false.
- `currentTime`, `seek(to:)` and the scrubber stay on item time throughout, so a seek round-trips.
- A host drawing its own overlay from `sourceTime` (libass) can keep the rendition selected behind its own suppressing `AVPlayerItemLegibleOutput` to keep the measurement running.

## What the session is doing

### Playback state

| Symbol | Reading |
| --- | --- |
| `$state` | `.idle`, `.loading`, `.playing`, `.paused`, `.seeking`, `.ended`, `.error(String)`. Transport INTENT, not motion. |
| `$errorInfo` | `PlaybackErrorInfo?`, the machine-readable half of `.error`: a `PlaybackErrorKind` token, plus the underlying `NSError` domain and code where one is involved. Non-nil exactly while `state` is `.error`, assigned before it. Classify on this, never on the message. See [How a load ends](#how-a-load-ends). |
| `$playbackPhase` | The derived single source of truth, and **the only one of these that tracks motion**. See [`playbackPhase`](#playbackphase). |
| `$isBuffering`, `$isSeeking`, `$seekTarget` | The raw axes `playbackPhase` folds. On the AVPlayer paths, a wait AVPlayer spends evaluating its buffering rate (every resume from pause, a frame or two) is not a rebuffer; one that moves on to minimizing stalls is (Sodalite#168). |
| `sourceAuthorizationRefused` | `AnyPublisher<Int, Never>`: the origin answered 401 or 403 to the session's request headers mid-session. One value per header set, the status. Renew and call `updateRequestHeaders(_:)`; see [Rotating a credential without a rebuild](#rotating-a-credential-without-a-rebuild). |
| `seekEvents` | `AnyPublisher<SeekEvent, Never>`. See [Seek events](#seek-events). |
| `$isClockHeld`, `clockHoldEvents` | The software host's clock hold (#800). See [Clock hold](#clock-hold). |
| `$isSessionReady` | The session is ready in the AVFoundation sense. Not the edge a black cover comes off on. |
| `$hasFirstFrameReadyForDisplay` | The picture for **this** load is up. See [First frame](#first-frame). |
| `hasRenderedVideoFrame()` | Asynchronous point read of local presentation evidence. See [First frame](#first-frame). |
| `$startupProgress` | `StartupProgress?` for a determinate loading bar. See [Startup progress](#startup-progress). |
| `$isAwaitingDisplaySwitch` | True while a loaded session holds its start for the display: the post-load play gate is waiting for a mode switch (Match Content, a dynamic-range change) to settle. `playbackPhase` reads `.loading` throughout, and the first frame can already be up with `startupProgress` at `.presenting`, so this is what says the wait is the panel's and not the source's. A host that keeps its spinner off a switch during `.preparingDisplay` can key on this for the same stretch after the session is built. Cleared when the gate ends and at every `load()` / `stop()` (AE#1000). |
| `softwarePathEscalations`, `SoftwarePathEscalationEvent` | A native session AVPlayer refused, rebuilt on the software path, with the failure it absorbed. See [The engine moves a refused session onto the software path](#the-engine-moves-a-refused-session-onto-the-software-path). |

#### `playbackPhase`

Prefer `$playbackPhase` over stitching `state` + `isBuffering` + `isSeeking` together, and over matching log text.

- **It tracks motion.** `state` is transport INTENT and turns `.playing` the moment the engine has called `play()`, which on a live join can be seconds before the rate rolls (AE#440). Until the transport has moved once in a load, the phase stays `.loading`; it turns `.playing` on the roll itself.
- **It adds** `.rebuffering` and `.stalled(reconnecting:)`.
- **Precedence**, highest first: `error > ended > idle > loading > stalled > seeking > rebuffering > playing/paused`. A source that stopped delivering stays visible while a seek is in flight, because no seek can land over it, and `isSeeking` / `seekEvents` still carry the seek (#410).
- **`.stalled(reconnecting: true)`** is a reader that is retrying; **`false`** is a reader whose ladder is spent and whose recovery has passed to the producer's reopen. Both mean the source is down.
- **`.rebuffering`** is published on the AVPlayer-backed paths: the native loopback session, direct remote HLS, and the bare-AVPlayer audio host (a starved progressive stream, once the item has played). There `.stalled` cannot occur, because there is no reader. The software video host publishes it too, from the moment one of its pumps pauses the synchronizer to refill (a dry ring at the live edge, an exhausted audio lead on demand).
- A source whose connection is retrying reads as `.stalled` on the FFmpeg-backed hosts (software video, FFmpeg audio) once the reader's ladder is running.

#### Seek events

`seekEvents` publishes `.began`, `.landed(renderedTime:)`, `.stalled`, `.superseded` and `.rejected(SeekEvent.Rejection)`. Each carries its `target`, an `id` that spans the seek, and a `SeekEvent.Origin`:

- `.programmatic`
- `.nativeScrub`
- `.deferred`: a seek the session could not take yet. This is where the engine publishes an optimistic `currentTime` for a position nothing has reached.

Use it where the falling edge of `$isSeeking` matters. A level cannot say whether a seek landed, gave up, or was superseded, and a `.stalled` seek can still land later under the same id.

#### Clock hold

After a start, a seek, an in-place switch or a resume, the software host's clock stands at rate 0 on its new position until the decoder has frames from there on in the layer. It then starts 0.25 s later (#800). A host that judges playback from the clock must not count that window as a stall.

`clockHoldEvents` is `AnyPublisher<ClockHoldEvent, Never>`: `.began`, then exactly one `.released(ClockHoldRelease)` with one of:

- `.ready(waitedSeconds:)`
- `.timedOut(waitedSeconds:)`: the decoder produced nothing for 2 s, or produced without reaching the position for 6 s
- `.cancelled`: a seek, pause, rate change or the end of the session took over

It is per engine instance, so several engines at once are told apart without reading `EngineLog`. The AVPlayer paths, the audio-only host, live streams off the FEL route, and a start whose frames are already queued never hold.

#### First frame

**`$hasFirstFrameReadyForDisplay`** means a picture, not motion. A live join presents its first frame and can then hold it bit-static for seconds while AVPlayer decides whether to start (AE#440). A host dropping a spinner here drops it onto a frozen frame; use `$playbackPhase` for "it is moving".

- Latched for the load, cleared at the next `load()` / `stop()`.
- Audio-only sessions never arm it.
- On an external screen (`isExternalPlaybackActive`) the local layer never reaches readiness, so the item's readiness is the honest edge and the flag latches there (#315).

**`hasRenderedVideoFrame()`** is an asynchronous point read of local presentation evidence.

- Native playback requires this load's first-frame readiness and a currently ready `AVPlayerLayer`. It can briefly return false during item swaps or recovery reloads that the load-scoped latch deliberately hides. Hosts may latch a positive result when dismissing a startup poster, but should not restore that poster or infer lost playback from a single false.
- Software playback requires at least one frame counted and not dropped by its currently owned renderer. Those software counters are cumulative, so this does not prove continuing motion or that a picture remains visible after a flush.
- Unlike the load-scoped latch above, it does not treat external-player readiness as a locally rendered frame.
- Returns false for no video, unavailable metrics (including visionOS 1.0), cancellation, or a session replaced during the read.
- It does not start playback or wait for a future frame.

#### Startup progress

`StartupProgress` carries `checkpoint`, `completed`, `total`, `fraction`, `stage` (a `StartupStage` naming the work in flight, for a label beside the bar), `generation` and `isComplete`. Every value is work some part of the load finished, never a timer and never an estimate, so a slow stretch holds and a skipped one jumps. The ladder, in order:

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

- `.dispatched` is the origin of the axis rather than progress along it, so a fresh sequence publishes `completed == 0` and `total` is eight.
- A path that legitimately skips work records the checkpoint it does reach, and the ones behind it are credited by that alone. Nothing ever waits for a checkpoint its path will never emit.
- `generation` counts the startups a user waited through, not teardowns, so an engine-initiated reroute continues the bar instead of resetting it.
- Sampling the furthest checkpoint at the moment a host gives up turns a failure counter into a map of where loads die.

### Route and output

| Symbol | Reading |
| --- | --- |
| `$videoRoute` | `VideoRoute`: which pipeline is actually serving, one of `.none`, `.remoteBypass`, `.loopback`, `.software`, `.audio`. `LoadOptions.nativeRemoteHLS` is only the request; the carriage watchdog, the remembered verdict and the HLS reroutes move a session between routes, mid-session too. Branch on this, above all for who draws subtitles. |
| `$audioDelivery` | `AudioDelivery`: how the audio reaches the renderer, one of `.none`, `.noAudioInSource`, `.streamCopy`, `.bridged`, `.decoded`, `.droppedNoPipeline`, `.playerManaged`. `.droppedNoPipeline` is a source that HAS audio playing video-only, because no pipeline could be built for it or because a live bridge decoded nothing (AE#641): the value a fallback ladder demotes on. See [Reading whether the audio was delivered](#reading-whether-the-audio-was-delivered). |
| `$currentAVPlayer`, `$currentAVPlayerItem` | The live AVFoundation objects, re-emitted on every reload. Both nil on `.software`, which renders into its own layer. A host that only ever hands `currentAVPlayer` to an `AVPlayerViewController` gets audio over an empty video plane on that route (#298). |
| `$airPlayPictureStaysLocal` | iOS: true while a wireless AirPlay receiver holds the audio route but the session runs on the software host. See [AirPlay and the software host](#airplay-and-the-software-host). |
| `setScreenMirrored(_:)` | iOS: tell the engine whether the screen is being mirrored. |
| `setAirPlayReceiverShowsVideo(_:)` | iOS: tell the engine whether the AirPlay receiver on the audio route shows video. |

#### AirPlay and the software host

**`$airPlayPictureStaysLocal`** is true on iOS while a wireless AirPlay receiver holds the audio route but the session runs on the software host (VP9, AV1 without hardware decode, deinterlaced MPEG-2 / VC-1 / H.264, `preferredDecodePath = .software`). That host draws into an `AVSampleBufferDisplayLayer`, and only its audio renderer follows the route, so the receiver plays sound only. Nothing fails, which is why the engine says so: show the viewer that this title's picture stays on the device.

- False on the native paths, where the receiver gets the stream, and everywhere off iOS.
- False too while the host reports the screen as mirrored (`setScreenMirrored(_:)`), because the mirror carries the layer.

**`setScreenMirrored(_:)`** (iOS). Pass `true` for a mirror only, from `UITraitCollection.sceneCaptureState`; a recording reads as captured too. A mirror carries the software host's layer to the receiver, so `airPlayPictureStaysLocal` reads false while it is on. No effect off iOS.

**`setAirPlayReceiverShowsVideo(_:)`** (iOS) tells the engine whether the AirPlay receiver on the audio route shows video (an Apple TV or a TV).

- The audio session reports every AirPlay output as the same port type, so the engine cannot tell a TV from a HomePod itself. The default is false (audio-only or unknown).
- A host has the same limit, so the value is what it knows itself: the viewer's own choice (for example a "playing to a TV" control), or a host-owned `AVPlayer`'s `isExternalPlaybackActive`.
- While true and a wireless route is active, a Profile 7 FEL source loads on the native route (8.1 where the display takes Dolby Vision, no enhancement layer) so the receiver gets a picture, instead of the dual-layer route, whose layer no receiver picks up.
- Opt-in: nothing changes for a host that never calls it.
- Read at each load. On a URL source `reloadAtCurrentPosition()` decides again; a custom source keeps the route it loaded with until the next `load()`.
- No effect off iOS.

### Source and format

| Symbol | Reading |
| --- | --- |
| `$videoFormat` | The format being presented: `.sdr`, `.hdr10`, `.hdr10Plus`, `.dolbyVision`, `.hlg`. See [Presented format](#presented-format). |
| `$sourceVideoFormat` | The format the **source** carries, before any panel-driven mapping. The pair is what an honest badge needs: HDR content on an SDR panel differs between the two. |
| `$sourceDVProfile`, `$sourceVideoFrameRate`, `$sourceVideoBitrate` | Source detail for an info panel. |
| `$sourceVideoScan` | A `VideoScan` (AE#983): `.progressive`, `.interlaced(VideoFieldOrder)` or `.unknown`. See [Scan type](#scan-type). |
| `sourceDVBLCompatID`, `sourceDolbyVisionBaseLayerPresentable` | Read-only source capability snapshot on the main actor (not publishers). See [Dolby Vision base layer](#dolby-vision-base-layer). |
| `$dolbyVisionConversion` | A `DolbyVisionConversion?`: the Dolby Vision profile rewrite applied to the served stream; nil when the session serves the source's own profile or no Dolby Vision. `.profile7ToProfile81` is a Profile 7 source played on a display presenting Dolby Vision, where `$videoFormat` reads `.dolbyVision` and `$sourceDVProfile` keeps 7, so a label can say "P7 -> P8.1". The enhancement layer is dropped by that conversion. Set when the loopback session starts, cleared on stop. |
| `$sourceVideoCodecName` | The source video codec in libavcodec's spelling ("hevc", "h264", "av1"), nil when the source carries no video. The probe-free remote-HLS bypass maps it back from the item's video sample type, so the field answers on every route. Not the same question as `$activeVideoDecoder`: a codec has several decoders, and which one runs depends on the hardware. |
| `$sourceContainerFormat` | The container libavformat opened ("matroska,webm", "mpegts"). Nil on the remote-HLS bypass, where AVFoundation opens the source and there is no libav context to ask. This is the container that ARRIVED, which on a remux or transcode session is not the one a host's library metadata describes. |
| `$sourceVideoStreamFormat` | A `VideoStreamFormat?` (AE#658): the source video stream's pixel format, depth and colour. See [Stream and decoded format](#stream-and-decoded-format). |
| `$decodedVideoFormat` | A `DecodedVideoFormat?` (AE#658): what the engine's own decoder actually produced. **nil on every native route.** See [Stream and decoded format](#stream-and-decoded-format). |
| `$activeVideoDecoder`, `$activeAudioDecoder` | The decoder names actually in use, for a stats overlay. This is the honest "what is decoding this" surface; `playbackBackend` is not. The software playback host can use VideoToolbox for HEVC, in which case `$activeVideoDecoder` reports `VideoToolbox HEVC (HW)` on load and reload even though `playbackBackend` is `.software`. Show `$activeAudioDecoder`, classify on `$audioDelivery`: a label cannot tell a source without audio from a source whose audio was dropped. |
| `$metadata` | `MediaMetadata` parsed at load (title / artist / album / cover). |
| `$mediaChapters`, `$discChapters`, `$discTitles`, `$selectedDiscTitle` | Container chapters, and disc titles / chapters for DVD and Blu-ray ISO sources. |
| `AetherEngine.displayCapabilities` | `static DisplayCapabilities`: `supportsHDR`, `supportsDolbyVision`, `supportsHDR10`, `supportsHLG` for the current display. See [Display capabilities](#display-capabilities). |

#### Presented format

`$videoFormat` is the format being presented, after the panel-driven mapping.

- **macOS** has no per-mode capability table. A Dolby Vision session the clamp sent to `.hdr10` is upgraded back to `.dolbyVision` once the item AVFoundation is playing turns out to carry a `dvh1` / `dvhe` sample entry (AE#515).
- **tvOS.** The panel term behind it no longer comes from the headroom alone. A session serving an HDR master that AVFoundation has not refused publishes the presented format half a second in. A display that takes an HDR master is presenting HDR, while one that does not refuses in 54 to 61 ms, and `currentEDRHeadroom` has been measured reading 1.00 through exactly that acceptance (AE#459).

#### Scan type

`$sourceVideoScan` is resolved at load from the evidence the routing reads, so a panel can tell 1080i from 1080p without guessing from the height. `VideoFieldOrder` is the display order: `.topFieldFirst` or `.bottomFieldFirst`.

- **Sources of evidence:** the probe's field order; the H.264 SPS when the demuxer leaves it open (`.interlaced(.unknown)`); and the decoded-frame sample on seekable VOD, which turns a source declared interlaced whose pictures are progressive (1080i25 Blu-ray carriage) into `.progressive`.
- AV1, VP9 and VP8 have no field coding and read `.progressive`.
- `.unknown` before load, on the probe-free remote-HLS bypass, and when nothing settles it.
- Kept across audio-switch and background reloads, re-read on a disc title switch, reset on stop.
- Whether a deinterlacer actually runs is `decodedVideoFormat?.deinterlace`.

#### Dolby Vision base layer

`sourceDVBLCompatID` and `sourceDolbyVisionBaseLayerPresentable` are a read-only source capability snapshot on the main actor, not publishers.

- The optional compatibility ID comes from the DV record; nil means unavailable. An ID of 2 describes an SDR-compatible base (P8.2/P10.2), not HDR10.
- The Boolean is the existing VUI-aware eligibility for `dolbyVisionHandling = .baseLayerOnly`. It is not a promise about the panel or an accepted reload.
- Load/stop reset them to nil/false.
- They are assigned before `sourceVideoFormat` and `sourceDVProfile`, so they are already current inside a `$sourceDVProfile` or `$sourceVideoFormat` callback. There is no separate notification for this snapshot.
- Profile alone is not enough: a contradicted P5 record may have a presentable YCbCr base, while an IPT-only source does not.
- Hosts still honour the engine's reload-refusal result. Neither field changes routing or enables FEL.

#### Stream and decoded format

**`$sourceVideoStreamFormat`** carries the source video stream's `pixelFormat` ("yuv420p10le"), `bitDepth`, `colorPrimaries`, `transfer`, `matrix`, `range` and `profile` ("Main 10"), in libav's names as the container and the probe's decoder declared them.

- A field the stream leaves unspecified is nil, never a guessed BT.709.
- `colorPrimariesLabel`, `transferLabel`, `matrixLabel` and `rangeLabel` give the names a viewer reads ("BT.2020", "PQ (SMPTE ST 2084)", "BT.2020 NCL", "Limited").
- nil before load and without video.
- On the probe-free remote-HLS bypass it is the DELIVERED stream, read back from AVPlayer's item video track once it resolves: colour and range from the format description; `profile`, `bitDepth` and `pixelFormat` from its avcC / hvcC record (nil where the codec has none of those, AV1 and VP9 included). Under a server-side transcode that is the transcode, not the library's file, which is the point of reading it there.

**`$decodedVideoFormat`** is what the engine's own decoder actually produced.

- `frame` is a `VideoStreamFormat` for the decoded picture: libavcodec's output pixel format, or the libav name of the VideoToolbox buffer on the software host's hardware decoder.
- `pixelBufferFormat` is the CoreVideo buffer it was displayed from (`420v`, `x420`); `pixelBufferLabel` reads "P010 (x420)".
- `deinterlace` is a `VideoDeinterlace?` (AE#983) naming the deinterlace graph the frames pass through: `filter` (`yadif_videotoolbox`, `bwdif`, `yadif`), `isHardware`, `fieldRate`, and `outputFramesPerSourceFrame` (2 at field rate, so "deinterlaced to 50 fps" is `sourceVideoFrameRate * 2`). nil while frames go out as decoded. The graph engages on the first frame flagged interlaced and stays until a seek.
- Republished when any of these changes mid-stream.
- **nil on every native route.** AVPlayer decodes there and its frames never pass through the engine. A panel shows `$sourceVideoStreamFormat` and names AVPlayer as the decoder, instead of inferring a pixel format it never saw.

#### Display capabilities

`AetherEngine.displayCapabilities` is what a settings screen should read instead of guessing from the device model.

- **macOS:** the table comes from `AVPlayer.eligibleForHDRPlayback` (there is no per-mode API there) and leaves Dolby Vision unclaimed. That is what `LoadOptions.panelPresentsDolbyVision` is for.
- **tvOS and iOS:** the per-mode table is `AVPlayer.availableHDRModes`, but since 6.82.0 it may only ADD. `supportsHDR10` and `supportsHLG` take eligibility as their floor, because the table under-reports HLG over HDMI against a panel whose EDID advertises it (AE#459). Dolby Vision still comes from the table alone on those platforms, where it is measured correct in both directions.
- **It answers at CALL TIME**, so a host that stores it stores a moment. On tvOS a backgrounded process is answered for its own state, and every term reads false until the app returns.
- A session reads it once, at the load, and every route and rebuild of that session answers to that one table (AE#535).

## Audio tracks

| Symbol | Notes |
| --- | --- |
| `$audioTracks` | `[TrackInfo]`. Republished when `LoadOptions.confirmAtmos` confirms a track, and when the DTS:X decoder confirms the playing track as DTS:X (`isDTSX`). On `.remoteBypass`, see below. |
| `$activeAudioTrackIndex` | The selected track's id. On `.remoteBypass`, the enabled item track's. |
| `selectAudioTrack(index:)` | Session-preserving reload. `index` is `TrackInfo.id`. See [Switching audio tracks](#switching-audio-tracks). |
| `audioShaping`, `setAudioShaping(_:)`, `$audioShapingState` | Shape the session's audio before it reaches the output (AE#923). See [Audio shaping](#audio-shaping). |
| `installAudioTap(channels:)`, `removeAudioTap()`, `audioTapHasDeliverySource`, `AetherEngine.audioTapFormat` | Opt-in decoded PCM, mono Float32 48 kHz with source-PTS stamps, off the render path. `channels` is an `AudioTapChannels`: `.downmix` (default) or `.dialogue` (the centre channel alone). See [the audio tap contract](#the-audio-tap-ends-with-its-session). |

**`$audioTracks` on `.remoteBypass`** lists the audio tracks AVPlayer built for the item (normally just the one playing), read from their format descriptions: `codec` in libavcodec's spelling (`eac3`, `ac3`, `aac`), `channels`, `sampleRate`, `profile` (AAC's object type; "Dolby Digital Plus + Dolby Atmos" with `isAtmos` when the E-AC-3 dec3 record announces JOC) and `language` from the track or the selected audible option. The ids are synthetic (from 400000 up) because there is no stream index on that route; compare them only with `activeAudioTrackIndex`.

### Switching audio tracks

`selectAudioTrack(index:)` is a session-preserving reload.

- **Native path.** The old item stays mounted while the source reopens. Its last picture is held on the bound `AetherStillView` (or `AetherPlayerView`) across the item swap until the new item's first frame, so the switch shows a still rather than black. Audio is not gapless. Nothing is held in PiP or on external playback, and a media-services reset still discards the item. See `AetherStillView` for the software path and Dolby Vision.
- **Elsewhere** expect roughly 0.5 to 1 s of black.
- **Rapid picks** coalesce into one rebuild at a time. A pick back to the active track costs nothing, and `stop()` or a new `load` drops what is queued.
- **Transport.** It comes back in the session's transport, like `reloadAtCurrentPosition()`: a paused session stays paused, and a `play()` or `pause()` that arrives while the rebuild awaits I/O decides the final state.

It is a no-op (every refusal is logged, so a picker that does nothing is explainable):

- when out of range or already active
- on a forward-only custom source (live ingest included), which cannot rebuild its pipeline. There a track change is a fresh `load` naming the stream.
- on a sequential origin (`$isSequentialOrigin`), which could only reopen at byte 0. There a track change is a fresh `load` at the position with `audioSourceStreamIndex` (AE#958).
- on `.remoteBypass`, where AVPlayer owns the audio selection and the track list is informational. A different language there is a different URL.

### Audio shaping

`audioShaping` / `setAudioShaping(_:)` take an `AudioShaping`, which carries:

- a channel cap (`maxChannels`)
- a dialogue lift (`dialogueGainDB`)
- night-mode compression (`compressor`; `AudioShaping.Compressor.night` is the engine's preset). With `ratio: 1` it is a plain gain of `makeupGainDB` into the limiter.
- a loudness target (`loudnessTargetLUFS`, clamped to `AudioShaping.loudnessTargetRange`, -36 to -12 LUFS): raises a quiet source to that programme loudness by at most `AudioShaping.maxLoudnessGainDB` (18 dB), never lowers one (AE#1036)

Values are clamped and read back clamped. The default shapes nothing and leaves every route as it was.

- **Active shaping needs PCM.** A stream-copied track (Atmos and every lossless bitstream included) is decoded and bridged while it is on, and shaping takes precedence over `objectAudioRendering`. Turning it off goes back to stream copy.
- **Every change is the session-preserving reload** (`reloadAtCurrentPosition`), because it changes which pipeline the session runs. Changes arriving during that rebuild are folded into it, like `setAudioDelay(_:)`'s.
- **`$audioShapingState`** publishes an `AudioShapingState`: `.off` (nothing asked, or the rebuild that carries a new value is still on the way), `.applied`, or `.unavailable` (AVPlayer owns the audio on `.remoteBypass` and the native audio-only host, or the session plays no audio).

See [Audio shaping](formats.md#audio-shaping) for what each setting does to the signal.

## Subtitles

| Symbol | Notes |
| --- | --- |
| `$subtitleTracks` | `[TrackInfo]`: embedded text, embedded bitmap, external files and a live channel's HLS renditions in one list. |
| `selectSubtitleTrack(index:)`, `clearSubtitle()` | Drives the host-overlay path, or AVPlayer's media selection on `.remoteBypass`. `clearSubtitle()` keeps `nativeSubtitleTracks` listed; only `load` / `stop` reset that. |
| `$subtitleCues` | `[SubtitleCue]`: `.text`, `.richText([SubtitleTextRun])`, or `.image(SubtitleImage)`, with an optional `SubtitleTextPlacement`. Cues carry raw source PTS. See [Cue retention](#cue-retention). |
| `$isSubtitleActive`, `$isLoadingSubtitles` | State for a subtitle toggle: active is the selection, loading is a sidecar or side-demuxer pass in flight. |
| `$activeSubtitleTrackIndex` | The selected id, including one resolved by `preferredSubtitleLanguages`. |
| `$sidecarASSHeader` | The ASS header for the active primary sidecar, for hosts rendering authored styling. |
| `addExternalSubtitleTrack(_:)`, `removeExternalSubtitleTrack(id:)` | Register or unregister an `ExternalSubtitleTrack` at runtime. Returns the `TrackInfo` it was listed as. Tracks added after load are overlay-only; declare them in `LoadOptions.externalSubtitles` to have them join the native renditions. |
| `selectSidecarSubtitle(url:httpHeaders:)` | One-shot sidecar decode without listing a track. Prefer `addExternalSubtitleTrack` + `selectSubtitleTrack`, which keeps the track listed and `activeSubtitleTrackIndex` populated. nil headers forward `LoadOptions.httpHeaders` (see [External subtitle request headers](#external-subtitle-request-headers)). |
| `maximumSubtitleOffsetSeconds` | The largest subtitle offset, of either sign, the host applies to its overlay against `clock.sourceTime`. Setting it sets both of the next two; reading it gives the larger. Default 60. See [Cue retention](#cue-retention). |
| `maximumSubtitleDelaySeconds`, `maximumSubtitleAdvanceSeconds` | The same reach per direction (AE#1031): the largest LATER offset (cues shown after their time) and the largest EARLIER one. Default 60 each. See [Cue retention](#cue-retention). |
| `setSoftwareSubtitleDelay(_:)`, `softwareSubtitleDelaySeconds` | Media-time offset for both channels composited into software PiP frames: positive delays cues, negative advances them. Non-finite values are ignored; the default is 0, and the value survives later loads on the same engine. Takes effect on the next composited frame, without a seek, reopen or A/V clock change. A host overlay applies the same value as `clock.sourceTime - delay`. AVPlayer-owned native renditions, native PiP and AirPlay are not shifted; a host offering a timing control should say so. |
| `SubtitleCaptionStyle`, `SubtitleCaptionStyle.current()`, `SubtitleCaptionStyle.observeChanges(_:)`, `SubtitleCaptionStyle.standard` | The user's system caption style. See [System caption style](#system-caption-style). |
| `teletextPage`, `setTeletextPage(_:)` | The DVB teletext caption page, at load and while the channel plays. |

### Cue retention

`$subtitleCues` holds the active track's cues from 300 s behind the playhead to the decode lead ahead.

- Bitmap cues (PGS/DVB/DVD) are retained as decoded RGBA. Those that ended further behind than `maximumSubtitleDelaySeconds` (at least 15 s) are also dropped, oldest first, once their images exceed 64 MiB (AE#879). Once the host has set any of the three reach properties, all of them are dropped at once (AE#929).
- Before those, cues starting beyond the decode lead that the drain has not reached yet are dropped, furthest first (after a backward seek, the old position's cues). The drain decodes them again on its way there (AE#929).
- A seek back re-decodes what was dropped.

**The offset reach** (default 60 each way) sizes how much bitmap cue history the engine keeps, and whether embedded subtitles cost a second read of a remote source. The two directions cost different things, so they can be set apart (AE#1031):

- `maximumSubtitleDelaySeconds`, for LATER offsets: the history behind the playhead the 64 MiB budget never evicts. It reads nothing twice, because a later offset only needs cues the main reader has already passed.
- `maximumSubtitleAdvanceSeconds`, for EARLIER offsets: how far ahead the drain decodes (at most 60 s), and whether the forward prefetch below runs.
- `maximumSubtitleOffsetSeconds` sets both. Each edge stays at least 15 s. A positive `softwareSubtitleDelaySeconds` is always covered by the history, a negative one by the lead.
- A host whose control shifts subtitles later only, or much further later than earlier, sets `maximumSubtitleAdvanceSeconds = 0` and its later range in `maximumSubtitleDelaySeconds`. Measured with `aetherctl` over HTTP on a 70 s, 20 Mbit/s MKV with a PGS set every 3 s, at 48 s: later 60 / earlier 0 kept 16 decoded sets behind the playhead against 6 at a reach of 0, and its prefetch stayed in the landing role (parked after 5 packets), where a reach of 60 read the file to its end a second time (375 MB requested against 215 MB).
- Setting it also drops every bitmap cue that ended behind that history at once, instead of keeping them up to the 64 MiB budget. Past the floor a cue serves no offset, and a seek back re-decodes its own window anyway.
- A host without a subtitle offset control should set 0. On a dense PGS track that keeps 15 s of decoded images on each side, instead of a protected 120 s plus 64 MiB of history (AE#929).
- **An advance of 0 also turns off the forward subtitle prefetch (AE#1015).** That reader exists only to have cues ready for an advance offset. On a remote MKV or MP4 it downloads the video a second time: a minute of 1080p read 243.6 MB with an embedded SRT selected against 104.5 MB without. With an advance of 0, embedded text subtitles come from the main reader alone, which covers a zero or positive offset. A bitmap track (PGS, DVB, DVD) keeps the reader in a landing role (AE#1022): after each seek, and at the start, it reads from 15 s before the landing to 2 s past it, then parks until the next seek. That is what finds the line a seek lands inside, because the main reader repositions on a video keyframe and never reads a set that began before it. Cost per seek: the window itself, plus up to one 32 MiB range the origin delivers in full (measured on a 2.7 Mbit/s 1080p MKV over HTTP, four seeks: 168 MB against 87 MB without it, and 299 MB at the default reach). The prefetch still runs while `softwareSubtitleDelaySeconds` is negative or the OCR worker is armed (PiP, AirPlay, external display on a bitmap track), and it starts or stops at once when either changes.
- The text drain lead is unaffected. Negative and non-finite values are ignored. It takes effect on the next drain tick.

### Native renditions (PiP, AirPlay, external display)

| Symbol | Notes |
| --- | --- |
| `$nativeSubtitleTracks`, `setNativeSubtitleSelected(track:)` | The WebVTT renditions declared by `prepareNativeSubtitles`, for PiP / AirPlay / external display. nil deselects. |
| `$nativeSubtitleDefaultOrdinal` | The rendition marked `DEFAULT=YES`, resolved from `nativeSubtitlePreferredLanguages`. A programmatic legible selection only renders if it is the default, so select **this** ordinal. |
| `$nativeSubtitleRenditionAvailable` | At least one cue exists for the native track. Gate the AVMediaSelection picker on it. |
| `$nativeSubtitleRenditionsServed` | Whether the served playlist is the master. A reload signal and a diagnostic, nothing more: whether a legible rendition reaches a wired external display is AVKit's business and cannot be observed from here. |
| `setNativeSubtitleRendering(_:)` | Hand subtitle drawing to AVKit while the video leaves the host's view hierarchy, and take it back on return. See below. |

`setNativeSubtitleRendering(_:)` is used for PiP, AirPlay and a wired external display.

- It is a standing request: it holds until called with `false` or the session ends, and survives the engine's own AirPlay reload.
- On a wireless AirPlay receiver the engine raises it itself when the host has not, and withdraws only that one when the receiver lets go. A host call takes over at any time.
- A bitmap track (PGS / DVB / DVD) gets an OCR-fed rendition, selected once the recognized cues cover AVKit's fetch window ([formats](formats.md#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display)).
- No-op for a track added after load, which has no rendition until the next reload.

### System caption style

`SubtitleCaptionStyle` is the user's system caption style: font, size, text, background and window colour and opacity, and edge style. The software host reads it itself, because it has no AVKit legible output to apply it.

- The engine applies it to the text cues it composites into software PiP frames, and re-renders on a change.
- A host drawing its own overlay calls `current()` and `observeChanges(_:)` (hold the returned `Observation`) to match.
- A field is non-nil only where the user's value differs from the system default. (The system's `UseValue` flag is not a sign of change.)
- Each field carries a `Precedence`. `overridesCue` ranks user, then cue, then engine default. `yieldsToCue` ranks cue, then user, then default. A host drawing its own overlay applies it with `Choice.resolved(cue:)`, which returns the user's value or the cue's per the field's `Precedence`, for a field whose `Choice` is non-nil.
- `standard` (nothing customised) keeps the cue's own styling and the default look.
- `observeChanges(_:)` calls its handler on an arbitrary thread, and not again once the `Observation` is released.
- Bitmap cues are never restyled.

### Secondary subtitles

An independent second track, for bilingual viewing or language learning.

| Symbol | Notes |
| --- | --- |
| `selectSecondarySubtitleTrack(index:)`, `selectSecondarySidecarSubtitle(url:httpHeaders:)`, `clearSecondarySubtitle()`, `$secondarySubtitleCues`, `$isSecondarySubtitleActive`, `$isLoadingSecondarySubtitles` | The second track's controls and state. |
| `$activeSecondarySubtitleTrackIndex` | Read-only selected `TrackInfo.id` for embedded and registered external secondary tracks. nil means off **or** a one-shot URL selection; use `isSecondarySubtitleActive` to tell them apart. |
| `$secondarySidecarASSHeader` | Independent ASS header for the active secondary sidecar when `preserveASSMarkup` is enabled. Pair it with `secondarySubtitleCues`, never with the primary header: script resolution and styles can differ. |

Selection:

- Selecting a registered external ID keeps the old secondary cues, ASS header, identity and bitmap drainer active while the candidate decodes. Only successful, current preparation replaces them; failure keeps the old selection and ends loading.
- A bitmap decoder must be created before replacement.
- The compatibility one-shot URL API keeps replace-on-start semantics.
- Reloads snapshot pending selection intent, so an audio switch or repeated rebuild does not silently restore the old pick.
- Primary and secondary may select the same track.

`$activeSecondarySubtitleTrackIndex`:

- A registered external selection publishes its ID when the decoded replacement commits, together with its cues. While it decodes, and after a failed decode, the previous ID stays with the previous cues. Prepared selections likewise publish only at commit.
- Clearing, stop/load and rebuild restoration update the same identity. Re-selecting the same ID does not emit a duplicate.
- As with other `@Published` fields, a synchronous subscriber uses the delivered value rather than re-reading during willSet.

`$secondarySidecarASSHeader` is nil by default, for a committed non-ASS selection, and after clearing or stopping. A registered secondary replacement keeps the old header while preparing; session-preserving reloads decode it again with the restored track.

#### Secondary subtitles across audio rebuilds

An active registered secondary subtitle survives an audio-track rebuild through its original registry id, including `ExternalSubtitleTrack.httpHeaders` and `sourceStreamIndex`.

- A one-shot secondary sidecar still restores through its URL.
- Switching to an embedded secondary track clears the previous sidecar URL.
- Internal teardown clears active secondary identity while the rebuild's saved selection can restore it. A decode result from an older load cannot republish cues or loading state in the new one.
- This does not add bitmap/ASS capabilities or prohibit selecting the same track in both channels.

### External subtitle request headers

When an external subtitle has no explicit `httpHeaders`, media headers are inherited only if its URL has the same HTTP scheme, host and effective port as the media URL.

- An omitted default port equals an explicit default port.
- A scheme change, including HTTP to HTTPS, is a different origin for this initial sidecar request.
- Unknown media origins and local files inherit nothing.
- This applies to primary and secondary overlays, native subtitle cue-store fills and remote-HLS sidecar renditions.
- For a subtitle server requiring authentication at another origin, set `ExternalSubtitleTrack.httpHeaders` or the sidecar call's `httpHeaders` explicitly. An explicit empty dictionary disables inheritance.
- Redirects still follow the existing redirect-header policy, and certificate trust still uses `EngineTLS.serverTrustEvaluator` independently.

### Prepared external subtitle selection

Use this to decode a downloaded subtitle file first and commit it only if it worked, without disturbing the current selection.

- `prepareExternalSubtitle(_:policy:)` decodes a downloaded regular SRT, WebVTT, ASS or SSA file without changing the active tracks, preferences or cue lists.
- `prepareExternalSubtitle(id:policy:)` prepares an existing registry entry without creating another ID.
- Preparation requires a playing, paused or seeking session and returns a MainActor-owned `PreparedExternalSubtitle`. Its `cueCount` lets the host check whether preparation succeeded.
- The existing `preserveASSMarkup` option governs ASS output.
- `commitExternalSubtitle(_:secondary:)` consumes the handle once and publishes already-decoded cues synchronously. It does not reopen or decode the file.
- `discard()` releases an unused candidate.
- `ExternalSubtitlePreparationError` distinguishes `unsupportedFormat`, `empty`, `resourceLimit`, `decodeFailed`, `cancelled` and `stale`. A failed preparation or rejected commit keeps the prior selection.

**Limits.** `ExternalSubtitlePreparationPolicy` bounds:

| Field | Default |
| --- | --- |
| `maximumFileBytes` | 4 MiB |
| `maximumCueCount` | 50,000 |
| `maximumCueBytes` | 8,192 UTF-8 bytes |
| `maximumTextBytes` | 8 MiB |

Hosts can supply different positive limits. Ordinary subtitle selection keeps its existing behaviour. A track registered by a successful prepared commit remembers its policy for later selections.

**Files.**

- Preparation performs file metadata checks and decoding on the existing blocking worker, not the MainActor.
- Remote downloading stays the host's responsibility.
- The local filename must have a supported extension; `formatHint` does not permit arbitrary containers.
- Keep the file stable during preparation.
- Non-regular files, symbolic links, unsupported codecs and multistream containers are outside this API.

**Invalidation.** Prepared candidates belong to one engine, one load/stop generation and one shared subtitle-selection intent. These invalidate older candidates: a selection or clear on **either** channel, registry removal, a successful commit, stop, or a new load. So two independently prepared candidates are not an atomic primary/secondary pair: committing one invalidates the other. This prevents a late picker result from replacing a newer user choice. The same registered subtitle remains selectable on both channels; the engine adds no host-specific exclusivity policy.

## Live and DVR

| Symbol | Notes |
| --- | --- |
| `$isLive` | Mirrors `LoadOptions.isLive` for the session. |
| `$isSequentialOrigin` | True while a VOD session is served as a sequential origin. See [Sequential origins](#sequential-origins). |
| `seekToLiveEdge(offsetSeconds:)` | `async`. Lands `offsetSeconds` behind the usable edge (default 0; negative or nonfinite read as 0), clamped to retained media. Choosing a safety margin is the host's call. On a live-only session it drives the native item to its own seekable end minus the offset. |
| `currentItemLiveEdgeTime` | The native item's usable live edge on the display axis. nil before the item has a range and on the software route. While AVPlayer's range mirror lags behind retained history, only already-played contiguous resident media is admitted, never prefetched media. |
| `liveTargetDurationSeconds` | The TARGETDURATION the engine's own live playlist is serving. nil on remote HLS live, on the software path and before the first playlist build. |
| `setNativeLiveDVRLimits(_:availableCapacityBytes:)` | Renews the native loopback session's DVR allowance without a reload or a second source. See [DVR limits](#dvr-limits). |
| `nativeLiveDVRMandatoryBytes` | The finite pinned playback payload that may exceed that allowance. Excludes init and subtitle data, muxer staging, AVPlayer's buffers, filesystem overhead and recordings. |
| `setSoftwareLiveDVRLimits(_:availableCapacityBytes:)`, `softwareLiveDVRBytes` | The same lease for the software live spool, which needs `LoadOptions.softwareDVRRetention`. `softwareLiveDVRBytes` is the retained packet payload. See [DVR limits](#dvr-limits). |
| `liveSourceReset` | The [retune contract](#live-the-retune-request). |
| `liveSourceReplayExhausted` | Verified replay exhausted one bounded recovery round. Cached DVR stays readable; retry via `retryLiveSourceRecovery()` under the host's backoff without losing packet history. See [exhausted verified replay](#live-exhausted-verified-replay). |
| `liveResumeClamped`, `LiveResumeClamp` | A resume that found the playhead outside the window and moved it; see [a resume that had to move](#live-a-resume-that-had-to-move). |
| `liveScrubThumbnail(atSessionSeconds:maxWidth:)` | Still on the live session axis, decoded from what the session already holds. A native session reads its DVR segment cache; a software session reads its DVR packet ring (#544), so a tuner channel the box decodes in software has a scrub preview too. |
| `$playlistShiftSeconds` | Seconds the producer subtracted from source PTS. Published values already fold it back; exposed for hosts pairing their own samples against AVPlayer's raw clock. |
| `HLSLiveIngestReader(playlistURL:)`, `HLSLiveIngestReader(playlistURL:httpHeaders:)` | The ready-made `IOReader` for ingesting an upstream HLS playlist directly, with AES-128 clear-key and SSAI handling. See below. |

**Timestamp resets.** On the native loopback path, `currentTime`, the seekable range, item placement and seek targets keep the session's initial timeline shift when the origin resets its timestamps, so the display time stays continuous. `clock.sourceTime` stays the presented frame's source PTS for cue matching, so the two intentionally differ after a reset.

**`HLSLiveIngestReader`.** The headers ride the playlist, every segment and every AES key, which is what a tokenized IPTV origin enforces per request. Credential headers (`Authorization`, `Cookie`, `X-Emby-Token` and the like) go only to the playlist's own origin, with no https to http downgrade. A URI the playlist points at another host gets the other headers without them, the same rule a redirect follows. Unsupported shapes surface a typed `HLSIngestError`.

### DVR limits

`setNativeLiveDVRLimits(_:availableCapacityBytes:)` takes a `LiveDVRLimits` (`windowSeconds`, `maximumBytes`, `minimumFreeBytes`, `capacityValidUntil` on the `systemUptime` clock) plus the caller's capacity sample.

- Cache eviction, playlist sizing and producer admission share it.
- A missing, invalid or expired sample withdraws the optional history (`seekableLiveRange` goes nil), and a timer reclaims it even while playback is parked. Renewal needs a fresh sample and deadline.
- The engine's own per-volume budget still applies on top.
- Returns false on a software, remote or unready session.

`setSoftwareLiveDVRLimits(_:availableCapacityBytes:)` is the same lease for the software live spool.

- Expiry withdraws seekable history and prunes at the next append, so it is not an immediate physical reclaim while no packets arrive.
- A feeder whose cursor was evicted re-anchors through its normal seek before pumping again. A newer seek, pause, stop or source change wins over that recovery.

### Sequential origins

`$isSequentialOrigin` is true while a VOD session is served as a sequential origin: declared (`LoadOptions.sequentialOrigin`), or found by the reader (the origin ignores `Range`, or refused the ranged open twice and served a plain GET, AE#693).

- The session plays from the start, so a `startPosition` given to `load()` was not honoured.
- On the loopback route a seek lands when its target lies in the `$residentRanges` span that reaches the producer's frontier (the last one). Any other target, and every seek on the software host, is rejected as `.sourceNotSeekable`.
- `selectAudioTrack` is ignored, since it could only reopen at byte 0. Load the source again with `audioSourceStreamIndex`.
- A host that needs the position reopens the source or tells the user.
- Set during `load()`, cleared on stop.

### Where a live start's seconds go

On the loopback live path (a raw stream, or an HLS source the engine ingests itself), the join cost is not probe or decode work. It is one withheld response.

**The holdback.** The engine serves AVPlayer a playlist of its own. AVPlayer starts a live session at the edge minus a holdback of `3 x TARGETDURATION`, the RFC 8216bis floor that the served playlist advertises. So the first `/media.m3u8` is held until the window carries that much content behind the edge. Serving earlier puts AVPlayer's opening seek inside its own stall-danger zone, where it restarts in a loop instead of playing (#189).

- An origin that hands over a backlog satisfies it at I/O speed.
- A strict-realtime origin pays it in wall clock.
- The native bypass has no such gate, so a host measuring both sees it only on the paths that ingest.

**How to see it.** Read these before treating a slow live start as a decode problem:

- `startupProgress` stalls at `sessionConstructed` for the whole wait. The checkpoint at the slow moment tells this apart from the demux probe (`streamsProbed`) and the display handshake (`routed`).
- The first serve logs the interval it held, the window it served, and the holdback it was measured against, whether it waited or was satisfied immediately.

#### `liveJoinProfile` and `.fastZap`

`LoadOptions.liveJoinProfile` is the lever, and `.fastZap` is its default. It collapses `TARGETDURATION` to the source keyframe cadence, and the holdback follows it down. So the win belongs to the source GOP rather than to the flag: `TARGETDURATION` can never fall below `ceil(max EXTINF)`, and a long-GOP source therefore keeps most of its runway under either profile.

Where the engine cuts the segments itself, each one is a whole GOP, and the value is sealed from the first few. So it carries headroom for a GOP 1.5 x the longest seen. (A broadcast whose GOPs ran 1.0 to 2.4 s sealed TARGETDURATION 1 on its first three and then broke `EXTINF <= TD` on every longer one, AE#670.) The headroom is the smallest value under which that longer GOP still lists (RFC 8216 rounds EXTINF to the nearest integer) and finishes inside AVPlayer's `1.5 x TARGETDURATION` patience with 0.5 s to spare. So 1 s GOPs serve TARGETDURATION 2 and a 6 s holdback, and so does a 59.94 fps stream whose scene-cut keyframes merge GOPs into 80 to 89-frame segments (up to 1.666 s seal 2).

#### An ingested HLS upstream: sealing over the whole upstream segment (AE#684)

**An ingested HLS upstream seals over the segment it is delivered in, as far as its join pays for it, under either profile.**

The engine re-cuts an upstream segment (at its GOPs under `.fastZap`, at about 4 s under `.standard`). But the window still changes only once per UPSTREAM segment. So what the seal asks for is the longest segment the upstream has served, whole. (`ceil(segment / 1.5)` used to leave the client a patience of exactly one delivery.) The upstream's advertised target duration is still not read.

The seal is bounded three ways:

1. **By the join, which is not deepened for it on an upstream of uniform segment length.** A seal is a holdback of `3 x` itself, and the join there is the three upstream segments it was before. (One more would be one more download before the first picture on every zap, which AE#678 measured and declined.) Their last GOP stays open until the next delivery, so three 6 s segments are 18 s joined and 16 s cut: the seal is 5, the largest value whose holdback that window holds, not 6. Three 10 s segments cut 28 s and seal 9.
2. **By a ceiling.** Segments longer than 10 s (`LiveEdgePolicy.upstreamSegmentSealCeilingSeconds`) are not asked for whole: a 20 s one seals 14, as it did before, because the live-only window is 60 s.
3. **Never under what it was.** Where the old value already covered the segment nothing moves: 2 s segments keep 2 and a 6 s holdback, and `.standard` keeps its 6 on anything up to 6 s.

**Alternating segment lengths.** The one addition to the join is that it is equalised over the PHASES of an upstream whose segment lengths alternate: a tune never loads more than the deepest tune of the same channel already did.

- Before: alternating 6 s and 4 s segments joined four (20 s listed, 18 s cut, seal 6) with a 4 s one newest, and three (16 s listed, 14 s cut, seal 4, as in 7.25.1) with a 6 s one newest. So the same channel behaved differently from one tune to the next.
- Now: the depth is the deepest the coverage rule takes over the tune itself and the tunes one, two, ... segments earlier that its own join still reaches, at most one segment above its own. Both phases join four and seal 6.
- Cost: the three-segment phase (about four tunes in ten on that shape) loads one additional short segment at the join, which the other six already load. 3.47 s to 4.23 s to first picture behind an 8 Mbit/s link, median of five, against 4.27 s in the other phase on either build.
- Shapes whose phases already joined alike keep their join and what it pays: 10 s / 8 s stays at three segments and seals 8 (7 before); 6 s / 6 s / 4 s stays at three and seals 4, unchanged; a shape like 6 s / 5 s keeps a seal that follows the phase (5 in one, 4 in the other), because equalising is about how much a tune loads, not about what it seals.

**What the log says.** The seal line says what was paid (`of which the join pays 5s of 6s (16.000s cut of the 18.000s it listed)`). "The join has no more to give" is a fact the reader states (its join batch is handed over and its consumer is waiting), not arithmetic on EXTINF, which a playlist that rounds its durations up would fail.

**Demuxed audio.** With a demuxed audio rendition the fact is the cutter's rather than one reader's: both join batches handed over and the cutter waiting on either of them. An audio rendition whose segments end a little before the video's runs dry first, and the video reader is then never the one being waited on. Measured with three runs per arm on three listed segments, audio aligned and audio 0.2 s short: first picture 0.18 to 0.21 s against 0.17 to 0.36 s on 7.25.1, TD 5 on 6 s and 9 on 10 s under both profiles.

**A slow join.** A join that is SLOWER than the `.fastZap` grace (a single-connection provider or a slow link) takes the bounded start before the grace is spent, and then seals the full value (6 or 10, not 5 or 9) over a window shorter than its holdback. AVPlayer notes that with a `-16832` warning at the start. Measured one request at a time behind a 4 to 5 Mbit/s link, that start is not worse than 7.25.1's: first picture 5.05 to 6.08 s against 7.05 to 8.26 s, no `-12888` where 7.25.1 drew 1 to 3.

**Net effect on the seal and holdback:**

| Upstream | Before | Now |
| --- | --- | --- |
| uniform 6 s, `.fastZap` | seal 4 (holdback 12 s) | seal 5 (holdback 15 s) |
| uniform 10 s, either profile | seal 7 (21 s) | seal 9 (27 s) |
| alternating 6 s / 4 s, both phases | seal 4 (12 s) | seal 6 (18 s) |
| 3 s segments with 1 s GOPs | seal 2 | unchanged at 2: three joined segments cut 8 s, which pays for no more, so the patience of one delivery this issue is about stays as it is there |

**Costs.**

- **Time to first picture on uniform upstreams** (the join, and with a host that fetches in parallel the time to the first picture) is what it was. Behind an 8 Mbit/s link, three runs per arm: 3.81 to 4.04 s before and 3.80 to 3.85 s after on 6 s segments; 6.15 to 6.36 s and 6.18 to 6.28 s on 10 s ones.
- **A host that allows fewer parallel requests than the join has segments** (`maxConcurrentSourceRequests` of 3 or less) sees its first picture later than before. The gate now waits for the join to be handed over, where it used to serve at 12 s of cut content. One request at a time behind 14 Mbit/s on the mixed shape, three runs per arm: 2.79 to 3.08 s before and 3.27 to 3.28 s after in the four-segment phase; 2.80 to 2.83 s and 3.44 to 3.49 s in the phase that now also loads the extra segment.
- **Standing latency** behind the upstream's edge: 3 s more on uniform 6 s segments, 6 s on alternating 6 s / 4 s and on 10 s ones, 3 s on 10 s / 8 s.

**Measurements.** On loopback against `Scripts/hls-burst-origin.py` (deliveries 3 to 9.3 s apart on 6 s segments), 60 s per run, three runs per arm and row, 7.25.1 against this. First picture is 0.17 to 0.51 s in both arms wherever a row does not say otherwise:

| upstream, profile, segments listed | 7.25.1 | now |
|---|---|---|
| 6 s, `.fastZap`, 3 | TD 4, 1 x `-12888` per run, 2 stalls in 3 runs | TD 5, none |
| 6 s, `.fastZap`, 4 | TD 4, 2 x `-12888` per run, 2 stalls in 3 runs | TD 5, 1 to 2 x `-12888`, no stall |
| 6 s, `.fastZap`, 8 | TD 4, 1 to 3 x `-12888`, 3 stalls in 3 runs | TD 5, 0 to 2 x `-12888`, no stall |
| 10 s, `.fastZap`, 3 / 4 / 8 | TD 7, 1 x `-12888` in 7 of 9 runs, window closed and item rebuilt in 4 of 9 | TD 9, none in 9 of 9 |
| 10 s, `.standard`, 3 / 8 | TD 7, item rebuilt in 6 of 6 runs | TD 9, none in 6 of 6 |
| 6 s, `.standard`, 3 / 8 | TD 6, first picture 6.18 to 6.53 s | unchanged: TD 6, 6.28 to 6.46 s |

**What it does not do:**

- On a 6 s provider `-12888` still comes. Over one 180 s run: 5 of them and a stall before, 3 and no stall after. 7.5 s of patience still loses to a 9 s gap; what changed is the holdback under it. (A join one segment deeper seals 6 and drew none in three such runs; it was measured and not shipped, for the download it costs.)
- `.standard` on 6 s segments still takes about 6.3 s to its first picture, waiting for the next upstream segment, exactly as before. Its seal there is its own `1.5 x cut target` floor, which three joined segments never covered.
- A real outage longer than the holdback's low point stalls under any of these. The capture that started this had 10 of its 110 delivery gaps above 9 s.

#### An HLS source with its own window fills the cushion at the join (6.77.0)

**An HLS source with a window of its own fills that cushion at the join rather than in wall clock.**

The ingest used to enter a live playlist three segments behind the edge. Three joined segments finalize only two downstream, because the last one stays open until the next arrives. The cushion wants three, so the gate then waited one upstream segment duration for content the origin was already holding in its window. The join now takes the coverage its own policy always targeted, which on short segments is several times three.

Measured against `hlsfixture --window 8` with `play --live --fast-zap`, three runs per row:

| Channel | First picture before | After |
| --- | --- | --- |
| 2 s segments | **2.22 s** | **0.20 s** |
| 1 s segments | **0.41 to 1.22 s** | **0.18 to 0.20 s** |

The spread is the second half of the finding: before the change, the number depended on where in the upstream segment cycle the tune landed.

- A window at the three-segment floor has nothing deeper to offer and is unchanged. So is a long-segment provider, whose coverage target was already met inside the old bound.
- The deeper entry is not paid back later. Both arms fetch up to the same upstream segment number at the same wall clock, so it is caught up at I/O speed instead of becoming a standing lag behind the live edge.
- It does not touch a source with no playlist at all (raw MPEG-TS over HTTP). There is no window to enter further back into, and the content does not exist yet.

### The tail after the first serve, and which signal survives it

A serve is not motion. After it, AVPlayer can present the first frame, publish `waitingToPlayAtSpecifiedRate` with `AVPlayerWaitingToMinimizeStallsReason`, and hold that frame perfectly still while it decides whether its cushion will sustain playback.

- A host measured 1.5 to 2.8 s of bit-static picture there on 9 of 11 consecutive tunes on an Apple TV 4K, confirmed against an HDMI capture, with the engine's clock advancing throughout (AE#440).
- Nothing on the item shortens it: `preferredForwardBufferDuration` measured inert, because the wait is a rate evaluation and not a buffer target.
- It does not reproduce on a macOS loopback harness in any window geometry. Treat it as a policy of the player on the device, not as something the served playlist can be shaped out of.

Two consequences for a host:

**Key chrome on `$playbackPhase`, not on `state` or `$hasFirstFrameReadyForDisplay`.** Both of those fire before the rate rolls, and honestly so: one is intent and the other is a picture. `playbackPhase` is `.loading` for the whole hold and turns `.playing` on the roll.

**`liveJoinStartsImmediately` cuts the hold short**, once per load, on a live session, over a buffer AVPlayer reports as non-empty and that carries at least 1.5 s ahead of the playhead. It is the other half of the trade `.fastZap` already prices: playback begins on a thinner cushion, so a source that hiccups just after the join rebuffers where it would otherwise have started later and played through. Every later hold in the session keeps AVPlayer's own policy, so a mid-stream rebuffer is untouched.

**It is on by default since 6.55.0**, based on a device A/B. Two runs of ten channel changes on the reported stack, control then lever:

| | control | lever |
|---|---|---|
| press to moving picture, warm | 6.4 / 6.5 / 7.2 s | 4.3 / 4.8 / 5.1 / 5.6 s |
| press to first PICTURE | 3.4-3.9 s | 3.4-3.9 s |
| stalls / dropped frames | 0 / 0 | 0 / 0 |
| cold joins | ~6.5 s | ~6.5 s |

First picture is unchanged, so the lever removes exactly the frozen tail and nothing else. The cold case is untouched, because the guards keep it out of a starved join. Set it `false` to keep AVPlayer's own policy for the join.

**Why a depth and not just the empty flag.** `isPlaybackBufferEmpty` is the precondition `AVPlayer.h` documents, not a measure of safety: one served fragment reads `false` exactly as a four-second cushion does. Sampling the buffer across every hold in the control run above read non-empty with **3.7 to 4.9 s** ahead of the playhead for the hold's whole duration. So the hold on that stack is always AVPlayer waiting on its own rate estimate, never starvation at the edge. That is why cutting it short cost nothing there. It is also why the guard reads the depth: behind the same `false`, a starved join holds a fraction of a second, and starting there would trade a still picture for an immediate stall.

- The depth is the contiguous span ahead of the playhead, so an island past a gap does not count.
- When the floor is not met the engine says so once per load (`leaving the stall-avoidance wait alone (buffer ahead ...s, ...)`), which separates the two mechanisms in a report after the fact.

**And the item has to be able to play (AE#684).** The depth is measured from the item's own `currentTime()`, and before `readyToPlay` that is where the loader began fetching, not where playback will begin. Under an `EXT-X-START` placement (how a rejoin lands a fresh item at the place the session held), AVPlayer fetches from about 6 s below the target first, so the reading is the lookback itself. One device capture shows `buffer ahead 4.00s` from a playhead of 48.00 s on an item placed at 53.908 s, every second of it behind the start, and `playImmediately` 36 ms before the item was ready. It was the one item of five in that capture to be forced, and the one its viewer reported out of sync; that is a correlation, not yet a mechanism.

A hold on an item that cannot play yet is now left alone (`leaving the stall-avoidance wait alone on an item that cannot play yet ...; asked again at readiness`) and decided again when the item becomes ready, from the playhead it really starts on.

### The rewind depth a live session really has

`seekableLiveRange` is the intersection of the DVR window and what the cache actually holds. `seek(to:)` clamps to it, so a target the range accepts is a target the seek reaches.

The floor is a backward-contiguous walk from the newest resident segment, not the cache's lowest index. A minimum index is not proof of coverage, and a rewind advertised below an interior hole cannot play forward.

History: `seekableLiveRange` used to be `max(0, edgeTime - dvrWindowSeconds) ... edgeTime`, pure arithmetic that never asked the cache. Two regimes where that over-promised, both measured on the loopback harness:

- **The session's own start.** A session that joined a source already 181 s into its timeline advertised a floor of 0.00 for its whole run; a seek to 0.20 landed at 181.66, the first position ever written. The over-promise is exactly the join offset, so it is small on a source whose timeline starts with the session and large on one that does not.
- **Retention shallower than the window.** With `dvrWindowSeconds: 30` on 1 s segments, the cache kept 24 s, and the advertised bound claimed 30.

**Resuming behind live.** When a session has fallen behind, `play()` recovers a playhead that no longer exists:

- it snaps a live-only source more than 45 s back to the edge
- it lands a DVR session whose window has slid past the playhead just above the retained floor

Both are recoveries, not opinions about where a viewer should be, and both are silent (unless the host listens to `liveResumeClamped`). A host with live-pause semantics of its own (a long pause that re-tunes, say) sets `clampsLiveResumeToWindow: false`. Then `play()` moves nothing, and `seekToLiveEdge()` performs the same recovery on request. The engine keeps reporting; the host decides.

**Where did a seek land?** Use `SeekEvent.landed(renderedTime:)` on `$seekEvents`. `await seek(to:)` returns no position, so a harness that records its own requested target reports an intention, not an outcome.

## Recording a live stream

| Symbol | Notes |
| --- | --- |
| `startRecording(to:)` | `async throws`. Records the live source to a file, fed from the connection the session already holds. |
| `stopRecording()` | `async`. Ends the recording and closes the file. Idempotent, and a no-op when nothing is recording. |
| `$recordingState` | A `RecordingState`: `.idle`, `.recording(RecordingProgress)`, `.ended(RecordingEndReason)`, `.failed(RecordingFailure)`. Progress republishes at 1 Hz, not per packet. |

**No second connection is opened.** That is the point of the feature. An IPTV plan commonly caps an account at 1 to 3 simultaneous connections, so a host that opens its own connection to record either fails outright or knocks the viewer off the channel. The engine already holds the one permitted connection and already demuxes every packet.

**What is written.** A **stream copy of the source packets into MPEG-TS**, taken before any audio bridging. Nothing is decoded and nothing is re-encoded.

- A TrueHD or DTS channel records its original audio while playback listens to the bridged FLAC rendition.
- A file cut short by a crash or a kill is still playable up to the truncation, which is why the container is MPEG-TS rather than fragmented MP4.
- The file opens on the first video keyframe after the call, so it starts on a decodable picture rather than mid-GOP.
- It follows the source, not the playhead. Pausing, or scrubbing back inside the DVR window, does not interrupt it.

**Which routes can record.** Only the two where the engine owns the byte path:

| `videoRoute` | Who holds the source connection | Recordable |
| --- | --- | --- |
| `.loopback` | The engine: demuxer, segment producer, local server | yes |
| `.software` | The engine: demuxer, software playback host | yes |
| `.remoteBypass` | AVFoundation, directly against the origin | no |

On `.remoteBypass` (`LoadOptions.nativeRemoteHLS`) the engine never sees a byte, so there is nothing to record without opening the second connection the feature exists to avoid. `startRecording(to:)` throws `.unsupportedRoute(.remoteBypass)` rather than recording nothing. The escape is the one described under [Where the token rotates](#live-the-retune-request): reload with `nativeRemoteHLS: false`, and the session moves onto the ingest reader and `.loopback`. The engine does not perform that reroute by itself: it would visibly interrupt the picture as a side effect of pressing Record, and the routing decision belongs to the host.

**The two reporting channels are separate.** One failure is never reported through both.

- Thrown out of `startRecording(to:)`: conditions a host can act on before anything is written. `.notLive`, `.unsupportedRoute`, `.alreadyRecording`, `.cannotCreateFile`.
- Published through `$recordingState` as `.failed`: conditions that can only be discovered while writing, after the call has long returned. `.diskFull`, `.writeFailed`, `.writeTooSlow`.

**`.writeTooSlow`: the engine drops the recording rather than the picture.** Writes are handed to a bounded queue drained off the demux thread. When that queue fills, the recording ends and says so. A demux thread parked on a slow disk would stall playback, which is not a trade the engine makes.

**A reset ends the recording.** When `liveSourceReset` fires, or the host calls `reloadAtCurrentPosition`, the file is closed cleanly and `$recordingState` publishes `.ended(.sourceReset)`. The recording does not carry on into the same file: a reset can bring back different codecs, different parameter sets or a different program, and writing that into streams declared from the old source produces a file that is unplayable or silently wrong past the seam. The host has the event and starts part two if it wants one. `stop()` and a new `load()` end it the same way with `.ended(.sessionEnded)`; a recording never outlives its session.

**Timing of `.ended`.** It is published once the file is closed. The queued tail and the trailer are written off the main actor, so it can arrive a moment after the call that ended the recording.

- `stopRecording()` returns only after it.
- A `startRecording(to:)` issued in that moment waits for it first. If a `stopRecording()` or a new `load()` overtakes that wait, the start throws `CancellationError` and records nothing.
- A stop that lands while the writer is already tearing itself down after a failure (`.writeTooSlow`, `.diskFull`, `.writeFailed`) waits for that teardown and publishes the failure, not `.ended`.

**Not implemented: recording from the start of what is already buffered.** A recording begins at the call, not at the back of the DVR window. On `.loopback` what is retained is remuxed fMP4 with **bridged** audio, not source packets, so prepending it would produce one file whose audio codec changes in the middle. On `.software` the packet ring does hold source packets, but shipping the behaviour on one route and not the other under one API is worse than not shipping it. If you need it, say so on the tracker rather than working around it.

## Picture, layers and PiP

| Symbol | Notes |
| --- | --- |
| `videoGravity` | Fill mode of whichever layer is mounted (`AVPlayerLayer` or the software display layer). Settable; this is the aspect-fit / aspect-fill control. |
| `AetherStillView`, `bindStillView(_:)`, `unbindStillView(_:)` | Holds the outgoing picture across an item swap, for a host that renders the native path through AVKit rather than `AetherPlayerView`. See [Held pictures across an audio switch](#held-pictures-across-an-audio-switch). |
| `nativePlayerLayer` | The engine's own `AVPlayerLayer`, for a host building `AVPictureInPictureController` around a layer rather than around `currentAVPlayer`. |
| `$softwarePiPSource` | `SoftwarePiPSource` for sample-buffer PiP on the software path. See [Picture in Picture on the software path](#picture-in-picture-on-the-software-path). |
| `$softwareDisplaySize` | The rectangle the software path's picture presents at: coded size under the decoder's pixel aspect. Mirrored, not latched, so a mid-stream resolution change re-shapes it. nil on every other path. |
| `$activeUpscale` | `UpscaleStatus?`: what the low-resolution upscale stage (`LoadOptions.upscalesLowResolutionVideo`, #846) does for this session. See [Upscale status](#upscale-status). |
| `sourceVideoWidth`, `sourceVideoHeight`, `sourceVideoPixelAspectRatio` | The source's CODED size and the multiplier that turns it into the presented one (`width * ratio`), read once from the probe. On `.remoteBypass` it comes from AVPlayer's item video track once it resolves: the delivered size. The ratio is 1 on square pixels and on a declared ratio the engine refuses (#290), never a guess. On the paths that draw, prefer what is on screen (`softwareDisplaySize`, `AVPlayerLayer.videoRect`) over recomputing it here. |
| `pictureInPictureActive` | Host-set. Keeps the pipeline and the loopback server alive across a background transition, and keeps the software path decoding video for the window. |
| `needsForegroundVideoRestore` | True after background policy actually releases the video item. Restore with `reloadAtCurrentPosition(applying:)` before play, choosing the desired transport intent. False when video was retained, or after stop/load. |
| `retainsVideoPipelineWhenBackgrounded` | Opt in to retaining a paused video pipeline through background suspension. Default false. Set before backgrounding. See [Background behaviour](#background-behaviour). |
| `backgroundPlaybackEnabled`, `backgroundTeardownGraceSeconds` | Background audio policy. The grace window (15 s default) is what lets a paused session survive a quick app switch. |
| `presentationAxisMap` | `PresentationAxisMap`: `sourceSeconds(forItemSeconds:)`, `itemSeconds(forSourceSeconds:)`, `shiftSeconds(atItemSeconds:)`, `seams` (each a `PresentationAxisMap.Seam` of `itemSeconds` and `shiftSeconds`), `isEmpty`. Readable off the main actor. Cue times and `sourceTime` live on the source axis; `AVPlayerItem.currentTime()` lives on the item axis, and they differ by the producer shift. Returns nil rather than a guess where no axis is established. |
| `setNativeVideoFrameTimeObserver(_:)` | Takes a `NativeVideoFrameTimeObserver`, called per muxed frame on both axes (`NativeVideoFrameTime`: `source`, `item`, `segmentIndex`, `isKeyframe`, `epoch`). Called on the producer pump thread in **decode** order, so `source` is not monotonic under B-frames. `epoch` rises process-wide. |
| `setSoftwareVideoFrameTimeObserver(_:)`, `softwarePresentationTimebase` | The software-path equivalent, a `SoftwareVideoFrameTimeObserver` over `SoftwareVideoFrameTime` (`presentation`, `generation`), in ascending presentation order, on the same axis as the cues. `generation` moves on every renderer flush. |

### Held pictures across an audio switch

An audio-track switch swaps the item in place, and `replaceCurrentItem` blanks the player layer until the new item's first frame. The engine holds the outgoing picture over that gap on the bound `AetherStillView` (or, without one, on the bound `AetherPlayerView`).

- **Placement.** The still view is transparent and takes no input. Place it above the video and below the host's chrome, for example at the top of `AVPlayerViewController.contentOverlayView`, and set its `videoGravity` to the host player's fill.
- **Software path.** It holds its renderer's last picture across the rebuild the same way.
- **Dolby Vision without a displayable base layer** (Profile 5, AV1 Profile 10) cannot be held as the output vends it.
  - Without the `DolbyVisionStillReshaping` trait, the engine remuxes the resident segment's video into a standalone file, and a player of the surface's own seeks it frame-exactly to the outgoing position. So the system compositor colours the held frame as it colours playback (pixel-identical to the paused outgoing picture on the clips measured; up in 165 to 220 ms on an M1).
  - With the trait, the frame is a 960-wide still decoded through the scrub stills' RPU reshaping.
  - Either way the switch waits for it (up to 3 s, with the outgoing picture paused meanwhile).
- Other profiles hold their base layer.
- Nothing is held in PiP or on external playback.

### Picture in Picture on the software path

`$softwarePiPSource` publishes a `SoftwarePiPSource`: the display layer plus transport answers on the enqueued frames' axis. iOS only in practice; tvOS AVKit does not evaluate sample-buffer content sources (FB9751461).

**Building the controller.**

- `SoftwarePiPSource.isSupported` (static) says whether the system offers PiP at all.
- `makePictureInPictureController()` returns a ready `AVPictureInPictureController` (nil when `isSupported` is false). Its content source uses `playbackDelegate`, a `SoftwarePiPPlaybackDelegate` that maps play, pause, skip (clamped to the VOD duration) and the time range onto the engine's transport.
- The host keeps the controller and sets `pictureInPictureActive` from its callbacks.
- A reload replaces `softwarePiPSource`, and the content source holds its delegate weakly. So rebuild the controller on every `$softwarePiPSource` change.

**Lifecycle.**

- When `state` or `duration` changes, the source invalidates the playback state of the controller it made (the latest one).
- When `softwarePiPSource` becomes nil (the session ended), the engine stops the controller it made and resets `pictureInPictureActive` to false. A host with its own controller closes PiP at that point and treats `pictureInPictureActive` as false.
- Any load on the software path ends PiP the same way, because each load builds a new display layer. (The native path hands the item over instead.)

**Layer geometry.** While `pictureInPictureActive`, a bound `AetherPlayerView` sizes the display layer to the picture's rectangle for the active `videoGravity`, because the window mirrors the layer's own geometry: aspect-fit for `resizeAspect` and `resize`, and the larger aspect-fill rectangle clipped by the view for `resizeAspectFill`. It restores the full-view frame afterwards, and a gravity change during PiP is applied at once. A host that mounts `softwarePiPSource.layer` in its own view must size the layer to the picture itself.

**macOS.**

- The bound view also follows the system PiP window. It is found through public AppKit: a new visible panel with the picture's aspect, when exactly one matches. The search stops after a few seconds, and re-runs when the window goes away, or when the picture's aspect changes while no window is found.
- The layer is laid out at the window's size, so the layer's own `videoGravity` fits the picture. A window matched under a known aspect is kept through later aspect changes until PiP ends, and its size is followed as the window resizes to the new picture. Without a match, the picture-shaped layout stays.
- The system draws an opaque bar over the top of that window for sample-buffer sources, covering part of the picture. There is no public API to remove it or read its height (FB22411168).

### Upscale status

`$activeUpscale` is published on the first upscaled frame, not when the load decides the route. nil while no stage runs, and cleared with the session.

- **Republished with `degraded` true** when a sustained overrun of the frame budget makes a VideoToolbox + MetalFX stage drop MetalFX. Frames then go out at the VideoToolbox output size (`targetSize`), carrying the source's pixel aspect ratio. The overrun is remembered for the process: a stage built later whose MetalFX output is at least that large, at a frame interval at least as short, starts degraded, without MetalFX, from the outset (or with `disabledReason` set when it has no VideoToolbox pass) and logs `[Upscale] starting ML only: ...`.
- **Republished with `disabledReason` set** if the stage cannot be built, or switches itself off after repeated failures or a sustained overrun of a stage that has nothing left to drop. Frames are then delivered as decoded.

### Background behaviour

`retainsVideoPipelineWhenBackgrounded` (default false; set before backgrounding):

- The host accepts that system-invalidated decoder sessions can still need `reloadAtCurrentPosition()`. This saves a rebuild when the pipeline survives.
- It does not enable background playback. A retained session that resumes while still backgrounded gets the playing-session policy then: teardown with background playback off, software audio-only.
- A seek or reload begun from the retained pause defers that decision until it settles, including a Play request received during the operation. A reload that stays paused keeps retention.
- Failed software video queues are flushed on play before the feeder wakes; healthy buffered frames remain.

## Now Playing and the audio session

| Symbol | Notes |
| --- | --- |
| `ownsVideoNowPlayingSession` | Opt in to owning system Now-Playing on the native **video** path. Off by default, and that default matters: an `AVPlayerViewController` host already gets this from AVKit, and opting in costs it AVKit's card, its `externalMetadata` and its transport commands. Read at host creation, so set it before `load()`. |
| `ownsSoftwareNowPlaying`, `remoteSkipInterval`, `softwareNowPlayingActive` | Now Playing for the software host. See [Now Playing on the software host](#now-playing-on-the-software-host). |
| `videoNowPlayingSession`, `setVideoNowPlayingInfo(_:)` | The session and its staged identity dictionary. Elapsed / rate / duration are merged from the player; do not stage them. |
| `audioNowPlayingSession`, `setAudioNowPlayingInfo(_:)` | The same pair for the audio-only path. Pass an empty dictionary to clear. See below. |
| `setExternalMetadata(_:)` | AVKit's on-screen info pane on the video path. Safe before `load()`; replayed at host creation. |
| `deactivatesAudioSessionOnStop` | Off by default. See [The audio session](#the-audio-session). |
| `rendererAudioSessionActivationEnabled` | Default `true`. See [Host-managed renderer audio activation](#host-managed-renderer-audio-activation). |
| `logTag` | A short name for this instance (`tile2`), carried by the `[SharedOutput]` lines and a `[AetherEngine:<tag>] state=` line per transition. Set it before `load()` (the tag is captured when the engine joins), on every engine of a host that runs several at once. |

**`audioNowPlayingSession` on the two audio-only hosts.**

- The AVPlayer host (`AudioAVPlayerHost`) owns its session unconditionally (there is no AVKit fork there).
- The FFmpeg host (`AudioPlaybackHost`) has no session, so the property is nil there and the host drives Now Playing through the shared centers. The FFmpeg host serves: codecs off the AVPlayer whitelist, a custom `IOReader`, a FLAC under CoreMedia's block floor, a FLAC whose frames are smaller than its `STREAMINFO` declares, any raw `.flac` file, and `preferredDecodePath = .software`.

### Now Playing on the software host

`ownsSoftwareNowPlaying` opts the software host (the Dolby Vision FEL route, which has no `AVPlayer`) into publishing its own Now-Playing card on the shared `MPNowPlayingInfoCenter` and serving play, pause, toggle, skip and change-position from `MPRemoteCommandCenter.shared()`.

- Off by default, and independent of `ownsVideoNowPlayingSession`, so the native path is untouched. A secondary role never takes it.
- Identity comes from `setExternalMetadata`, overlaid by `setVideoNowPlayingInfo`.
- `remoteSkipInterval` (default 10 s) sets the skip buttons.
- `softwareNowPlayingActive` is true while the engine is publishing: the cue for a host to register next/previous.

The centers are process-wide. The engine writes `MPNowPlayingInfoCenter.default()` and registers its own targets on `MPRemoteCommandCenter.shared()`. At stop it:

- removes only those targets
- restores each command's `isEnabled` to its value before the session; a command another owner changed meanwhile keeps that owner's `isEnabled`
- clears the info and playback state only while the center still holds what the engine last published (matched on elapsed, rate, title and duration), so a host that took over meanwhile keeps its card

### The audio session

**`deactivatesAudioSessionOnStop`** (off by default). The engine declares the audio-session category at the first load and never activates it on the native path, because AVKit activates per playback and that is what lets tvOS negotiate the HDMI route (#24). So it never deactivates it either.

- Set it true only when the app owns the session outright. The engine then releases it on a genuine final teardown: `stop()`, never a reload, handoff or live retune.
- With several engines in one process the release belongs to the last one out. A stop while another engine is still active keeps the session and logs `[SharedOutput] ... still active, session kept`.

### Host-managed renderer audio activation

`rendererAudioSessionActivationEnabled` defaults to `true`. Set it to `false` before loading when the host coordinates audible focus and owns `AVAudioSession.setActive(true)` across multiple players.

- Software and audio-renderer loads, track reloads and interruption recovery then skip engine-driven activation and channel preference changes.
- The host must activate the session before audible playback.
- The category and multichannel support are still declared off-main by the first load in the process, shared by concurrent engines, and never repeated after a success. So a host that changes the mode afterwards keeps it.
- A session the host already put on `.playback` before that first load keeps its mode and policy.
- Native AVKit activation is unchanged.
- If the host also owns deactivation, leave `deactivatesAudioSessionOnStop` false (its default).

## Stills and thumbnails

Two families: cache-backed stills from the active session (no second connection), and `FrameExtractor` for stills off playback.

### Stills from the active session

| Symbol | Notes |
| --- | --- |
| `scrubThumbnail(atSeconds:maxWidth:)` | Cache-backed still for the active session, live or VOD. Decodes bytes the session already holds, so it opens no second connection and works on single-connection sources (debrid / torrent links, IPTV accounts capped at one request) where a second demuxer is refused. A native session decodes from its segment cache; a software session from its packet cache (VOD, AE#605) or its DVR packet ring (live, #544). A VOD target outside what is retained returns nil rather than the nearest retained frame. |
| `vodScrubThumbnail(atSeconds:maxWidth:)`, `liveScrubThumbnail(atSessionSeconds:maxWidth:)` | The two arms, for callers that know which axis they hold. Both arms also serve software sessions: the live arm out of the DVR packet ring (#544), the VOD arm out of the packet cache its seeks land in (AE#605), keyframe to target, on the same axis `seek(to:)` takes. |
| `supportsCacheBackedStills` | True while the session can serve `scrubThumbnail` without a second connection. See below. |
| `scrubPreviewFrame(atSeconds:refined:maxWidth:isCancelled:)` | The timestamped form of `scrubThumbnail`. See [Timestamped scrub frames](#timestamped-scrub-frames). |
| `scrubPreviewDrawsInView`, `showScrubPreview(atSeconds:in:)`, `AetherScrubPreviewView`, `ScrubPreviewPlacement` | The scrub preview for Dolby Vision without a displayable base layer. See [Scrub previews for Dolby Vision Profile 5](#scrub-previews-for-dolby-vision-profile-5). |
| `scrubPreviewSourceGeneration` | A fresh `UUID` on every teardown, distinct across engine instances, so a host can fence a preview that resolved after its source went away. |
| `clearResidentPreviewFrames()` | Cancels in-flight resident previews and drops their cached approximations; playback media is untouched. |

**`supportsCacheBackedStills`** is true for any native session, a software live session, a software VOD session reading a remote source, and one playing a local file. False before load.

- Gate the scrub-preview affordance on it. It reports capability, not per-frame availability. A transient nil from `scrubThumbnail` while a segment is still being produced, or for a position the cache does not hold, is expected and means "time only, no image".
- A software session playing a local file keeps no packet cache, so its stills are decoded from the file by a `FrameExtractor`. No connection is opened, `scrubPreviewFrame` honours `isCancelled` and the 750 ms / 900 packet bound and reports the decoded frame's own time as `actualSeconds`, and a Dolby Vision Profile 7 title shows its base layer. A file URL on a network mount opens a second file handle to that mount.
- A Dolby Vision Profile 5 / 10.0 source without the `DolbyVisionStillReshaping` trait reads false here; `scrubPreviewDrawsInView` is its preview.
- Before AE#605 this was false on every software session, live included.

### Timestamped scrub frames

`scrubPreviewFrame(atSeconds:refined:maxWidth:isCancelled:)` is for a preview that labels the frame it shows rather than the position asked for.

- It reads only resident native segments or software packets, never seeks playback, and never opens a second source.
- It returns a `ScrubFrame`: the image, the measured `actualSeconds` on the same axis `seek(to:)` takes, `refined`, and the resident `validRange` the frame's run covers.
- `refined: false` stops at the first decoded frame (cached per segment at the same width). `true` decodes toward the target, and `refined` in the result means that decode reached it, not that the two times are equal.
- Missing, cancelled, replaced or stale work returns nil.
- Decode is bounded at 750 ms and 900 packets per request.

**The keyframe still ladder.** On a native VOD session, a position no resident segment covers is answered by the keyframe still ladder instead of nil.

- The engine builds the ladder only while the origin has nothing in flight: no pump range open, nobody queued, no refusal in the last two minutes, at least 30 s buffered ahead, and 15 s into the session.
- It reads one keyframe every 2 s off the source: first one a minute across the whole title, then one every 30 s, nearest the playhead first. It goes through the same per-origin request budget the pump uses, so a plan that allows one connection never sees two at once.
- A ladder frame is the nearest rung within 60 s (at or before the target, else after it) and is never refined. Its `actualSeconds` and `validRange` name the rung's own segment, so a host can tell it from a frame at the target.
- The lookup itself never touches the source.

### Scrub previews for Dolby Vision Profile 5

This is the scrub preview for Dolby Vision without a displayable base layer (Profile 5, AV1 Profile 10.0) on a native VOD session. Its base layer is IPT-PQ and no still API applies the RPU, so no `CGImage` of it can be correct; only the system compositor colours it.

- `scrubPreviewDrawsInView` is true for such a session in a build without the `DolbyVisionStillReshaping` trait. With the trait, the session serves reshaped stills through `scrubThumbnail` (and the still ladder and I-frame rendition), and `scrubPreviewDrawsInView` stays false.
- `showScrubPreview(atSeconds:in:)` takes the same playlist/output seconds as `scrubThumbnail`. It cuts the keyframe that opens the plan segment holding them into a standalone one-sample fMP4, and shows it in the `AetherScrubPreviewView` through that view's own muted `AVPlayer`.
- **Inside the resident window** the keyframe comes out of the segment cache, with no second connection.
- **Outside it**, the engine reads that keyframe off the source with a side demuxer of its own, the way the I-frame rendition reads its entries (seek to the segment's start, one packet, nothing decoded). It wraps it with the session's own sample entry, `dvcC` and `colr`: byte-identical to the source's keyframe, and the same picture the cache would give. That read is withheld where the I-frame rendition would be (a plan whose boundaries are not keyframes; a sequential, serial or held-connection origin; a disc; a source not reopenable by URL). It waits out a seek or producer restart, and skips a request a newer one has superseded. Those cases answer nil.
- The result is a `ScrubPreviewPlacement`: `actualSeconds` of the keyframe on screen and the `validRange` of its segment.
- Requests on one view are latest-wins. The outgoing picture stays up until the next one is displayable (two players alternate), so a superseded or failed request leaves the previous picture.
- Call `clear()` when the preview is hidden, which releases the view's decoders.
- Measured: 26 to 45 ms from request to picture on an M1 for a new segment, 1 ms for the one already shown, and a 4K preview next to 4K Profile 5 playback on an Apple TV 4K (3rd generation) without disturbing it.
- Never attach an `AVPlayerItemVideoOutput` to a player meant to show such a picture: AVFoundation switches the Dolby Vision processing off for the layer as soon as one is attached.

### `FrameExtractor`

`FrameExtractor` takes stills off playback: `thumbnail(at:maxWidth:)`, `preview(at:maxWidth:)`, `snapshot(at:maxSize:)`, `prewarm()`, `shutdown()`, over a URL or an `IOReader`. It opens its own demuxer, so it needs a source that tolerates a second connection.

| Mode | What it returns |
| --- | --- |
| thumbnail | A coarse keyframe, on the cheaper decode path. |
| `FrameMode.preview` | Decodes forward to the requested time at `maxWidth`. |
| `FrameMode.snapshot` | Native or bounded dimensions. |

- `maxSize` bounds apply after sample-aspect correction, so anamorphic stills fit both dimensions. HDR tone mapping uses the same square-pixel dimensions and native-width cap as SDR.
- Preview and snapshot decoding keep full reconstruction and bicubic scaling (HDR tone mapping included; the `DolbyVisionStillReshaping` converter still samples nearest-neighbour).
- Cache entries include the requested dimensions, so one extractor may serve several sizes. Thumbnails reuse their position bucket. Previews (own count-bounded cache) and snapshots reuse only an identical requested time, so adjacent frame requests stay distinct.
- Previews yield on uncached requests while `yieldWhile` reports starvation, and are cancelled by superseding extraction or `shutdown()`.
- This API shares ordinary extraction cancellation and HTTP read timeouts. Use `boundedSnapshot` when a caller-supplied total deadline is required.

**`boundedSnapshot(at:maxSize:limits:cancellation:)`** is the disposable form. One caller-supplied `ProbeLimits` / `ProbeCancellation` budget spans open, stream analysis, seek and decode, a stalled HTTP header included, and the result is a `BoundedStillFrame`. Use a fresh extractor: an already-open context is refused rather than charged to the budget. The context closes on every outcome.

**One current request per extractor.** `FrameExtractor.thumbnail`, `preview`, `snapshot`, `boundedSnapshot` and resident previews share one current request per extractor.

- A valid request supersedes an older decode, even when the newer result is cached or yields to playback.
- Cancelling its awaiting Task cancels that request. A cancelled or superseded request returns nil instead of publishing a late image.
- Requests with invalid timestamps, and already-cancelled requests, do not replace another caller's work.
- Replacement is intentional across modes: even a cached ordinary or resident preview cancels an in-flight `boundedSnapshot` and its caller-supplied `ProbeCancellation`. Use separate extractors for independent concurrent requests.
- Cancellation is cooperative between decode steps; an in-flight source read still uses its normal timeout. Use `boundedSnapshot` for an explicit total deadline.
- Cancellation and playback yield still schedule idle cleanup of an opened context. A superseded completion cannot reset the newer request's idle timer.

## Certificate trust

A media server behind a self-signed or private-CA certificate is common in self-hosted setups. URLSession refuses it, where the in-demuxer network stacks the engine replaced never did. A host whose own API layer bypasses trust therefore ends up split: browsing works, and every engine fetch fails its handshake before a byte is read.

| Symbol | Notes |
| --- | --- |
| `EngineTLS` | Trust policy for the engine's outbound HTTP connections. Off by default: no evaluator is set and every challenge keeps the system's default handling. |
| `EngineTLS.serverTrustEvaluator` | `(@Sendable (URLProtectionSpace) -> Bool)?`, asked per challenge about the origin the challenge came from. nil, the default, keeps default handling everywhere. Read per challenge, so replacing it applies from the next connection without rebuilding sessions. Called off the main actor from whichever queue raised the challenge, so it has to be thread-safe. |

```swift
EngineTLS.serverTrustEvaluator = { $0.host == "media.lan" }
```

It is a per-origin closure, not a flag, because a host commonly holds a LAN address behind a private certificate and a WAN address with a real one, and accepting the first must not quietly relax the second. A host that pins an SPKI hash reads the protection space and decides. Returning true for everything is the blunt version and is one line.

**Coverage.** This governs the sessions the engine owns, and the one route where AVPlayer does its own networking is covered too. On native remote HLS the origin URL would go to `AVURLAsset`, which asks no delegate about the certificate and which an ATS exception does not reach. So the engine stands a loopback relay in front of the origin and makes the request itself.

- That happens only for an origin the system actually refuses. One handshake decides, since an origin the system trusts is one AVPlayer reaches unaided.
- Media is relayed as it arrives rather than read whole, so the player's first byte and its throughput estimate are the origin's, not the loopback's.
- Nothing about this is configurable: setting an evaluator is the whole opt-in.

A certificate the host does not accept still reaches the host as `PlaybackErrorKind.sourceCertificateRejected` rather than as unreadable media, on the relayed route as well.

## Diagnostics

| Symbol | Notes |
| --- | --- |
| `AetherEngine.version` | The engine release this source descends from, as the string a published tag carries. SwiftPM resolves a package to a revision rather than to a tag, so an About panel or the header of a diagnostic log has nothing else to name the engine with. Between releases, and under a pin on an unreleased commit, it names the last published version the checkout descends from. |
| `diagnostics.liveTelemetry` | 1 Hz `LiveTelemetry?` snapshot while playing or paused, nil while idle. See [Live telemetry](#live-telemetry). |
| `LiveTelemetry.softwareCacheSeekHits`, `softwareCacheSeekMisses`, `softwareCacheSourceEpoch` | Optional cumulative software-VOD packet-cache counters. A hit repositions the retained consumer cursor without changing the source epoch; a miss repositions the demuxer and advances it. `nil` on other paths. `cachedBytes` includes retained compressed packet records on software VOD, distinct from decoded `displayCushionSeconds` and the underlying byte-reader window. |
| `LiveTelemetry.objectAudio` | An `ObjectAudioActivity` while `objectAudioRendering` plays TrueHD Atmos or DTS:X. See [Live telemetry](#live-telemetry). |
| `diagnostics.sessionCacheStatus` | The VOD session cache's budget and state. See [Session cache budget and status](#session-cache-budget-and-status). |
| `EngineLog.handler` | Mirror every info-level line into a host capture path. Fires from whatever thread emitted it, so it must be thread-safe and non-blocking. |
| `EngineLog.structuredHandler` | `handler` with each line's `Category` and `Level` passed along (AE#897), for a log viewer that files or filters lines by subsystem instead of guessing from the `[Prefix]` at the start of the text (a convention, not API, and absent on some lines). Same redacted lines, same order, same threading rules. Independent of `handler`: install both and each gets every line. The level is always `.info` today, because `.verbose` never reaches a host handler. |
| `EngineLog.subsystem`, `EngineLog.Category` | `de.superuser404.AetherEngine`, one category per subsystem: `engine`, `ffmpeg`, `session`, `muxer`, `demux`, `hls.server`, `audio.bridge`, `sw.playback`, `scrub`. |
| `EngineLog.Level` | `.info` reaches os_log and the host handler. `.verbose` is per-segment trace and reaches os_log's debug level **only**, never the handler, which keeps a mirrored stream readable. Read the verbose ones with `log stream --level debug`. |
| `EngineLog.registerSecret(_:)`, `EngineLog.unregisterSecret(_:)`, `EngineLog.redacted(_:)` | Name a value that must never be logged. See [Log redaction](#log-redaction). |
| `EngineLog.emit(_:category:level:)` | Emit a host line into the same stream, for a host that wants its own events interleaved with the engine's. |
| `segmentCacheDiskBytes`, `softwareHostFramesEnqueued` | Point reads for a stats overlay. |
| `activeProducerShiftSeconds`, `frameAhead`, `clockLeadSeconds` | Divergence diagnostics for tracing a clock that disagrees with the picture. Not for production playback logic. |
| `nativeItemReading()` -> `NativeItemReading?` | AE#509. The native item's own account of itself. See below. |

**`nativeItemReading()`** returns `playhead` (`AVPlayerItem.currentTime()`, on the ITEM axis), `loadedRangeCount` (0 = nothing has been PLACED, which no buffer depth can say) and `status` (0 unknown, 1 ready, 2 failed). Async, read off the main actor. nil when no native item is mounted. The engine's published clock is `item + playlistShiftSeconds`, so on a live source hours into an encoder clock the two are thousands of seconds apart in a healthy session: quote both or neither.

### Live telemetry

`diagnostics.liveTelemetry` lives on a separate `ObservableObject`, so its ticks cannot re-render a host observing the engine.

**On the loopback and software routes**, `instantBitrateMbps` and `averageBitrateMbps` are the rate of the MEDIA played, not of the transfer (AE#514): the bytes of the played video and audio packets the playhead crossed, over the media seconds it crossed. That is about the last 10 s for the first, and the whole session for the second. Read-ahead, a re-fetch after a seek, and a paused live source draining into its DVR window do not move them, and both stand still through a pause. The transfer is `networkThroughputMbps`.

**On `.remoteBypass`** it is fed from AVPlayer's access log alone:

- `instantBitrateMbps` and `averageBitrateMbps` are what the playing variant declares (BANDWIDTH, and AVERAGE-BANDWIDTH, or BANDWIDTH where the master omits it). The bytes AVPlayer transferred are buffer fill at link speed, not the stream's rate.
- `networkThroughputMbps` is the access log's `observedBitrate`.
- `networkTransferredBytes` and `droppedFrameCount` are its session totals.
- `forwardBufferSeconds` is the loaded range ahead of the playhead.
- `avSyncGapMs` and `observedFps` are nil.
- The loopback counters (`producerRestartCount`, `muxedBytesLifetime`, `serverBytesSentLifetime`, `serverRequestCount`, `demuxerBytesFetched`) read 0 because there is no loopback.

**`LiveTelemetry.objectAudio`** is reported on the loopback route and on the software host alike. It is nil on every other audio path, and always nil in a build without the `TrueHDObjectAudio` / `DTSXObjectAudio` traits. It reports:

- `layout`: the bed the presentation is rendered into
- `objects`: the objects it declares
- `activeObjects`: how many of them its latest metadata update plays
- `elevatedObjects`: how many of those sit above ear level with elevation allowed
- `heightChannels`: its bed channels on height speakers (where DTS:X's standard presentation carries its four heights)

Counted from the metadata, as the `bed levels` log line is: an active object can be silent. A seek zeroes the playing counts until the decoder restates them.

### Log redaction

`EngineLog.registerSecret(_:)` names a value that must never be logged, such as an IPTV password the host holds. Every line reaching os_log or the handler has it replaced, raw or percent-encoded, wherever it sits.

- The engine already strips named parameters, `Bearer` / `Basic` credentials, userinfo, encoded payloads and the Xtream Codes path layout on its own, also inside a URL carried percent-encoded in another URL's query. This covers what only the host can know, such as a provider URL carrying the password as a bare path segment.
- Registrations are counted: a value registered twice stays redacted until it is unregistered twice.
- Returns false for a value under four bytes.
- `redacted(_:)` returns a line as the handler would receive it, for a line a host or tool prints itself next to the engine's.

### Failed live starts

A failed live start keeps `PlaybackErrorKind.liveSourceUnavailable`, with its original URL error in `underlyingDomain` / `underlyingCode`.

- That cause is diagnostic data only. A transport failure at open is still ridden out by the reconnect ladder, and the URL error is attached when the start finally gives up.
- HTTP refusals remain `sourceRefused` / `sourceRateLimited`, and TLS trust failures remain `sourceCertificateRejected`.
- Keeping a cause does not reclassify a dead live channel as a VOD `sourceOpenFailed`.
- `HLSIngestError.playlistUnreachable(status:)` also carries refused segment or AES key requests; its historical name and NSError case code are kept.

### Source network events

`SourceNetworkDiagnostics.handler` optionally observes real source-request events.

- It is a process-wide observer and runs on the emitting thread, so a host callback must be thread-safe and non-blocking.
- Events from simultaneous players can interleave. Filter by captured context or request identity, not arrival order.
- Installing a handler does not change request or TLS policy.

**Event shape.** `SourceNetworkDiagnostics.Event` carries a per-request `requestID`, `role`, `phase`, status/URL error code, byte/timing metrics and optional `context`. All event fields are immutable. `SourceNetworkDiagnostics.Role` and `SourceNetworkDiagnostics.Phase` are string-backed structs with stable `rawValue` tokens and `init(rawValue:)` for future values. Hosts should handle unknown values.

| Roles (raw value) | Phases (raw value) |
| --- | --- |
| `persistentRead` (`PersistentRead`) | `response` |
| `chunkFetch` (`ChunkFetch`) | `redirect` |
| `streaming` (`Streaming`) | `completed` |
| `probe` (`Probe`) | `metrics` |
| `tailPrefetch` (`TailPrefetch`) | `bodyLimitExceeded` (`body_limit_exceeded`) |
| `hlsPlaylist` (`HLSPlaylist`) | `abandoned` |
| `hlsSegment` (`HLSSegment`) | |
| `hlsKey` (`HLSKey`) | |
| `boundedBody` (`BoundedBody`) | |

**Privacy.** Events contain no response bodies, header values or localized errors. Their `originalURL` and `url` are raw source URLs for host-side correlation: the host must redact them before persistence or forwarding, and must choose its own logging and retention policy.

**Attributing requests to a playback.** Set `LoadOptions.sourceDiagnosticsContext` to a `SourceNetworkDiagnostics.Context(playbackID:attemptID:)` before `load()`.

- Both UUIDs are opaque host-owned identifiers. The engine neither creates a host session nor sends the identifiers in HTTP headers or URLs.
- The optional task-local `SourceNetworkDiagnostics.context` supplies the same context while constructing a standalone `HLSLiveIngestReader(playlistURL:httpHeaders:diagnosticContext:)` or other instrumented reader. An explicit `diagnosticContext` selects that reader's context instead.
- AVIO readers capture it at initialization and pass it explicitly to probes, ranged reads, reconnects, chunk fetches, streaming and tail prefetch, including requests started on detached or FFmpeg threads.
- HLS playlist, segment, key and carriage-probe requests capture their context at creation, keep it through redirects/completion, and keep the source's context across internal reader reloads.
- A late event keeps the outgoing attempt's identifiers.
- A request without context stays unattributed. A handler must not fill it from whichever player happens to be active when it arrives.
- The context is load identity: `reloadAtCurrentPosition(applying:)` refuses a changed context before teardown, keeping the running session and its attribution intact.

**The held HTTP/1 HLS transport** emits the same event contract:

- A streamed body emits `completed` only when it ends or fails, `body_limit_exceeded` when its bound is exceeded, and `abandoned` when the consumer drops or abandons it.
- The byte count excludes bytes discarded by a background drain.
- An open that fails after a response head arrived reports the hop that answered (the redirect target, not the original URL) and that head's status.

AVPlayer's own internal network requests are not exposed, and a source path without instrumentation or captured context cannot be attributed by this API.

### The `open timings` line

Every playback, probe and restart open logs one `[Demuxer] open timings (<reader>)` line in the `demux` category: `connect`, `open_input`, `find_stream_info` and `total` in ms, the stream count and the probe budget (`probesize N MiB, analyzeduration N s`).

An open that ran the stream analysis appends how it ended, after the budget:

`; probe stop=<resolved|probesize|analyzeduration|eof|read-error|stopped|interrupted>, unresolved=<n>, programs=<n>, pmtMissing=<n>, headerWait=<released@Nms|->, probeBytes=<n>, closeToReturn=<Nms|->`

- `stop` is the first cause that applies: a close (`stopped`), a probe limit or cancellation (`interrupted`), a read error, the end of the input, every stream resolved with no header wait left (`resolved`; FFmpeg's own frame-rate and first-timestamp checks are not visible here, so a pass that spent its duration budget on those reads `resolved` too), the byte budget, otherwise the duration budget.
- `unresolved` counts the audio and video streams still missing their size, or their sample rate and channels.
- `pmtMissing` counts the MPEG-TS programs whose PMT never arrived, and `headerWait` says when the engine released the wait for one (see [A PAT program that never sends its PMT](formats.md#raw-live-mpeg-ts-and-the-live-join)).
- `probeBytes` is what the analysis read from the source, `closeToReturn` how long it took to end after a close.

A failed analysis adds `; find_stream_info failed (<code>)` after those fields. The line carries no URL, header or payload.

### Native video frame diagnostics and recovery

**`LoadOptions.nativeVideoFrameDiagnostics`** opts into decoded-frame observation on SDR native loopback playback. Default `false`.

- Excluded: remote bypass, HDR, external playback, mobile background activity, PiP (including its foreground transition), pause and seek.
- An additional `AVPlayerItemVideoOutput` samples frame timestamps without suppressing the player layer or retaining pixel buffers.
- `EngineLog` reports output progress, gaps/resumption and observation-task delays.
- A decoded output gap is not proof of a physical screen freeze. Unavailable output is reported explicitly, and the observation never seeks, retries, changes decoder routing or publishes a playback error.

**`LoadOptions.nativeVideoFrameRecovery`** separately opts into bounded recovery when an SDR native-loopback output that previously yielded pictures stops advancing while the item clock continues. Default `false`; enabling diagnostics alone does not enable this policy.

- Recovery enables the same sampling, excludes unavailable/stale observations and the modes above, and uses the same bounded, current-position repair as missing-layer recovery.
- Short gaps are observed without intervention. Recovery does not promise to reconstruct source pictures that never arrived.
- Healthy decoded progress, not a transient readiness flag after a swap, rearms it.
- The `aetherctl play --native-video-frame-recovery` flag exercises the same policy.
- `ReplayVideoBoundary` logs numeric counts of damaged, replaced and unreplaced pictures at confirmed seams, separately from the number of duplicates removed. `superseded` counts conflicting unflagged copies resolved within the verified pending batch; `untimed` counts unpositioned fragments discarded from the held damaged boundary. Unrelated source timestamp resets do not grant this authority.

**Native presentation recovery**, also enabled by `nativeVideoFrameRecovery` and off by default, watches the player layer's readiness.

- If a previously visible, attached video layer stays unready while foreground playback has both clock progress and buffered media, the engine first seeks to its current position, and can then replace the consumer item in place.
- It keeps the live source, retained DVR and current position. A live replacement is deferred when that position cannot be placed in retained media.
- Recovery is bounded until a sustained healthy presentation rearms it.
- Excluded: PiP, external playback, user pauses, seeks, hidden surfaces and buffering.
- `pictureInPictureActive` must be set before the PiP transition starts and cleared when it ends (also on a failed start), so a legitimately unready inline layer is never treated as missing video.
- `EngineLog` reports readiness, buffer, PiP/foreground eligibility and repair/resumption separately from optional decoded-output samples.

### Session cache budget and status

**The budget.** `LoadOptions.sessionCacheByteBudget` is an optional byte request for the temporary VOD cache.

- Nil keeps automatic sizing: the existing 2 GiB default (relaxed for an explicitly large forward window), the volume safety clamp, and process-wide `RetentionClaims` allocation stay in force.
- Explicit requests are nonnegative and clamped to one quarter of the capacity left after other sessions' unwritten claims. Unknown capacity keeps the 2 GiB ceiling.
- Zero requests window-only operation, not zero memory or zero disk I/O: nothing outside the playback window is retained, and the producer parks once it is 10 segments ahead. Any request the volume clamp reduces to zero gets the same.
- The software disk path keeps a bounded working spool (its existing packet-retention mechanism, not the fMP4 segment window). The tvOS memory-store default and live DVR retention policies are unchanged.

**The status.** Observe `diagnostics.sessionCacheStatus` on `EngineDiagnostics`, separately from the engine's UI state. `SessionCacheStatus` reports:

- `route` (`SessionCacheRoute`: `none`, `loopbackFMP4`, `nativeRemoteHLS`)
- `capability` (`SessionCacheCapability`: `inactive`, `active`, `unsupported`)
- `requestedBudgetBytes`, `volumeSafetyLimitBytes`, `baseEffectiveBudgetBytes`, `playbackSafeFloorBytes`, `effectiveBudgetBytes`
- `currentResidentBytes`, `currentForwardBytes`, `forwardWindowSegments`, `backwardWindowSegments`
- `producerParked`, `evictionCount` and `hardWindowFloorExceeded`
- `cleanupReason` (`SessionCacheCleanupReason`: `sessionStopped`, `sourceChanged`, `loadFailed`) and `cleanupResult` (`SessionCacheCleanupResult`: `notRun`, `succeeded`, `failed`), describing asynchronous deletion after the producer stops
- `lastFailure` (`SessionCacheFailureReason`: `sessionDirectoryCreationFailed`, `writeFailed`, `adoptFailed`, `staleSweepFailed`, `cleanupFailed`), a credential-free category

What the values mean:

- A protected playback window can exceed the byte request. The snapshot reports that, instead of claiming a strict cap that could starve playback.
- Live fMP4 sessions report `unsupported` for this VOD byte policy and keep their separate live DVR limits.
- Closed caches report `inactive` with the final cleanup result. `inactive` is the empty snapshot.
- The detailed snapshot describes fMP4 segment caching. Remote HLS is AVPlayer/server managed and reports unsupported, not successful zero-byte caching; `nativeRemoteHLS(requestedBudgetBytes:)` constructs that unsupported route state.
- Software packet storage keeps its existing separate telemetry.
- Old-session callbacks cannot replace a newer session's state.

**Direct `HLSVideoEngine` users** may call `sessionCacheStatus()` off the main thread and receive lifecycle updates through `onSessionCacheStatusChanged`. `stop(reason:)` records the cleanup reason; the existing zero-argument `stop()` and its callback type remain available.

**Cost and cleanup.** Engine sampling reads the in-memory byte ledger off-main at the existing telemetry cadence, without enumerating files on the UI thread. Successful cleanup removes the complete session UUID directory. A bounded startup sweep removes eligible abandoned siblings; it never adopts their bytes or supplies an offline/cross-launch cache.

## Optional components

Five parts of the engine are compiled only with their package trait, all off by default ([Installation › Optional components](installation.md#optional-components)). The options that ask for them stay in the API and are no-ops without the trait. So a host compiles the same either way, and asks at run time whether a setting would do anything:

| Symbol | Notes |
| --- | --- |
| `AetherEngine.OptionalComponent` | `CaseIterable`. Cases: `.trueHDObjectAudio`, `.dtsxObjectAudio` (`objectAudioRendering` per codec), `.dualLayerDolbyVision` (`preferDualLayerDolbyVision`), `.dolbyVisionStillReshaping` (stills of Dolby Vision Profile 5 / AV1 Profile 10.0 sources), `.dolbyVisionFelCurves` (a Profile 7 FEL source's enhancement layer folded into the Profile 8.1 RPU on the native route, the stream's mapping kept and its luma curve lifted per scene; on whenever built in, `foldsDolbyVisionFEL` turns it off per load, and it pauses on its own on a tvOS HDR10 panel without Dolby Vision, see [dolby-vision-fel.md §7](dolby-vision-fel.md#7-curve-fold-on-the-native-route)). |
| `OptionalComponent.isBuiltIn` | Whether this build carries the component. Fixed for the process; hide a toggle whose component reads false. |
| `OptionalComponent.traitName` | The package trait that compiles it, for a diagnostics screen. |

**Without `DolbyVisionStillReshaping`**, a Profile 5 / 10.0 source yields no still rather than a wrong one (its planes are IPT, which the standard path would read as YCbCr):

- `scrubThumbnail`, `scrubPreviewFrame` and the extractor's stills return nil
- `supportsCacheBackedStills` is false
- the I-frame rendition is absent (`dolbyVisionStillsNotBuiltIn`)
- an audio switch holds no picture

The session log says so once per session. Playback itself is unaffected.

## LoadOptions

All fields default to safe values; the tables below are the full set. Options with a longer contract have a details section after the tables. Depth for the media-shaped ones is in [formats.md](formats.md).

A "tuning field" is one `reloadAtCurrentPosition(applying:)` can correct on a running session. `isLive`, `audioOnly`, `nativeRemoteHLS`, `sequentialOrigin`, `sourceDiagnosticsContext` and `heldSourceConnection` name the session and cannot be corrected (see [Correcting a `LoadOption`](#correcting-a-loadoption-without-restarting-the-item)).

### Source and network

| Option | Default | What it does |
| --- | --- | --- |
| `httpHeaders` | empty | Extra headers on every probe, range and segment fetch. On `nativeRemoteHLS` they ride into the `AVURLAsset`, so header-enforcing IPTV origins work. Forwarded to sidecar subtitle fetches unless overridden. **Scoping differs by route**: see [`httpHeaders` scoping](#httpheaders-scoping). |
| `sourceDiagnosticsContext` | nil | Optional opaque `SourceNetworkDiagnostics.Context` kept by AVIO/HLS requests and internal reloads for host-side diagnostics. No wire headers, request-policy or playback effect. See [Source network events](#source-network-events). |
| `maxConcurrentSourceRequests` | nil | Most requests the reader may have open against this origin at once. See [`maxConcurrentSourceRequests`](#maxconcurrentsourcerequests). |
| `sourceOpenPolicy` | `SourceOpenPolicy()` | HTTP VOD opening budgets: `firstByteTimeout` (15 s) and `sizeProbeTimeout` (25 s). See [`sourceOpenPolicy`](#sourceopenpolicy). |
| `heldSourceConnection` | false | Ask the source **once** and pull it, instead of asking again every 8 to 16 MB of drain (AE#377). **Names the session.** See [`heldSourceConnection`](#heldsourceconnection). |
| `sequentialOrigin` | false | Declare an origin that fabricates range answers: one long-lived unranged GET, no ranged probes, non-seekable pb. See [`sequentialOrigin`](#sequentialorigin). |
| `declaredDurationSeconds` | nil | Trusted duration, overriding the container's. Required alongside `sequentialOrigin` on VOD, where the tail read is gone. |
| `probesize`, `maxAnalyzeDuration` | nil | Caller-bounded open-time probe budget (defaults 50 MB / 60 s). They fail **open**: an over-tight budget loads with late-resolving tracks silently missing rather than throwing, so validate track presence if you tighten them. Do not pass `0` for `maxAnalyzeDuration`; FFmpeg maps it to a shorter heuristic. |
| `skipsContainerAttachments` | false | Open a Matroska source without reading its attached files (AE#956). See [`skipsContainerAttachments`](#skipscontainerattachments). |

### Buffering and caching

| Option | Default | What it does |
| --- | --- | --- |
| `forwardBufferSegments` | nil (10, about 40 s) | How far the producer may race ahead and how much the cache keeps resident. Clamped to 4...2700; past the historical 150 the real bound is the session's disk budget, so a "buffer without limit" option can pass `Int.max`. Ignored on `nativeRemoteHLS`. Native HLS retention is readable as `$residentRanges` (see [Time](#time)). Software VOD uses the same forward-window and volume-budget policy for compressed packet read-ahead; its continuous selected A/V frontier is `bufferedPosition`, and its retained spans (including history and gaps) are `$residentRanges`. |
| `sessionCacheByteBudget` | nil | Optional byte request for the temporary VOD cache. See [Session cache budget and status](#session-cache-budget-and-status). |
| `progressiveSegmentDelivery` | false | Serve each VOD loopback segment while it is being written. The muxer flushes a fragment about every half second and the loopback server sends each one as it lands, so AVPlayer shows and starts on a segment's first fragments instead of waiting for its cut. Changes nothing on a source fast enough to cut segments before AVPlayer asks. On a slow link it removes a whole segment's download from startup and from a seek outside the buffer. A segment the producer abandons (restart, failed cut) ends its connection without the final chunk, so AVPlayer asks for it again. VOD only; ignored on live, `nativeRemoteHLS` and the software path. |
| `softwarePacketCacheStorage` | `.automatic` | `SoftwarePacketCacheStorage` selects compressed-packet storage for seekable software VOD. `automatic` keeps the defaults (tvOS purgeable memory, disk on other platforms). `disk` opts into temporary files with the existing volume and multi-session budget safeguards. `memory` uses the existing bounded purgeable-memory store; played memory history may disappear and require a source seek. Local files that bypass packet caching, live DVR, and native HLS are unchanged. The choice survives session reloads. Disk can contend with tvOS flash I/O; explicit selection is not a performance recommendation. |
| `generatesBackgroundScrubPreviews` | true | Pre-generate the sparse scrub-still ladder during idle source time. Set false when the host does not consume scrub previews: no ladder rung or ladder side reader is created. Independent of `serveIFramePlaylist`; does not disable on-demand snapshots, item-swap held pictures or Dolby Vision compositor/reshaping. All existing source eligibility and request-budget gates still apply when true. Correctable through `reloadAtCurrentPosition(applying:)`. |

### Live

| Option | Default | What it does |
| --- | --- | --- |
| `isLive` | false | Treat the source as live. Set it explicitly; duration-based auto-detection is too noisy. |
| `dvrWindowSeconds` | nil | Timeshift window. nil means live-only, and `seek` is a no-op. The window is a ceiling: the disk budget (a quarter of the free space, at most 2 GiB unless `liveDVRByteBudget` lifts it on the software route) bounds what is actually kept. So a long window on a high-bitrate channel or a small volume holds less than it asks for. With several engines running, each one's quarter is taken from the free space the others have not already claimed, so a tile added on a tight volume holds less history than the first one (AE#687). |
| `liveJoinProfile` | `.fastZap` | A `LiveJoinProfile`. `.fastZap` collapses TARGETDURATION to the source GOP plus headroom for one 1.5 x longer (AE#670) and bounds the first serve, so an IPTV join costs seconds instead of a full holdback. `.standard` always waits for the full `3 x TARGETDURATION` holdback (at least 18 s, 30 s on a 10 s GOP). See [Where a live start's seconds go](#where-a-live-starts-seconds-go). |
| `liveStartupGraceSeconds` | nil | `.fastZap` loopback live joins only: the extra wait after an eligible finalized window before the first serve. nil takes the observed segment duration clamped to 0.5 to 2 s. 0 serves (admits) as soon as the minimum media exists. nil or invalid values keep the automatic policy. Bounded by the existing manifest deadline. A shorter grace can rebuffer early on an irregular source. |
| `liveStartupSingleSegmentMinimumSeconds` | nil | `.fastZap` only: lets ONE finalized segment at least this long qualify for admission and start the session, instead of waiting for a second one, which on a long-GOP source is another whole GOP. nil, nonpositive or nonfinite values keep the two-segment minimum. A shallow first playlist can rebuffer if the next segment is late; that tradeoff is the host's. `Scripts/test-long-gop-startup.sh` exercises it against paced long-GOP MPEG-TS on macOS AVPlayer. |
| `liveDVRByteBudget` | nil | Disk budget in bytes for the software live DVR ring. nil keeps the default (a quarter of the free space, at most 2 GiB). An explicit value replaces the 2 GiB cap, for a window that has to hold hours of broadcast, such as a recording still in progress fed in as a live source. It is still clamped to a quarter of the free space the other sessions have not claimed, and never below the ring's 64 MiB playback floor. Software route only. |
| `softwareDVRRetention` | nil | Opts the software live spool into `SoftwareDVRRetentionOptions` (`startupMaximumBytes`, `playbackCushionBytes`, `playbackCushionSeconds`) and so into `setSoftwareLiveDVRLimits`. nil keeps the default spool. |
| `clampsLiveResumeToWindow` | true | Whether `play()` may move a behind-live playhead by itself: an edge snap on a live-only source more than 45 s behind, or a landing above the retained floor when a DVR window has slid past it. `false` hands the whole decision to the host, which then also owns the eviction case. |
| `liveEdgeCushionSeconds` | nil | How far behind the live edge a live session plays, in seconds. See [`liveEdgeCushionSeconds`](#liveedgecushionseconds). |
| `liveJoinStartsImmediately` | true | Cuts AVPlayer's stall-avoidance wait short once at the live join, over a buffer that is non-empty and at least 1.5 s deep, on an item that has reached `readyToPlay` (AE#684). The join tail no host can otherwise reach. Default since 6.55.0 after a device A/B; see [The tail after the first serve](#the-tail-after-the-first-serve-and-which-signal-survives-it). |
| `liveBlockingReload` | nil (auto) | LL-HLS blocking-reload override for loopback live sessions. Auto derives eligibility from observed upstream cadence, which is what keeps a bursty relay off a `-15410` loop. |
| `nativeRemoteHLS` | false | Hand a remote `master.m3u8` straight to AVPlayer: no demuxer probe, no loopback. Built for `isLive: true`; a remote HLS VOD URL reaches this route regardless (AE#154). The clock here is item time; see `clock.$sourceTime` (AE#616). |
| `nativeRemoteHLSIngestFallback` | true | The #168 / #293 carriage recovery and the #363 401/403 bypass refusal recovery. Setting it false turns both off. |
| `hostRetriesExhaustedLiveReplay` | `false` | The host owns the retry after a verified live replay exhausts the in-engine reopen: the engine publishes `liveSourceReplayExhausted` and holds production until `retryLiveSourceRecovery()`. `false` publishes `liveSourceReset` for the same exhaustion. |

Neither live startup option (`liveStartupGraceSeconds`, `liveStartupSingleSegmentMinimumSeconds`) changes segment cuts, TARGETDURATION, HOLD-BACK, `.standard` joins or the remote HLS bypass, and explicit holdback floors and cancellation still win.

### Audio

| Option | Default | What it does |
| --- | --- | --- |
| `audioOnly` | false | Lean audio pipeline, no video machinery. Also set automatically when the probe finds no video stream. |
| `audioBridgeMode` | `.surroundCompat` | Bridge encoder for codecs that cannot stream-copy into fMP4. `.surroundCompat` uses EAC3 for a source with more than two channels and FLAC for one with two or fewer (no surround to carry). `.lossless` uses FLAC up to 7.1 throughout and needs a sink that accepts multichannel LPCM. |
| `objectAudioRendering` | `.off` | TrueHD Atmos and DTS:X with heights (#731), in a build with the object-audio traits. See [`objectAudioRendering`](#objectaudiorendering). |
| `confirmAtmos` | false | Background per-track JOC confirmation, republishing `audioTracks` as tracks confirm. Never on the start path; skipped for live and forward-only readers. |
| `preferredAudioLanguages` | empty | First-frame audio pick from the engine's single probe. Ordered BCP-47 / ISO 639 tags; region and script are normalized and rank within one preference (#590). An explicit `audioSourceStreamIndex` still wins. |
| `audioShaping` | `AudioShaping()` | Start the session with audio shaping in force (AE#923). Same value `setAudioShaping(_:)` reads and writes. |
| `audioDelaySeconds` | 0 | Start the session with a lip-sync offset already in force; positive presents audio later. Same value `setAudioDelay(_:)` reads and writes, and a `reloadAtCurrentPosition(applying:)` can correct it. |

### Subtitles and scrubbing

| Option | Default | What it does |
| --- | --- | --- |
| `preferredSubtitleLanguages` | empty | Post-load subtitle activation on the host-overlay path. Ranks language specificity (an explicitly opposite script is rejected, not demoted) before the descriptor axis. Pure convenience: no reload and no pre-probe, unlike the audio equivalent. |
| `externalSubtitles` | empty | Sidecar files registered at load, so they rank in the language preference and can join the native renditions. |
| `initialSubtitleTrackID` | nil | Post-load subtitle activation by `TrackInfo.id` (an embedded stream index, or `externalSubtitleTrackIDBase` plus the index in `externalSubtitles`), for a host that already knows the track, such as a server's default. Wins over `preferredSubtitleLanguages`; an id that names no track falls through to it instead of failing the load. |
| `prepareNativeSubtitles` | false | Declare WebVTT renditions so subtitles survive PiP / AirPlay / external display. |
| `eagerNativeSubtitleReaders` | false | Populate those renditions at load instead of on first selection, for playlists AVKit auto-selects. Only meaningful with `prepareNativeSubtitles`. |
| `nativeSubtitlePreferredLanguages` | empty | Which rendition is marked `DEFAULT=YES`. Resolved by the same BCP-47 matching as the overlay pick, so inline and PiP / AirPlay agree (#590). Read back as `nativeSubtitleDefaultOrdinal`. Does not activate the overlay path, so it cannot double up with the native render. |
| `preserveASSMarkup` | false | Emit raw ASS event lines instead of extracted text; pair with `TrackInfo.assHeader`. ASS / SSA codecs only, embedded and sidecar alike, so a session mixing an ASS track with a SubRip one needs no reload to cross between them (AE#587). |
| `teletextPage` | nil | Fix the DVB teletext caption page instead of letting libzvbi auto-detect. |
| `serveIFramePlaylist` | false | Serve an I-frame rendition next to the master, so a stock `AVPlayerViewController` shows scrub thumbnails and scans on I-frames with no host code. See [`serveIFramePlaylist`](#serveiframeplaylist). |

### Display and HDR

| Option | Default | What it does |
| --- | --- | --- |
| `displayCriteriaOwner` | `.engine` | A `DisplayCriteriaOwner`: who writes `preferredDisplayCriteria` (AE#842). See [Display criteria](#display-criteria). |
| `suppressDisplayCriteria` | false | The engine writes no display criteria because AVKit does. The older spelling of `displayCriteriaOwner = .avKit`. See [Display criteria](#display-criteria). |
| `matchContentEnabled` | true | Mirror of `AVDisplayManager.isDisplayCriteriaMatchingEnabled`. False routes HDR through the auto-tonemap path. |
| `panelIsInHDRMode` | false | **Host assertion** that the panel is presenting HDR right now. See [`panelIsInHDRMode`](#panelisinhdrmode). |
| `attemptsHDRMasterOnUnprovenPanel` | true | Serve the HDR master to an HDR-eligible display whose panel state is unproven, and let AVFoundation's answer be the readout (AE#459). See [`attemptsHDRMasterOnUnprovenPanel`](#attemptshdrmasteronunprovenpanel). |
| `panelPresentsDolbyVision` | false | **Host assertion** that this display presents Dolby Vision, for the platforms where the engine cannot observe it (AE#493). See [`panelPresentsDolbyVision`](#panelpresentsdolbyvision). |
| `omitCriteriaColorExtensions` | false | Diagnostic lever: leave colour out of `AVDisplayCriteria` so AVPlayer re-reads it from the bitstream. |
| `keepDvh1TagWithoutDV` | false | Diagnostic lever: force dvh1 tags and a master playlist regardless of display capability. |
| `stereoPresentation` | `.automatic` | How a 3D source is presented where the system shows stereo. See [`stereoPresentation`](#stereopresentation). |

### Dolby Vision

| Option | Default | What it does |
| --- | --- | --- |
| `dolbyVisionHandling` | `.automatic` | A `DolbyVisionHandling`. `.baseLayerOnly` presents the HDR10 / HLG base layer of a Dolby Vision source and leaves the Dolby Vision out of the container on every display. See [`dolbyVisionHandling`](#dolbyvisionhandling). |
| `forceDolbyVisionOnNonDVDisplay` | false | **Experimental (AE#455).** Serve an HEVC Profile 8.1 source as Profile 5 on a display with no Dolby Vision of its own. See [`forceDolbyVisionOnNonDVDisplay`](#forcedolbyvisiononnondvdisplay). |
| `preferDualLayerDolbyVision` | false | Opt in to composing Profile 7 FEL sources on the GPU. Not recommended for a distributed app. See [`preferDualLayerDolbyVision`](#preferduallayerdolbyvision). |
| `foldsDolbyVisionFEL` | true | With the `DolbyVisionFelCurves` trait: fold a Profile 7 FEL source's enhancement layer into the Profile 8.1 RPU's luma curve. False keeps the plain conversion and its start speed (#1018). Ignored without the trait. See [dolby-vision-fel.md §7](dolby-vision-fel.md#7-curve-fold-on-the-native-route). |
| `dualLayerRoute` | `DualLayerRoute.softwareHost` | Which route composes a Profile 7 FEL picture once `preferDualLayerDolbyVision` has taken the dual-layer route. See [`dualLayerRoute`](#duallayerroute). |

### Decode and routing

| Option | Default | What it does |
| --- | --- | --- |
| `preferredDecodePath` | `.automatic` | A `DecodePath`. `.software` serves this source through `SoftwarePlaybackHost` whatever the routing concluded, scoped to this session and costing the source nothing (seeks, the audio switch and the title switch all keep working). The escape for the formats `VTCapabilityProbe` deliberately cannot classify, and for live H.264 / HEVC, which never reaches that gate at all. One-way: there is no `.native`. On an `audioOnly` session it sends the audio to the FFmpeg host instead of AVPlayer. See [Overriding the decode path](#overriding-the-decode-path). |
| `escalatesToSoftwarePath` | `true` | Whether a native session AVPlayer refuses on its merits (`CoreMediaErrorDomain`), or a live join without an entry point the native route can open (`AetherEngine.LiveJoin`, AE#627), may be rebuilt once on the software path (AE#561). `false` surfaces the failure as `.error` instead, for a host with its own fallback ladder (AE#629). Correctable. |
| `upscalesLowResolutionVideo` | false | Opt in to upscaling SDR video below 1080p to the display's native pixel size (#846). See [`upscalesLowResolutionVideo`](#upscaleslowresolutionvideo). |
| `deinterlaceMode` | `.auto` | A `DeinterlaceMode` for the software path: the Metal / VideoToolbox graph with a CPU bwdif fallback, or `.software` to force the CPU path. |
| `deinterlaceFieldRate` | `.field` | A `DeinterlaceFieldRate`: the hardware deinterlacer emits one frame per field (25i to 50p) or per frame. The software fallback is always frame rate, because doubling a CPU bwdif is the wrong trade and a fallback should not change cost class. |
| `nativeVideoFrameDiagnostics` | false | Decoded-frame observation on SDR native loopback playback. See [Native video frame diagnostics and recovery](#native-video-frame-diagnostics-and-recovery). |
| `nativeVideoFrameRecovery` | false | Bounded recovery when native output stops advancing. See [Native video frame diagnostics and recovery](#native-video-frame-diagnostics-and-recovery). |

### Session

| Option | Default | What it does |
| --- | --- | --- |
| `sharedOutputRole` | `.primary` (default) or `.secondary` | A `SharedOutputRole`. A secondary engine never writes display criteria and never owns Now Playing, whatever `suppressDisplayCriteria` and `ownsVideoNowPlayingSession` say, on the audio-only path too. It also skips the play gate's wait for a criteria write and the panel readout (`criteriaPanelReadout` is nil, as for any suppressed load), so its HDR labelling relies on `panelIsInHDRMode`. The role is fixed for a session, but a later `load()` may change it: as an identity field it only blocks corrections (Sodalite#175). A host that opted into `ownsVideoNowPlayingSession` and changes the role without a `stop()` keeps the native host's original Now Playing ownership until the next stop. See [Running several engines at once](#running-several-engines-at-once). |
| `autoplay` | true | False mounts paused: the load skips the terminal `play()` and settles at `.paused`, for a host that resumes later. See [`autoplay`](#autoplay). |

### Option details

#### `httpHeaders` scoping

- **On the plain `nativeRemoteHLS` bypass**, AVFoundation itself sends the headers to every host the playlists name (cross-host variants, segments and `EXT-X-KEY` URIs) and carries them across 302 redirects. So credential headers there reach every such host, and the engine cannot narrow that. A credential that must not reach every host a playlist names should not ride in `httpHeaders` on the bypass.
- **On the routes the engine fetches itself**, the per-origin credential scoping described for `HLSLiveIngestReader` applies: the ingest, the disc reader, the origin relay, the subtitle proxy, the audio tap and the live subtitle renditions.

#### `maxConcurrentSourceRequests`

The most requests the reader may have open against this origin at once, across every path it fetches on: pump ranges, detour blocks, size probes, tail prefetch, the subtitle side reader, and the HLS live ingest's playlist, segment and key fetches (whose prefetch window narrows to it, AE#678).

- nil counts without capping, and lowers the ceiling on its own after a 429/503/509.
- Set it when the provider states a limit. `1` also switches off the speculative parallel paths, which exist only to overlap with the pump.
- It counts **requests**, not TCP connections: over HTTP/2 a session multiplexes every request onto one connection, while the origin still counts each one (AE#377).
- It is also the only ceiling. Several engines playing from one origin are bounded by this value and by what the origin refuses, not by a transport pool underneath it (AE#450).

#### `sourceOpenPolicy`

HTTP VOD opening budgets for the playback reader and its reopens.

- `firstByteTimeout` (15 s) bounds the first data wait.
- `sizeProbeTimeout` (25 s) bounds the one retry and the whole size discovery, slot waits included.
- Nonpositive or nonfinite values take the defaults; anything above 120 s is capped.
- A request that gets no response is retried once with an open-ended Range, and that connection stays the playback connection. Two unanswered requests fail as `.sourceOpenFailed`, instead of demoting the source to forward-only.
- A real length-less or Range-ignoring response keeps the ordinary sequential handling.
- Single-request origins run the size probes serially; others race them and join the losers before playback starts.
- When an open retires a failed ranged connection and switches to forward-only playback, the retired connection's transport error cannot fail the replacement. A refusal or transport failure from the replacement itself still reaches the host.
- Live, `sequentialOrigin`, remote HLS and disposable probes keep their own budgets.

#### `heldSourceConnection`

Ask the source **once** and pull it, instead of ending the connection at the reader's window high water and asking again every 8 to 16 MB of drain (AE#377).

**When to use it.** For an origin that punishes repeated requests rather than concurrency. Some CDNs refuse new requests for minutes at a time while serving an already open connection at full rate. Against one of those, the request cadence is the defect, at any range size (measured at the reporting origin: 32 MB ranges raised to 256 MB, eight times fewer requests, the refusals unchanged). Where `maxConcurrentSourceRequests` bounds how many requests are in flight, this removes the second request.

**Limits.** The read path is the engine's own HTTP/1.1 over a demand-driven stream task, so:

- **HTTP/1.1 only** (no ALPN; an HTTP/2-only origin is out of scope)
- the **system proxy configuration does not apply**
- TLS is the OS's, through the same host trust decision as every other engine session, but has not been exercised against a self-signed origin

**Behaviour.**

- A viewer who pauses ends the connection after five seconds, and resuming costs one request at the frontier. A held flow nobody reads is the process-wide Network.framework starvation of AE#310.
- It applies to the playback reader. The subtitle and enrichment side readers keep the default transport, since they park for minutes at a time.
- The open-time detection of an origin that ignores `Range` (see `sequentialOrigin`) does not cover it, because its open is open-ended.
- **Names the session**: the transport is chosen at open, so a reload that changes it is refused.

**HLS VOD (AE#732).** A finite HLS VOD on the HEVC-in-MPEG-TS ingest (AE#268) is covered too. Playlist, key and segment requests run over one persistent HTTP/1.1 connection per origin, reused across segments and fetched one at a time. This is for origins that refuse h2 or new connections but serve consecutive requests on one keep-alive connection.

- Each body is streamed into the ingest as it arrives.
- A full FIFO lets the current body finish, but admits no next segment or key request until consumption makes room. Seek, close or cancellation retires that wait.
- Only the wait for a response head has a wall-clock ceiling (45 s). A body ends on its size limit or on 30 s without a byte, never on its duration.
- A new connection opens only on a server close, an origin change, or a seek that abandons a body with more than 2 MB left or too slow to arrive within 3 s. Otherwise the remainder is drained and the connection kept, with the next request waiting for it.
- The log names each connection's protocol and request count.

#### `sequentialOrigin`

Declares an origin that fabricates range answers: one long-lived unranged GET, no ranged probes, non-seekable pb. Requires `declaredDurationSeconds` on VOD.

- **Seeking outside what the session holds is unavailable.** On the loopback route, a target inside the resident span that reaches the producer's frontier lands from the segment cache. Anything else is rejected, and the host re-requests the archive at a shifted start (AE#958).
- An audio switch is a fresh load too, at the position with `audioSourceStreamIndex`, because `selectAudioTrack` could only reopen at byte 0.
- The first append playlist waits for more media than AVPlayer's first reload interval (one `TARGETDURATION`), at most 2 s past the first segment.
- An AirPlay hop on such a session swaps the item onto the LAN address instead of reopening the source, since a reopen could only start again from byte 0.

**Found without the declaration.** A URL source the reader finds forward-only by itself (`Range` ignored, so it can only stream front to back) is served this way without the declaration when its container states a duration. A stated `Content-Length` lets an MPEG-TS source estimate one. The open confirms a 200 answer with a one-byte range, because some CDNs answer a cache miss that way. `loadedOptions` then reads `true`, with that duration declared. Without a duration it stays on the software path.

**Caught when undeclared.** An undeclared origin that fabricates ranges is caught at the first ranged reconnect that starts inside bytes the reader holds (it asks 4 KB early and compares them). The session fails as `.sourceFabricatesRanges` before any of that body is played (AE#958).

#### `skipsContainerAttachments`

Matroska carries the fonts of its ASS subtitles as attachments, tens of megabytes on anime releases, and the demuxer reads all of them while the file opens, before the first packet. Over a slow origin that is most of the startup.

- With this on, the open passes over them (FFmpegBuild's `skip_attachments` matroska option): `fontAttachments` stays empty, and a Matroska cover image is not reported in `metadata`. Tracks, their indices and packets are unchanged.
- For a host that renders text subtitles itself or does without the embedded fonts. One that renders ASS with them (see [formats.md › Authored ASS styling](formats.md#authored-ass-styling)) leaves it off.
- Other containers are unaffected.
- Only the session's first open reads attachments either way. The side readers (embedded subtitles, scrub stills, I-frames, the Atmos and Dolby Vision passes) and the reopens of the same source always pass over them.
- Correctable through `reloadAtCurrentPosition(applying:)` on a URL source, which re-runs `load()`.
- `AetherEngine.probe(...)` honours it too (AE#1029). Without it, a probe of a Matroska file pays for the whole attachment set, so a probe under a `ProbeLimits.maxInputBytes` smaller than the fonts stops with `ProbeError.inputLimit` instead of answering from the header. With it, `SourceProbe.metadata` has no Matroska cover image.

#### `liveEdgeCushionSeconds`

How far behind the live edge a live session plays, in seconds: the buffer a viewer on a slow or unsteady link has against the channel (the "buffer duration" other players expose for IPTV).

- It only ever moves the playhead further back than the path's own safe distance, clamped to `LiveEdgePolicy.maximumEdgeCushionSeconds` (45 s).
- The join waits until that much media stands behind the newest. A live HLS origin's listed backlog fills it at link speed (the ingest joins deep enough); a raw MPEG-TS channel fills it only at 1x after its connect burst.
- A session holding the cushion reads `isAtLiveEdge`.
- It cannot help a link slower than the channel's bitrate.

Per route:

- **Loopback:** raises the served `HOLD-BACK` and the first-serve gate, floors `.fastZap`'s bounded start, and extends the first-serve deadline. The gate is waited out before the item is attached, so AVPlayer's playlist timer (about 20 s on tvOS) never runs during it (AE#851).
- **Software path:** the join lead, the landing holdback, and the cushion a rebuffer refills before resuming. Without `dvrWindowSeconds` the host keeps a packet ring that deep and still publishes no rewind window, so seeks stay refused.
- **`nativeRemoteHLS`:** `AVPlayerItem.configuredTimeOffsetFromLive`, kept across stalls and never below the origin's `recommendedTimeOffsetFromLive`.

#### `objectAudioRendering`

Renders TrueHD Atmos and DTS:X with heights (#731). Needs a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default, [Installation › Optional components](installation.md#optional-components)). Without a codec's trait the option is accepted, that codec keeps `audioBridgeMode` (the channel bridge), and the automatic audio pick does not prefer it. `AetherEngine.OptionalComponent` tells a host which codecs a build renders.

**Values.**

- `.render(SpatialSpeakerLayout)` builds that bed from TrueHD Atmos's lossless channel presentation steered by its objects, or routes DTS:X's heights into it (`.l512`, `.l514`, `.l712`, `.l714`, `.l916`). It delivers the bed in the form the output route carries, chosen at load:
  - 24-bit PCM (`ipcm` over HLS, 1.15 Mbit/s per bed channel, the rendered bed bit for bit), unless the route plays over AirPlay (an AirPlay port in the session's route; on macOS an AirPlay default output device)
  - then Apple Positional Audio (lossy, 320 kbps per bed channel)
- `.apac(SpatialSpeakerLayout)` and `.lpcm(SpatialSpeakerLayout)` force one form.
- `SpatialSpeaker` names the positions.

tvOS sends either form to an Atmos receiver as Dolby MAT, and iOS plays either as Spatial Audio. The rendered bed takes the place of the lossless 7.1 the bridge delivers, so it is the host's choice.

**Which sources.** Only TrueHD that FFmpeg marks Atmos, and DTS-HD Master Audio whose first frames decode as DTS:X in its standard presentation (whatever FFmpeg's label; DTS:X only into `.l714` or `.l916`), at 48 kHz, on OS 26+. Anything else, or any failure to start, keeps `audioBridgeMode` (on the software host, the PCM decode).

**Software host.** It honours the option too, on VOD sessions. TrueHD Atmos and DTS:X are rendered for the sample-buffer audio renderer, as PCM or APAC by the same rule. An E-AC-3 JOC track (6 channels, 48 kHz) is handed to the renderer compressed, after the system's Atmos decoder has been registered in the process, so its objects survive instead of the channel-bed core.

**Automatic audio pick.** With the option on, the automatic pick prefers a TrueHD Atmos or DTS:X-labelled track over the other tracks of the same language: of the `preferredAudioLanguages` match, or of the default track when no preference decides, or of every track when no audio track is tagged at all. It never prefers across a language or dub, never over `audioSourceStreamIndexOverride`, and only where the bed can be rendered (a VOD video session, on the loopback route or the software host, on OS 26 or later).

See [formats.md](formats.md#truehd-atmos-with-heights) and [DTS:X](formats.md#dtsx-with-heights).

#### `serveIFramePlaylist`

Serves an I-frame rendition next to the master, so a stock `AVPlayerViewController` shows scrub thumbnails and scans on I-frames with no host code. Hosts with their own transport bar use `scrubThumbnail` instead.

- One still per segment. An SDR source gets its own keyframes at full resolution. An HDR10, HLG or Dolby Vision source gets tone-mapped 640-pixel Motion JPEG stills (AVKit shows no scrub thumbnail from a PQ or Dolby Vision keyframe).
- Opens a second reader on the source.
- Absent (one log line says why) for: live; sources without a keyframe index; `sequentialOrigin`; `heldSourceConnection`; single-request origins; discs; media-playlist routing (the usual case: an HDR10, HLG or Dolby Vision title on an output that is not presenting HDR, such as an Apple TV locked to SDR, where AVFoundation accepts no master form for PQ content, AE#682); and a Dolby Vision Profile 5 / 10.0 source in a build without the `DolbyVisionStillReshaping` trait.

#### Display criteria

`displayCriteriaOwner` says who writes `preferredDisplayCriteria` (AE#842):

| Value | Meaning |
| --- | --- |
| `.engine` | Writes range and rate before the item loads, and defers to `suppressDisplayCriteria`. |
| `.avKit` | AVKit's write from the item. |
| `.host` | A host that writes its own criteria before `load()`, or none, so the panel stays in the output format chosen in tvOS Settings (a Dynamic Range "System" setting). The engine never writes, clears only a criteria it left applied itself, takes the brief play-gate budget instead of AVKit's second, reads the panel as on its own path, and still waits out a switch it sees running. |

`.avKit` and `.host` win over `suppressDisplayCriteria`. A `.secondary` engine is always a non-writer.

**`suppressDisplayCriteria`.** The engine writes no display criteria because AVKit does (`AVPlayerViewController.appliesPreferredDisplayCriteriaAutomatically`). It is the older spelling of `displayCriteriaOwner = .avKit`, and the setting for previews and headless runs.

- The play gate holds up to a second for AVKit's write on HDR and Dolby Vision content, and the panel readout is skipped. A host that keeps the panel in its system format wants `.host` instead (AE#842).
- A host that clears `preferredDisplayCriteria` itself between loads (leaving full screen for a preview) no longer strands the engine's same-format skip: the next non-suppressed load reads the display manager, finds nothing set, and writes again (AE#678). Clearing through `stop()` is still cleaner, because it resets the engine's record in the same step.

#### `panelIsInHDRMode`

A **host assertion** that the panel is presenting HDR right now, and the gate on whether the HDR10-to-DV upgrade is accepted upfront.

- It is an OR term over the engine's own readout on every platform, not a replacement for it, and no longer limited to `suppressDisplayCriteria` hosts (AE#459).
- The readout it backs up is `currentEDRHeadroom > 1`, which answers only around a dynamic-range transition. An Apple TV whose output format is locked to HDR never makes one and reads as an SDR panel forever, and on tvOS 27 the property has stopped answering at all on at least one box.
- A wrong assertion costs one in-place media-playlist fallback (`-11848`), not the item.
- An in-place rebuild (an audio pick, a custom-source reload) runs no handshake. It routes on the load's readout and display eligibility, together with the session's current assertion and the refusal latch, rather than on this option alone (AE#541).

#### `attemptsHDRMasterOnUnprovenPanel`

Serves the HDR master to an HDR-eligible display whose panel state is unproven, and lets AVFoundation's acceptance or refusal be the readout `UIScreen` will not give (AE#459). VOD and live. Set it false on a host that knows its display is SDR.

**Why.** The proxy this replaces is `currentEDRHeadroom`, which is measurably unreliable. On one Apple TV 4K 3rd gen on tvOS 26.6 it read a flat 1.00 across 46 samples of HDR content while the TV's own info display reported HDR. Later the same day, same box, same output format, same title, it read 1.20. The panel was presenting HDR and the property was wrong about it; what moves it is not established.

**What media-direct costs** on such a panel is not the picture but the manifest: the SUBTITLES rendition, the AUDIO rendition that is the only place AVFoundation reads an HLS language from, and SUPPLEMENTAL-CODECS.

**Behaviour.**

- A panel that proves itself through the headroom short-circuits, and nothing is attempted.
- A refusal costs one in-place media fallback, measured at 223 ms end to end (`-11868` after 54 ms, zero `errorLog` events, position kept, no visible black frame). It is latched for the process, so a genuinely SDR display pays it once rather than per title.
- Live attempts too: the refusal arrives before the first frame, so the live fallback's rejoin at the edge (#130) lands where the session was joining anyway.
- The published `videoFormat` is not moved by an ATTEMPT. It is moved by an ACCEPTANCE: a master AVFoundation has not refused after the settle window publishes the presented format, which is a stronger reading than the headroom rather than a substitute for it.

#### `panelPresentsDolbyVision`

A **host assertion** that this display presents Dolby Vision, for the platforms where the engine cannot observe it (AE#493). `AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`, so a Mac has no per-mode table at all. `eligibleForHDRPlayback` answers HDR10 and HLG but not this: it proves EDR, not that AVFoundation will accept a DV variant here.

**What setting it does.**

- Publishes `videoFormat = .dolbyVision` and asks the tvOS display-criteria handshake for `dvh1`.
- HDR support rides along, because DV is an HDR format. HDR10 and HLG capability are not implied.
- Profile 7 and AV1 Dolby Vision are still gated on it.
- Asserting also disables `forceDolbyVisionOnNonDVDisplay`, the tvOS route for that panel class (AE#455).
- An assertion only ever adds, so `false` cannot hide a capability the system reports.

**What it does not decide.** The packaging of a Profile 5, 8.1 or 8.4 source. 6.72.0 gave the non-DV branch its `dvcC` back and 6.73.0 its `SUPPLEMENTAL-CODECS`, so those three serve byte-identical manifests and segments either way (measured on macOS against the matched Dolby grades).

**A wrong assertion** costs one in-place media-playlist fallback (`-11868` / `-11848`) at the same position, where AVPlayer tone-maps the base layer. It is correctable mid-session through `reloadAtCurrentPosition(applying:)`. That net covers the item-failure class only. The `-15628` an HDR10-only panel showed on the DV packaging in May 2026 (AE#4) is a stall rather than an item failure, and it is no longer this claim's to own either: the same packaging reaches such a panel with or without it since 6.72.0 / 6.73.0, and it did not reproduce on tvOS 26.6. What the claim still moves on the route is HDR readiness, since `supportsHDR` rides along.

#### `stereoPresentation`

How a 3D source is presented where the system shows stereo (visionOS; every other system plays it 2D as before).

- `StereoPresentation.automatic` keeps an MV-HEVC stream's second view (`lhvC` in the init) and presents the side-by-side or over-under packing a container declares (Matroska `StereoMode`).
- `.sideBySide` / `.overUnder` say what a file's name alone says.
- `.mono` plays 2D.
- A stereo session declares `REQ-VIDEO-LAYOUT="CH-STEREO"` (EXT-X-VERSION 12), and a packed frame gets Apple's `vexu` in its sample entry.
- Frame packing is signalled on HEVC only (AVPlayer refuses a packed H.264 init over HLS), so a packed H.264 frame plays 2D.
- A tuning field: `reloadAtCurrentPosition(applying:)` carries a change.

#### `dolbyVisionHandling`

`.baseLayerOnly` presents the HDR10 / HLG base layer of a Dolby Vision source and leaves the Dolby Vision out of the container on every display: plain `hvc1` / `av01` sample entry, `dvcC` stripped, no `SUPPLEMENTAL-CODECS`, HDR10 / HLG display criteria. `videoFormat` reads the base layer's format, while `sourceVideoFormat` and `sourceDVProfile` keep saying what the file carries.

**When to use it.** It is the route a host offers as "Dolby Vision: off (HDR10)", for a source whose Dolby Vision is wrong and whose base layer is right. The reported shape is a remux carrying a Profile 7 RPU under a container record claiming Profile 5, where a player that believes the record decodes YCbCr as IPT and the picture comes out green / violet.

**Applies to** HEVC Profile 7 / 8.1 / 8.4, AV1 Profile 10.1 / 10.4, and a Profile 5 (or AV1 10.0) record whose VUI declares a BT.2020 YCbCr PQ or HLG base. A Profile 5 whose VUI is unspecified carries IPT-PQ-c2, has no base layer to present, keeps its route, and the engine says so in the log.

- Takes precedence over `forceDolbyVisionOnNonDVDisplay`.
- A tuning field, correctable through `reloadAtCurrentPosition(applying:)`. Under it, a Profile 5 record the VUI contradicts also stops refusing the software path.

See [formats.md](formats.md#dolby-vision-signaling).

#### `forceDolbyVisionOnNonDVDisplay`

**Experimental (AE#455).** On a display with no Dolby Vision of its own, serve an HEVC Profile 8.1 source the way a Profile 5 source is served (`dvh1` sample entry, `dvcC` rewritten to profile 5 / compatibility 0, `CODECS="dvh1.05.LL"`). AVPlayer then composes the RPU itself, instead of handing the panel the static-metadata HDR10 base layer. The bitstream is untouched; only the container's claim about it changes. Ignored on a display that does Dolby Vision, and Profile 8.1 only. See [formats.md](formats.md#dolby-vision-signaling) for what it buys and what it risks.

#### `preferDualLayerDolbyVision`

Opt in to composing Profile 7 FEL sources on the GPU, instead of taking the native route (the single-layer 8.1 conversion where the display takes Dolby Vision, the HDR10 base layer where it does not). See [dolby-vision-fel.md](dolby-vision-fel.md).

**Not recommended for a distributed app.** The composer evaluates the RPU's MMR chroma prediction and the enhancement layer itself, steps covered by live Dolby patents. The `DolbyVisionFelCurves` trait brings most of a FEL source's enhancement layer back on the native route without that ([Dolby Vision FEL › Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route)).

**Needs the `DualLayerDolbyVision` package trait** (off by default, [Installation › Optional components](installation.md#optional-components)). Without it the option is accepted and changes nothing, and a `reloadAtCurrentPosition(applying:)` that flips it is not refused.

**When the route is taken.** When true, and all of these hold:

- `dolbyVisionHandling` is `.automatic`
- the source is a seekable VOD
- the first RPU says `el_type` FEL
- VideoToolbox decodes HEVC in hardware
- the stream fits the real-time budget (UHD at 30 fps for the base layer plus a 1080p enhancement layer; a 24p UHD master uses 80% of it)

then Profile 7 routes through `SoftwarePlaybackHost` + `DualLayerVideoDecoder`. Both layers decode in VideoToolbox, `DoviFelComposer` reconstructs the picture in Metal and delivers 10-bit P010, and every frame carries its RPU converted to Profile 8.1 as a `DolbyVisionRPUData` attachment, which tvOS applies as Dolby Vision display management.

A Profile 7 MEL source, and anything the device cannot decode twice in real time, keeps the native route (8.1 where the display takes Dolby Vision, the HDR10 base layer where it does not; the conversion is lossless only for MEL). The load logs one `DV P7 dual-layer route: taken` / `not taken (<reason>)` line either way.

**What it gives up.** Against the native route: Picture in Picture, scrub thumbnails, subtitles, AirPlay. See [dolby-vision-fel.md](dolby-vision-fel.md#523-what-the-route-gives-up-against-the-native-route).

**Audio.** The route runs on the software host, whose audio is decoded by FFmpeg and played through the sample-buffer audio renderer.

- With `objectAudioRendering` off (the default), an E-AC-3 (JOC) track plays as its channel-bed core (5.1 or 7.1), without the objects.
- With `.apac(layout)` on (and the object-audio traits built in), JOC goes to the renderer compressed, and TrueHD Atmos and DTS:X are rendered as APAC (verified on macOS; the tvOS behaviour is unmeasured).

**The display is not consulted.** With the flag on and a display that does not take Dolby Vision, the route is still taken: the composed full-FEL picture is presented with its attached metadata, and how tvOS presents it is up to the platform. (The native route would have played the HDR10 base layer there.) The audio notes above apply there too.

**Correcting it.** A tuning field, correctable through `reloadAtCurrentPosition(applying:)` on a URL source (which re-runs `load()` and re-decides the route). On a custom `IOReader` source, a Profile 7 session refuses a change of this option, or a change of `dolbyVisionHandling` while this option is on, with `SessionReloadRefusal.dualLayerRouteNeedsFreshLoad`: the in-place rebuild keeps the route the session was loaded with. Call `load()` again with the new option.

#### `dualLayerRoute`

Which route composes a Profile 7 FEL picture once `preferDualLayerDolbyVision` has taken the dual-layer route.

- **`.softwareHost`** (default) is the route described under [`preferDualLayerDolbyVision`](#preferduallayerdolbyvision).
- **`.avPlayerOutput`** is a second route behind the same `DualLayerDolbyVision` trait, opt-in and off by default. See [dolby-vision-fel.md](dolby-vision-fel.md#524-the-avplayer-output-route).

**How `.avPlayerOutput` works.**

- AVPlayer decodes and times the base layer (the engine's loopback HLS stream, Profile 8.1 RPU) and plays the audio.
- The engine takes the decoded frames from an `AVPlayerItemVideoOutput` (biplanar 10-bit, no colour conversion), and pairs each with its enhancement layer from an in-process tap on the segment producer's single read of the source (no second connection and no full-file scan).
- It composes them with the same `DoviFelComposer` the software host uses, and presents the result in an `AVSampleBufferDisplayLayer` that follows the item's timebase. AVPlayer's own picture is hidden with the public `suppressesPlayerRendering`.
- The item owns the clock, so `currentTime`, `seek(to:)`, `play()` and `pause()` are AVPlayer's, and so is the audio. (The Atmos trade-off of `preferDualLayerDolbyVision` does not apply.)

**Enhancement-layer ring.** The enhancement-layer packets of the last stretch played are kept in a bounded on-disk ring (1 GiB at most, in the temporary directory, unlinked at once so nothing outlives the process) that keeps the newest bytes. So a seek back into content the ring still holds finds its enhancement layer.

- The session's forward-buffer window is capped at 10 segments on this route. The producer's lead is spent from the ring, and a lead longer than the ring would leave the playhead without an enhancement layer.
- While a position has no enhancement layer (a seek beyond what the ring holds, a gap), the picture is AVPlayer's own base-layer frame, shown at once. The composed picture resumes when the layers pair again (after a seek beyond the ring, once the playhead reaches packets the ring holds).
- A base-layer frame whose enhancement packet is merely late waits 0.1 s and then goes out as the base layer.

**Platforms.** Compiled for macOS, tvOS and iOS. Only macOS has been run; tvOS and iOS compile and are selectable but were not run on a device.

**Drawing.** The route draws in the engine's `AetherPlayerView`.

- A host that puts `nativePlayerLayer` into its own view sees no picture from it (the property is nil while the route runs).
- Picture in Picture is not offered on this route (`nativePlayerLayer` is nil and there is no `softwarePiPSource`), so a host cannot build a window that would be blank.
- Subtitles are not checked on it.
- When an AirPlay video receiver or an external display holds the picture (at load, or when the route changes mid-session), the route stops and AVPlayer shows its own picture, the Profile 8.1 base layer, without the enhancement layer. The log carries `[DualLayerOutputRoute] another screen ...`, and the route is decided again at the next load or rebuild of the session.

**When it changes nothing.** Unless the preference is on and the route decision takes the dual-layer route. A MEL source, a build without the trait, a source whose packets are not hvcC-framed (Annex B), and a stream without a usable frame rate load as with `.softwareHost` (the log says why).

**Picture difference.** The composed picture differs from the software host's by the dither pattern only. Both dither on the parity of a frame index: the host counts compositions, and this route uses the frame's position in the stream.

**Correcting it.** A tuning field, correctable through `reloadAtCurrentPosition(applying:)` on a URL source. On a custom `IOReader` Profile 7 session, a change of it while `preferDualLayerDolbyVision` is on is refused with `SessionReloadRefusal.dualLayerRouteNeedsFreshLoad`.

The load logs `DV P7 dual-layer: AVPlayer-output route (...)` after the usual `DV P7 dual-layer route: taken` line.

#### `upscalesLowResolutionVideo`

Opt in to upscaling SDR video below 1080p (coded width under 1920 and height under 1080) to the display's native pixel size (#846).

**How.** Such a source routes through `SoftwarePlaybackHost`. Each decoded frame runs VideoToolbox low-latency super resolution where the device and frame size allow it, then MetalFX spatial scaling to the source's display aspect fitted into the display, never past it. Needs tvOS / iOS / macOS 26 and a GPU with MetalFX spatial scaling. Status is published as `$activeUpscale`.

**Not taken** for HDR (PQ, HLG; an unspecified transfer counts as SDR), Dolby Vision, a display no larger than the source, any wireless AirPlay route (a receiver showing the video and AirPlay speakers playing the sound alike: the software path sends the sound there alone), and a demuxed-audio live stream. These keep their usual route. The load logs one `[Upscale] taken: <source> -> <target> (<stages>)` / `[Upscale] not taken (<reason>)` line either way.

**It never stops playback.** A frame the stage cannot process is delivered as decoded.

- **Building.** The stage is built off the main thread, since starting VideoToolbox super resolution loads its model on the Neural Engine (about 4 s cold on Apple TV). Until it is ready, frames are delivered as decoded (logged once as `[Upscale] passing frames through: stage still building`, then `[Upscale] stage built in ... ms`). A stage that cannot be built switches itself off like a failing one (`disabledReason` `stage not built: ...`).
- **Overrun.** A sustained overrun of the frame budget first drops MetalFX where VideoToolbox super resolution also runs (logged once as `[Upscale] degraded: ...`, published as `UpscaleStatus.degraded`). The overrun is remembered for the process, so a later session or in-session rebuild at least as heavy and as fast starts without MetalFX.
- **Switching off.** Repeated failures, or an overrun with nothing left to drop, switch it off for the session (logged once, and published through `$activeUpscale`). A stage that switched itself off stays off for the rest of the session, also across in-session rebuilds (audio switch, background return), and `$activeUpscale` keeps its `disabledReason`. Its plan (source, ML output and target size) is remembered for the process together with the source frame rate, so a later load with the same plan at that rate or faster logs `[Upscale] not taken (the stage disabled itself for this plan earlier in this process)`.
- **Timing log.** For the first ten 48-frame windows of each stage it logs a per-step timing line (`[Upscale] timing: total ... ms (copy, ml, edge, metal wall / gpu, attach) over 48 frames at ... ms interval`).

**Going back to native.** A URL VOD session that only the stage put on the software path goes back to the native path when the stage switches itself off: once no load is in flight, it reloads at the current position (`reloadAtCurrentPosition()`, logged as `[Upscale] stage disabled on a session it alone put on the software path: ...`). A custom `IOReader` source and a live session stay on the software path, with frames delivered as decoded.

**Correcting it.** A tuning field, correctable through `reloadAtCurrentPosition(applying:)` on a URL source (which re-runs `load()` and re-decides the route). On a custom `IOReader` source, turning it off is honoured in place (the session stays on the software path and delivers frames as decoded), and turning it on is refused with `SessionReloadRefusal.upscaleRouteNeedsFreshLoad`.

#### `autoplay`

`autoplay` describes THIS MOUNT and nothing after it. The rebuilds a session makes on its own (`reloadAtCurrentPosition`, an option correction, the AirPlay LAN swap, an audio-delay nudge) come back in the transport state the session is in, not in this one.

Correcting it through `reloadAtCurrentPosition(applying:)` therefore does nothing. The log names it as not applied rather than as applied (AE#464 round 3), and the call returns it as `sessionOwned` with `rebuilt` false rather than spending a teardown on it (AE#464 round 4). Call `play()` or `pause()` instead.

## Value types

| Type | Carries |
| --- | --- |
| `SourceProbe` | `url`, `durationSeconds`, `containerFormat`, `videoFormat`, `videoCodecID` / `videoCodecName`, `videoWidth` / `videoHeight`, `videoFrameRate`, `isDolbyVision`, `dvProfile`, `dvBLCompatID`, `carriesHDR10PlusMetadata`, `carriesHDRVividMetadata`, `dolbyVisionEnhancementLayer`, `discTitles`, `audioTracks`, `subtitleTracks`, `metadata`, `isLive`, `videoStreamFormat` (the same `VideoStreamFormat` a session publishes as `$sourceVideoStreamFormat`). See below. |
| `DolbyVisionEnhancementLayer` | `.fel` (the residual changes the picture; only the dual-layer route shows it) or `.mel` (the residual is empty; the base layer and RPU are the picture). Returned by `probeDolbyVisionEnhancementLayer`, and in `SourceProbe.dolbyVisionEnhancementLayer` by a probe asked for `.dolbyVisionEnhancementLayer`. |
| `TrackInfo` | See [`TrackInfo`](#trackinfo). |
| `MediaMetadata` | `title`, `artist`, `album`, `artworkData`, `hasDisplayMetadata`. There is no separate album-artist field: a container's album artist is a fallback the parser folds into `artist`. |
| `SubtitleCue` | `id`, `startTime`, `endTime`, `body` (a `SubtitleCue.Body`: `.text`, `.richText`, `.image`), `placement`, plus `text` and `isForced` conveniences. |
| `SubtitleTextRun` | `text`, `color`, `isBold`, `isItalic`, `isUnderlined`, `isStruckThrough`, `fontName`, `fontSize`, `isStyled`. |
| `SubtitleTextPlacement` | `alignment` (numpad), `position` (a [0, 1] anchor). |
| `SubtitleImage` | `cgImage`, `position`, `canvasSize`, `isForced`. |
| `ExternalSubtitleTrack` | `url`, `name`, `language`, `isForced`, `isHearingImpaired`, `isDefault`, `httpHeaders` (nil forwards `LoadOptions.httpHeaders`), `formatHint` for URLs whose path hides the format, and `sourceStreamIndex` for a container holding several subtitle streams. That index addresses the container at `url`, not the played media. |
| `NativeSubtitleTrack` | `ordinal`, `language`, `displayName`, plus `sameLanguageRank(of:in:)` for telling same-language options apart (eng Full against eng SDH). |
| `RecordingState` | `.idle`, `.recording(RecordingProgress)`, `.ended(RecordingEndReason)`, `.failed(RecordingFailure)`. What the session's live recording is doing. |
| `RecordingProgress` | `url`, `startedAt`, `bytesWritten`, `durationSeconds`. Republished at 1 Hz while recording. |
| `RecordingEndReason` | `.stoppedByHost`, `.sourceReset`, `.sessionEnded`. Why a recording stopped without failing; the file is closed and playable in every case. |
| `RecordingFailure` | `.unsupportedRoute(VideoRoute)`, `.notLive`, `.alreadyRecording(URL)`, `.cannotCreateFile`, `.diskFull`, `.writeFailed`, `.writeTooSlow`, `.noStreamsToCopy`. The first four are thrown out of `startRecording(to:)`; the rest arrive through `$recordingState`. |
| `TitleInfo` | `id` (0-based, longest first; id 0 is the main feature and the key for `selectTitle`), `name`, `durationSeconds`, `chapterCount`. |
| `ChapterInfo` | `id`, `name`, `startSeconds`, `durationSeconds`. The two publishers differ in axis. `discChapters` are title-relative and seeked through `selectChapter(id:)`. `mediaChapters` are on the 0-based `currentTime` / `seek(to:)` axis (the container start already taken off): a host passes `startSeconds` straight to `seek(to:)`, and `selectChapter` no-ops for them. |
| `AudioShaping` | `maxChannels` (nil or 1...8, never upmixes), `dialogueGainDB` (0...`maxDialogueGainDB`, 12), `compressor`, `clamped`, `isActive`, `summary` (the wording the engine's log uses). |
| `AudioShaping.Compressor` | `thresholdDB`, `ratio`, `makeupGainDB`, `attackMilliseconds`, `releaseMilliseconds`, `kneeDB`, `clamped`, and the `night` preset (-30 dB, 4:1, +10 dB makeup, 5 ms attack, 250 ms release, 6 dB knee). |
| `AudioShapingState` | `.off`, `.applied`, `.unavailable`; see `$audioShapingState`. |
| `UpscaleStatus` | `sourceSize` (the decoded size the stage receives), `mlScale` (the VideoToolbox super-resolution factor; nil when MetalFX alone scales), `targetSize` (the delivered size: the source's display aspect fitted into the display), `disabledReason` (set when the stage switched itself off mid-session), `degraded` (true once a sustained overrun made the stage drop MetalFX and deliver the VideoToolbox output at its own size, which `targetSize` then is, with the source's pixel aspect ratio; kept when the stage later switches itself off). See `$activeUpscale`. |
| `AudioTapChannels` | `.downmix` (every channel summed) or `.dialogue` (the front-centre channel, falling back to the downmix on a source without one). |
| `AudioTapBuffer` | `buffer` (`AVAudioPCMBuffer`), `sourceTime`, `discontinuity`, `channels` (what this buffer actually carries). Non-discontinuity buffers are strictly increasing and non-overlapping, which is what SpeechAnalyzer's input timeline requires. |
| `LiveTelemetry` | The 1 Hz snapshot: bitrates, observed fps, dropped frames, cache and network bytes, A/V gap, RSS. |
| `ObjectAudioActivity` | `layout`, `objects`, `activeObjects`, `elevatedObjects`, `heightChannels`: what object audio is doing, as `LiveTelemetry.objectAudio`. |
| `PlaybackErrorInfo` | `kind`, `underlyingDomain`, `underlyingCode`, `message`. Published as `$errorInfo` beside a `.error` state. |
| `PlaybackErrorKind` | The stable token inside it. See [`PlaybackErrorKind`](#playbackerrorkind). |
| `DisplayCapabilities`, `StartupProgress`, `SeekEvent`, `PresentationAxisMap`, `NativeVideoFrameTime`, `SoftwareVideoFrameTime`, `SoftwarePiPSource`, `SystemCaptionRequest`, `AetherEngineError`, `HLSIngestError` | Covered in their sections above. |
| `LiveDVRLimits`, `SoftwareDVRRetentionOptions` | The live DVR lease and the software spool's opt-in bounds; covered in [Live and DVR](#live-and-dvr). |
| `ScrubFrame` | `image`, `actualSeconds`, `refined`, `validRange`. Returned by `scrubPreviewFrame`. |
| `BoundedStillFrame` | `image`, `actualSeconds`. nil `actualSeconds` means the decoded frame carried no PTS, so the caller labels the requested time rather than claiming a measured one. |
| `FontAttachment` | Attached font files for authored ASS rendering: `filename`, `mimeType`, `data`. |

**`SourceProbe` HDR flags.** `carriesHDR10PlusMetadata` is `false` unless the probe was asked for `.hdr10Plus`, and a `false` means "not asked, or not seen inside the budget", never "proven absent". When it is true and the container said HDR10, `videoFormat` reads `.hdr10Plus`; a Dolby Vision source keeps `.dolbyVision` and carries the flag alongside. `carriesHDRVividMetadata` follows the same contract for `.hdrVivid` (#699) and never moves `videoFormat`: HDR Vivid rides an HLG or PQ base, which stays the label. `dolbyVisionEnhancementLayer` is nil unless the probe was asked for `.dolbyVisionEnhancementLayer`; nil also covers "not Profile 7" and "no RPU inside the budget", so it never means MEL (#1030).

**`SourceProbe` container facts (#1032).** Three fields carry what a loaded session publishes, read from the same open demuxer, so a details screen has them before the first playback. `containerFormat` is the libavformat name (`"matroska,webm"`, `"mov,mp4,m4a,3gp,3g2,mj2"`, `"mpegts"`), the same string as `sourceContainerFormat`, and it names what the bytes are: an MP4 renamed to `.mkv` reads `"mov,mp4,..."`. `dvBLCompatID` is the base-layer signal compatibility id from the `dvcC` / `dvvC` record, the same value as `sourceDVBLCompatID` (1 HDR10, 2 SDR, 4 HLG, 6 Blu-ray HDR10, 0 none; nil without a record), so Profile 8.1 / 8.2 / 8.4 need no guess from the transfer. `discTitles` is the same list as the session's `discTitles`, longest first, empty for a source that is no disc; an id from it is valid for `load(..., discTitleID:)`.

### `TrackInfo`

Fields: `id`, `name`, `codec`, `language`, `channels`, `bitrate`, `isDefault`, `isForced`, `isHearingImpaired`, `isCommentary`, `isVisualImpaired`, `isAtmos`, `isDTSX`, `trueHDAtmos`, `assHeader`, `isExternal`, `isNativelyRenderedSubtitle`; for audio also `sampleRate`, `bitsPerSample`, `sampleFormat`, `channelLayout`; and `profile` for every track (AE#658).

- `isVisualImpaired` is audio description, from the container's `VISUAL_IMPAIRED` disposition (AE#919).
- `bitsPerSample` is 0 where the codec has no fixed depth (AAC, AC-3, E-AC-3 and Opus decode to float).
- `sampleFormat` is the probe decoder's output in libav's names ("fltp", "s32").
- `profile` is libavcodec's profile name, and the place DTS:X ("DTS-HD MA + DTS:X") and TrueHD Atmos ("Dolby TrueHD + Dolby Atmos") show up. `isAtmos` covers E-AC-3 JOC only.
- `trueHDAtmos` (#1035) is a probe's `.atmos` answer for a TrueHD track, read from its major sync: `.atmos`, `.noAtmos` or `.unsettled`, nil when that pass did not run for the track. libavcodec names the profile only for a track the header probe decoded a frame of, so a nil `profile` alone cannot tell plain TrueHD from Atmos.
- `isDTSX` is set from that DTS:X profile at probe time. Because the probe labels it from the frames it read, it is also set once the DTS:X decoder confirms a track FFmpeg labelled plain DTS-HD MA while `objectAudioRendering` plays it. `audioTracks` is then republished, and the flag stays for that source.
- `isNativelyRenderedSubtitle` marks a subtitle the playback backend draws itself (a remote-HLS rendition AVFoundation renders). No cue reaches `subtitleCues`, so an overlay control (position, delay, styling) has nothing to act on.

### `PlaybackErrorKind`

A string-backed struct rather than an enum, so a kind added in a minor release cannot break a host's switch. Raw values are API and do not change.

The kinds: `.sourceOpenFailed`, `.sourceRefused`, `.customSourceProbeFailed`, `.liveSourceUnavailable`, `.hlsPlaylistOnRawLivePath`, `.dolbyVisionRequiresHardware`, `.demuxedAudioLiveUnsupported`, `.nativeItemFailed`, `.noPlayableTrackWithinBudget`, `.masterPlaylistRejected`, `.vodSourceFailed`, `.sourceRateLimited`, `.softwarePipelineFailed`, `.audioSessionFailed`, `.reloadFailed`, `.liveReloadNeverReady`, `.audioTrackSwitchFailed`, `.audioBridgeProducedNoOutput`, `.storageExhausted`, `.sourceCertificateRejected`, `.sourceFabricatesRanges`.

- **`.sourceRefused`**: the origin answered an HTTP status other than a rate limit instead of media; `underlyingCode` is the status.
- **`.sourceCertificateRejected`**: the transport was refused over certificate trust; `underlyingCode` is the `NSURLErrorDomain` code (AE#495).
- **`.sourceFabricatesRanges`**: the origin answered a byte range with other bytes (AE#958).

Kinds that need their own handling:

- **`.sourceRateLimited`** is the one to branch on separately: the source is being metered, not lost. The same request is expected to work later, and a handoff to a second player will meet the same refusal (AE#377).
- **`.audioBridgeProducedNoOutput`** is a DEMOTE, not a stop. A source whose audio has to be transcoded into fMP4 (MP3, MP2, DTS, TrueHD, Vorbis, PCM) produced no encoded audio at all, so the mp4 muxer could not build the sample entry it derives from a written packet (AE#396). The source is neither gone nor unreadable, and a second player that decodes the track itself plays the file. (It used to arrive as `.vodSourceFailed`, which reads as a dead source and ends a fallback ladder.)
- **`.storageExhausted`** is neither. The volume holding the loopback segment cache (the temporary directory) filled up and no segment could be written (`underlyingCode` is `-28`, `AVERROR(ENOSPC)`). The source, its audio and every other player are fine, and the same load succeeds once space is freed. (It used to arrive as `.vodSourceFailed` or `.audioBridgeProducedNoOutput`.)
- **`.sourceFabricatesRanges`** asks for a different load rather than a retry. A `206` named the requested offset over a body that did not hold the bytes the reader already had there (an IPTV timeshift archive answering on its own chunk boundary), so nothing past byte 0 can be placed. Load the source again with `sequentialOrigin` and `declaredDurationSeconds`. (It used to play repeated or shifted audio and video, or arrive as `.vodSourceFailed` / `.softwarePipelineFailed`.)

## Public but not host API

These are public for the CLI, the test suite, or a diagnostic overlay, and outside the shape this reference documents. Nothing here should carry playback logic. The `@_spi(Diagnostics)` entries are outside the SemVer contract and may change in any release. The other entries stay source-compatible like the rest of the public surface.

- **Test hooks**: `setForceSoftwarePathForTesting`, `setSourceThrottleKbpsForTesting`, `setSoftwareBackgroundAudioOnlyForTesting`, `softwareVideoFramesEnqueuedForTesting`, `invalidateSoftwareVideoSessionForTesting`, `setLargeAllocationCensusEnabled`, `forceStalledConsumerReloadForTesting`, `stallRendererClockForTesting`, `rendererClockRateForTesting`.
- **`playbackBackend`**: the internal rendering backend, exposed read-only for overlays. Hosts must not branch on it; `videoRoute` is the surface that answers the same question honestly.
- **`HLSVideoEngine`** and its `DiagnosticStats`: the loopback session's own machinery, public because `aetherctl` drives it directly. (Its `sessionCacheStatus()` is described under [Session cache budget and status](#session-cache-budget-and-status).)
- **`DiscInspector` / `DiscInspection`**, `DoviRpuConverter` and its probe, `AudioTapProbe`, `SoftwareDecodeProbeResult`, `A53SEIParser`: repro and inspection surfaces behind `aetherctl` subcommands.
- **`HLSLiveIngestReader`'s internals** (`terminalError`, `upstreamTargetDuration`, `observedLiveCadenceSeconds`, `closedLiveCadenceSeconds`, `upstreamSegmentDurationSeconds`, `companionAudioReader`): fixture and diagnostic reads. `closedLiveCadenceSeconds` and `upstreamSegmentDurationSeconds` are the closed evidence the served TARGETDURATION is sealed from (AE#447). `upstreamTargetDuration` is the upstream's own claim, reported in the seal line; nothing is derived from it.
- **`SubtitleChannel`**: the primary / secondary selector on the engine's internal subtitle routing. No public signature takes one; a host picks the channel by calling the primary or the secondary method.

**`@_spi(Diagnostics)` surfaces.** Hosts import none of these.

- **Dolby Vision Profile 7 FEL tooling.** The host surface of the FEL route is `LoadOptions.preferDualLayerDolbyVision` and, in `SessionReloadRefusal`, the new case `.dualLayerRouteNeedsFreshLoad`. See [Dolby Vision FEL](dolby-vision-fel.md) and [CLI](cli.md).

  | API | `aetherctl` | Availability |
  | --- | --- | --- |
  | `FelProbeResult` / `felDecodeProbe` | `feltest` | |
  | `felResidualEnabled` | `play --cycle-el` | |
  | `DmPassthroughReport` / `dmPassthroughReport` | `dmpass` (the display-metadata passthrough measurement) | |
  | `DoviFrameDump` / `doviFrameDump` | `elframe` | `DualLayerDolbyVision` trait only |
  | `DoviResidualSurveyResult` / `DoviResidualFrame` / `doviResidualSurvey` | `elsurvey` | `DualLayerDolbyVision` trait only |
  | `DoviRpuSurvey` / `DoviRpuSurveyResult` / `DoviRpuFrameSurvey` / `doviRpuSurvey` | `dvsurvey` | |
  | `FelCurveFoldResult` / `felCurveFold` | `felcurves` | `DolbyVisionFelCurves` trait only |
  | `armDolbyVisionPinTest` / `dolbyVisionPinIsArmed` / `dolbyVisionPinIsActive` | `play --dv-pin` | `DEBUG` builds with the `DualLayerDolbyVision` trait only |

- **AV1 Dolby Vision 10.1 switches**: `attachesAV1DolbyVisionRPU` (default on; off shows the route's HDR10 base layer for A/B viewing, from the next frame on) and `decodesAV1DolbyVisionInSoftware` (default off; dav1d even where VideoToolbox decodes AV1, so a Mac reproduces the Apple TV route). Hosts set neither: the route has no host option ([formats › Dolby Vision signaling](formats.md#dolby-vision-signaling)).
- **`convertsAV1FramesOnGPU`** (default on): off hands 10-bit AV1 back to `sws_scale` and lets dav1d apply the film grain, for CPU comparisons. Read when a decoder opens. Hosts never set it ([formats › Containers and codecs](formats.md#containers-and-codecs)).
- **`snapsAV1SeeksToKeyframes`** (default on): off keeps every seek on the software host's AV1 exact instead of landing it on the nearest keyframe, and a cache hit on the keyframe before the last one, for comparisons. Read when a session opens its decoder. Hosts never set it ([Transport › `seek(to:)`](#transport)).
