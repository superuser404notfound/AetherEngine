// HLSFixture: a local HTTP server that slices an input MPEG-TS file into
// fixed-size chunks and serves them as a sliding-window live HLS playlist.
//
// Contract
// --------
// Entry point: `runHLSFixture(args:)` is called from main.swift's dispatch.
//
// CLI:
//   aetherctl hlsfixture <input.ts> [--port 8090] [--segment-seconds 4]
//                        [--master] [--discontinuity-at N] [--slow-refresh]
//                        [--drop-segment N] [--encrypted] [--fmp4] [--self-test]
//
// Slicing
// -------
// The file is divided into fixed-size chunks of approximately 1 MB, each
// rounded DOWN to a multiple of 188 (the MPEG-TS packet size). If the
// resulting chunk would be zero bytes (pathologically small file), we fall
// back to the whole file as a single chunk. Segments cycle (wrap) so the
// fixture can serve a sliding live window forever without EOF.
//
// Playlist
// --------
// /media.m3u8   - sliding window of 6 segments; EXT-X-MEDIA-SEQUENCE
//                 advances on a real-time timer of --segment-seconds per step.
// /segN.ts      - the N-th chunk (N modulo chunk count).
// /master.m3u8  - (--master) two variants: low (404) and high -> media.m3u8.
//
// Fault knobs
// -----------
// --discontinuity-at N  Insert #EXT-X-DISCONTINUITY before segment N in the
//                        playlist whenever N falls in the current window.
// --slow-refresh         Hold every /media.m3u8 response for 8 seconds before
//                        replying (stall exercise).
// --drop-segment N       Serve HTTP 404 for /segN.ts.
// --encrypted            Add EXT-X-KEY:METHOD=AES-128,URI="key.bin" to the
//                        media playlist.
// --fmp4                 Add EXT-X-MAP:URI="init.mp4" to the media playlist.
//
// Self-test
// ---------
// --self-test: starts the server on a background thread, constructs an
// HLSLiveIngestReader against the entry URL, reads in 65536-byte buffers
// until 5 MB total or a non-positive return. On >= 5 MB with first byte 0x47
// prints "OK <bytes> bytes (TS sync ok)" and exits 0. On -1 prints the
// reader's terminalError and exits 1. On 0 prints "FAIL eof" and exits 1.
//
// Socket scaffolding mirrors LiveFixture: Darwin BSD sockets, not
// Network.framework. Thread-per-connection, blocking I/O.

import Darwin
import Foundation
import AetherEngine

// MARK: - Constants

private let tsPacketSize = 188
private let windowSize = 6
private let slowRefreshDelay: Double = 8.0

// MARK: - Entry point

func runHLSFixture(args: [String]) -> Int32 {
    var rest = args

    // Required positional: the input .ts file.
    guard !rest.isEmpty, !rest[0].hasPrefix("-") else {
        print("ERROR: hlsfixture requires <input.ts> as first argument")
        print("Usage: aetherctl hlsfixture <input.ts> [--port N] [--segment-seconds N]")
        print("       [--master] [--discontinuity-at N] [--slow-refresh]")
        print("       [--drop-segment N] [--encrypted] [--fmp4] [--self-test]")
        return 64
    }
    let inputPath = rest.removeFirst()

    // Flags.
    let port          = takeIntArg("--port",             from: &rest) ?? 8090
    let segSeconds    = takeIntArg("--segment-seconds",  from: &rest) ?? 4
    let discAt        = takeIntArg("--discontinuity-at", from: &rest)
    let dropSeg       = takeIntArg("--drop-segment",     from: &rest)
    let withMaster    = takeFlag("--master",       from: &rest)
    let slowRefresh   = takeFlag("--slow-refresh", from: &rest)
    let encrypted     = takeFlag("--encrypted",    from: &rest)
    let fmp4          = takeFlag("--fmp4",         from: &rest)
    let selfTest      = takeFlag("--self-test",    from: &rest)

    if !rest.isEmpty {
        print("WARNING: unknown arguments: \(rest.joined(separator: " "))")
    }

    // Load + slice the input file.
    let slices: [[UInt8]]
    do {
        slices = try loadAndSlice(path: inputPath)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        return 1
    }
    print("[HLSFixture] slices=\(slices.count) segmentSeconds=\(segSeconds)")

    // Build + start the server.
    let config = HLSFixtureConfig(
        slices: slices,
        segmentSeconds: segSeconds,
        withMaster: withMaster,
        discontinuityAt: discAt,
        slowRefresh: slowRefresh,
        dropSegment: dropSeg,
        encrypted: encrypted,
        fmp4: fmp4
    )
    let server = HLSFixtureServer(config: config)
    let listenPort: UInt16
    do {
        listenPort = try server.start(preferredPort: UInt16(port))
    } catch {
        print("ERROR: server start failed: \(error.localizedDescription)")
        return 1
    }

    let entryPath = withMaster ? "master.m3u8" : "media.m3u8"
    let entryURL  = "http://127.0.0.1:\(listenPort)/\(entryPath)"
    print(entryURL)

    if selfTest {
        return runSelfTest(entryURL: entryURL, server: server)
    }

    // Default: park until killed.
    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler {
        server.stop()
        exit(0)
    }
    sig.resume()
    RunLoop.main.run()
    return 0 // unreachable
}

// MARK: - Self-test

private func runSelfTest(entryURL: String, server: HLSFixtureServer) -> Int32 {
    guard let url = URL(string: entryURL) else {
        print("FAIL internal: could not build URL from \(entryURL)")
        server.stop()
        return 1
    }

    let reader = HLSLiveIngestReader(playlistURL: url)
    let target  = 5 * 1024 * 1024  // 5 MB
    let bufSize = 65536
    let buf     = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buf.deallocate() }

    var total = 0
    var firstByte: UInt8? = nil

    while total < target {
        let n = reader.read(buf, size: Int32(bufSize))
        if n < 0 {
            // Terminal error.
            reader.close()
            server.stop()
            let desc = reader.terminalError.map { "\($0)" } ?? "unknown"
            print("FAIL \(desc)")
            return 1
        }
        if n == 0 {
            reader.close()
            server.stop()
            print("FAIL eof")
            return 1
        }
        if firstByte == nil { firstByte = buf[0] }
        total += Int(n)
    }

    reader.close()
    server.stop()

    let syncOK = firstByte == 0x47
    if syncOK {
        print("OK \(total) bytes (TS sync ok)")
        return 0
    } else {
        print("FAIL first byte 0x\(String(firstByte ?? 0, radix: 16)) not 0x47 (TS sync failed)")
        return 1
    }
}

// MARK: - File slicing

/// Load `path` and split into 188-aligned chunks.
///
/// Strategy: fixed 1 MB target chunk size, rounded DOWN to the nearest
/// 188-byte multiple. If the file is smaller than one 188-byte packet we
/// throw; if the computed chunk size is < 188 we clamp to 188. The last
/// chunk is whatever bytes remain (also 188-aligned because the whole file
/// must be a multiple of 188). Segments cycle so the server never runs out.
private func loadAndSlice(path: String) throws -> [[UInt8]] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else {
        throw NSError(domain: "HLSFixture", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "file not found: \(path)"])
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    guard raw.count >= tsPacketSize else {
        throw NSError(domain: "HLSFixture", code: 2,
                      userInfo: [NSLocalizedDescriptionKey:
                          "file too small (\(raw.count) bytes); need at least 188"])
    }
    guard raw.count % tsPacketSize == 0 else {
        throw NSError(domain: "HLSFixture", code: 3,
                      userInfo: [NSLocalizedDescriptionKey:
                          "file size \(raw.count) is not a multiple of 188; not a raw MPEG-TS"])
    }

    // Target ~1 MB per chunk, aligned to 188.
    let targetBytes = 1 * 1024 * 1024
    let rawChunk = targetBytes - (targetBytes % tsPacketSize)
    let chunkSize = max(tsPacketSize, rawChunk <= raw.count ? rawChunk : raw.count)

    var slices: [[UInt8]] = []
    var offset = 0
    while offset < raw.count {
        let end = min(offset + chunkSize, raw.count)
        // Clamp the end down to a 188-byte boundary from `offset`.
        let len = end - offset
        let aligned = (len / tsPacketSize) * tsPacketSize
        if aligned <= 0 { break }
        let slice = [UInt8](raw[offset..<(offset + aligned)])
        slices.append(slice)
        offset += aligned
    }
    guard !slices.isEmpty else {
        throw NSError(domain: "HLSFixture", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "slicing produced zero chunks"])
    }
    return slices
}

// MARK: - Server config

struct HLSFixtureConfig {
    let slices: [[UInt8]]
    let segmentSeconds: Int
    let withMaster: Bool
    let discontinuityAt: Int?
    let slowRefresh: Bool
    let dropSegment: Int?
    let encrypted: Bool
    let fmp4: Bool
}

// MARK: - HTTP server

/// A minimal blocking HTTP server for the HLS live fixture.
/// One thread per accepted connection. The playlist is generated fresh on
/// each /media.m3u8 request using wall-clock time to advance the sequence number.
final class HLSFixtureServer: @unchecked Sendable {
    private let config: HLSFixtureConfig
    private var listenFd: Int32 = -1
    private var shouldStop = false
    private let lock = NSLock()
    private var clientFds = Set<Int32>()
    private(set) var port: UInt16 = 0

    /// Monotonic start time (for computing which segment is "current").
    private var startTime: Date = Date()

    private let acceptQueue = DispatchQueue(
        label: "com.aetherengine.hlsfixture.accept", qos: .userInitiated)
    private let workQueue = DispatchQueue(
        label: "com.aetherengine.hlsfixture.work", qos: .userInitiated,
        attributes: .concurrent)

    init(config: HLSFixtureConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start(preferredPort: UInt16) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw FixtureError.socketCreate(errno: errno) }

        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on,
                       socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = preferredPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRC != 0 {
            // Preferred port busy: let kernel pick one.
            addr.sin_port = 0
            let rc2 = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard rc2 == 0 else {
                let e = errno; Darwin.close(fd)
                throw FixtureError.bind(errno: e)
            }
        }

        guard listen(fd, 16) == 0 else {
            let e = errno; Darwin.close(fd); throw FixtureError.listen(errno: e)
        }

        var actual = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &actual, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &actualLen)
            }
        }) == 0 else {
            let e = errno; Darwin.close(fd); throw FixtureError.getsockname(errno: e)
        }
        let assignedPort = UInt16(bigEndian: actual.sin_port)

        lock.lock()
        listenFd = fd
        port = assignedPort
        shouldStop = false
        startTime = Date()
        lock.unlock()

        acceptQueue.async { [weak self] in self?.acceptLoop() }
        return assignedPort
    }

    func stop() {
        lock.lock()
        shouldStop = true
        let fd = listenFd
        listenFd = -1
        port = 0
        let clients = clientFds
        clientFds.removeAll()
        lock.unlock()

        if fd >= 0 { Darwin.close(fd) }
        for c in clients { Darwin.close(c) }
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            lock.lock()
            let stopping = shouldStop
            let fd = listenFd
            lock.unlock()
            if stopping || fd < 0 { return }

            var caddr = sockaddr_in()
            var clen  = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &caddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &clen)
                }
            }
            if cfd < 0 {
                let e = errno
                if e == EBADF || e == EINVAL { return }
                if e == EINTR || e == EAGAIN { continue }
                return
            }

            var on: Int32 = 1
            _ = setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                           socklen_t(MemoryLayout<Int32>.size))

            lock.lock()
            clientFds.insert(cfd)
            lock.unlock()

            workQueue.async { [weak self] in self?.serve(cfd) }
        }
    }

    // MARK: - Per-connection handler

    private func serve(_ fd: Int32) {
        defer {
            lock.lock(); clientFds.remove(fd); lock.unlock()
            Darwin.close(fd)
        }
        guard let path = readRequestPath(fd) else { return }
        handleRequest(fd: fd, path: path)
    }

    // MARK: - Request routing

    private func handleRequest(fd: Int32, path: String) {
        switch path {
        case "/master.m3u8" where config.withMaster:
            let body = masterPlaylist()
            send200(fd: fd, contentType: "application/vnd.apple.mpegurl", body: body)

        case "/low.m3u8":
            send404(fd: fd)

        case "/media.m3u8":
            if config.slowRefresh {
                // Park for 8 seconds before answering (stall exercise).
                Thread.sleep(forTimeInterval: slowRefreshDelay)
                // Check if server was stopped while sleeping.
                lock.lock(); let stopping = shouldStop; lock.unlock()
                if stopping { return }
            }
            let body = mediaPlaylist()
            send200(fd: fd, contentType: "application/vnd.apple.mpegurl", body: body)

        case _ where path.hasPrefix("/seg") && path.hasSuffix(".ts"):
            let indexStr = path.dropFirst("/seg".count).dropLast(".ts".count)
            guard let index = Int(indexStr) else { send404(fd: fd); return }
            if let drop = config.dropSegment, drop == index {
                send404(fd: fd)
                return
            }
            let slice = config.slices[index % config.slices.count]
            sendBinary(fd: fd, contentType: "video/mp2t", body: slice)

        default:
            send404(fd: fd)
        }
    }

    // MARK: - Playlist generation

    /// Compute the current media-sequence number based on wall-clock elapsed time.
    /// Advances by 1 each `segmentSeconds` seconds, starting at 0.
    private func currentSequence() -> Int {
        let elapsed = Date().timeIntervalSince(startTime)
        return max(0, Int(elapsed / Double(config.segmentSeconds)))
    }

    private func mediaPlaylist() -> String {
        let seq = currentSequence()
        let start = max(0, seq - windowSize + 1)

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:3")
        lines.append("#EXT-X-TARGETDURATION:\(config.segmentSeconds)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(start)")

        if config.encrypted {
            lines.append("#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"")
        }
        if config.fmp4 {
            lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        }

        for n in start...seq {
            if let disc = config.discontinuityAt, disc == n {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append("#EXTINF:\(config.segmentSeconds).0,")
            lines.append("seg\(n).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func masterPlaylist() -> String {
        [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-STREAM-INF:BANDWIDTH=100000",
            "low.m3u8",
            "#EXT-X-STREAM-INF:BANDWIDTH=5000000",
            "media.m3u8",
        ].joined(separator: "\n") + "\n"
    }

    // MARK: - HTTP helpers

    private func send200(fd: Int32, contentType: String, body: String) {
        let bodyBytes = [UInt8](body.utf8)
        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(bodyBytes.count)\r\n" +
            "Cache-Control: no-cache, no-store\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        _ = writeAll(fd: fd, bytes: [UInt8](header.utf8))
        _ = writeAll(fd: fd, bytes: bodyBytes)
    }

    private func sendBinary(fd: Int32, contentType: String, body: [UInt8]) {
        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-cache, no-store\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        _ = writeAll(fd: fd, bytes: [UInt8](header.utf8))
        _ = writeAll(fd: fd, bytes: body)
    }

    private func send404(fd: Int32) {
        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = writeAll(fd: fd, bytes: [UInt8](resp.utf8))
    }

    // MARK: - Socket I/O

    private func readRequestPath(_ fd: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 4096)
        var received: [UInt8] = []
        received.reserveCapacity(512)

        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n <= 0 { return nil }
            received.append(contentsOf: buf[0..<n])
            // Look for the end of the first request line.
            if let crlfIdx = received.firstRange(of: [0x0D, 0x0A]) {
                let requestLine = String(bytes: received[..<crlfIdx.lowerBound], encoding: .utf8) ?? ""
                // "GET /path HTTP/1.1"
                let parts = requestLine.split(separator: " ", maxSplits: 3)
                guard parts.count >= 2 else { return nil }
                return String(parts[1])
            }
            if received.count > 8192 { return nil }
        }
    }

    private func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var written = 0
        let total = bytes.count
        guard total > 0 else { return true }
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            while written < total {
                let r = send(fd, base.advanced(by: written), total - written, 0)
                if r < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if r == 0 { return false }
                written += r
            }
            return true
        }
    }

    // MARK: - Errors

    enum FixtureError: Error {
        case socketCreate(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case getsockname(errno: Int32)
    }
}

// MARK: - Arg helpers (scoped to this file)

private func takeFlag(_ name: String, from rest: inout [String]) -> Bool {
    guard let idx = rest.firstIndex(of: name) else { return false }
    rest.remove(at: idx)
    return true
}

private func takeIntArg(_ name: String, from rest: inout [String]) -> Int? {
    guard let idx = rest.firstIndex(of: name),
          idx + 1 < rest.count,
          let v = Int(rest[idx + 1]) else { return nil }
    rest.removeSubrange(idx...(idx + 1))
    return v
}
