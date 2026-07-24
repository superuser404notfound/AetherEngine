import Testing
import CoreVideo
import Libavutil
import Libavfilter
@testable import AetherEngine

/// yadif_videotoolbox hardware path (FFmpegBuild >= 2.1): the graph engages, emits
/// AV_PIX_FMT_VIDEOTOOLBOX frames wrapping CVPixelBuffers, and mode=send_field doubles the
/// output cadence on the sink's time_base.
///
/// Both tests self-skip (early return, engine falls back to .software) when the linked build has
/// no yadif_videotoolbox or the machine has no Metal device (CI VMs), the fallback itself is
/// covered by the software tests.
struct DeinterlaceHardwareTests {

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
                return ([], false)  // no yadif_videotoolbox / no Metal device: caller skips
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

    @Test("HW engine emits VideoToolbox frames wrapping CVPixelBuffers")
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
        guard hardware else { return }  // linked build predates yadif_videotoolbox, or no Metal
        #expect(sawVTFrame, "hw graph engaged but produced no frames")
        #expect(!seconds.isEmpty)
    }

    @Test("send_field doubles output cadence; send_frame keeps it")
    func fieldRateControlsCadence() {
        let streamTBSeconds = 1.0 / 30.0
        let (fieldSeconds, hwField) = run(fieldRate: .field, count: 8)
        guard hwField else { return }  // self-skip, see type doc
        let (frameSeconds, hwFrame) = run(fieldRate: .frame, count: 8)
        guard hwFrame else { return }

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

    @Test("warm-up releases its temporary graph and a fresh hardware graph remains usable")
    func warmupLeavesFreshGraphUsable() {
        guard DeinterlaceFilter.prewarmHardwarePipeline() else {
            return
        }

        let (seconds, hardware) = run(fieldRate: .field, count: 8)
        #expect(hardware)
        #expect(!seconds.isEmpty)
    }
}
