import Testing
import AetherLibavutil
import AetherLibavfilter
@testable import AetherEngine

/// DEC-202 / DEC-203: a libavfilter error is latched on the link, so the graph never recovers and
/// every pushed frame piles up in its source FIFO; and the end of the stream never reached the graph,
/// so the picture yadif/bwdif hold back was lost.
@Suite("Deinterlace graph recovery", .timeLimit(.minutes(3)))
struct DeinterlaceGraphRecoveryTests {

    private let timeBase = AVRational(num: 1, den: 30)

    private func makeFrame(pts: Int64) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = 64
        f.pointee.height = 64
        f.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        f.pointee.pts = pts
        f.pointee.flags |= (1 << 3)  // AV_FRAME_FLAG_INTERLACED
        _ = av_frame_get_buffer(f, 0)
        return f
    }

    private func softwareFilter() -> DeinterlaceFilter {
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .software)
        return filter
    }

    @Test("a pull error drops the graph and the next frame builds a fresh one")
    func pullErrorRebuildsTheGraph() {
        let filter = softwareFilter()
        defer { filter.teardown() }
        var f: UnsafeMutablePointer<AVFrame>? = makeFrame(pts: 0)
        defer { av_frame_free(&f) }
        #expect(filter.ensureGraph(frame: f!, timeBase: timeBase))
        #expect(filter.isActive)

        #expect(filter.noteGraphError(afterPull: FFmpegErr.enomem))
        #expect(!filter.isActive, "the latched graph must be dropped")
        #expect(filter.graphErrorCount == 1)
        #expect(filter.ensureGraph(frame: f!, timeBase: timeBase), "the next frame rebuilds")
        #expect(filter.isActive)
    }

    @Test("EAGAIN and EOF are not errors and keep the graph")
    func needsInputIsNotAnError() {
        let filter = softwareFilter()
        defer { filter.teardown() }
        var f: UnsafeMutablePointer<AVFrame>? = makeFrame(pts: 0)
        defer { av_frame_free(&f) }
        #expect(filter.ensureGraph(frame: f!, timeBase: timeBase))
        #expect(!filter.noteGraphError(afterPull: FFmpegErr.eagain))
        #expect(!filter.noteGraphError(afterPull: FFmpegErr.eof))
        #expect(!filter.noteGraphError(afterPull: 0))
        #expect(filter.isActive)
        #expect(filter.graphErrorCount == 0)
    }

    @Test("a graph that keeps failing stops being rebuilt, frames then render as they are")
    func repeatedErrorsLatchPassthrough() {
        let filter = softwareFilter()
        defer { filter.teardown() }
        var f: UnsafeMutablePointer<AVFrame>? = makeFrame(pts: 0)
        defer { av_frame_free(&f) }
        for _ in 0..<DeinterlaceFilter.maxGraphErrors {
            #expect(filter.ensureGraph(frame: f!, timeBase: timeBase))
            filter.noteGraphError(afterPull: FFmpegErr.enomem)
        }
        #expect(!filter.ensureGraph(frame: f!, timeBase: timeBase))
        #expect(!filter.isActive)
    }

    @Test("a push leaves the frame intact, so a failed push can still render it as it is")
    func pushKeepsTheCallersFrame() {
        let filter = softwareFilter()
        defer { filter.teardown() }
        var f: UnsafeMutablePointer<AVFrame>? = makeFrame(pts: 0)
        defer { av_frame_free(&f) }
        #expect(filter.ensureGraph(frame: f!, timeBase: timeBase))
        #expect(filter.push(f!) >= 0)
        #expect(f!.pointee.width == 64 && f!.pointee.height == 64,
                "buffersrc must not empty the caller's frame (DEC-202)")
    }

    @Test("sending end of stream releases the picture the filter holds back")
    func endOfStreamReleasesTheLastPicture() {
        let filter = softwareFilter()
        defer { filter.teardown() }
        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }

        var pulled = 0
        for pts in Int64(0)..<3 {
            var f: UnsafeMutablePointer<AVFrame>? = makeFrame(pts: pts)
            #expect(filter.ensureGraph(frame: f!, timeBase: timeBase))
            #expect(filter.push(f!) >= 0)
            av_frame_free(&f)
            while filter.pull(into: out) >= 0 { pulled += 1; av_frame_unref(out) }
        }
        #expect(pulled == 2, "the deinterlacer holds the last frame as `cur`, got \(pulled)")

        #expect(filter.sendEndOfStream() >= 0)
        while filter.pull(into: out) >= 0 { pulled += 1; av_frame_unref(out) }
        #expect(pulled == 3, "the last picture must come out at end of stream")
    }
}
