# Formats, codecs, and playback detail

Depth behind the README's "What it handles" matrix: codec routing, HDR signaling, audio bridging, subtitles, frame extraction, disc playback, and the documented edge cases. For the pipeline shapes these route through, see [docs/architecture.md](architecture.md).

## Containers and codecs

**Containers (demux side):** MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV.

**Hardware decode** (native AVPlayer path, VideoToolbox): H.264 (progressive), HEVC, HEVC Main10, on hardware whose VideoToolbox has a decoder for the specific profile. AV1 on devices with HW AV1 (M3+ Mac, iPhone 15 Pro+, future Apple TV chips) also routes natively.

**Software decode** (`SoftwareVideoDecoder` + `AVSampleBufferDisplayLayer`):

- AV1 (libavcodec / dav1d) on devices without HW AV1 (currently all Apple TVs, M1 / M2 Macs, pre-A17-Pro iPhones).
- VP9 and VP8 (libavcodec native) unconditionally, since AVPlayer's HLS pipeline rejects the `vp09` / `vp08` CODECS attributes even where VideoToolbox can HW-decode them.
- MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, and VC-1, none of which AVPlayer's HLS-fMP4 pipeline accepts; libavcodec ships native decoders for all three.
- Interlaced H.264 (declared field order TT / BB / TB / BT), so the deinterlacer below can run; tvOS AVPlayer does not deinterlace, so 1080i / 576i broadcast combs on the native path (#107).
- H.264 High 4:2:2 / 4:4:4 / High-10 and HEVC Rext (4:2:2 / 4:4:4 / 12-bit) on hardware whose VideoToolbox has no decoder for the profile (Intel Macs, older Apple TV chips). AVPlayer accepts these at the HLS CODECS level and the item reaches `readyToPlay`, but the native path then renders nothing, so a per-format `VTDecompressionSession` probe at load (`VTCapabilityProbe.canHardwareDecode`) routes them to libavcodec, which decodes them (#2). Apple Silicon has HW decoders for all of these and keeps them native.

Interlaced sources (DVD-rip MPEG-2, SD / HD broadcast H.264) are deinterlaced through a persistent bwdif graph (yadif fallback) that engages on the first interlaced frame and costs nothing on progressive content. The dispatch decision lives in `AetherEngine.load` (`VideoRoutingPolicy`), gated per source on `VTCapabilityProbe`, codec id, and declared field order.

## HDR routing

| Source | Wrapper signaling |
| --- | --- |
| H.264, HEVC (SDR) | BT.709 |
| HEVC Main10 (HDR10) | BT.2020 / PQ |
| HEVC Main10 (HDR10+) | BT.2020 / PQ + per-frame ST 2094-40 SEI stream-copied |
| HEVC Main10 (DV P5) | `dvh1` track type (DV-only, IPT-PQ base; forced even on SDR panels) |
| HEVC Main10 (DV P8.1 / P8.4 / P7) | `hvc1` primary + `dvvC` box, DV engaged via `SUPPLEMENTAL-CODECS` on DV panels, plain HDR10 / HLG base elsewhere |
| HEVC Main10 (HLG) | BT.2020 / HLG |
| AV1 HDR | BT.2020 / PQ |

HDR-to-SDR mapping is handled by AVPlayer and the system compositor according to the connected display. AetherEngine doesn't tonemap on the host; it tells the system "this is BT.2020 PQ" (or DV, or HLG) via the HLS-fMP4 sample description and lets tvOS / iOS pick the right path.

An HDR master playlist is only served when the panel is ready for it. On tvOS the external panel must already be in HDR mode or Match Dynamic Range must be on (an SDR-parked panel rejects an HDR master with `-11848`). On iOS and macOS the built-in panel engages EDR on demand with no display mode switch, so `AVPlayer.eligibleForHDRPlayback` counts as readiness there; SDR-only devices read ineligible and stay media-direct. `DisplayCriteriaController` issues the HDMI content-frame-rate and dynamic-range hint via `AVDisplayManager` before the first segment is fetched, so the receiver-side handshake is in flight by the time `AVPlayer` is ready to render. (For why this ordering is mandatory on tvOS, see the README's "Host setup on tvOS" section.) The per-mode capability split (Dolby Vision vs HDR10 vs HLG) still comes from `AVPlayer.availableHDRModes`; the 26 SDKs deprecate it in favor of the eligibility Bool but ship no per-mode replacement, and the DV5 `-11868` guard needs exactly that distinction, so the engine keeps the deprecated read until Apple obsoletes it. An HDR master additionally requires a known source frame rate (#130): AVPlayer filters a `VIDEO-RANGE=PQ`/`HLG` variant that carries no `FRAME-RATE` attribute out of the master at parse time and fails the item with `-1002` without ever fetching the media playlist (SDR variants are accepted without it). The manifest frame rate uses the probe's `avg_frame_rate` with an `r_frame_rate` fallback; a source where both are unset (some live MPEG-TS ingests) routes media-direct instead of serving a master AVPlayer provably rejects.

### Dolby Vision signaling

For DV streams the demuxer surfaces the source's `AVDOVIDecoderConfigurationRecord`, and the route depends on the profile's base-layer compatibility:

- **Profile 5** (DV-only, IPT-PQ, no base layer) emits a bare `dvh1.05.<dvLevel>` codec tag in the primary `CODECS` attribute with the `dvcC` box preserved. `dvh1` is forced even on non-DV panels (AVPlayer's system DV decoder tonemaps IPT-PQ internally; without `dvh1` the IPT chroma reads as YCbCr and shows a green / purple cast), so P5-on-non-DV is routed through a media playlist to dodge the `-11868` variant rejection.
- **Profiles 8.1 / 8.4** (HDR10- / HLG-compatible base) emit `hvc1.2.4.L<level>` as the primary `CODECS` tag. On a DV-capable display the muxer writes the `dvvC` box and the variant carries `dvh1.08.<dvLevel>/db1p` (8.1) or `/db4h` (8.4) in `SUPPLEMENTAL-CODECS`, which is what makes AVKit engage DV. On a non-DV display the `dvvC` is stripped (a lone `hvc1` + `dvvC` still trips `-11868`) and the stream plays as its plain HDR10 / HLG base with AVPlayer's tone-mapping.

AV1+DV emits a bare `dav1.10.<dvLevel>` primary for Profile 10.0 (DV-only) and Profile 10.1 (HDR10-compat base) with no supplemental entry, and an `av01...` primary plus `dav1.10.<dvLevel>/db4h` in `SUPPLEMENTAL-CODECS` for Profile 10.4 (HLG-compat base), on hardware-AV1 hosts.

**Profile 7** (dual-layer, the common UHD-Blu-ray remux profile) has no decoder on any Apple platform, so the engine converts it to single-layer **Profile 8.1** live during muxing: the RPU of each video packet is rewritten with [libdovi](https://github.com/superuser404notfound/LibDovi) (`dovi_convert_rpu_with_mode`, mode 2, the same transform as `dovi_tool -m 2`), the enhancement-layer NALs are dropped, and the container `dvvC` is set to Profile 8.1. On a DV-capable display this means real Dolby Vision (`dvh1.08/db1p` supplemental) instead of the plain HDR10 base; on a non-DV display Profile 7 still falls back to its HDR10 base, unchanged. The conversion is loss-free relative to what Apple could show before (the enhancement layer was never decodable on Apple hardware). MEL and FEL sources are both handled; a Full Enhancement Layer (FEL) source is logged, since its enhancement layer, which a native Profile 7 player would fold in, is discarded here while a Minimal (MEL) source loses nothing. Any per-packet conversion failure drops that RPU so the frame degrades to the clean HDR10 base, rather than shipping a Profile 7 RPU inside a container already declared 8.1.

**SDR-compatible-base profiles** (HEVC **Profile 8.2**, AV1 **Profile 10.2**) carry a Rec.709 base layer that no Apple platform has a DV decoder for. The engine strips the `dvcC` / DV config and plays the base as plain `hvc1` / `av01` (logging `not DV-routable, playing Rec.709 base`); there is no Dolby Vision on any display for these, on DV panels and SDR panels alike.

### HDR10+ dynamic metadata

ST 2094-40 metadata stays attached to the HEVC bitstream as user-data-registered ITU-T T.35 SEI NALs. The HLS-fMP4 stream-copy preserves the SEI through to `AVPlayer`, which forwards it to the system compositor. HDR10+-capable TVs apply the per-scene tone-mapping curves; HDR10-only TVs fall back to the static HDR10 base.

The published `videoFormat` starts at `.hdr10` for any BT.2020 / PQ source and flips to `.hdr10Plus` the first time a packet's T.35 SEI signature is seen in the producer's scan. Debounced across producer restarts so a scrub doesn't re-fire. Hosts can drive an HDR10+ badge or analytics hook off the `$videoFormat` transition.

## Audio

| | |
| --- | --- |
| Stream-copy (lossless into fMP4) | AAC-LC, AC3, EAC3, FLAC, ALAC. HE-AAC / HE-AACv2 stream-copy when the source carries an AudioSpecificConfig (any movie container) and bridge only without one (live ADTS / MPEG-TS, where a synthesized ASC would mis-signal SBR). LATM/LOAS-framed AAC (DVB broadcast framing) always bridges |
| Bridged (`AudioBridge`) | TrueHD, MLP, DTS, DTS-HD MA, MP3, MP2, Opus, Vorbis, PCM: decoded to PCM and re-encoded |
| Surround | 5.1 / 7.1 with correct `AudioChannelLayout` preserved through the wrapper |

Non-streamable codecs route through `AudioBridge` in one of two modes (`LoadOptions.audioBridgeMode`):

- **`.surroundCompat`** (default): lossy EAC3 at 128 kbps per channel (256 kbps stereo, 768 kbps 5.1). AVPlayer hands the encoded bitstream to HDMI and the sink decodes its own 5.1 mix, so surround works on essentially every modern AVR and soundbar (Sonos Arc, Samsung HW-Q, Bose).
- **`.lossless`** (opt-in): FLAC up to 7.1 lossless, which AVPlayer decodes to LPCM. Needs an AVR that accepts multichannel LPCM via HDMI (Denon, Marantz, NAD); on soundbars and basic AVRs that handle multichannel only via bitstream codecs the LPCM gets downmixed to stereo at the route.

`.surroundCompat` is the default because the soundbar / basic-AVR install base is the majority. Object metadata (Atmos / TrueHD-MA) is lost in either mode: FFmpeg's EAC3 encoder doesn't produce JOC, and FLAC has no object-channel concept. If a JOC source ever falls through to the bridge the engine logs a loud `WARNING: Atmos downgrade, ...`.

Two bridge lifecycle invariants (issue #99): the encoder PTS counter re-bases onto the first fed packet's (gate-shifted) source PTS on every session start and producer restart, so bridged audio always shares the video's output timeline, including a `load(startPosition:)` resume that anchors mid-file (a 0-based bridge timeline puts the audio track a full resume-offset away from video inside the same fragments, which AVPlayer silently discards). And the EOF tail flush leaves the encoder in FFmpeg's terminal draining state, so the bridge latches that and rebuilds the encoder on the next restart; a VOD pump that still dies with `muxerFailed` gets a bounded producer rebuild instead of stranding the session.

### Dolby Atmos

EAC3+JOC packets are stream-copied through the muxer untouched, on every output route. AVPlayer reads the segment, recognises JOC from the `dec3` box (`numDepSub=1`, `depChanLoc=0x0100`), and lets the downstream renderer decide: over HDMI it tunnels out as Dolby MAT 2.0 and the AVR lights up the Atmos indicator; over AirPods it renders spatially; over plain Bluetooth A2DP / LE it downmixes the bed channels to stereo natively. The route never changes the engine's decision (a JOC track is signaled in the playlist as `ec-3`, the same CODECS string as a non-JOC EAC3 5.1 track, so AVPlayer accepts it everywhere and the bitstream is never re-encoded for a route reason). The engine emits an explicit `[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged; ...` diagnostic on every Atmos session.

Matroska CodecPrivate doesn't usually carry the pre-parsed `dec3` / `dac3` box content the mov muxer needs at `avformat_write_header` time, so the muxer is configured with `+delay_moov` (alongside `+empty_moov+default_base_moof+frag_custom`). The moov atom is deferred until the first fragment-cut flush, by which point packets have flowed through `mov_write_packet` and libavformat's `handle_eac3` / `handle_ac3` have populated the sample-entry boxes from the actual packet bitstream. The first cut emits the deferred ftyp+moov (routed by `FragmentSplitter` to init.mp4); subsequent cuts emit normal moof+mdat. Net effect: EAC3 / AC3 from matroska direct-play stream-copies cleanly with valid sample-entries, no manual bitstream parsing on the host side.

## Subtitles

Subtitle cues come from one read: EVERY embedded subtitle stream (text and bitmap) stays in the session demuxer's keep-set and is harvested by a tap on the host's existing source read (each packet is observed then dropped, never muxed). Harvested packets are retained compressed in a per-session `SubtitlePacketStore` (300 s trailing window, byte-capped per stream) and a playhead-paced drainer decodes the selected stream near the playhead into the overlay. PGS streams in MPEG-TS (Blu-ray) arrive as one display set split across several PES packets (PCS|WDS|PDS|ODS|END, some without a PTS of their own); the store reassembles those chunks into one self-contained entry at the PCS presentation PTS before retention, so the drainer always decodes complete display sets (Matroska already carries one complete set per packet and is stored as-is), so enabling any embedded track is instant: the selection backfills synchronously from the store, with no positioning seek and no recovery machinery, even on remote disc images; the tap re-attaches with the producer across seeks and restarts. The tap's forward coverage ends at the producer's read position (its forward park, #102), which on direct play sits only a few seconds past the playhead; on VOD sessions a background subtitle-only side reader (the forward prefetcher, #151) therefore extends the store to the drainer's full 60 s lead window (raised to 270 s while a bitmap track's OCR rendition is armed, so the store covers the OCR worker's 240 s window), so `subtitleCues` holds cues ahead of the playhead for a host-applied ADVANCE sync offset, text and bitmap alike (live sessions skip it; content past the edge does not exist). It is best-effort: if it cannot open or wedges, the tap-fed behavior above is unchanged. Sidecars are fetched once. Each packet decodes through `avcodec_decode_subtitle2` (except in-band CEA-608, which has an in-house line-21 decoder, see below), and the result lands in a single `[SubtitleCue]` published list:

- **Text codecs** (SubRip / ASS / SSA / WebVTT / mov_text) → `SubtitleCue.body = .text(String)`. ASS dialogue headers and override blocks (`{\an8}`, `{\b1}`, ...) are stripped; `\N` becomes a real newline so the host can render with regular text layout. DVB teletext subtitles (live broadcast) decode through libzvbi (`libzvbi_teletextdec`, configured to emit ASS so the per-character colour broadcasters use to distinguish speakers survives rather than being flattened) with page-state semantics (#107). A page carrying colour publishes as `SubtitleCue.body = .richText([SubtitleTextRun])` (each run an optional RGB `SubtitleColor`, nil meaning the host default); a page with no colour stays plain `.text`, and `cue.text` flattens either form for consumers that do not render colour. The decoded page defaults to libzvbi's auto-detected subtitle page, overridable per channel via `LoadOptions.teletextPage` (for example AU page 801, which libzvbi does not always flag as a subtitle page). libzvbi emits page content open-ended ("valid until replaced") and page erases as empty events, so every teletext event trims earlier open cues at its start; roll-up captions build and replace cleanly, an erase clears the line, and a 120 s cap bounds a ghost line if transmission stops without either. Validated end to end against Australian FTA broadcasts (1080i25 H.264, captions on page 801), where the interlaced video deinterlaces through the software path's bwdif filter.
- **Bitmap codecs** (PGS / HDMV PGS / DVB / DVD) → `.image(SubtitleImage)`. The indexed pixel plane is walked through its palette, premultiplied against alpha, and wrapped as a `CGImage`. Position is normalised in `[0..1]` against the composition canvas, whose coded pixel size rides along as `SubtitleImage.canvasSize` (#112): a cropped-video rip can author a canvas taller than the coded video, so hosts map the canvas width-aligned and center-anchored onto the on-screen video rect to land cues where the disc authored them; `.zero` means treat canvas == video. A display set carrying multiple composition objects (a forced sign plus dialogue is a common real-disc shape) fans into one cue per object, all sharing the set's start PTS, and every object is retained and rendered (#146); each object's `AV_SUBTITLE_FLAG_FORCED` rides along as `SubtitleImage.isForced`, surfaced per cue via `SubtitleCue.isForced` (track-level forcedness stays on `TrackInfo.isForced`).
- **External files** (a separate `.srt` / `.ass` / `.vtt` URL) → register as first-class tracks (see below) or one-shot via `selectSidecarSubtitle(url:httpHeaders:)`, which opens its own short-lived `AVFormatContext`, decodes the whole file once, atomically swaps the result into `subtitleCues`. The fetch forwards the session's `LoadOptions.httpHeaders` by default (WebDAV auth and friends); pass the call's own `httpHeaders` to override per fetch.
- **In-band CEA-608 closed captions** (`eia_608` / QuickTime `c608`, a demuxable caption track) → `.text(String)`. FFmpegBuild ships no `ccaption` decoder, so these never reach `avcodec_decode_subtitle2`. Instead a read-only tap on the segment producer's existing source connection reads the caption track's `cc_data` (its packets are kept in the demuxer's keep-set, observed, then dropped, never muxed, so the loopback-HLS output stays byte-identical), an in-house line-21 decoder (validated against FFmpeg's `ccaption_dec.c`) turns it into cues, and they publish on the same `subtitleCues` overlay path as every other codec. First cut: field-1 / channel CC1; CEA-708 (DTVCC) and field 2 are follow-ons. Captions carried only inside the video bitstream (ATSC A/53 `cc_data`, the US broadcast/cable case) are extracted too (#131): on the native remux path the segment producer scans H.264/HEVC video packets for `user_data_registered_itu_t_t35` SEI (GA94), reorders the decode-order groups to presentation order by the packet DTS watermark, and feeds the same line-21 decoder; on the software-decode path (MPEG-2 and friends) the triplets come from `AV_FRAME_DATA_A53_CC` decoded-frame side data. Since no caption AVStream exists, a synthetic `eia_608` track (id 99608) surfaces lazily on the first real (non-padding) caption pair, so uncaptioned channels never show a dead menu entry. Host-overlay only (no PiP / AirPlay), like the bitmap codecs. (#77)

### External subtitle files as first-class tracks

External subtitle files register with the engine and appear in `subtitleTracks` next to the embedded streams, so a host keeps one track list and one selection call (#88):

- **Registration.** `LoadOptions.externalSubtitles: [ExternalSubtitleTrack]` declares files at load; `addExternalSubtitleTrack(_:)` registers any time mid-session (returns the created `TrackInfo`). The descriptor carries `url`, optional `name` / `language` / disposition flags, per-track `httpHeaders` (nil forwards the session's), and a `formatHint` for URLs whose path hides the extension.
- **Identity.** External `TrackInfo.id`s are synthetic: `AetherEngine.externalSubtitleTrackIDBase` (100 000) + registration ordinal, monotonic per load; load-declared tracks get `base + array index` in order. `TrackInfo.isExternal` distinguishes them from AVStream-indexed embedded tracks.
- **Selection.** `selectSubtitleTrack(index:)` and `selectSecondarySubtitleTrack(index:)` accept external ids and route onto the whole-file decode internally; `activeSubtitleTrackIndex` publishes the external id like any other selection. `removeExternalSubtitleTrack(id:)` unregisters (an active selection is cleared).
- **Renditions.** Load-declared external tracks join the native WebVTT renditions (next section): their store is filled by one whole-file decode at load and marked finished, and a finished store also backfills the fullscreen overlay instantly on select (no re-download; styled-ASS selections re-decode to keep raw markup). Tracks added after load are host-overlay only until the next load, because the rendition set is fixed in the master playlist at item creation.
- **Preferences.** `preferredSubtitleLanguages` ranks external tracks together with embedded ones. A track added mid-session re-runs the preference and auto-activates on a match, but only while the host has made no explicit subtitle call (select / sidecar / clear) in the session, so a deliberate subtitles-off stays off.

### Track selection by language preference

`LoadOptions` can seed the initial audio and subtitle tracks from an ordered language preference, resolved from the engine's single probe so a host honors a saved preference without a separate pre-probe or a post-load reload:

- **`preferredAudioLanguages`** (ordered ISO 639-1 / 639-2 codes or English names, e.g. `["en", "de"]`) picks the first-frame audio track: an explicit `audioSourceStreamIndex` wins, else the first track matching a preference in order, else the container default. The pick is muxed into the loopback HLS, so it is correct on the first frame with no `selectAudioTrack` reload.
- **`preferredSubtitleLanguages`** activates a subtitle at the end of load. Within the first preference that has a match, it picks the *best* track by container disposition: full subtitles rank over SDH (`HEARING_IMPAIRED`), forced, and commentary (`COMMENT`), and text over bitmap. No match leaves subtitles off. It drives the host-overlay path, so unlike audio it needs no reload regardless; it only spares a host from language-matching `subtitleTracks` itself. The native menu (below) keeps its own host-driven default selection via `setNativeSubtitleSelected(track:)`.

Matching is case-insensitive across ISO 639-1, 639-2/B, 639-2/T, and English names (`en` == `eng` == `english`); preference order dominates, so an earlier preference on a later track still wins. The resolved tracks are published on `player.activeAudioTrackIndex` / `player.activeSubtitleTrackIndex` (both match `TrackInfo.id`), and every `TrackInfo` carries `isDefault` / `isForced` / `isHearingImpaired` / `isCommentary` (from container dispositions) so a host can rank or filter the track lists the same way.

### Second simultaneous subtitle track (bilingual)

A second subtitle channel can run alongside the primary for bilingual playback / language learning: `selectSecondarySubtitleTrack(index:)` for an embedded track and `selectSecondarySidecarSubtitle(url:httpHeaders:)` for a sidecar file, mirroring the primary API. Its cues land in a separate `@Published secondarySubtitleCues` list (so the host can render the two channels independently, e.g. top vs bottom), with `isSecondarySubtitleActive` and `isLoadingSecondarySubtitles` for UI state; `clearSecondarySubtitle()` tears it down. The secondary channel decodes through the same demux loop and PTS rules as the primary.

A single packet that carries multiple rects (PGS often emits signs/songs at the top alongside dialogue at the bottom) becomes multiple cues at the same time range, and the host renders all of them. Cues are inserted in sorted order; re-emitted events after a seek dedupe by time range plus content (so two simultaneous speaker lines with identical timing both survive) and the list doesn't grow on rewind.

Subtitle cues land in raw source PTS. On the native path, AVPlayer's HLS clock sits at `source_pts - producer.videoShiftPts` (the producer applies a per-session shift to align the first segment's tfdt with the playlist origin, and the shift can change on every restart). Render the overlay against `player.sourceTime` so cues match the spoken audio regardless of which producer session is active.

### Native subtitle renditions (WebVTT for PiP, AirPlay, and external display)

Host-rendered subtitle overlays are invisible in Picture-in-Picture, AirPlay, and external-display sessions because those paths render the `AVPlayerLayer` content only; the SwiftUI / UIKit view tree is not composited. The engine therefore serves every text subtitle track as a real HLS `SUBTITLES` rendition over the loopback: the master playlist carries one language-tagged `EXT-X-MEDIA:TYPE=SUBTITLES` entry per track (`DEFAULT=NO,AUTOSELECT=NO`) plus `SUBTITLES="subs"` on the variant, backed by a per-track media playlist (`subs_N.m3u8`) whose WebVTT segments mirror the video segments 1:1. AVFoundation exposes the renditions as a standard legible `AVMediaSelection` group that travels with the stream everywhere `AVPlayer` goes, including PiP. (An earlier design muxed `mov_text`/tx3g traks into the fMP4 itself; in-band timed text is not HLS-conformant and AVPlayer rejected the stream, so the WebVTT rendition replaced it.)

**Opt-in.** Off by default (`LoadOptions.prepareNativeSubtitles = false`): no renditions in the master, no legible menu, output identical to before.

**Cue source: the producer pump tap.** The segment producer already reads the source's full interleave, so the text subtitle streams stay in its keep-set and every packet is handed to a session-level tap that decodes into per-track cue stores (the same pattern as the CEA-608 tap). Zero side-channel bandwidth, and coverage is by construction the produced region, across seeks and producer restarts. The host overlay is fed separately, by the packet-store drainer (#112 rework, see [Subtitles](#subtitles) above); a lazy per-selection reader still covers AVKit's ~240 s forward `.vtt` prefetch beyond the produced region. Load-declared external tracks (#88) have no demuxable stream to tap; their store is filled by one whole-file decode at load and marked finished, so their rendition serves complete `.vtt` files from the start.

**Routing scope.** A `SUBTITLES` rendition can only live in a master playlist, so native subtitles ride the master-routing rules: SDR sources on any panel, HDR / DV sources on HDR-ready panels. HDR-on-SDR-panel and DV Profile 5 on non-DV panels stay media-direct (no master, hence no native subtitles there); the host overlay still covers fullscreen. Bitmap subtitles (PGS / DVB / DVD) join as OCR-fed renditions: while a bitmap track is selected, a worker decodes its harvested packets ahead of the playhead (composition ends resolved at the next composition/clear event, the 5.14.1 sidecar semantics) and recognizes them on-device (Vision, track-language hinted) into plain-text cues for the track's rendition. Recognition is lossy by design; a failed or empty read drops that line from the rendition while fullscreen keeps the pixel-accurate bitmap overlay. External .sup sidecars fill their store from the selection-time sidecar decode's own image cues (no second fetch). Live sources are out of scope.

**Master-rejection fallback (#98, #130).** When AVPlayer rejects the served master (`-11868` AVErrorNoCompatibleAlternatesForExternalDisplay, `-11848` for an SDR-parked panel, or `-1002` when every variant was filtered at master parse time), the engine reloads the bare media playlist in place; a live session rejoins at the edge instead of replaying its stale start position. HDR / DV on an SDR external display is therefore media-playlist-driven (an AVKit limitation: forcing `VIDEO-RANGE=SDR` does not fool the external-display compatibility gate, which checks the real `colr` / codec rather than the manifest string), so the `SUBTITLES` renditions do not travel there. The separate `#35` cold-DV-start readiness gate, whose scenario is an HDR TV, first tries an HDR-preserving reduced master (`SUPPLEMENTAL-CODECS` dropped so it is plain HDR10, source range and `SUBTITLES` group kept) before the bare media playlist, so a cold DV start keeps HDR10 plus subtitles instead of dropping straight to subtitle-less media.

**Rich ASS styling.** With `LoadOptions.preserveASSMarkup` the tap keeps raw ASS event lines so the host overlay renders full styling (positions, colours); the WebVTT renditions strip the markup at serve time, so PiP shows plain text in the system caption style.

**Timing.** Served cues are on the AVPlayer clock axis, and producer restarts are timeline-exact (see [architecture](architecture.md)), so cues stay in sync with the picture across seeks and restarts.

**Selection: deliberately not automatic.** The renditions ship `DEFAULT=NO,AUTOSELECT=NO` so AVKit never engages one on its own and a host overlay never double-renders in fullscreen. A host that shows AVKit's stock chrome can still let the user pick from the native legible menu; Sodalite-style hosts select programmatically per surface instead.

**Selection: host-driven API.** These members on `AetherEngine` drive the native renditions programmatically:

```swift
// true once cues from at least one text track are decoded into the native stores
engine.$nativeSubtitleRenditionAvailable   // @Published var Bool

// true while the loopback session serves a master carrying the SUBTITLES group;
// goes false on a media-playlist fallback. Hosts use it to decide whether to draw
// their own subtitle window on a wired external display instead (#98)
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

1. Observe `$nativeSubtitleRenditionAvailable` (waits for the first cues to be ready before activating).
2. On entering PiP / AirPlay / external display: call `setNativeSubtitleRendering(true)` (or resolve the ordinal yourself via `setNativeSubtitleSelected(track:)`), and hide the host overlay.
3. On leaving: call `setNativeSubtitleRendering(false)` and re-enable the host overlay.

This avoids double subtitles during inline playback (where the host overlay is already painting them) and ensures the user sees subtitles the moment the stream is mirrored or sent to PiP.

**Device-verification checklist** (required before tagging a release):

- Selecting a rendition displays it in the PiP window and survives seeks (including seeks that restart the producer).
- Inline host ASS rendering unchanged: rich styling intact, tap-fed cues appear instantly on selection.
- No double subtitles while inline; no rendition is auto-selected on session start.
- Timing: no constant offset between audio and subtitle cues, before and after seeks.
- SDR / HDR10 picture behavior unchanged with `prepareNativeSubtitles = true` (the renditions only add master tags + subtitle endpoints).
- HDR-on-SDR-panel and DV Profile 5 on non-DV panels still play (media-direct, no renditions there by design).
- Memory bounded by total cue count across all tracks.

### Authored ASS styling

Hosts that render authored ASS styling themselves (positioning, speaker colours, karaoke) opt out of the stripping with `LoadOptions(preserveASSMarkup: true)`: cues then carry the raw event line (override tags, style references, escapes intact), the script header (`[Script Info]` + `[V4+ Styles]`) is surfaced, and `engine.fontAttachments` carries the container's embedded fonts (TTF / OTF) for the renderer's font directory. `ASSScriptBuilder` reassembles raw event cues + header into a complete script for whole-file renderers such as swift-ass-renderer's `loadTrack(content:)`, hardened against real-world Matroska tracks (synthesized `[Events]` section, NUL stripping, content-keyed dedupe since real files hardcode `ReadOrder: 0`).

The header arrives differently per source: embedded tracks carry it on `TrackInfo.assHeader`, and external `.ass` / `.ssa` sidecars loaded through `selectSidecarSubtitle(url:)` under the same `preserveASSMarkup` flag carry it on `engine.sidecarASSHeader` (extracted from the file's subtitle-stream extradata; nil for SRT / VTT and when preservation is off). Both pair with the raw event-line cues the same way (AetherEngine#48).

The host stays in charge of the actual paint: text styling, overlay layout, fade transitions, position scaling against the on-screen video rect.

## Frame extraction

`FrameExtractor` produces still `CGImage`s from a media URL through an FFmpeg decode context that is fully isolated from playback. It never touches the playback pipeline, the HLS loopback server, or the engine's shared state, so a scrub-preview decode can't perturb the frame on screen. Two modes share one decode core:

- **`thumbnail(at:maxWidth:)`**: seeks to the nearest keyframe, no forward decode, downscaled to `maxWidth` (default 320). Cheap and fast; built for scrub previews and Recents lists.
- **`snapshot(at:maxSize:)`**: decodes forward to the exact PTS, full or `maxSize`-clamped resolution. Built for user-triggered stills.

```swift
let frames = engine.makeFrameExtractor()           // nil if nothing is loaded
// or, for an arbitrary item (e.g. a Recents row):
let frames = FrameExtractor(url: url, httpHeaders: headers)

await frames.prewarm()                             // optional: hide cold-start at gesture begin
let preview = await frames.thumbnail(at: 612.0)    // CGImage?, nearest keyframe
let still   = await frames.snapshot(at: 612.0)     // CGImage?, frame-accurate
await frames.shutdown()                            // prompt teardown of the decode context
```

HDR sources come out looking right: PQ / HLG BT.2020 frames are tone-mapped to SDR BT.709 through a zscale + tonemap libavfilter graph before the `CGImage` is built, so HDR10 / HLG / DV P8.x stills match what the user sees instead of washed-out grey. Dolby Vision Profile 5 and AV1 Profile 10.0 (IPT-PQ base layers with no HDR10 fallback) route through `DolbyVisionStillConverter`, which applies the RPU colour transform (`ycc_to_rgb` + PQ EOTF + the IPT-PQ LMS matrices carried in `AV_FRAME_DATA_DOVI_METADATA`) before tone-mapping, so their stills come out with correct colour instead of the green / magenta cast a plain YCbCr read produces.

`FrameExtractor` is an `actor`. Blocking FFmpeg work runs on a dedicated serial queue, never on the cooperative thread pool. The decode context opens lazily on first use; a superseded request (the common case during an active scrub) cancels the in-flight decode so the latest position wins. Results land in a bounded LRU cache (snapshots and thumbnails kept in separate stores, thumbnails bucketed by second). After 10 s idle the context closes and the cache drops automatically; the next request reopens lazily. `shutdown()` is the explicit, permanent teardown. The engine does not retain the extractor returned by `makeFrameExtractor()`; the caller owns its lifecycle.

## Disc (DVD / Blu-ray ISO)

Decrypted disc images play through the normal decode path via a synthetic seekable byte source. `DiscReader` detects and routes both local `.iso` URLs and `MediaSource.custom` ISO readers.

- **DVD-Video ISO:** `ISO9660Reader` reads the ISO9660 bridge filesystem, `DVDIFOParser` reads the VMGI (VIDEO_TS.IFO) TT_SRPT to enumerate the disc's titles and each title set's VTS IFO (VTS_NN_0.IFO) program chain for the title duration and chapters, `DVDTitleSelector` groups each title set's content VOBs (whole-VTS, largest first), and `ConcatIOReader` presents the selected title's concatenated VOBs as one seekable source demuxed as MPEG-PS. On an unreadable VMGI it falls back to the VOB-size grouping; an unreadable VTS IFO leaves the title's duration and chapters empty but still plays.
- **Blu-ray ISO:** a read-only `UDFReader` (UDF 2.50, including the metadata partition and fragmented-file allocation descriptors) resolves BDMV, `MPLSParser` + `BDTitleSelector` enumerate every `.mpls` playlist as a selectable title (longest first so id 0 is the main feature; trivially short menu / FBI-warning playlists filtered), and the selected title's `.m2ts` clips are concatenated and demuxed as MPEG-TS (H.264 / HEVC / VC-1, AC3 / EAC3 / DTS / TrueHD / LPCM, PGS subtitles).

Both: no decryption (CSS / AACS retail discs must be ripped decrypted first), no GPL nav libraries, no menus, BD-J, or multi-angle.

**Title selection.** `engine.discTitles` (`@Published [TitleInfo]`) lists the disc's titles (id, name, duration, chapter count) and `engine.selectedDiscTitle` is the active one; `engine.selectTitle(id:)` switches title, rebuilding the pipeline from the new title's head. The selection survives audio-track switches and background-resume reloads, and a fresh `load` defaults to the main title (an out-of-range id clamps to it). Blu-ray enumerates all playlists; a DVD enumerates its title sets (the VMGI TT_SRPT title list, resolved whole-VTS, with the duration read from each VTS's main program chain; per-cell / episodic splitting is deferred).

**Chapters.** `engine.discChapters` (`@Published [ChapterInfo]`) carries the selected title's chapters; `engine.selectChapter(id:)` seeks to one (a thin `seek` wrapper, no pipeline rebuild). For Blu-ray they come from the playlist's PlayListMark entries (entry marks only; link points dropped), each mark's timestamp on its clip's STC offset by the clip's in_time and the cumulative duration of preceding play items. For DVD they come from the main program chain's program map plus the cumulative cell playback times. Chapter starts are title-relative (0-based); `selectChapter` adds the title's content-start base (the native playlist shift, or the software path's container start PTS) so the seek lands on the source-PTS playback axis.

## Network sources (SMB)

The optional `AetherEngineSMB` product plays media off an SMB2/3 share through the normal decode path, no server-side mount. `SMBConnection` (backed by [SMBClient](https://github.com/kishikawakatsumi/SMBClient), MIT, a pure-Swift SMB2 client over `NWConnection`) is a `ByteRangeSource`; `SMBIOReader` adapts it to the engine's `IOReader`, bridging each synchronous demux-thread read to SMBClient's async API across a happens-before semaphore edge. The reader is seekable, so audio-track switching, background reload, embedded subtitles, and scrub previews all work (`makeIndependentReader()` opens a second cursor over the same connection).

Read-only. NTLMv2 and guest auth (no Kerberos, which tvOS lacks). No writing, locking, or directory browsing. SMBClient negotiates only SMB 2.0.2 and 2.1, so there is no SMB3 transport encryption or AES-CMAC signing; a server configured SMB3-only or with `smb encrypt = required` won't connect. The connection is persistent (`SMBClient` plus a `FileReader`) and reads are serialised per connection, which clears typical media bitrates comfortably. The dependency is linked only by consumers of the `AetherEngineSMB` product, so the core engine and its tvOS hosts never pull it. SMBClient replaced AMSMB2/libsmb2, which `EPERM`s on tvOS / iOS. On tvOS the host supplies the local-network entitlement (and `NSLocalNetworkUsageDescription`) to reach a LAN share.

## Live ingest, AES-128, SSAI

A live HLS upstream can be ingested directly via `HLSLiveIngestReader` (a public forward-only `IOReader`), no media server in the data path. Segments are fetched through a bounded prefetch pipeline (up to 4 in flight, committed to the byte stream strictly in playlist order), so per-segment connection + TTFB latency overlaps and high-bitrate channels buffer ahead of real time (#177). Contract: MPEG-TS segments, including demuxed-audio variants (`EXT-X-MEDIA` audio groups, fetched by a companion reader and merged by DTS) and packed-audio renditions (raw ADTS framed by ID3 timestamps). AES-128 clear-key segments (`EXT-X-KEY:METHOD=AES-128`, the standard FAST-channel scheme) are decrypted in-line by `HLSSegmentDecryptor`: the key is fetched once per clip and memoised, each segment decrypted (AES-128-CBC / PKCS7) before demux. SAMPLE-AES / keyless AES-128 (no `URI`), fMP4 playlists (`EXT-X-MAP`), and a key-fetch / decrypt failure terminate with a typed `HLSIngestError` so the host can fall back to a server-mediated URL. This is standard HLS clear-key, not FairPlay / Widevine.

Server-side ad insertion (SSAI) plays through the direct path instead of bouncing to a server transcode at the ad break. FAST channels (Pluto and similar) splice ad creatives that restart the source clock and often carry a different video PID, resolution, and SPS than the program. The producer detects the program switch, parses the ad's SPS/PPS by hand (`H264SPS`) to build a fresh codec config, rotates the fMP4 muxer, and emits a versioned `#EXT-X-MAP` per discontinuity so AVPlayer resyncs cleanly across the init and resolution change; audio is re-anchored to the video timeline at every creative boundary (including amux creatives that mux audio on a separate source clock) and an `OutputTimestampSanitizer` keeps the stream monotonic across the splice. A no-cut stall watchdog sits underneath as a safety net: it tells a genuinely wedged pod (reading at full rate but unable to cut) from a slow source (a trickle) by read rate, and a wedge-classified stall whose video PTS is still advancing (a source delivering just below real time, #177) is held with the watchdog re-armed (bounded consecutive holds) instead of retuned; only a genuine wedge or an exhausted hold budget escalates to a host retune.

The live path's sliding-window eviction (which bounds resident memory) and DVR rewind are confirmed on Apple TV against a real broadcast feed: `behindLiveSeconds` holds at real-time pacing and the resident footprint stays bounded within the tvOS jetsam budget. The same behavior is exercised off-device through the `aetherctl live` / `hlsfixture` harnesses (sliding-window retention, real-time pacing, mid-stream reconnect, program-boundary discontinuities, DVR timeshift).

Raw live MPEG-TS over HTTP (a tuner or tuner proxy serving the transport stream directly, no HLS) plays on the software path; the forward-only reader routes it there automatically. Load it with `isLive: true` plus a `dvrWindowSeconds` for live semantics and the fastest open (an explicitly live load skips the open-time size probes entirely); `SourceProbe.isLive` flags no-duration network streams so hosts can detect and reload. Mid-stream-joined sources, which deliver their first samples at arbitrary PTS hours past zero, anchor the clock at the first decoded sample on every session shape (live, live+DVR, and a plain VOD open of the same URL or of a mid-broadcast capture file), publishing session-relative positions while `sourceTime` stays on the source axis for subtitles (#107).

## Known limitations

Things that work today but have a documented edge case, or are deferred behind an upstream dependency:

- **TrueHD-MAT Atmos object metadata is not preserved.** TrueHD / MLP sources route through the AudioBridge (FFmpeg's EAC3 encoder doesn't produce JOC). Bed channels and surround layout survive; object metadata is dropped. EAC3+JOC stream-copy from MKV / MP4 sources is intact.
- **`.surroundCompat` audio bridge caps 7.1 sources to 5.1.** FFmpeg's EAC3 encoder currently caps at 6 channels. Once [FFmpeg PR 21668](https://github.com/FFmpeg/FFmpeg/pull/21668) lands the cap and the dynamic bitrate auto-scale to 1024 kbps engage without a code change here. Use `.lossless` (FLAC) today if 7.1 matters.
- **Manual `MPNowPlayingInfoCenter` writes race the HLS-loopback path on tvOS 26.** The combination produces a `libdispatch` race. Only `AVPlayerViewController` with its standard transport bar safely surfaces Now Playing. Hosts that need a custom transport should use `MPNowPlayingSession` against the engine's `currentAVPlayer` publisher instead of `MPNowPlayingInfoCenter.default().nowPlayingInfo`.
- **Audio session is activated per playback, not at process launch.** The engine declares the `AVAudioSession` category (`.playback` / `.moviePlayback`) and multichannel support at init, but does NOT activate the session there. The route-sharing policy is platform-split (#116): tvOS declares `.longFormAudio`, iOS declares `.default`, because `.longFormAudio` marks the process as a long-form audio client and pins `AVPictureInPictureController.isPictureInPicturePossible` to false for any host-built PiP controller around the engine's player layer. Hosts do not need to re-declare the session for PiP. Activating once at launch used to pin the route to whatever the HDMI link reported at that instant: with tvOS Continuous Audio Connection off the link idles at stereo, so the launch-time activation negotiated the route to 2 channels and pinned it, downmixing non-Atmos multichannel for the whole session (AetherEngine#24). The native video path now lets the host's `AVPlayerViewController` activate the session per playback; the renderer paths (software decode, audio-only) activate it themselves. Hosts that mount the engine's bare `AVPlayerLayer` instead of an `AVPlayerViewController` should ensure the session is active at playback. A genuine sink-side ch=2 (an AVR caching its HDMI EDID incorrectly after standby) can still force a downmix; power-cycling the sink restores it. Atmos passthrough is unaffected either way because EAC3+JOC ships as MAT 2.0 over a 2-channel carrier.
- **AV1 on Apple TV is software-decoded.** No current Apple TV chip ships HW AV1. The `SoftwarePlaybackHost` + dav1d path handles it, but CPU use is meaningfully higher than HW HEVC. On iOS 17+ / macOS 14+ AV1 routes through Apple's HW pipeline transparently. Future Apple TV chips with HW AV1 will be picked up automatically by `VTCapabilityProbe`.
- **AV1 Dolby Vision Profile 10.0 has wrong colours when software-decoded.** dav1d / libavcodec cannot decode the proprietary DV colour space, so a Profile 10.0 source (DV-only, no fallback base layer) renders with incorrect colours on the SW path. Profiles 10.1 and 10.4 are unaffected because they carry an HDR10 / HLG base layer. Profile 10.0 only renders correctly through the native AVPlayer path on hosts with HW AV1 decode.
- **Dolby Vision Profile 5 / AV1 Profile 10.0 thumbnails skip the RPU reshaping curves.** `FrameExtractor` now applies the DV colour transform (from `AV_FRAME_DATA_DOVI_METADATA`) so P5 / P10.0 stills come out with correct colour, validated against a libplacebo render. The per-frame reshaping polynomials are intentionally not applied: they are not what causes the visible green / magenta corruption, and skipping them keeps this a lightweight CPU pass rather than a full Dolby Vision compositor. Brightness / contrast can therefore differ marginally from a fully graded DV render. A frame that carries no DV metadata falls back to the standard path.
