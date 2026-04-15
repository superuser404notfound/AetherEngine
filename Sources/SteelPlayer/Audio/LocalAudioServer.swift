import Foundation
import Network

/// Minimal local HTTP server that streams fMP4 audio to AVPlayer on tvOS.
///
/// ## Request Flow
///
/// 1. mediaserverd sends `Range: bytes=0-1` (probe)
///    → We respond 206 + 2 bytes, keep-alive for next request
/// 2. mediaserverd sends `Range: bytes=0-{big}` (stream)
///    → We respond 206 + Content-Length=2GB + keep connection OPEN
///    → Data is pushed continuously as it arrives from the demuxer
///
/// The streaming connection stays open for the entire playback session.
/// New fMP4 segments are sent via `send()` as the demux loop produces them.
final class LocalAudioServer: @unchecked Sendable {

    private var listener: NWListener?
    private let connectionQueue = DispatchQueue(label: "com.steelplayer.audioserver")

    private let lock = NSLock()

    /// fMP4 data buffer. Grows as packets arrive, trimmed after sending.
    private var buffer = Data()
    private var bufferTrimmed = 0

    /// Streaming state: the persistent connection to mediaserverd.
    private var streamConnection: NWConnection?
    private var streamActive = false
    private var streamSentOffset = 0  // Absolute bytes sent on stream
    private var isSending = false

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

    /// Queue fMP4 data. Sent immediately if stream connection is active.
    func send(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
        drainToStream()
    }

    func stop() {
        lock.lock()
        buffer = Data()
        bufferTrimmed = 0
        streamActive = false
        isSending = false
        lock.unlock()

        streamConnection?.cancel()
        streamConnection = nil
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state {
                self?.lock.lock()
                if self?.streamConnection === connection {
                    self?.streamActive = false
                }
                self?.lock.unlock()
            }
        }
        connection.start(queue: connectionQueue)
        readRequest(connection)
    }

    private func readRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard let self = self, error == nil, let data = content,
                  let request = String(data: data, encoding: .utf8) else { return }

            let lines = request.components(separatedBy: "\r\n")

            // Parse Range header
            var rangeStart = 0
            var rangeEnd: Int? = nil
            for line in lines {
                if line.lowercased().hasPrefix("range:") {
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

            let isProbe = (rangeEnd != nil && rangeEnd! < 1024)

            #if DEBUG
            let first = lines.first ?? ""
            print("[LocalAudioServer] \(first) → \(isProbe ? "probe" : "stream")")
            #endif

            if isProbe {
                self.respondProbe(connection, start: rangeStart, end: rangeEnd!)
            } else {
                self.startStreaming(connection, start: rangeStart)
            }
        }
    }

    // MARK: - Probe Response

    private func respondProbe(_ connection: NWConnection, start: Int, end: Int) {
        lock.lock()
        let localStart = max(0, start - bufferTrimmed)
        let localEnd = min(end + 1 - bufferTrimmed, buffer.count)
        let responseData: Data
        if localStart < buffer.count && localEnd > localStart {
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
            // Keep-alive: read next request on same connection
            self?.readRequest(connection)
        })
    }

    // MARK: - Streaming Response

    /// Start the persistent streaming connection. Header + available data sent,
    /// then new data pushed continuously via drainToStream().
    private func startStreaming(_ connection: NWConnection, start: Int) {
        let rangeEnd = declaredSize - 1
        let contentLength = declaredSize - start

        let header = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes \(start)-\(rangeEnd)/\(declaredSize)\r\nContent-Length: \(contentLength)\r\nAccept-Ranges: bytes\r\n\r\n"

        lock.lock()
        // Gather all available data from the requested offset
        let localStart = max(0, start - bufferTrimmed)
        var payload = Data(header.utf8)
        if localStart < buffer.count {
            payload.append(buffer.subdata(in: localStart..<buffer.count))
        }
        // Mark this as the active stream connection
        streamConnection = connection
        streamActive = true
        streamSentOffset = bufferTrimmed + buffer.count  // Next byte to send
        isSending = true  // We're about to send
        lock.unlock()

        #if DEBUG
        print("[LocalAudioServer] Stream: 206 bytes \(start)-\(rangeEnd), initial \(payload.count)B (header+data)")
        #endif

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            self?.lock.lock()
            self?.isSending = false
            self?.lock.unlock()

            if let error = error {
                #if DEBUG
                print("[LocalAudioServer] Stream send error: \(error)")
                #endif
                return
            }

            #if DEBUG
            print("[LocalAudioServer] Stream started, pushing data continuously")
            #endif

            // Start the continuous send loop
            self?.drainToStream()
        })
    }

    /// Push any new data to the active stream connection.
    /// Called after each `send()` and after each successful write.
    private func drainToStream() {
        lock.lock()
        guard streamActive, !isSending else {
            lock.unlock()
            return
        }

        // Calculate what's new since last send
        let localStart = streamSentOffset - bufferTrimmed
        guard localStart >= 0, localStart < buffer.count else {
            lock.unlock()
            return  // No new data yet
        }

        let dataToSend = buffer.subdata(in: localStart..<buffer.count)
        streamSentOffset = bufferTrimmed + buffer.count
        isSending = true

        // Trim old data we'll never need again (keep 64KB margin)
        let trimTo = streamSentOffset - bufferTrimmed - 65536
        if trimTo > 0 && trimTo < buffer.count {
            buffer = buffer.subdata(in: trimTo..<buffer.count)
            bufferTrimmed += trimTo
        }
        lock.unlock()

        guard let connection = streamConnection else {
            lock.lock()
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
                print("[LocalAudioServer] Stream error: \(error!)")
                #endif
                return
            }

            // Check if more data arrived while sending
            self?.drainToStream()
        })
    }
}
