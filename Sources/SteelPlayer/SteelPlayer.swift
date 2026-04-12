import Foundation
import QuartzCore
import CoreMedia
import CoreVideo
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

#if canImport(UIKit)
import UIKit
#endif

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
    private let audioDecoder = AudioDecoder()
    private let audioOutput = AudioOutput()
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

    /// Thread-safe playback control flags.
    private let flagsLock = NSLock()
    private var _isPlaying = false
    private var _stopRequested = false

    /// Whether the audio stream was successfully opened.
    private var audioAvailable = false

    private var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock()
            _isPlaying = newValue
            flagsLock.unlock()
            // Wake up the demux loop if resuming
            if newValue { frameQueue.wakeUp.signal() }
        }
    }
    private var stopRequested: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _stopRequested }
        set {
            flagsLock.lock()
            _stopRequested = newValue
            flagsLock.unlock()
            // Wake up demux loop so it can exit
            if newValue { frameQueue.wakeUp.signal() }
        }
    }

    // MARK: - Init

    /// Initialize the player. Can fail if the Metal device or shader
    /// library is not available (shouldn't happen on real Apple hardware).
    /// Lifecycle notification observers — stored for cleanup.
    private var lifecycleObservers: [Any] = []

    public init() throws {
        self.renderer = try MetalRenderer()
        setupLifecycleObservers()
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
        audioAvailable = false
        stopRequested = false

        #if DEBUG
        print("[SteelPlayer] Loading: \(url.absoluteString)")
        #endif

        do {
            // 1. Open the container with FFmpeg
            try demuxer.open(url: url)
            duration = demuxer.duration

            // 2. Find the video stream and open the hardware decoder
            let videoIdx = demuxer.videoStreamIndex
            guard videoIdx >= 0, let videoStream = demuxer.stream(at: videoIdx) else {
                throw SteelPlayerError.noVideoStream
            }

            try videoDecoder.open(stream: videoStream) { [weak self] pixelBuffer, pts in
                guard let self = self else { return }
                let seconds = CMTimeGetSeconds(pts)
                let frame = VideoFrame(
                    pixelBuffer: pixelBuffer,
                    pts: seconds.isFinite ? seconds : 0
                )
                self.frameQueue.push(frame)
                #if DEBUG
                let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
                let w = CVPixelBufferGetWidth(pixelBuffer)
                let h = CVPixelBufferGetHeight(pixelBuffer)
                let planes = CVPixelBufferGetPlaneCount(pixelBuffer)
                if self.frameQueue.count <= 2 {
                    print("[VT] Frame decoded: \(w)x\(h), format=\(fmt), planes=\(planes), pts=\(String(format: "%.3f", frame.pts))s")
                }
                #endif
            }

            // 2b. Find the audio stream and open the audio decoder
            let audioIdx = demuxer.audioStreamIndex
            if audioIdx >= 0, let audioStream = demuxer.stream(at: audioIdx) {
                do {
                    try audioDecoder.open(stream: audioStream)
                    audioAvailable = true
                } catch {
                    print("[SteelPlayer] Audio decoder failed: \(error) — playback will be silent")
                }
            }

            // For video-only files (or failed audio), start the synchronizer
            // as a free-running clock so video frame sync still works.
            if !audioAvailable {
                audioOutput.start()
            }

            // 3. Activate AVAudioSession (required on tvOS/iOS for audio output)
            #if os(iOS) || os(tvOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
                try session.setActive(true)
            } catch {
                print("[SteelPlayer] AVAudioSession error: \(error)")
            }
            #endif

            // 4. Seek to start position if requested
            if let start = startPosition, start > 0 {
                demuxer.seek(to: start)
            }

            // 5. Start the display link (render loop)
            startDisplayLink()

            // 6. Start the demux→decode loop on a background thread
            isPlaying = true
            state = .playing
            startDemuxLoop(videoStreamIndex: videoIdx, audioStreamIndex: audioIdx)

            #if DEBUG
            print("[SteelPlayer] Playback started (duration=\(String(format: "%.1f", duration))s)")
            #endif
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
    }

    public func play() {
        guard state == .paused else { return }
        isPlaying = true
        audioOutput.resume()
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        isPlaying = false
        audioOutput.pause()
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
        let target = max(0, min(seconds, duration))
        state = .seeking

        // Flush everything: frame queue, decoders, audio renderer, texture cache
        frameQueue.flush()
        videoDecoder.flush()
        audioDecoder.flush()
        audioOutput.flush()
        renderer.flushTextureCache()

        // Seek the demuxer to the new position
        demuxer.seek(to: target)
        currentTime = target

        // Set the audio clock to the seek target (not .zero!)
        let seekTime = CMTimeMakeWithSeconds(target, preferredTimescale: 90000)
        audioOutput.start(at: seekTime)

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
        audioOutput.stop()
        videoDecoder.flush()
        videoDecoder.close()
        audioDecoder.close()
        demuxer.close()
        frameQueue.flush()
        audioAvailable = false

        // Remove lifecycle observers
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    // MARK: - Demux Loop

    /// Runs on `demuxQueue`. Reads packets from the demuxer and feeds
    /// them to the appropriate decoders. Uses semaphore-based back-pressure
    /// instead of busy-waiting.
    private func startDemuxLoop(videoStreamIndex: Int32, audioStreamIndex: Int32) {
        let audioOutput = self.audioOutput
        let audioDecoder = self.audioDecoder
        let audioAvailable = self.audioAvailable
        var audioStarted = false

        demuxQueue.async { [weak self] in
            guard let self = self else { return }

            while !self.stopRequested {
                // Wait if paused — blocks until wakeUp is signaled
                if !self.isPlaying {
                    _ = self.frameQueue.wakeUp.wait(timeout: .now() + .milliseconds(100))
                    continue
                }

                // Back-pressure: block until the frame queue has space
                if !self.frameQueue.waitForSpace(timeout: .now() + .milliseconds(50)) {
                    // Check stop/pause flags while waiting
                    continue
                }

                // Read the next packet from the container
                let packet: UnsafeMutablePointer<AVPacket>?
                do {
                    packet = try self.demuxer.readPacket()
                } catch {
                    print("[SteelPlayer] Demuxer read error: \(error)")
                    Task { @MainActor [weak self] in
                        self?.state = .error("Playback error: \(error)")
                    }
                    break
                }

                guard let packet = packet else {
                    // EOF — flush remaining frames
                    self.videoDecoder.flush()
                    self.audioDecoder.flush()
                    Task { @MainActor [weak self] in
                        self?.state = .idle
                    }
                    break
                }

                let streamIdx = packet.pointee.stream_index

                if streamIdx == videoStreamIndex {
                    self.videoDecoder.decode(packet: packet)
                } else if streamIdx == audioStreamIndex && audioAvailable {
                    let sampleBuffers = audioDecoder.decode(packet: packet)
                    for sb in sampleBuffers {
                        audioOutput.enqueue(sampleBuffer: sb)
                    }
                    // Start the synchronizer once we have first audio data.
                    // Called directly (not via Task/@MainActor) because
                    // setRate() is thread-safe and delaying causes drops.
                    if !audioStarted && !sampleBuffers.isEmpty {
                        audioOutput.start()
                        audioStarted = true
                    }
                }
                // TODO: Phase 6 — route subtitle packets

                av_packet_free_safe(packet)
            }
        }
    }

    // MARK: - Render Loop

    private func startDisplayLink() {
        let target = DisplayLinkTarget(renderer: renderer, frameQueue: frameQueue, audioOutput: audioOutput, player: self)
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

    // MARK: - App Lifecycle

    private func setupLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        let nc = NotificationCenter.default

        // Pause when entering background — Metal rendering is not allowed,
        // and VTDecompressionSession becomes invalid in background.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.state == .playing else { return }
            self.pause()
            #if DEBUG
            print("[SteelPlayer] Paused (entered background)")
            #endif
        }
        lifecycleObservers.append(bgObserver)

        // Handle memory pressure — flush texture cache and drop queued frames
        let memObserver = nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.renderer.flushTextureCache()
            #if DEBUG
            print("[SteelPlayer] Memory warning — flushed texture cache")
            #endif
        }
        lifecycleObservers.append(memObserver)
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
///
/// Implements A/V sync: peeks at the next video frame's PTS and compares
/// it to the audio synchronizer's current time. Renders only when the
/// frame is "due" (within tolerance). Drops late frames, waits for early ones.
private class DisplayLinkTarget {
    let renderer: MetalRenderer
    let frameQueue: FrameQueue
    let audioOutput: AudioOutput
    weak var player: SteelPlayer?

    /// Render a frame if it's within 20ms of the audio clock.
    private let earlyThreshold: Double = 0.020
    /// Drop a frame if it's more than 40ms behind the audio clock.
    private let lateThreshold: Double = 0.040

    init(renderer: MetalRenderer, frameQueue: FrameQueue, audioOutput: AudioOutput, player: SteelPlayer) {
        self.renderer = renderer
        self.frameQueue = frameQueue
        self.audioOutput = audioOutput
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
        let clockTime = audioOutput.currentTimeSeconds

        // If audio hasn't started yet (clock = 0), render the first
        // available frame so the user sees something immediately.
        if clockTime <= 0 {
            guard let frame = frameQueue.pop() else { return }
            renderer.render(pixelBuffer: frame.pixelBuffer)
            updatePlayer(pts: frame.pts)
            return
        }

        // A/V sync: drop frames that are too late, render when "on time"
        while let frame = frameQueue.peek() {
            let delta = frame.pts - clockTime

            if delta < -lateThreshold {
                // Frame is late — drop it and try the next one
                _ = frameQueue.pop()
                continue
            }

            if delta > earlyThreshold {
                // Frame is early — wait for the next display link tick
                break
            }

            // Frame is on time — render it
            let frame = frameQueue.pop()!
            renderer.render(pixelBuffer: frame.pixelBuffer)
            updatePlayer(pts: frame.pts)
            break
        }
    }

    private func updatePlayer(pts: Double) {
        Task { @MainActor [weak player] in
            player?.updateTime(pts: pts)
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
