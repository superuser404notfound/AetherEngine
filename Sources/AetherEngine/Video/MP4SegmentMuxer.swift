import Darwin
import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Long-lived fragmented-MP4 muxer for one playback session. ONE AVFormatContext (mp4 muxer,
/// NOT hls wrapper) with movflags +empty_moov+default_base_moof+frag_custom+delay_moov.
///
/// Per-segment fresh context was tried; it fixed the 840 MB 4K-HDR HEVC leak but caused
/// A/V tfdt mismatches (~160 ms audio lead from FLAC bridge 4096-sample granularity + matroska
/// audio-ahead interleave). +delay_moov defers moov until the first av_write_frame(nil) so
/// mov_write_packet can parse EAC3/AC3 bitstream before emitting dec3/dac3 (without it:
/// -22 "Cannot write moov atom before EAC3/AC3 packets parsed", falling back to FLAC bridge
/// and losing Atmos JOC). NOT +dash (session-long sidx) or +frag_keyframe (interferes with
/// explicit cut control).
///
/// Cut sequence: av_interleaved_write_frame(nil) drains the interleaver, then
/// av_write_frame(nil) triggers mov_flush_fragment (moof+mdat). First cut only: a second
/// av_write_frame(nil) (gated by `moovFlushed`) handles FFmpeg splitting ftyp+moov and
/// moof+mdat across calls; subsequent cuts are single-call. FragmentSplitter routes ftyp+moov
/// to onInitCaptured (init.mp4) and moof+mdat bytes to the staging POSIX file.
final class MP4SegmentMuxer {

    // MARK: - Types

    /// Force color signaling on the output codecpar before avformat_write_header.
    /// Used for DV P5: SPS VUI omits transfer, no colr atom; without an explicit
    /// colr nclx the DV decoder won't engage on a dvh1 sample entry.
    struct ColorOverride {
        let primaries: AVColorPrimaries
        let trc: AVColorTransferCharacteristic
        let space: AVColorSpace
        let range: AVColorRange
    }

    struct VideoConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Forces fourCC on the output stream codec_tag (e.g. hvc1; hev1 default rejected by AVPlayer).
        let codecTagOverride: String?
        /// Drop AV_PKT_DATA_DOVI_CONF before avformat_write_header; hvc1+dvcC trips VT -12906.
        /// Mutually exclusive with `rewriteDoviConfigTo81`.
        let stripDolbyVisionMetadata: Bool
        /// Rewrite dvcC to valid P8.1 (dv_profile=8, compat=1, el_present=0) instead of stripping.
        /// Used for P7-on-DV-panel (paired with per-packet RPU rewrite) and malformed "P8.6"
        /// (invalid compat id; no packet rewrite needed). Mutually exclusive with `stripDolbyVisionMetadata`.
        let rewriteDoviConfigTo81: Bool
        /// Optional color-signaling override. See `ColorOverride`.
        let colorOverride: ColorOverride?
        /// Replaces codecpar.extradata after avcodec_parameters_copy. Used when the source hvcC
        /// has numOfArrays=0 (in-band parameter sets) and the engine rebuilt a proper hvcC with
        /// VPS/SPS/PPS arrays; the mp4 muxer writes extradata directly into the hvcC/avcC box.
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

    /// Config for a single mov_text (tx3g) subtitle output stream; muxer synthesises it entirely.
    struct SubtitleConfig {
        /// 1/1000 default = millisecond precision, sufficient for SRT/WebVTT cues.
        let timeBase: AVRational
        /// BCP-47 tag converted to ISO 639-2/T via iso639_2(fromBCP47:) for the QuickTime
        /// language metadata key. Nil = no language box.
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

    private(set) var currentSegmentIndex: Int
    /// Same volume as cache adopt target so rename is metadata-only.
    private let sessionDir: URL
    private var currentStagingPath: URL
    private var fd: Int32 = -1
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var pb: UnsafeMutablePointer<AVIOContext>?
    private var headerWritten: Bool = false
    /// Per-output-stream timestamp guard (strictly increasing dts, pts >= dts).
    /// No-op for healthy content; rescues SSAI ad-boundary pts < dts.
    private var timestampSanitizer = OutputTimestampSanitizer()
    /// +delay_moov: first cut may need a second av_write_frame(nil) because FFmpeg can split
    /// ftyp+moov and moof+mdat across calls; gate ensures it only fires once.
    private var moovFlushed: Bool = false
    /// Latched when the next staging file open fails; producer must stop the pump.
    private(set) var isWedged: Bool = false
    /// Latched after avformat_write_header; mp4 muxer rewrites time_base to its own pick
    /// (typically 1/16000 for 24 fps video, 1/<sample rate> for audio).
    private(set) var muxerVideoTimeBase: AVRational = AVRational(num: 1, den: 1)
    private(set) var muxerAudioTimeBase: AVRational = AVRational(num: 1, den: 1)
    private(set) var muxerSubtitleTimeBase: AVRational = AVRational(num: 1, den: 1000)
    private let haveAudio: Bool

    let videoOutputStreamIndex: Int32 = 0
    let audioOutputStreamIndex: Int32 = 1

    /// Ordinal -> libavformat stream index map for declared mov_text tracks.
    /// Dynamic: 1 without audio, 2 with audio, then +1 per additional subtitle track.
    private(set) var subtitleOutputStreamIndices: [Int32] = []

    private let splitter: FragmentSplitter

    // MARK: - Init

    /// Build the session-long muxer, opening its first segment file.
    /// `onInitCaptured` fires once when ftyp+moov bytes finish streaming (= init.mp4 content).
    /// Throws on any libavformat init failure or staging-file open failure.
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

        let firstPath = Self.stagingPath(forSegmentIndex: initialSegmentIndex,
                                         in: sessionDir)
        self.currentStagingPath = firstPath
        let firstFd = try Self.openPosix(path: firstPath)
        self.fd = firstFd

        // Ref-typed counter shared with the splitter closure (closure can't capture self during init).
        let counter = ByteCounter()
        counter.fd = firstFd
        self.byteCounter = counter

        // movenc 62.x forces enabled=1 on the first subtitle tkhd regardless of disposition=0;
        // post-process the init segment to clear the bit before handing it to the caller.
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

        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        let allocRet = avformat_alloc_output_context2(&ctxOut, nil, "mp4", "segment.m4s")
        guard allocRet == 0, let ctx = ctxOut else {
            close(firstFd)
            try? FileManager.default.removeItem(at: firstPath)
            throw MuxerError.allocFailed(code: allocRet)
        }
        self.formatContext = ctx

        // mp4 muxer writes to s->pb directly (unlike hlsenc which calls s->io_open); pb must be attached before write_header.
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
        if let firstSubIdx = capturedSubtitleIndices.first {
            muxerSubtitleTimeBase = ctx.pointee.streams.advanced(by: Int(firstSubIdx)).pointee!.pointee.time_base
        }
        subtitleOutputStreamIndices = capturedSubtitleIndices
    }

    private let byteCounter: ByteCounter

    // MARK: - Diagnostic probes

    /// Lifetime fragment bytes emitted; divergence from RSS growth pins whether the muxer is leaking.
    var lifetimeFragmentBytesEmitted: Int { byteCounter.lifetimeFragmentBytes }
    /// Diverging from producerPacketsWritten / pktsPerFragment flags a flush stall.
    var fragmentCutCount: Int { byteCounter.fragmentCuts }

    // MARK: - Eager probe

    /// Dry-run avformat_write_header to catch cascade failures the lazy muxer init would miss.
    /// The real muxer allocates on the first keep-packet; if write_header would fail (-22 for
    /// EAC3-from-MKV "Cannot write moov atom before EAC3/AC3 packets parsed") the cascade
    /// never falls back to FLAC bridge. Bytes go to a discarded in-memory AVIO sink.
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

    /// Shared stream setup + write_header used by both the session muxer and probeWriteHeader.
    /// Single source of truth: drift between the two would let the probe pass while the real muxer fails.
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

        // Subtitle streams declared after audio; indices dynamic (1 without audio, 2 with audio, +1 per track).
        // disposition=0 keeps tkhd enabled CLEAR so AVFoundation derives defaultOption=nil and does not
        // auto-display; movenc 62.x still forces enabled=1 on the first track, handled by clearSubtitleTkhdEnabled.
        for cfg in subtitles {
            guard let subStream = avformat_new_stream(ctx, nil) else {
                throw MuxerError.streamCreationFailed
            }
            subStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            subStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_MOV_TEXT
            subStream.pointee.time_base = cfg.timeBase
            subStream.pointee.disposition = 0
            if let iso = iso639_2(fromBCP47: cfg.language) {
                iso.withCString { cStr in
                    _ = av_dict_set(&subStream.pointee.metadata, "language", cStr, 0)
                }
            }
            capturedSubtitleIndices.append(subStream.pointee.index)
        }

        var opts: OpaquePointer? = nil
        defer { av_dict_free(&opts) }
        av_dict_set(&opts, "movflags", "+empty_moov+default_base_moof+frag_custom+delay_moov", 0)
        // use_editlist=0: +delay_moov derives an elst from the first packet timestamp (restart anchor);
        // AVPlayer fetches EXT-X-MAP once so post-restart fragments play against a stale elst causing
        // lipsync drift. Position belongs in each fragment's tfdt; moov stays restart-invariant.
        av_dict_set(&opts, "use_editlist", "0", 0)
        // infer_no_subs: skip default-track inference for subtitle traks only; movenc 62.x still
        // forces enabled=1 on the first subtitle tkhd regardless, handled by clearSubtitleTkhdEnabled.
        if !subtitles.isEmpty {
            av_dict_set(&opts, "default_mode", "infer_no_subs", 0)
        }

        let ret = avformat_write_header(ctx, &opts)
        guard ret >= 0 else {
            throw MuxerError.writeHeaderFailed(code: ret)
        }
    }

    // MARK: - Pump-side API

    static func subtitleTicks(forSeconds s: Double, timescale: Int32) -> Int64 {
        Int64((s * Double(timescale)).rounded())
    }

    private static let bcp47ToISO639_2: [String: String] = [
        "en": "eng", "de": "deu", "ja": "jpn", "fr": "fra",
        "es": "spa", "it": "ita", "pt": "por", "ru": "rus",
        "zh": "zho", "ko": "kor", "nl": "nld", "pl": "pol",
        "sv": "swe", "da": "dan", "no": "nor", "fi": "fin",
        "tr": "tur", "ar": "ara", "cs": "ces", "el": "ell",
        "he": "heb", "hi": "hin", "th": "tha", "uk": "ukr",
    ]

    /// BCP-47 -> ISO 639-2/T for QuickTime language key. Strips region subtag (en-US -> en);
    /// passes through already-3-letter codes; returns nil for unknown tags.
    static func iso639_2(fromBCP47 tag: String?) -> String? {
        guard let tag else { return nil }
        let base = tag.split(separator: "-", maxSplits: 1).first.map(String.init) ?? tag
        let lower = base.lowercased()
        if lower.count == 3 && lower.allSatisfy(\.isLetter) {
            return lower
        }
        return bcp47ToISO639_2[lower]
    }

    /// Write one mov_text sample. `payload` is the [uint16 BE len][UTF-8] body from MovTextSampleBuilder.
    /// av_interleaved_write_frame takes ownership of the packet buffer (calls av_packet_unref internally);
    /// trackedPacketFree in the defer frees the now-empty struct.
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

    /// Write one packet via av_interleaved_write_frame (caller must rescale pts/dts to muxerVideoTimeBase / muxerAudioTimeBase).
    @discardableResult
    func writePacket(_ packet: UnsafeMutablePointer<AVPacket>) -> Int32 {
        guard let ctx = formatContext else { return -1 }
        let clean = timestampSanitizer.sanitize(
            streamIndex: packet.pointee.stream_index,
            pts: packet.pointee.pts,
            dts: packet.pointee.dts
        )
        packet.pointee.pts = clean.pts
        packet.pointee.dts = clean.dts
        // av_write_frame was tried as a leak hypothesis; no impact on 8 MB/s mallocMB growth
        // (leak was Data(d) dispatch_data aliasing in AVIOReader). Reverted to interleaved for
        // cross-stream DTS monotonicity and audio+video re-ordering via libavformat.
        return av_interleaved_write_frame(ctx, packet)
    }

    /// Finalize the current segment and rotate fd to a fresh staging file for `nextIdx`.
    /// Returns `(path, bytes)` for the completed segment, or nil on any write failure.
    /// +delay_moov first-cut wrinkle: second av_write_frame(nil) (gated by moovFlushed) handles
    /// FFmpeg splitting ftyp+moov and moof+mdat across calls; safe no-op if both arrived in one call.
    func cutFragmentForNextSegment(_ nextIdx: Int) -> (path: URL, bytesWritten: Int)? {
        guard let ctx = formatContext, headerWritten, fd >= 0 else { return nil }

        // Drain the interleaver first: av_write_frame(nil) bypasses it, so audio packets buffered
        // waiting for video DTS catch-up would spill into the next fragment (~4 trailing AC-3 frames
        // missing per segment for matroska audio-leads-video sources, ~120 ms short of #EXTINF).
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

        let nextPath = Self.stagingPath(forSegmentIndex: nextIdx, in: sessionDir)
        do {
            let nextFd = try Self.openPosix(path: nextPath)
            self.fd = nextFd
            self.currentStagingPath = nextPath
            self.currentSegmentIndex = nextIdx
            byteCounter.fd = nextFd
        } catch {
            // isWedged: splitter would silently discard next fragment bytes until the pump failed a cut later.
            EngineLog.emit(
                "[MP4SegmentMuxer] open next staging file seg-\(nextIdx) FAILED: \(error)",
                category: .session
            )
            isWedged = true
            return (path: completedPath, bytesWritten: completedBytes)
        }

        return (path: completedPath, bytesWritten: completedBytes)
    }

    /// Final teardown: flush remaining packets, write trailer (mfra discarded by splitter), close fd.
    /// Returns the final segment's (path, bytes) for cache adoption, or nil on failure.
    func finalize() -> (path: URL, bytesWritten: Int)? {
        defer { cleanup() }

        guard let ctx = formatContext, headerWritten else {
            if fd >= 0 { close(fd); fd = -1 }
            try? FileManager.default.removeItem(at: currentStagingPath)
            return nil
        }

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

    private static func stagingPath(forSegmentIndex idx: Int, in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent(
            "staging-seg-\(idx)-\(UUID().uuidString.prefix(8)).tmp"
        )
    }

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

    /// avio_context_free does NOT free pb->buffer (separate av_malloc alloc); drop it explicitly first.
    private func cleanup() {
        if let ctx = formatContext {
            if let pb = ctx.pointee.pb {
                avio_flush(pb)
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
        cleanup()
    }

    // MARK: - AVIO

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
        // pure-forward writing; AVIO_SEEKABLE_NORMAL was tried as a leak hypothesis, no impact.
        pb.pointee.seekable = 0
        return pb
    }

    fileprivate func receive(_ buf: UnsafePointer<UInt8>, count: Int) {
        splitter.feed(buf, count: count)
    }

    // MARK: - Helpers

    /// Walk moov to find subtitle trak entries (handler sbtl or text) and clear tkhd enabled bit (bit 0 of 3-byte flags).
    /// movenc 62.x forces enabled=1 regardless of disposition=0; AVFoundation treats enabled=1 as defaultOption
    /// on AVMediaSelectionGroup and auto-displays the track. No-op when moov cannot be located.
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

        var pos = 0
        var moovStart = -1
        var moovEnd = -1
        while pos + 8 <= count {
            guard let size32 = readU32(pos) else { break }
            let boxSize: Int
            if size32 == 1 {
                // Extended 64-bit size.
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

        pos = moovStart
        while pos + 8 <= moovEnd {
            guard let size32 = readU32(pos) else { break }
            let boxSize = size32 == 0 ? (moovEnd - pos) : Int(size32)
            guard boxSize >= 8, pos + boxSize <= moovEnd else { break }
            let name = bytes[pos + 4 ..< pos + 8]
            if name == Data([0x74, 0x72, 0x61, 0x6b]) { // "trak"
                let trakStart = pos + 8
                let trakEnd   = pos + boxSize

                var tkhdFlagsOffset = -1   // byte offset of the 3-byte flags field inside tkhd
                var handlerType: Data? = nil

                var trakPos = trakStart
                while trakPos + 8 <= trakEnd {
                    guard let sz32 = readU32(trakPos) else { break }
                    let sz = sz32 == 0 ? (trakEnd - trakPos) : Int(sz32)
                    guard sz >= 8, trakPos + sz <= trakEnd else { break }
                    let boxName = bytes[trakPos + 4 ..< trakPos + 8]

                    if boxName == Data([0x74, 0x6b, 0x68, 0x64]) { // "tkhd"
                        // tkhd: [size 4B][name 4B][version 1B][flags 3B] -> flags at trakPos+9
                        let fOffset = trakPos + 9
                        if fOffset + 3 <= trakEnd {
                            tkhdFlagsOffset = fOffset
                        }
                    } else if boxName == Data([0x6d, 0x64, 0x69, 0x61]) { // "mdia"
                        let mdiaStart = trakPos + 8
                        let mdiaEnd   = trakPos + sz
                        var mPos = mdiaStart
                        while mPos + 8 <= mdiaEnd {
                            guard let msz32 = readU32(mPos) else { break }
                            let msz = msz32 == 0 ? (mdiaEnd - mPos) : Int(msz32)
                            guard msz >= 8, mPos + msz <= mdiaEnd else { break }
                            let mn = bytes[mPos + 4 ..< mPos + 8]
                            if mn == Data([0x68, 0x64, 0x6c, 0x72]) { // "hdlr"
                                // hdlr layout: sz+name(8) + ver(1) + flags(3) + pre_defined(4) + handler_type(4)
                                let htOffset = mPos + 8 + 1 + 3 + 4
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
                    // enabled is bit 0 of the 3-byte BE flags; lives at byte [+2].
                    bytes[tkhdFlagsOffset + 2] &= 0xFE
                }
            }
            pos += boxSize
        }
        return bytes
    }

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

    /// Mutate AV_PKT_DATA_DOVI_CONF in-place: dv_profile=8, compat=1 (HDR10), el_present_flag=0.
    /// Used for P7-on-DV-panel (paired with per-packet RPU conversion) and "P8.6" (invalid compat id only).
    /// No-op when DOVI side data is absent.
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

    /// Strip AV_PKT_DATA_DOVI_CONF from coded_side_data; hvc1+dvcC trips VT -12906.
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

    /// Replace codecpar.extradata using av_malloc + AV_INPUT_BUFFER_PADDING_SIZE pad.
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

/// Ref-typed mutable state shared between the FragmentSplitter closures and the muxer
/// (closures can't capture self during init).
private final class ByteCounter {
    var fd: Int32 = -1
    var bytesWrittenCurrentSegment: Int = 0
    var writeFailed: Bool = false
    var lifetimeFragmentBytes: Int = 0
    var fragmentCuts: Int = 0
}

// MARK: - C callback bridge

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

