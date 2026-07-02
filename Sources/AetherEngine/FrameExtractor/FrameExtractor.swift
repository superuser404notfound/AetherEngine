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
    /// #93 startup: session-coupled extractors yield elective thumbnail decodes while the
    /// playback pipeline is starved (see `shouldYield`). nil = never yield (standalone use).
    private let yieldWhile: (@Sendable () -> Bool)?

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

    private init(context: FrameDecodeContext, yieldWhile: (@Sendable () -> Bool)?) {
        self.context = context
        self.yieldWhile = yieldWhile
        self.cache = FrameCache(
            thumbnailLimit: 24,
            snapshotLimit: 2,
            thumbnailBucketSeconds: 1.0
        )
        // .utility (not .userInitiated): the disposable thumbnail decode must yield to
        // the real-time software playback decode under CPU contention so it cannot
        // starve playback on a weak box (issue #27).
        self.decodeQueue = DispatchQueue(label: "com.aetherengine.frameextractor", qos: .utility)
    }

    public init(url: URL, httpHeaders: [String: String] = [:],
                yieldWhile: (@Sendable () -> Bool)? = nil) {
        self.init(context: FrameDecodeContext(url: url, httpHeaders: httpHeaders),
                  yieldWhile: yieldWhile)
    }

    /// Construct over a custom `IOReader` source (a clone with its own cursor).
    /// The extractor owns the reader and closes it on teardown.
    public init(reader: IOReader, formatHint: String? = nil,
                yieldWhile: (@Sendable () -> Bool)? = nil) {
        self.init(context: FrameDecodeContext(reader: reader, formatHint: formatHint),
                  yieldWhile: yieldWhile)
    }

    /// Yield decision for elective (thumbnail) extraction. The disposable decode's demuxer pulls
    /// megabytes over the same link the segment producer needs; during startup and recovery that
    /// contention tipped the first segment past CoreMedia's ~4 s media timeout and killed the
    /// AVPlayer loader (-15628, #93 startup). Yield while a producer restart is in flight or the
    /// consumer's forward buffer has not stayed healthy long enough: a SINGLE 1 Hz tick above
    /// the floor (post-load seek shapes buffer spikes) let a 3.3 MB warm pull through the exact
    /// startup window that killed the loader, so the gate opens only after several consecutive
    /// healthy ticks. Unknown (nil) buffer resets the run, covering the cold startup window.
    public nonisolated static let yieldMinForwardBufferSeconds: Double = 3.0
    public nonisolated static let yieldHealthyTicksRequired = 3
    public nonisolated static func shouldYield(
        restartInFlight: Bool, consecutiveHealthyTicks: Int
    ) -> Bool {
        restartInFlight || consecutiveHealthyTicks < yieldHealthyTicksRequired
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
        // Elective thumbnails yield to a starved playback pipeline (snapshots are deliberate
        // one-shot user actions and stay ungated). Checked after the cache: hits are free.
        if mode == .thumbnail, yieldWhile?() == true {
            EngineLog.emit("[FrameExtractor] thumbnail yielded: playback pipeline starved",
                           category: .swPlayback, level: .verbose)
            return nil
        }
        currentToken?.cancel()
        let token = CancelToken()
        currentToken = token

        let context = self.context
        let result = await runOnQueue { () -> FrameResult in
            if token.isCancelled { return FrameResult(image: nil) }
            let start = DispatchTime.now()
            let wasOpen = context.isOpen
            let bytesBefore = context.bytesFetched
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
            // Per-miss cost line: correlates extraction bursts with playback stutter
            // (#93 post-recovery lag diagnosis). bytes = link bandwidth this miss consumed.
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            let bytes = context.bytesFetched - bytesBefore
            EngineLog.emit(
                "[FrameExtractor] miss mode=\(mode) t=\(String(format: "%.2f", seconds))s "
                + "took=\(String(format: "%.0f", ms))ms bytes=\(bytes) "
                + "reopened=\(wasOpen ? "n" : "y") image=\(image == nil ? "nil" : "ok") "
                + "cancelled=\(token.isCancelled ? "y" : "n")",
                category: .swPlayback, level: .verbose
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
