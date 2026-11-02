// VTLowLatencySuperResolutionScaler is not in the simulator SDKs.
#if !targetEnvironment(simulator)
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
import MetalFX
import VideoToolbox

/// The per-frame upscale stage (#846): optional VT low-latency super resolution, then MetalFX Spatial to
/// the plan's target size. Synchronous; `upscale` returns nil whenever the caller should deliver the
/// original frame. A sustained overrun of an ML + MetalFX stage first drops MetalFX (ML output at its own
/// size); failures and any further overrun disable it for good, each logged once. A MetalFX overrun is
/// remembered for the process (`MetalFXCostMemory`), so a later stage at least as heavy and as fast starts
/// without MetalFX.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class FrameUpscaler: @unchecked Sendable {

    struct Stats: Equatable, Sendable {
        var framesUpscaled: Int
        var failures: Int
        var meanMs: Double
        var maxMs: Double
        /// Per-stage means over the last budget window.
        var stageMeanMs = StageTimes()
    }

    /// Wall-clock milliseconds of one frame's steps; `metalGPU` is the command buffer's GPU time.
    struct StageTimes: Equatable, Sendable {
        var copy = 0.0, ml = 0.0, clamp = 0.0, metal = 0.0, metalGPU = 0.0, attach = 0.0, total = 0.0

        static func mean(_ all: [StageTimes]) -> StageTimes {
            guard !all.isEmpty else { return StageTimes() }
            let n = Double(all.count)
            func avg(_ k: KeyPath<StageTimes, Double>) -> Double { all.reduce(0) { $0 + $1[keyPath: k] } / n }
            return StageTimes(copy: avg(\.copy), ml: avg(\.ml), clamp: avg(\.clamp), metal: avg(\.metal),
                              metalGPU: avg(\.metalGPU), attach: avg(\.attach), total: avg(\.total))
        }

        var breakdown: String {
            String(format: "copy %.1f, ml %.1f, clamp %.1f, metal %.1f wall / %.1f gpu, attach %.1f",
                   copy, ml, clamp, metal, metalGPU, attach)
        }

        func logLine(frames: Int, intervalMs: Double) -> String {
            String(format: "total %.1f ms (%@) over %d frames at %.1f ms interval", total, breakdown, frames, intervalMs)
        }
    }

    enum Event: Sendable {
        case firstFrame(UpscalePlan, degraded: Bool)
        /// The overrun ladder dropped MetalFX: frames now go out at the plan's (ML output) size.
        case degraded(UpscalePlan, reason: String, stats: Stats)
        case disabled(reason: String, stats: Stats)
    }

    static let budgetWindow = 48
    /// Timing lines logged per stage, one per budget window.
    static let timingLinesPerStage = 10
    static let budgetFraction = 0.75
    static let maxConsecutiveFailures = 3
    /// PTS deltas the live frame interval is the median of.
    static let intervalWindow = 8
    /// A gap longer than this is a seek or a stall, not a frame period.
    static let maxFrameDelta = 0.5

    /// Median of the last `intervalWindow` deltas, `configured` until that many exist. The deinterlacer
    /// doubles a field-rate source's frame rate, so the stream's declared rate is only a seed.
    static func liveInterval(deltas: [Double], configured: Double) -> Double {
        guard deltas.count >= intervalWindow else { return configured }
        let sorted = deltas.suffix(intervalWindow).sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Scale factors VT offers for a frame size, empty when the ML scaler is unsupported.
    static func mlScaleFactors(_ width: Int, _ height: Int) -> [Float] {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else { return [] }
        return VTLowLatencySuperResolutionScalerConfiguration
            .__supportedScaleFactors(forFrameWidth: width, frameHeight: height).map(\.floatValue)
    }

    var onEvent: (@Sendable (Event) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onEvent }
        set { stateLock.lock(); _onEvent = newValue; stateLock.unlock() }
    }

    var isDisabled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _isDisabled }

    /// Why the stage switched itself off, nil while it runs.
    var disabledReason: String? { stateLock.lock(); defer { stateLock.unlock() }; return _disabledReason }

    var stats: Stats { stateLock.lock(); defer { stateLock.unlock() }; return _stats }

    /// The plan of the last `.firstFrame` or `.degraded` event, nil before the first upscaled frame.
    var deliveredPlan: UpscalePlan? { stateLock.lock(); defer { stateLock.unlock() }; return _deliveredPlan }
    private var _deliveredPlan: UpscalePlan?

    /// `deliveredPlan` with whether it is the degraded (ML only) rung, read together.
    var delivered: (plan: UpscalePlan, degraded: Bool)? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _deliveredPlan.map { ($0, _isDegraded) }
    }

    /// True once the overrun ladder dropped MetalFX; a rebuild for another size stays ML only.
    var isDegraded: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _isDegraded }

    var plan: UpscalePlan { processLock.lock(); defer { processLock.unlock() }; return stage.plan }

    /// Timed-out ML passes whose buffers are still held back for a late completion.
    var abandonedMLPasses: Int { processLock.lock(); defer { processLock.unlock() }; return stage.abandonedMLPasses }

    /// Test seam: replaces `VTFrameProcessor.process` for the ML pass.
    var mlSubmitOverride: MLSubmit? {
        get { processLock.lock(); defer { processLock.unlock() }; return _mlSubmitOverride }
        set { processLock.lock(); _mlSubmitOverride = newValue; processLock.unlock() }
    }
    typealias MLSubmit = (VTLowLatencySuperResolutionScalerParameters, @escaping @Sendable (Error?) -> Void) -> Void
    private var _mlSubmitOverride: MLSubmit?

    private let configuredInterval: Double
    private var frameInterval: Double
    private var ptsDeltas: [Double] = []
    private var lastPTS: Double?
    private let gpu: GPU
    private var stage: Stage
    private var lastPassThroughNote: String?
    private var recentTimes: [StageTimes] = []
    private var degraded = false
    private var stageFrames = 0
    private var timingLines = 0
    private var totalMs = 0.0
    private var consecutiveFailures = 0
    private var firstFrameSent = false
    private var backgroundRefusalNoted = false
    private var rememberedOverrunNoted = false
    private var frameIndex: Int64 = 0
    private let processLock = NSLock()

    private let stateLock = NSLock()
    private var _onEvent: (@Sendable (Event) -> Void)?
    private var _isDisabled = false
    private var _disabledReason: String?
    private var _isDegraded = false
    private var _stats = Stats(framesUpscaled: 0, failures: 0, meanMs: 0, maxMs: 0)

    init?(plan: UpscalePlan, frameInterval: Double) {
        guard let gpu = GPU() else {
            EngineLog.emit("[Upscale] stage unavailable: no Metal device or kernels", category: .swPlayback)
            return nil
        }
        do {
            stage = try Stage(plan: plan, gpu: gpu)
        } catch {
            EngineLog.emit("[Upscale] stage unavailable: \(error)", category: .swPlayback)
            return nil
        }
        self.gpu = gpu
        self.configuredInterval = frameInterval
        self.frameInterval = frameInterval
    }

    /// The overrun budget per frame, from the live frame interval.
    var frameBudgetMs: Double {
        processLock.lock(); defer { processLock.unlock() }
        return Self.budgetFraction * frameInterval * 1000
    }

    /// How long one ML pass may take before the original frame goes out.
    var mlTimeout: Double {
        processLock.lock(); defer { processLock.unlock() }
        return currentMLTimeout
    }

    private var currentMLTimeout: Double { max(0.05, 3 * frameInterval) }

    func upscale(_ input: CVPixelBuffer, pts: CMTime) -> CVPixelBuffer? {
        processLock.lock()
        defer { processLock.unlock() }
        guard !isDisabled else { return nil }
        notePTS(pts)

        let format = CVPixelBufferGetPixelFormatType(input)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            notePassThrough("pixel format \(fourCC(format)) is not 8-bit 4:2:0")
            return nil
        }
        let picture = Self.pictureRegion(of: input)
        if picture.width != stage.plan.sourceWidth || picture.height != stage.plan.sourceHeight {
            guard rebuild(for: input, width: picture.width, height: picture.height) else { return nil }
        }
        applyRememberedOverrun()
        guard !isDisabled else { return nil }
        lastPassThroughNote = nil

        let start = DispatchTime.now().uptimeNanoseconds
        frameIndex += 1
        do {
            var times = StageTimes()
            let output = try stage.process(
                input, picture: picture, frameIndex: frameIndex,
                mlTimeout: currentMLTimeout, submit: _mlSubmitOverride, times: &times)
            times.total = elapsedMs(since: start)
            recordSuccess(times)
            return output
        } catch {
            recordFailure(error)
            return nil
        }
    }

    private func notePTS(_ pts: CMTime) {
        guard pts.isNumeric else { return }
        let seconds = pts.seconds
        defer { lastPTS = seconds }
        guard let last = lastPTS, seconds > last, seconds - last <= Self.maxFrameDelta else { return }
        ptsDeltas.append(seconds - last)
        if ptsDeltas.count > Self.intervalWindow { ptsDeltas.removeFirst() }
        frameInterval = Self.liveInterval(deltas: ptsDeltas, configured: configuredInterval)
    }

    // MARK: - Rebuild and pass-through

    private func rebuild(for input: CVPixelBuffer, width: Int, height: Int) -> Bool {
        guard width < 1920, height < 1080 else {
            notePassThrough("\(width)x\(height) is not below 1080p")
            return false
        }
        let sar = Self.pixelAspectRatio(of: input)
        let display = CGSize(width: stage.plan.displayWidth, height: stage.plan.displayHeight)
        guard let plan = UpscaleRouteDecision.makePlan(
                source: SourceGeometry(width: width, height: height, sarNum: sar.0, sarDen: sar.1),
                display: display, mlScaleFactors: Self.mlScaleFactors),
              plan.targetWidth > width || plan.targetHeight > height else {
            notePassThrough("\(width)x\(height) is not smaller than the display")
            return false
        }
        do {
            stage = try Stage(plan: plan, gpu: gpu, mlOnly: degraded && plan.mlScale != nil)
        } catch {
            disable(reason: "rebuild for \(width)x\(height) failed: \(error)")
            return false
        }
        // The next upscaled frame republishes the plan.
        firstFrameSent = false
        stageFrames = 0
        timingLines = 0
        let built = stage.plan
        EngineLog.emit("[Upscale] input size changed: \(width)x\(height) -> \(built.targetWidth)x\(built.targetHeight)"
                       + (built.mlScale.map { " (ML \(String(format: "%g", $0))x)" } ?? "")
                       + (degraded && !built.needsMetalFX ? ", ML only (degraded)" : ""), category: .swPlayback)
        return true
    }

    private func notePassThrough(_ note: String) {
        guard note != lastPassThroughNote else { return }
        lastPassThroughNote = note
        EngineLog.emit("[Upscale] passing frames through: \(note)", category: .swPlayback)
    }

    /// The clean aperture when the buffer carries one smaller than itself (cropped streams such as H.264
    /// coded 1280x736 shown 1280x720), else the whole buffer. The origin is kept even for 4:2:0 chroma.
    static func pictureRegion(of buffer: CVPixelBuffer) -> PictureRegion {
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        let whole = PictureRegion(x: 0, y: 0, width: bw, height: bh)
        guard let ap = CVBufferCopyAttachment(buffer, kCVImageBufferCleanApertureKey, nil) as? [String: Any],
              let aw = (ap[kCVImageBufferCleanApertureWidthKey as String] as? NSNumber)?.doubleValue,
              let ah = (ap[kCVImageBufferCleanApertureHeightKey as String] as? NSNumber)?.doubleValue
        else { return whole }
        let ho = (ap[kCVImageBufferCleanApertureHorizontalOffsetKey as String] as? NSNumber)?.doubleValue ?? 0
        let vo = (ap[kCVImageBufferCleanApertureVerticalOffsetKey as String] as? NSNumber)?.doubleValue ?? 0
        let w = min(bw, Int(aw.rounded(.down))), h = min(bh, Int(ah.rounded(.down)))
        guard w > 0, h > 0, w < bw || h < bh else { return whole }
        let x = min(max(0, Int(((Double(bw) - aw) / 2 + ho).rounded(.down))) & ~1, bw - w)
        let y = min(max(0, Int(((Double(bh) - ah) / 2 + vo).rounded(.down))) & ~1, bh - h)
        return PictureRegion(x: x, y: y, width: w, height: h)
    }

    struct PictureRegion: Equatable {
        var x: Int, y: Int, width: Int, height: Int
    }

    private static func pixelAspectRatio(of buffer: CVPixelBuffer) -> (Int, Int) {
        guard let par = CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any],
              let h = (par[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber)?.intValue,
              let v = (par[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber)?.intValue
        else { return (1, 1) }
        return (h, v)
    }

    // MARK: - Accounting

    /// A command buffer refused because the app is in the background (iOS): not a fault of the stage.
    static func isBackgroundRefusal(_ error: Error) -> Bool {
        if let wrapped = error as? UpscaleError, let underlying = wrapped.underlying {
            return isBackgroundRefusal(underlying)
        }
        let ns = error as NSError
        return ns.domain == MTLCommandBufferErrorDomain && ns.code == Int(MTLCommandBufferError.Code.notPermitted.rawValue)
    }

    private func recordSuccess(_ times: StageTimes) {
        consecutiveFailures = 0
        backgroundRefusalNoted = false
        totalMs += times.total
        recentTimes.append(times)
        if recentTimes.count > Self.budgetWindow { recentTimes.removeFirst() }
        let windowMean = StageTimes.mean(recentTimes)
        stateLock.lock()
        _stats.framesUpscaled += 1
        _stats.meanMs = totalMs / Double(_stats.framesUpscaled)
        _stats.maxMs = max(_stats.maxMs, times.total)
        _stats.stageMeanMs = windowMean
        let handler = _onEvent
        stateLock.unlock()

        if !firstFrameSent {
            firstFrameSent = true
            stateLock.lock()
            _deliveredPlan = stage.plan
            stateLock.unlock()
            handler?(.firstFrame(stage.plan, degraded: degraded))
        }
        stageFrames += 1
        if stageFrames % Self.budgetWindow == 0, timingLines < Self.timingLinesPerStage {
            timingLines += 1
            EngineLog.emit("[Upscale] timing: " + windowMean.logLine(frames: recentTimes.count, intervalMs: frameInterval * 1000),
                           category: .swPlayback)
        }
        let budgetMs = Self.budgetFraction * frameInterval * 1000
        if recentTimes.count == Self.budgetWindow, windowMean.total > budgetMs {
            let over = String(format: "%.2f ms mean over %d frames against %.2f ms",
                              windowMean.total, Self.budgetWindow, budgetMs)
            if !degraded, stage.plan.mlScale != nil, stage.plan.needsMetalFX {
                degrade(over: over, window: windowMean)
            } else {
                disable(reason: "over budget, " + over)
            }
        }
    }

    /// The first rung of the overrun ladder: keep ML, drop MetalFX, start a fresh budget window.
    private func degrade(over: String, window: StageTimes) {
        let full = stage.plan
        guard let plan = stage.dropMetalFX() else {
            disable(reason: "over budget, " + over)
            return
        }
        MetalFXCostMemory.record(MetalFXCostMemory.Overrun(
            width: full.targetWidth, height: full.targetHeight, frameInterval: frameInterval, meanMs: window.total))
        EngineLog.emit("[Upscale] degraded: over budget (\(over)), dropping MetalFX, ML only to "
                       + "\(plan.targetWidth)x\(plan.targetHeight) (\(window.breakdown))", category: .swPlayback)
        enterDegraded(plan, reason: "over budget, " + over)
    }

    private func enterDegraded(_ plan: UpscalePlan, reason: String) {
        degraded = true
        recentTimes.removeAll()
        stageFrames = 0
        timingLines = 0
        stateLock.lock()
        _isDegraded = true
        _deliveredPlan = plan
        let stats = _stats
        let handler = _onEvent
        stateLock.unlock()
        handler?(.degraded(plan, reason: reason, stats: stats))
    }

    /// A MetalFX stage that an earlier overrun in this process covers drops MetalFX before running, or
    /// switches off when it has no ML pass to keep.
    private func applyRememberedOverrun() {
        guard !degraded, stage.plan.needsMetalFX,
              let overrun = MetalFXCostMemory.overrun(covering: stage.plan, frameInterval: frameInterval) else { return }
        let full = stage.plan
        let size = "\(full.targetWidth)x\(full.targetHeight)"
        guard full.mlScale != nil, let plan = stage.dropMetalFX() else {
            disable(reason: "MetalFX too slow on this device at \(size)")
            return
        }
        let reason = String(format: "MetalFX to %@ overran on this device earlier (%.1f ms at %.1f ms)",
                            size, overrun.meanMs, overrun.frameInterval * 1000)
        if !rememberedOverrunNoted {
            rememberedOverrunNoted = true
            EngineLog.emit("[Upscale] starting ML only: " + reason, category: .swPlayback)
        }
        enterDegraded(plan, reason: reason)
    }

    private func recordFailure(_ error: Error) {
        if Self.isBackgroundRefusal(error) {
            if !backgroundRefusalNoted {
                backgroundRefusalNoted = true
                EngineLog.emit("[Upscale] GPU work not permitted in the background, passing frames through",
                               category: .swPlayback)
            }
            return
        }
        consecutiveFailures += 1
        stateLock.lock()
        _stats.failures += 1
        stateLock.unlock()
        if let timeout = error as? MLTimeout, timeout.outstanding > MLScaler.maxAbandoned {
            disable(reason: "too many ML timeouts, \(timeout.outstanding) passes never completed")
            return
        }
        if consecutiveFailures >= Self.maxConsecutiveFailures {
            disable(reason: "\(consecutiveFailures) consecutive failures, last: \(error)")
        }
    }

    private func disable(reason: String) {
        stateLock.lock()
        guard !_isDisabled else { stateLock.unlock(); return }
        _isDisabled = true
        _disabledReason = reason
        let stats = _stats
        let handler = _onEvent
        stateLock.unlock()
        EngineLog.emit(String(format: "[Upscale] disabled: %@ (frames %d, failures %d, mean %.2f ms, max %.2f ms)",
                              reason, stats.framesUpscaled, stats.failures, stats.meanMs, stats.maxMs)
                       + (stats.framesUpscaled > 0 ? " (\(stats.stageMeanMs.breakdown))" : ""),
                       category: .swPlayback)
        handler?(.disabled(reason: reason, stats: stats))
        stage.release()
    }
}

// MARK: - Process-wide MetalFX cost

/// MetalFX overruns seen in this process: a stage whose MetalFX output is at least as large as a recorded
/// one, at a frame interval no longer, would overrun again, so it starts without MetalFX.
enum MetalFXCostMemory {
    struct Overrun: Equatable, Sendable {
        var width: Int, height: Int
        var frameInterval: Double
        var meanMs: Double
        var pixels: Int { width * height }

        /// 1% slack, so 24 fps counts as at least as fast as 23.976.
        func covers(pixels other: Int, frameInterval interval: Double) -> Bool {
            other >= pixels && interval <= frameInterval * 1.01
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var overruns: [Overrun] = []

    static func record(_ overrun: Overrun) {
        lock.lock(); defer { lock.unlock() }
        guard !overruns.contains(where: { $0.pixels <= overrun.pixels && $0.frameInterval >= overrun.frameInterval })
        else { return }
        overruns.removeAll { $0.pixels >= overrun.pixels && $0.frameInterval <= overrun.frameInterval }
        overruns.append(overrun)
    }

    static func overrun(covering plan: UpscalePlan, frameInterval: Double) -> Overrun? {
        lock.lock(); defer { lock.unlock() }
        return overruns.first { $0.covers(pixels: plan.targetWidth * plan.targetHeight, frameInterval: frameInterval) }
    }

    static func reset() {
        lock.lock(); overruns.removeAll(); lock.unlock()
    }
}

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
extension FrameUpscaler {
    static func resetMetalFXCostMemoryForTesting() { MetalFXCostMemory.reset() }
}

// MARK: - GPU state shared across rebuilds

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private struct UpscaleError: Error, CustomStringConvertible {
    let description: String
    let underlying: Error?
    init(_ description: String, underlying: Error? = nil) {
        self.description = description
        self.underlying = underlying
    }
}

/// The colour kernels, compiled once per process and device rather than per stage.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class UpscaleKernels: @unchecked Sendable {
    let toRGBA: MTLComputePipelineState
    let toNV12: MTLComputePipelineState

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byDevice: [UInt64: UpscaleKernels] = [:]

    private init(toRGBA: MTLComputePipelineState, toNV12: MTLComputePipelineState) {
        self.toRGBA = toRGBA
        self.toNV12 = toNV12
    }

    static func shared(for device: MTLDevice) -> UpscaleKernels? {
        lock.lock(); defer { lock.unlock() }
        if let kernels = byDevice[device.registryID] { return kernels }
        guard let library = try? device.makeLibrary(source: UpscaleShaderSource.source, options: nil),
              let f1 = library.makeFunction(name: "nv12ToRGBA"), let f2 = library.makeFunction(name: "rgbaToNV12"),
              let toRGBA = try? device.makeComputePipelineState(function: f1),
              let toNV12 = try? device.makeComputePipelineState(function: f2)
        else { return nil }
        let kernels = UpscaleKernels(toRGBA: toRGBA, toNV12: toNV12)
        byDevice[device.registryID] = kernels
        return kernels
    }
}

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private final class GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let toRGBA: MTLComputePipelineState
    let toNV12: MTLComputePipelineState
    let textureCache: CVMetalTextureCache

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let kernels = UpscaleKernels.shared(for: device)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.toRGBA = kernels.toRGBA
        self.toNV12 = kernels.toNV12
        self.textureCache = cache
    }

    func planeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture) {
        var ref: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane), h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, format, w, h, plane, &ref) == kCVReturnSuccess,
              let ref, let texture = CVMetalTextureGetTexture(ref)
        else { throw UpscaleError("no Metal texture for plane \(plane)") }
        return (texture, ref)
    }

    func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                  textures: [MTLTexture], color: UpscaleColorParams, grid: (Int, Int)) {
        encoder.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
        var params = color
        encoder.setBytes(&params, length: MemoryLayout<UpscaleColorParams>.size, index: 0)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: grid.0, height: grid.1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}

// MARK: - One plan's processing chain

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private final class Stage {
    private(set) var plan: UpscalePlan
    private let gpu: GPU
    private let ml: MLScaler?
    /// The MetalFX spatial scaler, held untyped because the tvOS SDK has it only from 27.1.
    private var scaler: AnyObject?
    private var rgba: MTLTexture?
    private var scaled: MTLTexture?
    /// Set on the ML-only rung: the output is the coded picture times the ML factor, not square.
    private var sourcePAR: (Int, Int)?
    private var outputPools: [OSType: CVPixelBufferPool] = [:]
    private var cropPools: [OSType: CVPixelBufferPool] = [:]

    static let droppedAttachmentKeys: Set<String> = [
        kCVImageBufferCleanApertureKey as String, kCVImageBufferPreferredCleanApertureKey as String,
        kCVImageBufferFieldCountKey as String, kCVImageBufferFieldDetailKey as String,
        kCVImageBufferDisplayDimensionsKey as String,
    ]

    /// `mlOnly` builds the degraded rung of `plan`: its ML pass, delivered at the ML output size.
    init(plan: UpscalePlan, gpu: GPU, mlOnly: Bool = false) throws {
        self.plan = plan
        self.gpu = gpu
        ml = try plan.mlScale.map { try MLScaler(width: plan.sourceWidth, height: plan.sourceHeight, scale: $0) }
        if mlOnly, let ml {
            self.plan = Self.mlOnlyPlan(plan, ml: ml)
            sourcePAR = Self.pixelAspect(of: plan)
            scaler = nil; rgba = nil; scaled = nil
            return
        }

        let inW = ml?.outputWidth ?? plan.sourceWidth
        let inH = ml?.outputHeight ?? plan.sourceHeight
        guard inW != plan.targetWidth || inH != plan.targetHeight else {
            guard ml != nil else { throw UpscaleError("plan scales nothing") }
            scaler = nil; rgba = nil; scaled = nil
            return
        }
        guard #available(tvOS 27.1, *), MTLFXSpatialScalerDescriptor.supportsDevice(gpu.device) else {
            throw UpscaleError("MetalFX spatial scaling unsupported")
        }
        let d = MTLFXSpatialScalerDescriptor()
        d.colorTextureFormat = .rgba8Unorm
        d.outputTextureFormat = .rgba8Unorm
        d.inputWidth = inW
        d.inputHeight = inH
        d.outputWidth = plan.targetWidth
        d.outputHeight = plan.targetHeight
        d.colorProcessingMode = .perceptual
        guard let scaler = d.makeSpatialScaler(device: gpu.device) else {
            throw UpscaleError("MetalFX scaler \(inW)x\(inH) -> \(plan.targetWidth)x\(plan.targetHeight) not built")
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: inW, height: inH, mipmapped: false)
        td.usage = scaler.colorTextureUsage.union(.shaderWrite)
        td.storageMode = .private
        let od = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: plan.targetWidth, height: plan.targetHeight, mipmapped: false)
        od.usage = scaler.outputTextureUsage.union(.shaderRead)
        od.storageMode = .private
        guard let rgba = gpu.device.makeTexture(descriptor: td), let scaled = gpu.device.makeTexture(descriptor: od) else {
            throw UpscaleError("intermediate textures not allocated")
        }
        scaler.colorTexture = rgba
        scaler.outputTexture = scaled
        scaler.inputContentWidth = inW
        scaler.inputContentHeight = inH
        self.scaler = scaler
        self.rgba = rgba
        self.scaled = scaled
    }

    deinit { release() }

    func release() { ml?.end() }

    var abandonedMLPasses: Int { ml?.abandonedCount ?? 0 }

    /// Switches this stage to its ML-only rung between two frames; nil when it has no ML or no MetalFX.
    func dropMetalFX() -> UpscalePlan? {
        guard let ml, scaler != nil else { return nil }
        sourcePAR = Self.pixelAspect(of: plan)
        plan = Self.mlOnlyPlan(plan, ml: ml)
        scaler = nil; rgba = nil; scaled = nil
        outputPools.removeAll()
        return plan
    }

    private static func mlOnlyPlan(_ plan: UpscalePlan, ml: MLScaler) -> UpscalePlan {
        var p = plan
        p.mlOutputWidth = ml.outputWidth
        p.mlOutputHeight = ml.outputHeight
        p.targetWidth = ml.outputWidth
        p.targetHeight = ml.outputHeight
        return p
    }

    /// The pixel aspect the full plan's target implies for the coded source (8:9 for 720x480 -> 2880x2160).
    private static func pixelAspect(of plan: UpscalePlan) -> (Int, Int) {
        let num = plan.targetWidth * plan.sourceHeight, den = plan.targetHeight * plan.sourceWidth
        guard num > 0, den > 0 else { return (1, 1) }
        var a = num, b = den
        while b != 0 { (a, b) = (b, a % b) }
        return (num / a, den / a)
    }

    func process(_ original: CVPixelBuffer, picture: FrameUpscaler.PictureRegion, frameIndex: Int64,
                 mlTimeout: Double, submit: FrameUpscaler.MLSubmit?,
                 times: inout FrameUpscaler.StageTimes) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(original)
        let color = UpscaleColorParams(videoRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       matrix: UpscaleMatrix.of(original))
        let input: CVPixelBuffer
        if picture.width == CVPixelBufferGetWidth(original) && picture.height == CVPixelBufferGetHeight(original) {
            input = original
        } else {
            let t0 = DispatchTime.now().uptimeNanoseconds
            if cropPools[format] == nil {
                cropPools[format] = try makePool(width: picture.width, height: picture.height, format: format)
            }
            input = try pooledBuffer(cropPools[format]!)
            try copyPlanes(from: original, to: input, origin: (picture.x, picture.y))
            times.copy += elapsedMs(since: t0)
        }
        let mlOut = try ml?.process(input, frameIndex: frameIndex, timeout: mlTimeout, submit: submit, times: &times)
        let output: CVPixelBuffer

        if #available(tvOS 27.1, *), let scaler = scaler as? any MTLFXSpatialScaler, let rgba, let scaled {
            let t0 = DispatchTime.now().uptimeNanoseconds
            output = try makeOutput(format: format, width: plan.targetWidth, height: plan.targetHeight)
            let source = mlOut ?? input
            // The ML pass carries sample values through unchanged, so its output keeps the input's range.
            let sy = try gpu.planeTexture(source, plane: 0, format: .r8Unorm)
            let sc = try gpu.planeTexture(source, plane: 1, format: .rg8Unorm)
            let oy = try gpu.planeTexture(output, plane: 0, format: .r8Unorm)
            let oc = try gpu.planeTexture(output, plane: 1, format: .rg8Unorm)
            guard let cb = gpu.queue.makeCommandBuffer() else { throw UpscaleError("no command buffer") }
            guard let enc = cb.makeComputeCommandEncoder() else { throw UpscaleError("no encoder") }
            gpu.dispatch(enc, gpu.toRGBA, textures: [sy.0, sc.0, rgba], color: color,
                         grid: (rgba.width, rgba.height))
            enc.endEncoding()
            scaler.encode(commandBuffer: cb)
            guard let enc2 = cb.makeComputeCommandEncoder() else { throw UpscaleError("no encoder") }
            gpu.dispatch(enc2, gpu.toNV12, textures: [scaled, oy.0, oc.0], color: color,
                         grid: (scaled.width / 2, scaled.height / 2))
            enc2.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            withExtendedLifetime((sy.1, sc.1, oy.1, oc.1)) {}
            CVMetalTextureCacheFlush(gpu.textureCache, 0)
            times.metal = elapsedMs(since: t0)
            times.metalGPU = max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            guard cb.status == .completed else {
                throw UpscaleError("command buffer \(cb.status.rawValue): \(cb.error.map { "\($0)" } ?? "no error")",
                                   underlying: cb.error)
            }
        } else if let mlOut {
            if CVPixelBufferGetPixelFormatType(mlOut) == format {
                output = mlOut
            } else {
                let t0 = DispatchTime.now().uptimeNanoseconds
                output = try makeOutput(format: format, width: CVPixelBufferGetWidth(mlOut), height: CVPixelBufferGetHeight(mlOut))
                try copyPlanes(from: mlOut, to: output)
                times.copy += elapsedMs(since: t0)
            }
        } else {
            throw UpscaleError("plan has no stage")
        }

        let t0 = DispatchTime.now().uptimeNanoseconds
        CVBufferRemoveAllAttachments(output)
        if let attachments = CVBufferCopyAttachments(original, .shouldPropagate) as? [String: Any] {
            // Geometry and field keys describe the input buffer, not this one.
            let carried = attachments.filter { !Self.droppedAttachmentKeys.contains($0.key) }
            CVBufferSetAttachments(output, carried as CFDictionary, .shouldPropagate)
        }
        if let sourcePAR {
            // The ML-only rung keeps the source's pixel shape: the decoder's tag, else the plan's.
            let par = CVBufferCopyAttachment(original, kCVImageBufferPixelAspectRatioKey, nil)
                ?? ([kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: sourcePAR.0,
                     kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: sourcePAR.1] as CFDictionary)
            CVBufferSetAttachment(output, kCVImageBufferPixelAspectRatioKey, par, .shouldPropagate)
        } else {
            let square: [String: Int] = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: 1,
                                         kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 1]
            CVBufferSetAttachment(output, kCVImageBufferPixelAspectRatioKey, square as CFDictionary, .shouldPropagate)
        }
        times.attach = elapsedMs(since: t0)
        return output
    }

    private func makeOutput(format: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
        if outputPools[format] == nil {
            outputPools[format] = try makePool(width: width, height: height, format: format)
        }
        return try pooledBuffer(outputPools[format]!)
    }
}

// MARK: - VT low-latency super resolution

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private final class MLScaler {
    let outputWidth: Int
    let outputHeight: Int
    private let processor = VTFrameProcessor()
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private let sourceFormat: OSType
    private var copiesInput = false
    private var ended = false
    private let abandoned = AbandonedPasses()

    /// Outstanding timed-out passes past which the stage disables itself.
    static let maxAbandoned = 8
    var abandonedCount: Int { abandoned.count }

    init(width: Int, height: Int, scale: Float) throws {
        let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: scale)
        let src = config.sourcePixelBufferAttributes
        let dst = config.destinationPixelBufferAttributes
        outputWidth = (dst[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? Int((Float(width) * scale).rounded())
        outputHeight = (dst[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? Int((Float(height) * scale).rounded())
        sourceFormat = (src[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
            ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sourcePool = try makePool(attributes: src, width: width, height: height)
        destinationPool = try makePool(attributes: dst, width: outputWidth, height: outputHeight)
        try processor.startSession(configuration: config)
    }

    deinit { end() }

    /// Off the decode thread: after timed-out passes VT may be wedged, and nothing waits for the session to end.
    func end() {
        guard !ended else { return }
        ended = true
        let processor = UncheckedSendable(processor)
        DispatchQueue.global(qos: .utility).async { processor.value.endSession() }
    }

    func process(_ input: CVPixelBuffer, frameIndex: Int64, timeout: Double,
                 submit: FrameUpscaler.MLSubmit?, times: inout FrameUpscaler.StageTimes) throws -> CVPixelBuffer {
        if !copiesInput, CVPixelBufferGetPixelFormatType(input) == sourceFormat, CVPixelBufferGetIOSurface(input) != nil {
            do {
                return try run(input, frameIndex: frameIndex, timeout: timeout, submit: submit, times: &times)
            } catch let error as MLTimeout {
                throw error
            } catch where FrameUpscaler.isBackgroundRefusal(error) {
                throw error
            } catch {
                copiesInput = true
                EngineLog.emit("[Upscale] ML scaler refused the decoder buffer (\(error)), copying input from now on",
                               category: .swPlayback)
            }
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let copy = try pooledBuffer(sourcePool)
        try copyPlanes(from: input, to: copy)
        times.copy += elapsedMs(since: t0)
        return try run(copy, frameIndex: frameIndex, timeout: timeout, submit: submit, times: &times)
    }

    private func run(_ source: CVPixelBuffer, frameIndex: Int64, timeout: Double,
                     submit: FrameUpscaler.MLSubmit?, times: inout FrameUpscaler.StageTimes) throws -> CVPixelBuffer {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var mlTimed = false
        defer { if !mlTimed { times.ml += elapsedMs(since: t0) } }
        let destination = try pooledBuffer(destinationPool)
        let pts = CMTime(value: frameIndex, timescale: 600)
        guard let sf = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
              let df = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: pts)
        else { throw UpscaleError("VTFrameProcessorFrame refused a buffer") }
        let params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sf, destinationFrame: df)
        let done = Completion()
        if let submit {
            submit(params) { done.finish($0) }
        } else {
            processor.process(parameters: params) { _, error in done.finish(error) }
        }
        guard let result = done.wait(timeout: timeout) else {
            // VT may still write these later: keep them out of the pools until it calls back.
            let abandoned = abandoned
            let id = abandoned.insert(source, destination)
            if !done.abandon(onLateFinish: { abandoned.remove(id) }) { abandoned.remove(id) }
            throw MLTimeout(seconds: timeout, outstanding: abandoned.count)
        }
        if let error = result { throw error }
        times.ml += elapsedMs(since: t0)
        mlTimed = true
        let t1 = DispatchTime.now().uptimeNanoseconds
        try clampBorder(destination, luma: mlBorderClamp)
        times.clamp = elapsedMs(since: t1)
        return destination
    }
}

/// VT super resolution rings at the frame edge (measured up to 39 code values), so this many outer luma
/// samples are replaced by the nearest clean row or column.
let mlBorderClamp = 12

/// Replicates row/column `luma` (and `luma / 2` in chroma) over the outer band on all four sides.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private func clampBorder(_ buffer: CVPixelBuffer, luma k: Int) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<2 {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
            throw UpscaleError("plane \(plane) has no base address")
        }
        let band = plane == 0 ? k : k / 2
        let bytes = plane == 0 ? 1 : 2
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane), h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        guard band > 0, w > 2 * band, h > 2 * band else { continue }
        let rowBytes = w * bytes
        for row in 0..<band {
            memcpy(base + row * stride, base + band * stride, rowBytes)
            memcpy(base + (h - 1 - row) * stride, base + (h - 1 - band) * stride, rowBytes)
        }
        for row in 0..<h {
            let line = base + row * stride
            for x in 0..<band {
                memcpy(line + x * bytes, line + band * bytes, bytes)
                memcpy(line + (w - 1 - x) * bytes, line + (w - 1 - band) * bytes, bytes)
            }
        }
    }
}

private func elapsedMs(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private final class Completion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var error: Error?
    private var finished = false
    private var onLateFinish: (@Sendable () -> Void)?
    func finish(_ error: Error?) {
        lock.lock()
        self.error = error
        finished = true
        let late = onLateFinish
        onLateFinish = nil
        lock.unlock()
        semaphore.signal()
        late?()
    }
    /// After a timed-out wait: `onLateFinish` runs when the pass completes. False when it already has.
    func abandon(onLateFinish: @escaping @Sendable () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        self.onLateFinish = onLateFinish
        return true
    }
    /// nil on timeout, else `.some(error)`.
    func wait(timeout: Double) -> Error?? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return .some(error)
    }
}

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private final class AbandonedPasses: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var buffers: [Int: (CVPixelBuffer, CVPixelBuffer)] = [:]
    var count: Int { lock.lock(); defer { lock.unlock() }; return buffers.count }
    func insert(_ source: CVPixelBuffer, _ destination: CVPixelBuffer) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        buffers[nextID] = (source, destination)
        return nextID
    }
    func remove(_ id: Int) { lock.lock(); buffers[id] = nil; lock.unlock() }
}

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private struct MLTimeout: Error, CustomStringConvertible {
    let seconds: Double
    let outstanding: Int
    var description: String { String(format: "ML pass did not complete within %.0f ms", seconds * 1000) }
}

// MARK: - Buffers

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private func makePool(width: Int, height: Int, format: OSType) throws -> CVPixelBufferPool {
    try makePool(attributes: [kCVPixelBufferPixelFormatTypeKey as String: format], width: width, height: height)
}

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private func makePool(attributes: [String: Any], width: Int, height: Int) throws -> CVPixelBufferPool {
    var attrs = attributes
    attrs[kCVPixelBufferWidthKey as String] = width
    attrs[kCVPixelBufferHeightKey as String] = height
    attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
    if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
        attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
    }
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
        attrs as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw UpscaleError("pixel buffer pool \(width)x\(height): \(status)") }
    return pool
}

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private func pooledBuffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw UpscaleError("pool buffer: \(status)") }
    return buffer
}

/// Plane-by-plane copy of `dst`'s size from `src` at `origin` (even), 8-bit bi-planar; the values carry over as is.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private func copyPlanes(from src: CVPixelBuffer, to dst: CVPixelBuffer, origin: (x: Int, y: Int) = (0, 0)) throws {
    guard origin.x % 2 == 0, origin.y % 2 == 0,
          CVPixelBufferGetWidth(src) >= origin.x + CVPixelBufferGetWidth(dst),
          CVPixelBufferGetHeight(src) >= origin.y + CVPixelBufferGetHeight(dst),
          CVPixelBufferGetPlaneCount(src) == 2, CVPixelBufferGetPlaneCount(dst) == 2
    else { throw UpscaleError("plane copy between mismatched buffers") }
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
    for plane in 0..<2 {
        guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane),
              let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane)
        else { throw UpscaleError("plane \(plane) has no base address") }
        let sStride = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
        let dStride = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
        let shift = plane == 0 ? 0 : 1
        let rowBytes = CVPixelBufferGetWidthOfPlane(dst, plane) * (plane == 0 ? 1 : 2)
        let from = s + (origin.y >> shift) * sStride + (origin.x >> shift) * (plane == 0 ? 1 : 2)
        for row in 0..<CVPixelBufferGetHeightOfPlane(dst, plane) {
            memcpy(d + row * dStride, from + row * sStride, rowBytes)
        }
    }
}

private func fourCC(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(code)
}
#endif
