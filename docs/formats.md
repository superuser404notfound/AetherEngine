# Formats, codecs, and playback detail

This page answers "does my file play, and how". The tables under [At a glance](#at-a-glance) give the quick answer. The sections after them explain the conditions, edge cases and evidence. [features.md](features.md) has the feature overview.

Every file takes one of three routes: the native AVPlayer path, the engine's own software decoder, or (for audio) the audio bridge.

## At a glance

The routes:

- **Native.** AVPlayer and VideoToolbox (Apple's hardware decoder) play a local HLS stream the engine serves on the device (the loopback, fMP4 segments). The default.
- **Software.** `SoftwarePlaybackHost`: the engine decodes the video itself (libavcodec, dav1d, or VideoToolbox where it can) and draws it through `AVSampleBufferDisplayLayer`. See [Software decode](#software-decode).
- **Stream copy.** An audio track goes into the fMP4 untouched, with no re-encode.
- **Bridge.** `AudioBridge` decodes an audio track the fMP4 cannot carry and re-encodes it (E-AC-3 or FLAC). See [Audio bridge modes](#audio-bridge-modes).

The audio columns describe the native path. The software host decodes every track to PCM itself, apart from its object-audio routes ([Atmos on the receiver](#atmos-on-the-receiver-tvos)).

### Containers and sources

| Container or source | Plays? | Notes |
| --- | --- | --- |
| MKV, WebM | Yes | |
| MP4, MOV, 3GP / 3G2 | Yes | Broken timestamp tables are repaired ([Files with broken timestamps or bitstreams](#files-with-broken-timestamps-or-bitstreams)) |
| MPEG-TS, M2TS | Yes | |
| MPEG-PS (DVD VOB) | Yes | |
| AVI, OGG / OGV, FLV | Yes | |
| ASF / WMV | Yes | FFmpegBuild 3.1.0 and later |
| RealMedia (.rm / .rmvb) | Yes | FFmpegBuild 3.8.0 and later |
| Audio files: WAV, MP3, FLAC, AAC (ADTS, LATM), AC-3, E-AC-3, DTS, TrueHD | Yes | AVPlayer or the FFmpeg audio host ([Audio-only files](#audio)) |
| Raw H.264, HEVC, MPEG-2, MPEG-4 Part 2 elementary streams | Demuxer in the build | |
| Remote HLS | Yes | AVPlayer plays it from the origin; a few shapes move to the engine's ingest ([Remote HLS](#remote-hls)) |
| Live HLS through the ingest | Yes | MPEG-TS segments, AES-128 clear key, demuxed audio. SAMPLE-AES and fMP4 playlists are refused ([Live ingest](#live-ingest-aes-128-ssai)) |
| Raw live MPEG-TS over HTTP | Yes | [Raw live MPEG-TS](#raw-live-mpeg-ts-and-the-live-join) |
| MPEG-DASH | On-demand only | Static, one Period, `SegmentBase`, unencrypted ([MPEG-DASH](#mpeg-dash-on-demand)) |
| DVD and Blu-ray ISO images and folders | Decrypted only | No menus, BD-J or multi-angle ([Disc](#disc-dvd--blu-ray-iso)) |
| SMB shares | Yes | With the `AetherEngineSMB` product, SMB 2.0.2 and 2.1 ([Network sources](#network-sources-smb)) |
| Custom byte source (`IOReader`) | Yes | [Custom byte sources](#custom-byte-sources-ioreader) |

### Video codecs

| Codec | Plays? | Route | Notes |
| --- | --- | --- | --- |
| H.264, progressive | Yes | Native | Software where VideoToolbox lacks the profile (High 4:2:2 / 4:4:4 / High 10) |
| H.264, interlaced | Yes | Software, deinterlaced | On VOD the field order is checked first; progressive content goes back to native ([Interlaced H.264](#interlaced-h264)) |
| H.264 MVC (3D Blu-ray, both views in one track) | Base view, 2D | Software | [3D Blu-ray MVC](#3d-blu-ray-mvc) |
| HEVC Main / Main 10 | Yes | Native | HEVC Rext (4:2:2 / 4:4:4 / 12-bit) goes software where VideoToolbox has no decoder for it |
| MV-HEVC | Yes | Native | Base layer, or stereo on visionOS ([3D Blu-ray MVC](#3d-blu-ray-mvc)) |
| AV1 Main | Yes | Native on chips with hardware AV1 (A17 Pro, M3 and later), software elsewhere (every Apple TV) | [AV1](#av1) |
| AV1 High / Professional | Yes | Software | Apple's AV1 hardware decodes Main only |
| VP9 | Yes | Software | VideoToolbox for profiles 0 and 2 (4:2:0), libavcodec otherwise ([VP9 and VP8](#vp9-and-vp8)) |
| VP8, MPEG-2, MPEG-4 Part 2 (XviD / DivX), VC-1 | Yes | Software | |
| WMV1 / 2 / 3, MS-MPEG4 v1 / 2 / 3 | Yes | Software | FFmpegBuild 2.4.3 and later |
| FLV1 (Sorenson Spark), VP6 | Yes | Software | FFmpegBuild 3.2.0 and later |
| RealVideo 1 to 4, H.263, Theora | Yes | Software | FFmpegBuild 3.8.0 and later |
| QuickTime RLE | Yes | Software | |
| ProRes, MJPEG, Cinepak, rawvideo, MPEG-1 video, Flash Screen Video | No | | No decoder in the build; the load fails ([Every other video codec](#every-other-video-codec)) |
| Any other video codec | If the build has a decoder | Software | |

### HDR and Dolby Vision

| Format | Plays? | Route | Notes |
| --- | --- | --- | --- |
| HDR10, HLG | Yes | Native or software | An HDR master is served only to a panel ready for HDR ([When an HDR master is served](#when-an-hdr-master-is-served)) |
| Broadcast HLG named only in the SEI | Yes, as HLG | Native or software | AE#839 |
| HDR10+ | Yes | Native or software | Dynamic metadata kept on both routes ([HDR10+](#hdr10-dynamic-metadata)) |
| HDR Vivid | Base layer | Native or software | The dynamic metadata is not applied by any Apple platform |
| Dolby Vision 5 | Yes | Native | `dvh1` on every display. Refused on the software path (#176) |
| Dolby Vision 8.1 / 8.4 | Yes | Native | Base layer plus Dolby Vision signalling |
| Dolby Vision 7 (UHD Blu-ray) | Yes | Native, converted to 8.1 | Curve fold and dual-layer composition are opt-in ([Profile 7](#profile-7)) |
| Dolby Vision 8.2, AV1 10.2, H.264 9 | Base layer only | Native | No Apple decoder for these |
| AV1 Dolby Vision 10.0 | Hardware AV1 only | Native | The software path refuses it ([Known limitations](#known-limitations)) |
| AV1 Dolby Vision 10.1 / 10.4 | Yes | Native or software | 10.1 keeps its Dolby Vision on the software host too ([AV1 Dolby Vision](#av1-dolby-vision)) |

### Audio codecs

| Codec | Plays? | Route (native path) | Notes |
| --- | --- | --- | --- |
| AAC-LC, HE-AAC / HE-AACv2 | Yes | Stream copy | LATM / LOAS, HE-AAC without an AudioSpecificConfig (live ADTS), and a layout in a PCE bridge |
| AC-3, E-AC-3, E-AC-3 JOC (Atmos) | Yes | Stream copy | JOC reaches HDMI as Dolby MAT 2.0 ([Dolby Atmos](#dolby-atmos)) |
| FLAC, ALAC | Yes | Stream copy | FLAC with `min_blocksize` below 192 bridges |
| TrueHD, MLP, DTS, DTS-HD MA | Yes | Bridge | Atmos objects and DTS:X heights only with `objectAudioRendering` and its trait ([TrueHD Atmos](#truehd-atmos-with-heights), [DTS:X](#dtsx-with-heights)) |
| MP3, MP2, MPEG-1 Layer I, Opus, Vorbis | Yes | Bridge | |
| PCM: signed 8, 16, 24 and 32-bit integer and 32 / 64-bit float (either byte order), unsigned 8-bit, G.711, Blu-ray and DVD LPCM | Yes | Bridge | |
| WMA family, Nellymoser, ADPCM-SWF, Speex, RealAudio, AMR-NB / AMR-WB | Yes | Bridge | |
| AC-4, MPEG-H 3D Audio | No | | Track is listed, plays silent ([Audio a build has no decoder for](#audio-a-build-has-no-decoder-for)) |

### Subtitle formats

| Format | Plays? | How | Notes |
| --- | --- | --- | --- |
| SubRip, ASS / SSA, WebVTT, mov_text (embedded or sidecar) | Yes | Host overlay (`subtitleCues`) | Native WebVTT renditions for PiP / AirPlay are opt-in. Raw ASS markup with `preserveASSMarkup` ([Authored ASS styling](#authored-ass-styling)) |
| PGS (embedded or `.sup`), DVB, DVD | Yes | Host overlay, as images | OCR-fed renditions for PiP / AirPlay ([Bitmap subtitles through OCR](#bitmap-subtitles-through-ocr)) |
| VobSub sidecar (`.idx` + `.sub`) | Local files only | Host overlay | [External subtitle files](#external-subtitle-files-as-first-class-tracks) |
| DVB teletext | Yes | Host overlay | [DVB teletext](#dvb-teletext) |
| CEA-608 (caption track, or A/53 in the video) | Yes, CC1 | Host overlay only | CEA-708 and field 2 are not decoded ([CEA-608](#in-band-cea-608-closed-captions)) |
| Live HLS WebVTT renditions | Yes | Host overlay | [Live HLS subtitle renditions](#live-hls-subtitle-renditions-host-overlay) |

Native renditions need a master playlist, so they are not served for HDR on an SDR panel, on the software path or for live sources ([Routing scope](#routing-scope)).

## Contents

- [Containers and codecs](#containers-and-codecs): demux formats, remote HLS, DASH, hardware and software decode, files with broken timestamps
- [HDR routing](#hdr-routing): HDR10, HDR10+, HLG, Dolby Vision, HDR Vivid
- [Audio](#audio): stream copy, the audio bridge, shaping, Atmos, TrueHD Atmos and DTS:X with heights
- [Subtitles](#subtitles): embedded, external, native renditions for PiP / AirPlay, live renditions, ASS styling
- [Frame extraction](#frame-extraction)
- [Disc (DVD / Blu-ray ISO)](#disc-dvd--blu-ray-iso)
- [Custom byte sources (`IOReader`)](#custom-byte-sources-ioreader)
- [Network sources (SMB)](#network-sources-smb)
- [Live ingest, AES-128, SSAI](#live-ingest-aes-128-ssai)
- [Known limitations](#known-limitations)

## Containers and codecs

**Containers (demux side):** MKV, MP4 (and 3GP / 3G2), WebM, MPEG-TS, MPEG-PS (DVD VOB), AVI, ASF / WMV, OGG, FLV, RealMedia (.rm / .rmvb).

The build also carries demuxers for audio files (WAV, MP3, FLAC, AAC in ADTS, LATM, AC-3, E-AC-3, DTS, TrueHD), raw H.264, HEVC, MPEG-2 and MPEG-4 Part 2 elementary streams, and subtitle files (SRT, ASS / SSA, WebVTT, PGS `.sup`, VobSub).

That list is the supported set, not the compiled set. Two demuxers need a note:

- **HLS.** The FFmpeg build carries the HLS demuxer, but HLS through it is not a supported source shape. The build ships no network protocols, only `file`, `pipe` and `data`, because the engine fetches bytes itself (its own `AVIOReader` over `URLSession`). So libavformat cannot fetch what a manifest points at. Remote HLS is handled one level up instead: by AVPlayer on the bypass (AVPlayer plays the origin directly, see the next section), or by the live ingest.
- **DASH.** The DASH demuxer is not in the build at all (it needs libxml2, which the build does not link). Remote DASH has its own path, described next.

### Remote HLS

A remote HLS playlist plays on AVPlayer straight from the origin by default (the bypass). The engine moves it elsewhere only where AVPlayer cannot show it:

- **Finite playlist of HEVC in MPEG-TS (AE#268).** AVFoundation builds no video track for HEVC in MPEG-TS. When the playlist and the first segment's PMT (its stream table) prove that shape, the load goes through the seekable MPEG-TS ingest instead. The ingest remuxes to fMP4 for the engine's own loopback. fMP4, live, encrypted, demuxed-audio and H.264 playlists stay on the bypass.
- **Live master that advertises HEVC, Dolby Vision or AV1 but delivers MPEG-TS (#168).** The session reaches `readyToPlay` with no video track, so a watchdog moves it onto the live ingest. `LoadOptions.nativeRemoteHLSIngestFallback` turns this off.
- **Finite MPEG-TS playlist in software (AE#990).** With `preferredDecodePath = .software`, any finite MPEG-TS playlist plays on the software host from the same seekable ingest, including the start position and seeks. A finite playlist whose media AVPlayer refuses takes that rebuild too (the AE#561 escalation). Other finite playlists mount AVPlayer once more and surface its failure.

**How the HEVC-in-MPEG-TS check runs** (#168). The engine reads the playlist and the head of one segment while AVPlayer starts, so the reroute does not wait for a grace window to run out. A media playlist URL with no master is covered too (#293). Only a codec that the HLS Authoring Spec allows in fMP4 alone triggers that read, so an H.264 channel spends no extra request on it.

**Refused by the origin** (#363). HTTP 401 and 403 reach the item as `NSURLError` -1013 / -1102. The engine then hands the session to the ingest instead of failing the load. The ingest fetches differently from AVPlayer:

- it sends the configured headers on every request,
- it runs at most four fetches at once,
- it sends no AVFoundation user agent.

So an origin that turned AVPlayer away with a user-agent filter or a per-token connection limit may still serve the ingest. The engine does not remember this refusal for the next load (unlike the carriage verdict), because a token expires and a connection limit frees up.

`LoadOptions.nativeRemoteHLSIngestFallback = false` turns off both recoveries (the live HEVC-in-MPEG-TS reroute and the refusal hand-off).

**Live `m3u8` on the loopback path** (#363). The raw live path reads bytes, not playlists. So for an `.m3u8` the engine builds the live ingest reader itself, and sends `LoadOptions.httpHeaders` with the playlist, every segment and every AES key. A tokenized IPTV origin checks exactly that on each request. Credential headers go only to the playlist's own origin: a segment or key on another host, or on http:// behind an https:// playlist, gets the other headers but not the token. A custom `IOReader` that hands a playlist to the raw live path gets the typed `hlsPlaylistOnRawLivePath` error, because it has no playlist URL to ingest from.

**Non-live `m3u8` on the loopback path** (#154). The bundled FFmpeg has no network support, so it can never demux the playlist locally, and remote HLS is AVPlayer's job anyway. On the bypass, the engine lists the stream's external WebVTT renditions (the legible `AVMediaSelectionGroup`) as `subtitleTracks`. `selectSubtitleTrack(index:)` and `clearSubtitle()` drive AVPlayer's media selection, and AVPlayer draws the cues.

**Mis-typed playlists on the reroute** (#154). The reroute is decided by the body (`#EXTM3U`), not by the URL, so the engine tells AVFoundation what it found: the asset declares `application/vnd.apple.mpegurl` (`AVURLAssetOverrideMIMETypeKey`). A playlist behind a URL without `.m3u8` that the origin serves as `video/mp4` or `application/octet-stream` plays instead of failing with AVFoundation -11829 / -11828. A host that sets `nativeRemoteHLS` itself gets no declaration; AVFoundation types that URL as it always has.

[architecture › Effective video route](architecture.md#effective-video-route-videoroute) lists these transitions as `videoRoute` reports them.

### MPEG-DASH (on-demand)

A remote MPD plays when it has the on-demand shape (AE#859):

- `type="static"`, one Period.
- Every selected representation is a single file addressed by `SegmentBase` (an `indexRange` pointing at a `sidx`, plus an `Initialization` range).
- Unencrypted.

The URL needs no extension. An `.mpd` path opens as DASH directly. Any other URL is recognized by its body: an MPD root after an optional BOM, XML declaration and comments, the same way an HLS playlist is recognized by `#EXTM3U`. Every request, the manifest included, carries `LoadOptions.httpHeaders`.

**How it works.** The engine does not demux DASH.

1. `DASHSourceOpener` reads the manifest with Foundation's `XMLParser`, picks the representations, and fetches each one's initialization segment and segment index in one range request (which also proves the origin honours `Range`).
2. `DASHVirtualLayout` lays them out as one fragmented MP4: a moov with one track per representation, a synthesized `sidx` per representation, and the representations' own subsegments, byte for byte, interleaved by start time.
3. libavformat's `mov` demuxer reads that file like any other, so everything downstream is unchanged: both playback routes, seeking, audio track switching, scrub previews and `probe`.

The only rewrite happens as the bytes are served: each moof gets the virtual file's track IDs, and an explicit `base_data_offset` moves with its fragment.

- **Selection.** The engine takes the highest-bandwidth playable video representation, plus the highest-bandwidth playable representation of every audio adaptation set, in manifest order. Representations inside one adaptation set are bitrate versions of the same content, so this keeps every language and drops only duplicates.
  - There is no adaptive switching: the session plays the representations it opened with.
  - Every carried audio track is fetched while it plays, selected or not. For the reporting asset that was three AAC tracks totalling about 310 kbit/s next to a 1 Mbit/s video.
  - Text and image (thumbnail) adaptation sets are not carried.
- **Languages.** An adaptation set's `lang` replaces a track's `und`, mapped to ISO 639-2/T (`en` becomes `eng`, `de-DE` becomes `deu`).
- **Network cost.** One request for the manifest and one per representation before the first media byte. During playback each representation file is read forward in requests that grow the way a single file's do. A small block cache per file (eight 1 MiB blocks) sits in front of them. It matters because libavformat reads an interleaved file in decode order, switching between a video fragment and the audio fragments beside it on every sample. Without the cache, each return to the video file would cost a fresh request: measured 1,042 requests for 45 s of one video file, against 65 with the cache. The origin byte total is the same as for the equivalent single MP4.
- **Refused, with the reason in the error:** live manifests (`type="dynamic"`), more than one Period, `SegmentTemplate` and `SegmentList` addressing, an initialization segment in a separate file, hierarchical `sidx` (`reference_type` 1), and encryption (`ContentProtection`, `pssh`, `encv` / `enca`). An unplayable audio adaptation set is skipped when the video plays. An unplayable video one fails the load.
- **Seeking a fragmented MP4.** libavformat indexes such a file one fragment at a time. Without a guard, a forward seek whose next sync sample starts an unread fragment lands on whatever later fragment an earlier read indexed (a start at 150 s and a seek to 60 s rendered 122 s). So `Demuxer.seek(to:streamIndex:)` checks the samples between the target and the chosen sync sample for a hole in the index. If it finds one, it lands on the sync sample before the target instead. This applies to every fragmented MP4, not only to DASH.

### Hardware decode

Native AVPlayer path, VideoToolbox:

- H.264 (progressive), HEVC, HEVC Main10, on hardware whose VideoToolbox has a decoder for the specific profile.
- AV1 Main profile on devices with hardware AV1 (M3+ Mac, iPhone 15 Pro+, future Apple TV chips). Apple's AV1 hardware decodes Main only (8 or 10 bit, 4:2:0), so High (4:4:4) and Professional (4:2:2, 12 bit) take the software path on these devices too, live included.

### Software decode

`SoftwarePlaybackHost`: the engine's own decoder (`SoftwareVideoDecoder`, or VideoToolbox where it can) and `AVSampleBufferDisplayLayer`. This table is the complete list of what takes it; [architecture › Software decoder pipeline](architecture-software.md#software-decoder-pipeline) has the pipeline itself.

| Source | Why it is software | Decoder |
| --- | --- | --- |
| AV1 without hardware AV1 | No hardware decoder (every current Apple TV, M1 / M2 Macs, iPhones before the A17 Pro). The engine registers the supplemental VideoToolbox AV1 decoder and checks `VTIsHardwareDecodeSupported` (`VTCapabilityProbe`), lazily, only when it routes an AV1 source | libavcodec / dav1d |
| AV1 High / Professional | Apple's AV1 hardware decodes Main profile only, so these go software on hardware-AV1 devices too, live included | libavcodec / dav1d |
| VP9, VP8 | AVPlayer parses the manifest, sees `vp09` / `vp08` in `CODECS`, then silently stops fetching (`item.status` never leaves `.unknown`). VideoToolbox decodes VP9 in hardware fine, only not inside the HLS pipeline | VideoToolbox for some VP9, else libavcodec |
| MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, VC-1 | None of `mp4v.20.X` / `mp2v` / `vc-1` is in the `CODECS` list of Apple's HLS Authoring Spec | libavcodec |
| MS-MPEG4 v1 / v2 / v3, WMV1 / WMV2 / WMV3 | Legacy Microsoft tail (FFmpegBuild 2.4.3) | libavcodec |
| FLV1, VP6 / VP6F / VP6A | Flash tail (FFmpegBuild 3.2.0) | libavcodec |
| RealVideo 1 to 4, H.263, Theora | 2000s tail (FFmpegBuild 3.8.0) | libavcodec |
| QuickTime RLE (`qtrle`) | Not on the native allowlist (FFmpegBuild 2.4.1) | libavcodec |
| Every other video codec | The native side is an allowlist (HEVC, H.264, hardware AV1), so everything else comes here (FFmpegBuild#1). Plays only if the build has a decoder | libavcodec |
| Interlaced H.264 | AVPlayer does not deinterlace, so 1080i / 576i broadcast would show combing (#107). Routed on the declared field order, checked against decoded frames on VOD (#232) | libavcodec + `DeinterlaceFilter` |
| H.264 High 4:2:2 / 4:4:4 / High 10, HEVC Rext, where VideoToolbox lacks the profile | The native path reaches `readyToPlay` and renders nothing (`VTCapabilityProbe.canHardwareDecode`, VOD) | libavcodec |
| H.264 with both MVC stereo views in one track | VideoToolbox is handed both views in one sample and renders nothing (#435) | libavcodec (base view) |
| Dolby Vision Profile 7 FEL, opt-in | `preferDualLayerDolbyVision` with the `DualLayerDolbyVision` trait composes both layers here ([Profile 7](#profile-7)) | VideoToolbox, both layers, plus the Metal composer |
| Upscaling, opt-in | With `upscalesLowResolutionVideo`, a source the route accepts moves here for the Metal scaler, and returns to native when the stage is dropped (#846, [Upscaling](#upscaling)) | The source's usual decoder |
| A native session AVPlayer refuses on its media | With `escalatesToSoftwarePath` (default), a CoreMedia refusal or a confirmed H.264 parameter-set change rebuilds the session here at its playhead ([Files with broken timestamps or bitstreams](#files-with-broken-timestamps-or-bitstreams)) | libavcodec, or VideoToolbox for HEVC |
| Anything, by request | `preferredDecodePath = .software` ([api › Overriding the decode path](api.md#overriding-the-decode-path)) | As above |

On the software host, VideoToolbox still decodes where it can: VP9 (see below), HEVC (which reaches the software host through, for example, escalation, the dual-layer route, upscaling or `preferredDecodePath = .software`), and AV1 Dolby Vision Profile 10.1 on devices with hardware AV1. Everything else there decodes in libavcodec.


#### AV1

AV1 runs through libavcodec / dav1d on devices without hardware AV1.

- **10-bit.** A 10-bit AV1 frame is converted to P010 (a 10-bit pixel format) on the GPU, and its film grain is applied there too (`GPUFrameConverter`). dav1d exports the grain parameters instead of applying them. One Metal pass then does both the grain and the planar-to-P010 conversion, in place of `sws_scale`, and matches dav1d's picture sample for sample. That takes two per-pixel passes off the CPU, which the decode already keeps busy. On a fanless Apple TV, CPU load means heat.
- **8-bit.** Keeps dav1d's grain and `sws_scale`.
- **Fallback.** A 10-bit frame the GPU pass refuses (no Metal device, a failed command buffer) falls back to `sws_scale` without its grain, since dav1d was told at open not to apply it.
- **Seeking.** A seek lands on the keyframe nearest its target, not exactly on it (`SWKeyframeSnap`). An exact landing would make dav1d decode from the keyframe before the target up to the target. 4K AV1 encodes run long GOPs (long gaps between keyframes), and on an Apple TV 4K (A15) that took 2 to 5 s ([api › Transport](api.md#transport)).

#### VP9 and VP8

VP9 and VP8 always use the software presentation route, because AVPlayer's HLS pipeline rejects the `vp09` / `vp08` CODECS attributes.

- VP9 tries a VideoToolbox hardware session for 8-bit profile 0 or 10-bit profile 2 with 4:2:0 chroma. WebM files lack the `vpcC` record that needs, so the engine synthesizes it from probed parameters.
- Other VP9 profiles, and failed hardware opens, fall back to libavcodec. VP8 always uses libavcodec.
- A key frame that changes the coded size (concatenated clips, adaptive recordings) gets a new decoder session of its own size. VideoToolbox answers every frame after a size change with `kVTVideoDecoderBadDataErr`, so without the new session playback would end silently at the switch.
- `activeVideoDecoder` names the decoder that actually opened.

#### MPEG-4 Part 2, MPEG-2, VC-1

MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video and VC-1: AVPlayer's HLS-fMP4 pipeline accepts none of them, and libavcodec ships native decoders for all three.

#### Legacy Microsoft codecs (FFmpegBuild 2.4.3, 3.1.0)

- **Video (FFmpegBuild 2.4.3):** MS-MPEG4 v1 / v2 / v3 (the DivX 3.x that pre-2005 AVI rips carry) and WMV1 / WMV2 / WMV3 (WMV9). These always routed to `SoftwareVideoDecoder`. Before that release they failed the load there with `unsupportedCodec`, because no decoder was compiled in.
- **Native `.wmv` / `.asf` files (FFmpegBuild 3.1.0):** play whole. That release added the `asf` demuxer and the entire WMA decoder family (Standard, Pro, Lossless, Voice). The video in such a file is usually WMV3 or VC-1, both already supported in Matroska and MPEG-TS.
- **All or nothing, on purpose.** The demuxer ships only together with the WMA decoders. Without a matching decoder the demuxer would open the file and then have nothing to decode its audio with: `AudioBridge` init fails, the cascade ends in `droppedNoPipeline`, and the session serves video only and plays the file silently. That is worse than an honest failure.
- WMA is not fMP4-legal in any flavour, so it always takes the AudioBridge, like MP2 and Blu-ray LPCM.
- None of the six video codecs supports frame threading, so they decode single-threaded. The content that carries them is SD.
- Reported by cmcpherson274 (FFmpegBuild#3), whose library carries WMV only inside Matroska and MPEG-TS. So native `.wmv` / `.asf` support waited for a second field report.

#### Flash codecs (FFmpegBuild 3.2.0)

- **Video:** FLV1 (Sorenson Spark, the H.263 variant every pre-2008 `.flv` carries) and the On2 VP6 family (`vp6`, `vp6f`, `vp6a`) that Flash 8 brought.
- **Audio:** Nellymoser Asao, ADPCM-SWF, Speex, and FLV's G.711 / big-endian PCM shapes, shipped for the same all-or-nothing reason as the WMA family.
- The `flv` demuxer has shipped from the start, so a modern Flash file (H.264 + AAC) has always played directly. Only the legacy decoders were missing.
- **Flash Screen Video** (`flashsv` / `flashsv2`) is deliberately absent: it needs zlib, which the build does not link, and screen recordings are not what a media library holds.
- Requested in the Sodalite Discord.

**Where the all-or-nothing rule lives.** In the FFmpeg build, not in the routing table. `AudioCodecCompat` only decides whether a codec is offered a stream copy. The bridge cascade below it asks libavcodec for a decoder by id and never reads the table. So a codec the table does not name still plays when the build carries its decoder (measured on Nellymoser-in-FLV before its entry existed). A codec the build lacks is silent whatever the table says.

#### 2000s codecs (FFmpegBuild 3.8.0)

- **RealMedia:** the `rm` demuxer, RealVideo 1 to 4 (`rv10` / `rv20` / `rv30` / `rv40`; an `.rmvb` is almost always RV40), and every RealAudio such a file carries (Cook, ATRAC3, Sipro, RealAudio Lossless, the 14.4 / 28.8 speech codecs), routed as one `realAudio` family.
- **Feature-phone 3GP / 3G2:** H.263 with AMR narrowband or wideband speech (`amr`), in the `mov` demuxer that was already here.
- **Theora**, the video of `.ogv`.
- **DVD LPCM** (`pcm_dvd`), which routes as `.pcm`.

The same all-or-nothing rule as WMA and Flash applies. None of the audio is fMP4-legal, so all of it bridges. Contributed by williamliu0516 (FFmpegBuild#7), checked against samples.ffmpeg.org files.

#### Every other video codec

Every other video codec takes the software path by default. The native path has its own allowlist (HEVC, H.264, hardware-decodable AV1), and `HLSVideoEngine` refuses the rest with `unsupportedCodec`. So a codec that is merely missing from the lists above goes to software, not native (FFmpegBuild#1).

- Whether such a source then plays depends on the FFmpeg build. QuickTime RLE (`qtrle`, FFmpegBuild 2.4.1) has a decoder and plays.
- With no decoder compiled in, the load fails at `SoftwareVideoDecoder` with `Unsupported video codec`, which is at least an honest error. ProRes, MJPEG, Cinepak, rawvideo and MPEG-1 video are not in the build and fail this way.
- `AV_CODEC_ID_NONE` is the one default-native case, since an audio-only source probes as NONE.

#### Interlaced H.264

Interlaced H.264 (declared field order TT / BB / TB / BT) takes the software path so the deinterlacer can run. tvOS AVPlayer does not deinterlace, so 1080i / 576i broadcast shows combing on the native path (#107).

On a seekable VOD source the engine first checks the declared field order against decoded frames (#232). A field order says how pictures are carried, not that any picture is interlaced. Progressive content in interlaced carriage is common: European 25 fps Blu-ray masters are PsF (progressive segmented frames), since Blu-ray has no 1080p25. Without the check, such content would take the software detour and then never deinterlace, because the filter engages on `AV_FRAME_FLAG_INTERLACED` and on nothing else.

`InterlaceProbe` decodes a short sample and asks the deinterlacer's own question (that flag), so it measures what playback would do rather than guessing at content:

- A sample in which the flag never appears sends the stream back to the native path with hardware decode.
- An inconclusive sample keeps the software route.
- A flagged frame ends the sample at once (~29 ms on 1080i, ~100 ms for a full sample).
- Live sources are never probed.

#### High profiles without a hardware decoder

H.264 High 4:2:2 / 4:4:4 / High-10 and HEVC Rext (4:2:2 / 4:4:4 / 12-bit), on hardware whose VideoToolbox has no decoder for the profile (Intel Macs, older Apple TV chips).

AVPlayer accepts these at the HLS CODECS level and the item reaches `readyToPlay`, but the native path then renders nothing. So at load the engine tries a `VTDecompressionSession` for the exact format (`VTCapabilityProbe.canHardwareDecode`). When that fails, it routes the source to libavcodec, which decodes it (#2). Apple Silicon has hardware decoders for all of these and keeps them native.

The probe only judges a config record that carries its parameter sets out of band (in the record itself). A source with in-band VPS/SPS/PPS only (`hev1`, `numOfArrays = 0`) gives VideoToolbox no SPS to build a session from. A failed session there says nothing about hardware support, so those sources keep the native path (AetherPlayer#2).

#### 3D Blu-ray MVC

This covers H.264 that carries both stereo views inside one track. That is how a 3D Blu-ray MVC remux is muxed: Matroska StereoMode 13 / 14 (`block_lr` / `block_rl`, both eyes in one block). libavformat reports it as stream-level `AV_PKT_DATA_STEREO3D` of type `AV_STEREO3D_FRAMESEQUENCE`, spelled `stereo_mode` in the stream metadata (#435).

- The second (dependent) view's slices reference a subset SPS that the base decoder never receives, so a plain H.264 decoder can only skip them. libavcodec does that and decodes the base view: the left eye, which is the 2D picture every non-3D player shows.
- VideoToolbox is handed whole samples with both views' NALs inside and renders nothing.
- The decision is the container's declaration, read at load. There is no probe.
- The frame-packed modes (side by side, top / bottom, checkerboard, row or column interleaved, anaglyph) are single self-contained pictures. They keep the native path with hardware decode. Cropping an eye out of one of those is the host's call, not the engine's.
- MV-HEVC keeps the native path too: it is Apple's own spatial-video format and AVPlayer plays its base layer.
- Real MVC 3D output is not offered on any path.
- **Stereo on visionOS.** There, `LoadOptions.stereoPresentation` (default `.automatic`) keeps an MV-HEVC stream's second view. It also presents an HEVC side-by-side or over-under packing as stereo when the container declares it (Matroska `StereoMode`). A host can name the packing per title too (`.sideBySide`, `.overUnder`). Packing is signalled on HEVC only, so packed H.264 plays 2D. Every other platform plays all of these 2D as described above. See [api › `stereoPresentation`](api.md#stereopresentation).

### Deinterlacing

Interlaced sources (DVD-rip MPEG-2, SD / HD broadcast H.264) are deinterlaced through a persistent filter graph. By default it runs on the GPU (`yadif_videotoolbox`, a Metal kernel, at field rate), with CPU bwdif (yadif on older builds) as the fallback. It engages on the first interlaced frame and costs nothing on progressive content.

`AetherEngine.load` decides the route (`VideoRoutingPolicy`), per source, from `VTCapabilityProbe`, the codec id, the declared field order, and on VOD the decode sample that verifies it.

`$sourceVideoScan` tells a host whether the source is progressive or interlaced, from the same evidence (AE#983, [api › Scan type](api.md#scan-type)).

### Upscaling

SDR video below 1080p can be upscaled to the display's pixel size on the software host. It is opt-in with `LoadOptions.upscalesLowResolutionVideo` (#846). The default scaler is VideoToolbox super resolution plus MetalFX. `upscaleScaler = .lineArt` runs a network made for drawn content instead (Anime4K mode A, 8 or 10 bit, up to 1080p; AE#1039). HDR, Dolby Vision and AirPlay routes are not upscaled. See [api › `upscalesLowResolutionVideo`](api.md#upscaleslowresolutionvideo).

### Files with broken timestamps or bitstreams

Some files carry timestamps or bitstreams that a player would show wrongly. The engine repairs these shapes at the demuxer or muxer; the host does nothing. Each repair is fail-closed: a file that does not match the shape exactly is delivered as written.

| What is wrong with the file | What the engine does | Cost | Detail |
| --- | --- | --- | --- |
| MP4 with no composition offsets (`ctts`) while the H.264 or HEVC bitstream reorders pictures, so every sample reports `PTS == DTS` (#409, #699) | Rebuilds presentation times from the picture order count in the slice headers (`H264CompositionOffsetRepair`) | None, hardware decode stays | [architecture › MP4 without composition offsets](architecture-native.md#mp4-without-composition-offsets) |
| The same, from a writer that also pushes timestamps to keep them monotonic | The same repair, with the frame step taken from the stream's rate and VUI timing | None | [architecture › Writers that push timestamps](architecture-native.md#writers-that-push-timestamps-to-keep-them-monotonic) |
| The same, on H.264 with a changing decode cadence | Assigns the file's own timestamp slots by display rank | None | [architecture › H.264 with a changing decode cadence](architecture-native.md#h264-with-a-changing-decode-cadence) |
| Matroska whose presentation slots are in coding order (#511) | Moves each slot to the picture whose display rank owns it (`H264MatroskaSlotPermutation`) | None | [architecture › Matroska with presentation slots in coding order](architecture-native.md#matroska-with-presentation-slots-in-coding-order) |
| MP4 whose composition offsets are missing only in later regions (judder after a seek) | Streams the same slot repair per sequence | None | [architecture › MP4 with composition offsets missing only in later regions](architecture-native.md#mp4-with-composition-offsets-missing-only-in-later-regions), [regression and reproduction](notes/partial-composition-regression.md) |
| H.264 VOD whose parameter sets change mid-file (audio, no picture) | Moves the session to the software path | Software decode | [Below](#h264-vod-with-changing-parameter-sets) |
| A video sample whose NAL chain overruns it, or confirmed HEVC with an incomplete two-byte NAL header (AE#561, #960) | Cuts an overlong chain at its last complete NAL; removes incomplete HEVC headers while preserving valid NALs, dropping a sample with no complete header. A CoreMedia refusal that still happens rebuilds the session on the software path, once | None, or software decode | [architecture › A video sample whose NAL chain overruns it](architecture-native.md#a-video-sample-whose-nal-chain-overruns-it) |
| 24p film stamped with 2:3 pulldown times, 50 and 33 ms per frame (Sodalite#236) | Puts each frame on its 24p slot on the native route (`PulldownCadenceRetimer`) | None | [architecture › 2:3 pulldown timing on 24p film](architecture-native.md#23-pulldown-timing-on-24p-film) |
| A declared frame rate that is not a standard rate (mkvmerge writes the first frame's duration, so such a file declares 20 fps) | Measures the rate on the head packets the probe already queued and uses that (23.976 here) for the display switch, the master's `FRAME-RATE` and the frame grid | None | |

On the pulldown clip, 587 of 606 frame steps came out at exactly 41.7 ms, where every step had been 50 or 33. Content that is not film (true 30p or 60p, constant-rate stretches) is untouched.

#### H.264 VOD with changing parameter sets

**The problem.** A length-prefixed H.264 file can keep its original `avcC` (the stream's config record) while later samples carry different SPS/PPS, including a resolution change under the same parameter-set IDs. Native HLS can then play audio without showing video, also after seeking or reopening at that position.

**Detection.** Before the producer writes an IDR (a keyframe) into the native segment, it checks the parameter sets that IDR actually references. Repeated sets, and announcements that no IDR uses, do not change the route. Only the part of the SPS a decoder session is built from counts (`H264SPS.decoderSignature`: profile, chroma format and bit depth, frame numbering and picture order, reference frames, size and cropping). A new PPS, VUI or level keeps the native route, because the native decoder takes those in band. On macOS such a change played through natively in every arm, while a profile or resolution change froze the picture.

**What happens.** In automatic mode, with `escalatesToSoftwarePath` enabled, a confirmed mismatch hands the session to the software path through the existing native-to-software takeover. The software decoder accepts the changing frame size, and the rebuild keeps the requested seek or resume position and the session transport. This can buffer briefly and costs CPU for software decoding. The native-only features described elsewhere on this page are not available on that route.

An explicit decode-path choice and disabled escalation are honored; the load then fails with an error when the native initialization cannot serve the source. Live Annex-B configuration rotation is unchanged.

## HDR routing

| Source | Wrapper signaling |
| --- | --- |
| H.264, HEVC (SDR) | BT.709 |
| HEVC Main10 (HDR10) | BT.2020 / PQ |
| HEVC Main10 (HDR10+) | BT.2020 / PQ + per-frame ST 2094-40 SEI stream-copied |
| HEVC Main10 (DV P5) | `dvh1` track type (DV-only, IPT-PQ base; forced even on SDR panels) |
| HEVC Main10 (DV P8.1 / P8.4 / P7) | `hvc1` primary + `dvvC` box (P7 converted to 8.1 first), DV engaged via `SUPPLEMENTAL-CODECS` on DV panels. Elsewhere the HDR10 / HLG base, with the RPU applied where AVPlayer converts it (a tvOS panel in SDR, a Mac); a tvOS panel without DV that presents HDR shows the base layer (AE#1018) |
| HEVC Main10 (HLG) | BT.2020 / HLG |
| HEVC / H.264 with a BT.2020 SDR VUI and an alternative-transfer SEI naming HLG | BT.2020 / HLG (AE#839) |
| AV1 HDR | BT.2020 / PQ |

Broadcast HLG (BBC iPlayer, UK DVB-T2 UHD) names HLG only in the `alternative_transfer_characteristics` SEI. Its VUI keeps a backward-compatible transfer (BT.709, BT.2020 10 or 12 bit, or unspecified) over BT.2020 primaries, so an SDR set still shows a picture. The demuxer reads the first video packets (at most 8) for that SEI. When it names HLG, the stream is marked HLG for every later reader: format detection, display criteria, `VIDEO-RANGE`, the muxer's `colr` and `probe(url:)` (AE#839).

AetherEngine does not tone-map (convert HDR to SDR) on the host. It tells the system "this is BT.2020 PQ" (or DV, or HLG) through the HLS-fMP4 sample description. AVPlayer and the system compositor then map HDR to SDR as the connected display needs. tvOS / iOS pick the right path.

**On the software host** there is no HLS sample description, so the same signal travels on each decoded frame. Both decoders (libavcodec and VideoToolbox) attach the colour primaries, transfer (PQ, HLG) and matrix to every pixel buffer. HDR10+ metadata goes out per frame as `kCMSampleAttachmentKey_HDR10PlusPerFrameData`. So an AV1 or VP9 HDR10 or HDR10+ source keeps its HDR and its dynamic metadata off the native route too. `videoFormat` moves to `.hdr10Plus` on the first frame that carries it.

### When an HDR master is served

An HDR master playlist is only served when the panel is ready for it. Otherwise the engine serves the bare media playlist (media-direct).

| Platform | Ready means |
| --- | --- |
| tvOS | The external panel is already in HDR mode, or Match Dynamic Range is on. An SDR-parked panel rejects an HDR master with `-11848`. |
| iOS | The built-in panel engages EDR on demand with no display mode switch, so `AVPlayer.eligibleForHDRPlayback` counts as readiness. SDR-only devices read ineligible and stay media-direct. |
| macOS | Same as iOS for readiness. See [the macOS capability table](#macos-capability-table) below. |

`DisplayCriteriaController` sends the HDMI content-frame-rate and dynamic-range hint through `AVDisplayManager` before the first segment is fetched. So the TV's handshake is already under way by the time `AVPlayer` is ready to render. (For why this ordering is mandatory on tvOS, see [guide › tvOS host setup](guide.md#tvos-host-setup).)

**Frame rate is required (#130).** An HDR master also needs a known source frame rate. When AVPlayer parses the master, it drops a `VIDEO-RANGE=PQ`/`HLG` variant that has no `FRAME-RATE` attribute, and fails the item with `-1002` without ever fetching the media playlist. (SDR variants are accepted without it.) The manifest frame rate comes from the probe's `avg_frame_rate`, with `r_frame_rate` as the fallback. A source where both are unset (some live MPEG-TS ingests) goes media-direct instead of serving a master AVPlayer would provably reject.

#### Per-mode capability table

The per-mode capability split (HDR10, HLG, Dolby Vision) still comes from `AVPlayer.availableHDRModes`. The 26 SDKs deprecate it in favour of the eligibility Bool but ship no per-mode replacement. Dolby Vision support needs exactly that split (the AV1 Dolby Vision packaging is gated on it, for one). So the engine keeps the deprecated read until Apple removes it.

- **The table may only ADD a mode, never subtract one (since 6.82.0).** `supportsHDR10` and `supportsHLG` take `eligibleForHDRPlayback` as their floor, because the table under-reports HLG over HDMI. Measured on a Samsung whose EDID advertises Hybrid Log-Gamma and which plays HLG in the TV's own player, connected straight to an Apple TV: the table reported `.hlg` absent. A second Apple TV on a different Samsung agreed. An iPhone 17 Pro on its built-in panel reported it present. So the absence is about the HDMI path, not the panel (AE#459).
- **That floor matters for one source.** `effectiveVideoFormat` guards on Dolby Vision, so `supportsHLG` is consulted only for a DV Profile 8.4. Without the floor, that source resolved to SDR on such a display while the manifest served `VIDEO-RANGE=HLG`. A plain HLG title was never clamped.
- **Dolby Vision is left on the table alone.** There it is measured correct in both directions (`false` on a Samsung without it, `true` on an iPhone 17 Pro the same day).

#### macOS capability table

The per-mode read does not exist on macOS at all (`API_UNAVAILABLE(macos)`). The Mac table is derived from eligibility for HDR10 and HLG, and leaves Dolby Vision unclaimed: eligibility proves EDR, not that AVFoundation will accept a DV variant on this display.

A host that knows the hardware claims Dolby Vision with `LoadOptions.panelPresentsDolbyVision`. For the failures AVPlayer reports as an item failure, a wrong claim costs one in-place fallback to the media playlist, not the item (AE#493).

The claim does not pick the packaging of a Profile 5, 8.1 or 8.4 source. 6.72.0 gave the non-DV branch its `dvcC` back and 6.73.0 its `SUPPLEMENTAL-CODECS`, so those three serve byte-identical manifests and segments with and without the claim. Profile 7 joined the three once it was converted on every display. What the claim changes is the published `videoFormat`, the criteria request and the HDR readiness that rides along. AV1 Dolby Vision is still gated on the claim.

On tvOS that leaves a gap. The `-15628` that an HDR10-only panel showed on the DV packaging in May 2026 (AE#4) is a stall, not an item failure. That packaging now reaches the panel with or without the claim, and the stall did not reproduce on tvOS 26.6. On tvOS, DV composition on a panel without Dolby Vision is what `forceDolbyVisionOnNonDVDisplay` is for (AE#455).

#### Label upgrade from the item (macOS, AE#515)

The label can also be taken back from the item itself, where the platform has no capability table to clamp it against.

A Dolby Vision source on macOS resolves to `.hdr10`, because `supportsDolbyVision` cannot be claimed there without a host assertion. Yet AVFoundation plays the `dvh1` sample entry the engine served anyway. Measured with the assertion off on a 16" XDR: a Profile 5 and a Profile 8.1 grade of Dolby's reference content both strobe. So the RPU (the per-frame Dolby Vision metadata) reaches the pixels with no claim set anywhere, and the clamp changed nothing but the label.

When the item's sample entry reads `dvh1` / `dvhe` and the probe agrees the source is Dolby Vision, the label is upgraded from `.hdr10` to `.dolbyVision` at `readyToPlay`. It is an upgrade and not a mirror of what AVFoundation parsed, for two reasons:

- An `.sdr` label is the clamp being right about a display presenting no HDR at all.
- On tvOS and iOS the per-mode table answers the capability question, so the label follows it rather than a sample entry that a Profile 5 master carries on every panel.

Profile 8.1 keeps `.hdr10` on macOS. It reports `hvc1` with the DV configuration alongside it, and it composes on that display all the same, but nothing in the stack reports that.

### Dynamic-range switch in parallel with the start (AE#348)

On a VOD load the dynamic-range switch and the session start run side by side.

- After an HDR or Dolby Vision criteria write, the pre-flight gate starts at the write, as before. Only the master-or-media choice waits for it.
- `HLSVideoEngine.prepare()` opens the source, plans the segments, starts the local server and starts the producer cutting the first segments while the panel is still switching.
- `serve(panelIsInHDRMode:)` picks the playlist once the gate has released and the panel has been read.

AVPlayer sees nothing before that. So the routing read happens no earlier than in the serial order, and a Dolby Vision write is never followed by a decode in the middle of the switch. The cold start becomes roughly the longer of the switch and the segment production, instead of their sum. For comparison: on an Apple TV 4K with a Dolby Vision title whose first two segments took 2.0 s to cut, the serial order started playback 1.5 s after the switch had ended.

`start()` is still `prepare()` followed by `serve` with the panel state given at init. Live loads keep the serial order, since their join is timed against the edge and the overlap has not been measured there.

### HEVC CODECS string and parameter sets

**CODECS string.** For non-DV HEVC, the primary `CODECS` string comes from the source `hvcC` profile_tier_level (profile space, profile, tier, level, constraint bytes). So an 8-bit Main source is not mis-declared as Main10. The compatibility-flags element is the stored `general_profile_compatibility_flags` in REVERSE bit order, per RFC 6381 / ISO 14496-15 Annex E. A real Main10 record stores `0x20000000` and prints `hvc1.2.4...`, matching MP4Box and Dolby's own reference manifests. The device checks the declaration against the init segment, so it has to be exact.

**Out-of-band parameter sets.** Whatever the profile, the `hvcC` shipped in `init.mp4` must carry the parameter sets out of band.

- Sources authored with in-band VPS/SPS/PPS only (`hev1`, `numOfArrays = 0`, which is what `MP4Box ...:xps_inband` and the common Dolby Vision MP4 recipes produce) are normalized at load: the engine scans the head of the stream for the parameter sets and rebuilds the record.
- A record that arrives with extra non-parameter-set arrays (libx265's user-data SEI) is stripped down to VPS/SPS/PPS.
- Shipping the source record verbatim in either case leaves AVPlayer with no usable format description: it buffers the whole forward window and never renders a frame.

H.264 gets the same rebuild (#938). An `avcC` with zero SPS or zero PPS (mkvmerge writes the 7-byte `01 64 00 20 ff e0 00` for such a track) is rebuilt from the first in-band SPS and PPS. movenc does the rebuild, so the High-profile extension comes out right, and the source's NAL length size is kept. Shipped verbatim, it fails differently from HEVC and more quietly: the item reaches `readyToPlay`, the clock runs and audio plays, but no frame is ever ready for display.

### Dolby Vision signaling

For DV streams the demuxer surfaces the source's `AVDOVIDecoderConfigurationRecord` (the Dolby Vision config record). The route depends on the profile's base layer: whether it has one, and which format it is compatible with.

| Profile | Base layer | Served as |
| --- | --- | --- |
| HEVC 5 | None (IPT-PQ) | `dvh1.05.<dvLevel>`, on every display |
| HEVC 8.1 / 8.4 | HDR10 / HLG | `hvc1` + `dvh1.08` in `SUPPLEMENTAL-CODECS`, on every display |
| HEVC 7 | HDR10 + enhancement layer | Converted to 8.1 (default), curve fold, or dual-layer composition |
| HEVC 8.2, AV1 10.2 | SDR Rec.709 | Plain base layer, no Dolby Vision |
| AV1 10.0 | None | `dav1.10.<dvLevel>` |
| AV1 10.1 / 10.4 | HDR10 / HLG | `av01` + `dav1.10` in `SUPPLEMENTAL-CODECS` |
| H.264 9 | SDR Rec.709 | Plain `avc1`, the Dolby Vision record stripped (Apple has no H.264 Dolby Vision decoder) |

The AV1 rows apply on a display that takes Dolby Vision. Elsewhere AV1 plays as plain `av01` (see [AV1 Dolby Vision](#av1-dolby-vision)). HEVC Profile 8 with a compatibility id other than 1, 2 or 4 (8.6, for example) is served as 8.1. AV1 Profile 10 with an unknown id is served as 10.0. Any other profile in an HEVC or AV1 record (not 5, 7 or 8 for HEVC, not 10 for AV1) fails the native load with `HLSVideoEngineError.unsupportedDVProfile`.

#### Profile 5

Profile 5 (DV-only, IPT-PQ, no base layer) emits a bare `dvh1.05.<dvLevel>` codec tag in the primary `CODECS` attribute, with the `dvcC` box preserved.

`dvh1` is forced even on non-DV panels. AVPlayer's system DV decoder tone-maps IPT-PQ internally; without `dvh1` the IPT chroma is read as YCbCr and shows a green / purple cast. P5 has no routing special case. It follows the normal HDR rule: a master on a panel ready for HDR (where the system's DV decoder tone-maps it, also on an HDR10 panel), and the media playlist on an SDR route.

#### Profiles 8.1 and 8.4

Profiles 8.1 / 8.4 (HDR10- / HLG-compatible base) emit `hvc1.2.4.L<level>` as the primary `CODECS` tag. The muxer writes the `dvvC` box, and the variant carries `dvh1.08.<dvLevel>/db1p` (8.1) or `/db4h` (8.4) in `SUPPLEMENTAL-CODECS`. That is what makes AVKit engage DV on a display that can present it.

Both are emitted on every display, not only a DV-capable one:

- The pairing is what the authoring spec asks for.
- It lets a client that does not know `dvh1` read the base layer instead of failing, and the loopback master reaches AirPlay receivers that are exactly that client.
- It makes AVPlayer put the RPU on the pixels wherever it has to convert the base layer, which on tvOS is every HDR source while the panel is not in HDR mode.

Older releases stripped it, because of an `-11868` measured on tvOS 26.0 that does not reproduce on 26.6. On a panel that is already in HDR, the base layer plays as plain HDR10 / HLG either way (AE#493).

#### Profile 8.1 on a non-DV display: `forceDolbyVisionOnNonDVDisplay`

With `LoadOptions.forceDolbyVisionOnNonDVDisplay` (experimental, default off, AE#455), Profile 8.1 on a non-DV display is served the way Profile 5 is: `dvh1` sample entry, the container `dvcC` rewritten to profile 5 / compatibility 0, `CODECS="dvh1.05.<dvLevel>"`, no supplemental.

- **What it buys.** AVPlayer then runs its own Dolby Vision composition and applies the per-frame RPU to the pixels before they leave the device. The default route gives the panel one static HDR10 grade.
- **Why it works.** The bitstream never changes, only the container's claim about it. A Profile 8.1 RPU already carries the mapping out of its own HDR10 base layer, so the composer does not need the container to describe that layer.
- **Why it is experimental.** This is not what the profile field means. A decoder that read the base layer's colorimetry from the profile rather than from the RPU would decode IPT out of YCbCr: the green / violet cast of #4 and #176.
- **Scope.** Profile 8.1, and Profile 7 once converted to it. Profile 8.4's base layer is HLG, and a profile-5 `dvcC` over an HLG `colr` is a container that contradicts itself.

#### Base layer only: `dolbyVisionHandling = .baseLayerOnly`

With `LoadOptions.dolbyVisionHandling = .baseLayerOnly`, any profile with a presentable base layer is served as that base layer alone, on every display: plain `hvc1` / `av01` sample entry, the `dvcC` stripped, no supplemental, no Profile 7 conversion, and HDR10 / HLG display criteria rather than `dvh1`. The RPU NAL units stay in the samples and are ignored.

**Why it is a host option and not a routing decision.** The case it exists for cannot be told from the container. It is a remux whose container record claims Profile 5, over a bitstream:

- whose VUI declares BT.2020 YCbCr PQ,
- whose RPU carries the NLQ and residual fields only Profile 7 has, with the identity as its mapping,
- whose base layer is plain HDR10 with its own static metadata.

Served as `dvh1.05`, the decoder reads YCbCr as IPT and the picture is green / violet. Served as its base layer, it is the HDR10 that every player ignoring the record shows. On the default route the engine logs the contradiction (`DV Profile 5 record over a BT.2020 YCbCr VUI`) so a host knows to offer the option.

**What is admitted:**

- HEVC Profile 7 / 8.1 / 8.4 and AV1 Profile 10.1 / 10.4, whose record names the base.
- A Profile 5 / AV1 10.0 record whose VUI names one (`matrix_coeffs` BT.2020 with a PQ or HLG transfer). A genuine Profile 5 leaves both unspecified, IPT having no VUI code point.

A Profile 5 whose VUI is unspecified has no base layer to present and keeps its route.

#### A Profile 5 record its own RPU contradicts (#532)

Such a source is served as what its RPU says, on every display, with no option to set.

**When it applies.** A remux whose container record claims Profile 5 over a bitstream whose VUI declares BT.2020 YCbCr with a PQ or HLG transfer states its own contradiction: IPT-PQ-c2 has no VUI code point, so a genuine Profile 5 leaves `matrix_coeffs` and `transfer_characteristics` unspecified.

**What happens.** For that pairing, and only for it, the engine reads the first `unspec62` RPU and takes libdovi's `guessed_profile` over the record. This is proof rather than a heuristic, because a Profile 5 RPU cannot carry a residual or an NLQ.

- An RPU that reads 7 takes the Profile 7 route below.
- An RPU that reads 8 takes the Profile 8.1 route and its compatibility rewrite, so the served container carries the record the source should have had.
- An RPU that agrees with the record, an RPU that cannot be read, and every source outside that pairing read no packets at all and keep their route. That is what makes the audit free for a genuine Profile 5.

**Details.**

- The read is a second open on the source, because the session's probe demuxer is handed to the software path as it stands.
- `LoadOptions.dolbyVisionHandling = .baseLayerOnly` takes precedence over the correction.
- The Profile 5 software-path refusal (#176) stands down for a corrected record, whose base layer is plain HEVC.
- AV1 Profile 10.0 is not covered: its RPU rides in an ITU-T T.35 metadata OBU rather than an `unspec62` NAL, so the base-layer option remains the answer for that class.

#### A Profile 5 the container never recorded (AE#567)

Such a source is given the record it should have carried. Some Matroska releases are Profile 5 with the `BlockAdditionMapping` dropped and a VUI that says nothing. Without the fix, the source loads as plain SDR and the IPT picture is decoded as YCbCr.

**When it applies.** HEVC 10-bit 4:2:0 with no Dolby Vision record and `color_trc`, `color_space` and `color_primaries` all unspecified. For that pairing only, the demuxer reads the first RPU from a second open at the end of its probe.

**What happens.** If libdovi's `guessed_profile` says 5, the demuxer appends an `AV_PKT_DATA_DOVI_CONF` (profile 5, level 6, rpu 1, el 0, bl 1, compatibility 0) to the stream's `coded_side_data`. Because it lives on the demuxed stream, the load, the HLS producer's own open, display criteria, the segment muxer's `dvcC` and every reload see a genuine Profile 5 record: `dvh1` sample entry, `CODECS="dvh1.05.06"`, `VIDEO-RANGE=PQ`, and the #176 software-path refusal.

It is served the way a recorded Profile 5 is, including the `colr nclx` repair. That repair is gated on an unspecified VUI, which is exactly this shape, and the same bytes cannot have two deliveries depending on what the container wrote down.

**Limits.**

- A failed read, or an RPU that reads anything else, leaves the source as it was.
- `.url` sources only (a custom reader has no second open). Live is skipped.
- `LoadOptions.dolbyVisionHandling = .baseLayerOnly` is unaffected, because a record with compatibility 0 has no base layer to present.

#### AV1 Dolby Vision

AV1+DV follows the same split as HEVC:

- **Profile 10.0** (DV-only, no base layer to fall back to) emits a bare `dav1.10.<dvLevel>` primary.
- **Profile 10.1** (HDR10-compatible base) emits an `av01...` primary plus `dav1.10.<dvLevel>/db1p` in the supplemental entry, with `VIDEO-RANGE=PQ`.
- **Profile 10.4** (HLG-compatible base) emits an `av01...` primary plus `dav1.10.<dvLevel>/db4h`, with `VIDEO-RANGE=HLG`.

On hardware-AV1 hosts the cross-compatible profiles (10.1, 10.4) are signaled this way. The `dav1` sample entry belongs to the profile without a base layer, the way `dvh1` belongs to Profile 5. A cross-compatible profile carries its base layer's own sample entry, so a client that cannot read Dolby Vision still plays it.

**Only on a Dolby Vision display.** Unlike HEVC Profiles 5 and 8, the AV1 packaging above is used only where the display takes Dolby Vision (the per-mode table, `panelPresentsDolbyVision` on a Mac, or `keepDvh1TagWithoutDV`). Everywhere else the record is dropped and the stream is served as plain `av01` with the range its VUI declares, so a 10.1 or 10.4 plays as its HDR10 or HLG base. A genuine Profile 10.0 declares no VUI range, so on such a display its IPT picture goes out as an SDR `av01` stream. That case has not been measured on a device.

**AV1 Profile 10.1 on the software host** gets its Dolby Vision from the engine rather than from AVFoundation. AVFoundation ignores the RPU an AV1 stream carries in its ITU-T T.35 metadata OBU and shows the HDR10 base layer.

- The RPU of a 10.1 stream is the RPU of an HEVC 8.1 stream in another wrapper. The decoder reads it out of each temporal unit (one frame's data). libdovi rewraps it into the `unspec62` form that VideoToolbox attaches to an HEVC 8.1 frame. The decoded frame then carries it under the same two keys, on the buffer and on its IOSurface (`DoviDisplayMetadata`), and the system's Dolby Vision display management applies it.
- dav1d attaches it where AV1 has no hardware decode (every Apple TV, M1 / M2 Macs, pre-A17-Pro iPhones), which is where AV1 plays on the software host anyway.
- Where VideoToolbox decodes AV1 and the host loads with `LoadOptions.preferredDecodePath = .software`, `HardwareVideoDecoder` decodes it and hands out each frame as a copy in a pool of its own, because on VideoToolbox's own output buffer the attachment never reached the panel.
- Measured with a pulse clip (constant pixels under an RPU that alternates): it pulses on an Apple TV 4K (3rd generation, tvOS 27) into an LG CX, and on macOS 27 (M5 Pro), where it composites to within 0.0001 PQ of the same RPU played as HEVC 8.1 through AVPlayer. A null-RPU clip stays steady.
- Profile 10.0 (no base layer) and 10.4 (its HLG base is unmeasured) keep the plain path.

#### Profile 7

Profile 7 (dual-layer, the common UHD Blu-ray remux profile) is handled according to two options: `LoadOptions.preferDualLayerDolbyVision` (default `false`, so dual-layer composition is opt-in) and `LoadOptions.dolbyVisionHandling`. The dual-layer composer is an optional component, compiled only with the `DualLayerDolbyVision` package trait (off by default, [Installation › Optional components](installation.md#optional-components)). Built without it, `preferDualLayerDolbyVision` changes nothing and every Profile 7 source takes the single-layer conversion.

| Route | When |
| --- | --- |
| Dual-layer composition | `DualLayerDolbyVision` trait, `preferDualLayerDolbyVision = true`, `dolbyVisionHandling` `.automatic`, `el_type` FEL, VideoToolbox HEVC hardware decode, seekable VOD |
| Curve fold | `DolbyVisionFelCurves` trait, FEL, the native route, `foldsDolbyVisionFEL` (default on). Paused on tvOS while a panel without Dolby Vision presents HDR (AE#1018) |
| Single-layer conversion (default) | `preferDualLayerDolbyVision = false`, a build without the `DualLayerDolbyVision` trait, or no VideoToolbox HEVC hardware decode |

**Dual-layer composition.** The software host decodes the base and enhancement layers in VideoToolbox and composes them with the RPU at 12-bit precision on the GPU (`DualLayerVideoDecoder`, `DoviFelComposer`). The composed frame carries the RPU converted to Profile 8.1 for tvOS display management. MEL sources (minimal enhancement layer) keep the native route. The route does not consult the display.

It gives up what the software host gives up: AVPlayer's PiP, I-frame thumbnails, native subtitle renditions, the AirPlay picture, and E-AC-3 Atmos objects unless `objectAudioRendering` is set ([Atmos on the receiver](#atmos-on-the-receiver-tvos)). Every Profile 7 load logs `DV P7 dual-layer route: taken` or `not taken (<reason>)`. Design, gate and trade-offs: [Dolby Vision FEL › 5.2 Routing](dolby-vision-fel.md#52-routing).

**The AVPlayer-output variant.** With `LoadOptions.dualLayerRoute = .avPlayerOutput` (same trait, opt-in), AVPlayer decodes the base layer and plays the audio, and the engine composes onto AVPlayer's own decoded frames instead of running the software host. The item keeps the clock, transport and audio, so the Atmos trade-off above does not apply. A position whose enhancement layer is not at hand shows AVPlayer's base-layer frame. Run on macOS only so far. See [api › `dualLayerRoute`](api.md#duallayerroute) and [Dolby Vision FEL › 5.2.4](dolby-vision-fel.md#524-the-avplayer-output-route).

**Curve fold.** This is the single-layer conversion below with two additions: the FEL RPU's own mapping is kept, and the enhancement layer's luma residual is folded into each scene's luma polynomial, so the platform decoder applies it. `LoadOptions.foldsDolbyVisionFEL = false` turns it off for one load. Where the RPU cannot reach the picture (tvOS, a display without Dolby Vision whose panel presents HDR, off the `forceDolbyVisionOnNonDVDisplay` route) it pauses and logs `[FelCurves] fold paused`. This is the recommended way to bring a FEL source's enhancement layer back in a distributed app. See [Dolby Vision FEL › Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route).

**Single-layer conversion (the default).** No Apple platform has a Profile 7 decoder, so the engine converts the stream to single-layer **Profile 8.1** live during muxing:

- The RPU of each video packet is rewritten with [libdovi](https://github.com/superuser404notfound/LibDovi) (`dovi_convert_rpu_with_mode`, mode 2, the same transform as `dovi_tool -m 2`).
- The enhancement-layer NALs are dropped, and the container `dvvC` is set to Profile 8.1.
- The conversion runs on every display, and the result is served exactly as a Profile 8.1 is.
  - On a DV-capable display this means real Dolby Vision (`dvh1.08/db1p` supplemental) instead of the plain HDR10 base.
  - On a display without Dolby Vision, the kept `dvvC` lets AVPlayer apply the RPU wherever it converts the base layer: while a tvOS panel is in SDR, on the `forceDolbyVisionOnNonDVDisplay` route, and on a Mac.
  - A tvOS panel without Dolby Vision that presents HDR shows the HDR10 base layer bit for bit (AE#1018).
- Without the conversion every Mac (no per-mode table) and every HDR10 / SDR panel would lose the RPU, and the enhancement layer would ship in segments nothing decodes.
- The conversion loses nothing that Apple hardware could show anyway, since the enhancement layer was never decodable there. It handles MEL and FEL sources. A Minimal (MEL) source loses nothing. A Full Enhancement Layer (FEL) source is logged, because this route discards its enhancement layer, which a native Profile 7 player would fold in (the dual-layer route above keeps it).
- Any per-packet conversion failure drops that RPU, so the frame degrades to the clean HDR10 base rather than shipping a Profile 7 RPU inside a container already declared 8.1.
- A session that converts publishes `dolbyVisionConversion = .profile7ToProfile81`, so a host label can name the profile actually served next to `sourceDVProfile`.

#### SDR-compatible-base profiles

HEVC **Profile 8.2** and AV1 **Profile 10.2** carry a Rec.709 base layer that no Apple platform has a DV decoder for. The engine strips the `dvcC` / DV config and plays the base as plain `hvc1` / `av01` (logging `not DV-routable, playing Rec.709 base`). There is no Dolby Vision on any display for these, on DV panels and SDR panels alike.

### HDR10+ dynamic metadata

HDR10+ metadata (ST 2094-40) stays in the HEVC bitstream as user-data-registered ITU-T T.35 SEI NALs. The HLS-fMP4 stream copy keeps the SEI all the way to `AVPlayer`, which forwards it to the system compositor. HDR10+-capable TVs apply the per-scene tone-mapping curves. HDR10-only TVs fall back to the static HDR10 base.

**The `videoFormat` label.** The published `videoFormat` starts at `.hdr10` for any BT.2020 / PQ source, and flips to `.hdr10Plus` the first time the producer validates a packet's HDR10+ metadata.

- That includes a Dolby Vision source with an HDR10+ layer next to its RPU (Blu-ray Profile 7 has one, and so does a Profile 8.1 remuxed from one), whenever the label resolved to its HDR10 base. `sourceVideoFormat` keeps saying `.dolbyVision`.
- The evidence is latched per session, so a label republished later by the panel proof (AE#459) keeps it.
- It is debounced across producer restarts, so a scrub does not re-fire it.
- Hosts can drive an HDR10+ badge or analytics hook off the `$videoFormat` transition.

**The metadata probe.** The opt-in metadata probe uses the same structural validator.

- Codec metadata framing, registered T.35 identifiers and the complete ST 2094-40 payload must all be valid. A matching byte sequence inside compressed picture data is not metadata.
- FFmpeg's parsed HDR10+ packet side data remains another supported carriage, including VP9/AV1 Matroska.
- No video decoder is opened just to inspect HEVC metadata.
- Probe confirmation sets `SourceProbe.carriesHDR10PlusMetadata` independently of the primary format, so `.dolbyVision` is kept.
- Absence of confirmation is not proof of absence, and says nothing about the connected display.

See [whole-probe limits and cancellation](api.md#whole-probe-limits-and-cancellation) for bounded source reads.

### HDR Vivid (CUVA) dynamic metadata

HDR Vivid (CUVA T/UWA 005.1) is built to be backward compatible: the base layer is plain HLG or PQ in BT.2020, and its dynamic metadata is an optional registered T.35 SEI on top (country 0x26, provider 0x0004, oriented code 0x0005).

- The engine plays that base exactly like any HLG or HDR10 source, and the SEI is stream-copied with the rest of the bitstream.
- No Apple platform applies it. A display without Vivid support shows the static base, which is the format's intended fallback.
- There is no host-side tone mapping: the native route has no pixel stage, tvOS gives an app no EDR or panel-peak reading to map against, and the TV maps the HDR signal itself (#699).

**Probing.** `probe(url:detecting: .hdrVivid)` reports carriage as `SourceProbe.carriesHDRVividMetadata`, in the same packet pass and budget as `.hdr10Plus`. libavcodec's CUVA parser is internal, so `HDRVividMetadataScan` walks the message body itself, with the same field widths. It counts a message only when its `system_start_code` is one of the defined 1 to 7, all its fields are present, and the bits after its last field are zero. HEVC only, as in libavcodec. `videoFormat` stays `.hlg` / `.hdr10`.

## Audio

| | |
| --- | --- |
| Stream-copy (lossless into fMP4) | AAC-LC, AC3, EAC3, FLAC, ALAC. See the exceptions below. |
| Bridged (`AudioBridge`) | TrueHD, MLP, DTS, DTS-HD MA, MP3, MP2, Opus, Vorbis, PCM (raw shapes plus G.711 A-law / mu-law and DVD LPCM), WMA (Standard, Pro, Lossless, Voice), the Flash tail Nellymoser Asao / ADPCM-SWF / Speex, RealAudio (Cook, ATRAC3, Sipro, Lossless, 14.4 / 28.8) and AMR-NB / AMR-WB: decoded to PCM and re-encoded |
| Surround | 5.1 / 7.1 with correct `AudioChannelLayout` preserved through the wrapper |

Stream-copy exceptions:

- **HE-AAC / HE-AACv2** stream-copy when the source carries an AudioSpecificConfig (any movie container), and bridge only without one (live ADTS / MPEG-TS, where a synthesized ASC would mis-signal SBR).
- **LATM/LOAS-framed AAC** (DVB broadcast framing) always bridges.
- **AAC whose AudioSpecificConfig says `channelConfiguration` 0** bridges (AE#1047). That value means the channel layout sits in a Program Config Element (PCE), which FFmpeg's AAC encoder writes for any layout without a standard number, such as 6.0. CoreMedia refuses the record and the item fails with `-11829` / `-12848`. Relabelling it with a standard number opens the item but plays silence, because the PCE's element order no longer matches. libavcodec reads the PCE, so the bridge plays it.
- **FLAC whose `STREAMINFO` `min_blocksize` is below 192** bridges too (AE#764). CoreMedia drops a track that declares less, and hangs on frames smaller than the field claims, so such a stream cannot be copied. The bridge is bit-perfect for FLAC.
- **Audio-only FLAC.** The same `min_blocksize` field sends an audio-only FLAC to the FFmpeg host instead of AVPlayer. So does any audio-only FLAC in the raw `flac` container, whose seeks CoreMedia misplaces (AE#946).
- **Audio-only AAC with a PCE.** The same `channelConfiguration` 0 sends an audio-only AAC to the FFmpeg host. On AVPlayer it opens and ends at 0 s (AE#1047).

**Audio-only files** take one of two hosts:

- From a URL, AVPlayer plays AAC, MP3, MP2, MPEG-1 Layer I, ALAC, FLAC, AC-3, E-AC-3 and PCM (16-bit little and big endian, 24-bit little and big endian, 32-bit float).
- Everything else, every custom `IOReader` source and `preferredDecodePath = .software` go to the FFmpeg host.
- FLAC also leaves AVPlayer in the two cases above, and when its frames carry fewer samples than `STREAMINFO`'s `max_blocksize` (AVPlayer mistimes those, AE#946).

See [architecture › Audio-only pipeline](architecture.md#audio-only-pipeline-music-podcasts-audiobooks).

**PCM shapes the bridge decodes.** Signed 8, 16, 24 and 32-bit integer and 32 / 64-bit float PCM, each little and big endian where the shape has an order, plus unsigned 8-bit, G.711 A-law / mu-law, Blu-ray LPCM and DVD LPCM. That covers the 24-bit big-endian PCM camera MOVs record (QuickTime `in24`) and 32-bit WAV. MPEG-1 Layer I (`mp1`) bridges like MP2. All of these need FFmpegBuild 3.15.0; with an older build a track in one of the newer shapes plays silent inside a video file (`audioDelivery` reads `.droppedNoPipeline`).

### Audio bridge modes

Non-streamable codecs route through `AudioBridge` in one of two modes (`LoadOptions.audioBridgeMode`):

| Mode | Encoder | Needs | Notes |
| --- | --- | --- | --- |
| `.surroundCompat` (default) | Chosen per source: EAC3 above two channels, FLAC for two or fewer | Any AVR or soundbar, including legacy ARC | Caps 7.1 to 5.1 |
| `.lossless` (opt-in) | FLAC up to 7.1 | A sink that takes multichannel LPCM | Bit-perfect, also at 96 and 192 kHz |

- **`.surroundCompat`** (default): the encoder is chosen per source, not per mode.
  - A source with more than two channels is re-encoded to lossy EAC3 at 128 kbps per channel (768 kbps 5.1). AVPlayer hands the encoded bitstream to HDMI and the sink decodes its own 5.1 mix, so surround works on essentially every AVR and soundbar, including one behind legacy ARC.
  - Two channels or fewer have no surround to carry and take the FLAC encoder instead. That is lossless where EAC3 would have been 256 kbps lossy, and the route decodes it to LPCM on routes that can only pass a Dolby bitstream through.
  - Why stereo avoids EAC3 (AE#395): an AirPlay 2 optical adapter played one MPEG-TS program's stream-copied AC3 5.1 but was silent on the bridged EAC3 stereo of the same program. So whichever track `av_find_best_stream` happened to pick decided whether the viewer heard anything.
- **`.lossless`** (opt-in): FLAC up to 7.1 lossless, which AVPlayer decodes to LPCM. It needs a sink that takes multichannel LPCM: an AVR over HDMI, or an AVR or soundbar on eARC. A Sonos Arc on eARC takes 6-channel LPCM, so a 7.1 source arrives there as lossless 5.1, folded by tvOS. Behind legacy ARC, which carries stereo LPCM or a Dolby bitstream only, the LPCM is downmixed to stereo, and `.surroundCompat` is the right mode.

**The host picks the mode (AE#794).** The engine does not pick between the two from the route, because it cannot tell them apart. With tvOS's Continuous Audio Connection on, every HDMI route reports 32 unlabelled channels, whatever the sink takes. An eARC soundbar and a legacy-ARC one look the same, and a wrong FLAC pick on the second plays stereo.

`.surroundCompat` is the default because the soundbar / basic-AVR install base is the majority.

**Sample rates (AE#548).** Either encoder opens at a sample rate it actually supports, which is not always the source's.

- E-AC-3 exists at 32 / 44.1 / 48 kHz only, so a 96 kHz TrueHD or DTS-HD master is resampled to 48 kHz on the `.surroundCompat` arm. Opening the encoder at the source rate would make `avcodec_open2` refuse the context and drop the whole session to silent video-only.
- The rates come from `avcodec_get_supported_config`, so an FFmpeg bump that widens them needs no change here.
- An encoder that advertises no list (FLAC) keeps the source rate untouched. That is what keeps `.lossless` bit-perfect at 96 and 192 kHz.
- The resampler is in the path on every bridged packet either way, so the conversion costs nothing that was not already being paid.

**Object metadata.** Object metadata (TrueHD Atmos objects, DTS:X heights) is lost in either mode: FFmpeg's EAC3 encoder does not produce JOC, and FLAC has no object-channel concept. `objectAudioRendering` is the route that keeps it. It needs a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default, [Installation › Optional components](installation.md#optional-components)), and renders the objects into a speaker bed delivered as APAC ([TrueHD Atmos with heights](#truehd-atmos-with-heights)). If a JOC source ever falls through to the bridge, the engine logs a loud `WARNING: Atmos downgrade, ...`.

### Bridge lifecycle (#99)

Two invariants:

- **Shared timeline.** On every session start and producer restart, the encoder's PTS counter re-bases onto the (gate-shifted) source PTS of the first packet fed. So bridged audio always shares the video's output timeline, including a `load(startPosition:)` resume that starts mid-file. (A bridge timeline starting at 0 would put the audio a full resume offset away from the video inside the same fragments, and AVPlayer silently discards that.)
- **Encoder rebuild after EOF.** The EOF tail flush leaves the encoder in FFmpeg's terminal draining state, so the bridge latches that and rebuilds the encoder on the next restart. A VOD pump that still dies with `muxerFailed` gets a bounded producer rebuild instead of stranding the session.

### Audio that ends before the picture (AE#847)

AVPlayer ends a muxed HLS item the moment its audio runs out, however much video is left. Seeking again in place does not get past it. Measured on a 60 s HEVC track over 35 s of AC-3, both from the engine's loopback and from a plain ffmpeg fMP4 playlist. A gap in the audio is harmless: with audio at 0-35 s and 59-60 s the same item plays to 59.99 s, also when started inside the gap.

**The fix (`AudioTailPadding`).** When the producer reaches the end of the file and the audio it wrote stops more than half a second short of the video, the final segment gets silence up to the end of the picture. The silence starts where the audio stopped, or at the segment's own start if the audio stopped earlier, and is written in whole frames of the delivered codec.

- **Padded:** AC-3, E-AC-3 and FLAC always; AAC-LC and ALAC since FFmpegBuild 3.10.0 (the encoders come from the FFmpeg build).
- **Not padded:** HE-AAC, MP3, Opus and a stand-in sample entry (the APAC bed). These log `AE#847 audio tail not padded` with the reason.
- **Limit.** The fill exists only in the segment written at end of file. On a source that arrives barely faster than its bitrate, with a silent tail longer than the producer's lead, AVPlayer waits at the end of the audio until that segment exists, and then plays on.

### Audio shaping

`LoadOptions.audioShaping` / `setAudioShaping(_:)` (AE#923) shape the decoded PCM before it is re-encoded (loopback) or rendered (software host, FFmpeg audio-only host). Five settings, in any combination:

| Setting | Field | What it does |
| --- | --- | --- |
| Channel cap | `maxChannels` | Folds the source to at most that many channels |
| Dialogue lift | `dialogueGainDB` | Raises dialogue, up to 12 dB |
| Night mode | `compressor` | Compresses dynamics |
| Loudness target | `loudnessTargetLUFS` | Raises a quiet source to a programme loudness (AE#1036) |
| LFE in the fold | `lfeMixDB` | Keeps the LFE when the cap folds it away (AE#1044) |

**Channel cap (`maxChannels`).** The source is folded to at most that many channels with libswresample's own downmix (centre and surrounds at -3 dB, LFE dropped), the same fold the route would otherwise make. A cap decides the bridge encoder as a source with that many channels would, so a 5.1 source capped to stereo is FLAC, not stereo E-AC-3. A source is never upmixed.

**LFE in the fold (`lfeMixDB`, -20 to +10 dB).** By default a fold that leaves the output without an LFE drops it. With a level set, the LFE is mixed into the fold instead (AE#1044).

- **Who needs it.** A 2.1 system behind a stereo link, for example a TV that sends 2.0 PCM over optical to a stereo streamer with a subwoofer. That subwoofer only hears what is low in left and right, so whatever lives only in the `.1` of a film never reaches it.
- **What the number means.** It is libswresample's `lfe_mix_level`. On stereo out each side gets the LFE 3 dB below the value, on mono out the one channel gets it at the value. Measured on a 5.1 fixture capped to stereo: at 0 dB the LFE arrives at 0.707 of its level on each side, at -6 dB it is 6.0 dB lower, without a level it is gone.
- **When it does nothing.** Only a cap that folds the LFE away uses it. A cap that keeps an LFE (7.1 capped to 6 channels is 5.1) leaves it discrete. Without a cap the value is stored but nothing is active, so it does not move a stream-copied track onto the bridge.
- **Headroom.** The fold stays unnormalized. A loud LFE summed into loud fronts is caught by the limiter below.
- A second LFE (`LOW_FREQUENCY_2`) is not folded.

**Dialogue lift (`dialogueGainDB`, up to 12 dB).**

- **Source with a front centre.** The centre is raised wherever it lands, discrete or folded, in the remix matrix (no cost per sample). Measured on a 5.1 fixture with a tone on the centre only and another tone on every other channel, folded to stereo: 3, 6 and 9 dB asked move the centre tone 3.0, 6.0 and 9.0 dB against the other, on the bridge and on the software decoder alike.
- **Source without a centre that plays as stereo.** The dialogue is extracted by libavfilter's `dialoguenhance` and folded back onto both sides with `pan`. On a stereo fixture of a centred, gated 1 kHz tone over noise that differs between the sides, 3, 6 and 9 dB asked raise the tone 3.9, 7.4 and 10.6 dB against the noise.
- **Why `dialoguenhance`.** It beat a mid/side lift, measured on a mix of centred speech and wide music: at +6 dB the mid/side lift gained 2.0 dB against the wide music, `dialoguenhance` 5.1 to 7.2 dB. Neither separates speech from music mixed to the centre itself (0 to 1.2 dB); no stereo method can.
- A mono source is left alone.

**Night mode (`compressor`).** libavfilter's `acompressor`, peak detection, one gain for all channels so the image does not move. The `night` preset compresses everything above -30 dBFS 4:1 and adds 10 dB. Measured on a steady 1 kHz tone: 0 dBFS in comes out at -12.2 dBFS, -20 at -17.2, -40 at -30.0.

**Plain gain.** A compressor with `ratio: 1` compresses nothing, so `AudioShaping(compressor: .init(thresholdDB: 0, ratio: 1, makeupGainDB: g))` is a plain gain of `g` dB (up to 24) into the limiter. This is a supported use. Measured on a steady 997 Hz tone: -20 dBFS at +6 dB comes out at -14.0 dBFS, 0 dBFS at +12 dB stays at the -1 dBFS ceiling. A fixed gain is the same for every film; the loudness target below adapts it per film.

**Loudness target (`loudnessTargetLUFS`, -36 to -12 LUFS).** Raises a quietly mastered source to a programme loudness, for example -24 (broadcast loudness) or -16 (louder).

- **What is measured.** The integrated loudness of ITU-R BS.1770 / EBU R128 (K-weighting, 400 ms blocks every 100 ms, absolute gate -70 LUFS, relative gate -10 LU) over everything the source has played so far, after the channel cap and the dialogue lift. The LFE does not count, surrounds count 1.41 times a front. Measured against the standard's reference: a 0 dBFS 997 Hz tone reads 0.0 LUFS on both fronts and -3.01 on one, at 44.1, 48 and 96 kHz alike.
- **What is applied.** The difference to the target, never below 0 dB and never above 18 dB, in front of the compressor and the limiter. A source already at or above the target plays as it was. Measured on a steady -36 dBFS tone with a -24 target: it settles at -24.0; at -50 dBFS it stops at the 18 dB cap.
- **How fast.** The gain rises at most 2 dB per second and falls at most 6 dB per second, so the start of a quiet film fades up over a few seconds instead of stepping. Because the measurement covers the whole film so far, one loud or quiet scene barely moves it, and silence (below the gates) does not move it at all.
- **Seeks.** A seek keeps the measurement and the gain: the source is still the same programme. A new track or a new session measures from scratch.
- **No latency.** Each chunk plays at the gain the audio before it asked for, and is measured afterwards. libavfilter's `loudnorm` was not used because its dynamic mode only takes 192 kHz input and holds back 3 s of audio before its first output, which every start, seek and live tune would pay.
- The limiter keeps the lifted audio under -1 dBFS. A loud scene in a film lifted by 18 dB is limited hard, so the target is best kept moderate.

**Limiter.** Whenever shaping is active, libavfilter's `alimiter` runs last, at -1 dBFS with a 5 ms lookahead and its own latency compensation.

- It is what lets the fold stay unnormalized. Normalizing a 5.1 fold costs 7.6 dB of level, the opposite of what someone who cannot hear the dialogue asked for.
- It is what lets the makeup gain be generous.
- It is used instead of an instant-attack limiter because it measured far cleaner. On a steady overload its THD was -155 dB against -48.6. On two tones under limiting bass hits, its splatter above 3 kHz was -67 dB against -42 (relative to the tones), at the input's own floor.

**Timing.** `dialoguenhance` delays its content by three quarters of its FFT window (1536 samples at 48 kHz, 3072 at 96 kHz) and stamps its output with its input's timestamps regardless. So the engine runs the graph on a sample counter of its own: it drops the delay's priming, pushes the same number of silent samples at the end of the stream, and carries the timestamps itself. Output sample k is then input sample k. Measured: an impulse at sample 60000 of a stereo source comes out of the bridge at sample 60000 with 96000 samples in and out, and the software decoder presents it at 1.25000 s, its source time.

**Requirements.** The graph (`AudioShapingGraph`) needs FFmpegBuild 3.11.0 or later, which adds `abuffer`, `abuffersink`, `aformat`, `aresample`, `pan`, `dialoguenhance`, `acompressor` and `alimiter`. The loudness target needs no filter of its own (it is Swift, `LoudnessNormalizer`). Where the graph cannot be built, the remix still applies and the log says the dynamics do not; the loudness target is then off as well, because without the limiter its gain could clip.

**What it costs.** Shaping needs PCM.

- While it is active, a stream-copied track is decoded and bridged, so Atmos (E-AC-3 JOC) and every bitstream that would otherwise pass through arrive as their channel bed.
- On the software host the compressed E-AC-3 JOC route and the object render are skipped.
- Turning shaping off goes back to stream copy.
- Where AVPlayer owns the audio (`.remoteBypass`, the native audio-only host) there is no PCM to shape, and `$audioShapingState` reads `.unavailable`.

### Audio a build has no decoder for

AC-4 (ATSC 3.0 / NextGen TV) and MPEG-H 3D Audio have no decoder in the bundled FFmpeg, and there is nothing to switch on.

- FFmpeg carries codec ids for both so a container can be demuxed, but `libavcodec/allcodecs.c` names neither.
- The AC-4 decoder patches have sat out of tree for years, and the format is Dolby patent-encumbered.
- MPEG-H has an upstream wrapper around Fraunhofer's `mpeghdec`, whose licence is not LGPL-redistributable.
- Apple's own stack does not fill the gap either: there is no AC-4 format constant in CoreAudio.

**Such a track is expensive, not just silent.** `has_codec_parameters` fails an audio stream with no sample rate, and that value can only come from the container or from opening a decoder. So `find_stream_info` reads the full probe budget, then gives up and opens with the track missing anyway. On a live source that budget is spent at the wire rate. That is where Sodalite#100's minute-long tuning indicator came from.

**What the engine does.** The demuxer hides such a stream from the probe (one whose codec has no decoder AND whose parameters the container left unset), and restores it right after. The open then costs what it would without the track, and the caller still sees the track in `audioTracks`. A host with its own metadata can do better still and refuse the channel with a real sentence (Jellyfin names a live channel's audio codec in PlaybackInfo without opening a tuner).

### Track language on the native path

AVFoundation reads a track's language from the master playlist, not from the media. So the engine also declares there the audio it muxes into its single variant:

- one URI-less `EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="<iso 639-2/T>",DEFAULT=YES,AUTOSELECT=YES`,
- plus `AUDIO="aud"` on the variant.

(RFC 8216 4.3.4.2.1; the URI is absent precisely because the audio is inside the variant.) AVPlayer then exposes it as a one-option audible `AVMediaSelection` group and labels it from `LANGUAGE`, which is what a system audio menu shows.

Measured on macOS 26: when the master does not declare the rendition, an fMP4 whose audio `mdhd` reads `deu` reports `AVAssetTrack.languageCode == nil` and no audible group at all. The identical `mdhd` read from a progressive `.mp4` reports `deu`. The engine writes the `mdhd` too (the track is that language whoever reads it), but that is not where the label comes from.

The rendition is advertised only when the audio actually reached the variant, so an audio cascade that fell through to video-only never names a group its segments do not carry (AE#458).

**Resolving source labels.** Source labels are resolved to ISO 639-2/T in these steps:

1. **ICU.** Covers every language ICU knows plus BCP-47 subtags (`pt-BR` becomes `por`), and rejects free text such as `English` or a track title.
2. **A twenty-row table** in front of ICU, for the ISO 639-2/B bibliographic codes ICU does not resolve and Matroska routinely writes (`ger`, `fre`, `cze`).
3. **ISO 639-3 members CLDR aliases to a macrolanguage** (`cmn`, `arb`, `pes`, `swh`, `uzn`, `kmr`) have no alpha3 entry at all. The tag is canonicalized where the direct route came back empty, which resolves the alias without moving any tag that already resolved (`no` stays `nor`, not `nob`).
4. **ISO 639-3 members CLDR does NOT alias** (`cnr`, `prs`, `npi`, `ory`, `quz`, `crs` and 50 more, 56 measured on macOS 26) have neither an alpha3 entry nor a canonical form. There is nothing to convert: the tag already IS the ISO 639 code, so it passes through as itself. This step requires ICU to have a display NAME for the tag in a fixed reference locale. That is the validity signal canonicalization cannot give (`canonicalLanguageIdentifier` echoes `dub` and `xyz` back unchanged exactly as it echoes `cnr`). The locale is fixed rather than the device's, or a file would resolve on an English Apple TV and not on a German one.

A label that resolves to nothing writes nothing, so an untagged source's master stays as it is. The one exception is a stream-copied E-AC-3 JOC track (AE#726, next section), which gets a rendition without `LANGUAGE` because its `CHANNELS` has nowhere else to go.

### Every audio track in AVKit's audio menu

With `LoadOptions.nativeAudioTrackMenu` on, a stock `AVPlayerViewController` lists every audio track of the source in its audio menu, and a pick there switches the track (AE#1049). It is off by default. A host with its own track picker gains nothing from it.

**How it works.** The variant still carries one muxed audio track. The master lists the others in the same `aud` group as entries without a URI, with `DEFAULT=NO,AUTOSELECT=NO`. When the viewer picks one, the engine sees the item's audible selection change and calls `selectAudioTrack(index:)`. That is the usual audio switch, a reload that holds the last frame for about 120 to 140 ms on an Apple TV.

**Names in the menu.** Each entry is named like a subtitle rendition: the track's title if it has one, otherwise the language. AVFoundation labels the entry that is playing by its language only and ignores its `NAME` (measured on tvOS 26 and macOS 27), while the other entries show their `NAME`. So when a language appears more than once, a track that would be named by the bare language becomes "English (Track 2)", and the playing track cannot be confused with it. Names are fixed for the session and do not change when the track does.

**Why the extra entries need `AUTOSELECT=NO`.** With `AUTOSELECT=YES` on every entry, AVFoundation passed over `DEFAULT=YES` and picked the entry in the system language (macOS 27).

**What a pick does before the reload.** Picking an entry that is not in the variant keeps the muxed track playing on tvOS 26. On macOS 27 the clock stops with `rate` 1.0 and no error. The reload replaces the item either way.

**After the reload.** AVKit carries the viewer's pick over to the new item as a language preference. With two tracks in one language it can land on the wrong one, so the engine selects the served entry on the new item before it watches for picks again.

**Where it does not apply.** Only the loopback route, and only where `selectAudioTrack` can switch: not on a forward-only custom source, not on a sequential origin, not for companion-demuxed live audio. The served track also needs a master audio rendition, which means a language (or untagged E-AC-3 JOC, see above).

### Dolby Atmos

EAC3+JOC packets are stream-copied through the muxer untouched, on every output route.

AVPlayer reads the segment and recognises JOC (Joint Object Coding, the Atmos layer of E-AC-3) from the `dec3` box's ETSI TS 103 420 extension: `flag_ec3_extension_type_a = 1` followed by `complexity_index_type_a`, the object count. The height channels that a dependent substream adds are named by that substream's `chan_loc` bits. AVPlayer then lets the downstream renderer decide:

| Output | Result |
| --- | --- |
| HDMI | Tunnels out as Dolby MAT 2.0, the AVR lights up the Atmos indicator |
| AirPods | Renders spatially |
| Plain Bluetooth A2DP / LE | Downmixes the bed channels to stereo natively |

The route never changes the engine's decision. A JOC track is signaled in the playlist as `ec-3`, the same CODECS string as a non-JOC EAC3 5.1 track, so AVPlayer accepts it everywhere and the bitstream is never re-encoded for a route reason. The engine emits an explicit `[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged; ...` diagnostic on every Atmos session.

**`CHANNELS` on the audio rendition.** `CODECS` cannot carry the distinction. A JOC track is signaled `ec-3`, the same string a non-JOC E-AC-3 5.1 track gets (#34: never `ec+3`, which tvOS 26.5 refuses). So that attribute says nothing about objects either way, and the `dec3` box sits a layer below the playlist. The master's `EXT-X-MEDIA:TYPE=AUDIO` tag therefore carries `CHANNELS`. Apple's HLS Authoring Specification requires it on every audio rendition. Dolby's DD+ Online Delivery Kit defines it for object audio as the count of decodable objects, a slash, then `JOC`.

- The engine writes `CHANNELS="16/JOC"` for a stream-copied E-AC-3 JOC rendition, and the plain served channel count otherwise (`CHANNELS="6"` for a 5.1 bed).
- A source whose audio never reached the variant advertises no rendition, and so gets no attribute.
- **Untagged JOC (AE#726).** An untagged JOC stream copy still gets a rendition: `NAME="Dolby Atmos"`, no `LANGUAGE`, `CHANNELS="16/JOC"`. That rendition forces the master on an SDR source the same way a language does. AVFoundation lists it as one audible option named "Unknown" (measured on macOS against Dolby's untagged JOC test signal). A master without that rendition builds no audible group at all. An untagged track that is not object audio still gets no rendition, so no other untagged source changes route.

Two things decide the value:

- **Stream copy.** The JOC form is gated on the delivery being a stream copy as well as on the source probe. A JOC source whose stream-copy probe was rejected and which fell back to the audio bridge has no objects left in its segments and must claim none.
- **Muxer parameters.** The count is read from the codec parameters the muxer was configured with, not the source's, so a bridged track reports the encoder's layout.

The literal `16` is the object count that Dolby's delivery kit and Apple's own Atmos masters carry. Strictly, it is `complexity_index_type_a` from the `EC3SpecificBox`, which is not available at the playlist layer.

**`dec3` / `dac3` from Matroska.** Matroska CodecPrivate does not usually carry the pre-parsed `dec3` / `dac3` box content the mov muxer needs at `avformat_write_header` time. So the muxer is configured with `+delay_moov` (alongside `+empty_moov+default_base_moof+frag_custom`):

- The moov atom is deferred until the first fragment-cut flush. By then packets have flowed through `mov_write_packet`, and libavformat's `handle_eac3` / `handle_ac3` have populated the sample-entry boxes from the actual packet bitstream.
- The first cut emits the deferred ftyp+moov (routed by `FragmentSplitter` to init.mp4). Later cuts emit normal moof+mdat.

Net effect: EAC3 / AC3 from Matroska direct-play stream-copies cleanly with valid sample entries, and the host does no manual bitstream parsing.

**A dependent substream needs FFmpegBuild 3.7.0 or later.** A Blu-ray style DD+ track is an AC-3 core syncframe (`bsid 6`) followed by an E-AC-3 dependent syncframe that carries the height channels and the objects. Stock `handle_eac3()` gets two `dec3` fields wrong for that shape:

- `chan_loc` is taken from the dependent `chanmap` with a shift and mask that do not match ETSI TS 102 366 F.6.2.3 (fixed upstream as `f10fdd6310`, master only).
- `complexity_index_type_a` is read from the independent substream alone, so the TS 103 420 extension is dropped.

The box then describes a bare 5.1 bed, and an Atmos receiver reports multichannel PCM (AE#728). FFmpegBuild's `patch_ffmpeg_eac3_dec3` fixes both in the muxer. Measured on a 5.1.2 source with `chanmap = 0xA010`, the payload goes from `14 00 0C 0F 02 00` to `14 00 0C 0F 02 40 01 10` (`chan_loc` `0x040` is Lvh/Rvh; `01 10` states the extension and 16 objects). A track whose objects sit in the independent substream already gets a correct box and is unchanged.

### TrueHD Atmos with heights

**The problem.** Apple TV cannot bitstream TrueHD, and no Apple platform hands a third-party app a compressed bitstream output. So the audio bridge decodes a TrueHD track and re-encodes its 7.1 channel presentation (`audioBridgeMode`). For TrueHD Atmos that loses every height and every object position before the audio leaves the engine.

**The option.** `LoadOptions.objectAudioRendering = .render(layout)` keeps them (AetherEngine#731). The engine builds the `SpatialSpeakerLayout` bed the host names (5.1.2, 5.1.4, 7.1.2, 7.1.4 or 9.1.6, as `SpatialSpeaker` positions in CoreAudio's channel order) out of the stream's own lossless 7.1 (or 5.1) presentation, steered by its Atmos object presentation (see [How the bed is built](#how-the-bed-is-built)), and hands that bed to the system as PCM, or as APAC over AirPlay ([PCM or APAC](#pcm-or-apac)). tvOS sends it to an Atmos receiver or soundbar as Dolby MAT, the same way it delivers its own spatial content. iOS plays it as Spatial Audio.

**Why it is opt-in.** It is a trade: the rendered bed, PCM or lossy APAC at several Mbit/s, in place of the lossless 7.1 the channel bridge delivers.

- It applies only to TrueHD that FFmpeg marks as Atmos, at 48 kHz, on OS 26 or later. Anything else, and any failure to start, keeps `audioBridgeMode` with the audio intact.
- To learn before playback whether a TrueHD track carries Atmos, `probe(url:detecting: .atmos)` reads its major sync and answers in `TrackInfo.trueHDAtmos` (`.atmos`, `.noAtmos` or `.unsettled`; #1035).
- The decoder and the bed regression are an optional component, compiled only with the `TrueHDObjectAudio` package trait, off by default. Built without it, TrueHD Atmos keeps the channel bridge whatever the option asks, and the session log says so ([Installation › Optional components](installation.md#optional-components)).
- Silo built the first implementation in its fork: an exact object render, since replaced by this path.

#### PCM or APAC

The bed leaves the engine as 24-bit PCM or as Apple Positional Audio (`SpatialBedFormat`).

| Option | Format |
| --- | --- |
| `.render(layout)` | Chosen at load: PCM, unless the route plays over AirPlay (an AirPlay port in the session's route, or on macOS an AirPlay default output device), then APAC. visionOS follows iOS without a measurement of its own. |
| `.lpcm(layout)` | Always PCM |
| `.apac(layout)` | Always APAC |

**PCM.** Muxed as `ipcm` with a custom channel layout in the bed's own order. movenc writes it as a `chnl` box that AVFoundation reads back as exactly `Atmos_7_1_4` / `Atmos_9_1_6` (measured on macOS 27 with FFmpeg 8.1), so nothing is reordered. The master reads `CODECS="…,ipcm"`. It costs 1.15 Mbit/s per bed channel (18.4 Mbit/s for 9.1.6) on the loopback, and no encode at all. FLAC and ALAC stop at 8 channels, which is why the lossless form for a bed with heights is PCM.

**Measured 2026-10-28**, with one noise burst per channel:

- Apple TV 4K (tvOS 27) into a Sonos: 12 and 16 channels of PCM over HLS reached the receiver as Dolby Atmos with every channel on its own speaker, with Continuous Audio Connection off. Through the software host's sample-buffer renderer the same held with `AtmosOutputActivator` running, as it does there.
- iPhone with AirPods and spatial audio: every channel played in place.
- MacBook Air (macOS 27): every channel in place through its own speakers and through AirPods, over HLS and through the renderer.
- Over AirPlay to that Sonos, neither form arrived as more than stereo. APAC is the one that has played as Atmos to a HomePod pair (#834), so AirPlay keeps APAC.

#### How the bed is built

**Decoding.** [LibTrueHD](https://github.com/superuser404notfound/LibTrueHD) decodes two presentations from every access unit:

- the stream's highest channel-based presentation, Dolby's own lossless 7.1 (or 5.1) rendering of the mix;
- the object presentation: the bed elements and up to 15 dynamic objects with their object audio metadata.

The object presentation is decoded without matrix interpolation. LibTrueHD 3.2.0 leaves the interpolating decode out of its binary, and the engine's handle discards the values too. So on a stream that interpolates (a mix with moving objects; static mixes do not) the element signals are approximate. They never reach an output.

**The regression.** `BedRegression` builds every output as a linear combination of the channel presentation, per frequency band (a 2048-point STFT with a 512-frame hop, 64 log-spaced bands, `W · bed` with `W = R · A`):

- `A` is the least-squares regression of the elements on the bed, from their cross-spectra with it and the bed's own covariance, smoothed over about 20 ms.
- `R` is the elements' gains into the layout.

So each output takes from the bed exactly the part of it that belongs to the elements the layout places there. No element is reconstructed from the bed or mixed into an output.

**Energy bound.** Per band the output carries 0.9 to 1.6 times the bed's energy (a constant-power layout over Dolby's 7.1, whose objects measure 0.7 to 1.0 in power, lands inside). An element the decode got wrong can misplace energy but not add or remove it, and the output cannot click. The LFE is the bed's own.

**Accuracy.** Compared against the exact decode and mix of earlier releases, on 30 windows of ten films plus Dolby's Unfold demo:

- On mixes without interpolation the two agree to 40 to 45 dB.
- On mixes with it, the heights stayed within 0.15 dB at a correlation of 0.997 and above, except in two extremes (Unfold, 0.987; a window of *The Matrix* with a loud overhead effect, 0.81).
- In an A/B on an Apple TV into a Sonos Arc the difference was not audible.

**Latency.** The regression adds a latency of 2048 frames, which the bridge keeps off the timeline (the first packet still sits at its source position) and runs out at a segment cut, a restart and the end of input.

**Panning.** The layout gains are allocentric, the model Atmos metadata is authored in. The room is a unit cube, and a position is balanced constant-power between the two speaker planes that bracket its height, the two rows that bracket its depth and the two speakers that bracket its width, so moving an object never changes its loudness.

- Ceiling speakers sit where ETSI TS 103 448 puts them, a quarter of the room in from each wall rather than in its corners. An object on the ceiling a third of the way back plays mostly from the front tops, as Apple's own Atmos render places it.
- A 5.1 bed's surrounds sit halfway down the side walls, also as TS 103 448 places them, so on 5.1.2 and 5.1.4 an object at the back wall stays on them.
- Every element is a point source at its position with its gain. Object size, snap, zone masks, screen anchoring and the elevation switch are not read, and a metadata update applies as it stands, without a ramp.
- After a seek, decoding resumes at the next major sync, and the stream's first object metadata follows it up to 32 ms later. The decoder holds the audio in between and plays it at that metadata's positions, rather than leaving every object silent until it arrives (it waits at most 100 ms).
- The same panner routes DTS:X's channels (see [DTS:X with heights](#dtsx-with-heights)).

#### Track choice

With the option on, the automatic audio pick prefers a TrueHD Atmos track over the other tracks of the same language: of the `preferredAudioLanguages` match, or of the session's default track when no preference decides it. In a file whose audio tracks carry no language tag at all, it replaces the default with the first one.

- It never crosses a language or a dub (a region or script both tags state and disagree on).
- It never picks a commentary or an audio description for it.
- It applies only where the bed can be rendered: a VOD video session, on the loopback route or the software host, on OS 26 or later.
- An explicit `audioSourceStreamIndex` passed to `load` still wins.

Without this, a film carrying DTS-HD and TrueHD Atmos in one language usually opened on whichever the container listed first.

#### Atmos on the receiver (tvOS)

tvOS sends APAC over HDMI as Dolby MAT, and some sinks show Dolby Atmos for it on their own, but not all. A Samsung HW-Q990C soundbar fed by an Apple TV 4K (tvOS 27.2) played APAC without ever showing Atmos, although `AVAudioSession` reported a MAT format throughout.

**`AtmosOutputActivator`.** While a rendered session plays (TrueHD Atmos or DTS:X, as APAC or as PCM), the engine loops a silent E-AC-3 stream signalled as Dolby Atmos on a second, unmuted player. On the same setup, this brought the soundbar to Atmos before the first frame and kept it there across a seek. Nothing the app can read (`AVAudioSession`'s output format or channel count) tracked the indicator, so only the sink can confirm it.

- The stream is 2 s of digital silence written bit by bit from the E-AC-3 and object audio specifications (`Scripts/make-silent-atmos.swift`).
- It plays only while the engine's player plays or waits to play a rendered item on a route whose every output is HDMI, and is released otherwise.
- **Pause grace.** A pause does not stop it at once. It keeps playing for 60 s and pauses only if the engine's player is still paused then, because stopping it let the output leave Atmos, and a Samsung HW-Q990H re-locked on every resume and scrub (#848). The grace is bounded so a long pause does not keep the receiver busy, and it ends before tvOS's shortest screen saver delay.
- **DTS:X.** A rendered DTS:X programme runs it too. tvOS carries a bed with heights over HDMI only as Dolby MAT, so the receiver shows Dolby Atmos for an intact DTS:X bed either way. Without the stream, the Sonos above, with Continuous Audio off, kept a DTS:X bed rendered to PCM on stereo.
- **AirPlay.** Not run. There is no sink indicator to light, and the second player restarting beside the programme on resume left a HomePod pair silent after a pause (#834).
- iOS and macOS do not run it.

**On the software host** (the Dolby Vision FEL route), the activator runs the same way while its renderer receives a rendered bed (TrueHD Atmos or DTS:X, APAC or PCM, and on tvOS E-AC-3 JOC decoded by the system into a PCM bed) or compressed E-AC-3 JOC.

- On tvOS the renderer plays compressed E-AC-3 JOC silent (Apple TV 4K, tvOS 27, HDMI). So there `SoftwareEAC3AtmosDecoder` decodes it with the system's Atmos decoder into the bed whenever the bed is PCM. Over AirPlay the compressed route stays.
- Only the software host's PCM decode of the source never runs the activator.
- With a PCM bed the renderer needed it: the Sonos above stayed on stereo PCM without it.

#### Peak limiter

A linked peak limiter sits between the renderer and the encoder. The APAC encoder carries samples over full scale through unchanged (a tone at amplitude 4.0 decodes back at 4.001), and a rendered bed can get there, since object gains reach +15 dB and up to sixteen elements sum into one speaker.

- One gain for every channel, so no object moves.
- Instant attack, so nothing leaves above −0.18 dBFS without a lookahead delay that would shift the audio against the picture.
- It has a 250 ms release.
- A bed under the threshold passes bit for bit.

#### Cost

Decoding the object presentation and encoding APAC each take about one core (a PCM bed has no encode). On Dolby's Unfold demo (27 s, M1, release build):

| Stage | Time |
| --- | --- |
| TrueHD decode | 1.36 s (0.92 s since LibTrueHD 2.2.0, 0.60 s through its C API since 2.3.0) |
| APAC encode | 1.26 s |
| Rendering plus limiting | 0.06 s |

**Pipelined encode (`APACEncodePipeline`).** Apple's encoder runs on one thread, so the bridge hands each rendered 2048-frame chunk to a serial encode queue and decodes the next chunk meanwhile. On the whole sample that cuts 2.73 s to 1.75 s, and to 1.40 s with LibTrueHD 2.2.0's faster decode: 19x real time, against 10x in series. The encoder is the slower half, so the decoder does not set the pace. That time is what a seek past the produced range waits for before its first segment, so a seek is the one place the trade shows.

- The queue inherits the producer's QoS.
- A pool of three chunk buffers holds the producer at most two chunks ahead of the encoder.
- The producer waits for the queue (`settle()`) before a keyframe advances its segment cutter or a write cuts the open segment. So every packet is routed as the encode in series routed it, and every segment carries the same audio, byte for byte. Those waits cost about 0.1 s of the sample's overlap.

#### What the session log says

- `[SpatialAudioBridge] object configuration` names the presentation (`LFE + 15 objects` for Dolby's Unfold demo).
- A `bed levels` line gives each bed channel's RMS and peak with its CoreAudio name, how many objects were active and how many elevated, the LFE element's level and gain, and the limiter's work over the same window when it had any. It comes after the first 5 s of audio (and again after every seek), then every 30 s.
- The decoder waits for a major sync after a start or seek, so a decoder that returns nothing for 1200 packets in a row, a second of TrueHD, is reported as one that produces nothing, the same failure the channel bridge reports.

The object counts reach a host too, once a second, as `LiveTelemetry.objectAudio`, so a stats panel can say how many objects play and how many overhead without reading the log.

### DTS\:X with heights

**The problem.** DTS:X reaches the bridge the same way TrueHD Atmos does. Apple TV cannot bitstream DTS-HD, so `audioBridgeMode` decodes the lossless 7.1, and on a DTS:X track that 7.1 is a compatible downmix into which the encoder folded the four height channels.

**The option.** `objectAudioRendering = .render(layout)` keeps them, in a build with the `DTSXObjectAudio` package trait (off by default; without it DTS-HD keeps the channel bridge whatever the option asks, [Installation › Optional components](installation.md#optional-components)). A DTS-HD Master Audio track is decoded by FFmpeg's own `dca` decoder into the same bed regression and limiter as TrueHD Atmos, and leaves as PCM or APAC the same way ([PCM or APAC](#pcm-or-apac)). The engine side is a channel mapping (`DTSXObjectAudioDecoder`). No library comes in for it: FFmpegBuild patches the decoder (#798).

#### The standard presentation

DTS:X's standard presentation is a 7.1 bed and four fixed heights (the top front and top back pairs). Each height is folded at -3 dB into the bed speaker under it (top front left into L, top back left into the left rear, and so on), so that a 7.1 decoder plays the whole soundtrack.

**Decoding the heights.** The heights travel in a regular XLL channel set at the end of every lossless frame, behind their own syncword. Upstream FFmpeg recognises that syncword (it is what makes it label a track "DTS-HD MA + DTS:X") but then skips the channel set. FFmpegBuild's patch decodes it with FFmpeg's own XLL code. With the decoder option `x_heights`, which `DTSXObjectAudioDecoder` sets, it outputs 7.1.4: the bed exactly as coded (heights still folded in), next to the four heights. Without the option the decoder's output is unchanged.

**Rendering.** Nothing is subtracted from the bed. Every output is built from that bed alone by `BedRegression` in its fold mode: `W = D + (R − D · F) · A`.

- The bed plays on its own speakers.
- Each height moves the part of the bed the regression attributes to it (its cross-spectra with the bed over the bed's covariance, per band, about 20 ms of memory) from the speaker it is folded into to its own.
- The heights are statistics only and never play themselves.
- The fold `F` is the format's, not read from the stream's private metadata. Every frame of twelve DTS:X tracks measured (eight *Harry Potter* films, two *Shrek* films in two languages, *Mary and the Witch's Flower*) stated the same one.

**Accuracy.** Against the exact separation on 21 windows of seven of those films, the heights stayed within 0.14 dB at a correlation of 0.994 to 1.000 wherever they carry 0.3 % of the energy or more, 29 to 49 dB overall. The weakest seconds are nearly silent heights, 37 to 74 dB under the programme.

**Energy bound.** A height alone legitimately carries twice its folded energy, so the energy bound here is 0.5 to 2.5 times the bed (TrueHD's 0.9 to 1.6 would cost up to 14 dB).

**Latency.** The regression's 2048 frames, kept off the timeline.

**Layouts.** Each of the twelve channels has its own speaker, so DTS:X is rendered into the two layouts that carry all twelve one to one, 7.1.4 and 9.1.6.

A smaller layout (5.1.2, 5.1.4, 7.1.2) renders DTS:X as 7.1.4 instead. The host can set the layout to match the room, and the receiver maps the 7.1.4 bed onto its own speakers, the same as it does with tvOS's own Atmos. Nothing is panned, and a chain that cannot take twelve channels gets the 7.1 it would have had from the channel bridge, since tvOS folds the bed itself.

A host that wants TrueHD Atmos in the small layout but DTS:X on the 7.1 channel bridge sets `LoadOptions.rendersDTSXObjectAudio = false` (#1060). That holds for every DTS track of the load, so a file with both tracks plays either one without a reload.

#### The alternate presentations

Some streams use an alternate presentation (FFmpeg labels some "DTS-HD MA + DTS:X IMAX"; Trinnov's "Experience" trailer is another). They carry the same four fixed heights after one to five object channels, behind their own syncwords (`0xF14000D0`, `D1`, `D3`, `D4`).

- The same `x_heights` option finds their height channel set behind a CRC-protected prefix and two control blocks and outputs it like the standard one.
- The object channels are never decoded and stay in the bed, where the encoder folded them.
- They render the same way, with one difference: the profiles fold their heights at different gains. The decoder exports which presentation the heights came from (`x_presentation`), and `DTSXObjectAudioDecoder.foldGain(presentation:)` maps it to the profile's fold, never to the stream's metadata.

| Presentation | Height fold |
| --- | --- |
| Standard | -3 dB |
| D0 | Unity (measured to the LSB) |
| D1, D3 | -3 dB |
| D4 | Not measured: refused, plays as its 7.1 bed |

The D0 / D1 / D3 folds are as harletty-bridge's dca analysis measured them. On *Bad Boys for Life* (D0, 7.1.4 plus one object) every frame of a 60 s excerpt decoded its heights, and the bed stayed bit-identical to the plain 7.1 decode. The heights' coupling into L / rear left and R / rear right summed to 1.07, 1.03, 1.01 and 1.01 there, against 0.62 and 0.74 for the rear pair of the -3 dB standard presentation measured the same way.

An alternate stream whose frames carry no heights (the object-only variant on a 5.1 bed) also plays as its 7.1 bed.

#### Which tracks

The probe labels DTS:X from the frames it read, and some DTS:X it does not label at all (Trinnov's "Experience" trailer, whose extension FFmpeg does not recognise). So every 48 kHz DTS-HD MA track is offered to the decoder, and its decoded frames decide:

- The track renders on the first frame that comes out as 7.1.4.
- It is refused after eight that do not (a stream entered inside a peak-bit-rate smoothing period decodes its first frames from the lossy core alone).
- A stream that turns out not to be 48 kHz is refused on its first frame.
- A refused track, or one without a verdict, keeps `audioBridgeMode` with its lossless 7.1 as before.
- Lossy DTS (core, ES, 96/24, High Resolution) is never offered.

**The peek.** The engine shows the frames to the decoder through the demuxer's peek (`peekPackets`), which holds what it reads for the producer, so deciding costs no extra read and no seek. On a resume the demuxer is put where the first producer starts before the peek, not after it, and the frames there decide. The peek holds at most 512 packets or 24 MiB, every stream's included, and gives up without a verdict past either.

**Automatic pick.** The automatic audio pick prefers a track FFmpeg labels DTS:X the way it prefers TrueHD Atmos. A plain-labelled DTS:X track is rendered when it is the track that plays, but cannot be ranked before playback.

#### Seeks

A DTS-HD Master Audio frame is lossless only against the core decoder's filter and predictor history, which a stream entered mid-way does not have. The first frame after a seek decodes distorted (over 120 seeks into five DTS:X streams, its error was a median 2.7 dB below the signal), and the next can still err by -16 dBFS.

The decoder therefore decodes the first two frames after a start or seek without output, and counts them on its input timeline. The bridge's first encoded frame sits 21 ms after the segment's start, where those frames end, and nothing fills the gap. The first block then differs from a continuous decode by at most -33 dBFS, and the output is bit-identical again within about ten frames.

#### On the receiver

Over Jellyfin on an Apple TV 4K (tvOS 27.2), *8 Mile* and *The Bourne Identity* played as APAC with the soundbar showing Atmos, from the middle of the film and across seeks (back to playing in 0.7 to 2.2 s), with the same `AtmosOutputActivator` TrueHD Atmos uses. *Arrival*, plain DTS-HD MA, was refused on its first frame and showed PCM.

Those runs predate the decoder in FFmpeg. The activator still runs for a rendered DTS:X bed, like for every rendered bed (7.56.0), see [Atmos on the receiver](#atmos-on-the-receiver-tvos).

#### What the session log says (DTS:X)

- `[HLSVideoEngine] DTS-HD MA track is DTS:X 7.1.4 (first frame, 3 ms)` names the layout the verdict found.
- A refusal names its reason:
  - `no DTS:X extension in the standard presentation, 8 channels`
  - `DTS:X in an alternate presentation without heights, which plays as its 7.1 bed` (a stream FFmpeg labels IMAX whose frames carry none)
  - `DTS:X in alternate presentation 0xd4, whose height fold is not known, which plays as its 7.1 bed`
- A frame whose height channel set does not decode keeps the 7.1.4 layout with silent heights and the bed as coded, and libavcodec logs `DTS:X height channels not decoded, output silent heights`.
- A layout other than 7.1.4 or 9.1.6 logs `DTS:X is rendered into 7.1.4 instead of 5.1.2, the smallest bed that carries its channels one to one`.
- The `object configuration` and `bed levels` lines are the same as for TrueHD Atmos. So is the 1200-packet silence report: at 512 samples a DTS frame, that is 12.8 s of DTS, against a second of TrueHD.

## Subtitles

Subtitle cues come from one read of the source. Every cue, whatever its codec, ends up in a single published `[SubtitleCue]` list (`subtitleCues`) that the host renders as an overlay. Each packet decodes through `avcodec_decode_subtitle2`, except in-band CEA-608, which has an in-house line-21 decoder ([below](#in-band-cea-608-closed-captions)).

This section covers:

- how embedded cues are collected and how far ahead they reach,
- what each codec produces,
- external subtitle files, language preferences, a second simultaneous track,
- how the cue list stays correct across seeks,
- native WebVTT renditions for PiP / AirPlay / external display, live HLS renditions, and authored ASS styling.

**Render against `engine.sourceTime`.** Subtitle cues are stamped in raw source PTS (the file's own timestamps). On the native path, AVPlayer's HLS clock sits at `source_pts - producer.videoShiftPts`. The producer applies a per-session shift to align the first segment's tfdt with the playlist origin, and that shift can change on every restart. Rendering the overlay against `engine.sourceTime` keeps cues matched to the spoken audio, whichever producer session is active.

### How embedded cues are collected

What a host sees:

- **Instant selection.** Every embedded subtitle stream (text and bitmap) is harvested from the session's own source read, whether it is selected or not. Enabling any embedded track is therefore instant: the selection fills from what is already stored, with no positioning seek, even on remote disc images.
- **Cues ahead of the playhead.** On VOD, `subtitleCues` holds cues up to a 60 s lead window ahead of the playhead, text and bitmap alike, so a host can apply an ADVANCE sync offset. A forward prefetcher reads ahead of the video to fill it, with a 15 s margin past the window so a cue at its edge still gets its authored end. While a bitmap track's OCR rendition is armed, the lead is raised to 270 s, which clears the OCR worker's own 240 s window by 30 s.
- **The prefetch costs a second read.** On an interleaved container (Matroska, MP4) it downloads the video a second time. It runs only while the advance reach is above 0 (`maximumSubtitleAdvanceSeconds`, default 60), `softwareSubtitleDelaySeconds` is negative, or the OCR worker is armed (AE#1015). A host without an advance control sets the reach to 0; see [api › Cue retention](api.md#cue-retention). With a reach of 0, a bitmap track still reads a short window around each seek landing (AE#1022).
- **The video has priority on the link.** On a link with little headroom the prefetch yields to the video pump (#240).
- **Live sessions** have no prefetch: content past the edge does not exist.
- **Seeks and restarts** keep the cue list correct ([How the cue list stays correct across seeks](#how-the-cue-list-stays-correct-across-seeks)).

How the harvest, the packet store, the drain and the prefetcher work: [architecture › Subtitle cue pipeline](architecture-native.md#subtitle-cue-pipeline).

#### Sidecar fetch (AE#984)

Sidecars are fetched once. A text sidecar over HTTP (SRT, WebVTT, ASS/SSA, by extension or `formatHint`) is one plain GET for the whole body. The engine waits up to 120 s without a byte for it, then decodes it locally. So a server that extracts the stream before it answers still delivers. Container and `.sup` sidecars stay on the source reader.

### What each codec produces

| Source | `SubtitleCue.body` |
| --- | --- |
| Text codecs (SubRip / ASS / SSA / WebVTT / mov_text) | `.text(String)`, or `.richText([SubtitleTextRun])` with styling |
| DVB teletext | `.text(String)`, or `.richText` when the page carries colour |
| Bitmap codecs (PGS / HDMV PGS / DVB / DVD) | `.image(SubtitleImage)` |
| In-band CEA-608 | `.text(String)` |

#### Text codecs

SubRip / ASS / SSA / WebVTT / mov_text produce `SubtitleCue.body = .text(String)`, or `.richText([SubtitleTextRun])` when the cue asks for styling (#233).

- **One parser.** libavcodec converts every text format into an ASS event line before the engine sees it, so one override parser serves all of them.
- **Run attributes.** Inline `\b` / `\i` / `\u` / `\s` / `\c` / `\1c` / `\fn` / `\fs` / `\r` become attributes on the runs (`isBold`, `isItalic`, `isUnderlined`, `isStruckThrough`, `color`, `fontName`, `fontSize`).
- **Plain cues stay plain.** A cue that asks for nothing stays plain `.text` with the exact string it produced before.
- **Newlines.** `\N` becomes a real newline either way, and `cue.text` flattens both forms.
- **Placement.** Cue-level `\an` and `\pos` lift out into `SubtitleCue.placement` (ASS numpad alignment plus an optional `[0..1]`-normalised anchor, y from the top) instead of splitting a run.
- **WebVTT cue settings** reach the same field from packet side data (`AV_PKT_DATA_WEBVTT_SETTINGS`). The WebVTT decoder drops `line` / `position` / `align`, but the demuxer keeps them, so `line:10% align:start` arrives as an alignment and an anchor. `size` and `vertical` have no equivalent in the placement model and are ignored. A `position` without a `line` keeps only the alignment column, since an anchor point needs both axes.

#### DVB teletext

DVB teletext subtitles (live broadcast) decode through libzvbi (`libzvbi_teletextdec`) with page-state semantics (#107). libzvbi is configured to emit ASS, so the per-character colour broadcasters use to distinguish speakers survives rather than being flattened.

- **Colour.** A page carrying colour publishes as `SubtitleCue.body = .richText([SubtitleTextRun])`, each run with an optional RGB `SubtitleColor` (nil meaning the host default). A page with no colour stays plain `.text`. `cue.text` flattens either form for consumers that do not render colour.
- **Placement** arrives two ways, because libzvbi writes it two ways:
  - On a page flagged as a subtitle page, libzvbi derives the vertical anchor from the grid row and emits `{\anN}`, which lands in `SubtitleCue.placement` like any other alignment.
  - On a page it does not flag (the broadcaster leaves NEWSFLASH / SUBTITLE / SUPPRESS_HEADER unset, or the row-0 header has not been seen yet), it writes the whole page instead, one row per line. Then the ordinal of the first non-blank row is the only carrier of the position. The engine applies libzvbi's own third-of-the-page formula to that ordinal, so a caption the broadcaster moved to the top of frame stays there either way. It never overrides an `\an` that did arrive.
- **Whitespace** follows the same split. The unflagged page is the raw grid: every row at full column width, with a hard space per cell. So the engine trims the padding off both ends of each row and folds the empty rows it also emits. A page the decoder curates itself arrives untouched. There the remaining padding is the relative indentation carrying the alignment it chose, and the blank lines are its vertical fine-positioning inside the block.
- **Page choice (#364).** The decoded page defaults to libzvbi's auto-detected subtitle page. It can be overridden per channel via `LoadOptions.teletextPage` (for example AU page 801, which libzvbi does not always flag as a subtitle page), and changed while the channel plays via `setTeletextPage(_:)`. That call rebuilds the drain decoder of every channel currently showing a teletext track and leaves the others alone.
- **Cue lifetimes.** libzvbi emits page content open-ended ("valid until replaced") and page erases as empty events, so every teletext event trims earlier open cues at its start. Roll-up captions build and replace cleanly, an erase clears the line, and a 120 s cap bounds a ghost line if transmission stops without either.
- **Validated** end to end against Australian FTA broadcasts (1080i25 H.264, captions on page 801), where the interlaced video deinterlaces through the software path's bwdif filter.

#### Bitmap codecs

PGS / HDMV PGS / DVB / DVD produce `.image(SubtitleImage)`. The indexed pixel plane is walked through its palette, premultiplied against alpha, and wrapped as a `CGImage`.

- **Colour (#1006).** The image is always sRGB. On a PQ source (HDR10, Dolby Vision with a PQ base) a PGS palette is PQ-coded per the UHD Blu-ray spec, so each entry is converted first: to BT.2020, through the PQ EOTF against the BT.2408 graphics white of 203 nits, to BT.709, and clipped to SDR. The disc's ~294-nit text white lands on 255.
- **Position (#112).** Position is normalised in `[0..1]` against the composition canvas. The canvas's coded pixel size rides along as `SubtitleImage.canvasSize`. A cropped-video rip can author a canvas taller than the coded video. So hosts map the canvas width-aligned and center-anchored onto the coded video frame, which lands cues where the disc authored them, then scale onto the displayed picture rect per axis (the axes only differ on anamorphic video). `.zero` means treat canvas == video.
- **DVB (#971) and DVD on a rescaled encode (#993)** report the video frame instead of their 720x576 / 720x480 plane, since that display covers the whole picture with non-square pixels. A DVD on video wider than 16:9 reports the 16:9 frame at the video's width, as the picture was cropped out of it.
- **Several objects (#146).** A display set carrying multiple composition objects (a forced sign plus dialogue is a common real-disc shape) fans into one cue per object, all sharing the set's start PTS, and every object is kept and rendered.
- **Forced flag.** Each object's `AV_SUBTITLE_FLAG_FORCED` rides along as `SubtitleImage.isForced`, surfaced per cue via `SubtitleCue.isForced`. Track-level forcedness stays on `TrackInfo.isForced`.

#### External files

A separate `.srt` / `.ass` / `.vtt` URL either registers as a first-class track ([next section](#external-subtitle-files-as-first-class-tracks)) or is loaded one-shot via `selectSidecarSubtitle(url:httpHeaders:)`.

- **Text sidecar.** `selectSidecarSubtitle` opens its own short-lived `AVFormatContext`, decodes the whole file once, and atomically swaps the result into `subtitleCues`.
- **Bitmap sidecar (#921).** A PGS `.sup` (reported as `pgssub`) is read whole too, but not decoded. Its packets go into a packet store of its own, and the overlay drainer decodes the window around the playhead from them, exactly as for an embedded bitmap track. It shares that track's bitmap byte budget and backward-seek backscan, and shows its first picture without waiting for the rest of the file. Decoding it whole would keep every picture for the session: 12 times the size of the file on a film-length track.
- **Headers.** The fetch forwards the session's `LoadOptions.httpHeaders` by default (WebDAV auth and friends). Pass the call's own `httpHeaders` to override per fetch.

#### In-band CEA-608 closed captions

In-band CEA-608 (`eia_608` / QuickTime `c608`, a demuxable caption track) produces `.text(String)` (#77).

- FFmpegBuild ships no `ccaption` decoder, so these never reach `avcodec_decode_subtitle2`.
- Instead, a read-only tap on the segment producer's existing source connection reads the caption track's `cc_data`. Its packets are kept in the demuxer's keep-set, observed, then dropped. They are never muxed, so the loopback-HLS output stays byte-identical.
- An in-house line-21 decoder (validated against FFmpeg's `ccaption_dec.c`) turns it into cues, and they publish on the same `subtitleCues` overlay path as every other codec.
- First cut: field-1 / channel CC1 only. CEA-708 (DTVCC) and field 2 are follow-ons.

**Captions inside the video bitstream (#131).** Captions carried only inside the video (ATSC A/53 `cc_data`, the US broadcast/cable case) are extracted too:

- On the native remux path, the segment producer scans H.264/HEVC video packets for `user_data_registered_itu_t_t35` SEI (GA94), reorders the decode-order groups to presentation order by the packet DTS watermark, and feeds the same line-21 decoder.
- On the software-decode path (MPEG-2 and friends), the triplets come from `AV_FRAME_DATA_A53_CC` decoded-frame side data.
- No caption AVStream exists, so a synthetic `eia_608` track (id 99608) appears lazily on the first real (non-padding) caption pair. Uncaptioned channels never show a dead menu entry.

CEA-608 is host-overlay only (no PiP / AirPlay), like the bitmap codecs.

### External subtitle files as first-class tracks

External subtitle files register with the engine and appear in `subtitleTracks` next to the embedded streams, so a host keeps one track list and one selection call (#88).

- **Registration.** `LoadOptions.externalSubtitles: [ExternalSubtitleTrack]` declares files at load. `addExternalSubtitleTrack(_:)` registers one at any time mid-session and returns the created `TrackInfo`. The descriptor carries `url`, optional `name` / `language` / disposition flags, per-track `httpHeaders` (nil inherits the session's only for a same-origin URL), and a `formatHint` for URLs whose path hides the extension.
- **Containers with several subtitle streams.** An external URL can be a container rather than a sidecar (an MKV holding English, English SDH and Spanish).
  - `ExternalSubtitleTrack.sourceStreamIndex` names which stream to decode, as an ABSOLUTE `AVStream` index inside that container, so a host registers one track per stream against the same URL. nil decodes the container's first subtitle stream.
  - An index that is out of range or names a non-subtitle stream fails the decode rather than falling back, which would be indistinguishable from leaving it nil.
  - Tracks sharing a URL and headers are filled from a SINGLE pass over the container, so N tracks cost one fetch, not N (#266).
  - `TrackInfo.codec` is still derived from the URL extension, so a container URL reports `subrip`. Set `formatHint: "ass"` when the streams are ASS and the host drives a styled renderer.
- **VobSub (`.idx` + `.sub`).** Only from a local file URL, since FFmpegBuild 3.8.0. The `vobsub` demuxer reads the `.idx` it is handed and opens the `.sub` itself, by the `.idx`'s own name through the file protocol. So the two files have to sit side by side on disk. Over HTTP the engine opens a sidecar through its own `AVIOReader` without a path, so the demuxer has no name to derive the `.sub` from, and the open fails. A host that serves VobSub remotely downloads both files first.
- **Identity.** External `TrackInfo.id`s are synthetic: `AetherEngine.externalSubtitleTrackIDBase` (100 000) + registration ordinal, monotonic per load. Load-declared tracks get `base + array index`, in order. `TrackInfo.isExternal` distinguishes them from AVStream-indexed embedded tracks.
- **Selection.** `selectSubtitleTrack(index:)` and `selectSecondarySubtitleTrack(index:)` accept external ids and route onto the whole-file decode internally. `activeSubtitleTrackIndex` publishes the external id like any other selection. `removeExternalSubtitleTrack(id:)` unregisters (an active selection is cleared).
- **Renditions.** Load-declared external tracks join the native WebVTT renditions ([below](#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display)).
  - Their store is filled by one whole-file decode at load (one pass per container, covering every track pointing at it) and marked finished.
  - A finished store also backfills the fullscreen overlay instantly on select (no re-download; styled-ASS selections re-decode to keep raw markup).
  - A store that could not be filled stays unfinished rather than serving a complete but blank `.vtt`.
  - Tracks added after load are host-overlay only until the next load, because the rendition set is fixed in the master playlist at item creation.
- **Preferences.** `preferredSubtitleLanguages` ranks external tracks together with embedded ones. A track added mid-session re-runs the preference and auto-activates on a match, but only while the host has made no explicit subtitle call (select / sidecar / clear) in the session, so a deliberate subtitles-off stays off.

#### Renditions on the `nativeRemoteHLS` bypass (#316)

That path plays the origin playlist directly, so there is no loopback master to declare a sidecar in. For a VOD source the engine therefore:

1. fetches the origin master,
2. makes every variant / audio / key URI absolute against the origin,
3. adds one `EXT-X-MEDIA:TYPE=SUBTITLES` per text sidecar, joining the origin's own subtitles group when it has one so a variant's group choice cannot lose them,
4. serves that master from the loopback origin.

The media never moves: AVPlayer still fetches A/V straight from the origin, which is what the bypass exists for (E-AC-3 / Atmos passthrough).

- Renditions are declared `DEFAULT=NO,AUTOSELECT=NO` and without `FORCED`, the same discipline as the loopback master, so nothing self-engages.
- The track keeps its external id, and selecting it drives `AVMediaSelection` rather than the overlay, so it survives PiP / AirPlay / an external display.
- These keep the origin URL and overlay-only subtitles: live playlists (no `EXT-X-ENDLIST`), bitmap sidecars (`.sup`), an unparseable or unrewritable playlist, and an origin slower than the 5 s budget.
- **A rendition is never held for its sidecar (AE#984).** AVPlayer will not load media past the point where it needs the selected subtitle segment. So holding that request for a slow file would freeze the picture of a healthy stream. Instead, while the sidecar is still decoding, the `.vtt` is answered 404. AVPlayer retries every few seconds while A/V keeps loading, and the complete file is served on the first retry after the decode. A sidecar that could not be read is served empty at once. The loopback master's whole-program renditions of load-declared sidecars follow the same rule.

### Track selection by language preference

`LoadOptions` can seed the initial audio and subtitle tracks from an ordered language preference. It is resolved from the engine's single probe, so a host honors a saved preference without a separate pre-probe or a post-load reload.

- **`preferredAudioLanguages`** (ordered BCP-47 tags, ISO 639-1 / 639-2 / 639-3 codes or English names, e.g. `["en-GB", "de"]`) picks the first-frame audio track:
  - An explicit `audioSourceStreamIndex` wins.
  - Otherwise the best track for the first preference that matches at all.
  - Otherwise the container default.
  - Within a language, the programme mix ranks ahead of an audio description (`TrackInfo.isVisualImpaired`) and a commentary, so a file that lists either first still opens on the film. A host that follows the system's Audio Descriptions setting picks the described track itself through `audioSourceStreamIndex` (AE#919).
  - The pick is muxed into the loopback HLS, so it is correct on the first frame with no `selectAudioTrack` reload.
- **`preferredSubtitleLanguages`** activates a subtitle at the end of load:
  - Within the first preference that has a match, it picks the *best* track by language specificity and then by container disposition: full subtitles rank over SDH (`HEARING_IMPAIRED`), forced, and commentary (`COMMENT`), and text over bitmap.
  - No match leaves subtitles off.
  - It drives the host-overlay path, so unlike audio it never needs a reload. It only spares a host from language-matching `subtitleTracks` itself.
  - The native menu ([below](#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display)) keeps its own host-driven default selection via `setNativeSubtitleSelected(track:)`.

**Matching (#590).** Two labels name the same language when their canonical ISO 639-2/T identity agrees. Case, ISO 639-1 / 639-2/B / 639-2/T / 639-3 and English names all fold together (`en` == `eng` == `english` == `en-US`, `de` == `deu` == `ger`).

- A 639-3 member CLDR aliases onto its macrolanguage folds with it (`cmn` == `zh`).
- One it does not alias stays its own language: `yue` and `nan` never answer a `zh` preference, because wrong audio is worse than the container default.
- An empty or missing label, `und`, and free-form text such as a track title are never a match.

**Ranking.**

- Preference order dominates: an earlier preference on a worse-ranked track still beats a later preference on a perfect one.
- Within one preference the more specific tag wins, scored on script first and region second. Agreement (including both silent) beats one side stating it, which beats both stating it differently. So an `en-GB` preference takes `en-GB` over `eng` over `en-US`, and a `zh-Hant` preference takes `zh-TW` over a bare `zho`.
- For **subtitles**, an explicitly opposite script is not a weak answer but no answer at all: `zh-Hant` never resolves to a `zh-CN` track, and subtitles stay off instead. Audio has no such reading failure, so there a script mismatch only ranks last.
- `zh-CN` / `zh-SG` count as Simplified and `zh-TW` / `zh-HK` / `zh-MO` as Traditional, because that is the only field a media server has to make the distinction with. Bare `zh` / `chi` / `zho` states no script and is a fallback for either.
- Matching reads the tag's own subtags and never `Locale.Language`'s inferred ones. Those claim a script for every language they know (`zh` -> Hans, `en` -> Latn, `nan` -> Hans) and would turn an unspecified track into an explicit and sometimes wrong one.

**Shared with the native renditions.** The same resolution picks the `DEFAULT=YES` native rendition from `nativeSubtitlePreferredLanguages`, so the inline overlay and the PiP / AirPlay rendition cannot disagree about which track was meant.

**Inputs and outputs.** Nothing is inferred from `TrackInfo.name`, `ExternalSubtitleTrack.name` or a sidecar filename: the structured `language` field is the whole input. The resolved tracks are published on `engine.activeAudioTrackIndex` / `engine.activeSubtitleTrackIndex` (both match `TrackInfo.id`). Every `TrackInfo` carries `isDefault` / `isForced` / `isHearingImpaired` / `isCommentary` / `isVisualImpaired` (from container dispositions), so a host can rank or filter the track lists the same way.

### Second simultaneous subtitle track (bilingual)

A second subtitle channel can run alongside the primary, for bilingual playback or language learning. The API mirrors the primary one:

| Member | Purpose |
| --- | --- |
| `selectSecondarySubtitleTrack(index:)` | Select an embedded track |
| `selectSecondarySidecarSubtitle(url:httpHeaders:)` | Select a sidecar file |
| `@Published secondarySubtitleCues` | The secondary cue list, separate from the primary |
| `isSecondarySubtitleActive`, `isLoadingSecondarySubtitles` | UI state |
| `clearSecondarySubtitle()` | Tear the secondary channel down |

- The separate cue list lets the host render the two channels independently (for example top vs bottom).
- Embedded text and supported bitmap tracks (PGS, DVB and DVD) use the shared packet store, with independent per-channel decoders, cursors and PGS admission state.
- XSUB classification alone does not imply decoder availability in the shipped FFmpeg build.
- Clearing or rebuilding the secondary channel does not clear the primary.
- The host owns rendering both cue lists, including separate bitmap layers and any placement or delay policy.

### How the cue list stays correct across seeks

**Multiple rects and dedupe.** A single packet can carry several rects (subtitle regions; PGS often puts signs/songs at the top and dialogue at the bottom). It becomes several cues with the same time range, and the host renders all of them. Cues are inserted in sorted order. Events re-emitted after a seek dedupe by time range plus content, so two simultaneous speaker lines with identical timing both survive, and the list does not grow on rewind.

**Ending a PGS cue.** A PGS composition carries no end of its own. It is published with FFmpeg's open-ended placeholder end (`end_display_time = UINT32_MAX`) and closed at its successor composition or clear, which the packet store normally holds before the drain reaches it (#362). A seek past a still-open cue closes it at the start of the seek's reconstruction window (#357), so it never covers the new playhead. An authored duration is never touched.

**Holes and landings.** After a seek, the store can hold packets from several reads with an unread stretch between them. The drain waits at such a hole instead of decoding across it (#362, #941, #1021), and a cue claims the landing after a seek only when the ground between it and the playhead was actually read (#416). A tick that waited logs `outcome=harvestHole gapAt=`, and a withheld landing shows `landingWithheld=` on the delivery line.

How the store ends cues, finds holes and proves a landing: [architecture › Subtitle cue pipeline](architecture-native.md#subtitle-cue-pipeline).

### Native subtitle renditions (WebVTT for PiP, AirPlay, and external display)

**Why.** Host-rendered subtitle overlays are invisible in Picture-in-Picture, AirPlay and external-display sessions, because those paths render the `AVPlayerLayer` content only. The SwiftUI / UIKit view tree is not composited.

**What the engine does.** It serves every text subtitle track as a real HLS `SUBTITLES` rendition over the loopback:

- The master playlist carries one language-tagged `EXT-X-MEDIA:TYPE=SUBTITLES` entry per track (`DEFAULT=NO,AUTOSELECT=NO`) plus `SUBTITLES="subs"` on the variant.
- Each track is backed by a media playlist (`subs_N.m3u8`) whose WebVTT segments mirror the video segments 1:1.
- AVFoundation exposes the renditions as a standard legible `AVMediaSelection` group that travels with the stream everywhere `AVPlayer` goes, including PiP.

(Muxing `mov_text`/tx3g traks into the fMP4 itself does not work: in-band timed text is not HLS-conformant, and AVPlayer rejects the stream.)

**Opt-in.** Off by default (`LoadOptions.prepareNativeSubtitles = false`): no renditions in the master, no legible menu, and the output is the same as without the feature.

**Cue source: the producer pump tap.** The segment producer already reads the source's full interleave, so the text subtitle streams stay in its keep-set, and every packet is handed to a session-level tap that decodes into per-track cue stores (the same pattern as the CEA-608 tap).

- Zero side-channel bandwidth. Coverage is by construction the produced region, across seeks and producer restarts.
- The host overlay is fed separately, by the packet-store drainer (#112 rework, see [Subtitles](#subtitles) above).
- A lazy per-selection reader still covers AVKit's ~240 s forward `.vtt` prefetch beyond the produced region.
- Load-declared external tracks (#88) have no demuxable stream to tap. Their store is filled by one whole-file decode at load and marked finished, so their rendition serves complete `.vtt` files from the start.
- The renditions strip ASS markup at serve time, so PiP shows plain text in the system caption style. The host overlay keeps full styling with `preserveASSMarkup` ([Authored ASS styling](#authored-ass-styling)).

#### Routing scope

A `SUBTITLES` rendition can only live in a master playlist, so native subtitles follow the master-routing rules:

| Source and panel | Native subtitles |
| --- | --- |
| SDR source, any panel | Yes |
| HDR / DV source on an HDR-ready panel | Yes |
| HDR on an SDR panel | No (media-direct, no master) |
| Live sources | No: their own `SUBTITLES` renditions reach the host through the overlay ([below](#live-hls-subtitle-renditions-host-overlay)) |
| Software decode path (AV1 without hardware decode, VP9) | No: there is no `AVPlayerItem` for a legible group to live on, so `prepareNativeSubtitles` is inert and the host overlay owns subtitles on every surface |

Where there are no native subtitles, the host overlay still covers fullscreen.

#### Bitmap subtitles through OCR

Bitmap subtitles (PGS / DVB / DVD) join as OCR-fed renditions.

**When the worker runs.** Only while a bitmap track is selected AND its rendition is what is displayed (the host called `setNativeSubtitleRendering(true)` for PiP, AirPlay or an external display). It is not armed for fullscreen viewing, where nothing shows the rendition, because arming it is costly. Armed, it raises the forward prefetch to 270 s, and on Matroska that reader pulls every cluster. On a 4K remux that measured ten times the prefetch bytes of the overlay-only lead (434 against 17 MB in 90 s).

**What it does.** The worker decodes the track's harvested packets ahead of the playhead (composition ends resolved at the next composition/clear event, the 5.14.1 sidecar semantics). It recognizes them on-device (Vision, hinted with the track language) into plain-text cues for the track's rendition. Recognition is lossy by design. A failed or empty read drops that line from the rendition, while fullscreen keeps the pixel-accurate bitmap overlay.

**Selecting waits for recognition.** The worker is armed on demand, so the rendition's window starts empty. AVKit takes the whole forward window in one burst at selection and caches what it gets. So the native select waits until the worker has recognized every stored composition through `subtitleOCRLeadSeconds`, and only then selects. "Every stored composition" means read by the harvest and decoded, not merely cue ends reaching a target, which a sparse forced track never does.

- Near the end of a program, that window ends at the duration, and a harvest read that reached end of file covers it (AE#955; without that, a select in the last four minutes of a film waited forever).
- Re-selecting the track the worker already serves keeps the worker, so a host that re-asserts its pick next to `setNativeSubtitleRendering(true)` does not restart recognition.
- The wait has no deadline. It ends when the request changes, and reports its state after 60 s.

**External `.sup` sidecars** fill their store from the packets the selection already read (no second fetch), decoded a batch at a time so each picture lives only as long as its recognition (#921).

#### Wireless AirPlay (#86, #227)

While an iOS session plays to a wireless AirPlay receiver, the engine reloads its loopback over the device's LAN IP: the receiver fetches the stream for itself and cannot reach `127.0.0.1`. It keeps the master there, so the `SUBTITLES` renditions travel and `setNativeSubtitleSelected(track:)` has a legible group to select against. The `EXT-X-MEDIA` URIs are relative, so they resolve against the LAN base with no further work.

How the session moves onto the LAN address depends on whether it can be reopened where it is:

- A session that can be reopened is rebuilt at the playhead.
- A sequential origin (which could only be read again from byte 0), and a live session on the engine's own HLS ingest (a forward-only source that cannot be rebuilt at all, #526), swap the player's item onto the new address instead and carry on serving. The live one rejoins its playlist at the player's join point, as a live reload does.

Both cross back onto the loopback the same way when the receiver lets go.

**HDR and Dolby Vision over AirPlay.** Whether an HDR or Dolby Vision master is accepted is the receiver's decision, and it turns on the receiver's own output mode (measured 2026-07-27, iPhone 17 Pro to an Apple TV 4K, DV P8.1 4K source):

- With the Apple TV's video format fixed to 4K Dolby Vision, it takes the DV master and plays it with subtitles.
- With the format at 4K SDR, it refuses every HDR master, and Match Dynamic Range does not help: that setting switches only when tvOS decides the content warrants it, which it evidently never does for AirPlay content.

This is the same rule the engine already applies locally: an HDR source on a panel that is not in HDR mode is served the media playlist. DrHurt described it in #86. Changing the manifest does not help either. Against a parked receiver, dropping the DV `SUPPLEMENTAL-CODECS`, clamping the declared `BANDWIDTH`, omitting `RESOLUTION` and declaring `HDCP-LEVEL=TYPE-1` each changed nothing. Declaring the range as SDR was already disproven in #98.

**Catching the silent refusal.** The refusal is silent, so the engine catches it by watching progress. There is no `-11868` and no failed item. The rate flickers to `playing` for a single tick, so even `hasEverPlayed` latches. The picture never starts, while AVKit shows its "not playable on this display" sign.

- Five seconds without a segment fetched, on a master handed to a receiver, reloads the LAN media playlist, which every receiver takes.
- That receiver is remembered by route UID for the rest of the process, so it goes straight to media from then on.
- A second master attempt, to exploit the output switch the first one triggers, was tried on device and only doubled the wait.

For subtitles on HDR content over AirPlay, the answer is the receiver's setting: fix its video format to HDR or Dolby Vision. `$nativeSubtitleRenditionsServed` reports which playlist is actually in use, so a host can tell the user their subtitles will not travel to this route rather than dropping them silently. A wired HDMI external display is a different route, and keeps the loopback plus its master.

#### Master-rejection fallback (#98, #130)

When AVPlayer rejects the served master, the engine reloads the bare media playlist in place. Rejections:

- `-11868` AVErrorNoCompatibleAlternatesForExternalDisplay,
- `-11848` for an SDR-parked panel,
- `-1002` when every variant was filtered at master parse time.

A VOD session comes back where the refused item was placed (after a stage-2 recovery reload, that is the recovered position, not the session's first start). A live session rejoins at the edge instead of replaying its stale start position.

So HDR / DV on an SDR external display plays from the media playlist, and the `SUBTITLES` renditions do not travel there. This is an AVKit limitation: forcing `VIDEO-RANGE=SDR` does not fool the external-display compatibility gate, which checks the real `colr` / codec, not the manifest string.

The separate `#35` cold-DV-start readiness gate (its scenario is an HDR TV) tries one step in between. Before the bare media playlist, it serves a reduced master that keeps HDR: `SUPPLEMENTAL-CODECS` dropped so it is plain HDR10, the source range and the `SUBTITLES` group kept. So a cold DV start keeps HDR10 plus subtitles instead of dropping straight to subtitle-less media.

#### Timing

Served cues are on the AVPlayer clock axis, and producer restarts are timeline-exact (see [architecture](architecture.md)), so cues stay in sync with the picture across seeks and restarts.

#### Selection: deliberately not automatic

The renditions ship `DEFAULT=NO,AUTOSELECT=NO`, so AVKit never engages one on its own and a host overlay never double-renders in fullscreen. A host that shows AVKit's stock chrome can still let the user pick from the native legible menu. Sodalite-style hosts select programmatically per surface instead.

#### Selection: host-driven API

These members on `AetherEngine` drive the native renditions programmatically:

```swift
// true once cues from at least one text track are decoded into the native stores
engine.$nativeSubtitleRenditionAvailable   // @Published var Bool

// true while the served playlist carries the SUBTITLES group; goes false on a
// media-playlist fallback, on the wireless-AirPlay hop for an HDR / DV source, and
// when the receiver refuses the master it was handed (#227). Hosts use it to decide
// whether to draw their own subtitle window on a wired external display instead
// (#98), or to tell the user that subtitles will not travel to this route
engine.$nativeSubtitleRenditionsServed     // @Published var Bool

// ordered list of all native subtitle renditions (ordinal, language tag, display name)
engine.$nativeSubtitleTracks               // @Published var [NativeSubtitleTrack]

// select a rendition by ordinal (nil deselects); language-tag match, positional fallback.
// Re-asserts automatically if AVFoundation drops the selection during a stall recovery.
engine.setNativeSubtitleSelected(track ordinal: Int?, markerOnly: Bool = false)

// convenience for the enter/leave pattern below: true resolves the rendition matching the
// currently-active overlay track and selects it, false deselects
engine.setNativeSubtitleRendering(_ active: Bool)
```

`NativeSubtitleTrack` carries `.ordinal` (position in the rendition declaration), `.language` (ISO 639-2 tag), and `.displayName` (localized name suitable for a picker label).

#### Rendition names and SDH

The rendition's `NAME`, which AVKit shows in its subtitle menu and which `.displayName` repeats, comes from the track's own title when it has one (AE#1050). That is the container's `title` tag, or `ExternalSubtitleTrack.name` for a host-declared track. A track titled "CC" reads "English (CC)". A title that already names the language ("English Signs") is used as it is, and a title that is only the language code ("eng") is ignored. Without a title the name is the language, as before.

An SDH track drops "SDH" from its title, because AVFoundation appends "SDH" to an option with the SDH characteristic by itself. Measured on tvOS 26, `NAME="English (SDH)"` read "English (SDH) SDH" in AVKit's menu. So an English track titled "SDH" with the hearing-impaired disposition is named "English", and AVKit shows "English SDH".

Names stay unique within the group, because AVFoundation folds renditions with the same `NAME` into one option. Two tracks that end up with the same name get a number on the second ("English 2").

A track whose container marks it hearing impaired gets `CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound"`, the value Apple's HLS authoring spec uses for SDH. AVKit can label and rank the option from it. The remote HLS master rewrite writes the same value.

The recommended host pattern for PiP / AirPlay:

1. Observe `$nativeSubtitleRenditionAvailable` (wait for the first cues to be ready before activating).
2. On entering PiP / AirPlay / external display: call `setNativeSubtitleRendering(true)` (or resolve the ordinal yourself via `setNativeSubtitleSelected(track:)`), and hide the host overlay. A wireless AirPlay receiver is covered even without that call: the engine raises the request itself when the host has not, since the overlay cannot reach a receiver, and withdraws its own request when the receiver lets go (AE#955). A host call takes over either way.
3. On leaving: call `setNativeSubtitleRendering(false)` and re-enable the host overlay.

This avoids double subtitles during inline playback (where the host overlay is already painting them), and makes sure the user sees subtitles the moment the stream is mirrored or sent to PiP.

#### Showing the host's pick in AVKit's menu (`markerOnly`)

A host that draws a bitmap track itself inside a stock `AVPlayerViewController` would normally see AVKit's subtitle menu say "Off", because the engine keeps the legible group deselected while the overlay paints. `setNativeSubtitleSelected(track: n, markerOnly: true)` selects rendition `n` in that menu without drawing anything (AE#1052). The user sees their track ticked and can pick Off or another track from the menu.

- The marker rendition is served as empty WebVTT segments, so AVKit shows no text and no caption box over the host's overlay. The host's text style rules are left alone.
- No OCR runs for a marker. Bitmap recognition starts only when the rendition has to carry text.
- `setNativeSubtitleRendering(true)` (PiP, AirPlay, external display) turns the marker into a full rendition: OCR arms, and the engine deselects and reselects so AVKit refetches the segments under the playhead with text. Measured on an iPhone with iOS 27, the first OCR cue showed up right after the reselect.
- `setNativeSubtitleRendering(false)` goes back to the marker instead of deselecting.
- Any plain `setNativeSubtitleSelected(track:)` call, nil included, replaces the marker. The marker survives the engine's own reloads (audio switch, recovery, AirPlay).
- Scope is the VOD loopback, the same as bitmap renditions in general.

### Live HLS subtitle renditions (host overlay)

A live channel carries its subtitles the same way a VOD stream does: as an `EXT-X-MEDIA:TYPE=SUBTITLES` group in the upstream master. The live ingest demuxes only the picked video variant, so that group never reaches the demuxer. Without the handling below, a channel offering three subtitle languages would produce no subtitle track at all (#359).

**What the engine does.** It surfaces the master's renditions as tracks (synthetic ids from `liveSubtitleRenditionTrackIDBase`, 300000). When the host selects one, it fetches its WebVTT segments and publishes the cues on the same host-overlay surface the CEA-608 tap uses. This is the overlay path, not a legible `AVMediaSelection`: the live loopback serves a media playlist, which cannot declare a rendition (see [Routing scope](#routing-scope)).

**Lazy by design.** The tracks come from the master's declaration alone, and nothing is fetched until a track is selected, so a channel watched without subtitles pays no second HTTP loop. Selection starts a poll of the rendition playlist at its `EXT-X-TARGETDURATION`, and only unseen segment URIs are fetched, so a poll that arrives before the window moved costs one small request.

Three properties to know when reading `[LiveSubs]` log lines:

- **Placement comes from the playlist geometry, not from `X-TIMESTAMP-MAP`.** The spec's own anchor is unusable in the field. Measured against a public broadcaster, every segment carries the same constant map, whose MPEGTS value sits two hours away from the video PTS. What renditions of one program do share, byte for byte, is `EXT-X-MEDIA-SEQUENCE` and `EXT-X-PROGRAM-DATE-TIME`. So a cue is placed at its segment's broadcast time plus its offset inside that segment. An upstream without `EXT-X-PROGRAM-DATE-TIME` therefore has no placement at all. The loop says so in the log and stops, rather than publishing something plausible and wrong.
- **The fetch is anchored at the playhead, not at the head of the playlist.** A rendition playlist is not a handful of segments (a two-hour DVR window is 3600 entries), so everything older than 120 s behind the playhead is marked seen without being fetched. Enabling subtitles and jumping back a little still lands in covered ground.
- **A producer seam republishes the source-axis shift.** Cues already placed then refer to an axis that no longer exists. The loop watches its own pairing and re-anchors, so a long session does not drift further out the longer it runs (6.21.1).

`aetherctl play --live-ingest --subs <lang>` exercises this against a real channel. It is the only CLI route that does; without it, #359 stayed invisible for a long time.

### Authored ASS styling

Hosts that render authored ASS styling themselves (positioning, speaker colours, karaoke) opt out of the stripping with `LoadOptions(preserveASSMarkup: true)`. Then:

- Cues carry the raw event line (override tags, style references, escapes intact).
- The script header (`[Script Info]` + `[V4+ Styles]`) is surfaced.
- `engine.fontAttachments` carries the container's embedded fonts (TTF / OTF) for the renderer's font directory. A host that does not use them sets `LoadOptions.skipsContainerAttachments`, which saves the open reading them: tens of megabytes on anime releases (AE#956).

`ASSScriptBuilder` reassembles raw event cues + header into a complete script for whole-file renderers such as swift-ass-renderer's `loadTrack(content:)`. It is hardened against real-world Matroska tracks: it synthesizes an `[Events]` section, strips NULs, and dedupes by content, since real files hardcode `ReadOrder: 0`.

**ASS and SSA only (AE#587).** The flag reaches ASS and SSA tracks only, on the embedded and the sidecar path alike. libavcodec normalises SubRip, WebVTT and mov_text into event lines of the same shape (through `ff_ass_add_rect`). So those rects carry an ASS payload the engine could emit, and it deliberately never does. No header is surfaced for them (`TrackInfo.assHeader` is ASS/SSA-only), which would leave a host stripping the nine leading fields by hand. A session that mixes an ASS track with a SubRip one therefore needs no reload to switch between them, and `aetherctl play --preserve-ass-markup --subs <track>` shows which of the two a given track is.

**Where the header arrives (AetherEngine#48).**

- Embedded tracks carry it on `TrackInfo.assHeader`.
- External `.ass` / `.ssa` sidecars loaded through `selectSidecarSubtitle(url:)` under the same `preserveASSMarkup` flag carry it on `engine.sidecarASSHeader` (extracted from the file's subtitle-stream extradata; nil for SRT / VTT and when preservation is off).

Both pair with the raw event-line cues the same way.

The native WebVTT renditions strip the markup at serve time, so PiP, AirPlay and an external display show plain text in the system caption style while the host overlay keeps the styling ([Native subtitle renditions](#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display)).

The host stays in charge of the actual paint: text styling, overlay layout, fade transitions, position scaling against the on-screen video rect.

## Frame extraction

`FrameExtractor` produces still `CGImage`s from a media URL. It uses an FFmpeg decode context isolated from playback, so a scrub-preview decode cannot disturb the frame on screen.

- `thumbnail(at:maxWidth:)` seeks to the nearest keyframe, for scrub previews.
- `snapshot(at:maxSize:)` decodes forward to the exact time, for user-triggered stills.

The API, its lifecycle and the cache-backed stills of the active session are in [api › Stills and thumbnails](api.md#stills-and-thumbnails). What depends on the format:

**HDR stills.** PQ / HLG BT.2020 frames are tone-mapped to SDR BT.709 through a zscale + tonemap libavfilter graph before the `CGImage` is built, so HDR10 / HLG / DV P8.x stills match what the user sees instead of washed-out grey.

**Dolby Vision Profile 5 and AV1 Profile 10.0** (IPT-PQ base layers with no HDR10 fallback) route through `DolbyVisionStillConverter`, an optional component compiled only with the `DolbyVisionStillReshaping` package trait (off by default, [Installation › Optional components](installation.md#optional-components)).

- With the trait, the converter applies the full reconstruction from the RPU in `AV_FRAME_DATA_DOVI_METADATA`: the reshaping curves first, then `ycc_to_rgb` + the IPT-PQ LMS matrices, then a BT.2390 tone curve. Their stills come out with correct colour instead of the green / magenta cast a plain YCbCr read produces.
- Built without it, such a source yields no still at all (nil, `supportsCacheBackedStills` false, no I-frame rendition, no held picture) rather than the planes read as YCbCr. [api › Scrub previews for Dolby Vision Profile 5](api.md#scrub-previews-for-dolby-vision-profile-5) is the preview for that case.

## Disc (DVD / Blu-ray ISO)

Decrypted disc images play through the normal decode path via a synthetic seekable byte source. `DiscReader` detects and routes both local `.iso` URLs and `MediaSource.custom` ISO readers.

**Not supported, for both formats:** decryption (CSS / AACS retail discs must be ripped decrypted first), GPL nav libraries, menus, BD-J, multi-angle.

### DVD-Video ISO

1. `ISO9660Reader` reads the ISO9660 bridge filesystem. An image without a bridge volume (UDF only) has `VIDEO_TS` listed by `UDFReader` instead, once no `BDMV` is found there.
2. `DVDIFOParser` reads the VMGI (VIDEO_TS.IFO) TT_SRPT to enumerate the disc's titles, and each title set's VTS IFO (VTS_NN_0.IFO) program chain for the title duration and chapters.
3. `DVDTitleSelector` groups each title set's content VOBs (whole-VTS, largest first).
4. `ConcatIOReader` presents the selected title's concatenated VOBs as one seekable source, demuxed as MPEG-PS.

- **Fallbacks.** On an unreadable VMGI it falls back to the VOB-size grouping. An unreadable VTS IFO leaves the title's duration and chapters empty but still plays.
- **Timeline.** The main program chain's cells are folded onto one title timeline with the Blu-ray clip fold, each cell's timestamp base read from its navigation packs, since many discs restart the timestamps at a cell. Only a chain whose cells follow each other from the first title sector, with no angle block, is folded.
- **Seeking.** A seek goes to the VOBU's byte through the VTS time map (VTS_TMAPT).

### Blu-ray ISO

1. A read-only `UDFReader` (UDF 2.50, including the metadata partition and fragmented-file allocation descriptors) resolves BDMV.
2. `MPLSParser` + `BDTitleSelector` enumerate every `.mpls` playlist as a selectable title (longest first, so id 0 is the main feature; trivially short menu / FBI-warning playlists are filtered).
3. The selected title's `.m2ts` clips are concatenated and demuxed as MPEG-TS (H.264 / HEVC / VC-1, AC3 / EAC3 / DTS / TrueHD / LPCM, PGS subtitles).

**Seeking.** A seek goes by the clips' EP maps (`BDMV/CLIPINF/*.clpi`, the keyframe index): the folded title time names the clip, its `in_time` turns that into the clip's own clock, and the map gives the keyframe's byte. The seek is one byte reposition. It also holds on titles whose clips run their clocks over the same range, where a timestamp search lands in the wrong clip. A title with a clip that has no readable EP map seeks by timestamp.

**UHD Dolby Vision (AE#805).** A UHD clip's Dolby Vision lives in a second HEVC stream, the enhancement layer on PID `0x1015`, whose access units carry the RPUs. The base layer on `0x1011` carries none, and neither has a DOVI record.

- `BluRayDolbyVisionLayers` (in the demuxer) appends each RPU to the base picture with the same PTS, declares the base layer Profile 7 and keeps the enhancement packets to itself. So the clip takes the Profile 7 to 8.1 conversion like a remux, instead of playing as HDR10. On the 8.1 path the enhancement layer's pictures are not folded in.
- When the dual-layer route is wanted, the demuxer joins the two PIDs into one unit per picture instead (`DolbyVisionLayerJoin`, see [Dolby Vision FEL](dolby-vision-fel.md)), so a FEL clip takes the dual-layer route. A clip whose layers cannot be joined (a transport stream with no parameter sets in its record) still logs `not taken (enhancement layer on its own PID ...)`.
- A Matroska or MP4 file that carries the enhancement layer as a second video track is treated the same way. That means a `dvcC` record on the enhancement track declaring the enhancement layer only, and on the other track either a Profile 7 base-layer record or (as in Dolby's own `dby1` MP4 layout) a plain HDR10 base track with no record at all.
- This applies to folders as well.

### Remote disc images (AE#860)

A remote disc image is recognized by:

- its `.iso` / `.img` / `.udf` extension, or
- on an extensionless URL, the `Content-Type` of the opening response: `application/x-iso9660-image`, `application/x-cd-image`, `application/vnd.efi.iso`, `application/x-udf-image`, `application/x-raw-disk-image`, or
- an `application/octet-stream` answer whose body has a volume descriptor identifier (`CD001`, `BEA01`, `NSR02`, `NSR03`) in sector 16, which is already in the opening buffer. No extra request is made for it.

The type or signature only routes the open to the disc adapter. The ISO 9660 / UDF structure decides, and a body without one plays as ordinary media.

It needs an origin that honours HTTP `Range`, because a disc image is a filesystem that only random access can walk. The range probe is judged at the response head. An origin that answers it with a 200 fails the load with an error naming the cause (the body is never downloaded). A range answered wider than asked is cut where the range ends.

### Blu-ray folders

A disc ripped as a `BDMV` folder rather than an image plays the same way, through `MediaSource.custom` with a `DiscDirectoryReader`: the host lists the folder's files (path relative to the disc root, and size) and opens any one of them on request. `HTTPDiscDirectoryReader` is the ready-made one, with one URL per file, so an origin serves the disc as plain files over `Range` and never remuxes it.

The engine recognizes a folder by its reader's conformance (to `DiscDirectoryReader`), so `discImageProbeEnabled` does not matter for it. That flag gates signature reads on a byte source, and a folder has none. A controlled probe (`limits` or `cancellation`) reads a folder too. The playlists, IFOs and clip infos that recognition opens, and the clips' bytes, all count against `maxInputBytes`. A cancellation or a spent budget stops the scan before the next file opens.

Recognition is the image path with files in place of UDF extents:

- the same bounded playlist scan and title selection,
- the selected title's `.m2ts` files concatenated in playlist order as one MPEG-TS,
- the same multi-clip timeline, chapters and STN track languages,
- the same seek by the clips' EP maps when the folder carries `BDMV/CLIPINF`.

A host that already knows the main playlist names it in `preferredPlaylist`, and only that playlist is read and published as the title. The name to pass is `TitleInfo.playlist` from an earlier open, so a host can store it at the first open and skip the scan of every `.mpls` from then on. The concatenating reader opens a clip's file when the read reaches it, and keeps at most three open.

### DVD-Video folders

A listing that holds `VIDEO_TS/` files and no playable Blu-ray title is read as DVD-Video instead, by the same title-set code as an image. The selected title set's VOBs are concatenated in part order, which is the same run of bytes as their sectors on a disc, so the cell timeline and the VTS time map apply unchanged. `preferredPlaylist` does not apply.

### Title selection

- `engine.discTitles` (`@Published [TitleInfo]`) lists the disc's titles (id, name, duration, chapter count, and what the title is on the disc: `playlist` on Blu-ray, `titleSet` on DVD).
- `id` is the title's position in this scan, longest first, and can name another title after the disc was replaced. `playlist` and `titleSet` come from the disc itself, so a host stores those to recognize a title at a later open.
- `engine.selectedDiscTitle` is the active one.
- `engine.selectTitle(id:)` switches title, rebuilding the pipeline from the new title's head.

The selection survives audio-track switches and background-resume reloads. A fresh `load` defaults to the main title (an out-of-range id clamps to it). Blu-ray enumerates all playlists. A DVD enumerates its title sets (the VMGI TT_SRPT title list, resolved whole-VTS, with the duration read from each VTS's main program chain; per-cell / episodic splitting is deferred).

### Chapters

`engine.discChapters` (`@Published [ChapterInfo]`) carries the selected title's chapters. `engine.selectChapter(id:)` seeks to one (a thin `seek` wrapper, no pipeline rebuild).

- **Blu-ray:** from the playlist's PlayListMark entries (entry marks only; link points dropped), each mark's timestamp on its clip's STC offset by the clip's in_time and the cumulative duration of preceding play items.
- **DVD:** from the main program chain's program map plus the cumulative cell playback times.

Chapter starts are title-relative (0-based). `selectChapter` adds the title's content-start base (the native playlist shift, or the software path's container start PTS), so the seek lands on the source-PTS playback axis.

### Track languages

Neither disc format carries a track language in the stream. A title demuxed on its own reports every audio and subtitle track as undetermined, and `preferredAudioLanguages` / `preferredSubtitleLanguages` have nothing to match on. So the languages are read out of the disc's own navigation data and backfilled onto the tracks by stream id:

- **Blu-ray:** from every PlayItem's STN table (the ISO 639-2 codes beside each stream's PID, first declaration winning).
- **DVD:** from the VTS IFO audio and subpicture attribute tables, with the title's main program chain naming the substream each attribute is actually carried as. A stream the chain marks absent is dropped. Without a readable chain the attribute's position is used, which is how the great majority of discs are authored.

Only an undetermined track is filled in: a language the container really declares stays authoritative. `aetherctl disc-inspect` prints what a disc declares per title, so a disc whose tracks stay undetermined can be told apart from a disc that declares nothing (#527).

### Subpicture streams and the probe

An MPEG-PS demuxer can meet a new stream at any packet, so libavformat never lets `find_stream_info` stop early on a DVD. With the playback budget, that would mean 50 MB read on every open, and a subtitle whose first packet came later would not be a track at all.

So for a title whose VTS IFO is readable, the engine creates every subpicture stream the IFO declares before the probe. `mpegps` routes packets to an existing stream by id. The engine joins each subpicture's PES fragments itself, because libavformat's `dvdsub` parser only attaches to streams the demuxer created. Such a title then probes 8 MB / 5 s (#651).

- Stream indices on such a title start with those subpicture streams.
- A disc without a readable VTS IFO keeps the full budget.

### Container chapters

`engine.mediaChapters` (`@Published [ChapterInfo]`) carries the chapters a Matroska or MP4 container declares, read off the probe demuxer at load. It is empty for disc sources, which publish `discChapters` instead, so exactly one of the two is populated.

**Axis (#815).** `startSeconds` and `durationSeconds` are on the 0-based axis that `currentTime` and `seek(to:)` use, so a host hands `startSeconds` straight to `seek(to:)`. The engine gets there by moving each container time back by the origin the playback clock begins at:

- the container start, on the native path,
- the software clock's session zero, on the software path (0 within its 2 s tolerance),
- 0 for live.

Raw container times are on the `sourceTime` axis instead.

**Details.**

- A chapter that ends at or before that origin (a pre-roll ahead of a container start of 5 s) is left out. One that straddles it starts at 0.
- The list is empty until the backend is chosen, because the origin is not known before. It is rebuilt from a probe-time snapshot when the software clock anchors, so it follows the seek axis when that zero moves.
- `selectChapter(id:)` resolves against `discChapters` only, and no-ops for a container chapter id.
- Ids are assigned sequentially in start order, so they stay usable as list indices. Untitled entries are numbered "Chapter N".
- A chapter's duration runs to the next chapter's start rather than to its declared end, because muxers routinely write `end == start`. The last entry falls back to its declared end, then to the container duration.

## Custom byte sources (`IOReader`)

`MediaSource.custom(reader, formatHint:)` plays from a host-owned byte source (a memory buffer, an encrypted container, a tuner spool) through the same decode paths as a URL. Its contract (`cancel()`, in-place rebuilds, where a reopen starts, the position axis) is in [api › Custom byte sources](api.md#custom-byte-sources-ioreader).

## Network sources (SMB)

The optional `AetherEngineSMB` product plays media off an SMB share (SMB 2.0.2 and 2.1, read-only, NTLMv2 or guest) as a seekable `IOReader`, so track switching, subtitles and scrub previews work as on a URL. No SMB3 encryption or signing, so an SMB3-only server does not connect. Setup and limits: [guide › SMB shares](guide.md#smb-shares).

## Live ingest, AES-128, SSAI

### HLS live ingest

A live HLS upstream can be ingested directly via `HLSLiveIngestReader` (a public forward-only `IOReader`), with no media server in the data path.

- **Prefetch (#177).** Segments are fetched through a bounded prefetch pipeline: up to 4 in flight, committed to the byte stream strictly in playlist order. So the connection and TTFB (time to first byte) latency of each segment overlaps with the others, and high-bitrate channels buffer ahead of real time.
- **Supported:**
  - MPEG-TS segments, whole or as `EXT-X-BYTERANGE` sub-ranges of one resource (fetched with a `Range` request; an origin that answers 200 has the sub-range cut from the whole body),
  - demuxed-audio variants (`EXT-X-MEDIA` audio groups, fetched by a companion reader and merged by DTS), on the native path only. The rendition is the session's audio even when the variant's segments carry audio of their own, as RFC 8216 asks and AVPlayer does. The software path has no side-audio merge and keeps the variant's muxed audio,
  - packed-audio renditions (raw ADTS framed by ID3 timestamps),
  - AES-128 clear-key segments (below).
- **AES-128.** Clear-key segments (`EXT-X-KEY:METHOD=AES-128`, the standard FAST-channel scheme) are decrypted in-line by `HLSSegmentDecryptor`. The key is fetched once per clip and memoised, and each segment is decrypted (AES-128-CBC / PKCS7) before demux. This is standard HLS clear-key, not FairPlay / Widevine.
- **Refused** with a typed `HLSIngestError`, so the host can fall back to a server-mediated URL: SAMPLE-AES, keyless AES-128 (no `URI`), fMP4 playlists (`EXT-X-MAP`), and a key-fetch / decrypt failure.

### Server-side ad insertion (SSAI)

SSAI (ads spliced into the stream by the server) plays through the direct path instead of bouncing to a server transcode at the ad break. FAST channels (Pluto and similar) splice ad creatives that restart the source clock and often carry a different video PID, resolution and SPS than the program.

- The producer detects the program switch, parses the ad's SPS/PPS by hand (`H264SPS`) to build a fresh codec config, rotates the fMP4 muxer, and emits a versioned `#EXT-X-MAP` per discontinuity, so AVPlayer resyncs cleanly across the init and resolution change.
- Audio is re-anchored to the video timeline at every creative boundary (including amux creatives that mux audio on a separate source clock).
- With a demuxed audio rendition (Pluto TV: muxed programme segments, video-only ad segments, the sound of both in the rendition), the video PID switch works the same way. The merge orders the two readers by clock run before timestamp. Both clocks restart at the seam and each reader reaches it on its own schedule, so ordering by timestamp alone would hand out the ad before the end of the programme. Inside one run, two clocks more than 60 s apart (FFmpeg lifts the rendition's restart to 2^33 + x while the video stays at x) are compared by their distance from the run's first packets. A restart only one reader ever shows stops holding the other back after 10 s of its media. Every run change logs `merge clock run:`.
- An `OutputTimestampSanitizer` keeps the stream monotonic across the splice.
- **Audio on a new PID.** When an ad carries its audio on a PID of its own, the producer follows it only for stream-copied ADTS AAC whose frames match the track's configuration (`audio follows the source to stream N`). A bridged track or another codec logs `not followed`, and those segments are cut without sound.
- **Software path.** It has no side-audio merge, so ads that carry their sound only in a demuxed rendition (Pluto) play silent there. A live source that depends on a demuxed rendition and has no muxed audio of its own fails fast on the software path (`demuxedAudioLiveUnsupported`, `HLSIngestError.demuxedAudioNotSupported`), so the host can fall back.

**Stall watchdog.** A no-cut stall watchdog sits underneath as a safety net. It tells a genuinely wedged pod (reading at full rate but unable to cut) from a slow source (a trickle) by read rate. A stall classed as a wedge whose video PTS is still advancing (a source delivering just below real time, #177) is held instead of retuned, with the watchdog re-armed. The number of holds in a row is bounded. Only a genuine wedge or an exhausted hold budget escalates to a host retune.

### Validation

The live path's sliding-window eviction (which bounds resident memory) and DVR rewind are confirmed on Apple TV against a real broadcast feed: `behindLiveSeconds` holds at real-time pacing, and the resident footprint stays bounded within the tvOS jetsam budget. The same behavior is exercised off-device through the `aetherctl live` / `hlsfixture` harnesses (sliding-window retention, real-time pacing, mid-stream reconnect, program-boundary discontinuities, DVR timeshift).

### Raw live MPEG-TS and the live join

Raw live MPEG-TS over HTTP (a tuner, a tuner proxy, or an IPTV panel's continuous form of a channel) is routed like any live source: the native loopback path, unless the codec, declared interlace or a host override sends it to the software path.

**Software join on raw MPEG-TS.** Such a stream opens with whatever the origin holds of the channel, sent at link speed (8 to 18 s on one IPTV panel). A software session that started on the first packet of that burst would run the whole burst behind the broadcast for as long as it played. So once the burst has landed, the live feeder places the start `SoftwareLiveJoinPolicy.leadSeconds` (4 s) behind the newest media, on a keyframe, and the burst stays in the rewind ring. (The native path's AVPlayer already sits a holdback behind the newest segment.)

**Software join on live HLS (AE#813).** A live HLS ingest on the software path delivers a whole segment at a time instead, so its holdback follows the segment length (`SoftwareLiveHoldback`):

- The join starts `1.5 x segment + 1 s` behind the newest media (4 s on 2 s segments, 16 s on 10 s segments, at most 45 s).
- A rebuffer resumes only once one segment plus 2 s stands ahead of the clock.
- Return to Live lands as far back as a join.
- The live-edge verdict counts that distance plus one segment as the edge (the next segment can land right after a placement).

With a fixed 4 s lead instead, the buffer runs dry before every 10 s segment and the session stalls once per segment.

**Loading a live source.**

- Load it with `isLive: true` plus a `dvrWindowSeconds` for live semantics and the fastest open. An explicitly live load skips the open-time size probes entirely.
- `SourceProbe.isLive` flags no-duration network streams, so hosts can detect and reload.
- **Mid-stream joins (#107).** Sources joined mid-stream deliver their first samples at arbitrary PTS hours past zero. They anchor the clock at the first decoded sample on every session shape (live, live+DVR, and a plain VOD open of the same URL or of a mid-broadcast capture file), publishing session-relative positions while `sourceTime` stays on the source axis for subtitles.

**A PAT program that never sends its PMT.** The TS demuxer only knows its stream list is complete once every program its PAT lists has sent a PMT. Until then `avformat_find_stream_info` cannot take its "all info found" exit. Some IPTV panels and restreamers pass on a multiplex fragment whose PAT still lists a program they do not carry. Without a release, such a channel reads the whole playback budget (50 MiB / 60 s) after every stream it has is resolved.

- The engine releases that wait once the stream analysis has received data for 2.5 s while one program still has no PMT and another has its PMT and an audio or video stream. 2.5 s is five missed repetitions of the 0.5 s PMT interval ETSI TR 101 290 expects.
- A program whose PMT declares only data, SCTE-35 or teletext streams does not count. Those pass the analysis at once, so a release next to one would end it on the audio and video the demuxer guessed from their packets, before the TV program's PMT has declared its streams, their languages and its subtitle tracks.
- A stall counts as at most 0.5 s of that window, since no PMT can arrive while no data does. A source that stops delivering mid-analysis therefore does not run the window down.
- The release is what the demuxer does itself when the last PMT arrives, and it interrupts nothing. The analysis still stops only once every stream has its parameters, so late audio and a late keyframe are still waited for under the same budget, and no stream is dropped.
- A TS whose programs all send their PMT, and every other format, are untouched.
- A PMT that first arrives after the release adds its streams during playback, as a PMT version change does.

Measured through `aetherctl play --live` on a live-paced synthetic channel, median of 5: the stream analysis went from 58.7 s (32 MB, three requests, because the reader reconnects at the end of the 30 s fixture and the pass runs on to its 60 s cap) to 2.5 s (1.6 MB, one request), with both tracks. With audio that starts 5 s late it takes 4.9 s, and with a join 3 s into a 10 s GOP 7.6 s, the same as those channels without the silent program.

## Known limitations

Things that work today but have a documented edge case, or are deferred behind an upstream dependency.

- **The channel bridge drops TrueHD Atmos objects and DTS:X heights.** TrueHD / MLP and DTS-HD sources route through the AudioBridge. FFmpeg's EAC3 encoder does not produce JOC, and FLAC has no object channels, so bed channels and surround layout survive but objects and heights do not. `LoadOptions.objectAudioRendering = .render(layout)` keeps them, in a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default, [Installation › Optional components](installation.md#optional-components)). They are built into a speaker bed from the stream's own lossless 7.1 and delivered as 24-bit PCM, or APAC over AirPlay, which tvOS sends to an Atmos receiver as Dolby MAT ([TrueHD Atmos with heights](#truehd-atmos-with-heights), [DTS:X with heights](#dtsx-with-heights)). EAC3+JOC stream copy from MKV / MP4 sources is intact either way.
- **`.surroundCompat` audio bridge caps 7.1 sources to 5.1.** FFmpeg's EAC3 encoder currently caps at 6 channels. Once [FFmpeg PR 21668](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/21668) lands, the cap and the dynamic bitrate auto-scale to 1024 kbps engage without a code change here. Use `.lossless` (FLAC) today if 7.1 matters.
- **Now Playing and the audio session.** On the HLS-loopback path of tvOS 26, manual `MPNowPlayingInfoCenter` writes race the player; a host with a custom transport lets the engine own the card instead (`ownsVideoNowPlayingSession`). The engine activates the audio session per playback, not at launch, so tvOS can negotiate the HDMI channel count (AetherEngine#24). Both are host contracts: [api › Now Playing and the audio session](api.md#now-playing-and-the-audio-session).
- **AV1 on Apple TV is software-decoded.** No current Apple TV chip ships hardware AV1. The `SoftwarePlaybackHost` + dav1d path handles it, but CPU use is clearly higher than with hardware HEVC. For 10-bit AV1, film grain and the P010 conversion run on the GPU, so what stays on the CPU is dav1d's decode. A Profile 10.1 source keeps its Dolby Vision there ([Dolby Vision signaling](#dolby-vision-signaling)). Where the chip decodes AV1 (A17 Pro, M3 and later), Main profile AV1 takes the native route; High and Professional stay on software. Future Apple TV chips with hardware AV1 will be picked up automatically by `VTCapabilityProbe`.
- **AV1 Dolby Vision Profile 10.0 does not play on the software path.** dav1d / libavcodec cannot decode the proprietary DV colour space, so a Profile 10.0 source (DV-only, no fallback base layer) would show a green / purple picture there. The load fails instead, with `AetherEngineError.dolbyVisionUnplayableOnSoftwarePath` and the error kind `.dolbyVisionRequiresHardware`. HEVC Profile 5 is refused the same way when it reaches the software path (#176). Profiles 10.1 and 10.4 are unaffected, because they carry an HDR10 / HLG base layer. Profile 10.0 only plays through the native AVPlayer path on hosts with hardware AV1 decode.
- **Dolby Vision Profile 5 / AV1 Profile 10.0 thumbnails need the `DolbyVisionStillReshaping` trait.** Without it such a source yields no still ([Frame extraction](#frame-extraction)). A frame that carries no DV metadata falls back to the standard path.

## Moved sections

Older links to these sections still land here.

### MP4 without composition offsets

Moved to [MP4 without composition offsets](architecture-native.md#mp4-without-composition-offsets).

### H.264 with a changing decode cadence

Moved to [H.264 with a changing decode cadence](architecture-native.md#h264-with-a-changing-decode-cadence).

### Writers that push timestamps to keep them monotonic

Moved to [Writers that push timestamps to keep them monotonic](architecture-native.md#writers-that-push-timestamps-to-keep-them-monotonic).

### Matroska with presentation slots in coding order

Moved to [Matroska with presentation slots in coding order](architecture-native.md#matroska-with-presentation-slots-in-coding-order).

### MP4 with composition offsets missing only in later regions

Moved to [MP4 with composition offsets missing only in later regions](architecture-native.md#mp4-with-composition-offsets-missing-only-in-later-regions).

### A video sample whose NAL chain overruns it

Moved to [A video sample whose NAL chain overruns it](architecture-native.md#a-video-sample-whose-nal-chain-overruns-it).

### 24p film with 2:3 pulldown timestamps

Moved to [24p film with 2:3 pulldown timestamps](#files-with-broken-timestamps-or-bitstreams).

### A Profile 5 the container never recorded (`AE#recordless`)

Moved to [A Profile 5 the container never recorded (AE#recordless)](#a-profile-5-the-container-never-recorded-ae567).

### Forward prefetcher (#151)

Moved to [Forward prefetcher (#151)](architecture-native.md#forward-prefetcher-151).

### Sharing the link with video (#240)

Moved to [Sharing the link with video (#240)](architecture-native.md#sharing-the-link-with-video-240).

### Ending a PGS cue

Moved to [Ending a PGS cue](architecture-native.md#ending-a-pgs-cue).

### Holes in the packet store (#362, #941, #1021)

Moved to [Holes in the packet store (#362, #941, #1021)](architecture-native.md#holes-in-the-packet-store-362-941-1021).

### The landing after a seek (#416)

Moved to [The landing after a seek (#416)](architecture-native.md#the-landing-after-a-seek-416).

### Rich ASS styling

Moved to [Rich ASS styling](#authored-ass-styling).

### Device-verification checklist

Moved to [Device-verification checklist](../CONTRIBUTING.md#device-check-for-native-subtitle-renditions).

### `cancel()` unblocks, it does not invalidate

Moved to [cancel() unblocks, it does not invalidate](api.md#cancel-unblocks-it-does-not-invalidate).

### In-place rebuilds reuse the reader

Moved to [In-place rebuilds reuse the reader](api.md#in-place-rebuilds-reuse-the-reader).

### Where the reopen starts

Moved to [Where the reopen starts](api.md#where-the-reopen-starts).

### The axis a reader reports on is the axis it is asked on

Moved to [The axis a reader reports on is the axis it is asked on](api.md#the-axis-a-reader-reports-on-is-the-axis-it-is-asked-on).

### Host position arithmetic keyed to vending a stream

Moved to [Host position arithmetic keyed to vending a stream](api.md#host-position-arithmetic-keyed-to-vending-a-stream).
