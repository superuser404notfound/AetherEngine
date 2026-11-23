import Testing
import CoreGraphics
import Foundation
@testable import AetherEngine

/// `LoadOptions.upscalesFullHDVideo` and `UpscaleScaler.lanczos`: which sources the 1080p option takes,
/// how it sits beside `upscalesLowResolutionVideo`, and the Lanczos-3 taps the Metal stage uploads.
@Suite("Lanczos upscale route", .timeLimit(.minutes(3)))
struct LanczosUpscaleRouteTests {

    private func decide(
        lowRes: Bool = false, fullHD: Bool = true, scaler: UpscaleScaler = .automatic,
        source: SourceGeometry = SourceGeometry(width: 1920, height: 1080, sarNum: 1, sarDen: 1),
        sdr: Bool = true, dv: Bool = false, eightBit: Bool = true, tenBit: Bool = false, metalFX: Bool = true,
        display: CGSize = CGSize(width: 3840, height: 2160), airPlay: Bool = false
    ) -> UpscaleRouteDecision {
        UpscaleRouteDecision.decide(
            preference: lowRes, osSupportsStage: true, metalFXSupported: metalFX,
            source: source, isSDR: sdr, isDolbyVision: dv, isEightBit420: eightBit, display: display,
            wirelessAirPlayRoute: airPlay, demuxedAudioLive: false, mlScaleFactors: { _, _ in [1.5, 2] },
            scaler: scaler, isTenBit420: tenBit, fullHD: fullHD)
    }

    private func geo(_ w: Int, _ h: Int, _ n: Int = 1, _ d: Int = 1) -> SourceGeometry {
        SourceGeometry(width: w, height: h, sarNum: n, sarDen: d)
    }

    @Test func fullHDOnUHDIsOneLanczosPassToTheTarget() throws {
        let decision = decide()
        let plan = try #require(decision.plan)
        #expect(plan.scaler == .lanczos && plan.mlScale == nil && !plan.needsMetalFX)
        #expect(plan.mlOutputWidth == 3840 && plan.mlOutputHeight == 2160)
        #expect(plan.targetWidth == 3840 && plan.targetHeight == 2160)
        #expect(decision.logLine == "[Upscale] taken: 1920x1080 -> 3840x2160 (Lanczos)")
    }

    @Test func scopeAndAnamorphicSourcesKeepTheirAspect() throws {
        let scope = try #require(decide(source: geo(1920, 800)).plan)
        #expect(scope.targetWidth == 3840 && scope.targetHeight == 1600)
        let anamorphic = try #require(decide(source: geo(1440, 1080, 4, 3)).plan)
        #expect(anamorphic.targetWidth == 3840 && anamorphic.targetHeight == 2160)
    }

    @Test func theFullHDOptionTakesOnly1080p() {
        #expect(decide(source: geo(1280, 720)) == .notTaken(.belowFullHD))
        #expect(decide(source: geo(3840, 2160)) == .notTaken(.largerThan1080p))
        #expect(decide(source: geo(1920, 1088)) == .notTaken(.largerThan1080p))
        #expect(decide(fullHD: false) == .notTaken(.preferenceOff))
        #expect(decide(fullHD: false).logLine == nil)
    }

    @Test func bothOptionsSplitTheSourcesBySize() throws {
        let hd = try #require(decide(lowRes: true, source: geo(1280, 720)).plan)
        #expect(hd.scaler == .automatic && hd.mlScale != nil)
        #expect(try #require(decide(lowRes: true).plan).scaler == .lanczos)
        #expect(decide(lowRes: true, source: geo(3840, 2160)) == .notTaken(.largerThan1080p))
    }

    /// Without the 1080p option the low-resolution one refuses 1080p as before.
    @Test func lowResolutionAloneStillRefuses1080p() {
        #expect(decide(lowRes: true, fullHD: false) == .notTaken(.notBelow1080p))
        #expect(decide(lowRes: true, fullHD: false, source: geo(3840, 2160)) == .notTaken(.notBelow1080p))
    }

    @Test func aLineArtTitleKeepsLineArtAt1080p() throws {
        #expect(try #require(decide(lowRes: true, scaler: .lineArt).plan).scaler == .lineArt)
    }

    @Test func tenBitIsTakenAndHDRIsNot() {
        #expect(decide(eightBit: false, tenBit: true).plan?.scaler == .lanczos)
        #expect(decide(lowRes: true, eightBit: false, tenBit: true).plan?.scaler == .lanczos,
                "the automatic scaler's 8-bit rule does not apply to a 1080p source it does not take")
        #expect(decide(eightBit: false, tenBit: false) == .notTaken(.notFourTwoZero))
        #expect(decide(sdr: false) == .notTaken(.hdrOrDolbyVision))
        #expect(decide(dv: true) == .notTaken(.hdrOrDolbyVision))
    }

    @Test func noMetalFXNeededAndAirPlayKeepsItsRoute() {
        #expect(decide(metalFX: false).plan != nil)
        #expect(decide(airPlay: true) == .notTaken(.wirelessAirPlayRoute))
        #expect(decide(display: CGSize(width: 1920, height: 1080)) == .notTaken(.displayNotLarger))
    }

    private func policy(low: Bool = false, _ requested: UpscaleScaler = .automatic, fullHD: Bool = false) -> UpscaleSizePolicy {
        UpscaleSizePolicy(lowResolution: low, requested: requested, fullHD: fullHD)
    }

    @Test func aRebuildKeepsThePlanOnlyWhileItsScalerIsStillAskedFor() throws {
        let fullHDPlan = try #require(decide().plan)
        #expect(policy(fullHD: true).covers(fullHDPlan))
        #expect(!policy(low: true).covers(fullHDPlan))
        #expect(policy(low: true, .lineArt).covers(fullHDPlan), "a Lanczos plan line art fell back to belongs to line art")
        let hd = try #require(decide(lowRes: true, source: geo(1280, 720)).plan)
        #expect(!policy(fullHD: true).covers(hd))
        #expect(policy(low: true).covers(hd))
        // Both on, a line-art 1080p session: turning the low-resolution option off drops the line-art plan.
        let lineArt = try #require(decide(lowRes: true, scaler: .lineArt).plan)
        #expect(policy(low: true, .lineArt, fullHD: true).covers(lineArt))
        #expect(!policy(fullHD: true).covers(lineArt))
    }

    /// Most 1080p rips are cropped on both axes; they are 1080p all the same.
    @Test func croppedFullHDCountsAs1080p() throws {
        for (w, h) in [(1916, 1036), (1904, 800), (1440, 1080), (1280, 1072)] {
            #expect(decide(source: geo(w, h)).plan?.scaler == .lanczos, "\(w)x\(h)")
        }
        #expect(decide(source: geo(1280, 720)) == .notTaken(.belowFullHD))
        // With both on, Lanczos takes them from the automatic scaler (which would run MetalFX there).
        #expect(decide(lowRes: true, source: geo(1916, 1036)).plan?.scaler == .lanczos)
        #expect(decide(lowRes: true, fullHD: false, source: geo(1916, 1036)).plan?.scaler == .automatic)
    }

    @Test func theSizePolicyPicksPerSize() {
        let both = policy(low: true, fullHD: true)
        #expect(both.scaler(width: 1280, height: 720) == .automatic)
        #expect(both.scaler(width: 1920, height: 1080) == .lanczos)
        #expect(both.scaler(width: 3840, height: 2160) == nil)
        #expect(policy(low: true, .lineArt, fullHD: true).scaler(width: 1920, height: 1080) == .lineArt)
        #expect(policy(fullHD: true).scaler(width: 1280, height: 720) == nil)
    }

    /// A plan whose one axis would shrink is not taken: the Lanczos stage only scales up.
    @Test func aPlanThatShrinksAnAxisIsNotTaken() {
        #expect(decide(source: geo(1920, 1080, 2, 3), display: CGSize(width: 2560, height: 1440))
                == .notTaken(.displayNotLarger))
    }

    @Test func turningTheFullHDOptionOnForACustomSourceNeedsAFreshLoad() {
        let off = LoadOptions()
        var on = off
        on.upscalesFullHDVideo = true
        #expect(SessionOptionCorrection.upscaleRouteRefusal(isCustomSource: true, current: off, proposed: on)
                == .upscaleRouteNeedsFreshLoad)
        #expect(SessionOptionCorrection.upscaleRouteRefusal(isCustomSource: true, current: on, proposed: off) == nil)
        #expect(SessionOptionCorrection.upscaleRouteRefusal(isCustomSource: false, current: off, proposed: on) == nil)
    }

    /// Line art falls back to Lanczos where the automatic route has nothing: at 1080p, for 10-bit, and
    /// below 1080p without a VT super-resolution pass.
    @Test func lineArtFallsBackToLanczosWhereAutomaticCannotTakeIt() throws {
        func lineArtPlan(_ w: Int, _ h: Int) throws -> UpscalePlan {
            try #require(decide(lowRes: true, fullHD: false, scaler: .lineArt, source: geo(w, h)).plan)
        }
        let fullHD = try #require(UpscaleRouteDecision.lineArtFallback(for: try lineArtPlan(1920, 1080),
                                                                      mlScaleFactors: { _, _ in [2] }))
        #expect(fullHD.scaler == .lanczos && fullHD.targetWidth == 3840 && fullHD.targetHeight == 2160)
        let tenBit = try #require(UpscaleRouteDecision.lineArtFallback(for: try lineArtPlan(1280, 720), eightBit: false,
                                                                      mlScaleFactors: { _, _ in [2] }))
        #expect(tenBit.scaler == .lanczos)
        let noML = try #require(UpscaleRouteDecision.lineArtFallback(for: try lineArtPlan(1280, 720),
                                                                    mlScaleFactors: { _, _ in [] }))
        #expect(noML.scaler == .lanczos && noML.targetWidth == 3840)
    }

    // MARK: - Taps

    @Test(arguments: [(1920, 3840), (1080, 2160), (960, 1920), (1440, 3840), (800, 1600), (7, 13)])
    func tapsSumToOneAndReachTheKernelsSupport(input: Int, output: Int) throws {
        let taps = try #require(LanczosTaps(inputCount: input, outputCount: output))
        for o in 0..<output {
            let (first, weights) = taps.taps(at: o)
            #expect(abs(weights.reduce(0, +) - 1) < 1e-5)
            let centre = (Double(o) + 0.5) * Double(input) / Double(output) - 0.5
            // Every source sample within three of the centre is a tap, every tap is within three.
            #expect(centre - Double(first) >= 2 && centre - Double(first) < 3)
            #expect(LanczosTaps.kernel(centre - Double(first - 1)) == 0)
            #expect(LanczosTaps.kernel(centre - Double(first + 6)) == 0)
        }
    }

    @Test func twoXTapsAreTheTwoMirroredPhases() throws {
        let taps = try #require(LanczosTaps(inputCount: 1920, outputCount: 3840))
        let even = taps.taps(at: 200), odd = taps.taps(at: 201)
        #expect(even.first == 97 && odd.first == 98)
        for k in 0..<6 { #expect(abs(even.weights[k] - odd.weights[5 - k]) < 1e-6) }
    }

    @Test func flatStaysFlatAndAStepRingsWithinLanczosBounds() throws {
        let taps = try #require(LanczosTaps(inputCount: 32, outputCount: 64))
        #expect(taps.apply(Array(repeating: 100, count: 32)).allSatisfy { abs($0 - 100) < 1e-4 })
        let step = taps.apply((0..<32).map { $0 < 16 ? 16.0 : 235.0 })
        // Lanczos-3 rings at a step, about 10% of its height on each side at 2x; the stage clamps only to the
        // code range.
        #expect(step.max()! > 235 && step.max()! < 235 + 0.12 * 219)
        #expect(step.min()! < 16 && step.min()! > 16 - 0.12 * 219)
        #expect(abs(step[0] - 16) < 1e-4 && abs(step[63] - 235) < 1e-4)
    }

    @Test func aDownscaleIsRefused() {
        #expect(LanczosTaps(inputCount: 3840, outputCount: 1920) == nil)
        #expect(LanczosTaps(inputCount: 0, outputCount: 10) == nil)
    }
}
