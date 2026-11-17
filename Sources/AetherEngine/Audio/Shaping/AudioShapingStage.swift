import Foundation
import AetherLibavutil
import AetherLibswresample

/// AE#923: the shaping a PCM path runs, as one object. `AudioBridge` and `AudioDecoder` both remix
/// in their resampler (`AudioShapingMatrix`) and then dynamics-process in an `AudioShapingGraph`,
/// and the two halves have to agree on who lifts the dialogue: the matrix lifts a source's front
/// centre, the graph's `dialoguenhance` covers a stereo source that has none. When the source's
/// layout changes mid-stream that decision changes with it, so this type is where it is re-made
/// (audit AUD-203, AUD-207).
///
/// A rebuild keeps the loudness measurement (`LoudnessNormalizer`) and pushes the old graph's held
/// tail out through the caller's `emit` before the new graph takes over, so a programme boundary
/// neither restarts the AE#1036 gain at 0 dB nor drops the last milliseconds before it.
///
/// Not thread safe: the owner serialises every call under its own lock, as for the graph.
final class AudioShapingStage {

    typealias Emit = ([UnsafeMutableRawPointer?], Int, Int64?) -> Void

    let shaping: AudioShaping
    private let outputFormat: AVSampleFormat
    private var sampleRate: Int32 = 0
    private var outputLayout = AVChannelLayout()
    private(set) var graph: AudioShapingGraph?

    init(shaping: AudioShaping, outputFormat: AVSampleFormat) {
        self.shaping = shaping.clamped
        self.outputFormat = outputFormat
    }

    deinit { av_channel_layout_uninit(&outputLayout) }

    var hasGraph: Bool { graph != nil }

    /// The loudness target's gain in force, in dB; nil without a target or a graph.
    var loudnessGainDB: Double? { graph?.loudnessGainDB }

    /// Hands the shaping matrix to an allocated, not yet initialized resampler.
    @discardableResult
    func applyMatrix(to swr: OpaquePointer, input: UnsafePointer<AVChannelLayout>,
                     output: UnsafePointer<AVChannelLayout>) -> Bool {
        AudioShapingMatrix.apply(to: swr, input: input, output: output,
                                 dialogueGain: shaping.dialogueGain, lfeMixLevel: shaping.lfeMixLevel)
    }

    /// Whether `configure` with these parameters would replace the graph: the rate, the output
    /// layout or the dialogue route changed, or the graph already ended.
    func rebuildNeeded(sampleRate newRate: Int32, outputLayout newLayout: UnsafePointer<AVChannelLayout>,
                       sourceLayout: UnsafePointer<AVChannelLayout>) -> Bool {
        guard let old = graph else { return false }
        if old.ended || newRate != sampleRate || av_channel_layout_compare(&outputLayout, newLayout) != 0 { return true }
        let route = AudioShapingGraph.usesStereoDialogueEnhance(
            shaping: shaping, outputChannels: newLayout.pointee.nb_channels,
            sourceHasCentre: AudioShapingMatrix.hasCentre(sourceLayout))
        return route != old.enhancesDialogue
    }

    /// For an owner whose output format changes with the rebuild: pushes the graph's held tail out
    /// now, while the owner still describes the old format, when `configure` is about to replace it.
    func drainIfRebuilding(sampleRate newRate: Int32, outputLayout newLayout: UnsafePointer<AVChannelLayout>,
                           sourceLayout: UnsafePointer<AVChannelLayout>, emit: Emit) {
        guard rebuildNeeded(sampleRate: newRate, outputLayout: newLayout, sourceLayout: sourceLayout) else { return }
        graph?.drain(emit: emit)
    }

    /// Brings the graph in line with the stream now feeding it: builds it on the first call, and
    /// later rebuilds only when `rebuildNeeded`. Returns whether a graph is in place afterwards.
    ///
    /// The new graph is built before the old one is touched, so a failed build leaves a graph that
    /// that still matches the output serving (a stale dialogue route beats an unshaped session). The old graph's
    /// tail goes out through `emit` unless it was drained already. The loudness measurement moves
    /// to the new graph.
    @discardableResult
    func configure(sampleRate newRate: Int32, outputLayout newLayout: UnsafePointer<AVChannelLayout>,
                   sourceLayout: UnsafePointer<AVChannelLayout>, emit: Emit?) -> Bool {
        if let old = graph {
            guard rebuildNeeded(sampleRate: newRate, outputLayout: newLayout, sourceLayout: sourceLayout) else { return true }
            old.normalizer?.rebind(sampleRate: newRate, layout: newLayout)
            guard let next = AudioShapingGraph(shaping: shaping, sampleRate: newRate, layout: newLayout,
                                               sourceHasCentre: AudioShapingMatrix.hasCentre(sourceLayout),
                                               outputFormat: outputFormat, normalizer: old.normalizer) else {
                let keeps = !old.ended && newRate == sampleRate && av_channel_layout_compare(&outputLayout, newLayout) == 0
                if !keeps { graph = nil }
                EngineLog.emit("[AudioShaping] filter graph could not follow a source layout change; "
                               + (keeps ? "the previous graph keeps serving" : "audio passes unshaped"),
                               category: .session)
                return graph != nil
            }
            if let emit { old.drain(emit: emit) }
            graph = next
        } else {
            graph = AudioShapingGraph(shaping: shaping, sampleRate: newRate, layout: newLayout,
                                      sourceHasCentre: AudioShapingMatrix.hasCentre(sourceLayout),
                                      outputFormat: outputFormat)
        }
        sampleRate = newRate
        av_channel_layout_uninit(&outputLayout)
        av_channel_layout_copy(&outputLayout, newLayout)
        return graph != nil
    }

    func process(_ samples: UnsafePointer<Float>, frames: Int, pts: Int64?, emit: Emit) {
        graph?.process(samples, frames: frames, pts: pts, emit: emit)
    }

    func drain(emit: Emit) { graph?.drain(emit: emit) }

    func reset() { graph?.reset() }
}
