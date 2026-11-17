import Darwin
import Foundation

/// A loopback origin that holds every request whose path passes `holds` and answers none of them
/// until `release()`, which answers each held request with a 404 and closes it. Any other request,
/// and a held one that arrives after the release, gets its 404 at once. For a test that has to park
/// an engine inside one specific network await while something supersedes it: an engine fetches
/// several things from one origin in parallel (a sidecar beside a playlist), and only the await
/// under test may be the one that is parked.
final class HeldHTTPOrigin: @unchecked Sendable {
    let port: UInt16
    private let listener: LoopbackListener
    private let holds: (String) -> Bool
    private let lock = NSLock()
    private var held: [Int32] = []
    private var heldCount = 0
    private var heldPaths: [String] = []
    private var released = false
    private var stopped = false

    init?(holds: @escaping (String) -> Bool = { _ in true }) {
        guard let listener = LoopbackListener(backlog: 16) else { return nil }
        self.listener = listener
        self.holds = holds
        port = listener.port
        listener.start { [self] fd in admit(fd) }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    /// Requests parked so far (only those `holds` accepted).
    var connectionCount: Int { lock.withLock { heldCount } }

    /// Requests for exactly `path` parked so far.
    func heldRequests(for path: String) -> Int { lock.withLock { heldPaths.filter { $0 == path }.count } }

    func release() {
        let parked = lock.withLock { () -> [Int32] in
            released = true
            defer { held = [] }
            return held
        }
        for fd in parked { answer(fd) }
    }

    func stop() {
        let parked = lock.withLock { () -> [Int32] in
            stopped = true
            defer { held = [] }
            return held
        }
        for fd in parked { close(fd) }
        listener.stop()
    }

    private func admit(_ fd: Int32) -> Bool {
        if lock.withLock({ stopped }) { close(fd); return false }
        // The request line is read off the accept thread: the client may take a moment to send it.
        Thread.detachNewThread { [self] in
            let path = Self.requestPath(fd)
            let park = lock.withLock { () -> Bool? in
                if stopped { return nil }
                guard let path, holds(path), !released else { return false }
                heldCount += 1
                heldPaths.append(path)
                held.append(fd)
                return true
            }
            switch park {
            case nil: close(fd)
            case false?: answer(fd)
            case true?: break
            }
        }
        return true
    }

    private static func requestPath(_ fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var count = 0
        while count < buffer.count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + count, $0.count - count, 0) }
            guard n > 0 else { break }
            count += n
            if buffer[..<count].contains(0x0A) { break }
        }
        guard let line = String(decoding: buffer[..<count], as: UTF8.self).split(separator: "\r\n").first
        else { return nil }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    private func answer(_ fd: Int32) {
        let bytes = Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        close(fd)
    }
}
