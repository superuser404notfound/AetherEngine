import Foundation
import CoreGraphics

/// Produces still images from a media URL via an isolated FFmpeg decode
/// context, strictly separate from playback. Two modes share one decode
/// core: `snapshot` (frame-accurate, full-res) and `thumbnail`
/// (keyframe-snapped, low-res, fast).
///
/// Lifecycle is lazy: the decode context opens on first use. Blocking
/// FFmpeg work runs on a dedicated serial queue, never on the
/// cooperative thread pool.
///
/// Create one per URL. For the currently-playing item, prefer
/// `AetherEngine.makeFrameExtractor()`.
public actor FrameExtractor {
    private let context: FrameDecodeContext
    private let cache: FrameCache
    private let decodeQueue: DispatchQueue

    /// Cancellation flag for the in-flight decode. A new request flips
    /// the previous token so a superseded scrub decode bails promptly.
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

    public init(url: URL, httpHeaders: [String: String] = [:]) {
        self.context = FrameDecodeContext(url: url, httpHeaders: httpHeaders)
        self.cache = FrameCache(
            thumbnailLimit: 24,
            snapshotLimit: 2,
            thumbnailBucketSeconds: 1.0
        )
        self.decodeQueue = DispatchQueue(label: "com.aetherengine.frameextractor", qos: .userInitiated)
    }

    // MARK: - Public API

    public func thumbnail(at seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        await produce(at: seconds, mode: .thumbnail, targetWidth: maxWidth, maxSize: nil)
    }

    public func snapshot(at seconds: Double, maxSize: CGSize? = nil) async -> CGImage? {
        // targetWidth is inert for snapshot; FrameDecodeContext.clampedWidth governs size.
        await produce(at: seconds, mode: .snapshot, targetWidth: 0, maxSize: maxSize)
    }

    /// Open the decode context ahead of the first request to hide
    /// cold-start latency (e.g. at the start of a scrub gesture).
    public func prewarm() async {
        guard !isShutDown else { return }
        let context = self.context
        await runOnQueue { try? context.ensureOpen() }
        scheduleIdleClose()
    }

    /// Permanently tear down the decode context and clear the cache.
    /// Awaits the teardown on the decode queue, so when this returns the
    /// FFmpeg demuxer / codec / sws resources are fully released. After
    /// `shutdown()` the extractor is dead: further `thumbnail` /
    /// `snapshot` / `prewarm` calls return nil / no-op and do NOT reopen
    /// the context. Create a new `FrameExtractor` to extract again.
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

    /// Run blocking work on the dedicated serial queue and await the
    /// result without blocking the actor's executor.
    private func runOnQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            decodeQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Restart the idle countdown. Called at the end of every request.
    /// After `idleInterval` with no further request, the decode context
    /// is closed and the cache cleared; the next request reopens lazily.
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

    /// Transient teardown after idle: closes the decode context and
    /// drops the cache. Distinct from `shutdown()`, this does NOT set
    /// `isShutDown`, so the next request lazily reopens.
    private func idleClose() {
        cache.clear()
        let context = self.context
        // Fire-and-forget: idle teardown is best-effort and no caller
        // awaits it. Using runOnQueue here (as shutdown does) would
        // block the actor for no benefit.
        decodeQueue.async { context.close() }
    }
}

/// Wrapper so a CGImage? can cross the `runOnQueue` Sendable boundary
/// without tripping Swift 6 concurrency checking. CGImage is immutable
/// and already passed across domains in this module (see SubtitleImage).
private struct FrameResult: @unchecked Sendable {
    let image: CGImage?
}
