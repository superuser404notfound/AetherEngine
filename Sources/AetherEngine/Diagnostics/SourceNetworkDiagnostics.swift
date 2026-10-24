import Foundation

/// Observes real source requests. Hosts must redact URLs before persistence;
/// no headers, response bodies or localized error messages are included.
public enum SourceNetworkDiagnostics {
    /// Host-owned opaque identifiers. They are never sent as HTTP headers.
    public struct Context: Sendable, Equatable {
        public let playbackID: UUID
        public let attemptID: UUID
        public init(playbackID: UUID, attemptID: UUID) {
            self.playbackID = playbackID
            self.attemptID = attemptID
        }
    }

    @TaskLocal public static var context: Context?
    private static let requestContextKey = "AetherEngine.SourceNetworkDiagnostics.context"

    static func request(_ request: URLRequest, context: Context?) -> URLRequest {
        let copy = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        if let context {
            URLProtocol.setProperty([context.playbackID.uuidString, context.attemptID.uuidString],
                                    forKey: requestContextKey, in: copy)
        } else {
            URLProtocol.removeProperty(forKey: requestContextKey, in: copy)
        }
        return copy as URLRequest
    }

    static func context(for request: URLRequest) -> Context? {
        guard let values = URLProtocol.property(forKey: requestContextKey, in: request) as? [String],
              values.count == 2, let playbackID = UUID(uuidString: values[0]),
              let attemptID = UUID(uuidString: values[1]) else { return nil }
        return Context(playbackID: playbackID, attemptID: attemptID)
    }

    /// Stable, extensible diagnostic role values; raw values are API.
    public struct Role: RawRepresentable, Sendable, Equatable, Hashable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let persistentRead = Role(rawValue: "PersistentRead")
        public static let chunkFetch = Role(rawValue: "ChunkFetch")
        public static let streaming = Role(rawValue: "Streaming")
        public static let probe = Role(rawValue: "Probe")
        public static let tailPrefetch = Role(rawValue: "TailPrefetch")
        public static let hlsPlaylist = Role(rawValue: "HLSPlaylist")
        public static let hlsSegment = Role(rawValue: "HLSSegment")
        public static let hlsKey = Role(rawValue: "HLSKey")
        public static let boundedBody = Role(rawValue: "BoundedBody")
    }

    /// Stable, extensible diagnostic phase values; raw values are API.
    public struct Phase: RawRepresentable, Sendable, Equatable, Hashable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let response = Phase(rawValue: "response")
        public static let redirect = Phase(rawValue: "redirect")
        public static let completed = Phase(rawValue: "completed")
        public static let metrics = Phase(rawValue: "metrics")
        public static let bodyLimitExceeded = Phase(rawValue: "body_limit_exceeded")
        public static let abandoned = Phase(rawValue: "abandoned")
    }

    /// Immutable snapshot of one request event.
    public struct Event: Sendable {
        public let requestID: UUID
        public let role: Role
        public let phase: Phase
        public let originalURL: URL?
        public let url: URL?
        public let status: Int?
        public let urlErrorCode: Int?
        public let bytes: Int64
        public let elapsedMilliseconds: Int
        public let dnsMilliseconds: Int?
        public let connectMilliseconds: Int?
        public let tlsMilliseconds: Int?
        public let responseMilliseconds: Int?
        public let reusedConnection: Bool?
        public let context: Context?

        init(requestID: UUID, role: Role, phase: Phase, originalURL: URL?, url: URL?,
             status: Int?, urlErrorCode: Int?, bytes: Int64, elapsedMilliseconds: Int,
             dnsMilliseconds: Int? = nil, connectMilliseconds: Int? = nil,
             tlsMilliseconds: Int? = nil, responseMilliseconds: Int? = nil,
             reusedConnection: Bool? = nil, context: Context? = nil) {
            self.requestID = requestID
            self.role = role
            self.phase = phase
            self.originalURL = originalURL
            self.url = url
            self.status = status
            self.urlErrorCode = urlErrorCode
            self.bytes = bytes
            self.elapsedMilliseconds = elapsedMilliseconds
            self.dnsMilliseconds = dnsMilliseconds
            self.connectMilliseconds = connectMilliseconds
            self.tlsMilliseconds = tlsMilliseconds
            self.responseMilliseconds = responseMilliseconds
            self.reusedConnection = reusedConnection
            self.context = context
        }
    }

    public static var handler: (@Sendable (Event) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return observer }
        set { lock.lock(); observer = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var observer: (@Sendable (Event) -> Void)?

    static func urlErrorCode(_ error: Error?) -> Int? {
        var next = error as NSError?
        for _ in 0..<8 {
            guard let current = next else { return nil }
            if current.domain == NSURLErrorDomain { return current.code }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    final class Trace: Sendable {
        private let id = UUID()
        private let role: Role
        private let start = ProcessInfo.processInfo.systemUptime
        private let context: Context?
        init(role: Role, context: Context? = SourceNetworkDiagnostics.context) {
            self.role = role
            self.context = context
        }

        func record(_ phase: Phase, originalURL: URL, url: URL, status: Int? = nil,
                    bytes: Int64 = 0, error: Error? = nil) {
            handler?(Event(requestID: id, role: role, phase: phase,
                           originalURL: originalURL, url: url, status: status,
                           urlErrorCode: urlErrorCode(error), bytes: bytes,
                           elapsedMilliseconds: Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000),
                           context: context))
        }

        private func event(_ phase: Phase, task: URLSessionTask, url: URL? = nil,
                           status: Int? = nil, error: Error? = nil,
                           transaction: URLSessionTaskTransactionMetrics? = nil) -> Event {
            func milliseconds(_ start: Date?, _ end: Date?) -> Int? {
                guard let start, let end else { return nil }
                return Int(max(0, end.timeIntervalSince(start)) * 1_000)
            }
            return Event(requestID: id, role: role, phase: phase,
                  originalURL: task.originalRequest?.url, url: url ?? task.currentRequest?.url,
                  status: status ?? (task.response as? HTTPURLResponse)?.statusCode,
                  urlErrorCode: urlErrorCode(error), bytes: task.countOfBytesReceived,
                  elapsedMilliseconds: Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000),
                  dnsMilliseconds: milliseconds(transaction?.domainLookupStartDate, transaction?.domainLookupEndDate),
                  connectMilliseconds: milliseconds(transaction?.connectStartDate, transaction?.connectEndDate),
                  tlsMilliseconds: milliseconds(transaction?.secureConnectionStartDate, transaction?.secureConnectionEndDate),
                  responseMilliseconds: milliseconds(transaction?.requestStartDate, transaction?.responseStartDate),
                  reusedConnection: transaction?.isReusedConnection,
                  context: context)
        }
        func response(task: URLSessionTask, response: URLResponse) {
            handler?(event(.response, task: task, url: response.url, status: (response as? HTTPURLResponse)?.statusCode))
        }
        func redirect(task: URLSessionTask, response: HTTPURLResponse, request: URLRequest) {
            handler?(event(.redirect, task: task, url: request.url, status: response.statusCode))
        }
        func completed(task: URLSessionTask, error: Error?, phase: Phase = .completed) {
            handler?(event(phase, task: task, error: error))
        }
        func metrics(task: URLSessionTask, metrics: URLSessionTaskMetrics) {
            guard let receive = handler else { return }
            for transaction in metrics.transactionMetrics {
                receive(event(.metrics, task: task, url: transaction.request.url,
                              status: (transaction.response as? HTTPURLResponse)?.statusCode,
                              transaction: transaction))
            }
        }
    }
}
