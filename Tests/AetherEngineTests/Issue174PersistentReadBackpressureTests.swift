import Testing
import Foundation
@testable import AetherEngine

/// #174: the persistent reader applied backpressure by BLOCKING the URLSession delegate
/// callback until the consumer drained below winHighWater. Blocking the delegate has no
/// flow-control contract: whether the connection stops reading from the socket is a
/// transport implementation detail. Plain HTTP/1.1 happens to park after a few MB of
/// internal buffering, but the field crash (HTTPS origin, boringssl in the crashing
/// stack, iPadOS) shows the TLS/H2 path keeps pulling at line rate and buffers the
/// undelivered body in unbounded internal allocations (cold pages compress, then
/// EXC_RESOURCE at the jetsam limit). Real, contractual flow control is task
/// suspend/resume ("a task, while suspended, produces no network traffic"), the same
/// mechanism the streaming path already uses (streamHighWater / streamLowWater).
///
/// These tests run a loopback HTTP/1.1 origin that counts every body byte it manages to
/// write. The load-bearing assertion is the suspend state itself (the transport-agnostic
/// mechanism); the origin byte bound is the regression guard that catches a backpressure
/// removal without a replacement.
@Suite("AVIOReader persistent backpressure (#174)")
struct Issue174PersistentReadBackpressureTests {

    // MARK: - Loopback throttled origin

    /// Minimal blocking HTTP origin on 127.0.0.1: serves `Range: bytes=X-` with a 206 and
    /// an endless zero body, throttled to ~50 MB/s, counting bytes actually written. When
    /// the client stops reading, write() parks on the full socket buffer, so `bytesWritten`
    /// plateauing IS the observable for working flow control.
    private final class ThrottledOriginServer: @unchecked Sendable {
        let port: UInt16
        private let listenFD: Int32
        private let totalSize: Int64
        private let chunkBytes: Int
        private let throttleUs: useconds_t
        private let lock = NSLock()
        private var _bytesWritten: Int64 = 0
        private var _connFDs: [Int32] = []
        private var _stopped = false

        var bytesWritten: Int64 {
            lock.lock(); defer { lock.unlock() }
            return _bytesWritten
        }

        private var stopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return _stopped
        }

        init?(totalSize: Int64, chunkBytes: Int = 256 * 1024, throttleUs: useconds_t = 5000) {
            self.totalSize = totalSize
            self.chunkBytes = chunkBytes
            self.throttleUs = throttleUs

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(fd, 4) == 0 else {
                close(fd)
                return nil
            }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            guard nameResult == 0 else {
                close(fd)
                return nil
            }
            self.listenFD = fd
            self.port = UInt16(bigEndian: bound.sin_port)

            Thread.detachNewThread { [self] in acceptLoop() }
        }

        func stop() {
            lock.lock()
            let fds = _connFDs
            _connFDs = []
            let alreadyStopped = _stopped
            _stopped = true
            lock.unlock()
            guard !alreadyStopped else { return }
            // shutdown unblocks a write parked on a full socket buffer; close alone may not.
            for fd in fds {
                shutdown(fd, SHUT_RDWR)
                close(fd)
            }
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }

        private func acceptLoop() {
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 { return }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                lock.lock()
                if _stopped {
                    lock.unlock()
                    shutdown(fd, SHUT_RDWR)
                    close(fd)
                    return
                }
                _connFDs.append(fd)
                lock.unlock()
                Thread.detachNewThread { [self] in serve(fd) }
            }
        }

        private func serve(_ fd: Int32) {
            guard let request = readRequestHeader(fd) else { return }
            var offset: Int64 = 0
            if let rangeLine = request.components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("range:") }),
               let eq = rangeLine.range(of: "bytes="),
               let dash = rangeLine.range(of: "-", range: eq.upperBound..<rangeLine.endIndex),
               let start = Int64(rangeLine[eq.upperBound..<dash.lowerBound]) {
                offset = start
            }
            let remaining = totalSize - offset
            let header = "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \(offset)-\(totalSize - 1)/\(totalSize)\r\n"
                + "Content-Length: \(remaining)\r\n"
                + "Accept-Ranges: bytes\r\n"
                + "Connection: close\r\n\r\n"
            guard writeFully(fd, Array(header.utf8)) else { return }

            let chunk = [UInt8](repeating: 0x55, count: chunkBytes)
            var served: Int64 = 0
            while served < remaining && !stopped {
                let n = Int(min(Int64(chunkBytes), remaining - served))
                guard writeBody(fd, Array(chunk[0..<n])) else { return }
                served += Int64(n)
                if throttleUs > 0 { usleep(throttleUs) }
            }
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

    // MARK: - Tests

    @Test("stalled consumer parks the origin connection instead of buffering at line rate")
    func stalledConsumerParksOrigin() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Nobody consumes: the demux side is deliberately parked, the exact #174 shape
        // (muxer backpressured on SegmentCache high water, no read ever advances position).
        try await Task.sleep(for: .seconds(3))

        // Origin line rate here is ~50 MB/s. Without real flow control the origin keeps
        // serving (~150 MB in 3 s) into URLSession's internal buffering. With task-suspend
        // backpressure it parks at winHighWater plus socket/transport buffer slack.
        #expect(server.bytesWritten < 64 * 1024 * 1024,
                "origin served \(server.bytesWritten / (1024 * 1024)) MB into a stalled consumer")
        #expect(reader.persistentTaskIsSuspendedForTesting,
                "the persistent task must be suspended once the window exceeds winHighWater")
    }

    @Test("resuming consumption after a stall delivers fresh bytes (resume liveness)")
    func drainAfterStallResumesDelivery() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 256 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Stall long enough for the suspend to engage, then consume far more than the
        // window: delivery must keep flowing, which proves the task was resumed.
        try await Task.sleep(for: .seconds(2))

        let sliceCap = 256 * 1024
        let target = 48 * 1024 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        let deadline = Date().addingTimeInterval(30)
        while got < target && Date() < deadline {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got >= target, "only \(got / (1024 * 1024)) MB delivered after the stall")
    }

    @Test("teardown while suspended releases the task and does not hang")
    func teardownWhileSuspended() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        try reader.open()

        try await Task.sleep(for: .seconds(2))

        // Completing without a hang is the assertion; the suspended flag must be cleared
        // so the balanced resume-before-cancel actually happened.
        reader.markClosed()
        reader.close()
        #expect(!reader.persistentTaskIsSuspendedForTesting)
    }
}
