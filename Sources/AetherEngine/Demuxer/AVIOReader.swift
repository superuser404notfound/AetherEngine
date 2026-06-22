import Foundation
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
        // No URLCache instance — kills the in-memory cache that the
        // long-lived-session fix from fef8ef4 was working around.
        config.urlCache = nil
        return config
    }
    private var position: Int64 = 0
    private var fileSize: Int64 = -1

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
    // Consecutive unproductive reconnects (demux-thread-only).
    private var unproductiveReconnects = 0
    private var bytesAtLastReconnect: Int64 = 0

    /// Playback path (known size + prefetch) or live feeds. Live always uses the
    /// persistent reader; the streaming reader has no reconnect machinery.
    private var usePersistentReader: Bool {
        if isLive { return prefetchEnabled }
        return !isStreaming && prefetchEnabled
    }

    /// True for endless live feeds. Suppresses `position >= fileSize` EOF synthesis;
    /// reports EIO (-5) instead of EOF when the reconnect cap is hit.
    let isLive: Bool

    /// Timestamp of the last unplanned reconnect (drop/stall, not a seek).
    /// Producer correlates with a backward source-PTS reset to detect Jellyfin
    /// transcode respawn (re-serves from byte 0 on re-GET, invisible at byte level).
    /// Demux-thread-only (AVIO callback executes synchronously inside av_read_frame).
    private(set) var lastUnplannedReconnectAt: Date?

    init(url: URL, extraHeaders: [String: String] = [:], chunkSize: Int = 4 * 1024 * 1024, prefetchEnabled: Bool = true, isLive: Bool = false) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.chunkSize = chunkSize
        self.prefetchEnabled = prefetchEnabled
        self.isLive = isLive
    }

    private func applyExtraHeaders(_ request: inout URLRequest) {
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    func open() throws {
        fileSize = probeFileSize()

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

        if usePersistentReader {
            startPersistentConnection(at: 0)
            winCond.lock()
            let deadline = Date(timeIntervalSinceNow: 15)
            while window.isEmpty && !connEnded && !isClosed {
                if !winCond.wait(until: deadline) { break }
            }
            let gotData = !window.isEmpty
            winCond.unlock()
            if !gotData {
                // No first byte within 15s; read loop's stall/reconnect machinery takes over.
                EngineLog.emit("[AVIOReader] Persistent open: no data within 15s, proceeding to read-loop reconnect", category: .demux)
            }
        } else if isStreaming {
            startStreamingDownload()
            _ = streamDataReady.wait(timeout: .now() + .seconds(15))
        } else {
            if let data = fetchChunk(from: 0, size: chunkSize) {
                currentBuffer = data
                currentOffset = 0
            }
        }
    }

    private var isClosed = false
    private var isFullyClosed = false

    /// Wall-clock deadline for reads. Armed by `beginReadDeadline` to abort
    /// a `avformat_seek_file` that degrades into a linear scan when MKV Cues
    /// index is missing or past EOF (tens of minutes on remote sources).
    private var readDeadline = Date.distantFuture
    private var isPastReadDeadline: Bool { Date() >= readDeadline }
    /// Set when a read returned early due to deadline. `seekBounded` uses this
    /// since matroska may still return success with a partial index after abort.
    private(set) var readDeadlineFired = false

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

    /// Unblock a suspended av_read_frame without freeing resources.
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
        winCond.broadcast()
        winCond.unlock()
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
        if usePersistentReader { return readPersistent(into: buf, size: size) }
        if isStreaming { return readStreaming(into: buf, size: size) }
        return readSeekable(into: buf, size: size)
    }

    // MARK: - Seekable Read (Range-based)

    private func readSeekable(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
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

        while totalRead < requestSize {
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if isPastReadDeadline { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            winCond.lock()

            if activeTask == nil {
                let target = position
                winCond.unlock()
                seekReconnect(at: target)
                continue
            }

            let curPosition = position

            if curPosition < winStart {
                winCond.unlock()
                seekReconnect(at: curPosition)
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
                seekReconnect(at: curPosition)
                continue
            }

            if !ended {
                // Wait for the live connection to fill forward. A false return
                // means connStallTimeout elapsed with no data (socket stall).
                let signaled = winCond.wait(until: min(Date(timeIntervalSinceNow: Self.connStallTimeout), readDeadline))
                winCond.unlock()
                // Check deadline before stall handling to avoid misrouting a
                // deadline wake as a socket stall (which would reconnect).
                if isPastReadDeadline { continue }
                if !signaled {
                    if recordReconnectAndShouldGiveUp() {
                        EngineLog.emit("[AVIOReader] Persistent stall gave up at offset \(frontier) (\(unproductiveReconnects) unproductive)\(isLive ? " [live source lost]" : "")", category: .demux)
                        if isLive {
                            return totalRead > 0 ? Int32(totalRead) : AVERROR_EIO_VALUE
                        }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    EngineLog.emit("[AVIOReader] Persistent stall at offset \(frontier), reconnecting", category: .demux)
                    lastUnplannedReconnectAt = Date()
                    backoffBeforeReconnect(streak: unproductiveReconnects, retryAfter: 0)
                    startPersistentConnection(at: frontier)
                }
                continue
            }

            // Connection ended before EOF; reconnect at frontier. Honour Retry-After for 429/503.
            winCond.unlock()
            if recordReconnectAndShouldGiveUp(status: status) {
                EngineLog.emit("[AVIOReader] Persistent reconnect exhausted at offset \(frontier) status=\(status) (\(unproductiveReconnects) unproductive)\(isLive ? " [live source lost]" : "")", category: .demux)
                if isLive {
                    return totalRead > 0 ? Int32(totalRead) : AVERROR_EIO_VALUE
                }
                return totalRead > 0 ? Int32(totalRead) : -1
            }
            EngineLog.emit("[AVIOReader] Persistent conn ended at offset \(frontier) status=\(status), reconnecting (streak=\(unproductiveReconnects) retryAfter=\(retryAfter)s)", category: .demux)
            lastUnplannedReconnectAt = Date()
            backoffBeforeReconnect(streak: unproductiveReconnects, retryAfter: retryAfter)
            startPersistentConnection(at: frontier)
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

    // MARK: - Persistent Connection (lifecycle + delegate callbacks)

    /// Open a fresh Range: bytes=<offset>- connection. Bumps generation so
    /// late callbacks from the old connection are ignored.
    private func startPersistentConnection(at offset: Int64) {
        winCond.lock()
        connGeneration &+= 1
        let generation = connGeneration
        winStart = offset
        window = Data()
        connEnded = false
        connStatus = 0
        connRetryAfter = 0
        let oldSession = activeSession
        activeSession = nil
        activeTask = nil
        // Wake a backpressure-blocked old-gen delegate so it sees it is stale.
        winCond.broadcast()
        winCond.unlock()

        oldSession?.invalidateAndCancel()

        if isClosed { return }

        var request = URLRequest(url: requestURL())
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
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
            winCond.unlock()
            return
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
        winCond.lock()
        if generation == connGeneration {
            connStatus = status
            connRetryAfter = retryAfter
        }
        // VOD: 200 at offset > 0 means server ignored Range and sent the full body
        // from byte 0 (silent corruption). Reject it. Live is exempt: transcode
        // reconnect legitimately answers 200 with "from now".
        let requestedOffset = (generation == connGeneration) ? winStart : 0
        winCond.unlock()
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

    private func probeFileSize() -> Int64 {
        // Range bytes=0-0 probe (AetherEngine#8: HEAD breaks on Cloudflare-fronted
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

    /// Range bytes=0-0 GET cancelled at didReceive response. Returns total from
    /// Content-Range on 206, or expectedContentLength on 2xx (origins that ignore Range).
    private func rangeProbeFileSize() -> Int64? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
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

        if semaphore.wait(timeout: .now() + .seconds(25)) == .timedOut {
            task.cancel()
            #if DEBUG
            EngineLog.emit("[AVIOReader] Range probe timed out → trying HEAD", category: .demux)
            #endif
            return nil
        }

        if delegate.totalSize == nil {
            #if DEBUG
            EngineLog.emit("[AVIOReader] Range probe didn't yield a size → trying HEAD", category: .demux)
            #endif
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
            let (_, response) = try syncRequest(request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                #if DEBUG
                EngineLog.emit("[AVIOReader] HEAD failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)) → streaming mode", category: .demux)
                #endif
                return -1
            }
            let length = http.expectedContentLength
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(length) bytes (HEAD fallback)\(length <= 0 ? " streaming mode" : "")", category: .demux)
            #endif
            return length
        } catch {
            #if DEBUG
            EngineLog.emit("[AVIOReader] HEAD probe failed: \(error.localizedDescription) → streaming mode", category: .demux)
            #endif
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
        request.timeoutInterval = 15
        applyExtraHeaders(&request)

        var lastError: Error?
        for attempt in 0..<Self.maxRetries {
            do {
                let (data, response) = try syncRequest(request)
                if let http = response as? HTTPURLResponse {
                    let status = http.statusCode
                    if status != 200 && status != 206 {
                        if usingCachedURL && Self.isResolvedExpiryStatus(status) {
                            invalidateResolvedURL()
                        }
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
                lastError = error
                if attempt < Self.maxRetries - 1 {
                    Thread.sleep(forTimeInterval: Double(1 << attempt) * 0.5)
                }
            }
        }

        #if DEBUG
        EngineLog.emit("[AVIOReader] Fetch failed after \(Self.maxRetries) retries at offset \(offset): \(lastError?.localizedDescription ?? "?")", category: .demux)
        #endif
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

    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        let delegate = ChunkFetchDelegate(extraHeaders: extraHeaders)
        let task = Self.chunkSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        if semaphore.wait(timeout: .now() + .seconds(35)) == .timedOut {
            task.cancel()
            throw AVIOReaderError.requestTimeout
        }

        if let err = delegate.error { throw err }
        guard let response = delegate.response else { throw AVIOReaderError.noResponse }
        return (delegate.body, response)
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
        if (status == 206 || (200...299).contains(status)),
           let resolved = dataTask.currentRequest?.url {
            onResolved?(resolved)
        }
        if status == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.firstIndex(of: "/") {
            let totalString = contentRange[contentRange.index(after: slash)...]
            if totalString != "*", let size = Int64(totalString) {
                totalSize = size
                return
            }
        }
        if (200...299).contains(status), http.expectedContentLength > 0 {
            totalSize = http.expectedContentLength
        }
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
