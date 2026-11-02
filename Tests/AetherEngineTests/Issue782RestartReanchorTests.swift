import Testing
import Foundation
@testable import AetherEngine

/// AE#782: a producer restart behind the reader's window used to be served as serial 4 MB detour
/// blocks until 8 MB of it had gone by, which is the parse-read policy (#69), not playback's. A
/// restart now tells the reader, and the first backward read it cannot serve from memory anchors the
/// streaming connection at the landing.
@Suite("AE#782 restart re-anchors at the landing", .offCooperativePool)
struct Issue782RestartReanchorTests {

    private static let chunk = 256 * 1024

    /// The detour fetch's 4 s interactive budget is a wall clock: on a loaded runner a 4 MB block
    /// missed it, fell through to the rescue reconnect AT the landing, and the parse-read assertions
    /// read that as the AE#782 anchor. The policy under test is where the read goes, not how fast.
    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!, detourFetchBudget: 30)
    }

    private func readForward(_ reader: AVIOReader, _ buf: UnsafeMutablePointer<UInt8>, bytes: Int) -> Bool {
        var read = 0
        while read < bytes {
            let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
            if n <= 0 { return false }
            read += n
        }
        return true
    }

    private func matchesPattern(_ buf: UnsafeMutablePointer<UInt8>, count: Int, at offset: Int64) -> Bool {
        (0..<count).allSatisfy { buf[$0] == ThrottledOriginServer.patternByte(at: offset + Int64($0)) }
    }

    @Test("a backward read after a playback reposition opens the connection there, not a detour block",
          .timeLimit(.minutes(2)))
    func repositionAnchorsAtLanding() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        #expect(readForward(reader, buf, bytes: 13 * 1024 * 1024))

        let landing: Int64 = 5 * 1024 * 1024 + 4321
        #expect(reader.seek(offset: landing, whence: Int32(SEEK_SET)) == landing)
        reader.notePlaybackRepositioned()
        let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
        #expect(n > 0)
        #expect(matchesPattern(buf, count: n, at: landing), "the landing served the wrong bytes")

        #expect(reader.detourResidentBlocksForTesting == 0, "the landing was served as a detour block")
        #expect(server.requestedRanges.contains { $0.start == landing },
                "no connection was anchored at the landing: \(server.requestedRanges.map(\.start))")
    }

    @Test("without the reposition the same read is still a detour, so the parse-read policy is unchanged",
          .timeLimit(.minutes(2)))
    func parseReadStillDetours() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        #expect(readForward(reader, buf, bytes: 13 * 1024 * 1024))

        let landing: Int64 = 5 * 1024 * 1024 + 4321
        #expect(reader.seek(offset: landing, whence: Int32(SEEK_SET)) == landing)
        #expect(reader.read(into: buf, size: Int32(Self.chunk)) > 0)
        #expect(reader.detourResidentBlocksForTesting == 1)
        #expect(!server.requestedRanges.contains { $0.start == landing })
    }

    @Test("a resident detour block still serves the landing, and the first miss past it anchors",
          .timeLimit(.minutes(2)))
    func residentBlockServesFirst() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        #expect(readForward(reader, buf, bytes: 13 * 1024 * 1024))

        // An earlier scrub left block 1 (4 to 8 MB) resident.
        #expect(reader.seek(offset: 4 * 1024 * 1024, whence: Int32(SEEK_SET)) == 4 * 1024 * 1024)
        #expect(reader.read(into: buf, size: Int32(Self.chunk)) > 0)
        #expect(reader.detourResidentBlocksForTesting == 1)
        let requestsBefore = server.requestedRanges.count

        let landing: Int64 = 6 * 1024 * 1024
        #expect(reader.seek(offset: landing, whence: Int32(SEEK_SET)) == landing)
        reader.notePlaybackRepositioned()
        #expect(reader.read(into: buf, size: Int32(Self.chunk)) > 0)
        #expect(server.requestedRanges.count == requestsBefore, "a resident landing went to the network")

        #expect(readForward(reader, buf, bytes: 3 * 1024 * 1024))
        let blockEnd: Int64 = 8 * 1024 * 1024
        #expect(server.requestedRanges.contains { $0.start == blockEnd },
                "the first miss past the resident block did not anchor there: \(server.requestedRanges.map(\.start))")
        #expect(!server.requestedRanges.contains { $0.start == blockEnd && $0.end == blockEnd + 4 * 1024 * 1024 - 1 },
                "the first miss past the resident block was fetched as a detour block")
    }
}
