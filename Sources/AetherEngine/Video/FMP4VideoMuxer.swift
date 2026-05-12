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

    enum FMP4VideoMuxerError: Error, CustomStringConvertible, LocalizedError {
        case mp4MuxerNotAvailable(code: Int32)
        case ioBufferAllocFailed
        case ioContextAllocFailed
        case streamCreationFailed
        case packetCloneFailed
        case copyParametersFailed(code: Int32)
        case headerFailed(code: Int32)
        case writeFailed(code: Int32)
        case closed

        var description: String {
            switch self {
            case .mp4MuxerNotAvailable(let code): return "FMP4VideoMuxer: avformat_alloc_output_context2 returned \(code) (mp4 muxer not registered, FFmpeg build missing --enable-muxer=mp4?)"
            case .ioBufferAllocFailed:    return "FMP4VideoMuxer: av_malloc for AVIO buffer failed"
            case .ioContextAllocFailed:   return "FMP4VideoMuxer: avio_alloc_context failed"
            case .streamCreationFailed:   return "FMP4VideoMuxer: avformat_new_stream failed"
            case .packetCloneFailed:      return "FMP4VideoMuxer: av_packet_clone failed"
            case .copyParametersFailed(let code): return "FMP4VideoMuxer: avcodec_parameters_copy failed (\(code))"
            case .headerFailed(let code): return "FMP4VideoMuxer: avformat_write_header failed (\(code))"
            case .writeFailed(let code):  return "FMP4VideoMuxer: write failed (\(code))"
            case .closed:                 return "FMP4VideoMuxer: instance is closed"
            }
        }

        var errorDescription: String? { description }
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
        /// Override the muxer's default codec FourCC. Per the Apple
        /// HLS authoring spec (and validated by DrHurt's KSPlayer
        /// research, AetherEngine#1):
        ///   - DV Profile 5 → `"dvh1"`
        ///   - DV Profile 8.1 (HDR10-compat) → `"dvh1"`
        ///   - DV Profile 8.4 (HLG-compat) → nil (use the muxer's
        ///     default `hvc1`, the bitstream is interpreted as
        ///     plain HLG-HEVC and AVPlayer engages DV via the
        ///     `dvcC`/`dvvC` atom + `VIDEO-RANGE=HLG` declaration)
        ///   - HDR10 / HDR10+ / HLG → nil (default `hvc1`)
        /// Pass nil for "let libavformat decide" (which produces
        /// `hvc1` for HEVC).
        let codecTagOverride: String?
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
            throw FMP4VideoMuxerError.mp4MuxerNotAvailable(code: allocRet)
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
        if let override = video.codecTagOverride,
           let tag = Self.mkTag(fromFourCC: override) {
            videoStream.pointee.codecpar.pointee.codec_tag = tag
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
            throw FMP4VideoMuxerError.ioBufferAllocFailed
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
            throw FMP4VideoMuxerError.ioContextAllocFailed
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
        let init_ = drainCaptureBuffer()
        Self.logInitSegmentBoxSummary(init_)
        return init_
    }

    /// One-line summary of the structural boxes inside the init
    /// segment, emitted right after the muxer writes the header. The
    /// existing hex dump prints the raw bytes but rolls out of the
    /// 80-line LogTap ring buffer before the eventual playback
    /// failure lands; this summary picks out exactly the boxes that
    /// matter for AVPlayer's DV / HEVC acceptance and stays on a
    /// single line so it survives the buffer.
    ///
    /// Specifically answers: did the mp4 muxer emit `dvcC` / `dvvC`
    /// (the DV configuration boxes), and what video sample-entry
    /// FourCC did it pick? AVPlayer's `Cannot Open` -11829 +
    /// `CoreMediaErrorDomain -12848` on a P5 source typically means
    /// the sample entry is `dvh1` but the DV config box is missing,
    /// so AVPlayer parses the container as nominally-DV but can't
    /// find the configuration record to validate against.
    /// Exposed for the HLS segment provider to re-emit on each
    /// /init.mp4 fetch so the structural truth lands close to
    /// AVPlayer's parse failure, not just at session start where the
    /// overlay ring buffer rolls it off before the failure lands.
    static func logInitSegmentBoxSummary(_ data: Data) {
        let videoSampleEntries: Set<String> = [
            "hvc1", "hev1", "dvh1", "dvhe", "avc1", "avc3"
        ]
        var sampleEntry: String?
        var hasHvcC = false
        var hasDvcC = false
        var hasDvvC = false
        var hasFtyp = false
        var hasMoov = false

        // Walk every 4-byte ASCII run in the buffer looking for known
        // box-name FourCCs. The init segment is a few KB so this is
        // cheap, and a name-only scan stays robust against minor
        // structural variations (we don't need to recurse into box
        // sizes to answer the questions we care about).
        let bytes = [UInt8](data)
        if bytes.count >= 8 {
            for i in 0...(bytes.count - 4) {
                let b = (bytes[i], bytes[i+1], bytes[i+2], bytes[i+3])
                guard Self.isASCIIBoxName(b) else { continue }
                let tag = String(
                    bytes: [b.0, b.1, b.2, b.3],
                    encoding: .ascii
                ) ?? ""
                if videoSampleEntries.contains(tag), sampleEntry == nil {
                    sampleEntry = tag
                }
                switch tag {
                case "ftyp": hasFtyp = true
                case "moov": hasMoov = true
                case "hvcC": hasHvcC = true
                case "dvcC": hasDvcC = true
                case "dvvC": hasDvvC = true
                default: break
                }
            }
        }

        let entryStr = sampleEntry ?? "?"
        let summary = """
            [FMP4VideoMuxer] init.mp4 bytes=\(data.count) \
            sample-entry=\(entryStr) \
            ftyp=\(hasFtyp ? "y" : "n") \
            moov=\(hasMoov ? "y" : "n") \
            hvcC=\(hasHvcC ? "y" : "n") \
            dvcC=\(hasDvcC ? "y" : "MISSING") \
            dvvC=\(hasDvvC ? "y" : "absent")
            """
        EngineLog.emit(summary)
    }

    /// True iff the four bytes form a plausible mp4 box name (ASCII
    /// letters + digits). Filters out random binary that happens to
    /// fall on a 4-byte boundary, so the scan above doesn't report
    /// "samp" or other fragments embedded in coded data.
    private static func isASCIIBoxName(_ b: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        func isOK(_ c: UInt8) -> Bool {
            (c >= 0x61 && c <= 0x7a) ||  // a-z
            (c >= 0x41 && c <= 0x5a) ||  // A-Z
            (c >= 0x30 && c <= 0x39)     // 0-9
        }
        return isOK(b.0) && isOK(b.1) && isOK(b.2) && isOK(b.3)
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
            throw FMP4VideoMuxerError.packetCloneFailed
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

        // Capture source-side timestamps before rescaling so the
        // failure-path diag can surface them. Without these the
        // overlay only shows the rescaled values, which doesn't help
        // pinpoint whether the bug is "demuxer gave us bogus PTS" or
        // "rescale produced a non-monotonic DTS" or "muxer
        // boundary-aligned PTS got rejected by the mp4 muxer".
        let srcPts = cloned.pointee.pts
        let srcDts = cloned.pointee.dts
        let srcDuration = cloned.pointee.duration
        let pktSize = Int(cloned.pointee.size)
        let pktFlags = cloned.pointee.flags
        let isKey = (pktFlags & AV_PKT_FLAG_KEY) != 0

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
            // DrHurt's P8.1 MKV stalls at seg4 with "write failed
            // (-22)" (EINVAL), and the old diag couldn't tell us
            // which packet AVPlayer's downstream rejected. -22 from
            // mp4's av_interleaved_write_frame usually means
            // non-monotonic DTS or an unset PTS at a fragment
            // boundary; without source + rescaled timestamps in the
            // log the cause is invisible.
            let kind = toStreamIndex == videoOutputIndex ? "video" : "audio"
            EngineLog.emit(
                "[FMP4VideoMuxer] writePacket FAIL ret=\(ret) stream=\(kind)(\(toStreamIndex)) " +
                "src(pts=\(srcPts) dts=\(srcDts) dur=\(srcDuration) tb=\(sourceTb.num)/\(sourceTb.den)) " +
                "out(pts=\(cloned.pointee.pts) dts=\(cloned.pointee.dts) dur=\(cloned.pointee.duration) tb=\(outTb.num)/\(outTb.den)) " +
                "size=\(pktSize) key=\(isKey ? 1 : 0) flags=0x\(String(pktFlags, radix: 16))"
            )
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
            EngineLog.emit("[FMP4VideoMuxer] flushFragment FAIL ret=\(ret)")
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
    /// byte 3 = `d`). Returns nil if the input isn't exactly four
    /// ASCII characters.
    private static func mkTag(fromFourCC fourCC: String) -> UInt32? {
        let chars = Array(fourCC)
        guard chars.count == 4 else { return nil }
        var tag: UInt32 = 0
        for (i, ch) in chars.enumerated() {
            guard let ascii = ch.asciiValue else { return nil }
            tag |= UInt32(ascii) << (i * 8)
        }
        return tag
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
