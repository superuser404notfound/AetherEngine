import Foundation

/// Seekable `IOReader` over a remote disc image (ISO 9660 / UDF / Blu-ray BDMV) served over HTTP(S)
/// with byte-range support. The local case has `FileIOReader`; this is its remote twin, so
/// `DiscReader.wrap` can probe and read a remote `.iso` exactly the way it reads a local one (the
/// disc layer issues random-access seeks for the UDF anchor and directory structure, then reads the
/// selected title's m2ts/VOB extents). Without this a remote `.iso` is handed straight to
/// libavformat, which fails to probe it (a disc image is a filesystem, not a media container) (#64).
///
/// Reads are served from a single sliding read-ahead buffer. The read-ahead window is ADAPTIVE: it
/// starts at `baseChunkSize` (so the scattered, kilobyte-sized disc-structure reads at open do not
/// each pull a megabyte) and doubles up to `maxChunkSize` while reads stay sequential (so steady
/// playback of the title's extents costs few requests); any non-contiguous read resets it. Each
/// range request retries with backoff so a transient network blip does not end playback. The server
/// MUST honor range requests (any static file host does); if it does not, `init` returns nil after a
/// clear log and the caller falls back to the plain streaming path.
final class HTTPDiscIOReader: IOReader, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let baseChunkSize: Int
    private let maxChunkSize: Int
    private let maxRetries: Int
    private let totalSize: Int64

    private let lock = NSLock()
    private var position: Int64 = 0
    private var bufferStart: Int64 = -1
    private var buffer: [UInt8] = []
    /// End offset of the last buffer refill; a read starting here continues sequentially.
    private var lastFetchEnd: Int64 = -1
    /// Current adaptive read-ahead window; grows on sequential refills, resets on a seek.
    private var currentChunkSize: Int
    /// `cancelled` has its own lock: `read` holds `lock` across the (slow) fetch, and the fetch's
    /// retry loop must poll `cancelled` without re-entering the non-reentrant `lock`, and `cancel()`
    /// must be able to set it from another thread while a read is in flight.
    private let cancelLock = NSLock()
    private var cancelled = false

    /// Probes total size and range support with one (retried) `bytes=0-0` request. Returns nil if
    /// the source is unreachable or answers `200` (full body, no range support); logs which.
    init?(url: URL,
          extraHeaders: [String: String] = [:],
          baseChunkSize: Int = 256 * 1024,
          maxChunkSize: Int = 8 * 1024 * 1024,
          maxRetries: Int = 3,
          requestTimeout: TimeInterval = 30,
          sessionConfiguration: URLSessionConfiguration? = nil) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.baseChunkSize = max(64 * 1024, baseChunkSize)
        self.maxChunkSize = max(max(64 * 1024, baseChunkSize), maxChunkSize)
        self.currentChunkSize = max(64 * 1024, baseChunkSize)
        self.maxRetries = max(0, maxRetries)
        self.requestTimeout = requestTimeout
        let config = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return c
        }()
        self.session = URLSession(configuration: config)

        guard let size = Self.probeSize(
            url: url, extraHeaders: extraHeaders, session: session,
            timeout: requestTimeout, maxRetries: max(0, maxRetries)
        ), size > 0 else {
            session.invalidateAndCancel()
            return nil
        }
        self.totalSize = size
    }

    // MARK: - Pure helpers

    /// Inclusive byte-range header for a half-open `[offset, offset+length)` window.
    static func rangeHeader(offset: Int64, length: Int) -> String {
        "bytes=\(offset)-\(offset + Int64(length) - 1)"
    }

    /// Total size from a `Content-Range` value (`bytes 0-0/12345` -> 12345). Nil for `*` or junk.
    static func parseContentRangeTotal(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard total != "*" else { return nil }
        return Int64(total)
    }

    /// Next adaptive window: `base` when `position` is not the sequential continuation of the last
    /// refill, otherwise the previous window doubled and capped at `maxChunkSize`.
    static func nextChunkSize(position: Int64, lastFetchEnd: Int64, current: Int,
                              base: Int, maxChunk: Int) -> Int {
        guard position == lastFetchEnd, lastFetchEnd >= 0 else { return base }
        return min(current * 2, maxChunk)
    }

    // MARK: - IOReader

    func read(_ outBuffer: UnsafeMutablePointer<UInt8>?, size n: Int32) -> Int32 {
        guard let out = outBuffer, n > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        if position >= totalSize { return 0 }

        if position < bufferStart || position >= bufferStart + Int64(buffer.count) {
            currentChunkSize = Self.nextChunkSize(
                position: position, lastFetchEnd: lastFetchEnd,
                current: currentChunkSize, base: baseChunkSize, maxChunk: maxChunkSize)
            let want = Int(min(Int64(currentChunkSize), totalSize - position))
            guard want > 0, let data = fetchWithRetry(offset: position, length: want), !data.isEmpty else {
                return -1
            }
            bufferStart = position
            buffer = [UInt8](data)
            lastFetchEnd = position + Int64(buffer.count)
        }

        let bufOffset = Int(position - bufferStart)
        let available = buffer.count - bufOffset
        let toCopy = min(Int(n), available, Int(totalSize - position))
        guard toCopy > 0 else { return 0 }
        buffer.withUnsafeBufferPointer { src in
            out.update(from: src.baseAddress!.advanced(by: bufOffset), count: toCopy)
        }
        position += Int64(toCopy)
        return Int32(toCopy)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return totalSize }  // AVSEEK_SIZE
        lock.lock(); defer { lock.unlock() }
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END: target = totalSize + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }

    func close() { session.invalidateAndCancel() }

    func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
        session.getAllTasks { $0.forEach { $0.cancel() } }
    }

    func makeIndependentReader() -> IOReader? {
        HTTPDiscIOReader(url: url, extraHeaders: extraHeaders,
                         baseChunkSize: baseChunkSize, maxChunkSize: maxChunkSize,
                         maxRetries: maxRetries, requestTimeout: requestTimeout)
    }

    // MARK: - HTTP

    /// One range GET retried up to `maxRetries` times with linear backoff; aborts early on cancel.
    private func fetchWithRetry(offset: Int64, length: Int) -> Data? {
        var attempt = 0
        while true {
            cancelLock.lock(); let stop = cancelled; cancelLock.unlock()
            if stop { return nil }
            if let r = Self.rangeGet(url: url, extraHeaders: extraHeaders, session: session,
                                     timeout: requestTimeout, offset: offset, length: length),
               r.status == 206 || r.status == 200, !r.body.isEmpty {
                return r.body
            }
            attempt += 1
            if attempt > maxRetries { return nil }
            Thread.sleep(forTimeInterval: min(0.25 * Double(attempt), 1.0))
        }
    }

    private static func probeSize(url: URL, extraHeaders: [String: String], session: URLSession,
                                  timeout: TimeInterval, maxRetries: Int) -> Int64? {
        var attempt = 0
        while true {
            let r = rangeGet(url: url, extraHeaders: extraHeaders, session: session,
                             timeout: timeout, offset: 0, length: 1)
            if let r = r, r.status == 206, let cr = r.contentRange,
               let total = parseContentRangeTotal(cr) {
                return total
            }
            if let r = r, r.status == 200 {
                EngineLog.emit(
                    "[HTTPDiscIOReader] \(url.lastPathComponent): server answered 200 without a "
                    + "Content-Range; remote disc images need HTTP byte-range support. "
                    + "Falling back to the streaming path.",
                    category: .demux)
                return nil
            }
            attempt += 1
            if attempt > maxRetries {
                EngineLog.emit(
                    "[HTTPDiscIOReader] \(url.lastPathComponent): range probe failed after "
                    + "\(attempt) attempt(s) (status=\(r.map { String($0.status) } ?? "no response")). "
                    + "Falling back to the streaming path.",
                    category: .demux)
                return nil
            }
            Thread.sleep(forTimeInterval: min(0.25 * Double(attempt), 1.0))
        }
    }

    private struct RangeResponse { let status: Int; let contentRange: String?; let body: Data }

    private static func rangeGet(url: URL, extraHeaders: [String: String], session: URLSession,
                                 timeout: TimeInterval, offset: Int64, length: Int) -> RangeResponse? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue(rangeHeader(offset: offset, length: length), forHTTPHeaderField: "Range")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let sem = DispatchSemaphore(value: 0)
        var result: RangeResponse?
        let task = session.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = RangeResponse(
                    status: http.statusCode,
                    contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    body: data ?? Data()
                )
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }
}
