import Foundation
import CoreGraphics

/// The playback state of a `AetherEngine` instance.
public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case error(String)
}

/// Which internal backend is rendering the current session.
///
/// Engine-internal in spirit; exposed read-only on `AetherEngine` so
/// diagnostic overlays / TestFlight badges can show which path drove
/// a given playback. Hosts should not switch behavior on this value;
/// the engine handles all backend-specific concerns internally.
public enum PlaybackBackend: String, Sendable, Equatable {
    /// No session loaded.
    case none
    /// Legacy FFmpeg + VideoToolbox + AVSampleBufferDisplayLayer path.
    /// Removed in 1.0.0; reserved for compatibility with hosts that
    /// still switch on this value.
    case aether
    /// HLS-fMP4 over loopback to AVPlayer + AVPlayerLayer. Default path
    /// for codecs AVPlayer can decode natively (HEVC / H.264 / VP9 on
    /// supported hardware).
    case native
    /// FFmpeg / dav1d + AVSampleBufferDisplayLayer path. Used when the
    /// source's video codec isn't decodable by AVPlayer on the active
    /// platform — primarily AV1 on tvOS where Apple ships no SW decoder
    /// and no Apple TV chip has HW AV1.
    case software
    /// FFmpeg audio decode → AVSampleBufferAudioRenderer. The audio-only
    /// path: no video pipeline, no display layer, no loopback. Used for
    /// music and other audio-only sources.
    case audio
}

/// Static snapshot of what the current display can present.
///
/// Lifted from Sodalite's `DisplayCapabilities.swift`; exposed by the
/// engine so hosts have one source of truth.
public struct DisplayCapabilities: Sendable, Equatable {
    /// True iff the display can show any HDR (HDR10, HDR10+, HLG, or DV).
    public let supportsHDR: Bool
    /// True iff the display can show Dolby Vision.
    public let supportsDolbyVision: Bool
    /// True iff the display can show HDR10.
    public let supportsHDR10: Bool
    /// True iff the display can show HLG.
    public let supportsHLG: Bool

    public init(supportsHDR: Bool, supportsDolbyVision: Bool, supportsHDR10: Bool, supportsHLG: Bool) {
        self.supportsHDR = supportsHDR
        self.supportsDolbyVision = supportsDolbyVision
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
    }
}

/// Options for the unified `AetherEngine.load(url:options:)` entry
/// point. All flags default to safe values; hosts only need to set
/// what differs from default.
public struct LoadOptions: Sendable, Equatable {
    /// When `true`, omit BT.2020 / transfer / YCbCr matrix extensions
    /// from the AVDisplayCriteria format description so AVPlayer falls
    /// back to reading the actual bitstream's color metadata at session
    /// start. Diagnostic lever only; default off.
    public var omitCriteriaColorExtensions: Bool
    /// When `true`, skip the display-criteria handshake entirely. Used
    /// by previews and `aetherctl` where there's no panel to switch.
    public var suppressDisplayCriteria: Bool
    /// Extra HTTP headers to attach to every request the engine makes
    /// against the source URL (HEAD probe, Range chunks in seekable
    /// mode, the single GET in streaming mode, and the side-demuxer
    /// runs for embedded subtitles). Use this for `Authorization`
    /// tokens, custom auth headers, or anything else the source server
    /// requires. Headers are NOT forwarded to AVPlayer (AVPlayer hits
    /// the engine's loopback HLS server, not the source). Sidecar
    /// subtitle fetches via `selectSidecarSubtitle(url:)` forward
    /// these by default; pass that call's own `httpHeaders` parameter
    /// to override per fetch (#32).
    /// Default is empty (no extra headers).
    public var httpHeaders: [String: String]

    /// Force the engine into the DV codec-classification branch even
    /// when the active display reports `dvModeAvailable == false`.
    /// Diagnostic / opt-in lever, default OFF.
    ///
    /// When OFF (default), non-DV displays route DV sources through
    /// `HLSLocalServer.mediaPlaylistURL` (no master variant) so
    /// AVPlayer's auto-tonemap engages on the HEVC base layer. This
    /// is the only path that works on tvOS 26 — the master-level
    /// codec filter rejects bare `dvh1` AND cross-compat
    /// `hvc1+SUPPLEMENTAL=dvh1` on non-DV panels with
    /// `AVFoundationErrorDomain -11868`.
    ///
    /// When ON, the engine emits bare `dvh1` codec tags and serves
    /// the master playlist regardless of display capability. Tested
    /// working on macOS Tahoe AVPlayer against the Dolby reference
    /// kit per AetherEngine#4. Use this for DV-capable panels that
    /// misreport their `availableHDRModes`.
    public var keepDvh1TagWithoutDV: Bool

    /// Whether the user has tvOS Match Content (Dynamic Range and/or
    /// Frame Rate) enabled. Mirrors `AVDisplayManager.
    /// isDisplayCriteriaMatchingEnabled`; default `true` so non-tvOS
    /// callers and hosts that don't query don't accidentally regress
    /// HDR routing.
    ///
    /// One of the two inputs to the master-vs-media-playlist routing
    /// decision in `HLSVideoEngine` (see `panelIsInHDRMode` for the
    /// other). When `false`, tvOS keeps the panel locked in its
    /// current mode regardless of what the playlist advertises;
    /// engine treats the panel as "won't switch into HDR" and routes
    /// HDR sources through the media playlist for AVPlayer's
    /// auto-tonemap path.
    public var matchContentEnabled: Bool

    /// Whether the connected panel is currently presenting in HDR
    /// (EDR active) at load time. Mirrors `UIScreen.main.currentEDRHeadroom > 1`
    /// on tvOS / iOS; default `false` so callers that don't query
    /// stay on the conservative "treat as SDR" branch.
    ///
    /// The other input to the master-vs-media-playlist routing
    /// decision. When the panel is already in HDR, the master
    /// playlist's `VIDEO-RANGE=PQ` and `SUPPLEMENTAL-CODECS=dvh1`
    /// signals are accepted upfront (per DrHurt's empirical test:
    /// HDR-mode panel honours master + supplemental for the
    /// HDR10-to-DV upgrade). When in SDR, the master path only works
    /// if `matchContentEnabled == true` so AVKit can drive the
    /// panel-mode switch into HDR; otherwise routes via media.
    public var panelIsInHDRMode: Bool

    /// Audio bridge encoder choice for source codecs that can't
    /// stream-copy into fMP4 (TrueHD, DTS, DTS-HD MA, MP3, Opus, and
    /// EAC3-from-MKV-without-dec3-extradata).
    ///
    /// - `.surroundCompat` (default): EAC3 at 128 kbps per channel (256 kbps stereo, 768 kbps 5.1). AVPlayer
    ///   hands the encoded bitstream to HDMI; the sink decodes its
    ///   own 5.1 mix. Works on soundbars (Sonos Arc, Samsung HW-Q,
    ///   Bose) and AVRs that don't accept multichannel LPCM via HDMI.
    ///   Lossy; caps 7.1 sources to 5.1.
    /// - `.lossless`: FLAC up to 7.1 lossless. AVPlayer decodes to
    ///   LPCM and routes via the active HDMI port. Needs a sink that
    ///   accepts multichannel LPCM (Denon / Marantz / NAD AVRs).
    ///   On stereo-LPCM-only routes, multichannel LPCM gets downmixed
    ///   to stereo before output (silent regression versus EAC3).
    ///
    /// Default `.surroundCompat` because the LPCM-multichannel-over-
    /// HDMI capability needed by the lossless path is rarer than the
    /// soundbar / basic-AVR install base.
    public var audioBridgeMode: AudioBridgeMode

    /// Treat the source as a live stream (e.g. IPTV HTTP MPEG-TS, raw
    /// `live.ts` over HTTP, broadcaster feeds). When `true`:
    ///
    /// - `seek(to:)` becomes a no-op with a warning log. Live sources
    ///   have no random-access guarantee and seek would either stall
    ///   AVPlayer indefinitely or land outside the producer's segment
    ///   window.
    /// - The engine's `isLive` published surface reflects this for
    ///   host UIs (hide the scrubber, hide duration, etc.).
    ///
    /// Scope today: H.264 / HEVC inside MPEG-TS over HTTP routes
    /// through the native AVPlayer path via the existing HLS-fMP4
    /// remuxer. MPEG-2 / MPEG-4 Part 2 / VC-1 inside MPEG-TS routes
    /// through the SW pipeline. The sliding-window segment eviction
    /// for unbounded-duration sources is not yet implemented; long
    /// sessions on the native path will accumulate cached segments.
    /// Set this flag explicitly when the host knows the URL is a live
    /// feed; auto-detection from `probe.durationSeconds == 0` is too
    /// noisy (VOD MKVs with broken duration headers report the same).
    /// Default `false`.
    public var isLive: Bool

    /// Route the source through the lean audio-only path: FFmpeg decodes
    /// directly into `AVSampleBufferAudioRenderer`, skipping the video
    /// probe, the display-criteria handshake, and the entire HLS /
    /// segment-producer / muxer / loopback stack. Set this for music
    /// playback. The engine also falls into the audio path automatically
    /// when the probe finds no video stream, so a host that doesn't set
    /// the flag still gets audio playback for audio-only sources; the
    /// flag lets the host skip the (cheap) video probe entirely and
    /// guarantees the audio path even for malformed containers that
    /// advertise a phantom video stream. Default `false`.
    public var audioOnly: Bool

    /// Enables in-session timeshift (DVR) for a live source. nil keeps live-only
    /// behavior (seek is a no-op). A value is the rewind window in seconds; the
    /// engine retains roughly this much past content (disk-backed) and clamps
    /// seeks to it. Suggested host default when enabling DVR: 1800. Ignored when
    /// `isLive == false`. Default nil.
    public var dvrWindowSeconds: Double?

    /// Play the URL as a native AVPlayer HLS stream directly: build an
    /// `AVPlayerItem` from the (remote) URL and hand it to the native
    /// `AVPlayer`, skipping the demuxer probe, the display-criteria
    /// handshake, and the entire HLS segment-producer / muxer / loopback
    /// stack. Use this for a live source the upstream server already
    /// exposes as HLS (e.g. Jellyfin live `master.m3u8`): AVPlayer manages
    /// the live edge, buffering, and reconnect natively. Same lean-bypass
    /// shape as `audioOnly`, but for native HLS video. Pair with
    /// `isLive: true` for the live UI surfaces. Default `false`.
    public var nativeRemoteHLS: Bool

    /// Emit ASS / SSA subtitle cues as the RAW event line (the full
    /// `ReadOrder,Layer,Style,...,Text` payload including override
    /// tags like `{\pos(...)}` and `\N` escapes) instead of the
    /// engine's default plain-text extraction, which strips all
    /// styling. Opt-in for hosts that render ASS styling themselves;
    /// pair with `TrackInfo.assHeader` (the track's `[Script Info]` +
    /// `[V4+ Styles]` header) to resolve style references. Only
    /// affects tracks whose codec is ASS / SSA; SubRip / WebVTT /
    /// bitmap tracks are untouched. Default `false` (AetherEngine#30).
    public var preserveASSMarkup: Bool

    /// When `true`, advertise each of the source's subtitle tracks as a
    /// decoy (empty, cue-less) WebVTT rendition in the generated HLS
    /// master playlist, so AVKit's native subtitle picker lists them.
    /// The engine does NOT decode or paint cues for these renditions;
    /// the host renders the actual subtitle cues itself (via
    /// `subtitleCues`). This is purely a picker-population hook.
    /// Default `false`: when off, the master/media playlists are
    /// byte-identical to a build without this feature and no subtitle
    /// lines are emitted. The mapping the host needs to correlate a
    /// picked rendition back to an engine subtitle track is published on
    /// `AetherEngine.subtitleRenditions`.
    public var advertiseSubtitleRenditions: Bool

    /// ENGINE-INTERNAL: marks this load as a live REJOIN (a reload of
    /// an already-running live session: background-return reopen via
    /// `reloadAtCurrentPosition`). Not part of the public API and not
    /// settable through the public initializer; hosts always load with
    /// the default `false`.
    ///
    /// Why it exists: a live rejoin reuses the SAME upstream URL, and
    /// servers like Jellyfin re-serve their transcode buffer from the
    /// start at I/O speed, so the rebuilt producer presents a
    /// multi-segment backlog at AVPlayer's first playlist fetch
    /// instead of the fresh-join 2-segment cushion. The native load
    /// path must then skip its explicit initial seek and let AVPlayer
    /// pick its own live-edge join (see `LiveReloadPolicy`), or the
    /// reloaded item can wedge in `waitingToPlay` without ever
    /// reaching `readyToPlay`. Only meaningful when `isLive` is true.
    var isLiveRejoin: Bool = false

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
        nativeRemoteHLS: Bool = false,
        preserveASSMarkup: Bool = false,
        advertiseSubtitleRenditions: Bool = false
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
        self.nativeRemoteHLS = nativeRemoteHLS
        self.preserveASSMarkup = preserveASSMarkup
        self.advertiseSubtitleRenditions = advertiseSubtitleRenditions
    }
}

/// The detected video dynamic range format.
///
/// `hdr10Plus` shares the underlying HDR10 base layer with `hdr10`,
/// what makes it distinct is the per-frame ST 2094-40 dynamic metadata
/// the engine forwards to the display via
/// `kCMSampleAttachmentKey_HDR10PlusPerFrameData`. From an
/// AVDisplayCriteria perspective both formats request the same TV
/// mode (PQ + BT.2020); the badge / detection split exists so the host
/// UI can show the right label and so reporting is accurate.
public enum VideoFormat: Sendable, Equatable {
    case sdr
    case hdr10
    case hdr10Plus
    case dolbyVision
    case hlg
}

/// One-shot read of a media source's container + stream metadata.
/// Returned from `AetherEngine.probe(url:options:)`; no HLS server is
/// spun up, no decoders are opened. Intended for "what's in this
/// file?" debugging and host-side detail surfaces. The probe does the
/// same demuxer-open dance `load(url:)` does internally but tears down
/// immediately after reading metadata.
public struct SourceProbe: Sendable {
    /// The URL that was probed (echoed back for convenience).
    public let url: URL
    /// Total duration in seconds, or 0 if the source's container does
    /// not advertise one (live streams, pipes).
    public let durationSeconds: Double
    /// HDR / DV classification of the video track. `.sdr` for sources
    /// without HDR signaling or without a video track at all.
    public let videoFormat: VideoFormat
    /// FFmpeg AVCodecID raw value of the video stream's codec, or
    /// `AV_CODEC_ID_NONE.rawValue` (0) if there is no video track.
    public let videoCodecID: Int32
    /// Best-effort human-readable codec name (e.g. "hevc", "h264",
    /// "av1", "vp9"). `nil` when libavcodec doesn't expose one.
    public let videoCodecName: String?
    /// Pixel width of the video frame, 0 if no video track.
    public let videoWidth: Int32
    /// Pixel height of the video frame, 0 if no video track.
    public let videoHeight: Int32
    /// Frame rate snapped to a standard rate (23.976, 24, 25, ...) or
    /// `nil` when the source does not advertise one or has no video.
    public let videoFrameRate: Double?
    /// True if the video track signals Dolby Vision (any profile).
    public let isDolbyVision: Bool
    /// Audio tracks in source order. Empty when the source has no
    /// audio.
    public let audioTracks: [TrackInfo]
    /// Subtitle tracks in source order, both embedded text and
    /// bitmap (PGS / DVB) variants.
    public let subtitleTracks: [TrackInfo]
    /// Container metadata (tags + embedded cover art), normalized.
    public let metadata: MediaMetadata
    /// Best-effort live-stream hint: `true` when the source advertises
    /// no duration AND the URL scheme suggests a network feed
    /// (http / https / udp / rtp / rtsp). False positives are possible
    /// (VOD MKVs with broken duration headers), so this is a hint for
    /// hosts to decide whether to set `LoadOptions.isLive`, not a
    /// definitive classification.
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
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.metadata = metadata
        self.isLive = isLive
    }
}

/// Result of `AetherEngine.swDecodeProbe(url:)`. SW-decoder repro
/// shape for `aetherctl swdecode` and host-side SW-pipeline diagnostics
/// (MPEG-4 Part 2, MPEG-2, VC-1, AV1 on platforms without HW AV1).
/// Distinguishes "decoder couldn't open" from "decoder opened but
/// produced no frames" from "decode works end-to-end" so failures
/// can be localised without spinning up a render layer.
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

/// Metadata about an audio or subtitle track in the loaded media.
public struct TrackInfo: Identifiable, Sendable, Equatable {
    /// Track index as reported by FFmpeg's AVStream.
    public let id: Int
    /// Human-readable track name (title or fallback).
    public let name: String
    /// Codec name (e.g. "aac", "ac3", "subrip").
    public let codec: String
    /// BCP-47 language tag if available (e.g. "en", "de", "ja").
    public let language: String?
    /// Number of audio channels (2=stereo, 6=5.1, 8=7.1). 0 for non-audio.
    public let channels: Int
    /// True if this track is marked as default in the container.
    public let isDefault: Bool
    /// True if this is a Dolby Atmos track, currently means EAC3 with
    /// the JOC (Joint Object Coding) profile, which is what every
    /// streaming-quality Atmos elementary stream looks like in practice.
    /// Lets the player UI surface "Atmos" instead of just the channel
    /// count of the bed (typically 5.1).
    public let isAtmos: Bool

    /// For ASS / SSA subtitle tracks: the script header from the
    /// container's codec extradata (`[Script Info]`, `[V4+ Styles]`,
    /// and the `[Events]` format line). Hosts rendering ASS styling
    /// themselves (see `LoadOptions.preserveASSMarkup`) need it to
    /// resolve the style names referenced by each event line. nil for
    /// every other track kind.
    public let assHeader: String?

    public init(id: Int, name: String, codec: String, language: String?, channels: Int = 0, isDefault: Bool, isAtmos: Bool = false, assHeader: String? = nil) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.isDefault = isDefault
        self.isAtmos = isAtmos
        self.assHeader = assHeader
    }
}

/// A decoy subtitle rendition advertised in the generated HLS master
/// playlist so AVKit's native subtitle picker lists it (see
/// `LoadOptions.advertiseSubtitleRenditions`). Published on
/// `AetherEngine.subtitleRenditions`; the engine paints no cues for it,
/// it exists only to populate the picker and to let the host correlate
/// the picked legible option back to an engine subtitle `TrackInfo`.
public struct SubtitleRendition: Sendable, Equatable {
    /// Path-safe identifier the master playlist uses (`"sub<trackIndex>"`).
    /// The loopback server serves `/subs_<renditionID>.m3u8` + `.vtt`.
    public let renditionID: String
    /// Display name shown in the picker (the language label).
    public let name: String
    /// ISO language code emitted as `LANGUAGE=` (fallback `"und"`).
    public let language: String
    /// The engine subtitle AVStream index (`TrackInfo.id`) this rendition
    /// stands for; the host decodes + paints this track's cues when the
    /// rendition is selected.
    public let trackIndex: Int

    public init(renditionID: String, name: String, language: String, trackIndex: Int) {
        self.renditionID = renditionID
        self.name = name
        self.language = language
        self.trackIndex = trackIndex
    }
}

/// An attached file carried by the container (MKV attachment streams),
/// filtered to font payloads. Anime releases embed the TTF/OTF fonts
/// their ASS styles reference; hosts that render ASS styling themselves
/// (see `LoadOptions.preserveASSMarkup`) hand these to their renderer's
/// font directory so the authored typography resolves (AetherEngine#30).
public struct FontAttachment: Sendable, Equatable {
    /// Attachment filename from the container metadata ("filename").
    public let filename: String
    /// MIME type from the container metadata ("mimetype"); empty when
    /// the container does not carry one.
    public let mimeType: String
    /// The font file bytes.
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

    /// True when the MIME type or, as a fallback for missing / generic
    /// MIME, the filename extension identifies a font payload.
    static func isFontPayload(mimeType: String?, filename: String?) -> Bool {
        if let mime = mimeType?.lowercased(), fontMIMEs.contains(mime) {
            return true
        }
        if let ext = filename.flatMap({ ($0 as NSString).pathExtension.lowercased() }),
           fontExtensions.contains(ext) {
            // Only trust the extension when the MIME is absent or generic;
            // a declared non-font MIME wins.
            let mime = mimeType?.lowercased() ?? ""
            return mime.isEmpty || mime == "application/octet-stream"
        }
        return false
    }
}

/// Container-level media metadata (tags + embedded cover art) for the
/// loaded source. Every field is optional: audio files frequently ship
/// with partial or no tags, and video files usually have none. Built
/// via `MediaMetadata.from(...)`, which applies the album-artist fallback
/// and drops empty strings.
public struct MediaMetadata: Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?
    /// Embedded cover art bytes exactly as stored in the container
    /// (typically JPEG or PNG); no format validation is performed.
    /// nil when the source has no attached picture.
    public let artworkData: Data?

    public init(title: String?, artist: String?, album: String?, artworkData: Data?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
    }

    /// True when at least one human-readable text field is present, so
    /// hosts can decide between a metadata layout and a filename fallback.
    public var hasDisplayMetadata: Bool {
        title != nil || artist != nil || album != nil
    }

    /// Normalize raw demuxer values: trim whitespace, map empty to nil,
    /// and fall back to `albumArtist` when `artist` is absent.
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

/// A single decoded subtitle cue, start/end in container seconds plus a
/// payload. The payload is either plain text (SubRip / ASS / SSA / WebVTT
/// / mov_text after override-stripping) or a rendered bitmap (PGS / DVB
/// / HDMV) with a position normalised against the source video frame.
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
    }

    public init(id: Int, startTime: Double, endTime: Double, body: Body) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.body = body
    }

    /// Convenience for callers that only handle text cues. Returns nil
    /// for bitmap cues, which the host should render as `.image` instead.
    public var text: String? {
        if case .text(let s) = body { return s }
        return nil
    }
}

extension SubtitleCue: Equatable {
    public static func == (lhs: SubtitleCue, rhs: SubtitleCue) -> Bool {
        // ID is monotonic per subtitle session and unique within the
        // current `subtitleCues` array, that's enough to drive
        // SwiftUI animation diffing without comparing CGImage refs.
        lhs.id == rhs.id
            && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime
    }
}

/// A decoded bitmap subtitle rect, the kind PGS, HDMV PGS, DVB and
/// DVD subtitles produce. The CGImage is fully rendered (palette
/// applied, RGBA, premultiplied alpha) and ready to display. Position
/// is normalised in [0, 1] against the source video frame so the host
/// can scale to any display rect.
public struct SubtitleImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// Origin and size in [0, 1] coordinates of the source video frame.
    /// Hosts multiply by the on-screen video rect to position the
    /// bitmap correctly.
    public let position: CGRect

    public init(cgImage: CGImage, position: CGRect) {
        self.cgImage = cgImage
        self.position = position
    }
}

// MARK: - Audio Utilities

import CoreAudio

/// Map channel count to the appropriate CoreAudio channel layout tag.
/// Used by AudioDecoder for channel layout mapping.
///
/// 7.1 note: `MPEG_7_1_A` is the ITU "center-sides" layout (L R C LFE
/// Ls Rs Lc Rc) almost nobody ships. Blu-ray, TrueHD, DTS-HD MA and
/// streaming 7.1 are all the "Hollywood" layout, L R C LFE Ls Rs Lsr
/// Rsr, which is `MPEG_7_1_C`. Using the wrong tag made tvOS silently
/// drop the stream: the audio pipeline can't reconcile 7.1-A samples
/// with a 7.1-C output route, and just emits silence instead of
/// routing them.
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
