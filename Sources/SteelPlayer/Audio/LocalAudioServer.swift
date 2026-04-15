import Foundation
import Network

/// Minimal local HTTP server that streams fMP4 audio data to AVPlayer.
///
/// mediaserverd (tvOS out-of-process media server) uses standard HTTP
/// range requests to probe and stream media:
///
/// 1. `Range: bytes=0-1` → 206 Partial Content (2-byte probe)
/// 2. `Range: bytes=0-`  → 206 Partial Content (stream full content)
///
/// We declare a large Content-Length (2GB) and stream fMP4 data as
/// a progressive download. mediaserverd starts playback while data
/// is still arriving.
final class LocalAudioServer: @unchecked Sendable {

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "com.steelplayer.audioserver")

    private let lock = NSLock()
    /// True once we've sent the response header for the streaming connection.
    private var streamingActive = false
    private var pendingData = Data()
    private var isSending = false
    /// All data sent so far (for range request replays). Capped for memory.
    private var sentData = Data()

    /// Fake total size for Content-Length / Content-Range headers.
    private let declaredSize = 2_000_000_000

    private(set) var port: UInt16 = 0

    var streamURL: URL? {
        port > 0 ? URL(string: "http://127.0.0.1:\(port)/audio.mp4") : nil
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)

        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = l.port?.rawValue ?? 0
                #if DEBUG
                print("[LocalAudioServer] Listening on port \(self?.port ?? 0)")
                #endif
            }
            #if DEBUG
            if case .failed(let error) = state {
                print("[LocalAudioServer] Listener failed: \(error)")
            }
            #endif
        }

        l.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        l.start(queue: connectionQueue)
        listener = l

        for _ in 0..<50 {
            if port > 0 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Queue fMP4 data for sending to AVPlayer.
    func send(_ data: Data) {
        lock.lock()
        pendingData.append(data)
        sentData.append(data)
        lock.unlock()
        drainPending()
    }

    func stop() {
        lock.lock()
        pendingData = Data()
        sentData = Data()
        streamingActive = false
        isSending = false
        lock.unlock()

        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            #if DEBUG
            if case .failed(let error) = state {
                print("[LocalAudioServer] Connection failed: \(error)")
            }
            #endif
        }

        connection.start(queue: connectionQueue)
        readRequest(connection)
    }

    private func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self, error == nil, let data = content else { return }
            guard let request = String(data: data, encoding: .utf8) else { return }

            let lines = request.components(separatedBy: "\r\n")

            #if DEBUG
            for line in lines.prefix(10) {
                if line.isEmpty { break }
                print("[LocalAudioServer] \(line)")
            }
            #endif

            // Parse Range header
            var rangeStart: Int? = nil
            var rangeEnd: Int? = nil
            for line in lines {
                if line.lowercased().hasPrefix("range:") {
                    let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    // Parse "bytes=0-1" or "bytes=0-"
                    if value.hasPrefix("bytes=") {
                        let rangePart = value.dropFirst(6)
                        let parts = rangePart.split(separator: "-", maxSplits: 1)
                        if let startStr = parts.first {
                            rangeStart = Int(startStr)
                        }
                        if parts.count > 1, let endStr = parts.last, !endStr.isEmpty {
                            rangeEnd = Int(endStr)
                        }
                    }
                    break
                }
            }

            if let start = rangeStart, let end = rangeEnd {
                // Fixed range request (e.g., bytes=0-1 probe)
                self.handleProbeRequest(connection, start: start, end: end)
            } else if let start = rangeStart {
                // Open-ended range (e.g., bytes=0-) — this is the streaming request
                self.handleStreamRequest(connection, start: start)
            } else {
                // No range — full content request
                self.handleStreamRequest(connection, start: 0)
            }
        }
    }

    /// Handle a fixed-range probe request (e.g., Range: bytes=0-1).
    /// Responds with exactly the requested bytes and closes, ready for next request.
    private func handleProbeRequest(_ connection: NWConnection, start: Int, end: Int) {
        let length = end - start + 1

        lock.lock()
        let available = sentData
        lock.unlock()

        // Extract requested bytes from our buffer
        let responseData: Data
        if start < available.count {
            let actualEnd = min(end + 1, available.count)
            responseData = available.subdata(in: start..<actualEnd)
        } else {
            responseData = Data(count: length)  // Zero-fill if not yet available
        }

        let header = [
            "HTTP/1.1 206 Partial Content",
            "Content-Type: video/mp4",
            "Content-Range: bytes \(start)-\(end)/\(declaredSize)",
            "Content-Length: \(responseData.count)",
            "Accept-Ranges: bytes",
            "",
            ""
        ].joined(separator: "\r\n")

        var payload = Data()
        payload.append(header.data(using: .utf8)!)
        payload.append(responseData)

        #if DEBUG
        print("[LocalAudioServer] Probe response: 206 bytes=\(start)-\(end), \(responseData.count) bytes")
        #endif

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error = error {
                #if DEBUG
                print("[LocalAudioServer] Probe send error: \(error)")
                #endif
                return
            }
            // Read next request on the same connection (keep-alive)
            self?.readRequest(connection)
        })
    }

    /// Handle an open-ended range or full request — start streaming.
    private func handleStreamRequest(_ connection: NWConnection, start: Int) {
        // Cancel any previous streaming connection
        if activeConnection !== connection {
            activeConnection?.cancel()
        }
        activeConnection = connection

        let rangeEnd = declaredSize - 1
        let contentLength = declaredSize - start

        let header: String
        if start > 0 {
            header = [
                "HTTP/1.1 206 Partial Content",
                "Content-Type: video/mp4",
                "Content-Range: bytes \(start)-\(rangeEnd)/\(declaredSize)",
                "Content-Length: \(contentLength)",
                "Accept-Ranges: bytes",
                "",
                ""
            ].joined(separator: "\r\n")
        } else {
            header = [
                "HTTP/1.1 200 OK",
                "Content-Type: video/mp4",
                "Content-Length: \(declaredSize)",
                "Accept-Ranges: bytes",
                "",
                ""
            ].joined(separator: "\r\n")
        }

        // Gather all data from the requested offset
        lock.lock()
        var payload = Data()
        payload.append(header.data(using: .utf8)!)

        // Send any already-buffered data from the requested offset
        if start < sentData.count {
            payload.append(sentData.subdata(in: start..<sentData.count))
        }
        // Also append any pending data not yet in sentData
        if !pendingData.isEmpty {
            payload.append(pendingData)
            pendingData = Data()
        }
        streamingActive = true
        lock.unlock()

        #if DEBUG
        print("[LocalAudioServer] Stream response: start=\(start), initial payload=\(payload.count) bytes")
        #endif

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error = error {
                #if DEBUG
                print("[LocalAudioServer] Stream send error: \(error)")
                #endif
                return
            }

            #if DEBUG
            print("[LocalAudioServer] Stream started successfully")
            #endif

            self?.drainPending()
        })
    }

    private func drainPending() {
        lock.lock()
        guard streamingActive, !isSending, !pendingData.isEmpty else {
            lock.unlock()
            return
        }
        let dataToSend = pendingData
        pendingData = Data()
        isSending = true
        lock.unlock()

        guard let connection = activeConnection else {
            lock.lock()
            pendingData = dataToSend + pendingData
            isSending = false
            lock.unlock()
            return
        }

        connection.send(content: dataToSend, completion: .contentProcessed { [weak self] error in
            self?.lock.lock()
            self?.isSending = false
            self?.lock.unlock()

            if error != nil {
                #if DEBUG
                print("[LocalAudioServer] Send error: \(error!)")
                #endif
                return
            }

            self?.drainPending()
        })
    }
}
