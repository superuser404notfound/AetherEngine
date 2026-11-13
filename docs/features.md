# Features

What AetherEngine plays and what it does for your app (the host), one section per area. Each section gives the short answer first and the detail after it. The full depth per format is in [formats.md](formats.md), the API for each feature in [api.md](api.md).

- [Containers and streaming formats](#containers-and-streaming-formats)
- [Video](#video)
- [HDR and Dolby Vision](#hdr-and-dolby-vision)
- [Audio](#audio)
- [Dolby Atmos](#dolby-atmos)
- [Height channels from TrueHD and DTS:X](#height-channels-from-truehd-and-dtsx)
- [Subtitles](#subtitles)
- [Live TV and DVR](#live-tv-and-dvr)
- [Inputs: custom readers, SMB, certificates](#inputs-custom-readers-smb-certificates)
- [Seeking, streaming and prewarm](#seeking-streaming-and-prewarm)
- [Picture in Picture](#picture-in-picture)
- [Background audio](#background-audio)
- [Frames, metadata and the audio tap](#frames-metadata-and-the-audio-tap)
- [What the engine does not do](#what-the-engine-does-not-do)

## Containers and streaming formats

| Kind | Supported |
| --- | --- |
| Files | MKV, MP4, WebM, MPEG-TS, AVI, ASF / WMV, OGG, FLV, RealMedia (.rm / .rmvb), 3GP / 3G2 |
| Discs | DVD-Video and Blu-ray (decrypted), as an ISO image or as a `BDMV` / `VIDEO_TS` folder (`DiscDirectoryReader`), with selectable titles and chapters, demuxed through the normal path. See [formats.md › Disc](formats.md#disc-dvd--blu-ray-iso) |
| MPEG-DASH | Remote on-demand manifests: static, one Period, `SegmentBase`, unencrypted |
| HLS | Remote HLS through AVPlayer, live HLS through the engine's own ingest (see [Live TV and DVR](#live-tv-and-dvr)) |

**MPEG-DASH.** The engine turns the video and every audio language into one fragmented MP4. Seeks, audio switching and both playback paths then work as they do for any other file. Live manifests and `SegmentTemplate` manifests are refused with a reason.

## Video

The engine sends a format to hardware when the platform can decode it, and to its own software decoder otherwise. The hardware route is called the native path (VideoToolbox decodes, AVPlayer presents); the other one is the software path.

| Path | Codecs |
| --- | --- |
| Hardware (VideoToolbox) | H.264, HEVC, HEVC Main10; AV1 Main profile where the device has AV1 hardware |
| Software | AV1 (dav1d) without hardware, and AV1 High / Professional (4:4:4, 4:2:2, 12-bit) everywhere; VP9 (VideoToolbox hardware when supported, otherwise libavcodec); VP8; MPEG-4 Part 2; MPEG-2; VC-1; QuickTime RLE; the Flash tail (Sorenson Spark, On2 VP6); RealVideo 1-4; H.263; Theora; anything else the FFmpeg build has a decoder for |

- Software is the default route. Only HEVC, H.264 and hardware-decodable AV1 go native.
- H.264 High 4:2:2 / 4:4:4 / 10 and HEVC Rext go to software where VideoToolbox has no hardware decoder for them (Intel Macs, older chips).
- **Interlaced H.264** goes to software, because AVPlayer does not deinterlace. On VOD (on-demand files, not live) the engine checks the declared field order against decoded frames. Progressive video that is only packed as interlaced therefore keeps hardware decode.
- **Deinterlacing** runs on the GPU (yadif_videotoolbox, Metal, field rate by default), with a CPU bwdif fallback.
- **Upscaling (opt-in):** `LoadOptions.upscalesLowResolutionVideo` scales SDR video below 1080p up to the display. It uses VideoToolbox super resolution, then MetalFX, and needs OS 26. HDR, Dolby Vision and AirPlay keep their usual route, and the upscaling stage never stops playback. For animation, `upscaleScaler = .lineArt` runs a line-art network instead, which also takes 1080p. See [api.md › upscalesLowResolutionVideo](api.md#upscaleslowresolutionvideo).
- **3D on visionOS:** an MV-HEVC second view and side-by-side or over-under frame packing (HEVC) play in stereo (`LoadOptions.stereoPresentation`). Other platforms play 2D. See [api.md › stereoPresentation](api.md#stereopresentation).

## HDR and Dolby Vision

| Format | Support |
| --- | --- |
| HDR10 | Yes |
| HDR10+ | Yes, per-frame ST 2094-40 |
| HLG | Yes, declared or named by an alternative transfer SEI (as broadcast HLG is) |
| HDR Vivid | Played on its HLG / PQ base; CUVA metadata reported by `probe` |
| Dolby Vision | P5, P7, P8.1, P8.4, AV1 P10.x |

**Dolby Vision Profile 7** is the Blu-ray format: an HDR10 base layer plus an enhancement layer. With a FEL (full enhancement layer) the second layer carries real picture detail. Profile 7 plays in one of three ways:

1. **Default:** on the native route as single-layer Profile 8.1. A display without Dolby Vision gets the HDR10 base layer.
2. **With the `DolbyVisionFelCurves` trait:** a FEL source keeps its mapping, and its enhancement layer is folded into the luma (brightness) curve, scene by scene.
3. **With `preferDualLayerDolbyVision`:** both layers are composed on the GPU (Metal), with per-frame Dolby Vision metadata for FEL. Needs the `DualLayerDolbyVision` trait and hardware HEVC decode in VideoToolbox.

Which one to pick, and why the curve fold is the recommended one, is in [Optional components](installation.md#optional-components) and [dolby-vision-fel.md](dolby-vision-fel.md).

On tvOS the engine drives the display switch itself (Match Content: the TV changes into the source's HDR mode and frame rate). A host has to set this up once, see [guide.md › tvOS host setup](guide.md#tvos-host-setup).

## Audio

Stream-copied audio is passed on untouched. Bridged audio is decoded and re-encoded into a format Apple's audio stack plays.

| Handling | Codecs |
| --- | --- |
| Stream-copied, lossless | AAC, AC3, EAC3, FLAC, ALAC |
| Bridged (decoded, then re-encoded: by default surround to EAC3 5.1 and stereo to lossless FLAC; with `audioBridgeMode = .lossless`, FLAC up to 7.1) | TrueHD, MLP, DTS, DTS-HD MA, MP3, MP2, Opus, Vorbis, LPCM (including Blu-ray and G.711), WMA (Standard, Pro, Lossless, Voice), Nellymoser, ADPCM-SWF, Speex, RealAudio (Cook, ATRAC3, Sipro, Lossless, 14.4 / 28.8), AMR-NB, AMR-WB, DVD LPCM |

- **Surround:** 5.1 and 7.1 with the correct `AudioChannelLayout`.
- **Audio-only:** `LoadOptions.audioOnly` runs a lean pipeline with no video machinery.
- **Audio shaping (opt-in):** `LoadOptions.audioShaping` / `setAudioShaping(_:)` add a channel cap, a dialogue lift, a night mode (compressor plus limiter), a loudness target that lifts quiet sources (-36 to -12 LUFS) and an LFE level for stereo downmixes on 2.1 systems. See [formats.md › Audio shaping](formats.md#audio-shaping).
- **Audio delay:** `setAudioDelay(_:)` corrects lip sync while playing, up to 2 s either way. See [api.md › Audio delay](api.md#audio-delay).
- **Audio description:** `TrackInfo.isVisualImpaired` marks audio-description tracks.
- **AVKit's audio menu (opt-in):** `LoadOptions.nativeAudioTrackMenu` lists every audio track there, and a pick switches the track. See [formats.md › Every audio track in AVKit's audio menu](formats.md#every-audio-track-in-avkits-audio-menu).

## Dolby Atmos

**E-AC-3 + JOC (Dolby Atmos) is stream-copied on every route.** JOC is the Atmos object data inside an E-AC-3 track. It reaches HDMI as MAT 2.0 (the format Atmos receivers expect), AirPods with spatial audio, and Bluetooth as a downmix.

The one exception is the opt-in Profile 7 FEL dual-layer route (`preferDualLayerDolbyVision` with the `DualLayerDolbyVision` trait). It runs on the software host. There an E-AC-3 JOC track plays as its 5.1 / 7.1 bed (the plain speaker channels) without the objects.

Setting `LoadOptions.objectAudioRendering` keeps the objects on that route: compressed JOC goes to the renderer, and TrueHD and DTS:X object audio arrive as a rendered bed (in a build with the object-audio traits).

**Detecting Atmos honestly.** No container reliably says whether a track carries JOC before it is decoded. So an honest `TrackInfo.isAtmos` needs a short, bounded decode. There are two opt-in ways, and neither delays playback start:

- `AetherEngine.probeDetectingAtmos(url:/source:)` answers for a details screen without starting playback.
- `LoadOptions.confirmAtmos` lets the running session confirm its own tracks in the background and republish `audioTracks`.

## Height channels from TrueHD and DTS\:X

TrueHD Atmos and DTS:X can keep their height channels. This is opt-in through `LoadOptions.objectAudioRendering`, in a build with the `TrueHDObjectAudio` or `DTSXObjectAudio` trait ([Optional components](installation.md#optional-components)).

- The engine builds a speaker bed (a fixed set of speaker channels, heights included) from the stream's own lossless 7.1, steered by its objects (TrueHD) or heights (DTS:X).
- Layouts: TrueHD from 5.1.2 up to 9.1.6; DTS:X 7.1.4 and 9.1.6 (its four heights unfolded from the compatible 7.1); a smaller layout renders DTS:X as 7.1.4.
- Output: the bed as lossless 24-bit linear PCM. tvOS wraps it in Dolby MAT for an Atmos receiver, and iOS spatialises it on AirPods.
- Over AirPlay it goes as Apple Positional Audio (APAC, a lossy encode). That holds on the loopback route (the engine's local server feeding AVPlayer) and on the software host alike. Needs OS 26.

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

- **Embedded text cues** come from the data the engine already reads for playback, so enabling a track is instant and costs no extra bandwidth.
- **Raw ASS** markup and fonts are available opt-in, for hosts that render ASS themselves.
- **Native WebVTT renditions** (opt-in, `LoadOptions.prepareNativeSubtitles`): the engine hands AVPlayer one language-tagged rendition per text track, including external files declared at load. Subtitles then survive PiP, AirPlay and an external display.
- **Two tracks at once:** `selectSecondarySubtitleTrack(index:)` adds an independent second track (embedded or external) for bilingual viewing. Its cues arrive in `secondarySubtitleCues`. See [guide.md › A second subtitle track](guide.md#a-second-subtitle-track-at-the-same-time).
- **Subtitle offset reach:** `maximumSubtitleDelaySeconds` / `maximumSubtitleAdvanceSeconds` (or `maximumSubtitleOffsetSeconds` for both) keep enough bitmap history and lead for the offset range a host offers.
- **Bitmap tracks in PiP / AirPlay.** Bitmap tracks (PGS, DVB, DVD, embedded and external .sup) join as OCR-fed renditions. OCR here is on-device Vision text recognition: it runs while the track is selected and fills a language-tagged text rendition. This is lossy by design; fullscreen keeps the pixel-accurate overlay.

The host draws the overlay itself. See [formats.md › Subtitles](formats.md#subtitles).

## Live TV and DVR

- Unbounded live, with optional timeshift (DVR).
- Direct HLS ingest (the engine reads the live stream itself), with AES-128 clear-key encryption and SSAI ad-pod handling (ad breaks the server splices into the stream).
- Recording a channel over the connection the session already holds.

How to use all of this: [guide.md › Live TV and DVR](guide.md#live-tv-and-dvr). Format detail: [formats.md › Live ingest](formats.md#live-ingest-aes-128-ssai).

## Inputs: custom readers, SMB, certificates

- **Custom input:** play any byte source through the `IOReader` protocol (`load(source:)`). See [guide.md › Custom input](guide.md#custom-input).
- **SMB:** SMB shares (SMB 2.0.2 and 2.1) through the optional `AetherEngineSMB` product (NTLMv2, guest or anonymous, read-only). See [guide.md › SMB shares](guide.md#smb-shares).
- **Certificate trust:** a media server behind a self-signed or private-CA certificate plays once the host vouches for it.
  - `EngineTLS.serverTrustEvaluator` is asked per challenge, about the origin that challenge came from. A LAN address with a private certificate and a WAN address with a real one are decided separately.
  - It covers every session the engine owns, and the native remote-HLS route too. AVPlayer asks no delegate of its own there, so the engine puts a loopback relay in front of the origin, where the handshake can be checked.
  - The relay is mounted only for an origin the system actually refuses, and media is relayed as it arrives rather than read whole.

## Seeking, streaming and prewarm

**Seeking.** A seek back into content already watched is served from the cache, with no restart. The cache is budgeted in bytes (2 GiB cap). Short forward scrubs use the cached window too. Only a target the engine has never produced restarts the producer (the reader that feeds playback). `seek(to:exact: true)` lands exactly on its target, for a chapter mark or the end of an intro.

**Streaming.**

- One long-lived forward-streaming connection, reconnected when it drops. It rides out CDN stutter.
- Optional open-time probe budget (`LoadOptions.probesize` / `maxAnalyzeDuration`): how much the engine reads to analyse a file before playing. A smaller budget cuts first-frame latency on sparse remote remuxes.
- Configurable forward buffer (`LoadOptions.forwardBufferSegments`): from the 40 s default up to an opt-in whole-source pre-buffer. That pre-buffer is bounded in bytes by the session's disk budget, not in segments.

**Prewarm.** `AetherEngine.prewarm(url:httpHeaders:byteBudget:)` fetches a source's opening bytes before anything asks to play it, for a host whose UI knows what comes next.

- The next `load()` of that URL reads its parse bytes from RAM, gets the size with the bytes instead of probing for it, and opens its data connection where the warm bytes end instead of at byte zero. Nothing waits on a first byte.
- Static and off the main actor: no engine instance, no audio session, no layer.
- It never queues for the origin. The bytes live only in memory until they are adopted and are dropped under memory pressure. The HTTP headers are part of the cache key.

## Picture in Picture

PiP works on both playback paths. The host builds the controller; the engine keeps the pipeline alive and gets subtitles into the window.

- **Native path:** an `AVPictureInPictureController` around `currentAVPlayer` or the engine's `nativePlayerLayer`. When one native load follows another, the engine swaps the `AVPlayerItem` in place, so the window survives the move to the next episode. Subtitles reach the window as native renditions, bitmap tracks through OCR.
- **Software path:** `softwarePiPSource` builds a sample-buffer controller (`makePictureInPictureController()`, with a `SoftwarePiPPlaybackDelegate`). While PiP is active the engine draws the subtitle cues (text and PGS / DVB bitmaps) into the frames. Each load on this path ends PiP.
- **Platforms:** iOS and macOS. tvOS AVKit does not show sample-buffer content (Apple FB9751461, checked through tvOS 26), so on tvOS only the native path has PiP. On macOS the system draws an opaque bar over the top of the window (Apple FB22411168).

How to wire it: [guide.md › Picture in Picture](guide.md#picture-in-picture). Layer geometry, lifecycle and the macOS window: [api.md › Picture in Picture on the software path](api.md#picture-in-picture-on-the-software-path).

## Background audio

- **iOS:** audio keeps playing when the app goes to the background. The native AVPlayer stays alive; the software path drops video and keeps decoding audio (`backgroundPlaybackEnabled` / `pictureInPictureActive`).
- A paused session survives quick app switches for a grace window (`backgroundTeardownGraceSeconds`, default 15 s) before the wedge-safe teardown runs.
- **tvOS:** tears down immediately (wedge-safe), unless a PiP window is active. PiP keeps the pipeline and the loopback server alive, and on the software path it keeps decoding video too, because the window needs frames.
- A host waits for the published `isSessionReady` before any corrective action.
- **Now Playing (opt-in):** the engine can own the system Now Playing card and the remote commands on every platform and route (`ownsAudioNowPlaying`, `ownsVideoNowPlayingSession` with `ownsVideoNowPlayingCommands`, `ownsSoftwareNowPlaying`). `setNowPlayingInfo(_:)` sets the title and artwork, `setNowPlayingTrackCommands(next:previous:)` adds playlist buttons. See [guide.md › Now Playing](guide.md#now-playing).

## Frames, metadata and the audio tap

- **Frames:** the off-playback `FrameExtractor` has `thumbnail` (scrub preview) and `snapshot` (frame-accurate).
- **Probing without playing:** `AetherEngine.probe(url:)` / `probe(source:)` read tracks, HDR and Dolby Vision format, container and disc titles without starting a session, with optional byte and time limits and cancellation. Opt-in passes settle Atmos, HDR10+ and the Dolby Vision enhancement layer. See [api.md › Probing without playing](api.md#probing-without-playing).
- **Scan type:** `sourceVideoScan` tells a host 1080i from 1080p. See [api.md › Scan type](api.md#scan-type).
- **Metadata:** `MediaMetadata` (title, artist, album, cover) is parsed on load. A container's album artist fills `artist` when there is no artist.
- **Audio tap:** opt-in `installAudioTap()` delivers decoded playback audio as mono Float32 48 kHz PCM, off the render path. Each buffer carries its source-PTS timestamp (its position in the media). Use it for live transcription or ShazamKit.
  - It works on the loopback, remote-HLS (VOD and live) and software paths.
  - The stream belongs to its session. A session-preserving reload (audio, subtitle or disc-title switch, `reloadAtCurrentPosition`) finishes it, and the host installs it again when the stream ends.

## What the engine does not do

These are deliberate:

- **No built-in UI.** No controls, transport bar or HUD.
- **No analytics or session reporting.** A 1 Hz `engine.diagnostics.liveTelemetry` surface exists for host UIs that show runtime stats locally. Nothing leaves the device.
- **No playlist or queue.** Call `load(url:)` for the next item.
- **No subtitle overlay.** The engine emits `SubtitleCue` (text or `CGImage`); your UI draws it.
- **No custom renderer.** The picture goes through Apple's display stack (AVPlayerLayer or AVSampleBufferDisplayLayer). Metal runs only in opt-in stages (upscaling, the FEL composer) and in GPU deinterlacing.
- **No third-party networking.** `URLSession` moves the bytes, so TLS, HTTP/3, proxies and MDM rules work for free.
