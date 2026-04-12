import Foundation
import AVFoundation
import CoreMedia

/// Audio output using AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer.
///
/// The synchronizer serves as the **master clock** for the entire player:
/// video frames check `synchronizer.currentTime()` to decide when to
/// present. Audio is enqueued ahead of time and the synchronizer drives
/// playback timing.
final class AudioOutput {

    let renderer: AVSampleBufferAudioRenderer
    let synchronizer: AVSampleBufferRenderSynchronizer

    private var isStarted = false

    init() {
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)

        #if DEBUG
        print("[AudioOutput] Initialized")
        #endif
    }

    /// Start audio playback. Call after enqueueing the first audio samples.
    func start() {
        guard !isStarted else { return }
        synchronizer.setRate(1.0, time: .zero)
        isStarted = true
    }

    /// Pause audio (and the master clock).
    func pause() {
        synchronizer.setRate(0.0, time: synchronizer.currentTime())
    }

    /// Resume audio (and the master clock).
    func resume() {
        synchronizer.setRate(1.0, time: synchronizer.currentTime())
    }

    /// Enqueue a decoded audio CMSampleBuffer for playback.
    func enqueue(sampleBuffer: CMSampleBuffer) {
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        }
    }

    /// The current playback time according to the audio synchronizer.
    /// This is the **master clock** — video frames should be rendered
    /// when their PTS matches this value.
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
        renderer.flush()
        isStarted = false
    }

    /// Stop and tear down.
    func stop() {
        synchronizer.setRate(0.0, time: .zero)
        renderer.flush()
        isStarted = false
    }
}
