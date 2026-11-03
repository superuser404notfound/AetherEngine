import Foundation
import CoreGraphics

/// A bounded one-shot still. nil PTS means the source supplied no timestamp;
/// callers must label the requested time rather than claim a measured one.
// CGImage is immutable; all other stored properties are immutable Sendable values.
public struct BoundedStillFrame: @unchecked Sendable {
    public let image: CGImage
    public let actualSeconds: Double?
    public init(image: CGImage, actualSeconds: Double?) {
        self.image = image; self.actualSeconds = actualSeconds
    }
}

/// Produces still images from a media URL via an isolated FFmpeg decode context,
/// separate from playback. Three modes share one decode core: `snapshot` (frame-accurate,
/// full-res), `preview` (frame-accurate, downscaled) and `thumbnail` (keyframe-snapped, fast). Lazy: context opens on
/// first use; blocking FFmpeg work runs on a dedicated serial queue, not the cooperative pool.
/// Create one per URL; for the playing item prefer `AetherEngine.makeFrameExtractor()`.
public actor FrameExtractor {
    private let context: FrameDecodeContext
    private let cache: FrameCache
    private let decodeQueue: DispatchQueue
    /// #93 startup: session-coupled extractors yield elective thumbnail/preview decodes while the
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
    private var boundedCancellation: ProbeCancellation?

    /// Set by `shutdown()`. Once true, the extractor refuses further
    /// work instead of lazily reopening a closed context.
    private var isShutDown = false

    private var idleInterval: Duration = .seconds(10)
    private var idleTask: Task<Void, Never>?
    private var residentApproximation: (width: Int, frame: ScrubFrame)?
    nonisolated let residentIdentity: String?
    func clearResidentPreviewCache() {
        currentToken?.cancel()
        residentApproximation = nil
    }

    /// Only used with a one-segment DataIOReader. No URL or provider fallback.
    /// Refined results bypass the rendered-frame cache so they carry the actual decoded PTS.
    func residentPreview(rawTarget: Double, refined: Bool, maxWidth: Int,
                                isCancelled: @escaping @Sendable () -> Bool) async -> ScrubFrame? {
        guard !isShutDown, rawTarget.isFinite,
              !Task.isCancelled, !isCancelled() else { return nil }
        guard maxWidth > 0 else { return nil }
        // A cached approximation is still the latest scrub intent; retire an older refinement
        // before returning it, using the same cross-mode ownership rule as ordinary stills.
        currentToken?.cancel()
        boundedCancellation?.cancel()
        let token = CancelToken(); currentToken = token
        defer {
            if !isShutDown, currentToken === token { scheduleIdleClose() }
        }
        let width = maxWidth
        if !refined, let cached = residentApproximation, cached.width == width {
            return cached.frame
        }
        let context = self.context
        let result: ScrubFrame? = await withTaskCancellationHandler {
            await runOnQueue {
                guard !token.isCancelled, !isCancelled() else { return nil }
                do { try context.ensureOpen() } catch { return nil }
                var actual: Double?
                var didRefine = false
                let image = context.decodeFrame(at: 0, mode: refined ? .snapshot : .thumbnail,
                    targetWidth: width, maxSize: CGSize(width: CGFloat(width), height: CGFloat(width)),
                    isCancelled: { token.isCancelled || isCancelled() }, residentTarget: rawTarget,
                    reportResidentTime: { actual = $0; didRefine = $1 })
                guard let image, let actual, !token.isCancelled, !isCancelled() else { return nil }
                return ScrubFrame(image: image, actualSeconds: actual, refined: didRefine)
            }
        } onCancel: { token.cancel() }
        guard !Task.isCancelled, !isCancelled(), !token.isCancelled else { return nil }
        if !refined, let result, result.image.bytesPerRow * result.image.height <= 512 * 1_024 {
            residentApproximation = (width, result)
        }
        return result
    }

    private init(context: FrameDecodeContext, yieldWhile: (@Sendable () -> Bool)?, residentIdentity: String? = nil) {
        self.context = context
        self.residentIdentity = residentIdentity
        self.yieldWhile = yieldWhile
        self.cache = FrameCache(
            thumbnailLimit: 24,
            snapshotLimit: 2,
            thumbnailBucketSeconds: 1.0
        )
        // Still extraction is elective work and must yield to playback under CPU contention.
        self.decodeQueue = DispatchQueue(label: "com.aetherengine.frameextractor", qos: .utility)
    }

    /// `selectTitleID` picks the disc title for a Blu-ray / DVD ISO URL (nil = main title); it lets a
    /// still follow the currently-selected title instead of always the default one (AE#105). Inert for
    /// non-disc URLs.
    public init(url: URL, httpHeaders: [String: String] = [:],
                selectTitleID: Int? = nil,
                yieldWhile: (@Sendable () -> Bool)? = nil) {
        self.init(context: FrameDecodeContext(url: url, httpHeaders: httpHeaders, selectTitleID: selectTitleID),
                  yieldWhile: yieldWhile)
    }

    /// AE#792: an extractor over the session's own source, whose requests follow
    /// `updateRequestHeaders(_:)` like the session's other readers.
    init(url: URL, requestHeaderStore: RequestHeaderStore, selectTitleID: Int?,
         yieldWhile: (@Sendable () -> Bool)?) {
        self.init(context: FrameDecodeContext(url: url, httpHeaders: requestHeaderStore.current,
                                              selectTitleID: selectTitleID,
                                              requestHeaderStore: requestHeaderStore),
                  yieldWhile: yieldWhile)
    }

    /// Construct over a custom `IOReader` source (a clone with its own cursor).
    /// The extractor owns the reader and closes it on teardown.
    public init(reader: IOReader, formatHint: String? = nil,
                yieldWhile: (@Sendable () -> Bool)? = nil) {
        self.init(context: FrameDecodeContext(reader: reader, formatHint: formatHint),
                  yieldWhile: yieldWhile)
    }

    init(residentReader: IOReader, formatHint: String, identity: String,
         residentBudget: Duration = .milliseconds(750)) {
        self.init(context: FrameDecodeContext(reader: residentReader, formatHint: formatHint,
                                              residentBudget: residentBudget),
                  yieldWhile: nil, residentIdentity: identity)
    }

    /// Yield decision for elective thumbnail/preview extraction. The disposable decode's demuxer pulls
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

    /// Produce a frame-accurate, downscaled still for interactive scrubbing.
    /// Like thumbnails, uncached previews yield while the playback pipeline is starved.
    public func preview(at seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        await produce(at: seconds, mode: .preview, targetWidth: maxWidth, maxSize: nil)
    }

    public func snapshot(at seconds: Double, maxSize: CGSize? = nil) async -> CGImage? {
        // targetWidth is inert for snapshot; FrameDecodeContext.clampedWidth governs size.
        await produce(at: seconds, mode: .snapshot, targetWidth: 0, maxSize: maxSize)
    }

    /// AE#711 follow-up: the frame `offset` seconds after the first one this source decodes, for a
    /// one-segment cache source whose timestamps may sit on either axis. Frame-accurate like
    /// `snapshot`, uncached (the cache keys on stream time), and with the same Dolby Vision and HDR
    /// conversion as every still.
    func snapshot(afterFirstFrameBy offset: Double, maxSize: CGSize? = nil) async -> CGImage? {
        guard !isShutDown, offset.isFinite else { return nil }
        let context = self.context
        let image = await runOnQueue { () -> CGImage? in
            do { try context.ensureOpen() } catch {
                EngineLog.emit("[FrameExtractor] open failed: \(error)", category: .swPlayback)
                return nil
            }
            return context.decodeFrame(at: 0, mode: .snapshot, targetWidth: 0, maxSize: maxSize,
                                       afterFirstFrame: offset, isCancelled: { false })
        }
        scheduleIdleClose()
        return image
    }

    /// A still for a scrub preview over a local file, with the contract of `scrubPreviewFrame`: the
    /// caller's `isCancelled` is polled through the decode, the decode stops at the same 750 ms /
    /// 900 packet bound a resident one does, and the time of the frame actually decoded comes back
    /// (nil when the source stamps none) so the caller can label the picture rather than the request.
    /// Uncached, because a cache hit would not carry that time. `refined` decodes to the target;
    /// otherwise the first frame after the seek is returned, at `maxWidth`.
    func boundedLocalStill(at seconds: Double, refined: Bool, maxWidth: Int,
                           isCancelled: @escaping @Sendable () -> Bool) async -> (image: CGImage, decodedSeconds: Double?)? {
        guard !isShutDown, seconds.isFinite, seconds >= 0 else { return nil }
        currentToken?.cancel()
        let token = CancelToken()
        currentToken = token
        let context = self.context
        let mode: FrameMode = refined ? .snapshot : .thumbnail
        let size = CGSize(width: maxWidth, height: maxWidth)
        let result = await runOnQueue { () -> (image: CGImage, decodedSeconds: Double?)? in
            if token.isCancelled || isCancelled() { return nil }
            do { try context.ensureOpen() } catch {
                EngineLog.emit("[FrameExtractor] open failed: \(error)", category: .swPlayback)
                return nil
            }
            var decoded: Double?
            guard let image = context.decodeFrame(
                at: seconds, mode: mode, targetWidth: maxWidth, maxSize: refined ? size : nil,
                isCancelled: { token.isCancelled || isCancelled() },
                reportDecodedTime: { decoded = $0 }, bounded: true),
                !token.isCancelled, !isCancelled() else { return nil }
            return (image, decoded)
        }
        scheduleIdleClose()
        return result
    }

    /// Disposable source-backed preview with one budget spanning open, stream
    /// analysis, seek and decode. The controlled reader counts every input byte,
    /// the monotonic deadline interrupts I/O, and a late result is discarded.
    /// Unlike snapshot(), this never uses a previously opened or cached context.
    public func boundedSnapshot(at seconds: Double, maxSize: CGSize,
                                limits: ProbeLimits, cancellation: ProbeCancellation) async -> BoundedStillFrame? {
        guard !isShutDown, seconds.isFinite, !Task.isCancelled, !cancellation.isCancelled,
              let control = try? ProbeControl(limits: limits, cancellation: cancellation) else { return nil }
        currentToken?.cancel()
        boundedCancellation?.cancel()
        boundedCancellation = cancellation
        let token = CancelToken(); currentToken = token
        let context = self.context
        let result = await withTaskCancellationHandler {
            await runOnQueue { () -> BoundedStillFrame? in
                // A previously opened demuxer was outside this budget. Reject
                // it instead of letting its teardown extend this one-shot work.
                guard !context.isOpen else { control.finish(); return nil }
                defer { context.close(); control.finish() }
                guard !token.isCancelled, !cancellation.isCancelled else { return nil }
                do { try context.ensureOpen(control: control) } catch { return nil }
                var actual: Double?
                guard let image = context.decodeFrame(at: seconds, mode: .snapshot,
                    targetWidth: 0, maxSize: maxSize,
                    isCancelled: { token.isCancelled || cancellation.isCancelled || control.isStopped },
                    reportDecodedTime: { actual = $0 }),
                    !token.isCancelled, !cancellation.isCancelled else { return nil }
                do { try control.complete() } catch { return nil }
                return BoundedStillFrame(image: image, actualSeconds: actual)
            }
        } onCancel: {
            token.cancel()
            cancellation.cancel()
        }
        if boundedCancellation === cancellation { boundedCancellation = nil }
        return !Task.isCancelled && !cancellation.isCancelled && !token.isCancelled ? result : nil
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
    /// After shutdown() the extractor is dead: thumbnail/preview/snapshot/prewarm return nil/no-op
    /// and do NOT reopen; create a new FrameExtractor to extract again.
    public func shutdown() async {
        idleTask?.cancel()
        isShutDown = true
        currentToken?.cancel()
        boundedCancellation?.cancel()
        boundedCancellation = nil
        cache.clear()
        residentApproximation = nil
        let context = self.context
        await runOnQueue { context.close() }
    }

    // MARK: - Core

    private func produce(at seconds: Double, mode: FrameMode, targetWidth: Int, maxSize: CGSize?) async -> CGImage? {
        // Audit BIT-105: a 0/0 scrub fraction or `CMTime.indefinite.seconds` is a host bug, not a position.
        guard !isShutDown, !Task.isCancelled, seconds.isFinite, seconds >= 0 else { return nil }
        // A valid request owns the scrub intent even when its image is already cached or it
        // yields to playback. Retire the preceding decode before either early return.
        currentToken?.cancel()
        boundedCancellation?.cancel()
        let token = CancelToken()
        currentToken = token
        // Every admitted outcome owns idle cleanup, including cache hits, yields and caller
        // cancellation. A late completion cannot extend the newer request's idle lifetime.
        defer {
            if !isShutDown, currentToken === token { scheduleIdleClose() }
        }
        if let hit = cache.get(mode: mode, seconds: seconds, targetWidth: targetWidth, maxSize: maxSize) {
            return hit
        }
        // Elective thumbnails/previews yield to a starved playback pipeline (snapshots are deliberate
        // one-shot user actions and stay ungated). Checked after the cache: hits are free.
        if mode.isElective, yieldWhile?() == true {
            EngineLog.emit("[FrameExtractor] \(mode) yielded: playback pipeline starved",
                           category: .swPlayback, level: .verbose)
            return nil
        }
        let context = self.context
        let result = await withTaskCancellationHandler {
            await runOnQueue { () -> FrameResult in
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
        } onCancel: {
            token.cancel()
        }
        // Cancellation can win after the decode's last check, or while its result waits to
        // reenter this actor. Never publish/cache that result or reset a newer request's idle timer.
        guard !isShutDown, !Task.isCancelled, !token.isCancelled else { return nil }
        if let image = result.image {
            cache.set(image, mode: mode, seconds: seconds, targetWidth: targetWidth, maxSize: maxSize)
        }
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

    /// Tests that wait for the idle close shorten it, so a starved runner does not spend the
    /// suite's time limit on a fixed ten-second sleep.
    func setIdleIntervalForTesting(_ interval: Duration) {
        idleInterval = interval
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
        residentApproximation = nil
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
