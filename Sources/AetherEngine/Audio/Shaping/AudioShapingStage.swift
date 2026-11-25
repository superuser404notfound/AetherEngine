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
/// Binaural (`AudioShaping.binaural`) sits between the two halves. The resampler then writes the
/// source's own speaker layout (`resamplerLayout`), the matrix only lifts the centre in it, and
/// `BinauralRenderer` turns it into the stereo the graph and the output carry. It needs the graph,
/// whose float input it feeds: without one the resampler folds to stereo as it always did.
///
/// Not thread safe: the owner serialises every call under its own lock, as for the graph.
final class AudioShapingStage {

    typealias Emit = ([UnsafeMutableRawPointer?], Int, Int64?) -> Void

    let shaping: AudioShaping
    private let outputFormat: AVSampleFormat
    private var sampleRate: Int32 = 0
    private var outputLayout = AVChannelLayout()
    private(set) var graph: AudioShapingGraph?
    private(set) var renderer: BinauralRenderer?
    /// The layout `renderer` was built for; empty without one.
    private var rendererLayout = AVChannelLayout()
    private var rendered: [Float] = []
    private var mismatchLogged = false

    init(shaping: AudioShaping, outputFormat: AVSampleFormat) {
        self.shaping = shaping.clamped
        self.outputFormat = outputFormat
    }

    deinit {
        av_channel_layout_uninit(&outputLayout)
        av_channel_layout_uninit(&rendererLayout)
    }

    var hasGraph: Bool { graph != nil }

    /// The layout the owner's resampler writes for a source of `source` shaped into `output`: the
    /// source's own speakers when they go binaural, otherwise `output`. A source whose channels name
    /// no speaker the mixer knows is folded to 7.1 first. Only binaural with a graph in place gives
    /// anything but `output`, so an owner may call this whether or not it shapes.
    func resamplerLayout(source: UnsafePointer<AVChannelLayout>, output: UnsafePointer<AVChannelLayout>,
                         into layout: inout AVChannelLayout) {
        av_channel_layout_uninit(&layout)
        guard graph != nil, Self.rendersBinaural(shaping: shaping, source: source, output: output) else {
            av_channel_layout_copy(&layout, output)
            return
        }
        Self.binauralBed(for: source, into: &layout)
    }

    static func rendersBinaural(shaping: AudioShaping, source: UnsafePointer<AVChannelLayout>,
                                output: UnsafePointer<AVChannelLayout>) -> Bool {
        BinauralRenderer.isAvailable && output.pointee.nb_channels == 2
            && shaping.rendersBinaural(sourceChannels: source.pointee.nb_channels)
    }

    /// The bed a binaural source is rendered from: its own layout when the mixer can place every
    /// channel (an unspecified order read in the default order for its count), else 7.1.
    static func binauralBed(for source: UnsafePointer<AVChannelLayout>, into layout: inout AVChannelLayout) {
        av_channel_layout_uninit(&layout)
        if BinauralRenderer.labels(for: source) != nil {
            if source.pointee.order == AV_CHANNEL_ORDER_UNSPEC {
                av_channel_layout_default(&layout, source.pointee.nb_channels)
            } else {
                av_channel_layout_copy(&layout, source)
            }
        } else {
            av_channel_layout_default(&layout, 8)
        }
    }

    /// Builds, keeps or drops the renderer so it matches the bed `resamplerLayout` now asks for.
    private func syncRenderer(sampleRate rate: Int32, source: UnsafePointer<AVChannelLayout>,
                              output: UnsafePointer<AVChannelLayout>) {
        var bed = AVChannelLayout()
        defer { av_channel_layout_uninit(&bed) }
        resamplerLayout(source: source, output: output, into: &bed)
        guard av_channel_layout_compare(&bed, output) != 0 else {
            renderer = nil
            av_channel_layout_uninit(&rendererLayout)
            return
        }
        if let current = renderer, current.sampleRate == rate,
           av_channel_layout_compare(&rendererLayout, &bed) == 0 { return }
        let next = BinauralRenderer.labels(for: &bed).flatMap { BinauralRenderer(labels: $0, sampleRate: rate) }
        renderer = next
        av_channel_layout_uninit(&rendererLayout)
        if next != nil { av_channel_layout_copy(&rendererLayout, &bed) }
        EngineLog.emit("[AudioShaping] binaural: " + (next.map { "\($0.inputChannels)ch bed -> 2ch at \(rate) Hz" }
                       ?? "the spatial mixer refused the bed, folding to stereo instead"), category: .session)
    }

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
        defer { syncRenderer(sampleRate: sampleRate, source: sourceLayout, output: &outputLayout) }
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

    /// `channels` is the width of `samples`: the bed `resamplerLayout` asked for, or the output's.
    func process(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, pts: Int64?, emit: Emit) {
        guard let graph else { return }
        guard let renderer, channels == renderer.inputChannels, channels != Int(outputLayout.nb_channels) else {
            if channels != Int(outputLayout.nb_channels) {
                if !mismatchLogged {
                    mismatchLogged = true
                    EngineLog.emit("[AudioShaping] \(channels)ch input with no renderer for it; dropped",
                                   category: .session)
                }
                return
            }
            graph.process(samples, frames: frames, pts: pts, emit: emit)
            return
        }
        if rendered.count < frames * 2 { rendered = [Float](repeating: 0, count: frames * 2) }
        rendered.withUnsafeMutableBufferPointer { out in
            renderer.render(.interleaved(samples), frames: frames, into: out.baseAddress!)
            graph.process(UnsafePointer(out.baseAddress!), frames: frames, pts: pts, emit: emit)
        }
    }

    func drain(emit: Emit) { graph?.drain(emit: emit) }

    func reset() {
        graph?.reset()
        renderer?.reset()
    }
}
