import Foundation
import CoreMedia
import CoreVideo
import Metal
import CoreGraphics

/// One timed piece of per-frame work, in microseconds of wall time per frame.
public struct PerFrameBenchmarkResult: Codable, Sendable, Equatable {
    public let name: String
    public let iterations: Int
    public let minMicroseconds: Double
    public let medianMicroseconds: Double
    public let p95Microseconds: Double
    public let p99Microseconds: Double
    public let maxMicroseconds: Double
    /// Why a case did not run, or what else it measured (the frame chain's GPU time).
    public let note: String?
}

/// What `AetherEngine.runPerFrameBenchmarks` measured, and where.
public struct PerFrameBenchmarkReport: Codable, Sendable, Equatable {
    public let device: String
    public let os: String
    public let width: Int
    public let height: Int
    public let results: [PerFrameBenchmarkResult]
}

/// One case that got worse against a baseline report: slower beyond the tolerance, or ran in the baseline and
/// not now (skipped or missing). A gate that let a case quietly stop running would pass exactly when the
/// thing it times broke.
public struct PerFrameBenchmarkRegression: Sendable, Equatable {
    public let name: String
    public let reason: String
}

extension PerFrameBenchmarkReport {
    /// A case regresses when its median grows by more than `tolerance` (a fraction) and by more than this
    /// many microseconds. On the A12 Apple TV the same build's in-place tagging measured 18 us in one run and
    /// 48 us in the next (the thread on another core), and 50 us is 0.3% of a 59.94 fps frame.
    public static let regressionFloorMicroseconds = 50.0

    /// The cases that regressed against `baseline`, in the baseline's order. `aetherctl bench` fails on any.
    public func regressions(against baseline: PerFrameBenchmarkReport, tolerance: Double) -> [PerFrameBenchmarkRegression] {
        baseline.results.filter { $0.iterations > 0 }.compactMap { old in
            guard let now = results.first(where: { $0.name == old.name }) else {
                return PerFrameBenchmarkRegression(name: old.name, reason: "ran in the baseline, missing now")
            }
            guard now.iterations > 0 else {
                return PerFrameBenchmarkRegression(
                    name: old.name, reason: "ran in the baseline, skipped now: " + (now.note ?? "no reason given"))
            }
            let change = (now.medianMicroseconds - old.medianMicroseconds) / max(old.medianMicroseconds, 0.001)
            guard change > tolerance,
                  now.medianMicroseconds - old.medianMicroseconds > Self.regressionFloorMicroseconds else { return nil }
            return PerFrameBenchmarkRegression(
                name: old.name, reason: String(format: "median %.1f us, was %.1f (%+.0f%%)",
                                               now.medianMicroseconds, old.medianMicroseconds, change * 100))
        }
    }
}

extension AetherEngine {
    /// Times the per-frame work the software path does around each decoded frame, at the given picture
    /// size (4K P010 by default): the output metadata normalizer's three outcomes, the renderer's sample
    /// buffer, the HDR10 key-frame SEI scan and the frame chain. The upscale cases scale fixed 8-bit
    /// sources (480p, 720p, 1080p) to a 3840x2160 display, whatever the size given. For finding regressions and judging
    /// optimisations on a device; `aetherctl bench` runs it, and a tvOS host can call it.
    @MainActor
    public static func runPerFrameBenchmarks(iterations: Int = 300, width: Int = 3840,
                                             height: Int = 2160) -> PerFrameBenchmarkReport {
        PerFrameBenchmark(iterations: max(iterations, 10), width: width, height: height).run()
    }
}

@MainActor
struct PerFrameBenchmark {
    let iterations: Int
    let width: Int
    let height: Int
    /// False skips the frame chain and upscale cases, which compile their kernels (minutes on a cold CI
    /// runner) and wait on the GPU: for the unit test, which checks the case list and the report.
    var includesGPU = true
    static let warmup = 20

    /// A typical HDR10 master (BT.2020, 1000 nit, MaxCLL 1000 / 400), in Core Video's byte layout.
    static let hdr10 = HDR10StaticMetadataSEI.Values(
        masteringDisplay: HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                              masteringMinNits: 0.005).masteringDisplayColorVolume,
        contentLightLevel: HDR10StaticMetadataSEI.contentLightLevel(maxCLL: 1000, maxFALL: 400))

    func run() -> PerFrameBenchmarkReport {
        var results: [PerFrameBenchmarkResult] = []
        if let frame = Self.makeFrame(width: width, height: height,
                                      format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
            results.append(normalizerAlreadyTagged(frame))
            results.append(normalizerInPlace(frame))
            results.append(normalizerOwnedCopy(frame))
            results.append(rendererSampleBuffer(frame))
            if includesGPU {
                for chainCase in ChainCase.allCases { results.append(chain(frame, chainCase)) }
            } else {
                for chainCase in ChainCase.allCases { results.append(Self.skipped(chainCase.rawValue, "not requested")) }
            }
        } else {
            results.append(Self.skipped("frames", "could not create a \(width)x\(height) P010 buffer"))
        }
        results.append(keyFrameSEIScan())
        for upscaleCase in UpscaleCase.allCases {
            results.append(includesGPU ? upscale(upscaleCase) : Self.skipped(upscaleCase.rawValue, "not requested"))
        }
        return PerFrameBenchmarkReport(device: Self.deviceName(), os: ProcessInfo.processInfo.operatingSystemVersionString,
                                       width: width, height: height, results: results)
    }

    // MARK: - Cases

    /// The common case once the frame carries everything: five attachment reads and compares.
    private func normalizerAlreadyTagged(_ frame: CVPixelBuffer) -> PerFrameBenchmarkResult {
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        _ = apply(normalizer, frame, modifiable: true)
        return time("normalizer: frame already tagged") { _ = apply(normalizer, frame, modifiable: false) }
    }

    /// A decoder buffer VideoToolbox lets us modify: the attachments are written in place.
    private func normalizerInPlace(_ frame: CVPixelBuffer) -> PerFrameBenchmarkResult {
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        return time("normalizer: tag in place", prepare: { Self.strip(frame) }) {
            _ = apply(normalizer, frame, modifiable: true)
        }
    }

    /// A decoder buffer VideoToolbox still owns: the frame is copied into a pool of our own first.
    private func normalizerOwnedCopy(_ frame: CVPixelBuffer) -> PerFrameBenchmarkResult {
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        Self.strip(frame)
        return time("normalizer: owned copy") { _ = apply(normalizer, frame, modifiable: false) }
    }

    /// Every frame on its way to the display layer, with the format description cache hit.
    private func rendererSampleBuffer(_ frame: CVPixelBuffer) -> PerFrameBenchmarkResult {
        let renderer = SampleBufferRenderer()
        _ = apply(VideoToolboxOutputMetadataNormalizer(), frame, modifiable: true)
        var n: Int64 = 0
        return time("renderer: sample buffer") {
            n += 1
            _ = renderer.createSampleBuffer(from: frame, pts: CMTime(value: n, timescale: 24))
        }
    }

    /// A 4K key frame of about 250 KB: the in-band scan for the HDR10 SEI walks every NAL of it.
    private func keyFrameSEIScan() -> PerFrameBenchmarkResult {
        let packet = Self.keyFramePacket(sliceBytes: 250_000)
        return packet.withUnsafeBufferPointer { bytes in
            time("sei: HDR10 scan of a 250 KB key frame") {
                _ = HDR10StaticMetadataSEI.scan(bytes.baseAddress!, size: bytes.count, codec: .hevc,
                                                framing: .lengthPrefixed(size: 4))
            }
        }
    }

    /// The frame chain cases. The tone map runs the real BT.2390 kernel (no branch, so a flat frame costs
    /// what a real one does), from `toneMapCurve`.
    enum ChainCase: String, CaseIterable {
        case passThrough = "chain: pass-through, wall time"
        case twoPasses = "chain: two passes through RGB, wall time"
        case toneMap = "chain: tone map, one kernel, wall time"
        case toneMapTwoPasses = "chain: tone map, two passes, wall time"

        /// The one-kernel cases: what a chain of identity stages and one fused stage runs.
        var onePass: Bool { self == .passThrough || self == .toneMap }
        var toneMaps: Bool { self == .toneMap || self == .toneMapTwoPasses }
    }

    /// The bench's tone map: the 1000 nit master of `hdr10` to a 600 nit target.
    static let toneMapCurve = BT2390ToneCurve(sourcePeakNits: 1000, targetPeakNits: 600)!

    /// The chain's colour round trip, and the same with the tone map: as one kernel, and as the two passes
    /// through the RGB texture that every other stage needs.
    private func chain(_ frame: CVPixelBuffer, _ chainCase: ChainCase) -> PerFrameBenchmarkResult {
        let name = chainCase.rawValue
        #if targetEnvironment(simulator)
        return Self.skipped(name, "the frame chain is not built for the simulator")
        #else
        guard #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *) else {
            return Self.skipped(name, "the frame chain needs OS 26")
        }
        let stage: any FrameChainStage = chainCase.toneMaps
            ? ToneMapStage(curve: Self.toneMapCurve,
                           source: HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                                       masteringMinNits: 0.005))
            : PassThroughStage()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let chain = try? FrameChain(device: device, queue: queue, sourceWidth: width, sourceHeight: height,
                                          targetWidth: width, targetHeight: height, stages: [stage],
                                          fusesRoundTrip: chainCase.onePass)
        else { return Self.skipped(name, "no Metal device or the chain could not be built") }
        let picture = FrameUpscaler.pictureRegion(of: frame)
        var gpu: [Double] = []
        var result = time(name) {
            if let (_, ms) = try? chain.process(frame, picture: picture) { gpu.append(ms) }
        }
        gpu.sort()
        if !gpu.isEmpty {
            result = PerFrameBenchmarkResult(
                name: result.name, iterations: result.iterations, minMicroseconds: result.minMicroseconds,
                medianMicroseconds: result.medianMicroseconds, p95Microseconds: result.p95Microseconds,
                p99Microseconds: result.p99Microseconds, maxMicroseconds: result.maxMicroseconds,
                note: String(format: "GPU median %.0f us", gpu[gpu.count / 2] * 1000))
        }
        return result
        #endif
    }

    /// The upscale cases (`upscalesLowResolutionVideo`), each the stage playback builds for its plan:
    /// `automatic` takes the VT super-resolution factor the device offers, then MetalFX to the target.
    enum UpscaleCase: String, CaseIterable {
        case automatic480 = "upscale: 480p to 2160p, automatic, wall time"
        case automatic720 = "upscale: 720p to 2160p, automatic, wall time"
        case metalFX720 = "upscale: 720p to 2160p, MetalFX only, wall time"
        case lineArt1080 = "upscale: 1080p to 2160p, line art, wall time"
        case lineArtRestore1080 = "upscale: 1080p to 2160p, line art with restore, wall time"

        /// The coded source: 16:9 DVD (720x480, 32:27 pixels), 720p, 1080p.
        var source: SourceGeometry {
            switch self {
            case .automatic480: return SourceGeometry(width: 720, height: 480, sarNum: 32, sarDen: 27)
            case .automatic720, .metalFX720: return SourceGeometry(width: 1280, height: 720, sarNum: 1, sarDen: 1)
            case .lineArt1080, .lineArtRestore1080: return SourceGeometry(width: 1920, height: 1080, sarNum: 1, sarDen: 1)
            }
        }
        var scaler: UpscaleScaler { self == .lineArt1080 || self == .lineArtRestore1080 ? .lineArt : .automatic }
    }

    /// The display every upscale case fills.
    static let upscaleDisplay = CGSize(width: 3840, height: 2160)

    private func upscale(_ upscaleCase: UpscaleCase) -> PerFrameBenchmarkResult {
        let name = upscaleCase.rawValue
        #if targetEnvironment(simulator)
        return Self.skipped(name, "the upscale stage is not built for the simulator")
        #else
        guard #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *) else {
            return Self.skipped(name, "the upscale stage needs OS 26")
        }
        let source = upscaleCase.source
        let metalFXOnly = upscaleCase == .metalFX720
        let factors: (Int, Int) -> [Float] = { metalFXOnly ? [] : FrameUpscaler.mlScaleFactors($0, $1) }
        guard let plan = UpscaleRouteDecision.makePlan(source: source, display: Self.upscaleDisplay,
                                                       mlScaleFactors: factors, scaler: upscaleCase.scaler),
              let frame = Self.makeFrame(width: source.width, height: source.height,
                                         format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        else { return Self.skipped(name, "no plan or no \(source.width)x\(source.height) NV12 buffer") }
        let stage: UpscaleBenchmarkStage
        do {
            stage = try UpscaleBenchmarkStage(plan: plan, restores: upscaleCase == .lineArtRestore1080)
            // The first frame: VT super resolution can report support and still refuse every pass
            // (GitHub's macOS VMs, the A12 Apple TV on tvOS 27.2).
            _ = try stage.process(frame)
        } catch {
            return Self.skipped(name, "\(error)")
        }
        var steps: [FrameUpscaler.StageTimes] = []
        var failures = 0
        let result = time(name) {
            if let times = try? stage.process(frame) { steps.append(times) } else { failures += 1 }
        }
        func median(_ key: KeyPath<FrameUpscaler.StageTimes, Double>) -> Double {
            let sorted = steps.map { $0[keyPath: key] }.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2] * 1000
        }
        var note = Self.describe(stage.plan)
        if stage.plan.mlScale != nil { note += String(format: "; ML median %.0f us", median(\.ml)) }
        note += String(format: "; GPU median %.0f us", median(\.metalGPU))
        if failures > 0 { note += "; \(failures) frames failed" }
        return PerFrameBenchmarkResult(
            name: result.name, iterations: result.iterations, minMicroseconds: result.minMicroseconds,
            medianMicroseconds: result.medianMicroseconds, p95Microseconds: result.p95Microseconds,
            p99Microseconds: result.p99Microseconds, maxMicroseconds: result.maxMicroseconds, note: note)
        #endif
    }

    /// "1280x720 -> ML 2x 2560x1440 -> MetalFX 3840x2160": the steps of a plan, for the note.
    static func describe(_ plan: UpscalePlan) -> String {
        var steps = ["\(plan.sourceWidth)x\(plan.sourceHeight)"]
        switch plan.scaler {
        case .lineArt:
            steps.append("line art \(plan.mlOutputWidth)x\(plan.mlOutputHeight)")
            if plan.mlOutputWidth != plan.targetWidth || plan.mlOutputHeight != plan.targetHeight {
                steps.append("bilinear \(plan.targetWidth)x\(plan.targetHeight)")
            }
        case .automatic:
            if let scale = plan.mlScale {
                steps.append("ML " + String(format: "%g", scale) + "x \(plan.mlOutputWidth)x\(plan.mlOutputHeight)")
            }
            if plan.needsMetalFX { steps.append("MetalFX \(plan.targetWidth)x\(plan.targetHeight)") }
        }
        return steps.joined(separator: " -> ")
    }

    // MARK: - Helpers

    private func apply(_ normalizer: VideoToolboxOutputMetadataNormalizer, _ frame: CVPixelBuffer,
                       modifiable: Bool) -> CVPixelBuffer {
        normalizer.applyingOutputMetadata(
            to: frame, isModifiable: modifiable,
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020, pixelAspectRatio: nil, hdr10: Self.hdr10)
    }

    private static func strip(_ frame: CVPixelBuffer) {
        CVBufferRemoveAttachment(frame, kCVImageBufferMasteringDisplayColorVolumeKey)
        CVBufferRemoveAttachment(frame, kCVImageBufferContentLightLevelInfoKey)
    }

    /// Times `body` after a warm-up; `prepare` runs before each call, outside the timing.
    private func time(_ name: String, prepare: () -> Void = {}, _ body: () -> Void) -> PerFrameBenchmarkResult {
        for _ in 0 ..< Self.warmup { prepare(); body() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0 ..< iterations {
            prepare()
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            body()
            samples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1000)
        }
        samples.sort()
        func at(_ q: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
        return PerFrameBenchmarkResult(name: name, iterations: iterations, minMicroseconds: samples[0],
                                       medianMicroseconds: at(0.5), p95Microseconds: at(0.95),
                                       p99Microseconds: at(0.99), maxMicroseconds: samples[samples.count - 1],
                                       note: nil)
    }

    private static func skipped(_ name: String, _ why: String) -> PerFrameBenchmarkResult {
        PerFrameBenchmarkResult(name: name, iterations: 0, minMicroseconds: 0, medianMicroseconds: 0,
                                p95Microseconds: 0, p99Microseconds: 0, maxMicroseconds: 0, note: why)
    }

    /// A 4:2:0 IOSurface frame (P010 for the 4K cases, NV12 for the upscale sources), written once so its
    /// pages are real.
    private static func makeFrame(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: NSDictionary = [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                                        kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0 ..< CVPixelBufferGetPlaneCount(buffer) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                memset(base, 0x40, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// AUD, the HDR10 SEI, then slice data with no `00 00` in it (as after emulation prevention).
    static func keyFramePacket(sliceBytes: Int) -> [UInt8] {
        var rbsp: [UInt8] = [137, 24] + [UInt8](hdr10.masteringDisplay ?? Data()) + [144, 4]
            + [UInt8](hdr10.contentLightLevel ?? Data()) + [0x80]
        var sei: [UInt8] = [39 << 1, 1]
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 { sei.append(3); zeros = 0 }
            sei.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        rbsp.removeAll()
        let nals: [[UInt8]] = [[35 << 1, 1, 0x50], sei]
            + (0 ..< 4).map { i in [19 << 1, 1] + (0 ..< sliceBytes / 4).map { UInt8(0x11 &+ UInt8(truncatingIfNeeded: $0 &* 7 &+ i)) | 1 } }
        return nals.flatMap { nal in
            [UInt8(nal.count >> 24 & 0xFF), UInt8(nal.count >> 16 & 0xFF), UInt8(nal.count >> 8 & 0xFF),
             UInt8(nal.count & 0xFF)] + nal
        }
    }

    private static func deviceName() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
