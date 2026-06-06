import Foundation
import Darwin.Mach
import QuartzCore
import CoreMedia
import CoreVideo
import AVFoundation
import Combine
import Libavformat
import Libavcodec
import Libavutil

#if canImport(UIKit)
import UIKit
#endif
import MediaPlayer

/// AetherEngine, format-agnostic video muxer that feeds AVPlayer.
///
/// Open-source LGPL 3.0 engine that takes any source (HTTP, file://,
/// MKV / MP4 / TS containers; AVC / HEVC / VP9 / AV1 codecs) and
/// streams it as HLS-fMP4 over a loopback HTTP server to an internal
/// AVPlayer. The host embeds a single `AetherPlayerView` and calls
/// `engine.load(url:options:)`; the engine handles demux, fMP4 mux,
/// HDMI HDR-mode handshake, frame-rate matching, AVPlayer wiring, and
/// per-frame HDR metadata forwarding.
///
/// ## Architecture
///
/// ```
/// URL → FFmpeg Demuxer → HLS-fMP4 Mux (libavformat) → loopback HTTP
///   → AVPlayer → AVPlayerLayer (hosted by AetherPlayerView)
/// ```
///
/// Audio is stream-copied into the fMP4 when the codec is legal there
/// (AAC, AC3, EAC3 incl. JOC Atmos, FLAC, ALAC, MP3, Opus). Codecs
/// that aren't legal in fMP4 (TrueHD, DTS, etc.) bridge through the
/// engine's FLAC re-encoder so AVPlayer plays them as lossless FLAC.
///
/// ## Quick Start
///
/// ```swift
/// let engine = try AetherEngine()
/// let view = AetherPlayerView()
/// engine.bind(view: view)
/// try await engine.load(url: myVideoURL, options: .init())
/// engine.play()
/// ```
///
/// ## License
///
/// LGPL 3.0, App Store compatible when dynamically linked.
@MainActor
public final class AetherEngine: ObservableObject {

    // MARK: - Public State

    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var progress: Float = 0
    @Published public private(set) var audioTracks: [TrackInfo] = []
    @Published public private(set) var subtitleTracks: [TrackInfo] = []
    /// Active audio track's container stream index (matches `TrackInfo.id`),
    /// or `nil` while no audio is wired (audio-less source or before the
    /// first `load(url:)` resolves). Updated synchronously when
    /// `selectAudioTrack(index:)` reloads the pipeline; the host's
    /// picker reflects what the engine actually muxed rather than the
    /// last optimistic UI write.
    @Published public private(set) var activeAudioTrackIndex: Int?
    @Published public private(set) var videoFormat: VideoFormat = .sdr

    /// Source-detected video range as read from the demuxer probe, before
    /// any panel clamping. Differs from `videoFormat` when the panel can't
    /// present the source (e.g. DV source on an SDR panel, or HDR source
    /// with Match Content off): there `videoFormat` reads `.sdr` because
    /// that's what's on screen, while `sourceVideoFormat` keeps reading
    /// `.dolbyVision` / `.hdr10` because that's what's in the file.
    ///
    /// Hosts that want to label media attributes (Stats for Nerds, file
    /// inspectors) should use this. Hosts that drive UI tied to what the
    /// panel is actually rendering (HDR badges, tone-mapping decisions)
    /// should keep using `videoFormat`.
    ///
    /// Late HDR10+ upgrades from T.35 SEI flip this from `.hdr10` to
    /// `.hdr10Plus` independent of `videoFormat`'s panel guard, because
    /// SEI detection is a source-side fact.
    @Published public private(set) var sourceVideoFormat: VideoFormat = .sdr

    /// Which internal backend rendered the current session. Resolves
    /// to `.native` for AVPlayer-decodable sources (HEVC, H.264, plus
    /// AV1 on HW-AV1 devices) or `.software` when the source falls
    /// through to `SoftwarePlaybackHost` (SW dav1d for AV1 without HW,
    /// libavcodec for VP9, MPEG-4 Part 2, MPEG-2, VC-1). Kept on the
    /// public surface for diagnostic overlays and TestFlight badges;
    /// hosts should not switch on it.
    @Published public private(set) var playbackBackend: PlaybackBackend = .none

    /// 1 Hz snapshot of live playback telemetry while the engine is
    /// `.playing` or `.paused`. `nil` while idle. Driven by
    /// `LiveTelemetrySampler`. The host's stats overlay subscribes to
    /// this and renders into the Live + Engine Diagnostics sections.
    @Published public private(set) var liveTelemetry: LiveTelemetry?

    /// Human-readable identity of the video decoder currently in use,
    /// suitable for a "stats for nerds" UI. Examples:
    /// - `"VideoToolbox HEVC (HW)"` for the native AVPlayer path on
    ///   anything VideoToolbox can decode (HEVC, H.264, AV1 on HW-AV1
    ///   capable devices).
    /// - `"dav1d AV1 (SW)"` for AV1 falling through to the SW pipeline.
    /// - `"libavcodec VP9 (SW)"` for VP9.
    /// - `"libavcodec MPEG4 (SW)"` etc. for legacy codecs AVPlayer
    ///   cannot decode (MPEG-4 Part 2, MPEG-2, VC-1).
    /// `nil` while no playback session is loaded. Cleared in
    /// `stopInternal` so a new session never inherits the previous
    /// label.
    @Published public private(set) var activeVideoDecoder: String?

    /// Human-readable identity of the audio pipeline currently in use.
    /// For the native AVPlayer path this reflects what
    /// `HLSVideoEngine`'s stream-copy / FLAC-bridge cascade chose:
    /// - `"Stream-copy (EAC3+JOC Atmos)"` for preserved Atmos passthrough.
    /// - `"Stream-copy (<CODEC>)"` for non-Atmos passthrough.
    /// - `"FLAC bridge ← <CODEC>"` when the source codec isn't legal
    ///   in fMP4 and got re-encoded as FLAC for AVPlayer.
    /// For the SW path: `"libavcodec <codec> → CoreAudio"`.
    /// `nil` when the source has no audio, when the cascade fell
    /// through to video-only, or while no session is loaded.
    @Published public private(set) var activeAudioDecoder: String?

    /// Decoded subtitle cues for the active subtitle source. Populated
    /// by `selectSidecarSubtitle(url:)` only — embedded subtitle
    /// streams in the source travel through HLSVideoEngine into the
    /// fMP4 wrapper but aren't decoded back to text on this side yet
    /// (AVMediaSelection wiring is a tracked follow-up). Sidecar SRT
    /// works end-to-end.
    @Published public private(set) var subtitleCues: [SubtitleCue] = []
    /// True while a sidecar file is being downloaded + decoded.
    @Published public private(set) var isLoadingSubtitles: Bool = false
    /// True when sidecar subtitles are the active subtitle source.
    @Published public private(set) var isSubtitleActive: Bool = false

    /// True while the active session is a live stream (the host set
    /// `LoadOptions.isLive = true` at load time). Hosts use this to
    /// hide duration / scrubber UI, skip seek affordances, and switch
    /// the transport-bar layout to a now-only badge. Cleared in
    /// `stopInternal` so a finished live session doesn't bleed flag
    /// state into the next VOD load.
    @Published public private(set) var isLive: Bool = false

    // MARK: - Output

    /// How the AVPlayer surface fills its container layer. Mirrors
    /// the host's preferred fit mode to whichever `AVPlayerLayer` is
    /// currently mounted in the bound `AetherPlayerView`.
    public var videoGravity: AVLayerVideoGravity {
        get { _videoGravity }
        set {
            _videoGravity = newValue
            // Engine's native AVPlayerLayer (nativeHost.playerLayer) is
            // allocated but typically not the surface on screen — most
            // tvOS hosts wrap the AVPlayer in AVPlayerViewController,
            // which mounts its own internal AVPlayerLayer. Writing here
            // is still correct for hosts that use the engine's layer
            // directly (`AetherPlayerView.attach(host.playerLayer)`)
            // and for the SW path's displayLayer.
            nativeHost?.playerLayer.videoGravity = newValue
            softwareHost?.displayLayer.videoGravity = newValue
        }
    }
    private var _videoGravity: AVLayerVideoGravity = .resizeAspect

    // MARK: - Capabilities

    /// Snapshot of what the active display can present right now.
    ///
    /// Reads `AVPlayer.eligibleForHDRPlayback` and
    /// `AVPlayer.availableHDRModes` at call time. tvOS and iOS report
    /// panel capabilities; macOS reports the built-in display only and
    /// may under-report external displays.
    public static var displayCapabilities: DisplayCapabilities {
        #if os(tvOS) || os(iOS)
        let hdrEligible = AVPlayer.eligibleForHDRPlayback
        let modes = AVPlayer.availableHDRModes
        return DisplayCapabilities(
            supportsHDR: hdrEligible,
            supportsDolbyVision: modes.contains(.dolbyVision),
            supportsHDR10: modes.contains(.hdr10),
            supportsHLG: modes.contains(.hlg)
        )
        #else
        return DisplayCapabilities(
            supportsHDR: AVPlayer.eligibleForHDRPlayback,
            supportsDolbyVision: false,
            supportsHDR10: false,
            supportsHLG: false
        )
        #endif
    }

    // MARK: - View binding

    /// The view currently bound to this engine, if any. Weak so a host
    /// that drops its view reference doesn't leak the surface through
    /// the engine singleton.
    private weak var boundView: AetherPlayerView?

    /// Bind a render surface to this engine. The engine attaches the
    /// active `AVPlayerLayer` immediately and re-attaches on every
    /// session swap. Calling `bind` again with a different view
    /// detaches the old one.
    public func bind(view: AetherPlayerView) {
        if let existing = boundView, existing !== view {
            existing.detach()
        }
        boundView = view
        presentCurrentLayer()
    }

    /// Unbind a previously bound view. Idempotent; safe to call when
    /// nothing is bound or when a different view is bound.
    public func unbind(view: AetherPlayerView) {
        guard boundView === view else { return }
        view.detach()
        boundView = nil
    }

    /// Attach the active session's render layer to the bound view.
    /// Picks `nativeHost.playerLayer` (AVPlayerLayer) when the native
    /// AVPlayer path is active, `softwareHost.displayLayer`
    /// (AVSampleBufferDisplayLayer) for the SW dav1d path. No-op when
    /// neither host exists — the layer attaches on the next load.
    func presentCurrentLayer() {
        guard let view = boundView else { return }
        if let host = nativeHost {
            view.attach(host.playerLayer)
        } else if let host = softwareHost {
            view.attach(host.displayLayer)
        }
    }

    // MARK: - Display + native state

    /// Engine-owned HDMI HDR handshake controller. Programs
    /// `AVDisplayManager.preferredDisplayCriteria` from the format +
    /// frame rate the demuxer probes; no-op on iOS / macOS.
    private let displayCriteria = DisplayCriteriaController()

    /// HLS video engine that demuxes the source and serves a
    /// loopback HLS-fMP4 playlist for AVPlayer to consume. Non-nil
    /// between `load` and `stop`.
    private var nativeVideoSession: HLSVideoEngine?

    /// The native AVPlayer + AVPlayerLayer host. Non-nil between
    /// `load` and `stop`.
    private var nativeHost: NativeAVPlayerHost?

    /// Combine subscriptions from `nativeHost`'s @Published into the
    /// engine's own @Published mirrors. Cancelled on stopInternal so
    /// a new session doesn't accumulate them.
    private var nativeCancellables: Set<AnyCancellable> = []

    /// Software-decode host for codecs AVPlayer cannot decode on the
    /// active platform (today: AV1 on Apple TV, where Apple ships
    /// dav1d on iOS / macOS but not on tvOS and no Apple TV chip has
    /// HW AV1). Non-nil between `load` and `stop` when the source's
    /// video stream routed through the SW pipeline.
    private var softwareHost: SoftwarePlaybackHost?

    /// Combine subscriptions from `softwareHost`'s @Published mirrors.
    /// Cancelled on stopInternal alongside `nativeCancellables`.
    private var softwareCancellables: Set<AnyCancellable> = []

    /// The lean audio-only playback host. Non-nil only while an
    /// audio-only session (music) is active. Mutually exclusive with
    /// `nativeHost` / `softwareHost`: a load tears all of them down via
    /// `stopInternal` before bringing one up.
    private var audioHost: AudioPlaybackHost?

    /// Combine subscriptions from `audioHost`'s @Published mirrors into
    /// the engine's own surface. Cleared on stopInternal.
    private var audioCancellables = Set<AnyCancellable>()

    /// Native AVPlayer audio host. Created lazily on the first AVPlayer
    /// audio load and then KEPT for the engine's lifetime, reused across
    /// tracks via replaceCurrentItem. This is deliberate: its
    /// MPNowPlayingSession must persist so the system sees one stable
    /// Now-Playing app across a playlist. Recreating it per track (a fresh
    /// session each time) prevented the background Siri Remote + system
    /// Now-Playing UI from ever stabilising. `audioAVPlayerActive` gates
    /// whether this host is the CURRENT backend.
    private var audioAVPlayerHost: AudioAVPlayerHost?
    private var audioAVPlayerActive = false
    private var audioNativeCancellables = Set<AnyCancellable>()

    /// Periodic memory diagnostic. Emits the process's resident memory
    /// footprint and engine-internal counters every 30 s so we can
    /// see growth patterns instead of guessing about leaks. Started in
    /// `load(url:)` once `state = .playing` lands; cancelled in
    /// `stopInternal`. The log line shape is grep-friendly:
    ///
    ///   [AetherEngine] memprobe t=210s rss=412MB cache=27 subCues=0
    ///
    /// On macOS / aetherctl the line goes to stdout; on tvOS it goes to
    /// `EngineLog.handler` so the host's diagnostic overlay sees it too.
    private var memoryProbeTask: Task<Void, Never>?

    /// 1 Hz live-telemetry sampler. Mirrors the lifecycle of
    /// `memoryProbeTask`: started when the engine enters `.playing`
    /// (load completes) and torn down in `stopInternal`. The sampler
    /// holds a weak reference back to the engine so its retained task
    /// can't keep `self` alive past teardown.
    private var liveTelemetrySampler: LiveTelemetrySampler?

    /// The URL of the current playback session. Used by
    /// `reloadAtCurrentPosition()` to rebuild the pipeline after
    /// background suspension.
    // Internal getter (not public API): read by the same-module
    // AetherEngine+FrameExtractor extension to vend a FrameExtractor.
    private(set) var loadedURL: URL?

    /// Seconds the producer shifted AVPlayer's HLS clock away from
    /// source PTS on the native path: it subtracts `videoShiftPts` from
    /// every packet's pts/dts so seg-0's fragment tfdt aligns with the
    /// playlist's cumulative-EXTINF origin, leaving AVPlayer's raw clock
    /// at `source_pts - playlistShiftSeconds`. The engine folds this back
    /// in before publishing, so `currentTime` (and `sourceTime`) already
    /// carry source PTS on every path; see `nativeClockSeconds` for the
    /// pre-fold raw value. Retained public for diagnostics.
    ///
    /// Updated by `HLSVideoEngine.onPlaylistShiftChanged` on every
    /// producer init / restart (matroska seek imprecision means the
    /// shift can differ session-to-session for the same source).
    /// 0 on the SW / audio paths, whose clocks track source PTS directly.
    @Published public private(set) var playlistShiftSeconds: Double = 0

    /// Raw AVPlayer HLS clock (`source_pts - playlistShiftSeconds`) on the
    /// native path, before the shift is folded back into `currentTime`.
    /// Held so `onPlaylistShiftChanged` can re-derive `currentTime` the
    /// instant the shift changes mid-session, instead of waiting for the
    /// next periodic time tick. Unused on the SW / audio paths (shift 0).
    private var nativeClockSeconds: Double = 0

    /// Source PTS of the currently displayed frame. Equal to `currentTime`
    /// on every path now that the native clock is unified onto source time;
    /// kept as a stable alias for callers that want to express source-
    /// timeline intent explicitly (subtitle overlay, side-demuxer seek).
    @Published public private(set) var sourceTime: Double = 0

    /// The `LoadOptions` the host passed for the current session.
    /// Replayed on every internal reopen of the source URL
    /// (selectAudioTrack reload, embedded subtitle side demuxer,
    /// background reload) so auth, Match Content state, and the
    /// dvh1 tag override all survive mid-playback pipeline rebuilds
    /// rather than silently reverting to defaults. The audio-switch
    /// reload was hitting `matchContentEnabled = true` on a host that
    /// had loaded with `false`, which then routed HDR HEVC through the
    /// master playlist on a non-DV panel with Match Content off and
    /// surfaced "Öffnen fehlgeschlagen".
    // Internal getter (not public API): read by the same-module
    // AetherEngine+FrameExtractor extension to vend a FrameExtractor.
    private(set) var loadedOptions: LoadOptions = .init()

    /// In-flight sidecar subtitle decode. Cancelled on subtitle
    /// clear / track switch so a stale decode can't overwrite fresh
    /// cues.
    private var sidecarTask: Task<Void, Never>?

    /// In-flight embedded-subtitle reader Task. Runs a side Demuxer
    /// against the same source URL, seeked to the current playhead,
    /// reading subtitle packets directly. Bypasses the main HLS pump
    /// (which has already raced past the playhead by ~60-80 s when
    /// subtitle activation happens mid-playback, so its subtitle
    /// packets near the visible time have already been read and
    /// discarded). Cancelled + restarted on track change, on
    /// `clearSubtitle`, on `seek`, and on `stop`.
    private var embeddedSubtitleTask: Task<Void, Never>?

    /// Active embedded subtitle stream index, or -1 for none. Used by
    /// `seek` to know whether to re-arm the side demuxer at the new
    /// playback position.
    private var activeEmbeddedSubtitleStreamIndex: Int32 = -1

    /// Source video dimensions captured at `load()` probe time. The
    /// embedded subtitle decoder uses these as a canvas-size fallback
    /// when a bitmap codec's PCS hasn't been parsed yet.
    private var sourceVideoWidth: Int32 = 0
    private var sourceVideoHeight: Int32 = 0

    /// Last-detected source video codec id. Latched in `load(url:)` and
    /// reused by the audio-track-switch reload path so it can re-derive
    /// the same `activeVideoDecoder` label without re-running the
    /// demuxer probe. Reset to `AV_CODEC_ID_NONE` in `stopInternal`.
    private var lastDetectedVideoCodec: AVCodecID = AV_CODEC_ID_NONE

    /// Cap the per-session subtitle event diagnostic logs so the in-
    /// app overlay stays readable. Reset on `load()` so each new
    /// session gets a fresh budget.
    private var subtitleCueDiagnosticCount: Int = 0

    /// How far behind `currentTime` to retain old subtitle cues
    /// before pruning them out of `subtitleCues`. Bounds the
    /// session-time memory footprint of bitmap subtitle tracks
    /// (PGS / DVB / DVD), where each cue carries a CGImage that
    /// retains its decoded RGBA pixel buffer for the cue's lifetime.
    /// A 2-hour Blu-ray remux with PGS English subtitles emits
    /// ~1500-2000 cues; without pruning those CGImages stack and
    /// the heap climbs by several hundred MB over the session.
    /// 300 s covers normal pause durations and the backward-scrub
    /// reach that doesn't trigger a producer restart; cues evicted
    /// before that get re-emitted by the producer on restart since
    /// `EmbeddedSubtitleDecoder.resetState` clears the seen-key
    /// dedupe set at every restart.
    private let subtitleCueRetentionSeconds: Double = 300

    // MARK: - Init

    /// Lifecycle notification observers, stored for cleanup.
    private var lifecycleObservers: [Any] = []

    public init() throws {
        // Route FFmpeg's av_log output into EngineLog before any
        // libav* entry point runs, so probe/load diagnostics land in
        // Console.app + the host handler from the very first call.
        FFmpegLogBridge.install()

        // Declare the audio session's category + multichannel support,
        // but do NOT activate the session or pin a preferred channel
        // count here.
        //
        // Issue #24: activating the shared session once at process launch
        // (the engine is a process-wide singleton) latches it against
        // whatever the HDMI route reports at that instant. With tvOS
        // "Continuous Audio Connection" off the link idles at stereo
        // (output=2) at launch, the route gets pinned, and no later
        // AVAudioSession call (setActive / setPreferred / deactivate +
        // reactivate, all tried on device) can lift it — a 5.1 EAC3 asset
        // then downmixes to stereo. The native video path wraps its
        // AVPlayer in AVPlayerViewController, which owns and activates the
        // session per playback; letting AVKit drive activation lets tvOS
        // auto-negotiate the PCM <-> Dolby route switch against the live
        // sink. The renderer paths (SoftwarePlaybackHost / Audio*Host) do
        // their own activation via `activateRendererAudioSession()` since
        // they render through AVSampleBufferAudioRenderer / a bare
        // AVPlayer with no AVPlayerViewController to manage the session.
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try session.setSupportsMultichannelContent(true)
        } catch {
            EngineLog.emit("[AetherEngine] AVAudioSession setup error: \(error)", category: .engine)
        }
        EngineLog.emit("[AetherEngine] AVAudioSession: category set, not activated (AVKit drives activation) maxChannels=\(session.maximumOutputNumberOfChannels) output=\(session.outputNumberOfChannels)", category: .engine)
        #endif

        setupLifecycleObservers()
    }

    // MARK: - Probe

    /// One-shot read of a source's container + stream metadata,
    /// without spinning up the HLS server or any decoders. Returns
    /// the same kind of info `load(url:)` collects internally before
    /// dispatching, packaged as a `SourceProbe` for hosts and CLI
    /// tools that just want to know "what's in this file?".
    ///
    /// Network sources fetch a HEAD probe + a small initial range
    /// for libavformat's stream info pass; total bytes pulled depend
    /// on the container but typically a few MB. File sources read
    /// from disk directly via FFmpeg's file protocol.
    ///
    /// - Parameters:
    ///   - url: Media source (`file://`, `http://`, or `https://`).
    ///   - options: Forwarded for `httpHeaders` only; other flags are
    ///     ignored since no playback session starts.
    /// - Throws: Any error the demuxer raises during open / probe.
    public nonisolated static func probe(
        url: URL,
        options: LoadOptions = .init()
    ) throws -> SourceProbe {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }

        var detectedFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedCodecID: AVCodecID = AV_CODEC_ID_NONE
        var width: Int32 = 0
        var height: Int32 = 0
        let videoIdx = demuxer.videoStreamIndex
        if videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) {
            detectedFormat = Self.detectVideoFormat(stream: stream)
            detectedRate = Self.detectFrameRate(stream: stream)
            detectedCodecID = stream.pointee.codecpar.pointee.codec_id
            width = stream.pointee.codecpar.pointee.width
            height = stream.pointee.codecpar.pointee.height
        }
        let codecName: String? = {
            guard detectedCodecID != AV_CODEC_ID_NONE,
                  let cstr = avcodec_get_name(detectedCodecID) else { return nil }
            return String(cString: cstr)
        }()
        let snappedRate = detectedRate.flatMap { FrameRateSnap.snap($0) }
        let duration = demuxer.duration
        // Live-stream hint: duration absent + network-feed URL scheme.
        // Heuristic only; hosts decide whether to flip
        // LoadOptions.isLive based on this plus their own context
        // (e.g. an IPTV catalog entry vs a movie file).
        let liveSchemes: Set<String> = ["http", "https", "udp", "rtp", "rtsp"]
        let isLive = duration <= 0
            && liveSchemes.contains(url.scheme?.lowercased() ?? "")

        return SourceProbe(
            url: url,
            durationSeconds: duration,
            videoFormat: detectedFormat,
            videoCodecID: Int32(bitPattern: detectedCodecID.rawValue),
            videoCodecName: codecName,
            videoWidth: width,
            videoHeight: height,
            videoFrameRate: snappedRate,
            isDolbyVision: detectedFormat == .dolbyVision,
            audioTracks: demuxer.audioTrackInfos(),
            subtitleTracks: demuxer.subtitleTrackInfos(),
            isLive: isLive
        )
    }

    // MARK: - SW-decoder repro probe

    /// One-shot SW-decoder repro for `aetherctl swdecode` and any
    /// future host-side diagnostic that wants to localise SW-pipeline
    /// failures (MPEG-4 Part 2, MPEG-2, VC-1, AV1 on platforms without
    /// HW AV1) without spinning up a render target.
    ///
    /// Opens the demuxer, opens `SoftwareVideoDecoder` for the video
    /// stream, reads up to `maxPackets` packets and feeds the video
    /// ones to the decoder, returns counters + first-frame metadata.
    /// Useful failure modes the result discriminates:
    ///
    /// - `openSucceeded == false`: decoder couldn't open (FFmpegBuild
    ///   missing the libavcodec decoder, codec-private extradata
    ///   malformed). `openError` carries the reason.
    /// - `openSucceeded == true && framesDecoded == 0`: decoder
    ///   opened but never produced a frame from the packets fed.
    ///   Suggests pixel-format conversion failure or all-skipped
    ///   non-IDR packets.
    /// - `framesDecoded > 0` with a populated `firstFramePixelFormat`:
    ///   SW decode path is functionally healthy end-to-end; if real
    ///   playback still hangs, the failure is downstream
    ///   (`SoftwarePlaybackHost` frame-enqueue, `AVSampleBufferDisplayLayer`
    ///   attach, audio-clock sync).
    public nonisolated static func swDecodeProbe(
        url: URL,
        maxPackets: Int = 100,
        options: LoadOptions = .init()
    ) throws -> SoftwareDecodeProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            throw AetherEngineError.noVideoStream
        }

        let codecID = stream.pointee.codecpar.pointee.codec_id
        let codecName: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "unknown" }
            return String(cString: cstr)
        }()
        let width = stream.pointee.codecpar.pointee.width
        let height = stream.pointee.codecpar.pointee.height

        let decoder = SoftwareVideoDecoder()
        // Captured-by-reference accumulators via a class so the onFrame
        // closure can mutate them safely without inout / @escaping
        // capture gymnastics. Closure fires synchronously from inside
        // avcodec_send_packet / receive_frame, all on this thread.
        final class Accum {
            var framesDecoded = 0
            var firstFramePixelFormat: String?
            var firstFrameWidth: Int = 0
            var firstFrameHeight: Int = 0
        }
        let accum = Accum()

        do {
            try decoder.open(stream: stream) { pixelBuffer, _, _ in
                accum.framesDecoded += 1
                if accum.firstFramePixelFormat == nil {
                    let pfType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                    let bytes: [UInt8] = [
                        UInt8((pfType >> 24) & 0xff),
                        UInt8((pfType >> 16) & 0xff),
                        UInt8((pfType >> 8) & 0xff),
                        UInt8(pfType & 0xff),
                    ]
                    let printable = bytes.map { ($0 >= 0x20 && $0 < 0x7f) ? $0 : 0x2e }
                    let fourCC = String(bytes: printable, encoding: .ascii) ?? "????"
                    accum.firstFramePixelFormat = "\(fourCC) (0x\(String(pfType, radix: 16)))"
                    accum.firstFrameWidth = CVPixelBufferGetWidth(pixelBuffer)
                    accum.firstFrameHeight = CVPixelBufferGetHeight(pixelBuffer)
                }
            }
        } catch {
            return SoftwareDecodeProbeResult(
                codecName: codecName,
                codecID: Int32(bitPattern: codecID.rawValue),
                width: width,
                height: height,
                openSucceeded: false,
                openError: "\(error)",
                packetsRead: 0,
                packetsFedToDecoder: 0,
                framesDecoded: 0,
                firstFramePixelFormat: nil,
                firstFrameWidth: 0,
                firstFrameHeight: 0,
                firstError: "decoder open failed: \(error)"
            )
        }
        defer { decoder.close() }

        var packetsRead = 0
        var packetsFedToDecoder = 0
        var firstError: String?

        while packetsRead < maxPackets, accum.framesDecoded < maxPackets {
            do {
                guard let packet = try demuxer.readPacket() else {
                    break  // EOF
                }
                packetsRead += 1
                if packet.pointee.stream_index == videoIdx {
                    packetsFedToDecoder += 1
                    decoder.decode(packet: packet)
                }
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            } catch {
                if firstError == nil {
                    firstError = "\(error)"
                }
                break
            }
        }
        decoder.flush()

        return SoftwareDecodeProbeResult(
            codecName: codecName,
            codecID: Int32(bitPattern: codecID.rawValue),
            width: width,
            height: height,
            openSucceeded: true,
            openError: nil,
            packetsRead: packetsRead,
            packetsFedToDecoder: packetsFedToDecoder,
            framesDecoded: accum.framesDecoded,
            firstFramePixelFormat: accum.firstFramePixelFormat,
            firstFrameWidth: accum.firstFrameWidth,
            firstFrameHeight: accum.firstFrameHeight,
            firstError: firstError
        )
    }

    // MARK: - Public load

    /// Load a media file or stream URL. Replaces any current playback.
    ///
    /// Behavior:
    /// 1. Tears down the previous session.
    /// 2. Briefly opens the demuxer to detect format + frame rate.
    /// 3. Programs `AVDisplayCriteria` from the detected metadata
    ///    (DV → `dvh1`, others → `hvc1`; refresh rate snapped to a
    ///    standard rate; honors Match Content + Match Frame Rate).
    /// 4. Waits for the panel mode-switch to settle.
    /// 5. Spins up `HLSVideoEngine` + `NativeAVPlayerHost`.
    ///
    /// VP9 / AV1 sources gate on a runtime VideoToolbox capability
    /// probe; on hardware that can't decode them, the engine throws
    /// `HLSVideoEngine.HLSVideoEngineError.unsupportedCodec` and the
    /// host should surface that to the user. Dolby Vision Profile 7
    /// (dual-layer) and Profile 8.2 (SDR base) similarly throw.
    ///
    /// - Parameters:
    ///   - url: Media source (http/https/file).
    ///   - startPosition: Seconds into the stream to start at (resume).
    ///   - options: Engine-internal toggles. See `LoadOptions`.
    ///   - audioSourceStreamIndex: Optional container stream index for
    ///     the audio track to mux into the output. When non-nil, this is
    ///     used instead of `av_find_best_stream`'s automatic pick. Lets
    ///     the host honor a saved language preference on the very first
    ///     frame without bouncing through a separate
    ///     `selectAudioTrack` reload (which would cost a second of
    ///     "default-language audio plus black frame" at session start).
    ///     Validated against the container; an invalid index falls back
    ///     to the auto pick.
    public func load(
        url: URL,
        startPosition: Double? = nil,
        options: LoadOptions = .init(),
        audioSourceStreamIndex: Int32? = nil
    ) async throws {
        // Preserve the native AVPlayer host across a native->native reload
        // so AVKit's system Now-Playing registration survives the seam
        // (issue #15). Captured before stopInternal resets playbackBackend.
        // If this source instead routes to the software path, the SW branch
        // in the dispatch below releases the preserved host.
        let priorBackendWasNative = (playbackBackend == .native)
        stopInternal(keepNativeHost: priorBackendWasNative)
        loadedURL = url
        loadedOptions = options
        isLive = options.isLive
        state = .loading
        currentTime = 0
        nativeClockSeconds = 0
        duration = 0
        progress = 0
        audioTracks = []
        subtitleTracks = []
        subtitleCueDiagnosticCount = 0

        // 1. Brief demuxer probe to grab format + frame rate + track
        //    metadata. The HLSVideoEngine spun up below re-opens
        //    internally; the double-open keeps the failure-mode matrix
        //    small.
        var detectedFormat: VideoFormat = .sdr
        var effectiveFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedDVProfile: Bool = false
        var detectedCodecID: AVCodecID = AV_CODEC_ID_NONE
        var probedAudioTracks: [TrackInfo] = []
        var probedSubtitleTracks: [TrackInfo] = []
        var probedDefaultAudioIndex: Int32 = -1
        let probe = Demuxer()
        var probeOpened = false
        do {
            // Detach the HTTP probe + avformat_open_input + avformat_find_stream_info
            // off the @MainActor so the SwiftUI host stays responsive.
            // On a slow CDN this is the dominant blocking call in
            // `load()` (~6 s). Per Delarkz's AetherEngine#10: a @MainActor
            // async function whose body is synchronous Swift blocks the
            // main thread despite the `async` signature — there's no
            // suspension point. `Task.detached.value` introduces a real
            // hop to a background thread so the @MainActor runloop keeps
            // ticking.
            try await Task.detached(priority: .userInitiated) { [probe] in
                try probe.open(url: url, extraHeaders: options.httpHeaders)
            }.value
            probeOpened = true
            let videoIdx = probe.videoStreamIndex
            if videoIdx >= 0, let stream = probe.stream(at: videoIdx) {
                detectedFormat = Self.detectVideoFormat(stream: stream)
                effectiveFormat = Self.effectiveVideoFormat(detected: detectedFormat, stream: stream)
                detectedRate = Self.detectFrameRate(stream: stream)
                // DrHurt #4 (2026-05-26): use SOURCE-detected DV profile,
                // not effective-format. Drives `codecTag = dvh1` in the
                // display-criteria apply() call below, asking AVDisplayManager
                // for DV mode on every DV source regardless of whether the
                // panel reports DV capability. Apple's HLS pipeline + tone-
                // mapper is industry-leading at downgrading DV → HDR10
                // when the active panel mode can't host DV; we let AVPlayer
                // do that work instead of pre-emptively stripping DV signals
                // engine-side. Pairs with the always-emit-SUPPLEMENTAL +
                // no-strip change in HLSVideoEngine's profile81 / profile84
                // emission.
                detectedDVProfile = (detectedFormat == .dolbyVision)
                detectedCodecID = stream.pointee.codecpar.pointee.codec_id
                sourceVideoWidth = stream.pointee.codecpar.pointee.width
                sourceVideoHeight = stream.pointee.codecpar.pointee.height
                lastDetectedVideoCodec = detectedCodecID
            }
            probedAudioTracks = probe.audioTrackInfos()
            probedSubtitleTracks = probe.subtitleTrackInfos()
            probedDefaultAudioIndex = probe.audioStreamIndex
            // probe.close() deferred: ownership transfers to
            // `loadNative` (native dispatch) which hands it to
            // HLSVideoEngine for reuse, or we close it explicitly in
            // the software dispatch branch below since SW path opens
            // its own Demuxer. On the error path probe was never
            // opened, so close is a no-op.
        } catch {
            EngineLog.emit("[AetherEngine] probe failed (\(error)); proceeding without criteria", category: .engine)
        }

        // Source format is what the probe found in the file, before any
        // panel clamping. Stats overlays use this to label "what the file
        // is" vs `videoFormat` labelling "what the panel is showing".
        // (`videoFormat` itself is published lower in this method, after
        // the criteria handshake has settled and we know which dynamic-
        // range mode the panel actually adopted — see comment on the
        // `panelHDRAfterHandshake` snapshot below.)
        sourceVideoFormat = detectedFormat
        audioTracks = probedAudioTracks
        subtitleTracks = probedSubtitleTracks
        // Mirror the audio stream HLSVideoEngine will actually pick.
        // When the host passed an override, that takes precedence; if
        // the override is invalid we fall back to the auto pick to
        // match the engine's own internal cascade. nil when the source
        // has no audio at all, so the host can hide the picker without
        // having to recompute the default itself.
        let resolvedInitialAudio: Int32
        if let override = audioSourceStreamIndex,
           probedAudioTracks.contains(where: { $0.id == Int(override) }) {
            resolvedInitialAudio = override
        } else {
            resolvedInitialAudio = probedDefaultAudioIndex
        }
        activeAudioTrackIndex = resolvedInitialAudio >= 0 ? Int(resolvedInitialAudio) : nil
        let snappedRate = FrameRateSnap.snap(detectedRate ?? 0)
        EngineLog.emit("[AetherEngine] load url=\(url.absoluteString) source-format=\(detectedFormat) effective-format=\(effectiveFormat) rate=\(snappedRate.map { String(format: "%.3f", $0) } ?? "n/a")", category: .engine)

        // 1.5 Audio-only fast path. When the host asked for audio-only
        //     or the probe found no video stream, route to the lean
        //     AudioPlaybackHost and return before the display-criteria
        //     handshake and the video dispatch below ever run. The probe
        //     opened its own AVFormatContext; close it since the audio
        //     host opens its own Demuxer.
        let hasVideoStream = probeOpened && probe.videoStreamIndex >= 0
        if Self.shouldUseAudioOnlyPath(audioOnlyRequested: options.audioOnly, hasVideoStream: hasVideoStream) {
            // Read the chosen audio stream's codec before closing the probe
            // so AVPlayer-decodable audio takes the native path.
            let audioCodecID: AVCodecID = (probeOpened && resolvedInitialAudio >= 0)
                ? (probe.stream(at: resolvedInitialAudio)?.pointee.codecpar.pointee.codec_id ?? AV_CODEC_ID_NONE)
                : AV_CODEC_ID_NONE
            if probeOpened { probe.close() }
            let useNativeAudio = Self.avPlayerCanDecodeAudio(audioCodecID)
            EngineLog.emit("[AetherEngine] audio dispatch: codec=\(audioCodecID.rawValue) -> \(useNativeAudio ? "AVPlayer" : "FFmpeg")", category: .engine)
            do {
                if useNativeAudio {
                    try await loadAudioNative(url: url, startPosition: startPosition, httpHeaders: options.httpHeaders)
                    playbackBackend = .audio
                    activeVideoDecoder = nil
                    activeAudioDecoder = "AVPlayer"
                    videoFormat = .sdr
                    audioAVPlayerHost?.play()
                    state = .playing
                    startMemoryProbe()
                } else {
                    try await loadAudio(
                        url: url,
                        sourceHTTPHeaders: options.httpHeaders,
                        startPosition: startPosition,
                        audioSourceStreamIndex: resolvedInitialAudio >= 0 ? resolvedInitialAudio : nil
                    )
                    playbackBackend = .audio
                    activeVideoDecoder = nil
                    activeAudioDecoder = Self.softwareAudioDecoderLabel(
                        audioTracks: probedAudioTracks,
                        activeIndex: resolvedInitialAudio
                    )
                    videoFormat = .sdr
                    audioHost?.play()
                    state = .playing
                    startMemoryProbe()
                }
            } catch {
                state = .error("Failed to load: \(error.localizedDescription)")
                throw error
            }
            return
        }

        // 2. Display-criteria handshake. Drive from the effective format so
        //    a non-DV panel doesn't get asked to switch into dvh1 mode.
        if !options.suppressDisplayCriteria {
            let codecTag: FourCharCode? = detectedDVProfile ? 0x64766831 : nil
            let willSwitch = displayCriteria.apply(
                format: effectiveFormat,
                frameRate: snappedRate,
                codecTag: codecTag,
                omitColorExtensions: options.omitCriteriaColorExtensions
            )
            if willSwitch {
                await displayCriteria.waitForSwitch()
            }
        }

        // 2.5. Post-handshake panel-mode snapshot. tvOS exposes only one
        //      combined `isDisplayCriteriaMatchingEnabled` toggle — there's
        //      no API to tell whether Match Dynamic Range is on or only
        //      Match Frame Rate. A user with rate matching on and range
        //      matching off (DrHurt #4 2026-05-27 residual) reports the
        //      combined flag as `true`, the host passes
        //      `matchContentEnabled=true` in LoadOptions, but the panel
        //      stays SDR when we ask for HDR. The old gates
        //      (`supportsHDR && matchContentEnabled`) treated that as "will
        //      switch", routed via master playlist with `VIDEO-RANGE=PQ`,
        //      and AVPlayer rejected with -11848 / -11868 because the
        //      strict variant filter saw HDR variants on an SDR-locked
        //      panel.
        //
        //      Reading `currentEDRHeadroom` after `waitForSwitch` is the
        //      only authoritative way to know which sub-toggle is active:
        //      headroom > 1.0 means the panel accepted the HDR mode
        //      (match-range was on), headroom == 1.0 means it refused
        //      (match-range off). Pass that empirical reading to both the
        //      published `videoFormat` and HLSVideoEngine's master-vs-
        //      media routing so the two stay in step.
        //
        //      Suppressed-criteria hosts (AVKit-sole-writer path) fall
        //      back to the caller's pre-load snapshot — their criteria
        //      fires later from AVKit and we can't probe the outcome
        //      from here.
        let panelHDRAfterHandshake: Bool
        if options.suppressDisplayCriteria {
            panelHDRAfterHandshake = options.panelIsInHDRMode
        } else {
            panelHDRAfterHandshake = displayCriteria.currentPanelIsHDR()
        }
        videoFormat = (effectiveFormat != .sdr && panelHDRAfterHandshake)
            ? effectiveFormat
            : .sdr

        // 3. Dispatch by codec. The native AVPlayer path carries Atmos
        //    passthrough, Dolby Vision HDMI handshake, and the system
        //    HDR / HDR10+ pipeline — so we route there whenever
        //    AVPlayer's HLS-fMP4 pipeline can take the codec. The SW
        //    pipeline (dav1d / libavcodec → AVSampleBufferDisplayLayer)
        //    fills the gaps:
        //
        //    - AV1: native on iOS 17+ / macOS 14+ (Apple ships dav1d in
        //      VideoToolbox), SW on tvOS (Apple doesn't ship dav1d on
        //      tvOS and no Apple TV chip has HW AV1). The probe in
        //      `VTCapabilityProbe.av1Available` decides per-platform.
        //    - VP9: always SW. Empirically AVPlayer's HLS manifest
        //      parser rejects the `vp09` CODECS attribute even though
        //      VideoToolbox can HW-decode the codec — verified via
        //      aetherctl on macOS 26 against a libvpx-vp9 source
        //      (AVPlayer GETs master.m3u8 + media.m3u8 then silently
        //      stops fetching, `item.status` never leaves `.unknown`).
        //    - VP8: always SW. Same HLS-manifest-parser rejection as
        //      VP9; VP8 was never part of the HLS Authoring Spec CODECS
        //      list. Useful for legacy WebM rips.
        //    - MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video,
        //      VC-1: always SW. AVPlayer's HLS-fMP4 pipeline does not
        //      accept these codecs (`mp4v.20.X`, `mp2v`, `vc-1` are
        //      not in Apple's HLS Authoring Spec CODECS list).
        //      libavcodec ships native decoders for all three in
        //      FFmpegBuild; SoftwareVideoDecoder is codec-generic.
        //
        //    Everything else (HEVC / H.264) goes through the native
        //    path unconditionally.
        let useSoftwarePath: Bool
        switch detectedCodecID {
        case AV_CODEC_ID_AV1:
            useSoftwarePath = !VTCapabilityProbe.av1Available
        case AV_CODEC_ID_VP9,
             AV_CODEC_ID_VP8,
             AV_CODEC_ID_MPEG4,
             AV_CODEC_ID_MPEG2VIDEO,
             AV_CODEC_ID_VC1:
            useSoftwarePath = true
        default:
            useSoftwarePath = false
        }
        EngineLog.emit("[AetherEngine] dispatch: codec=\(detectedCodecID.rawValue) → \(useSoftwarePath ? "software" : "native")", category: .engine)

        do {
            if useSoftwarePath {
                // SW path opens its own Demuxer inside
                // SoftwarePlaybackHost.load — no reuse here. Close the
                // probe so it doesn't linger as a parallel open
                // AVFormatContext + AVIOReader for the entire SW
                // playback session.
                if probeOpened { probe.close() }
                // A native->native reload may have preserved the previous
                // AVPlayer host (issue #15), but this source routes to the
                // software path. Release it now: the SW pipeline renders
                // into its own layer and the host's currentAVPlayer sink
                // relies on a nil publish to drop AVKit's now-stale player.
                if nativeHost != nil {
                    nativeHost?.tearDown()
                    nativeHost = nil
                    currentAVPlayer = nil
                }
                try await loadSoftware(
                    url: url,
                    sourceHTTPHeaders: options.httpHeaders,
                    startPosition: startPosition,
                    audioSourceStreamIndex: audioSourceStreamIndex
                )
                playbackBackend = .software
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: detectedCodecID, isSoftware: true
                )
                activeAudioDecoder = Self.softwareAudioDecoderLabel(
                    audioTracks: probedAudioTracks,
                    activeIndex: resolvedInitialAudio
                )
                presentCurrentLayer()
                softwareHost?.play()
                state = .playing
                startMemoryProbe()
                startLiveTelemetrySampler()
            } else {
                // Native path: hand the probe Demuxer to loadNative.
                // HLSVideoEngine.start() reuses it instead of running
                // avformat_open_input + find_stream_info a second
                // time, saving ~1-3 s of cold-start latency on slow
                // CDN sources. The cue prewarm seek inside
                // HLSVideoEngine.start invalidates any stale read
                // position from the probe so position state is
                // irrelevant. If probe failed to open, pass nil and
                // HLSVideoEngine falls back to opening fresh.
                try await loadNative(
                    url: url,
                    sourceHTTPHeaders: options.httpHeaders,
                    startPosition: startPosition,
                    audioSourceStreamIndex: audioSourceStreamIndex,
                    keepDvh1TagWithoutDV: options.keepDvh1TagWithoutDV,
                    matchContentEnabled: options.matchContentEnabled,
                    panelIsInHDRMode: panelHDRAfterHandshake,
                    audioBridgeMode: options.audioBridgeMode,
                    preopenedDemuxer: probeOpened ? probe : nil
                )
                playbackBackend = .native
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: detectedCodecID, isSoftware: false
                )
                // Native audio identity comes from HLSVideoEngine's
                // cascade: stream-copy is preserved as a passthrough
                // label, FLAC bridge re-labels with the source codec,
                // video-only leaves the field nil.
                activeAudioDecoder = nativeVideoSession?.audioPipelineDescription
                presentCurrentLayer()
                // Gate play() on panel handshake completion. With the
                // host's `appliesPreferredDisplayCriteriaAutomatically`
                // = true, AVKit drives the criteria write from the
                // live AVPlayerItem's formatDescription (which reads
                // dvcC correctly from the fMP4 sample entry via
                // private CoreMedia hooks). waitForSwitch's Stage 1
                // grace gives AVKit time to fire that write; Stage 2
                // waits for the panel handshake to settle so the
                // first decoded frame doesn't hit a mid-transition
                // panel. For P5 specifically (no HDR10 base, requires
                // immediate DV mode), this is what makes cold-start
                // playback land.
                await displayCriteria.waitForSwitch()
                // Auto-play after load. AVPlayer's
                // `automaticallyWaitsToMinimizeStalling = true` (default)
                // handles "play before ready" correctly: it transitions
                // through `waitingToPlayAtSpecifiedRate`, buffers, and
                // starts playing once enough segments are in.
                nativeHost?.play()
                state = .playing
                startMemoryProbe()
                startLiveTelemetrySampler()
            }
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
    }

    /// Open HLSVideoEngine against the source, wire NativeAVPlayerHost
    /// to its loopback URL, forward host @Published into the engine's
    /// own published mirrors. `audioSourceStreamIndex` overrides the
    /// auto-picked audio stream when non-nil; used by the mid-playback
    /// audio-track-switch path so the new pipeline picks up the host's
    /// chosen language without a separate API entry point.
    private func loadNative(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32? = nil,
        keepDvh1TagWithoutDV: Bool = false,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        preopenedDemuxer: Demuxer? = nil
    ) async throws {
        let session = HLSVideoEngine(
            url: url,
            sourceHTTPHeaders: sourceHTTPHeaders,
            dvModeAvailable: Self.displayCapabilities.supportsDolbyVision,
            displaySupportsHDR: Self.displayCapabilities.supportsHDR,
            keepDvh1TagWithoutDV: keepDvh1TagWithoutDV,
            matchContentEnabled: matchContentEnabled,
            panelIsInHDRMode: panelIsInHDRMode,
            audioSourceStreamIndexOverride: audioSourceStreamIndex,
            initialPositionSeconds: startPosition,
            audioBridgeMode: audioBridgeMode,
            preopenedDemuxer: preopenedDemuxer
        )
        session.onFirstHDR10PlusDetected = { [weak self] in
            Task { @MainActor in self?.handleHDR10PlusDetected() }
        }
        session.onPlaylistShiftChanged = { [weak self] seconds in
            Task { @MainActor in
                guard let self = self else { return }
                self.playlistShiftSeconds = seconds
                // Re-fold against the raw clock so the published source-PTS
                // currentTime tracks the new shift immediately (e.g. after a
                // restart that landed past the planned keyframe), rather than
                // lagging until the next periodic time tick.
                self.currentTime = self.nativeClockSeconds + seconds
                self.sourceTime = self.currentTime
            }
        }
        // AVPlayer HLS playback over the loopback HTTP server. Detach
        // the synchronous network I/O inside `session.start()` (opens
        // its own Demuxer + prewarm seek = another ~1-3 s on slow CDN)
        // so the @MainActor doesn't block. See the probe-detach comment
        // above for the rationale.
        let playbackURL = try await Task.detached(priority: .userInitiated) { [session] in
            try session.start()
        }.value
        self.nativeVideoSession = session

        // Reuse the existing native host across a native->native reload
        // (episode change, audio-track switch) so the AVPlayer instance,
        // and AVKit's MediaRemote system Now-Playing registration bound to
        // it, survives the seam. Building a fresh AVPlayer here makes AVKit
        // fail to re-register ("Code=14 client callback") and the iPhone
        // Control Center widget goes blank (issue #15). stopInternal kept
        // the host alive (keepNativeHost) and unloaded its old item; a
        // brand-new host is built only on a cold load or after a
        // native->SW transition released the previous one.
        let host: NativeAVPlayerHost
        if let existing = nativeHost {
            host = existing
        } else {
            host = NativeAVPlayerHost()
        }
        host.playerLayer.videoGravity = _videoGravity
        // Replay any pre-load externalMetadata onto the host so its
        // AVPlayerItem picks it up before AVPlayer assigns the item. Hosts
        // that called `engine.setExternalMetadata` before `engine.load`
        // rely on this transfer.
        if !pendingExternalMetadata.isEmpty {
            host.setExternalMetadata(pendingExternalMetadata)
        }
        self.nativeHost = host
        // Publish before wiring up the @Published mirrors below so any host
        // that subscribes via the same Combine sink sees the AVPlayer
        // instance before the first time / state update lands. Only emit
        // when the instance actually changed: re-publishing the same player
        // would drive the host's currentAVPlayer sink to reassign
        // AVPlayerViewController.player to the same instance, re-triggering
        // the exact AVKit re-registration this reuse path exists to avoid.
        if currentAVPlayer !== host.avPlayer {
            self.currentAVPlayer = host.avPlayer
        }

        nativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                // Fold the producer's shift into the published clock so
                // currentTime carries source PTS, unifying it with the
                // SW / audio paths. nativeClockSeconds keeps the raw value
                // for onPlaylistShiftChanged to re-derive against.
                self.nativeClockSeconds = value
                self.currentTime = value + self.playlistShiftSeconds
                self.sourceTime = self.currentTime
            }
            .store(in: &nativeCancellables)
        host.$duration
            .sink { [weak self] value in
                if value > 0 { self?.duration = value }
            }
            .store(in: &nativeCancellables)
        host.$isReady
            .sink { [weak self] ready in
                guard let self = self else { return }
                if ready, self.state == .loading {
                    self.state = .paused
                }
            }
            .store(in: &nativeCancellables)
        host.$failureMessage
            .compactMap { $0 }
            .sink { [weak self] msg in self?.state = .error(msg) }
            .store(in: &nativeCancellables)
        host.$didReachEnd
            .filter { $0 }
            .sink { [weak self] _ in
                // AVPlayer reached end-of-stream. Flip to .idle so the
                // host's end-of-content flow fires.
                self?.state = .idle
            }
            .store(in: &nativeCancellables)
        host.$timeControlStatus
            .sink { [weak self] status in
                guard let self = self else { return }
                // Reconcile `state` when something other than the engine's
                // own play()/pause() drives the AVPlayer: AVKit's transport
                // bar (kept active for Control Center skip routing), CC's
                // play/pause, or the hardware play/pause button AVKit handles
                // internally. Without this `state` goes stale and the host's
                // togglePlayPause() resolves to a no-op (swallowed press).
                // Only reconcile between the two steady transport states;
                // never clobber loading/seeking/error/idle.
                // `.waitingToPlayAtSpecifiedRate` is a buffer stall while the
                // user still intends to play, so it maps to .playing and the
                // play/pause icon doesn't flicker on a rebuffer.
                guard self.state == .playing || self.state == .paused else { return }
                switch status {
                case .paused:
                    if self.state != .paused { self.state = .paused }
                case .playing, .waitingToPlayAtSpecifiedRate:
                    if self.state != .playing { self.state = .playing }
                @unknown default:
                    break
                }
            }
            .store(in: &nativeCancellables)

        // appliesPerFrameHDRDisplayMetadata = true unconditionally.
        // The earlier `session.servingMasterPlaylist` gating was a
        // speculative memory-leak mitigation (~3 MB/sec RSS growth on
        // long DV 8.1 sessions, never measurement-validated). DrHurt #4
        // 2026-05-26 correctly flagged that DV Profile 5 is pure DV with
        // no HDR10 base layer — the per-frame DV RPU is what AVPlayer's
        // tone-mapper needs to render anything at all on a non-DV panel
        // routed via the media playlist (`dv5OnSdrLockedNonDVPanel`
        // path). Setting the flag to false on that path was breaking
        // P5 playback entirely. Apple's default for the property is
        // also true (so setting it true explicitly is a no-op against
        // an unset property anyway; we keep the explicit write so
        // diagnostics surface the live value).
        host.load(url: playbackURL,
                  startPosition: startPosition,
                  perFrameHDR: true)
    }

    /// Open a `SoftwarePlaybackHost` against the source and wire its
    /// @Published mirror into the engine's own surface. Used when the
    /// source's video codec isn't decodable by AVPlayer on the active
    /// platform (today: AV1 on Apple TV). Same lifecycle shape as
    /// `loadNative`: host loads the URL itself (no HLS-fMP4 wrapper —
    /// the SW pipeline reads the source directly through its own
    /// Demuxer).
    /// Activate the shared audio session for the renderer paths that have
    /// no AVPlayerViewController to own activation: SoftwarePlaybackHost
    /// (FFmpeg decode -> AVSampleBufferAudioRenderer) and the audio-only
    /// hosts. The native AVPlayer video path deliberately does NOT call
    /// this — AVKit activates per playback so tvOS can auto-negotiate the
    /// HDMI route (issue #24). Restores the preferred-channel hint the
    /// init path used to set, now scoped to the renderer paths.
    private func activateRendererAudioSession() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do { try session.setActive(true) }
        catch {
            EngineLog.emit("[AetherEngine] activateRendererAudioSession error: \(error)", category: .engine)
        }
        let maxCh = session.maximumOutputNumberOfChannels
        if maxCh > 2 { try? session.setPreferredOutputNumberOfChannels(maxCh) }
        EngineLog.emit("[AetherEngine] renderer audio session active: maxChannels=\(maxCh) preferred=\(session.preferredOutputNumberOfChannels) output=\(session.outputNumberOfChannels)", category: .engine)
        #endif
    }

    private func loadSoftware(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32?
    ) async throws {
        activateRendererAudioSession()
        let host = SoftwarePlaybackHost()
        host.onFirstHDR10PlusDetected = { [weak self] in
            Task { @MainActor in self?.handleHDR10PlusDetected() }
        }
        self.softwareHost = host
        // SW path's currentTime tracks source PTS directly, so the
        // AVPlayer-clock shift is 0 and sourceTime mirrors currentTime.
        self.playlistShiftSeconds = 0

        softwareCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.currentTime = value
                self.sourceTime = value
            }
            .store(in: &softwareCancellables)
        host.$duration
            .sink { [weak self] value in
                if value > 0 { self?.duration = value }
            }
            .store(in: &softwareCancellables)
        host.$isReady
            .sink { [weak self] ready in
                guard let self = self else { return }
                if ready, self.state == .loading {
                    self.state = .paused
                }
            }
            .store(in: &softwareCancellables)
        host.$failureMessage
            .compactMap { $0 }
            .sink { [weak self] msg in self?.state = .error(msg) }
            .store(in: &softwareCancellables)
        host.$didReachEnd
            .filter { $0 }
            .sink { [weak self] _ in
                self?.state = .idle
            }
            .store(in: &softwareCancellables)

        // Detach the host's load (its body is synchronous despite the
        // `async` signature — a @MainActor caller awaiting it doesn't
        // yield to the runloop). Mirrors the same pattern applied to
        // the probe and to `session.start()`.
        try await Task.detached(priority: .userInitiated) { [host] in
            try await host.load(
                url: url,
                sourceHTTPHeaders: sourceHTTPHeaders,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex
            )
        }.value
    }

    /// Open an `AudioPlaybackHost` against an audio-only source and wire
    /// its @Published mirror into the engine's surface. The lean path:
    /// no HLS pipeline, no display layer, no display-criteria handshake.
    /// Same lifecycle shape as `loadSoftware`.
    private func loadAudio(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32?
    ) async throws {
        activateRendererAudioSession()
        let host = AudioPlaybackHost()
        self.audioHost = host
        // Audio path tracks source PTS directly: no AVPlayer-clock shift.
        self.playlistShiftSeconds = 0

        audioCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.currentTime = value
                self.sourceTime = value
            }
            .store(in: &audioCancellables)
        host.$duration
            .sink { [weak self] value in
                if value > 0 { self?.duration = value }
            }
            .store(in: &audioCancellables)
        host.$isReady
            .sink { [weak self] ready in
                guard let self = self else { return }
                if ready, self.state == .loading {
                    self.state = .paused
                }
            }
            .store(in: &audioCancellables)
        host.$failureMessage
            .compactMap { $0 }
            .sink { [weak self] msg in self?.state = .error(msg) }
            .store(in: &audioCancellables)
        host.$didReachEnd
            .filter { $0 }
            .sink { [weak self] _ in
                self?.state = .idle
            }
            .store(in: &audioCancellables)

        // Detach the host's load (its body is synchronous despite the
        // async signature) so the @MainActor runloop keeps ticking.
        try await Task.detached(priority: .userInitiated) { [host] in
            try await host.load(
                url: url,
                sourceHTTPHeaders: sourceHTTPHeaders,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex
            )
        }.value
    }

    /// Open an `AudioAVPlayerHost` against an audio-only source AVPlayer can
    /// decode natively, and wire its @Published mirror into the engine's
    /// surface. The native, energy-efficient default for audio-only; the
    /// FFmpeg `loadAudio` path is the fallback for codecs AVPlayer cannot
    /// decode. Same lifecycle shape as loadAudio.
    private func loadAudioNative(
        url: URL,
        startPosition: Double?,
        httpHeaders: [String: String]
    ) async throws {
        // Reuse the persistent host (and its MPNowPlayingSession) across
        // tracks; only create it the first time. host.load() below swaps the
        // item via replaceCurrentItem on the same AVPlayer.
        activateRendererAudioSession()
        let host = audioAVPlayerHost ?? AudioAVPlayerHost()
        self.audioAVPlayerHost = host
        self.audioAVPlayerActive = true
        self.playlistShiftSeconds = 0
        // Reclaim Now-Playing ownership for this session on each track start,
        // so the Home badge + remote commands stay bound across a pause.
        host.becomeActiveNowPlaying()
        host.setExternalMetadata(pendingExternalMetadata)

        audioNativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.currentTime = value
                self.sourceTime = value
            }
            .store(in: &audioNativeCancellables)
        host.$duration
            .sink { [weak self] value in
                if value > 0 { self?.duration = value }
            }
            .store(in: &audioNativeCancellables)
        host.$isReady
            .sink { [weak self] ready in
                guard let self = self else { return }
                if ready, self.state == .loading {
                    self.state = .paused
                }
            }
            .store(in: &audioNativeCancellables)
        host.$failureMessage
            .compactMap { $0 }
            .sink { [weak self] msg in self?.state = .error(msg) }
            .store(in: &audioNativeCancellables)
        host.$didReachEnd
            .filter { $0 }
            .sink { [weak self] _ in
                self?.state = .idle
            }
            .store(in: &audioNativeCancellables)
        // NOTE: deliberately NO reconciliation of `state` from the host's
        // `timeControlStatus` on the audio path. All audio transport flows
        // through the engine's own play()/pause() (driven host-side by
        // MPRemoteCommandCenter handlers, the in-app .onPlayPauseCommand, and
        // the queue logic), so those are the single source of truth for
        // `state`. Feeding timeControlStatus back into `state` mis-latched a
        // TRANSIENT `.paused` that AVFoundation emits during the app's
        // background transition as a real pause: the engine flipped to
        // paused while audio kept playing, the published now-playing rate
        // went to 0, and tvOS (which reads MPNowPlayingInfoPropertyPlaybackRate
        // to infer play-vs-pause) then believed we were paused-while-playing,
        // breaking the system Now-Playing badge and the Siri Remote routing.
        // timeControlStatus is advisory display state, not a command source.

        try await Task.detached(priority: .userInitiated) { [host] in
            try await host.load(url: url, startPosition: startPosition, httpHeaders: httpHeaders)
        }.value
    }

    // MARK: - Transport

    public func play() {
        if audioAVPlayerActive, let host = audioAVPlayerHost {
            host.play()
        } else if let host = audioHost {
            host.play()
        } else if let host = softwareHost {
            host.play()
        } else {
            nativeHost?.play()
        }
        if state == .paused || state == .loading {
            state = .playing
        }
    }

    public func pause() {
        if audioAVPlayerActive, let host = audioAVPlayerHost {
            host.pause()
        } else if let host = audioHost {
            host.pause()
        } else if let host = softwareHost {
            host.pause()
        } else {
            nativeHost?.pause()
        }
        if state == .playing {
            state = .paused
        }
    }

    public func togglePlayPause() {
        // Only togglable from the steady transport states (and from
        // .loading, where the press means "start"). Ignore in
        // .seeking / .error / .idle, matching the prior behaviour.
        switch state {
        case .playing, .paused, .loading: break
        default: return
        }
        // Decide from the LIVE transport state, not the published `state`.
        // On the native path AVKit's transport / Control Center / the
        // hardware play/pause button can toggle the AVPlayer directly, and
        // the `$timeControlStatus` reconciliation that mirrors those toggles
        // into `state` is async. Reading the AVPlayer synchronously here
        // closes that gap so a fast press can't act on a stale value and
        // resolve to a no-op (the "swallowed press" symptom). The SW host
        // has no AVPlayer and no competing transport owner, so its `state`
        // is authoritative.
        let isPlaying: Bool
        if audioAVPlayerActive {
            // Audio host has no competing transport owner, so `state` is
            // authoritative (same reasoning as the software host).
            isPlaying = (state == .playing)
        } else if audioHost != nil {
            // Audio host has no competing transport owner, so `state` is
            // authoritative (same reasoning as the software host).
            isPlaying = (state == .playing)
        } else if softwareHost != nil {
            isPlaying = (state == .playing)
        } else if let nativeHost {
            isPlaying = nativeHost.isEffectivelyPlaying
        } else {
            isPlaying = (state == .playing)
        }
        if isPlaying { pause() } else { play() }
    }

    /// Tear down and reload from the current position. Call after
    /// returning from background; AVIO connections and VT sessions
    /// (where applicable) are invalidated by tvOS when the app is
    /// suspended.
    public func reloadAtCurrentPosition() async throws {
        guard let url = loadedURL else { return }
        let pos = currentTime
        try await load(url: url, startPosition: pos > 1 ? pos : nil, options: loadedOptions)
    }

    public func seek(to seconds: Double) async {
        // Live streams have no random-access guarantee; AVPlayer would
        // either stall indefinitely or land on a segment that the
        // playlist hasn't materialised. Hosts can hide the scrubber by
        // observing `$isLive` so this guard is a defence-in-depth.
        guard !isLive else {
            EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: source is live", category: .engine)
            return
        }
        let target = max(0, min(seconds, duration))
        // seek(to:) speaks source PTS (the unified engine clock). On the
        // native path AVPlayer's HLS clock sits at source - playlistShiftSeconds,
        // so convert before driving the host. The SW / audio hosts already
        // run on source time (shift 0), making this a no-op there.
        let clockTarget = target - playlistShiftSeconds
        state = .seeking
        if audioAVPlayerActive, let host = audioAVPlayerHost {
            await host.seek(to: clockTarget)
        } else if let host = audioHost {
            await host.seek(to: clockTarget)
        } else if let host = softwareHost {
            await host.seek(to: clockTarget)
        } else {
            // Sliding-window EVENT playlist: ensure the seek target's
            // segment is visible in the playlist before AVPlayer fetches
            // it. Without this, a long forward seek can land AVPlayer
            // on a segment that the playlist hasn't grown to expose
            // yet — AVPlayer either fails the seek or stalls until the
            // playlist's periodic refresh catches up.
            nativeVideoSession?.extendVisibleWindow(toCoverSeconds: clockTarget)
            nativeHost?.seek(to: clockTarget)
        }
        nativeClockSeconds = clockTarget
        currentTime = target
        sourceTime = target

        // Re-arm the side subtitle demuxer at the new playhead so cues
        // for the post-scrub content surface immediately. Skip when
        // sidecar SRT is active (it pre-decoded the whole file).
        if activeEmbeddedSubtitleStreamIndex >= 0, let url = loadedURL {
            let streamIdx = activeEmbeddedSubtitleStreamIndex
            embeddedSubtitleTask?.cancel()
            subtitleCues = []
            // Side-demuxer seeks in source PTS, which is the seek target.
            startEmbeddedSubtitleTask(url: url, streamIndex: streamIdx, startAt: target)
        }

        // AVPlayer surfaces post-seek readiness via its own KVO; the
        // engine optimistically flips back to .playing so the host UI
        // doesn't stick on .seeking when the seek lands fast.
        state = .playing
    }

    /// Deprecated alias for `seek(to:)`, which is now itself source-PTS
    /// based (the engine clock is unified onto source time). Retained so
    /// existing callers keep building; prefer `seek(to:)` in new code.
    @available(*, deprecated, renamed: "seek(to:)")
    public func seek(toSourceTime seconds: Double) async {
        await seek(to: seconds)
    }

    public func stop() {
        stopInternal()
        state = .idle
        currentTime = 0
        progress = 0
    }

    /// The active `AVPlayer` instance, when the native AVKit path is in
    /// use. `nil` while the software (AVSampleBufferDisplayLayer) path
    /// is active or no session is loaded. Published so hosts that drive
    /// an `AVPlayerViewController` for system Now Playing can rebind
    /// `.player` whenever the engine swaps the underlying instance
    /// (every `selectAudioTrack` reload tears the previous host down
    /// and brings up a fresh one, so a one-shot assignment goes stale).
    @Published public private(set) var currentAVPlayer: AVPlayer?

    #if os(tvOS) || os(iOS)
    /// The Now-Playing session bound to the active AVPlayer audio path, or
    /// nil when that path is not active (FFmpeg audio / video / idle). The
    /// host app registers transport commands on its `remoteCommandCenter` and
    /// writes metadata to its `nowPlayingInfoCenter` so the app stays the
    /// active Now-Playing app across a background pause (the shared singletons
    /// drop a paused bare AVPlayer on tvOS, killing the Home badge + the
    /// remote play route). See AudioAVPlayerHost for the full rationale.
    public var audioNowPlayingSession: MPNowPlayingSession? {
        audioAVPlayerActive ? audioAVPlayerHost?.nowPlayingSession : nil
    }
    #endif

    /// Pending externalMetadata for the next native load. Set via
    /// `setExternalMetadata(_:)` before `load(url:)`; consumed when
    /// `loadNative` creates the `NativeAVPlayerHost` and applied to
    /// the AVPlayerItem before AVPlayer.replaceCurrentItem. Survives
    /// across native loads so internal reloads (audio-track switch,
    /// background reopen) replay the metadata.
    private var pendingExternalMetadata: [AVMetadataItem] = []

    /// Stage the metadata items for the system Now Playing surface
    /// (title, artwork, description, etc.). Set this rather than writing
    /// to `MPNowPlayingInfoCenter.nowPlayingInfo` when using AVKit or
    /// `MPNowPlayingSession` with automatic publishing: those read
    /// metadata off `AVPlayerItem.externalMetadata`, while manual
    /// `MPNowPlayingInfoCenter` writes race against MediaPlayer's
    /// internal serial queue on tvOS 26 and trip an assertion.
    /// Safe to call BEFORE `load(url:)`: the items are stashed on
    /// the engine and replayed onto the AVPlayerItem the moment the
    /// native host is created.
    public func setExternalMetadata(_ items: [AVMetadataItem]) {
        pendingExternalMetadata = items
        nativeHost?.setExternalMetadata(items)
        audioAVPlayerHost?.setExternalMetadata(items)
    }

    /// Set playback volume (0.0 = mute, 1.0 = full).
    public var volume: Float {
        get { (audioAVPlayerActive ? audioAVPlayerHost?.volume : nil) ?? audioHost?.volume ?? softwareHost?.volume ?? nativeHost?.avPlayer.volume ?? 1.0 }
        set {
            audioAVPlayerHost?.volume = newValue
            audioHost?.volume = newValue
            softwareHost?.volume = newValue
            nativeHost?.avPlayer.volume = newValue
        }
    }

    /// Set playback speed (0.5-2.0). On the native AVPlayer path audio
    /// pitch adjusts via `audioTimePitchAlgorithm`; on the SW path the
    /// rate goes through the synchronizer and audio plays at the
    /// changed rate without pitch correction.
    public func setRate(_ rate: Float) {
        if audioAVPlayerActive, let host = audioAVPlayerHost {
            host.setRate(rate)
        } else if let host = audioHost {
            host.setRate(rate)
        } else if let host = softwareHost {
            host.setRate(rate)
        } else {
            nativeHost?.setRate(rate)
        }
    }

    // MARK: - Audio / subtitle track selection

    /// Switch the active audio track mid-playback. The engine restarts
    /// its HLS pipeline with the new source audio stream as the muxed
    /// audio output, swaps AVPlayer to the freshly served playlist, and
    /// resumes at the current playhead.
    ///
    /// Roughly 0.5-1 s of black frame is expected during the swap
    /// because `AVPlayer.replaceCurrentItem` always tears the render
    /// surface down. The HDMI HDR-mode handshake is suppressed (the
    /// video stream isn't changing), so the panel doesn't re-negotiate.
    ///
    /// `index` is the audio track's container stream index, matching
    /// `TrackInfo.id` from `audioTracks`. Calls with an out-of-range
    /// index, an index pointing at a non-audio stream, or the index
    /// that's already active are no-ops.
    public func selectAudioTrack(index: Int) {
        guard let url = loadedURL else { return }
        guard audioTracks.contains(where: { $0.id == index }) else {
            EngineLog.emit(
                "[AetherEngine] selectAudioTrack: index=\(index) not in audioTracks (\(audioTracks.map { $0.id })), ignored",
                category: .engine
            )
            return
        }
        if activeAudioTrackIndex == index { return }

        EngineLog.emit(
            "[AetherEngine] selectAudioTrack: scheduling switch to stream \(index)",
            category: .engine
        )

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.reloadWithAudioOverride(
                url: url,
                audioStreamIndex: Int32(index)
            )
        }
    }

    /// The sidecar subtitle URL the host most recently activated, kept
    /// so `selectAudioTrack` can rehydrate the same selection after the
    /// pipeline reload. Cleared by `clearSubtitle` and `stopInternal`.
    private var loadedSidecarURL: URL?

    /// Perform the audio-track-switch reload. Tears the current native
    /// session down, brings a fresh `HLSVideoEngine` up with the new
    /// audio source stream override, swaps AVPlayer to the new playlist
    /// URL at the current playhead, and re-arms whichever subtitle
    /// source was active when this task actually began executing.
    ///
    /// Subtitle and playhead state are snapshotted INSIDE the task body
    /// rather than at the call site, because hosts commonly chain a
    /// `selectSubtitleTrack` call right after `selectAudioTrack` (e.g.
    /// auto-subs-for-foreign-audio): the chained call lands on the
    /// MainActor before this task body runs, and snapshotting at call
    /// time would miss it, leaving the picker showing a subtitle that
    /// the post-reload state never actually re-armed.
    private func reloadWithAudioOverride(
        url: URL,
        audioStreamIndex: Int32
    ) async {
        let resumeAt = currentTime
        let embeddedStreamToResume: Int32 = activeEmbeddedSubtitleStreamIndex
        let sidecarToResume: URL? = isSubtitleActive && activeEmbeddedSubtitleStreamIndex < 0
            ? loadedSidecarURL
            : nil
        EngineLog.emit(
            "[AetherEngine] reload begin: audioStream=\(audioStreamIndex) resumeAt=\(String(format: "%.2f", resumeAt))s embeddedSub=\(embeddedStreamToResume) sidecar=\(sidecarToResume?.lastPathComponent ?? "nil")",
            category: .engine
        )

        state = .loading
        let previousAudioIndex = activeAudioTrackIndex
        // Snapshot the active backend BEFORE stopInternal wipes it.
        // The reload has to land on whichever pipeline currently owns
        // playback — calling loadNative on a SW-routed source would
        // throw `unsupportedCodec` (HLSVideoEngine accepts HEVC / H.264
        // / VP9 / probed-AV1, not SW-only AV1) and leave the user
        // staring at a "playback stopped" error after picking a
        // different audio track.
        let wasOnSoftwarePath = (playbackBackend == .software)
        // Snapshot the video codec before stopInternal wipes it. The
        // reload re-uses the same source, so the decoder identity
        // label can be reconstructed without re-probing the demuxer.
        let preservedVideoCodec = lastDetectedVideoCodec
        let reloadStart = DispatchTime.now()
        EngineLog.emit("[AetherEngine] reload: stopInternal start", category: .engine)
        // Keep the active display criteria intact across the audio-track
        // switch. The video format isn't changing — `reloadWithAudioOverride`
        // only swaps the audio source stream inside the same HLS engine —
        // so a `displayCriteria.reset()` here is at best a no-op and at
        // worst triggers a 5 s `waitForSwitch` Stage 2 timeout on every
        // reload (Vincent test 2026-05-26, Bose SLIII A2DP route + 4K
        // HDR10 PQ source: each audio switch added ~12 s of black-screen
        // latency because the post-RESET handshake never re-settled,
        // even though the panel never actually left HDR mode). Preserving
        // the criteria also fixes a separate failure mode on the same
        // route: when the panel briefly dropped to SDR during the RESET
        // window, the new AVPlayer asset's PQ variant failed item open
        // with `AVFoundationErrorDomain -11868 / CoreMediaErrorDomain
        // -17223` at variant selection.
        // Keep the native AVPlayer host alive across the audio-track switch
        // (issue #15) unless playback is on the software path, where there
        // is no native host to preserve.
        stopInternal(resetDisplayCriteria: false, keepNativeHost: !wasOnSoftwarePath)
        EngineLog.emit("[AetherEngine] reload: stopInternal done (\(elapsedMs(since: reloadStart))ms)", category: .engine)
        loadedURL = url
        lastDetectedVideoCodec = preservedVideoCodec

        do {
            let loadStart = DispatchTime.now()
            if wasOnSoftwarePath {
                EngineLog.emit("[AetherEngine] reload: loadSoftware enter audio=\(audioStreamIndex) resumeAt=\(String(format: "%.2f", resumeAt))s", category: .engine)
                try await loadSoftware(
                    url: url,
                    sourceHTTPHeaders: loadedOptions.httpHeaders,
                    startPosition: resumeAt > 1 ? resumeAt : nil,
                    audioSourceStreamIndex: audioStreamIndex
                )
                EngineLog.emit("[AetherEngine] reload: loadSoftware done (\(elapsedMs(since: loadStart))ms)", category: .engine)
                playbackBackend = .software
                activeAudioTrackIndex = Int(audioStreamIndex)
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: preservedVideoCodec, isSoftware: true
                )
                activeAudioDecoder = Self.softwareAudioDecoderLabel(
                    audioTracks: audioTracks, activeIndex: audioStreamIndex
                )
                presentCurrentLayer()
                softwareHost?.play()
            } else {
                EngineLog.emit("[AetherEngine] reload: loadNative enter audio=\(audioStreamIndex) resumeAt=\(String(format: "%.2f", resumeAt))s", category: .engine)
                try await loadNative(
                    url: url,
                    sourceHTTPHeaders: loadedOptions.httpHeaders,
                    startPosition: resumeAt > 1 ? resumeAt : nil,
                    audioSourceStreamIndex: audioStreamIndex,
                    keepDvh1TagWithoutDV: loadedOptions.keepDvh1TagWithoutDV,
                    matchContentEnabled: loadedOptions.matchContentEnabled,
                    panelIsInHDRMode: loadedOptions.panelIsInHDRMode,
                    audioBridgeMode: loadedOptions.audioBridgeMode
                )
                EngineLog.emit("[AetherEngine] reload: loadNative done (\(elapsedMs(since: loadStart))ms)", category: .engine)
                playbackBackend = .native
                activeAudioTrackIndex = Int(audioStreamIndex)
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: preservedVideoCodec, isSoftware: false
                )
                activeAudioDecoder = nativeVideoSession?.audioPipelineDescription
                presentCurrentLayer()
                // Same play-gate as the initial load path: wait for any
                // pending AVKit auto-criteria handshake before resuming,
                // so the first decoded frame after the audio-track reload
                // doesn't hit a mid-transition panel.
                await displayCriteria.waitForSwitch()
                nativeHost?.play()
            }
            state = .playing
            // Re-arm the diagnostic samplers. stopInternal nilled the
            // sampler instance + the published liveTelemetry value, and
            // the reload path bypasses the public load() that would
            // otherwise restart them — so without this, the host's
            // stats overlay sees @Published liveTelemetry stuck at nil
            // and renders "-" for every field after the first audio
            // track switch in a session.
            startMemoryProbe()
            startLiveTelemetrySampler()
            EngineLog.emit("[AetherEngine] reload: state=.playing total=\(elapsedMs(since: reloadStart))ms", category: .engine)
        } catch {
            EngineLog.emit(
                "[AetherEngine] selectAudioTrack reload failed: \(error), playback stopped",
                category: .engine
            )
            activeAudioTrackIndex = previousAudioIndex
            state = .error("Audio track switch failed: \(error.localizedDescription)")
            return
        }

        // Resume whichever subtitle source the host had active when
        // this task started running. The sidecar branch wins because
        // `loadedSidecarURL` is set only when the active source is
        // sidecar; the embedded branch restarts the side-demuxer at
        // the new playhead.
        if let sidecar = sidecarToResume {
            selectSidecarSubtitle(url: sidecar)
        } else if embeddedStreamToResume >= 0 {
            selectSubtitleTrack(index: Int(embeddedStreamToResume))
        }
    }

    /// Activate an embedded subtitle stream from the source. A side
    /// Demuxer opens the source independently of the main HLS pump,
    /// seeks to (just before) the current playback position, and
    /// streams subtitle packets through an `EmbeddedSubtitleDecoder`.
    /// Cues land in `subtitleCues` typically within 1-2 seconds of
    /// activation.
    ///
    /// Supports text codecs (SubRip / ASS / SSA / WebVTT / mov_text)
    /// and bitmap codecs (PGS / DVB / DVD / XSUB) with full canvas-
    /// relative positioning.
    ///
    /// Why a side demuxer instead of routing through the main HLS
    /// pump: when activation happens mid-playback, the main pump has
    /// already raced ~60-80 s ahead of the playhead and discarded
    /// every subtitle packet in that window. Re-reading from the
    /// playhead via a side demuxer is the cheapest way to catch cues
    /// for content the user is about to see. The side demuxer also
    /// re-seeks on `engine.seek` so scrubs surface cues at the new
    /// position immediately.
    public func selectSubtitleTrack(index: Int) {
        cancelSidecarTask()
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil

        guard let url = loadedURL else { return }

        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true
        activeEmbeddedSubtitleStreamIndex = Int32(index)

        // Side-demuxer seeks in source PTS. sourceTime is the unified
        // source-PTS playhead (equal to currentTime now that the native
        // clock folds in playlistShiftSeconds), so it hands the demuxer
        // the true source position directly. Reading the pre-fold AVPlayer
        // clock here would land `playlistShiftSeconds` early and the first
        // emitted cue would read as "subs are 3-5 s late" — repro on Cars
        // at a restart-driven shift of ~3.92 s.
        startEmbeddedSubtitleTask(url: url, streamIndex: Int32(index), startAt: sourceTime)
    }

    /// Spin up the side-demuxer Task that streams cues into the
    /// engine. Captured-on-init: the URL, the stream index, the
    /// start position, and the source video dimensions. The Task's
    /// run loop is cancellable; `cancel()` triggers a clean exit.
    private func startEmbeddedSubtitleTask(url: URL, streamIndex: Int32, startAt: Double) {
        let w = sourceVideoWidth > 0 ? sourceVideoWidth : 1920
        let h = sourceVideoHeight > 0 ? sourceVideoHeight : 1080
        let headers = loadedOptions.httpHeaders
        embeddedSubtitleTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runEmbeddedSubtitleReader(
                url: url, headers: headers, streamIndex: streamIndex, startAt: startAt,
                videoWidth: w, videoHeight: h
            )
        }
    }

    /// Side-demuxer read loop. Opens a fresh `Demuxer` against the
    /// source URL, prewarms the cue table by seeking mid-file (so the
    /// MKV demuxer's cue index is loaded before the real seek), then
    /// seeks slightly before the requested start time and streams
    /// subtitle packets through an `EmbeddedSubtitleDecoder`, emitting
    /// cues back into the engine on the main actor.
    nonisolated private func runEmbeddedSubtitleReader(
        url: URL, headers: [String: String], streamIndex: Int32, startAt: Double,
        videoWidth: Int32, videoHeight: Int32
    ) async {
        let demuxer = Demuxer()
        do {
            try demuxer.open(url: url, extraHeaders: headers)
        } catch {
            EngineLog.emit("[AetherEngine] embedded subtitle open failed: \(error)", category: .engine)
            await MainActor.run { [weak self] in
                self?.isLoadingSubtitles = false
            }
            return
        }
        defer { demuxer.close() }

        // Prewarm the cue table by seeking mid-file before the actual
        // playhead seek. MKV cues live at the end of the file; a fresh
        // demuxer doesn't load them until first seek. Without this
        // prewarm, the seek-to-playhead lands inaccurately and we
        // either miss subtitle packets near the playhead or land far
        // away from where we asked. HLSVideoEngine does the same thing
        // for the same reason; we mirror it on the side demuxer.
        let duration = demuxer.duration
        if duration > 0 {
            demuxer.seek(to: duration * 0.5)
        }

        // Now the real seek. Slightly before the playhead so bitmap
        // subtitle codecs (PGS / DVB / HDMV) catch their state-machine
        // SETUP segments before the first END / EVENT segment.
        let seekTo = max(0, startAt - 2.0)
        demuxer.seek(to: seekTo)

        guard let stream = demuxer.stream(at: streamIndex),
              let decoder = EmbeddedSubtitleDecoder(
                  stream: stream,
                  sourceVideoWidth: videoWidth,
                  sourceVideoHeight: videoHeight
              )
        else {
            EngineLog.emit("[AetherEngine] embedded subtitle decoder open failed for stream=\(streamIndex)", category: .engine)
            await MainActor.run { [weak self] in
                self?.isLoadingSubtitles = false
            }
            return
        }

        let tb = stream.pointee.time_base
        let streamStartTime = stream.pointee.start_time

        // Comprehensive offset diagnostics: log every PTS-reference
        // value we have access to so we can correlate cue startTime
        // (source PTS based) with AVPlayer.currentTime (HLS playlist
        // based). If videoStream.start_time or format.start_time is
        // non-zero, that's the offset between source-time and
        // playlist-time.
        let formatStart = demuxer.formatStartTime
        let videoStream = demuxer.videoStreamIndex >= 0 ? demuxer.stream(at: demuxer.videoStreamIndex) : nil
        let videoStreamStart = videoStream?.pointee.start_time ?? 0
        let videoTb = videoStream?.pointee.time_base ?? AVRational(num: 1, den: 1)
        EngineLog.emit(
            "[AetherEngine] embedded subtitle reader started: stream=\(streamIndex) " +
            "startAt=\(String(format: "%.2f", startAt))s seekTo=\(String(format: "%.2f", seekTo))s " +
            "codec=\(decoder.codecID.rawValue) " +
            "subTb=\(tb.num)/\(tb.den) subStart=\(streamStartTime) " +
            "videoTb=\(videoTb.num)/\(videoTb.den) videoStart=\(videoStreamStart) " +
            "format.start_time=\(formatStart)us",
            category: .engine
        )

        await MainActor.run { [weak self] in
            self?.isLoadingSubtitles = false
        }

        var totalPacketsRead = 0
        var subtitlePacketsRead = 0
        var cuesEmitted = 0
        var firstCueLogged = false

        while !Task.isCancelled {
            guard let pkt = try? demuxer.readPacket() else {
                break
            }
            totalPacketsRead += 1
            let streamIdx = pkt.pointee.stream_index
            if streamIdx != streamIndex {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
                continue
            }
            subtitlePacketsRead += 1
            let pktPTS = pkt.pointee.pts
            let event = decoder.decode(
                packet: pkt,
                streamTimeBase: tb
            )
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
            if let event {
                cuesEmitted += event.cues.count
                if !firstCueLogged, let firstCue = event.cues.first {
                    EngineLog.emit(
                        "[AetherEngine] subtitle first cue: pktPTS=\(pktPTS) → " +
                        "startTime=\(String(format: "%.3f", firstCue.startTime))s " +
                        "endTime=\(String(format: "%.3f", firstCue.endTime))s",
                        category: .engine
                    )
                    firstCueLogged = true
                }
                await MainActor.run { [weak self] in
                    self?.applySubtitleEvent(event)
                }
            }
        }

        EngineLog.emit(
            "[AetherEngine] embedded subtitle reader exited (cancelled=\(Task.isCancelled)) " +
            "packetsRead=\(totalPacketsRead) subtitlePackets=\(subtitlePacketsRead) " +
            "cuesEmitted=\(cuesEmitted)",
            category: .engine
        )
    }

    /// Apply a decoded subtitle event from HLSVideoEngine's embedded
    /// decoder. Handles PGS clear-event semantics (trim previously
    /// displayed bitmap cues so they actually disappear at the right
    /// moment) and inserts new cues sorted by start time so the
    /// overlay's lookup stays correct after backward scrubs.
    @MainActor
    private func applySubtitleEvent(_ event: EmbeddedSubtitleDecoder.SubtitleEvent) {
        guard isSubtitleActive else { return }

        // Diagnostic: for the first ~20 cues after activation, log
        // each cue's time range alongside engine.currentTime (=
        // AVPlayer.currentTime). Lets us spot whether the source-side
        // PTS and the AVPlayer-side clock differ systematically.
        if subtitleCueDiagnosticCount < 20, let firstCue = event.cues.first {
            subtitleCueDiagnosticCount += 1
            EngineLog.emit(
                "[applySubtitleEvent #\(subtitleCueDiagnosticCount)] " +
                "cueStart=\(String(format: "%.3f", firstCue.startTime))s " +
                "cueEnd=\(String(format: "%.3f", firstCue.endTime))s " +
                "engine.currentTime=\(String(format: "%.3f", currentTime))s",
                category: .engine
            )
        }

        // Cues stay in source PTS; the AVPlayer-clock translation is
        // applied at the lookup boundary (host renders against
        // `engine.sourceTime`, side-demuxer seeks against the same).

        // PGS clear-event trim: each PGS event implicitly terminates
        // whatever was on screen. Truncate any image cue whose
        // interval straddles the new event's start so it disappears
        // at the right moment instead of staying up for the
        // UINT32_MAX (~50-day) default the decoder hands us.
        if let trimAt = event.pgsTrimAt {
            for i in 0..<subtitleCues.count {
                guard case .image = subtitleCues[i].body else { continue }
                let cue = subtitleCues[i]
                if cue.startTime < trimAt && cue.endTime > trimAt {
                    subtitleCues[i] = SubtitleCue(
                        id: cue.id,
                        startTime: cue.startTime,
                        endTime: trimAt,
                        body: cue.body
                    )
                }
            }
        }

        // Cues mostly arrive in DTS order, but a backward scrub can
        // make a fresh packet land before existing cues. Insert each
        // in sorted position so the overlay's lookup (binary search
        // then walk for overlapping cues) stays correct.
        for cue in event.cues {
            var lo = 0, hi = subtitleCues.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if subtitleCues[mid].startTime < cue.startTime {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            subtitleCues.insert(cue, at: lo)
        }

        // Prune cues that ended more than `subtitleCueRetentionSeconds`
        // before the current playback time. Bitmap cues (PGS / DVB /
        // DVD) each carry a CGImage with retained RGBA pixel data; on
        // long sessions with PGS subtitles the array grows by 1-2
        // cues / second and the heap climbs proportionally. The
        // retention window covers typical pause durations and the
        // backward-scrub reach that doesn't trigger a producer
        // restart; anything older that the user revisits via a far
        // scrub gets re-emitted by the producer pump on restart (the
        // EmbeddedSubtitleDecoder clears its dedupe set on every
        // resetState).
        pruneOldSubtitleCues()
    }

    /// Remove subtitle cues whose `endTime` has fallen further behind
    /// the current source-PTS position than the retention window.
    /// Called from `applySubtitleEvent` so the prune happens at the
    /// cue-emit cadence (~1-2 / second on a typical PGS track) rather
    /// than on a separate timer. Compares against `sourceTime` because
    /// cue start / end timestamps are in
    /// absolute source PTS seconds (see EmbeddedSubtitleDecoder.decode
    /// docstring). sourceTime now equals currentTime (the clock is unified
    /// onto source PTS), so either is correct; sourceTime keeps the intent
    /// explicit.
    private func pruneOldSubtitleCues() {
        guard !subtitleCues.isEmpty else { return }
        let cutoff = sourceTime - subtitleCueRetentionSeconds
        guard cutoff > 0 else { return }
        subtitleCues.removeAll { $0.endTime < cutoff }
    }

    /// Decode a sidecar subtitle file (`.srt` / `.ass` / `.vtt` /
    /// `.ssa` served alongside the media). The whole file is fetched
    /// and decoded up-front via `SubtitleDecoder.decodeFile`, then the
    /// resulting cues replace `subtitleCues` atomically.
    /// `isLoadingSubtitles` flips on for the duration so the host can
    /// show a spinner. Subsequent calls cancel any in-flight sidecar
    /// decode.
    public func selectSidecarSubtitle(url: URL) {
        cancelSidecarTask()
        // Sidecar replaces any active embedded stream.
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        activeEmbeddedSubtitleStreamIndex = -1

        loadedSidecarURL = url
        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true

        sidecarTask = Task { [weak self] in
            let cues: [SubtitleCue]
            do {
                cues = try await SubtitleDecoder.decodeFile(url: url)
            } catch {
                EngineLog.emit("[AetherEngine] sidecar decode failed: \(error)", category: .engine)
                await MainActor.run {
                    guard let self = self else { return }
                    if self.isSubtitleActive {
                        self.isLoadingSubtitles = false
                    }
                }
                return
            }

            await MainActor.run {
                guard let self = self else { return }
                guard self.isSubtitleActive else { return }
                // Sidecar cues stay in source PTS; host renders
                // against `engine.sourceTime`, which already adds the
                // active producer's playlist shift to AVPlayer's clock.
                self.subtitleCues = cues
                self.isLoadingSubtitles = false
            }
        }
    }

    /// Turn subtitles off and clear cached cues. Tears down both the
    /// sidecar SRT decode task and the side-demuxer embedded reader.
    public func clearSubtitle() {
        cancelSidecarTask()
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        activeEmbeddedSubtitleStreamIndex = -1
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        isLoadingSubtitles = false
    }

    private func cancelSidecarTask() {
        sidecarTask?.cancel()
        sidecarTask = nil
    }

    // MARK: - Internal teardown

    /// Milliseconds since a captured DispatchTime, rounded. Used by
    /// the reload-path diagnostic markers so each step's duration is
    /// visible without having to do mental arithmetic from absolute
    /// timestamps.
    private func elapsedMs(since start: DispatchTime) -> Int {
        Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Decide whether a load should use the audio-only path. Pure and
    /// `nonisolated` so it is unit-testable without a `@MainActor`
    /// engine instance. The audio path is taken when the host explicitly
    /// requested it OR the probe found no video stream.
    nonisolated static func shouldUseAudioOnlyPath(audioOnlyRequested: Bool, hasVideoStream: Bool) -> Bool {
        audioOnlyRequested || !hasVideoStream
    }

    /// Whether AVPlayer/AVFoundation can natively decode this audio codec
    /// on Apple platforms, so the engine can hand the source straight to a
    /// lean AVPlayer (hardware-accelerated, energy-efficient, native system
    /// integration) instead of the FFmpeg software path. Whitelist, not
    /// blacklist: anything not known-native (Opus, Vorbis, APE, WavPack,
    /// Musepack, ...) falls back to `AudioPlaybackHost`, which decodes
    /// everything via FFmpeg. AAC, MP3, MP2, ALAC, AC-3/E-AC-3, LPCM, and
    /// FLAC (AVFoundation has decoded FLAC since iOS/tvOS 11) are native.
    nonisolated static func avPlayerCanDecodeAudio(_ codecID: AVCodecID) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AAC,
             AV_CODEC_ID_MP3,
             AV_CODEC_ID_MP2,
             AV_CODEC_ID_MP1,
             AV_CODEC_ID_ALAC,
             AV_CODEC_ID_FLAC,
             AV_CODEC_ID_AC3,
             AV_CODEC_ID_EAC3,
             AV_CODEC_ID_PCM_S16LE,
             AV_CODEC_ID_PCM_S16BE,
             AV_CODEC_ID_PCM_S24LE,
             AV_CODEC_ID_PCM_S24BE,
             AV_CODEC_ID_PCM_F32LE:
            return true
        default:
            return false
        }
    }

    /// - Parameter resetDisplayCriteria: When `true` (default), release
    ///   the `AVDisplayManager.preferredDisplayCriteria` so the panel
    ///   returns to its default mode. Used by `load()` and the public
    ///   `stop()` API where the next session may target a different
    ///   format. The audio-track-switch reload path passes `false`
    ///   because the same source is being re-prepared with only the
    ///   audio stream changing — keeping the criteria in place avoids
    ///   a redundant `apply` + `waitForSwitch` cycle that on some
    ///   panels (notably when paired with a Bluetooth A2DP audio route)
    ///   never settles and times out at 5 s, adding ~12 s of black-
    ///   screen latency per audio switch.
    private func stopInternal(resetDisplayCriteria: Bool = true, keepNativeHost: Bool = false) {
        // Stop AVPlayer fetching before tearing down the loopback HLS
        // server, otherwise AVPlayer's segment requests race the
        // server shutdown and produce noisy errors in the log. Display
        // criteria reset is gated by the parameter so audio-only reloads
        // preserve the panel mode (see method doc).
        //
        // `keepNativeHost` preserves the NativeAVPlayerHost and its
        // AVPlayer instance across a native->native reload (episode
        // change, audio-track switch). `tearDown()` still unloads the
        // current item (so AVPlayer stops fetching from the old loopback
        // server before that server is torn down), but the host and the
        // published `currentAVPlayer` survive. AVKit binds its MediaRemote
        // system Now-Playing registration to the AVPlayer instance once,
        // at first presentation, and never re-registers against a swapped
        // player ("Code=14 client callback"), so reusing the instance is
        // what keeps the iPhone Control Center widget populated across the
        // seam (issue #15). Callers that cross into the software path must
        // release the preserved host themselves (the SW pipeline needs the
        // currentAVPlayer sink to see a nil publish).
        memoryProbeTask?.cancel()
        memoryProbeTask = nil
        liveTelemetrySampler?.stop()
        liveTelemetrySampler = nil
        liveTelemetry = nil
        nativeCancellables.removeAll()
        nativeHost?.tearDown()
        if !keepNativeHost {
            nativeHost = nil
            currentAVPlayer = nil
        }
        nativeVideoSession?.stop()
        nativeVideoSession = nil

        // Mirror teardown for the SW path. stop() halts the demux loop,
        // releases the decoders / synchronizer / display layer, and
        // closes the host's own Demuxer. The display layer is owned by
        // the renderer and detaches from the bound view via the view's
        // own attach() on the next presentCurrentLayer call.
        softwareCancellables.removeAll()
        softwareHost?.stop()
        softwareHost = nil

        // Mirror teardown for the audio-only path. stop() halts the
        // demux loop, flushes + releases the renderer / synchronizer,
        // and closes the host's own Demuxer. Clearing audioHost here is
        // what makes a music -> video handoff (and vice versa) start
        // from a clean slate: the engine is a process-wide singleton, so
        // a lingering audioHost would keep the old synchronizer's clock
        // and renderer alive under the next session.
        audioCancellables.removeAll()
        audioHost?.stop()
        audioHost = nil

        // The AVPlayer audio host is KEPT alive across loads (its
        // MPNowPlayingSession must persist for stable system Now-Playing).
        // Mark it inactive and stop playback, but do NOT release it; the
        // next audio load reuses it via replaceCurrentItem.
        audioNativeCancellables.removeAll()
        audioAVPlayerActive = false
        audioAVPlayerHost?.stop()

        if resetDisplayCriteria {
            displayCriteria.reset()
        }
        playbackBackend = .none
        activeVideoDecoder = nil
        activeAudioDecoder = nil
        lastDetectedVideoCodec = AV_CODEC_ID_NONE
        playlistShiftSeconds = 0
        nativeClockSeconds = 0
        sourceTime = 0

        cancelSidecarTask()
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        activeEmbeddedSubtitleStreamIndex = -1
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        isLoadingSubtitles = false
        // Audio-track state belongs to the host's picker; clear it so a
        // stale index from the previous session can't be re-applied via
        // `selectAudioTrack` before the next `load(url:)` repopulates
        // `audioTracks`.
        activeAudioTrackIndex = nil
        isLive = false
    }

    // MARK: - Memory diagnostic

    /// Start the periodic memory probe. Cancels any prior probe so a
    /// fresh `load(url:)` cycle starts a clean timeline. Drives one
    /// `EngineLog.emit` line every 30 s under the `.engine` category;
    /// the line shape is documented on `memoryProbeTask`.
    private func startMemoryProbe() {
        memoryProbeTask?.cancel()
        let sessionStart = Date()
        memoryProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard let self = self else { return }
                let elapsed = Int(Date().timeIntervalSince(sessionStart))
                let rssMB = Self.residentMemoryMB()
                let cueCount = self.subtitleCues.count

                // AVPlayer-side buffer probe: how much content has the
                // native host's current AVPlayerItem actually loaded? If
                // this number balloons past `preferredForwardBufferDuration`,
                // AVPlayer is buffering more than we asked it to and is
                // a candidate for the linear-growth memory leak.
                var bufferAheadSec = 0.0
                var bufferBehindSec = 0.0
                if let avPlayer = self.currentAVPlayer,
                   let item = avPlayer.currentItem {
                    let now = item.currentTime().seconds
                    for value in item.loadedTimeRanges {
                        let range = value.timeRangeValue
                        let start = range.start.seconds
                        let end = (range.start + range.duration).seconds
                        if end > now { bufferAheadSec += end - max(start, now) }
                        if start < now { bufferBehindSec += min(end, now) - start }
                    }
                }

                // Pipeline counters from the native HLS engine. Zero
                // when the SW path is active (no HLSVideoEngine) or
                // pre-start. Read once per probe — fields are not
                // mutually atomic but the 30 s cadence makes drift
                // irrelevant for trend analysis.
                let stats = self.nativeVideoSession?.diagnosticStats()
                let avioMB = (stats?.avioBytesFetched ?? 0) / 1024 / 1024
                let cacheMB = (stats?.segmentCacheBytes ?? 0) / 1024 / 1024
                let cacheCount = stats?.segmentCacheCount ?? 0
                let packetsWritten = stats?.producerPacketsWritten ?? 0
                let audioFifo = stats?.audioFifoSamples ?? 0
                let abFifoKB = (stats?.audioBridgeFifoBytes ?? 0) / 1024
                let abSwrKB = (stats?.audioBridgeSwrBytes ?? 0) / 1024
                let abTotKB = (stats?.audioBridgeTotalBytes ?? 0) / 1024
                let muxBytesMB = (stats?.muxerLifetimeFragmentBytes ?? 0) / 1024 / 1024
                let muxCuts = stats?.muxerFragmentCuts ?? 0
                let srvConns = stats?.serverConnectionCount ?? 0
                let srvBytesMB = (stats?.serverLifetimeBytesSent ?? 0) / 1024 / 1024
                let srvSfMB = (stats?.serverSendfileBytesSent ?? 0) / 1024 / 1024
                let pktAlive = stats?.packetsAlive ?? 0
                let pktTotal = stats?.packetsTotalAllocs ?? 0

                // VM breakdown so the leak source is visible at probe
                // time: internal (Swift / libavformat heap) vs external
                // (mmap'd cache files, dyld) vs IOSurface (HEVC decoded
                // frames) vs compressed (kernel-compressed pages still
                // accounted to us).
                let vmStr: String
                if let vm = Self.vmBreakdownMB() {
                    vmStr = "vmInt=\(vm.internalMB)MB "
                        + "vmExt=\(vm.externalMB)MB "
                        + "vmCmp=\(vm.compressedMB)MB "
                        + "vmIOS=\(vm.iosurfaceMB)MB "
                        + "physFP=\(vm.physFootprintMB)MB "
                } else {
                    vmStr = ""
                }

                let mallocStr: String
                if let m = Self.mallocZoneSummary() {
                    mallocStr = "mallocBlocks=\(m.blocksInUse) mallocMB=\(m.sizeInUseMB) "
                } else {
                    mallocStr = ""
                }

                let line = "[AetherEngine] memprobe t=\(elapsed)s "
                    + "rss=\(rssMB)MB "
                    + vmStr
                    + mallocStr
                    + "avioFetchedMB=\(avioMB) "
                    + "cacheCount=\(cacheCount) cacheMB=\(cacheMB) "
                    + "packetsWritten=\(packetsWritten) "
                    + "audioFifo=\(audioFifo) "
                    + "abFifoKB=\(abFifoKB) abSwrKB=\(abSwrKB) abTotKB=\(abTotKB) "
                    + "muxBytesMB=\(muxBytesMB) muxCuts=\(muxCuts) "
                    + "srvConns=\(srvConns) srvBytesMB=\(srvBytesMB) srvSfMB=\(srvSfMB) "
                    + "pktAlive=\(pktAlive) pktTotal=\(pktTotal) "
                    + "subCues=\(cueCount) "
                    + "audioTracks=\(self.audioTracks.count) "
                    + "subTracks=\(self.subtitleTracks.count) "
                    + "subActive=\(self.isSubtitleActive) "
                    + "avBufAhead=\(String(format: "%.1f", bufferAheadSec))s "
                    + "avBufBehind=\(String(format: "%.1f", bufferBehindSec))s"

                EngineLog.emit(line, category: .engine)
            }
        }
    }

    /// Start the 1 Hz live-telemetry sampler. Cancels any prior sampler
    /// so a fresh `load(url:)` cycle starts a clean timeline. Mirrors
    /// `startMemoryProbe`'s lifecycle so the two diagnostic surfaces
    /// share the same start + stop hooks.
    private func startLiveTelemetrySampler() {
        liveTelemetrySampler?.stop()
        let sampler = LiveTelemetrySampler(engine: self)
        liveTelemetrySampler = sampler
        sampler.start()
    }

    /// Resident memory footprint of the current process in MB, read via
    /// `mach_task_basic_info`. Returns 0 on error. Cheap to call (no
    /// allocations) and safe from any thread.
    static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1024 / 1024)
    }

    /// Detailed VM breakdown via `task_vm_info`. Splits the process's
    /// phys_footprint (jetsam-accounted bytes) into the buckets the
    /// kernel tracks separately:
    ///
    ///   internal:   anonymous memory — heap, stack, NSData backing,
    ///               anything malloc'd
    ///   external:   file-backed memory — mmap'd files, dyld text/data,
    ///               our SegmentCache reads via `.alwaysMapped`
    ///   compressed: pages the kernel compressed under pressure (still
    ///               counted against the process footprint)
    ///   iosurfaces: IOSurface-backed device memory (decoded video
    ///               frames, AVPlayer's HEVC reference pool)
    ///
    /// Surfaced in the 30 s memprobe line so memory-growth investigations
    /// can see which bucket moved between samples.
    static func vmBreakdownMB() -> (internalMB: Int,
                                    externalMB: Int,
                                    compressedMB: Int,
                                    iosurfaceMB: Int,
                                    physFootprintMB: Int)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (
            internalMB: Int(info.internal / 1024 / 1024),
            externalMB: Int(info.external / 1024 / 1024),
            compressedMB: Int(info.compressed / 1024 / 1024),
            iosurfaceMB: Int(info.device / 1024 / 1024),
            physFootprintMB: Int(info.phys_footprint / 1024 / 1024)
        )
    }

    /// Malloc-zone statistics for the default zone. `blocks_in_use`
    /// counts how many distinct allocations currently exist;
    /// `size_in_use` is their total bytes. Surfaced in the memprobe so
    /// we can tell whether vmInt growth is many small allocations
    /// leaking (block count climbs linearly) versus a single large
    /// buffer growing (block count flat, size up). Passing `nil` to
    /// malloc_zone_statistics asks libmalloc to sum across all zones
    /// it manages — equivalent to iterating malloc_get_all_zones
    /// without the pointer-cast gymnastics.
    static func mallocZoneSummary() -> (blocksInUse: Int, sizeInUseMB: Int)? {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (blocksInUse: Int(stats.blocks_in_use),
                sizeInUseMB: Int(stats.size_in_use / 1024 / 1024))
    }

    // MARK: - Live telemetry bridge

    /// Apply a fresh `LiveTelemetry` snapshot to the `@Published` mirror.
    /// Internal so `LiveTelemetrySampler` can write through despite the
    /// `private(set)` on `liveTelemetry` from the public API surface.
    func applyLiveTelemetry(_ snapshot: LiveTelemetry) {
        liveTelemetry = snapshot
    }


    /// Bytes the active demuxer has fetched from the source. Mirrors
    /// `Demuxer.avioBytesFetched` via HLSVideoEngine's existing
    /// diagnostic surface. Used by `LiveTelemetrySampler` for instant
    /// + average bitrate. Returns 0 on the SW path or pre-start.
    var demuxerBytesFetched: Int64 {
        nativeVideoSession?.demuxerBytesFetched ?? 0
    }

    /// Total resident bytes in the loopback HLS segment cache, or `nil`
    /// when no native session is active.
    var cachedBytes: Int64? {
        guard let bytes = nativeVideoSession?.segmentCacheTotalBytes else { return nil }
        return Int64(bytes)
    }

    /// Lifetime count of frames the SW host has enqueued into its
    /// AVSampleBufferDisplayLayer. Zero on the native path or pre-start.
    var softwareHostFramesEnqueued: Int {
        softwareHost?.framesEnqueued ?? 0
    }

    /// Number of producer restart sessions in the current session. Zero
    /// on the SW path or pre-start.
    var producerRestartCount: Int {
        nativeVideoSession?.producerRestartCount ?? 0
    }

    /// Lifetime bytes emitted by the active MP4SegmentMuxer.
    var muxedBytesLifetime: Int64 {
        Int64(nativeVideoSession?.muxedBytesLifetime ?? 0)
    }

    /// Lifetime bytes the loopback HLS server has written to AVPlayer.
    var serverBytesSentLifetime: Int64 {
        Int64(nativeVideoSession?.serverLifetimeBytesSent ?? 0)
    }

    /// Number of HTTP requests served by the loopback HLS server.
    var serverRequestCount: Int {
        nativeVideoSession?.serverRequestCount ?? 0
    }

    /// Bytes currently held in `AudioBridge`'s FIFO + swr-delay buffers.
    /// Zero when the bridge isn't live (stream-copy audio path or
    /// video-only source).
    var audioBridgeLiveBytes: Int {
        nativeVideoSession?.audioBridgeLiveBytes ?? 0
    }

    /// Most recently measured audio/video gate gap in source-clock
    /// milliseconds. 0 until the first audio gate opens.
    var lastAVGapMs: Double {
        nativeVideoSession?.lastAVGapMs ?? 0
    }

    // MARK: - Decoder identity helpers

    /// Build a user-facing label for the active video decoder. Native
    /// dispatch goes through VideoToolbox on every Apple platform we
    /// ship to, so the "HW" tag holds even on HW-AV1 capable devices;
    /// the SW branch covers the dav1d-on-tvOS AV1 case and the libavcodec
    /// VP9 path. Returns `nil` when the source had no video track
    /// (AV_CODEC_ID_NONE) so the caller can hide the row instead of
    /// printing a placeholder.
    private static func videoDecoderLabel(codecID: AVCodecID, isSoftware: Bool) -> String? {
        guard codecID != AV_CODEC_ID_NONE else { return nil }
        let name: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "video" }
            return String(cString: cstr).uppercased()
        }()
        if isSoftware {
            // SW host paths: AV1 via dav1d, VP9 via libavcodec's vp9
            // decoder, plus legacy codecs AVPlayer's HLS-fMP4 pipeline
            // does not accept (MPEG-4 Part 2 / MPEG-2 / VC-1) via the
            // matching libavcodec native decoder. SoftwareVideoDecoder
            // resolves the actual decoder via `avcodec_find_decoder`.
            switch codecID {
            case AV_CODEC_ID_AV1: return "dav1d \(name) (SW)"
            default:              return "libavcodec \(name) (SW)"
            }
        }
        return "VideoToolbox \(name) (HW)"
    }

    /// Build a user-facing label for the active audio decoder on the
    /// software path. The SW host always uses libavcodec for audio
    /// decode then hands PCM to CoreAudio, so the label is uniform.
    /// Returns `nil` when the source has no audio.
    private static func softwareAudioDecoderLabel(
        audioTracks: [TrackInfo],
        activeIndex: Int32
    ) -> String? {
        guard activeIndex >= 0,
              let track = audioTracks.first(where: { $0.id == Int(activeIndex) }) else {
            return nil
        }
        return "libavcodec \(track.codec.uppercased()) → CoreAudio"
    }

    // MARK: - Format / frame-rate probing

    private nonisolated static func detectVideoFormat(stream: UnsafeMutablePointer<AVStream>) -> VideoFormat {
        let codecpar = stream.pointee.codecpar.pointee
        // Dolby Vision side-data (the `dvcC` / `dvvC` box parsed out of
        // the container) is the authoritative DV marker, independent of
        // base-layer transfer characteristic. Profile 5 is non-backward-
        // compatible (no HDR10/HLG base; ships with SMPTE2084 OR an
        // unspecified trc depending on muxer); Profile 7 and 8.1 use
        // SMPTE2084 base; Profile 8.4 uses HLG base. Branching on
        // `color_trc` first mis-classifies the HLG-base case (P8.4
        // reported as plain HLG) and any unspecified-trc case (P5 with
        // an empty base-layer VUI reported as SDR) — both surface as
        // criteria writes with `codec=hvc1` instead of `dvh1`, so the
        // panel never enters DV mode even when it could. DrHurt#4
        // (2026-05-26): on a DV-capable panel, only P8.1 was producing
        // `format=dolbyvision codec=dvh1` pre-fix.
        if Self.streamHasDV(stream: stream) {
            return .dolbyVision
        }
        let transfer = codecpar.color_trc
        if transfer == AVCOL_TRC_SMPTE2084 { return .hdr10 }
        if transfer == AVCOL_TRC_ARIB_STD_B67 { return .hlg }
        return .sdr
    }

    /// Clamp the source-detected format to what the active display can
    /// actually present. AVPlayer renders DV's HDR10 (PQ) or HLG base
    /// layer on a non-DV panel — HLSVideoEngine forces this by emitting
    /// plain `hvc1` when `dvModeAvailable=false` — so the engine publishes
    /// the base format the panel ends up showing, not the source's DV
    /// claim. Picks the base from the source `color_trc`: PQ → hdr10,
    /// HLG → hlg. SDR-base DV (P8.2) collapses to .sdr; HLSVideoEngine
    /// refuses to serve it anyway so the badge never reaches the UI.
    private static func effectiveVideoFormat(
        detected: VideoFormat,
        stream: UnsafeMutablePointer<AVStream>
    ) -> VideoFormat {
        guard detected == .dolbyVision else { return detected }
        let caps = displayCapabilities
        if caps.supportsDolbyVision { return .dolbyVision }
        let trc = stream.pointee.codecpar.pointee.color_trc
        if trc == AVCOL_TRC_ARIB_STD_B67 {
            return caps.supportsHLG ? .hlg : .sdr
        }
        // SMPTE2084 base (P5 / P7 / P8.1) or an unspecified trc (P5
        // sometimes ships with an empty base-layer VUI). Both are
        // HDR-derived; AVPlayer tonemaps via the dvh1 sample entry on
        // a non-DV panel. Map to HDR10 if the panel can present it.
        return caps.supportsHDR10 ? .hdr10 : .sdr
    }

    /// Called (once per session) when either backend's HDR10+ scan
    /// catches a T.35 metadata payload. The host's badge tracks
    /// `videoFormat`, so flipping `.hdr10 → .hdr10Plus` here is what
    /// gets the badge to read "HDR10+". Guarded against upgrading
    /// non-HDR10 states: a DV / HLG / SDR-clamped session that also
    /// happens to carry HDR10+ metadata stays on its current format
    /// because we have no evidence the panel is rendering an HDR10
    /// base layer in those cases.
    @MainActor
    private func handleHDR10PlusDetected() {
        // Source upgrade runs independently of the panel guard below:
        // a T.35 payload in the stream is a property of the file, so an
        // HDR10 source that's currently clamped to .sdr for an SDR panel
        // still has its sourceVideoFormat correctly bumped to .hdr10Plus.
        if sourceVideoFormat == .hdr10 {
            sourceVideoFormat = .hdr10Plus
        }
        guard videoFormat == .hdr10 else { return }
        EngineLog.emit("[AetherEngine] HDR10+ T.35 detected, upgrading videoFormat .hdr10 → .hdr10Plus", category: .engine)
        videoFormat = .hdr10Plus
    }

    private nonisolated static func streamHasDV(stream: UnsafeMutablePointer<AVStream>) -> Bool {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else {
            return false
        }
        for i in 0..<nb {
            if sideData[i].type == AV_PKT_DATA_DOVI_CONF {
                return true
            }
        }
        return false
    }

    private nonisolated static func detectFrameRate(stream: UnsafeMutablePointer<AVStream>) -> Double? {
        let avg = stream.pointee.avg_frame_rate
        if avg.den > 0 && avg.num > 0 {
            return Double(avg.num) / Double(avg.den)
        }
        let r = stream.pointee.r_frame_rate
        if r.den > 0 && r.num > 0 {
            return Double(r.num) / Double(r.den)
        }
        return nil
    }

    // MARK: - App Lifecycle

    private func setupLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        let nc = NotificationCenter.default

        // Pause VIDEO when the app backgrounds so it doesn't keep streaming
        // in the background. The host calls `reloadAtCurrentPosition()` from
        // its own foreground hook to recover from any AVIO invalidation tvOS
        // may do during suspension.
        //
        // AUDIO (music) is the opposite: it is MEANT to keep playing in the
        // background (UIBackgroundModes audio). Pausing it here, or even just
        // flipping `state` to .paused while the audio AVPlayer keeps playing,
        // desyncs the system Now-Playing rate (the system reads
        // MPNowPlayingInfoPropertyPlaybackRate to know play-vs-pause), making
        // tvOS believe we are paused-while-playing and breaking the Now-Playing
        // badge + Siri Remote routing. So skip this entirely for the audio
        // backends and let them stream on.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.audioAVPlayerActive || self.audioHost != nil { return }
                guard self.state == .playing || self.state == .paused else { return }
                self.nativeHost?.pause()
                self.state = .paused
            }
        }
        lifecycleObservers.append(bgObserver)
        #endif
    }
}

// MARK: - Errors

public enum AetherEngineError: Error {
    case noVideoStream
    case noAudioStream
}
