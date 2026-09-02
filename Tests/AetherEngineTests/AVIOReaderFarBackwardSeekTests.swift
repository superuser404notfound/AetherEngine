import Testing
import Foundation
@testable import AetherEngine

/// A far backward seek is a reposition, not the parse-time ping-pong the #69 detour cache protects.
/// The 6.60.0-atlas.5 device trace paid five 4 MB requests and 38.5 seconds before the pump finally
/// re-anchored at a target 48 GB behind its old window. Near and header-region reads remain detours.
@Suite("Far backward seek re-anchor")
struct AVIOReaderFarBackwardSeekTests {
    private static let megabyte: Int64 = 1024 * 1024
    private static let detourBytes: Int64 = 4 * megabyte

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
    }

    @discardableResult
    private func read(_ byteCount: Int, at offset: Int64, from reader: AVIOReader) -> Int {
        guard reader.seek(offset: offset, whence: SEEK_SET) == offset else { return 0 }
        let slice = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buffer.deallocate() }
        var total = 0
        while total < byteCount {
            let result = reader.read(into: buffer, size: Int32(min(slice, byteCount - total)))
            #expect(result > 0, "read stopped at \(total) of \(byteCount) bytes")
            guard result > 0 else { break }
            total += Int(result)
        }
        return total
    }

    private func requestLength(_ request: (path: String, start: Int64, end: Int64?)) -> Int64? {
        request.end.map { $0 - request.start + 1 }
    }

    @Test("a far backward read re-anchors with a pump range")
    func farBackwardReadReanchors() throws {
        let server = try #require(ThrottledOriginServer(
            totalSize: 200 * Self.megabyte,
            throttleUs: 0
        ))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        #expect(read(8 * Int(Self.megabyte), at: 150 * Self.megabyte, from: reader)
            == 8 * Int(Self.megabyte))
        let requestsBeforeSeek = server.requestLog.count
        #expect(read(8 * Int(Self.megabyte), at: 40 * Self.megabyte, from: reader)
            == 8 * Int(Self.megabyte))

        let requests = Array(server.requestLog.dropFirst(requestsBeforeSeek))
        #expect(requests.contains {
            $0.start == 40 * Self.megabyte
                && requestLength($0) == AVIOReader.persistentRangeBytes
        }, "no pump range started at the backward target: \(requests)")
        #expect(!requests.contains { requestLength($0) == Self.detourBytes },
                "far backward seek fetched a detour block: \(requests)")
    }

    @Test("a backward read in the header region remains a detour")
    func headerReadRemainsDetour() throws {
        let server = try #require(ThrottledOriginServer(
            totalSize: 200 * Self.megabyte,
            throttleUs: 0
        ))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        #expect(read(8 * Int(Self.megabyte), at: 150 * Self.megabyte, from: reader)
            == 8 * Int(Self.megabyte))
        let requestsBeforeSeek = server.requestLog.count
        #expect(read(Int(Self.megabyte), at: Self.megabyte, from: reader) == Int(Self.megabyte))

        let requests = Array(server.requestLog.dropFirst(requestsBeforeSeek))
        #expect(requests.contains { requestLength($0) == Self.detourBytes },
                "header read did not retain the 4 MB detour path: \(requests)")
    }

    @Test("a backward read within the detour span remains a detour")
    func nearbyReadRemainsDetour() throws {
        let server = try #require(ThrottledOriginServer(
            totalSize: 200 * Self.megabyte,
            throttleUs: 0
        ))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        #expect(read(8 * Int(Self.megabyte), at: 150 * Self.megabyte, from: reader)
            == 8 * Int(Self.megabyte))
        let requestsBeforeSeek = server.requestLog.count
        #expect(read(Int(Self.megabyte), at: 140 * Self.megabyte, from: reader) == Int(Self.megabyte))

        let requests = Array(server.requestLog.dropFirst(requestsBeforeSeek))
        #expect(requests.contains { requestLength($0) == Self.detourBytes },
                "nearby backward read did not retain the 4 MB detour path: \(requests)")
    }
}
