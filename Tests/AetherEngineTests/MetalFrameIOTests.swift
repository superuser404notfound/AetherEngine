import Foundation
import Testing
import CoreVideo
import Metal
@testable import AetherEngine

/// The Metal plumbing the GPU frame stages share (audit GPU-R201): the dispatch fallback for GPUs without
/// non-uniform threadgroups and the lease that keeps a frame's texture cache alive.
@Suite("Metal frame I/O shared by the GPU stages", .timeLimit(.minutes(3)),
       .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct MetalFrameIOTests {

    /// Audit GPU-204: whole threadgroups cover the grid, rounded up on each axis.
    @Test("without non-uniform threadgroups the dispatch rounds the grid up to whole groups")
    func threadgroupCountCoversTheGrid() {
        let group = MTLSize(width: 32, height: 16, depth: 1)
        let count = MetalFrameIO.threadgroupCount(grid: (322, 182), threadgroup: group)
        #expect(count.width == 11 && count.height == 12 && count.depth == 1)
        let exact = MetalFrameIO.threadgroupCount(grid: (320, 176), threadgroup: group)
        #expect(exact.width == 10 && exact.height == 11)
    }

    @Test("the device's own answer is used unless a caller overrides it")
    func nonUniformSupportFollowsTheDevice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let io = try #require(MetalFrameIO(device: device))
        #expect(io.supportsNonUniformThreadgroups == MetalFrameIO.supportsNonUniformThreadgroups(device))
        #expect(MetalFrameIO(device: device, nonUniformThreadgroups: false)?.supportsNonUniformThreadgroups == false)
    }

    /// Audit GPU-201: a lease outlives the I/O object that made its textures and still holds that cache.
    @Test("a lease holds its textures' cache after their maker let go")
    func leaseHoldsTheCache() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let made = try #require(MetalFrameIO(device: device))
        var io: MetalFrameIO? = made
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &pb)
        let buffer = try #require(pb)
        let lease = try #require(io?.lease())
        let cache = try #require(io?.textureCache)
        let luma = io?.texture(buffer, plane: 0, format: .r8Unorm, in: lease)
        let chroma = io?.texture(buffer, plane: 1, format: .rg8Unorm, in: lease)
        #expect(luma?.width == 64 && luma?.height == 36)
        #expect(chroma?.width == 32 && chroma?.height == 18)
        io = nil
        #expect(lease.cache === cache)
        #expect(lease.count == 2)
    }
}
