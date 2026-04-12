import Foundation
import Libavformat
import Libavutil

/// Custom AVIO context that feeds data to FFmpeg via URLSession HTTP Range
/// requests. This replaces FFmpeg's built-in network stack (which is disabled
/// in FFmpegBuild) while keeping file:// URLs handled natively by FFmpeg.
///
/// Usage:
/// ```swift
/// let reader = AVIOReader(url: httpURL)
/// try reader.open()          // HEAD request to get file size
/// let avio = reader.avioContext
/// formatCtx.pointee.pb = avio
/// avformat_open_input(...)   // FFmpeg reads through our callbacks
/// ```
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

    private static let bufferSize: Int32 = 64 * 1024  // 64 KB

    init(url: URL) {
        self.url = url
        // Ephemeral session — no caching, no cookies, no disk persistence.
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Probe the remote resource (HTTP HEAD) and allocate the AVIO context.
    func open() throws {
        // 1. HEAD request to determine file size and seekability
        fileSize = try probeFileSize()

        // 2. Allocate the AVIO read buffer
        guard let buf = av_malloc(Int(Self.bufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        // 3. Create the AVIO context with our read/seek callbacks.
        //    The opaque pointer carries `self` into the C callbacks.
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.bufferSize,
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
            // avio_context_free frees both the context and the internal buffer
            avio_context_free(&context)
        }
        context = nil
        buffer = nil
        session.invalidateAndCancel()
    }

    deinit {
        close()
    }

    // MARK: - Internal

    /// HTTP HEAD request to get Content-Length. Blocks the calling thread.
    private func probeFileSize() throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

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

    /// Synchronous HTTP Range GET. Returns bytes read (0 = EOF, <0 = error).
    fileprivate func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        let rangeStart = position
        let rangeEnd = rangeStart + Int64(requestSize) - 1

        var request = URLRequest(url: url)
        request.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try syncRequest(request)
        } catch {
            #if DEBUG
            print("[AVIOReader] Read error at offset \(position): \(error)")
            #endif
            return -1  // AVERROR(EIO)
        }

        // Server may return 200 (full body) or 206 (partial content)
        if let http = response as? HTTPURLResponse,
           http.statusCode != 200 && http.statusCode != 206 {
            #if DEBUG
            print("[AVIOReader] HTTP \(http.statusCode) at offset \(position)")
            #endif
            return -1
        }

        if data.isEmpty {
            return 0  // EOF
        }

        let bytesRead = min(data.count, requestSize)
        data.withUnsafeBytes { raw in
            buf.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: bytesRead)
        }
        position += Int64(bytesRead)
        return Int32(bytesRead)
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
            // FFmpeg asks for the total size
            return fileSize
        default:
            return -1
        }
        return position
    }

    /// Blocking URLSession helper using a semaphore. Safe because this is
    /// only called from the demux background queue, never from main.
    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        // nonisolated(unsafe): safe because semaphore guarantees
        // the closure completes before we read these values.
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
        semaphore.wait()

        if let error = error { throw error }
        guard let result = result else { throw AVIOReaderError.noResponse }
        return result
    }
}

// MARK: - C Callbacks

/// Read callback for avio_alloc_context. Called by FFmpeg's av_read_frame.
private func readCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.read(into: buf, size: size)
}

/// Seek callback for avio_alloc_context. Called by FFmpeg for seeking.
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

    var description: String {
        switch self {
        case .allocationFailed: "AVIO buffer/context allocation failed"
        case .httpError(let code): "HTTP error \(code)"
        case .noResponse: "No response from server"
        }
    }
}
