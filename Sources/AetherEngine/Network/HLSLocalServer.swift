import Darwin
import Foundation

// MARK: - Segment Provider Protocol

/// Source of HLS segment bytes for HLSLocalServer. Production implementation synthesizes segments lazily on AVPlayer fetch (2h 4K at 6s/10MB would otherwise require ~120 GB resident).
protocol HLSSegmentProvider: AnyObject {
    /// ftyp+moov init segment bytes. Nil until muxer produces one (live-audio bring-up).
    func initSegment() -> Data?

    /// Media segment bytes (0-based index). Nil if not yet available or out of range; server returns 404 for nil.
    func mediaSegment(at index: Int) -> Data?

    /// Optional file URL for disk-backed segments (cache adopt path). Server streams file -> socket bypassing Foundation Data; sendfile(2) was tried but SIGSYS'd on tvOS sandbox.
    func mediaSegmentURL(at index: Int) -> URL?

    var segmentCount: Int { get }
    func segmentDuration(at index: Int) -> Double

    /// True when segment i opens at a live PTS discontinuity; playlist builder prefixes #EXT-X-DISCONTINUITY so AVPlayer keeps its timeline continuous.
    func segmentIsDiscontinuous(at index: Int) -> Bool

    /// Init version a segment decodes against. 0 = session init; higher = SSAI program switch (ad creative changed codec params); playlist emits new EXT-X-MAP on change.
    func initVersionID(forSegment index: Int) -> Int

    func initSegment(versionID: Int) -> Data?

    var playlistType: HLSPlaylistType { get }

    /// Live cut-target seconds; playlist builder uses it as a TARGETDURATION floor so the first manifest (before seg0) doesn't yield TD=1 and -12888 on high-bitrate sources. Nil for VOD/EVENT.
    var liveTargetSegmentDuration: Double? { get }

    /// False for bursty ingest sources that can't honor the LL-HLS blocking-reload contract (held reloads only resolve on the next upstream batch; -15410).
    var liveBlockingReloadEnabled: Bool { get }

    /// Real upstream arrival cadence for bursty sources; raises TARGETDURATION so AVPlayer's 1.5x patience covers the inter-batch gap.
    var liveTargetDurationFloorSeconds: Double? { get }

    /// Master-playlist metadata. When masterCodecs is non-nil the server publishes master.m3u8; nil means media-playlist-only.
    var masterCodecs: String? { get }
    var masterResolution: (width: Int, height: Int)? { get }
    var masterVideoRange: HLSVideoRange? { get }
    var masterBandwidth: Int? { get }

    /// SUPPLEMENTAL-CODECS on EXT-X-STREAM-INF. DV P8.1 = "dvh1.08.LL/db1p", P8.4 = "dvh1.08.LL/db4h"; P5 is nil (dvh1.05.LL goes in primary CODECS). AVPlayer's master-level codec filter silently drops variants whose primary CODECS it can't fall back to; bare dvh1 master stalled at fetch 2-3 without advancing to media.m3u8.
    var masterSupplementalCodecs: String? { get }

    var masterFrameRate: Double? { get }
    var masterAverageBandwidth: Int? { get }
    /// HDCP-LEVEL TYPE-1 required for resolutions >1920x1080 in HDR/DV (Apple Tech Talk 501).
    var masterHDCPLevel: String? { get }
    var masterClosedCaptions: String? { get }

    /// Native subtitle renditions (#15): one per text track, for the master EXT-X-MEDIA:TYPE=SUBTITLES tags
    /// and the /subs_{N} endpoints. Empty unless prepareNativeSubtitles is on and the cue stores are threaded.
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String)] { get }
    /// WebVTT body for the native subtitle ordinal (whole program), or nil if out of range.
    func nativeSubtitleVTT(ordinal: Int) -> String?
    /// Program duration (seconds) for the ordinal's VOD subtitle media playlist EXTINF/TARGETDURATION.
    func nativeSubtitleProgramDuration(ordinal: Int) -> Double

    /// Atomic snapshot at the top of each playlist build. discontinuitySequence = EXT-X-DISCONTINUITY-tagged segments that slid out of the window (RFC 8216 §6.2.2 requires incrementing it; omission slips AVPlayer's discontinuity tracking one window per boundary). firstVisible in the same snapshot: a separate lock acquisition let a concurrent slide produce MEDIA-SEQUENCE newer than the count.
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int)

    /// Index of the first segment visible in the current window (0 for VOD/EVENT; advances for live). Use notePlaylistBuild for playlist construction; this is for diagnostics.
    var firstVisibleSegmentIndex: Int { get }

    /// Block until at least one live segment is ready or timeout elapses. Holds the first live response so AVPlayer never sees an empty playlist (-12888).
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool

    /// LL-HLS blocking reload: block until segment at absolute index exists. Holds AVPlayer's ?_HLS_msn= reload open so it receives the new segment the instant it is cut, not a poll-interval late.
    func waitForLiveSegment(index: Int, timeout: TimeInterval) -> Bool
}

extension HLSSegmentProvider {
    func mediaSegmentURL(at index: Int) -> URL? { nil }
    var firstVisibleSegmentIndex: Int { 0 }
    func segmentIsDiscontinuous(at index: Int) -> Bool { false }
    func initVersionID(forSegment index: Int) -> Int { 0 }
    func initSegment(versionID: Int) -> Data? { versionID == 0 ? initSegment() : nil }
    var masterCodecs: String? { nil }
    var masterResolution: (width: Int, height: Int)? { nil }
    var masterVideoRange: HLSVideoRange? { nil }
    var masterBandwidth: Int? { nil }
    var masterSupplementalCodecs: String? { nil }
    var masterFrameRate: Double? { nil }
    var masterAverageBandwidth: Int? { nil }
    var masterHDCPLevel: String? { nil }
    var masterClosedCaptions: String? { nil }
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String)] { [] }
    func nativeSubtitleVTT(ordinal: Int) -> String? { nil }
    func nativeSubtitleProgramDuration(ordinal: Int) -> Double { 1.0 }
    var liveTargetSegmentDuration: Double? { nil }
    var liveBlockingReloadEnabled: Bool { true }
    var liveTargetDurationFloorSeconds: Double? { nil }
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool { true }
    func waitForLiveSegment(index: Int, timeout: TimeInterval) -> Bool { true }
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        return (visibleCount: segmentCount, firstVisible: 0, refreshCounter: 0, endlistAdded: false, discontinuitySequence: 0)
    }
}

enum HLSPlaylistType: Equatable {
    /// EXT-X-PLAYLIST-TYPE:EVENT, no ENDLIST. Append-only; segments never removed (audio-append path). NOT for sliding live (EVENT forbids removal).
    case event
    /// EXT-X-PLAYLIST-TYPE:VOD, ENDLIST present. Finite-duration video files.
    case vod
    /// No PLAYLIST-TYPE tag, no ENDLIST; MEDIA-SEQUENCE advances as old segments fall off (RFC 8216 §4.3.3.5: EVENT forbids removal, VOD implies finished; sliding window must omit the tag).
    case live
}

enum HLSVideoRange: String {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
}

// MARK: - Local HLS Server

/// Loopback HTTP/BSD-socket server feeding HLS-fMP4 to AVPlayer. Uses Darwin BSD sockets, not NWConnection: NWConnection's send path retained segment bytes across contentProcessed causing ~3 MB/sec RSS growth on 4K HEVC (AetherEngine#4). BSD + mmap-backed Data gives kernel-to-kernel copy with zero heap allocation per segment.
///
/// Endpoints: /master.m3u8 (when provider has master metadata; required for DV VIDEO-RANGE=PQ on EXT-X-STREAM-INF), /media.m3u8, /init.mp4, /seg{N}.mp4. Threading: one acceptQueue loop, concurrent workQueue handlers with blocking recv/send. Listens on 127.0.0.1; IP literal avoids DNS resolver dependency.
final class HLSLocalServer: @unchecked Sendable {

    // MARK: - Provider

    private weak var provider: HLSSegmentProvider?

    // MARK: - Public state

    /// Kernel-assigned ephemeral port. Zero until start() succeeds.
    private(set) var port: UInt16 = 0

    /// URL passed to AVPlayer. Points at master.m3u8 when the provider has master metadata, else media.m3u8.
    var playlistURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard port > 0 else { return nil }
        let path = (provider?.masterCodecs != nil) ? "master.m3u8" : "media.m3u8"
        return URL(string: "http://127.0.0.1:\(port)/\(path)")
    }

    /// Direct media.m3u8 URL, bypassing master-playlist variant selection (used when the DV/HDR handshake is unavailable so AVPlayer doesn't try to match a dvh1 master on an SDR panel).
    var mediaPlaylistURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/media.m3u8")
    }

    /// The device's active LAN IPv4 address for the AirPlay LAN-host swap (#86), or nil (caller keeps
    /// 127.0.0.1). DrHurt's caveat: en0 isn't always the active interface on multi-NIC / Ethernet devices.
    /// We scan `en*` interfaces (WiFi + wired Ethernet/Thunderbolt; cellular pdp_ip*, VPN utun*, AirDrop awdl*
    /// are excluded by the prefix) and prefer en0 (WiFi on Apple devices), falling back to the lowest-numbered
    /// wired en* otherwise. Synchronous getifaddrs (NWPathMonitor is async and would stall the reload path);
    /// the rare both-WiFi-and-Ethernet case picks WiFi, which is the usual AirPlay route.
    static func localActiveIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var byInterface: [String: String] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                byInterface[name] = String(cString: host)
            }
        }
        if let wifi = byInterface["en0"] { return wifi }
        return byInterface.keys.sorted().compactMap { byInterface[$0] }.first
    }

    /// Number of segments currently published.
    var segmentCount: Int {
        provider?.segmentCount ?? 0
    }

    // MARK: - Private state

    private var listenFd: Int32 = -1
    private var shouldStop = false
    private var clientFds = Set<Int32>()

    /// Active connection count; engine memory probe watches for unexpectedly rising accumulation (AVPlayer normally holds 1-3 connections).
    var activeConnectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return clientFds.count
    }

    /// Lifetime bytes sent (all responses). Compared against muxer's muxBytesMB in the engine memprobe to confirm no duplicate sends or dropped bytes.
    private let byteCounterLock = NSLock()
    private var _lifetimeBytesSent: Int = 0
    var lifetimeBytesSent: Int {
        byteCounterLock.lock()
        defer { byteCounterLock.unlock() }
        return _lifetimeBytesSent
    }
    private var _requestCount: Int = 0
    var requestCount: Int {
        byteCounterLock.lock()
        defer { byteCounterLock.unlock() }
        return _requestCount
    }
    private func bumpBytesSent(_ n: Int) {
        guard n > 0 else { return }
        byteCounterLock.lock()
        _lifetimeBytesSent &+= n
        byteCounterLock.unlock()
    }

    /// Lifetime bytes sent via the file-streaming fast path (file -> socket, no Swift Data). Used to verify the fast path is taken.
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

    private var loggedMasterPlaylist = false
    private var loggedMediaPlaylist = false
    private var loggedRequestHeaders = false
    private var mediaPlaylistBuildCount = 0  // periodic re-log of live playlist head/tail

    private let stateLock = NSLock()  // guards all mutable fields; never held across blocking syscalls

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

    /// When set (e.g. `aether-engine://engine/`), segment URIs in the playlist are absolute custom-scheme URLs routed through AVAssetResourceLoader. Nil emits relative URIs for the aetherctl HTTP workflow.
    private let subResourceBaseURL: URL?

    init(provider: HLSSegmentProvider, subResourceBaseURL: URL? = nil) {
        self.provider = provider
        self.subResourceBaseURL = subResourceBaseURL
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
        // Bind all interfaces (not just loopback) so an AirPlay receiver can reach the stream over the LAN
        // via the device's WiFi IP (#86, DrHurt). Local playback still uses 127.0.0.1; the URL host is only
        // swapped to the LAN IP while external playback is active. Ephemeral port, serves the current stream only.
        addr.sin_addr.s_addr = inet_addr("0.0.0.0")

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
        mediaPlaylistBuildCount = 0
        let clients = clientFds
        clientFds.removeAll()
        stateLock.unlock()

        // shutdown() BEFORE close() on the listen fd: close releases the fd number while the accept loop may have captured it; a new session could recycle that number and the dying loop would accept on the new session's socket. shutdown() wakes the blocked accept without releasing the number.
        if fdToClose >= 0 {
            shutdown(fdToClose, SHUT_RDWR)
            close(fdToClose)
        }
        // shutdown() (NOT close) client fds: close would release the fd number while the handler still owns it; a channel-zap reuses that number immediately on the process-wide singleton engine, so the handler's late send()/deferred close() would hit the new session's descriptor.
        for fd in clients {
            shutdown(fd, SHUT_RDWR)
        }
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
                // EINTR / EAGAIN: spurious wakeup, retry. ECONNABORTED:
                // a backlogged connection was torn down before accept
                // picked it up (normal during stop()); retry quietly, the
                // loop-top stop check exits if we're shutting down.
                if err == EINTR || err == EAGAIN || err == ECONNABORTED {
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
                           category: .hlsServer, level: .verbose)

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
                           category: .hlsServer, level: .verbose)
        }

        // HTTP/1.1 keep-alive loop: AVPlayer reuses connections across segment fetches. Connection:close per-request tried 2026-05-20; Instruments showed it shifted the leak from libnetwork into a 570 MiB Malloc heap bucket instead (strictly worse; reverted).
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
        byteCounterLock.lock()
        _requestCount &+= 1
        byteCounterLock.unlock()
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
        let rawTarget = String(parts[1])
        // Split path + query: AVPlayer appends ?_HLS_msn=N for LL-HLS blocking reloads; route match on path alone.
        let path: String
        let query: String
        if let q = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<q])
            query = String(rawTarget[rawTarget.index(after: q)...])
        } else {
            path = rawTarget
            query = ""
        }
        let normalizedPath = (path == "/audio.m3u8") ? "/media.m3u8" : path

        // #50 diag: promoted to .info so the host mirror names the failing path without a verbose build. Revert once #50 is root-caused.
        EngineLog.emit("[HLSLocalServer] \(firstLine)", category: .hlsServer)
        // Dump request headers once per session; AVPlayer capability headers (Accept, Range, X-Playback-Session-Id) can influence silent variant rejection.
        stateLock.lock()
        let dumpHeaders = !loggedRequestHeaders
        if dumpHeaders { loggedRequestHeaders = true }
        stateLock.unlock()
        if dumpHeaders {
            let allLines = text.components(separatedBy: "\r\n")
            let headers = allLines.dropFirst().prefix(while: { !$0.isEmpty }).joined(separator: " | ")
            // #50 diag: once-per-session, promoted to .info to surface any
            // Range / capability header that explains the 404. Revert with the
            // arrival-line promotion above once #50 is root-caused.
            EngineLog.emit("[HLSLocalServer] first request headers fd=\(fd): \(headers)", category: .hlsServer)  // #50 diag: .info, revert post-root-cause
        }

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
            // For live: hold until at least one segment exists (-12888 fires immediately on empty live playlist; AVPlayer never re-polls).
            if let p = provider, p.playlistType == .live {
                if let msn = Self.parseHLSMsn(query) {
                    // LL-HLS blocking reload: hold until segment msn is cut so AVPlayer receives it the instant it exists, not a reload-interval late. Gated on liveBlockingReloadEnabled: bursty ingest sources can't honor the contract and withheld it.
                    if p.liveBlockingReloadEnabled {
                        _ = p.waitForLiveSegment(index: msn, timeout: 18.0)
                    }
                } else {
                    _ = p.waitForFirstLiveSegment(timeout: 30.0)
                }
            }
            let body = buildMediaPlaylist()
            stateLock.lock()
            let firstTime = !loggedMediaPlaylist
            if firstTime { loggedMediaPlaylist = true }
            mediaPlaylistBuildCount += 1
            let isLivePlaylist = (provider?.playlistType == .live)
            let periodic = isLivePlaylist && (mediaPlaylistBuildCount % 10 == 0)
            stateLock.unlock()
            if firstTime || periodic {
                let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
                let head = lines.prefix(8).joined(separator: "\n")
                let tail = lines.suffix(6).joined(separator: "\n")
                EngineLog.emit("[HLSLocalServer] media.m3u8 head:\n\(head)",
                               category: .hlsServer, level: .verbose)
                EngineLog.emit("[HLSLocalServer] media.m3u8 tail:\n\(tail)",
                               category: .hlsServer, level: .verbose)
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
            // Versioned init for SSAI program switches: /init<N>.mp4 (N>0).
            if normalizedPath.hasPrefix("/init"),
               normalizedPath.hasSuffix(".mp4") {
                let vStr = normalizedPath.dropFirst("/init".count).dropLast(".mp4".count)
                if let v = Int(vStr), v > 0 {
                    let data = provider?.initSegment(versionID: v) ?? Data()
                    if data.isEmpty {
                        return send404(fd: fd, path: normalizedPath,
                                       reason: "init\(v).mp4 not available")
                    }
                    return send200(fd: fd, path: normalizedPath, data: data,
                                   contentType: "video/mp4")
                }
            }
            if normalizedPath.hasPrefix("/seg"),
               normalizedPath.hasSuffix(".mp4") {
                let indexStr = normalizedPath.dropFirst(4).dropLast(4)
                if let index = Int(indexStr), index >= 0 {
                    // File-backed fast path: stream page cache -> socket without Data materialization.
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
                    let reason = "segment[\(index)] empty (segmentCount=\(providerCount))"
                    switch Self.classifySegmentResponse(
                        index: index, segmentCount: providerCount, hasData: false) {
                    case .serve:
                        // Unreachable: hasData is false here.
                        return send404(fd: fd, path: normalizedPath, reason: reason)
                    case .retryLater:
                        return send503(fd: fd, path: normalizedPath, reason: reason)
                    case .notFound:
                        return send404(fd: fd, path: normalizedPath, reason: reason)
                    }
                }
                return send404(fd: fd, path: normalizedPath,
                               reason: "unparseable seg index '\(indexStr)'")
            }
            return send404(fd: fd, path: normalizedPath, reason: "unknown path")
        }
    }

    // MARK: - HTTP framing

    /// Shared response-header builder. Header and body are sent in two separate send() calls: data may be mmap-backed and must NOT be copied via Data.append (would materialize segment into Swift heap, defeating the BSD-socket rewrite).
    private static func responseHeader(
        status: String, contentLength: Int, contentType: String?
    ) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        if let contentType {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "Content-Length: \(contentLength)\r\n"
        if contentType != nil {
            header += "Access-Control-Allow-Origin: *\r\n"
            header += "Cache-Control: no-cache\r\n"
        }
        header += "Connection: keep-alive\r\n\r\n"
        return Data(header.utf8)
    }

    private func send200(fd: Int32, path: String, data: Data, contentType: String) -> Bool {
        let headerData = Self.responseHeader(status: "200 OK", contentLength: data.count, contentType: contentType)

        EngineLog.emit("[HLSLocalServer] -> 200 \(path) bytes=\(data.count) type=\(contentType)",
                       category: .hlsServer, level: .verbose)

        guard writeAll(fd: fd, data: headerData, path: "\(path) [header]") else {
            return false
        }
        return writeAll(fd: fd, data: data, path: path)
    }

    private func send200File(fd: Int32, path: String, fileURL: URL, contentType: String) -> Bool {
        let fsAttrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (fsAttrs?[.size] as? Int) ?? 0
        if fileSize == 0 {
            return send404(fd: fd, path: path, reason: "file \(fileURL.lastPathComponent) missing or empty")
        }

        let headerData = Self.responseHeader(status: "200 OK", contentLength: fileSize, contentType: contentType)

        EngineLog.emit("[HLSLocalServer] -> 200 \(path) bytes=\(fileSize) type=\(contentType) [filestream]",
                       category: .hlsServer, level: .verbose)

        guard writeAll(fd: fd, data: headerData, path: "\(path) [header]") else {
            return false
        }
        return streamFileToSocket(fileURL: fileURL, socketFd: fd, path: path,
                           expectedLength: fileSize)
    }

    private func send404(fd: Int32, path: String, reason: String) -> Bool {
        let response = Self.responseHeader(status: "404 Not Found", contentLength: 0, contentType: nil)
        EngineLog.emit("[HLSLocalServer] -> 404 \(path) reason=\(reason)",
                       category: .hlsServer)
        return writeAll(fd: fd, data: response, path: path)
    }

    /// 503 for an in-range segment not yet produced (#50). AVPlayer treats a 404 on a VOD segment as terminal loadFailed; 503+Retry-After keeps it recoverable so VideoSegmentProvider.serveSegment can nudge the producer back.
    private func send503(fd: Int32, path: String, reason: String) -> Bool {
        var header = "HTTP/1.1 503 Service Unavailable\r\n"
        header += "Content-Length: 0\r\n"
        header += "Retry-After: 1\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: keep-alive\r\n\r\n"
        EngineLog.emit("[HLSLocalServer] -> 503 \(path) reason=\(reason)",
                       category: .hlsServer)
        return writeAll(fd: fd, data: Data(header.utf8), path: path)
    }

    /// How to answer a `/seg{N}.mp4` request, given whether the provider
    /// produced bytes and the currently advertised segment count. Pure so
    /// the #50 in-range-is-never-404 rule is unit-testable without sockets.
    enum SegmentResponseKind: Equatable {
        /// Bytes are in hand; serve 200.
        case serve
        /// In-range (0 ..< segmentCount) but not produced yet; serve a
        /// retriable 503, never a 404.
        case retryLater
        /// Index is out of range (past the advertised count) or the count
        /// is unknown; a genuine 404.
        case notFound
    }

    static func classifySegmentResponse(index: Int, segmentCount: Int, hasData: Bool) -> SegmentResponseKind {
        if hasData { return .serve }
        if index >= 0, segmentCount > 0, index < segmentCount { return .retryLater }
        return .notFound
    }

    /// Blocking send loop. Uses withUnsafeBytes so mmap-backed Data stays mmap-backed (kernel page-faults in only the bytes copied to the socket send buffer, no heap accumulation).
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

    /// Chunked file -> socket stream (256 KB buffer). sendfile(2) tried first but is SIGSYS'd by tvOS sandbox; reverted to read+send. expectedLength must match Content-Length exactly: a file that grew or shrank between stat and read would shift HTTP framing on the keep-alive connection. Short file fails the response (closes connection) rather than leaving the client waiting.
    private func streamFileToSocket(fileURL: URL, socketFd: Int32, path: String,
                             expectedLength: Int) -> Bool {
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
            if totalSent >= expectedLength {
                // File grew after stat; do not send excess bytes.
                bumpBytesSent(totalSent)
                bumpSendfileBytes(totalSent)
                return true
            }
            let want = min(chunkSize, expectedLength - totalSent)
            let nRead = read(fileFd, buffer, want)
            if nRead == 0 {
                // File shrank after stat; fail to avoid framing desync.
                EngineLog.emit(
                    "[HLSLocalServer] short file \(path): sent=\(totalSent) expected=\(expectedLength)",
                    category: .hlsServer
                )
                return false
            }
            if nRead < 0 {
                let err = errno
                if err == EINTR { continue }
                EngineLog.emit("[HLSLocalServer] file read failed \(path): errno=\(err) sent=\(totalSent)",
                               category: .hlsServer)
                return false
            }
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
        guard let provider = provider else { return "#EXTM3U\n" }
        return Self.buildMasterPlaylistText(provider: provider,
                                             subResourceBaseURL: subResourceBaseURL)
    }

    private func buildMediaPlaylist() -> String {
        guard let provider = provider else { return "#EXTM3U\n" }
        return Self.buildMediaPlaylistText(provider: provider,
                                            subResourceBaseURL: subResourceBaseURL)
    }

    /// Parse ?_HLS_msn=N from the request query. _HLS_part ignored (segment-level blocking only, no partial segments). Returns nil for absent or unparseable (treated as plain reload).
    static func parseHLSMsn(_ query: String) -> Int? {
        guard !query.isEmpty else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "_HLS_msn", let n = Int(kv[1]), n >= 0 {
                return n
            }
        }
        return nil
    }

    /// Pure playlist builders callable without a live server instance. subResourceBaseURL emits absolute URIs for AVAssetResourceLoader; nil emits relative URIs for the HTTP workflow.
    static func buildMasterPlaylistText(provider: HLSSegmentProvider,
                                         subResourceBaseURL: URL? = nil) -> String {
        guard let codecs = provider.masterCodecs else {
            return "#EXTM3U\n"
        }
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")

        // EXT-X-STREAM-INF attribute order per Apple's HLS Authoring Spec Appendixes: BANDWIDTH, AVERAGE-BANDWIDTH, CODECS, SUPPLEMENTAL-CODECS, RESOLUTION/FRAME-RATE/VIDEO-RANGE, HDCP-LEVEL/CLOSED-CAPTIONS.
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

    static func buildMediaPlaylistText(provider: HLSSegmentProvider,
                                        subResourceBaseURL: URL? = nil) -> String {
        // Atomic snapshot from notePlaylistBuild(); a separate lock acquisition for visibleCount vs firstVisible let a concurrent window slide produce a trapping range.
        let snapshot = provider.notePlaylistBuild()
        let count = snapshot.visibleCount
        let firstVisible = min(snapshot.firstVisible, count)
        let typeIsEvent = (provider.playlistType == .event && !snapshot.endlistAdded)
        // Sliding live: no PLAYLIST-TYPE tag and no ENDLIST (EVENT forbids removal; VOD implies finished asset).
        let typeIsLive = (provider.playlistType == .live && !snapshot.endlistAdded)

        // TARGETDURATION must be >= every EXTINF (HLS spec).
        var maxDuration: Double = 0
        for i in firstVisible..<count {
            maxDuration = max(maxDuration, provider.segmentDuration(at: i))
        }
        var targetDuration = Int(ceil(max(1.0, maxDuration)))

        // Live TARGETDURATION floor = ceil(1.5 * cutTarget). Fixes two problems: (1) empty first manifest (maxDuration=0 -> TD=1, AVPlayer gets only 1.5s patience, -12888 on high-bitrate sources); (2) transcode warm-up ~8s stall at startup (-12888 once before recovery). Advertising a generous TD widens AVPlayer's unchanged-playlist patience at no startup-latency cost; EXTINF stays at cutTarget, reload cadence unchanged.
        if typeIsLive, let liveTarget = provider.liveTargetSegmentDuration {
            let liveFloor = Int(ceil(liveTarget * 1.5))
            targetDuration = max(targetDuration, liveFloor)
        }

        // Bursty ingest: raise TD to the real upstream arrival cadence so AVPlayer's unchanged-playlist patience (1.5x TD) covers the inter-batch gap. Pairs with liveBlockingReloadEnabled=false.
        if typeIsLive, let cadenceFloor = provider.liveTargetDurationFloorSeconds {
            targetDuration = max(targetDuration, Int(ceil(cadenceFloor)))
        }

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        if typeIsLive {
            // CAN-BLOCK-RELOAD: AVPlayer sends ?_HLS_msn=N and the server holds the response until that segment is cut (see waitForLiveSegment), so AVPlayer gets each segment the instant it exists instead of a poll-interval late. Segment-level only (no EXT-X-PART). Gated on liveBlockingReloadEnabled: bursty sources can't honor the contract (-15410 and periodic stalls on device repro 2026-06-11); they fall back to plain reloads with a raised TARGETDURATION.
            if provider.liveBlockingReloadEnabled {
                lines.append("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES")
            }
        }
        lines.append("#EXT-X-TARGETDURATION:\(targetDuration)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(firstVisible)")
        if typeIsLive {
            // RFC 8216 §6.2.2: EXT-X-DISCONTINUITY-SEQUENCE must advance when discontinuity-tagged segments slide out of the window; omitting it shifts AVPlayer's discontinuity numbering one window after each program boundary.
            lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(snapshot.discontinuitySequence)")
        }
        if typeIsLive {
            // Refresh counter keeps consecutive polls distinct so AVPlayer's unchanged-playlist patience (-12888) doesn't fire on a quiet window.
            lines.append("#EXT-X-SODALITE-REFRESH:\(snapshot.refreshCounter)")
        } else if typeIsEvent {
            lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
            lines.append("#EXT-X-SODALITE-REFRESH:\(snapshot.refreshCounter)")
        } else {
            // EXT-X-PLAYLIST-TYPE:VOD lets AVPlayer prune fetched segments past the buffer-behind window; without it RSS grows linearly with segment count for the whole playback.
            lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        }
        // Absolute custom-scheme URIs route sub-resources through AVAssetResourceLoader; relative URIs go through CFNetwork (aetherctl workflow).
        let initURI: (Int) -> String
        let segURI: (Int) -> String
        if let base = subResourceBaseURL {
            let baseStr = base.absoluteString
            let baseWithSlash = baseStr.hasSuffix("/") ? baseStr : baseStr + "/"
            initURI = { v in v == 0 ? "\(baseWithSlash)init.mp4" : "\(baseWithSlash)init\(v).mp4" }
            segURI = { idx in "\(baseWithSlash)seg\(idx).mp4" }
        } else {
            initURI = { v in v == 0 ? "init.mp4" : "init\(v).mp4" }
            segURI = { idx in "seg\(idx).mp4" }
        }
        // Initial EXT-X-MAP emitted before the loop so a discontinuity on seg0 is still directly before its #EXTINF (RFC/Apple: session map precedes first segment's tags).
        var lastInitVersion = provider.initVersionID(forSegment: firstVisible)
        lines.append("#EXT-X-MAP:URI=\"\(initURI(lastInitVersion))\"")
        for i in firstVisible..<count {
            if provider.segmentIsDiscontinuous(at: i) {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            // SSAI mid-stream init change: emit new EXT-X-MAP after discontinuity, before #EXTINF (verified order AVPlayer accepts for mid-stream init + resolution change).
            let v = provider.initVersionID(forSegment: i)
            if v != lastInitVersion {
                lines.append("#EXT-X-MAP:URI=\"\(initURI(v))\"")
                lastInitVersion = v
            }
            let dur = provider.segmentDuration(at: i)
            lines.append("#EXTINF:\(String(format: "%.3f", dur)),")
            lines.append(segURI(i))
        }
        // ENDLIST for VOD/completed EVENT; never for a sliding live playlist (AVPlayer must keep re-polling).
        if !typeIsLive && (snapshot.endlistAdded || !typeIsEvent) {
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

