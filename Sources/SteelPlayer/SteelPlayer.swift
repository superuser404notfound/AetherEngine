import Foundation
import QuartzCore
import CoreMedia
import CoreVideo
import Libavformat
import Libavcodec
import Libavutil

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
/// ## License
///
/// LGPL 3.0 — App Store compatible when dynamically linked.
@MainActor
public final class SteelPlayer: ObservableObject {

    // MARK: - Public State

    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var progress: Float = 0
    @Published public private(set) var audioTracks: [TrackInfo] = []
    @Published public private(set) var subtitleTracks: [TrackInfo] = []

    // MARK: - Output

    /// The Metal layer the player renders video frames into.
    public var metalLayer: CAMetalLayer { renderer.metalLayer }

    // MARK: - Internal Pipeline

    private let demuxer = Demuxer()
    private let videoDecoder = VideoDecoder()
    private let renderer: MetalRenderer
    private let frameQueue = FrameQueue(capacity: 8)

    /// Serial queue for the demux→decode loop (runs off main thread).
    private let demuxQueue = DispatchQueue(label: "com.steelplayer.demux", qos: .userInitiated)

    /// Display link drives the render loop synchronized to screen refresh.
    #if os(iOS) || os(tvOS) || os(visionOS)
    private var displayLink: CADisplayLink?
    #else
    private var displayTimer: Timer?
    #endif

    /// Controls whether the demux loop is actively reading packets.
    private var isPlaying = false

    /// Set to true to signal the demux loop to exit.
    private var stopRequested = false

    // MARK: - Init

    public init() {
        do {
            self.renderer = try MetalRenderer()
        } catch {
            fatalError("SteelPlayer: Metal initialization failed: \(error)")
        }
    }

    // MARK: - Public API

    /// Load a media file or stream URL. Replaces any current playback.
    public func load(url: URL, startPosition: Double? = nil) async throws {
        // Tear down any previous playback
        stopInternal()

        state = .loading
        currentTime = 0
        duration = 0
        progress = 0
        audioTracks = []
        subtitleTracks = []
        stopRequested = false

        #if DEBUG
        print("[SteelPlayer] Loading: \(url.absoluteString)")
        #endif

        // 1. Open the container with FFmpeg
        try demuxer.open(url: url)
        duration = demuxer.duration

        // 2. Find the video stream and open the hardware decoder
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let videoStream = demuxer.stream(at: videoIdx) else {
            throw SteelPlayerError.noVideoStream
        }

        try videoDecoder.open(stream: videoStream) { [weak self] pixelBuffer, pts in
            // This callback fires on VideoToolbox's internal thread
            guard let self = self else { return }
            let seconds = CMTimeGetSeconds(pts)
            let frame = VideoFrame(
                pixelBuffer: pixelBuffer,
                pts: seconds.isFinite ? seconds : 0
            )
            self.frameQueue.push(frame)
        }

        // 3. Seek to start position if requested
        if let start = startPosition, start > 0 {
            demuxer.seek(to: start)
        }

        // 4. Start the display link (render loop)
        startDisplayLink()

        // 5. Start the demux→decode loop on a background thread
        isPlaying = true
        state = .playing
        startDemuxLoop(videoStreamIndex: videoIdx)

        #if DEBUG
        print("[SteelPlayer] Playback started (duration=\(String(format: "%.1f", duration))s)")
        #endif
    }

    public func play() {
        guard state == .paused else { return }
        isPlaying = true
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        isPlaying = false
        state = .paused
    }

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: play()
        default: break
        }
    }

    public func seek(to seconds: Double) async {
        let target = max(0, seconds)
        state = .seeking

        // Flush the frame queue + decoder, then seek the demuxer
        frameQueue.flush()
        videoDecoder.flush()
        demuxer.seek(to: target)
        currentTime = target

        // Resume playing
        isPlaying = true
        state = .playing
    }

    public func stop() {
        stopInternal()
        state = .idle
        currentTime = 0
        progress = 0
    }

    public func selectAudioTrack(index: Int) {
        // TODO: Phase 2 — audio track switching
    }

    public func selectSubtitleTrack(index: Int) {
        // TODO: Phase 6 — subtitle support
    }

    // MARK: - Internal

    /// Called from the display link target to update playback position.
    fileprivate func updateTime(pts: Double) {
        currentTime = pts
        if duration > 0 {
            progress = Float(pts / duration)
        }
    }

    private func stopInternal() {
        stopRequested = true
        isPlaying = false
        stopDisplayLink()
        videoDecoder.flush()
        videoDecoder.close()
        demuxer.close()
        frameQueue.flush()
    }

    // MARK: - Demux Loop

    /// Runs on `demuxQueue`. Reads packets from the demuxer and feeds
    /// them to the video decoder. The decoder's callback pushes decoded
    /// frames into the frame queue. Audio packets are ignored for now
    /// (Phase 2).
    private func startDemuxLoop(videoStreamIndex: Int32) {
        demuxQueue.async { [weak self] in
            guard let self = self else { return }

            while !self.stopRequested {
                // Wait if paused
                if !self.isPlaying {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }

                // Back-pressure: wait if the frame queue is full
                if !self.frameQueue.hasSpace {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }

                // Read the next packet from the container
                guard let packet = self.demuxer.readPacket() else {
                    // EOF — signal the decoder to flush remaining frames
                    self.videoDecoder.flush()
                    DispatchQueue.main.async {
                        self.state = .idle
                    }
                    break
                }

                // Route the packet to the right decoder
                if packet.pointee.stream_index == videoStreamIndex {
                    self.videoDecoder.decode(packet: packet)
                }
                // TODO: Phase 2 — route audio packets to AudioDecoder
                // TODO: Phase 6 — route subtitle packets

                // Free the packet
                av_packet_free_safe(packet)
            }
        }
    }

    // MARK: - Render Loop

    private func startDisplayLink() {
        let target = DisplayLinkTarget(renderer: renderer, frameQueue: frameQueue, player: self)
        #if os(iOS) || os(tvOS) || os(visionOS)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #else
        // macOS fallback: Timer at ~60 Hz
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            target.tick()
        }
        #endif
    }

    private func stopDisplayLink() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        displayLink?.invalidate()
        displayLink = nil
        #else
        displayTimer?.invalidate()
        displayTimer = nil
        #endif
    }
}

// MARK: - Display Link Target

/// Separate target class to avoid retain cycles between CADisplayLink
/// and SteelPlayer. CADisplayLink retains its target strongly.
private class DisplayLinkTarget {
    let renderer: MetalRenderer
    let frameQueue: FrameQueue
    weak var player: SteelPlayer?

    init(renderer: MetalRenderer, frameQueue: FrameQueue, player: SteelPlayer) {
        self.renderer = renderer
        self.frameQueue = frameQueue
        self.player = player
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc func tick(_ link: CADisplayLink) {
        renderNextFrame()
    }
    #endif

    func tick() {
        renderNextFrame()
    }

    private func renderNextFrame() {
        guard let frame = frameQueue.pop() else { return }
        renderer.render(pixelBuffer: frame.pixelBuffer)

        Task { @MainActor [weak player] in
            player?.updateTime(pts: frame.pts)
        }
    }
}

// MARK: - Helpers

/// Safe wrapper around av_packet_free that handles the double-pointer.
private func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = packet
    av_packet_free(&p)
}

// MARK: - Errors

public enum SteelPlayerError: Error {
    case noVideoStream
    case noAudioStream
}
