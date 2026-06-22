import Foundation
import CoreGraphics

/// Produces still images from a media URL via an isolated FFmpeg decode context,
/// separate from playback. Two modes share one decode core: `snapshot` (frame-accurate,
/// full-res) and `thumbnail` (keyframe-snapped, low-res, fast). Lazy: context opens on
/// first use; blocking FFmpeg work runs on a dedicated serial queue, not the cooperative pool.
/// Create one per URL; for the playing item prefer `AetherEngine.makeFrameExtractor()`.
public actor FrameExtractor {
    private let context: FrameDecodeContext
    private let cache: FrameCache
    private let decodeQueue: DispatchQueue

    /// Cancellation flag for the in-flight decode; a new request flips the previous
    /// token so a superseded scrub decode bails promptly.
    private final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    }
    private var currentToken: CancelToken?

    /// Set by `shutdown()`. Once true, the extractor refuses further
    /// work instead of lazily reopening a closed context.
    private var isShutDown = false

    private let idleInterval: Duration = .seconds(10)
    private var idleTask: Task<Void, Never>?

    private init(context: FrameDecodeContext) {
        self.context = context
        self.cache = FrameCache(
            thumbnailLimit: 24,
            snapshotLimit: 2,
            thumbnailBucketSeconds: 1.0
        )
        self.decodeQueue = DispatchQueue(label: "com.aetherengine.frameextractor", qos: .userInitiated)
    }

    public init(url: URL, httpHeaders: [String: String] = [:]) {
        self.init(context: FrameDecodeContext(url: url, httpHeaders: httpHeaders))
    }

    /// Construct over a custom `IOReader` source (a clone with its own cursor).
    /// The extractor owns the reader and closes it on teardown.
    public init(reader: IOReader, formatHint: String? = nil) {
        self.init(context: FrameDecodeContext(reader: reader, formatHint: formatHint))
    }

    // MARK: - Public API

    public func thumbnail(at seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        await produce(at: seconds, mode: .thumbnail, targetWidth: maxWidth, maxSize: nil)
    }

    public func snapshot(at seconds: Double, maxSize: CGSize? = nil) async -> CGImage? {
        // targetWidth is inert for snapshot; FrameDecodeContext.clampedWidth governs size.
        await produce(at: seconds, mode: .snapshot, targetWidth: 0, maxSize: maxSize)
    }

    /// Open the decode context ahead of the first request to hide cold-start latency
    /// (e.g. at the start of a scrub gesture).
    public func prewarm() async {
        guard !isShutDown else { return }
        let context = self.context
        await runOnQueue { try? context.ensureOpen() }
        scheduleIdleClose()
    }

    /// Permanently tear down the decode context and clear the cache. Awaits teardown on
    /// the decode queue, so on return the FFmpeg demuxer/codec/sws are fully released.
    /// After shutdown() the extractor is dead: thumbnail/snapshot/prewarm return nil/no-op
    /// and do NOT reopen; create a new FrameExtractor to extract again.
    public func shutdown() async {
        idleTask?.cancel()
        isShutDown = true
        currentToken?.cancel()
        cache.clear()
        let context = self.context
        await runOnQueue { context.close() }
    }

    // MARK: - Core

    private func produce(at seconds: Double, mode: FrameMode, targetWidth: Int, maxSize: CGSize?) async -> CGImage? {
        guard !isShutDown else { return nil }
        if let hit = cache.get(mode: mode, seconds: seconds) {
            scheduleIdleClose()
            return hit
        }
        currentToken?.cancel()
        let token = CancelToken()
        currentToken = token

        let context = self.context
        let result = await runOnQueue { () -> FrameResult in
            if token.isCancelled { return FrameResult(image: nil) }
            do {
                try context.ensureOpen()
            } catch {
                EngineLog.emit("[FrameExtractor] open failed: \(error)", category: .swPlayback)
                return FrameResult(image: nil)
            }
            let image = context.decodeFrame(
                at: seconds, mode: mode,
                targetWidth: targetWidth, maxSize: maxSize,
                isCancelled: { token.isCancelled }
            )
            return FrameResult(image: image)
        }
        if let image = result.image, !token.isCancelled {
            cache.set(image, mode: mode, seconds: seconds)
        }
        scheduleIdleClose()
        return result.image
    }

    /// Run blocking work on the serial queue, awaiting the result without blocking the actor's executor.
    private func runOnQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            decodeQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Restart the idle countdown (called after every request). After `idleInterval`
    /// idle the context closes and cache clears; the next request reopens lazily.
    private func scheduleIdleClose() {
        idleTask?.cancel()
        idleTask = Task { [weak self, idleInterval] in
            do {
                try await Task.sleep(for: idleInterval)
                await self?.idleClose()
            } catch {
                // Cancelled before the interval elapsed: nothing to do.
            }
        }
    }

    /// Transient teardown after idle: closes the context and drops the cache. Unlike
    /// shutdown() this does NOT set `isShutDown`, so the next request lazily reopens.
    private func idleClose() {
        cache.clear()
        let context = self.context
        // Fire-and-forget: best-effort, no caller awaits it; runOnQueue would block the actor for nothing.
        decodeQueue.async { context.close() }
    }
}

/// Wrapper so CGImage? crosses the `runOnQueue` Sendable boundary under Swift 6.
/// CGImage is immutable and already passed across domains here (see SubtitleImage).
private struct FrameResult: @unchecked Sendable {
    let image: CGImage?
}
