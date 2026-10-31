// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import CoreVideo
import Foundation
import Metal
import Testing
@testable import AetherEngine

/// The 4:4:4 kernel composes each 4:2:0 site once per threadgroup tile. It must give the same bytes as the
/// per-sample form it replaced, which composed every site four times for each output sample. That form
/// lives here, as a reference kernel built from the engine's own site function, and is run on the same
/// planes and parameters.
@Suite(.offCooperativePoolOneLane, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct DoviChroma444KernelTests {

    typealias Fixture = DoviFelInPlaceComposeTests
    typealias H = DoviGpuCurveSweepTests

    /// The 4:4:4 kernel as it was before the tile form: four `dovi_output_site` calls per output sample.
    static let referenceKernel = """

    kernel void dovi_compose_chroma_444_reference(
        texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
        texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
        texture2d<float, access::sample>       el_uv_tex     [[texture(2)]],
        texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
        constant struct DoviMetalParams&       params        [[buffer(0)]],
        uint2                                  gid           [[thread_position_in_grid]])
    {
        uint uv_width = (params.bl_width + 1u) / 2u;
        uint uv_height = (params.bl_height + 1u) / 2u;
        if (gid.x >= params.bl_width || gid.y >= params.bl_height) {
            return;
        }
        uint site_x = gid.x / 2u;
        uint site_y = gid.y / 2u;
        uint other_x = (gid.x & 1u) != 0u ? min(site_x + 1u, uv_width - 1u) : site_x;
        uint other_y = (gid.y & 1u) != 0u ? min(site_y + 1u, uv_height - 1u) : site_y;
        DoviChromaSite a = dovi_output_site(uint2(site_x, site_y), bl_y_tex, bl_uv_tex, el_uv_tex, params);
        DoviChromaSite b = dovi_output_site(uint2(other_x, site_y), bl_y_tex, bl_uv_tex, el_uv_tex, params);
        DoviChromaSite c = dovi_output_site(uint2(site_x, other_y), bl_y_tex, bl_uv_tex, el_uv_tex, params);
        DoviChromaSite d = dovi_output_site(uint2(other_x, other_y), bl_y_tex, bl_uv_tex, el_uv_tex, params);
        dovi_write_chroma(out_uv_tex, gid,
                          (a.cb + b.cb + c.cb + d.cb + 2) >> 2,
                          (a.cr + b.cr + c.cr + d.cr + 2) >> 2, params);
    }
    """

    /// A fixed pseudo-random 10-bit code for (x, y, channel, seed), over `lo...hi`.
    static func random(_ x: Int, _ y: Int, _ c: Int, _ seed: Int, lo: Int, hi: Int) -> Int {
        var h = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ c &* 83492791 ^ seed &* 2654435761)
        h ^= h >> 15; h = h &* 2246822519; h ^= h >> 13; h = h &* 3266489917; h ^= h >> 16
        return lo + Int(h % UInt32(hi - lo + 1))
    }

    /// Full-range random planes (codes 0...1023 on every plane, so the clamps and the residual's range
    /// are exercised), as opposed to the fixture's video-range pattern.
    static func randomBaseAndEnhancement(width: Int, height: Int, seed: Int) -> (bl: CVPixelBuffer, el: CVPixelBuffer)? {
        guard let bl = H.makeBuffer(width: width, height: height),
              let el = H.makeBuffer(width: width / 2, height: height / 2) else { return nil }
        H.fillPlane(bl, plane: 0, components: 1) { x, y, _ in random(x, y, 0, seed, lo: 0, hi: 1023) }
        H.fillPlane(bl, plane: 1, components: 2) { x, y, c in random(x, y, 1 + c, seed, lo: 0, hi: 1023) }
        H.fillPlane(el, plane: 0, components: 1) { x, y, _ in random(x, y, 4, seed, lo: 0, hi: 1023) }
        H.fillPlane(el, plane: 1, components: 2) { x, y, c in random(x, y, 5 + c, seed, lo: 0, hi: 1023) }
        return (bl, el)
    }

    private static func texture(_ device: MTLDevice, _ format: MTLPixelFormat, width: Int, height: Int,
                                words: [UInt16]?, write: Bool = false) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = write ? [.shaderWrite, .shaderRead] : [.shaderRead]
        let tex = try #require(device.makeTexture(descriptor: desc))
        if let words {
            let perPixel = (format == .r16Uint || format == .r16Unorm) ? 1 : 2
            words.withUnsafeBytes {
                tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * perPixel * 2)
            }
        }
        return tex
    }

    /// The reference kernel's 4:4:4 chroma plane (interleaved Cb, Cr words) for these buffers.
    static func referenceChroma(device: MTLDevice, pipeline: MTLComputePipelineState,
                                bl: CVPixelBuffer, el: CVPixelBuffer,
                                params: DoviMetalParams, frameIndex: UInt32) throws -> [UInt16] {
        let w = CVPixelBufferGetWidthOfPlane(bl, 0), h = CVPixelBufferGetHeightOfPlane(bl, 0)
        let ew = CVPixelBufferGetWidthOfPlane(el, 0), eh = CVPixelBufferGetHeightOfPlane(el, 0)
        let blY = try texture(device, .r16Uint, width: w, height: h, words: Fixture.visibleWords(bl, plane: 0))
        let blUv = try texture(device, .rg16Uint, width: (w + 1) / 2, height: (h + 1) / 2, words: Fixture.visibleWords(bl, plane: 1))
        let elUv = try texture(device, .rg16Unorm, width: (ew + 1) / 2, height: (eh + 1) / 2, words: Fixture.visibleWords(el, plane: 1))
        let out = try texture(device, .rg16Uint, width: w, height: h, words: nil, write: true)

        var p = params
        p.blWidth = UInt32(w); p.blHeight = UInt32(h)
        p.elWidth = UInt32(ew); p.elHeight = UInt32(eh)
        p.frameIndex = frameIndex
        p.polyY.clampToCapacity(); p.polyCb.clampToCapacity(); p.polyCr.clampToCapacity()
        let data = p.serialize()
        let buffer = try #require(data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: data.count, options: .storageModeShared) })

        let queue = try #require(device.makeCommandQueue())
        let cb = try #require(queue.makeCommandBuffer())
        let enc = try #require(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setTexture(blY, index: 0); enc.setTexture(blUv, index: 1)
        enc.setTexture(elUv, index: 2); enc.setTexture(out, index: 3)
        enc.setBuffer(buffer, offset: 0, index: 0)
        let tw = pipeline.threadExecutionWidth
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / tw, 8)), depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        #expect(cb.error == nil)

        var words = [UInt16](repeating: 0, count: w * h * 2)
        words.withUnsafeMutableBytes {
            out.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return words
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let width: Int
        let height: Int
        let random: Bool
        let seed: Int
        let dither: DoviDither
        let chroma: Fixture.ChromaCurves
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "pattern 256x128 polynomial, no dither", width: 256, height: 128, random: false, seed: 3, dither: .none, chroma: .polynomial),
        Case(name: "pattern 256x128 two-piece MMR, bayer", width: 256, height: 128, random: false, seed: 3, dither: .bayer8x8, chroma: .mmrTwoPieces),
        Case(name: "pattern 1920x1080 one-piece MMR, bayer", width: 1920, height: 1080, random: false, seed: 5, dither: .bayer8x8, chroma: .mmrOnePiece),
        Case(name: "pattern 200x90 (not a multiple of 16), no dither", width: 200, height: 90, random: false, seed: 9, dither: .none, chroma: .mmrTwoPieces),
        Case(name: "pattern 255x127 (odd), bayer", width: 255, height: 127, random: false, seed: 3, dither: .bayer8x8, chroma: .polynomial),
        Case(name: "random seed 1, 256x128 polynomial, no dither", width: 256, height: 128, random: true, seed: 1, dither: .none, chroma: .polynomial),
        Case(name: "random seed 2, 254x126 two-piece MMR, bayer", width: 254, height: 126, random: true, seed: 2, dither: .bayer8x8, chroma: .mmrTwoPieces),
        Case(name: "random seed 12345, 1920x1080 one-piece MMR, bayer", width: 1920, height: 1080, random: true, seed: 12345, dither: .bayer8x8, chroma: .mmrOnePiece),
        Case(name: "random seed 7, 2x2 (a single cell)", width: 2, height: 2, random: true, seed: 7, dither: .none, chroma: .polynomial),
        Case(name: "random seed 8, 17x33 (one past a tile each way)", width: 17, height: 33, random: true, seed: 8, dither: .bayer8x8, chroma: .mmrOnePiece),
    ]

    @Test("the 4:4:4 tile kernel gives the per-sample kernel's chroma plane byte for byte", arguments: cases)
    func tileKernelMatchesPerSampleKernel(_ c: Case) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: DoviShaderSource.source + Self.referenceKernel, options: nil)
        let fn = try #require(library.makeFunction(name: "dovi_compose_chroma_444_reference"))
        let reference = try device.makeComputePipelineState(function: fn)

        let composer = try #require(DoviFelComposer())
        composer.chromaFormat = .yuv444
        let pair = c.random
            ? Self.randomBaseAndEnhancement(width: c.width, height: c.height, seed: c.seed)
            : Fixture.makeBaseAndEnhancement(width: c.width, height: c.height, seed: c.seed)
        let (bl, el) = try #require(pair)
        let params = Fixture.params(dither: c.dither, residual: true, chroma: c.chroma)
        let frameIndex: UInt32 = 5

        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: frameIndex))
        let actual = Fixture.visibleWords(out, plane: 1)
        let expected = try Self.referenceChroma(device: device, pipeline: reference, bl: bl, el: el,
                                                params: params, frameIndex: frameIndex)
        #expect(actual.count == c.width * c.height * 2)
        #expect(actual == expected, "\(c.name): the tile kernel's chroma differs from the per-sample kernel's")
    }

    @Test("the 4:4:4 pipeline can run the 16 x 16 threadgroup the tile kernel needs")
    func pipelineAllowsTheTile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pipelines = try DoviFelComposer.SharedPipelines.getOrCreate(device: device)
        #expect(pipelines.chroma444Pipeline.maxTotalThreadsPerThreadgroup >= 256)
    }
}
#endif
