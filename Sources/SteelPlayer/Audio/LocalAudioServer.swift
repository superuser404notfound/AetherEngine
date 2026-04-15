import Foundation
import Network

/// Minimal local HTTP server that streams fMP4 audio data to AVPlayer.
///
/// On tvOS, AVPlayer's media server (mediaserverd) runs out-of-process.
/// Custom URL schemes fail (-1002), and chunked encoding causes immediate
/// disconnect. The approach that works: standard HTTP/1.1 response with a
/// large Content-Length, serving data as progressive download. mediaserverd
/// starts playback while data is still arriving.
final class LocalAudioServer: @unchecked Sendable {

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "com.steelplayer.audioserver")

    private let lock = NSLock()
    private var headerSent = false
    private var pendingData = Data()
    private var isSending = false

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

    /// Send fMP4 data to the connected AVPlayer.
    func send(_ data: Data) {
        lock.lock()
        pendingData.append(data)
        lock.unlock()
        drainPending()
    }

    func stop() {
        lock.lock()
        pendingData = Data()
        headerSent = false
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
        activeConnection?.cancel()
        activeConnection = connection

        lock.lock()
        headerSent = false
        isSending = false
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            #if DEBUG
            if case .failed(let error) = state {
                print("[LocalAudioServer] Connection failed: \(error)")
            }
            #endif
            if case .cancelled = state {
                self?.lock.lock()
                self?.headerSent = false
                self?.isSending = false
                self?.lock.unlock()
            }
        }

        connection.start(queue: connectionQueue)

        // Read the full HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard error == nil else { return }

            #if DEBUG
            if let data = content, let request = String(data: data, encoding: .utf8) {
                // Log full request headers for debugging
                let lines = request.components(separatedBy: "\r\n")
                for line in lines.prefix(10) {
                    if line.isEmpty { break }
                    print("[LocalAudioServer] \(line)")
                }
            }
            #endif

            self?.sendHeaderAndInitialData(connection)
        }
    }

    private func sendHeaderAndInitialData(_ connection: NWConnection) {
        // Build HTTP response header.
        // Use a very large Content-Length so mediaserverd treats this as
        // a progressive download (starts playing while data arrives).
        // 2GB is large enough for any audio stream.
        let contentLength = 2_000_000_000
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: video/mp4",
            "Content-Length: \(contentLength)",
            "Accept-Ranges: none",
            "Cache-Control: no-cache",
            "",
            ""
        ].joined(separator: "\r\n")

        // Combine header + all pending data into ONE send.
        // Splitting them causes mediaserverd to close between sends.
        lock.lock()
        var payload = Data()
        payload.append(header.data(using: .utf8)!)
        payload.append(pendingData)
        let initialSize = pendingData.count
        pendingData = Data()
        headerSent = true
        lock.unlock()

        #if DEBUG
        print("[LocalAudioServer] Sending header + \(initialSize) bytes in one write")
        #endif

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error = error {
                #if DEBUG
                print("[LocalAudioServer] Initial send error: \(error)")
                #endif
                return
            }

            #if DEBUG
            print("[LocalAudioServer] Header + initial data sent successfully")
            #endif

            // Send any data that arrived while we were sending
            self?.drainPending()
        })
    }

    private func drainPending() {
        lock.lock()
        guard headerSent, !isSending, !pendingData.isEmpty else {
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
