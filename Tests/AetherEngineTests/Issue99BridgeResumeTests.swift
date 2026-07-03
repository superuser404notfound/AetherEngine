import XCTest
import Libavcodec
import Libavutil
@testable import AetherEngine

/// #99: VOD resume with bridged audio. Two defects:
///   A) An anchored INITIAL load never re-based the bridge encoder PTS, so bridged audio started at 0
///      while video carried the anchor's source PTS. Every fragment then held tracks ~15 minutes apart
///      and AVPlayer discarded everything (loadedTimeRanges stayed empty forever, no error posted).
///   B) A pump that reached EOF called flush(), which put the shared encoder into permanent draining
///      state; startSegment() only reset the decoder, and feed() swallowed the resulting AVERROR_EOF
///      silently. Every post-EOF restart then produced zero audio packets, the first cut could not
///      write the dec3 box ("Cannot write moov atom before EAC3 packets parsed") and the pump died.
final class Issue99BridgeResumeTests: XCTestCase {

    /// Little-endian 16-bit PCM WAV with a 440 Hz sine, built in memory (same shape as AudioTapDecoderTests).
    private func makeWAV(sampleRate: Int, channels: Int, seconds: Double) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            let v = Int16(9000 * sin(2 * .pi * 440 * Double(n) / Double(sampleRate)))
            for _ in 0..<channels {
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    /// Reads every audio packet of an in-memory WAV. Caller frees the packets.
    private func readAudioPackets(
        wav: Data
    ) throws -> (packets: [UnsafeMutablePointer<AVPacket>], codecpar: UnsafeMutablePointer<AVCodecParameters>, timeBase: AVRational, demuxer: Demuxer) {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: wav))
        let audioIdx = demuxer.audioStreamIndex
        guard audioIdx >= 0, let stream = demuxer.stream(at: audioIdx) else {
            throw NSError(domain: "test", code: 1)
        }
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == audioIdx {
                packets.append(packet)
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&p)
            }
        }
        return (packets, stream.pointee.codecpar, stream.pointee.time_base, demuxer)
    }

    private func freeAll(_ packets: inout [UnsafeMutablePointer<AVPacket>]) {
        for p in packets {
            var pp: UnsafeMutablePointer<AVPacket>? = p
            trackedPacketFree(&pp)
        }
        packets.removeAll()
    }

    // MARK: - A) resume alignment

    /// Anchored initial load (#99 failure mode A): the FIRST packets fed to a fresh bridge carry the
    /// resume position's source PTS. The bridge output must track that timeline, not restart at 0.
    /// No startSegment() call here on purpose: the initial anchored pump never issued one.
    func testFirstFeedTracksSourcePTSWithoutStartSegment() throws {
        let wav = makeWAV(sampleRate: 48_000, channels: 2, seconds: 1.0)
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }
        XCTAssertFalse(packets.isEmpty)

        // Simulate the resume anchor: shift the source timeline ~893.3 s forward.
        let resumeSeconds = 893.3
        let offsetTicks = Int64((resumeSeconds * Double(tb.den) / Double(tb.num)).rounded())
        for p in packets {
            if p.pointee.pts != Int64.min { p.pointee.pts += offsetTicks }
            if p.pointee.dts != Int64.min { p.pointee.dts += offsetTicks }
        }

        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .surroundCompat)
        defer { bridge.close() }

        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&outputs) }
        let firstFedPts = packets[0].pointee.pts
        for p in packets {
            outputs.append(contentsOf: try bridge.feed(packet: p))
        }
        XCTAssertFalse(outputs.isEmpty, "bridge produced no packets at all")

        let expected = av_rescale_q(firstFedPts, tb, bridge.encoderTimeBase)
        let actual = outputs[0].pointee.pts
        // One EAC3 frame (1536 samples) plus a little decoder slack; a 0-based output is ~43M ticks off.
        XCTAssertLessThan(
            abs(actual - expected), 4_000,
            "bridge output pts \(actual) does not track the resume source pts (expected ~\(expected)); "
            + "a 0-based timeline desyncs audio from video by the whole resume offset"
        )
    }

    // MARK: - B) EOF drain must not brick the bridge

    /// #99 failure mode B: flush() at pump EOF sent the encoder into draining state; a later restart
    /// (startSegment + fresh feeds) must produce packets again instead of silently emitting nothing.
    func testStartSegmentRevivesEncoderAfterEOFFlush() throws {
        let wav = makeWAV(sampleRate: 48_000, channels: 2, seconds: 1.0)
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }
        XCTAssertGreaterThan(packets.count, 3)

        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .surroundCompat)
        defer { bridge.close() }

        let half = packets.count / 2
        var outsFirst: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&outsFirst) }
        for p in packets[..<half] {
            outsFirst.append(contentsOf: try bridge.feed(packet: p))
        }
        XCTAssertFalse(outsFirst.isEmpty, "precondition: healthy bridge emits packets")

        var tail = bridge.flush()
        defer { freeAll(&tail) }

        // Producer restart after an EOF'd session (seek back into the file).
        bridge.startSegment()

        var outsSecond: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&outsSecond) }
        for p in packets[half...] {
            outsSecond.append(contentsOf: try bridge.feed(packet: p))
        }
        XCTAssertFalse(
            outsSecond.isEmpty,
            "bridge emitted nothing after EOF flush + startSegment: encoder stuck in draining state "
            + "(first cut then fails with 'Cannot write moov atom before EAC3 packets parsed')"
        )
    }

    /// Feeding after an EOF flush WITHOUT startSegment() is a caller bug; it must surface loudly
    /// instead of silently returning zero packets forever.
    func testFeedAfterEOFFlushWithoutStartSegmentThrows() throws {
        let wav = makeWAV(sampleRate: 48_000, channels: 2, seconds: 0.5)
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }
        XCTAssertGreaterThan(packets.count, 1)

        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .surroundCompat)
        defer { bridge.close() }

        _ = try bridge.feed(packet: packets[0])
        var tail = bridge.flush()
        freeAll(&tail)

        XCTAssertThrowsError(try bridge.feed(packet: packets[1])) { _ in }
    }

    // MARK: - VOD muxerFailed escalation gate

    /// A VOD pump death with reason muxerFailed previously had no recovery arm at all (only live
    /// sessions reopened). The revive gate allows a bounded number of producer rebuilds per session.
    func testMuxerFailureReviveGateAdmitsUpToCapThenRefuses() {
        var gate = MuxerFailureReviveGate(maxAttempts: 2)
        XCTAssertTrue(gate.admit())
        XCTAssertTrue(gate.admit())
        XCTAssertFalse(gate.admit())
        XCTAssertFalse(gate.admit())
        XCTAssertEqual(gate.attempts, 4)
    }
}
