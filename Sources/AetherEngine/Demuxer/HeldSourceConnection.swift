import Foundation

/// #377: the read path a host gets by asking for `LoadOptions.heldSourceConnection`.
///
/// The default reader asks the origin for a new range every `winLowWater` of drain, because a
/// `URLSessionDataTask` has no way to say "stop sending". It cannot be suspended (#220 measured
/// the suspend advisory, 911 MB arrived after it) and a task that does park holds a dormant flow
/// whose closed receive window takes every other Network.framework flow in the process down with
/// it (#310), so since 6.11.0 the connection is ENDED at the high water instead. Against an origin
/// that refuses new requests for minutes at a stretch, that request cadence is the whole defect:
/// any reader issuing one request per 8 to 16 MB will issue one inside a refusal window, on any
/// long file.
///
/// `URLSessionStreamTask` reads are demand driven, so this path asks once and pulls. The framing
/// is ours, which is the bounded work the whole question turned on:
///
/// - **HTTP/1.1 only.** No ALPN negotiation, no h2. An origin that only serves h2 is out of scope
///   for this flag, which is one of the reasons it is opt in rather than the default.
/// - **The system proxy configuration is not in this path.** A stream task connects to a host and
///   port; `URLRequest`'s proxy handling does not apply.
/// - **TLS is the OS's**, through `startSecureConnection()` with `EngineTLS.sessionDelegate` on the
///   session, so a host trust decision reaches it the same way it reaches every other engine
///   session.
///
/// Backpressure is the delegate's to spend, not this class's: `heldConnectionPullBudget` is asked
/// before every read and its answer is how many bytes are wanted. Returning 0 ends the connection.
/// The reason that matters is #310's dose, which is the LENGTH of a dormant stretch rather than its
/// existence: a pull reader that tops the window up as the consumer takes bytes is dormant for
/// chunk size over media rate, and a reader that stops pulling entirely (a paused viewer) has to
/// end the connection instead, which is what a 0 budget is for.
protocol HeldSourceConnectionDelegate: AnyObject {
    /// Allow or refuse the response. A refusal ends the connection without reading a body.
    func heldConnection(_ connection: HeldSourceConnection,
                        didReceive response: HTTPURLResponse,
                        from url: URL) -> Bool
    /// Body bytes, already unframed (chunked transfer decoded).
    func heldConnection(_ connection: HeldSourceConnection, didReceive data: Data)
    /// How many bytes to pull next. BLOCKS until there is room, and returns 0 to end the
    /// connection. Called on the connection's own queue, never under a lock this class holds.
    func heldConnectionPullBudget(_ connection: HeldSourceConnection) -> Int
    /// The connection is over: EOF, a refused response, a transport error, or a 0 budget.
    func heldConnection(_ connection: HeldSourceConnection, didEndWith error: Error?)
}

final class HeldSourceConnection: @unchecked Sendable {
    /// Largest single read handed to the transport. Only a bound on one `readData` call: the pull
    /// budget decides how much is actually wanted, and in the steady state that is the smaller
    /// number by far.
    private static let maxReadBytes = 1 * 1024 * 1024
    /// A response head larger than this is a malformed origin rather than a large header set.
    private static let maxHeadBytes = 128 * 1024
    /// Redirect hops followed inline. The reader resolves and pins the target itself, so a hop
    /// here is the residual case (a pin that expired between resolution and this request), not
    /// the normal path.
    private static let maxRedirects = 3
    /// Per-read wire timeout. The reader's own delivery-gap watchdog is the policy instrument;
    /// this only keeps a read from parking forever when the origin goes silent mid-body.
    private static let readTimeout: TimeInterval = 30
    private static let writeTimeout: TimeInterval = 20

    /// How a body's end is recognised, which is the part `URLSession` would otherwise do.
    fileprivate enum BodyFraming {
        /// `Content-Length` bytes remain.
        case identity(remaining: Int64)
        /// `Transfer-Encoding: chunked`.
        case chunked(ChunkedBodyDecoder)
        /// Neither header: the body ends when the connection does.
        case untilClose
    }

    private enum ConnectionError: LocalizedError {
        case malformedResponse(String)
        case tooManyRedirects
        case unsupportedURL(URL)
        case invalidHeaderField(String)

        var errorDescription: String? {
            switch self {
            case .invalidHeaderField(let name): return "a line break in the request field \(name)"
            case .malformedResponse(let detail): return "malformed HTTP response: \(detail)"
            case .tooManyRedirects: return "too many redirects"
            case .unsupportedURL(let url): return "unsupported URL for a held connection: \(url)"
            }
        }
    }

    private weak var delegate: HeldSourceConnectionDelegate?
    private let extraHeaders: [String: String]
    private let offset: Int64
    private let userAgent: String?
    private let queue: DispatchQueue
    /// The reader's connection generation this transfer belongs to. Carried here because the
    /// reader's response, delivery and end handling are all keyed on it and a stale callback has
    /// to be recognisable as stale.
    let generation: Int
    /// The origin slot this connection occupies, released once by whoever gets there first.
    private var ticket: OriginRequestBudget.Ticket?

    private let stateLock = NSLock()
    private var _cancelled = false
    private var session: URLSession?
    private var task: URLSessionStreamTask?
    /// Wire bytes read past the response head, still to be unframed.
    private var pending = Data()

    /// The URL this connection ended up talking to, redirects followed.
    private(set) var respondedBy: URL

    init(url: URL,
         offset: Int64,
         extraHeaders: [String: String],
         userAgent: String?,
         label: String,
         generation: Int = 0,
         ticket: OriginRequestBudget.Ticket? = nil,
         delegate: HeldSourceConnectionDelegate) {
        self.respondedBy = url
        self.offset = offset
        self.extraHeaders = extraHeaders
        self.userAgent = userAgent
        self.generation = generation
        self.ticket = ticket
        self.delegate = delegate
        self.queue = DispatchQueue(label: "aether.avio.held.\(label)", qos: .userInitiated)
    }

    var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _cancelled
    }

    /// Open the connection and run the pull loop until it ends. Returns immediately.
    func start() {
        queue.async { [weak self] in self?.run() }
    }

    /// Give the origin slot back. Idempotent: the reader releases synchronously so the frontier
    /// re-request does not queue behind this connection, and the end callback then finds nothing.
    func releaseOriginTicket() {
        stateLock.lock()
        let held = ticket
        ticket = nil
        stateLock.unlock()
        OriginRequestBudget.shared.release(held)
    }

    /// End the connection. Idempotent, and safe from any thread including from inside a delegate
    /// callback: the loop notices on its next turn and the socket is torn down here.
    func cancel() {
        stateLock.lock()
        if _cancelled {
            stateLock.unlock()
            return
        }
        _cancelled = true
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        stateLock.unlock()
        task?.closeRead()
        task?.closeWrite()
        session?.invalidateAndCancel()
    }

    // MARK: - The loop

    private func run() {
        var failure: Error?
        do {
            try openAndPump()
        } catch {
            // A cancel races every blocking call in here, and its error is our own doing rather
            // than the origin's. Reporting it would put a transport fault in the log for every
            // deliberate end.
            failure = isCancelled ? nil : error
        }
        cancel()
        delegate?.heldConnection(self, didEndWith: failure)
    }

    private func openAndPump() throws {
        let source = respondedBy
        var target = respondedBy
        var hops = 0
        while true {
            if isCancelled { return }
            // Audit DMX-3: the headers were built for the source, so every hop gets the #126
            // policy every URLSession path applies: credentials only to the same origin, and
            // never down from https to http.
            let headers = RedirectHeaderPolicy.headersToReplay(
                extraHeaders: extraHeaders, originalURL: source, redirectURL: target)
            let head = try open(target, headers: headers)
            if let location = Self.redirectLocation(head), hops < Self.maxRedirects {
                guard let next = URL(string: location, relativeTo: target)?.absoluteURL else {
                    throw ConnectionError.malformedResponse("unresolvable Location: \(location)")
                }
                hops += 1
                closeSocket()
                OriginRequestBudget.shared.noteRedirect(from: source, to: next)
                target = next
                continue
            }
            if Self.redirectLocation(head) != nil { throw ConnectionError.tooManyRedirects }
            respondedBy = target
            guard let response = Self.makeResponse(head, url: target) else {
                throw ConnectionError.malformedResponse("status \(head.status)")
            }
            guard delegate?.heldConnection(self, didReceive: response, from: target) == true else {
                return
            }
            try pump(framing: Self.framing(for: head))
            return
        }
    }

    /// Connect, write the request, and read until the head is complete.
    private func open(_ target: URL, headers: [String: String]) throws -> ResponseHead {
        guard let host = target.host, let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ConnectionError.unsupportedURL(target)
        }
        let secure = scheme == "https"
        let port = target.port ?? (secure ? 443 : 80)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.readTimeout
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let session = URLSession(configuration: configuration,
                                 delegate: EngineTLS.sessionDelegate,
                                 delegateQueue: AVIOReader.makePlaybackDelegateQueue())
        let task = session.streamTask(withHostName: host, port: port)

        stateLock.lock()
        if _cancelled {
            stateLock.unlock()
            session.invalidateAndCancel()
            throw CancellationError()
        }
        self.session = session
        self.task = task
        pending = Data()
        stateLock.unlock()

        task.resume()
        if secure { task.startSecureConnection() }

        try write(Self.requestBytes(target: target, host: host, port: port, secure: secure,
                                    offset: offset, extraHeaders: headers,
                                    userAgent: userAgent))
        return try readHead()
    }

    private func pump(framing: BodyFraming) throws {
        var framing = framing
        while true {
            if isCancelled { return }
            guard let delegate else { return }
            let budget = delegate.heldConnectionPullBudget(self)
            if budget <= 0 { return }
            if isCancelled { return }

            let wire = try nextWireBytes(upTo: min(budget, Self.maxReadBytes), framing: &framing)
            guard let wire else { return }   // end of body
            if !wire.isEmpty { delegate.heldConnection(self, didReceive: wire) }
        }
    }

    /// One pull: read wire bytes, unframe them, and report end of body as nil.
    private func nextWireBytes(upTo limit: Int, framing: inout BodyFraming) throws -> Data? {
        switch framing {
        case .identity(let remaining):
            if remaining <= 0 { return nil }
            let want = Int(min(Int64(limit), remaining))
            guard let data = try readBody(upTo: want) else { return nil }
            framing = .identity(remaining: remaining - Int64(data.count))
            return data
        case .chunked(let decoder):
            while true {
                if let out = try decoder.take(upTo: limit) { return out }
                if decoder.isComplete { return nil }
                guard let data = try readBody(upTo: limit) else {
                    throw ConnectionError.malformedResponse("connection closed inside a chunked body")
                }
                decoder.feed(data)
            }
        case .untilClose:
            return try readBody(upTo: limit)
        }
    }

    // MARK: - Wire

    private func write(_ data: Data) throws {
        guard let task = currentTask() else { throw CancellationError() }
        // Ownership passes to the callback and back on the semaphore, so only one side ever
        // touches the box. That is the same handoff the chunk fetch path uses.
        let outcome = CallbackOutcome()
        let done = DispatchSemaphore(value: 0)
        task.write(data, timeout: Self.writeTimeout) { error in
            outcome.error = error
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw error }
    }

    /// Body bytes from the buffer, refilled from the socket when it is empty. nil is EOF.
    private func readBody(upTo limit: Int) throws -> Data? {
        stateLock.lock()
        if !pending.isEmpty {
            let slice = pending.prefix(limit)
            pending.removeFirst(slice.count)
            stateLock.unlock()
            return Data(slice)
        }
        stateLock.unlock()
        let (data, eof) = try readFromSocket(maxLength: limit)
        if data.isEmpty && eof { return nil }
        return data
    }

    private func readHead() throws -> ResponseHead {
        var head = Data()
        let separator = Data("\r\n\r\n".utf8)
        while head.range(of: separator) == nil {
            let (chunk, eof) = try readFromSocket(maxLength: 64 * 1024)
            if chunk.isEmpty && eof {
                throw ConnectionError.malformedResponse("connection closed before a response head")
            }
            head.append(chunk)
            if head.count > Self.maxHeadBytes {
                throw ConnectionError.malformedResponse("no head terminator in \(Self.maxHeadBytes) bytes")
            }
        }
        guard let split = head.range(of: separator) else {
            throw ConnectionError.malformedResponse("head terminator vanished")
        }
        let body = Data(head[split.upperBound...])
        stateLock.lock()
        pending = body + pending
        stateLock.unlock()
        return try ResponseHead(rawHead: head[..<split.lowerBound])
    }

    private func readFromSocket(maxLength: Int) throws -> (Data, Bool) {
        guard let task = currentTask() else { throw CancellationError() }
        let outcome = CallbackOutcome()
        let done = DispatchSemaphore(value: 0)
        task.readData(ofMinLength: 1, maxLength: max(1, maxLength), timeout: Self.readTimeout) { data, eof, error in
            outcome.data = data ?? Data()
            outcome.atEOF = eof
            outcome.error = error
            done.signal()
        }
        done.wait()
        if let error = outcome.error { throw error }
        return (outcome.data, outcome.atEOF)
    }

    /// One transport callback's result, handed over on the semaphore. @unchecked Sendable: the
    /// caller blocks until the callback has signalled, so the two never touch it at once.
    private final class CallbackOutcome: @unchecked Sendable {
        var data = Data()
        var atEOF = false
        var error: Error?
    }

    private func currentTask() -> URLSessionStreamTask? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _cancelled ? nil : task
    }

    private func closeSocket() {
        stateLock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        pending = Data()
        stateLock.unlock()
        task?.closeRead()
        task?.closeWrite()
        session?.invalidateAndCancel()
    }
}

// MARK: - Framing

extension HeldSourceConnection {
    /// A parsed status line plus headers, keys lowercased.
    struct ResponseHead {
        let status: Int
        let headers: [String: String]
        let statusLine: String

        init(rawHead: Data) throws {
            let text = String(decoding: rawHead, as: UTF8.self)
            var lines = text.components(separatedBy: "\r\n")
            statusLine = lines.isEmpty ? "" : lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let code = Int(parts[1]) else {
                throw ConnectionError.malformedResponse("status line: \(statusLine)")
            }
            status = code
            var headers: [String: String] = [:]
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                // A repeated header folds with a comma, as the field-value grammar says.
                if let existing = headers[String(key)] {
                    headers[String(key)] = existing + ", " + value
                } else {
                    headers[String(key)] = value
                }
            }
            self.headers = headers
        }
    }

    static func redirectLocation(_ head: ResponseHead) -> String? {
        guard (301...308).contains(head.status), head.status != 304, head.status != 305 else { return nil }
        return head.headers["location"]
    }

    /// `HTTPURLResponse` is what the reader's response handling is written against, so the parsed
    /// head is handed over in that shape rather than duplicating the status, size and refusal
    /// classification that already live there.
    static func makeResponse(_ head: ResponseHead, url: URL) -> HTTPURLResponse? {
        HTTPURLResponse(url: url,
                        statusCode: head.status,
                        httpVersion: "HTTP/1.1",
                        headerFields: head.headers)
    }

    fileprivate static func framing(for head: ResponseHead) -> BodyFraming {
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .chunked(ChunkedBodyDecoder())
        }
        if let raw = head.headers["content-length"], let length = Int64(raw) {
            return .identity(remaining: length)
        }
        return .untilClose
    }

    static func requestBytes(target: URL,
                             host: String,
                             port: Int,
                             secure: Bool,
                             offset: Int64?,
                             extraHeaders: [String: String],
                             userAgent: String?) throws -> Data {
        // Audit DMX-4: the path goes on the wire as the URL spells it. `URL.path` is decoded, so
        // `%20`, `%3F` or `%2F` changed the resource asked for, a trailing slash was dropped, and a
        // `%0D%0A` in a redirect target became a raw line break in the request.
        let components = URLComponents(url: target, resolvingAgainstBaseURL: true)
        let encodedPath = components?.percentEncodedPath ?? ""
        var path = encodedPath.isEmpty ? "/" : encodedPath
        if let query = components?.percentEncodedQuery, !query.isEmpty { path += "?" + query }
        // An IPv6 literal is bracketed in Host, or its colons read as the port separator.
        let hostName = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        // A non-default port belongs in Host, since the origin may route on it.
        let hostHeader = (secure && port == 443) || (!secure && port == 80) ? hostName : "\(hostName):\(port)"

        // A nil offset is a whole-resource GET (AE#732's segment fetches), which carries no Range of
        // its own; the caller's applies, which is how an EXT-X-BYTERANGE segment names its sub-range.
        var lines = ["GET \(path) HTTP/1.1",
                     "Host: \(hostHeader)"]
        if let offset { lines.append("Range: bytes=\(offset)-") }
        lines += ["Accept: */*",
                  "Accept-Encoding: identity",
                  "Connection: keep-alive"]
        if let userAgent { lines.append("User-Agent: \(userAgent)") }
        // The caller's headers win: they carry the source's authentication, and a duplicate of a
        // header set above would be sent twice.
        let reserved = Set(["host", "connection", "accept-encoding"] + (offset == nil ? [] : ["range"]))
        for (name, value) in extraHeaders where !reserved.contains(name.lowercased()) {
            lines.removeAll { $0.lowercased().hasPrefix(name.lowercased() + ":") }
            lines.append("\(name): \(value)")
        }
        // Every field is written raw, so one carrying a line break would add lines of its own.
        // `isNewline`, because CRLF is a single Swift Character that matches neither "\r" nor "\n".
        if let bad = lines.first(where: { $0.contains(where: \.isNewline) }) {
            throw ConnectionError.invalidHeaderField(String(bad.prefix(while: { $0 != ":" && $0 != " " })))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

/// `Transfer-Encoding: chunked` decoder. Fed wire bytes, asked for body bytes.
///
/// An origin serving a Range answers 206 with a `Content-Length`, so this is the residual case: a
/// 200 from an origin that does not know its own length. It exists because refusing the encoding
/// would be a silent trap rather than an unsupported case: the reader downstream cannot tell a
/// chunk size line from media bytes, so an undecoded chunked body corrupts the container quietly.
final class ChunkedBodyDecoder {
    private enum State {
        case size
        case data(remaining: Int)
        /// The CRLF that closes a chunk's data.
        case dataTerminator
        /// Trailer fields after the zero-size chunk, ending at an empty line.
        case trailer
        case done
    }

    private var buffer = Data()
    private var state: State = .size

    /// Audit DMX-111: a size, terminator or trailer line longer than this is a malformed origin. A
    /// line with no CRLF would otherwise be buffered and rescanned for one that is not coming.
    static let maxLineBytes = 4096
    /// Framing bytes (size lines, terminators, blank lines, trailer fields) the decoder consumes
    /// without one byte of body in between. Bounds the states that consume without producing:
    /// endless blank lines, endless trailer fields.
    static let maxFramingBytes = 64 * 1024
    private static let crlf = Data("\r\n".utf8)
    private var framingBytes = 0

    var isComplete: Bool {
        if case .done = state { return true }
        return false
    }

    func feed(_ data: Data) {
        buffer.append(data)
    }

    /// Up to `limit` decoded body bytes, or nil when the buffer holds no complete body bytes yet.
    /// nil with `isComplete` set is the end of the body.
    func take(upTo limit: Int) throws -> Data? {
        var out = Data()
        loop: while out.count < limit {
            switch state {
            case .done:
                break loop
            case .size:
                guard let line = try takeLine() else { break loop }
                if line.isEmpty { continue }   // tolerate the CRLF of a preceding chunk
                let sizeField = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
                guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    throw ChunkedError.badChunkSize(line)
                }
                state = size == 0 ? .trailer : .data(remaining: size)
            case .data(let remaining):
                if buffer.isEmpty { break loop }
                let want = min(remaining, min(limit - out.count, buffer.count))
                if want == 0 { break loop }
                out.append(buffer.prefix(want))
                buffer.removeFirst(want)
                framingBytes = 0
                state = remaining - want == 0 ? .dataTerminator : .data(remaining: remaining - want)
            case .dataTerminator:
                guard let line = try takeLine() else { break loop }
                guard line.isEmpty else { throw ChunkedError.expectedChunkTerminator(line) }
                state = .size
            case .trailer:
                guard let line = try takeLine() else { break loop }
                if line.isEmpty { state = .done }
            }
        }
        return out.isEmpty ? nil : out
    }

    /// The next CRLF-terminated line, nil while there is not one yet. Only the first
    /// `maxLineBytes + 2` bytes are searched, so a line with no end costs a bounded scan and is
    /// refused instead of waited for.
    private func takeLine() throws -> String? {
        let window = buffer.startIndex..<min(buffer.endIndex, buffer.startIndex + Self.maxLineBytes + 2)
        guard let range = buffer.range(of: Self.crlf, in: window) else {
            if buffer.count >= Self.maxLineBytes + 2 { throw ChunkedError.lineTooLong }
            return nil
        }
        framingBytes += buffer.distance(from: buffer.startIndex, to: range.upperBound)
        if framingBytes > Self.maxFramingBytes { throw ChunkedError.framingTooLong }
        let line = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<range.upperBound)
        return line
    }

    enum ChunkedError: LocalizedError, Equatable {
        case badChunkSize(String)
        case expectedChunkTerminator(String)
        case lineTooLong
        case framingTooLong

        var errorDescription: String? {
            switch self {
            case .badChunkSize(let line): return "bad chunk size line: \(line)"
            case .expectedChunkTerminator(let line): return "expected a chunk terminator, got: \(line)"
            case .lineTooLong: return "a chunked size or trailer line passed \(ChunkedBodyDecoder.maxLineBytes) bytes"
            case .framingTooLong: return "chunked framing passed \(ChunkedBodyDecoder.maxFramingBytes) bytes without a body byte"
            }
        }
    }
}

// MARK: - The reader's transfer abstraction

extension HeldSourceConnection: PersistentTransfer {
    func startTransfer() { start() }
    func cancelTransfer() { cancel() }
    /// The whole point of this transport: nothing arrives that was not asked for, so the reader's
    /// high-water end has nothing to protect against here.
    var isDemandDriven: Bool { true }
}
