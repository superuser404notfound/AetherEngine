import Foundation
import AetherLibavcodec
import AetherLibavutil

/// AE#847: silence that carries the audio track to the end of the picture.
///
/// AVPlayer ends a muxed HLS item the moment its audio runs out, however much video is still
/// ahead (measured with a 60 s picture over 35 s of AC-3: `didPlayToEndTime` at 35.0 s, from
/// the engine's loopback and from a plain ffmpeg fMP4 playlist alike). A re-seek in place does
/// not get past it, the AE#287 cure for the opposite case, and neither does disabling the audio
/// track (the clock then stands still at the boundary). A GAP in the audio is fine: with audio
/// at 0-35 s and again at 59-60 s the same item plays to 59.99 s, also when it starts inside
/// the gap. So the final segment of a title whose audio ends early gets silence from where its
/// audio stops to where its video does, encoded in the codec the track is delivered in, and
/// AVPlayer bridges whatever gap remains before that segment on its own.
///
/// Hybrid remuxes (a web video track over a disc's audio) end their audio tens of seconds early
/// often enough that the rest of the credits went missing, and a resume inside that tail ended
/// the item at load.
enum AudioTailPadding {

    /// The span to fill, in seconds on the output axis, or nil when the audio already reaches the
    /// picture's end closely enough. `audioEnd` is nil when this run wrote no audio at all (a start
    /// inside the tail). The span never reaches back before `segmentStart`: earlier segments are
    /// already cut, and the gap in front of the fill is the one AVPlayer bridges.
    ///
    /// The threshold is the engine's end-of-media epsilon, so a title whose tracks end within half
    /// a second of each other (nearly every file) is muxed exactly as before.
    ///
    /// The span is capped at `maxFillSeconds` (`capped` says it was). The fill never needs more than
    /// the final segment's length plus the early-ending audio, and a corrupt final cluster whose
    /// last video timestamp sits hours past the audio would otherwise ask for hours of silence
    /// (audit AUD-209).
    static func span(videoEnd: Double, audioEnd: Double?, segmentStart: Double)
        -> (start: Double, end: Double, capped: Bool)? {
        guard videoEnd.isFinite, segmentStart.isFinite else { return nil }
        let start = max(audioEnd ?? segmentStart, segmentStart)
        guard videoEnd - start > AetherEngine.endOfMediaEpsilonSeconds else { return nil }
        let capped = videoEnd - start > maxFillSeconds
        return (start, capped ? start + maxFillSeconds : videoEnd, capped)
    }

    /// Ten minutes. Hybrid remuxes end their audio tens of seconds early and the final segment is
    /// seconds long (the plan's longest trusted gap is 30 s), so this is far past any real tail
    /// while holding a bad timestamp to about 19k E-AC-3 frames, written as they are encoded.
    static let maxFillSeconds = 600.0

    /// Whole encoder frames that fit into `ticks` of `timeBase`, at least one. Rounded down, so the
    /// fill never runs past the picture: a sub-frame shortfall is below anything AVPlayer acts on,
    /// while audio that outlasts the video is the AE#287 shape.
    static func frameCount(spanTicks: Int64, timeBase: AVRational, sampleRate: Int32, frameSize: Int32) -> Int {
        guard spanTicks > 0, timeBase.den > 0, sampleRate > 0, frameSize > 0 else { return 0 }
        let samples = av_rescale_q(spanTicks, timeBase, AVRational(num: 1, den: sampleRate))
        return max(1, Int(samples / Int64(frameSize)))
    }

    /// Whether the AAC track is Low Complexity, the only profile FFmpeg's encoder writes. HE-AAC
    /// frames are not interchangeable with LC ones under the same AudioSpecificConfig. An unknown
    /// profile is read from the ASC's audio object type (2 = LC); no ASC means no answer.
    static func aacIsLowComplexity(profile: Int32, extradata: [UInt8]) -> Bool {
        if profile == AV_PROFILE_AAC_LOW { return true }
        if profile != AV_PROFILE_UNKNOWN { return false }
        guard let first = extradata.first else { return false }
        return first >> 3 == 2
    }

    enum Outcome {
        case packets([UnsafeMutablePointer<AVPacket>], encoder: String)
        case unavailable(String)
    }

    /// Silent packets from `startTicks` on, stamped back to back in `timeBase` (the muxer's audio
    /// time base). The caller owns them and frees them with `trackedPacketFree`.
    ///
    /// The packets are stamped here rather than taken from the encoder: encoders with a priming
    /// delay (AAC) shift their own timestamps, and every frame is the same silence, so only the
    /// position matters.
    static func silencePackets(
        codecpar: UnsafePointer<AVCodecParameters>,
        startTicks: Int64,
        endTicks: Int64,
        timeBase: AVRational
    ) -> Outcome {
        var collected: [UnsafeMutablePointer<AVPacket>] = []
        switch streamSilence(codecpar: codecpar, startTicks: startTicks, endTicks: endTicks, timeBase: timeBase,
                             write: { collected.append($0) }) {
        case .unavailable(let reason):
            for p in collected { var q: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&q) }
            return .unavailable(reason)
        case .streamed(let encoder, _):
            return .packets(collected, encoder: encoder)
        }
    }

    enum StreamOutcome {
        case streamed(encoder: String, packets: Int)
        case unavailable(String)
    }

    /// `silencePackets`, handing each stamped packet to `write` as the encoder produces it instead
    /// of holding the whole fill (audit AUD-209). `write` owns the packet and frees it with
    /// `trackedPacketFree`. Everything that can refuse does so before the first packet is written.
    static func streamSilence(
        codecpar: UnsafePointer<AVCodecParameters>,
        startTicks: Int64,
        endTicks: Int64,
        timeBase: AVRational,
        write: (UnsafeMutablePointer<AVPacket>) -> Void
    ) -> StreamOutcome {
        let par = codecpar.pointee
        let codecID = par.codec_id
        if codecID == AV_CODEC_ID_AAC {
            let extradata = par.extradata.map { Array(UnsafeBufferPointer(start: $0, count: Int(par.extradata_size))) } ?? []
            guard aacIsLowComplexity(profile: par.profile, extradata: extradata) else {
                return .unavailable("AAC profile \(par.profile) is not Low Complexity")
            }
        }
        guard let codec = avcodec_find_encoder(codecID) else {
            return .unavailable("this FFmpeg build has no \(String(cString: avcodec_get_name(codecID))) encoder")
        }
        guard par.sample_rate > 0, par.ch_layout.nb_channels > 0 else {
            return .unavailable("the track declares no sample rate or channel count")
        }
        var encOpt = avcodec_alloc_context3(codec)
        guard let enc = encOpt else { return .unavailable("encoder context allocation failed") }
        defer { avcodec_free_context(&encOpt) }

        enc.pointee.sample_rate = par.sample_rate
        enc.pointee.time_base = AVRational(num: 1, den: par.sample_rate)
        if par.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&enc.pointee.ch_layout, par.ch_layout.nb_channels)
        } else {
            var layout = par.ch_layout
            guard av_channel_layout_copy(&enc.pointee.ch_layout, &layout) >= 0 else {
                return .unavailable("channel layout copy failed")
            }
        }
        let bits = par.bits_per_raw_sample
        enc.pointee.bits_per_raw_sample = bits
        guard let format = sampleFormat(for: codec, bitsPerRawSample: bits) else {
            return .unavailable("the encoder lists no sample format")
        }
        enc.pointee.sample_fmt = format
        if par.bit_rate > 0, codecID == AV_CODEC_ID_AC3 || codecID == AV_CODEC_ID_EAC3 || codecID == AV_CODEC_ID_AAC {
            enc.pointee.bit_rate = par.bit_rate
        }
        // ALAC frames are decoded against the track's magic cookie, whose frameLength the fill
        // must not exceed; FFmpeg's encoder writes 4096, as does nearly every source, but a cookie
        // that says otherwise is honoured.
        if codecID == AV_CODEC_ID_ALAC, let frameLength = alacFrameLength(par) {
            enc.pointee.frame_size = frameLength
        }
        let openRet = avcodec_open2(enc, codec, nil)
        guard openRet >= 0 else {
            return .unavailable("avcodec_open2 refused the track's parameters (\(openRet))")
        }

        let frameSize = enc.pointee.frame_size > 0 ? enc.pointee.frame_size : 1024
        let frames = frameCount(spanTicks: endTicks - startTicks, timeBase: timeBase,
                                sampleRate: par.sample_rate, frameSize: frameSize)
        let encoderName = String(cString: codec.pointee.name)
        guard frames > 0 else { return .streamed(encoder: encoderName, packets: 0) }

        let frameTicks = av_rescale_q(Int64(frameSize), AVRational(num: 1, den: par.sample_rate), timeBase)
        var emitted = 0
        func drain() {
            while emitted < frames, let pkt = trackedPacketAlloc() {
                guard avcodec_receive_packet(enc, pkt) >= 0 else {
                    var p: UnsafeMutablePointer<AVPacket>? = pkt
                    trackedPacketFree(&p)
                    return
                }
                let pts = startTicks + av_rescale_q(Int64(emitted) * Int64(frameSize),
                                                    AVRational(num: 1, den: par.sample_rate), timeBase)
                pkt.pointee.pts = pts
                pkt.pointee.dts = pts
                pkt.pointee.duration = frameTicks
                pkt.pointee.flags |= AV_PKT_FLAG_KEY
                emitted += 1
                write(pkt)
            }
        }

        var frameOpt: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frameOpt) }
        guard let frame = frameOpt else { return .unavailable("frame allocation failed") }
        for index in 0..<frames {
            av_frame_unref(frame)
            frame.pointee.format = format.rawValue
            frame.pointee.nb_samples = frameSize
            frame.pointee.sample_rate = par.sample_rate
            _ = av_channel_layout_copy(&frame.pointee.ch_layout, &enc.pointee.ch_layout)
            guard av_frame_get_buffer(frame, 0) >= 0 else { break }
            _ = av_samples_set_silence(frame.pointee.extended_data, 0, frameSize,
                                       enc.pointee.ch_layout.nb_channels, format)
            frame.pointee.pts = Int64(index) * Int64(frameSize)
            guard avcodec_send_frame(enc, frame) >= 0 else { break }
            drain()
        }
        _ = avcodec_send_frame(enc, nil)
        drain()

        return .streamed(encoder: encoderName, packets: emitted)
    }

    /// `frameLength` from an ALAC magic cookie, with or without the 12-byte atom header movenc
    /// and Matroska put in front of the ALACSpecificConfig.
    static func alacFrameLength(_ par: AVCodecParameters) -> Int32? {
        guard let data = par.extradata else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data, count: Int(par.extradata_size)))
        let offset = bytes.count >= 36 && bytes[4...7] == [0x61, 0x6C, 0x61, 0x63] ? 12 : 0
        guard bytes.count >= offset + 4 else { return nil }
        let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return value > 0 && value <= 16_384 ? Int32(value) : nil
    }

    /// The format to feed the encoder: for the lossless codecs the one that keeps the track's bit
    /// depth (a 16-bit FLAC stream must not grow 32-bit frames under its STREAMINFO), otherwise the
    /// encoder's first.
    private static func sampleFormat(for codec: UnsafePointer<AVCodec>, bitsPerRawSample: Int32) -> AVSampleFormat? {
        var configs: UnsafeRawPointer?
        var count: Int32 = 0
        guard avcodec_get_supported_config(nil, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, &configs, &count) >= 0,
              let list = configs, count > 0 else { return nil }
        let formats = (0..<Int(count)).map { list.assumingMemoryBound(to: AVSampleFormat.self)[$0] }
        let wantsWide = bitsPerRawSample > 16
        let preferred = formats.first { fmt in
            let bytes = av_get_bytes_per_sample(fmt)
            return wantsWide ? bytes == 4 : bytes == 2
        }
        return preferred ?? formats.first
    }
}
