import Foundation

/// Sequential delivery for `HTTPDiscIOReader` once a read pattern has proven itself sequential
/// (#1007). The adaptive refill hands nothing to the demuxer until a whole range has arrived, so
/// every request boundary costs the demuxer that request's latency plus its whole transfer time: on
/// a remote UHD Blu-ray ISO eight serial 8 MiB ranges ran at 61 Mb/s where one 64 MiB range ran at
/// 106 Mb/s, and the consumer starved.
///
/// Here the network fills a FIFO and `read` takes bytes the moment they arrive. Each request spans
/// up to `rangeSize`, and the next one starts as soon as the previous body is complete, without
/// waiting for the consumer. `watermark` bounds what is buffered: above it the task is suspended,
/// and it resumes once the consumer has drained half of it, so memory stays at the old 8 MiB window
/// (plus what URLSession had already queued when the suspend landed).
///
/// Every response is judged at its head the way `rangeGet` judges one: only a 206 that starts at the
/// frontier is taken, and a body that runs past the asked range is cut. A short body or a transport
/// error resumes with a fresh request at the next byte that has not arrived; `maxRetries` failures
/// in a row without a byte in between end the stream, and `read` then returns -1.
final class ProgressiveRangeStream: @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    private let session: URLSession
    private let timeout: TimeInterval
    private let rangeSize: Int
    private let watermark: Int
    private let maxRetries: Int
    private let onReceived: (Int) -> Void
    /// Exclusive end: the source size, or the start of the next warmed span.
    let end: Int64

    private let cond = NSCondition()
    private var chunks: [Data] = []
    private var headOffset = 0
    private var buffered = 0
    /// Next byte `read` hands out.
    private var readOffset: Int64
    /// Next byte the network delivers.
    private var frontier: Int64
    private var requestEnd: Int64 = 0
    private var task: URLSessionDataTask?
    private var generation = 0
    private var suspended = false
    private var failures = 0
    private var failed = false
    private var closed = false

    // One summary line at close, so a field log tells a slow link from a stalled consumer (#1007).
    private let startOffset: Int64
    private let openedAt = ProcessInfo.processInfo.systemUptime
    private var ranges = 0
    private var requestStartedAt: TimeInterval = 0
    private var awaitingFirstByte = false
    private var firstByteMax: TimeInterval = 0
    private var suspends = 0
    private var suspendedAt: TimeInterval = 0
    private var heldTime: TimeInterval = 0
    private var readWaits = 0
    private var readWaitTime: TimeInterval = 0

    init(url: URL, extraHeaders: [String: String], session: URLSession, timeout: TimeInterval,
         start: Int64, end: Int64, rangeSize: Int, watermark: Int, maxRetries: Int,
         onReceived: @escaping (Int) -> Void) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.session = session
        self.timeout = timeout
        self.rangeSize = max(64 * 1024, rangeSize)
        self.watermark = max(64 * 1024, watermark)
        self.maxRetries = max(0, maxRetries)
        self.onReceived = onReceived
        self.end = end
        self.readOffset = start
        self.frontier = start
        self.startOffset = start
        cond.lock()
        startRequestLocked()
        cond.unlock()
    }

    /// The offset the next `read` continues at.
    var position: Int64 {
        cond.lock(); defer { cond.unlock() }
        return readOffset
    }

    /// Moves the read position forward inside what has already arrived. False when `target` is
    /// not there, and the caller tears the stream down.
    func skip(to target: Int64) -> Bool {
        cond.lock(); defer { cond.unlock() }
        guard target >= readOffset, target < readOffset + Int64(buffered) else { return target == readOffset }
        consumeLocked(Int(target - readOffset), into: nil)
        return true
    }

    /// Blocks until at least one byte is buffered, then copies up to `size`. 0 at `end`, -1 once the
    /// stream failed or was closed.
    func read(into out: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        cond.lock(); defer { cond.unlock() }
        let waitStart: TimeInterval? = buffered == 0 && !closed && !failed && readOffset < end
            ? ProcessInfo.processInfo.systemUptime : nil
        defer {
            if let waitStart {
                readWaits += 1
                readWaitTime += ProcessInfo.processInfo.systemUptime - waitStart
            }
        }
        while buffered == 0 {
            if closed || failed { return -1 }
            if readOffset >= end { return 0 }
            // A healthy request makes progress within its own idle timeout, and a failed one ends
            // in `didComplete`; this only catches a task that never completes at all.
            if !cond.wait(until: Date().addingTimeInterval(timeout + 5)), buffered == 0,
               !closed, !failed {
                failLocked()
            }
        }
        let n = min(size, buffered)
        consumeLocked(n, into: out)
        return n
    }

    func close() {
        cond.lock()
        let summary = closed ? nil : summaryLocked()
        closed = true
        let t = task
        task = nil
        generation += 1
        chunks = []; buffered = 0; headOffset = 0
        cond.broadcast()
        cond.unlock()
        t?.cancel()
        if let summary { EngineLog.emit(summary, category: .demux) }
    }

    private func summaryLocked() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        let held = heldTime + (suspended ? now - suspendedAt : 0)
        let life = now - openedAt
        let bytes = frontier - startOffset
        let active = max(life - held, 0.001)
        func s(_ t: TimeInterval) -> String { String(format: "%.2fs", t) }
        return "[HTTPDiscIOReader] \(url.lastPathComponent): stream at \(startOffset) closed after \(s(life)): "
            + "\(bytes / 1_048_576) MiB, \(String(format: "%.1f", Double(bytes) * 8 / active / 1_000_000)) Mb/s "
            + "while not held, \(ranges) range(s), first byte max \(Int(firstByteMax * 1000)) ms, "
            + "\(suspends) hold(s) for \(s(held)), \(readWaits) read wait(s) for \(s(readWaitTime)) (#1007)"
    }

    // MARK: - Buffer

    private func consumeLocked(_ count: Int, into out: UnsafeMutablePointer<UInt8>?) {
        var left = count
        var written = 0
        while left > 0, let chunk = chunks.first {
            let take = min(left, chunk.count - headOffset)
            if let out {
                let from = chunk.startIndex + headOffset
                chunk.copyBytes(to: out.advanced(by: written), from: from..<(from + take))
            }
            written += take
            left -= take
            headOffset += take
            if headOffset == chunk.count {
                chunks.removeFirst()
                headOffset = 0
            }
        }
        buffered -= count
        readOffset += Int64(count)
        if suspended, buffered <= watermark / 2, let t = task {
            suspended = false
            heldTime += ProcessInfo.processInfo.systemUptime - suspendedAt
            t.resume()
        }
    }

    // MARK: - Network

    private func startRequestLocked() {
        guard !closed, !failed, frontier < end else { return }
        generation += 1
        requestEnd = min(frontier + Int64(rangeSize), end)
        var req = URLRequest(engineURL: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue(HTTPDiscIOReader.rangeHeader(offset: frontier, length: Int(requestEnd - frontier)),
                     forHTTPHeaderField: "Range")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let delegate = ProgressiveRangeDelegate(stream: self, generation: generation,
                                                start: frontier, end: requestEnd)
        let t = session.dataTask(with: req)
        t.delegate = delegate
        task = t
        endHoldLocked()
        ranges += 1
        requestStartedAt = ProcessInfo.processInfo.systemUptime
        awaitingFirstByte = true
        t.resume()
    }

    private func endHoldLocked() {
        if suspended { heldTime += ProcessInfo.processInfo.systemUptime - suspendedAt }
        suspended = false
    }

    private func failLocked() {
        failed = true
        let t = task
        task = nil
        generation += 1
        cond.broadcast()
        t?.cancel()
    }

    fileprivate func received(_ data: Data, generation g: Int, task t: URLSessionDataTask) {
        cond.lock(); defer { cond.unlock() }
        guard g == generation, !closed else { return }
        let room = Int(requestEnd - frontier)
        let take = min(room, data.count)
        if awaitingFirstByte {
            awaitingFirstByte = false
            firstByteMax = max(firstByteMax, ProcessInfo.processInfo.systemUptime - requestStartedAt)
        }
        if take > 0 {
            chunks.append(take < data.count ? data.prefix(take) : data)
            buffered += take
            frontier += Int64(take)
            failures = 0
            cond.broadcast()
        }
        onReceived(data.count)
        if data.count > room || frontier >= requestEnd {
            // Past the ask (or exactly on it with an over-wide answer): keep what was asked for and
            // let the next request continue. A body that ends on the range end completes by itself.
            if data.count > room { t.cancel() }
            return
        }
        if buffered >= watermark, !suspended {
            suspended = true
            suspends += 1
            suspendedAt = ProcessInfo.processInfo.systemUptime
            t.suspend()
        }
    }

    fileprivate func completed(generation g: Int, refused: String?) {
        cond.lock(); defer { cond.unlock() }
        guard g == generation, !closed, !failed else { return }
        task = nil
        endHoldLocked()
        if frontier >= requestEnd {
            startRequestLocked()
            return
        }
        failures += 1
        if let refused {
            EngineLog.emit("[HTTPDiscIOReader] \(url.lastPathComponent): streamed range at \(frontier) "
                           + "refused (\(refused)) (#1007)", category: .demux)
        }
        if failures > maxRetries {
            EngineLog.emit("[HTTPDiscIOReader] \(url.lastPathComponent): streamed range at \(frontier) "
                           + "failed \(failures) time(s), giving up (#1007)", category: .demux)
            failLocked()
            return
        }
        let delay = min(0.25 * Double(failures), 1.0)
        let retryGeneration = generation
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.cond.lock(); defer { self.cond.unlock() }
            guard retryGeneration == self.generation, self.task == nil else { return }
            self.startRequestLocked()
        }
    }
}

/// One streamed request's delivery, tagged with the generation it was started under so a callback
/// that arrives after a cancel or a restart is dropped.
private final class ProgressiveRangeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private weak var stream: ProgressiveRangeStream?
    private let generation: Int
    private let start: Int64
    private let end: Int64
    private var refused: String?

    init(stream: ProgressiveRangeStream, generation: Int, start: Int64, end: Int64) {
        self.stream = stream
        self.generation = generation
        self.start = start
        self.end = end
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
            refused = "not HTTP"
            completionHandler(.cancel)
            return
        }
        switch AVIOReader.rangeAnswer(http, requestedStart: start, requestedEnd: end - 1) {
        case .honoured, .overWide:
            completionHandler(.allow)
        case .misplaced(let served):
            refused = "206 starts at \(served)"
            completionHandler(.cancel)
        case .ignored, .wholeFile:
            refused = "status \(http.statusCode) without the range"
            completionHandler(.cancel)
        case .unjudged:
            refused = "status \(http.statusCode)"
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stream?.received(data, generation: generation, task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stream?.completed(generation: generation, refused: refused)
    }
}
