import Foundation
import Network

/// Minimal local HTTP server that streams fMP4 audio data to AVPlayer.
///
/// mediaserverd uses standard HTTP range requests:
/// 1. `Range: bytes=0-1` → probe (206 + 2 bytes)
/// 2. `Range: bytes=0-N` → full content from start
/// 3. `Range: bytes=X-N` → resume from offset X
///
/// We respond with whatever data is available and keep the sentOffset
/// to handle subsequent requests. Memory is bounded by only keeping
/// undelivered data + a small replay buffer for the initial probe.
final class LocalAudioServer: @unchecked Sendable {

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "com.steelplayer.audioserver")

    private let lock = NSLock()

    /// All fMP4 data accumulated (init segment + media segments).
    /// Trimmed periodically to prevent unbounded growth.
    private var buffer = Data()
    /// How many bytes have been trimmed from the start of buffer.
    private var bufferTrimmed = 0

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
        buffer.append(data)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        buffer = Data()
        bufferTrimmed = 0
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard let self = self, error == nil, let data = content,
                  let request = String(data: data, encoding: .utf8) else { return }

            let lines = request.components(separatedBy: "\r\n")

            #if DEBUG
            if let first = lines.first {
                print("[LocalAudioServer] \(first)")
            }
            #endif

            // Parse Range header
            var rangeStart = 0
            var rangeEnd: Int? = nil
            for line in lines {
                let lower = line.lowercased()
                if lower.hasPrefix("range:") {
                    let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("bytes=") {
                        let parts = value.dropFirst(6).split(separator: "-", maxSplits: 1)
                        if let s = parts.first { rangeStart = Int(s) ?? 0 }
                        if parts.count > 1, let e = parts.last, !e.isEmpty {
                            rangeEnd = Int(e)
                        }
                    }
                    break
                }
            }

            // Small probe (e.g., bytes=0-1): respond + wait for next request
            let isSmallProbe = (rangeEnd != nil && rangeEnd! < 1024)
            if isSmallProbe {
                self.respondProbe(connection, start: rangeStart, end: rangeEnd!)
            } else {
                // Content request: respond with available data + wait for next
                self.respondContent(connection, start: rangeStart)
            }
        }
    }

    /// Respond to a small probe request (e.g., bytes=0-1).
    private func respondProbe(_ connection: NWConnection, start: Int, end: Int) {
        lock.lock()
        let totalAvailable = bufferTrimmed + buffer.count
        let localStart = start - bufferTrimmed
        let responseData: Data
        if localStart >= 0 && localStart < buffer.count {
            let localEnd = min(end + 1 - bufferTrimmed, buffer.count)
            responseData = buffer.subdata(in: localStart..<localEnd)
        } else {
            responseData = Data(count: end - start + 1)
        }
        lock.unlock()

        let actualEnd = start + responseData.count - 1
        let header = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes \(start)-\(actualEnd)/\(declaredSize)\r\nContent-Length: \(responseData.count)\r\nAccept-Ranges: bytes\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(responseData)

        #if DEBUG
        print("[LocalAudioServer] Probe: 206 bytes \(start)-\(actualEnd) (\(responseData.count)B)")
        #endif

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard error == nil else { return }
            self?.readRequest(connection)
        })
    }

    /// Respond to a content request with all available data from the given offset.
    /// After sending, waits for the next request (mediaserverd will re-request
    /// from where we left off).
    private func respondContent(_ connection: NWConnection, start: Int) {
        lock.lock()
        let localStart = start - bufferTrimmed
        let responseData: Data
        if localStart >= 0 && localStart < buffer.count {
            responseData = buffer.subdata(in: localStart..<buffer.count)
        } else if localStart >= buffer.count {
            // No new data yet — wait briefly then try again
            lock.unlock()
            connectionQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.respondContent(connection, start: start)
            }
            return
        } else {
            responseData = Data()
        }

        // Trim buffer: keep only last 64KB for potential re-reads
        let totalSent = start + responseData.count
        let safeToTrim = totalSent - bufferTrimmed - 65536
        if safeToTrim > 0 && safeToTrim < buffer.count {
            buffer = buffer.subdata(in: safeToTrim..<buffer.count)
            bufferTrimmed += safeToTrim
        }
        lock.unlock()

        guard !responseData.isEmpty else {
            // Edge case: data was trimmed, can't serve
            readRequest(connection)
            return
        }

        let actualEnd = start + responseData.count - 1
        let header = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes \(start)-\(actualEnd)/\(declaredSize)\r\nContent-Length: \(responseData.count)\r\nAccept-Ranges: bytes\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(responseData)

        #if DEBUG
        print("[LocalAudioServer] Content: 206 bytes \(start)-\(actualEnd) (\(responseData.count)B), buffer=\(buffer.count + bufferTrimmed)B")
        #endif

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                #if DEBUG
                print("[LocalAudioServer] Send error: \(error!)")
                #endif
                return
            }
            self?.readRequest(connection)
        })
    }
}
