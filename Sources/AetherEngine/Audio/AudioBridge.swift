import Foundation
import Libavcodec
import Libavutil
import Libswresample

/// Transcoding bridge for the HLS-fMP4 pipeline's audio sidecar. Decodes a source stream (TrueHD, DTS, DTS-HD MA,
/// Vorbis, PCM, MP2) to PCM, resamples, re-encodes in one of two modes, emits packets HLSSegmentProducer writes
/// alongside video in the same fMP4 fragments.
///
/// Motivation: AVPlayer's fMP4 path decodes AAC/AC3/EAC3 (incl. Atmos JOC)/FLAC/ALAC/MP3/Opus directly, but FFmpeg's
/// mp4 muxer can't always stream-copy EAC3 from MKV (the dec3 box needs pre-parsed extradata MKV CodecPrivate often
/// lacks -> avformat_write_header -22 EINVAL); TrueHD/DTS aren't legal in fMP4 per ISOBMFF+HLS spec. FLAC and EAC3
/// are legal and decode everywhere on Apple devices, so reroute through one.
///
/// Atmos object metadata survives neither mode (TrueHD-MAT objects interleaved in the source, FFmpeg's EAC3 encoder
/// produces no JOC, FLAC has no object channel concept). EAC3+JOC sources stay lossless via the stream-copy path
/// that bypasses this bridge; only non-stream-copyable sources enter here.
///
/// Encoder choice. Public so LoadOptions / the host pass it through; default `.surroundCompat` (soundbar /
/// LPCM-stereo-only install base is the consumer majority).
///   - `.surroundCompat`: EAC3 128 kbps/channel (256 stereo, 768 5.1), AVPlayer -> HDMI bitstream tunnel. Lossy,
///     caps at 5.1 (7.1 loses SL/SR), but surround works on essentially every AVR + soundbar including LPCM-stereo-
///     only routes (Sonos Arc, Samsung HW-Q, Bose) where FLAC falls down.
///   - `.lossless`: FLAC up to 7.1, AVPlayer -> LPCM HDMI route. Needs a multichannel-LPCM sink (Denon/Marantz/NAD);
///     a stereo-LPCM route downmixes to stereo.
public enum AudioBridgeMode: String, Sendable, CaseIterable {
    case surroundCompat
    case lossless
}

final class AudioBridge: @unchecked Sendable {

    // MARK: - Mode

    typealias Mode = AudioBridgeMode

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
            case .encoderNotFound:               return "AudioBridge: bridge encoder not registered (FFmpeg build missing --enable-encoder=flac / --enable-encoder=eac3?)"
            case .encoderAllocFailed:            return "AudioBridge: avcodec_alloc_context3 (encoder) failed"
            case .encoderOpenFailed(let c):      return "AudioBridge: encoder open failed (\(c))"
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
    /// FIFO buffering resampled PCM until >= encoderCtx.frame_size samples. FLAC's wrapper has
    /// AV_CODEC_CAP_SMALL_LAST_FRAME but not VARIABLE_FRAME_SIZE, so non-final frames must hit frame_size exactly
    /// (~4608 @48kHz); EAC3 decodes 1536 samples/packet, so without the FIFO we'd hit -22 EINVAL on the first send.
    private var fifo: OpaquePointer?

    /// Serializes the public mutators (feed/flush/startSegment/noteTimelineJump/close) against each
    /// other. On a producer restart whose old pump did not exit within the 5s budget (slow/remote
    /// source), the abandoned pump can still be inside feed() while the restart thread calls
    /// startSegment() on this otherwise lock-free bridge; concurrent libswresample/libavcodec calls on
    /// the same contexts are a data race. Uncontended in the normal single-pump case. Mirrors
    /// AudioDecoder.stateLock. Diagnostic reads (fifoSampleCount/liveBytes) stay lock-free; the engine
    /// lifecycle (restartLock ref-handoff + waitForFinish-gated cleanup) forecloses their races.
    private let opLock = NSLock()

    /// PCM intermediate format end-to-end (resampler -> FIFO -> encoder). S16 for lossy sources (EAC3/AC3);
    /// S32 @ bits_per_raw_sample=24 for lossless sources (TrueHD, DTS-HD MA, FLAC, ALAC, raw 24/32-bit PCM) so
    /// FLAC output stays bit-perfect (S16 would dither away the bottom 8 bits, audible in quiet passages).
    private let pcmSampleFmt: AVSampleFormat
    private let pcmBytesPerSample: Int32
    private let pcmBitsPerRawSample: Int32

    /// AVCodecParameters for the encoder output stream; caller hands to HLSSegmentProducer.AudioConfig.codecpar.
    /// Owned by the bridge, freed in close().
    private(set) var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>?

    /// Output stream time base (1 / sample_rate). Caller passes as StreamConfig.timeBase.
    private(set) var encoderTimeBase: AVRational = AVRational(num: 1, den: 1)

    private let srcTimeBase: AVRational
    private let mode: Mode
    private var resampledFrame: UnsafeMutablePointer<AVFrame>?

    /// Encoder PTS counter in encoder time base, incremented by nb_samples/frame. FLAC demands monotonically
    /// increasing PTS in 1/sample_rate units.
    private var nextEncoderPTS: Int64 = 0

    /// Set by startSegment, consumed on the next decoded frame: rebases nextEncoderPTS off that frame's source-TB
    /// pts so per-fragment audio PTS tracks the source. Without it the counter drifts vs video across fragments
    /// because the FIFO retains a partial frame at each segment boundary.
    private var rebaseFromNextSourcePTS: Bool = false

    private static let avNoPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1

    // MARK: - Lifecycle

    /// Opens source decoder + bridge encoder (eagerly, so encoderCodecpar is ready for muxer init). Encoder by mode:
    /// `.surroundCompat` EAC3 128 kbps/ch, max 6 ch, FLTP; `.lossless` FLAC, max 8 ch, S16 (lossy src) or S32@24
    /// (lossless src). Incomplete source codecpar (TrueHD sometimes reports sample_rate=0 pre-frame) falls back to
    /// 48 kHz stereo, which the resampler reconfigures on the first decoded frame if it differs.
    init(
        srcCodecpar: UnsafeMutablePointer<AVCodecParameters>,
        srcTimeBase: AVRational,
        mode: Mode = .surroundCompat
    ) throws {
        self.srcTimeBase = srcTimeBase
        self.mode = mode

        // 1. Source decoder
        let srcCodecID = srcCodecpar.pointee.codec_id

        // PCM intermediate format by mode: EAC3 needs FLTP; FLAC takes S16 (lossy src) or S32@24 (lossless src).
        let isLosslessSource: Bool
        switch srcCodecID {
        case AV_CODEC_ID_TRUEHD,
             AV_CODEC_ID_MLP,
             AV_CODEC_ID_DTS,
             AV_CODEC_ID_FLAC,
             AV_CODEC_ID_ALAC,
             AV_CODEC_ID_PCM_S24LE,
             AV_CODEC_ID_PCM_S24BE,
             AV_CODEC_ID_PCM_S32LE,
             AV_CODEC_ID_PCM_S32BE:
            isLosslessSource = true
        default:
            isLosslessSource = false
        }
        switch mode {
        case .surroundCompat:
            pcmSampleFmt = AV_SAMPLE_FMT_FLTP
            pcmBytesPerSample = 4
            pcmBitsPerRawSample = 32
        case .lossless:
            if isLosslessSource {
                pcmSampleFmt = AV_SAMPLE_FMT_S32
                pcmBytesPerSample = 4
                pcmBitsPerRawSample = 24
            } else {
                pcmSampleFmt = AV_SAMPLE_FMT_S16
                pcmBytesPerSample = 2
                pcmBitsPerRawSample = 16
            }
        }
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

        // 2. Bridge encoder by mode: .surroundCompat -> EAC3 128 kbps/ch max 6; .lossless -> FLAC VBR max 8.
        // bit_rate set below after channel count resolves (EAC3 scales 128 kbps x nChannels per DrHurt on
        // AetherEngine#4: 256 stereo, 768 5.1, scales if the cap is bumped per Nomis101's PR 21668). FLAC = 0 (VBR).
        let encoderCodecID: AVCodecID
        let maxEncodedChannels: Int32
        switch mode {
        case .surroundCompat:
            encoderCodecID = AV_CODEC_ID_EAC3
            maxEncodedChannels = 6
        case .lossless:
            encoderCodecID = AV_CODEC_ID_FLAC
            maxEncodedChannels = 8
        }
        guard let encCodec = avcodec_find_encoder(encoderCodecID) else {
            cleanup()
            throw AudioBridgeError.encoderNotFound
        }
        guard let enc = avcodec_alloc_context3(encCodec) else {
            cleanup()
            throw AudioBridgeError.encoderAllocFailed
        }
        encoderCtx = enc

        let sampleRate: Int32 = srcCodecpar.pointee.sample_rate > 0
            ? srcCodecpar.pointee.sample_rate
            : 48000

        // Channel count in order: (1) srcCodecpar.ch_layout (demuxer from container header, most sources);
        // (2) dec.ch_layout after avcodec_open2 (some codecs propagate a default at init); (3) stereo fallback
        // with a loud log. Matroska doesn't reliably populate Channels for TrueHD/MLP (layout is in the bitstream,
        // container header optional); when both come back 0 the bridge defaults stereo and downmixes the real
        // 5.1/7.1, which the WARNING logs as a repro (proper fix: peek the first packet before opening the encoder).
        let containerChannels = srcCodecpar.pointee.ch_layout.nb_channels
        let decoderChannels = dec.pointee.ch_layout.nb_channels
        let resolvedChannels: Int32
        let resolvedSource: String
        if containerChannels > 0 && containerChannels <= 8 {
            resolvedChannels = containerChannels
            resolvedSource = "container"
        } else if decoderChannels > 0 && decoderChannels <= 8 {
            resolvedChannels = decoderChannels
            resolvedSource = "decoder"
        } else {
            resolvedChannels = 2
            resolvedSource = "fallback (stereo)"
            EngineLog.emit(
                "[AudioBridge] WARNING: source channel layout unresolved at bridge init "
                + "(container=\(containerChannels), decoder=\(decoderChannels)); "
                + "defaulting to stereo. Surround / Atmos sources will be downmixed. "
                + "Codec: \(srcCodecID.rawValue). Need to peek first packet to fix.",
                category: .session
            )
        }
        // Cap to encoder max (EAC3 5.1, FLAC 7.1). Above-cap downmix happens automatically inside swr_convert
        // when source layout exceeds the encoder's; the resampler picks Apple-compatible ordering.
        let nChannels: Int32 = min(resolvedChannels, maxEncodedChannels)
        let logBitRate: String = mode == .surroundCompat
            ? "\(Int64(nChannels) * 128) kbps"
            : "VBR"
        EngineLog.emit(
            "[AudioBridge] init: mode=\(mode.rawValue) "
            + "srcCodec=\(srcCodecID.rawValue) sampleRate=\(sampleRate) "
            + "sourceChannels=\(resolvedChannels) "
            + "encoderChannels=\(nChannels) bitRate=\(logBitRate) "
            + "(source=\(resolvedSource), container=\(containerChannels), decoder=\(decoderChannels))",
            category: .session
        )

        enc.pointee.sample_rate = sampleRate
        enc.pointee.sample_fmt = pcmSampleFmt
        enc.pointee.bits_per_raw_sample = pcmBitsPerRawSample
        // EAC3 per-channel bitrate 128 kbps (Dolby reference transparent profile); FLAC stays 0 = unlimited VBR.
        let resolvedBitRate: Int64
        switch mode {
        case .surroundCompat:
            resolvedBitRate = Int64(nChannels) * 128_000
        case .lossless:
            resolvedBitRate = 0
        }
        enc.pointee.bit_rate = resolvedBitRate
        enc.pointee.time_base = AVRational(num: 1, den: sampleRate)
        var encLayout = AVChannelLayout()
        av_channel_layout_default(&encLayout, nChannels)
        let layoutCopyRet = av_channel_layout_copy(&enc.pointee.ch_layout, &encLayout)
        if layoutCopyRet < 0 {
            cleanup()
            throw AudioBridgeError.encoderOpenFailed(code: layoutCopyRet)
        }
        let encOpenRet = avcodec_open2(enc, encCodec, nil)
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

        // 4. Resampler input format: decoder ctx sample_fmt if populated (most lossy codecs fill it at open),
        //    else seed FLTP for codecs that defer until the first frame (TrueHD); resampler reconfigures on feed.
        let inFmtRaw = dec.pointee.sample_fmt.rawValue
        let inFmt = inFmtRaw >= 0 ? dec.pointee.sample_fmt : AV_SAMPLE_FMT_FLTP
        let inRate = dec.pointee.sample_rate > 0 ? dec.pointee.sample_rate : sampleRate
        var inLayout = AVChannelLayout()
        if dec.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &dec.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, nChannels)
        }
        // copy() allocates a channel map for custom-order layouts; uninit the stack struct or that map leaks per session.
        defer { av_channel_layout_uninit(&inLayout) }

        let swrRet = swr_alloc_set_opts2(
            &swrCtx,
            &enc.pointee.ch_layout,
            pcmSampleFmt,
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

        // 5. Audio FIFO: ~1s of PCM (FFmpeg grows on demand), chunks resampler output into encoder-sized frames.
        guard let fifoPtr = av_audio_fifo_alloc(
            pcmSampleFmt,
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
        opLock.lock()
        defer { opLock.unlock() }
        cleanup()
    }

    /// FIFO depth in samples/channel, for the engine memory probe. Steady-state below frame_size (~4608 @48kHz);
    /// a growing value means the encoder isn't keeping up with the resampler.
    var fifoSampleCount: Int {
        guard let f = fifo else { return 0 }
        return Int(av_audio_fifo_size(f))
    }

    /// Snapshot of bytes live in the bridge's growable buffers, for the engine memory probe. Both fields grow on
    /// the FFmpeg side (FIFO reallocs upward, swr delay buffer reallocates on rate/layout shift), so a
    /// monotonically rising value points here vs the segment muxer or HLS server. Costs: two C calls, no allocations.
    struct LiveBytes {
        /// Samples currently in the FIFO (per channel).
        let fifoSamples: Int
        /// FIFO bytes in interleaved PCM (samples * channels * bytesPerSample).
        let fifoBytes: Int
        /// Samples the resampler is buffering internally, in encoder sample-rate units.
        let swrDelaySamples: Int
        /// Approx swr delay-buffer bytes (swrDelaySamples * channels * bytesPerSample); fine proxy for a growth trend.
        let swrDelayBytes: Int

        var totalBytes: Int { fifoBytes + swrDelayBytes }
    }

    var liveBytes: LiveBytes {
        let fifoSamples: Int
        if let f = fifo {
            fifoSamples = Int(av_audio_fifo_size(f))
        } else {
            fifoSamples = 0
        }

        let channels: Int
        let bytesPerSample: Int = Int(pcmBytesPerSample)
        if let enc = encoderCtx {
            channels = Int(enc.pointee.ch_layout.nb_channels)
        } else {
            channels = 0
        }

        let fifoBytes = fifoSamples * channels * bytesPerSample

        let swrDelaySamples: Int
        if let swr = swrCtx, let enc = encoderCtx {
            swrDelaySamples = Int(swr_get_delay(swr, Int64(enc.pointee.sample_rate)))
        } else {
            swrDelaySamples = 0
        }
        let swrDelayBytes = swrDelaySamples * channels * bytesPerSample

        return LiveBytes(
            fifoSamples: fifoSamples,
            fifoBytes: fifoBytes,
            swrDelaySamples: swrDelaySamples,
            swrDelayBytes: swrDelayBytes
        )
    }

    /// Mark a fragment boundary: drain the FIFO (drops the buffered partial frame, max ~96 ms @48kHz) and rebase
    /// encoder PTS off the next decoded frame's pts. Caller (VideoSegmentProvider) invokes before each fragment's
    /// audio so A/V timestamps stay aligned across muxer fragment boundaries.
    func startSegment() {
        opLock.lock()
        defer { opLock.unlock() }
        if let f = fifo {
            av_audio_fifo_reset(f)
        }
        // Drop decoder reference frames + resampler delay buffer too: after a backward scrub they hold pre-restart
        // samples that would bleed a few ms of old-position audio into the new position (and a stale decoder frame
        // could surface as garbage on the rebased timeline). swr_init on a configured context re-inits in place,
        // clearing fractional-delay state.
        if let dec = decoderCtx {
            avcodec_flush_buffers(dec)
        }
        if let swr = swrCtx {
            _ = swr_init(swr)
        }
        rebaseFromNextSourcePTS = true
    }

    /// Drain everything buffered at source EOF: remaining decoder frames, FIFO leftover (< one encoder frame),
    /// encoder internal delay. Without this the final ~100-200 ms of every VOD title were dropped (feed's FIFO
    /// drain only emits FULL frames and nothing sent the encoder its EOF frame). Returns the tail packets; caller
    /// writes them via the same muxer path. Call once at pump EOF before muxer finalize. Not meaningful for live.
    func flush() -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard let dec = decoderCtx, let enc = encoderCtx,
              let swr = swrCtx, let fifoPtr = fifo else { return [] }
        var results: [UnsafeMutablePointer<AVPacket>] = []

        // 1. Drain the decoder's internal delay.
        _ = avcodec_send_packet(dec, nil)
        var srcFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&srcFrame) }
        if let sf = srcFrame {
            while avcodec_receive_frame(dec, sf) >= 0 {
                try? resampleAndPushIntoFIFO(srcFrame: sf, enc: enc, swr: swr, fifo: fifoPtr)
            }
        }

        // 2. Encode the FIFO remainder, including the final partial
        //    frame (requireFull: false pads/short-frames it).
        try? drainFIFOIntoEncoder(enc: enc, fifo: fifoPtr, requireFull: false, results: &results)

        // 3. Flush the encoder's internal delay.
        _ = avcodec_send_frame(enc, nil)
        while true {
            guard let outPkt = trackedPacketAlloc() else { break }
            let recvRet = avcodec_receive_packet(enc, outPkt)
            guard recvRet >= 0 else {
                var p: UnsafeMutablePointer<AVPacket>? = outPkt
                trackedPacketFree(&p)
                break
            }
            results.append(outPkt)
        }
        if !results.isEmpty {
            EngineLog.emit(
                "[AudioBridge] EOF flush emitted \(results.count) tail packet(s)",
                category: .session
            )
        }
        return results
    }

    /// Live program-boundary correction. The free-running nextEncoderPTS counter collapses any audio splice gap
    /// sample-continuously while video keeps the rebase-preserved gap. Producer calls this with the residual
    /// (audio gap minus video gap, seconds): positive deltas advance the PTS (AVPlayer renders silence), negative
    /// (splice overlap) are clamped, the counter never rewinds. Called on the pump thread (same as feed). FIFO
    /// leftover (< one frame) is stamped post-jump; that error is one-shot, bounded by one frame (~32 ms).
    func noteTimelineJump(deltaSeconds: Double) {
        opLock.lock()
        defer { opLock.unlock() }
        guard deltaSeconds > 0, encoderTimeBase.den > 0 else { return }
        let samples = Int64((deltaSeconds * Double(encoderTimeBase.den)).rounded())
        nextEncoderPTS += samples
        EngineLog.emit(
            "[AudioBridge] live timeline jump: +\(String(format: "%.3f", deltaSeconds))s "
            + "(\(samples) samples) at encoder pts \(nextEncoderPTS)",
            category: .session
        )
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

    /// Decode one source packet, resample, buffer, encode. Returns 0+ encoded packets, ownership transferred to
    /// the caller (must av_packet_free after muxing). PTS is in encoderTimeBase units; the muxer rescales during writePacket.
    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard let dec = decoderCtx,
              let enc = encoderCtx,
              let swr = swrCtx,
              let fifoPtr = fifo else {
            return []
        }

        var results: [UnsafeMutablePointer<AVPacket>] = []

        // Capture packet.pts for the encoder-PTS rebase, NOT the decoded frame's pts. Issue #7: for codecs with
        // decoder priming (Opus preskip ~312 samples @48kHz, AAC delay), libavcodec's discard-samples path trims
        // the first frame AND advances frame.pts by the same amount; rebasing off that would forward-shift FLAC
        // by preskip-count, opening the audio gate ahead of video and stalling AVPlayer in waitingToPlay.
        // packet.pts is the source position of the encoded packet (preskip + content), so it keeps FLAC aligned
        // with source-PTS=packet.pts like the video segments regardless of auto-trim.
        let packetPts = packet.pointee.pts

        var srcFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&srcFrame) }
        guard let sf = srcFrame else { return results }

        // Drain every decodable frame into the FIFO. The PTS rebase fires on the first frame after a segment
        // boundary so FLAC timestamps track the source rather than drifting on FIFO leftover (uses packetPts, not sf.pts).
        func receiveDecodedFrames() throws {
            while avcodec_receive_frame(dec, sf) >= 0 {
                if rebaseFromNextSourcePTS, packetPts != Self.avNoPTS {
                    nextEncoderPTS = av_rescale_q(packetPts, srcTimeBase, encoderTimeBase)
                    rebaseFromNextSourcePTS = false
                }
                try resampleAndPushIntoFIFO(srcFrame: sf, enc: enc, swr: swr, fifo: fifoPtr)
            }
        }

        var sendRet = avcodec_send_packet(dec, packet)
        if sendRet == FFmpegErr.eagain {
            // EAGAIN = decoder output queue full (multi-frame packets, e.g. TrueHD bursts): receive frames first,
            // then retry the send. (Old code lumped EAGAIN with real errors and dropped the packet.)
            try receiveDecodedFrames()
            sendRet = avcodec_send_packet(dec, packet)
        }
        if sendRet == FFmpegErr.invalidData {
            // Corrupt source packet (glitchy live MPEG-TS, broken mp2 header). Decoder stays usable, so skip
            // rather than throw (per-packet throwing floods the caller hundreds/sec on a persistently bad feed).
            return results
        }
        if sendRet < 0 && sendRet != FFmpegErr.eof {
            throw AudioBridgeError.sendPacketFailed(code: sendRet)
        }

        try receiveDecodedFrames()

        // Drain the FIFO into encoder-frame-size chunks, each fed as one AVFrame.
        // The helper may append encoded packets before throwing; feed propagates the error (the
        // caller logs and continues, holding no reference), so free the partial results here or
        // they leak. flush() intentionally keeps its partial results via try?, so this cleanup
        // lives in feed(), not in the shared helper.
        do {
            try drainFIFOIntoEncoder(enc: enc, fifo: fifoPtr, requireFull: true, results: &results)
        } catch {
            for p in results {
                var pp: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&pp)
            }
            throw error
        }

        return results
    }

    /// Resample sf (decoded source frame) to encoder format and push into the FIFO (swr_convert may produce
    /// more/fewer samples; the FIFO smooths that). Buffer layout by pcmSampleFmt: interleaved (S16/S32, FLAC mode)
    /// is one contiguous buffer in out[0]; planar (FLTP, EAC3 mode) is N pointers, one per channel. Passing a
    /// single pointer for planar would have the encoder read garbage from N-1 unallocated slots (EXC_BAD_ACCESS in swr_convert).
    private func resampleAndPushIntoFIFO(
        srcFrame sf: UnsafeMutablePointer<AVFrame>,
        enc: UnsafeMutablePointer<AVCodecContext>,
        swr: OpaquePointer,
        fifo: OpaquePointer
    ) throws {
        let outNbSamples = swr_get_out_samples(swr, sf.pointee.nb_samples)
        guard outNbSamples > 0 else { return }

        // Corrupt source audio (glitchy live MPEG-TS, mp2 with missing frame headers) can decode to a frame with
        // nb_samples > 0 but a NULL channel pointer in extended_data; swr_convert then derefs NULL and crashes
        // EXC_BAD_ACCESS at 0x0. Skip such frames (the video path tolerates the same corruption).
        guard sf.pointee.nb_samples > 0,
              let ext = sf.pointee.extended_data,
              ext.pointee != nil else { return }

        let nChannels = enc.pointee.ch_layout.nb_channels
        let isPlanar = av_sample_fmt_is_planar(pcmSampleFmt) != 0
        let bufferCount = isPlanar ? Int(nChannels) : 1
        let bytesPerBuffer = isPlanar
            ? Int(outNbSamples) * Int(pcmBytesPerSample)
            : Int(outNbSamples) * Int(nChannels) * Int(pcmBytesPerSample)

        // Allocate N (planar) or 1 (interleaved) buffer(s).
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        buffers.reserveCapacity(bufferCount)
        for _ in 0..<bufferCount {
            buffers.append(UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerBuffer))
        }
        defer { for b in buffers { b.deallocate() } }

        // Pointer array for swr_convert + FIFO write: single element interleaved, one per channel planar.
        var outPtrs: [UnsafeMutablePointer<UInt8>?] = buffers.map { $0 }
        let producedSamples = outPtrs.withUnsafeMutableBufferPointer { outBuf in
            withUnsafeMutablePointer(to: &sf.pointee.extended_data) { srcPtr in
                let srcReadOnly = UnsafeRawPointer(srcPtr.pointee)
                    .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return swr_convert(
                    swr,
                    outBuf.baseAddress,
                    outNbSamples,
                    srcReadOnly,
                    sf.pointee.nb_samples
                )
            }
        }
        guard producedSamples > 0 else { return }

        // av_audio_fifo_write takes void **data; the same array works for both layouts (FIFO knows the format).
        _ = outPtrs.withUnsafeMutableBufferPointer { fifoBuf in
            fifoBuf.baseAddress!.withMemoryRebound(
                to: UnsafeMutableRawPointer?.self, capacity: bufferCount
            ) { rebound in
                av_audio_fifo_write(fifo, rebound, producedSamples)
            }
        }
    }

    /// Pull frame_size chunks from the FIFO and encode each. requireFull true stops below frame_size (streaming);
    /// false emits a final short frame for the leftover (flush).
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

            // Pull chunkSize samples into a fresh AVFrame the encoder consumes.
            var outFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&outFrame) }
            guard let of = outFrame else { break }
            of.pointee.format = pcmSampleFmt.rawValue
            of.pointee.nb_samples = chunkSize
            of.pointee.sample_rate = enc.pointee.sample_rate
            av_channel_layout_copy(&of.pointee.ch_layout, &enc.pointee.ch_layout)
            let allocRet = av_frame_get_buffer(of, 0)
            if allocRet < 0 { break }

            // FIFO read into the frame's data planes: interleaved uses data[0], planar uses data[0..N-1]
            // (data[] suffices since EAC3 caps 6 / FLAC 8 ch, below the 8-plane extended_data threshold).
            // av_audio_fifo_read takes void **data and respects the FIFO's format to fan out or not.
            let isPlanar = av_sample_fmt_is_planar(pcmSampleFmt) != 0
            let planes = isPlanar ? Int(nChannels) : 1
            let readSamples = withUnsafeMutablePointer(to: &of.pointee.data) { dataPtr in
                dataPtr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: planes) { rebound in
                    av_audio_fifo_read(fifo, rebound, chunkSize)
                }
            }
            if readSamples <= 0 { break }
            of.pointee.nb_samples = readSamples
            of.pointee.pts = nextEncoderPTS
            nextEncoderPTS += Int64(readSamples)

            let sendFrameRet = avcodec_send_frame(enc, of)
            if sendFrameRet < 0 && sendFrameRet != FFmpegErr.eof {
                throw AudioBridgeError.sendFrameFailed(code: sendFrameRet)
            }

            // Drain the encoder for ready packets.
            while true {
                guard let outPkt = trackedPacketAlloc() else { break }
                let recvRet = avcodec_receive_packet(enc, outPkt)
                if recvRet == FFmpegErr.eagain || recvRet == FFmpegErr.eof {
                    var p: UnsafeMutablePointer<AVPacket>? = outPkt
                    trackedPacketFree(&p)
                    break
                }
                if recvRet < 0 {
                    var p: UnsafeMutablePointer<AVPacket>? = outPkt
                    trackedPacketFree(&p)
                    break
                }
                results.append(outPkt)
            }
        }
    }
}

