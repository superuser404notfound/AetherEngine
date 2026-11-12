# Architecture: the software host

The software host decodes video in the engine and presents it through sample-buffer layers, for everything AVPlayer's HLS pipeline does not accept and for two opt-in stages. This page covers that host in depth: decoders, clock and renderer, the optional upscaling and Dolby Vision FEL stages, the audio tap, live playback on this host, and the compressed packet cache.

Start with the overview in [architecture.md](architecture.md). The native AVPlayer route has its own page, [architecture-native.md](architecture-native.md).

Contents:

- [Software decoder pipeline](#software-decoder-pipeline)
  - [How a session reaches this host](#how-a-session-reaches-this-host)
  - [VP9 hardware decode](#vp9-hardware-decode) and [VideoToolbox output metadata](#videotoolbox-output-metadata)
  - [Clock and transport](#clock-and-transport) and [rebuffering on the on-demand loop](#rebuffering-on-the-on-demand-loop)
  - [Audio channel layout and timestamps](#audio-channel-layout-and-timestamps)
  - [Live audio look-ahead and edge rebuffer](#live-audio-look-ahead-and-edge-rebuffer)
  - [Software renderer retirement](#software-renderer-retirement)
- [Optional video stages](#optional-video-stages): upscaling, Dolby Vision FEL
- [Audio on the software host](#audio-on-the-software-host)
- [Audio tap](#audio-tap)
- [Live sources on the software host](#live-sources-on-the-software-host)
- [Software VOD compressed packet cache](#software-vod-compressed-packet-cache)

## Software decoder pipeline

The software path decodes in the engine and renders through sample-buffer layers:

- **Video:** decoders into `CVPixelBuffer`s. dav1d for AV1, VideoToolbox with a libavcodec fallback for VP9, `HardwareVideoDecoder` (VideoToolbox) for HEVC and AV1 Dolby Vision, `DualLayerVideoDecoder` for Dolby Vision FEL, FFmpeg's native decoder for VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 and the rest.
- **Audio:** an audio producer (`SoftwareAudioProducing`) into `CMSampleBuffer`s: libavcodec PCM decode, compressed E-AC-3 JOC, or an APAC / PCM object-audio bed for TrueHD Atmos and DTS:X (`SoftwareAtmosRoute`).
- **Rendering:** `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer`, with `AVSampleBufferRenderSynchronizer` as the master clock.

```
Source URL ──► Demuxer ──┬─► video decoder ──► [UpscalingFrameHandler] ──► SampleBufferRenderer
                          │   (SoftwareVideoDecoder,   (opt-in)                     │
                          │    HardwareVideoDecoder,                                ▼
                          │    DualLayerVideoDecoder)                   AVSampleBufferDisplayLayer
                          │                                                         ▲
                          └─► audio producer ──► AudioOutput ───────────────────────┘
                              (PCM decode, E-AC-3     │          (synchronizer drives the layer's
                               JOC, object-audio bed) ▼           control timebase → A/V sync)
                                                AVR / speakers
```

### How a session reaches this host

`VideoRoutingPolicy` sends a source here at load when AVPlayer's HLS-fMP4 pipeline cannot take its video. The per-codec list, with the reason for each row, is in [formats.md, Software decode](formats.md#software-decode). Two opt-in stages also move a session here: [upscaling](#low-resolution-upscaling) and [Dolby Vision FEL composition](#dolby-vision-profile-7-fel). A host can ask for this host directly with `LoadOptions.preferredDecodePath = .software`.

A running native session can also move here. `SoftwarePathEscalation` takes over after a CoreMedia refusal, under its normal route and host opt-in constraints (`escalatesToSoftwarePath`), and the rebuild starts from the pending user seek or the actual playhead. One trigger is described in [AVC configuration changes](architecture-native.md#avc-configuration-changes). `videoRoute` reports the move ([Effective video route](architecture.md#effective-video-route-videoroute)).

**Interlace check on VOD.** On seekable VOD (#232) the declared field order is first checked against decoded frames (`InterlaceProbe`). The filter engages on `AV_FRAME_FLAG_INTERLACED` alone, so a sample in which that flag never appears proves the detour would do nothing, and the stream goes back to the native path.

**AV1 capability registration is lazy.** The engine registers the supplemental VideoToolbox AV1 decoder and checks `VTIsHardwareDecodeSupported` (`VTCapabilityProbe`) only when routing an AV1 source, so devices with hardware AV1 take the native path. Loading H.264, HEVC or audio-only content does not consult it. AV1 decode details and AV1 Dolby Vision: [formats.md, AV1](formats.md#av1) and [AV1 Dolby Vision](formats.md#av1-dolby-vision). Atmos on this host: [Audio on the software host](#audio-on-the-software-host).

### VP9 hardware decode

The software host tries a hardware-only VideoToolbox session for VP9 profile 0 (8-bit 4:2:0) and profile 2 (10-bit 4:2:0).

- `VideoToolboxVideoFormat` builds the `vpcC` record that WebM omits, using the [VP codec configuration box](https://www.webmproject.org/vp9/mp4/#vp-codec-configuration-box) layout.
- Registering the supplemental decoder is gated by OS availability.
- `VideoDecoderOpener` closes a failed candidate and opens libavcodec before the host publishes its decoder or starts reading packets. A failed fallback is also closed and its error is passed on.
- `HardwareVideoDecoder` reads the coded size from each VP9 key frame header and rebuilds its session when the size changes. The feed epoch is checked under the session lock before replacement, so a packet from before a seek cannot discard the current reference pictures.

Playback stays on the software presentation route, because AVPlayer's HLS path does not accept VP9. Existing HEVC hardware probing, Dolby Vision selection and HDR10+ delivery are unchanged.

### VideoToolbox output metadata

VideoToolbox decode callbacks can keep their image buffer as a reference picture, so the engine must not change it carelessly. The hardware video decoder passes the callback's `imageBufferModifiable` flag into `VideoToolboxOutputMetadataNormalizer`:

- Matching colour and pixel-aspect attachments leave the buffer untouched.
- A modifiable buffer is updated in place.
- Otherwise the update goes into an owned pixel buffer from a pool keyed by format.
- If the copy fails, the original output is kept rather than changing storage the decoder still owns.
- The same policy removes a stale pixel-aspect attachment when the current stream uses square pixels.

**Exception: the dual-layer base-layer decoder** (`allowsInPlaceOutputMetadata`). The composer writes the composed pixels into that decoded buffer anyway, so an owned copy would only cost a second pool.

The risk this accepts is later frames decoding from composed pixels, which would show as drift until the next IDR. It is verified on the Mac only, and a long-GOP picture comparison on the Apple TV decoder is still open ([measurements.md](measurements.md#dual-layer-in-place-output-metadata)).

**AV1 Dolby Vision RPU path.** It reuses that owned output, or makes its own copy, before changing buffer and IOSurface metadata. If copying fails, it delivers the original without setting or clearing RPU keys, including when RPU attachment is disabled.

### Clock and transport

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

### Rebuffering on the on-demand loop

The software host publishes a pump's hold as `isRebuffering`, which `playbackPhase` reads as `.rebuffering` ([Playback status](architecture.md#playback-status-playbackphase)). On the on-demand (VOD) loop:

- **The pause arm.** The loop pauses only once its pause arm is open: the source has either built `AudioLookaheadPolicy.rebufferResumeLeadSeconds` of lead once, or let the clock run `starvedLeadSeconds` (one second) past the last audio fed (AE#1025). A seek closes the arm again.
  - The first condition keeps an exactly-realtime origin, whose lead sits at its start offset, from pausing at every start.
  - The second catches a source slower than real time from the first byte. Such a source never builds that lead, and without this rule the clock would run on over a starved read-ahead with the phase at `.playing`.
- **Parked video keeps flowing.** While video is parked, the loop's read waits at most `parkedVideoReadWaitSeconds` (20 ms) for the source before it hands parked video to the renderer again. The loop is the only thread that does that, so an unbounded wait on a slow source would let the renderer run dry ([measured](measurements.md#parked-video-read-wait)).
- **The resume.** The resume after such a pause starts the clock through the video preroll, and a full layer counts as ready there (`SampleBufferRenderer.prerollSatisfied`). The frames handed over sit at or behind the stopped clock and nothing more fits until it runs, so without this the gate would wait out `AudioOutput.prerollTimeout`, and the clock would stand 2 s longer with the phase already back at `.playing`. A start or a seek begins with a flushed layer and still waits for `videoPrerollSeconds`.

### Audio channel layout and timestamps

**The channel layout on the format description must name the order the resampler wrote** (#401). `AudioDecoder` resamples into the layout from `makeResamplerOutputLayout` and stamps the tag from `audioChannelLayoutTag`. If the two disagree, the renderer places audio where the decoder never put it ([what a mismatch did](measurements.md#software-channel-layout-mismatch)).

- The two functions live side by side, and a test holds them against each other twice: once structurally, and once by rendering each channel through a real downmix.
- 6.1 is the one channel count CoreAudio has no matching tag for, so the resampler is pointed at 6.1(back) rather than leaving the common tags for a `UseChannelDescriptions` layout.

**Audio timestamps come from a sample count.** `AudioDecoder` stamps each `CMSampleBuffer` from a running sample count anchored to the first frame (`AudioClockAnchor`), not from the container's rounded per-packet PTS.

- Container time bases are coarse (1 ms in MKV). When a frame's duration is not a whole number of ticks (a 1536-sample AC-3 frame is 34.83 ms at 44.1 kHz but exactly 32 ms at 48 kHz), the rounded PTS leave a sub-millisecond gap or overlap at every buffer boundary. `AVSampleBufferAudioRenderer` then reconciles a discontinuity at each one: ~29 clicks per second, a continuous crackle.
- With the sample clock, consecutive buffers line up exactly.
- A real source discontinuity (> 100 ms off the predicted clock, such as a seek or an edit) re-anchors, so genuine gaps are not hidden. `flush()` drops the anchor.
- The clock advances only on a buffer that was actually emitted, so a dropped buffer adds no phantom samples.

### Live audio look-ahead and edge rebuffer

**The problem.** The DVR feeder loop interleaves audio behind the video renderer's back-pressure gate. On its own, the audio renderer can then hold no more than the video queue allows (under 1 s measured). On devices where software 1080i decode plus deinterlace runs near real time, that margin is zero and every feeder stall is an audible dropout (#107).

**The look-ahead pump.** The feeder runs an audio look-ahead pump (`AudioLookaheadPolicy` + `AudioLookaheadState`). It is an independent ring cursor that decodes and enqueues audio packets ahead of the combined cursor until the renderer holds `targetLeadSeconds` (4 s) over the synchronizer clock.

- Audio delivery does not depend on video decode speed. A chronically slow video decode shows as late video frames under smooth audio, which is the right priority.
- DVR seeks reset the pump cursor together with `setFeedCursor` (compare-and-set, the seek wins).

**Edge rebuffer.** The same pump pass handles a live source that delivers below real time. When the pump drains the ring at the edge, the free-running clock would otherwise outrun the stream for good: every later sample lands in the clock's past, a continuous chopping that never recovers. `AudioLookaheadPolicy.clockAction` pauses the clock at `underrunPauseLeadSeconds`, refills, and resumes at `rebufferResumeLeadSeconds`. This mirrors AVPlayer's stall handling on the native path.

**Seek landings near the frontier.** A host seek does not trigger that rebuffer on purpose. A software live landing closer to the reader's frontier than `rebufferResumeLeadSeconds` is held that far back (`AetherEngine.softwareLiveLanding`, Sodalite#104).

On a real-time source the lead arrives exactly as slowly as it is deep, so a landing at the frontier would park the clock for that long and then resume at the same distance behind as the held-back landing starts from.

**Segmented live sources.** A source that delivers whole segments (a live HLS ingest) gets a holdback sized from the segment length (`SoftwareLiveHoldback`, AE#813).

The join lead, the landing, the live-edge tolerance and a rebuffer's resume cushion (`newest source PTS - clock`, on top of the audio lead, since the pump caps that lead at `targetLeadSeconds`) all follow it. A continuous source keeps the values above.

**Resume after a source pause.** A paused source comes back in one of two ways: it skips what it missed and continues near real time, or it hands over the whole backlog at once. The second leaves the picture the length of the pause behind the newest media, on a path that never catches up by itself. So the feeder watches a resume with the join's rule (`SoftwareLiveJoinPolicy`, measured from the clock instead of the ring's first packet):

- Once the backlog has landed, if the span is past the band the edge verdict already counts as the edge (`SoftwareLiveHoldback.resumeCatchUpSpanSeconds`), the engine moves the picture up to the join lead behind the newest media through its own live seek (`SeekOrigin.liveRejoin`).
- An ordinary resume on a segmented source, up to its cushion plus one unit behind, is inside that band and is never followed by a seek.
- A source that skipped is left where it resumed.

Diagnose with `aetherctl play --audio-stats` (see [cli.md](cli.md)).

### Software renderer retirement

Each software playback host owns a fresh display layer. On stop, `AudioOutput` asks for immediate synchronizer removal with an invalid time and returns without blocking the main actor.

- A shared retirement task keeps the output, synchronizer and display layer alive until AVFoundation calls the completion handler. Cancellation does not release them early.
- Repeated detach requests share that task.
- A caller that reuses the same layer must await retirement before attaching it again.

## Optional video stages

### Low-resolution upscaling

With `LoadOptions.upscalesLowResolutionVideo` (#846, AE#1039), `load()` asks `UpscaleRouteDecision` once, from the probe, the display size and the device (`AetherEngine+Upscale.swift`). The decision is pure and logs one line.

**When the route is taken.** SDR, non-Dolby-Vision, 8-bit 4:2:0 video below 1080p, on OS 26 or later, when the display is larger than the source. Not on a wireless AirPlay route, and not on a live session with demuxed audio. `upscaleScaler = .lineArt` also takes 10-bit and 1080p. A plan whose stage gave up earlier in this process (`UpscaleFailureMemory`) is not taken again at that rate or a faster one.

**Where it runs.** A taken route moves the session to the software host, also when it would otherwise have played natively (`sourceSoftwareOnlyForUpscale`). The host wraps its decoder's frame handler (`UpscalingFrameHandler`), and `FrameUpscaler` runs on every decoded frame:

- `.automatic`: VideoToolbox low-latency super resolution on the Neural Engine where the device offers a scale factor, then MetalFX Spatial to the target size.
- `.lineArt`: Anime4K's 2x upscale and restore networks as Metal compute kernels (`LineArtShaderSource`), then a bilinear resample.
- The stage returns nil whenever the original frame should go out instead. Its VideoToolbox session is built off the decode thread (about 4 s cold on Apple TV), and frames pass through until it is ready.

**Budget.** Over a 48-frame window the stage's mean time must stay under 90% of the frame interval.

- An overrun first drops one rung: MetalFX after an ML pass, or the line-art restore pass and then line art itself for the automatic scaler.
- A further overrun, or three failures in a row, disables the stage for the session.
- If only the stage had put a URL VOD session on the software path, the session is then rebuilt on the native path (`upscaleDisableReturnsToNative`).

`$activeUpscale` publishes what runs. See [api.md, `upscalesLowResolutionVideo`](api.md#upscaleslowresolutionvideo).

### Dolby Vision Profile 7 FEL

By default a Profile 7 source plays its base layer on the native route, with each RPU rewritten to Profile 8.1. That drops the residual a FEL (full enhancement layer) carries. Two optional stages keep it, each behind a package trait that is off by default. Which to ship, and why: [dolby-vision-fel.md](dolby-vision-fel.md).

**Curve fold** (trait `DolbyVisionFelCurves`, `Video/FelCurves/`). It stays on the native route.

- `FelCurveLookahead` sits between the demuxer and `HLSSegmentProducer` on a VOD source. It holds back one GOP of packets, video and audio, then releases them in read order.
- Each scene that starts in the GOP is measured on its first picture: both layers decoded with VideoToolbox, sampled by `FelCurveSampler`, fitted by `FelCurveFit`.
- That luma residual is folded into the 8.1 RPU's luma curve, and the platform's Dolby Vision decoder applies it.
- It is not armed on live sources, with `foldsDolbyVisionFEL` off, or while the AVPlayer-output route below needs the enhancement layer intact. It pauses while the RPU cannot reach the picture (AE#1018).

See [dolby-vision-fel.md, section 7](dolby-vision-fel.md#7-curve-fold-on-the-native-route).

**Dual-layer composition** (trait `DualLayerDolbyVision`, opt-in with `preferDualLayerDolbyVision`). `DualLayerRouteDecision` decides once per Profile 7 source whether the stream is FEL and the device can decode both layers in real time. If so, the session takes one of two routes:

- **Software host** (`dualLayerRoute = .softwareHost`, the default). `DualLayerVideoDecoder` decodes both layers and composes them on the GPU (`DoviFelComposer`).
- **AVPlayer output** (`dualLayerRoute = .avPlayerOutput`). The session stays native. AVPlayer plays the 8.1 base layer and the audio from the loopback and owns the clock.
  - `DualLayerOutputRoute` takes its decoded frames from an `AVPlayerItemVideoOutput` and pairs them with the enhancement-layer packets the producer's read hands to `VideoPacketTap`.
  - It composes them with the same decoder and shows the result in a display layer above the hidden player layer.
  - The forward window is capped at 10 segments so the enhancement-layer ring still covers the playhead.
  - The route stands down when AirPlay or an external display takes the picture.

See [dolby-vision-fel.md, 5.2 Routing](dolby-vision-fel.md#52-routing) and [5.2.4 The AVPlayer-output route](dolby-vision-fel.md#524-the-avplayer-output-route).

The 2:3 pulldown retimer is not an optional stage: it is part of the native route's frame grid, see [2:3 pulldown timing on 24p film](architecture-native.md#23-pulldown-timing-on-24p-film).

## Audio on the software host

How each audio route sits on this host next to the native one (stream copy of E-AC-3 JOC, PCM decode, the object-audio render through `SoftwareAPACProducer`, and how `SoftwareAtmosRoute` picks per track) is one table, kept with the native side: [architecture-native.md, Audio routes and object audio](architecture-native.md#audio-routes-and-object-audio). The channel layout and timestamp rules of the PCM decode are under [Audio channel layout and timestamps](#audio-channel-layout-and-timestamps).

## Audio tap

`installAudioTap()` (#95) returns an `AsyncStream<AudioTapBuffer>` of decoded playback audio:

- Format: mono Float32 48 kHz (`AetherEngine.audioTapFormat`).
- Timestamps: source-PTS seconds (`sourceTime`, same axis as `engine.sourceTime`).
- A `discontinuity` flag on any gap (seek, eviction, track switch, drops under pressure).

It is meant for host-side speech features (live transcription with SpeechAnalyzer) and audio recognition (ShazamKit signatures).

```
native ──► SegmentCache (init + seg N) ──► mov demux ──► libavcodec ──► swr (mono 48k) ──► AsyncStream
software ──► AudioDecoder CMSampleBuffers ──► AVAudioConverter (mono 48k) ──► AsyncStream
                       (.dialogue: swr matrix / channel copy takes the centre alone)
```

### Where the audio comes from

| Path | Reader | How |
| --- | --- | --- |
| Native | `LoopbackAudioReader` | Pulls the engine's own muxed fMP4 segments from the segment cache near the playhead and decodes their audio track out-of-band (libavcodec + libswresample). Each segment gets a fresh demux context that reads the init and fragment in place and discards every stream but the audio one (#910). Because it reads the mux, it follows the active audio track for free (the mux holds exactly the selected track, after the bridge), adds zero network load, and cannot stall playback. |
| Remote HLS (direct AVPlayer ingest, no loopback, VOD and live) | `AudioTapHLSReader` | `AudioTapHLSVariantResolver` picks the active audio rendition or muxed variant. `AudioTapHLSFetcher` fetches and decrypts (AES-128 clear-key) self-contained TS / fMP4 segments, sending `LoadOptions.httpHeaders` like the player's asset (#119). The reader follows the playhead and decodes near it. |
| Software | `AVAudioConverter` sink on `SoftwarePlaybackHost` | Mirrors the host's PCM output. A track passed through compressed (E-AC-3 JOC) is side-decoded for the tap. |

`AudioTapReaderSelection` makes the reader choice per session. `audioTapHasDeliverySource` tells the host whether the current session can deliver at all, so a missing source fails loudly.

**Software path downmix.** The decoder emits the source channel layout up to 7.1 without downmixing.

- The sink takes its input format from the sample buffer's own channel layout. The channel-count-only `AVAudioFormat` initializer returns nil for every count above 2.
- It checks once per format that the converter really mixes down. Any discrete layout converts to digital silence without an error, so those are folded to mono inside the tap instead (#400).
- The converter runs with `downmix` on. Without it, AVAudioConverter maps by channel label instead of mixing: a stereo track arrives as its left channel, 2.1 as silence, and 4.0 to 7.1 as the centre alone (#908).

**Dialogue mode.** A `.dialogue` install (`installAudioTap(channels:)`) takes the front-centre channel alone instead of the downmix. The native and remote-HLS decoders set a one-row swresample matrix with the centre at unity; the software sink copies that channel out before the converter. Without a centre channel it falls back to the downmix. Each buffer's `channels` says which one it carries.

### Lifecycle

- One tap per engine. Installing again replaces the previous stream.
- `load()` and `stop()` finish the stream. Opt-in is per load; with no session, or a video-only source, the stream finishes immediately.
- The audio-only pipeline has no tap reader (`AudioTapReaderSelection` maps every backend but native and software to none). There too the stream finishes at once, and `audioTapHasDeliverySource` is false.
- A session-preserving reload finishes it too (audio / subtitle / disc-title switch, `reloadAtCurrentPosition`).
- Every delivery path is bound to the session it was installed on, and each install gets a fresh `AudioTapMonotonicFilter`. So a host re-installs when the stream ends and starts the new session on a clean timeline, not one stitched across a reload that resumes slightly behind the old position (#356).

### Release window and memory

Both readers decode whole segments but release the decoded buffers along the playhead:

- A buffer goes out once it starts before playhead + lead (10 s).
- The head of the segment an anchor lands in, if it already ended behind the playhead, is dropped.
- So the stream is handed at most tolerance + lead (12 s), however long a segment runs.

That bounds the release window, not memory. The decoded rest of the current segment is held on top of it, so the held tail grows with the segment length. For example, a reader parked at 95 s on 15 s segments has released 12.1 s and still holds 14.9 s. Whatever the consumer keeps is its own.

A backward seek is detected from the playhead's own movement, never from how far the decode runs ahead of it (#864).

**Delivery and overflow.** Delivery is best-effort, and lossy only for a consumer that falls behind:

- The stream queues 256 buffers (`bufferingOldest`, about twice the release window at the 100 ms chunk floor).
- A buffer that arrives while the queue is full is dropped, and the first buffer taken after that carries `discontinuity`. A host never reads contiguous PCM across an overflow.
- There is no non-evicting mode, because a stalled consumer would turn it into unbounded memory.

Live sources are best-effort.

The tap's reader for each path lives where that path does (native, remote HLS, software); it sits on this page because its sink and downmix rules are shared.

## Live sources on the software host

The native stream-copy path's live recovery (reconnect overlap, the replay boundary, playlist renewal) is in [architecture-native.md, Live sources](architecture-native.md#live-sources). The software host reuses the same replay guard and adds the rules below.

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

Why: on Apple TV the disk store's appends stall the demux thread while a download runs, and video it has already parked reaches the decoder late ([measured](measurements.md#tvos-packet-cache-disk-appends)). AVPlayer also keeps its progressive-download cache in memory on tvOS.

**Host override.** `LoadOptions.softwarePacketCacheStorage` (`SoftwarePacketCacheStorage`) forces either store on any platform: `.disk`, `.memory`, or `.automatic` for the defaults above.

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

**Why not stay demoted.** A permanently demoted producer is a priority inversion the scheduler cannot see: the consumer waits on an `NSCondition`, and a condition donates no priority to the thread it waits for.

- It costs throughput, not only fairness, even with idle cores: the efficiency class throttles the spool writes the producer makes for every packet, and that needs no CPU contention.
- The adaptive choice keeps almost all of the efficiency-class CPU time a permanently demoted producer would have, at identical total CPU.

The benchmark behind both statements: [measurements.md, Packet cache producer QoS](measurements.md#packet-cache-producer-qos).

Consumer starvation is reported as its own rate-limited line, so a source that cannot keep up is visible directly instead of guessed from a stalled clock.

### Tests

The CI packet-cache step runs the standalone regressions for coverage, VFR successors, the disk FIFO, read-ahead concurrency, host admission and the AVPacket envelope. They use generated numeric data and temporary records, not private video fixtures.
