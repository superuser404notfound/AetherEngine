import Foundation

/// Shared test origin for the reader's network paths (#174, #220).
///
/// Minimal blocking HTTP server on 127.0.0.1 that serves Range requests, honours a finite
/// range end, keeps the connection alive across requests, and counts every body byte it
/// manages to write. When the client stops reading, `write()` parks on the full socket
/// buffer, so `bytesWritten` plateauing IS the observable for working flow control.
/// Minimal blocking HTTP origin on 127.0.0.1: serves `Range: bytes=X-` with a 206 and
/// an endless zero body, throttled to ~50 MB/s, counting bytes actually written. When
/// the client stops reading, write() parks on the full socket buffer, so `bytesWritten`
/// plateauing IS the observable for working flow control.
final class ThrottledOriginServer: @unchecked Sendable {
    /// Per-request response override for failure-path tests. The default keeps every
    /// existing test on the historical always-206 behaviour.
    enum Directive {
        case serve206
        case status(Int, retryAfter: Int? = nil)
        case redirect(to: String)
        case dropConnection
        /// #309: answer with the 206 header, deliver `afterBytes` of the promised body, then stop
        /// writing WITHOUT closing the socket and without a FIN. The client keeps an established
        /// connection that delivers nothing and never errors, which is the reader-observable state
        /// behind #309 (the field case was a transport that died with URLSession surfacing nothing).
        /// `afterBytes: 0` is the headers-but-no-body variant, i.e. a generation that never sees a
        /// first byte.
        case serveThenGoSilent(afterBytes: Int64)
        /// Sequential-origin drop shape: answer the 206 header promising the full remaining body,
        /// deliver `afterBytes`, then close the socket outright. The client sees a connection that
        /// ended SHORT of its Content-Length - the observable behind the sequential reader's
        /// EIO-not-EOF distinction (a lost source must not read as end-of-media).
        case serveThenDrop(afterBytes: Int64)
        /// Audit DMX-5: a 206 that starts `start` rather than where it was asked, the way an edge
        /// that aligns ranges to its own chunk boundary answers. The body is that range's.
        case serve206From(start: Int64)
        /// AE#958: a 206 whose headers state exactly the range asked for while the body is the bytes
        /// from `bodyFrom`, the way a timeshift origin answers on its own chunk boundary. Nothing in
        /// the response gives it away.
        case serve206Fabricated(bodyFrom: Int64)
        /// Audit DMX-101: a server that cannot address bytes. Whatever range was asked for, the
        /// answer is a 200 with the whole source from byte 0 and its full Content-Length.
        case serve200
    }

    let port: UInt16
    private let listener: LoopbackListener
    /// #551: a var only so a test can make the origin's stated total CHANGE between two requests,
    /// which is the one shape that proves the reader rechecks a warm's size against the connection
    /// that is actually serving it. Every other test leaves it at its init value.
    private var totalSize: Int64
    /// #551: answer a finite range with everything from its start to the end of the source, i.e.
    /// serve WIDER than asked. Non-conforming, and a real shape: an edge that rounds a range up to
    /// its own chunk boundary does this. Default off keeps every existing test on the historical
    /// behaviour.
    private let ignoreRangeEnd: Bool
    /// AE#619: serve `patternByte(at:)` instead of a constant, so a test can check that the bytes
    /// the reader returns are the bytes at the offset it claims. Default off keeps every existing
    /// test on the historical constant body.
    private let patternedBody: Bool

    /// The byte a `patternedBody` origin serves at `offset`. Varies within every 256-byte run and
    /// between runs, so a shifted or reordered read cannot match by accident.
    static func patternByte(at offset: Int64) -> UInt8 {
        UInt8(truncatingIfNeeded: offset ^ (offset >> 8) ^ (offset >> 16) ^ (offset >> 24))
    }
    private let chunkBytes: Int
    private let throttleUs: useconds_t
    private let firstByteDelayUs: @Sendable (_ isSuffix: Bool) -> useconds_t
    private let respond: @Sendable (_ requestIndex: Int, _ offset: Int64, _ path: String) -> Directive
    /// #388: how many requests this origin tolerates at once before it answers 509, the way a
    /// connection-capped panel does. nil keeps every existing test on the unmetered behaviour.
    private let refuseAboveConcurrency: Int?
    private let lock = NSLock()
    private var _bytesWritten: Int64 = 0
    private var _connFDs: [Int32] = []
    private var _stopped = false
    private var _requestedRanges: [(start: Int64, end: Int64?)] = []
    private var _requestLog: [(path: String, start: Int64, end: Int64?)] = []
    private var _rangeHeaderPresent: [Bool] = []
    /// #551 round 2: the headers each request arrived with, lowercased names. A credential that
    /// must not reach a target is only provably absent at the target.
    private var _requestHeaders: [[String: String]] = []
    private var _inflight = 0
    private var _peakInflight = 0
    private var _refusedForConcurrency = 0

    /// #388: the most requests this origin ever had open at the same time. The reader's own budget
    /// counts what it BELIEVES it issued against an origin; this counts what the origin saw, which
    /// is the only side of the redirect the declared ceiling is supposed to be about.
    var peakConcurrentRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return _peakInflight
    }

    /// Requests this origin refused because they arrived on top of `refuseAboveConcurrency`.
    var refusedForConcurrency: Int {
        lock.lock(); defer { lock.unlock() }
        return _refusedForConcurrency
    }

    /// #551 only: restate the source's size for every request from here on.
    func setTotalSize(_ size: Int64) {
        lock.lock(); totalSize = size; lock.unlock()
    }

    var bytesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _bytesWritten
    }

    /// #220: what each request actually asked for. `end` is nil for an open-ended
    /// `bytes=X-`, which is what live sources and unresolved sizes keep using.
    var requestedRanges: [(start: Int64, end: Int64?)] {
        lock.lock(); defer { lock.unlock() }
        return _requestedRanges
    }

    var rangeRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestedRanges.count
    }

    /// Every request with its path, so a redirect test can tell source-URL hits from
    /// pinned-URL hits.
    var requestLog: [(path: String, start: Int64, end: Int64?)] {
        lock.lock(); defer { lock.unlock() }
        return _requestLog
    }

    /// #551 round 2: every request's headers, in `requestLog` order, names lowercased.
    var requestHeaders: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return _requestHeaders
    }

    /// Whether each logged request carried a Range header at all. A range-less GET is logged in
    /// `requestLog` as (start 0, end nil), indistinguishable from `bytes=0-`; the sequential-origin
    /// reader's whole contract is that it never sends Range, so its tests assert on THIS.
    var rangeHeaderPresence: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _rangeHeaderPresent
    }

    private var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    /// #281 retest: how long this origin sits on a request before its response header, per request
    /// form. A loopback origin answers instantly, which is the one thing a real one never does, and
    /// that difference is what let the speculative tail fetch pass every test while never once
    /// winning its race in the field. `isSuffix` is true for the `bytes=-n` form.
    init?(totalSize: Int64, chunkBytes: Int = 256 * 1024, throttleUs: useconds_t = 5000,
          refuseAboveConcurrency: Int? = nil,
          ignoreRangeEnd: Bool = false,
          patternedBody: Bool = false,
          firstByteDelayUs: @escaping @Sendable (_ isSuffix: Bool) -> useconds_t = { _ in 0 },
          respond: @escaping @Sendable (_ requestIndex: Int, _ offset: Int64, _ path: String) -> Directive = { _, _, _ in .serve206 }) {
        self.totalSize = totalSize
        self.ignoreRangeEnd = ignoreRangeEnd
        self.patternedBody = patternedBody
        self.chunkBytes = chunkBytes
        self.throttleUs = throttleUs
        self.refuseAboveConcurrency = refuseAboveConcurrency
        self.firstByteDelayUs = firstByteDelayUs
        self.respond = respond

        // #450: a backlog of 4 is a ceiling of this harness's own, and the suite that reads
        // this origin's request log is measuring how many concurrent readers get on the link.
        // A harness that brings its own version of the cause cannot measure it.
        guard let listener = LoopbackListener(backlog: 32) else { return nil }
        self.listener = listener
        self.port = listener.port
        listener.start { [self] fd in admit(fd) }
    }

    func stop() {
        lock.lock()
        let alreadyStopped = _stopped
        _stopped = true
        // shutdown unblocks a recv or a write parked on this fd and fails every later one; it
        // does not free the descriptor number. The serving thread owns that number until it
        // exits and closes it under this lock (`closeConnection`), so no write of its own can
        // land on a number the kernel has handed to someone else in between. Closing here did
        // exactly that on 2026-09-03: a write in `writeFully` hit a recycled guarded fd and
        // EXC_GUARD took the whole test process with it, 20 tests into 2475.
        let fds = alreadyStopped ? [] : _connFDs
        for fd in fds { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        guard !alreadyStopped else { return }
        listener.stop()
    }

    /// The one place a connection fd is closed. Deregistering and closing under the lock is
    /// what keeps `stop()` from shutting down a number this thread has already given back.
    private func closeConnection(_ fd: Int32) {
        lock.lock()
        _connFDs.removeAll { $0 == fd }
        close(fd)
        lock.unlock()
    }

    private func admit(_ fd: Int32) -> Bool {
        lock.lock()
        if _stopped {
            lock.unlock()
            shutdown(fd, SHUT_RDWR)
            close(fd)
            return false
        }
        _connFDs.append(fd)
        lock.unlock()
        Thread.detachNewThread { [self] in serve(fd) }
        return true
    }

    /// One connection, many requests: a bounded-range reader issues the next range on the
    /// same socket, so serving exactly one and hanging up would force a new connection per
    /// range and make the pooling measurement meaningless.
    private func serve(_ fd: Int32) {
        defer { closeConnection(fd) }
        while !stopped {
            if !serveOneRequest(fd) { return }
        }
    }

    /// Returns false when the connection should close (client gone, or a malformed request).
    private func serveOneRequest(_ fd: Int32) -> Bool {
        guard let request = readRequestHeader(fd) else { return false }
        let path = request.components(separatedBy: "\r\n").first
            .flatMap { line -> String? in
                let parts = line.components(separatedBy: " ")
                return parts.count >= 2 ? parts[1] : nil
            } ?? "?"
        var offset: Int64 = 0
        var rangeEnd: Int64? = nil
        var isSuffix = false
        var hadRangeHeader = false
        if let rangeLine = request.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = rangeLine.range(of: "bytes="),
           let dash = rangeLine.range(of: "-", range: eq.upperBound..<rangeLine.endIndex) {
            hadRangeHeader = true
            let head = rangeLine[eq.upperBound..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = rangeLine[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if head.isEmpty, let suffixLength = Int64(tail) {
                // #281: the suffix form `bytes=-n`, the last n bytes, which is what the speculative
                // tail fetch uses because it needs no size. Logged in its resolved form so a test
                // asserts against real offsets.
                offset = max(0, totalSize - suffixLength)
                rangeEnd = totalSize - 1
                isSuffix = true
            } else {
                if let start = Int64(head) { offset = start }
                if !tail.isEmpty, let end = Int64(tail) { rangeEnd = min(end, totalSize - 1) }
            }
        }
        lock.lock()
        _requestedRanges.append((offset, rangeEnd))
        _requestLog.append((path, offset, rangeEnd))
        _rangeHeaderPresent.append(hadRangeHeader)
        _requestHeaders.append(Self.parseHeaders(request))
        let requestIndex = _requestLog.count - 1
        // #388: in flight from the moment this origin has a request to answer until its body is
        // written. A request parked in `readRequestHeader` on a kept-alive socket is not one.
        _inflight += 1
        _peakInflight = max(_peakInflight, _inflight)
        let concurrent = _inflight
        let cap = refuseAboveConcurrency
        if let cap, concurrent > cap { _refusedForConcurrency += 1 }
        lock.unlock()
        defer {
            lock.lock()
            _inflight = max(0, _inflight - 1)
            lock.unlock()
        }

        if let cap, concurrent > cap {
            // What a connection-capped panel answers to the request that arrives on top of the
            // one it is already serving (#307/#380: 509, not 429).
            let header = "HTTP/1.1 509 Bandwidth Limit Exceeded\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: keep-alive\r\n\r\n"
            return writeFully(fd, Array(header.utf8))
        }

        var silentAfter: Int64? = nil
        var dropAfter: Int64? = nil
        var answersWholeSource = false
        var bodyShift: Int64 = 0
        switch respond(requestIndex, offset, path) {
        case .serve206:
            break
        case .serve200:
            answersWholeSource = true
            offset = 0
        case .serve206From(let start):
            offset = max(0, min(start, totalSize - 1))
        case .serve206Fabricated(let bodyFrom):
            bodyShift = max(0, min(bodyFrom, totalSize - 1)) - offset
        case .serveThenGoSilent(let afterBytes):
            silentAfter = max(0, afterBytes)
        case .serveThenDrop(let afterBytes):
            dropAfter = max(0, afterBytes)
        case .status(let code, let retryAfter):
            let header = "HTTP/1.1 \(code) Status\r\n"
                + (retryAfter.map { "Retry-After: \($0)\r\n" } ?? "")
                + "Content-Length: 0\r\n"
                + "Connection: keep-alive\r\n\r\n"
            return writeFully(fd, Array(header.utf8))
        case .redirect(let location):
            let header = "HTTP/1.1 302 Found\r\n"
                + "Location: \(location)\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: keep-alive\r\n\r\n"
            return writeFully(fd, Array(header.utf8))
        case .dropConnection:
            // Returning false ends `serve`, which closes the fd exactly once.
            shutdown(fd, SHUT_RDWR)
            return false
        }

        var pendingDelay = firstByteDelayUs(isSuffix)
        while pendingDelay > 0 && !stopped {
            let slice = min(pendingDelay, 100_000)   // usleep is only defined below one second
            usleep(slice)
            pendingDelay -= slice
        }

        let last = answersWholeSource ? totalSize - 1 : (ignoreRangeEnd ? nil : rangeEnd) ?? (totalSize - 1)
        let remaining = last - offset + 1
        // Keep-alive, not close: a bounded range that tears the socket down would make every
        // refill a fresh connection and would hide exactly the pooling question under test.
        let header = answersWholeSource
            ? "HTTP/1.1 200 OK\r\n"
                + "Content-Length: \(remaining)\r\n"
                + "Connection: keep-alive\r\n\r\n"
            : "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \(offset)-\(last)/\(totalSize)\r\n"
                + "Content-Length: \(remaining)\r\n"
                + "Accept-Ranges: bytes\r\n"
                + "Connection: keep-alive\r\n\r\n"
        guard writeFully(fd, Array(header.utf8)) else { return false }

        let chunk = [UInt8](repeating: 0x55, count: chunkBytes)
        var served: Int64 = 0
        while served < remaining && !stopped {
            // #309: the silent-death point. Neither close() nor shutdown(): the peer must keep an
            // established connection with an unfinished body, so the reader sees no bytes, no EOF
            // and no error. `stop()` is what releases this thread and the socket.
            if let silentAfter, served >= silentAfter {
                while !stopped { usleep(200_000) }
                return false
            }
            // Sequential-drop point: the body ends short of the promised Content-Length, which is
            // what the client's transport has to surface as a lost connection.
            //
            // Half-close, not close(). A full close tears down the receive direction too, and
            // anything still in flight can then be answered with an RST, which discards whatever
            // the peer has not handed to its application yet. The bytes this origin says it served
            // would silently stop being the bytes the reader can see, and a test asserting on the
            // amount delivered would be measuring the machine's scheduling (the 2026-08-11 CI
            // failure: 327212 of 2 MiB arrived). FIN keeps the sent bytes deliverable, so this
            // thread parks on the half-closed socket until `stop()` and closes it only then.
            if let dropAfter, served >= dropAfter {
                shutdown(fd, SHUT_WR)
                while !stopped { usleep(200_000) }
                return false
            }
            var n = Int(min(Int64(chunkBytes), remaining - served))
            if let silentAfter { n = Int(min(Int64(n), silentAfter - served)) }
            if let dropAfter { n = Int(min(Int64(n), dropAfter - served)) }
            let body = patternedBody
                ? (0..<n).map { Self.patternByte(at: offset + bodyShift + served + Int64($0)) }
                : Array(chunk[0..<n])
            guard writeBody(fd, body) else { return false }
            served += Int64(n)
            if throttleUs > 0 { usleep(throttleUs) }
        }
        return true
    }

    private static func parseHeaders(_ request: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }
        return headers
    }

    private func readRequestHeader(_ fd: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var collected = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while collected.range(of: terminator) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            collected.append(contentsOf: buf[0..<n])
            if collected.count > 128 * 1024 { return nil }
        }
        return String(data: collected, encoding: .utf8)
    }

    private func writeFully(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, raw.count)
            }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    /// Like writeFully but counts every byte the kernel actually accepted, including a
    /// final partial write, so a park mid-chunk is still measured accurately.
    private func writeBody(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, raw.count)
            }
            guard n > 0 else { return false }
            lock.lock()
            _bytesWritten += Int64(n)
            lock.unlock()
            sent += n
        }
        return true
    }
}
