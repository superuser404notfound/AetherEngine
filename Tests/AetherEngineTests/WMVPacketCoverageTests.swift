import Foundation
import CoreMedia
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("WMV I/P packet presentation coverage", .timeLimit(.minutes(3)), .offCooperativePool)
struct WMVPacketCoverageTests {
    enum Codec: String, CaseIterable, Sendable {
        case wmv1, wmv2
        var id: UInt32 { self == .wmv1 ? AV_CODEC_ID_WMV1.rawValue : AV_CODEC_ID_WMV2.rawValue }
    }

    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        func append(_ time: CMTime) { lock.withLock { times.append(time.seconds) } }
        var values: [Double] { lock.withLock { times } }
    }

    private final class Packets: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        let values: [SoftwareStoredPacket]
        init(_ values: [SoftwareStoredPacket]) { self.values = values }
        func next() -> SoftwareStoredPacket? {
            lock.withLock {
                guard index < values.count else { return nil }
                defer { index += 1 }
                return values[index]
            }
        }
    }

    /// Real demux and fixed FFmpeg software decoder, not hand-authored timestamp metadata.
    /// These I/P samples emit all 120 pictures without requiring an EOF drain API.
    private func decodedPackets(_ codec: Codec) throws -> [SoftwareStoredPacket] {
        let data = try WMVCoverageFixtures.data(codec.rawValue)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: video))
        #expect(stream.pointee.codecpar.pointee.codec_id.rawValue == codec.id)
        #expect(stream.pointee.time_base.num == 1 && stream.pointee.time_base.den == 1000)
        let frames = Frames()
        let decoder = SoftwareVideoDecoder()
        try decoder.open(stream: stream) { _, pts, _ in frames.append(pts) }
        defer { decoder.close() }
        var packets: [SoftwareStoredPacket] = []
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == video else { continue }
            packets.append(try SoftwareStoredPacket(copying: packet))
            decoder.decode(packet: packet)
        }
        #expect(packets.count == 120)
        let decoded = frames.values
        try #require(decoded.count == packets.count)
        for (packet, time) in zip(packets, decoded) {
            #expect(abs(time - Double(packet.pts) / 1000) < 0.000001)
            #expect(packet.duration == 33)
        }
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $0.pts < $1.pts })
        return packets
    }

    private func replacing(_ packet: SoftwareStoredPacket, pts: Int64) -> SoftwareStoredPacket {
        .init(pts: pts, dts: pts, duration: packet.duration, position: packet.position,
              streamIndex: packet.streamIndex, flags: packet.flags,
              timeBaseNumerator: packet.timeBaseNumerator, timeBaseDenominator: packet.timeBaseDenominator,
              bytes: packet.bytes, sideData: packet.sideData)
    }

    private func withStore(
        _ codec: Codec, memory: Bool, packets: [SoftwareStoredPacket], strict: Bool = false,
        origin: Double = 0, historyCapBytes: Int = 8 << 20,
        body: (SoftwarePacketReadAhead, any SoftwarePacketStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store: any SoftwarePacketStore = memory
            ? SoftwarePacketMemoryFIFO(chunkTargetBytes: 4096, historyCapBytes: historyCapBytes, kernelMayPurge: false)
            : try SoftwarePacketDiskFIFO(chunkTargetBytes: 4096, retainConsumed: true, parentDirectory: root)
        let input = Packets(packets)
        let source = SoftwarePacketReadAhead(
            video: .init(index: packets[0].streamIndex, numerator: 1, denominator: 1000), audio: nil,
            byteBudget: 8 << 20, forwardSeconds: 100, initialSourceClock: origin, fifo: store,
            videoReorderDepth: strict ? nil : SoftwarePlaybackHost.presentationReorderDepth(codecID: codec.id)
        ) { _ in input.next() }
        defer { source.close() }
        source.start()
        try await waitFor { source.snapshot.sourceEnded }
        try await body(source, store)
    }

    @Test("real WMV packets bridge rounding holes in either store without inventing an EOF tail",
          arguments: Codec.allCases, [false, true])
    func roundedDurations(codec: Codec, memory: Bool) async throws {
        let packets = try decodedPackets(codec)
        try await withStore(codec, memory: memory, packets: packets, strict: true) { old, _ in
            #expect(old.residentRanges.count > 1)
            #expect((old.snapshot.frontier ?? 0) < 0.1)
        }
        try await withStore(codec, memory: memory, packets: packets) { source, _ in
            #expect(source.residentRanges.count == 1)
            #expect(abs((source.snapshot.frontier ?? 0) - 3.971) < 0.000001)
            #expect(source.residentRanges.last?.upperBound == 3.971)
            for target in [0.0665, 2.5] {
                let token = source.beginSeek(to: target)
                let hit = try source.prepareSeek(token, to: target)
                #expect(hit)
                source.endSeek(token, sourceClock: target)
            }
            #expect(source.snapshot.sourceEpoch == 0)
            _ = source.beginSeek()
            #expect(source.residentRanges.isEmpty)
            #expect(source.snapshot.frontier == nil)
            #expect(source.snapshot.sourceEpoch == 1)
        }
    }

    @Test("nonzero source clocks retain the same WMV cache semantics",
          arguments: Codec.allCases, [false, true])
    func offsetClock(codec: Codec, memory: Bool) async throws {
        let packets = try decodedPackets(codec).map { replacing($0, pts: $0.pts + 600_000) }
        try await withStore(codec, memory: memory, packets: packets, origin: 600) { source, _ in
            #expect(source.residentRanges.first?.lowerBound == 600)
            #expect(source.residentRanges.last?.upperBound == 603.971)
            let target = 600.0665
            let hit = try source.prepareSeek(source.beginSeek(to: target), to: target)
            #expect(hit)
        }
    }

    @Test("missing or late WMV PTS invalidates real-store coverage",
          arguments: Codec.allCases, [false, true])
    func invalidTimestamps(codec: Codec, memory: Bool) async throws {
        let original = try decodedPackets(codec)
        for invalid in [Int64.min, Int64(1)] {
            var packets = original
            packets[60] = replacing(packets[60], pts: invalid)
            try await withStore(codec, memory: memory, packets: packets) { source, _ in
                #expect(source.residentRanges.isEmpty)
                #expect(source.snapshot.frontier == nil)
                let hit = try source.prepareSeek(source.beginSeek(to: 1), to: 1)
                #expect(!hit)
            }
        }
    }

    @Test("a real presentation discontinuity remains a cache miss",
          arguments: Codec.allCases, [false, true])
    func discontinuity(codec: Codec, memory: Bool) async throws {
        let packets = try decodedPackets(codec).enumerated().map { index, p in
            replacing(p, pts: p.pts + (index >= 60 ? 2000 : 0))
        }
        try await withStore(codec, memory: memory, packets: packets) { source, _ in
            #expect(source.residentRanges.count == 2)
            #expect(!source.residentRanges.contains { $0.contains(3) })
            let hit = try source.prepareSeek(source.beginSeek(to: 3), to: 3)
            #expect(!hit)
        }
    }

    @Test("evicted WMV history is no longer advertised or seekable",
          arguments: Codec.allCases, [false, true])
    func eviction(codec: Codec, memory: Bool) async throws {
        let packets = try decodedPackets(codec)
        try await withStore(codec, memory: memory, packets: packets, historyCapBytes: 0) { source, store in
            for _ in 0..<90 { _ = try #require(try source.read()) }
            // Memory uses its own history cap; this argument is the disk-store budget.
            try store.trimConsumed(toByteBudget: 0)
            _ = try #require(try source.read()) // refresh residency from the actual store floor
            #expect(!source.residentRanges.contains { $0.contains(0.0665) })
            let hit = try source.prepareSeek(source.beginSeek(to: 0.0665), to: 0.0665)
            #expect(!hit)
        }
    }

    @Test("WMV3 remains independent of WMV1/2 qualification")
    func codecBoundary() {
        for codec in Codec.allCases {
            #expect(SoftwarePlaybackHost.presentationReorderDepth(codecID: codec.id) == 1)
        }
        #expect(SoftwarePlaybackHost.presentationReorderDepth(codecID: AV_CODEC_ID_WMV3.rawValue) == nil)
        #expect(SoftwarePlaybackHost.presentationReorderDepth(codecID: AV_CODEC_ID_MPEG2VIDEO.rawValue) == nil)
    }
}
