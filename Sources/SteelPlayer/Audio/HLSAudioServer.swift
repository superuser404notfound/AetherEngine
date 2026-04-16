import Foundation
import Network

/// Local HTTP server that serves HLS audio to AVPlayer on tvOS.
///
/// Serves three types of resources:
/// - `/audio.m3u8` — Live sliding-window playlist (last 5 segments)
/// - `/init.mp4`   — fMP4 init segment (moov, loaded once)
/// - `/segN.mp4`   — fMP4 media segments (moof+mdat, loaded sequentially)
///
/// ## AVPlayer Stale-Detection Workaround
///
/// AVPlayer stops fetching segments when it polls the playlist multiple
/// times and gets the same response (same segment count). To prevent this:
/// 1. No `#EXT-X-PLAYLIST-TYPE:EVENT` — plain live playlist
/// 2. Sliding window of 5 segments (old segments drop off)
/// 3. Returns HTTP 404 when no new segments since last poll (signals
///    "server alive, buffering" per WWDC17 Session 514)
final class HLSAudioServer: @unchecked Sendable {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.steelplayer.hls")

    private let lock = NSLock()
    private var initSegmentData: Data?
    private var segments: [Data] = []
    private var segDuration: Double = 2.048


    private(set) var port: UInt16 = 0

    var playlistURL: URL? {
        port > 0 ? URL(string: "http://127.0.0.1:\(port)/audio.m3u8") : nil
    }

    // MARK: - Lifecycle

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)

        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = l.port?.rawValue ?? 0
                #if DEBUG
                print("[HLSAudioServer] Listening on port \(self?.port ?? 0)")
                #endif
            }
        }

        l.newConnectionHandler = { [weak self] conn in
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
        lock.lock()
        initSegmentData = nil
        segments.removeAll()
        lock.unlock()
    }

    // MARK: - Content Management

    func setInitSegment(_ data: Data) {
        lock.lock()
        initSegmentData = data
        lock.unlock()
    }

    func addMediaSegment(_ data: Data, duration: Double) {
        lock.lock()
        segments.append(data)
        segDuration = duration
        lock.unlock()
    }

    var segmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return segments.count
    }

    // MARK: - HTTP Request Handling

    private func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard let self = self, error == nil, let data = content,
                  let request = String(data: data, encoding: .utf8) else { return }

            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"

            #if DEBUG
            print("[HLSAudioServer] \(firstLine)")
            #endif

            if path.hasSuffix(".m3u8") {
                self.respondPlaylist(connection)
            } else if path == "/init.mp4" {
                self.lock.lock()
                let data = self.initSegmentData ?? Data()
                self.lock.unlock()
                self.respondData(connection, data: data, contentType: "video/mp4")
            } else if path.hasPrefix("/seg") && path.hasSuffix(".mp4") {
                let indexStr = path.dropFirst(4).dropLast(4)
                let index = Int(indexStr) ?? -1
                self.lock.lock()
                let data = (index >= 0 && index < self.segments.count) ? self.segments[index] : Data()
                self.lock.unlock()
                if data.isEmpty {
                    self.respond404(connection)
                } else {
                    self.respondData(connection, data: data, contentType: "video/mp4")
                }
            } else {
                self.respond404(connection)
            }
        }
    }

    private func respondPlaylist(_ connection: NWConnection) {
        lock.lock()
        let count = segments.count
        let duration = segDuration
        lock.unlock()

        // Sliding window: only advertise the last 5 segments.
        // As new segments are added, MEDIA-SEQUENCE increments and old
        // segments drop off. AVPlayer sees a changing playlist on each
        // poll, preventing stale-stream detection.
        let windowSize = 5
        let startIndex = max(0, count - windowSize)
        let targetDuration = Int(ceil(duration))

        var m3u8 = "#EXTM3U\n"
        m3u8 += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
        m3u8 += "#EXT-X-VERSION:7\n"
        // No #EXT-X-PLAYLIST-TYPE — plain live playlist
        m3u8 += "#EXT-X-MEDIA-SEQUENCE:\(startIndex)\n"
        m3u8 += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        for i in startIndex..<count {
            m3u8 += "#EXTINF:\(String(format: "%.3f", duration)),\n"
            m3u8 += "seg\(i).mp4\n"
        }
        // No #EXT-X-ENDLIST — stream continues

        #if DEBUG
        print("[HLSAudioServer] Playlist: seq=\(startIndex) segments=\(startIndex)..\(count-1) (window=\(count - startIndex))")
        #endif

        respondData(connection, data: Data(m3u8.utf8), contentType: "application/vnd.apple.mpegurl")
    }

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
