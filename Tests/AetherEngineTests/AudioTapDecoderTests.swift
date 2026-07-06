import XCTest
import AVFAudio
import Libavcodec
@testable import AetherEngine

/// #95: tap decoder (compressed packets to mono Float32 48 kHz) and the per-segment
/// composition decoder. The positive path runs a synthesized WAV through the real
/// Demuxer (wav demuxer + pcm_s16le decoder are in the FFmpegBuild allowlist).
final class AudioTapDecoderTests: XCTestCase {

    /// Little-endian 16-bit PCM WAV with a 440 Hz sine, built in memory.
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

    func testStereo44100DownmixesAndResamplesToMono48k() throws {
        let wav = makeWAV(sampleRate: 44_100, channels: 2, seconds: 2.0)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: wav))
        defer { demuxer.close() }
        let audioIdx = demuxer.audioStreamIndex
        XCTAssertGreaterThanOrEqual(audioIdx, 0)
        guard let stream = demuxer.stream(at: audioIdx) else { return XCTFail("no stream") }

        let decoder = AudioTapDecoder()
        try decoder.open(stream: stream)
        defer { decoder.close() }

        var chunks: [AudioTapChunk] = []
        while let packet = try demuxer.readPacket() {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&p) }
            guard packet.pointee.stream_index == audioIdx else { continue }
            chunks.append(contentsOf: decoder.decode(packet: packet))
        }
        chunks.append(contentsOf: decoder.drain())

        XCTAssertFalse(chunks.isEmpty)
        var totalSamples: AVAudioFrameCount = 0
        var lastPTS = -Double.infinity
        for c in chunks {
            XCTAssertEqual(c.buffer.format.sampleRate, 48_000)
            XCTAssertEqual(c.buffer.format.channelCount, 1)
            XCTAssertGreaterThan(c.ptsSeconds, lastPTS)
            lastPTS = c.ptsSeconds
            totalSamples += c.buffer.frameLength
        }
        // 2.0 s of source audio resampled to 48 kHz, within 5 %.
        XCTAssertEqual(Double(totalSamples), 96_000, accuracy: 4800)
        XCTAssertEqual(chunks[0].ptsSeconds, 0, accuracy: 0.1)
    }

    func testSegmentDecoderReturnsEmptyOnGarbage() {
        let dec = AudioTapSegmentDecoder()
        let chunks = dec.decode(initData: Data([0, 1, 2, 3]), segment: Data(repeating: 0xAB, count: 512))
        XCTAssertTrue(chunks.isEmpty)
    }

    func testSelfContainedSegmentDecodes() {
        let wav = makeWAV(sampleRate: 48_000, channels: 1, seconds: 1.0)
        let chunks = AudioTapSegmentDecoder().decode(selfContainedSegment: wav)
        XCTAssertFalse(chunks.isEmpty)
        var total: AVAudioFrameCount = 0
        for c in chunks {
            XCTAssertEqual(c.buffer.format.sampleRate, 48_000)
            total += c.buffer.frameLength
        }
        XCTAssertEqual(Double(total), 48_000, accuracy: 2400)   // ~1 s at 48k
    }

    func testSelfContainedGarbageReturnsEmpty() {
        XCTAssertTrue(AudioTapSegmentDecoder().decode(selfContainedSegment: Data([0, 1, 2, 3])).isEmpty)
    }
}
