import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#1047: an AAC `AudioSpecificConfig` with `channelConfiguration` 0 keeps its layout in a Program
/// Config Element, and CoreMedia refuses it on both routes (loopback `-11829` / `-12848`, an `.m4a` on
/// AVPlayer ends at 0 s). Such a track is decoded by libavcodec instead.
@Suite("AE#1047: AAC with its layout in a PCE")
struct Issue1047AACProgramConfigTests {

    /// The reporter's 26-byte CodecPrivate: AAC-LC, 48 kHz, channelConfiguration 0, a PCE for
    /// CPE, SCE, SCE, CPE, comment `Lavc62.11.100`.
    static let reporterRecord: [UInt8] = [
        0x11, 0x80, 0x04, 0xC8, 0x44, 0x00, 0x20, 0x00, 0xC4, 0x0D, 0x4C, 0x61, 0x76,
        0x63, 0x36, 0x32, 0x2E, 0x31, 0x31, 0x2E, 0x31, 0x30, 0x30, 0x56, 0xE5, 0x00,
    ]

    private static func withCodecpar(
        _ bytes: [UInt8], codec: AVCodecID = AV_CODEC_ID_AAC,
        _ body: (UnsafePointer<AVCodecParameters>) -> Void
    ) {
        guard let codecpar = avcodec_parameters_alloc() else {
            Issue.record("avcodec_parameters_alloc failed")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        codecpar.pointee.codec_id = codec
        if !bytes.isEmpty {
            guard let buf = av_mallocz(bytes.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))?
                .assumingMemoryBound(to: UInt8.self) else {
                Issue.record("av_mallocz failed")
                return
            }
            bytes.withUnsafeBufferPointer { if let base = $0.baseAddress { memcpy(buf, base, bytes.count) } }
            codecpar.pointee.extradata = buf
            codecpar.pointee.extradata_size = Int32(bytes.count)
        }
        body(UnsafePointer(codecpar))
    }

    @Test("the reporter's record is refused")
    func reporterRecordRejected() {
        #expect(AACAudioSpecificConfig.channelConfiguration(Self.reporterRecord) == 0)
        Self.withCodecpar(Self.reporterRecord) { #expect(AACAudioSpecificConfig.coreMediaRejects($0)) }
    }

    @Test("standard records keep stream-copy", arguments: [
        ([UInt8(0x11), 0x90], 2),   // LC 48 kHz stereo
        ([UInt8(0x11), 0xB0], 6),   // LC 48 kHz 5.1
        ([UInt8(0x12), 0x10], 2),   // LC 44.1 kHz stereo
        ([UInt8(0x11), 0xB8], 7),   // LC 48 kHz 7.1
    ])
    func standardRecords(bytes: [UInt8], channels: Int) {
        #expect(AACAudioSpecificConfig.channelConfiguration(bytes) == channels)
        Self.withCodecpar(bytes) { #expect(!AACAudioSpecificConfig.coreMediaRejects($0)) }
    }

    @Test("an explicit sampling rate shifts the field by 24 bits")
    func explicitSamplingRate() {
        // samplingFrequencyIndex 15 + 48000: a fixed-offset read lands on rate bits and reads 0.
        #expect(AACAudioSpecificConfig.channelConfiguration([0x17, 0x80, 0x5D, 0xC0, 0x10]) == 2)
        #expect(AACAudioSpecificConfig.channelConfiguration([0x17, 0x80, 0x5D, 0xC0, 0x00]) == 0)
    }

    @Test("an escaped object type shifts the field by 6 bits")
    func escapedObjectType() {
        #expect(AACAudioSpecificConfig.channelConfiguration([0xF8, 0x06, 0xC0]) == 6)
        #expect(AACAudioSpecificConfig.channelConfiguration([0xF8, 0x06, 0x00]) == 0)
    }

    @Test("no record, a short record or another codec is left alone")
    func nothingToRead() {
        #expect(AACAudioSpecificConfig.channelConfiguration([0x11]) == nil)
        #expect(AACAudioSpecificConfig.channelConfiguration([UInt8]()) == nil)
        Self.withCodecpar([]) { #expect(!AACAudioSpecificConfig.coreMediaRejects($0)) }
        Self.withCodecpar(Self.reporterRecord, codec: AV_CODEC_ID_AC3) {
            #expect(AACAudioSpecificConfig.channelConfiguration($0) == nil)
            #expect(!AACAudioSpecificConfig.coreMediaRejects($0))
        }
    }

    @Test("an audio-only PCE track goes to libavcodec")
    func audioOnlyRoute() {
        #expect(!AetherEngine.audioOnlyUsesAVPlayer(
            codecID: AV_CODEC_ID_AAC, isCustomSource: false,
            flacBlocksTooSmall: false, flacFramesMistimed: false, flacSeeksMisplaced: false,
            aacLayoutInPCE: true, preferred: .automatic))
        #expect(AetherEngine.audioOnlyUsesAVPlayer(
            codecID: AV_CODEC_ID_AAC, isCustomSource: false,
            flacBlocksTooSmall: false, flacFramesMistimed: false, flacSeeksMisplaced: false,
            aacLayoutInPCE: false, preferred: .automatic))
    }
}
