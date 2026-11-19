import Testing
import Foundation
@testable import AetherEngine

/// AE#1090: `LoadOptions.liveJoinsAtPlaylistStart` joins a live ingest at the oldest listed segment
/// ("start from the beginning" on a recording in progress). The join delivers the same few seconds an
/// edge join would at once and the backlog behind them at 1x, so the session downstream sees an
/// ordinary live source that happens to be that far behind the edge.
@Suite("Live ingest join at the playlist start (AE#1090)", .offCooperativePool, .timeLimit(.minutes(3)))
struct Issue1090LiveJoinAtPlaylistStartTests {

    private func playlist(sequence: Int, count: Int, duration: Double = 1) -> HLSMediaPlaylist {
        HLSMediaPlaylist(
            targetDuration: duration,
            mediaSequence: sequence,
            segments: (0..<count).map {
                HLSMediaSegment(uri: "seg\(sequence + $0).ts", duration: duration, discontinuityBefore: false)
            },
            hasEndList: false,
            isEncrypted: false,
            hasUnsupportedEncryption: false,
            hasMap: false
        )
    }

    @Test("the option is off by default and composes with the other live options")
    func optionDefault() {
        #expect(LoadOptions().liveJoinsAtPlaylistStart == false)
        let options = LoadOptions(isLive: true, dvrWindowSeconds: 4 * 3600, liveJoinsAtPlaylistStart: true)
        #expect(options.liveJoinsAtPlaylistStart)
    }

    // MARK: - Tracker

    @Test("the default join stays at the live edge")
    func defaultJoinIsAtTheEdge() {
        var tracker = HLSPlaylistTracker()
        let batch = tracker.newSegments(in: playlist(sequence: 0, count: 60))
        #expect(batch.first?.uri == "seg52.ts")
        #expect(batch.count == 8)
    }

    @Test("a playlist-start join takes the whole listing from MEDIA-SEQUENCE")
    func playlistStartTakesEverything() {
        var tracker = HLSPlaylistTracker(joinPoint: .playlistStart)
        let batch = tracker.newSegments(in: playlist(sequence: 40, count: 60))
        #expect(batch.count == 60)
        #expect(batch.first?.uri == "seg40.ts")
        #expect(batch.first?.discontinuityBefore == false)
        #expect(tracker.lastBatchFirstSequence == 40)
        #expect(tracker.lastBatchRejoinedAtEdge == false)

        // The next refresh continues from the cursor like any live session.
        let next = tracker.newSegments(in: playlist(sequence: 40, count: 62))
        #expect(next.map(\.uri) == ["seg100.ts", "seg101.ts"])
        #expect(tracker.lastBatchFirstSequence == 100)
    }

    @Test("a reopen resumes at its sequence, or the oldest listed one once that is gone")
    func sequenceResume() {
        var inside = HLSPlaylistTracker(joinPoint: .sequence(70))
        #expect(inside.newSegments(in: playlist(sequence: 40, count: 60)).first?.uri == "seg70.ts")
        #expect(inside.lastBatchFirstSequence == 70)

        var slid = HLSPlaylistTracker(joinPoint: .sequence(30))
        #expect(slid.newSegments(in: playlist(sequence: 40, count: 60)).first?.uri == "seg40.ts")
        #expect(slid.lastBatchFirstSequence == 40)
    }

    @Test("a resume point not listed yet waits for it instead of replaying")
    func resumeAheadOfTheListingWaits() {
        var tracker = HLSPlaylistTracker(joinPoint: .sequence(105))
        #expect(tracker.newSegments(in: playlist(sequence: 40, count: 60)).isEmpty)
        let next = tracker.newSegments(in: playlist(sequence: 40, count: 67))
        #expect(next.map(\.uri) == ["seg105.ts", "seg106.ts"])
    }

    @Test("a window that slides past the cursor rejoins at the edge and says so")
    func slideRejoinIsFlagged() {
        var tracker = HLSPlaylistTracker(joinPoint: .playlistStart)
        _ = tracker.newSegments(in: playlist(sequence: 0, count: 10))
        #expect(tracker.lastBatchRejoinedAtEdge == false)
        let rejoin = tracker.newSegments(in: playlist(sequence: 30, count: 10))
        #expect(!rejoin.isEmpty)
        #expect(rejoin.first?.discontinuityBefore == true)
        #expect(tracker.lastBatchRejoinedAtEdge)
        let next = tracker.newSegments(in: playlist(sequence: 31, count: 10))
        #expect(next.count == 1)
        #expect(tracker.lastBatchRejoinedAtEdge == false)
    }

    @Test("the burst is the edge join's coverage counted from the front")
    func burstDepth() {
        // 1 s segments: 8 s of coverage at a limit of 8.
        #expect(HLSPlaylistTracker.behindEdgeJoinBurstDepth(
            durations: Array(repeating: 1, count: 60), coverage: 8, limit: 8) == 8)
        // 6 s segments: 6 + 6 = 12 meets 10.
        #expect(HLSPlaylistTracker.behindEdgeJoinBurstDepth(
            durations: Array(repeating: 6, count: 60), coverage: 10, limit: 8) == 2)
        // The count limit wins over coverage, and a listing shorter than both is taken whole.
        #expect(HLSPlaylistTracker.behindEdgeJoinBurstDepth(
            durations: Array(repeating: 1, count: 60), coverage: 20, limit: 8) == 8)
        #expect(HLSPlaylistTracker.behindEdgeJoinBurstDepth(
            durations: [2, 2], coverage: 8, limit: 8) == 2)
    }

    // MARK: - Pacer

    @Test("segments inside the lead are due at once, later ones at 1x")
    func pacerSchedule() {
        var pacer = LiveBacklogPacer(anchor: 100, leadSeconds: 8)
        let due = (0..<12).map { _ in pacer.dueTime(forNextSegmentOfDuration: 1) }
        #expect(due.prefix(8).allSatisfy { $0 == 100 })
        #expect(due[8] == 101)
        #expect(due[11] == 104)
        #expect(pacer.scheduledEndSeconds == 12)
    }

    @Test("a malformed duration does not move the schedule")
    func pacerIgnoresBadDurations() {
        var pacer = LiveBacklogPacer(anchor: 0, leadSeconds: 2)
        _ = pacer.dueTime(forNextSegmentOfDuration: .nan)
        _ = pacer.dueTime(forNextSegmentOfDuration: -3)
        #expect(pacer.scheduledEndSeconds == 0)
        #expect(pacer.dueTime(forNextSegmentOfDuration: 3) == 1)
    }

    // MARK: - Reader against a loopback origin

    /// Serves one fixed live listing (no ENDLIST) of 1 s segments from MEDIA-SEQUENCE 0 and records
    /// when each segment was asked for.
    private final class RecordingOrigin: @unchecked Sendable {
        let port: UInt16
        private let listener: LoopbackListener
        private let playlist: Data
        private let segments: [Data]
        private let lock = NSLock()
        private var _requests: [(index: Int, at: Date)] = []

        var segmentRequests: [(index: Int, at: Date)] { lock.withLock { _requests } }

        init?(segments: [Data]) {
            self.segments = segments
            var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:1", "#EXT-X-MEDIA-SEQUENCE:0"]
            for index in segments.indices {
                lines.append("#EXTINF:1.0,")
                lines.append("seg\(index).ts")
            }
            playlist = Data(lines.joined(separator: "\n").utf8)
            guard let listener = LoopbackListener(backlog: 16) else { return nil }
            self.listener = listener
            port = listener.port
            listener.start { [weak self] conn in
                guard let self else { close(conn); return false }
                Thread.detachNewThread { [weak self] in self?.serve(conn) }
                return true
            }
        }

        func stop() { listener.stop() }

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
                  let path = head.components(separatedBy: "\r\n").first?.components(separatedBy: " ").dropFirst().first
            else { return }
            let body: Data
            if path.hasSuffix("media.m3u8") {
                body = playlist
            } else if let name = path.components(separatedBy: "/").last, name.hasPrefix("seg"), name.hasSuffix(".ts"),
                      let index = Int(name.dropFirst(3).dropLast(3)), segments.indices.contains(index) {
                lock.withLock { _requests.append((index, Date())) }
                body = segments[index]
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
    }

    private func makeSegment(index: Int) -> Data {
        var data = Data(capacity: 4 * 188)
        for packet in 0..<4 {
            var ts = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 188)
            ts[0] = 0x47
            ts[1] = UInt8(truncatingIfNeeded: packet)
            data.append(contentsOf: ts)
        }
        return data
    }

    /// Reads the reader on its own thread until it is closed.
    private final class Drain: @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()
        var data: Data { lock.withLock { _data } }

        init(_ reader: HLSLiveIngestReader) {
            Thread.detachNewThread { [self] in
                var buf = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32($0.count)) }
                    if n <= 0 { break }
                    lock.withLock { _data.append(contentsOf: buf[0..<Int(n)]) }
                }
            }
        }
    }

    @Test("the reader starts at segment 0, delivers the burst at once and the backlog at 1x")
    func readerPacesTheBacklog() async throws {
        let segments = (0..<60).map(makeSegment)
        let origin = try #require(RecordingOrigin(segments: segments))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.m3u8"))
        let reader = HLSLiveIngestReader(playlistURL: url)
        reader.setJoinsAtPlaylistStart(true)
        defer { reader.close() }

        #expect(reader.resolveSegmentFormatHint() == "mpegts")
        let drain = Drain(reader)
        let burstBytes = segments.prefix(8).reduce(0) { $0 + $1.count }
        try await waitFor { drain.data.count >= burstBytes }
        #expect(drain.data.prefix(burstBytes) == segments.prefix(8).reduce(Data(), +))
        #expect(reader.joinBacklogSeconds == 8)

        // Wait until the pacer has released a few segments past the burst. No deadline of its own: a
        // starved runner only makes this later, and the suite's time limit catches a hang.
        try await waitFor { origin.segmentRequests.contains { $0.index >= 11 } }
        let requests = origin.segmentRequests
        let joinedAt = try #require(requests.first { $0.index == 0 }?.at)
        // Segment k (k >= 8) is due k - 7 s after the join, and the join began just before segment 0
        // was asked for. Load can only make a request LATER, so this lower bound holds on any runner;
        // unpaced, the whole listing would have been asked for within a fraction of a second.
        for request in requests where request.index >= 8 {
            let earliest = Double(request.index - 7) - 0.25
            #expect(request.at.timeIntervalSince(joinedAt) >= earliest,
                    "segment \(request.index) fetched \(request.at.timeIntervalSince(joinedAt))s after the join")
        }

        // Delivered bytes are in playlist order from segment 0.
        let delivered = drain.data
        #expect(delivered == segments.prefix(delivered.count / segments[0].count).reduce(Data(), +))
    }

    @Test("a reopen of a session behind the edge resumes after the last delivered segment")
    func reopenResumes() async throws {
        let segments = (0..<60).map(makeSegment)
        let origin = try #require(RecordingOrigin(segments: segments))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.m3u8"))
        let reader = HLSLiveIngestReader(playlistURL: url)
        reader.setJoinsAtPlaylistStart(true)
        defer { reader.close() }

        // Before anything is delivered a reopen joins where the first reader did.
        #expect(reader.makeFreshMainReader()?.joinPoint == .playlistStart)

        let drain = Drain(reader)
        let burstBytes = segments.prefix(8).reduce(0) { $0 + $1.count }
        try await waitFor { drain.data.count >= burstBytes }
        // Bounds from what was read and fetched, not from the clock: the pacer keeps filling the FIFO
        // while a starved drain thread or test task sleeps, so on a loaded runner the resume point
        // has run past any fixed cap (CI read more than 12). A segment counts as delivered once it is
        // in the FIFO, so it is at least what the drain read and at most one past the last fetch.
        let drained = drain.data.count / segments[0].count
        guard case .sequence(let resume)? = reader.makeFreshMainReader()?.joinPoint else {
            Issue.record("reopen did not resume at a sequence")
            return
        }
        let lastFetched = try #require(origin.segmentRequests.map(\.index).max())
        #expect(resume >= max(8, drained), "resume \(resume), drained \(drained)")
        #expect(resume <= lastFetched + 1, "resume \(resume), last fetched \(lastFetched)")

        // An edge session's reopen stays at the edge.
        let edge = HLSLiveIngestReader(playlistURL: url)
        #expect(edge.makeFreshMainReader()?.joinPoint == .liveEdge)
        edge.close()
    }
}
