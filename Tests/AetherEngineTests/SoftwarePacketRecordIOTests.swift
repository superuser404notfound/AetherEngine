import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Audit PERF-109: a software VOD packet crossed the spool through two write calls, two reads that
/// each allocated, and two payload copies on the way back out. The record layout is pinned by
/// `Issue592PacketEnvelopeTests` and by the cursor tests; these pin what the cheaper I/O must keep.
@Suite("Software packet spool record I/O (audit PERF-109)")
struct SoftwarePacketRecordIOTests {

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf109-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func payload(_ size: Int, seed: UInt8) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: Int(seed) &+ i &* 31) }
        }
        return data
    }

    @Test("records of every size survive the spool across chunk boundaries")
    func recordsRoundTrip() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, parentDirectory: root)
        defer { try? fifo.close() }
        let sizes = [0, 1, 7, 8, 9, 100, 4_096, 65_528, 65_529, 70_000, 200_000, 0, 3]
        let records = sizes.enumerated().map { Self.payload($0.element, seed: UInt8($0.offset)) }
        for record in records { try fifo.append(record) }
        for record in records { #expect(try fifo.pop() == record) }
        #expect(try fifo.pop() == nil)
    }

    @Test("the chunk file is a big-endian length followed by the payload, record after record")
    func onDiskLayoutIsUnchanged() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 1 << 20, parentDirectory: root)
        defer { try? fifo.close() }
        let first = Self.payload(300, seed: 1)
        let second = Data()
        let third = Self.payload(17, seed: 9)
        for record in [first, second, third] { try fifo.append(record) }

        let raw = try Data(contentsOf: fifo.storageDirectory.appendingPathComponent("0.packets"))
        var expected = Data()
        for record in [first, second, third] {
            withUnsafeBytes(of: UInt64(record.count).bigEndian) { expected.append(contentsOf: $0) }
            expected.append(record)
        }
        #expect(raw == expected)
    }

    @Test("a chunk cut short behind the store's back is corruption, and the failure sticks")
    func truncatedChunkFailsClosed() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 1 << 20, parentDirectory: root)
        defer { try? fifo.close() }
        try fifo.append(Self.payload(1_000, seed: 4))
        let chunk = fifo.storageDirectory.appendingPathComponent("0.packets")
        let handle = try FileHandle(forWritingTo: chunk)
        try handle.truncate(atOffset: 500)
        try handle.close()

        #expect(throws: SoftwarePacketDiskFIFO.Failure.corruptRecord) { try fifo.pop() }
        #expect(fifo.snapshot.hasFailure)
        #expect(throws: (any Error).self) { try fifo.append(Data([1])) }
    }

    @Test("a decoded payload is the record's own memory, not a second copy of it")
    func decodeDoesNotCopyThePayload() throws {
        let packet = SoftwareStoredPacket(
            pts: 1, dts: 1, duration: 1, position: 0, streamIndex: 0, flags: 0,
            timeBaseNumerator: 1, timeBaseDenominator: 90_000,
            bytes: Self.payload(4_096, seed: 2),
            sideData: [.init(type: 7, bytes: Self.payload(40, seed: 3))])
        let record = try packet.encoded()
        let decoded = try SoftwareStoredPacket.decode(record)
        #expect(decoded == packet)

        let recordBase = record.withUnsafeBytes { $0.baseAddress }
        let payloadBase = decoded.bytes.withUnsafeBytes { $0.baseAddress }
        #expect(recordBase != nil && payloadBase == recordBase.map { $0 + SoftwareStoredPacket.headerBytes })
    }

    /// Reported, not asserted: a timing floor would be a CI coin toss. One packet at a time, so the
    /// spool never holds more than a chunk and the run leaves nothing behind.
    @Test("spool round trip throughput, reported")
    func throughputReport() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 4 << 20, parentDirectory: root)
        defer { try? fifo.close() }
        let rounds = 1_500
        let size = 208_000
        let source = Self.payload(size, seed: 5)
        let packet = SoftwareStoredPacket(
            pts: 0, dts: 0, duration: 1_001, position: 0, streamIndex: 0, flags: 1,
            timeBaseNumerator: 1, timeBaseDenominator: 90_000, bytes: source, sideData: [])
        let record = try packet.encoded()

        var checksum = 0
        let start = DispatchTime.now()
        for _ in 0..<rounds {
            try fifo.append(record)
            let back = try #require(try fifo.pop())
            let decoded = try SoftwareStoredPacket.decode(back)
            checksum &+= decoded.bytes.count
            av_packet_free_safe(try decoded.makeAVPacket())
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        print(String(format: "[PERF109] %d packets of %d bytes: %.0f us/pkt (append + pop + decode + AVPacket)",
                     rounds, size, seconds / Double(rounds) * 1e6))
        #expect(checksum == rounds * size)
    }
}
