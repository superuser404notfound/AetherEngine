import CommonCrypto
import Foundation
import XCTest
import Testing
@testable import AetherEngine

/// AE#732: under `heldSourceConnection` the HLS VOD ingest carries its playlist, probe and segment
/// requests over one persistent HTTP/1.1 connection per origin, across segment boundaries.
final class Issue732PersistentHTTP1Tests: XCTestCase {

    func testReaderCarriesPlaylistProbeAndEverySegmentOverOneConnection() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<5).map { "seg\($0).ts" }
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return .init(body: Self.transportStream(marker: UInt8(index)))
        }

        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"),
            httpHeaders: ["X-Fixture": "allowed"],
            persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        let stream = await Self.offPool { Self.drain(reader) }
        XCTAssertEqual(stream.count, 5 * 188 * 3)
        XCTAssertEqual((0..<5).map { stream[$0 * 188 * 3 + Self.markerOffset] }, [0, 1, 2, 3, 4])

        let log = server.requests
        XCTAssertEqual(server.connectionCount, 1, "every request rides the first connection")
        // The probe downloaded segment 0 whole, so the producer does not ask for it again.
        XCTAssertEqual(log.map(\.path), ["/vod.m3u8"] + segments.map { "/" + $0 })
        XCTAssertTrue(log.allSatisfy { $0.requestLine.hasSuffix(" HTTP/1.1") })
        XCTAssertTrue(log.allSatisfy { $0.headers["range"] == nil })
        XCTAssertTrue(log.allSatisfy { $0.headers["x-fixture"] == "allowed" })
    }

    func testReaderSurvivesASeekThatCancelsAFetchMidBody() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<6).map { "seg\($0).ts" }
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            // Segment 2 trickles, so the seek below lands while it is mid-body.
            return .init(body: Self.transportStream(marker: UInt8(index)), trickleUs: index == 2 ? 200_000 : 0)
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        // Into segment 2's body, so the seek lands mid-body rather than before its response head.
        let lead = await Self.offPool { Self.readBytes(reader, count: 7 * 188) }

        XCTAssertEqual(lead.count, 7 * 188)
        XCTAssertEqual(lead[6 * 188 + Self.markerOffset], 2, "the seventh packet is segment 2's first")

        let sought = await Self.offPool { reader.seek(to: 26) }

        XCTAssertTrue(sought) // segment 4 contains 26 s, the restart is one earlier
        let stream = await Self.offPool { Self.drain(reader) }
        XCTAssertEqual(stream.count, 3 * 188 * 3)
        XCTAssertEqual(stream[Self.markerOffset], 3)
        XCTAssertEqual(server.connectionCount, 1, "the short remainder was drained and the socket kept")
        XCTAssertEqual(server.maxInFlight, 1, "the next request waited for the drain")
        XCTAssertEqual(server.requests.map(\.path), ["/vod.m3u8", "/seg0.ts", "/seg1.ts", "/seg2.ts", "/seg3.ts", "/seg4.ts", "/seg5.ts"])
    }

    func testSlowSegmentReachesTheReaderBeforeItsDownloadEnds() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = ["seg0.ts", "seg1.ts"]
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return index == 0
                ? .init(body: Self.transportStream(marker: 0))
                : .init(body: Self.transportStream(marker: 1, packets: 600), trickleUs: 5_000)
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        let (buffer, got) = await Self.offPool { () -> ([UInt8], Int) in
            var buffer = [UInt8](repeating: 0, count: 188 * 4)
            var got = 0
            while got < buffer.count {
                let n = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress! + got, size: Int32(188 * 4 - got)) }
                XCTAssertGreaterThan(n, 0)
                if n <= 0 { break }
                got += Int(n)
            }
            return (buffer, got)
        }
        XCTAssertEqual(buffer[188 * 3], 0x47, "the first packet of segment 1 is in the reader")
        XCTAssertFalse(server.completed.contains("/seg1.ts"), "while segment 1 is still downloading")

        let rest = await Self.offPool { Self.drain(reader) }
        XCTAssertEqual(got + rest.count, 3 * 188 + 600 * 188)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testProbeLeavesTheFirstSegmentOpenInsteadOfDownloadingIt() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = ["seg0.ts", "seg1.ts"]
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return index == 0
                ? .init(body: Self.transportStream(marker: 0, packets: 400), trickleUs: 5_000)
                : .init(body: Self.transportStream(marker: 1))
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }
        XCTAssertFalse(server.completed.contains("/seg0.ts"), "the verdict did not wait for the whole segment")

        let stream = await Self.offPool { Self.drain(reader) }
        XCTAssertEqual(stream.count, 400 * 188 + 3 * 188)
        XCTAssertEqual(stream[Self.markerOffset], 0)
        XCTAssertEqual(stream[400 * 188 + Self.markerOffset], 1)
        XCTAssertEqual(server.requests.map(\.path), ["/vod.m3u8", "/seg0.ts", "/seg1.ts"])
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testSeekOverALargeRemainderClosesTheConnection() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<5).map { "seg\($0).ts" }
        // 12,000 packets is about 2.2 MB, over the drain budget.
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return index == 1
                ? .init(body: Self.transportStream(marker: 1, packets: 12_000), trickleUs: 2_000)
                : .init(body: Self.transportStream(marker: UInt8(index)))
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        let headCount = await Self.offPool { Self.readPacket(reader) }

        XCTAssertEqual(headCount, 188)
        try await waitUntil { server.requests.contains { $0.path == "/seg1.ts" } }
        let seekStarted = Date()
        let sought = await Self.offPool { reader.seek(to: 20) }
        XCTAssertTrue(sought) // segment 3 contains 20 s, the restart is one earlier
        let stream = await Self.offPool { Self.drain(reader) }
        XCTAssertLessThan(Date().timeIntervalSince(seekStarted), 2, "the seek did not wait for a drain")
        XCTAssertEqual(stream.count, 3 * 188 * 3)
        XCTAssertEqual(stream[Self.markerOffset], 2)
        XCTAssertEqual(server.connectionCount, 2)
    }

    func testSlowRemainderClosesAtOnceInsteadOfDraining() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<5).map { "seg\($0).ts" }
        // Inside the drain budget by size, but at 10 ms a packet its rest needs seconds.
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return index == 1
                ? .init(body: Self.transportStream(marker: 1, packets: 1_000), trickleUs: 10_000)
                : .init(body: Self.transportStream(marker: UInt8(index)))
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        let headCount = await Self.offPool { Self.readPacket(reader) }

        XCTAssertEqual(headCount, 188)
        try await waitUntil { server.requests.contains { $0.path == "/seg1.ts" } }
        try await Task.sleep(nanoseconds: 500_000_000) // long enough for the body to show its rate
        let seekStarted = Date()
        let sought = await Self.offPool { reader.seek(to: 20) }
        XCTAssertTrue(sought)
        let stream = await Self.offPool { Self.drain(reader) }
        XCTAssertLessThan(Date().timeIntervalSince(seekStarted), 1.5, "no drain that could not finish")
        XCTAssertEqual(stream.count, 3 * 188 * 3)
        XCTAssertEqual(stream[Self.markerOffset], 2)
        XCTAssertEqual(server.connectionCount, 2)
    }

    func testHeadReadsAreClampedToTheDeadline() {
        XCTAssertEqual(PersistentHTTP1Connection.headReadTimeout(left: 40, readTimeout: 30, lateReadSpent: false), 30)
        XCTAssertEqual(PersistentHTTP1Connection.headReadTimeout(left: 2, readTimeout: 30, lateReadSpent: false), 2)
    }

    func testADeadlineSpentWaitingForAThreadStillReadsTheSocketOnce() {
        // A pool that held this task past the deadline (CI: a 70 s stall) must not refuse a head that
        // arrived in time. One short read, then the deadline holds.
        XCTAssertEqual(PersistentHTTP1Connection.headReadTimeout(left: -20, readTimeout: 30, lateReadSpent: false),
                       PersistentHTTP1Connection.lateHeadReadTimeout)
        XCTAssertNil(PersistentHTTP1Connection.headReadTimeout(left: -20, readTimeout: 30, lateReadSpent: true))
        XCTAssertNil(PersistentHTTP1Connection.headReadTimeout(left: 0, readTimeout: 30, lateReadSpent: true))
    }

    func testDrainPastItsDeadlineClosesAndTheNextRequestGoesAhead() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<5).map { "seg\($0).ts" }
        // One packet short, then silent: drainable at any rate the seek could measure, however late
        // a loaded runner gets to it, so only the drain deadline ends it. A larger remainder turns
        // undrainable once the seek comes more than a few hundred ms after the body began.
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return index == 1
                ? .init(body: Self.transportStream(marker: 1, packets: 101), stallAfter: 188 * 100)
                : .init(body: Self.transportStream(marker: UInt8(index)))
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        // Read into segment 1, not just until the server saw its request: a seek that lands before the
        // client has the response head closes the connection at once instead of draining it (CI: 0.002 s).
        let lead = await Self.offPool { Self.readBytes(reader, count: 4 * 188) }

        XCTAssertEqual(lead.count, 4 * 188)
        XCTAssertEqual(lead[3 * 188 + Self.markerOffset], 1, "the fourth packet is segment 1's first")
        let seekStarted = Date()
        let sought = await Self.offPool { reader.seek(to: 20) }
        XCTAssertTrue(sought)
        let stream = await Self.offPool { Self.drain(reader) }
        let waited = Date().timeIntervalSince(seekStarted)
        XCTAssertGreaterThanOrEqual(waited, PersistentHTTP1Transport.drainDeadline - 0.2)
        XCTAssertLessThan(waited, PersistentHTTP1Transport.drainDeadline + 2)
        XCTAssertEqual(stream.count, 3 * 188 * 3)
        XCTAssertEqual(stream[Self.markerOffset], 2)
        XCTAssertEqual(server.connectionCount, 2)
    }

    func testSeekOntoAnEncryptedSegmentLetsTheProbeResponseGo() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let key = Data((0..<16).map { UInt8($0) })
        let clear = (0..<5).map { Self.transportStream(marker: UInt8($0)) }
        let encrypted = clear.map { Self.aes128CBC($0, key: key) }
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n"
        for index in 0..<5 {
            if index == 2 {
                text += "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000000\n"
            }
            text += "#EXTINF:6,\nseg\(index).ts\n"
        }
        let playlist = Data((text + "#EXT-X-ENDLIST").utf8)
        // Segment 0 is large and slow, so its probe response is still open when the seek lands.
        let first = Self.transportStream(marker: 0, packets: 2_000)
        server.route = { path in
            switch path {
            case "/vod.m3u8": return .init(body: playlist)
            case "/key.bin": return .init(body: key)
            case "/seg0.ts": return .init(body: first, trickleUs: 2_000)
            default:
                guard let index = Int(path.dropFirst(4).dropLast(3)), (1..<5).contains(index) else {
                    return .init(status: 404)
                }
                return .init(body: index >= 2 ? encrypted[index] : clear[index])
            }
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        let sought = await Self.offPool { reader.seek(to: 20) }

        XCTAssertTrue(sought) // segment 3 contains 20 s; the restart is 2, the first encrypted one
        let done = expectation(description: "drained")
        let box = StreamBox()
        Thread.detachNewThread {
            box.bytes = Self.drain(reader)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(box.bytes.count, 3 * 188 * 3)
        XCTAssertEqual(box.bytes.first.map { _ in box.bytes[Self.markerOffset] }, 2)
    }

    func testFullBufferLetsTheCurrentSegmentFinishAndHoldsTheNextRequest() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<3).map { "seg\($0).ts" }
        // 12 MB of segment 0 plus 5.6 MB of segment 1: the 16 MB FIFO fills inside segment 1.
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return .init(body: Self.transportStream(marker: UInt8(index), packets: index == 0 ? 64_000 : 30_000))
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        let headCount = await Self.offPool { Self.readPacket(reader) }

        XCTAssertEqual(headCount, 188)
        try await waitUntil { server.completed.contains("/seg1.ts") }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(server.requests.contains { $0.path == "/seg2.ts" }, "the next request waits for the reader")

        let rest = await Self.offPool { Self.drain(reader) }
        XCTAssertEqual(188 + rest.count, (64_000 + 30_000 + 30_000) * 188)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testASegmentTakenWholeJustUnderTheCeilingStillHoldsTheNextRequest() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<3).map { "seg\($0).ts" }
        // Segment 0 stops 45 KB short of the 16 MB ceiling, so segment 1 (56 KB, one chunk) is taken
        // whole while the FIFO is under it and lands it over: full, with nothing left in flight.
        server.route = { path in
            if path == "/vod.m3u8" { return .init(body: Self.mediaPlaylist(segments)) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else { return .init(status: 404) }
            return .init(body: Self.transportStream(marker: UInt8(index), packets: index == 0 ? 89_000 : 300))
        }
        let made = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true)
        let reader = try XCTUnwrap(made)
        defer { reader.close() }

        let headCount = await Self.offPool { Self.readPacket(reader) }

        XCTAssertEqual(headCount, 188)
        try await waitUntil { server.completed.contains("/seg1.ts") }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(server.requests.contains { $0.path == "/seg2.ts" }, "the next request waits for the reader")

        let rest = await Self.offPool { Self.drain(reader) }
        XCTAssertEqual(188 + rest.count, (89_000 + 300 + 300) * 188)
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testStalledBodyFailsWithWhatHadArrived() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        server.route = { _ in .init(body: Data(count: 5000), stallAfter: 1000) }
        let transport = PersistentHTTP1Transport(label: "test", readTimeout: 0.5)
        defer { transport.close() }

        do {
            _ = try await transport.get(server.url("/stall"), headers: [:], limit: 1 << 20)
            XCTFail("a stalled body completed")
        } catch let error as PersistentHTTP1Connection.ConnectionError {
            guard case .stalled = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("1000/5000 bytes"), error.localizedDescription)
        }
    }

    func testSteadySlowBodyIsNeverCutOff() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        // 80 packets 50 ms apart: four seconds in all, against a read timeout of 1 s. The margin is
        // per gap, and a starved CI runner stretched one 50 ms gap past the 0.3 s this used to allow.
        let body = Self.transportStream(marker: 7, packets: 80)
        server.route = { _ in .init(body: body, trickleUs: 50_000) }
        let transport = PersistentHTTP1Transport(label: "test", readTimeout: 1)
        defer { transport.close() }

        let answer = try await transport.get(server.url("/slow"), headers: [:], limit: 1 << 20)
        XCTAssertEqual(answer.body, body)
    }

    func testServerCloseOpensAFreshConnection() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        server.route = { path in .init(body: Data(path.utf8), connectionClose: path == "/b") }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        for path in ["/a", "/b", "/c", "/d"] {
            let answer = try await transport.get(server.url(path), headers: [:], limit: 1024)
            XCTAssertEqual(answer.response.statusCode, 200)
            XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), path)
        }
        XCTAssertEqual(server.requests.map(\.connection), [1, 1, 2, 2])
    }

    func testIdleConnectionDroppedByTheOriginIsRetriedOnce() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        // Hangs up after every response without saying so, which is what an origin's idle timeout
        // looks like to the next request on that connection.
        server.route = { path in .init(body: Data(path.utf8), silentClose: true) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        for path in ["/a", "/b", "/c"] {
            let answer = try await transport.get(server.url(path), headers: [:], limit: 1024)
            XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), path)
        }
        XCTAssertEqual(server.requests.map(\.path), ["/a", "/b", "/c"])
        XCTAssertEqual(server.connectionCount, 3)
    }

    func testChunkedBodyIsDecodedAndKeepsTheConnection() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let body = Data((0..<5000).map { UInt8($0 & 0xFF) })
        server.route = { _ in .init(body: body, chunked: true) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        for _ in 0..<3 {
            let answer = try await transport.get(server.url("/c"), headers: [:], limit: 1 << 20)
            XCTAssertEqual(answer.body, body)
        }
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testChunkedReadsKeepFramingAcrossCancellationHandlers() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        let expected = Data((0..<5000).map { UInt8($0 & 0xFF) })
        server.route = { _ in .init(body: expected, chunked: true) }
        let url = server.url("/chunked")
        let origin = try XCTUnwrap(PersistentHTTP1Transport.Origin(url))
        let connection = PersistentHTTP1Connection(origin: origin, label: "isolation")
        defer { connection.retire(reason: "test finished") }
        let head = try await connection.sendRequest(target: url, headers: [:])
        var framing = PersistentHTTP1Connection.framing(for: head)
        var received = Data()

        while true {
            let current = framing
            let (chunk, advanced) = try await withTaskCancellationHandler {
                try await connection.readChunk(current, progress: { "\(received.count) bytes" })
            } onCancel: {
                connection.retire(reason: "test cancelled")
            }
            framing = advanced
            guard let chunk else { break }
            received.append(chunk)
        }

        XCTAssertEqual(received, expected)
        XCTAssertNil(PersistentHTTP1Connection.reuseRefusal(head, framing))
    }

    func testRefusalKeepsTheConnectionAndReportsItsStatus() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        server.route = { path in path == "/denied" ? .init(status: 403, body: Data("no".utf8)) : .init(body: Data("ok".utf8)) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        let refused = try await transport.get(server.url("/denied"), headers: [:], limit: 1024)
        XCTAssertEqual(refused.response.statusCode, 403)
        XCTAssertTrue(refused.body.isEmpty)
        let served = try await transport.get(server.url("/fine"), headers: [:], limit: 1024)
        XCTAssertEqual(served.body, Data("ok".utf8))
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testBodyOverTheLimitIsRefused() async throws {
        let server = try XCTUnwrap(KeepAliveOrigin())
        defer { server.stop() }
        server.route = { _ in .init(body: Data(count: 4096)) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        do {
            _ = try await transport.get(server.url("/big"), headers: [:], limit: 1024)
            XCTFail("a 4 KB body passed a 1 KB limit")
        } catch let error as BoundedFetch.Exceeded {
            XCTAssertEqual(error.limit, 1024)
        }
    }

    func testCrossOriginRedirectKeepsOneConnectionPerOriginAndDropsCredentials() async throws {
        let cdn = try XCTUnwrap(KeepAliveOrigin())
        defer { cdn.stop() }
        let edge = try XCTUnwrap(KeepAliveOrigin())
        defer { edge.stop() }
        cdn.route = { path in .init(body: Data(path.utf8)) }
        edge.route = { path in .init(status: 302, headers: ["Location": cdn.url(path).absoluteString]) }
        let transport = PersistentHTTP1Transport(label: "test")
        defer { transport.close() }

        for path in ["/1.ts", "/2.ts", "/3.ts"] {
            let answer = try await transport.get(
                edge.url(path), headers: ["Authorization": "secret", "X-Plain": "kept"], limit: 1024)
            XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), path)
            XCTAssertEqual(answer.response.url, cdn.url(path))
        }
        XCTAssertEqual(edge.connectionCount, 1)
        XCTAssertEqual(cdn.connectionCount, 1)
        XCTAssertTrue(edge.requests.allSatisfy { $0.headers["authorization"] == "secret" })
        XCTAssertTrue(cdn.requests.allSatisfy { $0.headers["authorization"] == nil })
        XCTAssertTrue(cdn.requests.allSatisfy { $0.headers["x-plain"] == "kept" })
    }

    func testWholeResourceRequestCarriesNoRange() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example/api/ts?url=a%2Fb.ts"))
        let text = String(decoding: try HeldSourceConnection.requestBytes(
            target: url, host: "media.example", port: 443, secure: true,
            offset: nil, extraHeaders: [:], userAgent: nil), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /api/ts?url=a%2Fb.ts HTTP/1.1\r\nHost: media.example\r\n"))
        XCTAssertFalse(text.lowercased().contains("range:"))
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
    }

    // MARK: - Helpers

    static let markerOffset = 100

    fileprivate static func mediaPlaylist(_ segments: [String]) -> Data {
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n"
        for segment in segments { text += "#EXTINF:6,\n\(segment)\n" }
        return Data((text + "#EXT-X-ENDLIST").utf8)
    }

    /// TS packets whose first PMT declares HEVC (0x24); the marker sits in the PMT packet's filler.
    fileprivate static func transportStream(marker: UInt8, packets: Int = 3) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188 * packets)
        for packet in 0..<packets {
            bytes[packet * 188] = 0x47
            bytes[packet * 188 + 3] = 0x10
        }
        let pmt: [UInt8] = [0x40, 0x64, 0x10, 0, 0x02, 0xB0, 18, 0, 1, 0xC1, 0, 0,
                            0xE1, 0, 0xF0, 0, 0x24, 0xE1, 1, 0xF0, 0]
        bytes.replaceSubrange(1..<(1 + pmt.count), with: pmt)
        bytes[markerOffset] = marker
        return Data(bytes)
    }

    private final class StreamBox: @unchecked Sendable {
        var bytes: [UInt8] = []
    }

    fileprivate static func aes128CBC(_ data: Data, key: Data) -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let iv = Data(count: kCCBlockSizeAES128)
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count, outBytes.baseAddress, outCapacity, &written)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return out.prefix(written)
    }

    /// `read` and `seek` wait on the producer, and the producer runs on the cooperative pool. Called
    /// straight from an async test body they held that pool's thread, which under
    /// LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 is its only one, and the test deadlocked.
    private static func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: body()) }
        }
    }

    private static func readPacket(_ reader: HLSVODIngestReader) -> Int32 {
        var head = [UInt8](repeating: 0, count: 188)
        return head.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 188) }
    }

    private static func readBytes(_ reader: HLSVODIngestReader, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 188)
        while out.count < count {
            let want = Int32(min(buffer.count, count - out.count))
            let got = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: want) }
            if got <= 0 { return out }
            out += buffer[0..<Int(got)]
        }
        return out
    }

    private static func drain(_ reader: HLSVODIngestReader) -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 4096) }
            if count <= 0 { return out }
            out += buffer[0..<Int(count)]
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met in \(timeout) s") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// A loopback HTTP/1.1 origin that keeps connections alive and records which connection carried
/// each request.
final class KeepAliveOrigin: @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var chunked = false
        /// Answers with `Connection: close` and hangs up.
        var connectionClose = false
        /// Hangs up after the response without announcing it.
        var silentClose = false
        /// Sends the body one 188-byte packet per interval.
        var trickleUs: useconds_t = 0
        /// Sends this many body bytes, then nothing more until the origin stops.
        var stallAfter: Int?

        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(),
             chunked: Bool = false, connectionClose: Bool = false, silentClose: Bool = false,
             trickleUs: useconds_t = 0, stallAfter: Int? = nil) {
            self.status = status
            self.headers = headers
            self.body = body
            self.chunked = chunked
            self.connectionClose = connectionClose
            self.silentClose = silentClose
            self.trickleUs = trickleUs
            self.stallAfter = stallAfter
        }
    }

    struct Request {
        let connection: Int
        let path: String
        let requestLine: String
        let headers: [String: String]
    }

    private let listener: LoopbackListener
    private let lock = NSLock()
    private var _route: @Sendable (String) -> Reply = { _ in Reply(status: 404) }
    private var _requests: [Request] = []
    private var _connections = 0
    private var _completed: [String] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _fds: [Int32] = []
    private var stopped = false

    init?() {
        guard let listener = LoopbackListener() else { return nil }
        self.listener = listener
        listener.start { [self] fd in admit(fd) }
    }

    var route: @Sendable (String) -> Reply {
        get { lock.withLock { _route } }
        set { lock.withLock { _route = newValue } }
    }

    var requests: [Request] { lock.withLock { _requests } }
    var connectionCount: Int { lock.withLock { _connections } }
    /// Paths whose whole response went out.
    var completed: [String] { lock.withLock { _completed } }
    /// Most responses in progress at once, across connections.
    var maxInFlight: Int { lock.withLock { _maxInFlight } }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port)\(path)")!
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        for fd in _fds { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        if !already { listener.stop() }
    }

    private func admit(_ fd: Int32) -> Bool {
        lock.lock()
        if stopped {
            lock.unlock()
            close(fd)
            return false
        }
        _connections += 1
        let id = _connections
        _fds.append(fd)
        lock.unlock()
        Thread.detachNewThread { [self] in serve(fd, id: id) }
        return true
    }

    private func serve(_ fd: Int32, id: Int) {
        defer {
            lock.lock()
            _fds.removeAll { $0 == fd }
            close(fd)
            lock.unlock()
        }
        var leftover = Data()
        while true {
            guard let (head, rest) = readHead(fd, leftover: leftover) else { return }
            leftover = rest
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? ""
            let parts = requestLine.components(separatedBy: " ")
            let path = parts.count >= 2 ? parts[1] : "?"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let route: @Sendable (String) -> Reply = lock.withLock {
                _requests.append(Request(connection: id, path: path, requestLine: requestLine, headers: headers))
                _inFlight += 1
                _maxInFlight = max(_maxInFlight, _inFlight)
                return _route
            }
            let reply = route(path)
            let sent = respond(fd, reply)
            lock.withLock {
                _inFlight -= 1
                if sent { _completed.append(path) }
            }
            if !sent || reply.connectionClose || reply.silentClose { return }
        }
    }

    private func respond(_ fd: Int32, _ reply: Reply) -> Bool {
        var head = "HTTP/1.1 \(reply.status) X\r\n"
        for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
        if reply.chunked {
            head += "Transfer-Encoding: chunked\r\n"
        } else {
            head += "Content-Length: \(reply.body.count)\r\n"
        }
        if reply.connectionClose { head += "Connection: close\r\n" }
        head += "\r\n"
        guard send(fd, Data(head.utf8)) else { return false }
        if reply.chunked {
            var offset = 0
            while offset < reply.body.count {
                let piece = reply.body[offset..<min(reply.body.count, offset + 1000)]
                guard send(fd, Data((String(piece.count, radix: 16) + "\r\n").utf8) + piece + Data("\r\n".utf8))
                else { return false }
                offset += piece.count
            }
            return send(fd, Data("0\r\n\r\n".utf8))
        }
        if let stallAfter = reply.stallAfter {
            guard send(fd, reply.body.prefix(stallAfter)) else { return false }
            while !lock.withLock({ stopped }) { usleep(20_000) }
            return false
        }
        guard reply.trickleUs > 0 else { return send(fd, reply.body) }
        var offset = 0
        while offset < reply.body.count {
            let end = min(reply.body.count, offset + 188)
            guard send(fd, reply.body[offset..<end]) else { return false }
            offset = end
            usleep(reply.trickleUs)
        }
        return true
    }

    private func readHead(_ fd: Int32, leftover: Data) -> (String, Data)? {
        var collected = leftover
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let terminator = Data("\r\n\r\n".utf8)
        while collected.range(of: terminator) == nil {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            collected.append(contentsOf: buffer[0..<n])
        }
        let split = collected.range(of: terminator)!
        return (String(decoding: collected[..<split.lowerBound], as: UTF8.self),
                Data(collected[split.upperBound...]))
    }

    private func send(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }
    }
}

@Suite("Persistent HLS segment-boundary admission", .serialized, .timeLimit(.minutes(3)))
struct PersistentHLSSegmentAdmissionTests {
    enum Exit: String, CaseIterable, Sendable { case consume, seek, close, cancel }

    @Test("a final chunk filling the FIFO holds the next request until consumption or retirement",
          arguments: Exit.allCases, [nil, 1, 2])
    func finalChunkAdmission(exit: Exit, encryptedFrom: Int?) async throws {
        let server = try #require(KeepAliveOrigin())
        defer { server.stop() }
        let segments = (0..<4).map { "seg\($0).ts" }
        // After the one 188-byte read below, these two segments leave 16,777,308 bytes:
        // just above the 16 MiB ceiling. The final offered chunk can empty `pending` while
        // filling the FIFO, which used to skip append() and start the next request. Encrypted from
        // segment 1, the filling segment arrives whole through append() instead of stream().
        let packetCounts = [64_000, 25_242, 3, 3]
        let key = Data(repeating: 0x43, count: 16)
        var playlist = String(decoding: Issue732PersistentHTTP1Tests.mediaPlaylist(segments), as: UTF8.self)
        if let encryptedFrom {
            playlist = playlist.replacingOccurrences(of: "#EXTINF:6,\nseg\(encryptedFrom).ts",
                with: "#EXT-X-KEY:METHOD=AES-128,URI=\"/key\",IV=0x00000000000000000000000000000000\n#EXTINF:6,\nseg\(encryptedFrom).ts")
        }
        // The key is fetched before its first segment, so it only marks an escape when that is seg2.
        let nextRequest: @Sendable (KeepAliveOrigin.Request) -> Bool = { request in
            request.path == "/seg2.ts" || (encryptedFrom == 2 && request.path == "/key")
        }
        let playlistBody = Data(playlist.utf8)
        server.route = { path in
            if path == "/vod.m3u8" {
                return .init(body: playlistBody)
            }
            if path == "/key" { return .init(body: key) }
            guard let index = segments.firstIndex(where: { "/" + $0 == path }) else {
                return .init(status: 404)
            }
            let clear = Issue732PersistentHTTP1Tests.transportStream(
                marker: UInt8(index), packets: packetCounts[index])
            return .init(body: encryptedFrom.map { index >= $0 } == true
                ? Issue732PersistentHTTP1Tests.aes128CBC(clear, key: key) : clear)
        }
        // The factory turns a probe error into nil and only logs it. CI declined under load (main
        // d6c46ee6, deeed435) and nothing said why, so a failure carries the logged reason. The capture
        // is process-wide, so it filters on the factory's own decline line: the [HLSVODIngest] prefix
        // alone came back as six "resolved" lines from other tests. No line means a non-HEVC verdict.
        let log = EngineLogCapture()
        defer { log.end() }
        let reader = try #require(try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: server.url("/vod.m3u8"), httpHeaders: [:], persistentHTTP1: true),
            "declined: \(log.matching("carriage probe inconclusive"))")
        defer { reader.close() }
        let firstRead = ProbeTestJob { () -> Int32 in
            var bytes = [UInt8](repeating: 0, count: 188)
            return bytes.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 188) }
        }
        #expect(try await firstRead.outcome().get() == 188)
        try await waitFor { server.completed.contains("/seg1.ts") }
        let escaped = try await waitFor(upTo: .milliseconds(500)) {
            server.requests.contains(where: nextRequest)
        }
        #expect(!escaped, "the final chunk must not bypass the next request's admission")

        switch exit {
        case .consume: break
        case .seek: #expect(reader.seek(to: 20)) // starts at segment 2, before the containing segment 3
        case .close: reader.close()
        case .cancel: reader.cancel()
        }
        let drain = ProbeTestJob { () -> (bytes: Int, marker: UInt8?, terminal: Int32) in
            var bytes = [UInt8](repeating: 0, count: 4096)
            var total = 0
            var marker: UInt8?
            while true {
                let n = bytes.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 4096) }
                if n <= 0 { return (total, marker, n) }
                if marker == nil, n > Issue732PersistentHTTP1Tests.markerOffset {
                    marker = bytes[Issue732PersistentHTTP1Tests.markerOffset]
                }
                total += Int(n)
            }
        }
        let result = try await drain.outcome().get()
        switch exit {
        case .consume:
            #expect(result.bytes + 188 == packetCounts.reduce(0, +) * 188)
            #expect(result.terminal == 0)
        case .seek:
            #expect(result.bytes == 6 * 188)
            #expect(result.marker == 2)
            #expect(result.terminal == 0)
        case .close, .cancel:
            #expect(result.bytes == 0)
            #expect(result.terminal == -1)
            let lateRequest = try await waitFor(upTo: .milliseconds(500)) {
                server.requests.contains(where: nextRequest)
            }
            #expect(!lateRequest, "a retired producer must not issue the next request")
        }
        if exit == .consume || exit == .seek {
            #expect(server.requests.filter { $0.path == "/seg2.ts" }.count == 1)
            // The seek abandons seg1's body, and a drain that misses `drainDeadline` closes the socket
            // by design. A starved runner gets there (CI read 2 here), so only consumption pins reuse.
            #expect(server.connectionCount <= (exit == .seek ? 2 : 1))
            #expect(server.maxInFlight == 1)
        }
    }
}
