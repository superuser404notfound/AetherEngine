import Foundation
import Network

// MARK: - Segment Provider Protocol

/// Source of HLS segment bytes for one rendition.
///
/// One provider = one rendition. Video gets a `VideoSegmentProvider`,
/// each audio rendition gets its own `AudioSegmentProvider`. The
/// provider abstracts whether segments are produced live by a
/// libavformat `HLSSegmentProducer` (the normal case) or by some
/// future static source.
protocol HLSSegmentProvider: AnyObject {
    /// Init segment bytes (`ftyp` + empty `moov`). Returns nil when
    /// the muxer hasn't produced one yet.
    func initSegment() -> Data?

    /// Bytes for media segment `index` (0-based). Returns nil if the
    /// segment isn't available yet or is out of range.
    func mediaSegment(at index: Int) -> Data?

    /// Number of segments in this rendition.
    var segmentCount: Int { get }

    /// Duration in seconds of segment `index`. May vary per segment
    /// when boundaries snap to source keyframes (the video case);
    /// uniform for audio renditions.
    func segmentDuration(at index: Int) -> Double

    /// Apple HLS playlist type. Renditions backed by libavformat-driven
    /// HLSSegmentProducer pumps are always `.vod`.
    var playlistType: HLSPlaylistType { get }
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

// MARK: - Video rendition metadata

/// Master-playlist attributes for the video variant. Carried on the
/// video provider so the server can synthesize the EXT-X-STREAM-INF
/// line without reaching back into HLSVideoEngine.
struct HLSVideoRenditionInfo {
    /// CODECS attribute primary value (video codec only — the audio
    /// rendition's codec is appended at master-build time).
    let codecs: String
    /// SUPPLEMENTAL-CODECS attribute on `EXT-X-STREAM-INF`. Per
    /// Apple's HLS Authoring Spec Appendixes table, Dolby Vision
    /// Profile 8.1 advertises plain HEVC in `CODECS` and signals DV
    /// via `SUPPLEMENTAL-CODECS="dvh1.08.LL/db1p"` (P8.4 uses
    /// `dvh1.08.LL/db4h`). Profile 5 has no fallback variant and
    /// puts `dvh1.05.LL` directly in CODECS, so SUPPLEMENTAL-CODECS
    /// is nil there. AVPlayer's master-level codec filter is
    /// stricter than the segment-level filter and silently drops
    /// any variant whose primary CODECS it can't fall back to.
    let supplementalCodecs: String?
    let resolution: (width: Int, height: Int)
    let videoRange: HLSVideoRange
    let frameRate: Double?
    let bandwidth: Int
    let averageBandwidth: Int
    /// HDCP-LEVEL attribute. Apple Tech Talk 501 says `TYPE-1` is
    /// required for resolutions >1920x1080 in HDR / DV streams.
    let hdcpLevel: String?
    /// CLOSED-CAPTIONS attribute. Apple's reference DV samples set
    /// this to `NONE` when there's no in-band CC track.
    let closedCaptions: String?
}

// MARK: - Audio rendition metadata

/// Master-playlist attributes for one audio rendition (one
/// EXT-X-MEDIA TYPE=AUDIO line). Holders register one of these
/// alongside an `HLSSegmentProvider` via `registerAudioRendition`.
struct HLSAudioRendition {
    /// Stable identifier used to construct the per-rendition URL
    /// paths (e.g. `audio_<id>.m3u8`). In practice the source-
    /// container stream index as a decimal string so the host's
    /// AVMediaSelection→engine.audioTracks mapping has a key it can
    /// round-trip.
    let id: String
    /// Human-readable NAME attribute on the EXT-X-MEDIA line.
    let name: String
    /// LANGUAGE attribute, BCP-47 (`en`, `de`, `ja`). Optional.
    let language: String?
    /// DEFAULT attribute. Exactly one rendition per GROUP-ID should
    /// be DEFAULT=YES; AVPlayer picks that one as the initial audio
    /// selection.
    let isDefault: Bool
    /// CODECS attribute for this rendition (e.g. `mp4a.40.2`, `ec-3`,
    /// `fLaC`). Appended to the variant's CODECS attribute too.
    let codecs: String
    /// CHANNELS attribute. AAC stereo = "2", 5.1 = "6", 7.1 = "8".
    /// HLS spec encodes channel count as a string.
    let channels: Int
}

// MARK: - Local HLS Server

/// Loopback HTTP server feeding HLS-fMP4 to AVPlayer. Serves a master
/// playlist that references one video rendition (`video.m3u8`) plus
/// zero or more alternate audio renditions (`audio_<id>.m3u8`). Each
/// rendition is fed by a separate `HLSSegmentProducer` upstream.
///
/// Endpoints:
///   - `/master.m3u8` — master with EXT-X-STREAM-INF referencing the
///     video rendition, plus one EXT-X-MEDIA TYPE=AUDIO per registered
///     audio rendition.
///   - `/video.m3u8` — video rendition's media playlist (VOD).
///   - `/video_init.mp4` — video rendition's init segment.
///   - `/video_seg-{N}.m4s` — video rendition's media segment N.
///   - `/audio_<id>.m3u8` — audio rendition `<id>`'s media playlist.
///   - `/audio_<id>_init.mp4` — audio rendition `<id>`'s init segment.
///   - `/audio_<id>_seg-{N}.m4s` — audio rendition `<id>`'s media segment N.
///
/// Listens on `localhost` (not `127.0.0.1`) so tvOS App Transport
/// Security treats it as exempt without per-domain plist entries
/// (see TN3179, Apple Forum #663858).
final class HLSLocalServer: @unchecked Sendable {

    private var listener: NWListener?
    /// Concurrent so two AVPlayer GETs (e.g. video segment + audio
    /// segment for the same playhead) can each block in cache.fetch
    /// without starving each other. The previous serial queue worked
    /// for the single-rendition pipeline (only one outstanding GET);
    /// alternate renditions create per-track GETs that overlap in
    /// time and a serial queue would serialise their fetches.
    private let queue = DispatchQueue(label: "com.aetherengine.hls", attributes: .concurrent)

    /// Video rendition. Required — every session has video.
    private let videoProvider: HLSSegmentProvider
    private let videoInfo: HLSVideoRenditionInfo

    /// Audio renditions, in registration order. Each entry is one
    /// EXT-X-MEDIA TYPE=AUDIO entry in master.m3u8 and is served at
    /// `/audio_<id>.m3u8` + friends.
    private struct AudioEntry {
        let info: HLSAudioRendition
        let provider: HLSSegmentProvider
    }
    private var audioEntries: [AudioEntry] = []
    private let audioLock = NSLock()

    /// Wall-clock time when video seg0 was first fetched by AVPlayer.
    /// Used for pipeline-latency diagnostics.
    private(set) var seg0FetchTime: Date?

    /// One-shot flags so we log each playlist's full body once per
    /// session instead of on every AVPlayer re-fetch.
    private var loggedMasterPlaylist = false
    private var loggedVideoPlaylist = false
    private var loggedAudioPlaylists: Set<String> = []

    private(set) var port: UInt16 = 0

    /// URL the host hands to AVPlayer to start playback — always the
    /// master playlist. The previous "media-playlist-direct" bypass
    /// (used to force AVPlayer's auto-tone-mapping path on non-DV
    /// displays) doesn't survive the multi-rendition split: serving
    /// `video.m3u8` directly would play silent video because audio
    /// now lives in alternate renditions. For non-DV displays the
    /// engine already downgrades DV sources to plain HEVC in the
    /// master CODECS attribute (`HLSVideoEngine.start()` at the
    /// `!dvModeAvailable` branch), which is enough on its own.
    ///
    /// Uses the IP literal `127.0.0.1` rather than the hostname
    /// `localhost`. The hostname form needs DNS / nsswitch /
    /// /etc/hosts to resolve, and AVPlayer on tvOS appears to hang
    /// in its pre-flight before opening any TCP socket when
    /// resolution doesn't return immediately. The IP literal
    /// sidesteps the resolver entirely.
    var playlistURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/master.m3u8")
    }

    // MARK: - Init

    init(videoProvider: HLSSegmentProvider, videoInfo: HLSVideoRenditionInfo) {
        self.videoProvider = videoProvider
        self.videoInfo = videoInfo
    }

    /// Register an audio rendition. Called by `HLSVideoEngine` once
    /// per audio source track it spins a producer up for. Must be
    /// called before `start()` so master.m3u8's first build sees all
    /// renditions.
    func registerAudioRendition(info: HLSAudioRendition, provider: HLSSegmentProvider) {
        audioLock.lock()
        audioEntries.append(AudioEntry(info: info, provider: provider))
        audioLock.unlock()
    }

    private func audioEntry(forID id: String) -> AudioEntry? {
        audioLock.lock()
        defer { audioLock.unlock() }
        return audioEntries.first { $0.info.id == id }
    }

    private func snapshotAudioEntries() -> [AudioEntry] {
        audioLock.lock()
        defer { audioLock.unlock() }
        return audioEntries
    }

    // MARK: - Lifecycle

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)

        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = l.port?.rawValue ?? 0
                EngineLog.emit("[HLSLocalServer] Listening on port \(self?.port ?? 0)", category: .hlsServer)
            }
        }

        l.newConnectionHandler = { [weak self] conn in
            // Log every TCP-level transition so we can tell whether
            // AVPlayer is even getting as far as opening a connection,
            // and whether the connection is reaching `.ready` before
            // we attempt a receive.
            conn.stateUpdateHandler = { state in
                EngineLog.emit("[HLSLocalServer] conn state=\(state)", category: .hlsServer)
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
        loggedVideoPlaylist = false
        loggedAudioPlaylists.removeAll()
        seg0FetchTime = nil
        audioLock.lock()
        audioEntries.removeAll()
        audioLock.unlock()
    }

    // MARK: - HTTP Request Handling

    private func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                EngineLog.emit("[HLSLocalServer] receive error: \(error)", category: .hlsServer)
                connection.cancel()
                return
            }
            if isComplete && (content == nil || content?.isEmpty == true) {
                EngineLog.emit("[HLSLocalServer] connection closed by peer (no data)", category: .hlsServer)
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
                EngineLog.emit("[HLSLocalServer] non-UTF8 request bytes (\(data.count)B), closing", category: .hlsServer)
                connection.cancel()
                return
            }

            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"

            EngineLog.emit("[HLSLocalServer] \(firstLine)", category: .hlsServer)

            self.route(path: path, connection: connection)
        }
    }

    private func route(path: String, connection: NWConnection) {
        switch path {
        case "/master.m3u8":
            let body = buildMasterPlaylist()
            if !loggedMasterPlaylist {
                loggedMasterPlaylist = true
                EngineLog.emit("[HLSLocalServer] master.m3u8 body:\n\(body)", category: .hlsServer)
            }
            respondData(connection,
                        path: path,
                        data: Data(body.utf8),
                        contentType: "application/vnd.apple.mpegurl")

        case "/video.m3u8":
            let body = buildMediaPlaylist(for: videoProvider)
            if !loggedVideoPlaylist {
                loggedVideoPlaylist = true
                let head = body.split(separator: "\n").prefix(8).joined(separator: "\n")
                EngineLog.emit("[HLSLocalServer] video.m3u8 head:\n\(head)", category: .hlsServer)
            }
            respondData(connection,
                        path: path,
                        data: Data(body.utf8),
                        contentType: "application/vnd.apple.mpegurl")

        case "/video_init.mp4":
            let data = videoProvider.initSegment() ?? Data()
            if data.isEmpty {
                respond404(connection, path: path, reason: "video init.mp4 empty (provider not ready?)")
            } else {
                respondData(connection, path: path, data: data, contentType: "video/mp4")
            }

        default:
            if let segIndex = parseSegmentIndex(path: path, prefix: "/video_seg-", suffix: ".m4s") {
                if segIndex == 0 && seg0FetchTime == nil {
                    seg0FetchTime = Date()
                }
                serveSegment(connection, path: path, provider: videoProvider, index: segIndex)
                return
            }

            if let (audioID, suffix) = parseAudioPath(path) {
                guard let entry = audioEntry(forID: audioID) else {
                    respond404(connection, path: path, reason: "unknown audio rendition id=\(audioID)")
                    return
                }
                switch suffix {
                case .playlist:
                    let body = buildMediaPlaylist(for: entry.provider)
                    if !loggedAudioPlaylists.contains(audioID) {
                        loggedAudioPlaylists.insert(audioID)
                        let head = body.split(separator: "\n").prefix(8).joined(separator: "\n")
                        EngineLog.emit("[HLSLocalServer] audio_\(audioID).m3u8 head:\n\(head)", category: .hlsServer)
                    }
                    respondData(connection,
                                path: path,
                                data: Data(body.utf8),
                                contentType: "application/vnd.apple.mpegurl")
                case .initSegment:
                    let data = entry.provider.initSegment() ?? Data()
                    if data.isEmpty {
                        respond404(connection, path: path, reason: "audio init empty (provider not ready?)")
                    } else {
                        respondData(connection, path: path, data: data, contentType: "video/mp4")
                    }
                case .segment(let idx):
                    serveSegment(connection, path: path, provider: entry.provider, index: idx)
                }
                return
            }

            respond404(connection, path: path, reason: "unknown path")
        }
    }

    private func serveSegment(_ connection: NWConnection, path: String, provider: HLSSegmentProvider, index: Int) {
        guard index >= 0 else {
            respond404(connection, path: path, reason: "negative segment index \(index)")
            return
        }
        if let data = provider.mediaSegment(at: index), !data.isEmpty {
            respondData(connection, path: path, data: data, contentType: "video/mp4")
        } else {
            respond404(connection, path: path, reason: "segment[\(index)] empty (segmentCount=\(provider.segmentCount))")
        }
    }

    // MARK: - Path parsing

    private enum AudioPathSuffix {
        case playlist
        case initSegment
        case segment(Int)
    }

    /// Parse `/audio_<id>.m3u8`, `/audio_<id>_init.mp4`,
    /// `/audio_<id>_seg-<N>.m4s` into (id, suffix). Returns nil for
    /// non-audio paths. The id is whatever comes after `/audio_` up to
    /// the first suffix marker — opaque to the parser, must match what
    /// `registerAudioRendition` was called with.
    private func parseAudioPath(_ path: String) -> (id: String, suffix: AudioPathSuffix)? {
        let prefix = "/audio_"
        guard path.hasPrefix(prefix) else { return nil }
        let tail = path.dropFirst(prefix.count)
        // Order matters: longer suffix tested first so the id parser
        // doesn't accidentally swallow "_seg-N" / "_init" tokens.
        if tail.hasSuffix(".m3u8") {
            let id = String(tail.dropLast(".m3u8".count))
            return (id, .playlist)
        }
        if tail.hasSuffix("_init.mp4") {
            let id = String(tail.dropLast("_init.mp4".count))
            return (id, .initSegment)
        }
        if tail.hasSuffix(".m4s") {
            let body = tail.dropLast(".m4s".count)
            guard let segMarker = body.range(of: "_seg-") else { return nil }
            let id = String(body[..<segMarker.lowerBound])
            let idxStr = body[segMarker.upperBound...]
            guard let idx = Int(idxStr) else { return nil }
            return (id, .segment(idx))
        }
        return nil
    }

    /// Parse `/<prefix><N><suffix>` and return N, or nil.
    private func parseSegmentIndex(path: String, prefix: String, suffix: String) -> Int? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let inner = path.dropFirst(prefix.count).dropLast(suffix.count)
        return Int(inner)
    }

    // MARK: - Playlist construction

    private func buildMasterPlaylist() -> String {
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-INDEPENDENT-SEGMENTS")

        // EXT-X-MEDIA per audio rendition.
        let audios = snapshotAudioEntries()
        let audioGroupID = "audio"
        for entry in audios {
            var attrs: [String] = []
            attrs.append("TYPE=AUDIO")
            attrs.append("GROUP-ID=\"\(audioGroupID)\"")
            attrs.append("NAME=\"\(escapeAttr(entry.info.name))\"")
            if let lang = entry.info.language {
                attrs.append("LANGUAGE=\"\(lang)\"")
            }
            attrs.append("DEFAULT=\(entry.info.isDefault ? "YES" : "NO")")
            attrs.append("AUTOSELECT=YES")
            attrs.append("CHANNELS=\"\(entry.info.channels)\"")
            attrs.append("URI=\"audio_\(entry.info.id).m3u8\"")
            lines.append("#EXT-X-MEDIA:\(attrs.joined(separator: ","))")
        }

        // EXT-X-STREAM-INF attribute order follows Apple's HLS
        // Authoring Spec Appendixes example: BANDWIDTH first,
        // AVERAGE-BANDWIDTH next, then CODECS, then SUPPLEMENTAL-
        // CODECS, then RESOLUTION / FRAME-RATE / VIDEO-RANGE, then
        // AUDIO / HDCP-LEVEL / CLOSED-CAPTIONS.
        var streamInfAttrs: [String] = []
        streamInfAttrs.append("BANDWIDTH=\(videoInfo.bandwidth)")
        streamInfAttrs.append("AVERAGE-BANDWIDTH=\(videoInfo.averageBandwidth)")

        // CODECS combines video + default-audio rendition's codec when
        // an audio rendition exists. AVPlayer's master-level codec
        // filter checks every codec listed here against its decoder
        // support; missing the audio codec lets some setups reject
        // the variant entirely.
        let defaultAudio = audios.first(where: { $0.info.isDefault }) ?? audios.first
        let combinedCodecs: String
        if let a = defaultAudio {
            combinedCodecs = "\(videoInfo.codecs),\(a.info.codecs)"
        } else {
            combinedCodecs = videoInfo.codecs
        }
        streamInfAttrs.append("CODECS=\"\(combinedCodecs)\"")
        if let supplemental = videoInfo.supplementalCodecs {
            streamInfAttrs.append("SUPPLEMENTAL-CODECS=\"\(supplemental)\"")
        }
        streamInfAttrs.append("RESOLUTION=\(videoInfo.resolution.width)x\(videoInfo.resolution.height)")
        if let frameRate = videoInfo.frameRate {
            streamInfAttrs.append("FRAME-RATE=\(String(format: "%.3f", frameRate))")
        }
        streamInfAttrs.append("VIDEO-RANGE=\(videoInfo.videoRange.rawValue)")
        if !audios.isEmpty {
            streamInfAttrs.append("AUDIO=\"\(audioGroupID)\"")
        }
        if let hdcp = videoInfo.hdcpLevel {
            streamInfAttrs.append("HDCP-LEVEL=\(hdcp)")
        }
        if let cc = videoInfo.closedCaptions {
            streamInfAttrs.append("CLOSED-CAPTIONS=\(cc)")
        }
        lines.append("#EXT-X-STREAM-INF:\(streamInfAttrs.joined(separator: ","))")
        lines.append("video.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    private func buildMediaPlaylist(for provider: HLSSegmentProvider) -> String {
        let count = provider.segmentCount
        let isAudio = provider !== videoProvider

        // Compute target duration as ceil of the longest segment.
        // Spec requires this be >= every EXTINF in the playlist.
        var maxDuration: Double = 0
        for i in 0..<count {
            maxDuration = max(maxDuration, provider.segmentDuration(at: i))
        }
        let targetDuration = Int(ceil(max(1.0, maxDuration)))

        let prefix = isAudio ? audioURLPrefix(for: provider) : "video"
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-TARGETDURATION:\(targetDuration)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")
        switch provider.playlistType {
        case .vod:   lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        case .event: lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
        }
        lines.append("#EXT-X-MAP:URI=\"\(prefix)_init.mp4\"")
        for i in 0..<count {
            let dur = provider.segmentDuration(at: i)
            lines.append("#EXTINF:\(String(format: "%.3f", dur)),")
            lines.append("\(prefix)_seg-\(i).m4s")
        }
        if provider.playlistType == .vod {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Look up the URL path prefix (`audio_<id>`) for a given audio
    /// provider so its own media playlist references the right files.
    /// Falls back to "video" if the provider isn't registered as an
    /// audio rendition — defensive; callers shouldn't reach this for
    /// the video provider.
    private func audioURLPrefix(for provider: HLSSegmentProvider) -> String {
        audioLock.lock()
        defer { audioLock.unlock() }
        if let entry = audioEntries.first(where: { $0.provider === provider }) {
            return "audio_\(entry.info.id)"
        }
        return "video"
    }

    /// Quote double-quotes inside an HLS attribute string. HLS attribute
    /// values inside `"..."` don't have an escape mechanism; the spec
    /// says they "should not contain double quotes". For our metadata
    /// (track names from container metadata) we strip quotes by
    /// substitution to keep the manifest parseable.
    private func escapeAttr(_ s: String) -> String {
        return s.replacingOccurrences(of: "\"", with: "'")
    }

    // MARK: - HTTP framing

    private func respondData(_ connection: NWConnection, path: String, data: Data, contentType: String) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(data)

        EngineLog.emit("[HLSLocalServer] -> 200 \(path) bytes=\(data.count) type=\(contentType)", category: .hlsServer)

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error = error {
                EngineLog.emit("[HLSLocalServer] send failed for \(path): \(error)", category: .hlsServer)
            }
            self?.readRequest(connection)
        })
    }

    private func respond404(_ connection: NWConnection, path: String, reason: String) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
        EngineLog.emit("[HLSLocalServer] -> 404 \(path) reason=\(reason)", category: .hlsServer)
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.readRequest(connection)
        })
    }
}
