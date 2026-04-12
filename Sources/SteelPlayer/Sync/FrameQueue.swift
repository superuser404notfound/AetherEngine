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

/// Thread-safe FIFO queue for decoded video frames. The decoder pushes
/// frames from VideoToolbox's callback thread, and the render loop
/// pulls them on the display link thread.
final class FrameQueue: @unchecked Sendable {
    private var frames: [VideoFrame] = []
    private let lock = NSLock()
    private let capacity: Int

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

    /// Push a decoded frame. Drops the frame silently if the queue is full.
    /// Inserts in PTS-sorted order so pop/peek are O(1).
    func push(_ frame: VideoFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count < capacity else { return }
        // Binary search for insertion point to maintain PTS order.
        // Frames from VideoToolbox usually arrive in order, so the
        // common case is appending at the end (O(1) amortized).
        let insertIdx = frames.firstIndex(where: { $0.pts > frame.pts }) ?? frames.endIndex
        frames.insert(frame, at: insertIdx)
    }

    /// Pull the next frame (earliest PTS). Returns nil if empty.
    func pop() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
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
        defer { lock.unlock() }
        frames.removeAll()
    }
}
