import Foundation
import CoreVideo
import AVFoundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension AetherEngine {

    // MARK: - Probe

    /// One-shot container + stream metadata read; no HLS server or detail-pass decoders.
    /// Omit `limits` and `cancellation` to retain the existing open path. Opting in controls the entire
    /// probe, starting before source I/O; see `ProbeLimits` and `ProbeCancellation`.
    ///
    /// - Parameters:
    ///   - url: Media source (`file://`, `http://`, or `https://`).
    ///   - options: Forwarded for `httpHeaders` only; other flags ignored (no playback session).
    ///   - limits: Optional shared input, packet and monotonic time limits.
    ///   - cancellation: Optional one-shot token, callable from another thread or a task cancellation handler.
    /// - Throws: Open errors, `ProbeError` for a controlled stop, or `CancellationError`.
    public nonisolated static func probe(
        url: URL,
        options: LoadOptions = .init(),
        limits: ProbeLimits? = nil,
        cancellation: ProbeCancellation? = nil
    ) throws -> SourceProbe {
        try probe(source: .url(url), options: options, detecting: [],
                  limits: limits, cancellation: cancellation)
    }

    /// `probe(url:)` for a custom byte source (AetherEngine#27). Caller retains reader ownership; cursor is left at an unspecified position and `close()` is NOT called. Pass a fresh (or rewound) reader to `load(source:)` afterwards. `SourceProbe.url` is `aether-custom://source` for custom readers.
    public nonisolated static func probe(
        source: MediaSource,
        options: LoadOptions = .init(),
        limits: ProbeLimits? = nil,
        cancellation: ProbeCancellation? = nil
    ) throws -> SourceProbe {
        try probe(source: source, options: options, detecting: [],
                  limits: limits, cancellation: cancellation)
    }

    // MARK: - Bounded, opt-in Atmos/JOC detail probe

    /// `probe(url:)` plus a bounded, OPT-IN decode pass that authoritatively resolves E-AC-3 JOC (Dolby Atmos)
    /// on the default (or explicitly named) audio track.
    ///
    /// FFmpeg's E-AC-3 decoder only populates `AVCodecContext.profile == AV_PROFILE_EAC3_DDP_ATMOS` (30) AFTER
    /// decoding at least one audio frame. The lightweight `probe(url:)` / `probe(source:)` path never opens a
    /// decoder -- it only demuxes and runs `avformat_find_stream_info` -- so `TrackInfo.isAtmos` from those
    /// calls reflects only whatever `codecpar.profile` the container already carries pre-decode, which is
    /// unresolved for JOC in the common case. Call `probeDetectingAtmos` instead of `probe(url:)` ONLY when a
    /// host specifically needs an authoritative "Dolby Atmos" badge (e.g. a details screen): it is strictly
    /// more expensive than `probe(url:)` (it opens a real EAC3 decoder and decodes at least one frame) and
    /// MUST NOT be used on the playback-start critical path. `probe(url:)` / `probe(source:)` themselves are
    /// demux-only unless detail detection is requested. Whole-probe controls are separately opt-in.
    ///
    /// The decode pass is bounded by `atmosDetection` (packet-count / byte / wall-clock caps -- see
    /// `AtmosDetectionOptions`): it stops at the first successfully decoded audio frame, or at whichever cap
    /// is hit first. There is no video decode, no HLS server, and no playback session. The demuxer, decoder
    /// context, packet, and frame are all closed / freed before returning on every path, including error
    /// paths. A malformed / no-audio / non-EAC3 source is tolerated: the decode pass simply degrades to "not
    /// authoritatively Atmos" (the base probe's `TrackInfo.isAtmos`, which a pre-existing container-declared
    /// profile 30 can still leave `true` -- this API only ever ADDS confirmation, never removes a pre-decode
    /// signal) instead of throwing or hanging.
    ///
    /// - Parameters:
    ///   - url: Media source, forwarded verbatim to `probe(url:)`.
    ///   - options: Forwarded verbatim to `probe(url:)` (`httpHeaders` only; other flags ignored, same as `probe(url:)`).
    ///   - atmosDetection: Bounds + optional explicit track override for the decode pass. Defaults resolve the
    ///     demuxer's own default audio track (`Demuxer.audioStreamIndex`) and cap the decode attempt at 64
    ///     packets / 8 MiB / 2 s wall clock (soft -- see `AtmosDetectionOptions` doc for the same
    ///     AVIO-blocking caveat `Demuxer.seekBounded` already documents: a single blocking `av_read_frame()`
    ///     on a stalled remote socket can still run past the wall-clock budget before the next check fires).
    /// - Throws: Open errors, `ProbeError` for whole-probe stops, or `CancellationError`. Decode-side
    ///   failures (bad EAC3 extradata, no decoder built, a malformed frame, EOF before any frame decodes) are
    ///   NEVER thrown; they only affect whether Atmos gets confirmed.
    public nonisolated static func probeDetectingAtmos(
        url: URL,
        options: LoadOptions = .init(),
        atmosDetection: AtmosDetectionOptions = .init(),
        limits: ProbeLimits? = nil,
        cancellation: ProbeCancellation? = nil
    ) throws -> SourceProbe {
        try probe(source: .url(url), options: options, detecting: .atmos, atmosDetection: atmosDetection,
                  limits: limits, cancellation: cancellation)
    }

    /// `probeDetectingAtmos(url:)` for a custom byte source. Same reader-ownership contract as `probe(source:)`:
    /// the caller retains ownership, the cursor is left at an unspecified position, and `close()` is NOT called.
    public nonisolated static func probeDetectingAtmos(
        source: MediaSource,
        options: LoadOptions = .init(),
        atmosDetection: AtmosDetectionOptions = .init(),
        limits: ProbeLimits? = nil,
        cancellation: ProbeCancellation? = nil
    ) throws -> SourceProbe {
        try probe(source: source, options: options, detecting: .atmos, atmosDetection: atmosDetection,
                  limits: limits, cancellation: cancellation)
    }

    // MARK: - Bounded, opt-in detail probe

    /// `probe(url:)` plus the bounded, OPT-IN passes named in `detecting`, over ONE open handle to the source.
    ///
    /// Everything the base probe reports comes from the container. Two things a host wants to put on a
    /// details screen are not in there:
    ///
    /// - **Dolby Atmos**, which for E-AC-3 means the JOC flag in the dependent substream and only exists
    ///   post-decode (`.atmos`, see `AtmosDetectionOptions`), and
    /// - **HDR10+**, whose ST 2094-40 metadata rides an in-band ITU-T T.35 SEI that no demuxer parses
    ///   (`.hdr10Plus`, see `HDR10PlusDetectionOptions`), and
    /// - **HDR Vivid**, whose CUVA metadata rides the same kind of SEI in HEVC (`.hdrVivid`, scanned in
    ///   the same pass and under the same `HDR10PlusDetectionOptions` budget).
    ///
    /// Both cost reads past `avformat_find_stream_info`, which is why `probe(url:)` does neither.
    /// Neither is for the playback-start critical path. Asking for both runs both
    /// over one demuxer: the HDR10+ scan first, out of the packets `find_stream_info` already
    /// queued, then the queue-flushing seek the Atmos decode pass needs.
    ///
    /// Both passes are additive and one-directional. They can only ever SET `isAtmos` /
    /// `carriesHDR10PlusMetadata` / `carriesHDRVividMetadata`, never clear what the container already declared, and a pass that hits a cap
    /// leaves the base probe's answer exactly where it was.
    ///
    /// - Parameters:
    ///   - url: Media source, forwarded verbatim to `probe(url:)`.
    ///   - options: Forwarded verbatim to `probe(url:)` (`httpHeaders` only).
    ///   - detecting: Which extra passes to run. Empty is the header probe with the same controls.
    ///   - atmosDetection: Bounds + optional track override for the Atmos decode pass. Ignored without `.atmos`.
    ///   - hdr10PlusDetection: Bounds for the HDR10+ / HDR Vivid scan. Ignored without either.
    ///   - limits: Whole-probe limits, shared across open, stream analysis, seeks and both passes.
    ///   - cancellation: Cancellation reaches HTTP I/O or the custom reader's `cancel()`.
    /// - Throws: Open errors, `ProbeError` for whole-probe stops, or `CancellationError`. Ordinary
    ///   pass-side failures and per-pass caps only mean a detail stays unconfirmed.
    public nonisolated static func probe(
        url: URL,
        options: LoadOptions = .init(),
        detecting: ProbeDetail,
        atmosDetection: AtmosDetectionOptions = .init(),
        hdr10PlusDetection: HDR10PlusDetectionOptions = .init(),
        limits: ProbeLimits? = nil,
        cancellation: ProbeCancellation? = nil
    ) throws -> SourceProbe {
        try probe(source: .url(url), options: options, detecting: detecting,
                  atmosDetection: atmosDetection, hdr10PlusDetection: hdr10PlusDetection,
                  limits: limits, cancellation: cancellation)
    }

    /// `probe(url:detecting:)` for a custom byte source (SMB, WebDAV, a disc image, anything behind an
    /// `IOReader`). Same reader-ownership contract as `probe(source:)`: the caller retains ownership, the
    /// cursor is left at an unspecified position, and `close()` is NOT called.
    public nonisolated static func probe(
        source: MediaSource,
        options: LoadOptions = .init(),
        detecting: ProbeDetail,
        atmosDetection: AtmosDetectionOptions = .init(),
        hdr10PlusDetection: HDR10PlusDetectionOptions = .init(),
        limits: ProbeLimits? = nil,
        cancellation: ProbeCancellation? = nil
    ) throws -> SourceProbe {
        let control = try limits != nil || cancellation != nil
            ? ProbeControl(limits: limits, cancellation: cancellation) : nil
        let demuxer = Demuxer()
        demuxer.probeControl = control
        var ownedReader: IOReader?
        func closeInput() {
            demuxer.close()
            ownedReader?.close()
            ownedReader = nil
        }
        defer {
            closeInput()
            // Native calls have ended; join interruption callbacks before the host can reuse its reader.
            control?.finish()
        }
        let displayURL: URL
        do {
            try control?.check()
            switch source {
            case .url(let u):
                displayURL = u
                if let control {
                    let reader: IOReader
                    if u.isFileURL {
                        guard let file = FileIOReader(url: u) else { throw DemuxerError.openFailed(code: -1) }
                        reader = file
                    } else if ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
                        reader = ProbeHTTPReader(url: u, headers: options.httpHeaders, control: control)
                    } else {
                        throw ProbeError.unsupportedURL
                    }
                    ownedReader = reader
                    let counted = ProbeIOReader(reader: reader, control: control)
                    try control.check()
                    var isDASHManifest = false
                    if let http = reader as? ProbeHTTPReader {
                        do {
                            try http.open()
                        } catch AVIOReaderError.dashManifest {
                            isDASHManifest = true
                        }
                    }
                    try control.check()
                    if isDASHManifest {
                        // AE#859: an MPD is opened by the demuxer's own DASH path, which reads several
                        // files. Deadline and cancellation are honoured inside libavformat's reads
                        // through the demuxer's interrupt, but the manifest and head requests run to
                        // their own timeouts, and the byte budget, which counts one source, does not apply.
                        reader.close()
                        ownedReader = nil
                        try demuxer.open(url: u, extraHeaders: options.httpHeaders)
                    } else {
                        try demuxer.open(reader: counted, profile: probeOpenProfile(limits: limits))
                    }
                } else {
                    try demuxer.open(url: u, extraHeaders: options.httpHeaders)
                }
            case .custom(let reader, let formatHint):
                displayURL = URL(string: "aether-custom://source")!
                if let control {
                    try demuxer.open(reader: ProbeIOReader(reader: reader, control: control),
                                     formatHint: formatHint, profile: probeOpenProfile(limits: limits))
                } else {
                    try demuxer.open(reader: reader, formatHint: formatHint)
                }
            }
            try control?.check()
        } catch {
            try control?.check()
            throw error
        }

        var probe = makeSourceProbe(demuxer: demuxer, displayURL: displayURL)

        // HDR10+ first, and before any seek: `avformat_find_stream_info` leaves its packets queued and
        // `av_read_frame` hands those back first, so at the head of a container the scan gets video packets
        // that have already been paid for. Running it after the Atmos pass would mean re-reading them.
        let dynamicTargets = detecting.intersection([.hdr10Plus, .hdrVivid])
        if !dynamicTargets.isEmpty {
            let outcome = Self.detectHDR10Plus(
                demuxer: demuxer, videoIndex: demuxer.videoStreamIndex, options: hdr10PlusDetection,
                targets: dynamicTargets)
            try control?.check()
            if outcome.carriesHDR10Plus {
                probe = Self.enrichHDR10Plus(base: probe)
            }
            if outcome.carriesHDRVivid {
                probe.carriesHDRVividMetadata = true
            }
        }

        let targetIndex = Self.atmosDecodeTargetIndex(
            options: atmosDetection, defaultAudioStreamIndex: demuxer.audioStreamIndex)
        if detecting.contains(.atmos),
           demuxer.stream(at: targetIndex)?.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3,
           !probe.audioTracks.contains(where: { $0.id == Int(targetIndex) && $0.isAtmos }) {
            try control?.check()
            // Flush what is still queued before the decode pass starts. Those packets were read before
            // `detectAtmos` sets AVDISCARD_ALL, so libavformat hands them back regardless of the hint: on a
            // source whose audio does not sit at the head, the pass burns its whole foreign-packet fuse on
            // that queue and reports "not Atmos" for genuinely Atmos media without ever reading a byte of
            // audio. Seeking to the start discards the queue so the discard takes effect from the first read.
            // A source that cannot seek is no worse off than before. (It also puts a source the HDR10+ scan
            // has just walked back at the start.)
            demuxer.seekBounded(to: 0, timeout: Self.atmosProbeFlushSeekTimeout)
            try control?.check()
            let outcome = Self.detectAtmos(demuxer: demuxer, targetIndex: targetIndex, options: atmosDetection)
            try control?.check()
            if outcome.confirmedAtmos {
                probe = Self.enrichAtmos(base: probe, confirmedTrackID: Int(targetIndex))
            }
        }

        closeInput()
        try control?.complete()
        return probe
    }

    /// The caller's own limits are the only thing allowed to bind a controlled probe.
    ///
    /// Built from `.playback` rather than `.stillExtraction`: a host that asks for limits is asking to
    /// bound the COST, not to be answered from a shallower read, and a second hidden budget (the still
    /// extractor's 2 MiB probe and 2 s analysis) would make `probe(url:limits:)` report fewer streams
    /// than `probe(url:)` on exactly the sparse sources where that matters. `maxInputBytes` clamps the
    /// probe size, and the deadline plus the FFmpeg interrupt callback bound the analysis instead.
    /// The profile's AVIO tuning is not read on this path at all: a controlled probe always opens
    /// through a reader, whose own transport settings live in `ProbeHTTPReader`.
    ///
    /// The recordless Dolby Vision audit stays off, and that is a real gap rather than a tuning choice:
    /// it opens the source a SECOND time by URL (`DolbyVisionRecordAudit.rpuProfileOfSource`), traffic
    /// this probe's budget and cancellation do not reach, and `open(reader:)` clears `auditSource`
    /// regardless. A controlled probe of an untagged 10-bit HEVC source therefore reports no Dolby
    /// Vision record where an uncontrolled one does (AE#567).
    private nonisolated static func probeOpenProfile(limits: ProbeLimits?) -> DemuxerOpenProfile {
        guard let limits else { return .playback }
        var profile = DemuxerOpenProfile.playback
        // FFmpeg has a minimum probe size. The input seam still enforces smaller caller limits.
        profile.probesize = max(32, min(profile.probesize, limits.maxInputBytes))
        profile.auditsRecordlessDolbyVision = false
        profile.readerLabel = "probe"
        return profile
    }

    /// Flip `isAtmos` to `true` on exactly the one confirmed audio track, leaving everything else identical.
    ///
    /// Mutates copies rather than rebuilding the structs field by field: both memberwise inits carry defaulted
    /// parameters, so a hand-copy silently drops any field added later and the compiler stays quiet about it.
    nonisolated static func enrichAtmos(base: SourceProbe, confirmedTrackID: Int) -> SourceProbe {
        // Additive only: a track already marked isAtmos by the base probe is left as it is; this only ever
        // sets true, never clears a pre-decode signal.
        var probe = base
        probe.audioTracks = base.audioTracks.map { track in
            guard track.id == confirmedTrackID else { return track }
            var confirmed = track
            confirmed.isAtmos = true
            return confirmed
        }
        return probe
    }

    /// Record HDR10+ carriage on a probe: set the flag, and move `videoFormat` if it is the one label the
    /// payload describes (see `hdr10PlusUpgradedFormat`).
    ///
    /// Mutates a copy rather than rebuilding the struct field by field: the memberwise init carries defaulted
    /// parameters, so a hand-copy silently drops any field added later and the compiler stays quiet about it.
    nonisolated static func enrichHDR10Plus(base: SourceProbe) -> SourceProbe {
        var probe = base
        probe.carriesHDR10PlusMetadata = true
        probe.videoFormat = Self.hdr10PlusUpgradedFormat(base.videoFormat)
        return probe
    }

    /// Assemble a `SourceProbe` from an open demuxer. Shared by static probe entry points and `load(source:)`'s internal probe stage so all report identical metadata.
    nonisolated static func makeSourceProbe(
        demuxer: Demuxer,
        displayURL: URL
    ) -> SourceProbe {
        var detectedFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedCodecID: AVCodecID = AV_CODEC_ID_NONE
        var width: Int32 = 0
        var height: Int32 = 0
        var dvProfileNum: Int? = nil
        var streamFormat: VideoStreamFormat? = nil
        let videoIdx = demuxer.videoStreamIndex
        if videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) {
            detectedFormat = Self.detectVideoFormat(stream: stream)
            detectedRate = Self.detectFrameRate(stream: stream)
            detectedCodecID = stream.pointee.codecpar.pointee.codec_id
            width = stream.pointee.codecpar.pointee.width
            height = stream.pointee.codecpar.pointee.height
            dvProfileNum = Self.dvProfile(stream: stream)
            streamFormat = VideoStreamFormat(codecpar: stream.pointee.codecpar)
        }
        let codecName: String? = {
            guard detectedCodecID != AV_CODEC_ID_NONE,
                  let cstr = avcodec_get_name(detectedCodecID) else { return nil }
            return String(cString: cstr)
        }()
        let snappedRate = detectedRate.flatMap { FrameRateSnap.snap($0) }
        let duration = demuxer.duration
        // Heuristic only: duration absent + network scheme. aether-custom:// never matches. Hosts decide the final LoadOptions.isLive.
        let liveSchemes: Set<String> = ["http", "https", "udp", "rtp", "rtsp"]
        let isLive = duration <= 0
            && liveSchemes.contains(displayURL.scheme?.lowercased() ?? "")

        return SourceProbe(
            url: displayURL,
            durationSeconds: duration,
            videoFormat: detectedFormat,
            videoCodecID: Int32(bitPattern: detectedCodecID.rawValue),
            videoCodecName: codecName,
            videoWidth: width,
            videoHeight: height,
            videoFrameRate: snappedRate,
            isDolbyVision: detectedFormat == .dolbyVision,
            dvProfile: dvProfileNum,
            audioTracks: demuxer.audioTrackInfos(),
            subtitleTracks: demuxer.subtitleTrackInfos(),
            metadata: demuxer.mediaMetadata(),
            isLive: isLive,
            videoStreamFormat: streamFormat
        )
    }

    // MARK: - SW-decoder repro probe

    /// SW-decode repro for `aetherctl swdecode` (MPEG-4 Part 2, MPEG-2, VC-1, AV1 without HW). No render target. Discriminates: `openSucceeded == false` (missing libavcodec decoder / bad extradata), `framesDecoded == 0` (pixel-format conversion failure / all non-IDR), `framesDecoded > 0` (SW path healthy; downstream issue if real playback still hangs).
    public nonisolated static func swDecodeProbe(
        url: URL,
        maxPackets: Int = 100,
        options: LoadOptions = .init()
    ) throws -> SoftwareDecodeProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }
        return try swDecodeProbeRun(demuxer: demuxer, maxPackets: maxPackets)
    }

    /// SW-decode an in-memory media blob (e.g. an HLS `init.mp4` + one fMP4 segment concatenation) with a
    /// fresh decoder and no render target. Used by `aetherctl segverify` to test whether one segment is
    /// independently decodable: `framesDecoded == 0` means the blob carries no usable IRAP to start from
    /// (the #92 open-GOP defect, where the segment's IRAP landed in the previous segment).
    public nonisolated static func swDecodeProbe(
        data: Data,
        formatHint: String? = "mp4",
        maxPackets: Int = 200,
        options: LoadOptions = .init()
    ) throws -> SoftwareDecodeProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: formatHint)
        defer { demuxer.close() }
        return try swDecodeProbeRun(demuxer: demuxer, maxPackets: maxPackets)
    }

    /// #407: how many decoded picture timestamps `swDecodeProbe` retains. Enough to read a reorder
    /// cadence off, small enough that a long probe stays a diagnostic.
    private nonisolated static let probeFrameTimeCap = 240

    private nonisolated static func swDecodeProbeRun(
        demuxer: Demuxer,
        maxPackets: Int
    ) throws -> SoftwareDecodeProbeResult {
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            throw AetherEngineError.noVideoStream
        }

        let codecID = stream.pointee.codecpar.pointee.codec_id
        let codecName: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "unknown" }
            return String(cString: cstr)
        }()
        let width = stream.pointee.codecpar.pointee.width
        let height = stream.pointee.codecpar.pointee.height

        let decoder = SoftwareVideoDecoder()
        // Probe decodes a handful of frames and throws them away: no Metal pipeline for that.
        decoder.deinterlaceConfig = DeinterlaceConfig(mode: .software)
        // Class for captured-by-reference mutable accumulators; the onFrame closure fires SYNCHRONOUSLY on this same
        // thread inside avcodec_send_packet / receive_frame (the probe drives decode inline, no demux thread). The
        // DecodedFrameHandler is @Sendable for the off-actor playback path, so this single-threaded capture is an
        // honest @unchecked Sendable exception.
        final class Accum: @unchecked Sendable {
            var framesDecoded = 0
            var firstFramePixelFormat: String?
            var firstFrameWidth: Int = 0
            var firstFrameHeight: Int = 0
            var firstFrameColor: String?
            /// #407: in decoder output order, i.e. presentation order. Capped so a long run stays a
            /// diagnostic rather than an allocation.
            var frameTimesSeconds: [Double] = []
        }
        let accum = Accum()

        do {
            try decoder.open(stream: stream) { pixelBuffer, pts, _ in
                accum.framesDecoded += 1
                if accum.frameTimesSeconds.count < Self.probeFrameTimeCap {
                    accum.frameTimesSeconds.append(pts.seconds)
                }
                if accum.firstFramePixelFormat == nil {
                    let pfType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                    let bytes: [UInt8] = [
                        UInt8((pfType >> 24) & 0xff),
                        UInt8((pfType >> 16) & 0xff),
                        UInt8((pfType >> 8) & 0xff),
                        UInt8(pfType & 0xff),
                    ]
                    let printable = bytes.map { ($0 >= 0x20 && $0 < 0x7f) ? $0 : 0x2e }
                    let fourCC = String(bytes: printable, encoding: .ascii) ?? "????"
                    accum.firstFramePixelFormat = "\(fourCC) (0x\(String(pfType, radix: 16)))"
                    accum.firstFrameWidth = CVPixelBufferGetWidth(pixelBuffer)
                    accum.firstFrameHeight = CVPixelBufferGetHeight(pixelBuffer)
                    accum.firstFrameColor = [
                        kCVImageBufferColorPrimariesKey,
                        kCVImageBufferTransferFunctionKey,
                        kCVImageBufferYCbCrMatrixKey,
                    ].map { (CVBufferCopyAttachment(pixelBuffer, $0, nil) as? String) ?? "-" }
                        .joined(separator: " / ")
                }
            }
        } catch {
            return SoftwareDecodeProbeResult(
                codecName: codecName,
                codecID: Int32(bitPattern: codecID.rawValue),
                width: width,
                height: height,
                openSucceeded: false,
                openError: "\(error)",
                packetsRead: 0,
                packetsFedToDecoder: 0,
                framesDecoded: 0,
                firstFramePixelFormat: nil,
                firstFrameWidth: 0,
                firstFrameHeight: 0,
                firstError: "decoder open failed: \(error)"
            )
        }
        defer { decoder.close() }

        var packetsRead = 0
        var packetsFedToDecoder = 0
        var firstError: String?

        while packetsRead < maxPackets, accum.framesDecoded < maxPackets {
            do {
                guard let packet = try demuxer.readPacket() else {
                    break  // EOF
                }
                packetsRead += 1
                if packet.pointee.stream_index == videoIdx {
                    packetsFedToDecoder += 1
                    decoder.decode(packet: packet)
                }
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            } catch {
                if firstError == nil {
                    firstError = "\(error)"
                }
                break
            }
        }
        decoder.flush()

        return SoftwareDecodeProbeResult(
            codecName: codecName,
            codecID: Int32(bitPattern: codecID.rawValue),
            width: width,
            height: height,
            openSucceeded: true,
            openError: nil,
            packetsRead: packetsRead,
            packetsFedToDecoder: packetsFedToDecoder,
            framesDecoded: accum.framesDecoded,
            firstFramePixelFormat: accum.firstFramePixelFormat,
            firstFrameWidth: accum.firstFrameWidth,
            firstFrameHeight: accum.firstFrameHeight,
            firstError: firstError,
            frameTimesSeconds: accum.frameTimesSeconds,
            firstFrameColor: accum.firstFrameColor
        )
    }

    /// Pure, nonisolated, and unit-testable: audio-only path when the host requested it OR a *successful* probe
    /// genuinely found no video stream.
    ///
    /// A failed probe (`probeOpened == false`) must NOT route here. probeOpened false means we never looked, not
    /// that there is no video; conflating the two silently degrades a real video file to the audio-only backend
    /// when the open-time probe loses to a transient origin 429 (#78). On probe failure the caller falls through
    /// to the native path so HLSVideoEngine reopens and discovers the stream (it demonstrably can).
    nonisolated static func shouldUseAudioOnlyPath(audioOnlyRequested: Bool, probeOpened: Bool, hasVideoStream: Bool) -> Bool {
        if audioOnlyRequested { return true }
        return probeOpened && !hasVideoStream
    }

    /// What load() does about the previous session's display criteria once routing is known.
    ///
    /// The load seam preserves the criteria through stopInternal (a nil write bounces the panel through
    /// SDR before apply() re-negotiates the same mode, #128). That moves the cleanup decision here:
    enum LoadDisplayCriteriaAction {
        /// Engine-writer video path: apply() overwrites the preserved criteria in place, single handshake.
        case applyFresh
        /// No engine apply() this session (audio-only, or criteria owned by AVKit or the host): clear a criteria a
        /// previous session left applied, so it can't keep the panel in DV/HDR under music playback or
        /// fight AVKit's own write. `DisplayCriteriaController.reset()` stays didApply-gated, so this is
        /// a no-op for hosts that never route criteria through the engine.
        case clearStale
    }

    nonisolated static func loadDisplayCriteriaAction(engineWritesCriteria: Bool, audioOnlyPath: Bool) -> LoadDisplayCriteriaAction {
        (!engineWritesCriteria || audioOnlyPath) ? .clearStale : .applyFresh
    }

    /// AE#348: whether the pre-flight gate after an HDR/DV write runs beside the load rather than in front
    /// of it.
    ///
    /// The gate guards the routing read (master or media, from the settled panel) and the AVPlayerItem,
    /// not the segment production in front of them: `HLSVideoEngine.prepare()` reads nothing about the
    /// panel. Serialising the two put a ~96 Mbit/s title's first two segments (2.0 s to cut) behind a
    /// switch that ended 1.5 s before playback started (Apple TV 4K, DV, badrabbit 2026-10-16). The gate
    /// still starts at the write and the routing read still waits for it, so the read is never taken
    /// earlier than before.
    ///
    /// Live keeps the serial order: its join and rejoin are timed against the edge, and the overlap has not
    /// been measured there.
    nonisolated static func preflightGateRunsBesideLoad(isLive: Bool) -> Bool {
        !isLive
    }

    /// #274: how long the post-load play-gate blind-polls for a panel switch to start.
    ///
    /// The gate exists for one case: a sole-writer host (`suppressDisplayCriteria`) whose criteria write
    /// lands during the load, from AVKit's auto path reading dvcC off the live AVPlayerItem. DV P5 has no
    /// HDR10 base layer, so its first frame must not hit a panel that is still SDR, and 1000 ms is the
    /// budget that made that land (5d60dbb2). Every other session paid the same 1000 ms for a switch that
    /// could not arrive, which is dead startup time, not safety:
    ///
    /// - Engine-writer sessions wrote their criteria synchronously *before* `loadNative`. Whatever switch
    ///   that write triggers has started long before the gate runs (and `.willSwitch` already settled it in
    ///   the pre-flight), so a second full blind poll buys nothing.
    /// - SDR content reaches no dynamic-range switch at all. The only write anyone can still make is
    ///   rate-only, and the engine already declines to gate its own rate-only writes (`apply()` returns
    ///   `.applied` with no pre-flight wait) because those switches are sub-second.
    ///
    /// AE#842: a host-owned session counts as written-before-load too. The host wrote its criteria (or none)
    /// before calling `load()`, so like the engine's own write there is nothing inbound to blind-poll for.
    ///
    /// `formatKnown` is false when the open-time probe failed: the real range is then unknown and a DV write
    /// may still be inbound, so a suppressed host keeps the full budget.
    ///
    /// `noWriterExpected` is a `.secondary` load (Sodalite#175): nobody writes criteria for it, so there is
    /// no inbound switch to wait for.
    nonisolated static func playGateGrace(
        criteriaUnchanged: Bool,
        criteriaWrittenBeforeLoad: Bool,
        formatKnown: Bool,
        effectiveFormat: VideoFormat,
        noWriterExpected: Bool = false
    ) -> DisplayCriteriaController.StartGrace {
        // #133: the criteria were already active, nothing was written, nothing can settle.
        if criteriaUnchanged || noWriterExpected { return .skip }
        if criteriaWrittenBeforeLoad { return .brief }
        guard formatKnown else { return .full }
        return effectiveFormat == .sdr ? .brief : .full
    }

    /// Sodalite#175: a secondary never writes criteria, whatever the host passed.
    nonisolated static func applyingSharedOutputRole(_ options: LoadOptions) -> LoadOptions {
        guard options.sharedOutputRole == .secondary else { return options }
        var adjusted = options
        adjusted.suppressDisplayCriteria = true
        adjusted.displayCriteriaOwner = .engine
        return adjusted
    }

    /// Sodalite#175: Now Playing belongs to the primary; a secondary never takes it.
    nonisolated static func ownsNowPlaying(hostOptIn: Bool, role: SharedOutputRole) -> Bool {
        hostOptIn && role == .primary
    }

    /// Whitelist (not blacklist) of AVPlayer-native audio codecs: AAC, MP3, MP2, ALAC, AC-3/E-AC-3, LPCM, FLAC (native since iOS/tvOS 11). Anything else falls back to `AudioPlaybackHost` (FFmpeg).
    nonisolated static func avPlayerCanDecodeAudio(_ codecID: AVCodecID) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AAC,
             AV_CODEC_ID_MP3,
             AV_CODEC_ID_MP2,
             AV_CODEC_ID_MP1,
             AV_CODEC_ID_ALAC,
             AV_CODEC_ID_FLAC,
             AV_CODEC_ID_AC3,
             AV_CODEC_ID_EAC3,
             AV_CODEC_ID_PCM_S16LE,
             AV_CODEC_ID_PCM_S16BE,
             AV_CODEC_ID_PCM_S24LE,
             AV_CODEC_ID_PCM_S24BE,
             AV_CODEC_ID_PCM_F32LE:
            return true
        default:
            return false
        }
    }

    /// Whether an audio-only session goes to AVPlayer (`AudioAVPlayerHost`) rather than libavcodec
    /// (`AudioPlaybackHost`). AVPlayer needs a URL it can read and a codec on the whitelist, and
    /// takes neither a FLAC whose blocks are under CoreMedia's floor (AE#764), nor a FLAC whose frames
    /// are smaller than `STREAMINFO`'s `max_blocksize` (AE#946, AVPlayer mistimes it), nor a raw FLAC
    /// file (AE#946, AVPlayer seeks it to the wrong place), nor a session the host asked onto `.software`.
    nonisolated static func audioOnlyUsesAVPlayer(
        codecID: AVCodecID,
        isCustomSource: Bool,
        flacBlocksTooSmall: Bool,
        flacFramesMistimed: Bool,
        flacSeeksMisplaced: Bool,
        preferred: DecodePath
    ) -> Bool {
        !isCustomSource && avPlayerCanDecodeAudio(codecID) && !flacBlocksTooSmall && !flacFramesMistimed
            && !flacSeeksMisplaced && preferred != .software
    }

    /// AE#946: CoreMedia's parser for the raw FLAC container ignores `SEEKTABLE` and places a seek by
    /// an estimated byte rate, then stamps the requested time on whatever frame it reached. On real
    /// music that lands seconds early (a 96/24 track with a quiet intro: 120 s played from 100.3 s,
    /// reported as 120 s), so the clock runs ahead of the sound and the track ends while it is still
    /// playing. Playback from zero is exact, and FLAC inside MP4 (`dfLa`) seeks exactly; only the
    /// bare `flac` container is affected, whatever encoder wrote it.
    nonisolated static func coreMediaMisplacesSeeks(codecID: AVCodecID, containerFormatName: String?) -> Bool {
        codecID == AV_CODEC_ID_FLAC && containerFormatName == "flac"
    }

    /// AE#946: how many packets the audio-only dispatch looks through for the first FLAC frame. An
    /// attached cover picture is delivered as a packet ahead of the audio.
    static let flacFramePeekPacketBudget = 8

    /// AE#946: the block size of `streamIndex`'s first FLAC frame, peeked without consuming it (the FFmpeg
    /// host reuses this demuxer and reads the same packets). nil when no fixed-blocksize frame turned up.
    static func firstFLACFrameBlockSize(demuxer: Demuxer, streamIndex: Int32) -> UInt16? {
        var blockSize: UInt16?
        try? demuxer.peekPackets(maxPackets: flacFramePeekPacketBudget) { packet in
            guard packet.pointee.stream_index == streamIndex else { return false }
            if let data = packet.pointee.data, packet.pointee.size > 0 {
                blockSize = FLACStreamInfo.fixedStrategyFrameBlockSize(
                    UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
            }
            return true
        }
        return blockSize
    }

    // MARK: - Audio track selection (#72)

    /// Resolve the audio stream index selected by an explicit host `override` or, failing that, the
    /// ordered `preferredLanguages` policy. Returns nil when neither applies, so the caller keeps the
    /// container / session default pick (i.e. an empty preference list with no override is a no-op,
    /// behaviourally identical to before #72). Pure and nonisolated so a host can avoid a separate
    /// audio pre-probe or a post-load `selectAudioTrack` reload (#72).
    nonisolated static func selectAudioIndex(
        tracks: [TrackInfo],
        override: Int32?,
        preferredLanguages: [String],
        prefersObjectAudio: Bool = false,
        defaultIndex: Int32 = -1
    ) -> Int32? {
        // Explicit host override wins, but only when it names a real audio track (else fall through).
        if let override, tracks.contains(where: { $0.id == Int(override) }) {
            return override
        }
        // AE#919: within a language the programme mix wins over audio description and commentary, which a
        // file may list first. #731: with object rendering on, TrueHD Atmos and DTS:X keep their heights,
        // which no other track of the same language does better, so they win the remaining ties. Never
        // across a language.
        let secondaryRank: (Int) -> Int = { index in
            let track = tracks[index]
            let descriptorRank = track.isVisualImpaired || track.isCommentary ? 1 : 0
            let atmosRank = prefersObjectAudio && !isRenderableObjectAudio(track) ? 1 : 0
            return descriptorRank * 2 + atmosRank
        }
        // Each preference is scanned across all tracks in order, so an earlier preference on a later
        // track still beats a later preference on an earlier track. Within one preference the most
        // specific tag wins, so an "en-GB" preference takes en-GB over eng over en-US (#590).
        if let index = bestLanguageMatchIndex(
            languages: tracks.map(\.language),
            preferredLanguages: preferredLanguages,
            kind: .audio,
            secondaryRank: secondaryRank
        ) {
            return Int32(tracks[index].id)
        }
        // No language preference decided it: the session would take its default track, so a TrueHD
        // Atmos or DTS:X track in that track's language replaces it.
        // Same dub only: a script or region both tags state and disagree on (es-ES against es-419) is
        // another dub, not another format of this one.
        guard prefersObjectAudio,
              let fallback = tracks.first(where: { $0.id == Int(defaultIndex) }),
              !isRenderableObjectAudio(fallback)
        else { return nil }
        // With no track tagged at all (`und`, empty, none) there is nothing to tell dubs apart by, and
        // demo discs like Dolby's Unfold tag nothing and list the E-AC-3 JOC as the probe's best stream.
        // One tagged track is enough to show the file names its dubs, so the default then stays.
        guard let language = fallback.language, LanguageTag(language) != nil else {
            guard tracks.allSatisfy({ LanguageTag($0.language) == nil }) else { return nil }
            return tracks.first(where: isRenderableObjectAudio).map { Int32($0.id) }
        }
        let candidates = tracks.compactMap { track -> (track: TrackInfo, rank: Int)? in
            guard isRenderableObjectAudio(track),
                  let rank = languageMatchRank(track.language, language, kind: .audio),
                  rank / 3 < 2, rank % 3 < 2 else { return nil }
            return (track, rank)
        }
        guard let atmos = candidates.min(by: { $0.rank < $1.rank })?.track else { return nil }
        return Int32(atmos.id)
    }

    /// TrueHD that FFmpeg marked Atmos while probing (mlpdec sets the profile from the major sync), and
    /// not a commentary or an audio description. `TrackInfo.isAtmos` stays the E-AC-3 JOC answer it is
    /// documented as.
    nonisolated static func isRenderableTrueHDAtmos(_ track: TrackInfo) -> Bool {
        linksTrueHDObjectDecoder && track.codec.lowercased() == "truehd"
            && !track.isCommentary && !track.isVisualImpaired && !track.isExternal
            && track.profile == trueHDAtmosProfileName
    }

    nonisolated private static let trueHDAtmosProfileName =
        VideoStreamFormat.profileName(codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS)

    /// DTS that FFmpeg labelled DTS:X while probing, and not a commentary or an audio description. FFmpeg
    /// names only two of DTS:X's markers, so a DTS-HD MA track it labels plain can be DTS:X as well; that
    /// one is still rendered when it is the track that plays, but only the label can be ranked before
    /// playback.
    /// `TrackInfo.codec` is the decoder's name, `dca` for libavcodec's DTS decoder; `dts` is the
    /// codec's own name, which a build without the decoder would report.
    nonisolated static func isRenderableDTSX(_ track: TrackInfo) -> Bool {
        linksDTSXObjectDecoder && ["dca", "dts"].contains(track.codec.lowercased())
            && !track.isCommentary && !track.isVisualImpaired && !track.isExternal
            && dtsxProfileNames.contains(track.profile ?? "")
    }

    nonisolated private static let dtsxProfileNames = Set([AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX]
        .compactMap { VideoStreamFormat.profileName(codecID: AV_CODEC_ID_DTS, profile: $0) })

    /// Whether the build links the codec's object decoder (#777: its package trait). Without it the codec
    /// keeps the channel bridge, so the pick has no heights to prefer it for.
    nonisolated static let linksTrueHDObjectDecoder = OptionalComponent.trueHDObjectAudio.isBuiltIn

    nonisolated static let linksDTSXObjectDecoder = OptionalComponent.dtsxObjectAudio.isBuiltIn

    /// The tracks object rendering keeps the heights of.
    nonisolated static func isRenderableObjectAudio(_ track: TrackInfo) -> Bool {
        isRenderableTrueHDAtmos(track) || isRenderableDTSX(track)
    }

    /// Resolve the subtitle track to auto-activate from `LoadOptions.preferredSubtitleLanguages`: within the
    /// first preference (scanned in order) that has any language match, the best track by language
    /// specificity and then by `subtitlePickRank`; else nil. Preference order dominates rank, so an earlier preference always beats a
    /// later one. Unlike audio there is no explicit index override and no default fallback: nil means "keep
    /// subtitles off" (the default). Pure and nonisolated; the engine calls this at the end of a successful
    /// load and, on a hit, activates the track via the host-overlay path so a host without container metadata
    /// of its own need not language-match and rank `subtitleTracks` itself (#73).
    nonisolated static func selectSubtitleIndex(
        tracks: [TrackInfo],
        preferredLanguages: [String]
    ) -> Int32? {
        guard let index = bestLanguageMatchIndex(
            languages: tracks.map(\.language),
            preferredLanguages: preferredLanguages,
            kind: .subtitle,
            secondaryRank: { subtitlePickRank(tracks[$0]) }
        ) else { return nil }
        return Int32(tracks[index].id)
    }

    /// The subtitle track to activate at the end of a load: `LoadOptions.initialSubtitleTrackID` when it
    /// names a track in `tracks`, else the best `preferredSubtitleLanguages` match, else nil (subtitles
    /// off). The explicit id wins because a host that names a track has already made the choice the
    /// language ranking approximates; an id that matches nothing is ignored rather than treated as an
    /// error, so a stale server index cannot fail a load. Pure and nonisolated, like `selectSubtitleIndex`.
    nonisolated static func resolveInitialSubtitleIndex(
        tracks: [TrackInfo],
        initialTrackID: Int?,
        preferredLanguages: [String]
    ) -> Int32? {
        if let initialTrackID, tracks.contains(where: { $0.id == initialTrackID }) {
            return Int32(initialTrackID)
        }
        return selectSubtitleIndex(tracks: tracks, preferredLanguages: preferredLanguages)
    }

    /// Lower rank wins. The descriptor axis (full > SDH > forced > commentary, from container dispositions)
    /// dominates; text-vs-bitmap is a tiebreaker (text preferred, since host styling only applies to text
    /// cues). Sourced from `TrackInfo` disposition flags rather than title strings, so it is locale-robust.
    /// Used by `selectSubtitleIndex` and exposed so a host can rank `subtitleTracks` the same way (#73).
    nonisolated static func subtitlePickRank(_ track: TrackInfo) -> Int {
        let descriptorRank: Int
        if track.isCommentary {
            descriptorRank = 3
        } else if track.isForced {
            descriptorRank = 2
        } else if track.isHearingImpaired {
            descriptorRank = 1
        } else {
            descriptorRank = 0
        }
        return descriptorRank * 2 + (isBitmapSubtitleCodec(track.codec) ? 1 : 0)
    }

    /// True when the codec is a bitmap (image) subtitle. `TrackInfo.codec` is the libavcodec DECODER name
    /// (pgssub / dvdsub / dvbsub / xsub), not the descriptor name (hdmv_pgs_subtitle / dvb_subtitle / ...);
    /// matched case-insensitively by substring so either form is tolerated. Bitmap subs cannot mux into
    /// mov_text, so the native-subtitle rendition (#55) excludes them and only the host overlay renders them.
    nonisolated static func isBitmapSubtitleCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return ["pgs", "hdmv", "dvb_sub", "dvbsub", "dvd_sub", "dvdsub", "vobsub", "xsub"]
            .contains(where: { c.contains($0) })
    }

    /// True when the codec is DVB Teletext, the only subtitle codec whose decode depends on a page
    /// number (`txt_page`, see `EmbeddedSubtitleDecoder.decoderOptions`). Both spellings the track
    /// list can carry are covered: the libzvbi DECODER name (`libzvbi_teletextdec`) when FFmpeg was
    /// built with it, and the descriptor name (`dvb_teletext`) when it was not. Matched by substring
    /// for the same reason `isBitmapSubtitleCodec` is (#364).
    nonisolated static func isTeletextSubtitleCodec(_ codec: String) -> Bool {
        codec.lowercased().contains("teletext")
    }

    /// True when the codec is an in-band CEA-608/708 caption track (`eia_608` / QuickTime `c608`). These
    /// have no FFmpeg decoder, so they bypass the side-demuxer `EmbeddedSubtitleDecoder` and are served by
    /// the producer CC tap, which parses their `cc_data` directly. (#77)
    nonisolated static func isEmbeddedClosedCaptionCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c == "eia_608" || c == "eia_708" || c == "cea708" || c == "cea_708"
    }

    /// Whether the two labels name the same language, ignoring how specific either one is: case,
    /// ISO 639-1 / 639-2 (B and T) / 639-3 / English name, and any region or script subtag. So
    /// `"en" == "eng" == "english" == "en-US"`, `"de" == "deu" == "ger"`. Empty / nil / `und` / a
    /// free-form track name never matches. Shared by audio (#72) and subtitle (#73) selection.
    ///
    /// This is the plain yes-or-no question, for callers that only need to know whether a track is
    /// in the right language. Selection goes through `languageMatchRank` instead, which keeps the
    /// specificity this deliberately drops (#590).
    nonisolated static func languageMatches(_ trackLanguage: String?, _ preferred: String) -> Bool {
        languageMatchRank(trackLanguage, preferred, kind: .audio) != nil
    }

    /// ISO 639-1 / 639-2/T / 639-2/B equivalence classes plus the common English names, which is the
    /// part ICU cannot resolve: `LanguageTag.canonicalPrimary` reads every set through
    /// `AudioLanguageMap` first and only falls back to this table. Mirrors the host-side table so
    /// engine-resolved selection matches what hosts computed before #72.
    nonisolated static let languageSynonyms: [Set<String>] = [
        ["de", "deu", "ger", "german"], ["en", "eng", "english"], ["fr", "fra", "fre", "french"],
        ["es", "spa", "spanish"], ["it", "ita", "italian"], ["ja", "jpn", "japanese"],
        ["ko", "kor", "korean"], ["zh", "zho", "chi", "chinese"], ["pt", "por", "portuguese"],
        ["ru", "rus", "russian"], ["nl", "nld", "dut", "dutch"], ["sv", "swe", "swedish"],
        ["da", "dan", "danish"], ["no", "nor", "norwegian"], ["nb", "nob"], ["nn", "nno"],
        ["fi", "fin", "finnish"], ["pl", "pol", "polish"], ["cs", "ces", "cze", "czech"],
        ["hu", "hun", "hungarian"], ["tr", "tur", "turkish"], ["el", "ell", "gre", "greek"],
        ["ar", "ara", "arabic"], ["he", "heb", "hebrew"], ["hi", "hin", "hindi"],
        ["id", "ind", "indonesian"], ["th", "tha", "thai"], ["vi", "vie", "vietnamese"],
        ["uk", "ukr", "ukrainian"], ["ro", "ron", "rum", "romanian"], ["sk", "slk", "slo", "slovak"],
        ["hr", "hrv", "croatian"], ["bg", "bul", "bulgarian"], ["sr", "srp", "serbian"],
        ["pt-br", "por"], ["pt-pt", "por"],
    ]

    // MARK: - Decoder identity helpers

    /// User-facing label for the active video decoder. nil when no video track (AV_CODEC_ID_NONE).
    /// isSoftware describes the decoder, not the playback path: the software host can use VideoToolbox.
    static func videoDecoderLabel(codecID: AVCodecID, isSoftware: Bool) -> String? {
        guard codecID != AV_CODEC_ID_NONE else { return nil }
        let name: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "video" }
            return String(cString: cstr).uppercased()
        }()
        if isSoftware {
            switch codecID {
            case AV_CODEC_ID_AV1: return "dav1d \(name) (SW)"
            default:              return "libavcodec \(name) (SW)"
            }
        }
        return "VideoToolbox \(name) (HW)"
    }

    /// User-facing label for the active audio pipeline on the SW path. nil when no audio track. AE#462:
    /// `activeIndex` is the HOST's resolved index, never the engine's pick. The pick says which track was
    /// asked for; a session whose decoder refused to open serves none, and this label used to name one
    /// for it. `route` is the host's `audioRoute`: the PCM decode is libavcodec into CoreAudio, the Atmos
    /// routes are named the way the loopback route names its own APAC ("TRUEHD Atmos → APAC 7.1.4").
    nonisolated static func softwareAudioDecoderLabel(
        audioTracks: [TrackInfo],
        activeIndex: Int32,
        route: SoftwareAtmosRoute = .pcm
    ) -> String? {
        guard activeIndex >= 0,
              let track = audioTracks.first(where: { $0.id == Int(activeIndex) }) else {
            return nil
        }
        let codec = track.codec.uppercased()
        switch route {
        case .pcm: return "libavcodec \(codec) → CoreAudio"
        case .compressedEAC3JOC: return "\(codec) Atmos → renderer (compressed)"
        case .apac(let layout):
            return codec.hasPrefix("DTS") ? "DTS:X → APAC \(layout.rawValue)" : "\(codec) Atmos → APAC \(layout.rawValue)"
        case .pcmBed(let layout):
            return codec.hasPrefix("DTS") ? "DTS:X → PCM \(layout.rawValue)" : "\(codec) Atmos → PCM \(layout.rawValue)"
        }
    }

    // MARK: - Format / frame-rate probing

    nonisolated static func detectVideoFormat(stream: UnsafeMutablePointer<AVStream>) -> VideoFormat {
        let codecpar = stream.pointee.codecpar.pointee
        // dvcC/dvvC side-data is the authoritative DV marker, independent of color_trc. Branching on color_trc first mis-classifies HLG-base P8.4 (reported as HLG) and unspecified-trc P5 (reported as SDR) -- both emit hvc1 instead of dvh1, so the panel never enters DV (DrHurt#4 2026-05-26: only P8.1 produced dolbyvision pre-fix).
        if Self.streamHasDV(stream: stream) {
            return .dolbyVision
        }
        let transfer = codecpar.color_trc
        if transfer == AVCOL_TRC_SMPTE2084 { return .hdr10 }
        if transfer == AVCOL_TRC_ARIB_STD_B67 { return .hlg }
        return .sdr
    }

    /// Clamp source format to what the panel can present. On non-DV panels, publishes the HDR10/HLG base layer format (hvc1 path); SDR-base DV (P8.2) collapses to .sdr (HLSVideoEngine refuses to serve it).
    ///
    /// The capability table is passed in rather than read here: on the platforms with no per-mode API it
    /// carries the host's own assertion (AE#493), and the caller is the one holding this session's options.
    nonisolated static func effectiveVideoFormat(
        detected: VideoFormat,
        stream: UnsafeMutablePointer<AVStream>,
        capabilities: DisplayCapabilities
    ) -> VideoFormat {
        effectiveVideoFormat(detected: detected,
                             baseTransfer: stream.pointee.codecpar.pointee.color_trc,
                             capabilities: capabilities)
    }

    /// The clamp itself, off the stream so it can be exercised against a capability table the test machine
    /// does not have. AE#493 turned on what a table of `false` does to a source, and nothing pinned it.
    nonisolated static func effectiveVideoFormat(
        detected: VideoFormat,
        baseTransfer: AVColorTransferCharacteristic,
        capabilities: DisplayCapabilities
    ) -> VideoFormat {
        guard detected == .dolbyVision else { return detected }
        if capabilities.supportsDolbyVision { return .dolbyVision }
        if baseTransfer == AVCOL_TRC_ARIB_STD_B67 {
            return capabilities.supportsHLG ? .hlg : .sdr
        }
        // SMPTE2084 base (P5/P7/P8.1) or unspecified trc (P5 with empty VUI): AVPlayer tonemaps via dvh1 on non-DV panel.
        return capabilities.supportsHDR10 ? .hdr10 : .sdr
    }

    /// The format to publish as `videoFormat`: what the panel is presenting, not what the file carries
    /// (`sourceVideoFormat` is that). One funnel for both the load-time answer and the late one the #459
    /// playback probe can produce seconds later, so the two cannot drift apart.
    ///
    /// The HDR10+ carry-over exists because the two can arrive in either order. `handleHDR10PlusDetected`
    /// upgrades a `videoFormat` that already reads `.hdr10`, and on a panel whose answer is still pending
    /// the label reads `.sdr` when the T.35 payload lands, so the upgrade is skipped and the evidence
    /// survives in the session's latch alone. Republishing the bare effective format would then relabel a
    /// proven HDR10+ session "HDR10+ -> HDR10", trading one wrong arrow for a quieter one.
    ///
    /// The latch rather than `sourceVideoFormat == .hdr10Plus`: a Dolby Vision source can carry an HDR10+
    /// layer too (Blu-ray Profile 7, and Profile 8.1 remuxed from one), `sourceVideoFormat` keeps saying
    /// Dolby Vision for it, and a display without Dolby Vision presents that HDR10+ base (AE#459).
    nonisolated static func presentedVideoFormat(
        effectiveFormat: VideoFormat,
        panelPresentsHDR: Bool,
        sourceCarriesHDR10Plus: Bool
    ) -> VideoFormat {
        guard effectiveFormat != .sdr, panelPresentsHDR else { return .sdr }
        if effectiveFormat == .hdr10, sourceCarriesHDR10Plus { return .hdr10Plus }
        return effectiveFormat
    }

    /// AE#515 (from #493): the label a loopback session takes back from the item AVFoundation is playing,
    /// where the platform has no capability table to clamp it against.
    ///
    /// `AVPlayer.availableHDRModes` is `API_UNAVAILABLE(macos)`, so `supportsDolbyVision` is false on
    /// every Mac unless the host asserts it, and `effectiveVideoFormat` sends a Profile 5 PQ base to
    /// `.hdr10`. Measured with the assertion off on a 16" XDR: Profile 5 and Profile 8.1 both strobe
    /// against Dolby's reference content, so the RPU reaches the pixels with no claim set anywhere and
    /// the clamp was moving nothing but the label. `NativeAVPlayerHost` already parses the served item's
    /// sample entry, and a `dvh1` / `dvhe` entry is that session's own evidence.
    ///
    /// An upgrade rather than the unconditional mirror `loadRemoteHLS` wires, and each term earns its
    /// place by a case it keeps out:
    ///
    /// - `perModeCapabilitiesObservable` keeps tvOS and iOS out, where the table answers and the label
    ///   follows it. A Profile 5 master carries `dvh1` on every panel, so the mirror would relabel a
    ///   tvOS session parked in SDR, or one on an HDR10-only panel, as Dolby Vision.
    /// - `.hdr10` is the only clamped value taken back. `.sdr` is the clamp being right about a display
    ///   that presents no HDR at all, and `.dolbyVision` is a session that already says so.
    /// - the item term is what the evidence actually is. Profile 8.1 reports `hvc1` and composes anyway,
    ///   which nothing in the stack reports, so it keeps `.hdr10`.
    /// - the source term is the engine's own probe agreeing. A probe that did not call the source Dolby
    ///   Vision leaves no RPU to compose, and the disagreement is a packaging fault worth seeing rather
    ///   than a label to publish.
    ///
    /// `nil` means leave the published label alone.
    nonisolated static func dolbyVisionLabelUpgrade(
        publishedFormat: VideoFormat,
        sourceFormat: VideoFormat,
        itemFormat: VideoFormat,
        perModeCapabilitiesObservable: Bool
    ) -> VideoFormat? {
        guard !perModeCapabilitiesObservable,
              publishedFormat == .hdr10,
              sourceFormat == .dolbyVision,
              itemFormat == .dolbyVision else { return nil }
        return .dolbyVision
    }

    /// AE#459: what this session takes the panel to be presenting, from the host's assertion and the
    /// engine's own criteria readout.
    ///
    /// The assertion is an OR term over the readout, never a replacement for it, and it defaults to
    /// `false`, so a host that asserts nothing is where it was. Both halves are here because each one goes
    /// silent somewhere. `currentPanelIsHDR()` rests on the EDR headroom, which only answers around a
    /// dynamic-range TRANSITION: an Apple TV whose output is locked to HDR never makes one and reads as an
    /// SDR panel forever, and on tvOS 27 the property stopped moving on at least one box even across a real
    /// switch. A suppressed-criteria host has no readout to take at all, which is why the assertion used to
    /// count only there.
    ///
    /// `nil` readout means suppressed, not false: the difference matters in the log, where a suppressed
    /// session has nothing to compare the assertion against.
    nonisolated static func sessionPanelPresentsHDR(hostAsserts: Bool, criteriaReadout: Bool?) -> Bool {
        hostAsserts || (criteriaReadout ?? false)
    }

    /// AE#459: what the ROUTE may assume about the panel, which is deliberately more than what the LABEL
    /// may claim.
    ///
    /// The label answers "what is this display presenting", and where nothing can answer it the honest
    /// value is SDR. The route answers a different question, "will AVFoundation accept an HDR master
    /// here", and there is exactly one component that knows: AVFoundation. Predicting its answer from
    /// `UIScreen.currentEDRHeadroom` was never more than a proxy, and the proxy is measurably unreliable.
    /// Measured on one Apple TV 4K 3rd gen on tvOS 26.6 against a panel whose own info display reported
    /// HDR at the time: the property read a flat 1.00 across 46 samples of HDR content and the session
    /// routed media-direct, and later the same day, same box, same output format, same title, it read
    /// 1.20. The TV reporting HDR while the property read 1.00 is what rules out a silently dropped link,
    /// so the panel was presenting HDR and the property was wrong about it. What moves it is NOT
    /// established: the "4K HDR10+" output mode was blamed and then refuted by running the comparison back
    /// the other way. The only pattern the data supports is a correlation, that every correct reading
    /// follows a recent output-format change while every wrong one comes from a box parked in one mode.
    ///
    /// So on an unproven panel the engine serves the master and lets acceptance or refusal be the readout
    /// the display will not give. What refusal costs was measured before this was built rather than
    /// assumed: output locked to 4K SDR with Match Content off, master forced, a PQ title. AVPlayer failed
    /// the item with `-11868` after 54 ms with zero `errorLog` events, `MasterFallbackDecision` swapped the
    /// media playlist onto the live `AVPlayer` at the same position, and the item was playing 223 ms after
    /// the master was served, with no visible black frame.
    ///
    /// Three terms, each earning its place. A panel that PROVED itself short-circuits, so a box on plain
    /// "4K HDR" never attempts anything and pays nothing. Eligibility is required, so a display that
    /// cannot do HDR at all is never offered a master it has no business receiving. And the refusal is
    /// latched for the process, so the 223 ms is paid at most once by a genuinely SDR panel rather than on
    /// every title.
    ///
    /// What this deliberately does NOT do is move the label. Acceptance is better evidence than the
    /// headroom ever was, but publishing HDR because a master was SERVED would claim exactly what this
    /// issue was opened about, one frame earlier.
    nonisolated static func sessionRoutesAsHDRPanel(
        panelPresentsHDR: Bool,
        attemptWhenUnproven: Bool,
        displayEligibleForHDR: Bool,
        panelRefusedHDRMaster: Bool
    ) -> Bool {
        if panelPresentsHDR { return true }
        return attemptWhenUnproven && displayEligibleForHDR && !panelRefusedHDRMaster
    }

    /// AE#667: whether an unproven master has to wait for the running switch before it is served.
    ///
    /// The pre-flight releases the load at its 2 s cap while an HDR switch is still in flight, on purpose:
    /// the overlap is what #348 kept, and a proven or media route has nothing to lose by it. The unproven
    /// master is the one route that does, because its whole point is to let AVPlayer's acceptance stand in
    /// for the readout, and AVPlayer answers for the mode the panel is in NOW. Measured on an Apple TV 4K
    /// (tvOS 27.0, HDR10 panel): master served 140 ms after the cap, `-11868` 80 ms later, the switch
    /// ending 660 ms after that, and the refusal latched, so every later HDR title went media-direct.
    ///
    /// Only a switch seen to START counts. A DV switch that never reports would make this an unbounded wait
    /// for an end that cannot arrive, and a proven panel is excluded because it already answered. What the
    /// wait costs is the prep that used to overlap the switch's tail; the play gate held the first frame
    /// until that end anyway.
    nonisolated static func unprovenMasterAwaitsSwitchEnd(
        routesAsHDR: Bool,
        panelPresentsHDR: Bool,
        switchRunning: Bool
    ) -> Bool {
        routesAsHDR && !panelPresentsHDR && switchRunning
    }

    /// AE#541: the HDR route of an in-place rebuild, composed from the same two decisions the load makes.
    ///
    /// The readout and the display's eligibility are the load's, because the rebuild runs no handshake to
    /// take them again. The host's assertion and the attempt lever are the session's current options, so a
    /// `reloadAtCurrentPosition(applying:)` correction still moves the route. The refusal latch is read
    /// now rather than carried: a master the panel refused after the load must not be served again.
    nonisolated static func reloadRoutesAsHDRPanel(
        hostAsserts: Bool,
        criteriaReadoutAtLoad: Bool?,
        attemptWhenUnproven: Bool,
        displayEligibleForHDR: Bool,
        panelRefusedHDRMaster: Bool
    ) -> Bool {
        sessionRoutesAsHDRPanel(
            panelPresentsHDR: sessionPanelPresentsHDR(
                hostAsserts: hostAsserts, criteriaReadout: criteriaReadoutAtLoad),
            attemptWhenUnproven: attemptWhenUnproven,
            displayEligibleForHDR: displayEligibleForHDR,
            panelRefusedHDRMaster: panelRefusedHDRMaster)
    }

    /// AE#535: the display table an in-place rebuild routes from, on the same principle as the route
    /// above: the load's answer, because the rebuild is not a fresh look at the display.
    ///
    /// `displayCapabilities` answers at call time, and on tvOS a backgrounded process is answered for its
    /// own state rather than for the display: every per-mode term reads false, the user's Match-Content
    /// preference reads `off` beside it, and both come back when the app does. A route-death rebuild lands
    /// inside that window (measured at 0.7 s and 2.5 s after the transition), so a table read there would
    /// clamp an HDR source to SDR and withhold its master on a panel nothing had changed. The host's
    /// Dolby Vision assertion is applied to it here, as at the load, because it is the session's claim and
    /// not an observation. Reading now is the fallback for a rebuild with no load behind it, which the
    /// engine's own paths cannot produce.
    nonisolated static func reloadDisplayCapabilities(
        observedAtLoad: DisplayCapabilities?,
        hostAssertsDolbyVision: Bool,
        readNow: () -> DisplayCapabilities
    ) -> DisplayCapabilities {
        (observedAtLoad ?? readNow()).assertingDolbyVision(hostAssertsDolbyVision)
    }

    private nonisolated static func streamHasDV(stream: UnsafeMutablePointer<AVStream>) -> Bool {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else {
            return false
        }
        for i in 0..<nb {
            if sideData[i].type == AV_PKT_DATA_DOVI_CONF {
                return true
            }
        }
        return false
    }

    /// Dolby Vision profile number (5, 7, 8, 10) from the dvcC/dvvC configuration record; nil when the stream carries no DV side-data. Same record `CodecRoutePolicy` reads for routing.
    nonisolated static func dvProfile(stream: UnsafeMutablePointer<AVStream>) -> Int? {
        dvConfig(stream: stream)?.profile
    }

    /// Profile + base-layer signal compatibility ID from the dvcC/dvvC record (compat 0 = IPT-only, no
    /// compatible base layer). nil when the stream carries no DV side-data.
    nonisolated static func dvConfig(stream: UnsafeMutablePointer<AVStream>) -> (profile: Int, blCompatID: Int)? {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else {
            return nil
        }
        for i in 0..<nb {
            let item = sideData[i]
            guard item.type == AV_PKT_DATA_DOVI_CONF, let raw = item.data, item.size >= 8 else { continue }
            let record = raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
            return (Int(record.dv_profile), Int(record.dv_bl_signal_compatibility_id))
        }
        return nil
    }

    /// Container-declared stereo layout from stream-level `AV_PKT_DATA_STEREO3D` side data; nil when the
    /// stream declares none. Matroska StereoMode is the source in practice (`stereo_mode` in the stream
    /// metadata is the same value spelled as a string). Read for routing: `AV_STEREO3D_FRAMESEQUENCE` on
    /// H.264 means both views ride in one track (#435).
    nonisolated static func stereo3DType(stream: UnsafeMutablePointer<AVStream>) -> AVStereo3DType? {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else { return nil }
        for i in 0..<nb {
            let item = sideData[i]
            guard item.type == AV_PKT_DATA_STEREO3D, let raw = item.data,
                  item.size >= MemoryLayout<AVStereo3D>.size else { continue }
            return raw.withMemoryRebound(to: AVStereo3D.self, capacity: 1) { $0.pointee.type }
        }
        return nil
    }

    nonisolated static func detectFrameRate(stream: UnsafeMutablePointer<AVStream>) -> Double? {
        let avg = stream.pointee.avg_frame_rate
        if avg.den > 0 && avg.num > 0 {
            return Double(avg.num) / Double(avg.den)
        }
        let r = stream.pointee.r_frame_rate
        if r.den > 0 && r.num > 0 {
            return Double(r.num) / Double(r.den)
        }
        return nil
    }
}
