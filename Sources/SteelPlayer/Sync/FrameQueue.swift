import Foundation
import CoreMedia
import CoreVideo

/// A decoded video frame ready for rendering.
struct VideoFrame {
    /// The decoded pixel buffer (CVPixelBuffer from VideoToolbox).
    let pixelBuffer: CVPixelBuffer
    /// Presentation timestamp in seconds.
    let pts: Double
}

/// Thread-safe PTS-sorted queue for decoded video frames.
///
/// Uses a lock for thread-safe array access and a semaphore purely as
/// a wake-up signal (not for counting). The demux loop checks `hasSpace`
/// under the lock; if full, it blocks on the semaphore until `pop()`
/// signals that space freed up.
final class FrameQueue: @unchecked Sendable {
    private var frames: [VideoFrame] = []
    private let lock = NSLock()
    private let capacity: Int

    /// Signaled by pop() to wake a blocked waitForSpace() caller.
    /// Value starts at 0 — only used as a notification, not for counting.
    private let spaceAvailable = DispatchSemaphore(value: 0)

    /// Signaled when the demux loop should wake up (play/resume/stop).
    let wakeUp = DispatchSemaphore(value: 0)

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    /// Number of buffered frames.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    /// True if the queue has room for more frames.
    var hasSpace: Bool {
        lock.lock()
        defer { lock.unlock() }
        return frames.count < capacity
    }

    /// Block until there's space in the queue, or until the timeout expires.
    /// Checks the actual count under lock — the semaphore is only used as
    /// a wake-up signal, not for slot tracking.
    func waitForSpace(timeout: DispatchTime = .now() + .milliseconds(50)) -> Bool {
        lock.lock()
        if frames.count < capacity {
            lock.unlock()
            return true
        }
        lock.unlock()
        // Queue is full — wait for pop() to signal
        return spaceAvailable.wait(timeout: timeout) == .success
    }

    /// Push a decoded frame. Maintains PTS-sorted order.
    /// If the queue is full and the new frame has an earlier PTS than the
    /// latest queued frame, evict the latest to make room (B-frame reordering).
    /// This prevents HEVC B-frames from being silently dropped.
    func push(_ frame: VideoFrame) {
        lock.lock()
        defer { lock.unlock() }

        if frames.count >= capacity {
            // Queue is full. If new frame belongs BEFORE the latest frame
            // (B-frame with earlier PTS), evict the latest to make room.
            if let last = frames.last, frame.pts < last.pts {
                frames.removeLast()
            } else {
                // New frame is later than everything — drop it (it would
                // be at the end anyway, and the queue is full).
                return
            }
        }

        let insertIdx = frames.firstIndex(where: { $0.pts > frame.pts }) ?? frames.endIndex
        frames.insert(frame, at: insertIdx)
    }

    /// Pull the next frame (earliest PTS). Returns nil if empty.
    /// Signals spaceAvailable so a blocked waitForSpace() can proceed.
    func pop() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        spaceAvailable.signal()
        return frame
    }

    /// Peek at the next frame (earliest PTS) without removing it.
    func peek() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first
    }

    /// Remove all frames.
    func flush() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
        // Wake up blocked waitForSpace() and paused demux loop
        spaceAvailable.signal()
        wakeUp.signal()
    }
}
