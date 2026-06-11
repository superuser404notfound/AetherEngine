import Foundation
import Libavcodec
import Libavutil
import Libswresample

/// Source-to-mux-friendly transcoding bridge for the HLS-fMP4 video
/// pipeline's audio sidecar. Decodes a source audio stream (TrueHD,
/// DTS, DTS-HD MA, Vorbis, PCM, MP2) to PCM, resamples, re-encodes
/// in one of two modes the caller picks, and emits encoded audio
/// packets the `HLSSegmentProducer` writes alongside the video stream
/// in the same fMP4 fragments.
///
/// Modes (see `AudioBridge.Mode`):
///   - `.surroundCompat` (default): EAC3 at 128 kbps per channel (256 kbps stereo, 768 kbps 5.1). AVPlayer
///     hands the encoded bitstream to HDMI; the sink decodes its own
///     5.1. Works on essentially every modern AVR + soundbar
///     including LPCM-stereo-only routes (Sonos Arc, Samsung HW-Q,
///     Bose, etc.) where the lossless FLAC path falls down. Lossy
///     and caps at 5.1, so 7.1 sources lose SL/SR.
///   - `.lossless`: FLAC up to 7.1 lossless. AVPlayer decodes to
///     LPCM and routes via the active HDMI port. Needs a sink that
///     accepts multichannel LPCM (Denon / Marantz / NAD high-end
///     AVRs). On a stereo-LPCM route the multichannel LPCM gets
///     downmixed to stereo before output.
///
/// The motivation: AVPlayer's fMP4 decode path supports AAC / AC3 /
/// EAC3 (incl. Atmos JOC) / FLAC / ALAC / MP3 / Opus directly, but
/// FFmpeg's mp4 muxer can't always stream-copy EAC3 from MKV (the
/// `dec3` box bytes need pre-parsed extradata that MKV CodecPrivate
/// often doesn't carry, leading to `avformat_write_header` returning
/// -22 EINVAL). TrueHD and DTS aren't legal in fMP4 at all per the
/// ISOBMFF + Apple HLS spec. FLAC and EAC3 are legal, decode
/// everywhere on Apple devices, so we reroute through one of them.
///
/// Atmos object metadata cannot be preserved through either bridge
/// mode: TrueHD-MAT objects are interleaved in the source bitstream,
/// FFmpeg's EAC3 encoder doesn't produce JOC (the Dolby-licensed
/// extension that encodes Atmos in EAC3), and FLAC has no object
/// channel concept. EAC3+JOC sources are kept lossless via the
/// stream-copy path that bypasses the bridge entirely; only sources
/// that can't stream-copy enter this bridge.
/// Encoder choice for the audio bridge. Public so `LoadOptions` and
/// the host can pass it through; default `.surroundCompat` because
/// the soundbar / LPCM-stereo-only install base is the majority of
/// the consumer market.
///
/// - `.surroundCompat`: EAC3 at 128 kbps per channel (256 kbps stereo, 768 kbps 5.1), AVPlayer → HDMI
///   bitstream tunnel. Lossy but surround works on essentially every
///   modern AVR + soundbar.
/// - `.lossless`: FLAC up to 7.1, AVPlayer → LPCM HDMI route. Needs
///   a sink that accepts multichannel LPCM (Denon / Marantz / NAD).
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
    /// Audio FIFO that buffers resampled PCM until we have at least
    /// `encoderCtx.frame_size` samples to feed the encoder. FLAC's
    /// libavcodec wrapper has `AV_CODEC_CAP_SMALL_LAST_FRAME` but
    /// not `AV_CODEC_CAP_VARIABLE_FRAME_SIZE`, so non-final frames
    /// must hit `frame_size` exactly (typically 4608 at 48 kHz).
    /// EAC3 packets decode to 1536 samples each so we'd otherwise
    /// hit `-22 EINVAL` on the first send.
    private var fifo: OpaquePointer?

    /// PCM sample format used end-to-end through the bridge: the
    /// resampler converts to it, the FIFO holds it, the encoder
    /// consumes it. `S16` for lossy source codecs (EAC3, AC3 etc.)
    /// where 16-bit precision matches the source's perceptual range.
    /// `S32` with `bits_per_raw_sample=24` for lossless source codecs
    /// (TrueHD, DTS-HD MA, FLAC source, ALAC source, raw 24/32-bit
    /// PCM) so a lossless source goes through a lossless intermediate
    /// and the FLAC output stays bit-perfect. Going S16 for lossless
    /// source would silently dither away the bottom 8 bits, audible
    /// in quiet passages.
    private let pcmSampleFmt: AVSampleFormat
    private let pcmBytesPerSample: Int32
    private let pcmBitsPerRawSample: Int32

    /// AVCodecParameters describing the FLAC output stream. Caller
    /// hands this to `HLSSegmentProducer.AudioConfig.codecpar` and
    /// the producer installs it on the muxer's audio output stream.
    /// Owned by the bridge; freed in `close()`.
    private(set) var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>?

    /// Time base of the FLAC output stream (1 / sample_rate). Caller
    /// passes this as `StreamConfig.timeBase`.
    private(set) var encoderTimeBase: AVRational = AVRational(num: 1, den: 1)

    private let srcTimeBase: AVRational
    private let mode: Mode
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

    /// Opens the source decoder + bridge encoder. The encoder choice
    /// is picked by `mode`:
    ///   - `.surroundCompat`: EAC3 at 128 kbps per channel (256 kbps stereo, 768 kbps 5.1) via FFmpeg's eac3
    ///     encoder. Caps channels at 6, sample format FLTP.
    ///   - `.lossless`: FLAC at source channel count via FFmpeg's flac
    ///     encoder. Caps at 8 channels (FLAC max), sample format S16
    ///     for lossy sources or S32@24 for lossless sources.
    /// Encoder is opened eagerly so `encoderCodecpar` is available
    /// immediately for muxer init. If the source's codecpar is
    /// incomplete (TrueHD sometimes reports `sample_rate=0` until the
    /// first frame), we fall back to 48 kHz stereo, which the resampler
    /// will reconfigure on the first decoded frame if it differs.
    init(
        srcCodecpar: UnsafeMutablePointer<AVCodecParameters>,
        srcTimeBase: AVRational,
        mode: Mode = .surroundCompat
    ) throws {
        self.srcTimeBase = srcTimeBase
        self.mode = mode

        // 1. Source decoder
        let srcCodecID = srcCodecpar.pointee.codec_id

        // PCM intermediate format. The encoder mode dictates this:
        //   - EAC3 needs FLTP (float planar) regardless of source.
        //   - FLAC takes S16 or S32; lossless sources get S32+24 to
        //     preserve bit depth, lossy sources stay at S16.
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

        // 2. Bridge encoder. Selected by mode:
        //   - .surroundCompat → AV_CODEC_ID_EAC3, 128 kbps per channel, max 6 ch
        //   - .lossless       → AV_CODEC_ID_FLAC, VBR, max 8 ch
        //
        // The actual bit_rate is set further below after the channel
        // count resolves (EAC3 scales 128 kbps × nChannels — DrHurt's
        // pointer on AetherEngine#4: 256 kbps stereo, 768 kbps 5.1,
        // scales naturally if the channel cap ever gets bumped per
        // Nomis101's PR 21668). FLAC stays at 0 = unlimited VBR.
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

        // Channel-count resolution. Try sources in order:
        //   1. srcCodecpar.ch_layout — populated by the demuxer from the
        //      container's audio track header (matroska Channels element,
        //      mp4 audio sample entry, etc.). Most sources land here.
        //   2. dec.ch_layout after avcodec_open2 — some codecs propagate
        //      a default layout from the decoder's init function even
        //      without a frame decode.
        //   3. Fallback to stereo, with a loud log line so the silent
        //      surround → stereo downmix doesn't go unnoticed.
        //
        // Matroska doesn't reliably populate Channels for TrueHD / MLP:
        // the codec's bitstream carries the layout, but the container
        // header is optional. When both srcCodecpar and dec come back at
        // 0, the bridge defaults to stereo and the resampler downmixes
        // the actual 7.1 / 5.1 source — which is the symptom we ship a
        // warning for so future-us has a logged repro to fix on (the
        // proper fix is peeking the first packet to settle ch_layout
        // before opening the encoder).
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
        // Cap to the encoder's max channel count. EAC3 stops at 5.1
        // (mode .surroundCompat), FLAC at 7.1 (mode .lossless).
        // Downmix from above the cap happens automatically inside
        // swr_convert when the source channel layout exceeds the
        // encoder's; the resampler picks Apple-compatible layout
        // ordering.
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
        // Dynamic per-channel bitrate for the EAC3 path (128 kbps per
        // channel, the Dolby reference transparent profile). For FLAC
        // (`.lossless` mode) stay at 0 = unlimited VBR.
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
        // copy() allocates a channel map for custom-order layouts; the
        // stack struct must be uninit'd or that map leaks per session.
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

        // 5. Audio FIFO: buffer up to one second of PCM samples by
        //    default (FFmpeg grows it on demand if we exceed). Used
        //    to chunk the resampler's output into encoder-sized
        //    frames.
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
        cleanup()
    }

    /// Current FIFO depth in samples (per channel). Used by the engine
    /// memory probe to spot drain stalls. Steady-state is below
    /// `encoderCtx.frame_size` (~4608 at 48 kHz); a growing value
    /// indicates the encoder isn't keeping up with the resampler.
    var fifoSampleCount: Int {
        guard let f = fifo else { return 0 }
        return Int(av_audio_fifo_size(f))
    }

    /// Snapshot of bytes the bridge has live in its growable buffers.
    /// Used by the engine memory probe to detect whether the bridge is
    /// the source of linear memory growth. Both fields are growable on
    /// the FFmpeg side (FIFO reallocs upward, swr's internal delay
    /// buffer reallocates when input rate / layout shifts), so a
    /// monotonically rising value across probe samples points the
    /// finger here vs. the segment muxer or HLS server.
    ///
    /// Costs: two C calls, no allocations.
    struct LiveBytes {
        /// Samples currently in the FIFO (per channel).
        let fifoSamples: Int
        /// Bytes the FIFO is holding in interleaved PCM:
        /// `samples * channels * bytesPerSample`.
        let fifoBytes: Int
        /// Samples the resampler is buffering internally, measured in
        /// encoder sample-rate units.
        let swrDelaySamples: Int
        /// Approximate bytes held in the swr delay buffer
        /// (`swrDelaySamples * channels * bytesPerSample`). The
        /// resampler may use a different internal format, but for a
        /// growth trend this is a fine proxy.
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
        // Drop the decoder's reference frames and the resampler's delay
        // buffer too: after a backward scrub they still hold
        // pre-restart samples that would otherwise bleed a few ms of
        // old-position audio into the new position (and a stale decoder
        // frame could surface as garbage content on the rebased
        // timeline). swr_init on a configured context re-initializes it
        // in place, clearing the fractional-delay state.
        if let dec = decoderCtx {
            avcodec_flush_buffers(dec)
        }
        if let swr = swrCtx {
            _ = swr_init(swr)
        }
        rebaseFromNextSourcePTS = true
    }

    /// Drain everything still buffered in the bridge at source EOF:
    /// remaining decoder frames, the FIFO leftover (< one encoder
    /// frame), and the encoder's internal delay. Without this the
    /// final ~100-200 ms of audio of every VOD title were silently
    /// dropped (the FIFO drain in `feed` only emits FULL encoder
    /// frames, and nothing ever sent the encoder its EOF frame).
    /// Returns the final encoded packets; the caller writes them via
    /// the same muxer path as `feed` output. Call once, at pump EOF,
    /// before muxer finalize. Not meaningful for live (no EOF).
    func flush() -> [UnsafeMutablePointer<AVPacket>] {
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

    /// Live program-boundary correction. The bridge stamps its output
    /// from the free-running `nextEncoderPTS` sample counter, which
    /// collapses any audio splice gap sample-continuously, while the
    /// video timeline keeps the relative gap the rebase preserved. The
    /// producer calls this with the residual (audio gap minus video
    /// gap, in seconds) so the bridged audio timeline reproduces the
    /// same relationship: positive deltas advance the encoder PTS
    /// (AVPlayer renders the gap as silence), negative ones (an audio
    /// overlap at the splice) are clamped, the counter cannot rewind.
    /// Called on the pump thread, same thread as `feed`. Samples still
    /// sitting in the FIFO (< one encoder frame) are stamped post-jump;
    /// that error is bounded by one frame (~32 ms) and one-shot.
    func noteTimelineJump(deltaSeconds: Double) {
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

        // Capture the packet's pts before we hand it to the decoder.
        // The encoder-PTS rebase uses this rather than the decoded
        // frame's pts.
        //
        // For codecs with decoder priming samples (Opus preskip ~312
        // samples at 48 kHz, AAC encoder delay), libavcodec's generic
        // discard-samples path trims the leading samples from the
        // first decoded frame AND advances `frame.pts` by the same
        // amount. Rebasing the encoder timeline off the advanced
        // frame.pts would forward-shift FLAC output by preskip-count
        // units, opening the audio gate ahead of the video gate and
        // stalling AVPlayer in `waitingToPlay` waiting for an audio
        // segment that never lines up. Issue #7.
        //
        // packet.pts represents the source timeline position of the
        // *encoded* packet (preskip + content). Using it for rebase
        // keeps the FLAC output aligned with source-PTS=packet.pts on
        // the first encoded sample, matching how video segments are
        // aligned, regardless of whether the codec auto-trims preskip
        // off the decoded data.
        let packetPts = packet.pointee.pts

        var srcFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&srcFrame) }
        guard let sf = srcFrame else { return results }

        // Drain every currently-decodable frame into the FIFO. The PTS
        // rebase fires on the first decoded frame after a segment
        // boundary so the FLAC stream timestamps track the source rather
        // than drifting on the FIFO leftover. See the packetPts capture
        // above for why we use that rather than sf.pts.
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
        if sendRet == AVERROR_EAGAIN_VALUE {
            // Standard FFmpeg contract: EAGAIN from send_packet means the
            // decoder's output queue is full (possible on multi-frame
            // packets, e.g. TrueHD bursts) and frames must be received
            // first, then the send retried. The old code lumped EAGAIN in
            // with real errors and threw, dropping the packet.
            try receiveDecodedFrames()
            sendRet = avcodec_send_packet(dec, packet)
        }
        if sendRet == AVERROR_INVALIDDATA_VALUE {
            // Corrupt source packet (glitchy live MPEG-TS, broken mp2
            // header). The decoder stays usable for the next valid packet,
            // so skip this one rather than throwing. Throwing per-packet on
            // a persistently corrupt stream floods the caller with caught
            // errors (hundreds per second on a bad feed) for no benefit.
            return results
        }
        if sendRet < 0 && sendRet != AVERROR_EOF_VALUE {
            throw AudioBridgeError.sendPacketFailed(code: sendRet)
        }

        try receiveDecodedFrames()

        // Drain the FIFO into encoder-frame-size chunks. Each chunk
        // becomes one AVFrame fed to the encoder.
        try drainFIFOIntoEncoder(enc: enc, fifo: fifoPtr, requireFull: true, results: &results)

        return results
    }

    /// Pull samples out of `sf` (decoded source frame), resample to
    /// encoder format, and push into the FIFO. `swr_convert` can
    /// produce more or fewer samples than the input frame contained,
    /// the FIFO smooths that out.
    ///
    /// Buffer layout depends on `pcmSampleFmt`:
    ///   - **Interleaved** (S16 / S32, the FLAC mode): one contiguous
    ///     buffer with all channels interleaved sample-by-sample.
    ///     swr_convert and av_audio_fifo_write both take a single
    ///     pointer in `out[0]`.
    ///   - **Planar** (FLTP, the EAC3 mode): one buffer per channel.
    ///     swr_convert needs `out` to be an array of N pointers, one
    ///     per channel. Same for av_audio_fifo_write. Passing a single
    ///     pointer (the interleaved layout) here would have the encoder
    ///     reading garbage from the N-1 unallocated channel slots,
    ///     surfaced previously as EXC_BAD_ACCESS inside swr_convert.
    private func resampleAndPushIntoFIFO(
        srcFrame sf: UnsafeMutablePointer<AVFrame>,
        enc: UnsafeMutablePointer<AVCodecContext>,
        swr: OpaquePointer,
        fifo: OpaquePointer
    ) throws {
        let outNbSamples = swr_get_out_samples(swr, sf.pointee.nb_samples)
        guard outNbSamples > 0 else { return }

        // Corrupt source audio (a glitchy live MPEG-TS feed, an mp2 stream
        // with missing frame headers) can decode into a frame that reports
        // nb_samples > 0 but carries no allocated sample buffer:
        // extended_data points at a channel-pointer array whose entries are
        // NULL. swr_convert then dereferences that NULL channel pointer and
        // crashes with EXC_BAD_ACCESS at 0x0. Skip such frames; the video
        // path already tolerates the same corruption, audio must too.
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

        // Build an array of pointers for swr_convert + FIFO write. For
        // interleaved this is a single-element array; for planar it's
        // one entry per channel.
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

        // av_audio_fifo_write takes `void **data`. The same per-channel
        // (planar) or single-pointer (interleaved) array works for
        // both: the FIFO was init'd with the sample format and knows
        // the layout.
        _ = outPtrs.withUnsafeMutableBufferPointer { fifoBuf in
            fifoBuf.baseAddress!.withMemoryRebound(
                to: UnsafeMutableRawPointer?.self, capacity: bufferCount
            ) { rebound in
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
            of.pointee.format = pcmSampleFmt.rawValue
            of.pointee.nb_samples = chunkSize
            of.pointee.sample_rate = enc.pointee.sample_rate
            av_channel_layout_copy(&of.pointee.ch_layout, &enc.pointee.ch_layout)
            let allocRet = av_frame_get_buffer(of, 0)
            if allocRet < 0 { break }

            // FIFO read into the AVFrame's data planes. For interleaved
            // formats `data[0]` holds the contiguous sample buffer; for
            // planar formats `data[0..N-1]` hold one buffer per channel
            // (extended_data[i] for high channel counts beyond 8, but
            // EAC3 caps us at 6 and FLAC at 8 so data[] is sufficient).
            // `av_audio_fifo_read` takes `void **data` and respects the
            // FIFO's sample format (planar vs interleaved) to choose
            // whether to write to data[0] alone or fan out per channel.
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
            _ = nChannels

            let sendFrameRet = avcodec_send_frame(enc, of)
            if sendFrameRet < 0 && sendFrameRet != AVERROR_EOF_VALUE {
                throw AudioBridgeError.sendFrameFailed(code: sendFrameRet)
            }

            // Drain encoder for any packets ready to emit.
            while true {
                guard let outPkt = trackedPacketAlloc() else { break }
                let recvRet = avcodec_receive_packet(enc, outPkt)
                if recvRet == AVERROR_EAGAIN_VALUE || recvRet == AVERROR_EOF_VALUE {
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

/// `AVERROR(EAGAIN)` and `AVERROR_EOF` are macros Swift can't import,
/// so we rederive them. EAGAIN is POSIX 35 on Apple platforms, and
/// FFmpeg's macro is `-(35)` after the FFERRTAG transform; but in
/// practice the constant FFmpeg returns is the negated POSIX value
/// for EAGAIN and a tagged sentinel for EOF.
private let AVERROR_EAGAIN_VALUE: Int32 = -35
private let AVERROR_EOF_VALUE: Int32 = -0x20464F45  // FFERRTAG('E','O','F',' ')
/// `AVERROR_INVALIDDATA` = `FFERRTAG('I','N','D','A')`. Returned by a
/// decoder fed a corrupt elementary-stream packet (e.g. a broken MPEG
/// audio frame with a missing header, common on a glitchy live MPEG-TS
/// source). Treated as "skip this packet", not fatal.
private let AVERROR_INVALIDDATA_VALUE: Int32 = -0x41444E49
