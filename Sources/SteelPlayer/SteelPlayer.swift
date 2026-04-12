import Foundation
import QuartzCore

/// SteelPlayer — Open-source FFmpeg + Metal video player engine.
///
/// A cross-platform (iOS, tvOS, macOS) media player that handles
/// demuxing, hardware-accelerated decoding, Metal rendering with
/// HDR tone mapping, and audio output. No UIKit/AppKit dependency —
/// the host app provides its own UI and simply embeds the player's
/// `metalLayer` in a view.
///
/// ## Quick Start
///
/// ```swift
/// let player = SteelPlayer()
///
/// // Add player.metalLayer to your view hierarchy
/// myView.layer.addSublayer(player.metalLayer)
///
/// // Load and play
/// try await player.load(url: myVideoURL)
/// player.play()
/// ```
///
/// ## Features
///
/// - FFmpeg-based demuxing (all containers: MKV, MP4, AVI, TS, ...)
/// - VideoToolbox hardware decoding (H.264, HEVC, incl. Main10)
/// - FFmpeg software decoding fallback
/// - Metal rendering with BT.2390 HDR→SDR tone mapping
/// - HDR10, HDR10+, HLG, and Dolby Vision support
/// - AVSampleBufferAudioRenderer for audio output
/// - PTS-based A/V synchronization
/// - Subtitle support (SRT, SSA/ASS, PGS)
///
/// ## License
///
/// LGPL 3.0 — App Store compatible when dynamically linked.
@MainActor
public final class SteelPlayer: ObservableObject {

    // MARK: - Public State

    /// The current playback state.
    @Published public private(set) var state: PlaybackState = .idle

    /// Current playback position in seconds.
    @Published public private(set) var currentTime: Double = 0

    /// Total duration of the loaded media in seconds. Zero if unknown.
    @Published public private(set) var duration: Double = 0

    /// Playback progress as a fraction [0, 1].
    @Published public private(set) var progress: Float = 0

    /// Available audio tracks in the loaded media.
    @Published public private(set) var audioTracks: [TrackInfo] = []

    /// Available subtitle tracks in the loaded media.
    @Published public private(set) var subtitleTracks: [TrackInfo] = []

    // MARK: - Output

    /// The Metal layer the player renders video frames into. Add this
    /// to your view hierarchy (e.g. as a sublayer of a UIView's layer).
    /// The host view is responsible for setting the layer's `frame` and
    /// `drawableSize` (in pixels, not points).
    public let metalLayer: CAMetalLayer = {
        let layer = CAMetalLayer()
        layer.isOpaque = true
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        return layer
    }()

    // MARK: - Init

    public init() {
        // Metal device + pipeline will be set up lazily on first load
    }

    // MARK: - Public API

    /// Load a media file or stream URL. Replaces any current playback.
    /// - Parameters:
    ///   - url: Local file URL or HTTP(S) stream URL.
    ///   - startPosition: Optional start position in seconds.
    public func load(url: URL, startPosition: Double? = nil) async throws {
        state = .loading
        currentTime = 0
        duration = 0
        progress = 0
        audioTracks = []
        subtitleTracks = []

        // TODO: Phase 1 — Demuxer + Decoder + Renderer implementation
        fatalError("SteelPlayer.load() not yet implemented")
    }

    /// Start or resume playback.
    public func play() {
        guard state == .paused else { return }
        state = .playing
        // TODO: resume decode + render loop
    }

    /// Pause playback.
    public func pause() {
        guard state == .playing else { return }
        state = .paused
        // TODO: pause decode + render loop
    }

    /// Toggle between play and pause.
    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: play()
        default: break
        }
    }

    /// Seek to an absolute position in seconds.
    public func seek(to seconds: Double) async {
        // TODO: Phase 3 — seeking implementation
    }

    /// Stop playback and release resources.
    public func stop() {
        state = .idle
        currentTime = 0
        progress = 0
        // TODO: tear down pipeline
    }

    /// Select an audio track by its index in `audioTracks`.
    public func selectAudioTrack(index: Int) {
        // TODO: Phase 2 — audio track switching
    }

    /// Select a subtitle track by its index in `subtitleTracks`.
    /// Pass -1 to disable subtitles.
    public func selectSubtitleTrack(index: Int) {
        // TODO: Phase 6 — subtitle support
    }
}
