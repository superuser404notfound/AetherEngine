# Changelog

Quick index of AetherEngine releases. Detailed per-release notes (breaking
changes, full fix list, acknowledgements) live on
[GitHub Releases](https://github.com/superuser404notfound/AetherEngine/releases).

Versioning follows [Semantic Versioning](https://semver.org). See
[README › Stability and versioning](README.md#stability-and-versioning) for
the public-API contract.

## [Unreleased]

### Fixed

- **UDF reader follows allocation-extent continuations (tag 258).** A file whose allocation descriptors overflow its (E)FE chains the rest through an Allocation Extent Descriptor (extent type 3). The reader now follows that chain (depth-bounded) instead of treating the continuation pointer as a bogus data extent. Defensive: inline descriptors already cover ~114 GiB per file, so no current Blu-ray needs it, but a heavily fragmented title would otherwise under-resolve.

## [3.13.3] — 2026-06-24

### Fixed

- **Blu-ray ISO playback failed for every real UDF 2.50 disc image (#62).** The UDF reader found the volume anchor and parsed the volume structure, but listing the root directory returned nothing, so no `BDMV` was found, `DiscReader.wrap` returned `nil`, and the raw image fell through to a plain FFmpeg open that reports `AVERROR_INVALIDDATA`. The cause was a partition-reference bug: a metadata-resident file entry's `short_ad` allocation descriptors were resolved against the physical partition. A `short_ad` carries no partition reference, so it is relative to the file entry's own recording partition; for a metadata-partition entry that means metadata-virtual blocks resolved through the Metadata File. The root directory data lives in the metadata partition, so the wrong sectors were read. `short_ad` now resolves against the file entry's own partition (`long_ad`, which carries an explicit reference for the physical m2ts payload, was already correct). Verified end to end against the Blender Sintel Blu-ray ISO.

### Added

- **`AetherEngine.inspectDisc(url:)` plus `aetherctl disc-inspect [--dump]`.** An FFmpeg-free, stage-by-stage walk of a local disc image (ISO9660/UDF signatures, UDF root and BDMV tree, parsed `.mpls` playlists, selected main title, resolved m2ts extents) that reports exactly where recognition bails. `DiscReader` also emits gated `[disc]` diagnostics on the playback path so a future failure is debuggable instead of a silent `nil`.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.13.3))

## [3.13.2] — 2026-06-23

### Fixed

- **Adversarial bug-audit pass: roughly a dozen correctness, concurrency, and memory-safety fixes across the engine.** The demuxer now synchronizes its `AVIOReader` close flags to close a persistent-connection teardown race, the audio bridge serializes its mutators under an internal lock, drains the decoder at EOF so the final tail is not dropped, and frees partial encoded packets when a FIFO drain throws. The native subtitle cue store is now guarded against the pump thread, SMB `cancel()` unblocks a parked read instead of waiting out the timeout, live seek finalize is guarded on the load generation to drop superseded seeks, and `FrameExtractor` flushes its decoder at EOF so last-GOP snapshots are not lost.
- **Disc reader hardened against untrusted and cancelled reads.** `DiscReader.readAll` now caps untrusted UDF extent allocation, `ConcatIOReader.cancel()` forwards to the base reader, and the sidecar subtitle path avoids a double-free of its `AVFormatContext` when an HTTP open fails. The DVR feeder also seeds at a real keyframe when the seek target precedes the ring.

### Performance

- **O(log n) `segmentIndex` lookup.** The per-packet segment-index resolution now uses a binary search instead of an O(n) linear scan over stored segments.

### Changed

- **Internal quality pass.** Strict-concurrency and deprecation warnings cleared (27 in total), dead code and redundant comments pruned, FragmentSplitter and SegmentCache index math covered by new tests, and the dual-subtitle API plus `dualsubs` CLI documented.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.13.2))

## [3.13.1] — 2026-06-22

### Fixed

- **Embedded ASS subtitle feed fell behind playback on packet-dense tracks (#56).** The embedded subtitle side reader published each decoded event through its own awaited `MainActor.run` hop. On a track that stacks many events on the same (or nearly the same) timestamp, those per-event hops serialize the demux loop against the host's on-MainActor ASS renderer, so demux throughput collapses to the MainActor scheduling rate and the published `subtitleCues` fall far behind the playhead (in the reported sample, 1534 ASS events share a single 5.207 s timestamp). Decoded events are now coalesced and flushed to the MainActor in a single hop once the batch spans a short window of source time (sparse tracks still flush per event, so there is no added latency) or reaches a count cap (the decisive throttle for a same-timestamp burst, turning that 1534-event cluster into roughly a dozen hops instead of 1534). The native `tx3g` reader (3.13.0) already wrote cues off-actor and is unaffected.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.13.1))

## [3.13.0] — 2026-06-22

### Added

- **Native subtitle tracks for Picture-in-Picture, AirPlay, and external display (#55).** All embedded and sidecar text subtitle tracks can be muxed into the fragmented-MP4 stream as native language-tagged `tx3g` (mov_text) tracks, so AVPlayer renders them itself and they survive PiP, AirPlay, and external-display playback, where a host-drawn overlay is never composited. AVPlayer's stock legible menu enumerates every language for selection. This rides the existing `media.m3u8` path with no master playlist, so SDR / HDR10 / HLG / Dolby Vision (including Profile 5) routing is byte-identical to before. Opt-in via `LoadOptions.prepareNativeSubtitles`; tracks are exposed as `nativeSubtitleTracks` with `setNativeSubtitleSelected(track:)`.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.13.0))

## [3.12.0] — 2026-06-21

### Added

- **`clock.bufferedPosition` for buffer-bar indicators (#54).** A new published value on `engine.clock` reports how far ahead the engine has buffered, on the same source axis as `sourceTime`, so a host can draw a YouTube-style buffer bar as `bufferedPosition / duration`. On the native AVPlayer path it is the end of the contiguous `loadedTimeRanges` span covering the playhead, folded with the same seam shift as `sourceTime`; on the software (dav1d / libavcodec) path it is the newest demuxed source PTS, i.e. how far ahead bytes have been fetched and demuxed from the (possibly remote) source; the audio path mirrors `currentTime`. Clamped to never trail the rendered frame, reset on load / stop. Additive, no behavior change to existing surfaces.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.12.0))

## [3.11.7] — 2026-06-20

### Fixed

- **Malformed Dolby Vision "Profile 8.6" rejected by AVPlayer (#53).** Some HEVC sources are tagged DV Profile 8 with an invalid `dv_bl_signal_compatibility_id` (typically 6, which is really P7's marker) because an old tool confused the profile with the `dvhe08.06` level field. The bitstream is a single-layer HDR10-base P8.1 stream, but a `dvvC` whose compat id contradicts the `db1p` brand makes AVPlayer reject the variant outright; previously the engine classified it as P8.1 yet stream-copied the source `dvcC` unmodified, so the invalid compat survived into `init.mp4`. On a DV-capable panel the engine now normalizes the container `dvcC` to a valid P8.1 (compat = 1, profile = 8, el_present = 0) so the `dvvC` and `db1p` supplemental agree and AVPlayer accepts it; no per-packet RPU work is needed since the elementary stream is already P8.1. On a non-DV panel the existing strip path still forces the HDR10 fallback, matching the server's DOVIInvalid remux. Internally this decoupled the container `dvcC` rewrite (`rewriteDoviConfigTo81`) from the P7 per-packet RPU conversion so both routes share the container fix.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.11.7))

## [3.11.6] — 2026-06-20

### Fixed

- **Still-image / scrub-preview thumbnails of anamorphic SD content rendered horizontally stretched (#23).** `FrameExtractor` (the on-device frame source for scrub previews and chapter thumbnails) scaled each decoded frame using its coded width and height only, ignoring the sample aspect ratio, so an NTSC DVD (720x480 stored, displayed at 4:3) produced a 3:2 thumbnail. `FrameDecodeContext` now reads the stream SAR at open (per-frame SAR as a fallback, since the software decoder does not reliably attach it) and folds it into the output height via `displayDimensions(...)`, so thumbnails keep the source display aspect (4:3 here, 16:9 for anamorphic widescreen DVDs). Mirrors the main decode-path SAR fix (3.11.3). The HDR tone-map thumbnail path is unchanged (anamorphic content is effectively always SDR). Regression test covers NTSC, PAL, and anamorphic ratios.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.11.6))

## [3.11.5] — 2026-06-20

### Fixed

- **Long delay to first subtitle cue when a track is activated mid-playback (no pause) on a slow/remote source (#52).** `selectSubtitleTrack(index:)` mid-playback on a large/remote (high-latency) source showed the first on-screen cue tens of seconds late instead of the ~1-2s the API promises. The side demuxer captured the playhead (`startAt`) before `demuxer.open` and the `duration*0.5` prewarm seek; on a slow source those steps cost several seconds of wall-clock during which unpaused playback advanced, so the reader then seeked to a now-stale position behind the live playhead and paged forward over already-played content. Those cues arrived behind the playhead and were dropped by the current-cue lookup until the read caught up. The reader now re-samples the live playhead after the open + prewarm and re-targets the single existing seek to it (no extra network seek), keeping the bitmap SETUP lead-in and seeding the read-ahead snapshot from the re-sampled value. It is a no-op when paused, on a fast/local open, and on the seek re-arm path.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.11.5))

## [3.11.4] — 2026-06-20

### Fixed

- **Spurious terminal `.failed` published while the AVPlayer kept playing (#50).** On engine-native loopback-HLS playback the engine could publish a terminal failure while the player was demonstrably still advancing (clock and subtitle cues moving, segments flowing, title playing to the end), aborting a session that had self-healed. AVPlayer flips `item.status` to `.failed` on transient errors it then recovers from (an in-range loopback 404, or an AVIOReader range-read reconnect), and the `.failed` KVO is not synchronized with the `timeControlStatus` KVO, so the earlier gate (3.11.3) that checked the instantaneous transport state at the failure instant still let a transient through whenever it fired during a brief `.waitingToPlayAtSpecifiedRate` blip. The failure publish now discriminates on whether playback was ever established (a latch set on the first `.playing` transition) instead of an instantaneous sample: before playback establishes a `.failed` surfaces promptly (genuine startup failure), and after it every `.failed` is deferred and only surfaced if, after a settle, the player is both stopped and has not advanced its clock. No transient that keeps the clock moving can publish a terminal failure anymore.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.11.4))

## [3.11.3] — 2026-06-19

### Fixed

- **Anamorphic SD content (DVD rips, widescreen DVDs) rendered "flattened" / horizontally squished (#23).** DVD MPEG-2 stores non-square pixels (NTSC 720x480 is encoded for 4:3 display; widescreen DVDs for 16:9), but `SoftwareVideoDecoder` attached only color-space metadata to its output `CVPixelBuffer`, never the sample aspect ratio. `CMVideoFormatDescriptionCreateForImageBuffer` therefore produced a format description with no `PixelAspectRatio` extension, and `AVSampleBufferDisplayLayer` sized the picture with square pixels (a too-wide 3:2). The decoder now captures the container SAR at `open()` and attaches each frame's `sample_aspect_ratio` (with that stream-level fallback) as `kCVImageBufferPixelAspectRatioKey`, so the picture displays at its intended aspect. The native VideoToolbox path already reads SAR from the container, so only the software path needed this.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.11.3))

## [3.11.2] — 2026-06-19

### Fixed

- **Interlaced MPEG-2 / VC-1 / MPEG-4 (DVD rips, SD broadcast) played at half speed and froze on resume (#23).** `bwdif` / `yadif` configure their output link with `time_base = input / 2` and emit frame PTS in that halved base, but `DeinterlaceFilter.pull` handed those frames straight to `SoftwareVideoDecoder.emit`, which timestamps every frame on the stream time_base. Reading a doubled-tick PTS with the un-halved base placed every interlaced frame at 2x its real presentation time: from start the video paced at half rate (renderer queue fills, demux parks on back-pressure, audio drains then goes silent); on resume frames landed far in the future so the picture froze on one frame while the audio-driven clock advanced. `pull` now rescales the pulled PTS and duration from the buffersink time_base back into the stream time_base via `av_buffersink_get_time_base`, which also handles the `pts_multiplier = 1` fallback when `av_reduce` cannot form the exact half base.

### Changed

- Loopback-HLS request arrivals are now logged at `.info` (was `.debug`) to surface the request path during the #50 plain-playback 404 investigation.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.11.2))

## [3.11.1] — 2026-06-18

### Fixed

- **System-wide `mediaserverd` wedge after a long background suspension.** A paused native session left running into a multi-hour tvOS suspension kept its AVPlayer decode session, the in-process loopback HLS server sockets, and the upstream AVIO connection all allocated. On resume that wedged the shared `mediaserverd` system-wide: every app (including unrelated ones) could only paint the first frame until the device was rebooted. The `didEnterBackground` handler now tears the video pipeline down instead of merely pausing, releasing the decode session synchronously before suspension. The native host shell and `currentAVPlayer` are kept so Now-Playing survives, and the clock / loaded URL / options are preserved so the host's foreground `reloadAtCurrentPosition()` resumes at the paused position.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.11.1))

## [3.11.0] — 2026-06-18

### Added

- **Live Dolby Vision Profile 7 to 8.1 conversion.** P7 sources (dual-layer BL+EL+RPU, the common Blu-ray remux profile that Apple platforms cannot decode) now play by routing the base layer as 8.1 and rewriting the RPU live via `DoviRpuConverter` (libdovi, shipped as the new `LibDovi` xcframework). On any conversion failure the path falls back to HDR10 rather than rejecting the file. The conversion is gated off for SSAI re-init. `aetherctl dovitest <file>` exercises the converter. (S1483, S1484, S1489)
- **P8.2 / P10.2 / P9 base-layer playback.** These profiles now play their base layers instead of being rejected outright.
- **Intel Mac support.** `LibDovi` ships x86_64 fat binaries (macOS and iOS Simulator) as of 1.0.2, so AetherEngine cross-builds for x86_64. (1.0.1 added the iOS slices that 1.0.0 was missing.)

### Fixed

- **Loopback-HLS 404 `loadFailed` wedge after a rapid seek burst (#50).** An in-range VOD segment (`index < segmentCount`) evicted from the rolling window while the single producer sat elsewhere was answered with a 404, which AVPlayer treats as terminal `loadFailed`. The server now returns a retriable 503 for in-range misses (404 stays for genuinely out-of-range indices), and `serveSegment` re-asserts the producer reposition across bounded waits instead of orphaning it behind the #35 restart coalescer's single pending slot.
- **Subtitles raced ahead of the picture during post-seek rebuffer (#49).** Under a sustained seek rate the published clock held the optimistic seek target while AVPlayer stayed parked at the pre-seek frame, so subtitles (which read `sourceTime`) led the on-screen image. `sourceTime` now tracks the actually-rendered frame on the native path while `currentTime` keeps scrub intent. Adds the `clockLeadSeconds` diagnostic.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.11.0))

## [3.10.0] — 2026-06-17

### Added

- **`preserveASSMarkup` now covers external ASS sidecars.** `selectSidecarSubtitle(url:)` honours the session's `LoadOptions.preserveASSMarkup` for `.ass` / `.ssa` files exactly like embedded tracks: cues carry the raw libavcodec event line (override tags and style references intact) instead of stripped plain text, and the script header (`[Script Info]` + `[V4+ Styles]`) extracted from the file's subtitle-stream extradata is surfaced on the new published `engine.sidecarASSHeader`. Hosts pair the two through `ASSScriptBuilder` to drive a whole-script renderer (swift-ass-renderer's `loadTrack(content:)`) for external subtitles, not just embedded ones. SRT / VTT sidecars and the text-only secondary channel are unaffected (no ASS payload, header stays nil). `SubtitleRectText.rawASSLine(for:)` is now the shared raw-line extractor behind both the inline and sidecar decoders (AetherEngine#48).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.10.0))

## [3.9.0] — 2026-06-17

### Added

- **Independent secondary subtitle track (dual subtitles).** A second, fully independent subtitle channel now runs alongside the primary one, so a host can display two subtitle lines at once (for example the original language plus a translation, for bilingual playback and language learning). The public API mirrors the primary surface: `selectSecondarySubtitleTrack(index:)`, `selectSecondarySidecarSubtitle(url:httpHeaders:)`, `clearSecondarySubtitle()`, plus the published `secondarySubtitleCues`, `isSecondarySubtitleActive`, and `isLoadingSecondarySubtitles`. Internally a `SubtitleChannel` enum threads through the reader, apply, and cancel paths (the primary path stays behavior-identical), each channel owning its own side demuxer, seek re-arm, teardown, and audio-track-reload resume. The secondary channel is text-only (bitmap codecs are rejected) and always decodes to plain text: it never preserves ASS markup, so it stays clean even when the primary is a styled ASS track. `aetherctl dualsubs <file> --primary <i> --secondary <j>` validates the two channels emitting cues independently (AetherEngine#47).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.9.0))

## [3.8.0] — 2026-06-17

### Added

- **SMB2/3 playback via the optional `AetherEngineSMB` product.** Play media off an SMB share through the normal decode path, no server-side mount: `SMBConnection` (backed by AMSMB2 / libsmb2, LGPL-2.1, the same license tier as the bundled FFmpeg) is a read-only `ByteRangeSource`, and `SMBIOReader` adapts it to the engine's existing `IOReader`, bridging each synchronous demux-thread read to AMSMB2's async API. Seekable, so audio-track switching, background reload, embedded subtitles, and scrub previews all work. The SMB dependency is scoped to the new product, so the core engine and its tvOS hosts never link libsmb2. Read-only, NTLMv2 / guest auth; on tvOS the host supplies the local-network entitlement. `aetherctl smbtest <smb-url>` validates a share from macOS (AetherEngine#46).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.8.0))

## [3.7.0] — 2026-06-17

### Fixed

- **Seek on the native loopback-HLS path no longer bounces back through the pre-seek position.** A seek wrote the target clock optimistically and flipped state back to `.playing` without waiting for AVPlayer's seek to physically land, so the 100 ms periodic time observer kept publishing the stale pre-seek clock until the (seconds-late) loopback seek completed — the reported time read the target, snapped back to the old position, then re-settled. `seek(to:)` now awaits the real AVPlayer completion, and the native host suppresses the periodic observer's stale reads while a seek is in flight, so the clock holds the target across the landing (AetherEngine#37).
- **Hang on MKV sources with a missing or out-of-bounds Cues index.** When a file's Cues seek index is absent or points past EOF (truncated / mis-muxed remux), libavformat's matroska seek degrades the VOD cue-prewarm into a multi-GB linear forward scan — tens of minutes (a de-facto hang) on a large remote source, even though every byte range of the stream serves fine. The prewarm seek is now bounded by a deadline (`HLSVideoEngine.cuePrewarmTimeout`); on timeout it falls back to the existing keyframe / uniform-stride segment plan so playback starts promptly. Healthy files (Cues resolve in well under a second) are unaffected.
- **Playback above 2x no longer goes abnormal.** AVPlayer's HLS fast-forward is undefined above 2x for video (an audio-only session plays cleanly to 3x); driving a higher rate sent both audio and video abnormal. `setRate(_:)` now clamps the requested rate to the path's ceiling, and the new `AetherEngine.maxSupportedRate` exposes it (2.0 for video, 3.0 for audio-only) so a host can size its speed picker correctly (AetherEngine#39).

### Added

- **`isSeeking` / `seekTarget` published seek signal.** `AetherEngine.isSeeking` is true from seek entry until the seek physically lands (not the optimistic `.playing` flip), uniform across programmatic `seek(to:)` and native AVKit transport-bar scrubs (which drive a producer restart out of the served window). `seekTarget` carries the in-flight destination on the source-PTS axis. A host coordinating playback across devices can gate on these to tell a deliberate seek from a rebuffer or underflow skip without inferring it from `currentTime` jumps (AetherEngine#38).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.7.0))

## [3.6.1] — 2026-06-16

### Fixed

- **Live no-cut stall classified by read rate, not packet count.** A slow live source that trickles packets (a Wowza SMIL `bounce` re-buffering at an SSAI ad splice) could accumulate enough packets over a long stall to be misread as a cutter wedge, tripping the tight wedge timeout and forcing a premature host retune to the server transcode route mid-program. The watchdog now classifies wedge vs. source starvation by the packet read RATE over the stall window: a genuine wedge streams at full rate but cannot cut, a trickle stays well under the threshold and takes the longer starvation backstop, giving the source time to resume.

### Changed

- The no-cut stall trace now reports a per-window breakdown (video / keyframe / audio / foreign-stream packet counts, last foreign stream index, and the video PTS advance across the stall) so an undetected live boundary is diagnosable from one log line. Non-audio/video streams are also named by codec in the demuxer open log.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.6.1))

## [3.6.0] — 2026-06-16

### Added

- **SSAI ad-pod direct play for FAST channels.** Server-side-ad-inserted live streams (Pluto and similar) now play their ad pods through the direct path instead of falling back to a server transcode. The producer detects a program switch when an ad creative arrives on a different video PID, parses the ad's SPS/PPS by hand to build a fresh codec config (`H264SPS`), rotates the fMP4 muxer, and emits a versioned `#EXT-X-MAP` per discontinuity so AVPlayer resyncs cleanly across the init and resolution change. A no-cut stall watchdog stays underneath as a safety net, escalating a genuinely wedged pod to a host retune.
- **AES-128 clear-key direct play.** Live HLS streams encrypted with full-segment `METHOD=AES-128` (clear-key, the standard FAST-channel scheme) now direct-play: the playlist's `EXT-X-KEY` is parsed, the key fetched and memoised, and each segment decrypted (AES-128-CBC / PKCS7) before demux. SAMPLE-AES and keyless variants still fall back. This is standard HLS, not FairPlay / Widevine.

### Fixed

- **SSAI ad-pod audio sync.** Audio across an ad pod is re-anchored to the video timeline at every creative boundary so it cannot accumulate drift, and an output-timestamp sanitizer at the muxer keeps the stream monotonic across the splice. The final case: amux ad creatives that mux audio on a different source clock than video (audio near 2^33, video from 0) had their audio launched far into the future by copying the video shift verbatim; the audio shift is now derived from each stream's own boundary timestamp against the shared seam, so it stays sample-exact for any source base.
- **Transient slow live segment no longer tears down the session.** A single slow CDN segment used to trip the no-cut watchdog and escalate to a host retune as if the pipeline had wedged. The watchdog now distinguishes a cutter wedge (reading fast, cannot cut) from source starvation (barely reading) and gives a slow segment a backstop that sits past the ingest reader's own retry budget, so it recovers and keeps playing.

### Changed

- High-frequency live trace (per-request local-server lines, per-segment captures) now logs at OSLog `.debug` level and is not mirrored to the host log handler, keeping the default Console stream and in-app log buffers focused on decision and error lines. Retrieve the trace on demand with `log stream --level debug`.
- A successful SDR rate-only display switch (Match Frame Rate engaging on a 50/60 fps stream) no longer logs a misleading "panel stayed SDR despite HDR criteria" warning; the warning is now reserved for genuine HDR handshake failures.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.6.0))

## [3.5.0] — 2026-06-15

### Added

- **DVD-Video ISO playback (decrypted images).** Plays decrypted DVD `.iso` files by reading the ISO9660 bridge filesystem (`ISO9660Reader`), selecting the longest title set by VOB size (`DVDTitleSelector`), and presenting its concatenated VOBs as one synthetic seekable byte source (`ConcatIOReader`) demuxed through the existing MPEG-PS path. Detection (`DiscReader`) routes both `MediaSource.custom` ISO readers and local `.iso` URLs automatically. No decryption (CSS-protected retail discs must be ripped decrypted first), no GPL nav libraries, main title only (no menus / multi-angle). (#36)
- **Blu-ray ISO playback (decrypted images).** Plays decrypted Blu-ray `.iso` files: a read-only UDF 2.50 reader (`UDFReader`, including the metadata partition and fragmented-file allocation descriptors), `.mpls` playlist parsing with longest-title selection (`MPLSParser` / `BDTitleSelector`), and the title's `.m2ts` clips concatenated (`ConcatIOReader`) and demuxed as MPEG-TS through the existing path (H.264 / HEVC / VC-1, AC3 / EAC3 / DTS / TrueHD / LPCM, PGS subtitles). No decryption (AACS retail discs must be ripped decrypted first), no third-party disc libraries, main title only (no menus / BD-J / multi-angle). (#36)
- **MPEG Program Stream and Blu-ray demuxer/codec coverage.** FFmpegBuild (pinned at d7fd54b) now enables the `mpegvideo` and `m4v` raw demuxers, so MPEG-2 / MPEG-4 video inside an MPEG Program Stream (DVD VOB) is identified via the demuxer probe instead of mis-detected as audio, plus the `pcm_bluray` decoder for Blu-ray M2TS LPCM tracks.

### Fixed

- **Rapid-seek wedge on loopback HLS.** A burst of seeks could wedge HEVC loopback playback (clock frozen while the state still reads "playing") through an uncoordinated producer-restart cascade. Restart requests are now coalesced, and an `isBuffering` signal distinguishes a genuine rebuffer from a stall. (#35)

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.5.0))

## [3.4.2] — 2026-06-15

### Fixed

- **EAC3+JOC (Atmos) no longer needlessly bridged on Bluetooth.** EAC3+JOC tracks were force-routed through the FLAC bridge whenever the audio output was Bluetooth A2DP / LE, re-encoding the bitstream and discarding the object metadata. AVPlayer decodes and downmixes EAC3+JOC on Bluetooth natively, so the bridge was unnecessary; a JOC track is signaled in the playlist as `ec-3` (identical to non-JOC EAC3 5.1), which AVPlayer's variant selection accepts on every route. EAC3 now always stream-copies regardless of route: HDMI passes DD+/JOC through, AirPods render Atmos spatially, plain Bluetooth downmixes natively. The only remaining EAC3 bridge case (a source missing the `dec3` extradata the mp4 muxer needs) stays route-independent. Reported and device-verified by DrHurt (#34). ([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.4.2))

## [3.4.1] — 2026-06-14

### Fixed

- **HE-AAC no longer needlessly bridged to EAC3.** HE-AAC (SBR) and HE-AACv2 (PS) audio tracks were unconditionally routed through the audio bridge and re-encoded to EAC3, even from movie containers AVPlayer decodes natively. The forced bridge is now gated on the source lacking an AudioSpecificConfig (live ADTS/MPEG-TS, where a synthesized ASC would mis-signal SBR); a container that ships a valid ASC fMP4 stream-copies and plays natively. Reported by DrHurt (#33). ([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.4.1))

## [3.4.0] — 2026-06-12

### Added

- **Demuxed-audio HLS direct play.** Live upstreams whose variants are video-only with a separate `EXT-X-MEDIA` audio playlist (ARD and friends) now direct-play with sound: `HLSLiveIngestReader` spawns a companion rendition reader, a side demuxer opens the audio stream, and the segment producer merges both sources by DTS into one output timeline. Previously these variants failed fast (3.3.0's detection) and forced a server-mediated fallback.
- **Packed-audio renditions.** Audio playlists carrying raw ADTS segments framed by ID3 `PRIV` timestamps (`com.apple.streaming.transportStreamTimestamp`, 90 kHz) are classified per segment and wrapped on the fly (`PackedAudioSegments`), with a synthesized clock aligning them to the video timeline.
- **Live playlist-refresh retry.** Transient refresh failures (CDN hiccups, origin restarts) retry inside a bounded ~12 s budget before the ingest goes terminal, so a single dropped poll no longer kills the session.

### Fixed

- **Live reloads rejoin at the live edge.** An audio-track switch (or any engine reload) on a live session used to re-apply the stale resume position against a server that re-served its full transcode backlog, which could park AVPlayer in `waitingToPlay` forever (device-verified on tvOS 26 + Jellyfin). Reload positioning is now policy-driven (`LiveReloadPolicy`): live rejoins take the playlist's own live-edge join and skip the pre-readiness zero seek; a readiness watchdog (10 s budget from first serving evidence) fails a wedged rejoin cleanly into the host's retune surface instead of hanging.
- **Swallowed play intent on the reused AVPlayer host.** A `play()` issued while `replaceCurrentItem` was mid-swap could be silently dropped, leaving the item `readyToPlay` but parked in `paused`. The host now latches the play intent and re-asserts it at `readyToPlay` (cleared on pause/unload).
- **Published audio index after a live reload.** The engine reconciles the published audio-track selection with what the rebuilt pipeline actually plays, so hosts no longer see a phantom track switch.

### Tooling

- `aetherctl live --reload-test` exercises the live rejoin end to end against the built-in fixture, including the Jellyfin full-backlog replay shape.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.4.0))

## [3.3.1] — 2026-06-12

### Fixed

Reliability release: a two-pass full-codebase audit (every file reviewed twice, the second pass adversarially re-verifying the first) fixed ~60 defects and removed ~350 lines of dead code. Highlights:

- **FFmpeg audio-only path actually paces, pauses, and seeks.** A CMSampleBuffer timing bug made every coalesced buffer report its sample count squared as duration, wedging the buffer-ahead gate after one packet (~20 ms audio, then silence); `play()` after `pause()` never resumed the synchronizer; seeks never reset the enqueue high-water mark (backward seek = minutes of silence) and a seek landing in the EOF drain window skipped the track.
- **Resource leaks.** Every demuxer open leaked its 256 KB AVIO buffer (`avio_context_free` does not free `ctx->buffer`); closing a chunked (no-Content-Length) stream leaked the connection, URLSession, and a parked thread; streaming mode gained backpressure so a paused consumer no longer buffers the rest of the file at line rate; `AVChannelLayout` copies are now uninitialized.
- **Teardown and supersession races.** `stop()` no longer blocks behind a producer restart's 5 s wait; a scheduled audio-track switch can no longer resurrect a dismissed session or hijack a newer load; seeks landing mid-stop no longer publish a phantom `.playing`; subtitle track switches no longer let a superseded task overwrite the successor's cues or abort handle.
- **Stale state.** Live TV after an HDR10 film no longer reports `.hdr10` all session; video-to-music switches release the old video AVPlayer; the public `stop()` clears the session identity so background-return hooks can't revive it.
- **Correctness.** Plain-HLG sources now signal `VIDEO-RANGE=HLG` (was PQ) on the H.264 / HEVC routes; live-variant selection no longer reads `AVERAGE-BANDWIDTH` as `BANDWIDTH` (and ignores quoted-value content); 8-channel AAC is no longer declared stereo in the synthesized AudioSpecificConfig; two simultaneous ASS speaker lines with identical timing both survive dedupe; a VT callback force-unwrap crash and several decoder/renderer data races are locked; keep-alive framing on the loopback server survives a segment file changing size mid-response.
- **Diagnostics and tooling.** FFmpeg log dedupe actually works under the custom callback; the packet-leak counter no longer drifts on DV5 sources; `aetherctl` no longer hangs on large `validate` reports, crashes on out-of-range/NaN flag values, or kills the reconnect its own `--drop-after` fixture is testing.

No public API changes (one inert no-op method with no consumers was removed; see release notes).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.3.1))

## [3.3.0] — 2026-06-11

### Added

- **Sidecar subtitles with auth headers.** `selectSidecarSubtitle(url:httpHeaders:)` attaches custom HTTP headers to the subtitle fetch and forwards the session's `LoadOptions.httpHeaders` by default, so subtitles on authenticated hosts (WebDAV and friends) load like the media itself (#32, requested by @bitxeno).
- **Live HLS ingest (`HLSLiveIngestReader`).** Public forward-only `IOReader` that plays a live HLS upstream directly: resolves master playlists (highest-BANDWIDTH variant), polls the media playlist, fetches the MPEG-TS segments sequentially, and feeds them to the demuxer as one continuous TS stream. Phase 1 supports unencrypted TS segments; `EXT-X-KEY` and `EXT-X-MAP` playlists terminate with a typed `HLSIngestError` so hosts can fall back to a server-mediated path. The live-edge join is duration-capped (newest segments covering up to 1.5x the upstream target duration), and the local loopback playlist adapts to the upstream's real cadence: sources whose segments are materially longer than the cut target drop the LL-HLS blocking-reload advertisement and raise `TARGETDURATION` to the arrival cadence, which is what keeps AVPlayer from flagging invalid blocking behavior (-15410) and stalling on bursty upstreams.
- **Live custom sources reach the native loopback.** `Demuxer.open(reader:)` now threads `isLive` into the demuxer options (suppressing the duration-estimate SEEK_END that latched EOF on forward-only readers), and the forward-only-means-software dispatch rule is exempted for live sessions.
- **`aetherctl hlsfixture`.** Local HLS live fixture server (sliding window, master indirection, discontinuity/slow-refresh/404/encrypted/fMP4 fault knobs) with a `--self-test` mode that runs `HLSLiveIngestReader` against it end to end.

### Fixed

- **Live custom-source loss surfaces to the host.** A live custom source whose pump exits no longer enters the URL-reopen backoff (impossible for a synthetic custom URL, it stalled silently after ~23 s of doomed retries); the engine fires the existing `liveSourceReset` retune surface instead.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.3.0))

## [3.2.0] — 2026-06-11

### Breaking

- **Live telemetry moved to `engine.diagnostics`.** The 1 Hz `liveTelemetry` snapshot was the last timer-driven `@Published` on the engine itself: the sampler rewrote it every second of every session (VOD included), so any SwiftUI view observing the engine re-rendered once per second for the whole session, the same render-storm class the 3.0.0 clock split fixed for `currentTime` (#29 follow-up, reported by @ohjey). It now lives on `EngineDiagnostics`, a separate `ObservableObject` mirroring the `PlaybackClock` split. Migration: plain reads (`engine.liveTelemetry`) compile unchanged through a read-only forwarder; Combine/SwiftUI subscriptions move from `engine.$liveTelemetry` to `engine.diagnostics.$liveTelemetry`.

### Added

- **tvOS integration note: SwiftUI `Menu` in custom player chrome.** On tvOS 26 an open SwiftUI `Menu` blinks its focused row whenever any render transaction runs in the hosting tree, even in unrelated leaf views (SwiftUI issue, reported to Apple). README now documents the UIKit-owned menu-button pattern (`UIButton` + `button.menu` in a `UIViewRepresentable` that only replaces the `UIMenu` on real item changes), courtesy of @ohjey (#29).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.2.0))

## [3.1.0] — 2026-06-11

### Added

- **`engine.fontAttachments`.** Embedded font attachments (TTF / OTF) from the loaded container, exposed as `[FontAttachment]` (filename, MIME type, raw data) so hosts can stage them into a font directory for an ASS renderer. Populated on every `load()`, cleared on `stop()`; survives the in-session audio-switch reload (#30 host contract).
- **`ASSScriptBuilder`.** Reassembles the engine's raw paced ASS event cues (`LoadOptions.preserveASSMarkup`) plus `TrackInfo.assHeader` into a complete ASS script for whole-file renderers such as swift-ass-renderer's `loadTrack(content:)`. Hardened against real-world Matroska tracks: synthesizes the `[Events]` section when CodecPrivate lacks it, strips NUL terminators that make libass stop parsing, and dedupes by event content (start, end, line) because real files hardcode `ReadOrder: 0` on every line.

### Fixed

- **Post-scrub A/V desync and picture jumps on the software path.** The fragmented-MP4 muxer wrote an edit list into `init.mp4` that baked the producer's restart position into `elst`. AVPlayer pins the first `EXT-X-MAP` it sees, so after a backward scrub the stale edit list shifted the presentation timeline: lipsync drifted and the picture jumped. Edit lists are now disabled (`use_editlist=0`); the restart offset travels exclusively via per-track `tfdt`, making `init.mp4` restart-invariant.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.1.0))

## [3.0.1] — 2026-06-10

### Fixed

- **Persistent-reader window no longer leaks its backing storage.** The sliding window trimmed consumed bytes with `Data.removeFirst`, which only advances the slice's lower bound: the backing allocation kept growing with every byte ever streamed through the connection (~14 MB/s on an 80 Mbps remux) while the window's logical size held at ~20 MB, until jetsam killed the app on large files. The trim now re-bases the window into fresh compact storage; a 512 MB standalone repro went from +513 MB footprint to +9 MB flat. Same pattern fixed in the sequential streaming reader. Second half of #31 (the first half, subtitle side-demuxer pacing, shipped in 3.0.0).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.0.1))

## [3.0.0] — 2026-06-10

### Breaking

- **High-frequency playback clock moved to `engine.clock`.** The continuously ticking values (`currentTime`, `sourceTime`, `progress`, `liveEdgeTime`, `seekableLiveRange`, `isAtLiveEdge`, `behindLiveSeconds`) now live on `PlaybackClock`, a separate `ObservableObject`, so the ~10 Hz ticks no longer fire `objectWillChange` on the engine itself. SwiftUI views that observe the engine for track lists / state stop re-rendering per tick; native tvOS `Menu` dropdowns no longer flicker during playback (#29). Migration: plain reads (`engine.currentTime`) compile unchanged through read-only forwarders; Combine subscriptions move from `engine.$currentTime` to `engine.clock.$currentTime` (same for the other clock values).

### Added

- **`probe(source:)`.** The one-shot metadata probe now accepts a `MediaSource`, so custom `IOReader` sources can be probed like URLs. The caller keeps reader ownership; the probe never calls `close()` (#27).
- **`load()` returns `SourceProbe`.** Both `load(url:)` and `load(source:)` return the probe assembled from the internal probe stage (`@discardableResult`, existing callers compile unchanged): video size, codec, duration, tracks, container tags in one shot. `sourceVideoWidth` / `sourceVideoHeight` are also public read-only now (#28).
- **Opt-in raw ASS event lines.** `LoadOptions.preserveASSMarkup` emits ASS / SSA cues as the raw event line (override tags, style references, escapes intact) instead of stripped plain text, and `TrackInfo.assHeader` carries the track's script header (`[Script Info]` + `[V4+ Styles]`) so hosts can render authored styling themselves. Default off; non-ASS codecs unaffected (#30; full libass rendering stays open there).
- **Live DVR scrub thumbnails.** `liveScrubThumbnail` decodes preview stills straight from the DVR segment cache, with an LRU keyed to the live session generation.
- **`DataIOReader`.** A ready-made in-memory `IOReader` over an immutable `Data` buffer, for composed-buffer demuxing and tests.
- **Native remote-HLS path.** `LoadOptions.nativeRemoteHLS` plays a server-provided HLS URL directly with AVPlayer (live edge, buffering, reconnect managed natively), bypassing the demux / remux / loopback pipeline.
- **SW-path deinterlacing.** Interlaced sources route through a persistent bwdif / yadif filter graph on the software decode path.
- **HE-AAC / LATM bridging.** LATM/LOAS AAC live audio bridges instead of dropping; mis-signaled ADTS streams bridge instead of corrupt stream-copy; plain ADTS-AAC stream-copies into fMP4 without the FLAC bridge.

### Fixed

- **Embedded-subtitle side demuxer no longer races to EOF.** It paces against the playhead (90 s read-ahead; TCP backpressure throttles its connection to playback rate). Previously it re-downloaded the entire remaining file alongside playback and pinned every future PGS bitmap cue in memory, which on 50-80 GB UHD remuxes ran the app into jetsam (#31, subtitle part).
- **Live hardening batch.** Server-side stream-replay detection after reconnect (host retune request), program-boundary timeline rebase instead of packet drops, A/V-sync rebase pairing with seam history, source-loss auto-reopen with backoff, deterministic pause/resume, LL-HLS blocking playlist reload for faster startup, fast give-up on dead tuners (hard HTTP errors / never-productive sources), abortable in-flight probes on stop / channel zap.
- **VOD robustness batch.** Muxer-wedge exit, audio-bridge EOF / restart flush, Range-ignored (200-at-offset) guard, cache-gated backward restart, paused-seek clock anchor, corrupt-source-audio resilience in `swr_convert`.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.0.0))

## [2.5.0] — 2026-06-08

### Added

- **Live TV and DVR (timeshift) playback.** `LoadOptions.isLive` opts a session into unbounded live mode. Pass `dvrWindowSeconds` (e.g. `1800`) to enable in-session timeshift; omit it (nil) for live-only playback where `seek()` is a no-op. The host drives a single scrubber against a session-relative timeline (seconds since first frame) that is identical across both the native and software paths.
- **Native-path live (H.264 / HEVC / AV1-with-HW).** A forward-only live producer cuts segments on the fly and serves a sliding HLS playlist (advancing `#EXT-X-MEDIA-SEQUENCE`, no `#EXT-X-ENDLIST`, no `#EXT-X-PLAYLIST-TYPE`) to AVPlayer. Timeshift uses AVPlayer's native seekable range; discontinuities are signaled via `#EXT-X-DISCONTINUITY` so the session timeline stays monotonic.
- **Software-path live (AV1-without-HW / VP9 / MPEG-2 / VC-1).** Unbounded live with no duration guard. Timeshift is backed by a disk-spooled, keyframe-indexed `PacketRingBuffer` that retains up to `dvrWindowSeconds` of packets; seek within the ring rewinds without a network round-trip. PTS-offset repair keeps the session timeline monotonic across source discontinuities.
- **`LoadOptions.dvrWindowSeconds: Double?`.** Nil (default) enables live-only mode. A non-nil value enables timeshift with that rewind window in seconds; `1800` (30 min) is the suggested starting point for IPTV / broadcaster feeds.
- **`@Published private(set) var liveEdgeTime: Double`.** The current live edge expressed as session-relative seconds since the first frame. Advances continuously during live playback.
- **`@Published private(set) var seekableLiveRange: ClosedRange<Double>?`.** The DVR-seekable span of the session timeline. Nil when DVR is disabled or the session is not live. Hosts can bind a scrubber's range directly to this property.
- **`@Published private(set) var isAtLiveEdge: Bool`.** True when the playhead is within a small threshold of `liveEdgeTime`. Note: this is generally false during normal live playback because it anchors on the buffered live edge; call `seekToLiveEdge()` to snap to live rather than polling this flag.
- **`@Published private(set) var behindLiveSeconds: Double`.** Seconds the current playhead lags behind `liveEdgeTime`. Zero when at the live edge or when DVR is disabled.
- **`func seekToLiveEdge() async`.** Snaps the playhead to the live edge, on both paths. Safe to call at any time during a live session; no-op when live-only.
- **`seek(to:)` extended for DVR.** In a live session with DVR enabled, `seek(to:)` accepts a session-relative position clamped to `seekableLiveRange`. In live-only sessions it remains a no-op, preserving the existing contract for callers that do not opt into DVR.
- **`AVIOReader` endless-feed mode.** The demuxer AVIO no longer synthesizes EOF from a `Content-Length` header in live sessions. Terminal error is reported only after reconnect retries are exhausted, so transient CDN drops don't terminate the session.
- **Stable live `#EXT-X-TARGETDURATION`.** Live playlists declare a generous, stable target duration from the first manifest and hold the initial response until the first segment is ready, so high-bitrate live sources no longer fail at startup with `CoreMediaErrorDomain -12888`.

### Notes

- Live sliding-window memory behavior and `behindLiveSeconds` accuracy were verified off-device (resident-footprint plateau under a sliding playlist, stable behind-live at real-time pacing). On-device confirmation on Apple TV with a real broadcast feed is still recommended.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.5.0))

## [2.4.0] — 2026-06-07

Custom input sources. A new public `IOReader` protocol lets hosts play media from any byte source (memory buffers, encrypted-at-rest archives, proprietary containers) through `load(source: .custom(...))`. No breaking API change, existing `load(url:)` callers are unaffected.

- **`IOReader` + `MediaSource` + `load(source:)`.** Implement `read` / `seek` / `close` and pass an instance via `MediaSource.custom(_:formatHint:)`. `load(url:)` is retained and forwards to the new entry point. Internally the engine attaches the reader to the demuxer's `AVFormatContext.pb`, the same seam the built-in `AVIOReader` uses, so no FFmpeg types are exposed (resolves #26).
- **Both playback paths, video and audio.** Seekable readers play on the native (AVPlayer / HLS-remux) and software decode paths; audio-only custom sources route through the software audio path (AVPlayer is URL-only). Forward-only readers (seek returns negative) play too, auto-routed to the software path.
- **Full mid-playback feature set on capable readers.** Audio-track switching and background reload work for seekable readers (the pipeline rebuilds on the retained reader). Embedded-subtitle selection and scrub-preview thumbnails work for readers that implement the new optional `makeIndependentReader()` (a second independent cursor); they no-op when it returns nil.
- **`cancel()` is now a protocol requirement** (with a default no-op) so a host override dispatches through the `any IOReader` existential. It must only unblock a pending read, never invalidate the reader, since the engine reuses the reader across an internal reload.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.4.0))

## [2.3.0] — 2026-06-06

New public API for media metadata, plus episode-autoplay playback-reliability fixes. No breaking API change, existing 2.x callers are unaffected.

- **`MediaMetadata` extracted on every load.** The demuxer parses normalized container tags (title, artist, album, albumArtist, with whitespace cleanup) and pulls embedded cover art. The engine publishes it at load time and exposes it through `SourceProbe`, and `aetherctl` prints the parsed container metadata in its probe output. Driven by the AetherPlayer media-player work.
- **Episode autoplay no longer starts audio before video.** The native `AVPlayer` reused across native-to-native reloads (since 2.2.1) carried its previous `rate=1.0` into the next item, so the new episode auto-resumed before the display-criteria handshake and played audio while the panel was still mid Match-Frame-Rate switch. The host now pauses the player across the item swap, so the post-handshake `play()` gates the start.
- **No more mid-playback stall plus A/V desync a minute or two into a stream.** `SegmentCache` evicted already-produced forward segments when AVPlayer did a transient backward refetch (an audio handover or decode flush moved the prune target back), which forced a cache-miss producer restart that re-muxed from a fresh init segment. The forward prune bound is now anchored on the highest stored index so produced-but-unconsumed segments survive the dip, and the restart decision no longer treats a resident segment the producer merely raced past as a pruned gap.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.3.0))

## [2.2.2] — 2026-06-06

Playback-clock correctness. The engine now presents a single source-PTS timeline. No breaking API change, existing 2.2.x callers are unaffected.

- **Unified the playback clock onto source PTS.** On the native HLS path `currentTime` previously mirrored AVPlayer's loopback clock (`source_pts - playlistShiftSeconds`) while `sourceTime` carried source PTS, forcing every source-timeline consumer (subtitle scheduling, media-segment intro/outro detection, resume reporting) to pick the right one of two clocks. The shift is now folded into the published `currentTime`, so `currentTime == sourceTime` on every path (the software and audio paths already ran on source time). Resume and `reloadAtCurrentPosition` get slightly more accurate as a result, and on a rare imprecise restart seek the reported position now reflects the true landed frame.
- **`seek(to:)` is now source-PTS based** and converts to the loopback clock internally (a no-op on the software and audio paths, where the shift is 0). A `seek(toSourceTime:)` alias exists but is deprecated, since `seek(to:)` now covers it. `sourceTime` stays public as a stable alias for callers that want to express source-timeline intent explicitly.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.2.2))

## [2.2.1] — 2026-06-06

Playback, audio, and Now-Playing fixes. No public API change, existing 2.2.x callers are unaffected.

- **Persistent forward-streaming AVIO reader for CDN direct-URL playback (#25).** The fragile chunked range reader is replaced with a VLC-style single forward-streaming connection that reconnects with backoff on drops. Waiting on data is now edge-triggered, and the reconnect cap is progress-aware so a stream that keeps advancing is not killed by a transient stall.
- **Multichannel audio no longer downmixes to stereo with continuous-audio off (#24).** Audio-route capability is sampled after playback settles rather than at `readyToPlay`, when the HDMI route has not finished negotiating yet. The native path lets AVKit own audio-session activation, and the manual reassert is scoped to the renderer paths that actually need it. (Earlier session-reassert and route-renegotiation attempts in this cycle were disproven on device and reverted.)
- **System Now-Playing survives native-to-native reloads (#15).** Episode autoplay and audio-track switches reuse the existing native `AVPlayer` via `replaceCurrentItem` instead of building a fresh one, which previously blanked the Control Center Now-Playing card on every swap.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.2.1))

## [2.2.0] — 2026-06-05

New public API: an audio-only playback path. `LoadOptions.audioOnly` routes a source into a lean audio pipeline that never builds the HLS loopback server, the display layer, or the video producer. Decode is native-first: codecs on the `avPlayerCanDecodeAudio` whitelist hand the URL straight to a bare `AVPlayer` (`AudioAVPlayerHost`), everything else falls back to an FFmpeg decode into `AVSampleBufferAudioRenderer` (`AudioPlaybackHost`). The engine branches `load()` into the audio path, routes transport (play / pause / seek) to the active host, and tears the host down in `stopInternal` for a clean handoff back to the video path.

System Now-Playing for the audio path: the AVPlayer host owns a persistent per-player `MPNowPlayingSession` (exposed via `audioNowPlayingSession`) that stays the active Now-Playing app across a background pause, auto-publishes now-playing info from the player, and carries `externalMetadata`. The host survives across tracks (no per-track teardown) and does not pause when the app backgrounds, so audio keeps playing with the system overlay live. All of this is gated `#if os(tvOS) || os(iOS)`; the path builds clean on macOS (no system session there) and iOS as well as tvOS.

New `aetherctl audio` subcommand for audio-path smoke testing: prints the active decoder and final duration, driven under `CFRunLoop` so end-of-track fires at playback end rather than demux EOF.

Minor bump: purely additive public API, no breaking changes. Existing 2.1.x callers compile and run unchanged.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.2.0))

## [2.1.3] — 2026-06-01

Playback fix. Transport state sync. No public API change, existing 2.1.x callers are unaffected.

- **Rapid play/pause presses no longer get swallowed.** On the native (AVPlayer) path the engine never derived its `state` from the player. When something other than `engine.play()` / `pause()` drove the AVPlayer (a host that keeps AVKit's transport bar active for Control Center skip routing, Control Center itself, or the hardware play/pause button AVKit handles internally), the engine's `state` went stale and the next `togglePlayPause()` resolved to the action already in effect, a visible no-op. `NativeAVPlayerHost` now publishes `timeControlStatus` and the engine reconciles `state` (playing / paused) from it, guarded to the steady transport states so loading, seeking, error and idle are never clobbered (`waitingToPlayAtSpecifiedRate` maps to playing so the icon does not flicker on a rebuffer). `togglePlayPause()` additionally decides from the live player rather than the published state, closing the async gap during fast presses.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.1.3))

## [2.1.2] — 2026-06-01

Playback fix. Head-of-stream A/V sync. No public API change, existing 2.1.x callers are unaffected.

- **Audio no longer leads video at file start.** On a fresh play (`baseIndex 0`) the producer snapped the first audio packet onto the video's `tfdt` (desired 0), which subtracted the audio track's intrinsic start offset from every audio packet. On sources whose first full audio frame lands well past video frame 0 (Cars: EAC3 first frame at +256 ms) this pulled the whole audio track that far ahead of the picture for the entire session (reported as a 256 ms A/V offset in the stats overlay). Head-of-stream now derives the audio shift from the video's origin shift, so both streams undergo one shared transform and their true source-time relationship is preserved by construction. Resume and scrub sessions were unaffected and keep the existing gate-on-video snap.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.1.2))

## [2.1.1] — 2026-05-31

`FrameExtractor` quality pass. Internal only, no public API change, existing 2.1.0 callers are unaffected.

- **HDR thumbnails tone-map correctly.** PQ (ST 2084) and HLG stills used to render too dark / desaturated because the extractor scaled straight to sRGB with no transfer conversion. HDR frames now route through a zscale + tonemap libavfilter graph (BT.2020 PQ/HLG to SDR BT.709 RGBA, hable tone curve); SDR keeps the direct sws path. Requires the avfilter + zimg FFmpegBuild (already pinned).
- **Faster, lighter remote extraction.** A `.stillExtraction` demuxer profile gives the extractor's AVIO a random-access shape: no read-ahead prefetch (which a scrub discards on the next seek and which competed with playback bandwidth), a 1 MB seek chunk, and a small probe budget. Plus decode fast-flags (skip loop filter, fast decode).
- **Fix: thumbnails on sparse-keyframe HEVC.** The thumbnail decode no longer sets `skip_frame = NONKEY`, which starved the decoder when a seek landed mid-GOP past a lone keyframe (nil thumbnail on some HEVC sources).

Known limitation: DV Profile 5 (IPT-PQ, no HDR10 base) thumbnails still have wrong colours on the software decode path, same class as the AV1 Profile 10.0 limitation. Full P5 playback is unaffected (native AVPlayer path).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.1.1))

## [2.1.0] — 2026-05-31

New public API: `FrameExtractor`, off-playback still-image extraction. Produces `CGImage`s from a media URL through an FFmpeg decode context fully isolated from playback (no contact with the HLS loopback server or shared engine state). Two modes share one decode core: `thumbnail(at:maxWidth:)` snaps to the nearest keyframe and downscales (scrub previews, Recents lists), `snapshot(at:maxSize:)` decodes forward to the exact PTS at full resolution (user stills).

`FrameExtractor` is an `actor`: blocking FFmpeg work runs on a dedicated serial queue off the cooperative pool, the decode context opens lazily, a superseded request cancels the in-flight decode so the latest scrub position wins, results land in a bounded LRU cache (mode-isolated stores, second-bucketed thumbnails), and the context idle-closes after 10 s. `shutdown()` is the explicit permanent teardown that awaits release of the FFmpeg resources.

`AetherEngine.makeFrameExtractor()` vends an extractor for the currently loaded URL (carrying its HTTP headers); arbitrary items construct `FrameExtractor(url:httpHeaders:)` directly. The engine does not retain the returned extractor; the caller owns its lifecycle.

New `aetherctl extract` subcommand for still extraction + leak testing (`--at`, `--snapshot`, `--width`, `--loops`), backed by the same public API.

Minor bump: purely additive public API, no breaking changes. Existing 2.0.x callers compile and run unchanged.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.1.0))

## [2.0.2] — 2026-05-28

Follow-up bugfix to 2.0.1's Profile 5 work. The colr fix in 2.0.1 put the PQ transfer signal on the output sample entry but AVPlayer still failed the asset with `CoreMediaErrorDomain -4` because the source MP4's `hvcC` carried only the 22-byte configuration header (`numOfArrays = 0`) with VPS / SPS / PPS in-band on every IRAP packet. `CMVideoFormatDescription` cannot be built from a `dvh1` sample entry whose configuration record has no parameter set arrays. The matroska demuxer doesn't hit this because matroska parameter sets live in `CodecPrivate`, which FFmpeg lifts into `codecpar.extradata` as a complete annex-B sequence that the mp4 muxer's `ff_isom_write_hvcc` then rebuilds properly.

The fix scans the first IRAP packet for VPS / SPS / PPS NAL units, builds a proper hvcC byte sequence (header + 3 parameter set arrays), and replaces the output stream's `codecpar.extradata` before `avformat_write_header`. Gated on the precise signal: HEVC codec, extradata ≥ 23 B with byte 22 = 0, NALU length size 4.

Verified locally against the issue #19 sample: loopback playback advances in QuickTime / AVPlayer, init.mp4 has all four boxes (`dvh1` + `hvcC` 125 B with parameter sets + `colr nclx 9/16/9` + `dvcC` P5 L6 compat=0), colors render correctly.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.0.2))

## [2.0.1] — 2026-05-28

Bugfix release: Dolby Vision Profile 5 MP4 sources whose SPS VUI omits the transfer characteristic and whose container has no `colr` atom now play correctly. Previously the engine stream-copied the gap through to its output fMP4, so AVPlayer saw a `dvh1` sample entry with no PQ signal and refused to engage the DV decoder. The same content as MKV played fine because matroska's `Colour` element gives FFmpeg explicit `codecpar.color_*` that the mp4 muxer writes as a `colr nclx` atom; the mp4 demuxer has no equivalent fallback.

The fix forces the canonical P5 color tuple (BT.2020 / PQ / BT.2020-NCL / limited range) on the muxer's stream codecpar before `avformat_write_header`. P5 is defined as IPT-PQ-c2, so the `dvcC` record alone implies that signaling, which makes the override safe (no risk of mislabeling a non-PQ source).

Reported by @strangeliu (issue #19), diagnosed with @DrHurt's broken-vs-Dolby-reference framing.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.0.1))

## [2.0.0] — 2026-05-27

Stability milestone: the HDR / Dolby Vision routing path is now considered done after the DrHurt #4 sweep across multiple panel modes settled, and the adoption-readiness package (tests, CI, CHANGELOG, examples, Swift Package Index listing) makes the project safe to depend on. **No breaking changes to the public API surface** — existing 1.5.0 callers compile and run unchanged. The major version bump is a stability signal, not an API redesign.

Key user-visible changes since 1.5.0:

- **Match Dynamic Range OFF correctly detected.** tvOS exposes only one combined `isDisplayCriteriaMatchingEnabled` flag for Match Content (rate + range). Users with Match Frame Rate ON and Match Dynamic Range OFF previously had the engine route HDR sources through master playlists with `VIDEO-RANGE=PQ`, which AVPlayer rejected with -11848 / -11868 since the panel stayed in SDR. The engine now reads `UIScreen.currentEDRHeadroom` after the criteria handshake settles and uses that empirical reading for the master-vs-media routing decision.
- **`sourceVideoFormat` published.** Stats / debug overlays can now show "what's in the file" alongside "what the panel is presenting". A DV source on an HDR10-only TV now reads `sourceVideoFormat = .dolbyVision`, `videoFormat = .hdr10`.
- **LiveTelemetry + memory probe restart after audio-track switch.** Diagnostic samplers no longer go silent after the user picks a different audio track mid-session.
- **HLS producer reliability hardening.** Forward-scrub + back-scrub combinations no longer leave AVPlayer stuck waiting for evicted segments. The cache high-water reset moved AFTER the restart returns (was BEFORE, creating restart cascades). Proactive backward-jump restart applied to both `mediaSegmentURL` and `mediaSegment` (data) code paths.

Adoption-readiness additions:

- `Tests/AetherEngineTests/` with 12 unit tests covering pure-function surfaces.
- GitHub Actions CI runs `swift test` on macOS plus `xcodebuild` smoke builds for tvOS and iOS Simulators on every push and PR.
- `CHANGELOG.md` (this file) as an in-repo release index.
- README › Stability and versioning documents the SemVer contract for adopters.
- README › Known limitations spells out the deferred / accepted-loss items so adopters can size them before integration.
- `Examples/MinimalPlayer/MinimalPlayerApp.swift` — a 90-line SwiftUI drop-in app demonstrating the smallest viable AetherEngine integration.
- `.spi.yml` for Swift Package Index multi-platform build matrix.

Internal:

- `resolveCodecRoute` extracted out of `HLSVideoEngine.start()`. The 300-line codec / DV dispatch switch is now a private function returning a `CodecRoute` struct. `start()` drops from ~830 to ~520 lines. Pure refactor, no behaviour change.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/2.0.0))

## [1.5.0] — 2026-05-26

DV detection rewritten to read side-data before `color_trc` so DV Profile
8.4 (HLG base) and Profile 5 (often unspecified base-layer trc) enter the
DV branch. VP8 routed through the SW pipeline alongside VP9. MLP decoder
added to AudioBridge for BD-MV remuxes. New `aetherctl swdecode`
subcommand for reproducing SW-path issues locally. HLS producer restarts
cleanly on far-behind segment fetches. Display criteria preserved across
audio-track switches. EAC3+JOC auto-routes through the FLAC bridge on
Bluetooth A2DP / LE since Atmos passthrough is impossible over those
routes. ([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.5.0))

## [1.4.4] — 2026-05-26

Fixed `AVFoundationErrorDomain -11868` /
`AVErrorNoCompatibleAlternatesForExternalDisplay` on tvOS 26.5 for HDR /
DV sources (SDR was unaffected). Root cause: tvOS 26.5 enforces the
"criteria-before-load" ordering synchronously at HLS variant validation,
which AVKit-auto cannot satisfy for HLS multivariant HDR sources.
Engine-driven sole-writer is the only working pattern; hosts should set
`appliesPreferredDisplayCriteriaAutomatically = false` and pass
`LoadOptions(suppressDisplayCriteria: false)`. DV 8.1 / 8.4 emission
hardened: `hvc1` sample entry + `SUPPLEMENTAL-CODECS=dvh1.../db1p` on DV
panels, strip DV side data on non-DV panels.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.4.4))

## [1.4.2] — 2026-05-26

Live-stream scaffolding (`LoadOptions.isLive`, `@Published var isLive`,
`seek` becomes no-op when live). MPEG-4 Part 2 / MPEG-2 / VC-1 routed
through the SW pipeline. DV 8.1 emission now includes the `/db1p` brand
identifier on `SUPPLEMENTAL-CODECS` so AVPlayer's DV pipeline actually
engages. `DisplayCriteriaController.reset()` no-ops when no `apply()`
happened during the session, preventing nil-write races against AVKit's
in-flight criteria management.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.4.2))

## [1.4.1] — 2026-05-25

`waitForSwitch` Stage 1 grace extended from 200 ms to 1000 ms so AVKit's
async criteria write lands inside the gate. `play()` now waits for the
panel handshake to settle (initial load + audio-track-reload paths) so
DV / HDR cold-path first-frame stalls go away in AVKit-sole-writer hosts.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.4.1))

## [1.4.0] — 2026-05-25

Added `LiveTelemetry` 1 Hz sampler for host stats overlays. Added
`FFmpegLogBridge` routing `av_log` output through `EngineLog`. Fixed
`waitForSwitch` async-handshake race that surfaced as AVPlayer -11848
"Cannot Open" on DV sources (the previous `isDisplayModeSwitchInProgress`
guard misclassified the setter's async window as "no switch needed").
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.4.0))

## [1.3.2] — 2026-05-23

DV Profile 7 (UHD-BD remuxes) now plays: routed as plain HEVC HDR10 with
the source `dvcC` stripped from the muxer output, so VT's HEVC selection
doesn't reject the sample entry with -12906. Resolved CDN URL cached
across range fetches (debrid / signed-URL proxies were paying the
redirect on every Range request, ~6 ops/sec at 4K HEVC). Engine logging
unified through `EngineLog`.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.3.2))

## [1.3.1] — 2026-05-23

Producer's empty-cache restart now fires after far scrubs (previous "wait
for cold-start" assumption stalled AVPlayer for 30 s on back-scrubs after
a forward scrub had moved the producer far away). DV Profile 5 routes
through the master playlist on HDR-ready non-DV panels (DV→HDR10
tonemap), and through the media playlist on SDR-locked panels (where
tvOS 26 rejects bare `dvh1.05` master with -11868). A/V gap reported in
the audio-gate-open log.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.3.1))

## [1.3.0] — 2026-05-22

Audio bridge gained two modes: `.surroundCompat` (default, EAC3 per-channel
at 128 kbps, soundbar-compatible) and `.lossless` (FLAC up to 7.1, needs
multichannel-LPCM-capable AVR). `dec3` / `dac3` now built from packet
bitstream via the mp4 muxer's `+delay_moov` flag (no host-side
reconstruction). DV Profile 5 dispatch unified on `dvh1` sample entry +
`dvcC` regardless of panel, routing decides master vs media. Memory leaks
audited: URLSession task pool retention, subtitle cue accumulation,
periodic muxer recycle all root-caused.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.3.0))

## [1.2.0] — 2026-05-17

Audio FLAC-bridge gate target rescaled into source TB (the prior
encoder-TB rescale ran 48× too far into source on DTS-HD MA sources,
producing 44 s A/V drift on cold start). MP3 routed through FLAC bridge
(AVPlayer reads any `mp4a` sample entry as AAC and rejects MP3 frames with
-11829). Embedded subtitle PTS origin documentation + matroska NOPTS
repair.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.2.0))

## [1.1.0] — 2026-05-16

Three days of Sodalite public-beta feedback drove the A/V sync overhaul:
unconditional `AV_PKT_FLAG_KEY` video gate (initial-start as well as
restart), audio always waits for video gate, per-stream dynamic PTS shift
into the playlist origin, NOPTS dts repair, HEVC open-GOP CRA + leading
RASL B-frame drop. HDR / DV routing now respects the tvOS Match Content
master toggle. SDR rate-only display criteria (Match Frame Rate works
independently of Match Dynamic Range). HDR10+ runtime detection from T.35
SEI. Effective `videoFormat` clamped to panel capability.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.1.0))

## [1.0.0] — 2026-05-13

First stable release. Two coexisting playback pipelines (native AVPlayer
via local HLS-fMP4 loopback for HEVC / H.264 / native AV1; SW dav1d / VP9
through `AVSampleBufferDisplayLayer` for codecs AVPlayer's HLS-fMP4 path
rejects). HDR10 / HDR10+ / HLG / Dolby Vision Profile 5 / 8.1 / 8.4
support. Stream-copy passthrough for fMP4-legal audio codecs; AudioBridge
fallback for the rest. Bitmap + text subtitle decoder. LGPL-3.0 with App
Store exception.
([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/1.0.0))
