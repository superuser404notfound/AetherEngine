import Darwin
import Foundation

/// A loopback origin that accepts every connection and answers none of them until `release()`,
/// which answers each held request with a 404 and closes it. A request that arrives after the
/// release gets its 404 at once. For a test that has to park an engine inside a network await
/// while something supersedes it.
final class HeldHTTPOrigin: @unchecked Sendable {
    let port: UInt16
    private let listener: LoopbackListener
    private let lock = NSLock()
    private var held: [Int32] = []
    private var accepted = 0
    private var released = false
    private var stopped = false

    init?() {
        guard let listener = LoopbackListener(backlog: 16) else { return nil }
        self.listener = listener
        port = listener.port
        listener.start { [self] fd in admit(fd) }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    var connectionCount: Int { lock.withLock { accepted } }

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
        let action = lock.withLock { () -> Int in
            if stopped { return 0 }
            accepted += 1
            if released { return 1 }
            held.append(fd)
            return 2
        }
        switch action {
        case 0: close(fd); return false
        case 1: Thread.detachNewThread { [self] in answer(fd) }
        default: break
        }
        return true
    }

    private func answer(_ fd: Int32) {
        let bytes = Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        close(fd)
    }
}
