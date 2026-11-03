import XCTest
import AVFAudio
import CoreMedia
@testable import AetherEngine

/// #95 SW path: AudioDecoder emits interleaved Float32 CMSampleBuffers; the converter turns
/// them into tap-format buffers and tracks PTS continuity across calls.
final class AudioTapPCMConverterTests: XCTestCase {

    /// Interleaved Float32 CMSampleBuffer at a given rate/channel count, constant value, with a
    /// given PTS. `layoutTag` mirrors AudioDecoder, which always attaches a layout to its format
    /// description; pass nil for the defensive case of a description that carries none.
    private func makeSample(seconds: Double, pts: Double, sampleRate: Double = 44_100,
                            channels: UInt32 = 2,
                            layoutTag: AudioChannelLayoutTag? = nil,
                            values: [Float]? = nil) throws -> CMSampleBuffer {
        let frames = Int(seconds * sampleRate)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        if let layoutTag {
            var layout = AudioChannelLayout(mChannelLayoutTag: layoutTag, mChannelBitmap: [],
                                            mNumberChannelDescriptions: 0,
                                            mChannelDescriptions: AudioChannelDescription())
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd,
                                           layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                           layout: &layout,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &fmt)
        } else {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &fmt)
        }
        let frame = values ?? [Float](repeating: 0.25, count: Int(channels))
        let data = (0..<frames).flatMap { _ in frame }
        var block: CMBlockBuffer?
        let byteCount = data.count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &block)
        data.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!,
                                              offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }

    func testConvertsToTapFormatAndKeepsPTS() throws {
        let conv = AudioTapPCMConverter()
        let out1 = conv.convert(try makeSample(seconds: 0.5, pts: 12.0))
        XCTAssertFalse(out1.isEmpty)
        XCTAssertTrue(out1[0].discontinuity)                      // first buffer after install
        XCTAssertEqual(out1[0].sourceTime, 12.0, accuracy: 0.01)
        let out2 = conv.convert(try makeSample(seconds: 0.5, pts: 12.5))
        // The SRC keeps a small in-flight window per call (samples are delayed into the next
        // call, not lost): assert the cumulative output over two calls, minus that window.
        let total = (out1 + out2).reduce(0) { $0 + Int($1.buffer.frameLength) }
        XCTAssertGreaterThan(total, 44_000)                       // ~1.0 s at 48 kHz
        XCTAssertLessThanOrEqual(total, 48_000)
        for b in out1 + out2 {
            XCTAssertEqual(b.buffer.format.sampleRate, 48_000)
            XCTAssertEqual(b.buffer.format.channelCount, 1)
        }
    }

    func testContiguousBuffersDoNotFlagDiscontinuity() throws {
        let conv = AudioTapPCMConverter()
        _ = conv.convert(try makeSample(seconds: 0.5, pts: 12.0))
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 12.5))
        XCTAssertFalse(out.contains { $0.discontinuity })
    }

    func testPTSJumpFlagsDiscontinuity() throws {
        let conv = AudioTapPCMConverter()
        _ = conv.convert(try makeSample(seconds: 0.5, pts: 12.0))
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 90.0))   // SW seek
        XCTAssertTrue(out[0].discontinuity)
    }

    /// #400: AudioDecoder emits the source channel count (up to 7.1) without downmixing, so a
    /// multichannel track on the software path hands the converter 3-8 interleaved channels.
    func testDownmixesEveryDecoderChannelCountToMonoTap() throws {
        for channels: UInt32 in 1...8 {
            let conv = AudioTapPCMConverter()
            let tag = audioChannelLayoutTag(for: Int32(channels))
            let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000,
                                                  channels: channels, layoutTag: tag))
            XCTAssertFalse(out.isEmpty, "no tap buffer for \(channels)ch input")
            for b in out {
                XCTAssertEqual(b.buffer.format.channelCount, 1)
                XCTAssertEqual(b.buffer.format.sampleRate, 48_000)
            }
            // A downmix that yields buffers of silence is as useless to the tap consumers as
            // no buffers at all, so assert the signal survived the layout mapping.
            XCTAssertGreaterThan(peak(out), 0.05, "\(channels)ch downmix is silent")
        }
    }

    /// A downmix has to hear every channel but the LFE. Equal values on every channel cannot
    /// tell a mix from a pick, which is how a converter that mapped stereo to its left channel and
    /// 5.1 to its centre passed the test above (#908); so drive one channel at a time.
    func testDownmixHearsEveryChannelButTheLFE() throws {
        for channels: UInt32 in 2...8 {
            let tag = audioChannelLayoutTag(for: Int32(channels))
            let lfe: Int? = channels == 3 ? 2 : (channels >= 6 ? 3 : nil)
            for ch in 0..<Int(channels) where ch != lfe {
                var values = [Float](repeating: 0, count: Int(channels))
                values[ch] = 0.5
                let out = AudioTapPCMConverter().convert(
                    try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000, channels: channels,
                                   layoutTag: tag, values: values))
                XCTAssertTrue(out.allSatisfy { $0.channels == .downmix })
                XCTAssertGreaterThan(peak(out), 0.05, "\(channels)ch: channel \(ch) missing from the downmix")
            }
        }
    }

    /// The same input with no channel layout on the format description must not trap either.
    func testMultichannelWithoutChannelLayoutStillConverts() throws {
        let conv = AudioTapPCMConverter()
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000,
                                              channels: 6, layoutTag: nil))
        XCTAssertFalse(out.isEmpty)
        XCTAssertEqual(out[0].buffer.format.channelCount, 1)
        XCTAssertGreaterThan(peak(out), 0.05)
    }

    /// The other measured silent class: a discrete layout has no mixdown matrix at any channel
    /// count, so the tap has to fold it itself rather than yield buffers of zeroes.
    func testDiscreteLayoutStillCarriesSignal() throws {
        let conv = AudioTapPCMConverter()
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000,
                                              channels: 6,
                                              layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6))
        XCTAssertFalse(out.isEmpty)
        XCTAssertGreaterThan(peak(out), 0.05)
    }

    // MARK: - Dialogue channel (#908)

    /// MPEG_5_1_A is FL FR FC LFE BL BR, AudioDecoder's 6-channel order.
    private static let fiveOne: AudioChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A

    func testDialogueTakesTheCentreAloneAndIgnoresTheRestOfTheMix() throws {
        let conv = AudioTapPCMConverter(channels: .dialogue)
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000, channels: 6,
                                              layoutTag: Self.fiveOne,
                                              values: [0.5, 0.5, 0, 0.5, 0.5, 0.5]))
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.channels == .dialogue })
        XCTAssertLessThan(peak(out), 0.001, "score and effects leaked into the dialogue tap")
    }

    func testDialogueCarriesTheCentreAtUnity() throws {
        let conv = AudioTapPCMConverter(channels: .dialogue)
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000, channels: 6,
                                              layoutTag: Self.fiveOne,
                                              values: [0, 0, 0.25, 0, 0, 0]))
        XCTAssertEqual(peak(out), 0.25, accuracy: 0.01)
    }

    func testDownmixInstallStillMixesEveryChannel() throws {
        let conv = AudioTapPCMConverter()
        let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000, channels: 6,
                                              layoutTag: Self.fiveOne,
                                              values: [0.5, 0.5, 0, 0.5, 0.5, 0.5]))
        XCTAssertTrue(out.allSatisfy { $0.channels == .downmix })
        XCTAssertGreaterThan(peak(out), 0.05)
    }

    /// Every multichannel layout AudioDecoder emits that has a centre gets it picked: 4.0 to 7.1.
    func testDialogueFindsTheCentreInEveryDecoderLayoutThatHasOne() throws {
        for channels: UInt32 in 4...8 {
            var values = [Float](repeating: 0, count: Int(channels))
            values[2] = 0.25   // FC is index 2 in every FFmpeg default order from 4.0 up
            let conv = AudioTapPCMConverter(channels: .dialogue)
            let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000,
                                                  channels: channels,
                                                  layoutTag: audioChannelLayoutTag(for: Int32(channels)),
                                                  values: values))
            XCTAssertTrue(out.allSatisfy { $0.channels == .dialogue }, "\(channels)ch")
            XCTAssertEqual(peak(out), 0.25, accuracy: 0.01, "\(channels)ch")
        }
    }

    /// No centre to take: mono, stereo, 2.1 and a discrete layout fall back to the downmix and say
    /// so, with signal. (A description with no layout at all gets AudioDecoder's own order for its
    /// channel count, which from 4 channels up has a centre.)
    func testDialogueFallsBackToTheDownmixWithoutACentre() throws {
        let cases: [(UInt32, AudioChannelLayoutTag?)] = [
            (1, kAudioChannelLayoutTag_Mono), (2, kAudioChannelLayoutTag_Stereo),
            (3, kAudioChannelLayoutTag_WAVE_2_1), (6, kAudioChannelLayoutTag_DiscreteInOrder | 6),
        ]
        for (channels, tag) in cases {
            let conv = AudioTapPCMConverter(channels: .dialogue)
            let out = conv.convert(try makeSample(seconds: 0.5, pts: 4.0, sampleRate: 48_000,
                                                  channels: channels, layoutTag: tag))
            XCTAssertFalse(out.isEmpty, "\(channels)ch \(String(describing: tag))")
            XCTAssertTrue(out.allSatisfy { $0.channels == .downmix }, "\(channels)ch \(String(describing: tag))")
            XCTAssertGreaterThan(peak(out), 0.05, "\(channels)ch \(String(describing: tag))")
        }
    }

    /// The byte copy assumes packed interleaved Float32; anything else is skipped, not misread.
    func testNonFloatInputIsSkipped() throws {
        let conv = AudioTapPCMConverter()
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &fmt)
        let frames = 1024
        let byteCount = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: byteCount, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0,
                                   dataLength: byteCount)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: fmt!, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: 1, preferredTimescale: 90_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        XCTAssertTrue(conv.convert(sample!).isEmpty)
    }

    private func peak(_ buffers: [AudioTapBuffer]) -> Float {
        buffers.reduce(Float(0)) { acc, b in
            guard let ch = b.buffer.floatChannelData?[0] else { return acc }
            return (0..<Int(b.buffer.frameLength)).reduce(acc) { max($0, abs(ch[$1])) }
        }
    }
}
