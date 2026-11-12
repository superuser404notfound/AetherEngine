# Architecture

AetherEngine is a video and audio playback engine for Apple platforms. A host app hands it a URL or a byte source; the engine opens it with libavformat, picks a playback pipeline, and publishes one observable state surface (`@Published` properties on the `@MainActor` `AetherEngine` facade) whichever pipeline runs.

This page is the overview for a new contributor: the pipelines in one picture, how a load picks one, the state a host sees, and which thread owns what. The depth lives in two companion pages and a file map:

- [architecture-native.md](architecture-native.md): the native AVPlayer route (segment plan, restarts, seeks, remote HLS, ingest, DASH, trick play, backgrounding, Now Playing, source connections, live sources).
- [architecture-software.md](architecture-software.md): the software host (decoders, clock, upscaling, Dolby Vision FEL, audio tap, the compressed packet cache).
- [source-map.md](source-map.md): which file owns what.

For using the engine, see [guide.md](guide.md) and [api.md](api.md). For format and codec details, see [formats.md](formats.md).

Contents:

- [The engine in one picture](#the-engine-in-one-picture)
- [Playback pipelines](#playback-pipelines)
  - [How a load picks a route](#how-a-load-picks-a-route)
  - [Audio-only pipeline](#audio-only-pipeline-music-podcasts-audiobooks)
- [Published state](#published-state)
  - [Playback status](#playback-status-playbackphase)
  - [Effective video route](#effective-video-route-videoroute)
- [Threads and owners](#threads-and-owners)
  - [Byte-reader callback scheduling](#byte-reader-callback-scheduling)
  - [Blocking work and the cooperative pool](#blocking-work-and-the-cooperative-pool)
  - [Subtitle recognition scheduling](#subtitle-recognition-scheduling)
- [Dependencies](#dependencies)
- [Where to read next](#where-to-read-next)

## The engine in one picture

```
                               Host app (SwiftUI / UIKit / AVKit)
                                   │  load / play / seek     ▲  @Published state, clock,
                                   ▼                         │  seekEvents, subtitle cues
                    ┌──────────────────────────────────────────────────────────┐
                    │  AetherEngine  (@MainActor facade, one per player)       │
                    │  routing at load · published state · Now Playing         │
                    └──────────────────────────────────────────────────────────┘
                         │ one host per session (TransportControllable)
       ┌─────────────────┼───────────────────────────┬───────────────────────────┐
       ▼                 ▼                           ▼                           ▼
 NativeAVPlayerHost   NativeAVPlayerHost      SoftwarePlaybackHost        AudioAVPlayerHost
 .loopback            .remoteBypass           .software                   AudioPlaybackHost
       │                 │                           │                    .audio
       ▼                 ▼                           ▼                           │
 Demuxer (AVIOReader)  AVPlayer on the        Demuxer (AVIOReader)        AVPlayer on the URL,
       │               origin's playlist             │                    or Demuxer + AudioDecoder
       ▼                                     ┌───────┴────────┐           into a sample-buffer
 HLSVideoEngine:                             ▼                ▼           audio renderer
 HLSSegmentProducer                    video decoders    audio producer
 → SegmentCache                        (dav1d, libavcodec, (PCM, E-AC-3 JOC,
 → VideoSegmentProvider                 VideoToolbox,      object-audio bed)
 → HLSLocalServer (loopback HTTP)       dual-layer FEL)         │
       │                                     ▼                  ▼
       ▼                               SampleBufferRenderer · AudioOutput
    AVPlayer                           (synchronizer = master clock)

 Subtitles: the demuxer's subtitle packets (and sidecar files) become cues the
 engine publishes for the host to draw; on .remoteBypass AVPlayer draws them.
```

Every route reads the source through the same `Demuxer`, except the two that hand a URL to AVPlayer (`.remoteBypass` and the AVPlayer audio host). Network sources reach the demuxer through `AVIOReader`; a local path is opened by libavformat itself. Source connection rules are in [architecture-native.md, Source connections](architecture-native.md#source-connections).

## Playback pipelines

A session runs one pipeline at a time. `videoRoute` names it, so the docs, the code and the published state use one vocabulary:

| `videoRoute` | Host | What runs | In depth |
| --- | --- | --- | --- |
| `.loopback` | `NativeAVPlayerHost` + `HLSVideoEngine` | The engine demuxes the source, remuxes it into HLS-fMP4 (HLS with fragmented MP4 segments), serves it from a local HTTP server, and `AVPlayer` decodes. The default for video. | [Native AVPlayer pipeline](architecture-native.md#native-avplayer-pipeline-default) |
| `.remoteBypass` | `NativeAVPlayerHost` | `AVPlayer` plays a remote HLS playlist directly. No demuxer, no local media server. | [Native route variants](architecture-native.md#native-route-variants) |
| `.software` | `SoftwarePlaybackHost` | The engine decodes video and audio itself and presents through `AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer`. | [Software decoder pipeline](architecture-software.md#software-decoder-pipeline) |
| `.audio` | `AudioAVPlayerHost` or `AudioPlaybackHost` | Audio only: a bare `AVPlayer`, or libavcodec into a sample-buffer audio renderer. | [Audio-only pipeline](#audio-only-pipeline-music-podcasts-audiobooks) |
| `.none` | none | No session. | |

Hosts see the same `@Published` state surface on every route.

### How a load picks a route

The engine picks at load (`load(url:)` / `load(source:)`):

1. **Audio-only**, when `LoadOptions.audioOnly` is set.
2. Otherwise **by the video codec** (`VideoRoutingPolicy`). The native side is an allowlist: HEVC, progressive H.264 and, on devices with a hardware AV1 decoder, AV1, which AVPlayer's HLS-fMP4 pipeline reliably accepts. Everything else goes to the software host: AV1 without hardware decode, VP9, VP8, MPEG-4 Part 2, MPEG-2, VC-1, interlaced H.264 (for deinterlacing), profiles VideoToolbox cannot decode, and every other codec. The full per-codec table, with the reason for each row, is in [formats.md, Software decode](formats.md#software-decode) and [Hardware decode](formats.md#hardware-decode).
3. **How the source reaches AVPlayer.** Remote HLS can go to AVPlayer directly, HLS the engine reads itself feeds the loopback, and MPEG-DASH becomes a virtual MP4 file. See [Native route variants](architecture-native.md#native-route-variants).
4. **Optional stages**, all opt-in: low-resolution upscaling and Dolby Vision FEL composition (both can move a session onto the software path), the FEL curve fold, rendered object audio, the I-frame rendition and live recording. See [Optional video stages](architecture-software.md#optional-video-stages), [Audio routes and object audio](architecture-native.md#audio-routes-and-object-audio), [Trick play and scrub stills](architecture-native.md#trick-play-and-scrub-stills) and [Live recording](architecture-native.md#live-recording).

A few recoveries move a running session to another pipeline: the software escalation after a CoreMedia refusal (`SoftwarePathEscalation`), the remote HLS carriage fallback (`RemoteHLSIngestFallback`) and the return from the upscale route. `videoRoute` reports the one actually running; the transitions are listed under [Effective video route](#effective-video-route-videoroute).

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

The AVPlayer audio host survives across tracks and does not pause when the app goes to the background. Now Playing for both audio hosts is under [Now Playing routes](architecture-native.md#now-playing-routes).

## Published state

Two published values summarise a session for the host. Both are derived, never stored: a pure fold over other state, recomputed on every input change. The host contract for each is in [api.md, `playbackPhase`](api.md#playbackphase) and [api.md, Route and output](api.md#route-and-output); this section explains the derivation.

### Playback status (`playbackPhase`)

`AetherEngine.playbackPhase` is the one observable for what playback is doing right now, on every route. It is derived, not a separate state machine: a pure fold of `state`, `isBuffering`, `isSeeking`, and a typed source-reconnect axis. It is recomputed on every input change, so it cannot get out of sync. Each input's `didSet` triggers an idempotent recompute that re-emits only on an actual change.

Precedence (highest first): `error > ended > idle > loading > stalled > seeking > rebuffering > playing/paused`.

**The reader axis outranks `isSeeking`.** A seek cannot land on a source that stopped delivering, so the seek level stays up as long as the seek stays alive, and that seek is not always the host's. The producer's restart coalescer issues its own `nativeScrub` seeks while recovering, so with `.seeking` on top the engine's own recovery would hide the outage it is recovering from (#410, [measured](measurements.md#reader-stall-hidden-behind-seeking)).

A seek stays visible through `isSeeking` and `seekEvents`; the reader axis is visible nowhere else. On a delivering source nothing changes: the reader is `flowing` and a seek reads `.seeking`.

**`.rebuffering`** is a buffer underrun on a healthy connection: AVPlayer waiting to play, or a software pump that paused its synchronizer to refill (the live feeder at a dry ring, the on-demand loop with its audio lead used up). `state` stays `.playing` across it.

- The software host publishes its pumps' hold as `isRebuffering`, folded into `isBuffering` the same way the audio host's wait is, so the phase turns `.rebuffering` the moment the clock stops. A live source that merely pauses therefore reads `.rebuffering`, not `.playing` over a still picture ([history](measurements.md#live-pause-read-as-playing)).
- When the software on-demand loop pauses, and how it resumes, is in [architecture-software.md, Rebuffering on the on-demand loop](architecture-software.md#rebuffering-on-the-on-demand-loop).

**`.stalled(reconnecting:)`** is a problem with the source connection (drop / 429 / 503 backoff) while the `AVIOReader` retries.

- It is a typed signal, not log text: the reader pushes a `flowing` / `reconnecting` phase through `Demuxer.onNetworkPhaseChanged`, the owning host forwards it (`HLSVideoEngine` on the native path, the software / audio hosts directly), and the engine hops it to the main actor.
- The flag is `true` while the reader retries, and `false` once it has used up its retry ladder (#410). Then the reader is out of the read, the producer's reopen owns the recovery, and the source is still down. The dying reader does not report `flowing` on its way out, so the reopen window never looks like a healthy source.

**Only bytes that crossed the network move the axis back to `flowing`.** This is the same line the reconnect ladders draw (#380, #410).

- A serve from the resident window, the retained head/tail spans (#281), or a resident detour block returns read-ahead the origin paid for before it died. Reporting delivery off those erased the stall on the next read.
- A metered detour fetch (429 / 503 / 509 on the arm that carries a throttling origin, #69/#71) reports `reconnecting`, and its give-up reports `exhausted`.
- One deliberate exception: the faulted-runway refill (#307/#309) replaces a dead connection while megabytes are still resident, and stays silent, because playback there continues. The empty-window ladder reports it when playback really starves.
- The native text subtitle readers (WebVTT rendition prefetch) are deliberately not wired up, so their stalls never move `playbackPhase`. The overlay itself is fed from the main read through the subtitle packet tap and has no connection of its own.

**Paths that cannot report `.stalled`.** The direct AVPlayer-HLS live path (`nativeRemoteHLS`) and the whitelisted-codec audio host (`AudioAVPlayerHost`) have no demuxer or `AVIOReader`. A starved connection there reads as `.rebuffering`.

- On the audio host that flag is folded from AVPlayer's own signals, `timeControlStatus == .waitingToPlayAtSpecifiedRate` and `AVPlayerItemPlaybackStalled`, and only once the item has played. The pre-roll wait of a fresh track is startup, not a rebuffer, and a paused player is never rebuffering.
- So a dead progressive stream (an internet-radio origin dropping the connection) reads `.rebuffering` instead of `.playing` with a frozen clock ([history](measurements.md#audio-host-buffering-axis)).

**For hosts:** observe `$playbackPhase` instead of combining `state == .loading`, `$isBuffering` and `$isSeeking`, and instead of regex-matching `EngineLog` for stall / reconnect.

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
| `.remoteBypass` -> `.loopback` | The carriage watchdog (#168): readyToPlay, but no video track for a master that advertises one (HEVC in MPEG-TS). Mid-session. |
| `.remoteBypass` -> `.loopback` | #199: the same master's verdict is remembered, so the next load skips the doomed mount entirely. At load time. |
| `.remoteBypass` -> `.loopback` | AE#268: the playlist plus the first segment's PMT identify a finite HEVC-in-MPEG-TS VOD. At load time. |
| `.remoteBypass` -> `.software` | AE#990: a finite MPEG-TS playlist with `preferredDecodePath = .software`, at load time, or one AVPlayer refused on its media, through the AE#561 rebuild. |
| `.loopback` -> `.remoteBypass` | AE#154 / AE#246: an HLS playlist reached the loopback path, which cannot demux it. At load time. |

Branch on this where host behaviour differs per pipeline: who draws subtitles (AVPlayer on the bypass, the host's renderer on loopback and software), and whether a composited PiP overlay makes sense at all. Observing it also turns a mid-session reroute into an event instead of a log line.

## Threads and owners

`AetherEngine` is `@MainActor`: transport calls, routing and every published value live on the main actor. The work that blocks or runs continuously lives on threads and queues the engine owns. The host-facing rules (what to call from where, which callbacks arrive off-main) are in [api.md, Isolation, and what runs off the main actor](api.md#isolation-and-what-runs-off-the-main-actor).

| Owner | Runs on | What it does |
| --- | --- | --- |
| `AetherEngine` facade, `player.clock`, `diagnostics` | Main actor | Load and routing, transport, published state, Now Playing. |
| `HLSSegmentProducer` (native) | Its own thread, `AetherEngine.HLSSegmentProducer.pump` | Demux loop: reads packets, cuts and muxes segments into the cache. |
| `HLSLocalServer` (native) | An accept thread plus one thread per connection | Serves the playlists and segments to AVPlayer. |
| `SoftwarePlaybackHost` (software) | Serial queues `engine.sw.demux` (read loop), `engine.sw.feed` (live DVR feeder), `engine.sw.seek` (demuxer repositioning) | Reads, decodes and feeds the renderers. |
| `SoftwarePacketReadAhead` (software VOD) | Its own thread, with a priority that changes inside the loop | Fills the compressed packet cache. See [Producer thread priority](architecture-software.md#producer-thread-priority). |
| `AudioPlaybackHost` (audio-only) | Serial queue `engine.audio.demux` | Demux and decode loop. |
| `AVIOReader`, held connections, prewarm | Their own serial URLSession delegate queues | Deliver source bytes. See [Byte-reader callback scheduling](#byte-reader-callback-scheduling). |
| Blocking engine tasks | `BlockingExecutor` on GCD's global queues | Demuxer opens, FIFO writes, joins. See [Blocking work and the cooperative pool](#blocking-work-and-the-cooperative-pool). |
| Bitmap subtitle OCR, AVFoundation diagnostic reads, audio tap reader | Dedicated threads | See [Subtitle recognition scheduling](#subtitle-recognition-scheduling), [Item diagnostics](architecture-native.md#item-diagnostics), [Audio tap](architecture-software.md#audio-tap). |
| `LiveRecordingWriter` | Its own utility queue | Writes the recording file. See [Live recording](architecture-native.md#live-recording). |

### Byte-reader callback scheduling

The AVIO reader, the held HTTP transport and the prewarm fetcher each use their own serial URLSession delegate queue at user-initiated QoS. These callbacks deliver playback bytes and release the origin-request tickets that foreground demux threads wait for. A semaphore wait cannot donate priority to an implicit utility callback queue, which is why the queues are explicit. Held transport work also runs at user-initiated QoS.

**Ticket release.**

- Finite AVIO requests release their ticket in the completion callback, before the waiting caller resumes to process the result.
- A lock-guarded lease makes that release idempotent against cancellation, early return and deallocation.
- Refusal responses are charged to the origin before its slot goes to another reader.
- Persistent and prewarm callbacks already return their tickets at completion.

Unchanged: per-origin caps, FIFO ordering, pacing, cancellation drains, and the timeout/overcommit policy. Each session keeps its own serial callback ordering.

**QoS is not a deadline.** A VOD segment already in the cache can still cross the slow-serve threshold while its serving thread is delayed. Its early chunked header is still valid: the response carries the same cached bytes, and the notification alone does not restart the producer.

### Blocking work and the cooperative pool

**Rule:** engine code that blocks its thread never runs on the Swift cooperative pool. Examples: a demuxer open or packet read, a FIFO write under backpressure, a `close()` that joins a pump, a `waitForFinish`.

**Why.** The pool has one thread per core and does not grow. Each blocked job takes one core's worth of async work away from the whole process, including the host app.

**How.** Create a detached engine task with `BlockingWork.detached` (`BlockingWork.swift`), never `Task.detached`. The task prefers `BlockingExecutor`, which runs its jobs on GCD's global queues, and GCD adds a thread when one blocks. Otherwise the task behaves as before: it awaits, hops to the main actor, and can be cancelled. `BlockingWorkTests` pins both halves, and a test fails the build if a `Task.detached` comes back into `Sources/AetherEngine`.

**Testing it.** `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` narrows the pool to one thread and reproduces pool exhaustion on any Mac. The full suite has to pass under it. How CI found the problem: [measurements.md, Cooperative pool exhaustion on CI](measurements.md#cooperative-pool-exhaustion-on-ci).

**HTTP/1.1 body reads.** Persistent HTTP/1.1 body reads inherit the caller's isolation through the isolated parameter of `PersistentHTTP1Connection.readChunk`. Its framing can own a mutable chunked-body decoder, so a read from a cancellation handler must not send that single-consumer state to another executor. Cancellation still abandons the body through its existing drain-or-close path.

### Subtitle recognition scheduling

Bitmap subtitle OCR awaits each image's recognition on a dedicated utility thread.

- `VNImageRequestHandler.perform` blocks while Vision does its work. Calling it directly from a Swift task, even `Task.detached`, can exhaust the cooperative executor. So embedded and sidecar OCR workers suspend during recognition instead of holding that executor.
- One process-wide admission slot stays taken until the native operation actually returns, including after cancellation. Cancelled callers still in the queue leave without starting another thread.
- Completed cues stay in the store. An embedded worker cancelled mid-batch invalidates that batch's advanced cursor, so re-selecting the track collects it again instead of skipping unfinished cues.

## Dependencies

| Package | License | Purpose |
| --- | --- | --- |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL-2.1-or-later | Slim FFmpeg 8.1 (avcodec / avformat / avutil / swresample / swscale / avfilter + zimg) for demux, HLS-fMP4 mux, AudioBridge E-AC-3 / FLAC encode, software-path dav1d decode, and sws_scale YUV → NV12 / P010. avfilter ships a trimmed filter set: zscale + tonemap + colorspace (HDR → SDR still extraction), bwdif + yadif + yadif_videotoolbox + hwupload (software and GPU deinterlacing), and the audio shaping graph (abuffer, abuffersink, aformat, aresample, pan, dialoguenhance, acompressor, alimiter; #923). The dca decoder's `x_heights` option decodes DTS:X height channels (#798). Bundles libzvbi for the DVB teletext decoder (#107). Shipped as dynamically linked frameworks, no GPL components. |
| [LibDovi](https://github.com/superuser404notfound/LibDovi) | MIT / Apache-2.0 | libdovi (the `dolby_vision` crate's C API) for live Dolby Vision Profile 7 to single-layer 8.1 RPU conversion (`dovi_convert_rpu_with_mode`, mode 2), so the Apple TV engages real DV on dual-layer UHD-BD remuxes instead of plain HDR10. The software FEL path uses the same library to read the reshaping and NLQ parameters for the Metal composer and to produce the per-frame 8.1 RPU it attaches as display metadata, and the native FEL curve fold writes its polynomial mapping back with `dovi_rpu_set_polynomial_mapping`. Prebuilt xcframework, no Rust at the consumer's build time. |
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient) | MIT | Pure-Swift SMB2 client over `NWConnection`, used only by the opt-in `AetherEngineSMB` product (never linked by the core engine). NTLMv2 / guest, SMB 2.0.2 / 2.1. Replaced AMSMB2/libsmb2, which `EPERM`s on tvOS / iOS. |
| [dav1d](https://code.videolan.org/videolan/dav1d) film grain synthesis, ported | BSD-2-Clause | `AV1FilmGrain.swift` (`AV1FilmGrainTables`) and `AV1FilmGrainShaderSource.swift` port dav1d's grain synthesis (`filmgrain_tmpl.c`, `fg_apply_tmpl.c`) to the CPU tables and the Metal pass of `GPUFrameConverter`, so the GPU route's picture matches dav1d's sample for sample. dav1d's notice is kept in both files. |
| [LibTrueHD](https://github.com/superuser404notfound/LibTrueHD) | MIT, plus Apache-2.0 parts | TrueHD decode for the object-audio bed (`objectAudioRendering`). Static library, linked only with the `TrueHDObjectAudio` trait. See [licensing.md](licensing.md#libtruehd). |
| [Anime4K](https://github.com/bloc97/Anime4K) Upscale CNN x2 (S), ported | MIT | The line-art scaler's kernels, compiled in as Metal source (`LineArtShaderSource`), whether or not a host uses `upscaleScaler = .lineArt`. bloc97's notice is kept in the file. See [licensing.md](licensing.md#anime4k). |
| VideoToolbox | System | Native path video decode (hardware where available, Apple's bundled software dav1d on iOS / macOS). |
| AVFoundation | System | AVPlayer + AVDisplayManager (native path); AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer (software path). |
| CoreMedia | System | Sample descriptions, format-description tagging, CMTimebase. |

## Where to read next

- [architecture-native.md](architecture-native.md): the native AVPlayer route in depth, its variants, backgrounding, Now Playing, source connections and live sources.
- [architecture-software.md](architecture-software.md): the software host in depth, the optional video stages, the audio tap and the packet cache.
- [source-map.md](source-map.md): which file owns what, folder by folder.
- [formats.md](formats.md): which formats play on which route, HDR and Dolby Vision signaling, audio bridging, subtitles.
- [dolby-vision-fel.md](dolby-vision-fel.md): the Dolby Vision Profile 7 FEL stages.
- [api.md](api.md): the host contract for everything on this page.

## Moved sections

These sections now live on other pages. The headings stay here so existing links keep working.

### Native AVPlayer pipeline (default)
Moved to [architecture-native.md, Native AVPlayer pipeline (default)](architecture-native.md#native-avplayer-pipeline-default).

### 2:3 pulldown timing on 24p film
Moved to [architecture-native.md, 2:3 pulldown timing on 24p film](architecture-native.md#23-pulldown-timing-on-24p-film).

### Native route variants
Moved to [architecture-native.md, Native route variants](architecture-native.md#native-route-variants).

### Trick play and scrub stills
Moved to [architecture-native.md, Trick play and scrub stills](architecture-native.md#trick-play-and-scrub-stills).

### Software decoder pipeline
Moved to [architecture-software.md, Software decoder pipeline](architecture-software.md#software-decoder-pipeline).

### Optional video stages
Moved to [architecture-software.md, Optional video stages](architecture-software.md#optional-video-stages).

### Audio routes and object audio
Moved to [architecture-native.md, Audio routes and object audio](architecture-native.md#audio-routes-and-object-audio).

### App backgrounding
Moved to [architecture-native.md, App backgrounding](architecture-native.md#app-backgrounding).

### Now Playing routes
Moved to [architecture-native.md, Now Playing routes](architecture-native.md#now-playing-routes).

### Audio tap (#95)
Moved to [architecture-software.md, Audio tap (#95)](architecture-software.md#audio-tap).

### Source connections
Moved to [architecture-native.md, Source connections](architecture-native.md#source-connections).

### Shared outputs and the display switch
Moved to [architecture-native.md, Shared outputs and the display switch](architecture-native.md#shared-outputs-and-the-display-switch).

### Live sources
Moved to [architecture-native.md, Live sources](architecture-native.md#live-sources).

### Exact overlap after a live source reconnect
Moved to [architecture-native.md, Exact overlap after a live source reconnect](architecture-native.md#exact-overlap-after-a-live-source-reconnect).

### Live replay boundary
Moved to [architecture-native.md, Live replay boundary](architecture-native.md#live-replay-boundary).

### Native video output diagnostics
Moved to [architecture-native.md, Native video output diagnostics](architecture-native.md#native-video-output-diagnostics).

### Software live replay admission and recovery
Moved to [architecture-software.md, Software live replay admission and recovery](architecture-software.md#software-live-replay-admission-and-recovery).

### Software Live without DVR
Moved to [architecture-software.md, Software Live without DVR](architecture-software.md#software-live-without-dvr).

### Live playlist renewal after a longer GOP
Moved to [architecture-native.md, Live playlist renewal after a longer GOP](architecture-native.md#live-playlist-renewal-after-a-longer-gop).

### Live recording
Moved to [architecture-native.md, Live recording](architecture-native.md#live-recording).

### Software VOD compressed packet cache
Moved to [architecture-software.md, Software VOD compressed packet cache](architecture-software.md#software-vod-compressed-packet-cache).

### Storage
Moved to [architecture-software.md, Storage](architecture-software.md#storage).

### Limits
Moved to [architecture-software.md, Limits](architecture-software.md#limits).

### Coverage frontier
Moved to [architecture-software.md, Coverage frontier](architecture-software.md#coverage-frontier).

### Seeks
Moved to [architecture-software.md, Seeks](architecture-software.md#seeks).

### What hosts see
Moved to [architecture-software.md, What hosts see](architecture-software.md#what-hosts-see).

### Producer thread priority
Moved to [architecture-software.md, Producer thread priority](architecture-software.md#producer-thread-priority).

### Tests
Moved to [architecture-software.md, Tests](architecture-software.md#tests).

### SwiftUI `Menu` in custom player chrome
Moved to [guide.md, SwiftUI `Menu` in custom player controls](guide.md#swiftui-menu-in-custom-player-controls).

### Source map
Moved to [source-map.md, Source map](source-map.md).

### Top level
Moved to [source-map.md, Top level](source-map.md#top-level).

### `Audio/`
Moved to [source-map.md, `Audio/`](source-map.md#audio).

### `Decoder/`
Moved to [source-map.md, `Decoder/`](source-map.md#decoder).

### `Demuxer/`
Moved to [source-map.md, `Demuxer/`](source-map.md#demuxer).

### `Diagnostics/`
Moved to [source-map.md, `Diagnostics/`](source-map.md#diagnostics).

### `Disc/`
Moved to [source-map.md, `Disc/`](source-map.md#disc).

### `Display/`
Moved to [source-map.md, `Display/`](source-map.md#display).

### `FrameExtractor/`
Moved to [source-map.md, `FrameExtractor/`](source-map.md#frameextractor).

### `IO/`
Moved to [source-map.md, `IO/`](source-map.md#io).

### `Native/`
Moved to [source-map.md, `Native/`](source-map.md#native).

### `Network/`
Moved to [source-map.md, `Network/`](source-map.md#network).

### `Recording/`
Moved to [source-map.md, `Recording/`](source-map.md#recording).

### `Renderer/`
Moved to [source-map.md, `Renderer/`](source-map.md#renderer).

### `Subtitles/`
Moved to [source-map.md, `Subtitles/`](source-map.md#subtitles).

### `Video/`
Moved to [source-map.md, `Video/`](source-map.md#video).

### `View/`
Moved to [source-map.md, `View/`](source-map.md#view).

### `Sources/AetherEngineSMB/`
Moved to [source-map.md, `Sources/AetherEngineSMB/`](source-map.md#sourcesaetherenginesmb).

### `Sources/aetherctl/`
Moved to [source-map.md, `Sources/aetherctl/`](source-map.md#sourcesaetherctl).
