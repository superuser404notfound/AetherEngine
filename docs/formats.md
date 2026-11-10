# Formats, codecs, and playback detail

This page is the detail behind the README's "What it handles" matrix: which formats play, which decode path each one takes, how HDR and Dolby Vision are signaled, how audio is bridged, how subtitles work, and the documented edge cases. For the pipeline shapes these routes run through, see [docs/architecture.md](architecture.md).

Contents:

- [Containers and codecs](#containers-and-codecs): demux formats, DASH, hardware and software decode, timestamp repairs for broken files
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

That list is the supported set, not the compiled set. Two demuxers need a note:

- **HLS.** The FFmpeg build carries the HLS demuxer, but it is not a supported source shape. The build ships no network protocols (only `file`, `pipe` and `data`, because bytes come from the engine's own `AVIOReader` over `URLSession`), so libavformat cannot fetch what a manifest points at. Remote HLS is handled one level up instead: by AVPlayer on the bypass, or by the live ingest.
- **DASH.** The DASH demuxer is not in the build at all (it needs libxml2, which the build does not link). Remote DASH has its own path, described next.

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

- **Selection.** The highest-bandwidth playable video representation, and the highest-bandwidth playable representation of every audio adaptation set, in manifest order. Representations inside one adaptation set are bitrate alternatives of the same content, so this keeps every language and drops only duplicates. There is no adaptive switching: the session plays the representations it opened with. Every carried audio track is fetched while it plays, selected or not (for the reporting asset, three AAC tracks totalling about 310 kbit/s next to a 1 Mbit/s video). Text and image (thumbnail) adaptation sets are not carried.
- **Languages.** An adaptation set's `lang` replaces a track's `und`, mapped to ISO 639-2/T (`en` becomes `eng`, `de-DE` becomes `deu`).
- **Network cost.** One request for the manifest and one per representation before the first media byte. During playback each representation file is read forward in requests that grow the way a single file's do, behind a small block cache per file (eight 1 MiB blocks). libavformat reads an interleaved file in decode order and switches between a video fragment and the audio fragments beside it on every sample. Without the cache, each return to the video file cost a fresh request: measured 1,042 requests for 45 s of one video file, against 65 with the cache, and the same origin byte total as the equivalent single MP4.
- **Refused, with the reason in the error:** live manifests (`type="dynamic"`), more than one Period, `SegmentTemplate` and `SegmentList` addressing, an initialization segment in a separate file, hierarchical `sidx` (`reference_type` 1), and encryption (`ContentProtection`, `pssh`, `encv` / `enca`). An unplayable audio adaptation set is skipped when the video plays. An unplayable video one fails the load.
- **Seeking a fragmented MP4.** libavformat indexes such a file one fragment at a time. A forward seek whose next sync sample starts an unread fragment used to land on whatever later fragment an earlier read had indexed (a start at 150 s and a seek to 60 s rendered 122 s). `Demuxer.seek(to:streamIndex:)` now checks the samples between the target and the chosen sync sample for a hole in the index, and lands on the sync sample before the target instead. This applies to every fragmented MP4, not only to DASH.

### Hardware decode

Native AVPlayer path, VideoToolbox:

- H.264 (progressive), HEVC, HEVC Main10, on hardware whose VideoToolbox has a decoder for the specific profile.
- AV1 on devices with hardware AV1 (M3+ Mac, iPhone 15 Pro+, future Apple TV chips).

### Software decode

`SoftwareVideoDecoder` + `AVSampleBufferDisplayLayer`. These sources take it:

| Source | Why it is software | Decoder |
| --- | --- | --- |
| AV1 without hardware AV1 | No HW decoder (all current Apple TVs, M1 / M2 Macs, pre-A17-Pro iPhones) | libavcodec / dav1d |
| VP9, VP8 | AVPlayer's HLS pipeline rejects the `vp09` / `vp08` CODECS attributes | VideoToolbox for some VP9, else libavcodec |
| MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, VC-1 | AVPlayer's HLS-fMP4 pipeline accepts none of them | libavcodec |
| MS-MPEG4 v1 / v2 / v3, WMV1 / WMV2 / WMV3 | Legacy Microsoft tail (FFmpegBuild 2.4.3) | libavcodec |
| FLV1, VP6 / VP6F / VP6A | Flash tail (FFmpegBuild 3.2.0) | libavcodec |
| RealVideo 1 to 4, H.263, Theora | 2000s tail (FFmpegBuild 3.8.0) | libavcodec |
| Interlaced H.264 | tvOS AVPlayer does not deinterlace | libavcodec + deinterlacer |
| H.264 High 4:2:2 / 4:4:4 / High-10, HEVC Rext, where VideoToolbox lacks the profile | Native path renders nothing | libavcodec |
| H.264 with both MVC stereo views in one track | VideoToolbox renders nothing | libavcodec (base view) |

Any video codec not on this list and not on the native allowlist fails the load (see [Every other video codec](#every-other-video-codec)).

#### AV1

AV1 runs through libavcodec / dav1d on devices without hardware AV1.

- **10-bit.** A 10-bit AV1 frame reaches P010 on the GPU with its film grain applied there (`GPUFrameConverter`). dav1d exports the grain parameters instead of applying them, and one Metal pass does both the grain and the planar-to-P010 conversion that `sws_scale` used to do, matching dav1d's picture sample for sample. This takes two per-pixel passes off the CPU that the decode needs, which on a fanless Apple TV means heat.
- **8-bit.** Keeps dav1d's grain and `sws_scale`.
- **Fallback.** A 10-bit frame the GPU pass refuses (no Metal device, a failed command buffer) falls back to `sws_scale` without its grain, since dav1d was told at open not to apply it.
- **Seeking.** A seek lands on the keyframe nearest its target rather than exactly on it (`SWKeyframeSnap`). Otherwise dav1d would decode from the keyframe before the target up to the target, and on an Apple TV 4K (A15) that took 2 to 5 s into 4K AV1, whose encodes run long GOPs ([api › Transport](api.md#transport)).

#### VP9 and VP8

VP9 and VP8 always use the software presentation route, because AVPlayer's HLS pipeline rejects the `vp09` / `vp08` CODECS attributes.

- VP9 tries a VideoToolbox hardware session for 8-bit profile 0 or 10-bit profile 2 with 4:2:0 chroma, synthesizing WebM's missing `vpcC` record from probed parameters.
- Other VP9 profiles, and failed hardware opens, fall back to libavcodec. VP8 always uses libavcodec.
- A key frame that changes the coded size (concatenated clips, adaptive recordings) gets a session of its own size. VideoToolbox answers every frame after a size change with `kVTVideoDecoderBadDataErr`, and playback would otherwise end silently at the switch.
- `activeVideoDecoder` names the decoder that actually opened.

#### MPEG-4 Part 2, MPEG-2, VC-1

MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video and VC-1: AVPlayer's HLS-fMP4 pipeline accepts none of them, and libavcodec ships native decoders for all three.

#### Legacy Microsoft codecs (FFmpegBuild 2.4.3, 3.1.0)

- **Video (FFmpegBuild 2.4.3):** MS-MPEG4 v1 / v2 / v3 (the DivX 3.x that pre-2005 AVI rips carry) and WMV1 / WMV2 / WMV3 (WMV9). The routing was already correct before that release: these reached `SoftwareVideoDecoder` and failed the load with `unsupportedCodec` because no decoder was compiled in.
- **Native `.wmv` / `.asf` files (FFmpegBuild 3.1.0):** play whole since that release added the `asf` demuxer and the entire WMA decoder family (Standard, Pro, Lossless, Voice). The video in such a file is usually WMV3 or VC-1, both already supported for their Matroska and MPEG-TS shapes.
- **All or nothing, on purpose.** The demuxer without a matching WMA decoder would open the file and then have nothing to decode its audio with: `AudioBridge` init fails, the cascade ends in `droppedNoPipeline`, and the session serves video only and plays the file silently. That is a worse failure than an honest one.
- WMA is not fMP4-legal in any flavour, so it always takes the AudioBridge, like MP2 and Blu-ray LPCM.
- None of the six video codecs supports frame threading, so they decode single-threaded. The content that carries them is SD.
- Reported by cmcpherson274 (FFmpegBuild#3), whose library carries WMV only inside Matroska and MPEG-TS. That is why the native form waited for a second field report.

#### Flash codecs (FFmpegBuild 3.2.0)

- **Video:** FLV1 (Sorenson Spark, the H.263 variant every pre-2008 `.flv` carries) and the On2 VP6 family (`vp6`, `vp6f`, `vp6a`) that Flash 8 brought.
- **Audio:** Nellymoser Asao, ADPCM-SWF, Speex, and FLV's G.711 / big-endian PCM shapes, shipped for the same all-or-nothing reason as the WMA family.
- The `flv` demuxer has shipped from the start, so a modern Flash file (H.264 + AAC) always direct-played. Only the legacy decoders were missing.
- **Flash Screen Video** (`flashsv` / `flashsv2`) is deliberately absent: it needs zlib, which the build does not link, and screen recordings are not what a media library holds.
- Requested in the Sodalite Discord.

**Where the all-or-nothing rule lives.** It lives in the FFmpeg build, not in the routing table. `AudioCodecCompat` decides whether a codec is offered a stream copy. The bridge cascade below it asks libavcodec for a decoder by id and never reads the table. So a codec the table does not name still plays when the build carries its decoder (measured on Nellymoser-in-FLV before its entry existed), and a codec the build lacks is silent whatever the table says.

#### 2000s codecs (FFmpegBuild 3.8.0)

- **RealMedia:** the `rm` demuxer, RealVideo 1 to 4 (`rv10` / `rv20` / `rv30` / `rv40`; an `.rmvb` is almost always RV40), and every RealAudio such a file carries (Cook, ATRAC3, Sipro, RealAudio Lossless, the 14.4 / 28.8 speech codecs), routed as one `realAudio` family.
- **Feature-phone 3GP / 3G2:** H.263 with AMR narrowband or wideband speech (`amr`), in the `mov` demuxer that was already here.
- **Theora**, the video of `.ogv`.
- **DVD LPCM** (`pcm_dvd`), which routes as `.pcm`.

The same all-or-nothing rule as WMA and Flash applies. None of the audio is fMP4-legal, so all of it bridges. Contributed by williamliu0516 (FFmpegBuild#7), checked against samples.ffmpeg.org files.

#### Every other video codec

Every other video codec fails the load by default. The native path has an allowlist of its own (HEVC, H.264, hardware-decodable AV1), and `HLSVideoEngine` refuses the rest with `unsupportedCodec`. So a codec that is merely absent from the lists above does not fall back to native, it fails the load.

- QuickTime RLE (`qtrle`, FFmpegBuild 2.4.1) is the case that surfaced this. ProRes, MJPEG, Cinepak and rawvideo have the same shape.
- Whether such a source then plays depends on the FFmpeg build. With no decoder compiled in, it fails at `SoftwareVideoDecoder` with `Unsupported video codec`, which is at least the honest error.
- `AV_CODEC_ID_NONE` is the one default-native case, since an audio-only source probes as NONE.

#### Interlaced H.264

Interlaced H.264 (declared field order TT / BB / TB / BT) takes the software path so the deinterlacer can run. tvOS AVPlayer does not deinterlace, so 1080i / 576i broadcast shows combing on the native path (#107).

On a seekable VOD source the declared field order is verified against decoded frames first (#232). A field order describes how pictures are carried, not that any picture is interlaced. Progressive content in interlaced carriage (PsF, which is what European 25 fps Blu-ray masters are, since Blu-ray has no 1080p25) used to take this detour and then never deinterlace, because the filter engages on `AV_FRAME_FLAG_INTERLACED` and on nothing else.

`InterlaceProbe` decodes a short sample and applies that same predicate, so it measures the runtime's own question rather than guessing at content:

- A sample in which the flag never appears sends the stream back to the native path with hardware decode.
- An inconclusive sample keeps the software route.
- A flagged frame ends the sample at once (~29 ms on 1080i, ~100 ms for a full sample).
- Live sources are never probed.

#### High profiles without a hardware decoder

H.264 High 4:2:2 / 4:4:4 / High-10 and HEVC Rext (4:2:2 / 4:4:4 / 12-bit), on hardware whose VideoToolbox has no decoder for the profile (Intel Macs, older Apple TV chips).

AVPlayer accepts these at the HLS CODECS level and the item reaches `readyToPlay`, but the native path then renders nothing. A per-format `VTDecompressionSession` probe at load (`VTCapabilityProbe.canHardwareDecode`) routes them to libavcodec, which decodes them (#2). Apple Silicon has hardware decoders for all of these and keeps them native.

The probe only judges a config record that actually carries out-of-band parameter sets. A source with in-band VPS/SPS/PPS (`hev1`, `numOfArrays = 0`) gives VideoToolbox no SPS to build a session from, which says nothing about hardware support, so those keep the native path (AetherPlayer#2).

#### 3D Blu-ray MVC

H.264 that carries both stereo views inside one track, which is how a 3D Blu-ray MVC remux is muxed: Matroska StereoMode 13 / 14 (`block_lr` / `block_rl`, both eyes in one block), reported by libavformat as stream-level `AV_PKT_DATA_STEREO3D` of type `AV_STEREO3D_FRAMESEQUENCE` and spelled `stereo_mode` in the stream metadata (#435).

- The dependent view's slices reference a subset SPS that the base decoder never receives, so a plain H.264 decoder can only skip them. libavcodec does that and decodes the base view, which is the left eye and the 2D fallback every non-3D player shows.
- VideoToolbox is handed whole samples with both views' NALs inside and renders nothing.
- The decision is the container's declaration, read at load. There is no probe.
- The frame-packed modes (side by side, top / bottom, checkerboard, row or column interleaved, anaglyph) are single self-contained pictures. They keep the native path with hardware decode. Cropping an eye out of one of those is the host's call, not the engine's.
- MV-HEVC keeps the native path too: it is Apple's own spatial-video format and AVPlayer plays its base layer.
- Real MVC 3D output is not offered on any path.

### Deinterlacing

Interlaced sources (DVD-rip MPEG-2, SD / HD broadcast H.264) are deinterlaced through a persistent bwdif graph (yadif fallback). It engages on the first interlaced frame and costs nothing on progressive content.

The dispatch decision lives in `AetherEngine.load` (`VideoRoutingPolicy`). It is gated per source on `VTCapabilityProbe`, the codec id, the declared field order, and on VOD the decode sample that verifies it.

### H.264 VOD with changing parameter sets

**The problem.** A length-prefixed H.264 file can keep its original `avcC` while later samples carry different SPS/PPS, including a resolution change under the same parameter-set IDs. Native HLS can then play audio without displaying video, including after seeking or reopening at that position.

**Detection.** The producer checks the parameter sets actually referenced by an IDR before writing it into the native segment. Repeated sets, and announcements that no IDR uses, do not change the route. Only the part of the SPS a decoder session is built from counts (`H264SPS.decoderSignature`: profile, chroma format and bit depth, frame numbering and picture order, reference frames, size and cropping). A new PPS, VUI or level keeps the native route, since the native decoder takes those in band: on macOS such a change played through natively in every arm, while a profile or resolution change froze the picture.

**What happens.** In automatic mode, with `escalatesToSoftwarePath` enabled, a confirmed mismatch uses the existing native-to-software takeover. The software decoder accepts the changing frame dimensions, and the rebuild keeps the requested seek/resume position and session transport. This can briefly buffer and costs software decoding CPU. The native-only features described elsewhere on this page are not available on that route.

Explicit decode-path choices and disabled escalation are honored, with an error when the native initialization cannot serve the source. Live Annex-B configuration rotation is unchanged.

### MP4 without composition offsets

**The problem.** Some writers emit a sample table with no `ctts` while the H.264 or HEVC bitstream still reorders pictures. Every sample then reports `PTS == DTS`. The native route stream-copies those timestamps into fMP4, so AVPlayer is handed decode order as presentation order: each future reference picture is shown before the B pictures that come before it. Measured through AVFoundation's own decoder on a twin pair (one encode muxed twice, composition offsets removed from one): 45 of 66 pictures landed at a time belonging to a different picture, and the content order stepped backwards 30 times (#409).

**The repair.** The container lost the information, but the bitstream did not. Every slice header carries a picture order count, which is display order. libavcodec's H.264 and HEVC parsers read it without decoding a pixel, and take MP4's length-prefixed payload directly. `H264CompositionOffsetRepair` samples the head (twelve pictures at most, held rather than re-read, so no rewind and no second fetch) and repairs a confirmed source at the demuxer boundary:

    PTS = (decode time of the picture that opened this coded video sequence) + shift + rank * step
    DTS = DTS + shift - reorderDelay * step

- Pulling decode time back by the reorder delay is what keeps `PTS >= DTS`. A healthy file carries the same negative head.
- `shift` is 0 or one reorder delay, depending on whether the writer left the sample ladder on the presentation axis or kept the edit list that trims the reorder head. It is clamped to that range so a malformed header cannot drag the picture off its audio.
- The rewrite happens once, in the demuxer, so the fMP4 producer, the segment plan, the software decoder and the still extractor all read one axis.
- The source keeps hardware decode: a missing table costs no route change.
- The container's own index is folded onto the same ladder, because the segment plan is built from index entries and then filled with these packets.

**Detection** is fail-closed and costs a healthy file almost nothing. The first real PTS-DTS offset ends the sample (usually on the first packet, since a reordered file's head sample sits one delay below zero). A source is repaired only when all of these hold:

- every sampled pair is equal,
- the decode ladder is uniform,
- the picture order regresses,
- the ranks it produces are distinct and fill the sampled window, or a decode-order prefix of at least nine pictures fills its own range exactly (this covers a hierarchical mini-GOP longer than the reorder delay, #699).

Anything short of that (a picture order that does not advance one rank per picture, a sample that starts nowhere it can be anchored) is delivered exactly as the container wrote it. Reported by @orut34iop; the HEVC case (#699) by @ijuniorfu.

#### H.264 with a changing decode cadence

For H.264 only, a changing decode cadence can instead use the original-slot policy described in [MP4 with composition offsets missing only in later regions](#mp4-with-composition-offsets-missing-only-in-later-regions). This fallback requires:

- a progressive IDR head with equal PTS/DTS,
- a container start/index lead that exactly matches the observed reorder head,
- a complete, distinct picture-order prefix whose timestamps pass the slot policy.

It assigns existing slots plus that lead rather than fitting a frame rate. DTS, audio and the keyframe index stay unchanged. An ambiguous head stays untouched.

#### Writers that push timestamps to keep them monotonic

**The problem.** Some writers go one step further: after dropping `ctts` they force the decode-order presentation times to be monotonic. Each B picture (and on some files each anchor too) decoded after another picture is pushed 1001 ticks (at 90 kHz, a third of a 29.97 fps frame) past the picture before it. There is then no ladder to read a step from. The reporting file (H.264 High, 720p, GOP 90) stepped 3003 on 87% of its samples and 1001, 2252, 9009 or 12012 on the rest. The probe skipped it as non-uniform, and QuickTime, the Files app and both engine routes showed the B pictures out of order.

**Choosing the step.** When nothing above takes such a head, it is repaired with the step taken from the stream's average frame rate. This requires that the sampled span is the time its pictures take at that rate, within the reorder delay plus two pictures, and that every other check above still passes.

- The step is then remeasured on the anchors when the writer left them on the presentation axis. The average rate is only an estimate: a 60-picture 29.97 fps clip reports 29.80.
- The reporting file pushed its P pictures as well (each anchor 1001 ticks past the picture before it), so no two anchors agree. The rate is then the one the bitstream's VUI timing states, if that is within 1% of the average rate, snapped to a standard frame rate (any whole rate up to 240, or an NTSC one such as 23.976 or 29.97) within 0.01%.
- Without a VUI rate, it is the standard rate nearest the average rate, if that is within 1%.
- A head with neither is left untouched.
- The VUI is what tells 24 from 23.976 on a short clip whose pushed tail drags the average. On all three reporting files it named the exact rate (23, 29.97 and 29.0002 fps).
- Pictures are placed on that rate as an exact fraction of a tick, so a 23 fps file (3913.04 ticks at 90 kHz) does not lose a tick every 25 pictures.
- DTS is rebuilt from each picture's decode slot rather than shifted, since a pushed B picture's DTS can sit after its own presentation time.

**Pushed keyframes.** The writer pushes keyframes as well, and only ever later. On both reporting files they sat 0 to 4 pictures after the end of the GOP before them, which left a gap or put the next GOP in front of the last pictures of the previous one. So a later IDR continues the sequence before it, unless:

- it is later than the reorder delay plus two and a half pictures (a real discontinuity; a third reporting file at 29 fps kept its keyframes four pictures late for a hundred seconds), or
- it is within half a tick per picture (all a rounded step can be off by).

An earlier IDR keeps its own time, which is how a chain started on a pushed keyframe after a seek moves back into place.

**Clock drift.** Counting alone follows the stated rate, and the writer's clock is not quite that (the third file states 29.0002 fps and writes 29.003). The chain drifted 61 ms behind the writer over 19 minutes and overlapped 3 times where an earlier keyframe pulled it back. A continued sequence therefore also leans toward the earliest origin the pictures before it point to, by at most an eighth of a picture per GOP, which removed both. (The writer only ever pushes a picture later, so the earliest origin is the nearest the truth.) A seek landing holds its first **8 pictures** and takes the earliest origin they point to in the same way.

**Segment boundaries.** A keyframe placed back like this sits before its index entry, by at most the reorder delay plus two and a half pictures, while the HLS segment plan is built from the index. The VOD cutter and the restart gate therefore reach that far back for the keyframe each boundary names, never as far as the keyframe before it. Without the reach, the keyframe stayed in the previous segment and the next one opened on audio, mid-GOP: `aetherctl segverify` counted that on 25 of 40 segments of the 23 fps file and 22 of the 29.97 fps one. All 40 are independent now, and so are segments a restart produced.

**Long P runs.** The second reporting file opens every GOP on twelve P pictures before its first B. So a head that has not reordered after twelve pictures, with `PTS == DTS` throughout, is sampled on to its first regression plus a mini-GOP, up to
**48 pictures**. The sampled span is checked against the rounded step with a tick per picture to spare, which is what the third file's head needed.

**Open-GOP seeks.** After a seek onto an open-GOP keyframe, which kept its own presentation time, the sequence origin is taken from its display rank rather than its decode slot.

**Shift clamp.** The shift is what puts the first keyframe on the stream's start time. It is clamped to **16 pictures** because this writer left the keyframe four pictures ahead.

**Measured** on generated twins from `Scripts/make-clamped-ladder-fixture.sh` (900 pictures at 29.97 fps):

| Fixture | Before | After |
| --- | --- | --- |
| Base twin, AVPlayer route | 169 backward steps | 0 |
| Base twin, software route | 44 backward steps | 0 |
| `pushed-anchors.mp4` (pushes the anchors too) | left untouched ("anchors do not agree on a step"), 44 backward steps on the software route | repaired, 0 |
| `p-run-clamped.mp4` (x264 CLI only, twelve P pictures opening every GOP) | 99 of 239 backward steps | 0 |

The repaired fixtures now demux to the healthy twin's timestamps, including the GOP whose keyframe the clamp pushed.

### Matroska with presentation slots in coding order

**The problem.** Matroska block timestamps are presentation timestamps by specification, and the format has no composition-offset table to lose. A writer that fills them packet by packet while the bitstream reorders pictures has therefore not lost anything: every presentation slot is still in the file. Each one just arrived attached to the picture that was *decoded* at that position rather than the one that is *displayed* there. On the reporting asset the first slots are 0, 40, 73, 107, 140, and the decoder emitted them as 0, 73, 107, 140, 40: one stepped-back presentation clock per mini-GOP for the length of the file. Measured through the engine's own software decoder on a generated twin, 15 of 30 frame times stepped backwards before the repair and 0 after (#511).

**The repair.** `H264MatroskaSlotPermutation` permutes rather than reconstructs: a picture carries the slot its own display rank owns, and the slot is read from the file instead of being computed.

- Nothing fits a cadence. A ladder quantized from a fractional frame rate is reproduced exactly rather than to within a tick, and a slot the writer clamped onto its cluster origin survives as written (the reporting asset has one, 7 ticks below the 1001/30 lattice its other 59 slots sit on).
- Decode timestamps do not move either. libavformat derives them from the rising slot ladder, which is the stream's real decode order, and a picture at most its own reorder delay behind its slot cannot violate `PTS >= DTS`.
- The container index is untouched for the same reason: it holds keyframe slots, and a keyframe is the first picture of its own sequence.

**Latency.** The slot a picture needs is a packet away, not a plan away. A picture coded ahead of the slot it owns waits for the packet carrying that slot, which is the mini-GOP reorder: three video packets on the reporting asset, in a 60-picture sequence. Nothing waits for the end of a sequence.

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

**Refusals.** Healthy nonzero offsets resume unchanged delivery. Fields, missing timestamps, incomplete POC, a rank claimed twice, arithmetic overflow and insufficient lead are not guessed at. **Every refusal hands the held packets back exactly as they arrived** and lets the rest of that sequence stream through, so a shape this policy does not own costs the repair and never the session. The next IDR is a fresh candidate. Seek and teardown release both unpublished input and pending output. No decoder-route or host-UI change is needed.

The uniform whole-file policy above is unchanged. Its strictly proven variable-cadence H.264 fallback reuses this same slot ladder.

See the [partial-composition regression and reproduction](partial-composition-regression.md) for generated fixtures, original numeric evidence and verification limits.

### A video sample whose NAL chain overruns it

**The problem.** A sample in an mp4 video track is a run of NAL units, each introduced by a big-endian length of the width the `avcC` / `hvcC` record declares, and a parser walks that run by addition. A damaged source can carry a length that reaches past the end of its own sample. The two consumers answer that differently:

- libavcodec logs `Invalid NAL unit size`, skips the frame and plays on.
- Apple's fMP4 parser answers the whole SEGMENT with `CoreMediaErrorDomain -19602`, which ends the session and every reload onto that segment.

So a file like that plays in mpv, plays after an MKVToolNix remux (which drops the unparsable tail), and dies here at whichever position AVPlayer first has to decode across the damaged sample.

**The fix.** The session muxer walks each video sample's chain before the write and cuts it at its last complete NAL, which gives the same bytes the remux would have written.

- A healthy sample is left alone.
- An Annex B payload is refused rather than walked as lengths.
- A sample with no complete unit at all is dropped instead of written empty.

The fixture generator `Scripts/nal-overrun-fixture.py` forges the shape into any length-prefixed source by rewriting four bytes, so the healthy original stands as the control arm (AE#561).

**Last rung: software takeover.** Some cases the cut cannot reach, and every recovery above it answers the same bytes again: the #93 revive reloads the item at the position that died, and the stage-2 chain refills the same segment. A segment AVPlayer refuses on its merits therefore ends the session, with the replacement item dying milliseconds after the first. So a failure in the CoreMedia domain is offered to `SoftwarePlaybackHost` before it is made terminal:

- The session is rebuilt at its playhead with `preferredDecodePath = .software`, which decodes with libavcodec (one skipped frame rather than a dead session) and reads the demuxer directly instead of the loopback HLS.
- Once per session, and only for a verdict on the MEDIA. A URL-loading failure is a verdict on the SOURCE, which both paths read through the same reader.
- Whether the software path can serve the source at all is the existing #461 `decodePathRefusal`, so a source it cannot serve costs a refusal and the original failure, not a second dead session.

## HDR routing

| Source | Wrapper signaling |
| --- | --- |
| H.264, HEVC (SDR) | BT.709 |
| HEVC Main10 (HDR10) | BT.2020 / PQ |
| HEVC Main10 (HDR10+) | BT.2020 / PQ + per-frame ST 2094-40 SEI stream-copied |
| HEVC Main10 (DV P5) | `dvh1` track type (DV-only, IPT-PQ base; forced even on SDR panels) |
| HEVC Main10 (DV P8.1 / P8.4 / P7) | `hvc1` primary + `dvvC` box (P7 converted to 8.1 first), DV engaged via `SUPPLEMENTAL-CODECS` on DV panels, RPU-driven tone map of the HDR10 / HLG base elsewhere |
| HEVC Main10 (HLG) | BT.2020 / HLG |
| AV1 HDR | BT.2020 / PQ |

AetherEngine does not tone-map on the host. It tells the system "this is BT.2020 PQ" (or DV, or HLG) through the HLS-fMP4 sample description, and AVPlayer and the system compositor map HDR to SDR as the connected display needs. tvOS / iOS pick the right path.

### When an HDR master is served

An HDR master playlist is only served when the panel is ready for it.

| Platform | Ready means |
| --- | --- |
| tvOS | The external panel is already in HDR mode, or Match Dynamic Range is on. An SDR-parked panel rejects an HDR master with `-11848`. |
| iOS | The built-in panel engages EDR on demand with no display mode switch, so `AVPlayer.eligibleForHDRPlayback` counts as readiness. SDR-only devices read ineligible and stay media-direct. |
| macOS | Same as iOS for readiness. See [the macOS capability table](#macos-capability-table) below. |

`DisplayCriteriaController` issues the HDMI content-frame-rate and dynamic-range hint via `AVDisplayManager` before the first segment is fetched, so the receiver-side handshake is in flight by the time `AVPlayer` is ready to render. (For why this ordering is mandatory on tvOS, see the README's "Host setup on tvOS" section.)

**Frame rate is required (#130).** An HDR master also needs a known source frame rate. AVPlayer filters a `VIDEO-RANGE=PQ`/`HLG` variant that carries no `FRAME-RATE` attribute out of the master at parse time, and fails the item with `-1002` without ever fetching the media playlist (SDR variants are accepted without it). The manifest frame rate uses the probe's `avg_frame_rate` with an `r_frame_rate` fallback. A source where both are unset (some live MPEG-TS ingests) routes media-direct instead of serving a master AVPlayer would provably reject.

#### Per-mode capability table

The per-mode capability split (HDR10, HLG, Dolby Vision) still comes from `AVPlayer.availableHDRModes`. The 26 SDKs deprecate it in favor of the eligibility Bool but ship no per-mode replacement, and the DV5 `-11868` guard needs exactly that distinction, so the engine keeps the deprecated read until Apple obsoletes it.

- **The table may only ADD a mode, never subtract one (since 6.82.0).** `supportsHDR10` and `supportsHLG` take `eligibleForHDRPlayback` as their floor, because the table under-reports HLG over HDMI. Measured on a Samsung whose EDID advertises Hybrid Log-Gamma and which plays HLG in the TV's own player, connected straight to an Apple TV: the table reported `.hlg` absent. A second Apple TV on a different Samsung agreed, and an iPhone 17 Pro on its built-in panel reported it present, so the absence is about the HDMI path rather than the panel (AE#459).
- **What that floor reaches is one source.** `effectiveVideoFormat` guards on Dolby Vision, so `supportsHLG` is consulted only for a DV Profile 8.4. That source previously resolved to SDR on such a display while the manifest served `VIDEO-RANGE=HLG`. A plain HLG title was never clamped.
- **Dolby Vision is left on the table alone.** There it is measured correct in both directions (`false` on a Samsung without it, `true` on an iPhone 17 Pro the same day).

#### macOS capability table

The per-mode read does not exist on macOS at all (`API_UNAVAILABLE(macos)`). The Mac table is derived from eligibility for HDR10 and HLG, and leaves Dolby Vision unclaimed: eligibility proves EDR, not that AVFoundation will accept a DV variant on this display.

A host that knows the hardware claims it with `LoadOptions.panelPresentsDolbyVision`. A wrong claim costs one in-place media-playlist fallback rather than the item (AE#493), for the failures AVPlayer reports as an item failure.

The claim no longer picks the packaging of a Profile 5, 8.1 or 8.4 source. 6.72.0 gave the non-DV branch its `dvcC` back and 6.73.0 its `SUPPLEMENTAL-CODECS`, so those three serve byte-identical manifests and segments with and without the claim. What changes is the published `videoFormat`, the criteria request and the HDR readiness that rides along. AV1 Dolby Vision is still gated on the claim. Profile 7 joined the three once it was converted on every display.

On tvOS that leaves a gap: the `-15628` an HDR10-only panel showed on the DV packaging in May 2026 (AE#4) is a stall rather than an item failure. It now reaches that panel with or without the claim, and it did not reproduce on tvOS 26.6. DV composition on a panel without Dolby Vision is what `forceDolbyVisionOnNonDVDisplay` is for there (AE#455).

#### Label upgrade from the item (macOS, AE#515)

The label can also be taken back from the item itself, where the platform has no capability table to clamp it against.

A Dolby Vision source on macOS resolves to `.hdr10`, because `supportsDolbyVision` cannot be claimed there without a host assertion. AVFoundation goes on playing the `dvh1` sample entry the engine served anyway. Measured with the assertion off on a 16" XDR, a Profile 5 and a Profile 8.1 grade of Dolby's reference content both strobe, so the RPU reaches the pixels with no claim set anywhere and the clamp was moving nothing but the label.

When the item's sample entry reads `dvh1` / `dvhe` and the probe agrees the source is Dolby Vision, the label is upgraded from `.hdr10` to `.dolbyVision` at `readyToPlay`. It is an upgrade and not a mirror of what AVFoundation parsed, for two reasons:

- An `.sdr` label is the clamp being right about a display presenting no HDR at all.
- On tvOS and iOS the per-mode table answers the capability question, so the label follows it rather than a sample entry that a Profile 5 master carries on every panel.

Profile 8.1 keeps `.hdr10` on macOS. It reports `hvc1` with the DV configuration alongside it, and it composes on that display all the same, but nothing in the stack reports that.

### Dynamic-range switch in parallel with the start (AE#348)

On a VOD load the dynamic-range switch and the session start run side by side.

- After an HDR or Dolby Vision criteria write, the pre-flight gate starts at the write, as before. Only the master-or-media choice waits for it.
- `HLSVideoEngine.prepare()` opens the source, plans the segments, starts the local server and starts the producer cutting the first segments while the panel is still switching.
- `serve(panelIsInHDRMode:)` picks the playlist once the gate has released and the panel has been read.

AVPlayer sees nothing before that, so the routing read happens no earlier than with the serial order, and a Dolby Vision write is never followed by a decode mid-switch. The cold start becomes roughly the longer of the switch and the segment production instead of their sum. On an Apple TV 4K with a Dolby Vision title whose first two segments took 2.0 s to cut, the serial order started playback 1.5 s after the switch had ended.

`start()` is still `prepare()` followed by `serve` with the panel state given at init. Live loads keep the serial order, since their join is timed against the edge and the overlap has not been measured there.

### HEVC CODECS string and parameter sets

**CODECS string.** Non-DV HEVC derives its primary `CODECS` string from the source `hvcC` profile_tier_level (profile space, profile, tier, level, constraint bytes), so an 8-bit Main source is not mis-declared as Main10. The compatibility-flags element is the stored `general_profile_compatibility_flags` in REVERSE bit order per RFC 6381 / ISO 14496-15 Annex E: a real Main10 record stores `0x20000000` and prints `hvc1.2.4...`, matching MP4Box and Dolby's own reference manifests. The declaration is checked against the init segment on device, so it has to be exact.

**Out-of-band parameter sets.** Whatever the profile, the `hvcC` shipped in `init.mp4` must carry the parameter sets out of band.

- Sources authored with in-band VPS/SPS/PPS only (`hev1`, `numOfArrays = 0`, which is what `MP4Box ...:xps_inband` and the common Dolby Vision MP4 recipes produce) are normalized at load: the engine scans the head of the stream for the parameter sets and rebuilds the record.
- A record that arrives with extra non-parameter-set arrays (libx265's user-data SEI) is stripped down to VPS/SPS/PPS.
- Shipping the source record verbatim in either case leaves AVPlayer with no usable format description: it buffers the whole forward window and never renders a frame.

H.264 gets the same rebuild (#938). An `avcC` with zero SPS or zero PPS (mkvmerge writes the 7-byte `01 64 00 20 ff e0 00` for such a track) is rebuilt from the first in-band SPS and PPS, by movenc so the High-profile extension comes out right, keeping the source's NAL length size. Shipped verbatim it fails differently from HEVC and more quietly: the item reaches `readyToPlay`, the clock runs and audio plays, and no frame is ever ready for display.

### Dolby Vision signaling

For DV streams the demuxer surfaces the source's `AVDOVIDecoderConfigurationRecord`. The route depends on the profile's base-layer compatibility.

| Profile | Base layer | Served as |
| --- | --- | --- |
| HEVC 5 | None (IPT-PQ) | `dvh1.05.<dvLevel>`, on every display |
| HEVC 8.1 / 8.4 | HDR10 / HLG | `hvc1` + `dvh1.08` in `SUPPLEMENTAL-CODECS`, on every display |
| HEVC 7 | HDR10 + enhancement layer | Converted to 8.1 (default), curve fold, or dual-layer composition |
| HEVC 8.2, AV1 10.2 | SDR Rec.709 | Plain base layer, no Dolby Vision |
| AV1 10.0 | None | `dav1.10.<dvLevel>` |
| AV1 10.1 / 10.4 | HDR10 / HLG | `av01` + `dav1.10` in `SUPPLEMENTAL-CODECS` |

#### Profile 5

Profile 5 (DV-only, IPT-PQ, no base layer) emits a bare `dvh1.05.<dvLevel>` codec tag in the primary `CODECS` attribute, with the `dvcC` box preserved.

`dvh1` is forced even on non-DV panels: AVPlayer's system DV decoder tone-maps IPT-PQ internally, and without `dvh1` the IPT chroma reads as YCbCr and shows a green / purple cast. So P5 on a non-DV panel is routed through a media playlist to avoid the `-11868` variant rejection.

#### Profiles 8.1 and 8.4

Profiles 8.1 / 8.4 (HDR10- / HLG-compatible base) emit `hvc1.2.4.L<level>` as the primary `CODECS` tag. The muxer writes the `dvvC` box, and the variant carries `dvh1.08.<dvLevel>/db1p` (8.1) or `/db4h` (8.4) in `SUPPLEMENTAL-CODECS`. That is what makes AVKit engage DV on a display that can present it.

Both are emitted on every display, not only a DV-capable one:

- The pairing is what the authoring spec asks for.
- It lets a client that does not know `dvh1` read the base layer instead of failing, and the loopback master reaches AirPlay receivers that are exactly that client.
- It makes AVPlayer put the RPU on the pixels wherever it has to convert the base layer, which on tvOS is every HDR source while the panel is not in HDR mode.

It used to be stripped, because of an `-11868` measured on tvOS 26.0 that no longer reproduces on 26.6. On a panel that is already in HDR, the base layer plays as plain HDR10 / HLG either way (AE#493).

#### Profile 8.1 on a non-DV display: `forceDolbyVisionOnNonDVDisplay`

With `LoadOptions.forceDolbyVisionOnNonDVDisplay` (experimental, default off, AE#455), Profile 8.1 on a non-DV display is served the way Profile 5 is: `dvh1` sample entry, the container `dvcC` rewritten to profile 5 / compatibility 0, `CODECS="dvh1.05.<dvLevel>"`, no supplemental.

- **What it buys.** AVPlayer then runs its own Dolby Vision composition and applies the per-frame RPU to the pixels before they leave the device. The default route gives the panel one static HDR10 grade.
- **Why it works.** The bitstream never changes, only the container's claim about it. A Profile 8.1 RPU already carries the mapping out of its own HDR10 base layer, so the composer does not need the container to describe that layer.
- **Why it is experimental.** This is not what the profile field means. A decoder that read the base layer's colorimetry from the profile rather than from the RPU would decode IPT out of YCbCr: the green / violet cast of #4 and #176.
- **Scope.** Profile 8.1, and Profile 7 once converted to it. Profile 8.4's base layer is HLG, and a profile-5 `dvcC` over an HLG `colr` is a container that contradicts itself.

#### Base layer only: `dolbyVisionHandling = .baseLayerOnly`

With `LoadOptions.dolbyVisionHandling = .baseLayerOnly`, any profile with a presentable base layer is served as that base layer alone, on every display: plain `hvc1` / `av01` sample entry, the `dvcC` stripped, no supplemental, no Profile 7 conversion, and HDR10 / HLG display criteria rather than `dvh1`. The RPU NAL units stay in the samples and are ignored.

**Why it is a host option and not a routing decision.** The case it exists for cannot be told from the container: a remux whose container record claims Profile 5 over a bitstream whose VUI declares BT.2020 YCbCr PQ, whose RPU carries the NLQ and residual fields only Profile 7 has, whose mapping is the identity, and whose base layer is plain HDR10 with its own static metadata. Served as `dvh1.05`, the decoder reads YCbCr as IPT and the picture is green / violet. Served as its base layer, it is the HDR10 every player that ignores the record shows. The engine logs the contradiction on the default route (`DV Profile 5 record over a BT.2020 YCbCr VUI`) so a host knows to offer the option.

**What is admitted:**

- HEVC Profile 7 / 8.1 / 8.4 and AV1 Profile 10.1 / 10.4, whose record names the base.
- A Profile 5 / AV1 10.0 record whose VUI names one (`matrix_coeffs` BT.2020 with a PQ or HLG transfer). A genuine Profile 5 leaves both unspecified, IPT having no VUI code point.

A Profile 5 whose VUI is unspecified has no base layer to present and keeps its route.

#### A Profile 5 record its own RPU contradicts (#532)

Served as what the RPU says, on every display, with no option to set.

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

#### A Profile 5 the container never recorded (`AE#recordless`)

Given the record it should have carried. Some Matroska releases are Profile 5 with the `BlockAdditionMapping` dropped and a VUI that says nothing, so the source loaded as plain SDR and the IPT picture was decoded as YCbCr.

**When it applies.** HEVC 10-bit 4:2:0 with no Dolby Vision record and `color_trc`, `color_space` and `color_primaries` all unspecified. For that pairing only, the demuxer reads the first RPU from a second open at the end of its probe.

**What happens.** If libdovi's `guessed_profile` says 5, the demuxer appends an `AV_PKT_DATA_DOVI_CONF` (profile 5, level 6, rpu 1, el 0, bl 1, compatibility 0) to the stream's `coded_side_data`. Because it lives on the demuxed stream, the load, the HLS producer's own open, display criteria, the segment muxer's `dvcC` and every reload see a genuine Profile 5 record: `dvh1` sample entry, `CODECS="dvh1.05.06"`, `VIDEO-RANGE=PQ`, and the #176 software-path refusal.

It is served the way a recorded Profile 5 is, including the `colr nclx` repair: the gate is an unspecified VUI, which is the shape that repair exists for, and the same bytes cannot have two deliveries depending on what the container wrote down.

**Limits.**

- A failed read, or an RPU that reads anything else, leaves the source as it was.
- `.url` sources only (a custom reader has no second open). Live is skipped.
- `LoadOptions.dolbyVisionHandling = .baseLayerOnly` is unaffected, because a record with compatibility 0 has no base layer to present.

#### AV1 Dolby Vision

AV1+DV follows the same split as HEVC:

- **Profile 10.0** (DV-only, no base layer to fall back to) emits a bare `dav1.10.<dvLevel>` primary.
- **Profile 10.1** (HDR10-compatible base) emits an `av01...` primary plus `dav1.10.<dvLevel>/db1p` in the supplemental entry, with `VIDEO-RANGE=PQ`.
- **Profile 10.4** (HLG-compatible base) emits an `av01...` primary plus `dav1.10.<dvLevel>/db4h`, with `VIDEO-RANGE=HLG`.

The cross-compatible profiles are signaled this way on hardware-AV1 hosts. The `dav1` sample entry belongs to the profile without a base layer, the way `dvh1` belongs to Profile 5. A cross-compatible profile carries its base layer's own sample entry, so a client that cannot read Dolby Vision still plays it.

**AV1 Profile 10.1 on the software host** gets its Dolby Vision from the engine rather than from AVFoundation. AVFoundation ignores the RPU an AV1 stream carries in its ITU-T T.35 metadata OBU and shows the HDR10 base layer.

- The RPU of a 10.1 stream is the RPU of an HEVC 8.1 stream in another wrapper. The decoder reads it out of each temporal unit, libdovi rewraps it into the `unspec62` form VideoToolbox attaches to an HEVC 8.1 frame, and the decoded frame carries it under the same two keys, on the buffer and on its IOSurface (`DoviDisplayMetadata`). The system's Dolby Vision display management applies it.
- dav1d attaches it where AV1 has no hardware decode (every Apple TV, M1 / M2 Macs, pre-A17-Pro iPhones), which is where AV1 plays on the software host anyway.
- Where VideoToolbox decodes AV1 and the host loads with `LoadOptions.preferredDecodePath = .software`, `HardwareVideoDecoder` decodes it and hands out each frame as a copy in a pool of its own. On VideoToolbox's own output buffer the attachment never reached the panel.
- Measured with a pulse clip (constant pixels under an RPU that alternates): it pulses on an Apple TV 4K (3rd generation, tvOS 27) into an LG CX, and on macOS 27 (M5 Pro), where it composites to within 0.0001 PQ of the same RPU played as HEVC 8.1 through AVPlayer. A null-RPU clip stays steady.
- Profile 10.0 (no base layer) and 10.4 (its HLG base is unmeasured) keep the plain path.

#### Profile 7

Profile 7 (dual-layer, the common UHD Blu-ray remux profile) is handled according to `LoadOptions.preferDualLayerDolbyVision` (default `false`: dual-layer composition is opt-in) and `LoadOptions.dolbyVisionHandling`. The dual-layer composer is an optional component, compiled only with the `DualLayerDolbyVision` package trait (off by default, [Installation › Optional components](installation.md#optional-components)). Built without it, `preferDualLayerDolbyVision` changes nothing and every Profile 7 source takes the single-layer conversion.

| Route | When |
| --- | --- |
| Dual-layer composition | `DualLayerDolbyVision` trait, `preferDualLayerDolbyVision = true`, `dolbyVisionHandling` `.automatic`, `el_type` FEL, VideoToolbox HEVC hardware decode |
| Curve fold | `DolbyVisionFelCurves` trait, FEL, the native route |
| Single-layer conversion (default) | `preferDualLayerDolbyVision = false`, a build without the `DualLayerDolbyVision` trait, or no VideoToolbox HEVC hardware decode |

**Dual-layer composition.** Profile 7 routes through `SoftwarePlaybackHost` + `DualLayerVideoDecoder`.

- Each packet is split into the 4K base layer (BL), the enhancement layer (EL, typically 1080p, carried in `unspec63` NAL units) and the RPU (`unspec62`).
- Both layers decode in their own `VTDecompressionSession`. `DoviFelComposer` applies the RPU's reshaping (polynomial luma, MMR chroma) and the inverse-NLQ residual from the upsampled EL at 12-bit precision. An ordered 8×8 Bayer dither (inverted on odd frames) then takes the result to 10-bit P010 for `AVSampleBufferDisplayLayer`.
- The composed frame also carries the RPU converted to Profile 8.1 as a `DolbyVisionRPUData` attachment, with `DolbyCompatibilityID` set to the string `"1"`. tvOS 27 reads it on every frame and applies Dolby Vision display management, so L1 / L2 dynamic metadata reaches the panel.
- A MEL source never reaches the dual-layer decoder. The route is FEL only; MEL (nothing to compose) keeps the native route.
- The route needs a seekable VOD and is logged once per Profile 7 load (`DV P7 dual-layer route: taken` / `not taken (<reason>)`).
- It does not consult the display. On a display that does not take Dolby Vision the route is still taken, and the composed picture is presented with its attached metadata, tvOS deciding how. The native route would have played the converted Profile 8.1 there.
- The software host plays an E-AC-3 Atmos track as its channel-bed core (no objects) unless `objectAudioRendering` is set, which keeps the objects (compressed JOC to the renderer, TrueHD Atmos and DTS:X as APAC, in a build with the object-audio traits).
- The stream is classified by `el_type` alone. An RPU that sets `disable_residual_flag` only switches the residual off for that frame and never changes the classification.

See [dolby-vision-fel.md](dolby-vision-fel.md) for the design.

**Curve fold.** The single-layer conversion below, with two differences:

- The FEL RPU's mapping is kept (mode 1, then mode 2), so the disc's luma polynomial and MMR chroma reach the platform decoder, which applies them.
- The enhancement layer's luma residual, measured on the first picture of each scene, is added to every frame's luma polynomial. The engine holds back one GOP to do so and never evaluates the mapping on a pixel.

This is the recommended way to bring a FEL source's enhancement layer back in a distributed app. The dual-layer composition above evaluates the MMR prediction and the residual itself. See [Dolby Vision FEL › Curve fold](dolby-vision-fel.md#7-curve-fold-on-the-native-route).

**Single-layer conversion (the default).** No Apple platform has a Profile 7 decoder, so the engine converts the stream to single-layer **Profile 8.1** live during muxing:

- The RPU of each video packet is rewritten with [libdovi](https://github.com/superuser404notfound/LibDovi) (`dovi_convert_rpu_with_mode`, mode 2, the same transform as `dovi_tool -m 2`).
- The enhancement-layer NALs are dropped, and the container `dvvC` is set to Profile 8.1.
- The conversion runs on every display, and the result is served exactly as a Profile 8.1 is. On a DV-capable display this means real Dolby Vision (`dvh1.08/db1p` supplemental) instead of the plain HDR10 base. On a display without Dolby Vision, the kept `dvvC` lets AVPlayer tone-map from the RPU rather than from the base layer's static metadata, the way mpv plays Profile 7 without an EL decoder.
- It used to skip the conversion and strip the record there, which cost every Mac (no per-mode table) and every HDR10 / SDR panel the RPU, and shipped the enhancement layer into segments nothing decodes.
- The conversion is loss-free relative to what Apple could show before (the enhancement layer was never decodable on Apple hardware). MEL and FEL sources are both handled. A Full Enhancement Layer (FEL) source is logged, since its enhancement layer, which a native Profile 7 player would fold in, is discarded on this route (the dual-layer route above keeps it). A Minimal (MEL) source loses nothing.
- Any per-packet conversion failure drops that RPU, so the frame degrades to the clean HDR10 base rather than shipping a Profile 7 RPU inside a container already declared 8.1.
- A session that converts publishes `dolbyVisionConversion = .profile7ToProfile81`, so a host label can name the profile actually served next to `sourceDVProfile`.

#### SDR-compatible-base profiles

HEVC **Profile 8.2** and AV1 **Profile 10.2** carry a Rec.709 base layer that no Apple platform has a DV decoder for. The engine strips the `dvcC` / DV config and plays the base as plain `hvc1` / `av01` (logging `not DV-routable, playing Rec.709 base`). There is no Dolby Vision on any display for these, on DV panels and SDR panels alike.

### HDR10+ dynamic metadata

ST 2094-40 metadata stays attached to the HEVC bitstream as user-data-registered ITU-T T.35 SEI NALs. The HLS-fMP4 stream copy preserves the SEI through to `AVPlayer`, which forwards it to the system compositor. HDR10+-capable TVs apply the per-scene tone-mapping curves. HDR10-only TVs fall back to the static HDR10 base.

**The `videoFormat` label.** The published `videoFormat` starts at `.hdr10` for any BT.2020 / PQ source, and flips to `.hdr10Plus` the first time the producer validates a packet's HDR10+ metadata.

- That includes a Dolby Vision source carrying an HDR10+ layer next to its RPU (Blu-ray Profile 7 does, and so does a Profile 8.1 remuxed from one), whenever the label resolved to its HDR10 base. `sourceVideoFormat` keeps saying `.dolbyVision`.
- The evidence is latched per session, so a label republished later by the panel proof (AE#459) keeps it.
- It is debounced across producer restarts, so a scrub does not re-fire it.
- Hosts can drive an HDR10+ badge or analytics hook off the `$videoFormat` transition.

**The metadata probe.** The same structural validator serves the opt-in metadata probe. Codec metadata framing, registered T.35 identifiers and the complete ST 2094-40 payload must be valid. A matching byte sequence inside compressed picture data is not metadata. FFmpeg's parsed HDR10+ packet side data remains another supported carriage, including VP9/AV1 Matroska. No video decoder is opened just to inspect HEVC metadata. Probe confirmation sets `SourceProbe.carriesHDR10PlusMetadata` independently of the primary format, preserving `.dolbyVision`. See [whole-probe limits and cancellation](api.md#whole-probe-limits-and-cancellation) for bounded source reads. Absence of confirmation is not proof of absence, and says nothing about the connected display.

### HDR Vivid (CUVA) dynamic metadata

HDR Vivid (CUVA T/UWA 005.1) is built to be backward compatible: the base layer is plain HLG or PQ in BT.2020, and its dynamic metadata is an optional registered T.35 SEI on top (country 0x26, provider 0x0004, oriented code 0x0005).

- The engine plays that base exactly like any HLG or HDR10 source, and the SEI is stream-copied with the rest of the bitstream.
- No Apple platform applies it. A display without Vivid support shows the static base, which is the format's intended fallback.
- There is no host-side tone mapping: the native route has no pixel stage, tvOS gives an app no EDR or panel-peak reading to map against, and the TV maps the HDR signal itself (#699).

**Probing.** `probe(url:detecting: .hdrVivid)` reports carriage as `SourceProbe.carriesHDRVividMetadata`, in the same packet pass and budget as `.hdr10Plus`. libavcodec's CUVA parser is internal, so `HDRVividMetadataScan` walks the body with the same field widths. It only counts a message whose `system_start_code` is one of the defined 1 to 7, whose fields are all present, and whose bits after the last field are zero. HEVC only, as in libavcodec. `videoFormat` stays `.hlg` / `.hdr10`.

## Audio

| | |
| --- | --- |
| Stream-copy (lossless into fMP4) | AAC-LC, AC3, EAC3, FLAC, ALAC. See the exceptions below. |
| Bridged (`AudioBridge`) | TrueHD, MLP, DTS, DTS-HD MA, MP3, MP2, Opus, Vorbis, PCM (raw shapes plus G.711 A-law / mu-law and DVD LPCM), WMA (Standard, Pro, Lossless, Voice), the Flash tail Nellymoser Asao / ADPCM-SWF / Speex, RealAudio (Cook, ATRAC3, Sipro, Lossless, 14.4 / 28.8) and AMR-NB / AMR-WB: decoded to PCM and re-encoded |
| Surround | 5.1 / 7.1 with correct `AudioChannelLayout` preserved through the wrapper |

Stream-copy exceptions:

- **HE-AAC / HE-AACv2** stream-copy when the source carries an AudioSpecificConfig (any movie container), and bridge only without one (live ADTS / MPEG-TS, where a synthesized ASC would mis-signal SBR).
- **LATM/LOAS-framed AAC** (DVB broadcast framing) always bridges.
- **FLAC whose `STREAMINFO` `min_blocksize` is below 192** bridges too (AE#764). CoreMedia drops a track that declares less, and hangs on frames smaller than the field claims, so such a stream cannot be copied (the bridge is bit-perfect for FLAC).
- **Audio-only FLAC.** The same `min_blocksize` field sends an audio-only FLAC to the FFmpeg host instead of AVPlayer. So does any audio-only FLAC in the raw `flac` container, whose seeks CoreMedia misplaces (AE#946).

### Audio bridge modes

Non-streamable codecs route through `AudioBridge` in one of two modes (`LoadOptions.audioBridgeMode`):

| Mode | Encoder | Needs | Notes |
| --- | --- | --- | --- |
| `.surroundCompat` (default) | Chosen per source: EAC3 above two channels, FLAC for two or fewer | Any AVR or soundbar, including legacy ARC | Caps 7.1 to 5.1 |
| `.lossless` (opt-in) | FLAC up to 7.1 | A sink that takes multichannel LPCM | Bit-perfect, also at 96 and 192 kHz |

- **`.surroundCompat`** (default): the encoder is chosen per source, not per mode. A source with more than two channels is re-encoded to lossy EAC3 at 128 kbps per channel (768 kbps 5.1). AVPlayer hands the encoded bitstream to HDMI and the sink decodes its own 5.1 mix, so surround works on essentially every AVR and soundbar, including one behind legacy ARC. Two channels or fewer have no surround to carry and take the FLAC encoder instead. That is lossless where EAC3 would have been 256 kbps lossy, and the route decodes it to LPCM on routes that can only pass a Dolby bitstream through. (AE#395: an AirPlay 2 optical adapter played one MPEG-TS program's stream-copied AC3 5.1 and was silent on the bridged EAC3 stereo of the same program, so which track `av_find_best_stream` happened to pick decided whether the viewer heard anything.)
- **`.lossless`** (opt-in): FLAC up to 7.1 lossless, which AVPlayer decodes to LPCM. It needs a sink that takes multichannel LPCM: an AVR over HDMI, or an AVR or soundbar on eARC. A Sonos Arc on eARC takes 6-channel LPCM, so a 7.1 source arrives there as lossless 5.1, folded by tvOS. Behind legacy ARC, which carries stereo LPCM or a Dolby bitstream only, the LPCM is downmixed to stereo, and `.surroundCompat` is the right mode.

**The host picks the mode (AE#794).** The engine does not pick between the two from the route. With tvOS's Continuous Audio Connection on, every HDMI route reports 32 unlabelled channels whatever the sink takes. An eARC soundbar and a legacy-ARC one look the same, and a wrong FLAC pick on the second plays stereo.

`.surroundCompat` is the default because the soundbar / basic-AVR install base is the majority.

**Sample rates (AE#548).** Either encoder opens at a sample rate it actually supports, which is not always the source's.

- E-AC-3 exists at 32 / 44.1 / 48 kHz only, so a 96 kHz TrueHD or DTS-HD master is resampled to 48 kHz on the `.surroundCompat` arm. Opening the encoder at the source rate instead made `avcodec_open2` refuse the context and took the whole session to silent video-only.
- The rates come from `avcodec_get_supported_config`, so an FFmpeg bump that widens them needs no change here.
- An encoder that advertises no list (FLAC) keeps the source rate untouched. That is what keeps `.lossless` bit-perfect at 96 and 192 kHz.
- The resampler is in the path on every bridged packet either way, so the conversion costs nothing that was not already being paid.

**Object metadata.** Object metadata (TrueHD Atmos objects, DTS:X heights) is lost in either mode: FFmpeg's EAC3 encoder does not produce JOC, and FLAC has no object-channel concept. `objectAudioRendering` is the route that keeps it, in a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default, [Installation › Optional components](installation.md#optional-components)), rendered into a speaker bed and delivered as APAC ([TrueHD Atmos with heights](#truehd-atmos-with-heights)). If a JOC source ever falls through to the bridge, the engine logs a loud `WARNING: Atmos downgrade, ...`.

### Bridge lifecycle (#99)

Two invariants:

- **Shared timeline.** The encoder PTS counter re-bases onto the first fed packet's (gate-shifted) source PTS on every session start and producer restart. Bridged audio therefore always shares the video's output timeline, including a `load(startPosition:)` resume that anchors mid-file. (A 0-based bridge timeline puts the audio track a full resume offset away from video inside the same fragments, which AVPlayer silently discards.)
- **Encoder rebuild after EOF.** The EOF tail flush leaves the encoder in FFmpeg's terminal draining state, so the bridge latches that and rebuilds the encoder on the next restart. A VOD pump that still dies with `muxerFailed` gets a bounded producer rebuild instead of stranding the session.

### Audio that ends before the picture (AE#847)

AVPlayer ends a muxed HLS item the moment its audio runs out, however much video is left, and a re-seek in place does not get past it. Measured on a 60 s HEVC track over 35 s of AC-3, both from the engine's loopback and from a plain ffmpeg fMP4 playlist. A gap in the audio is harmless: with audio at 0-35 s and 59-60 s the same item plays to 59.99 s, also from a start inside the gap.

**The fix (`AudioTailPadding`).** When the producer reaches the end of the file and the audio it wrote stops more than half a second short of the video, the final segment gets silence up to the end of the picture. The silence starts where the audio stopped, or at the segment's own start if the audio stopped earlier, and is written in whole frames of the delivered codec.

- **Padded:** AC-3, E-AC-3 and FLAC always; AAC-LC and ALAC since FFmpegBuild 3.10.0 (the encoders come from the FFmpeg build).
- **Not padded:** HE-AAC, MP3, Opus and a stand-in sample entry (the APAC bed). These log `AE#847 audio tail not padded` with the reason.
- **Limit.** The fill exists only in the segment written at end of file. On a source that arrives barely faster than its bitrate, with a silent tail longer than the producer's lead, AVPlayer waits at the end of the audio until that segment exists, and then plays on.

### Audio shaping

`LoadOptions.audioShaping` / `setAudioShaping(_:)` (AE#923) shape the decoded PCM before it is re-encoded (loopback) or rendered (software host, FFmpeg audio-only host). Three settings, in any combination:

| Setting | Field | What it does |
| --- | --- | --- |
| Channel cap | `maxChannels` | Folds the source to at most that many channels |
| Dialogue lift | `dialogueGainDB` | Raises dialogue, up to 12 dB |
| Night mode | `compressor` | Compresses dynamics |

**Channel cap (`maxChannels`).** The source is folded to at most that many channels with libswresample's own downmix (centre and surrounds at -3 dB, LFE dropped), the same fold the route would otherwise make. A cap decides the bridge encoder as a source with that many channels would, so a 5.1 source capped to stereo is FLAC, not stereo E-AC-3. A source is never upmixed.

**Dialogue lift (`dialogueGainDB`, up to 12 dB).**

- **Source with a front centre.** The centre is raised wherever it lands, discrete or folded, in the remix matrix (no cost per sample). Measured on a 5.1 fixture with a tone on the centre only and another tone on every other channel, folded to stereo: 3, 6 and 9 dB asked move the centre tone 3.0, 6.0 and 9.0 dB against the other, on the bridge and on the software decoder alike.
- **Source without a centre that plays as stereo.** The dialogue is extracted by libavfilter's `dialoguenhance` and folded back onto both sides with `pan`. On a stereo fixture of a centred, gated 1 kHz tone over noise that differs between the sides, 3, 6 and 9 dB asked raise the tone 3.9, 7.4 and 10.6 dB against the noise.
- **Why `dialoguenhance`.** It was chosen over a mid/side lift after measuring both on a mix of centred speech and wide music: at +6 dB the mid/side lift gained 2.0 dB against the wide music, `dialoguenhance` 5.1 to 7.2 dB. Neither separates speech from music mixed to the centre itself (0 to 1.2 dB), which no stereo method can.
- A mono source is left alone.

**Night mode (`compressor`).** libavfilter's `acompressor`, peak detection, one gain for all channels so the image does not move. The `night` preset compresses everything above -30 dBFS 4:1 and adds 10 dB. Measured on a steady 1 kHz tone: 0 dBFS in comes out at -12.2 dBFS, -20 at -17.2, -40 at -30.0.

**Limiter.** Whenever shaping is active, libavfilter's `alimiter` runs last, at -1 dBFS with a 5 ms lookahead and its own latency compensation. That is what lets the fold stay unnormalized (normalizing a 5.1 fold costs 7.6 dB of level, the opposite of what someone who cannot hear the dialogue asked for) and lets the makeup gain be generous. It replaced an instant-attack limiter after a measurement: on a steady overload its THD was -155 dB against -48.6, and on two tones under limiting bass hits its splatter above 3 kHz was -67 dB against -42 (relative to the tones), at the input's own floor.

**Timing.** `dialoguenhance` delays its content by three quarters of its FFT window (1536 samples at 48 kHz, 3072 at 96 kHz) and stamps its output with its input's timestamps regardless. The engine therefore runs the graph on a sample counter of its own, drops the delay's priming, pushes the same number of silent samples at the end of the stream and carries the timestamps itself, so output sample k is input sample k. Measured: an impulse at sample 60000 of a stereo source comes out of the bridge at sample 60000 with 96000 samples in and out, and the software decoder presents it at 1.25000 s, its source time.

**Requirements.** The graph (`AudioShapingGraph`) needs FFmpegBuild 3.11.0 or later, which adds `abuffer`, `abuffersink`, `aformat`, `aresample`, `pan`, `dialoguenhance`, `acompressor` and `alimiter`. Where it cannot be built, the remix still applies and the log says the dynamics do not.

**What it costs.** Shaping needs PCM.

- While it is active, a stream-copied track is decoded and bridged, so Atmos (E-AC-3 JOC) and every bitstream that used to pass through arrive as their channel bed.
- On the software host the compressed E-AC-3 JOC route and the object render are skipped.
- Turning shaping off goes back to stream copy.
- Where AVPlayer owns the audio (`.remoteBypass`, the native audio-only host) there is no PCM to shape, and `$audioShapingState` reads `.unavailable`.

### Audio a build has no decoder for

AC-4 (ATSC 3.0 / NextGen TV) and MPEG-H 3D Audio have no decoder in the bundled FFmpeg, and there is nothing to switch on.

- FFmpeg carries codec ids for both so a container can be demuxed, but `libavcodec/allcodecs.c` names neither.
- The AC-4 decoder patches have sat out of tree for years, and the format is Dolby patent-encumbered.
- MPEG-H has an upstream wrapper around Fraunhofer's `mpeghdec`, whose licence is not LGPL-redistributable.
- Apple's own stack does not fill the gap either: there is no AC-4 format constant in CoreAudio.

**Such a track is expensive, not just silent.** `has_codec_parameters` fails an audio stream with no sample rate, and that value can only come from the container or from opening a decoder. So `find_stream_info` reads to the full probe budget before failing open with the track missing anyway. On a live source that budget is spent at the wire rate, which is where Sodalite#100's minute-long tuning indicator came from.

**What the engine does.** The demuxer parks a stream whose codec has no decoder AND whose parameters the container left unset out of the probe's way, and restores it immediately after. The open then costs what it would have without the track, and the caller still sees the track in `audioTracks`. A host with its own metadata can do better still and refuse the channel with a real sentence (Jellyfin names a live channel's audio codec in PlaybackInfo without opening a tuner).

### Track language on the native path

AVFoundation reads a track's language from the master playlist, not from the media. So the engine also declares the audio it muxes into its single variant there: one URI-less `EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="<iso 639-2/T>",DEFAULT=YES,AUTOSELECT=YES` plus `AUDIO="aud"` on the variant (RFC 8216 4.3.4.2.1; the URI is absent precisely because the audio is inside the variant). AVPlayer then exposes it as a one-option audible `AVMediaSelection` group and labels it from `LANGUAGE`, which is what a system audio menu shows.

Measured on macOS 26: the same fMP4 whose audio `mdhd` reads `deu` reports `AVAssetTrack.languageCode == nil` and no audible group at all when the master does not declare the rendition, while the identical `mdhd` read from a progressive `.mp4` reports `deu`. The `mdhd` is written too (the track is that language whoever reads it), it is just not where the label comes from.

The rendition is advertised only when the audio actually reached the variant, so an audio cascade that fell through to video-only never names a group its segments do not carry (AE#458).

**Resolving source labels.** Source labels are resolved to ISO 639-2/T in these steps:

1. **ICU.** Covers every language ICU knows plus BCP-47 subtags (`pt-BR` becomes `por`), and rejects free text such as `English` or a track title.
2. **A twenty-row table** in front of ICU, for the ISO 639-2/B bibliographic codes ICU does not resolve and Matroska routinely writes (`ger`, `fre`, `cze`).
3. **ISO 639-3 members CLDR aliases to a macrolanguage** (`cmn`, `arb`, `pes`, `swh`, `uzn`, `kmr`) have no alpha3 entry at all. The tag is canonicalized where the direct route came back empty, which resolves the alias without moving any tag that already resolved (`no` stays `nor`, not `nob`).
4. **ISO 639-3 members CLDR does NOT alias** (`cnr`, `prs`, `npi`, `ory`, `quz`, `crs` and 50 more, 56 measured on macOS 26) have neither an alpha3 entry nor a canonical form, and there is nothing to convert: the tag already IS the ISO 639 code, so it passes through as itself. That step is gated on ICU having a display NAME for the tag in a fixed reference locale, which is the validity signal canonicalization cannot give (`canonicalLanguageIdentifier` echoes `dub` and `xyz` back unchanged exactly as it echoes `cnr`). The locale is fixed rather than the device's, or a file would resolve on an English Apple TV and not on a German one.

A label that resolves to nothing writes nothing, so an untagged source keeps the master it had before. The one exception is a stream-copied E-AC-3 JOC track (AE#726, next section), which gets a rendition without `LANGUAGE` because its `CHANNELS` has nowhere else to go.

### Dolby Atmos

EAC3+JOC packets are stream-copied through the muxer untouched, on every output route.

AVPlayer reads the segment and recognises JOC from the `dec3` box's ETSI TS 103 420 extension (`flag_ec3_extension_type_a = 1` followed by `complexity_index_type_a`, the object count), with the height channels a dependent substream adds named by that substream's `chan_loc` bits. It then lets the downstream renderer decide:

| Output | Result |
| --- | --- |
| HDMI | Tunnels out as Dolby MAT 2.0, the AVR lights up the Atmos indicator |
| AirPods | Renders spatially |
| Plain Bluetooth A2DP / LE | Downmixes the bed channels to stereo natively |

The route never changes the engine's decision. A JOC track is signaled in the playlist as `ec-3`, the same CODECS string as a non-JOC EAC3 5.1 track, so AVPlayer accepts it everywhere and the bitstream is never re-encoded for a route reason. The engine emits an explicit `[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged; ...` diagnostic on every Atmos session.

**`CHANNELS` on the audio rendition.** `CODECS` cannot carry the distinction. A JOC track is signaled `ec-3`, the same string a non-JOC E-AC-3 5.1 track gets (#34: never `ec+3`, which tvOS 26.5 refuses), so that attribute says nothing about objects either way, and the `dec3` box sits a layer below the playlist. The master's `EXT-X-MEDIA:TYPE=AUDIO` tag therefore carries `CHANNELS`. Apple's HLS Authoring Specification makes it required on every audio rendition, and Dolby's DD+ Online Delivery Kit defines it for object audio as the count of decodable objects, a slash, then `JOC`.

- The engine writes `CHANNELS="16/JOC"` for a stream-copied E-AC-3 JOC rendition, and the plain served channel count otherwise (`CHANNELS="6"` for a 5.1 bed).
- A source whose audio never reached the variant advertises no rendition, and so gets no attribute.
- **Untagged JOC (AE#726).** An untagged JOC stream copy still gets a rendition: `NAME="Dolby Atmos"`, no `LANGUAGE`, `CHANNELS="16/JOC"`. That rendition forces the master on an SDR source the same way a language does. AVFoundation lists it as one audible option named "Unknown" (measured on macOS against Dolby's untagged JOC test signal), where the tag-less master before built no audible group at all. An untagged track that is not object audio still gets no rendition, so no other untagged source changes route.

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

The box then describes a bare 5.1 bed, and an Atmos receiver reports multichannel PCM (AE#728). FFmpegBuild's `patch_ffmpeg_eac3_dec3` fixes both in the muxer. Measured on a 5.1.2 source with `chanmap = 0xA010`, the payload goes from `14 00 0C 0F 02 00` to `14 00 0C 0F 02 40 01 10` (`chan_loc` `0x040` is Lvh/Rvh; `01 10` states the extension and 16 objects). A track whose objects sit in the independent substream already got a correct box and is unchanged.

### TrueHD Atmos with heights

**The problem.** Apple TV cannot bitstream TrueHD, and no Apple platform hands a third-party app a compressed bitstream output. So the audio bridge decodes a TrueHD track and re-encodes its 7.1 channel presentation (`audioBridgeMode`). For TrueHD Atmos that loses every height and every object position before the audio leaves the engine.

**The option.** `LoadOptions.objectAudioRendering = .apac(layout)` keeps them (AetherEngine#731). The engine builds the `SpatialSpeakerLayout` bed the host names (5.1.2, 5.1.4, 7.1.2, 7.1.4 or 9.1.6, as `SpatialSpeaker` positions in CoreAudio's channel order) out of the stream's own lossless 7.1 (or 5.1) presentation, steered by its Atmos object presentation (see [How the bed is built](#how-the-bed-is-built)), and hands that bed to the system. tvOS sends it to an Atmos receiver or soundbar as Dolby MAT, the same way it delivers its own spatial content. iOS plays it as Spatial Audio.

**Why it is opt-in.** It is a trade: the rendered bed, PCM or lossy APAC at several Mbit/s, in place of the lossless 7.1 the channel bridge delivers.

- It applies only to TrueHD that FFmpeg marks as Atmos, at 48 kHz, on OS 26 or later. Anything else, and any failure to start, keeps `audioBridgeMode` with the audio intact.
- The decoder and the bed regression are an optional component, compiled only with the `TrueHDObjectAudio` package trait, off by default. Built without it, TrueHD Atmos keeps the channel bridge whatever the option asks, and the session log says so ([Installation › Optional components](installation.md#optional-components)).
- Silo built the first implementation in its fork, an exact object render that this path replaced.

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

The object presentation is decoded without matrix interpolation. LibTrueHD 3.2.0 leaves the interpolating decode out of its binary and the engine's handle discards the values too, so on a stream that interpolates (a mix with moving objects; static mixes do not) the element signals are approximate. They never reach an output.

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
- An explicit `audioSourceStreamIndexOverride` still wins.

Without this, a film carrying DTS-HD and TrueHD Atmos in one language usually opened on whichever the container listed first.

#### Atmos on the receiver (tvOS)

tvOS sends APAC over HDMI as Dolby MAT, and some sinks show Dolby Atmos for it on their own, but not all. A Samsung HW-Q990C soundbar fed by an Apple TV 4K (tvOS 27.2) played APAC without ever showing Atmos, although `AVAudioSession` reported a MAT format throughout.

**`AtmosOutputActivator`.** While a rendered session plays (TrueHD Atmos or DTS:X, as APAC or as PCM), the engine loops a silent E-AC-3 stream signalled as Dolby Atmos on a second, unmuted player. On the same setup that brought the soundbar to Atmos before the first frame and kept it there across a seek. Nothing the app can read (`AVAudioSession`'s output format or channel count) tracked the indicator, so only the sink can confirm it.

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

**Pipelined encode (`APACEncodePipeline`).** Apple's encoder runs on one thread, so the bridge hands each rendered 2048-frame chunk to a serial encode queue and decodes the next one meanwhile. That took the whole sample from 2.73 s to 1.75 s, and with LibTrueHD 2.2.0's faster decode to 1.40 s: 19x real time against 10x in series. The encoder is now the slower half, so the decoder no longer sets the pace. That time is what a seek past the produced range waits for before its first segment, so it is the one place the trade shows.

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

**The option.** `objectAudioRendering = .apac(layout)` keeps them, in a build with the `DTSXObjectAudio` package trait (off by default; without it DTS-HD keeps the channel bridge whatever the option asks, [Installation › Optional components](installation.md#optional-components)). A DTS-HD Master Audio track is decoded by FFmpeg's own `dca` decoder into the same bed regression, limiter and APAC encoder as TrueHD Atmos. The engine side is a channel mapping (`DTSXObjectAudioDecoder`). No library comes in for it: FFmpegBuild patches the decoder (#798).

#### The standard presentation

DTS:X's standard presentation is a 7.1 bed and four fixed heights (the top front and top back pairs). Each height is folded at -3 dB into the bed speaker under it (top front left into L, top back left into the left rear, and so on), so that a 7.1 decoder plays the whole soundtrack.

**Decoding the heights.** The heights travel in a regular XLL channel set at the end of every lossless frame, behind a syncword that upstream FFmpeg recognises (it is what makes it label a track "DTS-HD MA + DTS:X") but then skips. FFmpegBuild's patch decodes that channel set with FFmpeg's own XLL code. With the decoder option `x_heights`, which `DTSXObjectAudioDecoder` sets, it outputs 7.1.4: the bed exactly as coded, heights still folded in, next to the four heights. Without the option the decoder's output is unchanged.

**Rendering.** Nothing is subtracted from the bed. Every output is built from that bed alone by `BedRegression` in its fold mode: `W = D + (R − D · F) · A`.

- The bed plays on its own speakers.
- Each height moves the part of the bed the regression attributes to it (its cross-spectra with the bed over the bed's covariance, per band, about 20 ms of memory) from the speaker it is folded into to its own.
- The heights are statistics only and never play themselves.
- The fold `F` is the format's, not read from the stream's private metadata. Every frame of twelve DTS:X tracks measured (eight *Harry Potter* films, two *Shrek* films in two languages, *Mary and the Witch's Flower*) stated the same one.

**Accuracy.** Against the exact separation on 21 windows of seven of those films, the heights stayed within 0.14 dB at a correlation of 0.994 to 1.000 wherever they carry 0.3 % of the energy or more, 29 to 49 dB overall. The weakest seconds are nearly silent heights, 37 to 74 dB under the programme.

**Energy bound.** A height alone legitimately carries twice its folded energy, so the energy bound here is 0.5 to 2.5 times the bed (TrueHD's 0.9 to 1.6 would cost up to 14 dB).

**Latency.** The regression's 2048 frames, kept off the timeline.

**Layouts.** Each of the twelve channels has its own speaker, so DTS:X is rendered into the two layouts that carry all twelve one to one, 7.1.4 and 9.1.6. Any other layout keeps the channel bridge.

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

Those runs predate the decoder in FFmpeg, and the activator no longer runs for DTS:X: a DTS programme is not Dolby Atmos. So a sink that needs the activator to show Atmos now shows multichannel PCM for DTS:X, with the heights still in it.

#### What the session log says (DTS:X)

- `[HLSVideoEngine] DTS-HD MA track is DTS:X 7.1.4 (first frame, 3 ms)` names the layout the verdict found.
- A refusal names its reason:
  - `no DTS:X extension in the standard presentation, 8 channels`
  - `DTS:X in an alternate presentation without heights, which plays as its 7.1 bed` (a stream FFmpeg labels IMAX whose frames carry none)
  - `DTS:X in alternate presentation 0xd4, whose height fold is not known, which plays as its 7.1 bed`
- A frame whose height channel set does not decode keeps the 7.1.4 layout with silent heights and the bed as coded, and libavcodec logs `DTS:X height channels not decoded, output silent heights`.
- A layout other than 7.1.4 or 9.1.6 logs `DTS:X is rendered into 7.1.4 or 9.1.6 only`.
- The `object configuration` and `bed levels` lines are the same as for TrueHD Atmos. So is the 1200-packet silence report: at 512 samples a DTS frame, that is 12.8 s of DTS, against a second of TrueHD.

## Subtitles

Subtitle cues come from one read of the source. Every cue, whatever its codec, ends up in a single published `[SubtitleCue]` list (`subtitleCues`) that the host renders as an overlay. Each packet decodes through `avcodec_decode_subtitle2`, except in-band CEA-608, which has an in-house line-21 decoder ([below](#in-band-cea-608-closed-captions)).

This section covers:

- how embedded cues are collected and how far ahead they reach,
- what each codec produces,
- external subtitle files, language preferences, a second simultaneous track,
- how the cue list stays correct across seeks,
- native WebVTT renditions for PiP / AirPlay / external display, live HLS renditions, and authored ASS styling.

**Render against `player.sourceTime`.** Subtitle cues land in raw source PTS. On the native path, AVPlayer's HLS clock sits at `source_pts - producer.videoShiftPts`: the producer applies a per-session shift to align the first segment's tfdt with the playlist origin, and the shift can change on every restart. Rendering the overlay against `player.sourceTime` keeps cues matched to the spoken audio regardless of which producer session is active.

### How embedded cues are collected

- **Harvest.** EVERY embedded subtitle stream (text and bitmap) stays in the session demuxer's keep-set, and is harvested by a tap on the host's existing source read. Each packet is observed and then dropped, never muxed.
- **Store.** Harvested packets are kept compressed in a per-session `SubtitlePacketStore` (300 s trailing window, byte-capped per stream).
- **Drain.** A playhead-paced drainer decodes the selected stream near the playhead into the overlay.
- **PGS in MPEG-TS (Blu-ray).** A display set arrives split across several PES packets (PCS|WDS|PDS|ODS|END, some without a PTS of their own). The store reassembles those chunks into one self-contained entry at the PCS presentation PTS before keeping it, so the drainer always decodes complete display sets. Matroska already carries one complete set per packet and is stored as-is.
- **Instant selection.** Enabling any embedded track is instant: the selection backfills synchronously from the store, with no positioning seek and no recovery machinery, even on remote disc images.
- **Seeks and restarts.** The tap re-attaches with the producer across seeks and restarts.

#### Forward prefetcher (#151)

The tap's forward coverage ends at the producer's read position (its forward park, #102), which on direct play sits only a few seconds past the playhead. On VOD sessions a background subtitle-only side reader, the forward prefetcher, therefore extends the store past the drainer's 60 s lead window, by a 15 s margin so the set at the window's forward edge still has its own successor stored (#362).

- While a bitmap track's OCR rendition is armed, the lead is raised to 270 s, which clears the OCR worker's own 240 s window by 30 s, so the store actually holds what the worker is about to read.
- So `subtitleCues` holds cues ahead of the playhead for a host-applied ADVANCE sync offset, text and bitmap alike.
- Live sessions skip it: content past the edge does not exist.
- **Only when something reads ahead (AE#1015).** It runs while the host's offset reach is above 0 (`maximumSubtitleOffsetSeconds`, default 60), `softwareSubtitleDelaySeconds` is negative, or the OCR worker is armed. On an interleaved container it downloads the video a second time, so with a reach of 0 the drainer reads from the tap alone.
- It is best-effort. If it cannot open or wedges, the tap-fed behavior above is unchanged.
- **Positioning (#234).** Its positioning seek is anchored on the subtitle stream's own timestamp axis. Left to libavformat's default reference, the anchor follows whichever stream is not fully discarded. The pacing stream that gives the park its control point (#230) would then move it onto video keyframes, and on Matroska that lands in a later cluster and drops a landing cue that starts further back than the destination.
- **Re-anchoring.** A playhead jump re-anchors the running session in place rather than rebuilding it, since a rebuild pays an open, the Matroska cue-index prewarm and a positioning seek, each a bounded range the origin delivers in full.

#### Sharing the link with video (#240)

The side reader shares the source link with the video pump. On Matroska it is a second full copy of the stream (`matroska_parse_cluster` reads every block off the wire; only `matroska_parse_block` then honours the discard flag), so a subtitled session asks the link for about twice the media rate. Where the link has little headroom the two starve each other, so the video path has priority. A side reader:

- fetches while the pump is parked,
- yields while the pump is fetching, and yields completely while a seek is in flight,
- keeps a bounded grace window after each anchor so a freshly selected track still fills,
- takes the link back after a 60 s continuous yield, so a pump that never parks cannot disable lookahead for the session.

Measured on a 1.4x-headroom bench, far-seek landings improved about 45% at the median and the side reader's share of the link halved.

#### Sidecar fetch (AE#984)

Sidecars are fetched once. A text sidecar (SRT, WebVTT, ASS/SSA by extension or `formatHint`) over HTTP is one plain GET for the whole body, waited for up to 120 s without a byte and decoded locally. So a server that extracts the stream before it answers still delivers. Container and `.sup` sidecars stay on the source reader.

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
  - On a page it does not flag (the broadcaster leaves NEWSFLASH / SUBTITLE / SUPPRESS_HEADER unset, or the row-0 header has not been seen yet), it writes the whole page instead, one row per line, and the ordinal of the first non-blank row is the only carrier of the position. The engine applies libzvbi's own third-of-the-page formula to that ordinal, so a caption the broadcaster moved to the top of frame stays there either way. It never overrides an `\an` that did arrive.
- **Whitespace** follows the same split. The unflagged page is the raw grid, every row at full column width with a hard space per cell, so the engine trims the padding off both ends of each row and folds the empty rows it also emits. A page the decoder curates itself arrives untouched, since there the remaining padding is the relative indentation carrying the alignment it chose, and the blank lines are its vertical fine-positioning inside the block.
- **Page choice (#364).** The decoded page defaults to libzvbi's auto-detected subtitle page. It can be overridden per channel via `LoadOptions.teletextPage` (for example AU page 801, which libzvbi does not always flag as a subtitle page), and changed while the channel plays via `setTeletextPage(_:)`. That rebuilds the drain decoder of every channel currently showing a teletext track and leaves the others alone.
- **Cue lifetimes.** libzvbi emits page content open-ended ("valid until replaced") and page erases as empty events, so every teletext event trims earlier open cues at its start. Roll-up captions build and replace cleanly, an erase clears the line, and a 120 s cap bounds a ghost line if transmission stops without either.
- **Validated** end to end against Australian FTA broadcasts (1080i25 H.264, captions on page 801), where the interlaced video deinterlaces through the software path's bwdif filter.

#### Bitmap codecs

PGS / HDMV PGS / DVB / DVD produce `.image(SubtitleImage)`. The indexed pixel plane is walked through its palette, premultiplied against alpha, and wrapped as a `CGImage`.

- **Colour (#1006).** The image is always sRGB. On a PQ source (HDR10, Dolby Vision with a PQ base) a PGS palette is PQ-coded per the UHD Blu-ray spec, so each entry is converted first: to BT.2020, through the PQ EOTF against the BT.2408 graphics white of 203 nits, to BT.709, and clipped to SDR. The disc's ~294-nit text white lands on 255.
- **Position (#112).** Position is normalised in `[0..1]` against the composition canvas, whose coded pixel size rides along as `SubtitleImage.canvasSize`. A cropped-video rip can author a canvas taller than the coded video, so hosts map the canvas width-aligned and center-anchored onto the coded video frame to land cues where the disc authored them, then scale onto the displayed picture rect per axis (which only differs on anamorphic video). `.zero` means treat canvas == video.
- **DVB (#971) and DVD on a rescaled encode (#993)** report the video frame instead of their 720x576 / 720x480 plane, since that display covers the whole picture with non-square pixels. A DVD on video wider than 16:9 reports the 16:9 frame at the video's width, as the picture was cropped out of it.
- **Several objects (#146).** A display set carrying multiple composition objects (a forced sign plus dialogue is a common real-disc shape) fans into one cue per object, all sharing the set's start PTS, and every object is kept and rendered.
- **Forced flag.** Each object's `AV_SUBTITLE_FLAG_FORCED` rides along as `SubtitleImage.isForced`, surfaced per cue via `SubtitleCue.isForced`. Track-level forcedness stays on `TrackInfo.isForced`.

#### External files

A separate `.srt` / `.ass` / `.vtt` URL either registers as a first-class track ([next section](#external-subtitle-files-as-first-class-tracks)) or is loaded one-shot via `selectSidecarSubtitle(url:httpHeaders:)`.

- **Text sidecar.** `selectSidecarSubtitle` opens its own short-lived `AVFormatContext`, decodes the whole file once, and atomically swaps the result into `subtitleCues`.
- **Bitmap sidecar (#921).** A PGS `.sup` (reported as `pgssub`) is read whole too, but not decoded. Its packets go into a packet store of its own, and the overlay drainer decodes the window around the playhead from them, exactly as for an embedded bitmap track. It shares that track's bitmap byte budget and backward-seek backscan, and shows its first picture without waiting for the rest of the file. Decoding it whole kept every picture for the session, 12 times the size of the file on a film-length track.
- **Headers.** The fetch forwards the session's `LoadOptions.httpHeaders` by default (WebDAV auth and friends). Pass the call's own `httpHeaders` to override per fetch.

#### In-band CEA-608 closed captions

In-band CEA-608 (`eia_608` / QuickTime `c608`, a demuxable caption track) produces `.text(String)` (#77).

- FFmpegBuild ships no `ccaption` decoder, so these never reach `avcodec_decode_subtitle2`.
- Instead, a read-only tap on the segment producer's existing source connection reads the caption track's `cc_data`. Its packets are kept in the demuxer's keep-set, observed, then dropped, never muxed, so the loopback-HLS output stays byte-identical.
- An in-house line-21 decoder (validated against FFmpeg's `ccaption_dec.c`) turns it into cues, and they publish on the same `subtitleCues` overlay path as every other codec.
- First cut: field-1 / channel CC1. CEA-708 (DTVCC) and field 2 are follow-ons.

**Captions inside the video bitstream (#131).** Captions carried only inside the video (ATSC A/53 `cc_data`, the US broadcast/cable case) are extracted too:

- On the native remux path, the segment producer scans H.264/HEVC video packets for `user_data_registered_itu_t_t35` SEI (GA94), reorders the decode-order groups to presentation order by the packet DTS watermark, and feeds the same line-21 decoder.
- On the software-decode path (MPEG-2 and friends), the triplets come from `AV_FRAME_DATA_A53_CC` decoded-frame side data.
- Since no caption AVStream exists, a synthetic `eia_608` track (id 99608) surfaces lazily on the first real (non-padding) caption pair, so uncaptioned channels never show a dead menu entry.

CEA-608 is host-overlay only (no PiP / AirPlay), like the bitmap codecs.

### External subtitle files as first-class tracks

External subtitle files register with the engine and appear in `subtitleTracks` next to the embedded streams, so a host keeps one track list and one selection call (#88).

- **Registration.** `LoadOptions.externalSubtitles: [ExternalSubtitleTrack]` declares files at load. `addExternalSubtitleTrack(_:)` registers one at any time mid-session and returns the created `TrackInfo`. The descriptor carries `url`, optional `name` / `language` / disposition flags, per-track `httpHeaders` (nil forwards the session's), and a `formatHint` for URLs whose path hides the extension.
- **Containers with several subtitle streams.** An external URL can be a container rather than a sidecar (an MKV holding English, English SDH and Spanish).
  - `ExternalSubtitleTrack.sourceStreamIndex` names which stream to decode, as an ABSOLUTE `AVStream` index inside that container, so a host registers one track per stream against the same URL. nil decodes the container's first subtitle stream.
  - An index that is out of range or names a non-subtitle stream fails the decode rather than falling back, which would be indistinguishable from leaving it nil.
  - Tracks sharing a URL and headers are filled from a SINGLE pass over the container, so N tracks cost one fetch, not N (#266).
  - `TrackInfo.codec` is still derived from the URL extension, so a container URL reports `subrip`. Set `formatHint: "ass"` when the streams are ASS and the host drives a styled renderer.
- **VobSub (`.idx` + `.sub`).** Only from a local file URL, since FFmpegBuild 3.8.0. The `vobsub` demuxer reads the `.idx` it is handed and opens the `.sub` itself, by the `.idx`'s own name through the file protocol, so the pair has to sit side by side on disk. Over HTTP the engine opens a sidecar through its own `AVIOReader` without a path, so the demuxer has no name to derive the `.sub` from and the open fails. A host that serves VobSub remotely downloads both files first.
- **Identity.** External `TrackInfo.id`s are synthetic: `AetherEngine.externalSubtitleTrackIDBase` (100 000) + registration ordinal, monotonic per load. Load-declared tracks get `base + array index`, in order. `TrackInfo.isExternal` distinguishes them from AVStream-indexed embedded tracks.
- **Selection.** `selectSubtitleTrack(index:)` and `selectSecondarySubtitleTrack(index:)` accept external ids and route onto the whole-file decode internally. `activeSubtitleTrackIndex` publishes the external id like any other selection. `removeExternalSubtitleTrack(id:)` unregisters (an active selection is cleared).
- **Renditions.** Load-declared external tracks join the native WebVTT renditions ([below](#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display)).
  - Their store is filled by one whole-file decode at load (one pass per container, covering every track pointing at it) and marked finished.
  - A finished store also backfills the fullscreen overlay instantly on select (no re-download; styled-ASS selections re-decode to keep raw markup).
  - A store that could not be filled stays unfinished rather than serving a complete but blank `.vtt`.
  - Tracks added after load are host-overlay only until the next load, because the rendition set is fixed in the master playlist at item creation.
- **Preferences.** `preferredSubtitleLanguages` ranks external tracks together with embedded ones. A track added mid-session re-runs the preference and auto-activates on a match, but only while the host has made no explicit subtitle call (select / sidecar / clear) in the session, so a deliberate subtitles-off stays off.

#### Renditions on the `nativeRemoteHLS` bypass (#316)

That path plays the origin playlist directly and has no loopback master to declare anything in, so a declared sidecar used to be dropped outright. For a VOD source the engine now:

1. fetches the origin master,
2. makes every variant / audio / key URI absolute against the origin,
3. adds one `EXT-X-MEDIA:TYPE=SUBTITLES` per text sidecar, joining the origin's own subtitles group when it has one so a variant's group choice cannot lose them,
4. serves that master from the loopback origin.

The media never moves: AVPlayer fetches A/V from the origin exactly as before, which is the property the bypass exists for (E-AC-3 / Atmos passthrough).

- Renditions are declared `DEFAULT=NO,AUTOSELECT=NO` and without `FORCED`, the same discipline as the loopback master, so nothing self-engages.
- The track keeps its external id, and selecting it drives `AVMediaSelection` rather than the overlay, so it survives PiP / AirPlay / an external display.
- These keep the origin URL and overlay-only subtitles: live playlists (no `EXT-X-ENDLIST`), bitmap sidecars (`.sup`), an unparseable or unrewritable playlist, and an origin slower than the 5 s budget.
- **A rendition is never held for its sidecar (AE#984).** AVPlayer will not load media past the point it needs the selected subtitle segment for, so a request held for a slow file froze the picture of a healthy stream. While the sidecar is still decoding, the `.vtt` is answered 404. AVPlayer retries every few seconds while A/V keeps loading, and the complete file is served on the first retry after the decode. A sidecar that could not be read is served empty at once. The loopback master's whole-program renditions of load-declared sidecars follow the same rule.

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

**Inputs and outputs.** Nothing is inferred from `TrackInfo.name`, `ExternalSubtitleTrack.name` or a sidecar filename: the structured `language` field is the whole input. The resolved tracks are published on `player.activeAudioTrackIndex` / `player.activeSubtitleTrackIndex` (both match `TrackInfo.id`). Every `TrackInfo` carries `isDefault` / `isForced` / `isHearingImpaired` / `isCommentary` / `isVisualImpaired` (from container dispositions), so a host can rank or filter the track lists the same way.

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

**Multiple rects and dedupe.** A single packet that carries multiple rects (PGS often emits signs/songs at the top alongside dialogue at the bottom) becomes multiple cues with the same time range, and the host renders all of them. Cues are inserted in sorted order. Re-emitted events after a seek dedupe by time range plus content (so two simultaneous speaker lines with identical timing both survive), and the list does not grow on rewind.

#### Ending a PGS cue

A PGS composition carries no end of its own. It is published with FFmpeg's open-ended placeholder end (`end_display_time = UINT32_MAX`) and closed when its successor composition or clear arrives.

**The normal case: the next stored packet (#362).** The end a set is authored with is the PTS of the next packet on its stream, and the packet store holds that packet long before the drain window reaches it. So every tick closes each still-open cue at `SubtitlePacketStore.firstPTS(streamIndex:after:)`.

- Without this, the drain window's forward edge decides the end whenever it falls between a set and its clear: the set publishes open, the cursor moves past it, and the next thing to touch it is a composition at the next landing, tens or hundreds of seconds later (report: 3.55 s authored, 76.7 s delivered, and 817 s in the same session).
- For the store to be able to answer, the harvest has to lead the decode. The forward prefetcher parks a 15 s margin BEYOND the drain window (`subtitleForwardPrefetchLeadMarginSeconds`), because with both lines at 60 s the set at the edge is systematically the one whose clear is stored nowhere.
- Where the store genuinely has nothing after a set (its harvest frontier, a stream cut short), the cue stays open and #357's boundary close still owns it. Inventing an end there is the laundering this replaced.

**The last resort: the seek boundary (#357).** A seek can outrun the successor, and the retention prune cannot help (it filters on `endTime`, which a placeholder end never ages out of). So a jump past an open cue used to leave it in the published window, covering the new playhead until the next composition displaced it. On a seek, the drain now closes every still-open cue that began before its reconstruction window (playhead minus the 15 s backscan) at that window's start: past that line nothing is re-decoded, so nothing there can be confirmed as still open.

- The cue stays in the kept list for a backward seek. Only its unconfirmed end retires.
- An authored duration is never touched.
- The #100 stale-arrival hold is dropped on the same tick, for the same reason.

#### Holes in the packet store (#362, #941)

**The problem.** After a seek, the pump restarts behind the landing and fills forward, while the store still holds an island the previous run harvested further ahead. The drain window then reads as "packets, hole, packets". Decoding across that hole carries the drain cursor to its far side, and the cursor only moves forward: the hole's packets land a second later and are never read. A stretch of the film then carries no subtitles at all until some later seek resets the window behind it, and the set before the hole is closed at the island rather than at its own clear (report: eleven authored sets delivered as two).

**Why not a gap threshold.** The size of the gap cannot tell that apart from a silence the author left, and a threshold on it is actively harmful, since a set is separated from its own clear by its display duration.

**Harvest order (#362).** Harvest ORDER can tell. A run reads a stream forwards, so within one run PTS and sequence rise together. A PTS-ascending pair whose sequence DESCENDS is two runs meeting over a span neither of them has read. A tick stops at that boundary and waits (`harvestGapCut`).

- This costs nothing visible, because the drain runs its lead ahead of the playhead.
- The wait ends when the filling run re-harvests across the boundary, or when the playhead comes within two seconds of its far side, so an authored silence never stalls delivery.
- There is no other tick budget (#941 round 3). Ticks ran on wall time and expired during seeks and rebuffers while the playhead stood still, which decoded the island over the sets the refill was about to harvest.
- A tick that waited says so, as `outcome=harvestHole gapAt=`.

**Three runs meeting (#941).** Order still sees only half of it. Seek past the producer's front and straight back into the stretch that jump skipped, and three runs meet: the original one up to just past the landing, the forward one's island further on, and the restart behind the landing that has not written anything yet. The island was harvested after the near side, so the sequence ASCENDS across the hole, no pair descends, and the first tick decoded straight across, losing every set the restart then harvested in between (report: seven consecutive sets on a 1x link). A re-harvest of the island does the same to a wait that did fire, because it stamps the island newer than the held position.

The coverage ledger ([below](#the-landing-after-a-seek-416)) knows both cases. `harvestGapCut` also stops at a pair whose span no reader has read, and a wait resumes only when the order AND the ledger agree that the ground up to the next entry was read.

Two more things had to hold for that to work on a link near the media bitrate:

- **No reach claim during a seek.** The pump's reach claim ("it rendered the playhead, so it read up to there") is not made while a seek is in flight. `sourceTime` still reports the frame the seek is leaving while the producer is already re-anchored behind it, and the claim stretched the fresh run across exactly the skipped ground.
- **Release on the far side.** A wait now ends when the playhead closes on the FAR side of the hole (within `subtitleDrainHarvestGapReleaseLeadSeconds`), not on the near one. A refill at about 1x keeps the playhead just behind the filling run, so it passes the last packet before the hole while the hole is still ahead, and releasing there decoded the island over the sets the refill was a second from harvesting.

#### The landing after a seek (#416)

**The problem.** A hole behind the playhead has a third face: the landing itself. The gate that reconstructs the active line at a seek target seeds it from the newest set decoded behind the playhead, and that set is the active line only if nothing on its stream happened in between. The store's silence is read as that proof, and over a stretch nobody read, it proves nothing. A run re-aimed just after it harvested a set leaves that set's own clear on the far side of the skipped ground. The set then decodes at the landing looking unclosed and publishes over the new scene, ending at the next stored packet, which is the far side of the authored silence rather than its own successor (report: a two-second sound-effect caption standing ten seconds over the wrong scene, on both an Apple TV 4K and a Mac).

**Why the packets alone cannot show it.** #362 established this: a reader re-anchored FORWARD hangs its packets in ascending order behind the stretch it skipped, so the pair looks exactly like an authored silence. Only a reader restarted BEHIND leaves the descending sequence `harvestGapCut` reads.

**The coverage ledger.** So the readers now say what they read. `SubtitleHarvestCoverage` in the packet store keeps one span per run, anchored where the reader positioned and extended as it goes:

- The forward prefetcher reports its own read position.
- The pump's run begins where the producer opens or restarts, and reaches at least the playhead, since playback is rendering there.
- A set whose ground up to the playhead is not covered cannot claim the landing (`landingWithheld=` on the delivery line), and the pass ends on the next authored set as it would have anyway.
- A store nobody reports to answers every span with yes, so a path without coverage notes behaves exactly as it did.

**Cost.** The landing line is lost in the case where a set really is still up and the proof is missing, which needs an authored dwell long enough to span the whole unread stretch. The alternative was paying that for every normally authored set that ends inside one.

### Native subtitle renditions (WebVTT for PiP, AirPlay, and external display)

**Why.** Host-rendered subtitle overlays are invisible in Picture-in-Picture, AirPlay and external-display sessions, because those paths render the `AVPlayerLayer` content only. The SwiftUI / UIKit view tree is not composited.

**What the engine does.** It serves every text subtitle track as a real HLS `SUBTITLES` rendition over the loopback:

- The master playlist carries one language-tagged `EXT-X-MEDIA:TYPE=SUBTITLES` entry per track (`DEFAULT=NO,AUTOSELECT=NO`) plus `SUBTITLES="subs"` on the variant.
- Each track is backed by a media playlist (`subs_N.m3u8`) whose WebVTT segments mirror the video segments 1:1.
- AVFoundation exposes the renditions as a standard legible `AVMediaSelection` group that travels with the stream everywhere `AVPlayer` goes, including PiP.

(An earlier design muxed `mov_text`/tx3g traks into the fMP4 itself. In-band timed text is not HLS-conformant and AVPlayer rejected the stream, so the WebVTT rendition replaced it.)

**Opt-in.** Off by default (`LoadOptions.prepareNativeSubtitles = false`): no renditions in the master, no legible menu, output identical to before.

**Cue source: the producer pump tap.** The segment producer already reads the source's full interleave, so the text subtitle streams stay in its keep-set, and every packet is handed to a session-level tap that decodes into per-track cue stores (the same pattern as the CEA-608 tap).

- Zero side-channel bandwidth. Coverage is by construction the produced region, across seeks and producer restarts.
- The host overlay is fed separately, by the packet-store drainer (#112 rework, see [Subtitles](#subtitles) above).
- A lazy per-selection reader still covers AVKit's ~240 s forward `.vtt` prefetch beyond the produced region.
- Load-declared external tracks (#88) have no demuxable stream to tap. Their store is filled by one whole-file decode at load and marked finished, so their rendition serves complete `.vtt` files from the start.

#### Routing scope

A `SUBTITLES` rendition can only live in a master playlist, so native subtitles follow the master-routing rules:

| Source and panel | Native subtitles |
| --- | --- |
| SDR source, any panel | Yes |
| HDR / DV source on an HDR-ready panel | Yes |
| HDR on an SDR panel | No (media-direct, no master) |
| DV Profile 5 on a non-DV panel | No (media-direct, no master) |
| Live sources | No: their own `SUBTITLES` renditions reach the host through the overlay ([below](#live-hls-subtitle-renditions-host-overlay)) |
| Software decode path (AV1 without hardware decode, VP9) | No: there is no `AVPlayerItem` for a legible group to live on, so `prepareNativeSubtitles` is inert and the host overlay owns subtitles on every surface |

Where there are no native subtitles, the host overlay still covers fullscreen.

#### Bitmap subtitles through OCR

Bitmap subtitles (PGS / DVB / DVD) join as OCR-fed renditions.

**When the worker runs.** Only while a bitmap track is selected AND its rendition is the display (the host called `setNativeSubtitleRendering(true)` for PiP, AirPlay or an external display). It is not armed for fullscreen viewing, where nothing shows the rendition: armed, it raises the forward prefetch to 270 s, and on Matroska that reader pulls every cluster, which measured ten times the prefetch bytes of the overlay-only lead on a 4K remux (434 against 17 MB in 90 s).

**What it does.** The worker decodes the track's harvested packets ahead of the playhead (composition ends resolved at the next composition/clear event, the 5.14.1 sidecar semantics), and recognizes them on-device (Vision, hinted with the track language) into plain-text cues for the track's rendition. Recognition is lossy by design. A failed or empty read drops that line from the rendition, while fullscreen keeps the pixel-accurate bitmap overlay.

**Selecting waits for recognition.** Armed on demand, the worker starts the rendition's window empty, and AVKit takes the whole forward window in one burst at selection and caches what it gets. So the native select waits until the worker has recognized every stored composition through `subtitleOCRLeadSeconds` (read by the harvest and decoded, not merely cue ends reaching a target, which a sparse forced track never does), and only then selects.

- Near the end of a program, that window ends at the duration, and a harvest read that reached end of file covers it (AE#955: it did not, and a select in the last four minutes of a film waited forever).
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

This is the same rule the engine already applies locally, where an HDR source on a panel that is not in HDR mode is served the media playlist, and it is what DrHurt described in #86. Dressing the manifest up does not change it either. Against a parked receiver, dropping the DV `SUPPLEMENTAL-CODECS`, clamping the declared `BANDWIDTH`, omitting `RESOLUTION` and declaring `HDCP-LEVEL=TYPE-1` each changed nothing, and declaring the range as SDR was already disproven in #98.

**Catching the silent refusal.** The refusal is silent, so it has to be caught by watching progress: no `-11868`, no failed item, the rate flickers to `playing` for a single tick so even `hasEverPlayed` latches, and the picture never starts while AVKit shows its "not playable on this display" sign.

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

HDR / DV on an SDR external display is therefore media-playlist-driven, so the `SUBTITLES` renditions do not travel there. This is an AVKit limitation: forcing `VIDEO-RANGE=SDR` does not fool the external-display compatibility gate, which checks the real `colr` / codec rather than the manifest string.

The separate `#35` cold-DV-start readiness gate, whose scenario is an HDR TV, first tries an HDR-preserving reduced master (`SUPPLEMENTAL-CODECS` dropped so it is plain HDR10, source range and `SUBTITLES` group kept) before the bare media playlist. So a cold DV start keeps HDR10 plus subtitles instead of dropping straight to subtitle-less media.

#### Rich ASS styling

With `LoadOptions.preserveASSMarkup` the tap keeps raw ASS event lines, so the host overlay renders full styling (positions, colours). The WebVTT renditions strip the markup at serve time, so PiP shows plain text in the system caption style.

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
engine.setNativeSubtitleSelected(track ordinal: Int?)

// convenience for the enter/leave pattern below: true resolves the rendition matching the
// currently-active overlay track and selects it, false deselects
engine.setNativeSubtitleRendering(_ active: Bool)
```

`NativeSubtitleTrack` carries `.ordinal` (position in the rendition declaration), `.language` (ISO 639-2 tag), and `.displayName` (localized name suitable for a picker label).

The recommended host pattern for PiP / AirPlay:

1. Observe `$nativeSubtitleRenditionAvailable` (wait for the first cues to be ready before activating).
2. On entering PiP / AirPlay / external display: call `setNativeSubtitleRendering(true)` (or resolve the ordinal yourself via `setNativeSubtitleSelected(track:)`), and hide the host overlay. A wireless AirPlay receiver is covered even without that call: the engine raises the request itself when the host has not, since the overlay cannot reach a receiver, and withdraws its own request when the receiver lets go (AE#955). A host call takes over either way.
3. On leaving: call `setNativeSubtitleRendering(false)` and re-enable the host overlay.

This avoids double subtitles during inline playback (where the host overlay is already painting them), and makes sure the user sees subtitles the moment the stream is mirrored or sent to PiP.

#### Device-verification checklist

Required before tagging a release:

- Selecting a rendition displays it in the PiP window and survives seeks (including seeks that restart the producer).
- Inline host ASS rendering unchanged: rich styling intact, tap-fed cues appear instantly on selection.
- No double subtitles while inline; no rendition is auto-selected on session start.
- Timing: no constant offset between audio and subtitle cues, before and after seeks.
- SDR / HDR10 picture behavior unchanged with `prepareNativeSubtitles = true` (the renditions only add master tags + subtitle endpoints).
- HDR-on-SDR-panel and DV Profile 5 on non-DV panels still play (media-direct, no renditions there by design).
- Memory bounded by total cue count across all tracks.

### Live HLS subtitle renditions (host overlay)

A live channel carries its subtitles the same way a VOD stream does: as an `EXT-X-MEDIA:TYPE=SUBTITLES` group in the upstream master. The live ingest demuxes only the picked video variant, so that group never reaches the demuxer. Before #359, a channel offering three subtitle languages produced no subtitle track at all.

**What the engine does.** It surfaces the master's renditions as tracks (synthetic ids from `liveSubtitleRenditionTrackIDBase`, 300000). When the host selects one, it fetches its WebVTT segments and publishes the cues on the same host-overlay surface the CEA-608 tap uses. This is the overlay path, not a legible `AVMediaSelection`: the live loopback serves a media playlist, which cannot declare a rendition (see [Routing scope](#routing-scope)).

**Lazy by design.** The tracks come from the master's declaration alone, and nothing is fetched until a track is selected, so a channel watched without subtitles pays no second HTTP loop. Selection starts a poll of the rendition playlist at its `EXT-X-TARGETDURATION`, and only unseen segment URIs are fetched, so a poll that arrives before the window moved costs one small request.

Three properties to know when reading `[LiveSubs]` log lines:

- **Placement comes from the playlist geometry, not from `X-TIMESTAMP-MAP`.** The spec's own anchor is unusable in the field: measured against a public broadcaster, every segment carries the same constant map, whose MPEGTS value sits two hours away from the video PTS. What renditions of one program do share, byte for byte, is `EXT-X-MEDIA-SEQUENCE` and `EXT-X-PROGRAM-DATE-TIME`. So a cue is placed at its segment's broadcast time plus its offset inside that segment. An upstream without `EXT-X-PROGRAM-DATE-TIME` therefore has no placement at all: the loop says so in the log and stops, rather than publishing something plausible and wrong.
- **The fetch is anchored at the playhead, not at the head of the playlist.** A rendition playlist is not a handful of segments (a two-hour DVR window is 3600 entries), so everything older than 120 s behind the playhead is marked seen without being fetched. Enabling subtitles and jumping back a little still lands in covered ground.
- **A producer seam republishes the source-axis shift**, and cues already placed then refer to an axis that no longer exists. The loop watches its own pairing and re-anchors, which keeps a long session from drifting further out the longer it runs (6.21.1).

`aetherctl play --live-ingest --subs <lang>` exercises this against a real channel. It is the only CLI route that does, and its absence is why #359 stayed invisible for as long as it did.

### Authored ASS styling

Hosts that render authored ASS styling themselves (positioning, speaker colours, karaoke) opt out of the stripping with `LoadOptions(preserveASSMarkup: true)`. Then:

- Cues carry the raw event line (override tags, style references, escapes intact).
- The script header (`[Script Info]` + `[V4+ Styles]`) is surfaced.
- `engine.fontAttachments` carries the container's embedded fonts (TTF / OTF) for the renderer's font directory. A host that does not use them sets `LoadOptions.skipsContainerAttachments`, which saves the open reading them: tens of megabytes on anime releases (AE#956).

`ASSScriptBuilder` reassembles raw event cues + header into a complete script for whole-file renderers such as swift-ass-renderer's `loadTrack(content:)`. It is hardened against real-world Matroska tracks: a synthesized `[Events]` section, NUL stripping, and content-keyed dedupe, since real files hardcode `ReadOrder: 0`.

**ASS and SSA only (AE#587).** The flag reaches ASS and SSA tracks only, on the embedded and the sidecar path alike. libavcodec normalises SubRip, WebVTT and mov_text into event lines of the same shape through `ff_ass_add_rect`, so those rects carry an ASS payload the engine could emit and deliberately never does. No header is surfaced for them (`TrackInfo.assHeader` is ASS/SSA-only), which would leave a host stripping the nine leading fields by hand. A session that mixes an ASS track with a SubRip one therefore needs no reload to cross between them, and `aetherctl play --preserve-ass-markup --subs <track>` shows which of the two a given track is.

**Where the header arrives (AetherEngine#48).**

- Embedded tracks carry it on `TrackInfo.assHeader`.
- External `.ass` / `.ssa` sidecars loaded through `selectSidecarSubtitle(url:)` under the same `preserveASSMarkup` flag carry it on `engine.sidecarASSHeader` (extracted from the file's subtitle-stream extradata; nil for SRT / VTT and when preservation is off).

Both pair with the raw event-line cues the same way.

The host stays in charge of the actual paint: text styling, overlay layout, fade transitions, position scaling against the on-screen video rect.

## Frame extraction

`FrameExtractor` produces still `CGImage`s from a media URL through an FFmpeg decode context that is fully isolated from playback. It never touches the playback pipeline, the HLS loopback server, or the engine's shared state, so a scrub-preview decode cannot disturb the frame on screen. Two modes share one decode core:

| Method | What it does | Built for |
| --- | --- | --- |
| `thumbnail(at:maxWidth:)` | Seeks to the nearest keyframe, no forward decode, downscaled to `maxWidth` (default 320). Cheap and fast. | Scrub previews, Recents lists |
| `snapshot(at:maxSize:)` | Decodes forward to the exact PTS, full or `maxSize`-clamped resolution | User-triggered stills |

```swift
let frames = engine.makeFrameExtractor()           // nil if nothing is loaded
// or, for an arbitrary item (e.g. a Recents row):
let frames = FrameExtractor(url: url, httpHeaders: headers)

await frames.prewarm()                             // optional: hide cold-start at gesture begin
let preview = await frames.thumbnail(at: 612.0)    // CGImage?, nearest keyframe
let still   = await frames.snapshot(at: 612.0)     // CGImage?, frame-accurate
await frames.shutdown()                            // prompt teardown of the decode context
```

**HDR stills.** PQ / HLG BT.2020 frames are tone-mapped to SDR BT.709 through a zscale + tonemap libavfilter graph before the `CGImage` is built, so HDR10 / HLG / DV P8.x stills match what the user sees instead of washed-out grey.

**Dolby Vision Profile 5 and AV1 Profile 10.0** (IPT-PQ base layers with no HDR10 fallback) route through `DolbyVisionStillConverter`, an optional component compiled only with the `DolbyVisionStillReshaping` package trait (off by default, [Installation › Optional components](installation.md#optional-components)).

- With the trait, the converter applies the RPU colour transform (`ycc_to_rgb` + PQ EOTF + the IPT-PQ LMS matrices carried in `AV_FRAME_DATA_DOVI_METADATA`) before tone-mapping, so their stills come out with correct colour instead of the green / magenta cast a plain YCbCr read produces.
- Built without it, such a source yields no still at all (nil, `supportsCacheBackedStills` false, no I-frame rendition, no held picture) rather than the planes read as YCbCr.

**Lifecycle.**

- `FrameExtractor` is an `actor`. Blocking FFmpeg work runs on a dedicated serial queue, never on the cooperative thread pool.
- The decode context opens lazily on first use.
- A superseded request (the common case during an active scrub) cancels the in-flight decode, so the latest position wins.
- Results land in a bounded LRU cache (snapshots and thumbnails kept in separate stores, thumbnails bucketed by second).
- After 10 s idle the context closes and the cache drops automatically. The next request reopens lazily.
- `shutdown()` is the explicit, permanent teardown.
- The engine does not retain the extractor returned by `makeFrameExtractor()`. The caller owns its lifecycle.

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

**Seeking.** A seek goes by the clips' EP maps (`BDMV/CLIPINF/*.clpi`): the folded title time names the clip, its `in_time` turns that into the clip's own clock, and the map gives the keyframe's byte. The seek is one byte reposition, and it holds on titles whose clips run their clocks over the same range, where a timestamp search lands in the wrong clip. A title with a clip that has no readable EP map seeks by timestamp.

**UHD Dolby Vision (AE#805).** A UHD clip's Dolby Vision lives in a second HEVC stream, the enhancement layer on PID `0x1015`, whose access units carry the RPUs. The base layer on `0x1011` carries none, and neither has a DOVI record.

- `BluRayDolbyVisionLayers` (in the demuxer) appends each RPU to the base picture with the same PTS, declares the base layer Profile 7 and keeps the enhancement packets to itself. So the clip takes the Profile 7 to 8.1 conversion like a remux, instead of playing as HDR10. On the 8.1 path the enhancement layer's pictures are not folded in.
- When the dual-layer route is wanted, the demuxer joins the two PIDs into one unit per picture instead (`DolbyVisionLayerJoin`, see [Dolby Vision FEL](dolby-vision-fel.md)), so a FEL clip takes the dual-layer route. A clip whose layers cannot be joined (a transport stream with no parameter sets in its record) still logs `not taken (enhancement layer on its own PID ...)`.
- A Matroska or MP4 file that carries the enhancement layer as a second video track (a `dvcC` record on each, the enhancement track declaring the enhancement layer only) is treated the same way.
- This applies to folders as well.

### Remote disc images (AE#860)

A remote disc image is recognized by:

- its `.iso` / `.img` / `.udf` extension, or
- on an extensionless URL, the `Content-Type` of the opening response: `application/x-iso9660-image`, `application/x-cd-image`, `application/vnd.efi.iso`, `application/x-udf-image`, `application/x-raw-disk-image`, or
- an `application/octet-stream` answer whose body has a volume descriptor identifier (`CD001`, `BEA01`, `NSR02`, `NSR03`) in sector 16, which is already in the opening buffer. No extra request is made for it.

The type or signature only routes the open to the disc adapter. The ISO 9660 / UDF structure decides, and a body without one plays as ordinary media.

It needs an origin that honours HTTP `Range`, because a disc image is a filesystem that only random access can walk. The range probe is judged at the response head: an origin that answers it with a 200 fails the load with an error naming the cause (the body is never downloaded), and a range answered wider than asked is cut where the range ends.

### Blu-ray folders

A disc ripped as a `BDMV` folder rather than an image plays the same way, through `MediaSource.custom` with a `DiscDirectoryReader`: the host lists the folder's files (path relative to the disc root, and size) and opens any one of them on request. `HTTPDiscDirectoryReader` is the ready-made one, with one URL per file, so an origin serves the disc as plain files over `Range` and never remuxes it.

Recognition is the image path with files in place of UDF extents:

- the same bounded playlist scan and title selection,
- the selected title's `.m2ts` files concatenated in playlist order as one MPEG-TS,
- the same multi-clip timeline, chapters and STN track languages,
- the same seek by the clips' EP maps when the folder carries `BDMV/CLIPINF`.

A host that already knows the main playlist names it in `preferredPlaylist`, and only that playlist is read and published as the title. The concatenating reader opens a clip's file when the read reaches it, and keeps at most three open. A controlled probe (`limits` or `cancellation`) does not recognize a folder yet. An uncontrolled `probe(source:)` and `load(source:)` do.

### DVD-Video folders

A listing that holds `VIDEO_TS/` files and no playable Blu-ray title is read as DVD-Video instead, by the same title-set code as an image. The selected title set's VOBs are concatenated in part order, which is the same run of bytes as their sectors on a disc, so the cell timeline and the VTS time map apply unchanged. `preferredPlaylist` does not apply.

### Title selection

- `engine.discTitles` (`@Published [TitleInfo]`) lists the disc's titles (id, name, duration, chapter count).
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

An MPEG-PS demuxer can meet a new stream at any packet, so libavformat never lets `find_stream_info` stop early on a DVD. With the playback budget that meant 50 MB read on every open, and a subtitle whose first packet came after it was not a track at all.

For a title whose VTS IFO is readable, the engine creates every subpicture stream the IFO declares before the probe. `mpegps` routes packets to an existing stream by id, and the engine joins each subpicture's PES fragments itself, because libavformat's `dvdsub` parser only attaches to streams the demuxer created. Such a title then probes 8 MB / 5 s (#651).

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

`MediaSource.custom(reader, formatHint:)` hands the engine a host-owned byte source: a memory buffer, an encrypted container, a tuner spool, anything that is not a plain URL.

- `read`, `seek` and `close` are required. `cancel()`, `makeIndependentReader()` and `discImageProbeEnabled` have defaults.
- Every call arrives on the engine's demux thread, never main, and inside an autorelease pool the engine opens. So a reader built on `FileHandle` or `NSData` does not strand one autoreleased object per read on a pump thread that runs for the length of a session (#445).

### `cancel()` unblocks, it does not invalidate

Its whole job is to wake a `read` that is parked, so teardown does not hang. A memory or file reader leaves it at the default no-op.

A reader the engine may rebuild in place must be able to serve again immediately afterwards, because the rebuild reuses it. Treating `cancel()` as terminal (the way a socket's in-flight-request cancel is terminal) is the difference between a rebuilt session and a dead one. What that death looks like depends on the reader's own convention, so one host defect has two signatures:

- A latched reader whose read returns a negative value: the reopen fails on its first read and the session lands in `.error` carrying libavformat's `Operation not permitted`.
- One that returns `0`: this is mapped to `AVERROR_EOF`, and the session ENDS instead of failing. On a live source that is a stream that was never supposed to have an end (cmcpherson274).

The engine cancels a reader it intends to reuse exactly once, before the successor opens.

### In-place rebuilds reuse the reader

`reloadAtCurrentPosition()` and `reloadAtCurrentPosition(applying:)`, an audio-track switch, a disc-title switch and a background return all tear the pipeline down and reopen on the retained reader instead of reopening a URL. So a custom source gets the same session-preserving rebuild a URL source does. Exceptions:

- The Profile 7 dual-layer route is decided by `load()`. `reloadAtCurrentPosition(applying:)` refuses a `preferDualLayerDolbyVision` change (or a `dolbyVisionHandling` change while the preference is on) on a custom Profile 7 source with `SessionReloadRefusal.dualLayerRouteNeedsFreshLoad`.
- A reader that reports itself non-seekable is refused (`SessionReloadRefusal.customSourceNotSeekable`), since the rebuild cannot reposition it.

### Where the reopen starts

A fresh `AVIOContext` always starts its byte axis at 0, so the reader's cursor and that axis have to agree. How depends on whether the source is live:

- **VOD.** The reader is rewound to 0 and the axis starts there. The reopen re-reads the container header, and the backend seeks to the resume position afterwards.
- **Live.** The reader is left exactly where the session left it, and the axis is moved to the cursor instead (`[Demuxer] live reopen aligned to the reader's cursor at N bytes`). A live source has kept receiving during the rebuild, so rewinding it would replay the host's whole delivered window: measured on `aetherctl customio --live`, the rewind dropped the playhead from 41.5 s to 1.9 s and asked the host to re-deliver 15 MB, a 61 s window, at I/O speed. Aligning instead makes the rebuild the edge rejoin `LiveReloadPolicy` already performs on the URL branch.

The live case has one cost: the reopen re-probes the container from a mid-stream byte offset, so it needs a source that can be joined there. MPEG-TS resyncs on its own sync bytes and recovers within a GOP. A live reader that will not answer `seek(0, SEEK_CUR)` cannot be aligned to, so it is rewound as a VOD source would be, and the engine says so rather than doing it silently.

### The axis a reader reports on is the axis it is asked on

The live alignment reads the cursor with `seek(0, SEEK_CUR)` and hands that number straight back as a `SEEK_SET`. The seekability probe makes the same round trip at every open, and libavformat's own probe seeks travel the same axis.

- **Both of these are fine:** absolute file offsets, and offsets counted from wherever this install's stream joined. A reader counting from its join is reported in that axis (`aligned to the reader's cursor at N bytes` carries bytes-since-join, not a position in a file).
- **What breaks:** reporting on one axis and taking `SEEK_SET` on the other. The round trip then MOVES the source by the join offset, on a probe whose whole purpose is that it moves nothing, and the session reads from a stretch the host has not delivered yet.

Both halves are checked:

- The probe compares its own return against the position it was just told. This costs no extra callback and fires on every open, including every in-place rebuild.
- The alignment asks once more where the reader is, so a live reopen never reports an alignment that did not hold.

```
[Demuxer] custom source: the reader reported byte 2097152 and answered a seek back to it with
4194304, so its position report and its SEEK_SET argument are not on the same axis; the source
has been repositioned by the seekability probe
```

### Host position arithmetic keyed to vending a stream

**A host whose own position arithmetic is keyed to vending a stream has to re-key it before opting into in-place rebuilds** (cmcpherson274's corollary, and the reason his wrapper still refuses one). A rebuild consumes no new stream. Anything a host initialises at the point it hands one over (a live clock baseline, a DVR join anchor, the per-stream ownership that makes an unguarded cursor safe) is not re-initialised by a rebuild, and will disagree with the session that comes back. The engine's alignment fixes the bytes. It cannot fix a clock it cannot see.

## Network sources (SMB)

The optional `AetherEngineSMB` product plays media off an SMB2/3 share through the normal decode path, with no server-side mount.

- `SMBConnection` (backed by [SMBClient](https://github.com/kishikawakatsumi/SMBClient), MIT, a pure-Swift SMB2 client over `NWConnection`) is a `ByteRangeSource`.
- `SMBIOReader` adapts it to the engine's `IOReader`, bridging each synchronous demux-thread read to SMBClient's async API across a happens-before semaphore edge.
- The reader is seekable, so audio-track switching, background reload, embedded subtitles and scrub previews all work (`makeIndependentReader()` opens a second cursor over the same connection).
- The connection is persistent (`SMBClient` plus a `FileReader`), and reads are serialised per connection, which clears typical media bitrates comfortably.
- The dependency is linked only by consumers of the `AetherEngineSMB` product, so the core engine and its tvOS hosts never pull it.
- SMBClient replaced AMSMB2/libsmb2, which `EPERM`s on tvOS / iOS.
- On tvOS the host supplies the local-network entitlement (and `NSLocalNetworkUsageDescription`) to reach a LAN share.

**Limits.**

- Read-only. No writing, locking, or directory browsing.
- NTLMv2 and guest auth only (no Kerberos, which tvOS lacks).
- SMBClient negotiates only SMB 2.0.2 and 2.1, so there is no SMB3 transport encryption or AES-CMAC signing. A server configured SMB3-only or with `smb encrypt = required` will not connect.

## Live ingest, AES-128, SSAI

### HLS live ingest

A live HLS upstream can be ingested directly via `HLSLiveIngestReader` (a public forward-only `IOReader`), with no media server in the data path.

- **Prefetch (#177).** Segments are fetched through a bounded prefetch pipeline (up to 4 in flight, committed to the byte stream strictly in playlist order), so per-segment connection + TTFB latency overlaps and high-bitrate channels buffer ahead of real time.
- **Supported:**
  - MPEG-TS segments, whole or as `EXT-X-BYTERANGE` sub-ranges of one resource (fetched with a `Range` request; an origin that answers 200 has the sub-range cut from the whole body),
  - demuxed-audio variants (`EXT-X-MEDIA` audio groups, fetched by a companion reader and merged by DTS). The rendition is the session's audio even when the variant's segments carry audio of their own, as RFC 8216 asks and AVPlayer does. On the native path only: the software path has no side-audio merge and keeps the variant's muxed audio,
  - packed-audio renditions (raw ADTS framed by ID3 timestamps),
  - AES-128 clear-key segments (below).
- **AES-128.** Clear-key segments (`EXT-X-KEY:METHOD=AES-128`, the standard FAST-channel scheme) are decrypted in-line by `HLSSegmentDecryptor`. The key is fetched once per clip and memoised, and each segment is decrypted (AES-128-CBC / PKCS7) before demux. This is standard HLS clear-key, not FairPlay / Widevine.
- **Refused** with a typed `HLSIngestError`, so the host can fall back to a server-mediated URL: SAMPLE-AES, keyless AES-128 (no `URI`), fMP4 playlists (`EXT-X-MAP`), and a key-fetch / decrypt failure.

### Server-side ad insertion (SSAI)

SSAI plays through the direct path instead of bouncing to a server transcode at the ad break. FAST channels (Pluto and similar) splice ad creatives that restart the source clock and often carry a different video PID, resolution and SPS than the program.

- The producer detects the program switch, parses the ad's SPS/PPS by hand (`H264SPS`) to build a fresh codec config, rotates the fMP4 muxer, and emits a versioned `#EXT-X-MAP` per discontinuity, so AVPlayer resyncs cleanly across the init and resolution change.
- Audio is re-anchored to the video timeline at every creative boundary (including amux creatives that mux audio on a separate source clock).
- With a demuxed audio rendition (Pluto TV: muxed programme segments, video-only ad segments, the sound of both in the rendition) the video PID switch works the same way, and the merge orders the two readers by clock run before timestamp. Both clocks restart at the seam, each reader reaches it on its own schedule, and ordering by timestamp alone handed out the ad before the end of the programme. Inside one run, two clocks more than 60 s apart (FFmpeg lifts the rendition's restart to 2^33 + x while the video stays at x) are compared by their distance from the run's first packets. A restart only one reader ever shows stops holding the other back after 10 s of its media. Every run change logs `merge clock run:`.
- An `OutputTimestampSanitizer` keeps the stream monotonic across the splice.

**Stall watchdog.** A no-cut stall watchdog sits underneath as a safety net. It tells a genuinely wedged pod (reading at full rate but unable to cut) from a slow source (a trickle) by read rate. A wedge-classified stall whose video PTS is still advancing (a source delivering just below real time, #177) is held with the watchdog re-armed (bounded consecutive holds) instead of retuned. Only a genuine wedge or an exhausted hold budget escalates to a host retune.

### Validation

The live path's sliding-window eviction (which bounds resident memory) and DVR rewind are confirmed on Apple TV against a real broadcast feed: `behindLiveSeconds` holds at real-time pacing, and the resident footprint stays bounded within the tvOS jetsam budget. The same behavior is exercised off-device through the `aetherctl live` / `hlsfixture` harnesses (sliding-window retention, real-time pacing, mid-stream reconnect, program-boundary discontinuities, DVR timeshift).

### Raw live MPEG-TS and the live join

Raw live MPEG-TS over HTTP (a tuner, a tuner proxy, or an IPTV panel's continuous form of a channel) is routed like any live source: the native loopback path, unless the codec, declared interlace or a host override sends it to the software path.

**Software join on raw MPEG-TS.** Such a stream opens with whatever the origin holds of the channel, sent at link speed (8 to 18 s on one IPTV panel). A software session no longer starts on the first packet of that burst, where it would run the whole burst behind the broadcast for as long as it played. Once the burst has landed, the live feeder places the start `SoftwareLiveJoinPolicy.leadSeconds` (4 s) behind the newest media, on a keyframe, and the burst stays in the rewind ring. (The native path's AVPlayer already sits a holdback behind the newest segment.)

**Software join on live HLS (AE#813).** A live HLS ingest on the software path delivers a whole segment at a time instead, so its holdback follows the segment length (`SoftwareLiveHoldback`):

- The join starts `1.5 x segment + 1 s` behind the newest media (4 s on 2 s segments, 16 s on 10 s segments, at most 45 s).
- A rebuffer resumes only once one segment plus 2 s stands ahead of the clock.
- Return to Live lands as far back as a join.
- The live-edge verdict counts that distance plus one segment as the edge (the next segment can land right after a placement).

Without it, a 4 s lead ran dry before every 10 s segment and the session stalled once per segment.

**Loading a live source.**

- Load it with `isLive: true` plus a `dvrWindowSeconds` for live semantics and the fastest open. An explicitly live load skips the open-time size probes entirely.
- `SourceProbe.isLive` flags no-duration network streams, so hosts can detect and reload.
- **Mid-stream joins (#107).** Sources joined mid-stream deliver their first samples at arbitrary PTS hours past zero. They anchor the clock at the first decoded sample on every session shape (live, live+DVR, and a plain VOD open of the same URL or of a mid-broadcast capture file), publishing session-relative positions while `sourceTime` stays on the source axis for subtitles.

## Known limitations

Things that work today but have a documented edge case, or are deferred behind an upstream dependency.

- **The channel bridge drops TrueHD Atmos objects and DTS:X heights.** TrueHD / MLP and DTS-HD sources route through the AudioBridge (FFmpeg's EAC3 encoder does not produce JOC, and FLAC has no object channels): bed channels and surround layout survive, objects and heights do not. `LoadOptions.objectAudioRendering = .apac(layout)` keeps them, in a build with the `TrueHDObjectAudio` / `DTSXObjectAudio` package traits (off by default, [Installation › Optional components](installation.md#optional-components)). They are built into a speaker bed from the stream's own lossless 7.1 and delivered as 24-bit PCM, or APAC over AirPlay, which tvOS sends to an Atmos receiver as Dolby MAT ([TrueHD Atmos with heights](#truehd-atmos-with-heights), [DTS:X with heights](#dtsx-with-heights)). EAC3+JOC stream copy from MKV / MP4 sources is intact either way.
- **`.surroundCompat` audio bridge caps 7.1 sources to 5.1.** FFmpeg's EAC3 encoder currently caps at 6 channels. Once [FFmpeg PR 21668](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/21668) lands, the cap and the dynamic bitrate auto-scale to 1024 kbps engage without a code change here. Use `.lossless` (FLAC) today if 7.1 matters.
- **Manual `MPNowPlayingInfoCenter` writes race the HLS-loopback path on tvOS 26.** The combination produces a `libdispatch` race.
  - `AVPlayerViewController` with its standard transport bar surfaces Now Playing on its own, through AVKit's private MediaRemote registration, and needs nothing from the host.
  - A host with a custom transport sets `engine.ownsVideoNowPlayingSession = true` before `load()`. The native host then owns an `MPNowPlayingSession` bound to its player (published as `videoNowPlayingSession`), registers transport commands on that session's `remoteCommandCenter`, and stages identity metadata through `setVideoNowPlayingInfo(_:)`, which is replayed onto every fresh `AVPlayerItem`. The session auto-publishes elapsed time, rate and duration from the player, so nothing writes `MPNowPlayingInfoCenter.default().nowPlayingInfo`.
  - The flag is off by default and must stay off under AVKit. Two owners produce a half-working state: an empty identity card displaces AVKit's, and remote commands route into a session with no handlers.
- **Audio session is activated per playback, not at process launch.**
  - The engine declares the `AVAudioSession` category (`.playback` / `.moviePlayback`) and multichannel support off-main at the first load in the process, once, and does NOT activate the session there.
  - The route-sharing policy is platform-split (#116): tvOS declares `.longFormAudio`, iOS declares `.default`. `.longFormAudio` marks the process as a long-form audio client and pins `AVPictureInPictureController.isPictureInPicturePossible` to false for any host-built PiP controller around the engine's player layer. Hosts do not need to re-declare the session for PiP.
  - Why not at launch: activating once at launch pinned the route to whatever the HDMI link reported at that instant. With tvOS Continuous Audio Connection off the link idles at stereo, so the launch-time activation negotiated the route to 2 channels and pinned it, downmixing non-Atmos multichannel for the whole session (AetherEngine#24).
  - The native video path lets the host's `AVPlayerViewController` activate the session per playback. The renderer paths (software decode, audio-only) activate it themselves, off the main actor and before their host is built (AE#538). Hosts that mount the engine's bare `AVPlayerLayer` instead of an `AVPlayerViewController` should make sure the session is active at playback.
  - A genuine sink-side ch=2 (an AVR caching its HDMI EDID incorrectly after standby) can still force a downmix. Power-cycling the sink restores it.
  - Atmos passthrough is unaffected either way, because EAC3+JOC ships as MAT 2.0 over a 2-channel carrier.
- **AV1 on Apple TV is software-decoded.** No current Apple TV chip ships hardware AV1. The `SoftwarePlaybackHost` + dav1d path handles it, but CPU use is meaningfully higher than hardware HEVC. Film grain and the P010 conversion run on the GPU, so what stays on the CPU is dav1d's decode. A Profile 10.1 source keeps its Dolby Vision there ([Dolby Vision signaling](#dolby-vision-signaling)). On iOS 17+ / macOS 14+ AV1 routes through Apple's hardware pipeline transparently. Future Apple TV chips with hardware AV1 will be picked up automatically by `VTCapabilityProbe`.
- **AV1 Dolby Vision Profile 10.0 has wrong colours when software-decoded.** dav1d / libavcodec cannot decode the proprietary DV colour space, so a Profile 10.0 source (DV-only, no fallback base layer) renders with incorrect colours on the software path. Profiles 10.1 and 10.4 are unaffected, because they carry an HDR10 / HLG base layer. Profile 10.0 only renders correctly through the native AVPlayer path on hosts with hardware AV1 decode.
- **Dolby Vision Profile 5 / AV1 Profile 10.0 thumbnails skip the RPU reshaping curves.** `FrameExtractor` applies the DV colour transform (from `AV_FRAME_DATA_DOVI_METADATA`), so P5 / P10.0 stills come out with correct colour, validated against a libplacebo render. The per-frame reshaping polynomials are intentionally not applied: they are not what causes the visible green / magenta corruption, and skipping them keeps this a lightweight CPU pass rather than a full Dolby Vision compositor. Brightness / contrast can therefore differ slightly from a fully graded DV render. A frame that carries no DV metadata falls back to the standard path.
