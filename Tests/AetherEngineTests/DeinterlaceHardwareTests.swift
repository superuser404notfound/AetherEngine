import Testing
import CoreVideo
import AetherLibavutil
import AetherLibavfilter
@testable import AetherEngine

/// GPU deinterlace path (bwdif_videotoolbox, else yadif_videotoolbox): the graph engages, emits
/// AV_PIX_FMT_VIDEOTOOLBOX frames wrapping CVPixelBuffers, and mode=send_field doubles the
/// output cadence on the sink's time_base.
///
/// The tests are reported as skipped (not passed) when the linked build has no GPU
/// deinterlacer or the machine has no Metal device (CI VMs): the engine then falls back to
/// .software, and the fallback itself is covered by the software tests.
struct DeinterlaceHardwareTests {

    /// Built once: the probe stands up and tears down a whole filter graph.
    private static let hardwareAvailable = DeinterlaceFilter.prewarmHardwarePipeline()
    private static let needsHardware: Comment = "needs a GPU deinterlacer and a Metal device"
    /// AE#1102: both GPU filters in the linked build, so the preference and the hand-over show.
    private static let bothFiltersLinked = hardwareAvailable
        && DeinterlaceFilter.linkedHardwareFilters == DeinterlaceFilter.hardwareFilterNames

    private func makeFrame(pts: Int64, height: Int32 = 64) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = 64
        f.pointee.height = height
        f.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        f.pointee.pts = pts
        f.pointee.flags |= (1 << 3)  // AV_FRAME_FLAG_INTERLACED
        _ = av_frame_get_buffer(f, 0)
        return f
    }

    /// Run `count` frames through a filter with the given field rate; returns output seconds
    /// (converted via outputTimeBase) and whether the hw engine engaged.
    private func run(
        fieldRate: DeinterlaceFieldRate,
        count: Int64,
        onFrame: ((UnsafeMutablePointer<AVFrame>) -> Void)? = nil
    ) -> (seconds: [Double], hardware: Bool) {
        let streamTB = AVRational(num: 1, den: 30)
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .auto, fieldRate: fieldRate)
        defer { filter.teardown() }

        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }

        var seconds: [Double] = []
        var hardware = false
        for pts in Int64(0)..<count {
            let f = makeFrame(pts: pts)
            guard filter.ensureGraph(frame: f, timeBase: streamTB) else {
                var ff: UnsafeMutablePointer<AVFrame>? = f
                av_frame_free(&ff)
                return ([], false)
            }
            hardware = filter.engine == .hardware
            guard hardware else {
                var ff: UnsafeMutablePointer<AVFrame>? = f
                av_frame_free(&ff)
                return ([], false)
            }

            #expect(filter.push(f) >= 0)
            var ff: UnsafeMutablePointer<AVFrame>? = f
            av_frame_free(&ff)

            let outTB = filter.outputTimeBase
            let outTBSeconds = Double(outTB.num) / Double(outTB.den)
            while filter.pull(into: out) >= 0 {
                if out.pointee.pts != Int64.min {
                    seconds.append(Double(out.pointee.pts) * outTBSeconds)
                }
                onFrame?(out)
                av_frame_unref(out)
            }
        }
        return (seconds, hardware)
    }

    @Test("HW engine emits VideoToolbox frames wrapping CVPixelBuffers",
          .enabled(if: DeinterlaceHardwareTests.hardwareAvailable, DeinterlaceHardwareTests.needsHardware))
    func hardwareEmitsVideoToolboxFrames() {
        var sawVTFrame = false
        let (seconds, hardware) = run(fieldRate: .field, count: 8) { out in
            #expect(out.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
                    "hw sink must emit AV_PIX_FMT_VIDEOTOOLBOX frames")
            if let raw = out.pointee.data.3 {
                sawVTFrame = true
                let pb = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
                // The renderer path relies on displayable bi-planar buffers straight from the pool.
                let fmt = CVPixelBufferGetPixelFormatType(pb)
                #expect(fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                        || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        "expected NV12-class pixel buffer, got 0x\(String(fmt, radix: 16))")
                #expect(CVPixelBufferGetWidth(pb) == 64 && CVPixelBufferGetHeight(pb) == 64)
            } else {
                Issue.record("AV_PIX_FMT_VIDEOTOOLBOX frame with nil data[3]")
            }
        }
        #expect(hardware)
        #expect(sawVTFrame, "hw graph engaged but produced no frames")
        #expect(!seconds.isEmpty)
    }

    @Test("send_field doubles output cadence; send_frame keeps it",
          .enabled(if: DeinterlaceHardwareTests.hardwareAvailable, DeinterlaceHardwareTests.needsHardware))
    func fieldRateControlsCadence() {
        let streamTBSeconds = 1.0 / 30.0
        let (fieldSeconds, hwField) = run(fieldRate: .field, count: 8)
        let (frameSeconds, hwFrame) = run(fieldRate: .frame, count: 8)
        #expect(hwField && hwFrame)

        // Field rate must produce ~2x the frames of frame rate (lookahead trims the tails).
        #expect(fieldSeconds.count > frameSeconds.count + 2,
                "send_field produced \(fieldSeconds.count) vs send_frame \(frameSeconds.count)")

        // Distinct, monotonic timestamps at ~half the frame interval: the send_field PTS
        // regression collapsed field pairs onto duplicate timestamps.
        let sorted = fieldSeconds.sorted()
        #expect(sorted == fieldSeconds, "field PTS must be monotonic")
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let delta = sorted[i] - sorted[i - 1]
                #expect(delta > 0, "duplicate field PTS at index \(i)")
                #expect(abs(delta - streamTBSeconds / 2) < streamTBSeconds * 0.2,
                        "field spacing \(delta)s is not ~\(streamTBSeconds / 2)s")
            }
        }

        // Both cadences stay on the source's real-time axis.
        let maxInput = 7.0 * streamTBSeconds
        for s in fieldSeconds + frameSeconds {
            #expect(s <= maxInput + streamTBSeconds,
                    "output PTS \(s)s exceeds source range (\(maxInput)s)")
        }
    }

    @Test("bwdif_videotoolbox is preferred, one that fails to build hands over to yadif_videotoolbox",
          .enabled(if: DeinterlaceHardwareTests.bothFiltersLinked, "needs both GPU deinterlacers and a Metal device"))
    func bwdifPreferredThenYadif() throws {
        let timeBase = AVRational(num: 1, den: 30)

        let preferred = DeinterlaceFilter()
        preferred.config = DeinterlaceConfig(mode: .auto, fieldRate: .field)
        defer { preferred.teardown() }
        var frame: UnsafeMutablePointer<AVFrame>? = makeFrame(pts: 0)
        defer { av_frame_free(&frame) }
        try #require(preferred.ensureGraph(frame: frame!, timeBase: timeBase))
        #expect(preferred.activeDeinterlace?.filter == "bwdif_videotoolbox")

        // bwdif_videotoolbox refuses planes under 3x4 at configuration (a 64x6 NV12 frame has
        // 3-row chroma); yadif_videotoolbox builds on it, so the session stays on the GPU.
        let small = DeinterlaceFilter()
        small.config = DeinterlaceConfig(mode: .auto, fieldRate: .field)
        defer { small.teardown() }
        var smallFrame: UnsafeMutablePointer<AVFrame>? = makeFrame(pts: 0, height: 6)
        defer { av_frame_free(&smallFrame) }
        try #require(small.ensureGraph(frame: smallFrame!, timeBase: timeBase))
        #expect(small.activeDeinterlace?.filter == "yadif_videotoolbox")
        #expect(small.failedHardwareFilters == ["bwdif_videotoolbox"])
    }

    @Test("a GPU graph that errors while running falls back to software, not to the next GPU filter",
          .enabled(if: DeinterlaceHardwareTests.hardwareAvailable, DeinterlaceHardwareTests.needsHardware))
    func runtimeErrorGoesToSoftware() throws {
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .auto, fieldRate: .field)
        defer { filter.teardown() }
        let timeBase = AVRational(num: 1, den: 30)
        var frame: UnsafeMutablePointer<AVFrame>? = makeFrame(pts: 0)
        defer { av_frame_free(&frame) }

        try #require(filter.ensureGraph(frame: frame!, timeBase: timeBase))
        #expect(filter.engine == .hardware)
        #expect(filter.noteGraphError(afterPull: FFmpegErr.eio))
        try #require(filter.ensureGraph(frame: frame!, timeBase: timeBase))
        #expect(filter.engine == .software)
        #expect(filter.failedHardwareFilters.isEmpty)
    }

    @Test("warm-up releases its temporary graph and a fresh hardware graph remains usable",
          .enabled(if: DeinterlaceHardwareTests.hardwareAvailable, DeinterlaceHardwareTests.needsHardware))
    func warmupLeavesFreshGraphUsable() {
        #expect(DeinterlaceFilter.prewarmHardwarePipeline())

        let (seconds, hardware) = run(fieldRate: .field, count: 8)
        #expect(hardware)
        #expect(!seconds.isEmpty)
    }
}
