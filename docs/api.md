# Public API reference

This file lists every public surface a host app uses, and the contracts where the host has to act. The README shows the shape of an integration; this file is what you check an integration against.

Every public symbol is part of the [stability contract](installation.md#stability-and-versioning). `Tests/AetherEngineTests/PublicAPIDocumentationTests.swift` fails the build when a host-facing public declaration is named nowhere in the docs, so this file cannot fall behind the code unnoticed.

The host contracts come first. A mistake there costs a shipped app a bug report, not a compile error. A working example of the live contracts, compiled against the engine: [`Examples/LiveHost/LiveChannelHost.swift`](../Examples/LiveHost/LiveChannelHost.swift).

- [The contracts a host has to answer](#the-contracts-a-host-has-to-answer)
- [Constructing and binding](#constructing-and-binding)
- [Loading](#loading)
- [Custom byte sources (`IOReader`)](#custom-byte-sources-ioreader)
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
| [What must be set before `load()`](#what-must-be-set-before-load) | Set those engine properties first; know which options cost a reload |
| [Isolation, and what runs off the main actor](#isolation-and-what-runs-off-the-main-actor) | Call the blocking and threaded APIs from the right place |
| [Running several engines at once](#running-several-engines-at-once) | Use `.secondary` roles, `logTag`, and always `stop()` |
| [One FFmpeg, and it has to be the engine's](installation.md#one-ffmpeg-and-it-has-to-be-the-engines) (in Installation) | Keep a second FFmpeg from taking the engine's symbols |
| [Holding a second player beside the engine](installation.md#holding-a-second-player-beside-the-engine) (in Installation) | Link the engine into its own dynamic framework when the other FFmpeg is static |

The event subjects below (`liveSourceReset`, `liveSourceReplayExhausted`, `liveResumeClamped`, `systemCaptionRequest`, `softwarePathEscalations`) are `PassthroughSubject`s that live as long as the engine.

- Subscribe once, before the first `load()`. One subscription covers every later session.
- Nothing is replayed, so a late subscriber misses earlier events.
- Subscribing again on every load stacks duplicate sinks.
- Only the engine sends on them, never the host.

### How a load ends

**What the host must do:** let `CancellationError` pass without treating it as a failure, count a failure once (it is reported twice), and classify failures on `$errorInfo`, never on the message text. Every kind a failure can carry is listed under [`PlaybackErrorKind`](#playbackerrorkind) below.

`load(...)` reports a failure twice on purpose: it throws, and `state` publishes `.error`. A host that counts both counts one failure as two.

| What happened | `load()` | `state` |
| --- | --- | --- |
| The source could not be opened, probed, or routed | throws | `.error(message)` is published as well |
| A newer `load()` or a `stop()` superseded this one | throws `CancellationError` | belongs to the successor, untouched |
| The Task awaiting it was cancelled while it ran (Sodalite#173) | throws `CancellationError` | `.idle`; the native host is kept for the next load, as with a newer `load()` |
| AVPlayer refused the media during startup, and the engine rebuilt the session on the software path (AE#561) | keeps waiting, then returns (or throws what the rebuild threw) | whatever the rebuilt session reaches; `softwarePathEscalations` fires with `duringStartup` |
| A custom `IOReader` whose initial probe failed | throws | `.error` |
| Dolby Vision with no compatible base layer on the software path | throws `AetherEngineError.dolbyVisionUnplayableOnSoftwarePath(profile:)` | `.error` |
| An HLS playlist handed to the raw live path by a custom reader | throws `AetherEngineError.hlsPlaylistOnRawLivePath` | `.error` |
| The session died after the load returned (source loss, a reload that never became ready, a track switch that failed) | already returned | `.error(message)` only |
| A live session the engine cannot revive | already returned | no `.error`; `liveSourceReset` fires instead |

#### `CancellationError` is not a playback failure

Let `CancellationError` through untouched. A superseded load throws it at its first checkpoint, so every channel zap, every next-episode call and every `stop()` during a load produces one. A host that retries, falls back to a second engine, or shows an error whenever "load threw" ends up reacting to its own navigation.

A load the ENGINE superseded does not throw it. When the software-path rebuild (below) takes over the startup, the `load()` the host awaits follows the rebuild and keeps waiting, as it does across a #361 reroute (AE#629).

#### The message is a payload, `errorInfo` is the key

Log the message inside `.error` verbatim, but do not classify on it. It comes from two places:

- **The engine's own sentence.** It names the cause, not the symptom. Examples: `"AVFoundation built no track for it within 45s and the source's carriage could not be identified"`, `"Live source unavailable"`, or the Dolby Vision hardware refusal. A host timeout that fires first replaces it with the host's own sentence.
- **Forwarded from the failure underneath.** On the native paths this is `AVPlayerItem.error.localizedDescription` verbatim. AVFoundation localizes it into the device language. The `NSError` domain and code survive only if the localized text happens to contain them.

`$errorInfo` publishes a `PlaybackErrorInfo` beside the state. Its fields:

- `kind`: a `PlaybackErrorKind` naming what failed, in a form that survives a locale and a release
- `underlyingDomain`, `underlyingCode`: the underlying `NSError` domain and code wherever a Foundation / AVFoundation failure is involved. A non-nil `underlyingDomain` also marks the messages whose text the OS has localized.
- `hlsDiagnosticReason`: see [HLS ingest failures](#hls-ingest-failures)
- `ffmpegErrorCode`: see [FFmpeg error codes](#ffmpeg-error-codes)
- `message`: the payload described above

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

- `errorInfo` is assigned before `state`, so a `$state` sink reads this failure's info, not the previous one's.
- It is cleared when the state leaves `.error`, so the two cannot drift apart.
- Classify on `kind`. Substring rules over the message put every non-English device into "other".

#### `PlaybackErrorKind`

A string-backed struct, not an enum, so a kind added in a minor release cannot break a host's `switch`. Raw values are API and do not change.

The kinds: `.sourceOpenFailed`, `.sourceRefused`, `.customSourceProbeFailed`, `.hlsFormatUnsupported`, `.hlsIngestFailed`, `.liveSourceUnavailable`, `.hlsPlaylistOnRawLivePath`, `.dolbyVisionRequiresHardware`, `.demuxedAudioLiveUnsupported`, `.nativeItemFailed`, `.noPlayableTrackWithinBudget`, `.masterPlaylistRejected`, `.vodSourceFailed`, `.sourceRateLimited`, `.softwarePipelineFailed`, `.audioSessionFailed`, `.reloadFailed`, `.liveReloadNeverReady`, `.audioTrackSwitchFailed`, `.audioBridgeProducedNoOutput`, `.storageExhausted`, `.sourceCertificateRejected`, `.sourceFabricatesRanges`.

Kinds that need their own handling:

- **`.sourceRateLimited`** is the one to branch on separately: the source is being metered, not lost. See [Origin refusals](#origin-refusals-sourcerefused-and-sourceratelimited).
- **`.sourceRefused`**: the origin answered an HTTP status other than a rate limit instead of media; `underlyingCode` is the status. See [Origin refusals](#origin-refusals-sourcerefused-and-sourceratelimited).
- **`.sourceCertificateRejected`**: the transport was refused over certificate trust; `underlyingCode` is the `NSURLErrorDomain` code. See [Certificate refusals](#certificate-refusals-sourcecertificaterejected).
- **`.audioBridgeProducedNoOutput`** means demote to another player, not stop. The source's audio had to be transcoded into fMP4 (MP3, MP2, DTS, TrueHD, Vorbis, PCM) and produced no encoded audio at all. The mp4 muxer derives its sample entry from a written packet, so it could not build one (AE#396). The source is neither gone nor unreadable: a second player that decodes the track itself plays the file. See also [Reading whether the audio was delivered](#reading-whether-the-audio-was-delivered).
- **`.storageExhausted`** is neither a source nor an audio failure. The volume holding the loopback segment cache (the temporary directory) filled up, so no segment could be written (`underlyingCode` is `-28`, `AVERROR(ENOSPC)`). The source, its audio and every other player are fine. The same load succeeds once space is freed. It also fires when a write would break `sessionCacheHardLimitBytes` or `sessionCacheFreeReserveBytes` ([Whole-session segment storage admission](#whole-session-segment-storage-admission)), with the same `-28`, even though the volume itself may still have room.
- **`.sourceFabricatesRanges`** asks for a different load, not a retry. Load the source again with `sequentialOrigin` and `declaredDurationSeconds` (see [`sequentialOrigin`](#sequentialorigin)). The origin answered a byte range with other bytes (AE#958): a `206` named the requested offset, but the body did not hold the bytes the reader already had there. An IPTV timeshift archive answering on its own chunk boundary does this. Nothing past byte 0 can be placed.
- **`.liveSourceUnavailable`**, **`.hlsFormatUnsupported`**, **`.hlsIngestFailed`**, **`.customSourceProbeFailed`**: see the sections below.

How these kinds arrived in earlier releases is in [measurements.md › API history notes](measurements.md#api-history-notes).

#### Which kind a failed source open publishes

- **Custom source probe failed:** `.customSourceProbeFailed`, with the probe error's `underlyingDomain` and `underlyingCode` when available. It is set before the terminal `.error` state arrives, so a state observer reads the cause from `errorInfo` without parsing the message.
- **The engine's own live HLS ingest** is the exception. This is `HLSLiveIngestReader`, which a known HLS playlist URL on the live path loads through. When its probe failed because the origin refused the live playlist, the load publishes the origin's answer, as an HTTP reader's failed open does: `.sourceRateLimited` (429/503/509) or `.sourceRefused` with the status in `underlyingCode`. When the playlist could not be reached at all, it publishes `.liveSourceUnavailable`. So a host does not mistake a refusal for a stream it cannot play.
- **A plain-URL live open** (`isLive`) that the origin answers with a status fails the same way (#796). A 500 or 502 is asked once more first. A 2xx answer with a short text notice instead of media fails the same way too: that is how an Xtream panel at its connection cap answers, and it publishes `.sourceRateLimited` with 509 (#925).
- **A TLS trust refusal** on either publishes `.sourceCertificateRejected`.
- **Only a live open that reaches nothing** publishes `.liveSourceUnavailable`. The reconnect ladder first tries to ride out a transport failure. When the start gives up, the last connection's URL error domain and code are in `underlyingDomain` / `underlyingCode`. A transport failure does not prove that the media format is unsupported.

#### Origin refusals: `.sourceRefused` and `.sourceRateLimited`

Both kinds mean the origin answered the source request with an HTTP status instead of media. `underlyingCode` is that status.

- `.sourceRefused` is the origin's verdict on the resource or on itself: a 401/403 refusal (on a connection-capped IPTV panel this most often means "the slot is still held"), a 404, a 5xx.
- `.sourceRateLimited` is the same answer in the rate-limit shapes (429/503/509). It is split off because the recovery differs: the source is being metered, not lost. The same request is expected to work later, and a handoff to a second player meets the same meter (AE#377).

Both differ from `.sourceOpenFailed`, which is what a corrupt or unreadable source produces.

#### Certificate refusals: `.sourceCertificateRejected`

The transport was refused over certificate trust, so there was never a response to carry a status.

- `underlyingCode` is the `NSURLErrorDomain` code (-1200 through -1206).
- The message is the engine's own English sentence rather than the OS one, so a pasted report says the same thing on every device.
- It reaches a host from either path. On the FFmpeg path the reader types the failed open. On the native path the engine finds the URL error under AVFoundation's own error, which is where it sits.

Nothing about the media is wrong and no retry helps. A self-signed or private-CA origin needs a trust decision the host makes (AE#495, see [Certificate trust](#certificate-trust)).

#### HLS ingest failures

Outside live startup:

- `.hlsFormatUnsupported` identifies an HLS segment, encryption or demuxed-audio layout the ingest cannot handle.
- `.hlsIngestFailed` identifies invalid playlists, invalid responses, decryption failures or an ingest stall.

Both keep the underlying `HLSIngestError`; for diagnosis, use the optional subreason below. These kinds describe the failure. They do not pick a host's retry or fallback policy. Live startup keeps `.liveSourceUnavailable`, except for HTTP and TLS refusals; the original cause stays available as described under [Diagnostics](#diagnostics).

`PlaybackErrorInfo.hlsDiagnosticReason` carries an optional `HLSIngestDiagnosticReason` (a fixed set of values) taken from an underlying `HLSIngestError`, also through Foundation error wrappers. `HLSIngestError.diagnosticReason` exposes the same value directly.

- Each of these causes has its own stable raw value: missing EXTM3U, missing TARGETDURATION, an empty segment list, invalid response/encoding, an `EXT-X-BYTERANGE` the playlist or the origin's answer cannot satisfy (`invalidByteRange`), unsupported encryption, and key/decryption failures.
- An unknown playlist or decryption message maps to a fixed fallback value, never to a new token that contains the message.
- The field adds detail only. It does not change the failure's classification or recovery policy.
- Explicit `HLSIngestError` NSError codes match the historical Swift bridge; its error domain and human-readable descriptions are kept.
- The message is still free-form payload, not safe structured telemetry.

#### FFmpeg error codes

`PlaybackErrorInfo.ffmpegErrorCode` optionally carries the original negative FFmpeg result of a demux failure, also through an NSError wrapper. It is separate from `underlyingCode`, where the historical `AetherEngine.DemuxerError` case codes remain
0 (open), 1 (stream information), and 2 (read).

- A thrown demux NSError carries the same FFmpeg value under `AetherFFmpegErrorCode` in `userInfo`.
- Missing or invalid metadata leaves the field nil. The existing error domain, message and case code keep their meaning.
- For FFmpeg-specific diagnostics or compatibility decisions, use this field. Do not read a case code as an FFmpeg result.

#### Software live read failures

A read failure on a software live source, including an interrupted verified replay, reports `liveSourceUnavailable`, not `softwarePipelineFailed`. The source broke off; that is no evidence that the codec needs a different engine. The host picks retry timing through its usual live recovery policy. The software route's error stays available through `$errorInfo` and `.error`.

### `.ended` is terminal

**What the host must do:** to replay, call `load(...)` again.

`.ended` means the source played to completion, on any backend. It is not a pause at the last frame:

- `seek(to:)` is rejected with `SeekEvent.Rejection.noActiveSession`
- `play()` and `togglePlayPause()` do not revive the session

This is on purpose: a play press racing a host's end card must not quietly restart a finished session (#63/#164).

A VOD **parked at its final frame** without having ended (scrubbed or paused there) is a different case. It does resume: `play()` rewinds to the start first.

The clock stops too, on both backends. `clock.currentTime` and `clock.sourceTime` settle on the last sample and stay there. A progress bar bound to them holds at the end instead of running past `duration`.

Builds before 6.28.0 (software path) and 7.27.0 (audio-only path) behave differently here: [measurements.md › The clock after `.ended`](measurements.md#the-clock-after-ended).

### Live: the retune request

**What the host must do:** subscribe to `liveSourceReset` once, before the first live load (the subject lives as long as the engine and has no replay). When it fires, back off, then call `retryLiveSourceRecovery()`. If that returns `false`, run a bounded full-load policy. Keep one recovery in flight.

```swift
player.liveSourceReset            // PassthroughSubject<Void, Never>; one subscription per engine, no replay
```

Left unsubscribed, a channel stops while the engine still reports a session. From the outside that looks like a slow session. The guard, written out: [`Examples/LiveHost/LiveChannelHost.swift`](../Examples/LiveHost/LiveChannelHost.swift).

**When it fires.** The event asks the host to negotiate the source again. It fires when:

- the engine's bounded recovery round cannot continue acquiring the source, for example after a changed track layout, or ordinary source loss that used up in-engine recovery
- the stalled consumer asks for the source to be acquired again
- verified replay cannot reach new media (by default; see [exhausted verified replay](#live-exhausted-verified-replay) for the opt-in alternative)

**What the engine tries first.** An interrupted exact replay first tries the bounded in-engine source reopen, when there is a URL or a fresh-reader factory. The reopen:

- keeps the same cache, player item and bounded exact-packet history, so media already in the DVR window is not appended twice, even when the viewer is behind live
- retires the failed connection before opening the replacement
- continues in place when the new data overlaps completely; an ambiguous clock reset gets ordinary discontinuity handling

Recovery onto a fresh source ends an active recording with `sourceReset`. It never splices a new source into the old file.

**How to answer.** After your own backoff, try `retryLiveSourceRecovery()` first. A native live session that has produced media before can renew its source and keep its DVR timeline, even before any replay was detected.

- `false` means fresh negotiation is needed, for example after a changed track layout, or for a custom reader without a reopen factory. Use a bounded full-load policy then.
- Do not turn ordinary source loss into a decoder compatibility failure just because an origin stays unavailable.

**A same-URL retune is cheap.** The engine remembers the #168 carriage verdict (a master that advertises HEVC but delivers MPEG-TS) per exact absolute URL for six hours, 32 entries. So the retune goes straight onto the live ingest, and does not pay again for the doomed native mount and its watchdog grace.

A URL with a rotated per-session token misses that memory, so every retune pays the one-time discovery again. That matters where the first-frame budget is measured on retunes too.

**Where the token rotates**, the host has a key the memory lacks: the channel. `$videoRoute` publishes the reroute as it happens (`.remoteBypass` becomes `.loopback`). A host can store that verdict under its own channel id and open the channel's next session on the ingest directly, in one of two ways:

- with `nativeRemoteHLS: false` (from 6.24.0 an `m3u8` on the raw live path is routed onto the ingest reader, at the cost of one failed open)
- by handing `HLSLiveIngestReader` to `.custom(_:formatHint: "mpegts")` itself, which costs nothing at all

Either way skips the native mount and up to 4 s of carriage-watchdog grace per retune, whatever the URL looks like this time.

### Live: exhausted verified replay

**What the host must do:** only if it sets `LoadOptions.hostRetriesExhaustedLiveReplay = true`, subscribe to `liveSourceReplayExhausted` and retry with `retryLiveSourceRecovery()` under its own backoff.

`liveSourceReplayExhausted` is an engine-lifetime subject (one subscription per engine, no replay). It fires when native HLS recovery has verified the packets it already admitted but cannot reach new media.

- It fires only for a session loaded with `LoadOptions.hostRetriesExhaustedLiveReplay = true`. Without that option, the same exhaustion publishes `liveSourceReset`, so a host that only knows that event still retunes.
- Production pauses, while the cached DVR media and the replay history stay available.
- It is a source recovery event, not a codec failure, and not a requirement to show an error.

`retryLiveSourceRecovery() -> Bool` resumes source acquisition into the same cache and consumer item.

| Returns | When |
| --- | --- |
| `true` | the retained session accepts the request, or has a retry in flight |
| `false` | after stop/replacement, on unsupported routes, or when a changed track layout requires fresh negotiation |

- Concurrent calls coalesce.
- A stalled live producer can be renewed this way too. Its reader is cancelled, and its pump must finish before the history moves to a replacement.
- A new exhaustion publishes the subject again. Retry delays, cancellation and any overall limit are the host's to decide.
- Calling `load` or switching decoders instead throws this history away and can replay the old broadcast.

Once a session has verified replay, a later source-open exhaustion keeps this same contract, even if an earlier reconnect produced new media. A changed track layout still uses `liveSourceReset` for fresh negotiation.

### Live: a resume that had to move

**What the host must do:** subscribe to `liveResumeClamped` and tell the viewer that the resume moved, or set `clampsLiveResumeToWindow = false` and own the decision.

```swift
player.liveResumeClamped          // PassthroughSubject<LiveResumeClamp, Never>; one subscription per engine, no replay

public struct LiveResumeClamp {
    public let skippedSeconds: Double      // content the sliding window took while the session was paused
    public let behindLiveSeconds: Double   // where the resume landed; 0 for an edge snap
}
```

A session paused for longer than its DVR depth has lost the position it was parked on: the sliding window dropped it. So the resume cannot start where the pause stopped. `clampsLiveResumeToWindow` (default on) moves it to the oldest retained point, or to the live edge on a live-only session. This event fires when that happens.

It exists so the host can tell the viewer; without it, the resume moves silently ([measurements.md › Live resume clamp](measurements.md#live-resume-clamp)). Both fields are ready to show, with no arithmetic against a window the host cannot see: "you missed fourteen seconds", or "continuing twenty-five seconds behind live".

A host that owns the decision sets `LoadOptions.clampsLiveResumeToWindow = false` instead. It gets a log line naming the deferral, and nothing fires.

### The system asks for captions

**What the host must do:** subscribe to `systemCaptionRequest` and answer by selecting its own matching track, if it wants the behaviour.

```swift
player.systemCaptionRequest       // PassthroughSubject<SystemCaptionRequest, Never>; one subscription per engine, no replay
```

iOS 26's Automatic Subtitles (shown when muted, on skip back, or on a language mismatch) turn captions on, and there is no API to read that setting. The selection itself is the only request a host can see. The engine deselects its own rendition, because in fullscreen it would draw a caption box over the host's overlay. Then it forwards the request with the language the system named.

### The engine moves a refused session onto the software path

**What the host must do:** nothing, unless it runs its own fallback ladder. Then set `escalatesToSoftwarePath = false` and handle the failure as `.error`. Either way, `softwarePathEscalations` reports each rebuild.

```swift
player.softwarePathEscalations   // PassthroughSubject<SoftwarePathEscalationEvent, Never>; one subscription per engine, no replay
options.escalatesToSoftwarePath  // default true; false declines the rebuild
```

**What it does.** Sometimes AVPlayer fails a native item over the MEDIA itself (`CoreMediaErrorDomain`, typically `-19602` on a sample Apple's parser refuses). Every native recovery would reload the same bytes. So the engine does not end the session: it spends one rebuild per session on `SoftwarePlaybackHost`, at the session's playhead (AE#561). libavcodec skips the frame Apple refused and plays on.

**Where it applies.**

- On the remote-HLS bypass, only for a finite playlist (AE#990). The rebuild is the same load with `.software`. A playlist of MPEG-TS segments plays from the seekable TS ingest. Any other playlist mounts on AVPlayer once more and surfaces that failure.
- A live bypass keeps its own reroutes onto the live ingest.
- Not on a session already asked onto `.software`.
- Not for a URL-loading failure, which both paths would read through the same reader.
- Whether the software path can serve the source at all is the same check a `preferredDecodePath` correction runs.

**What the event carries.** It fires the moment the rebuild starts. It carries:

- the failure it absorbed, as the `PlaybackErrorInfo` it would have published (`kind` `.nativeItemFailed`)
- the position
- whether a `load()` was still waiting

- If the rebuild fails, the original failure is published as `.error` the usual way.
- If it succeeds, `videoRoute` moves to `.software`.
- A take during startup does not end the host's `load()` with a `CancellationError`. That call keeps waiting across the rebuild and returns the probe it already assembled.

**Opting out.** A host that re-plans a failing title with its own ladder (a transcode rung, a second player) sets `escalatesToSoftwarePath = false` and gets the failure as `.error`. It is a tuning field, correctable through `reloadAtCurrentPosition(applying:)`.

**Live joins.** A live join takes the same step when the source delivers video for the whole keyframe wait (15 s), but no picture the native route can start a segment on: no IDR, and no recovery point with `recovery_frame_cnt` 0. A feed that carries only gradual intra refresh looks like this (AE#627). Reopening would join the same bitstream, so the first join does not spend its reopen cycles on it.

- The absorbed failure carries the domain `AetherEngine.LiveJoin`.
- With `escalatesToSoftwarePath = false`, or when the step is not on offer, the join ends as `liveSourceReset` right there. The reopen cycles would have ended it the same way a minute later.
- A starvation after the session has produced segments keeps its reopens.

### The audio tap ends with its session

**What the host must do:** re-install the tap whenever its stream ends, and check `audioTapHasDeliverySource` right after installing.

`installAudioTap()` returns an `AsyncStream<AudioTapBuffer>` bound to the session it was installed against. It finishes on:

- `load()`
- `stop()`
- a **session-preserving reload**: an audio-track switch, a subtitle-track switch, a disc-title switch, `reloadAtCurrentPosition()`

Re-install on stream end to follow the new session (#356). This is on purpose. Each install gets a fresh monotonic filter, so the new session's timeline starts clean. Otherwise it would be stitched across a reload that resumes slightly behind the old position.

Read `audioTapHasDeliverySource` synchronously after installing. `false` means the stream will finish without yielding anything: no session, a video-only source, or a backend with no tap path. Fail loudly then, instead of awaiting an empty stream.

**Dialogue only.** `installAudioTap(channels: .dialogue)` builds the mono output from the front-centre channel alone, not from every channel (#908). On a 5.1 or 7.1 mix the dialogue sits there. A speech recognizer working on the full downmix hears it under the score and effects of the other channels.

- The format does not change.
- A source with no centre (mono, stereo, 2.1, a discrete layout) is delivered as the downmix. Every `AudioTapBuffer` says which it carries in `channels`, so a host can tell an isolated centre from the fallback.
- A source that states only a channel count is read in the default order for that count.
- Dialogue that lives only in Atmos objects is not in the centre channel and is missed either way.

### Correcting a `LoadOption` without restarting the item

**What the host must do:** to change an option on a playing session, call `reloadAtCurrentPosition(applying:)`, not a fresh `load()`. Handle its two refusals, and do not use it to change `autoplay`.

`reloadAtCurrentPosition(applying:)` is the session-preserving rebuild, but it replays options the host corrected instead of the session's own (#460).

```swift
try await player.reloadAtCurrentPosition { $0.httpHeaders["Authorization"] = "Bearer \(fresh)" }
```

The closure receives the options the session is CURRENTLY running on. That is not always what was passed to `load`, because the engine rewrites its own routing fields on a reroute. Change what needs correcting and leave the rest alone.

The change is installed into the session before the rebuild. So every internal reopen after it (an audio switch, a background reload) replays the correction and does not fall back to the load-time value.

**Why not a fresh `load()`.** `load` cannot set `subtitleSessionCarryover` or `isLiveRejoin`; only the engine can. So a fresh load wipes the following, and re-derives it by auto-selection:

- the id-exact external-subtitle registry
- every mid-session `addExternalSubtitleTrack`
- the host's explicit subtitle authority (subtitles explicitly OFF included)
- the live rejoin contract

This reload keeps all of it, at the same teardown cost as the plain `reloadAtCurrentPosition()`.

#### What the call returns

The call hands back a `SessionOptionCorrectionOutcome`:

- `applied`: the fields the correction applied
- `sessionOwned`: the fields the session owns and kept
- `rebuilt`: whether the session was torn down at all

A field the session owns costs no rebuild, because there is nothing for a rebuild to carry (AE#464 round 4). Two empty lists with `rebuilt` true mean the session was already running on that correction; that case does rebuild.

```swift
let outcome = try await player.reloadAtCurrentPosition { $0.autoplay = false }
// outcome.applied == [], outcome.sessionOwned == ["autoplay"], outcome.rebuilt == false
```

The result is `@discardableResult`, so a host that only needs the refusals can ignore it.

**`autoplay` cannot be changed this way.** To change the transport, call `play()` / `pause()` around the correction. The rebuild comes back in the transport state the session is actually in (AE#464 round 2), so a correction that sets `autoplay` is overwritten, not refused.

- The log says so. The field is not named in `#460: reload applying ...`; it gets its own `#460: autoplay not applied, the session owns it` line (AE#464 round 3).
- It costs no teardown and comes back as `sessionOwned` (round 4).
- The one rebuild that DOES apply the flag is the resume after a background teardown (#357). It has no session transport left to keep, so there the field is named as applied.

#### Refusals

Both refusals are thrown BEFORE any teardown, so a refused correction leaves the session playing. Both are all-or-nothing: if one field is refused, none of the correction is installed.

| Thrown | When |
| --- | --- |
| `AetherEngineError.loadIdentityNotCorrectable(fields:)` | the closure changed `isLive`, `audioOnly`, `nativeRemoteHLS`, `sequentialOrigin`, `heldSourceConnection`, `sharedOutputRole` or `sourceDiagnosticsContext`. Load the source again instead. See note 1. |
| `AetherEngineError.sessionNotReloadable(_:)` | there is no session, or the source is a custom `IOReader` that reported itself non-seekable and cannot be reopened at the current position. Its `SessionReloadRefusal` says which (`.noActiveSession` / `.customSourceNotSeekable`); a correction can also throw the cases below. |
| `AetherEngineError.sessionNotReloadable(.softwarePathCannotRepresentSource)` | the correction moves a native session onto the software path, and the source's only signal is IPT-PQ-c2 (Dolby Vision HEVC Profile 5, AV1 Profile 10.0). The software decoders pass that on as YCbCr, so the picture would render green/purple. |
| `AetherEngineError.sessionNotReloadable(.dualLayerRouteNeedsFreshLoad)` | the correction changes `preferDualLayerDolbyVision` (or `dolbyVisionHandling` or `dualLayerRoute` while the preference is on) on a custom `IOReader` Profile 7 session. The in-place rebuild keeps the route the session was loaded with; call `load()` again with the new option. |
| `AetherEngineError.sessionNotReloadable(.upscaleRouteNeedsFreshLoad)` | the correction turns `upscalesLowResolutionVideo` on, or changes `upscaleScaler` while it is on (AE#1039), for a custom `IOReader` session. Call `load()` again with the new option. See note 2. |
| `AetherEngineError.sessionNotReloadable(.demuxedAudioLiveIsNativeOnly)` | the correction moves a demuxed-audio live session onto the software path. The side-audio merge does not exist there, so it would play silent. |

1. **Identity fields.** These name the session rather than tune it: each opens the source on a different pipeline or gives the session a different role. Changing one makes a different item, not a correction.
   - The engine writes `nativeRemoteHLS` and `sequentialOrigin` itself.
   - `heldSourceConnection` picks the transport when the source is opened, so a correction could not take effect (AE#377).
   - `sourceDiagnosticsContext` identifies the original load and its requests. Pass a different context to a fresh `load()`. A tuning correction that keeps the context is allowed.
2. **Upscale route.** `load()` decides the route, and the in-place rebuild does not re-run it. Turning upscaling off is honoured in place: the rebuilt session stays on the software path, delivers frames as decoded and clears `$activeUpscale`. URL sources re-run `load()` and are not refused.

`SessionReloadRefusal` is a public enum that gains cases over time; switch over it with a `default:`.

`sessionReloadRefusal` predicts the two session-level refusals (`.noActiveSession`, `.customSourceNotSeekable`) without attempting a reload. It is nil when a rebuild would happen. The correction-specific refusals depend on the proposed options, so only the throw reveals them.

#### Where a correction lands

- **A URL source** rebuilds through the full `load`, so every field applies.
- **A custom `IOReader` source** rebuilds through a narrower reopen that keeps the retained reader. That path replays `loadedOptions` field by field instead of passing the struct through `load`:
  - The routing, probe-budget, live-join, deinterlace and subtitle-preparation fields all apply.
  - The four fields `load` itself consumes (`preferredAudioLanguages`, `externalSubtitles`, `maxConcurrentSourceRequests`, `autoplay`) are installed and take effect at the next load. The custom reload carries the session's explicit audio pick and its own subtitle re-arm, so the two language lists would have nothing to decide on that path anyway.

`preferredDecodePath` is in the first group. The reopen asks the same routing policy as `load`, starting from the session's current backend, so the correction lands on both source shapes.

This is safe because it only goes one way. `DecodePath` has no `.native`, so the reopen can only flip native to software, and the software path is the general one. What the software path cannot REPRESENT is refused before any teardown (the `.softwarePathCannotRepresentSource` and `.demuxedAudioLiveIsNativeOnly` rows above). Inside `load` those guards run after the routing decision; reaching them on a correction would fail a session that is already torn down.

#### Errors

- This call always throws when there is nothing to rebuild. The plain `reloadAtCurrentPosition()` is different: it throws `sessionNotReloadable` only on a custom source (no session, or a forward-only reader, AE#526), and on a URL source with no session it returns without doing anything. A host correcting a session needs to tell "corrected" from "did nothing", to decide whether to fall back to a fresh load.
- A rebuild that FAILS also throws what the rebuild threw, on both source shapes.
- A rebuild superseded by a newer `load` or `stop` throws `CancellationError`, on both source shapes. That is not a failure: the newer load owns the session. Let it pass, as after a superseded `load()`.

### Rotating a credential without a rebuild

**What the host must do:** when a bearer token is about to expire, call `updateRequestHeaders(_:)` with the new set. Subscribe to `sourceAuthorizationRefused` to renew as soon as the origin refuses one.

Some media servers require a bearer token on every request, and the token can expire while a title plays. Then the next request needs a new header, and nothing else should change. `updateRequestHeaders(_:)` does exactly that, without the teardown of `reloadAtCurrentPosition(applying:)` (AE#792):

```swift
let outcome = player.updateRequestHeaders(["Authorization": "Bearer \(fresh)"])
```

How it works:

- **The set replaces the session's headers**, the way `LoadOptions.httpHeaders` sets them at `load`. It is not merged.
- **The next request carries it.** Every source reader of the session reads its headers per request from one store, created at `load`. That covers the playback demuxer, the producer's reopens and revives, the I-frame and embedded-subtitle side readers, and the still extractor that `makeFrameExtractor()` returns for the session's own source.
- **A request already in flight** finishes with the headers it was sent with.
- **A reconnect already backing off** after a refusal sends the new set on its next attempt. So a session stalled on a lapsed credential (`.stalled(reconnecting: true)`) recovers without a rebuild once the host supplies a current one. Renewing before the expiry avoids the stall entirely.
- **Rebuilds keep it.** The set is also installed into the session's options, so every rebuild that replays them (an audio switch, a background return, `reloadAtCurrentPosition()`) opens with it.
- **Redirect scoping is unchanged:** a credential still does not follow a cross-origin redirect.
- The log names the header names it replaced, never their values.

The call returns a `RequestHeaderUpdateOutcome`:

| Outcome | When |
| --- | --- |
| `.appliedToLiveRequests` | every source request is made by the session's own readers: the `.loopback`, `.software` and FFmpeg `.audio` routes, and a load still opening. |
| `.installedForNextRebuild` | the requests come from something that fixed its headers when the session was built (see the note below). Call `reloadAtCurrentPosition()` if the set is needed now. |
| `.noActiveSession` | nothing is loaded; nothing was installed. |

Headers fixed at build time: AVFoundation on `.remoteBypass` or an AVPlayer-hosted audio item, a custom `IOReader` the host built, a remote disc image, a DASH manifest.

#### When the credential lapses anyway

A 401 or 403 mid-session is not treated as a dropped connection.

1. The reader gives it a short ladder of its own: the refused request, then two retries, about 3 s. The first retry re-resolves an expired signed redirect through the source.
2. The first refusal of a header set is published on `sourceAuthorizationRefused` (`AnyPublisher<Int, Never>`, the status). The host can renew right away. A timer based on the token's expiry would miss a token an admin revoked early.
3. A renewal that arrives while the reader is still retrying gives it a fresh ladder.
4. Once the reader has given up, the native loopback session waits up to 10 s for new headers. A renewal in that time rebuilds the producer at the playhead (up to three times per session). Otherwise the session ends with `PlaybackErrorKind.sourceRefused` and the status as `underlyingCode`, not `vodSourceFailed`.
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

**Why it is needed.** `VTCapabilityProbe.canHardwareDecode` **fails open by design**: four classes it cannot classify keep the native path. They are no extradata, Annex-B extradata, in-band parameter sets, and a format-description build failure. That is the right default, but occasionally wrong. When VideoToolbox then cannot build a decoder for what arrives, the item reaches `readyToPlay` and renders nothing. In-band parameter sets (`hev1` / `avc1` with an empty config record) are the class where the deciding evidence truly is not there at load time.

A live H.264 / HEVC load never reaches that check. For those codecs it is VOD-only, so a live session keeps the native path without being classified. Live AV1 is judged by profile, as for VOD (High and Professional go software).

**Detecting the symptom** is the host's job, and it is simple: call `hasRenderedVideoFrame()` some seconds after `readyToPlay`. It answers for both backends. (`softwareHostFramesEnqueued` is the software route's own counter and stays zero on the native path.) Do not use `setForceSoftwarePathForTesting` instead: it is process-global and drags along every concurrent session on a shared engine.

What to know:

- **One-way.** `DecodePath` has `.automatic` and `.software`, and no `.native`. The engine only sends a route to software when the native path cannot serve it (AV1 without hardware decode, VP9, a forward-only source, MVC carriage). Forcing native there gives a black screen. A host's evidence can only ever be "this native session is not decoding".
- **It does not override what the software path cannot represent.** A source whose only signal is IPT-PQ-c2 (Dolby Vision HEVC Profile 5, AV1 Profile 10.0) still fails the load with `dolbyVisionUnplayableOnSoftwarePath`, instead of decoding as YCbCr and rendering green/purple. A demuxed-audio live source still fails instead of playing silent. An override picks which host serves the session, not what that host can do.
- **`nativeRemoteHLS` is a different route, with one exception.** There AVPlayer plays the remote playlist and the engine demuxes and decodes nothing, so usually there is no decode path to prefer. The engine logs that it ignored the preference, so it does not look applied. See the note on the exception below.
- **An audio-only session honours it too.** With `audioOnly`, `.software` sends a codec AVPlayer could play (FLAC, ALAC, AAC, MP3, LPCM...) to the FFmpeg host (internal `AudioPlaybackHost`) instead of the AVPlayer audio host (internal `AudioAVPlayerHost`). The audio dispatch line in the log says the host asked for it. The cost is the system Now-Playing session: as for every audio-only source the FFmpeg host plays, `audioNowPlayingSession` is nil. A host that registers its transport commands on that session must drive Now Playing itself for such a session, through `MPNowPlayingInfoCenter.default()` and `MPRemoteCommandCenter.shared()`.
- **A mid-play correction lands on both source shapes**, URL and custom `IOReader` alike. It moves the session at its own playhead, without a restart. On a source the software path cannot represent, the correction is refused before any teardown with `SessionReloadRefusal` `.softwarePathCannotRepresentSource` or `.demuxedAudioLiveIsNativeOnly`, so the session keeps playing.

The `nativeRemoteHLS` exception (AE#990): a finite, unencrypted playlist of MPEG-TS segments. With `.software` it moves onto the seekable TS ingest that the AE#268 HEVC route uses, and decodes in software whatever the codec. The ingest serves `startPosition` and seeks. This covers a playlist reached through the AE#154 reroute of a `.url` load too. fMP4, live and encrypted playlists keep the bypass.

The mid-play correction, measured on the Dolby browser test kit, which has both variants: the Profile 5 cut of a clip is refused and keeps playing on VideoToolbox. The Profile 8.1 cut of the SAME material and grading is honoured and rebuilds on `libavcodec HEVC (SW)`.

### Reading whether the audio was delivered

**What the host must do:** a fallback ladder demotes on `$audioDelivery == .droppedNoPipeline`. Show `$activeAudioDecoder` to people, but never classify on it.

`$audioDelivery` publishes an `AudioDelivery`: how this session's audio reaches the renderer, as a typed fact (AE#462).

| Value | Meaning |
| --- | --- |
| `.none` | no session |
| `.noAudioInSource` | the source carries no audio track |
| `.streamCopy` | the source bitstream reaches the renderer unchanged. See note 1. |
| `.bridged` | decoded and re-encoded for the fMP4 pipeline. See note 2. |
| `.decoded` | libavcodec decodes to PCM and the engine renders it (the software path without an object-audio route, the FFmpeg audio-only host) |
| `.droppedNoPipeline` | the source HAS audio, but none of it could be delivered. The session plays video-only, silently. See note 3. |
| `.playerManaged` | AVFoundation owns the audio (the remote-HLS bypass, the native audio-only host). The engine has no pipeline of its own to classify and does not answer for AVFoundation. |

1. **`.streamCopy`**: muxed into fMP4 (Atmos, DTS-HD and everything else as authored). Or, on the software host off tvOS under `objectAudioRendering`, an E-AC-3 JOC track handed to the sample-buffer renderer still compressed.
2. **`.bridged`** has two forms:
   - The channel bridge to FLAC or E-AC-3. Lossless for the bed channels; object metadata is lost in the PCM intermediate.
   - Under `objectAudioRendering`, in a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default): rendered with its objects and heights into a speaker bed, on the loopback route and on the software host alike. The bed is delivered as lossless PCM (the `.render` default) or as APAC (lossy: on AirPlay, or forced with `.apac`).
   - On the tvOS software host it also covers E-AC-3 JOC that the system's Atmos decoder decoded into a PCM bed (AE#995).
3. **`.droppedNoPipeline`** causes: no decoder for it in this build; the bridge could not be built or could not write its header; the probe left its parameters empty, so no stream could be picked; or (live only) the bridge was built but its decoder produced nothing, after which the engine rebuilds the session without the track (AE#641).

```swift
player.$audioDelivery
    .filter { $0 == .droppedNoPipeline }
    .sink { _ in ladder.demote(reason: .silentVideo) }
```

**`.droppedNoPipeline` is the value a fallback ladder acts on**, just as it demotes on `PlaybackErrorKind.audioBridgeProducedNoOutput`. The two are the same outcome for the viewer, seen from opposite ends:

- `audioBridgeProducedNoOutput` fails loudly when a VOD bridge WAS built and then decoded nothing, the FLAC route included (AE#641).
- `.droppedNoPipeline` reports a bridge that could never be built at all.
- A live session whose bridge decodes nothing also ends at `.droppedNoPipeline`, not at the error. Its video is playable, and a live source has no position to hand to a second player. So the engine rebuilds it video-only by itself, and the value changes from `.bridged` to `.droppedNoPipeline` (AE#641).

Neither has to end the ladder. Serving the source again with audio the pipeline can carry plays it: a server-side transcode, or a second player that decodes the audio itself.

It is not a `PlaybackErrorKind`, because those are terminal: `state` moves to `.error`, and `errorInfo` is cleared when the state moves on. Video-only playback is not terminal, and not an error for every host.

**`$activeAudioDecoder`** is the same fact for a human (`"Stream-copy (EAC3+JOC Atmos)"`, `"TrueHD → FLAC bridge"`, `"libavcodec AC3 → CoreAudio"`). Show it in a stats overlay. Do not classify on it: it cannot tell a source with no audio from a source whose audio was dropped. Both publishers are written by the pipeline that serves the session, so `.droppedNoPipeline` and a nil label arrive together.

### What must be set before `load()`

**What the host must do:** set the engine properties below before calling `load()`. A later change does not reach the running session. The `LoadOptions` fields further down go into `load()` anyway; for them, the point is that changing one later costs a reload.

#### Engine properties to set before `load()`

| Property | Why |
| --- | --- |
| `ownsVideoNowPlayingSession` | read when the native host is created; a host preserved across a native to native reload keeps what it was created with |
| `ownsSoftwareNowPlaying`, `remoteSkipInterval` | read when the software host is built |
| `pictureInPictureActive` | governs the background teardown decision at the moment it happens |
| `logTag` | written into the shared-output book when the load joins it; a tag set later is missing from those log lines until the next `load()` |
| `rendererAudioSessionActivationEnabled` | read by software and audio-renderer loads; see [Host-managed renderer audio activation](#host-managed-renderer-audio-activation) |

#### `LoadOptions` that cost a reload to change

These take effect inside `load` itself. To change one on a playing session, use [`reloadAtCurrentPosition(applying:)`](#correcting-a-loadoption-without-restarting-the-item). Defaults and full descriptions are in [LoadOptions](#loadoptions).

| Option | Why |
| --- | --- |
| [`preferredAudioLanguages`](#audio) | the picked audio track is muxed at the first frame; a later `selectAudioTrack` costs a reload |
| [`prepareNativeSubtitles`, `externalSubtitles`](#subtitles-and-scrubbing) | the native renditions are declared in the init segment |
| [`panelIsInHDRMode`, `panelPresentsDolbyVision`, `matchContentEnabled`](#display-and-hdr) | the display-criteria handshake and the format clamp both run synchronously inside `load` |

### Isolation, and what runs off the main actor

**What the host must do:** drive the engine from the main actor. Call `probe` from a background queue, and make the frame-time observers and log handlers thread-safe.

`AetherEngine` is `@MainActor`. Every method and property in this reference is main-actor isolated unless it says otherwise. A host drives it from the main actor and receives its published values there.

The notable exceptions:

- **`AetherEngine.probe(...)` and `probeDetectingAtmos(...)` are `nonisolated` and synchronous**, and they open the source: a HEAD plus an initial range on a network URL, and a real decode pass for the Atmos variant. Call them from a detached task or a background queue. On the main actor they block it as long as the origin takes, which on a slow origin is seconds. The same holds for `probeDolbyVisionEnhancementLayer(url:options:)`.
- **The prewarm statics are `nonisolated`**: `prewarm(url:httpHeaders:byteBudget:)`, `isPrewarmed(url:)`, `discardPrewarmedSources()` and `prewarmDualLayerDolbyVision()`. So is `AetherEngine.version`. `defaultPrewarmByteBudget` is not; it is read on the main actor.
- **`presentationAxisMap` is `nonisolated`**, so a compositor pairing samples off the main actor can convert without hopping actors.
- **The two frame-time observers are `@Sendable` and run on the pipeline's own threads.** `NativeVideoFrameTimeObserver` runs on the producer pump, in decode order. `SoftwareVideoFrameTimeObserver` runs on the software decode thread, inline with the handover to the renderer, in presentation order. Neither may block or assume the main actor.
- **`EngineLog.handler` and `EngineLog.structuredHandler` fire on whatever thread emitted the line** (demuxer, producer, local server, audio bridge). Hop onto your own queue before writing anywhere.

`player.clock` is a separate `@MainActor ObservableObject` on purpose. Otherwise its ~10 Hz ticks would fire `objectWillChange` on the engine and re-render every view observing it; on tvOS that rebuilds open `Menu` dropdowns while the viewer uses them. Time-driven UI observes `clock`; everything else observes the engine. `diagnostics` is split out for the same reason, at 1 Hz.

`FrameExtractor` is an `actor`, so its `thumbnail` / `preview` / `snapshot` / `prewarm` / `shutdown` are `await`ed from anywhere. The audio tap's `AsyncStream` can be consumed from any task too; only `installAudioTap()` itself is main-actor.

### Running several engines at once

**What the host must do:** load one engine as `.primary` and the others as `.secondary`, set `logTag` on each before `load()`, switch the audible one with `volume`, and `stop()` every engine before letting go of it.

```swift
let tile = LoadOptions(sharedOutputRole: .secondary)
```

Every engine keeps decoding its audio, so switching the audible one is a volume change, not a reload.

**What `.secondary` changes.** A `.secondary` engine never writes display criteria and never owns Now Playing, whatever `suppressDisplayCriteria` and `ownsVideoNowPlayingSession` say. This holds on the audio-only path too. It also skips the play gate's wait for a criteria write, and the panel readout (`criteriaPanelReadout` is nil, as for any suppressed load). So its HDR labelling relies on `panelIsInHDRMode`.

- The role is fixed for a session, but a later `load()` may change it. As an identity field it only blocks corrections (Sodalite#175).
- A host that opted into `ownsVideoNowPlayingSession` and changes the role without a `stop()` keeps the native host's original Now Playing ownership until the next stop.

**What the engines share.** Each `AetherEngine` has its own loopback server, caches and lifecycle, so two or more can play side by side (a multiview grid). They share the process: the audio session, its channel preference, and the panel's display criteria. The engine keeps one internal record of who is still playing (`SharedOutputCoordinator`) and acts on it:

- **Audio session.** Only the last engine to stop releases it, and only if some engine in that round had `deactivatesAudioSessionOnStop`.
- **Channel count.** The preferred output channel count follows the widest source among the playing engines, so a muted stereo tile cannot downmix a 5.1 one.
- **Display criteria.** A reset waits until the last engine stops. That includes the resets a load runs to clear stale criteria. An engine that loads again as `.primary` in the meantime cancels its own pending reset; one that loads again as `.secondary` keeps it.
- **Disk.** Each session gets an allowance for seek and timeshift history: a quarter of the free space, at most 2 GiB per session unless `liveDVRByteBudget` lifts it on the software route. It is taken from what the other running engines have not claimed yet, so side-by-side engines cannot claim the same space twice. A claim ends with the session.
- **Stop every engine before you let go of it.** An engine counts as playing from `load()` until `stop()`, whatever its state, `.error` and `.ended` included. Stop an engine kept for reuse when its tile ends or fails, or the last real stop will not release the session. An engine released without `stop()` is noticed and dropped the next time another engine asks; until then it counts as playing.

## Constructing and binding

```swift
let player = try AetherEngine()
```

| Symbol | What it is |
| --- | --- |
| `AetherEngine()` | `public init() throws`, `@MainActor`, an `ObservableObject`. Use one engine per playback surface. See note 1. |
| `AetherPlayerSurface(engine:)` | SwiftUI view. Drop it in the tree; it mounts and binds an `AetherPlayerView` for you. |
| `AetherPlayerView` | UIKit / AppKit view (`PlatformBaseView` is `UIView` or `NSView`). Hosts the engine's layer. |
| `bind(view:)` | Attach a view. The engine swaps the hosted `CALayer` per session (`AVPlayerLayer` or `AVSampleBufferDisplayLayer`), so a bound host needs no per-route branch. See note 2. |
| `unbind(view:)` | Detach. The engine holds its views weakly, so this is for hosts that reuse one engine across surfaces. Unbinding the view the layer is on moves the layer to the most recently bound view still alive. |

1. **`AetherEngine()`.** Several engines against one origin cost that origin one long-lived request each (see `maxConcurrentSourceRequests`). The audio-session category is declared off the main thread at the first load in the process, and left alone if the host already chose `.playback`. The engine never activates the session here: AVKit activates it per playback, and that is what lets tvOS negotiate the HDMI route (#24).
2. **`bind(view:)`.** The layer shows on the most recently bound view that is still alive. An earlier view stays a fallback until it is unbound or released. That keeps the picture when a surface is remounted by identity on the same engine (AE#536). Binding a view another engine held takes it over from that engine; this is the common case when a multiview grid reuses a view.

## Loading

```swift
try await player.load(url: url)
try await player.load(url: url, startPosition: 347.5, options: LoadOptions(...))
try await player.load(source: .custom(reader, formatHint: "matroska"), options: ...)
try await player.reloadAtCurrentPosition()
```

| Symbol | Contract |
| --- | --- |
| `load(url:startPosition:options:audioSourceStreamIndex:discTitleID:)` | `async throws -> SourceProbe?`. Discardable. Tears down any running session first. Returns the load's own `SourceProbe`, so no second probe is needed. nil on the `nativeRemoteHLS` bypass (no probe runs there), and when a URL source plays although its probe failed. |
| `load(source:startPosition:options:audioSourceStreamIndex:discTitleID:)` | Same, for `MediaSource.url` or `.custom(IOReader, formatHint:)`. A custom source whose initial probe fails throws, since it cannot be reopened by URL. |
| `reloadAtCurrentPosition()` | `async throws`. Background reopen at the current position, keeping the options. See note 1 and [below](#reloading-at-the-current-position). |
| `prepareForItemReplacement()` | One-shot. Keeps the current native `AVPlayerItem` attached until the next `load()` replaces it atomically. See note 2. |
| `stop(resetDisplayCriteria:finalTeardown:)` | Ends the session: `state` becomes `.idle`, `startupProgress` becomes nil. See note 3. |
| `AetherEngine.externalSubtitleTrackIDBase` | `100_000`. Synthetic ids of external subtitle tracks start here. |

1. **`reloadAtCurrentPosition()` with nothing to reload.** On a custom source it throws `sessionNotReloadable` when there is no session or the reader is forward-only (AE#526). On a URL source with no session it returns without doing anything. Read `sessionReloadRefusal` first to tell the two apart.
2. **`prepareForItemReplacement()`** is for a host that mounts the engine's own player layer. Without it, that layer shows black across the nil-item gap of a foreground episode or playlist change. The next `load()` consumes it, `stop()` cancels it, and it has no effect when the outgoing session is not native. PiP hosts do not need it: an active PiP window already forces the handover (AE#158).
3. **`stop` parameters.** `resetDisplayCriteria: false` keeps the panel in its current mode across an item handoff. `finalTeardown` (default: the value of `resetDisplayCriteria`) says the host is leaving playback, not handing off to another `load()`. Only a final teardown honours `deactivatesAudioSessionOnStop`. To keep the panel mode and still release the session, pass `resetDisplayCriteria: false, finalTeardown: true`.

A custom source (`IOReader`, the disc-folder readers) is described under [Custom byte sources](#custom-byte-sources-ioreader).

### Reloading at the current position

`reloadAtCurrentPosition()` is session-preserving:

- It finishes an installed audio tap and keeps the native host where it can.
- It keeps the session's TRANSPORT instead of replaying `autoplay`. A session that was playing comes back playing, and a paused one comes back paused, whatever the mount was given (AE#464 round 2).
- A `play()` or `pause()` that arrives while it runs is newer, and decides how it comes back.
- The one exception is the resume after a background teardown. It has no transport left to read, so it is the host's call, and the mount flag still decides.
- The kept transport includes a pause the viewer made in AVKit's own controls, which call the `AVPlayer` directly.
- **Position.** A VOD session comes back at the playhead; a playhead at or below 1 s restarts from the beginning. A live session does not keep its position: it rejoins at the live edge, and the DVR window starts over.
- **It ends an active recording** with `.ended(.sourceReset)`, because the reopened source can bring back different codecs (see [Recording a live stream](#recording-a-live-stream)).

To change options at the same time, use [`reloadAtCurrentPosition(applying:)`](#correcting-a-loadoption-without-restarting-the-item).

### Cancelling a load

Cancelling the Task that awaits `load()` ends the load at once: it throws `CancellationError` instead of running its connect, open, retry and probe budgets to the end.

**What is aborted.** These all stop, typically within tens of milliseconds: a blocked network read, `avformat_open_input` / `find_stream_info`, a size probe, an `HLSLiveIngestReader` retry, and a custom reader's blocking `read`. The one step it cannot cut short is the AE#532 Dolby Vision record audit. That is a detached read, and the load waits for it before it throws.

**What is left.** The same state a newer `load()` leaves: the generation moves on, a custom reader is closed, and `state` becomes `.idle`. The native host and AVPlayer (#15), an AE#158 handover item and the panel mode are kept for the next load. Until that next `load()` or a `stop()`:

- the engine reads `.idle` but still holds the native host and its AVPlayer, with the item unloaded
- Now Playing may stay registered
- the audio session stays active
- with an AE#158 handover, the previous item can keep playing in PiP

A host that LEAVES on cancel (a dismissed view, say) must call `stop()`.

**Edge cases.**

- A cancellation only ends the load it belongs to. One that arrives after a newer `load()` or `stop()` took over, or after the load returned, changes nothing.
- A load that follows an engine rebuild (AE#629) ends that rebuild when cancelled.
- A `load()` called from a Task that is already cancelled throws before it touches the running session.
- A real failure at the same moment as the cancellation is reported as `CancellationError` too, and `state` ends `.idle`. A brief `.error` may have been published on the way.
- The same holds for a `reloadAtCurrentPosition()` of a URL source, which goes through `load()`.
- A load that returned before the cancellation is not undone. On the `nativeRemoteHLS` bypass `load()` returns at the mount, so a host leaving that startup calls `stop()`.
- Not cancelling changes nothing.

### Probing without playing

The probe functions read a source's metadata without starting a session. They are `nonisolated static` and synchronous, and they open the source, so call them off the main actor (see [Isolation](#isolation-and-what-runs-off-the-main-actor)).

| Symbol | Contract |
| --- | --- |
| `AetherEngine.probe(url:options:)` / `probe(source:options:)` | `nonisolated static throws -> SourceProbe`. Reads container and stream metadata, with no detail-pass decoder and no session. See note 1. |
| `AetherEngine.probeDetectingAtmos(url:options:atmosDetection:)` / `probeDetectingAtmos(source:options:atmosDetection:)` | `probe` plus a bounded decode pass that settles E-AC-3 JOC for an Atmos badge. Always more expensive; never use it on the playback-start path. Decode-side failures degrade to "not confirmed" instead of throwing. Same as `probe(url:detecting: .atmos)`. |
| `AetherEngine.probeDolbyVisionEnhancementLayer(url:options:)` | `nonisolated static throws -> DolbyVisionEnhancementLayer?`. Reads the first RPU's `el_type` for a details screen or badge, with no decode and no session. Synchronous and opens the source, so call it from a detached task or a background queue. See note 2. |
| `AetherEngine.probe(url:options:detecting:atmosDetection:hdr10PlusDetection:)` / `probe(source:...)` | `probe` plus the opt-in passes named in `ProbeDetail`, over one demuxer. See note 3. |
| `ProbeDetail` | `OptionSet`: `.atmos`, `.hdr10Plus`, `.hdrVivid`, `.dolbyVisionEnhancementLayer`. |
| `HDR10PlusDetectionOptions` | Bounds for the HDR10+ / HDR Vivid packet scan (one pass for both): `maxPackets` (32), `maxBytes` (16 MiB), `timeBudget` (2 s). See note 4. |
| `ProbeLimits` | Optional whole-probe controls: `maxInputBytes` (8 MiB), `maxPackets` (128), `maxPacketBytes` (2 MiB), `timeBudget` (5 s). Values must be nonnegative; the time budget must be finite. |
| `ProbeCancellation` | Thread-safe, one-shot token: `init()`, `isCancelled`, `cancel()`. Available on every URL/custom header, detail and `probeDetectingAtmos` overload. Cancellation is a request, not a completion notification. |
| `ProbeError` | `invalidLimits`, `inputLimit`, `packetLimit`, `packetSizeLimit`, `timedOut`, `invalidReaderResult`, `unsupportedURL`, `sourceBusy`; `errorDescription` describes the stop. Explicit caller cancellation throws `CancellationError` instead. |

1. **`probe`.** `options` is read for `httpHeaders` and `skipsContainerAttachments` only. Optional trailing `limits` and `cancellation` control the whole operation (below). For a custom reader the caller keeps ownership: `close()` is not called, and the cursor is left unspecified.
2. **`probeDolbyVisionEnhancementLayer`** reads within the load path's own packet and byte ceilings. `options` is read for `httpHeaders` only. Nil when the source is not Profile 7, or no RPU turns up in the budget. Not for the playback-start path.
   - Single-track sources only: an enhancement layer on its own PID or track is not joined here.
   - URL only, and the caller cannot bound it. For a custom source, a byte budget or cancellation, ask `probe(source:detecting: .dolbyVisionEnhancementLayer, limits:cancellation:)` instead.
3. **The detail passes:**
   - `.atmos`: the bounded JOC decode above for E-AC-3; for TrueHD, the first major sync (#1035).
   - `.hdr10Plus`: structurally validated ST 2094-40 carriage.
   - `.hdrVivid`: structurally validated CUVA HDR Vivid carriage in HEVC, scanned in the same packet pass as `.hdr10Plus`.
   - `.dolbyVisionEnhancementLayer`: FEL or MEL from the first RPU of a single-track Profile 7 source, in the same pass and budget. Skipped without a read when `dvProfile` is not 7 (#1030).

   All passes share the optional trailing `limits` and `cancellation`. So `probe(source: .custom(...))` answers the enhancement layer for a source behind an `IOReader`, under the caller's byte budget, and can be stopped. An empty set is the header probe with the same controls. The passes only ever SET `isAtmos` / `trueHDAtmos` / `carriesHDR10PlusMetadata` / `carriesHDRVividMetadata` / `dolbyVisionEnhancementLayer`. Ordinary pass failures and per-pass caps leave the detail unconfirmed. A whole-probe stop throws, with no partial result.
4. **`HDR10PlusDetectionOptions`.** On UHD remuxes the byte cap is the one that binds, because a single keyframe runs to several MB. It also bounds the total source read to four times `maxBytes` (at least 4 MiB), below the demuxer, so blocks of dropped streams count.

**Reading the answers.** A successful probe with `carriesHDR10PlusMetadata == false`, or an unconfirmed Atmos track, means **not confirmed within the requested passes/budgets**. It never proves absence.

- `isAtmos` means E-AC-3 JOC only.
- TrueHD Atmos answers in `TrackInfo.trueHDAtmos` instead (#1035). That is a `TrueHDAtmosVerdict`, and it IS three-state: `.atmos`, `.noAtmos` (a major sync was read and declares no Atmos presentation) or `.unsettled` (no major sync of the track within `AtmosDetectionOptions`). It is nil when the pass did not run for the track.
- The TrueHD pass needs no decoder and runs only for the targeted track (`AtmosDetectionOptions.targetTrackID`, else the default audio track). A profile the header probe already named Atmos costs no read. `.atmos` also sets `profile` to "Dolby TrueHD + Dolby Atmos".
- Under `ProbeLimits`, the byte budget covers this pass too. A TrueHD track that starts beyond `maxInputBytes` stops the probe with `ProbeError.inputLimit` instead of answering `.noAtmos`. A host that wants the answer for a late track sizes the budget to reach it.
- These answers describe the source's metadata. They are no evidence of HDMI output or display mode.
- Container-declared Dolby Vision stays primary even when HDR10+ is also confirmed.

### Whole-probe limits and cancellation

**Defaults.** Existing calls keep their open policy: `limits: nil, cancellation: nil`.

- Passing `limits: .init()` does three things. It starts a monotonic deadline before opening the source. It shares one input budget across disc recognition, container open, `avformat_find_stream_info`, the HDR scan, and the Atmos rewind and decode. And it turns off speculative HTTP prefetch.
- Passing only `cancellation` allows interruption without numeric limits.
- The open keeps the ordinary playback analysis budget, with `probesize` clamped to `maxInputBytes`. So a controlled probe does not answer from a shallower read than the same call without limits.
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

Cancelling the awaiting Swift task alone does not stop a synchronous probe; wire the handler as above. Do not share a custom reader's cursor with playback. The caller still owns and closes it.

**Threads.** `probe` blocks its thread until the native call returns. A detached task is not a background thread: it runs on the Swift cooperative pool, which has one thread per core. A host that probes several sources at once does better with its own GCD queue or `TaskExecutor`. The engine's own detached work goes through one (see Architecture, "Blocking work and the cooperative pool").

#### What the limits count

- **`maxInputBytes`** counts all bytes the underlying reader delivers to the probe, including bytes read again after a seek. Reads are clipped to the remaining allowance **before** the reader is called. It is **not a network/wire cap**: HTTP headers, transport buffers, requests that resolve the length, and reader-internal prefetch can use more.
- **HTTP range sizes.** An HTTP probe reads in byte ranges. They start at 64 KiB and double while each one continues the last in full, up to 4 MiB. A seek starts over at 64 KiB, and no range is longer than the input allowance still left (AE#927).
  - A grown range gets a request budget in proportion to its size, so it needs the same throughput a 64 KiB range needs in 2 s. The 2 s idle timeout still ends a stalled one.
  - So the 50 MiB playback analysis depth costs a few dozen round trips instead of ~800. The deadline is spent on the origin's bandwidth, not its latency.
- **`maxPackets`** counts every packet returned for inspection across both passes, including other streams. FFmpeg-internal packets during open/seek are bounded by input and time, not by this counter.
- **`maxPacketBytes`** rejects an oversized packet payload before parsing/decode, after FFmpeg has allocated it.
- None of these is a hard native-memory ceiling. The separate per-pass byte caps also reject a packet that would exceed the remaining allowance, instead of accepting an overshoot.

#### How interruption works

- The deadline and the token interrupt HTTP requests and call a custom `IOReader.cancel()` concurrently, also during open/seek. A blocking custom reader must implement thread-safe cancellation, unblock promptly, and handle cancellation racing an operation's start. The default no-op cannot do that.
- FFmpeg also gets an interrupt callback.
- This is cooperative interruption, **not a hard real-time return guarantee**: native computation and a reader that does not cooperate cannot be forcibly stopped.
- The call waits for native work to return before freeing its state, and drains interruption callbacks before handing the reader back. It never publishes a positive answer obtained after a stop.
- Cancelled HTTP requests finish their task callbacks before the probe releases their origin slots or returns.
- A controlled HTTP probe waits for an origin request slot until its own deadline, then gives up with `sourceBusy`. The deadline watchdog cannot interrupt a slot wait, so the deadline bounds it directly.
- Normal playback's redirect, cookie, authentication and response policies are unchanged.

**One detail a controlled probe cannot reach.** The recordless Dolby Vision audit (AE#567) opens the source a SECOND time by URL to read its first RPU. This probe's budget and cancellation do not cover that traffic, so a controlled probe skips the audit. As a result, an untagged 10-bit HEVC source whose container has no Dolby Vision record comes back without one from `probe(url:limits:)`, while `probe(url:)` synthesizes it. Probe that kind of source without limits, or treat the absence as unconfirmed.

### Warming a source before it is loaded

```swift
await AetherEngine.prewarm(url: nextEpisodeURL, httpHeaders: headers)
```

A cold open costs time. On a non-fast-start MP4 it takes two to three sequential round trips before the first sample read. On a slow origin, waiting for the first byte of the data connection is the whole start time the viewer notices. A host whose UI knows what comes next can spend those seconds in advance.

| Symbol | Contract |
| --- | --- |
| `AetherEngine.prewarm(url:httpHeaders:byteBudget:)` | `nonisolated static async -> SourcePrewarmReport`. Discardable. Fetches the opening bytes of a source the engine is not playing; the next `load()` of that exact URL adopts them instead of fetching. Needs no engine instance, audio session or layer, so a host warms while its player is still on the current item. Cancelling the task cancels the fetch and stores nothing. |
| `AetherEngine.prewarmDualLayerDolbyVision()` | `nonisolated static async -> Bool`. Discardable. Compiles the Profile 7 FEL composer's Metal shaders now (about 300 ms cold), so the first composed frame does not wait for them. Once per process; safe to run during playback. False without the `DualLayerDolbyVision` trait, with no Metal device, or when the shaders fail to compile. |
| `AetherEngine.isPrewarmed(url:)` | `nonisolated static -> Bool`. Whether that URL is warm right now, without consuming it. False again after the load that adopted it. |
| `AetherEngine.discardPrewarmedSources()` | `nonisolated static`. Drops every warmed source, for a host leaving the context they were made for. |
| `AetherEngine.defaultPrewarmByteBudget` | `8 * 1024 * 1024`. A byte budget, not a duration: a duration needs the bitrate, which is known only after the probe this tries to get ahead of. |
| `SourcePrewarmReport` | `retainedBytes`, `contentLength`, `declined`, `isWarm`. `declined` is one sentence naming why nothing was retained; the engine logs it either way. |

**What it fetches.** One ranged GET from byte zero, for the budget. A second one fetches the trailing object, but only where the head says the session will go looking for it. Two layouts do:

- an MP4 whose `moov` sits behind the media
- a Matroska whose SeekHead names a level-1 object past the warm head (usually its Cues). The span runs from that object to the end of the source. Above 1 MB it is declined, because a trailing object that large is a download, not an index.

**Where the bytes live.** A warm also hands the load the resolved location:

- A resolver URL that answers 302 with a temporary edge target is resolved once, by the warm. The session starts at that target and does not resolve the chain again. If that lease has run out by then, it falls back to the source URL through the same ladder a mid-session expiry uses.
- Credential headers (`Authorization`, `Cookie`, `X-Emby-Token` and the rest of the #126 set) never travel to a cross-origin target, whether reached through a redirect or pinned from a warm.
- An https source that redirects to plain http on a public name is followed over https instead (#954), because App Transport Security would refuse the http hop. Local names, IP literals and hosts the app's own `NSAppTransportSecurity` already allows over http keep the redirect as sent. The engine's own HTTP/1.1 transports are not bound by ATS and follow the hop as sent, without credentials.

**Remote disc images** (`.iso` / `.img` / `.udf` over HTTP) adopt a warm too (#647).

- The disc reader takes the size from the warm instead of probing for it. It answers the disc layer's structure reads and the title's opening extents from the head, and starts its first request where the warm ends.
- Its forks (the subtitle side reader, the forward prefetcher) share the same bytes without a copy.
- It does not pin the warm's redirect target, because that reader follows redirects per request.
- A disc-image URL that is not a disc after all hands the warm on to the streaming reader.

**Limits that are part of the contract:**

- **It never queues for the origin.** A warm takes a request slot only if one is free right now. It declines when the origin is metered down to one request at a time or is pacing the engine (`maxConcurrentSourceRequests`, #377). A prewarm that would have to wait for the playing session's uplink no longer helps.
- **The bytes live in memory, and only until they are used.** They do not survive the app. The first `load()` of that URL takes them over without copying. This is a head start, not an offline download, and there is no disk cache behind it.
- **All warms share one 64 MiB budget across the process.** When a new warm would exceed it, the oldest warms are dropped first. Under memory pressure every warm is dropped.
- **`LoadOptions.nativeRemoteHLS` is out of scope.** On that route AVPlayer makes the requests and the engine sees none of them, so there is nothing to adopt. Warming helps the paths where the engine fetches itself: the loopback native path, the software host, and the side demuxers.
- **The URL is the key, matched exactly, and so are the headers.** A signed URL warmed under one signature is not adopted under another. A warm fetched with other `httpHeaders` than the load's is not adopted either. An origin that varies on Referer, User-Agent or Authorization can answer a different body, and a different size, under one URL, and nothing in the bytes would show it. Pass the load's headers to the warm.

When an adopted head already covers the entire source, opening it makes neither a data connection nor a speculative suffix request. A partial warm still fetches the missing data and, when needed, the tail.

Warms run one at a time across the process. A second `prewarm` while one is in flight waits its turn instead of being refused. That costs the origin nothing: a queued warm holds no request slot and has sent nothing. What never queues is a request against the origin.

## Custom byte sources (`IOReader`)

`MediaSource.custom(reader, formatHint:)` hands the engine a host-owned byte source: a memory buffer, an encrypted container, a tuner spool, anything that is not a plain URL. It plays through the same decode paths as a URL.

`formatHint` names the libavformat demuxer to open with (`"mp4"`, `"matroska"`, `"mpegts"`). It is not weighed against the bytes. A known name skips content probing, so a Matroska hint on MP4 bytes fails the open instead of falling back. Pass `nil` when you only have a filename and are not sure of the content; the engine then probes the bytes, and `SourceProbe.containerFormat` tells you what it found. A name libavformat does not know behaves like `nil`.

**What the host must do:**

- implement `read`, `seek` and `close`
- make `cancel()` wake a parked `read` without making the reader unusable
- report and accept positions on one byte axis
- before opting into in-place rebuilds, re-key any position arithmetic that is tied to handing over a stream

All of it is explained below.

- `read`, `seek` and `close` are required. `cancel()`, `makeIndependentReader()` and `discImageProbeEnabled` have defaults. Implementing the first two enables unblocking on teardown, and embedded subtitles plus scrub stills.
- `discImageProbeEnabled` defaults to `true`, so the engine checks a custom source for an ISO/UDF image before opening it. A reader that knows it serves a regular media file returns `false` to skip those signature reads. A `DiscDirectoryReader` is recognized as a disc whatever it returns.
- Every call arrives on the engine's demux thread, never main, inside an autorelease pool the engine opens. So a reader built on `FileHandle` or `NSData` does not leak one autoreleased object per read on a pump thread that runs for the whole session (#445).

| Symbol | Contract |
| --- | --- |
| `DiscDirectoryReader`, `HTTPDiscDirectoryReader` | A Blu-ray ripped as a `BDMV` folder, or a DVD-Video as a `VIDEO_TS` folder, for `.custom(reader)`. See the note below and [Blu-ray folders](formats.md#disc-dvd--blu-ray-iso). |

`discFiles` lists the files (root-relative path and size), `openDiscFile(_:)` opens one, and `preferredPlaylist` optionally names the title's `.mpls`. `HTTPDiscDirectoryReader(files:preferredPlaylist:httpHeaders:)` serves each `File` (path, size, url) from its own `Range` origin.

### `cancel()` unblocks, it does not invalidate

Its only job is to wake a parked `read`, so teardown does not hang. A memory or file reader leaves it at the default no-op.

A reader the engine may rebuild in place must be able to serve again right afterwards, because the rebuild reuses it. If `cancel()` is terminal (as a socket's cancel of an in-flight request is), the rebuilt session is dead. How it dies depends on the reader's own convention, so one host defect has two symptoms:

- A latched reader whose read returns a negative value: the reopen fails on its first read, and the session lands in `.error` carrying libavformat's `Operation not permitted`.
- One that returns `0`: this is mapped to `AVERROR_EOF`, and the session ENDS instead of failing. On a live source, that is the end of a stream that was never supposed to end (cmcpherson274).

The engine cancels a reader it intends to reuse exactly once, before the successor opens.

### In-place rebuilds reuse the reader

These all tear the pipeline down and reopen on the retained reader, not on a URL: `reloadAtCurrentPosition()` and `reloadAtCurrentPosition(applying:)`, an audio-track switch, a disc-title switch, and a background return. So a custom source gets the same session-preserving rebuild as a URL source. Exceptions:

- `load()` decides the Profile 7 dual-layer route. On a custom Profile 7 source, `reloadAtCurrentPosition(applying:)` refuses a `preferDualLayerDolbyVision` change (or a `dolbyVisionHandling` change while the preference is on) with `SessionReloadRefusal.dualLayerRouteNeedsFreshLoad`.
- A reader that reports itself non-seekable is refused (`SessionReloadRefusal.customSourceNotSeekable`), because the rebuild cannot reposition it.

### Where the reopen starts

A fresh `AVIOContext` always starts its byte axis at 0, so the reader's cursor and that axis must agree. How they are made to agree depends on whether the source is live:

- **VOD.** The reader is rewound to 0, and the axis starts there. The reopen re-reads the container header, then the backend seeks to the resume position.
- **Live.** The reader stays exactly where the session left it, and the axis moves to the cursor instead (`[Demuxer] live reopen aligned to the reader's cursor at N bytes`). A live source keeps receiving during the rebuild, so a rewind would replay the host's whole delivered window. Measured on `aetherctl customio --live`: the rewind dropped the playhead from 41.5 s to 1.9 s and asked the host to re-deliver 15 MB, a 61 s window, at I/O speed. With the alignment, the rebuild becomes the same edge rejoin that `LiveReloadPolicy` performs on the URL branch.

The live case has one cost. The reopen re-probes the container from a byte offset in the middle of the stream, so the source must be joinable there. MPEG-TS resyncs on its own sync bytes and recovers within a GOP. A live reader that does not answer `seek(0, SEEK_CUR)` cannot be aligned to. It is rewound like a VOD source, and the engine says so instead of doing it silently.

### The axis a reader reports on is the axis it is asked on

The live alignment reads the cursor with `seek(0, SEEK_CUR)` and hands that number straight back as a `SEEK_SET`. The seekability probe makes the same round trip at every open, and libavformat's own probe seeks use the same axis.

- **Both of these are fine:** absolute file offsets, or offsets counted from wherever this install's stream joined. A reader that counts from its join is reported on that axis (`aligned to the reader's cursor at N bytes` then carries bytes since the join, not a position in a file).
- **What breaks:** reporting on one axis and taking `SEEK_SET` on the other. The round trip then MOVES the source by the join offset, during a probe meant to move nothing. The session then reads from a stretch the host has not delivered yet.

Both halves are checked:

- The probe compares its own return against the position it was just told. This costs no extra callback and runs on every open, including every in-place rebuild.
- The alignment asks once more where the reader is, so a live reopen never reports an alignment that did not hold.

```
[Demuxer] custom source: the reader reported byte 2097152 and answered a seek back to it with
4194304, so its position report and its SEEK_SET argument are not on the same axis; the source
has been repositioned by the seekability probe
```

### Host position arithmetic keyed to vending a stream

**A host whose own position arithmetic is keyed to vending a stream has to re-key it before opting into in-place rebuilds** (cmcpherson274's corollary, and the reason his wrapper still refuses one).

A rebuild consumes no new stream. Anything a host sets up at the moment it hands a stream over is not set up again by a rebuild, and will disagree with the session that comes back. Examples: a live clock baseline, a DVR join anchor, or the per-stream ownership that makes an unguarded cursor safe. The engine's alignment fixes the bytes. It cannot fix a clock it cannot see.

## Transport

| Symbol | Notes |
| --- | --- |
| `play()` | Rewinds first when parked at the final frame of a VOD; a no-op on `.ended`. |
| `pause()`, `togglePlayPause()` | `togglePlayPause()` is ignored while seeking, idle, ended or failed. |
| `seek(to:)` | `async`. Source-axis seconds. See [Seeking](#seeking). |
| `seek(to:exact:)` | `async`. `seek(to:)` is this with `exact: false`. See [Seeking](#seeking). |
| `canSeek` | Whether the ready session accepts a seek. Live needs retained DVR history, remote HLS a measured item range, and VOD a byte source proven seekable (a container duration alone is not proof). |
| `isSourceSeekable` | `@Published Bool?` for this load: nil is unknown or AVFoundation-owned, false is forward-only, true is a seekable byte source. A forward-only VOD ignores a saved `startPosition` and mounts at 0. Back to nil during every load or rebuild, until the new source is open. |
| `seek(toSourceTime:)` | Deprecated alias for `seek(to:)`. The clock is unified onto source PTS, so the two are the same call. |
| `setRate(_:)` | Playback speed. See [Playback speed](#playback-speed). |
| `maxSupportedRate` | 2.0 for video, 3.0 audio-only. Query after load; returns 2.0 while idle. Size a speed picker against it. |
| `audioDelaySeconds`, `setAudioDelay(_:)` | Lip-sync correction. See [Audio delay](#audio-delay). |
| `volume` | Pass 0.0 to 1.0 (not clamped). A write before a session exists is remembered and applied at load. |
| `selectTitle(id:)`, `selectChapter(id:)` | Disc titles and chapters. See the note below. |

**Titles and chapters.** `selectTitle` is synchronous and returns before the switch. It rebuilds the session at the start of the new title, like a fresh load. A pick made while a `load` is still running waits for that load to return, as an audio pick does. It ignores an unknown id, the title already playing, and a forward-only custom source; a reload that fails is only logged. `selectChapter` looks only in `discChapters` and seeks with `exact: true`. It cannot reach container chapters (`mediaChapters`): pass their `startSeconds` to `seek(to:exact: true)`.

### Seeking

`seek(to:)` is rejected when the session is idle, errored, ended, live without a DVR window, or on a forward-only VOD source.

- A seek made while the session is still `.loading` is not rejected. The latest target is kept and replayed once the session is ready, or dropped if the load fails.
- The forward-only case rejects with `SeekEvent.Rejection.sourceNotSeekable`, without a false landing. A seek queued during load drops its optimistic clock too.
- A sequential origin rejects the same way, except for a target the loopback session still holds; the rule is under [`sequentialOrigin`](#sequentialorigin).

Where a seek lands:

- **Native.** A seek reports a landing only when AVPlayer completed it no more than 0.75 s short of the target (an overshoot in the seek direction counts). An interrupted or clamped seek is not a landing.
- **Software host, AV1 decoded by dav1d.** The seek lands on the keyframe nearest the target, within 10 s (and within half the seek's own distance), and never on the far side of the playhead. The candidates are the keyframes the packet cache retains or the container's index lists. `.landed` reports that keyframe's position. Without such a keyframe at or after the target, the seek stays exact ([formats › Containers and codecs](formats.md#containers-and-codecs)).
- **`seek(to:exact: true)`** lands exactly on the target on that software AV1 route too, for a chapter mark or the end of an intro. It costs decoding from the keyframe before the target up to it. Every other route is exact either way. A seek stashed during load keeps the flag.

### Playback speed

`setRate(_:)` is clamped to `maxSupportedRate`; `0` pauses. Only the upper bound is clamped: reverse playback is not supported, so pass `0` or a positive rate.

- During an audio interruption on the software or audio-renderer path, a non-zero rate does not restart the audio the system paused. It is stored and applies when playback resumes.
- While the session is paused, a non-zero rate does not resume it. It becomes the rate the next `play()` starts at, and `state` stays `.paused` (#730).
- The speed holds across pause and resume, and across the rebuilds a session makes on its own (reload at position, audio-track switch, AirPlay LAN swap, background return).
- It belongs to the item: loading a different source, or `stop()`, returns to 1.0.
- Pitch-preserving on both decode routes: `audioTimePitchAlgorithm` is pinned to TimeDomain on the native player item and on the software path's audio renderer, so a speed control never has to be gated on which route a title took.

### Audio delay

`audioDelaySeconds` / `setAudioDelay(_:)` correct lip sync for the viewer's chain, in seconds. Positive presents audio later than video.

- Clamped to +/-2 s. Like `setRate`, it belongs to the session and holds across the rebuilds a session makes on its own.
- **Where it applies.** Only where the engine still holds the timestamps: the stamped sample PTS on `.software`, and the audio track of the fMP4 segments on `.loopback`.
  - AVFoundation exposes no equivalent a host can reach. So on `.remoteBypass` and on audio-only sessions the value is only kept for the session's own rebuilds, and the log says it had no effect.
  - A new `load()` starts from `LoadOptions.audioDelaySeconds`. A host that keeps the viewer's setting passes it there on every load.
- **A change re-anchors at the playhead.** Unlike `setRate`, it has a cost: audio already decoded or fetched carries the previous value and cannot be re-timed in place.
  - On `.software` the re-anchor is a seek to the current position.
  - On `.loopback` it is the session-preserving reload, so like any reload it ends an installed audio tap and an active recording. A seek would not do: seeking to the position AVPlayer already holds hits its buffer and plays out the old-offset segments anyway.
  - Measured on a 30 fps H.264 fixture: about 0.3 s of held picture on the loopback route, position kept.
- A live session without a DVR window has no position to return to. It takes the new value at the next seam it makes on its own.
- **Rapid presses.** Presses that arrive while a re-anchor runs are folded into it, instead of stacking one re-anchor per press (AE#464 round 3). A press after the running re-anchor read the value gets exactly one catch-up pass. The call does not carry the value with it, so the rebuild in flight delivers the newest one. Presses at a human pace arrive after a re-anchor has finished, and each gets its own.
- A re-anchor or a `reloadAtCurrentPosition(applying:)` raised right as a previous rebuild returned, before the new host has published a position, rebuilds at the position that rebuild was mounted at, not at the start (round 5).
- A call that arrives while the session is being rebuilt is neither applied nor refused. It is kept in the options the load in flight reads, and the log says so.

## Time

Time lives on `player.clock`, a separate `ObservableObject`, so its ~10 Hz ticks never fire `objectWillChange` on the engine.

| Symbol | Axis |
| --- | --- |
| `clock.$currentTime` | playback clock, the scrubber axis |
| `clock.$sourceTime` | source PTS of the displayed frame; render subtitle overlays against this. On `nativeRemoteHLS` it is item time, corrected while possible; see [below](#sourcetime-on-nativeremotehls). |
| `clock.$sourceTimeFollowsPicture` | whether `sourceTime` is known to follow the displayed frame. Always true except on `nativeRemoteHLS`, where it is true only while the lead has been measured since the last time jump (AE#616). |
| `clock.$progress` | `currentTime / duration` |
| `clock.$bufferedPosition` | source-axis position buffered ahead. Never below `currentTime`. While a native seek is pending, it is measured from the seek target (where `currentTime` already stands), not from the frame AVPlayer still shows. |
| `clock.$liveEdgeTime`, `clock.$seekableLiveRange`, `clock.$behindLiveSeconds`, `clock.$isAtLiveEdge` | live-window surfaces. See [The rewind depth a live session really has](#the-rewind-depth-a-live-session-really-has). |
| `$residentRanges` | where the loopback segment cache or software VOD packet cache holds picture right now, as disjoint ascending spans on the `currentTime` axis. See [Resident ranges](#resident-ranges). |
| `player.currentTime`, `sourceTime`, `sourceTimeFollowsPicture`, `progress`, `bufferedPosition`, `liveEdgeTime`, `seekableLiveRange`, `behindLiveSeconds`, `isAtLiveEdge` | non-published mirrors of the same values for one-shot reads |
| `$duration` | seconds; a `LoadOptions.declaredDurationSeconds` outranks the container's |

**`seekableLiveRange`** is where the DVR window (the policy) and what the segment cache really holds and can play forward from (the fact) overlap. So a rewind strip can be scaled on it, and `seek(to:)` clamps to the same floor (AE#441).

- The window and the cache differ for the whole first `dvrWindowSeconds` of a session, and again whenever retention evicts faster than the window slides.
- Software live sessions hold a packet ring instead. It evicts by the same byte budget as the native cache: a quarter of the volume's free space, at most 2 GiB unless `liveDVRByteBudget` sets a larger budget, at least 64 MiB. Once eviction has moved the ring past the window, the range's floor follows the ring.

**`bufferedPosition`.** On native loopback playback it also refreshes while paused, as segments arrive or are evicted. It describes the contiguous stretch ahead of the rendered position, not the sum of separate cached ranges. The refresh does not advance playback. On `.remoteBypass` there is no engine segment cache, so it is the end of AVPlayer's own loaded range that touches the playhead (`AVPlayerItem.loadedTimeRanges`). It refreshes on every change of those ranges, including while paused (AE#935).

### Resident ranges

`$residentRanges` is what the cache really holds, not AVPlayer's `loadedTimeRanges`. In one measured session the cache held 64 segments over four minutes, in several separate islands. AVPlayer exposed roughly twelve seconds around the playhead, and forgot an island the viewer had seeked ahead to as soon as the playhead left it.

- Empty is the nil-equivalent.
- A live session always publishes empty. Its rewind depth is `seekableLiveRange`, which answers a different question.
- Residency does not promise that a seek inside a span is instant. The player may still re-anchor and decode at the target, and a segment can start mid-GOP (AE#412).
- At most four updates a second; cleared on `load()` and teardown.
- Draw these spans directly on the `currentTime` axis. `bufferedPosition` alone only reaches forward, so it cannot tell where the cache starts behind the playhead.

**Software VOD.** `residentRanges` is where video coverage and the selected audio stream overlap, even if muted. A video-only source needs no audio.

- H.264/HEVC, VC-1 and [WMV1/2](notes/wmv-cache-coverage.md) use verified intervals up to the next frame's PTS. So the final picture, which has no known successor, does not get an invented end.
- Ranges are clipped against retained keyframes and discarded packet timestamps. Unknown or invalid coverage stays empty. Metadata limits may leave out old spans, to be safe, instead of claiming packets that no longer exist.
- AVI MPEG-4 sessions that suppress generated packet PTS can qualify a separate presentation axis for the cache. It comes from the existing MPEG-4 parser and the same decoder's repaired frame timestamps. The packet delivered to the decoder is unchanged. Packets whose ownership is unqualified or ambiguous stay uncovered. Retiring temporary timing pairs does not by itself evict confirmed ranges or retained seek anchors. See the [synthetic reproduction and scope](notes/avi-mpeg4-cache-repro.md).
- The software sampler builds an immutable snapshot in the background and publishes it on the main actor, including while paused. Cached seeks keep retained spans; a cache miss clears them when the old store is discarded. Seek, replacement and teardown guards reject a late snapshot.
- Live playback keeps exposing its separate seekable window, not VOD resident ranges.

### Software VOD positioning and read failures

After a source read failure, the software packets already committed and their verified ranges stay. Cached seeks may replay them, but draining those packets still throws the original read failure. The error does not turn into EOF, and does not flush unresolved successor timestamps. Storage or packet-envelope failures make the cache unusable instead. A cold seek starts a new source lifetime.

Software VOD resume and cache-miss seek positioning run off the main actor with a **30 s positioning
budget**, measured after acquiring demux access.

- Waiting for an earlier read can add to the total call time.
- A cold byte probe with a deadline uses the existing streaming reconnect at once. Detour blocks already resident stay usable, and ordinary parsing without a deadline keeps its detour policy.
- So keyframe searches that need several probes on slow remote storage can finish, while I/O still has a finite deadline. The flip side: an unavailable source can take longer to report failure.

Failures:

- A failed software resume throws before readiness or a requested clock anchor is published.
- A failed software seek reports `.stalled` and `.softwarePipelineFailed` and clears the in-flight state. It does not resume decoding or mark the target as landed. An AVPlayer seek stays pending for a late landing; this software failure is final for the host.
- Stop, cancellation and newer seeks still prevent stale completions from changing the active session.

### `sourceTime` on `nativeRemoteHLS`

(AE#616.) The engine sees no segment on this route, so the clock is AVPlayer's item time.

**The problem.** Some origins place a segment at its slot in the playlist, while the segment itself starts at the keyframe before that slot. A Jellyfin transcode restarted by `-ss <slot> -noaccurate_seek -copyts` does this. Item time then runs ahead of the frame on screen, by a different amount after every seek: 1.1 s to 8.3 s measured. AVPlayer keeps the anchor of the first segment it loaded after the seek.

**How the engine corrects it.** The engine injects WebVTT renditions (#316) for `LoadOptions.externalSubtitles`. They are placed by media timestamp, so each line reaches AVPlayer's legible output at its cue start plus that lead. The engine watches its own renditions with a non-suppressing legible output, and matches each presented line back to the cue it wrote. It then publishes `sourceTime` as item time minus the measured lead. Log line: `AE#616: item time leads the presented frame by ...`.

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
| `$errorInfo` | `PlaybackErrorInfo?`, the machine-readable half of `.error`: a `PlaybackErrorKind` token, plus the underlying `NSError` domain and code where one is involved. Non-nil exactly while `state` is `.error`, and assigned before it. Classify on this, never on the message. See [How a load ends](#how-a-load-ends). |
| `$playbackPhase` | The one derived state to rely on, and **the only one of these that tracks motion**. See [`playbackPhase`](#playbackphase). |
| `$isBuffering`, `$isSeeking`, `$seekTarget` | The raw inputs `playbackPhase` combines. See the note below. |
| `sourceAuthorizationRefused` | `AnyPublisher<Int, Never>`: the origin answered 401 or 403 to the session's request headers mid-session. One value (the status) per header set. Renew and call `updateRequestHeaders(_:)`; see [Rotating a credential without a rebuild](#rotating-a-credential-without-a-rebuild). |
| `seekEvents` | `AnyPublisher<SeekEvent, Never>`. See [Seek events](#seek-events). |
| `$isClockHeld`, `clockHoldEvents` | The software host's clock hold (#800). See [Clock hold](#clock-hold). |
| `$isSessionReady` | The session is ready in the AVFoundation sense. Not the edge a black cover comes off on. |
| `$hasFirstFrameReadyForDisplay` | The picture for **this** load is up. See [First frame](#first-frame). |
| `hasRenderedVideoFrame()` | Asynchronous point read of local presentation evidence. See [First frame](#first-frame). |
| `$startupProgress` | `StartupProgress?` for a determinate loading bar. See [Startup progress](#startup-progress). |
| `$isAwaitingDisplaySwitch` | True while a loaded session holds its start for the display: the post-load play gate waits for a mode switch (Match Content, a dynamic-range change) to settle. Cleared when the gate ends and at every `load()` / `stop()` (AE#1000). See the note below. |
| `softwarePathEscalations`, `SoftwarePathEscalationEvent` | A native session AVPlayer refused, rebuilt on the software path, with the failure it absorbed. See [The engine moves a refused session onto the software path](#the-engine-moves-a-refused-session-onto-the-software-path). |

- **`$isBuffering`.** On the AVPlayer paths, a wait while AVPlayer evaluates its buffering rate (every resume from pause, a frame or two) is not a rebuffer. One that moves on to minimizing stalls is (Sodalite#168).
- **`$isAwaitingDisplaySwitch`.** During that wait `playbackPhase` reads `.loading`, and the first frame can already be up with `startupProgress` at `.presenting`. This flag is what says the wait is the panel's, not the source's. A host that keeps its spinner hidden during a switch in `.preparingDisplay` can key on it for the same stretch after the session is built.

#### `playbackPhase`

Prefer `$playbackPhase` over stitching `state` + `isBuffering` + `isSeeking` together, and over matching log text.

- **It tracks motion.** `state` is transport INTENT. It turns `.playing` the moment the engine has called `play()`, which on a live join can be seconds before playback actually starts moving (AE#440). The phase stays `.loading` until the transport has moved once in a load, and turns `.playing` when it does.
- **It adds** `.rebuffering` and `.stalled(reconnecting:)`.
- **Precedence**, highest first: `error > ended > idle > loading > stalled > seeking > rebuffering > playing/paused`. A source that stopped delivering stays visible while a seek is in flight, because no seek can land over it; `isSeeking` / `seekEvents` still carry the seek (#410).
- **`.stalled(reconnecting: true)`** is a reader that is retrying. **`false`** is a reader that has used up its retries and handed recovery to the producer's reopen. Both mean the source is down.
- **`.rebuffering`** is published on the AVPlayer-backed paths: the native loopback session, direct remote HLS, and the bare-AVPlayer audio host (a starved progressive stream, once the item has played). `.stalled` cannot occur there, because there is no reader. The software video host publishes it too, from the moment one of its pumps pauses the synchronizer to refill (a dry ring at the live edge, or an audio lead used up on demand).
- A source whose connection is retrying reads as `.stalled` on the FFmpeg-backed hosts (software video, FFmpeg audio) once the reader's ladder is running.

#### Seek events

`seekEvents` publishes `.began`, `.landed(renderedTime:)`, `.stalled`, `.superseded` and `.rejected(SeekEvent.Rejection)`. Each carries its `target`, an `id` that spans the seek, and a `SeekEvent.Origin`:

- `.programmatic`
- `.nativeScrub`
- `.deferred`: a seek the session could not take yet. This is where the engine publishes an optimistic `currentTime` for a position nothing has reached.

Use it where the moment `$isSeeking` turns false matters. A plain Boolean cannot say whether a seek landed, gave up, or was superseded, and a `.stalled` seek can still land later under the same id.

The value is a struct: `id`, `origin`, `target` and `outcome` (a `SeekEvent.Outcome`, the cases named above), plus `isTerminal`, true for every outcome except `.began`.

- `id` rises per engine instance.
- Every `.began` ends in exactly one `.landed`, `.stalled` or `.superseded` under its id.
- A `.rejected` stands alone, with no `.began`. `SeekEvent.Rejection` names why:

- `.noActiveSession`: the engine is idle, errored or ended.
- `.liveWithoutDVR`: a live source with no DVR window to land in.
- `.sourceNotSeekable`: a forward-only source.

Two seeks publish no rejection. A non-finite target (NaN, infinity) is dropped with a log line and no event. A seek during `.loading` is not rejected: the latest one is stashed and replayed when the session settles, with origin `.deferred` (#178).

#### Clock hold

After a start, a seek, an in-place switch or a resume, the software host's clock stands still (rate 0) at its new position. It waits until the decoder has frames from that position in the layer, then starts 0.25 s later (#800). A host that judges playback from the clock must not count that wait as a stall.

`clockHoldEvents` is `AnyPublisher<ClockHoldEvent, Never>`: `.began`, then exactly one `.released(ClockHoldRelease)` with one of:

- `.ready(waitedSeconds:)`
- `.timedOut(waitedSeconds:)`: the decoder produced nothing for 2 s, or produced without reaching the position for 6 s
- `.cancelled`: a seek, pause, rate change or the end of the session took over

It is per engine instance, so several engines at once can be told apart without reading `EngineLog`. These never hold: the AVPlayer paths, the audio-only host, live streams off the FEL route, and a start whose frames are already queued.

#### First frame

**`$hasFirstFrameReadyForDisplay`** means a picture, not motion. A live join shows its first frame and can then hold it, completely still, for seconds while AVPlayer decides whether to start (AE#440). A host that hides its spinner here hides it over a frozen frame. For "it is moving", use `$playbackPhase`.

- Latched for the load, cleared at the next `load()` / `stop()`.
- Audio-only sessions never set it.
- On an external screen (`isExternalPlaybackActive`) the local layer never becomes ready. So the item's readiness is the honest signal, and the flag latches there (#315).

**`hasRenderedVideoFrame()`** is an asynchronous one-off check for evidence that a picture was rendered locally.

- Native playback requires this load's first-frame readiness and a currently ready `AVPlayerLayer`. It can briefly return false during item swaps or recovery reloads, which the load-scoped latch deliberately hides. A host may latch a positive result when it dismisses a startup poster. It should not bring that poster back, or conclude playback was lost, from a single false.
- Software playback requires at least one frame counted and not dropped by the renderer it currently owns. Those software counters are cumulative, so this does not prove continuing motion, or that a picture is still visible after a flush.
- Unlike the load-scoped latch above, it does not treat external-player readiness as a locally rendered frame.
- Returns false for no video, unavailable metrics (including visionOS 1.0), cancellation, or a session replaced during the read.
- It does not start playback or wait for a future frame.

#### Startup progress

`StartupProgress` carries `checkpoint`, `completed`, `total`, `fraction`, `stage` (a `StartupStage` naming the work in flight, for a label beside the bar), `generation` and `isComplete`. Every value is work some part of the load has finished, never a timer or an estimate. So the bar holds during a slow stretch and jumps over a skipped one. The checkpoints, in order:

| `StartupCheckpoint` | Finished work | `stage` until the next checkpoint |
| --- | --- | --- |
| `.dispatched` | `load()` accepted the request; the previous session is torn down | `.connecting` |
| `.sourceOpened` | the source is open and its first bytes arrived (connection, redirects, size probe) | `.openingContainer` |
| `.containerOpened` | `avformat_open_input` returned: the container is identified | `.analyzingStreams` |
| `.streamsProbed` | `avformat_find_stream_info` returned. On a slow origin the longest single stretch, and the one nothing else exposes | `.preparingDisplay` |
| `.displayPrepared` | the display-criteria handshake settled, or the path had none | `.selectingRoute` |
| `.routed` | native, software, audio or remote-HLS bypass is chosen | `.buildingSession` |
| `.sessionConstructed` | the backend host is built and holds its item | `.preparingPlayback` |
| `.ready` | the session reports itself ready | `.awaitingFirstFrame` |
| `.presenting` | the first frame is on screen. The end of the ladder, deliberately not `.playing` | `.presenting` (nothing in flight) |

- `.dispatched` is the starting point, not a step, so a fresh sequence publishes `completed == 0` and `total` is eight.
- A path that skips work records the checkpoint it does reach, and that alone credits the ones before it. Nothing ever waits for a checkpoint its path will never emit.
- `generation` counts the startups a user waited through, not teardowns. So a reroute the engine starts continues the bar instead of resetting it.
- Record the furthest checkpoint at the moment a host gives up, and a failure counter becomes a map of where loads die.

### Route and output

| Symbol | Reading |
| --- | --- |
| `$videoRoute` | `VideoRoute`: which pipeline is actually serving, one of `.none`, `.remoteBypass`, `.loopback`, `.software`, `.audio`. Branch on this, above all for who draws subtitles. See the note below. |
| `$audioDelivery` | `AudioDelivery`: how the audio reaches the renderer, one of `.none`, `.noAudioInSource`, `.streamCopy`, `.bridged`, `.decoded`, `.droppedNoPipeline`, `.playerManaged`. A fallback ladder demotes on `.droppedNoPipeline` (AE#641). See [Reading whether the audio was delivered](#reading-whether-the-audio-was-delivered). |
| `$currentAVPlayer`, `$currentAVPlayerItem` | The live AVFoundation objects, re-emitted on every reload. Both nil on `.software`, which renders into its own layer. A host that only hands `currentAVPlayer` to an `AVPlayerViewController` gets audio over an empty video plane on that route (#298). |
| `$airPlayPictureStaysLocal` | iOS: true while a wireless AirPlay receiver holds the audio route but the session runs on the software host. See [AirPlay and the software host](#airplay-and-the-software-host). |
| `setScreenMirrored(_:)` | iOS: tell the engine whether the screen is being mirrored. |
| `setAirPlayReceiverShowsVideo(_:)` | iOS: tell the engine whether the AirPlay receiver on the audio route shows video. |

- **`$videoRoute`.** `LoadOptions.nativeRemoteHLS` is only a request. The carriage watchdog, the remembered verdict and the HLS reroutes move a session between routes, also mid-session.
- **`$audioDelivery`.** `.droppedNoPipeline` is a source that HAS audio playing video-only: no pipeline could be built for it, or a live bridge decoded nothing.

#### AirPlay and the software host

**`$airPlayPictureStaysLocal`** is true on iOS while a wireless AirPlay receiver holds the audio route but the session runs on the software host (VP9, AV1 without hardware decode, deinterlaced MPEG-2 / VC-1 / H.264, `preferredDecodePath = .software`). That host draws into an `AVSampleBufferDisplayLayer`, and only its audio renderer follows the route, so the receiver plays sound only. Nothing fails, so the engine flags it: show the viewer that this title's picture stays on the device.

- False on the native paths, where the receiver gets the stream, and everywhere off iOS.
- False too while the host reports the screen as mirrored (`setScreenMirrored(_:)`), because the mirror carries the layer.

**`setScreenMirrored(_:)`** (iOS). Pass `true` for a mirror only, derived from `UITraitCollection.sceneCaptureState`; a screen recording also reads as captured there. A mirror carries the software host's layer to the receiver, so `airPlayPictureStaysLocal` reads false while it is on. No effect off iOS.

**`setAirPlayReceiverShowsVideo(_:)`** (iOS) tells the engine whether the AirPlay receiver on the audio route shows video (an Apple TV or a TV).

- The audio session reports every AirPlay output as the same port type, so the engine cannot tell a TV from a HomePod on its own. The default is false (audio-only or unknown).
- A host has the same limit, so pass what it knows itself: the viewer's own choice (for example a "playing to a TV" control), or a host-owned `AVPlayer`'s `isExternalPlaybackActive`.
- While true and a wireless route is active, a Profile 7 FEL source loads on the native route (8.1 where the display takes Dolby Vision, no enhancement layer), so the receiver gets a picture. The dual-layer route would draw into a layer no receiver picks up.
- Opt-in: nothing changes for a host that never calls it.
- Read at each load. On a URL source, `reloadAtCurrentPosition()` decides again; a custom source keeps its route until the next `load()`.
- No effect off iOS.

### Source and format

| Symbol | Reading |
| --- | --- |
| `$videoFormat` | The format being presented: `.sdr`, `.hdr10`, `.hdr10Plus`, `.dolbyVision`, `.hlg`. See [Presented format](#presented-format). |
| `$sourceVideoFormat` | The format the **source** carries, before any mapping for the panel. An honest badge needs both: for HDR content on an SDR panel they differ. |
| `$sourceDVProfile`, `$sourceVideoFrameRate`, `$sourceVideoBitrate` | Source detail for an info panel. |
| `$sourceVideoScan` | A `VideoScan` (AE#983): `.progressive`, `.interlaced(VideoFieldOrder)` or `.unknown`. See [Scan type](#scan-type). |
| `sourceDVBLCompatID`, `sourceDolbyVisionBaseLayerPresentable` | Read-only source capability snapshot on the main actor (not publishers). See [Dolby Vision base layer](#dolby-vision-base-layer). |
| `$dolbyVisionConversion` | A `DolbyVisionConversion?`: the Dolby Vision profile rewrite applied to the served stream. nil when the session serves the source's own profile, or no Dolby Vision. Set when the loopback session starts, cleared on stop. See note 1. |
| `$sourceVideoCodecName` | The source video codec in libavcodec's spelling ("hevc", "h264", "av1"), nil when the source has no video. Answers on every route. See note 2. |
| `$sourceContainerFormat` | The container libavformat opened ("matroska,webm", "mpegts"). See note 3. |
| `$sourceVideoStreamFormat` | A `VideoStreamFormat?` (AE#658): the source video stream's pixel format, depth and colour. See [Stream and decoded format](#stream-and-decoded-format). |
| `$decodedVideoFormat` | A `DecodedVideoFormat?` (AE#658): what the engine's own decoder actually produced. **nil on every native route.** See [Stream and decoded format](#stream-and-decoded-format). |
| `$activeVideoDecoder`, `$activeAudioDecoder` | The decoder names actually in use, for a stats overlay. This is the honest answer to "what is decoding this"; `playbackBackend` is not. See note 4. |
| `$metadata` | `MediaMetadata` parsed at load (title / artist / album / cover). |
| `$mediaChapters`, `$discChapters`, `$discTitles`, `$selectedDiscTitle` | Container chapters, and disc titles / chapters for DVD and Blu-ray ISO sources. |
| `AetherEngine.displayCapabilities` | `static DisplayCapabilities`: `supportsHDR`, `supportsDolbyVision`, `supportsHDR10`, `supportsHLG` for the current display. See [Display capabilities](#display-capabilities). |

1. **`.profile7ToProfile81`** is a Profile 7 source played on a display presenting Dolby Vision. `$videoFormat` reads `.dolbyVision` and `$sourceDVProfile` keeps 7, so a label can say "P7 -> P8.1". The conversion drops the enhancement layer.
2. **`$sourceVideoCodecName`.** The probe-free remote-HLS bypass maps it back from the item's video sample type, which is why it answers on every route. It answers a different question than `$activeVideoDecoder`: a codec has several decoders, and which one runs depends on the hardware.
3. **`$sourceContainerFormat`** is nil on the remote-HLS bypass, where AVFoundation opens the source and there is no libav context to ask. It is the container that ARRIVED. On a remux or transcode session, that is not the one a host's library metadata describes.
4. **Decoder names.** The software playback host can use VideoToolbox for HEVC. Then `$activeVideoDecoder` reports `VideoToolbox HEVC (HW)` on load and reload, even though `playbackBackend` is `.software`. Show `$activeAudioDecoder`, but classify on `$audioDelivery`: a label cannot tell a source without audio from a source whose audio was dropped.

#### Presented format

`$videoFormat` is the format being presented, after the panel-driven mapping.

- **macOS** has no per-mode capability table. Suppose the clamp sent a Dolby Vision session to `.hdr10`. Once the item AVFoundation plays turns out to carry a `dvh1` / `dvhe` sample entry, the format is upgraded back to `.dolbyVision` (AE#515).
- **tvOS.** The panel side does not come from the headroom alone. A session serving an HDR master that AVFoundation has not refused publishes the presented format half a second in. A display that takes an HDR master is presenting HDR; one that does not refuses within 54 to 61 ms. `currentEDRHeadroom` has been measured reading 1.00 through exactly that acceptance (AE#459).

#### Scan type

`$sourceVideoScan` is resolved at load from the same evidence the routing reads. So a panel can tell 1080i from 1080p without guessing from the height. `VideoFieldOrder` is the display order: `.topFieldFirst`, `.bottomFieldFirst`, or `.unknown` (the H.264 SPS case below).

- **Sources of evidence:** the probe's field order; the H.264 SPS when the demuxer leaves it open (`.interlaced(.unknown)`); and a sample of decoded frames on seekable VOD. That sample turns a source declared interlaced but with progressive pictures (1080i25 Blu-ray carriage) into `.progressive`.
- AV1, VP9 and VP8 have no field coding and read `.progressive`.
- `.unknown` before load, on the probe-free remote-HLS bypass, and when nothing settles it.
- Kept across audio-switch and background reloads, re-read on a disc title switch, reset on stop.
- Whether a deinterlacer actually runs is `decodedVideoFormat?.deinterlace`.

#### Dolby Vision base layer

`sourceDVBLCompatID` and `sourceDolbyVisionBaseLayerPresentable` are a read-only source capability snapshot on the main actor, not publishers.

- The optional compatibility ID comes from the DV record; nil means unavailable. An ID of 2 describes an SDR-compatible base (P8.2/P10.2), not HDR10.
- The Boolean is the existing VUI-aware eligibility for `dolbyVisionHandling = .baseLayerOnly`. It is not a promise about the panel or an accepted reload.
- Load/stop reset them to nil/false.
- They are assigned before `sourceVideoFormat` and `sourceDVProfile`, so they are already current inside a `$sourceDVProfile` or `$sourceVideoFormat` callback. This snapshot has no notification of its own.
- The profile alone is not enough: a contradicted P5 record may have a presentable YCbCr base, while an IPT-only source does not.
- Hosts still honour the engine's reload refusals. Neither field changes routing or enables FEL.

#### Stream and decoded format

**`$sourceVideoStreamFormat`** carries the source video stream's `pixelFormat` ("yuv420p10le"), `bitDepth`, `colorPrimaries`, `transfer`, `matrix`, `range` and `profile` ("Main 10"). They use libav's names, as the container and the probe's decoder declared them.

- A field the stream leaves unspecified is nil, never a guessed BT.709.
- `colorPrimariesLabel`, `transferLabel`, `matrixLabel` and `rangeLabel` give the names a viewer reads ("BT.2020", "PQ (SMPTE ST 2084)", "BT.2020 NCL", "Limited").
- nil before load and without video.
- On the probe-free remote-HLS bypass it describes the DELIVERED stream, read back from AVPlayer's item video track once that resolves. Colour and range come from the format description. `profile`, `bitDepth` and `pixelFormat` come from its avcC / hvcC record (nil where the codec has neither, AV1 and VP9 included). Under a server-side transcode this describes the transcode, not the library's file; that is the point of reading it there.

**`$decodedVideoFormat`** is what the engine's own decoder actually produced.

- `frame` is a `VideoStreamFormat` for the decoded picture: libavcodec's output pixel format, or the libav name of the VideoToolbox buffer on the software host's hardware decoder.
- `pixelBufferFormat` is the CoreVideo buffer it was displayed from (`420v`, `x420`); `pixelBufferLabel` reads "P010 (x420)".
- `deinterlace` is a `VideoDeinterlace?` (AE#983) naming the deinterlace graph the frames pass through: `filter` (`yadif_videotoolbox`, `bwdif`, `yadif`), `isHardware`, `fieldRate`, and `outputFramesPerSourceFrame` (2 at field rate, so "deinterlaced to 50 fps" is `sourceVideoFrameRate * 2`). nil while frames go out as decoded. The graph starts on the first frame flagged interlaced and stays until a seek.
- Republished when any of these changes mid-stream.
- **nil on every native route.** AVPlayer decodes there, and its frames never pass through the engine. A panel shows `$sourceVideoStreamFormat` and names AVPlayer as the decoder, instead of inventing a pixel format nobody measured.

#### Display capabilities

A settings screen reads `AetherEngine.displayCapabilities` instead of guessing from the device model.

- **macOS:** the table comes from `AVPlayer.eligibleForHDRPlayback` (there is no per-mode API there) and does not claim Dolby Vision. `LoadOptions.panelPresentsDolbyVision` is for that.
- **tvOS and iOS:** the per-mode table is `AVPlayer.availableHDRModes`, but since 6.82.0 it may only ADD. `supportsHDR10` and `supportsHLG` use eligibility as their minimum, because the table under-reports HLG over HDMI on a panel whose EDID advertises it (AE#459). Dolby Vision still comes from the table alone on those platforms, where it is measured correct in both directions.
- **visionOS:** `supportsHDR` comes from `AVPlayer.eligibleForHDRPlayback`; `supportsHDR10`, `supportsHLG` and `supportsDolbyVision` are all false.
- **It answers at CALL TIME**, so a stored value is a snapshot of one moment. On tvOS a backgrounded process gets an answer for its own state: every term reads false until the app returns.
- A session reads it once, at the load, and every route and rebuild of that session answers to that one table (AE#535).

## Audio tracks

| Symbol | Notes |
| --- | --- |
| `$audioTracks` | `[TrackInfo]`. Republished when `LoadOptions.confirmAtmos` confirms a track, and when the DTS:X decoder confirms the playing track as DTS:X (`isDTSX`). On `.remoteBypass`, see below. |
| `$activeAudioTrackIndex` | The selected track's id. On `.remoteBypass`, the enabled item track's. |
| `selectAudioTrack(index:)` | Session-preserving reload. `index` is `TrackInfo.id`. See [Switching audio tracks](#switching-audio-tracks). |
| `audioShaping`, `setAudioShaping(_:)`, `$audioShapingState` | Shape the session's audio before it reaches the output (AE#923). See [Audio shaping](#audio-shaping). |
| `installAudioTap(channels:)`, `removeAudioTap()`, `audioTapHasDeliverySource`, `AetherEngine.audioTapFormat` | Opt-in decoded PCM, mono Float32 48 kHz with source-PTS stamps, off the render path. `channels` is an `AudioTapChannels`: `.downmix` (default) or `.dialogue` (the centre channel alone). See [the audio tap contract](#the-audio-tap-ends-with-its-session). |

**`$audioTracks` on `.remoteBypass`** lists the audio tracks AVPlayer built for the item, normally just the one playing. They are read from their format descriptions:

- `codec` in libavcodec's spelling (`eac3`, `ac3`, `aac`), `channels`, `sampleRate`
- `profile`: AAC's object type; "Dolby Digital Plus + Dolby Atmos" with `isAtmos` when the E-AC-3 dec3 record announces JOC
- `language`, from the track or the selected audible option

The ids are synthetic (from 400000 up), because there is no stream index on that route. Compare them only with `activeAudioTrackIndex`.

### Switching audio tracks

`selectAudioTrack(index:)` is a session-preserving reload.

- **Native path.** The old item stays mounted while the source reopens. Its last picture is held until the new item's first frame, so the switch shows a still, not black. How and where it is held (still view, PiP, Dolby Vision, software path): [Held pictures across an audio switch](#held-pictures-across-an-audio-switch). Audio is not gapless, and a media-services reset still discards the item.
- **Elsewhere** expect roughly 0.5 to 1 s of black.
- **Rapid picks** are merged, so only one rebuild runs at a time. A pick back to the active track costs nothing, and `stop()` or a new `load` drops what is queued.
- **A pick during a load** waits until that `load` returns, then rebuilds. `audioTracks` is published before the load's display handshake, and a rebuild that replaced the load there lost the HDR route (AE#1061). The host's `load()` now also returns normally instead of throwing `CancellationError`. To skip the extra rebuild, pass the track to `load` as `audioSourceStreamIndex`.
- **Transport.** Like `reloadAtCurrentPosition()`, it comes back in the session's transport state: a paused session stays paused. A `play()` or `pause()` that arrives while the rebuild waits on I/O decides the final state.

It does nothing in these cases. Every refusal is logged, so a picker that does nothing can be explained:

- when out of range or already active
- on a forward-only custom source (live ingest included), which cannot rebuild its pipeline. There a track change is a fresh `load` naming the stream.
- on a sequential origin (`$isSequentialOrigin`): a track change there is a fresh `load`, see [`sequentialOrigin`](#sequentialorigin).
- on `.remoteBypass`, where AVPlayer owns the audio selection and the track list is informational. A different language there is a different URL.

### Audio shaping

`audioShaping` / `setAudioShaping(_:)` take an `AudioShaping`, which carries:

- a channel cap (`maxChannels`)
- a dialogue lift (`dialogueGainDB`)
- night-mode compression (`compressor`; `AudioShaping.Compressor.night` is the engine's preset). With `ratio: 1` it is a plain gain of `makeupGainDB` into the limiter.
- a loudness target (`loudnessTargetLUFS`, clamped to `AudioShaping.loudnessTargetRange`, -36 to -12 LUFS). It raises a quiet source to that programme loudness, by at most `AudioShaping.maxLoudnessGainDB` (18 dB), and never lowers one (AE#1036).
- an LFE level for a fold that drops the LFE (`lfeMixDB`, clamped to `AudioShaping.lfeMixRange`, -20 to +10 dB; nil drops it). It only acts together with a `maxChannels` cap that folds the LFE away, so `AudioShaping(maxChannels: 2, lfeMixDB: 0)` is the stereo downmix for a 2.1 system. On its own it is not active shaping (AE#1044).

Values are clamped, and read back clamped. The default shapes nothing and leaves every route as it was.

- **Active shaping needs PCM.** While it is on, a stream-copied track (Atmos and every lossless bitstream included) is decoded and bridged, and shaping takes precedence over `objectAudioRendering`. Turning it off goes back to stream copy.
- **Every change is the session-preserving reload** (`reloadAtCurrentPosition`), because it changes which pipeline the session runs. Changes that arrive during that rebuild are folded into it, as with `setAudioDelay(_:)`. The exception is a change between two inactive values (an `lfeMixDB` without a cap): it is stored, and nothing is rebuilt.
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
| `addExternalSubtitleTrack(_:)`, `removeExternalSubtitleTrack(id:)` | Register or unregister an `ExternalSubtitleTrack` at runtime. Returns the `TrackInfo` it is listed as. Tracks added after load are overlay-only; to have them join the native renditions, declare them in `LoadOptions.externalSubtitles`. |
| `selectSidecarSubtitle(url:httpHeaders:)` | One-shot sidecar decode without listing a track. Prefer `addExternalSubtitleTrack` + `selectSubtitleTrack`, which keeps the track listed and `activeSubtitleTrackIndex` set. nil headers inherit `LoadOptions.httpHeaders` for a same-origin URL only (see [External subtitle request headers](#external-subtitle-request-headers)). |
| `maximumSubtitleOffsetSeconds` | The largest subtitle offset, of either sign, the host applies to its overlay against `clock.sourceTime`. Setting it sets both of the next two; reading it gives the larger. Default 60. See [Cue retention](#cue-retention). |
| `maximumSubtitleDelaySeconds`, `maximumSubtitleAdvanceSeconds` | The same reach per direction (AE#1031): the largest LATER offset (cues shown after their time) and the largest EARLIER one. Default 60 each. See [Cue retention](#cue-retention). |
| `setSoftwareSubtitleDelay(_:)`, `softwareSubtitleDelaySeconds` | Media-time offset for both channels composited into software PiP frames: positive delays cues, negative advances them. Default 0. See the note below. |
| `SubtitleCaptionStyle`, `SubtitleCaptionStyle.current()`, `SubtitleCaptionStyle.observeChanges(_:)`, `SubtitleCaptionStyle.standard` | The user's system caption style. See [System caption style](#system-caption-style). |
| `teletextPage`, `setTeletextPage(_:)` | The DVB teletext caption page, at load and while the channel plays. |

**`setSoftwareSubtitleDelay(_:)`.** Non-finite values are ignored, and the value survives later loads on the same engine. It takes effect on the next composited frame, without a seek, reopen or A/V clock change. A host overlay applies the same value as `clock.sourceTime - delay`. AVPlayer-owned native renditions, native PiP and AirPlay are not shifted; a host offering a timing control should tell the viewer so.

### Cue retention

`$subtitleCues` holds the active track's cues from 300 s behind the playhead to the decode lead ahead.

- Bitmap cues (PGS/DVB/DVD) are kept as decoded RGBA. Those that ended further back than `maximumSubtitleDelaySeconds` (at least 15 s) are also dropped, oldest first, once their images exceed 64 MiB (AE#879). Once the host has set any of the three reach properties, all of them are dropped at once (AE#929).
- Before those, cues that start beyond the decode lead, and that the drain has not reached yet, are dropped, furthest first. After a backward seek these are the old position's cues. The drain decodes them again on its way there (AE#929).
- A seek back re-decodes what was dropped.

**The offset reach** (default 60 each way) sets how much bitmap cue history the engine keeps, and whether embedded subtitles cost a second read of a remote source. The two directions cost different things, so they can be set separately (AE#1031):

- `maximumSubtitleDelaySeconds`, for LATER offsets: the history behind the playhead that the 64 MiB budget never evicts. It reads nothing twice, because a later offset only needs cues the main reader has already passed.
- `maximumSubtitleAdvanceSeconds`, for EARLIER offsets: how far ahead the drain decodes (at most 60 s), and whether the forward prefetch below runs.
- `maximumSubtitleOffsetSeconds` sets both. Each edge stays at least 15 s. A positive `softwareSubtitleDelaySeconds` is always covered by the history, a negative one by the lead.
- A host whose control shifts subtitles only later, or much further later than earlier, sets `maximumSubtitleAdvanceSeconds = 0` and puts its later range in `maximumSubtitleDelaySeconds`.
- Setting it also drops every bitmap cue that ended behind that history at once, instead of keeping them up to the 64 MiB budget. Past that point a cue serves no offset, and a seek back re-decodes its own window anyway.
- A host without a subtitle offset control should set 0. On a dense PGS track that keeps 15 s of decoded images on each side, instead of a protected 120 s plus 64 MiB of history (AE#929).
- The text drain lead is unaffected. Negative and non-finite values are ignored. A change takes effect on the next drain tick.

**An advance of 0 also turns off the forward subtitle prefetch (AE#1015).**

- **Why.** That reader exists only to have cues ready for an advance offset. On a remote MKV or MP4 it downloads the video a second time.
- **Text tracks.** With an advance of 0, embedded text subtitles come from the main reader alone, which covers a zero or positive offset.
- **Bitmap tracks** (PGS, DVB, DVD) keep the reader for seek landings only (AE#1022). After each seek, and at the start, it reads from 15 s before the landing to 2 s past it, then waits for the next seek. That is how the line a seek lands inside is found: the main reader repositions on a video keyframe and never reads a set that began before it. Cost per seek: the window itself, plus up to one 32 MiB range the origin delivers in full.
- **Exceptions.** The prefetch still runs while `softwareSubtitleDelaySeconds` is negative or the OCR worker is armed (PiP, AirPlay, external display on a bitmap track). It starts or stops at once when either changes.

What each setting reads over HTTP, measured: [measurements.md › Subtitle offset reach and prefetch cost](measurements.md#subtitle-offset-reach-and-prefetch-cost).

### Native renditions (PiP, AirPlay, external display)

| Symbol | Notes |
| --- | --- |
| `$nativeSubtitleTracks`, `setNativeSubtitleSelected(track:markerOnly:)` | The WebVTT renditions declared by `prepareNativeSubtitles`, for PiP / AirPlay / external display. nil deselects. `markerOnly: true` ticks the track in AVKit's menu but serves it empty, for a host that draws the track itself ([formats](formats.md#showing-the-hosts-pick-in-avkits-menu-markeronly)). |
| `$nativeSubtitleDefaultOrdinal` | The rendition marked `DEFAULT=YES`, resolved from `nativeSubtitlePreferredLanguages`. A programmatic legible selection only renders if it is the default, so select **this** ordinal. |
| `$nativeSubtitleRenditionAvailable` | At least one cue exists for the native track. Gate the AVMediaSelection picker on it. |
| `$nativeSubtitleRenditionsServed` | Whether the served playlist is the master. Only a reload signal and a diagnostic: whether a legible rendition reaches a wired external display is up to AVKit and cannot be observed from here. |
| `setNativeSubtitleRendering(_:)` | Hand subtitle drawing to AVKit while the video leaves the host's view hierarchy, and take it back on return. See below. |

`setNativeSubtitleRendering(_:)` is used for PiP, AirPlay and a wired external display.

- It is a standing request: it holds until called with `false` or until the session ends, and survives the engine's own AirPlay reload.
- On a wireless AirPlay receiver the engine makes the request itself when the host has not. When the receiver lets go, it withdraws only its own request. A host call takes over at any time.
- A bitmap track (PGS / DVB / DVD) gets an OCR-fed rendition, selected once the recognized cues cover AVKit's fetch window ([formats](formats.md#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display)).
- No-op for a track added after load, which has no rendition until the next reload.

### System caption style

`SubtitleCaptionStyle` is the user's system caption style: font, size, text, background and window colour and opacity, and edge style. The software host reads it itself, because it has no AVKit legible output that would apply it.

- The engine applies it to the text cues it composites into software PiP frames, and re-renders on a change.
- A host drawing its own overlay calls `current()` and `observeChanges(_:)` (hold the returned `Observation`) to match.
- A field is non-nil only where the user's value differs from the system default. (The system's `UseValue` flag does not mean a change.)
- Each field carries a `Precedence`. `overridesCue` ranks user, then cue, then engine default. `yieldsToCue` ranks cue, then user, then default. For a field whose `Choice` is non-nil, a host drawing its own overlay calls `Choice.resolved(cue:)`. It returns the user's value or the cue's, as the field's `Precedence` says.
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

- Selecting a registered external ID keeps the old secondary cues, ASS header, identity and bitmap drainer active while the new track decodes. Only a successful preparation that is still current replaces them. A failure keeps the old selection and ends loading.
- A bitmap decoder must be created before the replacement.
- The older one-shot URL API keeps its behaviour: it replaces the old track as soon as it starts.
- Reloads save the pending selection, so an audio switch or repeated rebuild does not quietly bring back the old pick.
- Primary and secondary may select the same track.

`$activeSecondarySubtitleTrackIndex`:

- A registered external selection publishes its ID when the decoded replacement commits, together with its cues. While it decodes, and after a failed decode, the previous ID stays with the previous cues. Prepared selections also publish only at commit.
- Clearing, stop/load and the restore after a rebuild update the same identity. Re-selecting the same ID does not emit a duplicate.
- As with other `@Published` fields, a synchronous subscriber uses the delivered value instead of re-reading during willSet.

`$secondarySidecarASSHeader` is nil by default, for a committed non-ASS selection, and after clearing or stopping. A registered secondary replacement keeps the old header while preparing; session-preserving reloads decode it again with the restored track.

#### Secondary subtitles across audio rebuilds

An active registered secondary subtitle survives an audio-track rebuild through its original registry id, including `ExternalSubtitleTrack.httpHeaders` and `sourceStreamIndex`.

- A one-shot secondary sidecar is still restored through its URL.
- Switching to an embedded secondary track clears the previous sidecar URL.
- Internal teardown clears the active secondary identity while the rebuild's saved selection can restore it. A decode result from an older load cannot republish cues or loading state in the new one.
- This adds no bitmap/ASS capabilities, and does not forbid selecting the same track in both channels.

### External subtitle request headers

When an external subtitle has no explicit `httpHeaders`, it inherits the media headers only if its URL has the same HTTP scheme, host and effective port as the media URL.

- An omitted default port counts as equal to an explicit default port.
- A scheme change, HTTP to HTTPS included, makes a different origin for this first sidecar request.
- Unknown media origins and local files inherit nothing.
- This applies to primary and secondary overlays, native subtitle cue-store fills and remote-HLS sidecar renditions.
- For a subtitle server requiring authentication at another origin, set `ExternalSubtitleTrack.httpHeaders` or the sidecar call's `httpHeaders` explicitly. An explicit empty dictionary disables inheritance.
- Redirects still follow the existing redirect-header policy, and certificate trust still uses `EngineTLS.serverTrustEvaluator` independently.

### Prepared external subtitle selection

Use this to decode a downloaded subtitle file first and commit it only if it worked, without disturbing the current selection.

- `prepareExternalSubtitle(_:policy:)` decodes a downloaded regular SRT, WebVTT, ASS or SSA file without changing the active tracks, preferences or cue lists.
- `prepareExternalSubtitle(id:policy:)` prepares an existing registry entry without creating another ID.
- Preparation requires a playing, paused or seeking session, and returns a MainActor-owned `PreparedExternalSubtitle`. Success means it did not throw: a file with no cues throws `.empty`, so a returned handle always has a `cueCount` above zero. `cueCount` is for display, such as a "1,204 lines" label.
- The existing `preserveASSMarkup` option governs ASS output.
- `commitExternalSubtitle(_:secondary:)` consumes the handle once and publishes the already-decoded cues synchronously. It does not reopen or decode the file. It returns the `TrackInfo` the track is listed under (discardable). When it rejects the handle, it throws `ExternalSubtitlePreparationError` (`.stale`, `.cancelled`).
- `discard()` releases an unused candidate.
- `ExternalSubtitlePreparationError` distinguishes `unsupportedFormat`, `empty`, `resourceLimit`, `decodeFailed`, `cancelled` and `stale`. A failed preparation or rejected commit keeps the prior selection.

**Limits.** `ExternalSubtitlePreparationPolicy` bounds:

| Field | Default |
| --- | --- |
| `maximumFileBytes` | 4 MiB |
| `maximumCueCount` | 50,000 |
| `maximumCueBytes` | 8,192 UTF-8 bytes |
| `maximumTextBytes` | 8 MiB |

Hosts can supply other positive limits. Ordinary subtitle selection behaves as before. A track registered by a successful prepared commit remembers its policy for later selections.

**Files.**

- Preparation runs the file metadata checks and the decoding on the existing blocking worker, not on the MainActor.
- Downloading a remote file is still the host's job.
- The local filename must have a supported extension; `formatHint` does not open the API to arbitrary containers.
- Do not change the file while it is being prepared.
- Non-regular files, symbolic links, unsupported codecs and multistream containers are outside this API.

**Invalidation.** A prepared candidate belongs to one engine, one load/stop generation and one shared subtitle-selection intent.

- These invalidate older candidates: a selection or clear on **either** channel, registry removal, a successful commit, stop, or a new load.
- So two candidates prepared separately are not an atomic primary/secondary pair: committing one invalidates the other. That keeps a late picker result from replacing a newer user choice.
- The same registered subtitle stays selectable on both channels; the engine adds no host-specific exclusivity policy.

## Live and DVR

| Symbol | Notes |
| --- | --- |
| `$isLive` | Mirrors `LoadOptions.isLive` for the session. |
| `$isSequentialOrigin` | True while a VOD session is served as a sequential origin, declared or found by the reader. Set during `load()`, cleared on stop. See [`sequentialOrigin`](#sequentialorigin). |
| `seekToLiveEdge(offsetSeconds:)` | `async`. Lands `offsetSeconds` behind the usable edge (default 0; negative or non-finite read as 0), clamped to retained media. The safety margin is the host's call. On a live-only session it moves the native item to its own seekable end minus the offset. |
| `currentItemLiveEdgeTime` | The native item's usable live edge on the display axis. nil before the item has a range, and on the software route. See the note below. |
| `liveTargetDurationSeconds` | The TARGETDURATION the engine's own live playlist is serving. nil on remote HLS live, on the software path and before the first playlist build. |
| `setNativeLiveDVRLimits(_:availableCapacityBytes:)` | Renews the native loopback session's DVR allowance without a reload or a second source. See [DVR limits](#dvr-limits). |
| `nativeLiveDVRMandatoryBytes` | The finite pinned playback payload that may exceed that allowance. Excludes init and subtitle data, muxer staging, AVPlayer's buffers, filesystem overhead and recordings. |
| `setSoftwareLiveDVRLimits(_:availableCapacityBytes:)`, `softwareLiveDVRBytes` | The same lease for the software live spool, which needs `LoadOptions.softwareDVRRetention`. `softwareLiveDVRBytes` is the retained packet payload. See [DVR limits](#dvr-limits). |
| `liveSourceReset` | The [retune contract](#live-the-retune-request). |
| `liveSourceReplayExhausted` | Verified replay exhausted one bounded recovery round. Cached DVR stays readable; retry via `retryLiveSourceRecovery()` under the host's backoff without losing packet history. See [exhausted verified replay](#live-exhausted-verified-replay). |
| `liveResumeClamped`, `LiveResumeClamp` | A resume that found the playhead outside the window and moved it; see [a resume that had to move](#live-a-resume-that-had-to-move). |
| `liveScrubThumbnail(atSessionSeconds:maxWidth:)` | Still on the live session axis, decoded from what the session already holds. A native session reads its DVR segment cache; a software session reads its DVR packet ring (#544). So a tuner channel the box decodes in software has a scrub preview too. |
| `$playlistShiftSeconds` | Seconds the producer subtracted from source PTS. Published values already add it back; it is exposed for hosts pairing their own samples against AVPlayer's raw clock. |
| `HLSLiveIngestReader(playlistURL:)`, `HLSLiveIngestReader(playlistURL:httpHeaders:diagnosticContext:)` | The ready-made `IOReader` for ingesting an upstream HLS playlist directly, with AES-128 clear-key and SSAI handling. See below. |

**`currentItemLiveEdgeTime`.** While AVPlayer's copy of the range lags behind the retained history, only resident media that has already played and is contiguous counts, never prefetched media.

**Timestamp resets.** When the origin resets its timestamps on the native loopback path, `currentTime`, the seekable range, item placement and seek targets keep the session's initial timeline shift, so the displayed time stays continuous. `clock.sourceTime` stays the presented frame's source PTS for cue matching. So the two differ after a reset, on purpose.

**`HLSLiveIngestReader`.** The headers go with the playlist, every segment and every AES key, because a tokenized IPTV origin checks them per request. Credential headers (`Authorization`, `Cookie`, `X-Emby-Token` and the like) go only to the playlist's own origin, never downgraded from https to http. A URI the playlist points at another host gets the other headers without them, the same rule a redirect follows. Unsupported shapes surface a typed `HLSIngestError`.

### DVR limits

`setNativeLiveDVRLimits(_:availableCapacityBytes:)` takes a `LiveDVRLimits` (`windowSeconds`, `maximumBytes`, `minimumFreeBytes`, `capacityValidUntil` on the `systemUptime` clock) plus the caller's capacity sample.

- Cache eviction, playlist sizing and producer admission share it.
- A missing, invalid or expired sample withdraws the optional history (`seekableLiveRange` goes nil), and a timer frees the space even while playback is paused. Renewing needs a fresh sample and deadline.
- The engine's own per-volume budget still applies on top.
- Returns false on a software, remote or unready session.

`setSoftwareLiveDVRLimits(_:availableCapacityBytes:)` is the same lease for the software live spool.

- Expiry withdraws the seekable history and prunes at the next append. So while no packets arrive, the disk space is not freed at once.
- A feeder whose cursor was evicted re-anchors through its normal seek before pumping again. A newer seek, pause, stop or source change wins over that recovery.

### Where a live start's seconds go

On the loopback live path (a raw stream, or an HLS source the engine ingests itself), the join does not cost probe or decode work. It costs one response the engine holds back on purpose.

**What the host must do:** read `startupProgress` before treating a slow live start as a decode problem. Key the "playing" chrome on `$playbackPhase`. Choose the join trade with `liveJoinProfile` and `liveJoinStartsImmediately`; both default to the fast side.

**The holdback.** The engine serves AVPlayer a playlist of its own. AVPlayer starts a live session at the edge minus a holdback of `3 x TARGETDURATION`, the RFC 8216bis minimum that the served playlist advertises. So the engine holds the first `/media.m3u8` until the window carries that much content behind the edge. Serving earlier puts AVPlayer's opening seek inside its own stall-danger zone, where it restarts in a loop instead of playing (#189).

- An origin that hands over a backlog fills it at I/O speed.
- A strict-realtime origin fills it in wall-clock time.
- The native bypass has no such gate, so a host measuring both sees the wait only on the paths that ingest.

**How to see it.** Read these before treating a slow live start as a decode problem:

- `startupProgress` stops at `sessionConstructed` for the whole wait. The checkpoint at the slow moment tells this apart from the demux probe (`streamsProbed`) and the display handshake (`routed`).
- The first serve logs how long it held, the window it served, and the holdback it was measured against, whether it waited or not.

The measurements behind the rules below are in [measurements.md › Live join](measurements.md#live-join-sealing-over-the-upstream-segment).

#### `liveJoinProfile` and `.fastZap`

`LoadOptions.liveJoinProfile` is the lever, and `.fastZap` is its default. It shrinks `TARGETDURATION` to the source's keyframe interval, and the holdback shrinks with it. So the gain depends on the source's GOP, not on the flag: `TARGETDURATION` can never fall below `ceil(max EXTINF)`, so a long-GOP source keeps most of its wait under either profile.

Where the engine cuts the segments itself, each segment is a whole GOP, and the value is fixed ("sealed") from the first few. So it leaves headroom for a GOP 1.5 x the longest seen (AE#670). The headroom is the smallest value under which that longer GOP still lists (RFC 8216 rounds EXTINF to the nearest integer) and finishes inside AVPlayer's `1.5 x TARGETDURATION` patience with 0.5 s to spare.

- 1 s GOPs serve TARGETDURATION 2 and a 6 s holdback.
- So does a 59.94 fps stream whose scene-cut keyframes merge GOPs into 80 to 89-frame segments (up to 1.666 s seal 2).

#### An ingested HLS upstream: sealing over the whole upstream segment

**An ingested HLS upstream seals over the segment it is delivered in, as far as its join pays for it, under either profile** (AE#684).

The engine re-cuts an upstream segment (at its GOPs under `.fastZap`, at about 4 s under `.standard`). But the window still changes only once per UPSTREAM segment. So the seal asks for the longest segment the upstream has served, whole. The upstream's advertised target duration is not read.

The seal is bounded three ways:

1. **By the join, which is not made deeper for it on an upstream with uniform segment lengths.** A seal means a holdback of `3 x` itself, and the join there is three upstream segments. Their last GOP stays open until the next delivery. So three 6 s segments are 18 s joined and 16 s cut, and the seal is 5 (the largest value whose holdback that window holds), not 6. Three 10 s segments cut 28 s and seal 9.
2. **By a ceiling.** Segments longer than 10 s (`LiveEdgePolicy.upstreamSegmentSealCeilingSeconds`) are not asked for whole: a 20 s one seals 14, because the live-only window is 60 s.
3. **Never below the seal the re-cut segments give on their own.** Where that already covers the segment, nothing changes: 2 s segments keep 2 and a 6 s holdback, and `.standard` keeps its 6 on anything up to 6 s.

**Alternating segment lengths.** The one change to the join: on an upstream whose segment lengths alternate, the join depth is evened out over the PHASES. A tune never loads more than the deepest tune of the same channel already did.

- The depth is the deepest the coverage rule picks across the tune itself and the tunes one, two, ... segments earlier that its own join still reaches. It is at most one segment more than its own.
- Alternating 6 s and 4 s segments join four in both phases and seal 6. The phase that would have joined three loads one extra short segment at the join.
- Shapes whose phases already join alike keep their join: 10 s / 8 s stays at three segments and seals 8; 6 s / 6 s / 4 s stays at three and seals 4. A shape like 6 s / 5 s keeps a seal that follows the phase (5 in one, 4 in the other). The evening out is about how much a tune loads, not what it seals.

**The resulting seal and holdback:**

| Upstream | Seal (holdback) |
| --- | --- |
| uniform 6 s, `.fastZap` | 5 (15 s) |
| uniform 10 s, either profile | 9 (27 s) |
| alternating 6 s / 4 s, both phases | 6 (18 s) |
| 3 s segments with 1 s GOPs | 2: three joined segments cut 8 s, which pays for no more |

**What the log says.** The seal line says how much the join covered (`of which the join pays 5s of 6s (16.000s cut of the 18.000s it listed)`). "The join has no more to give" is a fact the reader states (its join batch is handed over and its consumer is waiting). It is not arithmetic on EXTINF, which would go wrong on a playlist that rounds its durations up.

**Demuxed audio.** With a demuxed audio rendition, the cutter states that fact instead of one reader: both join batches are handed over, and the cutter is waiting on either of them. An audio rendition whose segments end a little before the video's runs dry first, so the video reader is never the one being waited on.

**A slow join.** A join SLOWER than the `.fastZap` grace (a single-connection provider or a slow link) takes the bounded start before the grace runs out. It then seals the full value (6 or 10, not 5 or 9) over a window shorter than its holdback. AVPlayer logs a `-16832` warning about that at the start.

**What it costs a host.**

- **A host that allows fewer parallel requests than the join has segments** (`maxConcurrentSourceRequests` of 3 or less) sees its first picture later, because the gate waits until the join is handed over.
- **Standing latency** behind the upstream's edge follows the holdback in the table above.
- The seal does not change the time to first picture on a uniform upstream.

**What it does not do:**

- On a 6 s provider `-12888` still comes: 7.5 s of patience still loses to a 9 s delivery gap. The seal only changes the holdback under it.
- `.standard` on 6 s segments still takes about 6.3 s to its first picture, waiting for the next upstream segment. Its seal there is its own `1.5 x cut target` minimum, which three joined segments never cover.
- A real outage longer than the holdback's low point stalls under any of these.

#### An HLS source with its own window fills the cushion at the join

**An HLS source with a window of its own fills the cushion at the join, not in wall-clock time.** The ingest joins with the coverage its own policy targets, which on short segments is several times three segments. So the gate does not wait one upstream segment duration for content the origin already holds in its window.

- A window at the three-segment minimum has nothing deeper to offer and joins at three. So does a long-segment provider, whose coverage target is met within three segments.
- The deeper entry is not paid back later. It is caught up at I/O speed and does not become a standing lag behind the live edge.
- It does not affect a source with no playlist at all (raw MPEG-TS over HTTP). There is no window to enter further back, and the content does not exist yet.

Measured effect: [measurements.md › Live join: filling the cushion from the origin's window](measurements.md#live-join-filling-the-cushion-from-the-origins-window).

### The tail after the first serve, and which signal survives it

**What the host must do:** key chrome on `$playbackPhase`. Leave `liveJoinStartsImmediately` on unless the host wants AVPlayer's own policy for the join.

A serve is not motion. After it, AVPlayer can show the first frame, publish `waitingToPlayAtSpecifiedRate` with `AVPlayerWaitingToMinimizeStallsReason`, and hold that frame perfectly still for seconds. Meanwhile it decides whether its cushion will sustain playback (AE#440).

- Nothing on the item shortens it. `preferredForwardBufferDuration` has no effect there, because the wait is a rate evaluation, not a buffer target.
- Treat it as a policy of the player on the device, not something a different served playlist could avoid. It does not reproduce on a macOS loopback harness.

Two consequences for a host:

**Key chrome on `$playbackPhase`, not on `state` or `$hasFirstFrameReadyForDisplay`.** Both of those fire before playback starts moving, and correctly so: one is intent, the other is a picture. `playbackPhase` is `.loading` for the whole hold and turns `.playing` when playback starts moving.

**`liveJoinStartsImmediately` cuts the hold short.** It acts once per load, on a live session, when AVPlayer reports the buffer as non-empty and it holds at least 1.5 s ahead of the playhead.

- It is the other half of the trade `.fastZap` already makes: playback starts on a thinner cushion. A source that hiccups just after the join then rebuffers, where it would otherwise have started later and played through.
- Every later hold in the session keeps AVPlayer's own policy, so a mid-stream rebuffer is untouched.

**It is on by default.** The first picture comes at the same time, so the option removes exactly the frozen tail and nothing else. The cold case is untouched, because the guards keep it out of a starved join. Set it `false` to keep AVPlayer's own policy for the join. The device A/B behind the default: [measurements.md › Live join: the hold after the first serve](measurements.md#live-join-the-hold-after-the-first-serve).

**Why it checks the depth, not just the empty flag.** `isPlaybackBufferEmpty` is the precondition `AVPlayer.h` documents, not a measure of safety: one served fragment reads `false` just like a four-second cushion. On the measured stack the hold is AVPlayer waiting on its own rate estimate, never starvation at the edge, so cutting it short costs nothing there. Behind the same `false`, though, a starved join holds a fraction of a second, and starting there would trade a still picture for an immediate stall. So the guard reads the depth.

- The depth is the contiguous span ahead of the playhead; an island past a gap does not count.
- When the minimum is not met, the engine logs it once per load (`leaving the stall-avoidance wait alone (buffer ahead ...s, ...)`). In a report after the fact, that tells the two causes apart.

**And the item has to be able to play (AE#684).** The depth is measured from the item's own `currentTime()`. Before `readyToPlay` that is where the loader began fetching, not where playback will begin. Under an `EXT-X-START` placement (how a rejoin lands a fresh item where the session was), AVPlayer first fetches from about 6 s below the target, so the reading would only measure that lookback.

So a hold on an item that cannot play yet is left alone (`leaving the stall-avoidance wait alone on an item that cannot play yet ...; asked again at readiness`). It is decided again when the item becomes ready, from the playhead it really starts on.

### The rewind depth a live session really has

`seekableLiveRange` is where the DVR window and what the cache really holds overlap. `seek(to:)` clamps to it, so a target the range accepts is a target the seek reaches.

The floor is found by walking back, without gaps, from the newest resident segment. It is not the cache's lowest index: a lowest index does not prove coverage, and a rewind offered below a hole in the middle cannot play forward. Where an arithmetic window promised too much: [measurements.md › `seekableLiveRange` before it asked the cache](measurements.md#seekableliverange-before-it-asked-the-cache).

**Resuming behind live.** When a session has fallen behind, `play()` recovers a playhead that no longer exists:

- it snaps a live-only source more than 45 s back to the edge
- it lands a DVR session whose window has slid past the playhead just above the retained floor

Both are recoveries, not opinions about where a viewer should be. Both are silent, unless the host listens to `liveResumeClamped`. A host with its own live-pause behaviour (a long pause that re-tunes, say) sets `clampsLiveResumeToWindow: false`. Then `play()` moves nothing, and `seekToLiveEdge()` performs the same recovery on request. The engine keeps reporting; the host decides.

**Where did a seek land?** Use `SeekEvent.landed(renderedTime:)` on `$seekEvents`. `await seek(to:)` returns no position, so a harness that records its own requested target reports an intention, not an outcome.

## Recording a live stream

| Symbol | Notes |
| --- | --- |
| `startRecording(to:)` | `async throws`. Records the live source to a file, fed from the connection the session already holds. |
| `stopRecording()` | `async`. Ends the recording and closes the file. Idempotent, and a no-op when nothing is recording. |
| `$recordingState` | A `RecordingState`: `.idle`, `.recording(RecordingProgress)`, `.ended(RecordingEndReason)`, `.failed(RecordingFailure)`. Progress republishes at 1 Hz, not per packet. |

**No second connection is opened.** That is the point of the feature. An IPTV plan often caps an account at 1 to 3 simultaneous connections. A host that opens its own connection to record either fails outright or knocks the viewer off the channel. The engine already holds the one permitted connection and already demuxes every packet.

**What is written.** A **stream copy of the source packets into MPEG-TS**, taken before any audio bridging. Nothing is decoded and nothing is re-encoded.

- A TrueHD or DTS channel records its original audio, while playback listens to the bridged FLAC rendition.
- A file cut short by a crash or a kill is still playable up to where it stops. That is why the container is MPEG-TS and not fragmented MP4.
- The file starts at the first video keyframe after the call, so it begins on a decodable picture, not mid-GOP.
- It follows the source, not the playhead. Pausing, or scrubbing back inside the DVR window, does not interrupt it.

**Which routes can record.** Only the two where the engine owns the byte path:

| `videoRoute` | Who holds the source connection | Recordable |
| --- | --- | --- |
| `.loopback` | The engine: demuxer, segment producer, local server | yes |
| `.software` | The engine: demuxer, software playback host | yes |
| `.remoteBypass` | AVFoundation, directly against the origin | no |

On `.remoteBypass` (`LoadOptions.nativeRemoteHLS`) the engine never sees a byte. There is nothing to record without opening the second connection the feature exists to avoid, so `startRecording(to:)` throws `.unsupportedRoute(.remoteBypass)` instead of recording nothing.

The way out is the one under [Where the token rotates](#live-the-retune-request): reload with `nativeRemoteHLS: false`, and the session moves onto the ingest reader and `.loopback`. The engine does not reroute by itself. That would visibly interrupt the picture as a side effect of pressing Record, and the routing decision belongs to the host.

**The two reporting channels are separate.** One failure is never reported through both.

- Thrown from `startRecording(to:)`: conditions a host can act on before anything is written. `.notLive`, `.unsupportedRoute`, `.alreadyRecording`, `.cannotCreateFile`, `.noStreamsToCopy`.
- Published through `$recordingState` as `.failed`: conditions that only show up while writing, long after the call returned. `.diskFull`, `.writeFailed`, `.writeTooSlow`.

**`.writeTooSlow`: the engine drops the recording, not the picture.** Writes go into a bounded queue that is drained off the demux thread. When that queue fills, the recording ends and says so. Otherwise the demux thread would wait on a slow disk and stall playback, and the engine does not make that trade.

**A reset ends the recording.** When `liveSourceReset` fires, or the host calls `reloadAtCurrentPosition`, the file is closed cleanly and `$recordingState` publishes `.ended(.sourceReset)`.

- The recording does not continue in the same file. A reset can bring back different codecs, different parameter sets or a different program. Writing that into streams declared from the old source gives a file that is unplayable, or silently wrong, past the seam.
- The host gets the event and starts part two if it wants one.
- `stop()` and a new `load()` end it the same way, with `.ended(.sessionEnded)`. A recording never outlives its session.

**Timing of `.ended`.** It is published once the file is closed. The queued tail and the trailer are written off the main actor, so it can arrive a moment after the call that ended the recording.

- `stopRecording()` returns only after it.
- A `startRecording(to:)` issued in that moment waits for it first. If a `stopRecording()` or a new `load()` overtakes that wait, the start throws `CancellationError` and records nothing.
- A stop that lands while the writer is already tearing itself down after a failure (`.writeTooSlow`, `.diskFull`, `.writeFailed`) waits for that teardown and publishes the failure, not `.ended`.

**Not implemented: recording from the start of what is already buffered.** A recording begins at the call, not at the back of the DVR window.

- On `.loopback` the retained media is remuxed fMP4 with **bridged** audio, not source packets. Prepending it would give one file whose audio codec changes in the middle.
- On `.software` the packet ring does hold source packets. But one API that works on one route and not the other is worse than not offering it.

If you need it, say so on the tracker instead of working around it.

## Picture, layers and PiP

| Symbol | Notes |
| --- | --- |
| `videoGravity` | Fill mode of whichever layer is mounted (`AVPlayerLayer` or the software display layer). Settable; this is the aspect-fit / aspect-fill control. |
| `AetherStillView`, `bindStillView(_:)`, `unbindStillView(_:)` | Holds the outgoing picture across an item swap, for a host that renders the native path through AVKit rather than `AetherPlayerView`. See [Held pictures across an audio switch](#held-pictures-across-an-audio-switch). |
| `nativePlayerLayer` | The engine's own `AVPlayerLayer`, for a host building `AVPictureInPictureController` around a layer rather than around `currentAVPlayer`. |
| `$softwarePiPSource` | `SoftwarePiPSource` for sample-buffer PiP on the software path. See [Picture in Picture on the software path](#picture-in-picture-on-the-software-path). |
| `$softwareDisplaySize` | The rectangle the software path's picture is shown at: the coded size under the decoder's pixel aspect. It follows the stream (not latched), so a mid-stream resolution change reshapes it. nil on every other path. |
| `$activeUpscale` | `UpscaleStatus?`: what the low-resolution upscale stage (`LoadOptions.upscalesLowResolutionVideo`, #846) does for this session. See [Upscale status](#upscale-status). |
| `sourceVideoWidth`, `sourceVideoHeight`, `sourceVideoPixelAspectRatio` | The source's CODED size, and the multiplier that turns it into the presented one (`width * ratio`), read once from the probe. See note 1. |
| `pictureInPictureActive` | Host-set. Keeps the pipeline and the loopback server alive across a background transition, and keeps the software path decoding video for the window. |
| `needsForegroundVideoRestore` | True after the background policy actually released the video item. Before play, restore with `reloadAtCurrentPosition(applying:)` and choose the transport intent you want. False when video was retained, or after stop/load. |
| `retainsVideoPipelineWhenBackgrounded` | Opt in to keeping a paused video pipeline through background suspension. Default false. Set before backgrounding. See [Background behaviour](#background-behaviour). |
| `backgroundPlaybackEnabled`, `backgroundTeardownGraceSeconds` | Background audio policy. See note 2. |
| `presentationAxisMap` | `PresentationAxisMap`: `sourceSeconds(forItemSeconds:)`, `itemSeconds(forSourceSeconds:)`, `shiftSeconds(atItemSeconds:)`, `seams` (each a `PresentationAxisMap.Seam` of `itemSeconds` and `shiftSeconds`), `isEmpty`. Readable off the main actor. See note 3. |
| `setNativeVideoFrameTimeObserver(_:)` | Takes a `NativeVideoFrameTimeObserver`, called per muxed frame on both axes (`NativeVideoFrameTime`: `source`, `item`, `segmentIndex`, `isKeyframe`, `epoch`). Runs on the producer pump thread in **decode** order, so `source` is not monotonic under B-frames. `epoch` rises process-wide. |
| `setSoftwareVideoFrameTimeObserver(_:)`, `softwarePresentationTimebase` | The software-path equivalent: a `SoftwareVideoFrameTimeObserver` over `SoftwareVideoFrameTime` (`presentation`, `generation`), in ascending presentation order, on the same axis as the cues. `generation` moves on every renderer flush. |

1. **Source size.** On `.remoteBypass` it comes from AVPlayer's item video track once that resolves, so it is the delivered size. The ratio is 1 on square pixels, and on a declared ratio the engine refuses (#290); it is never a guess. On the paths that draw, prefer what is on screen (`softwareDisplaySize`, `AVPlayerLayer.videoRect`) over recomputing it from these.
2. **Background policy.** `backgroundPlaybackEnabled` defaults to `true` (iOS: PiP and background audio; tvOS: the PiP keepalive). The grace window (15 s default) lets a paused session survive a quick app switch. It applies on iOS only and is ignored on tvOS; 0 restores the immediate teardown.
3. **`presentationAxisMap`.** Cue times and `sourceTime` live on the source axis; `AVPlayerItem.currentTime()` lives on the item axis. They differ by the producer shift.
   - The property itself is never nil. Its three conversions return nil, not a guess, where no seam covers the position.
   - A host or test can also build its own: `init(seams:)`, `anchored(shiftSeconds:)` (one shift covering everything), `appendSeam(shiftSeconds:activatingAtItemSeconds:)`, and `maxSeams` (64; older seams are dropped beyond that).

### Held pictures across an audio switch

An audio-track switch swaps the item in place, and `replaceCurrentItem` blanks the player layer until the new item's first frame. The engine holds the outgoing picture over that gap on the bound `AetherStillView` (or, without one, on the bound `AetherPlayerView`).

- **Placement.** The still view is transparent and takes no input. Place it above the video and below the host's controls, for example at the top of `AVPlayerViewController.contentOverlayView`, and set its `videoGravity` to the host player's fill.
- **Software path.** It holds its renderer's last picture across the rebuild the same way.
- **Dolby Vision without a displayable base layer** (Profile 5, AV1 Profile 10) cannot be held as the output delivers it.
  - Without the `DolbyVisionStillReshaping` trait, the engine remuxes the resident segment's video into a standalone file. A player that belongs to the holding surface seeks it frame-exactly to the outgoing position. So the system compositor colours the held frame the same way it colours playback (pixel-identical to the paused outgoing picture on the clips measured; shown within 165 to 220 ms on an M1).
  - With the trait, the frame is a 960-wide still decoded through the scrub stills' RPU reshaping.
  - Either way the switch waits for it (up to 3 s, with the outgoing picture paused meanwhile).
- Other profiles hold their base layer.
- Nothing is held in PiP or on external playback.

### Picture in Picture on the software path

`$softwarePiPSource` publishes a `SoftwarePiPSource`: the display layer, plus transport answers on the axis of the enqueued frames. In practice iOS only: tvOS AVKit does not evaluate sample-buffer content sources (FB9751461).

**Building the controller.**

- `SoftwarePiPSource.isSupported` (static) says whether the system offers PiP at all.
- `makePictureInPictureController()` returns a ready `AVPictureInPictureController` (nil when `isSupported` is false). Its content source uses `playbackDelegate`, a `SoftwarePiPPlaybackDelegate` that maps play, pause, skip (clamped to the VOD duration) and the time range onto the engine's transport.
- The host keeps the controller and sets `pictureInPictureActive` from its callbacks.
- A reload replaces `softwarePiPSource`, and the content source holds its delegate weakly. So rebuild the controller on every `$softwarePiPSource` change.

**Lifecycle.**

- When `state` or `duration` changes, the source invalidates the playback state of the controller it made (the latest one).
- When `softwarePiPSource` becomes nil (the session ended), the engine stops the controller it made and resets `pictureInPictureActive` to false. A host with its own controller closes PiP at that point and treats `pictureInPictureActive` as false.
- Any load on the software path ends PiP the same way, because each load builds a new display layer. (The native path hands the item over instead.)

**Layer geometry.** While `pictureInPictureActive`, a bound `AetherPlayerView` sizes the display layer to the picture's rectangle for the active `videoGravity`. The PiP window copies the layer's own geometry, so this shapes the window.

- `resizeAspect` and `resize`: the aspect-fit rectangle.
- `resizeAspectFill`: the larger aspect-fill rectangle, clipped by the view.
- Afterwards it restores the full-view frame. A gravity change during PiP is applied at once.
- A host that mounts `softwarePiPSource.layer` in its own view must size the layer to the picture itself.

**macOS.**

- The bound view also follows the system PiP window. It finds it through public AppKit: a new visible panel with the picture's aspect, when exactly one matches. The search stops after a few seconds. It runs again when the window goes away, or when the picture's aspect changes while no window was found.
- The layer is laid out at the window's size, so the layer's own `videoGravity` fits the picture. A window matched under a known aspect is kept through later aspect changes until PiP ends, and the layout follows its size as the window resizes to the new picture. Without a match, the picture-shaped layout stays.
- The system draws an opaque bar over the top of that window for sample-buffer sources, covering part of the picture. There is no public API to remove it or read its height (FB22411168).

### Upscale status

`$activeUpscale` is published on the first upscaled frame, not when the load decides the route. nil while no stage runs, and cleared with the session.

- **Republished with `degraded` true** when the stage keeps overrunning its frame budget, and a VideoToolbox + MetalFX stage drops MetalFX. Frames then go out at the VideoToolbox output size (`targetSize`), with the source's pixel aspect ratio.
  - The overrun is remembered for the process. A stage built later, whose MetalFX output is at least that large at a frame interval at least as short, starts degraded from the outset, without MetalFX. (Without a VideoToolbox pass it starts with `disabledReason` set instead.) It logs `[Upscale] starting ML only: ...`.
- **Republished with `disabledReason` set** if the stage cannot be built, or switches itself off: after repeated failures, or a sustained overrun when it has nothing left to drop. Frames are then delivered as decoded.

### Background behaviour

`retainsVideoPipelineWhenBackgrounded` (default false; set before backgrounding):

- By opting in, the host accepts that decoder sessions the system invalidated can still need `reloadAtCurrentPosition()`. In return it saves a rebuild when the pipeline survives.
- It does not enable background playback. A retained session that resumes while still in the background gets the playing-session policy at that point: teardown with background playback off, software audio-only.
- A seek or reload started from the retained pause postpones that decision until it settles, including a Play request that arrives meanwhile. A reload that stays paused keeps the retention.
- On play, failed software video queues are flushed before the feeder wakes; healthy buffered frames stay.

## Now Playing and the audio session

The engine can own the system Now-Playing card (lock screen, Control Center, the Apple TV overlay, the Mac's Now Playing widget) and the transport commands behind it, on every host and every platform. Each route is a separate opt-in; otherwise a host that builds its own card would get a second one.

| Symbol | Notes |
| --- | --- |
| `ownsAudioNowPlaying` | Card and commands for audio-only sessions, on both audio hosts. Off by default. See [Where the engine publishes](#where-the-engine-publishes). |
| `ownsVideoNowPlayingSession` | Card for the native **video** path. Off by default, on purpose: an `AVPlayerViewController` host already gets this from AVKit, and opting in costs it AVKit's card, its `externalMetadata` and its transport commands. Read at host creation, so set it before `load()`. |
| `ownsVideoNowPlayingCommands` | With `ownsVideoNowPlayingSession`, the engine also answers the transport commands for native video. Off by default, so hosts that register their own on `videoNowPlayingSession.remoteCommandCenter` keep working. |
| `ownsSoftwareNowPlaying`, `softwareNowPlayingActive` | Card and commands for the software host. See [Now Playing on the software host](#now-playing-on-the-software-host). |
| `remoteSkipInterval` | Skip distance (default 10 s) on every route the engine answers commands for. |
| `setNowPlayingInfo(_:)` | The item's identity (title, artist, album, artwork) for whichever route `load()` picks, on every platform. Elapsed, rate and duration come from the host; do not stage them. Pass an empty dictionary to clear. |
| `setVideoNowPlayingInfo(_:)`, `setAudioNowPlayingInfo(_:)` | The same, for the video or the audio routes only. The video identity is cleared by `stop()`, the audio one is not. |
| `setNowPlayingTrackCommands(next:previous:)` | Next and previous track handlers (a playlist or an album queue). nil for a direction that does not exist right now. While either is set the card shows track buttons instead of the skip pair. |
| `nowPlayingCommandInterceptor` | Optional. Sees every remote command first (a `NowPlayingRemoteCommand`: play, pause, toggle, skip, change position, next, previous); return true when the host handled it. Use it for commands whose meaning depends on host state, such as play after the end of an item. |
| `claimNowPlaying()` | Hands the shared surface to this engine when several engines publish there. See [Several engines in one process](#several-engines-in-one-process). |
| `videoNowPlayingSession`, `audioNowPlayingSession` | The `MPNowPlayingSession` of the native video host and of the AVPlayer audio host. Declared on iOS, tvOS and visionOS only: a macOS host does not see these two members. nil on the software and FFmpeg hosts, and with no host. |
| `setExternalMetadata(_:)` | AVKit's on-screen info pane on the video path. Also the base identity of a card the engine publishes on the shared center. Safe before `load()`; replayed at host creation. |
| `deactivatesAudioSessionOnStop` | Off by default. See [The audio session](#the-audio-session). |
| `rendererAudioSessionActivationEnabled` | Default `true`. See [Host-managed renderer audio activation](#host-managed-renderer-audio-activation). |
| `logTag` | A short name for this instance (`tile2`), carried by the `[SharedOutput]` lines and by a `[AetherEngine:<tag>] state=` line per transition. On a host that runs several engines at once, set it on every engine before `load()` (the tag is captured when the engine joins). |

A host that opts into everything needs no MediaPlayer code of its own:

```swift
engine.ownsAudioNowPlaying = true
engine.ownsSoftwareNowPlaying = true
engine.ownsVideoNowPlayingSession = true      // not with AVPlayerViewController
engine.ownsVideoNowPlayingCommands = true
engine.setNowPlayingInfo([
    MPMediaItemPropertyTitle: title,
    MPMediaItemPropertyArtist: artist,
    MPMediaItemPropertyArtwork: artwork,      // decoded up front, @Sendable request handler
])
engine.setNowPlayingTrackCommands(next: hasNext ? { queue.next() } : nil,
                                  previous: hasPrevious ? { queue.previous() } : nil)
try await engine.load(url: url)
```

**Do not write `MPNowPlayingInfoCenter` yourself on native video on tvOS 26.** Manual writes race the HLS-loopback path inside `libdispatch`.

- An `AVPlayerViewController` with its standard transport bar needs nothing: AVKit publishes the card through its private MediaRemote registration.
- A custom transport sets `ownsVideoNowPlayingSession` (and `ownsVideoNowPlayingCommands`) instead. The native host then binds its `MPNowPlayingSession` to the player, replays the identity from `setNowPlayingInfo(_:)` onto every fresh `AVPlayerItem`, and lets the session publish elapsed time, rate and duration. So nothing writes `MPNowPlayingInfoCenter.default().nowPlayingInfo` on this path.
- Never set the flag under AVKit. Two owners leave a half-working card: an empty identity replaces AVKit's, and remote commands go to a session with no handlers.

### Where the engine publishes

| Host | iOS, tvOS, visionOS | macOS |
| --- | --- | --- |
| Native video (`NativeAVPlayerHost`) | The host's `MPNowPlayingSession` publishes the card; with `ownsVideoNowPlayingCommands` the engine binds the commands on the session's center. | No session exists and a bare `AVPlayer` publishes nothing, so the engine writes the shared info center (commands with `ownsVideoNowPlayingCommands`). |
| AVPlayer audio (`AudioAVPlayerHost`) | The host's session publishes the card; with `ownsAudioNowPlaying` the engine binds the commands on its center. | Shared centers, card and commands. |
| FFmpeg audio (`AudioPlaybackHost`) | Shared centers, card and commands. | Same. |
| Software video (`SoftwarePlaybackHost`) | Shared centers, card and commands. | Same. |

On the shared centers the card is republished on state, rate, duration and buffering changes, and on a clock jump. In between, the system extrapolates elapsed time.

- A remote play reactivates the audio session first (iOS and tvOS, unless `rendererAudioSessionActivationEnabled` is off). The system may have deactivated it during the pause, and a player resumed on an inactive session stays silent.
- Every command the engine receives logs a `[NowPlaying] remote command` line.
- Between two items (the next track, a reload) the card stays on the shared center until the next item publishes over it, so it does not blink out. `stop()` clears it, and so does a load on a route the engine does not own.

**`audioNowPlayingSession` on the two audio-only hosts.**

- The AVPlayer host (`AudioAVPlayerHost`) always owns its session on iOS, tvOS and visionOS (there is no AVKit alternative there).
- The FFmpeg host (`AudioPlaybackHost`) has no session, so the property is nil there. With `ownsAudioNowPlaying` the engine publishes for it; without, the host drives Now Playing through the shared centers.
- The FFmpeg host serves: codecs off the AVPlayer whitelist, a custom `IOReader`, a FLAC under CoreMedia's block-size minimum, a FLAC whose frames are smaller than its `STREAMINFO` declares, any raw `.flac` file, and `preferredDecodePath = .software`.

### Several engines in one process

The shared centers exist once per process. Two engines publishing there at once would overwrite each other's card and both answer every command, so a toggle would fire twice and cancel itself. The engine that claimed last holds the surface:

- An engine claims when it starts playing, and when the host calls `claimNowPlaying()` (a player window becoming key, for instance).
- An engine whose route starts while another holds the surface waits behind it.
- When the holder stops, the most recent claimant still waiting takes over.

Routes published through an `MPNowPlayingSession` take no part: the system arbitrates between sessions, and each session has its own command center. A secondary `sharedOutputRole` never publishes at all.

### Now Playing on the software host

`ownsSoftwareNowPlaying` opts the software host (the Dolby Vision FEL route, which has no `AVPlayer`) into publishing its own Now-Playing card on the shared `MPNowPlayingInfoCenter` and serving play, pause, toggle, skip and change-position from `MPRemoteCommandCenter.shared()`.

- Off by default, and independent of `ownsVideoNowPlayingSession`, so the native path is untouched. A secondary role never takes it.
- Identity comes from `setExternalMetadata`, overlaid by `setNowPlayingInfo` (or `setVideoNowPlayingInfo`).
- `softwareNowPlayingActive` is true while the engine is publishing for the software host. It turns true once the engine's command targets are on `MPRemoteCommandCenter.shared()`, so a host may replace some of them from its observer. It is false while the engine waits behind another one for the shared surface, and turns false again when it loses the surface or stops.
- To answer a command yourself, `nowPlayingCommandInterceptor` is the simpler route: it sees each command before the engine and never fights over targets.

The centers are process-wide. The engine writes `MPNowPlayingInfoCenter.default()` and registers its own targets on `MPRemoteCommandCenter.shared()`, as it does on every shared route. At stop it:

- removes only those targets
- restores each command's `isEnabled` to its value before the session; a command another owner changed meanwhile keeps that owner's `isEnabled`
- clears the info and playback state only while the center still holds what the engine last published (matched on elapsed, rate, title and duration), so a host that took over meanwhile keeps its card
- touches next and previous only while the host has handed in track handlers, so a host that registers its own keeps them

### The audio session

**When the session is declared and activated.** The engine declares the category (`.playback`, mode `.moviePlayback`) and multichannel support off the main actor at the first load in the process, once, and does not activate the session there.

- **Route-sharing policy differs by platform (#116).** tvOS declares `.longFormAudio`, iOS declares `.default`. `.longFormAudio` marks the process as a long-form audio client. That pins `AVPictureInPictureController.isPictureInPicturePossible` to false for any PiP controller a host builds around the engine's player layer, which is why iOS does not use it. Hosts do not need to re-declare the session for PiP.
- **Why not at launch (#24).** Activating at launch pins the route to whatever the HDMI link reports at that moment. With tvOS Continuous Audio Connection off, the link idles at stereo. The route would be negotiated to 2 channels and stay there, downmixing non-Atmos multichannel for the whole session.
- **Who activates.** On the native video path the host's `AVPlayerViewController` activates the session per playback. The renderer paths (software decode, audio-only) activate it themselves, off the main actor and before their host is built (AE#538). A host that mounts the bare `AVPlayerLayer` (`nativePlayerLayer`) instead of an `AVPlayerViewController` must make sure the session is active at playback.
- **Stereo from the receiver.** An AVR that caches its HDMI EDID wrongly after standby can still report 2 channels and force a downmix. Power-cycling the receiver fixes it.
- **Atmos is unaffected** either way: E-AC-3 with JOC ships as MAT 2.0 over a 2-channel carrier.

**`deactivatesAudioSessionOnStop`** (off by default). The engine declares the audio-session category at the first load but never activates it on the native path. AVKit activates it per playback, and that is what lets tvOS negotiate the HDMI route (#24). So the engine never deactivates it either.

- Set it true only when the app owns the session outright. The engine then releases it on a genuine final teardown: `stop()`, never a reload, handoff or live retune.
- Final means `stop()` with its default `resetDisplayCriteria: true`, or any `stop(...)` with `finalTeardown: true`. A `stop(resetDisplayCriteria: false)` alone is a handoff and keeps the session; see [Loading](#loading).
- With several engines in one process, the last one to stop releases it. A stop while another engine is still active keeps the session and logs `[SharedOutput] ... still active, session kept`.

### Host-managed renderer audio activation

`rendererAudioSessionActivationEnabled` defaults to `true`. Set it to `false` before loading when the host decides which player is audible and owns `AVAudioSession.setActive(true)` across several players.

- Software and audio-renderer loads, track reloads and interruption recovery then skip the engine's own activation and channel preference changes.
- The host must activate the session before audible playback.
- The first load in the process still declares the category and multichannel support, off the main thread. That declaration is shared by concurrent engines and never repeated after it succeeds, so a host that changes the mode afterwards keeps its change.
- A session the host already put on `.playback` before that first load keeps its mode and policy.
- Native AVKit activation is unchanged.
- If the host also owns deactivation, leave `deactivatesAudioSessionOnStop` false (its default).

## Stills and thumbnails

Two families: cache-backed stills from the active session (no second connection), and `FrameExtractor` for stills off playback.

### Stills from the active session

| Symbol | Notes |
| --- | --- |
| `scrubThumbnail(atSeconds:maxWidth:)` | Cache-backed still for the active session, live or VOD. Decodes bytes the session already holds, so it opens no second connection. See note 1. |
| `vodScrubThumbnail(atSeconds:maxWidth:)`, `liveScrubThumbnail(atSessionSeconds:maxWidth:)` | The two variants, for callers that know which axis they hold. See note 2. |
| `supportsCacheBackedStills` | True while the session can serve `scrubThumbnail` without a second connection. See below. |
| `scrubPreviewFrame(atSeconds:refined:maxWidth:isCancelled:)` | The timestamped form of `scrubThumbnail`. See [Timestamped scrub frames](#timestamped-scrub-frames). |
| `scrubPreviewDrawsInView`, `showScrubPreview(atSeconds:in:)`, `AetherScrubPreviewView`, `ScrubPreviewPlacement` | The scrub preview for Dolby Vision without a displayable base layer. See [Scrub previews for Dolby Vision Profile 5](#scrub-previews-for-dolby-vision-profile-5). |
| `scrubPreviewSourceGeneration` | A fresh `UUID` on every teardown, distinct across engine instances, so a host can fence a preview that resolved after its source went away. |
| `clearResidentPreviewFrames()` | Cancels in-flight resident previews and drops their cached approximations; playback media is untouched. |
| `releaseScrubPreviewDecoders()` | Closes every still decoder and returns once they are closed. Call it when a scrub ends. Cached stills stay. See [Memory while scrubbing](#memory-while-scrubbing). |

1. **`scrubThumbnail`** works on single-connection sources where a second demuxer is refused (debrid / torrent links, IPTV accounts capped at one request). A native session decodes from its segment cache; a software session from its packet cache (VOD, AE#605) or its DVR packet ring (live, #544). A VOD target outside what is retained returns nil, not the nearest retained frame.
2. **The two variants** also serve software sessions. The live one reads the DVR packet ring (#544). The VOD one reads the packet cache its seeks land in (AE#605), from keyframe to target, on the same axis `seek(to:)` takes.

**`supportsCacheBackedStills`** is true for any native session, a software live session, a software VOD session reading a remote source, and one playing a local file. False before load.

- Show or hide the scrub-preview feature based on it. It reports capability, not whether a given frame is available. A brief nil from `scrubThumbnail` while a segment is still being produced, or for a position the cache does not hold, is expected and means "time only, no image".
- A software session playing a local file keeps no packet cache, so a `FrameExtractor` decodes its stills from the file. No connection is opened. `scrubPreviewFrame` honours `isCancelled` and the 750 ms / 900 packet bound, and reports the decoded frame's own time as `actualSeconds`. A Dolby Vision Profile 7 title shows its base layer. A file URL on a network mount opens a second file handle to that mount.
- A Dolby Vision Profile 5 / 10.0 source without the `DolbyVisionStillReshaping` trait reads false here; `scrubPreviewDrawsInView` is its preview.

### Timestamped scrub frames

`scrubPreviewFrame(atSeconds:refined:maxWidth:isCancelled:)` is for a preview that labels the frame it shows, not the position asked for.

- It reads only resident native segments or software packets. It never seeks playback, and never opens a second source.
- It returns a `ScrubFrame`: the image, the measured `actualSeconds` on the same axis `seek(to:)` takes, `refined`, and the resident `validRange` the frame's run covers.
- `refined: false` stops at the first decoded frame (cached per segment at the same width). `true` decodes toward the target. `refined` in the result means that decode reached the target, not that the two times are equal.
- Missing, cancelled, replaced or stale work returns nil.
- Decode is bounded at 750 ms and 900 packets per request.

### Memory while scrubbing

A still decoder costs memory in proportion to the video's size. On an Apple TV 4K one VideoToolbox decoder for 4K HEVC 10-bit holds 100 to 160 MB of reference frames, a 1080p one a quarter of that (AE#1059).

- The engine keeps up to six recent segments ready for stills. Their open decoders share a budget of six 1080p pictures, so a 1080p title keeps all six open and a 4K title keeps one. The others close down to their cached still, and a repeat request at the same width is still answered from that cache.
- Before a decoder opens, the older ones close, so the budget holds at the peak and not only after it.
- A resident segment's decoder closes by itself after 3 s without a request.
- Call `releaseScrubPreviewDecoders()` when the scrub ends to close the rest at once.

**The keyframe still ladder.** On a native VOD session, a position no resident segment covers is answered from the keyframe still ladder instead of nil. The ladder is a sparse set of keyframe stills the engine collects in the background.

- The engine builds it only while the origin is idle: no pump range open, nothing queued, no refusal in the last two minutes, at least 30 s buffered ahead, and at least 15 s into the session.
- It reads one keyframe every 2 s from the source: first one per minute across the whole title, then one every 30 s, nearest the playhead first. It uses the same per-origin request budget as the pump, so a plan that allows one connection never sees two at once.
- A ladder frame is the nearest step within 60 s (at or before the target, else after it) and is never refined. Its `actualSeconds` and `validRange` name that step's own segment, so a host can tell it from a frame at the target.
- The lookup itself never touches the source.

### Scrub previews for Dolby Vision Profile 5

This is the scrub preview for Dolby Vision without a displayable base layer (Profile 5, AV1 Profile 10.0) on a native VOD session. Its base layer is IPT-PQ, and no still API applies the RPU (the Dolby Vision metadata), so no `CGImage` of it can be correct. Only the system compositor colours it right.

- `scrubPreviewDrawsInView` is true for such a session in a build without the `DolbyVisionStillReshaping` trait. With the trait, the session serves reshaped stills through `scrubThumbnail` (and the still ladder and I-frame rendition), and `scrubPreviewDrawsInView` stays false.
- `showScrubPreview(atSeconds:in:)` takes the same playlist/output seconds as `scrubThumbnail`. It cuts the keyframe that opens the plan segment holding that time into a standalone one-sample fMP4. It then shows it in the `AetherScrubPreviewView`, through that view's own muted `AVPlayer`.
- **Inside the resident window** the keyframe comes from the segment cache, with no second connection.
- **Outside it**, the engine reads that keyframe from the source with a side demuxer of its own, as the I-frame rendition reads its entries (seek to the segment's start, one packet, nothing decoded). See the note below.
- The result is a `ScrubPreviewPlacement`: `actualSeconds` of the keyframe on screen and the `validRange` of its segment.
- On one view the latest request wins. The outgoing picture stays up until the next one can be displayed (two players alternate), so a superseded or failed request leaves the previous picture.
- Call `clear()` when the preview is hidden, which releases the view's decoders.
- Measured: 26 to 45 ms from request to picture on an M1 for a new segment, 1 ms for the one already shown, and a 4K preview next to 4K Profile 5 playback on an Apple TV 4K (3rd generation) without disturbing it.
- Never attach an `AVPlayerItemVideoOutput` to a player meant to show such a picture: AVFoundation switches the Dolby Vision processing off for the layer as soon as one is attached.

**The read outside the resident window.** The engine wraps the keyframe with the session's own sample entry, `dvcC` and `colr`. The result is byte-identical to the source's keyframe, and the same picture the cache would give.

- The read is withheld wherever the I-frame rendition would be: a plan whose boundaries are not keyframes; a sequential, serial or held-connection origin; a disc; a source that cannot be reopened by URL.
- It waits out a seek or producer restart, and skips a request a newer one has superseded.
- Those cases answer nil.

### `FrameExtractor`

`FrameExtractor` is an `actor` that takes stills off playback: `thumbnail(at:maxWidth:)`, `preview(at:maxWidth:)`, `snapshot(at:maxSize:)`, `prewarm()`, `shutdown()`. Create it over a URL with `init(url:httpHeaders:selectTitleID:yieldWhile:)` or over an `IOReader` with `init(reader:formatHint:yieldWhile:)`. It opens its own demuxer, so it needs a source that tolerates a second connection.

It never touches the playback pipeline, the HLS loopback server or the engine's shared state, so a scrub-preview decode cannot disturb the frame on screen.

- `makeFrameExtractor()` builds one for the loaded session. It is nil when nothing is loaded, or when a custom reader cannot give an independent clone.
- The engine does not retain it, so the caller owns its lifecycle.
- For an item with no session (a Recents row), create one directly.

```swift
let frames = engine.makeFrameExtractor()           // nil if nothing is loaded
// or, for an arbitrary item:
let frames = FrameExtractor(url: url, httpHeaders: headers)

await frames.prewarm()                             // optional: hide the cold start at gesture begin
let preview = await frames.thumbnail(at: 612.0)    // CGImage?, nearest keyframe
let still   = await frames.snapshot(at: 612.0)     // CGImage?, frame-accurate
await frames.shutdown()                            // prompt teardown of the decode context
```

**Lifecycle.**

- Blocking FFmpeg work runs on a dedicated serial queue, never on the cooperative thread pool.
- The decode context opens lazily on first use; `prewarm()` opens it early.
- Results land in a bounded LRU cache, thumbnails bucketed by second.
- After 10 s idle the context closes and the cache drops. The next request reopens lazily.
- `shutdown()` is the explicit, permanent teardown.

| Method (`FrameMode`) | What it returns |
| --- | --- |
| `thumbnail(at:maxWidth:)` (`FrameMode.thumbnail`) | The nearest keyframe, no forward decode, scaled to `maxWidth` (default 320). For scrub previews and Recents lists. |
| `preview(at:maxWidth:)` (`FrameMode.preview`) | Decodes forward to the requested time at `maxWidth`. |
| `snapshot(at:maxSize:)` (`FrameMode.snapshot`) | Decodes forward to the exact time, at native or `maxSize`-bounded dimensions. For user-triggered stills. |

- `maxSize` bounds apply after sample-aspect correction, so anamorphic stills fit both dimensions. HDR tone mapping uses the same square-pixel dimensions and native-width cap as SDR.
- Preview and snapshot decoding keep full reconstruction and bicubic scaling (HDR tone mapping included; the `DolbyVisionStillReshaping` converter still samples nearest-neighbour).
- Cache entries include the requested dimensions, so one extractor may serve several sizes. Thumbnails reuse their position bucket. Previews (with their own cache, bounded by count) and snapshots reuse only an identical requested time, so requests for neighbouring frames stay distinct.
- On uncached requests, previews step aside while `yieldWhile` reports that playback is starving. A newer extraction or `shutdown()` cancels them.
- This API uses the ordinary extraction cancellation and HTTP read timeouts. When the caller needs a total deadline of its own, use `boundedSnapshot`.

**`boundedSnapshot(at:maxSize:limits:cancellation:)`** is the single-use form. One `ProbeLimits` / `ProbeCancellation` budget from the caller covers open, stream analysis, seek and decode, a stalled HTTP header included. The result is a `BoundedStillFrame`. Use a fresh extractor: an already-open context is refused, not charged to the budget. The context closes on every outcome.

**One current request per extractor.** `FrameExtractor.thumbnail`, `preview`, `snapshot`, `boundedSnapshot` and resident previews share one current request per extractor.

- A valid request supersedes an older decode, even when the newer result is cached or yields to playback.
- Cancelling its awaiting Task cancels that request. A cancelled or superseded request returns nil instead of publishing a late image.
- Requests with invalid timestamps, and already-cancelled requests, do not replace another caller's work.
- Replacement across modes is intentional: even a cached ordinary or resident preview cancels an in-flight `boundedSnapshot` and the caller's `ProbeCancellation`. Use separate extractors for independent concurrent requests.
- Cancellation is checked between decode steps; a source read already in flight still runs to its normal timeout. For an explicit total deadline, use `boundedSnapshot`.
- After a cancellation or a yield to playback, idle cleanup of an opened context is still scheduled. A superseded completion cannot reset the newer request's idle timer.

## Certificate trust

Self-hosted media servers often sit behind a self-signed or private-CA certificate. URLSession refuses such a certificate; the network code inside the demuxer, which the engine replaced, never did. So a host whose own API layer bypasses trust ends up split: browsing works, and every engine fetch fails its handshake before a byte is read.

| Symbol | Notes |
| --- | --- |
| `EngineTLS` | Trust policy for the engine's outbound HTTP connections. Off by default: no evaluator is set and every challenge keeps the system's default handling. |
| `EngineTLS.serverTrustEvaluator` | `(@Sendable (URLProtectionSpace) -> Bool)?`, asked per challenge about the origin the challenge came from. nil, the default, keeps default handling everywhere. See the note below. |

**`serverTrustEvaluator`** is read per challenge, so replacing it applies from the next connection without rebuilding sessions. It is called off the main actor, from whichever queue raised the challenge, so it must be thread-safe.

```swift
EngineTLS.serverTrustEvaluator = { $0.host == "media.lan" }
```

It is a per-origin closure, not a flag. A host often has a LAN address behind a private certificate and a WAN address with a real one, and accepting the first must not quietly relax the second. A host that pins an SPKI hash reads the protection space and decides. Returning true for everything is the blunt version, in one line.

**Coverage.** This governs the sessions the engine owns. It also covers the one route where AVPlayer does its own networking. On native remote HLS the origin URL would go to `AVURLAsset`, which asks no delegate about the certificate and which an ATS exception does not reach. So the engine puts a loopback relay in front of the origin and makes the request itself.

- That happens only for an origin the system actually refuses. One handshake decides: an origin the system trusts is one AVPlayer reaches on its own.
- Media is relayed as it arrives, not read whole, so the player's first byte and its throughput estimate are the origin's, not the loopback's.
- Nothing about this is configurable: setting an evaluator is the whole opt-in.

A certificate the host does not accept still reaches the host as `PlaybackErrorKind.sourceCertificateRejected`, not as unreadable media, on the relayed route too.

## Diagnostics

| Symbol | Notes |
| --- | --- |
| `AetherEngine.version` | The engine release this source descends from, as the string a published tag carries. See note 1. |
| `diagnostics.liveTelemetry` | 1 Hz `LiveTelemetry?` snapshot while playing or paused, nil while idle. See [Live telemetry](#live-telemetry). |
| `LiveTelemetry.softwareCacheSeekHits`, `softwareCacheSeekMisses`, `softwareCacheSourceEpoch` | Optional cumulative counters of the software-VOD packet cache. `nil` on other paths. See note 2. |
| `LiveTelemetry.objectAudio` | An `ObjectAudioActivity` while `objectAudioRendering` plays TrueHD Atmos or DTS:X. See [Live telemetry](#live-telemetry). |
| `diagnostics.sessionCacheStatus` | The VOD session cache's budget and state. See [Session cache budget and status](#session-cache-budget-and-status). |
| `EngineLog.handler` | Mirror every info-level line into a host capture path. Fires on whatever thread emitted the line, so it must be thread-safe and non-blocking. |
| `EngineLog.structuredHandler` | `handler` with each line's `Category` and `Level` passed along (AE#897). For a log viewer that files or filters lines by subsystem. See note 3. |
| `EngineLog.subsystem`, `EngineLog.Category` | `de.superuser404.AetherEngine`, one category per subsystem: `engine`, `ffmpeg`, `session`, `muxer`, `demux`, `hls.server`, `audio.bridge`, `sw.playback`, `scrub`. These are the raw values Console.app filters on. In Swift, three cases are spelled differently: `.hlsServer`, `.audioBridge`, `.swPlayback`. |
| `EngineLog.Level` | `.info` reaches os_log and the host handler. `.verbose` is a per-segment trace and reaches os_log's debug level **only**, never the handler, so a mirrored stream stays readable. Read the verbose lines with `log stream --level debug`. |
| `EngineLog.registerSecret(_:)`, `EngineLog.unregisterSecret(_:)`, `EngineLog.redacted(_:)` | Name a value that must never be logged. See [Log redaction](#log-redaction). |
| `EngineLog.emit(_:category:level:)` | Emit a host line into the same stream, for a host that wants its own events interleaved with the engine's. |
| `segmentCacheDiskBytes`, `softwareHostFramesEnqueued` | Point reads for a stats overlay. |
| `activeProducerShiftSeconds`, `frameAhead`, `clockLeadSeconds` | Divergence diagnostics for tracing a clock that disagrees with the picture. Not for production playback logic. |
| `nativeItemReading()` -> `NativeItemReading?` | AE#509. The native item's own account of itself. See below. |

1. **`AetherEngine.version`.** SwiftPM resolves a package to a revision, not a tag, so an About panel or a diagnostic log header has nothing else to name the engine with. Between releases, and under a pin on an unreleased commit, it names the last published version the checkout descends from.
2. **Software cache counters.** A hit repositions the retained consumer cursor without changing the source epoch; a miss repositions the demuxer and advances the epoch. On software VOD, `cachedBytes` includes the retained compressed packet records. That is separate from the decoded `displayCushionSeconds` and from the underlying byte-reader window.
3. **`structuredHandler`.** Without it, a viewer has to guess from the `[Prefix]` at the start of the text, which is a convention, not API, and missing on some lines. It gets the same redacted lines, in the same order, with the same threading rules. It is independent of `handler`: install both and each gets every line. The level is always `.info` today, because `.verbose` never reaches a host handler.

**`nativeItemReading()`** returns:

- `playhead`: `AVPlayerItem.currentTime()`, on the ITEM axis
- `loadedRangeCount`: 0 means nothing has been PLACED yet, which no buffer depth can tell you
- `status`: 0 unknown, 1 ready, 2 failed

It is async and read off the main actor; nil when no native item is mounted. The engine's published clock is `item + playlistShiftSeconds`. On a live source whose encoder clock is hours in, the two are thousands of seconds apart in a healthy session, so quote both or neither.

### Live telemetry

`diagnostics.liveTelemetry` lives on a separate `ObservableObject`, so its ticks cannot re-render a host observing the engine.

**On the loopback and software routes**, `instantBitrateMbps` and `averageBitrateMbps` are the rate of the MEDIA played, not of the transfer (AE#514). They count the bytes of the video and audio packets the playhead crossed, over the media seconds it crossed: about the last 10 s for the first, the whole session for the second.

- Read-ahead, a re-fetch after a seek, and a paused live source filling its DVR window do not move them. Both stand still through a pause.
- The transfer rate is `networkThroughputMbps`.

**On `.remoteBypass`** it is fed from AVPlayer's access log alone:

- `instantBitrateMbps` and `averageBitrateMbps` are what the playing variant declares (BANDWIDTH, and AVERAGE-BANDWIDTH, or BANDWIDTH where the master omits it). The bytes AVPlayer transferred are buffer fill at link speed, not the stream's rate.
- `networkThroughputMbps` is the access log's `observedBitrate`.
- `networkTransferredBytes` and `droppedFrameCount` are its session totals.
- `forwardBufferSeconds` is the loaded range ahead of the playhead.
- `avSyncGapMs` and `observedFps` are nil.
- The loopback counters (`producerRestartCount`, `muxedBytesLifetime`, `serverBytesSentLifetime`, `serverRequestCount`, `demuxerBytesFetched`) read 0 because there is no loopback.

**The other fields**, one snapshot per second. On an optional field, nil means "cannot be measured on this route right now":

| Field | Unit and route |
| --- | --- |
| `audioBridgeBitrateMbps` | Mbps of the audio bridge's encoded output on the loopback route, measured from its byte counter (the FLAC bridge is lossless VBR and has no fixed rate). nil without a bridge (stream copy, AVPlayer-native audio) and before the first measurement interval. |
| `observedFps` | Frames per second presented. nil on native, where AVPlayer has no usable live counter. |
| `droppedFrameCount` | Frames the display dropped this session: the access log on native, the render synchronizer on software. nil where the OS has no `videoPerformanceMetrics`. |
| `forwardBufferSeconds` | Seconds of AVPlayer's loaded range ahead of the playhead. nil on software. |
| `displayCushionSeconds` | Seconds of decoded video queued ahead of the clock on software. Sub-second by design. nil on native. |
| `readerWindowAheadBytes` | Bytes the playback reader fetched that the demuxer has not consumed yet: the runway ahead of the read cursor. Both routes; nil for a disc or custom source. Divide by `averageBitrateMbps` for seconds. |
| `accumulatedFrameDelaySeconds` | Seconds of accumulated late-frame delay on software, cumulative for the session (difference two ticks for a rate). nil on native and before the first read. |
| `cachedBytes` | Compressed resident bytes: the software packet spool or the loopback segment cache. nil on every other route. |
| `avSyncGapMs` | The loopback producer's last audio/video gate gap, in source-clock ms. 0 before the first audio gate opens; nil on software. |
| `audioBridgeLiveBytes` | Bytes held inside the audio bridge right now (its FIFO plus resampler delay). 0 without a bridge. A leak shows as steady growth. |
| `rssMb` | The whole process's resident memory in MiB, not the engine's share. 0 when the read fails. |

**`LiveTelemetry.objectAudio`** is reported on the loopback route and on the software host alike. It is nil on every other audio path, and always nil in a build without the `TrueHDObjectAudio` / `DTSXObjectAudio` traits. It reports:

- `layout`: the bed the presentation is rendered into
- `objects`: the objects it declares
- `activeObjects`: how many of them its latest metadata update plays
- `elevatedObjects`: how many of those sit above ear level with elevation allowed
- `heightChannels`: its bed channels on height speakers (where DTS:X's standard presentation carries its four heights)

These are counted from the metadata, like the `bed levels` log line, so an active object can be silent. A seek sets the playing counts to zero until the decoder restates them.

### Log redaction

`EngineLog.registerSecret(_:)` names a value that must never be logged, such as an IPTV password the host holds. Every line that reaches os_log or the handler has it replaced, raw or percent-encoded, wherever it appears.

- The engine already strips on its own: named parameters, `Bearer` / `Basic` credentials, userinfo, encoded payloads and the Xtream Codes path layout, also inside a URL carried percent-encoded in another URL's query. This call covers what only the host can know, such as a provider URL carrying the password as a bare path segment.
- Registrations are counted: a value registered twice stays redacted until it is unregistered twice.
- Returns false for a value under four bytes.
- `redacted(_:)` returns a line as the handler would receive it, for a line a host or tool prints itself next to the engine's.

### Failed live starts

A failed live start keeps `PlaybackErrorKind.liveSourceUnavailable`, with its original URL error in `underlyingDomain` / `underlyingCode`.

- That cause is for diagnosis only. The reconnect ladder still tries to ride out a transport failure at open; the URL error is attached when the start finally gives up.
- HTTP refusals remain `sourceRefused` / `sourceRateLimited`, and TLS trust failures remain `sourceCertificateRejected`.
- Keeping a cause does not reclassify a dead live channel as a VOD `sourceOpenFailed`.
- `HLSIngestError.playlistUnreachable(status:)` also carries refused segment or AES key requests; its historical name and NSError case code are kept.

### Source network events

`SourceNetworkDiagnostics.handler` optionally observes real source-request events.

- It is a process-wide observer and runs on the thread that emits the event, so a host callback must be thread-safe and non-blocking.
- Events from players running at the same time can interleave. Filter by captured context or request identity, not by arrival order.
- Installing a handler does not change request or TLS policy.

**Event shape.** `SourceNetworkDiagnostics.Event` carries a per-request `requestID`, `role`, `phase`, status/URL error code, byte and timing metrics, and an optional `context`. All event fields are immutable. `SourceNetworkDiagnostics.Role` and `SourceNetworkDiagnostics.Phase` are string-backed structs with stable `rawValue` tokens, and `init(rawValue:)` for future values. Hosts should handle unknown values.

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

**Privacy.** Events contain no response bodies, header values or localized errors. Their `originalURL` and `url` are raw source URLs, for matching on the host side. The host must redact them before storing or forwarding them, and chooses its own logging and retention policy.

**Attributing requests to a playback.** Set `LoadOptions.sourceDiagnosticsContext` to a `SourceNetworkDiagnostics.Context(playbackID:attemptID:)` before `load()`.

- Both UUIDs are opaque identifiers the host owns. The engine does not create a host session, and never sends the identifiers in HTTP headers or URLs.
- The optional task-local `SourceNetworkDiagnostics.context` supplies the same context while a standalone `HLSLiveIngestReader(playlistURL:httpHeaders:diagnosticContext:)` or other instrumented reader is constructed. An explicit `diagnosticContext` picks that reader's context instead.
- AVIO readers capture it when created and pass it on explicitly to probes, ranged reads, reconnects, chunk fetches, streaming and tail prefetch, including requests started on detached or FFmpeg threads.
- HLS playlist, segment, key and carriage-probe requests capture their context when created and keep it through redirects and completion. They keep the source's context across internal reader reloads.
- A late event keeps the identifiers of the attempt that is going away.
- A request without context stays unattributed. A handler must not fill it in from whichever player happens to be active when it arrives.
- The context identifies the load: `reloadAtCurrentPosition(applying:)` refuses a changed context before teardown, so the running session and its attribution stay intact.

**The held HTTP/1 HLS transport** emits the same event contract:

- A streamed body emits `completed` only when it ends or fails, `body_limit_exceeded` when its bound is exceeded, and `abandoned` when the consumer drops or abandons it.
- The byte count excludes bytes discarded by a background drain.
- An open that fails after a response head arrived reports the hop that answered (the redirect target, not the original URL) and that head's status.

AVPlayer's own internal network requests are not exposed, and a source path without instrumentation or captured context cannot be attributed by this API.

### The `open timings` line

Every playback, probe and restart open logs one `[Demuxer] open timings (<reader>)` line in the `demux` category: `connect`, `open_input`, `find_stream_info` and `total` in ms, the stream count and the probe budget (`probesize N MiB, analyzeduration N s`).

An open that ran the stream analysis appends how it ended, after the budget:

`; probe stop=<resolved|probesize|analyzeduration|eof|read-error|stopped|interrupted>, unresolved=<n>, programs=<n>, pmtMissing=<n>, headerWait=<released@Nms|->, probeBytes=<n>, closeToReturn=<Nms|->`

- `stop` is the first cause that applies, in this order:
  - a close (`stopped`)
  - a probe limit or cancellation (`interrupted`)
  - a read error
  - the end of the input
  - every stream resolved with no header wait left (`resolved`). FFmpeg's own frame-rate and first-timestamp checks are not visible here, so a pass that spent its duration budget on those also reads `resolved`.
  - the byte budget
  - otherwise the duration budget
- `unresolved` counts the audio and video streams still missing their size, or their sample rate and channels.
- `pmtMissing` counts the MPEG-TS programs whose PMT never arrived, and `headerWait` says when the engine released the wait for one (see [A PAT program that never sends its PMT](formats.md#raw-live-mpeg-ts-and-the-live-join)).
- `probeBytes` is what the analysis read from the source, `closeToReturn` how long it took to end after a close.

A failed analysis adds `; find_stream_info failed (<code>)` after those fields. The line carries no URL, header or payload.

### Native video frame diagnostics and recovery

**`LoadOptions.nativeVideoFrameDiagnostics`** opts into decoded-frame observation on SDR native loopback playback. Default `false`.

- Excluded: remote bypass, HDR, external playback, mobile background activity, PiP (including its foreground transition), pause and seek.
- An extra `AVPlayerItemVideoOutput` samples frame timestamps, without suppressing the player layer or keeping pixel buffers.
- `EngineLog` reports output progress, gaps and resumption, and delays of the observing task.
- A gap in decoded output does not prove the screen froze. Unavailable output is reported as such. The observation never seeks, retries, changes decoder routing or publishes a playback error.

**`LoadOptions.nativeVideoFrameRecovery`** separately opts into a bounded recovery. It acts when an SDR native-loopback output that has shown pictures stops advancing while the item clock keeps running. Default `false`; turning on diagnostics alone does not turn this on.

- Recovery turns on the same sampling. It ignores unavailable or stale observations and the modes above, and uses the same bounded repair at the current position as missing-layer recovery.
- Short gaps are only observed. Recovery does not promise to rebuild source pictures that never arrived.
- It is re-armed by healthy decoded progress, not by a brief readiness flag after a swap.
- The `aetherctl play --native-video-frame-recovery` flag exercises the same policy.
- `ReplayVideoBoundary` logs counts of damaged, replaced and unreplaced pictures at confirmed seams, separately from the number of duplicates removed. `superseded` counts conflicting unflagged copies resolved within the verified pending batch. `untimed` counts unpositioned fragments discarded from the held damaged boundary. Unrelated source timestamp resets do not trigger this.

**Native presentation recovery** is also turned on by `nativeVideoFrameRecovery` (off by default). It watches the player layer's readiness.

- Suppose a video layer that was visible and attached stays unready, while foreground playback has both clock progress and buffered media. The engine first seeks to its current position, and can then replace the consumer item in place.
- It keeps the live source, the retained DVR and the current position. A live replacement waits when that position cannot be placed in retained media.
- Recovery is bounded, until a sustained healthy presentation re-arms it.
- Excluded: PiP, external playback, user pauses, seeks, hidden surfaces and buffering.
- `pictureInPictureActive` must be set before the PiP transition starts and cleared when it ends (also on a failed start). Otherwise an inline layer that is rightly unready could be treated as missing video.
- `EngineLog` reports readiness, buffer, PiP/foreground eligibility, and repair and resumption, separately from the optional decoded-output samples.

### Session cache budget and status

**The budget.** `LoadOptions.sessionCacheByteBudget` is an optional byte request for the temporary VOD cache.

- Nil keeps automatic sizing: the existing 2 GiB default (relaxed for an explicitly large forward window), the volume safety clamp, and the process-wide `RetentionClaims` allocation all stay in force.
- Explicit requests are nonnegative. They are clamped to a quarter of the capacity left after the other sessions' unwritten claims. Unknown capacity keeps the 2 GiB ceiling.
- Zero means "playback window only", not zero memory or zero disk I/O. Nothing outside the playback window is kept, and the producer pauses once it is 10 segments ahead. Any request the volume clamp reduces to zero behaves the same.
- The software disk path keeps a bounded working spool (its existing packet-retention mechanism, not the fMP4 segment window). The tvOS memory-store default and the live DVR retention policies are unchanged.

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
- The detailed snapshot describes fMP4 segment caching. Remote HLS is managed by AVPlayer and the server, so it reports unsupported, not a successful zero-byte cache. `nativeRemoteHLS(requestedBudgetBytes:)` builds that unsupported route state.
- Software packet storage keeps its own separate telemetry.
- Callbacks from an old session cannot replace a newer session's state.

**Direct `HLSVideoEngine` users** may call `sessionCacheStatus()` off the main thread, and receive lifecycle updates through `onSessionCacheStatusChanged`. `stop(reason:)` records the cleanup reason; the existing zero-argument `stop()` and its callback type remain available.

**Cost and cleanup.** The engine reads its in-memory byte count off the main thread at the existing telemetry rate, without listing files on the UI thread. A successful cleanup removes the whole session UUID directory. A bounded sweep at startup removes abandoned sibling directories that qualify. It never takes over their bytes, and it is no offline or cross-launch cache.

### Whole-session segment storage admission

Two opt-in options bound how much disk one session's segment cache may use. Both are off by default, and then nothing changes.

- **`LoadOptions.sessionCacheHardLimitBytes`** caps one VOD loopback session at that many bytes, resident segments plus the ones still being written ("staging"). `nil` keeps the old behaviour. Live sessions ignore it.
- **`LoadOptions.sessionCacheFreeReserveBytes`** keeps that many bytes of the volume free. The engine checks it before every segment write, with or without the cap, on VOD and on live. `0` turns it off.

Both are per session, not a process-wide total. Two players with a 256 MiB cap can use 512 MiB together.

**What the cap gives up.** To make room, the cap evicts backward history that the normal retention would keep, so a seek back there can restart the producer. After a seek back to a segment that is no longer cached, it may also evict the farthest forward segments AVPlayer already fetched, so the requested one can land.

**When a write does not fit.** A writer blocked by the cap waits for playback to move on. It stops waiting when the session is cancelled or closed. A segment larger than the cap, or a write the reserve refuses, ends playback with `PlaybackErrorKind.storageExhausted`. Cancelling does not. Another process can still fill the volume between the measurement and the write.

**Status fields.** `SessionCacheStatus` reports `hardLimitBytes`, `freeDiskReserveBytes`, `stagingBytes` and `rejectedDiskWrites`. `currentDiskBytes` is resident plus staging bytes, but staging is only counted while one of the two options is set, so with both off it equals the resident bytes. `diskAdmissionWaiting` is true while a writer waits for disk room. That is different from `producerParked`, which means the producer is waiting on the forward window.

### Per-frame benchmark

`AetherEngine.runPerFrameBenchmarks(iterations:width:height:)` times the software path's work around each decoded frame on the device it runs on, and returns a `PerFrameBenchmarkReport` (device, OS, picture size, one `PerFrameBenchmarkResult` per case with min, median, p95, p99 and max in microseconds). Both are `Codable`, so a report can be saved and compared with a later build: `report.regressions(against: baseline, tolerance: 0.2)` returns one `PerFrameBenchmarkRegression` (case `name`, `reason`) per case that got slower than the tolerance and `PerFrameBenchmarkReport.regressionFloorMicroseconds`, or that ran in the baseline and is skipped or missing now. It plays nothing and needs no session; call it on the main actor, away from playback, because it keeps the CPU and GPU busy for a few seconds. The cases and the regression rule are in [cli.md › bench](cli.md#bench).

## Optional components

Five parts of the engine are compiled only with their package trait, all off by default ([Installation › Optional components](installation.md#optional-components)). The options that ask for them stay in the API and do nothing without the trait. So a host compiles the same either way, and asks at run time whether a setting would do anything:

| Symbol | Notes |
| --- | --- |
| `AetherEngine.OptionalComponent` | `CaseIterable`. Cases: `.trueHDObjectAudio`, `.dtsxObjectAudio` (`objectAudioRendering` per codec), `.dualLayerDolbyVision` (`preferDualLayerDolbyVision`), `.dolbyVisionStillReshaping` (stills of Dolby Vision Profile 5 / AV1 Profile 10.0 sources), `.dolbyVisionFelCurves` (the FEL curve fold, below). |
| `OptionalComponent.isBuiltIn` | Whether this build carries the component. Fixed for the process; hide a toggle whose component reads false. |
| `OptionalComponent.traitName` | The package trait that compiles it, for a diagnostics screen. |

**`.dolbyVisionFelCurves`** folds a Profile 7 FEL source's enhancement layer into the Profile 8.1 RPU on the native route. The stream's mapping is kept, and its luma curve is lifted per scene.

- It is on whenever built in; `foldsDolbyVisionFEL` turns it off per load.
- It pauses on its own on a tvOS HDR10 panel without Dolby Vision.
- See [dolby-vision-fel.md §7](dolby-vision-fel.md#7-curve-fold-on-the-native-route).

**Without `DolbyVisionStillReshaping`**, a Profile 5 / 10.0 source yields no still instead of a wrong one. Its planes are IPT, which the standard path would read as YCbCr:

- `scrubThumbnail`, `scrubPreviewFrame` and the extractor's stills return nil
- `supportsCacheBackedStills` is false
- the I-frame rendition is absent (`dolbyVisionStillsNotBuiltIn`)
- an audio switch holds no picture

The session log says so once per session. Playback itself is unaffected.

## LoadOptions

All fields default to safe values; the tables below are the full set. Options with a longer contract have a details section after the tables. More depth on the media-related ones is in [formats.md](formats.md).

Every field is a `var`. All but three are also `init` parameters. The three exceptions are `sourceDiagnosticsContext`, `softwareDVRRetention` and `liveDVRByteBudget`: set them as properties after `LoadOptions(...)`.

A "tuning field" is one that `reloadAtCurrentPosition(applying:)` can correct on a running session. `isLive`, `audioOnly`, `nativeRemoteHLS`, `sequentialOrigin`, `sourceDiagnosticsContext`, `heldSourceConnection` and `sharedOutputRole` identify the session and cannot be corrected (see [Correcting a `LoadOption`](#correcting-a-loadoption-without-restarting-the-item)).

### Source and network

| Option | Default | What it does |
| --- | --- | --- |
| `httpHeaders` | empty | Extra headers on every probe, range and segment fetch. On `nativeRemoteHLS` they go into the `AVURLAsset`, so IPTV origins that check headers work. Same-origin sidecar subtitle fetches inherit them unless overridden (see [External subtitle request headers](#external-subtitle-request-headers)). **Scoping differs by route**: see [`httpHeaders` scoping](#httpheaders-scoping). |
| `sourceDiagnosticsContext` | nil | Optional opaque `SourceNetworkDiagnostics.Context`, kept by AVIO/HLS requests and internal reloads for host-side diagnostics. No effect on headers sent, request policy or playback. See [Source network events](#source-network-events). |
| `maxConcurrentSourceRequests` | nil | Most requests the reader may have open against this origin at once. See [`maxConcurrentSourceRequests`](#maxconcurrentsourcerequests). |
| `sourceOpenPolicy` | `SourceOpenPolicy()` | HTTP VOD opening budgets: `firstByteTimeout` (15 s) and `sizeProbeTimeout` (25 s). See [`sourceOpenPolicy`](#sourceopenpolicy). |
| `heldSourceConnection` | false | Ask the source **once** and pull it, instead of asking again every 8 to 16 MB of drain (AE#377). **Names the session.** See [`heldSourceConnection`](#heldsourceconnection). |
| `sequentialOrigin` | false | Declare an origin that fakes its range answers: one long-lived unranged GET, no ranged probes, a non-seekable byte source (pb). See [`sequentialOrigin`](#sequentialorigin). |
| `declaredDurationSeconds` | nil | Trusted duration, overriding the container's. Required together with `sequentialOrigin` on VOD, where the tail read is gone. |
| `probesize`, `maxAnalyzeDuration` | nil | Caller-bounded open-time probe budget (defaults 50 MB / 60 s). `probesize` is in bytes, `maxAnalyzeDuration` in **microseconds** (60 s is `60_000_000`). See the note below. |
| `skipsContainerAttachments` | false | Open a Matroska source without reading its attached files (AE#956). See [`skipsContainerAttachments`](#skipscontainerattachments). |

**`probesize`, `maxAnalyzeDuration`.** They fail **open** as long as some stream resolves: a budget that is too tight loads, with late-resolving tracks silently missing. If you tighten them, check that the tracks you need are there. A budget within which no stream resolves throws. Do not pass `0` for `maxAnalyzeDuration`; FFmpeg maps it to a shorter heuristic.

### Buffering and caching

| Option | Default | What it does |
| --- | --- | --- |
| `forwardBufferSegments` | nil (10, about 40 s) | How far the producer may run ahead, and how much the cache keeps resident. Clamped to 4...2700. Ignored on `nativeRemoteHLS`. See note 1. |
| `sessionCacheByteBudget` | nil | Optional byte request for the temporary VOD cache. See [Session cache budget and status](#session-cache-budget-and-status). |
| `sessionCacheHardLimitBytes` | nil | Opt-in per-session disk cap for resident plus staging bytes on VOD loopback. See [Whole-session segment storage admission](#whole-session-segment-storage-admission). |
| `sessionCacheFreeReserveBytes` | 0 | Opt-in free-volume reserve checked before segment writes; independent of the hard cap and also available to live sessions. See [Whole-session segment storage admission](#whole-session-segment-storage-admission). |
| `progressiveSegmentDelivery` | false | Serve each VOD loopback segment while it is being written. VOD only; ignored on live, `nativeRemoteHLS` and the software path. See note 2. |
| `softwarePacketCacheStorage` | `.automatic` | `SoftwarePacketCacheStorage` picks where seekable software VOD stores compressed packets. The choice survives session reloads. See note 3. |
| `generatesBackgroundScrubPreviews` | true | Build the sparse scrub-still ladder while the source is idle. Correctable through `reloadAtCurrentPosition(applying:)`. See note 4. |

1. **`forwardBufferSegments`.** Above the historical 150, the real bound is the session's disk budget, so a "buffer without limit" option can pass `Int.max`. Native HLS retention is readable as `$residentRanges` (see [Time](#time)). Software VOD applies the same forward-window and volume-budget policy to its compressed packet read-ahead. Its continuous selected A/V frontier is `bufferedPosition`, and its retained spans (including history and gaps) are `$residentRanges`.
2. **`progressiveSegmentDelivery`.** The muxer flushes a fragment about every half second, and the loopback server sends each one as it lands. So AVPlayer shows and starts on a segment's first fragments instead of waiting for the whole cut.
   - On a source fast enough to cut segments before AVPlayer asks, it changes nothing.
   - On a slow link it removes a whole segment's download from startup, and from a seek outside the buffer.
   - A segment the producer abandons (restart, failed cut) ends its connection without the final chunk, so AVPlayer asks for it again.
3. **`softwarePacketCacheStorage`.**
   - `automatic` keeps the defaults: purgeable memory on tvOS, disk on other platforms.
   - `disk` opts into temporary files, with the existing safeguards for the volume and the multi-session budget. Disk can compete with tvOS flash I/O; choosing it is no performance recommendation.
   - `memory` uses the existing bounded purgeable-memory store. Played history in memory may disappear and then need a source seek.
   - Local files that bypass packet caching, live DVR, and native HLS are unchanged.
4. **`generatesBackgroundScrubPreviews`.** Set false when the host shows no scrub previews; then no ladder step or ladder side reader is created. It is independent of `serveIFramePlaylist`. It does not turn off on-demand snapshots, held pictures across an item swap, or Dolby Vision compositor/reshaping. When true, all existing source eligibility and request-budget checks still apply.

### Live

| Option | Default | What it does |
| --- | --- | --- |
| `isLive` | false | Treat the source as live. Set it explicitly; duration-based auto-detection is too noisy. |
| `dvrWindowSeconds` | nil | Timeshift window. nil means live-only, and `seek` does nothing. The window is a ceiling, not a guarantee. See note 1. |
| `liveJoinProfile` | `.fastZap` | A `LiveJoinProfile`. `.fastZap` shrinks TARGETDURATION to the source GOP, plus headroom for one 1.5 x longer (AE#670), and bounds the first serve, so an IPTV join costs seconds instead of a full holdback. `.standard` always waits for the full `3 x TARGETDURATION` holdback (at least 18 s, 30 s on a 10 s GOP). See [Where a live start's seconds go](#where-a-live-starts-seconds-go). |
| `liveStartupGraceSeconds` | nil | `.fastZap` loopback live joins only: the extra wait before the first serve, once a finalized window qualifies. See note 2. |
| `liveStartupSingleSegmentMinimumSeconds` | nil | `.fastZap` only: lets ONE finalized segment at least this long qualify to start the session, instead of waiting for a second one. See note 3. |
| `liveDVRByteBudget` | nil | Disk budget in bytes for the software live DVR ring. nil keeps the default (a quarter of the free space, at most 2 GiB). Software route only. See note 4. |
| `softwareDVRRetention` | nil | Opts the software live spool into `SoftwareDVRRetentionOptions` (`startupMaximumBytes`, `playbackCushionBytes`, `playbackCushionSeconds`), and with that into `setSoftwareLiveDVRLimits`. nil keeps the default spool. |
| `clampsLiveResumeToWindow` | true | Whether `play()` may move a behind-live playhead by itself: a snap to the edge on a live-only source more than 45 s behind, or a landing above the retained floor when a DVR window has slid past it. `false` hands the whole decision to the host, which then also owns the eviction case. |
| `liveEdgeCushionSeconds` | nil | How far behind the live edge a live session plays, in seconds. See [`liveEdgeCushionSeconds`](#liveedgecushionseconds). |
| `liveJoinStartsImmediately` | true | Cuts AVPlayer's stall-avoidance wait short once at the live join, on an item that has reached `readyToPlay`, over a buffer that is non-empty and at least 1.5 s deep (AE#684). No host can reach this join wait otherwise. See [The tail after the first serve](#the-tail-after-the-first-serve-and-which-signal-survives-it). |
| `liveBlockingReload` | nil (auto) | LL-HLS blocking-reload override for loopback live sessions. Auto decides from the observed upstream cadence, which is what keeps a bursty relay out of a `-15410` loop. |
| `nativeRemoteHLS` | false | Hand a remote `master.m3u8` straight to AVPlayer: no demuxer probe, no loopback. Built for `isLive: true`; a remote HLS VOD URL reaches this route anyway (AE#154). The clock here is item time; see `clock.$sourceTime` (AE#616). |
| `nativeRemoteHLSIngestFallback` | true | The #168 / #293 carriage recovery and the #363 recovery after a 401/403 refusal on the bypass. Setting it false turns both off. |
| `hostRetriesExhaustedLiveReplay` | `false` | The host owns the retry after a verified live replay exhausts the in-engine reopen: the engine publishes `liveSourceReplayExhausted` and holds production until `retryLiveSourceRecovery()`. `false` publishes `liveSourceReset` for the same exhaustion. |

1. **`dvrWindowSeconds`.** The disk budget bounds what is actually kept: a quarter of the free space, at most 2 GiB unless `liveDVRByteBudget` lifts it on the software route. So a long window on a high-bitrate channel, or on a small volume, holds less than it asks for. With several engines running, each one's quarter comes from the free space the others have not claimed yet, so a tile added on a tight volume holds less history than the first one (AE#687).
2. **`liveStartupGraceSeconds`.** nil uses the observed segment duration, clamped to 0.5 to 2 s. 0 serves (admits) as soon as the minimum media exists. nil or invalid values keep the automatic policy. The existing manifest deadline still bounds it. A shorter grace can rebuffer early on an irregular source.
3. **`liveStartupSingleSegmentMinimumSeconds`.** On a long-GOP source, a second segment is another whole GOP of waiting. nil, nonpositive or non-finite values keep the two-segment minimum. A shallow first playlist can rebuffer if the next segment is late; that trade-off is the host's. `Scripts/test-long-gop-startup.sh` exercises it against paced long-GOP MPEG-TS on macOS AVPlayer.
4. **`liveDVRByteBudget`.** An explicit value replaces the 2 GiB cap, for a window that has to hold hours of broadcast, such as a recording still in progress fed in as a live source. It is still clamped to a quarter of the free space the other sessions have not claimed, and never goes below the ring's 64 MiB playback minimum.

Neither live startup option (`liveStartupGraceSeconds`, `liveStartupSingleSegmentMinimumSeconds`) changes segment cuts, TARGETDURATION, HOLD-BACK, `.standard` joins or the remote HLS bypass, and explicit holdback floors and cancellation still win.

### Audio

| Option | Default | What it does |
| --- | --- | --- |
| `audioOnly` | false | Lean audio pipeline, no video machinery. Also set automatically when the probe finds no video stream. |
| `audioBridgeMode` | `.surroundCompat` | Bridge encoder for codecs that cannot be stream-copied into fMP4. `.surroundCompat` uses EAC3 for a source with more than two channels, and FLAC for two or fewer (no surround to carry). `.lossless` uses FLAC up to 7.1 throughout and needs a sink that accepts multichannel LPCM. |
| `objectAudioRendering` | `.off` | TrueHD Atmos and DTS:X with heights (#731), in a build with the object-audio traits. See [`objectAudioRendering`](#objectaudiorendering). |
| `rendersDTSXObjectAudio` | true | `false` keeps DTS:X on the channel bridge while `objectAudioRendering` still renders TrueHD Atmos (#1060). See [`objectAudioRendering`](#objectaudiorendering). |
| `confirmAtmos` | false | Confirms JOC per track in the background, and republishes `audioTracks` as tracks are confirmed. Never on the start path; skipped for live and forward-only readers. |
| `preferredAudioLanguages` | empty | Audio pick for the first frame, from the engine's single probe. Ordered BCP-47 / ISO 639 tags; region and script are normalized and rank within one preference (#590). An explicit `audioSourceStreamIndex` still wins. |
| `audioShaping` | `AudioShaping()` | Start the session with audio shaping in force (AE#923). Same value `setAudioShaping(_:)` reads and writes. |
| `audioDelaySeconds` | 0 | Start the session with a lip-sync offset already in force; positive presents audio later. Same value `setAudioDelay(_:)` reads and writes, and a `reloadAtCurrentPosition(applying:)` can correct it. |

### Subtitles and scrubbing

| Option | Default | What it does |
| --- | --- | --- |
| `preferredSubtitleLanguages` | empty | Turns on a subtitle after load, on the host-overlay path. Ranks how specifically the language matches (an explicitly opposite script is rejected, not demoted) before the descriptor. Pure convenience: unlike the audio equivalent, no reload and no extra probe. |
| `externalSubtitles` | empty | Sidecar files registered at load, so they rank in the language preference and can join the native renditions. |
| `initialSubtitleTrackID` | nil | Turns on a subtitle after load by `TrackInfo.id`, for a host that already knows the track, such as a server's default. The id is an embedded stream index, or `externalSubtitleTrackIDBase` plus the index in `externalSubtitles`. Wins over `preferredSubtitleLanguages`; an id that names no track falls back to it instead of failing the load. |
| `prepareNativeSubtitles` | false | Declare WebVTT renditions so subtitles survive PiP / AirPlay / external display. |
| `eagerNativeSubtitleReaders` | false | Populate those renditions at load instead of on first selection, for playlists AVKit auto-selects. Only meaningful with `prepareNativeSubtitles`. |
| `nativeAudioTrackMenu` | false | List every audio track in the master so a stock `AVPlayerViewController` offers them all in its audio menu; a pick switches through `selectAudioTrack`. See [Formats › Every audio track in AVKit's audio menu](formats.md#every-audio-track-in-avkits-audio-menu). |
| `nativeSubtitlePreferredLanguages` | empty | Which rendition is marked `DEFAULT=YES`. Resolved by the same BCP-47 matching as the overlay pick, so inline and PiP / AirPlay agree (#590). Read back as `nativeSubtitleDefaultOrdinal`. It does not turn on the overlay path, so subtitles cannot show twice next to the native render. |
| `preserveASSMarkup` | false | Emit raw ASS event lines instead of extracted text; pair with `TrackInfo.assHeader`. ASS / SSA codecs only, embedded and sidecar alike, so a session mixing an ASS track with a SubRip one switches between them without a reload (AE#587). |
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
| `dolbyVisionHandling` | `.automatic` | A `DolbyVisionHandling`. `.baseLayerOnly` presents the HDR10 / HLG base layer of a Dolby Vision source, and leaves Dolby Vision out of the container on every display. See [`dolbyVisionHandling`](#dolbyvisionhandling). |
| `forceDolbyVisionOnNonDVDisplay` | false | **Experimental (AE#455).** Serve an HEVC Profile 8.1 source as Profile 5 on a display with no Dolby Vision of its own. See [`forceDolbyVisionOnNonDVDisplay`](#forcedolbyvisiononnondvdisplay). |
| `preferDualLayerDolbyVision` | false | Opt in to composing Profile 7 FEL sources on the GPU. Not recommended for a distributed app. See [`preferDualLayerDolbyVision`](#preferduallayerdolbyvision). |
| `foldsDolbyVisionFEL` | true | With the `DolbyVisionFelCurves` trait: fold a Profile 7 FEL source's enhancement layer into the Profile 8.1 RPU's luma curve. False keeps the plain conversion and its start speed (#1018). Ignored without the trait. See [dolby-vision-fel.md §7](dolby-vision-fel.md#7-curve-fold-on-the-native-route). |
| `dualLayerRoute` | `DualLayerRoute.softwareHost` | Which route composes a Profile 7 FEL picture once `preferDualLayerDolbyVision` has taken the dual-layer route. See [`dualLayerRoute`](#duallayerroute). |

### Decode and routing

| Option | Default | What it does |
| --- | --- | --- |
| `preferredDecodePath` | `.automatic` | A `DecodePath`. `.software` serves this source through `SoftwarePlaybackHost`, whatever the routing concluded. One-way: there is no `.native`. See the note below and [Overriding the decode path](#overriding-the-decode-path). |
| `escalatesToSoftwarePath` | `true` | Whether a failing native session may be rebuilt once on the software path (AE#561). `false` surfaces the failure as `.error` instead, for a host with its own fallback ladder (AE#629). Correctable. See the note below. |
| `upscalesLowResolutionVideo` | false | Opt in to upscaling SDR video below 1080p to the display's native pixel size (#846). See [`upscalesLowResolutionVideo`](#upscaleslowresolutionvideo). |
| `upscaleScaler` | `.automatic` | The scaler that upscale stage runs. `.lineArt` is a 2x line-art network for animation that also takes 1080p and 10-bit SDR (AE#1039). See [`upscaleScaler`](#upscalescaler). |
| `deinterlaceMode` | `.auto` | A `DeinterlaceMode` for the software path: the Metal / VideoToolbox graph with a CPU bwdif fallback, or `.software` to force the CPU path. |
| `deinterlaceFieldRate` | `.field` | A `DeinterlaceFieldRate`: the hardware deinterlacer emits one frame per field (25i to 50p) or one per frame. The software fallback always runs at frame rate: doubling a CPU bwdif is the wrong trade, and a fallback should not jump to a higher cost. |
| `nativeVideoFrameDiagnostics` | false | Decoded-frame observation on SDR native loopback playback. See [Native video frame diagnostics and recovery](#native-video-frame-diagnostics-and-recovery). |
| `nativeVideoFrameRecovery` | false | Bounded recovery when native output stops advancing. See [Native video frame diagnostics and recovery](#native-video-frame-diagnostics-and-recovery). |

- **`preferredDecodePath`.** The override applies to this session only and costs the source nothing: seeks, the audio switch and the title switch all keep working. It is the way out for the formats `VTCapabilityProbe` deliberately cannot classify, and for live H.264 / HEVC, which never reaches that check at all. On an `audioOnly` session it sends the audio to the FFmpeg host instead of AVPlayer.
- **`escalatesToSoftwarePath`** covers two cases: a native session AVPlayer refuses over the media itself (`CoreMediaErrorDomain`), and a live join without an entry point the native route can open (`AetherEngine.LiveJoin`, AE#627).

### Session

| Option | Default | What it does |
| --- | --- | --- |
| `sharedOutputRole` | `.primary` | A `SharedOutputRole`: `.primary` or `.secondary`. A secondary engine never writes display criteria and never owns Now Playing. **Names the session.** See [Running several engines at once](#running-several-engines-at-once). |
| `autoplay` | true | False mounts paused: the load skips the terminal `play()` and settles at `.paused`, for a host that resumes later. See [`autoplay`](#autoplay). |

### Option details

#### `httpHeaders` scoping

- **On the plain `nativeRemoteHLS` bypass**, AVFoundation itself sends the headers to every host the playlists name (variants on other hosts, segments and `EXT-X-KEY` URIs), and carries them across 302 redirects. So credential headers there reach every such host, and the engine cannot narrow that. A credential that must not reach every host a playlist names should not go in `httpHeaders` on the bypass.
- **On the routes the engine fetches itself**, the per-origin credential scoping described for `HLSLiveIngestReader` applies: the ingest, the disc reader, the origin relay, the subtitle proxy, the audio tap and the live subtitle renditions.

#### `maxConcurrentSourceRequests`

The most requests the reader may have open against this origin at once. It counts every path the reader fetches on: pump ranges, detour blocks, size probes, tail prefetch, the subtitle side reader, and the HLS live ingest's playlist, segment and key fetches (whose prefetch window shrinks to it, AE#678).

- nil counts without capping, and lowers the ceiling by itself after a 429/503/509.
- Set it when the provider states a limit. `1` also turns off the speculative parallel paths, which exist only to overlap with the pump.
- It counts **requests**, not TCP connections. Over HTTP/2 a session carries every request on one connection, but the origin still counts each one (AE#377).
- It is also the only ceiling. Several engines playing from one origin are bounded by this value and by what the origin refuses, not by a transport pool underneath (AE#450).

#### `sourceOpenPolicy`

HTTP VOD opening budgets for the playback reader and its reopens.

- `firstByteTimeout` (15 s) bounds the wait for the first data.
- `sizeProbeTimeout` (25 s) bounds the one retry and the whole size discovery, slot waits included.
- Nonpositive or non-finite values take the defaults; anything above 120 s is capped.
- A request that gets no response is retried once with an open-ended Range, and that connection stays the playback connection. Two unanswered requests fail as `.sourceOpenFailed`, instead of demoting the source to forward-only.
- A response that really has no length, or ignores Range, keeps the ordinary sequential handling.
- Origins that allow a single request run the size probes one after another. Others run them in parallel and wait for the slower ones before playback starts.
- When an open drops a failed ranged connection and switches to forward-only playback, the dropped connection's transport error cannot fail the replacement. A refusal or transport failure from the replacement itself still reaches the host.
- Live, `sequentialOrigin`, remote HLS and disposable probes keep their own budgets.

#### `heldSourceConnection`

Ask the source **once** and keep pulling from that connection (AE#377). Without it, the reader ends the connection when its window is full and asks again every 8 to 16 MB of drain.

**When to use it.** For an origin that punishes repeated requests, not concurrency. Some CDNs refuse new requests for minutes at a time, while serving an already open connection at full rate. Against those, the number of requests is the problem, at any range size. Measured at the reporting origin: raising 32 MB ranges to 256 MB made eight times fewer requests, and the refusals stayed the same. `maxConcurrentSourceRequests` bounds how many requests are in flight; this option removes the second request.

**Limits.** The read path is the engine's own HTTP/1.1 over a demand-driven stream task, so:

- **HTTP/1.1 only** (no ALPN; an HTTP/2-only origin is out of scope)
- the **system proxy configuration does not apply**
- TLS is the OS's, through the same host trust decision as every other engine session, but it has not been tested against a self-signed origin

**Behaviour.**

- When the viewer pauses, the connection ends after five seconds; resuming costs one request where the read stopped. A held connection nobody reads would cause the process-wide Network.framework starvation of AE#310.
- It applies to the playback reader. The subtitle and enrichment side readers keep the default transport, because they sit idle for minutes at a time.
- The open-time check for an origin that ignores `Range` (see `sequentialOrigin`) does not cover it, because its open is open-ended.
- **Names the session**: the transport is chosen at open, so a reload that changes it is refused.

**HLS VOD (AE#732).** A finite HLS VOD on the HEVC-in-MPEG-TS ingest (AE#268) is covered too. Playlist, key and segment requests run over one persistent HTTP/1.1 connection per origin, reused across segments, one request at a time. This is for origins that refuse h2 or new connections but serve consecutive requests on one keep-alive connection.

- Each body is streamed into the ingest as it arrives.
- When the FIFO is full, the current body may finish, but no next segment or key request starts until playback makes room. Seek, close or cancellation ends that wait.
- Only the wait for a response head has a wall-clock ceiling (45 s). A body ends on its size limit or after 30 s without a byte, never because of its duration.
- A new connection opens only on a server close, an origin change, or a seek that abandons a body with more than 2 MB left, or one too slow to arrive within 3 s. Otherwise the rest is drained and the connection kept, and the next request waits for it.
- The log names each connection's protocol and request count.

#### `sequentialOrigin`

Declares an origin that fakes its range answers: one long-lived unranged GET, no ranged probes, a non-seekable byte source (pb). Requires `declaredDurationSeconds` on VOD. `$isSequentialOrigin` reports whether a session is served this way, declared or found by the reader.

**What the host must do.** A host that needs a position this session cannot reach reopens the source (an IPTV archive at a shifted start) or tells the user. An audio switch is a fresh `load` at the position with `audioSourceStreamIndex`.

- **The session plays from the start**, so a `startPosition` given to `load()` is not honoured.
- **Seeking outside what the session holds is unavailable.** On the loopback route, a target inside the `$residentRanges` span that reaches the producer's current end (the last span) lands from the segment cache. Any other target, and every seek on the software host, is rejected as `.sourceNotSeekable`; the host re-requests the archive at a shifted start (AE#958). `canSeek` stays false, so a host offering in-cache seeks checks `residentRanges` itself.
- **`selectAudioTrack` is ignored**, because it could only reopen at byte 0.
- The first append playlist waits for more media than AVPlayer's first reload interval (one `TARGETDURATION`), at most 2 s past the first segment.
- An AirPlay hop on such a session moves the item onto the LAN address instead of reopening the source, since a reopen could only start again from byte 0.

**Found without the declaration.** The reader may find a URL source forward-only by itself: the origin ignores `Range`, or refused the ranged open twice and served a plain GET (AE#693). If its container states a duration, it is served this way without the declaration.

- For an MPEG-TS source, a stated `Content-Length` allows estimating a duration.
- The open confirms a 200 answer with a one-byte range, because some CDNs answer a cache miss that way.
- `loadedOptions` then reads `true`, with that duration declared.
- Without a duration it stays on the software path.

**Caught when undeclared.** An undeclared origin that fakes ranges is caught at the first ranged reconnect that starts inside bytes the reader already holds: it asks for 4 KB early and compares them. The session fails as `.sourceFabricatesRanges` before any of that body is played (AE#958).

#### `skipsContainerAttachments`

Matroska carries the fonts of its ASS subtitles as attachments, tens of megabytes on anime releases. The demuxer reads all of them while the file opens, before the first packet. Over a slow origin that is most of the startup time.

- With this on, the open skips them (FFmpegBuild's `skip_attachments` matroska option). `fontAttachments` stays empty, and a Matroska cover image is not reported in `metadata`. Tracks, their indices and packets are unchanged.
- It suits a host that renders text subtitles itself, or does without the embedded fonts. A host that renders ASS with them (see [formats.md › Authored ASS styling](formats.md#authored-ass-styling)) leaves it off.
- Other containers are unaffected.
- Only the session's first open reads attachments either way. The side readers (embedded subtitles, scrub stills, I-frames, the Atmos and Dolby Vision passes) and the reopens of the same source always skip them.
- Correctable through `reloadAtCurrentPosition(applying:)` on a URL source, which re-runs `load()`.
- `AetherEngine.probe(...)` honours it too (AE#1029). Without it, a probe of a Matroska file pays for the whole attachment set, so a probe under a `ProbeLimits.maxInputBytes` smaller than the fonts stops with `ProbeError.inputLimit` instead of answering from the header. With it, `SourceProbe.metadata` has no Matroska cover image.

#### `liveEdgeCushionSeconds`

How far behind the live edge a live session plays, in seconds. It is the buffer a viewer on a slow or unsteady link has against the channel (other players call it "buffer duration" for IPTV).

- It only ever moves the playhead further back than the path's own safe distance, clamped to `LiveEdgePolicy.maximumEdgeCushionSeconds` (45 s).
- The join waits until that much media is available behind the newest. A live HLS origin's listed backlog fills it at link speed (the ingest joins deep enough). A raw MPEG-TS channel fills it only at real-time speed (1x) after its connect burst.
- A session holding the cushion reads `isAtLiveEdge`.
- It cannot help a link slower than the channel's bitrate.

Per route:

- **Loopback:** raises the served `HOLD-BACK` and the first-serve gate, sets the minimum for `.fastZap`'s bounded start, and extends the first-serve deadline. The gate is waited out before the item is attached, so AVPlayer's playlist timer (about 20 s on tvOS) never runs during it (AE#851).
- **Software path:** sets the join lead, the landing holdback, and the cushion a rebuffer refills before resuming. Without `dvrWindowSeconds` the host keeps a packet ring that deep but still publishes no rewind window, so seeks stay refused.
- **`nativeRemoteHLS`:** sets `AVPlayerItem.configuredTimeOffsetFromLive`, kept across stalls and never below the origin's `recommendedTimeOffsetFromLive`.

#### `objectAudioRendering`

Renders TrueHD Atmos and DTS:X with heights (#731). Needs a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default, [Installation › Optional components](installation.md#optional-components)).

- Without a codec's trait, the option is accepted, but that codec keeps `audioBridgeMode` (the channel bridge), and the automatic audio pick does not prefer it.
- `AetherEngine.OptionalComponent` tells a host which codecs a build renders.

**Values.**

- `.render(SpatialSpeakerLayout)` builds that bed from TrueHD Atmos's lossless channel presentation steered by its objects, or routes DTS:X's heights into it (`.l512`, `.l514`, `.l712`, `.l714`, `.l916`). It delivers the bed in the form the output route carries, chosen at load:
  - 24-bit PCM (`ipcm` over HLS, 1.15 Mbit/s per bed channel, the rendered bed bit for bit), unless the route plays over AirPlay (an AirPlay port in the session's route; on macOS an AirPlay default output device)
  - then Apple Positional Audio (lossy, 320 kbps per bed channel)
- `.apac(SpatialSpeakerLayout)` and `.lpcm(SpatialSpeakerLayout)` force one form.
- `SpatialSpeaker` names the positions.

tvOS sends either form to an Atmos receiver as Dolby MAT, and iOS plays either as Spatial Audio. The rendered bed replaces the lossless 7.1 the bridge would deliver, so it is the host's choice.

**Which sources.** At 48 kHz, on OS 26+, only these:

- TrueHD that FFmpeg marks Atmos
- DTS-HD Master Audio whose first frames decode as DTS:X, whatever FFmpeg's label. DTS:X renders into `.l714` or `.l916`, and a smaller layout gets `.l714` (the receiver maps it onto its speakers).

Anything else, or any failure to start, keeps `audioBridgeMode` (on the software host, the PCM decode).

**Software host.** It honours the option too, on VOD sessions.

- TrueHD Atmos and DTS:X are rendered for the sample-buffer audio renderer, as PCM or APAC by the same rule.
- An E-AC-3 JOC track (6 channels, 48 kHz) is handed to the renderer still compressed, once the system's Atmos decoder is registered in the process. So its objects survive, not just the channel-bed core.

**Automatic audio pick.** With the option on, the automatic pick prefers a track labelled TrueHD Atmos or DTS:X over the other tracks of the same language. "The same language" is that of the `preferredAudioLanguages` match; or of the default track when no preference decides; or every track when no audio track is tagged at all.

- It never prefers across a language or dub, and never over an explicit `audioSourceStreamIndex`.
- It only applies where the bed can be rendered: a VOD video session, on the loopback route or the software host, on OS 26 or later.

**Keeping DTS:X on the bridge.** `rendersDTSXObjectAudio = false` keeps every DTS track of the load on `audioBridgeMode`, while TrueHD Atmos still renders into the asked layout (#1060).

- Use it when TrueHD Atmos should go into a small bed (5.1.2, say) but DTS:X should stay on the 7.1 bridge instead of becoming 7.1.4.
- It holds for the whole load, so a viewer switching between a TrueHD Atmos track and a DTS-HD MA track needs no reload, and the host does not have to know before the first frame whether a DTS-HD MA track carries X.
- The automatic audio pick then does not prefer a DTS:X track.
- The default, `true`, renders both codecs as before. A `reloadAtCurrentPosition(applying:)` can change it.

See [formats.md](formats.md#truehd-atmos-with-heights) and [DTS:X](formats.md#dtsx-with-heights).

#### `serveIFramePlaylist`

Serves an I-frame rendition next to the master, so a stock `AVPlayerViewController` shows scrub thumbnails and scans on I-frames with no host code. Hosts with their own transport bar use `scrubThumbnail` instead.

- One still per segment. An SDR source gets its own keyframes at full resolution. An HDR10, HLG or Dolby Vision source gets tone-mapped 640-pixel Motion JPEG stills, because AVKit shows no scrub thumbnail from a PQ or Dolby Vision keyframe.
- Opens a second reader on the source.
- It is absent in these cases, and one log line says why:
  - live
  - sources whose segment boundaries are not keyframes (`planNotKeyframeAligned`)
  - `sequentialOrigin`, `heldSourceConnection`, single-request origins, discs
  - a custom `IOReader` whose `makeIndependentReader()` returns nil, so there is no second reader for the stills (`noSecondReader`)
  - media-playlist routing. The usual case is an HDR10, HLG or Dolby Vision title on an output that is not presenting HDR, such as an Apple TV locked to SDR, where AVFoundation accepts no master form for PQ content (AE#682).
  - a Dolby Vision Profile 5 / 10.0 source in a build without the `DolbyVisionStillReshaping` trait

#### Display criteria

`displayCriteriaOwner` says who writes `preferredDisplayCriteria` (AE#842):

| Value | Meaning |
| --- | --- |
| `.engine` | Writes range and rate before the item loads, and defers to `suppressDisplayCriteria`. |
| `.avKit` | AVKit's write from the item. |
| `.host` | A host that writes its own criteria before `load()`, or none, so the panel stays in the output format chosen in tvOS Settings (a Dynamic Range "System" setting). See the note below. |

- **`.host`.** The engine never writes, and clears only criteria it left applied itself. It uses the brief play-gate budget instead of AVKit's one second, reads the panel as on its own path, and still waits out a switch it sees running.
- `.avKit` and `.host` win over `suppressDisplayCriteria`. A `.secondary` engine never writes.

**`suppressDisplayCriteria`.** The engine writes no display criteria because AVKit does (`AVPlayerViewController.appliesPreferredDisplayCriteriaAutomatically`). It is the older spelling of `displayCriteriaOwner = .avKit`, and the setting for previews and headless runs.

- On HDR and Dolby Vision content, the play gate waits up to a second for AVKit's write, and the panel readout is skipped. A host that keeps the panel in its system format wants `.host` instead (AE#842).
- A host may clear `preferredDisplayCriteria` itself between loads (when leaving full screen for a preview). That no longer leaves the engine wrongly skipping its write for "the same format": the next non-suppressed load reads the display manager, finds nothing set, and writes again (AE#678). Clearing through `stop()` is still cleaner, because it resets the engine's record in the same step.

#### `panelIsInHDRMode`

A **host assertion** that the panel is presenting HDR right now. It also decides whether the HDR10-to-DV upgrade is accepted up front.

- On every platform it is added to the engine's own readout (either one is enough); it does not replace it. It is no longer limited to `suppressDisplayCriteria` hosts (AE#459).
- The readout it backs up is `currentEDRHeadroom > 1`, which only answers around a dynamic-range transition. An Apple TV whose output format is locked to HDR never makes one, so it reads as an SDR panel forever. On tvOS 27 the property has stopped answering at all on at least one box.
- A wrong assertion costs one in-place media-playlist fallback (`-11848`), not the item.
- An in-place rebuild (an audio pick, a custom-source reload) runs no handshake. It routes on the load's readout and display eligibility, together with the session's current assertion and the remembered refusal, not on this option alone (AE#541).

#### `attemptsHDRMasterOnUnprovenPanel`

Serves the HDR master to an HDR-eligible display whose panel state is unproven. AVFoundation's acceptance or refusal then provides the answer `UIScreen` will not give (AE#459). VOD and live. Set it false on a host that knows its display is SDR.

**Why.** It replaces `currentEDRHeadroom` as the signal, and that property is measurably unreliable. On one Apple TV 4K 3rd gen on tvOS 26.6 it read a flat 1.00 across 46 samples of HDR content, while the TV's own info display reported HDR. Later the same day, with the same box, output format and title, it read 1.20. The panel was presenting HDR and the property was wrong; what moves it is unknown.

**What the media-playlist fallback costs** on such a panel is not the picture but parts of the manifest: the SUBTITLES rendition, the AUDIO rendition (the only place AVFoundation reads an HLS language from), and SUPPLEMENTAL-CODECS.

**Behaviour.**

- A panel that already proves HDR through the headroom skips the attempt.
- A refusal costs one in-place media fallback, measured at 223 ms end to end (`-11868` after 54 ms, zero `errorLog` events, position kept, no visible black frame). It is remembered for the process, so a truly SDR display pays it once, not per title.
- Live tries too: the refusal arrives before the first frame, so the live fallback's rejoin at the edge (#130) lands where the session was joining anyway.
- An ATTEMPT does not change the published `videoFormat`. An ACCEPTANCE does: a master AVFoundation has not refused after the settle window publishes the presented format. That is a stronger reading than the headroom, not a replacement for it.

#### `panelPresentsDolbyVision`

A **host assertion** that this display presents Dolby Vision, for the platforms where the engine cannot observe it (AE#493). `AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`, so a Mac has no per-mode table at all. `eligibleForHDRPlayback` answers for HDR10 and HLG but not for this: it proves EDR, not that AVFoundation will accept a DV variant here.

**What setting it does.**

- Publishes `videoFormat = .dolbyVision` and asks the tvOS display-criteria handshake for `dvh1`.
- It implies HDR support, because DV is an HDR format. It does not imply HDR10 or HLG capability.
- Profile 7 and AV1 Dolby Vision are still gated on it.
- Asserting also disables `forceDolbyVisionOnNonDVDisplay`, the tvOS route for that panel class (AE#455).
- An assertion only ever adds, so `false` cannot hide a capability the system reports.

**What it does not decide.** The packaging of a Profile 5, 8.1 or 8.4 source. Those three serve byte-identical manifests and segments either way (measured on macOS against the matched Dolby grades).

**A wrong assertion** costs one in-place media-playlist fallback (`-11868` / `-11848`) at the same position, where AVPlayer tone-maps the base layer. It is correctable mid-session through `reloadAtCurrentPosition(applying:)`. That safety net covers only item failures. The claim still affects HDR readiness on the route, since it implies `supportsHDR`.

#### `stereoPresentation`

How a 3D source is presented where the system shows stereo (visionOS; every other system plays it 2D as before).

- `StereoPresentation.automatic` keeps an MV-HEVC stream's second view (`lhvC` in the init) and presents the side-by-side or over-under packing a container declares (Matroska `StereoMode`).
- `.sideBySide` / `.overUnder` say what a file's name alone says.
- `.mono` plays 2D.
- A stereo session declares `REQ-VIDEO-LAYOUT="CH-STEREO"` (EXT-X-VERSION 12), and a packed frame gets Apple's `vexu` in its sample entry.
- Frame packing is signalled on HEVC only (AVPlayer refuses a packed H.264 init over HLS), so a packed H.264 frame plays 2D.
- A tuning field: `reloadAtCurrentPosition(applying:)` carries a change.

#### `dolbyVisionHandling`

`.baseLayerOnly` presents the HDR10 / HLG base layer of a Dolby Vision source, and leaves Dolby Vision out of the container on every display: plain `hvc1` / `av01` sample entry, `dvcC` stripped, no `SUPPLEMENTAL-CODECS`, HDR10 / HLG display criteria. `videoFormat` reads the base layer's format, while `sourceVideoFormat` and `sourceDVProfile` keep saying what the file carries.

**When to use it.** It is the route a host offers as "Dolby Vision: off (HDR10)", for a source whose Dolby Vision is wrong but whose base layer is right. The reported case: a remux carrying a Profile 7 RPU under a container record that claims Profile 5. A player that believes the record decodes YCbCr as IPT, and the picture comes out green / violet.

**Applies to** HEVC Profile 7 / 8.1 / 8.4, AV1 Profile 10.1 / 10.4, and a Profile 5 (or AV1 10.0) record whose VUI declares a BT.2020 YCbCr PQ or HLG base. A Profile 5 whose VUI is unspecified carries IPT-PQ-c2. It has no base layer to present, so it keeps its route, and the engine says so in the log.

- Takes precedence over `forceDolbyVisionOnNonDVDisplay`.
- A tuning field, correctable through `reloadAtCurrentPosition(applying:)`. Under it, a Profile 5 record the VUI contradicts also stops refusing the software path.

See [formats.md](formats.md#dolby-vision-signaling).

#### `forceDolbyVisionOnNonDVDisplay`

**Experimental (AE#455).** On a display with no Dolby Vision of its own, serve an HEVC Profile 8.1 source the way a Profile 5 source is served (`dvh1` sample entry, `dvcC` rewritten to profile 5 / compatibility 0, `CODECS="dvh1.05.LL"`). AVPlayer then applies the RPU itself, instead of handing the panel the HDR10 base layer with static metadata.

- The bitstream is untouched; only the container's claim about it changes.
- Ignored on a display that does Dolby Vision. Profile 8.1 only.
- See [formats.md](formats.md#dolby-vision-signaling) for what it gains and what it risks.

#### `preferDualLayerDolbyVision`

Opt in to composing Profile 7 FEL sources on the GPU, instead of taking the native route (the single-layer 8.1 conversion where the display takes Dolby Vision, the HDR10 base layer where it does not). See [dolby-vision-fel.md](dolby-vision-fel.md).

**Not recommended for a distributed app.** The composer itself evaluates the RPU's MMR chroma prediction and the enhancement layer, steps covered by live Dolby patents. The `DolbyVisionFelCurves` trait brings back most of a FEL source's enhancement layer on the native route without that ([Dolby Vision FEL › Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route)).

**Needs the `DualLayerDolbyVision` package trait** (off by default, [Installation › Optional components](installation.md#optional-components)). Without it the option is accepted but changes nothing, and a `reloadAtCurrentPosition(applying:)` that flips it is not refused.

**When the route is taken.** When true, and all of these hold:

- `dolbyVisionHandling` is `.automatic`
- the source is a seekable VOD
- the first RPU says `el_type` FEL
- VideoToolbox decodes HEVC in hardware
- the stream fits the real-time budget (UHD at 30 fps for the base layer plus a 1080p enhancement layer; a 24p UHD master uses 80% of it)

then Profile 7 routes through `SoftwarePlaybackHost` + `DualLayerVideoDecoder`:

- Both layers decode in VideoToolbox.
- `DoviFelComposer` rebuilds the picture in Metal and delivers 10-bit P010.
- Every frame carries its RPU, converted to Profile 8.1, as a `DolbyVisionRPUData` attachment. tvOS applies it as Dolby Vision display management.

A Profile 7 MEL source, and anything the device cannot decode twice in real time, keeps the native route: 8.1 where the display takes Dolby Vision, the HDR10 base layer where it does not. (The conversion is lossless only for MEL.) The load logs one `DV P7 dual-layer route: taken` / `not taken (<reason>)` line either way.

**What it gives up.** Against the native route: Picture in Picture, scrub thumbnails, subtitles, AirPlay. See [dolby-vision-fel.md](dolby-vision-fel.md#523-what-the-route-gives-up-against-the-native-route).

**Audio.** The route runs on the software host, whose audio is decoded by FFmpeg and played through the sample-buffer audio renderer.

- With `objectAudioRendering` off (the default), an E-AC-3 (JOC) track plays as its channel-bed core (5.1 or 7.1), without the objects.
- With `objectAudioRendering` set (and the object-audio traits built in), TrueHD Atmos and DTS:X are rendered into the bed, PCM or APAC as the option picks ([Atmos on the receiver](formats.md#atmos-on-the-receiver-tvos)).
- E-AC-3 JOC goes to the renderer compressed. On tvOS with a PCM bed, the system's Atmos decoder turns it into the bed instead, because the renderer plays compressed JOC silently there.

**The display is not consulted.** With the flag on and a display that does not take Dolby Vision, the route is still taken. The composed full-FEL picture is presented with its attached metadata, and how tvOS presents it is up to the platform. (The native route would have played the HDR10 base layer there.) The audio notes above apply there too.

**Correcting it.** A tuning field, correctable through `reloadAtCurrentPosition(applying:)` on a URL source, which re-runs `load()` and decides the route again. On a custom `IOReader` source, a Profile 7 session refuses with `SessionReloadRefusal.dualLayerRouteNeedsFreshLoad` a change of this option, or of `dolbyVisionHandling` while this option is on. The in-place rebuild keeps the route the session was loaded with; call `load()` again with the new option.

#### `dualLayerRoute`

Which route composes a Profile 7 FEL picture once `preferDualLayerDolbyVision` has taken the dual-layer route.

- **`.softwareHost`** (default) is the route described under [`preferDualLayerDolbyVision`](#preferduallayerdolbyvision).
- **`.avPlayerOutput`** is a second route behind the same `DualLayerDolbyVision` trait, opt-in and off by default. See [dolby-vision-fel.md](dolby-vision-fel.md#524-the-avplayer-output-route).

**How `.avPlayerOutput` works.**

- AVPlayer decodes and times the base layer (the engine's loopback HLS stream, Profile 8.1 RPU) and plays the audio.
- The engine takes the decoded frames from an `AVPlayerItemVideoOutput` (biplanar 10-bit, no colour conversion). It pairs each frame with its enhancement layer, which it taps in-process from the segment producer's single read of the source. There is no second connection and no full-file scan.
- It composes them with the same `DoviFelComposer` the software host uses, and presents the result in an `AVSampleBufferDisplayLayer` that follows the item's timebase. AVPlayer's own picture is hidden with the public `suppressesPlayerRendering`.
- The item owns the clock, so `currentTime`, `seek(to:)`, `play()` and `pause()` are AVPlayer's, and so is the audio. (The Atmos trade-off of `preferDualLayerDolbyVision` does not apply.)

**Enhancement-layer ring.** The enhancement-layer packets of the most recent stretch are kept in a bounded on-disk ring that keeps the newest bytes: 1 GiB at most, in the temporary directory, unlinked at once so nothing outlives the process. So a seek back into content the ring still holds finds its enhancement layer.

- The session's forward-buffer window is capped at 10 segments on this route. The producer's lead uses up ring space, and a lead longer than the ring would leave the playhead without an enhancement layer.
- While a position has no enhancement layer (a seek beyond what the ring holds, a gap), the picture is AVPlayer's own base-layer frame, shown at once. The composed picture returns when the layers pair again (after a seek beyond the ring: once the playhead reaches packets the ring holds).
- A base-layer frame whose enhancement packet is only late waits 0.1 s, then goes out as the base layer.

**Platforms.** Compiled for macOS, tvOS and iOS. Only macOS has been run. tvOS and iOS compile and the route can be selected, but it has not been run on a device.

**Drawing.** The route draws in the engine's `AetherPlayerView`.

- A host that puts `nativePlayerLayer` into its own view sees no picture from it (the property is nil while the route runs).
- Picture in Picture is not offered on this route (`nativePlayerLayer` is nil and there is no `softwarePiPSource`), so a host cannot build a window that would be blank.
- Subtitles are not checked on it.
- When an AirPlay video receiver or an external display holds the picture (at load, or after a route change mid-session), the route stops. AVPlayer then shows its own picture, the Profile 8.1 base layer, without the enhancement layer. The log carries `[DualLayerOutputRoute] another screen ...`, and the route is decided again at the next load or rebuild of the session.

**When it changes nothing.** It only acts when the preference is on and the route decision takes the dual-layer route. A MEL source, a build without the trait, a source whose packets are not hvcC-framed (Annex B), and a stream without a usable frame rate load as with `.softwareHost` (the log says why).

**Picture difference.** The composed picture differs from the software host's only in the dither pattern. Both dither on whether a frame index is odd or even: the host counts compositions, and this route uses the frame's position in the stream.

**Correcting it.** A tuning field, correctable through `reloadAtCurrentPosition(applying:)` on a URL source. On a custom `IOReader` Profile 7 session, a change of it while `preferDualLayerDolbyVision` is on is refused with `SessionReloadRefusal.dualLayerRouteNeedsFreshLoad`.

The load logs `DV P7 dual-layer: AVPlayer-output route (...)` after the usual `DV P7 dual-layer route: taken` line.

#### `upscalesLowResolutionVideo`

Opt in to upscaling SDR video below 1080p (coded width under 1920 and height under 1080) to the display's native pixel size (#846).

**How.** Such a source routes through `SoftwarePlaybackHost`. Each decoded frame runs VideoToolbox low-latency super resolution where the device and frame size allow it. Then MetalFX spatial scaling fits it, at the source's display aspect, into the display, never beyond it. Needs tvOS / iOS / macOS 26. Status is published as `$activeUpscale`.

Without MetalFX spatial scaling (tvOS before 27.1, or a GPU without it), the stage starts on its VideoToolbox-only step, and the display scales the rest. This is logged as `[Upscale] MetalFX unavailable on this device, starting ML only` and published with `degraded` true. A plan with no VideoToolbox pass is then not taken.

**Not taken** for these; they keep their usual route:

- HDR (PQ, HLG; an unspecified transfer counts as SDR), and Dolby Vision
- a display no larger than the source
- any wireless AirPlay route, whether a receiver shows the video or AirPlay speakers play the sound: the software path sends only the sound there
- a demuxed-audio live stream
- an OS before 26
- a source whose coded size is unknown
- a plan the stage switched itself off for earlier in the process (see below)
- under the default `.automatic` scaler, a source that is not 8-bit 4:2:0, 10-bit SDR included (see [`upscaleScaler`](#upscalescaler))

The load logs one `[Upscale] taken: <source> -> <target> (<stages>)` / `[Upscale] not taken (<reason>)` line either way.

**It never stops playback.** A frame the stage cannot process is delivered as decoded.

- **Building.** The stage is built off the main thread, because starting VideoToolbox super resolution loads its model on the Neural Engine (about 4 s cold on Apple TV). Until it is ready, frames are delivered as decoded. This is logged once as `[Upscale] passing frames through: stage still building`, then `[Upscale] stage built in ... ms`. A stage that cannot be built switches itself off like a failing one (`disabledReason` `stage not built: ...`).
- **Overrun.** The frame budget is 90% of the frame interval, measured over 48 frames.
  - It is that generous because the GPU lowers its clock until a steady load fills most of the interval. On an A15, work that takes 14 ms back to back reads 32 ms at 24 fps. A stricter budget would trip on the clock, not on a stage that really falls behind.
  - A sustained overrun first drops MetalFX where VideoToolbox super resolution also runs. This is logged once as `[Upscale] degraded: ...` and published as `UpscaleStatus.degraded`.
  - The overrun is remembered for the process. A later session or in-session rebuild that is at least as heavy and as fast starts without MetalFX.
- **Switching off.** Repeated failures, or an overrun with nothing left to drop, switch it off for the session (logged once, and published through `$activeUpscale`).
  - A stage that switched itself off stays off for the rest of the session, also across in-session rebuilds (audio switch, background return), and `$activeUpscale` keeps its `disabledReason`.
  - Its plan (source, ML output and target size) is remembered for the process, together with the source frame rate. A later load with the same plan, at that rate or faster, logs `[Upscale] not taken (the stage disabled itself for this plan earlier in this process)`.
- **Timing log.** For the first ten 48-frame windows of each stage, it logs a per-step timing line (`[Upscale] timing: total ... ms (copy, ml, edge, metal wall / gpu, attach) over 48 frames at ... ms interval`).

**Going back to native.** A URL VOD session that only the stage put on the software path goes back to the native path when the stage switches itself off. Once no load is in flight, it reloads at the current position (`reloadAtCurrentPosition()`, logged as `[Upscale] stage disabled on a session it alone put on the software path: ...`). A custom `IOReader` source and a live session stay on the software path, with frames delivered as decoded.

**Correcting it.** A tuning field, correctable through `reloadAtCurrentPosition(applying:)` on a URL source, which re-runs `load()` and decides the route again. On a custom `IOReader` source, turning it off is honoured in place (the session stays on the software path and delivers frames as decoded). Turning it on is refused with `SessionReloadRefusal.upscaleRouteNeedsFreshLoad`.

#### `upscaleScaler`

Which scaler the upscale stage runs while `upscalesLowResolutionVideo` is on (AE#1039). Ignored while that option is off.

| Value | What it does | Takes |
| --- | --- | --- |
| `.automatic` (default) | VideoToolbox super resolution, then MetalFX, as described above | SDR, 8-bit 4:2:0, below 1080p |
| `.lineArt` | A 2x line-art network, then a bilinear resample to the display box where 2x does not land on it | SDR, 8 or 10-bit 4:2:0, up to 1920x1080 |

**What `.lineArt` is.** [Anime4K](https://github.com/bloc97/Anime4K)'s "mode A" in its small size (MIT licence), as native Metal compute kernels in half precision. The kernels are `LineArtShaderSource`, generated from the original GLSL by `Scripts/generate-line-art-shader.py` with the weights unchanged. The passes are Clamp_Highlights, Restore CNN (S), then Upscale CNN x2 (S).

- The restore pass cleans up compression traces and blur and darkens the lines before the upscale. The clamp keeps the result from overshooting at bright edges.
- It is made for drawn content and suits nothing else, so a host sets it per title (from the genre, or a per-show switch).

**What it costs.** About 15.6 ms of GPU time per frame for 1080p to 2160p on an A15 (Apple TV 4K, 3rd generation) with the GPU at full clock, 8.6 ms without the restore pass.

- In playback the GPU lowers its clock to match the load, so the stage's timing lines read about 32 ms at 24 fps (20 ms without restore). That is the clock, not a limit.
- At exactly 2x, the network's last step writes the output planes directly, with no 2x RGB texture in between.
- It needs no MetalFX and no Neural Engine, so the stage builds in well under a second.
- Like `.automatic`, it moves the title onto the software path, with that path's costs.

**How it behaves.** The same as the automatic stage, except:

- The load logs `[Upscale] taken: <source> -> <target> (line art 2x to <size>)`, with `, then bilinear` when 2x does not land on the target.
- It is not taken for a source that is neither 8 nor 10-bit 4:2:0 (`[Upscale] not taken (source is not 8 or 10-bit 4:2:0)`) or larger than 1920x1080 (`source is larger than 1920x1080`).
- Output frames keep the decoder's pixel format: 10-bit stays 10-bit.
- **Falling back.**
  - The first sustained overrun drops the restore pass and the clamp. This is logged as `[Upscale] degraded: line art over budget ..., dropping the restore pass` and republished with `degraded` true and `scaler` still `.lineArt`. A later stage this overrun covers starts without them.
  - A second overrun is remembered for the process (`LineArtCostMemory`). Then a source below 1080p falls back to the automatic route for the rest of the session: VideoToolbox super resolution, with MetalFX where available. The new stage builds off the decode thread while frames pass through, and `$activeUpscale` is republished with `degraded` true and `scaler` `.automatic`.
  - A 1080p source has nothing below line art, so it switches off.
  - A later load that the remembered overrun covers (at least as large, at least as fast) starts on that fallback directly, logged as `[Upscale] line art overran on this device earlier, ...`.
- `UpscaleStatus.scaler` is `.lineArt`, and `mlScale` is nil.

**Correcting it.** A tuning field, correctable through `reloadAtCurrentPosition(applying:)` on a URL source. On a custom `IOReader` source, switching it while `upscalesLowResolutionVideo` stays on is refused with `SessionReloadRefusal.upscaleRouteNeedsFreshLoad`, because the in-place rebuild keeps the session's plan.

#### `autoplay`

`autoplay` describes THIS MOUNT and nothing after it. The rebuilds a session makes on its own (`reloadAtCurrentPosition`, an option correction, the AirPlay LAN swap, an audio-delay change) come back in the transport state the session is in, not in this one.

So correcting it through `reloadAtCurrentPosition(applying:)` does nothing. Call `play()` or `pause()` instead.

- The log names it as not applied (AE#464 round 3).
- The call returns it as `sessionOwned` with `rebuilt` false, instead of spending a teardown on it (AE#464 round 4).

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
| `ExternalSubtitleTrack` | `url`, `name`, `language`, `isForced`, `isHearingImpaired`, `isDefault`, `httpHeaders` (nil inherits `LoadOptions.httpHeaders` for a same-origin URL only, see [External subtitle request headers](#external-subtitle-request-headers)), `formatHint` for URLs whose path hides the format, and `sourceStreamIndex` for a container holding several subtitle streams. That index addresses the container at `url`, not the played media. |
| `NativeSubtitleTrack` | `ordinal`, `language`, `displayName`, plus `sameLanguageRank(of:in:)` for telling same-language options apart (eng Full against eng SDH). |
| `RecordingState` | `.idle`, `.recording(RecordingProgress)`, `.ended(RecordingEndReason)`, `.failed(RecordingFailure)`. What the session's live recording is doing. |
| `RecordingProgress` | `url`, `startedAt`, `bytesWritten`, `durationSeconds`. Republished at 1 Hz while recording. |
| `RecordingEndReason` | `.stoppedByHost`, `.sourceReset`, `.sessionEnded`. Why a recording stopped without failing; the file is closed and playable in every case. |
| `RecordingFailure` | `.unsupportedRoute(VideoRoute)`, `.notLive`, `.alreadyRecording(URL)`, `.cannotCreateFile(String)`, `.noStreamsToCopy`, `.diskFull(bytesWritten:)`, `.writeFailed(String)`, `.writeTooSlow(bytesWritten:queuedBytesDropped:)`. The first five are thrown out of `startRecording(to:)`; the last three arrive through `$recordingState`. |
| `TitleInfo` | `id` (0-based, longest first; id 0 is the main feature and the key for `selectTitle`), `name`, `durationSeconds`, `chapterCount`, `playlist` (Blu-ray: the `.mpls` file name, e.g. "00800.mpls"), `titleSet` (DVD: the `NN` of `VTS_NN`). See note 1. |
| `ChapterInfo` | `id`, `name`, `startSeconds`, `durationSeconds`. The two publishers use different time axes. See note 2. |
| `AudioShaping` | `maxChannels` (nil or 1...8, never upmixes), `dialogueGainDB` (0...`maxDialogueGainDB`, 12), `compressor`, `loudnessTargetLUFS` (nil or within `loudnessTargetRange`, -36...-12; raises by at most `maxLoudnessGainDB`, 18 dB), `lfeMixDB` (nil or within `lfeMixRange`, -20...+10; the LFE level in a fold that drops it), `clamped`, `isActive`, `summary` (the wording the engine's log uses). |
| `AudioShaping.Compressor` | `thresholdDB` (clamped to -60...0 dBFS), `ratio` (1...20), `makeupGainDB` (0...24 dB), `attackMilliseconds` (0.1...200), `releaseMilliseconds` (10...2000), `kneeDB` (0...18); a non-finite value reads back as a neutral default. `clamped`, and the `night` preset (-30 dB, 4:1, +10 dB makeup, 5 ms attack, 250 ms release, 6 dB knee). |
| `AudioShapingState` | `.off`, `.applied`, `.unavailable`; see `$audioShapingState`. |
| `UpscaleStatus` | `sourceSize` (the decoded size the stage receives), `mlScale` (the VideoToolbox super-resolution factor; nil when MetalFX alone scales), `targetSize` (the delivered size: the source's display aspect fitted into the display), `disabledReason` (set when the stage switched itself off mid-session), `degraded` (see note 3), `scaler` (the `UpscaleScaler` the stage runs). See `$activeUpscale`. |
| `UpscaleScaler` | `.automatic` or `.lineArt`, the scaler `LoadOptions.upscaleScaler` selects. See [`upscaleScaler`](#upscalescaler). |
| `AudioTapChannels` | `.downmix` (every channel summed) or `.dialogue` (the front-centre channel, falling back to the downmix on a source without one). |
| `AudioTapBuffer` | `buffer` (`AVAudioPCMBuffer`), `sourceTime`, `discontinuity`, `channels` (what this buffer actually carries). Non-discontinuity buffers are strictly increasing and non-overlapping, which is what SpeechAnalyzer's input timeline requires. |
| `LiveTelemetry` | The 1 Hz snapshot: bitrates, observed fps, dropped frames, cache and network bytes, A/V gap, RSS. |
| `ObjectAudioActivity` | `layout`, `objects`, `activeObjects`, `elevatedObjects`, `heightChannels`: what object audio is doing, as `LiveTelemetry.objectAudio`. |
| `PlaybackErrorInfo` | Published as `$errorInfo` beside a `.error` state. Fields under [The message is a payload, `errorInfo` is the key](#the-message-is-a-payload-errorinfo-is-the-key). |
| `PlaybackErrorKind` | The stable token inside it. Every kind, and the ones that need their own handling: [`PlaybackErrorKind`](#playbackerrorkind). |
| `DisplayCapabilities`, `StartupProgress`, `SeekEvent`, `PresentationAxisMap`, `NativeVideoFrameTime`, `SoftwareVideoFrameTime`, `SoftwarePiPSource`, `SystemCaptionRequest`, `AetherEngineError`, `HLSIngestError` | Covered in their sections above. |
| `LiveDVRLimits`, `SoftwareDVRRetentionOptions` | The live DVR lease and the software spool's opt-in bounds; covered in [Live and DVR](#live-and-dvr). |
| `ScrubFrame` | `image`, `actualSeconds`, `refined`, `validRange`. Returned by `scrubPreviewFrame`. |
| `BoundedStillFrame` | `image`, `actualSeconds`. nil `actualSeconds` means the decoded frame carried no PTS, so the caller labels the requested time rather than claiming a measured one. |
| `FontAttachment` | Attached font files for authored ASS rendering: `filename`, `mimeType`, `data`. |

1. **`TitleInfo`.** `id` is a position in the current scan. `playlist` and `titleSet` name the title on the disc, so store those to recognize a title at a later open.
2. **`ChapterInfo`.** `discChapters` are relative to the title and reached through `selectChapter(id:)`. `mediaChapters` are on the 0-based `currentTime` / `seek(to:)` axis (the container start already subtracted): a host passes `startSeconds` straight to `seek(to:)`, and `selectChapter` does nothing for them.
3. **`UpscaleStatus.degraded`** is true when the stage runs below its top step. Either a sustained overrun or missing MetalFX made it deliver the VideoToolbox output at its own size (which `targetSize` then is, with the source's pixel aspect ratio), or a line-art overrun fell back to the automatic scaler. It stays true when the stage later switches itself off.

**`SourceProbe` HDR flags.**

- `carriesHDR10PlusMetadata` is `false` unless the probe was asked for `.hdr10Plus`. A `false` means "not asked, or not seen within the budget", never "proven absent".
- When it is true and the container said HDR10, `videoFormat` reads `.hdr10Plus`. A Dolby Vision source keeps `.dolbyVision` and carries the flag alongside.
- `carriesHDRVividMetadata` follows the same contract for `.hdrVivid` (#699), and never changes `videoFormat`: HDR Vivid sits on an HLG or PQ base, which stays the label.
- `dolbyVisionEnhancementLayer` is nil unless the probe was asked for `.dolbyVisionEnhancementLayer`. nil also covers "not Profile 7" and "no RPU within the budget", so it never means MEL (#1030).

**`SourceProbe` container facts (#1032).** Three fields carry what a loaded session publishes, read from the same open demuxer, so a details screen has them before the first playback.

- `containerFormat` is the libavformat name (`"matroska,webm"`, `"mov,mp4,m4a,3gp,3g2,mj2"`, `"mpegts"`), the same string as `sourceContainerFormat`. It names what the bytes are: an MP4 renamed to `.mkv` reads `"mov,mp4,..."`.
- `dvBLCompatID` is the base-layer signal compatibility id from the `dvcC` / `dvvC` record, the same value as `sourceDVBLCompatID` (1 HDR10, 2 SDR, 4 HLG, 6 Blu-ray HDR10, 0 none; nil without a record). So Profile 8.1 / 8.2 / 8.4 need no guess from the transfer.
- `discTitles` is the same list as the session's `discTitles`, longest first, empty for a source that is not a disc. An id from it is valid for `load(..., discTitleID:)`.

### `TrackInfo`

Fields: `id`, `name`, `codec`, `language`, `channels`, `bitrate`, `isDefault`, `isForced`, `isHearingImpaired`, `isCommentary`, `isVisualImpaired`, `isAtmos`, `isDTSX`, `trueHDAtmos`, `assHeader`, `isExternal`, `isNativelyRenderedSubtitle`; for audio also `sampleRate`, `bitsPerSample`, `sampleFormat`, `channelLayout`; and `profile` for every track (AE#658).

- `isVisualImpaired` is audio description, from the container's `VISUAL_IMPAIRED` disposition (AE#919).
- `bitsPerSample` is 0 where the codec has no fixed depth (AAC, AC-3, E-AC-3 and Opus decode to float).
- `sampleFormat` is the probe decoder's output in libav's names ("fltp", "s32").
- `profile` is libavcodec's profile name, and the place DTS:X ("DTS-HD MA + DTS:X") and TrueHD Atmos ("Dolby TrueHD + Dolby Atmos") show up. `isAtmos` covers E-AC-3 JOC only.
- `trueHDAtmos` (#1035) is a probe's `.atmos` answer for a TrueHD track, read from its major sync: `.atmos`, `.noAtmos` or `.unsettled`; nil when that pass did not run for the track. libavcodec names the profile only for a track the header probe decoded a frame of, so a nil `profile` alone cannot tell plain TrueHD from Atmos.
- `isDTSX` is set from that DTS:X profile at probe time. The probe labels it from the frames it read, so it is also set later, once the DTS:X decoder confirms a track FFmpeg labelled plain DTS-HD MA while `objectAudioRendering` plays it. `audioTracks` is then republished, and the flag stays for that source.
- `isNativelyRenderedSubtitle` marks a subtitle the playback backend draws itself (a remote-HLS rendition AVFoundation renders). No cue reaches `subtitleCues`, so an overlay control (position, delay, styling) has nothing to act on.

## Public but not host API

These are public for the CLI, the test suite, or a diagnostic overlay, and are outside the API this reference documents. Nothing here should carry playback logic.

- The `@_spi(Diagnostics)` entries are outside the SemVer contract and may change in any release.
- The other entries stay source-compatible, like the rest of the public surface.

- **Test hooks**: `setForceSoftwarePathForTesting`, `setForceAudioPipelineFailureForTesting`, `setForceMasterPlaylistForTesting`, `setSourceThrottleKbpsForTesting`, `setSoftwareBackgroundAudioOnlyForTesting`, `softwareVideoFramesEnqueuedForTesting`, `invalidateSoftwareVideoSessionForTesting`, `setLargeAllocationCensusEnabled`, `forceStalledConsumerReloadForTesting`, `stallRendererClockForTesting`, `rendererClockRateForTesting`.
- **`FrameExtractor`'s yield policy** (`shouldYield`, `yieldMinForwardBufferSeconds`, `yieldHealthyTicksRequired`): internal tuning, public so the tests can pin it.
- **`playbackBackend`**: the internal rendering backend, exposed read-only for overlays. Hosts must not branch on it; `videoRoute` is the surface that answers the same question honestly.
- **`HLSVideoEngine`** and its `DiagnosticStats`: the loopback session's own machinery, public because `aetherctl` drives it directly. (Its `sessionCacheStatus()` is described under [Session cache budget and status](#session-cache-budget-and-status).)
- **`DiscInspection`**, `DoviRpuConverter` and its probe, `VideoNALFraming`, `AudioTapProbe`, `SoftwareDecodeProbeResult`: reproduction and inspection tools behind `aetherctl` subcommands. `VideoNALFraming` is the framing argument of that converter: `.annexB` for start-code delimited NAL units as in MPEG-TS, `.lengthPrefixed(size:)` for the 1 to 4 byte length prefixes of MP4 and Matroska, read from the avcC/hvcC record. The wrong one does not fail; it finds nothing.
- **`HLSLiveIngestReader`'s internals** (`terminalError`, `upstreamTargetDuration`, `observedLiveCadenceSeconds`, `closedLiveCadenceSeconds`, `upstreamSegmentDurationSeconds`, `companionAudioReader`): fixture and diagnostic reads. `closedLiveCadenceSeconds` and `upstreamSegmentDurationSeconds` are the measured values the served TARGETDURATION is sealed from (AE#447). `upstreamTargetDuration` is the upstream's own claim, reported in the seal line; nothing is derived from it.
- **`SubtitleChannel`**: the primary / secondary selector on the engine's internal subtitle routing. No public signature takes one; a host picks the channel by calling the primary or the secondary method.

**`@_spi(Diagnostics)` surfaces.** Hosts import none of these.

- **Dolby Vision Profile 7 FEL tooling.** The host surface of the FEL route is `LoadOptions.preferDualLayerDolbyVision` and, in `SessionReloadRefusal`, the case `.dualLayerRouteNeedsFreshLoad`. See [Dolby Vision FEL](dolby-vision-fel.md) and [CLI](cli.md).

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

- **AV1 Dolby Vision 10.1 switches**: `attachesAV1DolbyVisionRPU` (default on; off shows the route's HDR10 base layer for A/B viewing, from the next frame on) and `decodesAV1DolbyVisionInSoftware` (default off; on uses dav1d even where VideoToolbox decodes AV1, so a Mac reproduces the Apple TV route). Hosts set neither: the route has no host option ([formats › Dolby Vision signaling](formats.md#dolby-vision-signaling)).
- **`convertsAV1FramesOnGPU`** (default on): off hands 10-bit AV1 back to `sws_scale` and lets dav1d apply the film grain, for CPU comparisons. Read when a decoder opens. Hosts never set it ([formats › Containers and codecs](formats.md#containers-and-codecs)).
- **`snapsAV1SeeksToKeyframes`** (default on): off keeps every AV1 seek on the software host exact instead of landing it on the nearest keyframe, and keeps a cache hit on the keyframe before the last one, for comparisons. Read when a session opens its decoder. Hosts never set it ([Transport › `seek(to:)`](#transport)).

## Moved sections

These headings moved. They stay here so older links keep working.

### One FFmpeg, and it has to be the engine's

Moved to [Installation › One FFmpeg, and it has to be the engine's](installation.md#one-ffmpeg-and-it-has-to-be-the-engines).

### Holding a second player beside the engine

Moved to [Installation › Holding a second player beside the engine](installation.md#holding-a-second-player-beside-the-engine).

### Sequential origins

Moved to [`sequentialOrigin`](#sequentialorigin).

### An ingested HLS upstream: sealing over the whole upstream segment (AE#684)

Moved to [An ingested HLS upstream: sealing over the whole upstream segment](#an-ingested-hls-upstream-sealing-over-the-whole-upstream-segment). The measurements are in [measurements.md](measurements.md#live-join-sealing-over-the-upstream-segment).

### An HLS source with its own window fills the cushion at the join (6.77.0)

Moved to [An HLS source with its own window fills the cushion at the join](#an-hls-source-with-its-own-window-fills-the-cushion-at-the-join). The measurements are in [measurements.md](measurements.md#live-join-filling-the-cushion-from-the-origins-window).
