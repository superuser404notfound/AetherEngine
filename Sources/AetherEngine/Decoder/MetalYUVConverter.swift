import Foundation
import CoreVideo
import AetherLibavcodec
import AetherLibavutil

#if canImport(Metal)
import Metal

/// Small, session-scoped YUV420P/YUV420P10LE -> NV12/P010 converter.
///
/// The source planes are uploaded into three reused shared textures and the destination
/// textures are views of the decoder's IOSurface-backed CVPixelBuffer.  The command buffer is
/// waited on before returning: callers may immediately enqueue the sample and the pool may
/// recycle the buffer without racing the compute pass.
final class MetalYUVConverter {
    enum Result: Equatable {
        case converted
        case unavailable(String)
        case failed(String)
    }

    /// This is deliberately a format policy, independent of device availability, so routing can
    /// be tested on CI machines without a Metal device.
    static func supports(codecID: AVCodecID, pixelFormat: AVPixelFormat) -> Bool {
        guard codecID == AV_CODEC_ID_AV1 else { return false }
        return pixelFormat == AV_PIX_FMT_YUV420P
            || pixelFormat == AV_PIX_FMT_YUVJ420P
            || pixelFormat == AV_PIX_FMT_YUV420P10LE
    }

    /// Convert FFmpeg's low-aligned 10-bit code value to the high-aligned P010 word. Kept as a
    /// small pure seam for exactness tests; the Metal kernel mirrors this integer arithmetic.
    static func p010Code(value: UInt16, fullRange: Bool, chroma: Bool = false) -> UInt16 {
        let input = UInt32(min(value, 1023))
        let code: UInt32
        if fullRange {
            let span: UInt32 = chroma ? 896 : 876
            let offset: UInt32 = 64
            code = offset + (input * span + 511) / 1023
        } else {
            let low: UInt32 = 64
            let high: UInt32 = chroma ? 960 : 940
            code = min(max(input, low), high)
        }
        return UInt16(min(code, 1023) << 6)
    }

    private struct Parameters {
        var fullRange: UInt32
    }

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let textureCache: CVMetalTextureCache?
    private var pipeline8: MTLComputePipelineState?
    private var pipeline10: MTLComputePipelineState?
    private var sourceY: MTLTexture?
    private var sourceU: MTLTexture?
    private var sourceV: MTLTexture?
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var source10Bit = false
    private var initializationFailure: String?

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.device = nil
            self.commandQueue = nil
            self.textureCache = nil
            initializationFailure = "no Metal device"
            return
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            self.commandQueue = nil
            self.textureCache = nil
            initializationFailure = "command queue creation failed"
            return
        }
        commandQueue = queue
        // CVMetalTextureCache defaults to shader-read textures. Declare both usages up front so
        // plane views created for our destination IOSurfaces are legal compute write targets on
        // tvOS as well as macOS. The per-texture attributes below repeat this contract for cache
        // implementations that do not inherit all cache attributes.
        let usage = NSNumber(value: MTLTextureUsage.shaderRead.union(.shaderWrite).rawValue)
        let cacheAttributes: NSDictionary = [kCVMetalTextureUsage: usage]
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault, cacheAttributes, device, nil, &cache
        ) == kCVReturnSuccess,
              let cache else {
            textureCache = nil
            initializationFailure = "texture cache creation failed"
            return
        }
        textureCache = cache

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let fn8 = library.makeFunction(name: "yuv420_to_nv12"),
                  let fn10 = library.makeFunction(name: "yuv420p10_to_p010") else {
                initializationFailure = "conversion shader function missing"
                return
            }
            pipeline8 = try device.makeComputePipelineState(function: fn8)
            pipeline10 = try device.makeComputePipelineState(function: fn10)
        } catch {
            initializationFailure = "conversion shader compilation failed: \(error)"
        }
    }

    func convert(
        frame: UnsafeMutablePointer<AVFrame>,
        destination: CVPixelBuffer,
        pixelFormat: AVPixelFormat,
        fullRange: Bool
    ) -> Result {
        guard Self.supports(codecID: AV_CODEC_ID_AV1, pixelFormat: pixelFormat) else {
            return .unavailable("unsupported pixel format \(pixelFormat.rawValue)")
        }
        let is10Bit = pixelFormat == AV_PIX_FMT_YUV420P10LE
        guard let device, let commandQueue, let textureCache,
              let pipeline = is10Bit ? pipeline10 : pipeline8 else {
            return .unavailable(initializationFailure ?? "Metal conversion unavailable")
        }

        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let chromaWidth = (width + 1) / 2
        guard width > 0, height > 0,
              let y = frame.pointee.data.0,
              let u = frame.pointee.data.1,
              let v = frame.pointee.data.2,
              frame.pointee.linesize.0 > 0,
              frame.pointee.linesize.1 > 0,
              frame.pointee.linesize.2 > 0,
              Int(frame.pointee.linesize.0) >= width * (is10Bit ? 2 : 1),
              Int(frame.pointee.linesize.1) >= chromaWidth * (is10Bit ? 2 : 1),
              Int(frame.pointee.linesize.2) >= chromaWidth * (is10Bit ? 2 : 1) else {
            return .failed("frame has no complete YUV420 planes")
        }

        if !ensureSourceTextures(device: device, width: width, height: height, is10Bit: is10Bit) {
            return .failed("source texture allocation failed")
        }
        let chromaHeight = (height + 1) / 2
        let regionY = MTLRegionMake2D(0, 0, width, height)
        let regionUV = MTLRegionMake2D(0, 0, chromaWidth, chromaHeight)
        sourceY?.replace(region: regionY, mipmapLevel: 0, withBytes: y,
                         bytesPerRow: Int(frame.pointee.linesize.0))
        sourceU?.replace(region: regionUV, mipmapLevel: 0, withBytes: u,
                         bytesPerRow: Int(frame.pointee.linesize.1))
        sourceV?.replace(region: regionUV, mipmapLevel: 0, withBytes: v,
                         bytesPerRow: Int(frame.pointee.linesize.2))

        let yWidth = CVPixelBufferGetWidthOfPlane(destination, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(destination, 0)
        let uvWidth = CVPixelBufferGetWidthOfPlane(destination, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(destination, 1)
        // CVPixelBuffer's bi-planar formats are exposed by CVMetalTextureCache as normalized
        // textures on Apple platforms (r8/rg8 and r16/rg16), not integer views. The kernels
        // write normalized values while retaining exact 8-bit and high-aligned 10-bit samples.
        let yFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm
        let usageAttributes: NSDictionary = [
            kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage.shaderRead.union(.shaderWrite).rawValue)
        ]
        var yTexture: CVMetalTexture?
        var uvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, destination, usageAttributes, yFormat,
            yWidth, yHeight, 0, &yTexture
        ) == kCVReturnSuccess,
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, destination, usageAttributes, uvFormat,
            uvWidth, uvHeight, 1, &uvTexture
        ) == kCVReturnSuccess,
        let yOut = yTexture.flatMap(CVMetalTextureGetTexture),
        let uvOut = uvTexture.flatMap(CVMetalTextureGetTexture),
        let sourceY, let sourceU, let sourceV,
        let commandBuffer = commandQueue.makeCommandBuffer(),
        let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return .failed("destination texture or command buffer creation failed")
        }

        var params = Parameters(fullRange: fullRange ? 1 : 0)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceY, index: 0)
        encoder.setTexture(sourceU, index: 1)
        encoder.setTexture(sourceV, index: 2)
        encoder.setTexture(yOut, index: 3)
        encoder.setTexture(uvOut, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<Parameters>.stride, index: 0)
        let threads = MTLSize(width: width, height: height, depth: 1)
        let w = max(1, min(pipeline.threadExecutionWidth, width))
        let h = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / w, height))
        encoder.dispatchThreads(threads, threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            return .failed("GPU command buffer status \(commandBuffer.status.rawValue)")
        }
        return .converted
    }

    private func ensureSourceTextures(device: MTLDevice, width: Int, height: Int, is10Bit: Bool) -> Bool {
        guard sourceY == nil || sourceWidth != width || sourceHeight != height || source10Bit != is10Bit else {
            return true
        }
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        // Metal color textures use normalized float channels. We upload the FFmpeg words
        // unchanged and quantize the normalized readback in the kernel; integer texture channel
        // types are not valid for texture2d on current Apple GPU compilers.
        let format: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        func makeTexture(width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            return device.makeTexture(descriptor: descriptor)
        }
        guard let y = makeTexture(width: width, height: height),
              let u = makeTexture(width: chromaWidth, height: chromaHeight),
              let v = makeTexture(width: chromaWidth, height: chromaHeight) else {
            sourceY = nil
            sourceU = nil
            sourceV = nil
            return false
        }
        sourceY = y
        sourceU = u
        sourceV = v
        sourceWidth = width
        sourceHeight = height
        source10Bit = is10Bit
        return true
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters { uint fullRange; };

    inline uchar limitedY8(uchar x, bool full) {
        uint v = full ? ((uint(x) * 219u + 127u) / 255u + 16u) : uint(x);
        return uchar(clamp(v, 16u, 235u));
    }
    inline uchar limitedUV8(uchar x, bool full) {
        uint v = full ? ((uint(x) * 224u + 127u) / 255u + 16u) : uint(x);
        return uchar(clamp(v, 16u, 240u));
    }
    inline uchar sample8(float4 x) {
        return uchar(round(clamp(x.r, 0.0f, 1.0f) * 255.0f));
    }
    inline ushort sample10(float4 x) {
        return ushort(round(clamp(x.r, 0.0f, 1.0f) * 65535.0f));
    }
    inline float limitedY10(ushort x, bool full) {
        uint v = uint(x);
        v = full ? ((v * 876u + 511u) / 1023u + 64u) : clamp(v, 64u, 940u);
        return float(clamp(v, 64u, 940u) << 6) / 65535.0f;
    }
    inline float limitedUV10(ushort x, bool full) {
        uint v = uint(x);
        v = full ? ((v * 896u + 511u) / 1023u + 64u) : clamp(v, 64u, 960u);
        return float(clamp(v, 64u, 960u) << 6) / 65535.0f;
    }

    kernel void yuv420_to_nv12(
        texture2d<float, access::read> y,
        texture2d<float, access::read> u,
        texture2d<float, access::read> v,
        texture2d<float, access::write> outY,
        texture2d<float, access::write> outUV,
        constant Parameters& p,
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outY.get_width() || gid.y >= outY.get_height()) return;
        bool full = p.fullRange != 0;
        outY.write(float4(float(limitedY8(sample8(y.read(gid)), full)) / 255.0f, 0, 0, 1), gid);
        if ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u) {
            uint2 c = gid / 2u;
            outUV.write(float4(float(limitedUV8(sample8(u.read(c)), full)) / 255.0f,
                               float(limitedUV8(sample8(v.read(c)), full)) / 255.0f, 0, 1), c);
        }
    }

    kernel void yuv420p10_to_p010(
        texture2d<float, access::read> y,
        texture2d<float, access::read> u,
        texture2d<float, access::read> v,
        texture2d<float, access::write> outY,
        texture2d<float, access::write> outUV,
        constant Parameters& p,
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outY.get_width() || gid.y >= outY.get_height()) return;
        bool full = p.fullRange != 0;
        outY.write(float4(limitedY10(sample10(y.read(gid)), full), 0, 0, 1), gid);
        if ((gid.x & 1u) == 0u && (gid.y & 1u) == 0u) {
            uint2 c = gid / 2u;
            outUV.write(float4(limitedUV10(sample10(u.read(c)), full),
                               limitedUV10(sample10(v.read(c)), full), 0, 1), c);
        }
    }
    """#
}

#else

/// Linux/non-Metal build seam. AetherEngine's supported playback platforms have Metal, but the
/// decoder still compiles for tooling and tests and will use its swscale fallback there.
final class MetalYUVConverter {
    enum Result: Equatable { case converted, unavailable(String), failed(String) }

    static func supports(codecID: AVCodecID, pixelFormat: AVPixelFormat) -> Bool {
        guard codecID == AV_CODEC_ID_AV1 else { return false }
        return pixelFormat == AV_PIX_FMT_YUV420P
            || pixelFormat == AV_PIX_FMT_YUVJ420P
            || pixelFormat == AV_PIX_FMT_YUV420P10LE
    }

    static func p010Code(value: UInt16, fullRange: Bool, chroma: Bool = false) -> UInt16 {
        let input = UInt32(min(value, 1023))
        let code: UInt32
        if fullRange {
            let span: UInt32 = chroma ? 896 : 876
            code = 64 + (input * span + 511) / 1023
        } else {
            let high: UInt32 = chroma ? 960 : 940
            code = min(max(input, 64), high)
        }
        return UInt16(min(code, 1023) << 6)
    }
}

#endif
