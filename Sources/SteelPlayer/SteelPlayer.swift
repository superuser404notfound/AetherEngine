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
    @Published public private(set) var videoFormat: VideoFormat = .sdr

    // MARK: - Output

    /// The video layer to embed in the host view hierarchy.
    /// Uses AVSampleBufferDisplayLayer for optimal frame pacing.
    public var videoLayer: CALayer { videoRenderer.displayLayer }

    // MARK: - Internal Pipeline

    /// Pipeline components — accessed from both main actor and demux queue.
    /// Each has internal locking for thread safety.
    nonisolated(unsafe) private let demuxer = Demuxer()
    private let videoDecoder = VideoDecoder()
    nonisolated(unsafe) private let softwareDecoder = SoftwareVideoDecoder()
    private let audioDecoder = AudioDecoder()

    /// True if the current stream uses software decoding (FFmpeg) instead of VT.
    /// Set during load(), read during demux loop — effectively immutable during playback.
    nonisolated(unsafe) private var usingSoftwareDecode = false
    private let audioOutput = AudioOutput()
    nonisolated(unsafe) private let videoRenderer = SampleBufferRenderer()

    /// Serial queue for the demux→decode loop (runs off main thread).
    private let demuxQueue = DispatchQueue(label: "com.steelplayer.demux", qos: .userInitiated)

    /// Thread-safe playback control flags.
    /// Accessed from both main actor and demux queue — protected by flagsLock.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying = false
    nonisolated(unsafe) private var _stopRequested = false

    /// Whether the audio stream was successfully opened.
    private var audioAvailable = false

    /// Detected video frame rate.
    private var videoFrameRate: Double = 0

    /// Condition for waking the demux loop from pause.
    private let demuxCondition = NSCondition()

    nonisolated private var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock()
            _isPlaying = newValue
            flagsLock.unlock()
            if newValue { demuxCondition.broadcast() }
        }
    }
    nonisolated private var stopRequested: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _stopRequested }
        set {
            flagsLock.lock()
            _stopRequested = newValue
            flagsLock.unlock()
            if newValue { demuxCondition.broadcast() }
        }
    }

    // MARK: - Init

    /// Lifecycle notification observers — stored for cleanup.
    private var lifecycleObservers: [Any] = []

    public init() throws {
        // Configure audio session BEFORE creating renderers — the renderer
        // may lock its output configuration at creation time. Without this,
        // multichannel content is downmixed to stereo.
        #if os(iOS) || os(tvOS)
        do {
            let session = AVAudioSession.sharedInstance()
            if #available(tvOS 17.0, iOS 17.0, *) {
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            } else {
                try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            }
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
            #if DEBUG
            let route = session.currentRoute.outputs.map { "\($0.portName)(\($0.channels?.count ?? 0)ch)" }.joined(separator: ", ")
            print("[SteelPlayer] Audio session: multichannel=true, route=\(route)")
            #endif
        } catch {
            print("[SteelPlayer] AVAudioSession error: \(error)")
        }
        #endif

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
        videoFormat = .sdr
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

            // Detect video format (SDR/HDR10/DV/HLG) from codec parameters
            videoFormat = detectVideoFormat(stream: videoStream)

            // Detect video frame rate for display link matching.
            // Also used for AVDisplayCriteria to set correct refresh rate.
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

            // Audio session already configured in init() — no duplicate setup needed.

            // 4. Seek to start position if requested.
            // Pre-start the audio clock at the seek time so the synchronizer
            // doesn't reject video frames whose PTS is far ahead of time 0.
            // The demux loop's audioOutput.start() becomes a no-op since
            // _isStarted is already true.
            var initialAudioTime: CMTime = .zero
            if let start = startPosition, start > 0 {
                demuxer.seek(to: start)
                currentTime = start
                let seekTime = CMTimeMakeWithSeconds(start, preferredTimescale: 90000)
                videoRenderer.setSkipThreshold(seekTime)
                if usingSoftwareDecode {
                    softwareDecoder.skipUntilPTS = seekTime
                }
                initialAudioTime = seekTime
                // DON'T start audioOutput here — the clock would advance
                // while the demux loop hasn't produced any frames yet.
                // Instead, pass the time to the demux loop.
            }

            // 5. Start the demux→decode loop and time updates
            isPlaying = true
            state = .playing
            startTimeUpdates()
            startDemuxLoop(videoStreamIndex: videoIdx, audioStreamIndex: audioIdx, initialAudioTime: initialAudioTime)

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

        // Flush decoders FIRST — VTDecompressionSession's flush waits for
        // async frames which get delivered to the renderer. Then flush the
        // renderer to clear those stale frames. Wrong order causes a still
        // frame from the old position to remain on screen after seek.
        if usingSoftwareDecode {
            softwareDecoder.flush()
        } else {
            videoDecoder.flush()
        }
        videoRenderer.flush()
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
        if usingSoftwareDecode {
            softwareDecoder.skipUntilPTS = seekTime
        }

        // Restart the audio clock at the seek position. The synchronizer
        // must be running for AVSampleBufferDisplayLayer to present frames.
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
    /// Accessed from demux queue — protected by single-writer (main actor).
    nonisolated(unsafe) private var activeAudioStreamIndex: Int32 = -1

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

    /// Set playback volume (0.0 = mute, 1.0 = full).
    public var volume: Float {
        get { audioOutput.volume }
        set { audioOutput.volume = newValue }
    }

    /// Set playback speed (0.5–2.0). Audio pitch adjusts automatically.
    public func setRate(_ rate: Float) {
        audioOutput.setRate(rate)
    }

    // MARK: - Internal

    private func stopInternal() {
        stopRequested = true
        isPlaying = false
        stopTimeUpdates()
        audioOutput.stop()
        // Flush decoders before renderer — decoder flush waits for async
        // VT frames which would otherwise land on the already-flushed renderer.
        if usingSoftwareDecode {
            softwareDecoder.flush()
            softwareDecoder.close()
        } else {
            videoDecoder.flush()
            videoDecoder.close()
        }
        videoRenderer.flush()
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
    private func startDemuxLoop(videoStreamIndex: Int32, audioStreamIndex: Int32, initialAudioTime: CMTime = .zero) {
        let audioOutput = self.audioOutput
        let audioDecoder = self.audioDecoder
        let audioAvailable = self.audioAvailable
        nonisolated(unsafe) var audioStarted = false

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
                // Retry transient errors (network hiccups) up to 3 times
                // with exponential backoff before giving up.
                let packet: UnsafeMutablePointer<AVPacket>?
                var readError: Error?
                var retries = 0
                let maxRetries = 3
                while true {
                    do {
                        packet = try self.demuxer.readPacket()
                        readError = nil
                        break
                    } catch {
                        retries += 1
                        if retries >= maxRetries || self.stopRequested {
                            readError = error
                            packet = nil
                            break
                        }
                        #if DEBUG
                        print("[SteelPlayer] Read error (retry \(retries)/\(maxRetries)): \(error)")
                        #endif
                        Thread.sleep(forTimeInterval: Double(1 << retries) * 0.2)
                    }
                }
                if let readError {
                    print("[SteelPlayer] Demuxer read failed after \(retries) retries: \(readError)")
                    Task { @MainActor [weak self] in
                        self?.state = .error("Playback error: \(readError)")
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
                    // Start the synchronizer when first audio data arrives.
                    // Starting HERE (not in load) ensures the clock doesn't
                    // advance while the decoder is still producing the first
                    // frame — eliminates "fast forward" on initial start.
                    // Seek restarts the clock directly in seek().
                    if !audioStarted && !sampleBuffers.isEmpty {
                        audioOutput.start(at: initialAudioTime)
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

    // MARK: - Video Format Detection

    /// Detect HDR format from stream metadata.
    private func detectVideoFormat(stream: UnsafeMutablePointer<AVStream>) -> VideoFormat {
        guard let codecpar = stream.pointee.codecpar else { return .sdr }

        let codecId = codecpar.pointee.codec_id
        let colorTRC = codecpar.pointee.color_trc
        let colorPrimaries = codecpar.pointee.color_primaries

        // Check for Dolby Vision via codec parameters side data.
        // Only report .dolbyVision if the display actually supports it —
        // otherwise report .hdr10 (DV Profile 8 is HDR10-compatible).
        if codecId == AV_CODEC_ID_HEVC {
            let nbSideData = Int(codecpar.pointee.nb_coded_side_data)
            if let sideData = codecpar.pointee.coded_side_data {
                for i in 0..<nbSideData {
                    if sideData[i].type == AV_PKT_DATA_DOVI_CONF {
                        #if os(tvOS) || os(iOS)
                        if AVPlayer.availableHDRModes.contains(.dolbyVision) {
                            #if DEBUG
                            print("[SteelPlayer] DV stream → Dolby Vision (display supports DV)")
                            #endif
                            return .dolbyVision
                        }
                        #endif
                        #if DEBUG
                        print("[SteelPlayer] DV stream → HDR10 fallback")
                        #endif
                        return .hdr10
                    }
                }
            }
        }

        // HDR10: BT.2020 primaries + PQ transfer function
        if colorTRC == AVCOL_TRC_SMPTE2084 && colorPrimaries == AVCOL_PRI_BT2020 {
            return .hdr10
        }

        // HLG: BT.2020 primaries + HLG transfer function
        if colorTRC == AVCOL_TRC_ARIB_STD_B67 && colorPrimaries == AVCOL_PRI_BT2020 {
            return .hlg
        }

        return .sdr
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
