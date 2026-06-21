# Architecture

How AetherEngine is put together: the three playback pipelines, the source-file map, and the dependency surface. For the public API and integration, see the [README](../README.md); for format and codec depth, [docs/formats.md](formats.md).

## Playback pipelines

AetherEngine has three playback pipelines, picked once at `load(url:)`: the audio-only path when `LoadOptions.audioOnly` is set, otherwise the native or software video path based on the source's video codec.

### Native AVPlayer pipeline (default)

Demux the source with libavformat, re-mux the elementary streams on the fly into HLS-fMP4, serve them from a local HTTP server on `127.0.0.1:<port>`, point `AVPlayer` at the playlist. Apple's stack does all decode, all HDR / Dolby Vision signaling over HDMI, all audio routing. This is the path for HEVC and H.264, which is what AVPlayer's HLS-fMP4 pipeline reliably accepts. Atmos passthrough, DV HDMI handshake, HDR10 / HDR10+ system-side tone-mapping all live on this path.

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

### Software decoder pipeline (AV1 + VP9 + VP8 + legacy fallback)

Demux the source, run video packets through libavcodec (dav1d for AV1, FFmpeg's native decoder for VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1) into `CVPixelBuffer`s, run audio through libavcodec into `CMSampleBuffer`s, render via `AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` as the master clock. Used for codecs AVPlayer's HLS-fMP4 pipeline doesn't accept: AV1 (no AV1 decoder on tvOS at all; Apple ships dav1d on iOS / macOS only, no Apple TV chip has HW AV1), VP9 / VP8 (AVPlayer parses the HLS manifest, sees `vp09` / `vp08` in the CODECS attribute, then silently stops fetching — `item.status` never leaves `.unknown`. VideoToolbox HW-decodes VP9 fine, but only outside the HLS pipeline), and legacy MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, and VC-1 (none of `mp4v.20.X` / `mp2v` / `vc-1` are in Apple's HLS Authoring Spec CODECS list).

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

AV1+DV (Profile 10.0 / 10.1 / 10.4) routes through the native path on hardware-AV1 hosts via the `dav1` / `av01` track type plus the source's `dvvC` box. AV1+Atmos is genuinely rare in the wild (mastering still runs in HEVC overwhelmingly), so the SW pipeline's lack of Atmos passthrough is a theoretical limitation rather than a real one. The dispatch happens once at load time; hosts see a unified `@Published` state surface either way.

### Audio-only pipeline (music, podcasts, audiobooks)

When the host sets `LoadOptions.audioOnly`, the engine skips the video machinery entirely: no HLS loopback server, no segment producer, no display layer. Decode is native-first. Codecs on the `avPlayerCanDecodeAudio` whitelist hand the source URL straight to a bare `AVPlayer` (`AudioAVPlayerHost`); everything else demuxes through libavformat and decodes through libavcodec into an `AVSampleBufferAudioRenderer` (`AudioPlaybackHost`). Transport (`play` / `pause` / `seek`) routes to the active host, and `stopInternal` tears it down for a clean handoff back to the video path on the next load.

```
audioOnly == true
   ├─ whitelisted codec ──► AVPlayer (AudioAVPlayerHost) ──► AVR / speakers
   └─ otherwise          ──► Demuxer ──► AudioDecoder ──► AVSampleBufferAudioRenderer ──► AVR / speakers
```

On tvOS and iOS the AVPlayer audio host owns a persistent per-player `MPNowPlayingSession` (exposed via `audioNowPlayingSession`) so the system Now-Playing overlay stays bound to the app across a background pause, auto-publishes now-playing info from the player, and carries `externalMetadata`. The host survives across tracks and does not pause when the app backgrounds. All of this is gated `#if os(tvOS) || os(iOS)`; on macOS the path compiles and plays without the system session (a macOS host drives Now-Playing through the shared centers itself).

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
├── AetherEngine+Probe.swift                 Static probe machinery: probe(url:/source:), swDecodeProbe, format / frame-rate / codec-label detection
├── AetherEngine+Loading.swift               The per-backend loaders (remote-HLS, native, software, audio, audio-native) + reload
├── AetherEngine+Subtitles.swift             Embedded + sidecar subtitle pipeline (side demuxer task, cue apply / prune)
├── AetherEngine+Live.swift                  Live window publishing, edge snap, resume clamp, scrub thumbnails
├── AetherEngine+Diagnostics.swift           Memory probe + live-telemetry bridge
├── PlaybackClock.swift                      engine.clock: the ~10 Hz ticking values (currentTime, sourceTime, bufferedPosition, progress, live-edge fields) as a separate ObservableObject
├── PlayerState.swift                        PlaybackState, VideoFormat, PlaybackBackend, LoadOptions, SourceProbe, TrackInfo, FontAttachment, MediaMetadata, SubtitleCue, SubtitleImage
├── LiveReloadPolicy.swift                   Pure decision functions for live reloads: rejoin at the live edge (no stale resume position), skip the pre-readiness zero seek
├── TransportControllable.swift              Common transport surface of the four playback hosts (single active-host dispatch)
├── FFmpegErrorConstants.swift               AVERROR sentinels Swift can't import from the C macros
├── Audio/
│   ├── AudioAVPlayerHost.swift              Audio-only path: bare AVPlayer host for whitelisted codecs, owns the persistent per-player MPNowPlayingSession (tvOS / iOS)
│   ├── AudioBridge.swift                    Native path: decode + re-encode per `AudioBridgeMode` (EAC3 5.1 default or lossless FLAC opt-in) for source codecs that can't stream-copy into fMP4
│   ├── AudioDecoder.swift                   SW path: libavcodec → PCM → CMSampleBuffer with channel-layout tagging
│   ├── AudioOutput.swift                    SW path: AVSampleBufferAudioRenderer + Synchronizer (master clock)
│   └── AudioPlaybackHost.swift              Audio-only path: FFmpeg demux + decode into AVSampleBufferAudioRenderer for codecs off the whitelist
├── Decoder/
│   ├── DeinterlaceFilter.swift              SW path: persistent bwdif / yadif libavfilter graph, engages on the first interlaced frame
│   ├── EmbeddedSubtitleDecoder.swift        Inline subtitle decode from demuxed packets
│   ├── HardwareVideoDecoder.swift           SW path: VideoToolbox HW HEVC / AV1 decoder for sources routed away from AVPlayer
│   ├── SoftwareVideoDecoder.swift           SW path: libavcodec/dav1d → CVPixelBuffer (NV12 / P010), HDR10+ side data
│   ├── SubtitleDecoder.swift                Sidecar URL one-shot decode (text only)
│   └── VideoDecoderTypes.swift              DecodedFrameHandler typealias + VideoDecoderError
├── Demuxer/
│   ├── AVIOProvider.swift                   Internal seam over a custom-AVIO byte source; AVIOReader and CustomIOReaderBridge both plug into the Demuxer through it
│   ├── AVIOReader.swift                     URLSession-backed avio_alloc_context, three modes: persistent forward-streaming connection with reconnect-on-drop (playback, incl. live), discrete Range chunks (still extraction), single sequential GET with backpressure (non-live sources without Content-Length). Optional read deadline bounds a degenerate matroska Cues seek
│   ├── CustomIOReaderBridge.swift           Bridges a host-supplied IOReader into avio_alloc_context read / seek callbacks
│   └── Demuxer.swift                        libavformat wrapper; seek + bounded seek (deadline-capped)
├── Diagnostics/
│   ├── EngineDiagnostics.swift              engine.diagnostics: timer-sampled values (liveTelemetry) as a separate ObservableObject
│   ├── EngineLog.swift                      Gated OSLog emission with severity levels (.verbose suppressed from default + host handler)
│   ├── FFmpegLogBridge.swift                av_log_set_callback funnel: FFmpeg's internal warnings surface through EngineLog
│   ├── LiveTelemetry.swift                  Value type emitted at 1 Hz: instant / avg bitrate, buffer, network, dropped frames, observed FPS, A/V sync gap, plus subsystem byte counters
│   ├── FourCC.swift                         Printable FourCC rendering for codec-tag diagnostics
│   ├── LiveTelemetrySampler.swift           @MainActor 1 Hz sampler that reads existing subsystem counters and assembles LiveTelemetry snapshots
│   └── PacketBalanceTracker.swift           Process-wide AVPacket alloc/free balance counter for leak diagnostics
├── Disc/
│   ├── DiscReader.swift                     Disc detection + routing: local `.iso` URLs and custom ISO readers into the demux path (DVD vs Blu-ray)
│   ├── ISO9660Reader.swift                  Read-only ISO9660 bridge-filesystem reader (DVD-Video images)
│   ├── DVDTitleSelector.swift               Selects the longest DVD title set by VOB size
│   ├── ConcatIOReader.swift                 Synthetic seekable IOReader concatenating byte extents (DVD VOBs / Blu-ray M2TS clips) into one source
│   ├── UDFReader.swift                      Read-only UDF 2.50 reader (Blu-ray BDMV, including the metadata partition and fragmented-file allocation descriptors)
│   ├── MPLSParser.swift                     Blu-ray `.mpls` playlist parser (title metadata)
│   └── BDTitleSelector.swift               Selects the main Blu-ray title from the longest `.mpls` playlist
├── Display/
│   ├── DisplayCriteriaController.swift      AVDisplayManager content-rate / dynamic-range hints (native path)
│   └── FrameRateSnap.swift                  Snap to standard rates (23.976, 24, 25, 29.97, 30, 50, 59.94, 60)
├── FrameExtractor/
│   ├── AetherEngine+FrameExtractor.swift    makeFrameExtractor() convenience for the currently loaded URL
│   ├── FrameExtractor.swift                 Off-playback still extraction actor: serial decode queue, cancel-supersede, idle-close
│   ├── FrameDecodeContext.swift             Isolated FFmpeg demux + decode + sws_scale → CGImage (thumbnail / snapshot)
│   ├── FrameCache.swift                     Bounded LRU: mode-isolated stores, second-bucketed thumbnails
│   ├── FrameTypes.swift                     FrameMode (.thumbnail / .snapshot)
│   └── HDRToneMapper.swift                  zscale + tonemap libavfilter graph: HDR (PQ / HLG, BT.2020) stills → SDR BT.709
├── IO/
│   ├── IOReader.swift                       Public custom byte-source protocol + MediaSource (load(source:) input)
│   ├── DataIOReader.swift                   Ready-made in-memory IOReader over an immutable Data buffer
│   ├── FileIOReader.swift                   Seekable IOReader over a local file via FileHandle (multi-GB ISO images)
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
│   ├── NativeAVPlayerHost.swift             Native path: AVPlayer host bound to the loopback HLS-fMP4 URL; awaits real seek landing, suppresses stale clock during in-flight seek
│   └── SoftwarePlaybackHost.swift           SW path: demux loop + decoders + renderer + synchronizer orchestration
├── Network/
│   └── HLSLocalServer.swift                 Native path: local HTTP server (127.0.0.1) serving playlist + segments
├── Renderer/
│   └── SampleBufferRenderer.swift           SW path: AVSampleBufferDisplayLayer + B-frame reorder, HDR10+ attachments
├── Subtitles/
│   ├── ASSScriptBuilder.swift               Reassembles raw ASS event cues + TrackInfo.assHeader into a complete script for whole-file renderers
│   └── SubtitleRectText.swift               Plain-text + raw ASS event-line extraction from subtitle rects, shared by the inline and sidecar decoders
├── Video/
│   ├── HLSVideoEngine.swift                 Native path: session orchestrator (start/stop, producer construction + restart, shift handling)
│   ├── HLSVideoEngine+AudioRoute.swift      Native path: stream-copy -> FLAC-bridge -> video-only audio cascade
│   ├── HLSVideoEngine+SegmentPlanning.swift Native path: keyframe / uniform segment plans, extradata + AAC fixups
│   ├── HLSVideoEngine+LiveReopen.swift      Native path: live source-loss recovery (capped-backoff reopen on the same timeline)
│   ├── CodecRoutePolicy.swift               Native path: DV / HDR / codec routing decisions (track types, CODECS strings, VIDEO-RANGE)
│   ├── DoviRpuConverter.swift               Native path: per-packet DV Profile 7 → 8.1 RPU conversion via libdovi (NAL surgery: convert type-62 RPU, drop type-63 EL)
│   ├── VideoSegmentProvider.swift           Native path: playlist-facing segment provider (live sliding window, restart heuristics)
│   ├── HLSSegmentProducer.swift             Native path: pump loop reading from Demuxer, feeding MP4SegmentMuxer, cutting fragments at segment-plan boundaries; SSAI program-switch detection + no-cut watchdog
│   ├── H264SPS.swift                        Hand-rolled H.264 SPS parser (SSAI ad-creative coded dimensions / codec config)
│   ├── OutputTimestampSanitizer.swift       Final-stage DTS/PTS monotonicity guard before the fMP4 mux (SSAI splices, program restarts)
│   ├── RestartCoalescer.swift               Coalesces a burst of producer-restart requests into one in-flight + one settled target (rapid-seek, AetherEngine#35)
│   ├── LiveWindow.swift                     Live path: session-relative DVR timeline (seconds since first frame), shared by the native and SW live paths
│   ├── MP4SegmentMuxer.swift                Native path: session-long fragmented-MP4 muxer (+empty_moov+default_base_moof+frag_custom+delay_moov)
│   ├── FragmentSplitter.swift               Native path: routes mp4 muxer's avio output stream into init.mp4 (ftyp+moov) vs per-segment moof+mdat files
│   ├── PacketRingBuffer.swift               Live path: keyframe-indexed, disk-spooled packet ring backing the SW-path DVR rewind
│   ├── SegmentCache.swift                   Native path: producer/consumer segment store with backpressure + scrub-aware eviction
│   └── VTCapabilityProbe.swift              AV1 system-decode probe (gates codec routing; VP9 / VP8 / MPEG-4 Part 2 / MPEG-2 / VC-1 always route SW)
└── View/
    └── AetherPlayerView.swift               Polymorphic surface: hosts either AVPlayerLayer (native) or AVSampleBufferDisplayLayer (SW)
```

## Dependencies

| Package | License | Purpose |
| --- | --- | --- |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | LGPL-3.0 | Slim FFmpeg 8.1 (avcodec / avformat / avutil / swresample / swscale / avfilter + zimg) for demux + HLS-fMP4 mux + AudioBridge FLAC encode + SW-path dav1d decode + sws_scale YUV → NV12 / P010. avfilter ships a trimmed filter set: zscale + tonemap + colorspace (HDR → SDR still extraction), bwdif + yadif (SW-path deinterlacing) |
| [LibDovi](https://github.com/superuser404notfound/LibDovi) | MIT / Apache-2.0 | libdovi (the `dolby_vision` crate's C API) for live Dolby Vision Profile 7 to single-layer 8.1 RPU conversion (`dovi_convert_rpu_with_mode`, mode 2), so the Apple TV engages real DV on dual-layer UHD-BD remuxes instead of plain HDR10. Prebuilt xcframework, no Rust at the consumer's build time |
| VideoToolbox | System | Native path video decode (HW where available, Apple's bundled SW dav1d on iOS / macOS) |
| AVFoundation | System | AVPlayer + AVDisplayManager (native path); AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer (SW path) |
| CoreMedia | System | Sample descriptions, format-description tagging, CMTimebase |
