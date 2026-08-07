# Architecture

How AetherEngine is put together: the three playback pipelines, the source-file map, and the dependency surface. For the public API and integration, see the [README](../README.md); for format and codec depth, [docs/formats.md](formats.md).

## Playback pipelines

AetherEngine has three playback pipelines, picked once at `load(url:)`: the audio-only path when `LoadOptions.audioOnly` is set, otherwise the native or software video path based on the source's video codec.

### Native AVPlayer pipeline (default)

Demux the source with libavformat, re-mux the elementary streams on the fly into HLS-fMP4, serve them from a local HTTP server on `127.0.0.1:<port>`, point `AVPlayer` at the playlist. Apple's stack does all decode, all HDR / Dolby Vision signaling over HDMI, all audio routing. This is the path for HEVC and progressive H.264, which is what AVPlayer's HLS-fMP4 pipeline reliably accepts (interlaced H.264 routes to the software path for deinterlacing, #107). Atmos passthrough, DV HDMI handshake, HDR10 / HDR10+ system-side tone-mapping all live on this path.

```
Source URL ──► Demuxer ──► HLSSegmentProducer ──► SegmentCache ──► HLSLocalServer
                                                                         │
                                                                         ▼
                                                                     AVPlayer
                                                                         │
                                                                         ├─► VideoToolbox (HW decode)
                                                                         └─► AVR / speakers (Atmos via MAT 2.0)
```

Why HLS-fMP4 for the native path instead of feeding `AVPlayer` the source URL directly: AVPlayer's progressive-download path won't accept arbitrary MKV containers, and even for MP4 sources it's brittle around Dolby Vision sample-description quirks and EAC3 `dec3` box variants. The HLS-fMP4 wrapper is the most permissive surface AVPlayer exposes; libavformat's `hls` muxer produces bytes byte-identical to `ffmpeg -f hls -hls_segment_type fmp4`, which is what Apple's HLS spec is defined against.

The playlist's segment boundaries come from a keyframe-aligned plan that mirrors the `hls` muxer's cut algorithm (segment N ends at the first IRAP at-or-after `(N+1) * targetSegmentDuration`), built in `HLSVideoEngine+SegmentPlanning.swift`. It needs the source's keyframe positions, which for MKV / MP4 come from a brief cue prewarm (a bounded seek that loads the Cues / `stss` index) and for MPEG-TS / M2TS come only from whatever `avformat_find_stream_info` plus that seek happened to scan. `keyframeIndexIsTrustworthy` gates the plan on two witnesses before trusting that index, falling back to a uniform-stride plan otherwise: the largest **gap** between consecutive keyframes must stay under a cap (a clustered TS index gaps by thousands of seconds; trusting it builds a multi-thousand-second first segment the `frag_custom` muxer buffers whole in RAM, #64), and the **coverage** from first to last indexed keyframe must span at least one `targetSegmentDuration`. The coverage check catches a remote MKV whose Cues tail read fails: the prewarm loads nothing, only the open-time keyframes survive bunched in the first few seconds, their gaps are tiny so the gap check passes, yet no keyframe reaches the first segment boundary, so the keyframe planner would degenerate to a single whole-file segment AVPlayer loads zero tracks from (`kFigAssetError_TrackNotFound`, #91). The uniform fallback anchors segment 0 at the content start so a late-starting title doesn't advertise empty leading segments.

At runtime the producer honors those boundaries with a keyframe-gated, decode-order cut (`VODSegmentCutter`): a segment opens only at the IRAP whose PTS reaches the next boundary, so the IRAP is the segment's first sample and its open-GOP leading pictures stay with it, matching the live path and the `hls` muxer. The earlier routing keyed each packet to a segment by its DTS against the PTS-valued boundaries, so under B-frame reorder a keyframe whose DTS trailed its PTS fell into the previous segment and the next one started mid-GOP, decode-dependent on its predecessor; a fresh decode at that boundary (rebuffer recovery) surfaced it as transient blocky corruption (#92).

Seeks are demand-driven: `AVPlayer` just fetches segments at the new position, and `VideoSegmentProvider` only tears the producer down and re-anchors it at the requested index (`restartHandler`, burst-coalesced by `RestartCoalescer`) when the request cannot be served from `SegmentCache`. A restart is the expensive path (it re-seeks the demuxer, slow on remote sources, #93), so for VOD the cache retains already-produced segments beyond its hard `[target - backwardWindow, target + forwardWindow]` window under a byte budget (2 GiB, clamped to a quarter of the tmp volume's free capacity), evicting farthest-from-target first once it fills. The hard window itself is never evicted, so that budget bounds only the extras around it, which holds by construction as long as the forward window stays at or below the historical 150-segment ceiling (~1.5 GB of 4K HEVC). A larger window is an explicit host opt-in into a whole-source prefetch (`LoadOptions.forwardBufferSegments`, up to 2700 segments ~ 3 h, #207): it drops the budget's 2 GiB default cap while keeping the quarter-of-free-space clamp, and the producer parks once its race-ahead owns that many bytes forward of the consumer target, resuming as eviction behind the playhead frees room (`PrefetchDiskBudget`). An opt-in prefetch therefore tracks the disk budget rather than the source length. A seek back into the retained span, and the forward march that follows it, is then a pure cache hit with zero producer restarts; only a seek into never-produced content restarts. Live sessions keep window-only pruning, since the sliding playlist has already dropped everything behind the window. When a non-disc VOD restart is required, it seeks on the video stream's native timestamp axis to the exact IRAP stored in the segment plan, with that timestamp as the lower bound; a global time seek can land a whole GOP earlier on multi-stream MP4 and turn the producer's scan-forward gate into a long remote read (#191). Disc plans use folded multi-clip timestamps and keep the global-time seek. Restarts on a slow link are further contained (#93 residual): a fetch that is waiting for an in-flight restart rides its progress instead of burning a fixed retry budget into a 503 (and never re-fires a restart at its own stale index), the wedged-restart fresh reopen skips `find_stream_info` (the session already holds saved codec configs and the segment plan), lazy native subtitle readers defer while a restart executes, and the FIRST producer of a resumed session anchors directly at the resume segment instead of producing seg0 into an immediate teardown. Retained scrub bands leave interior holes inside the cache's stored min/max index range, and residency there is not proof a segment exists: a fetch inside the range waits (2 s) only when the active producer's forward march actually covers the requested index, and restarts immediately otherwise (#129).

The public `seek(to:)` on the native path awaits AVPlayer's real landing so `isSeeking` spans it (#37/#38), but the wait is hard-bounded at 8 s (#65, #129): at the deadline the engine reconciles the published clock to AVPlayer's rendered frame and returns to the caller instead of stacking a second unbounded seek (repeated source stalls could chain those past 40 s). The original AVPlayer seek stays alive as the recovery intent (`pendingRecoverySeekClockTarget`): the producer is re-anchored at the target only when it is genuinely starved (a healthy-but-slow producer keeps its progress), the scrub clock is held while the intent is pending so recovery nudges cannot bounce it (#37), and a late landing settles the clock from the rendered frame, re-anchors subtitles once, and reconciles transport state after the fact; both orderings of the landing/deadline race on the MainActor are handled. Transport reconciles from live `timeControlStatus`, so an external AVKit / MediaRemote play or pause issued mid-seek wins, a spurious pause during active stall recovery is re-asserted inside the bounded recovery window, and a paused scrub still lands paused, never re-engaging playback (#122).

What a host observes about a seek comes in two shapes. `isSeeking` / `seekTarget` are the level: a seek is in flight, and where to. `seekEvents` is the stream that says what happened to it, because the level's falling edge is ambiguous by construction (#38 follow-up). Every accepted seek emits `.began` and exactly one of `.landed(renderedTime:)`, `.stalled` or `.superseded` under the same id, a seek that never reaches a host emits a standalone `.rejected`, and the one asymmetry is deliberate: a `.stalled` seek stays alive as recovery intent, so its `.landed` can still arrive minutes later on a source that finally serves the target, which is precisely the transition no level signal can express. Three paths feed it. Programmatic seeks report from their finalize, so the clock is already at the target when the event fires. Seeks stashed before the session can take them (#127/#178) hold the level for the whole stash window, because the engine publishes their target on `currentTime` optimistically and a consumer that broadcasts it needs to know nothing has reached it. Native AVKit scrubs end their window when the PICTURE reaches the restarted region, watched on `$renderedTime` and bounded at 8 s, not when the coalesced producer restart drains: draining means the producer is producing at the new index, and the picture arrives a fetch and a decode later (1.4 s on a WAN source in the reporting host's capture). A restart that a programmatic seek itself caused is left to that seek's events, since the restart segment can sit below where the picture ends up.

Restart latency is self-localizing (#93 follow-up): the "producer restarted" line carries a phase split (`stopWait/reopen/seek/build`), a producer's FIRST source read is timed, and any single `AVIOReader` read exceeding 2 s emits one `slow read` summary naming where the time went (detour fetches with network time, `connStallTimeout` waits, reconnects, backoff sleeps, bytes dropped by the stale-generation guard, generation span). A slow read with all-zero counters means the wait was upstream of the read loop.

A restart-window request must also never leave AVPlayer waiting in silence (#93 round 3): AVPlayer's media watchdog logs `-12889 "No response for media file"` after ~3.5 s without response HEADERS (holding the connection open does not help), and three strikes fail the item. A VOD serve still running at 2 s (`SlowServeSignal` armed by `VideoSegmentProvider.mediaSegment(at:onSlow:)`) therefore emits an early `200` with `Transfer-Encoding: chunked`; the segment follows as a single chunk when it lands, and a serve that ultimately misses aborts the connection (truncated transfer, AVPlayer retries) instead of framing a cacheable empty 200. Fast serves keep the byte-identical `Content-Length` response. If the item dies anyway, `failedToPlayToEndTime` parks it at rate 0 / `timeControlStatus == .paused` (with `item.status` often still `readyToPlay`), which every pause-guarded recovery layer used to misread as user intent, making the session terminal. The host now counts loopback-path end failures (`endFailureCount`), and the engine confirms the death through the same deferred window as the `.failed` KVO, then reloads the item through the stage-2 chain with the pause guard bypassed, bounded by `ItemDeathReviveGate` (3 attempts per dead spot; playback progress or a user seek away restores the budget).

When a restart does run, it must reproduce segments on the SAME media timeline the continuous run gave them: the loopback's contract with AVPlayer is "static VOD server", and AVPlayer anchors fMP4 segments by their `tfdt`. Each restart allocates a fresh mp4 muxer, and movenc zero-bases a new instance's timeline by default, so a restart-produced segment used to carry `tfdt=0` while the playlist placed it at its plan offset: an implicit timeline discontinuity on every restart, papered over for plain playback but fatal to ancillary consumers (AVKit's legible renderer detaches mid-PiP, Sodalite#32; playhead/loaded-range decoupling, #93). The muxer therefore sets `movflags +frag_discont` with `avoid_negative_ts=disabled` so `tfdt` carries the producer's absolute output timestamps, the restart audio gate inherits the session shift (video shift rescaled) instead of snapping audio onto the video seam, and leading head-of-stream audio that would map below 0 is dropped (the muxer no longer absorbs negative timestamps). A restarted segment is byte-identical to its continuous twin modulo the per-muxer `mfhd` sequence number (pinned by `RestartTimelineContinuityTests` on a committed A/V fixture); on matroska sources, per-sample DTS synthesis after a demuxer seek scatters the DTS decomposition and boundary-frame membership by a frame or two, but presentation timestamps and `tfdt` anchoring stay epoch-invariant.

### Software decoder pipeline (AV1 + VP9 + VP8 + legacy fallback)

Demux the source, run video packets through libavcodec (dav1d for AV1, FFmpeg's native decoder for VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1) into `CVPixelBuffer`s, run audio through libavcodec into `CMSampleBuffer`s, render via `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` as the master clock. Used for codecs AVPlayer's HLS-fMP4 pipeline doesn't accept: AV1 (no Apple TV currently ships an AV1 hardware decoder, and Apple bundles dav1d only on iOS / macOS, so AV1 always routes here today; the engine still registers the supplemental VideoToolbox AV1 decoder and gates on `VTIsHardwareDecodeSupported` (`VTCapabilityProbe`), so a future Apple TV chip with HW AV1 is picked up automatically), VP9 / VP8 (AVPlayer parses the HLS manifest, sees `vp09` / `vp08` in the CODECS attribute, then silently stops fetching. `item.status` never leaves `.unknown`. VideoToolbox HW-decodes VP9 fine, but only outside the HLS pipeline), and legacy MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, and VC-1 (none of `mp4v.20.X` / `mp2v` / `vc-1` are in Apple's HLS Authoring Spec CODECS list). Interlaced H.264 also routes here (`VideoRoutingPolicy`, keyed on the declared field order), because AVPlayer does not deinterlace and 1080i / 576i broadcast would comb; the SW path runs it through `DeinterlaceFilter` (#107). On seekable VOD that declaration is verified against decoded frames first (`InterlaceProbe`, #232): the filter engages on `AV_FRAME_FLAG_INTERLACED` alone, so a sample in which that flag never appears proves the detour would be a no-op and the stream goes back to the native path.

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

A seek holds the last frame on screen rather than blanking it. `SampleBufferRenderer.flush()` takes a `removingDisplayedImage` flag (`DisplayFlushOp` is the pure decision split out for testing): stop/teardown clears the visible frame (the default), but `SoftwarePlaybackHost.seek()` passes `false`, so the previous frame stays up until the post-seek keyframe decodes instead of flashing black on slow sources like MPEG-2. This matches the native/AVPlayer path, which holds the frame through a seek (#90).

`AudioDecoder` stamps each `CMSampleBuffer` from a running sample count anchored to the first frame (`AudioClockAnchor`), not from the container-quantized per-packet PTS. Container timebases are coarse (1 ms in MKV), so when a frame's duration is not an integer number of ticks (a 1536-sample AC-3 frame is 34.83 ms at 44.1 kHz but exactly 32 ms at 48 kHz) the quantized PTS leave a sub-millisecond gap or overlap at every buffer boundary, and `AVSampleBufferAudioRenderer` reconciles a discontinuity at each one (~29 clicks/sec, a continuous crackle). Anchoring to the sample clock makes consecutive buffers abut exactly; a real source discontinuity (> 100 ms off the predicted clock, i.e. a seek or edit) re-anchors so genuine gaps are not papered over, and `flush()` drops the anchor. The clock advances only on a successfully emitted buffer, so a dropped buffer injects no phantom samples.

AV1+DV (Profile 10.0 / 10.1 / 10.4) routes through the native path on hardware-AV1 hosts via the `dav1` / `av01` track type plus the source's `dvvC` box. AV1+Atmos is genuinely rare in the wild (mastering still runs in HEVC overwhelmingly), so the SW pipeline's lack of Atmos passthrough is a theoretical limitation rather than a real one. The dispatch happens once at load time; hosts see a unified `@Published` state surface either way.

**Background audio (iOS).** When the app backgrounds while playing, the engine keeps audio going rather than tearing the pipeline down. The decision is a pure, unit-tested policy, `backgroundAction(isAudioBackend:hasSoftwareHost:keepVideoAlive:state:)`, driven from the `UIApplication` lifecycle observers; `keepVideoAlive` comes from `shouldKeepVideoAlive(enabled:pipActive:state:)` and is gated to iOS (tvOS always tears down, wedge-safe: a frozen decode session crossing a multi-hour suspension wedged `mediaserverd`). On the native path "keep audio alive" is just declining to tear down: `AVPlayer` under the `.playback` session keeps decoding. The software path has no `AVPlayer`, and its combined demux loop normally paces the whole loop (audio and video) on the video renderer's `isReadyForMoreMediaData`; once `AVSampleBufferDisplayLayer` stops draining in the background that gate never reopens and audio would starve. So the host enters `backgroundAudioOnly`: the loop drops video packets and paces on the audio renderer (`AudioOutput.isReadyForMoreMediaData`) instead, keeping `AVSampleBufferAudioRenderer` fed and the synchronizer advancing. On foreground return the flag clears, the video decoder and renderer flush, and video resyncs at the next keyframe with audio uninterrupted. Scope is the combined VOD loop (and live-without-DVR, which shares it); the DVR feeder loop is unchanged. Exercise it headless with `aetherctl bgaudio` (see [cli.md](cli.md)).

**Live audio look-ahead + edge rebuffer (#107 audio chopping).** The DVR feeder loop shares the pacing coupling above: audio is interleaved behind the video renderer's back-pressure gate, so the audio renderer could never hold more than the video queue allows (<1 s measured). On devices where software 1080i decode + deinterlace runs near real time that margin is zero and every feeder stall is an audible dropout. The feeder therefore runs an audio look-ahead pump (`AudioLookaheadPolicy` + `AudioLookaheadState`): an independent ring cursor that decodes and enqueues audio packets ahead of the combined cursor until the renderer holds `targetLeadSeconds` (4 s) over the synchronizer clock, making audio delivery independent of video decode pace (a chronically slow video decode now degrades to late video frames under smooth audio, the right priority). DVR seeks reset the pump cursor alongside `setFeedCursor` (compare-and-set, seek wins). The same pump pass handles live-edge source underruns: when the source itself delivers below real time and the pump drains the ring at the edge, the free-running clock would otherwise outrun the stream permanently (every later sample lands in the clock's past, continuous chopping that never recovers). `AudioLookaheadPolicy.clockAction` pauses the clock at `underrunPauseLeadSeconds`, refills, and resumes at `rebufferResumeLeadSeconds`, mirroring AVPlayer's stall handling on the native path. Diagnose with `aetherctl play --audio-stats` (see [cli.md](cli.md)).

**Paused-background grace window (iOS, #127).** A paused session used to tear down the moment the app backgrounded, so a 10-30 s app switch paid a full pipeline rebuild (demuxer reopen, segment-plan scan, AVPlayer item reload). The teardown is now deferred by `backgroundTeardownGraceSeconds` (default 15 s, 0 restores the immediate teardown) held under a `UIBackgroundTask` assertion; `didBecomeActive` cancels the window, so a quick switch resumes on the live pipeline. At expiry the action is re-evaluated (PiP can start and lock-screen play can resume mid-window) and the teardown runs while the app is still genuinely running, never across an idle suspension; the assertion's expiration handler is a synchronous backstop. The step decision is the pure `backgroundStep(action:state:supportsGraceWindow:graceSeconds:)`; a PLAYING teardown (background playback disabled) stays immediate because its audio would keep sounding through the window, and tvOS keeps the unconditional teardown. Two hardening pieces ship with it: host seeks that arrive while the (re)built AVPlayer item is pre-ready are deferred (`shouldDeferHostSeek`) and the latest replays at readiness (an early seek clamps to 0 against empty seekable ranges and replaces `load()`'s own startPosition seek), and hosts observe the published `isSessionReady` to gate corrective actions (restore watchdogs, position clamps) instead of inferring readiness from `currentTime` being pinned at 0.

### Audio-only pipeline (music, podcasts, audiobooks)

When the host sets `LoadOptions.audioOnly`, the engine skips the video machinery entirely: no HLS loopback server, no segment producer, no display layer. Decode is native-first. Codecs on the `avPlayerCanDecodeAudio` whitelist hand the source URL straight to a bare `AVPlayer` (`AudioAVPlayerHost`); everything else demuxes through libavformat and decodes through libavcodec into an `AVSampleBufferAudioRenderer` (`AudioPlaybackHost`). Transport (`play` / `pause` / `seek`) routes to the active host, and `stopInternal` tears it down for a clean handoff back to the video path on the next load.

```
audioOnly == true
   ├─ whitelisted codec ──► AVPlayer (AudioAVPlayerHost) ──► AVR / speakers
   └─ otherwise          ──► Demuxer ──► AudioDecoder ──► AVSampleBufferAudioRenderer ──► AVR / speakers
```

On tvOS and iOS the AVPlayer audio host owns a persistent per-player `MPNowPlayingSession` (exposed via `audioNowPlayingSession`) so the system Now-Playing overlay stays bound to the app across a background pause, auto-publishes now-playing info from the player, and carries `externalMetadata`. The host survives across tracks and does not pause when the app backgrounds. All of this is gated `#if os(tvOS) || os(iOS)`; on macOS the path compiles and plays without the system session (a macOS host drives Now-Playing through the shared centers itself).

The native VIDEO host can own the same kind of session, but only on request (`ownsVideoNowPlayingSession`, default off, read when a host is created). The asymmetry is deliberate: the audio path is always a bare AVPlayer, whereas the video player is consumed both by custom-transport hosts and by `AVPlayerViewController` hosts, and AVKit owns Now-Playing there through its own private registration. A session claimed underneath AVKit costs that host its identity card and its working transport commands, so ownership is the host's call. When it is taken, the session lives on `NativeAVPlayerHost` and therefore survives native->native reloads with it (issue #15), and `setVideoNowPlayingInfo(_:)` stages the identity dictionary that is replayed onto every fresh `AVPlayerItem` (readiness-gate master reloads, media fallback, in-place PiP swaps).

### Audio tap (#95)

`installAudioTap()` returns an `AsyncStream<AudioTapBuffer>` of decoded playback audio: mono Float32 48 kHz (`AetherEngine.audioTapFormat`), stamped with source-PTS seconds (`sourceTime`, same axis as `engine.sourceTime`), with a `discontinuity` flag on any gap (seek, eviction, track switch, drops under pressure). Intended for host-side speech features (live transcription via SpeechAnalyzer) and audio recognition (ShazamKit signatures).

Native path: a loopback reader (`LoopbackAudioReader`) pulls the engine's own muxed fMP4 segments from the segment cache near the playhead and decodes their audio track out-of-band (libavcodec + libswresample, fresh per-segment demux context). Because it reads the mux, it follows the active audio track for free (the mux contains exactly the selected track, post-bridge), adds zero network load, and cannot stall playback by construction. Remote-HLS path (direct AVPlayer ingest, no loopback, VOD and live): `AudioTapHLSVariantResolver` picks the active audio rendition / muxed variant, `AudioTapHLSFetcher` fetches and decrypts (AES-128 clear-key) self-contained TS / fMP4 segments (sending `LoadOptions.httpHeaders`, same as the player's asset, #119), and a playhead-follow reader (`AudioTapHLSReader`) decodes them near the playhead; `AudioTapReaderSelection` makes the per-session reader choice, and `audioTapHasDeliverySource` tells the host whether the current session can deliver at all (fail-loud). Software path: the existing `AudioDecoder` PCM output is mirrored through an `AVAudioConverter` sink on `SoftwarePlaybackHost`. One tap per engine; re-install replaces the previous stream, and `load()` / `stop()` finish it (opt-in is per load; with no session or a video-only source the stream finishes immediately). Delivery is lossy under pressure (`bufferingNewest(64)`); live sources are best-effort.

```
native ──► SegmentCache (init + seg N) ──► mov demux ──► libavcodec ──► swr (mono 48k) ──► AsyncStream
software ──► AudioDecoder CMSampleBuffers ──► AVAudioConverter (mono 48k) ──► AsyncStream
```

### Playback status (`playbackPhase`)

`AetherEngine.playbackPhase` is the single observable for what playback is doing right now, across all three pipelines. It is *derived*, not a parallel state machine: a pure fold of `state`, `isBuffering`, `isSeeking`, and a typed source-reconnect axis, recomputed on every input change so it can never desync from them. Each input's `didSet` triggers an idempotent recompute that re-emits only on an actual change.

Precedence (highest first): `error > ended > idle > loading > seeking > stalled > rebuffering > playing/paused`.

- `.rebuffering` is a healthy-connection buffer underrun (AVPlayer waiting to play); `state` stays `.playing` across it.
- `.stalled(reconnecting:)` is a source-connection problem (drop / 429 / 503 backoff) where the `AVIOReader` is retrying. It is promoted from log text to a typed signal: the reader pushes a `flowing` / `reconnecting` phase through `Demuxer.onNetworkPhaseChanged`, the owning host (`HLSVideoEngine` on the native path, the software / audio hosts directly) forwards it, and the engine hops it to the main actor. The flag is `true` whenever the reader is reconnecting; the `false` case is reserved for a future "stalled, retries paused" distinction. The native text subtitle readers (WebVTT rendition prefetch) are deliberately left unwired so their stalls never move `playbackPhase`; the overlay itself is fed from the main read via the subtitle packet tap and has no connection of its own.
- The direct AVPlayer-HLS live path (`nativeRemoteHLS`) and the whitelisted-codec audio host (`AudioAVPlayerHost`) have no demuxer / `AVIOReader`, so they cannot report `.stalled`; a reconnect there reads as `.rebuffering`.

Hosts should observe `$playbackPhase` instead of combining `state == .loading`, `$isBuffering`, and `$isSeeking`, and instead of regex-matching `EngineLog` for stall / reconnect, which is no longer needed.

### Effective video route (`videoRoute`)

`LoadOptions.nativeRemoteHLS` records what the host asked for. It is not what ends up serving the session: the engine reroutes on its own findings, and `playbackBackend` cannot tell the two native pipelines apart because both are `.native`. `AetherEngine.videoRoute` publishes the pipeline actually running, derived the same way `playbackPhase` is (a pure fold over `playbackBackend` and the session's effective options, recomputed from each one's `didSet`, re-emitted only on a real change), so it cannot become a second opinion about the session.

- `.remoteBypass` is AVPlayer on the origin URL: no demuxer, no local server. AVFoundation owns media selection, buffering, and subtitle drawing.
- `.loopback` is the demuxer plus the local HLS-fMP4 server, the default video route. The engine owns the source connection and the subtitle pipeline.
- `.software`, `.audio` and `.none` mirror the corresponding backends.

Routes the host did not ask for:

| Transition | Trigger |
| --- | --- |
| `.remoteBypass` -> `.loopback` | #168 carriage watchdog: readyToPlay, but no video track for a master that advertises one (HEVC in MPEG-TS). Mid-session. |
| `.remoteBypass` -> `.loopback` | #199: the same master's verdict is remembered, so the next load skips the doomed mount entirely. At load time. |
| `.remoteBypass` -> `.loopback` | AE#268: the playlist plus the first segment's PMT identify a finite HEVC-in-MPEG-TS VOD. At load time. |
| `.loopback` -> `.remoteBypass` | AE#154 / AE#246: an HLS playlist reached the loopback path, which cannot demux it. At load time. |

Branch on this where host behaviour differs per pipeline: who draws subtitles (AVPlayer on the bypass, the host's renderer on loopback and software), and whether a composited PiP overlay is meaningful at all. Observing it also makes the mid-session reroute an event rather than a log line.

## SwiftUI `Menu` in custom player chrome

On tvOS 26, the focused row of an open SwiftUI `Menu` blinks whenever any SwiftUI render transaction runs in the hosting tree, even one fully contained in an unrelated leaf view (a `TimelineView(.periodic)` wall clock, a playbar observing `engine.clock`, a subtitle overlay). Minimal repro: a `Menu` next to a `TimelineView(.periodic(from: .now, by: 1))`, open the menu, the focused item blinks once per second. This is a SwiftUI issue, not an engine one; reported to Apple by an AetherEngine adopter (see [AetherEngine#29](https://github.com/superuser404notfound/AetherEngine/issues/29)).

The engine keeps its own surfaces out of the blast radius by splitting every continuously ticking value off the engine's `ObservableObject` (`engine.clock` at ~10 Hz, `engine.diagnostics` at 1 Hz). But a player UI always has something ticking, so if your custom chrome needs a dropdown while playback runs, build the menu button in UIKit and let SwiftUI host it. `UIButton` with `button.menu` + `showsMenuAsPrimaryAction` renders the same system menu as SwiftUI's `Menu` (public API since tvOS 17), and a `UIViewRepresentable` wrapper can guarantee the open dropdown is never rebuilt:

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

SwiftUI diffing can re-run `updateUIView` as often as it likes; the guard means an open menu only rebuilds on a real item change. Credit to [@ohjey](https://github.com/ohjey) for isolating the mechanism and the pattern (AetherEngine#29).

## Source map

```
Sources/AetherEngine/
├── AetherEngine.swift                       Engine core: stored state, load dispatch, transport, stop/seek, track selection
├── AetherEngine+Probe.swift                 Static probe machinery: probe(url:/source:), probeDetectingAtmos(url:/source:), swDecodeProbe, format / frame-rate / codec-label detection
├── AetherEngine+Loading.swift               The per-backend loaders (remote-HLS, native, software, audio, audio-native) + reload
├── AetherEngine+Subtitles.swift             Embedded + external subtitle pipeline (packet-store drainer, cue apply / prune, external track registry + unified selection routing, #88). Every embedded stream is tapped off the session demuxer into `SubtitlePacketStore`; a playhead-paced drainer decodes the selected stream (both channels, text and bitmap, VOD and live) into the overlay, riding producer seeks/restarts by construction, which replaced the side-demuxer reader and its recovery machinery outright (#112 rework); a VOD-only forward prefetcher extends store coverage past the producer park to the 60 s drain lead for host advance sync offsets (#151); side readers yield the source link to the video path while it is fetching or seeking (#240, `SideReaderLinkPolicy`); the drain tick states how far display-state determination has advanced on the absolute source axis, fenced by load + seek generation, so a host or conformance harness can tell "determined, and empty" from "not read yet" (#250, `AetherEngine+SubtitleResolution.swift`)
├── AetherEngine+ClosedCaptions.swift        In-band CEA-608 closed captions + A53/SEI extraction: ClosedCaptionTap (read-only producer observer) + cue mirroring (#77, #131)
├── AetherEngine+Live.swift                  Live window publishing, edge snap, resume clamp, scrub thumbnails
├── AetherEngine+Diagnostics.swift           Memory probe + live-telemetry bridge
├── AetherEngine+SubtitleResolution.swift    Emission of the #250 subtitle-resolution statement: one generation-fenced line stating the absolute source-time span display state has been decoded over, at post-seek reconstruction, the 30 s cadence, prefetcher EOF, any change of frontier source, and the tick where determination first reaches the playhead (`reason=coverage`, #318); `retainedFrom=` additionally states the floor of the run RETAINED across seeks, so "empty because nothing was ever authored before this point" is provable from a post-seek line alone (#276)
├── AetherEngine+AudioTap.swift              Opt-in decoded PCM audio tap (#95): installAudioTap() vends the AsyncStream, dispatches native-loopback vs remote-HLS vs SW-mirror
├── AetherEngine+BackgroundAudioTestHooks.swift DEBUG-only hooks letting aetherctl bgaudio toggle the SW background-audio keepalive without a UIApplication lifecycle (never shipped)
├── PlaybackClock.swift                      engine.clock: the ~10 Hz ticking values (currentTime, sourceTime, bufferedPosition, progress, live-edge fields) as a separate ObservableObject
├── PresentationAxis.swift                   Display-axis fold for disc titles (source PTS <-> 0-based published axis, AE#105)
├── PresentationAxisMap.swift                Source axis <-> item axis (#260): the seam history of producer shifts as a piecewise-constant map, plus its off-main mirror. Written by the shift-changed / rebased handlers, read by the clock fold, the live thumbnail path and hosts
├── NativeVideoFrameTime.swift               Per-muxed-frame presentation times on both axes (#260): the value type + observer typealias; emitted from HLSSegmentProducer.finalizeAndWriteVideo
├── SoftwareVideoFrameTime.swift             Per-enqueued-frame presentation time on the software path (#311): one axis (source == presentation there), plus a flush generation that a seek moves; emitted from SampleBufferRenderer.flushFrame
├── AetherEngine+FrameTimes.swift            Public installers for both per-frame time observers (native re-armed on each session, software on each host) plus `softwarePresentationTimebase`, the render synchronizer's clock
├── FrameTimeSequence.swift                  Process-wide monotonic allocator behind NativeVideoFrameTime.epoch and SoftwareVideoFrameTime.generation (#314), so the ordering rule holds across a load() and not only inside one session
├── PlayerState.swift                        PlaybackState, PlaybackPhase, VideoFormat, PlaybackBackend, LoadOptions, SourceProbe, TrackInfo, FontAttachment, MediaMetadata, SubtitleCue, SubtitleImage
├── LiveReloadPolicy.swift                   Pure decision functions for live reloads: rejoin at the live edge (no stale resume position), skip the pre-readiness zero seek
├── TransportControllable.swift              Common transport surface of the four playback hosts (single active-host dispatch)
├── FFmpegErrorConstants.swift               AVERROR sentinels Swift can't import from the C macros
├── Audio/
│   ├── AtmosConfirmationWorker.swift        LoadOptions.confirmAtmos: runs the bounded JOC pass on a side demuxer after the session is up, one E-AC-3 track at a time, and republishes audioTracks via a source-keyed ledger (#214)
│   ├── AtmosDetectionProbe.swift            Opt-in bounded E-AC-3 JOC decode pass behind probeDetectingAtmos: AtmosDetectionOptions caps, one decoder, no playback session (#214)
│   ├── AudioAVPlayerHost.swift              Audio-only path: bare AVPlayer host for whitelisted codecs, owns the persistent per-player MPNowPlayingSession (tvOS / iOS)
│   ├── AudioBridge.swift                    Native path: decode + re-encode per `AudioBridgeMode` (EAC3 5.1 default or lossless FLAC opt-in) for source codecs that can't stream-copy into fMP4
│   ├── AudioClockAnchor.swift               SW path: sample-count PTS anchor so consecutive buffers abut exactly; re-anchors on >100 ms drift (AVSampleBufferAudioRenderer crackle, #89)
│   ├── AudioDecoder.swift                   SW path: libavcodec → PCM → CMSampleBuffer with channel-layout tagging
│   ├── AudioOutput.swift                    SW path: AVSampleBufferAudioRenderer + Synchronizer (master clock)
│   ├── AudioPlaybackHost.swift              Audio-only path: FFmpeg demux + decode into AVSampleBufferAudioRenderer for codecs off the whitelist
│   └── Tap/
│       ├── AudioTapController.swift         Lifecycle owner for one tap: owns the AsyncStream continuation + (native path) the LoopbackAudioReader; one per engine, re-install replaces it (#95)
│       ├── AudioTapDecoder.swift            FFmpeg decode of tap packets into mono Float32 48 kHz AVAudioPCMBuffers (lazy resampler, own lock discipline)
│       ├── AudioTapPCMConverter.swift       SW path: AVAudioConverter sink mirroring AudioDecoder PCM into the tap's mono 48 kHz format
│       ├── AudioTapTypes.swift              AudioTapBuffer value type (single-consumer @unchecked Sendable) + pure loopback pacing decision
│       ├── AudioTapHLSVariantResolver.swift Remote-HLS tap: resolves the active audio rendition / muxed variant from the master playlist (#95)
│       ├── AudioTapHLSFetcher.swift         Remote-HLS tap: segment fetch + AES-128 clear-key decrypt for self-contained TS / fMP4 segments (#95)
│       ├── AudioTapHLSReader.swift          Remote-HLS tap worker: playhead-follow reader decoding fetched segments (VOD + live) (#95)
│       ├── AudioTapReaderSelection.swift    Pure per-session reader choice (loopback vs remote-HLS vs none) backing audioTapHasDeliverySource (#95)
│       └── LoopbackAudioReader.swift        Native-path tap worker: pulls fMP4 segments from SegmentCache near the playhead, decodes their audio out-of-band on a utility thread (cannot stall playback)
├── Decoder/
│   ├── A53ReorderBuffer.swift               Decode-to-presentation reorder for SEI caption groups (#131)
│   ├── A53SEIParser.swift                   A53/GA94 cc_data extraction from H.264/HEVC SEI NALs (#131)
│   ├── CCDataParser.swift                   Parses the bare cc_data triplet stream from a demuxable CEA-608 caption track (#77)
│   ├── CEA608Decoder.swift                  In-house CEA-608 line-21 decoder (field-1 / CC1), validated against FFmpeg ccaption_dec.c (#77)
│   ├── DeinterlaceFilter.swift              SW path: persistent bwdif / yadif libavfilter graph, engages on the first interlaced frame
│   ├── EmbeddedSubtitleDecoder.swift        Inline subtitle decode from demuxed packets; opens DVB teletext with libzvbi_teletextdec text-format options (#107)
│   ├── InterlaceProbe.swift                 Decodes a sample and applies the deinterlacer's own engagement predicate, so a declared field order that no frame backs up (PsF) stops costing a SW decode (#232)
│   ├── VideoRoutingPolicy.swift             Pure codec-and-field-order dispatch rule: AV1 gated on HW, VP9/VP8/MPEG4/MPEG2/VC1 always SW, interlaced H.264 SW so bwdif can deinterlace (#107, verified against decoded frames on VOD, #232), plus a second-stage gate routing H.264 High 4:2:2/4:4:4/10 + HEVC Rext to SW where VideoToolbox has no HW decoder (#2)
│   ├── HardwareVideoDecoder.swift           SW path: VideoToolbox HW HEVC / AV1 decoder for sources routed away from AVPlayer
│   ├── SoftwareVideoDecoder.swift           SW path: libavcodec/dav1d → CVPixelBuffer (NV12 / P010), HDR10+ side data
│   ├── SubtitleDecoder.swift                Sidecar URL one-shot decode (text only); decodes several streams of one container in a single pass (#266)
│   └── VideoDecoderTypes.swift              DecodedFrameHandler typealias + VideoDecoderError
├── Demuxer/
│   ├── AVIOProvider.swift                   Internal seam over a custom-AVIO byte source; AVIOReader and CustomIOReaderBridge both plug into the Demuxer through it, incl. the bounded-seek read deadline and the resolved byte size backing the byte-estimate seek fallback (#112)
│   ├── AVIOReader.swift                     URLSession-backed avio_alloc_context, three modes: persistent forward-streaming connection with reconnect-on-drop (playback, incl. live), discrete Range chunks (still extraction), single sequential GET with backpressure (non-live sources without Content-Length). Optional read deadline bounds a degenerate matroska Cues seek. Cold start on a non-faststart MP4 keeps the open window across the parse seek to the trailing moov (so the return trip to the first sample is a copy, not a third connection) and issues one speculative 64 KB suffix range alongside the open, rejected at the response header unless it is a well-formed 206. A read landing in that range waits for the fetch rather than connecting past it, bounded by the measured cost of one round trip against the origin, because the demuxer reaches the tail before a fetch issued at the same instant can land (#281)
│   ├── ResidentSpan.swift                   Bytes already in memory that a read can be served from without a round trip: the open window parked across a parse seek, and the speculative tail fetch. Not a cache (no fetch-on-miss, no eviction, no block alignment); it either covers an offset or it does not (#281)
│   ├── CustomIOReaderBridge.swift           Bridges a host-supplied IOReader into avio_alloc_context read / seek callbacks, with the same read deadline and reversible read abort as AVIOReader so bounded seeks also bound (and unwedge) disc-adapter sources
│   ├── Demuxer.swift                        libavformat wrapper; seek + bounded seek (deadline-capped) + byte-estimate positioning fallback for index-less containers (origin-corrected onto the file-relative time axis, fixed early bias in seconds, landing verified by a packet-PTS probe with proportional correction, and a sticky per-demuxer timestamp-seek lockout once the mechanism proves broken, #112). Per-open `DemuxerOpenProfile` budgets `find_stream_info` (probesize / max_analyze_duration), caller-overridable on the main playback open via `LoadOptions.probesize` / `maxAnalyzeDuration`. The native text readers' side demuxer sets `skipStreamInfo` to drop the `find_stream_info` pass entirely (codec_id / codec_type come from the container header / PMT at open); the reader runs a bounded `resolveStreamInfo()` on demand only if its target stream's codec is genuinely unresolved at open (#87)
│   ├── RedirectHeaderPolicy.swift           Per-header redirect replay policy for AVIOReader's URLSession delegates: Range and non-credential extra headers survive cross-host redirects (header-dependent proxies, #8), credential headers (Authorization, Cookie, Emby/Jellyfin tokens) are replayed only to a same-host target with no TLS downgrade and scrubbed otherwise, so presigned redirect targets neither 400 on conflicting auth nor see the media-server token (#126)
│   ├── SlowReadDiagnostics.swift            One-shot localization of a pathologically slow AVIOReader.read() (detour fetch / connStall / reconnect / backoff / dropped-generation bytes), #93 restart latency
│   └── SourceThrottle.swift                 Pure virtual-clock leaky-bucket rate limiter on the source read path (slow-CDN simulation for aetherctl --throttle); unit-testable without sleeping
├── Diagnostics/
│   ├── EngineDiagnostics.swift              engine.diagnostics: timer-sampled values (liveTelemetry) as a separate ObservableObject
│   ├── EngineLog.swift                      Gated OSLog emission with severity levels (.verbose suppressed from default + host handler)
│   ├── FFmpegLogBridge.swift                av_log_set_callback funnel: FFmpeg's internal warnings surface through EngineLog
│   ├── LiveTelemetry.swift                  Value type emitted at 1 Hz: instant / avg bitrate, buffer, network, dropped frames, observed FPS, A/V sync gap, plus subsystem byte counters. The software path reports its own read bytes, throughput, reader runway (`readerWindowAheadBytes`), decoded cushion (`displayCushionSeconds`) and dropped / late frames (#306); `forwardBufferSeconds` stays nil there because a renderer-back-pressured pump holds no seconds-deep reservoir to report
│   ├── FourCC.swift                         Printable FourCC rendering for codec-tag diagnostics
│   ├── LiveTelemetrySampler.swift           @MainActor 1 Hz sampler that reads existing subsystem counters and assembles LiveTelemetry snapshots
│   ├── PacketBalanceTracker.swift           Process-wide AVPacket alloc/free balance counter for leak diagnostics
│   ├── SubtitlePrefetchTelemetry.swift      Live gauge for the #151 forward prefetcher (lead, park, link yield, exit reason) + the #250 fence its banked read position belongs to
│   ├── SubtitleResolutionStatement.swift    Value + formatter for the #250 line: decode window clamped to a fenced harvest frontier, with the frontier's source (`via=prefetch|eof|pump`) travelling alongside so the number's worth is legible
│   ├── PacketTimingProbe.swift              Offline differential probe (#93 judder): raw demuxer packet timing per open profile, before NOPTS repair / muxing; backs aetherctl pktdump
│   └── AudioTapProbe.swift                  Headless native-session tap verification (#95): LoopbackAudioReader decode to mono 48 kHz WAV; backs aetherctl audiotap
├── Disc/
│   ├── DiscReader.swift                     Disc detection + routing: local `.iso` URLs and custom ISO readers into the demux path; enumerates titles and threads the selected one (DVD vs Blu-ray)
│   ├── DiscMetadata.swift                   Public `TitleInfo` / `ChapterInfo` plus the internal disc title + chapter model (45 kHz ticks, extent keys)
│   ├── ISO9660Reader.swift                  Read-only ISO9660 bridge-filesystem reader (DVD-Video images)
│   ├── DVDIFOParser.swift                   DVD VMGI TT_SRPT title list + each VTS IFO program chain (per-title duration + chapters)
│   ├── DVDTitleSelector.swift               Groups DVD title sets' content VOBs into selectable titles (whole-VTS, largest first)
│   ├── ConcatIOReader.swift                 Synthetic seekable IOReader concatenating byte extents (DVD VOBs / Blu-ray M2TS clips) into one source
│   ├── UDFReader.swift                      Read-only UDF 2.50 reader (Blu-ray BDMV, including the metadata partition and fragmented-file allocation descriptors)
│   ├── MPLSParser.swift                     Blu-ray `.mpls` playlist parser (clips, duration, PlayListMark chapters)
│   ├── BDTitleSelector.swift               Enumerates Blu-ray playlists as selectable titles (longest first; short menu / decoy playlists filtered)
│   ├── DiscRecognitionCache.swift           Memoises `DiscReader.wrap` per URL + title index so disc recognition does not re-run on every subtitle / track switch (load-bearing for remote-ISO track switches, #76)
│   └── DiscInspector.swift                  Diagnostic mirror of `DiscReader.wrap` for `aetherctl disc-inspect` (titles, chapters, recognition stages)
├── Display/
│   ├── DisplayCriteriaController.swift      AVDisplayManager content-rate / dynamic-range hints (native path)
│   └── FrameRateSnap.swift                  Snap to standard rates (23.976, 24, 25, 29.97, 30, 50, 59.94, 60)
├── FrameExtractor/
│   ├── AetherEngine+FrameExtractor.swift    makeFrameExtractor() convenience for the currently loaded URL
│   ├── DolbyVisionStillConverter.swift      Applies the RPU-carried DV colour transform to a DV P5 / P10.0 base-layer frame (IPT-PQ-C2, not YCbCr) so scrub stills lose the green + magenta cast (#103)
│   ├── FrameExtractor.swift                 Off-playback still extraction actor: serial decode queue, cancel-supersede, idle-close
│   ├── FrameDecodeContext.swift             Isolated FFmpeg demux + decode + sws_scale → CGImage (thumbnail / snapshot)
│   ├── FrameCache.swift                     Bounded LRU: mode-isolated stores, second-bucketed thumbnails
│   ├── FrameTypes.swift                     FrameMode (.thumbnail / .snapshot)
│   └── HDRToneMapper.swift                  zscale + tonemap libavfilter graph: HDR (PQ / HLG, BT.2020) stills → SDR BT.709
├── IO/
│   ├── IOReader.swift                       Public custom byte-source protocol + MediaSource (load(source:) input)
│   ├── DataIOReader.swift                   Ready-made in-memory IOReader over an immutable Data buffer
│   ├── FileIOReader.swift                   Seekable IOReader over a local file via FileHandle (multi-GB ISO images)
│   ├── HTTPDiscIOReader.swift               Seekable IOReader over a remote HTTP(S) disc image with adaptive read-ahead (the network-ISO counterpart to FileIOReader)
│   └── HLSIngest/
│       ├── HLSLiveIngestReader.swift        Public forward-only IOReader ingesting a live HLS upstream (resolver, playlist poller, segment fetcher, companion audio-rendition reader)
│       ├── HLSPlaylist.swift                Line-oriented RFC 8216 subset parser (master / media playlists)
│       ├── HLSPlaylistTracker.swift         Pure segment cursor: duration-capped edge join, window-slide rejoin, stall budget
│       ├── HLSSegmentDecryptor.swift        AES-128-CBC clear-key segment decryption (key fetch + memoise, PKCS7)
│       ├── PackedAudioSegments.swift        Packed-audio rendition support: LiveSegmentFormat classification + ID3 PRIV timestamp parser (raw ADTS segments)
│       ├── ByteFIFO.swift                   Bounded blocking byte queue between the fetch loop and the demux thread
│       ├── HLSIngestError.swift             Typed terminal errors (encrypted, fMP4, unreachable, invalid, stalled)
│       └── LiveIngestSourceInfo.swift       Internal seam: upstream segment cadence (shapes TARGETDURATION + blocking-reload eligibility) and DualSourceMergeOrder for the dual-source DTS merge
├── Native/
│   ├── AudioLookahead.swift                 SW live feeder audio look-ahead pump policy + cursor state: audio lead decoupled from video decode pace, live-edge underrun rebuffer (#107)
│   ├── Issue93ItemDeathRevive.swift         Bounded revive budget (`ItemDeathReviveGate`) for items killed by accumulated -12889 media timeouts (`failedToPlayToEndTime`, #93 round 3)
│   ├── MasterFallbackDecision.swift         Pure master → media playlist fallback decision (#98, #130): maps a master-rejection item failure (-11868 external-SDR, -11848 HDR-on-SDR, -1002 all variants filtered at parse) to a reactive re-serve
│   ├── NativeAVPlayerHost.swift             Native path: AVPlayer host bound to the loopback HLS-fMP4 URL; awaits real seek landing (deadline-bounded, first resume wins, #129), suppresses stale clock during in-flight seek
│   ├── RemoteHLSMediaSelection.swift        Remote-HLS bypass (#154): pure loopback→bypass reroute decision for non-live m3u8 sources (FFmpeg has no network) + legible AVMediaSelectionGroup → `subtitleTracks` mapping (synthetic ids from 200000)
│   └── SoftwarePlaybackHost.swift           SW path: demux loop + decoders + renderer + synchronizer orchestration
├── Network/
│   └── HLSLocalServer.swift                 Native path: local HTTP server (127.0.0.1) serving playlist + segments
├── Renderer/
│   └── SampleBufferRenderer.swift           SW path: AVSampleBufferDisplayLayer + B-frame reorder, HDR10+ attachments; `flush(removingDisplayedImage:)` holds the last frame through a seek (`DisplayFlushOp`, #90)
├── Subtitles/
│   ├── ASSScriptBuilder.swift               Reassembles raw ASS event cues + TrackInfo.assHeader into a complete script for whole-file renderers
│   ├── ExternalSubtitleTrack.swift          Host-facing descriptor for external subtitle files registered as first-class tracks (synthetic TrackInfo ids, #88; sourceStreamIndex addresses one stream of a container URL, #266)
│   ├── Issue100PGSStaleArrival.swift        Holdback (`PGSStaleArrivalGate`) for PGS cues arriving behind the playhead: catch-up bursts resolve via their successor's trim instead of flashing open-ended placeholder windows through the overlay (#100)
│   ├── MovTextSampleBuilder.swift           Stateless tx3g (mov_text) sample builder for the native legible-subtitle injection path (LoadOptions.prepareNativeSubtitles, #55)
│   ├── NativeSubtitleCueStore.swift         Owns the decoded-cue array behind a native WebVTT subtitle rendition + the overlay tap feed; deduped, filled by the pump tap (embedded) or one whole-file decode (load-declared external, #88) (#55, Sodalite#32)
│   ├── SubtitleRectText.swift               Plain-text + raw ASS event-line extraction from subtitle rects, shared by the inline and sidecar decoders
│   └── WebVTTBuilder.swift                  Builds a plain-text WebVTT body (ASS markup stripped) on the AVPlayer timeline for the separate HLS SUBTITLES rendition so AVKit renders subs in PiP (#15, #55)
├── Video/
│   ├── HLSVideoEngine.swift                 Native path: session orchestrator (start/stop, producer construction + restart, shift handling)
│   ├── HLSVideoEngine+AudioRoute.swift      Native path: stream-copy -> FLAC-bridge -> video-only audio cascade
│   ├── HLSVideoEngine+SegmentPlanning.swift Native path: keyframe / uniform segment plans, extradata + AAC fixups
│   ├── HLSVideoEngine+LiveReopen.swift      Native path: live source-loss recovery (capped-backoff reopen on the same timeline); VOD backpressure-wedge re-anchor + consumer re-engage nudge, which re-reads the rendered position at nudge time so the zero-tolerance seek never lands behind the on-screen frame (#115)
│   ├── CodecRoutePolicy.swift               Native path: DV / HDR / codec routing decisions (track types, CODECS strings, VIDEO-RANGE)
│   ├── DoviRpuConverter.swift               Native path: per-packet DV Profile 7 → 8.1 RPU conversion via libdovi (NAL surgery: convert type-62 RPU, drop type-63 EL)
│   ├── DoviRpuConverter+Probe.swift         Diagnostic DV-conversion probe (`doviConvertProbe` / `DoviConvertProbeResult`), backs `aetherctl dovitest`
│   ├── Issue65LivelockBreakers.swift        Pure backpressure-wedge detection (`BackpressureWedgeDetector`) breaking the VOD HLS scrub-burst livelock (#65); `seekIsWedged` starvation check + `SeekResumeGuard` single-resume latch for the deadline-bounded seek
│   ├── Issue99MuxerFailureRevive.swift      Bounded revive for a VOD pump that died with `muxerFailed` (#99): the first cut firing before any bridged audio reached the muxer (dec3 box) no longer ends the session
│   ├── SlowServeSignal.swift                One-shot slow-serve timer arming the server's early chunked header (keeps TTFB under AVPlayer's ~3.5 s -12889 window, #93 round 3)
│   ├── VideoSegmentProvider.swift           Native path: playlist-facing segment provider (live sliding window, restart heuristics, producer-coverage-gated sparse-hole waits #129)
│   ├── HLSSegmentProducer.swift             Native path: pump loop reading from Demuxer, feeding MP4SegmentMuxer, cutting fragments keyframe-gated in decode order so the IRAP opens its segment (#92); SSAI program-switch detection + no-cut watchdog
│   ├── VODSegmentCutter.swift               Native path: decode-order, keyframe-gated VOD segment cutter (the IRAP opens its segment, #92)
│   ├── H264SPS.swift                        Hand-rolled H.264 SPS parser (SSAI ad-creative coded dimensions / codec config)
│   ├── OutputTimestampSanitizer.swift       Final-stage DTS/PTS monotonicity guard before the fMP4 mux (SSAI splices, program restarts)
│   ├── RestartCoalescer.swift               Coalesces a burst of producer-restart requests into one in-flight + one settled target (rapid-seek, AetherEngine#35)
│   ├── LiveWindow.swift                     Live path: session-relative DVR timeline (seconds since first frame), shared by the native and SW live paths
│   ├── MP4SegmentMuxer.swift                Native path: session-long fragmented-MP4 muxer (+empty_moov+default_base_moof+frag_custom+delay_moov)
│   ├── FragmentSplitter.swift               Native path: routes mp4 muxer's avio output stream into init.mp4 (ftyp+moov) vs per-segment moof+mdat files
│   ├── PacketRingBuffer.swift               Live path: keyframe-indexed, disk-spooled packet ring backing the SW-path DVR rewind
│   ├── SegmentCache.swift                   Native path: producer/consumer segment store with backpressure, scrub-aware eviction + byte-budgeted VOD backward retention (restart-free back-seeks)
│   └── VTCapabilityProbe.swift              AV1 system-decode probe + per-format `canHardwareDecode` HW-decodability check for H.264 / HEVC profiles (Intel Macs, older chips, #2); gates codec routing (VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 and interlaced H.264 always route SW, see VideoRoutingPolicy)
└── View/
    └── AetherPlayerView.swift               Polymorphic surface: hosts either AVPlayerLayer (native) or AVSampleBufferDisplayLayer (SW)
```

The `AetherEngineSMB` product is a separate, opt-in target so its SMBClient (MIT) dependency never enters the core engine binary. Hosts that need LAN-share playback link it and hand the engine an `smb://` source via the standard `IOReader` seam:

```
Sources/AetherEngineSMB/
├── AetherEngineSMB.swift                    Product entry point: opt-in SMB2/3 byte source, depends on SMBClient (pure-Swift, NWConnection); never linked by the core engine
├── SMBURL.swift                             Parses smb://[user[:password]@]host[:port]/share/path URLs (missing credentials default to guest)
├── SMBConnection.swift                      Read-only SMB byte source over one share + path via SMBClient (persistent connection + FileReader; NTLMv2 / guest, SMB 2.0.2 / 2.1 only)
├── ByteRangeSource.swift                    Random-access read-only byte-source protocol, isolates the network backend from cursor / seek logic for testability
└── SMBIOReader.swift                        Bridges a ByteRangeSource into the engine's IOReader (blocking read via a happens-before semaphore edge)
```

The `aetherctl` CLI target (`Sources/aetherctl/`) is documented separately in [docs/cli.md](cli.md).

## Dependencies

| Package | License | Purpose |
| --- | --- | --- |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL-2.1-or-later | Slim FFmpeg 8.1 (avcodec / avformat / avutil / swresample / swscale / avfilter + zimg) for demux + HLS-fMP4 mux + AudioBridge FLAC encode + SW-path dav1d decode + sws_scale YUV → NV12 / P010. avfilter ships a trimmed filter set: zscale + tonemap + colorspace (HDR → SDR still extraction), bwdif + yadif + yadif_videotoolbox + hwupload (SW + GPU deinterlacing). Bundles libzvbi for the DVB teletext decoder (#107). Shipped as dynamically linked frameworks, no GPL components |
| [LibDovi](https://github.com/superuser404notfound/LibDovi) | MIT / Apache-2.0 | libdovi (the `dolby_vision` crate's C API) for live Dolby Vision Profile 7 to single-layer 8.1 RPU conversion (`dovi_convert_rpu_with_mode`, mode 2), so the Apple TV engages real DV on dual-layer UHD-BD remuxes instead of plain HDR10. Prebuilt xcframework, no Rust at the consumer's build time |
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient) | MIT | Pure-Swift SMB2 client over `NWConnection`, backing the opt-in `AetherEngineSMB` product only (never linked by the core engine). NTLMv2 / guest, SMB 2.0.2 / 2.1. Replaced AMSMB2/libsmb2, which `EPERM`s on tvOS / iOS |
| VideoToolbox | System | Native path video decode (HW where available, Apple's bundled SW dav1d on iOS / macOS) |
| AVFoundation | System | AVPlayer + AVDisplayManager (native path); AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer (SW path) |
| CoreMedia | System | Sample descriptions, format-description tagging, CMTimebase |
