import Foundation

/// One-shot "this serve is slow" timer for the segment serve path (issue #93, round 3).
///
/// Arms on init; if the serve is still running when `thresholdSeconds` elapses, `onSlow` fires
/// exactly once (the server uses it to emit an early chunked response header, keeping
/// time-to-first-byte under AVPlayer's ~3.5 s -12889 window). `complete()` is a barrier: after
/// it returns, the callback either ran to completion or will never run, so the caller can
/// safely read state the callback mutates.
///
/// The timer runs on a dedicated `DispatchSourceTimer`, not `DispatchQueue.global().asyncAfter`.
/// A slow serve is exactly when the global concurrent pool is busiest, and a global-queue work
/// item cannot fire until the pool hands it a thread; under saturation that can be many seconds
/// late (observed on a loaded CI runner: a `userInitiated` `asyncAfter` did not fire within 15 s),
/// which would blow the whole point of the early header. A private-queue source brings up its own
/// thread and fires on schedule regardless of global-pool pressure.
final class SlowServeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let queue = DispatchQueue(label: "aether.slowserve.timer", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(thresholdSeconds: TimeInterval, onSlow: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + thresholdSeconds, repeating: .never, leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.completed else { return }
            // Invoked under the lock so complete() blocks until the callback finishes;
            // the callback is a small socket-header write, never long-running.
            onSlow()
            // One-shot: drop the source after firing so it can never fire twice.
            self.timer?.cancel()
            self.timer = nil
        }
        timer = source
        source.resume()
    }

    func complete() {
        lock.lock()
        completed = true
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    deinit {
        // Safety net if complete() was never called: a resumed, uncancelled source is safe to
        // release, but cancel first so its handler cannot run against a torn-down instance.
        timer?.cancel()
    }
}
