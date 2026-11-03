import XCTest
import Testing
import AetherLibavformat
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

final class SecondarySubtitleChannelTests: XCTestCase {

    // Bitmap classification is shared by both channels. Decoder availability still depends
    // on the shipped FFmpeg build (in particular, XSUB is not built).
    func testBitmapCodecClassification() {
        XCTAssertTrue(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_HDMV_PGS_SUBTITLE))
        XCTAssertTrue(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_DVB_SUBTITLE))
        XCTAssertTrue(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_DVD_SUBTITLE))
        XCTAssertTrue(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_XSUB))
        XCTAssertFalse(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_SUBRIP))
        XCTAssertFalse(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_ASS))
    }

    @MainActor
    func testSecondaryChannelDefaultsAndIndependentClear() throws {
        let engine = try AetherEngine()
        XCTAssertEqual(engine.secondarySubtitleCues.count, 0)
        XCTAssertFalse(engine.isSecondarySubtitleActive)
        XCTAssertFalse(engine.isLoadingSecondarySubtitles)
        // Clearing one channel must not flip the other's flags.
        engine.clearSecondarySubtitle()
        XCTAssertFalse(engine.isSecondarySubtitleActive)
        engine.clearSubtitle()
        XCTAssertFalse(engine.isSubtitleActive)
        XCTAssertFalse(engine.isSecondarySubtitleActive)
    }
}

/// Generated PGS packets deliberately reuse palette/object id zero on two streams.
/// Drive the engine's actual packet-store drain with real shipped FFmpeg decoders.
@MainActor
struct SecondaryBitmapSubtitleTests {
    static func segment(_ type: UInt8, _ body: [UInt8]) -> Data {
        Data([type, UInt8(body.count >> 8), UInt8(body.count & 255)] + body)
    }
    static func pcs(x: Int, state: UInt8, clear: Bool = false) -> Data {
        var body: [UInt8] = [7, 128, 4, 56, 16, 0, 1, state, 0, 0, clear ? 0 : 1]
        if !clear { body += [0, 0, 0, 0, UInt8(x >> 8), UInt8(x & 255), 3, 132] }
        return segment(0x16, body)
    }
    static func displaySet(x: Int, luminance: UInt8) -> Data {
        let palette = segment(0x14, [0, 0, 0, 16, 128, 128, 0, 1, luminance, 128, 128, 255])
        let rle = Array(repeating: [0, 0x88, 1, 0, 0] as [UInt8], count: 8).flatMap { $0 }
        let object = segment(0x15, [0, 0, 0, 0xc0, 0, 0, 44, 0, 8, 0, 8] + rle)
        return pcs(x: x, state: 0x80) + palette + object + segment(0x80, [])
    }

    @Test("PGS channels isolate palettes, clear, off and cached reconstruction", .timeLimit(.minutes(3)))
    func independentChannels() async throws {
        let format = try #require(avformat_alloc_context())
        defer { avformat_free_context(format) }
        for _ in 0..<2 {
            let stream = try #require(avformat_new_stream(format, nil))
            stream.pointee.time_base = AVRational(num: 1, den: 90_000)
            stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
        }
        let engine = try AetherEngine()
        defer { engine.clearSubtitle(); engine.clearSecondarySubtitle() }
        engine.loadedURL = URL(string: "https://example.invalid/movie.mkv")!
        func drain() async {
            engine.requestSubtitleDrainTick()
            while let pending = engine.subtitleDrainTickInFlight { await pending.value }
        }
        let store = SubtitlePacketStore()
        engine.softwareSubtitlePacketStore = store
        engine.subtitleDrainDecoderFactoryForTesting = { index in
            guard (0..<2).contains(index), let stream = format.pointee.streams[Int(index)] else { return nil }
            return EmbeddedSubtitleDecoder(stream: stream, sourceVideoWidth: 1920, sourceVideoHeight: 1080)
        }
        func harvest(_ stream: Int32, _ time: Double, _ data: Data) {
            store.harvestChunk(streamIndex: stream, ptsSeconds: time, durationSeconds: 0,
                               flags: 0, payload: data, assembleSplitDisplaySets: true)
        }
        func image(_ cues: [SubtitleCue], at time: Double) throws -> SubtitleImage {
            let cue = try #require(cues.first { $0.startTime <= time && $0.endTime > time }, "no bitmap at \(time); intervals \(cues.map { [$0.startTime, $0.endTime] })")
            guard case .image(let image) = cue.body else {
                Issue.record("expected a decoded bitmap"); throw NSError(domain: "fixture", code: 1)
            }
            return image
        }
        func pixels(_ image: SubtitleImage) -> Data { image.cgImage.dataProvider!.data! as Data }
        harvest(0, 10, Self.displaySet(x: 100, luminance: 235))
        harvest(1, 10, Self.displaySet(x: 300, luminance: 100))
        // Composition-only packets require the decoder's previously cached palette/object.
        harvest(0, 12, Self.pcs(x: 100, state: 0) + Self.segment(0x80, []))
        harvest(1, 11, Self.pcs(x: 300, state: 0, clear: true) + Self.segment(0x80, []))
        engine.clock.sourceTime = 10
        engine.selectSubtitleTrack(index: 0)
        engine.selectSecondarySubtitleTrack(index: 1)
        await drain()
        let primary = try image(engine.subtitleCues, at: 10)
        let secondary = try image(engine.secondarySubtitleCues, at: 10)
        #expect(abs(primary.position.origin.x * 1920 - 100) < 0.01)
        #expect(abs(secondary.position.origin.x * 1920 - 300) < 0.01)
        #expect(pixels(primary) != pixels(secondary))
        #expect(!engine.secondarySubtitleCues.contains { $0.startTime <= 11.5 && $0.endTime > 11.5 })
        #expect(pixels(try image(engine.subtitleCues, at: 12)) == pixels(primary))
        let primaryDecoder = try #require(engine.subtitleDrainDecoders[.primary])
        let secondaryDecoder = try #require(engine.subtitleDrainDecoders[.secondary])
        #expect(primaryDecoder !== secondaryDecoder)
        engine.clearSecondarySubtitle()
        #expect(engine.subtitleDrainDecoders[.primary] === primaryDecoder)
        #expect(engine.subtitleDrainDecoders[.secondary] == nil)
        #expect(engine.secondarySubtitleCues.isEmpty)
        #expect(pixels(try image(engine.subtitleCues, at: 12)) == pixels(primary))
        engine.selectSecondarySubtitleTrack(index: 1)
        await drain()
        #expect(pixels(try image(engine.secondarySubtitleCues, at: 10)) == pixels(secondary))
        // A seek resets both channel cursors and reconstructs from retained packets.
        engine.clock.sourceTime = 200
        await drain()
        engine.clock.sourceTime = 10
        await drain()
        #expect(pixels(try image(engine.subtitleCues, at: 10)) == pixels(primary))
        #expect(pixels(try image(engine.secondarySubtitleCues, at: 10)) == pixels(secondary))
    }
}
