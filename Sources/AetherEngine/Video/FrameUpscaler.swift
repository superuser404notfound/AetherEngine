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
/// without MetalFX. Built on `buildQueue` when one is given: starting the VT session loads the model on the
/// Neural Engine through a synchronous XPC (~4 s cold on Apple TV), so frames pass through until it is ready.
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
        var copy = 0.0, ml = 0.0, edge = 0.0, metal = 0.0, metalGPU = 0.0, attach = 0.0, total = 0.0

        static func mean(_ all: [StageTimes]) -> StageTimes {
            guard !all.isEmpty else { return StageTimes() }
            let n = Double(all.count)
            func avg(_ k: KeyPath<StageTimes, Double>) -> Double { all.reduce(0) { $0 + $1[keyPath: k] } / n }
            return StageTimes(copy: avg(\.copy), ml: avg(\.ml), edge: avg(\.edge), metal: avg(\.metal),
                              metalGPU: avg(\.metalGPU), attach: avg(\.attach), total: avg(\.total))
        }

        var breakdown: String {
            String(format: "copy %.1f, ml %.1f, edge %.1f, metal %.1f wall / %.1f gpu, attach %.1f",
                   copy, ml, edge, metal, metalGPU, attach)
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
    /// The GPU lowers its clock until a regular load fills most of the frame interval (measured on an A15:
    /// work that takes 8.6 ms back to back reads 20.4 ms at 24 fps, 14.3 ms reads 31.7 ms, everything reads
    /// about 15.6 ms at 60 fps), so a stricter fraction trips on the clock, not on a stage that falls behind.
    static let budgetFraction = 0.9
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
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported, !MLRefusalMemory.refused else { return [] }
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

    var plan: UpscalePlan { processLock.lock(); defer { processLock.unlock() }; return stage?.plan ?? initialPlan }

    /// Timed-out ML passes whose buffers are still held back for a late completion.
    var abandonedMLPasses: Int { processLock.lock(); defer { processLock.unlock() }; return stage?.abandonedMLPasses ?? 0 }

    /// Test seam: replaces `VTFrameProcessor.process` for the ML pass.
    var mlSubmitOverride: MLSubmit? {
        get { processLock.lock(); defer { processLock.unlock() }; return _mlSubmitOverride }
        set { processLock.lock(); _mlSubmitOverride = newValue; processLock.unlock() }
    }
    typealias MLSubmit = (VTLowLatencySuperResolutionScalerParameters, @escaping @Sendable (Error?) -> Void) -> Void
    private var _mlSubmitOverride: MLSubmit?

    private let configuredInterval: Double
    private var frameInterval: Double
    /// The last `intervalWindow + 1` distinct PTS, in arrival order.
    private var recentPTS: [Double] = []
    private let gpu: GPU
    private let initialPlan: UpscalePlan
    private let buildQueue: DispatchQueue?
    /// The scaler the stage runs now: the plan's, until a line-art overrun falls back to `.automatic`.
    private var scaler: UpscaleScaler
    /// The last frame's sample depth; the automatic route takes 8-bit only.
    private var lastInputEightBit = true
    /// Whether the line-art stage runs its restore pass: the top rung, dropped first on an overrun.
    private var lineArtRestores = true

    /// True while a `.lineArt` stage runs its restore pass and highlight clamp.
    var runsLineArtRestore: Bool { processLock.lock(); defer { processLock.unlock() }; return lineArtRestores }
    /// nil while `buildQueue` builds it.
    private var stage: Stage?
    private var lastPassThroughNote: String?
    private var recentTimes: [StageTimes] = []
    private var degraded = false
    private var stageFrames = 0
    private var timingLines = 0
    private var totalMs = 0.0
    private var consecutiveFailures = 0
    /// True once a frame went through an ML pass on this upscaler.
    private var mlPassSucceeded = false
    private var firstFrameSent = false
    private var backgroundRefusalNoted = false
    private var rememberedOverrunNoted = false
    private var frameIndex: Int64 = 0
    private let processLock = NSLock()
    /// AE#957: what pipelined frames reported on completion, recorded at the next `begin`. `begin` holds
    /// `processLock` through the ML pass, so a completion that took it would wait for the next frame's
    /// pass before its frame could go out.
    private let completionLock = NSLock()
    private var completions: [Completion] = []
    private struct Completion {
        let stage: Stage
        let times: StageTimes
        let error: Error?
    }

    private let stateLock = NSLock()
    private var _onEvent: (@Sendable (Event) -> Void)?
    private var _isDisabled = false
    private var _disabledReason: String?
    private var _isDegraded = false
    private var _stats = Stats(framesUpscaled: 0, failures: 0, meanMs: 0, maxMs: 0)

    /// The queue the host builds its stages on, off the main actor.
    static let stageBuildQueue = DispatchQueue(label: "AetherEngine.FrameUpscaler.build", qos: .userInitiated)

    /// Without `buildQueue` the stage is built here and a failure returns nil; with it, a failure disables.
    init?(plan: UpscalePlan, frameInterval: Double, buildQueue: DispatchQueue? = nil) {
        guard let gpu = GPU() else {
            EngineLog.emit("[Upscale] stage unavailable: no Metal device or kernels", category: .swPlayback)
            return nil
        }
        self.gpu = gpu
        self.initialPlan = plan
        self.buildQueue = buildQueue
        self.scaler = plan.scaler
        self.configuredInterval = frameInterval
        self.frameInterval = frameInterval
        // Without MetalFX (tvOS before 27.1, or a GPU without it) the ML pass alone is the next best:
        // its output goes out at its own size and the display scales the rest.
        let mlOnly = Self.startsMLOnly(plan, metalFXAvailable: gpu.metalFXAvailable)
        if plan.scaler == .lineArt,
           let overrun = LineArtCostMemory.overrun(covering: plan, frameInterval: frameInterval, rung: .restore) {
            lineArtRestores = false
            EngineLog.emit(String(format: "[Upscale] line art without restore: it overran on this device earlier "
                                  + "(%.1f ms at %.1f ms)", overrun.meanMs, overrun.frameInterval * 1000),
                           category: .swPlayback)
        }
        let restores = lineArtRestores
        if mlOnly {
            degraded = true
            _isDegraded = true
            EngineLog.emit("[Upscale] MetalFX unavailable on this device, starting ML only", category: .swPlayback)
        }
        guard let buildQueue else {
            do {
                stage = try Stage(plan: plan, gpu: gpu, mlOnly: mlOnly, restores: restores)
            } catch {
                EngineLog.emit("[Upscale] stage unavailable: \(error)", category: .swPlayback)
                return nil
            }
            return
        }
        buildAsync(plan, mlOnly: mlOnly, restores: restores, on: buildQueue, generation: 0)
    }

    /// An `.automatic` plan that needs MetalFX starts on its ML-only rung when MetalFX is not there.
    static func startsMLOnly(_ plan: UpscalePlan, metalFXAvailable: Bool) -> Bool {
        plan.scaler == .automatic && plan.needsMetalFX && plan.mlScale != nil && !metalFXAvailable
    }

    /// Bumped by every switch of stage, so a build that finishes after a newer one was started is dropped.
    private var buildGeneration = 0

    private func buildAsync(_ plan: UpscalePlan, mlOnly: Bool, restores: Bool = true, on queue: DispatchQueue,
                            generation: Int) {
        let gpuBox = UncheckedSendable(gpu)
        queue.async { [weak self] in
            let start = DispatchTime.now().uptimeNanoseconds
            let built = Result {
                UncheckedSendable(try Stage(plan: plan, gpu: gpuBox.value, mlOnly: mlOnly, restores: restores))
            }
            self?.install(built, ms: elapsedMs(since: start), generation: generation)
        }
    }

    private func install(_ built: Result<UncheckedSendable<Stage>, Error>, ms: Double, generation: Int) {
        processLock.lock()
        defer { processLock.unlock() }
        guard generation == buildGeneration else {
            if case let .success(box) = built { box.value.release() }
            return
        }
        switch built {
        case let .success(box):
            guard !isDisabled else { box.value.release(); return }
            stage = box.value
            EngineLog.emit(String(format: "[Upscale] stage built in %.0f ms", ms), category: .swPlayback)
        case let .failure(error):
            disable(reason: "stage not built: \(error)")
        }
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

    /// One frame, start to finish on the calling thread: nil delivers the original frame. The tests and
    /// the benchmark use it; playback goes through `begin` and a `PipelinedFrameStage`.
    func upscale(_ input: CVPixelBuffer, pts: CMTime) -> CVPixelBuffer? {
        let start = DispatchTime.now().uptimeNanoseconds
        var begun = begin(input, pts: pts)
        if case let .later(startStep) = begun {
            let resumed = SyncBox<PipelinedFrameStage.Begun>()
            startStep { resumed.put($0) }
            begun = resumed.take()
        }
        let output: CVPixelBuffer?
        switch begun {
        case .passThrough, .later: output = nil
        case let .ready(buffer): output = buffer
        case let .gpu(work, complete):
            work.commandBuffer.commit()
            work.commandBuffer.waitUntilCompleted()
            output = complete(elapsedMs(since: start))
        }
        processLock.lock()
        recordCompletions()
        processLock.unlock()
        return output
    }

    /// The pipelined form of `upscale` (AE#957): encodes the frame's GPU work and returns it uncommitted.
    /// Its completion records the frame (budget, events, failures) with the time the frame held the
    /// caller's thread, which the overrun ladder compares with the frame interval.
    func begin(_ input: CVPixelBuffer, pts: CMTime) -> PipelinedFrameStage.Begun {
        processLock.lock()
        defer { processLock.unlock() }
        recordCompletions()
        guard !isDisabled else { return .passThrough }
        notePTS(pts)
        guard let built = stage else {
            notePassThrough("stage still building")
            return .passThrough
        }

        let format = CVPixelBufferGetPixelFormatType(input)
        lastInputEightBit = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        if built.plan.scaler == .lineArt {
            guard FrameChain.supportedFormats.contains(format) else {
                notePassThrough("pixel format \(fourCC(format)) is not 8 or 10-bit 4:2:0")
                return .passThrough
            }
        } else {
            guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
                notePassThrough("pixel format \(fourCC(format)) is not 8-bit 4:2:0")
                return .passThrough
            }
        }
        let picture = Self.pictureRegion(of: input)
        if picture.width != built.plan.sourceWidth || picture.height != built.plan.sourceHeight {
            guard rebuild(for: input, width: picture.width, height: picture.height) else { return .passThrough }
        }
        applyRememberedOverrun()
        guard !isDisabled, let stage else { return .passThrough }
        lastPassThroughNote = nil

        let start = DispatchTime.now().uptimeNanoseconds
        frameIndex += 1
        var times = StageTimes()
        if stage.runsMLOffThread {
            return beginOffThread(input, picture: picture, stage: stage, start: start, times: times)
        }
        let encoded: (output: CVPixelBuffer, work: EncodedGPUWork?)
        do {
            encoded = try stage.encode(input, picture: picture, frameIndex: frameIndex,
                                       mlTimeout: currentMLTimeout, submit: _mlSubmitOverride, times: &times)
        } catch {
            recordFailure(error)
            return .passThrough
        }
        guard let work = encoded.work else {
            times.total = elapsedMs(since: start)
            recordSuccess(times, stage: stage)
            return .ready(encoded.output)
        }
        let output = UncheckedSendable(encoded.output)
        let ran = UncheckedSendable(stage)
        let encodedTimes = times
        return .gpu(work) { [weak self] holdMs in
            guard let self else { return nil }
            return self.complete(work, output: output.value, stage: ran.value, times: encodedTimes, holdMs: holdMs)
        }
    }

    /// AE#957: an ML plan's frame, with `processLock` held. The crop happens here; the ML pass starts in
    /// `.later`, after `begin` let go of the lock, and `afterML` encodes MetalFX from its callback. So the
    /// decoder's thread waits only for the pass before this one, and the next frame's pass overlaps this
    /// frame's MetalFX work on the GPU.
    private func beginOffThread(_ original: CVPixelBuffer, picture: PictureRegion, stage: Stage, start: UInt64,
                                times: StageTimes) -> PipelinedFrameStage.Begun {
        var times = times
        let input: CVPixelBuffer
        do {
            input = try stage.cropInput(original, picture: picture, times: &times)
        } catch {
            recordFailure(error)
            return .passThrough
        }
        let ran = UncheckedSendable(stage)
        let frames = UncheckedSendable((original, input))
        let index = frameIndex, timeout = currentMLTimeout, submit = _mlSubmitOverride, startTimes = times
        return .later { [weak self] resume in
            guard let self else { resume(.passThrough); return }
            ran.value.startML(frames.value.1, original: frames.value.0, frameIndex: index, timeout: timeout,
                              submit: submit, times: startTimes) { [weak self] result, times in
                resume(self?.afterML(result, stage: ran.value, original: frames.value.0, input: frames.value.1,
                                     times: times, start: start) ?? .passThrough)
            }
        }
    }

    /// The ML pass answered (or timed out), on its finish queue: MetalFX encoded for the pipeline to commit,
    /// the ML output on the ML-only rung, or the original frame. The result is counted at the next `begin`.
    private func afterML(_ result: Result<UncheckedSendable<CVPixelBuffer>, Error>, stage ran: Stage,
                         original: CVPixelBuffer, input: CVPixelBuffer, times: StageTimes,
                         start: UInt64) -> PipelinedFrameStage.Begun {
        processLock.lock()
        defer { processLock.unlock() }
        // A stage replaced while the pass ran (a fallback, a rebuild) is not the one to encode on.
        guard ran === stage, !isDisabled else { return .passThrough }
        var times = times
        do {
            let mlOut = try result.get().value
            let encoded = try ran.encodeAfterML(original, input: input, mlOut: mlOut, times: &times)
            guard let work = encoded.work else {
                times.total = elapsedMs(since: start)
                queueCompletion(Completion(stage: ran, times: times, error: nil))
                return .ready(encoded.output)
            }
            let output = UncheckedSendable(encoded.output)
            let box = UncheckedSendable(ran)
            let encodedTimes = times
            return .gpu(work) { [weak self] holdMs in
                self?.complete(work, output: output.value, stage: box.value, times: encodedTimes, holdMs: holdMs)
            }
        } catch {
            queueCompletion(Completion(stage: ran, times: times, error: error))
            return .passThrough
        }
    }

    private func queueCompletion(_ completion: Completion) {
        completionLock.lock()
        completions.append(completion)
        completionLock.unlock()
    }

    /// A frame's GPU work completed, on Metal's completion thread. It only queues the result, under its
    /// own short lock, and the frame goes out at once; `recordCompletions` counts it.
    private func complete(_ work: EncodedGPUWork, output: CVPixelBuffer, stage ran: Stage,
                          times encodedTimes: StageTimes, holdMs: Double) -> CVPixelBuffer? {
        var times = encodedTimes
        let result: CVPixelBuffer?
        let completion: Completion
        do {
            times.metalGPU = try work.finish()
            times.total = holdMs
            completion = Completion(stage: ran, times: times, error: nil)
            result = output
        } catch {
            completion = Completion(stage: ran, times: times, error: error)
            result = nil
        }
        queueCompletion(completion)
        return result
    }

    /// Counts the queued completions, with `processLock` held. A frame of a stage that has since been
    /// replaced (a fallback or a rebuild) was delivered, but no longer counts for the stage that runs now.
    private func recordCompletions() {
        completionLock.lock()
        let done = completions
        completions.removeAll()
        completionLock.unlock()
        for c in done {
            guard c.stage === stage, !isDisabled else { continue }
            if let error = c.error { recordFailure(error) } else { recordSuccess(c.times, stage: c.stage) }
        }
    }

    private func notePTS(_ pts: CMTime) {
        guard pts.isNumeric else { return }
        recentPTS = Self.recentPTS(recentPTS, adding: pts.seconds)
        frameInterval = Self.liveInterval(deltas: Self.framePeriods(recentPTS), configured: configuredInterval)
    }

    /// `window` with `seconds` added: a PTS more than `maxFrameDelta` outside the window is a seek and
    /// starts a new one, a repeat is ignored, and the oldest arrival leaves past `intervalWindow + 1`.
    static func recentPTS(_ window: [Double], adding seconds: Double) -> [Double] {
        guard let lo = window.min(), let hi = window.max(),
              seconds >= lo - maxFrameDelta, seconds <= hi + maxFrameDelta else { return [seconds] }
        guard !window.contains(seconds) else { return window }
        return Array((window + [seconds]).suffix(intervalWindow + 1))
    }

    /// The gaps between neighbouring PTS in presentation order. Sorting first matters: VideoToolbox hands
    /// frames over in decode order, where the gap between two arrivals is up to a whole mini-GOP (measured
    /// 83.5 ms against a 41.7 ms period on 1080p HEVC, which doubled the budget).
    static func framePeriods(_ window: [Double]) -> [Double] {
        let sorted = window.sorted()
        return zip(sorted, sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 0 && $0 <= maxFrameDelta }
    }

    // MARK: - Rebuild and pass-through

    private func rebuild(for input: CVPixelBuffer, width: Int, height: Int) -> Bool {
        guard UpscaleRouteDecision.sizeAllowed(width: width, height: height, scaler: scaler) else {
            notePassThrough("\(width)x\(height) is " + (scaler == .lineArt ? "larger than 1920x1080" : "not below 1080p"))
            return false
        }
        let sar = Self.pixelAspectRatio(of: input)
        let display = CGSize(width: initialPlan.displayWidth, height: initialPlan.displayHeight)
        guard let plan = UpscaleRouteDecision.makePlan(
                source: SourceGeometry(width: width, height: height, sarNum: sar.0, sarDen: sar.1),
                display: display, mlScaleFactors: Self.mlScaleFactors, scaler: scaler),
              plan.targetWidth > width || plan.targetHeight > height else {
            notePassThrough("\(width)x\(height) is not smaller than the display")
            return false
        }
        let rebuilt: Stage
        do {
            let mlOnly = (degraded && plan.mlScale != nil)
                || Self.startsMLOnly(plan, metalFXAvailable: gpu.metalFXAvailable)
            rebuilt = try Stage(plan: plan, gpu: gpu, mlOnly: mlOnly, restores: lineArtRestores)
        } catch {
            disable(reason: "rebuild for \(width)x\(height) failed: \(error)")
            return false
        }
        stage = rebuilt
        // The next upscaled frame republishes the plan.
        firstFrameSent = false
        stageFrames = 0
        timingLines = 0
        let built = rebuilt.plan
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

    private func recordSuccess(_ times: StageTimes, stage: Stage) {
        consecutiveFailures = 0
        if stage.plan.mlScale != nil { mlPassSucceeded = true }
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
            if stage.plan.scaler == .lineArt, lineArtRestores {
                dropLineArtRestore(over: over, window: windowMean, plan: stage.plan)
            } else if stage.plan.scaler == .lineArt {
                fallBackFromLineArt(over: over, window: windowMean, plan: stage.plan)
            } else if !degraded, stage.plan.mlScale != nil, stage.plan.needsMetalFX {
                degrade(over: over, window: windowMean, stage: stage)
            } else {
                disable(reason: "over budget, " + over)
            }
        }
    }

    /// The line-art stage's top rung overran: remember it, rebuild without the restore pass (the kernels are
    /// compiled already, so this is quick and stays on this thread) and start a fresh budget window.
    private func dropLineArtRestore(over: String, window: StageTimes, plan: UpscalePlan) {
        LineArtCostMemory.record(LineArtCostMemory.Overrun(
            width: plan.sourceWidth, height: plan.sourceHeight, frameInterval: frameInterval, meanMs: window.total),
            rung: .restore)
        let rebuilt: Stage
        do {
            rebuilt = try Stage(plan: plan, gpu: gpu, restores: false)
        } catch {
            fallBackFromLineArt(over: over, window: window, plan: plan)
            return
        }
        lineArtRestores = false
        stage?.release()
        stage = rebuilt
        EngineLog.emit("[Upscale] degraded: line art over budget (\(over)), dropping the restore pass "
                       + "(\(window.breakdown))", category: .swPlayback)
        recentTimes.removeAll()
        stageFrames = 0
        timingLines = 0
        stateLock.lock()
        _isDegraded = true
        _deliveredPlan = plan
        let stats = _stats
        let handler = _onEvent
        stateLock.unlock()
        handler?(.degraded(plan, reason: "line art over budget, " + over, stats: stats))
    }

    /// The line-art rung overran: remember it for the process, then hand a source below 1080p to the
    /// automatic route (VT super resolution, with MetalFX where it is there), built off this thread while
    /// frames pass through. A 1080p source has nothing below line art and switches off.
    private func fallBackFromLineArt(over: String, window: StageTimes, plan: UpscalePlan) {
        LineArtCostMemory.record(LineArtCostMemory.Overrun(
            width: plan.sourceWidth, height: plan.sourceHeight, frameInterval: frameInterval, meanMs: window.total),
            rung: .upscale)
        // The automatic route takes 8-bit only, and not a plan that already switched itself off here.
        guard lastInputEightBit,
              let fallback = UpscaleRouteDecision.lineArtFallback(for: plan, mlScaleFactors: Self.mlScaleFactors),
              !UpscaleFailureMemory.contains(fallback, frameRate: 1 / frameInterval) else {
            disable(reason: "over budget, " + over)
            return
        }
        let mlOnly = Self.startsMLOnly(fallback, metalFXAvailable: gpu.metalFXAvailable)
            || MetalFXCostMemory.overrun(covering: fallback, frameInterval: frameInterval) != nil
        EngineLog.emit("[Upscale] degraded: line art over budget (\(over)), falling back to the automatic scaler"
                       + (fallback.mlScale.map { ", ML \(String(format: "%g", $0))x" } ?? "")
                       + (mlOnly ? " only" : " + MetalFX"), category: .swPlayback)
        scaler = .automatic
        stage?.release()
        stage = nil
        buildGeneration += 1
        var published = fallback
        if let buildQueue {
            buildAsync(fallback, mlOnly: mlOnly, on: buildQueue, generation: buildGeneration)
            if mlOnly {
                published.targetWidth = fallback.mlOutputWidth
                published.targetHeight = fallback.mlOutputHeight
            }
        } else {
            do {
                let built = try Stage(plan: fallback, gpu: gpu, mlOnly: mlOnly)
                stage = built
                published = built.plan
            } catch {
                disable(reason: "over budget, " + over + "; fallback not built: \(error)")
                return
            }
        }
        // MetalFX can still be dropped from the fallback later, so it is degraded only without it.
        degraded = mlOnly
        firstFrameSent = true
        recentTimes.removeAll()
        stageFrames = 0
        timingLines = 0
        stateLock.lock()
        _isDegraded = true
        _deliveredPlan = published
        let stats = _stats
        let handler = _onEvent
        stateLock.unlock()
        handler?(.degraded(published, reason: "line art over budget, " + over, stats: stats))
    }

    /// The first rung of the overrun ladder: keep ML, drop MetalFX, start a fresh budget window.
    private func degrade(over: String, window: StageTimes, stage: Stage) {
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
        guard !degraded, let stage, stage.plan.needsMetalFX,
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
            if error is MLPassFailure, fallBackFromMLFailure(error) { return }
            disable(reason: "\(consecutiveFailures) consecutive failures, last: \(error)")
        }
    }

    /// The ML pass failed `maxConsecutiveFailures` times in a row: run the same plan without it, MetalFX
    /// from the source to the target, instead of switching the stage off. VT super resolution can report
    /// support and refuse every pass (an A12 Apple TV on tvOS 27.2, GitHub's macOS VMs); when it never
    /// delivered a frame here, the process stops offering ML factors (`MLRefusalMemory`). False when there
    /// is no MetalFX to fall back to, or it overran here before.
    private func fallBackFromMLFailure(_ error: Error) -> Bool {
        guard let stage, stage.plan.scaler == .automatic, stage.plan.mlScale != nil, !degraded,
              gpu.metalFXAvailable else { return false }
        let plan = Self.metalFXOnlyPlan(stage.plan)
        guard plan.needsMetalFX, MetalFXCostMemory.overrun(covering: plan, frameInterval: frameInterval) == nil
        else { return false }
        let neverWorked = !mlPassSucceeded
        if neverWorked { MLRefusalMemory.record() }
        let reason = "ML pass failed \(consecutiveFailures) times in a row (last: \(error))"
        EngineLog.emit("[Upscale] degraded: \(reason), continuing with MetalFX only to "
                       + "\(plan.targetWidth)x\(plan.targetHeight)"
                       + (neverWorked ? "; VT super resolution is off for this process" : ""), category: .swPlayback)
        stage.release()
        self.stage = nil
        buildGeneration += 1
        if let buildQueue {
            buildAsync(plan, mlOnly: false, on: buildQueue, generation: buildGeneration)
        } else {
            do {
                self.stage = try Stage(plan: plan, gpu: gpu)
            } catch {
                disable(reason: reason + "; MetalFX only not built: \(error)")
                return true
            }
        }
        consecutiveFailures = 0
        // The published plan changes here; the next frame is not a new first frame.
        firstFrameSent = true
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
        return true
    }

    /// `plan` with its ML pass removed: MetalFX takes the source straight to the target.
    static func metalFXOnlyPlan(_ plan: UpscalePlan) -> UpscalePlan {
        var p = plan
        p.mlScale = nil
        p.mlOutputWidth = plan.sourceWidth
        p.mlOutputHeight = plan.sourceHeight
        return p
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
        stage?.release()
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

/// Set once VT super resolution failed every pass of a stage in this process: it reported support and
/// then refused, which is a property of the device, so later plans are made without an ML pass.
enum MLRefusalMemory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _refused = false

    static var refused: Bool { lock.lock(); defer { lock.unlock() }; return _refused }
    static func record() { lock.lock(); _refused = true; lock.unlock() }
    static func reset() { lock.lock(); _refused = false; lock.unlock() }
}

@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
extension FrameUpscaler {
    static func resetMLRefusalMemoryForTesting() { MLRefusalMemory.reset() }
    static func resetMetalFXCostMemoryForTesting() { MetalFXCostMemory.reset() }
    static func resetLineArtCostMemoryForTesting() { LineArtCostMemory.reset() }
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
    let metalFXAvailable: Bool

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
        if #available(tvOS 27.1, *) {
            metalFXAvailable = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        } else {
            metalFXAvailable = false
        }
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
    /// The `.lineArt` plan's whole processing; nil for `.automatic`.
    private let chain: FrameChain?
    /// The MetalFX spatial scaler, held untyped because the tvOS SDK has it only from 27.1.
    private var scaler: AnyObject?
    private var rgba: MTLTexture?
    private var scaled: MTLTexture?
    /// Set on the ML-only rung: the output is the coded picture times the ML factor, not square.
    private var sourcePAR: (Int, Int)?
    private var outputPools: [OSType: CVPixelBufferPool] = [:]
    private var cropPools: [OSType: CVPixelBufferPool] = [:]

    /// `mlOnly` builds the degraded rung of `plan`: its ML pass, delivered at the ML output size. `restores`
    /// picks the line-art stage's top rung (restore pass and highlight clamp) for a `.lineArt` plan.
    init(plan: UpscalePlan, gpu: GPU, mlOnly: Bool = false, restores: Bool = true) throws {
        self.plan = plan
        self.gpu = gpu
        if plan.scaler == .lineArt {
            ml = nil
            chain = try FrameChain(device: gpu.device, queue: gpu.queue,
                                   sourceWidth: plan.sourceWidth, sourceHeight: plan.sourceHeight,
                                   targetWidth: plan.targetWidth, targetHeight: plan.targetHeight,
                                   stages: [LineArtStage(restores: restores)])
            scaler = nil; rgba = nil; scaled = nil
            return
        }
        chain = nil
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
        let t0 = DispatchTime.now().uptimeNanoseconds
        let encoded = try encode(original, picture: picture, frameIndex: frameIndex, mlTimeout: mlTimeout,
                                 submit: submit, times: &times)
        if let work = encoded.work {
            times.metalGPU = try work.commitAndWait()
            times.metal = elapsedMs(since: t0) - times.copy - times.ml - times.edge - times.attach
        }
        return encoded.output
    }

    /// One frame up to its GPU work, encoded and not committed (AE#957): `PipelinedFrameStage` commits it
    /// and delivers `output` when it completed. `work` is nil when nothing runs on the GPU (the ML-only
    /// rung). The output's attachments are already set; they do not depend on the pixels.
    func encode(_ original: CVPixelBuffer, picture: FrameUpscaler.PictureRegion, frameIndex: Int64,
                mlTimeout: Double, submit: FrameUpscaler.MLSubmit?,
                times: inout FrameUpscaler.StageTimes) throws -> (output: CVPixelBuffer, work: EncodedGPUWork?) {
        if let chain {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let (output, work) = try chain.encode(original, picture: picture)
            times.metal = elapsedMs(since: t0)
            return (attach(to: output, from: original, times: &times), work)
        }
        let input = try cropInput(original, picture: picture, times: &times)
        let mlOut = try ml?.process(input, frameIndex: frameIndex, timeout: mlTimeout, submit: submit, times: &times)
        return try encodeAfterML(original, input: input, mlOut: mlOut, times: &times)
    }

    /// AE#957: an automatic plan with an ML pass runs it off the decoder's thread (`startML`, then
    /// `encodeAfterML` from its callback).
    var runsMLOffThread: Bool { chain == nil && ml != nil }

    /// The picture of `original` (its clean aperture), as a buffer of its own when it is smaller.
    func cropInput(_ original: CVPixelBuffer, picture: FrameUpscaler.PictureRegion,
                   times: inout FrameUpscaler.StageTimes) throws -> CVPixelBuffer {
        guard picture.width != CVPixelBufferGetWidth(original) || picture.height != CVPixelBufferGetHeight(original)
        else { return original }
        let format = CVPixelBufferGetPixelFormatType(original)
        let t0 = DispatchTime.now().uptimeNanoseconds
        if cropPools[format] == nil {
            cropPools[format] = try makePool(width: picture.width, height: picture.height, format: format)
        }
        let input = try pooledBuffer(cropPools[format]!)
        try copyPlanes(from: original, to: input, origin: (picture.x, picture.y))
        times.copy += elapsedMs(since: t0)
        return input
    }

    /// Starts this frame's ML pass and returns; `done` runs once, off this thread (see `MLScaler.start`).
    func startML(_ input: CVPixelBuffer, original: CVPixelBuffer, frameIndex: Int64, timeout: Double,
                 submit: FrameUpscaler.MLSubmit?, times: FrameUpscaler.StageTimes,
                 done: @escaping @Sendable (Result<UncheckedSendable<CVPixelBuffer>, Error>, FrameUpscaler.StageTimes) -> Void) {
        guard let ml else { done(.failure(UpscaleError("plan has no ML pass")), times); return }
        ml.start(input, original: original, frameIndex: frameIndex, timeout: timeout, submit: submit,
                 times: times, done: done)
    }

    /// Everything after the ML pass: MetalFX encoded and not committed, or the ML output itself on the
    /// ML-only rung. `mlOut` nil runs MetalFX on `input`.
    func encodeAfterML(_ original: CVPixelBuffer, input: CVPixelBuffer, mlOut: CVPixelBuffer?,
                       times: inout FrameUpscaler.StageTimes) throws -> (output: CVPixelBuffer, work: EncodedGPUWork?) {
        let format = CVPixelBufferGetPixelFormatType(original)
        let color = UpscaleColorParams(videoRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       matrix: UpscaleMatrix.of(original))
        if #available(tvOS 27.1, *), let scaler = scaler as? any MTLFXSpatialScaler, let rgba, let scaled {
            let t0 = DispatchTime.now().uptimeNanoseconds
            // On the encoding thread only; a texture an earlier frame still uses stays alive in its work.
            CVMetalTextureCacheFlush(gpu.textureCache, 0)
            let output = try makeOutput(format: format, width: plan.targetWidth, height: plan.targetHeight)
            let source = mlOut ?? input
            // The ML pass carries sample values through unchanged, so its output keeps the input's range.
            let sy = try gpu.planeTexture(source, plane: 0, format: .r8Unorm)
            let sc = try gpu.planeTexture(source, plane: 1, format: .rg8Unorm)
            let oy = try gpu.planeTexture(output, plane: 0, format: .r8Unorm)
            let oc = try gpu.planeTexture(output, plane: 1, format: .rg8Unorm)
            guard let cb = gpu.queue.makeCommandBuffer() else { throw UpscaleError("no command buffer") }
            guard let enc = cb.makeComputeCommandEncoder() else { throw UpscaleError("no encoder") }
            // `rgba` and `scaled` are shared by the frames in flight: Metal's hazard tracking orders their
            // use across command buffers on this queue.
            gpu.dispatch(enc, gpu.toRGBA, textures: [sy.0, sc.0, rgba], color: color,
                         grid: (rgba.width, rgba.height))
            enc.endEncoding()
            scaler.encode(commandBuffer: cb)
            guard let enc2 = cb.makeComputeCommandEncoder() else { throw UpscaleError("no encoder") }
            gpu.dispatch(enc2, gpu.toNV12, textures: [scaled, oy.0, oc.0], color: color,
                         grid: (scaled.width / 2, scaled.height / 2))
            enc2.endEncoding()
            times.metal = elapsedMs(since: t0)
            // The source buffers (the ML output among them) live as long as the work.
            let work = EncodedGPUWork(commandBuffer: cb, keepAlive: (sy.1, sc.1, oy.1, oc.1, source)) { status, error in
                UpscaleError("command buffer \(status.rawValue): \(error.map { "\($0)" } ?? "no error")",
                             underlying: error)
            }
            return (attach(to: output, from: original, times: &times), work)
        } else if let mlOut {
            let output: CVPixelBuffer
            if CVPixelBufferGetPixelFormatType(mlOut) == format {
                output = mlOut
            } else {
                let t0 = DispatchTime.now().uptimeNanoseconds
                output = try makeOutput(format: format, width: CVPixelBufferGetWidth(mlOut), height: CVPixelBufferGetHeight(mlOut))
                try copyPlanes(from: mlOut, to: output)
                times.copy += elapsedMs(since: t0)
            }
            return (attach(to: output, from: original, times: &times), nil)
        } else {
            throw UpscaleError("plan has no stage")
        }
    }

    private func attach(to output: CVPixelBuffer, from original: CVPixelBuffer,
                        times: inout FrameUpscaler.StageTimes) -> CVPixelBuffer {
        let t0 = DispatchTime.now().uptimeNanoseconds
        // The chain's stages may declare a new colour volume; the other paths keep the source's.
        FrameChainOutputAttachments.carry(from: original, to: output, volume: chain?.outputColorVolume ?? .unchanged)
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
private final class MLScaler: @unchecked Sendable {
    let outputWidth: Int
    let outputHeight: Int
    private let processor = VTFrameProcessor()
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    /// Unpadded output, nil when there is no margin to crop.
    private let croppedPool: CVPixelBufferPool?
    private let sourceFormat: OSType
    /// Mirrored source samples per side; an axis without room in VT's size limits keeps 0.
    private let pad: (x: Int, y: Int)
    /// `pad` in output samples.
    private let crop: (x: Int, y: Int)
    private var copiesInput = false
    private var ended = false
    private let abandoned = AbandonedPasses()
    /// AE#957: one pass at a time off the decoder's thread. The low-latency scaler numbers its frames, and
    /// the next frame's MetalFX work must be committed after this one's. Held from `start` until the
    /// callback has handed its frame on (or the pass timed out).
    private let passGate = DispatchSemaphore(value: 1)
    /// Where a pass's callback does its CPU work (crop, edges) and hands the frame on.
    private static let finishQueue = DispatchQueue(label: "AetherEngine.FrameUpscaler.ml", qos: .userInteractive)

    /// Outstanding timed-out passes past which the stage disables itself.
    static let maxAbandoned = 8
    var abandonedCount: Int { abandoned.count }

    init(width: Int, height: Int, scale: Float) throws {
        pad = Self.padding(width: width, height: height, scale: scale)
        crop = (Int((Float(pad.x) * scale).rounded()), Int((Float(pad.y) * scale).rounded()))
        let paddedW = width + 2 * pad.x, paddedH = height + 2 * pad.y
        let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: paddedW, frameHeight: paddedH, scaleFactor: scale)
        let src = config.sourcePixelBufferAttributes
        let dst = config.destinationPixelBufferAttributes
        let dstW = (dst[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? Int((Float(paddedW) * scale).rounded())
        let dstH = (dst[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? Int((Float(paddedH) * scale).rounded())
        outputWidth = dstW - 2 * crop.x
        outputHeight = dstH - 2 * crop.y
        sourceFormat = (src[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
            ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        sourcePool = try makePool(attributes: src, width: paddedW, height: paddedH)
        destinationPool = try makePool(attributes: dst, width: dstW, height: dstH)
        croppedPool = pad.x == 0 && pad.y == 0 ? nil : try makePool(attributes: dst, width: outputWidth, height: outputHeight)
        try processor.startSession(configuration: config)
    }

    deinit { end() }

    /// `mlEdgePad` on each axis whose padded size VT still takes at `scale`, preferring both, then the
    /// taller margin's axis. A margin whose output size is odd would split a chroma sample, so it is left off.
    static func padding(width: Int, height: Int, scale: Float) -> (x: Int, y: Int) {
        let p = mlEdgePad
        guard (Float(p) * scale).rounded() == Float(p) * scale, Int(Float(p) * scale) % 2 == 0 else { return (0, 0) }
        let candidates = [(p, p), (0, p), (p, 0)].filter { width > 2 * $0.0 && height > 2 * $0.1 }
        for (x, y) in candidates
        where FrameUpscaler.mlScaleFactors(width + 2 * x, height + 2 * y).contains(scale) {
            return (x, y)
        }
        return (0, 0)
    }

    /// Off the decode thread: after timed-out passes VT may be wedged, and nothing waits for the session to end.
    func end() {
        guard !ended else { return }
        ended = true
        let processor = UncheckedSendable(processor)
        DispatchQueue.global(qos: .utility).async { processor.value.endSession() }
    }

    func process(_ input: CVPixelBuffer, frameIndex: Int64, timeout: Double,
                 submit: FrameUpscaler.MLSubmit?, times: inout FrameUpscaler.StageTimes) throws -> CVPixelBuffer {
        if !copiesInput, croppedPool == nil, CVPixelBufferGetPixelFormatType(input) == sourceFormat,
           CVPixelBufferGetIOSurface(input) != nil {
            do {
                return try run(input, original: input, frameIndex: frameIndex, timeout: timeout, submit: submit, times: &times)
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
        try copyPlanes(from: input, to: copy, mirroring: pad)
        times.copy += elapsedMs(since: t0)
        return try run(copy, original: input, frameIndex: frameIndex, timeout: timeout, submit: submit, times: &times)
    }

    /// AE#957: `process` off the calling thread. Waits only for the pass before (bounded by `timeout`),
    /// starts this one and returns. `done` runs once, on `finishQueue`, with the output or the error: an
    /// `MLTimeout` when VT did not answer in `timeout`, whose buffers stay out of the pools until it does.
    /// `done` must hand the frame on (and commit its GPU work) before it returns: the next pass starts then.
    func start(_ input: CVPixelBuffer, original: CVPixelBuffer, frameIndex: Int64, timeout: Double,
               submit: FrameUpscaler.MLSubmit?, times: FrameUpscaler.StageTimes,
               done: @escaping @Sendable (Result<UncheckedSendable<CVPixelBuffer>, Error>, FrameUpscaler.StageTimes) -> Void) {
        guard passGate.wait(timeout: .now() + timeout) == .success else {
            done(.failure(MLTimeout(seconds: timeout, outstanding: abandoned.count)), times)
            return
        }
        let direct = !copiesInput && croppedPool == nil && CVPixelBufferGetPixelFormatType(input) == sourceFormat
            && CVPixelBufferGetIOSurface(input) != nil
        launch(UncheckedSendable(input), original: UncheckedSendable(original), direct: direct, frameIndex: frameIndex,
               timeout: timeout, submit: submit, times: times, done: done)
    }

    private func launch(_ input: UncheckedSendable<CVPixelBuffer>, original: UncheckedSendable<CVPixelBuffer>,
                        direct: Bool, frameIndex: Int64, timeout: Double, submit: FrameUpscaler.MLSubmit?,
                        times: FrameUpscaler.StageTimes,
                        done: @escaping @Sendable (Result<UncheckedSendable<CVPixelBuffer>, Error>, FrameUpscaler.StageTimes) -> Void) {
        var times = times
        let source: CVPixelBuffer, destination: CVPixelBuffer, params: VTLowLatencySuperResolutionScalerParameters
        do {
            if direct {
                source = input.value
            } else {
                let t0 = DispatchTime.now().uptimeNanoseconds
                source = try pooledBuffer(sourcePool)
                try copyPlanes(from: input.value, to: source, mirroring: pad)
                times.copy += elapsedMs(since: t0)
            }
            destination = try pooledBuffer(destinationPool)
            let pts = CMTime(value: frameIndex, timescale: 600)
            guard let sf = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
                  let df = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: pts)
            else { throw UpscaleError("VTFrameProcessorFrame refused a buffer") }
            params = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sf, destinationFrame: df)
        } catch {
            passGate.signal()
            done(.failure(error), times)
            return
        }
        let pass = AsyncPass()
        let retrySubmit = UncheckedSendable(submit)
        let buffers = UncheckedSendable((source, destination))
        let abandoned = abandoned
        let gate = passGate
        let t0 = DispatchTime.now().uptimeNanoseconds
        let callback: @Sendable (Error?) -> Void = { [self] error in
            let (first, abandonedID) = pass.finish()
            guard first else {
                // The pass answered after its timeout: its buffers may go back to the pools.
                if let abandonedID { abandoned.remove(abandonedID) }
                return
            }
            Self.finishQueue.async { [self] in
                var times = times
                times.ml += elapsedMs(since: t0)
                if let error {
                    if direct, !FrameUpscaler.isBackgroundRefusal(error) {
                        // As in `process`: VT may refuse the decoder's buffer; copy it from now on.
                        copiesInput = true
                        EngineLog.emit("[Upscale] ML scaler refused the decoder buffer (\(error)), copying input from now on",
                                       category: .swPlayback)
                        launch(input, original: original, direct: false, frameIndex: frameIndex, timeout: timeout,
                               submit: retrySubmit.value, times: times, done: done)
                        return
                    }
                    gate.signal()
                    done(.failure(FrameUpscaler.isBackgroundRefusal(error) ? error : MLPassFailure(underlying: error)), times)
                    return
                }
                let result: Result<UncheckedSendable<CVPixelBuffer>, Error>
                let t1 = DispatchTime.now().uptimeNanoseconds
                do {
                    result = .success(UncheckedSendable(try finishOutput(buffers.value.1, original: original.value)))
                } catch {
                    result = .failure(error)
                }
                times.edge = elapsedMs(since: t1)
                done(result, times)
                gate.signal()
            }
        }
        if let submit {
            submit(params) { callback($0) }
        } else {
            processor.process(parameters: params) { _, error in callback(error) }
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + timeout) {
            // VT may still write these later: keep them out of the pools until it calls back.
            guard pass.timeOut({ abandoned.insert(buffers.value.0, buffers.value.1) }) else { return }
            gate.signal()
            done(.failure(MLTimeout(seconds: timeout, outstanding: abandoned.count)), times)
        }
    }

    /// The pass's destination without its margin, with its edge band rescaled on every side (AE#846).
    private func finishOutput(_ destination: CVPixelBuffer, original: CVPixelBuffer) throws -> CVPixelBuffer {
        var output = destination
        if let croppedPool {
            output = try pooledBuffer(croppedPool)
            try copyPlanes(from: destination, to: output, origin: crop)
        }
        try rescaleEdges(of: output, from: original)
        return output
    }

    private func run(_ source: CVPixelBuffer, original: CVPixelBuffer, frameIndex: Int64, timeout: Double,
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
        if let error = result {
            throw FrameUpscaler.isBackgroundRefusal(error) ? error : MLPassFailure(underlying: error)
        }
        times.ml += elapsedMs(since: t0)
        mlTimed = true
        let t1 = DispatchTime.now().uptimeNanoseconds
        defer { times.edge = elapsedMs(since: t1) }
        return try finishOutput(destination, original: original)
    }
}

/// VT super resolution rings in the outer samples of its output, as if it padded the frame with zeros
/// (measured up to 147 code values on a flat field at 1.5x). The source therefore gets this many mirrored
/// samples on each side and the scaled margin is cropped off again, so the ringing falls in the discarded part.
let mlEdgePad = 16

/// The outer output samples (half in chroma) on every side are a bilinear scale of the source. Where VT's size
/// limit leaves no room for the margin (1280 wide at 1.5x) this hides the ringing, past it that stays within 4
/// code values. Everywhere else it hides the dark half-lines at a DVD's frame edge, which the ML pass sharpens
/// into a bright line three rows in (156 on a 126 field, AE#846); the band reaches past it.
let mlEdgeBand = 8

/// Rewrites the `mlEdgeBand` outer columns and/or rows of `output` with a bilinear scale of `source`.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private func rescaleEdges(of output: CVPixelBuffer, from source: CVPixelBuffer) throws {
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(output, [])
    defer {
        CVPixelBufferUnlockBaseAddress(output, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    for plane in 0..<2 {
        guard let s = CVPixelBufferGetBaseAddressOfPlane(source, plane)?.assumingMemoryBound(to: UInt8.self),
              let d = CVPixelBufferGetBaseAddressOfPlane(output, plane)?.assumingMemoryBound(to: UInt8.self)
        else { throw UpscaleError("plane \(plane) has no base address") }
        let channels = plane == 0 ? 1 : 2
        let band = plane == 0 ? mlEdgeBand : mlEdgeBand / 2
        let sw = CVPixelBufferGetWidthOfPlane(source, plane), sh = CVPixelBufferGetHeightOfPlane(source, plane)
        let w = CVPixelBufferGetWidthOfPlane(output, plane), h = CVPixelBufferGetHeightOfPlane(output, plane)
        let sStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let dStride = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
        guard w > 2 * band, h > 2 * band else { continue }
        let xs = bilinearTaps(count: w, source: sw), ys = bilinearTaps(count: h, source: sh)
        func write(row y: Int, columns: [Int]) {
            let ty = ys[y]
            let r0 = s + ty.i0 * sStride, r1 = s + ty.i1 * sStride, out = d + y * dStride
            for x in columns {
                let tx = xs[x]
                let a0 = tx.i0 * channels, a1 = tx.i1 * channels
                for c in 0..<channels {
                    let top = Float(r0[a0 + c]) + (Float(r0[a1 + c]) - Float(r0[a0 + c])) * tx.a
                    let bottom = Float(r1[a0 + c]) + (Float(r1[a1 + c]) - Float(r1[a0 + c])) * tx.a
                    out[x * channels + c] = UInt8(top + (bottom - top) * ty.a + 0.5)
                }
            }
        }
        let all = Array(0..<w), sides = Array(0..<band) + Array((w - band)..<w)
        for y in 0..<band { write(row: y, columns: all) }
        for y in (h - band)..<h { write(row: y, columns: all) }
        for y in band..<(h - band) { write(row: y, columns: sides) }
    }
}

/// Source taps of a bilinear scale from `source` to `count` samples, centres aligned and clamped to the edge.
private func bilinearTaps(count: Int, source: Int) -> [(i0: Int, i1: Int, a: Float)] {
    let f = Double(source) / Double(count)
    return (0..<count).map { i in
        let p = min(max((Double(i) + 0.5) * f - 0.5, 0), Double(source - 1))
        let i0 = Int(p)
        return (i0, min(i0 + 1, source - 1), Float(p - Double(i0)))
    }
}

private func elapsedMs(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
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

/// One value handed from another thread to a waiting one.
private final class SyncBox<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Value?
    func put(_ value: Value) { self.value = value; semaphore.signal() }
    func take() -> Value { semaphore.wait(); return value! }
}

/// AE#957: an ML pass started off the decoder's thread, raced by its timeout. The first of the two wins.
private final class AsyncPass: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0  // 0 pending, 1 finished, 2 timed out
    private var abandonedID: Int?
    /// VT called back: true when it was in time, else the abandoned buffers' id to release.
    func finish() -> (first: Bool, abandonedID: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard state == 0 else { return (false, abandonedID) }
        state = 1
        return (true, nil)
    }
    /// The timeout fired first: `abandon` parks the buffers, under the lock, so a late callback finds them.
    func timeOut(_ abandon: () -> Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == 0 else { return false }
        state = 2
        abandonedID = abandon()
        return true
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
/// VT's ML pass returned an error (not a timeout, not a background refusal): three in a row fall back
/// to MetalFX only (`fallBackFromMLFailure`).
private struct MLPassFailure: Error, CustomStringConvertible {
    let underlying: Error
    var description: String { "ML pass failed: \(underlying)" }
}

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

/// `copyPlanes` into a buffer `pad` samples (even) larger on each side, the margin mirrored about the edge sample.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
private func copyPlanes(from src: CVPixelBuffer, to dst: CVPixelBuffer, mirroring pad: (x: Int, y: Int)) throws {
    guard pad.x != 0 || pad.y != 0 else { return try copyPlanes(from: src, to: dst) }
    guard pad.x % 2 == 0, pad.y % 2 == 0,
          CVPixelBufferGetWidth(dst) == CVPixelBufferGetWidth(src) + 2 * pad.x,
          CVPixelBufferGetHeight(dst) == CVPixelBufferGetHeight(src) + 2 * pad.y,
          CVPixelBufferGetPlaneCount(src) == 2, CVPixelBufferGetPlaneCount(dst) == 2
    else { throw UpscaleError("mirrored copy between mismatched buffers") }
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
        let bytes = plane == 0 ? 1 : 2
        let px = plane == 0 ? pad.x : pad.x / 2, py = plane == 0 ? pad.y : pad.y / 2
        let w = CVPixelBufferGetWidthOfPlane(src, plane), h = CVPixelBufferGetHeightOfPlane(src, plane)
        let sStride = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
        let dStride = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
        guard w > px, h > py else { throw UpscaleError("plane \(plane) smaller than its margin") }
        for row in 0..<(h + 2 * py) {
            let sy = row < py ? py - row : (row >= h + py ? 2 * (h - 1) - (row - py) : row - py)
            let from = s + sy * sStride, to = d + row * dStride
            memcpy(to + px * bytes, from, w * bytes)
            for x in 0..<px {
                memcpy(to + (px - 1 - x) * bytes, from + (x + 1) * bytes, bytes)
                memcpy(to + (px + w + x) * bytes, from + (w - 2 - x) * bytes, bytes)
            }
        }
    }
}

// MARK: - Benchmark

/// One plan's stage built as playback builds it (VT session, MetalFX scaler, line-art chain), for
/// `PerFrameBenchmark`: the bench times what a frame really costs, not a copy of the stage.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class UpscaleBenchmarkStage {
    /// The plan the stage runs, as built (an ML-only rung keeps the ML output size).
    let plan: UpscalePlan
    private let stage: Stage
    private var frameIndex: Int64 = 0

    init(plan: UpscalePlan, restores: Bool = true) throws {
        guard let gpu = GPU() else { throw UpscaleError("no Metal device or upscale kernels") }
        stage = try Stage(plan: plan, gpu: gpu, restores: restores)
        self.plan = stage.plan
    }

    /// Runs one frame through the stage and returns its step times. `mlTimeout` is generous: a bench
    /// waits for the ML pass instead of dropping it as playback does.
    func process(_ frame: CVPixelBuffer, mlTimeout: Double = 1) throws -> FrameUpscaler.StageTimes {
        frameIndex += 1
        var times = FrameUpscaler.StageTimes()
        _ = try stage.process(frame, picture: FrameUpscaler.pictureRegion(of: frame), frameIndex: frameIndex,
                              mlTimeout: mlTimeout, submit: nil, times: &times)
        return times
    }
}

private func fourCC(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(code)
}
#endif
