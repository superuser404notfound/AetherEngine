import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Fragmented MP4 muxer driving FFmpeg's `mp4` muxer through a custom
/// `AVIOContext` so the output bytes are captured into a Swift `Data`
/// buffer instead of writing to disk. Used by `HLSVideoEngine` to
/// produce the init segment (`ftyp`+`moov`) once and then one
/// `moof`+`mdat` fragment per HLS segment, served by
/// `HLSLocalServer` over loopback to AVPlayer.
///
/// Key reasons for using `libavformat` instead of hand-rolling the
/// box layout (the way `FMP4AudioMuxer` does):
/// - HEVC `hvcC` parameter-set encoding is non-trivial (VPS/SPS/PPS
///   walk, profile-tier-level encoding).
/// - Dolby Vision `dvcC` / `dvvC` atom emission needs
///   `strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL` and the
///   muxer takes care of the byte layout from the input
///   `AV_PKT_DATA_DOVI_CONF` side data.
/// - B-frame composition-time-offset handling near segment
///   boundaries is what the `cmaf` movflag is for; we'd reproduce it
///   poorly by hand.
///
/// Movflags:
///   - `frag_custom`: muxer never auto-cuts; each `av_write_frame(NULL)`
///     emits one fragment. Lets the caller align segments to source
///     keyframes.
///   - `empty_moov`: `moov` is written upfront with no samples;
///     samples live in subsequent `moof`+`mdat` fragments.
///   - `default_base_moof`: sets the `default-base-is-moof` flag in
///     `tfhd`, required by Apple HLS-fMP4.
///   - `cmaf`: implies the above plus negative-CTS-offset support
///     and single-track-per-moof; required for Apple Dolby Vision
///     content per Apple's HLS Authoring Spec.
final class FMP4VideoMuxer {

    // MARK: - Errors

    enum FMP4VideoMuxerError: Error, CustomStringConvertible {
        case allocationFailed
        case streamCreationFailed
        case copyParametersFailed(code: Int32)
        case headerFailed(code: Int32)
        case writeFailed(code: Int32)
        case closed

        var description: String {
            switch self {
            case .allocationFailed: return "FMP4VideoMuxer: allocation failed"
            case .streamCreationFailed: return "FMP4VideoMuxer: avformat_new_stream failed"
            case .copyParametersFailed(let code): return "FMP4VideoMuxer: avcodec_parameters_copy failed (\(code))"
            case .headerFailed(let code): return "FMP4VideoMuxer: avformat_write_header failed (\(code))"
            case .writeFailed(let code): return "FMP4VideoMuxer: write failed (\(code))"
            case .closed: return "FMP4VideoMuxer: instance is closed"
            }
        }
    }

    // MARK: - Configuration

    /// One source stream's parameters. Caller supplies a pointer to
    /// FFmpeg's `AVCodecParameters` (typically `inputStream.codecpar`)
    /// and the source stream's `time_base`. The muxer copies the
    /// parameters internally so the caller may free / repurpose the
    /// source after `init` returns.
    struct StreamConfig {
        let codecpar: UnsafeMutablePointer<AVCodecParameters>
        let timeBase: AVRational
        /// When true, override the muxer's default codec FourCC
        /// (`hvc1`) with `dvh1` so AVPlayer routes the stream to its
        /// Dolby Vision decoder. Apple-only convention; non-Apple
        /// decoders generally accept either tag.
        let isDolbyVision: Bool
    }

    // MARK: - Properties

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var ioContext: UnsafeMutablePointer<AVIOContext>?
    private static let ioBufferSize: Int32 = 32 * 1024
    private static let avNoPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1   // AV_NOPTS_VALUE

    let videoOutputIndex: Int = 0
    let audioOutputIndex: Int?

    private let videoSourceTimeBase: AVRational
    private let audioSourceTimeBase: AVRational?

    /// Captures `write_packet` callback bytes between flushes.
    private var captureBuffer = Data()
    private let captureLock = NSLock()

    private var headerWritten = false
    private var isClosed = false

    // MARK: - Init

    init(video: StreamConfig, audio: StreamConfig?) throws {
        videoSourceTimeBase = video.timeBase
        audioSourceTimeBase = audio?.timeBase
        audioOutputIndex = audio != nil ? 1 : nil

        // 1. Allocate output format context for the "mp4" muxer.
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        let allocRet = avformat_alloc_output_context2(&ctxOut, nil, "mp4", nil)
        guard allocRet == 0, let ctx = ctxOut else {
            throw FMP4VideoMuxerError.allocationFailed
        }
        formatContext = ctx

        // 2. Allow non-standard extensions so the muxer writes
        //    `dvcC` / `dvvC` atoms (they aren't in the ISOBMFF base
        //    spec, only the Dolby Vision spec).
        ctx.pointee.strict_std_compliance = -2  // FF_COMPLIANCE_UNOFFICIAL

        // 3. Add the video stream and copy parameters from the source.
        guard let videoStream = avformat_new_stream(ctx, nil) else {
            cleanup()
            throw FMP4VideoMuxerError.streamCreationFailed
        }
        let vCopy = avcodec_parameters_copy(videoStream.pointee.codecpar, video.codecpar)
        guard vCopy >= 0 else {
            cleanup()
            throw FMP4VideoMuxerError.copyParametersFailed(code: vCopy)
        }
        videoStream.pointee.time_base = video.timeBase
        if video.isDolbyVision {
            // Set codec FourCC to 'dvh1'. Apple reads the codec tag
            // before the container's `dvcC`/`dvvC` atoms when deciding
            // whether to engage the DV pipeline, so the tag must say
            // "this is DV HEVC", not plain HEVC.
            videoStream.pointee.codecpar.pointee.codec_tag = Self.mkTag("d", "v", "h", "1")
        }

        // 4. Add the audio stream (if any).
        if let audio = audio {
            guard let audioStream = avformat_new_stream(ctx, nil) else {
                cleanup()
                throw FMP4VideoMuxerError.streamCreationFailed
            }
            let aCopy = avcodec_parameters_copy(audioStream.pointee.codecpar, audio.codecpar)
            guard aCopy >= 0 else {
                cleanup()
                throw FMP4VideoMuxerError.copyParametersFailed(code: aCopy)
            }
            audioStream.pointee.time_base = audio.timeBase
        }

        // 5. Allocate the AVIO buffer and a custom write context. The
        //    write callback appends bytes to `captureBuffer`; the
        //    caller drains this buffer after each `writeInitSegment`
        //    / `flushFragment` call. Read and seek callbacks are nil:
        //    `frag_custom` + `empty_moov` produces strictly forward
        //    output, the muxer never asks to seek backwards.
        guard let raw = av_malloc(Int(Self.ioBufferSize)) else {
            cleanup()
            throw FMP4VideoMuxerError.allocationFailed
        }
        let ioBuffer = raw.assumingMemoryBound(to: UInt8.self)
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let avio = avio_alloc_context(
            ioBuffer,
            Self.ioBufferSize,
            /* write_flag */ 1,
            opaque,
            nil,
            fmp4VideoMuxerWriteCallback,
            nil
        ) else {
            av_free(raw)
            cleanup()
            throw FMP4VideoMuxerError.allocationFailed
        }
        avio.pointee.seekable = 0
        ioContext = avio
        ctx.pointee.pb = avio
        ctx.pointee.flags |= 0x0080  // AVFMT_FLAG_CUSTOM_IO
    }

    deinit {
        cleanup()
    }

    // MARK: - Public API

    /// Writes the init segment (`ftyp` + empty `moov`) and returns
    /// the captured bytes. Must be called once before any
    /// `writePacket` / `flushFragment`. Idempotent: if called again,
    /// throws because libavformat doesn't support re-running
    /// `avformat_write_header` on the same context.
    func writeInitSegment() throws -> Data {
        guard !isClosed, let ctx = formatContext else {
            throw FMP4VideoMuxerError.closed
        }
        if headerWritten {
            throw FMP4VideoMuxerError.headerFailed(code: -1)
        }

        var opts: OpaquePointer? = nil  // AVDictionary*
        defer { av_dict_free(&opts) }
        av_dict_set(&opts,
                    "movflags",
                    "frag_custom+empty_moov+default_base_moof+cmaf",
                    0)

        clearCaptureBuffer()

        let ret = avformat_write_header(ctx, &opts)
        guard ret >= 0 else {
            throw FMP4VideoMuxerError.headerFailed(code: ret)
        }
        if let pb = ctx.pointee.pb {
            avio_flush(pb)
        }
        headerWritten = true
        return drainCaptureBuffer()
    }

    /// Hand one source packet to the muxer. The packet is cloned so
    /// the caller retains ownership of the original. Timestamps are
    /// rescaled from the source stream's time base (set at init) to
    /// the muxer stream's time base (which `libavformat` may have
    /// changed during `avformat_write_header`).
    ///
    /// `toStreamIndex` must be `videoOutputIndex` or
    /// `audioOutputIndex` (when audio is present).
    func writePacket(_ packet: UnsafePointer<AVPacket>, toStreamIndex: Int) throws {
        guard !isClosed, let ctx = formatContext, headerWritten else {
            throw FMP4VideoMuxerError.closed
        }
        guard let outStream = ctx.pointee.streams[toStreamIndex] else {
            throw FMP4VideoMuxerError.writeFailed(code: -1)
        }
        guard let cloned = av_packet_clone(packet) else {
            throw FMP4VideoMuxerError.allocationFailed
        }
        var pktPtr: UnsafeMutablePointer<AVPacket>? = cloned
        defer { av_packet_free(&pktPtr) }

        cloned.pointee.stream_index = Int32(toStreamIndex)

        let sourceTb: AVRational
        if toStreamIndex == videoOutputIndex {
            sourceTb = videoSourceTimeBase
        } else {
            sourceTb = audioSourceTimeBase ?? AVRational(num: 1, den: 1)
        }
        let outTb = outStream.pointee.time_base

        if cloned.pointee.pts != Self.avNoPTS {
            cloned.pointee.pts = av_rescale_q(cloned.pointee.pts, sourceTb, outTb)
        }
        if cloned.pointee.dts != Self.avNoPTS {
            cloned.pointee.dts = av_rescale_q(cloned.pointee.dts, sourceTb, outTb)
        }
        if cloned.pointee.duration != 0 {
            cloned.pointee.duration = av_rescale_q(cloned.pointee.duration, sourceTb, outTb)
        }
        cloned.pointee.pos = -1

        let ret = av_interleaved_write_frame(ctx, cloned)
        if ret < 0 {
            throw FMP4VideoMuxerError.writeFailed(code: ret)
        }
    }

    /// Force the muxer to emit a fragment containing every packet
    /// fed since the previous flush (or since the init segment, on
    /// first call). With `frag_custom` movflag this is the only way
    /// fragments get written: `av_write_frame` with a NULL packet is
    /// the explicit flush trigger, and the muxer responds by writing
    /// one `moof`+`mdat` for the accumulated samples.
    func flushFragment() throws -> Data {
        guard !isClosed, let ctx = formatContext, headerWritten else {
            throw FMP4VideoMuxerError.closed
        }
        let ret = av_write_frame(ctx, nil)
        if ret < 0 {
            throw FMP4VideoMuxerError.writeFailed(code: ret)
        }
        if let pb = ctx.pointee.pb {
            avio_flush(pb)
        }
        return drainCaptureBuffer()
    }

    /// Release all FFmpeg resources. Safe to call multiple times. The
    /// `deinit` calls this; explicit `close()` is for cases where the
    /// caller wants to free resources before the Swift reference goes
    /// away.
    func close() {
        cleanup()
    }

    // MARK: - Internal

    fileprivate func handleWrite(buf: UnsafePointer<UInt8>, size: Int32) -> Int32 {
        guard size > 0 else { return 0 }
        captureLock.lock()
        captureBuffer.append(buf, count: Int(size))
        captureLock.unlock()
        return size
    }

    private func drainCaptureBuffer() -> Data {
        captureLock.lock()
        let drained = captureBuffer
        captureBuffer = Data()
        captureLock.unlock()
        return drained
    }

    private func clearCaptureBuffer() {
        captureLock.lock()
        captureBuffer.removeAll(keepingCapacity: true)
        captureLock.unlock()
    }

    private func cleanup() {
        guard !isClosed else { return }
        isClosed = true
        // Order matters: free the format context first so the muxer
        // releases any reference to `pb`, then free the AVIO context
        // (which also frees the buffer it owns). avformat_free_context
        // does NOT free pb when AVFMT_FLAG_CUSTOM_IO is set on the
        // context, so we must release pb ourselves.
        if let ctx = formatContext {
            avformat_free_context(ctx)
            formatContext = nil
        }
        if ioContext != nil {
            // avio_context_free frees the underlying buffer too
            // (whatever buffer is currently set on the context, which
            // libavformat may have replaced from the one we passed).
            avio_context_free(&ioContext)
            ioContext = nil
        }
    }

    // MARK: - Helpers

    /// Equivalent of FFmpeg's `MKTAG(a, b, c, d)` macro. Encodes a
    /// four-character code as a little-endian `UInt32` (byte 0 = `a`,
    /// byte 3 = `d`).
    private static func mkTag(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> UInt32 {
        func code(_ ch: Character) -> UInt32 {
            UInt32(ch.asciiValue ?? 0)
        }
        return code(a) | (code(b) << 8) | (code(c) << 16) | (code(d) << 24)
    }
}

// MARK: - C callback bridge

/// FFmpeg `write_packet` callback bridge. The first argument is the
/// `opaque` pointer we passed to `avio_alloc_context`, which is the
/// muxer instance.
private func fmp4VideoMuxerWriteCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let muxer = Unmanaged<FMP4VideoMuxer>.fromOpaque(opaque).takeUnretainedValue()
    return muxer.handleWrite(buf: buf, size: size)
}
