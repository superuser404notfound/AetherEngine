// The frame chain is not built for the simulator.
#if !targetEnvironment(simulator)
import Foundation
import CoreMedia
import CoreVideo
import Metal

/// The per-frame picture processing stage (#957): a `FrameChain` with one `ToneMapStage`, which the chain
/// fuses into its one-kernel round trip. Playback runs it through a `PipelinedFrameStage` (`begin`), two
/// frames on the GPU at once; `process` is the same frame start to finish on the calling thread, nil
/// whenever the caller should deliver the original frame.
///
/// The curve starts from the frame's own HDR10 metadata and falls back to the plan's (the source's
/// declaration) for a frame that carries none. A frame the stage does not apply to (not PQ, not 4:2:0, a
/// peak at or below the target) passes through, logged once. Repeated failures, a sustained overrun of the
/// frame budget, or HDR10+ metadata in the stream switch it off for good, logged once: a display applies
/// HDR10+ to the picture it receives, which would then be mapped twice.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class FrameToneMapper: @unchecked Sendable {

    struct Stats: Equatable, Sendable {
        var framesProcessed = 0
        var failures = 0
        var meanMs = 0.0
        var maxMs = 0.0
    }

    enum Event: Sendable {
        /// The first processed frame, and every later one whose curve differs from the last published
        /// (its own metadata rebuilt the chain).
        case processed(VideoProcessingStatus)
        case disabled(reason: String, cause: DisableCause, stats: Stats)
    }

    /// Why the stage switched itself off. HDR10+ is a property of the title at any frame rate; the
    /// other two may not recur at a lower rate.
    enum DisableCause: Sendable, Equatable {
        case overrun, failures, hdr10Plus
    }

    /// The upscaler's budget rules, for the same reasons (the GPU clock follows the load).
    static let budgetWindow = FrameUpscaler.budgetWindow
    static let budgetFraction = FrameUpscaler.budgetFraction
    static let maxConsecutiveFailures = FrameUpscaler.maxConsecutiveFailures
    /// Timing lines logged, one per budget window.
    static let timingLines = 10

    let plan: VideoProcessingPlan

    var onEvent: (@Sendable (Event) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onEvent }
        set { stateLock.lock(); _onEvent = newValue; stateLock.unlock() }
    }

    /// Why the stage switched itself off, nil while it runs.
    var disabledReason: String? { stateLock.lock(); defer { stateLock.unlock() }; return _disabledReason }

    /// What switched it off, read with `disabledReason`.
    var disabled: (reason: String, cause: DisableCause)? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _disabledReason.map { ($0, _disabledCause) }
    }

    /// What the last published frame ran (the first processed one, or one that rebuilt the curve), nil before it.
    var delivered: VideoProcessingStatus? { stateLock.lock(); defer { stateLock.unlock() }; return _delivered }

    var stats: Stats { stateLock.lock(); defer { stateLock.unlock() }; return _stats }

    /// The overrun budget per frame, from the live frame interval.
    var frameBudgetMs: Double {
        processLock.lock(); defer { processLock.unlock() }
        return Self.budgetFraction * frameInterval * 1000
    }

    private let stateLock = NSLock()
    private var _onEvent: (@Sendable (Event) -> Void)?
    private var _disabledReason: String?
    private var _disabledCause = DisableCause.failures
    private var _delivered: VideoProcessingStatus?
    private var _stats = Stats()

    private let processLock = NSLock()
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let configuredInterval: Double
    private var frameInterval: Double
    private var recentPTS: [Double] = []
    private var chain: FrameChain?
    private var chainSize: (width: Int, height: Int)?
    /// The source metadata the chain's curve was built from; a frame with other values rebuilds it.
    private var chainSource: HDR10StaticMetadata?
    private var recentMs: [Double] = []
    private var totalMs = 0.0
    private var timingLinesLogged = 0
    private var consecutiveFailures = 0
    private var lastPassThroughNote: String?
    private var isDisabled = false

    init(plan: VideoProcessingPlan, frameInterval: Double, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.plan = plan
        self.device = device
        queue = device?.makeCommandQueue()
        configuredInterval = frameInterval
        self.frameInterval = frameInterval
    }

    func process(_ input: CVPixelBuffer, pts: CMTime, carriesHDR10Plus: Bool) -> CVPixelBuffer? {
        let start = DispatchTime.now().uptimeNanoseconds
        switch begin(input, pts: pts, carriesHDR10Plus: carriesHDR10Plus) {
        case .passThrough, .later: return nil
        case let .ready(output): return output
        case let .gpu(work, complete):
            work.commandBuffer.commit()
            work.commandBuffer.waitUntilCompleted()
            return complete(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
    }

    /// `process` without the commit and the wait (AE#957). The completion records the frame with the time
    /// it held the caller's thread, which the overrun check compares with the frame interval.
    func begin(_ input: CVPixelBuffer, pts: CMTime, carriesHDR10Plus: Bool) -> PipelinedFrameStage.Begun {
        processLock.lock()
        defer { processLock.unlock() }
        guard !isDisabled else { return .passThrough }
        if carriesHDR10Plus {
            disable(reason: "HDR10+ metadata in the stream (the display would map the mapped picture again)",
                    cause: .hdr10Plus)
            return .passThrough
        }
        if pts.isNumeric {
            recentPTS = FrameUpscaler.recentPTS(recentPTS, adding: pts.seconds)
            frameInterval = FrameUpscaler.liveInterval(deltas: FrameUpscaler.framePeriods(recentPTS),
                                                       configured: configuredInterval)
        }
        let format = CVPixelBufferGetPixelFormatType(input)
        guard FrameChain.supportedFormats.contains(format) else {
            notePassThrough("pixel format \(format) is not 8 or 10-bit 4:2:0")
            return .passThrough
        }
        let transfer = CVBufferCopyAttachment(input, kCVImageBufferTransferFunctionKey, nil) as? String
        guard transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String else {
            notePassThrough("the frame is not PQ")
            return .passThrough
        }
        let picture = FrameUpscaler.pictureRegion(of: input)
        guard picture.width % 2 == 0, picture.height % 2 == 0 else {
            notePassThrough("picture \(picture.width)x\(picture.height) is odd")
            return .passThrough
        }
        let source = HDR10StaticMetadata(
            masteringDisplayColorVolume: CVBufferCopyAttachment(input, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data,
            contentLightLevel: CVBufferCopyAttachment(input, kCVImageBufferContentLightLevelInfoKey, nil) as? Data)
            ?? plan.source

        do {
            guard let built = try chain(for: source, width: picture.width, height: picture.height) else {
                return .passThrough
            }
            let (output, work) = try built.chain.encode(input, picture: picture)
            built.chain.attach(from: input, to: output)
            lastPassThroughNote = nil
            let delivered = UncheckedSendable(output)
            let status = built.status
            return .gpu(work) { [weak self] holdMs in
                self?.complete(work, output: delivered.value, status: status, holdMs: holdMs)
            }
        } catch {
            recordFailure(error)
            return .passThrough
        }
    }

    private func complete(_ work: EncodedGPUWork, output: CVPixelBuffer, status: VideoProcessingStatus,
                          holdMs: Double) -> CVPixelBuffer? {
        processLock.lock()
        defer { processLock.unlock() }
        do {
            _ = try work.finish()
        } catch {
            if !isDisabled { recordFailure(error) }
            return nil
        }
        if !isDisabled { recordSuccess(holdMs, status: status) }
        return output
    }

    /// The chain for `source` at this size, built when either changed; nil (and a pass-through note) when
    /// this source's peak gives no curve to the target.
    private func chain(for source: HDR10StaticMetadata, width: Int, height: Int) throws
        -> (chain: FrameChain, status: VideoProcessingStatus)? {
        let target = plan.curve.targetPeakNits
        guard let peak = ToneMapSourcePeak.choose(masteringPeakNits: source.masteringPeakNits, maxCLL: source.maxCLL),
              let curve = BT2390ToneCurve(sourcePeakNits: peak.nits, targetPeakNits: target) else {
            notePassThrough("the frame's metadata gives no curve to the \(String(format: "%g", target)) nit target")
            return nil
        }
        let status = VideoProcessingStatus(stages: [.toneMap], sourcePeakNits: curve.sourcePeakNits,
                                           sourcePeak: peak.from, targetPeakNits: target)
        if let chain, chainSource == source, chainSize.map({ $0 == (width, height) }) == true {
            return (chain, status)
        }
        guard let device, let queue else { throw FrameToneMapperError.noMetalDevice }
        let built = try FrameChain(device: device, queue: queue, sourceWidth: width, sourceHeight: height,
                                   targetWidth: width, targetHeight: height,
                                   stages: [ToneMapStage(curve: curve, source: source)])
        let rebuilt = chain != nil
        chain = built
        chainSize = (width, height)
        chainSource = source
        EngineLog.emit(String(format: "[VideoProcessing] chain %@ for %dx%d: tone map %g nit (%@) to %g nit, "
                              + "knee at %.0f nit, %@", rebuilt ? "rebuilt" : "built", width, height,
                              curve.sourcePeakNits, peak.from.rawValue, target, curve.kneeNits,
                              built.isRoundTripOnly ? "one kernel" : "two passes"),
                       category: .swPlayback)
        return (built, status)
    }

    private func recordSuccess(_ ms: Double, status: VideoProcessingStatus) {
        consecutiveFailures = 0
        totalMs += ms
        recentMs.append(ms)
        if recentMs.count > Self.budgetWindow { recentMs.removeFirst() }
        stateLock.lock()
        _stats.framesProcessed += 1
        _stats.meanMs = totalMs / Double(_stats.framesProcessed)
        _stats.maxMs = max(_stats.maxMs, ms)
        let frames = _stats.framesProcessed
        let changed = _delivered != status
        if changed { _delivered = status }
        let handler = _onEvent
        stateLock.unlock()
        if changed { handler?(.processed(status)) }

        let windowMean = recentMs.reduce(0, +) / Double(recentMs.count)
        if frames % Self.budgetWindow == 0, timingLinesLogged < Self.timingLines {
            timingLinesLogged += 1
            EngineLog.emit(String(format: "[VideoProcessing] timing: %.2f ms mean over %d frames at %.1f ms interval",
                                  windowMean, recentMs.count, frameInterval * 1000), category: .swPlayback)
        }
        let budgetMs = Self.budgetFraction * frameInterval * 1000
        if recentMs.count == Self.budgetWindow, windowMean > budgetMs {
            disable(reason: String(format: "over budget, %.2f ms mean over %d frames against %.2f ms",
                                   windowMean, Self.budgetWindow, budgetMs), cause: .overrun)
        }
    }

    private func recordFailure(_ error: Error) {
        consecutiveFailures += 1
        stateLock.lock()
        _stats.failures += 1
        stateLock.unlock()
        if consecutiveFailures >= Self.maxConsecutiveFailures {
            disable(reason: "\(consecutiveFailures) consecutive failures, last: \(error)", cause: .failures)
        }
    }

    private func notePassThrough(_ note: String) {
        guard note != lastPassThroughNote else { return }
        lastPassThroughNote = note
        EngineLog.emit("[VideoProcessing] passing frames through: \(note)", category: .swPlayback)
    }

    private func disable(reason: String, cause: DisableCause) {
        guard !isDisabled else { return }
        isDisabled = true
        chain = nil
        stateLock.lock()
        _disabledReason = reason
        _disabledCause = cause
        let stats = _stats
        let handler = _onEvent
        stateLock.unlock()
        EngineLog.emit(String(format: "[VideoProcessing] disabled: %@ (frames %d, failures %d, mean %.2f ms, max %.2f ms)",
                              reason, stats.framesProcessed, stats.failures, stats.meanMs, stats.maxMs),
                       category: .swPlayback)
        handler?(.disabled(reason: reason, cause: cause, stats: stats))
    }
}

enum FrameToneMapperError: Error, CustomStringConvertible {
    case noMetalDevice

    var description: String {
        switch self {
        case .noMetalDevice: return "no Metal device"
        }
    }
}
#endif
