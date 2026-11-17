import Foundation
import AetherLibavcodec
import AetherLibavutil

/// #232: verifies a DECLARED interlaced H.264 stream against what the decoder actually emits.
///
/// The declaration and the decoder disagree systematically on progressive-in-interlaced-carriage
/// (PsF). Blu-ray has no 1080p25, so European 25 fps masters ship as 1080i25: interlaced carriage,
/// progressive pictures. FFmpeg then answers the same SEI two different ways:
///
/// - `h264_parser.c` (feeds `codecpar.field_order`, which is what the routing rule reads) sets
///   `AV_FIELD_TT` for a FRAME-coded picture on SEI `pic_struct == TOP_BOTTOM` alone. It weighs
///   neither `ct_type` nor how the slices were actually coded.
/// - `h264_slice.c` (feeds `AV_FRAME_FLAG_INTERLACED`) flags that same picture only when it is
///   field- or MBAFF-coded, and a `clock_timestamp` carrying `ct_type` overrides even that.
///
/// So the routing rule consumes the structurally less informed of the two values.
///
/// The probe deliberately does NOT try to answer "is this content progressive". It answers the
/// narrower question the routing rule actually rests on: WILL THE DEINTERLACER EVER ENGAGE.
/// `SoftwareVideoDecoder` engages it on `AV_FRAME_FLAG_INTERLACED` and on nothing else, so a
/// sample in which that flag never appears proves the software detour is a no-op for this stream:
/// what plays today is already the un-deinterlaced picture, and the native path renders the same
/// frames with hardware decode.
///
/// Because the probe's predicate IS the engagement predicate, its false positives are harmless by
/// construction. A stream whose first frame is flagged only because of libavcodec's
/// `prev_interlaced_frame = 1` decoder-init bias (h264_slice.c, the pic_struct=3 without ct_type
/// case) is exactly the stream on which the real software path would engage the deinterlacer at
/// that same frame and latch it. Reporting "interlaced" there is not a miss, it is agreement with
/// the runtime.
enum InterlaceProbe {

    enum Verdict: Equatable {
        /// A decoded frame carried `AV_FRAME_FLAG_INTERLACED`: the declaration holds, keep software.
        case interlaced(afterFrames: Int)
        /// The sample decoded and no frame was flagged: the deinterlacer would never engage.
        case progressive(framesDecoded: Int)
        /// Too little evidence to overrule the declaration (open failed, read error, short sample).
        case inconclusive(reason: String)
    }

    /// Decoded frames that end a clean sample. ~1.5 s at 25 fps, past the first GOP on broadcast
    /// and Blu-ray GOP lengths, so a sample is never confined to one intra period.
    static let sampleFrameTarget = 40
    /// Below this the sample is not evidence; a truncated read must not hand a stream to the
    /// native path on two frames of luck.
    static let minimumFrames = 12
    /// Packet ceiling, so a stream with a long non-video packet run cannot spin here.
    static let packetBudget = 600
    /// Wall-clock ceiling for the whole sample. Expiry yields `.inconclusive`, i.e. today's routing.
    static let wallClockBudget: TimeInterval = 3.0

    /// True when the verdict is strong enough to overrule a declared interlaced field order.
    static func refutesDeclaredInterlace(_ verdict: Verdict) -> Bool {
        if case .progressive = verdict { return true }
        return false
    }

    /// Decode a sample from `demuxer`'s video stream and report whether any frame is flagged
    /// interlaced. Reads packets, so it MOVES the demuxer's read position; callers that keep
    /// using the demuxer must reposition afterwards (`AetherEngine.load` seeks back to the head).
    ///
    /// No read deadline is armed here. `AVIOReader`'s deadline state is documented demux-thread-only
    /// and the session demuxer runs with prefetch enabled, so arming it from the load path would
    /// race the prefetch thread. The packet, frame, and wall-clock budgets bound the sample instead,
    /// and a stalled read is bounded by the same reader timeout the first playback read would hit.
    static func run(
        demuxer: Demuxer,
        streamIndex: Int32,
        sampleFrameTarget: Int = InterlaceProbe.sampleFrameTarget,
        minimumFrames: Int = InterlaceProbe.minimumFrames,
        packetBudget: Int = InterlaceProbe.packetBudget,
        wallClockBudget: TimeInterval = InterlaceProbe.wallClockBudget
    ) -> Verdict {
        guard streamIndex >= 0, let stream = demuxer.stream(at: streamIndex),
              let codecpar = stream.pointee.codecpar else {
            return .inconclusive(reason: "no video stream")
        }
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            return .inconclusive(reason: "no decoder")
        }
        let ctx: UnsafeMutablePointer<AVCodecContext>
        do {
            // Software decode only: the frame flags are what is being measured, and a hwaccel surface
            // adds nothing to that. Mirrors SoftwareVideoDecoder.open's get_format rejection.
            ctx = try FFmpegDecoderContext.open(
                codec: codec, codecpar: codecpar, maxPixels: FFmpegDecoderContext.maxVideoPixels,
                options: ["hwaccel": "none"]
            ) { ctx in
                ctx.pointee.get_format = FFmpegDecoderContext.softwareOnlyGetFormat
                // The sample is thrown away, only its per-frame interlace flags are read, and deblocking
                // touches neither. Skipping it is the one cheap win that cannot change the answer.
                ctx.pointee.skip_loop_filter = AVDISCARD_ALL
                ctx.pointee.thread_count = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
                ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
            }
        } catch FFmpegDecoderContext.Failure.allocation {
            return .inconclusive(reason: "no decoder")
        } catch FFmpegDecoderContext.Failure.parameters {
            return .inconclusive(reason: "parameters_to_context failed")
        } catch FFmpegDecoderContext.Failure.open(let code) {
            return .inconclusive(reason: "decoder open failed (\(code))")
        } catch {
            return .inconclusive(reason: "decoder open failed")
        }
        var ownedCtx: UnsafeMutablePointer<AVCodecContext>? = ctx
        defer { avcodec_free_context(&ownedCtx) }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else { return .inconclusive(reason: "frame alloc failed") }
        defer { av_frame_free(&frame) }

        var framesDecoded = 0
        var packetsRead = 0
        let deadline = Date(timeIntervalSinceNow: wallClockBudget)

        /// Pull everything the decoder has; returns the frame count at which a flagged frame
        /// appeared, or nil when the drain stayed clean.
        func drain() -> Int? {
            while avcodec_receive_frame(ctx, f) >= 0 {
                framesDecoded += 1
                let flagged = (f.pointee.flags & (1 << 3)) != 0  // AV_FRAME_FLAG_INTERLACED
                av_frame_unref(f)
                if flagged { return framesDecoded }
            }
            return nil
        }

        while framesDecoded < sampleFrameTarget, packetsRead < packetBudget, Date() < deadline {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                break  // read error: whatever was decoded so far still counts, see the floor below
            }
            guard let packet else { break }  // EOF
            packetsRead += 1
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)  // demuxer allocs tracked; free must stay on the tracker
            }
            guard packet.pointee.stream_index == streamIndex else { continue }
            if avcodec_send_packet(ctx, packet) == FFmpegErr.eagain {
                if let at = drain() { return .interlaced(afterFrames: at) }
                _ = avcodec_send_packet(ctx, packet)
            }
            if let at = drain() { return .interlaced(afterFrames: at) }
        }

        // Flush: frame threading holds several frames back, and on a short sample those are a
        // meaningful part of the evidence.
        _ = avcodec_send_packet(ctx, nil)
        if let at = drain() { return .interlaced(afterFrames: at) }

        guard framesDecoded >= minimumFrames else {
            return .inconclusive(reason: "only \(framesDecoded) frame(s) decoded")
        }
        return .progressive(framesDecoded: framesDecoded)
    }
}
