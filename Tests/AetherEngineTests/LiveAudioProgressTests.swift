import Foundation
import CoreMedia
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// Ordinary software Live keeps delivering audio when its video renderer cannot accept frames.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct LiveAudioProgressTests {
    /// A disk-cache preference must not disable playback or shrink the memory-only Live reservoir.
    @Test(arguments: [0, 1 << 20])
    func test_livePlayback_smallDiskCacheBudget_deliversAudio(budget: Int) async throws {
        // Arrange
        let engine = try AetherEngine()
        let delivered = ProbeTestBox(0)
        defer { engine.stop() }
        var options = LoadOptions(isLive: true, autoplay: false, preferredDecodePath: .software)
        options.sessionCacheByteBudget = budget

        // Act
        try await engine.load(
            source: .custom(ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data()),
                            formatHint: "mpegts"),
            options: options
        )
        let host = try #require(engine.softwareHost)
        host.observeDeliveredAudioForTesting { delivered.update { $0 += 1 } }
        engine.play()
        try await waitFor { delivered.value >= 24 || engine.errorInfo != nil }

        // Assert
        #expect(engine.errorInfo == nil)
        #expect(host.directLiveReadAheadForTesting != nil)
        #expect(delivered.value >= 24)
    }

    /// Large keyframes must wait for older parked video, then enter alone without deadlocking.
    @Test
    func test_videoParking_oversizedPacket_waitsOnlyUntilQueueDrains() {
        // Arrange
        let limit = 4 << 20
        let oversized = limit + 1

        // Act
        let waitsBehindVideo = SoftwarePlaybackHost.shouldWaitForLivePacketCapacity(
            parkedBytes: 1024, packetBytes: oversized, byteLimit: limit
        )
        let waitsAfterDrain = SoftwarePlaybackHost.shouldWaitForLivePacketCapacity(
            parkedBytes: 0, packetBytes: oversized, byteLimit: limit
        )
        let admitsAnotherPacket = !SoftwarePlaybackHost.shouldWaitForLivePacketCapacity(
            parkedBytes: oversized, packetBytes: 1024, byteLimit: limit
        )

        // Assert
        #expect(waitsBehindVideo)
        #expect(!waitsAfterDrain)
        #expect(!admitsAnotherPacket)
        #expect(!SoftwarePlaybackHost.shouldWaitForLivePacketCapacity(
            parkedBytes: limit - 1024, packetBytes: 1024, byteLimit: limit
        ))
    }

    // Failure modes:
    // - A full video renderer prevents the sole reader from reaching later audio packets.
    // - Source I/O prevents already parked video from reaching a ready renderer.
    // - Cancellation leaves the producer alive after source I/O retires.
    // - The forward-only source is mistaken for DVR or ends before its retained tail drains.

    /// Exercises the real audio decoder and renderer while video readiness remains closed (AE#934).
    @Test
    func test_audioDelivery_closedVideoGate_deliversSubsequentAudio() async throws {
        // Arrange - close video readiness before the demux loop starts.
        let reader = ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data())
        let engine = try AetherEngine()
        let ready = ProbeTestBox(false)
        let delivered = ProbeTestBox(0)
        defer {
            ready.update { $0 = true }
            engine.stop()
        }
        try await engine.load(
            source: .custom(reader, formatHint: "mpegts"),
            options: LoadOptions(isLive: true, autoplay: false, preferredDecodePath: .software)
        )
        let host = try #require(engine.softwareHost)
        host.videoRendererForTesting.readyForMoreMediaDataForTesting = { ready.value }
        host.observeDeliveredAudioForTesting { delivered.update { $0 += 1 } }

        // Act - audio must advance without changing the video gate.
        engine.play()
        try await waitFor { delivered.value >= 24 || engine.errorInfo != nil }

        // Assert - more than one audio burst reached the real renderer.
        #expect(engine.errorInfo == nil)
        #expect(delivered.value >= 24)
        #expect(host.videoRendererForTesting.takeCadence().handedOver == 0)
        #expect(engine.liveWindow?.windowSeconds == nil)
    }

    /// Background audio must escape a video read gate that was already full before the transition.
    @Test(arguments: [true, false])
    func test_backgroundAudio_fullParkedVideoQueue_resumesAudioDelivery(isLive: Bool) async throws {
        // Arrange - reach the actual packet cap with video readiness held closed.
        let engine = try AetherEngine()
        let ready = ProbeTestBox(false)
        let delivered = ProbeTestBox(0)
        defer {
            ready.update { $0 = true }
            engine.stop()
        }
        try await engine.load(
            source: .custom(ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data()),
                            formatHint: "mpegts"),
            options: LoadOptions(isLive: isLive, autoplay: false, preferredDecodePath: .software)
        )
        let host = try #require(engine.softwareHost)
        try #require((host.directLiveReadAheadForTesting != nil) == isLive)
        host.videoRendererForTesting.readyForMoreMediaDataForTesting = { ready.value }
        host.observeDeliveredAudioForTesting { delivered.update { $0 += 1 } }
        engine.setRate(2)
        engine.play()
        try await waitFor { host.parkedVideoCountForTesting == 256 || engine.errorInfo != nil }
        try #require(engine.errorInfo == nil)
        try #require(host.parkedVideoCountForTesting == 256)
        let beforeBackground = delivered.value

        // Act - keep video closed while changing only the host's background mode.
        host.enterBackgroundAudioOnly()
        try await waitFor { delivered.value >= beforeBackground + 24 || engine.errorInfo != nil }

        // Assert - the full queue was retired and no longer prevents subsequent audio reads.
        #expect(engine.errorInfo == nil)
        #expect(host.parkedVideoCountForTesting == 0)
        #expect(delivered.value >= beforeBackground + 24)
        #expect(host.videoRendererForTesting.takeCadence().handedOver == 0)
        #expect(host.clockRateForTesting ?? 0 > 0)
    }

    /// A blocked source read does not hold video that has already reached the consumer's queue.
    @Test
    func test_videoDelivery_sourceReadHeld_drainsReadyVideo() async throws {
        // Arrange - hold source I/O after enough packets have arrived to park video.
        let sourceGate = ProbeTestGate()
        let producerReads = ProbeTestBox(0)
        let ready = ProbeTestBox(false)
        let reader = ProbeRecordingReader(
            data: try LongGOPTransportStreamFixture.data(),
            chunkSize: 4096,
            afterRead: {
                if Thread.current.name == "AetherEngine.SoftwarePacketReadAhead.producer" {
                    producerReads.update { $0 += 1 }
                    if producerReads.value >= 2 { sourceGate.wait() }
                }
            },
            afterCancel: { sourceGate.open() }
        )
        let engine = try AetherEngine()
        defer {
            sourceGate.open()
            ready.update { $0 = true }
            engine.stop()
        }
        try await engine.load(
            source: .custom(reader, formatHint: "mpegts"),
            options: LoadOptions(isLive: true, autoplay: false, preferredDecodePath: .software)
        )
        let host = try #require(engine.softwareHost)
        host.videoRendererForTesting.readyForMoreMediaDataForTesting = { ready.value }
        engine.play()
        try await waitFor { sourceGate.entered || engine.errorInfo != nil }
        try #require(engine.errorInfo == nil)
        let readsWhileHeld = producerReads.value

        // Act - make only the renderer ready; the source remains blocked.
        ready.update { $0 = true }
        try await waitFor {
            host.videoRendererForTesting.takeCadence().handedOver >= 20 || engine.errorInfo != nil
        }

        // Assert - queued video progressed independently of further source reads.
        #expect(engine.errorInfo == nil)
        #expect(host.videoRendererForTesting.takeCadence().handedOver >= 20)
        #expect(producerReads.value == readsWhileHeld)
        #expect(!sourceGate.isOpen)
        let source = try #require(host.directLiveReadAheadForTesting?.packets)
        try await waitFor {
            host.parkedVideoCountForTesting == 0 && source.snapshot.packetCount == 0
                && source.consumerWaitStateForTesting.waiting > 0
        }
        let completedWaits = source.consumerWaitStateForTesting.completed
        let repeatedlyWoke = try await waitFor(upTo: .milliseconds(200)) {
            source.consumerWaitStateForTesting.completed > completedWaits + 1
        }
        #expect(!repeatedlyWoke, "An empty Live source must sleep until data or cancellation, not poll")
        engine.stop()
        #expect(sourceGate.isOpen)
        #expect(reader.cancelCount > 0)
        #expect(engine.state == .idle)
    }

    /// Closing is idempotent and the blocked producer retires after its source read returns.
    @Test
    func test_close_sourceStillHeld_retiresWorkerAfterReadReturns() async throws {
        // Arrange - block only the read-ahead producer.
        let sourceGate = ProbeTestGate()
        let producerReads = ProbeTestBox(0)
        let reader = ProbeRecordingReader(
            data: try LongGOPTransportStreamFixture.data(),
            chunkSize: 4096,
            afterRead: {
                if Thread.current.name == "AetherEngine.SoftwarePacketReadAhead.producer" {
                    producerReads.update { $0 += 1 }
                    if producerReads.value >= 2 { sourceGate.wait() }
                }
            },
            afterCancel: { sourceGate.open() }
        )
        let demuxer = Demuxer()
        defer {
            sourceGate.open()
            demuxer.close()
        }
        var source: DirectLiveAudioReadAhead? = try await BlockingWork.detached {
            try demuxer.open(reader: reader, formatHint: "mpegts", isLive: true)
            return try DirectLiveAudioReadAhead(
                demuxer: demuxer,
                videoIndex: demuxer.videoStreamIndex,
                audioIndex: demuxer.audioStreamIndex
            )
        }.value
        defer { source?.close() }
        weak var worker = source?.packets
        source?.packets.start()
        try await waitFor { sourceGate.entered }

        // Act - retire the consumer while its producer remains inside source I/O.
        source?.close()
        source?.close()
        source = nil

        // Assert - the worker survives its active read and is released after it returns.
        #expect(worker != nil)
        #expect(!sourceGate.isOpen)
        sourceGate.open()
        try await waitFor { worker == nil }
    }

    /// Buffer capacity and side data are charged in addition to the packet's visible payload.
    @Test
    func test_packetCost_sideDataPresent_includesAllocation() throws {
        // Arrange - allocate a real packet before adding side data.
        let packet = try #require(av_packet_alloc())
        defer {
            var owned = Optional(packet)
            av_packet_free(&owned)
        }
        try #require(av_new_packet(packet, 1024) == 0)
        let before = DirectLiveAudioReadAhead.packetBytes(packet)

        // Act - allocate metadata that must count toward the same storage allowance.
        _ = try #require(av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, 4096))

        // Assert - payload-only accounting cannot satisfy this bound.
        #expect(DirectLiveAudioReadAhead.packetBytes(packet) >= before + 4096)
    }

    /// Ordinary lip-sync offsets keep using the ringless source and still deliver decoded audio.
    @Test(arguments: [-0.5, 0.5])
    func test_audioDelay_smallSignedOffset_keepsDirectLiveRoute(delay: Double) async throws {
        // Arrange - request a supported signed offset before playback starts.
        let engine = try AetherEngine()
        let delivered = ProbeTestBox(0)
        defer { engine.stop() }
        try await engine.load(
            source: .custom(
                ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data()),
                formatHint: "mpegts"
            ),
            options: LoadOptions(
                isLive: true,
                autoplay: false,
                audioDelaySeconds: delay,
                preferredDecodePath: .software
            )
        )
        let host = try #require(engine.softwareHost)
        host.observeDeliveredAudioForTesting { delivered.update { $0 += 1 } }

        // Act - let the actual audio decoder and renderer process the offset session.
        engine.play()
        try await waitFor { delivered.value > 0 || engine.errorInfo != nil }

        // Assert - the offset does not opt into DVR or remove the direct source.
        #expect(engine.errorInfo == nil)
        #expect(delivered.value > 0)
        #expect(engine.audioDelaySeconds == delay)
        #expect(host.directLiveReadAheadForTesting != nil)
        #expect(engine.liveWindow?.windowSeconds == nil)
    }

    /// Both advertised DVR and a cushion-only ring keep their separate feeder path.
    @Test(arguments: [true, false])
    func test_liveRing_existingFeeder_doesNotCreateDirectSource(advertisesDVR: Bool) async throws {
        // Arrange - a cushion retains a ring even though its public rewind window stays absent.
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions(isLive: true, autoplay: false, preferredDecodePath: .software)
        if advertisesDVR {
            options.dvrWindowSeconds = 30
        } else {
            options.liveEdgeCushionSeconds = 2
        }

        // Act - construct the selected software Live route.
        try await engine.load(
            source: .custom(
                ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data()),
                formatHint: "mpegts"
            ),
            options: options
        )

        // Assert - prove a ring exists so a failed ring allocation cannot make this pass.
        let host = try #require(engine.softwareHost)
        #expect(host.liveDVRBytes != nil)
        #expect(host.directLiveReadAheadForTesting == nil)
    }

    /// Source EOF is only terminal after retained video and decoded audio have drained.
    @Test
    func test_finiteLive_sourceEnds_drainsBeforeEnding() async throws {
        // Arrange - the synthetic source contains 32 seconds of audio and video.
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await engine.load(
            source: .custom(
                ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data()),
                formatHint: "mpegts"
            ),
            options: LoadOptions(isLive: true, autoplay: false, preferredDecodePath: .software)
        )
        let host = try #require(engine.softwareHost)
        engine.setRate(2)

        // Act - consume the finite source through the ordinary Live route.
        engine.play()
        try await waitFor { engine.state == .ended || engine.errorInfo != nil }

        // Assert - reaching EOF in the producer did not discard the consumer's tail.
        #expect(engine.errorInfo == nil)
        #expect(engine.state == .ended)
        #expect(engine.currentTime > 30)
        #expect(host.videoRendererForTesting.takeCadence().handedOver > 100)
    }

    /// A declared AAC track with no packets cannot leave the clock unarmed at a full video gate.
    @Test
    func test_clockArming_declaredAudioNeverArrives_armsFromParkedVideo() async throws {
        // Arrange - retain the audio declaration while removing only its transport payload.
        let data = try await BlockingWork.detached { try Self.fixtureWithoutAudio() }.value
        let engine = try AetherEngine()
        let delivered = ProbeTestBox(0)
        let ready = ProbeTestBox(false)
        defer {
            ready.update { $0 = true }
            engine.stop()
        }
        try await engine.load(
            source: .custom(ProbeRecordingReader(data: data), formatHint: "mpegts"),
            options: LoadOptions(isLive: true, autoplay: false, preferredDecodePath: .software)
        )
        let host = try #require(engine.softwareHost)
        try #require(host.audioDelivery == .decoded)
        try #require(host.directLiveReadAheadForTesting != nil)
        host.videoRendererForTesting.readyForMoreMediaDataForTesting = { ready.value }
        host.observeDeliveredAudioForTesting { delivered.update { $0 += 1 } }

        // Act - exhaust the source or parking allowance without a buffer that could arm audio.
        engine.play()
        try await waitFor { (host.clockRateForTesting ?? 0) > 0 || engine.errorInfo != nil }

        // Assert - AE#337's video fallback starts the unchanged Live clock.
        #expect(engine.errorInfo == nil)
        #expect((host.clockRateForTesting ?? 0) > 0)
        #expect(delivered.value == 0)
        #expect(!ready.value)
    }

    /// Audio placed before the first keyframe never reaches the real decoder/output at a Live join.
    @Test
    func test_liveJoin_audioBeforeFirstKeyframe_dropsLeadingAudio() async throws {
        // Arrange - move one intact audio PES ahead of video and measure its source timestamps.
        let fixture = try await BlockingWork.detached { try Self.fixtureWithLeadingAudio() }.value
        let engine = try AetherEngine()
        let deliveredPTS = ProbeTestBox<[Double]>([])
        defer { engine.stop() }
        try await engine.load(
            source: .custom(ProbeRecordingReader(data: fixture.data), formatHint: "mpegts"),
            options: LoadOptions(isLive: true, autoplay: false, preferredDecodePath: .software)
        )
        let host = try #require(engine.softwareHost)
        try #require(host.directLiveReadAheadForTesting != nil)
        host.audioTapSink = { buffer in
            deliveredPTS.update { $0.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds) }
        }

        // Act - join through the new ringless source and the real audio decoder.
        engine.play()
        try await waitFor { !deliveredPTS.value.isEmpty || engine.errorInfo != nil }

        // Assert - AE#844 discarded the entire pre-keyframe audio prefix before decoding it.
        #expect(engine.errorInfo == nil)
        let firstDelivered = try #require(deliveredPTS.value.first)
        #expect(firstDelivered > fixture.preKeyframeAudioEnd)
    }

    /// Resolves stream PIDs from the existing synthetic source, then splits its complete TS records.
    nonisolated private static func fixtureTransportPackets() throws -> (
        packets: [Data], videoPID: Int, audioPID: Int
    ) {
        let data = try LongGOPTransportStreamFixture.data()
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: ProbeRecordingReader(data: data), formatHint: "mpegts")
        let video = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let audio = try #require(demuxer.stream(at: demuxer.audioStreamIndex))
        try #require(data.count.isMultiple(of: 188))
        let packets = stride(from: 0, to: data.count, by: 188).map {
            Data(data[$0..<($0 + 188)])
        }
        return (packets, Int(video.pointee.id), Int(audio.pointee.id))
    }

    /// Reads the transport PID without interpreting or changing its encoded payload.
    nonisolated private static func transportPID(_ packet: Data) -> Int {
        (Int(packet[1] & 0x1f) << 8) | Int(packet[2])
    }

    /// Keeps the PMT's AAC track and every video packet while omitting all AAC transport packets.
    nonisolated private static func fixtureWithoutAudio() throws -> Data {
        let fixture = try fixtureTransportPackets()
        return fixture.packets.reduce(into: Data()) { result, packet in
            if transportPID(packet) != fixture.audioPID { result.append(packet) }
        }
    }

    /// Reorders one complete AAC PES ahead of video, preserving the original encoded media.
    nonisolated private static func fixtureWithLeadingAudio() throws -> (
        data: Data, preKeyframeAudioEnd: Double
    ) {
        let fixture = try fixtureTransportPackets()
        var movedIndices: Set<Int> = []
        var leadingAudio = Data()
        var started = false
        for (index, packet) in fixture.packets.enumerated() {
            if transportPID(packet) != fixture.audioPID { continue }
            if packet[1] & 0x40 != 0 {
                if started { break }
                started = true
            }
            if started {
                movedIndices.insert(index)
                leadingAudio.append(packet)
            }
        }
        try #require(!leadingAudio.isEmpty)
        let firstVideo = try #require(fixture.packets.firstIndex {
            transportPID($0) == fixture.videoPID
        })
        var data = Data()
        for (index, packet) in fixture.packets.enumerated() {
            if index == firstVideo { data.append(leadingAudio) }
            if !movedIndices.contains(index) { data.append(packet) }
        }

        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: ProbeRecordingReader(data: data), formatHint: "mpegts")
        let audio = try #require(demuxer.stream(at: demuxer.audioStreamIndex))
        let audioTimeBase = av_q2d(audio.pointee.time_base)
        var preKeyframeAudioEnd: Double?
        while let packet = try demuxer.readPacket() {
            defer {
                var owned = Optional(packet)
                av_packet_free(&owned)
            }
            if packet.pointee.stream_index == demuxer.videoStreamIndex,
               packet.pointee.flags & AV_PKT_FLAG_KEY != 0 { break }
            if packet.pointee.stream_index == demuxer.audioStreamIndex {
                try #require(packet.pointee.pts != Int64.min)
                let pts = Double(packet.pointee.pts) * audioTimeBase
                preKeyframeAudioEnd = max(preKeyframeAudioEnd ?? pts, pts)
            }
        }
        return (data, try #require(preKeyframeAudioEnd))
    }
}
