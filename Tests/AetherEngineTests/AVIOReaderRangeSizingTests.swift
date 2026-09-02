import Testing
import Foundation
@testable import AetherEngine

/// The 6.60.0-atlas.5 fill trace spent eighteen requests on 576 MB in 8.1 seconds. Completed
/// ranges now ask for about eight seconds of delivery, while the #310 backpressure path and a
/// genuinely slow origin retain the 32 MB request shape.
@Suite("Delivery-rate pump range sizing")
struct AVIOReaderRangeSizingTests {
    private static let megabyte: Int64 = 1024 * 1024

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
    }

    @discardableResult
    private func drain(_ byteCount: Int, from reader: AVIOReader) -> Int {
        let slice = 1024 * 1024
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

    private func dataRanges(
        _ server: ThrottledOriginServer,
        fileSize: Int64,
        dropping first: Int = 0
    ) -> [(start: Int64, end: Int64?)] {
        Array(server.requestedRanges.dropFirst(first)).filter {
            $0.start < fileSize - Self.megabyte
        }
    }

    private func length(_ range: (start: Int64, end: Int64?)) -> Int64? {
        range.end.map { $0 - range.start + 1 }
    }

    @Test("a fast fill grows ranges and needs at most six requests for 300 MB")
    func fastFillUsesFewerRanges() throws {
        let fileSize = 400 * Self.megabyte
        let server = try #require(ThrottledOriginServer(totalSize: fileSize, throttleUs: 0))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        #expect(drain(300 * Int(Self.megabyte), from: reader) == 300 * Int(Self.megabyte))

        let ranges = dataRanges(server, fileSize: fileSize)
        #expect(length(try #require(ranges.first)) == AVIOReader.persistentRangeBytes)
        #expect(ranges.dropFirst().allSatisfy {
            (length($0) ?? 0) >= AVIOReader.persistentRangeBytes
                && (length($0) ?? 0) <= 128 * Self.megabyte
        }, "adaptive range escaped its 32...128 MB belt: \(ranges)")
        #expect(ranges.count <= 6, "300 MB fill still used \(ranges.count) ranges: \(ranges)")
    }

    @Test("an origin below the 32 MB per-eight-second floor keeps every range at 32 MB")
    func slowOriginKeepsFloor() throws {
        let fileSize = 160 * Self.megabyte
        let server = try #require(ThrottledOriginServer(
            totalSize: fileSize,
            throttleUs: 80_000
        ))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        #expect(drain(70 * Int(Self.megabyte), from: reader) == 70 * Int(Self.megabyte))

        let ranges = dataRanges(server, fileSize: fileSize)
        #expect(ranges.count >= 3, "the read did not cross two range boundaries: \(ranges)")
        #expect(ranges.allSatisfy { length($0) == AVIOReader.persistentRangeBytes },
                "slow origin changed the 32 MB request shape: \(ranges)")
    }

    @Test("a reopened reader starts at 32 MB and uses the remembered origin size second")
    func reopenedReaderUsesRememberedSize() throws {
        let fileSize = 400 * Self.megabyte
        let server = try #require(ThrottledOriginServer(totalSize: fileSize, throttleUs: 0))
        defer { server.stop() }

        let firstReader = makeReader(server)
        try firstReader.open()
        firstReader.markOpenPhaseFinished()
        #expect(drain(40 * Int(Self.megabyte), from: firstReader) == 40 * Int(Self.megabyte))
        let firstRanges = dataRanges(server, fileSize: fileSize)
        let remembered = try #require(firstRanges.dropFirst().compactMap(length).first)
        #expect(remembered > AVIOReader.persistentRangeBytes)
        firstReader.markClosed()
        firstReader.close()

        let requestsBeforeReopen = server.requestedRanges.count
        let secondReader = makeReader(server)
        defer { secondReader.markClosed(); secondReader.close() }
        try secondReader.open()
        secondReader.markOpenPhaseFinished()
        #expect(drain(40 * Int(Self.megabyte), from: secondReader) == 40 * Int(Self.megabyte))

        let reopened = dataRanges(server, fileSize: fileSize, dropping: requestsBeforeReopen)
        #expect(length(try #require(reopened.first)) == AVIOReader.persistentRangeBytes)
        #expect(length(try #require(reopened.dropFirst().first)) == remembered,
                "reopen forgot \(remembered / Self.megabyte) MB: \(reopened)")
    }
}
