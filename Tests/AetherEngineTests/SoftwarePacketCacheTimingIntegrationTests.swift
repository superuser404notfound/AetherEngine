import Foundation
import Testing
@testable import AetherEngine

@Suite("Qualified cache timing integration", .offCooperativePool, .timeLimit(.minutes(3)))
struct SoftwarePacketCacheTimingIntegrationTests {
    private final class Timing: SoftwarePacketCacheTimingSource, @unchecked Sendable {
        let lock = NSLock()
        var records: [SoftwarePacketCacheTimingRecord] = []
        var invalid = false
        var qualified = true
        func qualification(_ value: Bool) { lock.lock(); qualified = value; lock.unlock() }
        func append(_ packet: SoftwareStoredPacket, cursor: SoftwarePacketDiskFIFO.Cursor, epoch: UInt64) {
            lock.lock(); defer { lock.unlock() }
            records.append(.init(pts: packet.dts, duration: packet.duration, key: packet.flags & 1 != 0, cursor: cursor))
        }
        func drain(epoch: UInt64) -> SoftwarePacketCacheTimingBatch {
            lock.lock(); defer { lock.unlock() }
            defer { if qualified { records.removeAll() } }
            return .init(invalid: invalid, records: qualified ? records : [],
                         calibrationPressure: !qualified && records.count >= 4)
        }
        func fail() { lock.lock(); invalid = true; lock.unlock() }
        func seconds(position: Int64, epoch: UInt64) -> Double? { Double(position) / 1000 }
        func evict(before chunk: UInt64, epoch: UInt64) {}
    }
    private final class Input: @unchecked Sendable {
        var i = 0
        func next() -> SoftwareStoredPacket? {
            guard i < 100 else { return nil }; defer { i += 1 }
            let ticks = Int64(i * 40)
            return .init(pts: .min, dts: ticks, duration: 40, position: ticks,
                streamIndex: 0, flags: i % 10 == 0 ? 1 : 0,
                timeBaseNumerator: 1, timeBaseDenominator: 1000,
                bytes: Data(repeating: 7, count: 100), sideData: [])
        }
    }
    @Test("Qualified timing drives ranges and cache seek while returned packets keep missing PTS",
          arguments: [false, true])
    func rangesAndSeeks(memory: Bool) async throws {
        let timing = Timing(); let input = Input()
        let fifo: any SoftwarePacketStore = memory
            ? SoftwarePacketMemoryFIFO(chunkTargetBytes: 1, historyCapBytes: 1_000_000, kernelMayPurge: false)
            : try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, retainConsumed: true)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: nil, byteBudget: 1_000_000, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo, cacheTiming: timing) { _ in input.next() }
        defer { source.close() }; source.start()
        try await waitFor { source.snapshot.sourceEnded }
        #expect(source.residentRanges == [0...4])
        let packet = try #require(try source.read())
        #expect(packet.pts == .min); #expect(packet.cacheTimingEpoch == 0)
        let token = source.beginSeek(to: 2)
        #expect(try source.prepareSeek(token, to: 2))
        source.endSeek(token, sourceClock: 2)
        #expect(source.snapshot.cacheSeekHits == 1)
        #expect(source.residentRanges == [0...4])
        timing.fail()
        #expect(source.residentRanges.isEmpty)
        #expect(source.snapshot.frontier == nil)
        let miss = source.beginSeek(to: 2)
        #expect(try !source.prepareSeek(miss, to: 2))
        source.endSeek(miss, sourceClock: 2)
    }
    @Test("Unqualified metadata pressure parks a fast producer, drains without deadlock, and wakes on qualification",
          arguments: [false, true])
    func calibrationBackpressure(memory: Bool) async throws {
        let timing = Timing(); timing.qualification(false)
        let input = Input()
        let fifo: any SoftwarePacketStore = memory
            ? SoftwarePacketMemoryFIFO(chunkTargetBytes: 1, historyCapBytes: 1_000_000, kernelMayPurge: false)
            : try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, retainConsumed: true)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: nil, byteBudget: 1_000_000, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo, cacheTiming: timing) { _ in input.next() }
        defer { source.close() }; source.start()
        try await waitFor { source.producerParkedForTesting }
        #expect(source.snapshot.packetCount == 4)
        #expect(source.residentRanges.isEmpty)
        // Drain beyond the initial reservoir: the producer must keep feeding an unfinished GOP.
        for _ in 0..<6 { #expect(try source.read() != nil) }
        timing.qualification(true)
        // The sampler can lift calibration pressure even if the user has just paused the consumer.
        _ = source.snapshot
        try await waitFor { source.snapshot.sourceEnded }
        #expect(source.residentRanges == [0...4])
    }

}
