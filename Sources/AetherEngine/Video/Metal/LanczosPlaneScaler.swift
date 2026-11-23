#if !targetEnvironment(simulator)
import CoreVideo
import Foundation
import Metal

/// `UpscaleScaler.lanczos`: Lanczos-3 on the luma and chroma planes of a 4:2:0 frame (8 or 10-bit, video
/// or full range), with no RGB round trip and no colour arithmetic, so the matrix and the range do not
/// matter. Each plane goes through two passes, along the rows into a float texture of the target width,
/// then along the columns into the output plane, where the samples are rounded to the plane's codes.
/// Six taps per pass and sample (`LanczosTaps`), so 1080p to 2160p reads 12 source samples per output
/// sample instead of the 36 of a 2D kernel.
///
/// Measured against an Apple TV's own scaling, which is bilinear on both playback paths (A15, tvOS 27.2),
/// over 13 Netflix and SVT scenes brought from 4K to 1080p and back: VMAF NEG 94.0 against 85.5, with
/// MetalFX spatial at 92.1. On that A15 the stage reads about 8 ms of GPU per frame in playback at 24 fps.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class LanczosPlaneScaler {

    struct Failure: GPUStageFailure, CustomStringConvertible {
        let description: String
        let underlying: Error?
        init(_ description: String, underlying: Error? = nil) {
            self.description = description
            self.underlying = underlying
        }
    }

    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    private let queue: MTLCommandQueue
    private let kernels: LanczosKernels
    private let io: MetalFrameIO
    private let lumaColumns: MTLBuffer
    private let lumaRows: MTLBuffer
    private let chromaColumns: MTLBuffer
    private let chromaRows: MTLBuffer
    /// The row pass's output per plane: target width, source height, 32-bit float so a 10-bit plane loses
    /// nothing between the passes.
    private let lumaTemp: MTLTexture
    private let chromaTemp: MTLTexture
    private var outputPools: [OSType: CVPixelBufferPool] = [:]

    static let supportedFormats = FrameChain.supportedFormats

    init(device: MTLDevice, queue: MTLCommandQueue, sourceWidth: Int, sourceHeight: Int,
         targetWidth: Int, targetHeight: Int, io: MetalFrameIO? = nil) throws {
        guard targetWidth % 2 == 0, targetHeight % 2 == 0 else { throw Failure("odd target size") }
        let chromaW = (sourceWidth + 1) / 2, chromaH = (sourceHeight + 1) / 2
        guard let lumaX = LanczosTaps(inputCount: sourceWidth, outputCount: targetWidth),
              let lumaY = LanczosTaps(inputCount: sourceHeight, outputCount: targetHeight),
              let chromaX = LanczosTaps(inputCount: chromaW, outputCount: targetWidth / 2),
              let chromaY = LanczosTaps(inputCount: chromaH, outputCount: targetHeight / 2)
        else { throw Failure("Lanczos \(sourceWidth)x\(sourceHeight) -> \(targetWidth)x\(targetHeight) is not an upscale") }
        do {
            kernels = try LanczosKernels.shared(for: device)
        } catch {
            throw Failure("Lanczos kernels not built", underlying: error)
        }
        guard let io = io ?? MetalFrameIO(device: device) else { throw Failure("no Metal texture cache") }
        func buffer(_ taps: LanczosTaps) throws -> MTLBuffer {
            guard let b = taps.table.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }) else { throw Failure("tap buffer not allocated") }
            return b
        }
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw Failure("texture \(w)x\(h) not allocated") }
            return t
        }
        lumaRows = try buffer(lumaX)
        lumaColumns = try buffer(lumaY)
        chromaRows = try buffer(chromaX)
        chromaColumns = try buffer(chromaY)
        lumaTemp = try texture(.r32Float, targetWidth, sourceHeight)
        chromaTemp = try texture(.rg32Float, targetWidth / 2, chromaH)
        self.queue = queue
        self.io = io
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
    }

    /// One frame's work, encoded and not committed: the output buffer (input's format, target size, no
    /// attachments yet) holds the picture once it completed. `picture` is the region of `input` to scale.
    func encode(_ input: CVPixelBuffer, picture: FrameUpscaler.PictureRegion) throws
        -> (output: CVPixelBuffer, work: EncodedGPUWork) {
        // Only on the encoding thread; a texture an earlier frame still uses stays alive in its lease.
        io.flush()
        let format = CVPixelBufferGetPixelFormatType(input)
        guard Self.supportedFormats.contains(format) else { throw Failure("pixel format \(format) not supported") }
        guard picture.width == sourceWidth, picture.height == sourceHeight else {
            throw Failure("picture \(picture.width)x\(picture.height) is not the scaler's \(sourceWidth)x\(sourceHeight)")
        }
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let output = try makeOutput(format: format)
        let lease = io.lease()
        let iy = try planeTexture(input, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, lease)
        let ic = try planeTexture(input, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, lease)
        let oy = try planeTexture(output, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, lease)
        let oc = try planeTexture(output, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, lease)

        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            throw Failure("no command buffer")
        }
        // 10-bit planes hold the code in the high bits of 16, so a unorm16 sample is code * 64 / 65535.
        let codeScale: Float = tenBit ? 65535.0 / 64.0 : 255
        let maxCode: Float = tenBit ? 1023 : 255
        let chromaW = min((picture.width + 1) / 2, ic.width - picture.x / 2)
        let chromaH = min((picture.height + 1) / 2, ic.height - picture.y / 2)
        var luma = LanczosRegion(originX: UInt32(picture.x), originY: UInt32(picture.y), width: UInt32(picture.width),
                                 height: UInt32(picture.height), codeScale: codeScale, maxCode: maxCode)
        var chroma = LanczosRegion(originX: UInt32(picture.x / 2), originY: UInt32(picture.y / 2), width: UInt32(chromaW),
                                   height: UInt32(chromaH), codeScale: codeScale, maxCode: maxCode)
        pass(enc, kernels.rows, taps: lumaRows, region: &luma, from: iy, to: lumaTemp)
        pass(enc, kernels.columns, taps: lumaColumns, region: &luma, from: lumaTemp, to: oy)
        pass(enc, kernels.rows, taps: chromaRows, region: &chroma, from: ic, to: chromaTemp)
        pass(enc, kernels.columns, taps: chromaColumns, region: &chroma, from: chromaTemp, to: oc)
        enc.endEncoding()
        return (output, EncodedGPUWork(commandBuffer: cb, textures: lease) { status, error in
            Failure("command buffer \(status.rawValue): \(error.map { "\($0)" } ?? "no error")", underlying: error)
        })
    }

    private func pass(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, taps: MTLBuffer,
                      region: inout LanczosRegion, from source: MTLTexture, to destination: MTLTexture) {
        encoder.setBuffer(taps, offset: 0, index: 0)
        encoder.setBytes(&region, length: MemoryLayout<LanczosRegion>.size, index: 1)
        FrameChain.dispatch(encoder, pipeline, textures: [source, destination],
                            grid: (destination.width, destination.height), io: io)
    }

    private func planeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                              _ lease: MetalTextureLease) throws -> MTLTexture {
        guard let texture = io.texture(buffer, plane: plane, format: format, in: lease)
        else { throw Failure("no Metal texture for plane \(plane)") }
        return texture
    }

    private func makeOutput(format: OSType) throws -> CVPixelBuffer {
        if outputPools[format] == nil {
            outputPools[format] = try makePool(width: targetWidth, height: targetHeight, format: format)
        }
        return try pooledBuffer(outputPools[format]!)
    }
}

/// Layout matches `LanczosRegion` in `LanczosShaderSource`: the picture's region in the source plane, and
/// the plane's code scale for the final rounding.
struct LanczosRegion {
    var originX: UInt32
    var originY: UInt32
    var width: UInt32
    var height: UInt32
    var codeScale: Float
    var maxCode: Float
}

/// The two passes, compiled once per process and device.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class LanczosKernels: @unchecked Sendable {
    let rows: MTLComputePipelineState
    let columns: MTLComputePipelineState

    private static let cache = MetalPipelineCache<LanczosKernels>()

    private init(rows: MTLComputePipelineState, columns: MTLComputePipelineState) {
        self.rows = rows
        self.columns = columns
    }

    static func shared(for device: MTLDevice) throws -> LanczosKernels {
        try cache.resolve(device: device) {
            let library = try device.makeLibrary(source: LanczosShaderSource.source, options: nil)
            guard let rows = library.makeFunction(name: "lanczosRows"),
                  let columns = library.makeFunction(name: "lanczosColumns")
            else { throw LanczosPlaneScaler.Failure("Lanczos kernels missing") }
            return LanczosKernels(rows: try device.makeComputePipelineState(function: rows),
                                  columns: try device.makeComputePipelineState(function: columns))
        }
    }
}

enum LanczosShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // LanczosTaps: the first source index as a float, six weights, one pad.
    struct LanczosTap { float first; float w[6]; float pad; };
    struct LanczosRegion { uint originX; uint originY; uint width; uint height; float codeScale; float maxCode; };

    // Along the rows of the picture region: one output sample per thread, source rows kept, edges replicated.
    kernel void lanczosRows(constant LanczosTap *taps [[buffer(0)]],
                            constant LanczosRegion &r [[buffer(1)]],
                            texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        constant LanczosTap &t = taps[gid.x];
        int first = int(t.first);
        int last = int(r.width) - 1;
        // A clipped chroma plane's row texture is taller than the picture there: repeat its last row.
        uint y = r.originY + min(gid.y, r.height - 1);
        float4 acc = float4(0.0);
        for (int k = 0; k < 6; k++) {
            acc += t.w[k] * src.read(uint2(r.originX + uint(clamp(first + k, 0, last)), y));
        }
        dst.write(acc, gid);
    }

    // Along the columns of the row pass's output, rounded to the plane's codes. The ringing is clamped to the
    // code range only, so video-range footroom and headroom pass as they came.
    kernel void lanczosColumns(constant LanczosTap *taps [[buffer(0)]],
                               constant LanczosRegion &r [[buffer(1)]],
                               texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        constant LanczosTap &t = taps[gid.y];
        int first = int(t.first);
        int last = int(src.get_height()) - 1;
        float4 acc = float4(0.0);
        for (int k = 0; k < 6; k++) {
            acc += t.w[k] * src.read(uint2(gid.x, uint(clamp(first + k, 0, last))));
        }
        dst.write(clamp(rint(acc * r.codeScale), 0.0, r.maxCode) / r.codeScale, gid);
    }
    """
}
#endif
