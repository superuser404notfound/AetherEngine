import Foundation
import Testing
@testable import AetherEngine

@Suite("Controlled probe range growth (AE#927)")
struct ProbeRangeGrowthTests {
    private static let kib = 1024

    private func growth() -> ProbeRangeGrowth {
        ProbeRangeGrowth(floor: 64 * Self.kib, ceiling: 1024 * Self.kib)
    }

    @Test func contiguousFastRangesDoubleUpToTheCeiling() {
        var growth = growth()
        var offset: Int64 = 0
        var sizes: [Int] = []
        for _ in 0..<7 {
            let size = growth.size(at: offset, remainingInput: nil)
            sizes.append(size)
            growth.record(offset: offset, requested: size, received: size)
            offset += Int64(size)
        }
        #expect(sizes.map { $0 / Self.kib } == [64, 128, 256, 512, 1024, 1024, 1024])
    }

    @Test func aSeekStartsOverAtTheFloor() {
        var growth = growth()
        growth.record(offset: 0, requested: 512 * Self.kib, received: 512 * Self.kib)
        #expect(growth.size(at: Int64(512 * Self.kib), remainingInput: nil) == 1024 * Self.kib)
        #expect(growth.size(at: 50_000_000, remainingInput: nil) == 64 * Self.kib)
    }

    @Test func aShortBodyStartsOverAtTheFloor() {
        var growth = growth()
        growth.record(offset: 0, requested: 256 * Self.kib, received: 100)
        #expect(growth.size(at: 100, remainingInput: nil) == 64 * Self.kib)
    }

    @Test func aGrownRangeKeepsTheFloorRangesThroughputBudget() {
        let growth = growth()
        #expect(growth.budget(for: 64 * Self.kib, base: 2) == 2)
        #expect(growth.budget(for: 1024 * Self.kib, base: 2) == 32)
        #expect(growth.budget(for: 100, base: 2) == 2)
    }

    @Test func theRemainingInputBoundsARangeButNeverBelowTheFloor() {
        var growth = growth()
        growth.record(offset: 0, requested: 512 * Self.kib, received: 512 * Self.kib)
        let next = Int64(512 * Self.kib)
        #expect(growth.size(at: next, remainingInput: 300_000) == 300_000)
        #expect(growth.size(at: next, remainingInput: 10) == 64 * Self.kib)
    }

    /// The wiring: a controlled reader's sequential ranges grow, the uncontrolled default does not change.
    @Test func aControlledReaderAsksForGrowingRanges() throws {
        let data = Data((0..<(3 * 1024 * Self.kib)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let origin = try ProbeHTTPTestOrigin(data: data)
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/\(UUID().uuidString).ts"))
        let control = try ProbeControl(limits: .init(maxInputBytes: .max, timeBudget: 60), cancellation: nil)
        let reader = AVIOReader(
            url: url, chunkSize: 64 * Self.kib, prefetchEnabled: false,
            chunkRequestTimeout: 30, chunkMaxRetries: 1,
            probeControl: control, probeRangeCeiling: 1024 * Self.kib)
        defer {
            reader.markClosed()
            reader.finishProbeTransfers()
            reader.close()
            control.finish()
        }
        try reader.open()

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * Self.kib)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer {
                reader.read(into: $0.baseAddress!, size: Int32($0.count))
            }
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<Int(count)])
        }
        #expect(received == data)

        let lengths = origin.requests.compactMap(\.range).compactMap { range -> Int? in
            let bounds = range.dropFirst("bytes=".count).split(separator: "-")
            guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]) else { return nil }
            return end - start + 1
        }
        #expect(lengths.max() == 1024 * Self.kib, "ranges: \(lengths)")
        #expect(lengths.count <= 8, "3 MiB in 64 KiB ranges would be 48 requests: \(lengths)")
    }
}
