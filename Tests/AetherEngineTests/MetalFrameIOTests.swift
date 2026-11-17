import Foundation
import Testing
import CoreVideo
import Metal
@testable import AetherEngine

/// The Metal plumbing the GPU frame stages share (audit GPU-R201): the dispatch fallback for GPUs without
/// non-uniform threadgroups, the lease that keeps a frame's texture cache alive, and the per-device
/// pipeline cache that keeps a failed build.
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

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct BuildFailed: Error {}

    /// Audit GPU-R202: the chain's and the upscaler's kernels kept only successes, so a build that failed was
    /// compiled again (two libraries for the chain) on every tone-map rebuild and every upscaler stage.
    @Test("a failed pipeline build is kept and later callers fail without compiling again")
    func failedBuildIsKept() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache = MetalPipelineCache<Int>()
        let compiles = Counter()
        for _ in 0..<5 {
            #expect(throws: BuildFailed.self) {
                try cache.resolve(device: device) {
                    compiles.bump()
                    throw BuildFailed()
                }
            }
        }
        #expect(compiles.count == 1)
        cache.removeAll()
        #expect(try cache.resolve(device: device) { compiles.bump(); return 7 } == 7)
        #expect(try cache.resolve(device: device) { compiles.bump(); return 8 } == 7)
        #expect(compiles.count == 2)
    }

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
        func advance(_ by: Duration) { lock.lock(); instant = instant.advanced(by: by); lock.unlock() }
    }

    /// Review R-P4-1: a failure kept for the life of the process turned a transient compiler-service
    /// failure (an MTLCompilerService XPC interruption under memory pressure) into no tone mapping and
    /// no upscaling until the app relaunched. A failure now expires; inside the interval it still fails
    /// fast, so GPU-R202's no-recompile-per-stage-build holds.
    @Test("a kept failure expires after the retry interval and the next caller compiles again (review R-P4-1)")
    func keptFailureExpires() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clock = FakeClock()
        let cache = MetalPipelineCache<Int>(failureRetryInterval: .seconds(60), now: { clock.now })
        let compiles = Counter()
        #expect(throws: BuildFailed.self) { try cache.resolve(device: device) { compiles.bump(); throw BuildFailed() } }
        clock.advance(.seconds(59))
        #expect(throws: BuildFailed.self) { try cache.resolve(device: device) { compiles.bump(); return 1 } }
        #expect(compiles.count == 1)
        clock.advance(.seconds(1))
        #expect(try cache.resolve(device: device) { compiles.bump(); return 2 } == 2)
        clock.advance(.seconds(3600))
        #expect(try cache.resolve(device: device) { compiles.bump(); return 3 } == 2, "a success is kept for good")
        #expect(compiles.count == 2)
    }

    @Test("without a retry interval a failure is kept for the process, as the FEL composer wants (review R-P4-1)")
    func failureWithoutRetryIntervalIsKept() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let clock = FakeClock()
        let cache = MetalPipelineCache<Int>(failureRetryInterval: nil, now: { clock.now })
        let compiles = Counter()
        #expect(throws: BuildFailed.self) { try cache.resolve(device: device) { compiles.bump(); throw BuildFailed() } }
        clock.advance(.seconds(86_400))
        #expect(throws: BuildFailed.self) { try cache.resolve(device: device) { compiles.bump(); return 1 } }
        #expect(compiles.count == 1)
    }
}
