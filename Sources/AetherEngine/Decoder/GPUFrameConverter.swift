import Foundation
import CoreVideo
import Metal
import AetherLibavutil
import AetherLibswscale

/// A decoded `yuv420p10le` frame into a P010 pixel buffer on the GPU, with AV1 film grain applied on the
/// way when the frame carries its parameters (see `AV1FilmGrainTables`). Replaces, for those frames,
/// both `sws_scale` (planar to biplanar, shifted to the top of 16 bits) and dav1d applying the grain
/// itself, which together were a fifth of the CPU a 4K AV1 decode spends (12 % and 9 % of a 4K film at
/// 54 Mbit/s on an M5 Pro). Both are memory-bound per-pixel passes the GPU does in a few
/// milliseconds; on a fanless Apple TV the CPU time they free is heat that would otherwise throttle the
/// decode.
///
/// The frame is read where dav1d left it when its buffer lies on page boundaries (the GPU maps the
/// pages, nothing is copied), and copied once into a staging buffer otherwise.
///
/// Two ways to run a frame, both called under the decoder's lock only, which serialises them:
///
/// - `encode` returns the frame's work without committing it. The playback decoder hands it to a
///   `PipelinedFrameStage`, so up to `slotCount` frames are on the GPU while dav1d decodes the next, and
///   calls `finished` when the work completed. Waiting for each frame on the decoder's thread held a 1080p
///   10-bit AV1 episode at about 23 of its 24 frames a second on an Apple TV 4K (A15) in a host's Debug
///   build, so the clock paused to rebuffer every few seconds (see measurements.md).
/// - `convert` commits and waits, for the callers that read the frame right after `decode` returns (the
///   probe, the still extractor, the tests).
final class GPUFrameConverter: @unchecked Sendable {

    /// Process switch for comparisons (`AetherEngine.convertsAV1FramesOnGPU`). Read when a decoder
    /// opens, since dav1d is told then whether to apply film grain itself.
    nonisolated(unsafe) static var enabled = true

    /// Frames this converter can have on the GPU at once, each with buffers of its own: the depth of the
    /// pipeline the playback decoder runs it in. A frame's buffers are reused two frames later, when the
    /// pipeline has already delivered it.
    static let slotCount = PipelinedFrameStage.defaultDepth

    /// Frames between two `[GPUFrameConverter] last N frames` lines (about 10 s at 24 fps).
    static let statsInterval = 240

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let luma: MTLComputePipelineState
    private let chroma: MTLComputePipelineState
    private let io: MetalFrameIO

    /// The buffers one frame's work reads besides its picture: written while it is encoded, read by the
    /// GPU until it completes, so a frame still on the GPU keeps its own set.
    private final class Slot {
        let uniform: MTLBuffer
        let lumaGrain: MTLBuffer
        let chromaGrain: MTLBuffer
        let scaling: MTLBuffer
        var offsets: MTLBuffer?
        var staging: MTLBuffer?

        init?(device: MTLDevice) {
            let lumaBytes = AV1FilmGrainTables.lumaWidth * AV1FilmGrainTables.lumaHeight * 2
            let chromaBytes = 2 * AV1FilmGrainTables.chromaWidth * AV1FilmGrainTables.chromaHeight * 2
            guard let u = device.makeBuffer(length: MemoryLayout<AV1FilmGrainTables.Uniforms>.stride, options: .storageModeShared),
                  let lg = device.makeBuffer(length: lumaBytes, options: .storageModeShared),
                  let cg = device.makeBuffer(length: chromaBytes, options: .storageModeShared),
                  let sc = device.makeBuffer(length: 3 * AV1FilmGrainTables.scalingSize, options: .storageModeShared)
            else { return nil }
            uniform = u
            lumaGrain = lg
            chromaGrain = cg
            scaling = sc
        }
    }
    private let slots: [Slot]
    private var nextSlot = 0

    /// Counts and the periodic timing line, written on the decoder's thread (`encode`) and on a Metal
    /// completion thread (`finished`).
    private let statsLock = NSLock()
    private var converted = 0
    private var grained = 0
    private var copied = 0
    private var window = Window()
    private var loggedFailure = false
    private var loggedRoute = false

    /// Per-frame times since the last timing line, in milliseconds.
    private struct Window {
        var frames = 0
        var encodeMs = 0.0
        var gpuMs = 0.0
        var heldMs = 0.0
        var overlapped = 0
    }

    /// The CPU conversion a frame gets when its GPU work failed after the decoder had moved on (`finished`
    /// runs on a Metal completion thread, away from the decoder's own `sws_scale` context).
    private let fallback = CPUFallback()

    private static let pageSize = Int(getpagesize())

    /// Device, queue and pipelines, compiled once per process: every 10-bit AV1 open (each load, each still
    /// extractor) builds a converter, and a compile from source would sit on its time to first frame. A
    /// failure is kept too, so a shader that does not compile costs one attempt.
    private struct Shared: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let luma: MTLComputePipelineState
        let chroma: MTLComputePipelineState

        static let instance: Shared? = {
            guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else { return nil }
            do {
                let library = try dev.makeLibrary(source: AV1FilmGrainShaderSource.source, options: nil)
                guard let lumaFn = library.makeFunction(name: "fg_luma"),
                      let chromaFn = library.makeFunction(name: "fg_chroma") else { return nil }
                return Shared(device: dev, queue: queue,
                              luma: try dev.makeComputePipelineState(function: lumaFn),
                              chroma: try dev.makeComputePipelineState(function: chromaFn))
            } catch {
                EngineLog.emit("[GPUFrameConverter] Metal shader compilation failed: \(error)", category: .swPlayback)
                return nil
            }
        }()
    }

    init?() {
        guard let shared = Shared.instance else { return nil }
        let dev = shared.device
        device = dev
        queue = shared.queue
        luma = shared.luma
        chroma = shared.chroma
        guard let io = MetalFrameIO(device: dev) else { return nil }
        self.io = io
        var made: [Slot] = []
        for _ in 0..<Self.slotCount {
            guard let slot = Slot(device: dev) else { return nil }
            made.append(slot)
        }
        slots = made
    }

    /// Frames the GPU converted, grained and had to copy first.
    var counts: (converted: Int, grained: Int, copied: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (converted, grained, copied)
    }

    /// Whether this frame is one `encode` takes: planar 10-bit 4:2:0, positive strides.
    static func accepts(_ frame: UnsafePointer<AVFrame>) -> Bool {
        frame.pointee.format == AV_PIX_FMT_YUV420P10LE.rawValue
            && frame.pointee.linesize.0 > 0 && frame.pointee.linesize.1 > 0
            && frame.pointee.linesize.1 == frame.pointee.linesize.2
            && frame.pointee.data.0 != nil && frame.pointee.data.1 != nil && frame.pointee.data.2 != nil
    }

    /// The frame's film grain parameters, when it carries AV1 ones (dav1d exports them instead of
    /// applying them when the decoder opened with `AV_CODEC_EXPORT_DATA_FILM_GRAIN`).
    static func filmGrain(of frame: UnsafePointer<AVFrame>) -> AVFilmGrainParams? {
        guard let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_FILM_GRAIN_PARAMS),
              let data = sd.pointee.data, sd.pointee.size >= MemoryLayout<AVFilmGrainParams>.size else { return nil }
        let params = UnsafeRawPointer(data).loadUnaligned(as: AVFilmGrainParams.self)
        return params.type == AV_FILM_GRAIN_PARAMS_AV1 ? params : nil
    }

    /// One frame's work, encoded and not yet committed.
    struct Encoded: @unchecked Sendable {
        let work: EncodedGPUWork
        let width: Int, height: Int
        let grained: Bool
        let copied: Bool
        /// The time `encode` took on the decoder's thread (film grain tables, source, encoding).
        let encodeMs: Double
    }

    /// The command buffer's failure, as the frame stages report theirs.
    struct Failure: GPUStageFailure, CustomStringConvertible {
        let status: MTLCommandBufferStatus
        let underlying: Error?
        var description: String {
            "command buffer status \(status.rawValue)" + (underlying.map { ": \($0.localizedDescription)" } ?? "")
        }
    }

    /// Writes `frame` into `pixelBuffer` (a P010 buffer of the frame's size) and waits for the GPU. False
    /// when anything on the way failed; the caller then converts on the CPU instead (and without grain).
    func convert(_ frame: UnsafeMutablePointer<AVFrame>, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard let encoded = encode(frame, into: pixelBuffer) else { return false }
        encoded.work.commandBuffer.commit()
        encoded.work.commandBuffer.waitUntilCompleted()
        return finished(encoded, heldMs: nil)
    }

    /// Encodes `frame` into `pixelBuffer` (a P010 buffer of the frame's size) without committing it. Nil
    /// when anything on the way failed, logged once; the caller then converts on the CPU (without grain).
    ///
    /// The caller commits the work, keeps `frame`'s buffer alive until it completed (the GPU reads it in
    /// place), and then calls `finished`. At most `slotCount` frames may be on the GPU at once.
    func encode(_ frame: UnsafeMutablePointer<AVFrame>, into pixelBuffer: CVPixelBuffer) -> Encoded? {
        let started = DispatchTime.now().uptimeNanoseconds
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        let chromaW = (width + 1) >> 1, chromaH = (height + 1) >> 1
        guard Self.accepts(frame), width > 0, height > 0,
              CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height
        else { return nil }

        var tables: AV1FilmGrainTables?
        if let params = Self.filmGrain(of: frame) {
            tables = AV1FilmGrainTables(params: params, width: width, height: height,
                                        identityMatrix: frame.pointee.colorspace == AVCOL_SPC_RGB)
        }
        var uniforms = tables?.uniforms ?? AV1FilmGrainTables.Uniforms()
        uniforms.width = Int32(width)
        uniforms.height = Int32(height)
        uniforms.chromaWidth = Int32(chromaW)
        uniforms.chromaHeight = Int32(chromaH)
        uniforms.strideY = frame.pointee.linesize.0 / 2
        uniforms.strideC = frame.pointee.linesize.1 / 2
        if tables == nil {
            uniforms.applyY = 0
            uniforms.applyCb = 0
            uniforms.applyCr = 0
        }

        let slot = slots[nextSlot]
        nextSlot = (nextSlot + 1) % slots.count

        guard let source = sourceBuffer(frame, chromaHeight: chromaH, slot: slot),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder()
        else { return fail("no command buffer or source") }

        let textures = io.lease()
        guard let outY = io.texture(pixelBuffer, plane: 0, format: .r16Uint, width: width, height: height, in: textures),
              let outUV = io.texture(pixelBuffer, plane: 1, format: .rg16Uint, width: chromaW, height: chromaH, in: textures)
        else {
            enc.endEncoding()
            return fail("no destination textures")
        }

        withUnsafeBytes(of: &uniforms) { slot.uniform.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if let tables {
            tables.lumaGrain.withUnsafeBytes { slot.lumaGrain.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            tables.chromaGrain.withUnsafeBytes { slot.chromaGrain.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            tables.scaling.withUnsafeBytes { slot.scaling.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            if (slot.offsets?.length ?? 0) < tables.offsets.count {
                slot.offsets = device.makeBuffer(length: tables.offsets.count, options: .storageModeShared)
            }
            tables.offsets.withUnsafeBytes { raw in
                slot.offsets?.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
        if slot.offsets == nil { slot.offsets = device.makeBuffer(length: 16, options: .storageModeShared) }
        guard let offsets = slot.offsets else {
            enc.endEncoding()
            return fail("no offsets buffer")
        }

        enc.setComputePipelineState(luma)
        enc.setBuffer(source.buffer, offset: source.y, index: 0)
        enc.setBuffer(slot.uniform, offset: 0, index: 1)
        enc.setBuffer(slot.lumaGrain, offset: 0, index: 2)
        enc.setBuffer(slot.scaling, offset: 0, index: 3)
        enc.setBuffer(offsets, offset: 0, index: 4)
        enc.setTexture(outY, index: 0)
        dispatch(enc, pipeline: luma, width: width, height: height)

        enc.setComputePipelineState(chroma)
        enc.setBuffer(slot.chromaGrain, offset: 0, index: 2)
        enc.setBuffer(source.buffer, offset: source.cb, index: 5)
        enc.setBuffer(source.buffer, offset: source.cr, index: 6)
        enc.setTexture(outUV, index: 0)
        dispatch(enc, pipeline: chroma, width: chromaW, height: chromaH)
        enc.endEncoding()

        let work = EncodedGPUWork(commandBuffer: cb, textures: textures) { status, error in
            Failure(status: status, underlying: error)
        }
        let encodeMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return Encoded(work: work, width: width, height: height, grained: tables != nil,
                       copied: source.copied, encodeMs: encodeMs)
    }

    /// After the work `encode` made completed: the counts, the route line once, the timing line every
    /// `statsInterval` frames. `heldMs` is how long the frame held the decoder's thread in the pipeline
    /// (nil when `convert` waited for it there). False when the GPU work failed; the frame then still needs
    /// converting (`convertOnCPU`).
    func finished(_ encoded: Encoded, heldMs: Double?) -> Bool {
        let gpuMs: Double
        do {
            gpuMs = try encoded.work.finish()
        } catch {
            // A refusal while the app is in the background (iOS) is the system's, not a fault worth a line.
            if !EncodedGPUWork.isBackgroundRefusal(error) { _ = fail("\(error)") }
            return false
        }
        statsLock.lock()
        converted += 1
        if encoded.grained { grained += 1 }
        if encoded.copied { copied += 1 }
        let firstFrame = !loggedRoute
        loggedRoute = true
        window.frames += 1
        window.encodeMs += encoded.encodeMs
        window.gpuMs += gpuMs
        if let heldMs {
            window.heldMs += heldMs
            window.overlapped += 1
        } else {
            window.heldMs += encoded.encodeMs + gpuMs
        }
        let report = window.frames >= Self.statsInterval ? window : nil
        if report != nil { window = Window() }
        statsLock.unlock()

        if firstFrame {
            EngineLog.emit(
                "[GPUFrameConverter] \(encoded.width)x\(encoded.height) yuv420p10le -> P010 on the GPU, "
                + (encoded.grained ? "AV1 film grain applied here" : "no film grain on the first frame")
                + (encoded.copied ? ", frame copied to a staging buffer" : ", frame read in place")
                + (heldMs != nil ? ", up to \(Self.slotCount) frames on the GPU" : ", waiting for each frame"),
                category: .swPlayback)
        }
        if let report {
            let n = Double(report.frames)
            EngineLog.emit(
                "[GPUFrameConverter] last \(report.frames) frames: "
                + String(format: "encode %.2f ms, GPU %.2f ms, decoder thread held %.2f ms per frame",
                         report.encodeMs / n, report.gpuMs / n, report.heldMs / n)
                + (report.overlapped == report.frames ? " (overlapped)" : " (waited for each)"),
                category: .swPlayback)
        }
        return true
    }

    /// `frame` into `pixelBuffer` on the CPU, without grain, for a frame whose GPU work failed after the
    /// decoder moved on. `format` is the decoder's output format (`OutputFormat.swscaleFormat`). False
    /// when no `sws_scale` context could be made, so the buffer was not written.
    func convertOnCPU(_ frame: UnsafeMutablePointer<AVFrame>, into pixelBuffer: CVPixelBuffer, format: AVPixelFormat) -> Bool {
        fallback.convert(frame, into: pixelBuffer, format: format)
    }

    /// One buffer that covers all three planes, and where each starts in it.
    private struct Source {
        let buffer: MTLBuffer
        let y: Int, cb: Int, cr: Int
        let copied: Bool
    }

    private func sourceBuffer(_ frame: UnsafeMutablePointer<AVFrame>, chromaHeight: Int, slot: Slot) -> Source? {
        let height = Int(frame.pointee.height)
        guard let y = frame.pointee.data.0, let u = frame.pointee.data.1, let v = frame.pointee.data.2 else { return nil }
        let lsY = Int(frame.pointee.linesize.0), lsC = Int(frame.pointee.linesize.1)
        let planes = [(UnsafeMutableRawPointer(y), lsY * height),
                      (UnsafeMutableRawPointer(u), lsC * chromaHeight),
                      (UnsafeMutableRawPointer(v), lsC * chromaHeight)]

        // In place: one AVBuffer holding every plane, starting on a page (dav1d's picture pool hands out
        // whole-page allocations at 4K). The GPU reads it through the same pages the decoder wrote.
        if let ref = frame.pointee.buf.0, let base = ref.pointee.data {
            let start = Int(bitPattern: base), end = start + Int(ref.pointee.size)
            let inside = planes.allSatisfy { p in
                let a = Int(bitPattern: p.0)
                return a >= start && a + p.1 <= end
            }
            if inside, start % Self.pageSize == 0 {
                let length = (Int(ref.pointee.size) + Self.pageSize - 1) / Self.pageSize * Self.pageSize
                if let buffer = device.makeBuffer(bytesNoCopy: base, length: length,
                                                  options: .storageModeShared, deallocator: nil) {
                    return Source(buffer: buffer,
                                  y: Int(bitPattern: planes[0].0) - start,
                                  cb: Int(bitPattern: planes[1].0) - start,
                                  cr: Int(bitPattern: planes[2].0) - start,
                                  copied: false)
                }
            }
        }

        // Copied: the three planes back to back in the slot's staging buffer.
        let total = planes.reduce(0) { $0 + $1.1 }
        if (slot.staging?.length ?? 0) < total {
            slot.staging = device.makeBuffer(length: total, options: .storageModeShared)
        }
        guard let staging = slot.staging else { return nil }
        var offset = 0
        var offsets: [Int] = []
        for p in planes {
            offsets.append(offset)
            (staging.contents() + offset).copyMemory(from: p.0, byteCount: p.1)
            offset += p.1
        }
        return Source(buffer: staging, y: offsets[0], cb: offsets[1], cr: offsets[2], copied: true)
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let group = MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w / 2), depth: 1)
        io.dispatch(enc, grid: (width, height), threadgroup: group)
    }

    private func fail(_ why: String) -> Encoded? {
        statsLock.lock()
        let first = !loggedFailure
        loggedFailure = true
        statsLock.unlock()
        if first {
            EngineLog.emit("[GPUFrameConverter] frame left to sws_scale (logged once): \(why)", category: .swPlayback)
        }
        return nil
    }

    /// `sws_scale` of its own, for `convertOnCPU`.
    private final class CPUFallback: @unchecked Sendable {
        private let lock = NSLock()
        private var context: UnsafeMutablePointer<SwsContext>?

        func convert(_ frame: UnsafeMutablePointer<AVFrame>, into pixelBuffer: CVPixelBuffer, format: AVPixelFormat) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let width = frame.pointee.width, height = frame.pointee.height
            context = sws_getCachedContext(context, width, height, AVPixelFormat(rawValue: frame.pointee.format),
                                           width, height, format, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            guard let context else { return false }
            SoftwareVideoDecoder.scale(frame, into: pixelBuffer, with: context)
            return true
        }

        deinit { if context != nil { sws_freeContext(context) } }
    }
}

extension AetherEngine {
    /// Comparison switch for the software path: true (the default) converts 10-bit AV1 frames to P010 on the
    /// GPU and applies their film grain there, false leaves both to the CPU (dav1d's grain, `sws_scale`).
    /// Read when a decoder opens, so it takes effect on the next load or reload.
    @_spi(Diagnostics)
    public nonisolated static var convertsAV1FramesOnGPU: Bool {
        get { GPUFrameConverter.enabled }
        set { GPUFrameConverter.enabled = newValue }
    }
}
