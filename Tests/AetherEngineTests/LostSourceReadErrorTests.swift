import Testing
import Foundation
@testable import AetherEngine

/// A source that is lost mid-read reports a read error, never end-of-file: the consumer treats EOF
/// as "played to the end" and never retries it (audit DMX-6, DMX-10).
@Suite("Lost source reads report EIO", .offCooperativePool)
struct LostSourceReadErrorTests {

    /// Answers every request with a length-less 200 and every GET with `bodyBytes` of a body that
    /// never completes. The reader can resolve no size and runs the forward-only streaming path.
    private final class LengthlessResettingOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener
        private let bodyBytes: Int
        private let lock = NSCondition()
        private var stopped = false
        private var bodyCutRequested = false
        private var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        init?(bodyBytes: Int) {
            self.bodyBytes = bodyBytes
            guard let listener = LoopbackListener(backlog: 16) else { return nil }
            self.listener = listener
            port = listener.port
            listener.start { [self] fd in
                Thread.detachNewThread { [self] in serve(fd) }
                return true
            }
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.broadcast()
            lock.unlock()
            listener.stop()
        }

        func cutBody() {
            lock.lock()
            bodyCutRequested = true
            lock.broadcast()
            lock.unlock()
        }

        private func serve(_ fd: Int32) {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            var request = Data()
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { Darwin.close(fd); return }
                request.append(contentsOf: buf[0..<n])
            }
            let isHead = request.starts(with: Data("HEAD".utf8))
            // Chunked with no Content-Length, so no probe can size the source. The body promises
            // one chunk of twice `bodyBytes` and stops half way with a FIN: a truncated chunked
            // body is a transport error, where a length-less FIN would be a clean end.
            let header = Array(("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n"
                + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                + (isHead ? "" : String(2 * bodyBytes, radix: 16) + "\r\n")).utf8)
            _ = header.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if !isHead {
                let chunk = [UInt8](repeating: 0x47, count: 16 * 1024)
                var sent = 0
                while sent < bodyBytes {
                    let n = chunk.withUnsafeBytes { send(fd, $0.baseAddress, min($0.count, bodyBytes - sent), 0) }
                    guard n > 0 else { break }
                    sent += n
                }
            }
            if !isHead {
                // Prove a mid-read loss: CFNetwork may otherwise reject the truncated body
                // before delivering any data, correctly turning this into an open failure.
                lock.lock()
                while !bodyCutRequested && !stopped { lock.wait() }
                lock.unlock()
            }
            // Half-close, as `ThrottledOriginServer.serveThenDrop` does: a full close can turn into
            // an RST that discards bytes the reader has not been handed yet.
            shutdown(fd, SHUT_WR)
            while !isStopped { usleep(50_000) }
            Darwin.close(fd)
        }
    }

    private func drain(_ reader: AVIOReader) -> Int32 {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        while true {
            let n = reader.read(into: buf, size: 64 * 1024)
            if n <= 0 { return n }
        }
    }

    @Test("a length-less stream cut off mid-body reports EIO, not EOF",
          .timeLimit(.minutes(3)), arguments: [false, true])
    func cutOffLengthlessStreamIsAnError(sequentialOnly: Bool) async throws {
        let origin = try #require(LengthlessResettingOrigin(bodyBytes: 256 * 1024))
        defer { origin.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/live.ts")!,
                                prefetchEnabled: false, sequentialOnly: sequentialOnly)
        let outcome = try await withTaskCancellationHandler {
            try await ProbeTestJob {
                defer { reader.markClosed(); reader.close() }
                try reader.open()
                var firstByte: UInt8 = 0
                let firstRead = withUnsafeMutablePointer(to: &firstByte) { reader.read(into: $0, size: 1) }
                guard firstRead == 1 else { return (firstRead, firstRead) }
                origin.cutBody()
                return (firstRead, drain(reader))
            }.outcome()
        } onCancel: {
            reader.markClosed()
            origin.stop()
        }
        let (firstRead, last) = try outcome.get()
        try #require(firstRead == 1)
        #expect(last == FFmpegErr.eio)
    }

    @Test("a seekable read whose fetch fails reports EIO, not EOF", .timeLimit(.minutes(3)))
    func failedSeekableFetchIsAnError() throws {
        let target: Int64 = 8 * 1024 * 1024
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            offset == target ? .status(500) : .serve206
        }
        let origin = ThrottledOriginServer(totalSize: 32 * 1024 * 1024, throttleUs: 0, respond: respond)
        let server = try #require(origin)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                chunkSize: 256 * 1024, prefetchEnabled: false)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(reader.seek(offset: target, whence: SEEK_SET) == target)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: 4096) == FFmpegErr.eio)
    }
}
