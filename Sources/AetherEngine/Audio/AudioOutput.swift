import Foundation
import AVFoundation
import CoreMedia

/// Audio output using AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer.
///
/// The synchronizer serves as the **master clock** for the entire player:
/// video frames check `synchronizer.currentTime()` to decide when to
/// present. Audio is enqueued ahead of time and the synchronizer drives
/// playback timing.
final class AudioOutput: @unchecked Sendable {

    let renderer: AVSampleBufferAudioRenderer
    let synchronizer: AVSampleBufferRenderSynchronizer

    private let lock = NSLock()
    private var _isStarted = false

    init() {
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)

        // Enable spatial audio for AirPods Pro/Max and HomePod.
        // The renderer spatializes multichannel content automatically
        // when the user has spatial audio enabled in system settings.
        renderer.allowedAudioSpatializationFormats = .multichannel
    }

    /// Add the video display layer to the synchronizer so Apple handles
    /// A/V sync and frame pacing automatically.
    func attachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        synchronizer.addRenderer(displayLayer)
    }

    /// Remove the video display layer from the synchronizer.
    /// Call when switching to AVPlayer audio engine (which manages its own timing).
    func detachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        synchronizer.removeRenderer(displayLayer, at: synchronizer.currentTime(), completionHandler: nil)
    }

    /// Start audio playback at the given time. Call after enqueueing first samples.
    func start(at time: CMTime = .zero) {
        lock.lock()
        defer { lock.unlock() }
        guard !_isStarted else { return }
        synchronizer.setRate(_rate, time: time)
        _isStarted = true
    }

    /// The current playback rate. Stored so resume() restores the correct speed.
    private var _rate: Float = 1.0

    /// Playback volume (0.0 = mute, 1.0 = full).
    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Set playback speed (0.5–2.0). Takes effect immediately.
    func setRate(_ rate: Float) {
        _rate = rate
        synchronizer.setRate(rate, time: synchronizer.currentTime())
    }

    /// Pause audio (and the master clock).
    func pause() {
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
    }

    /// Resume audio (and the master clock) at the current playback rate.
    func resume() {
        synchronizer.setRate(_rate, time: synchronizer.currentTime())
    }

    /// Enqueue a decoded audio CMSampleBuffer for playback.
    /// Always enqueues — the renderer buffers internally. Checking
    /// isReadyForMoreMediaData caused early samples to be dropped
    /// before the synchronizer started, resulting in silence.
    func enqueue(sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)
    }

    /// The current playback time according to the audio synchronizer.
    var currentTime: CMTime {
        synchronizer.currentTime()
    }

    /// Current playback time in seconds.
    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
    }

    /// Flush the audio renderer (call on seek).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        renderer.flush()
        _isStarted = false
    }

    /// Stop and tear down.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        synchronizer.setRate(0.0, time: .zero)
        renderer.flush()
        _isStarted = false
    }
}
