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
    /// the engine's loopback HLS server, not the source). Headers are
    /// NOT applied to sidecar subtitle fetches via
    /// `selectSidecarSubtitle(url:)`; that path has its own load entry.
    /// Default is empty (no extra headers).
    public var httpHeaders: [String: String]

    public init(
        omitCriteriaColorExtensions: Bool = false,
        suppressDisplayCriteria: Bool = false,
        httpHeaders: [String: String] = [:]
    ) {
        self.omitCriteriaColorExtensions = omitCriteriaColorExtensions
        self.suppressDisplayCriteria = suppressDisplayCriteria
        self.httpHeaders = httpHeaders
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
        subtitleTracks: [TrackInfo]
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

    public init(id: Int, name: String, codec: String, language: String?, channels: Int = 0, isDefault: Bool, isAtmos: Bool = false) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.isDefault = isDefault
        self.isAtmos = isAtmos
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
