import Darwin
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

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
/// AE#222: +delay_moov alone is not enough for a source whose FIRST segment carries no audio packet (audio
/// blocks sitting behind seconds of video in file order). Such a session is built with an
/// `audioMoovPrimeFrame`: one real audio frame muxed at init writes moov (with a genuine dec3/dac3/dmlp) up
/// front, and the primed fragment's bytes are then discarded so the delivered segment is unchanged.
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
    /// colr nclx the DV decoder won't engage on a dvh1 sample entry. Also SDR retagged
    /// as sRGB on Mac / iPhone ([MovieClaw P60], see `ColorAttachments.presentsSDRAsSRGB`).
    struct ColorOverride {
        let primaries: AVColorPrimaries
        let trc: AVColorTransferCharacteristic
        let space: AVColorSpace
        let range: AVColorRange
    }

    /// What happens to the source `dvcC` / `dvvC` record on its way into the fMP4 sample entry.
    ///
    /// One value, not a set of Bools: the four outcomes exclude each other, and while that was only
    /// stated in comments a caller could ask for a strip AND a rewrite and get whichever the muxer's
    /// if-chain reached first.
    enum DoviConfigPolicy: Sendable, Equatable {
        /// Stream-copy the record unchanged. Genuine P5, and P8.x on a DV panel.
        case keep
        /// Drop `AV_PKT_DATA_DOVI_CONF` before write_header. P7's base layer and P8.2 (hvc1 + dvcC
        /// trips VT -12906), and P8.x on a non-DV panel (-11868).
        case strip
        /// Rewrite to a valid P8.1: `dv_profile=8`, `compat=1`, `el_present=0`. P7-on-DV-panel
        /// (paired with the per-packet RPU conversion) and the malformed "P8.6" compat id (#53).
        case rewriteToProfile81
        /// Rewrite to P5: `dv_profile=5`, `compat=0`, `el_present=0`. AE#455, opt-in. The bitstream
        /// stays a P8.1 with an HDR10 base layer; only the container claim changes, which is what
        /// makes AVPlayer run its own DV composition on a panel that cannot do DV itself.
        case rewriteToProfile5
    }

    struct VideoConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Forces fourCC on the output stream codec_tag (e.g. hvc1; hev1 default rejected by AVPlayer).
        let codecTagOverride: String?
        /// What to do with the source Dolby Vision configuration record. See `DoviConfigPolicy`.
        let doviConfig: DoviConfigPolicy
        /// Optional color-signaling override. See `ColorOverride`.
        let colorOverride: ColorOverride?
        /// Replaces codecpar.extradata after avcodec_parameters_copy. Used when the source hvcC
        /// has numOfArrays=0 (in-band parameter sets) and the engine rebuilt a proper hvcC with
        /// VPS/SPS/PPS arrays; the mp4 muxer writes extradata directly into the hvcC/avcC box.
        let extradataOverride: [UInt8]?
        /// [MovieClaw P38] 视频样本是 Annex B、配置记录是 hvcC：写包前由这里转成 4 字节长度前缀并保留全部 NAL
        /// （含带内 VPS/SPS/PPS）。movenc 自己转换时对 hvc1 会剥掉参数集，片中换参数集的片子就解不了
        let annexBSamplesKeepParameterSets: Bool
        /// The session's framing verdict for this track (audit BIT-104); nil gives the muxer its own.
        let nalFramingLatch: NALFramingLatch?

        init(
            codecpar: UnsafePointer<AVCodecParameters>,
            timeBase: AVRational,
            codecTagOverride: String?,
            doviConfig: DoviConfigPolicy = .keep,
            colorOverride: ColorOverride? = nil,
            extradataOverride: [UInt8]? = nil,
            annexBSamplesKeepParameterSets: Bool = false,
            nalFramingLatch: NALFramingLatch? = nil
        ) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.codecTagOverride = codecTagOverride
            self.doviConfig = doviConfig
            self.colorOverride = colorOverride
            self.extradataOverride = extradataOverride
            self.annexBSamplesKeepParameterSets = annexBSamplesKeepParameterSets
            self.nalFramingLatch = nalFramingLatch
        }
    }

    struct AudioConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// AE#458: ISO 639-2/T for the track's `mdhd`. Nil writes nothing, leaving movenc's `und`.
        let language: String?

        init(codecpar: UnsafePointer<AVCodecParameters>,
             timeBase: AVRational,
             language: String? = nil) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.language = language
        }
    }

    /// Result of a segment cut. `deferredAwaitingAudioSampleEntry` is a THIRD state, distinct from both
    /// success and failure: nothing was written, the muxer is intact, and the caller must retry the cut
    /// once an audio packet has been muxed. Collapsing it into nil (= failure) is what wedged AE#222.
    enum CutOutcome: Equatable {
        case completed(path: URL, bytesWritten: Int)
        case deferredAwaitingAudioSampleEntry
        case failed
    }

    enum MuxerError: Error, CustomStringConvertible, LocalizedError {
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

        var errorDescription: String? { description }
    }

    // MARK: - State

    private(set) var currentSegmentIndex: Int
    /// Same volume as cache adopt target so rename is metadata-only.
    private let sessionDir: URL
    private var currentStagingPath: URL
    /// [MovieClaw P57] 当前分片的暂存文件：只往后追加，封口时原样改名进缓存，所以可以边写边读
    var stagingURL: URL { currentStagingPath }
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
    /// EAC3/AC-3 moov-wedge guard (#92 follow-up): latched once the first audio packet is written so
    /// the first moov flush can never fire before FFmpeg has parsed an audio packet, mov_write_moov
    /// builds the E-AC-3 `dec3` / AC-3 `dac3` (and TrueHD `dmlp`) sample-entry box from a parsed packet,
    /// and flushing moov video-only errors -22 "Cannot write moov atom before EAC3 packets parsed" and
    /// wedges the muxer.
    private var audioPacketWritten: Bool = false
    /// True only when the audio codec's mp4 sample entry requires a PARSED packet before moov can be
    /// written (AC-3 `dac3`, E-AC-3 `dec3`, TrueHD `dmlp`). AAC and other codecs build their sample entry
    /// from codecpar alone, so they never wedge, and gating the #64 RAM-cap flush on them would needlessly
    /// weaken that memory bound. Latched at init from the audio codec_id.
    private let audioNeedsParsedPacketForMoov: Bool
    /// Width of the video track's NAL length prefix (avcC / hvcC), nil when the track is not
    /// length-prefixed at all. Latched at init: it is a property of the configuration record that
    /// lands in the sample entry, and the AE#561 sanitizer walks every video sample with it.
    private let videoNALLengthPrefixSize: Int?
    /// [MovieClaw P38] 写包前把 Annex B 视频样本转成长度前缀（保留参数集）
    private let convertsAnnexBVideoSamples: Bool
    /// AE#561 harness switch: the sanitizer removes the only shape that reproduces a segment Apple's
    /// parser refuses, so the rung underneath it (the software-path escalation) would have nothing to
    /// be measured against. Read once from the environment, never set in a shipped configuration.
    static let nalChainSanitizerDisabled =
        ProcessInfo.processInfo.environment["AETHER_DISABLE_NAL_SANITIZER"] != nil
    /// How many video samples the AE#561 sanitizer has had to cut, over this muxer's life.
    private(set) var truncatedVideoSamples: Int = 0
    /// Audit BIT-1: a video sample of this track walked exactly as a length-prefixed chain, so a
    /// `00 00 01` head is a 256-511 byte length from here on, not an Annex B start code. The
    /// session's latch when it passed one (audit BIT-104), so a rebuilt muxer keeps the verdict.
    private let videoNALFraming: NALFramingLatch

    private func sanitizerCut(_ bytes: UnsafeRawBufferPointer, lengthPrefixSize: Int) -> Int? {
        let confirmed = videoNALFraming.isConfirmed
        let cut = NALUnitChain.completeRunLength(
            bytes, lengthPrefixSize: lengthPrefixSize, framingConfirmed: confirmed)
        if cut == nil, !confirmed,
           NALUnitChain.walksExactly(bytes, lengthPrefixSize: lengthPrefixSize) {
            videoNALFraming.confirm()
        }
        return cut
    }

    /// Only AC-3 / E-AC-3 / TrueHD build their mp4 sample entry from a parsed packet (dac3/dec3/dmlp),
    /// so only they can hit the "moov before audio parsed" wedge and need the #64-flush guard. Shared with
    /// the producer, which uses it to decide whether retaining a moov-prime frame copy buys anything.
    ///
    /// AC-3 and E-AC-3 are what actually reach a muxer here, and for them ANY frame primes: every frame is
    /// a complete syncframe, so movenc's handle_eac3 derives the full sample entry from whichever one it
    /// gets. TrueHD is listed for completeness and is unreachable today (`AudioCodecCompat.requiresBridge`
    /// sends it through AudioBridge, so the muxer's audio track is the bridge's E-AC-3 or FLAC encoder,
    /// never mlpa). That matters if it is ever unblocked: movenc latches `track->extradata` from the FIRST
    /// packet written and `mov_write_dmlp_tag` rejects it unless it carries the major-sync word 0xF8726FBA,
    /// which most TrueHD frames do not, so a TrueHD stream-copy path would have to prime from a major-sync
    /// frame specifically instead of from an arbitrary retained one.
    static func audioNeedsParsedPacketForMoov(_ codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_AC3 ||
        codecID == AV_CODEC_ID_EAC3 ||
        codecID == AV_CODEC_ID_TRUEHD
    }
    /// Latched when the next staging file open fails; producer must stop the pump.
    private(set) var isWedged: Bool = false
    /// Latched after avformat_write_header; mp4 muxer rewrites time_base to its own pick
    /// (typically 1/16000 for 24 fps video, 1/<sample rate> for audio).
    private(set) var muxerVideoTimeBase: AVRational = AVRational(num: 1, den: 1)
    private(set) var muxerAudioTimeBase: AVRational = AVRational(num: 1, den: 1)
    private let haveAudio: Bool

    /// AE#464: host audio offset for this muxer, in seconds. Fixed for the muxer's life on purpose:
    /// two offsets inside one output track are not splicable (the seam gains a gap or an overlap of
    /// exactly the change, and a change that moves audio earlier is eaten by
    /// `OutputTimestampSanitizer`'s strictly-increasing DTS rule), so a new offset has to be a new
    /// muxer, which the producer restart provides.
    private let audioDelaySeconds: Double

    /// The same offset in the muxer's OUTPUT audio time base, latched once the header has rewritten
    /// it. Packets reach `writePacket` already rescaled, so this is the base the shift must be in.
    private var audioDelayTicks: Int64 = 0

    /// Mid-segment fragment-flush bound (#64). With movflags +frag_custom a moof+mdat is emitted only at
    /// an explicit segment cut; a degenerate plan (sparse-keyframe TS index) or any very long segment
    /// would otherwise buffer the whole span in libavformat's interleaver until the cut, growing RAM
    /// without bound (a 110 min Blu-ray reached ~13 GB and swapped the device disk full). Track the video
    /// output DTS window since the last flush and force an interim flush (the same drain pair as the cut,
    /// minus the fd rotation) once it spans more than `maxBufferedFragmentTicks`. Output-TB ticks (the
    /// muxer rewrites its own video time_base at write_header), 0 = bound disabled. Computed from the
    /// latched `muxerVideoTimeBase` after write_header; defaults to 0 so cleanup() on an init error path
    /// (which runs before the latch) sees a fully-initialized stored property.
    private var maxBufferedFragmentTicks: Int64 = 0
    /// Output-TB DTS of the first video packet since the last flush; Int64.min = no window open yet.
    private var fragmentWindowFirstVideoDts: Int64 = Int64.min

    /// AE#684: the sound handed to the segment being cut, first and last packet, in
    /// `muxerAudioTimeBase`. A segment opens on a video keyframe and carries whatever audio the
    /// source interleaved up to there, so where its sound begins against its picture is a property
    /// of the source's mux, and it is what an item placed in that segment starts its audio from.
    private var segmentSoundFirstPts: Int64 = Int64.min
    private var segmentSoundLastPts: Int64 = Int64.min

    /// The span since the last call, nil when the segment carried no audio packet. Consumes it.
    func takeSegmentSoundSpan() -> (first: Int64, last: Int64)? {
        defer { segmentSoundFirstPts = Int64.min; segmentSoundLastPts = Int64.min }
        guard segmentSoundFirstPts != Int64.min else { return nil }
        return (segmentSoundFirstPts, segmentSoundLastPts)
    }

    let videoOutputStreamIndex: Int32 = 0
    let audioOutputStreamIndex: Int32 = 1

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
        maxBufferedFragmentSeconds: Double = 8.0,
        audioMoovPrimeFrame: [UInt8]? = nil,
        audioDelaySeconds: Double = 0,
        onInitCaptured: @escaping (Data) -> Void
    ) throws {
        self.currentSegmentIndex = initialSegmentIndex
        self.sessionDir = sessionDir
        self.haveAudio = audio != nil
        self.audioDelaySeconds = audioDelaySeconds
        self.audioNeedsParsedPacketForMoov =
            audio.map { Self.audioNeedsParsedPacketForMoov($0.codecpar.pointee.codec_id) } ?? false
        self.videoNALFraming = video.nalFramingLatch ?? NALFramingLatch()
        // AE#561: the override, when there is one, is the record that reaches the sample entry. Both
        // carry the same width (the #19 rebuild keeps the source header's first 22 bytes), so this
        // only matters for a source whose own extradata is missing or Annex B.
        self.convertsAnnexBVideoSamples = video.annexBSamplesKeepParameterSets
        if let override = video.extradataOverride {
            self.videoNALLengthPrefixSize = override.withUnsafeBufferPointer {
                NALUnitChain.lengthPrefixSize(
                    codecID: video.codecpar.pointee.codec_id,
                    extradata: $0.baseAddress,
                    extradataSize: $0.count
                )
            }
        } else {
            self.videoNALLengthPrefixSize = NALUnitChain.lengthPrefixSize(
                codecID: video.codecpar.pointee.codec_id,
                extradata: UnsafePointer(video.codecpar.pointee.extradata),
                extradataSize: Int(video.codecpar.pointee.extradata_size)
            )
        }

        let firstPath = Self.stagingPath(forSegmentIndex: initialSegmentIndex,
                                         in: sessionDir)
        self.currentStagingPath = firstPath
        let firstFd = try Self.openPosix(path: firstPath)
        self.fd = firstFd

        // Ref-typed counter shared with the splitter closure (closure can't capture self during init).
        let counter = ByteCounter()
        counter.fd = firstFd
        self.byteCounter = counter

        self.splitter = FragmentSplitter(
            onHeaderComplete: { initBytes in
                // AE#187 defense-in-depth: strip a zero-sample video `sdtp` from the fragmented init before
                // forwarding it. The pinned FFmpegBuild (n8.1.2) never writes it, so this is a no-op there;
                // it neutralizes the box only for a consumer that links an older FFmpeg (a -force_load'ed
                // 7.1.5 shadowing the vendored build), whose init Apple TV would otherwise reject.
                let clean = HLSVideoEngine.stripEmptyVideoSampleDependencyBox(fromInit: [UInt8](initBytes))
                    .map { Data($0) } ?? initBytes
                onInitCaptured(clean)
            },
            onFragmentBytes: { ptr, count in
                guard !counter.writeFailed, counter.fd >= 0 else { return }
                // [MovieClaw P25] 测试钩子：模拟播放中存储被写满
                if AetherEngine.storageFullSimulated {
                    SegmentCache.markStorageExhausted()
                    counter.writeFailed = true
                    return
                }
                var written = 0
                while written < count {
                    let n = write(counter.fd, ptr.advanced(by: written), count - written)
                    if n < 0 {
                        let err = errno
                        if err == EINTR { continue }
                        // [MovieClaw P25] 写满了：记下来，泵失败时报「存储已满」而不是笼统的封装失败
                        if err == ENOSPC { SegmentCache.markStorageExhausted() }
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

        do {
            try Self.configureStreamsAndWriteHeader(
                ctx: ctx,
                video: video,
                audio: audio
            )
        } catch {
            cleanup()
            throw error
        }
        self.headerWritten = true

        muxerVideoTimeBase = ctx.pointee.streams.advanced(by: 0).pointee!.pointee.time_base
        if haveAudio {
            muxerAudioTimeBase = ctx.pointee.streams.advanced(by: 1).pointee!.pointee.time_base
            // AE#464: same reason as the bound below. Latched after write_header rewrote the stream
            // time_base, because that is the base the packets arrive in.
            audioDelayTicks = Self.audioDelayTicks(seconds: audioDelaySeconds,
                                                   audioTimeBase: muxerAudioTimeBase)
            if audioDelayTicks != 0 {
                // Release-visible: which muxer carries which offset is the only way to tell "the host
                // set it" from "the segments being served were cut with it", and a restart is what
                // moves the session from one to the other.
                EngineLog.emit(
                    "[MP4SegmentMuxer] AE#464 cutting seg\(initialSegmentIndex)+ with audio delay "
                    + String(format: "%+.0f ms", audioDelaySeconds * 1000)
                    + " (\(audioDelayTicks) ticks @ \(muxerAudioTimeBase.den)/\(muxerAudioTimeBase.num))",
                    category: .session
                )
            }
        }
        // Bound is in the muxer's rewritten output video TB: packets reach writePacket already rescaled
        // to muxerVideoTimeBase, so the window math must use it (not the source TB). Latched here, after
        // write_header has rewritten the stream time_base (#64).
        maxBufferedFragmentTicks = Self.bufferedFragmentTicks(
            seconds: maxBufferedFragmentSeconds,
            timeBase: muxerVideoTimeBase
        )

        // AE#222: prime moov from one real audio frame when the audio sample entry is packet-derived. Without
        // it, a source whose first segment carries no audio packet (video-first interleave: the audio blocks sit
        // physically behind seconds of video) cannot emit moov at the first cut at all, and no codecpar or
        // extradata can substitute (movenc builds dec3/dac3/dmlp in handle_eac3 from a PARSED frame only).
        if let prime = audioMoovPrimeFrame, audio != nil, audioNeedsParsedPacketForMoov {
            primeMoovWithAudioFrame(prime)
        }
    }

    private let byteCounter: ByteCounter

    // MARK: - Audio delay conversion (pure, AE#464)

    /// The host's audio offset in `audioTimeBase` ticks. Rounded rather than truncated so a nudge
    /// smaller than one tick still moves in the direction it was asked for instead of vanishing.
    static func audioDelayTicks(seconds: Double, audioTimeBase: AVRational) -> Int64 {
        guard seconds != 0, seconds.isFinite,
              audioTimeBase.num > 0, audioTimeBase.den > 0 else { return 0 }
        let ticks = seconds * Double(audioTimeBase.den) / Double(audioTimeBase.num)
        guard ticks.isFinite, abs(ticks) < Double(Int64.max) else { return 0 }
        return Int64(ticks.rounded())
    }

    // MARK: - Buffered-fragment bound math (pure, #64)

    /// Output-TB tick span for `seconds` at `timeBase` (the muxer's rewritten video time_base). 0 when
    /// the input is degenerate, which disables the bound.
    static func bufferedFragmentTicks(seconds: Double, timeBase: AVRational) -> Int64 {
        guard seconds > 0, timeBase.num > 0, timeBase.den > 0 else { return 0 }
        return Int64(seconds * Double(timeBase.den) / Double(timeBase.num))
    }

    /// True when the buffered video span [firstDts, currentDts] has reached `boundTicks` and an interim
    /// flush is due. A sentinel firstDts (Int64.min) means no window is open yet; a backward currentDts
    /// (a DTS reset) never triggers; boundTicks <= 0 disables the bound.
    static func bufferedTicksExceedsBound(firstDts: Int64, currentDts: Int64, boundTicks: Int64) -> Bool {
        guard boundTicks > 0, firstDts != Int64.min, currentDts >= firstDts else { return false }
        let (span, overflow) = currentDts.subtractingReportingOverflow(firstDts)
        return overflow || span >= boundTicks
    }

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
        audio: AudioConfig?
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

        do {
            try Self.configureStreamsAndWriteHeader(
                ctx: ctx,
                video: video,
                audio: audio
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
        audio: AudioConfig?
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
        switch video.doviConfig {
        case .keep:
            break
        case .strip:
            Self.stripDolbyVisionSideData(videoStream.pointee.codecpar)
        case .rewriteToProfile81:
            Self.rewriteDoviConfig(videoStream.pointee.codecpar, profile: 8, blCompatibilityID: 1)
        case .rewriteToProfile5:
            Self.rewriteDoviConfig(videoStream.pointee.codecpar, profile: 5, blCompatibilityID: 0)
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
            // AE#458: movenc reads this in mov_init, so it has to be set before write_header. With one
            // muxed audio track and no EXT-X-MEDIA rendition, mdhd is the only place AVFoundation can
            // read a track language from.
            if let language = audio.language {
                av_dict_set(&audioStream.pointee.metadata, "language", language, 0)
            }
            // AE#382: a source-container codec_tag (MPEG-TS stream type / registration descriptor) makes
            // movenc refuse the header, which the audio cascade reads as "cannot stream-copy" and bridges.
            Self.dropForeignAudioCodecTag(ctx: ctx, codecpar: audioStream.pointee.codecpar)
            // AE#221: repair a degenerate FLAC STREAMINFO before movenc serialises it into dfLa.
            if let streamInfo = Self.sanitizedFLACExtradata(UnsafePointer(audioStream.pointee.codecpar)) {
                Self.replaceExtradata(audioStream.pointee.codecpar, with: streamInfo)
            }
        }

        var opts: OpaquePointer? = nil
        defer { av_dict_free(&opts) }
        // +frag_discont with avoid_negative_ts=disabled makes tfdt carry the ABSOLUTE input dts:
        // a muxer built at a producer restart continues the session timeline instead of zero-basing
        // it. Without them, movenc forces the first sample's dts to 0 (movenc.c, the use_editlist=0 +
        // make_zero branch runs before frag_discont can), so every restart-produced segment carried
        // tfdt=0 while the VOD playlist placed it at its plan offset: an implicit timeline
        // discontinuity per restart that AVPlayer papers over for plain playback but that detaches
        // AVKit's legible renderer (Sodalite#32) and decouples playhead from loaded ranges (#93).
        // The producer guarantees non-negative output timestamps (leading head-of-stream audio is
        // dropped), so disabling the negative-ts rewrite is safe.
        av_dict_set(&opts, "movflags", "+empty_moov+default_base_moof+frag_custom+delay_moov+frag_discont", 0)
        // use_editlist=0: +delay_moov derives an elst from the first packet timestamp (restart anchor);
        // AVPlayer fetches EXT-X-MAP once so post-restart fragments play against a stale elst causing
        // lipsync drift. Position belongs in each fragment's tfdt; moov stays restart-invariant.
        av_dict_set(&opts, "use_editlist", "0", 0)
        av_dict_set(&opts, "avoid_negative_ts", "disabled", 0)

        let ret = avformat_write_header(ctx, &opts)
        guard ret >= 0 else {
            throw MuxerError.writeHeaderFailed(code: ret)
        }
    }

    // MARK: - Pump-side API

    /// Timestamps exactly as handed to the muxer, in muxer time base (#260). Returned rather than read back
    /// off the packet, because `av_interleaved_write_frame` takes ownership: "The returned packet will be
    /// blank (as if returned from av_packet_alloc()), even on error", so afterwards `pts`/`dts` are NOPTS.
    /// `pts` is what lands in the segment and therefore what `AVPlayerItem`'s timebase reads.
    struct WrittenTimestamps {
        let pts: Int64
        let dts: Int64
        static let none = WrittenTimestamps(pts: Int64.min, dts: Int64.min)
    }

    /// Write one packet via av_interleaved_write_frame (caller must rescale pts/dts to muxerVideoTimeBase / muxerAudioTimeBase).
    @discardableResult
    func writePacket(_ packet: UnsafeMutablePointer<AVPacket>) -> (rc: Int32, written: WrittenTimestamps) {
        guard let ctx = formatContext else { return (-1, .none) }

        // AE#464: the host's lip-sync offset, applied to the audio track only and BEFORE the
        // sanitizer, so the invariants it enforces hold for the timestamps that actually land in the
        // segment. Video is left alone deliberately: its timestamps are what the playlist timeline,
        // the segment boundaries and every seek are expressed in, so moving them would move the
        // session's reported position and the subtitle axis along with the sound.
        if audioDelayTicks != 0, packet.pointee.stream_index == audioOutputStreamIndex {
            if packet.pointee.pts != Int64.min { packet.pointee.pts &+= audioDelayTicks }
            if packet.pointee.dts != Int64.min { packet.pointee.dts &+= audioDelayTicks }
        }

        guard let clean = timestampSanitizer.sanitize(
            streamIndex: packet.pointee.stream_index,
            pts: packet.pointee.pts,
            dts: packet.pointee.dts
        ) else {
            av_packet_unref(packet)
            return (0, .none)
        }
        packet.pointee.pts = clean.pts
        packet.pointee.dts = clean.dts

        let streamIndex = packet.pointee.stream_index

        // [MovieClaw P38] Annex B → 4 字节长度前缀，保留全部 NAL（含 VPS/SPS/PPS）；配置记录已是 hvcC，movenc 不再转换
        if convertsAnnexBVideoSamples, streamIndex == videoOutputStreamIndex,
           let data = packet.pointee.data, packet.pointee.size > 0,
           let converted = AnnexBSampleConverter.lengthPrefixed(
               UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size))) {
            let grow = converted.count - Int(packet.pointee.size)
            if grow > 0, av_grow_packet(packet, Int32(grow)) < 0 {
                av_packet_unref(packet)
                return (-1, .none)
            }
            if grow < 0 { av_shrink_packet(packet, Int32(converted.count)) }
            converted.withUnsafeBytes { _ = memcpy(packet.pointee.data, $0.baseAddress, converted.count) }
        }

        // #64 mid-segment flush bound: cap libavformat's interleaver RAM on a very long segment
        // (degenerate sparse-keyframe plan, or an audio stream that decodes to nothing) by emitting a
        // moof+mdat into the current staging file before the buffered span grows without bound. Tracked
        // on the video output stream only; audio/subtitle packets ride along and are force-drained by the
        // flush. Flush BEFORE writing the triggering packet so it opens a fresh window.
        if streamIndex == videoOutputStreamIndex, packet.pointee.dts != Int64.min {
            let dts = packet.pointee.dts
            if fragmentWindowFirstVideoDts == Int64.min {
                fragmentWindowFirstVideoDts = dts
            } else if Self.bufferedTicksExceedsBound(
                firstDts: fragmentWindowFirstVideoDts,
                currentDts: dts,
                boundTicks: maxBufferedFragmentTicks
            ) {
                flushPendingFragment()
                fragmentWindowFirstVideoDts = dts
            }
        }

        // AE#561: a damaged source can carry a video sample whose NAL chain declares a unit that
        // reaches past the end of the packet. Apple's fMP4 parser walks that chain by addition and
        // answers the whole segment with -19602, which kills the session and every reload onto the
        // same segment; libavcodec's own decoder answers such a packet by skipping the frame, which
        // is why the file plays elsewhere. Cut the sample at its last complete NAL, which is what
        // MKVToolNix writes when it remuxes one of these files.
        if streamIndex == videoOutputStreamIndex,
           !Self.nalChainSanitizerDisabled,
           let lengthPrefixSize = videoNALLengthPrefixSize,
           let data = packet.pointee.data,
           packet.pointee.size > 0,
           let complete = sanitizerCut(
               UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
               lengthPrefixSize: lengthPrefixSize
           ) {
            truncatedVideoSamples += 1
            if truncatedVideoSamples <= 5 || truncatedVideoSamples % 100 == 0 {
                EngineLog.emit(
                    "[MP4SegmentMuxer] #561 video sample at dts=\(packet.pointee.dts) carries an "
                    + "incomplete NAL chain: \(packet.pointee.size) bytes, \(complete) of them "
                    + "complete; cut to the last whole unit (#\(truncatedVideoSamples) this muxer)",
                    category: .session
                )
            }
            if complete == 0 {
                // Nothing in the sample survives the walk, so there is no picture to hand over.
                av_packet_unref(packet)
                return (0, .none)
            }
            av_shrink_packet(packet, Int32(complete))
        }

        // av_write_frame was tried as a leak hypothesis; no impact on 8 MB/s mallocMB growth
        // (leak was Data(d) dispatch_data aliasing in AVIOReader). Reverted to interleaved for
        // cross-stream DTS monotonicity and audio+video re-ordering via libavformat.
        let rc = av_interleaved_write_frame(ctx, packet)

        // EAC3/AC-3/TrueHD moov-wedge guard (#92 follow-up). Under +delay_moov the first fragment flush
        // writes moov lazily, and FFmpeg's mp4 muxer can only build the AC-3/E-AC-3/TrueHD dac3/dec3/dmlp
        // sample-entry box once it has PARSED an audio packet. On a mid-file backward seek the producer
        // tears down and rebuilds a FRESH muxer at the restart segment; if that muxer's first moov flush
        // (a #64 RAM-cap flush, or the first segment cut) fires before any audio packet is written,
        // mov_write_moov errors -22 "Cannot write moov atom before EAC3 packets parsed", the cut fails, and
        // the segment is retried forever (AVPlayer 503 -> forever-loading). AAC never hits this (its sample
        // entry needs no parsed packet). Fix has two parts: (1) latch that an audio packet has been written;
        // (2) in the video-leads-audio case, the first audio packet arrives after a video packet is already
        // in the fragment window, proactively flush so moov is emitted WITH a parsed audio packet present
        // rather than waiting for the first cut. In the common backward-seek path the #74 pregate buffer
        // replays captured audio BEFORE the first video look-behind packet, so fragmentWindowFirstVideoDts
        // is still unset here and this proactive arm is skipped, moov is instead primed correctly at the
        // first cut, which already holds the audio in the interleaver. Idempotent once moovFlushed. Audio
        // routing/placement is untouched, so no audio dropouts. The proactive flush is scoped to
        // AC-3/E-AC-3/TrueHD (audioNeedsParsedPacketForMoov): AAC (and every other codec) never wedges and
        // must keep the exact stock code path, no extra early fragment flush, so nothing perturbs its audio.
        if streamIndex == audioOutputStreamIndex {
            audioPacketWritten = true
            if rc >= 0, clean.pts != Int64.min {
                if segmentSoundFirstPts == Int64.min { segmentSoundFirstPts = clean.pts }
                segmentSoundLastPts = clean.pts
            }
            if audioNeedsParsedPacketForMoov, !moovFlushed, fragmentWindowFirstVideoDts != Int64.min {
                flushPendingFragment()
            }
        }

        return (rc, WrittenTimestamps(pts: clean.pts, dts: clean.dts))
    }

    /// Emit a moof+mdat for everything buffered into the CURRENT staging file, without rotating the fd or
    /// advancing the segment index (#64). Mirrors `cutFragmentForNextSegment`'s drain pair minus the
    /// rotation, so libavformat's interleaver RAM is released mid-segment; the first such flush also emits
    /// ftyp+moov under +delay_moov, populating init.mp4 early instead of only at the (far-off) first cut.
    private func flushPendingFragment() {
        guard let ctx = formatContext, headerWritten, fd >= 0 else { return }
        // EAC3/AC-3/TrueHD moov-wedge guard (#92 follow-up): never let a video-only flush emit moov while
        // an audio stream whose sample entry needs a parsed packet is declared but no audio packet has been
        // written yet, mov_write_moov needs a parsed AC-3/E-AC-3/TrueHD packet for its dac3/dec3/dmlp box
        // (see writePacket). Scoped to those codecs so AAC (which never wedges) keeps the full #64 RAM-cap
        // bound. Skipping an interim #64 RAM-cap flush is harmless (the interleaver window just grows a
        // little longer); the first audio packet primes moov here or at the first cut (which already holds
        // the audio in the interleaver).
        if audioNeedsParsedPacketForMoov, !audioPacketWritten, !moovFlushed { return }
        _ = av_interleaved_write_frame(ctx, nil)
        _ = av_write_frame(ctx, nil)
        if !moovFlushed {
            moovFlushed = true
            _ = av_write_frame(ctx, nil)
        }
    }

    /// Bytes staged for the segment currently being written. Zero right after a moov prime, whose fragment
    /// bytes are deliberately discarded.
    var stagedSegmentByteCount: Int { byteCounter.bytesWrittenCurrentSegment }

    /// AE#222: mux one real audio frame and flush, so ftyp+moov (with a packet-derived dec3/dac3/dmlp)
    /// is emitted here rather than at the first cut, then drop the primed fragment's bytes from the staging
    /// file. The frame is genuine source audio, so the sample entry describes the real bitstream (Atmos/JOC
    /// signaling included); discarding its fragment keeps the delivered segment exactly as planned, with no
    /// out-of-place audio sample and no disjoint track ranges.
    private func primeMoovWithAudioFrame(_ frame: [UInt8]) {
        guard let ctx = formatContext, headerWritten, fd >= 0, !frame.isEmpty, !moovFlushed else { return }

        // The prime is only safe if +frag_discont can be re-armed afterwards (see below), so prove that first:
        // the flag is still set at this point (movenc consumes it on the first packet written), which makes
        // this a no-op that only reports whether the option is reachable on this build.
        guard let priv = ctx.pointee.priv_data,
              av_opt_set(priv, "movflags", "+frag_discont", 0) >= 0 else {
            EngineLog.emit(
                "[MP4SegmentMuxer] AE#222 cannot re-arm +frag_discont on this build; skipping the moov prime "
                + "(a prime without it would place the first real audio fragment at tfdt 0)",
                category: .session
            )
            return
        }

        var pktOpt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard let pkt = pktOpt else { return }
        defer { av_packet_free(&pktOpt) }
        guard av_new_packet(pkt, Int32(frame.count)) == 0, let dst = pkt.pointee.data else { return }
        frame.withUnsafeBytes { src in
            if let base = src.baseAddress { memcpy(dst, base, frame.count) }
        }

        // dts 0, deliberately, even though the frame's real position is later: the primed fragment is
        // discarded, so its timestamp is never presented, and re-arming +frag_discont below makes the first
        // REAL audio fragment carry its own dts regardless of what the prime claimed. Carrying the frame's
        // real position instead would be wrong on a restart muxer, whose output axis starts mid-title, and
        // would still need the same re-arm.
        let dts: Int64 = 0
        pkt.pointee.stream_index = audioOutputStreamIndex
        pkt.pointee.pts = dts
        pkt.pointee.dts = dts
        pkt.pointee.duration = 0
        pkt.pointee.flags |= AV_PKT_FLAG_KEY

        let rc = av_interleaved_write_frame(ctx, pkt)
        guard rc >= 0 else {
            EngineLog.emit(
                "[MP4SegmentMuxer] AE#222 moov prime write failed (\(rc)); first cut will defer instead",
                category: .session
            )
            return
        }
        // Drain before the fragment flush: handle_eac3 runs in mov_write_packet, so the frame must leave the
        // interleaver before mov_write_moov looks for its parsed bitstream.
        _ = av_interleaved_write_frame(ctx, nil)
        _ = av_write_frame(ctx, nil)
        moovFlushed = true
        _ = av_write_frame(ctx, nil)
        audioPacketWritten = true

        // Re-arm +frag_discont, which movenc consumed on the prime packet. Without this the next first-sample
        // of each track is treated as CONTINUING the primed fragment: movenc rewrites it to
        // `start_dts + track_duration` (movenc.c mov_write_single_packet) and tfdt is
        // `cluster[0].dts - start_dts`, so the first real audio fragment would land at tfdt 0 no matter where
        // its samples actually belong (measured: a 12 s audio start rendered at 0, i.e. 12 s out of sync).
        // Re-armed, every track keeps the absolute-dts behaviour the session relies on (see the movflags
        // comment in configureStreamsAndWriteHeader), primed or not.
        _ = av_opt_set(ctx.pointee.priv_data, "movflags", "+frag_discont", 0)

        discardStagedFragmentBytes()
        EngineLog.emit(
            "[MP4SegmentMuxer] AE#222 moov primed from a \(frame.count) B audio frame; "
            + "primed fragment discarded",
            category: .session
        )
    }

    /// Reset the current staging file to empty. Used after a moov prime, whose fragment must not be served.
    private func discardStagedFragmentBytes() {
        guard fd >= 0 else { return }
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else {
            // Leaving primed bytes in front of the real fragment would serve a segment with an out-of-place
            // audio sample; a wedge is recoverable, a mis-served segment is not.
            EngineLog.emit(
                "[MP4SegmentMuxer] AE#222 could not discard the primed fragment (errno=\(errno)); wedging",
                category: .session
            )
            isWedged = true
            return
        }
        byteCounter.bytesWrittenCurrentSegment = 0
    }

    /// Finalize the current segment and rotate fd to a fresh staging file for `nextIdx`.
    /// Returns `.completed` for the finished segment, `.failed` on a write failure, or
    /// `.deferredAwaitingAudioSampleEntry` when moov cannot be written yet (AE#222).
    /// +delay_moov first-cut wrinkle: second av_write_frame(nil) (gated by moovFlushed) handles
    /// FFmpeg splitting ftyp+moov and moof+mdat across calls; safe no-op if both arrived in one call.
    func cutFragmentForNextSegment(_ nextIdx: Int) -> CutOutcome {
        guard let ctx = formatContext, headerWritten, fd >= 0 else { return .failed }

        // AE#222: the same precondition flushPendingFragment enforces. A first cut that would write moov for a
        // packet-derived audio sample entry with no audio packet muxed yet fails -22 inside mov_write_moov,
        // leaves zero bytes, and used to surface as a failed cut (= a dead pump, three identical revives, and
        // a host fallback to server transcode). Reporting it as its own state lets the producer fetch a prime
        // frame and retry, keeping the E-AC-3 / AC-3 / TrueHD stream-copy (and any Atmos) intact.
        if audioNeedsParsedPacketForMoov, !audioPacketWritten, !moovFlushed {
            return .deferredAwaitingAudioSampleEntry
        }

        // Drain the interleaver first: av_write_frame(nil) bypasses it, so audio packets buffered
        // waiting for video DTS catch-up would spill into the next fragment (~4 trailing AC-3 frames
        // missing per segment for matroska audio-leads-video sources, ~120 ms short of #EXTINF).
        _ = av_interleaved_write_frame(ctx, nil)
        _ = av_write_frame(ctx, nil)
        if !moovFlushed {
            moovFlushed = true
            _ = av_write_frame(ctx, nil)
        }
        // New segment starts a fresh buffered-fragment window (#64).
        fragmentWindowFirstVideoDts = Int64.min

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
            return .failed
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
            return .completed(path: completedPath, bytesWritten: completedBytes)
        }

        return .completed(path: completedPath, bytesWritten: completedBytes)
    }

    /// Final teardown: flush remaining packets, write trailer (mfra discarded by splitter), close fd.
    /// Returns the final segment's (path, bytes) for cache adoption, or nil on failure.
    func finalize() -> (path: URL, bytesWritten: Int)? {
        defer { cleanup() }

        // AE#222: same precondition as the cut. A teardown flush on a muxer that never got an audio packet
        // cannot write moov either, so it would only emit two more -22s and a truncated file; there is nothing
        // to salvage (no moov means no playable segment).
        guard let ctx = formatContext, headerWritten,
              !(audioNeedsParsedPacketForMoov && !audioPacketWritten && !moovFlushed) else {
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

    /// AE#382: true when the mp4 muxer accepts `tag` for `codecID`, i.e. when the source tag may stay.
    ///
    /// The mpegts demuxer stamps `codecpar.codec_tag` with the PMT stream type (`0x87` for E-AC-3, `0x81`
    /// for AC-3) or, when the PMT carries a registration descriptor, with its fourcc (`EAC3`, `AC-3`).
    /// `avcodec_parameters_copy` carries that into the output stream, and movenc then looks the (tag, codec)
    /// pair up in the mp4 tag table, finds nothing, and refuses the whole header: "Could not find tag for
    /// codec eac3 in stream #1" -> `AVERROR(EINVAL)`. libavformat's own guard in `init_muxer` would have
    /// caught it one layer earlier, but it only fires at `FF_COMPLIANCE_NORMAL`; we run
    /// `strict_std_compliance = -2` for the Dolby Vision atoms, and below NORMAL that guard passes a foreign
    /// tag through untouched. So the tag has to be dropped here.
    ///
    /// The rule mirrors `streamcopy_init` in fftools/ffmpeg_mux_init.c, which is why an `ffmpeg -c copy`
    /// remux of the same source succeeds: keep the tag when the output format has no tag table at all, when
    /// it maps back to the same codec id (it is already an mp4 tag; `av_codec_get_id` matches
    /// case-insensitively, exactly like movenc's own validation, so a `AC-3` descriptor is fine), or when
    /// mp4 knows no tag for this codec whatsoever (nothing better to offer; movenc then fails loudly and the
    /// audio cascade bridges). Otherwise clear it and let `init_muxer` fill in the canonical tag (`ec-3`).
    static func mp4AcceptsAudioCodecTag(
        tags: UnsafePointer<OpaquePointer?>?,
        codecID: AVCodecID,
        tag: UInt32
    ) -> Bool {
        guard tag != 0 else { return true }
        guard let tags else { return true }
        if av_codec_get_id(tags, tag) == codecID { return true }
        var canonical: UInt32 = 0
        return av_codec_get_tag2(tags, codecID, &canonical) == 0
    }

    /// Applies `mp4AcceptsAudioCodecTag` to the muxer's own copy of the audio parameters.
    ///
    /// Audio only. The video tag is chosen deliberately by `VideoConfig.codecTagOverride` (every route in
    /// `CodecRoutePolicy` sets one, which is why a TS video stream never carried its `HEVC`/`H264` tag into
    /// the header), and the same rule would be actively wrong there: `dvh1` is not in the mp4 table at all
    /// (mov.c handles it), so a Dolby Vision sample entry would be silently demoted to `hvc1`.
    private static func dropForeignAudioCodecTag(
        ctx: UnsafeMutablePointer<AVFormatContext>,
        codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) {
        let tag = codecpar.pointee.codec_tag
        let codecID = codecpar.pointee.codec_id
        guard !mp4AcceptsAudioCodecTag(
            tags: ctx.pointee.oformat?.pointee.codec_tag,
            codecID: codecID,
            tag: tag
        ) else { return }
        codecpar.pointee.codec_tag = 0
        EngineLog.emit(
            "[MP4SegmentMuxer] audio codec_tag \(Self.fourCCDescription(tag)) is a source-container tag the "
            + "mp4 muxer rejects for \(avcodec_get_name(codecID).map { String(cString: $0) } ?? "?"); "
            + "cleared so the canonical sample entry is written (stream-copy stays available)",
            category: .session
        )
    }

    /// Printable form of a codec tag: the fourcc when all four bytes are printable ASCII, else hex.
    /// An MPEG-TS PMT stream type (0x87) is not a fourcc, so printing it as one would be noise.
    static func fourCCDescription(_ tag: UInt32) -> String {
        let bytes = [UInt8(tag & 0xFF), UInt8((tag >> 8) & 0xFF), UInt8((tag >> 16) & 0xFF), UInt8((tag >> 24) & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return String(format: "0x%08x", tag)
    }

    /// Mutate AV_PKT_DATA_DOVI_CONF in-place to the given profile / base-layer compatibility, always
    /// clearing `el_present_flag` (every route that rewrites emits a single layer). No-op when DOVI
    /// side data is absent. Internal, not private, so the rewrite can be asserted on directly.
    static func rewriteDoviConfig(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>,
        profile: UInt8,
        blCompatibilityID: UInt8
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
                rec.pointee.dv_profile = profile
                rec.pointee.dv_bl_signal_compatibility_id = blCompatibilityID
                rec.pointee.el_present_flag = 0
            }
            return
        }
    }

    /// Strip AV_PKT_DATA_DOVI_CONF from coded_side_data; hvc1+dvcC trips VT -12906.
    static func stripDolbyVisionSideData(
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

    /// AE#221: FLAC `STREAMINFO` with an illegal `min_blocksize`, clamped up to `max_blocksize`.
    /// Returns nil when there is nothing to repair, or nothing to repair it with.
    ///
    /// The spec floor is 16; 0 shows up in the wild because an MKV -> MP4 remux copies the source
    /// `CodecPrivate` verbatim and encoders that never rewrite `STREAMINFO` after a streaming pass leave the
    /// field zeroed. libavcodec's decoder ignores it, so the source demuxes and plays everywhere else, but
    /// CoreMedia validates it and rejects the whole audio sample description: the HLS asset fails to open
    /// with `-12848` (surfacing as AVFoundation `-11829 "Cannot Open"`) on the first segment. Stream-copy
    /// hands the source extradata straight to movenc, which writes it into `dfLa` byte for byte, so without
    /// this the defect reaches every segment of the session.
    ///
    /// `max_blocksize` is the only blocksize the container attests to, so it is the sole honest clamp
    /// target; when it is illegal too there is nothing to copy from and inventing a value would be a guess.
    /// Bisected on the reporter's asset: `min_blocksize` alone decides whether the session opens, and
    /// `total_samples` (equally wrong there, describing the pre-cut source) does not, so nothing else moves.
    static func sanitizedFLACExtradata(
        _ codecpar: UnsafePointer<AVCodecParameters>
    ) -> [UInt8]? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_FLAC,
              let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size >= Int32(flacStreamInfoSize) else { return nil }

        var bytes = [UInt8](UnsafeBufferPointer(start: extradata, count: Int(codecpar.pointee.extradata_size)))
        let minBlockSize = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let maxBlockSize = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        guard minBlockSize < flacMinimumBlockSize, maxBlockSize >= flacMinimumBlockSize else { return nil }

        bytes[0] = UInt8(maxBlockSize >> 8)
        bytes[1] = UInt8(maxBlockSize & 0xFF)
        EngineLog.emit(
            "[MP4SegmentMuxer] FLAC STREAMINFO min_blocksize=\(minBlockSize) is illegal, "
            + "clamped to max_blocksize=\(maxBlockSize) so dfLa passes CoreMedia validation",
            category: .session
        )
        return bytes
    }

    /// FLAC `STREAMINFO` payload length, and the spec's floor for both blocksize fields.
    private static let flacStreamInfoSize = 34
    private static let flacMinimumBlockSize: UInt16 = 16

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

