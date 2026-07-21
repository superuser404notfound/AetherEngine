import Foundation
import CoreGraphics

/// The playback state of a `AetherEngine` instance.
public enum PlaybackState: Sendable, Equatable {
    /// No session: pre-load, or torn down via `stop()`. Distinct from `.ended` (see below).
    case idle
    case loading
    case playing
    case paused
    case seeking
    /// The source played to completion on its own. Terminal, like `.idle`, but reached by reaching
    /// end-of-media rather than by `stop()`. Surfaced on every backend (native / software / audio) so a
    /// host can run end-of-playback handling (mark-watched, autoplay-next, dismiss) without observing the
    /// AVPlayer directly, which is impossible on the software-decode path (#63). Cleared by the next
    /// `load(...)`. Transport calls (`seek`, `togglePlayPause`) are no-ops here; reload to replay.
    case ended
    case error(String)
}

/// Internal rendering backend. Exposed read-only for diagnostic overlays; hosts must not branch on this value.
public enum PlaybackBackend: String, Sendable, Equatable {
    case none
    /// Removed in 1.0.0; reserved for hosts that still switch on it.
    case aether
    /// HLS-fMP4 over loopback to AVPlayer + AVPlayerLayer. Default for HEVC / H.264 / VP9.
    case native
    /// FFmpeg / dav1d + AVSampleBufferDisplayLayer. Used for AV1 on tvOS (no HW decoder).
    case software
    /// FFmpeg audio + AVSampleBufferAudioRenderer. No video pipeline.
    case audio
}

/// What playback is doing right now, as one observable (#85). Derived from `state`, `isBuffering`,
/// `isSeeking`, and the reader network phase, so it can never desync from them. Observe `$playbackPhase`
/// instead of stitching `state == .loading` + `$isBuffering` + `$isSeeking` together, and instead of
/// regex-matching `EngineLog` for stall/reconnect, which is no longer necessary.
///
/// `.stalled(reconnecting:)` reports a source-connection problem (drop / 429 / 503 backoff) distinct from
/// `.rebuffering` (a healthy-connection buffer underrun). The associated value is `true` whenever the
/// reader is retrying; a future "stalled, retries paused" distinction will surface as `false` without
/// changing the case. Not available on the direct AVPlayer-HLS live path (no demuxer / reader): a reconnect
/// there reads as `.rebuffering`.
public enum PlaybackPhase: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case rebuffering
    case stalled(reconnecting: Bool)
    case ended
    case error(String)
}

/// Source-fetch network axis feeding `PlaybackPhase` (#85). Binary today; `.reconnecting` covers the
/// `AVIOReader` stall / drop / backoff loop, `.flowing` covers normal delivery.
enum ReaderNetworkPhase: Sendable, Equatable {
    case flowing
    case reconnecting
}

extension PlaybackPhase {
    /// Pure fold of the four playback axes into one phase, with fixed precedence
    /// (highest first): error > ended > idle > loading > seeking > stalled > rebuffering > playing/paused.
    static func derive(state: PlaybackState,
                       isBuffering: Bool,
                       isSeeking: Bool,
                       stall: ReaderNetworkPhase) -> PlaybackPhase {
        switch state {
        case .error(let message): return .error(message)
        case .ended:              return .ended
        case .idle:               return .idle
        case .loading:            return .loading
        case .playing, .paused, .seeking:
            if isSeeking { return .seeking }
            if stall == .reconnecting { return .stalled(reconnecting: true) }
            if isBuffering { return .rebuffering }
            return state == .paused ? .paused : .playing
        }
    }
}

/// Static snapshot of what the current display can present. Single source of truth shared with the host.
public struct DisplayCapabilities: Sendable, Equatable {
    public let supportsHDR: Bool
    public let supportsDolbyVision: Bool
    public let supportsHDR10: Bool
    public let supportsHLG: Bool

    public init(supportsHDR: Bool, supportsDolbyVision: Bool, supportsHDR10: Bool, supportsHLG: Bool) {
        self.supportsHDR = supportsHDR
        self.supportsDolbyVision = supportsDolbyVision
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
    }
}

/// Deinterlacer selection for the software-decode path (interlaced MPEG-2 / VC-1 / MPEG-4, and
/// interlaced H.264, which routes software because AVPlayer does not deinterlace, #107 /
/// `VideoRoutingPolicy`).
public enum DeinterlaceMode: String, Sendable, Equatable {
    /// yadif_videotoolbox (Metal compute over VideoToolbox frames) when the linked FFmpeg build
    /// ships it AND a Metal device exists at runtime; otherwise falls back to software bwdif.
    /// The hardware path also skips the sws_scale copy: the filter sink emits IOSurface-backed
    /// CVPixelBuffers that go straight to the renderer.
    case auto
    /// Force the software bwdif/yadif path (previous engine behavior).
    case software
}

/// Output cadence of the HARDWARE deinterlacer (`DeinterlaceMode.auto` when the hw graph engages).
/// The software fallback always runs frame-rate: doubling sws_scale + CPU bwdif for field-rate
/// output is the wrong trade without the GPU, and a fallback should not change cost class.
public enum DeinterlaceFieldRate: String, Sendable, Equatable {
    /// One output frame per FIELD (25i -> 50p, 29.97i -> 59.94p): full temporal resolution,
    /// smoother motion. Default for the hardware path.
    case field
    /// One output frame per FRAME (25i -> 25p): halves filter output, matches the sw path.
    case frame
}

/// Options for `AetherEngine.load(url:options:)`. All flags default to safe values.
public struct LoadOptions: Sendable, Equatable {
    /// Diagnostic lever: omit BT.2020 / transfer / YCbCr matrix from AVDisplayCriteria so AVPlayer re-reads color from the bitstream. Default off.
    public var omitCriteriaColorExtensions: Bool
    /// Skip display-criteria handshake entirely. For previews and `aetherctl` where no panel exists. Default off.
    public var suppressDisplayCriteria: Bool
    /// Extra HTTP headers for HEAD probe, Range chunks, side-demuxer fetches. On the loopback paths they are NOT forwarded to AVPlayer (it hits the local server); on `nativeRemoteHLS` they ride into the AVURLAsset so header-enforcing origins (IPTV Referer / User-Agent / Authorization) work (#119). Forwarded to `selectSidecarSubtitle` by default; pass explicit headers to override (#32). Default empty.
    public var httpHeaders: [String: String]

    /// Diagnostic lever: force dvh1 codec tags + master playlist regardless of display capability. OFF by default: non-DV displays route DV through the media playlist (no master) so AVPlayer auto-tonemaps the HEVC base layer (only path that avoids AVFoundationErrorDomain -11868 on tvOS 26). AetherEngine#4.
    public var keepDvh1TagWithoutDV: Bool

    /// Mirror of `AVDisplayManager.isDisplayCriteriaMatchingEnabled`. Default `true`. When `false`, engine routes HDR sources through the media playlist (auto-tonemap path) because AVKit cannot switch the panel.
    public var matchContentEnabled: Bool

    /// Mirror of `UIScreen.main.currentEDRHeadroom > 1`. Default `false` (conservative SDR branch). When in HDR, master playlist VIDEO-RANGE=PQ and SUPPLEMENTAL-CODECS=dvh1 are accepted upfront for the HDR10-to-DV upgrade.
    public var panelIsInHDRMode: Bool

    /// Bridge encoder for codecs that cannot stream-copy into fMP4 (TrueHD, DTS, DTS-HD MA, MP3, Opus, EAC3-from-MKV-without-dec3-extradata).
    ///
    /// - `.surroundCompat` (default): EAC3 128 kbps/ch. Works on soundbars (Sonos Arc, Samsung HW-Q, Bose). Lossy; caps 7.1 to 5.1.
    /// - `.lossless`: FLAC up to 7.1. Needs a sink that accepts multichannel LPCM (Denon / Marantz / NAD AVRs); stereo-only routes silently downmix.
    public var audioBridgeMode: AudioBridgeMode

    /// Treat the source as a live stream. `seek(to:)` becomes a no-op; `isLive` surface reflects this for host UIs. Set explicitly: auto-detection from `probe.durationSeconds == 0` is too noisy (VOD MKVs with broken duration headers). Default `false`.
    public var isLive: Bool

    /// Lean audio-only path (FFmpeg + AVSampleBufferAudioRenderer): skips video probe, display-criteria handshake, HLS/muxer/loopback stack. Also set automatically when the probe finds no video stream. Default `false`.
    public var audioOnly: Bool

    /// DVR rewind window in seconds; nil = live-only (seek is a no-op). Engine retains roughly this much past content disk-backed. Suggested default: 1800. Ignored when `isLive == false`. Default nil.
    public var dvrWindowSeconds: Double?

    /// LL-HLS blocking-reload (`#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD`) override for live loopback sessions.
    /// nil (default) = auto: for a `LiveIngestSourceInfo` custom reader the engine derives eligibility from
    /// the OBSERVED upstream arrival cadence (off until sustained discipline is proven, permanently off once
    /// a burst is seen), so a relay/IPTV origin that advertises a normal TARGETDURATION but delivers segments
    /// in irregular batches no longer loops on `-15410`; for a plain-`url:` live source with no cadence signal
    /// (e.g. a Jellyfin real-time transcode) it stays on. `true`/`false` force it regardless of cadence. The
    /// TARGETDURATION floor still tracks observed cadence either way. Ignored for `nativeRemoteHLS` and VOD.
    /// Default nil (AetherEngine#167).
    public var liveBlockingReload: Bool? = nil

    /// AVPlayer item from the remote URL directly (Jellyfin live `master.m3u8`): no demuxer probe, no loopback. AVPlayer manages live edge / reconnect. Pair with `isLive: true`. Default `false`.
    public var nativeRemoteHLS: Bool

    /// Reroute a live `nativeRemoteHLS` session onto the loopback live-ingest path when AVPlayer reaches
    /// readyToPlay but never builds a video track for a master that advertises one. That signature means
    /// the master delivers HEVC in MPEG-TS segments, which AVFoundation's HLS demuxer does not support
    /// (the HLS Authoring Spec sanctions HEVC only in fMP4); the ingest path remuxes TS to fMP4 and plays
    /// the same stream. Live-only (VOD remote HLS is the AE#154 reroute target). `httpHeaders` ride along
    /// onto the ingest fetches. Default `true` (AetherEngine#168).
    public var nativeRemoteHLSIngestFallback: Bool

    /// Emit raw ASS event lines (`ReadOrder,Layer,Style,...,Text` including override tags) instead of plain-text extraction. Opt-in for hosts that render ASS styling themselves; pair with `TrackInfo.assHeader`. Only affects ASS / SSA codecs. Default `false` (AetherEngine#30).
    public var preserveASSMarkup: Bool

    /// Declare a mov_text track in the init moov so text subtitles survive PiP / AirPlay / external display via AVMediaSelection. Bitmap codecs (PGS / DVB / DVD) excluded automatically. Default `false` (#55).
    public var prepareNativeSubtitles: Bool = false

    /// Start the native WebVTT subtitle readers eagerly at load (instead of lazily on `setNativeSubtitleSelected`), so the `/subs_N_M.vtt` segments are already populated when AVKit fetches them under a host-independent selection (e.g. an `EXT-X-MEDIA ... DEFAULT=YES` rendition that AVKit auto-selects). Equivalent to a fully-populated static VOD subtitle file. Only meaningful with `prepareNativeSubtitles`. Default `false` (Sodalite#32 probe).
    public var eagerNativeSubtitleReaders: Bool = false

    /// Preferred subtitle languages (ISO 639-1/2) used ONLY to choose which native WebVTT rendition is marked DEFAULT=YES in the master, so a host-selected legible track renders (AVKit hides a non-default legible selection as mute-only). Read back as `nativeSubtitleDefaultOrdinal`. Unlike `preferredSubtitleLanguages` this does NOT auto-activate the host-overlay subtitle path, so it won't double up with the native render. Default empty (Sodalite#32).
    public var nativeSubtitlePreferredLanguages: [String] = []

    /// Caller-bounded demux probe budget in bytes, mapped to `AVFormatContext.probesize` for the main playback open. nil keeps the engine default (50 MB). A smaller value speeds `find_stream_info` on slow remote sources whose sparse streams (PGS, mjpeg cover art) would otherwise read to the full budget. An over-tight budget fails OPEN, not closed: `find_stream_info` still returns success with a logged warning, so the session loads with late-resolving tracks silently missing rather than throwing a load error. The value is written to the context verbatim (FFmpeg's AVOption floor of 32 is bypassed), so validate track presence after load if you set this aggressively. The routing `probe(url:)` API and still extraction keep the full budget; the embedded subtitle side-demuxer caps its own probe (it only needs codec ids, not resolved sparse tracks) and tightens to this value when it is smaller (#76). Default nil (#68).
    public var probesize: Int64?

    /// Caller-bounded demux probe budget in microseconds, mapped to `AVFormatContext.max_analyze_duration` for the main playback open. nil keeps the engine default (60 s). Pass a positive value to set an explicit cap; do NOT pass `0` expecting "no cap": FFmpeg maps `0` to a container-dependent heuristic (~5-7 s for MPEG-TS, longer elsewhere) that is SHORTER than the engine's 60 s default. Same scope and fail-open trade-off as `probesize`. Default nil (#68).
    public var maxAnalyzeDuration: Int64?

    /// Ordered audio-language preference (ISO 639-1 / 639-2 codes or English names, e.g. `["en", "de"]`). When non-empty and no explicit `audioSourceStreamIndex` is passed to `load`, the engine resolves the first-frame audio track from its single internal probe: the first track whose language matches an entry (preferences scanned in order, case-insensitive, ISO 639-1/2 B+T and English-name synonyms), falling back to the container default when none match. This lets a host honor a saved language preference on the first frame from one open, instead of probing separately or reloading via `selectAudioTrack` after load (#72). An explicit `audioSourceStreamIndex` still wins. Default empty.
    public var preferredAudioLanguages: [String]

    /// Ordered subtitle-language preference (ISO 639-1 / 639-2 codes or English names, e.g. `["en", "de"]`).
    /// When non-empty, at the end of a successful load the engine activates the best subtitle track whose
    /// language matches a preference (preferences scanned in order, case-insensitive, ISO 639-1/2 B+T and
    /// English-name synonyms; within the matched preference, full subtitles rank over SDH / forced /
    /// commentary and text over bitmap, from container dispositions); no match leaves subtitles OFF (the
    /// default). This drives the host-overlay
    /// path (`subtitleCues`, equivalent to a `selectSubtitleTrack` call) and publishes the resolved track
    /// via `activeSubtitleTrackIndex`. Where `preferredAudioLanguages` saves a real cost (its track is muxed
    /// into the loopback HLS at the first frame, so a late pick forces a pre-probe or reload), this is pure
    /// convenience: subtitles are activated post-load by a side demuxer at no reload or pre-probe cost, so it
    /// only spares a host from language-matching `subtitleTracks` itself. A later host `selectSubtitleTrack`
    /// / `clearSubtitle` overrides
    /// it. Independent of `prepareNativeSubtitles`, whose default selection stays host-driven via
    /// `setNativeSubtitleSelected`. Default empty (#73).
    public var preferredSubtitleLanguages: [String]

    /// External subtitle files to register at load (AetherEngine#88). Each appears in
    /// `subtitleTracks` (id = `externalSubtitleTrackIDBase` + array index, `isExternal == true`),
    /// participates in `preferredSubtitleLanguages` ranking, and, with `prepareNativeSubtitles`,
    /// joins the native WebVTT rendition (PiP). Tracks added later via `addExternalSubtitleTrack`
    /// are overlay-only until the next load. Default empty.
    public var externalSubtitles: [ExternalSubtitleTrack]

    /// Forward-buffer window of the loopback HLS session, in segments (one segment ~ 4 s): how far the
    /// producer may race ahead of the playhead AND how many forward segments the on-disk cache keeps
    /// resident (the two are coupled by construction, see `SegmentCache`). Larger values buffer more of
    /// the source up front (network-dropout robustness) at the cost of disk (segments are disk-backed,
    /// mmap reads) and ahead-of-time demux work: 4K HEVC runs ~ 10 MB per segment, so 150 segments can
    /// occupy ~ 1.5 GB on disk. The engine clamps to 4...150 (below 4 AVPlayer's own ~ 5-7-segment
    /// prefetch would starve, see `LiveWindowSizing.minSafeSegments`). nil keeps the historical default
    /// of 10 (~ 40 s). Ignored for `nativeRemoteHLS`, where AVPlayer talks to the remote server directly.
    public var forwardBufferSegments: Int?

    /// Autostart at load completion. Default `true`: every load path ends in `host.play()` and a
    /// `.playing` state (current behavior, byte-identical). Set `false` to mount PAUSED: a host that
    /// holds a pause at mount (synchronized-start lobby that loads several devices and starts them on
    /// a signal, or a hold-at-mount / resume prompt) no longer eats an engine-initiated resume it has
    /// to claw back. With `false` the load skips the terminal `host.play()` (and, on the native VOD
    /// path, the SDR->HDR cold-start readiness gate, which is an autostart-path recovery), leaves
    /// `playIntent` false, and settles `.loading -> .paused` via the existing `host.$isReady`
    /// waypoint; the host resumes later with `play()`. Same declared-vs-real family as #122/#123 (#124).
    public var autoplay: Bool = true

    /// Teletext caption page for `dvb_teletext` subtitle decode. nil (default) = libzvbi auto-detect
    /// (`txt_page=subtitle`); an explicit page (e.g. 801 for AU) targets channels whose caption page
    /// libzvbi does not flag as a subtitle page. Only affects teletext streams (#107).
    public var teletextPage: Int? = nil

    /// Deinterlacer for the software-decode path: `.auto` (default) tries the Metal/VideoToolbox
    /// hardware graph and falls back to software bwdif; `.software` forces the CPU path. See
    /// `DeinterlaceMode`.
    public var deinterlaceMode: DeinterlaceMode = .auto

    /// Cadence of the hardware deinterlacer: `.field` (default) doubles output to field rate
    /// (50/60 fps), `.frame` keeps frame rate. Ignored by the software fallback (always frame
    /// rate). See `DeinterlaceFieldRate`.
    public var deinterlaceFieldRate: DeinterlaceFieldRate = .field

    /// ENGINE-INTERNAL: marks this load as a live REJOIN (`reloadAtCurrentPosition`). Not settable from the public initializer. When true, the native load path skips its explicit initial seek so AVPlayer picks edge-minus-holdback (see `LiveReloadPolicy`); without it the reloaded item can wedge in `waitingToPlay` against Jellyfin's re-served backlog. Meaningful only when `isLive` is true.
    var isLiveRejoin: Bool = false

    /// ENGINE-INTERNAL (#170): subtitle session state a session-preserving reload
    /// (`reloadAtCurrentPosition`) carries into this load. Not settable from the public
    /// initializer. When present, the #88 registration point seeds the previous session's
    /// external registry id-exactly instead of re-registering `externalSubtitles`, and the
    /// host's subtitle authority flag carries over. Consumed by the load; never persisted.
    var subtitleSessionCarryover: SubtitleSessionCarryover? = nil

    public init(
        omitCriteriaColorExtensions: Bool = false,
        suppressDisplayCriteria: Bool = false,
        httpHeaders: [String: String] = [:],
        keepDvh1TagWithoutDV: Bool = false,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLive: Bool = false,
        audioOnly: Bool = false,
        dvrWindowSeconds: Double? = nil,
        liveBlockingReload: Bool? = nil,
        nativeRemoteHLS: Bool = false,
        nativeRemoteHLSIngestFallback: Bool = true,
        preserveASSMarkup: Bool = false,
        prepareNativeSubtitles: Bool = false,
        eagerNativeSubtitleReaders: Bool = false,
        nativeSubtitlePreferredLanguages: [String] = [],
        probesize: Int64? = nil,
        maxAnalyzeDuration: Int64? = nil,
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        externalSubtitles: [ExternalSubtitleTrack] = [],
        forwardBufferSegments: Int? = nil,
        autoplay: Bool = true,
        teletextPage: Int? = nil,
        deinterlaceMode: DeinterlaceMode = .auto,
        deinterlaceFieldRate: DeinterlaceFieldRate = .field
    ) {
        self.omitCriteriaColorExtensions = omitCriteriaColorExtensions
        self.suppressDisplayCriteria = suppressDisplayCriteria
        self.httpHeaders = httpHeaders
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.audioBridgeMode = audioBridgeMode
        self.isLive = isLive
        self.audioOnly = audioOnly
        self.dvrWindowSeconds = dvrWindowSeconds
        self.liveBlockingReload = liveBlockingReload
        self.nativeRemoteHLS = nativeRemoteHLS
        self.nativeRemoteHLSIngestFallback = nativeRemoteHLSIngestFallback
        self.preserveASSMarkup = preserveASSMarkup
        self.prepareNativeSubtitles = prepareNativeSubtitles
        self.eagerNativeSubtitleReaders = eagerNativeSubtitleReaders
        self.nativeSubtitlePreferredLanguages = nativeSubtitlePreferredLanguages
        self.probesize = probesize
        self.maxAnalyzeDuration = maxAnalyzeDuration
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.externalSubtitles = externalSubtitles
        self.forwardBufferSegments = forwardBufferSegments
        self.autoplay = autoplay
        self.teletextPage = teletextPage
        self.deinterlaceMode = deinterlaceMode
        self.deinterlaceFieldRate = deinterlaceFieldRate
    }
}

/// Detected video dynamic range format. `hdr10Plus` shares the HDR10 base layer with `hdr10`; the distinction is the per-frame ST 2094-40 metadata forwarded via `kCMSampleAttachmentKey_HDR10PlusPerFrameData`. Both map to PQ + BT.2020 in AVDisplayCriteria; the split is for badge accuracy.
public enum VideoFormat: Sendable, Equatable {
    case sdr
    case hdr10
    case hdr10Plus
    case dolbyVision
    case hlg
}

/// One-shot container + stream metadata from `AetherEngine.probe(url:options:)`. No HLS server, no decoders.
public struct SourceProbe: Sendable {
    public let url: URL
    /// 0 for live streams / pipes.
    public let durationSeconds: Double
    /// `.sdr` when no HDR signaling or no video track.
    public let videoFormat: VideoFormat
    /// FFmpeg AVCodecID raw value; 0 (AV_CODEC_ID_NONE) when no video track.
    public let videoCodecID: Int32
    /// Codec name from libavcodec (e.g. "hevc", "h264", "av1"). nil when unavailable.
    public let videoCodecName: String?
    /// 0 when no video track.
    public let videoWidth: Int32
    /// 0 when no video track.
    public let videoHeight: Int32
    /// Snapped to a standard rate (23.976, 24, 25, ...). nil when not advertised.
    public let videoFrameRate: Double?
    public let isDolbyVision: Bool
    /// Dolby Vision profile number (5, 7, 8, 10) read from the dvcC/dvvC configuration record; nil when not DV.
    public let dvProfile: Int?
    public let audioTracks: [TrackInfo]
    /// Includes both text and bitmap (PGS / DVB) variants.
    public let subtitleTracks: [TrackInfo]
    public let metadata: MediaMetadata
    /// Heuristic: no duration + network scheme (http / https / udp / rtp / rtsp). False positives possible (VOD MKVs with broken duration). Hosts decide the final `LoadOptions.isLive`.
    public let isLive: Bool

    public init(
        url: URL,
        durationSeconds: Double,
        videoFormat: VideoFormat,
        videoCodecID: Int32,
        videoCodecName: String?,
        videoWidth: Int32,
        videoHeight: Int32,
        videoFrameRate: Double?,
        isDolbyVision: Bool,
        dvProfile: Int? = nil,
        audioTracks: [TrackInfo],
        subtitleTracks: [TrackInfo],
        metadata: MediaMetadata = MediaMetadata(title: nil, artist: nil, album: nil, artworkData: nil),
        isLive: Bool = false
    ) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.videoFormat = videoFormat
        self.videoCodecID = videoCodecID
        self.videoCodecName = videoCodecName
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrameRate = videoFrameRate
        self.isDolbyVision = isDolbyVision
        self.dvProfile = dvProfile
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.metadata = metadata
        self.isLive = isLive
    }
}

/// Result of `AetherEngine.swDecodeProbe(url:)`. Distinguishes open-failure, open-but-no-frames, and healthy decode without a render layer.
public struct SoftwareDecodeProbeResult: Sendable {
    public let codecName: String
    public let codecID: Int32
    public let width: Int32
    public let height: Int32
    public let openSucceeded: Bool
    public let openError: String?
    public let packetsRead: Int
    public let packetsFedToDecoder: Int
    public let framesDecoded: Int
    public let firstFramePixelFormat: String?
    public let firstFrameWidth: Int
    public let firstFrameHeight: Int
    public let firstError: String?

    public init(
        codecName: String,
        codecID: Int32,
        width: Int32,
        height: Int32,
        openSucceeded: Bool,
        openError: String?,
        packetsRead: Int,
        packetsFedToDecoder: Int,
        framesDecoded: Int,
        firstFramePixelFormat: String?,
        firstFrameWidth: Int,
        firstFrameHeight: Int,
        firstError: String?
    ) {
        self.codecName = codecName
        self.codecID = codecID
        self.width = width
        self.height = height
        self.openSucceeded = openSucceeded
        self.openError = openError
        self.packetsRead = packetsRead
        self.packetsFedToDecoder = packetsFedToDecoder
        self.framesDecoded = framesDecoded
        self.firstFramePixelFormat = firstFramePixelFormat
        self.firstFrameWidth = firstFrameWidth
        self.firstFrameHeight = firstFrameHeight
        self.firstError = firstError
    }
}

/// Audio or subtitle track metadata.
public struct TrackInfo: Identifiable, Sendable, Equatable {
    /// FFmpeg AVStream index.
    public let id: Int
    public let name: String
    /// Lower-case libavcodec name (e.g. "aac", "ac3", "subrip").
    public let codec: String
    public let language: String?
    /// 2=stereo, 6=5.1, 8=7.1. 0 for non-audio.
    public let channels: Int
    /// Declared stream bitrate in bits per second from `codecpar.bit_rate`, or 0 when the container
    /// leaves it unset (common for lossless VBR audio and many MKV audio tracks). For Stats-for-Nerds.
    public let bitrate: Int64
    public let isDefault: Bool
    /// Container disposition `FORCED` (subtitles meant to show without the user enabling subtitles, e.g.
    /// foreign-dialogue or signs tracks). Drives the subtitle-language ranking in `selectSubtitleIndex`.
    public let isForced: Bool
    /// Container disposition `HEARING_IMPAIRED` (SDH / closed-caption tracks with sound descriptions).
    public let isHearingImpaired: Bool
    /// Container disposition `COMMENT` (director / cast commentary tracks). Applies to audio and subtitle.
    public let isCommentary: Bool
    /// EAC3 with JOC profile (Dolby Atmos). Lets the UI surface "Atmos" instead of the bed channel count (typically 5.1).
    public let isAtmos: Bool

    /// ASS / SSA tracks only: `[Script Info]` + `[V4+ Styles]` + `[Events]` format line from codec extradata. Hosts rendering ASS styling themselves (see `LoadOptions.preserveASSMarkup`) need it to resolve style references. nil for all other track kinds.
    public let assHeader: String?

    /// True for host-registered external subtitle tracks (AetherEngine#88); their `id` is synthetic
    /// (`AetherEngine.externalSubtitleTrackIDBase` + ordinal), not an AVStream index.
    public let isExternal: Bool

    public init(id: Int, name: String, codec: String, language: String?, channels: Int = 0, bitrate: Int64 = 0, isDefault: Bool, isForced: Bool = false, isHearingImpaired: Bool = false, isCommentary: Bool = false, isAtmos: Bool = false, assHeader: String? = nil, isExternal: Bool = false) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.bitrate = bitrate
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isCommentary = isCommentary
        self.isAtmos = isAtmos
        self.assHeader = assHeader
        self.isExternal = isExternal
    }
}

/// MKV attachment filtered to font payloads. Anime releases embed TTF/OTF fonts for their ASS styles; pass to the renderer's font directory (AetherEngine#30).
public struct FontAttachment: Sendable, Equatable {
    public let filename: String
    /// Empty when the container does not carry a MIME type.
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    private static let fontMIMEs: Set<String> = [
        "font/ttf", "font/otf", "font/sfnt", "font/collection",
        "application/x-truetype-font", "application/vnd.ms-opentype",
        "application/font-sfnt", "application/x-font-ttf",
        "application/x-font-otf",
    ]

    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// True when MIME type or (as fallback for absent / generic MIME) filename extension identifies a font.
    static func isFontPayload(mimeType: String?, filename: String?) -> Bool {
        if let mime = mimeType?.lowercased(), fontMIMEs.contains(mime) {
            return true
        }
        if let ext = filename.flatMap({ ($0 as NSString).pathExtension.lowercased() }),
           fontExtensions.contains(ext) {
            let mime = mimeType?.lowercased() ?? ""  // A declared non-font MIME wins over the extension.
            return mime.isEmpty || mime == "application/octet-stream"
        }
        return false
    }
}

/// Container-level tags + embedded cover art. Fields are optional; video files usually have none. `from(...)` applies album-artist fallback and drops empty strings.
public struct MediaMetadata: Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?
    /// Raw cover-art bytes (typically JPEG or PNG); no format validation.
    public let artworkData: Data?

    public init(title: String?, artist: String?, album: String?, artworkData: Data?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
    }

    /// True when at least one text field is present; lets hosts decide between a metadata layout and a filename fallback.
    public var hasDisplayMetadata: Bool {
        title != nil || artist != nil || album != nil
    }

    /// Trim whitespace, map empty to nil, fall back to `albumArtist` when `artist` is absent.
    public static func from(
        title: String?, artist: String?, album: String?,
        albumArtist: String?, artworkData: Data?
    ) -> MediaMetadata {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return nil }
            return t
        }
        return MediaMetadata(
            title: clean(title),
            artist: clean(artist) ?? clean(albumArtist),
            album: clean(album),
            artworkData: artworkData
        )
    }
}

/// Straight (non-premultiplied) RGB for a coloured subtitle run. Reusable for teletext (#107)
/// and future ASS colour work. nil on a run means "inherit the host's foreground preference".
public struct SubtitleColor: Sendable, Equatable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

/// One contiguous same-colour span of a rich-text cue.
public struct SubtitleTextRun: Sendable, Equatable {
    public let text: String
    public let color: SubtitleColor?
    public init(text: String, color: SubtitleColor?) { self.text = text; self.color = color }
}

/// Decoded subtitle cue (start/end in container seconds). Payload is plain text (SubRip / ASS / SSA / WebVTT / mov_text), coloured rich text (teletext / ASS colour tags), or a rendered bitmap (PGS / DVB / HDMV) with position normalized against the source video frame.
/// Both paths land in the same `subtitleCues` array, so the host renders
/// them with one switch in the overlay view.
public struct SubtitleCue: Identifiable, Sendable {
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let body: Body

    public enum Body: Sendable {
        case text(String)
        case image(SubtitleImage)
        case richText([SubtitleTextRun])
    }

    public init(id: Int, startTime: Double, endTime: Double, body: Body) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.body = body
    }

    /// Plain text for text and rich-text cues (rich runs concatenated); nil for bitmap cues.
    public var text: String? {
        switch body {
        case .text(let s): return s
        case .richText(let runs): return runs.map(\.text).joined()
        case .image: return nil
        }
    }

    /// True for a bitmap cue the disc flags as forced (PGS/DVD forced captions: signs, foreign
    /// dialogue). Per cue, so a display set mixing a forced sign with regular dialogue is
    /// distinguishable (#146); track-level forcedness stays on `TrackInfo.isForced`.
    public var isForced: Bool {
        if case .image(let image) = body { return image.isForced }
        return false
    }
}

extension SubtitleCue: Equatable {
    public static func == (lhs: SubtitleCue, rhs: SubtitleCue) -> Bool {
        // ID monotonic per session; sufficient for SwiftUI diffing without comparing CGImage refs.
        lhs.id == rhs.id
            && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime
    }
}

/// Decoded PGS / HDMV PGS / DVB / DVD bitmap subtitle. CGImage is fully rendered (RGBA, premultiplied alpha). Position is [0, 1] against the source video frame; multiply by the on-screen video rect to place it.
public struct SubtitleImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let position: CGRect
    /// Coded pixel size of the subtitle canvas `position` is normalized against (PGS/DVB
    /// composition canvas, e.g. 1920x1080). A cropped-video rip can have a canvas taller
    /// than the coded video; hosts map the canvas width-aligned and center-anchored onto
    /// the video rect so cues land where the disc authored them (incl. the lower bar).
    /// .zero when unknown (pre-canvas cues): hosts fall back to treating canvas == video.
    public let canvasSize: CGSize
    /// AV_SUBTITLE_FLAG_FORCED from the decoded rect (#146): the disc authored this object as a
    /// forced caption (sign / foreign-dialogue overlay shown even with subtitles off).
    public let isForced: Bool

    public init(cgImage: CGImage, position: CGRect, canvasSize: CGSize = .zero, isForced: Bool = false) {
        self.cgImage = cgImage
        self.position = position
        self.canvasSize = canvasSize
        self.isForced = isForced
    }
}

// MARK: - Audio Utilities

import CoreAudio

/// CoreAudio channel layout tag for a given channel count. 7.1 uses `AAC_7_1` (MPEG_7_1_C, "Hollywood" L R C LFE Ls Rs Lsr Rsr), NOT `MPEG_7_1_A` (ITU center-sides); the wrong tag causes tvOS to silently emit silence.
func audioChannelLayoutTag(for channels: Int32) -> AudioChannelLayoutTag {
    switch channels {
    case 1:  return kAudioChannelLayoutTag_Mono
    case 2:  return kAudioChannelLayoutTag_Stereo
    case 3:  return kAudioChannelLayoutTag_MPEG_3_0_A
    case 4:  return kAudioChannelLayoutTag_Quadraphonic
    case 5:  return kAudioChannelLayoutTag_MPEG_5_0_A
    case 6:  return kAudioChannelLayoutTag_MPEG_5_1_A
    case 7:  return kAudioChannelLayoutTag_MPEG_6_1_A
    case 8:  return kAudioChannelLayoutTag_AAC_7_1
    default: return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
    }
}
