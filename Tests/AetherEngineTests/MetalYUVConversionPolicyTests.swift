import Testing
import CoreVideo
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

#if canImport(Metal)
import Metal
#endif

@Suite("AV1 Metal YUV conversion policy")
struct MetalYUVConversionPolicyTests {
    @Test("the fast path is limited to AV1 YUV420 planar formats")
    func supportedFormats() {
        #expect(MetalYUVConverter.supports(codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_YUV420P))
        #expect(MetalYUVConverter.supports(codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_YUVJ420P))
        #expect(MetalYUVConverter.supports(codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_YUV420P10LE))
    }

    @Test("other codecs and layouts always use swscale")
    func unsupportedRoutesToFallback() {
        #expect(!MetalYUVConverter.supports(codecID: AV_CODEC_ID_HEVC, pixelFormat: AV_PIX_FMT_YUV420P))
        #expect(!MetalYUVConverter.supports(codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_NV12))
        #expect(!MetalYUVConverter.supports(codecID: AV_CODEC_ID_AV1, pixelFormat: AV_PIX_FMT_YUV444P))
    }

    @Test("10-bit FFmpeg samples are low-aligned and become high-aligned P010")
    func p010PackingAndRange() {
        #expect(MetalYUVConverter.p010Code(value: 64, fullRange: false) == UInt16(64 << 6))
        #expect(MetalYUVConverter.p010Code(value: 0, fullRange: false) == UInt16(64 << 6))
        #expect(MetalYUVConverter.p010Code(value: 1023, fullRange: false) == UInt16(940 << 6))
        #expect(MetalYUVConverter.p010Code(value: 0, fullRange: true) == UInt16(64 << 6))
        #expect(MetalYUVConverter.p010Code(value: 1023, fullRange: true) == UInt16(940 << 6))
        #expect(MetalYUVConverter.p010Code(value: 0, fullRange: true, chroma: true) == UInt16(64 << 6))
        #expect(MetalYUVConverter.p010Code(value: 1023, fullRange: true, chroma: true) == UInt16(960 << 6))
    }

#if canImport(Metal)
    @Test("Metal converts a small NV12 frame and preserves video-range samples")
    func gpuNV12Smoke() throws {
        // A machine without a Metal device is an expected CI configuration. Once a device is
        // present, conversion failures are assertions rather than skips.
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let converter = MetalYUVConverter()
        let frame = try makeFrame(format: AV_PIX_FMT_YUV420P)
        defer { var owned: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&owned) }
        let y = frame.pointee.data.0!
        let u = frame.pointee.data.1!
        let v = frame.pointee.data.2!
        y[0] = 16; y[1] = 235
        y[Int(frame.pointee.linesize.0)] = 81; y[Int(frame.pointee.linesize.0) + 1] = 145
        u[0] = 128; v[0] = 129

        let destination = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let result = converter.convert(
            frame: frame, destination: destination, pixelFormat: AV_PIX_FMT_YUV420P, fullRange: false
        )
        #expect(result == .converted)
        CVPixelBufferLockBaseAddress(destination, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(destination, [.readOnly]) }
        let yOut = CVPixelBufferGetBaseAddressOfPlane(destination, 0)!.assumingMemoryBound(to: UInt8.self)
        let uvOut = CVPixelBufferGetBaseAddressOfPlane(destination, 1)!.assumingMemoryBound(to: UInt8.self)
        #expect(yOut[0] == 16 && yOut[1] == 235)
        #expect(yOut[CVPixelBufferGetBytesPerRowOfPlane(destination, 0)] == 81)
        #expect(uvOut[0] == 128 && uvOut[1] == 129)
    }

    @Test("Metal converts low-aligned 10-bit samples to high-aligned P010")
    func gpuP010Smoke() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let converter = MetalYUVConverter()
        let frame = try makeFrame(format: AV_PIX_FMT_YUV420P10LE)
        defer { var owned: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&owned) }
        let y = UnsafeMutableRawPointer(frame.pointee.data.0!).assumingMemoryBound(to: UInt16.self)
        let u = UnsafeMutableRawPointer(frame.pointee.data.1!).assumingMemoryBound(to: UInt16.self)
        let v = UnsafeMutableRawPointer(frame.pointee.data.2!).assumingMemoryBound(to: UInt16.self)
        let yStride = Int(frame.pointee.linesize.0) / MemoryLayout<UInt16>.stride
        y[0] = 64; y[1] = 940
        y[yStride] = 640; y[yStride + 1] = 512
        u[0] = 940; v[0] = 64

        let destination = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let result = converter.convert(
            frame: frame, destination: destination, pixelFormat: AV_PIX_FMT_YUV420P10LE, fullRange: false
        )
        #expect(result == .converted)
        CVPixelBufferLockBaseAddress(destination, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(destination, [.readOnly]) }
        let yOut = CVPixelBufferGetBaseAddressOfPlane(destination, 0)!.assumingMemoryBound(to: UInt16.self)
        let uvOut = CVPixelBufferGetBaseAddressOfPlane(destination, 1)!.assumingMemoryBound(to: UInt16.self)
        let outStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0) / MemoryLayout<UInt16>.stride
        #expect(yOut[0] == UInt16(64 << 6) && yOut[1] == UInt16(940 << 6))
        #expect(yOut[outStride] == UInt16(640 << 6))
        #expect(uvOut[0] == UInt16(940 << 6) && uvOut[1] == UInt16(64 << 6))
    }

    @Test("negative FFmpeg plane strides use the conversion fallback result")
    func negativeStrideIsRejected() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let converter = MetalYUVConverter()
        let frame = try makeFrame(format: AV_PIX_FMT_YUV420P)
        defer { var owned: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&owned) }
        frame.pointee.linesize.0 = -frame.pointee.linesize.0
        let destination = try makePixelBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let result = converter.convert(
            frame: frame, destination: destination, pixelFormat: AV_PIX_FMT_YUV420P, fullRange: false
        )
        if case .failed = result {
            // Expected: the caller's swscale path owns the negative-stride fallback.
        } else {
            Issue.record("negative stride must not be submitted to the Metal texture upload")
        }
    }

    private func makeFrame(format: AVPixelFormat) throws -> UnsafeMutablePointer<AVFrame> {
        let frame = try #require(av_frame_alloc())
        frame.pointee.width = 2
        frame.pointee.height = 2
        frame.pointee.format = format.rawValue
        guard av_frame_get_buffer(frame, 0) >= 0 else {
            var owned: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&owned)
            throw NSError(domain: "MetalYUVConversionTests", code: 1)
        }
        return frame
    }

    private func makePixelBuffer(format: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: NSDictionary = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 2, 2, format, attributes, &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        return try #require(pixelBuffer)
    }
#endif
}
