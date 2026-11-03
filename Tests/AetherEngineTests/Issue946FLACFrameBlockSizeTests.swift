import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#946: AVPlayer times every fixed-blocksize FLAC frame by `STREAMINFO`'s `max_blocksize`. A file whose
/// frames carry another size ran its clock past the end (3:50 of 3:23, 4608 declared over 4096-sample
/// frames) or failed with `-12842`, so the audio-only dispatch reads the first frame's header and sends a
/// stream whose frames are smaller than declared to the FFmpeg host.
@Suite("AE#946: FLAC frame block size against STREAMINFO")
struct Issue946FLACFrameBlockSizeTests {

    private static func withFLAC(min: UInt16, max: UInt16, _ body: (UnsafePointer<AVCodecParameters>) -> Void) {
        guard let codecpar = avcodec_parameters_alloc() else {
            Issue.record("avcodec_parameters_alloc failed")
            return
        }
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        let length = FLACStreamInfo.size
        guard let buf = av_mallocz(length + Int(AV_INPUT_BUFFER_PADDING_SIZE))?
            .assumingMemoryBound(to: UInt8.self) else {
            Issue.record("av_mallocz failed")
            return
        }
        buf[0] = UInt8(min >> 8); buf[1] = UInt8(min & 0xFF)
        buf[2] = UInt8(max >> 8); buf[3] = UInt8(max & 0xFF)
        codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        codecpar.pointee.codec_id = AV_CODEC_ID_FLAC
        codecpar.pointee.extradata = buf
        codecpar.pointee.extradata_size = Int32(length)
        body(UnsafePointer(codecpar))
    }

    @Test("first frame headers as libFLAC and FFmpeg write them", arguments: [
        ([0xFF, 0xF8, 0xCB, 0x88, 0x00, 0xF5] as [UInt8], UInt16(4096)),   // flac --blocksize=4096, 96 kHz
        ([0xFF, 0xF8, 0x5B, 0x88, 0x00, 0x5C] as [UInt8], UInt16(4608)),   // flac --blocksize=4608
        ([0xFF, 0xF8, 0xDB, 0x8C, 0x00, 0x03] as [UInt8], UInt16(8192)),   // ffmpeg at 96 kHz
        ([0xFF, 0xF8, 0x19, 0x08, 0x00, 0x00] as [UInt8], UInt16(192)),
    ])
    func codedBlockSizes(header: [UInt8], expected: UInt16) {
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize(header) == expected)
    }

    @Test("an explicit 8- or 16-bit size follows the UTF-8 frame number, whatever its length")
    func explicitSizes() {
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF8, 0x69, 0x08, 0x00, 0x8F]) == 144)
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF8, 0x79, 0x08, 0x00, 0x11, 0xFF]) == 4608)
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF8, 0x79, 0x08, 0xC2, 0x80, 0x0F, 0xFF]) == 4096)
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize(
            [0xFF, 0xF8, 0x79, 0x08, 0xFC, 0x80, 0x80, 0x80, 0x80, 0x80, 0x0F, 0xFF]) == 4096)
    }

    @Test("anything that is not a whole fixed-blocksize header reads as nil")
    func notAFixedHeader() {
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF9, 0xCB, 0x88, 0x00]) == nil, "variable blocksize")
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF8, 0x09, 0x08, 0x00]) == nil, "reserved code 0")
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0x66, 0x4C, 0x61, 0x43, 0x00]) == nil, "no sync")
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF8, 0xCB]) == nil, "cut short")
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF8, 0x79, 0x08, 0x00, 0x11]) == nil, "16-bit size cut short")
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF8, 0x79, 0x08, 0x80, 0x00, 0x00]) == nil,
                "a continuation byte cannot open the frame number")
        #expect(FLACStreamInfo.fixedStrategyFrameBlockSize([0xFF, 0xF8, 0x79, 0x08, 0x00, 0xFF, 0xFF]) == nil,
                "65536 does not fit a FLAC block")
    }

    @Test("frames under max_blocksize route away from AVPlayer, a match or an oversize frame does not", arguments: [
        (UInt16(4608), UInt16(4608), UInt16(4096), true),    // the reporter's clock overrun
        (UInt16(4096), UInt16(4608), UInt16(4096), true),    // -12842
        (UInt16(4096), UInt16(4096), UInt16(4608), false),   // off spec, libavcodec refuses it as well
        (UInt16(4096), UInt16(4096), UInt16(4096), false),
        (UInt16(8192), UInt16(8192), UInt16(8192), false),
    ])
    func mismatchAgainstMax(min: UInt16, max: UInt16, frame: UInt16, mistimed: Bool) {
        Self.withFLAC(min: min, max: max) { codecpar in
            #expect(FLACStreamInfo.coreMediaMistimesFrames(codecpar, frameBlockSize: frame) == mistimed)
        }
    }

    @Test("a zeroed max gives nothing to compare against and keeps the route")
    func zeroedMaxDecidesNothing() {
        Self.withFLAC(min: 0, max: 0) { codecpar in
            #expect(!FLACStreamInfo.coreMediaMistimesFrames(codecpar, frameBlockSize: 4096))
        }
    }

    @Test("the dispatch sends a mistimed FLAC to the FFmpeg host on .automatic")
    func mistimedRoutesToFFmpeg() {
        #expect(!AetherEngine.audioOnlyUsesAVPlayer(
            codecID: AV_CODEC_ID_FLAC, isCustomSource: false, flacBlocksTooSmall: false,
            flacFramesMistimed: true, flacSeeksMisplaced: false, preferred: .automatic))
    }

    @Test("only the raw FLAC container has its seeks misplaced")
    func rawFLACContainerMisplacesSeeks() {
        #expect(AetherEngine.coreMediaMisplacesSeeks(codecID: AV_CODEC_ID_FLAC, containerFormatName: "flac"))
        #expect(!AetherEngine.coreMediaMisplacesSeeks(codecID: AV_CODEC_ID_FLAC, containerFormatName: "mov,mp4,m4a,3gp,3g2,mj2"))
        #expect(!AetherEngine.coreMediaMisplacesSeeks(codecID: AV_CODEC_ID_FLAC, containerFormatName: "matroska,webm"))
        #expect(!AetherEngine.coreMediaMisplacesSeeks(codecID: AV_CODEC_ID_FLAC, containerFormatName: nil))
        #expect(!AetherEngine.coreMediaMisplacesSeeks(codecID: AV_CODEC_ID_ALAC, containerFormatName: "flac"))
    }

    @Test("the dispatch sends a raw FLAC file to the FFmpeg host on .automatic")
    func rawFLACRoutesToFFmpeg() {
        #expect(!AetherEngine.audioOnlyUsesAVPlayer(
            codecID: AV_CODEC_ID_FLAC, isCustomSource: false, flacBlocksTooSmall: false,
            flacFramesMistimed: false, flacSeeksMisplaced: true, preferred: .automatic))
    }
}
