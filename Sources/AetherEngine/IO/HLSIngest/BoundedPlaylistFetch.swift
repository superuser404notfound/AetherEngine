import Foundation

/// Reads a playlist body with its size cap enforced while it arrives (audit NET-10).
///
/// `session.data(for:)` buffers the whole body before a caller can look at its size, so a cap tested
/// afterwards bounded nothing: an origin answering with an endless body kept the fetch growing until
/// the resource timeout, or until jetsam. Here a declared length over the cap is refused before a
/// byte is read, and an undeclared one is cut off at the cap.
enum BoundedPlaylistFetch {

    /// The body and response of `request`. A non-2xx answer comes back with an empty body: every
    /// caller throws on the status alone, so its body is not worth reading.
    static func data(for request: URLRequest, session: URLSession, limit: Int) async throws
        -> (Data, URLResponse)
    {
        do {
            return try await BoundedFetch.data(for: request, session: session, limit: limit, role: .hlsPlaylist)
        } catch let error as BoundedFetch.Exceeded {
            throw HLSIngestError.playlistInvalid(reason: "playlist exceeds \(error.limit) bytes")
        }
    }
}

/// One bounded HTTP body fetch for everything that holds a whole body in memory: playlists, key
/// files, transport-stream segments, WebVTT segments (audit NET-112, FEA-107, DEC-103, SUB-106).
///
/// A delegate rather than `session.data(for:)`, which buffers the whole body before a caller sees its
/// size, and rather than iterating `AsyncBytes`, which delivered one byte per step into a per-byte
/// `Data.append`, about 16 ms per MB (audit NET-113). The response head is judged before any body is
/// read: a non-2xx answer or a declared length over `limit` ends the transfer there. The body then
/// arrives in the chunks the session delivers and the transfer is cancelled the moment it passes
/// `limit`, so the peak is the limit plus one delivery.
enum BoundedFetch {

    struct Exceeded: Error, Equatable {
        let limit: Int
    }

    /// An AES-128 key is 16 bytes; the callers keep their own `== 16` check.
    static let keyLimit = 64

    /// One WebVTT segment of a live subtitle rendition carries a few cues.
    static let webVTTSegmentLimit = 1024 * 1024

    /// What a transport-stream segment of `seconds` may weigh: 20 MB/s of its own duration, between
    /// 32 MiB and 256 MiB. UHD remux HLS runs 6 to 10 s segments at about 100 Mbps (75 to 125 MB), so
    /// a small fixed cap would refuse the content the path exists for.
    static func segmentLimit(forDuration seconds: Double) -> Int {
        let floor = 32.0 * 1024 * 1024
        let ceiling = 256.0 * 1024 * 1024
        guard seconds.isFinite, seconds > 0 else { return Int(floor) }
        return Int(min(ceiling, max(floor, seconds * 20_000_000)))
    }

    /// The body and response of `request`. A non-2xx answer comes back with an empty body, since every
    /// caller decides on the status alone. Throws `Exceeded` for a body over `limit`.
    static func data(for request: URLRequest, session: URLSession, limit: Int, role: SourceNetworkDiagnostics.Role = .boundedBody) async throws
        -> (Data, URLResponse)
    {
        let delegate = BoundedBodyDelegate(limit: limit, role: role, context: SourceNetworkDiagnostics.context(for: request))
        defer { withExtendedLifetime(delegate) {} }
        let task = session.dataTask(with: request)
        task.delegate = delegate
        let outcome: BoundedBodyDelegate.Outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Installed through the delegate's own lock, and it replays an outcome that has already
                // landed: `onCancel` runs on the spot for a task that is already cancelled, so the
                // transfer can end before this line.
                delegate.installOutcomeHandler { continuation.resume(returning: $0) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        switch outcome {
        case .body(let data, let response): return (data, response)
        case .refused(let response): return (Data(), response)
        case .exceeded: throw Exceeded(limit: limit)
        case .failed(let error): throw error
        }
    }
}

private final class BoundedBodyDelegate: EngineTLS.RedirectScrubbingDelegate, URLSessionDataDelegate,
    @unchecked Sendable
{
    enum Outcome {
        case body(Data, URLResponse)
        case refused(URLResponse)
        case exceeded
        case failed(Error)
    }

    private enum Verdict {
        case refused
        case exceeded
    }

    private let limit: Int
    private let trace: SourceNetworkDiagnostics.Trace
    private var buffer = Data()
    private var response: URLResponse?
    private var verdict: Verdict?

    /// Guards the handoff between the caller, which installs the handler, and the session's delegate
    /// queue, which produces the outcome. Either can be first.
    private let handoff = NSLock()
    private var onOutcome: ((Outcome) -> Void)?
    private var landed: Outcome?

    init(limit: Int, role: SourceNetworkDiagnostics.Role, context: SourceNetworkDiagnostics.Context?) {
        self.limit = limit
        trace = .init(role: role, context: context)
        super.init()
    }

    func installOutcomeHandler(_ handler: @escaping (Outcome) -> Void) {
        handoff.lock()
        if let landed {
            self.landed = nil
            handoff.unlock()
            handler(landed)
            return
        }
        onOutcome = handler
        handoff.unlock()
    }

    private func deliver(_ outcome: Outcome) {
        handoff.lock()
        guard let handler = onOutcome else {
            landed = outcome
            handoff.unlock()
            return
        }
        onOutcome = nil
        handoff.unlock()
        handler(outcome)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        EngineTLS.resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        trace.response(task: dataTask, response: response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            verdict = .refused
            completionHandler(.cancel)
            return
        }
        let declared = response.expectedContentLength
        guard declared <= Int64(limit) else {
            verdict = .exceeded
            completionHandler(.cancel)
            return
        }
        if declared > 0 { buffer.reserveCapacity(Int(min(declared, 8 * 1024 * 1024))) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard verdict == nil else { return }
        guard buffer.count + data.count <= limit else {
            verdict = .exceeded
            buffer = Data()
            dataTask.cancel()
            return
        }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Refusal/body limits deliberately cancel the task; do not report that as user cancellation.
        trace.completed(task: task, error: verdict == nil ? error : nil,
                        phase: verdict == .exceeded ? .bodyLimitExceeded : .completed)
        switch verdict {
        case .refused?:
            if let response { deliver(.refused(response)) } else { deliver(.failed(URLError(.badServerResponse))) }
        case .exceeded?:
            deliver(.exceeded)
        case nil:
            if let error {
                deliver(.failed(error))
            } else if let response {
                deliver(.body(buffer, response))
            } else {
                deliver(.failed(URLError(.badServerResponse)))
            }
        }
    }

    override func urlSession(_ session: URLSession, task: URLSessionTask,
                             willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                             completionHandler: @escaping (URLRequest?) -> Void) {
        trace.redirect(task: task, response: response, request: request)
        super.urlSession(session, task: task, willPerformHTTPRedirection: response,
                         newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        trace.metrics(task: task, metrics: metrics)
    }
}
