import Foundation
import Libavformat
import Libavutil

/// Custom AVIO context that feeds data to FFmpeg via URLSession HTTP Range
/// requests with asynchronous double-buffering.
///
/// Architecture:
/// - Two buffers: `current` (being read by FFmpeg) and `prefetch` (being
///   downloaded in background). When `current` is exhausted, we swap.
/// - A background GCD queue continuously prefetches the next chunk so
///   network I/O never blocks the demux thread.
/// - For seeks, both buffers are invalidated and refilled.
///
/// Thread safety: AVIO callbacks run on the demux queue. Prefetch runs
/// on a dedicated background queue. Access to shared state is protected
/// by `bufferLock`.
final class AVIOReader: @unchecked Sendable {

    private let url: URL
    private let session: URLSession
    private var position: Int64 = 0
    private var fileSize: Int64 = -1

    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var buffer: UnsafeMutablePointer<UInt8>?

    // MARK: - Double Buffer

    private static let chunkSize = 8 * 1024 * 1024  // 8 MB per chunk
    private static let avioBufferSize: Int32 = 256 * 1024  // 256 KB

    /// Lock protecting buffer state shared between demux and prefetch threads.
    private let bufferLock = NSLock()

    /// The buffer currently being served to FFmpeg.
    private var currentBuffer = Data()
    private var currentOffset: Int64 = 0

    /// Pre-fetched next chunk, ready to swap in.
    private var prefetchBuffer: Data?
    private var prefetchOffset: Int64 = 0

    /// Whether a prefetch is in progress.
    private var isPrefetching = false

    /// Signaled when prefetch completes (so read() can stop waiting).
    private let prefetchReady = DispatchSemaphore(value: 0)

    /// Background queue for async prefetch.
    private let prefetchQueue = DispatchQueue(label: "com.steelplayer.avio.prefetch", qos: .userInitiated)

    private static let maxRetries = 3

    init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func open() throws {
        fileSize = try probeFileSize()

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

        // Pre-fill the first chunk synchronously so demuxer can start immediately
        if let data = fetchChunk(from: 0, size: Self.chunkSize) {
            currentBuffer = data
            currentOffset = 0
            // Start prefetching the second chunk
            triggerPrefetch(from: Int64(data.count))
        }
    }

    func close() {
        if context != nil {
            avio_context_free(&context)
        }
        context = nil
        buffer = nil
        currentBuffer = Data()
        prefetchBuffer = nil
        session.invalidateAndCancel()
    }

    deinit {
        close()
    }

    // MARK: - Read (called by FFmpeg on demux thread)

    fileprivate func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            bufferLock.lock()
            let bufEnd = currentOffset + Int64(currentBuffer.count)
            let inRange = position >= currentOffset && position < bufEnd
            bufferLock.unlock()

            if inRange {
                // Serve from current buffer
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

                // When we've consumed >50% of the current buffer, start prefetching next
                let consumed = Double(position - currentOffset) / Double(currentBuffer.count)
                let nextPrefetchOffset = currentOffset + Int64(currentBuffer.count)
                let needsPrefetch = consumed > 0.5 && !isPrefetching && prefetchBuffer == nil
                bufferLock.unlock()

                if needsPrefetch {
                    triggerPrefetch(from: nextPrefetchOffset)
                }
            } else {
                // Current buffer exhausted or position outside it — swap in prefetch
                bufferLock.lock()
                if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                    position < prefetchOffset + Int64(prefetch.count) {
                    // Prefetch buffer covers our position — swap it in
                    currentBuffer = prefetch
                    currentOffset = prefetchOffset
                    prefetchBuffer = nil
                    bufferLock.unlock()
                    continue  // Re-enter loop, now served from new current buffer
                }
                let hasPrefetchInFlight = isPrefetching
                bufferLock.unlock()

                if hasPrefetchInFlight {
                    // Wait for in-flight prefetch to complete
                    _ = prefetchReady.wait(timeout: .now() + .seconds(15))
                    // Re-check after wake
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

                // No prefetch available — synchronous fetch as last resort
                let chunkSize: Int
                if fileSize > 0 {
                    chunkSize = min(Self.chunkSize, Int(fileSize - position))
                } else {
                    chunkSize = Self.chunkSize
                }

                if chunkSize <= 0 { break }  // EOF

                guard let data = fetchChunk(from: position, size: chunkSize) else {
                    return totalRead > 0 ? Int32(totalRead) : -1
                }
                if data.isEmpty { break }

                bufferLock.lock()
                currentBuffer = data
                currentOffset = position
                prefetchBuffer = nil
                bufferLock.unlock()
            }
        }

        return totalRead > 0 ? Int32(totalRead) : 0
    }

    // MARK: - Prefetch (background thread)

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

        // Invalidate buffers if seeking outside current range
        bufferLock.lock()
        let inCurrent = position >= currentOffset &&
            position < currentOffset + Int64(currentBuffer.count)
        if !inCurrent {
            currentBuffer = Data()
            currentOffset = position
            prefetchBuffer = nil
        }
        bufferLock.unlock()

        return position
    }

    // MARK: - Network

    private func probeFileSize() throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10

        let (_, response) = try syncRequest(request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AVIOReaderError.httpError(
                code: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        let length = http.expectedContentLength
        #if DEBUG
        print("[AVIOReader] File size: \(length) bytes")
        #endif
        return length
    }

    private func fetchChunk(from offset: Int64, size: Int) -> Data? {
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 15

        var lastError: Error?
        for attempt in 0..<Self.maxRetries {
            do {
                let (data, response) = try syncRequest(request)
                if let http = response as? HTTPURLResponse,
                   http.statusCode != 200 && http.statusCode != 206 {
                    return nil
                }
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
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data, URLResponse)?
        nonisolated(unsafe) var error: Error?

        let task = session.dataTask(with: request) { d, r, e in
            if let e = e {
                error = e
            } else if let d = d, let r = r {
                result = (d, r)
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

// MARK: - C Callbacks

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
        case .allocationFailed: "AVIO buffer/context allocation failed"
        case .httpError(let code): "HTTP error \(code)"
        case .noResponse: "No response from server"
        case .requestTimeout: "HTTP request timed out"
        }
    }
}
