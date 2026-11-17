import AetherLibavutil

/// The input side a `SwrContext` was built for.
///
/// libswresample reads a frame's `extended_data` strictly per the input it was configured with, and
/// nothing revalidates that against later frames. A context that outlives a change in the frames
/// feeding it misreads them: a layout with more planes than the frame carries reads a NULL plane and
/// faults inside `swr_convert` (#452, a live TS splice from 5.1 to stereo at a program boundary),
/// while a rate or format change resamples garbage in silence. Every resampler that survives more
/// than one frame therefore records what it was built for and rebuilds when a frame stops matching.
///
/// Holds an `AVChannelLayout` copy, which allocates a channel map for custom-order layouts, so
/// `release()` belongs in the owner's teardown.
struct ResamplerInputParameters {

    private(set) var layout = AVChannelLayout()
    private(set) var format = AV_SAMPLE_FMT_NONE
    private(set) var rate: Int32 = 0

    /// Record the input a freshly built context was configured with. `layout` is the one handed to
    /// `swr_alloc_set_opts2`, which is the frame's when it carries one and a synthesised default
    /// when it does not.
    mutating func adopt(layout newLayout: inout AVChannelLayout, format newFormat: AVSampleFormat, rate newRate: Int32) {
        av_channel_layout_uninit(&layout)
        av_channel_layout_copy(&layout, &newLayout)
        format = newFormat
        rate = newRate
    }

    /// True when `frame` no longer matches what the context was built for.
    ///
    /// A field is compared only where the frame states it: a frame with an unresolved format or no
    /// layout fell back to the synthesised default at init, and must not rebuild the context on
    /// every frame. A layout comparison that cannot decide (a negative AVERROR, one of the layouts
    /// invalid) counts as changed, because carrying on with a stale context is the fault this exists
    /// to prevent.
    func differ(from frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if frame.pointee.sample_rate > 0, frame.pointee.sample_rate != rate { return true }
        if frame.pointee.format != AV_SAMPLE_FMT_NONE.rawValue, frame.pointee.format != format.rawValue { return true }
        if frame.pointee.ch_layout.nb_channels > 0 {
            let equal = withUnsafePointer(to: layout) { mine in
                av_channel_layout_compare(mine, &frame.pointee.ch_layout) == 0
            }
            if !equal { return true }
        }
        return false
    }

    /// How many `extended_data` planes a frame in this input format carries: one per channel when
    /// planar, a single interleaved plane otherwise. Every one of them is read by `swr_convert`.
    var planeCount: Int {
        av_sample_fmt_is_planar(format) != 0 ? Int(layout.nb_channels) : 1
    }

    /// True when `frame` carries every plane `swr_convert` will read from it.
    ///
    /// The comparison above rebuilds on a DECLARED input change. Corrupt live MPEG-TS decodes to a
    /// frame with `nb_samples > 0` and a NULL plane while declaring nothing, and `swr_convert`
    /// dereferences it the same way (`AudioBridge` guards the same case on the loopback path).
    func framePlanesArePresent(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        guard let planes = frame.pointee.extended_data else { return false }
        return (0..<planeCount).allSatisfy { planes[$0] != nil }
    }

    /// Drop the layout copy's channel map. Call from the owner's `close()`/teardown.
    mutating func release() {
        av_channel_layout_uninit(&layout)
        format = AV_SAMPLE_FMT_NONE
        rate = 0
    }
}

/// Index of the front-centre channel in `layout`, nil when there is none or the layout is the centre
/// alone: a mono track is not a dialogue stem, its one channel is the whole mix. A layout that only
/// states a count (AAC with a program config element, a plain WAV) is read in the default order for
/// that count, which is what swresample itself assumes for it (#908, AE#923).
///
/// The one definition of "has a centre" shared by the shaping lift (`AudioShapingMatrix`) and the
/// dialogue tap (`AudioTapDecoder`), which have to agree on it (audit AUD-R204).
func frontCentreIndex(of layout: UnsafePointer<AVChannelLayout>) -> Int? {
    let count = layout.pointee.nb_channels
    guard count > 1 else { return nil }
    var assumed = AVChannelLayout()
    defer { av_channel_layout_uninit(&assumed) }
    let index: Int32
    if layout.pointee.order == AV_CHANNEL_ORDER_UNSPEC {
        av_channel_layout_default(&assumed, count)
        index = av_channel_layout_index_from_channel(&assumed, AV_CHAN_FRONT_CENTER)
    } else {
        index = av_channel_layout_index_from_channel(layout, AV_CHAN_FRONT_CENTER)
    }
    return index >= 0 ? Int(index) : nil
}
