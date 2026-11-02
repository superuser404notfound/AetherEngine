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
    // - Live forwarding retains seek metadata or rejects a packet larger than its pacing bound.

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

    /// The real direct-live producer preserves packets whose payload or metadata crosses its bound.
    @Test(arguments: [false, true])
    func test_directLiveSource_oversizedPacketDeliversIntact(sideDataOversized: Bool) async throws {
        // Arrange — enlarge a demuxer-owned peek packet before its sole producer starts (AE#963).
        let demuxer = Demuxer()
        defer { demuxer.close() }
        let (source, expected) = try await BlockingWork.detached {
            try demuxer.open(
                reader: ProbeRecordingReader(data: LongGOPTransportStreamFixture.data()),
                formatHint: "mpegts",
                isLive: true
            )
            var peeked: UnsafeMutablePointer<AVPacket>?
            try demuxer.peekPackets(maxPackets: 1) { packet in
                peeked = packet
                return true
            }
            let packet = try #require(peeked)
            if sideDataOversized {
                let sideData = try #require(
                    av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, 5 << 20)
                )
                sideData.initialize(repeating: 7, count: 5 << 20)
            } else {
                let originalSize = Int(packet.pointee.size)
                try #require(av_grow_packet(packet, Int32(5 << 20)) == 0)
                packet.pointee.data.advanced(by: originalSize).initialize(repeating: 7, count: 5 << 20)
            }
            let expected = try SoftwareStoredPacket(copying: packet)
            let source = try DirectLiveAudioReadAhead(
                demuxer: demuxer,
                videoIndex: demuxer.videoStreamIndex,
                audioIndex: demuxer.audioStreamIndex
            )
            return (source, expected)
        }.value
        defer { source.close() }

        // Act — cross replay admission and packet serialization through the real producer.
        source.packets.start()
        let consumer = ProbeTestJob { try source.packets.read() }
        let result = try await consumer.outcome()

        // Assert — neither a large payload nor side data becomes a terminal size rejection.
        #expect(try result.get() == expected)
    }

    /// A valid packet larger than the forward window remains deliverable and parks further reads.
    @Test
    func test_forwardSource_oversizedPacketDeliversAndConsumptionResumes() async throws {
        // Arrange — one untimed packet alone exceeds the direct-live 4 MiB pacing bound (AE#963).
        let calls = ProbeTestBox(0)
        let packet = Self.packet(pts: Int64.min, payloadByteCount: 5 << 20)
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 25),
            audio: nil,
            byteBudget: 4 << 20,
            forwardSeconds: 4,
            initialSourceClock: 0,
            fifo: SoftwarePacketMemoryFIFO(chunkTargetBytes: 4096, historyCapBytes: 0),
            forwardOnly: true
        ) { _ in
            calls.update { $0 += 1 }
            return calls.value <= 2 ? packet : nil
        }
        defer { source.close() }
        source.start()
        try await waitFor { source.producerParkedForTesting }
        #expect(calls.value == 1)
        #expect(source.snapshot.packetCount == 1)

        // Act — consuming the overshoot must let the next intact packet enter the reservoir.
        #expect(try source.read(maximumWait: 0) == packet)
        try await waitFor { calls.value == 2 && source.producerParkedForTesting }
        #expect(source.snapshot.packetCount == 1)
        #expect(try source.read(maximumWait: 0) == packet)
        try await waitFor { source.snapshot.sourceEnded }

        // Assert — both packets arrived once, followed by real EOF without retained seek history.
        #expect(calls.value == 3)
        #expect(try source.read(maximumWait: 0) == nil)
        #expect(source.retainedKeyframeSeconds.isEmpty)
        #expect(source.residentRanges.isEmpty)
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
