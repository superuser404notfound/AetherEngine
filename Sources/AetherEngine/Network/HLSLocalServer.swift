import Foundation
import Network

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

/// Loopback HTTP server feeding HLS-fMP4 to AVPlayer. Originally the
/// audio-only `HLSAudioServer`; generalised in phase 3 of the DV
/// rollout so the same socket and request loop can serve video too.
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
/// Listens on `localhost` (not `127.0.0.1`) so tvOS App Transport
/// Security treats it as exempt without per-domain plist entries
/// (see TN3179, Apple Forum #663858).
final class HLSLocalServer: @unchecked Sendable {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.aetherengine.hls")

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

    /// Wall-clock time when seg0 was first fetched by AVPlayer. Used
    /// by the audio engine to measure HLS pipeline latency from
    /// "first segment available" to "AVPlayer asked for it".
    private(set) var seg0FetchTime: Date?

    /// One-shot flags so we log each playlist's full body once per
    /// session instead of on every AVPlayer re-fetch. Lets us see
    /// verbatim what got handed to AVPlayer without asking testers
    /// to curl the loopback port.
    private var loggedMasterPlaylist = false
    private var loggedMediaPlaylist = false

    private(set) var port: UInt16 = 0

    /// URL the host hands to AVPlayer to start playback. Points at
    /// the master playlist if the provider has one, else the media
    /// playlist directly.
    ///
    /// Uses the IP literal `127.0.0.1` rather than the hostname
    /// `localhost`. The hostname form needs DNS / nsswitch /
    /// /etc/hosts to resolve, and AVPlayer on tvOS appears to hang
    /// in its pre-flight before opening any TCP socket when
    /// resolution doesn't return immediately (build 122
    /// `timeControlStatus=waitingToPlay` with zero NWListener
    /// state-update events). The IP literal sidesteps the resolver
    /// entirely. ATS is covered either way: Sodalite's Info.plist
    /// already has `NSAllowsArbitraryLoads` plus
    /// `NSAllowsLocalNetworking`, so the original argument for
    /// keeping the hostname (per-domain ATS exception avoidance)
    /// no longer applies.
    var playlistURL: URL? {
        guard port > 0 else { return nil }
        let path = (provider?.masterCodecs != nil) ? "master.m3u8" : "media.m3u8"
        return URL(string: "http://127.0.0.1:\(port)/\(path)")
    }

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
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)

        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = l.port?.rawValue ?? 0
                EngineLog.emit("[HLSLocalServer] Listening on port \(self?.port ?? 0)")
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            // Log every TCP-level transition so we can tell whether
            // AVPlayer is even getting as far as opening a connection,
            // and whether the connection is reaching `.ready` before
            // we attempt a receive. Without this we silently lose any
            // connection that fails before delivering bytes.
            conn.stateUpdateHandler = { state in
                EngineLog.emit("[HLSLocalServer] conn state=\(state)")
            }
            conn.start(queue: self?.queue ?? .main)
            self?.readRequest(conn)
        }

        l.start(queue: queue)
        listener = l

        for _ in 0..<50 {
            if port > 0 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        loggedMasterPlaylist = false
        loggedMediaPlaylist = false
        bufferedProvider?.clear()
        seg0FetchTime = nil
    }

    // MARK: - Buffered-provider passthrough (legacy audio API)

    /// Set the init segment bytes (legacy audio API). Routes into
    /// the built-in buffered provider; throws nothing for the
    /// external-provider mode but silently does nothing.
    func setInitSegment(_ data: Data) {
        bufferedProvider?.setInitSegment(data)
    }

    /// Append a media segment (legacy audio API). Same caveat as
    /// `setInitSegment`.
    func addMediaSegment(_ data: Data, duration: Double) {
        bufferedProvider?.addMediaSegment(data, duration: duration)
    }

    /// Number of segments currently published.
    var segmentCount: Int {
        provider?.segmentCount ?? 0
    }

    // MARK: - HTTP Request Handling

    private func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                EngineLog.emit("[HLSLocalServer] receive error: \(error)")
                connection.cancel()
                return
            }
            if isComplete && (content == nil || content?.isEmpty == true) {
                EngineLog.emit("[HLSLocalServer] connection closed by peer (no data)")
                connection.cancel()
                return
            }
            guard let data = content else {
                // Spurious wake-up with no content and no error.
                // Re-arm and wait for actual bytes.
                self.readRequest(connection)
                return
            }
            guard let request = String(data: data, encoding: .utf8) else {
                EngineLog.emit("[HLSLocalServer] non-UTF8 request bytes (\(data.count)B), closing")
                connection.cancel()
                return
            }

            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"

            // The audio path historically used /audio.m3u8 as the
            // media playlist URL. Keep accepting it as an alias so
            // HLSAudioEngine doesn't have to change.
            let normalizedPath: String = {
                if path == "/audio.m3u8" { return "/media.m3u8" }
                return path
            }()

            EngineLog.emit("[HLSLocalServer] \(firstLine)")

            switch normalizedPath {
            case "/master.m3u8":
                if self.provider?.masterCodecs != nil {
                    let body = self.buildMasterPlaylist()
                    if !self.loggedMasterPlaylist {
                        self.loggedMasterPlaylist = true
                        EngineLog.emit("[HLSLocalServer] master.m3u8 body:\n\(body)")
                    }
                    self.respondData(connection,
                                     data: Data(body.utf8),
                                     contentType: "application/vnd.apple.mpegurl")
                } else {
                    self.respond404(connection)
                }
            case "/media.m3u8":
                let body = self.buildMediaPlaylist()
                if !self.loggedMediaPlaylist {
                    self.loggedMediaPlaylist = true
                    let head = body.split(separator: "\n").prefix(8).joined(separator: "\n")
                    EngineLog.emit("[HLSLocalServer] media.m3u8 head:\n\(head)")
                }
                self.respondData(connection,
                                 data: Data(body.utf8),
                                 contentType: "application/vnd.apple.mpegurl")
            case "/init.mp4":
                let data = self.provider?.initSegment() ?? Data()
                if data.isEmpty {
                    self.respond404(connection)
                } else {
                    self.respondData(connection, data: data, contentType: "video/mp4")
                }
            default:
                if normalizedPath.hasPrefix("/seg"), normalizedPath.hasSuffix(".mp4") {
                    let indexStr = normalizedPath.dropFirst(4).dropLast(4)
                    if let index = Int(indexStr), index >= 0 {
                        if index == 0 && self.seg0FetchTime == nil {
                            self.seg0FetchTime = Date()
                        }
                        if let data = self.provider?.mediaSegment(at: index), !data.isEmpty {
                            self.respondData(connection, data: data, contentType: "video/mp4")
                        } else {
                            self.respond404(connection)
                        }
                    } else {
                        self.respond404(connection)
                    }
                } else {
                    self.respond404(connection)
                }
            }
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

    // MARK: - HTTP framing

    private func respondData(_ connection: NWConnection, data: Data, contentType: String) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(data)

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.readRequest(connection)
        })
    }

    private func respond404(_ connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.readRequest(connection)
        })
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
