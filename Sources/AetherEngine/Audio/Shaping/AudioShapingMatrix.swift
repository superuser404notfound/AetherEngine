import Foundation
import AetherLibavutil
import AetherLibswresample

/// AE#923: the channel half of audio shaping, as a remix matrix for libswresample.
///
/// The downmix is libswresample's own (`swr_build_matrix2` with its default levels: centre and
/// surrounds at -3 dB, LFE dropped), so a capped session folds exactly the way an uncapped one
/// already did whenever the route forced a fold. The dialogue lift is applied to that matrix rather
/// than as a separate pass, so it costs nothing per sample: a source with a front centre gets that
/// input column scaled, wherever the centre lands. A source without a centre is lifted in
/// `AudioShapingGraph` instead (`dialoguenhance`), which separates the dialogue from wide content
/// where a matrix can only raise everything the two sides share.
///
/// The matrix is not normalized: a fold that sums past full scale, and a lift on top of it, is caught
/// by the limiter in `AudioShapingGraph`, which runs whenever shaping is active. Normalizing
/// instead would buy headroom by turning everything down by the worst-case sum (7.6 dB on a 5.1 fold),
/// which is the opposite of what a viewer who cannot hear the dialogue asked for.
enum AudioShapingMatrix {

    /// Row-major `[output][input]` coefficients, `stride` = input channel count, or nil when the
    /// default libswresample would build is already the answer (same layout in and out, no lift).
    ///
    /// A layout of unspecified order (a plain WAV, AAC with a PCE) is read in the default order for
    /// its channel count, the way libswresample itself reads it (AE#908 found the same in the tap).
    static func coefficients(
        input rawInput: UnsafePointer<AVChannelLayout>,
        output rawOutput: UnsafePointer<AVChannelLayout>,
        dialogueGain: Double
    ) -> [Double]? {
        let inCount = Int(rawInput.pointee.nb_channels)
        let outCount = Int(rawOutput.pointee.nb_channels)
        guard inCount > 0, outCount > 0 else { return nil }
        var inLayout = AVChannelLayout(), outLayout = AVChannelLayout()
        defer { av_channel_layout_uninit(&inLayout); av_channel_layout_uninit(&outLayout) }
        resolved(rawInput, into: &inLayout)
        resolved(rawOutput, into: &outLayout)
        return withUnsafePointer(to: &inLayout) { input in
            withUnsafePointer(to: &outLayout) { output in
                coefficients(resolvedInput: input, output: output, inCount: inCount, outCount: outCount,
                             dialogueGain: dialogueGain)
            }
        }
    }

    private static func resolved(_ layout: UnsafePointer<AVChannelLayout>, into out: inout AVChannelLayout) {
        if layout.pointee.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&out, layout.pointee.nb_channels)
        } else {
            av_channel_layout_copy(&out, layout)
        }
    }

    private static func coefficients(
        resolvedInput input: UnsafePointer<AVChannelLayout>,
        output: UnsafePointer<AVChannelLayout>,
        inCount: Int,
        outCount: Int,
        dialogueGain: Double
    ) -> [Double]? {
        let lift = dialogueGain.isFinite && dialogueGain > 1 ? dialogueGain : 1
        if lift == 1, av_channel_layout_compare(input, output) == 0 { return nil }

        var matrix = [Double](repeating: 0, count: inCount * outCount)
        let built = matrix.withUnsafeMutableBufferPointer { buf in
            swr_build_matrix2(input, output,
                              M_SQRT1_2, M_SQRT1_2, 0,
                              Double(Int32.max), 1.0,
                              buf.baseAddress, inCount, AV_MATRIX_ENCODING_NONE, nil)
        }
        guard built >= 0 else { return nil }
        guard lift > 1 else { return matrix }

        let centre = Int(av_channel_layout_index_from_channel(input, AV_CHAN_FRONT_CENTER))
        if centre >= 0 {
            for o in 0..<outCount { matrix[o * inCount + centre] *= lift }
        }
        return matrix
    }

    /// Whether the source carries a front centre the matrix can lift. Read in the default order for
    /// an unspecified layout, like `coefficients`. A mono source counts as no centre: its one channel
    /// is the whole mix, not the dialogue.
    static func hasCentre(_ layout: UnsafePointer<AVChannelLayout>) -> Bool {
        guard layout.pointee.nb_channels > 1 else { return false }
        var resolved = AVChannelLayout()
        defer { av_channel_layout_uninit(&resolved) }
        if layout.pointee.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&resolved, layout.pointee.nb_channels)
        } else {
            av_channel_layout_copy(&resolved, layout)
        }
        return av_channel_layout_index_from_channel(&resolved, AV_CHAN_FRONT_CENTER) >= 0
    }

    /// Hand the matrix to an allocated, not yet initialized resampler. Returns false when the
    /// resampler refused it, in which case the caller's default downmix stands.
    @discardableResult
    static func apply(
        to swr: OpaquePointer,
        input: UnsafePointer<AVChannelLayout>,
        output: UnsafePointer<AVChannelLayout>,
        dialogueGain: Double
    ) -> Bool {
        guard let matrix = coefficients(input: input, output: output, dialogueGain: dialogueGain) else { return true }
        let ret = matrix.withUnsafeBufferPointer { buf in
            swr_set_matrix(swr, buf.baseAddress, input.pointee.nb_channels)
        }
        if ret < 0 {
            EngineLog.emit("[AudioShaping] swr_set_matrix refused the shaping matrix (\(ret)); "
                           + "the default downmix stands", category: .session)
            return false
        }
        return true
    }
}
