import Foundation
import CoreMedia
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("MPEG candidate packet presentation coverage", .timeLimit(.minutes(3)), .offCooperativePool)
struct MPEGPacketCoverageTests {
    enum Fixture: String, CaseIterable, Sendable {
        case mpeg1, mpeg2, interlaced, pulldown, fields
        var id: UInt32 { self == .mpeg1 ? AV_CODEC_ID_MPEG1VIDEO.rawValue : AV_CODEC_ID_MPEG2VIDEO.rawValue }
        var count: Int { self == .pulldown || self == .fields ? 60 : 120 }
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

    /// Fixed libavcodec, including a true EOF drain. This deliberately does not use the CLI
    /// probe's flush/discard operation or claim renderer/deinterlacer/device acceptance.
    private func decodedPackets(_ codec: Fixture, transport: Bool = false) throws -> [SoftwareStoredPacket] {
        let data = try MPEGCacheFixtures.data(transport ? "fieldsTS" : codec.rawValue)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: transport ? "mpegts" : "matroska")
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: video))
        #expect(stream.pointee.codecpar.pointee.codec_id.rawValue == codec.id)
        #expect(stream.pointee.time_base.num == 1 && stream.pointee.time_base.den == (transport ? 90000 : 1000))
        let implementation = try #require(avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id))
        var context = avcodec_alloc_context3(implementation)
        let ctx = try #require(context)
        defer { avcodec_free_context(&context) }
        try #require(avcodec_parameters_to_context(ctx, stream.pointee.codecpar) >= 0)
        ctx.pointee.pkt_timebase = stream.pointee.time_base
        ctx.pointee.thread_count = 1
        try #require(avcodec_open2(ctx, implementation, nil) >= 0)
        var allocated = av_frame_alloc()
        let frame = try #require(allocated)
        defer { av_frame_free(&allocated) }
        var times: [Int64] = []
        var interlaced = 0
        var repeated = 0
        func receive() throws {
            while true {
                let result = avcodec_receive_frame(ctx, frame)
                if result == FFmpegErr.eagain || result == FFmpegErr.eof { break }
                try #require(result >= 0)
                times.append(frame.pointee.pts)
                if frame.pointee.flags & (1 << 3) != 0 { interlaced += 1 }
                if frame.pointee.repeat_pict > 0 { repeated += 1 }
                av_frame_unref(frame)
            }
        }
        var packets: [SoftwareStoredPacket] = []
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == video else { continue }
            let stored = try SoftwareStoredPacket(copying: packet)
            if codec == .fields {
                // Each presented frame must own both independently coded fields, including
                // Matroska's complete-frame packets and TS parser output.
                #expect(fieldPictureStructures(in: stored.bytes) == [1, 2])
            }
            packets.append(stored)
            try #require(avcodec_send_packet(ctx, packet) >= 0)
            try receive()
        }
        try #require(avcodec_send_packet(ctx, nil) >= 0)
        try receive()
        #expect(packets.count == codec.count)
        #expect(times == packets.map(\.pts).sorted())
        #expect(!times.contains(Int64.min))
        #expect(zip(packets, packets.dropFirst()).contains { $0.pts > $1.pts }, "the fixture includes B-picture reordering")
        if codec == .interlaced || codec == .fields { #expect(interlaced == codec.count) }
        if codec == .pulldown { #expect(repeated == 30) }
        return packets
    }

    private func fieldPictureStructures(in data: Data) -> [Int] {
        let bytes = [UInt8](data)
        guard bytes.count >= 7 else { return [] }
        var structures: [Int] = []
        for i in 0...(bytes.count - 7) where
            bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 && bytes[i + 3] == 0xb5 {
            // picture_coding_extension: id(4), f_code(16), intra_dc_precision(2), structure(2).
            if bytes[i + 4] >> 4 == 8 { structures.append(Int(bytes[i + 6] & 3)) }
        }
        return structures
    }

    @Test("separately coded MPEG fields form complete presentation packets through the TS parser")
    func fieldTransportParser() throws { _ = try decodedPackets(.fields, transport: true) }

    private func replacing(_ packet: SoftwareStoredPacket, pts: Int64) -> SoftwareStoredPacket {
        .init(pts: pts, dts: pts, duration: packet.duration, position: packet.position,
              streamIndex: packet.streamIndex, flags: packet.flags,
              timeBaseNumerator: packet.timeBaseNumerator, timeBaseDenominator: packet.timeBaseDenominator,
              bytes: packet.bytes, sideData: packet.sideData)
    }

    private func withStore(
        _ codec: Fixture, memory: Bool, packets: [SoftwareStoredPacket], strict: Bool = false,
        origin: Double? = nil, historyCapBytes: Int = 8 << 20,
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
            byteBudget: 8 << 20, forwardSeconds: 100, initialSourceClock: origin ?? Double(packets.map(\.pts).min()!) / 1000, fifo: store,
            videoReorderDepth: strict ? nil : SoftwarePlaybackHost.presentationReorderDepth(codecID: codec.id)
        ) { _ in input.next() }
        defer { source.close() }
        source.start()
        try await waitFor { source.snapshot.sourceEnded }
        try await body(source, store)
    }

    @Test("real MPEG packets bridge rounding holes in either store without inventing an EOF tail",
          arguments: Fixture.allCases, [false, true])
    func roundedDurations(codec: Fixture, memory: Bool) async throws {
        let packets = try decodedPackets(codec)
        let last = Double(packets.map(\.pts).max()!) / 1000
        let sorted = packets.sorted { $0.pts < $1.pts }
        let gap = try #require(zip(sorted, sorted.dropFirst()).first { $0.pts + $0.duration < $1.pts })
        let targetInHole = Double(gap.0.pts + gap.0.duration + gap.1.pts) / 2000
        try await withStore(codec, memory: memory, packets: packets, strict: true) { old, _ in
            #expect(old.residentRanges.count > 1)
            #expect((old.snapshot.frontier ?? 0) < last)
        }
        try await withStore(codec, memory: memory, packets: packets) { source, _ in
            #expect(source.residentRanges.count == 1)
            #expect(abs((source.snapshot.frontier ?? 0) - last) < 0.000001)
            #expect(source.residentRanges.last?.upperBound == last)
            for target in [targetInHole, last - 0.1] {
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

    @Test("nonzero source clocks retain the same MPEG cache semantics",
          arguments: Fixture.allCases, [false, true])
    func offsetClock(codec: Fixture, memory: Bool) async throws {
        let packets = try decodedPackets(codec).map { replacing($0, pts: $0.pts + 600_000) }
        try await withStore(codec, memory: memory, packets: packets, origin: Double(packets.map(\.pts).min()!) / 1000) { source, _ in
            #expect(source.residentRanges.first?.lowerBound == Double(packets.map(\.pts).min()!) / 1000)
            #expect(source.residentRanges.last?.upperBound == Double(packets.map(\.pts).max()!) / 1000)
            let target = Double(packets.map(\.pts).max()!) / 1000 - 0.1
            let hit = try source.prepareSeek(source.beginSeek(to: target), to: target)
            #expect(hit)
        }
    }

    @Test("missing or late MPEG PTS invalidates real-store coverage",
          arguments: Fixture.allCases, [false, true])
    func invalidTimestamps(codec: Fixture, memory: Bool) async throws {
        let original = try decodedPackets(codec)
        for invalid in [Int64.min, Int64(1)] {
            var packets = original
            packets[packets.count - 2] = replacing(packets[packets.count - 2], pts: invalid)
            try await withStore(codec, memory: memory, packets: packets,
                                origin: Double(original.map(\.pts).min()!) / 1000) { source, _ in
                #expect(source.residentRanges.isEmpty)
                #expect(source.snapshot.frontier == nil)
                let hit = try source.prepareSeek(source.beginSeek(to: 1), to: 1)
                #expect(!hit)
            }
        }
    }

    @Test("a real presentation discontinuity remains a cache miss",
          arguments: Fixture.allCases, [false, true])
    func discontinuity(codec: Fixture, memory: Bool) async throws {
        let original = try decodedPackets(codec)
        let split = original.map(\.pts).sorted()[original.count / 2]
        let packets = original.map { p in replacing(p, pts: p.pts + (p.pts >= split ? 2000 : 0)) }
        let target = Double(split) / 1000 + 1
        try await withStore(codec, memory: memory, packets: packets) { source, _ in
            #expect(source.residentRanges.count == 2)
            #expect(!source.residentRanges.contains { $0.contains(target) })
            let hit = try source.prepareSeek(source.beginSeek(to: target), to: target)
            #expect(!hit)
        }
    }

    @Test("evicted MPEG history is no longer advertised or seekable",
          arguments: Fixture.allCases, [false, true])
    func eviction(codec: Fixture, memory: Bool) async throws {
        let original = try decodedPackets(codec)
        // Repeat existing envelopes on separated time spans for a multi-chunk retention workload.
        // This is a store test, not a claim that the concatenation is a newly decoded media file.
        let span = ((original.map(\.pts).max()! + 999) / 1000 + 1) * 1000
        let packets = (0..<12).flatMap { cycle in
            original.map { replacing($0, pts: $0.pts + Int64(cycle) * span) }
        }
        try await withStore(codec, memory: memory, packets: packets, historyCapBytes: 0) { source, store in
            for _ in 0..<(packets.count * 3 / 4) { _ = try #require(try source.read()) }
            // Memory uses its own history cap; this argument is the disk-store budget.
            try store.trimConsumed(toByteBudget: 0)
            _ = try #require(try source.read()) // refresh residency from the actual store floor
            #expect(!source.residentRanges.contains { $0.contains(0.1) })
            let hit = try source.prepareSeek(source.beginSeek(to: 0.1), to: 0.1)
            #expect(!hit)
        }
    }

    @Test("MPEG candidate does not qualify WMV3")
    func codecBoundary() {
        for codec in Fixture.allCases {
            #expect(SoftwarePlaybackHost.presentationReorderDepth(codecID: codec.id) == 32)
        }
        #expect(SoftwarePlaybackHost.presentationReorderDepth(codecID: AV_CODEC_ID_WMV3.rawValue) == nil)
    }
}
