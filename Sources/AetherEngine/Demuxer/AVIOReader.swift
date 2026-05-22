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

    /// Diagnostic A/B round 2: bumped from 64 MB to 256 MB to test
    /// whether the residual ~0.65 MB/s leak that survives the 64 MB
    /// jump is still proportional to URLSession call count or has
    /// shifted to a per-recycle teardown leak (the parallel hypothesis).
    ///
    /// 8 MB chunks  → 3.20 MB/s leak (URLSession-dominated)
    /// 64 MB chunks → 0.64 MB/s leak (5x reduction; partial fix)
    /// 256 MB chunks → ?
    ///
    /// If 256 MB drops the rate to ~0.16 MB/s (linear with call count
    /// reduction) → URLSession is still the primary source. The
    /// "remaining" leak is just the same per-call leak at lower rate.
    /// If 256 MB stays at ~0.64 MB/s → URLSession is no longer the
    /// dominant contributor; the remainder is in demuxer recycle
    /// teardown (old AVIOReader / AVFormatContext retention) or
    /// elsewhere.
    ///
    /// Memory cost during this spike: ~512 MB peak (one current + one
    /// prefetch chunk). Acceptable on a 4 GB Apple TV 4K for a
    /// diagnostic; not appropriate for production until we know which
    /// chunk size to commit to.
    private static let chunkSize = 256 * 1024 * 1024  // 256 MB per chunk (diagnostic A/B round 2)
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
    ///    did exactly that, which leaked the 64 MB current + 64 MB
    ///    prefetch chunk Data buffers on every demuxer recycle —
    ///    observed as the residual ~0.64 MB/s growth after the
    ///    URLSession chunk-size A/B). `isFullyClosed` is a separate
    ///    latch for actual idempotency.
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
        print("[AVIOReader] Streaming started: \(url.lastPathComponent)")
        #endif

        // Wait until stream ends or reader is closed
        semaphore.wait()

        #if DEBUG
        print("[AVIOReader] Streaming ended")
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

            let size: Int
            if self.fileSize > 0 {
                size = min(Self.chunkSize, Int(self.fileSize - offset))
            } else {
                size = Self.chunkSize
            }

            let data = size > 0 ? self.fetchChunk(from: offset, size: size) : nil

            self.bufferLock.lock()
            self.prefetchBuffer = data
            self.prefetchOffset = offset
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

    private func probeFileSize() -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        applyExtraHeaders(&request)

        do {
            let (_, response) = try syncRequest(request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                #if DEBUG
                print("[AVIOReader] HEAD failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)) → streaming mode")
                #endif
                return -1
            }
            let length = http.expectedContentLength
            #if DEBUG
            print("[AVIOReader] File size: \(length) bytes\(length <= 0 ? " (streaming mode)" : "")")
            #endif
            return length
        } catch {
            // HEAD timeout or network error, fall back to streaming mode.
            // This is expected for live transcode URLs where the server
            // needs to start transcoding before responding.
            #if DEBUG
            print("[AVIOReader] HEAD probe failed: \(error.localizedDescription) → streaming mode")
            #endif
            return -1
        }
    }

    private func fetchChunk(from offset: Int64, size: Int) -> Data? {
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15
        applyExtraHeaders(&request)

        var lastError: Error?
        for attempt in 0..<Self.maxRetries {
            do {
                let (data, response) = try syncRequest(request)
                if let http = response as? HTTPURLResponse,
                   http.statusCode != 200 && http.statusCode != 206 {
                    return nil
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
        print("[AVIOReader] Fetch failed after \(Self.maxRetries) retries at offset \(offset): \(lastError?.localizedDescription ?? "?")")
        #endif
        return nil
    }

    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        // Per-request session AND completion-handler force-copy. Either
        // one alone is insufficient: Instruments (commit 8e47344) traced
        // the long-form 4K HDR leak to URLSession's dispatch_data_t
        // task-pool keeping response bodies alive past the completion
        // handler. Per-request session releases the pool entry only when
        // finishTasksAndInvalidate completes — which is async and can
        // lag the next fetch by enough to keep the previous chunk's
        // dispatch_data pinned. The force-copy makes the returned Data
        // a brand-new contiguous heap allocation that holds no reference
        // to URLSession's backing buffer at all, so the pool can drop
        // the dispatch_data immediately without keeping our chunk alive.
        //
        // The malloc diagnostic shipped this session showed mallocMB
        // growing ~8 MB/s with block count roughly flat — consistent
        // with a small fixed set of buffers being realloc'd-and-kept
        // by libmalloc instead of returned to the kernel. dispatch_data
        // is exactly that pattern: libmalloc tracks each pool slot, the
        // contents change but the slot count stays small.
        //
        // The chunkSize back to 8 MB stays. With force-copy in place
        // the per-chunk overhead is one 8 MB memcpy per fetch, which is
        // negligible at 4K HEVC bitrates (~3 chunks/s = 24 MB/s copy
        // bandwidth, far under any L1/L2 ceiling).
        let session = URLSession(configuration: Self.makeSessionConfig())
        defer { session.finishTasksAndInvalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data, URLResponse)?
        nonisolated(unsafe) var error: Error?

        let task = session.dataTask(with: request) { d, r, e in
            if let e = e {
                error = e
            } else if let d = d, let r = r {
                // Force-copy: allocate a fresh contiguous Data on our
                // heap and memcpy the bytes in. The returned Data has
                // no reference to URLSession's dispatch_data_t, so the
                // task pool can release the response body immediately
                // when the completion handler returns.
                //
                // Foundation may short-circuit Data(other) into a
                // structural share when both are dispatch_data-backed
                // (= the previous test showed only a partial leak
                // reduction). Force a real memcpy by allocating an
                // empty Data of the right size and writing the source
                // bytes into it under withUnsafeMutableBytes. Foundation
                // cannot alias this with the source — it has to do the
                // copy.
                let count = d.count
                var copied = Data(count: count)
                copied.withUnsafeMutableBytes { dst in
                    d.withUnsafeBytes { src in
                        if let dstBase = dst.baseAddress, let srcBase = src.baseAddress {
                            dstBase.copyMemory(from: srcBase, byteCount: count)
                        }
                    }
                }
                result = (copied, r)
            } else {
                error = AVIOReaderError.noResponse
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + .seconds(35)) == .timedOut {
            task.cancel()
            throw AVIOReaderError.requestTimeout
        }

        if let error = error { throw error }
        guard let result = result else { throw AVIOReaderError.noResponse }
        return result
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
            print("[AVIOReader] Stream error: \(error.localizedDescription)")
        }
        #endif
        onComplete()
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
