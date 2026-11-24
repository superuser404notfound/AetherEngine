import Darwin
import Foundation

/// A loopback origin that answers each path from a table and records the headers every request
/// arrived with (names lowercased), so a credential that must not reach a host is checked where it
/// would have landed. One request per connection; the table can be filled after start, so two of
/// these can point at each other.
final class CannedHTTPOrigin: @unchecked Sendable {
    enum Answer: Sendable {
        case body(String, contentType: String)
        case redirect(to: String)
        case status(Int)
        /// The inner answer, after the server has sat on the request this long.
        indirect case delayed(TimeInterval, Answer)
        /// The inner answer with one more response header.
        indirect case header(String, String, Answer)
    }

    struct Request: Sendable {
        let path: String
        let headers: [String: String]
    }

    let port: UInt16
    private let listener: LoopbackListener
    private let lock = NSLock()
    private var _routes: [String: Answer] = [:]
    private var _requests: [Request] = []
    private var _connections: Set<Int32> = []
    private var _stopped = false

    init?() {
        guard let listener = LoopbackListener(backlog: 16) else { return nil }
        self.listener = listener
        port = listener.port
        listener.start { [self] fd in admit(fd) }
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func route(_ path: String, _ answer: Answer) {
        lock.withLock { _routes[path] = answer }
    }

    var requests: [Request] { lock.withLock { _requests } }

    func requests(to path: String) -> [Request] { requests.filter { $0.path == path } }

    func stop() {
        lock.lock()
        let alreadyStopped = _stopped
        _stopped = true
        for fd in _connections { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        guard !alreadyStopped else { return }
        listener.stop()
    }

    private func admit(_ fd: Int32) -> Bool {
        lock.lock()
        if _stopped {
            lock.unlock()
            close(fd)
            return false
        }
        _connections.insert(fd)
        lock.unlock()
        Thread.detachNewThread { [self] in serve(fd) }
        return true
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            _connections.remove(fd)
            close(fd)
            lock.unlock()
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0, buffer.count < 65_536 else { return }
            buffer.append(chunk, count: n)
        }
        let lines = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let routed = lock.withLock { () -> Answer? in
            _requests.append(Request(path: path, headers: headers))
            return _routes[path]
        }
        var answer = routed
        if case .delayed(let seconds, let inner) = answer {
            Thread.sleep(forTimeInterval: seconds)
            answer = inner
        }
        var extraHeader = ""
        if case .header(let name, let value, let inner) = answer {
            extraHeader = "\(name): \(value)\r\n"
            answer = inner
        }
        var response: String
        switch answer {
        case .body(let body, let contentType):
            response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        case .redirect(let location):
            response = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        case .status(let code):
            response = "HTTP/1.1 \(code) Status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        case .delayed, .header:
            response = "HTTP/1.1 500 Nested Wrapper\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        case nil:
            response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        if !extraHeader.isEmpty, let statusEnd = response.range(of: "\r\n") {
            response.insert(contentsOf: extraHeader, at: statusEnd.upperBound)
        }
        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            sent += n
        }
    }
}
