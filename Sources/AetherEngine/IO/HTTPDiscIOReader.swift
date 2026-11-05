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
/// clear log and `open` throws `AVIOReaderError.originIgnoresRange`, and the response is hung up on at
/// its head, so a 40 GB image answered with a 200 is never downloaded to be rejected (audit NET-102).
///
/// A source the host warmed with `AetherEngine.prewarm` (#551) is read out of those bytes first
/// (#647): the warm has already stated the size and proven range support, so the reader neither
/// probes nor refetches the head, and its first request starts at the warm frontier.
final class HTTPDiscIOReader: IOReader, SourceTransferCounting, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let baseChunkSize: Int
    private let maxChunkSize: Int
    private let maxRetries: Int
    private let totalSize: Int64
    /// Warmed bytes (#647), read before the network. Immutable, so a fork shares them without a copy.
    private let residentSpans: [ResidentSpan]

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
    /// This reader's own share of `lifetimeFetchedBytes`: every response body `fetchWithRetry`
    /// received, a rejected or retried one included, since it crossed the link either way.
    private let transferLock = NSLock()
    private var transferredBytes: Int64 = 0

    var sourceBytesFetched: Int64 {
        transferLock.lock(); defer { transferLock.unlock() }
        return transferredBytes
    }

    /// Probes total size and range support with one (retried) `bytes=0-0` request, unless
    /// `prewarmed` has already stated both. Returns nil if the source is unreachable or answers `200`
    /// (full body, no range support); logs which. `open` tells the two apart.
    convenience init?(url: URL,
                      extraHeaders: [String: String] = [:],
                      baseChunkSize: Int = 256 * 1024,
                      maxChunkSize: Int = 8 * 1024 * 1024,
                      maxRetries: Int = 3,
                      requestTimeout: TimeInterval = 30,
                      sessionConfiguration: URLSessionConfiguration? = nil,
                      prewarmed: PrewarmedSource? = nil,
                      knownSize: Int64? = nil) {
        let session = Self.makeSession(sessionConfiguration)
        guard case .size(let size) = Self.resolveSize(
            url: url, extraHeaders: extraHeaders, session: session, requestTimeout: requestTimeout,
            maxRetries: maxRetries, knownSize: knownSize ?? prewarmed?.contentLength) else {
            session.invalidateAndCancel()
            return nil
        }
        self.init(url: url, extraHeaders: extraHeaders, baseChunkSize: baseChunkSize,
                  maxChunkSize: maxChunkSize, maxRetries: maxRetries, requestTimeout: requestTimeout,
                  session: session, totalSize: size,
                  residentSpans: prewarmed.map { [$0.head] + ($0.tail.map { [$0] } ?? []) } ?? [])
    }

    /// `init?` for a caller that has to say why a disc image cannot be read: an origin that answers the
    /// range probe with a 200 cannot address bytes, which is a different failure from an unreachable
    /// one, and a disc image is a filesystem that no reader can walk without ranges (audit NET-102).
    /// nil still means unreachable, and the caller falls back to the plain streaming path.
    static func open(url: URL,
                     extraHeaders: [String: String] = [:],
                     baseChunkSize: Int = 256 * 1024,
                     maxChunkSize: Int = 8 * 1024 * 1024,
                     maxRetries: Int = 3,
                     requestTimeout: TimeInterval = 30,
                     sessionConfiguration: URLSessionConfiguration? = nil,
                     prewarmed: PrewarmedSource? = nil) throws -> HTTPDiscIOReader? {
        let session = makeSession(sessionConfiguration)
        switch resolveSize(url: url, extraHeaders: extraHeaders, session: session,
                           requestTimeout: requestTimeout, maxRetries: maxRetries,
                           knownSize: prewarmed?.contentLength) {
        case .size(let size):
            return HTTPDiscIOReader(
                url: url, extraHeaders: extraHeaders, baseChunkSize: baseChunkSize,
                maxChunkSize: maxChunkSize, maxRetries: maxRetries, requestTimeout: requestTimeout,
                session: session, totalSize: size,
                residentSpans: prewarmed.map { [$0.head] + ($0.tail.map { [$0] } ?? []) } ?? [])
        case .ignoresRange:
            session.invalidateAndCancel()
            throw AVIOReaderError.originIgnoresRange
        case .unreachable:
            session.invalidateAndCancel()
            return nil
        }
    }

    private init(url: URL,
                 extraHeaders: [String: String],
                 baseChunkSize: Int,
                 maxChunkSize: Int,
                 maxRetries: Int,
                 requestTimeout: TimeInterval,
                 session: URLSession,
                 totalSize: Int64,
                 residentSpans: [ResidentSpan]) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.baseChunkSize = max(64 * 1024, baseChunkSize)
        self.maxChunkSize = max(max(64 * 1024, baseChunkSize), maxChunkSize)
        self.currentChunkSize = max(64 * 1024, baseChunkSize)
        self.maxRetries = max(0, maxRetries)
        self.requestTimeout = requestTimeout
        self.session = session
        self.residentSpans = residentSpans.filter { !$0.isEmpty }
        self.totalSize = totalSize
    }

    private static func makeSession(_ sessionConfiguration: URLSessionConfiguration?) -> URLSession {
        let config = sessionConfiguration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return c
        }()
        return URLSession(configuration: config, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    /// `knownSize` skips the range probe. Only a source that has already answered a range request
    /// with its total may pass it: the warm, or the reader a fork is made from. The one exception is a
    /// small file of a disc folder, read whole, where a range-blind origin costs nothing.
    private static func resolveSize(url: URL, extraHeaders: [String: String], session: URLSession,
                                    requestTimeout: TimeInterval, maxRetries: Int,
                                    knownSize: Int64?) -> SizeProbe {
        if let knownSize, knownSize > 0 { return .size(knownSize) }
        return probeSize(url: url, extraHeaders: extraHeaders, session: session,
                         timeout: requestTimeout, maxRetries: max(0, maxRetries))
    }

    /// #647: take what a host warmed for this URL, under the rule `AVIOReader` adopts by (#551).
    ///
    /// A take, like every adoption: the reader holds the bytes from here on. A caller whose source
    /// turns out not to be a disc puts them back (`SourcePrewarmStore.store`) so the streaming
    /// reader it falls back to adopts them instead.
    static func takePrewarm(for url: URL, extraHeaders: [String: String],
                            store: SourcePrewarmStore = .shared) -> PrewarmedSource? {
        guard let warm = store.take(for: url) else { return nil }
        guard warm.head.start == 0, !warm.head.isEmpty, warm.contentLength > 0 else { return nil }
        guard warm.requestHeaders == extraHeaders else {
            EngineLog.emit(
                "[HTTPDiscIOReader] \(url.lastPathComponent): a warm exists for this URL but was "
                + "fetched with different headers; opening cold (#647)", category: .demux)
            return nil
        }
        EngineLog.emit(
            "[HTTPDiscIOReader] \(url.lastPathComponent): adopted a prewarmed source: "
            + "head=\(warm.head.data.count)B tail=\(warm.tail?.data.count ?? 0)B of "
            + "\(warm.contentLength)B (#647)", category: .demux)
        return warm
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

    /// Start offset from a `Content-Range` value (`bytes 100-200/12345` -> 100). Nil for junk.
    static func parseContentRangeStart(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes ") else { return nil }
        let rest = trimmed.dropFirst("bytes ".count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex..<dash])
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

        if let span = residentSpans.first(where: { $0.covers(position) }) {
            let spanOffset = Int(position - span.start)
            let toCopy = min(Int(n), span.data.count - spanOffset, Int(totalSize - position))
            span.data.withUnsafeBytes { src in
                out.update(from: src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: spanOffset), count: toCopy)
            }
            position += Int64(toCopy)
            // Reading on past the span is the sequential continuation, so the window grows there.
            lastFetchEnd = position
            return Int32(toCopy)
        }

        if position < bufferStart || position >= bufferStart + Int64(buffer.count) {
            currentChunkSize = Self.nextChunkSize(
                position: position, lastFetchEnd: lastFetchEnd,
                current: currentChunkSize, base: baseChunkSize, maxChunk: maxChunkSize)
            // Stop at the next warmed span: its bytes are already here.
            let limit = residentSpans.lazy.map(\.start).filter { $0 > self.position }.min() ?? totalSize
            let want = Int(min(Int64(currentChunkSize), limit - position))
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
                         maxRetries: maxRetries, requestTimeout: requestTimeout,
                         session: Self.makeSession(nil),
                         totalSize: totalSize, residentSpans: residentSpans)
    }

    // MARK: - HTTP

    /// One range GET retried up to `maxRetries` times with linear backoff; aborts early on cancel.
    ///
    /// Requires a 206 whose `Content-Range` start matches `offset` exactly: a proxy that answers a
    /// range request with a full 200 (cache miss, range coalescing, a Range-stripping origin) or a
    /// 206 that starts somewhere else places its body at `position` regardless, corrupting the disc
    /// structure or media stream read through it (audit NET-9). The body is also trimmed to `length`
    /// in case the server sent more than asked.
    private func fetchWithRetry(offset: Int64, length: Int) -> Data? {
        var attempt = 0
        while true {
            cancelLock.lock(); let stop = cancelled; cancelLock.unlock()
            if stop { return nil }
            let response = Self.rangeGet(url: url, extraHeaders: extraHeaders, session: session,
                                         timeout: requestTimeout, offset: offset, length: length)
            if let response, !response.body.isEmpty {
                transferLock.lock(); transferredBytes &+= Int64(response.body.count); transferLock.unlock()
            }
            if let r = response, r.status == 206, !r.body.isEmpty,
               let contentRange = r.contentRange,
               Self.parseContentRangeStart(contentRange) == offset {
                return r.body.count > length ? r.body.prefix(length) : r.body
            }
            attempt += 1
            if attempt > maxRetries { return nil }
            Thread.sleep(forTimeInterval: min(0.25 * Double(attempt), 1.0))
        }
    }

    private enum SizeProbe {
        case size(Int64)
        /// The origin answered the range probe with a 200 that is not the byte asked for.
        case ignoresRange
        case unreachable
    }

    private static func probeSize(url: URL, extraHeaders: [String: String], session: URLSession,
                                  timeout: TimeInterval, maxRetries: Int) -> SizeProbe {
        var attempt = 0
        while true {
            let r = rangeGet(url: url, extraHeaders: extraHeaders, session: session,
                             timeout: timeout, offset: 0, length: 1)
            if let r = r, r.status == 206, let cr = r.contentRange,
               let total = parseContentRangeTotal(cr) {
                return .size(total)
            }
            if let r = r, r.status == 200 {
                EngineLog.emit(
                    "[HTTPDiscIOReader] \(url.lastPathComponent): server answered 200 to a range "
                    + "probe (hung up at the head); remote disc images need HTTP byte-range support.",
                    category: .demux)
                return r.answer == .ignored ? .ignoresRange : .unreachable
            }
            attempt += 1
            if attempt > maxRetries {
                EngineLog.emit(
                    "[HTTPDiscIOReader] \(url.lastPathComponent): range probe failed after "
                    + "\(attempt) attempt(s) (status=\(r.map { String($0.status) } ?? "no response")). "
                    + "Falling back to the streaming path.",
                    category: .demux)
                return .unreachable
            }
            Thread.sleep(forTimeInterval: min(0.25 * Double(attempt), 1.0))
        }
    }

    private struct RangeResponse {
        let status: Int
        let contentRange: String?
        let body: Data
        let answer: AVIOReader.RangeAnswer
    }

    /// Takes one range of the source. Only a 206 that starts where asked is taken at all, and what is
    /// taken is capped at `length`: a 200 or a misplaced 206 is hung up on at its head, and a 206 that
    /// runs past the range is cut where the range ends. The completion-handler form buffered the whole
    /// body first, so an origin that ignored Range (or answered `bytes N-EOF`) put a disc image into
    /// memory before the check ran (audit NET-102).
    ///
    /// #243: the pull path runs this synchronously on FFmpeg's read callback, i.e. on a demux pump
    /// thread that lives for the whole session inside ONE dispatch block, so nothing ever drains
    /// that thread's autorelease pool. Every response bridged out of the completion handler is then
    /// stranded there for the session: up to 8 MB per request at the top of the adaptive window,
    /// several requests a second, once per reader fork (main demuxer + subtitle side demuxer +
    /// forward prefetcher), which is the ~30 MB/s of `mallocMB` growth reported on a remote UHD ISO.
    ///
    /// Draining per request is the fix. A per-request `URLSession` is NOT: measured against a local
    /// range origin, 480 MB fetched leaves +968 MB in-use on a shared session and +973 MB with a
    /// fresh session per request, and 0 MB with this pool. That also retires the older
    /// "URLSession retains completed completion-handler bodies until invalidation" reading of the
    /// AVIOReader leak (see `AVIOReader.persistentSession`): the owner was always the caller
    /// thread's pool, and delegate-based delivery fixed that path by keeping the body off it.
    private static func rangeGet(url: URL, extraHeaders: [String: String], session: URLSession,
                                 timeout: TimeInterval, offset: Int64, length: Int) -> RangeResponse? {
        autoreleasepool {
            var req = URLRequest(engineURL: url, timeoutInterval: timeout)
            req.httpMethod = "GET"
            req.setValue(rangeHeader(offset: offset, length: length), forHTTPHeaderField: "Range")
            for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

            let delegate = RangeFetchDelegate(offset: offset, length: length)
            let sem = DispatchSemaphore(value: 0)
            delegate.onCompletion = { sem.signal() }
            let task = session.dataTask(with: req)
            task.delegate = delegate
            task.resume()
            if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
                task.cancel()
                return nil
            }
            guard let http = delegate.response else { return nil }
            let body = delegate.body
            Self.recordFetched(bytes: body.count)
            return RangeResponse(status: http.statusCode,
                                 contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                 body: body, answer: delegate.answer)
        }
    }

    // MARK: - Diagnostics

    /// Lifetime bytes pulled by every live `HTTPDiscIOReader` of this session, for the memprobe.
    /// The disc pull path had no byte counter at all (`avioFetchedMB` covers the AVIOReader path
    /// only), so a report on this path could show every engine-tracked pool flat while the reader
    /// forks pulled tens of MB/s, which is how #243 had to be argued from arithmetic instead of a
    /// counter. Reset per session by the memory probe.
    private static let fetchedLock = NSLock()
    nonisolated(unsafe) private static var fetchedBytesTotal: Int64 = 0
    nonisolated(unsafe) private static var fetchedResetCount: Int = 0

    private static func recordFetched(bytes: Int) {
        guard bytes > 0 else { return }
        fetchedLock.lock()
        fetchedBytesTotal &+= Int64(bytes)
        fetchedLock.unlock()
    }

    static var lifetimeFetchedBytes: Int64 {
        fetchedLock.lock(); defer { fetchedLock.unlock() }
        return fetchedBytesTotal
    }

    /// Bumped by every reset, so a reader of `lifetimeFetchedBytes` deltas can tell that a session
    /// start in between (`startMemoryProbe`) zeroed the tally under it.
    static var lifetimeFetchedResetCount: Int {
        fetchedLock.lock(); defer { fetchedLock.unlock() }
        return fetchedResetCount
    }

    static func resetLifetimeFetchedBytes() {
        fetchedLock.lock()
        fetchedBytesTotal = 0
        fetchedResetCount &+= 1
        fetchedLock.unlock()
    }
}

/// One range request's delivery. The decision is made at the response head, where nothing of the body
/// has been taken yet, and the body is capped at the range that was asked for.
private final class RangeFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let offset: Int64
    private let length: Int
    private(set) var response: HTTPURLResponse?
    private(set) var answer: AVIOReader.RangeAnswer = .unjudged
    private(set) var body = Data()
    var onCompletion: (() -> Void)?

    init(offset: Int64, length: Int) {
        self.offset = offset
        self.length = length
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        self.response = http
        answer = AVIOReader.rangeAnswer(
            http, requestedStart: offset, requestedEnd: offset + Int64(length) - 1)
        switch answer {
        case .honoured, .overWide:
            body.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(length)))))
            completionHandler(.allow)
        case .ignored, .wholeFile, .misplaced, .unjudged:
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let room = length - body.count
        if room > 0 { body.append(data.prefix(room)) }
        // A body that ends on the range end is left to finish, which keeps the connection for the
        // next range. Hanging up is for what runs past it.
        if data.count > room || (answer == .overWide && body.count >= length) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?()
    }
}
