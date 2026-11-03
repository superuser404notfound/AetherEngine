// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import Metal
@testable import AetherEngine

/// Guards the Dolby Vision shader source integrity and parameter serialization.
@Suite(.offCooperativePoolOneLane)
struct DoviShaderSyncTests {

    static let metalAvailable = MTLCreateSystemDefaultDevice() != nil

    @Test("The runtime-compiled source carries all expected kernels")
    func runtimeSourceCarriesKernels() {
        for kernel in ["dovi_compose_luma", "dovi_compose_chroma", "dovi_compose_chroma_422", "dovi_compose_chroma_444", "dovi_layout_probe"] {
            #expect(DoviShaderSource.source.contains("kernel void \(kernel)("),
                    "runtime source is missing \(kernel)")
        }
    }

    @Test("The pool-only source has the pool kernels and names no read_write binding; the full source adds the in-place kernels")
    func poolSourceHasNoReadWriteBinding() {
        let pool = DoviShaderSource.poolSource
        for kernel in ["dovi_compose_luma", "dovi_compose_chroma", "dovi_compose_chroma_422", "dovi_compose_chroma_444", "dovi_layout_probe"] {
            #expect(pool.contains("kernel void \(kernel)("), "pool source is missing \(kernel)")
        }
        #expect(!pool.contains("read_write"), "a device below tier 2 must not compile any read_write text")
        #expect(!pool.contains("_in_place"))
        #expect(DoviShaderSource.source(includingInPlace: false) == pool)

        let full = DoviShaderSource.source(includingInPlace: true)
        #expect(full == DoviShaderSource.source)
        for kernel in ["dovi_compose_luma_in_place", "dovi_compose_chroma_in_place"] {
            #expect(full.contains("kernel void \(kernel)("), "full source is missing \(kernel)")
        }
        #expect(full.hasPrefix(pool))
    }

    @Test("the pool-only source builds the pool pipelines and leaves the in-place pipelines nil", .enabled(if: DoviShaderSyncTests.metalAvailable, "needs a Metal device"))
    func poolSourceBuildsPoolPipelines() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // `inPlace: false`: a device below tier 2, which never looks for the in-place kernels.
        let below = try DoviFelComposer.SharedPipelines.compile(device: device, source: DoviShaderSource.poolSource, inPlace: false)
        #expect(below.lumaInPlacePipeline == nil && below.chromaInPlacePipeline == nil)
        #expect(!below.hasInPlacePipelines)
        // `inPlace: true` over a source without the kernels: the in-place build fails and the pool pipelines
        // still come back, so a failed in-place build cannot cost a device its pool path.
        let missing = try DoviFelComposer.SharedPipelines.compile(device: device, source: DoviShaderSource.poolSource, inPlace: true)
        #expect(missing.lumaInPlacePipeline == nil && missing.chromaInPlacePipeline == nil)
        for format in [DoviFelChromaFormat.yuv420, .yuv422, .yuv444] {
            #expect(below.pipeline(for: format).maxTotalThreadsPerThreadgroup > 0)
            #expect(missing.pipeline(for: format).maxTotalThreadsPerThreadgroup > 0)
        }
        #expect(below.lumaPipeline.maxTotalThreadsPerThreadgroup > 0)
        #expect(missing.lumaPipeline.maxTotalThreadsPerThreadgroup > 0)
    }

    static let tier2Available = MTLCreateSystemDefaultDevice().map { DoviFelComposer.supportsInPlaceReadWrite($0.readWriteTextureSupport) } ?? false

    @Test("the full source builds the in-place pipelines on a tier 2 device", .enabled(if: DoviShaderSyncTests.tier2Available, "needs a tier 2 Metal device"))
    func fullSourceBuildsInPlacePipelines() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pipelines = try DoviFelComposer.SharedPipelines.compile(device: device, source: DoviShaderSource.source, inPlace: true)
        #expect(pipelines.hasInPlacePipelines)
    }

    @Test("the tier line says the tier and whether in-place compose is on")
    func tierStatusLine() {
        let line2 = DoviFelComposer.inPlaceStatusLine(tier: .tier2, switchedOn: true)
        #expect(line2 == "[DoviFelComposer] read_write texture tier 2; in-place compose on")
        #expect(DoviFelComposer.inPlaceStatusLine(tier: .tier2, switchedOn: false).contains("tier 2; in-place compose off"))
        let line1 = DoviFelComposer.inPlaceStatusLine(tier: .tier1, switchedOn: true)
        #expect(line1.contains("tier 1; in-place compose off"))
        #expect(line1.contains("needs tier 2"))
        #expect(DoviFelComposer.inPlaceStatusLine(tier: .tierNone, switchedOn: true).contains("tier none; in-place compose off"))
    }

    @Test("Serializing produces exactly the byte count the C struct occupies")
    func serializedSizeIsStable() {
        var params = DoviMetalParams()
        params.polyY.numPivots = 9
        params.mmrCb.coefShift = 23
        #expect(params.serialize().count == DoviMetalParams.serializedSize)
        #expect(DoviMetalParams.serializedSize == 2972,
                "The parameter ABI changed; update tests and probe asserts")
    }

    @Test("two composers share one pipeline state instance (compiled once lazily)", .enabled(if: DoviShaderSyncTests.metalAvailable, "needs a Metal device"))
    func twoComposersSharePipelineStateInstance() throws {
        let c1 = try #require(DoviFelComposer())
        let c2 = try #require(DoviFelComposer())

        // Before accessing pipelines or composing, both composers exist without separate compiles.
        // Accessing pipelines returns identical instances (shared across composers).
        let luma1 = try #require(c1.lumaPipelineForTesting)
        let luma2 = try #require(c2.lumaPipelineForTesting)
        let chroma1 = try #require(c1.chromaPipelineForTesting)
        let chroma2 = try #require(c2.chromaPipelineForTesting)

        #expect(luma1 === luma2, "Composers must share the exact same luma pipeline state instance")
        #expect(chroma1 === chroma2, "Composers must share the exact same chroma pipeline state instance")
    }

    private final class CompileCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("a shader that fails to compile is compiled once; every later call fails fast", .enabled(if: DoviShaderSyncTests.metalAvailable, "needs a Metal device"))
    func compileFailureIsCached() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache = DoviFelComposer.SharedPipelines.Cache()
        let compiles = CompileCounter()
        for _ in 0..<5 {
            #expect(throws: DoviFelComposer.ComposerError.self) {
                try cache.resolve(device: device) {
                    compiles.bump()
                    throw DoviFelComposer.ComposerError.missingKernelFunction
                }
            }
        }
        #expect(compiles.count == 1)
    }

    @Test("concurrent first uses of the pipelines compile once", .enabled(if: DoviShaderSyncTests.metalAvailable, "needs a Metal device"))
    func concurrentResolveCompilesOnce() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache = DoviFelComposer.SharedPipelines.Cache()
        let compiles = CompileCounter()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            _ = try? cache.resolve(device: device) {
                compiles.bump()
                return try DoviFelComposer.SharedPipelines.compile(device: device, source: DoviShaderSource.source)
            }
        }
        #expect(compiles.count == 1)
    }

    @Test("prewarm builds the shared pipelines a composer then uses", .enabled(if: DoviShaderSyncTests.metalAvailable, "needs a Metal device"))
    func prewarmBuildsTheSharedPipelines() async throws {
        #expect(await AetherEngine.prewarmDualLayerDolbyVision())
        let device = try #require(MTLCreateSystemDefaultDevice())
        let shared = try DoviFelComposer.SharedPipelines.getOrCreate(device: device)
        let composer = try #require(DoviFelComposer())
        #expect(composer.lumaPipelineForTesting === shared.lumaPipeline, "the composer reuses the warmed pipeline, no second compile")
        #expect(await AetherEngine.prewarmDualLayerDolbyVision(), "a second warm is a cache hit")
    }
}
#endif
