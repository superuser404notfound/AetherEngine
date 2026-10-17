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
        for kernel in ["dovi_compose_luma", "dovi_compose_chroma", "dovi_layout_probe"] {
            #expect(DoviShaderSource.source.contains("kernel void \(kernel)("),
                    "runtime source is missing \(kernel)")
        }
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
}
#endif
