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

    /// Last output-time-base DTS we successfully submitted to the
    /// muxer, indexed by stream output index. Used purely for
    /// failure-path diag: if seg N's first packet has out-DTS less
    /// than or equal to seg N-1's last out-DTS for the same stream,
    /// the mp4 muxer rejects with EINVAL because it enforces
    /// monotonic DTS even across `frag_custom` fragments. Seeing
    /// that side-by-side in the log tells us the segment-boundary
    /// detection is letting overlapping packets through.
    private var lastSubmittedDts: [Int: Int64] = [:]
    private var lastSubmittedPts: [Int: Int64] = [:]
    /// Monotonic counter of packets successfully submitted on each
    /// output stream. Resets only on muxer close. Combined with the
    /// segment provider's `seg{N}: v=X a=Y` line tells us how many
    /// packets the previous segment wrote before we hit the failure
    /// on the current one.
    private var submittedCount: [Int: Int] = [:]

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
    ///
    /// `logSummary` controls whether the structural box summary is
    /// emitted to the diagnostic log. Default true for the session-
    /// wide init.mp4 generation; per-fragment muxers in the stateless
    /// fragment path pass false because they reproduce identical
    /// init bytes for every segment and the log would spam ~1 line
    /// per fragment.
    func writeInitSegment(logSummary: Bool = true) throws -> Data {
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
        if logSummary {
            Self.logInitSegmentBoxSummary(init_)
        }
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
        // Box-presence flags as plain y/n. Interpretation depends on
        // the source: non-DV HEVC and DV P5 don't carry dvvC, DV P8+
        // doesn't carry dvcC, all are valid configurations. Callers
        // judge whether an absence is correct or unexpected; this
        // log just reports the structural truth.
        let summary = """
            [FMP4VideoMuxer] init.mp4 bytes=\(data.count) \
            sample-entry=\(entryStr) \
            ftyp=\(hasFtyp ? "y" : "n") \
            moov=\(hasMoov ? "y" : "n") \
            hvcC=\(hasHvcC ? "y" : "n") \
            dvcC=\(hasDvcC ? "y" : "n") \
            dvvC=\(hasDvvC ? "y" : "n")
            """
        EngineLog.emit(summary, category: .muxer)
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

        // Snapshot the rescaled timestamps BEFORE we call
        // av_interleaved_write_frame. Vincent's seg18 retest with
        // the split FAIL diag showed `out(pts=AV_NOPTS_VALUE)` for
        // a packet whose source PTS would rescale cleanly to a
        // valid Int64 against the logged tb_out=1/16000 — which
        // can only happen if `write_frame` clobbers the packet's
        // PTS/DTS on rejection. Reading them after the call gives
        // us the post-rejection state, not what we actually
        // submitted. Capture them here so the log reflects what
        // the muxer was asked to write.
        let outPts = cloned.pointee.pts
        let outDts = cloned.pointee.dts
        let outDuration = cloned.pointee.duration

        let prevDts = lastSubmittedDts[toStreamIndex] ?? Int64.min
        let prevPts = lastSubmittedPts[toStreamIndex] ?? Int64.min
        let prevCount = submittedCount[toStreamIndex] ?? 0

        let ret = av_interleaved_write_frame(ctx, cloned)
        if ret >= 0 {
            // Track per-stream last-submitted timestamps for the
            // next-packet failure diag. Only update on success so
            // a rejected packet's values don't poison subsequent
            // comparisons.
            lastSubmittedDts[toStreamIndex] = outDts
            lastSubmittedPts[toStreamIndex] = outPts
            submittedCount[toStreamIndex] = prevCount + 1
        }
        if ret < 0 {
            // DrHurt's P8.1 MKV stalls at seg4 with "write failed
            // (-22)" (EINVAL). Diag split into two lines so each
            // survives the overlay's lineLimit(1) truncation: the
            // first carries time bases + raw codes (the answer to
            // "did the rescale produce AV_NOPTS_VALUE?"), the
            // second carries the timestamp/size detail.
            let kind = toStreamIndex == videoOutputIndex ? "video" : "audio"
            let outIsNoPTS = outPts == Self.avNoPTS || outDts == Self.avNoPTS
            EngineLog.emit(
                "[FMP4VideoMuxer] writePacket FAIL #1 ret=\(ret) stream=\(kind)(\(toStreamIndex)) " +
                "tb_src=\(sourceTb.num)/\(sourceTb.den) tb_out=\(outTb.num)/\(outTb.den) " +
                "outNoPTS=\(outIsNoPTS ? "Y" : "n") size=\(pktSize) key=\(isKey ? 1 : 0)",
                category: .muxer
            )
            EngineLog.emit(
                "[FMP4VideoMuxer] writePacket FAIL #2 " +
                "src(pts=\(srcPts) dts=\(srcDts) dur=\(srcDuration)) " +
                "out(pts=\(outPts) dts=\(outDts) dur=\(outDuration)) " +
                "flags=0x\(String(pktFlags, radix: 16))",
                category: .muxer
            )
            // Cross-segment monotonicity diag. Compares the offending
            // packet's out-DTS to the last successfully-submitted
            // DTS on the same stream. If `dtsΔ <= 0` the muxer is
            // rejecting because of non-monotonic DTS — that's
            // exactly the case the mp4 muxer enforces across
            // fragments, regardless of `frag_custom` / cmaf.
            let dtsDelta = outDts &- prevDts
            EngineLog.emit(
                "[FMP4VideoMuxer] writePacket FAIL #3 " +
                "prevSubmitted(pts=\(prevPts) dts=\(prevDts) count=\(prevCount)) " +
                "dtsΔ=\(dtsDelta) " +
                "monotonic=\(outDts > prevDts ? "y" : "NO")",
                category: .muxer
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
            EngineLog.emit("[FMP4VideoMuxer] flushFragment FAIL ret=\(ret)", category: .muxer)
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

    // MARK: - Stateless fragment generation

    /// One-shot fragment muxing. Spins up a fresh `FMP4VideoMuxer`,
    /// writes the init segment (discarded — the session-wide init.mp4
    /// is captured once at session start and served separately), feeds
    /// the supplied packets, flushes the resulting `moof`+`mdat`, and
    /// tears the muxer down.
    ///
    /// Why this exists: the long-lived muxer model used in the
    /// original `HLSVideoEngine` enforces per-stream DTS monotonicity
    /// across every fragment of the session. That's a poor fit for an
    /// on-demand HLS server where AVPlayer can request segments in
    /// arbitrary order (scrub) and our IRAP-boundary detection isn't
    /// perfectly accurate. Cross-fragment DTS overlap then triggers
    /// EINVAL inside libavformat, which the stateful path papered over
    /// with pre-emptive + reactive muxer resets — each of which created
    /// fresh sequence-number resets and produced subtle playback
    /// hangs.
    ///
    /// Going stateless removes that whole class of failure. Each
    /// fragment is muxed by an isolated FFmpeg muxer instance with no
    /// recollection of prior fragments. `tfdt` carries the absolute
    /// decode time of the fragment's first sample, which is the only
    /// timing the AVPlayer-side timeline needs — mfhd.sequence_number
    /// resets to 1 every fragment, which AVPlayer treats as a per-
    /// fragment dedup hint per the HLS/CMAF spec (the long-lived path
    /// already verified empirically that AVPlayer doesn't enforce
    /// monotonicity across fragments).
    ///
    /// Per-fragment overhead: one extra `avformat_write_header` call
    /// (~1–3 ms on Apple TV) plus the muxer alloc + cleanup. Negligible
    /// against the demux+seek+packet-read cost already paid per
    /// fragment.
    ///
    /// Packet lifetimes: the caller retains ownership of the supplied
    /// packets. The muxer's `writePacket` clones internally, so the
    /// originals can be freed by the caller after this function
    /// returns. Packets are submitted to the muxer in the order given,
    /// per-stream (video first, then audio); FFmpeg's interleaver
    /// reorders them in the output `mdat` as needed.
    ///
    /// `audioOutputIndex` must be 1 when `audio` is non-nil, matching
    /// the stream creation order in `init(video:audio:)`.
    static func writeFragmentStateless(
        video: StreamConfig,
        audio: StreamConfig?,
        videoPackets: [UnsafeMutablePointer<AVPacket>],
        audioPackets: [UnsafeMutablePointer<AVPacket>]
    ) throws -> Data {
        let muxer = try FMP4VideoMuxer(video: video, audio: audio)
        defer { muxer.close() }

        // The init bytes here are discarded — the session-wide
        // init.mp4 captured once at session start is what the HLS
        // server hands to AVPlayer. Writing the header is just a
        // libavformat prerequisite for `av_write_frame` to accept
        // any packets. `logSummary: false` suppresses the per-
        // fragment box-summary log spam.
        _ = try muxer.writeInitSegment(logSummary: false)

        // Per-stream synthetic-DTS state. The FFmpeg mp4 muxer
        // enforces strict-monotonic DTS per stream; many real-world
        // MKV/HEVC sources don't carry DTS on every packet (the
        // first packet returned after `av_seek_frame` commonly has
        // `dts == AV_NOPTS_VALUE`, and some encoders simply omit
        // DTS in favour of PTS-only timing). The mov muxer falls
        // back to PTS in that case, but then a subsequent packet
        // whose real DTS happens to equal that prior PTS produces
        // a `non monotonically increasing dts` rejection — even
        // though the source timeline is perfectly valid.
        //
        // Sanitise here: ensure each packet's `dts` is set and
        // strictly greater than the previous packet's submitted
        // DTS on the same stream. We try to preserve the source
        // signal first (use the real `dts`, or fall back to `pts`)
        // and only bump by one tick when needed to break a tie.
        // Sample durations come from `packet.duration` (set by the
        // demuxer) and feed the mp4 muxer's `trun` per-sample
        // duration column, so the small DTS adjustments don't
        // affect decoded playback timing.
        var lastDtsByStream: [Int: Int64] = [:]

        func sanitiseDTS(_ pkt: UnsafeMutablePointer<AVPacket>, streamIndex: Int) {
            var dts = pkt.pointee.dts
            let pts = pkt.pointee.pts
            let prev = lastDtsByStream[streamIndex]

            if dts == avNoPTS {
                // Source didn't carry DTS. PTS is almost always
                // present; fall back to it. If even PTS is unset
                // (extreme edge case), use prev+1 as a degenerate
                // monotonic placeholder.
                dts = pts != avNoPTS ? pts : ((prev ?? 0) + 1)
            }
            if let p = prev, dts <= p {
                dts = p &+ 1
            }
            pkt.pointee.dts = dts
            lastDtsByStream[streamIndex] = dts
        }

        for pkt in videoPackets {
            sanitiseDTS(pkt, streamIndex: muxer.videoOutputIndex)
            try muxer.writePacket(pkt, toStreamIndex: muxer.videoOutputIndex)
        }
        if let audioIdx = muxer.audioOutputIndex {
            for pkt in audioPackets {
                sanitiseDTS(pkt, streamIndex: audioIdx)
                try muxer.writePacket(pkt, toStreamIndex: audioIdx)
            }
        }

        return try muxer.flushFragment()
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
