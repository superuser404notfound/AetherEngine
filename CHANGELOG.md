# Changelog

Quick index of AetherEngine releases. Detailed per-release notes (breaking
changes, full fix list, acknowledgements) live on
[GitHub Releases](https://github.com/superuser404notfound/AetherEngine/releases).

Versioning follows [Semantic Versioning](https://semver.org). See
[README › Stability and versioning](README.md#stability-and-versioning) for
the public-API contract.

## [Unreleased]

### Added

- **The first live manifest now reports the interval it was held for.** A loopback live session's whole
  join latency is one withheld `/media.m3u8` response: the first serve waits until the window carries
  the live-edge holdback (`3 x TARGETDURATION`, AetherEngine#189) of content behind the edge, while
  everything else the engine does for that session finishes before the gate is even entered. Only a
  FAILED gate used to log, so a successful hold of eighteen seconds left no trace and a host had to
  measure it from the outside. Every exit now names what it held, the window it served and the holdback
  it was measured against, including the exit where no segment was ever cut, which used to return in
  silence. The bounded `.fastZap` start reported its grace alone, which is the last leg of the wait
  rather than the wait: a start measured here at 10.284 s reported itself as 2.000 s. `docs/api.md`
  gains the paragraph that says where a live start's seconds go, and how `startupProgress` separates
  this wait from the probe and the display handshake. Raised by ksktech-dev (AetherEngine#374).

## [6.27.0] - 2026-08-16

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.27.0))

### Added

- **The legacy Microsoft video tail decodes: MS-MPEG4 v1 / v2 / v3 (DivX 3.x) and WMV1 / WMV2 /
  WMV3 (WMV9).** Routing already sent them to the software path, which is where they belong, and
  they then failed the load with `unsupportedCodec` because the FFmpeg build compiled no decoder
  for them: a pre-2005 AVI rip carrying MS-MPEG4 v3 stopped at `unsupportedCodec(id: 16)`, a WMV9
  remux at `unsupportedCodec(id: 71)`. Both now open and play. The `avi` demuxer was already in the
  build, so the AVI case needed nothing else; WMV3 covers WMV9 inside Matroska and MPEG-TS, where
  the container's own demuxer supplies the stream. A native `.wmv` / `.asf` file still fails at
  open: it also needs the `asf` demuxer and a WMA decoder, and half that set is worse than none,
  since with the demuxer alone the file would play video with silent audio rather than fail
  honestly. Costs 32 KB on an arm64 device slice. Reported by cmcpherson274 (FFmpegBuild#3).

### Dependencies

- FFmpegBuild 2.4.3 (the six legacy Microsoft video decoders; decoder count 40 to 46, only
  `Libavcodec` changed).

## [6.26.0] - 2026-08-15

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.26.0))

### Added

- `$errorInfo`, the machine-readable half of a `.error` state (#376). A `PlaybackErrorInfo`
  carrying a stable `PlaybackErrorKind` token, the underlying `NSError` domain and code where a
  Foundation / AVFoundation failure is involved, and the same message the state carries. The text
  alone could not classify a failure: on the native paths it is
  `AVPlayerItem.error.localizedDescription` forwarded verbatim, so it arrives in the device's
  language and the domain and code behind it are gone, which put every non-English device into a
  host's unknown bucket. `PlaybackErrorKind` is a string-backed struct rather than an enum, so a
  kind added in a later minor release cannot break a host's switch, and its raw values are API.

### Changed

- Every failure now publishes through one funnel, so a `.error` state can no longer reach a host
  without its classification. `errorInfo` is assigned before `state`, so a `$state` sink reads
  this failure's own, and it is cleared by the state's move away from `.error`, so the two cannot
  drift. A test fails the build if a new `state = .error(...)` appears outside the funnel.
- `docs/api.md` had claimed the message inside `.error` is the engine's own sentence. True for the
  half that names a cause, false for the half most failing sessions produce, and a downstream host
  was building an analytics classifier on the strength of it.
- The live-host sample and the README's API tour classify on `errorInfo` and keep the message for
  the log.

## [6.25.4] - 2026-08-14

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.25.4))

### Fixed

- A forwarded Annex-B config record no longer carries its prefix SEI into the `hvcC` the mp4
  muxer builds (#365). When the record and the packets are both Annex B the record has to be
  forwarded as it is, because movenc reads it to decide whether to convert the samples, and it
  then builds the `hvcC` itself. `ff_isom_write_hvcc` collects five NAL types, not three (VPS,
  SPS, PPS, SEI_PREFIX, SEI_SUFFIX), so a prefix SEI in a Matroska CodecPrivate becomes a fourth
  array in the init sample description. That is the record Apple TV's HEVC track builder rejects
  (AE#187: `asset.tracks count=0`, no format description), and the AE#187 defense cannot reach
  this door: it guards on `configurationVersion == 1`, which an Annex-B buffer fails by
  construction, and the muxer-built record never passes through the engine. The
  non-parameter-set NALs are now dropped before the muxer runs and the record stays Annex B, so
  the decision movenc makes about the samples is unchanged.

### Changed

- The `#365` forward branch logs what the config record is made of (`VPS×1 (28 B), SPS×1
  (112 B), PPS×1 (10 B), SEI_PREFIX×1 (570 B)`) and what it dropped. A record's size alone does
  not say whether the excess is a large SPS or an SEI, and only the latter reaches the `hvcC`.

## [6.25.3] - 2026-08-14

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.25.3))

### Fixed

- A bitmap subtitle set no longer keeps an end it took from the far side of a stretch nobody
  read (#362). A PGS set has no end of its own, so 6.23.1 gives an open one the PTS of the
  next packet the store holds, which is the end the author put there. After a seek burst the
  store also holds islands an earlier run harvested, and the first packet after a set can then
  be a real packet that is not this set's successor (report: a set at 75.117 s closed at
  144.978 s, its own clear at 78.579 s; a second one closed at the next SET, 78 s out). Two
  changes. A bitmap cue's end is now re-derived on every drain tick and can only ever shorten,
  so the clear that lands a second later trims the set even though the drain cursor has moved
  past it and will never decode it; previously any end short of the open-ended placeholder was
  final, and that was the whole permanence. And the derivation stops at the drain window plus
  the forward prefetch's park margin, which is exactly as far as the harvest is designed to
  lead, instead of reaching to whatever the store happens to hold beyond it.
- Ends withheld for that reason are counted in the delivery statement (`endsWithheld=N`).
  `harvestGapAt` reports where DELIVERY stopped and says nothing about an end derived from the
  same store on a different horizon, so a window carrying a wrong end with no `gapAt` beside it
  had no diagnostic at all.

## [6.25.2] - 2026-08-14

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.25.2))

### Fixed

- A sequential-origin VOD session now folds a timeline discontinuity the way live folds a
  program boundary (#368). IPTV timeshift archives are chunked recordings whose every chunk
  restarts near PTS 0; libavformat's 33-bit wrap correction turns that backward seam into a
  +2^33 leap (device: dts delta 8226410192 ticks, 363524400 + 8226410192 = 2^33 exactly),
  which reached the keyframe-gated cutter unmodified and walked its monotonic index to the
  plan tail. After that the session was structurally dead: the playlist froze, the
  backpressure park waited on a segment the playlist can never advertise, and the wedge
  recovery's reposition is exactly what a sequential origin refuses. The existing live
  rebase (both streams, same thresholds) now also runs for sequential-origin VOD; cutter,
  ledger and append playlist need no change because they already operate on post-shift
  output time. No `EXT-X-DISCONTINUITY` is added at the seam: the archive is
  content-continuous and the output timeline stays continuous after the rebase.
- A sequential-origin session publishes the item axis, so the rebase above no longer moves
  its playhead (#368 follow-up). The rebase keeps the item axis continuous by moving the
  producer's shift, but `currentTime` was folded as `item + shift - origin` against an origin
  latched once at session start, so the whole wrap landed on the scrubber: measured 250 s ->
  63378 s on an archive whose declared duration is one hour, with `bufferedPosition` and
  `sourceTime` following it. A sequential archive has no source axis to anchor a display
  origin on (every chunk restarts near PTS 0), while its item axis starts at 0 by
  construction and is exactly what `declaredDurationSeconds` measures. Every other source
  keeps AE#270's latched origin and true source PTS.
- A timestamp leap that escapes the timeline rebase no longer turns a VOD session into a
  long-lived zombie (#369). Three containment gaps, one field trace: the look-behind sample
  duration is now capped at the discontinuity threshold instead of handing movenc the wrap
  itself as a duration (device: 8226410192 ticks, rejected as invalid, packet silently lost;
  the write rc is now logged on first failure too); discontinuity-scale fold runs now reach
  the fold counters instead of being discarded above 64 indices, so the #358 recovery arms
  actually arm for exactly the folds most certain to trigger them; and the advance-path
  backpressure park skips a release target beyond the sequential playlist's advertisable
  frontier, which only this pump's own finalize reports can move, so parking on it was waiting
  for oneself. Deliberately unchanged: `OutputTimestampSanitizer` keeps latching, because
  movenc latches monotonicity on its own once a wrapped packet is accepted, and a sanitizer
  reset would only convert garbage timestamps into rejected writes.
- The duration cap above also covers the duration a container DECLARES, and the skipped park
  hands its wedge detection on instead of dropping it (#369 follow-up). The cap only guarded
  the inferred delta, but the branch that runs when no forward delta exists (the EOF tail of
  exactly the wrapped stream the cap is for) passed the source's own number through untouched,
  and movenc rejects a sample on the number, not on where it came from. The skipped park is
  the more consequential one: the #207 disk park deliberately has no wedge breaker because the
  advance park catches a frozen consumer first, so skipping the advance park left a pump that
  races to the retention budget and then holds there forever on a consumer that will never
  move again. It now carries the same #65 detector, whose one-second cadence this park already
  polls at, and a trip ends the pump onto the existing re-anchor surface, which a sequential
  origin refuses into `onVODSourceFailed` within seconds.
- A sequential-origin session now serves its EVENT playlist from the first finalized
  segment and no longer spends the origin's prefix on the keyframe-spacing scan (#370).
  The startup gate reused a live sliding-window constant and demanded 2 published
  durations, and because a duration is only final when the NEXT segment's ledger opens,
  that meant 3 segment opens (~12-18 s of media) before AVPlayer's held playlist GET was
  answered; on a stalling origin the GET sat out the full 30 s and the asset load died on
  -12884 with ~12 s of media already on disk. A one-segment EVENT playlist is legal HLS
  and the refresh counter already defeats the -12888 patience the live constant guards
  against. The spacing scan's seek is a silent no-op on the non-seekable sequential pb, so
  it consumed up to 30 s of the single byte-0-only connection without the pump ever seeing
  those packets; sequential plans now go straight to the target stride (the #358 holes the
  scan softens don't bite the append playlist, whose zero-duration holes get no URI), which
  also stops the archive's first GOPs from being read past before the pump starts. A pump
  that dies before publishing anything now also releases a held startup GET immediately
  instead of letting it sit out the rest of its timeout.
- The startup-GET release above is now tied to the failure surface rather than to two call sites,
  and the gate counts what the playlist can advertise (#370 follow-up). A sequential origin reaches
  three further terminal surfaces: `.muxerFailed` revives through `requestRestart`, which a
  sequential origin refuses, and the AE#366 moov-prime and AE#169 read-error arms end on their own
  exhaustion. Each of those can fire before the first duration is published (an E-AC-3 archive whose
  first segment carries no audio packet is the field shape), and the held GET then still sat out its
  full 30 s on a session that had already failed; every VOD failure now surfaces through one method
  that releases the wait with it. The gate also counted raw appended entries, while the renderer
  gives a zero-duration entry (a plan index a long GOP skipped) no URI, so it could have answered
  the held GET with a playlist that renders empty, which is the -12888 the gate exists to prevent.
  With the cushion down to one entry there is no second entry left to mask that, so the gate now
  counts advertisable entries.

## [6.25.1] - 2026-08-13

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.25.1))

### Fixed

- A VOD source that produces nothing at all now reports it instead of leaving the
  host on a playlist that will never gain a segment. The decision for that
  (`isFatalVODPumpExit`, #126) is about what the pump produced, not about how it
  died, but it only fired on a read error, so a source that runs to EOF without
  ever writing a packet fell through every arm: measured on such a file, the host
  sat at `state=playing phase=rebuffering` for the whole session while the
  provider answered `404 init.mp4 empty`. It now also covers `.eof`, and the
  gate-starvation re-anchor reports whether it actually re-anchored so a spent
  arm reaches the same surface rather than ending on a bare return. An ordinary
  EOF after real playback is untouched: what keeps this safe is the
  produced-nothing condition, which such a session does not meet.

## [6.25.0] - 2026-08-13

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.25.0))

### Added

- `VideoNALFraming`, the framing of a packet payload (Annex B or length-prefixed).
  `DoviRpuConverter.convertPacketToProfile81` and `enhancementLayerType` take it as a
  defaulted parameter, so existing calls are unchanged; a caller that hands them Annex-B
  packets now has a way to say so.

### Fixed

- A source whose selected audio track is sparsely interleaved no longer ends in
  a permanent black screen (#366). The first segment of an AC-3 / E-AC-3 source
  cannot be cut until one parsed audio packet has reached the muxer, and the
  search for that packet read forward from where the pump stopped, bounded at
  128 MiB. That bound is a byte bound, so what it buys shrinks as the bitrate
  grows: five minutes of a 3 Mbps encode, ten seconds of a 97 Mbps UHD remux,
  and a legacy dub track can have its first packet hundreds of MiB in. When the
  forward scan comes back empty the engine now seeks to a handful of positions
  and takes any frame the track yields there, which is enough because AC-3 and
  E-AC-3 are one complete syncframe per packet and the prime frame's timestamp
  is discarded anyway. Measured on a fixture whose first audio packet sits at
  211 MiB: the forward scan and the midpoint probe find nothing, the 90 % probe
  finds a frame after two packets, and the session plays with the audio landing
  exactly at its source timestamp. Nothing in the container points at the track:
  `AVStream.start_time` for that track reads 0.
- A VOD session that exhausts its muxer-failure revive budget now reports the
  failure to the host (#366). The arm was a bare `return`: no producer, no
  restart and no error, so the provider answered `404 init.mp4 empty` forever
  while AVPlayer sat in `waitingToPlay`, which reaches the viewer as a black
  screen with nothing in it to act on. Its sibling arm for read errors has
  surfaced its own exhaustion since AE#169. The terminal failure now carries a
  reason as well as a code, so a source that could not be muxed no longer
  reports itself as a failed read (three of the existing call sites, the #358
  unproducible segment and the sequential-origin reposition among them, were
  reporting the same wrong cause).

- A HEVC source whose config record is Annex B while its packets are
  length-prefixed no longer produces a session with no picture (#365). The mp4
  muxer decides whether to convert samples by looking at the extradata
  ("extradata is Annex B, assume the bitstream is too"), so on such a source it
  ran its Annex-B converter over MP4-framed samples and emptied them: measured
  on a 1080p fixture, a 2,158,448 B segment came out at 61,912 B while the
  init.mp4 stayed perfectly valid and AVPlayer reached `readyToPlay` without
  ever producing a frame. The engine now measures the framing on real packets at
  open and converts the record to an hvcC when the two disagree, so the muxer's
  own test comes out right. This is the shape a Matroska remux has when its
  CodecPrivate is Annex B or missing entirely, in which case libavformat
  synthesises Annex-B extradata from the first in-band parameter sets. The
  predicate mirrors movenc for H.264 as well (there it reformats on anything
  that is not an `avcC`), though an H.264 source of that shape usually fails
  further upstream: its parser cannot split the packets either.
- The DV Profile 7 to 8.1 rewrite is no longer a silent no-op on an Annex-B
  source (#365). Its NAL walk assumed length prefixes, so on start-code framing
  it read `00 00 01 40` as a 320-byte NAL, found no RPU, and shipped the P7 RPU
  and the enhancement layer inside a container the muxer had already rewritten
  to 8.1. It now takes the measured framing and emits the packet in the framing
  it received.
- The in-band parameter-set rebuild (#19) no longer runs on Annex-B extradata.
  Bytes 21 and 22 of an Annex-B HEVC record pass its two checks by construction
  rather than by luck (the `00 00 03` emulation-prevention pattern in a Main10
  VPS sits exactly there), so it scanned a buffer that is not a config record at
  all. `canonicalizeHEVCConfigRecord` has always had the `configurationVersion`
  guard; this path never did.

## [6.24.0] - 2026-08-13

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.24.0))

### Changed

- A live `.m3u8` on the raw live path is now routed onto the live ingest
  instead of failing closed (#363). The AE#140 detection stays (an `#EXTM3U`
  body where a container's first byte belongs), only its destination changes:
  the engine builds the `HLSLiveIngestReader` it used to name in the error, and
  that reader puts `LoadOptions.httpHeaders` on the playlist, on every segment
  and on every AES key, which is what a tokenized IPTV origin enforces per
  request. `AetherEngineError.hlsPlaylistOnRawLivePath` still exists and still
  throws for a custom `IOReader`, which has no playlist URL to ingest from.

### Fixed

- A live remote-HLS session that the origin refuses outright no longer dies at
  the mount (#363). HTTP 401 and 403 reach the item as `NSURLError` -1013 and
  -1102, and the engine now hands such a session to the live ingest, whose
  fetcher is a different client at that origin: configured headers on every
  request, at most four concurrent fetches, no AVFoundation user agent. Gated
  by `LoadOptions.nativeRemoteHLSIngestFallback` like the #168 carriage
  recovery, fires once per session, and is deliberately not remembered for the
  next load, because a refusal can be an expired token or a full connection
  cap rather than a property of the master.
- `aetherctl` can drive a header-enforcing origin at last: `play --header
  "Name: Value"` (repeatable) fills `LoadOptions.httpHeaders` and rides into
  the ingest reader, and `hlsfixture` grew `--require-header`,
  `--deny-status`, `--deny-user-agent`, `--deny-segments-only`,
  `--redirect-entry` / `--redirect-host` / `--redirect-port`, `--media-origin`
  and `--segments-dir`. The last one serves pre-cut, GOP-aligned segments, so a
  live run can be asked whether it PLAYS rather than only whether it routed.

## [6.23.1] - 2026-08-13

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.23.1))

### Fixed

- A bitmap subtitle now ends where its author ended it, not where the next
  landing happened to decode (#362). A PGS set has no end of its own; whatever
  packet follows on the stream closes it. The drain decodes a window bounded at
  the playhead plus its lead, and that forward edge falls wherever it falls:
  where it landed between a set and its clear, the set was published open, the
  cursor moved on, and the next thing to touch it was a composition at the next
  seek landing, tens or hundreds of seconds later. The packet store already
  held that clear, so an open set now takes its end from there, and the forward
  prefetch parks a margin beyond the drain window so the answer is stored
  before the set publishes.
- A stretch of a title no longer loses its subtitles after a seek burst (#362).
  A seek restarts the pump behind the landing while the store still holds an
  island the previous run harvested further ahead, and the drain decoded across
  that hole and carried its cursor past it, so the packets arriving a second
  later were never read. A tick now stops where the harvest ORDER breaks rather
  than where the gaps are widest, which is what separates a hole nobody has
  read from a silence the author left. The wait ends when the harvest closes
  the hole, when the playhead reaches it, or on a tick budget, so a silence can
  never stall delivery, and a tick that waited states itself in the delivery
  line.

## [6.23.0] - 2026-08-13

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.23.0))

### Added

- `startupProgress` publishes how far a load has come, for hosts drawing a
  determinate loading bar instead of an indeterminate spinner (#361). It is a
  fixed ladder of nine checkpoints, each recorded by the code that finishes the
  work it names, so the number never runs on a timer and never advances on an
  estimate: a slow stretch holds and a skipped one jumps. Two of those
  checkpoints cover stretches a host previously had no visibility into at all,
  and they are the two that dominate a slow start: the source open, split into
  connection, container and stream analysis, and the display-criteria
  handshake. The value is scoped to a startup generation that counts the waits
  a user actually sat through rather than teardowns, so an engine-initiated
  reroute (an HLS playlist discovered on the loopback path) continues the bar
  instead of dropping it back to zero mid-load. Monotonic and deduped; a load
  that fails or is stopped never reaches the last checkpoint.

## [6.22.1] - 2026-08-13

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.22.1))

### Fixed

- A seek no longer carries a pre-seek subtitle into the new position (#357).
  A PGS composition has no end of its own: it is published with FFmpeg's
  open-ended placeholder end and closed when its successor arrives. A jump
  outruns that successor, and the retention prune filters on the end time,
  which a placeholder can never age out of, so the old cue stayed in the
  published window covering the new playhead and every host that asks which
  cue is active rendered it. A reset tick now retires the unconfirmed end at
  the start of its reconstruction window, on the store and on the #100 hold
  alike. An authored duration is untouched.

## [6.22.0] - 2026-08-13

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.22.0))

### Added

- `systemCaptionRequest` publishes a caption request the system made on its
  own (Sodalite#65). iOS 26 turns captions on by itself when playback is
  muted, when the user skips back, or when the audio language differs from the
  system language, and none of those three toggles has a read API. What the
  system does have is an effect: it selects a legible option in the item. The
  engine keeps deselecting that option, because its renditions exist for PiP,
  AirPlay and external screens and rendering one in fullscreen draws a caption
  box over a host's own subtitles, and it now reports the request instead of
  swallowing it. The payload is the option's language tag rather than a track
  id, because rendition ordinals are matched by language rank and not
  positionally.
- `setTeletextPage(_:)` changes the teletext caption page while a channel
  plays (#364). The page used to reach `EmbeddedSubtitleDecoder` only at
  construction, so it was fixed for the life of a selection and a channel
  whose caption page libzvbi does not flag as a subtitle page could only be
  corrected by leaving it, changing a setting and coming back. It now travels
  with the decoder rebuild the drain path already performs, and only the
  channels actually showing a teletext track are re-decoded. `teletextPage`
  reads the page in force; the value lands in the session's load options, so
  the internal reopens (audio switch, background reload) replay it.
- `aetherctl play --teletext-page N` fixes the page at load and
  `--switch-teletext-page <page|auto>[@ms]` changes it on the playing channel,
  which is what makes the runtime path measurable from the CLI at all.

### Fixed

- The native legible rendition stays deselected for the whole session rather
  than for its first two seconds (Sodalite#65). The pin covered AVKit's
  ready-time auto-select and nothing after it, so iOS 26's automatic captions,
  which fire minutes into a session, had nothing holding them back and AVKit
  rendered the rendition over the frame as an empty caption box. A
  media-selection observer now holds the deselect for the item's whole life,
  bounded against a selection fight it cannot win: several re-asserts inside
  one second stand down and log instead of spinning.

## [6.21.1] - 2026-08-12

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.21.1))

### Fixed

- A live subtitle rendition re-anchors when the source axis moves under it
  (#359). The placement pairs a segment's wall time with the session's shift,
  and a producer seam republishes that shift, which left every cue already
  placed referring to an axis that no longer existed. Unfixed this reads as
  subtitles drifting further out the longer a channel runs, and it never
  appears in a short session, which is exactly the shape that survives a
  test.

### Added

- `[LiveSubs]` states its anchor once and its running relation about every
  30 s: the lead of the newest cue over the picture, the cue count and the
  current shift. A viewer reporting late subtitles cannot tell a misplaced
  anchor from a stalled fetch, and those two numbers separate them.

## [6.21.0] - 2026-08-11

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.21.0))

### Added

- Live HLS subtitle renditions reach the host (#359). The live ingest modelled
  variants, the audio group and its renditions, and dropped
  `EXT-X-MEDIA:TYPE=SUBTITLES` on the floor, so a channel offering WebVTT
  subtitles had no subtitle track at all: `subtitleTracks` stayed empty, and a
  host's Teletext preference had no decoder to apply to, because a decoder is
  only built once a track is selected. The group's renditions now surface as
  `TrackInfo` entries under `liveSubtitleRenditionTrackIDBase` (300_000), and
  selecting one starts a poll of that rendition's playlist. Nothing is fetched
  before that: a channel watched without subtitles pays no second HTTP loop.
- `aetherctl play --live-ingest` loads a URL through `HLSLiveIngestReader` as a
  custom source, the shape a host uses for a live channel it ingests itself.
  The live ingest had no CLI harness against a real channel, which is why the
  gap above went unnoticed.

### Fixed

- Cues of a live subtitle rendition are placed by playlist geometry rather than
  by `X-TIMESTAMP-MAP` (#359). Measured against a public broadcaster the spec's
  own anchor does not carry: the rendition writes one constant map whose MPEGTS
  value sits two hours off the video rendition's PTS. What renditions of a
  program do share is identical `EXT-X-MEDIA-SEQUENCE` and identical
  `EXT-X-PROGRAM-DATE-TIME`, so a cue is placed by its segment's wall time plus
  its offset inside that segment, against the wall time the video ingest joined
  at. A segment carrying no map is refused rather than placed at face value.
- `RemoteHLSMediaSelection.ordinal` no longer claims track ids above its own
  space. The membership test was `id >= base` with no upper bound, so every id
  range added above it was routed into the AVMediaSelection path, where the
  symptom is not an error but a selection that silently does nothing.
- Media playlists carry `EXT-X-PROGRAM-DATE-TIME` through the parser, including
  the segments that inherit it from an earlier tag, and a segment rebuilt to
  mark a discontinuity keeps it.

## [6.20.2] - 2026-08-11

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.20.2))

### Fixed

- A background teardown hands its selection to the reload that follows it
  (#357). Every reload path snapshots the state it restores (the #170 subtitle
  carryover, the audio pick, the disc title) immediately before its own
  `stopInternal`, which holds only while teardown and reload are the same call.
  The paused-background teardown is not: it runs `stopInternal` when the app
  sleeps, and `reloadAtCurrentPosition` runs on foreground return, so the
  reload snapshotted a session that had already been wiped and restored
  nothing. For subtitles that leaves the rebuilt session with no drain target,
  so nothing is decoded, published, or logged, and the delivery, resolution and
  per-cue instruments all fall silent at once on a session whose subtitle
  stream is present in the reopened demuxer. Only an explicitly picked track
  died, because `hostExplicitSubtitleAction` is the one piece of state the
  teardown leaves standing and it suppresses the preferred-language
  auto-selection that brought an auto-picked track back. Both teardown paths
  now park a selection before `stopInternal` and the reload claims it once,
  custom-source branch included (its disc title and audio pick went the same
  way). The live read stays authoritative for what survives a teardown (the
  external track registry, its ordinal counter, the host's subtitle authority)
  and for a selection made after it, which is newer intent; the snapshot fills
  only the wiped fields, and any other `load()` or `stop()` drops it. Hosts
  need no change: a host that already calls `reloadAtCurrentPosition()` on
  foreground return is covered. Device-verified on iOS, where a host-side cue
  cache can mask the failure for as long as the 60 s drain lead, so a seek
  beyond that window is what makes it visible.

## [6.20.1] - 2026-08-11

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.20.1))

### Fixed

- The VOD cut gate reads the axis the plan is written in (#358). A
  keyframe-aligned plan's boundaries are the container index's sync-sample
  timestamps, and for mov/mp4 those are DECODE timestamps: the mov demuxer
  builds its index from `current_dts`. The gate compared a packet's
  PRESENTATION timestamp against them, so every keyframe reached boundaries
  beyond its own by the sample's composition offset and the cutter consumed
  them, leaving plan indices that never opened a segment while the playlist
  kept offering them. On an ordinary encode that offset is two frames and the
  mismatch is invisible, which is how it survived since #92; on a remux
  carrying an edit list it is seconds (the reported file: `dts=0 pts=300000`
  at 1/100000, exactly 3 s). Reproduced without that file by giving a normal
  encode the same shape with `setts=pts=PTS+N:dts=DTS`: at a 5 s offset with
  IRAPs every 4.2 s segment 0 was never opened at all and the session never
  started, and at 3 s with wider boundaries every segment carried a constant
  2.48 s of plan-versus-content disagreement that nothing reported. Both now
  read `drift=0.000` throughout. Keyframe gating is unchanged, so #92 holds:
  the IRAP is still the segment's first sample and its RASL pictures still
  follow it in decode order (`segverify` 6/6 on a B-frame encode, 5/5 on the
  offset fixture). Sources with no DTS fall back to the presentation timestamp.

## [6.20.0] - 2026-08-10

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.20.0))

### Changed

- The uniform fallback segment plan is never finer than the source's real IRAP
  spacing, which it now measures from the bitstream (#358). A grid finer than
  the GOP advertises boundaries no keyframe sits on, and the keyframe-gated
  cutter (#92, shipped in 4.8.0) opens a segment only at the IRAP that reaches a
  boundary: every boundary that IRAP stepped over is a plan index that gets no
  segment while `EXTINF` still comes from the plan, so the playlist keeps
  offering it. Reproduced on a 120 s / 10 s-GOP MPEG-TS, which the 4 s grid left
  with holes at two indices in three and a permanent stall on the first one the
  player reached. The index cannot answer the spacing question: it is
  untrustworthy by the time this path runs, and the same source indexed 1.400,
  59.960, 60.000, 60.280, 121.360, whose smallest gap (0.04 s) and largest
  (58.6 s) miss the real 10 s in opposite directions. The scan is bounded to 30 s
  of content, runs only on this fallback path, and live never reaches it. The
  comment above `buildSegmentedSourcePlan` has named this failure since #268,
  which fixed it only for sources that declare their own boundaries.

### Fixed

- A plan index the cutter folded away is repaired or fails, instead of being
  waited out forever (#358). The consumer's request for such an index rode out
  the slow threshold, took the early chunked header, got no body and was closed
  for a retry that met the same nothing: measured on a 40 s-GOP source against a
  30 s grid, the clock froze at 90.00 s while the session reported `playing` for
  the rest of the run. No recovery ran, because the pump had finished the file,
  so nothing was parked and the backpressure wedge detector never fired; the
  provider sees every request before the wait, so the decision sits there now.
  The cut records the indices it jumped in the segment cache rather than on the
  producer, since a restart rebuilds the producer and the repeat across restarts
  is the signal. A first fold re-anchors the producer at that index, whose
  boundary can open once the base moves (the same source then plays to the end);
  a second fold is that repair reproducing its own trigger and raises
  `onVODSourceFailed`. Live is excluded: its playlist is built from what was
  finalized, so it never offers an index the pump skipped.

## [6.19.4] - 2026-08-10

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.19.4))

### Fixed

- The demo `.dmg` job completes. 6.19.3 embedded the frameworks correctly and
  then failed signing them with `Permission denied`: the xcframework payloads
  are mode 555 and `cp -R` preserves that, so `codesign` could not replace
  their existing signature. The copies are made writable. The same run showed
  that the guard added in 6.19.3 checked presence rather than resolvability, so
  a bundle holding every framework could still abort in dyld with no rpath
  pointing at them; it now fails when that rpath is absent.

No library changes. Consumers pinning 6.19.2 or 6.19.3 get byte-identical
engine code.

## [6.19.3] - 2026-08-10

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.19.3))

### Fixed

- The macOS demo `.dmg` ships the FFmpeg frameworks it links against. They were
  statically linked once, and the packaging script recorded that as a comment
  ending "if FFmpegBuild ever switches to dynamic frameworks, this is where
  they'd be copied to". It since did, so the binary loads nine frameworks
  through `@rpath` and the bundle contained none of them: the demo aborted at
  launch with `Library not loaded: @rpath/Libavcodec.framework/...` on every
  machine, which cost a reporter a round of testing on AetherPlayer#2. The
  frameworks are now embedded and signed inside out, and the stale comment is
  replaced by a check that fails the build when an `@rpath` dependency is
  missing from the bundle.

No library changes. Consumers pinning `6.19.2` get byte-identical engine code.

## [6.19.2] - 2026-08-10

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.19.2))

### Changed

- A damaged PGS display set closes its predecessor instead of being dropped. PGS
  carries no end time, a cue is closed by the start of its successor, so a set
  whose referenced palette is missing used to take that successor with it and the
  previous subtitle stayed on screen past its authored end (#142). The bundled
  FFmpeg now returns the empty subtitle at that branch, which
  `EmbeddedSubtitleDecoder` already treats as a clear event. This replaces the
  cache retention across composition state 3 that FFmpegBuild had carried since
  2.1.1: those caches are bounded by a count, not by an id namespace, so retained
  pre-connection objects occupied the 64 object slots a self-contained connection
  display set needs, and a conformant set conveying a new object id was rejected
  outright. A damaged Epoch Continue set therefore no longer re-renders the
  previous bitmap from retained state; it ends the predecessor at the authored
  time and shows nothing until the next intact set. Upstream as FFmpeg PR 23851.

### Dependencies

- FFmpegBuild 2.4.2 (pgssubdec missing-palette recovery, replacing the Epoch
  Continue cache retention; only `Libavcodec` changed).

## [6.19.1] - 2026-08-10

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.19.1))

### Added

- `#357 subtitle-delivery`, a diagnostic line stating what each subtitle drain
  tick did with the packets it found: `outcome=` is one of `noDecoder`, `empty`,
  `undecodable`, `held`, `duplicate`, `trimOnly` or `published`, printed with the
  counts it was derived from. Emitted on a change of outcome and on every
  post-seek reset tick, never per tick. It complements `#250
  subtitle-resolution`, which states how far determination reached: the drain
  cursor advances over packets that decode to nothing, so resolution can keep
  pace with every seek landing while the overlay never changes, and the two lines
  together tell those cases apart. A channel holding a drain target whose decoder
  cannot be built now reports `noDecoder` instead of being skipped in silence.

### Changed

- The per-cue `[applySubtitleEvent]` line is budgeted per seek generation instead
  of per `load()`, so a seek sequence stays observable to its end rather than
  going quiet after twenty events, and it prints `sourceTime` beside
  `currentTime`. Cue timestamps are absolute source PTS, so on a session with a
  playlist shift those two are not on the same clock.

## [6.19.0] - 2026-08-10

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.19.0))

### Fixed

- A live session with bridged E-AC-3 audio no longer dies with `muxerFailed`
  when a mid-session muxer rotation (a same-PID parameter-set change after a
  reconnect join, or an SSAI program switch) cuts its first segment before any
  post-seam audio packet has been muxed. E-AC-3 builds its mp4 sample entry from
  a parsed packet, so the fresh muxer started un-primed, the cut deferred, and
  the pump exited; the AE#222 exit scan could not rescue it because a raw source
  frame cannot prime a bridge-encoded track. The producer now retains the last
  audio frame a muxer accepted and primes every later allocation with it.
  Contributed by @tschuegy (#340).
- A live pump death with `muxerFailed` no longer zombifies the session. It had
  no recovery arm at all: the provider kept serving a frozen playlist, AVPlayer
  parked on it waiting for buffer that never came, and nothing surfaced to the
  host. The live arm now rebuilds the producer in place on the same connection
  at the live continuation point (a reopen would double-connect against a
  healthy socket), bounded by progress rather than per session, and halts
  production plus asks the host to retune once the budget is spent. The AE#222
  prime rebuild takes the same in-place path for live, where it used to run
  through the VOD-only restart and rebuild nothing. Contributed by @tschuegy
  (#341).
- The stall re-engage watchdog no longer disarms itself for good when the player
  fetches anything inside its grace window. It was one-shot and edge-triggered,
  so a player that drained its remaining tail segments and then parked on a
  frozen playlist was unreachable: `playbackStalled` does not re-fire while the
  forward buffer is non-empty, a waiting player never posts
  `failedToPlayToEndTime`, and the producer-side wedge detector died with the
  pump. The watchdog now re-baselines and keeps watching for up to a minute, the
  stage-2 reload carries a budget that spans stall events (a reload storm at one
  frozen position no longer loops forever), and a live session whose clock has
  not advanced after the reload publishes `liveSourceReset` so the host can
  retune. Contributed by @tschuegy (#342).
- A live URL source that spends its reopen budget no longer zombifies. Both
  exhaustion sites (the barren-cycle cap and the reopen attempt cap) escalated
  only for the custom-factory transport #199 introduced, so the far more common
  URL session reached the same dead end with its provider left un-halted: it
  kept advertising blocking reloads it could never answer (-15410 on any held
  `?_HLS_msn=`, and on an item reload against it), the playlist stayed frozen,
  and the host was never asked to retune. Every in-engine transport now halts
  production and publishes `liveSourceReset` on exhaustion; a source with no
  in-engine transport still delegates at the pump exit and is deliberately not
  signalled twice. Contributed by @tschuegy (#343).
- The software path now folds PTS discontinuities on forward-only sources, not
  just live ones. A chunked IPTV timeshift archive restarts its timestamps at
  PTS ~0 on every chunk, and FFmpeg's 33-bit wrap correction reads that backward
  jump as a ~26.5 h forward one: the renderer waited 25 hours for the frame's
  display time and the video queue died with `FigVideoQueueRemote -12080`,
  picture and sound frozen about 90 s into every session. A non-seekable source
  offers no seek-based recovery either, so it now folds like live. Seekable VOD
  keeps its trusted container timeline untouched. Contributed by @tschuegy
  (#347).
- Software-path audio no longer chops on sources that decode near real time. The
  combined demux loop paced everything on the video renderer's ~10-frame queue,
  so interleaved audio could never build more than ~0.3 s of lead over the
  synchronizer clock: any decode or deinterlace jitter beyond that starved the
  audio renderer, the clock leapt to the next sample's PTS, and the queued video
  was suddenly late enough for the layer to drop it (a 1080i50 archive replay
  measured periodic +0.25 s clock leaps and 17 % renderer drops). Video packets
  now park in a bounded FIFO drained at the renderer's pace while audio keeps
  decoding ahead of the clock, and a genuine underrun pauses the clock for a
  rebuffer instead of letting it free-run, the same policy the DVR feeder arm
  uses. Live keeps its lockstep pacing. Contributed by @tschuegy (#347).
- Hardening on the above: the read is paced by the audio lead itself rather than
  by how many seconds of video happen to fit in the FIFO's packet cap (which
  moved the effective lead with frame rate), one method owns every wait on the
  renderer so none of them can wait under a rebuffer hold that only this thread
  could lift, the #337 unarmed-clock exit reaches the parked path, parked packets
  are seek-generation checked before decode, and the lead latch resets with the
  seek instead of pausing the clock on the first post-seek check (follow-up to
  #347).

### Added

- A 1 Hz `[SWDiag]` line for software sessions: clock and clock delta, decoded
  audio lead, parked FIFO depth, rebuffer state, the display layer's own drop
  counter and accumulated render delay with per-second deltas, queue-target
  status, surface state and `isReadyForDisplay`. The native path has `[LagDiag]`;
  software sessions had only the 30 s memprobe, which is too coarse to see the
  clock leaps and layer-drop bursts a stuttering session is made of.
  Contributed by @tschuegy (#347).

- `LoadOptions.sequentialOrigin` and its paired `LoadOptions.declaredDurationSeconds`
  for origins that fabricate range answers. IPTV timeshift/catch-up archives
  answer any `Range: bytes=X-` with a plausible `206` whose body actually sits on
  a coarse internal chunk boundary, so only byte 0 is addressable: the 32 MB
  range rotations spliced misplaced content into every reconnect (heard as a
  once-a-minute audio desync), the tail-read duration estimate read a 135-minute
  window as 9.5 hours, and the static plan's uniform `EXTINF` was wrong for any
  archive whose GOP cadence does not divide the cut target. Headers cannot expose
  the lie, so the caller declares it: the reader runs one long-lived unranged GET
  with no ranged probes and reports a lost connection as `EIO` rather than `EOF`,
  the declared duration takes precedence over the container's, such a source keeps
  the native path instead of being forced to software, and the session serves an
  append-only EVENT playlist carrying the durations actually muxed, completed with
  `ENDLIST` at true source EOF. Seeking is unavailable by construction; re-request
  the archive with a shifted start timestamp instead. `aetherctl play` gains
  `--sequential-origin` / `--declared-duration`. Contributed by @tschuegy (#346).

### Changed

- A sequential origin now refuses every producer reposition, not just the
  `readError` revive. `performRestart`'s demuxer seek cannot land anywhere on a
  non-seekable pb and does not treat that as failure, so a scrub-driven or
  deadline-driven restart would have kept reading wherever the stream stood and
  labelled those bytes as the target segment: the same fabricated-position
  content the declaration exists to keep out, only silent. The restart and the
  resume anchor for the first producer now take the same refusal the revive
  already took (follow-up to #346).

## [6.18.1] - 2026-08-09

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.18.1))

### Fixed

- visionOS builds again. Three availability lists named tvOS, iOS and macOS and
  then fell through to `*`, which on visionOS resolves to the package's declared
  floor of 1.0, so `AVSampleBufferDisplayLayer.isReadyForDisplay`, its
  `ReadyForDisplayDidChange` notification and
  `AVSampleBufferVideoRenderer.videoPerformanceMetrics` (all visionOS 1.1) were
  compile errors on that platform and on no other. visionOS 1.1 is now named in
  each list, so visionOS 1.0 takes the same documented fallbacks as tvOS/iOS
  below 17.4; the declared floor stays `.visionOS(.v1)`, so no consumer's
  platform minimum moves. Reported by @YangHanqing (#344).
- CI now builds the visionOS Simulator alongside tvOS and iOS. The platform has
  been declared since 6.0.0 with nothing compiling for it, which is why the
  break above shipped unnoticed.

## [6.18.0] - 2026-08-09

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.18.0))

### Changed

- Codec routing defaults to the software path. The dispatch switch used to name
  its software codecs (AV1 without hardware, VP9, VP8, MPEG-4 Part 2, MPEG-2,
  VC-1) and send everything else native, but the native path is an allowlist of
  its own: `HLSVideoEngine` takes HEVC, H.264 and hardware-decodable AV1 and
  throws `unsupportedCodec` on the rest. The two lists were not complementary,
  they left a hole, so a codec nobody had enumerated was not routed
  conservatively, it was routed to the one path that refuses it by contract and
  never reached libavcodec. Surfaced by FFmpegBuild#1 (QuickTime RLE): with the
  decoder built in, a qtrle `.mov` still failed the load. The same held for
  ProRes, MJPEG, Theora, Cinepak and rawvideo. `AV_CODEC_ID_NONE` stays native
  explicitly, since an audio-only source probes as NONE.

### Dependencies

- FFmpegBuild 2.4.1 (adds the `qtrle` decoder; 40 decoders, demuxer / filter /
  parser lists unchanged).

## [6.17.1] - 2026-08-09

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.17.1))

### Fixed

- Software path: a cold-start session no longer deadlocks when the selected
  audio stream's first packet sits past the point where the video renderer
  fills (#337). The video branch back-pressures on
  `renderer.isReadyForMoreMediaData`, the renderer only drains while the
  synchronizer clock runs, and the clock arms off the first decoded buffer of
  the selected audio stream, so a park entered there with an unarmed clock was
  terminal: every packet that could arm it sat behind the park. Reported after
  a host applied a language preference ~20 ms after `play()`, which rebuilds
  the session at `resumeAt = 0`; the session published `.playing` with a first
  frame on screen and `currentTime` pinned at 0 until the viewer seeked. The
  gate now anchors on the video the renderer is holding
  (`SWClockAnchorPolicy.shouldArmFromParkedVideo`, keeping the load anchor
  unless the source joined mid-stream) and logs one line naming the stream that
  never arrived. The live feeder's gate is closed the same way, where the
  terminal condition is its look-ahead pump having spent its pre-arm budget (an
  audio track that never decodes a buffer).

## [6.17.0] - 2026-08-09

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.17.0))

### Added

- `AetherEngine.softwareDisplaySize`: the size the software path's picture
  presents at, the coded frame under the pixel aspect ratio the decoder attached
  (#353). A host laying an overlay out over the picture had only
  `sourceVideoWidth` / `sourceVideoHeight`, which are the CODED size, so
  anamorphic content was laid out against the wrong rectangle (720x576 at 64:45
  presents as 1024x576), and `AVSampleBufferDisplayLayer` carries no `videoRect`
  to measure instead. Nor could a host compute it: the ratio is resolved per
  frame across three sources (#177) and one whose display aspect is impossible
  is dropped in favour of square pixels (#290). Read off the format description
  the renderer enqueues rather than recomputed from the SAR, so it cannot
  disagree with the screen. nil off the software path and before the first
  frame; it follows a mid-stream format change and is cleared with the session.

### Fixed

- Anamorphic HEVC on the software host rendered at its coded dimensions (#354).
  The VT-backed decoder attached no pixel aspect ratio, and the renderer builds
  its format description from the delivered pixel buffer, so nothing carried the
  ratio to the layer: 720x576 declaring 64:45 presented as 720x576, a 16:9
  picture squashed into 5:4. The libavcodec decoder on the same host has
  attached it since #177, so the gap was one decoder wide. Resolved once at open
  from the bitstream ratio and the container's, through the same #177 and #290
  gates, and attached next to the colour metadata that is re-applied there for
  the same reason. Reached in production by the interlaced-content detour and by
  forward-only sources, which is where broadcast SD lands.
- The software load path cancelled every Combine sink it had already wired.
  `softwareCancellables.removeAll()` stood between two groups of `.store(in:)`
  calls, so the SW-PiP cue mirror never delivered a cue after the frame
  compositor was armed, and subtitles in a software-path PiP window froze at
  whatever was on screen when PiP started.

## [6.16.2] - 2026-08-09

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.16.2))

### Fixed

- `hasFirstFrameReadyForDisplay` latches on the item's readiness while an
  external screen holds the picture. Device-measured (iPhone to Apple TV): with
  external playback active the local `AVPlayerLayer` never reaches
  `isReadyForDisplay`, on any load of the session, so a flag folded from that
  layer alone stayed false for the whole AirPlay session and a host lifting a
  cover on it covered the session instead of the load. Audio-only sessions still
  never arm it, and the seam rules are unchanged: this only ever adds a rise.
  Wired HDMI takes the same latch, it flips `isExternalPlaybackActive` too and
  keeps no local picture either.

### Documentation

- Corrected which seams `hasFirstFrameReadyForDisplay` survives. The AE#158
  in-place handover was listed among them and is not one: it is a full `load()`,
  which un-latches. The discriminator is the entry point, not the `inPlaceSwap`
  flag a swap is made with. The media fallback, the AirPlay master swap and the
  #93 recovery reload call `host.load(inPlaceSwap:)` themselves and are
  unchanged.

## [6.16.1] - 2026-08-09

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.16.1))

### Fixed

- A wireless AirPlay route change reloads the `nativeRemoteHLS` bypass when it is
  serving its own loopback origin. The bypass was exempt from that reload on the
  premise that remote HLS is always receiver-reachable, which stopped holding in
  6.14.0: with text sidecars declared at load, the bypass plays a master the
  engine serves from the loopback, and a receiver cannot reach `127.0.0.1`.
  Engaging AirPlay mid-playback therefore handed the receiver an address it
  could not fetch, losing the whole session rather than just its subtitles, with
  no watchdog underneath it because that path builds no `HLSVideoEngine` session.
  Engaging AirPlay before playback started was never affected, and neither were
  wired displays, PiP, or tvOS.

## [6.16.0] - 2026-08-09

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.16.0))

### Changed

- The play gate waits for a panel mode switch it observed starting, instead of
  breaking out of it after 2 s. Device-measured: a rate switch takes ~3.55 s and
  the panel is dark throughout, so releasing early bought no picture and played
  1.4 s of content into a black screen. The pre-flight gate, live, and panels
  that report no switch start keep the previous cap.

### Fixed

- Mode-switch notifications are observed from the manager that posts them. tvOS
  posts `AVDisplayManagerModeSwitchStart` / `...End` from an
  `AVSharedDisplayManager`, not from the `AVDisplayManager` that
  `preferredDisplayCriteria` is written to, so the settle gate had never seen a
  single one and fell back on the in-progress flag and the EDR headroom.
- The EDR headroom no longer ends a switch that was observed to start. It peaks
  during the transition, and had been releasing playback up to 2.5 s before the
  panel finished.
- The mode-switch observation is armed at the criteria write rather than at the
  play gate, so a switch that starts and finishes during the load is knowable
  rather than invisible, and both gates of one load read the same record.
- Settle lines report the panel's measured switch duration when both
  notifications were seen.

## [6.15.3] - 2026-08-08

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.15.3))

### Fixed

- **The display-criteria gate no longer reports a switch that started inside it as one that
  started before it.** Stage 1 read `isDisplayModeSwitchInProgress` on every poll while drawing
  the conclusion that only holds on the first one, so a switch whose flag rose 376 ms after entry
  was logged `start pre-gate`, the exact opposite of what it showed. A late flag with no start
  notification now reads as its own signal, which points at where the engine starts listening
  rather than at the panel (Sodalite#49, follow-up in #339).
- **Stage 1 and Stage 2 spend deadlines rather than poll counts.** `n` sleeps of `m` ms is only
  `n * m` on an idle scheduler: the same 40 x 50 ms Stage 2 was measured at 2082 ms in one run and
  2862 ms in another on a thermally throttled Apple TV. Note that this makes Stage 1's `.full`
  budget exactly 1000 ms where load could previously stretch it further.

## [6.15.2] - 2026-08-08

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.15.2))

### Fixed

- **A live source is no longer stuttered on a steady cycle by the reader's own backpressure.**
  The 16 MB high-water end (#310) had no live branch, and live connections are open-ended by
  design, so ending at high water was the only thing that ever terminated a healthy live
  connection. Each end drained ~8 MB to low water and re-requested "at the frontier" — a byte
  offset that means nothing to a live origin — so everything broadcast during the drain was lost
  and the demuxer rejoined on a corrupt TS packet. And it never happened once: IPTV panels serve
  their ring buffer as a join burst at line rate on every (re)connect, so the burst refilled the
  window immediately and each reconnect caused the next one, forever (a field trace against an
  Xtream panel cycled every ~9.5 MB with a `Packet corrupt` and an h264 decode error per cycle;
  the loopback repro accepts 17 MB of a 24 MB burst, parks at 16.9 MB and holds no connection).
  Live readers now run a 64 MB high water (matching `streamHighWater`, the bound the engine
  already accepts for the other reader that cannot bound by range request): the join burst is
  absorbed once, steady state plateaus at burst size with the connection never voluntarily
  ended, and the end-and-refill survives unchanged as the memory backstop for a "live" source
  that sustainedly outruns realtime.
- **A live reconnect that the origin cannot satisfy asks for the stream the way a join does.**
  The reconnect request carried `Range: bytes=<frontier>-`, but the frontier is reader
  bookkeeping (the window position delivered bytes are appended at), and whether it means
  anything server-side depends on the origin. Panels that ignore the offset and serve "from now"
  masked this; a panel that answers 416 to every offset it cannot satisfy turned each reconnect
  into an unrecoverable rejection loop (field trace: a panel that cleanly completes every
  response after its ~14 MB ring burst then 416'd the same frontier 35 generations in a row,
  ~1/s, while the runway drained from 8 MB to zero and the session starved). The rejection is
  now the signal: the first 416 on a nonzero live offset latches the join shape (`bytes=0-`,
  what every origin serves) for the rest of the session, so the loop costs one request and never
  repeats. A live source that IS byte-addressable (a growing stream file, a misdeclared VOD)
  keeps resuming at the frontier, which is what it answers correctly and where asking for byte
  zero would re-deliver its whole buffer on top of the window.
- **HTTP 509 from a pinned redirect target is treated as metering, not as a dead pin.**
  509 "Bandwidth Limit Exceeded" is what a connection-capped IPTV panel answers while the slot
  the reader is replacing has not been torn down server-side yet. It classified as a hard 5xx,
  so every attempt dropped the pinned post-redirect URL and re-resolved through the portal —
  latency per attempt, plus the second request against the very origin that has no room for it,
  which is the 519ae26e reasoning left incomplete (a permanent 509 ground through 13 attempts
  with 12 portal re-resolves at zero backoff, because ~8 MB of progress per cycle reset the
  unproductive streak every time). 509 now keeps the pin and pays the rate-limit streak and
  backoff alongside 429/503, honouring Retry-After when sent, with the same bounded give-up
  (#307 follow-up).

## [6.15.1] - 2026-08-08

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.15.1))

### Fixed

- **A `nativeRemoteHLS` session that never reached `readyToPlay` had no terminal state (#334).** An
  origin that answers every request while AVFoundation can build no track from what it serves leaves
  AVPlayer neither failing nor becoming ready, so `state` stayed `.loading` indefinitely: no error,
  no timeout, and a host with nothing to retune on. The carriage machinery could not help, because
  all of it is anchored at `readyToPlay`: the #293 probe settled `hevcInMPEGTS` and the verdict was
  then only ever read by a loop that had not started, and the deferred segment-head probe waited 20 s
  for a readiness that was not coming and gave up without reading. Three changes: a settled carriage
  verdict now reroutes on its own (it is read off the source and needs no grace), the deferred probe
  reads the segment head when the readiness ceiling expires instead of abandoning the case, and the
  bypass has a 45 s ceiling on silence that publishes a real error when nothing became ready, nothing
  rerouted and nothing failed. Readiness at any point, a reroute, or an AVPlayer failure all disarm
  it, so slow origins and transcode spin-ups never meet it.

## [6.15.0] - 2026-08-08

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.15.0))

### Added

- **`AetherEngine.videoRoute`: the pipeline actually serving the session (#321).** `LoadOptions
  .nativeRemoteHLS` is the request, not the outcome. The #168 carriage watchdog reroutes onto the
  ingest loopback mid-session, #199 takes it straight away for a remembered master, AE#268 does the
  same for a HEVC-in-MPEG-TS VOD, and AE#154 / AE#246 move the other way onto the bypass; none of it
  was observable, because `loadedOptions` is internal and `playbackBackend` is `.native` for both
  native pipelines. The new `@Published` value publishes `.remoteBypass` / `.loopback` / `.software`
  / `.audio` / `.none` and is derived from `playbackBackend` plus the session's effective options,
  so it cannot desync from them. Hosts can now decide who draws subtitles, and react to a reroute
  instead of inferring it. `aetherctl play` prints `route=` next to `backend=`.

## [6.14.0] - 2026-08-07

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.14.0))

### Fixed

- **`LoadOptions.externalSubtitles` was dropped on the `nativeRemoteHLS` bypass (#316).** The branch
  returns from `load()` before the probe path registers the declaration, so a host that declared
  sidecars on a remote HLS source got an empty `subtitleTracks` back, with no error and no log line
  to tell a dropped option from a source that has no subtitles. The AE#154 reroute onto the same
  bypass dropped them too, and the legible-group discovery would have overwritten them anyway: it
  assigned `subtitleTracks` wholesale instead of merging.

### Added

- **Sidecar subtitles become real renditions on the `nativeRemoteHLS` bypass (#316).** Media
  selection on an HLS asset comes from the playlist and nowhere else, so `addExternalSubtitleTrack`
  could only ever drive the host overlay, which is not drawn once the picture leaves the host's view
  hierarchy: PiP, AirPlay and a wired external display lost the subtitle, and for a Plex or Jellyfin
  transcode told `subtitles=none` the sidecar is the only copy there is. For a VOD source the engine
  now fetches the origin master, absolutises every variant, audio and key URI against it, adds one
  `EXT-X-MEDIA:TYPE=SUBTITLES` per text sidecar (joining the origin's own group when it has one) and
  serves that master from the loopback origin. The media never moves: AVPlayer still fetches all A/V
  bytes from the origin, which is the property the bypass exists for (E-AC-3 / Atmos passthrough).
  The tracks keep the external ids they were registered under, and selecting one drives
  `AVMediaSelection` rather than the overlay, so the two cannot draw at once. Live playlists, bitmap
  sidecars, an unrewritable playlist and a slow origin all keep the origin URL and overlay-only
  subtitles; the load is never failed over this.
- **`aetherctl play --sidecar <lang>=<path>`** declares sidecars at load, so the whole chain is
  observable from the CLI (served master body, injected count, the `subs_N.m3u8` / `.vtt` fetches).
  The end-of-run summary now also prints the settled subtitle track list and the active selection.

## [6.13.0] - 2026-08-07

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.13.0))

### Added

- **`hasFirstFrameReadyForDisplay`: the running path has a picture, which readiness never said.**
  `isSessionReady` is `AVPlayerItem.readyToPlay`, which AVFoundation reaches before the layer holds
  a frame and which stays true across a seek, so a host approximating presentation from it lifts
  its black cover onto black, and a load opened paused lifts it before there is anything to see.
  The signal that can answer the question was internal: `nativeHost` is not public, and the
  software path had no equivalent at all. The new `@Published` property folds
  `AVPlayerLayer.isReadyForDisplay` on the native path and
  `AVSampleBufferDisplayLayer.isReadyForDisplay` on the software one (not KVO-observable there,
  AVFoundation posts a notification for it; below tvOS/iOS 17.4 and macOS 14.4 the property does
  not exist and the fallback is the first frame handed to the renderer, one hop earlier).
  It is latched for the load rather than mirrored as a level: an item swap costs the layer its
  picture for ~40 ms even when the swap is the in-place handover that exists to be invisible, so
  the seams that reuse a running host hold the latch, while a rebuild through `load()` resets it
  with the item. And it states that the pipeline has a frame ready, not that a viewer sees one:
  both layers reach `isReadyForDisplay` while in no view hierarchy at all, which is the case
  #298 is about. For "has this seek reached the screen", `SeekEvent.landed` remains the answer,
  since a seek keeps the previous frame up and the layer never stops being ready for display
  (#315, reported by [@edde746](https://github.com/edde746)).
  `aetherctl play` prints the edge (`FIRSTFRAME ... t+`) and carries `rfd=y/n` per telemetry tick.

## [6.12.1] - 2026-08-07

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.12.1))

### Fixed

- **The software path no longer reports 0.0 Mbps of throughput on a healthy session.**
  `networkThroughputMbps` was a wall-clock mean over a 10 s window, but the reader fetches a large
  range and then parks on backpressure until low water, so on a fast link most ticks of that window
  carry no bytes at all: measured over a local origin, a healthy 2.8 Mbps VP9 session pulled 16.4 MB
  in one tick and then exactly nothing for the next 23, while its runway drained from 16.0 to 8.3 MB.
  The field read a confident 0.00 Mbps through all of it, which is the same false-with-confidence
  zero #306 was filed about, one field over. It is measured over the seconds bytes actually arrived
  in now, which is the quantity the native path already reports from `observedBitrate`, and it is nil
  rather than zero when nothing arrived in the window at all. A host that wants a held reading can
  keep the last non-nil value; a host given a zero could not tell a parked reader from a dead link.
  A throttled origin is unaffected: every tick carries bytes there, and a starving 2 Mbps session
  reads a steady 2.10 Mbps before and after (#306 follow-up, found while verifying
  [@kskchaitanya1993](https://github.com/kskchaitanya1993)'s retest).
- **Frame-time epochs keep rising across a `load()`, so a host can tell one item's frames from the
  next's.** `NativeVideoFrameTime.epoch` and `SoftwareVideoFrameTime.generation` both document the
  rule that a higher value retires everything recorded under a lower one, but both were counted per
  session: a load builds a new `HLSVideoEngine` (and a new software renderer), the counter restarted
  at zero, and the rule inverted at exactly the seam it exists for. A report still arriving from the
  outgoing session outranked everything the incoming one would ever emit, so a host that ordered by
  it discarded the whole new item rather than the stale entries. Both values are now drawn from a
  process-wide sequence, so the superseded session always ranks below the next one, and a superseded
  session is also detached from the observer at teardown so in the ordinary case it falls silent
  instead of racing. Successive values are strictly increasing but no longer consecutive; ordering
  was always the contract (#314, reported by [@edde746](https://github.com/edde746)).
- **The software renderer's metrics read builds across SDK generations again.**
  `loadRenderMetrics()` read `displayLayer.sampleBufferRenderer` and then suspended on that
  renderer's async accessor, and no single `await` on it satisfies both ends of the toolchain range:
  an SDK that isolates `AVSampleBufferDisplayLayer` to the main actor refuses to hand the renderer
  to any other domain, while a toolchain that imports the async accessor as `nonisolated` refuses to
  take that non-Sendable renderer from the main actor. The read is main-actor isolated now and goes
  through the completion-handler accessor, which suspends without moving the renderer anywhere.
  Every caller was already main-actor isolated, so playback and telemetry are unchanged
  (#313, reported and first fixed by [@jihongboo](https://github.com/jihongboo)).

## [6.12.0] - 2026-08-07

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.12.0))

### Fixed

- **A source connection that dies silently is now noticed on wall-clock time instead of on
  consumer cadence.** `connStallTimeout` was evaluated in exactly one place, the read loop's
  forward wait, so a transport that died while the sliding window could still serve reads was
  detected only once a consumer happened to block on it: `bytesFetched` sat frozen for 4.5
  minutes across a pause in the field report, and the reconnect fired only after the window had
  drained. A generation with an installed transfer and no delivery for `connStallTimeout` is now
  ended by a delivery-gap watchdog, whether or not a read is waiting on it, and the gap is named
  in the log. The watchdog only ENDS: opening connections stays with the read thread, so a paused
  player still holds no flow and cannot be driven into a timer-paced reconnect loop (#309).
- **A faulted connection is replaced while read-ahead remains, not once it is spent.** The
  frontier refill fired only for planned ends (a range delivered in full, a high-water end), so a
  generation that ended in fault was replaced only after the window hit empty. The reader spent
  its entire read-ahead before asking for a replacement and playback rejoined the clock with a
  burst (+17 MB in one interval, 389 dropped frames in the field trace). Any reason for having no
  flow now refills at low water; a fault additionally pays the failure ladder (status accounting,
  pin invalidation, bounded give-up) with its backoff expressed as a next-attempt time rather than
  as a sleep, so the demuxer keeps being served from the window between attempts (#309).

## [6.11.0] - 2026-08-07

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.11.0))

### Fixed

- **An origin refusing every range refill no longer spins the reader in an unbounded
  reconnect spiral.** A connection that ended in error without delivering a byte of its
  generation was treated as a benign reposition: `seekReconnect` cleared the unproductive
  streak and applied no backoff, so a connection-capped origin answering 500 at a 32 MiB
  range boundary produced ~15 reconnects/s (925 in 60 s observed) until the segment
  provider tore the demuxer down from outside. Such connections now take the failure
  ladder: status accounting, Retry-After, exponential backoff, a `.reconnecting` network
  phase, and a bounded give-up. The previously silent non-200/206 response rejection is
  now logged with its status and offset.
- **A pinned post-redirect URL is dropped on hard 5xx answers and on repeated zero-byte
  failures.** Redirect targets that expire per connection (Xtream-style aggregators)
  answered every later range with 500 from the pinned URL; only auth-expiry statuses
  (401/403/404/410) invalidated the pin. The reader now falls back to the source URL for
  a fresh redirect (503 keeps the pin — that is rate limiting, #71).
- **A VOD session whose readError revive cap is exhausted surfaces `onVODSourceFailed`**
  instead of dying silently with AVPlayer parked in `waitingToPlay` forever (#169).

### Changed

- **The persistent reader ends its connection at the window high water instead of suspending
  the data task** (#310). A suspended task holds a dormant established flow whose closed
  receive window sits unread for as long as the consumer takes to drain, roughly 100 s per
  cycle at 1 Mbps and indefinitely while paused. On tvOS and iOS, where TCP for
  Network.framework flows runs in the app process, that dormant state correlates
  dose-response by media bitrate with 10 to 80 s episodes in which every nw flow in the
  process goes deaf at once: established WebSockets time out unACKed and no new handshake
  completes, while raw BSD sockets from the same process keep working. The reader now either
  has an actively delivering connection or none at all, and the low-water frontier refill
  re-requests exactly where delivery stopped, so nothing is discarded and nothing is
  re-fetched. A paused player holds no connection. The cost is one extra range request per
  drain cycle. The `winHardCap` escape hatch and the suspend machinery are gone with it, and
  the memprobe reports `Parked=` (backpressure-ended, refill pending) in place of `Susp=` and
  `PostMB=`. Reported and field-verified over 71 minutes on two Apple TV 4K by @rrgomes.

## [6.10.0] - 2026-08-07

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.10.0))

### Added

- **The software path hands out its presentation timebase and reports its frame times.**
  `softwarePresentationTimebase` exposes the render synchronizer's clock, the master clock for both
  the audio renderer and the display layer, created unconditionally so it exists even on a source
  with no audio track. `setSoftwareVideoFrameTimeObserver` reports every enqueued frame as a
  `SoftwareVideoFrameTime` (`presentation`, `generation`). Both read the source axis, the axis the
  engine's subtitle cues already live on, so a host pacing a bitmap overlay (libass) against them
  converts nothing. Reports arrive at the handover to the compositor, past the reorder buffer, which
  makes them ascending in presentation order and excludes frames refused for an unschedulable
  timestamp or skipped after a seek. `generation` moves on every renderer flush, so entries recorded
  before a seek are distinguishable from the ones after it even where the timestamps repeat (#311).
- **`aetherctl play --frame-times`** installs that observer before `load()` and appends `ft`,
  `ftLast`, `ftGen`, `ooo` and the timebase reading to the 1 Hz line.

## [6.9.0] - 2026-08-07

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.9.0))

### Added

- **A software session reports its own network telemetry.** `LiveTelemetry` gains
  `displayCushionSeconds` (decoded video queued past the clock, software path),
  `readerWindowAheadBytes` (bytes fetched but not yet consumed by the demuxer, both paths) and
  `accumulatedFrameDelaySeconds` (cumulative late-frame delay, software path). `droppedFrameCount`
  is now populated on the software path as well, from the render synchronizer's own metrics rather
  than an `AVPlayerItem` access log that path does not have. `forwardBufferSeconds` deliberately
  stays nil there: the demux loop reads on renderer back-pressure, so no seconds-deep reservoir of
  arrived-but-unplayed media exists to report, and publishing the sub-second cushion under that name
  would read as a near-stall on a healthy session (#306).
- **`aetherctl play` prints the network half of the snapshot** on its 1 Hz line (`net`, `rx`,
  `ahead`, `cushion`, `fwd`, `drop`, `delay`), omitting whatever the running path has no answer for.

### Fixed

- **Byte-derived telemetry read zero for an entire software session.** The engine's pump byte
  counter resolved through the native HLS session, which a software session does not own, so
  instant bitrate, average bitrate, `networkThroughputMbps`, `networkTransferredBytes` and
  `LiveTelemetry.demuxerBytesFetched` were a hard zero on the one path that carries VP9, AV1 without
  hardware decode and MPEG-4 Part 2. It now reads software first and native second, the precedence
  the memory probe has always used (#306).

## [6.8.0] - 2026-08-07

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.8.0))

### Added

- **The subtitle-resolution statement says when determination reaches the playhead, instead of
  leaving it to be noticed 30 s later.** The #250 line marked changes of the frontier's SOURCE, and
  a frontier climbing past the rendered position is not one of those: after a far seek the
  reconstruction line is `via=pump` by construction, the pump-to-prefetch line can still land short
  of the target, and the next admissible line was then the 30 s cadence tick. A harness reading only
  fenced coverage therefore saw a post-seek gap of ~29 s where the rendered state had in fact been
  correct after ~1.4 s. The drain tick now emits `reason=coverage` on the first tick where a
  prefetch- or EOF-bounded span reaches the playhead, once per decoded run. No claim changed: it
  prints the statement the tick already builds, so `via=pump` still cannot state coverage, and on a
  link that cannot feed both readers the line correctly stays absent (#318).

### Changed

- **The software path's rejected-SAR line names the axis the ratio came from.** A rejected sample
  aspect ratio never latches, so the latch line that names frame / ctx / stream could not fire for
  it and the rejection line was the only line a bad ratio produced. It now carries the same three
  axes. On MPEG-TS, where no container ratio exists, `stream=` is the parser's reading of the SPS
  VUI at open time and `frame=` is the SPS in force for that frame, so a disagreement between them
  is the fingerprint of a declaration that moved between the join and the frame (#290).

## [6.7.0] - 2026-08-04

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.7.0))

### Added

- **The software path reports its read-ahead, and what the display did with it.** A software
  session left a trace with no cushion figure in it: `frameAhead` is the native producer-shift
  fold and reads 0 here whatever the buffer holds, `bufferedSessionTime` is fed only on live
  sessions so a VOD software session published its own playhead back as its frontier, and the
  `isReadyForMoreMediaData=false` line is latched to one per session. The memprobe now carries
  `swAhead=` (seconds of decoded video queued ahead of the clock), plus `swDropped=` and
  `swDelay=` from the renderer's own accounting, which counts frames dropped for missing their
  display deadline rather than only the ones we refuse ourselves. On a native session the fields
  are absent rather than zero.

### Changed

- **`bufferedPosition` on a VOD software session reports the decoded cushion instead of the
  playhead.** The AetherEngine#54 contract is unchanged (it never trails the playhead) and the live
  frontier still wins where it is larger; what changes is that the VOD software case stops
  publishing a frontier that was only ever a placeholder.

### Fixed

- **Ordinary remote custom readers can skip ISO/UDF disc-image recognition.**
  `IOReader.discImageProbeEnabled` defaults to `true`, preserving automatic DVD
  and Blu-ray image support. Readers that already know they expose a regular
  media file can return `false`, avoiding the sparse remote seeks used only for
  ISO9660 and UDF signature checks. The policy travels with independent readers,
  so subtitle side demuxers, reloads, and frame extraction do not repeat those
  unnecessary network reads. Contributed by @murderer1234.

## [6.6.4] - 2026-08-04

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.6.4))

### Fixed

- **A bounded-range boundary no longer re-fetches bytes the origin already
  delivered.** The #220 frontier refill opens the next range while data is still
  resident ahead of the read position, so a range boundary is not a stall.
  Starting that connection reset the window start to the frontier and dropped
  the window with it, up to 8 MB of delivered but undrained bytes, and the next
  read then sat below the window start, took the backward branch, and pulled
  those same bytes back over the network in 4 MB detour blocks on the demux read
  thread. A continuation now keeps its window. Visible on any paced consumer
  (playback reads at media rate, so the transfer always wins the race), and
  worst on a high-bitrate source, where the boundary comes around often enough
  to be noticed. On the software path, whose read-ahead is whatever
  `AVSampleBufferVideoRenderer` accepts and is not measured today (#303), the
  blocked read reached the picture as a stutter.

## [6.6.3] - 2026-08-04

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.6.3))

### Added

- **A software session says when its frames are decoding into nothing.** The
  software path renders into an `AVSampleBufferDisplayLayer` the engine owns,
  and that layer reaches the screen only once the host binds a surface with
  `bind(view:)` or `AetherPlayerSurface`. A host that presents an
  `AVPlayerViewController` for a software-routed source instead gets audio, a
  completely healthy engine log and no picture, because this path has no
  `AVPlayerItem` for AVKit to show, and a layer bound to a view that never got a
  layout looks the same from the outside. Both are now named once per session,
  about two seconds after frames start flowing, with the count of frames that
  went nowhere. Nothing about the session changes; the report that prompted this
  read a full render queue (`isReadyForMoreMediaData == false`, which is the
  demux loop's back-pressure gate working) as a renderer that had stopped
  accepting frames, and no line said otherwise. Reported by @akacores (#298).

### Changed

- **A frame whose presentation timestamp is not numeric no longer reaches the
  display queue.** `AV_NOPTS_VALUE` arrives at the renderer as `CMTime.invalid`,
  and CoreMedia builds a sample buffer from it without complaint, so the render
  synchronizer was the first thing in the chain that could not schedule it; the
  deinterlace path has dropped its own untimestamped output for that reason since
  it was added. The gate sits before the B-frame reorder buffer, where such a
  frame additionally reordered its neighbours (every comparison against NaN is
  false), and it counts and names what it drops so a source that produces untimed
  frames says so instead of showing a still picture (#298).

## [6.6.2] - 2026-08-04

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.6.2))

### Fixed

- **A seek no longer discards a transport call that arrives while its
  reposition is still running.** The software and audio hosts park their demux
  and feeder loops for the duration of a seek by clearing `isPlaying`, and since
  6.1.1 the demuxer reposition that follows is awaited off the main actor, so a
  second seek could enter that window and read the flag its predecessor had
  cleared as "was paused". A scrub during playback that reached the engine as
  two same-target seeks therefore anchored the audio clock at rate 0 and left
  the session parked, while the engine went on reporting `.playing`; only a
  manual pause plus play recovered it. The intent is now stashed by the seek
  that owns the window, inherited by whoever supersedes it, rewritten by
  `pause()` and `play()`, and read at the landing rather than at entry, which
  also closes the two siblings of the same defect: a `pause()` issued during a
  reposition was swallowed and playback continued, and a `play()` issued during
  one landed at rate 0 under a running loop. The seek finalize no longer reports
  `.playing` over a software or audio host that landed paused either. Reported
  by @wunax (#292).

## [6.6.1] - 2026-08-04

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.6.1))

### Fixed

- **The live carriage probe no longer spends a media connection where the
  playlists already answer, nor spends one against the mount.** Origins that
  authenticate per token routinely cap concurrent connections at one or two, and
  what such a cap counts is media fetches rather than playlist fetches, so the
  6.6.0 probe's ranged segment head was a second media connection opened while
  AVPlayer was establishing its own on exactly the channels the probe exists to
  speed up. An fMP4 media segment requires an `EXT-X-MAP` (RFC 8216 4.3.2.5), so
  a master advertising hvc1 / hev1 / dvh1 / dvhe / av01 over a window that
  carries none is that codec in MPEG-TS, settled now from the `CODECS` attribute
  AVFoundation has already parsed plus one playlist fetch and no segment byte at
  all. AES-128 no longer blocks that branch, since nothing is being decrypted to
  reach the verdict. What the playlists cannot settle, a direct media playlist or
  a master without `CODECS`, still reads one segment head, because only the PMT
  separates HEVC in MPEG-TS from H.264 in MPEG-TS there, but it waits for
  readyToPlay: the verdict cannot be acted on before the watchdog arms in any
  case, and a connection lost at that point costs the verdict rather than the
  mount. A session whose watchdog disarms first, or which never becomes ready,
  now fetches nothing. The saving stays about 3.5 s of the 4 s grace. Raised by
  @kskchaitanya1993 out of the #293 device leg (#296).

## [6.6.0] - 2026-08-03

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.6.0))

### Added

- **`nativePlayerLayer` and `softwareHostFramesEnqueued`,** two read-only
  properties with no behaviour attached. `AVPictureInPictureController` wants an
  `AVPlayerLayer` rather than an `AVPlayer`, and the software path has published
  its layer since 5.13.0, so a host rendering through `bind(view:)` had no route
  to the native layer already on screen and had to mount a second one. It reads
  nil outside a native session, which is also the honest signal for hiding a PiP
  button. `softwareHostFramesEnqueued` was already the engine's own answer to
  "are frames reaching the display layer" and simply was not public in a Release
  build: a host watchdog can ask `AVPlayerItemVideoOutput.hasNewPixelBuffer` on
  the native path and had nothing to ask on the software one, so it read every
  dav1d / libavcodec session as picture-less. Monotonic within a session and
  restarting at zero when a `load()` builds a new host. Requested by
  @kskchaitanya1993, who had been carrying both as downstream patches (#288).

### Changed

- **A live HEVC-in-MPEG-TS channel reaches the ingest without paying for a
  doomed native mount first.** The carriage verdict used to come only from the
  #168 watchdog, which needs a full mount, readyToPlay and a 4 s grace before it
  can conclude that AVPlayer will never build a video track, so every first open
  of such a channel spent that grace as audio over black, in every process. The
  same question is now answered from the source itself, the playlist plus the
  head of one segment (the evidence chain #268 already uses for finite VOD), read
  concurrently with the mount so nothing is serialized in front of first frame. A
  master that advertises H.264 never reaches the network for it, and a live media
  playlist URL with no master to judge is covered for the first time: its carriage
  was previously unjudgeable, which left it audio-only indefinitely. A video track
  that does build still wins at any point, so no working session is taken off the
  native path (#293).

### Fixed

- **No play-gate wait for a display switch Match Content cannot start.** With
  Match Content off, `waitForSwitch()` still ran its poll on the path that gates
  `play()`, and nothing in that state can start a switch: `apply()` declines to
  write the criteria, and tvOS ignores a sole-writer host's AVKit write just the
  same. The budget was dead startup time on every load, 200 ms for an
  engine-writer host and 1000 ms for a sole-writer host on HDR / DV. The guard
  reads the toggle live off the display manager rather than the host's
  `LoadOptions` snapshot, which can be stale in the direction that matters, and
  the skip line names the budget it dropped. Sessions with Match Content on are
  untouched. Reported by @kskchaitanya1993 (#289).
- **A pixel aspect ratio is judged by the picture it produces, not by its own
  magnitude.** `saneSAR` bounded each component to 256, which catches the
  pathological values and admits small-but-wrong ones: a live 1080p H.264 channel
  declaring 3:1 cleared it and smeared 1920x1080 into a 5.33:1 band. No bound on
  the ratio itself can work, since 2:1 is a standard VUI value and exactly right
  on a 960x1080 broadcast frame while being the reported defect on 1920x1080. The
  display aspect the ratio resolves to on this frame is now bounded to 1:3 ... 3:1,
  a rejected candidate falls through frame to codec context to stream rather than
  ending resolution, and the FrameExtractor resolves through the same policy.
  Reported by @kskchaitanya1993 (#290).
- **A container-declared pixel aspect ratio reaches the decoder.** The software
  path's container-SAR fallback read `codecpar->sample_aspect_ratio` alone, which
  is the one place a container ratio never lands: Matroska writes its DisplayWidth
  quotient to `st->sample_aspect_ratio` and MP4 does the same with `pasp`. The
  fallback was dead in exactly the case it was written for, and MPEG-2 sources hid
  it because their ratio arrives per frame from the sequence header. A 960x1080
  VP9 MKV declaring 2:1 drew at coded dimensions and now draws 16:9. A container
  ratio still runs the gates above like any other.

## [6.5.6] - 2026-08-03

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.5.6))

### Fixed

- **A VOD whose audio track outlives its video no longer ends when the picture
  runs out.** AVPlayer fires `didPlayToEndTime` the moment its video renderer
  runs dry, and the engine forwarded that as an organic finish. On a dual-audio
  BDRip whose selected English AAC runs 53 s past the last video sample, the item
  stopped 53 s early, and because `.ended` is terminal the tail was unreachable
  for the rest of the session. Reproduced deterministically on a 60 s-video /
  113 s-audio MKV, and identically with an 8 s and a 2 s tail, so the trigger is
  the video exhaustion rather than the length of the tail. An end that lands more
  than a second inside the range AVPlayer itself still reports as seekable is now
  refused, and the item is re-seeked in place and resumed: the tail plays out to
  an organic end at the real duration with no audio dropped. Bounded to three
  recoveries per item, each requiring the playhead to have moved, so a source
  that genuinely cannot continue costs one re-seek and then completes as before.

## [6.5.5] - 2026-08-03

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.5.5))

### Fixed

- **The retained file head now survives to serve playback's first read.** It was
  released when the demuxer finished parsing, on the reasoning that a far seek
  from there on is a scrub. After a trailing-index parse the anchored connection
  sits at the END of the file, so playback's first read is a backward one, and it
  lands at the head: measured landings of 48 and 263303 under `aetherctl` and
  5752 in a field trace, where it cost a fresh connection whose first byte took
  865 ms. No `probe`-based measurement could see it, because `probe` exits at
  exactly that call. Against a 300 ms origin on a fragmented fixture, playback's
  first read becomes a copy out of the head and the next connection is deferred
  by 3.93 MB of already-resident bytes. The head is released instead by the first
  post-open read it cannot answer.
- **An origin that declines suffix ranges is asked once per session, not once per
  open.** Some origins answer `bytes=-65536` with a 200 and the whole file. That
  body was already refused at the response header, but the request itself was
  re-issued on every open: a second connection opened at the same instant as the
  data connection whose first byte is the cold start, sharing the same uplink,
  against a server that had already shown it cannot serve it. Its answer is now
  remembered per origin. Only the origin's own answer latches immediately; a
  transport failure takes two, since a link bad enough to lose this request loses
  others.

## [6.5.4] - 2026-08-03

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.5.4))

### Changed

- **The HLS segment pump runs at the efficiency QoS whenever nothing is waiting
  on it.** Its queue was pinned to `.userInitiated` for the whole session, which
  is right for the windows where AVPlayer is blocked on a segment that has not
  been cut yet and wrong for the steady state, where the producer is minutes of
  content ahead and parked on backpressure. It cannot simply be demoted either:
  `HLSLocalServer` answers segment requests from a `.userInitiated` work queue
  and a cache miss parks that thread in `cache.fetch` until the pump produces the
  segment, a dependency dispatch has no way to see. Pinned to `.utility` on a
  fully saturated M1, filling the forward window took 1.21 s against 0.16 s and
  time to first frame rose from 0.14 s to 0.24 s; on an idle box the two are
  indistinguishable, which is why a single measurement on a device with thermal
  headroom cannot settle it. The pump therefore owns its thread now and retunes
  its own class as it runs: responsive until the consumer has started rendering
  and while the consumer sits within 16 s of content of what this pump has
  produced, `.utility` beyond that. Over a 120 s steady-state window that leaves
  it in the efficiency class for 416 ms of CPU against 419 ms for a build pinned
  to `.utility`. Live is unchanged, its production is source-paced and the
  blocking reload holds an AVPlayer request open on the very next segment.
  Reported and measured on iOS by edde746 (#286).

## [6.5.3] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.5.3))

### Fixed

- **A session that starts on a panel already in HDR is no longer routed as SDR.**
  `UIScreen.currentEDRHeadroom` is not a readout of the panel's HDMI mode. It is
  raised around a dynamic-range transition and decays back to 1.0 while the panel
  keeps presenting HDR, measured on an HDR10+ panel as a fall from 1.20 to 1.00
  thirteen seconds into a confirmed HDR10 session with no mode switch in progress.
  A replay that begins before the TV has dropped back to SDR therefore makes no
  transition at all, so the single read taken after `waitForSwitch` concluded that
  the panel was SDR. On tvOS that one boolean is the whole master-vs-media routing
  gate, so every such session was served media-direct with no HDR signaling and
  labelled SDR while the TV itself reported HDR. The reading now counts only as a
  positive; its absence is answered by whether a criteria write has ever
  demonstrably driven this display into HDR.

- **The settle diagnostics stop accusing a panel that was already in HDR.** Both
  the Stage 2 WARN and the cap line read headroom 1.0 after an HDR write as a
  refusal, which is indistinguishable from a panel that needed no transition.
  They now separate the two, and an unproven panel still names the real
  candidates.

## [6.5.2] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.5.2))

### Fixed

- **A range that finished delivering is now read out of the window instead of
  fetched again.** A completed range clears `activeTask` exactly as a dropped
  one does, and the no-connection branch reconnected at the READ position
  regardless, which resets `winStart` and drops everything still resident. A
  consumer slower than the transfer, which is what the parse pass is (one 256 KB
  AVIO buffer at a time), therefore re-fetched what it had just been handed.
  Measured with aetherctl against a Range-logging origin: a 764450 B trailing
  `moov` cost three connections and 1506918 delivered bytes, 1.97x its own size.
  It now costs one. Serving what is in hand first also lets the #220 frontier
  refill run, which it could not while this branch preempted it on every
  completed range.

- **A read at the end of the file no longer opens a connection for it.** The EOF
  decision sat below the reconnect, so a position at exactly `fileSize` first
  issued `bytes=<fileSize>-` and took an empty 206 whose reconnect reset
  `winStart` past the last byte, dropping a window the parse was still reading.
  On the same trailing-`moov` measurement that was one of the three connections.

- **The head of the file is retained across the open phase, so the return trip
  after a parse excursion is a copy.** #281 parked the open window at seek time,
  cut from `winStart`, on the reasoning that the demuxer returns to the window's
  start. It returns to the FILE's start: landings of 48, 1161, 5752 and 265159
  across four MP4 layouts and a field trace. Those coincide only when the parse
  seeks away before reading anything. A fragmented MP4 reads 33 MB first, so
  `winStart` has long left the head and the parked copy covers nothing that is
  asked for. The head is now collected as the data connection delivers it, which
  is the only point at which it can be, since `trimWindowLocked` drops it as the
  parse moves forward. Measured with aetherctl against an origin with 300 ms of
  latency per request: opening a fragmented fixture went from 1732 ms and four
  requests to 1219 ms and three. The parked window is gone: across six container
  layouts (four MP4, two MKV) it served no read that the retained head does not.

## [6.5.1] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.5.1))

### Fixed

- **The speculative tail fetch now removes the round trip it was added for.**
  6.4.5 issued a 64 KB suffix range alongside the open and let nothing wait on
  it, on the reasoning that a fetch landing late costs no more than the
  reconnect it failed to save. That reasoning was wrong about the timing, and
  the reporter's retest measured it: the demuxer reaches the trailing object
  within microseconds of the data connection's first byte, and the speculative
  fetch pays the same round trip plus a body, so on any origin whose first byte
  costs anything it is still on the wire at that moment. It never once served
  the read it exists for, it only added a request. A read landing in the
  fetched range now waits for it, bounded by what a round trip against this
  origin was measured to cost (the data connection's own time to first data),
  so waiting can never be the more expensive choice, and an origin that
  declines suffix ranges falls straight back to a reconnect. Only a loopback
  origin, which answers before the race can be lost, made the first version
  look like it worked, so the regression test models an origin whose first byte
  costs something.

### Changed

- The cold-start paths now say what they did. `tail prefetch issued`, then
  `installed` or `rejected` with the reason (status, disagreeing
  `Content-Range`, short body), and one line per span when it serves a read
  that would otherwise have reconnected. The advertised way to verify #281 was
  to look for a `bytes=-65536` request, which the engine never printed, so its
  absence from a log was not evidence of anything. Slow-read summaries gained
  `tailWaits=`.

## [6.5.0] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.5.0))

### Fixed

- **A terminal error now says what went wrong instead of "The operation
  couldn't be completed."** The engine publishes its terminal states as
  `state = .error("Failed to load: \(error.localizedDescription)")`, and its own
  error enums were only `CustomStringConvertible`. `localizedDescription` does
  not reach `description`, so Foundation's generic bridge answered "The
  operation couldn't be completed. (HLSIngestError error 0.)" and the HTTP
  status the ingest reader had already resolved was dropped at that boundary:
  an origin refusing a transcode with 500 was indistinguishable from a corrupt
  file. Every error type the engine can throw now conforms to `LocalizedError`
  with `errorDescription` returning the description it already computes, which
  fixes the reload, audio-track-switch and mid-session playback boundaries in
  the same move rather than the three load-path call sites alone.
  `DemuxerError` is the most common failure at that boundary and carried no
  description at all; it now renders its AVERROR code with libavutil's own
  text, so `INVALIDDATA` reads as itself rather than as an error number 0.
  Reported by @edde746, traced to the boundary (#283).

### Added

- **`LocalizedError` conformance on the public error types.** A minor rather
  than a patch: `HLSIngestError`, `PacketTimingProbe.ProbeError`,
  `AudioTapProbe.ProbeError` and the two `AetherEngineSMB` error structs gain
  public conformance and an `errorDescription`, and an adopter that renders a
  caught error with `localizedDescription` sees different text on this version
  than it did on 6.4.x. The text is the `description` those types already
  published, so anything already logging `"\(error)"` is unchanged.

## [6.4.7] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.4.7))

### Fixed

- **A live DVR rewind deeper than about 40 s no longer asks for a segment the
  cache has already deleted.** A live session resolved a segment retention
  budget of 0, on the reasoning that the sliding playlist had already dropped
  everything behind the window so retention would serve nothing. That had it
  backwards: the playlist window is the looser bound (300 segments for a 600 s
  DVR window at a 2 s cadence), while `pruneOutsideWindow` with a 0 budget
  takes its hard-window branch and cuts at `currentTargetIndex -
  backwardWindow`, i.e. 20 segments. Live therefore retained ~42 s no matter
  what `dvrWindowSeconds` asked for, while the playlist and the published
  `liveSeekableRange` advertised the whole window, and live has no
  `restartHandler` to re-produce a segment that is gone. Measured on the
  engine before the fix: `cacheCount` pinned at 21 for a whole 150 s session
  with `dvrWindowSeconds: 600`. Live now resolves the same volume-aware budget
  as VOD (2 GiB, clamped to a quarter of free space), which is the mechanism
  built for exactly this, so the retained history tracks the advertised window
  and stays bounded by it. `backwardWindow` keeps its own job as the
  Continuous-Audio handover floor. The producer-side prefetch park the budget
  also feeds is VOD-only, so live cannot park on it.

## [6.4.6] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.4.6))

### Fixed

- **Live sessions no longer freeze 6-8 s at a time when the producer's
  backpressure park meets an LL-HLS blocking reload.** The advance park
  released only on a client segment GET, while the client's held
  `?_HLS_msn=` reload was only satisfiable by a producer cut, and the held
  reload occupies the serialized keep-alive connection, starving the very
  segment GET that would release the park. The 18 s hold then expired into
  `503 unsatisfiable` long after AVPlayer's ~4 s forward buffer had drained
  into `playbackStalled`. Live production is source-paced now: the advance
  and versioned-init parks are VOD-only, replaced on live by a logged
  resident-segment runaway guard set far above the steady-state window, so
  only a consumer that has already stopped polling can reach it (a live park
  is a diagnostic, never steady state). Three aggravators fixed alongside:
  the sliding window is sized by the observed segment cadence instead of the
  cut target (fastZap's 0.5 s target vs ~2 s GOPs inflated the window 4x,
  pinning MEDIA-SEQUENCE at 0 and deferring `evictBelow` for minutes), the
  stall-recovery item reload now honors `LiveReloadPolicy` (live rejoin: no
  stale-clock resume, no zero-tolerance initial seek), and the
  blocking-reload hold is bounded by `3 x` the sealed TARGETDURATION
  (= the advertised HOLD-BACK) instead of a hardcoded 18 s. VOD paths are
  byte-identical. Reported and fixed by @tschuegy in #280.

### Changed

- **A live playlist whose sliding window overtakes the consumer's fetch point
  now says so.** The removed advance park capped the producer 10 segments
  ahead of that point, so the window could never pass it. Source-paced live
  cannot get there, but an origin handing over more than one window of
  backlog faster than the consumer drains it can, and the consumer then asks
  for a segment `evictBelow` has already deleted. That reads downstream as a
  cache miss or a live-edge jump with nothing naming the cause, so the
  playlist builder logs `live window slid past the consumer` once per
  excursion.

## [6.4.5] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.4.5))

### Fixed

- **A non-faststart MP4 cold start no longer pays three sequential round trips
  before the frame rate is known.** Opening one costs a data connection from
  byte zero, a seek to the trailing `moov`, and a return to the first sample.
  The third was self-inflicted: the seek to the tail discarded the window that
  already held the bytes the return trip went back for, so the reader
  re-fetched what it had just thrown away. That window is now kept for the
  duration of the demuxer's open pass and serves the return trip as a copy.
  Alongside it, `open()` issues one speculative 64 KB suffix range (`bytes=-n`,
  which needs no size and therefore runs in parallel with the very first
  request), covering the small trailing objects an open actually reads: `mfra`
  on fragmented MP4, and a trailing `moov` whose sample tables fit. On a 51 MB
  moov-at-end file the open goes from three sequential requests to two
  concurrent ones. A feature-length file's `moov` is far larger than 64 KB and
  still costs its own request, by design: fetching megabytes on a guess would
  compete with playback bytes on exactly the slow links this helps. Reported
  with before/after traces in #281.

- **Display-criteria settle times in the log are measured now, instead of
  having the Stage 1 budget added back in.** Stage 2 reported
  `startGrace.ticks * 10 + stage2Ticks * 50`, which counts Stage 1's entire
  blind-poll budget whether or not it was spent, so a rate switch that settled
  one 50 ms tick after a start the gate saw immediately logged `~1050ms`. Every
  settle time in every log collected so far reads up to a full second slow,
  including the ones the `.brief` play-gate budget (#274) was reasoned about.
  The line now carries the real numbers plus how Stage 1 learned of the switch:
  `start pre-gate after 0ms, total 90ms`, where `pre-gate` means the panel was
  already switching when the gate opened (so the switch began during the load
  that built the AVPlayerItem) and `in-gate` means it started inside the gate.
  That distinction is the ordering question these logs were added for and could
  not answer. The Stage 2 cap also stops attributing every unobservable switch
  to an unobservable DV panel: it reads the same attribution the settle branch
  got in #274, so an engine rate-only write that never reports an end says so
  rather than claiming DV. Measured from the logs on Sodalite#49.

## [6.4.4] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.4.4))

### Added

- **The `#250 subtitle-resolution` statement now states the determination span
  it retains across a seek, as `retainedFrom=`.** `coveredFrom` is the last
  reset's window start, so after a far seek it reads `target - 15` and can
  neither affirm nor refute that determination still reaches back to track
  start. That left one truth class inexpressible: "empty because nothing was
  ever authored before this point", which needs coverage back to the earliest
  point that could change the answer. The pre-seek line does carry the bound,
  but under the previous `seekGen`, and combining across the fence is what the
  fence exists to forbid. The engine now reconciles the runs itself: a
  post-seek reset folds its window into the retained run instead of
  overwriting it, and the line states that run's floor alongside the reset
  window. `coveredFrom` is unchanged; the two are separate claims. The runs
  join only when the new window opens inside the retained span, so a forward
  seek past the determined end and a backward seek starting below the floor
  both restart the run rather than span the hole. Requested by @cmcpherson274
  (#276).

## [6.4.3] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.4.3))

### Fixed

- **The post-load play-gate only pays the Dolby Vision cold-start budget when a
  dynamic-range switch can still reach the session.** The gate blind-polls up to
  1000 ms for a panel switch to *start*, a budget sized for the one case that
  needs it: a sole-writer host (`LoadOptions.suppressDisplayCriteria`) whose
  criteria write lands during the load, from AVKit's auto path. Every other
  session paid the same wait for a switch that could not arrive. Sessions where
  the engine wrote the criteria itself (synchronously, before the item loads, and
  already settled in the pre-flight for an HDR write) and sessions on SDR content,
  which no dynamic-range write can follow, now take a 200 ms budget instead, the
  value that was in place before the AVKit-sole-writer architecture raised it. A
  switch that has genuinely started still settles in Stage 2 unchanged, and a
  failed probe keeps the full budget because the source range is then unknown.
  Reported and measured by @digilearn-dev (#274).

- **A panel switch the engine did not initiate is no longer logged as a failed
  HDR handshake.** When a sole-writer host's own criteria write settled with EDR
  headroom at 1.0, the settle classification read `didApply == false` as the HDR
  branch and emitted `WARN ... panel stayed SDR despite HDR criteria` for what
  was a correct SDR rate-only switch. The engine has no target range to compare
  against for a write it never made, and now says so (#274).

## [6.4.2] - 2026-08-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.4.2))

### Fixed

- **A seekable HEVC-in-MPEG-TS HLS VOD plans its segments on the playlist's own
  boundaries.** MPEG-TS carries no upfront keyframe table, so the plan fell back
  to a synthetic uniform 4 s grid. On a source that carries one I-frame per 10 s
  segment only every fifth grid boundary is a random-access point, so a restart
  at any other index made the producer's scan-forward gate open up to 8 s late.
  That overshoot rode in the producer's timeline shift, where the video cutter
  and the audio index mapping folded it back on two different axes, and AVPlayer
  was left waiting on a segment that never arrived at the position it asked for
  (`CoreMediaErrorDomain -12889`). A seekable source now plans on the boundaries
  it declares, each backed off half a segment (0.5 s cap) so manifest-versus-PTS
  rounding cannot put a boundary past its own IRAP. Measured over five scattered
  seeks on a 10 s-GOP fixture, the per-restart gate overshoot goes from
  0/4/0/2/6 s to a flat 0.5 s. Reported and device-tested by @qoli (#268).

- **The VOD segment cutter compares on the item axis.** Packets reach it with the
  producer's shift already subtracted, while the plan boundaries are source PTS,
  so every cut landed one PTS origin late on any source that does not start at
  zero, and against boundaries that are themselves the source's IRAPs it would
  never have cut at all. The audio index mapping folds back the plan anchor
  rather than the shift for the same reason, and a restart's first `tfdt` is the
  segment's advertised start rather than its seek boundary (#268).

## [6.4.1] - 2026-08-01

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.4.1))

### Changed

- **`$subtitleCues` publishes once per drain tick instead of once per decoded
  subtitle packet.** Every publication carries the whole cumulative cue array,
  and a snapshot cannot tell a consumer which of its elements are new, so each
  one cost every subscriber a full walk: O(n) per packet, O(n²) per drain
  window. On a typeset ASS track that was 104 publications and 608,608 cue
  visits per second in a single consumer, none of which found new work. The
  tick now binds the channel's array once, applies the whole batch of decoded
  events to it, and publishes only when the batch actually changed something.
  The retained-store insert also looks up same-start cues by binary search
  rather than scanning the whole array. Reported and measured by @edde746
  (#271).

### Fixed

- **One drain tick no longer decodes an unbounded number of subtitle packets.**
  The drain window is bounded in seconds of content (backscan plus lead), never
  in packets, so its size was set by the file's subtitle density while the
  decode loop ran synchronously on the main actor with no suspension point. It
  is now capped per tick, with the boundary extended to the end of the run
  sharing the last packet's PTS: the drain cursor is a bare PTS advanced past
  what it decoded, so a cut inside a same-PTS run would skip the remainder
  rather than resume it on the next tick. Dense ASS deliberately keeps hundreds
  of distinct payloads on one timestamp. The subtitle OCR worker's existing cap
  gets the same PTS-boundary correction (#271).
- **A slow drain tick no longer reads its own duration as a seek.** The plan
  compared the live playhead against the playhead captured at the previous
  tick's start, so a tick lasting longer than the 2.5 s jump threshold made the
  next one reset onto a fresh, disjoint window: a positive feedback loop, since
  the reset window is the expensive one. Forward drift is now forgiven up to
  the wall time the previous tick consumed. Backward drift is not, because
  playback never moves the playhead backwards (#271).

## [6.4.0] - 2026-07-31

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.4.0))

### Added

- `HLSVideoEngine.sourceStartSeconds`, the source PTS the container's own
  timeline starts at. The engine folds it out of the published playhead; a host
  driving `HLSVideoEngine` directly can read it to do the same.

### Fixed

- **Finite HEVC-in-MPEG-TS HLS VOD no longer reaches AVPlayer's audio-only,
  black native path.** A bounded content probe now confirms the playlist is
  finite, its segments are MPEG-TS, and its PMT declares HEVC before selecting
  a seekable TS-to-fMP4 ingest. Direct media playlists and master playlists are
  both covered; URL, HTTP headers, duration, resume position, and forward or
  backward seek semantics are preserved. H.264, fMP4, live, audio-only, and
  inconclusive HLS inputs keep their existing route. The ingest is addressed on
  elapsed media time, so a source whose MPEG-TS PTS origin is not zero
  (broadcast-derived VOD routinely starts hours in) still lands where the host
  asked. (#268, PR #269, reported and implemented by @qoli)
- **A VOD source whose container starts at a non-zero PTS now publishes its
  playhead on the same 0-based axis as its duration.** The display origin was
  anchored for disc titles only, so a transport stream muxed with a 60 s origin
  opened its scrubber at 1:02 of a ten-minute item, and at broadcast scale a
  seek target computed on that axis resolved outside the item and landed at the
  start of the file. Sources that already start at 0, which is every MP4, are
  unaffected. (#270)

## [6.3.0] - 2026-07-31

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.3.0))

### Added

- **`ExternalSubtitleTrack.sourceStreamIndex`, so an external subtitle URL can be a container rather than a sidecar.** An external track's URL may hold several subtitle streams (an MKV with English, English SDH and Spanish), and a host would register one track per stream against that same URL. The sidecar decoder stopped at the container's first subtitle stream and the descriptor carried no index, so every such track decoded that same stream and the host got three selectable tracks rendering identical cues. The new field names the stream to decode as an absolute `AVStream` index inside the container, matching the convention that embedded track ids are stream indices; nil keeps decoding the first subtitle stream. An index that is out of range or names a non-subtitle stream fails the decode rather than falling back to the first subtitle stream, because a silent fallback is indistinguishable from the behaviour the index exists to escape. Reported by edde746. (#266)

### Changed

- **External tracks sharing a container are now filled from a single pass over it.** Each load-declared external track used to be decoded by its own whole-file read, so three tracks pointing at one MKV meant three full downloads at load, and `AVDISCARD_ALL` cannot shorten them (a Matroska demuxer reads every discarded byte anyway). Tracks sharing a URL and headers are now decoded together in one pass, one stream decoder per requested stream. Since a pass covering several streams fails as a whole, a failure retries the targets individually, so one host-side index mistake cannot blank the container's other tracks; a store that still could not be filled stays unfinished rather than serving a complete but blank rendition.

## [6.2.1] - 2026-07-30

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.2.1))

### Fixed

- **An ASS track that declares its play resolution with CRLF line endings is no longer read as declaring none.** The header arrives as codec extradata byte for byte as the muxer stored it, and muxed ASS is conventionally CRLF, so the line is `PlayResX: 718\r`. The trim used `CharacterSet.whitespaces`, which is space and tab but not CR, so the CR survived and `Double("718\r")` returned nil. Both lookups failed, the header was reported as declaring nothing, and every `\pos` on the track normalized against libavcodec's 384x288 default instead of the declared space. On a 718x480 script `{\an1\pos(298,432)}` reached the host at (0.776, 1.500) rather than (0.415, 0.900), which is off-picture and indistinguishable from a cue that never arrived. Header lines now split on any newline (CRLF, LF or lone CR) and trim newline-inclusive. Tracks that declare no play resolution are unaffected, since 384x288 is then the correct basis. Reported by rrgomes, traced to the line. (#261)

### Changed

- `SubtitleTextPlacement.position` no longer documents a [0, 1] range. A script may anchor outside the frame on purpose, so that is a range the engine cannot guarantee, and clamping or dropping such an anchor engine-side would hide the next wrong normalization basis the way #261 hid. Hosts that cannot draw off-picture should decide for themselves what to do with such a cue. No behaviour change.

## [6.2.0] - 2026-07-30

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.2.0))

### Added

- **The native path now states the relation between its two time axes, instead of leaving a host to infer it.** Cue times, chapter marks and `sourceTime` are source PTS; `AVPlayerItem.currentTime()` and its timebase are the axis the producer muxes into the segments. They differ by the producer shift, and nothing published closed that gap for a host compositing its own overlay: adding `playlistShiftSeconds` is correct only until the next producer epoch, the clock ticks at ~10 Hz and a clock reading is not a frame boundary, and the per-segment pair is a genuine pair but six seconds apart. `player.presentationAxisMap` converts either way at any position and is readable off the main actor, and `setNativeVideoFrameTimeObserver` reports both axes for every muxed frame, with its segment index, keyframe flag and producer epoch. Frames arrive in decode order, so `source` is not monotonic under B-frames. Both surfaces answer nothing rather than zero when no axis has been established, since at the call site a defaulted shift is indistinguishable from a measured one, which is what #259 cost. `player.currentAVPlayerItem` publishes alongside, because items are swapped in place and a host holding a timebase otherwise gets no signal. Requested by edde746 for frame-accurate libass rendering, with the axis measurement that showed the gap.

### Fixed

- **A VOD producer restart no longer folds the whole timeline with its new shift.** Each producer computes its own shift when its video gate opens, and a restart lands wherever the source seek lands, so a restart can change it. The shift history was rebuilt from scratch on every VOD restart with one entry covering everything, so content muxed by the previous producer, which AVPlayer can still hold in its buffer and put on screen, was folded with the incoming shift: the published playhead then leads or trails the picture by the difference for as long as that buffer lasts. The history now records the item-axis position each producer starts writing at and keeps the entries below it, and a backward restart drops only the entries it actually rewrites. Live already worked this way for program boundaries; that path is unchanged. Note that the shift-fold hypotheses in #65 were refuted by measurement at the time: that burst ran with an invariant shift, so this mechanism was inactive there and is not a retroactive explanation for it.

## [6.1.4] - 2026-07-30

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.1.4))

### Fixed

- **In-picture A/53 closed captions are timed against the source again, not against the playlist.** The extraction rides the segment producer's per-packet finalize step, which runs after the pump has rebased the packet onto the output timeline, so the timestamps handed to the caption tap carried the playlist shift while everything downstream reads them as source PTS: the decoded cues feed `subtitleCues`, and a host renders those against `currentTime`, which folds that same shift back in. Every A/53 caption was displaced by it, and because the shift is recomputed on each producer restart, the displacement changed after every seek. On a clip with B-frames it is two frames at head of stream; a restart landing off its planned keyframe has been measured in seconds; and a broadcast MPEG-TS source whose first DTS sits far from zero, which is the case this path exists for, carries it from the first packet. Only the producer path was affected: a demuxable `eia_608` / `c608` caption track is tapped before the rebase, and the software path reads its triplets out of decoded-frame side data, where no shift exists at all. Reported by edde746 from a read of the value flow plus a measurement of the shift magnitude, without a caption-bearing source on hand.

## [6.1.3] - 2026-07-30

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.1.3))

### Fixed

- **Teletext rows no longer arrive with the column padding still on them.** A page libzvbi does not classify as a subtitle page is written out as the raw grid, every row at full column width with a hard space per grid cell, and the engine's two whitespace passes both walked past the inside of a line break: one trims the outer edges of the whole cue, the other folds what sits between two newlines and never looks at the characters touching a single one. A two-row caption therefore reached the host as `row one<pad>` / `<pad>row two`, which puts the second row visibly off centre on a renderer that centres each line and draws the cue's background box wider than its text. Both passes are now gated on that same raw-grid case, which is exactly the page that arrives without an alignment override, so a page the decoder curates itself is passed through whole: there the surviving padding is the relative indentation carrying the alignment it picked, and the blank lines are its vertical fine-positioning inside the block, both of which the blank-line fold had been discarding since #107. Reported by tresby, who had solved it row-wise in a proxy implementation and supplied the failing sequence.

### Changed

- **FFmpegBuild and LibDovi are pinned to the minor rather than floating from a lower bound**, so a released engine tag's dependency set is a property of the tag instead of the registry at resolve time. Both classes of drift this guards against were live: LibDovi 1.1.0 raised its declared tvOS floor in a minor, which SwiftPM floats onto and then fails on instead of backing off, so every 5.x tag stopped resolving; and FFmpegBuild 2.4.0 replaced 2.3.0 under a fixed 5.28.0 checkout. Forward-looking only, already published tags keep what they declared. Consumers resolve to the same versions as before (FFmpegBuild 2.4.0, LibDovi 2.0.0).

## [6.1.2] - 2026-07-30

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.1.2))

### Fixed

- **Opening a large progressive HTTP source no longer dies in the allocator before the first frame.** The chunk-fetch delegate reserved whatever the response declared, and one of the requests that reaches that line is the HEAD size probe, which declares the entire source and delivers no body at all: opening a 12.4 GB MKV asked malloc for 12.4 GB in order to buffer nothing, and on a 6 GB device the NULL that came back was force-unwrapped inside `Data`'s storage, so it trapped on the URLSession delegate queue rather than throwing (a host app could neither catch it nor degrade). The HEAD fallback is launched 0.75 s after the range probes and runs whenever they have not resolved a size yet, so this was reachable on any non-prefetch open (still extraction, one-shot seekable) against a slow origin, not only against origins that reject Range outright. The reservation now comes from the request instead of the response: the span of a bounded `Range`, nothing at all for a HEAD, a flat 8 MB ceiling for an open-ended request. The body is bounded by that same span, so an origin that ignores `Range` and answers a bounded chunk request with `200` plus the whole source's length is hung up on after the requested prefix instead of having its entire file buffered and then rejected. Reported by dlev02 from a symbolicated crash report.

## [6.1.1] - 2026-07-30

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.1.1))

### Fixed

- **A seek on the software path no longer blocks the main thread for the length of a network read.** `SoftwarePlaybackHost` is `@MainActor` and ran the demuxer reposition inline, so a seek issued while the demux loop sat in a slow remote read waited out that read on the main thread: two field App Hangs, "Fully Blocked", 4.4 s and 5.2 s, on a WAN source. The lock is held across the whole of `av_read_frame`, which is also why the existing deadline could not have prevented them, since it is armed on the far side of that lock. The reposition now runs off the main actor under an 8 s read deadline, and a burst of scrubs collapses onto its last target instead of paying one lock wait per seek. The same inline call sat in both hosts' `startPosition` resume, so this covers every resume into a remote source, not just scrubbing. A reposition that spends its budget reports `.stalled` on `seekEvents` rather than a landing it cannot back up. Reported by rrgomes from two production crash-reporter events.

## [6.1.0] - 2026-07-30

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.1.0))

### Added

- **A seek now says what happened to it, not just that it stopped happening.** `isSeeking` / `seekTarget` are a level, and a level's falling edge cannot distinguish a landing from a give-up from a supersede, nor keep the target it belonged to (both properties clear in the same recompute, and any consumer that hops a queue sees them coalesced). `player.seekEvents` publishes `.began`, `.landed(renderedTime:)`, `.stalled`, `.superseded` and `.rejected`, each carrying its target and an id that pairs a seek with its outcome. The one asymmetry is the point of the stream: a seek that spent its recovery budget reports `.stalled` and drops out of `isSeeking`, but it stays alive inside AVPlayer, so its `.landed` can still arrive minutes later on a source that finally serves the target. Reported by rrgomes from production use of the signal in a synchronized-playback host, which had rebuilt all of this out of a landing grace, a retained last target and a 180 s unreached-target map.

### Fixed

- **A native scrub no longer reports a landing before the picture arrives.** The scrub's in-flight window ended when the coalesced producer restart drained, which means "the producer is producing at the new index", not "AVPlayer rendered it"; the picture follows a fetch and a decode later, measured at 1.4 s on a WAN source. The window now ends when the rendered frame reaches the restarted region, bounded at 8 s so a source that never serves it degrades to `.stalled` instead of latching the signal.
- **A seek issued before the session can take it is visible instead of silently optimistic.** Seeks stashed during load or against a pre-ready item (#127/#178) publish their target on `currentTime` so scrub UI follows, but left `isSeeking` false, which is the worst combination for a consumer broadcasting that position: a place nothing has reached, with no in-flight flag to suppress it. The stash window now carries the seek signal and hands over to its replay without a gap.
- **`seekTarget` no longer publishes a settled seek's destination.** It folded over the last non-nil target ever written, so a finished programmatic seek's target stayed published while a scrub was in flight toward a different one. Each source now owns its own target, and the published value follows the most authoritative one in flight.
- **A stop landing mid-seek no longer leaves the subtitle side-reader link owned by the video path** for the whole next session (the #240 gate is per engine, not per session).

## [6.0.2] - 2026-07-29

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.0.2))

### Added

- **The subtitle path now states how far it has decoded display state, on the absolute source axis and fenced by generation.** After a far seek lands, nothing in the log could tell "the pipeline has determined the display state here" from "it has produced nothing yet"; on a PGS track with no acquisition point those are indistinguishable from outside, and that distinction is the whole adjudication for a conformance harness. One line per active drain target, at post-seek reconstruction, on the 30 s cadence, at prefetcher EOF, and whenever the frontier's source changes: `[AetherEngine] #250 subtitle-resolution loadGen= seekGen= stream= coveredFrom= resolvedThrough= via= decodedThrough= reason=`. `resolvedThrough` is the decode window clamped to a harvest frontier, never the window's own lead edge (which would claim determination over unread bytes) and never the drain cursor alone (which stands still through every dialogue pause on a sparse track), with `via=prefetch|eof|pump` stating which frontier bounds the claim and therefore what the number is worth. Requested by cmcpherson274. No published property, no behaviour change.

## [6.0.1] - 2026-07-29

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.0.1))

### Fixed

- **Every 5.x tag stopped resolving, and 6.0.0 pinned the cause.** LibDovi published the visionOS slices and the tvOS floor correction together as 1.1.0. A raised platform floor is a breaking change, so it belonged in a major: SwiftPM resolved that new minor into every consumer pinning `from: "1.0.x"`, then failed the build on the floor mismatch instead of backing off to a version that fits. Any AetherEngine 5.x tag, all of which declare tvOS 16 and `LibDovi from: "1.0.2"`, became unbuildable on a fresh resolve within hours of that release. Reported by cmcpherson274 while retesting #240 on 5.28.0. The same content is now published as LibDovi 2.0.0 and the 1.1.0 tag is withdrawn, so the 5.x line resolves back to 1.0.2 and builds again; this engine pins `from: "2.0.0"`. 6.0.0 itself points at the withdrawn tag and no longer resolves, so it is superseded by this release rather than merely followed by it.

### Changed

- **The subtitle side readers no longer take the link without leaving a trace.** `prefetchYielded` counts every priority yield, a seek in flight as much as a producer that is fetching, while the `yielded the link for` line is emitted once per continuous-yield-cap grant, so a session can legitimately show seconds of yield with no such line anywhere. Reading the two as one number is a mistake this codebase invited and then made in an issue reply. The memprobe now carries `prefetchValve=N` next to `prefetchYielded=Ns` so the escape hatch has a figure of its own, and the native subtitle readers log their grants in the same shape the #151 prefetcher does instead of taking them silently.

## [6.0.0] - 2026-07-29

**Superseded by 6.0.1: this tag pins the withdrawn LibDovi 1.1.0 and no longer resolves.**

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/6.0.0))

### Added

- **visionOS is a supported build platform.** `Package.swift` declares `.visionOS(.v1)`, and the engine builds for visionOS device and simulator against FFmpegBuild 2.4.0 and LibDovi 1.1.0, which carry the `xros` slices. Three source sites learned about the platform: the AV1 supplemental-decoder registration in `VTCapabilityProbe` (a platform absent from `#available` counts as available, so visionOS reached an API introduced in 26.2), the AirPlay observation (`AVPlayer.isExternalPlaybackActive` is unavailable there, so the whole serve-the-loopback-over-the-LAN path is compiled out and inert), and `SampleBufferRenderer` (`preventsDisplaySleepDuringVideoPlayback` does not exist and `preferredDynamicRange` arrives in 26.0). The tvOS-only display-criteria layer needed nothing: visionOS has no HDMI mode handshake, so the criteria-free routing the iOS path already uses applies. Playback on real hardware is unverified. Requested by jihongboo (#161).

### Changed

- **BREAKING: the tvOS floor is 17.0, up from 16.0.** This is a correction rather than a new requirement. LibDovi compiles its tvOS slices with `-mtvos-version-min=17.0` and declares `.tvOS(.v17)`, so a consumer building this engine against tvOS 16 was already linking a binary that never supported it; the manifest simply claimed otherwise. It surfaces now because the LibDovi release carrying the visionOS slices also carries that correction. Nothing else in the public API changed, and no symbol was removed or renamed.

## [5.29.0] - 2026-07-29

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.29.0))

### Fixed

- **A remote HLS VOD source died when the load-time probe failed for an unrelated reason.** The AE#154 reroute onto the native remote-HLS bypass keys on the reader's typed `hlsPlaylistOnVODPath` classification, but that classification only reaches it when the load-time probe is the open that reads the playlist body. If the probe failed transiently first, the load fell through to the loopback path with no preopened demuxer, `HLSVideoEngine.start()` reopened the URL, and that second open produced the classification, which was then interpolated into `openFailed(reason:)` and lost its domain. A playable source failed terminally with `HLS playlist supplied to the VOD loopback path`, while a manual retry (whose first probe happened to see the body) played natively. The fallback open now rethrows both HLS classifications verbatim, and a load that reaches one takes the same AE#154 reroute, preserving URL, headers and resume position. Reported by qoli (#246).
- **The remote-HLS bypass ignored the resume position.** `LoadOptions.nativeRemoteHLS` routes before the probe, and that branch never forwarded `startPosition`, so a VOD playlist restarted at zero whether the host requested the bypass directly or arrived on it through a reroute. VOD now honors the anchor; live keeps its no-initial-seek contract even when a host passes one.

### Added

- **Container chapters as `mediaChapters`.** Matroska and MP4 chapters are read off the probe demuxer at load and published as `@Published mediaChapters: [ChapterInfo]`, so a host can bind a chapter picker for ordinary files the way it already can for discs. Empty for disc sources, which keep publishing `discChapters`; unlike those, a container chapter's `startSeconds` is already a timestamp on the `seek(to:)` axis and needs no base (`selectChapter(id:)` stays disc-only). Ids are sequential in start order, untitled entries are numbered, and a chapter's duration runs to the next chapter's start rather than to its declared end, because muxers routinely write `end == start`. Contributed by natedogg058 (#179).
- **System Now-Playing on the native video path, opt-in.** A host with a custom transport can now let the engine own an `MPNowPlayingSession` bound to the native player: set `ownsVideoNowPlayingSession` before `load()`, register transport commands on the published `videoNowPlayingSession`, and stage identity metadata with `setVideoNowPlayingInfo(_:)`, which is replayed onto every fresh `AVPlayerItem` (readiness-gate reloads, media fallback, in-place PiP swaps). The session lives on the native host, so it survives native->native reloads and keeps system Now-Playing ownership across a background pause, the same shape the audio path already had. It is off by default and must stay off under `AVPlayerViewController`, which owns Now-Playing itself; two owners leave an empty identity card and remote commands routed into a session with no handlers. Contributed by natedogg058 (#180).

## [5.28.2] - 2026-07-29

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.28.2))

### Fixed

- **A disc image leaked every byte it read.** `HTTPDiscIOReader` and `FileIOReader` are driven from FFmpeg's read callback, which runs on a demux pump thread that stays inside one dispatch block for the whole session and so never drains its autorelease pool, so every body they bridged out on that thread was stranded until playback ended. On a remote Blu-ray ISO that is up to 8 MB per range request, several a second, once per reader fork (main demuxer, subtitle side demuxer, forward prefetcher), which is the ~30 MB/s of `mallocMB` growth the reporter measured; RSS looks flat because the pages are never touched again and go to the compressor, and the process is eventually jetsammed. Both readers now drain per read, and the SMB reader got the same treatment. Measured against a local range origin, 480 MB fetched left +968 MB in use before and 0 MB after, and 128 MB read through the file reader left +134 MB before and 0 MB after. A per-request `URLSession` fixes nothing here (+973 MB), which also retires the older reading of the AVIOReader leak as URLSession retaining completed bodies until invalidation: the owner was always the caller thread's pool. Reported by bitxeno (#243).

### Added

- **`discFetchedMB` in the memprobe.** The disc pull path had no byte counter at all (`avioFetchedMB` covers the AVIOReader path only), so on a disc-image session every engine-tracked pool reads flat while the reader forks pull tens of MB/s. Printed only when the path is in use, session-scoped like `t=`, so two probe lines give a rate.

## [5.28.1] - 2026-07-29

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.28.1))

### Fixed

- **`SubtitleCue.placement` reached the host on sidecars but never on an embedded track.** 5.26.0 added the field and the decoders fill it correctly, but every operation on the retained cue store rebuilt the cue through the memberwise initializer to change one field, listing the fields it happened to know about. `placement` is defaulted there for source compatibility, so those call sites dropped it and still compiled. The decisive one stamps the session-monotonic id on every cue entering the store, so nothing arriving through the drained embedded path could carry a placement at all, and the #107 text trim would have dropped it a second time on each teletext page transition. That is the split the reporter saw: WebVTT placement worked because a sidecar's cues are published as decoded, teletext placement did not because it is an embedded track. Cue rebuilds now go through one copy helper that carries every field it is not asked to change. Reported by tresby (#233).

## [5.28.0] - 2026-07-28

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.28.0))

### Fixed

- **Far seeks stop competing with the subtitle side reader for the source link.** On Matroska a subtitle-only side reader is a second full copy of the stream (`matroska_parse_cluster` reads every block off the wire, `matroska_parse_block` only then honours the discard flag), so a subtitled session asks the link for roughly twice the media rate. Above about 2x headroom nobody notices; at 1.3x to 1.5x, an ordinary Wi-Fi bench in front of a high-bitrate remux, the two readers split the link and the video path misses its deadlines. The reporter measured the same segment serving in 2.2 s alone and 7.5 s alongside the prefetcher, which expired the seek landing budget; the recovery then re-anchored, which jumped the clock, which rebuilt the prefetch session, which took more link, and landings stacked to 25 s. The video path now has priority: a side reader fetches while the pump is parked, yields while it is fetching, yields completely while a seek is in flight, keeps a bounded grace window after each anchor so a freshly selected track still fills, and takes the link back after a 60 s continuous yield so a pump that never parks cannot disable lookahead for a session. A playhead jump re-anchors the running prefetch session in place instead of tearing it down and building a new one, which since the bounded ranges of 5.24.0 cost an open, a Matroska cue-index prewarm and a positioning seek, each a full range off the link, once per jump. Measured on a shaped 1.4x-headroom bench: far-seek landings 23.5 s to 12.7 s at the median, source connections 35 to 21, and the side reader's share of the bytes roughly halved. Reported by cmcpherson274 (#240).

### Added

- **Per-reader link attribution in the log.** Every `AVIOReader` carries a label (`pump`, `prefetch`, `nativesubs`, `extract`), the connection-start line names it and reports its range length, and it is no longer `DEBUG`-only; the 30 s memprobe reports `pumpFetchedMB` next to `prefFetchedMB` plus the prefetcher's cumulative link yield. Without those, several readers against one origin are indistinguishable in a field log, and a single reader walking forward in bounded ranges reads like several concurrent connections.
- **`aetherctl play --seek-pattern a,b,c` and `throttle-origin.py --shared`.** A list of absolute far-seek targets, one per `--seek-every` tick, with the elapsed time printed per seek; and a throttling mode that shapes the sum of all connections rather than each one. Per-connection shaping gives two readers the full rate each, so a contention defect cannot reproduce under it at all.

## [5.27.0] - 2026-07-28

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.27.0))

### Added

- **External WebVTT subtitle files load at all.** The FFmpeg build carried the `webvtt` decoder but never the `webvtt` demuxer, so `avformat_open_input` rejected every standalone `.vtt` file with `AVERROR_INVALIDDATA` and a sidecar WebVTT track failed before a single cue was decoded, on every path that opens one. Same shape as the raw-PGS `sup` gap fixed in FFmpegBuild 2.1.3, and it hid for the same reason: the codec was present, so the failure looked like it had to be elsewhere. Requires FFmpegBuild 2.3.0, which this release pins.
- **WebVTT cue settings reach the host after all: `line`, `position` and `align` arrive as `SubtitleCue.placement`.** 5.26.0 reported them as upstream-blocked, which was a conclusion about the wrong layer. libavcodec's WebVTT decoder really does drop them, and says so as a `@todo` in `webvttdec.c`'s file header, so nothing about the placement is in the ASS event line it synthesises. The demuxer keeps them: `libavformat/webvttdec.c` attaches the verbatim settings string to every packet as `AV_PKT_DATA_WEBVTT_SETTINGS`, and `matroskadec.c` propagates the same side data for WebVTT in Matroska. Both subtitle decoders now read it, and the packet store carries the string through a rebuild, since side data does not live in the payload and a stored packet would otherwise lose the placement a freshly demuxed one has. A percentage `line` becomes an anchor point plus the alignment row, anchored to the frame edge it is nearer (the spec's default line alignment would pin the box top at `line:90%` and hang a two-line cue off the frame); a `line` number keeps only the half of the frame it names, because line boxes need a rendered line height the engine does not have. An ASS `\an` or `\pos` still wins, since that came from the payload itself. `size` and `vertical` have no equivalent in the placement model and are ignored, and a `position` without a `line` keeps only the alignment column, because an anchor point needs both axes.

### Fixed

- **Teletext captions keep their vertical placement on pages libzvbi does not flag as subtitle pages.** `gen_sub_ass` derives the vertical anchor from the grid row itself and emits it as `{\anN}`, which the engine has read since 5.26.0, but that whole block sits behind `is_subtitle_page`. That flag comes from the row-0 page header (NEWSFLASH clear, SUBTITLE set, SUPPRESS_HEADER set), and when a broadcaster does not set all three, or the header has not been seen yet, the else path writes the whole page instead: one `" \N"` per grid row with the empty ones included, no `\an`, no per-row trim. The ordinal of the first non-blank row is then the only carrier of the position, and the edge trim was removing it before anything could read it. That ordinal now feeds libzvbi's own third-of-the-page formula rather than an invented scale, so a caption the broadcaster moved to the top of frame to clear a lower-third graphic stays there. Deliberately coarse: three bands is what the source encodes, and mapping each row to its own offset makes consecutive cues of different heights sit at different heights, which reads as a blink. It never overrides an `\an` that arrived, including `{\an2}`, which is explicitly bottom and produces exactly the empty derived output that "no information" would. Reported by tresby (#233).
- **A styled cue trims the same whitespace an unstyled one does.** The plain path trimmed with `.whitespacesAndNewlines`, the styled path tested for a literal space, tab or newline, so a Unicode space (U+00A0 among them) survived on a styled cue and not on an unstyled one carrying the same text. Teletext cannot produce one, since libzvbi maps U+00A0 to a space and writes it as `\h`, but SRT, WebVTT and ASS payloads can.
- **A blank teletext row that a colour change split into its own run folds like any other.** The #107 interior blank-line fold worked per run plus one run boundary, which misses the shape the source produces most easily: the padding of an otherwise empty row carries the spacing attribute that changes colour, so the blank row lands in a whitespace-only run of its own and breaks the chain between the two text rows. The fold now runs on the flattened sequence and re-splits along the original run boundaries, so run structure cannot hide a blank row from it.

## [5.26.0] - 2026-07-28

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.26.0))

### Added

- **Text subtitle styling reaches the host instead of being stripped: bold, italic, underline, strikeout, colour, font face and size, plus the placement a cue asks for.** `SubtitleTextRun` gained `isBold`, `isItalic`, `isUnderlined`, `isStruckThrough`, `fontName` and `fontSize` alongside the colour it already carried, and `SubtitleCue` gained `placement` (`SubtitleTextPlacement`: an ASS numpad alignment and an optional anchor normalized to [0, 1] the same way `SubtitleImage.position` is). Both additions are source-compatible: the new initializer parameters are defaulted, so existing call sites are untouched. This needed no per-format parsing, because libavcodec converts every text subtitle format into an ASS event line before the engine sees it and the markup was arriving on `AVSubtitleRect.ass` the whole time. SRT goes through `ff_htmlmarkup_to_ass`, which turns `<b>/<i>/<u>/<s>` into `{\b1}/{\i1}/{\u1}/{\s1}`, `<font color=>` into `{\c&HBBGGRR&}`, `<font size=>` into `{\fs}` and `<font face=>` into `{\fn}`; WebVTT maps its own inline tags to the same overrides; dvb_teletext already decoded with `txt_format=ass`, which is why its colours alone survived. What discarded the rest was on this side: `cleanASSBody` stripped every `{...}` block with a regex, and the colour parser handled `\c`/`\1c` and documented that it ignored everything else. That parser is now a full override parser, so SRT, WebVTT, teletext and ASS all light up through one code path, and the teletext positioning that was arriving and being dropped comes with it. Lookalike tags are left alone rather than half-parsed (`\be` and `\bord` are not `\b`, `\iclip` is not `\i`, `\shad` is not `\s`, `\fscx` and `\fsp` are not `\fs`), `\r` resets the accumulated state, and `\an`/`\pos` are lifted out to the cue instead of splitting a run. `\pos` is normalized against the play resolution the line actually uses: a real ASS script's declared `PlayResX/Y` when its header provides one, otherwise libavcodec's 384x288 default, which is what the synthesised lines use. No option gates any of this. An unstyled cue still arrives as `.text` with the same string as before, so a host that only handles that case sees no change, and `.richText` was already a case every subtitle-rendering host had to handle for teletext.
- **The software-path PiP compositor renders that styling instead of flattening it.** It previously reduced a rich-text cue to `runs.map(\.text).joined()` and drew every cue in one white font stacked from the bottom, so styling would have stopped at the PiP window. It now builds a per-run attributed line (per-run colour, font face, ASS-relative size, real CoreText bold and italic traits, underline, and a manually drawn rule for strikeout, which CoreText has no attribute for) and honours a cue's placement, mapping the ASS numpad alignment to a corner inset by the layout margin, or anchoring the block on an explicit `\pos`. Cues without placement keep the existing bottom-up stack.

### Notes

- WebVTT cue settings (`line`, `position`, `align`, `size`, `vertical`) still do not arrive: libavcodec does not convert them, as `webvttdec.c` states in its own file header. WebVTT bold, italic and underline work; WebVTT positioning needs an upstream change. SRT positioning arrives only when the demuxer supplies `AV_PKT_DATA_SUBTITLE_POSITION` side data, which most `.srt` files do not carry, though a leading `{\anN}` in the text survives libavcodec's conversion.

## [5.25.2] - 2026-07-28

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.25.2))

### Fixed

- **The native subtitle readers anchor their positioning seek on the subtitle axis too.** Same defect as #234 reached from the other direction, and not part of that regression: these readers seek before they set their discard flags, so at seek time every stream is still `AVDISCARD_DEFAULT`, every stream collects `av_find_default_stream_index`'s +200 for `discard != AVDISCARD_ALL`, and video takes the reference on its own +75. There was never an accidental subtitle anchor here to lose, so this predates #230 entirely, but the consequence is the one #234 describes: on Matroska the seek lands in the cluster holding the last video keyframe, and a cue that starts further back is behind the read head before the first packet arrives. These readers feed the native WebVTT renditions, so what went missing was the line that should be on screen where a seek lands. The anchor is now the lowest routed subtitle stream, and the `native subtitle readers started` line carries `anchor=<index>`. A whole-program read (Sodalite#32) starts at 0 and is unaffected either way.
- **Subtitle packets sharing a PTS are all retained instead of overwriting one another.** Insertion into the packet store treated the timestamp as a unique key, so a packet landing on an already-occupied PTS replaced the entry sitting there. The premise was that a repeated PTS could only mean the pump and the forward prefetcher re-harvesting the same packet (#151), which is a real overlap and does need collapsing, but it is not the only way two packets share a timestamp. ASS/SSA authors overlapping lines on identical Start/End as a matter of course, and a karaoke or layered-style track emits a whole burst of distinct Dialogue events on one: the #56 measurement of a real track found 1534 packets on exactly pts=5.207000. Every member of such a burst but the last was discarded on write, so a heavily styled track reached the renderer with most of its events missing. That is what the report measured from a host wrapper, 245 processed events where the track carries 2054 in the same range, a count that tracked the 268 distinct timestamp pairs rather than the events themselves. A re-harvest is byte-identical to what it duplicates, and that, rather than the bare timestamp match, is the signature the collapse now tests. Anything else joins the run at its end, so a shared timestamp reaches the drainer in harvest order and overlapping lines layer in the order they were authored instead of reversed. The insert position is now found by binary search rather than scanned from the front, which cost little while a burst collapsed to a single entry and costs real time now that it does not: the scan made one append linear in retained packets and a session's harvest quadratic. Reported and fixed by fivepandasna (#235).

## [5.25.1] - 2026-07-28

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.25.1))

### Fixed

- **The subtitle forward prefetcher positions on the subtitle axis explicitly, so a seek landing several keyframes behind the destination is delivered again.** 5.23.11 added a pacing stream at `AVDISCARD_NONKEY` (#230) to give the reader a read-position control point between sparse cues, and that flag silently moved the seek. The reader positions with `avformat_seek_file(ctx, -1, ...)`, and a -1 stream index leaves the reference stream to `av_find_default_stream_index`, whose score awards +200 to any stream with `discard != AVDISCARD_ALL`. Until 5.23.10 the subtitle stream was the only stream not fully discarded and therefore won that vote, 200 to 75, by accident rather than by intent: the target was measured on the subtitle axis and the seek landed on the last cue at or before it. `AVDISCARD_NONKEY` is not `AVDISCARD_ALL`, so from 5.23.11 the pacing stream collected the same +200 and video outranked it at 275. On Matroska the seek then jumps to the cluster holding the last video keyframe and everything in earlier clusters is never read, so a line that starts well behind the destination, the shape a long cue with a distant clear produces, was gone before the first packet arrived. Nothing downstream could recover it: the landing display set was never decoded, so neither the #143 candidate seed nor the #204 finalize ever saw it. The anchor is now passed explicitly (`seekBounded(to:anchorStreamIndex:timeout:)`), which also converts the target into that stream's own time base, so positioning no longer depends on what else the source happens to deliver. The park from #230 is unchanged. Not reproducible on MP4, which is why the #230 tests did not catch it: `mov_read_seek` re-seeks every stream individually and backwards, while `matroska_read_seek` jumps to one cluster position for all of them. Reported by cmcpherson274 with a bisection across four releases on identical fixture bytes (#234).

## [5.25.0] - 2026-07-28

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.25.0))

### Changed

- **A declared interlaced field order is now verified against decoded frames before it routes a stream to software.** H.264 that declares interlaced carriage takes the software path so the deinterlacer can run, because tvOS AVPlayer does not deinterlace and 1080i broadcast would otherwise comb. On progressive-in-interlaced-carriage (PsF) that detour never deinterlaces anything, and European 25 fps Blu-ray masters are exactly that class, Blu-ray having no 1080p25: interlaced carriage, progressive pictures. The two signals disagree by construction. `h264_parser.c` reports `AV_FIELD_TT` for a frame-coded picture on SEI `pic_struct=3` alone, weighing neither `ct_type` nor how the slices were actually coded, while `h264_slice.c` weighs both and leaves `AV_FRAME_FLAG_INTERLACED` clear on that same picture. Routing consumed the structurally less informed of the two, so those titles gave up hardware decode, and the power and thermal headroom that goes with it, for a filter that never built a graph. `InterlaceProbe` now decodes a short sample first and applies the exact predicate that engages the deinterlacer, so it never has to judge content: `SoftwareVideoDecoder` engages on that frame flag and on nothing else, so a sample in which the flag never appears proves the detour would be a no-op and the native path renders the same frames with hardware decode. Only a clean sample overrules the declaration, an inconclusive one keeps the previous routing, and a flagged frame ends the sample at once, so genuinely interlaced material pays a frame or two of decode rather than a full sample (29 ms against 104 ms measured on 1920x1080). Seekable VOD only: the sample moves the read position of the demuxer the session reuses, and live 1080i broadcast, the case the rule exists for, is neither seekable nor mis-declared. Reported by rrgomes (#232).

## [5.24.0] - 2026-07-28

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.24.0))

### Changed

- **The persistent reader now requests a bounded range at a time instead of the rest of the file.** 5.23.12 bounded the resident window by ending the connection once it passed 48 MB, which caught the damage but left the cause: the reader asked for `bytes=X-`, the entire remainder of the source, and then tried to regulate the resulting flow by suspending the URLSession task, which CFNetwork treats as advisory. It now asks for 32 MB and re-requests at the frontier once the consumer drains below the 8 MB low water, so the resident window is bounded by construction (low water plus one range, 40 MB) rather than by reaction, and no delivered byte is discarded or re-fetched at a boundary. The refill is issued from the low-water crossing rather than from an empty window, so a range boundary does not become a stall. A full range delivery is recognised as a planned end and takes its own path: no backoff, no unproductive-reconnect charge, no `.reconnecting` phase and no `lastUnplannedReconnectAt`, because nothing failed and spending the give-up budget on range boundaries would kill the reader on a healthy link. All persistent connections now share one `URLSession` with a per-task delegate, the pattern the chunk path has used since the task-pool leak was fixed, so a range boundary is not a TLS handshake; releasing a connection is `task.cancel()` rather than session teardown. Live sources and any source whose total size is not yet resolved keep the open-ended form. Measured against a real 52.7 GB 4K HEVC remux over a link shaped to 1.46x media rate, the band where the defect actually appears: post-suspend delivery 29-124 MB to zero, cap events 8 to zero, malloc 142-201 MB to 92-151 MB, window peak 51 MB to 21 MB, with playback, subtitle counts and stall counts unchanged. Keep-Alive verified from the server side, 90 range requests served over 3 connections. The 48 MB cap and the task suspend both stay in place as a net that should now never engage, so a firing cap is a signal rather than the normal ceiling.

## [5.23.12] - 2026-07-28

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.12))

### Fixed

- **A source served over a link only moderately faster than the content no longer grows the reader's window without bound.** The persistent reader applies backpressure by suspending the URLSession task above a 16 MB high water, and `suspend()` is advisory: CFNetwork keeps draining the socket and delivering to the delegate. Whether that matters depends on the link, which is why it went unseen. Against a fast origin the socket buffer fills, TCP throttles the sender, and the suspend is never asked to hold anything, so every measurement looks correct, including this project's own regression test for the mechanism. Against an origin delivering a moderate multiple of media rate the socket never fills and every byte is accepted while the task is flagged suspended: measured at 911 MB post-suspend on one reader with the window climbing linearly, and over 3 GB across both readers on a real 4K remux, taking the host machine down. The resident window is now bounded at 48 MB, three times the high water, past which the connection is ended deliberately and re-requested at the frontier once the consumer has drained it, so no delivered byte is discarded or re-fetched. The bound is sized against the peak rather than the window, since crossing it is a `Data` realloc that holds both buffers at once; a field capture with an earlier 128 MB bound in place still reached 1003 MB of live allocation with two blocks at 153 and 129 MB. Two readers exist on a subtitled source and both were affected, on the native path as much as the software one: on a direct-play source the native path runs the HLS loopback and demuxes from the origin itself. Healthy sessions sit at 16-21 MB on macOS and tvOS alike and never reach the bound. Reported and field-verified by rrgomes (#220).
- **The malloc census no longer aborts the process it is measuring.** Its recorder runs inside `malloc_zone`'s in-use enumerator with every zone held through `force_lock`, so it must not allocate, and `for i in 0..<Int(count)` iterates a `Range` through `IndexingIterator`'s protocol witness when the call is not specialized. That allocates, which takes the same `os_unfair_lock` recursively, and libplatform aborts with "Trying to recursively lock an os_unfair_lock". Optimized builds specialize the range away and never reach it, so release builds were fine while debug builds died on the first census.

### Added

- **Per-reader window diagnostics in the periodic memory probe.** `pumpWinMB` / `prefWinMB` (resident window), `AheadMB` (undrained forward extent, the quantity the suspend gates on), `Susp` and `PostMB` (bytes the delegate accepted while the task was already flagged suspended) for the playback reader and the subtitle side reader separately, on both the software and native paths. `PostMB` is what separates backpressure that never engaged from backpressure that engaged and was ignored; the suspend flag alone reads identically in the healthy and the failing case.
- **A prefetch gauge in the same line.** `prefetch=` reports the subtitle forward prefetcher's state and, once stopped, why (`eof`, `failed`, `openfail`, `cancelled`), alongside `prefetchLead`, `prefetchHarvested` and `prefetchTbFallback`. The reader works a full lead ahead of the playhead, so it reaches EOF before playback ends and a bare "stopped" state fired on every completed session.
- **`Scripts/throttle-origin.py`**, a range-preserving throttling proxy that puts a chosen link shape in front of a real server, in single-URL or whole-server form, logging per-connection byte totals. Defects that only appear at a moderate multiple of media rate are not reachable by repeating runs on a fast link.

## [5.23.11] - 2026-07-27

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.11))

### Fixed

- **The subtitle side readers now park on how far they have read, not on when the next cue happens to arrive.** The park could only be evaluated from a packet the loop received, and with every non-subtitle stream on `AVDISCARD_ALL` the only packets it received were subtitle packets, so between two cues there was no control point at all and a single `av_read_frame` call walked whatever lay between them. On a dense PGS track that is bounded by the cue spacing; on a sparse track, a long dialogue-free stretch, or a forced-subtitle track with a handful of cues per hour it is not bounded at all, and the reader ran arbitrarily far past the lead edge on a second connection to the origin. One non-subtitle stream now stays deliverable at `AVDISCARD_NONKEY`, which yields one packet per IRAP on video (audio is the fallback, cover art is excluded); those packets are freed unharvested and exist only to place the read on the timeline, by DTS rather than PTS since a video PTS runs ahead of the bytes when the stream carries B-frames. `runNativeSubtitleReaders` had the same defect, having always evaluated its park per delivered packet and simply been starved of deliveries, and takes a pacing stream too; the whole-program reader does not park and so does not take one. Worth knowing for anyone reasoning about side-reader cost: `AVDISCARD_ALL` avoids the byte read in mov, which skips the `avio_seek` and the read outright, but not in Matroska, where `ebml_parse` reads each cluster's blocks off the wire and `matroska_parse_block` only then checks discard. Found by rrgomes while reading the software path for #220. Covered by `Issue230PrefetchReadPositionParkTests`.
- **A subtitle prefetch session that dies on a read error now comes back instead of staying dead for the rest of playback.** The loop left on the first failed read through `try? demuxer.readPacket()`, which cannot tell EOF from an error, so a transport failure on the side reader, a stall that exhausted the read deadline or a reconnect that gave up all ended the session permanently; the only thing that started a new one was a drain-tick jump, meaning a seek or a producer re-anchor, so a viewer who did not seek lost every cue beyond the pump's own forward park with no signal of it beyond an exit line that reported `cancelled=false` for every reason alike. The loop now reports why it stopped, and only a read failure restarts. The restart is bounded twice over: three consecutive failures with nothing harvested between them (backing off one, two, four seconds) end it, a session that harvested cues before breaking is treated as a fresh transport failure and gets a fresh budget, and a total of eight restarts caps a source that fails in a loop after one packet each time. Each attempt re-anchors at the current playhead and takes its own independent reader on a custom source, and exhausting the budget logs what it costs. Found by rrgomes while reading the software path for #220. Covered by `Issue231PrefetchRestartTests`.

## [5.23.10] - 2026-07-27

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.10))

### Fixed

- **A software-decoded title no longer wedges its picture on a decoder that asks to be read first.** `avcodec_send_packet` returning `AVERROR(EAGAIN)` is not a decode error: it means the packet was not consumed because the decoder's output queue is full and has to be drained before more input is accepted, which is legal at any point under frame threading, and the software video decoder runs with `thread_count` at the core count and both threading types enabled. It was handled as any other negative result, so the packet was dropped and the queue left full, and every subsequent send hit the same wall: the picture stopped for good while audio kept playing, until a seek flushed the decoder. The send now drains the receive loop and resends the same packet on EAGAIN, a genuine error drops the packet and logs once per decoder, and the drain runs either way since a dropped packet does not invalidate frames the decoder already holds. Found by rrgomes while reading the software path for #220. Covered by `Issue220SoftwareDecoderDrainTests`.
- **The subtitle forward prefetcher no longer loses its forward park, or its cue timing, to one failed time-base lookup.** The reader memoized its own failure: a stream lookup that returned nothing fell back to `AVRational(0, 1)`, that value went into the per-session cache, and the park guard (`tb.num > 0`) then skipped every subsequent packet on that stream, so the side reader ran the rest of the session with no forward park and pulled from the origin far ahead of the playhead on a second connection. The same value also reached the packet store, where the harvest rate is `num/den`: at zero every cue it harvested would land at second 0. Only usable time bases are cached now, an unusable one drops that single packet and retries on the next, and it logs once per session. Found by rrgomes while reading the software path for #220. Covered by `Issue220PrefetchTimeBaseTests`.

## [5.23.9] - 2026-07-27

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.9))

### Fixed

- **Wireless AirPlay works again, and it now carries subtitles as far as the receiver allows.** Three defects sat on top of each other on that hop. First, the reload that the external-playback observer starts tears down the very AVPlayer item the observer watches, so a transient "external playback ended" arrived mid-reload and cleared the AirPlay flag before the load path read it. The rebuilt session therefore served the loopback again, the receiver re-engaged external playback, and that edge started the next reload: one full session rebuild per turn, forever, with the LAN rewrite never once applied. An edge that lands during a session-preserving reload is now held and reconciled against the live audio route afterwards, the route being the one signal that survives an item teardown. Second, the 5.23.8 rule that keeps a master for its subtitle renditions asked `videoRange != .sdr || effectiveDvMode`, and `effectiveDvMode` is a device capability, so on any DV-capable iPhone or iPad SDR content took the HDR branch and lost its renditions anyway, which made that release a no-op on exactly the hardware it was written for. The decision reads the real `VIDEO-RANGE` now. Third, the reactive master-rejection fallback reloaded the `127.0.0.1` media playlist, which a receiver cannot reach, as did the startup-readiness gate's three reloads; all of them are rewritten onto the LAN address.
- **A receiver that refuses the playlist it was handed no longer parks the picture.** The refusal is silent: no `-11868`, no failed item, the rate flickers to `playing` for a single tick so even `hasEverPlayed` latches, and the clock then never moves while AVKit shows its "not playable on this display" sign. Five seconds without a segment fetched on a master handed to a receiver now reloads the LAN media playlist, and that receiver is remembered by route UID for the rest of the process, so the cost is one delayed start rather than a stall on every title. Progress is the only available signal, since the refusal produces no error at all, and the discriminator against a merely paused session is the server's own account: a refusing receiver asks for playlists and never for a segment.

### Notes

- **Whether HDR and Dolby Vision carry their subtitles over AirPlay is the receiver's call.** With an Apple TV's video format fixed to 4K Dolby Vision, the DV master is accepted and its subtitle renditions play. With the format at 4K SDR it is refused, and Match Dynamic Range does not change that: the setting switches only when tvOS decides the content warrants it, which it never does for AirPlay content. Nothing in the manifest moves that decision, tested against a parked receiver: dropping the DV `SUPPLEMENTAL-CODECS`, clamping the declared `BANDWIDTH`, omitting `RESOLUTION` and declaring `HDCP-LEVEL=TYPE-1` all left it refusing, and declaring the range as SDR was disproven in #98. The engine therefore offers the master, falls back when it is refused, and reports the outcome through `nativeSubtitleRenditionsServed`. Offering it a second time, to exploit the output switch the first attempt triggers on such a receiver, was tried on device and only doubled the wait before the picture appeared. For subtitles on HDR content over AirPlay, the receiver's video format has to be fixed to HDR or Dolby Vision.

## [5.23.8] - 2026-07-27

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.8))

### Fixed

- **Native subtitles now reach a wireless AirPlay receiver instead of being dropped on the way there.** A `SUBTITLES` rendition can only be declared in a master playlist, but the AirPlay rewrite that moves the loopback onto the device's LAN IP also forced the media playlist for every source, so the receiver was handed a manifest with no `EXT-X-MEDIA` tags: `setNativeSubtitleSelected(track:)` had no legible group to select against, succeeded, and changed nothing. The blanket downgrade came from a real constraint that is narrower than the rule built on it, namely that AVPlayer rejects an HDR or Dolby Vision master on a receiver that is not in HDR or DV mode and will not switch by itself. An SDR variant is routing-safe on any receiver, so it now keeps its master and its renditions travel; the master's rendition URIs are relative and resolve against the LAN base with no further work. HDR and DV sources keep the media downgrade, because an SDR-signalled master over HDR content does not fool the compatibility gate either (it reads the real `colr` and codec, not the manifest string), and `nativeSubtitleRenditionsServed` now reports that honestly on the AirPlay hop rather than describing the local session, so a host can tell the user their subtitles will not travel to this route. The reactive master-rejection fallback also rewrites onto the LAN IP now: it previously reloaded the `127.0.0.1` media playlist, which a receiver cannot reach. Reported by thatcube. Covered by `AirPlayPlaylistDecisionTests`.

## [5.23.7] - 2026-07-26

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.7))

### Fixed

- **A seek no longer makes the reported buffer frontier claim a lead the size of the seek distance.** For a tick or two after a far seek, `clock.bufferedPosition` reported the band at the seek destination as if it sat ahead of the position the seek had left, so a host drawing a buffer bar from it saw a lead of tens of minutes over a playhead with nothing resident ahead of it, corrected only once the clock landed. The frontier walk anchors at `max(playhead, consumer fetch target)`, and that anchor is sound because everything below the fetch target has been handed to the consumer and sits in its own buffer, but only inside an uninterrupted fetch sequence: AVPlayer fetches no further ahead than its buffer reaches, which is what keeps the distance between the playhead and the target bounded during normal playback. A seek removes that bound, and because the consumer needs the data in order to seek, its fetch at the destination lands before `currentTime()` reports the new position, so the walk ran through the freshly produced band there and measured it against the old playhead. The cache now tracks the consumer's current fetch sequence, and outside it the walk anchors on the playhead, which reports the band genuinely reachable from there or nothing when the playhead's own segment is gone. A backward refetch of the Continuous-Audio handover and its return to the fetch front stay inside the sequence, so the whole-source prefetch case that the anchor was introduced for is unaffected. What remains is bounded by the backward window rather than by the seek distance: a scrub shorter than that window stays inside the sequence and can still anchor on the previous target for a tick. Playback was never affected, only the published figure. Covered by `Issue207FrontierAnchorTests`.

## [5.23.6] - 2026-07-26

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.6))

### Fixed

- **A FLAC source whose `STREAMINFO` declares an illegal `min_blocksize` plays instead of failing to open.** Such a source died on the first segment with `AVFoundationErrorDomain -11829 "Cannot Open"` (underlying `CoreMediaErrorDomain -12848`) while playing fine in QuickTime, so a host saw a codec it fully supports refuse to start. The field must be at least 16 per the FLAC specification, but 0 occurs in the wild: an MKV to MP4 remux copies the source `CodecPrivate` verbatim, and encoders that never rewrite `STREAMINFO` after a streaming pass leave it zeroed. libavcodec's decoder ignores the field, so such a source demuxes and probes cleanly everywhere, which is exactly why nothing upstream of the muxer noticed; CoreMedia validates it and rejects the entire audio sample description. Stream-copy hands the source extradata straight to movenc, which serialises it into `dfLa` byte for byte, so the defect reached every segment of the session rather than degrading one. An illegal `min_blocksize` is now clamped up to `max_blocksize`, the only blocksize the container actually attests to, with every other `STREAMINFO` byte left untouched, md5 and `total_samples` included. When `max_blocksize` is illegal too there is nothing honest to clamp to, so the extradata passes through unchanged rather than carrying an invented value. The clamp sits on the single path shared by the session muxer and the stream-copy pre-flight probe, so the probe cannot pass while the real muxer emits a box CoreMedia rejects. Covered by `Issue221FLACStreamInfoTests`.

## [5.23.5] - 2026-07-26

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.5))

### Fixed

- **An E-AC-3 source whose first segment carries no audio packet plays instead of wedging the muxer.** Such a source (audio blocks sitting behind seconds of video in file order, common in WEB-DL remuxes) never produced a frame: the first segment cut failed with -22 "Cannot write moov atom before EAC3 packets parsed", the pump ended, the VOD revive rebuilt the identical configuration twice more, and the session was abandoned as "not muxable", so a host fell back to a server transcode of a file it should have played untouched. movenc builds the `ec-3` sample entry's `dec3` box in `handle_eac3`, that is only from a PARSED bitstream frame, never from codecpar or extradata, so `+delay_moov` alone cannot cover a first fragment that holds video only. `flushPendingFragment` already refused such a flush; the cut did not, and its only "not now" signal was a nil return, which the producer correctly reads as a fatal wedge. A cut now has a third outcome, distinct from success and failure: nothing is written, the muxer stays intact, and the pump scans forward (bounded) for one real audio frame and exits with it. The session keeps that frame and rebuilds, and every muxer from then on muxes it at init, which writes moov with a genuine `dec3`, and then discards the primed fragment's bytes. The delivered segment is therefore exactly what was planned, with no out-of-place audio sample and no disjoint track ranges, and the E-AC-3 stream-copy is preserved, Atmos included, rather than being downgraded to the FLAC bridge. Bridging would not have been a fix in any case: the E-AC-3 bridge wedges identically, because its encoder output is also E-AC-3. A source whose audio never arrives inside the scan bounds falls through to the existing recovery.
- **A teardown on a muxer that never received an audio packet stops logging failed moov writes.** `finalize()` gained the same precondition as the cut, so a muxer that cannot write moov closes quietly instead of emitting two more -22s for a moov it was never able to produce.

## [5.23.4] - 2026-07-26

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.4))

### Fixed

- **The reported buffer frontier no longer collapses to the playhead under an opt-in whole-source prefetch.** `clock.bufferedPosition` fell back to exactly the playhead a few minutes into a session and stayed there for the rest of it, so a host drawing a buffer bar from it watched the bar shrink to nothing while a quarter-hour of content sat resident on disk. The cause was an anchor mismatch, not byte accounting: the frontier walk started at the playhead's segment, while the cache's eviction window is anchored on the consumer's fetch target (`lo = target - backwardWindow`). AVPlayer's fetch target runs around 120 s ahead of the playhead, so the playhead's own segment falls below the retained low end and is an evictable extra. Only an opt-in prefetch ever reaches the retention budget, so only there does the eviction of those extras actually run, which is why a whole-source window surfaced a bug the historical 10-segment window never could: the walk began on a hole and reported nothing cached ahead on every tick. The walk now anchors at `max(playhead, fetch target)`, which is sound rather than merely optimistic, because a segment is only ever declared as the target from the segment-serve path, so everything below it has been handed to the consumer and sits in its own buffer. Simply skipping the leading hole would have failed in the opposite and more dangerous direction: after a backward seek the band above the new position survives, and a walk that skipped the hole would report it as buffered when almost nothing is available where playback actually is. Playback was never affected, nothing was missing, and the union of the consumer's buffer and the cache stayed contiguous throughout; only the published figure was wrong.

### Changed

- **`clock.bufferedPosition`'s contract is stated the same way everywhere.** It is the end of the contiguous *safe* range ahead of the playhead: on the native path what AVPlayer already holds plus the contiguous disk cache band above it, which is what grows with the network buffer setting. The documentation had drifted, describing the frontier as AVPlayer's `loadedTimeRanges` span in one place (superseded in 5.0.0, when the frontier moved to the disk cache read-ahead) and as the disk read-ahead alone in another. No behaviour change beyond the fix above, which also removes an under-report during the first seconds of a session before the cache has built.

## [5.23.3] - 2026-07-25

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.3))

### Fixed

- **HEVC sources whose parameter sets live in-band no longer freeze at 00:00.** A source authored with in-band VPS/SPS/PPS ships an `hvcC` that is just the 23-byte header with `numOfArrays = 0`; the parameter sets travel with the packets instead. That is what `MP4Box ...:xps_inband` and the widely used Dolby Vision MP4 authoring recipes produce, and it is how Dolby's own Profile 8.1 reference asset is built. The normalizer that recovers those parameter sets and rebuilds the record scanned packets from whatever cursor the cue prewarm and the segment-plan pass had left behind, so on a real film (263 s, IRAPs every 2 s) it read 16 mid-GOP packets, found nothing, and let the muxer emit an *empty* `hvcC` box, an init segment MP4Box rejects as an invalid ISO file. AVPlayer accepts the master, fetches the media, fills the entire forward window, and never renders a frame: `CoreMediaErrorDomain -19601`, which is not one of the codes the master-to-media fallback reacts to, so nothing recovers the session. The scan now rewinds to the head first (in-band parameter sets are guaranteed at the first IRAP but only recur once per GOP after it) and counts its budget in video packets, so a film's audio and subtitle tracks cannot exhaust it before the first video packet arrives. Live, forward-only feeds keep scanning from the live cursor. The failure path now logs what it saw. Covered by `InBandParameterSetRebuildTests` against a new `hev1-inband-xps.mp4` fixture.
- **The same sources are no longer force-routed to the software decoder.** `VTCapabilityProbe.canHardwareDecode` builds a format description from the `avcC` / `hvcC` and asks VideoToolbox for a hardware session. A record with no parameter sets still parses, so the description is created and only the session create fails, with `-4`, because there is no SPS to configure a decoder from. That says nothing about hardware support, but the probe read it as "no hardware decoder" and sent every such source to `SoftwarePlaybackHost` on all platforms, Apple Silicon included, at a real CPU cost. The probe's other unclassifiable cases (no extradata, Annex-B extradata, format-description build failure) already kept the native path; a record that is present but carries nothing to judge now does too.
- **The derived HEVC `CODECS` string declared the wrong profile-compatibility flags.** RFC 6381 / ISO 14496-15 Annex E write `general_profile_compatibility_flags` in reverse bit order. Trimming trailing zeroes off the stored value coincides with that only for nibble-palindromic values such as `0x60000000`; a real Main10 record stores `0x20000000` and must print `hvc1.2.4...`, matching MP4Box and Dolby's own reference manifests, where the engine printed `hvc1.2.2...`. Since plain HEVC is routed through a master so tvOS gets codec signaling, and the declaration is checked against the init segment on device, every 10-bit non-DV source was shipping a master that misdescribed its own bitstream.

## [5.23.2] - 2026-07-25

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.2))

### Fixed

- **A VOD seek on a slow source no longer reverts the clock to the pre-seek position and flaps the transport.** On a high-latency source (Dolby Vision over SMB) a seek can miss its deadline while the producer is still genuinely working. The deadline recovery then reverted the reported clock to the frozen pre-seek position and reconciled the transport, which on the device is the reported failure: the scrubber visibly jumps back to the old spot and the session parks flapping paused↔playing for ~40 s while the orphaned old-position segment drains. Four changes: (1) the deadline now extends while the producer is demonstrably serving the target — measured as media buffered *at the seek target*, which the old-playhead buffer metric structurally cannot see, and required to be both above a floor and still **growing** between windows so a producer that served a few seconds and then died cannot buy the whole budget. A target the producer's march cannot reach (AE#141) is never granted an extension; (2) the fallthrough holds the clock at the target, re-anchors the producer there once, re-issues the seek so AVPlayer abandons the old-position buffer, and waits a bounded number of windows, reconciling *forward* to the target and never back; (3) a landing that overshoots forward past the target is accepted as complete instead of triggering a backward-yank re-seek on an already-playing item; (4) the wait path edge-detects the landing at AVPlayer's own ~100 ms observer cadence, so the host's loading state clears when playback actually resumes rather than up to a full window later (which left a spinner over already-playing video). Budget is bounded throughout: at most 4 deadline extensions, one re-anchor, and 4 post-re-anchor waits — so `await seek(to:)` stays suspended for at most ~44 s on a source that keeps progressing and never lands — before a terminal give-up that holds the clock at the target rather than reverting, and reports `.rebuffering`/`.stalled` rather than remaining `.seeking`. Live, software and audio-host paths are untouched. Contributed by Brandon Moore (#216), with follow-up hardening on three edges the new wait windows opened: the loop now stands down when the `$renderedTime` sink finalized the same seek underneath it (the sink accepts a landing within ±5 s of the target, the loop's poll wants ±0.75 s, so a landing a few seconds short would otherwise have been re-anchored and re-seeked backward onto an item already reported as playing); a *near* backward seek no longer counts the abandoned playhead's own forward buffer as media served at the target, which the 30 s measurement window alone only kept clear of a far one; and a cancelled calling task terminates on the give-up contract instead of spending all ten windows in a single runloop turn and restarting the producer on the way through. Covered by `RecoverySeekTargetTests`.

## [5.23.1] - 2026-07-25

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.1))

### Fixed

- **The `deactivatesAudioSessionOnStop` release no longer blocks the teardown.** `setActive(false)` is an XPC round trip to mediaserverd, and on an E-AC-3 / Atmos MAT passthrough route the sink renegotiates the HDMI link inside that call: measured at roughly half a second on an Apple TV 4K feeding an AVR, against a few milliseconds for the same call on a 5.1 route. Called inline from `stopInternal` that was half a second of frozen UI on every stop, because the host's dismiss cannot start until `stop()` returns (5.1 content dismissed instantly, Atmos content hung). The release now runs off the main actor just after the teardown, the same treatment `setCategory` got in #114, guarded by the load generation so a `load()` that follows a stop cancels a release that has not run yet rather than losing its session to it. Hosts that leave the flag at its default `false` are unaffected.

## [5.23.0] - 2026-07-25

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.23.0))

### Added

- **`AetherEngine.deactivatesAudioSessionOnStop` (default `false`): optionally release the shared `AVAudioSession` on final teardown.** On an E-AC-3 / Atmos BITSTREAM PASSTHROUGH route the HDMI sink keeps its own decode ring, and while the session stays active it can keep looping the last MAT frame after the player is released — audio stutters on after leaving playback, and persists even off-screen. Opting in deactivates the session (with `.notifyOthersOnDeactivation`) once playback is torn down for good, which closes that ring. It is off by default because the native path deliberately never *activates* the session (AVKit does, per playback, #24), so deactivating one the host app owns must be the host's decision — an app playing its own audio (UI sounds, TTS, `AVAudioEngine`, a background music player) would otherwise have its session torn out from under it. Only a genuine final teardown honours it: `stop(resetDisplayCriteria: true)`, never a native→native reload, a native→audio/software handoff, or a live retune. `stop(resetDisplayCriteria:finalTeardown:)` lets a host that keeps display criteria across a stop/load pair still declare a genuine final teardown. An `AVAudioSessionErrorCodeIsBusy` result is logged as the informational diagnostic it is, not retried: per `AVAudioSession.h` the session is deactivated regardless and the code only flags that I/O was still running (and iOS/tvOS 26 stopped returning it altogether). The release applies to every backend and runs as the last step of the teardown, once the item is unloaded, the `AVPlayer` released and the software / audio outputs stopped: for the renderer paths, which bypass AVKit and activate the session themselves, it is the engine releasing what the engine took. Contributed by Brandon Moore (#215), with follow-up hardening moving the release from the native host to the engine's own teardown so the software and audio paths are covered too. Covered by `AudioSessionTeardownPolicyTests`.

## [5.22.1] - 2026-07-25

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.22.1))

### Fixed

- **`probeDetectingAtmos` now confirms JOC on sources whose audio does not sit at the head of the container.** The pass sets `AVDISCARD_ALL` on every non-target stream so its caps budget the audio rather than the interleave, but it ran straight after the base probe, and `avformat_find_stream_info` leaves its own packets queued inside libavformat. Those come back from `av_read_frame` regardless of the discard hint, so on a remux whose audio starts well past the head the foreign-packet fuse was spent on that queue before a single audio byte arrived and a genuinely Atmos track reported as not-Atmos. The queue is now discarded with a bounded seek to the start before the decode pass, so the discard takes effect from the first read. Measured on Dolby's own Online Delivery Kit JOC signal remuxed with its audio 70 s in: not confirmed before, confirmed off the first audio packet in 3 ms after. A source that cannot seek is no worse off than before. Covered by `AtmosConfirmationJOCTests`, which skips unless the local fixtures are present.

  Worth recording alongside it: with the audio at the head, `find_stream_info` decodes an E-AC-3 frame on its own and `probe(url:)` already reports `isAtmos` correctly, on both MP4 and MKV and even at a 50 KB probe budget. The pre-decode flag is therefore not the coin flip 5.21.0's notes implied. It is reliable exactly until `find_stream_info` stops reaching the audio, which is what a coarse interleave over a slow link does, and that is the case both this fix and `LoadOptions.confirmAtmos` exist for.

## [5.22.0] - 2026-07-25

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.22.0))

### Added

- **`LoadOptions.confirmAtmos`: the session confirms E-AC-3 JOC on its own audio tracks, so `TrackInfo.isAtmos` is an answer rather than a guess.** 5.21.0 made an authoritative check available as `probeDetectingAtmos`, but only as a static one-shot probe: a host wanting an honest Atmos badge during playback had to open the source a second time itself and patch its own copy of the track list. With the flag set, the engine runs the same bounded decode pass (`AtmosDetectionOptions` caps, one E-AC-3 track at a time, on a second handle to the source) and republishes `audioTracks` as tracks confirm, so every surface bound to the published list lights up on its own. It starts only after the session is up and runs at utility priority, so the first frame never waits on it, and it opens at most one extra handle at a time. Every E-AC-3 track is scanned rather than only the playing one, so a track picker stays consistent when the user switches. Confirmations are held in a session ledger keyed to the loaded source and re-applied after every `audioTracks` republish, because the native demuxed-audio path and a disc title switch both swap the whole list and would otherwise drop the flag on the next audio switch. Skipped for live sources, where a second connection to the origin can cost a tuner and the pass would start at the live edge rather than at the playhead, and for forward-only custom readers, which cannot hand out a second cursor. Default `false`: a session that does not opt in is unchanged. Covered by `AtmosConfirmationTests`.

## [5.21.0] - 2026-07-25

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.21.0))

### Added

- **`AetherEngine.probeDetectingAtmos(url:/source:)`: opt-in, authoritative E-AC-3 JOC (Dolby Atmos) detection.** Nothing in libavformat ever sets `AV_PROFILE_EAC3_DDP_ATMOS` (30); even the MP4 `dec3` box reader takes only data rate, channel mode and LFE and drops the complexity index, so the profile appears on `codecpar` only when `avformat_find_stream_info` happened to decode an audio frame on its own. The lightweight `probe(url:)`/`probe(source:)` path therefore reported `TrackInfo.isAtmos` for JOC roughly by chance. The new API opens an E-AC-3 decoder and reads the authoritative post-decode profile, bounded by `AtmosDetectionOptions` (packet, byte and wall-clock caps, default 64 packets / 8 MiB / 2 s) with no video decode, no HLS server and no playback session. Non-target streams are discarded for the pass, so the caps budget the *audio* rather than the interleaved container; without that, a UHD remux's multi-MB video packets exhaust the byte cap before any audio reaches the decoder and a genuinely Atmos track reports as not-Atmos. The scan does not answer off the first decoded frame: `libavcodec/ac3dec.c` assigns the profile per frame and resets it to unknown whenever the JOC flag is absent, so it keeps decoding within the same budget until the JOC profile appears or a cap fires, and a cap reached after real decodes still reports the observation instead of a give-up. Malformed, no-audio and non-EAC3 sources degrade to "not confirmed" rather than throwing, and a track's `isAtmos` is only ever set, never cleared. Scope is E-AC-3 JOC, which is what `TrackInfo.isAtmos` has always meant; TrueHD carrying Atmos is out of scope. `probe(url:)`/`probe(source:)` themselves are unmodified: this is a separate, strictly opt-in entry point for hosts (a details screen, say) that need an authoritative Atmos badge, not a flag on the default probe. Contributed by Brandon Moore (#214), with follow-up hardening in the scan, the option-range handling and the probe enrichment. Covered by `AtmosDetectionOptionsTests` and `AtmosDetectionProbeIntegrationTests`.

## [5.20.8] - 2026-07-25

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.8))

### Fixed

- **Long-running SoftwarePlaybackHost live sessions no longer leak memory into eventual Jetsam termination.** Each of the four dispatch-block loops (demux, reader, feeder, pumpAudio) now drains its autorelease pool on every iteration instead of only at session end, and inner wait/poll loops (paused condition-wait, back-pressure `isReadyForMoreMediaData` spin, live-edge wait) drain their own pools per spin so that temporaries from `Date` bridging and ObjC runtime calls do not accumulate during extended pauses or renderer back-pressure. Each loop ran inside a single GCD work item that never returned for the lifetime of the session, so the thread's autorelease pool was never drained and per-iteration temporaries accrued unbounded while every pool the engine tracks itself (packet ring, segment cache, audio FIFO) stayed flat. On an Apple TV 4K (3rd gen) live session the physical footprint climbed from 174 MB to 451 MB over ten minutes before the fix and holds flat at ~163 MB over thirteen minutes after it. The same drain is applied to `AudioPlaybackHost.runDemuxLoop` for parity, where no leak was measurable. Reported, diagnosed and fixed by Nathan Piper (#205).

## [5.20.7] - 2026-07-24

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.7))

### Added

- **`LoadOptions.forwardBufferSegments` now reaches a whole-source pre-buffer, bounded in bytes instead of segments.** The 150-segment ceiling (~10 min at 4 s) silently capped a host's "buffer without limit" option, so a user who deliberately opted into pre-buffering a film for a flaky WAN still stalled after ~10 min of content. The ceiling is now 2700 (~3 h), a sanity bound that covers a feature film, so hosts can pass `Int.max`; the floor (4) and the nil default (10) are unchanged and 150 still passes through, leaving sessions that do not opt in untouched. Raising the constant alone would have been unsafe: the segment cache never evicts its hard window, so the retention budget bounds only the entries outside it and a whole-film window would have put ~18 GB of 4K HEVC on the volume unchecked, where a failed segment write degrades to a stall. Windows past 150 now count as an explicit opt-in, dropping the budget's 2 GiB default cap while keeping the quarter-of-free-space clamp, and the producer parks once its race-ahead has filled that budget, resuming as the playhead advances. An opt-in prefetch therefore buffers as much of the source as safely fits and then tracks playback. Reported with a ceiling-raise patch by fxndxs (#207, follow-up to #102). Covered by `PrefetchDiskBudgetTests` and the updated `ForwardBufferWindowTests`.

## [5.20.6] - 2026-07-24

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.6))

### Fixed

- **PGS seek landings now publish when the landing line's own zero-object `CLEAR` is the only stored successor in the drain lead window.** The 5.15.2 reconstruction finalizer correctly handled open-ended and far-clear landings, but treated every stored packet after the playhead as a pass-ending successor. A normal authored `CLEAR` trimmed the held landing candidate to its correct end while carrying no cues that could end `admitDuringReconstruction`, so the bounded candidate remained silently withheld. Reconstruction finalization now uses the decoded gate state: a renderable successor already ends the pass while decoding, while a clear-only successor leaves the correctly trimmed candidate ready to publish. Forced cues and end-of-file landings follow the same path. Reported with a controlled clear-position matrix by cmcpherson274 (#204, residual from #143). Covered by `Issue204PGSClearLandingTests` and the existing #143/#146 reconstruction suites.

## [5.20.5] - 2026-07-24

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.5))

### Fixed

- **Live loopback playlists now keep one stable `TARGETDURATION` and matching `HOLD-BACK` for the complete provider lifetime.** The first-manifest gate captured the observed cadence floor once before waiting, while each playlist refresh independently recomputed timing from the latest cadence and visible segment duration. A session could therefore begin with `TARGETDURATION:1` and `HOLD-BACK=3`, then change to `TARGETDURATION:2` and `HOLD-BACK=6` after AVPlayer was already ready with buffered segments, violating the HLS requirement that `TARGETDURATION` remain constant. The provider now owns one timing seal shared by the startup gate and every playlist build. The gate re-reads cadence after each wake until it releases, then seals that decision; later cadence still controls blocking-reload eligibility but cannot mutate the timing tags. Reported with first-versus-later playlist captures by Simpendaal (#209). Covered by `Issue209LiveTargetDurationStabilityTests`.
- **Explicit `.fastZap` sessions now have a bounded first-manifest wait on strict-realtime origins.** The low-latency profile shortened segments and holdback, but the first playlist still waited for the complete `3 x TARGETDURATION` cushion or the 30-second outer fallback. A source arriving at wall-clock speed could therefore exceed the host's video-presence watchdog before AVPlayer received any media playlist. Full holdback remains preferred. Once at least two finalized segments exist, `.fastZap` waits one observed-segment grace clamped to 0.5...2.0 seconds, then may serve a shallow first window. `.standard` retains the full-holdback guarantee. The bounded trade-off can produce one early `-16832` or a short rebuffer while the window deepens. Reported with strict-realtime startup measurements by kskchaitanya1993 (#208). Covered by `Issue208FastZapDegradedStartTests`.

## [5.20.4] - 2026-07-24

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.4))

### Fixed

- **VOD playback now reaches the real end of media when the final Cues-derived segment boundary has no matching runtime keyframe.** The natural forward producer correctly carried the remaining EOF media in the preceding segment, but the playlist still advertised a short final slot that no producer or restart anchor could create. AVPlayer waited forever at that impossible segment seam and eventually failed with -12889. A final plan slot shorter than the ordinary cut target now folds into its predecessor while preserving the complete duration and terminal PTS. The collapsed plan is also the single plan used by engine state, provider construction, initial seek mapping, and producer startup. Isolated across four rounds of exceptionally detailed device traces by rrgomes (#169). Covered by `PlanCollapseShortSegmentsTests`.

## [5.20.3] - 2026-07-24

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.3))

### Fixed

- **The first automatically deinterlaced software session after a process launch now warms the Metal deinterlace pipeline before playback reaches its first video frame.** FFmpeg created the `yadif_videotoolbox` Metal compute pipeline synchronously while processing the first interlaced frame. On a cold process this could delay video for roughly ten seconds while audio had already started; the same-URL reload was fast because the pipeline was then cached. A process-wide detached task now builds and destroys a small real hardware-deinterlace graph when `AetherEngine` initializes. Automatic deinterlacing awaits that shared warm-up before renderer audio activation and software-host creation, while forced software deinterlacing bypasses the wait. Warm-up failure remains nonfatal, so the real session still attempts hardware and retains its CPU fallback. Reported with precise cold-vs-warm timing by Simpendaal (#203). Covered by `Issue203SoftwareColdStartTests` and `DeinterlaceHardwareTests`.

## [5.20.2] - 2026-07-23

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.2))

### Fixed

- **Mid-stream VOD resume and producer restarts now seek directly to the target segment's indexed video IRAP instead of landing at an earlier global sync point.** The segment plan already carried the exact video-stream timestamp, but the restart path converted it to seconds and asked libavformat for an unconstrained global seek. On multi-stream MP4 files that can select a much earlier sync point, forcing the producer to scan and discard a whole GOP before it can write the first segment. On a slow HTTP origin that scan took long enough for startup to fail with zero packets written. For non-disc VOD, the demuxer now seeks on the video stream's native timestamp axis with the target as the lower bound; containers that do not support the precise seek retain the previous global-time fallback. Disc sources also keep the fallback because their segment plans use folded multi-clip timestamps. Reported with decisive slow-origin diagnostics by kskchaitanya1993 (#191). Covered by `Issue191IRAPSeekTests`.

## [5.20.1] - 2026-07-23

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.1))

### Fixed

- **The restart scan-forward gate now opens on keyframe presentation time, so the tail of a B-frame VOD file is producible again instead of starving to EOF.** The gate compared packet dts against a plan-boundary PTS (`segmentPlan[baseIndex].startPts`, a Cues timestamp); under B-frame reorder a keyframe's dts sits a reorder delay below its own pts, so the gate dropped the exact IRAP the restart seeked for, the same defect class the #92 cutter fix removed from segment cutting. Mid-file the next IRAP rescued the miss one GOP late; at the file tail there is no next IRAP, so the unbounded VOD gate dropped every remaining packet to EOF and the pump exited with zero packets written, leaving the final segment unproducible under any anchoring (the 5.19.1 escalation restarted into the same starve). Two further layers: a VOD pump whose gate still starves to EOF (no runtime keyframe at or after the targeted boundary, e.g. tail Cues drift or a mis-flagged tail IRAP) re-anchors production on the segment of the last keyframe the gate dropped (bounded), so the tail content gets produced and end-of-media completes through the 5.16.2 tail-park instead of dying at -12889; and the #35/#169 startup readiness gate's data-wait consults pump liveness, so production that already exited with nothing served fails over immediately instead of riding 8 rounds (24 s) of false hope. Traced across three rounds with exemplary lifecycle logs by rrgomes (#169). Covered by `Issue169GateStarvationTests` and extended `StartupReadinessGateTests`.

## [5.20.0] - 2026-07-23

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.20.0))

### Fixed

- **A #168-rerouted live session that loses its ingest now recovers in-engine instead of cycling through the doomed native mount.** When the loopback ingest died mid-session (a MEDIA-SEQUENCE reset from an encoder restart or looped test pool, a CDN gap outliving the refresh-retry budget, an upstream ENDLIST), the pump exit delegated straight to host retune, and a host that answers by re-tuning the same URL relanded on the native bypass, which deterministically builds no video track for HEVC-in-MPEG-TS carriage, so the session re-ran the whole reroute dance (native mount, ~4 s watchdog grace, reroute, rejoin) roughly every 13 s. Three-layer fix: the ingest playlist tracker treats three consecutive whole-window MEDIA-SEQUENCE regressions as an axis reset and rejoins at the new edge under a discontinuity seam instead of starving the reader into its `ingestStalled` terminal; masters whose video-carriage watchdog fired are remembered (bounded, expiring, `RerouteVerdictMemory`), so any later load of the same URL routes straight onto the live-ingest loopback and skips the doomed mount entirely; and engine-created ingest readers gained an in-session reopen transport (`HLSVideoEngine.CustomSourceReopenFactory`, new public surface, hence the minor bump), so `eof`/`readError` pump exits rebuild a fresh reader through the existing bounded live-reopen machinery and only an exhausted budget surfaces `liveSourceReset` to the host. Host-provided custom readers and demuxed-audio companion sessions keep the immediate host-retune contract. Traced end to end with deep-window field logs by kskchaitanya1993 (#199, split out of #189). Covered by `Issue199RerouteRecoveryTests` and extended `HLSPlaylistTrackerTests`.

## [5.19.1] - 2026-07-22

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.19.1))

### Fixed

- **A VOD session whose producer dies mid-session (tail read error) now recovers instead of parking into -12889.** When the source reader stopped for good near the end of a file (reconnect churn on a slow link), the final segment was never produced and the request for it re-armed a 30 s backpressure wait forever: the forward-wait branch judged "will this arrive?" by index distance to the producer's march front alone, a dead producer freezes that front just below the request, and the restart escalation was additionally vetoed by the dead producer's still-installed base "covering" the index. On top of that, a mid-session `readError` pump exit had no recovery arm at all (only the nothing-ever-produced case surfaced as fatal, #126). Three-layer fix: a bounded event-driven revive rebuilds the producer on a fresh demuxer right at the pump exit; the forward wait is liveness-aware (a finished pump restarts immediately, a silently frozen march escalates after one fully burned wait with zero front progress, an advancing front keeps the full #141/#93 patience); and both proofs bypass the producerCovers veto. VOD only; live keeps its pump watchdogs and reopen machinery. Reported with a decisive trace by rrgomes (#169). Covered by `Issue169DeadProducerEscalationTests`.

## [5.19.0] - 2026-07-22

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.19.0))

### Added

- **`LoadOptions.liveJoinProfile` with a `.fastZap` opt-in for low-latency live joins (IPTV channel zapping).** Raw live MPEG-TS on the native loopback path took 10-18 s to first frame on a strict-real-time origin: the 5.18.5 startup cushion gates the first manifest on `HOLD-BACK = 3 x TARGETDURATION` of content (the RFC 8216bis floor, which cannot be undercut without reintroducing the `-16832` restart loop), and with the fixed ~4 s segment cut target `TARGETDURATION` never fell below 6, so the holdback was always >= 18 s regardless of how short the source GOPs were. `.fastZap` cuts live segments at every keyframe past 0.5 s instead, so segments quantize to the source keyframe cadence, `TARGETDURATION` follows the real GOP length, and the holdback the join waits for shrinks proportionally: a short-GOP 1080p50 IPTV stream on a strict-real-time origin reaches `readyToPlay` in ~2 s instead of ~20 s. The holdback contract itself is unchanged in both profiles, so long-GOP sources degrade to `.standard` behavior automatically and bursty ingest origins keep the observed-cadence `TARGETDURATION` floor (#167). Trade-off, documented on the option: a smaller `TARGETDURATION` tightens AVPlayer's unchanged-playlist patience and live-edge buffer, so mid-stream stalls or bursts rebuffer more readily than under `.standard` (the default, byte-identical to 5.18.7). `aetherctl live` gains `--fast-zap` and `--preroll N` (0 models a strict-real-time origin with no backlog burst) for reproducible A/B join-latency runs. Proposed with field measurements by Simpendaal (#195). Covered by `Issue195FastLiveJoinTests`.

## [5.18.7] - 2026-07-22

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.18.7))

### Fixed

- **HEVC-in-MP4 VOD now plays on Apple TV instead of failing to build a video track.** On tvOS, AVPlayer builds no HEVC track from a bare media playlist; it needs the codec advertised in a master playlist's `EXT-X-STREAM-INF` `CODECS` attribute (H.264 builds without it, and macOS and the Simulator build HEVC media-direct from the init `hvcC`, so neither reproduced it). The loopback now serves HEVC through a master where routing-safe. The plain-HEVC `CODECS` string is also derived from the source `hvcC` per RFC 6381 (e.g. `hvc1.1.6.L93.90`) instead of a hardcoded Main10 declaration, so it matches the init and a strict device no longer rejects the item. Reported by kskchaitanya1993 (#187).
- **Defensive strip of a zero-sample `sdtp` box from the fragmented init.** The pinned FFmpeg never writes this box, but a consumer that links an older FFmpeg the wrong way (a `-force_load`ed framework shadowing the vendored build) emits an `sdtp` describing zero samples into the `empty_moov` init, which Apple TV rejects and macOS tolerates. The engine now removes it from the captured init regardless of which FFmpeg produced the bytes.

## [5.18.6] - 2026-07-22

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.18.6))

### Fixed

- **Remote HLS external WebVTT subtitles now recover when the legible media selection loads after the item is ready.** On the `nativeRemoteHLS` bypass the engine surfaces the item's legible `AVMediaSelectionGroup` as `subtitleTracks`. The discovery loaded that group exactly once, and if `loadMediaSelectionGroup(for: .legible)` returned an empty group at that instant it gave up for the whole session, leaving `subtitleTracks` permanently empty. On macOS 26 the group is populated once the master playlist is parsed (before `readyToPlay`), so the single load caught every rendition; a reporter on macOS 27 beta saw a permanently empty subtitle picker, because on that OS the legible group only fills once the item reaches `readyToPlay` and the one-shot load missed it. The discovery now retries the group load once after `readyToPlay` before giving up, so a late-populating legible group no longer drops the renditions. The fast path is unchanged: a non-empty first load skips the wait. Reported by jihongboo (#154).

## [5.18.5] - 2026-07-22

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.18.5))

### Fixed

- **Long-GOP live played through the loopback no longer restarts inside AVPlayer's own stall-danger zone at startup.** A 4K50 HEVC-in-MPEG-TS stream routed onto the live-ingest loopback (the #168 reroute) cuts keyframe-aligned segments of ~4.8-5.76 s, so the served `EXT-X-TARGETDURATION` is 6. The media playlist advertised no explicit `EXT-X-SERVER-CONTROL:HOLD-BACK`, so AVPlayer fell back to its implicit live-edge holdback of `3 x TARGETDURATION` (~18 s) and tried to begin playback that far behind the live edge, while the fixed two-segment startup cushion built only ~9.6 s of content. AVPlayer's initial seek to edge-minus-holdback therefore landed inside the window's stall-danger region and it spammed `-16832 restarting Ns from end of live playlist; target duration Ts - stall danger`, rebuffering on every channel open until the real-time window naturally deepened past the holdback. The loopback now advertises `HOLD-BACK` explicitly at the RFC 8216bis floor (`3 x TARGETDURATION`, which is also AVPlayer's implicit default made explicit), and the startup gate holds the first manifest until the window carries at least that holdback depth (bounded above by the sliding-window size and the existing startup deadline) so AVPlayer's live-edge seek always lands inside real content. Both the served playlist and the startup cushion derive `TARGETDURATION` through one shared policy, so the depth built can never drift from the holdback advertised. Sources that arrive with a backlog (a Jellyfin transcode, or an upstream live window pulled at I/O speed) satisfy the gate almost immediately; only a strict-real-time origin pays the deepen-the-buffer latency, which is inherent to joining long-GOP live without stalling. Root-caused with field-verified diagnostics by kskchaitanya1993 (#189). Covered by `Issue189LiveEdgeHoldbackTests`.

## [5.18.4] - 2026-07-22

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.18.4))

### Fixed

- **`AetherPlayerSurface` now rebinds its engine on every SwiftUI update, so replacing the `AetherEngine` instance at the same structural position no longer leaves fresh video black over working audio.** The surface bound the engine to its platform view only in `makeUIView`/`makeNSView`; the update path was empty. When a host tears down and recreates its engine at the same position (a retry/reload flow), SwiftUI reuses the platform view and calls only `updateUIView`, so the new engine's `bind(view:)` never ran: its `boundView` stayed nil, the post-load `presentCurrentLayer()` no-oped on the guard, and the reused view kept displaying the previous engine's detached layer. `isReadyForDisplay` read true throughout, because the host's layer reports ready without being attached to any on-screen view. `updateUIView`/`updateNSView` now call `engine.bind(view:)`; steady-state passes are a cheap no-op (`presentCurrentLayer()` re-attaches the same layer and `attach` short-circuits on identical layer), while an engine swap points the new engine at the reused view and re-attaches its layer. Hosts that keyed the surface identity to the engine (`.id(ObjectIdentifier(engine))`) as a workaround no longer need to. Root-caused and reported by rrgomes (#188). Covered by `Issue188SurfaceRebindTests`.

## [5.18.3] - 2026-07-22

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.18.3))

### Fixed

- **HEVC-in-MP4 progressive VOD dispatched to the loopback remux no longer builds a fMP4 init that Apple TV hardware rejects.** libx265 (and other encoders) embed a large user-data `SEI_PREFIX` NAL array in the hvcC config record; the VOD muxer copied the source codec parameters verbatim, so that array reached the `init.mp4` sample description. Apple TV builds the HEVC format description straight from the hvcC parameter-set arrays and rejects a record carrying a non-parameter-set array (`asset.tracks count=0`, `AVFoundationErrorDomain -11829`, underlying `CoreMediaErrorDomain -12848`, before any media fetch); macOS and the tvOS Simulator both tolerate it, so it only surfaced on device. Both 8-bit Main and 10-bit Main10/HDR10 were affected. The HEVC config record is now canonicalized before write_header, keeping only the VPS/SPS/PPS arrays and dropping SEI and any other NAL arrays, so the VOD init matches the canonical form the live MPEG-TS and direct fMP4-HLS paths already emit. HDR10 static metadata (in-band per-IRAP plus the `colr`/`mdcv`/`clli` boxes) and Dolby Vision signaling (`dvcC`/`dvvC`, RPU) are outside the hvcC and unaffected. Reported by kskchaitanya1993 (#187). Covered by `HEVCConfigRecordTests`.

## [5.18.2] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.18.2))

### Fixed

- **Seeks issued while the initial load is still in progress are no longer silently dropped.** `seek(to:)` no-oped for the whole `state == .loading` window (probe, native load, readiness gate, several seconds on slow sources), so hosts rendering the target optimistically watched playback snap back to the pre-seek position. The latest loading-window seek is now stashed in the #127 pre-ready slot, published optimistically to the scrub clock, and replayed when the session settles into a playable state (including autostart paths, where readiness fires while `state` is still `.loading`); a load that dies discards it. Reported by YangHanqing (#178, mechanism 1). Covered by `Issue178LoadingSeekStashTests`.
- **An ordinary seek issued while a recovery re-anchor was pending no longer lands on the recovery position instead of its own target.** Once a seek-deadline reconcile parked an authoritative restart in the coalescer's pending slot (#79), a subsequent user seek's segment-driven restart was dropped outright, and the producer stayed anchored ~10 s+ away from the requested target while the provider's re-fire bookkeeping believed the restart had run. A new user seek now releases the superseded authoritative claim before dispatching the host seek, so its restart takes the pending slot normally; the #79 lock still blocks stale burst-tail scrubs that arrive without a fresh user seek. Reported by YangHanqing (#178, mechanism 2). Covered by `RestartCoalescerTests`.

## [5.18.1] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.18.1))

### Fixed

- **High-bitrate live HLS on the ingest path could rebuffer because the reader could not get ahead of the playhead.** The ingest segment loop awaited each fetch fully before starting the next, so every segment paid a connection + TTFB round-trip with no bytes flowing; on a 4K50 HEVC/TS stream (~13 Mbps) the producer ran below real time (cache stuck at ~5 segments) even on links that can pull much faster. Segment fetches now run through a bounded prefetch pipeline: up to 4 fetches (and AES-128 decrypts) in flight, committed to the FIFO strictly in playlist order, so classification, discontinuity handling, and demuxer pacing are unchanged while the link is saturated. Reported with a field-verified design by kskchaitanya1993 (#177). Covered by `Issue177IngestPrefetchTests`.
- **Live streams delivering just below real time were force-retuned every ~10 s, re-joining behind the live edge and draining the buffer each cycle.** The no-cut watchdog retuned on wall-clock since the last finalized segment alone; a source whose 6 s segment simply has not fully arrived inside the 10 s timeout was classified a cutter wedge although video PTS was still advancing. The wedge classification is now gated on PTS advance: when video advanced at least 2 s in the window, the watchdog holds and re-arms (bounded to 6 consecutive holds) instead of exiting for host retune. A genuine SSAI ad-pod wedge reads at full rate with frozen video PTS and still retunes immediately; the source-starvation classification is unchanged. Reported with a field-verified design by kskchaitanya1993 (#177). Covered by `Issue177NoCutHoldTests`.
- **Anamorphic (SAR != 1:1) content on the software decode path rendered at coded dimensions, collapsing to a thin strip.** The renderer's cached `CMVideoFormatDescription` snapshots the pixel-aspect attachment at creation but its cache key omitted PAR, so whatever the first frame carried was frozen for the whole stream; garbage `AVCodecContext` SARs (1088:1 seen in the field) and per-field oscillation on interlaced content had no gate. The decoder now resolves SAR frame -> codec context -> stream (first sane value wins, both axes gated to 1...256), latches the first non-square SAR per stream, and the renderer keys its format-description cache on PAR. Reported with a field-verified design by kskchaitanya1993 (#177). Covered by `Issue177SARLatchTests`.

## [5.18.0] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.18.0))

### Fixed

- **IPT-only Dolby Vision (HEVC P5, AV1 P10.0) now fails the load with a clear error when it would start on the software path, instead of playing with a green/purple cast.** Follow-up to 5.17.5: AV1 Profile 10.0 (compat 0) has the same IPT-PQ-c2-only signal as HEVC P5, but on devices without hardware AV1 decode (all Apple TVs, M1/M2 Macs, pre-A17 iPhones) it routes to dav1d, and there is no native fallback to prefer (AVPlayer HLS requires HW AV1), so no route can render it color-correctly. The dispatch now consults `VideoRoutingPolicy.softwarePathCannotRepresent` after the final routing decision and fails fast; this also closes HEVC P5's remaining doors into the software path (forward-only sources, test override). P7 / P8.x and AV1 P10.1 / P10.2 / P10.4 stay software-eligible since their base layer decodes with correct color. Part of the #176 cleanup. Covered by `VideoRoutingPolicyTests`.

### Added

- New public error case `AetherEngineError.dolbyVisionUnplayableOnSoftwarePath(profile:)` (hence the minor bump).

## [5.17.5] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.17.5))

### Fixed

- **Dolby Vision Profile 5 misrouted to the software path with a green/purple color shift, even on Apple Silicon.** The #2 second-stage gate probes VideoToolbox with a plain-HEVC format description built from the raw hvcC; for P5 that is not what the native route plays (dvh1 + dvcC, decoded by Apple's DV decoder, #98), and VT rejects the bare P5 hvcC with -12906/-4, so the probe returned a false negative and the fallback routed P5 to the SoftwarePlaybackHost, where libavcodec decodes the IPT-PQ-c2 base layer as YCbCr (the reported cast). P5 has no HDR10/HLG/SDR-compatible base layer, so software is never a correct fallback for it: HEVC streams whose DOVI config says profile 5 now bypass the gate and stay native unconditionally (the VT probe is not even invoked); P7 / P8.x keep the gate since their base layer is standard Main10 that the software path decodes with correct color. Reported by ijuniorfu, triaged by DrHurt (#176). Covered by `VideoRoutingPolicyTests`.

## [5.17.4] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.17.4))

### Fixed

- **`-15410` when the LOCAL segment producer stalls (SSAI cutter wedge) while LL-HLS blocking-reload is latched ON, including a second one right after the stall watchdog's item reload.** Follow-up to the 5.16.0 observed-cadence fix: the cadence policy observes ingest arrivals, which keep flowing while the cutter is wedged, so it cannot see this failure mode. The held `?_HLS_msn=` reload waited on a segment that will never be cut, timed out, and was answered with the unchanged playlist (no requested MSN), which AVPlayer flags as invalid blocking-reload behavior; the item reload against the same zombie server immediately re-armed a second hold. The server now answers an unsatisfiable held blocking reload with a retriable 503 (RFC 8216bis) instead of a spec-invalid unchanged 200, and every live pump exit that delegates to host retune (`segmentStall`, `sourceReplay`, non-URL-reopenable pump deaths) latches the provider production-halted: blocking-reload stops being advertised for the rest of the session (beating the host override), and parked waiters release immediately instead of sleeping out their hold. Reopenable URL exits keep cutting into the same provider and do not latch. Reported by G00380316 (#167 retest). Covered by `LiveProductionHaltTests`.

## [5.17.3] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.17.3))

### Fixed

- **`EXC_RESOURCE` memory-limit crash on the native loopback pipeline: the persistent source reader kept pulling from the origin while the muxer was correctly backpressure-stalled.** The persistent reader applied window backpressure by blocking the URLSession delegate callback until the consumer drained below the 16 MB high-water mark. Blocking the delegate has no flow-control contract: whether the connection stops reading from the socket is a transport implementation detail. Plain HTTP/1.1 happens to park after a few MB of internal buffering, but the TLS/H2 path keeps reading at line rate and buffers the undelivered body in unbounded URLSession-internal allocations; with a realtime consumer that grows at line rate minus playback rate, goes cold, gets compressed, and trips the jetsam limit after minutes (the reporter's memprobe: delivered bytes at playback rate, malloc growing 12x faster, `vmCmp` climbing ~500 MB per 30 s with rss flat, and the network thread the only active thread, mid `SSL_read`). The reader now uses task suspend/resume, the contractual flow control the streaming path already used: delivery never blocks, the task suspends once the window exceeds the high-water mark, and the read loop resumes it when the drain crosses the new 8 MB low-water mark (or before parking in the frontier wait, where a suspended task would never deliver). Every reconnect and teardown path balances a pending suspend before cancel. Reported by Enoch Abiodun (#174). Covered by `Issue174PersistentReadBackpressureTests` against a loopback origin that counts the bytes it actually manages to serve.

## [5.17.2] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.17.2))

### Fixed

- **Matroska `TrackTimestampScale != 1` follows RFC 9559 again (FFmpegBuild 2.2.0): the 5.9.4 clamp is dropped, the warning stays.** Upstream review of our proposed FFmpeg patch ([FFmpeg PR 23852](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/23852)) corrected the #145 premise: RFC 9559 (11.1.3, 11.2, 5.1.3.5.3) puts Block/SimpleBlock relative timestamps and BlockDuration in Track Ticks, absolute time is `(cluster + rel x TTS) x TimestampScale`, and upstream `matroskadec` implements exactly that. The "hybrid axis" described in the 5.9.4 entry does not exist; the file that motivated it was authored on the segment axis and is invalid per RFC, and the clamp would have mistimed a conformant `TTS != 1` file. Timestamp behavior is now exactly upstream's RFC behavior; the demuxer still warns whenever a track carries `TTS != 1` (the element is deprecated and widely ignored, so such files may be authored against readers that ignore it), which keeps the actual defect reported in #145, the silence, fixed. `Issue145MatroskaTrackTimestampScaleTests` now locks the RFC semantics: a conformant Track Ticks file demuxes at its authored times (the clamp broke exactly this case), and a segment-axis-authored file documents the RFC-scaled rendering as invalid-file behavior.

## [5.17.1] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.17.1))

### Fixed

- **The wireless-AirPlay LAN-swap reload (and the background-return reopen) destroyed host subtitle session state: mid-session `addExternalSubtitleTrack` registrations vanished (the host's menu kept listing ids that no longer existed), the user's explicit audio/subtitle picks (including subtitles explicitly OFF) were overridden by a re-run of preferred-language auto-selection, and `nativeSubtitleReapplyOrdinal` was wiped, so the AirPlay receiver rendered no subtitles at all.** `reloadAtCurrentPosition` now captures a session carryover before the reload: the fresh `load()` seeds the external-track registry from it id-exactly (removal gaps preserved, no id collisions) and before the native rendition table is built, so mid-session external tracks also become WebVTT-rendition-eligible on the reloaded item, exactly the AirPlay/PiP window where the host overlay cannot draw; the explicit audio pick rides `load()`'s existing `audioSourceStreamIndex` override; the previous subtitle selection is re-selected instead of auto-derived; and the native-rendition pick is replayed the way the #65 recovery already does, recomputed against the rebuilt table. A host `setNativeSubtitleRendering` call landing mid-reload (the AirPlay flip triggers the engine reload and the host reaction from the same KVO change) is latched and applied after the restore instead of being misread as a deselect. The audio-switch reload gets the same native-ordinal replay, and an active external track re-arms through its synthetic id there. Reported by dlev02 (#170). Covered by `Issue170SessionCarryoverTests`.

## [5.17.0] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.17.0))

### Added

- **`LoadOptions.nativeRemoteHLSIngestFallback: Bool`** (default `true`) to opt out of the new live remote-HLS ingest reroute described below.
- **`HLSLiveIngestReader(playlistURL:httpHeaders:)`**: the ingest reader now carries custom HTTP headers on every playlist, segment, and AES-key fetch (the companion audio reader inherits them), so header-enforcing IPTV origins (Referer / User-Agent / Authorization, #119) accept the ingest the same way they accept the AVPlayer bypass.

### Fixed

- **A live channel whose master advertises HEVC (`CODECS="hvc1..."`) but delivers MPEG-TS segments stayed black (audio-only) on `nativeRemoteHLS`: AVPlayer never built a video track at all.** Per the HLS Authoring Spec, AVFoundation supports HEVC only in fMP4 carriage; for HEVC-in-TS it reaches `readyToPlay`, builds the audio track, and silently never creates the video track, so there is also no `CMFormatDescription` for the 5.16.1 range detection to read and nothing to program display criteria for. The engine now arms a carriage watchdog at `readyToPlay` on live bypass sessions: it polls `item.tracks` at a 0.5 s cadence for 4 s, takes advertisement evidence from `AVURLAsset.variants` (AVFoundation's already-fetched master parse, so no second origin connect past IPTV tokens / WAFs), and when an advertised video rendition never builds an item track it reroutes the session onto the loopback ingest path, where `HLSLiveIngestReader` remuxes TS to fMP4 and the full display-criteria handshake runs. Audio-only masters (radio channels) and masters without variant evidence disarm without firing; VOD is excluded (the AE#154 reroute target, so no ping-pong); dead origins never reach `readyToPlay` and so never trigger it. Follow-up to #168 after the reporter's 5.16.1 retest log proved the track-build rejection branch. Covered by `RemoteHLSIngestFallbackTests` and `HLSLiveIngestHeaderTests`.

## [5.16.2] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.16.2))

### Fixed

- **A long 4K Dolby Vision loopback-HLS VOD failed to finish at end-of-media: AVPlayer parked a fraction of a second from the end (`WaitingToMinimizeStalls`), never fired `didPlayToEndTime`, and after ~43s died with `CoreMediaErrorDomain -12889`.** The final segment is produced and served fine, but its advertised `#EXTINF` is derived from the container duration (`sourceDurationSeconds`), while the muxer writes the final video sample at EOF with only its one-frame duration. When the container duration overshoots the last real video sample (audio a few frames longer, or a rounded-up MKV `Duration`), the video track underfills the advertised segment by ~0.1s, so the video renderer parks waiting for frames that never existed while `loadedTimeRanges` (audio plus the segment map) reports full buffering. The engine now detects this tail park from its 1 Hz native tick and synthesizes organic end-of-media (playhead within `endOfMediaEpsilonSeconds` of duration, final segment loaded to the end, `WaitingToMinimizeStalls`, playhead frozen for a 3-tick grace), so the session finishes cleanly (`.ended` -> mark-watched / autoplay-next) after ~3s instead of hanging then erroring at ~43s. Reported by rrgomes (Apple TV 4K, tvOS 26, 48-min HEVC Main10 DV Profile 8.1). Covered by `NearEndOfMediaParkTests`.
- **Resuming into the last few seconds of a Dolby Vision title dropped DV: the #35 readiness gate reported "master never produced tracks", reloaded, timed out again, and fell back through the reduced master to the media playlist (HDR10 base, DV dropped).** A tail resume anchors the readiness-gate master on the final segment, still being produced over a slow link, so `awaitStartupReadiness` times out with 0 tracks and no media loaded. The gate (written for the cold DV/HDCP decode failure) misread unstarted production as a decode failure and burned the master fallback chain before it had any segment data to decode. The gate now splits a settle-window timeout by whether any media has loaded: no media means the first segment has not been served yet, so it keeps the DV master and re-awaits, bounded by `maxDataWaitRounds` (~24s of patience, comfortably longer than a slow-link final-segment production); media loaded but still 0 tracks stays the cold-decode park with the reload/fallback chain unchanged. A genuinely wedged producer still falls through once the data-wait budget is spent. Reported by rrgomes. Covered by `StartupReadinessGateTests`.

## [5.16.1] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.16.1))

### Fixed

- **HDR10 / Dolby Vision over `nativeRemoteHLS` presented no video (audio-only, black), and the reported dynamic range was always SDR.** The `nativeRemoteHLS` bypass hands the m3u8 straight to AVPlayer and runs no demux probe, so it never programmed `AVDisplayManager.preferredDisplayCriteria` and never learned the item's dynamic range. On a bare `AVPlayerLayer` an HDR item with the panel in SDR reaches `readyToPlay` and plays audio but presents no video; `videoFormat` also stayed at the `.sdr` default (`appliesPreferredDisplayCriteriaAutomatically` is `AVPlayerViewController`-only and does not exist on the bare `AVPlayer` this path uses). The engine now reads the range back from AVPlayer's parsed video-track `CMFormatDescription` (transfer function plus `dvh1` / `dvhe` sample type) at `readyToPlay` and again at first frame, publishes it into `sourceVideoFormat` / `videoFormat`, and for an HDR range programs the display criteria (Match Dynamic Range plus Match Frame Rate) the same way the loopback path does, with no second connection to the origin. SDR and sole-writer (`suppressDisplayCriteria`) hosts are untouched. Reported on a 4K50 HDR10 HEVC Main10 IPTV channel (Apple TV 4K, tvOS 26). Covered by `RemoteHLSFormatDetectionTests`. Awaiting reporter device retest.

## [5.16.0] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.16.0))

### Added

- **`LoadOptions.liveBlockingReload: Bool?`** to override LL-HLS blocking-reload eligibility for live loopback sessions. `nil` (default) keeps the automatic behavior; `true`/`false` force it regardless of cadence. See the fix below for the auto behavior.

### Fixed

- **Live HLS ingest from a bursty origin looped on `CoreMediaErrorDomain -15410` ("Invalid server blocking reload behavior for low latency"), stalling and self-recovering with a nudge-seek over and over.** LL-HLS blocking-reload eligibility and the local `#EXT-X-TARGETDURATION` floor both derived from `HLSLiveIngestReader.upstreamTargetDuration`, the upstream origin's *self-declared* `#EXT-X-TARGETDURATION`. A relay/budget IPTV origin that advertises a normal target but pushes segments in irregular batches (rather than encoding in disciplined real time) defeated that check: the advertised value looked fine, so the loopback server kept advertising `CAN-BLOCK-RELOAD=YES` and held each `?_HLS_msn=` reload until its batch landed, which AVPlayer treats as a spec violation (`-15410`). The hint was also read once at load and frozen, so it could never reflect how the origin actually behaved. The engine now measures the **observed** inter-segment arrival cadence in the ingest reader (`LiveArrivalCadenceMeter`: the recent-max closed inter-arrival interval, widened by the currently-open gap) and drives both decisions from it on every manifest render (`LiveCadencePolicy`): blocking-reload starts OFF, latches ON only after a sustained window of disciplined cadence, and latches permanently OFF the moment a burst is observed (a monotonic OFF -> ON -> OFF path, since ON/OFF flapping would itself trip `-15410`); the TARGETDURATION floor tracks the monotonic max observed cadence so AVPlayer's 1.5x-target unchanged-playlist patience always covers the real inter-batch gap (no `-12888` regression). Plain-`url:` live with no cadence signal (for example a Jellyfin real-time transcode, which is disciplined) keeps blocking-reload on by default, so mainstream live TV is unaffected; hosts can override either way with the new `LoadOptions.liveBlockingReload`. Reported by a downstream integrator (iPhone 16 Pro Max / iPad 10th generation, HDR10 4K HEVC + EAC3 5.1 bursty ingest). Covered by `LiveCadencePolicyTests`.

## [5.15.5] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.15.5))

### Fixed

- **Unbounded aggregate memory growth in `SubtitlePacketStore` on sources with many embedded subtitle tracks, up to an iOS jetsam kill.** The store capped retained compressed subtitle packets at 32MB *per stream* (`perStreamByteCap`), but the pump tap and the forward prefetcher both harvest *every* embedded subtitle stream into the session store (so a track switch backfills instantly without a side demuxer, #112). Nothing bounded the sum across streams, so a source with many tracks (99 in the field repro, mostly bitmap/PGS, each independently climbing toward its own 32MB ceiling) grew heap allocations toward N x 32MB (~3.2GB); the host's `memprobe` showed `mallocMB` tracking `subTracks` rather than playback time or bytes downloaded, and the process eventually hit the iOS jetsam limit and was killed. The store now enforces an aggregate byte budget (`aggregateByteCap`, 96MB) across all streams in addition to the per-stream cap: the active drain targets (primary + secondary) are protected so a switch back to them still backfills from a full window, and the coldest (least-recently-touched) non-protected streams evict oldest-first once the aggregate budget is exceeded. Total retained bytes are tracked incrementally (O(1) per append) and a monotonic touch counter orders eviction; the engine keeps the protected set in sync with the active subtitle selection on every change and re-asserts it each drain tick. Reported by Enoch Abiodun (iPhone 16 Pro Max / iPad 10th generation, 99-track source). Covered by `Issue166AggregateByteCapTests`.

## [5.15.4] - 2026-07-21

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.15.4))

### Fixed

- **On an FFmpeg build without the configured bridge encoder (for example no `--enable-encoder=eac3`), a bridge-required audio codec played as silent video-only with no cascade to FLAC.** The audio route made a single `AudioBridge` attempt with the configured `audioBridgeMode` (default `.surroundCompat` = EAC3). When that mode's encoder was absent from the build, `AudioBridge.init` threw `.encoderNotFound` and the handler dropped straight to silent video-only, so every bridge-required codec (DTS, TrueHD, MP3, Opus, Vorbis, PCM, MP2, LATM-AAC) came up with no audio and the only signal was one log line. The route now cascades: it tries the configured mode and, only on a missing-encoder error, falls through to the other mode's encoder (EAC3 <-> FLAC) before any video-only fallback, and emits a loud ERROR rather than a quiet info line when no bridge encoder is available. Every other init failure is source-specific and stops immediately without a pointless retry. No behavior change when the configured encoder is present: the first attempt succeeds exactly as before. Also fixes a routing log line that hardcoded "FLAC re-encode" regardless of the configured mode, and a stale doc-comment. Reported and hardware-verified by a downstream integrator (Apple TV 4K, DTS 5.1 and TrueHD Atmos over network, audio plays via the FLAC bridge). Covered by `Issue165BridgeModeCascadeTests`.

## [5.15.3] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.15.3))

### Fixed

- **Scrubbing or seeking a VOD to the very end left the engine reporting `.playing` while AVPlayer sat frozen on the final frame, and `play()` / `togglePlayPause()` could not resume.** A programmatic `seek(to: duration)` never fires `AVPlayerItem.didPlayToEndTime` (that notification is for playback reaching the end on its own), so the seek settled to a phantom `.playing` and, because `AVPlayer.play()` at end-of-media is a no-op, the transport controls stalled with no way to restart. A VOD scrubbed to its final frame now parks at `.paused` (honest, non-terminal, so the scrubber stays live and can scrub back), and `play()` / `togglePlayPause()` rewind to the start before resuming when the playhead is parked at the end. The terminal `.ended` state (organic completion, #63) is deliberately unchanged: it drives the host's end-of-playback handling (mark-watched / autoplay-next / dismiss), so a manual scrub to the end must not trigger it, and a play press racing an end card must not silently restart a finished session. Reported by jihongboo. Covered by `SeekToEndOfMediaTests`.

## [5.15.2] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.15.2))

### Fixed

- **A seek landing on a PGS line with no following subtitle within a minute stayed dark, forced cues included.** The #143 reconstruction pass reshows the seek-landing line by holding it as a candidate and emitting it once the backscan decode reaches the playhead, using the next composition at/after the playhead as the pass-end trigger. A landing whose set is the newest decodable composition in the drain window (the file's last line, or sparse/forced dialogue whose next line sits beyond the 60 s forward lead) has no such trigger, so the candidate stayed held and the overlay dark: tens of seconds on sparse dialogue, forever at end of file. The drain now finalizes a reconstruction pass once it has seeded a candidate and confirmed no successor is stored ahead in the lead window, emitting the landing line (the whole same-start group) immediately. A line the author cleared before the playhead no longer covers it and is not resurrected; landings with a successor in the window are unchanged. Reported by cmcpherson274 (5.9.7 retest of #143). Covered by `Issue143PGSLandingLineTests` and `SubtitleOverlayDrainerTests`.

## [5.15.1] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.15.1))

### Fixed

- **Live MPEG-TS channels routed to the software decoder (interlaced H.264 via #150) played silent.** Once #150 began correctly routing interlaced live streams to the software path, those sessions came up with no audio. The software host resolved its audio track only through `av_find_best_stream`, which returns -1 for a live MPEG-TS AAC stream whose codec parameters the probe left empty (sample rate and channel count zero, because stream analysis stops before the first audio frame is decoded), so no decoder opened and audio packets were dropped (`audioCodecID=none` at session start). The native path already handled this; the software path now mirrors it, falling back to the first audio-type stream on live sources when `av_find_best_stream` finds none, and repairing the AAC parameters to 48 kHz stereo AAC-LC so the decoder opens and channel negotiation is correct (the decoder otherwise recovers rate and channels from the first decoded frame, but not before the session reports zero). VOD keeps its existing stream selection. Reported by digilearn-dev (#133). Covered by `SoftwareLiveAudioResolutionTests`.

## [5.15.0] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.15.0))

### Added

- **Bitmap subtitles (PGS / DVB / DVD, embedded and external .sup) now survive PiP, AirPlay, and wired external displays on the native path.** Bitmap tracks join the native rendition table at load as OCR-fed renditions: while one is selected, a worker decodes its harvested compositions ahead of the playhead (packet-store source, drainer pacing, 5.14.1 end-clamp semantics) and recognizes them on-device (Vision, `.accurate`, track-language hinted) into plain-text cues for the track's WebVTT rendition; the #151 forward-prefetch lead rises to 270 s while armed so AVKit's ~240 s .vtt prefetch burst is served populated. External .sup sidecars fill their store from the selection-time sidecar decode's own image cues (no second fetch). Lossy by design: a failed or empty read drops that line from the rendition, and fullscreen keeps the pixel-accurate bitmap overlay. VOD, master-routed sessions; no API breaks, hosts need only the pin bump.

## [5.14.1] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.14.1))

### Fixed

- **External PGS subtitle files (raw .sup sidecars, e.g. Jellyfin serving external PGS tracks) now load and render.** Two gaps compounded into a silent no-show on every path: FFmpegBuild lacked the `sup` demuxer (fixed in 2.1.3, now pinned), so `avformat_open_input` rejected the file with `AVERROR_INVALIDDATA`; and the sidecar decode loop extracted only text rects, dropping bitmap rects. The loop now routes bitmap rects through the embedded path's `imageForSubtitleRect` into `.image` cues with PGS end semantics (an open composition ends at the next composition event's PTS instead of a flat 5 s fallback). Also fixes the frame compositor's bitmap placement: `SubtitleImage.position` is normalized against its canvas, and the compositor treated it as absolute pixels. Covered by `SidecarPGSDecodeTests` (real .sup fixture, local-only) and the updated `SubtitleFrameCompositorTests`.

## [5.14.0] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.14.0))

### Added

- **Subtitles render inside sample-buffer PiP windows: the software path composites active cues into decoded frames while `pictureInPictureActive`.** The system PiP window renders only the display layer, so host-drawn overlays never reach it; a new `SubtitleFrameCompositor` caches one overlay per cue-set change (text cues in a readable default look via CoreText, bitmap cues width-aligned center-anchored per their PGS/DVB canvas) and GPU-composites it into a pooled buffer of the source pixel format inside the renderer's flush path. Outside PiP nothing changes (fullscreen subtitle drawing stays with the host); any compositing failure passes the original frame through. Covered by `SubtitleFrameCompositorTests` including a synthetic-buffer integration test.

## [5.13.0] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.13.0))

### Added

- **`SoftwarePiPSource`: a published sample-buffer PiP bridge for the software path.** Hosts building system PiP for SW-routed codecs (dav1d AV1/VP9 and friends) need the display layer plus transport answers on the enqueued frames' PTS axis (source axis); both are engine knowledge, so the engine now publishes `softwarePiPSource` (the `currentAVPlayer` analog) carrying the `AVSampleBufferDisplayLayer`, `timeRange()`, `isPaused`, `setPlaying(_:)`, and `skip(by:)`, with AVKit staying host-side. The background policy keeps SW video decoding alive while `pictureInPictureActive` (the window needs frames) instead of dropping to audio-only; without PiP, background behavior is unchanged. Covered by `SoftwarePiPSourceTests` and the extended `BackgroundKeepaliveTests`.

## [5.12.0] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.12.0))

### Added

- **A native->native load while a PiP window is active now hands the AVPlayerItem over in place, so system PiP survives next-episode transitions.** The load teardown dropped the running item to nil for the whole load gap (probe, demuxer, fresh loopback session), and the system closes a PiP window whose source layer's player loses its item; the #93 in-PiP recovery reload had already established the same failure mode and the `inPlaceSwap` fix for it. `load()` now computes `shouldHandOverItemInPlace(pipActive:priorBackendWasNative:)`, `stopInternal` defers the item detach (`keepCurrentItem`), and the loopback host.load callsite consumes the armed handover as `inPlaceSwap`: the old item keeps playing until `replaceCurrentItem` swaps in the ready master, transport intent latched. Audio-switch and recovery reloads keep their existing contracts (consume-and-reset). Covered by `PiPItemHandoverTests`. Host adoption: Sodalite re-enables next-episode auto-advance inside the tvOS PiP window. (#158)

## [5.11.0] - 2026-07-20

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.11.0))

### Added

- **tvOS: an active PiP window now keeps the video pipeline and loopback server alive across backgrounding.** tvOS previously ran an unconditional video teardown on `didEnterBackground` (wedge-safe: a live decode session crossing a multi-hour suspension wedged mediaserverd system-wide), which killed a system PiP window the moment the user left the app. The background handler now consults the new `shouldKeepVideoAliveTV(enabled:pipActive:)` policy: only `pictureInPictureActive` (set by the host from its PiP delegate, now cross-platform) defers the teardown, and the flag's `didSet` runs the wedge-safe teardown immediately when the PiP window closes while still backgrounded, so nothing crosses an idle suspension. Without active PiP, tvOS background behavior is byte-identical to before; there is no grace window and no background-audio case on tvOS. Covered by `BackgroundKeepaliveTests`.

## [5.10.0] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.10.0))

### Added

- **A non-live remote HLS playlist handed to the default (loopback) path now plays, and its external WebVTT subtitle renditions surface as `subtitleTracks`.** The bundled FFmpeg is built with `--disable-network`, so its hls demuxer could never engage behind the custom I/O context (no extension / MIME hint reaches the probe) let alone fetch a variant; a remote VOD m3u8 died with a bare `AVERROR_INVALIDDATA`. The AVIOReader now classifies the `#EXTM3U` body on the non-live path too (typed `hlsPlaylistOnVODPath`, the #140 sibling) and `load()` reroutes the URL onto the `nativeRemoteHLS` bypass, where AVPlayer plays remote HLS natively; a VOD `startPosition` rides into the bypass as a resume seek (live callers keep the no-initial-seek contract). On the bypass the engine maps the item's legible `AVMediaSelectionGroup` onto `subtitleTracks` (synthetic ids, forced / SDH dispositions carried), `selectSubtitleTrack(index:)` / `clearSubtitle()` drive AVPlayer's media selection with the manual-criteria pin, AVPlayer renders the cues itself, and an AVKit / caption-preference auto-select is mirrored into `activeSubtitleTrackIndex` after readiness. Verified end-to-end against the reported WWDC CMAF stream (7 renditions surfaced, explicit select lands). Covered by `RemoteHLSMediaSelectionTests`. Reported by jihongboo (#154).

## [5.9.7] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.9.7))

### Fixed

- **`subtitleCues` now holds embedded cues up to the drainer's full 60 s lead window ahead of the playhead on VOD sessions, so a host-applied ADVANCE sync offset finds them, text and bitmap alike.** The #112 pump tap harvests subtitle packets only as far as the segment producer's forward park (#102), which on direct play sits a few seconds past AVPlayer's fetch position; the drainer's 60 s lead was an empty promise beyond that, a delay offset worked (300 s trailing retention) but an advance showed nothing or flashed cues in late. A VOD-only subtitle forward prefetcher (a subtitle-only side reader, all other streams discarded per #104) now fills the session `SubtitlePacketStore` to `playhead + 60 s` independent of the producer: parked on the subtitle PTS axis, re-anchored on seeks via the drain tick's jump detection, open deferred while a producer restart is in flight (#93), positioned under the shared bounded-seek + byte-estimate rules (#112 round 10). Split-PES PGS display sets assemble under a per-writer key so the pump's in-flight set is never corrupted; overlapping completed packets dedupe by PTS. Live sessions skip it (content past the edge does not exist), and it is best-effort: on open failure or wedge, behavior is exactly the tap-fed status quo. Covered by `Issue151SubtitleForwardPrefetchTests`. Reported by rrgomes (#151).

## [5.9.6] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.9.6))

### Fixed

- **Interlaced live H.264 whose demuxer field-order probe stays UNKNOWN now routes to the software deinterlace path instead of staying on native VideoToolbox decode with a persistent colour cast.** The #107 rule (interlaced H.264 goes software so bwdif can deinterlace; tvOS AVPlayer does not) keyed only off the demuxer's `field_order` probe, so a channel that is unambiguously interlaced at the bitstream level (SPS `frame_mbs_only_flag=0`) but probes `AV_FIELD_UNKNOWN` silently defeated the routing and rendered with a sustained green cast from the first frame. When the probe is inconclusive, the routing decision now parses the SPS from codecpar extradata (both Annex-B/MPEG-TS and avcC/MP4/MKV layouts) and treats `frame_mbs_only_flag=0` as interlaced. A concrete PROGRESSIVE probe (which analyzed actual frames) still wins over the SPS capability flag, and a false positive only pays an unnecessary software decode: the software decoder engages bwdif per frame from `AV_FRAME_FLAG_INTERLACED`, so progressive frames pass through untouched. The fallback logs `fieldOrder=UNKNOWN but SPS frame_mbs_only_flag=0; treating as interlaced for routing (#150)` when it fires. Covered by `VideoRoutingPolicyTests` and `H264SPSTests`. Reported by digilearn-dev (#150).

## [5.9.5] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.9.5))

### Fixed

- **A PGS display set carrying multiple composition objects at one start PTS (a forced sign plus dialogue, a common real-disc shape) now renders ALL its objects instead of collapsing to the last one; each object's forced flag is surfaced per cue.** The decoder already fanned N objects into N same-start image cues, but the retained store's same-start image replacement (#112) assumed "a PGS composition has a unique start PTS", true per composition, false per composition object, so each sibling replaced the previous before publish and only the last object survived (deterministic, no error; the only host-visible fingerprint was a gap in the session-monotonic cue ids). The replacement key now includes object geometry (normalized position + pixel size, deterministic across re-decodes via the alpha-bounding-box crop): a re-decode still replaces its placeholder twin, sibling objects are all kept, mirroring the text path's distinct-simultaneous-speakers rule. Same collapse one level up: the #112 reconstruction pass held a single candidate cue, so a multi-object landing set lost all but one object at seek time; the candidate is now the whole same-start group, with the #143 clear-trim applied per member.

### Added

- **Per-cue forced flag.** `AVSubtitleRect`'s `AV_SUBTITLE_FLAG_FORCED` (set by pgssubdec/dvdsubdec for forced captions) was never read; hosts could not distinguish a forced sign from dialogue. It now lands in `SubtitleImage.isForced` and surfaces per cue as `SubtitleCue.isForced` (source-compatible additions; track-level forcedness stays on `TrackInfo.isForced`). Covered by `Issue146PGSMultiObjectTests`. Reported by cmcpherson274 (#146).

## [5.9.4] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.9.4))

### Fixed

- **An MKV track carrying `TrackTimestampScale != 1` now demuxes on the coherent, unscaled segment axis (cluster + rel) instead of a silently wrong hybrid axis (cluster + rel x scale).** Inherited FFmpeg behavior (present in n8.1.2 and current master): `matroskadec` bakes the track's TrackTimestampScale into the stream time base but divides only the cluster component of each block timestamp by it. On the reporter's TTS=2.0 fixture, cue starts shifted by `relTs x (TTS - 1)` per cluster (12->14 s, 24.5->29 s), packets arrived non-monotonic in storage order (the 29 s cue before the 25 s clear), a stale fade outlived its authored clear, and packet durations ran at twice their authored length, all without any warning. Fixed at the FFmpeg layer: FFmpegBuild 2.1.2 (`patch_ffmpeg_matroska_tts`) clamps any non-1.0 scale to 1.0 with a warning carrying the ignored value, extending upstream's own `< 0.01` clamp. The element is deprecated (RFC 9559 caps it at Matroska v3) and most readers ignore it; full spec scaling would desync the track from its siblings, so the clamp keeps every track on the storage axis, in sync and monotonic, and a strict no-op for the TTS=1.0 world. Covered by `Issue145MatroskaTrackTimestampScaleTests` demuxing a synthetic in-memory Matroska through the engine. Reported by cmcpherson274 (#145).

## [5.9.3] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.9.3))

### Fixed

- **A seek landing mid-cue (or exactly on a display-set start boundary) on a PGS stream without acquisition points now re-shows the landing line, forced cues included, instead of leaving the overlay dark until the next authored composition.** The #112 reconstruction pass seeded its active-line candidate only from a self-contained composition (Acquisition Point / Epoch Start); on AP-less/sparse-authored streams every lead-in composition is Normal, so no candidate was ever seeded and the landing-span line was silently discarded, while successor cues re-emitted normally (on sparse dialogue the blackout ran tens of seconds). The candidate is now seeded from any successfully decoded composition behind the playhead; the drain decoder is rebuilt fresh at the backscan start, so a set with missing references fails decode and never reaches the gate, and the steady-state path already publishes Normal compositions unconditionally. Companion fix: `pgsTrimAt` (broadcast by every composition and clear) now also closes the reconstruction candidate's open placeholder window, so a line the author cleared before the playhead can no longer resurrect as the active line at pass end (a hole latent since #112 for acquisition-point content too). Covered by `Issue143PGSLandingLineTests`. Reported by cmcpherson274 (#143).

## [5.9.2] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.9.2))

### Fixed

- **A bare PGS Epoch-Continue display set (PCS+WDS+END, palette and objects referenced from retained decoder state, no PDS/ODS retransmit) now renders instead of being dropped whole with "Invalid palette id 0"; the predecessor cue no longer overstays.** Inherited FFmpeg behavior (present in n8.1.2 and current master): `pgssubdec` releases retained palettes/objects for ANY `composition_state != Normal`, including `0xC0` Epoch Continue, although Epoch Continue by definition continues the previous epoch across a connection point and a bare set legitimately references that state. The failed palette lookup discarded the set, and since PGS end times are closed by the successor cue, the prior cue's clear was delayed to the next cue (reporter's 90 s cue ran to the 100 s clear instead of the authored 95 s). Fixed at the FFmpeg layer: FFmpegBuild 2.1.1 (`patch_ffmpeg_pgssub`) skips the flush for Epoch Continue only; Acquisition Point and Epoch Start, self-contained restatements by spec, keep flushing. Covered by `Issue142PGSEpochContinueTests` driving the shipped decoder with synthetic display sets. Reported by cmcpherson274 (#142).

## [5.9.1] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.9.1))

### Fixed

- **A far-forward VOD seek above a retained scrub band no longer parks in 30 s serve timeouts into item death; the producer re-anchors at the target immediately.** Reported geometry: a scripted 600 s scrub left its segment band resident under the retention budget, the producer was later re-anchored at ~302 s, and a fourth seek targeted 640 s, just above the dead band's top. Two layers misread that. The segment server's forward-wait branch trusted the resident maximum as "the producer is about to write this" and parked the request for the target segment (three 30 s cache-miss timeouts; the third tore the connection into `-1017` / `failedToPlayToEndTime` item death and a stage-2 reload, correct target state only ~108 s after the seek command). And the 8 s seek-deadline path (#129) preserved the "progressing" producer because the old position still had forward buffer, blind to the target sitting ~330 s beyond what the march could reach inside the consumer's timeout budget. The forward-wait branch now keys on the active producer's write front (its high water since restart, or its anchor before the first write) instead of the resident maximum, so a request beyond the reachable window re-anchors the producer at once; and the seek-deadline backstop now also re-anchors a progressing producer whose march cannot reach the pending seek target (starvation is no longer the only trigger). Reported by cmcpherson274 (#141).

## [5.9.0] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.9.0))

### Fixed

- **Handing an HLS playlist (`.m3u8`) URL to `load(isLive:)` on the generic path no longer hangs forever with no error.** The documented HLS entry points (`LoadOptions.nativeRemoteHLS` and `HLSLiveIngestReader`) were bypassed, so the playlist URL routed onto the raw-byte live reader. A live origin serves the finite `#EXTM3U` body at HTTP 200 and closes the connection, which the endless-feed reader read as a dropped live stream and reconnected, re-fetching the same body forever. Those reconnects looked productive (a full body at 200, and every `find_stream_info` probe seek reset the unproductive-reconnect streak), so the reconnect give-up counters (#71) never tripped, `avformat_open_input` never returned, and `load()` sat at `.loading` with no terminal state (reporter saw 262 reconnect cycles over 5.75 minutes). The raw-byte reader now inspects the first bytes of a live source and fails closed when they are an HLS playlist tag (a raw media container never opens with `#`; TS syncs on `0x47`), before the reconnect loop is ever entered. Reported by cmcpherson274 (#140).

### Added

- **`AetherEngineError.hlsPlaylistOnRawLivePath`.** `load()` now throws this typed, catchable error (with an actionable `LocalizedError` description) when an `.m3u8` playlist is misrouted onto the raw live path, pointing the caller at `LoadOptions.nativeRemoteHLS` / `HLSLiveIngestReader` instead of looping silently.

## [5.8.9] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.9))

### Fixed

- **Stereo sources now reach the AVR as stereo so its upmixer engages (software renderer path).** The renderer paths (`SoftwarePlaybackHost`, `AudioPlaybackHost`) activated `AVAudioSession` with `setPreferredOutputNumberOfChannels` pinned to the route maximum regardless of the source. A stereo track (live TV, interlaced VOD) was therefore presented to a 7.1 AVR as an 8-channel PCM stream, so the receiver saw native surround and never engaged its Dolby Pro Logic II / DTS Neural:X upmixer; stereo played flat across the front channels. The preferred output count now matches the active audio track's own channel count (resolved from the published track list), clamped to the route maximum, and falls back to the route maximum only when the source count cannot be determined. Genuine multichannel sources still get every channel. Reported and fixed by Nathan Piper (nathanpiper).

## [5.8.8] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.8))

### Fixed

- **Exiting a long live DVR channel no longer freezes the UI for several seconds.** `PacketRingBuffer.close()` collected every spooled packet file and deleted them one at a time on the calling thread; a live software-host stream held open for minutes spools tens of thousands of files, so the O(n) filesystem walk stalled the caller (5-30 s) and, on the main actor, blocked channel switching. `close()` is now idempotent (the in-RAM index is cleared synchronously under the lock, so the ring is immediately unusable) and dispatches the scratch-directory removal to a background queue, so filesystem I/O never blocks the caller. Every spooled file lives under the per-instance scratch dir, so a single recursive removal covers them all. Reported and fixed by Nathan Piper (nathanpiper).

## [5.8.7] - 2026-07-19

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.7))

### Fixed

- **Resuming near the end of a file with a keyframe cluster could load forever instead of playing.** When a VOD's keyframe index carried a burst of IRAPs within a few frames (a hard cut / scene change near the resume point), the keyframe-aligned segment plan emitted sub-frame (~40 ms) segments: once the absolute `(segIdx+1) * targetDuration` cut threshold lagged the actual position, each clustered keyframe became its own boundary. The plan and the producer share one boundary list, and the producer only cuts a segment index when a demuxed keyframe's PTS maps into its `[start, end)` window, so a ~40 ms window could catch none of the actually-demuxed keyframes and that index was never produced while its neighbours were. The playlist still advertised the missing index, so AVPlayer requested it, the serve path waited out a 30 s cache miss, and it surfaced as CoreMedia `-15628` loader poison; the stall watchdog then reloaded and every fresh item re-hit the identical skipped hole, spinning the item-reload loop forever. The plan now folds any segment shorter than 1 s into a neighbour (`collapseShortSegments`), so every advertised segment has a window wide enough to contain a demuxed keyframe and the plan and producer agree; kept boundaries are still real keyframes and total duration is conserved. Reported and device-verified by Vincent.

## [5.8.6] - 2026-07-18

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.6))

### Changed

- **Cleared five Swift 6 `SendableClosureCaptures` warnings in the AVIO size-probe.** The staggered-concurrent open-time size probe (#107 follow-up) kept its `resolvedSize` / `outstanding` counters as mutable locals and passed each probe as a plain `() -> Int64` thunk, so Swift 6 flagged the `asyncAfter` `@Sendable` closures. The synchronisation was already correct (every touch guarded by one `NSCondition`); the shared state now lives in a condition-guarded `@unchecked Sendable` box and the probe thunk is `@Sendable`. No behaviour change; the package builds warning-free under Swift 6. Surfaced while sweeping build warnings for the Sodalite 1.0 release.

## [5.8.5] - 2026-07-18

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.5))

### Fixed

- **Recurring green flicker mid-stream on live MPEG-TS channels whose encoder restarts or splices in place (#133 follow-up).** The #133 join gate covered joining a broadcast mid-stream, but the same "non-existing PPS/SPS referenced" decode condition recurred later in the same session on some UK terrestrial channels via Xtream, showing as green frames that came back throughout playback rather than only at tune-in. The fMP4 `avcC` (SPS/PPS) freezes at `avformat_write_header`, and the versioned-init rotation that re-establishes it only fired for an SSAI program switch on a new video PID. An in-band parameter-set change on the *same* PID (encoder restart or regional opt-out splice) forced only a discontinuity cut, so the panel kept decoding the new slices against the stale `avcC`. Each mid-stream keyframe now compares its in-band SPS/PPS against the sets backing the current `avcC` and, on a divergence, rotates the muxer through the same versioned EXT-X-MAP path, parsing the sets directly so it works whether or not the demuxer surfaces the change as side data. A same-PID change keeps the program's Dolby Vision / colour signaling; only an ad creative on a new PID drops it. Reported with precise logs by digilearn-dev. This build also adds diagnostics (per-epoch video PID, parameter-set-change counter, and DisplayCriteria skip-signature logging) to confirm the path on retest.

## [5.8.4] - 2026-07-18

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.4))

### Fixed

- **Teletext captions no longer render a blank line between two lines placed on non-adjacent rows (#107).** libzvbi joins teletext rows with `\N`, so a two-line caption whose lines sit on non-adjacent rows (an empty middle row used only for vertical placement) arrived as `line1\n\nline2` and showed a blank line the broadcaster never intended. The 5.8.0 edge-trim only removed leading and trailing newlines; interior runs of consecutive newlines now fold to a single break too, on both the plain and coloured teletext paths. Single line breaks between adjacent rows are preserved. Reported by tresby, who device-verified the 801 page override and hardware deinterlace on real AU streams in the same pass.

## [5.8.3] - 2026-07-18

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.3))

### Fixed

- **iOS / tvOS build fix for the #2 decodability probe.** `VTCapabilityProbe.canHardwareDecode` used `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder` without the iOS 17 / tvOS 17 availability guard (the symbol did not exist on iOS before 17), so 5.8.2 compiled on macOS but failed the iOS / tvOS simulator build. Guarded the same way `HardwareVideoDecoder` does. No behavior change on shipping deployment targets. macOS (AetherPlayer) was unaffected in 5.8.2.

## [5.8.2] - 2026-07-18

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.2))

### Fixed

- **H.264 / HEVC formats VideoToolbox cannot hardware-decode now fall back to software instead of a black screen (#2).** H.264 High 4:2:2 / 4:4:4 / High-10 and HEVC Rext are accepted by AVPlayer at the HLS CODECS level (the item reaches `readyToPlay`), but on hardware without a VideoToolbox decoder for the profile (Intel Macs, older Apple TV chips) the native path then renders nothing, while QuickTime plays the same file via its own software decoder. A per-format `VTDecompressionSession` probe at load (`VTCapabilityProbe.canHardwareDecode`) now routes these sources to the `SoftwarePlaybackHost` (libavcodec), which decodes them. Apple Silicon has hardware decoders for all of these and keeps them on the native path unchanged. Reported by DrHurt.

## [5.8.1] - 2026-07-18

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.1))

### Fixed

- **Dolby Vision P7 conversion failures degrade to clean HDR10 instead of shipping mixed-profile DV (#135).** When libdovi cannot convert a P7 RPU to P8.1 on the loopback-HLS producer path, the offending RPU (and its enhancement-layer NAL) is now dropped rather than muxed through, so the affected frame plays as the clean HDR10 base instead of riding a P7 RPU inside a container already declared 8.1. Well-formed remuxes never reach this path and are unaffected. Field notes from rrgomes.

### Added

- **Full Enhancement Layer (FEL) sources are logged during P7 to P8.1 conversion (#135).** The first RPU's enhancement-layer type is probed once; a FEL source (whose enhancement layer is discarded in the single-layer conversion, unlike a MEL source where the drop is lossless) now emits a one-line log, so a flatter-looking FEL disc can be triaged against a native P7 player. Also surfaced on `DoviConvertProbeResult.enhancementLayerType` for `aetherctl dovitest` validation. Thanks to rrgomes.

## [5.8.0] - 2026-07-18

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.8.0))

### Added

- **Hardware deinterlacing with smooth field-rate motion (#107).** Interlaced broadcast on the software-decode path (MPEG-2 / VC-1 / MPEG-4 and interlaced H.264) now deinterlaces on the GPU via `yadif_videotoolbox` (the yadif kernel as a Metal compute shader over VideoToolbox frames) and, by default, at field rate (`send_field`: 25i to 50p, 29.97i to 59.94p) for smooth motion on sport. `LoadOptions.deinterlaceMode` (default `.auto`) selects the hardware graph with a software bwdif fallback (no Metal device, an older linked FFmpeg, or a graph-build failure all fall back cleanly); `LoadOptions.deinterlaceFieldRate` (default `.field`) controls cadence. The hardware sink emits IOSurface-backed CVPixelBuffers copied GPU-side into the decoder's own pool, skipping the sws_scale copy. Requires FFmpegBuild 2.1.0 (pulled transitively), which also carries a patch balancing an over-release of the autoreleased Metal command-buffer/encoder in the upstream VT filter (a candidate for ffmpeg-devel). Adopts and thanks tresby (whose fork this ports) and nathanpiper.

### Fixed

- **Coloured teletext captions no longer render a leading blank line (#107).** libzvbi teletext ASS can prefix a row-positioning newline; the plain-text path trimmed it but the coloured (rich-text) path did not, so a coloured caption showed a blank line the same page without colour would not. The colour parser now edge-trims leading and trailing whitespace and newlines across the run sequence, matching the plain path (interior line breaks and colours preserved). Reported by tresby.

## [5.7.0] - 2026-07-18

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.7.0))

### Added

- **Coloured DVB teletext captions (#107).** Teletext subtitles now decode through libzvbi as ASS (`txt_format=ass`) so the per-character colour broadcasters use to distinguish speakers survives to the overlay. A new `SubtitleCue.Body.richText([SubtitleTextRun])` carries the coloured runs (each run an RGB `SubtitleColor?`, nil meaning "use the host default"); `cue.text` still flattens rich cues to plain text so existing text consumers are unchanged, and an all-white page keeps emitting plain `.text`. Both reference hosts render the coloured runs. Thanks to tresby and nathanpiper.
- **Teletext caption-page override (#107).** `LoadOptions.teletextPage` selects the teletext page libzvbi decodes (default nil = auto-detect the flagged subtitle page). Channels whose captions ride a page libzvbi does not flag as a subtitle page (for example Australian free-to-air on page 801) can now be targeted explicitly; the option threads through every subtitle tap site.

### Fixed

- **Coloured teletext cues are trimmed and de-duplicated in the retained store like plain ones (#107).** The teletext successor-trim and the live-DVR re-decode de-dupe were text-cue-only; coloured pages (now rich-text cues) are handled by both, so a coloured caption is closed by its successor instead of lingering to the page-hold cap, and does not duplicate across a live-DVR seek.

## [5.6.2] - 2026-07-17

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.6.2))

### Fixed

- **Live H.264 channels joining mid-broadcast no longer green-flash or die with an empty playlist (#133).** On the MPEG-TS ingest path the video gate opened on any keyframe-flagged packet without confirming a decodable IDR access unit. Joining a running broadcast, that meant the decoder briefly rendered an uninitialized reference (green frame) until the real SPS/PPS/IDR arrived, or, when the probe joined before any SPS and left `codecpar` at 0x0, the first muxer allocation fed 0x0 dimensions into `avformat_write_header` (-22) and the channel produced an empty `#EXTM3U` that never recovered. A live-only pre-gate (H.264 with Annex-B framing) now withholds video until a packet carries in-band SPS + PPS and a true IDR slice, and reconstructs the muxer's dimensions from those in-band parameter sets when the probe left them unresolved. A miss is covered by the existing bounded live keyframe-gate timeout (reopen), not a terminal muxer failure. fMP4 live and VOD are unaffected.
- **Same-format live zaps no longer pay the full display-mode settle cap (#133).** Zapping between two channels of the same format (e.g. two SDR 50 Hz channels) re-applied identical `AVDisplayCriteria`, which on unobservable-Dolby-Vision panels started a mode switch the app cannot observe and made the post-load settle wait burn its full ~3s cap on every zap. The engine now retains the last-applied criteria and skips both the redundant panel write and the settle wait when the incoming criteria are already active, cutting that redundant latency to zero. Any zap that actually changes format, rate, or dynamic range settles exactly as before. Thanks to digilearn-dev for the detailed report and reproduction.

## [5.6.1] - 2026-07-17

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.6.1))

### Fixed

- **A diagnostics tick can no longer hang or kill the host app (#134).** On the native path the 1 Hz `LiveTelemetrySampler.tick` made up to six synchronous AVFoundation reads per second on the main actor; each is a sync XPC round-trip to mediaserverd, so a momentarily busy media server (a display-mode change on an HDR start, for example) parked the main thread in `mach_msg` and surfaced in production hosts as fully blocked app hangs and watchdog terminations. The reads now run as one coalesced batch (one `accessLog()`, one `currentTime()`) on a dedicated background queue, and a tick that resumes after a stop or reload seam drops its stale snapshot instead of publishing it into the new session. The same class of read existed in the 30 s memory probe (now hopped through the same helper) and in the host's `seekableEnd`, which live clock-tick sinks and the paused-live 1 Hz window timer read per call and is now a KVO mirror of `seekableTimeRanges`. As a side effect, the `[LagDiag]` line no longer pays any AVFoundation cost when verbose logging is disabled. Thanks to l984-451 for the Sentry-backed report, the exact read inventory, and the off-main fix proposal.

## [5.6.0] - 2026-07-17

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.6.0))

### Added

- **A53/SEI-embedded CEA-608 captions are now extracted and rendered (#131).** US broadcast and cable-sourced feeds carry closed captions as ATSC A/53 `cc_data` inside the video bitstream rather than as a demuxable caption stream, so the #77 closed-caption tap never armed and captioned live channels played with no subtitle option. The segment producer now scans H.264/HEVC video packets for `user_data_registered_itu_t_t35` SEI (GA94), reorders the decode-order caption groups to presentation order, and feeds the existing line-21 decoder; the software-decode path (MPEG-2 and friends) feeds the same tap from `AV_FRAME_DATA_A53_CC` decoded-frame side data. A synthetic `eia_608` track surfaces lazily on the first real caption pair, so uncaptioned channels never show a dead menu entry and hosts need no changes. Overlay-only for now (no native WebVTT rendition); CEA-708 stays out of scope, matching #77's field-1/CC1 first cut. Thanks to dlev02 for the precise engine audit that scoped the fix.

## [5.5.1] - 2026-07-17

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.5.1))

### Fixed

- **Live HDR10 channels no longer fail at startup with -1002 (#130).** AVPlayer filters a `VIDEO-RANGE=PQ`/`HLG` variant without a `FRAME-RATE` attribute out of the master playlist at parse time and fails the item with NSURLErrorDomain -1002 before ever fetching the media playlist. Live MPEG-TS probes can leave `avg_frame_rate` unset, so live HDR sessions could serve exactly that master with no recovery path. The manifest frame rate now falls back to `r_frame_rate`, a source with no detectable frame rate routes media-direct instead of serving an unloadable master, and a startup -1002 while serving the master reactively falls back to the media playlist (live sessions rejoin at the edge). Thanks to digilearn-dev.

## [5.5.0] - 2026-07-17

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.5.0))

### Changed

- **FFmpeg now ships as dynamically linked frameworks (FFmpegBuild 2.0.0).** The FFmpeg xcframeworks were static archives that SPM linked into the app binary, which left closed-source App Store adopters without a realistic LGPL compliance path. They are now dynamic frameworks that Xcode embeds and signs in the app bundle automatically; no integration changes are needed. FFmpegBuild 2.0.0 also corrects the license statement (the FFmpeg parts are LGPL-2.1-or-later, not LGPL-3.0) and excludes libzvbi's GPL-2 sources from the build, so no GPL code ships in the binaries. The README's License section now spells out that the engine's store exception does not extend to FFmpeg and what adopters have to do instead. Thanks to the adopter whose licensing review flagged the contradiction.

## [5.4.1] - 2026-07-17

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.4.1))

### Fixed

- **A native seek can no longer suspend the caller past its 8 s budget (#129).** The old deadline path retried the seek with an unbounded await, so repeated source stalls could leave `seek(to:)` suspended for 40+ s. The deadline now reconciles the public clock to the rendered frame and returns; the original AVPlayer seek stays alive as the recovery intent, and a late landing settles clock, transport state, and subtitle re-anchoring after the fact (both orderings of the completion/deadline race on the MainActor are handled). The producer is restarted only when it is genuinely starved; a healthy-but-slow producer keeps its progress. Thanks to thatcube.
- **Interior sparse-cache holes no longer burn a 2 s wait the producer can never fill (#129).** A cache index inside the stored min/max range is not proof of residency after scrubbing leaves retained bands. The fetch path now waits only when the active producer's forward march actually covers the requested index, and restarts immediately otherwise. Thanks to thatcube.
- **A starved seek landing with a paused `timeControlStatus` and playing intent no longer latches paused.** The seek finalize now reconciles transport from live AVPlayer status: external AVKit / MediaRemote play or pause issued during a seek wins, while the bounded stall-recovery window reasserts play over a spurious pause (the #122 guarantee is unchanged: a paused scrub still lands paused).

## [5.4.0] - 2026-07-17

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.4.0))

### Added

- **`stop(resetDisplayCriteria:)` lets a handoff stop preserve the panel's HDMI mode (#128).** Nil-ing `preferredDisplayCriteria` during a same-mode stop()/load() handoff bounced tvOS through SDR before re-negotiating the same Dolby Vision mode. `stop(resetDisplayCriteria: false)` keeps the criteria applied so the next `load()` overwrites it in place; the plain `stop()` default is unchanged. Thanks to thatcube for the fix, verified on real hardware.

### Fixed

- **Back-to-back `load()` calls no longer bounce the panel through SDR (#128 follow-up).** The engine's own load-over-load seam (e.g. a next-episode handoff that reloads in place) reset the criteria the same way before `apply()` re-negotiated. The seam now preserves the criteria; audio-only sessions and suppressed (AVKit-sole-writer) hosts clear a leftover criteria at routing time instead, so music playback cannot keep the panel in DV/HDR and dual writers cannot fight.

## [5.3.1] - 2026-07-16

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.3.1))

### Fixed

- **Credential headers are no longer replayed onto cross-origin redirect targets (#126 follow-up).** The redirect handler shared by the persistent reader and both size probes reapplied every caller-supplied header, including `Authorization`, to whatever URL a redirect landed on. A media server 307-redirecting to a cross-origin presigned object-storage URL (query-string auth) then rejected the request with 400 (two conflicting auth mechanisms), every probe went blind, and the reader degraded to forward-only streaming mode, breaking moov-at-end MP4s against a fully byte-seekable target. It also disclosed the media-server token to foreign hosts. Credentials (`Authorization`, `Proxy-Authorization`, `Cookie`, Emby/Jellyfin token headers) are now replayed only to a same-host target with no TLS downgrade; `Range` and non-credential extra headers still survive cross-host redirects for header-dependent proxies (#8 behavior unchanged). Thanks to YangHanqing for the precise A/B diagnosis.

## [5.3.0] - 2026-07-16

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.3.0))

### Added

- **Live audio delivery is decoupled from video decode pace (#107).** The software live (DVR) feeder fed audio interleaved behind the video renderer's back-pressure gate, capping the audio renderer's lead over the clock below one second; on devices where software 1080i decode plus deinterlacing runs near real time that margin is zero and every feeder stall was an audible dropout. An audio look-ahead pump now decodes and enqueues audio from the DVR ring up to a 4 s lead independent of the video path, so a slow video decode degrades to late video frames under smooth audio. DVR seeks reset the pump cursor atomically alongside the combined cursor.
- **Live-edge source underruns pause and rebuffer instead of chopping forever (#107).** When the source itself briefly delivers below real time and playback drains the ring at the live edge, the free-running synchronizer clock used to outrun the stream permanently, leaving every later sample in the clock's past (continuous chopping that never recovered). The clock now pauses at 0.15 s of remaining audio lead, refills, and resumes at 2 s, mirroring AVPlayer's stall handling on the native path.
- **`aetherctl play --audio-stats` and `--host-calls seekback`.** The play harness can now tap the decoded PCM and report per-second audio lead plus source-PTS continuity gaps, and script a DVR rewind plus live-edge return; this is the tooling the audio-chopping report was diagnosed and verified with.

## [5.2.1] - 2026-07-16

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.2.1))

### Changed

- **Open-time size probes run concurrently (#107 follow-up).** The Range / HEAD / bounded-range fallback ladder for origins whose data connection resolves no length ran sequentially, tripling open latency on genuinely length-less sources (each probe pays the origin's full connect latency). The primary open-ended range probe still fires first and alone; the two fallbacks start 750 ms later in parallel, first positive size wins. Origins that resolve the primary inside the stagger window see identical wire traffic. Verified 17.2 s to 12.1 s against a 3 s-latency length-less origin; probe requests and budgets unchanged.

## [5.2.0] - 2026-07-16

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.2.0))

### Added

- **Teletext subtitles render on the overlay with page-state semantics (#107).** DVB teletext (libzvbi) captions now reach `subtitleCues` on every software session shape. libzvbi emits page content open-ended ("until replaced") and page erases as rect-less clear events; both now carry a text trim that closes earlier open cues at the event start, so live roll-up captions build and replace cleanly instead of accumulating. Open-ended windows are additionally capped at 120 s as a ghost-line bound. Validated end-to-end against Australian FTA broadcasts (1080i25 H.264, captions on page 801). Thanks to tresby for the tuner access that made the live validation possible.
- **`aetherctl play`.** Full load+play session smoke test: 1 Hz transport telemetry, `--live` / `--dvr-window`, `--subs <codec-or-lang>` cue logging, and `--host-calls` mimicry of host post-load call sequences. Fails loud when the clock does not advance or a selected subtitle track produces no cues.

### Fixed

- **Mid-stream-joined sources no longer freeze on the first frame (#107).** A live tuner MPEG-TS opened without `isLive`, live without a DVR window, or a capture file cut mid-broadcast delivers its first samples hours past the load anchor; the combined demux loop armed the synchronizer at the load anchor (0 on a fresh load), scheduling every A/V sample far in the future. The clock now re-anchors at the first decoded sample PTS when it deviates from the load anchor by more than 2 s (`SWClockAnchorPolicy`); positions stay session-relative through the anchor's session zero while `sourceTime` rides the raw source axis, matching the native path's split.
- **Live-DVR sessions feed subtitle packets again (#107).** The live reader loop only ring-buffered audio/video; subtitle packets never reached the session packet store, starving the overlay drainer on every live+DVR session.
- **Host rate changes before clock arming no longer wedge the session (#107).** A `setRate` issued between `load()` and the demux loop's clock arming requested a rate at a clock time where no media will ever exist; `AVSampleBufferRenderSynchronizer`'s delayed-rate-change machinery then held the effective rate at 0 permanently. `setRate` / `pause` / play-resume now gate the synchronizer call on the armed-clock latch, and arming applies the latest host rate. `AudioOutput` logs every clock mutation.

## [5.1.0] - 2026-07-16

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.1.0))

### Added

- **Paused-background grace window on iOS (#127).** A paused session used to tear down the moment the app backgrounded, so a 10-30 s app switch paid a full pipeline rebuild. The teardown is now deferred by `backgroundTeardownGraceSeconds` (default 15 s, 0 restores the immediate teardown), held under a background-task assertion; returning inside the window resumes on the live pipeline with no reload. At expiry the background action is re-evaluated (PiP / lock-screen play can change mid-window) and the wedge-safe teardown runs while the app is still genuinely running, never across an idle suspension. A playing session with background playback disabled still tears down immediately; tvOS keeps the unconditional teardown. Thanks to dlev02 for the proposals and device logs.
- **Public `isSessionReady` (#127).** `@Published` engine flag, true once the active session's transport is ready to accept seeks and report real time (native path: AVPlayerItem readyToPlay), false across every teardown. Hosts gate corrective actions (restore watchdogs, position clamps) on it instead of inferring readiness from `currentTime` being pinned at 0.

### Fixed

- **Pre-ready host seeks no longer clamp to 0:00 (#127).** A host seek forwarded while the AVPlayer item was pre-ready clamped to 0 against empty seekable ranges and replaced `load()`'s own pending start-position seek, restarting playback from the file head. Such seeks are now deferred and the latest one replays at readiness.

## [5.0.7] - 2026-07-15

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.0.7))

### Fixed

- **Unknown-length HTTP MP4 no longer enters a seek-dependent path and silently produces zero packets (#126).** When no size probe resolved a length (an origin answering `bytes=0-` with 200/chunked and rejecting HEAD, e.g. Emby behind a buffering proxy), the AVIO reader degraded to forward-only streaming mode but still advertised itself as seekable, so the mov demuxer parsed a tail moov it could never rewind to and every sample read died with "partial file" while the host waited on a playlist that never gained a segment. Three layers: a last-resort bounded `bytes=0-1` range probe recovers the real size from origins that honor ranges but omit lengths on open-ended requests (full seekable playback, the common case); a source that genuinely resolves no size now reports itself non-seekable to both FFmpeg and the routing layer, so moov-at-end files fail cleanly at open and faststart files route to the sequential software path; and a VOD producer that dies on a read error having produced nothing now surfaces a fatal load error instead of leaving AVPlayer in `waitingToPlay` until the host's timeout. Thanks to YangHanqing for the precise log capture and the VLC control test.

## [5.0.6] - 2026-07-15

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.0.6))

### Fixed

- **Playback resumes after system audio-session interruptions that end with `.shouldResume` (Sodalite iOS device report).** The engine had no `AVAudioSession` interruption handling at all: a foreign session claiming audio (a phone call, Siri, or a live-camera PiP with record priority) paused AVPlayer through the system, and when the interruption ended playback stayed silent until a manual play. The system pause never goes through `pause()`, so the native host's durable `playIntent` (#122) survives the interruption and arms a resume; on interruption end the engine re-issues `play()` only when the system grants `.shouldResume` (a call ending, Siri dismissing). Sessions that end without it, such as a camera PiP closing, stay paused by design and resume manually. An explicit user `pause()` or stop disarms the resume; in the background only audio backends may resume. Interruptions are also logged with type, reason, options, and session state, so foreign-session conflicts are visible in captures.

## [5.0.5] - 2026-07-14

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.0.5))

### Added

- **A host can now mount media paused with `LoadOptions.autoplay` (#124).** Every load path ended in an unconditional autostart, so a host that wanted to hold a pause at mount (a synchronized-start lobby that loads several devices and starts them together on a signal, or a hold-at-mount / resume prompt) always received one engine-initiated resume at load completion and had to claw it back with a racy state-sink clamp, the same declared-versus-real split as #122/#123. `LoadOptions.autoplay` defaults to `true`, so every current caller is byte-identical. Set it to `false` and the load skips its terminal `play()` and `state = .playing` across all paths (native VOD, software, both audio backends, and the lean native remote-HLS path), leaves `playIntent` false, and settles `.loading` to `.paused` through the existing `host.$isReady` readiness waypoint; the host resumes later with `play()`. On the native VOD path the SDR-to-HDR cold-start readiness gate is skipped for a paused mount, since it is an autostart-path recovery that plays to poll readiness. The `reloadAtCurrentPosition` path (audio switch, live rejoin) is unchanged. Thanks to rrgomes for the device traces and the code-level shape of the fix.

### Fixed

- **Subtitle cues no longer starve permanently after a backward seek into cache-resident content (#125).** During a long mixed-direction seek storm on a heavy 4K Dolby Vision remux with embedded PGS and SubRip tracks, subtitle cues could stop rendering partway through and never return, each track re-arm logging `backfilled 0 cues` over an armed but empty store. The #112 overlay is fed only from the session's `SubtitlePacketStore`, whose single writer is the producer demux pump, and the playhead-paced drainer pruned that store every tick at `playhead - retentionSeconds`. A backward jump into segment-cache-resident content is served without a producer restart and the pump stays parked forward, so once a forward excursion pushed the prune cutoff past the returned region its packets were gone and never re-harvested, leaving the drain window permanently empty. The trailing time-prune is removed; the store is now bounded only by its existing per-stream byte cap (evict-oldest), so text tracks keep the whole session and bitmap tracks keep a wide trailing window, matching how the segment cache retains history for backward seeks rather than clamping to a window ahead of the playhead. A backward seek past a bitmap stream's evicted edge is a deferred windowed-re-read fallback. Thanks to rrgomes for the code-level diagnosis (the pump as the store's only writer, the cache-resident backward jump that skips the restart) and the byte-retention fix direction.

## [5.0.4] - 2026-07-13

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.0.4))

### Fixed

- **Subtitle cues no longer pace ahead of a frozen picture during a queued seek chase (#123).** Under sustained *queued* skip bursts on a heavy 4K Dolby Vision asset (a new burst issued into an unfinished settle), the engine's reported clock adopted each new target immediately while the underlying player rebuilt, and `sourceTime` (documented as the on-screen frame, not the scrub target, #49) parked tens of seconds ahead of the picture for 14 to 33 s. Any host pacing subtitle cues off `sourceTime` then rendered cues for positions 10 to 30 s ahead over a still frame until convergence. The VOD seek finalize and the native host's seek completion stamped `sourceTime` (and `renderedTime`) onto the target unconditionally at landing, but during a chase the player is `waitingToPlayAtSpecifiedRate` with the picture frozen behind the target, and the 100 ms periodic observer that would walk the clock back to the rendered frame is silent while buffering, so the stamp stuck. Both stamps are now gated on whether the landed frame is actually presented: a playing or paused landing shows the target frame and settles onto it immediately (isolated and paused scrubs are unchanged), while a landing still buffering toward the target holds `sourceTime` on the rendered frame and lets the observer settle it when playback resumes and the frame is delivered. Cues glued to `sourceTime` stay glued to the picture through the chase, and `abs(currentTime - sourceTime)` stays honest as a converging gap a host can gate cue rendering on. The phase logs ruled out the producer restart coalescer (nine cheap restarts across roughly 107 seeks, the long stretches had zero rebuilds and were pure player buffering). Thanks to rrgomes for the triangulated three-clock traces and the phase breakdown that isolated the finalize stamp.

## [5.0.3] - 2026-07-12

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.0.3))

### Fixed

- **A seek issued while paused no longer re-engages playback (#122).** With playback paused by the host, a skip or scrub commit spontaneously resumed the underlying player (rate 1) with no host `play()` call. The normal seek finalize forced `state = .playing` regardless of the transport intent in effect when the seek was issued. That both reported playing after a paused scrub and weaponised the #93 stall-recovery reassert: the seek's own paused landing (`timeControlStatus == .paused`), arriving while `state == .playing` inside an open recovery window (a backward skip's rebuffer opens one), was misread as a spurious pause, so the engine called `host.play()`. The finalize now derives its state from the durable transport intent (the native host's `playIntent`, which a seek never touches), so a paused scrub lands paused, presenting the new frame, and `engineStateIsPlaying` stays honest so the reassert only fires on genuine stalls. A playing scrub is unchanged. Thanks to rrgomes for the traces isolating the three trigger points and confirming a plain pause is never affected.

## [5.0.2] - 2026-07-11

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.0.2))

### Fixed

- **Embedded SRT cues no longer duplicate after rapid seeking (#121).** The overlay drainer rebuilds the `EmbeddedSubtitleDecoder` on every seek (`.resetAndDecode`), which restarts its per-instance dedupe set and cue-id counter at zero. Because `subtitleCues` is intentionally retained across the seek, the backscan re-decoded cues still in the store, and the insert path only replaced same-start bitmap cues while always appending text cues, so identical lines accumulated (a report saw the count grow 4 to 7 to 11) and the reset decoder ids collided with retained ids (`ForEach(id:)` "occurs multiple times"). Both invariants now live at the retained-store insert funnel, which sees the whole session rather than one decoder generation: a text cue already present with the same start, end, and text is dropped (content, not id, so simultaneous distinct speaker lines and genuine repeats at new timestamps still insert), and every cue that lands is stamped with a session-monotonic id. Thanks to wunax for the source-level diagnosis and the exact repro.

## [5.0.1] - 2026-07-10

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.0.1))

### Fixed

- **Split MPEG-TS PGS display sets reassemble before decode (#112).** On Blu-ray MPEG-TS a PGS display set spans several PES packets (PCS, WDS, PDS, ODS, END). The packet-tap store kept one entry per harvested packet keyed by unique PTS, so segments without a PTS died at the NOPTS guard and segments sharing one collapsed in the same-PTS replace; the decoder never saw the palette and object definitions and every set failed at its END segment ("Invalid palette id"). The store now reassembles armed streams' chunks into one self-contained entry at the PCS presentation PTS (opens on PCS, finalizes on END, drops mid-set backfill starts, bails on missing END, backward jumps, or a 16 MiB cap). Arming comes from the demuxer (PGS streams in an mpegts container) through both hosts' tap sinks; Matroska stays on the per-packet path, where the decoder's synthetic-END flush covers stripped ENDs.
- **iOS route-sharing policy no longer blocks host PiP (#116).** The shared `AVAudioSession` declared `.longFormAudio` on every platform. On iOS that marks the process a long-form audio client, which pins `AVPictureInPictureController.isPictureInPicturePossible` to `false` for any host-built PiP controller around the engine's player layer, and hosts could not durably re-declare against the engine's detached declaration (#114). The policy is now platform-split: tvOS keeps `.longFormAudio` (HDMI route negotiation, #24), iOS declares `.default`.
- **Dolby Vision first frame no longer waits out a fixed 5 s poll (#117).** `waitForSwitch()` polled `isDisplayModeSwitchInProgress` for a fixed 5 s and never watched the OS mode-switch notifications, so on panels where a DV switch is unobservable to the app (`currentEDRHeadroom` stays 1.0 and the in-progress flag never clears even though the panel visibly enters DV) it ran the full timeout every time, and `load()` waits twice. It now settles the instant the panel reports done (`AVDisplayManagerModeSwitchStart` / `End` notifications, or EDR headroom rising) and otherwise caps the wait at ~2 s. Measured DV first frame ~10 s to ~2 s on an unobservable panel; observable panels (HDR10 / HLG, or DV panels that post the notification) settle immediately. SDR / rate-only loads are unaffected, the wait already early-exits for them. Thanks to thatcube for PR #118.
- **`LoadOptions.httpHeaders` reaches the nativeRemoteHLS path (#119).** The remote-HLS bypass built its `AVURLAsset` without an options dictionary, silently dropping the headers, so header-enforcing IPTV origins (per-stream Referer / User-Agent / Authorization) answered 403 and those channels could not play at all. The headers now ride the asset via `AVURLAssetHTTPHeaderFieldsKey`, and the remote-HLS audio tap fetcher (#95) sends the same headers on its own playlist, segment, and AES-key requests. Loopback callers pass no headers and keep their default asset unchanged.
- **Pre-bound surfaces show video on `loadRemoteHLS` (#120).** The lean remote-HLS bypass assigned its host and early-returned without presenting the player layer, so a surface bound before load (the usual SwiftUI order: view appears, then the load task fires) never attached `playerLayer` and every remote-HLS live channel played audio over black video. The layer is now presented right after the host is assigned, mirroring `loadNative`; attach is idempotent, so host-reuse and post-bind cases are unaffected.

## [5.0.0] - 2026-07-09

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/5.0.0))

### Breaking

- **`setNativeSubtitleForPiP(_:)` renamed to `setNativeSubtitleRendering(_:)`.** The native WebVTT legible rendition is selected whenever the video leaves the host's own view hierarchy (a PiP window, an AirPlay receiver, or a wired external display, Sodalite#34), where the host on-frame overlay cannot draw. The old name implied PiP-only; the behavior is general. Pure rename, no behavior change.

### Changed

- **Embedded subtitle overlay pipeline reworked: packet tap replaces the side-demuxer readers (#112).** The overlay path used to open a second demuxer per selected embedded subtitle track and seek it around to reconstruct stateful PGS lines after seeks, fast-forwards, and audio switches. Eleven rounds of fixes hardened that model and it still regressed on index-starved remote sources (recovery north of 20 s). The producer now keeps every embedded subtitle stream it already demuxes and feeds them into `SubtitlePacketStore` (compressed retention, 300 s / 32 MB); a playhead-paced drainer decodes cues from the store at the playhead, running the same stale-arrival gate, successor trim, and retention rules as before. The software host feeds the store through its own tap. The side readers, their reuse pool, re-arm coalescing, condemned latch, and the cross-thread read-abort chain are deleted (~1350 lines); the native text-rendition readers (iOS WebVTT prefetch for PiP / AirPlay) remain. No extra connections, no reconstruction seeks: post-seek recovery is bounded by decode speed, not remote I/O. Includes the drainer forwarding cue-less PGS clear events so lines drop during silence, and the backscan running through the gate's reconstruction admission. One caveat carries over by design: a forward jump into never-watched, sparse-dialogue territory can still show a brief gap until the next composition, the same as mpv / VLC. Supersedes the interim per-seek reconstruction rounds that lived only between 4.12.1 and this release.

### Added

- **Buffered position for host scrub bars (#33).** `bufferedPosition` reports the disk cache's contiguous read-ahead frontier on the playlist axis for native direct play, so hosts can draw a buffered band ahead of the playhead.
- **Interlaced live TV: software deinterlace + DVB teletext (#107).** Interlaced H.264 routes to the software path with bwdif deinterlacing, and DVB teletext decodes through libzvbi into WebVTT cues. FFmpegBuild 1.0.5.
- **Cache-backed VOD scrub stills (#106).** Single-connection VOD sources render scrub thumbnails from the segment cache, the VOD twin of the live-TV path, instead of opening a second origin connection.
- **Remote-HLS audio tap delivery (#95).** `installAudioTap()` now delivers on the remote-HLS path (VOD and live): rendition/variant resolver, segment fetch + decrypt, self-contained TS/fMP4 decode, a playhead-follow reader, a monotonic gate trimming seam overlaps, and `audioTapHasDeliverySource` for host fail-loud. `aetherctl audiotap --remote` drives it.
- **Subtitle-preserving reduced-master fallback (#98).** Display-rejection fallback now stages master to reduced to media: the served reduced master keeps HDR and the subtitle renditions instead of dropping straight to a bare media playlist. `nativeSubtitleRenditionsServed` is published for the host external-subtitle window.
- **`SubtitleImage.canvasSize` (#112).** Bitmap cues carry their composition canvas size so hosts can map them onto the rendered video rect (defaulted parameter, source-compatible).
- **Stats surface.** Declared source video bitrate (with Matroska `BPS` fallback), nominal frame rate, audio bitrate, and bridge output are published for host stats overlays.

### Fixed

- **Multi-clip / multi-title Blu-ray timeline (#105).** Fold multi-clip titles on observed clip bases rather than MPLS inTime, rebase the playhead onto the 0-based display axis, defeat repeated-clip decoy playlists in title selection, trust the MPLS title duration, and follow the selected title for stills.
- **DV P5 still tone-map (#103).** The DV P5 still converter matches libplacebo's BT.2390 tone-map and applies the RPU reshaping curves.
- **Backward-scrub cold read reconnects fast (#93, #96).** The detour fetch a starved backward scrub rides is bounded to a ~4 s budget instead of waiting out the 15/35 s socket timeouts, and `markClosed` cancels the persistent connection.
- **Stall-recovery nudge reads the rendered frame (#115).** The stalled-consumer nudge re-reads the position at nudge time instead of reusing the pre-grace wedge capture, which skipped VOD playback backward on re-engage.
- **AVAudioSession hang-risk diagnostic from the engine constructor (#114).** `AetherEngine.init()` runs on the main actor, so its `setCategory(.playback, ...)` / `setSupportsMultichannelContent(true)` pair, both XPC round-trips to mediaserverd, executed on the main thread. The category is now declared on a detached task; every load path awaits it before the first activation, preserving issue #24's "declare early, never activate at init" contract.
- **Cold DV/HDR master start gates on real track readiness (#35),** falling back to media when the tracks never materialize, and the #65 backpressure wedge detector is suspended until the first rendered frame so a slow DV-master pre-roll is not treated as a wedge.
- **Scrub clock held through a wedged-restart recovery (#37 resurface, #93).**
- **Resolved content lengths shared across demuxer opens (#112).** `SourceContentLengthCache` lets an open whose size probe was starved under concurrent load (or 429'd) reuse an already-resolved length for the same origin and stay byte-seekable; a genuinely length-less source never populates the cache.
- **Synthetic PGS END flush gated on a complete object (#112),** clearing the "Invalid object id 0" decode noise on split m2ts.
- **Native legible renditions (Sodalite#38).** Host-managed native renditions never emit `FORCED=YES`, and the native legible selection stays deselected in fullscreen until the host explicitly selects it. The deselect is pinned unconditionally the moment the legible group loads and re-asserted on a 40 ms cadence for the first second, so a system caption preference no longer flashes cues for up to ~0.5 s at video start on iOS.
- **Wired HDMI external display keeps loopback + master (Sodalite#34).**

## [4.12.1] - 2026-07-05

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.12.1))

### Fixed

- **mov_text subtitle OOM on the host overlay (#104 follow-up).** 4.12.0 added the video/audio discard to the native PiP/AirPlay subtitle rendition path only. The tvOS host-overlay reader is a different side demuxer and still lacked the discard, so selecting an embedded text subtitle streamed the whole video and audio through a second connection just to reach the sparse subtitle samples, RSS climbing with playback position until jetsam (worst on files with many subtitle tracks). The overlay side demuxer now discards everything except the selected subtitle stream, so it fast-walks the index between cues with no video/audio I/O.

## [4.12.0] - 2026-07-05

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.12.0))

### Added

- **Opt-in decoded PCM audio tap (#95).** `installAudioTap()` streams playback audio as mono Float32 48 kHz `AVAudioPCMBuffer`s with source-PTS timestamps and discontinuity flags, for host-side speech/audio features (live transcription, ShazamKit). Native path decodes the engine's own loopback segments near the playhead (zero extra network, follows the active track, cannot stall playback); software path mirrors the existing PCM decode. New `aetherctl audiotap` verification command.
- **Configurable forward-buffer window (#102).** `LoadOptions.forwardBufferSegments` sets how many segments the native path buffers ahead (clamped 4...150); nil keeps the adaptive default, letting hosts trade memory for resilience on slow or unstable sources.
- **Dolby Vision profile exposed for stats (#103).** `SourceProbe.dvProfile` and the live `sourceDVProfile` publish the source's DV profile number (5 / 7 / 8 / 10), so hosts can label "Dolby Vision P5" without a separate probe.
- **CEA-608 as a native WebVTT rendition on iOS (#98).** Decoded 608 captions are bridged into the native rendition machinery, so they survive PiP and AirPlay through the existing WebVTT path.

### Fixed

- **Stall recovery lands at the requested seek target (#93 retest).** A user seek that wedges never lands, so the frozen AVPlayer clock still reports the pre-seek position (#37 semantics); the recovery chain then nudged and reloaded at that frozen position, silently losing the seek (user seeks to 341.9 s, recovery resumes at 391.9 s). The unlanded seek target now survives the wedge as recovery intent: the nudge and the stage-2 item reload aim at it. The intent retires when the seek lands (rendered output reaches the target's neighbourhood), when playback resumes elsewhere (AVPlayer abandoned the seek; a later unrelated stall must not teleport to a stale target), and on load reset / stop.

- **Single-digit wedge detection once the producer parks (#93 retest).** The VOD backpressure wedge was detected by a 24 s frozen-fetch-target counter alone, putting recovery latency at 30-70 s (reporter timings). The detector now has a fast path keyed on the signal pair the reporter's trace isolated: producer parked while the consumer's fetch target AND rendered clock are both frozen with intact play intent. Both frozen for 5 s breaks the park immediately; healthy steady-state playback (the clock advances between segment fetches) and post-seek decode ramps (clock flat but prefetch keeps advancing the target) never trip it. The 24 s counter remains as fallback when no clock signal is wired.

- **Producer re-anchor aims at the requested seek target too (#93 retest).** Both producer re-anchor sites (the seek-deadline reconcile and the wedge break) re-anchored at the frozen rendered position even while an unlanded user seek was pending, pulling the producer away from the target window its own seek restart had just anchored; the wrong-window refill could also evict the target's segments from retention (a follow-on cache-miss stall shape). All recovery stages, producer re-anchor, consumer nudge, and stage-2 reload, now share one anchor decision: pending seek target first, frozen position only when none is pending.

- **Dolby Vision Profile 5 / AV1 Profile 10.0 thumbnail colour (#103).** `FrameExtractor` software-decoded the IPT-PQ-C2 base layer and read its planes as BT.2020 YCbCr, producing a green / magenta cast. It now applies the Dolby Vision colour transform from the RPU metadata (the IPT-PQ matrices + PQ EOTF, then a Hable tone-map to SDR) on the CPU; no Apple still-image API (AVAssetImageGenerator, QuickLook) resolves this on its own, since the reshape runs only in the live display compositor. Playback was never affected. The per-frame reshaping curves are intentionally skipped, validated against a libplacebo reference render as not driving the visible corruption.
- **mov_text subtitle memory growth (#104).** The native subtitle side demuxer lacked `discardAllStreamsExcept`, so it streamed the whole video + audio program through a second reader just to harvest sparse mov_text packets; RSS scaled with playback position and freed on deselect. It now discards the non-subtitle streams before packet allocation.
- **Bridged-resume alignment and post-EOF revive (#99).** Bridge PTS rebase, post-EOF encoder rebuild, and a bounded VOD muxer-failed revive.
- **PGS catch-up burst suppression (#100).** Stale PGS arrivals are held for successor resolution instead of flashing on screen.
- **Reactive master to media fallback on display rejection (#98).** Routing falls back from a master to a media playlist when the display rejects the advertised codec; the obsolete P5 always-media-direct guard was dropped now that the engine emits a well-formed `dvh1.05` master.
- **macOS on-demand HDR master routing (#98).** macOS built-in panels count as engage-on-demand for HDR masters.
- **Bounded wedge-restart reopen (#93 residual latency).** The wedge-restart reopen is bounded to a finite byte range, cutting residual restart latency.

### Changed

- **SMB uses SMBClient (#97).** The NWConnection-based `SMBClient` replaces AMSMB2, so SMB shares work on tvOS / iOS (AMSMB2 hit EPERM). Support boundary is SMB 2.0.2 / 2.1.

### Removed

- **Dead in-band mov_text / tx3g subtitle muxing.** Native subtitles ship as a separate WebVTT rendition; the unused in-band muxing path was removed.

## [4.11.0] - 2026-07-03

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.11.0))

### Fixed

- **Post-recovery video judder (#93 residual).** The wedged-restart fresh reopen skipped `avformat_find_stream_info` entirely, so the reopened demuxer never resolved the video stream's B-frame reorder depth (`video_delay` stayed 0) and delivered matroska B-frame packets with NOPTS or presentation-ordered, non-monotonic dts. The producer's dts repair then telescoped sample durations or dropped every reordered frame it could not bump past the `dts <= pts` muxer invariant, so every region produced after a wedge recovery played with heavy sustained video judder while stream-copied audio stayed clean. The reopen now keeps `find_stream_info` under a bounded probe budget (4 MB / 5 s), which resolves the reorder depth from the first packets at a small bounded read cost.

- **Subtitle readers follow AVKit-side seeks (#93 residual).** PiP's skip buttons seek the AVPlayer directly and never pass through the engine's seek API, so the native subtitle readers kept reading forward from the old region after a far PiP skip; AVKit's selection burst then fetched empty `.vtt` windows for the new region and cached them permanently, leaving the PiP rendition blank until a fresh selection. A far rendered-time jump now schedules a debounced re-anchor: once the skip storm settles, readers outside the playhead's coverage restart at the new position and the remembered rendition selection replays, whose deselect/reselect busts the cached empty windows. The whole-program eager reader is left alone.

- **PiP survives the stage-2 recovery reload (#93 residual).** The reload's default item teardown paused the player and dropped the current item to nil before the fresh one existed; during Picture in Picture that nil-item gap invalidated AVKit's content source (the PiP window was dismissed shortly after an in-PiP recovery, leaving audio-only background playback) and the transport bounce burned the spurious-pause re-assert budget within milliseconds. The recovery reload now swaps items atomically (`inPlaceSwap`): observers are rewired, but transport intent, clocks and the old item stay alive until `replaceCurrentItem` hands AVPlayer the fresh one. Episode-switch reloads keep the pause-before-swap path (#15 waitForSwitch).

- **Pre-first-frame loader death now recovers (#93 startup).** A CoreMedia -15628 before playback ever started never posts `playbackStalled`, so the dead-consumer watchdog never armed and the session sat in an endless spinner (producer parking and re-anchoring forever). The -15628 errorLog now surfaces as a stall signal (the watchdog's fetches-frozen / waitingToPlay / item-healthy guards drop survivable transients), and the backpressure-wedge re-anchor path arms its own stage-2 item-reload escalation when the consumer stays silent after the nudge. The extractor yield gate also gained hysteresis: it opens only after several consecutive healthy 1 Hz buffer ticks, because a single post-load spike above the floor let a multi-megabyte warm pull through the exact window that killed the loader.

- **Active subtitles survive the stage-2 recovery reload (#93 residual).** The dead-loader item reload swaps AVPlayerItems, and legible selection is per-item, so an active native subtitle rendition silently disappeared (worst in PiP, where the rendition is the only subtitle path). The engine now remembers the host's last `setNativeSubtitleSelected` request and replays it onto the fresh item; a deselect clears the memory so a reload never resurrects subtitles the user turned off.

- **Session-coupled still extraction yields to a starved pipeline (#93 startup).** The scrub-preview warm-seed / chapter-thumbnail extraction opens its own demuxer and pulls megabytes over the same link the segment producer needs; at playback start on a marginal link that contention tipped the first segment past CoreMedia's ~4 s media timeout, the AVPlayer loader died (-15628) and the session played 1-2 s, stalled, and needed the stage-2 item reload. Extractors vended by `makeFrameExtractor()` (and the new `makeFrameExtractor(url:httpHeaders:)` overload for host-chosen still URLs, e.g. originals during a transcode) now yield elective thumbnail decodes while a producer restart is in flight or the consumer's forward buffer is under 3 s; snapshots and cache hits are never gated, and standalone `FrameExtractor(url:)` instances are unaffected.

### Added

- **`aetherctl pktdump`.** Raw video packet timing (dts / pts / duration, NOPTS and monotonicity stats, delta histograms) as delivered by the demuxer under a selectable open profile (`--profile playback|restartReopen|stillExtraction`). The differential between profiles is what isolated the #93 judder root cause; backed by the public `PacketTimingProbe`.

## [4.10.0] - 2026-07-02

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.10.0))

### Added

- **External subtitles as first-class tracks (#88).** External subtitle files register with the engine (`LoadOptions.externalSubtitles` at load, `addExternalSubtitleTrack` any time) and appear in `subtitleTracks` with a synthetic id and `isExternal == true`, selectable through the unified `selectSubtitleTrack` (primary and secondary). Load-declared tracks join the native WebVTT renditions (subtitles in PiP / AirPlay) via a whole-file store fill, and a finished store backfills the fullscreen overlay instantly on select. `preferredSubtitleLanguages` ranks external tracks too; a track added mid-session auto-activates only while the host has made no explicit subtitle choice. `removeExternalSubtitleTrack` unregisters.

- **Resume-anchored first producer (#93).** The first producer anchors at the segment covering the load's start position instead of producing seg0 into an immediate teardown; the seg0/resume fetch race could previously 404 the item into a host reload (double spinner, audio over a black frame).

### Fixed

- A pump-tap-fed subtitle selection kept forwarding cues into the overlay after switching to a sidecar file (stale tap-overlay stream index).
- **iOS HDR/DV master routing.** The master-vs-media gate required a tvOS-style panel-in-HDR signal, so every HDR/DV film on iPhone routed media-direct and PiP subtitles silently never worked for them; iOS now treats `AVPlayer.eligibleForHDRPlayback` as panel readiness.
- **Subtitle rendition names and selection.** Duplicate same-language rendition NAMEs collapsed AVFoundation's legible options, and the option matcher compared raw container tags against normalized language tags, selecting a wrong-language rendition in PiP. Names are unique now, forced tracks declare `FORCED=YES`, and matching goes through the ISO-synonym table with no cross-language fallback.
- **Backward-seek restart latency cluster (#93 residual).** The wedged-restart fresh reopen no longer re-pays the full first-open probe budget; waiting segment fetches ride an in-flight restart instead of burning fixed retry budgets into 503s; lazy native subtitle readers defer while a restart is executing instead of competing for the starved link. Fetch-fired restarts are now heavily guarded: a re-request for the index a restart just targeted waits for the fresh producer instead of tearing it down, an index the active producer's forward march covers never fires or backstops (a backstop re-fire killed a 75% complete capture on device), and a request superseded by a newer declared target (a skip-storm orphan AVPlayer has already abandoned) never fires at all.
- **Terminal stall self-recovery (#93 residual).** After a CoreMedia -15628 error AVPlayer's media loader can die silently: playbackStalled, then zero segment requests while waitingToPlay, and the item never fails, leaving an endless spinner only a manual back-out cleared. Every stall now arms a fetch-counter watchdog: a consumer still silent after a grace window gets a zero-tolerance nudge seek, and if the loader stays dead, an in-place item reload on the same host (AVKit, PiP, and Control Center survive; retention serves the reload instantly). A spurious `.paused` (rate 0, no wait reason, no user action) during recovery is re-asserted with play() instead of latched as a user pause, which previously suspended the producer's wedge breaker and parked the session forever.

## [4.9.1] - 2026-07-02

### Fixed

- **tvOS build.** The segment-retention free-space clamp queried `volumeAvailableCapacityForImportantUsage`, which does not exist on tvOS; tvOS now uses the plain `volumeAvailableCapacity` key.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.9.1))

## [4.9.0] - 2026-07-02

### Added

- **Native WebVTT subtitle renditions: subtitles survive PiP, AirPlay, and external display (Sodalite#32, #55).** Opt-in via `LoadOptions.prepareNativeSubtitles`: every text subtitle track is served as a language-tagged HLS `SUBTITLES` rendition over the loopback master (windowed per-video-segment WebVTT), exposed through AVFoundation's legible `AVMediaSelection` group. Renditions ship `DEFAULT=NO,AUTOSELECT=NO` so a host overlay never double-renders; hosts select per surface via `setNativeSubtitleSelected(track:)`, which now re-asserts automatically when AVFoundation drops a selection made during a stall recovery. Replaces the earlier mov_text/tx3g in-stream approach (in-band timed text is not HLS-conformant).
- **Subtitle pump tap: embedded text cues harvested from the producer's own read.** The segment producer keeps the text subtitle streams in its keep-set and hands their packets to a session-level decode tap (generalizing the CEA-608 tap), filling the per-track cue stores at zero side-channel bandwidth with coverage equal to the produced region, across seeks and restarts. The host overlay is fed from the same stores, so enabling embedded text subtitles is instant even on remote sources (previously a side demuxer had to open, seek, and read over the link); ASS markup is preserved for the styled overlay and stripped for the WebVTT renditions.
- **Byte-budgeted VOD segment retention: seeks into watched content no longer restart the producer (#93, Sodalite#32).** `SegmentCache` now keeps already-produced segments beyond its hard sliding window resident under a byte budget (2 GiB, clamped to a quarter of the tmp volume's free capacity; farthest-from-target evicted first once it fills), so a backward seek into the retained span, and the forward march after it, is served from cache with zero producer teardowns. This removes the demuxer re-seek that could wedge AVPlayer on slow sources after a backward seek (#93) and is the structural groundwork for PiP subtitles surviving seeks, since a producer restart detaches AVKit's legible renderer mid-session (Sodalite#32). Live sessions keep window-only pruning.

### Fixed

- **A teardown no longer caches a partial segment (VOD).** Every pump exit adopted the in-flight segment, including restart teardowns, caching content shorter than the playlist's EXTINF under a full segment's index (video and audio ending at different interleave-drain points). With retention such a segment became replayable: seeking back played it with ~2 s of A/V desync. VOD now adopts the in-flight segment only on a natural EOF (the tail is legitimately short); every other exit discards it and the next request re-produces it full-length. Live keeps adopting (its playlist advertises actual durations).
- **A producer restart now continues the fMP4 media timeline instead of zero-basing it (Sodalite#32, #93).** Every restart allocates a fresh mp4 muxer, and movenc zero-based each instance's timeline, so a restart-produced segment carried `tfdt=0` while the VOD playlist placed it at its plan offset: an implicit timeline discontinuity on every seek-restart. AVPlayer papered over it for plain playback, but it detaches AVKit's legible renderer mid-PiP (Sodalite#32) and matches the playhead/loaded-range decoupling signature (#93). The muxer now sets `movflags +frag_discont` with `avoid_negative_ts=disabled` so `tfdt` carries the producer's absolute output timestamps, the restart audio gate inherits the session shift (video shift rescaled, as head-of-stream always did) instead of snapping audio onto the video seam and off the source frame grid, and leading head-of-stream audio that would map below zero is dropped. A restarted segment is now byte-identical to its continuously-produced twin modulo the per-muxer `mfhd` sequence number, pinned by a new witness test on a committed A/V fixture; the init segment stays byte-identical across restarts. Head-of-stream audio also no longer has its first frame artificially stretched to absorb the intrinsic A/V offset; the true offset lands in `tfdt`.
- **E-AC-3/AC-3/TrueHD no longer wedge the fragmented-mp4 muxer on an out-of-cache backward seek (#94).** Under `+delay_moov` the mp4 muxer writes `moov` lazily on the first flush, and for AC-3/E-AC-3/TrueHD the audio sample entry (`dac3`/`dec3`/`dmlp`) can only be built from a parsed audio packet — so a first `moov` flush that fires video-only errors `-22` ("Cannot write moov atom before EAC3 packets parsed"), the segment cut fails, and the fresh muxer the producer builds at a backward-seek restart is retried forever (AVPlayer 503 → forever-loading spinner). `MP4SegmentMuxer` now latches at init whether the audio codec needs a parsed packet and, scoped to those codecs only, guards the #64 RAM-cap interim flush and proactively primes `moov` with the first audio packet. AAC and every other codec keep the stock path (no early flush, full RAM-cap bound), so there is no audio-dropout regression.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.9.0))

## [4.8.0] - 2026-06-30

### Added

- **Unified `playbackPhase` as the playback-status source of truth (#85).** A published `playbackPhase` enum replaces ad hoc status flags, with a typed `.stalled(reconnecting:)` case and a typed `onNetworkPhaseChanged` reader callback wired across the native, software, and audio hosts.
- **Software-path background audio on iOS.** Software-decode playback keeps audio alive when the app backgrounds, via a background-audio-only demux loop and a wedge-safe keepalive policy. Exercised by the new `aetherctl bgaudio` harness.
- **`aetherctl segverify`.** A deterministic, headless probe that decodes each loopback segment in isolation and reports whether it is independently decodable (the segment-independence ground truth used to verify #92).
- **`aetherctl --throttle-kbps`.** Slow-CDN simulation for `serve` / `segverify`, to reproduce backpressure and recovery behaviour under a bandwidth cap.

### Fixed

- **Open-GOP and B-frame VOD segments decode cleanly after a fresh decode (#92).** VOD segment cutting is now keyframe-gated in decode order (the IRAP opens its own segment, like the live path and FFmpeg's hls muxer), so a rebuffer or seek landing on a segment boundary no longer starts mid-GOP with a decode dependency on its predecessor. This removes the transient blocky corruption on reordered content.
- **A bunched keyframe index that spans under one segment is rejected (#91).** Such an index passed the gap check but produced a single whole-file segment that AVPlayer rejected with no tracks; the planner now also requires the index to span at least one target segment, else it falls back to a uniform plan.
- **No black flash on a software-path seek (#90).** The software path holds the last displayed frame across a seek instead of blanking the display before the post-seek keyframe.
- **No audio crackle on software-decode playback (#89).** Software-decode audio buffers are stamped from a gapless running sample clock, fixing a per-frame click on frames that do not land on integer-millisecond boundaries.
- **No multi-second startup stall on remote PGS subtitles (#87).** The subtitle side demuxer skips `find_stream_info` and reads the codec from the header or PMT, with a bounded fallback, removing the blocking probe at load.
- **Correct HDR and Dolby Vision format label in Stats for Nerds on iOS.**

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.8.0))

## [4.7.0] - 2026-06-29

### Added

- **AirPlay (#86).** The in-process loopback HLS is served over the device's active LAN IP with the media playlist forced while AirPlay external playback is active, so the receiver gets the engine-processed stream (Dolby Vision / Atmos / subtitles preserved) instead of a master it would reject.
- **iOS background playback.** A wedge-safe background keepalive policy plus a PiP and background-playback API for hosts, so native-path iOS playback survives backgrounding and Picture-in-Picture.
- **Experimental native WebVTT subtitles (gated).** A WebVTT `SUBTITLES` rendition served over the loopback so text subtitles can reach PiP / AirPlay via `AVMediaSelection`, opt-in behind `LoadOptions.prepareNativeSubtitles` and inert by default (reliable display through a custom-transport player is still open, #55).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.7.0))

## [4.6.3] — 2026-06-27

### Fixed

- **A remote ISO no longer recognizes the disc twice at startup (#76).** The 4.6.2 cache stopped the per-switch re-open, but the reporter still saw the disc open twice before playback began. The probe demuxer opens the source with no explicit title (`selectTitleID == nil`) and caches the recognition under that key, while the rest of the engine references that same title by its resolved id (the default resolves to title index 0, and `DiscTitle.id == index`): background reloads and the subtitle side demuxer pass the concrete id, never nil. The side demuxer's first open therefore missed the probe's cache entry and re-ran the full UDF / `.mpls` parse, the second "disc tray" open before the first cue. `DiscReader.storeRecognition` now aliases the entry under the resolved selected index when it differs from the requested id, so the nil-probe recognition is hit by the concrete-id lookup. Disc recognition runs once per session; the subtitle side demuxer still attaches its own (probe-capped) demuxer for the bitmap-subtitle stream, which is decoded out-of-band from a separate context by design, but no longer re-recognizes the disc in front of it.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.6.3))

## [4.6.2] — 2026-06-27

### Changed

- **Subtitle and audio track switches on a remote ISO no longer re-open the source (#76).** Selecting a subtitle track, switching audio, or seeking re-opened a demuxer, and every open re-ran disc recognition: the UDF / ISO9660 directory parse plus a read of every `.mpls` (Blu-ray) or `.IFO` (DVD) over HTTP. On a disc with dozens of playlists that round-tripped many times per switch, which the reporter saw as the "disc tray" reopening on each subtitle change. Two changes remove it. (1) `DiscReader.wrap` now memoizes the parsed disc structure (title list + clip extents) per source URL and selected title, so a reopen rebuilds only the cheap concat reader and skips the directory re-parse; the main pump, the subtitle side demuxer, and the audio reload share one cache, so recognition runs once per session. (2) For URL sources the subtitle side demuxer is retained per source + title and reused across track switches and seeks: the open container is re-seeked to the new playhead and re-pointed at the new stream index, with no re-open or re-probe. A successor reader hands off from its predecessor before touching the shared demuxer, so they never read it concurrently. Custom sources (SMB) still open per switch but benefit from the recognition cache.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.6.2))

## [4.6.1] — 2026-06-27

### Fixed

- **Hardened the 4.6.0 in-band CEA-608 closed-caption path (#77).** Two robustness fixes from post-merge review. (1) The `ClosedCaptionTap` decoded on the producer pump thread with no lock, on the assumption of a single pump. The restart path abandons an old pump after a 5 s join timeout (`HLSVideoEngine.performRestart`), so an abandoned pump can briefly overlap the new one calling into the same tap, racing the (not-thread-safe) `CEA608Decoder` and the cue buffer. The tap now guards its decode state with a lock, mirroring `NativeSubtitleCueStore` (#55); worst case during the rare overlap is a few garbled cues that self-correct on the next reset / EOC. (2) Seeking with closed captions active left the pre-seek caption on screen until the next caption decoded, because the CC seek path reset the tap but did not clear the mirrored cues. It now clears them immediately, symmetric with the side-demuxer subtitle path.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.6.1))

## [4.6.0] — 2026-06-27

### Added

- **In-band CEA-608 closed captions from a demuxable caption track, rendered through the host overlay (#77).** A source whose only caption track is an embedded CEA-608 stream (`eia_608`, e.g. a QuickTime/MP4 `c608` track) previously could not render: FFmpegBuild ships no `ccaption` decoder, so the side-demuxer `EmbeddedSubtitleDecoder` open failed and the track sat active-but-blank (`subActive=true / subCues=0`). The engine now reads that caption track's `cc_data` off the segment producer's existing source connection: a read-only observer keeps the `eia_608` stream in the demuxer's keep-set, hands each of its packets to an external `ClosedCaptionTap`, then drops it (never muxed → the loopback-HLS segment output is byte-identical to the no-CC path). An in-house CEA-608 decoder (pop-on / roll-up / paint-on, PAC row addressing, mid-row codes, and the basic / special / extended West-European character sets; odd-parity validation, doubled-control suppression and the character / PAC tables validated against FFmpeg's `ccaption_dec.c`) turns the bytes into cues published on the same `subtitleCues` host-overlay path as every other side-decoded subtitle codec. Because the tap owns the cue buffer and rides the producer (re-threaded onto every restart via `makeProducer`), captions appear instantly on enable (no second demuxer, no extra connection) and survive seek / reload / wedge. The native `mov_text` rendition (#55) is untouched: CC is excluded from that path (it can't become `tx3g`) and rendered through the overlay like the bitmap subtitle codecs, so (as with those) it is host-overlay only (no PiP / AirPlay CC). First cut: 608 field-1 / channel CC1; CEA-708 (DTVCC) and field 2 are follow-ons. Thanks to DrHurt for the externalise-subtitles steer.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.6.0))

## [4.5.7] — 2026-06-27

### Fixed

- **On macOS the video image slid off-center during a live window resize, snapping back centered once the drag ended (#80).** The hosted video `CALayer` was added as a sublayer with no autoresizing mask, so its frame only caught up on the next `layout()` pass, a frame behind the continuously-changing view `bounds` during the drag. Because an `NSView`'s backing layer is anchored bottom-left, that one-pass lag read as the image drifting off-center while resizing. The layer now gets a flexible autoresizing mask (`[.layerWidthSizable, .layerHeightSizable]`) in the AppKit branch, so Core Animation stretches it in lockstep with the superlayer's bounds on every frame; initialized to full bounds, it starts and stays full-bounds (and centered) throughout. AppKit-only branch, so iOS/tvOS are untouched, and no effect on decode, timing, or audio. Reported by reckloon from a downstream consumer (Ocelot).

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.5.7))

## [4.5.6] — 2026-06-27

### Fixed

- **A video file silently degraded to the audio-only backend when its open-time probe lost to a transient origin error (#78).** When the probe open hit a rate-limit (a 429 whose body parsed as `AVERROR_INVALIDDATA`), the engine logged `probe failed (...); proceeding without criteria` and then routed a 4K HEVC VOD to the audio-only path: audio played, no picture for the rest of the session, Live state showing `Backend audio, resolution 0x0`. Root cause was a conflation of "probe failed" with "file has no video": on probe failure `hasVideoStream` was false not because the file lacked video but because we never looked, and `shouldUseAudioOnlyPath` read that as no-video and dispatched `audio dispatch: codec=0 -> FFmpeg`. Once connections recovered the demux open enumerated `stream[0] type=video codec=hevc 3840x2160` (the audio-only decision was already locked in). The audio-only path is now reserved for an explicit `audioOnly` request or a *successful* probe that genuinely found no video. A failed probe on a non-audioOnly URL source falls through to the native video path (custom and live sources already fail-fast on a failed probe), so `HLSVideoEngine` reopens the source and discovers the stream. Reported by the AetherPlayer community.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.5.6))

## [4.5.5] — 2026-06-27

### Fixed

- **Selecting an embedded subtitle on a network ISO (Blu-ray / DVD over http) never showed cues, while the same disc worked from a local ISO (#76).** The embedded subtitle side-demuxer logged `embedded subtitle reader exited (cancelled=true) packetsRead=0`: it was superseded by a seek / title switch / re-select before it read a single packet. The open was glacially slow on a remote disc. It re-opened with the full 50 MB / 60 s probe, and the disc's sparse `hdmv_pgs_subtitle` streams never resolve codec parameters, so `find_stream_info` read to the full 50 MB over http chasing them (the #75 pattern). It then ran the MKV cue-index prewarm seek (`duration × 0.5`), a cold range read to the middle of a 32 GB ISO that buys nothing for a concat MPEG-TS / VOB disc. Together the open ran tens of seconds; locally both are instant, so it only failed over http. `EmbeddedSubtitleDecoder` needs only codec id / type (carried in the container header / MPEG-TS PMT and resolved by the open itself) and seeds bitmap canvas dims from the source video size, so the full chase is pure cost. The side-demuxer now caps its probe to 4 MB / 5 s (honouring an even tighter caller budget), skips the cue-index prewarm seek for disc sources, and opens the same BD/DVD title the user is watching rather than always title 0. Applied to both the inline reader and the native multi-decode (#55) reader. Reported by the AetherPlayer community.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.5.5))

## [4.5.4] — 2026-06-26

### Fixed

- **Resuming or seeking into a wide-interleave progressive MP4 desynced audio ~1 s ahead of video (#74 follow-up).** The 4.5.1 fix buffered pre-video-gate audio only at head-of-stream, so first-frame playback is in sync, but a mid-file seek/resume on a source that muxes audio ahead of video in file order still drifted. On a restart the demuxer lands before the video keyframe and scans forward to it; the audio that matches the keyframe is muxed earlier in the file, so it is read during that scan while the audio gate is still closed and was dropped. The post-gate restart-target filter then snapped the next (~1 s-later) audio onto the keyframe, putting audio ahead of picture (reporter trace: `audio gate open: actual=44112896 target=44064064 gapMs=1017.3`). The producer now buffers pre-gate audio on a VOD restart as well, not just head-of-stream, so the same restart-target filter selects the matching packet from the `[target, …]` window and the gate opens at `gapMs ≈ 0`. Live restart keeps the original drop (its program-boundary re-anchor handles audio separately); the buffer stays bounded by the existing 8 MB cap, and normal-interleave seeks are unaffected. Reported and root-caused by reckloon.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.5.4))

## [4.5.3] — 2026-06-26

### Fixed

- **A rapid scrub burst could leave the loopback-HLS VOD producer permanently anchored away from the playhead (#79).** The 4.2.2 seek-deadline recovery reconciles the engine clock to AVPlayer's real rendered position and re-anchors the segment producer there. Under a sustained bidirectional scrub burst on a bridged-audio title that re-anchor was routed through the burst-coalescing restart path (#35), where a later coalesced scrub target overwrote it, so the producer settled at the stale scrub position (~3914 s) while the clock sat at the rendered position (~5577 s), a ~1660 s gap AVPlayer could never close, leaving it starved with no recovery. The recovery re-anchor is now *authoritative*: computed from AVPlayer's real position, it wins the coalescer's pending slot over any in-flight scrub target (a newer authoritative re-anchor still supersedes an older one), so the producer ends where the clock was reconciled to. The backpressure wedge breaker uses the same authoritative path; live segment-loss reopen is unaffected. Separately, when a restart found the old producer wedged in a blocking network read on the shared demuxer (which `stop()` cannot interrupt), the new producer queued behind that read for the full ~20 s connection-stall timeout (a ~25 s restart). On the single-demuxer VOD path the engine now opens a fresh demuxer, aborts the wedged read, and hands the fresh demuxer to the new producer, which also frees the wedged reader's buffers promptly instead of after 20 s. Thanks to reckloon for the frame-exact trace and the root-cause analysis.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.5.3))

## [4.5.2] — 2026-06-26

### Fixed

- **A user pause was misread as a backpressure wedge, deadlocking the loopback-HLS VOD path (#65).** The 4.2.2 wedge-breaker re-anchors the producer when the consumer's fetch target freezes. A paused AVPlayer freezes that target legitimately (it issues no forward fetch by design), so a pause longer than ~24 s on a bridged-audio loopback-HLS title (TrueHD, DTS-HD MA, or any codec that routes through the FLAC/EAC3 bridge) tripped the breaker. The re-anchor loop then ran against a player that cannot advance, exhausted its attempts, and left the producer re-anchored ahead of a buffer stranded behind the playhead, a state resume could not recover (force-quit required). Wedge detection now gates on play intent: it tracks `timeControlStatus` and suspends while the player is paused, so a pause of any length never trips it and the window after resume starts fresh. A genuine starved wedge (the player wants to play but is buffer-starved, `waitingToPlay`) still trips, and the seek-deadline reconcile gets the same pause guard so a paused scrub is not mistaken for a starved seek. Thanks to rrgomes and reckloon for the independent captures and the precise root-cause analysis.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.5.2))

## [4.5.1] — 2026-06-26

### Fixed

- **Head-of-stream audio muxed ahead of video was dropped, causing a constant ~1 s A/V desync (#74).** On the native loopback-HLS path the producer's audio gate dropped every audio packet that arrived before the first video packet. On a wide-interleave source (audio muxed ~1 s ahead of video in file order, e.g. a progressive MP4 whose leading second of AAC precedes the first video packet) that discarded the entire leading second of real audio, so AVPlayer pulled the survivors forward into a constant ~1 s lag (the same file stays in sync in VLC / Infuse). The producer now buffers that pre-gate audio (bounded by an 8 MB cap) and replays it in DTS order once the video gate opens, so it flows through the normal target-filter / anchor / write path. Scoped to head-of-stream; restart and seek producers keep the original drop, where the post-gate shift already anchors their surviving audio. Thanks to reckloon for the report and the corrected root-cause analysis.

- **An unresolvable cover-art stream made remote open read to the full probe budget (#75).** A remote MP4 carrying an embedded cover-art stream (mjpeg reported as 0x0) kept `avformat_find_stream_info` reading toward `probesize` (tens of MB pulled over the network) trying to resolve codec parameters that never resolve, even though the real H.264 + AAC streams were available almost immediately. Attached-picture streams are now reclassified to `AVMEDIA_TYPE_ATTACHMENT` before stream-info probing, so they resolve instantly and the probe stops once the real streams are known. Cover-art extraction is unaffected (it reads the attached picture plus the unchanged disposition). Thanks to reckloon for the report.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.5.1))

## [4.5.0] — 2026-06-26

### Added

- **Subtitle-language pick ranks by container disposition; `TrackInfo` surfaces forced / SDH / commentary (#73).** `LoadOptions.preferredSubtitleLanguages` (4.4.0) activated the first track in a matching language. It now activates the *best* track within the first matching preference: full subtitles rank over SDH (`HEARING_IMPAIRED`), forced, and commentary (`COMMENT`), and text over bitmap, all from container dispositions; preference order still dominates rank. New `TrackInfo.isForced` / `isHearingImpaired` / `isCommentary` (read alongside the existing `isDefault`) surface those dispositions for audio and subtitle tracks, so a host can rank or filter `subtitleTracks` the same way. The pure `selectSubtitleIndex`, `subtitlePickRank`, and `isBitmapSubtitleCodec` helpers are exposed and unit-tested.

### Fixed

- **Bitmap subtitles leaked into the native `mov_text` rendition (#55).** With `prepareNativeSubtitles` set, two sites matched `TrackInfo.codec` (the libavcodec *decoder* name, e.g. `pgssub`) against an exact-match set of *descriptor* names (`hdmv_pgs_subtitle`, `dvb_subtitle`, `dvd_subtitle`, `xsub`), so PGS / DVB / DVD bitmap tracks were not excluded (only `xsub` matched by coincidence). They leaked into the `mov_text` trak table and the native-store-attach set, producing phantom entries in the `AVMediaSelection` legible group and a store/reader index mismatch. Both sites now use a shared decoder-name `isBitmapSubtitleCodec` classifier that agrees with the reader's enum classifier, so only true text tracks become native `mov_text` traks.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.5.0))

## [4.4.0] — 2026-06-26

### Added

- **First-frame subtitle selection by language preference (#73).** A host with a saved subtitle-language preference had to read the post-load `subtitleTracks` and language-match `selectSubtitleTrack` itself. New `LoadOptions.preferredSubtitleLanguages` (ordered; ISO 639-1 / 639-2 codes or English names, e.g. `["en", "de"]`; default empty) lets the engine activate the first subtitle track whose language matches a preference (preferences scanned in order, case-insensitive, ISO 639-1/2 B+T and English-name synonyms) at the end of a successful load, mirroring the audio twin (`preferredAudioLanguages`, #72). No match leaves subtitles off (the default). The host-overlay path is used (equivalent to a `selectSubtitleTrack` call), the resolved track is published via the new `activeSubtitleTrackIndex` (parity with `activeAudioTrackIndex` so a picker reflects it), and the side demuxer is anchored at the resume position (clamped to the probe duration) instead of byte 0. Unlike `preferredAudioLanguages` (whose track is muxed into the loopback HLS at the first frame, so a late pick forces a pre-probe or reload), this is pure convenience: subtitles are activated post-load by a side demuxer at no reload or pre-probe cost, so it only spares a host from language-matching `subtitleTracks` itself. Independent of `prepareNativeSubtitles`, whose default selection stays host-driven via `setNativeSubtitleSelected`. Empty preferences is a behavioral no-op, so nothing changes until a host opts in. The audio half of #73 already shipped in 4.3.0. Thanks to reckloon for the request.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.4.0))

## [4.3.0] — 2026-06-26

### Added

- **First-frame audio selection by language preference (#72).** A host that wants a saved audio-language preference honored on the first frame previously had to open the source an extra time to pick the track (an audio pre-probe) or reload via `selectAudioTrack` after load. Each extra open re-runs `avformat_open_input` + `find_stream_info` + the size probe, multiplying pre-first-frame latency and request volume against a remote source. New `LoadOptions.preferredAudioLanguages` (ordered; ISO 639-1 / 639-2 codes or English names, e.g. `["en", "de"]`; default empty) lets the engine resolve the audio track from its single internal probe: an explicit `audioSourceStreamIndex` still wins, else the first track matching a preference in order (case-insensitive, ISO 639-1/2 B+T and English-name synonyms), else the container default. The resolved index drives the played audio on both the native and software paths. Empty preferences with no override is a behavioral no-op, so nothing changes until a host opts in; a probe-failed source still honors an explicit override verbatim. The engine already reuses its single probe demuxer as the session demuxer, so honoring the preference here removes the remaining redundant open for the prefer-a-language case. Thanks to reckloon for the request and the staged-reuse framing.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.3.0))

## [4.2.3] — 2026-06-26

### Fixed

- **Redundant open-time size probe on remote HTTP sources (#70).** `AVIOReader.open()` fired a dedicated `probeFileSize()` round-trip (a `Range: bytes=0-0` GET, falling back to HEAD) before opening the real data connection, even though that connection's own `Range: bytes=0-` request returns a 206 whose `Content-Range` already carries the total. On origins that omit a length for `bytes=0-0` the probe also paid a second HEAD round-trip, and that HEAD was the request some origins rate-limited (429), dropping an otherwise-fine source into seekless streaming mode. The playback path now derives the size from the first data connection's response (206 `Content-Range`, or `Content-Length` on a from-0 2xx), so the common case skips the probe entirely; live skips it too (its result was discarded anyway and it burned the Range timeout on transcode endpoints that reject Range). When the data connection resolves no size (a genuinely length-less origin, a transient 429, slow response headers, or a length only reachable via HEAD), the open falls back to the exact prior probe path on a separate connection and budget, so seekability is preserved whenever a size is reachable and only a truly length-less source streams. The size is now folded in under the connection's existing lock, and the remaining still-extraction probe switches `bytes=0-0` to `bytes=0-` for the same one-shot win. Thanks to reckloon for the diagnosis and the confirmed `bytes=0-` probe shape.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.2.3))

## [4.2.2] — 2026-06-26

### Fixed

- **Loopback-HLS VOD scrub-burst livelock (#65).** A sustained bidirectional scrub burst on the native (loopback-HLS) direct-play path could deadlock playback: the engine clock latched at an optimistic seek target AVPlayer never physically reached, while the segment producer parked on backpressure with no VOD watchdog. The two halves waited on each other with no recovery floor, so the picture froze 30 to 40 seconds behind the reported clock and never recovered. Two coupled fixes give the path a recovery floor. The native VOD seek await is now bounded by a cadence budget: when a seek does not land and AVPlayer is genuinely starved (no forward buffer), the engine reconciles its clock to AVPlayer's real rendered position instead of the unreachable target and re-anchors the producer there, while a slow-but-buffering seek still awaits its real landing unchanged. And the VOD backpressure park now has the watchdog the live paths always had: a consumer fetch target frozen past a threshold breaks the park and re-anchors the producer on AVPlayer's real position (a slow-but-advancing consumer never trips it, and a storm guard bounds re-anchors if AVPlayer never resumes). Thanks to rrgomes for the frame-exact trace that pinned the root cause.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.2.2))

## [4.2.1] — 2026-06-26

### Fixed

- **Persistent AVIOReader reconnect storm on a non-faststart / coarsely-interleaved remote MP4 (#69).** A remote MP4 with a trailing `moov` and track data tens of MB apart makes the demuxer ping-pong across distant file regions during `avformat_find_stream_info` / index parse. The persistent reader used to tear down and reopen its HTTP connection on every such non-sequential read, so the parse storm drove the origin into a 429 and playback never started. Those random-access reads now go through the existing pooled keep-alive session, cached as 4 MB aligned blocks in a small LRU (8 blocks, roughly 32 MB, VOD-only), so the streaming connection stays anchored and the storm collapses to the two legitimate reconnects (open plus the one seek to the moov). The sequential playback fast path never enters the cache, so it carries no overhead; only full-length blocks are cached, so a truncated range response cannot shadow the re-fetch of its uncovered tail; and once detour reads turn sequential past 8 MB the streaming connection re-anchors there, returning steady playback (and large backward scrubs) to the cheap sliding-window path. Thanks to reckloon for the detailed diagnosis and the validated detour-cache design.
- **Reconnect loop under a sustained 429 (#71).** When an origin rate-limited essentially every request, the reader looped reconnecting (gen=N climbing) instead of failing cleanly: a 429 carried no `Retry-After` so the backoff was zero, and the random-access parse seeks kept resetting the unproductive-reconnect streak before it reached the give-up cap. A 429/503 now drives a separate rate-limit streak that the seek-driven reconnects do not reset and that only real read progress clears, so a throttled origin gives up cleanly after a bounded number of attempts, with exponential backoff that grows even when no `Retry-After` is present. The detour cache's miss-under-429 fallback backs off in place and retries the pooled fetch rather than opening a fresh connection, so it cannot re-enter the churn the cache removes.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.2.1))

## [4.2.0] — 2026-06-26

### Added

- **Caller-bounded demux probe budget per `load()` (#68).** A large remote remux with sparse streams (HDMV PGS subtitles, an mjpeg cover attachment) makes `avformat_find_stream_info` read to the full internal probe budget (50 MB / 60 s) on every open, costing roughly 13-14 s before the first frame over a slow CDN even though the video and audio streams resolve almost immediately. That budget is tuned for local disk, where reading 50 MB is free, and a remote caller had no way to cap it. Two optional `LoadOptions` fields now let a caller cap the open-time probe, both defaulting to `nil` so nothing changes unless set: `probesize` (bytes, maps to `AVFormatContext.probesize`) and `maxAnalyzeDuration` (microseconds, maps to `AVFormatContext.max_analyze_duration`). The cap is applied to every main-playback open that runs `find_stream_info` (the routing probe that becomes the session demuxer, the software and audio fallback opens, the audio/title-switch reopens so a switch does not re-incur the cost, and the native HLS fallback open and live reopen) and only to those: the subtitle side-demuxer, the routing `probe(url:)` API, the Dolby Vision probe, still extraction, and the live companion-audio demuxer all keep the full budget because a complete probe is load-bearing there (sparse PGS / DVB track detection). An over-tight budget fails open (a late-resolving track is silently missing), not closed; `maxAnalyzeDuration: 0` is FFmpeg's shorter heuristic, not "no cap". Both trade-offs are documented on the fields. Internally, `DemuxerOpenProfile.withProbeBudget(probesize:maxAnalyzeDuration:)` overrides only the two probe knobs and leaves the AVIO tuning untouched.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.2.0))

## [4.1.0] — 2026-06-25

### Added

- **Disc title and chapter selection for DVD-Video and Blu-ray (#67).** A disc image now exposes every selectable title and the chapters of the playing title, and the host can switch between them. `engine.discTitles` lists the titles (Blu-ray playlists / DVD title sets, longest first so id 0 is the main feature) with each one's duration and chapter count; `engine.selectedDiscTitle` is the active one; `engine.selectTitle(id:)` switches title, rebuilding from the new title's head (the selection survives audio-track switches and background resume, and a fresh `load` defaults to the main title). `engine.discChapters` carries the selected title's chapters and `engine.selectChapter(id:)` seeks to one (a thin seek, no pipeline rebuild). Blu-ray titles and chapters come from the MPLS playlists and their PlayListMark entries; DVD titles, durations, and chapters come from the VMGI TT_SRPT and each title set's program chain (whole-VTS resolution, per-cell / episodic splitting deferred). Chapter starts are title-relative and `selectChapter` rebases them onto the playback clock (the native playlist shift, or the software path's container start PTS) so the seek lands. A new `discTitleID` parameter on `load` opens a disc straight to a chosen title, and `aetherctl disc-inspect` prints the full title + chapter list for a local image.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.1.0))

## [4.0.7] — 2026-06-25

### Added

- **Remote disc images (ISO 9660 / UDF / Blu-ray BDMV) over HTTP(S) (#64).** A local `.iso` is routed through the disc adapter, but the HTTP open path fed the source straight to libavformat, which fails to probe a disc image (it is a filesystem, not a media container) and returned an error, so network ISO playback never worked. New `HTTPDiscIOReader` is a seekable reader over an http(s) disc image using byte-range requests (the remote twin of the local file reader): it probes total size and range support up front and serves reads from an adaptive sliding read-ahead window (small for the scattered disc-structure reads at open, growing while playback stays sequential), with per-request retry/backoff so a transient blip does not end playback. `openHTTP` now routes a disc-image URL (`.iso` / `.img` / `.udf`) through the disc adapter exactly like the local path, and falls back to the streaming reader when the source is not a recognizable disc (so a mislabeled `.iso` still plays). The server must support byte ranges; if it does not, the reader logs why and falls back. Gated on the extension so normal media URLs keep the optimized streaming open with no probe cost.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.0.7))

## [4.0.6] — 2026-06-25

### Fixed

- **DTS-HD Master Audio on a Blu-ray (MPEG-TS / M2TS) played silent (#64).** The bundled FFmpeg build (FFmpegBuild) enables a minimal parser allow-list, and it was missing the `dca` parser. On a byte-stream container the demuxer needs a codec's parser to assemble a complete frame; without `dca`, the MPEG-TS demuxer handed the decoder the DTS core (`0x7FFE8001`) and the following DTS-HD extension substream (`0x64582025`) as two separate packets, so every extension frame was rejected with "Residual encoded channels are present without core" and the track was silent. Matroska was unaffected because its blocks are already whole frames (only the `.m2ts` path was silent), which is why the same disc remuxed to MKV, or its audio extracted with `ffmpeg -c copy`, decoded fine. Fixed by bumping to FFmpegBuild 1.0.3, which enables `dca` and, in the same pass, the other parsers missing for already-bundled decoders: `mlp` (TrueHD/MLP), `vc1` (VC-1 video), and `dvbsub` / `dvdsub` (DVB and DVD bitmap subtitles), so the same framing class cannot bite TrueHD or VC-1 on M2TS either. No engine code change.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.0.6))

## [4.0.5] — 2026-06-25

### Fixed

- **A Blu-ray whose content starts late played nothing until you seeked past the start (#64 follow-up).** The 4.0.4 disk-fill fix routes a sparse MPEG-TS keyframe index to the uniform-stride segment plan, but that plan anchored its source-axis boundaries at PTS 0. On a title whose first keyframe is well after zero (one real disc starts at 11.6s) the leading segments covered source time that has no frames, so the producer never emitted them while the playlist still advertised them, and the player's first-segment fetch was permanently out of range (it just kept restarting the producer). Playback only worked after seeking past the content start. The uniform plan now anchors its boundaries at the first keyframe (falling back to the video stream start time), exactly like the keyframe-aligned plan, so segment 0 begins at the content start. No public API change.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.0.5))

## [4.0.4] — 2026-06-25

### Fixed

- **A Blu-ray (MPEG-TS / M2TS) source could fill the device disk and play neither video nor audio (#64).** MPEG-TS carries no upfront keyframe table the way Matroska Cues or MP4 `stss` do, so the VOD segment planner only saw the handful of keyframes that `avformat_find_stream_info` plus the mid-file prewarm seek happened to index (on a long title: one near the start, a cluster near the seek point). The keyframe-aligned planner trusted that sparse, clustered list whenever it had at least two entries and built a degenerate plan whose first segment spanned the whole gap (a 110 minute title produced a single ~3288 second segment). The fragmented-MP4 muxer runs with `+frag_custom`, so it emits a fragment only at an explicit segment cut; with one enormous segment it buffered nearly the entire title in libavformat's interleaver before any flush, which grew to multiple gigabytes that the device compressed and swapped until the disk filled, and `+delay_moov` kept `init.mp4` empty until that first flush so the player got no video either. Two fixes, both engine-internal: (1) the planner now rejects a keyframe index whose largest inter-keyframe gap exceeds `max(targetSegmentDuration * 4, 30)` seconds and falls back to the uniform-stride plan (regular ~4 second segments); (2) the muxer now caps how much it buffers within any one segment, force-flushing a fragment into the current file once the buffered video span exceeds ~2 segment durations (the same drain the cut uses, without rotating the file), which bounds memory on any long segment regardless of plan shape and also populates `init.mp4` promptly so video starts. No public API change.

### Known limitations

- On the same disc, the default DTS-HD Master Audio track decodes to no audio: its frames code the lossless extension as a residual on top of the core, which libavcodec's DCA decoder cannot reconstruct, so the bridge skips them. The fix above restores video; selecting one of the disc's AC3 tracks gives audio. The DTS-HD MA case is tracked separately.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.0.4))

## [4.0.3] — 2026-06-25

### Fixed

- **Enabling subtitles could freeze or badly slow the scrub-preview (trickplay) thumbnails (#27).** On-device scrub thumbnails are produced by an independent still-extraction pipeline that opens its own connection to the source and runs on a single serial decode queue. Its remote-source chunk read could park on a flat ~35s timeout with no way to cancel it, so a single stalled read froze the queue and pinned the preview on one frame while further scrubs queued behind it. Turning subtitles on is what triggered it: that spins up a third reader (the subtitle side-demuxer, opened with the persistent playback profile and a 90s read-ahead) which competes with the thumbnail reader for the source's bandwidth and the device's cores, lengthening the cold reads into the park; with subtitles off the reads return promptly and the preview tracks the scrub. Interlaced 480p MPEG-2 made it worse because that codec is software-decoded, so playback already held the cores. The still-extraction reader now aborts an in-flight fetch within ~100ms when a scrub supersedes it (or on teardown), bounds each decode with a short read deadline, fails fast (one retry instead of three across two URLs), and the thumbnail decoder is capped to two threads at `.utility` QoS so it can no longer starve the real-time software playback decode. Engine-internal change; no public API change. The playback and live read paths are untouched.

- **Dead live remote-HLS streams froze silently instead of retuning.** When a live IPTV/HLS source stopped delivering segments (segment 404s or an expired auth token), the native player's `failedToPlayToEnd` was only logged and the item stayed `readyToPlay`, so no terminal error reached the host and the automatic live retune never fired (the picture just froze). Remote-HLS `failedToPlayToEnd` is now routed through deferred-confirmation into a terminal error (gated to remote-HLS live only), so the host's live retune kicks in.

### Diagnostics

- Added a positive content-vs-clock ledger and a VOD backpressure-wedge probe to keep instrumenting the #65 post-seek-burst frame-drift investigation.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.0.3))

## [4.0.2] — 2026-06-25

### Fixed

- **DTS-HD Master Audio lost its lossless XLL extension in FLAC bridge mode (#66).** The 4.0.1 fix routed every DTS source through the `dca_core` bitstream filter, stripping each packet to its lossy DTS core before the decoder. For DTS-HD MA streams that decode the full lossless XLL cleanly, that downgraded `.lossless` (FLAC) output to lossy 5.1, audible for hosts bridging to a multichannel-LPCM AVR. The bridge now decodes the full stream again (DTS-HD MA reconstructs the lossless XLL as S32P, re-encoded bit-perfectly to FLAC), and keeps the per-packet `EINVAL` skip that handles the rare residual-XLL-without-core frame (#64). It also re-derives the resampler input format from each decoded frame (the canonical libswresample contract, matching the software audio decoder), so a stream whose `sample_fmt` was unresolved at decoder open, or a bailed live probe, can no longer misread the decoded samples as the seed format. The `dca_core` filter is simply no longer used; no FFmpegBuild change is required.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.0.2))

## [4.0.1] — 2026-06-24

### Fixed

- **DTS-HD Master Audio still failed to bridge after the 3.13.4 core-only attempt (#64).** 3.13.4 opened the `dca` decoder with `core_only=1` to skip the lossless XLL extension, but on Blu-ray the DTS core is carried as an asset inside the extension substream (EXSS), not as a standalone core sync, so `core_only` made libavcodec report "No valid DCA sub-stream found" and emit no audio (it even printed "Consider disabling 'core_only'"). The bridge now runs DTS through the `dca_core` bitstream filter, which strips each DTS-HD (MA / HRA) packet to its mandatory core at the bitstream level, so the decoder only ever sees full-rate 5.1/7.1 core PCM and never attempts the XLL reconstruction that residual-codes channels without a usable core. Falls back gracefully to the full decode path (with single-packet EINVAL skipping) if a build lacks the filter. Requires FFmpegBuild 1.0.2 (which enables `dca_core`).

## [4.0.0] — 2026-06-24

### Added

- **End-of-media is now surfaced to hosts as `PlaybackState.ended` (#63).** Each playback host already tracked `didReachEnd`, but the engine consumed it internally and collapsed the public surface to `.idle`, indistinguishable from pre-load or `stop()`. Hosts that want end-of-playback behavior (mark-watched, autoplay-next, dismiss) could only work around it on the native path by observing the handed-out `AVPlayer` for `AVPlayerItemDidPlayToEndTime`; on the software-decode path there is no public `AVPlayer`, so there was no recourse at all. The engine now has a dedicated terminal state, `PlaybackState.ended`, set on end-of-media across every backend (native / software / audio); `stop()` still goes to `.idle`. `.ended` is terminal: `seek` / `togglePlayPause` are no-ops, and the next `load(...)` clears it.

### Breaking

- **`PlaybackState` gains a `.ended` case.** Adding a case to a (non-frozen) public enum is source-breaking: an exhaustive `switch` over `PlaybackState` that lacks an `@unknown default` no longer compiles until it handles `case .ended`. This is the only breaking change in 4.0.0 and the reason for the major bump; it ships as a major precisely so `from:`-pinned adopters opt into it deliberately rather than being broken on a routine `swift package update`. Migration: add `case .ended` (run end-of-playback handling) wherever you previously treated `.idle` as end-of-media, and keep `.idle` for pre-load / stopped.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/4.0.0))

## [3.13.4] — 2026-06-24

### Fixed

- **DTS-HD Master Audio failed to bridge ("Residual encoded channels are present without core", #64).** When the audio bridge decoded a DTS-HD MA / HRA track (common on Blu-ray remuxes), the libavcodec `dca` decoder rejected many frames with `EINVAL` because their lossless XLL extension uses residual coding that cannot reconstruct standalone, so the bridge produced no audio for those frames. The bridge re-encodes to lossy EAC3 (or FLAC) and discards the XLL refinement anyway, so it now decodes the mandatory DTS core only (`core_only`), which reconstructs full-rate 5.1/7.1 PCM on every frame. No effect on plain DTS core streams.
- **UDF reader follows allocation-extent continuations (tag 258).** A file whose allocation descriptors overflow its (E)FE chains the rest through an Allocation Extent Descriptor (extent type 3). The reader now follows that chain (depth-bounded) instead of treating the continuation pointer as a bogus data extent. Defensive: inline descriptors already cover ~114 GiB per file, so no current Blu-ray needs it, but a heavily fragmented title would otherwise under-resolve.

([release notes](https://github.com/superuser404notfound/AetherEngine/releases/tag/3.13.4))

## [3.13.3] — 2026-06-24

### Fixed

- **Music Now Playing crashed on tvOS 26 with embedded cover art.** The bare-AVPlayer audio Now Playing path crashed on tvOS 26 (`dispatch_assert_queue_fail`) when a track carried embedded artwork: the system harvested and decoded the asset's embedded cover off the expected queue, and a non-Sendable artwork closure ran off its actor. The engine now follows Apple's recommended path, an auto-publishing `MPNowPlayingSession` with per-item `AVPlayerItem.nowPlayingInfo` instead of manual `MPNowPlayingInfoCenter` writes or `externalMetadata`, with writes gated on item readiness to avoid the serial-queue crash during item swaps, and the audio is wrapped in a metadata-free composition so the system never decodes the asset's (sometimes corrupt) embedded artwork.
- **Blu-ray ISO playback failed for every real UDF 2.50 disc image (#62).** The UDF reader found the volume anchor and parsed the volume structure, but listing the root directory returned nothing, so no `BDMV` was found, `DiscReader.wrap` returned `nil`, and the raw image fell through to a plain FFmpeg open that reports `AVERROR_INVALIDDATA`. The cause was a partition-reference bug: a metadata-resident file entry's `short_ad` allocation descriptors were resolved against the physical partition. A `short_ad` carries no partition reference, so it is relative to the file entry's own recording partition; for a metadata-partition entry that means metadata-virtual blocks resolved through the Metadata File. The root directory data lives in the metadata partition, so the wrong sectors were read. `short_ad` now resolves against the file entry's own partition (`long_ad`, which carries an explicit reference for the physical m2ts payload, was already correct). Verified end to end against the Blender Sintel Blu-ray ISO.
- **Audio bridge pipeline diagnostics label ordered as "source -> bridge"** so the logged stage order reads correctly.

### Changed

- **The video decoder frame-handler contract is now `@Sendable`,** hardening the off-actor decode callback for Swift 6 strict concurrency.
- **Bumped FFmpegBuild to 1.0.1 (FFmpeg n8.1.2).**

### Added

- **`AetherEngine.inspectDisc(url:)` plus `aetherctl disc-inspect [--dump]`.** An FFmpeg-free, stage-by-stage walk of a local disc image (ISO9660/UDF signatures, UDF root and BDMV tree, parsed `.mpls` playlists, selected main title, resolved m2ts extents) that reports exactly where recognition bails. `DiscReader` also emits gated `[disc]` diagnostics on the playback path so a future failure is debuggable instead of a silent `nil`.

### Documentation

- **Live MPEG-TS sliding-window and DVR rewind marked device-confirmed** in the formats documentation.

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
