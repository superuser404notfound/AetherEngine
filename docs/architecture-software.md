# Architecture: the software host

The software host (`SoftwarePlaybackHost`) is the pipeline in which the engine decodes video itself and presents it through sample-buffer layers (`AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer`) instead of AVPlayer. It plays everything AVPlayer's HLS pipeline does not accept, and it runs two opt-in stages. This page covers it in depth: decoders, clock and renderer, the optional upscaling and Dolby Vision FEL stages, the audio tap, live playback on this host, and the compressed packet cache.

Start with the overview in [architecture.md](architecture.md). The native AVPlayer route has its own page, [architecture-native.md](architecture-native.md).

**Words this page uses.**

- **Host app**: the app that embeds the engine. **Host** alone, in a type name, means a playback host: the engine object that runs one pipeline for one session.
- **Synchronizer**: the `AVSampleBufferRenderSynchronizer` that both renderers are attached to. Its clock is the master clock of the session: "the clock" on this page means this one.
- **Producer** and **consumer**: a producer thread reads ahead from the source and stores packets; a consumer takes them out to decode. The two run at different speeds on purpose.
- **Lead**: how far the audio or video already handed to a renderer runs ahead of the clock, in seconds.
- **Frontier**: the newest point in the source the reader has reached.

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

- **Video:** decoders that output `CVPixelBuffer`s.
  - dav1d for AV1.
  - VideoToolbox with a libavcodec fallback for VP9.
  - `HardwareVideoDecoder` (VideoToolbox) for HEVC and AV1 Dolby Vision.
  - `DualLayerVideoDecoder` for Dolby Vision FEL.
  - FFmpeg's native decoder for VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 and the rest.
- **Audio:** an audio producer (`SoftwareAudioProducing`, the component that turns the audio track into `CMSampleBuffer`s). It does one of three things: libavcodec PCM decode, pass E-AC-3 JOC through compressed, or render an APAC / PCM object-audio bed for TrueHD Atmos and DTS:X (`SoftwareAtmosRoute`).
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

**At load.** `VideoRoutingPolicy` sends a source here when AVPlayer's HLS-fMP4 pipeline cannot take its video. The per-codec list, with the reason for each row, is in [formats.md, Software decode](formats.md#software-decode).

- Two opt-in stages also move a session here: [upscaling](#low-resolution-upscaling) and [Dolby Vision FEL composition](#dolby-vision-profile-7-fel).
- A host app can ask for this host directly with `LoadOptions.preferredDecodePath = .software`.

**Mid-session (escalation).** A running native session can also move here. Escalation means `SoftwarePathEscalation` rebuilds the session on this host after CoreMedia refuses the media.

- It runs under its normal route and host app opt-in constraints (`escalatesToSoftwarePath`).
- The rebuild starts from the pending user seek or the actual playhead.
- One trigger is described in [AVC configuration changes](architecture-native.md#avc-configuration-changes).
- `videoRoute` reports the move ([Effective video route](architecture.md#effective-video-route-videoroute)).

**Interlace check on VOD.** Interlaced H.264 comes here to be deinterlaced. On seekable VOD (#232) the declared field order is first checked against decoded frames (`InterlaceProbe`). The deinterlace filter engages on `AV_FRAME_FLAG_INTERLACED` alone. So if that flag never appears in a sample, the detour would do nothing, and the stream goes back to the native path.

**AV1 capability registration is lazy.** The engine registers the supplemental VideoToolbox AV1 decoder and checks `VTIsHardwareDecodeSupported` (`VTCapabilityProbe`) only when routing an AV1 source, so devices with hardware AV1 take the native path. Loading H.264, HEVC or audio-only content does not consult it.

- AV1 decode details and AV1 Dolby Vision: [formats.md, AV1](formats.md#av1) and [AV1 Dolby Vision](formats.md#av1-dolby-vision).
- Atmos on this host: [Audio on the software host](#audio-on-the-software-host).

### VP9 hardware decode

The software host first tries a hardware-only VideoToolbox session for VP9 profile 0 (8-bit 4:2:0) and profile 2 (10-bit 4:2:0).

- `VideoToolboxVideoFormat` builds the `vpcC` record that WebM omits, using the [VP codec configuration box](https://www.webmproject.org/vp9/mp4/#vp-codec-configuration-box) layout.
- Registering the supplemental decoder is gated by OS availability.
- `VideoDecoderOpener` closes a failed candidate and opens libavcodec before the host publishes its decoder or starts reading packets. A failed fallback is also closed and its error is passed on.
- `HardwareVideoDecoder` reads the coded size from each VP9 key frame header and rebuilds its session when the size changes.
- Before that replacement it checks the feed epoch (a counter that every decoder flush advances, and every seek flushes) under the session lock. So a packet from before a seek cannot discard the current reference pictures.

Playback stays on the software presentation route, because AVPlayer's HLS path does not accept VP9. HEVC hardware probing, Dolby Vision selection and HDR10+ delivery work as before.

### VideoToolbox output metadata

A VideoToolbox decode callback can keep its output image buffer as a reference picture for later frames. So the engine must not change that buffer carelessly when it fixes colour or pixel-aspect attachments. The hardware video decoder passes the callback's `imageBufferModifiable` flag into `VideoToolboxOutputMetadataNormalizer`, which decides:

- Matching colour and pixel-aspect attachments leave the buffer untouched.
- A modifiable buffer is updated in place.
- Otherwise the update goes into an owned pixel buffer from a pool keyed by format.
- If the copy fails, the original output is kept rather than changing storage the decoder still owns.
- The same policy removes a stale pixel-aspect attachment when the current stream uses square pixels.

**Exception: the dual-layer base-layer decoder** (`allowsInPlaceOutputMetadata`). The composer writes the composed pixels into that decoded buffer anyway, so an owned copy would only cost a second pool.

The risk this accepts: later frames could decode from composed pixels, which would show as drift until the next IDR (the next full keyframe). It is verified on the Mac only. A long-GOP picture comparison on the Apple TV decoder is still open ([measurements.md](measurements.md#dual-layer-in-place-output-metadata)).

**HDR10 static metadata (AE#957).** VideoToolbox attaches no mastering display colour volume or content light level to the frames it decodes, though the stream carries both. The hardware decoder finds the stream's values at `open()` and the normalizer adds them with the colour attachments, under the same policy. `HDR10StaticMetadataSEI` reads them for a PQ stream:

- from the container first (`mdcv` / `clli` boxes, Matroska colour metadata, both arrive as `codecpar` side data);
- then from the SEI in the `hvcC` (x265 writes it there);
- then from the SEI of the first 3 key frames, for HEVC and H.264. Frames before the values are found go out without them.

The SEI payloads are byte for byte what Core Video's attachments hold, so they are copied as they are. The television does read these attachments, see [measurements.md](measurements.md#hdr10-metadata-on-the-software-path-reaches-the-television-ae957).

**The decoder's format description carries the same values (AE#957).** The owned copy costs about 7 ms per 4K frame on an A12 Apple TV, so the normalizer should only ever need it as a fallback. For HEVC, AV1 and VP9 the description VideoToolbox decodes with names the stream's colour, and the HDR10 values known at `open()`. VideoToolbox then attaches both itself and the frames match as decoded. Without the colour keys it tagged a PQ BT.2020 HEVC clip as BT.709, and every frame was copied. Values found later, in a key frame's SEI, still go on by copy.

At `close()` the decoder logs how each frame went: `output metadata over N frames: A as decoded, B in place, C copied, D copy failed`. Copies on every frame mean the description and the normalizer disagree. Numbers: [measurements.md](measurements.md#per-frame-cost-of-the-software-path-ae957); to time it on a device, [`aetherctl bench`](cli.md#bench).

**AV1 Dolby Vision RPU path.** (The RPU is the per-frame Dolby Vision metadata.) This path reuses that owned output, or makes its own copy, before changing buffer and IOSurface metadata. If copying fails, it delivers the original without setting or clearing RPU keys, including when RPU attachment is disabled.

### Clock and transport

**Clock arming.** The feeder (the loop that hands decoded media to the renderers) starts the clock once it has media; this is "arming". It publishes the arm latch (a flag that says the clock now exists) synchronously, so `play()` and `pause()` can see it.

After arming, a rate correction runs on the main actor next to those transport calls, so it cannot restart the synchronizer halfway through a pause. Before applying the correction it:

- rechecks the output identity and the seek generation,
- ignores a stopped or seeking session,
- leaves end-of-media tail playback to its owner, unless the host app explicitly paused.

**Command revision.** The correction also carries the output's clock-command revision, a counter that every clock command advances. `AudioOutput` compares that revision and applies the rate under its existing lock. So a later rebuffer pause, seek or rate command wins over the queued correction.

- A preroll completion (the start that waits until enough media is queued) belongs to its original command and keeps the revision.
- A paused intent cancels a pending preroll start, even while the synchronizer still reports rate zero.

**Explicit pause.** The software host's `pause()` also calls `AudioOutput.setPlaybackEnabled(false)`, which owns every clock write under the output lock. Stale feeder arms, rebuffer releases and preroll completions then cannot start the clock, even without a command revision.

- A paused seek still moves its anchor, at zero rate.
- Internal buffering pauses leave this transport intent alone.
- Only `play()` re-enables it. Enabling alone neither starts a clock with no anchor nor advances the command revision. So when play arrived before the feeder published its arm latch, a pending arm correction can still supply the first start.

**Seeks keep the last frame on screen.** `SampleBufferRenderer.flush()` takes a `removingDisplayedImage` flag and passes it to `AVSampleBufferVideoRenderer.flush(removingDisplayedImage:)`.

- Stop and teardown clear the visible frame (the default).
- `SoftwarePlaybackHost.seek()` passes `false`. The previous frame stays up until the keyframe after the seek decodes, instead of flashing black on slow sources like MPEG-2.
- This matches the native path, which also holds the frame through a seek (#90).

### Rebuffering on the on-demand loop

The software host publishes a pump's hold as `isRebuffering` (a pump is a read and feed loop), which `playbackPhase` reads as `.rebuffering` ([Playback status](architecture.md#playback-status-playbackphase)). On the on-demand (VOD) loop:

**The pause arm.** The loop may pause only once its pause arm is open. The arm opens when either:

- the source has built `AudioLookaheadPolicy.rebufferResumeLeadSeconds` of lead once, or
- the clock has run `starvedLeadSeconds` (one second) past the last audio fed (AE#1025).

A seek closes the arm again. Why both conditions:

- The first keeps an origin that delivers at exactly real time from pausing at every start. Its lead sits at its start offset.
- The second catches a source slower than real time from the first byte. Such a source never builds that lead. Without this rule the clock would run on over a starved read-ahead with the phase at `.playing`.

**Parked video keeps flowing.** Parked video is decoded video that waits until the renderer has room. While video is parked, the loop's read waits at most `parkedVideoReadWaitSeconds` (20 ms) for the source, then hands parked video to the renderer again. The loop is the only thread that does that, so an unbounded wait on a slow source would let the renderer run dry ([measured](measurements.md#parked-video-read-wait)).

**The resume.** After such a pause the clock restarts through the video preroll, and a full layer counts as ready there (`SampleBufferRenderer.prerollSatisfied`).

- Why: the frames already handed over sit at or behind the stopped clock, and nothing more fits until it runs. Without this rule the gate would wait out `AudioOutput.prerollTimeout`, and the clock would stand 2 s longer with the phase already back at `.playing`.
- A start or a seek begins with a flushed layer and still waits for `videoPrerollSeconds`.

### Audio channel layout and timestamps

**The channel layout on the format description must name the order the resampler wrote** (#401). `AudioDecoder` resamples into the layout from `makeResamplerOutputLayout` and stamps the tag from `audioChannelLayoutTag`. If the two disagree, the renderer places audio where the decoder never put it ([what a mismatch did](measurements.md#software-channel-layout-mismatch)).

- The two functions live side by side. A test holds them against each other twice: once structurally, and once by rendering each channel through a real downmix.
- 6.1 is the one channel count CoreAudio has no matching tag for. So the resampler is pointed at 6.1(back), rather than leaving the common tags for a `UseChannelDescriptions` layout.

**Audio timestamps come from a sample count.** `AudioDecoder` stamps each `CMSampleBuffer` from a running sample count anchored to the first frame (`AudioClockAnchor`), not from the container's rounded per-packet PTS.

- Why: container time bases are coarse (1 ms in MKV). When a frame's duration is not a whole number of ticks (a 1536-sample AC-3 frame is 34.83 ms at 44.1 kHz but exactly 32 ms at 48 kHz), the rounded PTS leave a sub-millisecond gap or overlap at every buffer boundary. `AVSampleBufferAudioRenderer` then reconciles a discontinuity at each one: ~29 clicks per second, a continuous crackle.
- With the sample clock, consecutive buffers line up exactly.
- A real source discontinuity (> 100 ms off the predicted clock, such as a seek or an edit) re-anchors, so genuine gaps are not hidden. `flush()` drops the anchor.
- The clock advances only on a buffer that was actually emitted, so a dropped buffer adds no phantom samples.

### Live audio look-ahead and edge rebuffer

**The problem.** On live sources with DVR (a rewindable window of the live stream), the DVR feeder loop reads packets from a ring buffer and interleaves audio behind the video renderer's back-pressure gate. On its own, the audio renderer can then hold no more than the video queue allows (under 1 s measured). On devices where software 1080i decode plus deinterlace runs near real time, that margin is zero, and every feeder stall is an audible dropout (#107).

**The look-ahead pump.** The feeder runs an audio look-ahead pump (`AudioLookaheadPolicy` + `AudioLookaheadState`). It is an independent cursor into the ring. It decodes and enqueues audio packets ahead of the combined cursor (the one that feeds audio and video together) until the renderer holds `targetLeadSeconds` (4 s) over the synchronizer clock.

- Audio delivery does not depend on video decode speed. A chronically slow video decode shows as late video frames under smooth audio, which is the right priority.
- DVR seeks reset the pump cursor together with `setFeedCursor` (compare-and-set, the seek wins).

**Edge rebuffer.** The same pump pass handles a live source that delivers below real time. When the pump drains the ring at the live edge, the free-running clock would otherwise outrun the stream for good: every later sample lands in the clock's past, a continuous chopping that never recovers.

So `AudioLookaheadPolicy.clockAction` pauses the clock at `underrunPauseLeadSeconds`, refills, and resumes at `rebufferResumeLeadSeconds`. This mirrors AVPlayer's stall handling on the native path.

**Seek landings near the frontier.** A host app seek does not trigger that rebuffer on purpose. A software live landing closer to the reader's frontier than `rebufferResumeLeadSeconds` is held that far back (`AetherEngine.softwareLiveLanding`, Sodalite#104).

Why: on a real-time source the lead arrives exactly as slowly as it is deep. A landing at the frontier would park the clock for that long, then resume at the same distance behind as the held-back landing starts from.

**Segmented live sources.** A source that delivers whole segments (a live HLS ingest) gets a holdback (a fixed distance kept behind the newest media) sized from the segment length (`SoftwareLiveHoldback`, AE#813).

These all follow that holdback:

- the join lead (how far behind the newest media playback starts),
- the landing,
- the live-edge tolerance,
- a rebuffer's resume cushion (`newest source PTS - clock`, on top of the audio lead, since the pump caps that lead at `targetLeadSeconds`).

A continuous source keeps the values above.

**Resume after a source pause.** A paused source comes back in one of two ways:

- it skips what it missed and continues near real time, or
- it hands over the whole backlog at once. That leaves the picture the length of the pause behind the newest media, on a path that never catches up by itself.

So the feeder watches a resume with the join's rule (`SoftwareLiveJoinPolicy`, measured from the clock instead of the ring's first packet):

- Once the backlog has landed, the engine checks the span to the newest media. If it is past the band that the edge verdict already counts as the edge (`SoftwareLiveHoldback.resumeCatchUpSpanSeconds`), the engine moves the picture up to the join lead behind the newest media, through its own live seek (`SeekOrigin.liveRejoin`).
- An ordinary resume on a segmented source, up to its cushion plus one unit behind, is inside that band and is never followed by a seek.
- A source that skipped is left where it resumed.

Diagnose with `aetherctl play --audio-stats` (see [cli.md](cli.md)).

### Software renderer retirement

Retirement is how a stopped host lets go of its renderers safely. Each software playback host owns a fresh display layer. On stop, `AudioOutput` asks for immediate synchronizer removal with an invalid time, and returns without blocking the main actor.

- A shared retirement task keeps the output, synchronizer and display layer alive until AVFoundation calls the completion handler. Cancellation does not release them early.
- Repeated detach requests share that task.
- A caller that reuses the same layer must await retirement before attaching it again.

## Optional video stages

### Low-resolution upscaling

With `LoadOptions.upscalesLowResolutionVideo` (#846, AE#1039), `load()` asks `UpscaleRouteDecision` once, from the probe, the display size and the device (`AetherEngine+Upscale.swift`). The decision is a pure function and logs one line.

**When the route is taken.** All of these must hold:

- SDR, non-Dolby-Vision, 8-bit 4:2:0 video below 1080p,
- OS 26 or later,
- the display is larger than the source,
- not a wireless AirPlay route, and not a live session with demuxed audio.

`upscaleScaler = .lineArt` also takes 10-bit and 1080p. A plan whose stage gave up earlier in this process (`UpscaleFailureMemory`) is not taken again at that rate or a faster one.

**Where it runs.** A taken route moves the session to the software host, also when it would otherwise have played natively (`sourceSoftwareOnlyForUpscale`). The host wraps its decoder's frame handler (`UpscalingFrameHandler`), and `FrameUpscaler` runs on every decoded frame:

- `.automatic`: VideoToolbox low-latency super resolution on the Neural Engine where the device offers a scale factor, then MetalFX Spatial to the target size.
- `.lineArt`: Anime4K's 2x upscale and restore networks as Metal compute kernels (`LineArtShaderSource`), then a bilinear resample.
- The stage returns nil whenever the original frame should go out instead. Its VideoToolbox session is built off the decode thread (about 4 s cold on Apple TV), and frames pass through unchanged until it is ready.

**Budget.** Over a 48-frame window the stage's mean time must stay under 90% of the frame interval.

- An overrun first drops one rung: MetalFX after an ML pass, or the line-art restore pass and then line art itself for the automatic scaler.
- A further overrun, or three failures in a row, disables the stage for the session.
- If only the stage had put a URL VOD session on the software path, the session is then rebuilt on the native path (`upscaleDisableReturnsToNative`).

`$activeUpscale` publishes what runs. See [api.md, `upscalesLowResolutionVideo`](api.md#upscaleslowresolutionvideo).

**The frame chain** (`FrameChain`, AE#957) is what the line-art scaler and the HDR10 probe run on. It turns the 4:2:0 frame into a half-float RGB texture, runs its stages, and turns the result back into the input's format at the target size, all in one command buffer.

- A chain whose stages all leave the picture alone (`FrameChainStage.isIdentity`, today `PassThroughStage`) at its own size runs as one kernel with no RGB texture. On an A12 Apple TV the RGB texture cost most of the 10 ms the two passes took per 4K frame.
- That kernel is `frameChainRoundTripWide` when the width and the picture's x origin are multiples of 4: it reads and writes four luma samples per texel and folds the colour arithmetic, 2.7 ms per 4K frame on the A12. Otherwise `frameChainRoundTrip`, one sample per access, 4.0 ms.
- Every other chain keeps the two passes: a stage reads its neighbours from that texture.
- Both paths give the same picture: luma unchanged, chroma within one code value.

### Dolby Vision Profile 7 FEL

Profile 7 Dolby Vision (UHD Blu-ray) carries two video layers: a base layer, and an enhancement layer whose residual refines the picture. A FEL (full enhancement layer) carries real picture data in that residual.

By default a Profile 7 source plays its base layer on the native route, with each RPU (the per-frame Dolby Vision metadata) rewritten to Profile 8.1. That drops the residual. Two optional stages keep it, each behind a package trait that is off by default. Which to ship, and why: [dolby-vision-fel.md](dolby-vision-fel.md).

**Curve fold** (trait `DolbyVisionFelCurves`, `Video/FelCurves/`). It stays on the native route.

- `FelCurveLookahead` sits between the demuxer and `HLSSegmentProducer` on a VOD source. It holds back one GOP (group of pictures, from one keyframe to the next) of packets, video and audio, then releases them in read order.
- Each scene that starts in the GOP is measured on its first picture: both layers decoded with VideoToolbox, sampled by `FelCurveSampler`, fitted by `FelCurveFit`.
- That luma residual is folded into the 8.1 RPU's luma curve, and the platform's Dolby Vision decoder applies it.
- It is not armed on live sources, with `foldsDolbyVisionFEL` off, or while the AVPlayer-output route below needs the enhancement layer intact. It pauses while the RPU cannot reach the picture (AE#1018).

See [dolby-vision-fel.md, section 7](dolby-vision-fel.md#7-curve-fold-on-the-native-route).

**Dual-layer composition** (trait `DualLayerDolbyVision`, opt-in with `preferDualLayerDolbyVision`). `DualLayerRouteDecision` decides once per Profile 7 source whether the stream is FEL and the device can decode both layers in real time. If so, the session takes one of two routes:

- **Software host** (`dualLayerRoute = .softwareHost`, the default). `DualLayerVideoDecoder` decodes both layers and composes them on the GPU (`DoviFelComposer`).
- **AVPlayer output** (`dualLayerRoute = .avPlayerOutput`). The session stays native. AVPlayer plays the 8.1 base layer and the audio from the loopback (the engine's local HLS server) and owns the clock.
  - `DualLayerOutputRoute` takes its decoded frames from an `AVPlayerItemVideoOutput` and pairs them with the enhancement-layer packets the producer's read hands to `VideoPacketTap`.
  - It composes them with the same decoder and shows the result in a display layer above the hidden player layer.
  - The forward window is capped at 10 segments so the enhancement-layer ring still covers the playhead.
  - The route stands down when AirPlay or an external display takes the picture.

See [dolby-vision-fel.md, 5.2 Routing](dolby-vision-fel.md#52-routing) and [5.2.4 The AVPlayer-output route](dolby-vision-fel.md#524-the-avplayer-output-route).

### HDR10 pass-through probe

A measurement switch for AE#957, not a feature. It checks whether HDR10 metadata the engine attaches to a frame of its own reaches the television. tvOS has no `CAEDRMetadata`, so the attachments on the buffer given to `AVSampleBufferDisplayLayer` are the only lever. Tone mapping to a panel's peak depends on the answer.

It is off unless `AETHER_HDR10_PROBE` is set (`HDR10PassThroughProbe.swift`). The variable is read at every software-path load, so a test host can switch it between loads. It never runs with an upscale plan or on the dual-layer decoder.

| `AETHER_HDR10_PROBE` | each decoded frame |
|---|---|
| `log` | unchanged; the first frame's colour tags and HDR10 metadata are logged |
| `meta` | the decoder's buffer gets the probe's mastering display and content light level values |
| `chain` | goes through the frame chain (`PassThroughStage`) into a buffer of the engine's own, attachments copied |
| `chain+meta` | both: the engine's own buffer, with the probe's values |
| `pulse` | as `meta`, but every 72 frames the values switch to a 4000 nit set (MaxCLL 4000, MaxFALL 1000) and back |
| `chain+pulse` | as `chain+meta`, switching the same way |

- `AETHER_HDR10_PROBE_META` sets the values, as `maxcll=345,maxfall=123,peak=777,min=0.005` (the default). They share no number with a real master, so an analyser shows whose metadata a television got, and a MaxCLL of 345 changes the television's tone mapping visibly (`Probes/HDR10PassThrough`). A value out of range turns the probe off with one `[HDR10Probe] ignored:` line.
- `meta` changes the attachments of VideoToolbox's buffer in place. Attachments are not pixels, so reference frames decode the same, but it is a probe, not the output-metadata policy above.
- The chain runs on OS 26 and later on a device. Elsewhere, and on a frame the chain cannot take, both chain modes deliver the frame unchanged, without the probe's values.
- The pulse modes need no instrument. The pixels stay the same and only the metadata changes, so a television that reads it tone-maps the bright parts brighter and dimmer every 3 s at 23.976 fps. The first four switches are logged.
- The renderer keeps one format description while the frames look the same. Its cache key includes the frame's mastering display and content light level bytes, so a metadata change at the same size and colour gets a new description (`FormatDescriptionFollowsHDR10MetadataTests`).
- The log lines start with `[HDR10Probe]`: the first frame before and after, the format description built from the output, and the GPU time over each 48-frame window (the first ten). Three chain failures in a row turn the probe off for the session.

The device harness that plays every mode on an Apple TV is [`Probes/HDR10PassThrough`](../Probes/HDR10PassThrough/README.md).

The 2:3 pulldown retimer is not an optional stage. It is part of the native route's frame grid, see [2:3 pulldown timing on 24p film](architecture-native.md#23-pulldown-timing-on-24p-film).

## Audio on the software host

One table, kept with the native side, shows how each audio route sits on this host next to the native one: stream copy of E-AC-3 JOC, PCM decode, the object-audio render through `SoftwareAPACProducer`, and how `SoftwareAtmosRoute` picks per track. See [architecture-native.md, Audio routes and object audio](architecture-native.md#audio-routes-and-object-audio).

The channel layout and timestamp rules of the PCM decode are under [Audio channel layout and timestamps](#audio-channel-layout-and-timestamps).

## Audio tap

The audio tap gives the host app a copy of the audio that is playing. `installAudioTap()` (#95) returns an `AsyncStream<AudioTapBuffer>` of decoded playback audio:

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

`AudioTapReaderSelection` picks the reader per session. `audioTapHasDeliverySource` tells the host app whether the current session can deliver at all, so a missing source fails loudly.

**Software path downmix.** The decoder emits the source channel layout up to 7.1 without downmixing. The tap's sink mixes it down to mono:

- The sink takes its input format from the sample buffer's own channel layout. The channel-count-only `AVAudioFormat` initializer returns nil for every count above 2.
- It checks once per format that the converter really mixes down. Any discrete layout converts to digital silence without an error, so those are folded to mono inside the tap instead (#400).
- The converter runs with `downmix` on. Without it, AVAudioConverter maps by channel label instead of mixing: a stereo track arrives as its left channel, 2.1 as silence, and 4.0 to 7.1 as the centre alone (#908).

**Dialogue mode.** A `.dialogue` install (`installAudioTap(channels:)`) takes the front-centre channel alone instead of the downmix.

- The native and remote-HLS decoders set a one-row swresample matrix with the centre at unity.
- The software sink copies that channel out before the converter.
- Without a centre channel it falls back to the downmix. Each buffer's `channels` says which one it carries.

### Lifecycle

- One tap per engine. Installing again replaces the previous stream.
- `load()` and `stop()` finish the stream. Opt-in is per load. With no session, or a video-only source, the stream finishes immediately.
- The audio-only pipeline has no tap reader (`AudioTapReaderSelection` maps every backend but native and software to none). There too the stream finishes at once, and `audioTapHasDeliverySource` is false.
- A session-preserving reload finishes it too (audio / subtitle / disc-title switch, `reloadAtCurrentPosition`).
- Every delivery path is bound to the session it was installed on, and each install gets a fresh `AudioTapMonotonicFilter`. So a host app re-installs when the stream ends, and the new session starts on a clean timeline. It is not stitched across a reload that resumes slightly behind the old position (#356).

### Release window and memory

Both readers decode whole segments but release the decoded buffers along the playhead:

- A buffer goes out once it starts before playhead + lead (10 s).
- The head of the segment an anchor lands in is dropped if it already ended behind the playhead.
- So the stream is handed at most tolerance + lead (12 s), however long a segment runs.

That bounds the release window, not memory. The decoded rest of the current segment is held on top of it, so the held tail grows with the segment length. For example, a reader parked at 95 s on 15 s segments has released 12.1 s and still holds 14.9 s. Whatever the consumer keeps is its own.

A backward seek is detected from the playhead's own movement, never from how far the decode runs ahead of it (#864).

**Delivery and overflow.** Delivery is best-effort, and lossy only for a consumer that falls behind:

- The stream queues 256 buffers (`bufferingOldest`, about twice the release window at the 100 ms chunk floor).
- A buffer that arrives while the queue is full is dropped, and the first buffer taken after that carries `discontinuity`. A host app never reads contiguous PCM across an overflow.
- There is no non-evicting mode, because a stalled consumer would turn it into unbounded memory.

Live sources are best-effort.

Each path's tap reader belongs to that path (native, remote HLS, software). The tap is documented on this page because its sink and downmix rules are shared.

## Live sources on the software host

The native stream-copy path's live recovery (reconnect overlap, the replay boundary, playlist renewal) is in [architecture-native.md, Live sources](architecture-native.md#live-sources). The software host reuses the same replay guard and adds the rules below.

### Software live replay admission and recovery

After a reconnect, a live source can send packets again that the engine already has (a replay). The replay guard catches them. `LiveReplayPacketReader` runs the same `LivePacketReplayGuard` before recording, clock-discontinuity folding and the ring append. Both the DVR reader and the live combined loop use it.

- The guard holds suspect packets in quarantine until it knows whether they are new. Quarantine is bounded to 96 MiB and 10,000 packets. EOF, a read failure, cancellation and explicit positioning release the packets it owns.
- A verified partial replay is never forwarded as fresh media.
- An interrupted source surfaces as `liveSourceUnavailable`. Retry timing is left to the app, and transport loss is not treated as a codec incompatibility.

**Settling tail.** After paired verification, exact matching packets that the demuxer releases late stay suppressed until each track has advanced past the backward-discontinuity threshold. This tail never discards different compressed bytes just because their timestamps repeat.

**DVR cursor recovery.** During a DVR cursor recovery, acquisition waits before appending another packet, so it cannot evict the target while decoders and clocks are being repositioned. Memory and disk retention caps stay in force.

### Software Live without DVR

Ordinary live software playback with audio uses `DirectLiveAudioReadAhead` on the existing Demuxer connection.

**How it works.**

- A forward-only memory FIFO lets audio move ahead of a full video renderer.
- Bounded parking of compressed video, plus short consumer waits, keep already-read video ready to run when source I/O waits.
- The timed waits apply only while video is parked. Otherwise the consumer sleeps until source data, EOF, a failure or cancellation wakes it.
- Video decoding yields between packets, so it cannot drain a whole parked batch before available audio gets a turn.
- The live clock never takes on VOD pause/rebuffer behaviour. The audio lead target is a ceiling, not a prefill required before start.

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
- For both live and VOD, entering background audio-only mode retires parked video before evaluating the read gate (including a queue that was already full), and uses audio-renderer backpressure.

## Software VOD compressed packet cache

**What it is.** Seekable software VOD that is read through one of the engine's byte readers gets a compressed packet cache: a producer reads packets ahead of playback and stores them, and the decode consumer, paced by the renderer, takes them out. The store is a session-owned FIFO (also called the spool) of lossless packet envelopes.

**What a record holds.** Payload, PTS/DTS, packet duration, position, flags, stream index, time base and every side-data entry. Neither decoded pictures nor source URLs are kept in metadata.

**What is not cached.** A source libavformat opens itself (a local path) stays on the direct loop. The spool exists to avoid a second trip to a source, and re-reading a local file is a page-cache hit.

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

The host uses the existing `forwardBufferSegments` clamp and the native session retention and volume-safety policy.

- **The forward-second limit is measured on the reservoir**: the packets from the one the consumer last took to the newest one stored. That is what the producer is building, and two timestamps always describe it.
- The coverage frontier (below) answers a stricter question. It reports nothing once a hole or a single late presentation timestamp invalidates it, so it cannot be the only thing enforcing the limit.
- Byte and forward-time thresholds stop prefetch, with bounded slack for protected chunks and a single record.
- Old consumed chunks can be reclaimed exactly at the budget boundary, so refilling cannot deadlock.

### Coverage frontier

The cache frontier is how far ahead of the playhead the cache provably holds playable media. It is the intersection of the selected audio and video presentation coverage that contains the playhead.

- Unknown intervals stay unknown. Byte counts are never turned into guessed seconds.
- H.264 and HEVC use a bounded presentation reorder queue and confirmed successor timestamps. Why: a VFR packet's decode duration can be shorter than the picture's real display time, and a container that rounds durations down (41 ms against 41/42 ms deltas at 23.976 fps) would otherwise split the coverage at every frame (#613).
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
- Consumer generations and source epochs are separate counters. A cached seek must not discard a producer packet in flight, and a superseded consumer must not steal the first packet of a new source epoch.
- Admission applies equally to packet, EOF, error and delayed end-of-media callbacks.
- At EOF the VOD consumer parks until a new seek or stop.

### What hosts see

This changes engine cache semantics, not host app UI.

- Software `bufferedPosition` and `LiveTelemetry.cachedBytes` describe compressed coverage and residency.
- `forwardBufferSeconds` stays the native player's loaded-range metric.
- `displayCushionSeconds` still describes the small decoded queue.
- Native HLS `residentRanges` and live DVR are not repurposed.

### Producer thread priority

The producer runs on its own thread rather than a dispatch queue. A queue's QoS is fixed at creation, and this producer's urgency changes inside one long-running loop.

- It starts latency-critical.
- It drops to the efficiency class once the reserve reaches half the forward window.
- It goes back to latency-critical at a quarter of the window, the moment a consumer parks in a read, or whenever the reserve cannot be expressed in seconds at all (the state of both a cold start and a seek landing).
- The two thresholds differ so a source sitting on one threshold does not switch on every packet.

**Why not stay demoted.** A permanently demoted producer is a priority inversion the scheduler cannot see: the consumer waits on an `NSCondition`, and a condition donates no priority to the thread it waits for.

- It costs throughput, not only fairness, even with idle cores. The efficiency class throttles the spool writes the producer makes for every packet, and that needs no CPU contention.
- The adaptive choice keeps almost all of the efficiency-class CPU time a permanently demoted producer would have, at identical total CPU.

The benchmark behind both statements: [measurements.md, Packet cache producer QoS](measurements.md#packet-cache-producer-qos).

Consumer starvation is reported as its own rate-limited line, so a source that cannot keep up is visible directly instead of guessed from a stalled clock.

### Tests

The CI packet-cache step runs the standalone regressions for coverage, VFR successors, the disk FIFO, read-ahead concurrency, host admission and the AVPacket envelope. They use generated numeric data and temporary records, not private video fixtures.
