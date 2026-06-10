import Darwin
import Foundation

// MARK: - Segment Provider Protocol

/// Source of HLS segment bytes for `HLSLocalServer`.
///
/// The production implementation is the video path's lazy on-demand
/// provider that synthesises each segment when AVPlayer fetches it,
/// never holding more than one or two in memory at a time. Necessary
/// because a 2h 4K video at 6 s / 10 MB segments would otherwise
/// require ~120 GB of resident memory.
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
    /// providers that hold segments only in memory or when the segment
    /// isn't yet available. Lets the server bypass Foundation's
    /// `Data(contentsOf:)` entirely and stream the file straight to
    /// the socket via `sendfile(2)`.
    func mediaSegmentURL(at index: Int) -> URL?

    /// Number of segments currently known. May grow over time for
    /// `.event` playlists, fixed for `.vod` playlists.
    var segmentCount: Int { get }

    /// Duration in seconds of segment `index`. May vary per segment
    /// when boundaries snap to source keyframes (the video case);
    /// returns the same value for every index in the audio case.
    func segmentDuration(at index: Int) -> Double

    /// Whether segment `index` opens at a live PTS discontinuity (a
    /// program boundary where the source clock leapt). When true the
    /// playlist builder prefixes the segment's `#EXTINF` with
    /// `#EXT-X-DISCONTINUITY`, which tells AVPlayer to keep its own
    /// timeline continuous across the jump. Always false for VOD and the
    /// audio-append path.
    func segmentIsDiscontinuous(at index: Int) -> Bool

    /// Apple HLS playlist type. `.event` for live appended audio,
    /// `.vod` for the fully-known video case.
    var playlistType: HLSPlaylistType { get }

    /// Target segment duration in seconds as configured for the live
    /// producer (e.g. 4-6 s). Non-nil only for `.live` providers. The
    /// playlist builder uses this as a stable floor for
    /// `#EXT-X-TARGETDURATION` so the very first manifest (before any
    /// segment is finalized) already declares a generous value instead of
    /// falling back to `max(1, 0) == 1`, which gives AVPlayer only 1.5 s
    /// to receive segment 0 and triggers CoreMediaErrorDomain -12888 for
    /// high-bitrate sources. VOD and EVENT providers return nil and keep
    /// the existing `ceil(maxProducedDuration)` computation unchanged.
    var liveTargetSegmentDuration: Double? { get }

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
    /// `#EXT-X-ENDLIST`. Used by the video provider to advance a
    /// sliding-window live playlist. `discontinuitySequence` is the
    /// number of `#EXT-X-DISCONTINUITY`-tagged segments that have slid
    /// OUT of the visible window, emitted as
    /// `#EXT-X-DISCONTINUITY-SEQUENCE` (RFC 8216 §6.2.2 REQUIRES the
    /// server to increment it when a discontinuity-tagged segment is
    /// removed; without it AVPlayer's discontinuity tracking slips one
    /// window-length after every program boundary).
    func notePlaylistBuild() -> (visibleCount: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int)

    /// First segment index visible in the current playlist window.
    /// For append-only and VOD playlists this is always 0.
    /// For a live session this advances as old segments
    /// fall off the back. Used by `buildMediaPlaylistText` to emit
    /// `#EXT-X-MEDIA-SEQUENCE` and to list only [firstVisible, visibleCount).
    var firstVisibleSegmentIndex: Int { get }

    /// Blocks the calling thread until this provider has at least one
    /// segment ready, or until `timeout` seconds elapse, whichever
    /// comes first. Returns `true` if at least one segment is available,
    /// `false` on timeout. Used by the server's manifest handler to hold
    /// the first live response until there is meaningful content, preventing
    /// CoreMediaErrorDomain -12888 on empty live playlists.
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool

    /// LL-HLS blocking playlist reload. Blocks the calling thread until a
    /// segment with absolute index `index` (the requested Media Sequence
    /// Number) exists, or until `timeout` seconds elapse. Returns `true`
    /// once the segment is available, `false` on timeout. Lets the server
    /// hold AVPlayer's `_HLS_msn` reload open and answer the instant the
    /// next segment is cut, instead of AVPlayer polling on its own fixed
    /// cadence and discovering fresh segments a reload-interval late (the
    /// residual live startup pause). Non-live providers return immediately.
    func waitForLiveSegment(index: Int, timeout: TimeInterval) -> Bool
}

extension HLSSegmentProvider {
    /// Default: no file backing. Providers that store segments on
    /// disk override to return the file URL so the server can use
    /// the `sendfile(2)` fast path.
    func mediaSegmentURL(at index: Int) -> URL? { nil }

    /// Default: append-only / VOD playlists always start at segment 0.
    var firstVisibleSegmentIndex: Int { 0 }

    /// Default: no discontinuities. Only the live video provider tracks
    /// program-boundary segments; every other provider returns false.
    func segmentIsDiscontinuous(at index: Int) -> Bool { false }

    var masterCodecs: String? { nil }
    var masterResolution: (width: Int, height: Int)? { nil }
    var masterVideoRange: HLSVideoRange? { nil }
    var masterBandwidth: Int? { nil }
    var masterSupplementalCodecs: String? { nil }
    var masterFrameRate: Double? { nil }
    var masterAverageBandwidth: Int? { nil }
    var masterHDCPLevel: String? { nil }
    var masterClosedCaptions: String? { nil }
    /// Default: not a live provider; playlist builder uses the
    /// computed-from-segments path.
    var liveTargetSegmentDuration: Double? { nil }

    /// Blocks the calling thread until this provider has at least one
    /// segment ready, or until `timeout` seconds elapse, whichever
    /// comes first. Returns `true` if at least one segment is available,
    /// `false` on timeout. Non-live providers return `true` immediately
    /// (their segment list is fully known at init time). Used by the
    /// server's manifest handler to hold the first live response until
    /// there is meaningful content to give AVPlayer: an empty live
    /// manifest with zero `#EXTINF` entries causes AVPlayer to fire
    /// CoreMediaErrorDomain -12888 immediately, regardless of
    /// `#EXT-X-TARGETDURATION`, because the playlist "hasn't changed"
    /// by the time the first poll interval fires.
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool { true }

    /// Default: non-live providers have their full segment list at init,
    /// so any requested index is already available.
    func waitForLiveSegment(index: Int, timeout: TimeInterval) -> Bool { true }

    /// Default implementation for providers that don't run a
    /// sliding-window playlist. Reports the current segmentCount,
    /// a zero refresh counter (the byte-level change line is a
    /// video-side concern), and trusts the static playlistType to
    /// drive ENDLIST inclusion.
    func notePlaylistBuild() -> (visibleCount: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        return (visibleCount: segmentCount, refreshCounter: 0, endlistAdded: false, discontinuitySequence: 0)
    }
}

enum HLSPlaylistType: Equatable {
    /// Append-only playlist (`#EXT-X-PLAYLIST-TYPE:EVENT`, no ENDLIST).
    /// Segments are never removed and MEDIA-SEQUENCE stays 0. Used by the
    /// audio-append path. NOT used for the productized sliding live video
    /// path (EVENT forbids segment removal, which is exactly what a
    /// sliding live window must do).
    case event
    /// Complete asset (`#EXT-X-PLAYLIST-TYPE:VOD`, ENDLIST present). Used
    /// by finite-duration video files.
    case vod
    /// Sliding live playlist: no `#EXT-X-PLAYLIST-TYPE` tag at all and no
    /// `#EXT-X-ENDLIST`, with a `#EXT-X-MEDIA-SEQUENCE` that advances as
    /// old segments fall off the back of the window. This is the only
    /// spec-correct shape for a window that both grows at the live edge
    /// and drops consumed segments: EVENT forbids removal and VOD implies
    /// a finished asset, so a live sliding playlist must omit the tag
    /// (RFC 8216 §4.3.3.5). Used by the live video session.
    case live
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

    /// Provider set via `init(provider:)`. Held weakly; the producer
    /// owns its own lifetime and the server outlives it on teardown.
    private weak var externalProvider: HLSSegmentProvider?

    private var provider: HLSSegmentProvider? {
        externalProvider
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
    private var loggedRequestHeaders = false
    /// Count of /media.m3u8 builds. Used to periodically re-log the
    /// head/tail of a live sliding playlist so the advancing
    /// #EXT-X-MEDIA-SEQUENCE is observable over a run.
    private var mediaPlaylistBuildCount = 0

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

    /// Base URL for sub-resource URLs (init.mp4 / segXX.mp4) in the
    /// generated playlist. When set to e.g. `aether-engine://engine/`,
    /// the playlist emits absolute custom-scheme URLs that AVPlayer
    /// routes through the AVAssetResourceLoader delegate, bypassing
    /// CFNetwork entirely for the heavy segment payloads. When nil,
    /// the playlist emits relative URLs (`init.mp4`, `seg0.mp4`) which
    /// AVPlayer resolves against the playlist's own URL, used by the
    /// `aetherctl` CLI workflow where everything goes over HTTP.
    private let subResourceBaseURL: URL?

    init(provider: HLSSegmentProvider, subResourceBaseURL: URL? = nil) {
        self.externalProvider = provider
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
        mediaPlaylistBuildCount = 0
        let clients = clientFds
        clientFds.removeAll()
        seg0FetchTime = nil
        stateLock.unlock()

        // shutdown() the listen fd BEFORE close(): close alone releases
        // the fd number while the accept loop may already have captured
        // it for its next accept() call; a new session can recycle the
        // number in that window and the dying loop would accept on the
        // NEW session's listen socket, stealing one connection. shutdown
        // wakes the blocked accept without releasing the number; the
        // close after it then proceeds with the loop already unwinding.
        if fdToClose >= 0 {
            shutdown(fdToClose, SHUT_RDWR)
            close(fdToClose)
        }
        // shutdown() (NOT close) the active client fds to unblock
        // recv/send. close() here would release the fd NUMBER while the
        // connection handler still owns it; on the process-wide singleton
        // engine the next session (channel zap) immediately opens new
        // sockets/files that recycle those numbers, so the handler's
        // late send() / deferred close() would then hit a foreign
        // descriptor (the new session's segment file or AVPlayer
        // connection). shutdown() wakes the blocked syscalls (recv
        // returns 0, send fails EPIPE) but keeps the number reserved
        // until the handler's single deferred close() releases it.
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
        // Split the request target into path + query. AVPlayer appends an
        // LL-HLS delivery directive (`?_HLS_msn=N`) to media.m3u8 reload
        // requests once the playlist advertises CAN-BLOCK-RELOAD, so the
        // route switch must match on the path alone, and the query carries
        // the blocking-reload Media Sequence Number.
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

        EngineLog.emit("[HLSLocalServer] \(firstLine)", category: .hlsServer)
        // Dump full request headers on first request per session.
        // AVPlayer's HLS pipeline may send capability headers
        // (Accept, Range, X-Playback-Session-Id) that influence its
        // variant-filter decisions. Server returning a response that
        // doesn't honour expected headers can trigger silent
        // variant rejection without errorLog events.
        stateLock.lock()
        let dumpHeaders = !loggedRequestHeaders
        if dumpHeaders { loggedRequestHeaders = true }
        stateLock.unlock()
        if dumpHeaders {
            let allLines = text.components(separatedBy: "\r\n")
            let headers = allLines.dropFirst().prefix(while: { !$0.isEmpty }).joined(separator: " | ")
            EngineLog.emit("[HLSLocalServer] first request headers fd=\(fd): \(headers)", category: .hlsServer)
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
            // For a live provider with no segments yet, hold this response
            // until the first segment is available. An empty live playlist
            // (no `#EXTINF` entries) causes AVPlayer to fire
            // CoreMediaErrorDomain -12888 immediately on macOS/tvOS 26,
            // regardless of `#EXT-X-TARGETDURATION`, because AVFoundation's
            // HLS client treats a live playlist with zero segments as
            // permanently stalled (it never polls again). Once we have at
            // least one segment the playlist is genuinely playable and
            // subsequent polls see incrementing content (MEDIA-SEQUENCE /
            // new segments), so -12888 never fires during normal playback.
            // The 30 s ceiling is a safety net; a real segment always
            // arrives well within it (the first ~5 s segment at 22 Mbps
            // takes at most a few seconds to demux + remux over loopback).
            if let p = provider, p.playlistType == .live {
                if let msn = Self.parseHLSMsn(query) {
                    // LL-HLS blocking reload: AVPlayer is asking for the
                    // playlist that contains Media Sequence Number `msn`
                    // (the next segment past what it already has). Hold the
                    // response until the producer finalizes that segment, so
                    // AVPlayer receives it the instant it is cut rather than
                    // a fixed reload-interval later. This is the structural
                    // fix for the residual startup pause: the segment exists
                    // on time, but the standard fixed-cadence reload made
                    // AVPlayer discover it late and drain its buffer. The
                    // timeout is a safety net (3 x target duration); on
                    // timeout we serve the current playlist and AVPlayer
                    // reissues the blocking reload.
                    _ = p.waitForLiveSegment(index: msn, timeout: 18.0)
                } else {
                    // First (non-directive) load: hold until the startup
                    // cushion exists so AVPlayer never sees an empty live
                    // playlist (-12888).
                    _ = p.waitForFirstLiveSegment(timeout: 30.0)
                }
            }
            let body = buildMediaPlaylist()
            stateLock.lock()
            let firstTime = !loggedMediaPlaylist
            if firstTime { loggedMediaPlaylist = true }
            mediaPlaylistBuildCount += 1
            // For a live (sliding) playlist, re-log the head/tail every 10
            // rebuilds so the advancing #EXT-X-MEDIA-SEQUENCE is observable
            // over a run (the firstTime-only log can't show advancement).
            // VOD logs once and never re-logs (no advancement to show).
            let isLivePlaylist = (provider?.playlistType == .live)
            let periodic = isLivePlaylist && (mediaPlaylistBuildCount % 10 == 0)
            stateLock.unlock()
            if firstTime || periodic {
                let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
                let head = lines.prefix(8).joined(separator: "\n")
                let tail = lines.suffix(6).joined(separator: "\n")
                EngineLog.emit("[HLSLocalServer] media.m3u8 head:\n\(head)",
                               category: .hlsServer)
                EngineLog.emit("[HLSLocalServer] media.m3u8 tail:\n\(tail)",
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
            "Cache-Control: no-cache\r\n" +
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
            "Cache-Control: no-cache\r\n" +
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
        guard let provider = provider else { return "#EXTM3U\n" }
        return Self.buildMasterPlaylistText(provider: provider,
                                             subResourceBaseURL: subResourceBaseURL)
    }

    private func buildMediaPlaylist() -> String {
        guard let provider = provider else { return "#EXTM3U\n" }
        return Self.buildMediaPlaylistText(provider: provider,
                                            subResourceBaseURL: subResourceBaseURL)
    }

    /// Parse the LL-HLS `_HLS_msn` (Media Sequence Number) delivery
    /// directive from a request query string (e.g. `_HLS_msn=42` or
    /// `_HLS_msn=42&_HLS_part=0`). Returns nil when absent or unparseable,
    /// which the caller treats as a plain (non-blocking) reload. `_HLS_part`
    /// is intentionally ignored: we advertise segment-level blocking reload
    /// only, with no partial segments.
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

    /// Public static playlist builders. Pure functions of the provider
    /// state, callable without a live `HLSLocalServer` instance.
    ///
    /// `subResourceBaseURL`: when set, `EXT-X-MAP` and segment URIs are
    /// emitted as absolute URLs under that base instead of as relative
    /// paths. Default (nil) emits relative URIs that AVPlayer resolves
    /// against the playlist URL.
    static func buildMasterPlaylistText(provider: HLSSegmentProvider,
                                         subResourceBaseURL: URL? = nil) -> String {
        guard let codecs = provider.masterCodecs else {
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

    static func buildMediaPlaylistText(provider: HLSSegmentProvider,
                                        subResourceBaseURL: URL? = nil) -> String {
        // Atomic snapshot of visible-window state. The video provider
        // uses this hook to advance its sliding window; capturing the
        // snapshot once and reading from it prevents segmentCount /
        // playlistType from drifting between read sites inside this
        // build.
        let snapshot = provider.notePlaylistBuild()
        let count = snapshot.visibleCount
        let firstVisible = provider.firstVisibleSegmentIndex
        let typeIsEvent = (provider.playlistType == .event && !snapshot.endlistAdded)
        // A sliding live playlist: MEDIA-SEQUENCE advances, segments below
        // firstVisible are gone, and the playlist is neither EVENT (which
        // forbids removal) nor VOD (which implies a finished asset). It
        // carries no PLAYLIST-TYPE tag and no ENDLIST.
        let typeIsLive = (provider.playlistType == .live && !snapshot.endlistAdded)

        // Compute target duration as ceil of the longest produced segment.
        // Spec requires this be >= every EXTINF in the playlist.
        var maxDuration: Double = 0
        for i in firstVisible..<count {
            maxDuration = max(maxDuration, provider.segmentDuration(at: i))
        }
        var targetDuration = Int(ceil(max(1.0, maxDuration)))

        // For live playlists, apply a stable floor of 1.5x the producer's
        // configured cut target. Two distinct problems share this floor:
        //
        // 1. Empty first manifest. Before segment 0 is finalized, maxDuration
        //    is 0 and the plain computation yields 1, giving AVPlayer only
        //    1.5 s to receive the first segment (1.5 * TARGETDURATION per
        //    spec). High-bitrate sources (20+ Mbps, 5+ s segments, many MB)
        //    cannot be demuxed, remuxed, and published over the loopback path
        //    in that window, so AVPlayer fires CoreMediaErrorDomain -12888
        //    "Playlist File unchanged for longer than 1.5 * target duration".
        //
        // 2. Transcode warm-up jitter. Even with the startup cushion, the
        //    server's real-time transcode takes a moment to reach steady
        //    throughput. During that warm-up the producer can stall ~8 s
        //    cutting the next segment (the pump blocks in the persistent
        //    reader), and AVPlayer, started one segment behind the edge,
        //    catches the gap and trips -12888 once at startup before
        //    recovering. The fix is patience, not a bigger cushion: a bigger
        //    cushion would add startup latency, whereas advertising a more
        //    generous TARGETDURATION widens the -12888 window at no startup
        //    cost. The segments are still CUT at the producer's target, so
        //    EXTINF stays ~targetSeconds and the playlist-reload cadence is
        //    unaffected; only AVPlayer's unchanged-playlist patience grows.
        //
        // ceil(1.5 * target) = 6 for a 4 s cut gives a 9 s patience window,
        // which clears the observed ~8 s warm-up gap with margin. Per HLS
        // spec TARGETDURATION must be >= every EXTINF; since the producer
        // cuts at targetSeconds, 1.5x comfortably satisfies that for normal
        // segments, and if a produced segment ever exceeds the floor, max()
        // keeps us compliant. VOD and EVENT paths are unchanged.
        if typeIsLive, let liveTarget = provider.liveTargetSegmentDuration {
            let liveFloor = Int(ceil(liveTarget * 1.5))
            targetDuration = max(targetDuration, liveFloor)
        }

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        if typeIsLive {
            // LL-HLS blocking playlist reload. Advertising CAN-BLOCK-RELOAD
            // makes AVPlayer reload with an `?_HLS_msn=N` directive instead
            // of polling on its own fixed cadence; the server holds that
            // reload open until segment N is cut (see the media.m3u8 handler
            // + waitForLiveSegment), so AVPlayer receives each new segment
            // the instant it is produced rather than a reload-interval late.
            // This removes the residual startup pause, where freshly cut
            // segments existed on time but AVPlayer discovered them late and
            // drained its buffer. We advertise segment-level blocking only
            // (no EXT-X-PART / PART-INF, since the producer does not cut
            // partial segments), so AVPlayer sends `_HLS_msn` without
            // `_HLS_part`. No explicit HOLD-BACK: AVPlayer uses its default
            // (3 x TARGETDURATION) distance from the live edge.
            lines.append("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES")
        }
        lines.append("#EXT-X-TARGETDURATION:\(targetDuration)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:\(firstVisible)")
        if typeIsLive {
            // RFC 8216 §6.2.2: must track discontinuity-tagged segments
            // that slid out of the window, or AVPlayer's discontinuity
            // numbering shifts one window-length after every program
            // boundary. Emitted unconditionally for live (0 is the spec
            // default and harmless).
            lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(snapshot.discontinuitySequence)")
        }
        if typeIsLive {
            // No #EXT-X-PLAYLIST-TYPE and no #EXT-X-ENDLIST: the sliding
            // window grows at the live edge and drops segments below
            // MEDIA-SEQUENCE. A refresh counter keeps two consecutive
            // polls distinct so AVPlayer never trips its "Playlist File
            // unchanged" (-12888) check during a quiet window.
            lines.append("#EXT-X-SODALITE-REFRESH:\(snapshot.refreshCounter)")
        } else if typeIsEvent {
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
        // URI emission: relative for HTTP-only playback (aetherctl
        // workflow, AVPlayer-via-HTTP), absolute custom-scheme for the
        // Sodalite resource-loader path. Absolute URLs in the playlist
        // are how AVPlayer knows to route a sub-resource through the
        // delegate instead of CFNetwork.
        let initURI: String
        let segURI: (Int) -> String
        if let base = subResourceBaseURL {
            let baseStr = base.absoluteString
            let baseWithSlash = baseStr.hasSuffix("/") ? baseStr : baseStr + "/"
            initURI = "\(baseWithSlash)init.mp4"
            segURI = { idx in "\(baseWithSlash)seg\(idx).mp4" }
        } else {
            initURI = "init.mp4"
            segURI = { idx in "seg\(idx).mp4" }
        }
        lines.append("#EXT-X-MAP:URI=\"\(initURI)\"")
        for i in firstVisible..<count {
            // A segment that opened at a live program-boundary PTS jump is
            // prefixed with #EXT-X-DISCONTINUITY (RFC 8216 §4.3.2.3): the tag
            // applies to the segment that FOLLOWS it, so it goes immediately
            // before that segment's #EXTINF. AVPlayer resets its media-
            // sequence timeline at the tag, which keeps seekableEnd (and the
            // engine's native session edge) monotonic across the source jump.
            if provider.segmentIsDiscontinuous(at: i) {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            let dur = provider.segmentDuration(at: i)
            lines.append("#EXTINF:\(String(format: "%.3f", dur)),")
            lines.append(segURI(i))
        }
        // ENDLIST marks a complete playlist. Emit it for VOD and for any
        // append path that has reached its end (endlistAdded), but NEVER
        // for a sliding live playlist (it must stay open so AVPlayer keeps
        // re-polling the advancing window) and not while an EVENT playlist
        // is still growing.
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

