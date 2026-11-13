import Testing
import Foundation
@testable import AetherEngine

/// #177 issue 1: the ingest segment loop awaited each fetch fully before starting the next,
/// so every segment paid a connection + TTFB round-trip with no bytes flowing and the
/// producer could not get ahead of the playhead on high-bitrate live streams. The loop now
/// runs a bounded prefetch pipeline: up to `maxConcurrentSegmentFetches` fetches in flight,
/// committed to the FIFO strictly in playlist order.
///
/// The loopback origin adds per-segment latency and records how many segment requests are
/// being served concurrently. Serial fetch never exceeds 1; the pipeline must overlap
/// (>= 2) while staying inside its window (<= 4). Byte order in the FIFO stays playlist
/// order even when a slow segment completes after its successors.
@Suite("HLS live ingest bounded prefetch (#177)", .offCooperativePool, .timeLimit(.minutes(3)))
struct Issue177IngestPrefetchTests {

    // MARK: - Loopback HLS origin

    /// Minimal HTTP/1.1 origin on 127.0.0.1 serving one media playlist and its TS segments,
    /// one connection per request (Connection: close). Segment responses are delayed by a
    /// per-index latency before the first body byte to model TTFB; an in-flight counter
    /// captures the concurrency high-water mark.
    private final class LoopbackHLSOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener
        private let firstPlaylist: Data
        private let finalPlaylist: Data
        private let segments: [Data]
        private let delaysMs: [Int]
        private let lock = NSLock()
        private var _playlistRequests = 0
        private var _inFlight = 0
        private var _highWater = 0

        var concurrencyHighWater: Int {
            lock.lock(); defer { lock.unlock() }
            return _highWater
        }

        /// The first playlist response advertises only `initialWindow` segments without ENDLIST
        /// (the join takes the last few per the tracker's edge policy); every later response
        /// advertises all segments with ENDLIST, so the refresh delivers one large fresh batch.
        init?(segments: [Data], delaysMs: [Int], initialWindow: Int) {
            self.segments = segments
            self.delaysMs = delaysMs

            func playlist(count: Int, endList: Bool) -> Data {
                var lines = [
                    "#EXTM3U",
                    "#EXT-X-VERSION:3",
                    "#EXT-X-TARGETDURATION:1",
                    "#EXT-X-MEDIA-SEQUENCE:0",
                ]
                for index in 0..<count {
                    lines.append("#EXTINF:1.0,")
                    lines.append("seg\(index).ts")
                }
                if endList { lines.append("#EXT-X-ENDLIST") }
                return Data(lines.joined(separator: "\n").utf8)
            }
            firstPlaylist = playlist(count: initialWindow, endList: false)
            finalPlaylist = playlist(count: segments.count, endList: true)

            guard let listener = LoopbackListener(backlog: 16) else { return nil }
            self.listener = listener
            port = listener.port
            // The listener sets SO_NOSIGPIPE, or a hung-up peer takes the whole test process with
            // it: serve() parks in the scripted delay before it writes the body, and a cancelled or
            // drained fetch closes in exactly that window.
            listener.start { [weak self] conn in
                guard let self else { close(conn); return false }
                Thread.detachNewThread { [weak self] in
                    self?.serve(conn)
                }
                return true
            }
        }

        func stop() {
            listener.stop()
        }

        private func serve(_ conn: Int32) {
            defer { close(conn) }
            var request = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(conn, &buf, buf.count)
                guard n > 0 else { return }
                request.append(contentsOf: buf[0..<n])
                if request.count > 64 * 1024 { return }
            }
            guard let head = String(data: request, encoding: .utf8),
                  let requestLine = head.components(separatedBy: "\r\n").first else { return }
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else { return }
            let path = parts[1]

            let body: Data
            if path.hasSuffix("media.m3u8") {
                lock.lock()
                _playlistRequests += 1
                let isFirst = _playlistRequests == 1
                lock.unlock()
                body = isFirst ? firstPlaylist : finalPlaylist
            } else if let index = segmentIndex(for: path), segments.indices.contains(index) {
                lock.lock()
                _inFlight += 1
                _highWater = max(_highWater, _inFlight)
                lock.unlock()
                usleep(useconds_t(delaysMs[index] * 1000))
                body = segments[index]
                lock.lock()
                _inFlight -= 1
                lock.unlock()
            } else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = notFound.withCString { write(conn, $0, strlen($0)) }
                return
            }

            let header = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            _ = header.withCString { write(conn, $0, strlen($0)) }
            body.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(conn, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }

        private func segmentIndex(for path: String) -> Int? {
            guard let name = path.components(separatedBy: "/").last,
                  name.hasPrefix("seg"), name.hasSuffix(".ts") else { return nil }
            return Int(name.dropFirst(3).dropLast(3))
        }
    }

    /// A recognizable TS-shaped segment: valid sync bytes at 188-byte cadence, payload
    /// stamped with the segment index so FIFO ordering is checkable byte-for-byte.
    private func makeSegment(index: Int, packets: Int = 4) -> Data {
        var data = Data(capacity: packets * 188)
        for packet in 0..<packets {
            var ts = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 188)
            ts[0] = 0x47
            ts[1] = UInt8(truncatingIfNeeded: packet)
            data.append(contentsOf: ts)
        }
        return data
    }

    /// Returns the moment `expectedBytes` arrived (~0.5 s healthy). It has no deadline of its own:
    /// under parallel-suite starvation the tail segments can arrive tens of seconds late while the
    /// reader is perfectly healthy, and a 15 s cap turned exactly that into a byte-count flake
    /// (8/11 segments at deadline, CI 2026-07-21). The suite's `.timeLimit` is the hang catcher.
    private func drain(_ reader: HLSLiveIngestReader, expectedBytes: Int) async throws -> Data {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var done = false
        }
        let box = Box()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = buf.withUnsafeMutableBufferPointer {
                    reader.read($0.baseAddress, size: Int32($0.count))
                }
                if n <= 0 { break }
                box.lock.lock()
                box.data.append(contentsOf: buf[0..<Int(n)])
                let enough = box.data.count >= expectedBytes
                box.lock.unlock()
                if enough { break }
            }
            box.lock.lock()
            box.done = true
            box.lock.unlock()
        }
        try await waitFor { box.lock.withLock { box.done } }
        return box.lock.withLock { box.data }
    }

    // MARK: - Tests

    @Test("backlog fetches overlap within the window and commit in playlist order")
    func prefetchOverlapsAndPreservesOrder() async throws {
        // First playlist advertises seg0..7 (1 s segments, so the tracker's 8 s coverage target
        // wants the whole window and the eviction margin leaves the oldest, joining seg1..7); the
        // refresh advertises seg0..15 with ENDLIST, delivering seg8..15 as one 8-segment batch
        // that exercises the full prefetch window.
        let segmentCount = 16
        let segments = (0..<segmentCount).map { makeSegment(index: $0) }
        // Segment 9 is served far slower than its successors: with concurrent fetches,
        // seg10..seg12 complete first and must wait in the reorder window, not hit the FIFO.
        // 1500 ms (not a token 400 ms): seg9's serve window is what the overlap assertion
        // below measures, and on a starved CI runner the successor fetches' connection
        // threads can take hundreds of ms to get scheduled at all; a narrow window would
        // read high-water 1 on a correctly overlapping pipeline.
        var delays = [Int](repeating: 20, count: segmentCount)
        delays[5] = 50
        delays[9] = 1500
        let origin = try #require(LoopbackHLSOrigin(
            segments: segments, delaysMs: delays, initialWindow: 8))
        defer { origin.stop() }

        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.m3u8"))
        let reader = HLSLiveIngestReader(playlistURL: url)
        defer { reader.close() }

        #expect(reader.resolveSegmentFormatHint() == "mpegts")

        // Join takes seg1..7 per the tracker's edge policy, the refresh appends seg8..15.
        let expected = segments[1...].reduce(Data(), +)
        let got = try await drain(reader, expectedBytes: expected.count)

        #expect(reader.terminalError == nil)
        #expect(got == expected, "FIFO bytes must be exact playlist order regardless of completion order")

        // The load-bearing assertion: fetches actually overlapped (serial fetch = high water 1)
        // while staying inside the bounded window.
        #expect(origin.concurrencyHighWater >= 2, "segment fetches never overlapped; ingest is still serial")
        #expect(origin.concurrencyHighWater <= HLSLiveIngestReader.maxConcurrentSegmentFetches)
    }

    @Test("a declared single-request origin gets its segments one at a time (AE#678)")
    func declaredRequestCeilingSerializesTheBacklog() async throws {
        let segmentCount = 16
        let segments = (0..<segmentCount).map { makeSegment(index: $0) }
        var delays = [Int](repeating: 20, count: segmentCount)
        delays[9] = 400
        let origin = try #require(LoopbackHLSOrigin(
            segments: segments, delaysMs: delays, initialWindow: 8))
        defer { origin.stop() }

        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.m3u8"))
        OriginRequestBudget.shared.setHostLimit(1, for: url)
        defer { OriginRequestBudget.shared.setHostLimit(nil, for: url) }
        let reader = HLSLiveIngestReader(playlistURL: url)
        defer { reader.close() }

        let expected = segments[1...].reduce(Data(), +)
        let got = try await drain(reader, expectedBytes: expected.count)

        #expect(reader.terminalError == nil)
        #expect(got == expected)
        #expect(origin.concurrencyHighWater == 1, "the ingest overran the host's declared request ceiling")
    }

    @Test("the prefetch window narrows to the origin's request budget")
    func prefetchWindowFollowsTheBudget() {
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: nil) == 4)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 1) == 1)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 2) == 2)
        #expect(HLSLiveIngestReader.segmentFetchConcurrency(budgetLimit: 12) == 4)
    }

    @Test("single-segment playlists still ingest correctly through the pipeline")
    func singleSegmentStillWorks() async throws {
        let segments = [makeSegment(index: 7)]
        let origin = try #require(LoopbackHLSOrigin(
            segments: segments, delaysMs: [10], initialWindow: 1))
        defer { origin.stop() }

        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.m3u8"))
        let reader = HLSLiveIngestReader(playlistURL: url)
        defer { reader.close() }

        let got = try await drain(reader, expectedBytes: segments[0].count)
        #expect(reader.terminalError == nil)
        #expect(got == segments[0])
    }
}
