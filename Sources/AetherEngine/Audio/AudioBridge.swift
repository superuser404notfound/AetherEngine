import Foundation
import Libavcodec
import Libavutil
import Libswresample

/// Source-to-FLAC transcoding bridge for the HLS-fMP4 video pipeline's
/// audio sidecar. Decodes a source audio stream (EAC3, TrueHD, DTS,
/// DTS-HD MA) to PCM, resamples to S16, re-encodes losslessly as FLAC,
/// and emits encoded FLAC packets the FMP4VideoMuxer can stream-copy
/// into the same fragments as the HEVC video.
///
/// The motivation: AVPlayer's fMP4 decode path supports AAC / AC3 /
/// EAC3 (incl. Atmos JOC) / FLAC / ALAC / MP3 / Opus directly, but
/// FFmpeg's mp4 muxer can't always stream-copy EAC3 from MKV (the
/// `dec3` box bytes need pre-parsed extradata that MKV CodecPrivate
/// often doesn't carry, leading to `avformat_write_header` returning
/// -22 EINVAL). TrueHD and DTS aren't legal in fMP4 at all per the
/// ISOBMFF + Apple HLS spec. FLAC is legal, decodes everywhere on
/// Apple devices, and is lossless from PCM, so we reroute through it.
///
/// Trade-off: the EAC3-with-Atmos-JOC stream-copy path preserves the
/// JOC metadata for Atmos-capable receivers, but this bridge produces
/// 5.1 / 7.1 PCM-derived FLAC, losing the spatial mix. Caller decides
/// whether to bridge eagerly (TrueHD / DTS, which have no other
/// option) or lazy after a stream-copy attempt (EAC3, where we want
/// to keep Atmos when the muxer accepts it).
final class AudioBridge: @unchecked Sendable {

    // MARK: - Errors

    enum AudioBridgeError: Error, CustomStringConvertible {
        case decoderNotFound(codecID: UInt32)
        case decoderAllocFailed
        case decoderParametersFailed(code: Int32)
        case decoderOpenFailed(code: Int32)
        case encoderNotFound
        case encoderAllocFailed
        case encoderOpenFailed(code: Int32)
        case codecparAllocFailed
        case resamplerAllocFailed(code: Int32)
        case resamplerInitFailed(code: Int32)
        case sendPacketFailed(code: Int32)
        case sendFrameFailed(code: Int32)

        var description: String {
            switch self {
            case .decoderNotFound(let id):       return "AudioBridge: no FFmpeg decoder for source codec id \(id)"
            case .decoderAllocFailed:            return "AudioBridge: avcodec_alloc_context3 (decoder) failed"
            case .decoderParametersFailed(let c): return "AudioBridge: avcodec_parameters_to_context returned \(c)"
            case .decoderOpenFailed(let c):      return "AudioBridge: source decoder open failed (\(c))"
            case .encoderNotFound:               return "AudioBridge: FLAC encoder not registered (FFmpeg build missing --enable-encoder=flac?)"
            case .encoderAllocFailed:            return "AudioBridge: avcodec_alloc_context3 (FLAC encoder) failed"
            case .encoderOpenFailed(let c):      return "AudioBridge: FLAC encoder open failed (\(c))"
            case .codecparAllocFailed:           return "AudioBridge: avcodec_parameters_alloc failed"
            case .resamplerAllocFailed(let c):   return "AudioBridge: swr_alloc_set_opts2 returned \(c)"
            case .resamplerInitFailed(let c):    return "AudioBridge: swr_init returned \(c)"
            case .sendPacketFailed(let c):       return "AudioBridge: avcodec_send_packet (decoder) returned \(c)"
            case .sendFrameFailed(let c):        return "AudioBridge: avcodec_send_frame (encoder) returned \(c)"
            }
        }
    }

    // MARK: - State

    private var decoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var encoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swrCtx: OpaquePointer?
    /// Audio FIFO that buffers resampled S16 PCM until we have at
    /// least `encoderCtx.frame_size` samples to feed the encoder.
    /// FLAC's libavcodec wrapper has `AV_CODEC_CAP_SMALL_LAST_FRAME`
    /// but not `AV_CODEC_CAP_VARIABLE_FRAME_SIZE`, so non-final
    /// frames must hit `frame_size` exactly (typically 4608 at
    /// 48 kHz). EAC3 packets decode to 1536 samples each so we'd
    /// otherwise hit `-22 EINVAL` on the first send.
    private var fifo: OpaquePointer?

    /// AVCodecParameters describing the FLAC output stream. Caller
    /// hands this to `FMP4VideoMuxer` as the audio `StreamConfig`.
    /// Owned by the bridge; freed in `close()`.
    private(set) var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>?

    /// Time base of the FLAC output stream (1 / sample_rate). Caller
    /// passes this as `StreamConfig.timeBase`.
    private(set) var encoderTimeBase: AVRational = AVRational(num: 1, den: 1)

    private let srcTimeBase: AVRational
    private var resampledFrame: UnsafeMutablePointer<AVFrame>?

    /// PTS counter for the encoder, in encoder time base. Incremented
    /// by `nb_samples` per encoded frame. FLAC encoder demands
    /// monotonically increasing PTS in 1/sample_rate units.
    private var nextEncoderPTS: Int64 = 0

    /// Set by `startSegment`, consumed on the next decoded source
    /// frame: pulls that frame's pts out of source time base and
    /// rebases `nextEncoderPTS` from it so per-fragment audio PTS
    /// tracks the source. Without this the FLAC PTS counter would
    /// drift relative to video across fragments because the FIFO
    /// retains a partial frame at each segment boundary.
    private var rebaseFromNextSourcePTS: Bool = false

    private static let avNoPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1

    // MARK: - Lifecycle

    /// Opens the source decoder + FLAC encoder. Encoder is opened
    /// eagerly using `srcCodecpar.sample_rate` and `ch_layout` so the
    /// resulting `encoderCodecpar` is available immediately for muxer
    /// init. If the source's codecpar is incomplete (TrueHD sometimes
    /// reports `sample_rate=0` until the first frame), we fall back to
    /// 48 kHz stereo, which the resampler will reconfigure on the
    /// first decoded frame if it differs.
    init(srcCodecpar: UnsafeMutablePointer<AVCodecParameters>, srcTimeBase: AVRational) throws {
        self.srcTimeBase = srcTimeBase

        // 1. Source decoder
        let srcCodecID = srcCodecpar.pointee.codec_id
        guard let srcCodec = avcodec_find_decoder(srcCodecID) else {
            throw AudioBridgeError.decoderNotFound(codecID: srcCodecID.rawValue)
        }
        guard let dec = avcodec_alloc_context3(srcCodec) else {
            throw AudioBridgeError.decoderAllocFailed
        }
        decoderCtx = dec
        let copyRet = avcodec_parameters_to_context(dec, srcCodecpar)
        guard copyRet >= 0 else {
            cleanup()
            throw AudioBridgeError.decoderParametersFailed(code: copyRet)
        }
        let openRet = avcodec_open2(dec, srcCodec, nil)
        guard openRet >= 0 else {
            cleanup()
            throw AudioBridgeError.decoderOpenFailed(code: openRet)
        }

        // 2. FLAC encoder. We pull the requested sample rate / channel
        //    layout from the source codecpar (with safe defaults), and
        //    fix the encoder's input sample format at S16 because FLAC
        //    accepts only S16 / S32 and S16 is enough for AVPlayer's
        //    audio decode path. `bit_rate=0` is the FLAC encoder's
        //    "no rate cap" signal (FLAC is variable-bitrate / lossless).
        guard let flacCodec = avcodec_find_encoder(AV_CODEC_ID_FLAC) else {
            cleanup()
            throw AudioBridgeError.encoderNotFound
        }
        guard let enc = avcodec_alloc_context3(flacCodec) else {
            cleanup()
            throw AudioBridgeError.encoderAllocFailed
        }
        encoderCtx = enc

        let sampleRate: Int32 = srcCodecpar.pointee.sample_rate > 0
            ? srcCodecpar.pointee.sample_rate
            : 48000
        let nChannels: Int32 = (srcCodecpar.pointee.ch_layout.nb_channels > 0
                                && srcCodecpar.pointee.ch_layout.nb_channels <= 8)
            ? srcCodecpar.pointee.ch_layout.nb_channels
            : 2

        enc.pointee.sample_rate = sampleRate
        enc.pointee.sample_fmt = AV_SAMPLE_FMT_S16
        enc.pointee.bit_rate = 0
        enc.pointee.time_base = AVRational(num: 1, den: sampleRate)
        var encLayout = AVChannelLayout()
        av_channel_layout_default(&encLayout, nChannels)
        let layoutCopyRet = av_channel_layout_copy(&enc.pointee.ch_layout, &encLayout)
        if layoutCopyRet < 0 {
            cleanup()
            throw AudioBridgeError.encoderOpenFailed(code: layoutCopyRet)
        }
        let encOpenRet = avcodec_open2(enc, flacCodec, nil)
        guard encOpenRet >= 0 else {
            cleanup()
            throw AudioBridgeError.encoderOpenFailed(code: encOpenRet)
        }
        encoderTimeBase = AVRational(num: 1, den: sampleRate)

        // 3. Codecpar describing the FLAC output for the muxer.
        guard let cp = avcodec_parameters_alloc() else {
            cleanup()
            throw AudioBridgeError.codecparAllocFailed
        }
        encoderCodecpar = cp
        let fillRet = avcodec_parameters_from_context(cp, enc)
        if fillRet < 0 {
            cleanup()
            throw AudioBridgeError.encoderOpenFailed(code: fillRet)
        }

        // 4. Resampler input format: prefer the decoder context's
        //    sample_fmt if it's already populated (most lossy codecs
        //    fill it during avcodec_open2). For codecs that defer
        //    until the first decoded frame (TrueHD), seed with FLTP
        //    and the resampler reconfigures on first feed if the real
        //    layout differs.
        let inFmtRaw = dec.pointee.sample_fmt.rawValue
        let inFmt = inFmtRaw >= 0 ? dec.pointee.sample_fmt : AV_SAMPLE_FMT_FLTP
        let inRate = dec.pointee.sample_rate > 0 ? dec.pointee.sample_rate : sampleRate
        var inLayout = AVChannelLayout()
        if dec.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &dec.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, nChannels)
        }

        let swrRet = swr_alloc_set_opts2(
            &swrCtx,
            &enc.pointee.ch_layout,
            AV_SAMPLE_FMT_S16,
            sampleRate,
            &inLayout,
            inFmt,
            inRate,
            0,
            nil
        )
        guard swrRet >= 0, swrCtx != nil else {
            cleanup()
            throw AudioBridgeError.resamplerAllocFailed(code: swrRet)
        }
        let initRet = swr_init(swrCtx)
        guard initRet >= 0 else {
            cleanup()
            throw AudioBridgeError.resamplerInitFailed(code: initRet)
        }

        // 5. Audio FIFO: buffer up to one second of S16 samples by
        //    default (FFmpeg grows it on demand if we exceed). Used
        //    to chunk the resampler's output into encoder-sized
        //    frames.
        guard let fifoPtr = av_audio_fifo_alloc(
            AV_SAMPLE_FMT_S16,
            nChannels,
            sampleRate
        ) else {
            cleanup()
            throw AudioBridgeError.encoderAllocFailed
        }
        fifo = fifoPtr
    }

    deinit {
        cleanup()
    }

    func close() {
        cleanup()
    }

    /// Mark a fragment boundary. Drains the FIFO (drops the partial
    /// frame's worth of samples that was buffered for the next
    /// encoder packet, max ~96 ms at 48 kHz), and rebases the
    /// encoder PTS off the next decoded source frame's pts. Caller
    /// (VideoSegmentProvider) invokes this before feeding audio
    /// packets for each fragment so audio and video timestamps stay
    /// aligned across the muxer's fragment boundaries.
    func startSegment() {
        if let f = fifo {
            av_audio_fifo_reset(f)
        }
        rebaseFromNextSourcePTS = true
    }

    private func cleanup() {
        if decoderCtx != nil {
            avcodec_free_context(&decoderCtx)
        }
        if encoderCtx != nil {
            avcodec_free_context(&encoderCtx)
        }
        if swrCtx != nil {
            swr_free(&swrCtx)
        }
        if encoderCodecpar != nil {
            avcodec_parameters_free(&encoderCodecpar)
        }
        if resampledFrame != nil {
            av_frame_free(&resampledFrame)
        }
        if let f = fifo {
            av_audio_fifo_free(f)
            fifo = nil
        }
    }

    // MARK: - Feed

    /// Decode one source audio packet, resample, buffer, encode to
    /// FLAC. Returns zero or more newly-encoded FLAC packets,
    /// ownership transferred to the caller (caller must
    /// `av_packet_free` after muxing). PTS on each FLAC packet is in
    /// `encoderTimeBase` units; the muxer rescales during
    /// `writePacket`.
    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        guard let dec = decoderCtx,
              let enc = encoderCtx,
              let swr = swrCtx,
              let fifoPtr = fifo else {
            return []
        }

        var results: [UnsafeMutablePointer<AVPacket>] = []

        let sendRet = avcodec_send_packet(dec, packet)
        if sendRet < 0 && sendRet != AVERROR_EOF_VALUE {
            throw AudioBridgeError.sendPacketFailed(code: sendRet)
        }

        var srcFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&srcFrame) }
        guard let sf = srcFrame else { return results }

        while avcodec_receive_frame(dec, sf) >= 0 {
            // Rebase encoder PTS off the first decoded frame after a
            // segment boundary so the FLAC stream timestamps track
            // the source rather than drifting on the FIFO leftover.
            if rebaseFromNextSourcePTS, sf.pointee.pts != Self.avNoPTS {
                nextEncoderPTS = av_rescale_q(sf.pointee.pts, srcTimeBase, encoderTimeBase)
                rebaseFromNextSourcePTS = false
            }
            try resampleAndPushIntoFIFO(srcFrame: sf, enc: enc, swr: swr, fifo: fifoPtr)
        }

        // Drain the FIFO into encoder-frame-size chunks. Each chunk
        // becomes one AVFrame fed to the encoder.
        try drainFIFOIntoEncoder(enc: enc, fifo: fifoPtr, requireFull: true, results: &results)

        return results
    }

    /// Pull S16 samples out of `sf` (decoded source frame), resample
    /// to encoder format, and push into the FIFO. `swr_convert` can
    /// produce more or fewer samples than the input frame contained,
    /// the FIFO smooths that out.
    private func resampleAndPushIntoFIFO(
        srcFrame sf: UnsafeMutablePointer<AVFrame>,
        enc: UnsafeMutablePointer<AVCodecContext>,
        swr: OpaquePointer,
        fifo: OpaquePointer
    ) throws {
        let outNbSamples = swr_get_out_samples(swr, sf.pointee.nb_samples)
        guard outNbSamples > 0 else { return }

        let nChannels = enc.pointee.ch_layout.nb_channels
        let bytesPerSample: Int32 = 2  // S16
        let bufferBytes = Int(outNbSamples * nChannels * bytesPerSample)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferBytes)
        defer { buffer.deallocate() }

        // S16 (interleaved): swr_convert wants `uint8_t **out` where
        // out[0] points at the interleaved sample buffer.
        var outPtr: UnsafeMutablePointer<UInt8>? = buffer
        let producedSamples = withUnsafeMutablePointer(to: &outPtr) { outBufPtr in
            withUnsafeMutablePointer(to: &sf.pointee.extended_data) { srcPtr in
                let srcReadOnly = UnsafeRawPointer(srcPtr.pointee)
                    .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return swr_convert(
                    swr,
                    outBufPtr,
                    outNbSamples,
                    srcReadOnly,
                    sf.pointee.nb_samples
                )
            }
        }
        guard producedSamples > 0 else { return }

        // Push into FIFO. av_audio_fifo_write takes `void **data`,
        // for non-planar formats only data[0] is read.
        var fifoData: UnsafeMutablePointer<UInt8>? = buffer
        _ = withUnsafeMutablePointer(to: &fifoData) { ptr in
            ptr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) { rebound in
                av_audio_fifo_write(fifo, rebound, producedSamples)
            }
        }
    }

    /// Pull `frame_size` chunks out of the FIFO and encode each. When
    /// `requireFull` is true, stops once the FIFO has fewer than
    /// `frame_size` samples (used during streaming). When false, also
    /// emits a final short frame for the leftover (used during flush).
    private func drainFIFOIntoEncoder(
        enc: UnsafeMutablePointer<AVCodecContext>,
        fifo: OpaquePointer,
        requireFull: Bool,
        results: inout [UnsafeMutablePointer<AVPacket>]
    ) throws {
        let frameSize = enc.pointee.frame_size > 0 ? enc.pointee.frame_size : 4096
        let nChannels = enc.pointee.ch_layout.nb_channels

        while true {
            let available = av_audio_fifo_size(fifo)
            let chunkSize: Int32
            if available >= frameSize {
                chunkSize = frameSize
            } else if !requireFull && available > 0 {
                chunkSize = available
            } else {
                break
            }

            // Pull `chunkSize` samples out of the FIFO into a fresh
            // AVFrame whose buffer the encoder will consume.
            var outFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&outFrame) }
            guard let of = outFrame else { break }
            of.pointee.format = AV_SAMPLE_FMT_S16.rawValue
            of.pointee.nb_samples = chunkSize
            of.pointee.sample_rate = enc.pointee.sample_rate
            av_channel_layout_copy(&of.pointee.ch_layout, &enc.pointee.ch_layout)
            let allocRet = av_frame_get_buffer(of, 0)
            if allocRet < 0 { break }

            // FIFO read into of.data[0] (S16 interleaved is non-planar).
            let readSamples = withUnsafeMutablePointer(to: &of.pointee.data) { dataPtr in
                dataPtr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) { rebound in
                    av_audio_fifo_read(fifo, rebound, chunkSize)
                }
            }
            if readSamples <= 0 { break }
            of.pointee.nb_samples = readSamples
            of.pointee.pts = nextEncoderPTS
            nextEncoderPTS += Int64(readSamples)
            _ = nChannels

            let sendFrameRet = avcodec_send_frame(enc, of)
            if sendFrameRet < 0 && sendFrameRet != AVERROR_EOF_VALUE {
                throw AudioBridgeError.sendFrameFailed(code: sendFrameRet)
            }

            // Drain encoder for any packets ready to emit.
            while true {
                guard let outPkt = av_packet_alloc() else { break }
                let recvRet = avcodec_receive_packet(enc, outPkt)
                if recvRet == AVERROR_EAGAIN_VALUE || recvRet == AVERROR_EOF_VALUE {
                    var p: UnsafeMutablePointer<AVPacket>? = outPkt
                    av_packet_free(&p)
                    break
                }
                if recvRet < 0 {
                    var p: UnsafeMutablePointer<AVPacket>? = outPkt
                    av_packet_free(&p)
                    break
                }
                results.append(outPkt)
            }
        }
    }
}

/// `AVERROR(EAGAIN)` and `AVERROR_EOF` are macros Swift can't import,
/// so we rederive them. EAGAIN is POSIX 35 on Apple platforms, and
/// FFmpeg's macro is `-(35)` after the FFERRTAG transform; but in
/// practice the constant FFmpeg returns is the negated POSIX value
/// for EAGAIN and a tagged sentinel for EOF.
private let AVERROR_EAGAIN_VALUE: Int32 = -35
private let AVERROR_EOF_VALUE: Int32 = -0x20464F45  // FFERRTAG('E','O','F',' ')
