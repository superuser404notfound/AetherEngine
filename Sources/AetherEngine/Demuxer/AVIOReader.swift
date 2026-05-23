import Foundation
import Libavformat
import Libavutil

/// Custom AVIO context that feeds data to FFmpeg via URLSession.
///
/// Two modes:
/// - **Seekable** (file size known): HTTP Range requests with double-buffering.
///   Used for direct play of complete files.
/// - **Streaming** (file size unknown/-1): Single GET request, sequential reads.
///   Used for live transcoded streams from Jellyfin.
///
/// Thread safety: AVIO callbacks run on the demux queue. Prefetch/streaming
/// runs on a dedicated background queue. Shared state protected by locks.
final class AVIOReader: @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    /// Configuration template for per-request sessions. We do NOT
    /// share a long-lived URLSession across Range fetches: every
    /// completed dataTask sits inside the session's internal task
    /// list (Foundation's "completed-task pool") until the session
    /// is invalidated, retaining its 8 MB `dispatch_data_t` response
    /// body the whole time. With long-lived sessions playing a 4K
    /// HDR HEVC source at ~25 Mbps that pool grows at ~5 MB/s of
    /// heap, which is exactly the residual leak we chased after the
    /// urlCache=nil fix.
    ///
    /// Per-request sessions used to be unsafe because each
    /// configuration spun up its own URLCache (the "N URLCaches
    /// racing async invalidation" reverted in fef8ef4). Setting
    /// `config.urlCache = nil` removes the URLCache entirely, which
    /// makes per-request sessions safe again: each fetch creates a
    /// session with no URLCache, completes, and is dismantled via
    /// finishTasksAndInvalidate so the task pool releases its
    /// response data immediately.
    private static func makeSessionConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // No URLCache instance — kills the in-memory cache that the
        // long-lived-session fix from fef8ef4 was working around.
        config.urlCache = nil
        return config
    }
    private var position: Int64 = 0
    private var fileSize: Int64 = -1

    /// Final URL after the first request's redirect chain resolved.
    /// Used for subsequent Range / probe fetches so we skip the proxy
    /// → CDN redirect hop on every chunk. Nil until a request
    /// completes with a 2xx/206 response whose `currentRequest.url`
    /// differs from the caller-supplied `url`.
    ///
    /// Auth-expiry statuses (401/403/404/410) against the resolved
    /// URL drop the cache and retry once against the original source
    /// URL so the proxy can re-issue a fresh signed redirect. See
    /// AetherEngine#12.
    private let resolvedURLLock = NSLock()
    private var _resolvedURL: URL?

    /// URL to use for the next request: the cached resolved CDN URL
    /// when available, otherwise the caller-provided source URL.
    private func requestURL() -> URL {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL ?? url
    }

    /// Snapshot of the current cached resolved URL, or nil if none.
    /// Used to distinguish "request hit the cached URL" from "request
    /// hit the source URL" so the auth-expiry fallback only triggers
    /// for the former.
    private func cachedResolvedURL() -> URL? {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL
    }

    /// Cache the resolved URL after a successful response. Called from
    /// the per-task delegates' `didReceive response` with the task's
    /// `currentRequest.url` (the URL after the redirect chain). No-op
    /// when the resolved URL equals the source URL (no redirect
    /// happened) or matches an already-cached value.
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

    /// Drop the cached resolved URL so the next request goes through
    /// the source URL and re-resolves. Called when a request against
    /// the cached URL returned an auth-expiry-like status.
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

    /// Status codes that mean "the cached signed URL has expired or
    /// is no longer authoritative; retry against the source URL".
    private static func isResolvedExpiryStatus(_ status: Int) -> Bool {
        return status == 401 || status == 403 || status == 404 || status == 410
    }

    /// Cumulative bytes returned by every `fetchChunk` (seekable mode)
    /// and `StreamingDelegate.didReceive` (streaming mode) since the
    /// reader was opened. Read by the engine's memory probe to compare
    /// against RSS growth — if RSS climbs faster than this counter,
    /// the leak is downstream of the network read (AVPlayer, IOSurface,
    /// Foundation cache, etc.). Atomic via `counterLock`.
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

    /// True when the source is a live stream (no Content-Length).
    private var isStreaming: Bool { fileSize <= 0 }

    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var buffer: UnsafeMutablePointer<UInt8>?

    // MARK: - Seekable Mode (Range requests)

    /// Settled chunk size: 4 MB.
    ///
    /// Field-validated 2026-05-22: paired with the delegate-based
    /// fetch path (`chunkSession` + `ChunkFetchDelegate`), 4 MB
    /// chunks stay bounded through 5+ min runs and deliver ~0.7 s
    /// cold-start chunk wait on 45 Mbps 4K HEVC (versus ~1.4 s at
    /// 8 MB, ~10 s at the historic 64 MB). Promoted from PROBE to
    /// shipped after field validation confirmed no leak at the
    /// 4 MB / ~1.4 ops/sec cadence.
    ///
    /// Why this works at any chunk size (where the historic 8 MB
    /// attempt leaked): delegate-based incremental delivery doesn't
    /// accumulate a monolithic response body in URLSession's task
    /// object. Each chunk is force-copied into the delegate's body
    /// buffer per `urlSession(_:dataTask:didReceive data:)` call,
    /// and URLSession releases the source dispatch_data after the
    /// delegate ack returns. No per-request `finishTasksAndInvalidate`
    /// either (shared session), so no invalidation backlog at high
    /// fetch frequency.
    ///
    /// Why not even smaller (2 MB / 1 MB): diminishing returns. From
    /// 8 MB → 4 MB the cold-start improved noticeably; from 4 MB →
    /// 2 MB the gain is sub-0.5 s while HTTP roundtrip overhead at
    /// 5+ ops/sec on remote CDN starts adding 50-275 ms/sec of
    /// server processing time per playback second. Not worth it.
    ///
    /// Why the previous 8 MB attempt (e327e5e) leaked at 6 MB/sec
    /// where this one doesn't: the old path used per-request
    /// URLSession + completion-handler, and URLSession's task object
    /// holds the monolithic response body in its internal state past
    /// the handler invocation until `finishTasksAndInvalidate`
    /// finishes (async). At 6 fetches/sec the pool of pending
    /// sessions piled up faster than invalidation could drain. The
    /// new path skips invalidation entirely: a shared long-lived
    /// session, incremental delivery to a delegate that force-copies
    /// each chunk, source dispatch_data released per delivery. No
    /// monolithic body, no accumulation.
    ///
    /// Trade-off captured: cold-start fetches 8 MB at source bitrate
    /// (~1 s on 50 Mbps 4K HEVC, vs ~10 s at 64 MB). Steady-state
    /// URLSession ops at ~0.8/sec for 50 Mbps source, handled by the
    /// shared session's TCP connection pool without per-fetch
    /// handshake cost.
    ///
    /// History of this knob:
    ///   - Long-form leak investigation A/B (with the periodic
    ///     demuxer recycle still active):
    ///       8 MB chunks  → 3.20 MB/s leak
    ///       64 MB chunks → 0.64 MB/s leak
    ///       256 MB chunks → 4.85 MB/s leak + memory warnings
    ///   - 1ee963d removed the recycle and the recycle race that
    ///     drove the bulk of the per-chunk retention. Bounded
    ///     mallocMB (211-291 MB oscillation through 11-min runs)
    ///     was field-measured at 64 MB chunks post-recycle-removal.
    ///   - e327e5e (2026-05-22) drop to 8 MB on the assumption that
    ///     "chunk size doesn't affect leak control after the
    ///     recycle is gone". That assumption was wrong: at 8 MB +
    ///     ~6 ops/sec at 4K HEVC bitrates, the per-request URLSession
    ///     `finishTasksAndInvalidate` (async by design) doesn't
    ///     complete between requests. URLSession instances and
    ///     their internal pools accumulate, and `mallocMB` grows
    ///     linearly at the source bitrate (~6 MB/s on a 50 Mbps
    ///     stream). Reverted to 64 MB after a 5-min Harry Potter
    ///     run hit 1.9 GB / 1.8 GB jetsam range.
    ///
    /// Why 64 MB works where 8 MB doesn't:
    ///   - URLSession ops drop from ~6/sec to ~0.8/sec
    ///   - finishTasksAndInvalidate has time to complete between
    ///     fetches, so the pool of pending sessions stays at ~1-2
    ///     instead of climbing to dozens
    ///   - Per-chunk dispatch_data still goes through force-copy
    ///     (heap-independent Data), so the per-fetch retention is
    ///     bounded; the multiplier was the pool accumulation, not
    ///     individual fetches leaking more
    ///
    /// Cost: cold-start fetches one 64 MB chunk before AVPlayer can
    /// open the asset. At 50 Mbps source bitrate ≈ ~10 s wait.
    /// Partially recovered by 6783036 (probe Demuxer reuse, saves
    /// 1-3 s by skipping the second avformat_find_stream_info), so
    /// effective cold-start is ~6-8 s versus the pre-fixes ~10 s+.
    ///
    /// Future optimisation paths (not implemented):
    ///   - Asymmetric: small first chunk (4 MB ≈ 0.6 s wait) for
    ///     fast startup, large subsequent chunks (64 MB) for low
    ///     ops/sec. Requires tracking "is this the first fetch" in
    ///     the reader.
    ///   - Single long-lived URLSession with per-task delegate
    ///     instead of per-request session. Eliminates the
    ///     invalidation backlog entirely. Risk: returns to the
    ///     historic dispatch_data task-pool retention pattern;
    ///     would need re-validating that force-copy makes the pool
    ///     drop bytes promptly enough.
    ///   - Bounded pool of N reusable URLSessions, round-robin.
    private static let chunkSize = 4 * 1024 * 1024  // 4 MB per chunk
    private static let avioBufferSize: Int32 = 256 * 1024  // 256 KB
    private static let streamTrimThreshold = 1024 * 1024  // 1 MB, keep for small backward seeks

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

    /// Growing buffer fed by the streaming task, read by FFmpeg.
    private var streamBuffer = Data()
    private var streamBytesRead: Int64 = 0
    private var streamEnded = false
    private let streamLock = NSLock()
    private let streamDataReady = DispatchSemaphore(value: 0)

    init(url: URL, extraHeaders: [String: String] = [:]) {
        self.url = url
        self.extraHeaders = extraHeaders
    }

    /// Apply the caller-supplied extra headers to a request. Used by
    /// every site that builds a URLRequest against the source URL
    /// (probe HEAD, Range fetch, streaming GET) so auth headers flow
    /// consistently. Range / method / timeout are set elsewhere and
    /// not overridden here.
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

        if isStreaming {
            // Streaming mode: start a continuous GET request in background.
            // Data accumulates in streamBuffer, read() serves from it.
            startStreamingDownload()
            // Wait for initial data before returning
            _ = streamDataReady.wait(timeout: .now() + .seconds(15))
        } else {
            // Seekable mode: pre-fill the first chunk with a Range request
            if let data = fetchChunk(from: 0, size: Self.chunkSize) {
                currentBuffer = data
                currentOffset = 0
                triggerPrefetch(from: Int64(data.count))
            }
        }
    }

    private var isClosed = false
    private var isFullyClosed = false

    /// Mark as closed without freeing resources. The AVIO read callback
    /// checks this flag and returns -1 immediately, which causes
    /// av_read_frame to return an error and unblock the demux thread.
    /// Call this BEFORE acquiring the demuxer's access lock to prevent
    /// deadlock when the demux thread is suspended inside av_read_frame.
    func markClosed() {
        isClosed = true
        // Wake any semaphore waits so the read callbacks can exit
        prefetchReady.signal()
        streamDataReady.signal()
    }

    /// Fully release the AVIOContext, internal AVIO buffer, prefetch /
    /// current data buffers, and signal stream-mode termination.
    /// Idempotent against repeat invocation, but NOT idempotent against
    /// `markClosed` — they're two separate state transitions:
    ///
    /// 1. `markClosed` (unblock demux thread) — fast, no allocations.
    ///    `Demuxer.close()` calls it first so `av_read_frame` returns
    ///    immediately and the demuxer's access lock can be acquired
    ///    without waiting on a suspended read.
    /// 2. `close` (free resources) — invoked once the demuxer's
    ///    access lock is released. Must NOT short-circuit when
    ///    `isClosed` is already true (the previous `guard !isClosed`
    ///    did exactly that, which silently leaked the 64 MB current
    ///    + 64 MB prefetch chunk Data buffers any time a demuxer
    ///    teardown ran). `isFullyClosed` is a separate latch for
    ///    actual idempotency.
    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        if context != nil {
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
        streamLock.unlock()
        streamDataReady.signal()
    }

    // MARK: - Read (called by FFmpeg on demux thread)

    fileprivate func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        guard !isClosed else { return -1 }
        return isStreaming ? readStreaming(into: buf, size: size) : readSeekable(into: buf, size: size)
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
                let needsPrefetch = consumed > 0.5 && !isPrefetching && prefetchBuffer == nil
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

                let chunkSize: Int
                if fileSize > 0 {
                    chunkSize = min(Self.chunkSize, Int(fileSize - position))
                } else {
                    chunkSize = Self.chunkSize
                }

                if chunkSize <= 0 { break }

                guard let data = fetchChunk(from: position, size: chunkSize) else {
                    break
                }

                bufferLock.lock()
                currentBuffer = data
                currentOffset = position
                prefetchBuffer = nil
                bufferLock.unlock()
            }
        }

        return totalRead > 0 ? Int32(totalRead) : AVERROR_EOF_VALUE
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

                // Trim consumed data to prevent unbounded memory growth
                // Keep last 1MB for potential small backward seeks
                streamLock.lock()
                let consumed = Int(position - streamBytesRead)
                if consumed > Self.streamTrimThreshold {
                    let trimAmount = consumed - Self.streamTrimThreshold
                    streamBuffer.removeFirst(trimAmount)
                    streamBytesRead += Int64(trimAmount)
                }
                streamLock.unlock()
            } else if ended {
                break
            } else {
                // Wait for more data from the streaming task
                let timeout = streamDataReady.wait(timeout: .now() + .seconds(15))
                if timeout == .timedOut { break }
            }
        }

        return totalRead > 0 ? Int32(totalRead) : AVERROR_EOF_VALUE
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
            self.streamLock.unlock()
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
            configuration: Self.makeSessionConfig(),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = streamSession.dataTask(with: request)
        task.resume()

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming started: \(url.lastPathComponent)", category: .demux)
        #endif

        // Wait until stream ends or reader is closed
        semaphore.wait()

        #if DEBUG
        EngineLog.emit("[AVIOReader] Streaming ended", category: .demux)
        #endif
        streamSession.invalidateAndCancel()
    }

    // MARK: - Prefetch (background, seekable mode only)

    private func triggerPrefetch(from offset: Int64) {
        if fileSize > 0 && offset >= fileSize { return }

        bufferLock.lock()
        guard !isPrefetching else { bufferLock.unlock(); return }
        isPrefetching = true
        bufferLock.unlock()

        prefetchQueue.async { [weak self] in
            guard let self = self else { return }

            // Bail before issuing the fetch if close already ran.
            // Without this the closure would still spend up to one
            // chunk-size worth of network time downloading data
            // we're about to throw away, and a teardown that races
            // with an in-flight prefetch can complete the fetch
            // AFTER `close()` has cleared the buffers — the closure
            // would then write its fresh chunk-size Data back into
            // `prefetchBuffer`, undoing the cleanup.
            if self.isFullyClosed {
                self.bufferLock.lock()
                self.isPrefetching = false
                self.bufferLock.unlock()
                self.prefetchReady.signal()
                return
            }

            let size: Int
            if self.fileSize > 0 {
                size = min(Self.chunkSize, Int(self.fileSize - offset))
            } else {
                size = Self.chunkSize
            }

            let data = size > 0 ? self.fetchChunk(from: offset, size: size) : nil

            self.bufferLock.lock()
            // Re-check under lock: close() may have fired while
            // fetchChunk was blocking on the network. If so, drop the
            // freshly-fetched data on the floor instead of pinning
            // chunk-size bytes in prefetchBuffer for an
            // already-discarded reader. The Data goes out of scope at
            // the end of this block and its backing buffer is freed
            // immediately.
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
        switch whence {
        case SEEK_SET:
            position = offset
        case SEEK_CUR:
            position += offset
        case SEEK_END:
            guard fileSize >= 0 else { return -1 }
            position = fileSize + offset
        case AVSEEK_SIZE:
            return fileSize
        default:
            return -1
        }

        if !isStreaming {
            // Seekable mode: invalidate buffers if outside current range
            bufferLock.lock()
            let inCurrent = position >= currentOffset &&
                position < currentOffset + Int64(currentBuffer.count)
            if !inCurrent {
                currentBuffer = Data()
                currentOffset = position
                prefetchBuffer = nil
            }
            bufferLock.unlock()
        }

        return position
    }

    // MARK: - Network (seekable mode)

    /// Long-lived URLSession dedicated to file-size probes. AetherEngine.load()
    /// probes the same URL twice (once via probe Demuxer, once via session
    /// Demuxer), and per-request sessions force a fresh TLS handshake each
    /// time — Cloudflare-fronted origins can flag the changing TLS
    /// fingerprint as suspicious, intermittently slowing or 400-ing the
    /// repeat probe. A single long-lived session keeps the connection
    /// pool warm and the fingerprint stable. Distinct from `syncRequest`'s
    /// per-request session pattern, which is load-bearing for chunk-fetch
    /// leak control but adds no benefit to a one-byte probe.
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    private func probeFileSize() -> Int64 {
        // Per Delarkz's AetherEngine#8: HEAD probes break against origins
        // that reject HEAD (e.g. Cloudflare-fronted tb-cdn.st returning
        // 405). Without a known file size AVIOReader falls back to
        // streaming mode where SEEK_SET / SEEK_END both return -1, which
        // breaks any demuxer that seeks on open (MKV / WebM Cues, AVI
        // index, non-faststart MP4) and disables user scrubbing on
        // everything else.
        //
        // Replace with Range bytes=0-0 GET, cancel in didReceive
        // response so the body never streams. Fall back to HEAD if
        // the Range probe doesn't yield a size (live-transcode URLs
        // that don't accept Range early in the session).
        if let size = rangeProbeFileSize(), size > 0 {
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(size) bytes (Range probe)", category: .demux)
            #endif
            return size
        }
        return headProbeFileSize()
    }

    /// Range `bytes=0-0` GET that cancels in `didReceive response`.
    /// Returns the total size parsed from `Content-Range: bytes 0-0/<TOTAL>`
    /// on a 206 response, or `expectedContentLength` on a 2xx response
    /// (some origins ignore Range and respond with full content + length).
    /// Nil on cancellation, timeout, network error, or unparseable
    /// Content-Range.
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

    /// Legacy HEAD probe, kept as fallback for live-transcode endpoints
    /// that don't accept Range early in the session.
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
            // HEAD timeout or network error, fall back to streaming mode.
            // This is expected for live transcode URLs where the server
            // needs to start transcoding before responding.
            #if DEBUG
            EngineLog.emit("[AVIOReader] HEAD probe failed: \(error.localizedDescription) → streaming mode", category: .demux)
            #endif
            return -1
        }
    }

    private func fetchChunk(from offset: Int64, size: Int) -> Data? {
        // First attempt: use the cached resolved CDN URL if we have
        // one, otherwise the source URL. If the cached URL was used
        // and returned an auth-expiry-like status, fall back to the
        // source URL for one more attempt so the proxy can re-issue
        // a signed redirect.
        if let data = fetchChunkAttempt(from: offset, size: size, forceSource: false) {
            return data
        }
        // Only retry against the source if the first attempt actually
        // used a cached URL. Otherwise the second pass would just
        // repeat the same request.
        if cachedResolvedURL() != nil {
            return fetchChunkAttempt(from: offset, size: size, forceSource: true)
        }
        return nil
    }

    /// Single fetch pass against either the cached resolved URL or
    /// the source URL. Returns nil on any non-200/206 response,
    /// dropping the cached URL when the failure looks like an expiry.
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

    /// Long-lived URLSession dedicated to chunk fetches in the seekable
    /// path. Paired with per-task `ChunkFetchDelegate` instances that
    /// receive bytes incrementally and force-copy each delivery into
    /// our own buffer.
    ///
    /// Why long-lived this time (the historic leak chase rejected
    /// long-lived sessions): the original leak was driven by
    /// completion-handler-style dataTasks where URLSession's task
    /// pool accumulated monolithic response bodies past completion-
    /// handler return. The delegate-based path doesn't accumulate —
    /// URLSession delivers chunks as they arrive and releases its
    /// internal references once the delegate ack returns. With
    /// per-delivery force-copy, the source dispatch_data is released
    /// per delivery, never accumulating. No invalidation overhead per
    /// fetch either, so high-frequency small-chunk patterns don't
    /// stack up un-invalidated sessions.
    private static let chunkSession: URLSession = {
        let config = makeSessionConfig()
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        // Delegate-based incremental fetch on a shared long-lived
        // session. See `chunkSession` for the why; the rest of this
        // function is just lifecycle: build a fresh delegate, attach
        // it to a fresh task on the shared session, wait on a
        // semaphore for completion, hand back our heap-allocated
        // body Data.
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

// MARK: - Chunk Fetch Delegate

/// Per-task delegate for the seekable-mode range fetch. Receives
/// response bytes incrementally and force-copies each delivery into
/// its own `body` Data buffer, so the source dispatch_data references
/// can be released per delivery instead of accumulating in URLSession's
/// task pool past completion.
///
/// `@unchecked Sendable` because the delegate is single-use per fetch
/// and ownership is enforced by the calling thread blocking on a
/// semaphore: URLSession's delegate callbacks run on its own queue
/// while the calling thread waits, so there's no concurrent access to
/// the mutable fields. Body access from the caller happens only after
/// `onCompletion` fires + the semaphore signals.
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

    /// Preserve the `Range` header + caller-supplied extra headers on
    /// cross-host redirects. URLSession strips custom headers when a
    /// redirect changes host; without this the CDN sees a plain GET
    /// instead of a partial fetch and either streams the whole body
    /// (busted memory) or 400s on proxies that require Range. See
    /// the same hook on `ProbeDelegate` for the original incident.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var updated = request
        if let originalRange = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            updated.setValue(originalRange, forHTTPHeaderField: "Range")
        }
        for (name, value) in extraHeaders {
            updated.setValue(value, forHTTPHeaderField: name)
        }
        completionHandler(updated)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        // Pre-reserve buffer space when Content-Length is known so
        // body.append doesn't repeatedly realloc as chunks stream in.
        if let http = response as? HTTPURLResponse {
            let len = Int(http.expectedContentLength)
            if len > 0 { body.reserveCapacity(len) }
            // Surface the post-redirect URL so the reader can cache
            // it for subsequent range fetches. Only on success: a 4xx
            // redirect target shouldn't poison the cache.
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
        // Explicit force-copy: append a fresh contiguous range to our
        // heap-backed `body` and memcpy the source bytes in. Foundation's
        // own `body.append(data)` may keep a reference to the source
        // dispatch_data via copy-on-write semantics, defeating the
        // whole point. Manual memcpy through withUnsafeMutableBytes
        // guarantees the source can be dropped once this method returns.
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

/// URLSession delegate that delivers data chunks incrementally
/// instead of buffering the entire response.
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

/// Per-task delegate for the file-size Range probe. Preserves the Range
/// header across cross-host redirects (URLSession default drops it),
/// captures the total size from the 206 response's `Content-Range`
/// header, and cancels the task before the body streams.
///
/// `@unchecked Sendable` because the delegate is single-use per probe
/// and is owned by the calling thread via the semaphore; URLSession's
/// delegate callbacks run on its own queue but the calling thread
/// blocks until `onCompletion` fires, so there's no concurrent access
/// to the mutable fields.
private final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var totalSize: Int64?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?

    init(extraHeaders: [String: String]) {
        self.extraHeaders = extraHeaders
    }

    /// Preserve the `Range` header (and the caller-supplied extra
    /// headers) on cross-host redirects. URLSession's default
    /// `willPerformHTTPRedirection` strips custom request headers when
    /// the redirect changes host; without this, the redirected origin
    /// (e.g. Cloudflare CDN behind an AIOStreams proxy) sees a regular
    /// GET and either streams the full body or `400 Bad Request`s on
    /// proxies that require Range.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var updated = request
        if let originalRange = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            updated.setValue(originalRange, forHTTPHeaderField: "Range")
        }
        for (name, value) in extraHeaders {
            updated.setValue(value, forHTTPHeaderField: name)
        }
        completionHandler(updated)
    }

    /// Capture Content-Range total size, then cancel so the body
    /// never streams. The fast path is a 206 response with
    /// `Content-Range: bytes 0-0/<TOTAL>`; we also accept a plain
    /// 2xx with a positive `Content-Length`, which is what some
    /// origins return when they ignore Range entirely on the first
    /// byte.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        defer { completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else { return }
        // Surface the post-redirect URL so the reader can cache it for
        // subsequent range fetches. Only on success: a 4xx redirect
        // target shouldn't poison the cache.
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

/// FFmpeg AVERROR_EOF, the C macro can't be imported into Swift.
/// FFERRTAG(0xF8,'E','O','F') = -541478725
private let AVERROR_EOF_VALUE: Int32 = -541478725

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
    case httpError(code: Int)
    case noResponse
    case requestTimeout

    var description: String {
        switch self {
        case .allocationFailed: return "Failed to allocate AVIO buffer"
        case .httpError(let code): return "HTTP error \(code)"
        case .noResponse: return "No response from server"
        case .requestTimeout: return "Request timed out"
        }
    }
}
