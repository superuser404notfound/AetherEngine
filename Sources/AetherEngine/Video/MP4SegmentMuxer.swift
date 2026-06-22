import Darwin
import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Long-lived fragmented-MP4 muxer driving the HLS-fMP4 segments for
/// one playback session. Replaces the libavformat `hls` muxer that
/// accumulated state across the session and caused the long-form 4K
/// HDR HEVC memory leak (the producer-restart diagnostic freed 840 MB
/// in one teardown).
///
/// Earlier iteration: per-segment fresh AVFormatContext. Memory leak
/// solved but produced A/V tfdt mismatches at fragment boundaries —
/// FLAC bridge emits packets at fixed 4096-sample (~85 ms) granularity
/// and matroska interleaves audio AHEAD of video, so the first audio
/// packet of each segment muxer landed ~160 ms BEFORE the video tfdt
/// of the same fragment. AVPlayer accepted the first few segments and
/// then froze with audio drop as drift accumulated. The mp4 muxer's
/// `av_interleaved_write_frame` queue handles cross-stream sync
/// internally; we lost it when we switched to per-segment.
///
/// Current architecture: ONE AVFormatContext for the whole session,
/// configured as a plain `mp4` muxer (not `hls` wrapper) with these
/// movflags:
///
///   +empty_moov         — combined with +delay_moov this means the
///                          moov is written WITHOUT per-sample data
///                          (which lives in fragments instead).
///   +default_base_moof  — relative offsets in tfhd (cleaner fmp4)
///   +frag_custom        — caller controls fragment cuts via
///                          `av_write_frame(ctx, nil)`. Packets enter
///                          via `av_interleaved_write_frame` and
///                          queue in libavformat's interleaver until
///                          cross-stream DTS ordering allows commit
///                          to `mov_write_packet`. At cut time we
///                          must drain the interleaver explicitly
///                          (see `cutFragmentForNextSegment`); the
///                          cut itself bypasses the interleaver and
///                          would otherwise leave still-buffered
///                          packets to spill into the next fragment.
///   +delay_moov         — defers writing the moov atom until the
///                          first `av_write_frame(ctx, nil)` call,
///                          AFTER packets have been queued via
///                          `writePacket`. This lets `mov_write_packet`
///                          run its codec-specific extradata
///                          population (`handle_eac3` for EAC3,
///                          equivalent for AC3) on actual packet
///                          bitstream BEFORE the sample-entry boxes
///                          (dec3 / dac3) are serialised into the
///                          moov. The matroska CodecPrivate for
///                          AC3 / EAC3 doesn't usually carry the
///                          pre-parsed bitstream info the mov muxer
///                          wants, so without delay_moov those
///                          sources fail write_header with -22 /
///                          "Cannot write moov atom before EAC3/AC3
///                          packets parsed", and stream-copy falls
///                          back to the FLAC bridge (losing Atmos
///                          JOC and burning decode→encode CPU).
///                          delay_moov plus libavformat's existing
///                          parsing recovers stream-copy for the
///                          full Atmos JOC chain.
///
///   (notably NOT: +dash, +frag_keyframe — +dash adds a session-long
///   sidx accumulator across fragments; +frag_keyframe would interfere
///   with our explicit fragment-cut control via av_write_frame(nil).)
///
/// Cut sequence: each call to `cutFragmentForNextSegment` first
/// drains libavformat's interleaver via
/// `av_interleaved_write_frame(ctx, nil)`, so any packets still
/// buffered there (waiting for cross-stream DTS catch-up) get
/// committed to mov_write_packet and end up in the segment being
/// cut. It then calls `av_write_frame(ctx, nil)` to trigger
/// `mov_flush_fragment`, which emits the moof+mdat. On the first
/// cut only there's a second `av_write_frame(ctx, nil)` (gated by
/// `moovFlushed`) to handle the +delay_moov wrinkle: depending on
/// interleaver state at the time, FFmpeg may have split the flush
/// across calls, writing the deferred ftyp+moov first and the
/// moof+mdat on the follow-up. When `mov_flush_fragment` already
/// wrote both atoms in the single call, the gated second call is a
/// safe no-op against an empty queue. Subsequent cuts are
/// single-call after the drain.
///
/// Output flow per session:
///
///   1. allocate ONE AVFormatContext (mp4 muxer)
///   2. add video + optional audio streams
///   3. avformat_write_header → emits ftyp + moov via avio callback
///   4. caller pumps packets via writePacket() — muxer queues them
///   5. at each segment boundary the caller calls
///      cutFragmentForNextSegment(_:) → muxer flushes the queued
///      packets as one moof+mdat via avio callback → splitter routes
///      the bytes to the current segment's POSIX file → fd is rotated
///      to the next segment's file
///   6. at session end: finalize() → final flush + write_trailer +
///      free_context
///
/// The `FragmentSplitter` parses the avio output stream and routes
/// the ftyp + moov portion to the init-handler callback (= init.mp4
/// content) and the per-fragment moof + mdat bytes to the currently-
/// open segment file. `mfra` at trailer is discarded.
///
/// AVPlayer compatibility: per Apple's HLS Authoring Spec, fMP4
/// segments need `moof + mdat` with `tfdt` carrying decode time, and
/// movie-fragment-relative addressing. No `styp` / `sidx` required.
final class MP4SegmentMuxer {

    // MARK: - Types

    /// Force color signaling fields on the output stream's codecpar
    /// after `avcodec_parameters_copy` and before `avformat_write_header`.
    /// Used for Dolby Vision Profile 5 sources whose SPS VUI omits the
    /// transfer characteristic and whose MP4 container has no `colr`
    /// atom: P5 is defined as IPT-PQ-c2 (BT.2020 / PQ / BT.2020-NCL,
    /// limited range), and the `dvcC` record alone implies that, but
    /// AVPlayer's DV decoder won't engage on a `dvh1` sample entry
    /// without an explicit `colr nclx` atom or PQ VUI. Setting these
    /// on the muxer's stream codecpar causes the mp4 muxer to write a
    /// `colr nclx 9/16/9` atom that AVPlayer reads as the canonical
    /// PQ signal.
    struct ColorOverride {
        let primaries: AVColorPrimaries
        let trc: AVColorTransferCharacteristic
        let space: AVColorSpace
        let range: AVColorRange
    }

    struct VideoConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Optional fourcc to set on the output stream's codec_tag.
        /// Used to force `hvc1` on HEVC (default is `hev1` which
        /// AVPlayer doesn't accept).
        let codecTagOverride: String?
        /// Drop `AV_PKT_DATA_DOVI_CONF` from the output stream's
        /// codecpar before `avformat_write_header`. Set when the
        /// engine is intentionally routing a Dolby Vision source as
        /// plain HEVC HDR10 (P7 on a non-DV panel; P8.2) so the mp4
        /// muxer doesn't emit a `dvcC` box inside an `hvc1` sample
        /// entry. VideoToolbox's HEVC decoder selection rejects that
        /// combo with `kVTVideoDecoderUnsupportedDataFormatErr`
        /// (-12906) because the dvcC advertises a DV profile the
        /// dvh1-less sample entry contradicts.
        /// Mutually exclusive with `rewriteDoviConfigTo81`.
        let stripDolbyVisionMetadata: Bool
        /// Rewrite the `dvcC` config record to a valid Profile 8.1
        /// (`dv_profile = 8`, `compat = 1`, `el_present = 0`) instead of
        /// stripping it. True for two routes, both on a DV-capable panel:
        /// HEVC P7 (the P7-to-8.1 live conversion, paired with the
        /// producer's per-packet RPU rewrite) and the malformed "P8.6"
        /// case (profile 8 carrying an invalid compat id for what is
        /// really an HDR10-base single-layer stream, where only the
        /// container record needs fixing). The muxer calls
        /// `rewriteDoviConfigToProfile81` in place before
        /// `avformat_write_header` so the container header carries a
        /// valid P8.1 `dvvC` box. Muxer-side this is the only DV-rewrite
        /// knob; the per-packet RPU conversion is gated separately in the
        /// producer.
        let rewriteDoviConfigTo81: Bool
        /// Optional color-signaling override. See `ColorOverride`.
        let colorOverride: ColorOverride?
        /// Optional replacement for the output stream's
        /// `codecpar.extradata` after `avcodec_parameters_copy`.
        /// Used when the source's hvcC carries only the configuration
        /// header (numOfArrays = 0) and parameter sets are in-band,
        /// so the engine has rebuilt a proper hvcC with VPS / SPS /
        /// PPS arrays for AVPlayer to build a CMVideoFormatDescription
        /// from. The mp4 muxer reads `codecpar.extradata` directly
        /// into the sample entry's `hvcC` / `avcC` box, so replacing
        /// the buffer here is enough to land the rebuilt configuration
        /// record in `init.mp4`.
        let extradataOverride: [UInt8]?

        init(
            codecpar: UnsafePointer<AVCodecParameters>,
            timeBase: AVRational,
            codecTagOverride: String?,
            stripDolbyVisionMetadata: Bool = false,
            rewriteDoviConfigTo81: Bool = false,
            colorOverride: ColorOverride? = nil,
            extradataOverride: [UInt8]? = nil
        ) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.codecTagOverride = codecTagOverride
            self.stripDolbyVisionMetadata = stripDolbyVisionMetadata
            self.rewriteDoviConfigTo81 = rewriteDoviConfigTo81
            self.colorOverride = colorOverride
            self.extradataOverride = extradataOverride
        }
    }

    struct AudioConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
    }

    /// Configuration for a single mov_text (tx3g) subtitle output stream.
    /// The muxer synthesises the stream entirely; no source codecpar is needed.
    struct SubtitleConfig {
        /// Time base for the subtitle stream. Spike-validated default: 1/1000
        /// (millisecond precision, sufficient for SRT/WebVTT cues).
        let timeBase: AVRational
        /// BCP-47 language tag (e.g. "en", "de", "en-US"). Converted to
        /// ISO 639-2/T via `iso639_2(fromBCP47:)` and written into the
        /// stream's metadata `language` key so QuickTime/AVFoundation can
        /// label the track in the media-selection menu. Nil = no language box.
        let language: String?

        init(
            timeBase: AVRational = AVRational(num: 1, den: 1000),
            language: String? = nil
        ) {
            self.timeBase = timeBase
            self.language = language
        }
    }

    enum MuxerError: Error, CustomStringConvertible {
        case allocFailed(code: Int32)
        case streamCreationFailed
        case copyParametersFailed(code: Int32)
        case avioAllocFailed
        case writeHeaderFailed(code: Int32)
        case openStagingFileFailed(errno: Int32)

        var description: String {
            switch self {
            case .allocFailed(let c): return "MP4SegmentMuxer: avformat_alloc_output_context2 failed (\(c))"
            case .streamCreationFailed: return "MP4SegmentMuxer: avformat_new_stream failed"
            case .copyParametersFailed(let c): return "MP4SegmentMuxer: avcodec_parameters_copy failed (\(c))"
            case .avioAllocFailed: return "MP4SegmentMuxer: avio_alloc_context failed"
            case .writeHeaderFailed(let c): return "MP4SegmentMuxer: avformat_write_header failed (\(c))"
            case .openStagingFileFailed(let e): return "MP4SegmentMuxer: open() staging file failed errno=\(e)"
            }
        }
    }

    // MARK: - State

    /// Index of the segment whose bytes are currently flowing into
    /// `fd`. The mp4 muxer is fragment-agnostic — it just emits
    /// moof+mdat blocks on `av_write_frame(ctx, nil)` calls. We track
    /// the index here and rotate `fd` between cuts so each fragment's
    /// bytes land in a separate file.
    private(set) var currentSegmentIndex: Int

    /// Cache session directory where staging files live. Same volume
    /// as the cache's adopt target so the rename is metadata-only.
    private let sessionDir: URL

    /// Current staging file's full path. Replaced at each fragment
    /// cut; the previous path is returned to the caller for cache
    /// adoption.
    private var currentStagingPath: URL

    /// Open POSIX file descriptor for the current segment's staging
    /// file. Closed + replaced at each fragment cut, closed for the
    /// final time in finalize().
    private var fd: Int32 = -1

    /// AVFormatContext for the mp4 muxer. ONE instance for the whole
    /// session — see class docstring for why per-segment was tried and
    /// reverted.
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    /// AVIO context attached to `ctx.pb`. Allocated in init, freed in
    /// cleanup(). The mp4 muxer writes through this context; bytes
    /// route through `mp4SegmentMuxerSinkWrite` → `splitter` → fd.
    private var pb: UnsafeMutablePointer<AVIOContext>?

    /// Latched once avformat_write_header succeeds and av_write_trailer
    /// becomes safe to call. Guards against double-trailer if the
    /// caller invokes finalize() after a header-write failure.
    private var headerWritten: Bool = false

    /// Per-output-stream final timestamp guard (strictly increasing dts,
    /// pts >= dts). A no-op for healthy content; rescues SSAI ad-boundary
    /// segments whose pts < dts would otherwise be dropped wholesale.
    private var timestampSanitizer = OutputTimestampSanitizer()

    /// Latched after the first `av_write_frame(ctx, NULL)` call,
    /// which is when the `+delay_moov` muxer writes the deferred
    /// ftyp + moov atoms. With delay_moov, the first cut may need a
    /// second `av_write_frame(NULL)` after the interleaver-drain +
    /// initial flush, because FFmpeg can split the work across calls:
    /// the first emits ftyp+moov (with valid `dec3` / `dac3`
    /// sample-entry boxes that `mov_write_packet` populated as
    /// packets were queued via `writePacket`), the second emits the
    /// actual moof+mdat for seg-0. Subsequent cuts skip the gated
    /// second call. See `cutFragmentForNextSegment` for the call site.
    private var moovFlushed: Bool = false

    /// Latched when rotating to the next segment's staging file failed.
    /// The muxer then has no open fd, the splitter discards every
    /// subsequent fragment byte, and the session cannot recover (the
    /// avformat context's fragment state is tied to the lost fd). The
    /// producer checks this right after each cut and ends the pump.
    private(set) var isWedged: Bool = false

    /// Muxer's chosen time_base for the video output stream, latched
    /// after avformat_write_header. The mp4 muxer rewrites the stream's
    /// time_base to its own auto-pick (usually 1/16000 for 24 fps
    /// video, 1/<sample rate> for audio); subsequent
    /// av_packet_rescale_ts calls target this time_base.
    private(set) var muxerVideoTimeBase: AVRational = AVRational(num: 1, den: 1)
    private(set) var muxerAudioTimeBase: AVRational = AVRational(num: 1, den: 1)
    /// Time base for the subtitle output stream, latched after
    /// `avformat_write_header`. Nil when no subtitle stream was requested.
    private(set) var muxerSubtitleTimeBase: AVRational = AVRational(num: 1, den: 1000)
    private let haveAudio: Bool

    /// Stream indices in the output (video always 0; audio 1 when present).
    let videoOutputStreamIndex: Int32 = 0
    let audioOutputStreamIndex: Int32 = 1

    /// Ordinal-to-muxer-stream-index map for the declared mov_text tracks.
    /// Entry N holds the libavformat stream index for the Nth subtitle track
    /// (ordinal matches the position in the `subtitles` array passed to
    /// `init`). Empty when no subtitle streams were configured. Indices are
    /// captured from `avformat_new_stream` and are never hardcoded because
    /// the value is dynamic (1 without audio, 2 with audio, then increments
    /// for each additional subtitle track).
    private(set) var subtitleOutputStreamIndices: [Int32] = []

    /// The FragmentSplitter that parses the avio output stream and
    /// routes header vs fragment bytes. Owned strongly here so its
    /// closures stay alive for the muxer's lifetime; the avio write
    /// callback recovers it via the pb opaque pointer.
    private let splitter: FragmentSplitter

    // MARK: - Init

    /// Build the session-long muxer, opening its first segment file.
    /// `onInitCaptured` fires once when the ftyp + moov bytes finish
    /// streaming through the avio buffer (= init.mp4 content).
    ///
    /// Subsequent fragment cuts re-route bytes via
    /// `cutFragmentForNextSegment(_:)`. The avformat context and avio
    /// context live for the whole session.
    ///
    /// Throws on any libavformat init failure or staging-file open
    /// failure. The instance is unusable after a throw.
    init(
        initialSegmentIndex: Int,
        sessionDir: URL,
        video: VideoConfig,
        audio: AudioConfig?,
        subtitles: [SubtitleConfig] = [],
        onInitCaptured: @escaping (Data) -> Void
    ) throws {
        self.currentSegmentIndex = initialSegmentIndex
        self.sessionDir = sessionDir
        self.haveAudio = audio != nil

        // Open the first segment's staging file. Subsequent segments
        // open their own files inside cutFragmentForNextSegment(_:).
        let firstPath = Self.stagingPath(forSegmentIndex: initialSegmentIndex,
                                         in: sessionDir)
        self.currentStagingPath = firstPath
        let firstFd = try Self.openPosix(path: firstPath)
        self.fd = firstFd

        // Mutable ref-typed counter is shared between the splitter's
        // non-self-capturing fragment-write closure and the muxer's
        // fragment-cut state. The closure can't capture `self`
        // directly (we're still inside init); the counter struct +
        // the muxer's fd-rotation logic both read / write through it.
        let counter = ByteCounter()
        counter.fd = firstFd
        self.byteCounter = counter

        // When subtitle streams are declared, movenc 62.x forces the first
        // subtitle tkhd to enabled=1 in the moov payload regardless of
        // disposition=0 or default_mode settings. Post-process the captured
        // init segment to clear the enabled bit on every subtitle tkhd before
        // the bytes reach the HLS init.mp4 handler. The patched bytes are
        // otherwise byte-for-byte identical to what movenc emits, and the
        // post-process is a no-op when no subtitle streams are declared.
        let subtitleCount = subtitles.count
        self.splitter = FragmentSplitter(
            onHeaderComplete: { initBytes in
                if subtitleCount > 0 {
                    let patched = Self.clearSubtitleTkhdEnabled(initBytes)
                    onInitCaptured(patched)
                } else {
                    onInitCaptured(initBytes)
                }
            },
            onFragmentBytes: { ptr, count in
                guard !counter.writeFailed, counter.fd >= 0 else { return }
                var written = 0
                while written < count {
                    let n = write(counter.fd, ptr.advanced(by: written), count - written)
                    if n < 0 {
                        let err = errno
                        if err == EINTR { continue }
                        counter.writeFailed = true
                        return
                    }
                    if n == 0 {
                        counter.writeFailed = true
                        return
                    }
                    written += n
                }
                counter.bytesWrittenCurrentSegment += count
                counter.lifetimeFragmentBytes += count
            }
        )

        // Allocate the mp4 muxer. URL string is a placeholder; the
        // muxer never opens a real file because we hand it our own
        // AVIO context attached directly to `ctx.pb` below.
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        let allocRet = avformat_alloc_output_context2(&ctxOut, nil, "mp4", "segment.m4s")
        guard allocRet == 0, let ctx = ctxOut else {
            close(firstFd)
            try? FileManager.default.removeItem(at: firstPath)
            throw MuxerError.allocFailed(code: allocRet)
        }
        self.formatContext = ctx

        // Pre-attach the AVIO context routing through our
        // FragmentSplitter. The mp4 muxer writes directly to `s->pb`;
        // unlike hlsenc it does NOT call `s->io_open` to allocate one
        // on demand, so we must have a real pb in place before
        // avformat_write_header runs.
        guard let pb = Self.allocAVIOContext(muxer: self) else {
            avformat_free_context(ctx)
            self.formatContext = nil
            close(firstFd)
            try? FileManager.default.removeItem(at: firstPath)
            throw MuxerError.avioAllocFailed
        }
        self.pb = pb
        ctx.pointee.pb = pb

        var capturedSubtitleIndices: [Int32] = []
        do {
            try Self.configureStreamsAndWriteHeader(
                ctx: ctx,
                video: video,
                audio: audio,
                subtitles: subtitles,
                capturedSubtitleIndices: &capturedSubtitleIndices
            )
        } catch {
            cleanup()
            throw error
        }
        self.headerWritten = true

        muxerVideoTimeBase = ctx.pointee.streams.advanced(by: 0).pointee!.pointee.time_base
        if haveAudio {
            muxerAudioTimeBase = ctx.pointee.streams.advanced(by: 1).pointee!.pointee.time_base
        }
        // Latch muxer-assigned time base from the first subtitle stream (all
        // subtitle streams share the same 1/1000 time base; Task 2 can extend
        // this to per-track if needed).
        if let firstSubIdx = capturedSubtitleIndices.first {
            muxerSubtitleTimeBase = ctx.pointee.streams.advanced(by: Int(firstSubIdx)).pointee!.pointee.time_base
        }
        subtitleOutputStreamIndices = capturedSubtitleIndices
    }

    /// Strong ref to the byte-counter shared with the splitter
    /// closures. Owned here so the closures' captured reference stays
    /// alive for the muxer's lifetime.
    private let byteCounter: ByteCounter

    // MARK: - Diagnostic probes

    /// Cumulative bytes ever emitted through the splitter's fragment
    /// callback over the muxer's lifetime. Used by the engine memory
    /// probe to compare libavformat's reported output volume vs.
    /// observed RSS growth. If lifetime bytes climb at ~observed leak
    /// rate, the muxer is retaining old fragment data; if much lower,
    /// the leak is elsewhere in libavformat (sample tables, frag_info)
    /// or outside the muxer entirely.
    var lifetimeFragmentBytesEmitted: Int { byteCounter.lifetimeFragmentBytes }

    /// Count of successful fragment cuts since init. Diverging from
    /// `producerPacketsWritten / pktsPerFragment` flags a flush stall.
    var fragmentCutCount: Int { byteCounter.fragmentCuts }

    /// Bytes the libavformat AVIO buffer is currently holding before
    /// flush. Bounded by our 65536-byte alloc; reported here mostly to
    /// confirm pb stays bounded vs. any imagined growth.
    var avioPendingBytes: Int {
        guard let pb = pb else { return 0 }
        let base = UInt(bitPattern: Int(bitPattern: OpaquePointer(pb.pointee.buffer)))
        let cur = UInt(bitPattern: Int(bitPattern: OpaquePointer(pb.pointee.buf_ptr)))
        guard cur >= base else { return 0 }
        return Int(cur - base)
    }

    // MARK: - Eager probe

    /// Dry-run the `avformat_write_header` path with the given codec
    /// configuration to detect mux failures the engine's audio cascade
    /// would otherwise miss. Returns 0 on success or a libavformat
    /// negative error code.
    ///
    /// Background: in the current architecture the real muxer is
    /// allocated lazily inside the producer's pump on the first
    /// keep-packet, well after `HLSVideoEngine.buildProducerWithAudioCascade`
    /// has returned its producer. If `avformat_write_header` would
    /// fail (typical case: EAC3-from-MKV without `dec3` extradata,
    /// for which the mp4 muxer returns -22 / "Cannot write moov atom
    /// before EAC3 packets parsed"), the cascade never sees the error
    /// and never falls back to the FLAC bridge. The session dies
    /// before the first segment.
    ///
    /// This probe runs the same `avformat_alloc_output_context2` →
    /// add streams → `avformat_write_header` sequence with the same
    /// movflags, but routes the bytes to a discarded in-memory AVIO
    /// buffer. No filesystem side effects, no segment files, no
    /// long-lived state.
    static func probeWriteHeader(
        video: VideoConfig,
        audio: AudioConfig?,
        subtitles: [SubtitleConfig] = []
    ) -> Int32 {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        let allocRet = avformat_alloc_output_context2(&ctxOut, nil, "mp4", "probe.m4s")
        guard allocRet == 0, let ctx = ctxOut else {
            return allocRet
        }
        defer { avformat_free_context(ctx) }

        // In-memory AVIO sink. avio_open_dyn_buf returns a context
        // whose write callback appends to an internal buffer; we
        // discard the buffer at the end so no bytes survive the probe.
        var pb: UnsafeMutablePointer<AVIOContext>?
        let avioRet = avio_open_dyn_buf(&pb)
        guard avioRet >= 0, let pbCtx = pb else {
            return avioRet
        }
        ctx.pointee.pb = pbCtx
        defer {
            var bufPtr: UnsafeMutablePointer<UInt8>?
            _ = avio_close_dyn_buf(pbCtx, &bufPtr)
            if bufPtr != nil {
                av_free(bufPtr)
            }
        }

        var unused: [Int32] = []
        do {
            try Self.configureStreamsAndWriteHeader(
                ctx: ctx,
                video: video,
                audio: audio,
                subtitles: subtitles,
                capturedSubtitleIndices: &unused
            )
            return 0
        } catch MuxerError.copyParametersFailed(let code) {
            return code
        } catch MuxerError.writeHeaderFailed(let code) {
            return code
        } catch {
            return -1
        }
    }

    /// Stream setup + header write shared by the session muxer init and
    /// `probeWriteHeader`. Single source of truth on purpose: any drift
    /// between the two would let the probe pass while the real muxer
    /// fails (or vice versa), which is exactly the failure mode the
    /// probe exists to prevent.
    ///
    /// When `subtitles` is non-empty, one mov_text (tx3g) stream is added
    /// per entry, in order, after the audio stream. Each stream's
    /// `avformat_new_stream`-assigned index is appended to
    /// `capturedSubtitleIndices` so the caller can latch the ordinal map
    /// into `subtitleOutputStreamIndices` without hardcoding.
    private static func configureStreamsAndWriteHeader(
        ctx: UnsafeMutablePointer<AVFormatContext>,
        video: VideoConfig,
        audio: AudioConfig?,
        subtitles: [SubtitleConfig],
        capturedSubtitleIndices: inout [Int32]
    ) throws {
        // strict=-2 lets the mp4 muxer write Dolby Vision atoms (dvcC,
        // dvvC) and other non-strict-ISOBMFF extensions when the source
        // codecpar carries DV side data. Matches the prior hls-path
        // setting; mp4 muxer respects the same compliance level.
        ctx.pointee.strict_std_compliance = -2

        // Video stream.
        guard let videoStream = avformat_new_stream(ctx, nil) else {
            throw MuxerError.streamCreationFailed
        }
        let vCopy = avcodec_parameters_copy(videoStream.pointee.codecpar, video.codecpar)
        guard vCopy >= 0 else {
            throw MuxerError.copyParametersFailed(code: vCopy)
        }
        videoStream.pointee.time_base = video.timeBase
        if let override = video.codecTagOverride,
           let tag = Self.mkTag(fromFourCC: override) {
            videoStream.pointee.codecpar.pointee.codec_tag = tag
        }
        if video.rewriteDoviConfigTo81 {
            Self.rewriteDoviConfigToProfile81(videoStream.pointee.codecpar)
        } else if video.stripDolbyVisionMetadata {
            Self.stripDolbyVisionSideData(videoStream.pointee.codecpar)
        }
        if let co = video.colorOverride {
            videoStream.pointee.codecpar.pointee.color_primaries = co.primaries
            videoStream.pointee.codecpar.pointee.color_trc = co.trc
            videoStream.pointee.codecpar.pointee.color_space = co.space
            videoStream.pointee.codecpar.pointee.color_range = co.range
        }
        if let extradata = video.extradataOverride {
            Self.replaceExtradata(videoStream.pointee.codecpar, with: extradata)
        }
        // Audio stream (optional).
        if let audio = audio {
            guard let audioStream = avformat_new_stream(ctx, nil) else {
                throw MuxerError.streamCreationFailed
            }
            let aCopy = avcodec_parameters_copy(audioStream.pointee.codecpar, audio.codecpar)
            guard aCopy >= 0 else {
                throw MuxerError.copyParametersFailed(code: aCopy)
            }
            audioStream.pointee.time_base = audio.timeBase
        }

        // Subtitle streams (one per entry in `subtitles`). Declared after
        // audio so their stream indices are dynamic: first subtitle gets
        // index 1 without audio, 2 with audio, etc. Each entry's
        // avformat_new_stream-assigned index is appended to
        // capturedSubtitleIndices so the caller can build the ordinal map.
        //
        // Spike-verified disposition: set to 0 (no AV_DISPOSITION_DEFAULT)
        // so the mov muxer writes a tkhd with the enabled flag CLEAR, which
        // causes ffprobe to report disposition:default=0. AVFoundation then
        // derives defaultOption=nil on the legible AVMediaSelectionGroup so
        // the host can select the track explicitly without auto-display.
        // (When disposition includes AV_DISPOSITION_DEFAULT the sole subtitle
        // track becomes the defaultOption and auto-displays, causing double
        // subtitles with the host-rendered inline track.)
        //
        // NOTE: movenc in libavformat 62.x still forces `enabled=1` on the
        // first subtitle tkhd regardless of disposition=0 and even when
        // default_mode=infer_no_subs or passthrough is set. The muxer-level
        // knob is therefore NOT sufficient. The init-segment bytes are
        // post-processed in `clearSubtitleTkhdEnabled(_:)` to clear the
        // enabled bit directly in the moov payload before the bytes are
        // handed to the caller. That post-process is applied inside the
        // `onHeaderComplete` closure below when subtitle streams are present.
        for cfg in subtitles {
            guard let subStream = avformat_new_stream(ctx, nil) else {
                throw MuxerError.streamCreationFailed
            }
            subStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            subStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_MOV_TEXT
            subStream.pointee.time_base = cfg.timeBase
            // Spike-verified: clear AV_DISPOSITION_DEFAULT so the tkhd
            // enabled flag stays clear and AVFoundation does not auto-select.
            subStream.pointee.disposition = 0
            // Write ISO 639-2/T language tag into the stream metadata so
            // AVFoundation can label the track in the media-selection menu.
            if let iso = iso639_2(fromBCP47: cfg.language) {
                iso.withCString { cStr in
                    _ = av_dict_set(&subStream.pointee.metadata, "language", cStr, 0)
                }
            }
            capturedSubtitleIndices.append(subStream.pointee.index)
        }

        // Movflags: the leak-free trio. See class docstring.
        // +frag_custom puts fragment cuts under explicit caller control
        // via av_write_frame(ctx, nil); packets enter through
        // av_interleaved_write_frame and queue in libavformat's
        // interleaver until cross-stream DTS ordering allows commit.
        // Note that the cut bypasses that buffer — cutFragmentForNextSegment
        // drains it via av_interleaved_write_frame(ctx, nil) first so
        // the trailing packets land in the segment being cut, not the
        // next one.
        var opts: OpaquePointer? = nil
        defer { av_dict_free(&opts) }
        av_dict_set(&opts, "movflags", "+empty_moov+default_base_moof+frag_custom+delay_moov", 0)
        // No edit lists in the moov. With delay_moov the mov muxer
        // derives an empty-edit from the FIRST packet's timestamp,
        // which on a producer restart is the restart anchor (field
        // evidence: elst.segment_duration == 280280 after a seek to
        // segment 28). That makes init.mp4 position-DEPENDENT, but
        // AVPlayer fetches EXT-X-MAP exactly once per session, so
        // every post-restart fragment then plays against a stale edit
        // list: post-scrub lipsync drift and timeline jumps. Position
        // belongs exclusively in the fragments' tfdt (absolute output
        // timeline, both tracks), which also preserves the relative
        // head-of-stream A/V offset. With edit lists off, the moov is
        // restart-invariant, matching the SegmentCache's pinned-init
        // assumption.
        av_dict_set(&opts, "use_editlist", "0", 0)
        // Prevent the mp4 muxer from auto-marking subtitle tracks as
        // default. ffmpeg's movenc default_mode=infer would set tkhd
        // enabled on the only subtitle stream even when disposition=0,
        // causing AVFoundation to derive a non-nil defaultOption and
        // auto-display the track. infer_no_subs skips that inference
        // for subtitle tracks while still marking audio/video defaults
        // normally. Guarded to only apply when subtitle streams are
        // present to avoid touching video/audio-only session behaviour.
        // Note: as of libavformat 62.x infer_no_subs is insufficient
        // empirically (first subtitle still gets enabled=1 in tkhd).
        // The byte-level post-process in clearSubtitleTkhdEnabled handles
        // the remaining cases that the movenc option leaves uncorrected.
        if !subtitles.isEmpty {
            av_dict_set(&opts, "default_mode", "infer_no_subs", 0)
        }

        let ret = avformat_write_header(ctx, &opts)
        guard ret >= 0 else {
            throw MuxerError.writeHeaderFailed(code: ret)
        }
    }

    // MARK: - Pump-side API

    /// Convert seconds to integer ticks in a given time base.
    /// Pure helper: `seconds * timescale` rounded to the nearest tick.
    /// Used to map AVPlayer-axis cue times onto the subtitle stream's
    /// 1/1000 time base before building an AVPacket.
    static func subtitleTicks(forSeconds s: Double, timescale: Int32) -> Int64 {
        Int64((s * Double(timescale)).rounded())
    }

    /// BCP-47 two-letter to ISO 639-2/T three-letter language code mapping
    /// for common languages. Reused by `iso639_2(fromBCP47:)` without
    /// re-allocation on every call.
    private static let bcp47ToISO639_2: [String: String] = [
        "en": "eng", "de": "deu", "ja": "jpn", "fr": "fra",
        "es": "spa", "it": "ita", "pt": "por", "ru": "rus",
        "zh": "zho", "ko": "kor", "nl": "nld", "pl": "pol",
        "sv": "swe", "da": "dan", "no": "nor", "fi": "fin",
        "tr": "tur", "ar": "ara", "cs": "ces", "el": "ell",
        "he": "heb", "hi": "hin", "th": "tha", "uk": "ukr",
    ]

    /// Map a BCP-47 language tag to an ISO 639-2/T three-letter code
    /// suitable for the QuickTime `language` metadata key (e.g. "eng",
    /// "deu"). Returns nil when `tag` is nil or not in the known table,
    /// signaling "no language box" to the caller.
    ///
    /// Mapping rules:
    /// - Strip any region subtag after the first "-" (en-US -> "en").
    /// - Look up the base tag in the static two-letter -> three-letter table.
    /// - A tag that is already three lowercase letters is passed through
    ///   as-is (caller already has an ISO 639-2 code).
    /// - Unknown tags return nil.
    static func iso639_2(fromBCP47 tag: String?) -> String? {
        guard let tag else { return nil }
        // Strip region subtag: "en-US" -> "en".
        let base = tag.split(separator: "-", maxSplits: 1).first.map(String.init) ?? tag
        let lower = base.lowercased()
        // Pass through already-3-letter codes unchanged.
        if lower.count == 3 && lower.allSatisfy(\.isLetter) {
            return lower
        }
        return bcp47ToISO639_2[lower]
    }

    /// Write one mov_text sample into the muxer's subtitle stream.
    ///
    /// `payload` is the `[uint16 BE len][UTF-8]` body produced by
    /// `MovTextSampleBuilder`. `trackOrdinal` is the zero-based index into
    /// the `subtitles` array passed to `init` (matches the source track's
    /// ordinal from the producer). `ptsSeconds` and `durationSeconds` are
    /// on the AVPlayer timeline axis (same as the cue times stored in
    /// `NativeSubtitleCueStore`).
    ///
    /// No-op when `trackOrdinal` is out of range (no subtitle streams, or
    /// ordinal beyond the declared count), which preserves byte-identical
    /// output for all existing video/audio-only sessions.
    ///
    /// AVPacket lifetime: `trackedPacketAlloc` + `av_new_packet` allocate
    /// the struct and its ref-counted data buffer. `av_interleaved_write_frame`
    /// (called via `writePacket`) takes ownership of the buffer reference
    /// (it calls `av_packet_unref` internally), zeroing `data`/`size` on
    /// the packet but leaving the struct alive. `trackedPacketFree` in the
    /// defer then frees the now-empty struct. This mirrors the pattern in
    /// `SoftwarePlaybackHost.enqueue(packet:)` (line ~721).
    func writeSubtitleSample(
        _ payload: Data,
        trackOrdinal: Int,
        ptsSeconds: Double,
        durationSeconds: Double
    ) {
        guard trackOrdinal < subtitleOutputStreamIndices.count else { return }
        let idx = subtitleOutputStreamIndices[trackOrdinal]
        let timescale = muxerSubtitleTimeBase.den
        let ptsTicks = Self.subtitleTicks(forSeconds: ptsSeconds, timescale: timescale)
        let durTicks = Self.subtitleTicks(forSeconds: durationSeconds, timescale: timescale)

        guard let p = trackedPacketAlloc() else { return }
        var pkt: UnsafeMutablePointer<AVPacket>? = p
        defer { trackedPacketFree(&pkt) }

        guard av_new_packet(p, Int32(payload.count)) >= 0 else { return }
        payload.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = p.pointee.data {
                memcpy(dst, src, payload.count)
            }
        }
        p.pointee.pts = ptsTicks
        p.pointee.dts = ptsTicks
        p.pointee.duration = durTicks
        p.pointee.stream_index = idx
        _ = writePacket(p)
    }

    /// Write one packet via av_interleaved_write_frame. Caller has
    /// already rescaled the packet's pts/dts to the muxer's time_base
    /// (use `muxerVideoTimeBase` / `muxerAudioTimeBase` as targets)
    /// and set the correct output `stream_index`.
    ///
    /// Returns the libavformat return code, but in practice the only
    /// reasonable response to a non-zero return is to log and continue;
    /// the muxer state may be inconsistent but we'd tear it down soon
    /// anyway at the next segment boundary.
    @discardableResult
    func writePacket(_ packet: UnsafeMutablePointer<AVPacket>) -> Int32 {
        guard let ctx = formatContext else { return -1 }
        // Final-stage guard: enforce strictly-increasing dts and pts >= dts
        // per output stream. Healthy content is unchanged; this only fires
        // for server-side-ad-insertion boundaries (Pluto/FAST) whose
        // creatives restart the source clock and trail pts behind dts,
        // which otherwise makes the muxer drop every audio packet of the
        // ad and stalls AVPlayer. See OutputTimestampSanitizer.
        let clean = timestampSanitizer.sanitize(
            streamIndex: packet.pointee.stream_index,
            pts: packet.pointee.pts,
            dts: packet.pointee.dts
        )
        packet.pointee.pts = clean.pts
        packet.pointee.dts = clean.dts
        // av_interleaved_write_frame instead of av_write_frame.
        // Tested av_write_frame against av_interleaved as a leak
        // hypothesis (the latter buffers packets in a PacketListEntry
        // linked list until cross-stream interleave is possible);
        // empirically had no impact on the 8 MB/s mallocMB growth
        // before the URLSession force-copy landed. Reverted to the
        // interleaved variant because (a) it's the safer default for
        // cross-stream DTS monotonicity and (b) leaves audio + video
        // re-ordering to libavformat's tested code path rather than
        // relying on matroska always serving us perfect chronological
        // order. The actual leak ended up being upstream of the muxer
        // (Foundation Data(d) silently aliasing dispatch_data backing),
        // confirmed by the force-copy fix in AVIOReader.
        return av_interleaved_write_frame(ctx, packet)
    }

    /// Trigger a fragment cut, finalize the just-completed segment's
    /// file, and rotate `fd` to a freshly-opened file for `nextIdx`.
    ///
    /// Sequence:
    ///   1. Drain libavformat's interleaver with
    ///      `av_interleaved_write_frame(ctx, nil)` so packets still
    ///      buffered there (waiting for cross-stream DTS catch-up) get
    ///      committed to `mov_write_packet` and end up in the
    ///      just-completed segment instead of the next one. Then call
    ///      `av_write_frame(ctx, nil)` to trigger `mov_flush_fragment`
    ///      under the `+frag_custom` path, which emits one moof+mdat
    ///      block. Bytes flow through the avio callback →
    ///      FragmentSplitter → current `fd`.
    ///   2. After the flush returns, the current segment is fully
    ///      written. We close `fd`, capture its byte count and path,
    ///      and reset the counter.
    ///   3. Open a fresh staging file for `nextIdx`, set it as the
    ///      new `fd`. Subsequent packet writes accumulate inside the
    ///      muxer until the next cut.
    ///
    /// Returns `(path, bytes)` for the segment that was just
    /// completed (= the one whose index was `currentSegmentIndex`
    /// before this call), or `nil` if any write failed or the new
    /// file couldn't be opened. On a nil return the muxer state may
    /// be inconsistent; the caller should bail.
    ///
    /// First-cut wrinkle with `+delay_moov`: the deferred ftyp+moov
    /// atoms are emitted by the first `av_write_frame(nil)` call.
    /// The FragmentSplitter routes those bytes to `onHeaderComplete`
    /// (= init.mp4), so the segment file's byte counter sees nothing
    /// from that call. A second `av_write_frame(nil)` call (gated by
    /// `!moovFlushed`) flushes the actual moof+mdat for seg-0, which
    /// the splitter routes to `onFragmentBytes`. When FFmpeg's
    /// `mov_flush_fragment` writes both moov AND moof+mdat in a
    /// single call, the gated second call is a safe no-op against an
    /// empty queue.
    func cutFragmentForNextSegment(_ nextIdx: Int) -> (path: URL, bytesWritten: Int)? {
        guard let ctx = formatContext, headerWritten, fd >= 0 else { return nil }

        // 1. Drain libavformat's interleaver, then flush the queued
        //    fragment via the mp4 muxer's frag_custom path. Bytes for
        //    the just-completed segment are written to the current
        //    `fd` via the avio callback.
        //
        //    The drain is the key step. `writePacket` uses
        //    `av_interleaved_write_frame`, which buffers packets in
        //    libavformat's interleaver until cross-stream DTS ordering
        //    allows commit to mov_write_packet. Plain
        //    `av_write_frame(ctx, nil)` triggers mov_flush_fragment
        //    but bypasses that buffer, so packets still held there
        //    (typical when audio is ahead of video and the interleaver
        //    is waiting for video to catch up) carry over into the
        //    next fragment instead of landing in the one we're cutting.
        //    That manifested as ~4 trailing AC-3 frames missing from
        //    the end of each segment's audio for matroska sources
        //    with audio-leads-video interleave, so the segment's
        //    actual audio coverage fell ~120 ms short of its declared
        //    `#EXTINF`. Calling `av_interleaved_write_frame(ctx, nil)`
        //    first commits the buffered packets, then the subsequent
        //    `av_write_frame(ctx, nil)` emits the moof+mdat for them.
        _ = av_interleaved_write_frame(ctx, nil)
        _ = av_write_frame(ctx, nil)
        if !moovFlushed {
            moovFlushed = true
            _ = av_write_frame(ctx, nil)
        }

        // 2. Snapshot the completed segment + reset counters.
        let completedPath = currentStagingPath
        let completedBytes = byteCounter.bytesWrittenCurrentSegment
        let completedFailed = byteCounter.writeFailed
        close(fd)
        fd = -1
        byteCounter.fd = -1
        byteCounter.bytesWrittenCurrentSegment = 0

        if completedFailed || completedBytes == 0 {
            try? FileManager.default.removeItem(at: completedPath)
            return nil
        }

        byteCounter.fragmentCuts += 1

        // 3. Rotate to the next segment's staging file.
        let nextPath = Self.stagingPath(forSegmentIndex: nextIdx, in: sessionDir)
        do {
            let nextFd = try Self.openPosix(path: nextPath)
            self.fd = nextFd
            self.currentStagingPath = nextPath
            self.currentSegmentIndex = nextIdx
            byteCounter.fd = nextFd
        } catch {
            // Failed to open the next file: the muxer can't keep
            // producing. Latch isWedged so the producer ends the pump at
            // THIS cut. Returning only the completed tuple (pre-fix
            // behavior) made the caller treat the cut as fully
            // successful; with fd == -1 the splitter then silently
            // discarded every fragment byte of the next segment and the
            // pump only failed one cut later, with no log at the actual
            // failure site.
            EngineLog.emit(
                "[MP4SegmentMuxer] open next staging file seg-\(nextIdx) FAILED: \(error)",
                category: .session
            )
            isWedged = true
            return (path: completedPath, bytesWritten: completedBytes)
        }

        return (path: completedPath, bytesWritten: completedBytes)
    }

    /// Final teardown at session end. Triggers one last fragment cut
    /// for whatever's queued (= the final segment), writes the mp4
    /// trailer (which may emit a small mfra the splitter discards),
    /// closes the current fd, and frees the format context + AVIO.
    ///
    /// Returns the final segment's `(path, bytes)` for cache adoption,
    /// or nil on any failure.
    func finalize() -> (path: URL, bytesWritten: Int)? {
        defer { cleanup() }

        guard let ctx = formatContext, headerWritten else {
            if fd >= 0 { close(fd); fd = -1 }
            try? FileManager.default.removeItem(at: currentStagingPath)
            return nil
        }

        // Final fragment flush + trailer. Both write through the
        // avio callback → splitter → current fd.
        _ = av_write_frame(ctx, nil)
        _ = av_write_trailer(ctx)

        let finalPath = currentStagingPath
        let finalBytes = byteCounter.bytesWrittenCurrentSegment
        let finalFailed = byteCounter.writeFailed

        if fd >= 0 {
            close(fd)
            fd = -1
            byteCounter.fd = -1
        }

        if finalFailed || finalBytes == 0 {
            try? FileManager.default.removeItem(at: finalPath)
            return nil
        }
        return (path: finalPath, bytesWritten: finalBytes)
    }

    // MARK: - Path helpers

    /// Staging filename for a segment index. Lives under the cache's
    /// session directory so the cache adopt is a metadata-only rename.
    private static func stagingPath(forSegmentIndex idx: Int, in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent(
            "staging-seg-\(idx)-\(UUID().uuidString.prefix(8)).tmp"
        )
    }

    /// Open a staging file via POSIX `creat(2)`. Throws if the open
    /// fails (parent dir not writable, disk full, etc).
    private static func openPosix(path: URL) throws -> Int32 {
        let cPath = path.withUnsafeFileSystemRepresentation { ptr -> [CChar] in
            guard let p = ptr else { return [] }
            var arr = [CChar]()
            var i = 0
            while p[i] != 0 { arr.append(p[i]); i += 1 }
            arr.append(0)
            return arr
        }
        guard !cPath.isEmpty else {
            throw MuxerError.openStagingFileFailed(errno: EINVAL)
        }
        let fd = cPath.withUnsafeBufferPointer { buf -> Int32 in
            creat(buf.baseAddress, 0o644)
        }
        guard fd >= 0 else {
            throw MuxerError.openStagingFileFailed(errno: errno)
        }
        return fd
    }

    // MARK: - Internal cleanup

    /// Free the format context + the AVIO context attached to its
    /// `pb`. The avio buffer (`pb->buffer`) was allocated via
    /// `av_malloc` and `avio_context_free` does NOT free it, so we
    /// drop that explicitly first. Safe to call multiple times.
    private func cleanup() {
        if let ctx = formatContext {
            // Flush + free the AVIO context. The mp4 muxer's
            // write_trailer should already have flushed via avio_flush
            // (or our writePacket path), but call it defensively in
            // case the muxer is being torn down mid-segment after a
            // header-write failure.
            if let pb = ctx.pointee.pb {
                avio_flush(pb)
                // Free the avio buffer (separate alloc from the
                // AVIOContext struct itself).
                if pb.pointee.buffer != nil {
                    withUnsafeMutablePointer(to: &pb.pointee.buffer) { bufRef in
                        bufRef.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { raw in
                            av_freep(UnsafeMutableRawPointer(raw))
                        }
                    }
                }
                var pbVar: UnsafeMutablePointer<AVIOContext>? = pb
                avio_context_free(&pbVar)
                ctx.pointee.pb = nil
            }
            avformat_free_context(ctx)
            formatContext = nil
        }
    }

    deinit {
        if fd >= 0 {
            close(fd)
        }
        // Free the AVFormatContext / AVIOContext / avio buffer too. The
        // producer always finalize()s before dropping the reference, so
        // this is a safety net for any future early-release path; without
        // it those allocations (incl. the 64 KB avio buffer) would leak.
        cleanup()
    }

    // MARK: - AVIO

    /// Allocate the AVIO context the mp4 muxer writes through. The
    /// muxer accesses `s->pb` directly (it never calls `s->io_open`,
    /// unlike hlsenc's wrap), so this gets attached to
    /// `ctx.pointee.pb` before `avformat_write_header`.
    fileprivate static func allocAVIOContext(muxer: MP4SegmentMuxer) -> UnsafeMutablePointer<AVIOContext>? {
        let bufSize: Int32 = 65536
        guard let raw = av_malloc(Int(bufSize)) else { return nil }
        let buf = raw.assumingMemoryBound(to: UInt8.self)
        let opaque = Unmanaged.passUnretained(muxer).toOpaque()
        guard let pb = avio_alloc_context(
            buf,
            bufSize,
            /* write_flag */ 1,
            opaque,
            nil,
            mp4SegmentMuxerSinkWrite,
            nil
        ) else {
            av_free(raw)
            return nil
        }
        // seekable=0: the mov muxer with +empty_moov+frag_custom is
        // pure-forward writing, never asks for size or seeks back.
        // (Tried seekable=AVIO_SEEKABLE_NORMAL + stub seek as a leak
        // hypothesis; had no impact on memory growth.)
        pb.pointee.seekable = 0
        return pb
    }

    /// Receive a chunk of muxer output. Routes through the
    /// FragmentSplitter so init bytes land in `onInitCaptured` and
    /// fragment bytes land in the staging POSIX file.
    fileprivate func receive(_ buf: UnsafePointer<UInt8>, count: Int) {
        splitter.feed(buf, count: count)
    }

    // MARK: - Helpers

    /// Walk the moov box in `initData` and clear the `enabled` flag (bit 0
    /// of the 24-bit tkhd flags field) on every subtitle trak.
    ///
    /// Background: libavformat's movenc forces `enabled=1` on the first
    /// subtitle tkhd in libavformat 62.x regardless of the stream's
    /// `disposition` field or the `default_mode` option. AVFoundation
    /// treats a `tkhd` with `enabled=1` as `defaultOption` on the legible
    /// `AVMediaSelectionGroup`, which auto-displays the track without the
    /// host selecting it. Clearing the bit here (after write_header but
    /// before the bytes leave the muxer) is the only reliable fix.
    ///
    /// Algorithm:
    ///   1. Walk top-level boxes to find `moov`.
    ///   2. Inside `moov`, enumerate `trak` children.
    ///   3. For each `trak`, scan its children for `tkhd` and for
    ///      `mdia > hdlr` to read the handler type.
    ///   4. If the handler type is `sbtl` or `text` (subtitle), clear
    ///      bit 0 of the tkhd flags field (bytes [9..11] of the tkhd body).
    ///
    /// The patched bytes are otherwise byte-identical to the original.
    /// No-op when the moov cannot be located (malformed init segment).
    static func clearSubtitleTkhdEnabled(_ initData: Data) -> Data {
        var bytes = initData
        let count = bytes.count

        // Inline big-endian UInt32 reader. Uses byte-by-byte assembly to
        // avoid alignment faults on Data buffers that are not 4-byte aligned.
        func readU32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= count else { return nil }
            return bytes.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> UInt32 in
                let b0 = UInt32(ptr[offset])
                let b1 = UInt32(ptr[offset + 1])
                let b2 = UInt32(ptr[offset + 2])
                let b3 = UInt32(ptr[offset + 3])
                return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            }
        }

        // Walk top-level boxes to find moov.
        var pos = 0
        var moovStart = -1
        var moovEnd = -1
        while pos + 8 <= count {
            guard let size32 = readU32(pos) else { break }
            let boxSize: Int
            if size32 == 1 {
                // Extended 64-bit size. Read 8 more bytes.
                guard pos + 16 <= count,
                      let hi = readU32(pos + 8), let lo = readU32(pos + 12)
                else { break }
                boxSize = Int((UInt64(hi) << 32) | UInt64(lo))
            } else if size32 == 0 {
                boxSize = count - pos  // box extends to EOF
            } else {
                boxSize = Int(size32)
            }
            guard boxSize >= 8, pos + boxSize <= count else { break }
            let name = bytes[pos + 4 ..< pos + 8]
            if name == Data([0x6d, 0x6f, 0x6f, 0x76]) { // "moov"
                moovStart = pos + 8  // skip size+name
                moovEnd   = pos + boxSize
                break
            }
            pos += boxSize
        }
        guard moovStart >= 0 else { return bytes }  // no moov found

        // Walk trak children of moov.
        pos = moovStart
        while pos + 8 <= moovEnd {
            guard let size32 = readU32(pos) else { break }
            let boxSize = size32 == 0 ? (moovEnd - pos) : Int(size32)
            guard boxSize >= 8, pos + boxSize <= moovEnd else { break }
            let name = bytes[pos + 4 ..< pos + 8]
            if name == Data([0x74, 0x72, 0x61, 0x6b]) { // "trak"
                let trakStart = pos + 8
                let trakEnd   = pos + boxSize

                // Collect tkhd offset and hdlr handler type from this trak.
                var tkhdFlagsOffset = -1   // byte offset of the 3-byte flags inside tkhd
                var handlerType: Data? = nil

                var trakPos = trakStart
                while trakPos + 8 <= trakEnd {
                    guard let sz32 = readU32(trakPos) else { break }
                    let sz = sz32 == 0 ? (trakEnd - trakPos) : Int(sz32)
                    guard sz >= 8, trakPos + sz <= trakEnd else { break }
                    let boxName = bytes[trakPos + 4 ..< trakPos + 8]

                    if boxName == Data([0x74, 0x6b, 0x68, 0x64]) { // "tkhd"
                        // tkhd layout: [size 4B][name 4B][version 1B][flags 3B][...]
                        // flags offset = trakPos + 8 (skip size+name) + 1 (version) = trakPos + 9
                        let fOffset = trakPos + 9
                        if fOffset + 3 <= trakEnd {
                            tkhdFlagsOffset = fOffset
                        }
                    } else if boxName == Data([0x6d, 0x64, 0x69, 0x61]) { // "mdia"
                        // Walk mdia to find hdlr.
                        let mdiaStart = trakPos + 8
                        let mdiaEnd   = trakPos + sz
                        var mPos = mdiaStart
                        while mPos + 8 <= mdiaEnd {
                            guard let msz32 = readU32(mPos) else { break }
                            let msz = msz32 == 0 ? (mdiaEnd - mPos) : Int(msz32)
                            guard msz >= 8, mPos + msz <= mdiaEnd else { break }
                            let mn = bytes[mPos + 4 ..< mPos + 8]
                            if mn == Data([0x68, 0x64, 0x6c, 0x72]) { // "hdlr"
                                // hdlr: [size][name][version 1B][flags 3B]
                                //       [pre_defined 4B][handler_type 4B][...]
                                let htOffset = mPos + 8 + 1 + 3 + 4  // skip sz+name+ver+flags+predefined
                                if htOffset + 4 <= mdiaEnd {
                                    handlerType = bytes[htOffset ..< htOffset + 4]
                                }
                                break
                            }
                            mPos += msz
                        }
                    }
                    trakPos += sz
                }

                // Subtitle handler types: 'sbtl' (tx3g/mov_text) or 'text'.
                let isSbtl = handlerType == Data([0x73, 0x62, 0x74, 0x6c]) // "sbtl"
                let isText = handlerType == Data([0x74, 0x65, 0x78, 0x74]) // "text"
                if (isSbtl || isText), tkhdFlagsOffset >= 0 {
                    // Clear bit 0 (enabled) of the most-significant byte of the
                    // 3-byte big-endian flags field. The three bytes are at
                    // [tkhdFlagsOffset], [+1], [+2]; the enabled flag is bit 0
                    // of the 24-bit big-endian value, which is bit 0 of byte [+2].
                    bytes[tkhdFlagsOffset + 2] &= 0xFE
                }
            }
            pos += boxSize
        }
        return bytes
    }

    /// Encode a four-character code as a little-endian UInt32.
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

    /// Rewrite the `AV_PKT_DATA_DOVI_CONF` side data on a codecpar in
    /// place so the container's `dvvC` / `dvcC` box advertises Profile
    /// 8.1. Called for two DV-capable-panel routes before writing the
    /// muxer header: a P7 source converted to P8.1 (paired with the
    /// producer's per-packet RPU rewrite) and a malformed "P8.6" source
    /// (profile already 8, but an invalid compat id) where only the
    /// container record needs normalizing and no packet rewrite happens.
    /// No-op when the DOVI side data is absent.
    ///
    /// Fields mutated:
    ///   `dv_profile`               → 8
    ///   `dv_bl_signal_compatibility_id` → 1   (HDR10-compat, matching P8.1)
    ///   `el_present_flag`          → 0   (no EL; the converter drops EL NALs)
    /// All other fields (level, rpu/bl flags, etc.) are left intact.
    private static func rewriteDoviConfigToProfile81(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) {
        let count = Int(codecpar.pointee.nb_coded_side_data)
        guard count > 0, let sideData = codecpar.pointee.coded_side_data else { return }
        for i in 0..<count {
            let item = sideData.advanced(by: i)
            guard item.pointee.type == AV_PKT_DATA_DOVI_CONF else { continue }
            guard let raw = item.pointee.data,
                  item.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
            else { return }
            raw.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self,
                capacity: 1
            ) { rec in
                rec.pointee.dv_profile = 8
                rec.pointee.dv_bl_signal_compatibility_id = 1
                rec.pointee.el_present_flag = 0
            }
            return
        }
    }

    /// Remove the Dolby Vision configuration record from a codecpar's
    /// `coded_side_data` array so `avformat_write_header` doesn't emit
    /// a `dvcC` box on the sample entry. Used when the engine has
    /// chosen to route a DV source as plain HEVC HDR10: an `hvc1`
    /// sample entry + a P7 `dvcC` box is exactly the combination
    /// VideoToolbox's HEVC decoder selection rejects with
    /// `kVTVideoDecoderUnsupportedDataFormatErr` (-12906), since the
    /// dvcC promises a DV profile the sample entry doesn't honour.
    private static func stripDolbyVisionSideData(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) {
        guard codecpar.pointee.nb_coded_side_data > 0,
              codecpar.pointee.coded_side_data != nil else { return }
        av_packet_side_data_remove(
            codecpar.pointee.coded_side_data,
            &codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF
        )
    }

    /// Replace the output stream's `codecpar.extradata` with the
    /// caller-supplied bytes, using FFmpeg's `av_malloc` and the
    /// required `AV_INPUT_BUFFER_PADDING_SIZE` trailing pad. Frees
    /// the buffer that `avcodec_parameters_copy` placed there.
    private static func replaceExtradata(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>,
        with bytes: [UInt8]
    ) {
        if codecpar.pointee.extradata != nil {
            av_freep(&codecpar.pointee.extradata)
        }
        codecpar.pointee.extradata_size = 0
        let total = bytes.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buf = av_malloc(total)?.assumingMemoryBound(to: UInt8.self) else { return }
        bytes.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                memcpy(buf, base, bytes.count)
            }
        }
        memset(buf + bytes.count, 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))
        codecpar.pointee.extradata = buf
        codecpar.pointee.extradata_size = Int32(bytes.count)
    }
}

/// Shared mutable state between the FragmentSplitter's
/// non-self-capturing closures and the muxer that owns them. Ref-typed
/// so the closures can mutate it without capturing `self` (which
/// doesn't exist yet during init).
private final class ByteCounter {
    /// fd the splitter's fragment-byte callback writes to. Rotated
    /// when the muxer cuts a fragment.
    var fd: Int32 = -1
    /// Bytes written to the current segment's file since the last
    /// fragment cut. Reset at each cut.
    var bytesWrittenCurrentSegment: Int = 0
    /// Sticky once any `write(2)` call returns an error.
    var writeFailed: Bool = false
    /// Cumulative fragment bytes ever emitted through the splitter
    /// for the muxer's lifetime. Monotone counter; never reset.
    var lifetimeFragmentBytes: Int = 0
    /// Successful fragment cuts since muxer init. Bumped at each
    /// `cutFragmentForNextSegment(_:)` call that produced bytes.
    var fragmentCuts: Int = 0
}

// MARK: - C callback bridge

/// `avio_alloc_context` write callback. Recovers the muxer via the
/// avio opaque (set to the MP4SegmentMuxer instance) and forwards the
/// bytes to its FragmentSplitter.
private func mp4SegmentMuxerSinkWrite(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf, size > 0 else { return -1 }
    let muxer = Unmanaged<MP4SegmentMuxer>.fromOpaque(opaque).takeUnretainedValue()
    muxer.receive(buf, count: Int(size))
    return size
}

