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
    ///
    /// On iOS 18 / tvOS 18 / macOS 15 Apple split the queue rendering
    /// surface off `AVSampleBufferDisplayLayer` onto a dedicated
    /// `AVSampleBufferVideoRenderer` accessible via
    /// `displayLayer.sampleBufferRenderer`. Direct `addRenderer(layer)`
    /// still type-checks (the layer still conforms to
    /// `AVQueuedSampleBufferRendering`), but on tvOS 26+ it's been
    /// observed to fail with `FigVideoQueueRemote err=-12080` after
    /// the first enqueue. Attaching the renderer instead of the layer
    /// resolves it.
    func attachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        } else {
            synchronizer.addRenderer(displayLayer)
        }
    }

    /// Remove the video display layer from the synchronizer and block
    /// until the removal actually completes. AVSampleBufferRenderSynchronizer
    /// does the detach asynchronously; if the caller immediately assigns
    /// `displayLayer.controlTimebase` for a new Atmos session the layer
    /// is briefly owned by both the synchronizer and a controlTimebase,
    /// which Apple documents as undefined behavior. Symptom: on the
    /// first PCM→Atmos switch after app launch, FigVideoQueueRemote
    /// throws err=-12080 the instant we assign the new timebase and
    /// the display layer stops rendering entirely (audio keeps going).
    ///
    /// A short semaphore wait on the calling thread is cheap (sub-100ms
    /// in practice) and makes the handoff deterministic.
    func detachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        let semaphore = DispatchSemaphore(value: 0)
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            synchronizer.removeRenderer(displayLayer.sampleBufferRenderer, at: synchronizer.currentTime()) { _ in
                semaphore.signal()
            }
        } else {
            synchronizer.removeRenderer(displayLayer, at: synchronizer.currentTime()) { _ in
                semaphore.signal()
            }
        }
        let result = semaphore.wait(timeout: .now() + .seconds(1))
        #if DEBUG
        if result == .timedOut {
            print("[AudioOutput] detachVideoLayer: timed out waiting for synchronizer removal")
        }
        #endif
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
    /// Always enqueues, the renderer buffers internally. Checking
    /// isReadyForMoreMediaData caused early samples to be dropped
    /// before the synchronizer started, resulting in silence.
    func enqueue(sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(sampleBuffer)

        #if DEBUG
        // Log exactly once per session: first successful enqueue and,
        // if the renderer rejected it, the error. Lets us distinguish
        // "no audio because nothing was enqueued" from "no audio
        // because the renderer rejected our format".
        if !_loggedFirstEnqueue {
            _loggedFirstEnqueue = true
            let fmt = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let sr = fmt.map { "\($0.mSampleRate)Hz" } ?? "?"
            let ch = fmt.map { "\($0.mChannelsPerFrame)ch" } ?? "?"
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            print("[AudioOutput] first enqueue: \(sr) \(ch), \(count) samples, renderer.error=\(String(describing: renderer.error))")
        } else if let err = renderer.error, !_loggedRendererError {
            _loggedRendererError = true
            print("[AudioOutput] renderer error: \(err)")
        }
        #endif
    }

    #if DEBUG
    private var _loggedFirstEnqueue = false
    private var _loggedRendererError = false
    #endif

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

    /// Flush the renderer queue without resetting `_isStarted` or
    /// stopping the synchronizer. Used when hot-swapping the audio
    /// decoder mid-playback (e.g. an audio-track switch with the
    /// same audio mode), the master clock keeps ticking, the video
    /// pipeline stays untouched, and only the queued audio samples
    /// from the old track are dropped so the new language is heard
    /// promptly. Without this, calling the regular flush would
    /// reset `_isStarted = false`, and the synchronizer would stop
    /// until a fresh `start(at:)` call jumped the clock, visually
    /// the same fast-forward burst the cross-mode reset path
    /// produces.
    func flushRendererKeepingClock() {
        lock.lock()
        defer { lock.unlock() }
        renderer.flush()
    }

    /// Stop and tear down.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        synchronizer.setRate(0.0, time: .zero)
        renderer.flush()
        _isStarted = false
    }

    /// Jump the synchronizer's master clock to a specific time and
    /// resume at the given rate atomically. Used by seek paths so PTS-
    /// stamped samples decoded after the seek align with the clock,
    /// without falling-through-time race windows that
    /// `pause → flush → setRate` would expose. Idempotent on
    /// `_isStarted` (post-seek the synchronizer is started by definition,
    /// so subsequent demux-loop `start(at:)` calls are no-ops).
    func seekClock(to time: CMTime, rate: Float) {
        lock.lock()
        defer { lock.unlock() }
        _rate = rate
        synchronizer.setRate(rate, time: time)
        _isStarted = true
    }
}
