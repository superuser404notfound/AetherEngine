# Features

What AetherEngine plays and what it does for a host, one section per area. Each section gives the short answer first and the detail after it. The full depth per format is in [formats.md](formats.md), the API for each feature in [api.md](api.md).

- [Containers and streaming formats](#containers-and-streaming-formats)
- [Video](#video)
- [HDR and Dolby Vision](#hdr-and-dolby-vision)
- [Audio](#audio)
- [Dolby Atmos](#dolby-atmos)
- [Height channels from TrueHD and DTS:X](#height-channels-from-truehd-and-dtsx)
- [Subtitles](#subtitles)
- [Picture in Picture](#picture-in-picture)
- [Background audio](#background-audio)
- [Seeking, streaming and prewarm](#seeking-streaming-and-prewarm)
- [Live TV and DVR](#live-tv-and-dvr)
- [Inputs: custom readers, SMB, certificates](#inputs-custom-readers-smb-certificates)
- [Frames, metadata and the audio tap](#frames-metadata-and-the-audio-tap)
- [What the engine does not do](#what-the-engine-does-not-do)

## Containers and streaming formats

| Kind | Supported |
| --- | --- |
| Files | MKV, MP4, WebM, MPEG-TS, AVI, ASF / WMV, OGG, FLV, RealMedia (.rm / .rmvb), 3GP / 3G2 |
| Discs | DVD-Video and Blu-ray ISO (decrypted), with selectable titles and chapters, demuxed through the normal path |
| MPEG-DASH | Remote on-demand manifests: static, one Period, `SegmentBase`, unencrypted |
| HLS | Remote HLS through AVPlayer, live HLS through the engine's own ingest (see [Live TV and DVR](#live-tv-and-dvr)) |

**MPEG-DASH.** The engine lays the video and every audio language out as one fragmented MP4. Seeks, audio switching and both playback paths then work as they do for any other file. Live manifests and `SegmentTemplate` manifests are refused with a reason.

## Video

The engine sends a format to hardware when the platform can decode it, and to its own software decoder otherwise.

| Path | Codecs |
| --- | --- |
| Hardware (VideoToolbox) | H.264, HEVC, HEVC Main10; AV1 Main profile where the device has AV1 hardware |
| Software | AV1 (dav1d) without hardware, and AV1 High / Professional (4:4:4, 4:2:2, 12-bit) everywhere; VP9 (VideoToolbox hardware when supported, otherwise libavcodec); VP8; MPEG-4 Part 2; MPEG-2; VC-1; QuickTime RLE; the Flash tail (Sorenson Spark, On2 VP6); RealVideo 1-4; H.263; Theora; anything else the FFmpeg build has a decoder for |

- Software is the default route. Only HEVC, H.264 and hardware-decodable AV1 go native.
- H.264 High 4:2:2 / 4:4:4 / 10 and HEVC Rext go to software where VideoToolbox has no hardware decoder for them (Intel Macs, older chips).
- **Interlaced H.264** goes to software, because AVPlayer does not deinterlace. On VOD the engine checks the declared field order against decoded frames, so progressive video in interlaced carriage keeps hardware decode.
- **Deinterlacing** runs on the GPU (yadif_videotoolbox, Metal, field rate by default), with a CPU bwdif fallback.

## HDR and Dolby Vision

| Format | Support |
| --- | --- |
| HDR10 | Yes |
| HDR10+ | Yes, per-frame ST 2094-40 |
| HLG | Yes, declared or named by an alternative transfer SEI (as broadcast HLG is) |
| HDR Vivid | Played on its HLG / PQ base; CUVA metadata reported by `probe` |
| Dolby Vision | P5, P7, P8.1, P8.4, AV1 P10.x |

**Dolby Vision Profile 7** plays in one of three ways:

1. **Default:** on the native route as single-layer Profile 8.1. A display without Dolby Vision gets the HDR10 base layer.
2. **With the `DolbyVisionFelCurves` trait:** a FEL source keeps its mapping, and its enhancement layer is folded into the luma curve per scene.
3. **With `preferDualLayerDolbyVision`:** composed dual-layer on Metal, with per-frame Dolby Vision metadata for FEL. Needs the `DualLayerDolbyVision` trait and hardware HEVC decode in VideoToolbox.

Which one to pick, and why the curve fold is the recommended one, is in [Optional components](installation.md#optional-components) and [dolby-vision-fel.md](dolby-vision-fel.md).

On tvOS the engine drives the display switch (Match Content) itself. A host has to set this up once, see [guide.md › tvOS host setup](guide.md#tvos-host-setup).

## Audio

| Handling | Codecs |
| --- | --- |
| Stream-copied, lossless | AAC, AC3, EAC3, FLAC, ALAC |
| Bridged (decoded, then re-encoded to EAC3 5.1 by default, or to lossless FLAC) | TrueHD, MLP, DTS, DTS-HD MA, MP3, MP2, Opus, Vorbis, LPCM (including Blu-ray and G.711), WMA (Standard, Pro, Lossless, Voice), Nellymoser, ADPCM-SWF, Speex, RealAudio (Cook, ATRAC3, Sipro, Lossless, 14.4 / 28.8), AMR-NB, AMR-WB, DVD LPCM |

- **Surround:** 5.1 and 7.1 with the correct `AudioChannelLayout`.
- **Audio-only:** `LoadOptions.audioOnly` runs a lean pipeline with no video machinery, and system Now-Playing on tvOS and iOS.

## Dolby Atmos

**E-AC-3 + JOC (Dolby Atmos) is stream-copied on every route:** HDMI as MAT 2.0, AirPods with spatial audio, and Bluetooth as a downmix.

The one exception is the opt-in Profile 7 FEL dual-layer route (`preferDualLayerDolbyVision` with the `DualLayerDolbyVision` trait). It runs on the software host and plays an E-AC-3 JOC track as its 5.1 / 7.1 bed without the objects, unless `LoadOptions.objectAudioRendering` is set. Then the objects are kept: compressed JOC goes to the renderer, and TrueHD and DTS:X object audio arrive as a rendered bed (in a build with the object-audio traits).

**Detecting Atmos honestly.** No container reliably says whether a track carries JOC before it is decoded. So an honest `TrackInfo.isAtmos` needs a short, bounded decode. Two opt-in ways, neither on the playback-start path:

- `AetherEngine.probeDetectingAtmos(url:/source:)` answers for a details screen without starting playback.
- `LoadOptions.confirmAtmos` lets the running session confirm its own tracks in the background and republish `audioTracks`.

## Height channels from TrueHD and DTS\:X

TrueHD Atmos and DTS:X can keep their height channels. This is opt-in through `LoadOptions.objectAudioRendering`, in a build with the `TrueHDObjectAudio` or `DTSXObjectAudio` trait ([Optional components](installation.md#optional-components)).

- The engine builds a speaker bed from the stream's own lossless 7.1, steered by its objects (TrueHD) or heights (DTS:X).
- Layouts: TrueHD from 5.1.2 up to 9.1.6; DTS:X 7.1.4 and 9.1.6 (its four heights unfolded from the compatible 7.1).
- Output: lossless 24-bit PCM delivered as Apple Positional Audio. tvOS sends it to an Atmos receiver as Dolby MAT, iOS plays it as Spatial Audio. Over AirPlay the route plays APAC.

Details: [formats.md › TrueHD Atmos with heights](formats.md#truehd-atmos-with-heights) and [formats.md › DTS:X with heights](formats.md#dtsx-with-heights).

## Subtitles

| Kind | How it arrives |
| --- | --- |
| Text: SRT, ASS, SSA, VTT, mov_text | Inline text cues |
| Bitmap: PGS, DVB, DVD, plus local VobSub `.idx` + `.sub` sidecars | `CGImage` cues |
| CEA-608 closed captions (field 1) | Text cues. From an `eia_608` / `c608` demuxable track, or extracted from A53 `cc_data` in the video bitstream: H.264 / HEVC SEI on the native path, decoded-frame side data (such as MPEG-2) on the software path. The caption track appears lazily on the first real caption data. |
| DVB teletext | Decoded to text cues with the broadcaster's colours (libzvbi). Pick the caption page with `LoadOptions.teletextPage` at load, or `setTeletextPage(_:)` while the channel plays. |
| External files | First-class tracks: registered, listed and selected like embedded streams |
| A live channel's HLS `SUBTITLES` renditions | Listed as tracks, fetched only once one is selected |

More:

- **Embedded text cues** are harvested from the producer's own read, so enabling a track is instant and costs no extra bandwidth.
- **Raw ASS** markup and fonts are available opt-in, for hosts that render ASS themselves.
- **Native WebVTT renditions** (opt-in, `LoadOptions.prepareNativeSubtitles`): one language-tagged rendition per text track, including load-declared external files. Subtitles then survive PiP, AirPlay and an external display.
- **Bitmap tracks in PiP / AirPlay.** Bitmap tracks (PGS, DVB, DVD, embedded and external .sup) join as OCR-fed renditions. On-device Vision text recognition runs while the track is selected and fills a language-tagged text rendition. This is lossy by design; fullscreen keeps the pixel-accurate overlay.

The host draws the overlay itself. See [formats.md › Subtitles](formats.md#subtitles).

## Picture in Picture

**Native path.** The host builds an `AVPictureInPictureController` around `currentAVPlayer`, or around the session's own `nativePlayerLayer` when it renders through `bind(view:)` instead of AVKit. While `pictureInPictureActive` is set, a native-to-native load hands the `AVPlayerItem` over in place, so the window survives the move to the next episode. A selected bitmap track is OCR-recognized into its WebVTT rendition, so PGS subtitles show in the PiP window here too.

**Software path.**

- The published `softwarePiPSource` carries the `AVSampleBufferDisplayLayer` plus transport answers on the enqueued frames' PTS axis, for sample-buffer PiP.
- `makePictureInPictureController()` builds the controller with a `SoftwarePiPPlaybackDelegate` over the engine's play, pause, skip and time range.
- While PiP is active, the engine composites the active subtitle cues (text and PGS / DVB bitmaps) into the decoded frames, because the host overlay cannot reach the window.
- A bound `AetherPlayerView` shapes the software layer like the picture (aspect-fit, or aspect-fill clipped by the view), so the window mirrors it without offset or crop. A host that mounts `softwarePiPSource.layer` itself sizes it the same way.
- Ending the session closes the helper controller's window. A load on the software path ends PiP (there is no hand-over as on the native path).

**Platform limits.**

- iOS renders sample-buffer PiP. tvOS AVKit does not evaluate sample-buffer content sources (Apple FB9751461, verified through tvOS 26).
- On macOS the layer is laid out at the size of the system PiP window (found through public AppKit and followed on resize; the picture-shaped layout is kept when no window is found). The system draws an opaque bar over the top of that window that no public API removes (Apple FB22411168).

## Background audio

- **iOS:** audio keeps playing when the app goes to the background. The native AVPlayer stays alive; the software path drops video and keeps decoding audio (`backgroundPlaybackEnabled` / `pictureInPictureActive`).
- A paused session survives quick app switches for a grace window (`backgroundTeardownGraceSeconds`, default 15 s) before the wedge-safe teardown runs.
- **tvOS:** tears down immediately (wedge-safe), unless a PiP window is active. PiP keeps the pipeline and the loopback server alive, and on the software path it keeps decoding video too, because the window needs frames.
- Hosts gate corrective actions on the published `isSessionReady`.

## Seeking, streaming and prewarm

**Seeking.** Seeks back into content already watched are restart-free cache hits (byte-budgeted retention, 2 GiB cap). Short forward scrubs ride the cached window. Only a target that was never produced restarts the producer.

**Streaming.**

- One long-lived forward-streaming connection, reconnected when it drops. Resilient to CDN stutter.
- Optional open-time probe budget (`LoadOptions.probesize` / `maxAnalyzeDuration`) to cut first-frame latency on sparse remote remuxes.
- Configurable forward buffer (`LoadOptions.forwardBufferSegments`): from the 40 s default up to an opt-in whole-source pre-buffer. That pre-buffer is bounded in bytes by the session's disk budget, not in segments.

**Prewarm.** `AetherEngine.prewarm(url:httpHeaders:byteBudget:)` fetches a source's opening bytes before anything asks to play it, for a host whose UI knows what comes next.

- The next `load()` of that URL reads its parse bytes from RAM, gets the size with the bytes instead of probing for it, and opens its data connection where the warm bytes end instead of at byte zero. Nothing waits on a first byte.
- Static and off the main actor: no engine instance, no audio session, no layer.
- It never queues for the origin. The bytes live only in memory until they are adopted and are dropped under memory pressure. The HTTP headers are part of the cache key.

## Live TV and DVR

- Unbounded live, with optional timeshift (DVR).
- Direct HLS ingest with AES-128 clear-key and SSAI ad-pod handling.
- Recording a channel over the connection the session already holds.

How to use all of this: [guide.md › Live TV and DVR](guide.md#live-tv-and-dvr). Format detail: [formats.md › Live ingest](formats.md#live-ingest-aes-128-ssai).

## Inputs: custom readers, SMB, certificates

- **Custom input:** play any byte source through the `IOReader` protocol (`load(source:)`). See [guide.md › Custom input](guide.md#custom-input).
- **SMB:** SMB2/3 shares through the optional `AetherEngineSMB` product (NTLMv2 or guest, read-only). See [guide.md › SMB shares](guide.md#smb-shares).
- **Certificate trust:** a media server behind a self-signed or private-CA certificate plays once the host vouches for it.
  - `EngineTLS.serverTrustEvaluator` is asked per challenge, about the origin that challenge came from. A LAN address with a private certificate and a WAN address with a real one are decided separately.
  - It covers every session the engine owns, and the native remote-HLS route too. AVPlayer asks no delegate of its own there, so the engine puts a loopback relay in front of the origin, where the handshake can be checked.
  - The relay is mounted only for an origin the system actually refuses, and media is relayed as it arrives rather than read whole.

## Frames, metadata and the audio tap

- **Frames:** the off-playback `FrameExtractor` has `thumbnail` (scrub preview) and `snapshot` (frame-accurate).
- **Metadata:** `MediaMetadata` (title, artist, album, cover) is parsed on load. A container's album artist fills `artist` when there is no artist.
- **Audio tap:** opt-in `installAudioTap()` delivers decoded playback audio as mono Float32 48 kHz PCM with source-PTS timestamps, off the render path. Use it for live transcription or ShazamKit. It works on the loopback, remote-HLS (VOD and live) and software paths. The stream belongs to its session: a session-preserving reload (audio, subtitle or disc-title switch, `reloadAtCurrentPosition`) finishes it, and the host installs it again when the stream ends.

## What the engine does not do

These are deliberate:

- **No built-in UI.** No controls, transport bar or HUD.
- **No analytics or session reporting.** A 1 Hz `engine.diagnostics.liveTelemetry` surface exists for host UIs that show runtime stats locally. Nothing leaves the device.
- **No playlist or queue.** Call `load(url:)` for the next item.
- **No subtitle overlay.** The engine emits `SubtitleCue` (text or `CGImage`); your UI draws it.
- **No Metal shaders** for normal playback. Everything renders through Apple's native display stack.
- **No third-party networking.** `URLSession` moves the bytes, so TLS, HTTP/3, proxies and MDM rules work for free.
