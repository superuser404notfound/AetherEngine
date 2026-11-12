#if !targetEnvironment(simulator)
import CoreVideo
import Foundation
import Metal

/// A chain of GPU stages over one decoded frame (AE#957, AE#1039): the 4:2:0 picture (8 or 10-bit) goes to
/// RGB in a half-float texture, through each stage in order, and back to the input's pixel format at the
/// target size, resampled bilinearly where the last stage does not land on it. Everything runs in one
/// command buffer. Stages see gamma-coded RGB in 0...1 (SDR only, so there is no transfer handling).
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class FrameChain {

    struct Failure: Error, CustomStringConvertible {
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
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let kernels: FrameChainKernels
    private let textureCache: CVMetalTextureCache
    private let stages: [any FrameChainStage]
    private let rgb: MTLTexture
    private var outputPools: [OSType: CVPixelBufferPool] = [:]

    /// The formats the chain reads and writes: 8 and 10-bit bi-planar 4:2:0, video and full range.
    static let supportedFormats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]

    init(device: MTLDevice, queue: MTLCommandQueue, sourceWidth: Int, sourceHeight: Int,
         targetWidth: Int, targetHeight: Int, stages: [any FrameChainStage]) throws {
        guard let kernels = FrameChainKernels.shared(for: device) else { throw Failure("chain kernels not built") }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache
        else { throw Failure("no Metal texture cache") }
        guard targetWidth % 2 == 0, targetHeight % 2 == 0 else { throw Failure("odd target size") }
        self.device = device
        self.queue = queue
        self.kernels = kernels
        self.textureCache = cache
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.stages = stages
        rgb = try Self.texture(device, sourceWidth, sourceHeight)
        var size = (sourceWidth, sourceHeight)
        for stage in stages { size = try stage.prepare(device: device, kernels: kernels, input: size) }
    }

    static func texture(_ device: MTLDevice, _ width: Int, _ height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw Failure("texture \(width)x\(height) not allocated") }
        return t
    }

    /// `picture` is the region of `input` the chain scales (the clean aperture), with an even origin.
    /// Returns a buffer of the input's format at the target size, attachments left to the caller, and
    /// the command buffer's GPU time in milliseconds.
    func process(_ input: CVPixelBuffer, picture: FrameUpscaler.PictureRegion) throws -> (CVPixelBuffer, Double) {
        let format = CVPixelBufferGetPixelFormatType(input)
        guard Self.supportedFormats.contains(format) else { throw Failure("pixel format \(format) not supported") }
        guard picture.width == sourceWidth, picture.height == sourceHeight else {
            throw Failure("picture \(picture.width)x\(picture.height) is not the chain's \(sourceWidth)x\(sourceHeight)")
        }
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        var params = FrameChainColorParams(tenBit: tenBit, videoRange: videoRange, matrix: UpscaleMatrix.of(input),
                                           origin: (picture.x, picture.y))
        let output = try makeOutput(format: format)
        let lumaFormat: MTLPixelFormat = tenBit ? .r16Unorm : .r8Unorm
        let chromaFormat: MTLPixelFormat = tenBit ? .rg16Unorm : .rg8Unorm
        let iy = try planeTexture(input, plane: 0, format: lumaFormat)
        let ic = try planeTexture(input, plane: 1, format: chromaFormat)
        let oy = try planeTexture(output, plane: 0, format: lumaFormat)
        let oc = try planeTexture(output, plane: 1, format: chromaFormat)

        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            throw Failure("no command buffer")
        }
        enc.setBytes(&params, length: MemoryLayout<FrameChainColorParams>.size, index: 0)
        Self.dispatch(enc, kernels.toRGB, textures: [iy.0, ic.0, rgb], grid: (sourceWidth, sourceHeight))
        var current = rgb
        for stage in stages { current = stage.encode(enc, input: current) }
        enc.setBytes(&params, length: MemoryLayout<FrameChainColorParams>.size, index: 0)
        Self.dispatch(enc, kernels.toYCbCr, textures: [current, oy.0, oc.0], grid: (targetWidth / 2, targetHeight / 2))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime((iy.1, ic.1, oy.1, oc.1)) {}
        CVMetalTextureCacheFlush(textureCache, 0)
        guard cb.status == .completed else {
            throw Failure("command buffer \(cb.status.rawValue): \(cb.error.map { "\($0)" } ?? "no error")",
                          underlying: cb.error)
        }
        return (output, max(0, (cb.gpuEndTime - cb.gpuStartTime) * 1000))
    }

    static func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                         textures: [MTLTexture], grid: (Int, Int)) {
        encoder.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
        let w = pipeline.threadExecutionWidth
        let h = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / w))
        encoder.dispatchThreads(MTLSize(width: grid.0, height: grid.1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private func planeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture) {
        var ref: CVMetalTexture?
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane), h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, format, w, h, plane, &ref) == kCVReturnSuccess,
              let ref, let texture = CVMetalTextureGetTexture(ref)
        else { throw Failure("no Metal texture for plane \(plane)") }
        return (texture, ref)
    }

    private func makeOutput(format: OSType) throws -> CVPixelBuffer {
        if outputPools[format] == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: targetWidth, kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                attrs as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else { throw Failure("output pool: \(status)") }
            outputPools[format] = pool
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPools[format]!, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure("pool buffer: \(status)") }
        return buffer
    }
}

/// One step of a `FrameChain`: RGB half-float texture in, RGB half-float texture out.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
protocol FrameChainStage: AnyObject {
    /// Allocates what the stage needs for an input of `input` size and returns its output size.
    func prepare(device: MTLDevice, kernels: FrameChainKernels, input: (Int, Int)) throws -> (Int, Int)
    func encode(_ encoder: MTLComputeCommandEncoder, input: MTLTexture) -> MTLTexture
}

/// Hands its input on unchanged. A chain of only this stage is the plain colour round trip.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class PassThroughStage: FrameChainStage {
    func prepare(device: MTLDevice, kernels: FrameChainKernels, input: (Int, Int)) throws -> (Int, Int) { input }
    func encode(_ encoder: MTLComputeCommandEncoder, input: MTLTexture) -> MTLTexture { input }
}

/// Anime4K's Upscale CNN x2 (S) (`LineArtShaderSource`): four 3x3 convolutions at the input size, then a
/// depth-to-space pass that writes twice the input size and adds the bilinear input.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class LineArtStage: FrameChainStage {
    private var convolutions: [MTLComputePipelineState] = []
    private var depthToSpace: MTLComputePipelineState?
    private var features: [MTLTexture] = []
    private var output: MTLTexture?

    func prepare(device: MTLDevice, kernels: FrameChainKernels, input: (Int, Int)) throws -> (Int, Int) {
        convolutions = kernels.lineArtConvolutions
        depthToSpace = kernels.lineArtDepthToSpace
        features = try convolutions.map { _ in try FrameChain.texture(device, input.0, input.1) }
        output = try FrameChain.texture(device, input.0 * 2, input.1 * 2)
        return (input.0 * 2, input.1 * 2)
    }

    func encode(_ encoder: MTLComputeCommandEncoder, input: MTLTexture) -> MTLTexture {
        guard let depthToSpace, let output else { return input }
        var previous = input
        for (pipeline, feature) in zip(convolutions, features) {
            FrameChain.dispatch(encoder, pipeline, textures: [previous, feature], grid: (feature.width, feature.height))
            previous = feature
        }
        FrameChain.dispatch(encoder, depthToSpace, textures: [input, previous, output], grid: (output.width, output.height))
        return output
    }
}

/// Layout matches `FrameChainColorParams` in `FrameChainShaderSource`. Sample values are turned into
/// code values (`codeScale`), then into Y' 0...1 and Cb/Cr -0.5...0.5 with the range's offsets.
struct FrameChainColorParams {
    var originX: UInt32
    var originY: UInt32
    var codeScale: Float
    var maxCode: Float
    var yOffset: Float
    var yRange: Float
    var cOffset: Float
    var cRange: Float
    var kr: Float
    var kb: Float

    init(tenBit: Bool, videoRange: Bool, matrix: UpscaleMatrix, origin: (Int, Int)) {
        originX = UInt32(origin.0)
        originY = UInt32(origin.1)
        // 10-bit planes hold the code in the high bits of 16, so a unorm16 read is code * 64 / 65535.
        codeScale = tenBit ? 65535.0 / 64.0 : 255
        maxCode = tenBit ? 1023 : 255
        let s: Float = tenBit ? 4 : 1
        yOffset = videoRange ? 16 * s : 0
        yRange = videoRange ? 219 * s : maxCode
        cOffset = 128 * s
        cRange = videoRange ? 224 * s : maxCode
        kr = matrix.kr
        kb = matrix.kb
    }
}

/// The chain's pipelines, compiled once per process and device.
@available(tvOS 26, iOS 26, macOS 26, visionOS 26, *)
final class FrameChainKernels: @unchecked Sendable {
    let toRGB: MTLComputePipelineState
    let toYCbCr: MTLComputePipelineState
    let lineArtConvolutions: [MTLComputePipelineState]
    let lineArtDepthToSpace: MTLComputePipelineState

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byDevice: [UInt64: FrameChainKernels] = [:]

    private init(toRGB: MTLComputePipelineState, toYCbCr: MTLComputePipelineState,
                 lineArtConvolutions: [MTLComputePipelineState], lineArtDepthToSpace: MTLComputePipelineState) {
        self.toRGB = toRGB
        self.toYCbCr = toYCbCr
        self.lineArtConvolutions = lineArtConvolutions
        self.lineArtDepthToSpace = lineArtDepthToSpace
    }

    static func shared(for device: MTLDevice) -> FrameChainKernels? {
        lock.lock(); defer { lock.unlock() }
        if let kernels = byDevice[device.registryID] { return kernels }
        func pipeline(_ library: MTLLibrary, _ name: String) -> MTLComputePipelineState? {
            library.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        guard let chain = try? device.makeLibrary(source: FrameChainShaderSource.source, options: nil),
              let lineArt = try? device.makeLibrary(source: LineArtShaderSource.source, options: nil),
              let toRGB = pipeline(chain, "frameChainToRGB"), let toYCbCr = pipeline(chain, "frameChainToYCbCr"),
              let depthToSpace = pipeline(lineArt, LineArtShaderSource.depthToSpaceKernel)
        else { return nil }
        let convolutions = LineArtShaderSource.convolutionKernels.compactMap { pipeline(lineArt, $0) }
        guard convolutions.count == LineArtShaderSource.convolutionKernels.count else { return nil }
        let kernels = FrameChainKernels(toRGB: toRGB, toYCbCr: toYCbCr, lineArtConvolutions: convolutions,
                                        lineArtDepthToSpace: depthToSpace)
        byDevice[device.registryID] = kernels
        return kernels
    }
}

enum FrameChainShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FrameChainColorParams {
        uint originX; uint originY;
        float codeScale; float maxCode;
        float yOffset; float yRange; float cOffset; float cRange;
        float kr; float kb;
    };

    // The picture region starts at the origin (even); chroma is sampled at each luma sample's centre.
    kernel void frameChainToRGB(constant FrameChainColorParams &p [[buffer(0)]],
                                texture2d<float, access::read> yTex [[texture(0)]],
                                texture2d<float, access::sample> cTex [[texture(1)]],
                                texture2d<half, access::write> outTex [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
        constexpr sampler bilinear(coord::pixel, address::clamp_to_edge, filter::linear);
        uint2 origin = uint2(p.originX, p.originY);
        float y = (yTex.read(gid + origin).r * p.codeScale - p.yOffset) / p.yRange;
        float2 cpos = (float2(gid + origin) + 0.5) * 0.5;
        float2 c = (cTex.sample(bilinear, cpos).rg * p.codeScale - p.cOffset) / p.cRange;
        float kg = 1.0 - p.kr - p.kb;
        float r = y + 2.0 * (1.0 - p.kr) * c.y;
        float b = y + 2.0 * (1.0 - p.kb) * c.x;
        float g = (y - p.kr * r - p.kb * b) / kg;
        outTex.write(half4(half3(saturate(float3(r, g, b))), 1.0h), gid);
    }

    inline float quantize(float v, float offset, float range, constant FrameChainColorParams &p) {
        return clamp(rint(v * range + offset), 0.0, p.maxCode) / p.codeScale;
    }

    // One thread per 2x2 output luma block: the chain's last texture sampled bilinearly at the target size,
    // four Y samples and one CbCr from their mean.
    kernel void frameChainToYCbCr(constant FrameChainColorParams &p [[buffer(0)]],
                                  texture2d<float, access::sample> inTex [[texture(0)]],
                                  texture2d<float, access::write> yTex [[texture(1)]],
                                  texture2d<float, access::write> cTex [[texture(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        uint2 base = gid * 2;
        if (base.x >= yTex.get_width() || base.y >= yTex.get_height()) { return; }
        constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 size = float2(yTex.get_width(), yTex.get_height());
        float3 w = float3(p.kr, 1.0 - p.kr - p.kb, p.kb);
        float3 sum = float3(0.0);
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 pos = base + uint2(dx, dy);
                float3 rgb = saturate(inTex.sample(bilinear, (float2(pos) + 0.5) / size).rgb);
                sum += rgb;
                yTex.write(float4(quantize(dot(rgb, w), p.yOffset, p.yRange, p), 0.0, 0.0, 1.0), pos);
            }
        }
        float3 rgb = sum * 0.25;
        float y = dot(rgb, w);
        float cb = (rgb.b - y) / (2.0 * (1.0 - p.kb));
        float cr = (rgb.r - y) / (2.0 * (1.0 - p.kr));
        cTex.write(float4(quantize(cb, p.cOffset, p.cRange, p), quantize(cr, p.cOffset, p.cRange, p), 0.0, 1.0), gid);
    }
    """
}
#endif
