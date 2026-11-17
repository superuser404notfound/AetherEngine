#if !targetEnvironment(simulator)
import Foundation
import Testing
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
@testable import AetherEngine

private enum ChainGate {
    static var gpuAvailable: Bool {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }
}

/// AE#957 / AE#1039: the GPU frame chain and its line-art stage. The colour round trip through RGB must
/// leave 8 and 10-bit frames as they were, the picture region must be honoured, and the line-art network
/// must keep flat areas flat and edges where they are.
@Suite("Frame chain", .serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)),
       .enabled(if: ChainGate.gpuAvailable))
struct FrameChainTests {

    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    private func chain(_ w: Int, _ h: Int, target: (Int, Int)? = nil, stages: [any FrameChainStage],
                       fusesRoundTrip: Bool = true, io: MetalFrameIO? = nil) throws -> FrameChain {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let t = target ?? (w, h)
        return try FrameChain(device: device, queue: queue, sourceWidth: w, sourceHeight: h,
                              targetWidth: t.0, targetHeight: t.1, stages: stages, fusesRoundTrip: fusesRoundTrip,
                              io: io)
    }

    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    private func whole(_ w: Int, _ h: Int) -> FrameUpscaler.PictureRegion {
        FrameUpscaler.PictureRegion(x: 0, y: 0, width: w, height: h)
    }

    @Test(arguments: [false, true])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func passThroughRoundTripKeepsTheFrame(tenBit: Bool) throws {
        let input = try ChainFrames.gradient(320, 180, tenBit: tenBit)
        let (out, _) = try chain(320, 180, stages: [PassThroughStage()]).process(input, picture: whole(320, 180))
        #expect(CVPixelBufferGetPixelFormatType(out) == CVPixelBufferGetPixelFormatType(input))
        let diff = ChainFrames.maxDifference(input, out)
        #expect(diff.y <= 1 && diff.c <= 1, "max difference Y \(diff.y), C \(diff.c) (tenBit \(tenBit))")
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func onlyThePictureRegionIsScaled() throws {
        let input = try ChainFrames.flat(320, 196, y: 126, c: 128)
        ChainFrames.paintRows(input, 0..<16, y: 235)
        let picture = FrameUpscaler.PictureRegion(x: 0, y: 16, width: 320, height: 180)
        let (out, _) = try chain(320, 180, target: (640, 360), stages: [PassThroughStage()]).process(input, picture: picture)
        #expect(CVPixelBufferGetWidth(out) == 640 && CVPixelBufferGetHeight(out) == 360)
        let range = ChainFrames.lumaRange(out)
        #expect(range.lowerBound >= 125 && range.upperBound <= 127, "Y \(range)")
    }

    /// The network adds a learned residual to the bilinear image; on a flat field there is nothing to add.
    @Test(arguments: [false, true])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func lineArtKeepsAFlatFieldFlat(tenBit: Bool) throws {
        let input = try ChainFrames.flat(480, 270, y: 126, c: 128, tenBit: tenBit)
        let (out, _) = try chain(480, 270, target: (960, 540), stages: [LineArtStage()]).process(input, picture: whole(480, 270))
        #expect(CVPixelBufferGetWidth(out) == 960 && CVPixelBufferGetHeight(out) == 540)
        let scale = tenBit ? 4 : 1
        let y = ChainFrames.lumaRange(out)
        print("[FrameChainTests] line art flat field Y \(y) (tenBit \(tenBit))")
        #expect(y.lowerBound >= (126 - 2) * scale && y.upperBound <= (126 + 2) * scale, "Y \(y)")
    }

    /// A hard vertical edge lands where the source puts it (between output columns 2e-1 and 2e) and the
    /// network sharpens it compared with a bilinear 2x, which leaves an intermediate column.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func lineArtKeepsAnEdgeInPlaceAndSharpensIt() throws {
        let input = try ChainFrames.flat(480, 270, y: 40, c: 128)
        ChainFrames.paintLuma(input) { x, _ in x < 240 ? 40 : 200 }
        let (out, _) = try chain(480, 270, target: (960, 540), stages: [LineArtStage()]).process(input, picture: whole(480, 270))
        let row = ChainFrames.lumaRow(out, 270)
        print("[FrameChainTests] line art edge columns 474...485: \(Array(row[474...485]))")
        #expect(row[470] < 60 && row[489] > 180, "far sides \(row[470]) / \(row[489])")
        #expect(row[478] < 120 && row[481] > 120, "edge between 479 and 480: \(Array(row[476...483]))")
        let bilinear = try chain(480, 270, target: (960, 540), stages: [PassThroughStage()]).process(input, picture: whole(480, 270)).0
        let soft = ChainFrames.lumaRow(bilinear, 270)
        func transition(_ r: [Int]) -> Int { r[470...489].filter { $0 > 60 && $0 < 180 }.count }
        #expect(transition(row) <= transition(soft), "transition width \(transition(row)) vs bilinear \(transition(soft))")
    }

    /// The last line-art stage at exactly 2x writes the output planes itself; that must match the general
    /// path (the 2x RGB texture, then the chain's conversion) to within rounding.
    @Test(arguments: [false, true], [false, true])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func directLineArtOutputMatchesTheGeneralPath(tenBit: Bool, restores: Bool) throws {
        let input = try ChainFrames.gradient(480, 270, tenBit: tenBit)
        ChainFrames.paintLuma(input) { x, y in ((x / 7 + y / 5) % 9 == 0) ? 30 : 60 + x / 4 }
        let direct = LineArtStage(restores: restores)
        let (a, _) = try chain(480, 270, target: (960, 540), stages: [direct]).process(input, picture: whole(480, 270))
        #expect(direct.writesOutputDirectly)
        let general = LineArtStage(restores: restores)
        let (b, _) = try chain(480, 270, target: (960, 540), stages: [general, PassThroughStage()])
            .process(input, picture: whole(480, 270))
        #expect(!general.writesOutputDirectly)
        let diff = ChainFrames.maxDifference(a, b)
        #expect(diff.y <= 1 && diff.c <= 1, "Y \(diff.y), C \(diff.c)")
    }

    /// AE#957: a chain whose stages leave the picture alone, at its own size, runs as one kernel with no
    /// RGB texture. It must give what the two passes give, to within rounding: 320 wide takes the wide
    /// kernel (four luma samples per texel), 322 the narrow one.
    @Test(arguments: [false, true], [320, 322])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957OneKernelRoundTripMatchesTheTwoPasses(tenBit: Bool, width: Int) throws {
        let input = try ChainFrames.gradient(width, 180, tenBit: tenBit)
        ChainFrames.paintLuma(input) { x, y in ((x / 7 + y / 5) % 9 == 0) ? 30 : 60 + x / 2 }
        let fused = try chain(width, 180, stages: [PassThroughStage(), PassThroughStage()])
        let twoPass = try chain(width, 180, stages: [PassThroughStage()], fusesRoundTrip: false)
        let scaled = try chain(width, 180, target: (width * 2, 360), stages: [PassThroughStage()])
        #expect(fused.isRoundTripOnly)
        #expect(!twoPass.isRoundTripOnly)
        #expect(!scaled.isRoundTripOnly)
        let wide = FrameChain.roundTripIsWide(targetWidth: width, pictureX: 0)
        #expect(wide == (width == 320))
        let (a, _) = try fused.process(input, picture: whole(width, 180))
        let (b, _) = try twoPass.process(input, picture: whole(width, 180))
        let diff = ChainFrames.maxDifference(a, b)
        #expect(diff.y <= 1 && diff.c <= 1, "Y \(diff.y), C \(diff.c) (tenBit \(tenBit), width \(width))")
    }

    /// A picture that starts inside the frame (a crop): both one-kernel versions read from its origin and give
    /// what the two passes give. x 4 keeps the wide kernel, x 2 takes the narrow one.
    @Test(arguments: [false, true], [4, 2])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957OneKernelRoundTripHonoursThePictureOrigin(tenBit: Bool, originX: Int) throws {
        let input = try ChainFrames.gradient(336, 200, tenBit: tenBit)
        ChainFrames.paintLuma(input) { x, y in ((x / 5 + y / 7) % 8 == 0) ? 40 : 50 + (x + y) / 3 }
        let picture = FrameUpscaler.PictureRegion(x: originX, y: 8, width: 320, height: 180)
        let fused = try chain(320, 180, stages: [PassThroughStage()])
        let twoPass = try chain(320, 180, stages: [PassThroughStage()], fusesRoundTrip: false)
        let wide = FrameChain.roundTripIsWide(targetWidth: 320, pictureX: originX)
        #expect(wide == (originX == 4))
        let (a, _) = try fused.process(input, picture: picture)
        let (b, _) = try twoPass.process(input, picture: picture)
        let diff = ChainFrames.maxDifference(a, b)
        #expect(diff.y <= 1 && diff.c <= 1, "Y \(diff.y), C \(diff.c) (tenBit \(tenBit), origin x \(originX))")
    }

    /// The wide kernel reads luma four samples at a time: a picture origin off those texels takes the narrow one.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957TheWideRoundTripNeedsFourSampleAlignment() {
        let aligned = FrameChain.roundTripIsWide(targetWidth: 3840, pictureX: 0)
        let offset = FrameChain.roundTripIsWide(targetWidth: 1920, pictureX: 2)
        let narrow = FrameChain.roundTripIsWide(targetWidth: 1918, pictureX: 0)
        #expect(aligned)
        #expect(!offset)
        #expect(!narrow)
    }

    /// AE#957: a stage that declares its output's colour volume sets the frames' HDR10 metadata, and a
    /// stage after it that declares nothing keeps it. The chain's attach step writes it over the source's.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957AStagesDeclaredColorVolumeReachesTheOutput() throws {
        let fitted = HDR10StaticMetadata(maxCLL: 800, maxFALL: 300, masteringPeakNits: 800, masteringMinNits: 0.0005)
        let input = try ChainFrames.gradient(320, 180, tenBit: true)
        let source = HDR10StaticMetadata(maxCLL: 4000, maxFALL: 1000, masteringPeakNits: 4000, masteringMinNits: 0.005)
        CVBufferSetAttachment(input, kCVImageBufferContentLightLevelInfoKey, source.contentLightLevel as CFData,
                              .shouldPropagate)
        let plain = try chain(320, 180, stages: [PassThroughStage()])
        #expect(plain.outputColorVolume == .unchanged)
        let fitting = try chain(320, 180, stages: [DeclaringStage(.hdr10(fitted)), PassThroughStage()])
        #expect(fitting.outputColorVolume == .hdr10(fitted))
        let (out, _) = try fitting.process(input, picture: whole(320, 180))
        fitting.attach(from: input, to: out)
        let lightLevel = CVBufferCopyAttachment(out, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
        let mastering = CVBufferCopyAttachment(out, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data
        #expect(lightLevel == fitted.contentLightLevel)
        #expect(mastering == fitted.masteringDisplayColorVolume)
    }

    /// AE#957: the tone map runs inside the one round-trip kernel and gives what its own pass between the two
    /// passes gives, to within rounding. 320 wide takes the wide kernel, 322 the narrow one.
    @Test(arguments: [320, 322])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957TheFusedToneMapMatchesItsOwnPass(width: Int) throws {
        let curve = try #require(BT2390ToneCurve(sourcePeakNits: 1000, targetPeakNits: 600))
        let master = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000, masteringMinNits: 0.005)
        let input = try ChainFrames.gradient(width, 180, tenBit: true)
        // Luma 240...720 of 1023: from about 6 nit, below the 464 nit knee, to about 990 nit, above it.
        let fused = try chain(width, 180, stages: [ToneMapStage(curve: curve, source: master), PassThroughStage()])
        let twoPass = try chain(width, 180, stages: [ToneMapStage(curve: curve, source: master)], fusesRoundTrip: false)
        let twoMaps = try chain(width, 180, stages: [ToneMapStage(curve: curve, source: master),
                                                     ToneMapStage(curve: curve, source: master)])
        #expect(fused.isRoundTripOnly)
        #expect(!twoPass.isRoundTripOnly)
        #expect(!twoMaps.isRoundTripOnly, "one fused stage per kernel")
        let (a, _) = try fused.process(input, picture: whole(width, 180))
        let (b, _) = try twoPass.process(input, picture: whole(width, 180))
        let diff = ChainFrames.maxDifference(a, b)
        #expect(diff.y <= 1 && diff.c <= 1, "Y \(diff.y), C \(diff.c) (width \(width))")
        // The ramp's top is brighter than the target, so the map lowers it; the dark end is below the knee.
        let plain = try chain(width, 180, stages: [PassThroughStage()]).process(input, picture: whole(width, 180)).0
        #expect(ChainFrames.lumaRange(a).upperBound < ChainFrames.lumaRange(plain).upperBound)
        #expect(ChainFrames.lumaRange(a).lowerBound == ChainFrames.lumaRange(plain).lowerBound)
        #expect(fused.outputColorVolume == .hdr10(curve.outputMetadata(from: master)))
    }

    /// Audit GPU-204: an A10X (Apple TV 4K 1st gen) has no non-uniform threadgroups, so every kernel runs in
    /// whole groups there and its bounds guard drops the threads past the edge. A width and height off the
    /// threadgroup grid must give the picture the non-uniform dispatch gives, on each kind of chain.
    @Test(arguments: ["round trip", "two passes", "line art"])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func gpu204WholeThreadgroupsGiveTheSamePicture(kind: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let uniform = try #require(MetalFrameIO(device: device, nonUniformThreadgroups: false))
        let curve = try #require(BT2390ToneCurve(sourcePeakNits: 1000, targetPeakNits: 600))
        let master = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000, masteringMinNits: 0.005)
        let (w, h) = (322, 182)
        func build(_ io: MetalFrameIO?) throws -> FrameChain {
            switch kind {
            case "round trip":
                return try chain(w, h, stages: [ToneMapStage(curve: curve, source: master)], io: io)
            case "two passes":
                return try chain(w, h, stages: [ToneMapStage(curve: curve, source: master)], fusesRoundTrip: false, io: io)
            default:
                return try chain(w, h, target: (w * 2, h * 2), stages: [LineArtStage()], io: io)
            }
        }
        let input = try ChainFrames.gradient(w, h, tenBit: true)
        let (expected, _) = try build(nil).process(input, picture: whole(w, h))
        let (got, _) = try build(uniform).process(input, picture: whole(w, h))
        let diff = ChainFrames.maxDifference(expected, got)
        #expect(diff.y == 0 && diff.c == 0, "\(kind): Y \(diff.y), C \(diff.c)")
    }

    /// Audit GPU-201: the work of a frame holds the texture cache its textures came from. The tone mapper
    /// drops or rebuilds its chain (and the chain's cache) with two frames on the GPU, and a CVMetalTexture
    /// that finalizes after its cache calls into freed memory (the FEL composer crashed that way).
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func gpu201AFramesWorkHoldsItsTextureCache() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let made = try #require(MetalFrameIO(device: device))
        let cache = made.textureCache
        var io: MetalFrameIO? = made
        var built: FrameChain? = try chain(320, 180, stages: [PassThroughStage()], io: io)
        let input = try ChainFrames.gradient(320, 180, tenBit: false)
        let encoded = try #require(try built?.encode(input, picture: whole(320, 180)))
        let textures = try #require(encoded.work.textures)
        #expect(textures.cache === cache)
        #expect(textures.count == 4, "both planes of the input and of the output")
        built = nil
        io = nil
        encoded.work.commandBuffer.commit()
        encoded.work.commandBuffer.waitUntilCompleted()
        _ = try encoded.work.finish()
        let diff = ChainFrames.maxDifference(input, encoded.output)
        #expect(diff.y <= 1 && diff.c <= 1)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func unsupportedFormatIsRefused() throws {
        let bgra = try ChainFrames.buffer(320, 180, format: kCVPixelFormatType_32BGRA)
        #expect(throws: FrameChain.Failure.self) {
            _ = try chain(320, 180, stages: [PassThroughStage()]).process(bgra, picture: whole(320, 180))
        }
    }
}

/// The line-art plan through `FrameUpscaler`: what the session sees.
@Suite("Line-art upscaler", .serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)),
       .enabled(if: ChainGate.gpuAvailable))
struct LineArtUpscalerTests {

    private func plan(_ w: Int, _ h: Int, sar: (Int, Int) = (1, 1), display: CGSize = CGSize(width: 3840, height: 2160)) throws -> UpscalePlan {
        try #require(UpscaleRouteDecision.makePlan(
            source: SourceGeometry(width: w, height: h, sarNum: sar.0, sarDen: sar.1),
            display: display, mlScaleFactors: { _, _ in [] }, scaler: .lineArt))
    }

    @Test(arguments: [false, true])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func fullHDGoesToUHDInTheInputFormat(tenBit: Bool) throws {
        let up = try #require(FrameUpscaler(plan: try plan(1920, 1080), frameInterval: 1.0 / 24))
        let input = try ChainFrames.gradient(1920, 1080, tenBit: tenBit)
        for _ in 0..<5 {
            let out = try #require(up.upscale(input, pts: .invalid))
            #expect(CVPixelBufferGetWidth(out) == 3840 && CVPixelBufferGetHeight(out) == 2160)
            #expect(CVPixelBufferGetPixelFormatType(out) == CVPixelBufferGetPixelFormatType(input))
            #expect(CVBufferCopyAttachment(out, kCVImageBufferYCbCrMatrixKey, nil) != nil)
        }
        #expect(up.stats.framesUpscaled == 5 && up.stats.failures == 0)
        #expect(up.delivered?.plan.scaler == .lineArt)
        print(String(format: "[LineArtUpscalerTests] 1920x1080 -> 3840x2160 (tenBit %@): mean %.2f ms, GPU %.2f ms",
                     tenBit ? "yes" : "no", up.stats.meanMs, up.stats.stageMeanMs.metalGPU))
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func otherFormatsPassThrough() throws {
        let up = try #require(FrameUpscaler(plan: try plan(1280, 720), frameInterval: 1.0 / 24))
        #expect(up.upscale(try ChainFrames.buffer(1280, 720, format: kCVPixelFormatType_32BGRA), pts: .invalid) == nil)
        #expect(!up.isDisabled)
        #expect(up.upscale(try ChainFrames.gradient(1280, 720, tenBit: false), pts: .invalid) != nil)
    }

    /// Audit GPU-203: the line-art chain's errors are `FrameChain.Failure`, which the upscaler's refusal check
    /// did not look through, so iOS background refusals counted and switched the stage off after three.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func gpu203BackgroundRefusalsNeverSwitchLineArtOff() throws {
        let up = try #require(FrameUpscaler(plan: try plan(640, 360, display: CGSize(width: 1280, height: 720)),
                                            frameInterval: 1.0 / 24))
        let input = try ChainFrames.gradient(640, 360, tenBit: false)
        up.forcedCommandBufferError = NSError(domain: MTLCommandBufferErrorDomain,
                                              code: Int(MTLCommandBufferError.Code.notPermitted.rawValue))
        for _ in 0..<6 { #expect(up.upscale(input, pts: .invalid) == nil) }
        #expect(!up.isDisabled && up.stats.failures == 0)
        up.forcedCommandBufferError = nil
        #expect(up.upscale(input, pts: .invalid) != nil)

        up.forcedCommandBufferError = NSError(domain: MTLCommandBufferErrorDomain,
                                              code: Int(MTLCommandBufferError.Code.timeout.rawValue))
        for _ in 0..<FrameUpscaler.maxConsecutiveFailures { _ = up.upscale(input, pts: .invalid) }
        #expect(up.isDisabled)
    }

    /// The ladder at 1080p: an overrun first drops the restore pass, a second one switches the stage off
    /// (nothing below line art takes 1080p). Both rungs are remembered.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func fullHDOverrunDropsRestoreThenSwitchesOff() throws {
        FrameUpscaler.resetLineArtCostMemoryForTesting()
        defer { FrameUpscaler.resetLineArtCostMemoryForTesting() }
        let p = try plan(1920, 1080)
        let up = try #require(FrameUpscaler(plan: p, frameInterval: 0.0001))
        #expect(up.runsLineArtRestore)
        let degraded = LockedPlan()
        up.onEvent = { if case let .degraded(plan, _, _) = $0 { degraded.set(plan) } }
        let input = try ChainFrames.gradient(1920, 1080, tenBit: false)
        for _ in 0..<48 { _ = up.upscale(input, pts: .invalid) }
        #expect(!up.isDisabled && !up.runsLineArtRestore && up.isDegraded)
        #expect(degraded.value?.scaler == .lineArt)
        #expect(up.upscale(input, pts: .invalid) != nil, "the stage without restore delivers frames")
        for _ in 0..<47 { _ = up.upscale(input, pts: .invalid) }
        #expect(up.isDisabled)
        #expect(LineArtCostMemory.overrun(covering: p, frameInterval: 0.0001, rung: .restore) != nil)
        #expect(LineArtCostMemory.overrun(covering: p, frameInterval: 0.0001, rung: .upscale) != nil)
    }

    /// A restore overrun earlier in the process starts the next stage that it covers without the restore pass.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func aRememberedRestoreOverrunStartsWithoutIt() throws {
        FrameUpscaler.resetLineArtCostMemoryForTesting()
        defer { FrameUpscaler.resetLineArtCostMemoryForTesting() }
        LineArtCostMemory.record(.init(width: 1280, height: 720, frameInterval: 1.0 / 24, meanMs: 40), rung: .restore)
        let covered = try #require(FrameUpscaler(plan: try plan(1920, 1080), frameInterval: 1.0 / 24))
        #expect(!covered.runsLineArtRestore)
        let smaller = try #require(FrameUpscaler(plan: try plan(960, 540), frameInterval: 1.0 / 24))
        #expect(smaller.runsLineArtRestore)
    }

    /// The automatic route takes 8-bit only, so a 10-bit source below 1080p has nothing to fall back to.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func tenBitOverrunBelow1080pSwitchesOff() throws {
        FrameUpscaler.resetLineArtCostMemoryForTesting()
        defer { FrameUpscaler.resetLineArtCostMemoryForTesting() }
        let up = try #require(FrameUpscaler(plan: try plan(1280, 720), frameInterval: 0.0001))
        let input = try ChainFrames.gradient(1280, 720, tenBit: true)
        for _ in 0..<96 { _ = up.upscale(input, pts: .invalid) }
        #expect(up.isDisabled)
        #expect(up.plan.scaler == .lineArt)
    }

    /// Below 1080p the next best is the automatic route: VT super resolution, MetalFX where it is there.
    @Test(.enabled(if: LineArtGate.mlAvailable))
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func overrunBelow1080pFallsBackToTheAutomaticScaler() throws {
        FrameUpscaler.resetLineArtCostMemoryForTesting()
        defer { FrameUpscaler.resetLineArtCostMemoryForTesting() }
        let up = try #require(FrameUpscaler(plan: try plan(1280, 720), frameInterval: 0.0001))
        let fallback = LockedPlan()
        up.onEvent = { if case let .degraded(plan, _, _) = $0 { fallback.set(plan) } }
        let input = try ChainFrames.gradient(1280, 720, tenBit: false)
        for _ in 0..<96 { _ = up.upscale(input, pts: .invalid) }
        #expect(!up.isDisabled)
        #expect(fallback.value?.scaler == .automatic && fallback.value?.mlScale != nil)
        #expect(up.plan.scaler == .automatic)
        #expect(up.upscale(input, pts: .invalid) != nil, "the fallback stage delivers frames")
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func aSizeChangeRebuildsUpToFullHD() throws {
        let up = try #require(FrameUpscaler(plan: try plan(1280, 720), frameInterval: 1.0 / 24))
        let out = try #require(up.upscale(try ChainFrames.gradient(1920, 1080, tenBit: false), pts: .invalid))
        #expect(CVPixelBufferGetWidth(out) == 3840 && up.plan.sourceWidth == 1920 && up.plan.scaler == .lineArt)
        #expect(up.upscale(try ChainFrames.gradient(2560, 1440, tenBit: false), pts: .invalid) == nil)
        #expect(!up.isDisabled)
    }
}

private enum LineArtGate {
    /// VT super resolution reports support on GitHub's macOS VMs yet fails every pass, so one real pass decides.
    static let mlAvailable: Bool = {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *), ChainGate.gpuAvailable,
              let plan = UpscaleRouteDecision.makePlan(
                  source: SourceGeometry(width: 1280, height: 720, sarNum: 1, sarDen: 1),
                  display: CGSize(width: 1920, height: 1080), mlScaleFactors: FrameUpscaler.mlScaleFactors),
              plan.mlScale != nil,
              let up = FrameUpscaler(plan: plan, frameInterval: 1.0 / 24),
              let frame = try? ChainFrames.gradient(1280, 720, tenBit: false)
        else { return false }
        return up.upscale(frame, pts: .invalid) != nil
    }()
}

private final class LockedPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: UpscalePlan?
    func set(_ p: UpscalePlan) { lock.lock(); plan = p; lock.unlock() }
    var value: UpscalePlan? { lock.lock(); defer { lock.unlock() }; return plan }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Hands its input on unchanged but declares a colour volume, as a tone mapper would.
@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
private final class DeclaringStage: FrameChainStage {
    let outputColorVolume: FrameChainColorVolume
    init(_ volume: FrameChainColorVolume) { outputColorVolume = volume }
    func prepare(io: MetalFrameIO, kernels: FrameChainKernels, input: (Int, Int), finalTarget: (Int, Int)?) throws -> (Int, Int) {
        input
    }
    func encode(_ encoder: MTLComputeCommandEncoder, input: MTLTexture) -> MTLTexture { input }
}

/// #957: the picture processing stage as the session runs it: a PQ frame is tone mapped and goes out with
/// the target's metadata; what it does not apply to passes through; HDR10+ and an overrun switch it off.
@Suite("Picture processing stage (#957)", .serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)),
       .enabled(if: ChainGate.gpuAvailable))
struct FrameToneMapperTests {

    private static let master = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                                    masteringMinNits: 0.005)

    private func plan() throws -> VideoProcessingPlan {
        try #require(VideoProcessingRouteDecision.decide(
            options: VideoProcessingOptions(targetPeakNits: 600), osSupportsStage: true, isPQ: true,
            isDolbyVision: false, carriesHDR10Plus: false, displayTakesHDR10: true, declared: Self.master,
            width: 320, height: 180, isFourTwoZero: true, wirelessAirPlayRoute: false, demuxedAudioLive: false).plan)
    }

    /// A 10-bit ramp from about 6 to about 990 nit, tagged PQ, with `metadata` attached when given.
    private func frame(pq: Bool = true, metadata: HDR10StaticMetadata? = master) throws -> CVPixelBuffer {
        let pb = try ChainFrames.gradient(320, 180, tenBit: true)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                              pq ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2,
                              .shouldPropagate)
        if let metadata {
            CVBufferSetAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey,
                                  metadata.masteringDisplayColorVolume as CFData, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferContentLightLevelInfoKey,
                                  metadata.contentLightLevel as CFData, .shouldPropagate)
        }
        return pb
    }

    private static func metadata(of pb: CVPixelBuffer) -> HDR10StaticMetadata? {
        HDR10StaticMetadata(
            masteringDisplayColorVolume: CVBufferCopyAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data,
            contentLightLevel: CVBufferCopyAttachment(pb, kCVImageBufferContentLightLevelInfoKey, nil) as? Data)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957APQFrameIsMappedAndSaysTheTarget() throws {
        let plan = try plan()
        let stage = FrameToneMapper(plan: plan, frameInterval: 1.0 / 24)
        let input = try frame()
        let output = try #require(stage.process(input, pts: CMTime(value: 0, timescale: 24), carriesHDR10Plus: false))
        #expect(ChainFrames.lumaRange(output).upperBound < ChainFrames.lumaRange(input).upperBound)
        #expect(ChainFrames.lumaRange(output).lowerBound == ChainFrames.lumaRange(input).lowerBound)
        #expect(Self.metadata(of: output) == plan.curve.outputMetadata(from: Self.master))
        #expect(stage.delivered == VideoProcessingStatus(stages: [.toneMap], sourcePeakNits: 1000, sourcePeak: .mastering,
                                                         targetPeakNits: 600))
        #expect(stage.disabledReason == nil)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957AFrameWithoutMetadataUsesTheSourcesDeclaration() throws {
        let plan = try plan()
        let stage = FrameToneMapper(plan: plan, frameInterval: 1.0 / 24)
        let output = try #require(stage.process(try frame(metadata: nil), pts: .zero, carriesHDR10Plus: false))
        #expect(Self.metadata(of: output) == plan.curve.outputMetadata(from: Self.master))
    }

    /// A frame whose own metadata gives another peak rebuilds the curve, and the status follows it.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957AFrameWithItsOwnPeakRepublishesTheStatus() throws {
        let stage = FrameToneMapper(plan: try plan(), frameInterval: 1.0 / 24)
        let events = EventBox()
        stage.onEvent = { events.append($0) }
        #expect(stage.process(try frame(), pts: .zero, carriesHDR10Plus: false) != nil)
        #expect(stage.process(try frame(), pts: .zero, carriesHDR10Plus: false) != nil)
        let brighter = HDR10StaticMetadata(maxCLL: 1500, maxFALL: 400, masteringPeakNits: 4000, masteringMinNits: 0.005)
        #expect(stage.process(try frame(metadata: brighter), pts: .zero, carriesHDR10Plus: false) != nil)
        #expect(stage.delivered == VideoProcessingStatus(stages: [.toneMap], sourcePeakNits: 1500, sourcePeak: .maxCLL,
                                                         targetPeakNits: 600))
        #expect(events.count(where: { if case .processed = $0 { true } else { false } }) == 2,
                "the first frame and the rebuild, not every frame")
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957WhatTheStageDoesNotApplyToPassesThrough() throws {
        let stage = FrameToneMapper(plan: try plan(), frameInterval: 1.0 / 24)
        #expect(stage.process(try frame(pq: false), pts: .zero, carriesHDR10Plus: false) == nil)
        let dim = HDR10StaticMetadata(maxCLL: 500, maxFALL: 200, masteringPeakNits: 500, masteringMinNits: 0.005)
        #expect(stage.process(try frame(metadata: dim), pts: .zero, carriesHDR10Plus: false) == nil)
        #expect(stage.disabledReason == nil, "passing a frame through is no failure")
        #expect(stage.process(try frame(), pts: .zero, carriesHDR10Plus: false) != nil)
    }

    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957HDR10PlusSwitchesItOffForGood() throws {
        let stage = FrameToneMapper(plan: try plan(), frameInterval: 1.0 / 24)
        #expect(stage.process(try frame(), pts: .zero, carriesHDR10Plus: true) == nil)
        #expect(stage.disabled?.cause == .hdr10Plus)
        #expect(stage.process(try frame(), pts: .zero, carriesHDR10Plus: false) == nil)
    }

    /// A frame interval no frame can meet: the 48-frame window fills, its mean is over 90% of it, and the
    /// stage switches itself off once, with the reason.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func issue957ASustainedOverrunSwitchesItOff() throws {
        let stage = FrameToneMapper(plan: try plan(), frameInterval: 1e-6)
        let events = EventBox()
        stage.onEvent = { events.append($0) }
        let input = try frame()
        for _ in 0 ..< FrameToneMapper.budgetWindow - 1 {
            #expect(stage.process(input, pts: .invalid, carriesHDR10Plus: false) != nil)
        }
        #expect(stage.disabledReason == nil)
        _ = stage.process(input, pts: .invalid, carriesHDR10Plus: false)
        #expect(stage.disabled?.cause == .overrun)
        #expect(stage.disabledReason?.hasPrefix("over budget") == true)
        #expect(stage.process(input, pts: .invalid, carriesHDR10Plus: false) == nil)
        #expect(events.count(where: { if case .disabled = $0 { true } else { false } }) == 1)
        #expect(events.count(where: { if case .processed = $0 { true } else { false } }) == 1)
    }

    /// Audit GPU-201: a frame with its own metadata rebuilds the chain while the two frames before it are
    /// still on the GPU, which releases the old chain and its texture cache under them. Their work holds
    /// that cache now, so they complete and deliver their picture.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func gpu201ARebuildWithFramesInFlightDeliversThem() throws {
        let stage = FrameToneMapper(plan: try plan(), frameInterval: 1.0 / 24)
        var inFlight: [(EncodedGPUWork, @Sendable (Double) -> CVPixelBuffer?)] = []
        for metadata in [Self.master, Self.master,
                         HDR10StaticMetadata(maxCLL: 1500, maxFALL: 400, masteringPeakNits: 4000, masteringMinNits: 0.005)] {
            guard case let .gpu(work, complete) = stage.begin(try frame(metadata: metadata), pts: .zero,
                                                               carriesHDR10Plus: false) else {
                Issue.record("a PQ frame above the target goes to the GPU")
                return
            }
            inFlight.append((work, complete))
        }
        for (work, complete) in inFlight {
            work.commandBuffer.commit()
            work.commandBuffer.waitUntilCompleted()
            #expect(complete(0) != nil)
        }
        inFlight.removeAll()
        #expect(stage.disabled == nil && stage.stats.framesProcessed == 3)
    }

    /// Audit GPU-203: iOS refuses GPU work in the background with `notPermitted`. The chain wraps that in its
    /// own error, which the check did not look through, so three refused frames switched the stage off and
    /// the engine latched the title as failed for the process. Any other error still does after three.
    @Test
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func gpu203BackgroundRefusalsNeverSwitchItOff() throws {
        let stage = FrameToneMapper(plan: try plan(), frameInterval: 1.0 / 24)
        let input = try frame()
        stage.forcedCommandBufferError = NSError(domain: MTLCommandBufferErrorDomain,
                                                 code: Int(MTLCommandBufferError.Code.notPermitted.rawValue))
        for _ in 0..<6 { #expect(stage.process(input, pts: .invalid, carriesHDR10Plus: false) == nil) }
        #expect(stage.disabled == nil && stage.stats.failures == 0)
        stage.forcedCommandBufferError = nil
        #expect(stage.process(input, pts: .invalid, carriesHDR10Plus: false) != nil)

        stage.forcedCommandBufferError = NSError(domain: MTLCommandBufferErrorDomain,
                                                 code: Int(MTLCommandBufferError.Code.timeout.rawValue))
        for _ in 0..<FrameToneMapper.maxConsecutiveFailures {
            #expect(stage.process(input, pts: .invalid, carriesHDR10Plus: false) == nil)
        }
        #expect(stage.disabled?.cause == .failures)
    }

    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [FrameToneMapper.Event] = []
        func append(_ e: FrameToneMapper.Event) { lock.lock(); events.append(e); lock.unlock() }
        func count(where match: (FrameToneMapper.Event) -> Bool) -> Int {
            lock.lock(); defer { lock.unlock() }
            return events.filter(match).count
        }
    }
}

/// 8-bit (420v) and 10-bit (x420) BT.709 video-range test frames. 10-bit samples sit in the high bits of 16.
private enum ChainFrames {
    struct Failure: Error {}

    static func buffer(_ w: Int, _ h: Int, format: OSType) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, format, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { throw Failure() }
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pb
    }

    private static func isTenBit(_ pb: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    /// Writes 8-bit-scale codes; a 10-bit frame gets them times 4.
    private static func fill(_ pb: CVPixelBuffer, y: (Int, Int) -> Int, c: (Int, Int) -> (Int, Int)) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ten = isTenBit(pb)
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
            for row in 0..<h {
                for x in 0..<w {
                    let values = plane == 0 ? [y(x, row)] : { let v = c(x, row); return [v.0, v.1] }()
                    for (i, v) in values.enumerated() {
                        let index = x * values.count + i
                        if ten {
                            base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)[index] = UInt16(v) << 6
                        } else {
                            base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)[index] = UInt8(v)
                        }
                    }
                }
            }
        }
    }

    static func gradient(_ w: Int, _ h: Int, tenBit: Bool) throws -> CVPixelBuffer {
        let pb = try buffer(w, h, format: tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let s = tenBit ? 4 : 1
        fill(pb, y: { x, _ in (60 + x * 120 / max(w - 1, 1)) * s },
             c: { x, row in ((120 + row * 16 / max(h / 2 - 1, 1)) * s, (136 - x * 16 / max(w / 2 - 1, 1)) * s) })
        return pb
    }

    static func flat(_ w: Int, _ h: Int, y: Int, c: Int, tenBit: Bool = false) throws -> CVPixelBuffer {
        let pb = try buffer(w, h, format: tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let s = tenBit ? 4 : 1
        fill(pb, y: { _, _ in y * s }, c: { _, _ in (c * s, c * s) })
        return pb
    }

    static func paintLuma(_ pb: CVPixelBuffer, _ value: (Int, Int) -> Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let p = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeight(pb) {
            for x in 0..<CVPixelBufferGetWidth(pb) { p[y * stride + x] = UInt8(value(x, y)) }
        }
    }

    static func paintRows(_ pb: CVPixelBuffer, _ rows: Range<Int>, y value: Int) {
        paintLuma(pb) { _, y in rows.contains(y) ? value : sample(pb, plane: 0, x: 0, y: y) }
    }

    private static func sample(_ pb: CVPixelBuffer, plane: Int, x: Int, y: Int, component: Int = 0, components: Int = 1) -> Int {
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
        let index = x * components + component
        if isTenBit(pb) {
            return Int(base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)[index] >> 6)
        }
        return Int(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[index])
    }

    static func lumaRange(_ pb: CVPixelBuffer) -> ClosedRange<Int> {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var lo = Int.max, hi = Int.min
        for y in 0..<CVPixelBufferGetHeight(pb) {
            for x in 0..<CVPixelBufferGetWidth(pb) {
                let v = sample(pb, plane: 0, x: x, y: y)
                lo = min(lo, v); hi = max(hi, v)
            }
        }
        return lo...hi
    }

    static func lumaRow(_ pb: CVPixelBuffer, _ row: Int) -> [Int] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        return (0..<CVPixelBufferGetWidth(pb)).map { sample(pb, plane: 0, x: $0, y: row) }
    }

    /// Largest absolute difference per plane between two frames of the same size and format.
    static func maxDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (y: Int, c: Int) {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly); CVPixelBufferUnlockBaseAddress(a, .readOnly) }
        var dy = 0, dc = 0
        for y in 0..<CVPixelBufferGetHeight(a) {
            for x in 0..<CVPixelBufferGetWidth(a) {
                dy = max(dy, abs(sample(a, plane: 0, x: x, y: y) - sample(b, plane: 0, x: x, y: y)))
            }
        }
        for y in 0..<CVPixelBufferGetHeightOfPlane(a, 1) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(a, 1) {
                for k in 0..<2 {
                    dc = max(dc, abs(sample(a, plane: 1, x: x, y: y, component: k, components: 2)
                                     - sample(b, plane: 1, x: x, y: y, component: k, components: 2)))
                }
            }
        }
        return (dy, dc)
    }
}
#endif
