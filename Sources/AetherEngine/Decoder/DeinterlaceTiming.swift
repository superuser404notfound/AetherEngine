import Foundation

/// AE#1112: what the deinterlace graph costs the decoder's thread, summed over `statsInterval` input
/// frames and logged as one `[Deinterlace] timing` line. Covers inverse telecine too: `fieldmatch` and
/// `decimate` run inside the same push and pull.
///
/// The decoder feeds it under its lock, in the order the work happens: the decode calls, the push, the
/// pulls and the copy of each output frame, then `finishInput` once per frame it pushed. Work that lands
/// before the push (the flush of a graph whose cadence broke) belongs to the frame that caused it.
struct DeinterlaceTimingWindow {
    /// Input frames between two lines (8 s at 29.97 fps), the same count `GPUFrameConverter` uses.
    static let statsInterval = 240

    /// A PTS step longer than this is a seek or a gap, not a frame interval.
    static let maxFrameIntervalSeconds = 1.0

    struct Report: Equatable {
        var label: String
        var framesIn = 0
        var framesOut = 0
        var decodeMs = 0.0
        var pushMs = 0.0
        var pullMs = 0.0
        /// `VTPixelTransferSession` copies out of FFmpeg's pool (GPU engine).
        var transferMs = 0.0
        var transfers = 0
        /// `sws_scale` conversions into a pixel buffer (CPU engine).
        var convertMs = 0.0
        var converts = 0
        /// The worst single input frame: its push, pulls and copies. Decode is left out, since frame
        /// threading does not tie a decode call to one frame.
        var maxMs = 0.0
        /// Mean PTS step between pushed frames, nil when no two of them were close enough to measure.
        var inputIntervalMs: Double?

        var heldMs: Double { decodeMs + pushMs + pullMs + transferMs + convertMs }

        /// The input interval scaled by frames in over frames out: half of it at field rate, 5/4 of it
        /// after `decimate`.
        var outputIntervalMs: Double? {
            guard let inputIntervalMs, framesIn > 0, framesOut > 0 else { return nil }
            return inputIntervalMs * Double(framesIn) / Double(framesOut)
        }

        var logLine: String {
            let n = Double(max(framesIn, 1))
            func ms(_ v: Double) -> String { String(format: "%.2f ms", v / n) }
            var graph = "push \(ms(pushMs)), pull \(ms(pullMs))"
            if transfers > 0 { graph += ", transfer \(ms(transferMs))" }
            if converts > 0 { graph += ", convert \(ms(convertMs))" }
            var line = "[Deinterlace] timing: last \(framesIn) frames in, \(framesOut) out (\(label)): "
                + graph + " per input frame, max " + String(format: "%.2f ms", maxMs)
                + "; decode \(ms(decodeMs)); decoder thread held \(ms(heldMs)) per input frame"
            if let inputIntervalMs, let outputIntervalMs {
                line += String(format: " against a %.1f ms input / %.1f ms output interval",
                               inputIntervalMs, outputIntervalMs)
            }
            return line
        }
    }

    /// The work of the input frame in flight, folded into the window by `finishInput`.
    private struct Frame {
        var decodeMs = 0.0
        var pushMs = 0.0
        var pullMs = 0.0
        var transferMs = 0.0
        var transfers = 0
        var convertMs = 0.0
        var converts = 0
        var outputs = 0
        var graphMs: Double { pushMs + pullMs + transferMs + convertMs }
    }

    private var window: Report?
    private var frame = Frame()
    private var lastPTSSeconds: Double?
    private var intervalSumSeconds = 0.0
    private var intervalCount = 0

    mutating func addDecode(ms: Double) { frame.decodeMs += ms }
    mutating func addPush(ms: Double) { frame.pushMs += ms }
    mutating func addPull(ms: Double) { frame.pullMs += ms }
    mutating func addOutput() { frame.outputs += 1 }

    mutating func addTransfer(ms: Double) {
        frame.transferMs += ms
        frame.transfers += 1
    }

    mutating func addConvert(ms: Double) {
        frame.convertMs += ms
        frame.converts += 1
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
        w.framesOut += frame.outputs
        w.decodeMs += frame.decodeMs
        w.pushMs += frame.pushMs
        w.pullMs += frame.pullMs
        w.transferMs += frame.transferMs
        w.transfers += frame.transfers
        w.convertMs += frame.convertMs
        w.converts += frame.converts
        w.maxMs = max(w.maxMs, frame.graphMs)
        frame = Frame()

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
