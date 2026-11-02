import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("AVI MPEG-4 cache presentation timing", .offCooperativePool, .timeLimit(.minutes(3)))
struct SoftwarePacketCacheTimingTests {
    private func packet(_ i: Int, shift: Int64 = 0) -> SoftwareStoredPacket {
        let (dts, key, encoded) = MPEG4CacheTimingFixture.packets[i]
        return .init(pts: Int64.min, dts: dts + shift, duration: 1, position: Int64(i + 100),
            streamIndex: 0, flags: key ? 1 : 0, timeBaseNumerator: 1, timeBaseDenominator: 25,
            bytes: Data(base64Encoded: encoded)!, sideData: [])
    }
    private func cursor(_ i: Int, generation: UUID) -> SoftwarePacketDiskFIFO.Cursor {
        .init(chunkID: UInt64(i / 25), generation: generation, offset: UInt64(i * 100), recordIndex: i, payloadPrefix: 0)
    }
    private func populate(_ timing: SoftwarePacketCacheTiming, epoch: UInt64 = 0, shift: Int64 = 0, sourcePackets: [SoftwareStoredPacket]? = nil,
                          numerator: Int32 = 1, denominator: Int32 = 25,
                          drain: ((SoftwarePacketCacheTimingBatch) -> Void)? = nil) throws -> [Int64: Int64] {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_MPEG4))
        var ctx: UnsafeMutablePointer<AVCodecContext>? = try #require(avcodec_alloc_context3(codec))
        var frame: UnsafeMutablePointer<AVFrame>? = try #require(av_frame_alloc())
        defer { avcodec_free_context(&ctx); av_frame_free(&frame) }
        let c = ctx!; let f = frame!
        c.pointee.width = 32; c.pointee.height = 32
        c.pointee.pkt_timebase = AVRational(num: numerator, den: denominator)
        c.pointee.thread_count = 1; c.pointee.flags |= AV_CODEC_FLAG_COPY_OPAQUE
        #expect(avcodec_open2(c, codec, nil) == 0)
        var observations: [Int64: Int64] = [:]
        func receive() {
            while avcodec_receive_frame(c, f) >= 0 {
                if let (e, position) = SoftwarePacketCacheIdentity.identity(f) {
                    let pts = f.pointee.pts == Int64.min ? f.pointee.best_effort_timestamp : f.pointee.pts
                    timing.observe(epoch: e, position: position, pts: pts)
                    observations[position] = pts
                }
                av_frame_unref(f)
            }
        }
        let generation = UUID()
        let packets = sourcePackets ?? MPEG4CacheTimingFixture.packets.indices.map { packet($0, shift: shift) }
        for i in packets.indices {
            var p = packets[i]
            timing.append(p, cursor: cursor(i, generation: generation), epoch: epoch)
            p.cacheTimingEpoch = epoch
            let av = try p.makeAVPacket()
            #expect(av.pointee.pts == Int64.min)
            #expect(av.pointee.dts == p.dts)
            #expect(avcodec_send_packet(c, av) == 0)
            av_packet_unref(av); av_packet_free_safe(av)
            receive()
            drain?(timing.drain(epoch: epoch))
        }
        #expect(avcodec_send_packet(c, nil) == 0); receive()
        return observations
    }

    @Test("Whole-record parser time matches repaired decoded frames across B-frame order")
    func actualParserAndDecoder() throws {
        let timing = SoftwarePacketCacheTiming(numerator: 1, denominator: 25)
        let decoded = try populate(timing)
        let batch = timing.drain(epoch: 0)
        #expect(!batch.invalid)
        #expect(batch.records.count == MPEG4CacheTimingFixture.packets.count - 1) // No invented last packet: parser has not seen its successor.
        #expect(batch.records.contains { $0.key })
        var untimedTail: [SoftwarePacketCacheTimingRecord] = []
        for record in batch.records {
            let position = Int64(record.cursor.recordIndex + 100)
            let framePTS = try #require(decoded[position])
            if framePTS == Int64.min {
                untimedTail.append(record)
            } else {
                #expect(record.pts == framePTS)
            }
            #expect(timing.seconds(position: position, epoch: 0) == Double(record.pts) / 25)
        }
        // With generated packet PTS suppressed, this fixture's final displayed reference
        // picture has neither frame PTS nor best_effort_timestamp when FFmpeg is flushed.
        // It cannot qualify a pairing. The parser still has its coded display time; compare
        // every timestamped frame above, and pin this separate EOF boundary explicitly.
        #expect(untimedTail.count == 1)
        #expect(untimedTail.first?.pts == batch.records.map(\.pts).max())
        #expect(untimedTail.first?.pts == Int64(MPEG4CacheTimingFixture.packets.count))
        #expect(!timing.drain(epoch: 0).invalid)
        #expect(batch.records.map(\.pts) != batch.records.map(\.pts).sorted())
        #expect(timing.drain(epoch: 0).records.isEmpty)
    }

    @Test("A cold seek recalibrates the nonzero source axis and rejects old-epoch observations")
    func coldSeek() throws {
        let timing = SoftwarePacketCacheTiming(numerator: 1, denominator: 25)
        _ = try populate(timing)
        let first = timing.drain(epoch: 0)
        _ = try populate(timing, epoch: 1, shift: 150_000)
        timing.observe(epoch: 0, position: 100, pts: -20)
        let second = timing.drain(epoch: 1)
        #expect(!second.invalid)
        #expect(second.records.map(\.pts) == first.records.map { $0.pts + 150_000 })
        #expect(timing.seconds(position: 100, epoch: 0) == nil)
    }

    @Test("No decoder-confirmed GOP means no cache axis; mismatch invalidates a confirmed axis")
    func qualificationAndMismatch() throws {
        let timing = SoftwarePacketCacheTiming(numerator: 1, denominator: 25)
        let g = UUID()
        for i in 0..<40 { timing.append(packet(i), cursor: cursor(i, generation: g), epoch: 0) }
        #expect(timing.drain(epoch: 0).records.isEmpty)
        let confirmed = SoftwarePacketCacheTiming(numerator: 1, denominator: 25)
        let observed = try populate(confirmed)
        #expect(!confirmed.drain(epoch: 0).records.isEmpty)
        confirmed.observe(epoch: 0, position: 100, pts: observed[100]! + 1)
        #expect(confirmed.drain(epoch: 0).invalid)
        #expect(confirmed.seconds(position: 100, epoch: 0) == nil)
    }

    @Test("Packed/multiple pictures in one record are not guessed into whole-packet coverage")
    func packedOwnershipIsConservative() {
        let timing = SoftwarePacketCacheTiming(numerator: 1, denominator: 25)
        let a = packet(0); let b = packet(1)
        let packed = SoftwareStoredPacket(pts: .min, dts: 0, duration: 1, position: 100,
            streamIndex: 0, flags: 1, timeBaseNumerator: 1, timeBaseDenominator: 25,
            bytes: a.bytes + b.bytes, sideData: [])
        let g = UUID()
        timing.append(packed, cursor: cursor(0, generation: g), epoch: 0)
        timing.append(packet(2), cursor: cursor(2, generation: g), epoch: 0)
        #expect(timing.drain(epoch: 0).invalid)
        #expect(timing.drain(epoch: 0).records.isEmpty)
    }

    @Test("Evicted packet identities cannot be reused and metadata pressure stays conservative")
    func evictionAndBound() throws {
        let timing = SoftwarePacketCacheTiming(numerator: 1, denominator: 25)
        _ = try populate(timing)
        timing.evict(before: 2, epoch: 0)
        #expect(timing.seconds(position: 100, epoch: 0) == nil)
        #expect(timing.drain(epoch: 0).records.allSatisfy { $0.cursor.chunkID >= 2 })
        let small = SoftwarePacketCacheTiming(numerator: 1, denominator: 25, maximumEntries: 16)
        let g = UUID()
        for i in 0..<20 { small.append(packet(i), cursor: cursor(i, generation: g), epoch: 0) }
        #expect(small.drain(epoch: 0).invalid)
        #expect(small.drain(epoch: 0).oldestUsableChunk == nil)
        #expect(small.seconds(position: 100, epoch: 0) == nil)
    }

    @Test("Published coverage survives temporary pairing-map retirement until real chunk eviction")
    func publishedHistorySurvivesPairingLimit() throws {
        let timing = SoftwarePacketCacheTiming(numerator: 1, denominator: 25, maximumEntries: 64)
        var records: [SoftwarePacketCacheTimingRecord] = []
        _ = try populate(timing, drain: { batch in
            #expect(!batch.invalid)
            #expect(batch.oldestUsableChunk == nil)
            records += batch.records
        })
        #expect(records.count == MPEG4CacheTimingFixture.packets.count - 1)
        #expect(records.first?.cursor.recordIndex == 0)
        // Temporary pairings can retire; the already-published range/cursor must not retire with them.
        #expect(timing.seconds(position: 100, epoch: 0) == nil)
        timing.evict(before: 4, epoch: 0)
        #expect(timing.drain(epoch: 0).oldestUsableChunk == 4)
        #expect(timing.seconds(position: 199, epoch: 0) == nil)
    }

    @Test("Fast source keeps early ranges and cache hits past pairing cap; actual byte eviction removes them",
          arguments: [false, true])
    func fastSourceRetainedHistory(memory: Bool) async throws {
        // Obtain the fixture's actual repaired decoder timestamps, then let the producer outrun
        // consumption. This models the device paused near the start while its cache fills.
        let reference = SoftwarePacketCacheTiming(numerator: 1, denominator: 25)
        let decoded = try populate(reference)
        let timing = SoftwarePacketCacheTiming(numerator: 1, denominator: 25, maximumEntries: 64)
        let packets = MPEG4CacheTimingFixture.packets.indices.map { packet($0) }
        final class Input: @unchecked Sendable { var index = 0 }
        let input = Input()
        let fifo: any SoftwarePacketStore = memory
            ? SoftwarePacketMemoryFIFO(chunkTargetBytes: 1, historyCapBytes: 1_000_000, kernelMayPurge: false)
            : try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, retainConsumed: true)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 25),
            audio: nil, byteBudget: 1_000_000, forwardSeconds: 3600, initialSourceClock: 0,
            fifo: fifo, cacheTiming: timing) { _ in
                if input.index > 0 {
                    let previous = packets[input.index - 1]
                    if let pts = decoded[previous.position] {
                        timing.observe(epoch: 0, position: previous.position, pts: pts)
                    }
                }
                guard input.index < packets.count else { return nil }
                defer { input.index += 1 }
                return packets[input.index]
            }
        defer { source.close() }; source.start()
        try await waitFor { source.snapshot.sourceEnded }
        let ranges = source.residentRanges
        let start = Double(try #require(decoded[100])) / 25
        #expect(ranges.first?.lowerBound == start)
        #expect(timing.seconds(position: 100, epoch: 0) == nil)
        let token = source.beginSeek(to: 1)
        #expect(try source.prepareSeek(token, to: 1))
        source.endSeek(token, sourceClock: 1)
        #expect(source.snapshot.cacheSeekHits == 1)
        let restored = try #require(try source.read())
        #expect(restored.position == 100)
        #expect(restored.pts == .min)
        #expect(restored.bytes == packets[0].bytes)
        #expect(source.residentRanges == ranges)
        // Physical eviction still clips coverage and rejects a stale early seek.
        for _ in 0..<(packets.count - 20) { #expect(try source.read() != nil) }
        if let memory = fifo as? SoftwarePacketMemoryFIFO {
            memory.purgeHistoryForTesting()
            _ = source.residentRanges // The sampler notices a purged history chunk.
        } else {
            try fifo.trimConsumed(toByteBudget: 0)
        }
        #expect(try source.read() != nil) // Synchronize the actual store's retention floor.
        #expect((source.residentRanges.first?.lowerBound ?? .infinity) > start)
        let miss = source.beginSeek(to: 1)
        #expect(try !source.prepareSeek(miss, to: 1))
        source.endSeek(miss, sourceClock: 1)
    }

    @Test("Observation identity is transient: spool format and decoded payload stay byte-identical")
    func envelopeUnchanged() throws {
        let original = packet(3)
        var tagged = original; tagged.cacheTimingEpoch = 42
        #expect(try tagged.encoded() == original.encoded())
        let restored = try SoftwareStoredPacket.decode(tagged.encoded())
        #expect(restored == original)
        let av = try tagged.makeAVPacket()
        defer { av_packet_unref(av); av_packet_free_safe(av) }
        #expect(try SoftwareStoredPacket(copying: av) == original)
        #expect(av.pointee.opaque_ref != nil)
    }
}
