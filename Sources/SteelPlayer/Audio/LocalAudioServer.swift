import Foundation
import Network

/// Minimal local HTTP server that streams fMP4 audio data to AVPlayer.
///
/// On tvOS, custom URL schemes don't work with AVPlayer because media
/// playback runs out-of-process (mediaserverd doesn't know custom schemes).
/// This server streams fMP4 over HTTP/1.1 with chunked transfer encoding,
/// which tells AVPlayer that more data is coming.
///
/// ## Why Chunked?
///
/// - HTTP/1.0 + `Connection: close` → AVPlayer reads data, assumes EOF, disconnects
/// - HTTP/1.1 + `Transfer-Encoding: chunked` → AVPlayer knows to keep reading
/// - Each chunk is: `{size_hex}\r\n{data}\r\n` — explicit framing
final class LocalAudioServer: @unchecked Sendable {

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "com.steelplayer.audioserver")

    private let lock = NSLock()
    private var headerSent = false
    private var pendingData = Data()
    private var isSending = false

    /// The port the server is listening on. 0 if not started.
    private(set) var port: UInt16 = 0

    /// The URL that AVPlayer should use to connect.
    var streamURL: URL? {
        port > 0 ? URL(string: "http://127.0.0.1:\(port)/audio.mp4") : nil
    }

    /// Start the server on a random available port.
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: .any)

        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = l.port?.rawValue ?? 0
                #if DEBUG
                print("[LocalAudioServer] Listening on port \(self?.port ?? 0)")
                #endif
            case .failed(let error):
                #if DEBUG
                print("[LocalAudioServer] Listener failed: \(error)")
                #endif
            default:
                break
            }
        }

        l.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        l.start(queue: connectionQueue)
        listener = l

        // Wait briefly for the listener to become ready
        for _ in 0..<50 {
            if port > 0 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Send fMP4 data to the connected AVPlayer.
    /// Data is wrapped in HTTP chunked encoding before sending.
    /// Can be called before AVPlayer connects — data is buffered.
    func send(_ data: Data) {
        lock.lock()
        pendingData.append(data)
        lock.unlock()
        drainPending()
    }

    /// Stop the server and close all connections.
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

        // Read the HTTP request (we don't parse it — just need to consume it)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard error == nil else { return }

            #if DEBUG
            if let data = content, let request = String(data: data, encoding: .utf8) {
                let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                print("[LocalAudioServer] Request: \(firstLine)")
            }
            #endif

            self?.sendHTTPHeader(connection)
        }
    }

    private func sendHTTPHeader(_ connection: NWConnection) {
        // HTTP/1.1 with chunked transfer encoding.
        // This tells AVPlayer to keep reading — more chunks will arrive.
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: video/mp4",
            "Transfer-Encoding: chunked",
            "Cache-Control: no-cache, no-store",
            "",
            ""  // Empty line ends headers
        ].joined(separator: "\r\n")

        connection.send(content: header.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error = error {
                #if DEBUG
                print("[LocalAudioServer] Header send error: \(error)")
                #endif
                return
            }

            self?.lock.lock()
            self?.headerSent = true
            self?.lock.unlock()

            #if DEBUG
            print("[LocalAudioServer] HTTP/1.1 chunked header sent")
            #endif

            self?.drainPending()
        })
    }

    /// Send buffered data as HTTP chunked encoding to the active connection.
    /// Format: `{size_hex}\r\n{data}\r\n`
    private func drainPending() {
        lock.lock()
        guard headerSent, !isSending, !pendingData.isEmpty else {
            lock.unlock()
            return
        }
        let rawData = pendingData
        pendingData = Data()
        isSending = true
        lock.unlock()

        guard let connection = activeConnection else {
            lock.lock()
            pendingData = rawData + pendingData
            isSending = false
            lock.unlock()
            return
        }

        // Wrap in chunked encoding: "{size_hex}\r\n{data}\r\n"
        let sizeStr = String(rawData.count, radix: 16)
        var chunk = Data()
        chunk.append(contentsOf: sizeStr.utf8)
        chunk.append(contentsOf: "\r\n".utf8)
        chunk.append(rawData)
        chunk.append(contentsOf: "\r\n".utf8)

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            self?.lock.lock()
            self?.isSending = false
            self?.lock.unlock()

            if error != nil {
                #if DEBUG
                print("[LocalAudioServer] Send error: \(error!)")
                #endif
                return
            }

            // Send more if data arrived while we were sending
            self?.drainPending()
        })
    }
}
