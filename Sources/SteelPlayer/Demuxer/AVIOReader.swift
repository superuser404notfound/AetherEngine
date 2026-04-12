import Foundation
import Libavformat
import Libavutil

/// Custom AVIO context that feeds data to FFmpeg via URLSession HTTP Range
/// requests. Replaces FFmpeg's built-in network stack (disabled in FFmpegBuild).
///
/// Features:
/// - **Read-ahead buffer**: Fetches 2 MB chunks per HTTP request, serves
///   FFmpeg's smaller reads from memory. Reduces HTTP round-trips by ~30x.
/// - **Retry with backoff**: Transient network errors are retried up to 3 times.
/// - **Timeout protection**: Semaphore-based sync with 30s timeout to prevent
///   deadlocks if the session is invalidated while a request is in flight.
///
/// Thread safety: Callbacks are invoked on the demux queue — no concurrent access.
final class AVIOReader: @unchecked Sendable {

    private let url: URL
    private let session: URLSession
    private var position: Int64 = 0
    private var fileSize: Int64 = -1

    /// The AVIO context FFmpeg reads from. Nil until `open()` is called.
    private(set) var context: UnsafeMutablePointer<AVIOContext>?

    /// Buffer allocated with av_malloc — owned by AVIOContext after creation.
    private var buffer: UnsafeMutablePointer<UInt8>?

    // MARK: - Read-Ahead Buffer

    /// How much data to fetch per HTTP request (amortizes RTT overhead).
    private static let httpChunkSize = 2 * 1024 * 1024  // 2 MB

    /// AVIO buffer size — how much FFmpeg requests per read callback.
    private static let avioBufferSize: Int32 = 256 * 1024  // 256 KB

    /// Cached data from the last HTTP chunk fetch.
    private var readAheadBuffer = Data()
    /// File offset where readAheadBuffer starts.
    private var readAheadOffset: Int64 = 0

    private static let maxRetries = 3

    init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// Probe the remote resource (HTTP HEAD) and allocate the AVIO context.
    func open() throws {
        // 1. HEAD request to determine file size and seekability
        fileSize = try probeFileSize()

        // 2. Allocate the AVIO read buffer
        guard let buf = av_malloc(Int(Self.avioBufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        // 3. Create the AVIO context with our read/seek callbacks.
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.avioBufferSize,
            0,          // write_flag = 0 (read-only)
            opaque,
            readCallback,
            nil,        // no write callback
            seekCallback
        ) else {
            av_free(buf)
            buffer = nil
            throw AVIOReaderError.allocationFailed
        }

        context = ctx
    }

    /// Release the AVIO context and session.
    func close() {
        if context != nil {
            avio_context_free(&context)
        }
        context = nil
        buffer = nil
        readAheadBuffer = Data()
        session.invalidateAndCancel()
    }

    deinit {
        close()
    }

    // MARK: - Internal

    /// HTTP HEAD request to get Content-Length.
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
        let length = http.expectedContentLength  // -1 if unknown
        #if DEBUG
        print("[AVIOReader] File size: \(length) bytes")
        #endif
        return length
    }

    /// Read data for FFmpeg. Serves from the read-ahead buffer when possible,
    /// fetches a new chunk from the network when needed.
    fileprivate func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            // Check if current position is within the read-ahead buffer
            let bufferEnd = readAheadOffset + Int64(readAheadBuffer.count)
            if position >= readAheadOffset && position < bufferEnd {
                // Serve from buffer
                let offsetInBuffer = Int(position - readAheadOffset)
                let available = readAheadBuffer.count - offsetInBuffer
                let toCopy = min(available, requestSize - totalRead)

                readAheadBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: offsetInBuffer)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: toCopy)
                }
                position += Int64(toCopy)
                totalRead += toCopy
            } else {
                // Fetch a new chunk from the network
                let chunkSize: Int
                if fileSize > 0 {
                    chunkSize = min(Self.httpChunkSize, Int(fileSize - position))
                } else {
                    chunkSize = Self.httpChunkSize
                }

                if chunkSize <= 0 {
                    // EOF
                    break
                }

                guard let data = fetchChunk(from: position, size: chunkSize) else {
                    return totalRead > 0 ? Int32(totalRead) : -1
                }

                if data.isEmpty {
                    break  // EOF
                }

                readAheadOffset = position
                readAheadBuffer = data
            }
        }

        return totalRead > 0 ? Int32(totalRead) : 0  // 0 = EOF
    }

    /// Fetch a chunk of data from the HTTP server with retry logic.
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
                    #if DEBUG
                    print("[AVIOReader] HTTP \(http.statusCode) at offset \(offset)")
                    #endif
                    return nil
                }

                return data
            } catch {
                lastError = error
                if attempt < Self.maxRetries - 1 {
                    // Exponential backoff: 0.5s, 1s, 2s
                    Thread.sleep(forTimeInterval: Double(1 << attempt) * 0.5)
                }
            }
        }

        #if DEBUG
        print("[AVIOReader] Read failed after \(Self.maxRetries) retries at offset \(offset): \(lastError?.localizedDescription ?? "unknown")")
        #endif
        return nil
    }

    /// Handle seek requests from FFmpeg.
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

        // Invalidate read-ahead buffer if seeking outside it
        let bufferEnd = readAheadOffset + Int64(readAheadBuffer.count)
        if position < readAheadOffset || position >= bufferEnd {
            readAheadBuffer = Data()
            readAheadOffset = position
        }

        return position
    }

    /// Blocking URLSession helper with timeout protection.
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

        // Timeout prevents deadlock if session is invalidated during request
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
