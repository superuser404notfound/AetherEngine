import Foundation

/// One-shot "this serve is slow" timer for the segment serve path (issue #93, round 3).
///
/// Arms on init; if the serve is still running when `thresholdSeconds` elapses, `onSlow` fires
/// exactly once (the server uses it to emit an early chunked response header, keeping
/// time-to-first-byte under AVPlayer's ~3.5 s -12889 window). `complete()` is a barrier: after
/// it returns, the callback either ran to completion or will never run, so the caller can
/// safely read state the callback mutates.
final class SlowServeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var workItem: DispatchWorkItem?

    init(thresholdSeconds: TimeInterval, onSlow: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.completed else { return }
            // Invoked under the lock so complete() blocks until the callback finishes;
            // the callback is a small socket-header write, never long-running.
            onSlow()
        }
        workItem = item
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + thresholdSeconds, execute: item)
    }

    func complete() {
        lock.lock()
        completed = true
        lock.unlock()
        workItem?.cancel()
        workItem = nil
    }
}
