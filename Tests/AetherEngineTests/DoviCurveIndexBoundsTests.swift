// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import Metal
@testable import AetherEngine

/// A pivot index the kernels form from `num_pivots` stays inside the parameter block for every pivot count,
/// so a load a GPU compiler executes despite its guard cannot leave the buffer. The parser's identity
/// fail-safe (`num_pivots` 0, for a curve it rejects) is the case that faulted: a rejected Cb curve next to an
/// MMR Cr curve made the A12 read 4 GiB past `poly_cb.num_pivots` (`dovi_last_pivot` in `DoviShaderSource`).
@Suite(.offCooperativePoolOneLane)
struct DoviCurveIndexBoundsTests {

    typealias H = DoviGpuCurveSweepTests

    /// (num_pivots, the index the kernels must read).
    static let lastPivotCases: [(UInt32, UInt32)] = [
        (0, 0),                                // the parser's identity: the index that read 4 GiB past the block
        (1, 0),
        (2, 1),
        (3, 2),
        (9, 8),
        (10, 8),                               // over capacity (clampToCapacity zeroes it; the shader holds anyway)
        (UInt32.max, 8),
    ]

    /// Runs `dovi_last_pivot` on the GPU, compiled from the composer's own source, for one curve.
    private static func lastPivotOnGpu(numPivots: UInt32) throws -> (index: UInt32, value: UInt32) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let probe = """
        kernel void dovi_last_pivot_probe(constant struct DoviMetalParams& params [[buffer(0)]],
                                          device uint* out [[buffer(1)]],
                                          uint tid [[thread_position_in_grid]]) {
            if (tid != 0u) { return; }
            out[0] = dovi_last_pivot(params.poly_cb);
            out[1] = params.poly_cb.pivots[dovi_last_pivot(params.poly_cb)];
        }
        """
        let library = try device.makeLibrary(source: DoviShaderSource.poolSource + probe, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "dovi_last_pivot_probe")))
        var curve = DoviPolynomialParams()
        curve.numPivots = numPivots
        curve.pivots = (0..<DoviPolynomialParams.maxPivots).map { UInt32(100 + $0) }
        var params = DoviMetalParams()
        params.polyCb = curve                  // the curve that faulted; serialized as is, without clampToCapacity
        let bytes = params.serialize()
        let block = try #require(device.makeBuffer(length: bytes.count, options: .storageModeShared))
        bytes.withUnsafeBytes { block.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        let out = try #require(device.makeBuffer(length: 8, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(block, offset: 0, index: 0)
        encoder.setBuffer(out, offset: 0, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.error == nil)
        let words = out.contents().bindMemory(to: UInt32.self, capacity: 2)
        return (words[0], words[1])
    }

    @Test("the last-pivot index stays inside the pivots for every pivot count, the identity fail-safe's 0 included",
          .enabled(if: DoviShaderSyncTests.metalAvailable, "needs a Metal device"),
          arguments: lastPivotCases)
    func lastPivotIndexIsBounded(numPivots: UInt32, expected: UInt32) throws {
        let result = try Self.lastPivotOnGpu(numPivots: numPivots)
        #expect(result.index == expected)
        #expect(result.value == 100 + expected)
    }

    /// Every index the kernels form from `num_pivots` goes through a bound: `dovi_last_pivot` or the capped piece
    /// count in `dovi_select_piece`. A plain `num_pivots - 1` in an index is exactly what faulted on the A12.
    @Test("the kernels form no pivot index from num_pivots without a bound")
    func noUnboundedPivotIndexInTheKernels() {
        let source = DoviShaderSource.kernels + DoviShaderSource.inPlaceKernels
        #expect(!source.contains("num_pivots - 1"))
        #expect(!source.contains("int(curve.num_pivots) - 2"))
    }

    /// The shape that faulted, composed: Cb rejected by the parser (identity, `num_pivots` 0) and Cr an MMR curve
    /// that reads the Cb term. Cb passes the base layer through; Cr's Cb input has no range to be clamped to.
    @Test("a rejected Cb curve next to an MMR Cr curve composes as identity Cb and an unclamped Cb input to Cr",
          .enabled(if: DoviShaderSyncTests.metalAvailable, "needs a Metal device"))
    func rejectedCbNextToMmrCr() throws {
        let composer = try #require(DoviFelComposer())
        var p = DoviGpuEdgeCaseTests.params(flags: [.disableResidual])
        p.ditherMode = .debugRawVDR
        p.polyCb = .identity
        p.mmrCb = DoviMmrParams()
        var cr = DoviPolynomialParams()
        cr.numPivots = 2
        cr.pivots[0] = 0
        cr.pivots[1] = 1023
        cr.method[0] = DoviMapping.mmr.rawValue
        cr.order[0] = 1
        cr.coefShift[0] = 23
        var crMmr = DoviMmrParams()
        crMmr.coefShift = 23
        crMmr.coef[0][1] = 1 << 23              // Cr = the Cb term (u)
        p.polyCr = cr
        p.mmrCr = crMmr
        for bl in [(512, 30, 512), (512, 1000, 512)] {
            let out = try DoviGpuEdgeCaseTests.composeConstant(composer, bl: bl, el: (512, 512, 512), params: p)
            let vdr = DoviTestSupport.rawVDR(out)
            #expect(Set(vdr[1]) == [bl.1 * 4])
            #expect(Set(vdr[2]) == [bl.1 * 4])
        }
    }
}
#endif
