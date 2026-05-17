import Foundation
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

    /// Which internal backend rendered the current session. Resolves
    /// to `.native` for AVPlayer-decodable sources (HEVC, H.264, plus
    /// AV1 on HW-AV1 devices) or `.software` when the source falls
    /// through to `SoftwarePlaybackHost` (SW dav1d for AV1 without HW,
    /// libavcodec for VP9). Kept on the public surface for diagnostic
    /// overlays and TestFlight badges; hosts should not switch on it.
    @Published public private(set) var playbackBackend: PlaybackBackend = .none

    /// Human-readable identity of the video decoder currently in use,
    /// suitable for a "stats for nerds" UI. Examples:
    /// - `"VideoToolbox HEVC (HW)"` for the native AVPlayer path on
    ///   anything VideoToolbox can decode (HEVC, H.264, AV1 on HW-AV1
    ///   capable devices).
    /// - `"dav1d AV1 (SW)"` for AV1 falling through to the SW pipeline.
    /// - `"libavcodec VP9 (SW)"` for VP9.
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

    /// The URL of the current playback session. Used by
    /// `reloadAtCurrentPosition()` to rebuild the pipeline after
    /// background suspension.
    private var loadedURL: URL?

    /// Seconds to ADD to AVPlayer's HLS clock to recover the source
    /// PTS of the currently displayed frame on the native path.
    ///
    /// The producer subtracts `videoShiftPts` from every packet's
    /// pts/dts so seg-0's fragment tfdt aligns with the playlist's
    /// cumulative-EXTINF origin. AVPlayer's clock therefore sits at
    /// `source_pts - playlistShiftSeconds`. Subtitles come from an
    /// independent side-demuxer (or pre-decoded sidecar) and land in
    /// raw source PTS, so the cue lookup and the side-demuxer's seek
    /// have to add this shift back to map between the two clocks.
    ///
    /// Updated by `HLSVideoEngine.onPlaylistShiftChanged` on every
    /// producer init / restart (matroska seek imprecision means the
    /// shift can differ session-to-session for the same source).
    /// 0 on the SW path; the SW renderer's clock already tracks
    /// source PTS directly.
    @Published public private(set) var playlistShiftSeconds: Double = 0

    /// Source PTS of the currently displayed frame, derived on every
    /// `currentTime` or `playlistShiftSeconds` update. Hosts that
    /// schedule against the source timeline (subtitle overlay, side-
    /// demuxer seek) should read this instead of `currentTime`.
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
    private var loadedOptions: LoadOptions = .init()

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

    // MARK: - Init

    /// Lifecycle notification observers, stored for cleanup.
    private var lifecycleObservers: [Any] = []

    public init() throws {
        // Configure audio session for multichannel playback. AVPlayer
        // needs `.playback` + `.moviePlayback` + multichannel-content
        // enabled before its first asset opens, otherwise output is
        // forced to stereo. The `.longFormAudio` policy keeps audio
        // alive across rapid app-switch flips.
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
        } catch {
            EngineLog.emit("[AetherEngine] AVAudioSession setup error: \(error)", category: .engine)
        }
        let maxCh = session.maximumOutputNumberOfChannels
        if maxCh > 2 {
            try? session.setPreferredOutputNumberOfChannels(maxCh)
        }
        EngineLog.emit("[AetherEngine] AVAudioSession: maxChannels=\(maxCh), preferred=\(session.preferredOutputNumberOfChannels), output=\(session.outputNumberOfChannels)", category: .engine)
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

        return SourceProbe(
            url: url,
            durationSeconds: demuxer.duration,
            videoFormat: detectedFormat,
            videoCodecID: Int32(bitPattern: detectedCodecID.rawValue),
            videoCodecName: codecName,
            videoWidth: width,
            videoHeight: height,
            videoFrameRate: snappedRate,
            isDolbyVision: detectedFormat == .dolbyVision,
            audioTracks: demuxer.audioTrackInfos(),
            subtitleTracks: demuxer.subtitleTrackInfos()
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
        stopInternal()
        loadedURL = url
        loadedOptions = options
        state = .loading
        currentTime = 0
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
        do {
            try probe.open(url: url, extraHeaders: options.httpHeaders)
            let videoIdx = probe.videoStreamIndex
            if videoIdx >= 0, let stream = probe.stream(at: videoIdx) {
                detectedFormat = Self.detectVideoFormat(stream: stream)
                effectiveFormat = Self.effectiveVideoFormat(detected: detectedFormat, stream: stream)
                detectedRate = Self.detectFrameRate(stream: stream)
                detectedDVProfile = (effectiveFormat == .dolbyVision)
                detectedCodecID = stream.pointee.codecpar.pointee.codec_id
                sourceVideoWidth = stream.pointee.codecpar.pointee.width
                sourceVideoHeight = stream.pointee.codecpar.pointee.height
                lastDetectedVideoCodec = detectedCodecID
            }
            probedAudioTracks = probe.audioTrackInfos()
            probedSubtitleTracks = probe.subtitleTrackInfos()
            probedDefaultAudioIndex = probe.audioStreamIndex
            probe.close()
        } catch {
            EngineLog.emit("[AetherEngine] probe failed (\(error)); proceeding without criteria", category: .engine)
        }

        // Publish the format the panel will actually present, not the
        // source's claimed format. Three clamping passes feed into this:
        //
        //   1. `effectiveVideoFormat` collapses DV on a non-DV panel to
        //      its base layer (HDR10 for P8.1, HLG for P8.4, SDR for
        //      P8.2 even though the engine refuses to serve it).
        //   2. The HDR-capability check below: if the connected panel
        //      can't show HDR at all (`supportsHDR == false`), or if
        //      the panel is currently in SDR with tvOS Match Content
        //      OFF, the HLSVideoEngine routes through the media
        //      playlist for AVPlayer's auto-tonemap path. The display
        //      then renders SDR, so the badge / Stats overlay should
        //      read SDR too.
        //
        // Mirrors the master-vs-media routing in HLSVideoEngine.start()
        // so the published format and the actual on-screen rendering
        // stay in step.
        let panelWillPresentHDR = options.panelIsInHDRMode
            || (Self.displayCapabilities.supportsHDR && options.matchContentEnabled)
        videoFormat = (effectiveFormat != .sdr && panelWillPresentHDR)
            ? effectiveFormat
            : .sdr
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
        //
        //    Everything else (HEVC / H.264) goes through the native
        //    path unconditionally.
        let useSoftwarePath: Bool
        switch detectedCodecID {
        case AV_CODEC_ID_AV1:
            useSoftwarePath = !VTCapabilityProbe.av1Available
        case AV_CODEC_ID_VP9:
            useSoftwarePath = true
        default:
            useSoftwarePath = false
        }
        EngineLog.emit("[AetherEngine] dispatch: codec=\(detectedCodecID.rawValue) → \(useSoftwarePath ? "software" : "native")", category: .engine)

        do {
            if useSoftwarePath {
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
            } else {
                try await loadNative(
                    url: url,
                    sourceHTTPHeaders: options.httpHeaders,
                    startPosition: startPosition,
                    audioSourceStreamIndex: audioSourceStreamIndex,
                    keepDvh1TagWithoutDV: options.keepDvh1TagWithoutDV,
                    matchContentEnabled: options.matchContentEnabled,
                    panelIsInHDRMode: options.panelIsInHDRMode
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
                // Auto-play after load. AVPlayer's
                // `automaticallyWaitsToMinimizeStalling = true` (default)
                // handles "play before ready" correctly: it transitions
                // through `waitingToPlayAtSpecifiedRate`, buffers, and
                // starts playing once enough segments are in.
                nativeHost?.play()
                state = .playing
                startMemoryProbe()
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
        panelIsInHDRMode: Bool = false
    ) async throws {
        let session = HLSVideoEngine(
            url: url,
            sourceHTTPHeaders: sourceHTTPHeaders,
            dvModeAvailable: Self.displayCapabilities.supportsDolbyVision,
            displaySupportsHDR: Self.displayCapabilities.supportsHDR,
            keepDvh1TagWithoutDV: keepDvh1TagWithoutDV,
            matchContentEnabled: matchContentEnabled,
            panelIsInHDRMode: panelIsInHDRMode,
            audioSourceStreamIndexOverride: audioSourceStreamIndex
        )
        session.onFirstHDR10PlusDetected = { [weak self] in
            Task { @MainActor in self?.handleHDR10PlusDetected() }
        }
        session.onPlaylistShiftChanged = { [weak self] seconds in
            Task { @MainActor in
                guard let self = self else { return }
                self.playlistShiftSeconds = seconds
                self.sourceTime = self.currentTime + seconds
            }
        }
        let playbackURL = try session.start()
        self.nativeVideoSession = session

        let host = NativeAVPlayerHost()
        host.playerLayer.videoGravity = _videoGravity
        // Replay any pre-load externalMetadata onto the freshly-created
        // host so its AVPlayerItem picks it up before AVPlayer assigns
        // the item. Hosts that called `engine.setExternalMetadata`
        // before `engine.load` rely on this transfer.
        if !pendingExternalMetadata.isEmpty {
            host.setExternalMetadata(pendingExternalMetadata)
        }
        self.nativeHost = host
        // Publish before wiring up the @Published mirrors below so any
        // host that subscribes via the same Combine sink sees the new
        // AVPlayer instance before the first time / state update lands.
        self.currentAVPlayer = host.avPlayer

        nativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.currentTime = value
                self.sourceTime = value + self.playlistShiftSeconds
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

        host.load(url: playbackURL, startPosition: startPosition)
    }

    /// Open a `SoftwarePlaybackHost` against the source and wire its
    /// @Published mirror into the engine's own surface. Used when the
    /// source's video codec isn't decodable by AVPlayer on the active
    /// platform (today: AV1 on Apple TV). Same lifecycle shape as
    /// `loadNative`: host loads the URL itself (no HLS-fMP4 wrapper —
    /// the SW pipeline reads the source directly through its own
    /// Demuxer).
    private func loadSoftware(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32?
    ) async throws {
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

        try await host.load(
            url: url,
            sourceHTTPHeaders: sourceHTTPHeaders,
            startPosition: startPosition,
            audioSourceStreamIndex: audioSourceStreamIndex
        )
    }

    // MARK: - Transport

    public func play() {
        if let host = softwareHost {
            host.play()
        } else {
            nativeHost?.play()
        }
        if state == .paused || state == .loading {
            state = .playing
        }
    }

    public func pause() {
        if let host = softwareHost {
            host.pause()
        } else {
            nativeHost?.pause()
        }
        if state == .playing {
            state = .paused
        }
    }

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused, .loading: play()
        default: break
        }
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
        let target = max(0, min(seconds, duration))
        state = .seeking
        if let host = softwareHost {
            await host.seek(to: target)
        } else {
            nativeHost?.seek(to: target)
        }
        currentTime = target

        // Re-arm the side subtitle demuxer at the new playhead so cues
        // for the post-scrub content surface immediately. Skip when
        // sidecar SRT is active (it pre-decoded the whole file).
        if activeEmbeddedSubtitleStreamIndex >= 0, let url = loadedURL {
            let streamIdx = activeEmbeddedSubtitleStreamIndex
            embeddedSubtitleTask?.cancel()
            subtitleCues = []
            // Side-demuxer seeks in source PTS, not AVPlayer clock.
            startEmbeddedSubtitleTask(url: url, streamIndex: streamIdx, startAt: target + playlistShiftSeconds)
        }

        // AVPlayer surfaces post-seek readiness via its own KVO; the
        // engine optimistically flips back to .playing so the host UI
        // doesn't stick on .seeking when the seek lands fast.
        state = .playing
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
    }

    /// Set playback volume (0.0 = mute, 1.0 = full).
    public var volume: Float {
        get { softwareHost?.volume ?? nativeHost?.avPlayer.volume ?? 1.0 }
        set {
            softwareHost?.volume = newValue
            nativeHost?.avPlayer.volume = newValue
        }
    }

    /// Set playback speed (0.5-2.0). On the native AVPlayer path audio
    /// pitch adjusts via `audioTimePitchAlgorithm`; on the SW path the
    /// rate goes through the synchronizer and audio plays at the
    /// changed rate without pitch correction.
    public func setRate(_ rate: Float) {
        if let host = softwareHost {
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
        stopInternal()
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
                    panelIsInHDRMode: loadedOptions.panelIsInHDRMode
                )
                EngineLog.emit("[AetherEngine] reload: loadNative done (\(elapsedMs(since: loadStart))ms)", category: .engine)
                playbackBackend = .native
                activeAudioTrackIndex = Int(audioStreamIndex)
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: preservedVideoCodec, isSoftware: false
                )
                activeAudioDecoder = nativeVideoSession?.audioPipelineDescription
                presentCurrentLayer()
                nativeHost?.play()
            }
            state = .playing
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

        // Side-demuxer seeks in source PTS, not AVPlayer clock. On the
        // native HLS path AVPlayer's currentTime sits at
        // `source_pts - playlistShiftSeconds`, so we add the shift back
        // before handing it to the side demuxer. Without this, the
        // demuxer seek lands `playlistShiftSeconds` before the actual
        // source playhead and the first emitted cue (typically a long-
        // tail past cue) is followed by a gap that reads as "subs are
        // 3-5 s late" — repro on Cars at a restart-driven shift of
        // ~3.92 s.
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
                av_packet_free(&p)
                continue
            }
            subtitlePacketsRead += 1
            let pktPTS = pkt.pointee.pts
            let event = decoder.decode(
                packet: pkt,
                streamTimeBase: tb
            )
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
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

    private func stopInternal() {
        // Stop AVPlayer fetching before tearing down the loopback HLS
        // server, otherwise AVPlayer's segment requests race the
        // server shutdown and produce noisy errors in the log. Always
        // reset display criteria so a previous DV/HDR session doesn't
        // leak the panel mode into the next playback.
        memoryProbeTask?.cancel()
        memoryProbeTask = nil
        nativeCancellables.removeAll()
        nativeHost?.tearDown()
        nativeHost = nil
        currentAVPlayer = nil
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

        displayCriteria.reset()
        playbackBackend = .none
        activeVideoDecoder = nil
        activeAudioDecoder = nil
        lastDetectedVideoCodec = AV_CODEC_ID_NONE
        playlistShiftSeconds = 0
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
                EngineLog.emit(
                    "[AetherEngine] memprobe t=\(elapsed)s "
                    + "rss=\(rssMB)MB subCues=\(cueCount) "
                    + "audioTracks=\(self.audioTracks.count) "
                    + "subTracks=\(self.subtitleTracks.count) "
                    + "subActive=\(self.isSubtitleActive)",
                    category: .engine
                )
            }
        }
    }

    /// Resident memory footprint of the current process in MB, read via
    /// `mach_task_basic_info`. Returns 0 on error. Cheap to call (no
    /// allocations) and safe from any thread.
    private static func residentMemoryMB() -> Int {
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
            // Only two real paths through the SW host today: AV1 via
            // dav1d, VP9 via libavcodec's vp9 decoder. Anything else
            // routes through the native pipeline, so this branch can be
            // exhaustive without a generic fallback.
            switch codecID {
            case AV_CODEC_ID_AV1: return "dav1d \(name) (SW)"
            case AV_CODEC_ID_VP9: return "libavcodec \(name) (SW)"
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
        let transfer = codecpar.color_trc
        // PQ + DV side data → dolbyVision; PQ alone → hdr10. HLG → hlg.
        // Everything else → sdr. Per-stream HDR10+ T.35 SEI detection
        // happens inside HLSVideoEngine; this probe is the coarse
        // gate for the display-criteria handshake.
        if transfer == AVCOL_TRC_SMPTE2084 {
            return Self.streamHasDV(stream: stream) ? .dolbyVision : .hdr10
        }
        if transfer == AVCOL_TRC_ARIB_STD_B67 {
            return .hlg
        }
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
        if trc == AVCOL_TRC_SMPTE2084 {
            return caps.supportsHDR10 ? .hdr10 : .sdr
        }
        return .sdr
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

        // Pause AVPlayer when the app backgrounds so audio doesn't
        // keep streaming in the background. The host calls
        // `reloadAtCurrentPosition()` from its own foreground hook to
        // recover from any AVIO invalidation tvOS may do during
        // suspension.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
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
