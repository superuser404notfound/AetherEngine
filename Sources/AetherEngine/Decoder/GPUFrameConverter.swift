import Foundation
import CoreVideo
import Metal
import AetherLibavutil

/// A decoded `yuv420p10le` frame into a P010 pixel buffer on the GPU, with AV1 film grain applied on the
/// way when the frame carries its parameters (see `AV1FilmGrainTables`). Replaces, for those frames,
/// both `sws_scale` (planar to biplanar, shifted to the top of 16 bits) and dav1d applying the grain
/// itself, which together were a fifth of the CPU a 4K AV1 decode spends (12 % and 9 % of a 4K film at
/// 54 Mbit/s on an M5 Pro). Both are memory-bound per-pixel passes the GPU does in a few
/// milliseconds; on a fanless Apple TV the CPU time they free is heat that would otherwise throttle the
/// decode.
///
/// The frame is read where dav1d left it when its buffer lies on page boundaries (the GPU maps the
/// pages, nothing is copied), and copied once into a staging buffer otherwise. Synchronous: `convert`
/// returns after the GPU finished, so the frame and the pixel buffer are free to go on as before.
/// Called under the decoder's lock only, which serialises it.
final class GPUFrameConverter: @unchecked Sendable {

    /// Process switch for comparisons (`AetherEngine.convertsAV1FramesOnGPU`). Read when a decoder
    /// opens, since dav1d is told then whether to apply film grain itself.
    nonisolated(unsafe) static var enabled = true

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let luma: MTLComputePipelineState
    private let chroma: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private let supportsNonUniformThreadgroups: Bool

    private let uniformBuffer: MTLBuffer
    private let lumaGrainBuffer: MTLBuffer
    private let chromaGrainBuffer: MTLBuffer
    private let scalingBuffer: MTLBuffer
    private var offsetsBuffer: MTLBuffer?
    private var staging: MTLBuffer?

    private(set) var framesConverted = 0
    private(set) var framesGrained = 0
    private(set) var framesCopied = 0
    private var loggedFailure = false
    private var loggedRoute = false

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
        supportsNonUniformThreadgroups = dev.supportsFamily(.apple4) || dev.supportsFamily(.mac2)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache) == kCVReturnSuccess else { return nil }
        textureCache = cache
        let lumaBytes = AV1FilmGrainTables.lumaWidth * AV1FilmGrainTables.lumaHeight * 2
        let chromaBytes = 2 * AV1FilmGrainTables.chromaWidth * AV1FilmGrainTables.chromaHeight * 2
        guard let u = dev.makeBuffer(length: MemoryLayout<AV1FilmGrainTables.Uniforms>.stride, options: .storageModeShared),
              let lg = dev.makeBuffer(length: lumaBytes, options: .storageModeShared),
              let cg = dev.makeBuffer(length: chromaBytes, options: .storageModeShared),
              let sc = dev.makeBuffer(length: 3 * AV1FilmGrainTables.scalingSize, options: .storageModeShared)
        else { return nil }
        uniformBuffer = u
        lumaGrainBuffer = lg
        chromaGrainBuffer = cg
        scalingBuffer = sc
    }

    deinit {
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    /// Whether this frame is one `convert` takes: planar 10-bit 4:2:0, positive strides.
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

    /// Writes `frame` into `pixelBuffer` (a P010 buffer of the frame's size). False when anything on the
    /// way failed; the caller then converts on the CPU instead (and without grain).
    func convert(_ frame: UnsafeMutablePointer<AVFrame>, into pixelBuffer: CVPixelBuffer) -> Bool {
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        let chromaW = (width + 1) >> 1, chromaH = (height + 1) >> 1
        guard Self.accepts(frame), width > 0, height > 0,
              CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height
        else { return false }

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

        guard let source = sourceBuffer(frame, chromaHeight: chromaH),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder()
        else { return fail("no command buffer or source") }

        var keepAlive: [CVMetalTexture] = []
        guard let outY = texture(pixelBuffer, plane: 0, format: .r16Uint, width: width, height: height, keepAlive: &keepAlive),
              let outUV = texture(pixelBuffer, plane: 1, format: .rg16Uint, width: chromaW, height: chromaH, keepAlive: &keepAlive)
        else {
            enc.endEncoding()
            return fail("no destination textures")
        }

        withUnsafeBytes(of: &uniforms) { uniformBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if let tables {
            tables.lumaGrain.withUnsafeBytes { lumaGrainBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            tables.chromaGrain.withUnsafeBytes { chromaGrainBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            tables.scaling.withUnsafeBytes { scalingBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            if (offsetsBuffer?.length ?? 0) < tables.offsets.count {
                offsetsBuffer = device.makeBuffer(length: tables.offsets.count, options: .storageModeShared)
            }
            tables.offsets.withUnsafeBytes { raw in
                offsetsBuffer?.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
        if offsetsBuffer == nil { offsetsBuffer = device.makeBuffer(length: 16, options: .storageModeShared) }
        guard let offsets = offsetsBuffer else {
            enc.endEncoding()
            return fail("no offsets buffer")
        }

        enc.setComputePipelineState(luma)
        enc.setBuffer(source.buffer, offset: source.y, index: 0)
        enc.setBuffer(uniformBuffer, offset: 0, index: 1)
        enc.setBuffer(lumaGrainBuffer, offset: 0, index: 2)
        enc.setBuffer(scalingBuffer, offset: 0, index: 3)
        enc.setBuffer(offsets, offset: 0, index: 4)
        enc.setTexture(outY, index: 0)
        dispatch(enc, pipeline: luma, width: width, height: height)

        enc.setComputePipelineState(chroma)
        enc.setBuffer(chromaGrainBuffer, offset: 0, index: 2)
        enc.setBuffer(source.buffer, offset: source.cb, index: 5)
        enc.setBuffer(source.buffer, offset: source.cr, index: 6)
        enc.setTexture(outUV, index: 0)
        dispatch(enc, pipeline: chroma, width: chromaW, height: chromaH)
        enc.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()
        _ = keepAlive
        if let error = cb.error { return fail("command buffer: \(error.localizedDescription)") }

        framesConverted += 1
        if tables != nil { framesGrained += 1 }
        if !loggedRoute {
            loggedRoute = true
            EngineLog.emit(
                "[GPUFrameConverter] \(width)x\(height) yuv420p10le -> P010 on the GPU, "
                + (tables != nil ? "AV1 film grain applied here" : "no film grain on the first frame")
                + (source.copied ? ", frame copied to a staging buffer" : ", frame read in place"),
                category: .swPlayback)
        }
        return true
    }

    /// One buffer that covers all three planes, and where each starts in it.
    private struct Source {
        let buffer: MTLBuffer
        let y: Int, cb: Int, cr: Int
        let copied: Bool
    }

    private func sourceBuffer(_ frame: UnsafeMutablePointer<AVFrame>, chromaHeight: Int) -> Source? {
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

        // Copied: the three planes back to back in a reusable staging buffer.
        let total = planes.reduce(0) { $0 + $1.1 }
        if (staging?.length ?? 0) < total {
            staging = device.makeBuffer(length: total, options: .storageModeShared)
        }
        guard let staging else { return nil }
        var offset = 0
        var offsets: [Int] = []
        for p in planes {
            offsets.append(offset)
            (staging.contents() + offset).copyMemory(from: p.0, byteCount: p.1)
            offset += p.1
        }
        framesCopied += 1
        return Source(buffer: staging, y: offsets[0], cb: offsets[1], cr: offsets[2], copied: true)
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         width: Int, height: Int, keepAlive: inout [CVMetalTexture]) -> MTLTexture? {
        guard let textureCache else { return nil }
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                                                        format, width, height, plane, &cvTex) == kCVReturnSuccess,
              let cvTex else { return nil }
        keepAlive.append(cvTex)
        return CVMetalTextureGetTexture(cvTex)
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let group = MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w / 2), depth: 1)
        if supportsNonUniformThreadgroups {
            enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group)
        } else {
            enc.dispatchThreadgroups(MTLSize(width: (width + group.width - 1) / group.width,
                                             height: (height + group.height - 1) / group.height, depth: 1),
                                     threadsPerThreadgroup: group)
        }
    }

    private func fail(_ why: String) -> Bool {
        if !loggedFailure {
            loggedFailure = true
            EngineLog.emit("[GPUFrameConverter] frame left to sws_scale (logged once): \(why)", category: .swPlayback)
        }
        return false
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
