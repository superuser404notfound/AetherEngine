import Testing
import CoreGraphics
import AetherLibavutil
@testable import AetherEngine

/// AE#1039: what `.lineArt` changes about the upscale route. It takes 1080p and 10-bit SDR, needs no
/// MetalFX, and plans one 2x pass followed by a bilinear resample to the display box.
@Suite("Line-art upscale route")
struct LineArtUpscaleRouteTests {

    private func decide(
        scaler: UpscaleScaler = .lineArt, metalFX: Bool = true,
        source: SourceGeometry = SourceGeometry(width: 1920, height: 1080, sarNum: 1, sarDen: 1),
        sdr: Bool = true, dv: Bool = false, eightBit: Bool = true, tenBit: Bool = false,
        display: CGSize = CGSize(width: 3840, height: 2160)
    ) -> UpscaleRouteDecision {
        UpscaleRouteDecision.decide(
            preference: true, osSupportsStage: true, metalFXSupported: metalFX,
            source: source, isSDR: sdr, isDolbyVision: dv, isEightBit420: eightBit, display: display,
            wirelessAirPlayRoute: false, demuxedAudioLive: false, mlScaleFactors: { _, _ in [1.5, 2] },
            scaler: scaler, isTenBit420: tenBit)
    }

    private func geo(_ w: Int, _ h: Int, _ n: Int = 1, _ d: Int = 1) -> SourceGeometry {
        SourceGeometry(width: w, height: h, sarNum: n, sarDen: d)
    }

    @Test func fullHDOnUHDIsOneLineArtPassStraightToTheTarget() throws {
        let decision = decide()
        let plan = try #require(decision.plan)
        #expect(plan.scaler == .lineArt && plan.mlScale == nil)
        #expect(plan.mlOutputWidth == 3840 && plan.mlOutputHeight == 2160)
        #expect(plan.targetWidth == 3840 && plan.targetHeight == 2160)
        #expect(!plan.needsMetalFX)
        #expect(decision.logLine == "[Upscale] taken: 1920x1080 -> 3840x2160 (line art 2x to 3840x2160)")
    }

    @Test func hd720ResamplesTheRestBilinearly() throws {
        let decision = decide(source: geo(1280, 720))
        let plan = try #require(decision.plan)
        #expect(plan.mlOutputWidth == 2560 && plan.mlOutputHeight == 1440)
        #expect(plan.targetWidth == 3840 && plan.targetHeight == 2160)
        #expect(!plan.needsMetalFX)
        #expect(decision.logLine?.hasSuffix("(line art 2x to 2560x1440, then bilinear)") == true)
    }

    @Test func anamorphicSourceKeepsItsDisplayAspect() throws {
        let plan = try #require(decide(source: geo(1440, 1080, 4, 3)).plan)
        #expect(plan.mlOutputWidth == 2880 && plan.mlOutputHeight == 2160)
        #expect(plan.targetWidth == 3840 && plan.targetHeight == 2160)
    }

    @Test func tenBitIsTakenOnlyByLineArt() {
        #expect(decide(eightBit: false, tenBit: true).plan != nil)
        #expect(decide(scaler: .automatic, source: geo(1280, 720), eightBit: false, tenBit: true)
                == .notTaken(.notEightBit420))
        #expect(decide(eightBit: false, tenBit: false) == .notTaken(.notFourTwoZero))
    }

    @Test func fullHDIsTakenOnlyByLineArt() {
        #expect(decide(scaler: .automatic) == .notTaken(.notBelow1080p))
        #expect(decide(source: geo(2560, 1440)) == .notTaken(.largerThan1080p))
        #expect(decide(source: geo(1920, 1088)) == .notTaken(.largerThan1080p))
    }

    @Test func lineArtNeedsNoMetalFX() {
        #expect(decide(metalFX: false).plan != nil)
        #expect(decide(scaler: .automatic, metalFX: false, source: geo(1280, 720)).plan?.mlScale != nil)
    }

    @Test func hdrAndDolbyVisionKeepTheirRoute() {
        #expect(decide(sdr: false) == .notTaken(.hdrOrDolbyVision))
        #expect(decide(dv: true) == .notTaken(.hdrOrDolbyVision))
    }

    @Test func aDisplayNoLargerThanTheSourceIsNotTaken() {
        #expect(decide(display: CGSize(width: 1920, height: 1080)) == .notTaken(.displayNotLarger))
    }

    /// The failure memory keys on the plan, so a line-art plan that gave up does not block the automatic
    /// route for the same source, and the other way round.
    @Test func plansOfTheTwoScalersAreDistinct() throws {
        let lineArt = try #require(decide(source: geo(1280, 720)).plan)
        let automatic = try #require(decide(scaler: .automatic, source: geo(1280, 720)).plan)
        #expect(lineArt != automatic)
    }

    @Test(arguments: [
        (AV_PIX_FMT_YUV420P10LE, true), (AV_PIX_FMT_P010LE, true), (AV_PIX_FMT_NV12, false),
        (AV_PIX_FMT_YUV422P10LE, false), (AV_PIX_FMT_YUV420P12LE, false),
    ])
    func tenBit420IsRecognised(format: AVPixelFormat, expected: Bool) {
        #expect(UpscaleRouteDecision.isTenBit420(pixelFormat: format.rawValue, bitsPerRawSample: 0) == expected)
    }

    @Test func unknownFormatFallsBackToTheRawDepth() {
        #expect(UpscaleRouteDecision.isTenBit420(pixelFormat: AV_PIX_FMT_NONE.rawValue, bitsPerRawSample: 10))
        #expect(!UpscaleRouteDecision.isTenBit420(pixelFormat: AV_PIX_FMT_NONE.rawValue, bitsPerRawSample: 8))
    }

    /// What line art falls back to: the automatic plan below 1080p when it has an ML pass, else nothing.
    @Test func lineArtFallsBackToTheAutomaticPlanBelow1080p() throws {
        let hd = try #require(decide(source: geo(1280, 720)).plan)
        let fallback = try #require(UpscaleRouteDecision.lineArtFallback(for: hd, mlScaleFactors: { _, _ in [1.5] }))
        #expect(fallback.scaler == .automatic && fallback.mlScale == 1.5)
        #expect(fallback.targetWidth == hd.targetWidth && fallback.targetHeight == hd.targetHeight)
        #expect(UpscaleRouteDecision.lineArtFallback(for: hd, mlScaleFactors: { _, _ in [] }) == nil)

        let fullHD = try #require(decide().plan)
        #expect(UpscaleRouteDecision.lineArtFallback(for: fullHD, mlScaleFactors: { _, _ in [2] }) == nil)

        let dvd = try #require(decide(source: geo(720, 480, 8, 9)).plan)
        let dvdFallback = try #require(UpscaleRouteDecision.lineArtFallback(for: dvd, mlScaleFactors: { _, _ in [2] }))
        #expect(dvdFallback.targetWidth == dvd.targetWidth && dvdFallback.targetHeight == dvd.targetHeight)
    }

    @Test func lineArtOverrunIsRememberedForLargerAndFasterSources() throws {
        LineArtCostMemory.reset()
        defer { LineArtCostMemory.reset() }
        let hd = try #require(decide(source: geo(1280, 720)).plan)
        let fullHD = try #require(decide().plan)
        let sd = try #require(decide(source: geo(720, 480, 8, 9)).plan)
        LineArtCostMemory.record(.init(width: 1280, height: 720, frameInterval: 1.0 / 24, meanMs: 40), rung: .upscale)
        #expect(LineArtCostMemory.overrun(covering: hd, frameInterval: 1.0 / 24, rung: .restore) == nil, "rungs are separate")
        #expect(LineArtCostMemory.overrun(covering: hd, frameInterval: 1001.0 / 24000, rung: .upscale) != nil)
        #expect(LineArtCostMemory.overrun(covering: fullHD, frameInterval: 1.0 / 60, rung: .upscale) != nil)
        #expect(LineArtCostMemory.overrun(covering: sd, frameInterval: 1.0 / 24, rung: .upscale) == nil)
        #expect(LineArtCostMemory.overrun(covering: hd, frameInterval: 1.0 / 12, rung: .upscale) == nil)
        #expect(LineArtCostMemory.overrun(covering: hd, frameInterval: nil, rung: .upscale) != nil)
    }

    /// A custom source's in-place rebuild keeps its plan, so switching the scaler there needs a fresh load.
    @Test func switchingTheScalerOnACustomSourceNeedsAFreshLoad() {
        var on = LoadOptions()
        on.upscalesLowResolutionVideo = true
        var lineArt = on
        lineArt.upscaleScaler = .lineArt
        var off = lineArt
        off.upscalesLowResolutionVideo = false
        #expect(SessionOptionCorrection.upscaleRouteRefusal(isCustomSource: true, current: on, proposed: lineArt)
                == .upscaleRouteNeedsFreshLoad)
        #expect(SessionOptionCorrection.upscaleRouteRefusal(isCustomSource: false, current: on, proposed: lineArt) == nil)
        #expect(SessionOptionCorrection.upscaleRouteRefusal(isCustomSource: true, current: lineArt, proposed: off) == nil)
        #expect(SessionOptionCorrection.upscaleRouteRefusal(isCustomSource: true, current: off, proposed: off) == nil)
    }
}
