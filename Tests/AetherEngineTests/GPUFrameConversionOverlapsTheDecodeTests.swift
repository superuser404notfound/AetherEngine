import Foundation
import Testing
import CoreMedia
import CoreVideo
import Metal
import AetherLibavutil
@testable import AetherEngine

/// The playback decoder's 10-bit AV1 conversion overlaps the decode (`overlapsGPUConversion`): up to
/// `GPUFrameConverter.slotCount` frames are on the GPU at once, each with buffers of its own, and they
/// leave in the order they were decoded. Waiting for each frame on the decoder's thread held a 1080p
/// episode below 24 fps on an Apple TV 4K (A15) in a host's Debug build. Synthetic pictures against the dav1d 1.5.4 digests of
/// `AV1FilmGrainGPUReferenceTests`, so it runs wherever Metal does; the media check in `AV1FilmGrainGPUTests`
/// runs the same route on a real clip.
@Suite("GPU frame conversion overlaps the decode", .serialized, .timeLimit(.minutes(3)),
       .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct GPUFrameConversionOverlapsTheDecodeTests {

    typealias Reference = AV1FilmGrainGPUReferenceTests

    /// A picture's grain and what dav1d makes of it, as Y, Cb and Cr digests.
    struct Case: @unchecked Sendable {
        let grain: Reference.Grain?
        let y: UInt64, u: UInt64, v: UInt64
    }

    /// The reference test's three parameter sets, and the picture without grain (unchanged).
    static let cases: [Case] = {
        let plain = Reference.input()
        return [
            Case(grain: Reference.separateChroma,
                 y: 0x0A79_4163_CECE_F7C4, u: 0x71A7_0EC9_C22D_61A6, v: 0x59FE_E10A_9622_0C74),
            Case(grain: Reference.lumaOnly,
                 y: 0x8514_48C0_0FB0_C78E, u: 0xBFD4_86A4_FE08_C751, v: 0x43C0_DFEE_3FB8_DEE5),
            Case(grain: Reference.chromaFromLuma,
                 y: 0xDBE9_F1CE_A211_666A, u: 0x2178_A90C_22E4_10FA, v: 0xEA55_0257_B0BE_5A8B),
            Case(grain: nil, y: Reference.digest(plain.y), u: Reference.digest(plain.u), v: Reference.digest(plain.v)),
        ]
    }()

    static func check(_ pb: CVPixelBuffer, against c: Case, _ label: String) {
        let out = Reference.read(pb)
        #expect(Reference.digest(out.y) == c.y, "\(label): luma")
        #expect(Reference.digest(out.u) == c.u, "\(label): Cb")
        #expect(Reference.digest(out.v) == c.v, "\(label): Cr")
    }

    /// Two frames encoded before either is committed, as the pipeline has them, each keep their own grain:
    /// the uniforms, grain templates, scaling and offsets of the first are not overwritten by the second.
    /// Two pairs, so the second pair writes the buffers the first pair used.
    @Test func framesOnTheGPUTogetherEachKeepTheirOwnGrain() throws {
        #expect(GPUFrameConverter.slotCount == 2)
        let converter = try #require(GPUFrameConverter())
        for pair in [(0, 1), (2, 3)] {
            var first: UnsafeMutablePointer<AVFrame>? = try Reference.makeFrame(Self.cases[pair.0].grain)
            var second: UnsafeMutablePointer<AVFrame>? = try Reference.makeFrame(Self.cases[pair.1].grain)
            defer { av_frame_free(&first); av_frame_free(&second) }
            let pbFirst = try Reference.makePixelBuffer(), pbSecond = try Reference.makePixelBuffer()
            let firstFrame = try #require(first), secondFrame = try #require(second)
            let a = try #require(converter.encode(firstFrame, into: pbFirst))
            let b = try #require(converter.encode(secondFrame, into: pbSecond))
            a.work.commandBuffer.commit()
            b.work.commandBuffer.commit()
            a.work.commandBuffer.waitUntilCompleted()
            b.work.commandBuffer.waitUntilCompleted()
            #expect(converter.finished(a, heldMs: 0))
            #expect(converter.finished(b, heldMs: 0))
            Self.check(pbFirst, against: Self.cases[pair.0], "frame \(pair.0)")
            Self.check(pbSecond, against: Self.cases[pair.1], "frame \(pair.1)")
        }
        let counts = converter.counts
        #expect(counts.converted == 4)
        #expect(counts.grained == 3)
    }

    /// Through the pipeline the decoder runs it in: frames leave in decode order, each converted with its
    /// own grain, although the decoder lets go of its frame as soon as `submit` returns (the work holds a
    /// reference to the picture until the GPU read it).
    @Test func framesLeaveThePipelineInDecodeOrderConverted() async throws {
        let converter = try #require(GPUFrameConverter())
        let frames = 8
        let delivered = Delivered()
        let pipeline = PipelinedFrameStage(
            depth: GPUFrameConverter.slotCount,
            deliver: { buffer, pts, _ in delivered.add(buffer, pts: pts) },
            begin: { buffer, pts, _ in
                guard let source = try? Reference.makeFrame(Self.cases[Int(pts.value) % Self.cases.count].grain),
                      let encoded = converter.encode(source, into: buffer)
                else { return .passThrough }
                let held = Held(source)
                return .gpu(encoded.work) { heldMs in
                    _ = converter.finished(encoded, heldMs: heldMs)
                    withExtendedLifetime(held) {}
                    return nil
                }
            })
        let buffers = UncheckedSendable(try (0..<frames).map { _ in try Reference.makePixelBuffer() })
        let submitted = runOnOwnThread {
            for n in 0..<frames {
                pipeline.submit(buffers.value[n], pts: CMTime(value: Int64(n), timescale: 24), hdr10Plus: nil)
            }
            pipeline.settle()
        }
        try await waitFor { submitted.isSet }
        try await waitFor { delivered.count == frames }
        #expect(delivered.pts == Array(0..<Int64(frames)))
        for (n, pb) in delivered.buffers.enumerated() {
            Self.check(pb, against: Self.cases[n % Self.cases.count], "frame \(n)")
        }
        #expect(converter.counts.converted == frames)
        #expect(pipeline.inFlight == 0)
    }

    /// The decoder runs its frames through the pipeline only when the playback host asks: the probe, the
    /// still extractor and the tests read a frame as soon as `decode` returns.
    @Test func onlyThePlaybackHostOverlapsTheConversion() {
        #expect(SoftwareVideoDecoder().overlapsGPUConversion == false)
    }

    /// The picture a frame's work reads in place, freed once the completion that holds it is gone.
    private final class Held: @unchecked Sendable {
        let frame: UnsafeMutablePointer<AVFrame>
        init(_ frame: UnsafeMutablePointer<AVFrame>) { self.frame = frame }
        deinit {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
        }
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(pb: CVPixelBuffer, pts: Int64)] = []
        func add(_ pb: CVPixelBuffer, pts: CMTime) { lock.lock(); items.append((pb, pts.value)); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        var pts: [Int64] { lock.lock(); defer { lock.unlock() }; return items.map(\.pts) }
        var buffers: [CVPixelBuffer] { lock.lock(); defer { lock.unlock() }; return items.map(\.pb) }
    }
}
