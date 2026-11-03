import XCTest
import AVFAudio
import AetherLibavcodec
import AetherLibavutil
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

    // MARK: - Dialogue channel (#908)

    /// 16-bit WAVE_FORMAT_EXTENSIBLE with an explicit channel mask, so FFmpeg reads a real layout
    /// (a plain 6-channel header leaves the order to a guess). `sample(channel, frame)` in -1...1.
    private func makeExtensibleWAV(channelMask: UInt32, channels: Int, seconds: Double,
                                   sample: (Int, Int) -> Double) -> Data {
        let rate = 48_000
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            for c in 0..<channels {
                let v = Int16(max(-1, min(1, sample(c, n))) * 32767)
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(60 + pcm.count)); str("WAVE")
        str("fmt "); u32(40); u16(0xFFFE); u16(UInt16(channels)); u32(UInt32(rate))
        u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        u16(22); u16(16); u32(channelMask)
        // KSDATAFORMAT_SUBTYPE_PCM
        d.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                              0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    /// FL FR FC LFE BL BR.
    private static let fiveOneMask: UInt32 = 0x3F

    private func peak(_ chunks: [AudioTapChunk]) -> Float {
        var p: Float = 0
        for c in chunks {
            let s = c.buffer.floatChannelData![0]
            for i in 0..<Int(c.buffer.frameLength) { p = max(p, abs(s[i])) }
        }
        return p
    }

    private func tone(_ n: Int, _ hz: Double) -> Double { sin(2 * .pi * hz * Double(n) / 48_000) }

    func testDialogueDecodesTheCentreAloneFromA51Mix() {
        // Centre silent, every other channel loud: the dialogue tap must hear nothing.
        let wav = makeExtensibleWAV(channelMask: Self.fiveOneMask, channels: 6, seconds: 1) { c, n in
            c == 2 ? 0 : 0.5 * self.tone(n, 220)
        }
        let dialogue = AudioTapSegmentDecoder(channels: .dialogue).decode(selfContainedSegment: wav)
        XCTAssertFalse(dialogue.isEmpty)
        XCTAssertTrue(dialogue.allSatisfy { $0.channels == .dialogue })
        XCTAssertLessThan(peak(dialogue), 0.001)

        let downmix = AudioTapSegmentDecoder().decode(selfContainedSegment: wav)
        XCTAssertTrue(downmix.allSatisfy { $0.channels == .downmix })
        XCTAssertGreaterThan(peak(downmix), 0.1)
    }

    func testDialogueCarriesTheCentreAtUnity() {
        let wav = makeExtensibleWAV(channelMask: Self.fiveOneMask, channels: 6, seconds: 1) { c, n in
            c == 2 ? 0.5 * self.tone(n, 440) : 0
        }
        let chunks = AudioTapSegmentDecoder(channels: .dialogue).decode(selfContainedSegment: wav)
        XCTAssertEqual(peak(chunks), 0.5, accuracy: 0.02)
    }

    func testDialogueFallsBackToTheDownmixOnStereoAndMono() {
        for channels in [1, 2] {
            let wav = makeWAV(sampleRate: 48_000, channels: channels, seconds: 1)
            let chunks = AudioTapSegmentDecoder(channels: .dialogue).decode(selfContainedSegment: wav)
            XCTAssertFalse(chunks.isEmpty, "\(channels)ch")
            XCTAssertTrue(chunks.allSatisfy { $0.channels == .downmix }, "\(channels)ch")
            XCTAssertGreaterThan(peak(chunks), 0.1, "\(channels)ch")
        }
    }

    /// A layout that states only a count is read in the default order for it, as swresample and
    /// the software path read it; mono and stereo still have no centre to take.
    func testCentreIndexReadsACountOnlyLayoutInTheDefaultOrder() {
        func index(_ count: Int32, order: AVChannelOrder) -> Int? {
            var layout = AVChannelLayout()
            if order == AV_CHANNEL_ORDER_UNSPEC {
                layout.order = order
                layout.nb_channels = count
            } else {
                av_channel_layout_default(&layout, count)
            }
            defer { av_channel_layout_uninit(&layout) }
            return AudioTapDecoder.centreIndex(of: &layout)
        }
        XCTAssertEqual(index(6, order: AV_CHANNEL_ORDER_UNSPEC), 2)
        XCTAssertEqual(index(6, order: AV_CHANNEL_ORDER_NATIVE), 2)
        XCTAssertNil(index(2, order: AV_CHANNEL_ORDER_UNSPEC))
        XCTAssertNil(index(1, order: AV_CHANNEL_ORDER_NATIVE))
    }

    func testSelfContainedGarbageReturnsEmpty() {
        XCTAssertTrue(AudioTapSegmentDecoder().decode(selfContainedSegment: Data([0, 1, 2, 3])).isEmpty)
    }
}
