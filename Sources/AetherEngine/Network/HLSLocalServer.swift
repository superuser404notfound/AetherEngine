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
}

extension HLSSegmentProvider {
    var masterCodecs: String? { nil }
    var masterResolution: (width: Int, height: Int)? { nil }
    var masterVideoRange: HLSVideoRange? { nil }
    var masterBandwidth: Int? { nil }
    var masterSupplementalCodecs: String? { nil }
    var masterFrameRate: Double? { nil }
    var masterAverageBandwidth: Int? { nil }
    var masterHDCPLevel: String? { nil }
    var masterClosedCaptions: String? { nil }
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
/// Phase-5 rewrite: uses POSIX BSD sockets + GCD instead of
/// `Network.NWListener` / `NWConnection`. The earlier `Network`-
/// framework implementation cooperated with `MPNowPlayingInfoCenter`
/// writes in a way that reproducibly tripped
/// `_dispatch_assert_queue_fail` deep inside MediaPlayer on tvOS 26
/// (manual nowPlayingInfo writes from outside AVKit always crashed,
/// regardless of timing or queue). Swiftfin uses manual writes
/// successfully because their AVPlayer reads real HTTPS, never a
/// loopback `NWConnection`. Dropping NWConnection from the loopback
/// removes the queue-affinity collision; manual writes can then
/// drive title / artwork / skip-command targets the same way
/// Swiftfin does.
///
/// Threading: one accept loop on a dedicated serial queue, each
/// accepted connection handled on a concurrent worker queue with
/// blocking `recv` / `send` syscalls. Provider methods are
/// thread-safe by contract (the buffered impl uses an NSLock, the
/// video path's `HLSSegmentProducer` is `@unchecked Sendable` with
/// internal locks). Server's own mutable state (`port`,
/// `loggedMaster/MediaPlaylist`, `seg0FetchTime`, `clientFds`) is
/// guarded by `stateLock`.
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
/// Listens on `127.0.0.1` so tvOS App Transport Security treats it
/// as loopback-exempt (`NSAllowsLocalNetworking` in Sodalite's
/// Info.plist) without per-domain plist entries.
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
    ///
    /// Uses the IP literal `127.0.0.1` rather than the hostname
    /// `localhost`. The hostname form needs DNS / nsswitch /
    /// /etc/hosts to resolve, and AVPlayer on tvOS appears to hang
    /// in its pre-flight before opening any TCP socket when
    /// resolution doesn't return immediately. The IP literal
    /// sidesteps the resolver entirely.
    var playlistURL: URL? {
        guard port > 0 else { return nil }
        let path = (provider?.masterCodecs != nil) ? "master.m3u8" : "media.m3u8"
        return URL(string: "http://127.0.0.1:\(port)/\(path)")
    }

    /// Direct media-playlist URL, bypassing the master-playlist
    /// variant-selection step. Per DrHurt's note on AetherEngine#2:
    /// when AVPlayer loads a media playlist directly rather than
    /// via a master, it automatically tone-maps HDR / Dolby Vision
    /// content to whatever the display can render. The host route
    /// picks this URL instead of `playlistURL` whenever the DV /
    /// HDR display handshake isn't available.
    var mediaPlaylistURL: URL? {
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
    /// and unblock their `recv` / `send` calls. Modify only while
    /// holding `stateLock`.
    private var clientFds = Set<Int32>()

    /// One-shot flags so we log each playlist's full body once per
    /// session instead of on every AVPlayer re-fetch.
    private var loggedMasterPlaylist = false
    private var loggedMediaPlaylist = false

    /// Guards every mutable field above plus the listenFd. Reads
    /// from the public-facing computed properties (`playlistURL`,
    /// etc.) take the lock too. Lightweight; never held across
    /// blocking syscalls.
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

    /// Default init for the legacy audio path. Creates a built-in
    /// `BufferedSegmentProvider`; `setInitSegment` / `addMediaSegment`
    /// route into it.
    init() {
        self.bufferedProvider = BufferedSegmentProvider()
    }

    /// Init with a caller-supplied provider for the video path.
    /// `setInitSegment` and `addMediaSegment` are no-ops in this mode.
    init(provider: HLSSegmentProvider) {
        self.externalProvider = provider
        self.bufferedProvider = nil
    }

    // MARK: - Lifecycle

    func start() throws {
        // Create TCP socket on 127.0.0.1 with an ephemeral port.
        // SOCK_STREAM = TCP, IPPROTO_TCP = 6.
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw HLSLocalServerError.socketCreate(errno: errno)
        }

        // SO_REUSEADDR avoids "Address already in use" when the
        // previous server's TIME_WAIT entries haven't cleared yet.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        // SO_NOSIGPIPE prevents SIGPIPE when the client closes the
        // socket mid-write. Without this a closed peer kills the
        // process. send() will return EPIPE instead, which we
        // handle gracefully.
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

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

        // backlog=16 is plenty: AVPlayer typically opens 1-3 connections.
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
        loggedMasterPlaylist = false
        loggedMediaPlaylist = false
        stateLock.unlock()

        EngineLog.emit("[HLSLocalServer] Listening on port \(assignedPort)", category: .hlsServer)

        // Launch the accept loop. acceptQueue is serial and holds
        // the blocking `accept()` call for the lifetime of the
        // server; stop() closes listenFd to wake it.
        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(listenFd: fd)
        }
    }

    func stop() {
        // 1. Flip the stop flag and snapshot live fds.
        stateLock.lock()
        shouldStop = true
        let listenSnapshot = listenFd
        let clients = clientFds
        listenFd = -1
        clientFds.removeAll()
        port = 0
        loggedMasterPlaylist = false
        loggedMediaPlaylist = false
        seg0FetchTime = nil
        stateLock.unlock()

        bufferedProvider?.clear()

        // 2. Close the listen socket — unblocks the accept loop's
        // accept() call with EBADF / -1.
        if listenSnapshot >= 0 {
            close(listenSnapshot)
        }
        // 3. Close all client sockets — unblocks their handler
        // threads' recv() / send() calls. Handlers exit via the
        // EOF / EBADF return path.
        for cfd in clients {
            close(cfd)
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

    private func runAcceptLoop(listenFd: Int32) {
        while true {
            // Check stop flag before accept(); cheap.
            stateLock.lock()
            let stopping = shouldStop
            stateLock.unlock()
            if stopping { return }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFd, sa, &clientLen)
                }
            }
            if clientFd < 0 {
                let err = errno
                if err == EINTR { continue }
                // EBADF / ECONNABORTED / etc. — listen socket likely
                // closed via stop(). Exit loop cleanly.
                EngineLog.emit("[HLSLocalServer] accept ended (errno=\(err))", category: .hlsServer)
                return
            }

            // Inherit SO_NOSIGPIPE from the listen socket on some
            // BSDs is unreliable; set it explicitly on the client.
            var on: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // 60s idle timeout on recv. Without this an AVPlayer
            // keep-alive connection that goes silent (because AVPlayer
            // opened a new one elsewhere) would park this worker
            // forever. AVPlayer's typical inter-request gap is
            // single-digit seconds, so 60s is comfortable headroom.
            var timeout = timeval(tv_sec: 60, tv_usec: 0)
            _ = setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            stateLock.lock()
            clientFds.insert(clientFd)
            stateLock.unlock()

            EngineLog.emit("[HLSLocalServer] conn opened fd=\(clientFd)", category: .hlsServer)

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
            EngineLog.emit("[HLSLocalServer] conn closed fd=\(fd)", category: .hlsServer)
        }

        // HTTP/1.1 keep-alive loop. AVPlayer reuses connections
        // for several segment fetches before opening a new one.
        while true {
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
                // Peer closed cleanly.
                if buffer.isEmpty { return nil }
                EngineLog.emit("[HLSLocalServer] peer EOF mid-request fd=\(fd)", category: .hlsServer)
                return nil
            }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK {
                    // SO_RCVTIMEO fired — connection idle too long.
                    EngineLog.emit("[HLSLocalServer] recv timeout fd=\(fd)", category: .hlsServer)
                    return nil
                }
                EngineLog.emit("[HLSLocalServer] recv error fd=\(fd) errno=\(err)", category: .hlsServer)
                return nil
            }
            buffer.append(chunk, count: n)

            // Look for the headers terminator.
            if let end = findHeadersTerminator(buffer) {
                return buffer.prefix(end + 4)
            }
            if buffer.count > 8192 {
                EngineLog.emit("[HLSLocalServer] request too large fd=\(fd) bytes=\(buffer.count)", category: .hlsServer)
                return nil
            }
        }
    }

    /// Returns the offset of `\r\n\r\n` in `buf`, or nil if not present.
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

    /// Parse + dispatch one request. Returns false to close the
    /// connection (e.g. send error), true to keep keep-alive going.
    private func processRequest(_ request: Data, on fd: Int32) -> Bool {
        guard let text = String(data: request, encoding: .utf8) else {
            EngineLog.emit("[HLSLocalServer] non-UTF8 request bytes (\(request.count)B)", category: .hlsServer)
            return false
        }
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            EngineLog.emit("[HLSLocalServer] malformed request line: '\(firstLine)'", category: .hlsServer)
            return false
        }
        let path = String(parts[1])
        // The audio path historically used /audio.m3u8 as the media
        // playlist URL. Keep accepting it as an alias.
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
                    EngineLog.emit("[HLSLocalServer] master.m3u8 body:\n\(body)", category: .hlsServer)
                }
                return send200(fd: fd, path: normalizedPath, data: Data(body.utf8), contentType: "application/vnd.apple.mpegurl")
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
                EngineLog.emit("[HLSLocalServer] media.m3u8 head:\n\(head)", category: .hlsServer)
            }
            return send200(fd: fd, path: normalizedPath, data: Data(body.utf8), contentType: "application/vnd.apple.mpegurl")

        case "/init.mp4":
            let data = provider?.initSegment() ?? Data()
            if data.isEmpty {
                return send404(fd: fd, path: normalizedPath, reason: "init.mp4 empty (provider not ready?)")
            }
            return send200(fd: fd, path: normalizedPath, data: data, contentType: "video/mp4")

        default:
            if normalizedPath.hasPrefix("/seg"), normalizedPath.hasSuffix(".mp4") {
                let indexStr = normalizedPath.dropFirst(4).dropLast(4)
                if let index = Int(indexStr), index >= 0 {
                    if index == 0 {
                        stateLock.lock()
                        if seg0FetchTime == nil { seg0FetchTime = Date() }
                        stateLock.unlock()
                    }
                    if let data = provider?.mediaSegment(at: index), !data.isEmpty {
                        return send200(fd: fd, path: normalizedPath, data: data, contentType: "video/mp4")
                    }
                    let providerCount = provider?.segmentCount ?? -1
                    return send404(fd: fd, path: normalizedPath, reason: "segment[\(index)] empty (segmentCount=\(providerCount))")
                }
                return send404(fd: fd, path: normalizedPath, reason: "unparseable seg index '\(indexStr)'")
            }
            return send404(fd: fd, path: normalizedPath, reason: "unknown path")
        }
    }

    // MARK: - HTTP framing

    private func send200(fd: Int32, path: String, data: Data, contentType: String) -> Bool {
        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n"
        var payload = Data(header.utf8)
        payload.append(data)

        EngineLog.emit("[HLSLocalServer] -> 200 \(path) bytes=\(data.count) type=\(contentType)", category: .hlsServer)

        return writeAll(fd: fd, data: payload, path: path)
    }

    private func send404(fd: Int32, path: String, reason: String) -> Bool {
        let response =
            "HTTP/1.1 404 Not Found\r\n" +
            "Content-Length: 0\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n"
        EngineLog.emit("[HLSLocalServer] -> 404 \(path) reason=\(reason)", category: .hlsServer)
        return writeAll(fd: fd, data: Data(response.utf8), path: path)
    }

    /// Blocking send loop. Returns false on broken pipe / error.
    private func writeAll(fd: Int32, data: Data, path: String) -> Bool {
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                let base = raw.baseAddress!.advanced(by: written)
                return send(fd, base, data.count - written, 0)
            }
            if result < 0 {
                let err = errno
                if err == EINTR { continue }
                EngineLog.emit("[HLSLocalServer] send failed for \(path): errno=\(err)", category: .hlsServer)
                return false
            }
            if result == 0 {
                EngineLog.emit("[HLSLocalServer] send returned 0 for \(path)", category: .hlsServer)
                return false
            }
            written += result
        }
        return true
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
        let count = provider.segmentCount

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
        switch provider.playlistType {
        case .vod:   lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        case .event: lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
        }
        lines.append("#EXT-X-MAP:URI=\"init.mp4\"")
        for i in 0..<count {
            let dur = provider.segmentDuration(at: i)
            lines.append("#EXTINF:\(String(format: "%.3f", dur)),")
            lines.append("seg\(i).mp4")
        }
        if provider.playlistType == .vod {
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
        case .socketCreate(let e): return "HLSLocalServer: socket() failed errno=\(e)"
        case .bind(let e):         return "HLSLocalServer: bind() failed errno=\(e)"
        case .listen(let e):       return "HLSLocalServer: listen() failed errno=\(e)"
        case .getsockname(let e):  return "HLSLocalServer: getsockname() failed errno=\(e)"
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

    // HLSSegmentProvider conformance

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
