import AetherLibavutil

/// AE#1120: whether a FLAC track served in fMP4 keeps its channel layout on Apple platforms.
///
/// CoreMedia reads no layout from a FLAC sample entry. A `chnl` box or a QuickTime `chan` box next to
/// `dfLa`, and a `WAVEFORMATEXTENSIBLE_CHANNEL_MASK` comment inside it, are all ignored (measured with
/// `CMAudioFormatDescriptionGetChannelLayout` on macOS 27), and Apple's own `afconvert` drops the layout
/// when it writes FLAC into MP4. What CoreMedia assumes instead is one layout per channel count, the
/// FLAC format's defaults, which are also FFmpeg's (`flac_channel_layouts`):
///
/// | ch | assumed |
/// |---|---|
/// | 1 | C |
/// | 2 | L R |
/// | 3 | L R C |
/// | 4 | L R Rls Rrs |
/// | 5 | L R C Ls Rs |
/// | 6 | L R C LFE Ls Rs |
/// | 7 | L R C LFE Cs Ls Rs |
/// | 8 | L R C LFE Rls Rrs Ls Rs |
///
/// Any other layout plays with some of its channels on the wrong speakers: 7.1(wide) puts its
/// front-of-centre pair on the side surrounds, 2.1 plays its LFE as a centre. Such a track has to leave
/// the engine as PCM, whose `chnl` box CoreMedia does read.
///
/// One equivalence is allowed. A layout whose only surround pair is the BACK pair (FFmpeg's 5.1, which
/// is what an AAC 5.1 decodes to) counts as the side pair: with one surround pair there is nothing for
/// the two labels to tell apart, and moving the most common 5.1 FLAC off stream copy for it would cost
/// a decode and twice the bit rate for no audible change.
enum FLACChannelLabels {

    /// The layout CoreMedia assumes for a FLAC track of `channels` channels, in sample order. Nil above 8,
    /// which FLAC cannot carry.
    static func assumedLayout(channels: Int) -> [AVChannel]? {
        switch channels {
        case 1: return [AV_CHAN_FRONT_CENTER]
        case 2: return [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT]
        case 3: return [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER]
        case 4: return [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT]
        case 5: return [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER,
                        AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT]
        case 6: return [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
                        AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT]
        case 7: return [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
                        AV_CHAN_BACK_CENTER, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT]
        case 8: return [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
                        AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT]
        default: return nil
        }
    }

    /// False only when the track would play channels on the wrong speakers AND PCM can name every one of
    /// them, so the answer decides between FLAC and PCM. True for:
    /// - a layout CoreMedia assumes anyway;
    /// - one or two channels, where a label (a mono track tagged front left, a stereo pair tagged Lt/Rt)
    ///   would move the sound off the centre or the pair rather than fix anything;
    /// - an order that names no speakers (unknown, ambisonic) and a channel movenc's `chnl` table has no
    ///   position for, where a PCM header would fail to write and the session would lose its audio;
    /// - a count FLAC cannot carry, which the bridge downmixes anyway.
    static func carries(_ layout: UnsafePointer<AVChannelLayout>) -> Bool {
        let count = Int(layout.pointee.nb_channels)
        guard count > 2,
              layout.pointee.order == AV_CHANNEL_ORDER_NATIVE || layout.pointee.order == AV_CHANNEL_ORDER_CUSTOM,
              let assumed = assumedLayout(channels: count) else { return true }
        let source = (0..<count).map { av_channel_layout_channel_from_index(layout, UInt32($0)) }
        guard source.allSatisfy(chnlPositions.contains) else { return true }
        return foldingLoneBackPair(source) == foldingLoneBackPair(assumed)
    }

    /// The speakers movenc can write into a `chnl` box (`iso_channel_position` in libavformat's
    /// mov_chan.c). Any other channel makes the PCM header write fail.
    static let chnlPositions: Set<AVChannel> = [
        AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
        AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT, AV_CHAN_FRONT_LEFT_OF_CENTER, AV_CHAN_FRONT_RIGHT_OF_CENTER,
        AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT, AV_CHAN_BACK_CENTER,
        AV_CHAN_SURROUND_DIRECT_LEFT, AV_CHAN_SURROUND_DIRECT_RIGHT,
        AV_CHAN_SIDE_SURROUND_LEFT, AV_CHAN_SIDE_SURROUND_RIGHT, AV_CHAN_WIDE_LEFT, AV_CHAN_WIDE_RIGHT,
        AV_CHAN_TOP_FRONT_LEFT, AV_CHAN_TOP_FRONT_RIGHT, AV_CHAN_TOP_FRONT_CENTER,
        AV_CHAN_TOP_BACK_LEFT, AV_CHAN_TOP_BACK_RIGHT, AV_CHAN_TOP_BACK_CENTER,
        AV_CHAN_TOP_SIDE_LEFT, AV_CHAN_TOP_SIDE_RIGHT, AV_CHAN_TOP_CENTER, AV_CHAN_LOW_FREQUENCY_2,
        AV_CHAN_BOTTOM_FRONT_LEFT, AV_CHAN_BOTTOM_FRONT_RIGHT, AV_CHAN_BOTTOM_FRONT_CENTER,
    ]

    /// The back pair renamed to the side pair when the layout has no side pair of its own.
    static func foldingLoneBackPair(_ channels: [AVChannel]) -> [AVChannel] {
        guard channels.contains(AV_CHAN_BACK_LEFT), channels.contains(AV_CHAN_BACK_RIGHT),
              !channels.contains(AV_CHAN_SIDE_LEFT), !channels.contains(AV_CHAN_SIDE_RIGHT) else {
            return channels
        }
        return channels.map {
            $0 == AV_CHAN_BACK_LEFT ? AV_CHAN_SIDE_LEFT : $0 == AV_CHAN_BACK_RIGHT ? AV_CHAN_SIDE_RIGHT : $0
        }
    }
}
