import Foundation

/// AE#732: the HLS VOD ingest's transport under `LoadOptions.heldSourceConnection`.
///
/// Some origins answer an HLS segment reliably only over one persistent HTTP/1.1 connection: h2 and
/// freshly opened HTTP/1.1 connections are refused (403) while consecutive requests on one keep-alive
/// connection are served. Forcing the protocol per request is therefore not enough, the connection has
/// to outlive the segment, which is what this pool is for. It is the HLS sibling of
/// `HeldSourceConnection` (#377) and shares its wire format: HTTP/1.1 written by the engine over a
/// `URLSessionStreamTask`, TLS through `EngineTLS`, no ALPN and so never h2, no system proxy.
///
/// One request per origin (scheme, host, port) at a time: a request claims its origin's connection
/// and the next one waits until that connection is back in the pool or closed. A successful body is
/// handed to the caller as it arrives (`Body`), so a slow segment feeds the demuxer while it
/// downloads instead of after. A connection goes back to the pool only after a complete response it
/// can be reused for: HTTP/1.1, no `Connection: close`, and a body with a known end. A body its
/// caller abandons (a seek) is drained when little of it is left, inside `maxDrainBytes` and
/// `drainDeadline`, so the next request can still ride the same socket; a larger remainder closes it.
final class PersistentHTTP1Transport: @unchecked Sendable {
    static let maxRedirects = 3
    /// Idle connections kept, one per origin. A segment redirected to a CDN host keeps both the
    /// playlist origin and the CDN connection warm.
    private static let maxIdleOrigins = 2
    /// An abandoned body with more than this left closes its connection instead of draining it.
    static let maxDrainBytes: Int64 = 2 * 1024 * 1024
    /// How long a drain may hold up the next request before its connection is closed instead.
    static let drainDeadline: TimeInterval = 3

    struct Response {
        let body: Data
        let response: HTTPURLResponse
    }

    /// The origin's connection while a request or its body is out, and who waits for it.
    private struct Claim {
        var connection: PersistentHTTP1Connection?
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    let label: String
    private let readTimeout: TimeInterval
    private let lock = NSLock()
    private var idle: [Origin: PersistentHTTP1Connection] = [:]
    private var claims: [Origin: Claim] = [:]
    private var closed = false
    private var nextConnectionID = 0

    init(label: String, readTimeout: TimeInterval = PersistentHTTP1Connection.defaultReadTimeout) {
        self.label = label
        self.readTimeout = readTimeout
    }

    /// GET `url` with `headers`, redirects followed under the #126 header policy, the whole body
    /// collected. A non-2xx answer comes back with its status and an empty body. Throws
    /// `BoundedFetch.Exceeded` for a 2xx body over `limit`.
    func get(_ url: URL, headers: [String: String], limit: Int,
             diagnosticContext: SourceNetworkDiagnostics.Context? = nil,
             role: SourceNetworkDiagnostics.Role = .boundedBody) async throws -> Response {
        let body = try await open(url, headers: headers, limit: limit,
                                  diagnosticContext: diagnosticContext, role: role)
        var data = Data()
        while let chunk = try await body.next() {
            data.append(chunk)
        }
        return Response(body: data, response: body.response)
    }

    /// GET `url` and return as soon as the response head is in. A 2xx body is read through the
    /// returned `Body`, which holds the origin until it ends or is abandoned; every other answer has
    /// been read to its end already and its `Body` is empty.
    func open(_ url: URL, headers: [String: String], limit: Int,
              diagnosticContext: SourceNetworkDiagnostics.Context? = nil,
              role: SourceNetworkDiagnostics.Role = .boundedBody) async throws -> Body {
        let trace = SourceNetworkDiagnostics.Trace(role: role, context: diagnosticContext)
        let hop = OpenHop(url: url)
        do {
            return try await open(url, headers: headers, limit: limit, trace: trace, hop: hop)
        } catch {
            // The hop that failed, with the status its head carried: a failure after a redirect or
            // after the head arrived (an oversized or malformed answer) names what was answered.
            trace.record(error is BoundedFetch.Exceeded ? .bodyLimitExceeded : .completed,
                         originalURL: url, url: hop.url, status: hop.status, error: error)
            throw error
        }
    }

    /// The request an open is on, for the terminal event of an open that fails. Task-confined.
    private final class OpenHop {
        var url: URL
        var status: Int?
        init(url: URL) { self.url = url }
    }

    private func open(_ url: URL, headers: [String: String], limit: Int,
                      trace: SourceNetworkDiagnostics.Trace, hop: OpenHop) async throws -> Body {
        var target = url
        var hops = 0
        while true {
            hop.url = target
            hop.status = nil
            let hopHeaders = RedirectHeaderPolicy.headersToReplay(
                extraHeaders: headers, originalURL: url, redirectURL: target)
            let (connection, head, reused) = try await request(target, headers: hopHeaders)
            hop.status = head.status
            trace.record(.response, originalURL: url, url: target, status: head.status)
            let success = (200..<300).contains(head.status)
            let location = HeldSourceConnection.redirectLocation(head)
            guard let response = HeldSourceConnection.makeResponse(head, url: target) else {
                release(connection, refusal: "status \(head.status)")
                throw PersistentHTTP1Connection.ConnectionError.malformed("status \(head.status)")
            }
            if !success || location != nil {
                let refusal: String?
                do {
                    refusal = try await connection.discardBody(head)
                } catch {
                    release(connection, refusal: Task.isCancelled ? "cancelled" : EngineLog.summary(of: error))
                    throw error
                }
                release(connection, refusal: refusal)
                if let location {
                    guard hops < Self.maxRedirects else {
                        throw PersistentHTTP1Connection.ConnectionError.tooManyRedirects
                    }
                    guard let next = URL(string: location, relativeTo: target)?.absoluteURL else {
                        throw PersistentHTTP1Connection.ConnectionError.malformed("unresolvable Location: \(location)")
                    }
                    trace.record(.redirect, originalURL: url, url: next, status: head.status)
                    hops += 1
                    target = next
                    continue
                }
                trace.record(.completed, originalURL: url, url: target, status: head.status)
                return Body(finished: response)
            }
            let framing = PersistentHTTP1Connection.framing(for: head)
            if case .identity(let length) = framing, length > Int64(limit) {
                release(connection, refusal: "body of \(length) bytes over the \(limit) byte limit")
                throw BoundedFetch.Exceeded(limit: limit)
            }
            return Body(
                transport: self, connection: connection, head: head, response: response,
                framing: framing, limit: limit, reused: reused, trace: trace, originalURL: url)
        }
    }

    /// Closes every connection, idle or out, and refuses further requests.
    func close() {
        lock.lock()
        closed = true
        let connections = Array(idle.values) + claims.values.compactMap(\.connection)
        let waiters = claims.values.flatMap(\.waiters)
        idle.removeAll()
        claims.removeAll()
        lock.unlock()
        for connection in connections { connection.retire(reason: "transport closed") }
        for waiter in waiters { waiter.resume() }
    }

    /// Sends one request and reads its response head on a pooled connection. A REUSED connection that
    /// fails before a response head is retried once on a fresh one: an origin may close an idle
    /// keep-alive connection at any time, and the request on it never reached anyone (RFC 9112 9.3.1).
    private func request(
        _ target: URL, headers: [String: String]
    ) async throws -> (PersistentHTTP1Connection, HeldSourceConnection.ResponseHead, Bool) {
        guard let origin = Origin(target) else {
            throw PersistentHTTP1Connection.ConnectionError.unsupportedURL(target)
        }
        var connection = try await checkOut(origin)
        do {
            return (connection, try await connection.sendRequest(target: target, headers: headers), connection.requestCount > 1)
        } catch PersistentHTTP1Connection.ConnectionError.staleKeepAlive where connection.requestCount > 1 {
            connection.retire(reason: "stale keep-alive")
            do {
                try Task.checkCancellation()
                connection = try openFresh(origin)
                replaceClaim(origin, with: connection)
                return (connection, try await connection.sendRequest(target: target, headers: headers), false)
            } catch {
                release(connection, refusal: Task.isCancelled ? "cancelled" : EngineLog.summary(of: error))
                throw error
            }
        } catch {
            release(connection, refusal: Task.isCancelled ? "cancelled" : EngineLog.summary(of: error))
            throw error
        }
    }

    /// Claims `origin` and returns its idle connection or a fresh one. While another request holds the
    /// origin, waits for it: a second connection beside a response still in flight is the pattern the
    /// origins this path exists for refuse. A body holds it no longer than its next stall, its drain
    /// deadline or its end.
    private func checkOut(_ origin: Origin) async throws -> PersistentHTTP1Connection {
        while true {
            // A request cancelled while it waited must not take the connection: its cancellation
            // handler would close the socket the drain just kept.
            try Task.checkCancellation()
            if let connection = try claim(origin) { return connection }
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let parked = lock.withLock { () -> Bool in
                    guard !closed, claims[origin] != nil else { return false }
                    claims[origin]?.waiters.append(waiter)
                    return true
                }
                if !parked { waiter.resume() }
            }
        }
    }

    /// The claimed connection, nil while another request holds `origin`.
    private func claim(_ origin: Origin) throws -> PersistentHTTP1Connection? {
        try lock.withLock { () -> PersistentHTTP1Connection? in
            if closed { throw CancellationError() }
            guard claims[origin] == nil else { return nil }
            let connection = idle.removeValue(forKey: origin) ?? makeConnection(origin)
            claims[origin] = Claim(connection: connection)
            return connection
        }
    }

    private func openFresh(_ origin: Origin) throws -> PersistentHTTP1Connection {
        try lock.withLock {
            if closed { throw CancellationError() }
            return makeConnection(origin)
        }
    }

    /// Under `lock`.
    private func makeConnection(_ origin: Origin) -> PersistentHTTP1Connection {
        nextConnectionID += 1
        return PersistentHTTP1Connection(
            origin: origin, label: "\(label)#\(nextConnectionID)", readTimeout: readTimeout)
    }

    private func replaceClaim(_ origin: Origin, with connection: PersistentHTTP1Connection) {
        lock.withLock { claims[origin]?.connection = connection }
    }

    /// Ends the claim `connection` holds: back to the pool when `refusal` is nil, closed otherwise,
    /// and the next waiting request goes ahead. Idempotent.
    fileprivate func release(_ connection: PersistentHTTP1Connection, refusal: String?) {
        lock.lock()
        var waiters: [CheckedContinuation<Void, Never>] = []
        if let claim = claims[connection.origin], claim.connection === connection {
            claims.removeValue(forKey: connection.origin)
            waiters = claim.waiters
        }
        var evicted: [PersistentHTTP1Connection] = []
        var pooled = false
        if refusal == nil, !closed, !connection.isRetired {
            if let previous = idle[connection.origin], previous !== connection { evicted.append(previous) }
            idle[connection.origin] = connection
            pooled = true
            if idle.count > Self.maxIdleOrigins,
               let oldest = idle.filter({ $0.key != connection.origin })
                .min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                idle.removeValue(forKey: oldest.key)
                evicted.append(oldest.value)
            }
        }
        lock.unlock()
        if !pooled { connection.retire(reason: refusal ?? "transport closed") }
        for stale in evicted { stale.retire(reason: "origin change") }
        for waiter in waiters { waiter.resume() }
    }

    struct Origin: Hashable, CustomStringConvertible {
        let secure: Bool
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let host = url.host?.lowercased(), !host.isEmpty,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            secure = scheme == "https"
            self.host = host
            port = url.port ?? (secure ? 443 : 80)
        }

        var description: String { "\(secure ? "https" : "http")://\(host):\(port)" }
    }

    /// A 2xx body, read in the pieces the socket delivers. One consumer at a time. Its end returns the
    /// connection to the pool; `abandon()`, or cancelling the task inside `next()`, drains or closes it.
    final class Body: @unchecked Sendable {
        let response: HTTPURLResponse
        /// `Content-Length`, nil for a chunked or close-framed body.
        let expectedLength: Int64?

        private let transport: PersistentHTTP1Transport?
        private let connection: PersistentHTTP1Connection?
        private let head: HeldSourceConnection.ResponseHead?
        private let limit: Int
        private let reused: Bool
        private let trace: SourceNetworkDiagnostics.Trace?
        private let originalURL: URL?
        private let started = Date()
        private let lock = NSLock()
        private var framing: PersistentHTTP1Connection.Framing
        private var received: Int64 = 0
        private var reading = false
        private var abandoned = false
        /// Set once the claim is released, by whichever path ends the body first.
        private var released = false

        fileprivate init(finished response: HTTPURLResponse) {
            self.response = response
            expectedLength = 0
            transport = nil
            connection = nil
            head = nil
            limit = 0
            reused = false
            trace = nil
            originalURL = nil
            framing = .empty
            released = true
        }

        fileprivate init(
            transport: PersistentHTTP1Transport,
            connection: PersistentHTTP1Connection,
            head: HeldSourceConnection.ResponseHead,
            response: HTTPURLResponse,
            framing: PersistentHTTP1Connection.Framing,
            limit: Int,
            reused: Bool,
            trace: SourceNetworkDiagnostics.Trace,
            originalURL: URL
        ) {
            self.transport = transport
            self.connection = connection
            self.head = head
            self.response = response
            self.framing = framing
            self.limit = limit
            self.reused = reused
            self.trace = trace
            self.originalURL = originalURL
            if case .identity(let length) = framing { expectedLength = length } else { expectedLength = nil }
        }

        deinit {
            // A body dropped unread must not hold its origin.
            finish(refusal: "body dropped mid-read", phase: .abandoned)
        }

        /// The next piece of the body, nil at its end.
        func next() async throws -> Data? {
            guard let connection else { return nil }
            if Task.isCancelled {
                abandon()
                throw CancellationError()
            }
            let current = lock.withLock { () -> PersistentHTTP1Connection.Framing? in
                guard !released, !abandoned else { return nil }
                reading = true
                return framing
            }
            guard let current else {
                if lock.withLock({ abandoned }) { throw CancellationError() }
                return nil
            }
            let chunk: Data?
            let advanced: PersistentHTTP1Connection.Framing
            do {
                (chunk, advanced) = try await withTaskCancellationHandler {
                    try await connection.readChunk(current, progress: progress)
                } onCancel: {
                    self.abandon()
                }
            } catch {
                let wasAbandoned = lock.withLock { () -> Bool in
                    reading = false
                    return abandoned
                }
                finish(refusal: (wasAbandoned ? "drain failed: " : "") + EngineLog.summary(of: error), error: error)
                if wasAbandoned { throw CancellationError() }
                throw error
            }
            enum Step { case deliver, end, overLimit, drain }
            let step = lock.withLock { () -> Step in
                reading = false
                framing = advanced
                if let chunk { received += Int64(chunk.count) }
                if abandoned { return .drain }
                if chunk == nil { return .end }
                if received > Int64(limit) { return .overLimit }
                return .deliver
            }
            switch step {
            case .deliver:
                return chunk
            case .end:
                let refusal = head.flatMap { PersistentHTTP1Connection.reuseRefusal($0, advanced) }
                EngineLog.emit(
                    "[HLSVODIngest] AE#732 connection \(connection.label) request \(connection.requestCount) "
                        + "status=\(response.statusCode) \(progress()) \(reused ? "reused" : "fresh")"
                        + (refusal.map { ", not reusable: \($0)" } ?? ""),
                    category: .engine, level: .verbose)
                finish(refusal: refusal)
                return nil
            case .overLimit:
                finish(refusal: "body over the \(limit) byte limit", phase: .bodyLimitExceeded)
                throw BoundedFetch.Exceeded(limit: limit)
            case .drain:
                // The read in flight when the body was abandoned is back; the drain goes on from
                // here, off the caller's task.
                if chunk == nil {
                    finish(refusal: head.flatMap { PersistentHTTP1Connection.reuseRefusal($0, advanced) }, drained: true)
                } else {
                    Task { await self.drain() }
                }
                throw CancellationError()
            }
        }

        /// Stops reading. Little left, at a rate that brings it in before `drainDeadline`: drained in
        /// the background, the connection kept, and the next request to this origin waits for it.
        /// Otherwise the connection is closed at once, since a drain that cannot finish only delays the
        /// next request by its deadline and loses the connection anyway. Idempotent.
        func abandon() {
            guard let connection else { return }
            let decision = lock.withLock { () -> (inFlight: Bool, drainable: Bool)? in
                guard !released, !abandoned else { return nil }
                abandoned = true
                switch framing {
                case .identity(let remaining):
                    return (reading, remaining <= PersistentHTTP1Transport.maxDrainBytes && drainsInTime(remaining))
                case .chunked, .empty: return (reading, true)
                case .untilClose: return (reading, false)
                }
            }
            guard let decision else { return }
            guard decision.drainable else {
                finish(refusal: "abandoned mid-body, \(progress())")
                return
            }
            EngineLog.emit(
                "[HLSVODIngest] AE#732 connection \(connection.label) draining abandoned body, \(progress())",
                category: .engine)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(PersistentHTTP1Transport.drainDeadline * 1_000_000_000))
                self.finish(refusal: "drain not done within \(Int(PersistentHTTP1Transport.drainDeadline)) s, \(self.progress())")
            }
            if !decision.inFlight {
                Task { await self.drain() }
            }
        }

        /// Under `lock`. Whether `remaining` bytes arrive within the drain deadline at the rate this body
        /// has come in so far; a body too young to have a rate gets the benefit of the doubt.
        private func drainsInTime(_ remaining: Int64) -> Bool {
            let elapsed = Date().timeIntervalSince(started)
            guard remaining > 0, received > 0, elapsed >= 0.25 else { return true }
            let rate = Double(received) / elapsed
            return Double(remaining) / rate <= PersistentHTTP1Transport.drainDeadline
        }

        private func drain() async {
            guard let connection else { return }
            var drained: Int64 = 0
            while let current = lock.withLock({ released ? nil : framing }) {
                do {
                    let (chunk, advanced) = try await connection.readChunk(current, progress: progress)
                    lock.withLock { framing = advanced }
                    guard let chunk else {
                        finish(refusal: head.flatMap { PersistentHTTP1Connection.reuseRefusal($0, advanced) }, drained: true)
                        return
                    }
                    drained += Int64(chunk.count)
                    if drained > PersistentHTTP1Transport.maxDrainBytes {
                        finish(refusal: "drain over \(PersistentHTTP1Transport.maxDrainBytes) bytes")
                        return
                    }
                } catch {
                    finish(refusal: "drain failed: \(EngineLog.summary(of: error))", error: error)
                    return
                }
            }
        }

        /// Releases the claim once, from whichever of the end, a failure, the drain or its deadline
        /// gets there first.
        private func finish(refusal: String?, drained: Bool = false,
                            phase: SourceNetworkDiagnostics.Phase = .completed, error: Error? = nil) {
            guard let connection else { return }
            let outcome = lock.withLock { () -> (bytes: Int64, abandoned: Bool)? in
                guard !released else { return nil }
                released = true
                return (received, abandoned)
            }
            guard let outcome else { return }
            if drained, refusal == nil {
                EngineLog.emit(
                    "[HLSVODIngest] AE#732 connection \(connection.label) drained, kept for the next request",
                    category: .engine)
            }
            if let transport {
                transport.release(connection, refusal: refusal)
            } else {
                connection.retire(reason: refusal ?? "transport gone")
            }
            // Emit outside the body/pool locks, once, after the request releases its origin.
            if let trace, let originalURL {
                trace.record(outcome.abandoned ? .abandoned : phase,
                             originalURL: originalURL, url: response.url ?? originalURL,
                             status: response.statusCode, bytes: outcome.bytes, error: error)
            }
        }

        /// "received/expected bytes in N s", for the log lines and the stall error.
        private func progress() -> String {
            let (count, expected) = lock.withLock { (received, expectedLength) }
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            return "\(count)/\(expected.map(String.init) ?? "?") bytes in \(elapsed) s"
        }
    }
}

/// One HTTP/1.1 keep-alive connection: request, response head, body, and the next request on the
/// same socket. Not safe for concurrent requests; the pool hands it to one caller at a time.
final class PersistentHTTP1Connection: @unchecked Sendable {
    /// Longest wait for the next byte. The only time limit on a body: a slow segment that keeps
    /// arriving is never cut off, one that stops is.
    static let defaultReadTimeout: TimeInterval = 30
    private static let writeTimeout: TimeInterval = 20
    /// Wall-clock ceiling from sending a request to its complete response head.
    static let headDeadline: TimeInterval = 45
    private static let maxHeadBytes = 128 * 1024
    private static let maxReadBytes = 1 * 1024 * 1024
    /// A refused or redirecting answer is read to its end so the connection survives it; one with a
    /// larger body than this is not worth the bytes, and closes the connection instead.
    private static let maxDiscardedBodyBytes = 64 * 1024

    enum ConnectionError: LocalizedError {
        case malformed(String)
        case tooManyRedirects
        case unsupportedURL(URL)
        /// The origin closed a reused connection before answering; the request is safe to repeat.
        case staleKeepAlive
        /// No complete response head within `headDeadline` of sending the request.
        case headDeadlineExceeded
        /// No byte of the body for `seconds`; `progress` is what had arrived by then.
        case stalled(seconds: TimeInterval, progress: String)

        var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "malformed HTTP response: \(detail)"
            case .tooManyRedirects: return "too many redirects"
            case .unsupportedURL(let url): return "unsupported URL for a persistent connection: \(url)"
            case .staleKeepAlive: return "keep-alive connection closed by the origin"
            case .headDeadlineExceeded:
                return "no response head within \(Int(PersistentHTTP1Connection.headDeadline)) s"
            case .stalled(let seconds, let progress):
                return "body stalled, no bytes for \(String(format: "%g", seconds)) s after \(progress)"
            }
        }
    }

    enum Framing {
        case identity(remaining: Int64)
        case chunked(ChunkedBodyDecoder)
        case untilClose
        case empty
    }

    let origin: PersistentHTTP1Transport.Origin
    let label: String
    private let readTimeout: TimeInterval
    private let stateLock = NSLock()
    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private var retired = false
    private var pending = Data()
    private var _requestCount = 0
    private var _lastUsed = Date.distantPast

    init(origin: PersistentHTTP1Transport.Origin, label: String, readTimeout: TimeInterval = defaultReadTimeout) {
        self.origin = origin
        self.label = label
        self.readTimeout = readTimeout
    }

    var requestCount: Int { stateLock.withLock { _requestCount } }
    var isRetired: Bool { stateLock.withLock { retired } }
    var lastUsed: Date { stateLock.withLock { _lastUsed } }

    /// Writes the request and reads the response head. Cancellation closes the connection: a request
    /// without its answer leaves nothing on the socket worth keeping.
    func sendRequest(target: URL, headers: [String: String]) async throws -> HeldSourceConnection.ResponseHead {
        let task = try connectIfNeeded()
        let reused = stateLock.withLock { () -> Bool in
            _requestCount += 1
            _lastUsed = Date()
            return _requestCount > 1
        }
        let deadline = Date().addingTimeInterval(Self.headDeadline)
        return try await withTaskCancellationHandler {
            let request = try HeldSourceConnection.requestBytes(
                target: target, host: origin.host, port: origin.port, secure: origin.secure,
                offset: nil, extraHeaders: headers, userAgent: nil)
            do {
                try await task.write(request, timeout: Self.writeTimeout)
            } catch {
                if reused, !Task.isCancelled { throw ConnectionError.staleKeepAlive }
                throw error
            }
            do {
                return try await readHead(task, reused: reused, deadline: deadline)
            } catch let error as ConnectionError {
                throw error
            } catch {
                if reused, !Task.isCancelled { throw ConnectionError.staleKeepAlive }
                throw error
            }
        } onCancel: {
            self.retire(reason: "cancelled")
        }
    }

    /// The next piece of a body under `framing`, nil at its end, plus the framing after it. No
    /// cancellation handler: the caller decides whether an abandoned body is drained or closed.
    func readChunk(
        _ framing: Framing, progress: () -> String,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> (Data?, Framing) {
        guard let task = stateLock.withLock({ retired ? nil : task }) else { throw CancellationError() }
        while true {
            switch framing {
            case .empty:
                return (nil, framing)
            case .identity(let remaining):
                if remaining <= 0 { return (nil, framing) }
                let data = try await nextBytes(task, upTo: Int(min(remaining, Int64(Self.maxReadBytes))), progress: progress)
                guard let data else {
                    throw ConnectionError.malformed("connection closed \(remaining) bytes before the end of the body")
                }
                return (data, .identity(remaining: remaining - Int64(data.count)))
            case .chunked(let decoder):
                if let out = try decoder.take(upTo: Self.maxReadBytes) { return (out, framing) }
                if decoder.isComplete { return (nil, framing) }
                guard let data = try await nextBytes(task, upTo: Self.maxReadBytes, progress: progress) else {
                    throw ConnectionError.malformed("connection closed inside a chunked body")
                }
                decoder.feed(data)
            case .untilClose:
                return (try await nextBytes(task, upTo: Self.maxReadBytes, progress: progress), framing)
            }
        }
    }

    /// Reads a non-2xx body to its end so the connection survives it. nil when the connection may
    /// carry the next request, the reason otherwise.
    func discardBody(_ head: HeldSourceConnection.ResponseHead) async throws -> String? {
        var framing = Self.framing(for: head)
        if case .identity(let length) = framing, length > Int64(Self.maxDiscardedBodyBytes) {
            return "status \(head.status) body not drained"
        }
        var discarded = 0
        let started = Date()
        while true {
            if Date().timeIntervalSince(started) > Self.headDeadline { return "status \(head.status) body too slow to drain" }
            let (chunk, advanced) = try await readChunk(framing, progress: { "\(discarded) discarded bytes" })
            framing = advanced
            guard let chunk else { break }
            discarded += chunk.count
            if discarded > Self.maxDiscardedBodyBytes { return "status \(head.status) body not drained" }
        }
        return Self.reuseRefusal(head, framing)
    }

    /// Closes the socket. Idempotent; the first reason is the one logged.
    func retire(reason: String) {
        stateLock.lock()
        if retired {
            stateLock.unlock()
            return
        }
        retired = true
        let task = self.task
        let session = self.session
        let count = _requestCount
        self.task = nil
        self.session = nil
        pending = Data()
        stateLock.unlock()
        task?.closeRead()
        task?.closeWrite()
        session?.invalidateAndCancel()
        guard task != nil else { return }
        EngineLog.emit(
            "[HLSVODIngest] AE#732 connection \(label) \(origin) closed after \(count) "
                + "request\(count == 1 ? "" : "s") reason=\(reason)",
            category: .engine)
    }

    /// Why the connection cannot carry another request after this response, nil when it can.
    static func reuseRefusal(_ head: HeldSourceConnection.ResponseHead, _ framing: Framing) -> String? {
        if case .untilClose = framing { return "body framed by close" }
        let connection = head.headers["connection"]?.lowercased() ?? ""
        if connection.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "close" }) {
            return "server close"
        }
        if !head.statusLine.hasPrefix("HTTP/1.1") { return "not HTTP/1.1 (\(head.statusLine.prefix(8)))" }
        return nil
    }

    static func framing(for head: HeldSourceConnection.ResponseHead) -> Framing {
        if (100..<200).contains(head.status) || head.status == 204 || head.status == 304 { return .empty }
        if head.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .chunked(ChunkedBodyDecoder())
        }
        if let raw = head.headers["content-length"], let length = Int64(raw), length >= 0 {
            return .identity(remaining: length)
        }
        return .untilClose
    }

    // MARK: - Wire

    private func connectIfNeeded() throws -> URLSessionStreamTask {
        stateLock.lock()
        if retired {
            stateLock.unlock()
            throw CancellationError()
        }
        if let task {
            stateLock.unlock()
            return task
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = readTimeout
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let session = URLSession(
            configuration: configuration, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        let task = session.streamTask(withHostName: origin.host, port: origin.port)
        self.session = session
        self.task = task
        stateLock.unlock()
        task.resume()
        if origin.secure { task.startSecureConnection() }
        EngineLog.emit(
            "[HLSVODIngest] AE#732 connection \(label) open \(origin) protocol=http/1.1",
            category: .engine)
        return task
    }

    private func readHead(
        _ task: URLSessionStreamTask, reused: Bool, deadline: Date
    ) async throws -> HeldSourceConnection.ResponseHead {
        let separator = Data("\r\n\r\n".utf8)
        var head = takePending()
        while head.range(of: separator) == nil {
            try Task.checkCancellation()
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw ConnectionError.headDeadlineExceeded }
            let (chunk, eof): (Data, Bool)
            do {
                (chunk, eof) = try await read(task, maxLength: 64 * 1024, timeout: min(readTimeout, left))
            } catch where Self.isTimeout(error) {
                // The read's timeout was clamped to the deadline; its expiry is the deadline's, not a
                // stall, and the socket's own POSIX timeout would say neither.
                if left < readTimeout { throw ConnectionError.headDeadlineExceeded }
                throw error
            }
            if chunk.isEmpty && eof {
                if reused, head.isEmpty { throw ConnectionError.staleKeepAlive }
                throw ConnectionError.malformed("connection closed before a response head")
            }
            head.append(chunk)
            if head.count > Self.maxHeadBytes {
                throw ConnectionError.malformed("no head terminator in \(Self.maxHeadBytes) bytes")
            }
        }
        guard let split = head.range(of: separator) else {
            throw ConnectionError.malformed("head terminator vanished")
        }
        stateLock.withLock { pending = Data(head[split.upperBound...]) }
        return try HeldSourceConnection.ResponseHead(rawHead: head[..<split.lowerBound])
    }

    /// Bytes left over from the head read first, then the socket. nil is EOF.
    private func nextBytes(
        _ task: URLSessionStreamTask, upTo limit: Int, progress: () -> String,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Data? {
        let buffered = stateLock.withLock { () -> Data in
            let slice = pending.prefix(limit)
            pending.removeFirst(slice.count)
            return Data(slice)
        }
        if !buffered.isEmpty { return buffered }
        do {
            let (data, eof) = try await read(task, maxLength: limit, timeout: readTimeout)
            if data.isEmpty && eof { return nil }
            return data
        } catch where Self.isTimeout(error) {
            throw ConnectionError.stalled(seconds: readTimeout, progress: progress())
        }
    }

    private func takePending() -> Data {
        stateLock.withLock {
            let data = pending
            pending = Data()
            return data
        }
    }

    private func read(
        _ task: URLSessionStreamTask, maxLength: Int, timeout: TimeInterval
    ) async throws -> (Data, Bool) {
        let (data, eof) = try await task.readData(
            ofMinLength: 1, maxLength: max(1, maxLength), timeout: timeout)
        return (data ?? Data(), eof)
    }

    private static func isTimeout(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSPOSIXErrorDomain && error.code == Int(ETIMEDOUT))
            || (error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut)
    }
}
