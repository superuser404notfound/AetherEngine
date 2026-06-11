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

    /// High-frequency playback clock (`currentTime`, `sourceTime`,
    /// live-edge fields). Deliberately a SEPARATE ObservableObject:
    /// its ~10 Hz ticks must not fire `objectWillChange` on the
    /// engine itself, or every engine-observing SwiftUI view
    /// re-renders per tick (tvOS native `Menu` dropdowns flicker,
    /// AetherEngine#29). Observe `clock` only in the leaf views that
    /// render time; see `PlaybackClock` for the usage guide.
    public let clock = PlaybackClock()

    /// Current playback position in seconds. Read-only convenience
    /// forwarder for polling; for push updates subscribe to
    /// `clock.$currentTime` (the engine's `objectWillChange` does NOT
    /// fire on clock ticks).
    public var currentTime: Double { clock.currentTime }

    @Published public private(set) var duration: Double = 0

    /// Forwarder; see `clock.progress`.
    public var progress: Float { clock.progress }

    @Published public private(set) var audioTracks: [TrackInfo] = []
    @Published public private(set) var subtitleTracks: [TrackInfo] = []
    /// Container metadata (tags + embedded cover) for the loaded source.
    /// nil while idle or when the source carries no metadata. Populated
    /// during `load(url:)` from the probe demuxer, before backend dispatch,
    /// so it is available for both audio and video sources.
    @Published public private(set) var metadata: MediaMetadata?
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

    /// Timer-sampled diagnostics (`liveTelemetry`, 1 Hz). Deliberately
    /// a SEPARATE ObservableObject for the same reason as `clock`: a
    /// once-per-second sample must not fire `objectWillChange` on the
    /// engine itself, or every engine-observing SwiftUI view re-renders
    /// per sample for the whole session (AetherEngine#29 follow-up).
    /// Observe `diagnostics` only in stats overlays; see
    /// `EngineDiagnostics` for the usage guide.
    public let diagnostics = EngineDiagnostics()

    /// 1 Hz snapshot of live playback telemetry while the engine is
    /// `.playing` or `.paused`. `nil` while idle. Read-only convenience
    /// forwarder for polling; for push updates subscribe to
    /// `diagnostics.$liveTelemetry` (the engine's `objectWillChange`
    /// does NOT fire on telemetry samples).
    public var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }

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

    /// Largest session-relative time reached on a live source (seconds since
    /// first frame). Meaningful only while `isLive`. 0 otherwise.
    /// Forwarder; for push updates subscribe to `clock.$liveEdgeTime`
    /// (live-edge fields tick ~1 Hz and live on the clock so they
    /// don't fire the engine's `objectWillChange`).
    public var liveEdgeTime: Double { clock.liveEdgeTime }
    /// DVR-seekable span on the session timeline, or nil when DVR is disabled
    /// or the source is not live. Forwarder; see `clock.seekableLiveRange`.
    public var seekableLiveRange: ClosedRange<Double>? { clock.seekableLiveRange }
    /// True when playback is at / near the live edge. Forwarder; see
    /// `clock.isAtLiveEdge`.
    public var isAtLiveEdge: Bool { clock.isAtLiveEdge }
    /// Seconds the playhead trails the live edge. 0 at the edge.
    /// Forwarder; see `clock.behindLiveSeconds`.
    public var behindLiveSeconds: Double { clock.behindLiveSeconds }

    /// Fires when the live source server restarted its stream from the
    /// beginning after a connection drop (e.g. a Jellyfin transcode
    /// respawn re-serving from byte 0). The engine has parked the session
    /// (playback drains the remaining buffer) and CANNOT recover on the
    /// same URL: a reopen would replay the same content again. The host
    /// must re-negotiate a fresh playback session (new transcode at the
    /// live edge) and call `load` with the new URL. Event-only (no
    /// replay): subscribe per session.
    public let liveSourceReset = PassthroughSubject<Void, Never>()

    // MARK: - Live scrub thumbnails

    /// Decode contexts for the live scrub preview, keyed by segment
    /// index. Tiny LRU (capacity 2) so scrubbing within one segment
    /// reuses the open demux/decode context; torn down in stopInternal
    /// with the rest of the session state.
    private var liveThumbnailExtractors: [(segmentIndex: Int, extractor: FrameExtractor)] = []

    /// A frame from the live DVR window at `atSessionSeconds` (the
    /// `seekableLiveRange` timeline), decoded locally from the engine's
    /// own segment cache: no network, no server round-trip. The session
    /// time is converted to the raw output timeline via the seam history
    /// before the segment lookup and the extractor seek, mirroring the
    /// inverse of the `$currentTime` fold. Returns nil when no native
    /// live session is active, the time is outside the resident window,
    /// or decoding fails. Never throws.
    public func liveScrubThumbnail(atSessionSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard isLive, let session = nativeVideoSession else { return nil }
        // Session -> output conversion: the published seekableLiveRange is
        // output-time + shift (seam-resolved), while the segment table and
        // the muxed tfdt live on the raw output timeline. Resolve the seam
        // whose output-domain span contains the converted value, newest
        // first (mirrors the $currentTime fold, inverted).
        let outputSeconds: Double
        if let seam = liveShiftSeams.last(where: { seconds - $0.shift >= $0.activateAt }) {
            outputSeconds = seconds - seam.shift
        } else {
            outputSeconds = seconds - playlistShiftSeconds
        }
        let gen = loadGeneration
        let source = await Task.detached(priority: .userInitiated) { [session] in
            session.liveScrubThumbnailSource(atSeconds: outputSeconds)
        }.value
        guard let source else { return nil }
        // A zap/stop while the detached read was in flight cleared the
        // LRU (stopInternal); inserting now would revive a dead-session
        // extractor whose per-session segment indices collide with the
        // next channel's, serving frames from the PREVIOUS channel.
        guard loadGeneration == gen else { return nil }
        let extractor: FrameExtractor
        if let idx = liveThumbnailExtractors.firstIndex(where: { $0.segmentIndex == source.segmentIndex }) {
            // Move hit to the back so it's the last to be evicted (true LRU).
            let hit = liveThumbnailExtractors.remove(at: idx)
            liveThumbnailExtractors.append(hit)
            extractor = hit.extractor
        } else {
            extractor = FrameExtractor(reader: DataIOReader(data: source.data), formatHint: "mp4")
            liveThumbnailExtractors.append((source.segmentIndex, extractor))
            while liveThumbnailExtractors.count > 2 {
                let evicted = liveThumbnailExtractors.removeFirst()
                Task { await evicted.extractor.shutdown() }
            }
        }
        return await extractor.thumbnail(at: outputSeconds, maxWidth: maxWidth)
    }

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

    /// TEST-ONLY routing override. When true, `load` forces every source
    /// through `SoftwarePlaybackHost` regardless of codec, so the SW live
    /// + DVR path can be exercised against the H.264 fixture (which would
    /// otherwise route native). Set ONLY via
    /// `setForceSoftwarePathForTesting(_:)` from `aetherctl`; nothing in
    /// the shipping app calls that setter, so normal codec dispatch is
    /// unaffected.
    nonisolated(unsafe) static var forceSoftwarePathForTesting = false

    /// TEST-ONLY. Flip the software-path routing override (see
    /// `forceSoftwarePathForTesting`). Exposed for the `aetherctl live
    /// --sw` harness; not intended for app use.
    public nonisolated static func setForceSoftwarePathForTesting(_ on: Bool) {
        forceSoftwarePathForTesting = on
    }

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

    /// DVR / live window tracker. Non-nil for ANY live session (both the
    /// native and software-decode paths construct it at load). Its
    /// `windowSeconds` is nil when DVR is disabled (live-only: no rewind
    /// range, scrubbing suppressed), and non-nil when a DVR window was
    /// requested. Updated by `publishLiveWindow`, which both the native
    /// time tick and the SW host's edge callback drive; the published
    /// live surfaces above reflect its state.
    private var liveWindow: LiveWindow?

    /// The URL of the current playback session. Used by
    /// `reloadAtCurrentPosition()` to rebuild the pipeline after
    /// background suspension.
    // Internal getter (not public API): read by the same-module
    // AetherEngine+FrameExtractor extension to vend a FrameExtractor.
    private(set) var loadedURL: URL?

    /// True when the active source is a custom `IOReader` (loaded via
    /// `load(source: .custom(...))`). Such a source has no URL: `loadedURL`
    /// holds a synthetic placeholder for bookkeeping only, so features that
    /// reopen the source by URL (reload, audio-track switch, embedded
    /// subtitles, FrameExtractor) must no-op instead of trying to reopen the
    /// placeholder. See `load(source:)` docs for the limitation list.
    /// Internal getter (read by the same-module FrameExtractor extension).
    private(set) var isCustomSource = false

    /// The active custom source's reader, retained so internal reloads can
    /// reuse it (seek + rebuild) and so concurrent features can clone it.
    /// Owned by the engine: closed in stopInternal on final teardown, nil for
    /// URL sources.
    private(set) var customReader: IOReader?

    /// The format hint passed with the active custom source, reused when the
    /// engine reopens the source (reload) or opens a clone (subtitles/scrub).
    private(set) var customFormatHint: String?

    /// Whether the active custom source is seekable (set at load from the
    /// probe demuxer's isSourceSeekable). Forward-only custom sources cannot
    /// be reopened/rewound, so reload features stay no-op for them.
    private(set) var customSourceIsSeekable = false

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

    /// Monotonic load/stop generation. Bumped by every `stopInternal`
    /// (which runs at the head of every `load()`, `stop()`, and audio
    /// reload), captured by `load()`/`reloadWithAudioOverride` after
    /// their own teardown, and re-checked after every suspension point.
    /// Without it, a load suspended at the probe / criteria handshake /
    /// session start resumed AFTER a newer load (or a plain `stop()`)
    /// and kept executing: it overwrote the successor's published
    /// state, registered its own session over the successor's (orphaning
    /// the successor's producer + loopback server forever), reloaded the
    /// SHARED native host's item out from under it, and could resurrect
    /// playback after dismissal. A superseded load now unwinds with
    /// `CancellationError` at the first checkpoint.
    private var loadGeneration: UInt64 = 0

    /// Throw when the captured generation is stale (a newer load/stop
    /// owns the engine). Callers clean up their LOCAL resources before
    /// calling; shared state belongs to the successor and must not be
    /// touched on the unwind path.
    private func checkLoadCurrent(_ gen: UInt64) throws {
        guard loadGeneration == gen else {
            EngineLog.emit(
                "[AetherEngine] load superseded (gen \(gen) -> \(loadGeneration)); unwinding",
                category: .engine
            )
            throw CancellationError()
        }
    }

    /// Session history of live program-boundary shift seams, in
    /// output-timeline order. The producer rebases its timeline the
    /// moment it READS a boundary, but AVPlayer renders that seam
    /// ~buffer + holdback later; each entry holds the new shift and the
    /// raw-clock position from which it is true for on-screen content.
    /// The `$currentTime` sink RESOLVES the active shift by looking up
    /// the newest seam at or before the raw clock (a history, not a
    /// destructive queue: a backward DVR seek across an already-crossed
    /// seam must fold pre-seam content with the pre-seam shift again).
    /// The baseline entry (activateAt -infinity) is seeded by the
    /// gate-open / restart shift. Cleared on every load/stop; capped in
    /// the append handler.
    private var liveShiftSeams: [(activateAt: Double, shift: Double)] = []

    /// 1 Hz live-window publisher, independent of playback ticks. The
    /// `$currentTime` sink only fires while AVPlayer's periodic time
    /// observer runs, i.e. NOT while paused, so without this timer
    /// `liveEdgeTime` / `behindLiveSeconds` / `isAtLiveEdge` /
    /// `seekableLiveRange` all freeze for the entire pause: the UI shows
    /// "at live edge" while drifting arbitrarily far behind, and a DVR
    /// scrub issued while paused seeks against a stale edge. The edge is
    /// reachable while paused via `host.seekableEnd` (AVPlayer keeps
    /// reloading the live playlist during a pause).
    private var liveWindowTimerTask: Task<Void, Never>?

    /// Drive the live surfaces at 1 Hz for the lifetime of a native live
    /// session. Replaces nothing: the `$currentTime` sink still publishes
    /// on every playback tick; this covers the paused case.
    private func startLiveWindowTimer(host: NativeAVPlayerHost) {
        liveWindowTimerTask?.cancel()
        guard isLive else { return }
        liveWindowTimerTask = Task { [weak self, weak host] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let host else { return }
                guard self.isLive else { continue }
                self.publishLiveWindow(edgeSessionTime: host.seekableEnd + self.playlistShiftSeconds)
            }
        }
    }

    /// Source PTS of the currently displayed frame. Equal to `currentTime`
    /// on every path now that the native clock is unified onto source time;
    /// kept as a stable alias for callers that want to express source-
    /// timeline intent explicitly (subtitle overlay, side-demuxer seek).
    /// Forwarder; for push updates subscribe to `clock.$sourceTime`.
    public var sourceTime: Double { clock.sourceTime }

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
    /// when a bitmap codec's PCS hasn't been parsed yet. Public
    /// read-only for hosts that size their UI from the source frame
    /// (AetherEngine#28); 0 before the first load or when the source
    /// has no video track. `load(source:)` also returns the full
    /// `SourceProbe`, which carries the same dimensions plus the rest
    /// of the probe metadata in one shot.
    public private(set) var sourceVideoWidth: Int32 = 0
    public private(set) var sourceVideoHeight: Int32 = 0

    /// Font files attached to the loaded container (MKV attachments),
    /// populated once during `load()` from the probe demuxer; empty
    /// when the source carries none. Hosts rendering ASS styling
    /// themselves write these to a directory and point their
    /// renderer's font config at it (AetherEngine#30). Deliberately
    /// not `@Published` and not part of `SourceProbe`: the payloads
    /// can be 10-30 MB and only playback hosts need them.
    public private(set) var fontAttachments: [FontAttachment] = []

    /// Last-detected source video codec id. Latched in `load(url:)` and
    /// reused by the audio-track-switch reload path so it can re-derive
    /// the same `activeVideoDecoder` label without re-running the
    /// demuxer probe. Reset to `AV_CODEC_ID_NONE` in `stopInternal`.
    private var lastDetectedVideoCodec: AVCodecID = AV_CODEC_ID_NONE

    /// Probe demuxer of the CURRENTLY RUNNING load(), registered before the
    /// (detached, potentially minutes-blocking) open and cleared when load()
    /// exits. stopInternal marks it closed so player dismissal / channel
    /// zapping aborts a probe stuck in the AVIOReader reconnect loop
    /// instead of letting it reconnect into the next session.
    private var inFlightProbeDemuxer: Demuxer?

    /// The embedded-subtitle side demuxer currently reading, registered
    /// by `runEmbeddedSubtitleReader` so the cancel sites can
    /// `markClosed()` it: Task cancellation alone is only observed
    /// between `readPacket` calls and a read blocked in the AVIO
    /// reconnect loop otherwise survives stop()/track switches.
    private var activeSubtitleSideDemuxer: Demuxer?

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

    /// How far past the playhead (source-PTS seconds) the embedded-
    /// subtitle side demuxer may read before parking. Without this
    /// gate the side demuxer races to EOF at network speed, which
    /// (a) downloads the entire remaining source a second time in
    /// parallel with playback and (b) accumulates every future cue
    /// in `subtitleCues`, because `pruneOldSubtitleCues` only trims
    /// BEHIND the playhead. On a large file with a PGS track the
    /// bitmap cues (each retaining a decoded RGBA CGImage) pin
    /// hundreds of MB to multiple GB and jetsam kills the app
    /// (AetherEngine#31, 50-80 GB UHD remuxes on Apple TV 4K).
    /// 90 s comfortably covers
    /// the main pump's ~60-80 s production lead plus a network
    /// hiccup on the subtitle connection; while parked, the reader's
    /// stalled `readPacket` stops draining the persistent connection
    /// and TCP backpressure (the 16 MB window high-water) pauses the
    /// transfer server-side, so the second connection throttles to
    /// playback rate instead of line rate.
    nonisolated private static let embeddedSubtitleReadAheadSeconds: Double = 90

    // MARK: - Init

    /// Lifecycle notification observers. Block-based observers are NOT
    /// auto-removed on dealloc (unlike selector-based ones), so the bag
    /// removes them in its own deinit (a MainActor deinit can't touch
    /// non-Sendable stored state under Swift 6, hence the helper class).
    /// In practice the engine is a process-wide singleton and never
    /// deallocates; this keeps the cleanup contract honest anyway.
    private let lifecycleObservers = LifecycleObserverBag()

    private final class LifecycleObserverBag: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [Any] = []
        func append(_ token: Any) {
            lock.lock(); tokens.append(token); lock.unlock()
        }
        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

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
        try probe(source: .url(url), options: options)
    }

    /// `probe(url:)` for a custom byte source (AetherEngine#27). Same
    /// one-shot metadata read, but against a caller-supplied
    /// `IOReader` instead of a URL.
    ///
    /// Reader contract: the caller retains ownership. The probe seeks
    /// and reads through the reader for libavformat's stream-info
    /// pass and leaves the cursor at an unspecified position; it does
    /// NOT call `close()`. Hand the engine a fresh reader (or one you
    /// rewind yourself) when you `load(source:)` afterwards. For the
    /// `.url` case this is exactly `probe(url:)`.
    ///
    /// `SourceProbe.url` echoes the probed URL for `.url` sources and
    /// the synthetic `aether-custom://source` for custom readers
    /// (mirroring what `load(source:)` publishes as `loadedURL`).
    public nonisolated static func probe(
        source: MediaSource,
        options: LoadOptions = .init()
    ) throws -> SourceProbe {
        let demuxer = Demuxer()
        let displayURL: URL
        switch source {
        case .url(let u):
            try demuxer.open(url: u, extraHeaders: options.httpHeaders)
            displayURL = u
        case .custom(let reader, let formatHint):
            try demuxer.open(reader: reader, formatHint: formatHint)
            displayURL = URL(string: "aether-custom://source")!
        }
        defer { demuxer.close() }
        return makeSourceProbe(demuxer: demuxer, displayURL: displayURL)
    }

    /// Assemble a `SourceProbe` from an open demuxer. Shared by the
    /// static probe entry points and `load(source:)`'s internal probe
    /// stage, so all of them report identical metadata for the same
    /// source.
    private nonisolated static func makeSourceProbe(
        demuxer: Demuxer,
        displayURL: URL
    ) -> SourceProbe {
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
        // (e.g. an IPTV catalog entry vs a movie file). Custom readers
        // (synthetic aether-custom:// scheme) never match.
        let liveSchemes: Set<String> = ["http", "https", "udp", "rtp", "rtsp"]
        let isLive = duration <= 0
            && liveSchemes.contains(displayURL.scheme?.lowercased() ?? "")

        return SourceProbe(
            url: displayURL,
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
            metadata: demuxer.mediaMetadata(),
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
    /// Load media from a URL. Convenience wrapper over `load(source:)`.
    @discardableResult
    public func load(
        url: URL,
        startPosition: Double? = nil,
        options: LoadOptions = .init(),
        audioSourceStreamIndex: Int32? = nil
    ) async throws -> SourceProbe? {
        try await load(
            source: .url(url),
            startPosition: startPosition,
            options: options,
            audioSourceStreamIndex: audioSourceStreamIndex
        )
    }

    /// Load media from a URL or a custom `IOReader`. See `MediaSource`.
    ///
    /// Custom sources: seekable readers play on both the native and
    /// software paths; forward-only readers (`seek` returns negative for
    /// SEEK_SET/CUR/END) play on the software path only. A custom source
    /// whose initial probe fails throws, since it cannot be reopened by URL.
    ///
    /// Capability for custom sources. Seekable readers support audio-track
    /// switching and background-return reload (the pipeline rebuilds on the
    /// retained reader). Embedded-subtitle selection and FrameExtractor scrub
    /// previews work when the reader implements `makeIndependentReader()` (they
    /// run a second demuxer concurrently and need an independent cursor); they
    /// no-op when it returns nil. Forward-only readers (seek returns negative)
    /// cannot rewind or, typically, clone, so those features no-op for them.
    /// Plain playback and sidecar subtitles always work.
    ///
    /// Returns the `SourceProbe` assembled from the internal probe
    /// stage (video size, codec, tracks, metadata) so hosts get the
    /// source facts without a second probe round-trip
    /// (AetherEngine#28). nil on the `nativeRemoteHLS` bypass (no
    /// probe runs there) and when the probe failed but playback
    /// proceeds anyway (URL sources can be reopened internally).
    @discardableResult
    public func load(
        source: MediaSource,
        startPosition: Double? = nil,
        options: LoadOptions = .init(),
        audioSourceStreamIndex: Int32? = nil
    ) async throws -> SourceProbe? {
        // Preserve the native AVPlayer host across a native->native reload
        // so AVKit's system Now-Playing registration survives the seam
        // (issue #15). Captured before stopInternal resets playbackBackend.
        // If this source instead routes to the software path, the SW branch
        // in the dispatch below releases the preserved host.
        let priorBackendWasNative = (playbackBackend == .native)
        stopInternal(keepNativeHost: priorBackendWasNative)
        // This load owns the engine as long as no newer stop/load bumps
        // the generation; every suspension point below re-checks.
        let gen = loadGeneration
        // A url binding the rest of the body uses. For custom sources this
        // is synthetic: it is never dereferenced for I/O (probe, native, and
        // software opens all run against the preopened probe demuxer below),
        // only used for non-I/O bookkeeping such as loadedURL.
        let url: URL
        switch source {
        case .url(let u):
            url = u
            isCustomSource = false
            customReader = nil
            customFormatHint = nil
        case .custom(let reader, let hint):
            url = URL(string: "aether-custom://source")!
            isCustomSource = true
            customReader = reader
            customFormatHint = hint
        }
        loadedURL = url
        loadedOptions = options
        isLive = options.isLive
        // Native remote-HLS has no engine-managed DVR window; the rewind
        // range is whatever the remote HLS playlist exposes. Give the live
        // window an unbounded rewind bound so the engine's live seek isn't a
        // no-op; the host's `avPlayer.seek` clamps to AVPlayer's real
        // seekable range, so an over-wide bound only affects the published
        // range's width, not where a seek actually lands. VOD/loopback live
        // keeps its disk-backed `dvrWindowSeconds`.
        liveWindow = options.isLive
            ? LiveWindow(windowSeconds: options.nativeRemoteHLS ? .greatestFiniteMagnitude : options.dvrWindowSeconds)
            : nil
        state = .loading
        clock.currentTime = 0
        nativeClockSeconds = 0
        duration = 0
        clock.progress = 0
        audioTracks = []
        subtitleTracks = []
        metadata = nil
        fontAttachments = []
        subtitleCueDiagnosticCount = 0
        // Reset format/dimension state from the previous session. Paths
        // that return before the probe (nativeRemoteHLS) or that find no
        // video track would otherwise keep publishing the predecessor's
        // values: Live TV after an HDR10 film kept reporting .hdr10 for
        // the whole live session, and the doc on sourceVideoWidth/Height
        // promises 0 when the source has no video track.
        videoFormat = .sdr
        sourceVideoFormat = .sdr
        sourceVideoWidth = 0
        sourceVideoHeight = 0

        // Native remote-HLS live path: skip the probe + loopback pipeline
        // entirely and play the URL directly with AVPlayer. The source
        // server (Jellyfin) already exposes HLS; AVPlayer manages the live
        // edge, buffering, and reconnect natively. Routed before the probe
        // because we never demux the m3u8 ourselves (unlike the audioOnly
        // divert below, which needs probe info first).
        if options.nativeRemoteHLS {
            do {
                try await loadRemoteHLS(url: url, options: options)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Without this catch a throwing loadRemoteHLS stranded
                // state at .loading forever (the bypass sits outside the
                // do/catch all other load paths run under). The body
                // can't throw today, but the signature says it can.
                state = .error("Failed to load: \(error.localizedDescription)")
                throw error
            }
            // No probe ran on this bypass; there is nothing to report.
            return nil
        }

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
        // Register the in-flight probe so stopInternal can abort it. The
        // probe's avformat_open_input / find_stream_info can block for the
        // AVIOReader's full reconnect budget against a dead live source
        // (e.g. a tuner answering HTTP 500); without this, dismissing the
        // player or zapping channels left the probe reconnecting in the
        // background THROUGH the next sessions until the budget ran out
        // (device repro: a 500-looping channel kept reconnecting across
        // three subsequent channel sessions). markClosed() is lock-free and
        // makes the blocked open return promptly.
        inFlightProbeDemuxer = probe
        // Identity-guarded: a superseding load() (channel zap mid-probe) has
        // already registered ITS probe by the time this one unwinds; an
        // unconditional nil here would strip the successor's abort handle.
        defer { if inFlightProbeDemuxer === probe { inFlightProbeDemuxer = nil } }
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
            try await Task.detached(priority: .userInitiated) { [probe, source, options] in
                switch source {
                case .url(let u):
                    // Pass isLive so the probe demuxer's AVIOReader is
                    // configured for endless-feed mode. The probe demuxer is
                    // reused as the session demuxer (avformat_open_input +
                    // avformat_find_stream_info run only once), so the
                    // AVIOReader it holds must already have isLive=true when
                    // the producer starts reading from it.
                    try probe.open(url: u, extraHeaders: options.httpHeaders, isLive: options.isLive)
                case .custom(let reader, let formatHint):
                    // Pass isLive so the probe demuxer suppresses the
                    // SEEK_END duration estimate on a forward-only live
                    // reader (same reason as the .url arm above). The probe
                    // demuxer is reused as the session demuxer, so the live
                    // flag must be set at open time.
                    try probe.open(reader: reader, formatHint: formatHint, isLive: options.isLive)
                }
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
            // probe.close() deferred: ownership transfers to `loadNative`
            // (native dispatch) or `loadSoftware` (software dispatch). Both
            // adopt the probe demuxer for reuse, or open fresh only if the
            // probe failed. On the error path probe was never opened, so
            // close is a no-op.
        } catch {
            EngineLog.emit("[AetherEngine] probe failed (\(error)); proceeding without criteria", category: .engine)
        }

        // Superseded while the probe was blocked? The probe is this
        // load's local; close it (detached, the close can block) and
        // unwind without touching shared state.
        if loadGeneration != gen {
            probe.markClosed()
            if probeOpened {
                Task.detached { [probe] in probe.close() }
            }
            try checkLoadCurrent(gen)
        }

        // Custom sources have no URL to reopen from: a failed probe is fatal.
        if case .custom = source, !probeOpened {
            state = .error("Failed to load: custom source probe failed")
            throw DemuxerError.openFailed(code: -1)
        }

        // Live fail-fast: a live source whose probe could not even open is a
        // dead tuner (the AVIOReader already burned its full reconnect
        // budget getting here). Proceeding would dispatch on codec NONE and
        // grind a second, equally doomed open for another ~30 s of spinner
        // before erroring out. Fail now so the host can show the error (or
        // try the next channel) immediately.
        if options.isLive, !probeOpened {
            state = .error("Live source unavailable")
            throw DemuxerError.openFailed(code: -5)
        }

        // Record seekability for reload gating (forward-only custom sources
        // cannot rewind, so audio-switch / background-reload stay no-op).
        customSourceIsSeekable = isCustomSource ? probe.isSourceSeekable : false

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
        metadata = probeOpened ? probe.mediaMetadata() : nil
        fontAttachments = probeOpened ? probe.fontAttachmentInfos() : []
        // Assemble the caller-facing SourceProbe now, while the probe
        // demuxer is open: ownership transfers to loadNative /
        // loadSoftware further down, after which the streams are gone
        // (AetherEngine#28).
        let sourceProbe: SourceProbe? = probeOpened
            ? Self.makeSourceProbe(demuxer: probe, displayURL: url)
            : nil
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
        //     handshake and the video dispatch below ever run. The native
        //     (AVPlayer) audio sub-branch reopens the URL itself, so it
        //     closes the probe; the FFmpeg sub-branch reuses the probe
        //     demuxer (required for custom sources, which have no URL).
        let hasVideoStream = probeOpened && probe.videoStreamIndex >= 0
        if Self.shouldUseAudioOnlyPath(audioOnlyRequested: options.audioOnly, hasVideoStream: hasVideoStream) {
            // Read the chosen audio stream's codec before closing the probe
            // so AVPlayer-decodable audio takes the native path.
            let audioCodecID: AVCodecID = (probeOpened && resolvedInitialAudio >= 0)
                ? (probe.stream(at: resolvedInitialAudio)?.pointee.codecpar.pointee.codec_id ?? AV_CODEC_ID_NONE)
                : AV_CODEC_ID_NONE
            // Custom sources have no URL; AVPlayer (loadAudioNative) cannot consume a
            // custom FFmpeg demuxer, so force the FFmpeg audio path for them.
            let useNativeAudio = !isCustomSource && Self.avPlayerCanDecodeAudio(audioCodecID)
            EngineLog.emit("[AetherEngine] audio dispatch: codec=\(audioCodecID.rawValue) -> \(useNativeAudio ? "AVPlayer" : "FFmpeg")", category: .engine)
            // A native->native reload may have preserved the previous
            // AVPlayer host (issue #15), but this source routes to an
            // audio path: release the video host now (mirrors the SW
            // branch below). Without this the old VIDEO AVPlayer stayed
            // alive and published via currentAVPlayer for the whole
            // audio session, and the volume setter kept writing into it.
            if nativeHost != nil {
                nativeHost?.tearDown()
                nativeHost = nil
                currentAVPlayer = nil
            }
            do {
                if useNativeAudio {
                    if probeOpened { probe.close() }
                    try await loadAudioNative(url: url, startPosition: startPosition, httpHeaders: options.httpHeaders, generation: gen)
                    try checkLoadCurrent(gen)
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
                        audioSourceStreamIndex: resolvedInitialAudio >= 0 ? resolvedInitialAudio : nil,
                        preopenedDemuxer: probeOpened ? probe : nil,
                        generation: gen
                    )
                    try checkLoadCurrent(gen)
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
            } catch is CancellationError {
                // Superseded: the successor owns `state`; just unwind.
                throw CancellationError()
            } catch {
                state = .error("Failed to load: \(error.localizedDescription)")
                throw error
            }
            return sourceProbe
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
                // Superseded during the panel handshake? The probe is
                // still this load's local; close it and unwind.
                if loadGeneration != gen {
                    probe.markClosed()
                    if probeOpened {
                        Task.detached { [probe] in probe.close() }
                    }
                    try checkLoadCurrent(gen)
                }
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
        var useSoftwarePath: Bool
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
        // Forward-only custom sources cannot serve the native path's seeks
        // (cue prewarm, segment seeks). The software path reads strictly
        // forward and decodes every codec, so route them there regardless.
        // Live custom sources are exempt: the live producer is forward-only
        // by design and never seeks the source backward, scrub previews come
        // from the DVR segment cache (not the source reader), and the
        // audio-switch reload guard below already no-ops for forward-only
        // custom sources. VOD keeps the SW-only rule.
        if isCustomSource && !probe.isSourceSeekable && !options.isLive {
            useSoftwarePath = true
            EngineLog.emit("[AetherEngine] custom source is forward-only, forcing software path", category: .engine)
        }
        // TEST-ONLY routing override. `aetherctl live --sw` flips this so
        // the H.264/HEVC fixture (which would normally take the native
        // path) is forced through SoftwarePlaybackHost, exercising the SW
        // live + DVR path end-to-end without a VP9/MPEG-2 fixture. Default
        // false; nothing in the shipping app sets it, so normal codec
        // routing above is unaffected. See `forceSoftwarePathForTesting`.
        if Self.forceSoftwarePathForTesting {
            useSoftwarePath = true
            EngineLog.emit("[AetherEngine] TEST override: forcing software path", category: .engine)
        }
        EngineLog.emit("[AetherEngine] dispatch: codec=\(detectedCodecID.rawValue) → \(useSoftwarePath ? "software" : "native")", category: .engine)

        do {
            if useSoftwarePath {
                // SW path now REUSES the probe demuxer (single open). Do not
                // close it here; loadSoftware adopts it (or opens fresh only
                // if the probe failed). One open AVFormatContext total.
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
                    audioSourceStreamIndex: audioSourceStreamIndex,
                    isLive: options.isLive,
                    dvrWindowSeconds: options.dvrWindowSeconds,
                    preopenedDemuxer: probeOpened ? probe : nil,
                    generation: gen
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
                    isLive: options.isLive,
                    dvrWindowSeconds: options.dvrWindowSeconds,
                    preopenedDemuxer: probeOpened ? probe : nil,
                    generation: gen
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
                try checkLoadCurrent(gen)
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
        } catch is CancellationError {
            // Superseded: a newer load/stop owns `state`; unwind quietly.
            throw CancellationError()
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
        return sourceProbe
    }

    /// Open HLSVideoEngine against the source, wire NativeAVPlayerHost
    /// to its loopback URL, forward host @Published into the engine's
    /// own published mirrors. `audioSourceStreamIndex` overrides the
    /// auto-picked audio stream when non-nil; used by the mid-playback
    /// audio-track-switch path so the new pipeline picks up the host's
    /// chosen language without a separate API entry point.
    /// Lean native-HLS live path: build an `AVPlayerItem` from the remote
    /// URL on the (reused) `NativeAVPlayerHost` and wire its @Published
    /// mirrors into the engine surface. No Demuxer, no HLSVideoEngine, no
    /// producer, no loopback server, no display-criteria handshake (AVKit
    /// drives match-content for the AVPlayerViewController). The live-window
    /// surfaces are published off `host.seekableEnd`, which reflects the
    /// remote HLS playlist's seekable range. Mirrors `loadNative`'s host +
    /// publisher wiring, minus everything loopback-specific.
    private func loadRemoteHLS(url: URL, options: LoadOptions) async throws {
        playbackBackend = .native

        let host: NativeAVPlayerHost
        if let existing = nativeHost {
            host = existing
        } else {
            host = NativeAVPlayerHost()
        }
        host.playerLayer.videoGravity = _videoGravity
        if !pendingExternalMetadata.isEmpty {
            host.setExternalMetadata(pendingExternalMetadata)
        }
        self.nativeHost = host
        // No producer on this path, so the playhead carries the AVPlayer
        // clock directly (no source-PTS fold). Keep the shift at 0.
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()
        if currentAVPlayer !== host.avPlayer {
            self.currentAVPlayer = host.avPlayer
        }

        nativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.nativeClockSeconds = value
                self.clock.currentTime = value
                self.clock.sourceTime = value
                if self.isLive {
                    self.publishLiveWindow(edgeSessionTime: host.seekableEnd)
                }
            }
            .store(in: &nativeCancellables)
        startLiveWindowTimer(host: host)
        host.$duration
            .sink { [weak self] value in
                if value > 0 { self?.duration = value }
            }
            .store(in: &nativeCancellables)
        // Intentionally do NOT flip to .paused on readiness for this path.
        // The live autostart has already called host.play(), so readyToPlay
        // is just a waypoint to .playing: the AVPlayer item is ready but is
        // still filling its initial buffer (the Jellyfin live transcode
        // spin-up can leave it in waitingToPlay for ~10 s AFTER readiness).
        // Flipping to .paused here would drop the host's loading spinner and
        // show a black 'paused' frame for that whole window. The
        // timeControlStatus sink below instead holds .loading until AVPlayer
        // actually renders, then flips to .playing.
        host.$failureMessage
            .compactMap { $0 }
            .sink { [weak self] msg in self?.state = .error(msg) }
            .store(in: &nativeCancellables)
        host.$didReachEnd
            .filter { $0 }
            .sink { [weak self] _ in self?.state = .idle }
            .store(in: &nativeCancellables)
        // Drive the host's loading/playing UI off AVPlayer's REAL transport
        // state. Critical for live: the stream stays in .loading (spinner up)
        // through the whole transcode spin-up + initial buffer, and only
        // reaches .playing when AVPlayer genuinely starts rendering. Setting
        // state = .playing eagerly at load() time (as a prior revision did)
        // dropped the spinner immediately and showed a ~10 s black screen
        // while AVPlayer was still in waitingToPlay.
        host.$timeControlStatus
            .sink { [weak self] status in
                guard let self = self else { return }
                // .error / .idle are terminal; don't resurrect them.
                if case .error = self.state { return }
                if self.state == .idle { return }
                switch status {
                case .playing:
                    if self.state != .playing { self.state = .playing }
                case .waitingToPlayAtSpecifiedRate:
                    // Bringing the stream up, or a mid-playback rebuffer.
                    // Hold .loading so the spinner shows during startup; once
                    // playback has begun the host treats .loading as a no-op
                    // for the full-screen spinner (hasStartedPlaying gate).
                    if self.state != .playing { self.state = .loading }
                case .paused:
                    // Only an explicit pause after playback began. The
                    // transient pre-roll paused at load (state == .loading)
                    // must not be mistaken for a user pause.
                    if self.state == .playing { self.state = .paused }
                @unknown default:
                    break
                }
            }
            .store(in: &nativeCancellables)

        // Start at AVPlayer's natural live edge (skipInitialSeek). AVPlayer
        // hits the remote server directly here (not the loopback); the
        // Jellyfin HLS URL carries its own auth (ApiKey / PlaySessionId /
        // LiveStreamId) as query params, so no extra HTTP headers are needed.
        host.load(url: url,
                  startPosition: nil,
                  perFrameHDR: true,
                  skipInitialSeek: true,
                  // System-adaptive buffering for fast live startup. The
                  // 4 s VOD floor forced a 3-4 s black screen pulling the
                  // buffer from the remote Jellyfin transcode before play.
                  forwardBufferDuration: 0)

        // Self-start playback. The VOD native path triggers play() at the
        // tail of load() (after loadNative returns + the display-criteria
        // handshake); this lean path early-returns from load() before that
        // code, so it must start the AVPlayer itself. No criteria handshake
        // here: AVKit drives match-content from the live AVPlayerItem on the
        // AVPlayerViewController. AVPlayer's `automaticallyWaitsToMinimize-
        // Stalling = true` handles "play before ready" — it sits in
        // `waitingToPlayAtSpecifiedRate`, buffers the first segments, then
        // plays. Without this the item loads to `readyToPlay` but stays at
        // `timeControlStatus == .paused` (one frame, never advances).
        //
        // State is left at .loading (set by load() before dispatch). It flips
        // to .playing only when the timeControlStatus sink sees AVPlayer
        // actually rendering, so the host keeps its loading spinner up through
        // the transcode spin-up instead of showing a premature black screen.
        host.play()
        startMemoryProbe()
        // No startLiveTelemetrySampler() here, deliberately: the sampler's
        // counters all read the loopback pipeline (demuxer / producer /
        // cache / server), none of which exists on this AVPlayer-direct
        // bypass. Its fields are nil-safe, but a sampler emitting all-zero
        // rows would only mislead.
    }

    private func loadNative(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32? = nil,
        keepDvh1TagWithoutDV: Bool = false,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        preopenedDemuxer: Demuxer? = nil,
        generation: UInt64
    ) async throws {
        // Upstream cadence hint for ingest sessions (nil for URL sources).
        // Safe to read here: the load probe's demuxer open blocked on the
        // reader's first bytes, and HLSLiveIngestReader publishes its
        // upstreamTargetDuration before any segment byte enters the FIFO
        // (see the ordering guarantee on that property), so by the time
        // loadNative runs the value is set for any reader that knows it.
        // HLSVideoEngine derives the playlist shaping (blocking-reload
        // eligibility, TARGETDURATION floor) from the hint itself.
        let liveSourceCadenceHint = (customReader as? LiveIngestSourceInfo)?.upstreamTargetDuration
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
            isLiveSession: isLive,
            dvrWindowSeconds: dvrWindowSeconds,
            liveSourceCadenceHint: liveSourceCadenceHint,
            preopenedDemuxer: preopenedDemuxer,
            sourceReopenableByURL: !isCustomSource
        )
        session.onFirstHDR10PlusDetected = { [weak self] in
            Task { @MainActor in self?.handleHDR10PlusDetected() }
        }
        session.onPlaylistShiftChanged = { [weak self] seconds in
            Task { @MainActor in
                guard let self = self else { return }
                self.playlistShiftSeconds = seconds
                // Gate-open / restart shift = the session baseline of the
                // seam history (valid from the beginning of the output
                // timeline). Boundary seams append after it.
                self.liveShiftSeams = [(activateAt: -.infinity, shift: seconds)]
                // Re-fold against the raw clock so the published source-PTS
                // currentTime tracks the new shift immediately (e.g. after a
                // restart that landed past the planned keyframe), rather than
                // lagging until the next periodic time tick.
                self.clock.currentTime = self.nativeClockSeconds + seconds
                self.clock.sourceTime = self.currentTime
            }
        }
        session.onPlaylistShiftRebased = { [weak self] seconds, seamOutputSeconds in
            Task { @MainActor in
                guard let self = self else { return }
                // Live program boundary: the producer rebased its timeline,
                // but AVPlayer is still rendering ~buffer + holdback of OLD
                // program. Record the seam and let the $currentTime sink
                // resolve the active shift from the history, so the
                // published currentTime/sourceTime never jump ahead of what
                // is actually on screen, and a backward DVR seek across a
                // crossed seam folds with the pre-seam shift again. Seams
                // append in output-timeline order by construction (the
                // continuation dts is monotonic even for backward source
                // jumps).
                self.liveShiftSeams.append(
                    (activateAt: seamOutputSeconds, shift: seconds)
                )
                if self.liveShiftSeams.count > 64 {
                    // Bound the history; dropping the oldest only loses
                    // shift fidelity for DVR positions older than 60+
                    // program boundaries, far outside any real window.
                    self.liveShiftSeams.removeFirst(self.liveShiftSeams.count - 64)
                }
            }
        }
        session.onLiveSourceReset = { [weak self, weak session] in
            Task { @MainActor in
                // A stale session (superseded by a zap) must not trigger a
                // retune of whatever is playing now.
                guard let self, let session,
                      self.nativeVideoSession === session else { return }
                self.liveSourceReset.send()
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
        // Superseded while the session was starting? The session is this
        // load's local: stop it (its teardown detaches internally) and
        // unwind before touching the shared host or registering it.
        if loadGeneration != generation {
            session.stop()
            try checkLoadCurrent(generation)
        }
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
                // Resolve the shift for the playhead's position from the
                // seam history (see onPlaylistShiftRebased above): newest
                // seam at or before the raw clock wins, so forward
                // playback activates seams as they're crossed AND a
                // backward DVR seek re-applies the pre-seam shift.
                if let active = self.liveShiftSeams.last(where: { value >= $0.activateAt }) {
                    self.playlistShiftSeconds = active.shift
                }
                self.clock.currentTime = value + self.playlistShiftSeconds
                self.clock.sourceTime = self.currentTime
                // Live: publish the DVR window surfaces on every tick. The
                // edge must sit on the SAME session axis as the playhead. The
                // playhead is folded as host.currentTime + playlistShiftSeconds
                // above, so the edge (host.seekableEnd in the AVPlayer clock)
                // folds the same way: seekableEnd + playlistShiftSeconds. Using
                // the opposite sign would put edge and playhead on different
                // axes and behindLiveSeconds would be meaningless.
                if self.isLive {
                    self.publishLiveWindow(edgeSessionTime: host.seekableEnd + self.playlistShiftSeconds)
                }
            }
            .store(in: &nativeCancellables)
        startLiveWindowTimer(host: host)
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
        // Loopback live deliberately keeps the 4 s forwardBufferDuration
        // default rather than a deeper buffer. A deep buffer is actively
        // harmful for live: against the instant-delivering loopback server
        // AVPlayer pulls the entire visible playlist up front, races to the
        // live edge, and then hits the one-time transcode warm-up gap (the
        // ~8 s before the producer cuts the next segment) head-on at the
        // edge, stalling for the full gap on -12888. A 4 s buffer instead
        // PACES AVPlayer's consumption to match production, so it plays
        // through its lead while the producer rides out the warm-up, leaving
        // only a brief startup hiccup. Verified on device: 8 s made the
        // startup pause far worse (8-10 s) than the 4 s default (~1 s).
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
        audioSourceStreamIndex: Int32?,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        preopenedDemuxer: Demuxer?,
        generation: UInt64
    ) async throws {
        activateRendererAudioSession()
        let host = SoftwarePlaybackHost()
        host.onFirstHDR10PlusDetected = { [weak self] in
            Task { @MainActor in self?.handleHDR10PlusDetected() }
        }
        // Live edge publishing: the SW host calls this on its time tick
        // with the session-relative edge; the engine publishes the same
        // four live surfaces it does for the native path. No-op when the
        // session is not live (liveWindow nil -> publishLiveWindow no-ops).
        host.onLiveEdge = { [weak self] edge in
            self?.publishLiveWindow(edgeSessionTime: edge)
        }
        self.softwareHost = host
        // SW path's currentTime tracks source PTS directly, so the
        // AVPlayer-clock shift is 0 and sourceTime mirrors currentTime.
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()

        softwareCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.clock.currentTime = value
                self.clock.sourceTime = value
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

        // Reuse the probe demuxer when present (no second avformat_open_input;
        // also what makes forward-only sources work here, no seek(0) reopen).
        // Fall back to a fresh open only when the probe failed to open.
        // The (possibly blocking) open stays detached so the @MainActor
        // runloop keeps ticking, matching the probe / session.start pattern.
        try await Task.detached(priority: .userInitiated) {
            [host, preopenedDemuxer, url, sourceHTTPHeaders, isLive, dvrWindowSeconds] in
            let dem: Demuxer
            if let pre = preopenedDemuxer {
                dem = pre
            } else {
                dem = Demuxer()
                try dem.open(url: url, extraHeaders: sourceHTTPHeaders, isLive: isLive)
            }
            try await host.load(
                demuxer: dem,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex,
                isLive: isLive,
                dvrWindowSeconds: dvrWindowSeconds
            )
        }.value
        // Superseded while the host was loading? The successor's
        // stopInternal already detached this host from the engine;
        // stop it again (idempotent) so the demuxer the detached
        // closure opened is torn down, then unwind.
        if loadGeneration != generation {
            host.stop()
            try checkLoadCurrent(generation)
        }
    }

    /// Open an `AudioPlaybackHost` against an audio-only source and wire
    /// its @Published mirror into the engine's surface. The lean path:
    /// no HLS pipeline, no display layer, no display-criteria handshake.
    /// Same lifecycle shape as `loadSoftware`.
    private func loadAudio(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        preopenedDemuxer: Demuxer?,
        generation: UInt64
    ) async throws {
        activateRendererAudioSession()
        let host = AudioPlaybackHost()
        self.audioHost = host
        // Audio path tracks source PTS directly: no AVPlayer-clock shift.
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()

        audioCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.clock.currentTime = value
                self.clock.sourceTime = value
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

        // Reuse the probe demuxer when present (custom sources require it,
        // since they have no URL to reopen; URL sources just skip a redundant
        // open). Fall back to a fresh open only when the probe failed.
        // The (possibly blocking) open stays detached so the @MainActor
        // runloop keeps ticking.
        try await Task.detached(priority: .userInitiated) {
            [host, preopenedDemuxer, url, sourceHTTPHeaders] in
            let dem: Demuxer
            if let pre = preopenedDemuxer {
                dem = pre
            } else {
                dem = Demuxer()
                try dem.open(url: url, extraHeaders: sourceHTTPHeaders)
            }
            try await host.load(
                demuxer: dem,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex
            )
        }.value
        // Superseded while the host was loading? Same unwind as
        // loadSoftware: re-stop the detached host, then throw.
        if loadGeneration != generation {
            host.stop()
            try checkLoadCurrent(generation)
        }
    }

    /// Open an `AudioAVPlayerHost` against an audio-only source AVPlayer can
    /// decode natively, and wire its @Published mirror into the engine's
    /// surface. The native, energy-efficient default for audio-only; the
    /// FFmpeg `loadAudio` path is the fallback for codecs AVPlayer cannot
    /// decode. Same lifecycle shape as loadAudio.
    private func loadAudioNative(
        url: URL,
        startPosition: Double?,
        httpHeaders: [String: String],
        generation: UInt64
    ) async throws {
        // Reuse the persistent host (and its MPNowPlayingSession) across
        // tracks; only create it the first time. host.load() below swaps the
        // item via replaceCurrentItem on the same AVPlayer.
        activateRendererAudioSession()
        let host = audioAVPlayerHost ?? AudioAVPlayerHost()
        self.audioAVPlayerHost = host
        self.audioAVPlayerActive = true
        self.playlistShiftSeconds = 0
        self.liveShiftSeams.removeAll()
        // Reclaim Now-Playing ownership for this session on each track start,
        // so the Home badge + remote commands stay bound across a pause.
        host.becomeActiveNowPlaying()
        host.setExternalMetadata(pendingExternalMetadata)

        audioNativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in
                guard let self = self else { return }
                self.clock.currentTime = value
                self.clock.sourceTime = value
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
        // Superseded while the (persistent, shared) host was loading?
        // Don't tear the host down, the successor may be using it; just
        // unwind before play()/state writes.
        try checkLoadCurrent(generation)
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
        clampLiveResumeIfBehindWindow()
    }

    /// Live resume clamp. While paused the live edge keeps advancing (the
    /// 1 Hz window timer keeps `liveWindow` fresh), and a pause longer
    /// than the retention window leaves the playhead on content the
    /// sliding window has already evicted. AVPlayer would then fetch
    /// evicted segments (fast-404'd by the provider) instead of cleanly
    /// resuming, so jump the playhead back inside the window: to just
    /// above the DVR window's lower bound when a DVR window exists, or to
    /// the live edge for live-only sessions (their server-side retention
    /// floor is 60 s; clamping at 45 s leaves headroom before eviction).
    private func clampLiveResumeIfBehindWindow() {
        guard isLive, let w = liveWindow else { return }
        let margin: Double = 5
        if let win = w.windowSeconds {
            guard w.behindLiveSeconds > (win - margin) else { return }
            let t = (w.seekableRange?.lowerBound ?? w.edgeTime) + margin
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(String(format: "%.1f", w.behindLiveSeconds))s "
                + "window=\(String(format: "%.0f", win)) -> seek \(String(format: "%.1f", t))",
                category: .session
            )
            Task { await self.seek(to: t) }
        } else {
            // Live-only: seek(to:) refuses targets without a DVR window,
            // so route through the edge snap (which drives the host
            // directly).
            guard w.behindLiveSeconds > 45 else { return }
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(String(format: "%.1f", w.behindLiveSeconds))s "
                + "window=live-only -> edge snap",
                category: .session
            )
            Task { await self.seekToLiveEdge() }
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
        if isCustomSource {
            // No URL to reopen; rebuild on the retained reader (seekable only),
            // keeping the current audio track.
            guard customSourceIsSeekable, let placeholderURL = loadedURL else { return }
            await reloadWithAudioOverride(
                url: placeholderURL,
                audioStreamIndex: activeAudioTrackIndex.map { Int32($0) }
            )
            return
        }
        guard let url = loadedURL else { return }
        let pos = currentTime
        try await load(url: url, startPosition: pos > 1 ? pos : nil, options: loadedOptions)
    }

    public func seek(to seconds: Double) async {
        // No active session: a host scrub racing stop() must not flip an
        // idle/error engine to .seeking -> .playing with no pipeline
        // behind it.
        switch state {
        case .idle, .error:
            EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: no active session (state=\(state))", category: .engine)
            return
        case .loading:
            // Mid-load there are no hosts yet: the body below would be
            // all no-ops but still flip state to .playing, dropping the
            // host's spinner early and breaking the $isReady -> .paused
            // waypoint that load() is still driving.
            EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: load in progress", category: .engine)
            return
        default:
            break
        }
        // Live-only sources (no DVR window) have no rewind range; AVPlayer
        // would either stall indefinitely or land on a segment the playlist
        // hasn't materialised. DVR sources expose a bounded seekable range
        // and fall through. Hosts can hide the scrubber by observing
        // `$seekableLiveRange == nil` so this guard is defence-in-depth.
        if isLive {
            guard let w = liveWindow, w.windowSeconds != nil else {
                EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: live, DVR disabled", category: .engine)
                return
            }
        }
        // VOD: clamp to [0, duration] in source PTS. Live/DVR: clamp to the
        // window's session-relative seekable range.
        let target: Double = isLive ? (liveWindow?.clamp(seconds) ?? seconds) : max(0, min(seconds, duration))
        state = .seeking
        if isLive {
            // Live/DVR native path: translate the session-time target into the
            // AVPlayer live clock. Measure how far behind the live edge the
            // (clamped) target sits, then apply that same delta backward from
            // AVPlayer's current seekable-range end. Because the published edge
            // is seekableEnd + playlistShiftSeconds (the same fold as the
            // playhead), this collapses to clockTarget = target - shift, which
            // is consistent with the engine's source-PTS axis. We compute it via
            // the behind-delta to stay robust if the edge advances between the
            // publish tick and this seek.
            // Software-decode live path: drive the SW host's ring-backed
            // DVR reseed with the session-time target directly (the host
            // maps session time to source PTS internally). The native
            // AVPlayer-clock translation below does not apply; there is no
            // nativeHost, so do NOT touch nativeClockSeconds.
            if softwareHost != nil, nativeHost == nil {
                EngineLog.emit("[AetherEngine] SW live seek target=\(target)", category: .engine)
                await softwareHost?.seek(to: target)
                clock.currentTime = target
                clock.sourceTime = target
                state = .playing
                return
            }
            let behind = (liveWindow?.edgeTime ?? target) - target   // >= 0; 0 == "to the edge"
            let clockTarget = max(0, (nativeHost?.seekableEnd ?? 0) - behind)
            EngineLog.emit("[AetherEngine] live seek target=\(target) behind=\(behind) seekableEnd=\(nativeHost?.seekableEnd ?? 0) clockTarget=\(clockTarget)", category: .engine)
            // Skip extendVisibleWindow: that is the VOD sliding-window mechanism.
            // The live playlist already exposes its window of segments.
            nativeHost?.seek(to: clockTarget)
            nativeClockSeconds = clockTarget
            clock.currentTime = target
            clock.sourceTime = target
            // publishLiveWindow on the next tick recomputes behindLiveSeconds
            // against the new playhead.
            state = .playing
            return
        }
        // seek(to:) speaks source PTS (the unified engine clock). On the
        // native path AVPlayer's HLS clock sits at source - playlistShiftSeconds,
        // so convert before driving the host. The SW / audio hosts already
        // run on source time (shift 0), making this a no-op there.
        let clockTarget = target - playlistShiftSeconds
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
        clock.currentTime = target
        clock.sourceTime = target

        // Re-arm the side subtitle demuxer at the new playhead so cues
        // for the post-scrub content surface immediately. Skip when
        // sidecar SRT is active (it pre-decoded the whole file).
        if activeEmbeddedSubtitleStreamIndex >= 0, let url = loadedURL {
            let streamIdx = activeEmbeddedSubtitleStreamIndex
            embeddedSubtitleTask?.cancel()
            embeddedSubtitleTask = nil
            activeSubtitleSideDemuxer?.markClosed()
            activeSubtitleSideDemuxer = nil
            subtitleCues = []
            // Side-demuxer seeks in source PTS, which is the seek target.
            // For custom sources, request a fresh clone; skip re-arm if the
            // reader cannot produce one (forward-only source mid-seek).
            if isCustomSource {
                if let clone = customReader?.makeIndependentReader() {
                    startEmbeddedSubtitleTask(url: url, reader: clone, formatHint: customFormatHint, streamIndex: streamIdx, startAt: target)
                }
            } else {
                startEmbeddedSubtitleTask(url: url, reader: nil, formatHint: nil, streamIndex: streamIdx, startAt: target)
            }
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

    /// Update the live DVR window from a path's reported edge and publish the
    /// four live surfaces (`liveEdgeTime`, `seekableLiveRange`, `isAtLiveEdge`,
    /// `behindLiveSeconds`). Path-agnostic: the native tick and the SW
    /// tick both call this with their session-relative edge time. No-op when
    /// no live window is active.
    @MainActor
    private func publishLiveWindow(edgeSessionTime: Double) {
        guard var w = liveWindow else { return }
        w.noteEdge(edgeSessionTime)
        w.notePlayhead(currentTime)
        liveWindow = w
        clock.liveEdgeTime = w.edgeTime
        clock.seekableLiveRange = w.seekableRange
        clock.isAtLiveEdge = w.isAtEdge
        clock.behindLiveSeconds = w.behindLiveSeconds
    }

    /// Seek to the current live edge. No-op when not live. With DVR enabled this
    /// resolves to `behind = 0` -> `clockTarget = seekableEnd`, i.e. the edge.
    public func seekToLiveEdge() async {
        guard isLive, let w = liveWindow else { return }
        // Live-only (no DVR window): seek(to:) refuses every target since
        // there is no rewind range, but snapping TO the edge is always
        // legal, and it is the recovery move after a long pause leaves
        // the playhead on evicted content. Drive the native host directly
        // at its own seekable end (the SW live-only path has no ring and
        // plays at the edge by construction; nothing to do there).
        guard w.windowSeconds != nil else {
            if let host = nativeHost {
                let clockTarget = max(0, host.seekableEnd)
                EngineLog.emit(
                    "[AetherEngine] live-only edge snap: clockTarget=\(String(format: "%.1f", clockTarget))",
                    category: .engine
                )
                host.seek(to: clockTarget)
                nativeClockSeconds = clockTarget
                clock.currentTime = clockTarget + playlistShiftSeconds
                clock.sourceTime = currentTime
            }
            return
        }
        await seek(to: w.edgeTime)
    }

    public func stop() {
        stopInternal()
        state = .idle
        clock.currentTime = 0
        clock.progress = 0
        // Published-surface hygiene: without these, the PREVIOUS
        // session's metadata/track lists/duration/format survive until
        // the next load() and hosts reading between stop and load see
        // stale values. pendingExternalMetadata would even replay the
        // old title/artwork onto an unrelated next session.
        duration = 0
        metadata = nil
        audioTracks = []
        subtitleTracks = []
        // Session-scoped like the track lists; must survive stopInternal,
        // which also runs under the audio-track-switch reload (that path
        // skips the probe, so clearing here would strand the session with
        // an empty font list after any audio switch).
        fontAttachments = []
        videoFormat = .sdr
        sourceVideoFormat = .sdr
        sourceVideoWidth = 0
        sourceVideoHeight = 0
        pendingExternalMetadata = []
        // Source identity is load-scoped, but the public stop() ends the
        // session for good: clearing it here keeps reloadAtCurrentPosition
        // from resurrecting the old URL (e.g. a background-return hook
        // firing after the player was dismissed) and keeps
        // selectSubtitleTrack from spawning a side demuxer against a
        // stopped session. load() re-sets all of these immediately, so the
        // internal stopInternal()-then-reload paths are unaffected.
        loadedURL = nil
        isCustomSource = false
        customSourceIsSeekable = false
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
        // Custom sources rebuild on the retained reader; a forward-only reader
        // cannot rewind, so it stays a no-op.
        if isCustomSource && !customSourceIsSeekable { return }
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

    /// Perform a pipeline rebuild at the current playhead. Tears the current
    /// session down, brings a fresh pipeline up with an optional audio source
    /// stream override (nil keeps the auto-picked track), resumes at the
    /// current position, and re-arms whichever subtitle source was active when
    /// this task actually began executing. Called by `selectAudioTrack` (with a
    /// concrete index) and by `reloadAtCurrentPosition` for custom sources
    /// (with nil to keep the current track). For custom sources the rebuild
    /// reuses the retained `customReader` (see the `customPreopened` block);
    /// for URL sources `loadSoftware`/`loadNative` reopen the URL.
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
        audioStreamIndex: Int32?
    ) async {
        let resumeAt = currentTime
        let embeddedStreamToResume: Int32 = activeEmbeddedSubtitleStreamIndex
        let sidecarToResume: URL? = isSubtitleActive && activeEmbeddedSubtitleStreamIndex < 0
            ? loadedSidecarURL
            : nil
        EngineLog.emit(
            "[AetherEngine] reload begin: audioStream=\(audioStreamIndex.map(String.init) ?? "nil") resumeAt=\(String(format: "%.2f", resumeAt))s embeddedSub=\(embeddedStreamToResume) sidecar=\(sidecarToResume?.lastPathComponent ?? "nil")",
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
        stopInternal(resetDisplayCriteria: false, keepNativeHost: !wasOnSoftwarePath, keepCustomReader: true)
        EngineLog.emit("[AetherEngine] reload: stopInternal done (\(elapsedMs(since: reloadStart))ms)", category: .engine)
        // Same supersede contract as load(): a newer load/stop bumps the
        // generation and this reload unwinds at the next checkpoint.
        let gen = loadGeneration
        loadedURL = url
        lastDetectedVideoCodec = preservedVideoCodec

        // Custom sources have no URL to reopen; rebuild the pipeline on the
        // retained reader. Build the demuxer off-main (find_stream_info
        // blocks) and hand it through the existing preopenedDemuxer channel.
        // The reader is seekable here (forward-only custom reload entry points
        // no-op). The demuxer opens at byte 0; loadSoftware/loadNative then
        // seek to the resume position via their startPosition argument.
        var customPreopened: Demuxer? = nil
        if isCustomSource, let reader = customReader {
            let hint = customFormatHint
            do {
                let isLiveReload = loadedOptions.isLive
                customPreopened = try await Task.detached(priority: .userInitiated) {
                    let d = Demuxer()
                    // isLive preserved across audio-track reload: a live
                    // custom source must not trigger SEEK_END on reopen.
                    try d.open(reader: reader, formatHint: hint, isLive: isLiveReload)
                    return d
                }.value
            } catch {
                EngineLog.emit("[AetherEngine] reload: custom reader reopen failed: \(error)", category: .engine)
                activeAudioTrackIndex = previousAudioIndex
                state = .error("Reload failed: \(error.localizedDescription)")
                return
            }
            if loadGeneration != gen {
                customPreopened?.markClosed()
                if let d = customPreopened {
                    Task.detached { d.close() }
                }
                EngineLog.emit("[AetherEngine] reload superseded after reader reopen; unwinding", category: .engine)
                return
            }
        }

        do {
            let loadStart = DispatchTime.now()
            if wasOnSoftwarePath {
                EngineLog.emit("[AetherEngine] reload: loadSoftware enter audio=\(audioStreamIndex.map(String.init) ?? "nil") resumeAt=\(String(format: "%.2f", resumeAt))s", category: .engine)
                try await loadSoftware(
                    url: url,
                    sourceHTTPHeaders: loadedOptions.httpHeaders,
                    // Live rejoins at the live edge; a stale playhead
                    // resume position is meaningless against the fresh
                    // source connection.
                    startPosition: loadedOptions.isLive ? nil : (resumeAt > 1 ? resumeAt : nil),
                    audioSourceStreamIndex: audioStreamIndex,
                    isLive: loadedOptions.isLive,
                    dvrWindowSeconds: loadedOptions.dvrWindowSeconds,
                    preopenedDemuxer: customPreopened,
                    generation: gen
                )
                EngineLog.emit("[AetherEngine] reload: loadSoftware done (\(elapsedMs(since: loadStart))ms)", category: .engine)
                playbackBackend = .software
                activeAudioTrackIndex = audioStreamIndex.map { Int($0) }
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: preservedVideoCodec, isSoftware: true
                )
                activeAudioDecoder = Self.softwareAudioDecoderLabel(
                    audioTracks: audioTracks, activeIndex: audioStreamIndex ?? -1
                )
                presentCurrentLayer()
                softwareHost?.play()
            } else {
                EngineLog.emit("[AetherEngine] reload: loadNative enter audio=\(audioStreamIndex.map(String.init) ?? "nil") resumeAt=\(String(format: "%.2f", resumeAt))s", category: .engine)
                try await loadNative(
                    url: url,
                    sourceHTTPHeaders: loadedOptions.httpHeaders,
                    // Live rejoins at the live edge (see loadSoftware above).
                    startPosition: loadedOptions.isLive ? nil : (resumeAt > 1 ? resumeAt : nil),
                    audioSourceStreamIndex: audioStreamIndex,
                    keepDvh1TagWithoutDV: loadedOptions.keepDvh1TagWithoutDV,
                    matchContentEnabled: loadedOptions.matchContentEnabled,
                    panelIsInHDRMode: loadedOptions.panelIsInHDRMode,
                    audioBridgeMode: loadedOptions.audioBridgeMode,
                    // Without these the audio-switch reload of a LIVE session
                    // rebuilt the pipeline as VOD: the demuxer opened in
                    // streaming mode (no live reconnect machinery) and
                    // HLSVideoEngine ran the duration guard against a 0-length
                    // source, failing the whole switch with "cannot build
                    // segment plan" (device repro: KiKA).
                    isLive: loadedOptions.isLive,
                    dvrWindowSeconds: loadedOptions.dvrWindowSeconds,
                    preopenedDemuxer: customPreopened,
                    generation: gen
                )
                EngineLog.emit("[AetherEngine] reload: loadNative done (\(elapsedMs(since: loadStart))ms)", category: .engine)
                playbackBackend = .native
                activeAudioTrackIndex = audioStreamIndex.map { Int($0) }
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
                try checkLoadCurrent(gen)
                nativeHost?.play()
            }
            try checkLoadCurrent(gen)
            state = .playing
            // Re-arm the diagnostic samplers. stopInternal nilled the
            // sampler instance + diagnostics.liveTelemetry, and the
            // reload path bypasses the public load() that would
            // otherwise restart them, so without this the host's
            // stats overlay sees liveTelemetry stuck at nil and
            // renders "-" for every field after the first audio
            // track switch in a session.
            startMemoryProbe()
            startLiveTelemetrySampler()
            EngineLog.emit("[AetherEngine] reload: state=.playing total=\(elapsedMs(since: reloadStart))ms", category: .engine)
        } catch is CancellationError {
            // Superseded by a newer load/stop: it owns the engine state.
            return
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
        guard let url = loadedURL else { return }
        // Embedded-subtitle selection runs a side demuxer concurrently with
        // playback. For custom sources the side demuxer needs an independent
        // second cursor; if the reader cannot clone, no-op. Mint the clone
        // after the loadedURL guard so it is never leaked on an early return.
        var customClone: IOReader? = nil
        if isCustomSource {
            guard let clone = customReader?.makeIndependentReader() else { return }
            customClone = clone
        }
        cancelSidecarTask()
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        // Unblock a side demuxer parked in a network read; cancel alone
        // is only observed between reads (see runEmbeddedSubtitleReader).
        activeSubtitleSideDemuxer?.markClosed()
        activeSubtitleSideDemuxer = nil

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
        startEmbeddedSubtitleTask(url: url, reader: customClone, formatHint: customFormatHint, streamIndex: Int32(index), startAt: sourceTime)
    }

    /// Spin up the side-demuxer Task that streams cues into the
    /// engine. Captured-on-init: the URL, the stream index, the
    /// start position, and the source video dimensions. The Task's
    /// run loop is cancellable; `cancel()` triggers a clean exit.
    private func startEmbeddedSubtitleTask(url: URL, reader: IOReader?, formatHint: String?, streamIndex: Int32, startAt: Double) {
        let w = sourceVideoWidth > 0 ? sourceVideoWidth : 1920
        let h = sourceVideoHeight > 0 ? sourceVideoHeight : 1080
        let headers = loadedOptions.httpHeaders
        let preserveASS = loadedOptions.preserveASSMarkup
        embeddedSubtitleTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runEmbeddedSubtitleReader(
                url: url, reader: reader, formatHint: formatHint,
                headers: headers, streamIndex: streamIndex, startAt: startAt,
                videoWidth: w, videoHeight: h, preserveASSMarkup: preserveASS
            )
        }
    }

    /// Side-demuxer read loop. Opens a fresh `Demuxer` against the
    /// source URL, prewarms the cue table by seeking mid-file (so the
    /// MKV demuxer's cue index is loaded before the real seek), then
    /// seeks slightly before the requested start time and streams
    /// subtitle packets through an `EmbeddedSubtitleDecoder`, emitting
    /// cues back into the engine on the main actor. The loop paces
    /// itself against the playhead (`embeddedSubtitleReadAheadSeconds`)
    /// instead of racing to EOF; see the constant's doc for why.
    nonisolated private func runEmbeddedSubtitleReader(
        url: URL, reader: IOReader?, formatHint: String?,
        headers: [String: String], streamIndex: Int32, startAt: Double,
        videoWidth: Int32, videoHeight: Int32, preserveASSMarkup: Bool = false
    ) async {
        let demuxer = Demuxer()
        // Register for abort: Task.cancel() is only observed BETWEEN
        // readPacket calls, but a side demuxer blocked inside the AVIO
        // reconnect loop against a stalled source survived stop()/track
        // switches and kept its connection reconnecting into the next
        // session, the same orphan class the probe-abort hook fixed for
        // load(). markClosed (from the cancel sites) makes the blocked
        // read return promptly.
        let registered = await MainActor.run { [weak self] () -> Bool in
            // Stale-task guard: if this task was already cancelled (track
            // switch A->B where B's registration landed first), overwriting
            // would hijack B's abort handle. The cancel sites would then
            // markClosed the wrong demuxer and A's identity-guarded defer
            // would nil B's registration, leaving B's reader unabortable.
            guard !Task.isCancelled, let self else { return false }
            self.activeSubtitleSideDemuxer = demuxer
            return true
        }
        guard registered else {
            reader?.close()
            return
        }
        defer {
            Task { @MainActor [weak self, weak demuxer] in
                if let self, let demuxer, self.activeSubtitleSideDemuxer === demuxer {
                    self.activeSubtitleSideDemuxer = nil
                }
            }
        }
        do {
            if let reader = reader {
                try demuxer.open(reader: reader, formatHint: formatHint)
            } else {
                try demuxer.open(url: url, extraHeaders: headers)
            }
        } catch {
            EngineLog.emit("[AetherEngine] embedded subtitle open failed: \(error)", category: .engine)
            reader?.close()
            await MainActor.run { [weak self] in
                // Stale-task guard: a cancelled reader (track switch in
                // flight) must not clear the SUCCESSOR's loading spinner.
                guard !Task.isCancelled else { return }
                self?.isLoadingSubtitles = false
            }
            return
        }
        // The side demuxer owns the clone reader (the bridge does not close
        // it); close it after the demuxer is torn down.
        defer {
            demuxer.close()
            reader?.close()
        }

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
                  sourceVideoHeight: videoHeight,
                  preserveASSMarkup: preserveASSMarkup
              )
        else {
            EngineLog.emit("[AetherEngine] embedded subtitle decoder open failed for stream=\(streamIndex)", category: .engine)
            await MainActor.run { [weak self] in
                // Stale-task guard: a cancelled reader (track switch in
                // flight) must not clear the SUCCESSOR's loading spinner.
                guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            self?.isLoadingSubtitles = false
        }

        var totalPacketsRead = 0
        var subtitlePacketsRead = 0
        var cuesEmitted = 0
        var firstCueLogged = false

        // Playhead pacing (AetherEngine#31): track demux progress via
        // every packet's timestamp (video/audio packets included; the
        // subtitle stream alone is too sparse to gate on) and park the
        // loop once it runs `embeddedSubtitleReadAheadSeconds` past
        // the playhead. `playheadSnapshot` is refreshed lazily from
        // the MainActor only when the threshold trips, which in steady
        // state is a couple of hops per second at the lead boundary.
        var playheadSnapshot = startAt
        var parkLogged = false
        var timeBaseCache: [Int32: AVRational] = [:]

        readLoop: while !Task.isCancelled {
            guard let pkt = try? demuxer.readPacket() else {
                break
            }
            totalPacketsRead += 1
            let streamIdx = pkt.pointee.stream_index

            // Packet position in source-PTS seconds, from the packet's
            // own stream timebase. NOPTS-valued packets don't advance
            // the pacing clock.
            let rawTS = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
            var pktSeconds: Double?
            if rawTS != Int64.min {
                let ptb: AVRational
                if let cached = timeBaseCache[streamIdx] {
                    ptb = cached
                } else {
                    ptb = demuxer.stream(at: streamIdx)?.pointee.time_base
                        ?? AVRational(num: 0, den: 1)
                    timeBaseCache[streamIdx] = ptb
                }
                if ptb.num > 0, ptb.den > 0 {
                    pktSeconds = Double(rawTS) * Double(ptb.num) / Double(ptb.den)
                }
            }

            if streamIdx == streamIndex {
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
                        guard !Task.isCancelled else { return }
                        self?.applySubtitleEvent(event)
                    }
                }
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
            }

            // Park until the playhead catches up to within the read-
            // ahead window. Task cancellation (track switch, seek,
            // stop) is observed by Task.sleep, which throws
            // immediately on a cancelled task.
            if let pktSeconds, pktSeconds > playheadSnapshot + Self.embeddedSubtitleReadAheadSeconds {
                while !Task.isCancelled {
                    guard let fresh = await MainActor.run(body: { [weak self] in self?.sourceTime }) else {
                        break readLoop
                    }
                    playheadSnapshot = fresh
                    if pktSeconds <= playheadSnapshot + Self.embeddedSubtitleReadAheadSeconds {
                        break
                    }
                    if !parkLogged {
                        parkLogged = true
                        EngineLog.emit(
                            "[AetherEngine] embedded subtitle reader parked: " +
                            "demuxPos=\(String(format: "%.1f", pktSeconds))s " +
                            "playhead=\(String(format: "%.1f", playheadSnapshot))s " +
                            "lead=\(Int(Self.embeddedSubtitleReadAheadSeconds))s",
                            category: .engine
                        )
                    }
                    do {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    } catch {
                        break readLoop
                    }
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
    ///
    /// `httpHeaders`: extra headers for the subtitle fetch (WebDAV
    /// auth and friends, #32). nil forwards the loaded session's
    /// `LoadOptions.httpHeaders`, so a subtitle served by the same
    /// authenticated host as the media works without repeating the
    /// headers; pass an explicit dictionary (or `[:]`) to override.
    public func selectSidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        cancelSidecarTask()
        // Sidecar replaces any active embedded stream.
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        // Unblock a side demuxer parked in a network read; cancel alone
        // is only observed between reads (see runEmbeddedSubtitleReader).
        activeSubtitleSideDemuxer?.markClosed()
        activeSubtitleSideDemuxer = nil
        activeEmbeddedSubtitleStreamIndex = -1

        loadedSidecarURL = url
        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true

        let effectiveHeaders = httpHeaders ?? loadedOptions.httpHeaders
        sidecarTask = Task { [weak self] in
            let cues: [SubtitleCue]
            do {
                cues = try await SubtitleDecoder.decodeFile(url: url, httpHeaders: effectiveHeaders)
            } catch {
                EngineLog.emit("[AetherEngine] sidecar decode failed: \(error)", category: .engine)
                await MainActor.run {
                    // Stale-task guard: a superseded sidecar load (A->B
                    // switch) must not clear the SUCCESSOR's loading
                    // spinner. isSubtitleActive alone doesn't cover this:
                    // it is true again for B by the time A's error lands.
                    guard !Task.isCancelled, let self = self else { return }
                    if self.isSubtitleActive {
                        self.isLoadingSubtitles = false
                    }
                }
                return
            }

            await MainActor.run {
                // Stale-task guard, mirroring the embedded path: without
                // it a superseded load A whose decode outlives the A->B
                // switch overwrites B's cues (isSubtitleActive is true
                // again for B, so that check alone can't catch it).
                guard !Task.isCancelled, let self = self else { return }
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
        // Unblock a side demuxer parked in a network read; cancel alone
        // is only observed between reads (see runEmbeddedSubtitleReader).
        activeSubtitleSideDemuxer?.markClosed()
        activeSubtitleSideDemuxer = nil
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
    private func stopInternal(resetDisplayCriteria: Bool = true, keepNativeHost: Bool = false, keepCustomReader: Bool = false) {
        // Invalidate any in-flight load(): its post-await checkpoints
        // compare against this counter and unwind when stale.
        loadGeneration &+= 1
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
        // Abort a probe blocked in open/find_stream_info (see
        // `inFlightProbeDemuxer`). Lock-free + idempotent; the owning
        // load() unwinds with openFailed and clears the reference.
        inFlightProbeDemuxer?.markClosed()
        liveTelemetrySampler?.stop()
        liveTelemetrySampler = nil
        diagnostics.liveTelemetry = nil
        nativeCancellables.removeAll()
        nativeHost?.tearDown()
        if !keepNativeHost {
            nativeHost = nil
            currentAVPlayer = nil
        }
        nativeVideoSession?.stop()
        nativeVideoSession = nil

        // Live scrub-thumbnail contexts die with the session.
        let liveThumbs = liveThumbnailExtractors
        liveThumbnailExtractors.removeAll()
        for entry in liveThumbs {
            Task { await entry.extractor.shutdown() }
        }

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

        // Close the custom source reader on final teardown (a real stop or a
        // new load). Internal reloads pass keepCustomReader: true so the
        // retained reader survives the intermediate teardown for reuse.
        if !keepCustomReader {
            customReader?.close()
            customReader = nil
            customFormatHint = nil
            customSourceIsSeekable = false
        }

        if resetDisplayCriteria {
            displayCriteria.reset()
        }
        playbackBackend = .none
        activeVideoDecoder = nil
        activeAudioDecoder = nil
        lastDetectedVideoCodec = AV_CODEC_ID_NONE
        playlistShiftSeconds = 0
        liveShiftSeams.removeAll()
        nativeClockSeconds = 0
        clock.sourceTime = 0

        liveWindowTimerTask?.cancel()
        liveWindowTimerTask = nil

        cancelSidecarTask()
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        // Unblock a side demuxer parked in a network read; cancel alone
        // is only observed between reads (see runEmbeddedSubtitleReader).
        activeSubtitleSideDemuxer?.markClosed()
        activeSubtitleSideDemuxer = nil
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
        liveWindow = nil
        clock.liveEdgeTime = 0
        clock.seekableLiveRange = nil
        clock.isAtLiveEdge = false
        clock.behindLiveSeconds = 0
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

    /// Apply a fresh `LiveTelemetry` snapshot to the `@Published` mirror
    /// on `diagnostics`. Kept as the single write-through point so the
    /// sampler does not reach into `EngineDiagnostics` directly.
    func applyLiveTelemetry(_ snapshot: LiveTelemetry) {
        diagnostics.liveTelemetry = snapshot
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

    /// Authoritative on-disk byte footprint of the loopback HLS segment
    /// cache (freshly stat-ed resident files), or `nil` when no native
    /// session is active. Public so the `aetherctl live --report-cache-
    /// bytes` harness can verify the live window keeps disk bounded.
    public var segmentCacheDiskBytes: Int64? {
        nativeVideoSession?.segmentCacheDiskBytes
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
                // The SW path must pause too: without this a SW session
                // kept demuxing/decoding/streaming until tvOS suspended
                // the process, while the published state already said
                // .paused.
                self.softwareHost?.pause()
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
