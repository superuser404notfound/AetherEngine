import Testing
import CoreGraphics
import AetherLibavutil
@testable import AetherEngine

@Suite("Upscale route decision")
struct UpscaleRouteDecisionTests {

    private static func defaultFactors(_ w: Int, _ h: Int) -> [Float] { w <= 960 ? [1.5, 2] : (w <= 1280 ? [1.5] : []) }

    private func decide(
        preference: Bool = true, os: Bool = true, metalFX: Bool = true,
        source: SourceGeometry = SourceGeometry(width: 1280, height: 720, sarNum: 1, sarDen: 1),
        sdr: Bool = true, dv: Bool = false, eightBit: Bool = true,
        display: CGSize = CGSize(width: 3840, height: 2160),
        airPlay: Bool = false, demuxedLive: Bool = false,
        factors: (Int, Int) -> [Float] = UpscaleRouteDecisionTests.defaultFactors,
        failedEarlier: (UpscalePlan) -> Bool = { _ in false }
    ) -> UpscaleRouteDecision {
        UpscaleRouteDecision.decide(
            preference: preference, osSupportsStage: os, metalFXSupported: metalFX,
            source: source, isSDR: sdr, isDolbyVision: dv, isEightBit420: eightBit, display: display,
            wirelessAirPlayRoute: airPlay, demuxedAudioLive: demuxedLive, mlScaleFactors: factors,
            stageFailedEarlier: failedEarlier)
    }

    private func geo(_ w: Int, _ h: Int, _ n: Int = 1, _ d: Int = 1) -> SourceGeometry {
        SourceGeometry(width: w, height: h, sarNum: n, sarDen: d)
    }

    @Test func offByDefaultLogsNothing() {
        let d = decide(preference: false)
        #expect(d == .notTaken(.preferenceOff))
        #expect(d.logLine == nil)
    }

    @Test func ntscDVDGets2xThenMetalFX() throws {
        let plan = try #require(decide(source: geo(720, 480, 8, 9)).plan)
        #expect(plan.mlScale == 2)
        #expect(plan.mlOutputWidth == 1440 && plan.mlOutputHeight == 960)
        #expect(plan.targetWidth == 2880 && plan.targetHeight == 2160)
        #expect(plan.needsMetalFX)
    }

    @Test func palDVDWideKeepsDisplayAspect() throws {
        let plan = try #require(decide(source: geo(720, 576, 64, 45)).plan)
        #expect(plan.targetWidth == 3840 && plan.targetHeight == 2160)
    }

    @Test func hd720Gets1_5xThenMetalFX() throws {
        let plan = try #require(decide().plan)
        #expect(plan.mlScale == 1.5)
        #expect(plan.mlOutputWidth == 1920 && plan.mlOutputHeight == 1080)
        #expect(plan.targetWidth == 3840 && plan.targetHeight == 2160)
        #expect(plan.displayWidth == 3840 && plan.displayHeight == 2160)
    }

    @Test func hd720OnA1080pDisplayIsMLOnly() throws {
        let plan = try #require(decide(display: CGSize(width: 1920, height: 1080)).plan)
        #expect(plan.mlOutputWidth == 1920 && plan.mlOutputHeight == 1080)
        #expect(plan.targetWidth == 1920 && plan.targetHeight == 1080)
        #expect(!plan.needsMetalFX)
    }

    @Test func noMLFactorFallsBackToMetalFXOnly() throws {
        let plan = try #require(decide(factors: { _, _ in [] }).plan)
        #expect(plan.mlScale == nil)
        #expect(plan.mlOutputWidth == 1280 && plan.mlOutputHeight == 720)
        #expect(plan.needsMetalFX)
    }

    @Test func mlNeverOvershootsTarget() throws {
        let plan = try #require(decide(source: geo(960, 540), display: CGSize(width: 1280, height: 720)).plan)
        #expect(plan.mlScale == nil)
        #expect(plan.mlOutputWidth == 960 && plan.mlOutputHeight == 540)
        #expect(plan.needsMetalFX)
    }

    @Test func fullHDIsNeverTouched() {
        for s in [geo(1920, 1080), geo(1920, 800), geo(1440, 1080)] {
            #expect(decide(source: s) == .notTaken(.notBelow1080p))
        }
    }

    @Test func hdrAndDolbyVisionAreRefused() {
        #expect(decide(sdr: false) == .notTaken(.hdrOrDolbyVision))
        #expect(decide(dv: true) == .notTaken(.hdrOrDolbyVision))
    }

    @Test func tenBitSDRIsRefusedAndEightBitTaken() {
        #expect(decide(eightBit: false) == .notTaken(.notEightBit420))
        #expect(decide(eightBit: true).plan != nil)
        #expect(decide(eightBit: false).logLine?.contains("8-bit 4:2:0") == true)
    }

    @Test func bitDepthIsCheckedAfterHDRAndBeforeGeometry() {
        #expect(decide(sdr: false, eightBit: false) == .notTaken(.hdrOrDolbyVision))
        #expect(decide(source: geo(0, 0), eightBit: false) == .notTaken(.notEightBit420))
    }

    @Test func eightBit420FromCodecParameters() {
        func check(_ f: AVPixelFormat, _ bits: Int32 = 0) -> Bool {
            UpscaleRouteDecision.isEightBit420(pixelFormat: f.rawValue, bitsPerRawSample: bits)
        }
        #expect(check(AV_PIX_FMT_YUV420P))
        #expect(check(AV_PIX_FMT_YUVJ420P))
        #expect(check(AV_PIX_FMT_NV12))
        #expect(!check(AV_PIX_FMT_YUV420P10LE))
        #expect(!check(AV_PIX_FMT_P010LE))
        #expect(!check(AV_PIX_FMT_YUV422P))
        #expect(!check(AV_PIX_FMT_YUV444P))
        #expect(!check(AV_PIX_FMT_RGB24))
        // A known format wins over a contradicting raw sample count.
        #expect(check(AV_PIX_FMT_YUV420P, 10))
        #expect(check(AV_PIX_FMT_NONE, 8))
        #expect(check(AV_PIX_FMT_NONE, 1))
        #expect(!check(AV_PIX_FMT_NONE, 10))
        #expect(!check(AV_PIX_FMT_NONE, 0))
    }

    @Test func displayNotLargerIsRefused() {
        #expect(decide(display: CGSize(width: 1280, height: 720)) == .notTaken(.displayNotLarger))
    }

    @Test func exitsInOrder() {
        #expect(decide(os: false, sdr: false) == .notTaken(.unsupportedOS))
        #expect(decide(metalFX: false, sdr: false) == .notTaken(.metalFXUnsupported))
        #expect(decide(source: geo(0, 0), sdr: false) == .notTaken(.hdrOrDolbyVision))
        #expect(decide(source: geo(0, 0), airPlay: true) == .notTaken(.geometryUnknown))
        #expect(decide(source: geo(1920, 1080), display: CGSize(width: 100, height: 100)) == .notTaken(.notBelow1080p))
    }

    @Test func zeroGeometryIsUnknown() {
        #expect(decide(source: geo(0, 0)) == .notTaken(.geometryUnknown))
    }

    @Test func zeroSARCountsAsSquare() throws {
        let a = try #require(decide(source: geo(1280, 720, 0, 0)).plan)
        let b = try #require(decide().plan)
        #expect(a == b)
    }

    @Test func airPlayAndDemuxedLiveRefuse() {
        #expect(decide(airPlay: true) == .notTaken(.wirelessAirPlayRoute))
        #expect(decide(demuxedLive: true) == .notTaken(.demuxedAudioLive))
    }

    /// AirPlay speakers with the picture on HDMI: the route would move a natively playable SD episode onto
    /// the software path, whose seek lost the sound on the speakers (7.53.1, tvOS 27.2).
    @Test func audioOnlyAirPlayRefusesLikeAVideoReceiver() {
        let sd = geo(720, 556)
        #expect(decide(source: sd).plan != nil)
        #expect(decide(source: sd, airPlay: true) == .notTaken(.wirelessAirPlayRoute))
    }

    @Test func aPlanWhoseStageFailedIsNotTakenAgain() throws {
        let plan = try #require(decide().plan)
        #expect(decide(failedEarlier: { $0 == plan }) == .notTaken(.stageFailedEarlier))
        #expect(decide(source: geo(720, 480), failedEarlier: { $0 == plan }).plan != nil)
    }

    @Test func failureMemoryRemembersPlansAtTheirRate() throws {
        UpscaleFailureMemory.reset()
        defer { UpscaleFailureMemory.reset() }
        let plan = try #require(decide().plan)
        let other = try #require(decide(source: geo(720, 480)).plan)
        #expect(!UpscaleFailureMemory.contains(plan, frameRate: 50))
        UpscaleFailureMemory.record(plan, frameRate: 50)
        #expect(UpscaleFailureMemory.contains(plan, frameRate: 50))
        #expect(UpscaleFailureMemory.contains(plan, frameRate: 59.94))
        #expect(UpscaleFailureMemory.contains(plan, frameRate: nil))
        #expect(!UpscaleFailureMemory.contains(plan, frameRate: 25))
        #expect(!UpscaleFailureMemory.contains(other, frameRate: 50))
        UpscaleFailureMemory.record(plan, frameRate: 24)
        #expect(UpscaleFailureMemory.contains(plan, frameRate: 23.976))
        #expect(decide(failedEarlier: { UpscaleFailureMemory.contains($0, frameRate: 25) })
                == .notTaken(.stageFailedEarlier))
    }

    /// The owed return is dropped once the session moved on, and waits while nothing plays.
    @Test @MainActor func owedNativeReturnClearsOnANewGenerationAndWaitsOtherwise() throws {
        let engine = try AetherEngine()
        engine.upscaleNativeReturnOwed = engine.loadGeneration &+ 1
        engine.settleOwedUpscaleNativeReturn()
        #expect(engine.upscaleNativeReturnOwed == nil)
        engine.upscaleNativeReturnOwed = engine.loadGeneration
        engine.settleOwedUpscaleNativeReturn()
        #expect(engine.state == .idle)
        #expect(engine.upscaleNativeReturnOwed == engine.loadGeneration)
    }

    @Test func disabledStageReturnsOnlyAURLVODSessionItAloneMovedToNative() {
        #expect(AetherEngine.upscaleDisableReturnsToNative(softwareOnlyForUpscale: true, isCustomSource: false, isLive: false))
        #expect(!AetherEngine.upscaleDisableReturnsToNative(softwareOnlyForUpscale: false, isCustomSource: false, isLive: false))
        #expect(!AetherEngine.upscaleDisableReturnsToNative(softwareOnlyForUpscale: true, isCustomSource: true, isLive: false))
        #expect(!AetherEngine.upscaleDisableReturnsToNative(softwareOnlyForUpscale: true, isCustomSource: false, isLive: true))
    }

    @Test func makePlanIsExposed() throws {
        let plan = try #require(UpscaleRouteDecision.makePlan(
            source: geo(1280, 720), display: CGSize(width: 3840, height: 2160),
            mlScaleFactors: Self.defaultFactors))
        #expect(plan.targetWidth == 3840)
        #expect(UpscaleRouteDecision.makePlan(source: geo(0, 0), display: CGSize(width: 3840, height: 2160),
                                              mlScaleFactors: Self.defaultFactors) == nil)
    }

    @Test func logLineNamesThePlan() {
        let line = decide().logLine
        #expect(line?.contains("1280x720") == true)
        #expect(line?.contains("ML 1.5x") == true)
        #expect(line?.contains("MetalFX") == true)
        #expect(line?.contains("3840x2160") == true)
        #expect(line?.hasPrefix("[Upscale]") == true)
    }
}
