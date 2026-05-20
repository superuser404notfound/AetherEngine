import Darwin
import Foundation

// MARK: - Segment Provider Protocol

/// Source of HLS segment bytes for `HLSLocalServer`.
///
/// Two production implementations exist:
///   - `BufferedSegmentProvider` (built into `HLSLocalServer`) for the
///     live audio passthrough case where segments are pushed in via
///     `setInitSegment` / `addMediaSegment` and held in memory until
///     the session ends.
///   - The video path's lazy on-demand provider (Phase 4) that
///     synthesises each segment when AVPlayer fetches it, never
///     holding more than one or two in memory at a time. Necessary
///     because a 2h 4K video at 6 s / 10 MB segments would otherwise
///     require ~120 GB of resident memory.
protocol HLSSegmentProvider: AnyObject {
    /// Init segment bytes (`ftyp` + empty `moov`). Returns nil when
    /// the muxer hasn't produced one yet (live-audio bring-up).
    func initSegment() -> Data?

    /// Bytes for media segment `index` (0-based). Returns nil if the
    /// segment isn't available yet (live append) or out of range. The
    /// server responds with 404 for nil; callers should not call this
    /// for indices beyond `segmentCount`.
    func mediaSegment(at index: Int) -> Data?

    /// File URL for media segment `index` when the segment is backed
    /// by a real file on disk (the cache adopt path). Returns nil for
    /// providers that hold segments only in memory (BufferedSegmentProvider
    /// audio path) or when the segment isn't yet available. Lets the
    /// server bypass Foundation's `Data(contentsOf:)` entirely and
    /// stream the file straight to the socket via `sendfile(2)`.
    func mediaSegmentURL(at index: Int) -> URL?

    /// Number of segments currently known. May grow over time for
    /// `.event` playlists, fixed for `.vod` playlists.
    var segmentCount: Int { get }

    /// Duration in seconds of segment `index`. May vary per segment
    /// when boundaries snap to source keyframes (the video case);
    /// returns the same value for every index in the audio case.
    func segmentDuration(at index: Int) -> Double

    /// Apple HLS playlist type. `.event` for live appended audio,
    /// `.vod` for the fully-known video case.
    var playlistType: HLSPlaylistType { get }

    /// Optional master-playlist metadata. When `masterCodecs` is
    /// non-nil, the server publishes a `master.m3u8` containing one
    /// variant referencing `media.m3u8` plus these attributes; when
    /// nil, only the media playlist is published.
    var masterCodecs: String? { get }
    var masterResolution: (width: Int, height: Int)? { get }
    var masterVideoRange: HLSVideoRange? { get }
    var masterBandwidth: Int? { get }

    /// SUPPLEMENTAL-CODECS attribute on `EXT-X-STREAM-INF`. Per
    /// Apple's HLS Authoring Spec Appendixes table, Dolby Vision
    /// Profile 8.1 advertises plain HEVC in `CODECS` and signals DV
    /// via `SUPPLEMENTAL-CODECS="dvh1.08.LL/db1p"` (P8.4 uses
    /// `dvh1.08.LL/db4h`). Profile 5 has no fallback variant and
    /// puts `dvh1.05.LL` directly in CODECS, so SUPPLEMENTAL-CODECS
    /// is nil there. AVPlayer's master-level codec filter is
    /// stricter than the segment-level filter and silently drops
    /// any variant whose primary CODECS it can't fall back to: a
    /// bare `dvh1` master made AVPlayer fetch the master 2-3 times
    /// and then never advance to media.m3u8.
    var masterSupplementalCodecs: String? { get }

    /// FRAME-RATE attribute, recommended by Apple's HLS Authoring
    /// Spec for HDR / DV variants.
    var masterFrameRate: Double? { get }

    /// AVERAGE-BANDWIDTH attribute. Apple's spec marks this required
    /// for HDR / DV variants. For VOD it's the same as BANDWIDTH;
    /// for true ABR it's lower than peak.
    var masterAverageBandwidth: Int? { get }

    /// HDCP-LEVEL attribute. Apple Tech Talk 501 says `TYPE-1` is
    /// required for resolutions >1920x1080 in HDR / DV streams.
    var masterHDCPLevel: String? { get }

    /// CLOSED-CAPTIONS attribute. Apple's reference DV samples set
    /// this to `NONE` when there's no in-band CC track.
    var masterClosedCaptions: String? { get }

    /// Hook called by `HLSLocalServer.buildMediaPlaylist` at the top
    /// of each playlist build. Returns the snapshot the playlist
    /// should be built against: visible segment count, refresh
    /// counter (for the byte-level "playlist changed" signal), and
    /// whether the playlist should declare itself complete with
    /// `#EXT-X-ENDLIST`. The video provider uses this to advance a
    /// sliding-window EVENT playlist; the audio provider's default
    /// implementation reports its current state without any side
    /// effect.
    func notePlaylistBuild() -> (visibleCount: Int, refreshCounter: Int, endlistAdded: Bool)
}

extension HLSSegmentProvider {
    /// Default: no file backing. Providers that store segments on
    /// disk override to return the file URL so the server can use
    /// the `sendfile(2)` fast path.
    func mediaSegmentURL(at index: Int) -> URL? { nil }

    var masterCodecs: String? { nil }
    var masterResolution: (width: Int, height: Int)? { nil }
    var masterVideoRange: HLSVideoRange? { nil }
    var masterBandwidth: Int? { nil }
    var masterSupplementalCodecs: String? { nil }
    var masterFrameRate: Double? { nil }
    var masterAverageBandwidth: Int? { nil }
    var masterHDCPLevel: String? { nil }
    var masterClosedCaptions: String? { nil }

    /// Default implementation for providers that don't run a
    /// sliding-window playlist. Reports the current segmentCount,
    /// a zero refresh counter (the byte-level change line is a
    /// video-side concern), and trusts the static playlistType to
    /// drive ENDLIST inclusion.
    func notePlaylistBuild() -> (visibleCount: Int, refreshCounter: Int, endlistAdded: Bool) {
        return (visibleCount: segmentCount, refreshCounter: 0, endlistAdded: false)
    }
}

enum HLSPlaylistType {
    case event
    case vod
}

enum HLSVideoRange: String {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
}

// MARK: - Local HLS Server

/// Loopback HTTP server feeding HLS-fMP4 to AVPlayer.
///
/// Implementation note: BSD sockets via Darwin (socket / bind /
/// listen / accept / recv / send). Predecessor used NWConnection
/// from Network.framework. We swapped it out after empirically
/// measuring that NWConnection's send path retained segment bytes
/// in its internal queue across the contentProcessed callback,
/// producing ~3 MB/sec RSS growth proportional to the source
/// video bitrate on long-form 4K HDR HEVC sessions (AetherEngine#4).
/// DrHurt's hypothesis on the issue thread that "your on-device
/// http server is caching segments in ram" pointed straight at it.
///
/// BSD sockets + `Data.withUnsafeBytes` on a mmap-backed `Data`
/// give us a kernel-to-kernel copy from the segment file's page
/// cache to the socket send buffer with no user-space heap copy
/// at all. Combined with the disk-backed SegmentCache, the entire
/// serve path is zero-allocation per segment.
///
/// Endpoints:
///   - `/master.m3u8` only when the provider has master-level
///     metadata (codecs, resolution, video range). Required for
///     Dolby Vision because `VIDEO-RANGE=PQ` and the `CODECS=dvh1.…`
///     attribute live on `EXT-X-STREAM-INF`, not on a media playlist.
///   - `/media.m3u8` always present. EVENT or VOD depending on the
///     provider.
///   - `/init.mp4` the `ftyp`+`moov` init segment.
///   - `/seg{N}.mp4` the N-th `moof`+`mdat` media segment.
///
/// Threading: one accept loop on `acceptQueue`, each accepted
/// connection handled on `workQueue` (concurrent) with blocking
/// recv / send syscalls. Provider methods are thread-safe by
/// contract (the buffered impl uses an NSLock, the video path's
/// `HLSSegmentProducer` is `@unchecked Sendable` with internal
/// locks). Server's own mutable state is guarded by `stateLock`.
///
/// Listens on `127.0.0.1`. Sodalite's Info.plist sets
/// `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking` so ATS
/// is exempt either way; the IP literal avoids any DNS resolver
/// dependency that the `localhost` hostname form would imply.
final class HLSLocalServer: @unchecked Sendable {

    // MARK: - Provider

    /// External provider, set via `init(provider:)`. Mutually
    /// exclusive with `bufferedProvider`.
    private weak var externalProvider: HLSSegmentProvider?
    /// Built-in buffered provider for the legacy audio path. Lives
    /// behind `setInitSegment` / `addMediaSegment`. Nil when an
    /// external provider is supplied.
    private var bufferedProvider: BufferedSegmentProvider?

    private var provider: HLSSegmentProvider? {
        externalProvider ?? bufferedProvider
    }

    // MARK: - Public state

    /// Wall-clock time when seg0 was first fetched by AVPlayer. Used
    /// by the audio engine to measure HLS pipeline latency from
    /// "first segment available" to "AVPlayer asked for it".
    private(set) var seg0FetchTime: Date?

    /// Listening port, assigned by the kernel from the ephemeral
    /// range. Zero until `start()` succeeds.
    private(set) var port: UInt16 = 0

    /// URL the host hands to AVPlayer to start playback. Points at
    /// the master playlist if the provider has one, else the media
    /// playlist directly.
    var playlistURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard port > 0 else { return nil }
        let path = (provider?.masterCodecs != nil) ? "master.m3u8" : "media.m3u8"
        return URL(string: "http://127.0.0.1:\(port)/\(path)")
    }

    /// Direct media-playlist URL, bypassing master-playlist variant
    /// selection. Host route picks this URL whenever the DV / HDR
    /// display handshake isn't available so AVPlayer doesn't try
    /// to match a `dvh1` master against an SDR-locked panel.
    var mediaPlaylistURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/media.m3u8")
    }

    /// Number of segments currently published.
    var segmentCount: Int {
        provider?.segmentCount ?? 0
    }

    // MARK: - Private state

    private var listenFd: Int32 = -1
    private var shouldStop = false
    /// Active client file descriptors so `stop()` can close them
    /// and unblock their `recv` / `send` syscalls. Modify only
    /// while holding `stateLock`.
    private var clientFds = Set<Int32>()

    /// Current count of accepted, not-yet-closed client connections.
    /// Read by the engine memory probe to spot CFNetwork loopback
    /// keep-alive accumulation. AVPlayer typically holds 1-3 long-
    /// lived connections to the local server; a steadily rising number
    /// would point here.
    var activeConnectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return clientFds.count
    }

    /// Lifetime sum of bytes ever sent through `writeAll` and
    /// `sendfileAll` over all responses. Compared against the muxer's
    /// `muxBytesMB` in the engine memprobe — equality confirms the
    /// data path is intact (no duplicate sends, no dropped bytes).
    private let byteCounterLock = NSLock()
    private var _lifetimeBytesSent: Int = 0
    var lifetimeBytesSent: Int {
        byteCounterLock.lock()
        defer { byteCounterLock.unlock() }
        return _lifetimeBytesSent
    }
    private func bumpBytesSent(_ n: Int) {
        guard n > 0 else { return }
        byteCounterLock.lock()
        _lifetimeBytesSent &+= n
        byteCounterLock.unlock()
    }

    /// Lifetime count of segment bytes sent via the `sendfile(2)`
    /// fast path (file → socket entirely in-kernel, zero Swift Data
    /// involvement). Used to verify the path is actually taken vs.
    /// falling back to the Data path.
    private var _lifetimeSendfileBytes: Int = 0
    var lifetimeSendfileBytes: Int {
        byteCounterLock.lock()
        defer { byteCounterLock.unlock() }
        return _lifetimeSendfileBytes
    }
    private func bumpSendfileBytes(_ n: Int) {
        guard n > 0 else { return }
        byteCounterLock.lock()
        _lifetimeSendfileBytes &+= n
        byteCounterLock.unlock()
    }

    /// One-shot flags so we log each playlist's full body once per
    /// session instead of on every AVPlayer re-fetch.
    private var loggedMasterPlaylist = false
    private var loggedMediaPlaylist = false

    /// Guards every mutable field above plus the listenFd. Reads
    /// from the public-facing computed properties take the lock too.
    /// Lightweight; never held across blocking syscalls.
    private let stateLock = NSLock()

    private let acceptQueue = DispatchQueue(
        label: "com.aetherengine.hls.accept",
        qos: .userInitiated
    )
    private let workQueue = DispatchQueue(
        label: "com.aetherengine.hls.work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Init

    init() {
        self.bufferedProvider = BufferedSegmentProvider()
    }

    init(provider: HLSSegmentProvider) {
        self.externalProvider = provider
        self.bufferedProvider = nil
    }

    // MARK: - Lifecycle

    func start() throws {
        // SOCK_STREAM = TCP, IPPROTO_TCP = 6.
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw HLSLocalServerError.socketCreate(errno: errno)
        }

        // SO_REUSEADDR avoids "Address already in use" when the
        // previous server's TIME_WAIT entries haven't cleared yet.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on,
                       socklen_t(MemoryLayout<Int32>.size))
        // SO_NOSIGPIPE prevents SIGPIPE when the client closes the
        // socket mid-write. Without this a closed peer kills the
        // process. send() returns EPIPE instead, which we handle.
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // kernel picks ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw HLSLocalServerError.bind(errno: err)
        }

        // backlog=16 is plenty: AVPlayer typically opens 1-3 conns.
        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw HLSLocalServerError.listen(errno: err)
        }

        // Read back the assigned port.
        var actual = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &actualLen)
            }
        }
        guard getNameResult == 0 else {
            let err = errno
            close(fd)
            throw HLSLocalServerError.getsockname(errno: err)
        }
        let assignedPort = UInt16(bigEndian: actual.sin_port)

        stateLock.lock()
        listenFd = fd
        port = assignedPort
        shouldStop = false
        stateLock.unlock()

        EngineLog.emit("[HLSLocalServer] Listening on port \(assignedPort)",
                       category: .hlsServer)

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        stateLock.lock()
        shouldStop = true
        let fdToClose = listenFd
        listenFd = -1
        port = 0
        loggedMasterPlaylist = false
        loggedMediaPlaylist = false
        let clients = clientFds
        clientFds.removeAll()
        bufferedProvider?.clear()
        seg0FetchTime = nil
        stateLock.unlock()

        // Close the listen fd to unblock accept().
        if fdToClose >= 0 {
            close(fdToClose)
        }
        // Close all active client fds to unblock recv/send.
        for fd in clients {
            close(fd)
        }
    }

    // MARK: - Buffered-provider passthrough (legacy audio API)

    func setInitSegment(_ data: Data) {
        bufferedProvider?.setInitSegment(data)
    }

    func addMediaSegment(_ data: Data, duration: Double) {
        bufferedProvider?.addMediaSegment(data, duration: duration)
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let stopping = shouldStop
            let fd = listenFd
            stateLock.unlock()
            if stopping || fd < 0 { return }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &clientLen)
                }
            }
            if clientFd < 0 {
                let err = errno
                // EBADF means listenFd was closed by stop(); exit cleanly.
                if err == EBADF || err == EINVAL {
                    return
                }
                // EINTR / EAGAIN: spurious wakeup, retry.
                if err == EINTR || err == EAGAIN {
                    continue
                }
                EngineLog.emit("[HLSLocalServer] accept failed errno=\(err)",
                               category: .hlsServer)
                continue
            }

            // SO_NOSIGPIPE on the accepted socket too, otherwise a
            // closed-peer send still raises SIGPIPE on iOS.
            var on: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                           socklen_t(MemoryLayout<Int32>.size))
            // 60s idle timeout. AVPlayer's typical inter-request gap
            // is single-digit seconds; 60s is comfortable headroom.
            var timeout = timeval(tv_sec: 60, tv_usec: 0)
            _ = setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                           socklen_t(MemoryLayout<timeval>.size))

            stateLock.lock()
            clientFds.insert(clientFd)
            stateLock.unlock()

            EngineLog.emit("[HLSLocalServer] conn opened fd=\(clientFd)",
                           category: .hlsServer)

            workQueue.async { [weak self] in
                self?.handleConnection(clientFd)
            }
        }
    }

    // MARK: - Per-connection handler

    private func handleConnection(_ fd: Int32) {
        defer {
            stateLock.lock()
            clientFds.remove(fd)
            stateLock.unlock()
            close(fd)
            EngineLog.emit("[HLSLocalServer] conn closed fd=\(fd)",
                           category: .hlsServer)
        }

        // HTTP/1.1 keep-alive loop. AVPlayer reuses a single
        // connection for several segment fetches before opening
        // a new one. (Tried Connection: close per-request on 2026-05-20
        // to bound libnetwork pool growth — Instruments showed it
        // shifted the same leak from libnetwork into a 570 MiB heap
        // bucket of Malloc 10 MiB chunks instead. Strictly worse,
        // reverted.)
        while true {
            stateLock.lock()
            let stopping = shouldStop
            stateLock.unlock()
            if stopping { return }
            guard let request = readHTTPRequest(fd) else { return }
            guard processRequest(request, on: fd) else { return }
        }
    }

    /// Read until end of HTTP headers (`\r\n\r\n`). Returns the raw
    /// request bytes (headers only — no body, since we only accept
    /// GET). Returns nil on EOF, error, or oversize.
    private func readHTTPRequest(_ fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n == 0 {
                if buffer.isEmpty { return nil }
                EngineLog.emit("[HLSLocalServer] peer EOF mid-request fd=\(fd)",
                               category: .hlsServer)
                return nil
            }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    EngineLog.emit("[HLSLocalServer] recv timeout fd=\(fd)",
                                   category: .hlsServer)
                    return nil
                }
                EngineLog.emit("[HLSLocalServer] recv error fd=\(fd) errno=\(err)",
                               category: .hlsServer)
                return nil
            }
            buffer.append(chunk, count: n)
            if let end = findHeadersTerminator(buffer) {
                return buffer.prefix(end + 4)
            }
            if buffer.count > 8192 {
                EngineLog.emit("[HLSLocalServer] request too large fd=\(fd) bytes=\(buffer.count)",
                               category: .hlsServer)
                return nil
            }
        }
    }

    private func findHeadersTerminator(_ buf: Data) -> Int? {
        guard buf.count >= 4 else { return nil }
        let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        return buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            for i in 0...(buf.count - 4) {
                if base[i] == needle[0] && base[i + 1] == needle[1]
                    && base[i + 2] == needle[2] && base[i + 3] == needle[3] {
                    return i
                }
            }
            return nil
        }
    }

    private func processRequest(_ request: Data, on fd: Int32) -> Bool {
        guard let text = String(data: request, encoding: .utf8) else {
            EngineLog.emit("[HLSLocalServer] non-UTF8 request bytes (\(request.count)B)",
                           category: .hlsServer)
            return false
        }
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2,
                                    omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            EngineLog.emit("[HLSLocalServer] malformed request line: '\(firstLine)'",
                           category: .hlsServer)
            return false
        }
        let path = String(parts[1])
        let normalizedPath = (path == "/audio.m3u8") ? "/media.m3u8" : path

        EngineLog.emit("[HLSLocalServer] \(firstLine)", category: .hlsServer)

        switch normalizedPath {
        case "/master.m3u8":
            if provider?.masterCodecs != nil {
                let body = buildMasterPlaylist()
                stateLock.lock()
                let firstTime = !loggedMasterPlaylist
                if firstTime { loggedMasterPlaylist = true }
                stateLock.unlock()
                if firstTime {
                    EngineLog.emit("[HLSLocalServer] master.m3u8 body:\n\(body)",
                                   category: .hlsServer)
                }
                return send200(fd: fd, path: normalizedPath,
                               data: Data(body.utf8),
                               contentType: "application/vnd.apple.mpegurl")
            }
            return send404(fd: fd, path: normalizedPath, reason: "no masterCodecs")

        case "/media.m3u8":
            let body = buildMediaPlaylist()
            stateLock.lock()
            let firstTime = !loggedMediaPlaylist
            if firstTime { loggedMediaPlaylist = true }
            stateLock.unlock()
            if firstTime {
                let head = body.split(separator: "\n").prefix(8).joined(separator: "\n")
                EngineLog.emit("[HLSLocalServer] media.m3u8 head:\n\(head)",
                               category: .hlsServer)
            }
            return send200(fd: fd, path: normalizedPath,
                           data: Data(body.utf8),
                           contentType: "application/vnd.apple.mpegurl")

        case "/init.mp4":
            let data = provider?.initSegment() ?? Data()
            if data.isEmpty {
                return send404(fd: fd, path: normalizedPath,
                               reason: "init.mp4 empty (provider not ready?)")
            }
            return send200(fd: fd, path: normalizedPath, data: data,
                           contentType: "video/mp4")

        default:
            if normalizedPath.hasPrefix("/seg"),
               normalizedPath.hasSuffix(".mp4") {
                let indexStr = normalizedPath.dropFirst(4).dropLast(4)
                if let index = Int(indexStr), index >= 0 {
                    if index == 0 {
                        stateLock.lock()
                        if seg0FetchTime == nil { seg0FetchTime = Date() }
                        stateLock.unlock()
                    }
                    // Fast path: if the segment is file-backed (cache
                    // adopt path), stream via `sendfile(2)` directly
                    // from the page cache to the socket — bypasses
                    // Foundation `Data(contentsOf:)` entirely. Tests
                    // the hypothesis that `.alwaysMapped` was silently
                    // materializing the segment into anonymous heap
                    // per fetch, leaking ~one-segment-worth per serve.
                    if let url = provider?.mediaSegmentURL(at: index) {
                        return send200File(fd: fd, path: normalizedPath,
                                            fileURL: url,
                                            contentType: "video/mp4")
                    }
                    if let data = provider?.mediaSegment(at: index),
                       !data.isEmpty {
                        return send200(fd: fd, path: normalizedPath, data: data,
                                       contentType: "video/mp4")
                    }
                    let providerCount = provider?.segmentCount ?? -1
                    return send404(fd: fd, path: normalizedPath,
                                   reason: "segment[\(index)] empty (segmentCount=\(providerCount))")
                }
                return send404(fd: fd, path: normalizedPath,
                               reason: "unparseable seg index '\(indexStr)'")
            }
            return send404(fd: fd, path: normalizedPath, reason: "unknown path")
        }
    }

    // MARK: - HTTP framing

    /// Header + body send via two separate `send` calls. Critical:
    /// `data` may be a mmap-backed `Data` (the disk-segment-cache
    /// path), and we MUST NOT concatenate it via `Data.append` —
    /// that forces a copy into payload's own backing buffer,
    /// materialising the entire segment into Swift heap. The bug
    /// the BSD-socket rewrite is fixing.
    ///
    /// `writeAll` calls `data.withUnsafeBytes` to get a pointer
    /// straight at the mmap'd pages and hands it to `send(2)`.
    /// Kernel copies page-cache -> socket-send-buffer. No heap
    /// involvement.
    private func send200(fd: Int32, path: String, data: Data, contentType: String) -> Bool {
        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n"
        let headerData = Data(header.utf8)

        EngineLog.emit("[HLSLocalServer] -> 200 \(path) bytes=\(data.count) type=\(contentType)",
                       category: .hlsServer)

        guard writeAll(fd: fd, data: headerData, path: "\(path) [header]") else {
            return false
        }
        return writeAll(fd: fd, data: data, path: path)
    }

    /// HTTP 200 response whose body is streamed from a file via
    /// `sendfile(2)`. Header goes through `writeAll` as usual; body
    /// stays kernel-side. Returns false on file-open failure (treat
    /// as 5xx the caller logs and the connection dies), broken pipe,
    /// or zero-length file.
    private func send200File(fd: Int32, path: String, fileURL: URL, contentType: String) -> Bool {
        // Stat the file to fill Content-Length. If the file is missing
        // or zero-length we treat as a cache miss → 404, same as the
        // Data path.
        let fsAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (fsAttrs?[.size] as? Int) ?? 0
        if fileSize == 0 {
            return send404(fd: fd, path: path, reason: "file \(fileURL.lastPathComponent) missing or empty")
        }

        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(fileSize)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n"
        let headerData = Data(header.utf8)

        EngineLog.emit("[HLSLocalServer] -> 200 \(path) bytes=\(fileSize) type=\(contentType) [sendfile]",
                       category: .hlsServer)

        guard writeAll(fd: fd, data: headerData, path: "\(path) [header]") else {
            return false
        }
        return sendfileAll(fileURL: fileURL, socketFd: fd, path: path)
    }

    private func send404(fd: Int32, path: String, reason: String) -> Bool {
        let response =
            "HTTP/1.1 404 Not Found\r\n" +
            "Content-Length: 0\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n"
        EngineLog.emit("[HLSLocalServer] -> 404 \(path) reason=\(reason)",
                       category: .hlsServer)
        return writeAll(fd: fd, data: Data(response.utf8), path: path)
    }

    /// Blocking send loop. Reads `data` via `withUnsafeBytes` so
    /// mmap-backed Data stays mmap-backed — the kernel page-faults
    /// in only the bytes it's about to copy into the socket send
    /// buffer; nothing accumulates in our heap. Returns false on
    /// broken pipe / error.
    private func writeAll(fd: Int32, data: Data, path: String) -> Bool {
        var written = 0
        let total = data.count
        if total == 0 { return true }
        while written < total {
            let result = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                let remaining = total - written
                return send(fd, base.advanced(by: written), remaining, 0)
            }
            if result < 0 {
                let err = errno
                if err == EINTR { continue }
                EngineLog.emit("[HLSLocalServer] send failed for \(path): errno=\(err)",
                               category: .hlsServer)
                return false
            }
            if result == 0 {
                EngineLog.emit("[HLSLocalServer] send returned 0 for \(path)",
                               category: .hlsServer)
                return false
            }
            written += result
        }
        bumpBytesSent(total)
        return true
    }

    /// Stream a file to the socket through a fixed-size reusable
    /// buffer. Bypasses Foundation `Data(contentsOf:)` so any
    /// silent heap materialization that path triggered on tvOS
    /// cannot account for the residual leak.
    ///
    /// (Tried `sendfile(2)` first — the obvious zero-copy approach —
    /// but tvOS sandboxes that syscall and the process gets SIGSYS'd
    /// on first call. Reverted to chunked read+send.)
    ///
    /// Buffer: one 256 KB heap allocation per call, deallocated on
    /// return. Constant per-request memory; the kernel-side page
    /// cache services the reads.
    ///
    /// Returns false on broken pipe / file open failure / partial
    /// send the kernel won't drain. The caller treats failure the
    /// same as a `writeAll` failure: close the connection.
    private func sendfileAll(fileURL: URL, socketFd: Int32, path: String) -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            EngineLog.emit("[HLSLocalServer] file open failed \(path): \(error)",
                           category: .hlsServer)
            return false
        }
        let fileFd = handle.fileDescriptor
        defer { try? handle.close() }

        let chunkSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        var totalSent: Int = 0
        while true {
            let nRead = read(fileFd, buffer, chunkSize)
            if nRead == 0 {
                // EOF. Full file transferred.
                bumpBytesSent(totalSent)
                bumpSendfileBytes(totalSent)
                return true
            }
            if nRead < 0 {
                let err = errno
                if err == EINTR { continue }
                EngineLog.emit("[HLSLocalServer] file read failed \(path): errno=\(err) sent=\(totalSent)",
                               category: .hlsServer)
                return false
            }
            // Drain this chunk to the socket. Partial sends loop.
            var written = 0
            while written < nRead {
                let n = send(socketFd, buffer.advanced(by: written), nRead - written, 0)
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    EngineLog.emit("[HLSLocalServer] send failed \(path): errno=\(err) sent=\(totalSent + written)",
                                   category: .hlsServer)
                    return false
                }
                if n == 0 {
                    EngineLog.emit("[HLSLocalServer] send returned 0 \(path) sent=\(totalSent + written)",
                                   category: .hlsServer)
                    return false
                }
                written += n
            }
            totalSent += nRead
        }
    }

    // MARK: - Playlist construction

    private func buildMasterPlaylist() -> String {
        guard let provider = provider, let codecs = provider.masterCodecs else {
            return "#EXTM3U\n"
        }
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")

        // EXT-X-STREAM-INF attribute order follows Apple's HLS
        // Authoring Spec Appendixes example: BANDWIDTH first,
        // AVERAGE-BANDWIDTH next, then CODECS, then SUPPLEMENTAL-
        // CODECS, then RESOLUTION / FRAME-RATE / VIDEO-RANGE, then
        // HDCP-LEVEL / CLOSED-CAPTIONS at the end.
        var streamInfAttrs: [String] = []
        let bandwidth = provider.masterBandwidth ?? 5_000_000
        streamInfAttrs.append("BANDWIDTH=\(bandwidth)")
        if let avg = provider.masterAverageBandwidth {
            streamInfAttrs.append("AVERAGE-BANDWIDTH=\(avg)")
        }
        streamInfAttrs.append("CODECS=\"\(codecs)\"")
        if let supplemental = provider.masterSupplementalCodecs {
            streamInfAttrs.append("SUPPLEMENTAL-CODECS=\"\(supplemental)\"")
        }
        if let resolution = provider.masterResolution {
            streamInfAttrs.append("RESOLUTION=\(resolution.width)x\(resolution.height)")
        }
        if let frameRate = provider.masterFrameRate {
            streamInfAttrs.append("FRAME-RATE=\(String(format: "%.3f", frameRate))")
        }
        if let range = provider.masterVideoRange {
            streamInfAttrs.append("VIDEO-RANGE=\(range.rawValue)")
        }
        if let hdcp = provider.masterHDCPLevel {
            streamInfAttrs.append("HDCP-LEVEL=\(hdcp)")
        }
        if let cc = provider.masterClosedCaptions {
            streamInfAttrs.append("CLOSED-CAPTIONS=\(cc)")
        }
        lines.append("#EXT-X-STREAM-INF:\(streamInfAttrs.joined(separator: ","))")
        lines.append("media.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    private func buildMediaPlaylist() -> String {
        guard let provider = provider else { return "#EXTM3U\n" }
        // Atomic snapshot of visible-window state. The video provider
        // uses this hook to advance its sliding window; capturing the
        // snapshot once and reading from it prevents segmentCount /
        // playlistType from drifting between read sites inside this
        // build.
        let snapshot = provider.notePlaylistBuild()
        let count = snapshot.visibleCount
        let typeIsEvent = (provider.playlistType == .event && !snapshot.endlistAdded)

        // Compute target duration as ceil of the longest segment.
        // Spec requires this be >= every EXTINF in the playlist.
        var maxDuration: Double = 0
        for i in 0..<count {
            maxDuration = max(maxDuration, provider.segmentDuration(at: i))
        }
        let targetDuration = Int(ceil(max(1.0, maxDuration)))

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-TARGETDURATION:\(targetDuration)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")
        if typeIsEvent {
            lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
            lines.append("#EXT-X-SODALITE-REFRESH:\(snapshot.refreshCounter)")
        } else {
            // Without EXT-X-PLAYLIST-TYPE:VOD AVPlayer treats the playlist
            // as potentially mutable and retains every fetched segment in
            // process memory in case a later refresh extends the window.
            // With ENDLIST present the playlist is by definition final,
            // but the explicit VOD tag is what lets AVPlayer prune fetched
            // segments past the buffer-behind window. Without it RSS grows
            // linearly with segment count for the entire playback (the
            // libavformat hlsenc + ffmpeg-cli reference build sets this
            // when -hls_playlist_type vod is on; matching that output is
            // the only reason our Mac AirPlay reference run stays flat).
            lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        }
        lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        for i in 0..<count {
            let dur = provider.segmentDuration(at: i)
            lines.append("#EXTINF:\(String(format: "%.3f", dur)),")
            lines.append("seg\(i).mp4")
        }
        if snapshot.endlistAdded || !typeIsEvent {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Errors

enum HLSLocalServerError: Error, CustomStringConvertible {
    case socketCreate(errno: Int32)
    case bind(errno: Int32)
    case listen(errno: Int32)
    case getsockname(errno: Int32)

    var description: String {
        switch self {
        case .socketCreate(let e): return "HLSLocalServer: socket() failed (errno=\(e))"
        case .bind(let e):         return "HLSLocalServer: bind() failed (errno=\(e))"
        case .listen(let e):       return "HLSLocalServer: listen() failed (errno=\(e))"
        case .getsockname(let e):  return "HLSLocalServer: getsockname() failed (errno=\(e))"
        }
    }
}

// MARK: - Buffered Segment Provider (for the legacy audio path)

/// In-memory provider that backs the `HLSLocalServer` when no
/// external provider is supplied. The audio engine's segments are
/// small (~16 KB at 0.5 s each) so holding them all in memory is
/// fine for the duration of a session. The video path uses a
/// different (lazy) provider that never holds more than one or two
/// segments at a time.
private final class BufferedSegmentProvider: HLSSegmentProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var initData: Data?
    private var segments: [Data] = []
    private var perSegmentDuration: Double = 2.048

    func setInitSegment(_ data: Data) {
        lock.lock()
        initData = data
        lock.unlock()
    }

    func addMediaSegment(_ data: Data, duration: Double) {
        lock.lock()
        segments.append(data)
        perSegmentDuration = duration
        lock.unlock()
    }

    func clear() {
        lock.lock()
        initData = nil
        segments.removeAll()
        lock.unlock()
    }

    func initSegment() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return initData
    }

    func mediaSegment(at index: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return (index >= 0 && index < segments.count) ? segments[index] : nil
    }

    var segmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return segments.count
    }

    func segmentDuration(at index: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return perSegmentDuration
    }

    var playlistType: HLSPlaylistType { .event }
}
