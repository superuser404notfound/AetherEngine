# Architecture

How AetherEngine works inside: the three playback pipelines, byte-reader scheduling, live-source recovery, the software packet cache, a few patterns for host apps, a file-by-file source map, and the dependencies. For using the engine, see [guide.md](guide.md) and [api.md](api.md). For format and codec details, see [docs/formats.md](formats.md).

Contents:

- [Playback pipelines](#playback-pipelines)
  - [Native AVPlayer pipeline (default)](#native-avplayer-pipeline-default)
  - [Software decoder pipeline](#software-decoder-pipeline)
  - [App backgrounding](#app-backgrounding)
  - [Audio-only pipeline](#audio-only-pipeline-music-podcasts-audiobooks)
  - [Audio tap](#audio-tap-95)
  - [Playback status](#playback-status-playbackphase)
  - [Effective video route](#effective-video-route-videoroute)
- [Byte-reader callback scheduling](#byte-reader-callback-scheduling)
- [Live sources](#live-sources)
- [Software VOD compressed packet cache](#software-vod-compressed-packet-cache)
- [SwiftUI `Menu` in custom player chrome](#swiftui-menu-in-custom-player-chrome)
- [Blocking work and the cooperative pool](#blocking-work-and-the-cooperative-pool)
- [Subtitle recognition scheduling](#subtitle-recognition-scheduling)
- [Source map](#source-map)
- [Dependencies](#dependencies)

## Playback pipelines

AetherEngine has three playback pipelines. It picks one once, at `load(url:)`:

- **Audio-only**, when `LoadOptions.audioOnly` is set.
- Otherwise **native** or **software** video, based on the source's video codec.

The dispatch happens once at load time. Hosts see the same `@Published` state surface either way.

### Native AVPlayer pipeline (default)

The native path lets Apple's stack do the decoding:

1. libavformat demuxes the source.
2. The elementary streams are re-muxed on the fly into HLS-fMP4 (HLS with fragmented MP4 segments).
3. A local HTTP server on an ephemeral port serves them. The player is handed `127.0.0.1:<port>/<session-token>/...`.
4. `AVPlayer` plays that playlist. Apple's stack does all decode, all HDR / Dolby Vision signaling over HDMI, and all audio routing.

The server listens on all interfaces so an AirPlay receiver can reach it over the LAN. It is protected by:

- a per-session path token,
- a cap of 32 connections, 24 of them for non-loopback peers,
- a 10 s head deadline for unauthenticated connections.

This path handles HEVC and progressive H.264, which AVPlayer's HLS-fMP4 pipeline reliably accepts. Interlaced H.264 goes to the software path for deinterlacing (#107). Atmos passthrough, the DV HDMI handshake, and HDR10 / HDR10+ system-side tone-mapping all live on this path.

```
Source URL ──► Demuxer ──► HLSSegmentProducer ──► SegmentCache ──► HLSLocalServer
                                                                         │
                                                                         ▼
                                                                     AVPlayer
                                                                         │
                                                                         ├─► VideoToolbox (HW decode)
                                                                         └─► AVR / speakers (Atmos via MAT 2.0)
```

**Why HLS-fMP4 instead of handing `AVPlayer` the source URL.** AVPlayer's progressive-download path does not accept arbitrary MKV containers. Even for MP4 it is brittle around Dolby Vision sample-description quirks and EAC3 `dec3` box variants. HLS-fMP4 is the most permissive input AVPlayer has. libavformat's `hls` muxer produces bytes identical to `ffmpeg -f hls -hls_segment_type fmp4`, which is what Apple's HLS spec is defined against.

#### Segment plan

The playlist's segment boundaries come from a keyframe-aligned plan built in `HLSVideoEngine+SegmentPlanning.swift`. It mirrors the `hls` muxer's cut rule: segment N ends at the first IRAP (a random-access keyframe) at or after `(N+1) * targetSegmentDuration`.

The plan needs the source's keyframe positions:

- **MKV / MP4:** from a brief cue prewarm, a bounded seek that loads the Cues / `stss` index.
- **MPEG-TS / M2TS:** only whatever `avformat_find_stream_info` plus that seek happened to scan.

`keyframeIndexIsTrustworthy` runs three checks before trusting that index. If one fails, the engine uses a uniform-stride plan instead.

| Check | Rule | What it catches |
| --- | --- | --- |
| Gap | The largest gap between consecutive keyframes stays under a cap. | A clustered TS index gaps by thousands of seconds. Trusting it builds a first segment thousands of seconds long, which the `frag_custom` muxer buffers whole in RAM (#64). |
| Coverage | First to last indexed keyframe spans at least one `targetSegmentDuration`. | A remote MKV whose Cues tail read fails. The prewarm loads nothing, and only the open-time keyframes from the first few seconds survive. Their gaps are tiny, so the gap check passes, but no keyframe reaches the first segment boundary. The plan would collapse into one whole-file segment, from which AVPlayer loads zero tracks (`kFigAssetError_TrackNotFound`, #91). |
| Tail | The coverage reaches within 60 s of the source duration. | A dense index that stops minutes short is a partial scan (an MKV whose Cues are missing or point past EOF leaves only what the capped prewarm walked). Trusting it cuts a last segment from the final scanned keyframe to the end of the title, which the producer can never finish (PR #703). |

The uniform fallback anchors segment 0 at the content start, so a title that starts late does not advertise empty leading segments.

#### Cutting segments at runtime

The producer follows the plan with `VODSegmentCutter`, a keyframe-gated cut in decode order. A segment opens only at the IRAP that reaches the next boundary. That IRAP is the segment's first sample, and its open-GOP leading pictures stay with it. This matches the live path and the `hls` muxer.

The earlier code assigned each packet to a segment by its DTS against PTS-valued boundaries. With B-frame reorder, a keyframe whose DTS trailed its PTS fell into the previous segment, so the next segment started mid-GOP and depended on its predecessor. A fresh decode at that boundary (rebuffer recovery) showed brief blocky corruption (#92).

**Which timestamp "reaches" a boundary depends on the container.** The plan's boundaries are the container's own index entries, and containers disagree on what an entry means: a mov/mp4 sample table holds decode times, a Matroska Cue holds a presentation time. So the gate compares a packet on the plan's own axis (`PlanBoundaryAxis`, picked from the demuxer's format name). Both mismatches have caused real bugs:

- **Presentation packet against decode boundaries.** A keyframe could reach boundaries beyond its own by its composition offset (a couple of frames on an ordinary encode, 3 s on a remux with an edit list). That used up plan indices that never opened a segment while the playlist still offered them (#358).
- **Decode packet against presentation boundaries.** No keyframe reached its own boundary on any Matroska file whose video has composition offsets, which is every MKV with B-frames. The gate never opened on the planned IRAP. Audio (routed by boundary, not gated) opened each segment instead, so every segment began mid-GOP, about one IRAP below its own first random-access point. AVPlayer does not notice while it decodes through the boundaries. The first time it has to decode from one, it fails with `CoreMediaErrorDomain -19602`, at a position that depends on the encode rather than on elapsed time (AE#561).

`PlanBoundaryAxisTests` pins this with one HEVC stream muxed into both containers, where only the timestamps differ.

#### AVC configuration changes

**AVC VOD configuration changes are judged before native muxing.** `H264ConfigurationTracker` catches an H.264 VOD stream whose configuration changes mid-title, before the changed sample reaches the native muxer.

- It starts from the producer's effective `avcC`, follows length-prefixed SPS/PPS in NAL order, and checks the SPS referenced by each IDR against that baseline by its decoder signature (profile through cropping). PPS, VUI and level do not count, because the native decoder takes them in band.
- On a mismatch the pump exits with a typed reason before the changed sample is written. The session keeps the verdict if the pump finishes before its owning load is installed. Producer epoch and load generation checks reject superseded events.
- Recovery is the existing `SoftwarePathEscalation` takeover, under its normal route and host opt-in constraints. The rebuild starts from the pending user seek or the actual playhead, never from the producer's read-ahead position.

This avoids relying on a static VOD playlist refreshing an `EXT-X-MAP` after it has already been loaded.

#### Restarts keep the same timeline

A restarted producer must produce segments on the same media timeline the continuous run gave them. The loopback server's contract with AVPlayer is "static VOD server", and AVPlayer places fMP4 segments by their `tfdt` (the fragment's base decode time).

Each restart creates a fresh mp4 muxer, and movenc starts a new instance's timeline at zero by default. So a restarted segment used to carry `tfdt=0` while the playlist placed it at its plan offset. That was a hidden timeline break on every restart. Plain playback hid it, but it broke other consumers: AVKit's legible renderer detached mid-PiP (Sodalite#32), and the playhead drifted away from the loaded ranges (#93).

The fix:

- The muxer sets `movflags +frag_discont` with `avoid_negative_ts=disabled`, so `tfdt` carries the producer's absolute output timestamps.
- The restart audio gate inherits the session shift (the video shift, rescaled) instead of snapping audio onto the video seam.
- Leading audio at the head of the stream that would map below 0 is dropped, since the muxer no longer absorbs negative timestamps.

A restarted segment is byte-identical to its continuous twin except for the per-muxer `mfhd` sequence number. `RestartTimelineContinuityTests` pins this on a committed A/V fixture. On Matroska sources, per-sample DTS synthesis after a demuxer seek shifts the DTS split and boundary-frame membership by a frame or two, but presentation timestamps and `tfdt` anchoring stay the same across restarts.

**Negative timestamps are clamped (AE#509).** `tfdt` is an `unsigned int(64)`, so with this setting a negative output axis cannot be represented at all. The published first timestamp is therefore clamped at zero. The case that hit it: libavformat serves an MPEG-TS whose first DTS sits within 60 s of the 33-bit PTS wrap with every timestamp `2^33` ticks low (`AV_PTS_WRAP_SUB_OFFSET`). A live join there published `baseMediaDecodeTime = 2^64 - |dts|` against a playlist starting at 0. AVPlayer then fetched the whole window and placed none of it, with no error and no stall.

#### Constant-rate frame grid

The video track's output time base is normally the source's, which movenc scales up to at least 10000 (Matroska's 1/1000 becomes 1/16000). That keeps the container's rounding, which hurts on a constant-rate track: 23.976 fps on 1 ms ticks reaches AVPlayer as 41 and 42 ms steps. At a 59.94 Hz output every second frame sits exactly on a refresh boundary, where half a millisecond of rounding decides which vsync shows it (AE#886).

`CFRFrameGrid` fixes this for a VOD track when both are true:

- the source tick is 0.1 ms or coarser, and
- the frame rate probes as exactly a standard rate the tick cannot represent.

It then uses a time base with one frame in whole ticks (1/24000 with 1001 ticks for 23.976, 1/24000 with 1000 ticks for 24), anchored at the stream's start time. `HLSSegmentProducer` moves each packet whose source-axis PTS lies within one source tick of a grid slot onto that slot (the DTS onto its own slot, never past the PTS), and rescales everything else as before.

The grid is derived once per session, before the first producer runs, from the stream's declared rate. So every producer of a session writes the same `init.mp4` timescale, and a restarted segment still matches its continuous twin. The one exception to "declared" is a declared rate that is not a standard rate at all: `SourceFrameRateMeasurement` then fits the rate to the head packets that `find_stream_info` already queued (peeked, not consumed) and the load uses that instead (Sodalite#236). mkvmerge writes the first frame's duration as a track's DefaultDuration, so film carrying 2:3 pulldown timing declares 20 fps while it runs at 23.976.

#### 2:3 pulldown timing on 24p film

Some encodes of soft-telecined DVDs keep the film's progressive frames but stamp each with the time its first field would appear on a 59.94 Hz field clock: frames last three fields, then two (50 ms, 33 ms), averaging 23.976. On a 23.976 Hz panel a 33 ms frame can fall between two refreshes and never be shown, and whether it does depends on the vsync phase, which every start and seek re-rolls. The result is a pan that stutters on one pass and plays clean on the next (Sodalite#236).

These frames lie 8 to 17 ms from a grid slot, far past `CFRFrameGrid`'s one-tick tolerance. On a 24p grid, `PulldownCadenceRetimer` owns every video packet instead:

- It keeps a window of the last 48 packets (decode order) and calls the stretch film when every spacing among them, in presentation order, is two or three fields and they average two and a half. Anything else (true 30p or 60p video, a constant-rate stretch) goes through `CFRFrameGrid.place` unchanged.
- In film, each frame goes to its nearest slot on a 24p grid whose origin follows the film. An edit that drops or repeats a field moves the film one field against the grid; the retimer re-centres on the running mean deviation, so no frame moves more than about one field from its source time.
- A frame only moves where it stays strictly between its neighbours in presentation order, checked against the whole window. Otherwise the grid re-anchors on that frame, or the frame keeps its own time.
- `PulldownCadenceLatch` carries the verdict across the session's producers, so a producer started by a seek retimes from its first frame instead of waiting for its window.

The producer's finish line counts `pulldownRetimed=` next to `onGrid=` and `offGrid=`.

#### Seeks and the segment cache

Seeks are demand-driven. `AVPlayer` simply fetches segments at the new position. `VideoSegmentProvider` tears the producer down and re-anchors it at the requested index (`restartHandler`, with bursts coalesced by `RestartCoalescer`) only when `SegmentCache` cannot serve the request. A restart is the expensive path: it re-seeks the demuxer, which is slow on remote sources (#93).

**VOD cache retention.**

- The cache has a hard window, `[target - backwardWindow, target + forwardWindow]`, that is never evicted.
- For VOD it also keeps already-produced segments outside that window, under a byte budget: 2 GiB, clamped to a quarter of the tmp volume's free capacity. Once full, it evicts the segments farthest from the target first.
- Because the hard window is never evicted, the budget only bounds the extras around it. That holds by construction as long as the forward window stays at or below the historical 150-segment ceiling (~1.5 GB of 4K HEVC).
- A seek back into the retained span, and the forward march after it, is a pure cache hit with zero producer restarts. Only a seek into never-produced content restarts.
- Live sessions prune by window only, since the sliding playlist has already dropped everything behind the window.

**Whole-source prefetch (opt-in).** A forward window larger than that is an explicit host opt-in through `LoadOptions.forwardBufferSegments` (up to 2700 segments, ~3 h, #207). It drops the budget's 2 GiB default cap but keeps the quarter-of-free-space clamp. The producer parks once its race-ahead holds that many bytes ahead of the consumer target, and resumes as eviction behind the playhead frees room (`PrefetchDiskBudget`). So an opt-in prefetch follows the disk budget, not the source length.

**Where a restart seeks.** A non-disc VOD restart seeks on the video stream's native timestamp axis to the exact IRAP stored in the segment plan, with that timestamp as the lower bound. A global time seek can land a whole GOP earlier on multi-stream MP4 and turn the producer's scan-forward gate into a long remote read (#191). Disc plans use folded multi-clip timestamps and keep the global-time seek.

**Restarts on a slow link (#93 residual).**

- A fetch waiting on an in-flight restart follows that restart's progress instead of burning a fixed retry budget into a 503. It never re-fires a restart at its own stale index.
- The fresh reopen after a wedged restart skips `find_stream_info`, because the session already holds saved codec configs and the segment plan.
- Lazy native subtitle readers wait while a restart runs.
- The first producer of a resumed session anchors directly at the resume segment, instead of producing seg0 into an immediate teardown.

**Holes in the cache (#129).** Retained scrub bands leave holes inside the cache's stored min/max index range, so an index inside that range is no proof the segment exists. A fetch inside the range waits (2 s) only when the active producer's forward march actually covers the requested index. Otherwise it restarts at once.

#### Seek deadline and recovery

The public `seek(to:)` on the native path waits for AVPlayer's real landing, so `isSeeking` covers it (#37/#38). The wait is capped at 8 s (#65, #129). At the deadline the engine sets the published clock to AVPlayer's rendered frame and returns to the caller, instead of stacking a second unbounded seek (repeated source stalls could chain those past 40 s).

After the deadline:

- The original AVPlayer seek stays alive as the recovery intent (`pendingRecoverySeekClockTarget`).
- The producer is re-anchored at the target only when it is really starved. A healthy but slow producer keeps its progress.
- The scrub clock is held while the intent is pending, so recovery nudges cannot bounce it (#37).
- A late landing sets the clock from the rendered frame, re-anchors subtitles once, and reconciles transport state afterwards. Both orders of the landing/deadline race on the MainActor are handled.

Transport state is reconciled from live `timeControlStatus`:

- An external AVKit / MediaRemote play or pause issued mid-seek wins.
- A spurious pause during active stall recovery is re-asserted inside the bounded recovery window.
- A paused scrub still lands paused and never restarts playback (#122).

#### Seek events

A host can observe a seek in two ways:

- `isSeeking` / `seekTarget` are a **level**: a seek is in flight, and where to.
- `seekEvents` is a **stream** that says what happened to it. It exists because the level's falling edge is ambiguous by design (#38 follow-up).

Every accepted seek emits `.began` and then exactly one of `.landed(renderedTime:)`, `.stalled` or `.superseded`, under the same id. A seek that never reaches a host emits a standalone `.rejected`.

One asymmetry is deliberate: a `.stalled` seek stays alive as recovery intent, so its `.landed` can still arrive minutes later on a source that finally serves the target. No level signal can express that.

Three paths feed the stream:

- **Programmatic seeks** report from their finalize step, so the clock is already at the target when the event fires.
- **Seeks stashed before the session can take them** (#127/#178) hold the level for the whole stash window. The engine publishes their target on `currentTime` optimistically, and a consumer that broadcasts it needs to know nothing has reached it yet.
- **Native AVKit scrubs** end their window when the picture reaches the restarted region, watched on `$renderedTime` and capped at 8 s. They do not end when the coalesced producer restart drains: draining only means the producer is producing at the new index, and the picture arrives a fetch and a decode later (1.4 s on a WAN source in the reporting host's capture). A restart that a programmatic seek itself caused is left to that seek's events, since the restart segment can sit below where the picture ends up.

#### Restart latency diagnostics

Restart latency explains itself in the log (#93 follow-up):

- The "producer restarted" line carries a phase split (`stopWait/reopen/seek/build`).
- A producer's first source read is timed.
- Any single `AVIOReader` read over 2 s emits one `slow read` summary that names where the time went: detour fetches with network time, `connStallTimeout` waits, reconnects, backoff sleeps, bytes dropped by the stale-generation guard, and the generation span.

A slow read with all-zero counters means the wait happened before the read loop.

#### Keeping AVPlayer from timing out (#93 round 3)

A request during a restart must never leave AVPlayer waiting in silence. AVPlayer's media watchdog logs `-12889 "No response for media file"` after ~3.5 s without response headers (holding the connection open does not help), and three strikes fail the item.

So a VOD serve still running at 2 s (`SlowServeSignal`, armed by `VideoSegmentProvider.mediaSegment(at:onSlow:)`) sends an early `200` with `Transfer-Encoding: chunked`:

- The segment follows as a single chunk when it is ready.
- A serve that finally misses aborts the connection (truncated transfer, AVPlayer retries) instead of sending a cacheable empty 200.
- Fast serves keep the byte-identical `Content-Length` response.

**If the item dies anyway.** `failedToPlayToEndTime` parks the item at rate 0 / `timeControlStatus == .paused`, with `item.status` often still `readyToPlay`. Every pause-guarded recovery layer used to read that as user intent, which made the session terminal. Now:

- The host counts end failures on the loopback path (`endFailureCount`).
- The engine confirms the death through the same deferred window as the `.failed` KVO, then reloads the item through the stage-2 chain with the pause guard bypassed.
- `ItemDeathReviveGate` caps this at 3 attempts per dead spot. Playback progress, or a user seek away, restores the budget.
- The fresh item resumes only if the host's play intent says the viewer was playing. A paused title whose item dies (a tvOS screensaver taking the display is one way) is reloaded and stays paused.

#### End-of-item recovery

Native end-of-item recovery captures the published clock peak and its freshness before it awaits AVFoundation's off-main reading. A slow reading therefore cannot invalidate an end witness and replay an audio tail that already finished. Before applying the result, the host checks both the session generation and the seek generation. If a replacement or seek happened in between, it owns the transport, and the old end notification is suppressed.

#### Item diagnostics

**Item diagnostics must not become playback work.** `accessLog()` and `errorLog()` can block while waiting on AVFoundation's media-service queues, even when called from an item notification. So these callers go through `AVPlayerItemDiagnostics`:

- the video host's log notifications and failure dump,
- the audio-only error observer,
- the reconciliation of the outgoing item's counters.

How it works:

- Each reader owns its original item, merges pending reasons, and hands log values (not native log objects) to the main actor.
- Failure track arrays are also fetched off-main. The SDK's UI-actor-isolated track handles then use async asset-property loaders.
- A stop or load invalidates publication, including queued callbacks, without waiting for a read.
- Delivery rechecks ownership after synchronous log handlers and state subscribers, because they can replace the item while its diagnostic batch is being consumed.
- Merged error batches look at unseen entries, so a fetch error in between cannot hide the startup `-15628` loader-poison signal.
- Access-log notification output is capped at five entries per item. A failure still dumps the complete available logs.

**Admission.** Admission is process-wide: at most **two concurrent diagnostic reads**, plus **one pending retirement
read** kept beyond those lanes. Current-item and error work goes before optional retirement work. Cancellation never frees a lane that is still inside a native getter. One stuck lane leaves the other available. Two stuck lanes defer diagnostics rather than spawn more threads. This contains diagnostic stalls only: it does not fix an underlying media-server failure, and it does not make every other AVPlayer operation nonblocking. Telemetry keeps its own separate, serial read path.

**Item swaps in one session.** On a swap, the engine folds in the outgoing item's last observed totals (transferred bytes, dropped frames) without calling a getter at the handover. Later it reconciles only the difference found by its final background read.

- Telemetry readings also refresh that cache, so an older diagnostic snapshot cannot move it backwards or count the outgoing item twice.
- If swaps outpace blocked readers, an older retirement read that has not started is discarded. Its observed totals stay, but the final totals are incomplete. This is reported once per session, never made up.
- A new playback session (including an episode handover on the same player) clears those totals and rejects any old reconciliation.

### Software decoder pipeline

The software path decodes in the engine and renders through sample-buffer layers:

- **Video:** libavcodec into `CVPixelBuffer`s. dav1d for AV1, VideoToolbox with a libavcodec fallback for VP9, FFmpeg's native decoder for VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1.
- **Audio:** libavcodec into `CMSampleBuffer`s.
- **Rendering:** `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer`, with `AVSampleBufferRenderSynchronizer` as the master clock.

It is used for what AVPlayer's HLS-fMP4 pipeline does not accept:

| Source | Why it routes here |
| --- | --- |
| AV1 | No Apple TV ships an AV1 hardware decoder yet, and Apple bundles dav1d only on iOS / macOS, so AV1 always routes here today. The engine still registers the supplemental VideoToolbox AV1 decoder and checks `VTIsHardwareDecodeSupported` (`VTCapabilityProbe`), so a future Apple TV chip with hardware AV1 is picked up automatically. |
| VP9 / VP8 | AVPlayer parses the HLS manifest, sees `vp09` / `vp08` in the CODECS attribute, then silently stops fetching. `item.status` never leaves `.unknown`. VideoToolbox decodes VP9 in hardware fine, but only outside the HLS pipeline. |
| MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, VC-1 | None of `mp4v.20.X` / `mp2v` / `vc-1` is in the CODECS list of Apple's HLS Authoring Spec. |
| Interlaced H.264 | AVPlayer does not deinterlace, so 1080i / 576i broadcast would show combing. `VideoRoutingPolicy` routes on the declared field order, and the software path runs it through `DeinterlaceFilter` (#107). |

**Interlace check on VOD (#232).** On seekable VOD the declared field order is first checked against decoded frames (`InterlaceProbe`). The filter engages on `AV_FRAME_FLAG_INTERLACED` alone, so a sample in which that flag never appears proves the detour would do nothing, and the stream goes back to the native path.

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

**AV1 notes.** AV1+DV (Profile 10.0 / 10.1 / 10.4) routes through the native path on hosts with hardware AV1, using the `dav1` / `av01` track type plus the source's `dvvC` box. AV1+Atmos is rare in practice (mastering still runs overwhelmingly in HEVC), so the software path's lack of Atmos passthrough is a theoretical limit, not a real one. AV1 capability registration is lazy and runs only when routing an AV1 source. Loading H.264, HEVC or audio-only content does not consult it.

#### VP9 hardware decode

The software host tries a hardware-only VideoToolbox session for VP9 profile 0 (8-bit 4:2:0) and profile 2 (10-bit 4:2:0).

- `VideoToolboxVideoFormat` builds the `vpcC` record that WebM omits, using the [VP codec configuration box](https://www.webmproject.org/vp9/mp4/#vp-codec-configuration-box) layout.
- Registering the supplemental decoder is gated by OS availability.
- `VideoDecoderOpener` closes a failed candidate and opens libavcodec before the host publishes its decoder or starts reading packets. A failed fallback is also closed and its error is passed on.
- `HardwareVideoDecoder` reads the coded size from each VP9 key frame header and rebuilds its session when the size changes. The feed epoch is checked under the session lock before replacement, so a packet from before a seek cannot discard the current reference pictures.

Playback stays on the software presentation route, because AVPlayer's HLS path does not accept VP9. Existing HEVC hardware probing, Dolby Vision selection and HDR10+ delivery are unchanged.

#### VideoToolbox output metadata

VideoToolbox decode callbacks can keep their image buffer as a reference picture, so the engine must not change it carelessly. The hardware video decoder passes the callback's `imageBufferModifiable` flag into `VideoToolboxOutputMetadataNormalizer`:

- Matching colour and pixel-aspect attachments leave the buffer untouched.
- A modifiable buffer is updated in place.
- Otherwise the update goes into an owned pixel buffer from a pool keyed by format.
- If the copy fails, the original output is kept rather than changing storage the decoder still owns.
- The same policy removes a stale pixel-aspect attachment when the current stream uses square pixels.

**Exception: the dual-layer base-layer decoder** (`allowsInPlaceOutputMetadata`). The composer writes the composed pixels into that decoded buffer anyway, so an owned copy would only cost a second pool. The risk this accepts is later frames decoding from composed pixels, which would show as drift until the next IDR. It was checked on the Mac only: 240 frames of two real FEL clips were bit-identical with and without the copy. A long-GOP picture comparison on the Apple TV decoder is still open.

**AV1 Dolby Vision RPU path.** It reuses that owned output, or makes its own copy, before changing buffer and IOSurface metadata. If copying fails, it delivers the original without setting or clearing RPU keys, including when RPU attachment is disabled.

#### Clock and transport

**Clock arming.** The feeder publishes the arm latch synchronously, so `play()` and `pause()` can see that a clock exists. The rate correction after arming runs on the main actor next to those transport calls, so it cannot restart the synchronizer halfway through a pause. Before applying a correction it:

- rechecks the output identity and the seek generation,
- ignores a stopped or seeking session,
- leaves end-of-media tail playback to its owner, unless the host explicitly paused.

The correction also carries the output's clock-command revision. `AudioOutput` compares that revision and applies the rate under its existing lock, so a later rebuffer pause, seek or rate command overrides the queued correction. A preroll completion belongs to its original command and keeps the revision. A paused intent cancels a pending preroll start, even while the synchronizer still reports rate zero.

**Explicit pause.** The software host's `pause()` also calls `AudioOutput.setPlaybackEnabled(false)`, which owns every clock write under the output lock. Stale feeder arms, rebuffer releases and preroll completions then cannot start the clock, even without a command revision.

- A paused seek still moves its anchor, at zero rate.
- Internal buffering pauses leave this transport intent alone.
- Only `play()` re-enables it. Enabling alone neither starts a clock with no anchor nor advances the command revision, so a pending arm correction can still supply the first start when play arrived before the feeder published its arm latch.

**Seeks keep the last frame on screen.** `SampleBufferRenderer.flush()` takes a `removingDisplayedImage` flag and passes it to `AVSampleBufferVideoRenderer.flush(removingDisplayedImage:)`. Stop and teardown clear the visible frame (the default). `SoftwarePlaybackHost.seek()` passes `false`, so the previous frame stays up until the keyframe after the seek decodes, instead of flashing black on slow sources like MPEG-2. This matches the native path, which also holds the frame through a seek (#90).

#### Audio channel layout and timestamps

**The channel layout on the format description must name the order the resampler wrote** (#401). `AudioDecoder` resamples into the layout from `makeResamplerOutputLayout` and stamps the tag from `audioChannelLayoutTag`. If the two disagree, the renderer places audio where the decoder never put it. Measured per channel, the earlier pairing:

- moved every channel of a 7.1 track and put the LFE hard left at full gain,
- put a 4.0 centre hard left,
- mixed a 2.1 LFE into both channels instead of dropping it.

Only 5.0 and 5.1 lined up, which is why nobody noticed. The two functions now live side by side, and a test holds them against each other twice: once structurally, and once by rendering each channel through a real downmix. 6.1 is the one channel count CoreAudio has no matching tag for, so the resampler is pointed at 6.1(back) rather than leaving the common tags for a `UseChannelDescriptions` layout.

**Audio timestamps come from a sample count.** `AudioDecoder` stamps each `CMSampleBuffer` from a running sample count anchored to the first frame (`AudioClockAnchor`), not from the container's rounded per-packet PTS.

- Container time bases are coarse (1 ms in MKV). When a frame's duration is not a whole number of ticks (a 1536-sample AC-3 frame is 34.83 ms at 44.1 kHz but exactly 32 ms at 48 kHz), the rounded PTS leave a sub-millisecond gap or overlap at every buffer boundary. `AVSampleBufferAudioRenderer` then reconciles a discontinuity at each one: ~29 clicks per second, a continuous crackle.
- With the sample clock, consecutive buffers line up exactly.
- A real source discontinuity (> 100 ms off the predicted clock, such as a seek or an edit) re-anchors, so genuine gaps are not hidden. `flush()` drops the anchor.
- The clock advances only on a buffer that was actually emitted, so a dropped buffer adds no phantom samples.

#### Live audio look-ahead and edge rebuffer

**Live audio look-ahead + edge rebuffer (#107 audio chopping).** The DVR feeder loop interleaves audio behind the video renderer's back-pressure gate, so the audio renderer could never hold more than the video queue allowed (<1 s measured). On devices where software 1080i decode plus deinterlace runs near real time, that margin is zero and every feeder stall is an audible dropout.

**The look-ahead pump.** The feeder runs an audio look-ahead pump (`AudioLookaheadPolicy` + `AudioLookaheadState`). It is an independent ring cursor that decodes and enqueues audio packets ahead of the combined cursor until the renderer holds `targetLeadSeconds` (4 s) over the synchronizer clock. Audio delivery no longer depends on video decode speed. A chronically slow video decode now shows as late video frames under smooth audio, which is the right priority. DVR seeks reset the pump cursor together with `setFeedCursor` (compare-and-set, the seek wins).

**Edge rebuffer.** The same pump pass handles a live source that delivers below real time. When the pump drains the ring at the edge, the free-running clock would otherwise outrun the stream for good: every later sample lands in the clock's past, a continuous chopping that never recovers. `AudioLookaheadPolicy.clockAction` pauses the clock at `underrunPauseLeadSeconds`, refills, and resumes at `rebufferResumeLeadSeconds`. This mirrors AVPlayer's stall handling on the native path.

**Seek landings near the frontier.** A host seek does not trigger that rebuffer on purpose. A software live landing closer to the reader's frontier than `rebufferResumeLeadSeconds` is held that far back (`AetherEngine.softwareLiveLanding`, Sodalite#104 round 3). On a real-time source the lead arrives exactly as slowly as it is deep, so a landing at the frontier would park the clock for that long and then resume at the same distance behind as the held-back landing starts from.

**Segmented live sources (AE#813).** A source that delivers whole segments (a live HLS ingest) gets a holdback sized from the segment length (`SoftwareLiveHoldback`). The join lead, the landing, the live-edge tolerance and a rebuffer's resume cushion (`newest source PTS - clock`, on top of the audio lead, since the pump caps that lead at `targetLeadSeconds`) all follow it. A continuous source keeps the values above.

**Resume after a source pause.** A paused source comes back in one of two ways: it skips what it missed and continues near real time, or it hands over the whole backlog at once. The second leaves the picture the length of the pause behind the newest media, on a path that never catches up by itself. So the feeder watches a resume with the join's rule (`SoftwareLiveJoinPolicy`, measured from the clock instead of the ring's first packet):

- Once the backlog has landed, if the span is past the band the edge verdict already counts as the edge (`SoftwareLiveHoldback.resumeCatchUpSpanSeconds`), the engine moves the picture up to the join lead behind the newest media through its own live seek (`SeekOrigin.liveRejoin`).
- An ordinary resume on a segmented source, up to its cushion plus one unit behind, is inside that band and is never followed by a seek.
- A source that skipped is left where it resumed.

Diagnose with `aetherctl play --audio-stats` (see [cli.md](cli.md)).

#### Software renderer retirement

Each software playback host owns a fresh display layer. On stop, `AudioOutput` asks for immediate synchronizer removal with an invalid time and returns without blocking the main actor.

- A shared retirement task keeps the output, synchronizer and display layer alive until AVFoundation calls the completion handler. Cancellation does not release them early.
- Repeated detach requests share that task.
- A caller that reuses the same layer must await retirement before attaching it again.

### App backgrounding

#### Background audio (iOS)

When the app goes to the background while playing, the engine keeps audio going instead of tearing the pipeline down.

**The decision.** It is a pure, unit-tested policy, `backgroundAction(isAudioBackend:hasSoftwareHost:softwareHostHasAudio:keepVideoAlive:pipActive:state:)`, driven from the `UIApplication` lifecycle observers. `keepVideoAlive` comes from `shouldKeepVideoAlive(enabled:pipActive:state:)` and applies on iOS only. tvOS always tears down, for safety: a frozen decode session crossing a multi-hour suspension wedged `mediaserverd`.

**Native path.** Keeping audio alive just means not tearing down. `AVPlayer` under the `.playback` session keeps decoding.

**Software path.** There is no `AVPlayer`. The combined demux loop normally paces itself (audio and video) on the video renderer's `isReadyForMoreMediaData`. Once `AVSampleBufferDisplayLayer` stops draining in the background, that gate never reopens and audio would starve. So the host enters `backgroundAudioOnly`:

- The loop drops video packets and paces on the audio renderer (`AudioOutput.isReadyForMoreMediaData`) instead, which keeps `AVSampleBufferAudioRenderer` fed and the synchronizer running.
- On return to the foreground the flag clears, the video decoder and renderer flush, and video resyncs at the next keyframe while audio continues.
- A software host that renders no audio of its own never enters this mode (AE#739). The loop would have nothing to pace on and would drop the rest of the file within moments, parking the clock at end of media in the background. Such a session is released like a paused one and reloaded on return.

**VideoToolbox session.** The session is rebuilt on every return to the foreground, because an iOS screen lock invalidates it, and in audio-only mode nothing decodes video to notice. A loss seen while video is wanted (`kVTInvalidSessionErr` from a decode) is reported by `HardwareVideoDecoder.onSessionLost`. The host rebuilds the session and repositions to the playhead, so the picture comes back on the frame the audio is at. If that happens in the background, or VT refuses the rebuild, the recovery is owed to the next foreground return.

**Scope.** The combined VOD loop, and live-without-DVR, which shares it. The DVR feeder loop is unchanged. Test it headless with `aetherctl bgaudio` (see [cli.md](cli.md)).

#### Paused-background grace window (iOS, #127)

A paused session used to tear down as soon as the app went to the background, so a 10-30 s app switch paid a full pipeline rebuild (demuxer reopen, segment-plan scan, AVPlayer item reload).

**How it works now.**

- The teardown is deferred by `backgroundTeardownGraceSeconds` (default 15 s; 0 restores the immediate teardown), held under a `UIBackgroundTask` assertion.
- `didBecomeActive` cancels the window, so a quick switch resumes on the live pipeline.
- At expiry the action is evaluated again (PiP can start, and lock-screen play can resume, during the window). The teardown runs while the app is still really running, never across an idle suspension. The assertion's expiration handler is a synchronous backstop.
- The step decision is the pure `backgroundStep(action:state:supportsGraceWindow:graceSeconds:)`.
- A playing teardown (background playback disabled) stays immediate, because its audio would keep sounding through the window. tvOS keeps the unconditional teardown.

**Hardening that ships with it.**

- Host seeks that arrive while the (re)built AVPlayer item is not yet ready are deferred (`shouldDeferHostSeek`), and the latest one replays at readiness. An early seek would clamp to 0 against empty seekable ranges and replace `load()`'s own startPosition seek.
- Hosts observe the published `isSessionReady` to gate corrective actions (restore watchdogs, position clamps), instead of guessing readiness from `currentTime` being stuck at 0.

#### What a teardown hands the reload that follows it (#357)

Every reload path snapshots the state it restores (the #170 subtitle carryover, the audio pick, the disc title) right before its own `stopInternal`. That only works while teardown and reload are the same call. The background path splits them: it tears down when the app sleeps and reloads on return. So the reload's snapshot ran long after the state was wiped, and restored nothing.

For subtitles that left the rebuilt session without a drain target: no cue was delivered and every delivery log stayed silent, which looked like a delivery bug rather than a lost selection. Only an explicitly picked track was lost; an auto-picked one came back through the reload's re-run of preferred-language selection.

Now the teardown parks a `BackgroundTeardownSelection` before `stopInternal`, and `reloadAtCurrentPosition` claims it once.

- The live read stays authoritative for what survives a teardown (the external registry, its ordinal counter, the host's subtitle authority) and for a selection made after it, which is newer intent.
- The snapshot fills only the fields the teardown wiped.

#### Keeping the native host across a teardown

The background teardown also keeps one object: the `NativeAVPlayerHost` shell (`keepNativeHost`). AVKit registers its MediaRemote Now-Playing client once per `AVPlayer` instance and never registers again against a swapped one (issue #15).

On the way back, the reload decides whether to keep it with `shouldPreserveNativeHostAcrossLoad(backend:nativeHostSurvives:)`. That asks whether a host is still there, not which backend is running. The teardown leaves `playbackBackend` at `.none`, so checking the backend alone threw away exactly the instance the teardown had kept: the viewer came back from a tvOS screensaver to playing video with a dead system Now-Playing card (Sodalite#149). A load that then routes to software or audio-only releases the kept host in its own dispatch branch.

### Audio-only pipeline (music, podcasts, audiobooks)

When the host sets `LoadOptions.audioOnly`, the engine skips the video machinery: no HLS loopback server, no segment producer, no display layer. Decoding is native-first:

- Codecs on the `avPlayerCanDecodeAudio` whitelist hand the source URL straight to a bare `AVPlayer` (`AudioAVPlayerHost`).
- Everything else demuxes through libavformat and decodes through libavcodec into an `AVSampleBufferAudioRenderer` (`AudioPlaybackHost`).

These also take the libavcodec route, even when the codec is whitelisted:

| Case | Reason |
| --- | --- |
| A custom `IOReader` | AVPlayer needs a URL. |
| A FLAC whose blocks are under CoreMedia's floor | AE#764. |
| A FLAC whose first frame is smaller than its `STREAMINFO` `max_blocksize` | AVPlayer times each frame by the declared size and runs its clock past the end. Read from a peeked first packet (AE#946). |
| Any FLAC in the raw `flac` container | CoreMedia ignores the `SEEKTABLE`, places a seek by an estimated byte rate, and stamps the requested time on the frame it reached, seconds early on real music (AE#946). FLAC in MP4 seeks exactly. |
| `LoadOptions.preferredDecodePath = .software` | The host asked for it. |

`audioOnlyUsesAVPlayer` holds the whole decision. Transport (`play` / `pause` / `seek`) goes to the active host, and `stopInternal` tears it down for a clean handoff back to the video path on the next load.

```
audioOnly == true
   ├─ whitelisted codec, URL source, not .software ──► AVPlayer (AudioAVPlayerHost) ──► AVR / speakers
   └─ otherwise ──► Demuxer ──► AudioDecoder ──► AVSampleBufferAudioRenderer ──► AVR / speakers
```

**Now Playing on the audio host.** On tvOS, iOS and visionOS the AVPlayer audio host owns a persistent per-player `MPNowPlayingSession` (exposed as `audioNowPlayingSession`). It keeps the system Now-Playing overlay bound to the app across a background pause, publishes now-playing info from the player automatically, and carries `externalMetadata`. The host survives across tracks and does not pause when the app goes to the background. macOS has no such session; there, and on the FFmpeg audio host everywhere, the engine publishes through the shared centers when the app set `ownsAudioNowPlaying` (see `AetherEngine+NowPlaying.swift`).

**Now Playing on the video host.** The native video host can own the same kind of session, but only on request (`ownsVideoNowPlayingSession`, default off, read when a host is created). The difference is deliberate. The audio path is always a bare AVPlayer, but the video player is used both by custom-transport hosts and by `AVPlayerViewController` hosts, and AVKit owns Now-Playing there through its own private registration. A session claimed underneath AVKit costs that host its identity card and its working transport commands, so it is the host's call. When taken:

- The session lives on `NativeAVPlayerHost`, so it survives native-to-native reloads with it (issue #15).
- `setNowPlayingInfo(_:)` (or `setVideoNowPlayingInfo(_:)`) stages the identity dictionary that is replayed onto every fresh `AVPlayerItem` (readiness-gate master reloads, media fallback, in-place PiP swaps).
- `ownsVideoNowPlayingCommands` lets the engine bind the transport commands on the session's center; without it the host does.
- On macOS no session exists, so the engine publishes the card on the shared centers instead.

### Audio tap (#95)

`installAudioTap()` returns an `AsyncStream<AudioTapBuffer>` of decoded playback audio:

- Format: mono Float32 48 kHz (`AetherEngine.audioTapFormat`).
- Timestamps: source-PTS seconds (`sourceTime`, same axis as `engine.sourceTime`).
- A `discontinuity` flag on any gap (seek, eviction, track switch, drops under pressure).

It is meant for host-side speech features (live transcription with SpeechAnalyzer) and audio recognition (ShazamKit signatures).

```
native ──► SegmentCache (init + seg N) ──► mov demux ──► libavcodec ──► swr (mono 48k) ──► AsyncStream
software ──► AudioDecoder CMSampleBuffers ──► AVAudioConverter (mono 48k) ──► AsyncStream
                       (.dialogue: swr matrix / channel copy takes the centre alone)
```

#### Where the audio comes from

| Path | Reader | How |
| --- | --- | --- |
| Native | `LoopbackAudioReader` | Pulls the engine's own muxed fMP4 segments from the segment cache near the playhead and decodes their audio track out-of-band (libavcodec + libswresample). Each segment gets a fresh demux context that reads the init and fragment in place and discards every stream but the audio one (#910). Because it reads the mux, it follows the active audio track for free (the mux holds exactly the selected track, after the bridge), adds zero network load, and cannot stall playback. |
| Remote HLS (direct AVPlayer ingest, no loopback, VOD and live) | `AudioTapHLSReader` | `AudioTapHLSVariantResolver` picks the active audio rendition or muxed variant. `AudioTapHLSFetcher` fetches and decrypts (AES-128 clear-key) self-contained TS / fMP4 segments, sending `LoadOptions.httpHeaders` like the player's asset (#119). The reader follows the playhead and decodes near it. |
| Software | `AVAudioConverter` sink on `SoftwarePlaybackHost` | Mirrors the existing `AudioDecoder` PCM output. |

`AudioTapReaderSelection` makes the reader choice per session. `audioTapHasDeliverySource` tells the host whether the current session can deliver at all, so a missing source fails loudly.

**Software path downmix.** The decoder emits the source channel layout up to 7.1 without downmixing.

- The sink takes its input format from the sample buffer's own channel layout. The channel-count-only `AVAudioFormat` initializer returns nil for every count above 2.
- It checks once per format that the converter really mixes down. Any discrete layout converts to digital silence without an error, so those are folded to mono inside the tap instead (#400).
- The converter runs with `downmix` on. Without it, AVAudioConverter maps by channel label instead of mixing, which delivered a stereo track as its left channel, 2.1 as silence, and 4.0 to 7.1 as the centre alone (#908).

**Dialogue mode.** A `.dialogue` install (`installAudioTap(channels:)`) takes the front-centre channel alone instead of the downmix. The native and remote-HLS decoders set a one-row swresample matrix with the centre at unity; the software sink copies that channel out before the converter. Without a centre channel it falls back to the downmix. Each buffer's `channels` says which one it carries.

#### Lifecycle

- One tap per engine. Installing again replaces the previous stream.
- `load()` and `stop()` finish the stream. Opt-in is per load; with no session, or a video-only source, the stream finishes immediately.
- A session-preserving reload finishes it too (audio / subtitle / disc-title switch, `reloadAtCurrentPosition`). Every delivery path is bound to the session it was installed on, and each install gets a fresh `AudioTapMonotonicFilter`. So a host re-installs when the stream ends and starts the new session on a clean timeline, not one stitched across a reload that resumes slightly behind the old position (#356).

#### Release window and memory

Both readers decode whole segments but release the decoded buffers along the playhead:

- A buffer goes out once it starts before playhead + lead (10 s).
- The head of the segment an anchor lands in, if it already ended behind the playhead, is dropped.
- So the stream is handed at most tolerance + lead (12 s), however long a segment runs.

That bounds the release window, not memory. The decoded rest of the current segment is held on top of it (a reader parked at 95 s on 15 s segments has released 12.1 s and still holds 14.9 s), so the held tail grows with the segment length. Whatever the consumer keeps is its own.

A backward seek is detected from the playhead's own movement, never from how far the decode runs ahead of it (#864).

**Delivery and overflow.** Delivery is best-effort, and lossy only for a consumer that falls behind:

- The stream queues 256 buffers (`bufferingOldest`, about twice the release window at the 100 ms chunk floor).
- A buffer that arrives while the queue is full is dropped, and the first buffer taken after that carries `discontinuity`. A host never reads contiguous PCM across an overflow.
- There is no non-evicting mode, because a stalled consumer would turn it into unbounded memory.

Live sources are best-effort.

### Playback status (`playbackPhase`)

`AetherEngine.playbackPhase` is the one observable for what playback is doing right now, across all three pipelines. It is derived, not a separate state machine: a pure fold of `state`, `isBuffering`, `isSeeking`, and a typed source-reconnect axis. It is recomputed on every input change, so it cannot get out of sync. Each input's `didSet` triggers an idempotent recompute that re-emits only on an actual change.

Precedence (highest first): `error > ended > idle > loading > stalled > seeking > rebuffering > playing/paused`.

**The reader axis outranks `isSeeking` (#410).** A seek cannot land on a source that stopped delivering, so the seek level stays up as long as the seek stays alive, and that seek is not always the host's. The producer's restart coalescer issues its own `nativeScrub` seeks while recovering, so the engine's own recovery used to hide the outage it was recovering from (measured at 29 s and 41 s on a killed LAN origin). A seek stays visible through `isSeeking` and `seekEvents`; the reader axis is visible nowhere else. On a delivering source nothing changes: the reader is `flowing` and a seek reads `.seeking` as before.

**`.rebuffering`** is a buffer underrun on a healthy connection: AVPlayer waiting to play, or a software pump that paused its synchronizer to refill (the live feeder at a dry ring, the on-demand loop with its audio lead used up). `state` stays `.playing` across it.

- The software host publishes its pumps' hold as `isRebuffering`, folded into `isBuffering` the same way the audio host's wait is, so the phase turns `.rebuffering` the moment the clock stops.
- The on-demand loop pauses only once its pause arm is open: the source has either built `AudioLookaheadPolicy.rebufferResumeLeadSeconds` of lead once, or let the clock run `starvedLeadSeconds` (one second) past the last audio fed (AE#1025). The first keeps an exactly-realtime origin, whose lead sits at its start offset, from pausing at every start. The second catches a source slower than real time from the first byte, which never builds that lead and used to run the clock on over a starved read-ahead with the phase at `.playing`. A seek closes the arm again.
- While video is parked, the on-demand loop's read waits at most `parkedVideoReadWaitSeconds` (20 ms) for the source before it hands parked video to the renderer again. The loop is the only thread that does that, so an unbounded wait on a slow source let the renderer run dry and fed it a third of the frame rate (AE#1025).
- The resume after such a pause starts the clock through the video preroll, and a full layer counts as ready there (`SampleBufferRenderer.prerollSatisfied`): the frames handed over sit at or behind the stopped clock and nothing more fits until it runs, so the gate used to wait out `AudioOutput.prerollTimeout` and the clock stood 2 s longer with the phase already back at `.playing`. A start or a seek begins with a flushed layer and still waits for `videoPrerollSeconds`.
- Before that change, a live source that merely paused read as `.playing` over a still picture for the whole reader stall timeout, until the reader's reconnect promoted it to `.stalled`. A host app watching the clock had already reloaded the session, and the fresh join behind the same frozen burst replayed what it had just shown.

**`.stalled(reconnecting:)`** is a problem with the source connection (drop / 429 / 503 backoff) while the `AVIOReader` retries.

- It is a typed signal, not log text: the reader pushes a `flowing` / `reconnecting` phase through `Demuxer.onNetworkPhaseChanged`, the owning host forwards it (`HLSVideoEngine` on the native path, the software / audio hosts directly), and the engine hops it to the main actor.
- The flag is `true` while the reader retries, and `false` once it has used up its retry ladder (#410). Then the reader is out of the read, the producer's reopen owns the recovery, and the source is still down. Before, the dying reader reported `flowing` on its way out (only so the next reader's dedupe gate could not strand the phase), and the whole reopen window looked like a healthy source.

**Only bytes that crossed the network move the axis back to `flowing` (#410).** This is the same line the reconnect ladders have drawn since #380.

- A serve from the resident window, the retained head/tail spans (#281), or a resident detour block returns read-ahead the origin paid for before it died. Reporting delivery off those erased the stall on the next read.
- A metered detour fetch (429 / 503 / 509 on the arm that carries a throttling origin, #69/#71) now reports `reconnecting`, and its give-up reports `exhausted`. Before, it charged the ladder but told the axis nothing.
- One deliberate exception: the faulted-runway refill (#307/#309) replaces a dead connection while megabytes are still resident, and stays silent, because playback there continues. The empty-window ladder reports it when playback really starves.
- The native text subtitle readers (WebVTT rendition prefetch) are deliberately not wired up, so their stalls never move `playbackPhase`. The overlay itself is fed from the main read through the subtitle packet tap and has no connection of its own.

**Paths that cannot report `.stalled`.** The direct AVPlayer-HLS live path (`nativeRemoteHLS`) and the whitelisted-codec audio host (`AudioAVPlayerHost`) have no demuxer or `AVIOReader`. A starved connection there reads as `.rebuffering`.

- On the audio host that flag is folded from AVPlayer's own signals, `timeControlStatus == .waitingToPlayAtSpecifiedRate` and `AVPlayerItemPlaybackStalled`, and only once the item has played. The pre-roll wait of a fresh track is startup, not a rebuffer, and a paused player is never rebuffering.
- Up to and including 6.30.1 the audio host fed no buffering axis at all, so a dead progressive stream (an internet-radio origin dropping the connection) stayed `.playing` with a frozen clock, and a host had nothing but the clock to watch.

**For hosts:** observe `$playbackPhase` instead of combining `state == .loading`, `$isBuffering` and `$isSeeking`, and instead of regex-matching `EngineLog` for stall / reconnect, which is no longer needed.

### Effective video route (`videoRoute`)

`LoadOptions.nativeRemoteHLS` records what the host asked for, not what ends up serving the session. The engine reroutes based on what it finds, and `playbackBackend` cannot tell the two native pipelines apart because both are `.native`.

`AetherEngine.videoRoute` publishes the pipeline actually running. It is derived like `playbackPhase` (a pure fold over `playbackBackend` and the session's effective options, recomputed from each one's `didSet`, re-emitted only on a real change), so it cannot become a second opinion about the session.

| Route | Meaning |
| --- | --- |
| `.remoteBypass` | AVPlayer on the origin URL. No demuxer, no local server. AVFoundation owns media selection, buffering and subtitle drawing. |
| `.loopback` | The demuxer plus the local HLS-fMP4 server, the default video route. The engine owns the source connection and the subtitle pipeline. |
| `.software`, `.audio`, `.none` | Mirror the matching backends. |

Routes the host did not ask for:

| Transition | Trigger |
| --- | --- |
| `.remoteBypass` -> `.loopback` | #168 carriage watchdog: readyToPlay, but no video track for a master that advertises one (HEVC in MPEG-TS). Mid-session. |
| `.remoteBypass` -> `.loopback` | #199: the same master's verdict is remembered, so the next load skips the doomed mount entirely. At load time. |
| `.remoteBypass` -> `.loopback` | AE#268: the playlist plus the first segment's PMT identify a finite HEVC-in-MPEG-TS VOD. At load time. |
| `.remoteBypass` -> `.software` | AE#990: a finite MPEG-TS playlist with `preferredDecodePath = .software`, at load time, or one AVPlayer refused on its media, through the AE#561 rebuild. |
| `.loopback` -> `.remoteBypass` | AE#154 / AE#246: an HLS playlist reached the loopback path, which cannot demux it. At load time. |

Branch on this where host behaviour differs per pipeline: who draws subtitles (AVPlayer on the bypass, the host's renderer on loopback and software), and whether a composited PiP overlay makes sense at all. Observing it also turns a mid-session reroute into an event instead of a log line.

## Byte-reader callback scheduling

The AVIO reader, the held HTTP transport and the prewarm fetcher each use their own serial URLSession delegate queue at user-initiated QoS. These callbacks deliver playback bytes and release the origin-request tickets that foreground demux threads wait for. A semaphore wait cannot donate priority to an implicit utility callback queue, which is why the queues are explicit. Held transport work also runs at user-initiated QoS.

**Ticket release.**

- Finite AVIO requests release their ticket in the completion callback, before the waiting caller resumes to process the result.
- A lock-guarded lease makes that release idempotent against cancellation, early return and deallocation.
- Refusal responses are charged to the origin before its slot goes to another reader.
- Persistent and prewarm callbacks already return their tickets at completion.

Unchanged: per-origin caps, FIFO ordering, pacing, cancellation drains, and the timeout/overcommit policy. Each session keeps its own serial callback ordering.

**QoS is not a deadline.** A VOD segment already in the cache can still cross the slow-serve threshold while its serving thread is delayed. Its early chunked header is still valid: the response carries the same cached bytes, and the notification alone does not restart the producer.

## Live sources

How the engine recovers when a live source reconnects, replays media it already sent, or changes shape. The first sections cover the native stream-copy path, then the software path, then playlist renewal.

### Exact overlap after a live source reconnect

After a reconnect a live source often re-sends media the engine already has. On the single-demuxer stream-copy path the engine removes that overlap only on proof.

**Proof of replay.**

- A rollback in timestamps alone is never proof. A rollback to a retained packet's DTS/PTS can open a provisional candidate, even if the first payload differs.
- Only exact DTS, PTS and compressed-payload SHA-256 matches count as replay evidence.
- Candidate packets are buffered until both tracks pass their previously admitted frontier. Then the old media is removed, and new media continues on the existing timeline.

**Damaged boundaries.** A reconnect can cut a transport/PES packet in half. Forwarding a whole candidate after one mismatch replayed old pictures, and reopening right after that mismatch kept hitting the same damaged boundary. So:

- A short unmatched run that includes the first packet of either track is quarantined, within a bounded source-time interval and a bounded unmatched-packet count per track.
- Before any exact match on a track, the first unmatched timestamp anchors that bound.
- Untimed packets stay under the producer's overall byte/packet limits and the source watchdog.
- Later exact matches, or crossing that track's old frontier, complete the interval. Discarding a candidate with gaps also requires distinct matching timestamps on every participating track.
- Prolonged divergence, EOF, a read failure, or the scan limits still interrupt a confirmed prefix without forwarding it.
- A short unconfirmed programme boundary keeps normal discontinuity handling.
- A source clock reset with different content is never classified as replay on its timestamps alone.

**Reopen.** A supported source reopens inside the same cache. Its fresh producer receives the bounded history of accepted packets and the source frontiers. A seek, channel change or independent load starts without that history. The failed socket is retired before the replacement opens. Changed track layouts ask for fresh host negotiation. Bridged audio and separate side-audio sources are excluded from paired replay recognition.

**Watchdog and host retry.**

- The cutter watchdog tells a bounded overlap scan apart from a stuck cut, while still detecting source starvation. The guard belongs to the producer thread.
- Repeated source loss parks acquisition after the existing bounded reopen budget.
- A host that opted in with `hostRetriesExhaustedLiveReplay` gets `liveSourceReplayExhausted`, which hands it the retry timing. It can call `retryLiveSourceRecovery()` without replacing the cache or the consumer item.
- Stop or replacement cancels the pending retry, duplicate requests are merged, and resumed production restores the provider's blocking-reload capability.
- Application backoff and error display stay with the host.

**Corrupt packets.**

- Corrupt packets with usable timestamps can still match identical, previously accepted bytes. An MPEG-TS continuity flag alone does not invalidate that proof.
- Corrupt packets are held in source order during a candidate. A completed paired verification discards damaged boundary packets, even when their usable timestamps are already past one track's retained frontier.
- Ambiguous candidates keep their packets.
- This does not discard arbitrary damaged packets during normal playback, and does not reset a decoder on a transport warning.

**Diagnostics.** Per-track and per-action diagnostics are rate-limited and include source timestamps or `missing`, never URLs. `forwarded` means the packet reached the normal pump path, not that a corrupt picture was shown. Native `LagDiag` clock progress follows the AVPlayer clock. `videoFrames=unavailable` records that it is not a rendered-frame counter, and unavailable drop counts show `-` instead of zero.

### Live replay boundary

Live packet admission also protects the outgoing transport boundary.

- A timed, flagged video packet beyond admitted history is held, while earlier intact pictures and audio continue.
- Exact replay on the participating tracks can supply the clean returning frame. The flagged packet is discarded only with that evidence.
- Good pictures that the outgoing parser releases late do not complete a track before its replay is traversed.
- Verified pending video is ordered by decode timestamp, exact returning copies are removed, and the settling frontier covers every retained good packet.
- An ambiguous boundary, EOF or read failure keeps its packets and admitted history. A clean outgoing picture cannot release the boundary on its own.
- Held intact pictures define a provisional replay horizon, while the replacement for the damaged picture stays fresh media until admitted. Only committed packets enter retained source history.

**Limits.** The lookahead covers sparse-video cadence as well as the bounded source interval. The held-video packet count is capped, and it and the source interval bound the lookahead. The transport and no-cut watchdog deadlines handle a source that stops delivering.

**Tests.** Encoded long-GOP H.264/AAC replay tests decode both the admitted software packets and the remuxed fragments, and compare every picture with the original.

### Native video output diagnostics

Video diagnostics keep source packet cadence separate from native decoded-output progress.

- The optional output observer belongs to one item/session and stops on teardown.
- It skips ineligible playback modes, and discards its state on positioning or inactive rendering.
- It emits bounded progress summaries and gap episodes. It keeps no pictures and makes no recovery decisions.
- Hosts decide whether to enable it and where its measurements go.
- The output is detached before a host-announced PiP transition, and reattached only to a ready inline layer after PiP ends.

**Presentation repair is separate.** Native presentation repair uses layer readiness, independent of this optional output. Its bounded sequence (nudge, then item replacement) requires advancing playback, a resident buffer and an attached foreground surface. It does not reset source history or move a DVR viewer to the live edge. In-place item replacement keeps the repair budget, which only rearms after sustained healthy presentation.

### Software live replay admission and recovery

`LiveReplayPacketReader` runs the same `LivePacketReplayGuard` before recording, clock-discontinuity folding and the ring append. Both the DVR reader and the live combined loop use it.

- Quarantine is bounded to 96 MiB and 10,000 packets. EOF, a read failure, cancellation and explicit positioning release the packets it owns.
- A verified partial replay is never forwarded as fresh media.
- An interrupted source surfaces as `liveSourceUnavailable`. Retry timing is left to the app, and transport loss is not treated as a codec incompatibility.

**Settling tail.** After paired verification, exact matching packets that the demuxer releases late stay suppressed until each track has advanced past the backward-discontinuity threshold. This tail never discards different compressed bytes just because their timestamps repeat.

**DVR cursor recovery.** During a DVR cursor recovery, acquisition waits before appending another packet, so it cannot evict the target while decoders and clocks are being repositioned. Memory and disk retention caps stay in force.

### Software Live without DVR

Ordinary Live software playback with audio uses `DirectLiveAudioReadAhead` on the existing Demuxer connection.

**How it works.**

- A forward-only memory FIFO lets audio move ahead of a full video renderer.
- Bounded parking of compressed video, plus short consumer waits, keep already-read video ready to run when source I/O waits.
- The timed waits apply only while video is parked. Otherwise the consumer sleeps until source data, EOF, a failure or cancellation wakes it.
- Video decoding yields between packets, so it cannot drain a whole parked batch before available audio gets a turn.
- The Live clock never takes on VOD pause/rebuffer behavior. The audio lead target is a ceiling, not a prefill required before start.

**Memory budgets.** The forward store and the parked-video queue use fixed in-memory pacing budgets, independent of `sessionCacheByteBudget`, free disk space and disk-retention claims.

- These are queue thresholds, not total allocation ceilings: one indivisible packet may exceed a threshold. The forward producer then waits for consumption, and parked video drains before an oversized packet is admitted alone.
- Packet cost includes referenced buffer capacity and side data.
- Consumed records create no seek history and no public DVR window.

**Other rules.**

- If read-ahead setup is unavailable, playback keeps the direct loop.
- Replay filtering runs before recording and decode, with its existing admission and quarantine limits.
- Per-packet generation checks, first-keyframe audio admission and the unarmed-video clock fallback still apply.
- Sessions with a DVR or cushion feeder keep their separate route.
- Standard `[SWDiag]` audio-lead and parked-depth reporting covers this path (AE#934).
- For both Live and VOD, entering background audio-only mode retires parked video before evaluating the read gate (including a queue that was already full), and uses audio-renderer backpressure.

### Live playlist renewal after a longer GOP

The first live media playlist seals its target duration. If a later finalized segment's serialized `EXTINF`, rounded to an integer, is larger than that value, the provider creates a new `live-N/` playlist namespace with a larger seal.

- The old video and subtitle URLs keep their original target, and keep the end index before the oversized segment, even after that segment leaves the live window.
- Relative segment, init and subtitle URLs resolve within either namespace to the same retained cache. Source acquisition is not reopened.

The native consumer swaps to the renewed URL using the existing in-place reload and playlist placement code.

- The viewing position and play/pause intent carry across the swap, including a DVR position behind live.
- A renewal never repeats a startup cushion wait that already finished.
- It never cuts a GOP at a dependent frame or misstates a segment's duration.

Limits: a consumer item replacement can still cause a short interruption, and this policy cannot rebuild missing source frames.

## Software VOD compressed packet cache

Seekable software VOD read through one of the engine's byte readers has a compressed packet producer, separate from the decode consumer that the renderer paces. The producer stores lossless packet envelopes in a session-owned FIFO.

**What a record holds.** Payload, PTS/DTS, packet duration, position, flags, stream index, time base and every side-data entry. Neither decoded pictures nor source URLs are kept in metadata.

**What is not cached.** A source libavformat opens itself (a local path) stays on the direct loop. The spool exists to avoid a second trip to a source, and re-reading a file is a page-cache hit.

### Storage

**Disk (default).** A session-owned temporary disk FIFO.

- Metadata reads and seek intent are main-thread safe. Disk operations and source reads stay on worker threads.
- Stop releases the session's directory. Bounded stale cleanup uses session leases, without following symlinks or deleting live stores.
- If creating the store fails, the original direct playback loop is still available.
- Cache corruption at runtime is a reported playback failure, not silently skipped data.

**tvOS: memory.** On tvOS the same records live in purgeable memory instead (`SoftwarePacketMemoryFIFO`, bounds in `SoftwarePlaybackHost.memoryPacketStoreBudget`):

- a 96 MB forward window,
- up to 128 MB of played history kept volatile, so the kernel may reclaim it under pressure. A seek into reclaimed history is then a normal cache miss.
- No session files and no disk retention claim.

Why: on an Apple TV 4K the disk store's appends took 100 to 600 ms while a download ran. The demux thread stalled behind them, and video it had already parked reached the decoder late. AVPlayer also keeps its progressive-download cache in memory on tvOS.

### Limits

The host uses the existing `forwardBufferSegments` clamp and the native session retention/volume-safety policy.

- The forward-second limit is measured on the reservoir: from the packet the consumer last took to the newest one stored. That is what the producer is building, and two timestamps always describe it. The coverage frontier (below) answers a stricter question and reports nothing once a hole or a single late presentation timestamp invalidates it, so it cannot be the only thing enforcing the limit.
- Byte and forward-time thresholds stop prefetch, with bounded slack for protected chunks and a single record.
- Old consumed chunks can be reclaimed exactly at the budget boundary, so refilling cannot deadlock.

### Coverage frontier

The cache frontier is the intersection of the selected audio and video presentation coverage that contains the playhead.

- Unknown intervals stay unknown. Byte counts are never turned into guessed seconds.
- H.264 and HEVC use a bounded presentation reorder queue and confirmed successor timestamps. A VFR packet's decode duration can be shorter than the picture's real display time, and a container that rounds durations down (41 ms against 41/42 ms deltas at 23.976 fps) would otherwise split the coverage at every frame (#613).
- Larger discontinuities, and invalid or unexpectedly late timestamps, invalidate or split coverage.
- Other codecs keep strict packet-duration coverage.
- Coverage keeps its history behind the playhead for cached backward seeks, up to 4096 ranges per stream. When full, it forgets the ranges entirely behind the playhead rather than stop describing new packets.
- Without a proven compressed frontier, the existing decoded-cushion fallback still applies.

**Quantized audio packet coverage.** `SoftwareAudioPacketCoverage` tracks the possible integer sample-clock phases across admitted audio packets, instead of bridging every small gap with an epsilon.

- Codec geometry is limited to: fixed MPEG audio/AC-3 frames, declared AAC/E-AC-3 frame sizes, complete non-reservoir WMA v1/v2 blocks, and exact PCM sample frames.
- Unknown, packed or conflicting layouts keep strict positive-duration intervals.
- Missing timestamps, backwards transitions and arithmetic overflow break the clock evidence. A real missing packet or an accumulated extra tick stays a hole.
- This changes packet-cache coverage and seek admission, not the decoded audio output clock.
- Audio without durations keeps the bounded successor-PTS contract, including repeated TrueHD millisecond timestamps.

### Seeks

- A cached seek restores a retained keyframe cursor, including an earlier keyframe for available preroll, and keeps the producer at its existing source frontier.
- AV1 through dav1d restores to the last keyframe at or before the target instead (`anchorsOnLastKeyframe`). An AV1 keyframe opens on its own, and the earlier one only cost dav1d a whole GOP of decode before the picture came back.
- A cache miss clears coverage and repositions the demuxer. Discarding the spool is the worker's job, not the seek's: removing every retained chunk costs more the longer the session has kept them, and no seek waits on it.
- Consumer generations and source epochs are separate. A cached seek must not discard a producer packet in flight, and a superseded consumer must not steal the first packet of a new source epoch.
- Admission applies equally to packet, EOF, error and delayed end-of-media callbacks.
- At EOF the VOD consumer parks until a new seek or stop.

### What hosts see

This changes engine cache semantics, not host UI.

- Software `bufferedPosition` and `LiveTelemetry.cachedBytes` describe compressed coverage/residency.
- `forwardBufferSeconds` stays the native player's loaded-range metric.
- `displayCushionSeconds` still describes the small decoded queue.
- Native HLS `residentRanges` and live DVR are not repurposed.

### Producer thread priority

The producer runs on its own thread rather than a dispatch queue, because a queue's QoS is fixed at creation and this producer's urgency changes inside one long-running loop.

- It starts latency-critical.
- It drops to the efficiency class once the reserve reaches half the forward window.
- It goes back to latency-critical at a quarter of the window, the moment a consumer parks in a read, or whenever the reserve cannot be expressed in seconds at all (the state of both a cold start and a seek landing).
- The two thresholds differ so a source sitting on one threshold does not switch on every packet.

**Why not stay demoted.** A permanently demoted producer is a priority inversion the scheduler cannot see: the consumer waits on an `NSCondition`, and a condition donates no priority to the thread it waits for. It costs throughput, not only fairness. On an idle 8-core M1 with negligible consumer decode cost, the efficiency-class producer drained 147 MB of an 80 Mbit/s source in 60 s, where the responsive one drained 438 MB, with seven cores free the whole time. Lifting only the thread's disk-I/O policy on the same class brought it to 528 MB. So the cause is the class throttling the spool writes the producer makes for every packet, and it needs no CPU contention.

**What the adaptive choice keeps.** Over a 100 s steady state it keeps 2165 ms of efficiency-class CPU, against 2145 ms for a permanently demoted producer and 1 ms for a permanently responsive one, at identical total CPU.

Consumer starvation is reported as its own rate-limited line, so a source that cannot keep up is visible directly instead of guessed from a stalled clock.

### Tests

The CI packet-cache step runs the standalone regressions for coverage, VFR successors, the disk FIFO, read-ahead concurrency, host admission and the AVPacket envelope. They use generated numeric data and temporary records, not private video fixtures.

## SwiftUI `Menu` in custom player chrome

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

## Blocking work and the cooperative pool

**Rule:** engine code that blocks its thread never runs on the Swift cooperative pool. Examples: a demuxer open or packet read, a FIFO write under backpressure, a `close()` that joins a pump, a `waitForFinish`.

**Why.** The pool has one thread per core and does not grow. Each blocked job takes one core's worth of async work away from the whole process, including the host app.

**How.** Create a detached engine task with `BlockingWork.detached` (`BlockingWork.swift`), never `Task.detached`. The task prefers `BlockingExecutor`, which runs its jobs on GCD's global queues, and GCD adds a thread when one blocks. Otherwise the task behaves as before: it awaits, hops to the main actor, and can be cancelled. `BlockingWorkTests` pins both halves, and a test fails the build if a `Task.detached` comes back into `Sources/AetherEngine`.

**Background.** CI found it: on a 3-core runner the suite parked all three pool threads for half a minute at a time, until a 120 s time limit fired at 151 s, because its watchdog is a task on the same pool. `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` narrows the pool to one thread and reproduces this on any Mac. The full suite has to pass under it.

**HTTP/1.1 body reads.** Persistent HTTP/1.1 body reads inherit the caller's isolation through the isolated parameter of `PersistentHTTP1Connection.readChunk`. Its framing can own a mutable chunked-body decoder, so a read from a cancellation handler must not send that single-consumer state to another executor. Cancellation still abandons the body through its existing drain-or-close path.

## Subtitle recognition scheduling

Bitmap subtitle OCR awaits each image's recognition on a dedicated utility thread.

- `VNImageRequestHandler.perform` blocks while Vision does its work. Calling it directly from a Swift task, even `Task.detached`, can exhaust the cooperative executor. So embedded and sidecar OCR workers suspend during recognition instead of holding that executor.
- One process-wide admission slot stays taken until the native operation actually returns, including after cancellation. Cancelled callers still in the queue leave without starting another thread.
- Completed cues stay in the store. An embedded worker cancelled mid-batch invalidates that batch's advanced cursor, so re-selecting the track collects it again instead of skipping unfinished cues.

## Source map

Which file owns what. Paths are relative to `Sources/AetherEngine/` unless noted. Files whose job needs more than one line have a short note under their folder's table.

### Top level

| File | What it does |
| --- | --- |
| `AetherEngine.swift` | Engine core: stored state, load dispatch, transport, stop/seek, track selection. |
| `AetherEngine+Probe.swift` | Static probes: `probe(url:)` / `probe(source:)`, shared HDR10+ / Atmos detail, `swDecodeProbe`, format, frame-rate and codec-label detection. |
| `ProbeControl.swift` | Opt-in input / packet / deadline accounting for a whole probe, and caller cancellation. Native callbacks keep their control until synchronous work returns. |
| `AetherEngine+Loading.swift` | Per-backend loaders (remote HLS, native, software, audio, audio-native) and reload. |
| `AetherEngine+OptionalComponents.swift` | `AetherEngine.OptionalComponent`: which trait-gated components (object audio, dual-layer DV, DV still reshaping) this build carries. |
| `AetherEngine+Subtitles.swift` | Embedded and external subtitle pipeline (#88, #112). See note. |
| `AetherEngine+ClosedCaptions.swift` | In-band CEA-608 closed captions and A53/SEI extraction: `ClosedCaptionTap` (read-only producer observer) plus cue mirroring (#77, #131). |
| `AetherEngine+Live.swift` | Live window publishing, edge snap, resume clamp, scrub thumbnails. |
| `AetherEngine+Diagnostics.swift` | Memory probe and live-telemetry bridge. |
| `AetherEngine+SubtitleDelivery.swift` | Emits the #357 subtitle-delivery line. See note. |
| `AetherEngine+SubtitleResolution.swift` | Emits the #250 subtitle-resolution line. See note. |
| `AetherEngine+AudioTap.swift` | Opt-in decoded PCM audio tap (#95): `installAudioTap()` returns the `AsyncStream` and picks native loopback, remote HLS or software mirror. |
| `AetherEngine+BackgroundAudioTestHooks.swift` | DEBUG-only hooks so `aetherctl bgaudio` can toggle the software background-audio keepalive without a `UIApplication` lifecycle. Never shipped. |
| `PlaybackClock.swift` | `engine.clock`: the ~10 Hz values (`currentTime`, `sourceTime`, `bufferedPosition`, `progress`, live-edge fields) as a separate `ObservableObject`. |
| `PresentationAxis.swift` | Display-axis fold for disc titles (source PTS to the 0-based published axis, AE#105). |
| `PresentationAxisMap.swift` | Source axis to item axis (#260). See note. |
| `NativeVideoFrameTime.swift` | Per-muxed-frame presentation times on both axes (#260): value type and observer typealias, emitted from `HLSSegmentProducer.finalizeAndWriteVideo`. |
| `SoftwareVideoFrameTime.swift` | Per-enqueued-frame presentation time on the software path (#311): one axis (source equals presentation there) plus a flush generation that a seek moves. Emitted from `SampleBufferRenderer.flushFrame`. |
| `AetherEngine+FrameTimes.swift` | Public installers for both per-frame time observers (native re-armed each session, software each host), plus `softwarePresentationTimebase`, the render synchronizer's clock. |
| `FrameTimeSequence.swift` | Process-wide monotonic allocator behind `NativeVideoFrameTime.epoch` and `SoftwareVideoFrameTime.generation` (#314), so ordering holds across a `load()`, not only inside one session. |
| `PlayerState.swift` | `PlaybackState`, `PlaybackPhase`, `VideoFormat`, `PlaybackBackend`, `LoadOptions`, `SourceProbe`, `TrackInfo`, `FontAttachment`, `MediaMetadata`, `SubtitleCue`, `SubtitleImage`. |
| `LiveReloadPolicy.swift` | Pure decisions for live reloads: rejoin at the live edge (no stale resume position), skip the pre-readiness zero seek. |
| `TransportControllable.swift` | Common transport surface of the four playback hosts (single active-host dispatch). |
| `FFmpegErrorConstants.swift` | AVERROR sentinels Swift cannot import from the C macros. |
| `AetherEngine+LiveSubtitleRenditions.swift` | Live: the upstream master's `EXT-X-MEDIA:TYPE=SUBTITLES` renditions as tracks (#359). See note. |
| `AetherEngine+SubtitleOCR.swift` | Arming, per-ordinal cursors and the MainActor tick of the bitmap-subtitle OCR worker. It fills a text rendition for PiP / AirPlay / external display while a PGS / DVB / DVD track's rendition is selected natively. |
| `AetherEngine+AudioShaping.swift` | `setAudioShaping(_:)`: audio shaping as a live setting. Each change is a session-preserving rebuild, with presses folded into the one in flight (AE#923). |
| `AetherEngine+TeletextPage.swift` | `setTeletextPage(_:)`: the teletext caption page as a live setting. Rebuilds the drain decoder of each channel showing a teletext track and leaves others alone, so a page libzvbi does not flag as a subtitle page can be fixed without leaving the channel (#364). |
| `AetherEngine+ScrubThumbnail.swift` | Scrub still for the active native session, decoded from bytes already in `SegmentCache`. Single-connection sources (debrid / torrent links) that refuse the `FrameExtractor`'s second demuxer still get previews (#106). |
| `AetherEngine+NowPlaying.swift` | Builds the Now-Playing publisher of the route that loaded, from the app's opt-ins (`ownsSoftwareNowPlaying`, `ownsAudioNowPlaying`, `ownsVideoNowPlayingSession` + `ownsVideoNowPlayingCommands`; primary role only): commands on the route's `MPNowPlayingSession`, or card and commands on the shared centers where none exists. Keeps the card through a load seam, and takes part in `NowPlayingArbiter` on the shared centers. |
| `SeekEvent.swift` | One statement about a seek's lifecycle (outcome plus its target). `isSeeking` / `seekTarget` are a level, and a level cannot say why it fell (#38 follow-up). |
| `StartupProgress.swift` | The nine-checkpoint startup ladder behind `$startupProgress` (#361). See note. |
| `SubtitleSessionCarryover.swift` | Subtitle state carried across an engine-initiated `reloadAtCurrentPosition` (AirPlay LAN swap, background-return reopen), which otherwise rebuilds the session from `LoadOptions` alone (#170). |
| `BackgroundTeardownSelection.swift` | The selection a teardown hands to the reload after it, for the one case where they are separate calls: the paused-background teardown (#127, #357). |

Notes:

- **`AetherEngine+Subtitles.swift`.** Every embedded stream is tapped off the session demuxer into `SubtitlePacketStore`. A playhead-paced drainer decodes the selected stream (text and bitmap, VOD and live) into the overlay, and rides producer seeks and restarts by construction. This replaced the side-demuxer reader and its recovery code outright (#112 rework). Also here: cue apply / prune; `closeOpenEndedCues`, which takes a placeholder end from the next stored packet, or retires the cue at the reconstruction window when the store has none; the external track registry and unified selection routing (#88). A VOD-only forward prefetcher extends store coverage past the producer park to the 60 s drain lead, for host advance sync offsets (#151), plus a margin so the harvest leads the decode and the set at the window's edge can take its authored end from the store (#362). Side readers yield the source link to the video path while it fetches or seeks (#240, `SideReaderLinkPolicy`). The drain tick states how far display-state determination has advanced on the absolute source axis, fenced by load and seek generation, so a host or conformance harness can tell "determined, and empty" from "not read yet" (#250, `AetherEngine+SubtitleResolution.swift`).
- **`AetherEngine+SubtitleDelivery.swift`.** One line per change of what a drain tick did with the packets it found (`outcome=` noDecoder / empty / undecodable / held / duplicate / trimOnly / published), plus the counts behind it. It complements #250, which states how far determination reached: the drain cursor advances over packets that decode to nothing, so resolution can keep up with every seek landing while the overlay never changes. The two lines together tell those cases apart.
- **`AetherEngine+SubtitleResolution.swift`.** One generation-fenced line stating the absolute source-time span over which display state has been decoded. Emitted at post-seek reconstruction, every 30 s, at prefetcher EOF, on any change of frontier source, and at the tick where determination first reaches the playhead (`reason=coverage`, #318). `retainedFrom=` also states the floor of the run retained across seeks, so "empty because nothing was ever authored before this point" is provable from one post-seek line (#276).
- **`PresentationAxisMap.swift`.** The history of producer shifts as a piecewise-constant map, plus an off-main mirror. Written by the shift-changed / rebased handlers; read by the clock fold, the live thumbnail path and hosts.
- **`AetherEngine+LiveSubtitleRenditions.swift`.** Renditions get synthetic ids from 300000. Once one is selected it is fetched as WebVTT segments onto the host-overlay surface. Cues are placed by the playlist geometry the renditions share (`EXT-X-PROGRAM-DATE-TIME`), anchored at the playhead rather than at the head of a two-hour DVR playlist, and re-anchored when a producer seam moves the source axis.
- **`StartupProgress.swift`.** Each value is recorded by the code that finishes the work it names, never by a timer, so a determinate loading bar holds through a slow stretch and jumps through a skipped one. A path that skips work is credited by the checkpoint it does reach, which is why the ladder is one ordered axis rather than a per-path set.

### `Audio/`

| File | What it does |
| --- | --- |
| `AtmosConfirmationWorker.swift` | `LoadOptions.confirmAtmos`: after the session is up, runs the bounded JOC pass on a side demuxer, one E-AC-3 track at a time, and republishes `audioTracks` through a source-keyed ledger (#214). Declined on an origin limited to one request, `sequentialOrigin` and `heldSourceConnection`, rechecked per track. |
| `AtmosDetectionProbe.swift` | Opt-in bounded E-AC-3 JOC decode pass behind `probeDetectingAtmos`: `AtmosDetectionOptions` caps, one decoder, no playback session (#214). |
| `AudioAVPlayerHost.swift` | Audio-only path: bare AVPlayer host for whitelisted codecs. Owns the persistent per-player `MPNowPlayingSession` (tvOS / iOS). Publishes the rebuffer axis (`waitingToPlayAtSpecifiedRate` / `AVPlayerItemPlaybackStalled` after first play) that the engine folds into `isBuffering`. |
| `AudioBridge.swift` | Native path: decode and re-encode per `AudioBridgeMode` (EAC3 5.1 default, or lossless FLAC opt-in) for source codecs that cannot stream-copy into fMP4. |
| `AudioClockAnchor.swift` | Software path: sample-count PTS anchor so consecutive buffers line up exactly; re-anchors on >100 ms drift (AVSampleBufferAudioRenderer crackle, #89). |
| `AudioDecoder.swift` | Software path: libavcodec → PCM → `CMSampleBuffer`, with channel-layout tagging that names the resampler's own order (#401). |
| `AudioOutput.swift` | Software path: `AVSampleBufferAudioRenderer` + synchronizer (master clock). |
| `AudioPlaybackHost.swift` | Audio-only path: FFmpeg demux and decode into `AVSampleBufferAudioRenderer` for codecs off the whitelist. |
| `AudioTailPadding.swift` | Native path: writes silence in the delivered codec from where a title's audio ends to where its video ends, into the final segment at end of file, because AVPlayer ends an item when its audio runs out (AE#847). |
| `SoftwareAtmosRoute.swift` | Software path: the pure choice of how a track's audio reaches the renderer (PCM decode, compressed E-AC-3 JOC, or TrueHD Atmos / DTS:X rendered into a bed as APAC or PCM), from codec, stream shape, live and `objectAudioRendering`. |
| `SoftwareAudioProducing.swift` | Software path: what the host asks of whatever turns an audio packet into renderer input. Implemented by `AudioDecoder`, `SoftwareEAC3Passthrough` and `SoftwareAPACProducer`. |
| `SoftwareEAC3Passthrough.swift` | Software path: E-AC-3 JOC packets sent compressed to the audio renderer, with the `dec3` format description built from the stream, so the system's Atmos decoder gets the objects. |
| `AtmosDecoderPrimer.swift` | Registers the system's Atmos decoders in the process once (by creating an AVPlayer). The renderer needs this before it decodes compressed E-AC-3 as Atmos. |

#### `Audio/Shaping/`

| File | What it does |
| --- | --- |
| `AudioShaping.swift` | `AudioShaping` (channel cap, dialogue lift, compressor, loudness target) and `AudioShapingState`: the host's request and the published answer (AE#923). |
| `AudioShapingMatrix.swift` | The cap and the centre lift as one libswresample remix matrix. |
| `AudioShapingGraph.swift` | The libavfilter graph after the remix: dialoguenhance + pan on stereo, acompressor, alimiter, aformat. Runs on its own sample counter so its latency never reaches the timeline. |
| `LoudnessNormalizer.swift` | The loudness target (AE#1036): BS.1770 integrated loudness over what has played, and the bounded, latency-free gain toward the target, applied in front of the graph. |

#### `Audio/Spatial/`

| File | What it does |
| --- | --- |
| `SpatialAudioBridge.swift` | TrueHD Atmos / DTS:X packets in, the layout's bed out as APAC or PCM packets on the source timeline (optional components). |
| `BedRegression.swift` | Builds every output from the stream's own bed, per band, steered by the elements' cross-spectra; never an element signal (W = R · A; DTS:X folds W = D + (R − D · F) · A). |
| `ObjectAudioPlacement.swift` | Each element's gains towards the layout from its metadata: point sources, no ramps. Mixes no audio. |
| `AllocentricPanner.swift` | Constant-power point-source gains in the allocentric room model, TS 103 448 speaker targets. |
| `TrueHDObjectAudioDecoder.swift` | LibTrueHD: the channel presentation plus the object presentation, without matrix interpolation. |
| `DTSXObjectAudioDecoder.swift` | FFmpeg `dca` with `x_heights`: the 7.1 bed as coded plus the four heights and their folds. |
| `SpatialBedOutput.swift` | `SpatialBedFormat` (PCM or APAC, and the route rule `.render` uses), the bed buffers and packets, and `PCMBedPacker`, the 24-bit PCM sink next to `APACEncodePipeline`. |
| `SoftwareAPACProducer.swift` | Software path: TrueHD Atmos / DTS:X rendered into a speaker bed through `SpatialAudioBridge` as APAC or PCM, handed to the audio renderer as sample buffers. |

#### `Audio/Tap/`

| File | What it does |
| --- | --- |
| `AudioTapController.swift` | Lifecycle owner for one tap: owns the `AsyncStream` continuation and (native path) the `LoopbackAudioReader`. One per engine; installing again replaces it (#95). |
| `AudioTapDecoder.swift` | FFmpeg decode of tap packets into mono Float32 48 kHz `AVAudioPCMBuffer`s (lazy resampler, own lock discipline). |
| `AudioTapPCMConverter.swift` | Software path: `AVAudioConverter` sink mirroring `AudioDecoder` PCM into the tap's mono 48 kHz format. Carries the source channel layout and checks the mixdown itself (#400). |
| `AudioTapTypes.swift` | `AudioTapBuffer` value type (single-consumer `@unchecked Sendable`) and the pure loopback pacing decision. |
| `AudioTapHLSVariantResolver.swift` | Remote-HLS tap: finds the active audio rendition / muxed variant from the master playlist (#95). |
| `AudioTapHLSFetcher.swift` | Remote-HLS tap: segment fetch and AES-128 clear-key decrypt for self-contained TS / fMP4 segments (#95). |
| `AudioTapHLSReader.swift` | Remote-HLS tap worker: follows the playhead and decodes fetched segments (VOD and live) (#95). |
| `AudioTapReaderSelection.swift` | Pure per-session reader choice (loopback, remote HLS, or none) behind `audioTapHasDeliverySource` (#95). |
| `LoopbackAudioReader.swift` | Native-path tap worker: pulls fMP4 segments from `SegmentCache` near the playhead and decodes their audio out-of-band on a utility thread (cannot stall playback). |
| `AudioTapMonotonicGate.swift` | Keeps `sourceTime` strictly increasing and non-overlapping across consecutive tap buffers. SpeechAnalyzer ends its input loop on the first overlap, and decoder priming at segment seams produces small backward steps (#95 follow-up). |

### `Decoder/`

| File | What it does |
| --- | --- |
| `A53ReorderBuffer.swift` | Decode-to-presentation reorder for SEI caption groups (#131). |
| `A53SEIParser.swift` | A53/GA94 cc_data extraction from H.264/HEVC SEI NALs (#131). |
| `DualLayerPictureAlignment.swift` | Software FEL path (`DualLayerDolbyVision` trait): pairs each EL picture with the base picture of the same display slot (POC), falling back to access-unit pairing (#702). |
| `FrameSideDataRing.swift` | Software FEL path (`DualLayerDolbyVision` trait): fixed ring of per-frame RPU parameters and display metadata, keyed by timestamp (#702). |
| `OrderedDelivery.swift` | Software FEL path (`DualLayerDolbyVision` trait): hands composed frames from the Metal completion queue to the renderer in decode order, with an epoch for seeks and a stall guard (#702). |
| `CCDataParser.swift` | Parses the bare cc_data triplet stream from a demuxable CEA-608 caption track (#77). |
| `CEA608Decoder.swift` | In-house CEA-608 line-21 decoder (field 1 / CC1), checked against FFmpeg `ccaption_dec.c` (#77). |
| `DeinterlaceFilter.swift` | Software path: persistent bwdif / yadif libavfilter graph; engages on the first interlaced frame. |
| `EmbeddedSubtitleDecoder.swift` | Inline subtitle decode from demuxed packets. Opens DVB teletext with libzvbi_teletextdec text-format options (#107). |
| `InterlaceProbe.swift` | Decodes a sample and applies the deinterlacer's own engagement test, so a declared field order that no frame backs up (PsF) stops costing a software decode (#232). |
| `VideoRoutingPolicy.swift` | Pure dispatch rule by codec and field order. See note. |
| `HardwareVideoDecoder.swift` | Software path: VideoToolbox hardware HEVC / AV1 decoder for sources routed away from AVPlayer. |
| `DualLayerVideoDecoder.swift` | Software path: Dolby Vision Profile 7 FEL (`DualLayerDolbyVision` trait). See note. |
| `SoftwareVideoDecoder.swift` | Software path: libavcodec/dav1d → `CVPixelBuffer` (NV12 / P010), HDR10+ side data. 10-bit AV1 reaches P010 through `GPUFrameConverter`. |
| `GPUFrameConverter.swift` | Software path: converts a 10-bit AV1 frame to P010 in one Metal pass and applies its film grain there (dav1d exports the grain instead of applying it). `sws_scale` stays the fallback. |
| `AV1FilmGrain.swift` | The per-frame grain tables (templates, scaling functions, block offsets), computed on the CPU the way dav1d computes them. |
| `AV1FilmGrainShaderSource.swift` | The Metal kernels: dav1d's per-pixel grain and the P010 write. |
| `AV1GaussianSequence.swift` | AV1's Gaussian_Sequence (specification 7.18.3.3). |
| `SidecarTextFetch.swift` | One plain whole-body GET for a text sidecar over HTTP, decoded from a temporary file, instead of the playback reader's ranged open and its 15 s + 25 s give-up (AE#984). |
| `SubtitleDecoder.swift` | One-shot decode of a sidecar URL. Decodes several streams of one container in a single pass (#266); a bitmap stream is read into packets instead (#921). |
| `VideoDecoderTypes.swift` | `DecodedFrameHandler` typealias and `VideoDecoderError`. |
| `DeinterlaceHardwareWarmup.swift` | On-demand, process-wide prewarm of the deinterlace filter's hardware pipeline. See note. |
| `PixelAspectPolicy.swift` | Whether a declared sample aspect ratio should be believed. See note. |

Notes:

- **`VideoRoutingPolicy.swift`.** AV1 is gated on hardware support. VP9 / VP8 / MPEG-4 / MPEG-2 / VC-1 always go software. Interlaced H.264 goes software so bwdif can deinterlace (#107; checked against decoded frames on VOD, #232). A second-stage gate routes H.264 High 4:2:2 / 4:4:4 / 10 and HEVC Rext to software where VideoToolbox has no hardware decoder (#2).
- **`DualLayerVideoDecoder.swift`.** Two `HardwareVideoDecoder`s (a base layer, typically 4K, and an enhancement layer, typically 1080p), paired by HEVC picture order with the packet's RPU, composed on Metal by `DoviFelComposer`, and delivered in decode order with the Profile 8.1 RPU attached per frame. See [dolby-vision-fel.md](dolby-vision-fel.md).
- **`DeinterlaceHardwareWarmup.swift`.** Only potentially interlaced `.auto` loads start and await it. Progressive sources and forced-software deinterlace skip it. Same-title reloads keep even a decoded progressive verdict. The background selection snapshot keeps that decision for a custom-reader reopen, while URL reloads probe again. Actual disc-title changes re-evaluate the reopened metadata. A source declared progressive that later supplies interlaced frames still deinterlaces on demand, paying the cold graph build at that first frame.
- **`PixelAspectPolicy.swift`.** Two gates. A ratio-magnitude gate (#177, live TS carrying 1088:1), which admits precise or unreduced ratios such as 759:712. A display-aspect gate judged against the frame the SAR applies to, since 2:1 is right on 960x1080 and wrong on 1920x1080 (#290).

### `Demuxer/`

| File | What it does |
| --- | --- |
| `AVIOProvider.swift` | Internal seam over a custom-AVIO byte source. `AVIOReader` and `CustomIOReaderBridge` both plug into the Demuxer through it, including the bounded-seek read deadline and the resolved byte size behind the byte-estimate seek fallback (#112). |
| `AVIOReader.swift` | URLSession-backed `avio_alloc_context` with three modes. See note. |
| `ResidentSpan.swift` | Bytes already in memory that a read can be served from without a round trip: the open window kept across a parse seek, and the speculative tail fetch. Not a cache (no fetch on miss, no eviction, no block alignment); it either covers an offset or it does not (#281). |
| `RangeHonestyProbe.swift` | Checks a ranged reconnect against bytes already held. The request starts a few KB early, and delivery waits until those KB match. A mismatch latches the reader into failing reads and records the origin, so the session fails as `sourceFabricatesRanges` instead of playing another chunk's bytes (AE#958). |
| `CustomIOReaderBridge.swift` | Bridges a host-supplied `IOReader` into `avio_alloc_context` read / seek callbacks, with the same read deadline and reversible read abort as `AVIOReader`, so bounded seeks also bound (and unwedge) disc-adapter sources. |
| `Demuxer.swift` | libavformat wrapper: seek, bounded seek, byte-estimate positioning fallback, per-open probe budgets. See note. |
| `RedirectHeaderPolicy.swift` | Which headers are replayed on a redirect, for `AVIOReader` and every other engine session (audit NET-108, NET-109). See note. |
| `SlowReadDiagnostics.swift` | One-shot explanation of a very slow `AVIOReader.read()` (detour fetch / connStall / reconnect / backoff / dropped-generation bytes), #93 restart latency. |
| `SourceThrottle.swift` | Pure virtual-clock leaky-bucket rate limiter on the source read path (slow-CDN simulation for `aetherctl --throttle`). Unit-testable without sleeping. |
| `SourceContentLengthCache.swift` | Remembers a source URL's resolved total byte length across demuxer opens, so a subtitle side demuxer opening the same origin later inherits the size the video producer already resolved (#112). |

Notes:

- **`AVIOReader.swift` modes.** (1) A persistent forward-streaming connection with reconnect-on-drop (playback, including live). (2) Discrete Range chunks (still extraction). (3) A single sequential GET with backpressure (non-live sources without Content-Length). An optional read deadline bounds a degenerate Matroska Cues seek.
- **`AVIOReader.swift` cold start on a non-faststart MP4 (#281).** The open window is kept across the parse seek to the trailing moov, so the trip back to the first sample is a copy, not a third connection. One speculative 64 KB suffix range is issued alongside the open, rejected at the response header unless it is a well-formed 206. A read landing in that range waits for the fetch instead of connecting past it, bounded by the measured cost of one round trip to the origin, because the demuxer reaches the tail before a fetch issued at the same moment can land.
- **`AVIOReader.swift` refusals and redirects.** A suffix-range denial is remembered per origin only from the origin's answer to the range form (a 200, a 416), never from a 403/404/429/5xx. A source refused with an HTTP status fails the open with a typed error (`AVIOReaderError.httpStatus`) instead of handing FFmpeg the error page (#378). A post-redirect target is pinned from its first 2xx and dropped again on an auth-expiry status, on a streak of unproductive reconnects, and after a bounded grace of rate-limited attempts (#307/#380). A pin that has carried no bytes for a minute is dropped on its first refusal instead, because the lingering-slot 509 that grace exists for cannot happen with nothing of ours in flight (#392).
- **`Demuxer.swift` positioning.** Seek, bounded seek (deadline-capped), and a byte-estimate positioning fallback for containers without an index. The fallback is origin-corrected onto the file-relative time axis, uses a fixed early bias in seconds, verifies its landing with a packet-PTS probe with proportional correction, and latches a sticky per-demuxer timestamp-seek lockout once the mechanism proves broken (#112).
- **`Demuxer.swift` probe budgets.** A per-open `DemuxerOpenProfile` budgets `find_stream_info` (probesize / max_analyze_duration). The caller can override it on the main playback open with `LoadOptions.probesize` / `maxAnalyzeDuration`. The native text readers' side demuxer sets `skipStreamInfo` to drop the `find_stream_info` pass entirely (codec_id / codec_type come from the container header / PMT at open); the reader runs a bounded `resolveStreamInfo()` on demand, only if its target stream's codec is really unresolved at open (#87). The playback open parks known PGS tracks (whose width only a decoded composition segment can supply) and undecodable audio as ATTACHMENT for the duration of `find_stream_info`, so neither holds the pass to its byte ceiling (#466, #858).
- **`RedirectHeaderPolicy.swift`.** Applies to `AVIOReader`'s URLSession delegates and, through `EngineTLS`'s session-level delegate, to every other engine session (audit NET-108). Range and non-credential extra headers survive cross-host redirects (header-dependent proxies, #8). Credential headers (Authorization, Cookie, Emby/Jellyfin tokens) are replayed only to a same-host target with no TLS downgrade, and removed otherwise, so presigned redirect targets neither 400 on conflicting auth nor see the media-server token (#126). `CredentialScope` applies the same rule to every URI a playlist names: the relay, the #316 subtitle proxy, the audio tap and the live rendition fetch send the credentials only to the URL the host handed over, and allowing a fetch never grants them (audit NET-109).

### `Diagnostics/`

| File | What it does |
| --- | --- |
| `EngineDiagnostics.swift` | `engine.diagnostics`: timer-sampled values (`liveTelemetry`) as a separate `ObservableObject`. |
| `EngineLog.swift` | Gated OSLog output with severity levels (`.verbose` is suppressed from the default and from the host handler). |
| `FFmpegLogBridge.swift` | `av_log_set_callback` funnel: FFmpeg's internal warnings come out through `EngineLog`. |
| `LiveTelemetry.swift` | Value type emitted at 1 Hz. See note. |
| `FourCC.swift` | Printable FourCC rendering for codec-tag diagnostics. |
| `LiveTelemetrySampler.swift` | @MainActor 1 Hz sampler that reads existing subsystem counters and builds `LiveTelemetry` snapshots. |
| `PacketBalanceTracker.swift` | Process-wide AVPacket alloc/free balance counter for leak diagnostics. |
| `SubtitlePrefetchTelemetry.swift` | Live gauge for the #151 forward prefetcher (lead, park, link yield, exit reason), plus the #250 fence its banked read position belongs to. |
| `SubtitleResolutionStatement.swift` | Value and formatter for the #250 line: the decode window clamped to a fenced harvest frontier, with the frontier's source (`via=prefetch\|eof\|pump`) alongside so the number's worth is clear. |
| `PacketTimingProbe.swift` | Offline differential probe (#93 judder): raw demuxer packet timing per open profile, before NOPTS repair and muxing. Backs `aetherctl pktdump`. |
| `AudioTapProbe.swift` | Headless native-session tap check (#95): `LoopbackAudioReader` decode to mono 48 kHz WAV. Backs `aetherctl audiotap`. |
| `AVFoundationOffMain.swift` | Off-main hop for batched synchronous AVFoundation property reads (#134). Figplayer-backed getters are sync XPC round trips, and a busy media server would otherwise block the main thread into a watchdog kill. |
| `AVPlayerItemDiagnostics.swift` | Item-bound log snapshots, merged notification/failure reads, bounded shared admission and asynchronous counter retirement. |
| `MallocBlockCensus.swift` | In-process census of live malloc blocks by size class (#220), so a step in resident memory can name the allocation instead of guessing it from a block count and a total. |
| `MallocBlockCensusTrigger.swift` | Captures that census when memory jumps. Every recorded kill is flat and then steps inside a single 30 s memprobe sample, so a periodic sampler can never catch the allocation (#220). |
| `ThreadCPUSampler.swift` | CPU time per thread group between two samples (consumed time, including ended threads): the `cpuprobe` line next to every memprobe. Public, so a host can profile its UI from a field log. |
| `VMRegionCensus.swift` | Per-`user_tag` census of the dirty + swapped pages `phys_footprint` counts, as a delta against the session's first tick. Names the region a rising footprint rose in when every itemized bucket (heap census included) is flat, which is where AE#445 kept ending up. |
| `SubtitleDeliveryStatement.swift` | Value and formatter for the #357 line. See note. |

Notes:

- **`LiveTelemetry.swift`.** Instant / average bitrate, buffer, network, dropped frames, observed FPS, A/V sync gap, plus subsystem byte counters. The software path reports its own read bytes, throughput, reader runway (`readerWindowAheadBytes`), decoded cushion (`displayCushionSeconds`) and dropped / late frames (#306). `forwardBufferSeconds` stays nil there, because a pump held back by the renderer has no seconds-deep reservoir to report.
- **`SubtitleDeliveryStatement.swift`.** States what a drain tick did with the packets it found, so "nothing appeared on screen" can be attributed from outside instead of guessed from a missing log line. `harvestHole` names the tick that decoded nothing on purpose, which would otherwise read as `empty` (#362). `landingWithheld=` counts the sets refused the landing because the ground between them and the playhead was never read (#416).

### `Disc/`

| File | What it does |
| --- | --- |
| `DiscReader.swift` | Disc detection and routing: local `.iso` URLs and custom ISO readers into the demux path. Lists titles and threads the selected one (DVD vs Blu-ray). |
| `DiscImageMediaType.swift` | The `Content-Type` values (and, under `application/octet-stream`, the sector-16 volume signatures) that send an extensionless HTTP URL to the disc adapter, plus the process memo of URLs found to be discs (AE#860). |
| `DiscMetadata.swift` | Public `TitleInfo` / `ChapterInfo`, plus the internal disc title and chapter model (45 kHz ticks, extent keys). |
| `ISO9660Reader.swift` | Read-only ISO9660 bridge-filesystem reader (DVD-Video images). |
| `DVDIFOParser.swift` | DVD VMGI TT_SRPT title list, plus each VTS IFO program chain (per-title duration and chapters) and stream attribute tables (track languages, declared subpicture streams). |
| `DVDSubpictureAssembler.swift` | Joins a DVD subpicture's PES fragments for the streams the engine declares from the IFO (the `dvdsub` parser's job, which libavformat only does for streams it created itself). |
| `DVDTitleSelector.swift` | Groups DVD title sets' content VOBs into selectable titles (whole VTS, largest first). |
| `ConcatIOReader.swift` | Synthetic seekable `IOReader` that joins byte extents (DVD VOBs / Blu-ray M2TS clips) into one source. |
| `UDFReader.swift` | Read-only UDF 2.50 reader (Blu-ray BDMV, including the metadata partition and fragmented-file allocation descriptors). |
| `MPLSParser.swift` | Blu-ray `.mpls` playlist parser (clips, duration, PlayListMark chapters, STN-table track languages). |
| `BDTitleSelector.swift` | Lists Blu-ray playlists as selectable titles (longest first; short menu / decoy playlists filtered out). |
| `DiscRecognitionCache.swift` | Remembers `DiscReader.wrap` per URL + title index, so disc recognition does not re-run on every subtitle / track switch (important for remote-ISO track switches, #76). |
| `DiscInspector.swift` | Diagnostic mirror of `DiscReader.wrap` for `aetherctl disc-inspect` (titles, chapters, recognition stages). |

### `Display/`

| File | What it does |
| --- | --- |
| `DisplayCriteriaController.swift` | AVDisplayManager content-rate / dynamic-range hints (native path). |
| `FrameRateSnap.swift` | Snaps to standard rates (23.976, 24, 25, 29.97, 30, 50, 59.94, 60). |

### `FrameExtractor/`

| File | What it does |
| --- | --- |
| `AetherEngine+FrameExtractor.swift` | `makeFrameExtractor()` convenience for the currently loaded URL. |
| `DolbyVisionStillConverter.swift` | `DolbyVisionStillReshaping` trait. Applies the RPU-carried DV colour transform to a DV P5 / P10.0 base-layer frame (IPT-PQ-C2, not YCbCr), so scrub stills lose the green and magenta cast (#103). |
| `FrameExtractor.swift` | Off-playback still extraction actor: serial decode queue, cancel-supersede, idle-close. |
| `FrameDecodeContext.swift` | Isolated FFmpeg demux + decode + sws_scale → `CGImage` (thumbnail / preview / snapshot). |
| `FrameCache.swift` | Bounded LRU: stores isolated per mode, thumbnails bucketed by second. |
| `FrameTypes.swift` | `FrameMode` (`.thumbnail` / `.preview` / `.snapshot`). |
| `HDRToneMapper.swift` | zscale + tonemap libavfilter graph: HDR (PQ / HLG, BT.2020) stills → SDR BT.709. |

### `IO/`

| File | What it does |
| --- | --- |
| `IOReader.swift` | Public custom byte-source protocol and `MediaSource` (the `load(source:)` input). |
| `DataIOReader.swift` | Ready-made in-memory `IOReader` over an immutable `Data` buffer. |
| `FileIOReader.swift` | Seekable `IOReader` over a local file via `FileHandle` (multi-GB ISO images). |
| `HTTPDiscIOReader.swift` | Seekable `IOReader` over a remote HTTP(S) disc image with adaptive read-ahead (the network counterpart to `FileIOReader`). |
| `ProgressiveRangeStream.swift` | `HTTPDiscIOReader`'s playback path: a bounded FIFO over ranges of up to 64 MiB whose bytes reach the demuxer as they arrive (#1007). Once it has run, a seek pays one base-size fetch and the continuation streams again. Each stream logs one summary line at close (rate while not held, ranges, worst time to first byte, holds, read waits). |

#### `IO/HLSIngest/`

| File | What it does |
| --- | --- |
| `HLSLiveIngestReader.swift` | Public forward-only `IOReader` that ingests a live HLS upstream (resolver, playlist poller, segment fetcher, companion audio-rendition reader). |
| `HLSPlaylist.swift` | Line-based parser for a subset of RFC 8216 (master / media playlists). |
| `HLSPlaylistTracker.swift` | Pure segment cursor: duration-capped edge join, window-slide rejoin, stall budget. |
| `HLSSegmentDecryptor.swift` | AES-128-CBC clear-key segment decryption (key fetch and memo, PKCS7). |
| `PackedAudioSegments.swift` | Packed-audio rendition support: `LiveSegmentFormat` classification and ID3 PRIV timestamp parser (raw ADTS segments). |
| `ByteFIFO.swift` | Bounded blocking byte queue between the fetch loop and the demux thread. Empty writes do nothing, invalid read lengths return an error, and only a finished, drained queue returns EOF. |
| `HLSIngestError.swift` | Typed terminal errors (encrypted, fMP4, unreachable, invalid, stalled). |
| `LiveIngestSourceInfo.swift` | Internal seam: upstream segment cadence (shapes TARGETDURATION and blocking-reload eligibility) and `DualSourceMergeOrder` for the dual-source DTS merge. |
| `HLSVODIngestReader.swift` | Ingest reader for an immutable ENDLIST playlist. Seeks restart the source at the segment before the requested playlist time, on an elapsed-media-time axis (the EXTINF sum) rather than the container's PTS. |
| `HLSCarriageProbe.swift` | Reads a live source's video carriage from its playlist and the first segment's PMT, so the #168 verdict is available while the native mount is still in its watchdog grace, instead of seconds after (#293, #296). |
| `LiveArrivalCadenceMeter.swift` | Measures how often a live upstream really delivers new segments (interval between batches plus the currently open gap), the signal LL-HLS shaping trusts instead of a self-reported TARGETDURATION. Closed intervals are reported separately, because the seal may not be taken from a gap that the first-serve gate itself is holding open (AE#447). |

### `Native/`

| File | What it does |
| --- | --- |
| `AudioLookahead.swift` | Software live feeder: audio look-ahead pump policy and cursor state. Audio lead independent of video decode speed, live-edge underrun rebuffer (#107). |
| `Issue93ItemDeathRevive.swift` | Bounded revive budget (`ItemDeathReviveGate`) for items killed by accumulated -12889 media timeouts (`failedToPlayToEndTime`, #93 round 3). |
| `MasterFallbackDecision.swift` | Pure master → media playlist fallback decision (#98, #130). Maps a master-rejection item failure (-11868 external SDR, -11848 HDR on SDR, -1002 all variants filtered at parse) to a reactive re-serve. |
| `NativeAVPlayerHost.swift` | Native path: AVPlayer host bound to the loopback HLS-fMP4 URL. Awaits the real seek landing (deadline-bounded, first resume wins, #129) and hides the stale clock during a seek. |
| `SoftwarePathEscalation.swift` | Native path, last rung: a CoreMedia-domain failure (AVPlayer refusing the media, not the source) is offered to the engine's own decoder once per session instead of ending it, since every recovery above reloads the same bytes (AE#561). |
| `RemoteHLSMediaSelection.swift` | Remote-HLS bypass (#154): pure loopback→bypass reroute decision for non-live m3u8 sources (FFmpeg has no network), and legible `AVMediaSelectionGroup` → `subtitleTracks` mapping (synthetic ids from 200000). |
| `SoftwarePlaybackHost.swift` | Software path: runs the demux loop, decoders, renderer and synchronizer. |
| `SoftwarePlaybackHost+AudioProducer.swift` | Software path: picks and builds the audio producer for the session's track. Every unavailable Atmos route falls back to the PCM decode (logged). |
| `VideoSessionRetryPolicy.swift` | Software path: when to retry a refused video-session rebuild while the picture is on screen. Four quick attempts at keyframes, then one every 30 s, never a terminal error. |
| `SoftwareFlushRecovery.swift` | Software path: pure rules for putting a flushed or failed video/audio output queue back to work (triggers; seek versus wait for the next keyframe). |
| `AirPlayPlaylistDecision.swift` | Pure decisions for the wireless-AirPlay loopback rewrite: whether a receiver gets the master or the media playlist, and whether a route change rebuilds the session or swaps its item (a sequential origin, a forward-only live source). Kept separate and testable offline like `MasterFallbackDecision` (#86, #227, #526). |
| `NativeLegibleDeselectPin.swift` | Stops AVKit's ready-time legible auto-select from turning on a rendition the host never asked for (Sodalite#38), and publishes the caption requests the system makes itself as `systemCaptionRequest`, by BCP 47 language rather than by ordinal (Sodalite#65). |
| `RemoteHLSFormatDetection.swift` | Dynamic-range classification for the `nativeRemoteHLS` bypass, read from AVPlayer's own track format instead of a second origin probe, which that path exists to avoid (#168). |
| `RemoteHLSStreamDescription.swift` | The rest of that read-back for stats panels: delivered dimensions, colour description and avcC/hvcC profile as a `VideoStreamFormat`, and the item's audio tracks as `TrackInfo` (codec, channels, rate, dec3 JOC). |
| `RemoteHLSIngestFallback.swift` | Moves a bypass session onto the live-ingest loopback when the master advertises HEVC / DV / AV1 but delivers MPEG-TS, a carriage AVFoundation builds no video track for (#168). |
| `RemoteHLSMasterRewrite.swift` | Declares host-supplied sidecar subtitles as legible renditions on the bypass by rewriting the origin master, since media selection on an HLS asset comes only from the playlist (#316). |
| `RemoteHLSSubtitleProxy.swift` | Puts a loopback origin in front of that remote master: two playlist GETs, a rewrite and a socket. Anything that does not line up keeps the plain origin URL (#316). |
| `RemoteHLSSubtitleProvider.swift` | Serves only what the proxy injected (`/master.m3u8`, `/subs_N.m3u8`, `/subs_N_0.vtt`). The A/V variants still point at the origin, so no media byte moves off it (#316). |
| `RemoteHLSReadinessDeadline.swift` | The terminal state the bypass never had: an origin that answers everything while AVFoundation can build no track from it, which no failure signal reports (#334). |
| `RerouteVerdictMemory.swift` | Bounded, expiring memory of master URLs whose carriage watchdog fired, so a retune after an ingest death lands on the working path instead of paying for a full mount plus grace again (#199). |
| `SWClockAnchorPolicy.swift` | Where the software demux loop anchors the synchronizer clock on the first decoded sample: as-is for files and resumes (the intrinsic A/V lead-in survives), at the sample for a source joined mid-stream (#107). A sample behind the anchor is resume preroll and never moves it (AE#724). |
| `SWKeyframeSnap.swift` | Where a seek on the software host's AV1 through dav1d lands: the keyframe nearest its target, within 10 s and never across the playhead, from the packet cache's retained keyframes and the container's index. Exact when neither reaches the target (Matroska Cues arrive only with a demuxer reposition). `AetherEngine.snapsAV1SeeksToKeyframes` turns it off for comparisons. |
| `SeekResumeIntent.swift` | Whether a seek on a demuxer-driven host re-arms the clock at `lastRate` or parks it at 0, for the second seek issued inside the window its predecessor cleared (#292). |
| `SoftwareBufferFrontier.swift` | How far ahead of the clock the software path really holds decoded video, and how that folds into the `bufferedPosition` a host reads (#303). |
| `SoftwarePiPSource.swift` | Everything a host needs to build an `AVPictureInPictureController` content source around the software path without AVKit entering the engine: the layer plus the four transport answers behind the sample-buffer delegate. |
| `SoftwareNowPlaying.swift` | The Now-Playing publisher every engine-owned route uses: state-to-card mapping, remote-command routing (track commands included) and the sink, behind small protocols for the info and command centers so tests run on fakes. Undoes only its own changes at stop. |
| `NowPlayingArbiter.swift` | Which engine in the process holds the shared Now-Playing centers: the last one to claim (start playing, or `claimNowPlaying()`); waiting engines take over in claim order. |
| `StartupReadinessGate.swift` | Outcome of one startup-readiness attempt: the reloaded item became playable, died, or ran out the settle window without doing either. |

### `Network/`

| File | What it does |
| --- | --- |
| `HLSLocalServer.swift` | Native path: local HTTP server for playlist and segments (all interfaces for AirPlay, every path behind a per-session token, loopback URLs handed to the local player). See note. |
| `URLRequest+ContentSniffing.swift` | `URLRequest(engineURL:)`, the one way the engine builds an origin request. It turns off CFNetwork's content sniffing, which otherwise holds back a `text/plain` or untyped response, refusals included, until 512 body bytes or the end of the connection (AE#986). |

Note on `HLSLocalServer.swift`: it writes the master, so it decides the audio rendition's attributes. `EXT-X-MEDIA:TYPE=AUDIO` carries `LANGUAGE` (AE#458) and `CHANNELS`. The segment provider answers `CHANNELS` (`"16/JOC"` for a stream-copied E-AC-3 JOC track, the served bed count otherwise), and it is omitted when the provider has no rendition to attribute. An untagged track has no rendition, unless it is a stream-copied JOC one, which gets one without `LANGUAGE` so it can carry `CHANNELS` (AE#726).

### `Renderer/`

| File | What it does |
| --- | --- |
| `SampleBufferRenderer.swift` | Software path: `AVSampleBufferDisplayLayer` + B-frame reorder, HDR10+ attachments. `flush(removingDisplayedImage:)` holds the last frame through a seek (#90). The decode thread reaches the layer only through its `sampleBufferRenderer`, taken once on the main actor (#351). |
| `SubtitleFrameCompositor.swift` | Draws active cues into decoded software-path frames while PiP is active, since the system PiP window shows only the sample-buffer layer. Playback wins: every failure path returns the original buffer untouched. |

### `Subtitles/`

| File | What it does |
| --- | --- |
| `ASSScriptBuilder.swift` | Rebuilds raw ASS event cues + `TrackInfo.assHeader` into a complete script for whole-file renderers. |
| `ExternalSubtitleTrack.swift` | Host-facing descriptor for external subtitle files registered as first-class tracks (synthetic `TrackInfo` ids, #88; `sourceStreamIndex` addresses one stream of a container URL, #266). |
| `Issue100PGSStaleArrival.swift` | Holdback (`PGSStaleArrivalGate`) for PGS cues that arrive behind the playhead (#100). See note. |
| `MovTextSampleBuilder.swift` | Stateless ASS/SSA → plain-text cleaner for cue bodies, used by `WebVTTBuilder` when serving a native rendition. The name predates the in-band tx3g path, which did not conform to HLS and is gone. |
| `NativeSubtitleCueStore.swift` | Owns the decoded-cue array behind a native WebVTT subtitle rendition and the overlay tap feed. Deduplicated; filled by the pump tap (embedded) or one whole-file decode (load-declared external, #88) (#55, Sodalite#32). |
| `SidecarBitmapSource.swift` | A bitmap sidecar's packets in a store of their own, drained around the playhead like an embedded track (#921). |
| `SubtitleRectText.swift` | Plain-text and raw ASS event-line extraction from subtitle rects, shared by the inline and sidecar decoders. |
| `WebVTTBuilder.swift` | Builds a plain-text WebVTT body (ASS markup stripped) on the AVPlayer timeline for the separate HLS SUBTITLES rendition, so AVKit renders subtitles in PiP (#15, #55). |
| `SubtitlePacketStore.swift` | Session-long store of compressed subtitle packets harvested from the owning host's demux pump (#112 rework). See note. |
| `SubtitleHarvestCoverage.swift` | Which spans of the source the harvest runs actually read (#416). See note. |
| `SubtitleOverlayDrainer.swift` | Playhead-paced decode planning for the overlay (#112 rework). See note. |
| `SubtitleCaptionStyle.swift` | The user's system caption style (font, size, colours, opacity, edge style) for the software host's text rendering, with `current()` and `observeChanges(_:)`. A field is set only where it differs from the system default. |
| `SubtitleForwardPrefetcher.swift` | VOD-only subtitle side reader that fills the same store up to playhead + drain lead, past the producer's own forward park, so a host advance sync offset finds cues (#151). |
| `SideReaderLinkPolicy.swift` | Who gets the source link when the video path and a subtitle side reader both want it. On Matroska a "subtitle-only" reader still pulls every block off the wire, so the video path has priority, with a bounded grace and a yield ceiling (#240). |
| `PQSubtitlePalette.swift` | Converts a PQ-coded PGS palette entry (UHD Blu-ray HDR) to sRGB against the BT.2408 graphics white, applied per display set on a PQ source (#1006). |
| `SubtitleImageOCR.swift` | On-device recognition of bitmap subtitle images (PGS / DVB / DVD) into plain-text cues for the native rendition. Lossy by design; the fullscreen overlay keeps the pixel-accurate bitmaps. |
| `SubtitleOCRPendingState.swift` | End resolution for pending compositions in the OCR worker, matching the sidecar rules: a composition still open at the next composition or clear event ends at that event's PTS. |
| `WebVTTCueSettings.swift` | WebVTT cue settings (`line`, `position`, `align`) mapped onto `SubtitleTextPlacement`. libavcodec's decoder drops them from the ASS line it builds; the demuxer keeps them as packet side data (#233). |
| `WebVTTSegmentParser.swift` | One parsed WebVTT segment of a live SUBTITLES rendition. Cue times are in the segment's own local clock (a counter providers run for days), and placement comes from the playlist geometry rather than the `X-TIMESTAMP-MAP` the spec offers (#359). |

Notes:

- **`Issue100PGSStaleArrival.swift`.** Catch-up bursts resolve through their successor's trim instead of flashing open-ended placeholder windows on the overlay (#100). The hold and the reconstruction candidate belong to one position, so a reset tick drops them before arming the next pass (#357; otherwise the first trim after a seek republishes pre-seek history as the active line). A cue behind the playhead can be the landing's active line only where the harvest reports having read the ground between the two (`groundIsRead`, #416).
- **`SubtitlePacketStore.swift`.** Written on the pump thread, read by the MainActor drainer, all state lock-guarded. `firstPTS(streamIndex:after:)` is where an open bitmap set reads its authored end, since a display set is closed by whatever packet follows it (#362). `hasReadSpan(from:through:)` says whether anyone read a stretch, which every answer based on the store's silence depends on (#416).
- **`SubtitleHarvestCoverage.swift`.** One span per run, anchored where a reader positioned and extended as it goes. A PGS set claims the landing when the store is empty between it and the playhead, but over ground nobody read that silence proves nothing, and the packets alone cannot tell the two apart (#416, the ledger #362 round 2 named and left unbuilt).
- **`SubtitleOverlayDrainer.swift`.** Reads packets from the store near the playhead into the existing apply path, so the stale-arrival gate, trim state machine and retention stay relative to the playhead. `harvestGapCut` stops a tick where the store's harvest order breaks, not where its gaps are widest, so a hole a restarted pump has not filled yet is waited on instead of skipped forever (#362). It also stops where the coverage ledger says nobody read the span between two entries, the forward re-anchor's hole that order cannot show (#941). Where the ledger has heard from a reader it decides alone, so a re-harvest over ground the prefetch already read is not a hole (#1021); order is the rule only on a store with no ledger.

### `Video/`

| File | What it does |
| --- | --- |
| `HLSVideoEngine.swift` | Native path: session orchestrator (start/stop, producer construction and restart, shift handling). |
| `KeyframeStillLadder.swift` | Native VOD: which keyframe the sparse scrub-still ladder reads next (one a minute, then every 30 s, nearest the playhead first) and whether the origin is idle enough to read it (nothing in flight or queued, no recent refusal, 30 s buffered). Lets `scrubPreviewFrame` answer beyond the resident window on a one-connection plan. |
| `HLSVideoEngine+AudioRoute.swift` | Native path: audio cascade of stream-copy, then FLAC bridge, then video-only. |
| `HLSVideoEngine+SegmentPlanning.swift` | Native path: keyframe / uniform segment plans, extradata and AAC fixups. |
| `HLSVideoEngine+LiveReopen.swift` | Native path: live source-loss recovery (capped-backoff reopen on the same timeline), and the VOD backpressure-wedge re-anchor plus consumer re-engage nudge. The nudge re-reads the rendered position at nudge time, so the zero-tolerance seek never lands behind the on-screen frame (#115). |
| `CodecRoutePolicy.swift` | Native path: DV / HDR / codec routing decisions (track types, CODECS strings, VIDEO-RANGE). |
| `AnnexBSampleConverter.swift` | Native path: the session muxer rewrites Annex-B HEVC samples to length-prefixed NALs, keeping in-band VPS/SPS/PPS. movenc's own conversion under `hvc1` drops them, so a stream that sends a new PPS mid-title stopped decoding at the change (PR #703). |
| `FelCurves/` | `DolbyVisionFelCurves` trait. See note. |
| `DoviRpuConverter.swift` | libdovi RPU surgery for both routes. See note. |
| `DoviRpuConverter+Probe.swift` | Diagnostic DV-conversion probe (`doviConvertProbe` / `DoviConvertProbeResult`); backs `aetherctl dovitest`. |
| `HEVCPictureOrderCount.swift` | H.265 picture order count (8.3.1) of one layer from parameter sets and first slice headers, without decoding; nil for anything it cannot follow (#702). |
| `DoviDisplayMetadata.swift` | Software FEL path (`DualLayerDolbyVision` trait): sets `DolbyVisionRPUData` (the Profile 8.1 RPU without its NAL header) and `DolbyCompatibilityID` (the CFString "1", never a number) on every emitted buffer, or clears both. tvOS consumes them in backboardd. |
| `DoviDisplayMetadataDebug.swift` | DEBUG-only pin test (`DualLayerDolbyVision` trait): swaps in a captured RPU on a duty cycle, the on-device consumption test. |
| `DoviRpuSurvey.swift` | L1 / L2 display-metadata survey over a title's RPUs (no decode, no GPU); backs `aetherctl dvsurvey`. |
| `AetherEngine+FelProbe.swift` | `DualLayerDolbyVision` trait: FEL decode probe behind `aetherctl feltest`, and the `--cycle-el` residual switch. |
| `AetherEngine+DolbyVisionTest.swift` | DEBUG-only, `DualLayerDolbyVision` trait: `@_spi(Diagnostics)` hook (not host API) that arms the pin test from a debug menu or `aetherctl play --dv-pin`. |
| `Issue65LivelockBreakers.swift` | Pure backpressure-wedge detection (`BackpressureWedgeDetector`) that breaks the VOD HLS scrub-burst livelock (#65); `seekIsWedged` starvation check and `SeekResumeGuard` single-resume latch for the deadline-bounded seek. |
| `Issue99MuxerFailureRevive.swift` | Bounded revive for a VOD pump that died with `muxerFailed` (#99): the first cut firing before any bridged audio reached the muxer (dec3 box) no longer ends the session. |
| `SlowServeSignal.swift` | One-shot slow-serve timer that arms the server's early chunked header (keeps time-to-first-byte under AVPlayer's ~3.5 s -12889 window, #93 round 3). |
| `VideoSegmentProvider.swift` | Native path: segment provider facing the playlist (live sliding window, restart heuristics, sparse-hole waits gated on producer coverage, #129). |
| `MarchRateTracker.swift` | Native path: the producer's march rate from segment completions, cut at restarts and backpressure parks. Feeds the provider's wait-or-restart decision for a short forward jump (#932). |
| `HLSSegmentProducer.swift` | Native path: pump loop that reads from the Demuxer, feeds `MP4SegmentMuxer`, and cuts fragments keyframe-gated in decode order so the IRAP opens its segment (#92). Also SSAI program-switch detection and the no-cut watchdog. |
| `VODSegmentCutter.swift` | Native path: decode-order, keyframe-gated VOD segment cutter (the IRAP opens its segment, #92). |
| `PlanBoundaryAxis.swift` | Which axis a container stamps its index entries on, and so which packet timestamp the cutter gate may compare with a plan boundary: decode for a mov/mp4 sample table, presentation for a Matroska Cue (#358, AE#561). |
| `VideoConfigRecord.swift` | The `hvcC` / `avcC` config record and the framing question that hangs off it (#365). See note. |
| `H264SPS.swift` | Hand-written H.264 SPS parser (SSAI ad-creative coded dimensions / codec config). |
| `H264CompositionOffsetRepair.swift` | Rebuilds the presentation axis of an MP4 whose writer dropped `ctts` while the bitstream still reorders pictures (#409, HEVC #699). See note. |
| `OutputTimestampSanitizer.swift` | Last-stage DTS/PTS monotonicity guard before the fMP4 mux (SSAI splices, program restarts). |
| `CFRFrameGrid.swift` | Exact frame grid for a constant-rate VOD track on a coarse time base: the muxer's video time base and the slot each on-grid PTS/DTS lands on (AE#886). |
| `PulldownCadenceRetimer.swift` | Puts 24p film carrying 2:3 pulldown timestamps onto the frame grid, one slot a frame, while the recent cadence is film (Sodalite#236) |
| `SourceFrameRateMeasurement.swift` | Fits the frame rate to the head packets when the declared one is not a standard rate (Sodalite#236) |
| `RestartCoalescer.swift` | Merges a burst of producer-restart requests into one in-flight and one settled target (rapid seeking, AetherEngine#35). |
| `LiveWindow.swift` | Live path: session-relative DVR timeline (seconds since the first frame), shared by the native and software live paths. |
| `MP4SegmentMuxer.swift` | Native path: session-long fragmented-MP4 muxer (`+empty_moov+default_base_moof+frag_custom+delay_moov`). |
| `NALUnitChain.swift` | Last-stage payload guard before the fMP4 mux: a video sample whose length-prefixed NAL chain overruns it is cut at its last complete unit, because Apple's parser answers one such sample with -19602 for the whole segment (AE#561). |
| `AudioLanguageMap.swift` | Native path: the ISO 639-2/T code an audio track is declared with in the master's `EXT-X-MEDIA:TYPE=AUDIO` rendition and written into its `mdhd` (AE#458). See note. |
| `FragmentSplitter.swift` | Native path: splits the mp4 muxer's avio output into `init.mp4` (ftyp+moov) and per-segment moof+mdat files. |
| `PacketRingBuffer.swift` | Live path: keyframe-indexed, disk-spooled packet ring behind the software DVR rewind. Append-only chunk files, a 24-byte index record per packet, eviction by time and by the session retention budget, evict-and-retry when the volume or quota is full. |
| `SessionDirectoryLiveness.swift` | The flock marker a session directory under `aether-segments/` holds while its owner lives, so the stale-session sweep spares a live `SegmentCache` or DVR ring (AE#451, SEG-105). |
| `SegmentCache.swift` | Native path: producer/consumer segment store with backpressure, scrub-aware eviction, and byte-budgeted VOD backward retention (back-seeks without restarts). |
| `VTCapabilityProbe.swift` | AV1 system-decode probe and per-format `canHardwareDecode` check for H.264 / HEVC profiles (Intel Macs, older chips, #2). Gates codec routing; VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 and interlaced H.264 always route software (see `VideoRoutingPolicy`). |
| `LiveCadencePolicy.swift` | Turns the observed arrival cadence into the two LL-HLS decisions (served TARGETDURATION, blocking-reload eligibility), re-evaluated on every manifest render instead of trusting a bursty origin's own number. |
| `PrefetchDiskBudget.swift` | Disk bound for an opt-in whole-source prefetch. The hard window is never evicted, so the budget only bounds what lives outside it (#207). |
| `RetentionClaims.swift` | Process-wide ledger of the running sessions' disk allowances. A new session is sized from the free space minus what the others may still write, so concurrent engines cannot each claim a quarter of the same space (#687). |

#### `Video/Metal/`

The `Dovi*` files build only with the `DualLayerDolbyVision` trait.

| File | What it does |
| --- | --- |
| `FrameChain.swift` | The GPU frame chain (AE#957, AE#1039): a decoded 8 or 10-bit 4:2:0 frame to half-float RGB, through a list of `FrameChainStage`s, and back to the input's format at the target size, in one command buffer. `PassThroughStage` and `LineArtStage` are its stages; `FrameUpscaler` runs it for the `.lineArt` plan. |
| `LineArtShaderSource.swift` | Generated (`Scripts/generate-line-art-shader.py`) from Anime4K's Upscale CNN x2 (S), MIT: four half-precision convolution kernels and the depth-to-space kernel, compiled at runtime. |
| `UpscaleShaderSource.swift` | NV12 / RGBA kernels around MetalFX for the automatic upscale stage, and the Y'CbCr matrix from a buffer's tag. |
| `DoviFelChromaFormat.swift` | Chroma sampling of the composed frame: 4:2:0 (the composition), 4:2:2 and 4:4:4 (experimental, `AETHER_FEL_CHROMA`), and each format's CoreVideo layout. |
| `DoviFelComposer.swift` | BL + EL + RPU composition: pipelines compiled at runtime, pooled P010 output, `composeAsync` bounded at `maxFramesInFlight` with completions on its own serial queue; RPU → `DoviMetalParams` parsing. |
| `DoviShaderSource.swift` | Luma / chroma compose kernels (reshaping, inverse NLQ, bilinear EL upsampling, ordered dither) and the ABI layout probe, compiled at runtime. |
| `DoviMetalParams.swift` | Swift mirror of the kernel parameter structs and their byte-exact serializer. |

Notes:

- **`FelCurves/`.** `FelCurveLookahead` holds back one GOP between demuxer and producer, keeps a FEL source's mapping in the Profile 8.1 RPU, and folds its luma residual into the luma curve per scene. `FelCurveSampler` / `FelCurveFit` / `FelCurveModel` are the luma sampling, the fixed-pivot least-squares fit, and the RPU side. `FelCurveFoldRun` backs `aetherctl felcurves`.
- **`DoviRpuConverter.swift`.** Native path: per-packet Profile 7 → 8.1 rewrite (convert the type-62 RPU, drop the type-63 EL). Software FEL path: `separateDualLayers` also lifts the EL into its own packet and returns the composer's reshaping parameters, plus the 8.1 RPU attached as display metadata.
- **`VideoConfigRecord.swift`.** movenc decides whether to Annex-B-convert every sample from the extradata, not from the packet. So a source that carries Annex-B parameter sets while muxing length-prefixed NALs has each sample rewritten by a converter that finds no start codes. This file mirrors movenc's own two tests instead of a similar-looking predicate, because predicting that decision wrong is the whole bug.
- **`H264CompositionOffsetRepair.swift`.** libavcodec's H.264 or HEVC parser supplies each access unit's picture order count without decoding. A fail-closed head sample settles the ladder and the shift, and packets are rewritten onto the timeline a correct muxer would have written, so the native path and hardware decode are kept. A writer that forced the decode ladder to be monotonic is rebuilt at the stream's frame rate, measured on its anchors.
- **`AudioLanguageMap.swift`.** ICU handles the twenty ISO 639-2/B bibliographic codes Matroska writes. Then canonicalization handles the ISO 639-3 members CLDR aliases, and passes through the ones it does not. It fails closed on anything ICU can neither resolve nor name.

### `View/`

| File | What it does |
| --- | --- |
| `AetherPlayerView.swift` | One view for both paths: hosts either `AVPlayerLayer` (native) or `AVSampleBufferDisplayLayer` (software). |

### `Sources/AetherEngineSMB/`

The `AetherEngineSMB` product is a separate, opt-in target, so its SMBClient (MIT) dependency never enters the core engine binary. Hosts that need LAN-share playback link it and hand the engine an `smb://` source through the standard `IOReader` seam.

| File | What it does |
| --- | --- |
| `AetherEngineSMB.swift` | Product entry point: opt-in SMB2/3 byte source, depends on SMBClient (pure Swift, NWConnection). Never linked by the core engine. |
| `SMBURL.swift` | Parses `smb://[user[:password]@]host[:port]/share/path` URLs (missing credentials default to guest). |
| `SMBConnection.swift` | Read-only SMB byte source over one share + path via SMBClient (persistent connection + FileReader; NTLMv2 / guest, SMB 2.0.2 / 2.1 only). |
| `ByteRangeSource.swift` | Random-access, read-only byte-source protocol. Keeps the network backend apart from cursor / seek logic for testing. |
| `SMBIOReader.swift` | Bridges a `ByteRangeSource` into the engine's `IOReader` (blocking read through a happens-before semaphore edge). |

### `Sources/aetherctl/`

The `aetherctl` CLI target is documented separately in [docs/cli.md](cli.md).

## Dependencies

| Package | License | Purpose |
| --- | --- | --- |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL-2.1-or-later | Slim FFmpeg 8.1 (avcodec / avformat / avutil / swresample / swscale / avfilter + zimg) for demux, HLS-fMP4 mux, AudioBridge FLAC encode, software-path dav1d decode, and sws_scale YUV → NV12 / P010. avfilter ships a trimmed filter set: zscale + tonemap + colorspace (HDR → SDR still extraction), bwdif + yadif + yadif_videotoolbox + hwupload (software and GPU deinterlacing). Bundles libzvbi for the DVB teletext decoder (#107). Shipped as dynamically linked frameworks, no GPL components. |
| [LibDovi](https://github.com/superuser404notfound/LibDovi) | MIT / Apache-2.0 | libdovi (the `dolby_vision` crate's C API) for live Dolby Vision Profile 7 to single-layer 8.1 RPU conversion (`dovi_convert_rpu_with_mode`, mode 2), so the Apple TV engages real DV on dual-layer UHD-BD remuxes instead of plain HDR10. The software FEL path uses the same library to read the reshaping and NLQ parameters for the Metal composer and to produce the per-frame 8.1 RPU it attaches as display metadata. Prebuilt xcframework, no Rust at the consumer's build time. |
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient) | MIT | Pure-Swift SMB2 client over `NWConnection`, used only by the opt-in `AetherEngineSMB` product (never linked by the core engine). NTLMv2 / guest, SMB 2.0.2 / 2.1. Replaced AMSMB2/libsmb2, which `EPERM`s on tvOS / iOS. |
| [dav1d](https://code.videolan.org/videolan/dav1d) film grain synthesis, ported | BSD-2-Clause | `AV1FilmGrain` and `AV1FilmGrainShaderSource` port dav1d's grain synthesis (`filmgrain_tmpl.c`, `fg_apply_tmpl.c`) to the CPU tables and the Metal pass of `GPUFrameConverter`, so the GPU route's picture matches dav1d's sample for sample. dav1d's notice is kept in both files. |
| VideoToolbox | System | Native path video decode (hardware where available, Apple's bundled software dav1d on iOS / macOS). |
| AVFoundation | System | AVPlayer + AVDisplayManager (native path); AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer (software path). |
| CoreMedia | System | Sample descriptions, format-description tagging, CMTimebase. |
