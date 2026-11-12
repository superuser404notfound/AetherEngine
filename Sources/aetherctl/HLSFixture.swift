// HLSFixture: a local HTTP server that slices an input MPEG-TS file into
// fixed-size chunks and serves them as a sliding-window live HLS playlist.
//
// Contract
// --------
// Entry point: `runHLSFixture(args:)` is called from main.swift's dispatch.
//
// CLI:
//   aetherctl hlsfixture <input.ts> [--port 8090] [--segment-seconds 4]
//                        [--master] [--codecs STR] [--resolution WxH]
//                        [--discontinuity-at N] [--slow-refresh]
//                        [--drop-segment N] [--encrypted] [--fmp4] [--self-test]
//                        [--require-header "Name: Value"] [--redirect-entry]
//                        [--redirect-host localhost]
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
//                 --codecs / --resolution add CODECS= / RESOLUTION= to both
//                 EXT-X-STREAM-INF lines. Without them AVFoundation reports no
//                 video attributes for the variants, and every decision that
//                 reads them (the #168 carriage watchdog, the #293 probe gate)
//                 sees a master that advertises no video at all: the fixture
//                 then does not carry the case under test.
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
// --require-header "N: V" Answer 403 to every request that does not carry
//                        exactly this header (AE#363: tokenized IPTV origins
//                        enforce a User-Agent / STB profile per request). The
//                        REQ log line then reads auth=ok or auth=MISSING per
//                        request, which is what makes "who lost the header,
//                        and on which hop" a measurement rather than a guess.
// --redirect-entry       Entry URL becomes /entry.m3u8 and 302s to the real
//                        entry on --redirect-host (default localhost) at the
//                        same port: the portal-to-edge hop, cross-origin by
//                        host name while staying on loopback.
// --redirect-port N      Send that 302 to port N instead, i.e. to a SECOND
//                        fixture instance, so the hop changes host and port
//                        the way a portal-to-CDN handoff does.
// --media-origin H:P     Master's variant URIs point at that origin absolutely
//                        (portal serves the master, CDN the media playlist).
// --deny-status N        Refuse with N instead of 403 (401 reaches the engine
//                        as a different NSURLError code, so both are cases).
// --deny-segments-only   Enforce the header on .ts requests only: the refusal
//                        then lands after readyToPlay, which is a different
//                        signal (item error log) from a refused master.
// --deny-user-agent S    Refuse any request whose User-Agent contains S.
//                        "AppleCoreMedia" refuses AVFoundation and serves the
//                        engine's own ingest fetcher, the one origin shape that
//                        tells the two live clients apart (AE#363 acceptance).
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
private let slowRefreshDelay: Double = 8.0

// MARK: - Entry point

func runHLSFixture(args: [String]) -> Int32 {
    var rest = args

    // AE#363: serve pre-cut, GOP-aligned segments instead of byte slices. Byte slicing is fine for
    // "did it route" and useless for "did it play": every slice starts mid-GOP, so the rerouted ingest
    // decodes nothing and the run rebuffers forever. A directory of real segments
    // (`ffmpeg -c copy -f hls -hls_time 4 -hls_flags independent_segments`) makes playthrough an
    // observable, which is what an acceptance run for a routing fix actually needs.
    let segmentsDir = takeStringFlag("--segments-dir", from: &rest)

    guard segmentsDir != nil || (!rest.isEmpty && !rest[0].hasPrefix("-")) else {
        print("ERROR: hlsfixture requires <input.ts> as first argument (or --segments-dir <dir>)")
        print("Usage: aetherctl hlsfixture (<input.ts> | --segments-dir <dir>) [--port N] [--segment-seconds N]")
        print("       [--target-duration N] [--window N]")
        print("       [--master] [--codecs STR] [--resolution WxH] [--discontinuity-at N] [--slow-refresh]")
        print("       [--drop-segment N] [--encrypted] [--fmp4] [--self-test]")
        return 64
    }
    let inputPath = segmentsDir == nil ? rest.removeFirst() : ""

    let port          = takeIntFlag("--port", from: &rest) ?? 8090
    let segSeconds    = takeIntFlag("--segment-seconds", from: &rest) ?? 4
    // 0 causes divide-by-zero in currentSequence(); negatives produce a nonsense playlist.
    guard segSeconds >= 1 else {
        print("ERROR: --segment-seconds must be >= 1 (got \(segSeconds))")
        return 64
    }
    // AE#374: advertised TARGETDURATION, independent of the real cut size. Default keeps the tight
    // ceil(max EXTINF); `--target-duration <segment+1>` is the padded shape a packager commonly serves.
    let advertisedTD  = takeIntFlag("--target-duration", from: &rest)
    // AE#374: sliding-window depth. Three segments is the HLS minimum and the shallowest window a
    // startup gate wanting 3 x TD of content can be handed.
    let windowSegs    = takeIntFlag("--window", from: &rest) ?? 6
    let discAt        = takeIntFlag("--discontinuity-at", from: &rest)
    let dropSeg       = takeIntFlag("--drop-segment", from: &rest)
    // An advertised TD below ceil(max EXTINF) is not a stricter origin, it is an invalid playlist.
    if let td = advertisedTD, td < segSeconds {
        print("ERROR: --target-duration must be >= --segment-seconds (HLS requires TD >= ceil(max EXTINF));"
              + " got \(td) < \(segSeconds)")
        return 64
    }
    guard windowSegs >= 3 else {
        print("ERROR: --window must be >= 3 (HLS live playlists carry at least three segments); got \(windowSegs)")
        return 64
    }
    let withMaster    = takeFlag("--master",       from: &rest)
    let codecs        = takeStringFlag("--codecs", from: &rest)
    let resolution    = takeStringFlag("--resolution", from: &rest)
    let slowRefresh   = takeFlag("--slow-refresh", from: &rest)
    let encrypted     = takeFlag("--encrypted",    from: &rest)
    let fmp4          = takeFlag("--fmp4",         from: &rest)
    let selfTest      = takeFlag("--self-test",    from: &rest)
    // AE#363: header-enforcing origin. "Name: Value"; anything without it gets 403.
    let requireHeaderSpec = takeStringFlag("--require-header", from: &rest)
    // AE#363: portal-to-edge hop. The entry URL becomes /entry.m3u8 and 302s to this host name.
    let redirectEntry = takeFlag("--redirect-entry", from: &rest)
    let redirectHost  = takeStringFlag("--redirect-host", from: &rest) ?? "localhost"
    let redirectPort  = takeIntFlag("--redirect-port", from: &rest).flatMap { UInt16(exactly: $0) }
    // AE#363: master's variants point at another origin absolutely (portal serves the master, CDN
    // serves the media playlist and segments).
    let mediaOrigin   = takeStringFlag("--media-origin", from: &rest)
    let denyStatus    = takeIntFlag("--deny-status", from: &rest) ?? 403
    let denySegments  = takeFlag("--deny-segments-only", from: &rest)
    let denyUserAgent = takeStringFlag("--deny-user-agent", from: &rest)

    var requiredHeader: (name: String, value: String)? = nil
    if let spec = requireHeaderSpec {
        guard let colon = spec.firstIndex(of: ":") else {
            print("ERROR: --require-header expects \"Name: Value\", got '\(spec)'")
            return 64
        }
        requiredHeader = (String(spec[..<colon]).trimmingCharacters(in: .whitespaces),
                          String(spec[spec.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    if !rest.isEmpty {
        print("WARNING: unknown arguments: \(rest.joined(separator: " "))")
    }

    let slices: [[UInt8]]
    do {
        slices = try segmentsDir.map { try loadSegments(directory: $0) } ?? loadAndSlice(path: inputPath)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        return 1
    }
    print("[HLSFixture] slices=\(slices.count) segmentSeconds=\(segSeconds)"
          + " advertisedTD=\(advertisedTD ?? segSeconds) window=\(windowSegs)"
          + (segmentsDir == nil ? "" : " (pre-cut segments)"))

    let config = HLSFixtureConfig(
        slices: slices,
        segmentSeconds: segSeconds,
        targetDurationSeconds: advertisedTD,
        windowSegments: windowSegs,
        withMaster: withMaster,
        codecs: codecs,
        resolution: resolution,
        discontinuityAt: discAt,
        slowRefresh: slowRefresh,
        dropSegment: dropSeg,
        encrypted: encrypted,
        fmp4: fmp4,
        requiredHeader: requiredHeader,
        denyStatus: denyStatus,
        denyUserAgentSubstring: denyUserAgent,
        enforceOnSegmentsOnly: denySegments,
        redirectEntryToHost: redirectEntry ? redirectHost : nil,
        redirectEntryToPort: redirectPort,
        absoluteMediaOrigin: mediaOrigin
    )
    let server = HLSFixtureServer(config: config)
    // UInt16(exactly:) rejects out-of-range port values instead of wrapping silently.
    guard let preferredPort = UInt16(exactly: port) else {
        print("ERROR: --port must be 0-65535 (got \(port))")
        return 64
    }
    let listenPort: UInt16
    do {
        listenPort = try server.start(preferredPort: preferredPort)
    } catch {
        print("ERROR: server start failed: \(error.localizedDescription)")
        return 1
    }

    let entryPath = redirectEntry ? "entry.m3u8" : (withMaster ? "master.m3u8" : "media.m3u8")
    let entryURL  = "http://127.0.0.1:\(listenPort)/\(entryPath)"
    if let requiredHeader {
        print("[HLSFixture] requiring header \(requiredHeader.name): \(requiredHeader.value) (403 otherwise)")
    }
    if redirectEntry {
        print("[HLSFixture] /entry.m3u8 302s to host \(redirectHost) (cross-origin hop)")
    }
    print(entryURL)

    if selfTest {
        return runSelfTest(entryURL: entryURL, server: server,
                           headers: requiredHeader.map { [$0.name: $0.value] } ?? [:])
    }

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

private func runSelfTest(entryURL: String, server: HLSFixtureServer,
                         headers: [String: String] = [:]) -> Int32 {
    guard let url = URL(string: entryURL) else {
        print("FAIL internal: could not build URL from \(entryURL)")
        server.stop()
        return 1
    }

    let reader = HLSLiveIngestReader(playlistURL: url, httpHeaders: headers)
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

// MARK: - Pre-cut segments

/// AE#363: load `*.ts` from `directory` in numeric order. Sorting matters and lexicographic sorting is
/// wrong here: seg10 belongs after seg9, and a window that serves them out of order looks exactly like
/// a decoder defect.
private func loadSegments(directory: String) throws -> [[UInt8]] {
    let fm = FileManager.default
    let names = try fm.contentsOfDirectory(atPath: directory)
        .filter { $0.hasSuffix(".ts") }
        .sorted { a, b in
            let na = Int(a.filter(\.isNumber)) ?? 0
            let nb = Int(b.filter(\.isNumber)) ?? 0
            return na == nb ? a < b : na < nb
        }
    guard !names.isEmpty else {
        throw NSError(domain: "HLSFixture", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "no .ts files in \(directory)"])
    }
    return try names.map { name in
        let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name))
        return [UInt8](data)
    }
}

// MARK: - File slicing

/// Load `path` and split into ~1 MB 188-byte-aligned chunks. Throws if file is not a whole-packet MPEG-TS. Segments cycle so the server never runs out.
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

    let targetBytes = 1 * 1024 * 1024 // ~1 MB per chunk, aligned to 188
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
    /// AE#374: advertised `#EXT-X-TARGETDURATION`. nil = `segmentSeconds`, the tight `ceil(max EXTINF)`.
    /// Packagers commonly pad it (`segment + 1`) to widen a client's unchanged-playlist patience, and the
    /// engine seeds its own served TD floor from whatever the upstream advertises (`LiveCadencePolicy`),
    /// so the padding costs `3 x` itself in first-serve holdback. Reproducible only if it is expressible.
    var targetDurationSeconds: Int? = nil
    /// AE#374: how many segments the sliding window keeps visible. The startup gate wants `3 x TD` of
    /// content behind the live edge, so window depth and advertised TD are the two halves of one cost.
    var windowSegments: Int = 6
    let withMaster: Bool
    /// CODECS / RESOLUTION for the master's variants. nil leaves them off, which is what a variant
    /// with no `AVAssetVariant.videoAttributes` looks like to AVFoundation.
    var codecs: String? = nil
    var resolution: String? = nil
    let discontinuityAt: Int?
    let slowRefresh: Bool
    let dropSegment: Int?
    let encrypted: Bool
    let fmp4: Bool
    /// Slice indices (modulo slice count) that carry an EXT-X-DISCONTINUITY
    /// before them. Used by the SSAI repro (`hlslive`) to mark the
    /// content→ad and ad→content seams. Empty for the default fixture.
    var discontinuityIndices: Set<Int> = []
    /// AE#363: every request without this exact header gets `denyStatus`, which is what a tokenized
    /// IPTV origin does to a client that lost its STB profile. nil = serve everything.
    var requiredHeader: (name: String, value: String)? = nil
    /// AE#363: the refusal status (401 and 403 reach the engine as different NSURLError codes).
    var denyStatus: Int = 403
    /// AE#363: refuse any request whose User-Agent contains this substring. "AppleCoreMedia" refuses
    /// AVFoundation and serves everything else, which is the one origin shape that discriminates
    /// between the two live clients: the AVPlayer bypass is turned away, the engine's own ingest
    /// fetcher is not. UA-filtering IPTV origins are common enough that this is the field case.
    var denyUserAgentSubstring: String? = nil
    /// AE#363: enforce the header on segment requests only, so the refusal lands AFTER readyToPlay
    /// rather than at the master fetch. The two produce different signals and need different code.
    var enforceOnSegmentsOnly: Bool = false
    /// AE#363: when set, `/entry.m3u8` 302s to the real entry on this host name (same loopback
    /// server, different origin). nil = no redirect hop.
    var redirectEntryToHost: String? = nil
    /// AE#363: port of the redirect target. nil = this server's own port (host-name-only hop);
    /// set it to a second fixture instance for a hop that changes host AND port, the shape a
    /// portal-to-edge handoff actually has.
    var redirectEntryToPort: UInt16? = nil
    /// AE#363: `host:port` the master's variant URIs point at, absolute. The second shape a portal
    /// hands out (master here, media and segments on the CDN) and a different question from the
    /// redirect: whether a client carries its origin headers to a host the PLAYLIST names.
    var absoluteMediaOrigin: String? = nil
}

// MARK: - HTTP server

/// Minimal blocking HTTP/HLS fixture server. Thread-per-connection; playlist advances via wall-clock sequence number.
final class HLSFixtureServer: @unchecked Sendable {
    private let config: HLSFixtureConfig
    private var listenFd: Int32 = -1
    private var shouldStop = false
    private let lock = NSLock()
    private var clientFds = Set<Int32>()
    private var port: UInt16 = 0

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
            addr.sin_port = 0 // preferred port busy: let kernel pick
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
                // Unexpected errno (e.g. EMFILE): print so it is not silently confused with an engine-side connect failure.
                print("[HLSFixture] accept failed: errno=\(e); accept loop exiting")
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
        guard let request = readRequest(fd) else { return }
        handleRequest(fd: fd, path: request.path, headers: request.headers)
    }

    // MARK: - Request routing

    private func handleRequest(fd: Int32, path: String, headers: [String: String]) {
        // One line per request: which requests a load actually costs is the observable a request
        // count claim needs (a probe that must not run is proven by the absence of its fetch).
        // AE#363: the header verdict rides on the same line, because "which requests carried the
        // origin header" is the whole question a header-enforcing origin exists to answer.
        if let denied = config.denyUserAgentSubstring,
           let userAgent = headers["user-agent"], userAgent.contains(denied) {
            print("[HLSFixture] REQ \(path) host=\(headers["host"] ?? "?") ua=\(userAgent) "
                  + "-> \(config.denyStatus) (denied user agent)")
            sendDenied(fd: fd, status: config.denyStatus)
            return
        }

        var authVerdict = ""
        if let required = config.requiredHeader,
           !config.enforceOnSegmentsOnly || path.hasSuffix(".ts") {
            let seen = headers[required.name.lowercased()]
            authVerdict = seen == required.value ? " auth=ok" : " auth=MISSING"
            if seen != required.value {
                print("[HLSFixture] REQ \(path) host=\(headers["host"] ?? "?")\(authVerdict)"
                      + " -> \(config.denyStatus)" + (seen == nil ? "" : " (got '\(seen!)')"))
                sendDenied(fd: fd, status: config.denyStatus)
                return
            }
        }
        print("[HLSFixture] REQ \(path) host=\(headers["host"] ?? "?")\(authVerdict)")

        // AE#363: the entry URL is a redirect to a DIFFERENT host name for the same loopback server,
        // which is what a tokenized IPTV portal does (portal answers, CDN edge serves). 127.0.0.1 and
        // localhost are distinct origins to any HTTP client that decides header forwarding by host.
        if let redirectHost = config.redirectEntryToHost, path == "/entry.m3u8" {
            let targetPort = config.redirectEntryToPort ?? lock.withLock { port }
            let target = "http://\(redirectHost):\(targetPort)/\(config.withMaster ? "master.m3u8" : "media.m3u8")"
            print("[HLSFixture] 302 /entry.m3u8 -> \(target)")
            send302(fd: fd, location: target)
            return
        }

        switch path {
        case "/master.m3u8" where config.withMaster:
            let body = masterPlaylist()
            send200(fd: fd, contentType: "application/vnd.apple.mpegurl", body: body)

        case "/low.m3u8":
            send404(fd: fd)

        case "/media.m3u8":
            if config.slowRefresh {
                Thread.sleep(forTimeInterval: slowRefreshDelay) // stall exercise
                lock.lock(); let stopping = shouldStop; lock.unlock()
                if stopping { return }
            }
            let body = mediaPlaylist()
            send200(fd: fd, contentType: "application/vnd.apple.mpegurl", body: body)

        case _ where path.hasPrefix("/seg") && path.hasSuffix(".ts"):
            let indexStr = path.dropFirst("/seg".count).dropLast(".ts".count)
            // index >= 0: Swift % is sign-preserving; a negative index would crash the process.
            guard let index = Int(indexStr), index >= 0 else { send404(fd: fd); return }
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

    /// Media-sequence number derived from wall-clock elapsed time; advances by 1 per segmentSeconds.
    private func currentSequence() -> Int {
        let elapsed = Date().timeIntervalSince(startTime)
        return max(0, Int(elapsed / Double(config.segmentSeconds)))
    }

    private func mediaPlaylist() -> String {
        let seq = currentSequence()
        let start = max(0, seq - config.windowSegments + 1)

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:3")
        lines.append("#EXT-X-TARGETDURATION:\(config.targetDurationSeconds ?? config.segmentSeconds)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(start)")

        if config.encrypted {
            lines.append("#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"")
        }
        if config.fmp4 {
            lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        }

        let sliceCount = max(1, config.slices.count)
        for n in start...seq {
            if config.discontinuityAt == n
                || config.discontinuityIndices.contains(n % sliceCount) {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            lines.append("#EXTINF:\(config.segmentSeconds).0,")
            lines.append("seg\(n).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func masterPlaylist() -> String {
        var attributes = ""
        if let codecs = config.codecs { attributes += ",CODECS=\"\(codecs)\"" }
        if let resolution = config.resolution { attributes += ",RESOLUTION=\(resolution)" }
        let prefix = config.absoluteMediaOrigin.map { "http://\($0)/" } ?? ""
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-STREAM-INF:BANDWIDTH=100000\(attributes)",
            "\(prefix)low.m3u8",
            "#EXT-X-STREAM-INF:BANDWIDTH=5000000\(attributes)",
            "\(prefix)media.m3u8",
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

    /// AE#363: what a header-enforcing origin answers a request that arrives without its header.
    private func sendDenied(fd: Int32, status: Int) {
        let reason = status == 401 ? "Unauthorized" : (status == 403 ? "Forbidden" : "Denied")
        var resp = "HTTP/1.1 \(status) \(reason)\r\n"
        if status == 401 {
            // Without a challenge some clients retry forever instead of surfacing the refusal.
            resp += "WWW-Authenticate: Bearer realm=\"fixture\"\r\n"
        }
        resp += "Content-Length: 0\r\nConnection: close\r\n\r\n"
        _ = writeAll(fd: fd, bytes: [UInt8](resp.utf8))
    }

    /// AE#363: the portal-to-edge hop. 302 rather than 301 so nothing caches the target away.
    private func send302(fd: Int32, location: String) {
        let resp = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\n"
            + "Content-Length: 0\r\nCache-Control: no-cache, no-store\r\nConnection: close\r\n\r\n"
        _ = writeAll(fd: fd, bytes: [UInt8](resp.utf8))
    }

    // MARK: - Socket I/O

    /// Request line plus headers (names lower-cased). Reads to the end of the header block, not just
    /// the first CRLF: AE#363 needs to know which headers a request carried, not only its path.
    private func readRequest(_ fd: Int32) -> (path: String, headers: [String: String])? {
        var buf = [UInt8](repeating: 0, count: 4096)
        var received: [UInt8] = []
        received.reserveCapacity(1024)

        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n <= 0 { return nil }
            received.append(contentsOf: buf[0..<n])
            guard let endIdx = received.firstRange(of: [0x0D, 0x0A, 0x0D, 0x0A]) else {
                if received.count > 16384 { return nil }
                continue
            }
            let block = String(bytes: received[..<endIdx.lowerBound], encoding: .utf8) ?? ""
            var lines = block.components(separatedBy: "\r\n")
            guard !lines.isEmpty else { return nil }
            let requestLine = lines.removeFirst()
            let parts = requestLine.split(separator: " ", maxSplits: 3) // "GET /path HTTP/1.1"
            guard parts.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
            return (String(parts[1]), headers)
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

    enum FixtureError: Error, CustomStringConvertible, LocalizedError {
        case socketCreate(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case getsockname(errno: Int32)

        var description: String {
            switch self {
            case .socketCreate(let e): "HLSFixture: socket() failed (errno=\(e))"
            case .bind(let e): "HLSFixture: bind() failed (errno=\(e))"
            case .listen(let e): "HLSFixture: listen() failed (errno=\(e))"
            case .getsockname(let e): "HLSFixture: getsockname() failed (errno=\(e))"
            }
        }

        var errorDescription: String? { description }
    }
}


