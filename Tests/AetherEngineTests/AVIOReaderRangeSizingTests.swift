import Testing
import Foundation
@testable import AetherEngine

/// The 6.60.0-atlas.7 fill trace spent three 128 MB requests in 5.5 seconds before the first
/// refusal, then steady playback reached 17 requests per minute. Completed fills now ask for the
/// file remainder, while a fast VOD window refills as one 128 MB request after backpressure.
@Suite("Delivery-rate pump range sizing")
struct AVIOReaderRangeSizingTests {
    private static let megabyte: Int64 = 1024 * 1024

    private struct WindowRow: Sendable, CustomStringConvertible {
        let name: String
        let deliveryBytesPerSecond: Double
        let isLive: Bool
        let fileSize: Int64
        let expectedHigh: Int
        let expectedLow: Int

        var description: String { name }
    }

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

    private func waitUntil(
        _ timeout: Duration = .seconds(8),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "condition did not become true within \(timeout)")
    }

    @Test("a fast completed range asks for the file remainder")
    func fastFillUsesFileRemainder() throws {
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
        let fill = try #require(ranges.dropFirst().first)
        #expect(length(fill) == fileSize - fill.start,
                "fast fill did not ask through the file end: \(ranges)")
    }

    @Test("the range calculation keeps its 32 MB floor and 2 GiB sanity bound")
    func rangeCalculationBounds() {
        #expect(AVIOReader.rangeSizeForDeliveryRate(
            deliveredBytes: Self.megabyte,
            deliverySeconds: 8
        ) == AVIOReader.persistentRangeBytes)
        #expect(AVIOReader.rangeSizeForDeliveryRate(
            deliveredBytes: Self.megabyte,
            deliverySeconds: 0
        ) == 2 * 1024 * Self.megabyte)
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

    @Test("only known-size fast VOD raises the session window", arguments: [
        WindowRow(
            name: "below threshold",
            deliveryBytesPerSecond: 12.5 * Double(Self.megabyte) - 1,
            isLive: false,
            fileSize: 400 * Self.megabyte,
            expectedHigh: 16 * Int(Self.megabyte),
            expectedLow: 8 * Int(Self.megabyte)
        ),
        WindowRow(
            name: "at threshold",
            deliveryBytesPerSecond: 12.5 * Double(Self.megabyte),
            isLive: false,
            fileSize: 400 * Self.megabyte,
            expectedHigh: 128 * Int(Self.megabyte),
            expectedLow: 64 * Int(Self.megabyte)
        ),
        WindowRow(
            name: "live",
            deliveryBytesPerSecond: 12.5 * Double(Self.megabyte),
            isLive: true,
            fileSize: 400 * Self.megabyte,
            expectedHigh: 64 * Int(Self.megabyte),
            expectedLow: 8 * Int(Self.megabyte)
        ),
        WindowRow(
            name: "unknown size",
            deliveryBytesPerSecond: 12.5 * Double(Self.megabyte),
            isLive: false,
            fileSize: 0,
            expectedHigh: 16 * Int(Self.megabyte),
            expectedLow: 8 * Int(Self.megabyte)
        ),
    ])
    private func fastOriginWindowTruthTable(_ row: WindowRow) {
        let window = AVIOReader.fastOriginWindow(
            deliveryBytesPerSecond: row.deliveryBytesPerSecond,
            isLive: row.isLive,
            fileSize: row.fileSize
        )
        #expect(window.high == row.expectedHigh)
        #expect(window.low == row.expectedLow)
    }

    @Test("a fast VOD backpressure end refills one 128 MB window")
    func fastOriginBackpressureRefillsWindow() async throws {
        let fileSize = 1024 * Self.megabyte
        let server = try #require(ThrottledOriginServer(
            totalSize: fileSize,
            throttleUs: 4_000
        ))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        #expect(drain(40 * Int(Self.megabyte), from: reader) == 40 * Int(Self.megabyte))
        try await waitUntil {
            reader.windowDiagnostics.parked
        }

        let rangesBeforeRefill = dataRanges(server, fileSize: fileSize).count
        #expect(drain(96 * Int(Self.megabyte), from: reader) == 96 * Int(Self.megabyte))
        try await waitUntil {
            self.dataRanges(server, fileSize: fileSize).count > rangesBeforeRefill
        }

        let refill = try #require(
            dataRanges(server, fileSize: fileSize).dropFirst(rangesBeforeRefill).first
        )
        #expect(length(refill) == 128 * Self.megabyte,
                "backpressure refill was not one high-water request: \(refill)")
    }
}
