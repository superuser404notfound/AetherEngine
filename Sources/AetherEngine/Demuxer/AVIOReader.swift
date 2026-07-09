import Foundation
import os
import Libavformat
import Libavutil

/// Custom AVIO context feeding FFmpeg via URLSession. Three modes:
/// - **Persistent** (known size + prefetch=true, playback path): single long-lived
///   `Range: bytes=<pos>-` GET into a sliding window; reconnects on drop/429/503.
///   Fix for AetherEngine#25 (CDN stutter collapsing playback). See `readPersistent`.
/// - **Seekable chunked** (known size + prefetch=false, still/frame-extraction):
///   discrete Range chunks for random access. See `readSeekable`.
/// - **Streaming** (size=-1): single sequential GET, no reconnect. See `readStreaming`.
///
/// AVIO callbacks run on the demux queue; prefetch/delivery on background queues.
/// Shared state protected by locks.

/// Dedupes `ReaderNetworkPhase` emissions so a flapping origin does not spam the callback (#85).
/// Mutated only on the demux thread (the read loop), so it needs no locking.
struct NetworkPhaseGate {
    private var last: ReaderNetworkPhase = .flowing
    mutating func shouldEmit(_ next: ReaderNetworkPhase) -> Bool {
        guard next != last else { return false }
        last = next
        return true
    }
}

final class AVIOReader: AVIOProvider, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    /// Session config factory. Short-lived probes/chunks get a 60s resource timeout;
    /// long-lived persistent/streaming connections omit it (fires mid-stream, NSURLError
    /// -1001; stall detection is handled by `connStallTimeout`). `urlCache = nil` avoids
    /// the "N URLCaches racing async invalidation" leak (reverted in fef8ef4).
    private static func makeSessionConfig(longLived: Bool = false) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        if !longLived {
            config.timeoutIntervalForResource = 60
        }
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // No URLCache instance, kills the in-memory cache that the
        // long-lived-session fix from fef8ef4 was working around.
        config.urlCache = nil
        return config
    }
    private var position: Int64 = 0
    private var fileSize: Int64 = -1

    /// Typed source-fetch network phase, pushed on every stall/reconnect/recovery transition (#85).
    /// Mirrors `HLSVideoEngine.onSeekStateChanged`. `@Sendable`: invoked from the demux thread, the
    /// consumer hops to the main actor. Set only on the MAIN playback reader, never the subtitle side reader.
    var onNetworkPhaseChanged: (@Sendable (ReaderNetworkPhase) -> Void)?

    /// Demux-thread-only dedupe for `onNetworkPhaseChanged`.
    private var networkPhaseGate = NetworkPhaseGate()

    /// Emit a phase transition through the gate (demux thread only).
    private func emitNetworkPhase(_ phase: ReaderNetworkPhase) {
        if networkPhaseGate.shouldEmit(phase) {
            onNetworkPhaseChanged?(phase)
        }
    }

    /// Cached CDN URL after redirect resolution; skips proxy hop on subsequent chunks.
    /// Auth-expiry statuses (401/403/404/410) against it invalidate and fall back to
    /// the source URL. See AetherEngine#12.
    private let resolvedURLLock = NSLock()
    private var _resolvedURL: URL?

    private func requestURL() -> URL {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL ?? url
    }

    private func cachedResolvedURL() -> URL? {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL
    }

    private func recordResolvedURL(_ resolved: URL?) {
        guard let resolved else { return }
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if resolved != url && resolved != _resolvedURL {
            _resolvedURL = resolved
            #if DEBUG
            EngineLog.emit("[AVIOReader] Cached resolved URL host=\(resolved.host ?? "?")", category: .demux)
            #endif
        }
    }

    private func invalidateResolvedURL() {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if _resolvedURL != nil {
            _resolvedURL = nil
            #if DEBUG
            EngineLog.emit("[AVIOReader] Dropped resolved URL cache (expiry status)", category: .demux)
            #endif
        }
    }

    private static func isResolvedExpiryStatus(_ status: Int) -> Bool {
        return status == 401 || status == 403 || status == 404 || status == 410
    }

    // Cumulative bytes fetched since open; memory probe compares against RSS growth.
    private let counterLock = NSLock()
    private var _cumulativeBytesFetched: Int64 = 0
    var cumulativeBytesFetched: Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _cumulativeBytesFetched
    }
    private func addBytesFetched(_ n: Int) {
        counterLock.lock()
        _cumulativeBytesFetched &+= Int64(n)
        counterLock.unlock()
    }

    private var isStreaming: Bool { fileSize <= 0 }

    var isSeekable: Bool { true }

    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var buffer: UnsafeMutablePointer<UInt8>?

    // MARK: - Seekable Mode (Range requests)

    /// Default 4 MB. Delegate-based incremental delivery (ChunkFetchDelegate on a
    /// shared long-lived chunkSession) avoids the per-request URLSession task-pool
    /// leak that made 8 MB chunks bleed ~6 MB/s (e327e5e). 4 MB gives ~0.7 s
    /// cold-start on 45 Mbps 4K HEVC. Smaller values add HTTP roundtrip overhead
    /// at 5+ ops/sec without meaningful latency benefit. Still-extraction passes a
    /// smaller value for random-access single-keyframe fetches.
    private let chunkSize: Int
    /// When false, no speculative next-chunk prefetch (random-access: next read
    /// almost always seeks elsewhere, so prefetch would be wasted bandwidth).
    private let prefetchEnabled: Bool
    /// When set, the open-time data connection requests a finite `bytes=0-N` range instead of the
    /// open-ended `bytes=0-` stream (#93 residual). Scopes to the open connection only; read-loop
    /// reconnects and seek reconnects stay open-ended. nil = open-ended everywhere (playback).
    private let boundedInitialFetch: Int64?
    private static let avioBufferSize: Int32 = 256 * 1024  // 256 KB
    private static let streamTrimThreshold = 1024 * 1024  // 1 MB, keep for small backward seeks
    // Backpressure: suspend the streaming task above highWater, resume below lowWater.
    private static let streamHighWater = 64 * 1024 * 1024
    private static let streamLowWater = 32 * 1024 * 1024

    private let bufferLock = NSLock()
    private var currentBuffer = Data()
    private var currentOffset: Int64 = 0
    private var prefetchBuffer: Data?
    private var prefetchOffset: Int64 = 0
    private var isPrefetching = false
    private let prefetchReady = DispatchSemaphore(value: 0)
    private let prefetchQueue = DispatchQueue(label: "com.aetherengine.avio.prefetch", qos: .userInitiated)
    private static let maxRetries = 3

    // MARK: - Streaming Mode (sequential GET)

    private var streamBuffer = Data()
    private var streamBytesRead: Int64 = 0
    private var streamEnded = false
    private let streamLock = NSLock()
    private let streamDataReady = DispatchSemaphore(value: 0)

    // MARK: - Persistent Mode (single forward-streaming connection, playback path)

    // Backpressure: pause delivery above highWater; peak resident window ~22 MB.
    private static let winHighWater = 16 * 1024 * 1024
    // Keep this many bytes behind the cursor for small matroska backward re-reads.
    private static let winLookback = 2 * 1024 * 1024
    // Trim in batches to avoid O(n^2) memmove storm on every 256 KB read.
    private static let winTrimBatch = 4 * 1024 * 1024
    // Forward seeks within this distance keep the live connection; beyond it, reconnect.
    private static let seekKeepForwardLimit = 8 * 1024 * 1024
    // CDN stall threshold: no bytes for this long triggers reconnect.
    private static let connStallTimeout: TimeInterval = 20
    // A reconnect that delivers at least this much counts as progress; resets streak.
    private static let minReconnectProgress: Int64 = 512 * 1024
    // Cap on CONSECUTIVE unproductive reconnects; resets on real progress.
    private static let reconnectMaxUnproductive = 12

    // MARK: - Detour Block Cache (random-access parse reads; AetherEngine#69)

    // A non-faststart / coarsely-interleaved remote MP4 makes the demuxer ping-pong between
    // distant file regions (header, trailing moov, sample data) during find_stream_info /
    // index parse. Each non-sequential read used to tear down + reopen the persistent
    // connection (seekReconnect), so the parse storm hammered the origin into a 429.
    // Instead, serve those random-access reads through the pooled keep-alive chunkSession
    // (the one fetchChunk already uses), caching 4 MB aligned blocks. The streaming
    // connection stays ANCHORED; the ping-pong becomes cache hits; the storm collapses to
    // the two legitimate reconnects (open + the one seek to the moov). The sequential
    // playback fast path never enters this code, so it carries zero overhead.
    private static let detourBlockSize = 4 * 1024 * 1024
    private static let detourMaxBlocks = 8                       // ~32 MB LRU ceiling
    // Once detour reads turn sequential past this much, re-anchor the streaming connection
    // there so sustained playback returns to the cheap window path (e.g. after a backward scrub).
    private static let detourReanchorBytes: Int64 = 8 * 1024 * 1024
    // Interactive per-fetch budget for a detour block (#93/#96). A backward-scrub read serves via the
    // detour cache; a miss fetches a 4 MB block over the pooled session. On a per-connection-starved
    // origin that fetch used to ride the full chunkRequestTimeout (idle 15s / total 35s) before falling
    // through to the rescue reconnect, which opens a fresh connection the origin serves in ~30-190ms
    // (rrgomes' #93/#96 traces: the whole 15-35s sat here, invisibly, in the detour fetch). A 4 MB block
    // over a healthy remote 4K source lands in ~1s, so a tight budget aborts a starved fetch fast and
    // lets the reconnect serve, without tripping healthy parse-time detour fetches (#69 stays intact:
    // its fetches complete well under this, and a genuinely slow parse fetch reconnecting is bounded by
    // the #71 rate-limit streak, far gentler than the pre-cache per-read storm).
    private static let detourFetchBudgetSeconds: TimeInterval = 4

    /// Effective per-fetch budget for a detour block: the tight interactive cap, never exceeding the
    /// caller's chunk budget (still-extraction passes a smaller one; it never reaches this path, but
    /// the clamp keeps the invariant). Internal so the bound is unit-tested without a live origin.
    static func effectiveDetourBudget(chunkRequestTimeout: TimeInterval) -> TimeInterval {
        min(detourFetchBudgetSeconds, chunkRequestTimeout)
    }

    // Cap on CONSECUTIVE rate-limited (429/503) network attempts before giving up cleanly.
    // Distinct axis from unproductiveReconnects: NOT reset by seekReconnect, so parse-driven
    // seeks cannot mask a throttled origin into an infinite reconnect loop (AetherEngine#71).
    private static let rateLimitMaxStreak = 6

    /// NSCondition guards all persistent-mode fields and serves as the
    /// edge-triggered condition variable for read waits and backpressure.
    private let winCond = NSCondition()
    /// Sliding window of bytes from the live connection, starting at `winStart`.
    /// `position - winStart` is the read offset within `window`.
    private var window = Data()
    private var winStart: Int64 = 0
    // Connection state.
    private var connEnded = false
    private var connStatus = 0
    // Retry-After seconds from 429/503, honoured before reconnect.
    private var connRetryAfter: TimeInterval = 0
    // Bumped on every (re)connect; stale delegate callbacks are ignored.
    private var connGeneration = 0
    private var activeSession: URLSession?
    private var activeTask: URLSessionDataTask?
    // #93 restart latency diagnostics (winCond-guarded): bytes dropped by the stale-generation
    // guard, plus per-generation time-to-first-data tracking.
    private var staleGenDroppedBytes: Int64 = 0
    private var connStartedAt = DispatchTime.now()
    private var connFirstDataSeen = false
    // Consecutive unproductive reconnects (demux-thread-only).
    private var unproductiveReconnects = 0
    private var bytesAtLastReconnect: Int64 = 0
    // Consecutive 429/503 attempts; survives seekReconnect, resets on real read progress (#71).
    private var rateLimitStreak = 0

    /// Detour LRU block cache (its own leaf lock, never held across `fetchChunk`/network or
    /// `winCond`). Stores only full-size blocks; short bodies are served once but never cached
    /// (see serveFromDetour), so eviction never shadows a re-fetchable tail. Pure copy/eviction
    /// math lives on the cache and is unit-tested without any network.
    private let detourCache = DetourBlockCache(blockSize: AVIOReader.detourBlockSize,
                                               maxBlocks: AVIOReader.detourMaxBlocks)
    // Re-anchor run tracking (demux-thread-only): the file offset the next sequential detour read
    // would continue from, and how many contiguous bytes the current detour run has served.
    private var detourRunNextExpected: Int64 = -1
    private var detourRunBytes: Int64 = 0

    /// Playback path (known size + prefetch) or live feeds. Live always uses the
    /// persistent reader; the streaming reader has no reconnect machinery.
    private var usePersistentReader: Bool {
        if isLive { return prefetchEnabled }
        return !isStreaming && prefetchEnabled
    }

    /// True for endless live feeds. Suppresses `position >= fileSize` EOF synthesis;
    /// reports EIO (-5) instead of EOF when the reconnect cap is hit.
    let isLive: Bool

    /// Detour cache is VOD-only: live feeds have no meaningful random access and a
    /// non-authoritative size, so they stay on the unchanged reconnect path.
    private var detourEligible: Bool { !isLive && fileSize > 0 }

    /// Timestamp of the last unplanned reconnect (drop/stall, not a seek).
    /// Producer correlates with a backward source-PTS reset to detect Jellyfin
    /// transcode respawn (re-serves from byte 0 on re-GET, invisible at byte level).
    /// Demux-thread-only (AVIO callback executes synchronously inside av_read_frame).
    private(set) var lastUnplannedReconnectAt: Date?

    /// Seekable-path per-chunk Range-request budget (seconds) and retry passes.
    /// Defaults preserve the historical playback/probe behaviour; still extraction
    /// passes smaller values so a stalled scrub thumbnail aborts fast (issue #27).
    private let chunkRequestTimeout: TimeInterval
    private let chunkMaxRetries: Int

    /// TEST-ONLY slow-CDN throttle (kbit/s, 0 = unlimited), captured once from the static hook at init.
    private let throttleKbps: Int
    private var throttleVClockNs: UInt64 = 0
    private let throttleLock = NSLock()

    init(url: URL, extraHeaders: [String: String] = [:], chunkSize: Int = 4 * 1024 * 1024, prefetchEnabled: Bool = true, isLive: Bool = false, chunkRequestTimeout: TimeInterval = 35, chunkMaxRetries: Int = 3, boundedInitialFetch: Int64? = nil) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.chunkSize = chunkSize
        self.prefetchEnabled = prefetchEnabled
        self.isLive = isLive
        self.chunkRequestTimeout = chunkRequestTimeout
        self.chunkMaxRetries = max(1, chunkMaxRetries)
        self.boundedInitialFetch = boundedInitialFetch.map { max(1, $0) }
        self.throttleKbps = AetherEngine.sourceThrottleKbpsForTesting
    }

    /// Slow-CDN simulation: hold delivered bytes to `throttleKbps` by sleeping the demux thread before the
    /// bytes reach the demuxer. No-op unless the test hook is set. Lock-guarded: prefetch and demux paths
    /// can both deliver. Sleeping here is consistent with the existing reconnect backoff on this thread.
    private func applyThrottle(deliveredBytes: Int) {
        guard throttleKbps > 0, deliveredBytes > 0 else { return }
        throttleLock.lock()
        let sleepNs = SourceThrottle.advance(
            vclockNs: &throttleVClockNs,
            nowNs: DispatchTime.now().uptimeNanoseconds,
            deliveredBytes: deliveredBytes,
            kbps: throttleKbps
        )
        throttleLock.unlock()
        if sleepNs > 0 { Thread.sleep(forTimeInterval: Double(sleepNs) / 1_000_000_000) }
    }

    private func applyExtraHeaders(_ request: inout URLRequest) {
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    func open() throws {
        guard let buf = av_malloc(Int(Self.avioBufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.avioBufferSize,
            0,
            opaque,
            readCallback,
            nil,
            seekCallback
        ) else {
            av_free(buf)
            buffer = nil
            throw AVIOReaderError.allocationFailed
        }

        context = ctx

        if prefetchEnabled {
            // Playback path. The persistent connection's `Range: bytes=0-` request is itself
            // the size probe: its 206 Content-Range is folded into fileSize by
            // persistentReceivedResponse (issue #70), so the common case skips the dedicated
            // probeFileSize() round-trip (and its HEAD fallback, the request some origins 429).
            startPersistentConnection(at: 0, boundedTo: boundedInitialFetch)
            let gotData = awaitFirstPersistentData()
            var tookFallback = false
            if !isLive {
                // Atomically decide, under winCond, whether the optimistic connection resolved
                // a size; if not, abandon it (generation bump ignores a size landing in the
                // race window). fileSize is read under the lock because the delegate thread now
                // writes it (issue #70 review #4/#5).
                let (haveSize, abandoned) = resolveOptimisticOpen()
                abandoned?.invalidateAndCancel()
                if !haveSize {
                    // The data connection resolved no size (no-length origin, a transient 429,
                    // slow headers, or an origin whose length only comes via HEAD). Fall back to
                    // the exact pre-#70 probe path (Range bytes=0- then HEAD, on its own
                    // connection and budget): it keeps seekability whenever a size is reachable
                    // and only streams on a genuinely length-less source, restoring main's
                    // resilience to all of those cases (issue #70 review #1/#3/#4).
                    tookFallback = true
                    EngineLog.emit("[AVIOReader] Data connection resolved no size, falling back to probe", category: .demux, level: .verbose)
                    fileSize = resolveInitialFileSize()
                    if isStreaming {
                        startStreamingDownload()
                        _ = streamDataReady.wait(timeout: .now() + .seconds(15))
                    } else {
                        startPersistentConnection(at: 0)
                        if !awaitFirstPersistentData() {
                            EngineLog.emit("[AVIOReader] Persistent open (post-probe): no data within 15s, proceeding to read-loop reconnect", category: .demux)
                        }
                    }
                }
            }
            if !tookFallback && !gotData {
                // No first byte within 15s; read loop's stall/reconnect machinery takes over.
                EngineLog.emit("[AVIOReader] Persistent open: no first byte within 15s, proceeding to read-loop reconnect", category: .demux)
            }
        } else {
            // Non-prefetch (still extraction / one-shot seekable): the size is needed up
            // front for SEEK_END and container index seeks, so keep the dedicated probe.
            fileSize = resolveInitialFileSize()
            if isStreaming {
                startStreamingDownload()
                _ = streamDataReady.wait(timeout: .now() + .seconds(15))
            } else {
                if let data = fetchChunk(from: 0, size: chunkSize) {
                    currentBuffer = data
                    currentOffset = 0
                }
            }
        }
    }

    /// Block up to 15s for the persistent connection's first window bytes. The response
    /// (and thus any Content-Range size) has already been processed by the time data
    /// arrives. Demux thread, open-time only. Returns true if data arrived.
    private func awaitFirstPersistentData() -> Bool {
        winCond.lock()
        let deadline = Date(timeIntervalSinceNow: 15)
        while window.isEmpty && !connEnded && !isClosed {
            if !winCond.wait(until: deadline) { break }
        }
        let gotData = !window.isEmpty
        winCond.unlock()
        return gotData
    }

    /// Under a single winCond critical section: snapshot whether the optimistic open-time
    /// connection resolved a size (fileSize > 0, written by the delegate thread in
    /// persistentReceivedResponse), and if not, atomically abandon that connection so the
    /// open can fall back to the probe path. Bumping the generation inside the same lock as
    /// the read means a size that lands in the race window is ignored rather than racing a
    /// half-done teardown (issue #70 review #4/#5). Returns the session to cancel outside
    /// the lock. Demux thread, open-time only; leaves the AVIO context intact (unlike close()).
    private func resolveOptimisticOpen() -> (haveSize: Bool, abandoned: URLSession?) {
        winCond.lock()
        defer { winCond.unlock() }
        if fileSize > 0 { return (true, nil) }
        connGeneration &+= 1
        let session = activeSession
        activeSession = nil
        activeTask = nil
        window = Data()
        connEnded = true
        winCond.broadcast()
        return (false, session)
    }

    // Close flags written on the teardown thread (markClosed / fullyClose) and read on the demux
    // thread plus the URLSession delegate threads (persistent-connection callbacks). Backed by a
    // leaf unfair lock so every access is synchronized; the bare Bools were a TSan-confirmed data
    // race (markClosed write vs appendPersistentData read). The lock is only ever held for the
    // get/set itself (never across another lock), so it cannot invert with winCond/streamLock.
    private let isClosedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var isClosed: Bool {
        get { isClosedLock.withLock { $0 } }
        set { isClosedLock.withLock { $0 = newValue } }
    }
    private let isFullyClosedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var isFullyClosed: Bool {
        get { isFullyClosedLock.withLock { $0 } }
        set { isFullyClosedLock.withLock { $0 = newValue } }
    }

    /// #112 round 8: the resolved total byte size (Content-Length / Content-Range), nil until known.
    /// Read under winCond like every other fileSize access. Used by `Demuxer.seekByteEstimate` for the
    /// single-probe byte-position fallback when a timestamp seek on an index-less container times out.
    var resolvedFileSize: Int64? {
        winCond.lock()
        defer { winCond.unlock() }
        return fileSize > 0 ? fileSize : nil
    }

    /// Wall-clock deadline for reads. Armed by `beginReadDeadline` to abort
    /// a `avformat_seek_file` that degrades into a linear scan when MKV Cues
    /// index is missing or past EOF (tens of minutes on remote sources).
    private var readDeadline = Date.distantFuture
    private var isPastReadDeadline: Bool { Date() >= readDeadline }
    /// Set when a read returned early due to deadline. `seekBounded` uses this
    /// since matroska may still return success with a partial index after abort.
    private(set) var readDeadlineFired = false

    /// Contract: `readDeadline`/`readDeadlineFired` are demux-thread-only. The
    /// still-extraction (FrameExtractor) reader satisfies this because it runs on one
    /// serial decode queue and `avioPrefetch:false` means no background prefetch thread
    /// touches them. A future profile that re-enables prefetch on a deadline-armed
    /// reader would need these guarded.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        readDeadlineFired = false
        readDeadline = Date(timeIntervalSinceNow: seconds)
        // Wake a read already parked in the forward-wait so it re-evaluates
        // against the new deadline instead of sleeping the full stall window.
        winCond.lock()
        winCond.broadcast()
        winCond.unlock()
    }

    func endReadDeadline() {
        readDeadline = .distantFuture
    }

    // Streaming task/session held so teardown can cancel and unblock streamDownloadSync.
    private var streamingSession: URLSession?
    private var streamingTask: URLSessionDataTask?
    // Suspend/resume calls are balanced under streamLock.
    private var streamingTaskSuspended = false

    /// Unblock a suspended av_read_frame and release the live network connection.
    /// Must be called BEFORE acquiring the demuxer's access lock.
    func markClosed() {
        isClosed = true
        // Wake any semaphore waits so the read callbacks can exit
        prefetchReady.signal()
        streamDataReady.signal()
        streamLock.lock()
        let sTask = streamingTask
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        sTask?.cancel()
        winCond.lock()
        connGeneration &+= 1
        // #93/#96 residual: cancel the persistent Range GET here, not only in close(). markClosed is
        // the abort used by the #79 reopen path (dem.markClosed() to unblock a wedged read); leaving
        // its long-lived open-ended connection alive lets it keep draining the origin for the whole
        // reopen + first-read window, and that connection fair-shares the origin's bandwidth with the
        // fresh reader's cold read, which is exactly the per-connection starvation behind the residual
        // 15-30s cold reads. The AVIO context is untouched (close() still frees it); only the socket
        // is released. Grab under winCond, invalidate outside it (mirrors close()).
        let session = activeSession
        let task = activeTask
        activeSession = nil
        activeTask = nil
        connEnded = true
        winCond.broadcast()
        winCond.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    /// Free all resources. Separate from `markClosed` (step 1: unblock reads)
    /// because `isClosed` alone can't gate this: prior misuse of that guard
    /// silently leaked 64 MB current + 64 MB prefetch buffers on teardown.
    /// `isFullyClosed` is the idempotency latch for this step.
    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        if let ctx = context {
            // avio_context_free does NOT free ctx->buffer (verified, aviobuf.c).
            // Free ctx.pointee.buffer, not original av_malloc ptr: FFmpeg can
            // realloc internally via ffio_set_buf_size.
            av_free(ctx.pointee.buffer)
            avio_context_free(&context)
        }
        context = nil
        buffer = nil

        bufferLock.lock()
        currentBuffer = Data()
        prefetchBuffer = nil
        bufferLock.unlock()

        detourCache.clear()

        streamLock.lock()
        streamEnded = true
        streamBuffer = Data()
        let sTask = streamingTask
        let sSession = streamingSession
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamingTask = nil
        streamingSession = nil
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        streamDataReady.signal()
        // Covers a close() without prior markClosed().
        sTask?.cancel()
        sSession?.invalidateAndCancel()

        winCond.lock()
        connGeneration &+= 1
        connEnded = true
        let session = activeSession
        activeSession = nil
        activeTask = nil
        window = Data()
        winCond.broadcast()
        winCond.unlock()
        session?.invalidateAndCancel()
    }

    // MARK: - Read (called by FFmpeg on demux thread)

    fileprivate func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        guard !isClosed else { return -1 }
        if isPastReadDeadline { readDeadlineFired = true; return -1 }
        // Check usePersistentReader before isStreaming: live feeds without
        // Content-Length must use the reconnect-capable persistent path.
        let n: Int32
        if usePersistentReader { n = readPersistent(into: buf, size: size) }
        else if isStreaming { n = readStreaming(into: buf, size: size) }
        else { n = readSeekable(into: buf, size: size) }
        if n > 0 { applyThrottle(deliveredBytes: Int(n)) }
        return n
    }

    // MARK: - Seekable Read (Range-based)

    private func readSeekable(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            // Abort a superseded / torn-down / past-deadline still read between chunk
            // fetches so it cannot park the decode queue (issue #27). Mirrors the
            // checks readPersistent already does at its loop head.
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if isPastReadDeadline { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            bufferLock.lock()
            let bufEnd = currentOffset + Int64(currentBuffer.count)
            let inRange = position >= currentOffset && position < bufEnd
            bufferLock.unlock()

            if inRange {
                bufferLock.lock()
                let offsetInBuffer = Int(position - currentOffset)
                let available = currentBuffer.count - offsetInBuffer
                let toCopy = min(available, requestSize - totalRead)

                currentBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: offsetInBuffer)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: toCopy)
                }
                position += Int64(toCopy)
                totalRead += toCopy

                let consumed = Double(position - currentOffset) / Double(currentBuffer.count)
                let nextPrefetchOffset = currentOffset + Int64(currentBuffer.count)
                let needsPrefetch = prefetchEnabled && consumed > 0.5 && !isPrefetching && prefetchBuffer == nil
                bufferLock.unlock()

                if needsPrefetch {
                    triggerPrefetch(from: nextPrefetchOffset)
                }
            } else {
                bufferLock.lock()
                if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                    position < prefetchOffset + Int64(prefetch.count) {
                    currentBuffer = prefetch
                    currentOffset = prefetchOffset
                    prefetchBuffer = nil
                    bufferLock.unlock()
                    continue
                }
                let hasPrefetchInFlight = isPrefetching
                bufferLock.unlock()

                if hasPrefetchInFlight {
                    _ = prefetchReady.wait(timeout: .now() + .seconds(15))
                    bufferLock.lock()
                    if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                        position < prefetchOffset + Int64(prefetch.count) {
                        currentBuffer = prefetch
                        currentOffset = prefetchOffset
                        prefetchBuffer = nil
                        bufferLock.unlock()
                        continue
                    }
                    bufferLock.unlock()
                }

                let fetchSize: Int
                if fileSize > 0 {
                    fetchSize = min(chunkSize, Int(fileSize - position))
                } else {
                    fetchSize = chunkSize
                }

                if fetchSize <= 0 { break }

                guard let data = fetchChunk(from: position, size: fetchSize), !data.isEmpty else {
                    // An aborted fetch (supersede/close/deadline) must report a read
                    // error, not EOF (which would truncate the stream cleanly). issue #27.
                    if isClosed || isPastReadDeadline {
                        if isPastReadDeadline { readDeadlineFired = true }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    // nil = transport failure; empty = 2xx with no body (would loop forever otherwise).
                    break
                }

                bufferLock.lock()
                currentBuffer = data
                currentOffset = position
                prefetchBuffer = nil
                bufferLock.unlock()
            }
        }

        return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
    }

    // MARK: - Streaming Read (sequential GET)

    private func readStreaming(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            streamLock.lock()
            let posInBuffer = Int(position - streamBytesRead)
            let available = streamBuffer.count - posInBuffer
            let ended = streamEnded
            streamLock.unlock()

            if available > 0 && posInBuffer >= 0 {
                let toCopy = min(available, requestSize - totalRead)

                streamLock.lock()
                streamBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: posInBuffer)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: toCopy)
                }
                streamLock.unlock()

                position += Int64(toCopy)
                totalRead += toCopy

                // subdata (not removeFirst): removeFirst leaks backing storage (see trimWindowLocked).
                streamLock.lock()
                let consumed = Int(position - streamBytesRead)
                if consumed > Self.streamTrimThreshold {
                    let trimAmount = consumed - Self.streamTrimThreshold
                    streamBuffer = streamBuffer.subdata(in: trimAmount..<streamBuffer.count)
                    streamBytesRead += Int64(trimAmount)
                }
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended, streamBuffer.count < Self.streamLowWater {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
            } else if ended {
                break
            } else {
                // Resume before waiting: a suspended task would never deliver.
                streamLock.lock()
                var toResume: URLSessionDataTask?
                if streamingTaskSuspended {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
                let timeout = streamDataReady.wait(timeout: .now() + .seconds(15))
                if timeout == .timedOut { break }
            }
        }

        return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
    }

    // MARK: - Persistent Read (single forward-streaming connection)

    /// Sliding-window read over a single long-lived Range: bytes=<offset>- connection.
    /// State machine: inside window -> copy; before window -> backward reconnect;
    /// position >= fileSize -> EOF (only EOF path); far forward -> reconnect;
    /// just ahead + live conn -> wait; conn ended -> reconnect + backoff.
    /// Fetch failures reconnect at the frontier, never collapse to AVERROR_EOF (AetherEngine#25).
    private func readPersistent(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        // #93 restart latency: accumulate where THIS read spends its time; one summary line fires
        // on completion when the whole call exceeded the threshold (see SlowReadDiagnostics).
        let readStart = DispatchTime.now()
        var diag = SlowReadDiagnostics()
        func msSince(_ t: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        }
        // #93/#96 residual: count the reconnect AND time the synchronous connect path it drives
        // (the old session's invalidateAndCancel + new task setup, all on this demux thread), so a
        // slow read that sinks its time into reconnecting names it as `connect=` instead of `unaccounted=`.
        func timedReconnect(seek: Bool, at offset: Int64) {
            diag.recordReconnect()
            let connectStart = DispatchTime.now()
            if seek { seekReconnect(at: offset) } else { startPersistentConnection(at: offset) }
            diag.recordConnect(ms: msSince(connectStart))
        }
        winCond.lock()
        let diagEntryPosition = position
        let diagGenAtStart = connGeneration
        let diagDropsAtStart = staleGenDroppedBytes
        winCond.unlock()
        defer {
            let elapsedMs = msSince(readStart)
            if elapsedMs >= diag.thresholdMs {
                winCond.lock()
                let genAtEnd = connGeneration
                let dropped = staleGenDroppedBytes - diagDropsAtStart
                winCond.unlock()
                diag.recordStaleGenerationDrop(bytes: dropped)
                if let line = diag.line(elapsedMs: elapsedMs, offset: diagEntryPosition,
                                        generationSpan: (diagGenAtStart, genAtEnd)) {
                    EngineLog.emit(line, category: .demux)
                }
            }
        }

        while totalRead < requestSize {
            diag.recordIteration()
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if isPastReadDeadline { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            // #93/#96 residual: time the loop-head lock acquisition. A delegate thread holding winCond
            // across its copy + backpressure window blocks the read HERE with nothing to show for it, so
            // this turns that invisible wait into `lockWait=`.
            let lockWaitStart = DispatchTime.now()
            winCond.lock()
            diag.recordLockWait(ms: msSince(lockWaitStart))

            if activeTask == nil {
                let target = position
                winCond.unlock()
                timedReconnect(seek: true, at: target)
                continue
            }

            let curPosition = position

            if curPosition < winStart {
                winCond.unlock()
                // Backward random-access read (MP4 parse ping-pong, or a large backward scrub).
                // Serve via the pooled detour cache so the anchored streaming connection is NOT
                // torn down (the reconnect storm + origin 429, AetherEngine#69).
                if detourEligible {
                    // Re-anchor the streaming connection once detour reads have turned sequential
                    // past the threshold (playback resumed here), so steady playback returns to
                    // the cheap window path instead of fetching 4 MB blocks forever.
                    if curPosition == detourRunNextExpected && detourRunBytes >= Self.detourReanchorBytes {
                        detourResetRun()
                        timedReconnect(seek: true, at: curPosition)
                        continue
                    }
                    let detourStart = DispatchTime.now()
                    switch serveFromDetour(into: buf.advanced(by: totalRead),
                                           maxLen: requestSize - totalRead,
                                           at: curPosition, allowFetch: true) {
                    case .served(let n):
                        // A resident-block hit is a pure memcpy (sub-ms); anything slower crossed the network.
                        let detourMs = msSince(detourStart)
                        diag.recordDetourServe(ms: detourMs, fetched: detourMs > 2)
                        winCond.lock(); position = curPosition + Int64(n); winCond.broadcast(); winCond.unlock()
                        totalRead += n
                        unproductiveReconnects = 0
                        rateLimitStreak = 0
                        emitNetworkPhase(.flowing)   // detour cache served: not stalled (#85)
                        detourTrackSequential(at: curPosition, length: n)
                        continue
                    case .rateLimited(let retryAfter):
                        // #93/#96: account the (throttled) fetch attempt's time so it leaves `unaccounted`.
                        diag.recordDetourFetchAttempt(ms: msSince(detourStart))
                        // Origin is throttling the detour fetch too (#71). Back off in place and
                        // RETRY the detour fetch; do NOT open a fresh connection (that re-enters
                        // the 429 churn the cache exists to remove). Give up cleanly at the cap.
                        if recordRateLimitAndShouldGiveUp() {
                            EngineLog.emit("[AVIOReader] Detour rate-limit gave up at offset \(curPosition) (\(rateLimitStreak) consecutive 429/503)", category: .demux)
                            return totalRead > 0 ? Int32(totalRead) : -1
                        }
                        let backoffStart = DispatchTime.now()
                        backoffBeforeReconnect(streak: rateLimitStreak, retryAfter: retryAfter)
                        diag.recordBackoff(ms: msSince(backoffStart))
                        continue
                    case .miss:
                        // #93/#96: this is where the residual cold read actually lived. A starved fetch
                        // rode its budget then missed; account that time (else it hides in `unaccounted`)
                        // before falling through to the rescue reconnect that serves in ~30-190ms.
                        diag.recordDetourFetchAttempt(ms: msSince(detourStart))
                        if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
                        if isPastReadDeadline { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }
                        // Hard transport failure: degrade to the OLD single-reconnect behavior.
                        timedReconnect(seek: true, at: curPosition)
                        continue
                    }
                }
                timedReconnect(seek: true, at: curPosition)
                continue
            }

            let posInWindow = Int(curPosition - winStart)
            let available = window.count - posInWindow
            if available > 0 {
                let copyNow = min(available, requestSize - totalRead)
                window.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: posInWindow)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: copyNow)
                }
                position = curPosition + Int64(copyNow)
                totalRead += copyNow
                trimWindowLocked()
                unproductiveReconnects = 0      // real progress
                rateLimitStreak = 0             // real progress clears the 429 give-up streak (#71)
                emitNetworkPhase(.flowing)      // recovered: source delivering again (#85)
                winCond.broadcast()              // window may have shrunk: wake backpressure
                winCond.unlock()
                continue
            }

            let frontier = winStart + Int64(window.count)
            let ended = connEnded
            let status = connStatus
            let retryAfter = connRetryAfter

            // Genuine EOF: only path that returns AVERROR_EOF. Skip for live
            // (fileSize non-authoritative on live feeds).
            if !isLive && fileSize > 0 && curPosition >= fileSize {
                winCond.unlock()
                return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
            }

            if curPosition > frontier + Int64(Self.seekKeepForwardLimit) {
                winCond.unlock()
                // Far-forward seek. Serve from the detour cache ONLY if the block is already
                // resident (e.g. the moov region the parser revisits); a genuine forward scrub
                // misses and re-anchors the streaming window there, never chunk-serving forever.
                if detourEligible {
                    switch serveFromDetour(into: buf.advanced(by: totalRead),
                                           maxLen: requestSize - totalRead,
                                           at: curPosition, allowFetch: false) {
                    case .served(let n):
                        diag.recordDetourServe(ms: 0, fetched: false)   // resident-only path
                        winCond.lock(); position = curPosition + Int64(n); winCond.broadcast(); winCond.unlock()
                        totalRead += n
                        unproductiveReconnects = 0
                        rateLimitStreak = 0
                        emitNetworkPhase(.flowing)   // detour cache served: not stalled (#85)
                        detourTrackSequential(at: curPosition, length: n)
                        continue
                    case .rateLimited, .miss:
                        break   // allowFetch:false never rate-limits; a miss falls through to reconnect
                    }
                }
                timedReconnect(seek: true, at: curPosition)
                continue
            }

            if !ended {
                // Wait for the live connection to fill forward. A false return
                // means connStallTimeout elapsed with no data (socket stall).
                let waitStart = DispatchTime.now()
                let signaled = winCond.wait(until: min(Date(timeIntervalSinceNow: Self.connStallTimeout), readDeadline))
                winCond.unlock()
                diag.recordStallWait(ms: msSince(waitStart), signaled: signaled)
                // Check deadline before stall handling to avoid misrouting a
                // deadline wake as a socket stall (which would reconnect).
                if isPastReadDeadline { continue }
                if !signaled {
                    if recordReconnectAndShouldGiveUp() {
                        EngineLog.emit("[AVIOReader] Persistent stall gave up at offset \(frontier) (\(unproductiveReconnects) unproductive)\(isLive ? " [live source lost]" : "")", category: .demux)
                        emitNetworkPhase(.flowing)   // reader is exiting; let state carry the terminal outcome (#85)
                        if isLive {
                            return totalRead > 0 ? Int32(totalRead) : AVERROR_EIO_VALUE
                        }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    EngineLog.emit("[AVIOReader] Persistent stall at offset \(frontier), reconnecting", category: .demux)
                    lastUnplannedReconnectAt = Date()
                    emitNetworkPhase(.reconnecting)   // unplanned reconnect now in flight (#85)
                    let backoffStart = DispatchTime.now()
                    backoffBeforeReconnect(streak: unproductiveReconnects, retryAfter: 0)
                    diag.recordBackoff(ms: msSince(backoffStart))
                    timedReconnect(seek: false, at: frontier)
                }
                continue
            }

            // Connection ended before EOF; reconnect at frontier. Honour Retry-After for 429/503.
            winCond.unlock()
            // A 429/503 is rate limiting, not a dead source: drive give-up + backoff off the
            // rate-limit streak, which (unlike unproductiveReconnects) survives the seekReconnect
            // that parse seeks fire, so a throttled origin fails cleanly instead of looping (#71).
            let isRateLimited = (status == 429 || status == 503)
            let giveUp = isRateLimited ? recordRateLimitAndShouldGiveUp()
                                       : recordReconnectAndShouldGiveUp(status: status)
            if giveUp {
                let streakDesc = isRateLimited ? "\(rateLimitStreak) consecutive 429/503" : "\(unproductiveReconnects) unproductive"
                EngineLog.emit("[AVIOReader] Persistent reconnect exhausted at offset \(frontier) status=\(status) (\(streakDesc))\(isLive ? " [live source lost]" : "")", category: .demux)
                emitNetworkPhase(.flowing)   // reader is exiting; let state carry the terminal outcome (#85)
                if isLive {
                    return totalRead > 0 ? Int32(totalRead) : AVERROR_EIO_VALUE
                }
                return totalRead > 0 ? Int32(totalRead) : -1
            }
            let backoffStreak = isRateLimited ? rateLimitStreak : unproductiveReconnects
            EngineLog.emit("[AVIOReader] Persistent conn ended at offset \(frontier) status=\(status), reconnecting (streak=\(backoffStreak) retryAfter=\(retryAfter)s)", category: .demux)
            lastUnplannedReconnectAt = Date()
            emitNetworkPhase(.reconnecting)   // unplanned reconnect now in flight (#85)
            let backoffStart = DispatchTime.now()
            backoffBeforeReconnect(streak: backoffStreak, retryAfter: retryAfter)
            diag.recordBackoff(ms: msSince(backoffStart))
            timedReconnect(seek: false, at: frontier)
        }

        return Int32(totalRead)
    }

    /// Drop consumed bytes in ~winTrimBatch steps to avoid O(n^2) memmove.
    /// MUST use `subdata` (not `removeFirst`): removeFirst only advances the slice's
    /// lower bound but backing storage grows with count.setter in appendPersistentData,
    /// leaking ~14 MB/s on 80 Mbps remux (AetherEngine#31). subdata re-bases to compact
    /// storage. Caller holds `winCond`.
    private func trimWindowLocked() {
        let behind = Int(position - winStart)
        let dropThreshold = Self.winLookback + Self.winTrimBatch
        if behind > dropThreshold {
            let drop = behind - Self.winLookback
            window = window.subdata(in: drop..<window.count)
            winStart += Int64(drop)
        }
    }

    /// Intentional reconnect for a seek; clears the unproductive streak.
    private func seekReconnect(at offset: Int64) {
        unproductiveReconnects = 0
        bytesAtLastReconnect = cumulativeBytesFetched
        startPersistentConnection(at: offset)
    }

    /// Increments the unproductive-reconnect streak (resets if progress exceeded
    /// `minReconnectProgress`). Returns true when the cap is hit. Demux-thread-only.
    private func recordReconnectAndShouldGiveUp(status: Int = 0) -> Bool {
        let now = cumulativeBytesFetched
        if now - bytesAtLastReconnect >= Self.minReconnectProgress {
            unproductiveReconnects = 0
        } else {
            unproductiveReconnects += 1
        }
        bytesAtLastReconnect = now
        // Hard 4xx/5xx (not 429/503 which carry Retry-After) on a source that has
        // never delivered a byte = server-side failure (e.g. Jellyfin 500 after
        // transcode-failure latency ~15-20s/attempt). One retry, then out.
        let isHardError = status >= 400 && status != 429 && status != 503
        if now == 0 && isHardError {
            return unproductiveReconnects > 1
        }
        // Dead-on-arrival sources (never produced data) get a reduced budget;
        // sources that ever produced data keep the full budget for mid-stream resilience.
        let cap = now == 0
            ? Self.reconnectMaxUnproductiveNeverProductive
            : Self.reconnectMaxUnproductive
        return unproductiveReconnects > cap
    }

    // 4 attempts ride out a transient transcode spin-up (~10-15s with backoff)
    // without grinding a dead tuner for minutes.
    private static let reconnectMaxUnproductiveNeverProductive = 4

    /// Exponential backoff (0.5s..8s) growing with streak; immediate on streak=0.
    /// Sleeps in 0.1s slices so a close is honoured promptly.
    private func backoffBeforeReconnect(streak: Int, retryAfter: TimeInterval) {
        let expo = streak <= 0 ? 0.0 : min(Double(1 << min(streak, 4)) * 0.5, 8.0)
        let total = min(max(expo, retryAfter), 15.0)
        if total <= 0 { return }
        var slept = 0.0
        while slept < total {
            if isClosed { return }
            Thread.sleep(forTimeInterval: 0.1)
            slept += 0.1
        }
    }

    /// Increments the consecutive 429/503 streak; returns true once the bounded cap is hit.
    /// Demux-thread-only. Deliberately NOT reset by `seekReconnect` (parse seeks must not mask a
    /// throttled origin into an endless reconnect loop, #71); only real read progress clears it.
    /// Internal (not private) so the bounded give-up is unit-tested without a live origin.
    func recordRateLimitAndShouldGiveUp() -> Bool {
        rateLimitStreak += 1
        return rateLimitStreak > Self.rateLimitMaxStreak
    }

    // MARK: - Detour Block Cache (AetherEngine#69)

    private enum DetourServe { case served(Int); case rateLimited(TimeInterval); case miss }
    private enum DetourFetch { case ok(Data); case rateLimited(TimeInterval); case failed }

    /// Serve `[offset, offset+maxLen)` (clamped to one 4 MB block) from the detour cache,
    /// fetching the block over the pooled keep-alive chunkSession on a miss when `allowFetch`.
    /// Demux-thread call; may block on the network via `detourFetchBlock` (no lock held across it).
    /// Returns `.miss` (never `.served(0)`) so callers fall back to a single reconnect.
    private func serveFromDetour(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int,
                                 at offset: Int64, allowFetch: Bool) -> DetourServe {
        guard fileSize > 0, offset < fileSize, maxLen > 0 else { return .miss }

        // Resident-block hit: pure copy, no network.
        if let n = detourCache.serveCached(into: dst, maxLen: maxLen, at: offset) {
            return .served(n)
        }
        guard allowFetch else { return .miss }

        let blockStart = (offset / Int64(Self.detourBlockSize)) * Int64(Self.detourBlockSize)
        let blockLen = Int(min(Int64(Self.detourBlockSize), fileSize - blockStart))
        let block: Data
        switch detourFetchBlock(from: blockStart, size: blockLen) {
        case .ok(let fetched):
            // Cache only FULL-length blocks. A truncated 206 cached verbatim would shadow the
            // re-fetch path for its uncovered tail, so the parser ping-ponging into that tail
            // would cost one reconnect per read, reintroducing a mild storm (#69 review). Serve
            // the short body once; the next read of this block re-fetches.
            if fetched.count == blockLen, !isFullyClosed {
                detourCache.insert(blockStart / Int64(Self.detourBlockSize), fetched)
                #if DEBUG
                EngineLog.emit("[AVIOReader] detour fill block=\(blockStart / Int64(Self.detourBlockSize)) offset=\(blockStart) size=\(fetched.count) (resident=\(detourCache.residentCount))", category: .demux)
                #endif
            }
            block = fetched
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter)
        case .failed:
            return .miss
        }

        let inBlock = Int(offset - blockStart)
        guard inBlock >= 0, inBlock < block.count else { return .miss }
        let n = min(maxLen, block.count - inBlock)
        block.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inBlock).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return .served(n)
    }

    /// Single Range fetch for a detour block over the pooled chunkSession. Surfaces 429/503 with
    /// its Retry-After so the caller can back off in place rather than churn the connection (#71).
    private func detourFetchBlock(from offset: Int64, size: Int) -> DetourFetch {
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: requestURL())
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        // #93/#96: a starved backward-scrub detour fetch must abort fast (the rescue reconnect serves
        // instantly), so this path uses the tight interactive budget, not the full chunk timeout.
        let budget = Self.effectiveDetourBudget(chunkRequestTimeout: chunkRequestTimeout)
        request.timeoutInterval = budget
        applyExtraHeaders(&request)
        do {
            let (data, response) = try syncRequest(request, budget: budget)
            if let http = response as? HTTPURLResponse {
                let status = http.statusCode
                if status == 429 || status == 503 {
                    return .rateLimited(Self.parseRetryAfter(http))
                }
                if status != 200 && status != 206 {
                    if Self.isResolvedExpiryStatus(status) { invalidateResolvedURL() }
                    return .failed
                }
                // VOD: 200 at offset > 0 = server ignored Range; silent corruption. Reject.
                if status == 200 && offset > 0 && !isLive {
                    EngineLog.emit("[AVIOReader] detour: server ignored Range (200 for offset \(offset)); rejecting", category: .demux, level: .verbose)
                    return .failed
                }
            }
            addBytesFetched(data.count)
            return .ok(data)
        } catch {
            return .failed
        }
    }

    /// Tracks contiguity of detour reads for the re-anchor heuristic. Shared by BOTH the backward
    /// and far-forward branches; the re-anchor check itself lives only in the backward branch on
    /// purpose, so a forward-accumulated run later met by a contiguous backward read is an intended
    /// re-anchor, not an accident. A non-contiguous read restarts the run. Demux-thread-only.
    private func detourTrackSequential(at offset: Int64, length: Int) {
        if offset == detourRunNextExpected {
            detourRunBytes += Int64(length)
        } else {
            detourRunBytes = Int64(length)
        }
        detourRunNextExpected = offset + Int64(length)
    }

    private func detourResetRun() {
        detourRunNextExpected = -1
        detourRunBytes = 0
    }

    // MARK: - Persistent Connection (lifecycle + delegate callbacks)

    /// Open a fresh Range: bytes=<offset>- connection. Bumps generation so
    /// late callbacks from the old connection are ignored.
    private func startPersistentConnection(at offset: Int64, boundedTo: Int64? = nil) {
        winCond.lock()
        connGeneration &+= 1
        let generation = connGeneration
        winStart = offset
        window = Data()
        connEnded = false
        connStatus = 0
        connRetryAfter = 0
        connStartedAt = DispatchTime.now()   // #93: time-to-first-data per generation
        connFirstDataSeen = false
        let oldSession = activeSession
        activeSession = nil
        activeTask = nil
        // Wake a backpressure-blocked old-gen delegate so it sees it is stale.
        winCond.broadcast()
        winCond.unlock()

        oldSession?.invalidateAndCancel()

        if isClosed { return }

        var request = URLRequest(url: requestURL())
        // #93 residual: a bounded open connection asks for a finite range so an origin that dribbles
        // the open-ended `bytes=0-` stream serves it as a fast finite GET. The 206 Content-Range still
        // carries the total size, so fileSize resolution (issue #70) is unaffected.
        if let boundedTo {
            request.setValue("bytes=\(offset)-\(offset + boundedTo - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        request.timeoutInterval = 0  // long-lived; stalls handled by the reader
        applyExtraHeaders(&request)

        let delegate = PersistentReadDelegate(
            reader: self,
            generation: generation,
            extraHeaders: extraHeaders
        )
        let session = URLSession(
            configuration: Self.makeSessionConfig(longLived: true),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)

        winCond.lock()
        // A close() that raced in bumped the generation; don't install a stale connection.
        guard generation == connGeneration, !isClosed else {
            winCond.unlock()
            session.invalidateAndCancel()
            return
        }
        activeSession = session
        activeTask = task
        winCond.unlock()

        task.resume()
        #if DEBUG
        EngineLog.emit("[AVIOReader] Persistent conn start gen=\(generation) offset=\(offset)", category: .demux)
        #endif
    }

    /// Force-copies `data` into the sliding window and applies backpressure by
    /// blocking until the consumer drains below winHighWater. Force-copy releases
    /// source dispatch_data per delivery (same leak control as the chunk path).
    fileprivate func appendPersistentData(_ data: Data, generation: Int) {
        winCond.lock()
        guard generation == connGeneration, !isFullyClosed else {
            // #93: a slow read's summary line reports how much data the stale-generation
            // guard discarded while the read waited.
            staleGenDroppedBytes += Int64(data.count)
            winCond.unlock()
            return
        }
        var firstDataMs: Double? = nil
        if !connFirstDataSeen {
            connFirstDataSeen = true
            firstDataMs = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds) / 1_000_000
        }
        let count = data.count
        let base = window.count
        window.count = base + count
        window.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                if let d = dst.baseAddress, let s = src.baseAddress {
                    (d + base).copyMemory(from: s, byteCount: count)
                }
            }
        }
        addBytesFetched(count)
        winCond.broadcast()
        // Backpressure: 0.2s timeout is belt-and-suspenders; correctness from broadcasts.
        while generation == connGeneration && !isClosed {
            let ahead = window.count - max(0, Int(position - winStart))
            if ahead <= Self.winHighWater { break }
            _ = winCond.wait(until: Date(timeIntervalSinceNow: 0.2))
        }
        winCond.unlock()
        if let firstDataMs {
            // #93/#96 residual: a slow first-data gap is release-visible so a device trace can pair it
            // with the response-header timing above. Small header gap + large first-data gap = the body
            // stalled after headers; large header gap = server-side connection queuing. Fast reads stay
            // on the DEBUG-only path to keep the release log quiet.
            if firstDataMs > 2000 {
                EngineLog.emit("[AVIOReader] gen=\(generation) first data after \(Int(firstDataMs))ms",
                               category: .demux)
            } else {
                #if DEBUG
                EngineLog.emit("[AVIOReader] gen=\(generation) first data after \(Int(firstDataMs))ms",
                               category: .demux)
                #endif
            }
        }
    }

    fileprivate func persistentReceivedResponse(
        _ http: HTTPURLResponse,
        resolvedURL: URL?,
        generation: Int
    ) -> Bool {
        let status = http.statusCode
        var isOK = status == 200 || status == 206
        var retryAfter: TimeInterval = 0
        if status == 429 || status == 503 {
            retryAfter = Self.parseRetryAfter(http)
        }
        var headerMs: Double? = nil
        winCond.lock()
        if generation == connGeneration {
            connStatus = status
            connRetryAfter = retryAfter
            // #93/#96 residual: time-to-first-response-header for this generation. A large value here
            // with a small subsequent first-data gap points at server-side connection queuing (the
            // origin accepted the socket but withheld the response while it served another connection
            // of the same file at full rate), the prime suspect for the ~15s cold reads.
            headerMs = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds) / 1_000_000
        }
        // VOD: 200 at offset > 0 means server ignored Range and sent the full body
        // from byte 0 (silent corruption). Reject it. Live is exempt: transcode
        // reconnect legitimately answers 200 with "from now".
        let requestedOffset = (generation == connGeneration) ? winStart : 0
        // Issue #70: the first from-0 data connection doubles as the size probe, so the
        // playback open skips probeFileSize() entirely. Derive the total from this
        // response (206 Content-Range, or Content-Length on a from-0 2xx). Write-once
        // (fileSize <= 0), current-gen only, and never for live (whose length is
        // non-authoritative). The response precedes any body and no read() reads fileSize
        // until open() returns, so this write is ordered behind winCond just like the data.
        if generation == connGeneration, !isLive, fileSize <= 0,
           let total = Self.sizeFromResponse(http, requestedOffset: requestedOffset) {
            fileSize = total
            // #112: share this resolved length so a later side demuxer on the same origin can skip a probe that
            // might be starved under this connection's load and would otherwise collapse it to forward-only.
            SourceContentLengthCache.store(total, for: url)
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(total) bytes (data connection)", category: .demux)
            #endif
        }
        winCond.unlock()
        if let headerMs, headerMs > 2000 {
            EngineLog.emit(
                "[AVIOReader] gen=\(generation) response headers after \(Int(headerMs))ms status=\(status)",
                category: .demux
            )
        }
        if status == 200 && requestedOffset > 0 && !isLive {
            EngineLog.emit(
                "[AVIOReader] server ignored Range (200 for offset \(requestedOffset)); rejecting body",
                category: .demux
            )
            isOK = false
        }

        if isOK {
            if let resolvedURL { recordResolvedURL(resolvedURL) }
            return true
        }
        if Self.isResolvedExpiryStatus(status) {
            invalidateResolvedURL()
        }
        return false
    }

    fileprivate func persistentConnectionEnded(error: Error?, generation: Int) {
        winCond.lock()
        let isCurrentGen = (generation == connGeneration)
        if isCurrentGen {
            connEnded = true
        }
        let windowAhead = isCurrentGen ? (window.count - max(0, Int(position - winStart))) : 0
        winCond.broadcast()
        winCond.unlock()
        if let error {
            EngineLog.emit("[AVIOReader] Persistent conn gen=\(generation) ended with error: \(error.localizedDescription)", category: .demux)
        }
        if isCurrentGen && isLive {
            EngineLog.emit("[AVIOReader] Live source: connection ended gen=\(generation) buffered=\(windowAhead / 1024)KB; reconnect will fire when buffer drains", category: .demux)
        }
    }

    /// Parses delta-seconds Retry-After; HTTP-date form falls back to expo backoff. Cap 15s.
    private static func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else {
            return 0
        }
        return min(max(seconds, 0), 15)
    }

    // MARK: - Streaming Download (background)

    private func startStreamingDownload() {
        prefetchQueue.async { [weak self] in
            self?.streamDownloadSync()
        }
    }

    private func streamDownloadSync() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 0  // No timeout for live streams
        applyExtraHeaders(&request)

        let semaphore = DispatchSemaphore(value: 0)

        let delegate = StreamingDelegate { [weak self] data in
            guard let self, !self.isClosed else { return }
            self.streamLock.lock()
            self.streamBuffer.append(data)
            // Backpressure: park the transfer once the retained buffer
            // exceeds the high water mark; readStreaming resumes it when
            // the consumer drains below the low water mark (and before
            // any wait, so a far-forward seek can't deadlock against a
            // suspended producer).
            var toSuspend: URLSessionDataTask?
            if !self.streamingTaskSuspended, self.streamBuffer.count > Self.streamHighWater {
                self.streamingTaskSuspended = true
                toSuspend = self.streamingTask
            }
            self.streamLock.unlock()
            toSuspend?.suspend()
            self.addBytesFetched(data.count)
            self.streamDataReady.signal()
        } onComplete: { [weak self] in
            self?.streamLock.lock()
            self?.streamEnded = true
            self?.streamLock.unlock()
            self?.streamDataReady.signal()
            semaphore.signal()
        }

        let streamSession = URLSession(
            configuration: Self.makeSessionConfig(longLived: true),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = streamSession.dataTask(with: request)

        // Register before resume so markClosed()/close() can cancel; re-check after.
        streamLock.lock()
        streamingSession = streamSession
        streamingTask = task
        streamLock.unlock()

        task.resume()
        if isClosed { task.cancel() }

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming started: \(url.lastPathComponent)", category: .demux)
        #endif

        semaphore.wait()

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming ended", category: .demux)
        #endif
        streamLock.lock()
        streamingSession = nil
        streamingTask = nil
        streamLock.unlock()
        streamSession.invalidateAndCancel()
    }

    // MARK: - Prefetch (background, seekable mode only)

    private func triggerPrefetch(from offset: Int64) {
        guard prefetchEnabled else { return }
        if fileSize > 0 && offset >= fileSize { return }

        bufferLock.lock()
        guard !isPrefetching else { bufferLock.unlock(); return }
        isPrefetching = true
        bufferLock.unlock()

        prefetchQueue.async { [weak self] in
            guard let self = self else { return }

            // Bail if close() ran to avoid writing stale data back into prefetchBuffer.
            if self.isFullyClosed {
                self.bufferLock.lock()
                self.isPrefetching = false
                self.bufferLock.unlock()
                self.prefetchReady.signal()
                return
            }

            let size: Int
            if self.fileSize > 0 {
                size = min(self.chunkSize, Int(self.fileSize - offset))
            } else {
                size = self.chunkSize
            }

            let data = size > 0 ? self.fetchChunk(from: offset, size: size) : nil

            self.bufferLock.lock()
            // Re-check: close() may have fired while fetchChunk was on the network.
            if !self.isFullyClosed {
                self.prefetchBuffer = data
                self.prefetchOffset = offset
            }
            self.isPrefetching = false
            self.bufferLock.unlock()

            self.prefetchReady.signal()
        }
    }

    // MARK: - Seek

    fileprivate func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == AVSEEK_SIZE { return fileSize }
        // For persistent mode, position is shared with the delegate thread;
        // read SEEK_CUR base under the window lock.
        let newPosition: Int64
        switch whence {
        case SEEK_SET:
            newPosition = offset
        case SEEK_CUR:
            if usePersistentReader {
                winCond.lock(); let cur = position; winCond.unlock()
                newPosition = cur + offset
            } else {
                newPosition = position + offset
            }
        case SEEK_END:
            guard fileSize >= 0 else { return -1 }
            newPosition = fileSize + offset
        default:
            return -1
        }

        if usePersistentReader {
            // Just move the cursor; the read loop decides whether to reconnect.
            // Coalesces the matroska seek-storm on open into minimal reconnects.
            winCond.lock()
            position = newPosition
            winCond.broadcast()
            winCond.unlock()
        } else if !isStreaming {
            position = newPosition
            bufferLock.lock()
            let inCurrent = position >= currentOffset &&
                position < currentOffset + Int64(currentBuffer.count)
            if !inCurrent {
                currentBuffer = Data()
                currentOffset = position
                prefetchBuffer = nil
            }
            bufferLock.unlock()
        } else {
            // Streaming: forward-only; backward seeks below the retained
            // window return failure so the demuxer doesn't silently wait 15s.
            streamLock.lock()
            let oldestRetained = streamBytesRead
            streamLock.unlock()
            if newPosition < oldestRetained { return -1 }
            position = newPosition
        }

        return newPosition
    }

    // MARK: - Network (seekable mode)

    /// Long-lived session for file-size probes. Per-request sessions force fresh TLS
    /// handshakes, which Cloudflare-fronted origins can flag as suspicious. Distinct
    /// from syncRequest's per-request pattern (load-bearing for chunk-fetch leak control).
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    /// Total size from a data-connection response: `Content-Range` total on a 206, or
    /// `Content-Length` on a from-0 2xx (origins that answer 200 ignoring Range). Nil when
    /// the origin gave no usable length (chunked, or an unknown `*` total). Issue #70.
    static func sizeFromResponse(_ http: HTTPURLResponse, requestedOffset: Int64) -> Int64? {
        // On a 206 the total lives ONLY in Content-Range; Content-Length is the partial span,
        // so a 206 with an unknown (`*`) or unparseable range must report no size, never fall
        // through to the partial length (issue #70 review #6).
        if http.statusCode == 206 {
            guard let cr = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = HTTPDiscIOReader.parseContentRangeTotal(cr), total > 0 else {
                return nil
            }
            return total
        }
        if (200...299).contains(http.statusCode), requestedOffset == 0,
           http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        return nil
    }

    /// #112: resolve the source length for the open, preferring a live probe and falling back to a length another
    /// demuxer already resolved for the same origin. A fresh probe here can be 429'd or answered without a length
    /// while the video producer is hammering the origin, which would drop this reader to forward-only streaming so
    /// every `avformat_seek_file` returns -1 and PGS reconstruction reads nothing. The producer's persistent open
    /// caches the real length (SourceContentLengthCache.store at the data-connection response), so a starved probe
    /// reuses it and stays byte-seekable. A successful probe also seeds the cache for whoever opens next.
    private func resolveInitialFileSize() -> Int64 {
        let probed = probeFileSize()
        if probed > 0 {
            SourceContentLengthCache.store(probed, for: url)
            return probed
        }
        if let cached = SourceContentLengthCache.lookup(url), cached > 0 {
            EngineLog.emit("[AVIOReader] size probe empty; reusing cached \(cached) bytes to keep seekability (#112)", category: .demux)
            return cached
        }
        return probed
    }

    private func probeFileSize() -> Int64 {
        // Range bytes=0- probe (AetherEngine#8: HEAD breaks on Cloudflare-fronted
        // origins returning 405). Without a known size, streaming mode is used and
        // SEEK_SET/SEEK_END return -1, breaking MKV/AVI index seeks and scrubbing.
        if let size = rangeProbeFileSize(), size > 0 {
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(size) bytes (Range probe)", category: .demux)
            #endif
            return size
        }
        return headProbeFileSize()
    }

    /// Open-ended Range bytes=0- GET cancelled at didReceive response (no body transfers).
    /// Returns the total from Content-Range on 206, or expectedContentLength on 2xx (origins
    /// that ignore Range). bytes=0- over bytes=0-0: some origins special-case the single-byte
    /// form and omit length, then 429 the HEAD fallback (issue #70); bytes=0- answers with a
    /// proper Content-Range in one shot.
    private func rangeProbeFileSize() -> Int64? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        applyExtraHeaders(&request)

        let delegate = ProbeDelegate(extraHeaders: extraHeaders)
        let task = Self.probeSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        // Bound + make abortable: still extraction caps this at its small budget so a
        // reopen mid-scrub on a stalled source can't park ~25s, and a teardown during
        // open returns at once (issue #27). Playback keeps its 25s ceiling.
        let probeBudget = min(25, chunkRequestTimeout)
        if Self.awaitSignal(semaphore, budget: probeBudget, pollInterval: 0.1,
                            shouldAbort: { [weak self] in self?.isClosed == true }) != .signaled {
            task.cancel()
            EngineLog.emit("[AVIOReader] Range probe timed out, trying HEAD", category: .demux, level: .verbose)
            return nil
        }

        if delegate.totalSize == nil {
            EngineLog.emit("[AVIOReader] Range probe didn't yield a size, trying HEAD", category: .demux, level: .verbose)
        }
        return delegate.totalSize
    }

    /// HEAD probe fallback for live-transcode endpoints that reject Range.
    private func headProbeFileSize() -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        applyExtraHeaders(&request)

        do {
            // Honour the still budget here too so the open-time HEAD fallback can't
            // ride the default 35s on a stalled origin during a cold/reopen scrub (#27).
            let (_, response) = try syncRequest(request, budget: chunkRequestTimeout)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                EngineLog.emit("[AVIOReader] HEAD failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)), streaming mode", category: .demux, level: .verbose)
                return -1
            }
            let length = http.expectedContentLength
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(length) bytes (HEAD fallback)\(length <= 0 ? " streaming mode" : "")", category: .demux)
            #endif
            return length
        } catch {
            EngineLog.emit("[AVIOReader] HEAD probe failed: \(error.localizedDescription), streaming mode", category: .demux, level: .verbose)
            return -1
        }
    }

    private func fetchChunk(from offset: Int64, size: Int) -> Data? {
        if let data = fetchChunkAttempt(from: offset, size: size, forceSource: false) {
            return data
        }
        // Retry against source URL only if a cached resolved URL was used
        // (so the proxy can re-issue a fresh signed redirect).
        if cachedResolvedURL() != nil {
            return fetchChunkAttempt(from: offset, size: size, forceSource: true)
        }
        return nil
    }

    private func fetchChunkAttempt(from offset: Int64, size: Int, forceSource: Bool) -> Data? {
        let usingCachedURL = !forceSource && cachedResolvedURL() != nil
        let target = forceSource ? url : requestURL()
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: target)
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = min(15, chunkRequestTimeout)
        applyExtraHeaders(&request)

        var lastError: Error?
        for attempt in 0..<chunkMaxRetries {
            do {
                let (data, response) = try syncRequest(request, budget: chunkRequestTimeout)
                if let http = response as? HTTPURLResponse {
                    let status = http.statusCode
                    if status != 200 && status != 206 {
                        if usingCachedURL && Self.isResolvedExpiryStatus(status) {
                            invalidateResolvedURL()
                        }
                        EngineLog.emit("[AVIOReader] chunk fetch got HTTP \(status) at offset \(offset)\(usingCachedURL ? " (cached URL, will retry source)" : "")", category: .demux, level: .verbose)
                        return nil
                    }
                    // VOD: 200 at offset > 0 = server ignored Range; silent corruption. Reject.
                    if status == 200 && offset > 0 && !isLive {
                        EngineLog.emit(
                            "[AVIOReader] server ignored Range (200 for offset \(offset)); rejecting chunk",
                            category: .demux
                        )
                        return nil
                    }
                }
                addBytesFetched(data.count)
                return data
            } catch {
                // Superseded / closed / past the read deadline: this read is disposable,
                // bail at once instead of retrying into the abort (issue #27).
                if isClosed || isPastReadDeadline { return nil }
                lastError = error
                if attempt < chunkMaxRetries - 1 {
                    Thread.sleep(forTimeInterval: Double(1 << attempt) * 0.5)
                }
            }
        }

        EngineLog.emit("[AVIOReader] Fetch failed after \(chunkMaxRetries) retries at offset \(offset): \(lastError?.localizedDescription ?? "?")", category: .demux, level: .verbose)
        return nil
    }

    /// Long-lived session for seekable-path chunk fetches paired with per-task
    /// ChunkFetchDelegate. Delegate-based incremental delivery (not completion-handler)
    /// releases source dispatch_data per delivery, avoiding the task-pool accumulation
    /// that drove the original leak (completion-handler style). No invalidation overhead.
    private static let chunkSession: URLSession = {
        let config = makeSessionConfig()
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    /// Outcome of an abortable semaphore wait (issue #27).
    enum WaitOutcome: Equatable { case signaled, timedOut, aborted }

    /// Wait on `semaphore` up to `budget` seconds, polling `shouldAbort` every
    /// `pollInterval`. Returns `.signaled` the moment the semaphore fires,
    /// `.aborted` within one poll of `shouldAbort()` going true, or `.timedOut`
    /// when the budget elapses. Lets a seekable chunk read bail promptly on
    /// supersede / close / read-deadline instead of parking the decode queue in a
    /// flat 35s wait (the root cause of the frozen scrub preview, issue #27).
    static func awaitSignal(
        _ semaphore: DispatchSemaphore,
        budget: TimeInterval,
        pollInterval: TimeInterval,
        shouldAbort: () -> Bool
    ) -> WaitOutcome {
        let deadline = Date(timeIntervalSinceNow: budget)
        while true {
            if shouldAbort() { return .aborted }
            let now = Date()
            if now >= deadline { return .timedOut }
            let slice = min(pollInterval, deadline.timeIntervalSince(now))
            if semaphore.wait(timeout: .now() + max(0.001, slice)) == .success {
                return .signaled
            }
        }
    }

    private func syncRequest(_ request: URLRequest, budget: TimeInterval = 35) throws -> (Data, URLResponse) {
        let delegate = ChunkFetchDelegate(extraHeaders: extraHeaders)
        let task = Self.chunkSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        // Poll for close / read-deadline so a superseded or torn-down still-extraction
        // read aborts within ~100ms instead of riding the full budget (issue #27).
        let outcome = Self.awaitSignal(
            semaphore, budget: budget, pollInterval: 0.1,
            shouldAbort: { [weak self] in self?.isClosed == true || self?.isPastReadDeadline == true }
        )
        guard outcome == .signaled else {
            task.cancel()
            throw AVIOReaderError.requestTimeout
        }

        if let err = delegate.error { throw err }
        guard let response = delegate.response else { throw AVIOReaderError.noResponse }
        return (delegate.body, response)
    }
}

// MARK: - Detour Block Cache

/// Fixed-block LRU cache backing the persistent reader's detour path (AetherEngine#69). Random-access
/// parse reads on a non-faststart remote MP4 are served from here over the pooled keep-alive session
/// instead of tearing down the anchored streaming connection. Thread-safe via a single leaf lock
/// (demux-thread reads + teardown-thread `clear`); never held across the network. Stores only
/// full-size blocks (the fetch/insert decision is the caller's), so eviction can't shadow a
/// re-fetchable short-body tail. The copy + eviction math is pure and unit-tested without a network.
final class DetourBlockCache: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    private var lru: [Int64] = []
    private let maxBlocks: Int
    let blockSize: Int

    init(blockSize: Int, maxBlocks: Int) {
        self.blockSize = blockSize
        self.maxBlocks = maxBlocks
    }

    /// Returns the resident block for `idx` and bumps its recency, or nil on a miss.
    func block(_ idx: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = blocks[idx] else { return nil }
        if let i = lru.firstIndex(of: idx) {
            lru.remove(at: i)
            lru.append(idx)
        }
        return data
    }

    /// Inserts a (full-size) block, evicting the least-recently-used tail beyond `maxBlocks`.
    func insert(_ idx: Int64, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if blocks[idx] == nil { lru.append(idx) }
        blocks[idx] = data
        while lru.count > maxBlocks {
            blocks.removeValue(forKey: lru.removeFirst())
        }
    }

    func clear() {
        lock.lock()
        blocks.removeAll()
        lru.removeAll()
        lock.unlock()
    }

    var residentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return blocks.count
    }

    /// Copy up to `maxLen` bytes covering `offset` from the resident block into `dst`, returning the
    /// byte count. Returns nil if the covering block is not resident, or if `offset` lands in the
    /// uncovered tail of a short block (so the caller re-fetches rather than serving stale bytes).
    /// One call serves at most to the block boundary; a read spanning blocks is driven by the caller
    /// re-entering at the advanced offset. Pure given the cache contents; bumps recency on a hit.
    func serveCached(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int, at offset: Int64) -> Int? {
        guard maxLen > 0, offset >= 0 else { return nil }
        let idx = offset / Int64(blockSize)
        let blockStart = idx * Int64(blockSize)
        guard let blk = block(idx) else { return nil }
        let inBlock = Int(offset - blockStart)
        guard inBlock >= 0, inBlock < blk.count else { return nil }
        let n = min(maxLen, blk.count - inBlock)
        blk.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inBlock).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return n
    }
}

/// Preserves Range + extra headers across cross-host redirects. URLSession strips
/// custom headers on host change; without this, CDN behind AIOStreams proxy gets a
/// plain GET and either streams the full body or 400s.
private func redirectPreservingHeaders(
    task: URLSessionTask,
    newRequest request: URLRequest,
    extraHeaders: [String: String]
) -> URLRequest {
    var updated = request
    if let originalRange = task.originalRequest?.value(forHTTPHeaderField: "Range") {
        updated.setValue(originalRange, forHTTPHeaderField: "Range")
    }
    for (name, value) in extraHeaders {
        updated.setValue(value, forHTTPHeaderField: name)
    }
    return updated
}

// MARK: - Persistent Read Delegate

/// Forwards deliveries into the reader's sliding window with generation tagging
/// so stale-connection late callbacks are no-ops. @unchecked Sendable: only
/// mutable coupling is weak reader, guarded by winCond.
private final class PersistentReadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var reader: AVIOReader?
    let generation: Int
    let extraHeaders: [String: String]

    init(reader: AVIOReader, generation: Int, extraHeaders: [String: String]) {
        self.reader = reader
        self.generation = generation
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let reader else {
            completionHandler(.cancel)
            return
        }
        let resolved = (http.statusCode == 200 || http.statusCode == 206)
            ? dataTask.currentRequest?.url
            : nil
        let allow = reader.persistentReceivedResponse(
            http, resolvedURL: resolved, generation: generation
        )
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        reader?.appendPersistentData(data, generation: generation)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        reader?.persistentConnectionEnded(error: error, generation: generation)
    }
}

// MARK: - Chunk Fetch Delegate

/// Single-use per fetch; force-copies each delivery into `body` so source
/// dispatch_data is released per delivery. @unchecked Sendable: ownership
/// via semaphore ensures no concurrent access to mutable fields.
private final class ChunkFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var body = Data()
    var response: URLResponse?
    var error: Error?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String]) {
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        if let http = response as? HTTPURLResponse {
            let len = Int(http.expectedContentLength)
            if len > 0 { body.reserveCapacity(len) }
            let status = http.statusCode
            if status == 200 || status == 206,
               let resolved = dataTask.currentRequest?.url {
                onResolved?(resolved)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Force-copy: body.append(data) may retain source dispatch_data via CoW,
        // defeating the per-delivery release. Manual memcpy guarantees drop on return.
        let count = data.count
        let baseCount = body.count
        body.count = baseCount + count
        body.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                if let dstBase = dst.baseAddress, let srcBase = src.baseAddress {
                    (dstBase + baseCount).copyMemory(from: srcBase, byteCount: count)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        self.error = error
        onCompletion?()
    }
}

// MARK: - Streaming Delegate

private final class StreamingDelegate: NSObject, URLSessionDataDelegate {
    let onData: @Sendable (Data) -> Void
    let onComplete: @Sendable () -> Void

    init(onData: @escaping @Sendable (Data) -> Void, onComplete: @escaping @Sendable () -> Void) {
        self.onData = onData
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        #if DEBUG
        if let error {
            EngineLog.emit("[AVIOReader] Stream error: \(error.localizedDescription)", category: .demux)
        }
        #endif
        onComplete()
    }
}

// MARK: - Probe Delegate

/// File-size Range probe delegate. Preserves Range across cross-host redirects,
/// captures total from Content-Range, cancels before the body streams.
/// @unchecked Sendable: single-use per probe, semaphore ownership prevents concurrency.
private final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var totalSize: Int64?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String]) {
        self.extraHeaders = extraHeaders
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        defer { completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else { return }
        let status = http.statusCode
        if (200...299).contains(status), let resolved = dataTask.currentRequest?.url {
            onResolved?(resolved)
        }
        // The probe requests `bytes=0-`, so requestedOffset is 0. Shared with the
        // data-connection path so a 206 with an unknown (`*`) total never reports its
        // partial Content-Length as the size (issue #70 review #6).
        totalSize = AVIOReader.sizeFromResponse(http, requestedOffset: 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?()
    }
}

// MARK: - C Callbacks


// AVERROR(EIO) = -5: live source lost (distinct from AVERROR_EOF).
private let AVERROR_EIO_VALUE: Int32 = -5

private func readCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.read(into: buf, size: size)
}

private func seekCallback(
    opaque: UnsafeMutableRawPointer?,
    offset: Int64,
    whence: Int32
) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.seek(offset: offset, whence: whence)
}

// MARK: - Errors

enum AVIOReaderError: Error, CustomStringConvertible {
    case allocationFailed
    case noResponse
    case requestTimeout

    var description: String {
        switch self {
        case .allocationFailed: return "Failed to allocate AVIO buffer"
        case .noResponse: return "No response from server"
        case .requestTimeout: return "Request timed out"
        }
    }
}
