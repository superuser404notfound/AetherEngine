import Testing
import AetherLibavutil
import AetherLibavfilter
@testable import AetherEngine

/// #853: the inverse telecine graph (`fieldmatch`, the deinterlacer for the frames left combed,
/// `decimate`) on exact 3:2 frames: it hands back each film frame once, on a steady 23.976 fps
/// timeline that re-anchors whenever the graph is rebuilt, and it gives up its last pictures at the
/// end of the stream.
@Suite("Inverse telecine graph", .timeLimit(.minutes(3)))
struct InverseTelecineChainTests {

    private typealias Frames = TelecineFrameSynthesizer

    private static let hardwareAvailable = DeinterlaceFilter.prewarmHardwarePipeline()

    private func filter(mode: DeinterlaceMode = .software, fieldRate: DeinterlaceFieldRate = .frame,
                        rate: DeinterlaceConfig.SourceFrameRate = Frames.frameRate) -> DeinterlaceFilter {
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: mode, fieldRate: fieldRate, inverseTelecine: true,
                                          sourceFrameRate: rate)
        return filter
    }

    /// Pushes `frames` (freeing each), pulls everything, and with `endOfStream` drains the graph.
    /// Returns the output PTS and, for CPU frames, the film frame each output reproduces.
    private func run(_ filter: DeinterlaceFilter, frames: [UnsafeMutablePointer<AVFrame>],
                     endOfStream: Bool = true, filmFrames: Int = 0) -> (pts: [Int64], film: [Int?]) {
        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }
        var pts: [Int64] = []
        var film: [Int?] = []
        func pullAll() {
            while filter.pull(into: out) >= 0 {
                pts.append(out.pointee.pts)
                if filmFrames > 0 { film.append(Frames.matchingFilmFrame(out, filmFrames: filmFrames)) }
                av_frame_unref(out)
            }
        }
        for frame in frames {
            var f: UnsafeMutablePointer<AVFrame>? = frame
            #expect(filter.ensureGraph(frame: frame, timeBase: Frames.timeBase))
            #expect(filter.push(frame) >= 0)
            av_frame_free(&f)
            pullAll()
        }
        if endOfStream {
            #expect(filter.sendEndOfStream() >= 0)
            pullAll()
        }
        return (pts, film)
    }

    @Test("3:2 film comes back as its film frames, each once, at 23.976 fps")
    func filmFramesComeBackOnce() {
        let filter = filter()
        defer { filter.teardown() }
        // The pattern repeats every `filmPeriod` film frames, so a film frame is known up to that period.
        let result = run(filter, frames: (0..<50).map { Frames.telecinedFrame($0) }, filmFrames: Frames.filmPeriod)
        #expect(result.pts.count == 40, "fifty 29.97i frames are forty film frames, got \(result.pts.count)")
        #expect(result.film == (0..<40).map { $0 % Frames.filmPeriod },
                "each film frame exactly once, in order: \(result.film)")
        #expect(result.pts == (0..<40).map { Int64($0) }, "one 1001/24000 tick per frame: \(result.pts)")
    }

    @Test("the graph reports inverse telecine on the 1001/24000 time base, at frame rate")
    func reportAndTimeBase() {
        let filter = filter()
        defer { filter.teardown() }
        let frame = Frames.telecinedFrame(0)
        defer { var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f) }
        #expect(filter.ensureGraph(frame: frame, timeBase: Frames.timeBase))
        #expect(filter.outputTimeBase.num == 1001 && filter.outputTimeBase.den == 24000)
        let report = filter.activeDeinterlace
        #expect(report?.inverseTelecine == true)
        #expect(report?.fieldRate == .frame)
        #expect(report?.filter == "bwdif")
        #expect(report?.outputFrameRateFactor == 0.8)
    }

    @Test("the end of the stream releases the partial cycle decimate holds")
    func endOfStreamReleasesThePartialCycle() {
        let filter = filter()
        defer { filter.teardown() }
        let noFlush = run(filter, frames: (0..<7).map { Frames.telecinedFrame($0) }, endOfStream: false)
        filter.teardown()
        let flushed = run(self.filter(), frames: (0..<7).map { Frames.telecinedFrame($0) })
        #expect(noFlush.pts.count < flushed.pts.count, "decimate holds frames until its cycle completes")
        // 7 in: one full cycle of five keeps four, the two left over come out on EOF without a drop.
        #expect(flushed.pts.count == 6, "got \(flushed.pts.count)")
    }

    @Test("a rebuilt graph anchors its timeline on its own first frame (every seek)")
    func rebuildReanchors() {
        let filter = filter()
        defer { filter.teardown() }
        let first = run(filter, frames: (0..<20).map { Frames.telecinedFrame($0) }, endOfStream: false)
        #expect(first.pts.first == 0)
        filter.teardown()  // what SoftwareVideoDecoder.flush() does on a seek
        let second = run(filter, frames: (0..<20).map { Frames.telecinedFrame($0, firstPTS: 100) })
        // PTS 100 on 1001/30000 is 80 on 1001/24000: the same instant, on the output's time base.
        #expect(second.pts.first == 80, "got \(String(describing: second.pts.first))")
        #expect(second.pts == (0..<second.pts.count).map { 80 + Int64($0) })
    }

    @Test("a missing source frame or a step back breaks the cadence; a repeated timestamp does not")
    func timestampGapsBreakTheCadence() {
        let filter = filter()
        defer { filter.teardown() }
        _ = run(filter, frames: (0..<10).map { Frames.telecinedFrame($0) }, endOfStream: false)
        func breaks(_ pts: Int64) -> Bool {
            let frame = Frames.telecinedFrame(0, firstPTS: pts)
            defer { var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f) }
            return filter.breaksInverseTelecineCadence(frame, timeBase: Frames.timeBase)
        }
        #expect(!breaks(10), "the next frame")
        #expect(!breaks(9), "a repeated timestamp: decimate ignores input timestamps")
        #expect(breaks(12), "two frames missing")
        #expect(breaks(5), "a step back")
    }

    @Test("a frame that repeats a field (1.5 frames at 90 kHz, either rounding) is no gap; one missing frame is")
    func repeatFieldFrameIsNoGap() {
        let filter = filter()
        defer { filter.teardown() }
        _ = run(filter, frames: (0..<10).map { Frames.telecinedFrame($0) }, endOfStream: false)
        // The check reads both timestamps on the time base it is handed, so asking on 1/90000 measures the
        // step from the last push (PTS 9) in MPEG ticks: 3003 per frame at 29.97.
        func breaks(afterTicks ticks: Int64) -> Bool {
            let frame = Frames.telecinedFrame(0, firstPTS: 9 + ticks)
            defer { var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f) }
            return filter.breaksInverseTelecineCadence(frame, timeBase: AVRational(num: 1, den: 90000))
        }
        #expect(!breaks(afterTicks: 4504))
        #expect(!breaks(afterTicks: 4505), "rounded up, still the repeat-field duration")
        #expect(breaks(afterTicks: 6006), "one frame missing")
    }

    @Test("after a gap the decoder's flush and rebuild put the timeline back on the source")
    func gapFlushReanchors() {
        let filter = filter()
        defer { filter.teardown() }
        let before = run(filter, frames: (0..<15).map { Frames.telecinedFrame($0) }, endOfStream: false)
        // SoftwareVideoDecoder on a gap: end of stream, drain, teardown, then the late frame builds anew.
        let drained = run(filter, frames: [], endOfStream: true)
        filter.teardown()
        let after = run(filter, frames: (0..<10).map { Frames.telecinedFrame($0, firstPTS: 30) })
        #expect(before.pts.count + drained.pts.count == 15 - 3, "15 in, three cycles, three drops")
        #expect(after.pts.first == 24, "PTS 30 on 1001/30000 is 24 on 1001/24000")
    }

    @Test("true interlaced video forced through the graph neither stalls nor fails: it loses one frame in five")
    func interlacedVideoDoesNotStall() {
        let filter = filter()
        defer { filter.teardown() }
        let result = run(filter, frames: (0..<50).map { Frames.interlacedVideoFrame($0) })
        #expect(result.pts.count == 40)
        #expect(filter.graphErrorCount == 0)
    }

    @Test("without a stream rate the graph cannot decimate and deinterlaces as before")
    func unknownRateFallsBackToTheDeinterlacer() {
        let filter = filter(rate: DeinterlaceConfig.SourceFrameRate())
        defer { filter.teardown() }
        let frame = Frames.telecinedFrame(0)
        defer { var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f) }
        #expect(filter.ensureGraph(frame: frame, timeBase: Frames.timeBase))
        #expect(filter.activeDeinterlace?.inverseTelecine == false)
        let result = run(filter, frames: (1..<10).map { Frames.telecinedFrame($0) })
        #expect(result.pts.count == 9, "one frame out per frame in")
    }

    @Test("the snapped NTSC rates are exact rationals")
    func ntscRatesSnap() {
        #expect(DeinterlaceConfig.SourceFrameRate(num: 30000, den: 1001).framesPerSecond == 30000.0 / 1001.0)
        #expect(!DeinterlaceConfig.SourceFrameRate().isKnown)
    }

    @Test("the GPU engine keeps the cadence work on the CPU and runs at frame rate under inverse telecine",
          .enabled(if: hardwareAvailable, "needs a GPU deinterlacer and a Metal device"))
    func hardwareChainRunsAtFrameRate() {
        let filter = filter(mode: .auto, fieldRate: .field)
        defer { filter.teardown() }
        let result = run(filter, frames: (0..<50).map { Frames.telecinedFrame($0) })
        #expect(result.pts.count == 40, "send_frame under inverse telecine, not send_field: \(result.pts.count)")
        let probe = self.filter(mode: .auto, fieldRate: .field)
        defer { probe.teardown() }
        let frame = Frames.telecinedFrame(0)
        defer { var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f) }
        #expect(probe.ensureGraph(frame: frame, timeBase: Frames.timeBase))
        #expect(probe.engine == .hardware)
        #expect(probe.activeDeinterlace?.inverseTelecine == true)
        #expect(probe.activeDeinterlace?.fieldRate == .frame)
        #expect(probe.activeDeinterlace?.isHardware == true)
    }
}
