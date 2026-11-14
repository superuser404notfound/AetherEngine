# Architecture: the native route

The native route is the default for video. The engine reads the source file, repackages its streams as HLS with fragmented MP4 segments, serves that from a local HTTP server, and lets `AVPlayer` decode and present it. Apple's stack does all the decoding.

This page covers that route in depth, plus the parts of a session that sit around it: timestamp repairs for broken files, other ways a source reaches AVPlayer (remote HLS, HLS ingest, DASH), trick play, subtitles, audio routes, backgrounding, Now Playing, source connections, shared outputs and live sources.

Start with the overview in [architecture.md](architecture.md). The other route, the **software host** (the engine decodes with FFmpeg and renders the frames itself), has its own page: [architecture-software.md](architecture-software.md).

**Terms used throughout this page:**

| Term | Meaning |
| --- | --- |
| demux / remux | Split a container (MKV, MP4, MPEG-TS) into its compressed audio and video streams / write those streams into another container without re-encoding. |
| loopback | The engine's local HTTP server on `127.0.0.1`, and the route that plays through it. |
| producer | `HLSSegmentProducer`, the loop that reads packets from the demuxer and writes HLS segments. |
| pump | The producer's source-reading loop. It "parks" (pauses reading) once it is far enough ahead of the playhead. |
| segment plan | The list of segment boundaries the playlist advertises before any segment exists. |
| PTS / DTS | Presentation and decode timestamp of a compressed picture (what `CMSampleBuffer` calls presentation and decode time). |
| composition offset | PTS minus DTS. It is non-zero when the encoder reorders pictures (B-frames). |
| GOP | Group of pictures: a keyframe and the pictures that depend on it. |
| VOD / live | A finite title with a known duration / a stream that keeps growing. |

Contents:

- [Native AVPlayer pipeline (default)](#native-avplayer-pipeline-default)
  - [Segment plan](#segment-plan) and [cutting segments at runtime](#cutting-segments-at-runtime)
  - [Restarts keep the same timeline](#restarts-keep-the-same-timeline)
  - [Constant-rate frame grid](#constant-rate-frame-grid) and [2:3 pulldown timing](#23-pulldown-timing-on-24p-film)
  - [Seeks and the segment cache](#seeks-and-the-segment-cache), [seek deadline](#seek-deadline-and-recovery), [seek events](#seek-events)
  - [Keeping AVPlayer from timing out](#keeping-avplayer-from-timing-out) and [item diagnostics](#item-diagnostics)
- [Timestamp repairs for broken files](#timestamp-repairs-for-broken-files)
- [Native route variants](#native-route-variants): remote HLS bypass, HLS ingest, MPEG-DASH
- [Trick play and scrub stills](#trick-play-and-scrub-stills)
- [Subtitle cue pipeline](#subtitle-cue-pipeline): harvest, prefetch, PGS ends, holes, landings
- [Audio routes and object audio](#audio-routes-and-object-audio)
- [App backgrounding](#app-backgrounding)
- [Now Playing routes](#now-playing-routes)
- [Source connections](#source-connections)
- [Shared outputs and the display switch](#shared-outputs-and-the-display-switch)
- [Live sources](#live-sources): reconnect overlap, replay boundary, playlist renewal, recording

## Native AVPlayer pipeline (default)

The native path works in four steps:

1. libavformat (FFmpeg's container library) demuxes the source.
2. The elementary streams are re-muxed on the fly into HLS-fMP4 (HLS with fragmented MP4 segments).
3. A local HTTP server on an ephemeral port serves them. The player is handed `127.0.0.1:<port>/<session-token>/...`.
4. `AVPlayer` plays that playlist. Apple's stack does all decode, all HDR / Dolby Vision signaling over HDMI, and all audio routing.

The server listens on all interfaces so an AirPlay receiver can reach it over the LAN. It is protected by:

- a per-session path token,
- a cap of 32 connections, 24 of them for non-loopback peers,
- a 10 s head deadline for unauthenticated connections.

This path handles the codecs AVPlayer's HLS-fMP4 pipeline reliably accepts:

- HEVC,
- progressive H.264,
- AV1, on devices with a hardware AV1 decoder.

Interlaced H.264 goes to the software path, which can deinterlace it (#107). Atmos passthrough, the Dolby Vision (DV) HDMI handshake, and HDR10 / HDR10+ tone-mapping by the system all live on this path.

```
Source URL ──► Demuxer ──► [FelCurveLookahead] ──► HLSSegmentProducer ──► SegmentCache
                            (opt-in FEL fold)        (+ AudioBridge for          │
                                                      audio AVPlayer can't take) ▼
                                                                         VideoSegmentProvider
                                                                                 │
                                                                                 ▼
                                                                          HLSLocalServer
                                                                                 │
                                                                                 ▼
                                                                             AVPlayer
                                                                                 │
                                                                                 ├─► VideoToolbox (HW decode)
                                                                                 └─► AVR / speakers (Atmos via MAT 2.0)
```

What the boxes do:

- `HLSSegmentProducer` (the producer) writes the segments into `SegmentCache`. Its `AudioBridge` re-encodes audio AVPlayer cannot take.
- `VideoSegmentProvider` answers the server's requests from the cache. When a request falls outside the cache, it restarts the producer there.
- `HLSLocalServer` is the loopback HTTP server.

Two optional stages plug into this chain: the [Dolby Vision FEL stages](architecture-software.md#dolby-vision-profile-7-fel) (FEL is the full enhancement layer of a Dolby Vision profile 7 disc; the "fold" moves its brightness effect into the Dolby Vision metadata so AVPlayer can play the base layer alone) and the [object-audio render](#audio-routes-and-object-audio). The AVPlayer-output FEL route also taps the producer's reads. On the output side, Atmos reaches the receiver wrapped in MAT 2.0 (Dolby's container for sending Atmos over HDMI).

**Why HLS-fMP4 instead of handing `AVPlayer` the source URL.** HLS-fMP4 is the most permissive input AVPlayer has.

- AVPlayer's progressive-download path does not accept arbitrary MKV containers.
- Even for MP4 it is brittle around Dolby Vision sample-description quirks and EAC3 `dec3` box variants.
- libavformat's `hls` muxer produces bytes identical to `ffmpeg -f hls -hls_segment_type fmp4`, which is what Apple's HLS spec is defined against.

### Segment plan

A VOD playlist lists every segment before any of them exists, so the engine must know every boundary up front. These boundaries come from a keyframe-aligned plan built in `HLSVideoEngine+SegmentPlanning.swift`. It mirrors the `hls` muxer's cut rule: segment N ends at the first IRAP (a random-access keyframe) at or after `(N+1) * targetSegmentDuration`.

The plan needs the source's keyframe positions, read from the container's keyframe index:

- **MKV / MP4:** from a brief cue prewarm, a bounded seek that loads the index (Matroska Cues, or the MP4 `stss` sync-sample table).
- **MPEG-TS / M2TS:** these have no index, so only whatever `avformat_find_stream_info` plus that seek happened to scan.

`keyframeIndexIsTrustworthy` runs three checks before trusting that index. If one fails, the engine uses a uniform-stride plan instead (boundaries at even intervals).

| Check | Rule | What it catches |
| --- | --- | --- |
| Gap | The largest gap between consecutive keyframes stays under a cap. | A clustered TS index gaps by thousands of seconds. Trusting it builds a first segment thousands of seconds long, which the `frag_custom` muxer buffers whole in RAM (#64). |
| Coverage | First to last indexed keyframe spans at least one `targetSegmentDuration`. | A remote MKV whose Cues tail read fails. The prewarm loads nothing; only the keyframes seen at open (the first few seconds) survive. Their gaps are tiny, so the gap check passes, but no keyframe reaches the first segment boundary. The plan would collapse into one whole-file segment, from which AVPlayer loads zero tracks (`kFigAssetError_TrackNotFound`, #91). |
| Tail | The coverage reaches within 60 s of the source duration. | A dense index that stops minutes short is a partial scan, for example an MKV whose Cues are missing or point past EOF, so only what the capped prewarm walked is known. Trusting it cuts a last segment from the final scanned keyframe to the end of the title, which the producer can never finish (PR #703). |

The uniform fallback anchors segment 0 at the content start, so a title that starts late does not advertise empty leading segments.

### Cutting segments at runtime

Every segment starts on its own random-access point and never depends on the segment before it. So a fresh decode at a boundary (rebuffer recovery) shows no corruption (#92).

The producer follows the plan with `VODSegmentCutter`, a cut in decode order that waits for a keyframe:

- A segment opens only at the IRAP that reaches the next boundary. That IRAP is the segment's first sample.
- Its open-GOP leading pictures (pictures after the keyframe in decode order that display before it) stay with it.
- This matches the live path and the `hls` muxer.

Background: [measurements.md, Segment cutting by decode time](measurements.md#segment-cutting-by-decode-time).

**Which timestamp "reaches" a boundary depends on the container.** The plan's boundaries are the container's own index entries, and containers disagree on what an entry means:

- a mov/mp4 sample table holds decode times,
- a Matroska Cue holds a presentation time.

So the gate compares a packet on the plan's own axis (`PlanBoundaryAxis`, picked from the demuxer's format name). Each mismatch breaks playback:

- **Presentation packet against decode boundaries.** A keyframe could reach boundaries beyond its own by its composition offset (a couple of frames on an ordinary encode, 3 s on a remux with an edit list). That used up plan indices that never opened a segment while the playlist still offered them (#358).
- **Decode packet against presentation boundaries.** No keyframe reaches its own boundary on any Matroska file whose video has composition offsets, which is every MKV with B-frames. The gate never opens on the planned IRAP.

  Audio is routed by boundary, not gated, so audio opens each segment instead. Every segment then begins mid-GOP, about one IRAP below its own first random-access point. AVPlayer does not notice while it decodes straight through the boundaries. The first time it has to start decoding at one, it fails with `CoreMediaErrorDomain -19602`. Where that happens depends on the encode, not on elapsed time (AE#561).

`PlanBoundaryAxisTests` pins this with one HEVC stream muxed into both containers, where only the timestamps differ.

### AVC configuration changes

**AVC VOD configuration changes are judged before native muxing.** Some H.264 (AVC) VOD streams change their decoder configuration mid-title. The engine does not rely on a static VOD playlist refreshing an `EXT-X-MAP` (the init segment that carries the configuration) after AVPlayer has already loaded it. Instead, `H264ConfigurationTracker` catches the change before the changed sample reaches the native muxer, and hands the session to the software path.

- **Detection.** It starts from the producer's effective `avcC` (the configuration record in the init segment). It follows length-prefixed SPS/PPS (the parameter sets that describe the stream) in NAL order. Each IDR (an H.264 keyframe) names an SPS, and that SPS is checked against the baseline by its decoder signature (profile through cropping). PPS, VUI and level do not count, because the native decoder takes them in band.
- **Stop.** On a mismatch the pump exits with a typed reason before the changed sample is written. The session keeps the verdict if the pump finishes before its owning load is installed. Producer epoch and load generation checks reject superseded events.
- **Recovery.** The existing `SoftwarePathEscalation` takeover rebuilds the session on the software path, under its normal route and host opt-in constraints. The rebuild starts from the pending user seek or the actual playhead, never from the producer's read-ahead position.

### Restarts keep the same timeline

A restarted producer must write segments on the same media timeline an uninterrupted run would have given them. The loopback server's contract with AVPlayer is "static VOD server", and AVPlayer places fMP4 segments by their `tfdt` (the fragment's base decode time).

Each restart creates a fresh mp4 muxer, and movenc (FFmpeg's MP4 muxer) starts each new instance's timeline at zero by default. Left alone, a restarted segment would carry `tfdt=0` while the playlist places it at its plan offset: a hidden timeline break on every restart. Plain playback hides it, but other consumers break:

- AVKit's legible (subtitle) renderer detaches mid-PiP (Sodalite#32),
- the playhead drifts away from the loaded ranges (#93).

So the engine keeps absolute timestamps:

- The muxer sets `movflags +frag_discont` with `avoid_negative_ts=disabled`, so `tfdt` carries the producer's absolute output timestamps.
- The restart audio gate inherits the session shift (the video shift, rescaled) instead of snapping audio onto the video seam.
- Leading audio at the head of the stream that would map below 0 is dropped, since the muxer no longer absorbs negative timestamps.

The result: a restarted segment is byte-identical to the same segment from an uninterrupted run, except for the per-muxer `mfhd` sequence number. `RestartTimelineContinuityTests` pins this on a committed A/V fixture.

One exception on Matroska sources: the demuxer synthesizes DTS per sample after a seek, which shifts the DTS split and which segment a boundary frame lands in by a frame or two. Presentation timestamps and `tfdt` anchoring still stay the same across restarts.

**Negative timestamps are clamped.** `tfdt` is an `unsigned int(64)`, so with this setting a negative output axis cannot be represented at all. The published first timestamp is therefore clamped at zero (AE#509).

The case this covers: MPEG-TS timestamps are 33-bit and wrap around. When an MPEG-TS's first DTS sits within 60 s of that wrap, libavformat serves every timestamp `2^33` ticks low (`AV_PTS_WRAP_SUB_OFFSET`). Unclamped, a live join there publishes `baseMediaDecodeTime = 2^64 - |dts|` against a playlist starting at 0. AVPlayer then fetches the whole window and places none of it, with no error and no stall.

### Constant-rate frame grid

**The problem.** The video track's output time base (the tick size of its timestamps) is normally the source's, which movenc scales up to at least 10000 (Matroska's 1/1000 becomes 1/16000). That keeps the container's rounding, which hurts on a constant-rate track:

- 23.976 fps on 1 ms ticks reaches AVPlayer as 41 and 42 ms steps.
- At a 59.94 Hz output every second frame sits exactly on a refresh boundary, where half a millisecond of rounding decides which vsync shows it (AE#886).

**The fix.** `CFRFrameGrid` puts the frames on an exact grid (CFR: constant frame rate) for a VOD track when both are true:

- the source tick is 0.1 ms or coarser, and
- the frame rate probes as exactly a standard rate the tick cannot represent.

It then uses a time base with one frame in whole ticks (1/24000 with 1001 ticks for 23.976, 1/24000 with 1000 ticks for 24), anchored at the stream's start time. `HLSSegmentProducer` moves each packet whose source-axis PTS lies within one source tick of a grid slot onto that slot (the DTS onto its own slot, never past the PTS), and rescales everything else as before.

The grid is derived once per session, before the first producer runs, from the stream's declared rate. So every producer of a session writes the same `init.mp4` timescale, and a restarted segment still matches its continuous twin.

**When the declared rate is not a standard rate.** Then `SourceFrameRateMeasurement` fits the rate to the head packets that `find_stream_info` already queued (peeked, not consumed), and the load uses that instead (Sodalite#236). This matters because mkvmerge writes the first frame's duration as a track's DefaultDuration, so film carrying 2:3 pulldown timing declares 20 fps while it runs at 23.976.

### 2:3 pulldown timing on 24p film

**The problem.** Some encodes of soft-telecined DVDs (film stored at 24 fps with flags that tell a player to show it at 59.94 fields per second) keep the film's progressive frames but stamp each with the time its first field would appear on a 59.94 Hz field clock. Frames then last three fields, then two (50 ms, 33 ms), averaging 23.976.

On a 23.976 Hz panel a 33 ms frame can fall between two refreshes and never be shown. Whether it does depends on the vsync phase, which every start and seek re-rolls. The result is a pan that stutters on one pass and plays clean on the next (Sodalite#236).

**The fix.** These frames lie 8 to 17 ms from a grid slot, far past `CFRFrameGrid`'s one-tick tolerance. So on a 24p grid, `PulldownCadenceRetimer` owns every video packet instead:

- It keeps a window of the last 48 packets (decode order) and calls the stretch film when every spacing among them, in presentation order, is two or three fields and they average two and a half. Anything else (true 30p or 60p video, a constant-rate stretch) goes through `CFRFrameGrid.place` unchanged.
- In film, each frame goes to its nearest slot on a 24p grid whose origin follows the film. An edit that drops or repeats a field moves the film one field against the grid; the retimer re-centres on the running mean deviation, so no frame moves more than about one field from its source time.
- A frame only moves where it stays strictly between its neighbours in presentation order, checked against the whole window. Otherwise the grid re-anchors on that frame, or the frame keeps its own time.
- `PulldownCadenceLatch` carries the verdict across the session's producers, so a producer started by a seek retimes from its first frame instead of waiting for its window.

The producer's finish line counts `pulldownRetimed=` next to `onGrid=` and `offGrid=`.

### Seeks and the segment cache

Seeks are demand-driven: `AVPlayer` simply fetches segments at the new position, and the engine serves them.

- If `SegmentCache` holds the segment, the request is a cache hit.
- Otherwise `VideoSegmentProvider` tears the producer down and re-anchors it at the requested index (`restartHandler`, with bursts coalesced by `RestartCoalescer`).

A restart is the expensive path: it re-seeks the demuxer, which is slow on remote sources (#93). Most rules below exist to avoid restarts or keep them cheap.

**VOD cache retention.**

- The cache has a hard window around the target (the segment being played), `[target - backwardWindow, target + forwardWindow]`, that is never evicted.
- For VOD it also keeps already-produced segments outside that window, under a byte budget: 2 GiB, clamped to a quarter of the tmp volume's free capacity. Once full, it evicts the segments farthest from the target first.
- A host can set the byte budget itself with `LoadOptions.sessionCacheByteBudget`. The volume clamp still applies.
- Concurrent sessions share that clamp: each is sized from the free space minus the other sessions' unwritten claims (`RetentionClaims`, #687).
- Because the hard window is never evicted, the budget only bounds the extras around it. That holds by construction as long as the forward window stays at or below the historical 150-segment ceiling (~1.5 GB of 4K HEVC).
- A seek back into the retained span, and the forward march after it, is a pure cache hit with zero producer restarts. Only a seek into never-produced content restarts.
- Live sessions keep a newest-first suffix up to the native DVR retention budget, so the whole advertised DVR window stays resident. Live has no restart handler that could re-produce a deleted segment.

**Whole-source prefetch (opt-in).** A forward window larger than that is an explicit host opt-in through `LoadOptions.forwardBufferSegments` (up to 2700 segments, ~3 h, #207). It drops the budget's 2 GiB default cap but keeps the quarter-of-free-space clamp.

The producer parks once the segments it has written ahead of the consumer target fill that budget, and resumes as eviction behind the playhead frees room (`PrefetchDiskBudget`). So an opt-in prefetch follows the disk budget, not the source length.

**Where a restart seeks.** A non-disc VOD restart seeks to the exact IRAP stored in the segment plan, on the video stream's own timestamp axis, with that timestamp as the lower bound. A seek on the global time axis can land a whole GOP earlier on multi-stream MP4, and the producer then has to read forward to the IRAP, which is a long remote read (#191). Disc plans use folded multi-clip timestamps (one timeline across several clip files) and keep the global-time seek.

**Restarts on a slow link.** These rules keep a slow remote source from turning one restart into many (#93):

- A fetch waiting on an in-flight restart follows that restart's progress instead of burning a fixed retry budget into a 503. It never re-fires a restart at its own stale index.
- The fresh reopen after a wedged restart skips `find_stream_info`, because the session already holds saved codec configs and the segment plan.
- Lazy native subtitle readers wait while a restart runs.
- The first producer of a resumed session anchors directly at the resume segment, instead of producing seg0 into an immediate teardown.

**Holes in the cache.** Scrubbing leaves retained bands of segments with gaps between them, inside the cache's stored min/max index range. So an index inside that range is no proof the segment exists. A fetch inside the range waits (2 s) only when the active producer's forward march actually covers the requested index. Otherwise it restarts at once (#129).

### Seek deadline and recovery

The public `seek(to:)` on the native path waits for AVPlayer's real landing (the first frame shown at the target), so `isSeeking` covers it (#37/#38). The wait is capped at 8 s (#65, #129).

At the deadline the engine sets the published clock to AVPlayer's rendered frame and returns to the caller. It does not stack a second unbounded seek, because repeated source stalls could chain those past 40 s.

After the deadline:

- The original AVPlayer seek stays alive as the recovery intent (`pendingRecoverySeekClockTarget`).
- The producer is re-anchored at the target only when it is really starved. A healthy but slow producer keeps its progress.
- The scrub clock is held while the intent is pending, so recovery nudges cannot bounce it (#37).
- A late landing sets the clock from the rendered frame, re-anchors subtitles once, and reconciles transport state afterwards. Both orders of the landing/deadline race on the MainActor are handled.

Transport state is reconciled from live `timeControlStatus`:

- An external AVKit / MediaRemote play or pause issued mid-seek wins.
- A spurious pause during active stall recovery is re-asserted inside the bounded recovery window.
- A paused scrub still lands paused and never restarts playback (#122).

### Seek events

A host can observe a seek in two ways:

- `isSeeking` / `seekTarget` are a **level**: a seek is in flight, and where to.
- `seekEvents` is a **stream** that says what happened to it. It exists because the level's falling edge is ambiguous by design (#38 follow-up).

Every accepted seek emits `.began` and then exactly one of `.landed(renderedTime:)`, `.stalled` or `.superseded`, under the same id. A seek that never reaches a host emits a standalone `.rejected`.

One asymmetry is deliberate: a `.stalled` seek stays alive as recovery intent, so its `.landed` can still arrive minutes later on a source that finally serves the target. No level signal can express that.

Three paths feed the stream:

- **Programmatic seeks** report from their finalize step, so the clock is already at the target when the event fires.
- **Seeks stashed before the session can take them** (#127/#178) hold the level for the whole stash window. The engine publishes their target on `currentTime` optimistically, and a consumer that broadcasts it needs to know nothing has reached it yet.
- **Native AVKit scrubs** end their window when the picture reaches the restarted region, watched on `$renderedTime` and capped at 8 s.

  They do not end when the coalesced producer restart drains. Draining only means the producer is producing at the new index; the picture arrives a fetch and a decode later ([measured](measurements.md#native-scrub-picture-latency)).

  A restart that a programmatic seek itself caused is left to that seek's events, since the restart segment can sit below where the picture ends up.

### Restart latency diagnostics

Restart latency explains itself in the log (#93):

- The "producer restarted" line carries a phase split (`stopWait/reopen/seek/build`).
- A producer's first source read is timed.
- Any single `AVIOReader` read over 2 s emits one `slow read` summary that names where the time went: detour fetches with network time, `connStallTimeout` waits, reconnects, backoff sleeps, bytes dropped by the stale-generation guard, and the generation span.

A slow read with all-zero counters means the wait happened before the read loop.

### Keeping AVPlayer from timing out

A request during a restart must never leave AVPlayer waiting in silence (#93). AVPlayer's media watchdog logs `-12889 "No response for media file"` after ~3.5 s without response headers. Holding the connection open does not help, and three strikes fail the item.

So a VOD serve still running at 2 s sends the response headers early: a `200` with `Transfer-Encoding: chunked` (`SlowServeSignal`, armed by `VideoSegmentProvider.mediaSegment(at:onSlow:)`).

- The segment follows as a single chunk when it is ready.
- A serve that finally misses aborts the connection (truncated transfer, AVPlayer retries) instead of sending a cacheable empty 200.
- Fast serves keep the byte-identical `Content-Length` response.

**If the item dies anyway.** `failedToPlayToEndTime` parks the item at rate 0 / `timeControlStatus == .paused`, with `item.status` often still `readyToPlay`. A recovery layer that respects pauses would read that as the viewer pausing and end the session for good. So:

- The host counts end failures on the loopback path (`endFailureCount`).
- A death counts once the item has shown its first frame (a non-zero `presentationSize`), not only after the first `.playing`. The window between the two is real: a host that waits for the display mode switch before calling `play()` can lose the HDMI link there, and before AE#1043 that death belonged to neither the startup watchdogs nor this escalation, so the session sat on a frozen frame forever. A death before the first frame stays with the startup watchdogs.
- The engine confirms the death through the same deferred window as the `.failed` KVO. It then reloads the item through the stage-2 chain (the engine's item-reload recovery) with the pause guard bypassed.
- `ItemDeathReviveGate` caps this at 3 attempts per dead spot. Playback progress, or a user seek away, restores the budget.
- The fresh item resumes only if the host's play intent says the viewer was playing. A paused title whose item dies (a tvOS screensaver taking the display is one way) is reloaded and stays paused.

### End-of-item recovery

When an item ends, native recovery first records the highest published clock value and how fresh it is, then awaits AVFoundation's off-main reading. A slow reading therefore cannot invalidate that proof of the end and replay an audio tail that already finished.

Before applying the result, the host checks both the session generation and the seek generation. If a replacement or seek happened in between, that one owns the transport, and the old end notification is suppressed.

### Item diagnostics

**Item diagnostics must not become playback work.** `accessLog()` and `errorLog()` can block while waiting on AVFoundation's media-service queues, even when called from an item notification. So these callers go through `AVPlayerItemDiagnostics`:

- the video host's log notifications and failure dump,
- the audio-only error observer,
- the reconciliation of the outgoing item's counters.

How it works:

- Each reader owns its original item, merges pending reasons, and hands log values (not native log objects) to the main actor.
- Failure track arrays are also fetched off-main. The SDK's UI-actor-isolated track handles then use async asset-property loaders.
- A stop or load invalidates publication, including queued callbacks, without waiting for a read.
- Delivery rechecks ownership after synchronous log handlers and state subscribers, because they can replace the item while its diagnostic batch is being consumed.
- Merged error batches look at unseen entries, so a fetch error in between cannot hide the startup `-15628` loader-poison signal (a stall after which AVPlayer fetches no more media).
- Access-log notification output is capped at five entries per item. A failure still dumps the complete available logs.

**Admission.** Admission is process-wide: at most **two concurrent diagnostic reads**, plus **one pending retirement
read** kept beyond those lanes. A retirement read is the final read of an item that has just been replaced (see item swaps below).

- Current-item and error work goes before optional retirement work.
- Cancellation never frees a lane that is still inside a native getter.
- One stuck lane leaves the other available. Two stuck lanes defer diagnostics rather than spawn more threads.
- Telemetry keeps its own separate, serial read path.

This contains diagnostic stalls only: it does not fix an underlying media-server failure, and it does not make every other AVPlayer operation nonblocking.

**Item swaps in one session.** On a swap, the engine folds in the outgoing item's last observed totals (transferred bytes, dropped frames) without calling a getter at the handover. Later it reconciles only the difference found by its final background read.

- Telemetry readings also refresh that cache, so an older diagnostic snapshot cannot move it backwards or count the outgoing item twice.
- If swaps outpace blocked readers, an older retirement read that has not started is discarded. Its observed totals stay, but the final totals are incomplete. This is reported once per session, never made up.
- A new playback session (including an episode handover on the same player) clears those totals and rejects any old reconciliation.


## Timestamp repairs for broken files

The engine repairs these file shapes at the demuxer or the session muxer. The host-facing summary (symptom, repair, cost) is in [formats › Files with broken timestamps or bitstreams](formats.md#files-with-broken-timestamps-or-bitstreams).

### MP4 without composition offsets

**The problem.** Some writers emit a sample table with no `ctts` (MP4's composition-offset table) while the H.264 or HEVC bitstream still reorders pictures. Every sample then reports `PTS == DTS`. The native route stream-copies those timestamps into fMP4, so AVPlayer is handed decode order as presentation order. Each future reference picture is then shown before the B pictures that should come before it (#409, [measured](measurements.md#mp4-without-composition-offsets)).

**The repair.** The container lost the information, but the bitstream did not. Every slice header carries a picture order count (POC), which is display order. libavcodec's H.264 and HEVC parsers read it without decoding a pixel, and take MP4's length-prefixed payload directly.

`H264CompositionOffsetRepair` samples the head of the stream (twelve pictures at most, held rather than re-read, so no rewind and no second fetch). If the source is confirmed broken, it rewrites the timestamps at the demuxer boundary. In the formula, `rank` is a picture's display position within its sequence, `step` is one frame duration, and `reorderDelay` is how many pictures the encoder reorders across:

    PTS = (decode time of the picture that opened this coded video sequence) + shift + rank * step
    DTS = DTS + shift - reorderDelay * step

- Pulling decode time back by the reorder delay is what keeps `PTS >= DTS`. A healthy file carries the same negative head.
- `shift` is 0 or one reorder delay, depending on whether the writer left the sample ladder on the presentation axis or kept the edit list that trims the reorder head. It is clamped to that range so a malformed header cannot drag the picture off its audio.
- The rewrite happens once, in the demuxer, so the fMP4 producer, the segment plan, the software decoder and the still extractor all read one axis.
- The source keeps hardware decode: a missing table costs no route change.
- The container's own index is folded onto the same ladder, because the segment plan is built from index entries and then filled with these packets.

**Detection** is fail-closed (when in doubt, the file is left alone) and costs a healthy file almost nothing. The first real PTS-DTS offset ends the sample. That is usually the first packet, since a reordered file's head sample sits one delay below zero. A source is repaired only when all of these hold:

- every sampled pair is equal,
- the decode ladder (the sequence of decode timestamps) is uniform,
- the picture order regresses,
- the ranks it produces are distinct and fill the sampled window, or a decode-order prefix of at least nine pictures fills its own range exactly (this covers a hierarchical mini-GOP, the run of B pictures between two anchors, that is longer than the reorder delay, #699).

Anything short of that (a picture order that does not advance one rank per picture, a sample that starts nowhere it can be anchored) is delivered exactly as the container wrote it. Reported by @orut34iop; the HEVC case (#699) by @ijuniorfu.

#### H.264 with a changing decode cadence

For H.264 only, a changing decode cadence can instead use the original-slot policy (keep the timestamps the file already has and hand them out again by display rank) described in [MP4 with composition offsets missing only in later regions](#mp4-with-composition-offsets-missing-only-in-later-regions). This fallback requires:

- a progressive IDR head with equal PTS/DTS,
- a container start/index lead that exactly matches the observed reorder head,
- a complete, distinct picture-order prefix whose timestamps pass the slot policy.

It assigns existing slots plus that lead rather than fitting a frame rate. DTS, audio and the keyframe index stay unchanged. An ambiguous head stays untouched.

#### Writers that push timestamps to keep them monotonic

**The problem.** Some writers go one step further: after dropping `ctts` they force the presentation times, in decode order, to rise monotonically.

- Each B picture decoded after another picture is pushed 1001 ticks (at 90 kHz, a third of a 29.97 fps frame) past the picture before it.
- On some files each anchor (an I or P picture that others reference) is pushed too.

There is then no even ladder to read a step from, so the uniform-ladder check above skips such a file as non-uniform ([the reporting files](measurements.md#writers-that-push-timestamps)).

**Choosing the step.** When nothing above takes such a head, it is repaired with the step taken from the stream's average frame rate. Two conditions apply:

- the sampled span matches the time its pictures take at that rate, within the reorder delay plus two pictures,
- every other check above still passes.

How the step is refined:

- The step is then remeasured on the anchors when the writer left them on the presentation axis. The average rate is only an estimate: a 60-picture 29.97 fps clip reports 29.80.
- The reporting file pushed its P pictures as well (each anchor 1001 ticks past the picture before it), so no two anchors agree. The rate is then the one the bitstream's VUI timing (frame-rate fields in the SPS) states, if that is within 1% of the average rate, snapped to a standard frame rate (any whole rate up to 240, or an NTSC one such as 23.976 or 29.97) within 0.01%.
- Without a VUI rate, it is the standard rate nearest the average rate, if that is within 1%.
- A head with neither is left untouched.
- The VUI is what tells 24 from 23.976 on a short clip whose pushed tail drags the average.
- Pictures are placed on that rate as an exact fraction of a tick, so a 23 fps file (3913.04 ticks at 90 kHz) does not lose a tick every 25 pictures.
- DTS is rebuilt from each picture's decode slot rather than shifted, since a pushed B picture's DTS can sit after its own presentation time.

**Pushed keyframes.** The writer pushes keyframes as well, and only ever later, which leaves a gap or puts the next GOP in front of the last pictures of the previous one. So a later IDR continues the sequence before it, unless:

- it is later than the reorder delay plus two and a half pictures (a real discontinuity), or
- it is within half a tick per picture (all a rounded step can be off by).

An earlier IDR keeps its own time, which is how a chain started on a pushed keyframe after a seek moves back into place.

**Clock drift.** Counting frames at the stated rate is not enough, because the writer's clock does not run at exactly that rate. A counted chain drifts behind the writer and then overlaps where an earlier keyframe pulls it back.

So a continued sequence also leans toward the earliest origin the pictures before it point to, by at most an eighth of a picture per GOP. The writer only ever pushes a picture later, so the earliest origin is the nearest the truth. A seek landing holds its first **8 pictures** and takes the earliest origin they point to in the same way.

**Segment boundaries.** A keyframe moved back like this sits before its index entry, by at most the reorder delay plus two and a half pictures. The HLS segment plan, though, is built from the index. So the VOD cutter and the restart gate reach that far back for the keyframe each boundary names, never as far as the keyframe before it.

Without the reach, the keyframe would stay in the previous segment and the next one would open on audio, mid-GOP. With it, every segment is independent, including segments a restart produced (`aetherctl segverify` checks this).

**Long P runs.** Some of these files open every GOP on twelve P pictures before the first B. So a head that has not reordered after twelve pictures, with `PTS == DTS` throughout, is sampled on to its first regression plus a mini-GOP, up to
**48 pictures**. The sampled span is checked against the rounded step with a tick per picture to spare.

**Open-GOP seeks.** After a seek onto an open-GOP keyframe, which kept its own presentation time, the sequence origin is taken from its display rank rather than its decode slot.

**Shift clamp.** The shift is what puts the first keyframe on the stream's start time. It is clamped to **16 pictures**, enough for a writer that leaves the keyframe four pictures ahead.

**Fixtures.** `Scripts/make-clamped-ladder-fixture.sh` generates twins for each shape (900 pictures at 29.97 fps); the repaired fixtures demux to the healthy twin's timestamps. Before and after counts: [measurements.md, Clamped timestamp ladders](measurements.md#clamped-timestamp-ladders).

### Matroska with presentation slots in coding order

**The problem.** Matroska block timestamps are presentation timestamps by specification, and the format has no composition-offset table to lose. Some writers fill them packet by packet while the bitstream reorders pictures. Nothing is lost then: every presentation slot (timestamp value) is still in the file. But each one is attached to the picture *decoded* at that position rather than the one *displayed* there. The presentation clock steps back once per mini-GOP for the length of the file (#511, [measured](measurements.md#matroska-slots-in-coding-order)).

**The repair.** `H264MatroskaSlotPermutation` reorders the existing slots rather than computing new ones: a picture gets the slot its own display rank owns, read from the file.

- Nothing fits a cadence. A ladder quantized from a fractional frame rate is reproduced exactly rather than to within a tick, and a slot the writer clamped onto its cluster origin survives as written.
- Decode timestamps do not move either. libavformat derives them from the rising slot ladder, which is the stream's real decode order, and a picture at most its own reorder delay behind its slot cannot violate `PTS >= DTS`.
- The container index is untouched for the same reason: it holds keyframe slots, and a keyframe is the first picture of its own sequence.

**Latency.** The slot a picture needs is a packet away, not a plan away. A picture coded ahead of the slot it owns waits for the packet carrying that slot, which is the mini-GOP reorder (a few video packets). Nothing waits for the end of a sequence.

**Detection** is fail-closed and costs a healthy file almost nothing. One stepped-back slot is the container doing what the format says, and it ends the sample on what is normally the third packet. `PTS != DTS` is not an eligibility test here, because libavformat synthesizes a decode ladder from a rising presentation one just as readily as from a reordered one. A source is repaired only when:

- the sampled slots rise strictly,
- the picture order regresses,
- the ranks are distinct, fill the sampled window and are a multiple of one measured step,
- no picture sits further behind its own slot than the reorder delay the container declares.

A stream that later stops being that shape, or a wait that no mini-GOP explains, hands its packets back exactly as they arrived rather than permuting half a sequence. Diagnosed by @orut34iop on PR #511, whose numeric ladder is the regression fixture.

### MP4 with composition offsets missing only in later regions

**The problem.** A healthy head does not prove a healthy table for the whole file. Some mixed MP4s keep valid offsets at the head, then give later reordered pictures zero offsets. Seeking into that region can produce persistent judder despite normal aggregate FPS and enough network buffering.

**The repair.** When a healthy origin picture corroborates the container's edit/index lead, the demuxer keeps a zero-hold healthy path and watches for zero-offset IDRs.

- Progressive pictures are parsed as they arrive. Valid equal PTS/DTS and distinct even POC let the streaming slot ladder assign original DTS slots plus the corroborated presentation lead, by display rank.
- Original DTS, audio and the already published keyframe index never move.
- Actual timestamp slots, rather than an average-FPS clock, preserve interval changes and quantization within a sequence.

**Bounds.** As in the Matroska policy above, the slot a picture needs is a packet away, not a plan away: a picture coded ahead of its own slot waits the mini-GOP the reorder created. Nothing waits for the end of a sequence, and no sequence is too long to repair.

- Backward displacement stays bounded by the declared reorder delay.
- A forward-coded anchor farther ahead needs a bounded, complete decode-prefix proof, as in #700: distinct ranks fill a prefix, the backward delay still fits, and the observed slots plus lead pass a dry run. Only the measured forward distance is then allowed, limited to **16 pictures**. That proof resets at each candidate IDR.
- The packets held behind it stay bounded by **1024 interleaved packets and
32 MiB**, which is a ceiling on a container's interleaving rather than on its GOP.
- A candidate sequence has to show its reordering within **64 pictures** before a single picture is rewritten.

**Refusals.** Healthy nonzero offsets resume unchanged delivery. Fields, missing timestamps, incomplete POC, a rank claimed twice, arithmetic overflow and insufficient lead are not guessed at.

- **Every refusal hands the held packets back exactly as they arrived** and lets the rest of that sequence stream through, so a shape this policy does not own costs the repair and never the session.
- The next IDR is a fresh candidate.
- Seek and teardown release both unpublished input and pending output.
- No decoder-route or host-UI change is needed.

The uniform whole-file policy above is unchanged. Its strictly proven variable-cadence H.264 fallback reuses this same slot ladder.

See the [partial-composition regression and reproduction](notes/partial-composition-regression.md) for generated fixtures, original numeric evidence and verification limits.

### A video sample whose NAL chain overruns it

**The problem.** A sample in an mp4 video track is a run of NAL units (the codec's basic data packets). Each unit starts with a big-endian length, whose width the `avcC` / `hvcC` record declares, and a parser walks the run by adding up those lengths. A damaged source can carry a length that reaches past the end of its own sample. The two consumers answer that differently:

- libavcodec logs `Invalid NAL unit size`, skips the frame and plays on.
- Apple's fMP4 parser answers the whole SEGMENT with `CoreMediaErrorDomain -19602`, which ends the session and every reload onto that segment.

So a file like that plays in mpv, plays after an MKVToolNix remux (which drops the unparsable tail), and dies here at whichever position AVPlayer first has to decode across the damaged sample.

**The fix.** The session muxer walks each video sample's chain before the write and cuts it at its last complete NAL, which gives the same bytes the remux would have written.

- A healthy sample is left alone.
- An Annex B payload is refused rather than walked as lengths.
- A sample with no complete unit at all is dropped instead of written empty.
- An HEVC unit shorter than its two-byte NAL header (for example a one-byte EOS at the end of an M2TS) is
  removed, even when the length chain fits exactly. The picture and any Dolby Vision RPU around it stay.
  This only runs on confirmed length-prefixed HEVC. A shared packet is made writable before the bytes move,
  and a sample left with no complete unit is dropped (#960).

The fixture generator `Scripts/nal-overrun-fixture.py` forges the shape into any length-prefixed source by rewriting four bytes, so the healthy original stands as the control arm (AE#561).

**Last rung: software takeover.** Some cases the cut cannot reach. Every native recovery then serves the same bytes again: the #93 revive reloads the item at the position that died, and the stage-2 chain refills the same segment. A segment AVPlayer refuses on its merits would end the session, with each replacement item dying milliseconds after the one before. So a failure in the CoreMedia domain is offered to `SoftwarePlaybackHost` before it is made terminal:

- The session is rebuilt at its playhead with `preferredDecodePath = .software`, which decodes with libavcodec (one skipped frame rather than a dead session) and reads the demuxer directly instead of the loopback HLS.
- Once per session, and only for a verdict on the MEDIA. A URL-loading failure is a verdict on the SOURCE, which both paths read through the same reader.
- Whether the software path can serve the source at all is the existing #461 `decodePathRefusal`, so a source it cannot serve costs a refusal and the original failure, not a second dead session.

## Native route variants

The native pipeline above is the **loopback** route: the engine demuxes, remuxes and serves. Three source shapes reach AVPlayer another way. `videoRoute` reports which one runs (see [Effective video route](architecture.md#effective-video-route-videoroute)).

### Remote HLS bypass

**Remote HLS bypass (`.remoteBypass`).** AVPlayer gets the origin's own playlist. There is no demuxer, no producer and no segment cache. This route runs with `LoadOptions.nativeRemoteHLS`, and for a remote HLS VOD URL that reached the loopback path (AE#154).

The `Native/RemoteHLS*` types cover what is left for the engine: media selection (`RemoteHLSMediaSelection`), the readiness deadline, the subtitle cue clock and the carriage watchdog (`RemoteHLSIngestFallback`), which notices when AVPlayer cannot play the stream's carriage and falls back to ingest.

- **Local proxy, only when needed.** The engine puts its local server in front of the origin's master playlist for two reasons only (`RemoteHLSSubtitleProxy`). It can declare host sidecar subtitles as renditions in a master of its own (#316). It can relay the media through a URLSession the engine owns, so the host's TLS trust answer applies (`HLSOriginRelay`, AE#495). The two compose.
- **No media bytes.** The engine sees none here. Recording and prewarm do not apply, a starved connection reads as `.rebuffering` rather than `.stalled`, and the audio tap fetches its own copy of the segments (`AudioTapHLSReader`).

### HLS ingest into the loopback

Some HLS sources AVPlayer cannot play directly, so the engine reads them itself and feeds the ordinary loopback pipeline. Both readers in `IO/HLSIngest/` are `IOReader`s (the byte-source protocol the demuxer reads from). They expose the playlist's MPEG-TS segments as one byte stream for the demuxer (`formatHint: "mpegts"`).

| Reader | What it does | When the engine routes onto it |
| --- | --- | --- |
| `HLSLiveIngestReader` | Picks the highest-bandwidth variant, polls the media playlist, prefetches segments and commits them in playlist order. A demuxed audio rendition gets a companion reader. AES-128 clear-key segments are decrypted on the way (`HLSSegmentDecryptor`); fMP4 segments (`EXT-X-MAP`) end the session with an `HLSIngestError`. | A known HLS playlist URL on the live path with `nativeRemoteHLS` off (AE#678). A bypass that built no video track for a master that advertises one, typically HEVC in MPEG-TS (#168); the verdict is remembered per master (#199), and `HLSCarriageProbe` can settle it early from the playlist and the first segment's PMT (AE#293). |
| `HLSVODIngestReader` | One finite playlist. A seek restarts at the segment before the target, on an elapsed-time axis, and the demuxer's packet gate drops frames before the exact target. With `heldSourceConnection`, every request goes over one persistent HTTP/1.1 connection per origin (`PersistentHTTP1Transport`, AE#732). | A finite HEVC-in-MPEG-TS VOD, at load (AE#268). Any finite MPEG-TS playlist with `preferredDecodePath = .software`, which then decodes on the software host (AE#990). |

### MPEG-DASH

**MPEG-DASH (on-demand)** is not a route of its own. The `Demuxer` opens an MPD through `DASHSourceOpener`, which lays the selected representations out as one fragmented MP4 served by `DASHVirtualMP4Reader`. libavformat's `mov` demuxer reads that like any file, so everything downstream is the ordinary loopback or software pipeline. Details and limits: [formats.md, MPEG-DASH](formats.md#mpeg-dash-on-demand).

## Trick play and scrub stills

Scrub images (the thumbnails shown while the viewer drags the timeline) come from bytes the session already holds wherever it can, so they cost no second connection. Host API: [api.md, Stills and thumbnails](api.md#stills-and-thumbnails).

- **Cache-backed stills.** `scrubThumbnail` decodes what the session holds: the loopback segment cache on the native route (`AetherEngine+ScrubThumbnail.swift`), and the DVR packet ring (the buffer of recent live packets) or the packet cache on the software host (`SoftwareStillExtractor`). The software extractor drives a real `SoftwareVideoDecoder`, so deinterlacing and pixel aspect match the picture on screen.
- **Sparse still ladder.** For VOD stretches nothing resident covers, `KeyframeStillLadder` reads one keyframe per rung (one evenly spaced position) off the source while the link is idle. It uses a slot of the pump's per-origin request budget (`generatesBackgroundScrubPreviews`). A one-request origin gets no ladder (AE#937).
- **I-frame rendition.** With `serveIFramePlaylist` (AE#682), the master lists an I-frame playlist (a playlist of keyframes only), so a stock `AVPlayerViewController` shows scrub thumbnails with no host code. The local server answers `iframe_init.mp4` and `iframe{N}.mp4` through `IFrameRendition`:
  - `IFrameSideReader` reads the keyframe that opens plan segment N on a demuxer of its own, one request at a time, and `IFramePayloadCache` keeps it on disk.
  - `IFrameFragmentBuilder` wraps it in one fMP4 fragment on the main rendition's timeline. Each fragment gets a fresh muxer, because AVKit asks for I-frames in any order.
  - HDR and Dolby Vision sources get one SDR Motion JPEG per keyframe instead (`IFrameJPEGBuilder`), because the tvOS scrubber gives up on PQ I-frames.
  - The rendition is all or nothing (`IFrameRenditionEligibility`). Live sessions, sequential and held origins, serial origins, disc sources and plans whose boundaries are not keyframes list none.

<!-- Subtitle cue pipeline (route-neutral: it serves the native and the software path alike; put it wherever the shared pipeline lives, but keep the anchor subtitle-cue-pipeline and the H3/H4 headings, formats.md links to them) -->
## Subtitle cue pipeline

The host-facing behaviour is in [formats › Subtitles](formats.md#subtitles). This is how the engine collects embedded cues and keeps the list correct. It serves the native and the software path alike. The field reports behind these rules are in [measurements.md, Subtitle cue pipeline reports](measurements.md#subtitle-cue-pipeline-reports).

### Harvest, store and drain

Subtitles move through three stages: a tap harvests their packets, a store keeps them, and a drainer decodes the ones near the playhead.

- **Harvest.** EVERY embedded subtitle stream (text and bitmap) stays in the session demuxer's keep-set (the streams it does not discard). A tap on the host's existing source read harvests them. Each packet is observed and then dropped, never muxed.
- **Store.** Harvested packets are kept compressed in a per-session `SubtitlePacketStore` (300 s trailing window, byte-capped per stream).
- **Drain.** A drainer paced by the playhead decodes the selected stream near the playhead into the overlay.
- **PGS in MPEG-TS (Blu-ray).** PGS is the Blu-ray bitmap subtitle format; one subtitle image is a display set. In MPEG-TS a display set arrives split across several PES packets (PCS|WDS|PDS|ODS|END, some without a PTS of their own). The store reassembles those chunks into one self-contained entry at the PCS presentation PTS before keeping it, so the drainer always decodes complete display sets. Matroska already carries one complete set per packet and is stored as-is.
- **Instant selection.** Enabling any embedded track is instant: the selection backfills synchronously from the store, with no positioning seek and no recovery machinery, even on remote disc images.
- **Seeks and restarts.** The tap re-attaches with the producer across seeks and restarts.

<a id="forward-prefetcher-151"></a>

### Forward prefetcher

**Why it exists.** The tap only sees what the producer reads, and the producer parks a few seconds past the playhead on direct play (its forward park, #102). So on VOD sessions a background side reader that reads subtitles only, the forward prefetcher (#151), extends the store further ahead.

**How far ahead.**

- It reads past the drainer's 60 s lead window by a 15 s margin, so the set at the window's forward edge still has its own successor stored (#362).
- While a bitmap track's OCR rendition (bitmap subtitles turned into text) is armed, the lead is raised to 270 s. That clears the OCR worker's own 240 s window by 30 s, so the store actually holds what the worker is about to read.
- The result: `subtitleCues` holds cues ahead of the playhead for a host-applied ADVANCE sync offset, text and bitmap alike.
- Live sessions skip it: content past the live edge does not exist.

**Only when something reads ahead (AE#1015).** On an interleaved container the side reader downloads the video a second time, so it runs only when one of these holds:

- the host's advance reach is above 0 (`maximumSubtitleAdvanceSeconds`, default 60, also set by `maximumSubtitleOffsetSeconds`; the later reach `maximumSubtitleDelaySeconds` never starts it, AE#1031),
- `softwareSubtitleDelaySeconds` is negative,
- the OCR worker is armed.

With an advance of 0, a text track reads from the tap alone.

**The landing role (AE#1022).** A landing is the position playback arrives at after a start or a seek. With an advance of 0, a bitmap track keeps the reader for its landings only. After each positioning it reads from 15 s before the landing (`subtitleDrainBackscanSeconds`) to 2 s past it, and parks there until the next one instead of following the playhead.

- The tap cannot serve a landing on its own. It repositions on a video keyframe at or before the target, so a set that began before that keyframe is never read. A set it does read has no read ground behind it (no proof of what came before), which the #416 check refuses.
- A software seek sends the reader to the landing as the seek goes out, so the ground is read by the first drain tick after preroll.
- A landing the check refused anyway is reconstructed once its ground reads (`subtitleLandingAwaitingGround`).

**Every session reads from 15 s behind its landing (AE#1022)**, in either role, and claims its coverage from there. A set that began just before a start position or a far seek is therefore proven like any other.

**An open set is closed where playback left (AE#1022 round 2).** A bitmap set whose clear was not read yet still has its open placeholder end, so it would be drawn over the landing of a seek. When a software seek goes out, such a set is closed at the departure, the position playback left from. Its clear was still unread there and the harvest runs ahead of the playhead, so the set really lasted that long, and nothing past it is known. A set that starts after the departure was never on screen. If it starts before the landing of a forward seek, it is closed at its own start, and a re-decode replaces it (`insertCueSorted`). Closing at the landing instead, as round 1 did, claimed the whole stretch the seek jumped over, and a later seek back into it drew the set again.

**Nothing publishes between that closing and the landing (AE#1022 round 3).** Until a software seek lands, the clock still reports the frame it is leaving. A drain tick planned there decodes around the departure and would publish a set whose clear is unread as open again, after the closing ran, so the clock draws it at the landing until the landing's reset closes it. So a tick planned under an earlier seek generation is dropped when its batch comes back, and no tick is planned while a seek that closed its departure is in flight (`subtitleDepartureClosedSeekGeneration`). The cursors stay where they were, and the first tick after the landing is the reset that reconstructs it.

**Other rules.**

- It is best-effort. If it cannot open or wedges, the tap-fed behavior above is unchanged.
- **Positioning (#234).** Its positioning seek is anchored on the subtitle stream's own timestamp axis. Left to libavformat's default, the anchor follows whichever stream is not fully discarded. That is the pacing stream that gives the park its control point (#230), so the seek would land on video keyframes. On Matroska that lands in a later cluster and drops a landing cue that starts further back than the destination.
- **Re-anchoring.** A playhead jump re-anchors the running session in place rather than rebuilding it. A rebuild pays an open, the Matroska cue-index prewarm and a positioning seek, and the origin delivers each of those bounded ranges in full.

<a id="sharing-the-link-with-video-240"></a>

### Sharing the link with video

The side reader shares the source link with the video pump, and the video path has priority (#240).

On Matroska the side reader downloads a second full copy of the stream: `matroska_parse_cluster` reads every block off the wire, and only `matroska_parse_block` then honours the discard flag. So a subtitled session asks the link for about twice the media rate. Where the link has little headroom the two would starve each other. A side reader therefore:

- fetches while the pump is parked,
- yields while the pump is fetching, and yields completely while a seek is in flight,
- keeps a bounded grace window after each anchor so a freshly selected track still fills,
- takes the link back after a 60 s continuous yield, so a pump that never parks cannot disable lookahead for the session.

Bench result: [measurements.md, Subtitle side reader link sharing](measurements.md#subtitle-side-reader-link-sharing).

### Ending a PGS cue

A PGS composition (one subtitle image) carries no end time of its own. The disc ends it with the next composition, or with a clear (an empty composition that removes the image). The engine publishes it with FFmpeg's open-ended placeholder end (`end_display_time = UINT32_MAX`) and closes it when that successor arrives.

**The normal case: the next stored packet (#362).** A set's authored end is the PTS of the next packet on its stream, and the packet store holds that packet long before the drain window reaches it. So every tick (one drain pass) closes each still-open cue at `SubtitlePacketStore.firstPTS(streamIndex:after:)`.

- Without this, the drain window's forward edge decides the end whenever it falls between a set and its clear. The set publishes open, the cursor moves past it, and the next thing to touch it is a composition at the next landing, tens or hundreds of seconds later.
- For the store to be able to answer, the harvest has to lead the decode. The forward prefetcher parks a 15 s margin BEYOND the drain window (`subtitleForwardPrefetchLeadMarginSeconds`), because with both lines at 60 s the set at the edge is systematically the one whose clear is stored nowhere.
- Where the store genuinely has nothing after a set (its harvest frontier, a stream cut short), the cue stays open and #357's boundary close still owns it. The engine never invents an end there.

**The last resort: the seek boundary (#357).** A seek can outrun the successor. The retention prune cannot help, because it filters on `endTime`, and a placeholder end never ages out. Left alone, a jump past an open cue would leave it in the published window, covering the new playhead until the next composition displaced it.

So on a seek, the drain closes every still-open cue that began before its reconstruction window (playhead minus the 15 s backscan), at that window's start. Before that line nothing is re-decoded, so nothing there can be confirmed as still open.

- The cue stays in the kept list for a backward seek. Only its unconfirmed end retires.
- An authored duration is never touched.
- The #100 stale-arrival hold is dropped on the same tick, for the same reason.

<a id="holes-in-the-packet-store-362-941-1021"></a>

### Holes in the packet store

**The problem** (#362, #941, #1021). After a seek, the pump restarts behind the landing and fills forward. The store still holds an island (a stretch of packets) that the previous run harvested further ahead. The drain window then reads as "packets, hole, packets".

Decoding across that hole carries the drain cursor to its far side, and the cursor only moves forward. The hole's packets land a second later and are never read. A stretch of the film then carries no subtitles at all until some later seek resets the window behind it. The set before the hole is also closed at the island rather than at its own clear.

**Why not a gap threshold.** The size of a gap cannot tell a hole from a silence the author left. A threshold on it is actively harmful, since a set is separated from its own clear by its display duration.

**Harvest order (#362).** The order of harvesting can tell. Each harvested packet carries a sequence number. A run (one reader's continuous pass) reads a stream forwards, so within one run PTS and sequence rise together. A pair whose PTS rises while its sequence DESCENDS is two runs meeting over a span neither of them has read. A tick stops at that boundary and waits (`harvestGapCut`).

- This costs nothing visible, because the drain runs its lead ahead of the playhead.
- The wait ends when the filling run re-harvests across the boundary, or when the playhead comes within two seconds of its far side, so an authored silence never stalls delivery.
- There is no other tick budget (#941). A wall-time budget would expire during seeks and rebuffers while the playhead stands still, and decode the island over the sets the refill is about to harvest.
- A tick that waited says so, as `outcome=harvestHole gapAt=`.

**Three runs meeting (#941).** Order alone misses some holes. Seek past the producer's front and straight back into the stretch that jump skipped, and three runs meet:

- the original run, up to just past the landing,
- the forward run's island, further on,
- the restart behind the landing, which has not written anything yet.

The island was harvested after the near side, so the sequence ASCENDS across the hole and no pair descends. A tick reading order alone would decode straight across, losing every set the restart then harvests in between. A re-harvest of the island does the same to a wait that did fire, because it stamps the island newer than the held position.

The coverage ledger ([below](#the-landing-after-a-seek)) knows both cases. `harvestGapCut` also stops at a pair whose span no reader has read.

**The ledger decides alone (#1021).** Order also sees holes that are not there:

- A track selected at load starts the forward prefetch with the session, so the prefetch stores the next 75 s first.
- The main reader then reads each of those packets again a few seconds ahead of the playhead, and a re-harvest takes the fresh sequence.
- So every pair at the main reader's front descends. A drain that stopped at each one would never get more than a few seconds ahead of the playhead, and a host's advance offset would show nothing until the first seek.

So where the ledger has heard from a reader, it is the whole answer, both for a cut and for the end of a wait. A pair whose span some run read is decoded through; one nobody read is a hole, whatever the sequences say. Order stays the rule only on a store whose readers never report coverage.

On a link near the media bitrate, two more rules make this work:

- **No reach claim during a seek.** The pump's reach claim ("it rendered the playhead, so it read up to there") is not made while a seek is in flight. `sourceTime` still reports the frame the seek is leaving while the producer is already re-anchored behind it, so the claim would stretch the fresh run across exactly the skipped ground.
- **Release on the far side.** A wait ends when the playhead closes on the FAR side of the hole (within `subtitleDrainHarvestGapReleaseLeadSeconds`), not on the near one. A refill at about 1x keeps the playhead just behind the filling run. The playhead passes the last packet before the hole while the hole is still ahead, and releasing there would decode the island over the sets the refill is a second from harvesting.

<a id="the-landing-after-a-seek-416"></a>

### The landing after a seek

**The problem** (#416). A hole behind the playhead also affects the landing itself. At a seek target, a gate reconstructs the subtitle line that should be on screen. It seeds that line from the newest set decoded behind the playhead. That set is the right line only if nothing on its stream happened in between, and the store's silence is read as that proof. Over a stretch nobody read, silence proves nothing.

A run re-aimed just after it harvested a set leaves that set's own clear on the far side of the skipped ground. The set then decodes at the landing looking unclosed and publishes over the new scene. It ends at the next stored packet, which is the far side of the authored silence rather than its own successor.

**Why the packets alone cannot show it** (#362). A reader re-anchored FORWARD hangs its packets in ascending order behind the stretch it skipped, so the pair looks exactly like an authored silence. Only a reader restarted BEHIND leaves the descending sequence `harvestGapCut` reads.

**The coverage ledger.** So the readers report what they read. `SubtitleHarvestCoverage` in the packet store keeps one span per run, anchored where the reader positioned and extended as it goes:

- The forward prefetcher reports its own read position.
- The pump's run begins where the producer opens or restarts, and reaches at least the playhead, since playback is rendering there.
- A set whose ground up to the playhead is not covered cannot claim the landing (`landingWithheld=` on the delivery line), and the pass ends on the next authored set as it would have anyway.
- A store nobody reports to has no ledger to ask (`harvestReadCheck()` is nil), so a path without coverage notes behaves exactly as it did: the landing is not withheld and holes are read from harvest order.

**Cost.** The landing line is lost when a set really is still up but the proof is missing. That needs a set displayed long enough to span the whole unread stretch. Without the ledger, every normally authored set that ends inside such a stretch would publish over the new scene instead.

## Audio routes and object audio

How a track's audio leaves the engine depends on its codec and the pipeline. Host-facing detail is in [formats.md, Audio](formats.md#audio); this is where each route sits.

Terms in the table: JOC is the object-audio extension of E-AC-3 (Atmos in streaming); object audio is sound positioned in 3D space rather than tied to a channel; a speaker bed is a fixed set of speaker channels the objects are rendered into; APAC is Apple's spatial audio codec.

| Route | Native (loopback) | Software host |
| --- | --- | --- |
| Stream copy | Codecs AVPlayer decodes go into the fMP4 untouched, E-AC-3 JOC included. AVPlayer decodes the objects and sends Atmos on ([Dolby Atmos](formats.md#dolby-atmos)). | With `objectAudioRendering` on, a VOD E-AC-3 JOC track goes to the audio renderer compressed (`SoftwareEAC3Passthrough`) once the system's Atmos decoder is registered (`AtmosDecoderPrimer`). On tvOS, where the renderer plays that silent, the system decoder renders it to PCM first (`SoftwareEAC3AtmosDecoder`). |
| Channel bridge or decode | `AudioBridge` re-encodes what AVPlayer cannot take (TrueHD, DTS and the rest) to E-AC-3 or FLAC ([Audio bridge modes](formats.md#audio-bridge-modes)). | libavcodec decodes to PCM (`AudioDecoder`). This is the default for every codec, and always on live sessions. |
| Object render | With `objectAudioRendering`, TrueHD Atmos and DTS:X are rendered into a speaker bed by `SpatialAudioBridge` and muxed as PCM (`ipcm`) or APAC (`HLSVideoEngine+SpatialAudio.swift`). | The same bridge, wrapped by `SoftwareAPACProducer`, hands its packets to the renderer as sample buffers. VOD only. |

`SoftwareAtmosRoute` picks the software host's column per track.

**The object render** (`Audio/Spatial/`) is one bridge on both paths:

- **Decode.** `TrueHDObjectAudioDecoder` (over LibTrueHD) or `DTSXObjectAudioDecoder` (over FFmpeg's `dca` with FFmpegBuild's `x_heights` option) delivers the stream's channel presentation plus its objects or heights.
- **Regression.** `BedRegression` builds every speaker of the `SpatialSpeakerLayout` bed from the channel presentation alone. The objects and heights only steer that mix as statistics; they are never played themselves.
- **Output.** `SpatialBedFormat`: 24-bit PCM, or APAC over AirPlay (`APACEncoder`). On tvOS `AtmosOutputActivator` plays a silent E-AC-3 Atmos stream beside it, because some receivers otherwise never switch to Atmos.
- **Gates.** It needs the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default), 48 kHz and OS 26 or later. TrueHD must be marked Atmos by FFmpeg, and DTS-HD MA must decode as DTS:X. Anything else, or any failure to start, keeps the bridge (or the PCM decode).

See [TrueHD Atmos with heights](formats.md#truehd-atmos-with-heights) and [DTS:X with heights](formats.md#dtsx-with-heights).

## App backgrounding

### Background audio (iOS)

When the app goes to the background while playing, the engine keeps audio going instead of tearing the pipeline down.

**The decision.** It is a pure, unit-tested policy, `backgroundAction(isAudioBackend:hasSoftwareHost:softwareHostHasAudio:keepVideoAlive:pipActive:state:retainPausedVideoPipeline:)`, driven from the `UIApplication` lifecycle observers.

- `keepVideoAlive` comes from `shouldKeepVideoAlive(enabled:pipActive:state:)` on iOS.
- tvOS tears down unless a PiP window is active (`shouldKeepVideoAliveTV`), for safety: a frozen decode session crossing a multi-hour suspension can wedge `mediaserverd`.
- On any platform a host can keep a paused session's pipeline through the background with `retainsVideoPipelineWhenBackgrounded` (AE#870, see [api.md, Background behaviour](api.md#background-behaviour)).

The host contract for all of this is in that api.md section; this page covers the mechanism.

**Native path.** Keeping audio alive just means not tearing down. `AVPlayer` under the `.playback` session keeps decoding.

**Software path.** There is no `AVPlayer`. The combined demux loop normally paces itself (audio and video) on the video renderer's `isReadyForMoreMediaData`. Once `AVSampleBufferDisplayLayer` stops draining in the background, that gate never reopens and audio would starve. So the host enters `backgroundAudioOnly`:

- The loop drops video packets and paces on the audio renderer (`AudioOutput.isReadyForMoreMediaData`) instead, which keeps `AVSampleBufferAudioRenderer` fed and the synchronizer running.
- On return to the foreground the flag clears, the video decoder and renderer flush, and video resyncs at the next keyframe while audio continues.
- A software host that renders no audio of its own never enters this mode (AE#739). The loop would have nothing to pace on and would drop the rest of the file within moments, parking the clock at end of media in the background. Such a session is released like a paused one and reloaded on return.

**VideoToolbox session.** The software host's VideoToolbox (VT) decode session is rebuilt on every return to the foreground. An iOS screen lock invalidates it, and in audio-only mode nothing decodes video to notice.

A loss seen while video is wanted (`kVTInvalidSessionErr` from a decode) is reported by `HardwareVideoDecoder.onSessionLost`. The host rebuilds the session and repositions to the playhead, so the picture comes back on the frame the audio is at. If that happens in the background, or VT refuses the rebuild, the recovery waits for the next foreground return.

**Scope.** The combined VOD loop, and live-without-DVR, which shares it. The DVR feeder loop is unchanged. Test it headless with `aetherctl bgaudio` (see [cli.md](cli.md)).

### Paused-background grace window (iOS)

A paused session waits a short grace window before it tears down in the background (#127). Without it, the teardown would run as soon as the app goes to the background, and a 10-30 s app switch would pay a full pipeline rebuild (demuxer reopen, segment-plan scan, AVPlayer item reload).

**How it works.**

- The teardown is deferred by `backgroundTeardownGraceSeconds` (default 15 s; 0 restores the immediate teardown), held under a `UIBackgroundTask` assertion.
- `didBecomeActive` cancels the window, so a quick switch resumes on the live pipeline.
- At expiry the action is evaluated again (PiP can start, and lock-screen play can resume, during the window). The teardown runs while the app is still really running, never across an idle suspension. The assertion's expiration handler is a synchronous backstop.
- The step decision is the pure `backgroundStep(action:state:supportsGraceWindow:graceSeconds:)`.
- A playing teardown (background playback disabled) stays immediate, because its audio would keep sounding through the window. tvOS keeps the teardown, with the same PiP and `retainsVideoPipelineWhenBackgrounded` exceptions.

**Hardening that ships with it.**

- Host seeks that arrive while the (re)built AVPlayer item is not yet ready are deferred (`shouldDeferHostSeek`), and the latest one replays at readiness. An early seek would clamp to 0 against empty seekable ranges and replace `load()`'s own startPosition seek.
- Hosts observe the published `isSessionReady` to gate corrective actions (restore watchdogs, position clamps), instead of guessing readiness from `currentTime` being stuck at 0.

### What a teardown hands the reload that follows it

The background teardown saves the viewer's track selection for the later reload: it parks a `BackgroundTeardownSelection` before `stopInternal` (the engine's internal teardown), and `reloadAtCurrentPosition` claims it once.

The reason: every other reload path snapshots the state it restores (the #170 subtitle carryover, the audio pick, the disc title) right before its own `stopInternal`. That only works while teardown and reload are the same call. The background path splits them. It tears down when the app sleeps and reloads on return, so a snapshot taken by the reload would run long after the state was wiped (#357, symptoms in [measurements.md](measurements.md#lost-subtitle-selection-after-a-background-teardown)).

How the two sources combine:

- The live read stays authoritative for what survives a teardown (the external registry, its ordinal counter, the host's subtitle authority) and for a selection made after it, which is newer intent.
- The snapshot fills only the fields the teardown wiped.

### Keeping the native host across a teardown

The background teardown also keeps one object: the `NativeAVPlayerHost` shell (`keepNativeHost`), which owns the `AVPlayer`. AVKit registers its MediaRemote Now-Playing client once per `AVPlayer` instance and never registers again against a swapped one (issue #15). A new `AVPlayer` would leave the system Now-Playing card dead.

On the way back, the reload decides whether to keep it with `shouldPreserveNativeHostAcrossLoad(backend:nativeHostSurvives:)`. That asks whether a host is still there, not which backend is running. The teardown leaves `playbackBackend` at `.none`, so checking the backend alone would throw away exactly the instance the teardown kept, and the card would be dead after the return (Sodalite#149).

A load that then routes to software or audio-only releases the kept host in its own dispatch branch.

## Now Playing routes

The engine publishes the system Now-Playing card and answers the remote commands only where the host opted in: `ownsAudioNowPlaying`, `ownsVideoNowPlayingSession` (plus `ownsVideoNowPlayingCommands`) and `ownsSoftwareNowPlaying`. Host contract: [api.md, Now Playing and the audio session](api.md#now-playing-and-the-audio-session).

`AetherEngine+NowPlaying.swift` decides per route, in one pure function (`nowPlayingPlan`), which of two ways it publishes. A secondary `sharedOutputRole` never publishes.

| Plan | Hosts | What the engine does |
| --- | --- | --- |
| Session commands | AVPlayer audio host and native video host, on iOS, tvOS and visionOS | The host's `MPNowPlayingSession` publishes the card from its player. The engine binds the transport commands on that session's center. |
| Shared center | Software host, FFmpeg audio host, every host on macOS (no `MPNowPlayingSession` there) | The engine writes `MPNowPlayingInfoCenter.default()` and answers `MPRemoteCommandCenter.shared()`. `SoftwareNowPlaying.swift` maps engine state to the card and commands to engine actions. |

**Session hosts.**

- The AVPlayer audio host owns its session unconditionally (exposed as `audioNowPlayingSession`). It keeps the overlay bound to the app across a background pause and carries `externalMetadata`.
- The native video host creates one only with `ownsVideoNowPlayingSession`, read when the host is created. The video player also serves `AVPlayerViewController` hosts, and AVKit owns Now Playing there through its own private registration. A session claimed underneath AVKit costs that host its card and its working transport commands, so it is the host's call.
- That session lives on `NativeAVPlayerHost`, so it survives native-to-native reloads (issue #15). The identity staged with `setNowPlayingInfo(_:)` is replayed onto every fresh `AVPlayerItem` (readiness-gate master reloads, media fallback, in-place PiP swaps).

**Shared center.**

- The shared centers exist once per process. `NowPlayingArbiter` (#1041) keeps several engines from overwriting each other's card and both answering every command.
- The engine that claimed last holds the surface: it claims when it starts playing and on `claimNowPlaying()`. When it leaves, the most recent claimant still waiting takes over.
- Session routes do not enlist, because the system arbitrates between sessions.
- Between two items the card stays on the center until the next route publishes over it, so it does not blink out. `stop()` clears it, and so does a load on a route the engine does not own.
- A remote play reactivates the audio session first (iOS and tvOS). `nowPlayingCommandInterceptor` sees every command before the engine acts on it, and `setNowPlayingTrackCommands(next:previous:)` adds a queue's track buttons.

## Source connections

`AVIOReader` (`Demuxer/`) reads the engine's HTTP sources. Four mechanisms change how it treats an origin (the server a source comes from). The host contracts are in api.md.

- **One request budget per origin.** `OriginRequestBudget` counts requests, not TCP connections, across every path a reader fetches on: the pump's ranges, detour blocks (out-of-order reads, for example an index at the end of the file), size probes and the side readers.

  A limit comes from the host (`maxConcurrentSourceRequests`) or is learned when the origin answers 429, 503 or 509 (#377). Speculative paths (prewarm, the still ladder) take a slot only when one is free right now.
- **Held source connection** ([`heldSourceConnection`](api.md#heldsourceconnection), AE#377). The default reader ends its connection once its read-ahead window is full, and sends a new request every 8 to 16 MB the player consumes.

  Some origins punish repeated requests. Against those, `HeldSourceConnection` asks once and pulls over a `URLSessionStreamTask`, with the engine's own HTTP/1.1 framing. On the HLS VOD ingest the same option uses one persistent HTTP/1.1 connection per origin (see [HLS ingest](#hls-ingest-into-the-loopback)).
- **Sequential origins** ([`sequentialOrigin`](api.md#sequentialorigin), AE#693, AE#958). An origin that ignores `Range`, or answers ranges it does not honour, is read as one long unranged GET. The session plays front to back, and seeks land only inside the resident span that reaches the producer's frontier.

  An undeclared origin that fabricates ranges is caught at the first ranged reconnect and fails as `.sourceFabricatesRanges`. `$isSequentialOrigin` reports it ([Sequential origins](api.md#sequentialorigin)).
- **Prewarm** ([Warming a source](api.md#warming-a-source-before-it-is-loaded), #551). Prewarm fetches a source's first bytes before the host loads it, so the start is faster. `AetherEngine.prewarm(url:httpHeaders:byteBudget:)` is static and needs no engine.

  `SourcePrewarmFetcher` issues one ranged GET from byte zero, plus a tail request only where `SourcePrewarmPlan` says the open will look there. `SourcePrewarmStore` keeps the bytes in memory, keyed by URL and headers, and the next `load()` of that URL takes them.

These apply to the software host too: it reads through the same `AVIOReader`.

## Shared outputs and the display switch

**Several engines in one process.** Each `AetherEngine` has its own loopback server, caches and hosts. The audio session, its preferred channel count and the panel's display criteria (the TV's video mode) exist once per process. `SharedOutputCoordinator` keeps track of which engines still use them: an engine joins when a load starts and leaves on a final teardown.

- The audio session is released only by the last engine out.
- The preferred output channel count is the widest playing source.
- A display criteria reset waits for the last engine.
- Every engine's audio session activation and release run on one queue, so they keep their order.
- A `.secondary` `SharedOutputRole` (a multiview tile, say) never writes display criteria and never publishes Now Playing (Sodalite#175).

Disk retention is shared the same way, through `RetentionClaims`. Host contract: [api.md, Running several engines at once](api.md#running-several-engines-at-once).

**Display criteria and the play gate.** On tvOS `DisplayCriteriaController` writes `AVDisplayManager.preferredDisplayCriteria` (dynamic range and frame rate) before the item loads, so the panel's mode switch runs in parallel with the start. Elsewhere it is a stub. `DisplayCriteriaOwner` says who writes for a load: the engine (the default), AVKit, or the host.

After the session is built, a play gate (`waitForSwitch`) holds the start until a switch settles, on the native and the software path alike. `isAwaitingDisplaySwitch` is raised around that gate (AE#1000). `playbackPhase` reads `.loading` throughout, so this flag is how a host tells a panel wait from a source wait. Details: [api.md, Display criteria](api.md#display-criteria).

## Live sources

How the engine recovers when a live source reconnects, replays media it already sent, or changes shape. This page covers the native stream-copy path, playlist renewal and recording. The software host's live admission and its no-DVR loop are in [architecture-software.md, Live sources on the software host](architecture-software.md#live-sources-on-the-software-host).

### Exact overlap after a live source reconnect

After a reconnect a live source often re-sends media the engine already has. On the single-demuxer stream-copy path the engine removes that overlap only on proof.

**Proof of replay.**

- A rollback in timestamps alone is never proof. A rollback to a retained packet's DTS/PTS can open a provisional candidate (a run of packets suspected to be a replay), even if the first payload differs.
- Only exact DTS, PTS and compressed-payload SHA-256 matches count as replay evidence.
- Candidate packets are buffered until both tracks pass their previously admitted frontier (the newest packet already accepted on that track). Then the old media is removed, and new media continues on the existing timeline.

**Damaged boundaries.** A reconnect can cut a transport/PES packet in half. Two simple answers fail there: forwarding the whole candidate after one mismatch replays old pictures, and reopening right after that mismatch keeps hitting the same damaged boundary. So:

- A short unmatched run that includes the first packet of either track is quarantined, within a bounded source-time interval and a bounded unmatched-packet count per track.
- Before any exact match on a track, the first unmatched timestamp anchors that bound.
- Untimed packets stay under the producer's overall byte/packet limits and the source watchdog.
- Later exact matches, or crossing that track's old frontier, complete the interval. Discarding a candidate with gaps also requires distinct matching timestamps on every participating track.
- Prolonged divergence, EOF, a read failure, or the scan limits still interrupt a confirmed prefix without forwarding it.
- A short unconfirmed programme boundary keeps normal discontinuity handling.
- A source clock reset with different content is never classified as replay on its timestamps alone.

**Reopen.** A supported source reopens inside the same cache. Its fresh producer receives the bounded history of accepted packets and the source frontiers.

- A seek, channel change or independent load starts without that history.
- The failed socket is retired before the replacement opens.
- Changed track layouts ask for fresh host negotiation.
- Bridged audio and separate side-audio sources are excluded from paired replay recognition.

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

**Diagnostics.** Per-track and per-action diagnostics are rate-limited and include source timestamps or `missing`, never URLs.

- `forwarded` means the packet reached the normal pump path, not that a corrupt picture was shown.
- Native `LagDiag` clock progress follows the AVPlayer clock. `videoFrames=unavailable` records that it is not a rendered-frame counter, and unavailable drop counts show `-` instead of zero.

### Live replay boundary

Live packet admission also protects the outgoing transport boundary: the last packets before a reconnect, which the cut may have damaged. The engine holds a damaged picture there until the replayed media proves a clean copy exists.

- A timed, flagged (marked corrupt) video packet beyond admitted history is held, while earlier intact pictures and audio continue.
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

**Presentation repair is separate.** Native presentation repair uses layer readiness, independent of this optional output.

- Its bounded sequence (nudge, then item replacement) requires advancing playback, a resident buffer and an attached foreground surface.
- It does not reset source history or move a DVR viewer to the live edge.
- In-place item replacement keeps the repair budget, which only rearms after sustained healthy presentation.

### Live playlist renewal after a longer GOP

A live HLS playlist declares a target duration (the longest segment it will carry), and the first live media playlist seals that value: it never changes for that playlist. A later GOP can be longer than that. If a later finalized segment's serialized `EXTINF`, rounded to an integer, is larger than the sealed value, the provider creates a new `live-N/` playlist namespace with a larger seal.

- The old video and subtitle URLs keep their original target, and keep the end index before the oversized segment, even after that segment leaves the live window.
- Relative segment, init and subtitle URLs resolve within either namespace to the same retained cache. Source acquisition is not reopened.

The native consumer swaps to the renewed URL using the existing in-place reload and playlist placement code.

- The viewing position and play/pause intent carry across the swap, including a DVR position behind live.
- A renewal never repeats a startup cushion wait (the buffer the live start waits for) that already finished.
- It never cuts a GOP at a dependent frame or misstates a segment's duration.

Limits: a consumer item replacement can still cause a short interruption, and this policy cannot rebuild missing source frames.

### Live recording

`startRecording(to:)` (AE#560) copies a live source's packets into an MPEG-TS file, fed from the connection the session already holds. Nothing is decoded or re-encoded.

- **Where the tap sits.** The two routes that own a demux loop implement `LiveRecordingHost`: `HLSSegmentProducer` on the loopback route, `SoftwarePlaybackHost` on the software route. Their tap sits before the audio bridge, so the file keeps the source's own codecs. `.remoteBypass` cannot record, because the engine sees no bytes there.
- **Never block the demux thread.** The tap only offers each packet to `LiveRecordingQueue`, a byte-bounded handoff that never waits. When it is full it refuses and counts the drop, and the recording ends as `.writeTooSlow` instead of stalling the picture.
- **The writer.** `LiveRecordingWriter` drains the queue on its own queue, opens the file at the first video keyframe, and muxes. `RecordingState` is what `$recordingState` publishes.

Host contract: [api.md, Recording a live stream](api.md#recording-a-live-stream).
