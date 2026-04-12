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
    func push(_ frame: VideoFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count < capacity else { return }
        frames.append(frame)
    }

    /// Pull the next frame (lowest PTS). Returns nil if the queue is empty.
    func pop() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        // Pop the earliest frame by PTS
        let idx = frames.indices.min(by: { frames[$0].pts < frames[$1].pts }) ?? 0
        return frames.remove(at: idx)
    }

    /// Peek at the next frame without removing it.
    func peek() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.min(by: { $0.pts < $1.pts })
    }

    /// Remove all frames.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll()
    }
}
