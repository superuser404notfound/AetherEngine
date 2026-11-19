import Foundation
import Testing
import CoreMedia
import CoreVideo
import Metal
import AetherLibavutil
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// The playback decoder's 10-bit AV1 conversion overlaps the decode (`overlapsGPUConversion`): up to
/// `GPUFrameConverter.slotCount` frames are on the GPU at once, each with buffers of its own, and they
/// leave in the order they were decoded. Waiting for each frame on the decoder's thread held a 1080p
/// episode below 24 fps on an Apple TV 4K (A15). The converter and the pipeline are checked on synthetic
/// pictures against the dav1d 1.5.4 digests of `AV1FilmGrainGPUReferenceTests`, and the decoder's own
/// route on a committed clip (`AV1FilmGrainClipFixture`): order, the waiting route's samples, a flush, the
/// drain. All of it runs wherever Metal does.
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
        let playback = SoftwareVideoDecoder()
        SoftwarePlaybackHost.prepareForPlayback(playback)
        #expect(playback.overlapsGPUConversion)
    }

    // MARK: - The decoder's own route, on the committed clip

    typealias Media = AV1FilmGrainGPUTests

    /// The clip open, its video stream, and decoders on it; closed by `close()`.
    final class Session: @unchecked Sendable {
        let url: URL
        let demuxer = Demuxer()
        let videoIndex: Int32
        let stream: UnsafeMutablePointer<AVStream>
        private var decoders: [SoftwareVideoDecoder] = []

        init() throws {
            url = try AV1FilmGrainClipFixture.write()
            try demuxer.open(url: url)
            videoIndex = demuxer.videoStreamIndex
            stream = try #require(demuxer.stream(at: videoIndex))
        }

        func decoder(overlapped: Bool, onFrame: @escaping DecodedFrameHandler) throws -> SoftwareVideoDecoder {
            let decoder = SoftwareVideoDecoder()
            decoder.overlapsGPUConversion = overlapped
            try decoder.open(stream: stream, onFrame: onFrame)
            decoders.append(decoder)
            return decoder
        }

        /// Every video packet of the clip, from where the demuxer stands, to each decoder.
        func decodeAll(_ targets: [SoftwareVideoDecoder]) {
            while let pkt = try? demuxer.readPacket() {
                if pkt.pointee.stream_index == videoIndex {
                    for decoder in targets { decoder.decode(packet: pkt) }
                }
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&p)
            }
        }

        func close() {
            for decoder in decoders { decoder.close() }
            demuxer.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Through the pipeline every frame arrives, in order, sample for sample the frame the waiting route
    /// delivers, with its grain applied on the GPU.
    @Test func theDecoderDeliversEveryFrameInOrderAsTheWaitingRouteDoes() async throws {
        let session = try Session()
        defer { session.close() }
        let waitingFrames = Media.FrameSink(), overlappedFrames = Media.FrameSink()
        let waiting = try session.decoder(overlapped: false) { pb, pts, _ in waitingFrames.add(pb, pts: pts) }
        let overlapped = try session.decoder(overlapped: true) { pb, pts, _ in overlappedFrames.add(pb, pts: pts) }
        #expect(!waiting.convertsInPipeline)
        #expect(overlapped.convertsInPipeline)

        let done = runOnOwnThread {
            session.decodeAll([waiting, overlapped])
            waiting.drainForEndOfStream()
            overlapped.drainForEndOfStream()
        }
        try await waitFor { done.isSet }

        let reference = waitingFrames.all, frames = overlappedFrames.all
        #expect(reference.count == AV1FilmGrainClipFixture.frameCount)
        #expect(frames.count == reference.count)
        var report = Media.Report()
        for (a, b) in zip(reference, frames) { report.compare(a, b) }
        #expect(report.ptsMismatches == 0)
        #expect(report.yMismatches == 0)
        #expect(report.uvMismatches == 0)
        let pts = frames.map(\.pts.seconds)
        #expect(pts == pts.sorted(), "decode order")
        #expect(overlapped.gpuConversionCounts?.grained == AV1FilmGrainClipFixture.frameCount)
    }

    /// After `flush()` returns, no frame from before it reaches the handler (a frame still on the GPU is
    /// retired with its epoch), and the decoder goes on with what it is given next.
    @Test func aFlushRetiresTheFramesStillOnTheGPU() async throws {
        let session = try Session()
        defer { session.close() }
        let recorder = FlushRecorder()
        let decoder = try session.decoder(overlapped: true) { pb, pts, _ in recorder.add(pts) }
        #expect(decoder.convertsInPipeline)

        let flushed = runOnOwnThread {
            session.decodeAll([decoder])
            decoder.flush()
            recorder.markFlushed()
        }
        try await waitFor { flushed.isSet }
        // The bound is the assertion: nothing from before the flush may turn up after it.
        let late = try await waitFor(upTo: .milliseconds(300)) { recorder.afterFlush > 0 }
        #expect(!late, "\(recorder.afterFlush) frame(s) from before the flush arrived after it")

        // The next position decodes as usual under the new epoch.
        let again = runOnOwnThread {
            _ = session.demuxer.seek(to: 0)
            session.decodeAll([decoder])
            decoder.drainForEndOfStream()
        }
        try await waitFor { again.isSet }
        #expect(recorder.afterFlush == AV1FilmGrainClipFixture.frameCount)
    }

    /// When `drainForEndOfStream()` returns, every frame has reached the handler, those still on the GPU
    /// included: the host drains the renderer right after it.
    @Test func theDrainDeliversEveryFrameBeforeItReturns() async throws {
        let session = try Session()
        defer { session.close() }
        let recorder = FlushRecorder()
        let decoder = try session.decoder(overlapped: true) { pb, pts, _ in recorder.add(pts) }
        let countAtReturn = Counted()
        let drained = runOnOwnThread {
            session.decodeAll([decoder])
            decoder.drainForEndOfStream()
            countAtReturn.set(recorder.total)
        }
        try await waitFor { drained.isSet }
        #expect(countAtReturn.value == AV1FilmGrainClipFixture.frameCount)
    }

    /// Frames as they arrive, and how many came after `markFlushed`.
    private final class FlushRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var flushed = false
        private var count = 0
        private var late = 0
        func add(_ pts: CMTime) {
            lock.lock(); count += 1; if flushed { late += 1 }; lock.unlock()
        }
        func markFlushed() { lock.lock(); flushed = true; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return count }
        var afterFlush: Int { lock.lock(); defer { lock.unlock() }; return late }
    }

    private final class Counted: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = -1
        func set(_ v: Int) { lock.lock(); stored = v; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
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
