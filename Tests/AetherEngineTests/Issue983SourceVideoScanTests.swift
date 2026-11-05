import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#983: a host labels the source progressive or interlaced from the engine's own evidence
/// instead of guessing from the height, and sees whether a deinterlacer runs on the software path.
@Suite("AE#983: source scan and deinterlace report")
struct Issue983SourceVideoScanTests {

    @Test("field orders resolve in display order, and only a clean frame sample overrules them")
    func resolveTable() {
        func scan(_ order: AVFieldOrder, codec: AVCodecID = AV_CODEC_ID_H264,
                  sps: Bool = false, refuted: Bool = false) -> VideoScan {
            VideoScan.resolve(codecID: codec, fieldOrder: order, spsIndicatesInterlaced: sps,
                              frameSampleRefutesInterlace: refuted)
        }
        #expect(scan(AV_FIELD_PROGRESSIVE) == .progressive)
        #expect(scan(AV_FIELD_TT) == .interlaced(.topFieldFirst))
        #expect(scan(AV_FIELD_BT) == .interlaced(.topFieldFirst))
        #expect(scan(AV_FIELD_BB) == .interlaced(.bottomFieldFirst))
        #expect(scan(AV_FIELD_TB) == .interlaced(.bottomFieldFirst))
        #expect(scan(AV_FIELD_UNKNOWN, sps: true) == .interlaced(.unknown))
        #expect(scan(AV_FIELD_UNKNOWN) == .unknown)
        #expect(scan(AV_FIELD_UNKNOWN, codec: AV_CODEC_ID_MPEG2VIDEO) == .unknown)
        #expect(scan(AV_FIELD_UNKNOWN, codec: AV_CODEC_ID_AV1) == .progressive)
        #expect(scan(AV_FIELD_UNKNOWN, codec: AV_CODEC_ID_VP9) == .progressive)
        #expect(scan(AV_FIELD_TT, refuted: true) == .progressive)
        #expect(!VideoScan.unknown.isInterlaced)
        #expect(VideoScan.interlaced(.unknown).isInterlaced)
    }

    @Test("a load publishes the scan from the routing evidence, a reload keeps it, stop clears it",
          .timeLimit(.minutes(2)), arguments: [false, true])
    @MainActor
    func loadPublishesScan(interlaced: Bool) async throws {
        let fixture = interlaced
            ? Issue232InterlaceProbeTests.interlacedBase64
            : Issue232InterlaceProbeTests.declaredTTProgressiveBase64
        let bytes = try #require(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-scan-\(UUID().uuidString).mp4")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.autoplay = false
        options.preferredDecodePath = .software
        _ = try await engine.load(url: file, options: options)
        // The progressive fixture declares TT in its container; the frame sample overrules it.
        let expected: VideoScan = interlaced ? .interlaced(.topFieldFirst) : .progressive
        #expect(engine.sourceVideoScan == expected)
        try await engine.reloadAtCurrentPosition()
        #expect(engine.sourceVideoScan == expected)
        engine.stop()
        #expect(engine.sourceVideoScan == .unknown)
    }

    @Test("decodedVideoFormat names the deinterlacer only when frames pass through one",
          .timeLimit(.minutes(2)), arguments: [false, true])
    @MainActor
    func decodedFormatCarriesDeinterlace(interlaced: Bool) async throws {
        let fixture = interlaced
            ? Issue232InterlaceProbeTests.interlacedBase64
            : Issue232InterlaceProbeTests.declaredTTProgressiveBase64
        let bytes = try #require(Data(base64Encoded: fixture, options: .ignoreUnknownCharacters))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-scan-\(UUID().uuidString).mp4")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.preferredDecodePath = .software
        _ = try await engine.load(url: file, options: options)
        for _ in 0..<100 where engine.decodedVideoFormat == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let format = try #require(engine.decodedVideoFormat)
        #expect((format.deinterlace != nil) == interlaced)
    }

    private static func interlacedFrame() -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = 64
        f.pointee.height = 64
        f.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        f.pointee.pts = 0
        f.pointee.flags |= (1 << 3)  // AV_FRAME_FLAG_INTERLACED
        _ = av_frame_get_buffer(f, 0)
        return f
    }

    @Test("the software graph reports frame rate whatever the field-rate option, and teardown clears it")
    func softwareGraphReport() throws {
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .software, fieldRate: .field)
        var frame: UnsafeMutablePointer<AVFrame>? = Self.interlacedFrame()
        defer { av_frame_free(&frame) }
        #expect(filter.activeDeinterlace == nil)
        try #require(filter.ensureGraph(frame: frame!, timeBase: AVRational(num: 1, den: 25)))
        let report = try #require(filter.activeDeinterlace)
        #expect(["bwdif", "yadif"].contains(report.filter))
        #expect(!report.isHardware)
        #expect(report.fieldRate == .frame)
        #expect(report.outputFramesPerSourceFrame == 1)
        filter.teardown()
        #expect(filter.activeDeinterlace == nil)
    }

    @Test("the hardware graph reports the field rate it was configured with",
          .enabled(if: DeinterlaceFilter.prewarmHardwarePipeline(), "needs yadif_videotoolbox and a Metal device"))
    func hardwareGraphReport() throws {
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .auto, fieldRate: .field)
        defer { filter.teardown() }
        var frame: UnsafeMutablePointer<AVFrame>? = Self.interlacedFrame()
        defer { av_frame_free(&frame) }
        try #require(filter.ensureGraph(frame: frame!, timeBase: AVRational(num: 1, den: 25)))
        #expect(filter.activeDeinterlace == VideoDeinterlace(
            filter: "yadif_videotoolbox", isHardware: true, fieldRate: .field))
        #expect(filter.activeDeinterlace?.outputFramesPerSourceFrame == 2)
    }
}
