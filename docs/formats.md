# Formats, codecs, and playback detail

Depth behind the README's "What it handles" matrix: codec routing, HDR signaling, audio bridging, subtitles, frame extraction, disc playback, and the documented edge cases. For the pipeline shapes these route through, see [docs/architecture.md](architecture.md).

## Containers and codecs

**Containers (demux side):** MKV, MP4, WebM, MPEG-TS, AVI, OGG, FLV.

**Hardware decode** (native AVPlayer path, VideoToolbox): H.264, HEVC, HEVC Main10. AV1 on devices with HW AV1 (M3+ Mac, iPhone 15 Pro+, future Apple TV chips) also routes natively.

**Software decode** (`SoftwareVideoDecoder` + `AVSampleBufferDisplayLayer`):

- AV1 (libavcodec / dav1d) on devices without HW AV1 — currently all Apple TVs, M1 / M2 Macs, pre-A17-Pro iPhones.
- VP9 and VP8 (libavcodec native) unconditionally, since AVPlayer's HLS pipeline rejects the `vp09` / `vp08` CODECS attributes even where VideoToolbox can HW-decode them.
- MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video, and VC-1, none of which AVPlayer's HLS-fMP4 pipeline accepts; libavcodec ships native decoders for all three.

Interlaced sources (DVD-rip MPEG-2, SD broadcast) are deinterlaced through a persistent bwdif graph (yadif fallback) that engages on the first interlaced frame and costs nothing on progressive content. The dispatch decision lives in `AetherEngine.load`, gated per source on `VTCapabilityProbe` and codec id.

## HDR routing

| Source | Wrapper signaling |
| --- | --- |
| H.264, HEVC (SDR) | BT.709 |
| HEVC Main10 (HDR10) | BT.2020 / PQ |
| HEVC Main10 (HDR10+) | BT.2020 / PQ + per-frame ST 2094-40 SEI stream-copied |
| HEVC Main10 (DV P5 / P8.1 / P8.4) | `dvh1` / `dvhe` track type with the source's `dvcC` box preserved |
| HEVC Main10 (HLG) | BT.2020 / HLG |
| AV1 HDR | BT.2020 / PQ |

HDR-to-SDR mapping is handled by AVPlayer and the system compositor according to the connected display. AetherEngine doesn't tonemap on the host; it tells the system "this is BT.2020 PQ" (or DV, or HLG) via the HLS-fMP4 sample description and lets tvOS / iOS pick the right path. `DisplayCriteriaController` issues the HDMI content-frame-rate and dynamic-range hint via `AVDisplayManager` before the first segment is fetched, so the receiver-side handshake is in flight by the time `AVPlayer` is ready to render. (For why this ordering is mandatory on tvOS, see the README's "Host setup on tvOS" section.)

### Dolby Vision signaling

For DV streams the demuxer surfaces the source's `AVDOVIDecoderConfigurationRecord`. On DV-capable displays, `HLSVideoEngine` writes the matching ISO BMFF `dvcC` box into the HLS-fMP4 sample description and emits a bare `dvh1.<profile>.<dvLevel>` codec tag for Profile 5, 8.1, and 8.4 so AVKit's auto-criteria reads `dvh1` from the sample entries and engages DV mode directly. On non-DV displays the engine downgrades to plain `hvc1`: Profile 5 is unplayable there (no HDR10 base), and Profiles 8.1 / 8.4 fall back to their HDR10 / HLG base layer with AVPlayer's tone-mapping path. AV1+DV (Profile 10.0 / 10.1 / 10.4) uses the parallel `dav1` / `av01` track type plus `dvvC` box on hardware-AV1 hosts.

**Profile 7** (dual-layer, the common UHD-Blu-ray remux profile) has no decoder on any Apple platform, so the engine converts it to single-layer **Profile 8.1** live during muxing: the RPU of each video packet is rewritten with [libdovi](https://github.com/superuser404notfound/LibDovi) (`dovi_convert_rpu_with_mode`, mode 2, the same transform as `dovi_tool -m 2`), the enhancement-layer NALs are dropped, and the container `dvvC` is set to Profile 8.1. On a DV-capable display this means real Dolby Vision (`dvh1.08/db1p` supplemental) instead of the plain HDR10 base; on a non-DV display Profile 7 still falls back to its HDR10 base, unchanged. The conversion is loss-free relative to what Apple could show before (the enhancement layer was never decodable on Apple hardware), and any per-packet conversion failure falls back to the HDR10 strip. MEL and FEL sources are both handled.

### HDR10+ dynamic metadata

ST 2094-40 metadata stays attached to the HEVC bitstream as user-data-registered ITU-T T.35 SEI NALs. The HLS-fMP4 stream-copy preserves the SEI through to `AVPlayer`, which forwards it to the system compositor. HDR10+-capable TVs apply the per-scene tone-mapping curves; HDR10-only TVs fall back to the static HDR10 base.

The published `videoFormat` starts at `.hdr10` for any BT.2020 / PQ source and flips to `.hdr10Plus` the first time a packet's T.35 SEI signature is seen in the producer's scan. Debounced across producer restarts so a scrub doesn't re-fire. Hosts can drive an HDR10+ badge or analytics hook off the `$videoFormat` transition.

## Audio

| | |
| --- | --- |
| Stream-copy (lossless into fMP4) | AAC-LC, AC3, EAC3, FLAC, ALAC. HE-AAC / HE-AACv2 stream-copy when the source carries an AudioSpecificConfig (any movie container) and bridge only without one (live ADTS / MPEG-TS, where a synthesized ASC would mis-signal SBR). LATM/LOAS-framed AAC (DVB broadcast framing) always bridges |
| Bridged (`AudioBridge`) | TrueHD, MLP, DTS, DTS-HD MA, MP3, MP2, Opus, Vorbis, PCM — decoded to PCM and re-encoded |
| Surround | 5.1 / 7.1 with correct `AudioChannelLayout` preserved through the wrapper |

Non-streamable codecs route through `AudioBridge` in one of two modes (`LoadOptions.audioBridgeMode`):

- **`.surroundCompat`** (default): lossy EAC3 at 128 kbps per channel (256 kbps stereo, 768 kbps 5.1). AVPlayer hands the encoded bitstream to HDMI and the sink decodes its own 5.1 mix, so surround works on essentially every modern AVR and soundbar (Sonos Arc, Samsung HW-Q, Bose).
- **`.lossless`** (opt-in): FLAC up to 7.1 lossless, which AVPlayer decodes to LPCM. Needs an AVR that accepts multichannel LPCM via HDMI (Denon, Marantz, NAD); on soundbars and basic AVRs that handle multichannel only via bitstream codecs the LPCM gets downmixed to stereo at the route.

`.surroundCompat` is the default because the soundbar / basic-AVR install base is the majority. Object metadata (Atmos / TrueHD-MA) is lost in either mode: FFmpeg's EAC3 encoder doesn't produce JOC, and FLAC has no object-channel concept. If a JOC source ever falls through to the bridge the engine logs a loud `WARNING: Atmos downgrade — ...`.

### Dolby Atmos

EAC3+JOC packets are stream-copied through the muxer untouched, on every output route. AVPlayer reads the segment, recognises JOC from the `dec3` box (`numDepSub=1`, `depChanLoc=0x0100`), and lets the downstream renderer decide: over HDMI it tunnels out as Dolby MAT 2.0 and the AVR lights up the Atmos indicator; over AirPods it renders spatially; over plain Bluetooth A2DP / LE it downmixes the bed channels to stereo natively. The route never changes the engine's decision (a JOC track is signaled in the playlist as `ec-3`, the same CODECS string as a non-JOC EAC3 5.1 track, so AVPlayer accepts it everywhere and the bitstream is never re-encoded for a route reason). The engine emits an explicit `[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged; ...` diagnostic on every Atmos session.

Matroska CodecPrivate doesn't usually carry the pre-parsed `dec3` / `dac3` box content the mov muxer needs at `avformat_write_header` time, so the muxer is configured with `+delay_moov` (alongside `+empty_moov+default_base_moof+frag_custom`). The moov atom is deferred until the first fragment-cut flush, by which point packets have flowed through `mov_write_packet` and libavformat's `handle_eac3` / `handle_ac3` have populated the sample-entry boxes from the actual packet bitstream. The first cut emits the deferred ftyp+moov (routed by `FragmentSplitter` to init.mp4); subsequent cuts emit normal moof+mdat. Net effect: EAC3 / AC3 from matroska direct-play stream-copies cleanly with valid sample-entries, no manual bitstream parsing on the host side.

## Subtitles

Subtitle packets are routed through the same demux loop as audio and video. No second AVIO connection, no full-file scan. Each packet decodes inline through `avcodec_decode_subtitle2`, the result lands in a single `[SubtitleCue]` published list:

- **Text codecs** (SubRip / ASS / SSA / WebVTT / mov_text) → `SubtitleCue.body = .text(String)`. ASS dialogue headers and override blocks (`{\an8}`, `{\b1}`, ...) are stripped; `\N` becomes a real newline so the host can render with regular text layout.
- **Bitmap codecs** (PGS / HDMV PGS / DVB / DVD) → `.image(SubtitleImage)`. The indexed pixel plane is walked through its palette, premultiplied against alpha, and wrapped as a `CGImage`. Position is normalised in `[0..1]` against the source video frame so the host scales to any on-screen rect.
- **Sidecar files** (a separate `.srt` / `.ass` / `.vtt` URL) → `selectSidecarSubtitle(url:httpHeaders:)` opens its own short-lived `AVFormatContext`, decodes the whole file once, atomically swaps the result into `subtitleCues`. The fetch forwards the session's `LoadOptions.httpHeaders` by default (WebDAV auth and friends); pass the call's own `httpHeaders` to override per fetch.

A single packet that carries multiple rects (PGS often emits signs/songs at the top alongside dialogue at the bottom) becomes multiple cues at the same time range, and the host renders all of them. Cues are inserted in sorted order; re-emitted events after a seek dedupe by time range plus content (so two simultaneous speaker lines with identical timing both survive) and the list doesn't grow on rewind.

Subtitle cues land in raw source PTS. On the native path, AVPlayer's HLS clock sits at `source_pts - producer.videoShiftPts` (the producer applies a per-session shift to align the first segment's tfdt with the playlist origin, and the shift can change on every restart). Render the overlay against `player.sourceTime` so cues match the spoken audio regardless of which producer session is active.

### Native subtitle menu (tx3g / mov_text for PiP, AirPlay, and external display)

Host-rendered subtitle overlays are invisible in Picture-in-Picture, AirPlay, and external-display sessions because those paths render the `AVPlayerLayer` content only; the SwiftUI / UIKit view tree is not composited. The native subtitle track feature solves this by muxing all text subtitle tracks as separate `mov_text` (tx3g) traks directly into the fragmented-MP4 stream so AVFoundation exposes them as a standard legible `AVMediaSelection` group that travels with the stream everywhere `AVPlayer` goes, including PiP and AirPlay.

**Opt-in.** The feature is off by default (`LoadOptions.prepareNativeSubtitles = false`). When disabled, the muxer output is byte-identical to the prior behavior and `AVPlayerViewController` shows no subtitle menu.

**All text tracks, not just the active one.** When `prepareNativeSubtitles` is `true` and the title has text subtitle tracks (embedded or sidecar), the engine declares one `mov_text` trak in the `init.mp4` moov per text track, each language-tagged (ISO 639-2), all with `disposition:default=0`. AVFoundation's legible group exposes every track as a selectable option. None is auto-displayed (`defaultOption` is `nil`); the host or the user's native AVPlayer menu chooses when to engage one. A single side-demuxer decode pass decodes all text streams in parallel into per-track bounded stores; memory is bounded by total cue count across all tracks.

**Scope and format coverage.** Works on VOD with embedded text subtitles and sidecar files (SRT / VTT / ASS). Covers all SDR, HDR10, HLG, and Dolby Vision sources uniformly, including DV Profile 5 (which has no HLS master playlist, ruling out WebVTT in-manifest tracks). Bitmap subtitles (PGS / DVB / DVD) cannot become native text tracks; they remain host-rendered only. Live sources are out of scope for this release.

**Rich ASS styling note.** Every native track carries plain text (ASS/SSA markup stripped, same as every other text format). Rich ASS styling (positions, speaker colours, karaoke) is still host-rendered inline via `LoadOptions.preserveASSMarkup`; the native track in PiP / AirPlay falls back to the system caption style.

**Timing.** Cue PTS values written to the `mov_text` tracks are on the AVPlayer clock axis (`source_pts - producer.videoShiftPts`), so they stay in sync with the displayed frame regardless of producer restarts or seeks.

**Selection: native menu.** AVPlayer's built-in legible menu enumerates all language-tagged tracks automatically. No host code is required for that path; selection works in PiP and AirPlay without any additional wiring.

**Selection: host-driven API.** Three members on `AetherEngine` drive the native subtitle menu programmatically:

```swift
// true once cues from at least one text track are decoded into the native stores
engine.$nativeSubtitleRenditionAvailable   // @Published var Bool

// ordered list of all native mov_text tracks (ordinal, language tag, display name)
engine.$nativeSubtitleTracks               // @Published var [NativeSubtitleTrack]

// select a track by ordinal (nil deselects all); matches by language tag, positional fallback
engine.setNativeSubtitleSelected(track ordinal: Int?)
```

`NativeSubtitleTrack` carries `.ordinal` (position in the muxer declaration), `.language` (ISO 639-2 tag), and `.displayName` (localized name suitable for a picker label).

The recommended host pattern for PiP / AirPlay:

1. Observe `$nativeSubtitleRenditionAvailable` (waits for the first cues to be ready before activating).
2. On entering PiP / AirPlay / external display: call `setNativeSubtitleSelected(track: ordinal)` with the ordinal that matches the currently active inline track, and hide the host overlay.
3. On leaving: call `setNativeSubtitleSelected(track: nil)` and re-enable the host overlay.

This avoids double subtitles during inline playback (where the host overlay is already painting them) and ensures the user sees subtitles the moment the stream is mirrored or sent to PiP.

**Device-verification checklist** (required before tagging a release):

- Native menu lists every subtitle language with correct labels in AVPlayer's standard legible picker.
- Selecting a language from the native menu displays it; switching languages (including in PiP) works.
- Inline host ASS rendering unchanged: rich styling intact, no regression from the all-tracks decode pass.
- No double subtitles while inline; no track is auto-displayed on session start.
- Timing: no constant offset between audio and subtitle cues.
- SDR, HDR10, and Dolby Vision picture behavior byte-identical to a session with `prepareNativeSubtitles = false` (the tx3g traks must not perturb video or audio).
- DV Profile 5 source with a text subtitle: subtitle works via the native menu.
- Memory bounded by total cue count across all tracks (not per-track allocation that grows with track count).

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

HDR sources come out looking right: PQ / HLG BT.2020 frames are tone-mapped to SDR BT.709 through a zscale + tonemap libavfilter graph before the `CGImage` is built, so HDR10 / HLG / DV P8.x stills match what the user sees instead of washed-out grey. (DV Profile 5 is the documented exception, see Known limitations.)

`FrameExtractor` is an `actor`. Blocking FFmpeg work runs on a dedicated serial queue, never on the cooperative thread pool. The decode context opens lazily on first use; a superseded request (the common case during an active scrub) cancels the in-flight decode so the latest position wins. Results land in a bounded LRU cache (snapshots and thumbnails kept in separate stores, thumbnails bucketed by second). After 10 s idle the context closes and the cache drops automatically; the next request reopens lazily. `shutdown()` is the explicit, permanent teardown. The engine does not retain the extractor returned by `makeFrameExtractor()`; the caller owns its lifecycle.

## Disc (DVD / Blu-ray ISO)

Decrypted disc images play through the normal decode path via a synthetic seekable byte source. `DiscReader` detects and routes both local `.iso` URLs and `MediaSource.custom` ISO readers.

- **DVD-Video ISO:** `ISO9660Reader` reads the ISO9660 bridge filesystem, `DVDTitleSelector` picks the longest title set by VOB size, and `ConcatIOReader` presents its concatenated VOBs as one seekable source demuxed as MPEG-PS.
- **Blu-ray ISO:** a read-only `UDFReader` (UDF 2.50, including the metadata partition and fragmented-file allocation descriptors) resolves BDMV, `MPLSParser` + `BDTitleSelector` pick the main title from the longest `.mpls` playlist, and its `.m2ts` clips are concatenated and demuxed as MPEG-TS (H.264 / HEVC / VC-1, AC3 / EAC3 / DTS / TrueHD / LPCM, PGS subtitles).

Both: no decryption (CSS / AACS retail discs must be ripped decrypted first), no GPL nav libraries, main title only (no menus, BD-J, or multi-angle).

## Network sources (SMB)

The optional `AetherEngineSMB` product plays media off an SMB2/3 share through the normal decode path, no server-side mount. `SMBConnection` (backed by [AMSMB2](https://github.com/amosavian/AMSMB2) / libsmb2, LGPL-2.1, same license tier as the bundled FFmpeg) is a `ByteRangeSource`; `SMBIOReader` adapts it to the engine's `IOReader`, bridging each synchronous demux-thread read to AMSMB2's async API. The reader is seekable, so audio-track switching, background reload, embedded subtitles, and scrub previews all work (`makeIndependentReader()` opens a second cursor on the same connection).

Read-only. NTLMv2 and guest auth (no Kerberos, which tvOS lacks). No writing, locking, directory browsing, or SMB3 transit encryption. AMSMB2 exposes no persistent file handle, so each read is a fresh ranged fetch; this clears typical media bitrates comfortably. The dependency is linked only by consumers of the `AetherEngineSMB` product, so the core engine and its tvOS hosts never pull libsmb2. On tvOS the host supplies the local-network entitlement to reach a LAN share.

## Live ingest, AES-128, SSAI

A live HLS upstream can be ingested directly via `HLSLiveIngestReader` (a public forward-only `IOReader`), no media server in the data path. Contract: MPEG-TS segments, including demuxed-audio variants (`EXT-X-MEDIA` audio groups, fetched by a companion reader and merged by DTS) and packed-audio renditions (raw ADTS framed by ID3 timestamps). AES-128 clear-key segments (`EXT-X-KEY:METHOD=AES-128`, the standard FAST-channel scheme) are decrypted in-line by `HLSSegmentDecryptor`: the key is fetched once per clip and memoised, each segment decrypted (AES-128-CBC / PKCS7) before demux. SAMPLE-AES / keyless AES-128 (no `URI`), fMP4 playlists (`EXT-X-MAP`), and a key-fetch / decrypt failure terminate with a typed `HLSIngestError` so the host can fall back to a server-mediated URL. This is standard HLS clear-key, not FairPlay / Widevine.

Server-side ad insertion (SSAI) plays through the direct path instead of bouncing to a server transcode at the ad break. FAST channels (Pluto and similar) splice ad creatives that restart the source clock and often carry a different video PID, resolution, and SPS than the program. The producer detects the program switch, parses the ad's SPS/PPS by hand (`H264SPS`) to build a fresh codec config, rotates the fMP4 muxer, and emits a versioned `#EXT-X-MAP` per discontinuity so AVPlayer resyncs cleanly across the init and resolution change; audio is re-anchored to the video timeline at every creative boundary (including amux creatives that mux audio on a separate source clock) and an `OutputTimestampSanitizer` keeps the stream monotonic across the splice. A no-cut stall watchdog sits underneath as a safety net: it tells a genuinely wedged pod (reading at full rate but unable to cut) from a slow source (a trickle) by read rate, escalating only the former to a host retune.

## Known limitations

Things that work today but have a documented edge case, or are deferred behind an upstream dependency:

- **TrueHD-MAT Atmos object metadata is not preserved.** TrueHD / MLP sources route through the AudioBridge (FFmpeg's EAC3 encoder doesn't produce JOC). Bed channels and surround layout survive; object metadata is dropped. EAC3+JOC stream-copy from MKV / MP4 sources is intact.
- **`.surroundCompat` audio bridge caps 7.1 sources to 5.1.** FFmpeg's EAC3 encoder currently caps at 6 channels. Once [FFmpeg PR 21668](https://github.com/FFmpeg/FFmpeg/pull/21668) lands the cap and the dynamic bitrate auto-scale to 1024 kbps engage without a code change here. Use `.lossless` (FLAC) today if 7.1 matters.
- **Manual `MPNowPlayingInfoCenter` writes race the HLS-loopback path on tvOS 26.** The combination produces a `libdispatch` race. Only `AVPlayerViewController` with its standard transport bar safely surfaces Now Playing. Hosts that need a custom transport should use `MPNowPlayingSession` against the engine's `currentAVPlayer` publisher instead of `MPNowPlayingInfoCenter.default().nowPlayingInfo`.
- **Audio session is activated per playback, not at process launch.** The engine declares the `AVAudioSession` category (`.playback` / `.moviePlayback` / `.longFormAudio`) and multichannel support at init, but does NOT activate the session there. Activating once at launch used to pin the route to whatever the HDMI link reported at that instant: with tvOS Continuous Audio Connection off the link idles at stereo, so the launch-time activation negotiated the route to 2 channels and pinned it, downmixing non-Atmos multichannel for the whole session (AetherEngine#24). The native video path now lets the host's `AVPlayerViewController` activate the session per playback; the renderer paths (software decode, audio-only) activate it themselves. Hosts that mount the engine's bare `AVPlayerLayer` instead of an `AVPlayerViewController` should ensure the session is active at playback. A genuine sink-side ch=2 (an AVR caching its HDMI EDID incorrectly after standby) can still force a downmix; power-cycling the sink restores it. Atmos passthrough is unaffected either way because EAC3+JOC ships as MAT 2.0 over a 2-channel carrier.
- **Live MPEG-TS sliding-window eviction and DVR rewind are verified off-device, pending on-device confirmation.** The sliding playlist bounds the resident footprint and `behindLiveSeconds` is stable at real-time pacing, both measured via the `aetherctl` harness. Confirmation on Apple TV with a real broadcast feed (where the tvOS jetsam budget and real tuner timing apply) is still recommended before relying on it in production.
- **AV1 on Apple TV is software-decoded.** No current Apple TV chip ships HW AV1. The `SoftwarePlaybackHost` + dav1d path handles it, but CPU use is meaningfully higher than HW HEVC. On iOS 17+ / macOS 14+ AV1 routes through Apple's HW pipeline transparently. Future Apple TV chips with HW AV1 will be picked up automatically by `VTCapabilityProbe`.
- **AV1 Dolby Vision Profile 10.0 has wrong colours when software-decoded.** dav1d / libavcodec cannot decode the proprietary DV colour space, so a Profile 10.0 source (DV-only, no fallback base layer) renders with incorrect colours on the SW path. Profiles 10.1 and 10.4 are unaffected because they carry an HDR10 / HLG base layer. Profile 10.0 only renders correctly through the native AVPlayer path on hosts with HW AV1 decode.
- **Dolby Vision Profile 5 thumbnails (FrameExtractor) have wrong colours.** `FrameExtractor` tone-maps HDR10 / HLG / DV P8.x stills correctly, but DV Profile 5 is IPT-PQ with no HDR10 base layer, so the software decode the extractor uses cannot resolve its colour space (same root cause as the AV1 Profile 10.0 limitation). Full playback of P5 is unaffected: it routes through the native AVPlayer path, which engages the display's DV pipeline.
