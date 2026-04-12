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

/// Thread-safe PTS-sorted queue for decoded video frames with semaphore-based
/// back-pressure. The decoder pushes frames from VideoToolbox's callback thread,
/// and the render loop pulls them on the display link thread.
///
/// Instead of busy-waiting when the queue is full, producers block on
/// `waitForSpace()` and are woken when a frame is consumed.
final class FrameQueue: @unchecked Sendable {
    private var frames: [VideoFrame] = []
    private let lock = NSLock()
    private let capacity: Int

    /// Signaled when a frame is consumed, allowing a blocked producer to proceed.
    private let spaceAvailable: DispatchSemaphore

    /// Signaled when the demux loop should wake up (play/resume/stop).
    let wakeUp = DispatchSemaphore(value: 0)

    init(capacity: Int = 8) {
        self.capacity = capacity
        self.spaceAvailable = DispatchSemaphore(value: capacity)
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
    /// Returns true if space is available, false on timeout.
    func waitForSpace(timeout: DispatchTime = .now() + .milliseconds(50)) -> Bool {
        if spaceAvailable.wait(timeout: timeout) == .success {
            return true
        }
        return false
    }

    /// Push a decoded frame. Maintains PTS-sorted order (binary search insert).
    /// Caller should have previously called `waitForSpace()`.
    func push(_ frame: VideoFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count < capacity else { return }
        let insertIdx = frames.firstIndex(where: { $0.pts > frame.pts }) ?? frames.endIndex
        frames.insert(frame, at: insertIdx)
    }

    /// Pull the next frame (earliest PTS). Returns nil if empty.
    /// Signals the space semaphore so a blocked producer can proceed.
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

    /// Remove all frames and reset the space semaphore.
    func flush() {
        lock.lock()
        let count = frames.count
        frames.removeAll()
        // Signal inside the lock to prevent race with pop() double-signaling
        for _ in 0..<count {
            spaceAvailable.signal()
        }
        lock.unlock()
        // Wake demux loop in case it's paused
        wakeUp.signal()
    }
}
