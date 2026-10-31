// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import Metal
import CoreVideo
import CoreMedia
import Dovi
import os

/// Hardware-accelerated Metal compute engine for Dolby Vision Profile 7 Full
/// Enhancement Layer (FEL).
///
/// Reconstructs the VDR master from a 10-bit base layer and a 10-bit enhancement
/// layer: each component's base-layer sample goes through its piecewise
/// reshaping curve (polynomial or MMR), the inverse-NLQ residual decoded from the
/// enhancement layer is added, and the result is quantised back down to a 10-bit
/// video-range P010 CVPixelBuffer.
final class DoviFelComposer: @unchecked Sendable {

    /// `os_signpost` interval from "slot acquired, about to encode" to "GPU
    /// retired, handing off to `OrderedDelivery`" (dolby-vision-fel.md §5.11), readable in
    /// Instruments alongside `OrderedDelivery`'s own "Delivery" interval.
    private static let signpostLog = OSLog(subsystem: EngineLog.subsystem, category: "dovi.compose")

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?

    /// Lazily compiled and process-shared compute pipelines (dolby-vision-fel.md §5.6).
    private var pipelines: SharedPipelines?
    /// Whether `dispatchThreads` is available. It needs non-uniform threadgroup
    /// support (`MTLGPUFamily.apple4`, i.e. A11 and later; the first-generation
    /// Apple TV 4K is A10X and is not); everything older has to dispatch whole
    /// threadgroups and rely on the kernels' bounds guard.
    private let supportsNonUniformThreadgroups: Bool

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private var poolFormat: DoviFelChromaFormat = .yuv420
    private var poolBuffers: [WeakPoolBuffer] = []
    private var poolBufferHighWaterMark = 0
    /// Set by ``releaseOutputPool()``. A composition arriving after teardown (a VideoToolbox callback still in
    /// flight when the decoder closed) is refused instead of quietly building a new pool nobody will release.
    private var tornDown = false
    private let lock = NSLock()

    /// Whether playback composes into the decoded base-layer buffer instead of a buffer from the output pool
    /// (see ``canComposeInPlace(baseBuffer:params:)``). On by default; `AETHER_FEL_INPLACE=0` in the
    /// environment turns it off for an A/B run, and tests set it directly. Guarded by `lock`.
    private var inPlaceEnabled = ProcessInfo.processInfo.environment["AETHER_FEL_INPLACE"] != "0"
    /// Base-layer buffers a composition is currently writing into. A buffer in here is not composed again
    /// and not handed to anything else until its command buffer retires. Guarded by `lock`.
    private var inPlaceInFlight = Set<ObjectIdentifier>()
    /// Frames composed in place since creation, and frames lost to a command buffer that failed after it had
    /// started writing into the base-layer buffer. Guarded by `lock`.
    private var inPlaceComposedCount = 0
    private var inPlaceLostCount = 0
    /// The chroma sampling of composed frames (see ``DoviFelChromaFormat``). Starts from `AETHER_FEL_CHROMA`,
    /// 4:2:0 when unset; tests set it directly. Guarded by `lock`.
    private var chromaFormatStorage = DoviFelChromaFormat.fromEnvironment

    private final class WeakPoolBuffer {
        weak var value: CVPixelBuffer?
        init(_ value: CVPixelBuffer) { self.value = value }
    }

    /// Preallocated Metal parameter buffers (one per in-flight slot) to avoid per-frame allocations (dolby-vision-fel.md §5.6).
    private let paramBuffers: [MTLBuffer]
    /// Preallocated 1024-entry luma prediction LUT buffers (dolby-vision-fel.md §5.6).
    private let lumaLutBuffers: [MTLBuffer]
    private var freeParamSlotIndices: [Int]

    /// Output pixel buffer pool status for 1 Hz summary diagnostics (dolby-vision-fel.md §5.11).
    var allocatedPoolBuffers: Int {
        lock.lock()
        defer { lock.unlock() }
        return poolBufferHighWaterMark
    }

    /// Number of `uint` slots `dovi_layout_probe` writes.
    static let layoutProbeSlots = 36 + 3 * 20

    /// Largest `coefficient_log2_denom` the fixed-point path accepts. The RPU
    /// syntax caps it at 23 (0x17), so a
    /// larger value means a misparse rather than an exotic stream.
    private static let maxCoefLog2Denom = 23

    /// One-shot latch for the `linear_deadzone_threshold != 0` diagnostic.
    ///
    /// The inverse NLQ adds the threshold to the scaled magnitude before the shift,
    /// as the spec's pseudo-code and DoViBaker do; see `dovi_eval_inv_nlq`. Every
    /// stream available to test against carries a zero threshold, so a non-zero one
    /// is the first content to actually exercise that term and is worth saying so
    /// out loud exactly once.
    nonisolated(unsafe) private static var loggedNonZeroDeadzone = false
    private static let deadzoneLogLock = NSLock()

    /// Lines already logged by ``logOnce(_:)``. Bounded: a stream that varies the numbers in a message stops
    /// being logged after `maxOnceLines` distinct lines instead of growing the set.
    nonisolated(unsafe) private static var onceLines = Set<String>()
    private static let onceLock = NSLock()
    private static let maxOnceLines = 64

    /// Logs a line once per distinct text. Parse-time rejections and command buffer errors can recur on every
    /// frame (a stream that trips a check, a GPU that keeps failing), so each would otherwise flood the log;
    /// the decoder's per-second summary still counts every failed compose.
    private static func logOnce(_ line: String, category: EngineLog.Category = .swPlayback) {
        onceLock.lock()
        let fresh = onceLines.count < maxOnceLines && onceLines.insert(line).inserted
        onceLock.unlock()
        if fresh { EngineLog.emit(line, category: category) }
    }

    /// Test seam: counts how many times `parseRpuParameters` has been called
    /// (i.e., how many RPUs have been parsed). Reset with
    /// `resetParseRpuCountForTesting()` between measurements.
    /// Per thread, so concurrently running tests cannot disturb each other's count.
    private static let parseCountKey = "DoviFelComposer.parseRpuCount"
    private static var _parseRpuCount: Int {
        get { Thread.current.threadDictionary[parseCountKey] as? Int ?? 0 }
        set { Thread.current.threadDictionary[parseCountKey] = newValue }
    }
    static var parseRpuCountForTesting: Int { _parseRpuCount }
    static func resetParseRpuCountForTesting() { _parseRpuCount = 0 }

    enum ComposerError: Error, Sendable {
        case missingKernelFunction
    }

    /// Process-shared compute pipelines compiled once per device (dolby-vision-fel.md §5.6).
    final class SharedPipelines: @unchecked Sendable {
        let lumaPipeline: MTLComputePipelineState
        let chromaPipeline: MTLComputePipelineState
        let chroma422Pipeline: MTLComputePipelineState
        let chroma444Pipeline: MTLComputePipelineState
        let layoutProbePipeline: MTLComputePipelineState?

        init(
            luma: MTLComputePipelineState,
            chroma: MTLComputePipelineState,
            chroma422: MTLComputePipelineState,
            chroma444: MTLComputePipelineState,
            probe: MTLComputePipelineState?
        ) {
            self.lumaPipeline = luma
            self.chromaPipeline = chroma
            self.chroma422Pipeline = chroma422
            self.chroma444Pipeline = chroma444
            self.layoutProbePipeline = probe
        }

        /// The chroma kernel for `format`.
        func pipeline(for format: DoviFelChromaFormat) -> MTLComputePipelineState {
            switch format {
            case .yuv420: return chromaPipeline
            case .yuv422: return chroma422Pipeline
            case .yuv444: return chroma444Pipeline
            }
        }

        /// Per-device results, failures included: a shader that does not compile will not compile on the next
        /// frame either, so the failure is kept and every later call fails fast instead of recompiling.
        final class Cache: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [ObjectIdentifier: Result<SharedPipelines, Error>] = [:]

            func resolve(device: MTLDevice, compile: () throws -> SharedPipelines) throws -> SharedPipelines {
                lock.lock()
                defer { lock.unlock() }
                let key = ObjectIdentifier(device)
                if let entry = entries[key] { return try entry.get() }
                let result = Result { try compile() }
                entries[key] = result
                return try result.get()
            }

            func removeAll() {
                lock.lock()
                entries.removeAll()
                lock.unlock()
            }
        }

        private static let shared = Cache()

        static func getOrCreate(device: MTLDevice) throws -> SharedPipelines {
            try shared.resolve(device: device) {
                do {
                    return try compile(device: device, source: DoviShaderSource.source)
                } catch {
                    EngineLog.emit("[DoviFelComposer] Metal shader compilation error: \(error)", category: .swPlayback)
                    throw error
                }
            }
        }

        static func compile(device: MTLDevice, source: String) throws -> SharedPipelines {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let lumaFn = library.makeFunction(name: "dovi_compose_luma"),
                  let chromaFn = library.makeFunction(name: "dovi_compose_chroma"),
                  let chroma422Fn = library.makeFunction(name: "dovi_compose_chroma_422"),
                  let chroma444Fn = library.makeFunction(name: "dovi_compose_chroma_444") else {
                throw ComposerError.missingKernelFunction
            }
            let luma = try device.makeComputePipelineState(function: lumaFn)
            let chroma = try device.makeComputePipelineState(function: chromaFn)
            let chroma422 = try device.makeComputePipelineState(function: chroma422Fn)
            let chroma444 = try device.makeComputePipelineState(function: chroma444Fn)
            let probe: MTLComputePipelineState?
            if let probeFn = library.makeFunction(name: "dovi_layout_probe") {
                probe = try? device.makeComputePipelineState(function: probeFn)
            } else {
                probe = nil
            }

            return SharedPipelines(luma: luma, chroma: chroma, chroma422: chroma422, chroma444: chroma444, probe: probe)
        }

        #if DEBUG
        static func resetCacheForTesting() {
            shared.removeAll()
        }
        #endif
    }

    /// Lazily resolves or compiles the process-shared Metal compute pipelines (dolby-vision-fel.md §5.6).
    private func ensurePipelines() -> SharedPipelines? {
        // Under `lock` on every read: `pipelines` is written from whichever thread composes first, and a
        // failed compile is cached by `SharedPipelines.Cache`, so a broken shader costs one compile, once.
        lock.lock()
        defer { lock.unlock() }
        if let pipelines { return pipelines }
        guard let p = try? SharedPipelines.getOrCreate(device: device) else { return nil }
        self.pipelines = p
        return p
    }

    #if DEBUG
    var lumaPipelineForTesting: MTLComputePipelineState? {
        ensurePipelines()?.lumaPipeline
    }

    var chromaPipelineForTesting: MTLComputePipelineState? {
        ensurePipelines()?.chromaPipeline
    }
    #endif

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            return nil
        }
        self.device = dev
        self.commandQueue = queue
        self.supportsNonUniformThreadgroups = dev.supportsFamily(.apple4) || dev.supportsFamily(.mac2)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache) == kCVReturnSuccess,
              let createdCache = cache else {
            return nil
        }
        self.textureCache = createdCache

        var pBuffers: [MTLBuffer] = []
        var lutBuffers: [MTLBuffer] = []
        for _ in 0..<Self.maxFramesInFlight {
            guard let buf = dev.makeBuffer(length: DoviMetalParams.serializedSize, options: .storageModeShared),
                  let lut = dev.makeBuffer(length: 1024 * MemoryLayout<Float>.stride, options: .storageModeShared) else {
                return nil
            }
            pBuffers.append(buf)
            lutBuffers.append(lut)
        }
        self.paramBuffers = pBuffers
        self.lumaLutBuffers = lutBuffers
        self.freeParamSlotIndices = Array(0..<Self.maxFramesInFlight)
    }

    deinit {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    // MARK: - Pixel Buffer Pool Management

    private func ensurePool(width: Int, height: Int, format: DoviFelChromaFormat) -> CVPixelBufferPool? {
        lock.lock()
        defer { lock.unlock() }

        // Checked under the same lock `releaseOutputPool()` takes, so a teardown landing between a caller's
        // earlier look and this point cannot leave a fresh pool behind that nothing will release.
        guard !tornDown else { return nil }

        if let pool = pixelBufferPool, poolWidth == width, poolHeight == height, poolFormat == format {
            return pool
        }

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4,
            kCVPixelBufferPoolMaximumBufferAgeKey: 1.0,
            kCVPixelBufferPoolAllocationThresholdKey: DoviFelComposer.outputPoolAllocationThreshold
        ]

        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &newPool
        )

        guard status == kCVReturnSuccess, let pool = newPool else {
            return nil
        }

        self.pixelBufferPool = pool
        self.poolWidth = width
        self.poolHeight = height
        self.poolFormat = format
        poolBuffers.removeAll()
        poolBufferHighWaterMark = 0
        return pool
    }

    private func recordPoolBuffer(_ buffer: CVPixelBuffer, pool: CVPixelBufferPool) {
        lock.lock()
        defer { lock.unlock() }
        guard pool === pixelBufferPool else { return }
        poolBuffers.removeAll { $0.value == nil }
        if !poolBuffers.contains(where: { $0.value === buffer }) {
            poolBuffers.append(WeakPoolBuffer(buffer))
        }
        poolBufferHighWaterMark = max(poolBufferHighWaterMark, poolBuffers.count)
    }

    #if DEBUG
    func ensurePoolForTesting(width: Int, height: Int, format: DoviFelChromaFormat = .yuv420) -> CVPixelBufferPool? {
        ensurePool(width: width, height: height, format: format)
    }

    /// One allocation from the output pool: `reserve: false` stops at the threshold, `true` draws on the reserve
    /// above it, as `encodeCompose` does once the threshold refuses.
    func createOutputBufferForTesting(pool: CVPixelBufferPool, reserve: Bool = false) -> (status: CVReturn, buffer: CVPixelBuffer?) {
        var buf: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            reserve ? Self.poolReserveAuxAttributes : Self.poolAuxAttributes,
            &buf
        )
        if status == kCVReturnSuccess, let buf { recordPoolBuffer(buf, pool: pool) }
        return (status, buf)
    }
    #endif

    // MARK: - Texture Extraction

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        keepAlive: inout [CVMetalTexture]
    ) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            plane,
            &cvTex
        )
        guard status == kCVReturnSuccess, let validCvTex = cvTex else {
            return nil
        }
        keepAlive.append(validCvTex)
        return CVMetalTextureGetTexture(validCvTex)
    }

    // MARK: - Frame Composition

    /// Reconstructs the VDR master from BL and EL pixel buffers, returning a
    /// 10-bit video-range P010 CVPixelBuffer.
    ///
    /// Blocks the calling thread until the GPU is done. That is what an offline
    /// caller wants — a probe, a unit test, `aetherctl` — but it is the wrong
    /// shape for playback, where the wait lands on the decode thread and stops
    /// decode(N+1) from overlapping GPU(N). Playback uses
    /// ``composeAsync(baseBuffer:enhancementBuffer:params:frameIndex:completion:)``.
    func compose(
        baseBuffer: CVPixelBuffer,
        enhancementBuffer: CVPixelBuffer,
        params: DoviMetalParams,
        frameIndex: UInt32 = 0
    ) -> CVPixelBuffer? {
        // Takes an in-flight slot like `composeAsync`, so a parameter slot is never taken outside the semaphore
        // that bounds them. Only tests, `aetherctl` and probes call this; playback uses `composeAsync`.
        acquireSlot()
        defer { releaseInFlightSlot() }
        guard let work = encodeCompose(baseBuffer: baseBuffer,
                                       enhancementBuffer: enhancementBuffer,
                                       params: params,
                                       frameIndex: frameIndex) else {
            return nil
        }
        defer { returnParamSlot(work.paramSlot) }
        work.commandBuffer.commit()
        work.commandBuffer.waitUntilCompleted()
        if let failure = Self.commandBufferFailure(work.commandBuffer, forced: forcedCommandBufferFailure.withLock { $0 }) {
            // The GPU did not finish writing the destination: it is not a frame, so no frame is returned.
            Self.logOnce("[DoviFelComposer] Command buffer error: \(failure)")
            return nil
        }
        _ = work.keepAlive
        // Colour attachments are copied in `encodeCompose`, at encode time on
        // this calling thread — nothing left to do here.
        return work.destination
    }

    /// Test seam: makes every command buffer count as failed, so a test can drive the failure path without
    /// a GPU fault. Read once per command buffer; a plain unfair lock, never held across anything.
    let forcedCommandBufferFailure = OSAllocatedUnfairLock(initialState: false)

    /// The command buffer's error, as text, or nil when it completed cleanly.
    private static func commandBufferFailure(_ cb: MTLCommandBuffer, forced: Bool) -> String? {
        forced ? "forced failure (test)" : cb.error?.localizedDescription
    }

    /// Same composition, without blocking the caller on the GPU.
    ///
    /// `completion` is invoked exactly once — off the calling thread once the
    /// command buffer retires, or inline with nil if the frame could not be set
    /// up at all. The GPU's writes are complete before it fires, so the buffer
    /// it hands over is safe to enqueue for display.
    ///
    /// At most ``maxFramesInFlight`` compositions are outstanding on the GPU; a
    /// caller that runs further ahead than that blocks here until one retires.
    /// That is the backpressure that keeps the pixel buffer pool from growing
    /// without bound, and it is deliberately the decode thread that absorbs it.
    /// The slot is released when the command buffer retires rather than when
    /// `completion` returns, so a slow consumer can leave at most
    /// ``maxFramesInFlight`` further frames queued for delivery behind it. That
    /// asymmetry is required, not incidental: releasing the slot from the
    /// delivery side would put the signal behind the caller's own lock.
    func composeAsync(
        baseBuffer: CVPixelBuffer,
        enhancementBuffer: CVPixelBuffer,
        params: DoviMetalParams,
        frameIndex: UInt32 = 0,
        completion: @escaping @Sendable (CVPixelBuffer?) -> Void
    ) {
        acquireSlot()
        composeAsyncWithAcquiredSlot(
            baseBuffer: baseBuffer,
            enhancementBuffer: enhancementBuffer,
            params: params,
            frameIndex: frameIndex,
            completion: completion
        )
    }

    /// Blocks until one of ``maxFramesInFlight`` compositions is free.
    ///
    /// dolby-vision-fel.md §5.6: the decoder calls this with no lock held, on the
    /// VideoToolbox output thread that produced the `compose` action, so the
    /// backpressure lands on that thread instead of stalling `deliver`, the
    /// other layer's callback, `flush()` and `close()` behind the decoder lock.
    func acquireSlot() {
        inFlight.wait()
        slotLock.lock()
        activeSlotsInUse += 1
        if activeSlotsInUse > peakSlotsInUse {
            peakSlotsInUse = activeSlotsInUse
        }
        slotLock.unlock()
    }

    /// Releases one in-flight slot. Only for callers that acquired with
    /// ``acquireSlot()`` and then failed before reaching
    /// ``composeAsyncWithAcquiredSlot(baseBuffer:enhancementBuffer:params:frameIndex:completion:)``.
    func releaseSlot() {
        releaseInFlightSlot()
    }

    private func releaseInFlightSlot() {
        slotLock.lock()
        if activeSlotsInUse > 0 {
            activeSlotsInUse -= 1
        }
        slotLock.unlock()
        inFlight.signal()
    }

    /// Reads and resets the peak slot count for the 1 Hz summary (dolby-vision-fel.md §5.11).
    func takePeakSlotsInUse() -> Int {
        slotLock.lock()
        defer { slotLock.unlock() }
        let peak = peakSlotsInUse
        peakSlotsInUse = activeSlotsInUse
        return peak
    }

    private func takeParamSlot() -> Int? {
        slotLock.lock()
        defer { slotLock.unlock() }
        guard !freeParamSlotIndices.isEmpty else { return nil }
        return freeParamSlotIndices.removeLast()
    }

    private func returnParamSlot(_ slot: Int) {
        slotLock.lock()
        freeParamSlotIndices.append(slot)
        slotLock.unlock()
    }

    /// Same composition, assuming the caller already holds a slot from
    /// ``acquireSlot()``. The slot is released when the command buffer retires
    /// (or inline with `completion(nil)` when the frame cannot be set up).
    func composeAsyncWithAcquiredSlot(
        baseBuffer: CVPixelBuffer,
        enhancementBuffer: CVPixelBuffer,
        params: DoviMetalParams,
        frameIndex: UInt32 = 0,
        completion: @escaping @Sendable (CVPixelBuffer?) -> Void
    ) {
        startComposeAsync(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer, params: params,
                          frameIndex: frameIndex, inPlace: false) { buffer, _ in completion(buffer) }
    }

    /// The shared body of the two asynchronous entry points. `finish` gets the composed buffer, or nil with
    /// `corrupt` telling whether the base-layer buffer was already being written when the frame failed (only
    /// ever true in place, where the destination is the base-layer buffer itself).
    private func startComposeAsync(
        baseBuffer: CVPixelBuffer,
        enhancementBuffer: CVPixelBuffer,
        params: DoviMetalParams,
        frameIndex: UInt32,
        inPlace: Bool,
        finish completion: @escaping @Sendable (CVPixelBuffer?, _ corrupt: Bool) -> Void
    ) {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: "Compose", signpostID: signpostID,
                    "frame=%{public}u", frameIndex)
        guard let work = encodeCompose(baseBuffer: baseBuffer,
                                       enhancementBuffer: enhancementBuffer,
                                       params: params,
                                       frameIndex: frameIndex,
                                       inPlace: inPlace) else {
            os_signpost(.end, log: Self.signpostLog, name: "Compose", signpostID: signpostID, "encode-failed")
            if inPlace { endInPlace(baseBuffer, composed: false, started: false) }
            releaseInFlightSlot()
            completion(nil, false)
            return
        }
        // `textures` holds the CVMetalTextures; the source buffers are held
        // alongside them because a CVMetalTexture is not documented to keep the
        // pixel buffer it was made from alive, and the GPU reads both until the
        // command buffer retires. Boxed because CoreVideo's types are not
        // `Sendable` and this crosses two queues: CoreVideo buffers are
        // themselves thread-safe, and only one queue touches the box at a time.
        let frame = ComposedFrame(destination: work.destination,
                                  source: baseBuffer,
                                  enhancement: enhancementBuffer,
                                  textures: work.keepAlive,
                                  cache: textureCache)
        // Captured as a value, not through `self?.`, before the handler below is
        // even built: the whole point of `deliveryQueue` is that calling
        // `completion` never depends on the composer still being alive, so there
        // is no `self?.deliveryQueue ?? .global()`-shaped fallback to reach for
        // if it were. `DispatchQueue` is a plain `Sendable`
        // reference, so this costs nothing.
        let deliveryQueue = self.deliveryQueue
        let paramSlot = work.paramSlot
        // Held strongly so it outlives a composer that is released mid-flight: libdispatch traps
        // if a semaphore is destroyed below its initial count, and `self` is weak in the handler.
        let inFlightSemaphore = self.inFlight
        let forcedFailure = self.forcedCommandBufferFailure
        work.commandBuffer.addCompletedHandler { [weak self] cb in
            // Metal runs these handlers on ONE serial queue per command queue, so
            // this block must never take a lock the caller above might be holding
            // and must never block (dolby-vision-fel.md §4.3). The caller is inside
            // `inFlight.wait()` while it holds the decoder's lock, and a `completion`
            // that reached for that same lock would block here, which would
            // stop every LATER handler from running, and one of those is the
            // signal the caller is waiting for. Signalling first only defers that
            // by a frame - it deadlocked on device after ~10s of playback.
            //
            // So: release the slot inline — nothing below this line can block —
            // then hop to `deliveryQueue` for everything else, `completion`
            // included, so Metal's shared queue never waits on it no matter what
            // it does. In production `completion` is `DualLayerVideoDecoder.
            // runCompose`'s closure, itself just a `queue.async` into
            // `OrderedDelivery.fulfil`, so this hop is normally a hand-off from
            // one non-blocking queue to another; `DoviComposeAsyncTests.
            // doesNotDeadlockAgainstTheCallersLock` is what this hop exists for —
            // it hands `composeAsync` a `completion` that deliberately blocks on
            // a lock the caller holds, and only survives because that block runs
            // off Metal's queue.
            //
            // This event marks the instant
            // Metal actually invoked this handler — i.e. "GPU retired" —
            // distinct from the "Compose" interval's `.end`, which only
            // fires later, after the hop below has run. Without it, nothing
            // in the signposts brackets the hand-off from Metal's queue to
            // `deliveryQueue` on its own: Instruments could see "Compose"
            // ran long but not whether that was GPU time or queueing delay
            // hopping to the relay. It has to be the very first thing here,
            // ahead of even `inFlight.signal()`, so it costs nothing on the
            // must-never-block path (`os_signpost` does not block) and is
            // not itself delayed by anything below it.
            os_signpost(.event, log: Self.signpostLog, name: "Compose", signpostID: signpostID, "metal-completion-fired")
            if let strongSelf = self {
                strongSelf.returnParamSlot(paramSlot)
                strongSelf.releaseInFlightSlot()
            } else {
                inFlightSemaphore.signal()
            }
            // Everything the hop needs pulled out of `cb` here, as plain
            // Sendable values: `cb` itself is `any MTLCommandBuffer`, not
            // Sendable, so it cannot cross into `deliveryQueue.async`'s
            // closure directly, and `self` is captured once, strongly, into a
            // fresh local rather than referenced from inside the nested
            // closure (which is what the "captured var 'self' in
            // concurrently-executing code" warning was about).
            let errorDescription = Self.commandBufferFailure(cb, forced: forcedFailure.withLock { $0 })
            let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            let composer = self
            deliveryQueue.async {
                if let errorDescription {
                    Self.logOnce("[DoviFelComposer] Command buffer error: \(errorDescription)")
                }
                composer?.recordGPUTime(ms: gpuMs)
                os_signpost(.end, log: Self.signpostLog, name: "Compose", signpostID: signpostID)
                if inPlace { composer?.endInPlace(frame.destination, composed: errorDescription == nil, started: true) }
                // A command buffer that errored leaves the destination partly written. With a pool buffer the
                // caller falls back to the base layer instead of showing garbage. In place the destination
                // is the base layer, so there is nothing clean to fall back to and `corrupt` says so.
                completion(errorDescription == nil ? frame.destination : nil, errorDescription != nil && inPlace)
                frame.release()
            }
        }
        work.commandBuffer.commit()
    }

    /// Compositions allowed to be outstanding at once. Sized against the pool's
    /// `kCVPixelBufferPoolMinimumBufferCountKey` so a full pipeline still draws
    /// from the preallocated set rather than growing the pool.
    static let maxFramesInFlight = 3
    /// Buffers the output pool allocates in normal running; past it `encodeCompose` draws on
    /// `outputPoolReserve`, and only with that spent too does a frame bypass to the base layer
    /// (dolby-vision-fel.md §5.6, §5.10).
    ///
    /// Derived from the renderer's look-ahead cap, not a second constant to keep in step: when decode
    /// outruns the clock the gate holds the look-ahead at its limit, and the pool then holds that many
    /// frames plus the one on screen, the one the display layer retains, and the compositions in flight.
    ///
    /// The margin is built from those holders: the one on screen, the one the layer retains,
    /// `maxFramesInFlight` compositions, and one spare. A smaller margin let a burst of in-flight compositions
    /// on top of a full look-ahead exhaust the pool (CoreVideo -6689) and fall back to the base layer.
    /// A 4K P010 buffer is about 25 MB, so the threshold is about 375 MB.
    private static let residualSwitch = OSAllocatedUnfairLock(initialState: true)

    /// Whether the enhancement-layer residual (EL fetch + NLQ) is applied. Off, the composer still maps the
    /// base layer through the RPU curves, which is what a minimal enhancement layer (MEL) stream decodes
    /// to; on, it is the full FEL result. Exists for A/B viewing (`aetherctl play --cycle-el`); it takes
    /// effect from the next composed frame and applies to every composer in the process. Default on.
    static var residualEnabled: Bool {
        get { residualSwitch.withLock { $0 } }
        set { residualSwitch.withLock { $0 = newValue } }
    }

    static let outputPoolAllocationThreshold = SampleBufferRenderer.felVideoLookaheadFrames + 2 + maxFramesInFlight + 1
    nonisolated(unsafe) private static let poolAuxAttributes: CFDictionary = [
        kCVPixelBufferPoolAllocationThresholdKey: outputPoolAllocationThreshold
    ] as CFDictionary
    /// Buffers the pool may grow by when the threshold refuses one. A refused buffer means a base-layer
    /// frame, a visible brightness step on real titles (`fallbackFrameDelta`); a burst composes into one of
    /// these instead. They return to the pool like any other and `kCVPixelBufferPoolMaximumBufferAgeKey`
    /// frees them after a second unused, so the extra memory (about 25 MB each at 4K) lasts only as long as the
    /// burst. Sized like the in-flight limit, the holder a burst's shortfall came from on the titles measured.
    static let outputPoolReserve = maxFramesInFlight
    /// With the pool and its reserve both refused, the composer retries this many times, sleeping
    /// `outputPoolRetryInterval` between attempts (never after the last): at most 9 x 4 ms, about 36 ms.
    static let outputPoolAttempts = 10
    static let outputPoolRetryInterval: TimeInterval = 0.004
    nonisolated(unsafe) private static let poolReserveAuxAttributes: CFDictionary = [
        kCVPixelBufferPoolAllocationThresholdKey: outputPoolAllocationThreshold + outputPoolReserve
    ] as CFDictionary
    private let inFlight = DispatchSemaphore(value: DoviFelComposer.maxFramesInFlight)
    private let slotLock = NSLock()
    private var activeSlotsInUse: Int = 0
    private var peakSlotsInUse: Int = 0

    /// Exists for exactly one reason (dolby-vision-fel.md §4.3): Metal runs every
    /// `addCompletedHandler` block for a command queue on **one serial queue**,
    /// so a `completion` closure that blocks — on a caller's lock, or on
    /// anything else — would stall every later handler too, including the
    /// `inFlight.signal()` a different, currently-blocked caller is waiting on.
    /// `DoviComposeAsyncTests.doesNotDeadlockAgainstTheCallersLock` reproduces
    /// that shape directly against `composeAsync`, independent of anything
    /// `DualLayerVideoDecoder`/`OrderedDelivery` promise about their own
    /// callback never blocking — this queue is what makes the composer safe
    /// against a slow or badly-behaved `completion` on its own terms.
    ///
    /// This is not a second ordering mechanism: this queue carries no
    /// ordering responsibility at all (`OrderedDelivery` reorders by ticket
    /// regardless of which thread calls `fulfil`), it only gets `completion`
    /// off Metal's queue. It runs at `qos: .userInteractive`, and it is
    /// captured as a plain value below, never through `self?.`, so there is
    /// no unordered `.global()` fallback to reach for.
    private let deliveryQueue = DispatchQueue(label: "de.superuser404.dovi.compose-delivery", qos: .userInteractive)

    /// One composition's CoreVideo objects, kept alive from encode until the
    /// completion has run. `@unchecked Sendable` for the reason given at its
    /// construction site in `composeAsync`.
    private final class ComposedFrame: @unchecked Sendable {
        let destination: CVPixelBuffer
        private var source_: CVPixelBuffer?
        private var enhancement_: CVPixelBuffer?
        private var textures_: [CVMetalTexture]?
        /// A `CVMetalTexture` calls back into its cache when it finalizes and does not
        /// retain it, so the cache has to outlive the textures. Without this a composer
        /// released while a command buffer was in flight crashed in
        /// `CVMetalTextureCache::bufferBackingNotInUse`.
        private var cache_: CVMetalTextureCache?

        var source: CVPixelBuffer { source_! }

        init(destination: CVPixelBuffer, source: CVPixelBuffer,
             enhancement: CVPixelBuffer, textures: [CVMetalTexture],
             cache: CVMetalTextureCache?) {
            self.destination = destination
            self.cache_ = cache
            self.source_ = source
            self.enhancement_ = enhancement
            self.textures_ = textures
        }

        /// Drops the inputs once the consumer has the output. Explicit so the
        /// lifetime is a statement rather than a `_ =` that a later edit can
        /// delete without noticing what it was holding up.
        func release() {
            source_ = nil
            enhancement_ = nil
            textures_ = nil
            cache_ = nil
        }
    }

    private struct EncodedFrame {
        let commandBuffer: MTLCommandBuffer
        let destination: CVPixelBuffer
        let keepAlive: [CVMetalTexture]
        let paramSlot: Int
    }

    /// Everything up to (not including) `commit`: pool rental (or, in place, none), texture binding,
    /// parameter upload and the two dispatches.
    ///
    /// `inPlace` writes the result into `baseBuffer` itself. Nothing is written by this function (the GPU
    /// writes only after the caller commits), so a nil return always means the base-layer buffer is untouched.
    private func encodeCompose(
        baseBuffer: CVPixelBuffer,
        enhancementBuffer: CVPixelBuffer,
        params: DoviMetalParams,
        frameIndex: UInt32,
        inPlace: Bool = false
    ) -> EncodedFrame? {
        let blW = CVPixelBufferGetWidth(baseBuffer)
        let blH = CVPixelBufferGetHeight(baseBuffer)
        let elW = CVPixelBufferGetWidth(enhancementBuffer)
        let elH = CVPixelBufferGetHeight(enhancementBuffer)

        guard blW > 0, blH > 0, elW > 0, elH > 0 else { return nil }
        // Chroma is subsampled by two and rounds up: an odd luma size still has a last chroma column/row.
        let blCW = (blW + 1) / 2, blCH = (blH + 1) / 2
        let elCW = (elW + 1) / 2, elCH = (elH + 1) / 2

        // The output's chroma sampling. Only the 4:2:0 base layer can be composed into, so in place is 4:2:0 only.
        let format = chromaFormat
        if inPlace, format != .yuv420 { return nil }
        let (outCW, outCH) = format.chromaSize(width: blW, height: blH)

        // The destination is either a buffer rented from the output pool, or the base-layer buffer itself.
        // In place the pool is not asked for, so it is not created unless a frame is refused for in-place
        // (for example a luma MMR curve).
        let dst: CVPixelBuffer
        if inPlace {
            guard !isTornDown else { return nil }
            dst = baseBuffer
        } else {
            guard let pool = ensurePool(width: blW, height: blH, format: format) else { return nil }
            guard let rented = rentOutputBuffer(from: pool) else { return nil }
            dst = rented
            // Colour attachments are metadata, not pixels: copying them now, on
            // this calling thread, rather than from Metal's completion handler
            // (dolby-vision-fel.md §5.6) is safe because `dst` is not handed to anyone
            // until the command buffer this function's caller commits has
            // retired — nothing reads `dst` early just because its attachments
            // are set before the GPU has written its pixels.
            propagateColorAttachments(from: baseBuffer, to: dst)
        }

        var keepAliveTextures: [CVMetalTexture] = []

        // Plane 0 is luma, plane 1 is interleaved chroma. The integer planes are
        // bound as Uint so the kernels see raw code values; the enhancement layer
        // is bound as Unorm because it is upsampled by the hardware bilinear sampler.
        guard let blYTex = makeTexture(from: baseBuffer, plane: 0, format: .r16Uint, width: blW, height: blH, keepAlive: &keepAliveTextures),
              let blUvTex = makeTexture(from: baseBuffer, plane: 1, format: .rg16Uint, width: blCW, height: blCH, keepAlive: &keepAliveTextures),
              let elYTex = makeTexture(from: enhancementBuffer, plane: 0, format: .r16Unorm, width: elW, height: elH, keepAlive: &keepAliveTextures),
              let elUvTex = makeTexture(from: enhancementBuffer, plane: 1, format: .rg16Unorm, width: elCW, height: elCH, keepAlive: &keepAliveTextures) else {
            return nil
        }
        // In place the output planes are the base-layer planes: the same textures, bound a second time.
        let outYTex: MTLTexture
        let outUvTex: MTLTexture
        if inPlace {
            outYTex = blYTex
            outUvTex = blUvTex
        } else {
            guard let y = makeTexture(from: dst, plane: 0, format: .r16Uint, width: blW, height: blH, keepAlive: &keepAliveTextures),
                  let uv = makeTexture(from: dst, plane: 1, format: .rg16Uint, width: outCW, height: outCH, keepAlive: &keepAliveTextures) else {
                return nil
            }
            outYTex = y
            outUvTex = uv
        }

        var metalParams = params
        metalParams.blWidth = UInt32(blW)
        metalParams.blHeight = UInt32(blH)
        metalParams.elWidth = UInt32(elW)
        metalParams.elHeight = UInt32(elH)
        metalParams.frameIndex = frameIndex
        metalParams.polyY.clampToCapacity()
        metalParams.polyCb.clampToCapacity()
        metalParams.polyCr.clampToCapacity()

        // The in-place order below depends on luma never reading chroma. A luma MMR curve does, and
        // `canComposeInPlace` sends such frames down the pool path; this is the same check one more time
        // where it would do harm, so a caller that skipped the question cannot get a wrong picture.
        if inPlace, metalParams.flags.contains(.lumaMmr) { return nil }

        guard let pipelines = ensurePipelines() else { return nil }
        let chromaPipeline = pipelines.pipeline(for: format)

        guard let paramSlot = takeParamSlot() else { return nil }
        let paramBuffer = paramBuffers[paramSlot]
        let rawBuffer = UnsafeMutableRawBufferPointer(start: paramBuffer.contents(), count: DoviMetalParams.serializedSize)
        var serialized = metalParams
        if !Self.residualEnabled { serialized.flags.insert(.disableResidual) }
        serialized.serialize(into: rawBuffer)

        let lutBuffer = lumaLutBuffers[paramSlot]
        populateLumaLut(into: lutBuffer.contents().assumingMemoryBound(to: Float.self), params: metalParams)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            returnParamSlot(paramSlot)
            return nil
        }

        // Pool path: both passes go in one concurrent encoder. Luma reads BL luma + BL
        // chroma (a luma MMR curve would need it) and the EL luma; chroma reads
        // BL luma + BL chroma and the EL chroma. Neither reads what the other
        // writes — `outYTex` and `outUvTex` are separate planes — so the barrier
        // Metal puts between two serial encoders buys nothing and costs a full
        // GPU sync point per frame.
        //
        // In place the two passes do depend on each other, and the order matters. The chroma pass reads
        // the base-layer luma around each chroma sample (a neighbourhood, so other threads' pixels), but only
        // its own chroma sample. The luma pass reads only its own luma sample (chroma only for a luma MMR
        // curve, which is excluded above). So chroma goes first, while all the luma is still the decoded
        // base layer, and each chroma thread overwrites only the chroma sample it has just read. Luma goes
        // second, and each luma thread overwrites only the luma sample it has just read; nothing reads
        // luma any more. That needs no scratch buffer. The serial encoder and the barrier between
        // the passes make the second wait for the first.
        let encoderType: MTLDispatchType = inPlace ? .serial : .concurrent
        guard let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: encoderType) else {
            returnParamSlot(paramSlot)
            return nil
        }

        func encodeLuma() {
            encoder.setComputePipelineState(pipelines.lumaPipeline)
            encoder.setTexture(blYTex, index: 0)
            encoder.setTexture(blUvTex, index: 1)
            encoder.setTexture(elYTex, index: 2)
            encoder.setTexture(outYTex, index: 3)
            encoder.setBuffer(paramBuffer, offset: 0, index: 0)
            encoder.setBuffer(lutBuffer, offset: 0, index: 1)
            dispatch(encoder, width: blW, height: blH,
                     threadgroup: threadgroupSize(for: pipelines.lumaPipeline))
        }
        func encodeChroma() {
            encoder.setComputePipelineState(chromaPipeline)
            encoder.setTexture(blYTex, index: 0)
            encoder.setTexture(blUvTex, index: 1)
            encoder.setTexture(elUvTex, index: 2)
            encoder.setTexture(outUvTex, index: 3)
            encoder.setBuffer(paramBuffer, offset: 0, index: 0)
            dispatch(encoder, width: outCW, height: outCH,
                     threadgroup: format == .yuv444 ? Self.chroma444Threadgroup : threadgroupSize(for: chromaPipeline))
        }

        if inPlace {
            encodeChroma()
            encoder.memoryBarrier(scope: .textures)
            encodeLuma()
        } else {
            encodeLuma()
            encodeChroma()
        }

        encoder.endEncoding()

        if inPlace { Self.removeNonPropagatingAttachments(from: dst) }

        return EncodedFrame(commandBuffer: commandBuffer, destination: dst, keepAlive: keepAliveTextures, paramSlot: paramSlot)
    }

    /// Takes a buffer from the output pool, drawing on the reserve and retrying briefly when the pool is full.
    private func rentOutputBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        // A base-layer frame is NOT close to the composed one on real titles: measured on the three
        // real FEL files its 10-bit luma differs by a mean of ~8 codes (p99 up to 230) on two and ~79
        // on clip C (`fallbackFrameDelta`), a visible brightness step. So when the threshold
        // refuses, take a buffer from the reserve above it rather than wait. Only with the reserve
        // spent too, wait briefly, but never long: on device a 300 ms wait stalled the
        // VideoToolbox callback, then the demux loop, starving audio into 7 rebuffers in a minute.
        var outBuffer: CVPixelBuffer?
        var poolStatus = kCVReturnError
        for attempt in 0..<Self.outputPoolAttempts {
            for aux in [Self.poolAuxAttributes, Self.poolReserveAuxAttributes] {
                poolStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux, &outBuffer)
                if poolStatus != kCVReturnWouldExceedAllocationThreshold { break }
            }
            if poolStatus != kCVReturnWouldExceedAllocationThreshold { break }
            if attempt < Self.outputPoolAttempts - 1 { Thread.sleep(forTimeInterval: Self.outputPoolRetryInterval) }
        }
        guard poolStatus == kCVReturnSuccess, let dst = outBuffer else {
            EngineLog.emit("[DoviFelComposer] output pool refused a buffer (status \(poolStatus)); frame falls back to the base layer", category: .swPlayback, level: .verbose)
            return nil
        }
        recordPoolBuffer(dst, pool: pool)
        return dst
    }

    // MARK: - In-place composition

    /// Why a base-layer buffer is not composed in place (it goes through the output pool instead).
    enum InPlaceRefusal: Equatable, Sendable {
        case switchedOff
        case tornDown
        case outputChroma
        case notIOSurfaceBacked
        case notX420
        case planeLayout
        case lumaMmr
    }

    /// Decides whether `baseBuffer` can be the compose target. Pure apart from reading the buffer's
    /// description; nothing is changed.
    ///
    /// All of these must hold: the switch is on; the buffer is IOSurface-backed (the GPU can only write
    /// those through a texture); its format is the 10-bit biplanar video-range layout the kernels write
    /// (`x420`, the same as a pool buffer); the planes are the luma size and the half-size interleaved chroma
    /// (even dimensions), which is what the composed output has; and the frame has no luma MMR curve (that
    /// curve reads the chroma that the in-place order overwrites first). Anything else gets the pool path,
    /// unchanged.
    func inPlaceDecision(baseBuffer: CVPixelBuffer, params: DoviMetalParams) -> InPlaceRefusal? {
        lock.lock()
        let enabled = inPlaceEnabled
        let torn = tornDown
        let format = chromaFormatStorage
        lock.unlock()
        if !enabled { return .switchedOff }
        if torn { return .tornDown }
        if format != .yuv420 { return .outputChroma }
        return Self.inPlaceRefusal(baseBuffer: baseBuffer, params: params)
    }

    /// The buffer-and-frame part of ``inPlaceDecision(baseBuffer:params:)``, without composer state.
    static func inPlaceRefusal(baseBuffer: CVPixelBuffer, params: DoviMetalParams) -> InPlaceRefusal? {
        guard CVPixelBufferGetIOSurface(baseBuffer) != nil else { return .notIOSurfaceBacked }
        guard CVPixelBufferGetPixelFormatType(baseBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
            return .notX420
        }
        let w = CVPixelBufferGetWidth(baseBuffer)
        let h = CVPixelBufferGetHeight(baseBuffer)
        guard w > 0, h > 0, w % 2 == 0, h % 2 == 0,
              CVPixelBufferGetPlaneCount(baseBuffer) == 2,
              CVPixelBufferGetWidthOfPlane(baseBuffer, 0) == w, CVPixelBufferGetHeightOfPlane(baseBuffer, 0) == h,
              CVPixelBufferGetWidthOfPlane(baseBuffer, 1) == w / 2, CVPixelBufferGetHeightOfPlane(baseBuffer, 1) == h / 2
        else { return .planeLayout }
        if params.flags.contains(.lumaMmr) { return .lumaMmr }
        return nil
    }

    /// True when ``composeInPlaceAsyncWithAcquiredSlot(baseBuffer:enhancementBuffer:params:frameIndex:completion:)``
    /// may be used for this frame.
    func canComposeInPlace(baseBuffer: CVPixelBuffer, params: DoviMetalParams) -> Bool {
        inPlaceDecision(baseBuffer: baseBuffer, params: params) == nil
    }

    /// What an in-place composition did to the base-layer buffer.
    enum InPlaceResult: Sendable, Equatable {
        /// The base-layer buffer now holds the composed frame.
        case composed
        /// The frame could not be set up and nothing was written: the buffer still holds the base layer, which
        /// is the same fallback a failed pool composition gets.
        case baseIntact
        /// The GPU started writing and then failed: the buffer holds a mix of base layer and composed pixels. It
        /// must not be shown; the frame is dropped. A second request for a buffer that is already being
        /// composed in place gets this too: it is dropped and counted as lost, not sent to the pool path
        /// (a pool compose would read pixels the first composition is still writing).
        case baseCorrupted
    }

    /// Composes into `baseBuffer` itself, assuming the caller holds a slot from ``acquireSlot()``. The caller
    /// must have asked ``canComposeInPlace(baseBuffer:params:)`` first.
    ///
    /// The base-layer buffer is exclusive to this composition from here until `completion` runs: the
    /// decoder hands it over when it pairs the frame and keeps no other reference that reads pixels,
    /// the buffer is delivered to the renderer only from `completion`, and the composer refuses a second
    /// composition of the same buffer while the first is outstanding. A frame is never composed twice:
    /// nothing retries after a failure, because the failed buffer is dropped.
    func composeInPlaceAsyncWithAcquiredSlot(
        baseBuffer: CVPixelBuffer,
        enhancementBuffer: CVPixelBuffer,
        params: DoviMetalParams,
        frameIndex: UInt32 = 0,
        completion: @escaping @Sendable (InPlaceResult) -> Void
    ) {
        guard beginInPlace(baseBuffer) else {
            EngineLog.emit("[DoviFelComposer] in-place compose refused: the buffer is already being composed; frame dropped", category: .swPlayback)
            releaseInFlightSlot()
            completion(.baseCorrupted)
            return
        }
        startComposeAsync(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer, params: params,
                          frameIndex: frameIndex, inPlace: true) { buffer, corrupt in
            completion(buffer != nil ? .composed : (corrupt ? .baseCorrupted : .baseIntact))
        }
    }

    /// Claims `buffer` for an in-place composition; false when one is already outstanding on it.
    private func beginInPlace(_ buffer: CVPixelBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inPlaceInFlight.insert(ObjectIdentifier(buffer)).inserted
    }

    /// Releases the claim. `started` is whether the command buffer was committed (so the buffer may have been
    /// written to); a failure after that is a lost frame.
    private func endInPlace(_ buffer: CVPixelBuffer, composed: Bool, started: Bool) {
        lock.lock()
        inPlaceInFlight.remove(ObjectIdentifier(buffer))
        if composed {
            inPlaceComposedCount += 1
        } else if started {
            inPlaceLostCount += 1
        }
        lock.unlock()
    }

    /// Frames composed into their base-layer buffer so far (for the 1 Hz summary).
    var inPlaceComposedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return inPlaceComposedCount
    }

    /// Frames dropped because the GPU failed after it had started writing into the base-layer buffer.
    var inPlaceLostFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return inPlaceLostCount
    }

    private var isTornDown: Bool {
        lock.lock(); defer { lock.unlock() }
        return tornDown
    }

    #if DEBUG
    /// Test seam: claims a buffer the way an outstanding in-place composition does, and gives it back.
    func claimInPlaceForTesting(_ buffer: CVPixelBuffer) -> Bool { beginInPlace(buffer) }
    func releaseInPlaceClaimForTesting(_ buffer: CVPixelBuffer) { endInPlace(buffer, composed: false, started: false) }
    #endif

    /// Turns the in-place path on or off for this composer (A/B runs and tests). From the next frame on.
    var inPlaceComposeEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return inPlaceEnabled }
        set { lock.lock(); inPlaceEnabled = newValue; lock.unlock() }
    }

    /// The chroma sampling composed frames are written in. Frames already in flight keep the format they
    /// were started with.
    var chromaFormat: DoviFelChromaFormat {
        get { lock.lock(); defer { lock.unlock() }; return chromaFormatStorage }
        set { lock.lock(); chromaFormatStorage = newValue; lock.unlock() }
    }

    /// Whether the output pool exists. In-place playback must leave it absent.
    var hasOutputPool: Bool {
        lock.lock(); defer { lock.unlock() }
        return pixelBufferPool != nil
    }

    /// Removes the attachments that do not propagate from `buffer`. A pool buffer gets only the base layer's
    /// propagating attachments (`CVBufferPropagateAttachments`), so this makes the in-place buffer carry
    /// the same set. Decoder-private per-buffer notes are the kind of thing that does not propagate.
    private static func removeNonPropagatingAttachments(from buffer: CVPixelBuffer) {
        guard let local = CVBufferCopyAttachments(buffer, .shouldNotPropagate) as? [CFString: Any] else { return }
        for key in local.keys { CVBufferRemoveAttachment(buffer, key) }
    }

    /// Precomputes the 1024-entry luma prediction table when luma is polynomial (dolby-vision-fel.md §5.6).
    private func populateLumaLut(into ptr: UnsafeMutablePointer<Float>, params: DoviMetalParams) {
        let poly = params.polyY
        let blMax = Float(params.blMax) + 1   // normalise by 2^bits, as the kernels do
        guard poly.numPivots >= 2 else {
            for code in 0..<1024 {
                ptr[code] = Float(code) / blMax
            }
            return
        }

        let numPivots = Int(poly.numPivots)
        let lastPiece = numPivots - 2
        let lo = Int(poly.pivots[0])
        let hi = Int(poly.pivots[numPivots - 1])

        for code in 0..<1024 {
            var piece = 0
            for i in 0...lastPiece {
                if code >= Int(poly.pivots[i]) {
                    piece = i
                }
            }
            let p = max(0, min(piece, lastPiece))
            let method = (p < DoviPolynomialParams.maxPieces && p < poly.method.count) ? poly.method[p] : DoviMapping.polynomial.rawValue
            if method != DoviMapping.polynomial.rawValue {
                ptr[code] = Float(code) / blMax
                continue
            }

            let clamped = min(max(code, lo), hi)
            let x = Float(clamped) / blMax
            let shift = (p < poly.coefShift.count) ? Int32(poly.coefShift[p]) : 0
            let inv = ldexpf(1.0, -shift)
            let coefs = (p < poly.coef.count) ? poly.coef[p] : [0, 0, 0]
            let c0 = (coefs.count > 0) ? Float(coefs[0]) : 0
            let c1 = (coefs.count > 1) ? Float(coefs[1]) : 0
            let c2 = (coefs.count > 2) ? Float(coefs[2]) : 0

            var pred = c0 * inv
            let order = (p < poly.order.count) ? poly.order[p] : 0
            if order >= 1 {
                pred = fmaf(c1 * inv, x, pred)
            }
            if order >= 2 {
                pred = fmaf(c2 * inv, x * x, pred)
            }
            ptr[code] = pred
        }
    }

    /// The 4:4:4 kernel composes each 4:2:0 site once per threadgroup tile and so needs threadgroups of exactly
    /// this size (`DOVI_444_TILE` in the shader).
    static let chroma444Threadgroup = MTLSize(width: 16, height: 16, depth: 1)

    /// Sizes threadgroups using the pipeline's execution width (dolby-vision-fel.md §5.6).
    private func threadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let w = pipeline.threadExecutionWidth
        let maxThreads = pipeline.maxTotalThreadsPerThreadgroup
        if w >= 32 {
            let h = max(1, min(maxThreads / w, 8))
            return MTLSize(width: w, height: h, depth: 1)
        } else {
            return MTLSize(width: 16, height: 16, depth: 1)
        }
    }

    private func propagateColorAttachments(from baseBuffer: CVPixelBuffer, to dst: CVPixelBuffer) {
        CVBufferPropagateAttachments(baseBuffer, dst)
    }

    // MARK: - GPU Timing

    /// Mean GPU time per composition over the last `gpuTimeWindow` frames, in
    /// milliseconds, or nil before the first window closes.
    ///
    /// The wall-clock cost of a frame is GPU time plus texture binding, pool
    /// rental and encode; only this separates them, which is what says whether
    /// the shaders need work or the CPU side does.
    var meanGPUTimeMs: Double? {
        gpuTimeLock.lock(); defer { gpuTimeLock.unlock() }
        if let gpuTimeMean { return gpuTimeMean }
        if gpuTimeCount > 0 { return gpuTimeAccum / Double(gpuTimeCount) }
        return nil
    }

    private static let gpuTimeWindow = 120
    private let gpuTimeLock = NSLock()
    private var gpuTimeAccum: Double = 0
    private var gpuTimeCount: Int = 0
    private var gpuTimeMean: Double?

    private func recordGPUTime(ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        gpuTimeLock.lock()
        gpuTimeAccum += ms
        gpuTimeCount += 1
        var closed: Double?
        if gpuTimeCount >= Self.gpuTimeWindow {
            closed = gpuTimeAccum / Double(gpuTimeCount)
            gpuTimeMean = closed
            gpuTimeAccum = 0
            gpuTimeCount = 0
        }
        gpuTimeLock.unlock()
        if let closed {
            EngineLog.emit(String(format: "[DoviFelComposer] gpu %.1fms/frame over %d frames",
                                  closed, Self.gpuTimeWindow), category: .swPlayback, level: .verbose)
        }
    }

    // MARK: - Flush & Invalidation

    /// Flushes the texture cache, releasing cached IOSurface-backed Metal textures (dolby-vision-fel.md §5.6).
    func flushTextureCache() {
        lock.lock()
        defer { lock.unlock() }
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    /// Seek/flush: keeps the output pool. Dropping it here made the next frames allocate a second pool while
    /// the renderer still held the old one's buffers (the displayed image and the look-ahead the display layer
    /// had not yet let go of), so the footprint doubled for the half second a seek took to settle (about
    /// +260 MB at 4K, where the pool holds up to 15 buffers of 25 MB). The same pool is capped by the allocation threshold,
    /// so the old buffers return to it as the renderer releases them and the new frames reuse them. Idle
    /// buffers beyond the minimum are released at once.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        if let pool = pixelBufferPool {
            CVPixelBufferPoolFlush(pool, .excessBuffers)
        }
    }

    /// Teardown: drops the pool so its idle buffers go with it, and marks the composer as torn down: every
    /// later composition is refused (`compose` returns nil, `composeAsync` completes with nil and gives its
    /// slot back), so no pool is rebuilt after this. One composer serves one decoder, which is closed once.
    func releaseOutputPool() {
        lock.lock()
        defer { lock.unlock() }
        tornDown = true
        pixelBufferPool = nil
        poolBuffers.removeAll()
        poolBufferHighWaterMark = 0
        poolWidth = 0
        poolHeight = 0
    }

    // MARK: - ABI Layout Probe

    /// Uploads `params` exactly the way ``compose(baseBuffer:enhancementBuffer:params:frameIndex:)``
    /// does and returns the sentinels `dovi_layout_probe` reads back out of it.
    ///
    /// Metal has no `static_assert` and the offline `metal` compiler is not always
    /// installed, so this is how the shader's view of the parameter block gets
    /// checked against ``DoviMetalParams/serialize()`` rather than by hand.
    /// Returns nil when the probe kernel is unavailable.
    func probeLayout(params: DoviMetalParams) -> [UInt32]? {
        guard let pipelines = ensurePipelines(), let pipeline = pipelines.layoutProbePipeline else { return nil }

        let slots = Self.layoutProbeSlots
        guard let outBuffer = device.makeBuffer(length: slots * 4, options: .storageModeShared) else {
            return nil
        }
        memset(outBuffer.contents(), 0, slots * 4)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(pipeline)
        let paramData = params.serialize()
        paramData.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress {
                encoder.setBytes(ptr, length: raw.count, index: 0)
            }
        }
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        dispatch(encoder, width: 1, height: 1,
                 threadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { return nil }

        let ptr = outBuffer.contents().bindMemory(to: UInt32.self, capacity: slots)
        return Array(UnsafeBufferPointer(start: ptr, count: slots))
    }

    /// Covers exactly `width` x `height` threads.
    ///
    /// `dispatchThreads` takes the thread count and splits the edge threadgroups
    /// itself, so the grid is the plane. Rounding the grid up to a multiple of the
    /// threadgroup is the `dispatchThreadgroups` convention, and that is the path
    /// taken where non-uniform threadgroups are unavailable: there the extra
    /// threads are real and the kernels' `gid >= bl_width` guard is what discards
    /// them.
    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        width: Int,
        height: Int,
        threadgroup: MTLSize
    ) {
        guard width > 0, height > 0 else { return }
        if supportsNonUniformThreadgroups {
            encoder.dispatchThreads(
                MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: threadgroup
            )
        } else {
            encoder.dispatchThreadgroups(
                MTLSize(
                    width: (width + threadgroup.width - 1) / threadgroup.width,
                    height: (height + threadgroup.height - 1) / threadgroup.height,
                    depth: 1
                ),
                threadsPerThreadgroup: threadgroup
            )
        }
    }

    // MARK: - RPU Parsing via libdovi

    /// Whether the base and enhancement layers are the 10-bit codes the kernels assume. The kernels read and
    /// write 10-in-16 P010 planes, so a base layer of any other depth would need different texture formats, not
    /// just a new divisor; the enhancement layer is bound as a 10-in-16 plane and the NLQ constants assume a
    /// 10-bit code, so an EL of any other depth would be read at the wrong scale. libdovi 3.4 already rejects
    /// both at parse time, which is why this is separate from the parse and tested directly: the check keeps the
    /// composer safe if a later libdovi stops enforcing it.
    static func layerBitDepthsSupported(bl: Int, el: Int) -> Bool {
        guard bl == 10 else {
            logOnce("[DoviFelComposer] bl_bit_depth \(bl) unsupported; refusing to compose", category: .swPlayback)
            return false
        }
        guard el == 10 else {
            logOnce("[DoviFelComposer] el_bit_depth \(el) unsupported; refusing to compose", category: .swPlayback)
            return false
        }
        return true
    }

    /// Parses an unspec62 RPU NAL into composer parameters.
    ///
    /// Returns nil when the RPU cannot be trusted at all (no header, a
    /// coefficient encoding the kernels do not implement, a bit depth they cannot
    /// address), so the caller presents the base layer rather than a guess. A
    /// single unusable component instead degrades to an identity curve for that
    /// component, which is visually the base layer for that channel and never
    /// flat mid-grey.
    static func parseRpuParameters(rpu: OpaquePointer) -> DoviMetalParams? {
        _parseRpuCount += 1

        if let err = dovi_rpu_get_error(rpu) {
            logOnce("[DoviFelComposer] libdovi error: \(String(cString: err))", category: .swPlayback)
        }

        guard let mapping = dovi_rpu_get_data_mapping(rpu) else {
            logOnce("[DoviFelComposer] dovi_rpu_get_data_mapping returned nil", category: .swPlayback)
            return nil
        }
        defer { dovi_rpu_free_data_mapping(mapping) }

        guard let header = dovi_rpu_get_header(rpu) else {
            logOnce("[DoviFelComposer] dovi_rpu_get_header returned nil; refusing to guess bit depths", category: .swPlayback)
            return nil
        }
        defer { dovi_rpu_free_header(header) }

        var params = DoviMetalParams()

        // coefficient_data_type selects fixed point (0) or 32-bit float (1). Every
        // coefficient below is decoded as (int << denom) + frac, which is only the
        // fixed-point reading, so refuse the float form instead of misreading it.
        let coefDataType = header.pointee.coefficient_data_type
        guard coefDataType == 0 else {
            logOnce("[DoviFelComposer] coefficient_data_type \(coefDataType) is not fixed point; refusing to compose", category: .swPlayback)
            return nil
        }

        let coefLog2DenomRaw = header.pointee.coefficient_log2_denom
        guard coefLog2DenomRaw <= UInt64(maxCoefLog2Denom) else {
            logOnce("[DoviFelComposer] coefficient_log2_denom \(coefLog2DenomRaw) out of range; refusing to compose", category: .swPlayback)
            return nil
        }
        let coefLog2Denom = Int(coefLog2DenomRaw)

        let blBitDepth = Int(header.pointee.bl_bit_depth_minus8) + 8
        let vdrBitDepth = Int(header.pointee.vdr_bit_depth_minus8) + 8
        let elBitDepth = Int(header.pointee.el_bit_depth_minus8) + 8
        guard layerBitDepthsSupported(bl: blBitDepth, el: elBitDepth) else { return nil }
        guard params.setBitDepths(bl: blBitDepth, vdr: vdrBitDepth) else {
            logOnce("[DoviFelComposer] bit depth pair bl=\(blBitDepth) vdr=\(vdrBitDepth) unsupported; refusing to compose", category: .swPlayback)
            return nil
        }

        if header.pointee.disable_residual_flag {
            params.flags.insert(.disableResidual)
        }
        if let elType = header.pointee.el_type, strcmp(elType, "MEL") == 0 {
            // MEL carries no residual by construction: the enhancement layer is a
            // constant mid-grey and only the RPU matters.
            params.flags.insert(.disableResidual)
        }

        // The inverse NLQ product is Q(coefficient_log2_denom) of a normalised
        // residual; this shift brings it into VDR code units. A denominator below
        // the VDR depth would make the shift negative and the whole derivation
        // meaningless, so that disables the residual rather than shifting the
        // other way.
        let nlqShift = UInt32(max(0, coefLog2Denom - vdrBitDepth))
        let nlqMethodIdc = mapping.pointee.nlq_method_idc
        var nlqMethod: DoviNlqMethod = .none
        if coefLog2Denom < vdrBitDepth {
            logOnce("[DoviFelComposer] coefficient_log2_denom \(coefLog2Denom) below vdr_bit_depth \(vdrBitDepth); dropping residual", category: .swPlayback)
        } else if nlqMethodIdc == 0 {
            nlqMethod = .linear
        } else if nlqMethodIdc > 0 {
            logOnce("[DoviFelComposer] nlq_method_idc \(nlqMethodIdc) not implemented; dropping residual", category: .swPlayback)
        }

        // Predicted NLQ pivots are delta-coded like the reshaping pivots.
        var nlqPivots: [UInt32] = [0, params.blMax]
        if mapping.pointee.nlq_pred_pivot_value.len >= 2,
           let pivotData = mapping.pointee.nlq_pred_pivot_value.data {
            let p0 = UInt32(pivotData[0])
            let p1 = p0 + UInt32(pivotData[1])
            nlqPivots = [p0, p1]
        }

        let curves = [mapping.pointee.curves.0, mapping.pointee.curves.1, mapping.pointee.curves.2]
        let labels = ["Y", "Cb", "Cr"]

        for c in 0..<3 {
            var poly = DoviPolynomialParams()
            var mmr = DoviMmrParams()
            if !parseReshapingCurve(
                curves[c],
                coefLog2Denom: coefLog2Denom,
                blMax: params.blMax,
                polyOut: &poly,
                mmrOut: &mmr
            ) {
                // Identity for this component: the base layer passes through
                // unreshaped, which is wrong but recognisable, where a partially
                // filled curve would put a flat value across the plane.
                logOnce("[DoviFelComposer] \(labels[c]) reshaping curve rejected; falling back to identity", category: .swPlayback)
                poly = .identity
                mmr = DoviMmrParams()
            }

            let nlq = parseNlqParams(
                nlq: mapping.pointee.nlq,
                component: c,
                label: labels[c],
                method: nlqMethod,
                coefLog2Denom: coefLog2Denom,
                nlqShift: nlqShift,
                pivots: nlqPivots
            )

            switch c {
            case 0:
                params.polyY = poly
                params.mmrY = mmr
                params.nlqY = nlq
            case 1:
                params.polyCb = poly
                params.mmrCb = mmr
                params.nlqCb = nlq
            default:
                params.polyCr = poly
                params.mmrCr = mmr
                params.nlqCr = nlq
            }
        }

        if params.polyY.usesMmr {
            // Tells the luma kernel to fetch the base-layer chroma planes it
            // otherwise skips. No observed profile 7 stream does this (libdovi would
            // report mapping_idc = 1 for component 0), so it is worth a log.
            logOnce("[DoviFelComposer] luma curve uses MMR; enabling cross-component luma path", category: .swPlayback)
            params.flags.insert(.lumaMmr)
        }

        return params
    }

    /// Combines an RPU coefficient's signed integer part and unsigned fraction
    /// into one Q(denom) value, the way FFmpeg's `get_se_coef` does.
    ///
    /// Returns nil rather than saturating: a value that does not fit is a misparse
    /// or an unsupported stream, and clamping it would quietly install a curve
    /// that is wrong in a way nothing downstream can detect.
    private static func fixedPoint(int intPart: Int64, frac: UInt64, denom: Int) -> Int32? {
        guard let wide = fixedPointWide(int: intPart, frac: frac, denom: denom) else { return nil }
        guard wide >= Int64(Int32.min), wide <= Int64(Int32.max) else { return nil }
        return Int32(wide)
    }

    /// As ``fixedPoint(int:frac:denom:)`` but keeps the full 64-bit result, for
    /// values that are shifted down again before they have to fit in 32 bits.
    private static func fixedPointWide(int intPart: Int64, frac: UInt64, denom: Int) -> Int64? {
        guard denom >= 0, denom <= maxCoefLog2Denom else { return nil }
        let scale = Int64(1) << Int64(denom)
        guard frac < UInt64(scale) else { return nil }
        let (shifted, shiftOverflow) = intPart.multipliedReportingOverflow(by: scale)
        guard !shiftOverflow else { return nil }
        let (sum, addOverflow) = shifted.addingReportingOverflow(Int64(frac))
        guard !addOverflow else { return nil }
        return sum
    }

    /// Fills `polyOut` (and `mmrOut` for MMR pieces) from one component's
    /// reshaping curve. Returns false if anything about the curve is inconsistent,
    /// leaving the outputs partially written for the caller to discard.
    private static func parseReshapingCurve(
        _ curve: DoviReshapingCurve,
        coefLog2Denom: Int,
        blMax: UInt32,
        polyOut: inout DoviPolynomialParams,
        mmrOut: inout DoviMmrParams
    ) -> Bool {
        let numPivots = Int(curve.num_pivots_minus2) + 2
        guard numPivots >= 2, numPivots <= DoviPolynomialParams.maxPivots else { return false }
        guard let pivotsData = curve.pivots.data, curve.pivots.len >= numPivots else { return false }

        // Pivots are delta-coded; prefix-sum them into absolute BL code values.
        var running: UInt64 = 0
        for i in 0..<numPivots {
            running += UInt64(pivotsData[i])
            guard running <= UInt64(blMax) else { return false }
            polyOut.pivots[i] = UInt32(running)
        }
        guard polyOut.pivots[numPivots - 1] > polyOut.pivots[0] else { return false }
        polyOut.numPivots = UInt32(numPivots)

        let pieces = numPivots - 1
        guard pieces >= 1, pieces <= DoviPolynomialParams.maxPieces else { return false }

        switch curve.mapping_idc {
        case 0:
            guard let poly = curve.polynomial else { return false }
            guard let orderData = poly.pointee.poly_order_minus1.data,
                  poly.pointee.poly_order_minus1.len >= pieces else { return false }
            guard let intPieces = poly.pointee.poly_coef_int.list,
                  poly.pointee.poly_coef_int.len >= pieces,
                  let fracPieces = poly.pointee.poly_coef.list,
                  poly.pointee.poly_coef.len >= pieces else { return false }

            for p in 0..<pieces {
                let order = Int(orderData[p]) + 1
                // The syntax allows linear and quadratic pieces only.
                guard order >= 1, order <= 2 else { return false }
                polyOut.method[p] = DoviMapping.polynomial.rawValue
                polyOut.order[p] = UInt32(order)
                polyOut.coefShift[p] = UInt32(coefLog2Denom)

                guard let intData = intPieces[p]?.pointee, let intValues = intData.data,
                      let fracData = fracPieces[p]?.pointee, let fracValues = fracData.data else { return false }
                let count = order + 1
                guard intData.len >= count, fracData.len >= count else { return false }
                for j in 0..<count {
                    guard let coef = fixedPoint(int: intValues[j], frac: fracValues[j], denom: coefLog2Denom) else {
                        return false
                    }
                    polyOut.coef[p][j] = coef
                }
            }
            return true

        case 1:
            guard let mmr = curve.mmr else { return false }
            guard let orderData = mmr.pointee.mmr_order_minus1.data,
                  mmr.pointee.mmr_order_minus1.len >= pieces else { return false }
            guard let constInt = mmr.pointee.mmr_constant_int.data,
                  mmr.pointee.mmr_constant_int.len >= pieces,
                  let constFrac = mmr.pointee.mmr_constant.data,
                  mmr.pointee.mmr_constant.len >= pieces else { return false }
            guard let intPieces = mmr.pointee.mmr_coef_int.list,
                  mmr.pointee.mmr_coef_int.len >= pieces,
                  let fracPieces = mmr.pointee.mmr_coef.list,
                  mmr.pointee.mmr_coef.len >= pieces else { return false }

            for p in 0..<pieces {
                let order = Int(orderData[p]) + 1
                guard order >= 1, order <= 3 else { return false }
                polyOut.method[p] = DoviMapping.mmr.rawValue
                polyOut.order[p] = UInt32(order)

                guard let constant = fixedPoint(int: constInt[p], frac: constFrac[p], denom: coefLog2Denom) else {
                    return false
                }
                mmrOut.constant[p] = constant

                guard let intOrders = intPieces[p]?.pointee, let intOrderList = intOrders.list,
                      let fracOrders = fracPieces[p]?.pointee, let fracOrderList = fracOrders.list,
                      intOrders.len >= order, fracOrders.len >= order else { return false }

                for o in 0..<order {
                    guard let intTerms = intOrderList[o]?.pointee, let intValues = intTerms.data,
                          let fracTerms = fracOrderList[o]?.pointee, let fracValues = fracTerms.data,
                          intTerms.len >= 7, fracTerms.len >= 7 else { return false }
                    for k in 0..<7 {
                        guard let coef = fixedPoint(int: intValues[k], frac: fracValues[k], denom: coefLog2Denom) else {
                            return false
                        }
                        mmrOut.coef[p][o * 7 + k] = coef
                    }
                }
            }
            mmrOut.coefShift = UInt32(coefLog2Denom)
            return true

        default:
            return false
        }
    }

    /// Reads one component's inverse-NLQ parameters. Any value that does not fit
    /// the fixed-point ABI disables the residual for that component instead of
    /// being clamped, while keeping the decoded shift and pivots so a probe can
    /// still report what the RPU said.
    static func parseNlqParams(
        nlq: UnsafePointer<DoviRpuDataNlq>?,
        component c: Int,
        label: String,
        method: DoviNlqMethod,
        coefLog2Denom: Int,
        nlqShift: UInt32,
        pivots: [UInt32]
    ) -> DoviNlqParams {
        var disabled = DoviNlqParams.disabled
        disabled.nlqPivots = pivots
        disabled.nlqShift = nlqShift

        guard method == .linear, let nlq = nlq else { return disabled }

        let offset: UInt16
        let slopeInt: UInt64
        let slopeFrac: UInt64
        let thrInt: UInt64
        let thrFrac: UInt64
        let maxInt: UInt64
        let maxFrac: UInt64

        switch c {
        case 0:
            offset = nlq.pointee.nlq_offset.0
            slopeInt = nlq.pointee.linear_deadzone_slope_int.0
            slopeFrac = nlq.pointee.linear_deadzone_slope.0
            thrInt = nlq.pointee.linear_deadzone_threshold_int.0
            thrFrac = nlq.pointee.linear_deadzone_threshold.0
            maxInt = nlq.pointee.vdr_in_max_int.0
            maxFrac = nlq.pointee.vdr_in_max.0
        case 1:
            offset = nlq.pointee.nlq_offset.1
            slopeInt = nlq.pointee.linear_deadzone_slope_int.1
            slopeFrac = nlq.pointee.linear_deadzone_slope.1
            thrInt = nlq.pointee.linear_deadzone_threshold_int.1
            thrFrac = nlq.pointee.linear_deadzone_threshold.1
            maxInt = nlq.pointee.vdr_in_max_int.1
            maxFrac = nlq.pointee.vdr_in_max.1
        default:
            offset = nlq.pointee.nlq_offset.2
            slopeInt = nlq.pointee.linear_deadzone_slope_int.2
            slopeFrac = nlq.pointee.linear_deadzone_slope.2
            thrInt = nlq.pointee.linear_deadzone_threshold_int.2
            thrFrac = nlq.pointee.linear_deadzone_threshold.2
            maxInt = nlq.pointee.vdr_in_max_int.2
            maxFrac = nlq.pointee.vdr_in_max.2
        }

        guard let slopeIntSigned = Int64(exactly: slopeInt),
              let thrIntSigned = Int64(exactly: thrInt),
              let maxIntSigned = Int64(exactly: maxInt),
              let scale = fixedPoint(int: slopeIntSigned, frac: slopeFrac, denom: coefLog2Denom),
              let threshold = fixedPoint(int: thrIntSigned, frac: thrFrac, denom: coefLog2Denom),
              let maxFp = fixedPointWide(int: maxIntSigned, frac: maxFrac, denom: coefLog2Denom) else {
            logOnce("[DoviFelComposer] \(label) NLQ parameters do not fit the fixed-point ABI; dropping residual", category: .swPlayback)
            return disabled
        }

        // vdr_in_max is a normalised ceiling in Q(coefficient_log2_denom); the
        // same shift that converts the residual converts the ceiling.
        let scaledMax = maxFp >> Int64(nlqShift)
        // A ceiling of 0 clamps every magnitude to min(|r|, 0) = 0 under the spec's clamp, so the residual
        // contributes nothing: refusing it, which drops the residual, is exact.
        guard scaledMax > 0, scaledMax <= Int64(Int32.max) else {
            logOnce("[DoviFelComposer] \(label) vdr_in_max \(scaledMax) zero or out of range; dropping residual", category: .swPlayback)
            return disabled
        }

        if threshold != 0 {
            deadzoneLogLock.lock()
            let first = !loggedNonZeroDeadzone
            loggedNonZeroDeadzone = true
            deadzoneLogLock.unlock()
            if first {
                EngineLog.emit("[DoviFelComposer] \(label) linear_deadzone_threshold = \(threshold) (non-zero); "
                    + "the inverse NLQ adds it to the scaled magnitude, as the spec's pseudo-code "
                    + "does, but no surveyed stream carries a non-zero threshold. If highlights look "
                    + "crushed or lifted, this is the first thing to question.", category: .swPlayback)
            }
        }

        var params = DoviNlqParams()
        params.nlqMethod = .linear
        params.nlqPivots = pivots
        params.nlqShift = nlqShift
        params.nlqOffset = Int32(offset)
        params.nlqScale = scale
        params.nlqThreshold = threshold
        params.vdrInMax = Int32(scaledMax)
        return params
    }
}
#endif
