import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Forward-only Live reads must yield scheduling opportunities without losing source packets.
@Suite(.timeLimit(.minutes(3)))
struct ForwardPacketReadTests {
    // Failure modes:
    // - An idle source is mistaken for EOF or consumes the next available packet.
    // - Cancellation is reported as idle and leaves a worker waiting indefinitely.
    // - Live forwarding retains seek metadata or exceeds replay's compressed allowance.

    /// An idle poll leaves the source open and subsequently returns the original envelope once.
    @Test
    func test_read_idlePreservesNextPacketAndEOF() async throws {
        // Arrange — hold the producer before it returns its first packet.
        let gate = ProbeTestGate()
        let calls = ProbeTestBox(0)
        let packet = Self.packet()
        let source = Self.source { _ in
            calls.update { $0 += 1 }
            if calls.value == 1 { gate.wait(); return packet }
            return nil
        }
        defer { gate.open(); source.close() }
        source.start()
        try await waitFor { gate.entered }

        // Act — yield while the source is held, then allow the same packet through.
        #expect(throws: SoftwarePacketReadAhead.ReadError.idle) {
            _ = try source.read(maximumWait: 0)
        }
        #expect(!source.snapshot.sourceEnded)
        gate.open()
        try await waitFor { source.snapshot.sourceEnded }

        // Assert — no packet was consumed by the idle poll, and only real EOF returns nil.
        #expect(try source.read(maximumWait: 0) == packet)
        #expect(try source.read(maximumWait: 0) == nil)
        #expect(source.retainedKeyframeSeconds.isEmpty)
        #expect(source.residentRanges.isEmpty)
    }

    /// A retired host generation and a closed source take precedence over an idle deadline.
    @Test
    func test_read_cancellationIsDistinctFromIdle() throws {
        // Arrange — an empty source that has not started has no producer to wake it.
        let source = Self.source { _ in nil }
        defer { source.close() }

        // Act — cancel this reader generation, then close the source.
        #expect(throws: SoftwarePacketReadAhead.ReadError.interrupted) {
            _ = try source.read(isCurrent: { false }, maximumWait: 0)
        }
        source.close()

        // Assert — close remains terminal even when the caller requested a poll.
        #expect(throws: SoftwarePacketReadAhead.ReadError.closed) {
            _ = try source.read(maximumWait: 0)
        }
    }

    /// Closing wakes an empty-queue consumer even while its producer is still inside source I/O.
    @Test
    func test_read_closeWakesConsumerBeforeSourceReturns() async throws {
        // Arrange — the producer is held independently of the consumer's empty-queue wait.
        let gate = ProbeTestGate()
        let source = Self.source { _ in gate.wait(); return nil }
        defer { gate.open(); source.close() }
        source.start()
        try await waitFor { gate.entered }
        let consumer = ProbeTestJob { try source.read(maximumWait: 60) }

        // Act — retire the queue without releasing its source read.
        source.close()
        let result = try await consumer.outcome()

        // Assert — cancellation reaches the consumer independently of source progress.
        #expect(!gate.isOpen)
        switch result {
        case .failure(let error):
            #expect(error as? SoftwarePacketReadAhead.ReadError == .closed)
        case .success:
            Issue.record("A closed forward source must throw instead of reporting EOF")
        }
    }

    /// An origin failure remains actionable and cannot be swallowed as an idle scheduling yield.
    @Test
    func test_read_sourceFailureRemainsDistinctFromIdle() async throws {
        // Arrange — the source fails before it can return an envelope.
        let source = Self.source { _ in throw CocoaError(.fileReadCorruptFile) }
        defer { source.close() }
        source.start()

        // Act — let a real consumer wait for either the packet or the producer's failure.
        let consumer = ProbeTestJob { try source.read() }
        let result = try await consumer.outcome()

        // Assert — the original failure survives the forward reader boundary.
        switch result {
        case .failure(let error):
            #expect((error as? CocoaError)?.code == .fileReadCorruptFile)
        case .success:
            Issue.record("A failed source must throw instead of reporting EOF")
        }
        #expect(!source.snapshot.sourceEnded)
    }

    /// The forward reservoir still parks at its time window without retaining coverage metadata.
    @Test
    func test_forwardSource_timeBoundParksAndConsumptionResumes() async throws {
        // Arrange — provide an unlimited 25 fps source and a byte budget far above four seconds.
        let calls = ProbeTestBox(0)
        let source = Self.source { _ in
            calls.update { $0 += 1 }
            return Self.packet(pts: Int64(calls.value))
        }
        defer { source.close() }
        source.start()
        try await waitFor { source.producerParkedForTesting }
        let initiallyRead = calls.value
        #expect(initiallyRead == 100)
        #expect(source.snapshot.packetCount == 100)

        // Act — moving the consumer by one packet creates exactly one packet of reservoir space.
        #expect(try source.read(maximumWait: 0)?.pts == 1)
        try await waitFor { calls.value > initiallyRead && source.producerParkedForTesting }

        // Assert — forwarding resumes without rebuilding seek anchors or coverage ranges.
        #expect(calls.value == 101)
        #expect(source.snapshot.packetCount == 100)
        #expect(source.retainedKeyframeSeconds.isEmpty)
        #expect(source.residentRanges.isEmpty)
    }

    /// Untimed packets remain byte-bounded, including one admitted-record overshoot at the gate.
    @Test
    func test_forwardSource_byteBoundParksAndConsumptionResumes() async throws {
        // Arrange — unknown timestamps make the byte budget the only usable producer limit.
        let calls = ProbeTestBox(0)
        let packet = Self.packet(pts: Int64.min, payloadByteCount: 4096)
        let recordBytes = try packet.encoded().count + 8
        let budget = 16_384
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 25),
            audio: nil,
            byteBudget: budget,
            forwardSeconds: 4,
            initialSourceClock: 0,
            fifo: SoftwarePacketMemoryFIFO(chunkTargetBytes: 4096, historyCapBytes: 0),
            forwardOnly: true
        ) { _ in
            calls.update { $0 += 1 }
            return packet
        }
        defer { source.close() }
        source.start()
        try await waitFor { source.producerParkedForTesting }
        let initiallyRead = calls.value
        let residency = source.snapshot.residentBytes

        // Act — drain the bounded initial reservoir so the producer can read again.
        for _ in 0..<initiallyRead {
            #expect(try source.read(maximumWait: 0) == packet)
        }
        try await waitFor { calls.value > initiallyRead && source.producerParkedForTesting }

        // Assert — the initial gate held within one record and no seek metadata was retained.
        #expect(initiallyRead == (budget + recordBytes - 1) / recordBytes)
        #expect(residency >= budget)
        #expect(residency < budget + recordBytes)
        #expect(source.retainedKeyframeSeconds.isEmpty)
        #expect(source.residentRanges.isEmpty)
    }

    /// Packet admission includes payload and side data, accepting the exact allocation boundary.
    @Test(arguments: [0, 4096])
    func test_packetAdmission_oversizedAllocationFails(sideDataBytes: Int) throws {
        // Arrange — use real FFmpeg allocation capacity rather than a fabricated byte estimate.
        let packet = try #require(av_packet_alloc())
        defer { var owned = Optional(packet); av_packet_free(&owned) }
        try #require(av_new_packet(packet, 1024) == 0)
        if sideDataBytes > 0 {
            _ = try #require(av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, sideDataBytes))
        }
        let cost = DirectLiveAudioReadAhead.packetBytes(packet)

        // Act — the exact limit admits this packet, while one byte less rejects it.
        try DirectLiveAudioReadAhead.validatePacketSize(packet, limit: cost)
        var rejected = false
        do {
            try DirectLiveAudioReadAhead.validatePacketSize(packet, limit: cost - 1)
        } catch DirectLiveAudioReadAhead.Failure.packetTooLarge(let bytes, let limit) {
            rejected = true
            #expect(bytes == cost)
            #expect(limit == cost - 1)
        }

        // Assert — admission has preserved caller ownership and the allocation remains intact.
        #expect(rejected)
        #expect(packet.pointee.size == 1024)
        #expect(DirectLiveAudioReadAhead.packetBytes(packet) == cost)
    }

    /// A side-data-heavy damaged packet cannot enter quarantine on its tiny payload cost alone.
    @Test
    func test_replay_sideDataExceedingAllowanceFails() throws {
        // Arrange — establish a valid frontier before introducing a damaged video boundary.
        let reader = LiveReplayPacketReader(
            videoIndex: 0,
            audioIndex: 1,
            videoTimeBase: 0.1,
            audioTimeBase: 0.1,
            residentLimit: 1024,
            retainedSize: { packet in
                var bytes = Int(packet.pointee.size)
                for index in 0..<Int(packet.pointee.side_data_elems) {
                    bytes += Int(packet.pointee.side_data[index].size)
                }
                return bytes
            }
        )
        var index = 0

        // Act — quarantine a one-byte damaged payload carrying 4 KiB of side data.
        #expect(throws: LiveReplayPacketReader.Failure.retentionExceeded) {
            while let packet = try reader.read(from: {
                if index > 80 { return nil }
                let packet = try #require(av_packet_alloc())
                try #require(av_new_packet(packet, 1) == 0)
                packet.pointee.stream_index = Int32(index % 2)
                packet.pointee.pts = Int64(index / 2)
                packet.pointee.dts = packet.pointee.pts
                packet.pointee.data[0] = 1
                if index == 80 {
                    packet.pointee.flags |= AV_PKT_FLAG_CORRUPT
                    _ = try #require(av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, 4096))
                }
                index += 1
                return packet
            }) {
                var owned = Optional(packet)
                av_packet_free(&owned)
            }
        }

        // Assert — the rejected packet was reached and explicit reset remains usable.
        #expect(index == 81)
        reader.reset()
        #expect(try reader.read(from: { nil }) == nil)
    }

    /// A deterministic keyframe envelope includes timing and side data that must survive polling.
    private static func packet(
        pts: Int64 = 10,
        payloadByteCount: Int = 3
    ) -> SoftwareStoredPacket {
        SoftwareStoredPacket(
            pts: pts, dts: pts, duration: 1, position: 0,
            streamIndex: 0, flags: 1, timeBaseNumerator: 1, timeBaseDenominator: 25,
            bytes: Data(repeating: 1, count: payloadByteCount), sideData: [.init(type: 1, bytes: Data([4, 5]))]
        )
    }

    /// Builds a memory-only forward source whose producer owns the supplied read closure.
    private static func source(
        read: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?
    ) -> SoftwarePacketReadAhead {
        SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 25),
            audio: nil,
            byteBudget: 1 << 20,
            forwardSeconds: 4,
            initialSourceClock: 0,
            fifo: SoftwarePacketMemoryFIFO(chunkTargetBytes: 4096, historyCapBytes: 0),
            forwardOnly: true,
            readSource: read
        )
    }
}
