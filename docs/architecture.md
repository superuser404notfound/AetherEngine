# Architecture

How AetherEngine is put together: the three playback pipelines, the source-file map, and the dependency surface. For the public API and integration, see the [README](../README.md); for format and codec depth, [docs/formats.md](formats.md).

## Playback pipelines

AetherEngine has three playback pipelines, picked once at `load(url:)`: the audio-only path when `LoadOptions.audioOnly` is set, otherwise the native or software video path based on the source's video codec.

### Native AVPlayer pipeline (default)

Demux the source with libavformat, re-mux the elementary streams on the fly into HLS-fMP4, serve them from a local HTTP server on an ephemeral port (the player is handed `127.0.0.1:<port>/<session-token>/...`; the listener binds all interfaces so an AirPlay receiver can reach it over the LAN, behind the per-session path token, a 32-connection cap with 24 for non-loopback peers, and a 10 s head deadline for unauthenticated connections), point `AVPlayer` at the playlist. Apple's stack does all decode, all HDR / Dolby Vision signaling over HDMI, all audio routing. This is the path for HEVC and progressive H.264, which is what AVPlayer's HLS-fMP4 pipeline reliably accepts (interlaced H.264 routes to the software path for deinterlacing, #107). Atmos passthrough, DV HDMI handshake, HDR10 / HDR10+ system-side tone-mapping all live on this path.

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

**AVC VOD configuration changes are judged before native muxing.** `H264ConfigurationTracker`
starts from the producer’s effective `avcC`, follows length-prefixed SPS/PPS in NAL order, and checks
the SPS referenced by an IDR against that baseline by its decoder signature (profile through
cropping; PPS, VUI and level are taken in band by the native decoder and do not count). A mismatch exits the pump with a typed reason
before the changed sample is written; the session retains the verdict for a pump that finishes before
its owning load is installed. Producer epoch and load generation checks reject superseded events.
The existing `SoftwarePathEscalation` takeover owns recovery under its normal route and host opt-in
constraints. Rebuilding uses the pending user seek, or the actual playhead, never the producer’s
read-ahead position. This avoids relying on a static VOD playlist refreshing an `EXT-X-MAP` after it
has already been loaded.

**Item diagnostics must not become playback work.** `accessLog()` and `errorLog()` can synchronously
wait on AVFoundation's media-service queues, even when called from an item notification. The video
host's log notifications and failure dump, the audio-only error observer, and outgoing-item counter
reconciliation therefore use `AVPlayerItemDiagnostics`: each reader owns its original item, coalesces
pending reasons, and delivers log values rather than native log objects to the main actor. Failure
track arrays are fetched off-main as well; the SDK's UI-actor-isolated track handles then use async
asset-property loaders. A stop/load invalidates publication, including queued callbacks, without
waiting for a read. Delivery rechecks ownership after synchronous log handlers and state subscribers,
which can replace the item while its diagnostic batch is being consumed. Coalesced error batches
examine unseen entries so an intervening fetch error
cannot hide the startup `-15628` loader-poison signal. Access-log notification output is capped at
five entries per item; a failure still dumps the complete available logs.

Admission is process-wide: at most **two concurrent diagnostic reads**, with **one pending retirement
read** retained beyond those lanes. Current-item/error work precedes optional retirement work.
Cancellation never releases a lane still inside a native getter; one stranded lane leaves the other
available, and two stranded lanes defer diagnostics rather than spawn more threads. This contains
diagnostic stalls, not an underlying media-server failure, and does not claim to make every other
AVPlayer operation nonblocking. Telemetry retains its existing separate, serial read path.

Same-session item swaps fold the outgoing item's last observed transferred-byte/dropped-frame totals
without a getter at the handover, then reconcile only the delta from its final background read.
Telemetry readings also refresh that cache, so an older diagnostic snapshot cannot move it backwards
or double-count the outgoing item. If swaps outpace blocked readers, an older unstarted retirement
read is discarded: its observed totals remain, but final totals are incomplete, reported once per
session rather than fabricated. A new playback session (including an episode handover on the same
player) clears those totals and rejects any old reconciliation.

The playlist's segment boundaries come from a keyframe-aligned plan that mirrors the `hls` muxer's cut algorithm (segment N ends at the first IRAP at-or-after `(N+1) * targetSegmentDuration`), built in `HLSVideoEngine+SegmentPlanning.swift`. It needs the source's keyframe positions, which for MKV / MP4 come from a brief cue prewarm (a bounded seek that loads the Cues / `stss` index) and for MPEG-TS / M2TS come only from whatever `avformat_find_stream_info` plus that seek happened to scan. `keyframeIndexIsTrustworthy` gates the plan on three witnesses before trusting that index, falling back to a uniform-stride plan otherwise: the largest **gap** between consecutive keyframes must stay under a cap (a clustered TS index gaps by thousands of seconds; trusting it builds a multi-thousand-second first segment the `frag_custom` muxer buffers whole in RAM, #64), and the **coverage** from first to last indexed keyframe must span at least one `targetSegmentDuration`. The coverage check catches a remote MKV whose Cues tail read fails: the prewarm loads nothing, only the open-time keyframes survive bunched in the first few seconds, their gaps are tiny so the gap check passes, yet no keyframe reaches the first segment boundary, so the keyframe planner would degenerate to a single whole-file segment AVPlayer loads zero tracks from (`kFigAssetError_TrackNotFound`, #91). The **tail** check requires that coverage to reach within 60 s of the source duration: a dense index that stops minutes short is a partial scan (an MKV whose Cues are missing or point past EOF leaves only what the capped prewarm walked), and trusting it cuts a last segment from the final scanned keyframe to the end of the title that the producer can never finish (PR #703). The uniform fallback anchors segment 0 at the content start so a late-starting title doesn't advertise empty leading segments.

At runtime the producer honors those boundaries with a keyframe-gated, decode-order cut (`VODSegmentCutter`): a segment opens only at the IRAP that reaches the next boundary, so the IRAP is the segment's first sample and its open-GOP leading pictures stay with it, matching the live path and the `hls` muxer. The earlier routing keyed each packet to a segment by its DTS against the PTS-valued boundaries, so under B-frame reorder a keyframe whose DTS trailed its PTS fell into the previous segment and the next one started mid-GOP, decode-dependent on its predecessor; a fresh decode at that boundary (rebuffer recovery) surfaced it as transient blocky corruption (#92).

Which timestamp "reaches" a boundary is a question about the CONTAINER, because the plan's boundaries ARE its index entries, and containers do not agree on what an entry means: a mov/mp4 sample table holds decode times, a Matroska Cue holds a presentation time. The gate therefore compares a packet on the plan's own axis (`PlanBoundaryAxis`, chosen from the demuxer's format name), and both mismatches have been paid for. A presentation packet against decode boundaries let a keyframe reach boundaries beyond its own by its composition offset (a couple of frames on an ordinary encode, 3 s on a remux carrying an edit list), consuming plan indices that never opened a segment while the playlist kept offering them (#358). A decode packet against presentation boundaries let no keyframe reach its own boundary at all, on every Matroska whose video carries composition offsets, which is every MKV with B-frames: the gate never opened on the planned IRAP, audio (routed by boundary, not gated) opened each segment instead, and every segment began mid-GOP roughly one IRAP below its own first random-access point. That is invisible while AVPlayer decodes THROUGH the boundaries and fatal the first time it has to decode FROM one, which it answers with `CoreMediaErrorDomain -19602` at a position that depends on the encode rather than on elapsed time (AE#561). `PlanBoundaryAxisTests` pins it on one HEVC stream muxed into both containers, where only the stamping differs.

Seeks are demand-driven: `AVPlayer` just fetches segments at the new position, and `VideoSegmentProvider` only tears the producer down and re-anchors it at the requested index (`restartHandler`, burst-coalesced by `RestartCoalescer`) when the request cannot be served from `SegmentCache`. A restart is the expensive path (it re-seeks the demuxer, slow on remote sources, #93), so for VOD the cache retains already-produced segments beyond its hard `[target - backwardWindow, target + forwardWindow]` window under a byte budget (2 GiB, clamped to a quarter of the tmp volume's free capacity), evicting farthest-from-target first once it fills. The hard window itself is never evicted, so that budget bounds only the extras around it, which holds by construction as long as the forward window stays at or below the historical 150-segment ceiling (~1.5 GB of 4K HEVC). A larger window is an explicit host opt-in into a whole-source prefetch (`LoadOptions.forwardBufferSegments`, up to 2700 segments ~ 3 h, #207): it drops the budget's 2 GiB default cap while keeping the quarter-of-free-space clamp, and the producer parks once its race-ahead owns that many bytes forward of the consumer target, resuming as eviction behind the playhead frees room (`PrefetchDiskBudget`). An opt-in prefetch therefore tracks the disk budget rather than the source length. A seek back into the retained span, and the forward march that follows it, is then a pure cache hit with zero producer restarts; only a seek into never-produced content restarts. Live sessions keep window-only pruning, since the sliding playlist has already dropped everything behind the window. When a non-disc VOD restart is required, it seeks on the video stream's native timestamp axis to the exact IRAP stored in the segment plan, with that timestamp as the lower bound; a global time seek can land a whole GOP earlier on multi-stream MP4 and turn the producer's scan-forward gate into a long remote read (#191). Disc plans use folded multi-clip timestamps and keep the global-time seek. Restarts on a slow link are further contained (#93 residual): a fetch that is waiting for an in-flight restart rides its progress instead of burning a fixed retry budget into a 503 (and never re-fires a restart at its own stale index), the wedged-restart fresh reopen skips `find_stream_info` (the session already holds saved codec configs and the segment plan), lazy native subtitle readers defer while a restart executes, and the FIRST producer of a resumed session anchors directly at the resume segment instead of producing seg0 into an immediate teardown. Retained scrub bands leave interior holes inside the cache's stored min/max index range, and residency there is not proof a segment exists: a fetch inside the range waits (2 s) only when the active producer's forward march actually covers the requested index, and restarts immediately otherwise (#129).

The public `seek(to:)` on the native path awaits AVPlayer's real landing so `isSeeking` spans it (#37/#38), but the wait is hard-bounded at 8 s (#65, #129): at the deadline the engine reconciles the published clock to AVPlayer's rendered frame and returns to the caller instead of stacking a second unbounded seek (repeated source stalls could chain those past 40 s). The original AVPlayer seek stays alive as the recovery intent (`pendingRecoverySeekClockTarget`): the producer is re-anchored at the target only when it is genuinely starved (a healthy-but-slow producer keeps its progress), the scrub clock is held while the intent is pending so recovery nudges cannot bounce it (#37), and a late landing settles the clock from the rendered frame, re-anchors subtitles once, and reconciles transport state after the fact; both orderings of the landing/deadline race on the MainActor are handled. Transport reconciles from live `timeControlStatus`, so an external AVKit / MediaRemote play or pause issued mid-seek wins, a spurious pause during active stall recovery is re-asserted inside the bounded recovery window, and a paused scrub still lands paused, never re-engaging playback (#122).

What a host observes about a seek comes in two shapes. `isSeeking` / `seekTarget` are the level: a seek is in flight, and where to. `seekEvents` is the stream that says what happened to it, because the level's falling edge is ambiguous by construction (#38 follow-up). Every accepted seek emits `.began` and exactly one of `.landed(renderedTime:)`, `.stalled` or `.superseded` under the same id, a seek that never reaches a host emits a standalone `.rejected`, and the one asymmetry is deliberate: a `.stalled` seek stays alive as recovery intent, so its `.landed` can still arrive minutes later on a source that finally serves the target, which is precisely the transition no level signal can express. Three paths feed it. Programmatic seeks report from their finalize, so the clock is already at the target when the event fires. Seeks stashed before the session can take them (#127/#178) hold the level for the whole stash window, because the engine publishes their target on `currentTime` optimistically and a consumer that broadcasts it needs to know nothing has reached it. Native AVKit scrubs end their window when the PICTURE reaches the restarted region, watched on `$renderedTime` and bounded at 8 s, not when the coalesced producer restart drains: draining means the producer is producing at the new index, and the picture arrives a fetch and a decode later (1.4 s on a WAN source in the reporting host's capture). A restart that a programmatic seek itself caused is left to that seek's events, since the restart segment can sit below where the picture ends up.

Restart latency is self-localizing (#93 follow-up): the "producer restarted" line carries a phase split (`stopWait/reopen/seek/build`), a producer's FIRST source read is timed, and any single `AVIOReader` read exceeding 2 s emits one `slow read` summary naming where the time went (detour fetches with network time, `connStallTimeout` waits, reconnects, backoff sleeps, bytes dropped by the stale-generation guard, generation span). A slow read with all-zero counters means the wait was upstream of the read loop.

A restart-window request must also never leave AVPlayer waiting in silence (#93 round 3): AVPlayer's media watchdog logs `-12889 "No response for media file"` after ~3.5 s without response HEADERS (holding the connection open does not help), and three strikes fail the item. A VOD serve still running at 2 s (`SlowServeSignal` armed by `VideoSegmentProvider.mediaSegment(at:onSlow:)`) therefore emits an early `200` with `Transfer-Encoding: chunked`; the segment follows as a single chunk when it lands, and a serve that ultimately misses aborts the connection (truncated transfer, AVPlayer retries) instead of framing a cacheable empty 200. Fast serves keep the byte-identical `Content-Length` response. If the item dies anyway, `failedToPlayToEndTime` parks it at rate 0 / `timeControlStatus == .paused` (with `item.status` often still `readyToPlay`), which every pause-guarded recovery layer used to misread as user intent, making the session terminal. The host now counts loopback-path end failures (`endFailureCount`), and the engine confirms the death through the same deferred window as the `.failed` KVO, then reloads the item through the stage-2 chain with the pause guard bypassed, bounded by `ItemDeathReviveGate` (3 attempts per dead spot; playback progress or a user seek away restores the budget). The fresh item resumes only if the host's play intent says the viewer was playing: a paused title whose item dies (a tvOS screensaver taking the display is one way) is reloaded and stays paused.

When a restart does run, it must reproduce segments on the SAME media timeline the continuous run gave them: the loopback's contract with AVPlayer is "static VOD server", and AVPlayer anchors fMP4 segments by their `tfdt`. Each restart allocates a fresh mp4 muxer, and movenc zero-bases a new instance's timeline by default, so a restart-produced segment used to carry `tfdt=0` while the playlist placed it at its plan offset: an implicit timeline discontinuity on every restart, papered over for plain playback but fatal to ancillary consumers (AVKit's legible renderer detaches mid-PiP, Sodalite#32; playhead/loaded-range decoupling, #93). The muxer therefore sets `movflags +frag_discont` with `avoid_negative_ts=disabled` so `tfdt` carries the producer's absolute output timestamps, the restart audio gate inherits the session shift (video shift rescaled) instead of snapping audio onto the video seam, and leading head-of-stream audio that would map below 0 is dropped (the muxer no longer absorbs negative timestamps). A restarted segment is byte-identical to its continuous twin modulo the per-muxer `mfhd` sequence number (pinned by `RestartTimelineContinuityTests` on a committed A/V fixture); on matroska sources, per-sample DTS synthesis after a demuxer seek scatters the DTS decomposition and boundary-frame membership by a frame or two, but presentation timestamps and `tfdt` anchoring stay epoch-invariant. Because `tfdt` carries `unsigned int(64)`, that same setting makes a negative output axis unrepresentable rather than merely unusual, so the published first timestamp is clamped at zero (AE#509): libavformat serves an MPEG-TS whose first DTS sits within 60 s of the 33-bit PTS wrap with every timestamp `2^33` ticks low (`AV_PTS_WRAP_SUB_OFFSET`), and a live join there published `baseMediaDecodeTime = 2^64 - |dts|` against a playlist starting at 0, which AVPlayer answers by fetching the whole window and placing none of it, with no error and no stall of its own.

The video track's output time base is normally the source's, which movenc scales up to at least 10000 (Matroska's 1/1000 becomes 1/16000). That keeps whatever quantization the container has, and on a constant-rate track it is not harmless: 23.976 fps on 1 ms ticks reaches AVPlayer as 41 and 42 ms steps, and at a 59.94 Hz output every second frame sits exactly on a refresh boundary, where half a millisecond of rounding decides which vsync shows it (AE#886). `CFRFrameGrid` therefore gives a VOD track whose source tick is 0.1 ms or coarser, and whose rate probes as exactly a standard rate that the tick cannot hold, a time base with one frame in whole ticks (1/24000 and 1001 ticks for 23.976, 1/24000 and 1000 for 24), anchored at the stream's start time. `HLSSegmentProducer` puts each packet whose source-axis PTS lies within one source tick of a slot onto that slot (DTS onto its own slot, never past the PTS), and rescales everything else as before. The grid is derived from stream fields only, never from observed packets, so every producer of a session writes the same `init.mp4` timescale and a restarted segment still matches its continuous twin.

### Software decoder pipeline (AV1 + VP9 + VP8 + legacy fallback)

Demux the source, run video packets through libavcodec (dav1d for AV1, VideoToolbox with a libavcodec fallback for VP9, FFmpeg's native decoder for VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1) into `CVPixelBuffer`s, run audio through libavcodec into `CMSampleBuffer`s, render via `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` as the master clock. Used for codecs AVPlayer's HLS-fMP4 pipeline doesn't accept: AV1 (no Apple TV currently ships an AV1 hardware decoder, and Apple bundles dav1d only on iOS / macOS, so AV1 always routes here today; the engine still registers the supplemental VideoToolbox AV1 decoder and gates on `VTIsHardwareDecodeSupported` (`VTCapabilityProbe`), so a future Apple TV chip with HW AV1 is picked up automatically), VP9 / VP8 (AVPlayer parses the HLS manifest, sees `vp09` / `vp08` in the CODECS attribute, then silently stops fetching. `item.status` never leaves `.unknown`. VideoToolbox HW-decodes VP9 fine, but only outside the HLS pipeline), and legacy MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, and VC-1 (none of `mp4v.20.X` / `mp2v` / `vc-1` are in Apple's HLS Authoring Spec CODECS list). Interlaced H.264 also routes here (`VideoRoutingPolicy`, keyed on the declared field order), because AVPlayer does not deinterlace and 1080i / 576i broadcast would comb; the SW path runs it through `DeinterlaceFilter` (#107). On seekable VOD that declaration is verified against decoded frames first (`InterlaceProbe`, #232): the filter engages on `AV_FRAME_FLAG_INTERLACED` alone, so a sample in which that flag never appears proves the detour would be a no-op and the stream goes back to the native path.

The software host attempts a hardware-only VideoToolbox session for VP9 profile 0 (8-bit 4:2:0)
and profile 2 (10-bit 4:2:0). `VideoToolboxVideoFormat` synthesizes the `vpcC` record WebM omits
using the [VP codec configuration box](https://www.webmproject.org/vp9/mp4/#vp-codec-configuration-box)
layout. Supplemental decoder registration is gated by OS availability. `VideoDecoderOpener` closes
a failed candidate and opens libavcodec before the host publishes its decoder or starts reading
packets; a failed fallback is also closed and its error is propagated. `HardwareVideoDecoder` reads the coded size from each VP9 key frame header and rebuilds its session when it changes. The feed epoch is checked under the session lock before replacement, so a pre-seek packet cannot discard the current reference pictures. Playback remains on the
software presentation route because AVPlayer's HLS path does not accept VP9. Existing HEVC
hardware probing, Dolby Vision selection and HDR10+ delivery are unchanged.


VideoToolbox decode callbacks can retain their image buffer as a reference picture. The hardware
video decoder passes the callback's `imageBufferModifiable` flag into
`VideoToolboxOutputMetadataNormalizer`: matching colour and pixel-aspect attachments leave the
buffer untouched, a modifiable buffer is updated in place, and other updates use an owned pixel
buffer from a format-keyed pool. A failed copy preserves the original output rather than mutating
storage the decoder still owns. The same policy removes a stale pixel-aspect attachment when the
current stream uses square pixels. The AV1 Dolby Vision RPU path reuses that owned output or makes
its own copy before changing buffer and IOSurface metadata. If copying fails, it delivers the
original without setting or clearing RPU keys, including when RPU attachment is disabled.


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

Clock arming publishes its latch synchronously on the feeder, so `play()` and `pause()` can see
that a clock exists. Its post-arm rate correction runs on the main actor alongside those transport
operations: it cannot restart the synchronizer halfway through a pause. Before applying a correction,
it rechecks the output identity and seek generation, ignores a stopped or seeking session, and leaves
end-of-media tail playback to its owner unless the host explicitly paused. It also carries the output's clock-command revision:
`AudioOutput` compares that revision and applies the rate under its existing lock, so a later
rebuffer pause, seek or rate command supersedes the queued correction. Preroll completion belongs
to its original command and keeps the revision. Paused intent cancels a pending preroll start,
even while the synchronizer still reports rate zero.

Explicit software-host `pause()` also calls `AudioOutput.setPlaybackEnabled(false)`, which owns every
clock write under the output lock: stale feeder arms, rebuffer releases and preroll completions cannot
start it, even without a command revision. A paused seek still changes its anchor at zero rate. Internal
buffering pauses leave this transport intent alone. Only `play()` re-enables it; enabling alone neither
starts an unanchored clock nor advances the command revision, so a pending arm correction can still
supply the initial start when play arrived before the feeder published its armed latch.

A seek holds the last frame on screen rather than blanking it. `SampleBufferRenderer.flush()` takes a `removingDisplayedImage` flag and hands it straight to `AVSampleBufferVideoRenderer.flush(removingDisplayedImage:)`: stop/teardown clears the visible frame (the default), but `SoftwarePlaybackHost.seek()` passes `false`, so the previous frame stays up until the post-seek keyframe decodes instead of flashing black on slow sources like MPEG-2. This matches the native/AVPlayer path, which holds the frame through a seek (#90).

**The channel layout on that same format description has to name the order the resampler wrote** (#401). `AudioDecoder` resamples into `makeResamplerOutputLayout`'s layout and stamps `audioChannelLayoutTag`'s tag, and if the two disagree the renderer places audio where the decoder never put it: measured per channel, the earlier pairing moved every channel of a 7.1 track and placed the LFE hard left at full gain, put a 4.0 centre hard left, and mixed a 2.1 LFE into both channels instead of dropping it. Only 5.0 and 5.1 lined up, which is why it went unseen. The two functions therefore live side by side and a test holds them against each other, once structurally and once by rendering each channel through a real downmix. 6.1 is the single count CoreAudio has no matching tag for, so the resampler is pointed at 6.1(back) rather than leaving the well-trodden tags for a `UseChannelDescriptions` layout.

`AudioDecoder` stamps each `CMSampleBuffer` from a running sample count anchored to the first frame (`AudioClockAnchor`), not from the container-quantized per-packet PTS. Container timebases are coarse (1 ms in MKV), so when a frame's duration is not an integer number of ticks (a 1536-sample AC-3 frame is 34.83 ms at 44.1 kHz but exactly 32 ms at 48 kHz) the quantized PTS leave a sub-millisecond gap or overlap at every buffer boundary, and `AVSampleBufferAudioRenderer` reconciles a discontinuity at each one (~29 clicks/sec, a continuous crackle). Anchoring to the sample clock makes consecutive buffers abut exactly; a real source discontinuity (> 100 ms off the predicted clock, i.e. a seek or edit) re-anchors so genuine gaps are not papered over, and `flush()` drops the anchor. The clock advances only on a successfully emitted buffer, so a dropped buffer injects no phantom samples.

AV1+DV (Profile 10.0 / 10.1 / 10.4) routes through the native path on hardware-AV1 hosts via the `dav1` / `av01` track type plus the source's `dvvC` box. AV1+Atmos is genuinely rare in the wild (mastering still runs in HEVC overwhelmingly), so the SW pipeline's lack of Atmos passthrough is a theoretical limitation rather than a real one. AV1 capability registration is lazy and runs only when routing an AV1 source; loading H.264, HEVC or audio-only content does not consult it. The dispatch happens once at load time; hosts see a unified `@Published` state surface either way.

**Background audio (iOS).** When the app backgrounds while playing, the engine keeps audio going rather than tearing the pipeline down. The decision is a pure, unit-tested policy, `backgroundAction(isAudioBackend:hasSoftwareHost:softwareHostHasAudio:keepVideoAlive:pipActive:state:)`, driven from the `UIApplication` lifecycle observers; `keepVideoAlive` comes from `shouldKeepVideoAlive(enabled:pipActive:state:)` and is gated to iOS (tvOS always tears down, wedge-safe: a frozen decode session crossing a multi-hour suspension wedged `mediaserverd`). On the native path "keep audio alive" is just declining to tear down: `AVPlayer` under the `.playback` session keeps decoding. The software path has no `AVPlayer`, and its combined demux loop normally paces the whole loop (audio and video) on the video renderer's `isReadyForMoreMediaData`; once `AVSampleBufferDisplayLayer` stops draining in the background that gate never reopens and audio would starve. So the host enters `backgroundAudioOnly`: the loop drops video packets and paces on the audio renderer (`AudioOutput.isReadyForMoreMediaData`) instead, keeping `AVSampleBufferAudioRenderer` fed and the synchronizer advancing. On foreground return the flag clears, the video decoder and renderer flush, and video resyncs at the next keyframe with audio uninterrupted. A software host that renders no audio of its own never enters this mode (AE#739): the loop would have nothing to pace on and would drop the rest of the file within moments, parking the clock at end of media in the background, so such a session is released like a paused one and reloaded on return. The VideoToolbox session is rebuilt on every foreground return, because an iOS screen lock invalidates it and in audio-only mode nothing decodes video to notice. A loss observed while video is wanted (`kVTInvalidSessionErr` from a decode) is reported by `HardwareVideoDecoder.onSessionLost`; the host rebuilds the session and repositions to the playhead so the picture returns on the frame the audio is at, and owes the recovery to the next foreground return when it happens in the background or VT refuses the rebuild. Scope is the combined VOD loop (and live-without-DVR, which shares it); the DVR feeder loop is unchanged. Exercise it headless with `aetherctl bgaudio` (see [cli.md](cli.md)).

**Live audio look-ahead + edge rebuffer (#107 audio chopping).** The DVR feeder loop shares the pacing coupling above: audio is interleaved behind the video renderer's back-pressure gate, so the audio renderer could never hold more than the video queue allows (<1 s measured). On devices where software 1080i decode + deinterlace runs near real time that margin is zero and every feeder stall is an audible dropout. The feeder therefore runs an audio look-ahead pump (`AudioLookaheadPolicy` + `AudioLookaheadState`): an independent ring cursor that decodes and enqueues audio packets ahead of the combined cursor until the renderer holds `targetLeadSeconds` (4 s) over the synchronizer clock, making audio delivery independent of video decode pace (a chronically slow video decode now degrades to late video frames under smooth audio, the right priority). DVR seeks reset the pump cursor alongside `setFeedCursor` (compare-and-set, seek wins). The same pump pass handles live-edge source underruns: when the source itself delivers below real time and the pump drains the ring at the edge, the free-running clock would otherwise outrun the stream permanently (every later sample lands in the clock's past, continuous chopping that never recovers). `AudioLookaheadPolicy.clockAction` pauses the clock at `underrunPauseLeadSeconds`, refills, and resumes at `rebufferResumeLeadSeconds`, mirroring AVPlayer's stall handling on the native path. A host seek does not ask the pump to do that on purpose: a software live landing nearer the reader's frontier than `rebufferResumeLeadSeconds` is held that far back (`AetherEngine.softwareLiveLanding`, Sodalite#104 round 3), because on a real-time source the lead arrives exactly as slowly as it is deep, so a landing at the frontier parks the clock for that long and resumes at the same distance behind it that the held-back landing starts from. A source that delivers whole segments (a live HLS ingest) gets a holdback sized from the segment length instead (`SoftwareLiveHoldback`, AE#813): the join lead, the landing, the live-edge tolerance and a rebuffer's resume cushion (`newest source PTS - clock`, on top of the audio lead, since the pump caps that lead at `targetLeadSeconds`) all follow it, and a continuous source keeps the values above. A source that paused comes back one of two ways: it skips what it missed and continues near real time, or it hands the whole backlog over at once, which leaves the picture the length of the pause behind the newest media on a path that never catches up on its own. So the feeder watches a resume with the join's rule (`SoftwareLiveJoinPolicy`, from the clock instead of the ring's first packet): once the backlog has landed, a span past the band the edge verdict already counts as the edge (`SoftwareLiveHoldback.resumeCatchUpSpanSeconds`, so an ordinary resume on a segmented source, up to its cushion plus one unit behind, is never followed by a seek) moves the picture up to the join lead behind the newest media through the engine's own live seek (`SeekOrigin.liveRejoin`), and a source that skipped leaves it where it resumed. Diagnose with `aetherctl play --audio-stats` (see [cli.md](cli.md)).

**Paused-background grace window (iOS, #127).** A paused session used to tear down the moment the app backgrounded, so a 10-30 s app switch paid a full pipeline rebuild (demuxer reopen, segment-plan scan, AVPlayer item reload). The teardown is now deferred by `backgroundTeardownGraceSeconds` (default 15 s, 0 restores the immediate teardown) held under a `UIBackgroundTask` assertion; `didBecomeActive` cancels the window, so a quick switch resumes on the live pipeline. At expiry the action is re-evaluated (PiP can start and lock-screen play can resume mid-window) and the teardown runs while the app is still genuinely running, never across an idle suspension; the assertion's expiration handler is a synchronous backstop. The step decision is the pure `backgroundStep(action:state:supportsGraceWindow:graceSeconds:)`; a PLAYING teardown (background playback disabled) stays immediate because its audio would keep sounding through the window, and tvOS keeps the unconditional teardown. Two hardening pieces ship with it: host seeks that arrive while the (re)built AVPlayer item is pre-ready are deferred (`shouldDeferHostSeek`) and the latest replays at readiness (an early seek clamps to 0 against empty seekable ranges and replaces `load()`'s own startPosition seek), and hosts observe the published `isSessionReady` to gate corrective actions (restore watchdogs, position clamps) instead of inferring readiness from `currentTime` being pinned at 0.

**What a teardown hands the reload that follows it (#357).** Every reload path snapshots the state it restores (the #170 subtitle carryover, the audio pick, the disc title) immediately before its own `stopInternal`. That contract holds only while teardown and reload are the same call, which the background path is not: it tears down when the app sleeps and reloads on foreground return, so the reload's snapshot ran long after the state it wanted was wiped and it restored nothing. For subtitles that leaves the rebuilt session without a drain target, so no cue is delivered and every delivery instrument stays silent, which reads as a delivery defect rather than a lost selection; only an explicitly picked track died, because an auto-picked one came back through the reload's re-run preferred-language selection. The teardown now parks a `BackgroundTeardownSelection` before `stopInternal` and `reloadAtCurrentPosition` claims it once. The live read stays authoritative for what survives a teardown (the external registry, its ordinal counter, the host's subtitle authority) and for a selection made after it, which is newer intent; the snapshot fills only the fields the teardown wiped.

The same seam owns one object, not just state: the background teardown keeps the `NativeAVPlayerHost` shell alive (`keepNativeHost`), because AVKit registers its MediaRemote Now-Playing client once per `AVPlayer` instance and never registers again against a swapped one (issue #15). The reload on the way back decides whether to keep it with `shouldPreserveNativeHostAcrossLoad(backend:nativeHostSurvives:)`, which asks whether a host is still there rather than which backend is running: the teardown leaves `playbackBackend` at `.none`, so reading the backend alone discarded exactly the instance the teardown had preserved, and the viewer came back from a tvOS screensaver to playing video with a dead system Now-Playing card (Sodalite#149). A load that then routes software or audio-only releases the preserved host in its own dispatch branch.

### Audio-only pipeline (music, podcasts, audiobooks)

When the host sets `LoadOptions.audioOnly`, the engine skips the video machinery entirely: no HLS loopback server, no segment producer, no display layer. Decode is native-first. Codecs on the `avPlayerCanDecodeAudio` whitelist hand the source URL straight to a bare `AVPlayer` (`AudioAVPlayerHost`); everything else demuxes through libavformat and decodes through libavcodec into an `AVSampleBufferAudioRenderer` (`AudioPlaybackHost`). So does a custom `IOReader`, a FLAC whose blocks are under CoreMedia's floor (AE#764), and a session the host asked onto `LoadOptions.preferredDecodePath = .software`; `audioOnlyUsesAVPlayer` holds the whole decision. Transport (`play` / `pause` / `seek`) routes to the active host, and `stopInternal` tears it down for a clean handoff back to the video path on the next load.

```
audioOnly == true
   ├─ whitelisted codec, URL source, not .software ──► AVPlayer (AudioAVPlayerHost) ──► AVR / speakers
   └─ otherwise ──► Demuxer ──► AudioDecoder ──► AVSampleBufferAudioRenderer ──► AVR / speakers
```

On tvOS and iOS the AVPlayer audio host owns a persistent per-player `MPNowPlayingSession` (exposed via `audioNowPlayingSession`) so the system Now-Playing overlay stays bound to the app across a background pause, auto-publishes now-playing info from the player, and carries `externalMetadata`. The host survives across tracks and does not pause when the app backgrounds. All of this is gated `#if os(tvOS) || os(iOS)`; on macOS the path compiles and plays without the system session (a macOS host drives Now-Playing through the shared centers itself).

The native VIDEO host can own the same kind of session, but only on request (`ownsVideoNowPlayingSession`, default off, read when a host is created). The asymmetry is deliberate: the audio path is always a bare AVPlayer, whereas the video player is consumed both by custom-transport hosts and by `AVPlayerViewController` hosts, and AVKit owns Now-Playing there through its own private registration. A session claimed underneath AVKit costs that host its identity card and its working transport commands, so ownership is the host's call. When it is taken, the session lives on `NativeAVPlayerHost` and therefore survives native->native reloads with it (issue #15), and `setVideoNowPlayingInfo(_:)` stages the identity dictionary that is replayed onto every fresh `AVPlayerItem` (readiness-gate master reloads, media fallback, in-place PiP swaps).

### Audio tap (#95)

`installAudioTap()` returns an `AsyncStream<AudioTapBuffer>` of decoded playback audio: mono Float32 48 kHz (`AetherEngine.audioTapFormat`), stamped with source-PTS seconds (`sourceTime`, same axis as `engine.sourceTime`), with a `discontinuity` flag on any gap (seek, eviction, track switch, drops under pressure). Intended for host-side speech features (live transcription via SpeechAnalyzer) and audio recognition (ShazamKit signatures).

Native path: a loopback reader (`LoopbackAudioReader`) pulls the engine's own muxed fMP4 segments from the segment cache near the playhead and decodes their audio track out-of-band (libavcodec + libswresample, fresh per-segment demux context that reads the init and fragment in place and discards every stream but the audio one, #910). Because it reads the mux, it follows the active audio track for free (the mux contains exactly the selected track, post-bridge), adds zero network load, and cannot stall playback by construction. Remote-HLS path (direct AVPlayer ingest, no loopback, VOD and live): `AudioTapHLSVariantResolver` picks the active audio rendition / muxed variant, `AudioTapHLSFetcher` fetches and decrypts (AES-128 clear-key) self-contained TS / fMP4 segments (sending `LoadOptions.httpHeaders`, same as the player's asset, #119), and a playhead-follow reader (`AudioTapHLSReader`) decodes them near the playhead; `AudioTapReaderSelection` makes the per-session reader choice, and `audioTapHasDeliverySource` tells the host whether the current session can deliver at all (fail-loud). Software path: the existing `AudioDecoder` PCM output is mirrored through an `AVAudioConverter` sink on `SoftwarePlaybackHost`. That decoder emits the source channel layout up to 7.1 without downmixing, so the sink takes its input format from the sample buffer's own channel layout (the channel-count-only `AVAudioFormat` initializer returns nil for every count above 2) and verifies once per format that the converter really mixes it down: any discrete layout converts to digital silence without reporting an error, and those are folded to mono inside the tap instead (#400). The converter runs with `downmix` on: without it AVAudioConverter does not mix but maps by channel label, which delivered a stereo track as its left channel, 2.1 as silence and 4.0 to 7.1 as the centre alone (#908). A `.dialogue` install (`installAudioTap(channels:)`) takes the front-centre channel alone instead of the downmix: the native and remote-HLS decoders set a one-row swresample matrix with the centre at unity, the software sink copies that channel out before the converter. Without a centre it falls back to the downmix, and each buffer's `channels` says which it carries. One tap per engine; re-install replaces the previous stream, and `load()` / `stop()` finish it (opt-in is per load; with no session or a video-only source the stream finishes immediately). A session-preserving reload finishes it too (audio / subtitle / disc-title switch, `reloadAtCurrentPosition`): every delivery path is bound to the session it was installed against, and each install gets a fresh `AudioTapMonotonicFilter`, so a host re-installs on stream end and starts the new session on a clean timeline rather than one stitched across a reload that resumes slightly behind the old position (#356). Both readers decode whole segments but release the decoded buffers along the playhead: a buffer goes out once it starts before playhead + lead (10 s), and the head of the segment an anchor lands in that already ended behind the playhead is dropped, so the stream is handed at most tolerance + lead (12 s) however long a segment runs. That bounds the release window, not retention: the decoded rest of the current segment is held on top of it (a reader parked at 95 s on 15 s segments has released 12.1 s and still holds 14.9 s), so the held tail grows with the segment length, and whatever the consumer keeps is its own. A backward seek is read off the playhead's own movement, never off how far the decode runs ahead of it (#864). Delivery is best-effort and lossy only for a consumer that falls behind: the stream queues 256 buffers (`bufferingOldest`, about twice the release window at the 100 ms chunk floor), a buffer that arrives while it is full is dropped, and the first one taken after that carries `discontinuity`, so a host never reads contiguous PCM across an overflow. There is no non-evicting mode; a stalled consumer would turn it into unbounded memory. Live sources are best-effort.

```
native ──► SegmentCache (init + seg N) ──► mov demux ──► libavcodec ──► swr (mono 48k) ──► AsyncStream
software ──► AudioDecoder CMSampleBuffers ──► AVAudioConverter (mono 48k) ──► AsyncStream
                       (.dialogue: swr matrix / channel copy takes the centre alone)
```

### Playback status (`playbackPhase`)

`AetherEngine.playbackPhase` is the single observable for what playback is doing right now, across all three pipelines. It is *derived*, not a parallel state machine: a pure fold of `state`, `isBuffering`, `isSeeking`, and a typed source-reconnect axis, recomputed on every input change so it can never desync from them. Each input's `didSet` triggers an idempotent recompute that re-emits only on an actual change.

Precedence (highest first): `error > ended > idle > loading > stalled > seeking > rebuffering > playing/paused`.

The reader axis outranks `isSeeking` (#410). A seek cannot land over a source that stopped delivering, so the level stays up for as long as the seek stays alive, and the seek holding it is not necessarily the host's: the producer's restart coalescer issues its own `nativeScrub` seeks while recovering, so the engine's recovery used to hide the outage it was recovering from (measured at 29 s and 41 s on a killed LAN origin). A seek stays observable through `isSeeking` and `seekEvents`; the reader axis is observable nowhere else. Over a delivering source nothing changes: the reader is `flowing` and a seek reads `.seeking` exactly as before.

- `.rebuffering` is a healthy-connection buffer underrun (AVPlayer waiting to play, or a software pump that paused its synchronizer to refill: the live feeder at a dry ring, the on-demand loop with its audio lead exhausted); `state` stays `.playing` across it. The software host publishes its pumps' hold as `isRebuffering`, folded into `isBuffering` the way the audio host's wait is, so the phase turns `.rebuffering` the moment the clock stops. Before it did not, and a live source that merely paused read as `.playing` over a standing picture for the whole of the reader's stall timeout, until the reader's reconnect promoted it to `.stalled`; a host app watching the clock had reloaded the session long before, and the fresh join behind the same frozen burst replayed what it had just shown.
- `.stalled(reconnecting:)` is a source-connection problem (drop / 429 / 503 backoff) where the `AVIOReader` is retrying. It is promoted from log text to a typed signal: the reader pushes a `flowing` / `reconnecting` phase through `Demuxer.onNetworkPhaseChanged`, the owning host (`HLSVideoEngine` on the native path, the software / audio hosts directly) forwards it, and the engine hops it to the main actor. The flag is `true` while the reader is retrying and `false` once it has spent its ladder (#410): the reader is out of the read, the producer's reopen owns the recovery, and the source is still down. Before that the dying reader claimed `flowing` on its way out, purely so the next reader's dedupe gate could not strand the phase, and the whole reopen window read as a healthy source.

Only bytes that crossed the network move the axis back to `flowing` (#410), the same line the reconnect ladders have drawn since #380: a serve out of the resident window, the retained head/tail spans (#281) or a resident detour block hands back read-ahead the origin paid for before it died, and reporting delivery off it erased the stall on the next read. A metered detour fetch (429 / 503 / 509 on the arm that carries a throttling origin, #69/#71) now reports `reconnecting` and its give-up reports `exhausted`; it charged the ladder but told the axis nothing. One deliberate exception remains: the faulted-runway refill (#307/#309) replaces a dead connection while megabytes are still resident and stays silent, because playback there is uninterrupted; the empty-window ladder reports it when playback genuinely starves. The native text subtitle readers (WebVTT rendition prefetch) are deliberately left unwired so their stalls never move `playbackPhase`; the overlay itself is fed from the main read via the subtitle packet tap and has no connection of its own.
- The direct AVPlayer-HLS live path (`nativeRemoteHLS`) and the whitelisted-codec audio host (`AudioAVPlayerHost`) have no demuxer / `AVIOReader`, so they cannot report `.stalled`; a starved connection there reads as `.rebuffering`. On the audio host that flag is folded from AVPlayer's own signals, `timeControlStatus == .waitingToPlayAtSpecifiedRate` and `AVPlayerItemPlaybackStalled`, and only once the item has played: the pre-roll wait of a fresh track is startup, not a rebuffer, and a paused player is never one. Up to and including 6.30.1 the audio host fed no buffering axis at all, so a dead progressive stream (an internet-radio origin dropping the connection) stayed `.playing` with a frozen clock and a host had nothing but the clock to watch.

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

## Byte-reader callback scheduling

The AVIO reader, held HTTP transport and prewarm fetcher use independent serial
user-initiated URLSession delegate queues. These callbacks deliver playback bytes
and release origin-request tickets needed by foreground demux threads. A semaphore
wait cannot donate priority to an implicit utility callback queue. Held transport
work also runs at user-initiated QoS.

Finite AVIO requests release their ticket in the completion callback, before the
synchronous caller resumes to process its result. A lock-guarded lease makes that
release idempotent against cancellation, early return and deallocation. Refusal
responses are charged to the origin before handing its slot to another reader. Persistent
and prewarm callbacks already return their tickets at completion. Per-origin caps,
FIFO ordering, pacing, cancellation drains and timeout/overcommit policy remain
unchanged; each session retains its own serial callback ordering.

QoS is not an execution deadline. A VOD segment already in the cache may still
cross the slow-serve threshold while its serving thread is delayed. Its early
chunked header remains valid: the response carries the same cached bytes, and
the notification alone does not restart the producer.

## Live replay boundary and video diagnostics

Live packet admission also protects the outgoing transport boundary. A timed, flagged video
packet beyond admitted history is held while earlier intact pictures and audio continue.
Exact replay on the participating tracks can supply the clean returning frame; the flagged
packet is discarded only with that evidence. Good pictures released late by the outgoing
parser do not complete a track before its replay is traversed. Verified pending video is
ordered by decode timestamp, exact returning copies are removed, and the settling frontier
covers every retained good packet. An ambiguous boundary, EOF or read failure preserves its
packets and admitted history. A clean outgoing picture cannot release the boundary on its own.
The lookahead covers sparse-video cadence as well as the bounded source interval; the packet
count remains capped. Held intact pictures define a provisional replay horizon, while the
replacement for the damaged picture remains fresh media until admitted. Only committed
packets enter retained source history. Held-video packet count and source interval bound the lookahead;
transport and no-cut watchdog deadlines remain responsible for a source that stops delivering.

Video diagnostics keep source packet cadence separate from native decoded-output progress.
The optional output observer belongs to one item/session, stops on teardown, excludes
ineligible playback modes and discards its state through positioning or inactive rendering.
It emits bounded progress summaries and gap episodes, without retaining pictures or making
recovery decisions. Hosts control whether to enable it and where to send its measurements.
The output is detached before a host-announced PiP transition and only reattached to a ready
inline layer after PiP ends. Native presentation repair uses layer readiness independently of
this optional output. Its bounded nudge/item-replacement sequence requires advancing playback,
resident buffer and an attached foreground surface; it does not reset source history or move a
DVR viewer to the live edge. In-place item replacement preserves the repair budget, which only
rearms after sustained healthy presentation. Encoded long-GOP H.264/AAC replay tests decode both
admitted software packets and remuxed fragments and compare every picture with the original.

## Software VOD compressed packet cache

Seekable software VOD read through one of the engine's byte readers has a
compressed packet producer separate from the renderer-paced decode consumer. The
producer stores lossless packet envelopes in a session-owned temporary disk FIFO.
Envelopes preserve payload, PTS/DTS, packet duration, position, flags, stream
index, time base and every side-data entry; neither decoded pictures nor source
URLs are retained in metadata. A source libavformat opens itself, which is a
local path, stays on the direct loop: the spool exists to avoid a second trip to
a source, and re-reading a file is a page-cache hit.

The host uses the existing `forwardBufferSegments` clamp and native session
retention/volume-safety policy. The forward-second limit is measured on the
reservoir, from the packet the consumer last took to the newest one stored,
because that is what the producer is building and two timestamps always say it.
The coverage frontier below answers a stricter question and reports nothing at
all once a hole or a single late presentation timestamp invalidates it, so it
cannot be the only thing holding the limit up. Byte and forward-time thresholds
stop prefetch, with bounded protected-chunk and single-record slack. Old consumed chunks can
be reclaimed at the exact budget boundary so refill cannot deadlock. Metadata
reads and seek intent are main-thread safe; disk operations and source reads
stay on workers. Stop releases the session's directory, and bounded stale
cleanup uses session leases without following symlinks or deleting live stores.
If creating the store fails, the original direct playback loop remains available.
Runtime cache corruption is a reported playback failure, not silently skipped data.

On tvOS the same records live in purgeable memory instead
(`SoftwarePacketMemoryFIFO`, bounds in `SoftwarePlaybackHost.memoryPacketStoreBudget`):
a 96 MB forward window, and up to 128 MB of played history kept volatile, so the
kernel may reclaim it under pressure and a seek into reclaimed history is a normal
cache miss. On an Apple TV 4K the disk store's appends took 100 to 600 ms while a
download ran, the demux thread stalled behind them, and video it had already
parked reached the decoder late; AVPlayer keeps its progressive-download cache in
memory on tvOS too. No session files and no disk retention claim are made there.

The cache frontier is the intersection of selected audio and video presentation
coverage containing the playhead. Unknown intervals remain unknown; byte counts
are not converted to guessed seconds. H.264 and HEVC use a bounded presentation
reorder queue and confirmed successor timestamps, because a VFR packet's decode
duration can be shorter than the picture's actual display hold, and a container
that rounds durations down (41 ms against 41/42 ms deltas at 23.976 fps) would
otherwise split the coverage at every frame (#613). Larger discontinuities,
invalid or unexpectedly late timestamps invalidate or split coverage. Other
codecs retain strict packet-duration coverage. Coverage keeps its history behind
the playhead for backward cached seeks, up to 4096 ranges per stream; a full
coverage forgets the ranges wholly behind the playhead rather than stop
describing new packets. Without a proven compressed frontier, the existing
decoded-cushion fallback still applies.

A cached seek restores a retained keyframe cursor, including an earlier keyframe
for available preroll, and keeps the producer at its existing source frontier.
A cache miss clears coverage and repositions the demuxer; discarding the spool
is the worker's job, not the seek's, because removing every retained chunk costs
more the longer the session has kept them and no seek waits on that work.
Consumer generations
and source epochs are separate: a cached seek must not discard an in-flight
producer packet, and a superseded consumer must not steal the first packet of a
new source epoch. Admission applies equally to packet, EOF, error and delayed
end-of-media callbacks. At EOF the VOD consumer parks until a new seek or stop.

This changes engine cache semantics, not host UI. Software `bufferedPosition`
and `LiveTelemetry.cachedBytes` describe compressed coverage/residency;
`forwardBufferSeconds` remains the native player's loaded-range metric and
`displayCushionSeconds` still describes the small decoded queue. Native HLS
`residentRanges` and live DVR are not repurposed.

The producer owns a thread rather than a dispatch queue, because a queue's QoS
is fixed at creation while this producer's urgency changes inside one
long-running loop. It starts latency-critical, drops to the efficiency class
once the reserve reaches half the forward window, and returns to
latency-critical at a quarter of it, the instant a consumer parks in a read, or
whenever the reserve cannot be expressed in seconds at all, which is the state a
cold start and a seek landing are both in. The two depths differ so a source
sitting on one threshold does not retune once per packet. A permanently demoted
producer is an inversion the scheduler cannot see, since the consumer waits on
an `NSCondition` and a condition donates no priority to the thread it waits for,
and it was measured costing throughput rather than only fairness: on an idle
8-core M1 with the consumer's decode cost made negligible, the efficiency-class
producer drained 147 MB of an 80 Mbit/s source in 60 s where the responsive one
drained 438 MB, with seven cores free the whole time. Lifting only the thread's
disk-I/O policy on the same class restored it to 528 MB, which names the cause:
the class throttles the spool writes the producer makes for every packet, so the
effect needs no contention for cycles. The adaptive choice keeps what the
demotion was for; over a 100 s steady state it retains 2165 ms of
efficiency-class CPU against 2145 ms for a permanently demoted producer and 1 ms
for a permanently responsive one, at identical total CPU. Consumer starvation is
reported as its own rate-limited line, so a source that cannot keep up is
readable instead of inferred from a stalled clock.

The CI packet-cache step runs the standalone coverage, VFR successor, disk FIFO,
read-ahead concurrency, host admission and AVPacket-envelope regressions. These
use generated numeric data and temporary records, not private video fixtures.

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

## Blocking work and the cooperative pool

Engine code that blocks its thread (a demuxer open or packet read, a FIFO write under
backpressure, a `close()` that joins a pump, a `waitForFinish`) never runs on the Swift
cooperative pool. That pool has one thread per core and does not grow, so each blocked job takes
a core's worth of async work out of the whole process, the host app's included. A detached engine
task is therefore created through `BlockingWork.detached` (`BlockingWork.swift`), never
`Task.detached`: the task prefers `BlockingExecutor`, which runs its jobs on GCD's global queues,
and GCD adds a thread when one blocks. The task otherwise behaves as before (it awaits, hops to
the main actor, is cancelled). `BlockingWorkTests` pins both halves, and a test fails the build
of any `Task.detached` that comes back into `Sources/AetherEngine`.

The trigger was CI: on a 3-core runner the suite parked all three pool threads for half a minute
at a time, until a 120 s time limit fired at 151 s because its watchdog is a task on the same
pool. `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` narrows the pool to one thread and reproduces that
on any Mac; the full suite has to pass under it.

Persistent HTTP/1.1 body reads inherit the caller's isolation through
`PersistentHTTP1Connection.readChunk`'s isolated parameter. Its framing can own a
mutable chunked-body decoder, so a cancellation-handler read must not send that
single-consumer state to a different executor. Cancellation still abandons the
body through its existing drain-or-close path.

## Subtitle recognition scheduling

Bitmap subtitle OCR awaits each image's recognition on a dedicated utility thread.
`VNImageRequestHandler.perform` blocks while Vision completes its own work; calling it directly
from a Swift task, even `Task.detached`, can exhaust the cooperative executor. Embedded and
sidecar OCR workers therefore suspend during recognition rather than occupying that executor.
One process-wide admission slot stays occupied until the native operation actually returns,
including after cancellation. Cancelled queued callers leave without starting another thread.
Completed cues remain in the store; an embedded worker cancelled mid-batch invalidates that
batch's advanced cursor so re-selection collects it again rather than skipping unfinished cues.

## Source map

```
Sources/AetherEngine/
├── AetherEngine.swift                       Engine core: stored state, load dispatch, transport, stop/seek, track selection
├── AetherEngine+Probe.swift Static probe machinery: probe(url:/source:), shared HDR10+/Atmos detail orchestration, swDecodeProbe, format / frame-rate / codec-label detection
├── ProbeControl.swift Opt-in whole-probe input/packet/deadline accounting and caller cancellation; native callbacks retain their control until synchronous work returns
├── AetherEngine+Loading.swift               The per-backend loaders (remote-HLS, native, software, audio, audio-native) + reload
├── AetherEngine+OptionalComponents.swift   `AetherEngine.OptionalComponent`: which trait-gated components (object audio, dual-layer DV, DV still reshaping) this build carries
├── AetherEngine+Subtitles.swift             Embedded + external subtitle pipeline (packet-store drainer, cue apply / prune, `closeOpenEndedCues` taking a placeholder end from the next stored packet, or retiring it at the reconstruction window when the store has none, external track registry + unified selection routing, #88). Every embedded stream is tapped off the session demuxer into `SubtitlePacketStore`; a playhead-paced drainer decodes the selected stream (both channels, text and bitmap, VOD and live) into the overlay, riding producer seeks/restarts by construction, which replaced the side-demuxer reader and its recovery machinery outright (#112 rework); a VOD-only forward prefetcher extends store coverage past the producer park to the 60 s drain lead for host advance sync offsets (#151), plus a margin so the harvest leads the decode and the set at the window's edge can take its authored end from the store (#362); side readers yield the source link to the video path while it is fetching or seeking (#240, `SideReaderLinkPolicy`); the drain tick states how far display-state determination has advanced on the absolute source axis, fenced by load + seek generation, so a host or conformance harness can tell "determined, and empty" from "not read yet" (#250, `AetherEngine+SubtitleResolution.swift`)
├── AetherEngine+ClosedCaptions.swift        In-band CEA-608 closed captions + A53/SEI extraction: ClosedCaptionTap (read-only producer observer) + cue mirroring (#77, #131)
├── AetherEngine+Live.swift                  Live window publishing, edge snap, resume clamp, scrub thumbnails
├── AetherEngine+Diagnostics.swift           Memory probe + live-telemetry bridge
├── AetherEngine+SubtitleDelivery.swift      Emission of the #357 subtitle-delivery statement: one line per change of what a drain tick DID with the packets it found (`outcome=` noDecoder / empty / undecodable / held / duplicate / trimOnly / published), plus the counts it was derived from. Complements #250, which states how far determination reached: the drain cursor advances over packets that decode to nothing, so resolution can keep pace with every seek landing while the overlay never changes, and the two lines together separate those cases
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
├── AetherEngine+LiveSubtitleRenditions.swift Live path: the upstream master's `EXT-X-MEDIA:TYPE=SUBTITLES` renditions surfaced as tracks (synthetic ids from 300000) and, once one is selected, fetched as WebVTT segments onto the host-overlay surface; cues are placed by the playlist geometry the renditions share (`EXT-X-PROGRAM-DATE-TIME`), anchored at the playhead rather than at the head of a two-hour DVR playlist, and re-anchored when a producer seam moves the source axis (#359)
├── AetherEngine+SubtitleOCR.swift           Arming, per-ordinal cursors and the MainActor tick of the bitmap-subtitle OCR worker that fills a text rendition for PiP / AirPlay / external display while a PGS / DVB / DVD track's rendition is selected natively (PiP / AirPlay / external display)
├── AetherEngine+AudioShaping.swift          `setAudioShaping(_:)`: audio shaping as a live setting, every change a session-preserving rebuild with presses folded into the one in flight (AE#923)
├── AetherEngine+TeletextPage.swift          The teletext caption page as a live setting: `setTeletextPage(_:)` rebuilds the drain decoder of every channel currently showing a teletext track and leaves the others alone, so a page libzvbi does not flag as a subtitle page is correctable without leaving the channel (#364)
├── AetherEngine+ScrubThumbnail.swift        Cache-backed scrub still for the active native session: decodes from already-produced SegmentCache bytes, so single-connection sources (debrid / torrent links) that refuse the FrameExtractor's second demuxer still get previews (#106)
├── AetherEngine+SoftwareNowPlaying.swift    Builds the software host's Now-Playing publisher when the app set `ownsSoftwareNowPlaying` (primary role only) and publishes `softwareNowPlayingActive`
├── SeekEvent.swift                          One statement about a seek's lifecycle (outcome plus the target it belonged to): `isSeeking` / `seekTarget` are a level signal, and a level cannot say why it fell (#38 follow-up)
├── StartupProgress.swift                    The nine-checkpoint startup ladder behind `$startupProgress` (#361): each value is recorded by the code that finishes the work it names, never by a timer, so a determinate loading bar holds through a slow stretch and jumps through a skipped one. A path that skips work is credited by the checkpoint it does reach, which is why the ladder is one ordered axis rather than a per-path set
├── SubtitleSessionCarryover.swift           Subtitle session state carried across an engine-initiated `reloadAtCurrentPosition` (AirPlay LAN swap, background-return reopen), which otherwise rebuilds the session from `LoadOptions` alone (#170)
├── BackgroundTeardownSelection.swift        The session selection a teardown hands to the reload that follows it, for the one case where teardown and reload are not the same call: the paused-background teardown (#127, #357)
├── Audio/
│   ├── AtmosConfirmationWorker.swift        LoadOptions.confirmAtmos: runs the bounded JOC pass on a side demuxer after the session is up, one E-AC-3 track at a time, and republishes audioTracks via a source-keyed ledger (#214); declined on an origin limited to one request, sequentialOrigin and heldSourceConnection, re-checked per track
│   ├── AtmosDetectionProbe.swift            Opt-in bounded E-AC-3 JOC decode pass behind probeDetectingAtmos: AtmosDetectionOptions caps, one decoder, no playback session (#214)
│   ├── AudioAVPlayerHost.swift              Audio-only path: bare AVPlayer host for whitelisted codecs, owns the persistent per-player MPNowPlayingSession (tvOS / iOS); publishes the rebuffer axis (`waitingToPlayAtSpecifiedRate` / `AVPlayerItemPlaybackStalled` after first play) that the engine folds into `isBuffering`
│   ├── AudioBridge.swift                    Native path: decode + re-encode per `AudioBridgeMode` (EAC3 5.1 default or lossless FLAC opt-in) for source codecs that can't stream-copy into fMP4
│   ├── AudioClockAnchor.swift               SW path: sample-count PTS anchor so consecutive buffers abut exactly; re-anchors on >100 ms drift (AVSampleBufferAudioRenderer crackle, #89)
│   ├── AudioDecoder.swift                   SW path: libavcodec → PCM → CMSampleBuffer with channel-layout tagging that names the resampler's own order (#401)
│   ├── AudioOutput.swift                    SW path: AVSampleBufferAudioRenderer + Synchronizer (master clock)
│   ├── AudioPlaybackHost.swift              Audio-only path: FFmpeg demux + decode into AVSampleBufferAudioRenderer for codecs off the whitelist
│   ├── AudioTailPadding.swift               Native path: silence in the delivered codec from where a title's audio ends to where its video does, written into the final segment at end of file, because AVPlayer ends an item when its audio runs out (AE#847)
│   ├── SoftwareAtmosRoute.swift             SW path: the pure choice of how a track's audio reaches the renderer (PCM decode, compressed E-AC-3 JOC, or TrueHD Atmos / DTS:X rendered into a bed as APAC or PCM) from codec, stream shape, live and `objectAudioRendering`
│   ├── SoftwareAudioProducing.swift         SW path: what the host asks of whatever turns an audio packet into renderer input; implemented by `AudioDecoder`, `SoftwareEAC3Passthrough` and `SoftwareAPACProducer`
│   ├── SoftwareEAC3Passthrough.swift        SW path: E-AC-3 JOC packets enqueued compressed to the audio renderer, with the `dec3` format description built from the stream, so the system's Atmos decoder gets the objects
│   ├── AtmosDecoderPrimer.swift             Registers the system's Atmos decoders in the process once (creates an AVPlayer), which the renderer needs before it decodes compressed E-AC-3 as Atmos
│   ├── Shaping/
│   │   ├── AudioShaping.swift               `AudioShaping` (channel cap, dialogue lift, compressor) and `AudioShapingState`, the host's request and the published answer (AE#923)
│   │   ├── AudioShapingMatrix.swift         The cap and the centre lift as one libswresample remix matrix
│   │   └── AudioShapingGraph.swift          The libavfilter graph after the remix: dialoguenhance + pan on stereo, acompressor, alimiter, aformat; runs on its own sample counter so its latency never reaches the timeline
│   ├── Spatial/
│   │   ├── SpatialBedOutput.swift           `SpatialBedFormat` (PCM or APAC, and the route rule `.render` uses), the bed buffers and packets, and `PCMBedPacker`, the 24-bit PCM sink beside `APACEncodePipeline`
│   │   └── SoftwareAPACProducer.swift       SW path: TrueHD Atmos / DTS:X rendered into a speaker bed through `SpatialAudioBridge` as APAC or PCM, the packets handed to the audio renderer as sample buffers
│   └── Tap/
│       ├── AudioTapController.swift         Lifecycle owner for one tap: owns the AsyncStream continuation + (native path) the LoopbackAudioReader; one per engine, re-install replaces it (#95)
│       ├── AudioTapDecoder.swift            FFmpeg decode of tap packets into mono Float32 48 kHz AVAudioPCMBuffers (lazy resampler, own lock discipline)
│       ├── AudioTapPCMConverter.swift       SW path: AVAudioConverter sink mirroring AudioDecoder PCM into the tap's mono 48 kHz format, carrying the source channel layout and self-checking the mixdown (#400)
│       ├── AudioTapTypes.swift              AudioTapBuffer value type (single-consumer @unchecked Sendable) + pure loopback pacing decision
│       ├── AudioTapHLSVariantResolver.swift Remote-HLS tap: resolves the active audio rendition / muxed variant from the master playlist (#95)
│       ├── AudioTapHLSFetcher.swift         Remote-HLS tap: segment fetch + AES-128 clear-key decrypt for self-contained TS / fMP4 segments (#95)
│       ├── AudioTapHLSReader.swift          Remote-HLS tap worker: playhead-follow reader decoding fetched segments (VOD + live) (#95)
│       ├── AudioTapReaderSelection.swift    Pure per-session reader choice (loopback vs remote-HLS vs none) backing audioTapHasDeliverySource (#95)
│       ├── LoopbackAudioReader.swift        Native-path tap worker: pulls fMP4 segments from SegmentCache near the playhead, decodes their audio out-of-band on a utility thread (cannot stall playback)
│       └── AudioTapMonotonicGate.swift      Enforces a strictly monotonic, non-overlapping `sourceTime` timeline on consecutive tap buffers; SpeechAnalyzer ends its input loop on the first overlap, and segment-seam decoder priming produces sub-threshold backward ones (#95 follow-up)
├── Decoder/
│   ├── A53ReorderBuffer.swift               Decode-to-presentation reorder for SEI caption groups (#131)
│   ├── A53SEIParser.swift                   A53/GA94 cc_data extraction from H.264/HEVC SEI NALs (#131)
│   ├── DualLayerPictureAlignment.swift      SW FEL path (`DualLayerDolbyVision` trait): pairs each EL picture with the base picture of the same display slot (POC), falling back to access-unit pairing (#702)
│   ├── FrameSideDataRing.swift              SW FEL path (`DualLayerDolbyVision` trait): fixed ring of per-frame RPU parameters and display metadata keyed by timestamp (#702)
│   ├── OrderedDelivery.swift                SW FEL path (`DualLayerDolbyVision` trait): hands composed frames from the Metal completion queue to the renderer in decode order, with an epoch for seeks and a stall guard (#702)
│   ├── CCDataParser.swift                   Parses the bare cc_data triplet stream from a demuxable CEA-608 caption track (#77)
│   ├── CEA608Decoder.swift                  In-house CEA-608 line-21 decoder (field-1 / CC1), validated against FFmpeg ccaption_dec.c (#77)
│   ├── DeinterlaceFilter.swift              SW path: persistent bwdif / yadif libavfilter graph, engages on the first interlaced frame
│   ├── EmbeddedSubtitleDecoder.swift        Inline subtitle decode from demuxed packets; opens DVB teletext with libzvbi_teletextdec text-format options (#107)
│   ├── InterlaceProbe.swift                 Decodes a sample and applies the deinterlacer's own engagement predicate, so a declared field order that no frame backs up (PsF) stops costing a SW decode (#232)
│   ├── VideoRoutingPolicy.swift             Pure codec-and-field-order dispatch rule: AV1 gated on HW, VP9/VP8/MPEG4/MPEG2/VC1 always SW, interlaced H.264 SW so bwdif can deinterlace (#107, verified against decoded frames on VOD, #232), plus a second-stage gate routing H.264 High 4:2:2/4:4:4/10 + HEVC Rext to SW where VideoToolbox has no HW decoder (#2)
│   ├── HardwareVideoDecoder.swift           SW path: VideoToolbox HW HEVC / AV1 decoder for sources routed away from AVPlayer
│   ├── DualLayerVideoDecoder.swift          SW path: Dolby Vision Profile 7 FEL (`DualLayerDolbyVision` trait). Two HardwareVideoDecoders (a base layer, typically 4K, and an enhancement layer, typically 1080p) paired by HEVC picture order with the packet's RPU, composed on Metal by `DoviFelComposer`, delivered in decode order with the Profile 8.1 RPU attached per frame; see [dolby-vision-fel.md](dolby-vision-fel.md)
│   ├── SoftwareVideoDecoder.swift           SW path: libavcodec/dav1d → CVPixelBuffer (NV12 / P010), HDR10+ side data; 10-bit AV1 reaches P010 through `GPUFrameConverter`
│   ├── GPUFrameConverter.swift              SW path: a 10-bit AV1 frame into P010 in one Metal pass, its film grain applied there (dav1d exports the grain instead of applying it); `sws_scale` stays the fallback
│   ├── AV1FilmGrain.swift                   The per-frame grain tables (templates, scaling functions, block offsets), computed on the CPU as dav1d computes them
│   ├── AV1FilmGrainShaderSource.swift       The Metal kernels: dav1d's per-pixel grain and the P010 write
│   ├── AV1GaussianSequence.swift            AV1's Gaussian_Sequence (specification 7.18.3.3)
│   ├── SubtitleDecoder.swift                Sidecar URL one-shot decode; decodes several streams of one container in a single pass (#266); a bitmap stream is read into packets instead (#921)
│   ├── VideoDecoderTypes.swift              DecodedFrameHandler typealias + VideoDecoderError
│   ├── DeinterlaceHardwareWarmup.swift      Demand-driven process-wide prewarm of the deinterlace filter's hardware pipeline; only potentially interlaced `.auto` loads start and await it. Progressive sources and forced-software deinterlace skip it. Same-title reloads preserve even a decoded progressive verdict; the background selection snapshot retains that decision for a custom-reader reopen, while URL reloads probe afresh. Actual disc-title changes re-evaluate reopened metadata. A source declared progressive that later supplies interlaced frames still deinterlaces on demand, paying the cold graph build at that first frame
│   └── PixelAspectPolicy.swift              Whether a declared sample aspect ratio deserves to be believed: a ratio-magnitude gate (#177, live TS carrying 1088:1), which admits precise or unreduced ratios such as 759:712, plus a display-aspect gate judged against the frame the SAR applies to, since 2:1 is right on 960x1080 and wrong on 1920x1080 (#290)
├── Demuxer/
│   ├── AVIOProvider.swift                   Internal seam over a custom-AVIO byte source; AVIOReader and CustomIOReaderBridge both plug into the Demuxer through it, incl. the bounded-seek read deadline and the resolved byte size backing the byte-estimate seek fallback (#112)
│   ├── AVIOReader.swift                     URLSession-backed avio_alloc_context, three modes: persistent forward-streaming connection with reconnect-on-drop (playback, incl. live), discrete Range chunks (still extraction), single sequential GET with backpressure (non-live sources without Content-Length). Optional read deadline bounds a degenerate matroska Cues seek. Cold start on a non-faststart MP4 keeps the open window across the parse seek to the trailing moov (so the return trip to the first sample is a copy, not a third connection) and issues one speculative 64 KB suffix range alongside the open, rejected at the response header unless it is a well-formed 206. A read landing in that range waits for the fetch rather than connecting past it, bounded by the measured cost of one round trip against the origin, because the demuxer reaches the tail before a fetch issued at the same instant can land (#281). A suffix-range denial is remembered per origin only from the origin's answer to the range form (a 200, a 416), never from a 403/404/429/5xx; a source refused with an HTTP status fails the open typed (`AVIOReaderError.httpStatus`) instead of handing FFmpeg the error page (#378). A post-redirect target is pinned from its first 2xx and dropped again on an auth-expiry status, on an unproductive-reconnect streak, and on a bounded grace of rate-limited attempts (#307/#380); a pin that has carried no bytes for a minute is dropped by its FIRST refusal instead, because the lingering-slot 509 that grace exists for cannot arise with nothing of ours in flight (#392)
│   ├── ResidentSpan.swift                   Bytes already in memory that a read can be served from without a round trip: the open window parked across a parse seek, and the speculative tail fetch. Not a cache (no fetch-on-miss, no eviction, no block alignment); it either covers an offset or it does not (#281)
│   ├── CustomIOReaderBridge.swift           Bridges a host-supplied IOReader into avio_alloc_context read / seek callbacks, with the same read deadline and reversible read abort as AVIOReader so bounded seeks also bound (and unwedge) disc-adapter sources
│   ├── Demuxer.swift                        libavformat wrapper; seek + bounded seek (deadline-capped) + byte-estimate positioning fallback for index-less containers (origin-corrected onto the file-relative time axis, fixed early bias in seconds, landing verified by a packet-PTS probe with proportional correction, and a sticky per-demuxer timestamp-seek lockout once the mechanism proves broken, #112). Per-open `DemuxerOpenProfile` budgets `find_stream_info` (probesize / max_analyze_duration), caller-overridable on the main playback open via `LoadOptions.probesize` / `maxAnalyzeDuration`. The native text readers' side demuxer sets `skipStreamInfo` to drop the `find_stream_info` pass entirely (codec_id / codec_type come from the container header / PMT at open); the reader runs a bounded `resolveStreamInfo()` on demand only if its target stream's codec is genuinely unresolved at open (#87). The playback open parks known PGS tracks (whose width only a decoded composition segment can supply) and undecodable audio as ATTACHMENT for the duration of `find_stream_info`, so neither holds the pass to its byte ceiling (#466, #858)
│   ├── RedirectHeaderPolicy.swift           Per-header redirect replay policy for AVIOReader's URLSession delegates and, through `EngineTLS`'s session-level delegate, for every other engine session (audit NET-108): Range and non-credential extra headers survive cross-host redirects (header-dependent proxies, #8), credential headers (Authorization, Cookie, Emby/Jellyfin tokens) are replayed only to a same-host target with no TLS downgrade and scrubbed otherwise, so presigned redirect targets neither 400 on conflicting auth nor see the media-server token (#126). `CredentialScope` applies the same rule to every URI a playlist names: the relay, the #316 subtitle proxy, the audio tap and the live rendition fetch send the credentials only to the URL the host handed over, and allowing a fetch never grants them (audit NET-109)
│   ├── SlowReadDiagnostics.swift            One-shot localization of a pathologically slow AVIOReader.read() (detour fetch / connStall / reconnect / backoff / dropped-generation bytes), #93 restart latency
│   ├── SourceThrottle.swift                 Pure virtual-clock leaky-bucket rate limiter on the source read path (slow-CDN simulation for aetherctl --throttle); unit-testable without sleeping
│   └── SourceContentLengthCache.swift       Memoizes a source URL's resolved total byte length across demuxer opens, so a subtitle side demuxer opening the same origin later inherits the size the video producer already resolved (#112)
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
│   ├── AudioTapProbe.swift                  Headless native-session tap verification (#95): LoopbackAudioReader decode to mono 48 kHz WAV; backs aetherctl audiotap
│   ├── AVFoundationOffMain.swift            Off-main hop for batched synchronous AVFoundation property reads (#134): figplayer-backed getters are sync XPC round trips, and a momentarily busy media server otherwise blocks the main thread into a watchdog kill
│   ├── AVPlayerItemDiagnostics.swift        Item-bound log snapshots, coalesced notification/failure reads, bounded shared admission and asynchronous counter retirement
│   ├── MallocBlockCensus.swift              In-process census of live malloc blocks by size class (#220), so a step in resident memory can name the allocation instead of being guessed at from a block count and a total
│   ├── MallocBlockCensusTrigger.swift       Jump-triggered capture of that census: every kill on record is flat and then steps inside a single 30 s memprobe sample, so a periodic sampler can never catch the allocation (#220)
│   ├── ThreadCPUSampler.swift               CPU time per thread group between two samples (consumed time, ended threads included), the `cpuprobe` line beside every memprobe; public so a host can profile its UI from a field log
│   ├── VMRegionCensus.swift                 Per-`user_tag` census of the dirty + swapped pages `phys_footprint` counts, delta against the session's first tick: names the region a rising footprint rose in when every itemized bucket (heap census included) is flat, which is the state AE#445 kept ending in
│   └── SubtitleDeliveryStatement.swift      Value + formatter for the #357 line stating what a drain tick did with the packets it found, so "nothing appeared on screen" is attributable from outside instead of inferred from an absent log line; `harvestHole` names the tick that decoded nothing on purpose, which would otherwise read as `empty` (#362); `landingWithheld=` counts the sets refused the landing because the ground between them and the playhead was never read (#416)
├── Disc/
│   ├── DiscReader.swift                     Disc detection + routing: local `.iso` URLs and custom ISO readers into the demux path; enumerates titles and threads the selected one (DVD vs Blu-ray)
│   ├── DiscImageMediaType.swift             The `Content-Type` values (and, under `application/octet-stream`, the sector-16 volume signatures) that send an extensionless HTTP URL to the disc adapter, and the process memo of URLs found to be discs (AE#860)
│   ├── DiscMetadata.swift                   Public `TitleInfo` / `ChapterInfo` plus the internal disc title + chapter model (45 kHz ticks, extent keys)
│   ├── ISO9660Reader.swift                  Read-only ISO9660 bridge-filesystem reader (DVD-Video images)
│   ├── DVDIFOParser.swift                   DVD VMGI TT_SRPT title list + each VTS IFO program chain (per-title duration + chapters) and stream attribute tables (track languages, declared subpicture streams)
│   ├── DVDSubpictureAssembler.swift         Joins a DVD subpicture's PES fragments for the streams the engine declares from the IFO (the `dvdsub` parser's job, which libavformat only does for streams it created)
│   ├── DVDTitleSelector.swift               Groups DVD title sets' content VOBs into selectable titles (whole-VTS, largest first)
│   ├── ConcatIOReader.swift                 Synthetic seekable IOReader concatenating byte extents (DVD VOBs / Blu-ray M2TS clips) into one source
│   ├── UDFReader.swift                      Read-only UDF 2.50 reader (Blu-ray BDMV, including the metadata partition and fragmented-file allocation descriptors)
│   ├── MPLSParser.swift                     Blu-ray `.mpls` playlist parser (clips, duration, PlayListMark chapters, STN-table track languages)
│   ├── BDTitleSelector.swift               Enumerates Blu-ray playlists as selectable titles (longest first; short menu / decoy playlists filtered)
│   ├── DiscRecognitionCache.swift           Memoises `DiscReader.wrap` per URL + title index so disc recognition does not re-run on every subtitle / track switch (load-bearing for remote-ISO track switches, #76)
│   └── DiscInspector.swift                  Diagnostic mirror of `DiscReader.wrap` for `aetherctl disc-inspect` (titles, chapters, recognition stages)
├── Display/
│   ├── DisplayCriteriaController.swift      AVDisplayManager content-rate / dynamic-range hints (native path)
│   └── FrameRateSnap.swift                  Snap to standard rates (23.976, 24, 25, 29.97, 30, 50, 59.94, 60)
├── FrameExtractor/
│   ├── AetherEngine+FrameExtractor.swift    makeFrameExtractor() convenience for the currently loaded URL
│   ├── DolbyVisionStillConverter.swift      `DolbyVisionStillReshaping` trait. Applies the RPU-carried DV colour transform to a DV P5 / P10.0 base-layer frame (IPT-PQ-C2, not YCbCr) so scrub stills lose the green + magenta cast (#103)
│   ├── FrameExtractor.swift                 Off-playback still extraction actor: serial decode queue, cancel-supersede, idle-close
│   ├── FrameDecodeContext.swift             Isolated FFmpeg demux + decode + sws_scale → CGImage (thumbnail / preview / snapshot)
│   ├── FrameCache.swift                     Bounded LRU: mode-isolated stores, second-bucketed thumbnails
│   ├── FrameTypes.swift                     FrameMode (.thumbnail / .preview / .snapshot)
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
│       ├── ByteFIFO.swift                   Bounded blocking byte queue between the fetch loop and the demux thread; empty writes are no-ops, invalid read lengths return an error, and only a finished, drained queue returns EOF
│       ├── HLSIngestError.swift             Typed terminal errors (encrypted, fMP4, unreachable, invalid, stalled)
│       ├── LiveIngestSourceInfo.swift       Internal seam: upstream segment cadence (shapes TARGETDURATION + blocking-reload eligibility) and DualSourceMergeOrder for the dual-source DTS merge
│       ├── HLSVODIngestReader.swift         Ingest reader for an immutable ENDLIST playlist: seeks restart the source at the segment preceding the requested playlist time, on an elapsed-media-time axis (the EXTINF sum) rather than the container's PTS
│       ├── HLSCarriageProbe.swift           Reads a live source's video carriage from its playlist and the first segment's PMT, so the #168 verdict is available while the native mount is still inside its watchdog grace instead of seconds after it (#293, #296)
│       └── LiveArrivalCadenceMeter.swift    Measures the observed segment-arrival cadence of a live upstream (interval between batches of new segments plus the currently open gap), the signal LL-HLS shaping trusts instead of a self-reported TARGETDURATION. The closed intervals are reported separately, because the seal may not be taken from a gap the first-serve gate is itself holding open (AE#447)
├── Native/
│   ├── AudioLookahead.swift                 SW live feeder audio look-ahead pump policy + cursor state: audio lead decoupled from video decode pace, live-edge underrun rebuffer (#107)
│   ├── Issue93ItemDeathRevive.swift         Bounded revive budget (`ItemDeathReviveGate`) for items killed by accumulated -12889 media timeouts (`failedToPlayToEndTime`, #93 round 3)
│   ├── MasterFallbackDecision.swift         Pure master → media playlist fallback decision (#98, #130): maps a master-rejection item failure (-11868 external-SDR, -11848 HDR-on-SDR, -1002 all variants filtered at parse) to a reactive re-serve
│   ├── NativeAVPlayerHost.swift             Native path: AVPlayer host bound to the loopback HLS-fMP4 URL; awaits real seek landing (deadline-bounded, first resume wins, #129), suppresses stale clock during in-flight seek
│   ├── SoftwarePathEscalation.swift         Native path: the last rung. A CoreMedia-domain failure (AVPlayer refusing the MEDIA, not the source) is offered to the engine's own decoder once per session instead of ending it, since every recovery above reloads the same bytes (AE#561)
│   ├── RemoteHLSMediaSelection.swift        Remote-HLS bypass (#154): pure loopback→bypass reroute decision for non-live m3u8 sources (FFmpeg has no network) + legible AVMediaSelectionGroup → `subtitleTracks` mapping (synthetic ids from 200000)
│   ├── SoftwarePlaybackHost.swift           SW path: demux loop + decoders + renderer + synchronizer orchestration
│   ├── SoftwarePlaybackHost+AudioProducer.swift SW path: picks and builds the audio producer for the session's track, with every unavailable Atmos route landing on the PCM decode (logged)
│   ├── VideoSessionRetryPolicy.swift        SW path: when a refused video-session rebuild is retried while the picture is on screen: four quick attempts at keyframes, then one every 30 s, never a terminal error
│   ├── SoftwareFlushRecovery.swift          SW path: pure rules for putting a flushed or failed video/audio output queue back to work (triggers, seek versus wait for the next keyframe)
│   ├── AirPlayPlaylistDecision.swift        Pure decisions for the wireless-AirPlay loopback rewrite: which of master / media a receiver is handed, and whether a route change rebuilds the session or swaps its item (a sequential origin, a forward-only live source), kept separate and testable offline like `MasterFallbackDecision` (#86, #227, #526)
│   ├── NativeLegibleDeselectPin.swift       Keeps AVKit's ready-time legible auto-select from engaging a rendition the host never asked for (Sodalite#38), and publishes the caption requests the system makes on its own as `systemCaptionRequest`, by BCP 47 language rather than by ordinal (Sodalite#65)
│   ├── RemoteHLSFormatDetection.swift       Dynamic-range classification for the `nativeRemoteHLS` bypass, read back from AVPlayer's own track format instead of a second origin probe, which that path exists to avoid (#168)
│   ├── RemoteHLSStreamDescription.swift     The rest of that read-back for stats panels: delivered dimensions, colour description and avcC/hvcC profile as a `VideoStreamFormat`, and the item's audio tracks as `TrackInfo` (codec, channels, rate, dec3 JOC)
│   ├── RemoteHLSIngestFallback.swift        Reroutes a bypass session onto the live-ingest loopback when the master advertises HEVC / DV / AV1 but delivers MPEG-TS, carriage AVFoundation builds no video track for (#168)
│   ├── RemoteHLSMasterRewrite.swift         Declares host-supplied sidecar subtitles as legible renditions on the bypass by rewriting the origin master, since media selection on an HLS asset comes from the playlist and nowhere else (#316)
│   ├── RemoteHLSSubtitleProxy.swift         Stands a loopback origin in front of that remote master: two playlist GETs, a rewrite and a socket, and anything that does not line up keeps the plain origin URL (#316)
│   ├── RemoteHLSSubtitleProvider.swift      Serves only what the proxy injected (`/master.m3u8`, `/subs_N.m3u8`, `/subs_N_0.vtt`); the A/V variants still point at the origin, so no media byte moves off it (#316)
│   ├── RemoteHLSReadinessDeadline.swift     The terminal state the bypass never had: an origin that answers everything while AVFoundation can build no track from what it serves, which no failure signal ever reports (#334)
│   ├── RerouteVerdictMemory.swift           Bounded, expiring memory of master URLs whose carriage watchdog fired, so a retune after an ingest death relands on the working path instead of re-paying a full mount plus grace (#199)
│   ├── SWClockAnchorPolicy.swift            Where the SW demux loop anchors the synchronizer clock on the first decoded sample: verbatim for files and resumes (intrinsic A/V lead-in survives), at the sample for a mid-stream-joined source (#107); a sample BEHIND the anchor is resume preroll and never moves it (AE#724)
│   ├── SeekResumeIntent.swift               Whether a seek on a demuxer-driven host re-arms the clock at `lastRate` or parks it at 0, for the second seek issued inside the window its predecessor cleared (#292)
│   ├── SoftwareBufferFrontier.swift         How far ahead of the clock the software path is actually holding decoded video, and how that folds into the `bufferedPosition` a host reads (#303)
│   ├── SoftwarePiPSource.swift              Everything a host needs to build an `AVPictureInPictureController` content source around the software path without AVKit entering the engine: the layer plus the four transport answers behind the sample-buffer delegate
│   ├── SoftwareNowPlaying.swift             Software-host Now-Playing: state-to-card mapping, remote-command routing and the publisher, behind small protocols for the two process-wide centers so tests run on fakes; undoes only its own changes at stop
│   └── StartupReadinessGate.swift           Outcome of one startup-readiness attempt: the reloaded item reached a playable state, died, or ran out the settle window without doing either
├── Network/
│   └── HLSLocalServer.swift                 Native path: local HTTP server (all interfaces for AirPlay, every path behind a per-session token, loopback URLs handed to the local player) serving playlist + segments. It writes the master, so the audio rendition's attributes are decided here: `EXT-X-MEDIA:TYPE=AUDIO` carries `LANGUAGE` (AE#458) and `CHANNELS`, the latter answered by the segment provider (`"16/JOC"` for a stream-copied E-AC-3 JOC track, the served bed count otherwise) and omitted entirely when the provider has no rendition to attribute. An untagged track has no rendition unless it is a stream-copied JOC one, which gets one without `LANGUAGE` for the sake of its `CHANNELS` (AE#726)
├── Renderer/
│   ├── SampleBufferRenderer.swift           SW path: AVSampleBufferDisplayLayer + B-frame reorder, HDR10+ attachments; `flush(removingDisplayedImage:)` holds the last frame through a seek (#90); the decode thread reaches the layer only through its `sampleBufferRenderer`, taken once on the main actor (#351)
│   └── SubtitleFrameCompositor.swift        Composites active cues into decoded software-path frames while PiP is active, since the system PiP window renders only the sample-buffer layer; playback wins, every failure path returns the original buffer untouched
├── Subtitles/
│   ├── ASSScriptBuilder.swift               Reassembles raw ASS event cues + TrackInfo.assHeader into a complete script for whole-file renderers
│   ├── ExternalSubtitleTrack.swift          Host-facing descriptor for external subtitle files registered as first-class tracks (synthetic TrackInfo ids, #88; sourceStreamIndex addresses one stream of a container URL, #266)
│   ├── Issue100PGSStaleArrival.swift        Holdback (`PGSStaleArrivalGate`) for PGS cues arriving behind the playhead: catch-up bursts resolve via their successor's trim instead of flashing open-ended placeholder windows through the overlay (#100); the hold and the reconstruction candidate belong to one position, so a reset tick drops them before arming the next pass (#357, else the first post-seek trim republishes pre-seek history as the active line); a cue behind the playhead is eligible to be the landing's active line only where the harvest reports having read the ground between the two (`groundIsRead`, #416)
│   ├── MovTextSampleBuilder.swift           Stateless ASS/SSA → plain-text sanitizer for cue bodies, used by `WebVTTBuilder` when serving a native rendition; the name predates the in-band tx3g path, which was non-conformant for HLS and is gone
│   ├── NativeSubtitleCueStore.swift         Owns the decoded-cue array behind a native WebVTT subtitle rendition + the overlay tap feed; deduped, filled by the pump tap (embedded) or one whole-file decode (load-declared external, #88) (#55, Sodalite#32)
│   ├── SidecarBitmapSource.swift            A bitmap sidecar's packets in a store of their own, drained around the playhead like an embedded track (#921)
│   ├── SubtitleRectText.swift               Plain-text + raw ASS event-line extraction from subtitle rects, shared by the inline and sidecar decoders
│   ├── WebVTTBuilder.swift                  Builds a plain-text WebVTT body (ASS markup stripped) on the AVPlayer timeline for the separate HLS SUBTITLES rendition so AVKit renders subs in PiP (#15, #55)
│   ├── SubtitlePacketStore.swift            Session-lifetime retention of compressed subtitle packets harvested from the owning host's demux pump; written on the pump thread, read by the MainActor drainer, all state lock-guarded (#112 rework); `firstPTS(streamIndex:after:)` is where an open bitmap set reads its authored end, since a display set is closed by whatever packet follows it (#362); `hasReadSpan(from:through:)` says whether anyone READ a stretch, which is what every answer derived from the store's silence rests on (#416)
│   ├── SubtitleHarvestCoverage.swift        Which spans of the source the harvest runs actually read, one span per run, anchored where a reader positioned and extended as it goes. A PGS set claims the landing by the store being empty between it and the playhead; over ground nobody read that silence is not evidence, and the packets alone cannot tell the two apart (#416, the ledger #362 round 2 named and left unbuilt)
│   ├── SubtitleOverlayDrainer.swift         Playhead-paced decode planning for the overlay: reads packets from the store near the playhead into the existing apply path, so stale-arrival gate, trim state machine and retention stay playhead-relative (#112 rework); `harvestGapCut` stops a tick where the store's harvest ORDER breaks rather than where its gaps are widest, so a hole a restarted pump has not filled yet is waited on instead of skipped past forever (#362)
│   ├── SubtitleCaptionStyle.swift           The user's system caption style (font, size, colours, opacity, edge style) for the software host's text rendering, with `current()` and `observeChanges(_:)`; a field is set only where it differs from the system default
│   ├── SubtitleForwardPrefetcher.swift      VOD-only subtitle side reader filling the same store up to playhead + drain lead, past the producer's own forward park, so a host ADVANCE sync offset finds cues (#151)
│   ├── SideReaderLinkPolicy.swift           Who gets the source link when the video path and a subtitle side reader want it at once: on Matroska a "subtitle-only" reader still pulls every block off the wire, so the video path has priority with a bounded grace and a yield ceiling (#240)
│   ├── SubtitleImageOCR.swift               On-device recognition of bitmap subtitle images (PGS / DVB / DVD) into plain-text cues for the native rendition; lossy by design, the fullscreen overlay keeps the pixel-accurate bitmaps
│   ├── SubtitleOCRPendingState.swift        Pending-composition end resolution for the OCR worker, mirroring the sidecar semantics: a composition still open at the next composition or clear event ends at that event's PTS
│   ├── WebVTTCueSettings.swift              WebVTT cue settings (`line`, `position`, `align`) mapped onto `SubtitleTextPlacement`: libavcodec's decoder drops them from the ASS line it synthesises, the demuxer keeps them as packet side data (#233)
│   └── WebVTTSegmentParser.swift            One parsed WebVTT segment of a live SUBTITLES rendition: cue times are in the segment's own local clock (a counter providers run for days), and placement comes from the playlist geometry rather than the `X-TIMESTAMP-MAP` the spec offers (#359)
├── Video/
│   ├── HLSVideoEngine.swift                 Native path: session orchestrator (start/stop, producer construction + restart, shift handling)
│   ├── KeyframeStillLadder.swift            Native VOD: which keyframe the sparse scrub-still ladder reads next (one a minute, then every 30 s, nearest the playhead first) and whether the origin is idle enough to read it (nothing in flight or queued, no recent refusal, 30 s buffered), so `scrubPreviewFrame` can answer beyond the resident window on a one-connection plan
│   ├── HLSVideoEngine+AudioRoute.swift      Native path: stream-copy -> FLAC-bridge -> video-only audio cascade
│   ├── HLSVideoEngine+SegmentPlanning.swift Native path: keyframe / uniform segment plans, extradata + AAC fixups
│   ├── HLSVideoEngine+LiveReopen.swift      Native path: live source-loss recovery (capped-backoff reopen on the same timeline); VOD backpressure-wedge re-anchor + consumer re-engage nudge, which re-reads the rendered position at nudge time so the zero-tolerance seek never lands behind the on-screen frame (#115)
│   ├── CodecRoutePolicy.swift               Native path: DV / HDR / codec routing decisions (track types, CODECS strings, VIDEO-RANGE)
│   ├── AnnexBSampleConverter.swift          Native path: Annex-B HEVC samples rewritten to length-prefixed NALs by the session muxer, in-band VPS/SPS/PPS kept. movenc's own conversion under `hvc1` drops them, so a stream that sends a new PPS mid-title stopped decoding at the change (PR #703)
│   ├── DoviRpuConverter.swift               libdovi RPU surgery for both routes. Native path: per-packet Profile 7 → 8.1 rewrite (convert type-62 RPU, drop type-63 EL). SW FEL path: `separateDualLayers` also lifts the EL into its own packet and returns the composer's reshaping parameters plus the 8.1 RPU attached as display metadata
│   ├── DoviRpuConverter+Probe.swift         Diagnostic DV-conversion probe (`doviConvertProbe` / `DoviConvertProbeResult`), backs `aetherctl dovitest`
│   ├── HEVCPictureOrderCount.swift          H.265 picture order count (8.3.1) of one layer from parameter sets and first slice headers, no decoding; nil for anything it cannot follow (#702)
│   ├── DoviDisplayMetadata.swift            SW FEL path (`DualLayerDolbyVision` trait): sets `DolbyVisionRPUData` (the Profile 8.1 RPU minus its NAL header) and `DolbyCompatibilityID` (the CFString "1", never a number) on every emitted buffer, or clears both; tvOS consumes them in backboardd
│   ├── DoviDisplayMetadataDebug.swift       DEBUG-only pin test (`DualLayerDolbyVision` trait): substitutes a captured RPU on a duty cycle, the on-device consumption test
│   ├── DoviRpuSurvey.swift                  L1 / L2 display-metadata survey over a title's RPUs (no decode, no GPU); backs `aetherctl dvsurvey`
│   ├── AetherEngine+FelProbe.swift          `DualLayerDolbyVision` trait: FEL decode probe backing `aetherctl feltest`, and the `--cycle-el` residual switch
│   ├── AetherEngine+DolbyVisionTest.swift   DEBUG-only, `DualLayerDolbyVision` trait: `@_spi(Diagnostics)` hook (not host API) that arms the pin test from a debug menu or `aetherctl play --dv-pin`
│   ├── Metal/                               `DualLayerDolbyVision` trait only
│   │   ├── DoviFelChromaFormat.swift        Chroma sampling of the composed frame: 4:2:0 (the composition), 4:2:2 and 4:4:4 (experimental, `AETHER_FEL_CHROMA`), each format's CoreVideo layout
│   │   ├── DoviFelComposer.swift            BL + EL + RPU composition: runtime-compiled pipelines, pooled P010 output, `composeAsync` bounded at `maxFramesInFlight` with completions on its own serial queue; RPU → `DoviMetalParams` parsing
│   │   ├── DoviShaderSource.swift           Luma / chroma compose kernels (reshaping, inverse NLQ, bilinear EL upsampling, ordered dither) and the ABI layout probe, compiled at runtime
│   │   └── DoviMetalParams.swift            Swift mirror of the kernel parameter structs and their byte-exact serializer
│   ├── Issue65LivelockBreakers.swift        Pure backpressure-wedge detection (`BackpressureWedgeDetector`) breaking the VOD HLS scrub-burst livelock (#65); `seekIsWedged` starvation check + `SeekResumeGuard` single-resume latch for the deadline-bounded seek
│   ├── Issue99MuxerFailureRevive.swift      Bounded revive for a VOD pump that died with `muxerFailed` (#99): the first cut firing before any bridged audio reached the muxer (dec3 box) no longer ends the session
│   ├── SlowServeSignal.swift                One-shot slow-serve timer arming the server's early chunked header (keeps TTFB under AVPlayer's ~3.5 s -12889 window, #93 round 3)
│   ├── VideoSegmentProvider.swift           Native path: playlist-facing segment provider (live sliding window, restart heuristics, producer-coverage-gated sparse-hole waits #129)
│   ├── MarchRateTracker.swift               Native path: the producer's march rate from segment completions, cut at restarts and backpressure parks, behind the provider's wait-or-restart decision for a short forward jump (#932)
│   ├── HLSSegmentProducer.swift             Native path: pump loop reading from Demuxer, feeding MP4SegmentMuxer, cutting fragments keyframe-gated in decode order so the IRAP opens its segment (#92); SSAI program-switch detection + no-cut watchdog
│   ├── VODSegmentCutter.swift               Native path: decode-order, keyframe-gated VOD segment cutter (the IRAP opens its segment, #92)
│   ├── PlanBoundaryAxis.swift               Which axis a container stamps its index entries on, and therefore which packet timestamp the cutter gate may compare against a plan boundary: decode for a mov/mp4 sample table, presentation for a Matroska Cue (#358, AE#561)
│   ├── VideoConfigRecord.swift              The `hvcC` / `avcC` config record and the framing question hanging off it (#365): movenc decides whether to Annex-B-convert every sample from the EXTRADATA rather than the packet, so a source carrying Annex-B parameter sets while muxing length-prefixed NALs has each sample rewritten by a converter that finds no start codes. Mirrors movenc's own two tests instead of an equivalent-looking predicate, since predicting that decision wrong is the whole defect
│   ├── H264SPS.swift                        Hand-rolled H.264 SPS parser (SSAI ad-creative coded dimensions / codec config)
│   ├── H264CompositionOffsetRepair.swift    Rebuilds the presentation axis of an MP4 whose writer dropped `ctts` while the bitstream still reorders pictures: libavcodec's H.264 or HEVC parser supplies each access unit's picture order count without decoding, a fail-closed head sample settles the ladder and the shift, and packets are rewritten to the timeline a correct muxer would have written, so the native path and hardware decode are kept (#409, HEVC #699); a writer that forced the decode ladder monotonic is rebuilt at the stream's frame rate, measured on its anchors
│   ├── OutputTimestampSanitizer.swift       Final-stage DTS/PTS monotonicity guard before the fMP4 mux (SSAI splices, program restarts)
│   ├── CFRFrameGrid.swift                   Exact frame grid for a constant-rate VOD track on a coarse time base: the muxer's video time base and the slot each on-grid PTS/DTS lands on (AE#886)
│   ├── RestartCoalescer.swift               Coalesces a burst of producer-restart requests into one in-flight + one settled target (rapid-seek, AetherEngine#35)
│   ├── LiveWindow.swift                     Live path: session-relative DVR timeline (seconds since first frame), shared by the native and SW live paths
│   ├── MP4SegmentMuxer.swift                Native path: session-long fragmented-MP4 muxer (+empty_moov+default_base_moof+frag_custom+delay_moov)
│   ├── NALUnitChain.swift                   Final-stage payload guard before the fMP4 mux: a video sample whose length-prefixed NAL chain overruns it is cut at its last complete unit, because Apple's parser answers one such sample with -19602 for the whole segment (AE#561)
│   ├── AudioLanguageMap.swift               Native path: the ISO 639-2/T an audio track is declared with in the master's `EXT-X-MEDIA:TYPE=AUDIO` rendition and written into its `mdhd`; ICU in front of the twenty ISO 639-2/B bibliographic codes Matroska writes, then canonicalization for the ISO 639-3 members CLDR aliases and pass-through for the ones it does not, failing closed on anything ICU can neither resolve nor name (AE#458)
│   ├── FragmentSplitter.swift               Native path: routes mp4 muxer's avio output stream into init.mp4 (ftyp+moov) vs per-segment moof+mdat files
│   ├── PacketRingBuffer.swift               Live path: keyframe-indexed, disk-spooled packet ring backing the SW-path DVR rewind (append-only chunk files, a 24-byte index record per packet, eviction by time and by the session retention budget, evict-and-retry when the volume or quota is full)
│   ├── SessionDirectoryLiveness.swift       The flock marker a session directory under `aether-segments/` holds for its owner's lifetime, so the stale-session sweep spares a live SegmentCache or DVR ring (AE#451, SEG-105)
│   ├── SegmentCache.swift                   Native path: producer/consumer segment store with backpressure, scrub-aware eviction + byte-budgeted VOD backward retention (restart-free back-seeks)
│   ├── VTCapabilityProbe.swift              AV1 system-decode probe + per-format `canHardwareDecode` HW-decodability check for H.264 / HEVC profiles (Intel Macs, older chips, #2); gates codec routing (VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 and interlaced H.264 always route SW, see VideoRoutingPolicy)
│   ├── LiveCadencePolicy.swift              Turns the observed arrival cadence into the two LL-HLS decisions (served TARGETDURATION, blocking-reload eligibility), re-evaluated on every manifest render, instead of trusting a bursty origin's own number
│   ├── PrefetchDiskBudget.swift             Disk bound for an opt-in whole-source prefetch: the hard window is never evicted, so the budget bounds only what lives outside it (#207)
│   └── RetentionClaims.swift                Process-wide ledger of the running sessions' disk allowances: a new session is sized from the free space minus what the others may still write, so concurrent engines cannot each claim a quarter of the same space (#687)
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
| [LibDovi](https://github.com/superuser404notfound/LibDovi) | MIT / Apache-2.0 | libdovi (the `dolby_vision` crate's C API) for live Dolby Vision Profile 7 to single-layer 8.1 RPU conversion (`dovi_convert_rpu_with_mode`, mode 2), so the Apple TV engages real DV on dual-layer UHD-BD remuxes instead of plain HDR10. The software FEL path uses the same library to read the reshaping and NLQ parameters for the Metal composer and to produce the per-frame 8.1 RPU it attaches as display metadata. Prebuilt xcframework, no Rust at the consumer's build time |
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient) | MIT | Pure-Swift SMB2 client over `NWConnection`, backing the opt-in `AetherEngineSMB` product only (never linked by the core engine). NTLMv2 / guest, SMB 2.0.2 / 2.1. Replaced AMSMB2/libsmb2, which `EPERM`s on tvOS / iOS |
| [dav1d](https://code.videolan.org/videolan/dav1d) film grain synthesis, ported | BSD-2-Clause | `AV1FilmGrain` and `AV1FilmGrainShaderSource` port dav1d's grain synthesis (`filmgrain_tmpl.c`, `fg_apply_tmpl.c`) to the CPU tables and the Metal pass of `GPUFrameConverter`, so the GPU route's picture is dav1d's sample for sample; dav1d's notice is kept in both files |
| VideoToolbox | System | Native path video decode (HW where available, Apple's bundled SW dav1d on iOS / macOS) |
| AVFoundation | System | AVPlayer + AVDisplayManager (native path); AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer (SW path) |
| CoreMedia | System | Sample descriptions, format-description tagging, CMTimebase |


### Exact overlap after a live source reconnect

On the single-demuxer stream-copy path, rollback alone is never treated as proof
of replay. A rollback to a retained packet's DTS/PTS can open a provisional
candidate even if the first payload differs. Only exact DTS, PTS and compressed-
payload SHA-256 matches establish replay evidence. Candidate packets are buffered until both
tracks pass their previously admitted frontier, then old media is removed and
new media continues on the existing timeline.

A reconnect can truncate a transport/PES packet. Immediately forwarding a whole
candidate after one mismatch replayed old pictures; immediately reopening after
that mismatch repeatedly met the same damaged boundary. A short unmatched run
including the first packet of either track is quarantined within a bounded
source-time interval and unmatched-packet count per track. Before any exact match on a
track, the first unmatched timestamp anchors that bound. Untimed packets remain
under the producer's overall byte/packet limits and source watchdog. Later exact matches, or crossing that track's old
frontier, complete the interval; discarding a candidate containing gaps also
requires distinct matching timestamps on every participating track. Prolonged
divergence, EOF, read failure and scan limits still interrupt a confirmed prefix
without forwarding it. A short unconfirmed programme boundary retains normal
discontinuity handling. A source clock reset with different content is never
classified as replay solely by its timestamps.

A supported source reopens inside the same cache. Its fresh producer receives the
bounded accepted-packet history and source frontiers; a seek, channel change or
independent load starts without that history. The failed socket is retired before
the replacement opens. Changed track layouts request fresh host negotiation.
Bridged audio and separate side-audio sources remain excluded from paired replay
recognition.

The cutter watchdog distinguishes a bounded overlap scan from a stuck cut while
still detecting source starvation. The guard belongs to the producer thread.
Repeated source loss parks acquisition after the existing bounded reopen budget.
For a host that opted in with `hostRetriesExhaustedLiveReplay`,
`liveSourceReplayExhausted` hands the retry timing to it, and it can call
`retryLiveSourceRecovery()` without replacing the cache or consumer item. Stop or
replacement revokes the pending retry, duplicate requests coalesce, and resumed
production restores the provider's blocking-reload capability. Application
backoff and error presentation remain host-owned.

Corrupt packets with usable timestamps can still match identical previously
accepted bytes: an MPEG-TS continuity flag alone does not invalidate that proof.
Corrupt packets are held in source order during a candidate; a completed paired
verification discards damaged boundary packets even when their usable timestamps
are already past one track's retained frontier. Ambiguous candidates preserve their
packets. This does not discard arbitrary damaged packets during normal playback
or reset a decoder on a transport warning. Per-track/action diagnostics are rate-limited and include source timestamps or
`missing`, never URLs. `forwarded` means the packet reached the normal pump path,
not that a corrupt picture was displayed. Native `LagDiag` clock progress follows
the AVPlayer clock; `videoFrames=unavailable` explicitly records that it is not a
rendered-frame counter, and unavailable drop counts use `-` instead of zero.

### Software live replay admission and recovery

`LiveReplayPacketReader` uses the same `LivePacketReplayGuard` before recording,
clock-discontinuity folding and ring append. Both the DVR reader and the live
combined loop use it. Quarantine is bounded to 96 MiB and 10,000 packets; EOF,
read failure, cancellation and explicit positioning release owned packets. A
verified partial replay is never forwarded as fresh media. An interrupted source
is surfaced as `liveSourceUnavailable`, leaving retry timing to the consuming
application rather than treating transport loss as codec incompatibility.

After paired verification, exact matching packets released late by the demuxer
remain suppressed until each track has advanced beyond the backward-discontinuity
threshold. This settling tail never discards different compressed bytes solely
because their timestamps repeat. During a DVR cursor recovery, acquisition waits
before appending another packet so it cannot evict the target while decoders and
clocks are being repositioned. Memory/disk retention caps remain in force.

### Live playlist renewal after a longer GOP

The first live media playlist seals its target duration. If a later finalized
segment's serialized `EXTINF`, rounded to an integer, exceeds that value, the
provider creates a new `live-N/` playlist namespace with a larger seal. The old
video and subtitle URLs keep their original target and retain the end index before
an oversized segment, even after that segment leaves the live window. Relative segment/init/subtitle URLs resolve within either
namespace to the same retained cache; source acquisition is not reopened.

The native consumer swaps to the renewed URL using the existing in-place reload
and playlist placement machinery. The viewing position and play/pause intent
are carried across the swap, including a DVR position behind live. A renewal
never repeats an already completed startup cushion wait. The change does not
cut a GOP at a dependent frame or falsify a segment's duration. A consumer item
replacement can still cause a short interruption; missing source frames cannot
be reconstructed by this policy.

### Quantized audio packet coverage

`SoftwareAudioPacketCoverage` retains feasible integer sample-clock phases across admitted audio packets rather than bridging every small gap with an epsilon. Codec geometry is limited to fixed MPEG audio/AC-3 frames, declared AAC/E-AC-3 frame sizes, complete non-reservoir WMA v1/v2 blocks and exact PCM sample frames. Unknown, packed or conflicting layouts keep strict positive-duration intervals. Missing timestamps, backwards transitions and arithmetic overflow break clock evidence; a genuine missing packet or accumulated extra tick remains a hole. This changes packet-cache coverage and seek admission, not the decoded audio output clock. Duration-less audio retains the bounded successor-PTS contract, including repeated TrueHD millisecond timestamps.

### Software renderer retirement

Each software playback host owns a fresh display layer. On stop, `AudioOutput` requests immediate synchronizer removal with an invalid time and returns without blocking the main actor. Its shared retirement task retains the output, synchronizer and display layer until AVFoundation calls the completion handler; cancellation does not release those objects early. Repeated detach requests share that task. A caller reusing the same layer must await retirement before attaching it again.
