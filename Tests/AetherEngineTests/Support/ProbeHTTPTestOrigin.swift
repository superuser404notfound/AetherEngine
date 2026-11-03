import Darwin
import Foundation

/// Per-test, loopback-only origin. Socket waits and response gates live on owned detached threads.
final class ProbeHTTPTestOrigin: @unchecked Sendable {
    enum Stage: CaseIterable, Equatable, Sendable { case headers, body }

    struct Request: Sendable {
        let method: String
        let range: String?
    }

    private struct State {
        var stopping = false
        var acceptExited = false
        var connections: Set<Int32> = []
        var requests: [Request] = []
        var failure: String?
        var stalled = false
    }

    let port: UInt16
    let blocked = ProbeTestGate()
    /// Every request that arrives after `holdLaterRequests()` waits here, before its response head,
    /// until the test opens the gate (or `stop()` does).
    let held = ProbeTestGate()
    private let holding = ProbeTestBox(false)
    private let listener: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let data: Data
    private let stage: Stage?
    private let stallOpenEndedBody: Bool
    private let onBlocked: @Sendable () -> Void
    private let response: (@Sendable (Request, Int) -> Data?)?
    private let state = ProbeTestBox(State())

    init(data: Data, stage: Stage? = nil, stallOpenEndedBody: Bool = false,
         onBlocked: @escaping @Sendable () -> Void = {},
         response: (@Sendable (Request, Int) -> Data?)? = nil) throws {
        self.data = data
        self.stage = stage
        self.stallOpenEndedBody = stallOpenEndedBody
        self.onBlocked = onBlocked
        self.response = response
        guard let (fd, boundPort) = LoopbackPort.listen(backlog: 16) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var wake: [Int32] = [-1, -1]
        var initialized = false
        defer {
            if !initialized {
                Darwin.close(fd)
                for pipeFD in wake where pipeFD >= 0 { Darwin.close(pipeFD) }
            }
        }
        guard pipe(&wake) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              fcntl(wake[1], F_SETFL, O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        listener = fd
        wakeRead = wake[0]
        wakeWrite = wake[1]
        port = boundPort
        initialized = true
        Thread.detachNewThread { self.acceptLoop() }
    }

    var requests: [Request] { state.value.requests }

    func holdLaterRequests() { holding.update { $0 = true } }
    var failure: String? { state.value.failure }
    var isStopped: Bool {
        let snapshot = state.value
        return snapshot.acceptExited && snapshot.connections.isEmpty
    }

    func stop() {
        state.update { state in
            guard !state.stopping else { return }
            state.stopping = true
            // The accept thread owns its listener and wake pipe until poll returns. Closing a
            // listener from another thread can race descriptor reuse or fail to wake accept.
            if !state.acceptExited {
                var byte: UInt8 = 1
                var sent: Int
                repeat { sent = Darwin.write(wakeWrite, &byte, 1) } while sent < 0 && errno == EINTR
                if sent != 1 { state.failure = "Could not wake the test origin: \(errno)" }
            }
            // Connection workers likewise retain descriptor ownership until their syscalls unwind.
            for fd in state.connections { shutdown(fd, SHUT_RDWR) }
        }
        blocked.open()
        held.open()
    }

    private func acceptLoop() {
        defer {
            state.update {
                Darwin.close(listener)
                Darwin.close(wakeRead)
                Darwin.close(wakeWrite)
                $0.acceptExited = true
            }
        }
        while !state.value.stopping {
            var events = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = events.withUnsafeMutableBufferPointer {
                poll($0.baseAddress, nfds_t($0.count), -1)
            }
            guard ready >= 0 else {
                if errno == EINTR { continue }
                state.update { $0.failure = "poll failed: \(errno)" }
                return
            }
            if events[1].revents != 0 || state.value.stopping { return }
            guard events[0].revents & Int16(POLLIN) != 0 else {
                state.update { $0.failure = "Unexpected test listener event" }
                return
            }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if !state.value.stopping {
                    state.update { $0.failure = "accept failed: \(errno)" }
                }
                return
            }
            var noSigPipe: Int32 = 1
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                state.update { $0.failure = "Connection setup failed: \(errno)" }
                Darwin.close(fd)
                return
            }
            var accepted = false
            state.update {
                if !$0.stopping {
                    $0.connections.insert(fd)
                    accepted = true
                }
            }
            guard accepted else { Darwin.close(fd); return }
            Thread.detachNewThread { self.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            state.update {
                Darwin.close(fd)
                $0.connections.remove(fd)
            }
        }
        guard let request = readRequest(fd) else { return }
        var index = 0
        state.update {
            index = $0.requests.count
            $0.requests.append(request)
        }
        if stage == .headers, index == 0 { park() }
        if holding.value { held.wait() }
        guard !state.value.stopping else { return }

        if let custom = response?(request, index) {
            _ = writeFully(fd, data: custom)
            return
        }

        var start = 0
        var end = data.count - 1
        if let range = request.range {
            let parts = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            guard range.hasPrefix("bytes="), parts.count == 2,
                  let first = Int(parts[0]), first >= 0, first < data.count,
                  parts[1].isEmpty || Int(parts[1]) != nil else {
                state.update { $0.failure = "Unexpected test request range: \(range)" }
                return
            }
            start = first
            if let last = Int(parts[1]) { end = min(end, last) }
        }
        guard end >= start else {
            state.update { $0.failure = "Inverted test request range" }
            return
        }
        let ranged = request.range != nil
        let header = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(end - start + 1)\r\n"
            + (ranged ? "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n" : "")
            + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        guard writeFully(fd, data: Data(header.utf8)) else { return }
        guard request.method != "HEAD" else { return }
        // The open-ended GET is the response-header-only size probe. Park the subsequent
        // finite chunk request only, after its headers but before its first payload byte.
        if stage == .body, request.range != nil,
           stallOpenEndedBody || request.range != "bytes=0-" { park() }
        guard !state.value.stopping else { return }
        _ = writeFully(fd, data: data.subdata(in: start..<(end + 1)))
    }

    private func park() {
        var shouldPark = false
        state.update {
            if !$0.stalled {
                $0.stalled = true
                shouldPark = true
            }
        }
        if shouldPark { blocked.wait(onArrival: onBlocked) }
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var header = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while header.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            header.append(contentsOf: buffer.prefix(count))
            guard header.count <= 64 * 1024 else {
                state.update { $0.failure = "Oversize test request header" }
                return nil
            }
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let method = lines[0].split(separator: " ").first.map(String.init)
        guard let method, method == "GET" || method == "HEAD" else {
            state.update { $0.failure = "Unexpected test request method" }
            return nil
        }
        let range = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        return Request(method: method, range: range)
    }

    private func writeFully(_ fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
