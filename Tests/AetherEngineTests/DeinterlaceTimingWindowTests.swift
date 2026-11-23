import Testing
@testable import AetherEngine

/// AE#1112: the `[Deinterlace] timing` window sums what the graph costs the decoder's thread per input
/// frame and reports it every `statsInterval` frames, with the output interval derived from frames in
/// against frames out.
@Suite(.timeLimit(.minutes(3)))
struct DeinterlaceTimingWindowTests {

    private static let ivtcLabel = "bwdif_videotoolbox, inverse telecine GPU"
    private static let ntsc = 1001.0 / 30000.0

    /// One input frame: decode, push, `outputs` pulls that each yield a frame and a transfer, and the
    /// closing pull that comes back empty.
    private func feed(_ w: inout DeinterlaceTimingWindow, k: Int, outputs: Int,
                      label: String = ivtcLabel, push: Double = 1.0, pull: Double = 0.5,
                      transfer: Double = 0.25, decode: Double = 2.0,
                      pts: Double? = nil) -> DeinterlaceTimingWindow.Report? {
        w.addDecode(ms: decode)
        w.addPush(ms: push)
        for _ in 0..<outputs {
            w.addPull(ms: pull)
            w.addOutput()
            w.addTransfer(ms: transfer)
        }
        w.addPull(ms: pull)
        return w.finishInput(label: label, ptsSeconds: pts ?? Double(k) * Self.ntsc)
    }

    @Test("inverse telecine: 240 in, 192 out, output interval at 23.976 fps")
    func inverseTelecineWindow() throws {
        var w = DeinterlaceTimingWindow()
        var reports: [DeinterlaceTimingWindow.Report] = []
        for k in 0..<DeinterlaceTimingWindow.statsInterval {
            // decimate keeps four of every five
            if let r = feed(&w, k: k, outputs: k % 5 == 4 ? 0 : 1) { reports.append(r) }
        }
        #expect(reports.count == 1)
        let r = try #require(reports.first)
        #expect(r.framesIn == 240)
        #expect(r.framesOut == 192)
        #expect(abs(try #require(r.inputIntervalMs) - 33.367) < 0.01)
        #expect(abs(try #require(r.outputIntervalMs) - 41.708) < 0.01)
        // per input frame: push 1, pulls 0.5 * (outputs + 1), transfers 0.25 * outputs, decode 2
        #expect(abs(r.costs.pushMs / 240 - 1.0) < 1e-9)
        #expect(abs(r.costs.pullMs / 240 - 0.9) < 1e-9)
        #expect(abs(r.costs.transferMs / 240 - 0.2) < 1e-9)
        #expect(abs(r.heldMs / 240 - 4.1) < 1e-9)
        // the worst frame is one that kept its output: 1 + 0.5 * 2 + 0.25, decode left out
        #expect(abs(r.maxMs - 2.25) < 1e-9)
        #expect(r.logLine == "[Deinterlace] timing: last 240 frames in, 192 out (bwdif_videotoolbox, inverse telecine GPU): "
                + "push 1.00 ms, pull 0.90 ms, transfer 0.20 ms per input frame, max 2.25 ms; decode 2.00 ms; "
                + "decoder thread held 4.10 ms per input frame against a 33.4 ms input / 41.7 ms output interval")
    }

    @Test("field rate: two out per frame in halves the interval; the window restarts after a report")
    func fieldRateWindowsRepeat() throws {
        var w = DeinterlaceTimingWindow()
        var reports: [DeinterlaceTimingWindow.Report] = []
        for k in 0..<(2 * DeinterlaceTimingWindow.statsInterval) {
            if let r = feed(&w, k: k, outputs: 2, label: "bwdif_videotoolbox, inverse telecine off") {
                reports.append(r)
            }
        }
        #expect(reports.count == 2)
        for r in reports {
            #expect(r.framesIn == 240 && r.framesOut == 480)
            #expect(abs(try #require(r.outputIntervalMs) - 16.683) < 0.01)
        }
    }

    @Test("a chain change starts a new window; the frame that closes it stays in")
    func labelChangeResets() throws {
        var w = DeinterlaceTimingWindow()
        for k in 0..<100 { _ = feed(&w, k: k, outputs: 1, label: "bwdif_videotoolbox, inverse telecine GPU") }
        var report: DeinterlaceTimingWindow.Report?
        for k in 100..<340 {
            if let r = feed(&w, k: k, outputs: 1, label: "bwdif_videotoolbox, inverse telecine CPU") { report = r }
        }
        let r = try #require(report)
        #expect(r.label == "bwdif_videotoolbox, inverse telecine CPU")
        #expect(r.framesIn == 240)
    }

    @Test("a seek in the window does not count as a frame interval")
    func seekStepIsSkipped() throws {
        var w = DeinterlaceTimingWindow()
        var report: DeinterlaceTimingWindow.Report?
        for k in 0..<DeinterlaceTimingWindow.statsInterval {
            // forward jump of 600 s at frame 100, a step back at frame 200
            let pts = Double(k) * Self.ntsc + (k >= 100 ? 600 : 0) - (k >= 200 ? 900 : 0)
            if let r = feed(&w, k: k, outputs: 1, pts: pts) { report = r }
        }
        let r = try #require(report)
        #expect(abs(try #require(r.inputIntervalMs) - 33.367) < 0.01)
    }

    @Test("the CPU engine reports convert instead of transfer; no timestamps leave the interval out")
    func cpuEngineWithoutTimestamps() throws {
        var w = DeinterlaceTimingWindow()
        var report: DeinterlaceTimingWindow.Report?
        for _ in 0..<DeinterlaceTimingWindow.statsInterval {
            w.addPush(ms: 3)
            w.addPull(ms: 1)
            w.addOutput()
            w.addConvert(ms: 0.5)
            w.addPull(ms: 0)
            if let r = w.finishInput(label: "bwdif, inverse telecine CPU", ptsSeconds: nil) { report = r }
        }
        let r = try #require(report)
        #expect(r.inputIntervalMs == nil)
        #expect(r.logLine == "[Deinterlace] timing: last 240 frames in, 240 out (bwdif, inverse telecine CPU): "
                + "push 3.00 ms, pull 1.00 ms, convert 0.50 ms per input frame, max 4.50 ms; decode 0.00 ms; "
                + "decoder thread held 4.50 ms per input frame")
    }

    @Test("graph builds count into held and max, and show on the line only when one happened")
    func buildsShowWhenTheyHappen() throws {
        var w = DeinterlaceTimingWindow()
        var report: DeinterlaceTimingWindow.Report?
        for k in 0..<DeinterlaceTimingWindow.statsInterval {
            if k == 0 || k == 120 { w.addBuild(ms: 6) }
            if let r = feed(&w, k: k, outputs: 2, label: "bwdif_videotoolbox, inverse telecine off") { report = r }
        }
        let r = try #require(report)
        #expect(r.costs.builds == 2)
        // push 1 + three pulls 0.5 + two transfers 0.25 + the build
        #expect(abs(r.maxMs - 9.0) < 1e-9)
        #expect(r.logLine.contains("): builds 2 (12.0 ms total), push 1.00 ms, pull"))
        // decode 2 + graph 3 per frame, plus 12 ms of builds over 240 frames
        #expect(abs(r.heldMs / 240 - 5.05) < 1e-9)
    }

    @Test("work of a frame that never reached the graph, or of a drained graph, is not carried over")
    func discardedWorkIsNotCarried() throws {
        var w = DeinterlaceTimingWindow()
        var report: DeinterlaceTimingWindow.Report?
        for k in 0..<DeinterlaceTimingWindow.statsInterval {
            if k == 50 {
                // a failed push: its decode and push time go, the frame renders as-is
                w.addDecode(ms: 40)
                w.addPush(ms: 40)
                w.discardPending()
            }
            if k == 100 {
                // the end-of-stream drain pulls two frames with no input of their own, then a seek
                w.addPull(ms: 40)
                w.addOutput()
                w.addOutput()
                w.addTransfer(ms: 40)
                w.noteDiscontinuity()
            }
            if let r = feed(&w, k: k, outputs: 1) { report = r }
        }
        let r = try #require(report)
        #expect(r.framesOut == 240)
        #expect(abs(r.maxMs - 2.25) < 1e-9)
        #expect(abs(r.heldMs / 240 - 4.25) < 1e-9)
    }

    @Test("a seek resets the step, so even a short skip is no frame interval")
    func discontinuityResetsTheStep() throws {
        var w = DeinterlaceTimingWindow()
        var report: DeinterlaceTimingWindow.Report?
        for k in 0..<DeinterlaceTimingWindow.statsInterval {
            // a 0.5 s skip forward at frame 100, through the flush a seek makes
            if k == 100 { w.noteDiscontinuity() }
            let pts = Double(k) * Self.ntsc + (k >= 100 ? 0.5 : 0)
            if let r = feed(&w, k: k, outputs: 1, pts: pts) { report = r }
        }
        let r = try #require(report)
        #expect(abs(try #require(r.inputIntervalMs) - 33.367) < 0.01)
    }

    @Test("label names the filter and where inverse telecine runs")
    func labels() {
        #expect(DeinterlaceTimingWindow.label(for: VideoDeinterlace(
            filter: "bwdif_videotoolbox", isHardware: true, fieldRate: .field)) == "bwdif_videotoolbox, inverse telecine off")
        #expect(DeinterlaceTimingWindow.label(for: VideoDeinterlace(
            filter: "bwdif_videotoolbox", isHardware: true, fieldRate: .frame, inverseTelecine: true,
            inverseTelecineIsHardware: true)) == "bwdif_videotoolbox, inverse telecine GPU")
        #expect(DeinterlaceTimingWindow.label(for: VideoDeinterlace(
            filter: "bwdif", isHardware: false, fieldRate: .frame, inverseTelecine: true)) == "bwdif, inverse telecine CPU")
    }
}
