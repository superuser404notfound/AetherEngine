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

/// SteelPlayer — Open-source FFmpeg + VideoToolbox video player engine.
///
/// A cross-platform (iOS, tvOS, macOS) media player that handles
/// demuxing, hardware-accelerated decoding via VideoToolbox, and
/// audio/video output via Apple's AVSampleBuffer infrastructure.
/// No UIKit/AppKit dependency — the host app provides its own UI
/// and simply embeds the player's `videoLayer` in a view.
///
/// ## Architecture
///
/// ```
/// URL → AVIO (URLSession) → FFmpeg Demuxer → AVPackets
///   ├─ Video → VideoToolbox HW Decode → CVPixelBuffer → AVSampleBufferDisplayLayer
///   └─ Audio → FFmpeg SW Decode → CMSampleBuffer → AVSampleBufferAudioRenderer
///   └─ Both synced via AVSampleBufferRenderSynchronizer (master clock)
/// ```
///
/// ## Quick Start
///
/// ```swift
/// let player = try SteelPlayer()
/// myView.layer.addSublayer(player.videoLayer)
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

    /// The video layer to embed in the host view hierarchy.
    /// Uses AVSampleBufferDisplayLayer for optimal frame pacing.
    public var videoLayer: CALayer { videoRenderer.displayLayer }

    // MARK: - Internal Pipeline

    private let demuxer = Demuxer()
    private let videoDecoder = VideoDecoder()
    private let softwareDecoder = SoftwareVideoDecoder()
    private let audioDecoder = AudioDecoder()

    /// True if the current stream uses software decoding (FFmpeg) instead of VT.
    private var usingSoftwareDecode = false
    private let audioOutput = AudioOutput()
    private let videoRenderer = SampleBufferRenderer()

    /// Serial queue for the demux→decode loop (runs off main thread).
    private let demuxQueue = DispatchQueue(label: "com.steelplayer.demux", qos: .userInitiated)

    /// Thread-safe playback control flags.
    private let flagsLock = NSLock()
    private var _isPlaying = false
    private var _stopRequested = false

    /// Whether the audio stream was successfully opened.
    private var audioAvailable = false

    /// Detected video frame rate.
    private var videoFrameRate: Double = 0

    /// Condition for waking the demux loop from pause.
    private let demuxCondition = NSCondition()

    private var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock()
            _isPlaying = newValue
            flagsLock.unlock()
            if newValue { demuxCondition.broadcast() }
        }
    }
    private var stopRequested: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _stopRequested }
        set {
            flagsLock.lock()
            _stopRequested = newValue
            flagsLock.unlock()
            if newValue { demuxCondition.broadcast() }
        }
    }

    // MARK: - Init

    /// Initialize the player. Can fail if the Metal device or shader
    /// library is not available (shouldn't happen on real Apple hardware).
    /// Lifecycle notification observers — stored for cleanup.
    private var lifecycleObservers: [Any] = []

    public init() throws {
        // Add video display layer to the audio synchronizer so Apple
        // handles A/V sync and frame pacing automatically.
        audioOutput.addVideoRenderer(videoRenderer.displayLayer)
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

            let videoRenderer = self.videoRenderer
            let frameCallback: DecodedFrameHandler = { pixelBuffer, pts in
                videoRenderer.enqueue(pixelBuffer: pixelBuffer, pts: pts)
            }

            // Try VideoToolbox hardware decode first, fall back to FFmpeg
            // software decode for codecs without HW support (AV1 on A15, etc.)
            do {
                try videoDecoder.open(stream: videoStream, onFrame: frameCallback)
                usingSoftwareDecode = false
                #if DEBUG
                print("[SteelPlayer] Using VideoToolbox hardware decode")
                #endif
            } catch {
                #if DEBUG
                print("[SteelPlayer] VT failed: \(error) — trying software decode")
                #endif
                do {
                    try softwareDecoder.open(stream: videoStream, onFrame: frameCallback)
                    usingSoftwareDecode = true
                    #if DEBUG
                    print("[SteelPlayer] Using FFmpeg software decode")
                    #endif
                } catch {
                    #if DEBUG
                    print("[SteelPlayer] Software decode also failed: \(error)")
                    #endif
                    throw error
                }
            }

            // Detect video frame rate for display link matching
            let avgFR = videoStream.pointee.avg_frame_rate
            if avgFR.den > 0 && avgFR.num > 0 {
                videoFrameRate = Double(avgFR.num) / Double(avgFR.den)
            } else {
                let rFR = videoStream.pointee.r_frame_rate
                if rFR.den > 0 && rFR.num > 0 {
                    videoFrameRate = Double(rFR.num) / Double(rFR.den)
                }
            }
            #if DEBUG
            print("[SteelPlayer] Video frame rate: \(String(format: "%.3f", videoFrameRate)) fps")
            #endif

            // Populate track metadata from the demuxer
            audioTracks = demuxer.audioTrackInfos()
            subtitleTracks = demuxer.subtitleTrackInfos()

            // 2b. Find the audio stream and open the audio decoder
            let audioIdx = demuxer.audioStreamIndex
            activeAudioStreamIndex = audioIdx
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

            // 4. Seek to start position if requested.
            // Pre-start the audio clock at the seek time so the synchronizer
            // doesn't reject video frames whose PTS is far ahead of time 0.
            // The demux loop's audioOutput.start() becomes a no-op since
            // _isStarted is already true.
            if let start = startPosition, start > 0 {
                demuxer.seek(to: start)
                currentTime = start
                let seekTime = CMTimeMakeWithSeconds(start, preferredTimescale: 90000)
                audioOutput.start(at: seekTime)
            }

            // 5. Start the demux→decode loop and time updates
            isPlaying = true
            state = .playing
            startTimeUpdates()
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

        // Pause the demux loop so it stops calling readPacket().
        // The Demuxer's accessLock serializes seek vs. any in-flight read,
        // but pausing first avoids decoding stale packets after flush.
        isPlaying = false

        // Flush everything: display layer, decoders, audio renderer
        videoRenderer.flush()
        if usingSoftwareDecode {
            softwareDecoder.flush()
        } else {
            videoDecoder.flush()
        }
        audioDecoder.flush()
        audioOutput.flush()

        // Seek the demuxer — accessLock inside Demuxer ensures we wait
        // if a readPacket() call is still in-flight on the demux queue.
        demuxer.seek(to: target)
        currentTime = target

        // Drop decoded frames between the keyframe and the seek target
        // to prevent the visual "fast forward" effect.
        let seekTime = CMTimeMakeWithSeconds(target, preferredTimescale: 90000)
        videoRenderer.setSkipThreshold(seekTime)

        // Set the audio clock to the seek target (not .zero!)
        audioOutput.start(at: seekTime)

        // Resume playing from new position
        isPlaying = true
        state = .playing
    }

    public func stop() {
        stopInternal()
        state = .idle
        currentTime = 0
        progress = 0
    }

    /// The currently active audio stream index.
    private var activeAudioStreamIndex: Int32 = -1

    public func selectAudioTrack(index: Int) {
        let streamIndex = Int32(index)
        guard streamIndex != activeAudioStreamIndex,
              let stream = demuxer.stream(at: streamIndex) else { return }

        // Close old decoder, open new one on the selected stream
        audioDecoder.flush()
        audioDecoder.close()
        audioOutput.flush()

        do {
            try audioDecoder.open(stream: stream)
            activeAudioStreamIndex = streamIndex

            // Restart synchronizer at current position
            let seekTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 90000)
            audioOutput.start(at: seekTime)
        } catch {
            #if DEBUG
            print("[SteelPlayer] Audio track switch failed: \(error)")
            #endif
        }
    }

    public func selectSubtitleTrack(index: Int) {
        // TODO: Phase 6 — subtitle support
    }

    // MARK: - Internal

    private func stopInternal() {
        stopRequested = true
        isPlaying = false
        stopTimeUpdates()
        audioOutput.stop()
        videoRenderer.flush()
        if usingSoftwareDecode {
            softwareDecoder.flush()
            softwareDecoder.close()
        } else {
            videoDecoder.flush()
            videoDecoder.close()
        }
        audioDecoder.close()
        demuxer.close()
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
                // Wait if paused
                if !self.isPlaying {
                    self.demuxCondition.lock()
                    while !self.isPlaying && !self.stopRequested {
                        self.demuxCondition.wait(until: Date(timeIntervalSinceNow: 0.5))
                    }
                    self.demuxCondition.unlock()
                    continue
                }

                // Read the next packet from the container.
                // No back-pressure here — audio and subtitle packets must
                // flow freely. Video-only throttling happens below.
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
                    // EOF — flush decoder and drain reorder buffer
                    if self.usingSoftwareDecode {
                        self.softwareDecoder.flush()
                    } else {
                        self.videoDecoder.flush()
                    }
                    self.videoRenderer.drainReorderBuffer()
                    self.audioDecoder.flush()
                    Task { @MainActor [weak self] in
                        self?.state = .idle
                    }
                    break
                }

                let streamIdx = packet.pointee.stream_index

                if streamIdx == videoStreamIndex {
                    // Back-pressure: wait if display layer isn't ready
                    while !self.videoRenderer.displayLayer.isReadyForMoreMediaData && !self.stopRequested {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    if self.stopRequested { av_packet_free_safe(packet); break }

                    if self.usingSoftwareDecode {
                        self.softwareDecoder.decode(packet: packet)
                    } else {
                        self.videoDecoder.decode(packet: packet)
                    }
                } else if streamIdx == self.activeAudioStreamIndex && audioAvailable {
                    let sampleBuffers = audioDecoder.decode(packet: packet)
                    for sb in sampleBuffers {
                        audioOutput.enqueue(sampleBuffer: sb)
                    }
                    // Start the synchronizer once we have first audio data.
                    // AVSampleBufferDisplayLayer handles frame pacing — no
                    // need to wait for video buffer like with CADisplayLink.
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

    // MARK: - Playback Time Updates

    /// Periodically update currentTime/progress from the audio clock.
    private var timeUpdateTimer: Task<Void, Never>?

    private func startTimeUpdates() {
        timeUpdateTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self = self, !Task.isCancelled else { return }
                let t = self.audioOutput.currentTimeSeconds
                if t > 0 {
                    self.currentTime = t
                    if self.duration > 0 {
                        self.progress = Float(t / self.duration)
                    }
                }
            }
        }
    }

    private func stopTimeUpdates() {
        timeUpdateTimer?.cancel()
        timeUpdateTimer = nil
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
        }
        lifecycleObservers.append(bgObserver)

        // Handle memory pressure — flush texture cache and drop queued frames
        let memObserver = nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.videoRenderer.flush()
            #if DEBUG
            print("[SteelPlayer] Memory warning — flushed texture cache")
            #endif
        }
        lifecycleObservers.append(memObserver)
        #endif
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
