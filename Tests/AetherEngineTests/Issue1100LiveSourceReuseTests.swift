import Darwin
import Foundation
import Testing
@testable import AetherEngine

/// AE#1100: a live session must not open a one-shot live URL twice. An HDHomeRun tuner opened again
/// with the same `SessionID` replays that session from its start, so an audio switch or a reconnect
/// that reopened the loaded URL put the viewer minutes behind live.
@Suite(.serialized)
struct Issue1100LiveSourceReuseTests {

    // MARK: - The ring keeps every audio track apart

    @Test("the ring records each packet's stream and keeps its 24-byte record", .timeLimit(.minutes(3)))
    func ringRecordsStream() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae1100-ring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ring = try PacketRingBuffer(windowSeconds: 60, scratch: scratch, byteBudget: 64 << 20)
        defer { ring.close() }

        try ring.append(pts: 0, isKeyframe: true, isVideo: true, streamIndex: 0, bytes: Data([0]))
        try ring.append(pts: 0, isKeyframe: false, isVideo: false, streamIndex: 1, bytes: Data([1]))
        try ring.append(pts: 0, isKeyframe: false, isVideo: false, streamIndex: 2, bytes: Data([2]))
        try ring.append(pts: 0.03, isKeyframe: false, isVideo: false, bytes: Data([3]))

        #expect(ring.kind(atSeq: 0).map { [$0.isVideo ? 1 : 0, Int($0.streamIndex)] } == [1, 0])
        #expect(ring.kind(atSeq: 1)?.streamIndex == 1)
        #expect(ring.kind(atSeq: 2)?.streamIndex == 2)
        #expect(ring.kind(atSeq: 3)?.streamIndex == -1)
        #expect(ring.packet(atSeq: 2)?.streamIndex == 2)
        #expect(ring.packet(atSeq: 2)?.bytes == Data([2]))
        #expect(ring.kind(atSeq: 4) == nil)
        #expect(MemoryLayout<PacketRingBuffer.Entry>.stride == 24)
    }

    @Test("the feeder plays only the selected track, and an unnamed packet always", .timeLimit(.minutes(3)))
    func feederPicksTrack() {
        #expect(PacketRingBuffer.audioPacket(ofStream: 2, feeds: 2))
        #expect(!PacketRingBuffer.audioPacket(ofStream: 1, feeds: 2))
        #expect(PacketRingBuffer.audioPacket(ofStream: -1, feeds: 2))
    }

    @Test("the reader stores every other audio track that has a time base", .timeLimit(.minutes(3)))
    func alternateStreams() {
        let tracks: [(index: Int32, timeBaseSeconds: Double)] = [(1, 1.0 / 90000), (2, 1.0 / 90000), (3, 0)]
        #expect(LiveAudioSelection.alternateStreams(audioTracks: tracks, reference: 1) == [2: 1.0 / 90000])
        // No reference track: nothing to fold the others on, so nothing extra is stored.
        #expect(LiveAudioSelection.alternateStreams(audioTracks: tracks, reference: -1).isEmpty)
    }

    @Test("a swap is what the next snapshot reads", .timeLimit(.minutes(3)))
    func selectionSwap() {
        let selection = LiveAudioSelection(streamIndex: 1, decoder: nil, timeBaseSeconds: 1.0 / 90000)
        selection.replace(streamIndex: 2, decoder: nil, timeBaseSeconds: 1.0 / 48000)
        #expect(selection.snapshot.streamIndex == 2)
        #expect(selection.snapshot.timeBaseSeconds == 1.0 / 48000)
    }

    // MARK: - A dropped live connection reconnects on the host's URL

    /// HDHomeRun's shape: an unranged 200 with no length, so the first connection ends after
    /// `firstConnectionBytes` with a plain close, and every later one drips until the test stops.
    final class OneShotLiveOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener
        private let firstConnectionBytes: Int
        private let lock = NSLock()
        private var _targets: [String] = []
        private var _stopped = false

        init?(firstConnectionBytes: Int) {
            guard let listener = LoopbackListener() else { return nil }
            self.listener = listener
            self.port = listener.port
            self.firstConnectionBytes = firstConnectionBytes
            listener.start { [self] fd in
                Thread.detachNewThread { [self] in serve(fd) }
                return true
            }
        }

        var targets: [String] {
            lock.lock(); defer { lock.unlock() }
            return _targets
        }

        private var stopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return _stopped
        }

        func stop() {
            lock.lock(); _stopped = true; lock.unlock()
            listener.stop()
        }

        private func serve(_ fd: Int32) {
            defer { close(fd) }
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            var collected = Data()
            while collected.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { return }
                collected.append(contentsOf: buf[0..<n])
            }
            let line = String(decoding: collected, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.lock()
            let first = _targets.isEmpty
            _targets.append(target)
            lock.unlock()
            let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n"
            guard Self.writeAll(fd, Array(header.utf8)) else { return }
            let piece = [UInt8](repeating: 0x47, count: 16 * 1024)
            var sent = 0
            while !stopped {
                if first, sent >= firstConnectionBytes { return }
                guard Self.writeAll(fd, piece) else { return }
                sent += piece.count
                usleep(first ? 0 : 20_000)
            }
        }

        private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                guard n > 0 else { return false }
                off += n
            }
            return true
        }
    }

    /// Opens a live reader, reads past the first connection's end, and returns what the origin was asked.
    private static func targetsAfterReconnect(liveReopenURL: (@Sendable (URL) -> URL?)?) throws -> [String] {
        let firstBytes = 512 * 1024
        let origin = try #require(OneShotLiveOrigin(firstConnectionBytes: firstBytes))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/auto/v4.1?ClientID=1&SessionID=101")!
        let reader = AVIOReader(url: url, isLive: true, liveReopenURL: liveReopenURL)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let size = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        var total = 0
        let deadline = Date().addingTimeInterval(60)
        while total < firstBytes * 2, Date() < deadline {
            let n = reader.read(into: buf, size: Int32(size))
            if n > 0 { total += Int(n) }
        }
        #expect(total >= firstBytes * 2, "the reader never got past the dropped connection")
        return origin.targets
    }

    @Test("a live reconnect asks the host for the URL", .timeLimit(.minutes(3)))
    func reconnectUsesHostURL() throws {
        let targets = try Self.targetsAfterReconnect(liveReopenURL: { url in
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.queryItems = [URLQueryItem(name: "ClientID", value: "1"),
                                 URLQueryItem(name: "SessionID", value: "102")]
            return parts?.url
        })
        #expect(targets.count >= 2)
        #expect(targets.first?.contains("SessionID=101") == true)
        #expect(targets.dropFirst().allSatisfy { $0.contains("SessionID=102") }, "\(targets)")
    }

    @Test("without a hook the reconnect reopens the loaded URL", .timeLimit(.minutes(3)))
    func reconnectWithoutHookKeepsURL() throws {
        let targets = try Self.targetsAfterReconnect(liveReopenURL: nil)
        #expect(targets.count >= 2)
        #expect(targets.allSatisfy { $0.contains("SessionID=101") }, "\(targets)")
    }
}
