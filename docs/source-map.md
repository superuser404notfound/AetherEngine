# Source map

Which file owns what, folder by folder. Paths are relative to `Sources/AetherEngine/` unless noted. Files whose job needs more than one line have a short note under their folder's table. For how these pieces fit together, start with [architecture.md](architecture.md). `Scripts/check-source-map.py` fails CI when a Swift file under `Sources/` is not named on this page, so a new file gets its one-line row in the same commit.

## Top level

| File | What it does |
| --- | --- |
| `AetherEngine.swift` | Engine core: stored state, load dispatch, transport, stop/seek, track selection. |
| `AetherEngine+Probe.swift` | Static probes: `probe(url:)` / `probe(source:)`, shared HDR10+ / Atmos detail, `swDecodeProbe`, format, frame-rate and codec-label detection. |
| `ProbeControl.swift` | Opt-in input / packet / deadline accounting for a whole probe, and caller cancellation. Native callbacks keep their control until synchronous work returns. |
| `AetherEngine+Loading.swift` | Per-backend loaders (remote HLS, native, software, audio, audio-native) and reload. |
| `AetherEngine+OptionalComponents.swift` | `AetherEngine.OptionalComponent`: which trait-gated components (TrueHD object audio, DTS:X object audio, dual-layer DV, DV still reshaping, DV FEL curves) this build carries. |
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
| `AetherEngine+Version.swift` | `AetherEngine.version`: the release this source descends from, rewritten in each release prep commit. |
| `AetherEngine+ReloadWithOptions.swift` | `reloadAtCurrentPosition(applying:)` (AE#460): a session-preserving reload that corrects a `LoadOption`, its outcome and `SessionReloadRefusal`. |
| `AetherEngine+RequestHeaders.swift` | `updateRequestHeaders(_:)` (AE#792): swaps a live session's request headers (a rotated bearer token) without a rebuild. |
| `AetherEngine+SoftwarePathEscalation.swift` | AE#561: the rung under every native recovery. Moves a session AVPlayer refuses on its merits onto the software host. |
| `AetherEngine+AudioDelay.swift` | `setAudioDelay(_:)` / `audioDelaySeconds` (AE#464): the viewer's lip-sync nudge as a live setting, placed per route by `AudioDelayPolicy`. |
| `AetherEngine+AudioMenu.swift` | AE#1049: names every audio track for the master's audio group and answers a pick in AVKit's audio menu with `selectAudioTrack`. |
| `AetherEngine+AudibleReadback.swift` | Logs once per load what AVFoundation resolved from the audio the engine served (AE#458). Read-only: it never selects an option. |
| `AetherEngine+ChannelCountChange.swift` | F4: follows a mid-play change of the route's output channel count and rewrites the renderer paths' channel preference. |
| `AetherEngine+RouteRemoval.swift` | F3: pauses a renderer path when its audio route goes away (headphones unplugged), as AVPlayer does on its own. |
| `AetherEngine+InterruptionGuard.swift` | F5: keeps a transport `play()` during an audio-session interruption from restarting a renderer path's clock. |
| `AetherEngine+LiveAudioDrop.swift` | AE#641: a live channel whose audio the bridge builds but cannot decode plays video-only instead of stalling. |
| `AetherEngine+RendererClockTestHooks.swift` | DEBUG-only hooks for the aetherctl `--host-calls stallclock` drill (AE#549): a master clock stopped by something other than the host. |
| `AetherEngine+HeldPicture.swift` | Holds the current picture on a `HeldStillSurface` across an in-place item swap (audio-track switch), with a timeout if the next item never shows a frame. |
| `AetherEngine+CompositorPreview.swift` | `showScrubPreview(atSeconds:in:)` and `ScrubPreviewPlacement`: compositor-drawn scrub previews for DV Profile 5 / AV1 10.0. |
| `AetherEngine+DualLayerOutputRoute.swift` | Session lifecycle of `DualLayerOutputRoute` (`LoadOptions.dualLayerRoute == .avPlayerOutput`): prepare, start, forward-buffer cap. |
| `AetherEngine+EnhancementLayerProbe.swift` | `probeDolbyVisionEnhancementLayer` and `DolbyVisionEnhancementLayer`: FEL or MEL from a Profile 7 source's first RPU. |
| `AetherEngine+Prewarm.swift` | `prewarmDualLayerDolbyVision()` (compiles the FEL composer's shaders ahead of time) and `prewarm(url:...)`, the source warm (#551). |
| `AetherEngine+Upscale.swift` | #846: the load's side of the upscale stage. Reads probe, display and device once per load; publishes the stage's status. |
| `AetherEngine+Recording.swift` | `startRecording(to:)` / stop: records the playing live stream from the connection the session already holds (AE#560). |
| `PlaybackErrorInfo.swift` | `PlaybackErrorKind` (stable string tokens, #376) and `PlaybackErrorInfo` behind a published `PlaybackState.error`. |
| `SessionCacheStatus.swift` | `SessionCacheStatus` and its enums: which route owns buffering for the session, and the session cache's capability, cleanup and failure reasons. |
| `SoftwarePacketCacheStorage.swift` | `SoftwarePacketCacheStorage`: disk or memory store for the software VOD packet cache. |
| `SourceOpenPolicy.swift` | `SourceOpenPolicy`: the HTTP VOD startup budgets (initial data wait, whole fallback recovery). |
| `SharedOutputCoordinator.swift` | The process-wide outputs (audio session, channel preference, display criteria) every engine shares, and who still uses them (Sodalite#175). |
| `SharedOutputRole.swift` | `SharedOutputRole`: `.primary` or `.secondary` (a multiview tile), which shared outputs a load may drive. |
| `ClockHoldEvent.swift` | `ClockHoldEvent` / `ClockHoldRelease`: the software path's clock hold after a start, seek or resume (#800), so a host does not read it as a stall. |
| `BlockingWork.swift` | `BlockingWork` and `BlockingExecutor`: where engine work that blocks its thread runs, off the cooperative pool. See [Blocking work and the cooperative pool](architecture.md#blocking-work-and-the-cooperative-pool). |
| `LanguageTagMatching.swift` | `LanguageTag` parsing and the audio / subtitle preference match, script mismatches included (#590). |
| `MediaDurationCeiling.swift` | One week: the longest program the engine parses, plans or serves (audit NET-101, HLS-102). |
| `VideoScan.swift` | `VideoScan`, `VideoFieldOrder`, `VideoDeinterlace` (AE#983): how the source picture is scanned and deinterlaced. |
| `VideoStreamFormat.swift` | `VideoStreamFormat` / `DecodedVideoFormat` (AE#658): a picture's format in FFmpeg's vocabulary plus display labels, for a stats panel. |

Notes:

- **`AetherEngine+Subtitles.swift`.** Five mechanisms live here:
  - **Packet tap and drainer.** Every embedded stream is tapped off the session demuxer into `SubtitlePacketStore`. A playhead-paced drainer decodes the selected stream (text and bitmap, VOD and live) into the overlay, and rides producer seeks and restarts by construction. It replaces the side-demuxer reader and its recovery code (#112).
  - **Cue apply / prune and `closeOpenEndedCues`**, which takes a placeholder end from the next stored packet, or retires the cue at the reconstruction window when the store has none. Also the external track registry and unified selection routing (#88).
  - **VOD forward prefetcher.** It extends store coverage past the producer park to the 60 s drain lead, for host advance sync offsets (#151), plus a margin so the harvest leads the decode and the set at the window's edge can take its authored end from the store (#362).
  - **Side readers** yield the source link to the video path while it fetches or seeks (#240, `SideReaderLinkPolicy`).
  - **Resolution state.** The drain tick states how far display-state determination has advanced on the absolute source axis, fenced by load and seek generation, so a host or conformance harness can tell "determined, and empty" from "not read yet" (#250, `AetherEngine+SubtitleResolution.swift`).
- **`AetherEngine+SubtitleDelivery.swift`.** One line per change of what a drain tick did with the packets it found (`outcome=` noDecoder / empty / undecodable / held / duplicate / trimOnly / published), plus the counts behind it. It complements #250, which states how far determination reached: the drain cursor advances over packets that decode to nothing, so resolution can keep up with every seek landing while the overlay never changes. The two lines together tell those cases apart.
- **`AetherEngine+SubtitleResolution.swift`.** One generation-fenced line stating the absolute source-time span over which display state has been decoded. Emitted at post-seek reconstruction, every 30 s, at prefetcher EOF, on any change of frontier source, and at the tick where determination first reaches the playhead (`reason=coverage`, #318). `retainedFrom=` also states the floor of the run retained across seeks, so "empty because nothing was ever authored before this point" is provable from one post-seek line (#276).
- **`PresentationAxisMap.swift`.** The history of producer shifts as a piecewise-constant map, plus an off-main mirror. Written by the shift-changed / rebased handlers; read by the clock fold, the live thumbnail path and hosts.
- **`AetherEngine+LiveSubtitleRenditions.swift`.** Renditions get synthetic ids from 300000. Once one is selected it is fetched as WebVTT segments onto the host-overlay surface. Cues are placed by the playlist geometry the renditions share (`EXT-X-PROGRAM-DATE-TIME`), anchored at the playhead rather than at the head of a two-hour DVR playlist, and re-anchored when a producer seam moves the source axis.
- **`StartupProgress.swift`.** Each value is recorded by the code that finishes the work it names, never by a timer, so a determinate loading bar holds through a slow stretch and jumps through a skipped one. A path that skips work is credited by the checkpoint it does reach, which is why the ladder is one ordered axis rather than a per-path set.

## `Audio/`

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
| `AACAudioSpecificConfig.swift` | Reads the `channelConfiguration` of an AAC AudioSpecificConfig and decides when CoreMedia refuses the record because its layout sits in a PCE (AE#1047). |
| `AtmosDecoderPrimer.swift` | Registers the system's Atmos decoders in the process once (by creating an AVPlayer). The renderer needs this before it decodes compressed E-AC-3 as Atmos. |
| `AudioDelayPolicy.swift` | AE#464: where a host's audio-delay nudge lands on each video route. |
| `AudioRatePolicy.swift` | Pitch handling for host-driven rate changes on both transport surfaces (#434). |
| `AudioRouteDescription.swift` | The audio route as one log fragment, shared by every host so native and software logs describe it in the same words. |
| `AudioTranscodingBridge.swift` | Native path: the protocol the segment producer drives a bridge through. `AudioBridge` and `SpatialAudioBridge` implement it. |
| `DTSXConfirmation.swift` | #744 follow-up: sets `TrackInfo.isDTSX` from the DTS:X decoder's verdict, kept beyond the session that produced it. |
| `FLACStreamInfo.swift` | Reads the `STREAMINFO` blocksize fields CoreMedia keys FLAC on, and decides when CoreMedia would refuse or mistime the track (AE#764). |
| `RendererClockResume.swift` | AE#549: what a renderer path's `play()` does with a clock the system stopped rather than the host. |
| `RendererTimeline.swift` | AE#395: the renderer axis (source time minus `origin`) the renderers and their synchronizer run on. |
| `ResamplerInputParameters.swift` | The input a `SwrContext` was built for, so a context is rebuilt when the frames feeding it change. |
| `SoftwareEAC3AtmosDecoder.swift` | Software path on tvOS: decodes E-AC-3 JOC through the system Atmos decoder into the speaker bed and hands it to the renderer as PCM. |

### `Audio/Shaping/`

| File | What it does |
| --- | --- |
| `AudioShaping.swift` | `AudioShaping` (channel cap, dialogue lift, compressor, loudness target, LFE level in the fold) and `AudioShapingState`: the host's request and the published answer (AE#923). |
| `AudioShapingMatrix.swift` | The cap, the centre lift and the LFE level as one libswresample remix matrix. |
| `AudioShapingGraph.swift` | The libavfilter graph after the remix: dialoguenhance + pan on stereo, acompressor, alimiter, aformat. Runs on its own sample counter so its latency never reaches the timeline. |
| `LoudnessNormalizer.swift` | The loudness target (AE#1036): BS.1770 integrated loudness over what has played, and the bounded, latency-free gain toward the target, applied in front of the graph. |

### `Audio/Spatial/`

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
| `SpatialSpeakerLayout.swift` | `SpatialSpeakerLayout` / `SpatialSpeaker`: the public speaker beds object audio is rendered into. |
| `ObjectAudioRendering.swift` | `ObjectAudioRendering`: the public choice of how TrueHD Atmos and DTS:X are delivered (decode, render, layout). |
| `ObjectAudioActivity.swift` | `ObjectAudioActivity`: bed, declared, playing and overhead object counts, published as `LiveTelemetry.objectAudio`. |
| `ObjectAudioDecoding.swift` | The protocol both object decoders implement, and the decoded block, bed and bed-fold values they return. |
| `ObjectMetadataHold.swift` | Holds decoded blocks between a reset and the first object metadata, so a seek does not place every object nowhere. |
| `TrueHDMajorSync.swift` | Reads Atmos from a TrueHD major sync in the packets, the same test mlpdec applies, for tracks the probe never decoded. |
| `PeakLimiter.swift` | Keeps the rendered bed under full scale before the APAC encoder, which does not clip (#731). |
| `BedLevelMeter.swift` | Per-channel bed levels for the session log and the object counts behind `ObjectAudioActivity`. |
| `APACEncoder.swift` | Apple Positional Audio Codec encoder over `AVAudioConverter`: planar float bed in, packets for the fMP4 muxer out. |
| `APACEncodePipeline.swift` | Runs the `APACEncoder` on its own serial queue so the next chunk decodes and renders while the previous one encodes. |
| `APACConverterInput.swift` | One read-only borrow of the encoder's PCM storage for a single `convert` call. |
| `APACSampleEntry.swift` | The `apac` sample entry and the init-segment rewrite that installs it in place of the stand-in ALAC entry movenc writes. |
| `AtmosOutputActivator.swift` | Keeps a tvOS HDMI route in Dolby Atmos while a rendered bed or software-host E-AC-3 JOC plays. |

### `Audio/Tap/`

| File | What it does |
| --- | --- |
| `AudioTapController.swift` | Lifecycle owner for one tap: owns the `AsyncStream` continuation and (native path) the `LoopbackAudioReader`. One per engine; installing again replaces it (#95). |
| `AudioTapDecoder.swift` | FFmpeg decode of tap packets into mono Float32 48 kHz `AVAudioPCMBuffer`s (lazy resampler, own lock discipline). |
| `AudioTapPCMConverter.swift` | Software path: `AVAudioConverter` sink mirroring `AudioDecoder` PCM into the tap's mono 48 kHz format. Carries the source channel layout and checks the mixdown itself (#400). |
| `AudioTapTypes.swift` | `AudioTapBuffer` value type (single-consumer `@unchecked Sendable`) and the pure loopback pacing decision. |
| `AudioTapHLSVariantResolver.swift` | Remote-HLS tap: finds the active audio rendition / muxed variant from the master playlist (#95). |
| `AudioTapHLSFetcher.swift` | Remote-HLS tap: segment fetch and AES-128 clear-key decrypt for self-contained TS / fMP4 segments (#95). |
| `AudioTapHLSReader.swift` | Remote-HLS tap worker: follows the playhead and decodes fetched segments (VOD and live) (#95). |
| `AudioTapReaderSelection.swift` | Pure per-session reader choice (loopback, software sink, remote HLS, or none) behind `audioTapHasDeliverySource` (#95). |
| `LoopbackAudioReader.swift` | Native-path tap worker: pulls fMP4 segments from `SegmentCache` near the playhead and decodes their audio out-of-band on a utility thread (cannot stall playback). |
| `AudioTapMonotonicGate.swift` | Keeps `sourceTime` strictly increasing and non-overlapping across consecutive tap buffers. SpeechAnalyzer ends its input loop on the first overlap, and decoder priming at segment seams produces small backward steps (#95 follow-up). |

## `Decoder/`

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
| `HardwareVideoDecoder.swift` | Software path: VideoToolbox hardware decoder (HEVC, VP9, AV1 Dolby Vision) for sources routed away from AVPlayer. |
| `DualLayerVideoDecoder.swift` | Software path: Dolby Vision Profile 7 FEL (`DualLayerDolbyVision` trait). See note. |
| `SoftwareVideoDecoder.swift` | Software path: libavcodec/dav1d → `CVPixelBuffer` (NV12 / P010), HDR10+ side data, HDR10 static metadata. 10-bit AV1 reaches P010 through `GPUFrameConverter`. |
| `GPUFrameConverter.swift` | Software path: converts a 10-bit AV1 frame to P010 in one Metal pass and applies its film grain there (dav1d exports the grain instead of applying it). `sws_scale` stays the fallback. |
| `AV1FilmGrain.swift` | The per-frame grain tables (templates, scaling functions, block offsets), computed on the CPU the way dav1d computes them. |
| `AV1FilmGrainShaderSource.swift` | The Metal kernels: dav1d's per-pixel grain and the P010 write. |
| `AV1GaussianSequence.swift` | AV1's Gaussian_Sequence (specification 7.18.3.3). |
| `SidecarTextFetch.swift` | One plain whole-body GET for a text sidecar over HTTP, decoded from a temporary file, instead of the playback reader's ranged open and its 15 s + 25 s give-up (AE#984). |
| `SubtitleDecoder.swift` | One-shot decode of a sidecar URL. Decodes several streams of one container in a single pass (#266); a bitmap stream is read into packets instead (#921). |
| `VideoDecoderTypes.swift` | `DecodedFrameHandler` typealias and `VideoDecoderError`. |
| `DeinterlaceHardwareWarmup.swift` | On-demand, process-wide prewarm of the deinterlace filter's hardware pipeline. See note. |
| `PixelAspectPolicy.swift` | Whether a declared sample aspect ratio should be believed. See note. |
| `VideoDecoderOpener.swift` | Opens the preferred video decoder and falls back atomically before the demux loop captures its pipeline. |
| `VideoToolboxVideoFormat.swift` | Builds the Core Media format description `HardwareVideoDecoder` needs, synthesizing VP9's `vpcC` from probed parameters. |
| `VideoToolboxOutputMetadataNormalizer.swift` | Adds codec-declared colour metadata to VideoToolbox output that lacks it, through a pixel-transfer pool rather than mutating the frame. |
| `ColorDescription.swift` | A stream's colour description merged from bitstream (VUI) and container (AE#499). |
| `HDR10StaticMetadataSEI.swift` | AE#957: the stream's HDR10 static metadata (container side data, `hvcC` / `av1C`, key-frame SEI or AV1 metadata OBUs, a decoded frame's side data) in Core Video's byte layout. |
| `HDR10StaticMetadata.swift` | AE#957: builds and describes the two HDR10 attachments (mastering display, content light level) in Core Video's byte layout. |
| `AlternativeTransferSEI.swift` | AE#839: reads the `alternative_transfer_characteristics` SEI that names HLG behind a backward-compatible VUI. |
| `AV1DolbyVisionRPU.swift` | The Dolby Vision RPU from an AV1 T.35 metadata OBU (Profile 10), attached to decoded frames for the system's DV display management. |
| `DualLayerRouteDecision.swift` | Whether a Profile 7 load takes the dual-layer route or stays native, and why. Pure, logged once per source. |
| `UpscalingFrameHandler.swift` | Runs the upscale stage (#846) on every decoded frame; a nil from the stage delivers the original. |

Notes:

- **`VideoRoutingPolicy.swift`.** AV1 is gated on hardware support. VP9 / VP8 / MPEG-4 / MPEG-2 / VC-1 always go software. Interlaced H.264 goes software so bwdif can deinterlace (#107; checked against decoded frames on VOD, #232). A second-stage gate routes H.264 High 4:2:2 / 4:4:4 / 10 and HEVC Rext to software where VideoToolbox has no hardware decoder (#2).
- **`DualLayerVideoDecoder.swift`.** Two `HardwareVideoDecoder`s (a base layer, typically 4K, and an enhancement layer, typically 1080p), paired by HEVC picture order with the packet's RPU, composed on Metal by `DoviFelComposer`, and delivered in decode order with the Profile 8.1 RPU attached per frame. See [dolby-vision-fel.md](dolby-vision-fel.md).
- **`DeinterlaceHardwareWarmup.swift`.** Only potentially interlaced `.auto` loads start and await it. Progressive sources and forced-software deinterlace skip it. Same-title reloads keep even a decoded progressive verdict. The background selection snapshot keeps that decision for a custom-reader reopen, while URL reloads probe again. Actual disc-title changes re-evaluate the reopened metadata. A source declared progressive that later supplies interlaced frames still deinterlaces on demand, paying the cold graph build at that first frame.
- **`PixelAspectPolicy.swift`.** Two gates. A ratio-magnitude gate (#177, live TS carrying 1088:1), which admits precise or unreduced ratios such as 759:712. A display-aspect gate judged against the frame the SAR applies to, since 2:1 is right on 960x1080 and wrong on 1920x1080 (#290).

## `Demuxer/`

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
| `ChunkedByteWindow.swift` | AE#619: the persistent reader's byte window as the chunks the connection delivered, so dropping the head copies nothing. |
| `ConnStartLogGate.swift` | Decides which `conn start` lines a reader writes, so a fast forward walk does not flood the host log. |
| `HeldSourceConnection.swift` | #377: the read path behind `LoadOptions.heldSourceConnection`, one long-lived connection instead of a range per refill. |
| `OriginRequestBudget.swift` | #377: one request budget per origin shared by every pool the reader fetches on, plus the transport log. |
| `RequestHeaderStore.swift` | AE#792: a session's request headers as one value every reader reads at request time, so a rotated token reaches them all. |
| `LiveReopenAlignment.swift` | Where a fresh `AVIOContext` starts reading when a retained live reader is rebuilt (AE#460 follow-up). |
| `SourceSizeProbeScope.swift` | One file-size discovery with its delayed workers and requests, cancelled and joined as a unit under one deadline. |
| `SourcePrewarmFetcher.swift` | #551: fetches a source's head (and tail where useful) before it plays; `SourcePrewarmReport` says what a warm did. |
| `SourcePrewarmPlan.swift` | #551: which tail a warm still has to fetch once its head is in, only for layouts that will look for it. |
| `SourcePrewarmStore.swift` | #551: holds prewarmed bytes until a `load()` of the same URL takes them. |
| `VFWDecodeOrderPTSRepair.swift` | #407: rebuilds presentation timestamps for a Matroska `V_MS/VFW/FOURCC` track (VC-1 remuxes), which carries none. |

Notes:

- **`AVIOReader.swift` modes.** (1) A persistent forward-streaming connection with reconnect-on-drop (playback, including live). (2) Discrete Range chunks (still extraction). (3) A single sequential GET with backpressure (non-live sources without Content-Length). An optional read deadline bounds a degenerate Matroska Cues seek.
- **`AVIOReader.swift` cold start on a non-faststart MP4 (#281).** The open window is kept across the parse seek to the trailing moov, so the trip back to the first sample is a copy, not a third connection. One speculative 64 KB suffix range is issued alongside the open, rejected at the response header unless it is a well-formed 206. A read landing in that range waits for the fetch instead of connecting past it, bounded by the measured cost of one round trip to the origin, because the demuxer reaches the tail before a fetch issued at the same moment can land.
- **`AVIOReader.swift` refusals and redirects.**
  - A suffix-range denial is remembered per origin only from the origin's answer to the range form (a 200, a 416), never from a 403/404/429/5xx.
  - A source refused with an HTTP status fails the open with a typed error (`AVIOReaderError.httpStatus`) instead of handing FFmpeg the error page (#378).
  - A post-redirect target is pinned from its first 2xx and dropped again on an auth-expiry status, on a streak of unproductive reconnects, and after a bounded grace of rate-limited attempts (#307/#380).
  - A pin that has carried no bytes for a minute is dropped on its first refusal instead, because the lingering-slot 509 that grace exists for cannot happen with nothing of ours in flight (#392).
- **`Demuxer.swift` positioning.** Seek, bounded seek (deadline-capped), and a byte-estimate positioning fallback for containers without an index. The fallback is origin-corrected onto the file-relative time axis, uses a fixed early bias in seconds, verifies its landing with a packet-PTS probe with proportional correction, and latches a sticky per-demuxer timestamp-seek lockout once the mechanism proves broken (#112).
- **`Demuxer.swift` probe budgets.** A per-open `DemuxerOpenProfile` budgets `find_stream_info` (probesize / max_analyze_duration). The caller can override it on the main playback open with `LoadOptions.probesize` / `maxAnalyzeDuration`.
  - The native text readers' side demuxer sets `skipStreamInfo` to drop the `find_stream_info` pass entirely (codec_id / codec_type come from the container header / PMT at open); the reader runs a bounded `resolveStreamInfo()` on demand, only if its target stream's codec is really unresolved at open (#87).
  - The playback open parks known PGS tracks (whose width only a decoded composition segment can supply) and undecodable audio as ATTACHMENT for the duration of `find_stream_info`, so neither holds the pass to its byte ceiling (#466, #858).
- **`RedirectHeaderPolicy.swift`.** Applies to `AVIOReader`'s URLSession delegates and, through `EngineTLS`'s session-level delegate, to every other engine session (audit NET-108).
  - Range and non-credential extra headers survive cross-host redirects (header-dependent proxies, #8). Credential headers (Authorization, Cookie, Emby/Jellyfin tokens) are replayed only to a same-host target with no TLS downgrade, and removed otherwise, so presigned redirect targets neither 400 on conflicting auth nor see the media-server token (#126).
  - `CredentialScope` applies the same rule to every URI a playlist names: the relay, the #316 subtitle proxy, the audio tap and the live rendition fetch send the credentials only to the URL the host handed over, and allowing a fetch never grants them (audit NET-109).

## `Diagnostics/`

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
| `LogRedaction.swift` | Strips credentials (tokens in URL queries, auth headers) out of a line before `EngineLog` emits it. |
| `FFmpegRuntimeCheck.swift` | Witnesses which FFmpeg answers in this process, so a second FFmpeg in the host's link is caught. |
| `SourceNetworkDiagnostics.swift` | Public observer of real source requests, tagged with a playback and attempt id. No headers or bodies. |
| `PlayedMediaLedger.swift` | AE#514: media bytes keyed by presentation time, so bitrate is metered from what the playhead crossed, not what was transferred. |
| `VideoFrameProgress.swift` | Whether the video presentation is actually advancing, judged apart from a progressing audio or item clock. |
| `QoSClassName.swift` | One name for a QoS class, read back after setting it, for the self-retuning producers' logs (AE#286, AE#519). |
| `FelResidualMeasure.swift` | `DualLayerDolbyVision` trait: with `AETHER_FEL_MEASURE=N`, composes every Nth frame with and without the residual and logs the difference. |

Notes:

- **`LiveTelemetry.swift`.** Instant / average bitrate, buffer, network, dropped frames, observed FPS, A/V sync gap, plus subsystem byte counters. The software path reports its own read bytes, throughput, reader runway (`readerWindowAheadBytes`), decoded cushion (`displayCushionSeconds`) and dropped / late frames (#306). `forwardBufferSeconds` stays nil there, because a pump held back by the renderer has no seconds-deep reservoir to report.
- **`SubtitleDeliveryStatement.swift`.** States what a drain tick did with the packets it found, so "nothing appeared on screen" can be attributed from outside instead of guessed from a missing log line. `harvestHole` names the tick that decoded nothing on purpose, which would otherwise read as `empty` (#362). `landingWithheld=` counts the sets refused the landing because the ground between them and the playhead was never read (#416).

## `Disc/`

| File | What it does |
| --- | --- |
| `DiscReader.swift` | Disc detection and routing: ISO images (local, remote, custom reader) and BDMV / VIDEO_TS folders into the demux path. Lists titles and threads the selected one (DVD vs Blu-ray). |
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
| `DiscDirectory.swift` | `DiscDirectoryReader` / `HTTPDiscDirectoryReader`: a disc served as a `BDMV` or `VIDEO_TS` folder,, concatenated like an ISO. |
| `DiscSeekTable.swift` | Blu-ray CLPI EP-map parser and the seek table built from it. |
| `BluRayDolbyVisionLayers.swift` | A UHD Blu-ray's Dolby Vision as two transport PIDs (base 0x1011, enhancement 0x1015), paired per picture. |
| `SeparateDolbyVisionLayers.swift` | Detects a Profile 7 source whose layers are separate container streams (Blu-ray PIDs, or a Matroska / MP4 track each). |
| `DolbyVisionLayerJoin.swift` | Joins separately carried base and enhancement layers into the one-unit-per-picture shape the dual-layer route reads. |

## `Display/`

| File | What it does |
| --- | --- |
| `DisplayCriteriaController.swift` | AVDisplayManager content-rate / dynamic-range hints (native path). |
| `FrameRateSnap.swift` | Snaps to standard rates (23.976, 24, 25, 29.97, 30, 50, 59.94, 60). |
| `DisplayCriteriaOwner.swift` | `DisplayCriteriaOwner`: who writes `preferredDisplayCriteria` for a load (AE#842). |
| `DisplayPixelSize.swift` | The main display's native size in pixels, the box the upscale stage (#846) fits into. |

## `FrameExtractor/`

| File | What it does |
| --- | --- |
| `AetherEngine+FrameExtractor.swift` | `makeFrameExtractor()` convenience for the currently loaded URL. |
| `DolbyVisionStillConverter.swift` | `DolbyVisionStillReshaping` trait. Applies the RPU-carried DV colour transform to a DV P5 / P10.0 base-layer frame (IPT-PQ-C2, not YCbCr), so scrub stills lose the green and magenta cast (#103). |
| `FrameExtractor.swift` | Off-playback still extraction actor: serial decode queue, cancel-supersede, idle-close. |
| `FrameDecodeContext.swift` | Isolated FFmpeg demux + decode + sws_scale → `CGImage` (thumbnail / preview / snapshot). |
| `FrameCache.swift` | Bounded LRU: stores isolated per mode, thumbnails bucketed by second. |
| `FrameTypes.swift` | `FrameMode` (`.thumbnail` / `.preview` / `.snapshot`). |
| `HDRToneMapper.swift` | zscale + tonemap libavfilter graph: HDR (PQ / HLG, BT.2020) stills → SDR BT.709. |

## `IO/`

| File | What it does |
| --- | --- |
| `IOReader.swift` | Public custom byte-source protocol and `MediaSource` (the `load(source:)` input). |
| `DataIOReader.swift` | Ready-made in-memory `IOReader` over an immutable `Data` buffer. |
| `FileIOReader.swift` | Seekable `IOReader` over a local file via `FileHandle` (multi-GB ISO images). |
| `HTTPDiscIOReader.swift` | Seekable `IOReader` over a remote HTTP(S) disc image with adaptive read-ahead (the network counterpart to `FileIOReader`). |
| `ProgressiveRangeStream.swift` | `HTTPDiscIOReader`'s playback path: a bounded FIFO over ranges of up to 64 MiB whose bytes reach the demuxer as they arrive (#1007). Once it has run, a seek pays one base-size fetch and the continuation streams again. Each stream logs one summary line at close (rate while not held, ranges, worst time to first byte, holds, read waits). |
| `ProbeIOReader.swift` | Wraps a probe's readers (plain, HTTP, disc folder) so every read counts against its `ProbeControl` and can be cancelled. |
| `ProbeRangeGrowth.swift` | AE#927: range sizing for a controlled probe's seekable reads, doubling while reads continue. |

### `IO/DASH/`

On-demand MPEG-DASH (AE#859): one static Period, each representation a single `SegmentBase` file, laid out as one fragmented MP4 so nothing downstream knows it was DASH.

| File | What it does |
| --- | --- |
| `DASHManifest.swift` | MPD parser and representation selection; anything outside the supported profile is refused with a `DASHSourceError`. |
| `DASHSourceOpener.swift` | Turns an MPD URL into a `DASHVirtualMP4Reader`: fetches the manifest, init segments and segment indexes, no media. |
| `DASHVirtualMP4.swift` | The virtual layout: MP4 box helpers, init and `sidx` parsing, and the fragment patcher. |
| `DASHVirtualMP4Reader.swift` | Serves the layout as one seekable byte stream, each range read from its representation file through a block cache. |

### `IO/HLSIngest/`

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
| `BoundedPlaylistFetch.swift` | Reads a playlist body with its size cap enforced while it arrives (audit NET-10). |
| `PersistentHTTP1Transport.swift` | AE#732: the HLS VOD ingest's transport under `heldSourceConnection`, one persistent HTTP/1.1 keep-alive connection. |

## `Native/`

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
| `SoftwarePacketReadAhead.swift` | Software VOD: compressed packet prefetch decoupled from renderer pacing; cached seeks move only the consumer cursor. See [Software VOD compressed packet cache](architecture-software.md#software-vod-compressed-packet-cache). |
| `SoftwarePacketStore.swift` | The store protocol the read-ahead uses, implemented by the disk and memory FIFOs. |
| `SoftwarePacketDiskFIFO.swift` | Session-owned, disk-backed FIFO of compressed-packet records. |
| `SoftwarePacketMemoryFIFO.swift` | The same store in purgeable memory, used on tvOS. |
| `SoftwareStoredPacket.swift` | Lossless packet envelope (timestamps, flags, side data) for the read-ahead store. |
| `SoftwareStoredPacket+FFmpeg.swift` | Copies an `AVPacket` into a `SoftwareStoredPacket` and back, and tags decoded frames with the cache identity they came from. |
| `SoftwarePacketCoverage.swift` | Presentation-time coverage of compressed packets the caller still owns, in decode order. |
| `SoftwareVideoPacketCoverage.swift` | Video coverage qualified against the renderer's successor-PTS durations. |
| `SoftwareAudioPacketCoverage.swift` | Audio coverage from exact decoded sample geometry where the codec allows it. |
| `SoftwarePacketCacheTiming.swift` | A separate presentation axis for packets whose PTS the AVI MPEG-4 repair withholds, qualified against the decoder's own frames. |
| `SoftwareReadAdmission.swift` | Read generations: packets, EOF and errors of a superseded seek or stop are rejected. |
| `SoftwareEndOfMediaClock.swift` | AE#374: stops the software master clock at end of media so `currentTime` does not walk past `duration`. |
| `SoftwareLiveJoinPolicy.swift` | Where a software live session starts playing once the connect burst has landed, and the holdback behind the edge. |
| `DirectLiveAudioReadAhead.swift` | Software live without a DVR feeder: a forward-only read-ahead on the one existing source connection. |
| `SoftwareStillExtractor.swift` | #544: decodes one still from the software live path's packet window with a real `SoftwareVideoDecoder`. |
| `PausedFirstFrame.swift` | Sodalite#104: a pause before the first frame still decodes and shows that frame instead of black. |
| `SeekWindow.swift` | AE#491: the stretch between a seek's request and its completion, and what reads mean inside it. |
| `OneShotSlot.swift` | AE#595: a value built at most once on first use and never retried after a failure. |
| `AudibleSelectionReadback.swift` | AE#458: what AVFoundation resolved from the served audio, as one log line. |
| `RemoteHLSCueClock.swift` | AE#616: the offset between AVPlayer's item time and presented media time on the bypass, from the engine's own renditions. |
| `RemoteHLSCueClockObserver.swift` | AE#616: feeds `RemoteHLSCueClock` from a non-suppressing legible output on the bypass item. |
| `DualLayerOutputRoute.swift` | `DualLayerDolbyVision` trait: the second FEL route. Composes AVPlayer's decoded base layer with the tapped enhancement layer into a display layer on the item's clock. |

## `Network/`

| File | What it does |
| --- | --- |
| `HLSLocalServer.swift` | Native path: local HTTP server for playlist and segments (all interfaces for AirPlay, every path behind a per-session token, loopback URLs handed to the local player). See note. |
| `URLRequest+ContentSniffing.swift` | `URLRequest(engineURL:)`, the one way the engine builds an origin request. It turns off CFNetwork's content sniffing, which otherwise holds back a `text/plain` or untyped response, refusals included, until 512 body bytes or the end of the connection (AE#986). |
| `EngineTLS.swift` | Public host TLS trust policy (`serverTrustEvaluator`) for every engine session, plus the redirect-scrubbing session delegate. |
| `HLSOriginRelay.swift` | AE#495: fetches a remote HLS origin for AVPlayer through the local server, so the host's TLS policy applies. |
| `TransportSecurityFailure.swift` | AE#495: tells a refused TLS handshake apart from an unreadable source. |

Note on `HLSLocalServer.swift`: it writes the master, so it decides the audio rendition's attributes. `EXT-X-MEDIA:TYPE=AUDIO` carries `LANGUAGE` (AE#458) and `CHANNELS`. The segment provider answers `CHANNELS` (`"16/JOC"` for a stream-copied E-AC-3 JOC track, the served bed count otherwise), and it is omitted when the provider has no rendition to attribute. An untagged track has no rendition, unless it is a stream-copied JOC one, which gets one without `LANGUAGE` so it can carry `CHANNELS` (AE#726).

## `Recording/`

Live recording (AE#560): `AetherEngine+Recording.swift` starts it; these files copy the session's own packets to disk.

| File | What it does |
| --- | --- |
| `RecordingState.swift` | Public `RecordingState`, `RecordingProgress`, `RecordingEndReason`, `RecordingFailure`. |
| `LiveRecordingSink.swift` | The sink and host protocols, and the per-stream descriptor a recording copies from. |
| `LiveRecordingQueue.swift` | Bounded, non-blocking, byte-budgeted handoff from the demux thread to the writer. |
| `LiveRecordingWriter.swift` | Stream-copies packets into MPEG-TS, so a file cut short by a crash still plays. |

## `Renderer/`

| File | What it does |
| --- | --- |
| `SampleBufferRenderer.swift` | Software path: `AVSampleBufferDisplayLayer` + B-frame reorder, HDR10+ attachments. `flush(removingDisplayedImage:)` holds the last frame through a seek (#90). The decode thread reaches the layer only through its `sampleBufferRenderer`, taken once on the main actor (#351). |
| `SubtitleFrameCompositor.swift` | Draws active cues into decoded software-path frames while PiP is active, since the system PiP window shows only the sample-buffer layer. Playback wins: every failure path returns the original buffer untouched. |
| `PresentationFloor.swift` | The lowest presentation time still to come, fed to `presentationTimeExpectation` for frames handed over in decode order. |

## `Subtitles/`

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
| `ExternalSubtitlePreparationPolicy.swift` | Bounds for opt-in preparation of a downloaded text sidecar. |
| `PreparedExternalSubtitle.swift` | `prepareExternalSubtitle(...)`: decodes a sidecar ahead of selection into a single-use candidate. |
| `SubtitleDrainStopReason.swift` | #496: why the overlay drainer and forward prefetcher were torn down, for the log. |

Notes:

- **`Issue100PGSStaleArrival.swift`.** Catch-up bursts resolve through their successor's trim instead of flashing open-ended placeholder windows on the overlay (#100). The hold and the reconstruction candidate belong to one position, so a reset tick drops them before arming the next pass (#357; otherwise the first trim after a seek republishes pre-seek history as the active line). A cue behind the playhead can be the landing's active line only where the harvest reports having read the ground between the two (`groundIsRead`, #416).
- **`SubtitlePacketStore.swift`.** Written on the pump thread, read by the MainActor drainer, all state lock-guarded. `firstPTS(streamIndex:after:)` is where an open bitmap set reads its authored end, since a display set is closed by whatever packet follows it (#362). `hasReadSpan(from:through:)` says whether anyone read a stretch, which every answer based on the store's silence depends on (#416).
- **`SubtitleHarvestCoverage.swift`.** One span per run, anchored where a reader positioned and extended as it goes. A PGS set claims the landing when the store is empty between it and the playhead, but over ground nobody read that silence proves nothing, and the packets alone cannot tell the two apart (#416, the ledger #362 round 2 named and left unbuilt).
- **`SubtitleOverlayDrainer.swift`.** Reads packets from the store near the playhead into the existing apply path, so the stale-arrival gate, trim state machine and retention stay relative to the playhead.
  - `harvestGapCut` stops a tick where the store's harvest order breaks, not where its gaps are widest, so a hole a restarted pump has not filled yet is waited on instead of skipped forever (#362).
  - It also stops where the coverage ledger says nobody read the span between two entries, the forward re-anchor's hole that order cannot show (#941). Where the ledger has heard from a reader it decides alone, so a re-harvest over ground the prefetch already read is not a hole (#1021); order is the rule only on a store with no ledger.

## `Video/`

| File | What it does |
| --- | --- |
| `HLSVideoEngine.swift` | Native path: session orchestrator (start/stop, producer construction and restart, shift handling). |
| `KeyframeStillLadder.swift` | Native VOD: which keyframe the sparse scrub-still ladder reads next (one a minute, then every 30 s, nearest the playhead first) and whether the origin is idle enough to read it (nothing in flight or queued, no recent refusal, 30 s buffered). Lets `scrubPreviewFrame` answer beyond the resident window on a one-connection plan. |
| `HLSVideoEngine+AudioRoute.swift` | Native path: audio cascade of stream-copy, then `AudioBridge` (E-AC-3 above stereo by default, FLAC with `.lossless`, or the object-audio bed through `SpatialAudioBridge`), then video-only. |
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
| `NALUnitChain.swift` | Last-stage payload guard before the fMP4 mux: cuts a length-prefixed NAL chain at its last complete unit when it overruns a sample (AE#561), and removes incomplete one-byte HEVC headers while preserving valid payloads (#960). |
| `AudioLanguageMap.swift` | Native path: the ISO 639-2/T code an audio track is declared with in the master's `EXT-X-MEDIA:TYPE=AUDIO` rendition and written into its `mdhd` (AE#458). See note. |
| `FragmentSplitter.swift` | Native path: splits the mp4 muxer's avio output into `init.mp4` (ftyp+moov) and per-segment moof+mdat files. |
| `PacketRingBuffer.swift` | Live path: keyframe-indexed, disk-spooled packet ring behind the software DVR rewind. Append-only chunk files, a 24-byte index record per packet, eviction by time and by the session retention budget, evict-and-retry when the volume or quota is full. |
| `SessionDirectoryLiveness.swift` | The flock marker a session directory under `aether-segments/` holds while its owner lives, so the stale-session sweep spares a live `SegmentCache` or DVR ring (AE#451, SEG-105). |
| `SegmentCache.swift` | Native path: producer/consumer segment store with backpressure, scrub-aware eviction, and byte-budgeted VOD backward retention (back-seeks without restarts). |
| `VTCapabilityProbe.swift` | AV1 system-decode probe and per-format `canHardwareDecode` check for H.264 / HEVC profiles (Intel Macs, older chips, #2). Gates codec routing; VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 and interlaced H.264 always route software (see `VideoRoutingPolicy`). |
| `LiveCadencePolicy.swift` | Turns the observed arrival cadence into the two LL-HLS decisions (served TARGETDURATION, blocking-reload eligibility), re-evaluated on every manifest render instead of trusting a bursty origin's own number. |
| `PrefetchDiskBudget.swift` | Disk bound for an opt-in whole-source prefetch. The hard window is never evicted, so the budget only bounds what lives outside it (#207). |
| `RetentionClaims.swift` | Process-wide ledger of the running sessions' disk allowances. A new session is sized from the free space minus what the others may still write, so concurrent engines cannot each claim a quarter of the same space (#687). |
| `HLSVideoEngine+SpatialAudio.swift` | Native path: whether a source is rendered as object audio, into which bed, and building the spatial producer. |
| `SourceTimestampBounds.swift` | Audit SEG-1: implausible demuxed timestamps become `AV_NOPTS_VALUE` at the source so the tick math cannot overflow. |
| `EpochAxisTable.swift` | Per-segment-index record of what an epoch opening left behind, in both quantities a later reading asks for. |
| `H264ConfigurationTracker.swift` | Pump-local evidence that an AVC access unit no longer matches its sample description. |
| `H264MatroskaSlotPermutation.swift` | #511: Matroska H.264 timestamp-slot repair, and the `H264TimestampRepairSession` protocol both repairs share. |
| `H264PartialCompositionRepair.swift` | A mixed MP4 whose later IDR sequences lose their ctts: restores display ownership of the original timestamp slots. |
| `H264PartialCompositionRepairSession.swift` | The per-session state of that repair, zero-hold for healthy packets. |
| `VideoConfigRecord+InBand.swift` | Rebuilds an `hvcC` with empty arrays from in-band parameter sets for consumers that need them in the record. |
| `LivePacketReplayGuard.swift` | Removes packets a live origin resends after a reconnect, matched on timestamps and payload. |
| `LiveReplayPacketReader.swift` | Demux-thread admission through that guard, before clock folding, recording and DVR storage. |
| `LiveReadHead.swift` | AE#936: how far and how fast the cutter reads into the open live segment, for the fastZap grace. |
| `LiveDVRLimits.swift` | `LiveDVRLimits`: caller-selected DVR retention (window, bytes, free-space floor), and its policy. |
| `SoftwareDVRRetentionOptions.swift` | `SoftwareDVRRetentionOptions`: opt-in storage bounds for a software live spool. |
| `NoCutStallWatchdog.swift` | AE#406: the live no-cut stall decision, held off the read thread it judges. |
| `PumpRelaxationRateProbe.swift` | AE#850: whether the pump keeps up with real time at the relaxed QoS. |
| `RefusingSourceReviveBudget.swift` | #377: how long a session keeps trying a source that refuses it, as one number. |
| `StereoVideoSignal.swift` | `StereoPresentation` (`LoadOptions.stereoPresentation`) and how the native path signals frame-packed 3D in the served HLS. |
| `HDR10PlusDetectionProbe.swift` | `probe(url:detecting:)`: the opt-in HDR10+ / HDR Vivid pre-playback scan, its bounds and `ProbeDetail`. |
| `HDR10PlusMetadataScan.swift` | Decoder-free HDR10+ confirmation from T.35 SEI / OBU or Matroska side data, for playback and the probe. |
| `HDRVividMetadataScan.swift` | Decoder-free HDR Vivid (CUVA) confirmation for the detail probe (#699). |
| `DolbyVisionRecordAudit.swift` | AE#532: what a DV source's own RPU says about the profile its container record claims. |
| `DoviRpuGuard.swift` | CRC-checks every RPU before libdovi (built panic=abort) parses it. |
| `DoviDmDigest.swift` | `DualLayerDolbyVision` trait: a field-by-field reading of one RPU's display-management metadata, for comparing two. |
| `DoviDmPassthroughProbe.swift` | `DualLayerDolbyVision` trait: checks that composed frames keep the source RPU's display metadata (`aetherctl dmpass`). |
| `DoviFrameDump.swift` | `DualLayerDolbyVision` trait: one FEL frame composed with and without its residual (`aetherctl elframe`). |
| `DoviResidualSurvey.swift` | `DualLayerDolbyVision` trait: what a title's enhancement layer does to luma at sampled frames (`aetherctl elsurvey`). |
| `VideoPacketTap.swift` | Copies source video packets before the Profile 7 conversion strips the EL, with the time the served stream shows them. |
| `VideoPacketHistory.swift` | Bounded on-disk history of tapped packets, so the EL route can follow AVPlayer to any cached position. |
| `CompositorPreviewBuilder.swift` | Turns a resident segment into a video-only fMP4 a second AVPlayer shows, the only way DV P5 / 10.0 scrub previews get their colour. |
| `IFrameRendition.swift` | AE#682: the I-frame rendition the segment provider serves for AVKit's scrubber, and its format. |
| `IFrameRenditionEligibility.swift` | AE#682: whether a session serves the I-frame rendition, all or nothing. |
| `IFrameSideReader.swift` | AE#682: reads a plan segment's opening keyframe on a demuxer of its own. |
| `IFrameFragmentBuilder.swift` | AE#682: wraps one keyframe into one fMP4 fragment on the main rendition's timeline. |
| `IFrameJPEGBuilder.swift` | AE#682: one keyframe as a Motion JPEG fragment, for sources whose own keyframes AVKit will not show. |
| `IFramePayloadCache.swift` | AE#682: byte-capped on-disk cache of keyframe payloads read for the rendition. |
| `FrameUpscaler.swift` | The per-frame upscale stage (#846): optional VT super resolution, then MetalFX, with overrun fallback. |
| `UpscaleRouteDecision.swift` | Whether and how a load upscales: source geometry, the plan, and process-wide failure and cost memory. |

### `Video/FelCurves/`

Only with the `DolbyVisionFelCurves` trait. See the `FelCurves/` note below.

| File | What it does |
| --- | --- |
| `FelCurveLookahead.swift` | Holds back one GOP between demuxer and producer and swaps each scene's RPU for the folded Profile 8.1 one. |
| `FelCurveSampler.swift` | Draws luma samples from one decoded base / enhancement picture pair on the enhancement layer's grid. |
| `FelCurveFit.swift` | Fits those samples into a luma reshaping curve. |
| `FelCurveModel.swift` | The Profile 8.1 curve, NLQ and RPU values the fold reads and writes. |
| `FelCurveFoldRun.swift` | Diagnostic: folds a whole FEL source and returns its RPUs (`aetherctl felcurves`). |

### `Video/Metal/`

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

## `View/`

| File | What it does |
| --- | --- |
| `AetherPlayerView.swift` | One view for both paths: hosts either `AVPlayerLayer` (native) or `AVSampleBufferDisplayLayer` (software). |
| `AetherStillView.swift` | Public transparent surface a host using AVKit binds (`bindStillView(_:)`), so a picture can be held across an item swap. |
| `HeldStill.swift` | `HeldStillSurface` and the presenter that shows and clears a held picture on it (AE#711). |
| `AetherScrubPreviewView.swift` | Public scrub preview surface for DV Profile 5 / AV1 10.0, played through its own muted `AVPlayer`. |
| `PictureInPictureAreaTracker.swift` | macOS: follows the system PiP window's size for a software session so the display layer fits it (AE#810). |

## `Sources/AetherEngineSMB/`

The `AetherEngineSMB` product is a separate, opt-in target, so its SMBClient (MIT) dependency never enters the core engine binary. Hosts that need LAN-share playback link it and hand the engine an `smb://` source through the standard `IOReader` seam.

| File | What it does |
| --- | --- |
| `AetherEngineSMB.swift` | Product entry point: opt-in SMB 2.0.2 / 2.1 byte source, depends on SMBClient (pure Swift, NWConnection). Never linked by the core engine. |
| `SMBURL.swift` | Parses `smb://[user[:password]@]host[:port]/share/path` URLs (missing credentials default to guest). |
| `SMBConnection.swift` | Read-only SMB byte source over one share + path via SMBClient (persistent connection + FileReader; NTLMv2 / guest, SMB 2.0.2 / 2.1 only). |
| `ByteRangeSource.swift` | Random-access, read-only byte-source protocol. Keeps the network backend apart from cursor / seek logic for testing. |
| `SMBIOReader.swift` | Bridges a `ByteRangeSource` into the engine's `IOReader` (blocking read through a happens-before semaphore edge). |

## `Sources/aetherctl/`

Every subcommand is listed with its flags in [docs/cli.md](cli.md#subcommands-at-a-glance). Paths below are relative to `Sources/aetherctl/`.

| File | What it does |
| --- | --- |
| `main.swift` | Entry point: global flags, subcommand dispatch, usage text. |
| `ArgParsing.swift` | Shared flag helpers (`--key value`, booleans, stray-flag rejection). |
| `DebugOutput.swift` | The private per-user debug directory under the temp dir (audit OPS-3, OPS-107). |
| `Probe.swift` | `probe`. |
| `PktDump.swift` | `pktdump`. |
| `DiscInspect.swift` | `disc-inspect`. |
| `Serve.swift` | `serve` (and the bare-URL alias) and `validate`. |
| `SegVerify.swift` | `segverify`. |
| `PlaybackCmd.swift` | `play`, including host-call drills, telemetry and verdicts. |
| `PictureProbe.swift` | `play --picture-probe` (AE#418): which source frame AVPlayer presents at an item time. |
| `SWDecode.swift` | `swdecode`. |
| `SeekTest.swift` | `seektest`. |
| `Extract.swift` | `extract`. |
| `ScrubPreviewCmd.swift` | `scrubpreview`. |
| `DualSubs.swift` | `dualsubs`. |
| `AudioCmd.swift` | `audio`. |
| `AudioTapCmd.swift` | `audiotap`. |
| `BackgroundAudioCmd.swift` | `bgaudio`. |
| `CustomIO.swift` | `customio`. |
| `LiveSpoolIO.swift` | `customio --live` (AE#445): a host-owned live spool behind `MediaSource.custom`. |
| `SMBTestCommand.swift` | `smbtest`. |
| `LiveCmd.swift` | `live`, plus its high-bitrate seed generation. |
| `LiveFixture.swift` | The synthetic, never-ending MPEG-TS source behind `live`. |
| `DVRCmd.swift` | `dvr`. |
| `HLSFixture.swift` | `hlsfixture`. |
| `HLSLiveRepro.swift` | `hlslive`. |
| `DoviTest.swift` | `dovitest`. |
| `FelTest.swift` | `feltest`. |
| `DvSurvey.swift` | `dvsurvey`. |
| `ElType.swift` | `eltype`. |
| `ElSurvey.swift` | `elsurvey`. |
| `ElFrame.swift` | `elframe`. |
| `FelCurves.swift` | `felcurves`. |
| `DmPass.swift` | `dmpass`. |
