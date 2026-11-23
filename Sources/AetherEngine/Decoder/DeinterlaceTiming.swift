import Foundation

/// AE#1112: what the deinterlace graph costs the decoder's thread, summed over `statsInterval` input
/// frames and logged as one `[Deinterlace] timing` line. Covers inverse telecine too: `fieldmatch` and
/// `decimate` run inside the same push and pull.
///
/// The decoder feeds it under its lock, in the order the work happens: the decode calls, the graph
/// check or build, the push, the pulls and the copy of each output frame, then `finishInput` once per
/// frame it pushed. Work that lands before the push (the flush of a graph whose cadence broke) belongs
/// to the frame that caused it. A frame that never reaches the graph is dropped with `discardPending`.
struct DeinterlaceTimingWindow {
    /// Input frames between two lines (8 s at 29.97 fps), the same count `GPUFrameConverter` uses.
    static let statsInterval = 240

    /// A PTS step longer than this is a gap, not a frame interval. Seeks reset the step through
    /// `noteDiscontinuity`.
    static let maxFrameIntervalSeconds = 1.0

    /// Times in milliseconds and counts, for one input frame or summed over a window.
    struct Costs: Equatable {
        var decodeMs = 0.0
        /// Graph builds (`ensureGraph` that built one): the first frame, a seek, a cadence break.
        var buildMs = 0.0
        var builds = 0
        var pushMs = 0.0
        var pullMs = 0.0
        /// `VTPixelTransferSession` copies out of FFmpeg's pool (GPU engine).
        var transferMs = 0.0
        var transfers = 0
        /// `sws_scale` conversions into a pixel buffer (CPU engine).
        var convertMs = 0.0
        var converts = 0
        /// Frames the graph returned, the ones dropped for a missing timestamp included.
        var outputs = 0

        /// Everything but decode, which frame threading does not tie to one frame.
        var graphMs: Double { buildMs + pushMs + pullMs + transferMs + convertMs }

        static func += (lhs: inout Costs, rhs: Costs) {
            lhs.decodeMs += rhs.decodeMs
            lhs.buildMs += rhs.buildMs
            lhs.builds += rhs.builds
            lhs.pushMs += rhs.pushMs
            lhs.pullMs += rhs.pullMs
            lhs.transferMs += rhs.transferMs
            lhs.transfers += rhs.transfers
            lhs.convertMs += rhs.convertMs
            lhs.converts += rhs.converts
            lhs.outputs += rhs.outputs
        }
    }

    struct Report: Equatable {
        var label: String
        var framesIn = 0
        var costs = Costs()
        /// The worst single input frame's graph work (`Costs.graphMs`).
        var maxMs = 0.0
        /// Mean PTS step between pushed frames, nil when no two of them were close enough to measure.
        var inputIntervalMs: Double?

        var framesOut: Int { costs.outputs }
        var heldMs: Double { costs.decodeMs + costs.graphMs }

        /// The input interval scaled by frames in over frames out: half of it at field rate, 5/4 of it
        /// after `decimate`.
        var outputIntervalMs: Double? {
            guard let inputIntervalMs, framesIn > 0, framesOut > 0 else { return nil }
            return inputIntervalMs * Double(framesIn) / Double(framesOut)
        }

        var logLine: String {
            let n = Double(max(framesIn, 1))
            func ms(_ v: Double) -> String { String(format: "%.2f ms", v / n) }
            var graph = ""
            if costs.builds > 0 { graph += "builds \(costs.builds) (" + String(format: "%.1f ms total", costs.buildMs) + "), " }
            graph += "push \(ms(costs.pushMs)), pull \(ms(costs.pullMs))"
            if costs.transfers > 0 { graph += ", transfer \(ms(costs.transferMs))" }
            if costs.converts > 0 { graph += ", convert \(ms(costs.convertMs))" }
            var line = "[Deinterlace] timing: last \(framesIn) frames in, \(framesOut) out (\(label)): "
                + graph + " per input frame, max " + String(format: "%.2f ms", maxMs)
                + "; decode \(ms(costs.decodeMs)); decoder thread held \(ms(heldMs)) per input frame"
            if let inputIntervalMs, let outputIntervalMs {
                line += String(format: " against a %.1f ms input / %.1f ms output interval",
                               inputIntervalMs, outputIntervalMs)
            }
            return line
        }
    }

    private var window: Report?
    /// The input frame in flight, folded into the window by `finishInput`.
    private var pending = Costs()
    private var lastPTSSeconds: Double?
    private var intervalSumSeconds = 0.0
    private var intervalCount = 0

    mutating func addDecode(ms: Double) { pending.decodeMs += ms }
    mutating func addPush(ms: Double) { pending.pushMs += ms }
    mutating func addPull(ms: Double) { pending.pullMs += ms }
    mutating func addOutput() { pending.outputs += 1 }

    mutating func addBuild(ms: Double) {
        pending.buildMs += ms
        pending.builds += 1
    }

    mutating func addTransfer(ms: Double) {
        pending.transferMs += ms
        pending.transfers += 1
    }

    mutating func addConvert(ms: Double) {
        pending.convertMs += ms
        pending.converts += 1
    }

    /// The frame in flight did not go through the graph (no graph, a failed push), or its graph was
    /// drained and dropped: none of its work belongs to the next frame.
    mutating func discardPending() { pending = Costs() }

    /// A seek or flush: the next PTS step is no frame interval, and nothing pending carries over.
    mutating func noteDiscontinuity() {
        lastPTSSeconds = nil
        pending = Costs()
    }

    /// Closes the input frame that was just pushed. `label` names the graph it went through; a new
    /// label starts a new window, so one line never mixes two chains. Returns the window once it holds
    /// `statsInterval` frames.
    mutating func finishInput(label: String, ptsSeconds: Double?) -> Report? {
        if window?.label != label {
            window = Report(label: label)
            lastPTSSeconds = nil
            intervalSumSeconds = 0
            intervalCount = 0
        }
        guard var w = window else { return nil }
        w.framesIn += 1
        w.costs += pending
        w.maxMs = max(w.maxMs, pending.graphMs)
        pending = Costs()

        if let pts = ptsSeconds {
            if let last = lastPTSSeconds {
                let step = pts - last
                if step > 0, step < Self.maxFrameIntervalSeconds {
                    intervalSumSeconds += step
                    intervalCount += 1
                }
            }
            lastPTSSeconds = pts
        }

        guard w.framesIn >= Self.statsInterval else {
            window = w
            return nil
        }
        if intervalCount > 0 { w.inputIntervalMs = intervalSumSeconds / Double(intervalCount) * 1000 }
        window = Report(label: label)
        intervalSumSeconds = 0
        intervalCount = 0
        return w
    }

    /// The `[Deinterlace] timing` label for a graph: filter, then where inverse telecine runs.
    static func label(for deinterlace: VideoDeinterlace) -> String {
        let cadence = !deinterlace.inverseTelecine ? "off" : (deinterlace.inverseTelecineIsHardware ? "GPU" : "CPU")
        return "\(deinterlace.filter), inverse telecine \(cadence)"
    }
}
