import Foundation
import Libavformat
import Libavcodec
import Libavutil


/// The stages an `open()` passes through, reported as each one finishes (#361). Deliberately the
/// three boundaries the open really has: the source coming up (connection, redirects, first bytes),
/// the container being identified, and the stream analysis that follows it. There is nothing
/// finer-grained to report without reaching inside `avformat_find_stream_info`, which is exactly the
/// stretch a host most wants to see move, and exactly the one FFmpeg does not narrate.
enum DemuxerOpenStage: Sendable {
    /// The AVIO provider is open: the connection stands and its first bytes have arrived.
    case sourceOpened
    /// `avformat_open_input` returned.
    case containerOpened
    /// The stream-info pass returned (or was skipped by profile).
    case streamsProbed
}

/// Open-time tuning for the demuxer + its AVIO reader. `.playback` is
/// the default everywhere; `.stillExtraction` switches AVIO to a
/// random-access profile (no read-ahead prefetch, small seek chunk) and
/// a minimal probe budget for fast single-keyframe fetches.
struct DemuxerOpenProfile: Sendable {
    var probesize: Int64
    var maxAnalyzeDuration: Int64
    var avioPrefetch: Bool
    var avioChunkSize: Int
    /// Per-chunk Range-request budget for the seekable (still-extraction) AVIO path.
    /// Caps how long a single cold/stalled chunk read can park before it aborts.
    /// Playback keeps the generous default (its reads go through the persistent
    /// reader; this only bounds open-time size probes). Still extraction shrinks it
    /// so a disposable scrub thumbnail never freezes the decode queue (issue #27).
    var avioRequestTimeout: TimeInterval
    /// Retry passes for a failed seekable chunk fetch. Still extraction drops this
    /// to a single attempt: a scrub thumbnail is disposable and must fail fast
    /// rather than ride a 3-retry-times-2-URL storm (issue #27).
    var avioMaxRetries: Int
    /// Skip the open-time `avformat_find_stream_info` pass (#87). The subtitle side demuxer
    /// needs only `codec_id` / `codec_type`, which `avformat_open_input` already resolves from the
    /// container header / MPEG-TS PMT; find_stream_info would then chase sparse PGS/DVB tracks to the
    /// probe cap (they keep `has_codec_parameters` false, the #75 pattern) for nothing, landing as a
    /// flat ~5 s startup stall on a slow remote source. The side reader runs a bounded find_stream_info
    /// on demand only if its target subtitle stream's codec is genuinely unresolved at open.
    var skipStreamInfo: Bool

    /// Bound the open-time data connection to a finite byte range (`bytes=0-N`) instead of the
    /// open-ended `bytes=0-` streaming request (#93 residual). Only the wedge-restart reopen sets
    /// it: that open reads the container header plus the bounded find_stream_info probe and nothing
    /// more (the producer seeks to the target and streams from there on its own connection), so an
    /// open-ended full-file GET is both wasteful and, on origins that serve `bytes=0-` as a slow
    /// dribble while answering finite ranges instantly, the whole 22 s reopen cost (device trace:
    /// one offset=0 read, stallWaits=14/20.5 s, next to a bounded sibling range that answered in
    /// ~300 ms). nil keeps the open-ended behaviour for every other path (playback streams from 0).
    var boundedInitialFetch: Int64? = nil

    /// `LoadOptions.sequentialOrigin`: the origin fabricates range answers, so the AVIO reader must
    /// run its forward-only streaming mode (one unranged GET from byte 0) and never issue a ranged
    /// request. Lives in the profile so the probe demuxer, the session demuxer, and every fresh
    /// reopen (wedge restart, revive) inherit it together.
    var avioSequentialOnly: Bool = false

    /// `LoadOptions.declaredDurationSeconds`: caller-trusted duration override consumed by
    /// `Demuxer.duration`. Rides in the profile next to `avioSequentialOnly` because the two are a
    /// pair: without the ranged tail read the container resolves no duration of its own.
    var declaredDurationSeconds: Double? = nil

    /// #240: what to call this demuxer's network reader in the log. Several readers run against the
    /// same origin at once (the pump, the subtitle forward prefetcher, the native subtitle readers),
    /// and a connection line without a name cannot say which one opened it: the reporter of #240 read
    /// one reader's generation counter as several concurrent connections, because nothing in the line
    /// distinguished them. Defaults to the pump, since every other path builds its profile explicitly.
    var readerLabel: String = "pump"

    /// A copy of `self` under a different reader name, for two call sites that share a profile.
    func withReaderLabel(_ label: String) -> DemuxerOpenProfile {
        var copy = self
        copy.readerLabel = label
        return copy
    }

    static let playback = DemuxerOpenProfile(
        probesize: 50 * 1024 * 1024,
        maxAnalyzeDuration: 60 * 1_000_000,
        avioPrefetch: true,
        avioChunkSize: 4 * 1024 * 1024,
        avioRequestTimeout: 35,
        avioMaxRetries: 3,
        skipStreamInfo: false
    )

    static let stillExtraction = DemuxerOpenProfile(
        probesize: 2 * 1024 * 1024,
        maxAnalyzeDuration: 2 * 1_000_000,
        avioPrefetch: false,
        avioChunkSize: 1 * 1024 * 1024,
        avioRequestTimeout: 8,
        avioMaxRetries: 1,
        skipStreamInfo: false,
        readerLabel: "extract"
    )

    /// A copy of `self` with only the open-time probe budget overridden (#68).
    /// A non-nil `probesize` / `maxAnalyzeDuration` replaces the matching field;
    /// nil keeps the receiver's value. The AVIO tuning (prefetch, chunk size,
    /// per-chunk read budget, retries) always rides through untouched so a caller
    /// can shrink find_stream_info on a slow remote source without disturbing the
    /// streaming reader.
    func withProbeBudget(probesize: Int64?, maxAnalyzeDuration: Int64?) -> DemuxerOpenProfile {
        var copy = self
        if let probesize { copy.probesize = probesize }
        if let maxAnalyzeDuration { copy.maxAnalyzeDuration = maxAnalyzeDuration }
        return copy
    }

    /// A copy of `self` carrying the sequential-origin declaration and its paired trusted
    /// duration (no-op when `sequential` is false and `declaredDuration` is nil), in the style
    /// of `withProbeBudget` so call sites can chain it onto their existing profile.
    func withSequentialOrigin(_ sequential: Bool, declaredDuration: Double?) -> DemuxerOpenProfile {
        var copy = self
        copy.avioSequentialOnly = sequential
        if let declaredDuration { copy.declaredDurationSeconds = declaredDuration }
        return copy
    }

    /// Open profile for the #79 wedged-restart fresh reopen (#93 residual). The 44 s device
    /// restart was find_stream_info re-paying the FULL playback probe budget (50 MB / 60 s)
    /// over an already-starved link, so the reopen shrinks the budget instead of skipping the
    /// pass. It must NOT set `skipStreamInfo`: without find_stream_info the video stream's
    /// reorder depth stays unresolved (codecpar.video_delay == 0) and FFmpeg's generic layer
    /// cannot reconstruct decode-order dts for matroska B-frame content. Packets then arrive
    /// with NOPTS or presentation-ordered (dts == pts, non-monotonic) dts, and the producer's
    /// dts repair telescopes sample durations or drops every reordered frame it cannot bump
    /// past the dts <= pts muxer invariant: sustained video judder after every wedge recovery
    /// while stream-copied audio stays clean (#93 post-recovery judder, device-traced 07-02).
    /// The bounded budget resolves video_delay from the first few packets (HEVC/H.264 parser
    /// reads it from SPS) at a small bounded read cost. Keeps the playback AVIO tuning for the
    /// sustained pump reads that follow.
    static let restartReopen: DemuxerOpenProfile = {
        var profile = playback.withProbeBudget(probesize: 4 * 1024 * 1024,
                                               maxAnalyzeDuration: 5 * 1_000_000)
        // Bound the open connection to comfortably above the 4 MB probe budget (header + probe +
        // margin for the AVIO buffer straddling the 4 MB boundary). The producer reconnects
        // open-ended at the seek target immediately after, so sustained reads are untouched.
        profile.boundedInitialFetch = 8 * 1024 * 1024
        return profile
    }()

    /// Open profile for the embedded subtitle side-demuxer (#76, #87). `EmbeddedSubtitleDecoder`
    /// needs only `codec_id` / `codec_type` (carried in the container header / MPEG-TS PMT,
    /// resolved by `avformat_open_input` itself) and seeds bitmap (PGS/DVB/DVD) canvas dims
    /// from the source video size, so the `find_stream_info` chase after sparse, never-resolving
    /// subtitle streams is pure cost. Every PGS track keeps `has_codec_parameters` false to the
    /// budget cap (the #75 pattern), so even the #76 5 s ceiling is paid in full on a remote URL
    /// source, landing as a flat ~5 s startup stall when the track is selected at load (#87). So
    /// `skipStreamInfo` opts out of the chase entirely; the side reader runs a bounded find_stream_info
    /// on demand only if its target subtitle stream's codec is genuinely unresolved at open. The probe
    /// ceiling still bounds that fallback pass and honors an even tighter caller budget (#68). Keeps the
    /// playback AVIO tuning (prefetch, chunk size, per-chunk timeout): the reader does sustained paced
    /// reads, not a one-shot still fetch.
    static func subtitleSideDemuxer(callerProbesize: Int64?, callerMaxAnalyzeDuration: Int64?) -> DemuxerOpenProfile {
        let probeCeiling: Int64 = 4 * 1024 * 1024
        let analyzeCeiling: Int64 = 5 * 1_000_000
        let probesize = min(callerProbesize ?? probeCeiling, probeCeiling)
        let analyze = min(callerMaxAnalyzeDuration ?? analyzeCeiling, analyzeCeiling)
        var profile = playback.withProbeBudget(probesize: probesize, maxAnalyzeDuration: analyze)
        profile.skipStreamInfo = true
        profile.readerLabel = "subs"
        return profile
    }

    /// Open profile for the `LoadOptions.confirmAtmos` side demuxer (#214 follow-up). The pass needs only
    /// `codec_id` / `codec_type` on the audio streams, which `avformat_open_input` resolves from the
    /// container header (matroska CodecID, MP4 sample entry, MPEG-TS PMT), so `find_stream_info` would be
    /// pure cost on a remote source for a background enrichment nobody is waiting on. Keeps the playback
    /// AVIO tuning: the pass does sustained paced reads until it has enough audio packets, not a one-shot
    /// fetch, and `boundedInitialFetch` stays nil because reaching the audio in an interleaved UHD remux
    /// can span well past any header-sized bound.
    static func atmosConfirmationDemuxer(callerProbesize: Int64?, callerMaxAnalyzeDuration: Int64?)
        -> DemuxerOpenProfile {
        subtitleSideDemuxer(callerProbesize: callerProbesize, callerMaxAnalyzeDuration: callerMaxAnalyzeDuration)
    }
}

/// AVFormatContext wrapper. HTTP(S) uses custom AVIO via URLSession (no built-in
/// network stack in FFmpegBuild); file:// uses FFmpeg's file protocol directly.
/// `readPacket()` and `seek()` serialized via `accessLock` for thread safety.
public final class Demuxer: @unchecked Sendable {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    // Serializes formatContext access between readPacket() and seek();
    // concurrent access triggers assertion failures in matroskadec.c.
    private let accessLock = NSLock()

    private var avioProvider: AVIOProvider?
    private var openProfile: DemuxerOpenProfile = .playback

    /// #409: rewrites the timestamps of an MP4 whose writer dropped the composition-offset table.
    /// Lives here rather than in a playback host so that every consumer of this demuxer (the fMP4
    /// producer, the segment plan, the software decoder, the still extractor) reads the same axis;
    /// a repair applied per host would have them disagree by the reorder delay. nil for every stream
    /// that is not the exact defect shape, which is decided once, on the first read.
    private var compositionRepair: H264CompositionOffsetRepairSession?
    private var compositionRepairEvaluated = false

    /// #112 round 11: whether `seekByteEstimate` has what it needs (a resolved byte size and a positive
    /// duration). The side reader caps the timestamp-seek attempt tight when this is true, because the
    /// verified estimate is a cheaper, bounded way to position on an index-less source.
    func canByteEstimate(knownDuration: Double) -> Bool {
        guard knownDuration > 0 else { return false }
        accessLock.lock()
        defer { accessLock.unlock() }
        return avioProvider?.resolvedByteSize != nil
    }

    /// Number of attached-picture (cover-art) streams reclassified to ATTACHMENT before
    /// stream-info probing on the most recent open. See `reclassifyAttachedPictures`. (#75)
    private(set) var attachedPictureStreamsReclassified: Int = 0

    // Memory probe: compare against RSS growth; 0 for file:// sources.
    var avioBytesFetched: Int64 { avioProvider?.cumulativeBytesFetched ?? 0 }

    // Forward-only custom sources report false.
    var isSourceSeekable: Bool { avioProvider?.isSeekable ?? true }

    /// Timestamp of last unplanned reconnect (drop/stall, not a seek).
    /// Live producer correlates with backward source-PTS reset to detect
    /// Jellyfin transcode respawn. See `AVIOReader.lastUnplannedReconnectAt`.
    var lastUnplannedSourceReconnectAt: Date? {
        (avioProvider as? AVIOReader)?.lastUnplannedReconnectAt
    }

    /// #220: sliding-window snapshot of this demuxer's network reader, nil for disc / custom /
    /// file providers that have no window. Surfaced per demuxer (pump and subtitle side reader
    /// are separate readers against the same origin) in the periodic memprobe.
    var ioWindowDiagnostics: (windowBytes: Int, aheadBytes: Int, parked: Bool)? {
        (avioProvider as? AVIOReader)?.windowDiagnostics
    }

    /// Forwarded to the playback `AVIOReader` so source stall/reconnect transitions reach the engine (#85).
    /// `didSet` re-forwards so it works whether set before or after `open()`. Set only on the playback
    /// demuxer; the subtitle side-demuxer leaves it nil so its stalls never move `playbackPhase`. Disc /
    /// custom providers without an `AVIOReader` simply never emit.
    var onNetworkPhaseChanged: (@Sendable (ReaderNetworkPhase) -> Void)? {
        didSet { (avioProvider as? AVIOReader)?.onNetworkPhaseChanged = onNetworkPhaseChanged }
    }

    /// #361: emitted as each stage of `open()` finishes, so the engine can publish startup progress
    /// through the one stretch of a load a host cannot otherwise see. Called on whatever thread the
    /// open runs on (the playback open is detached off the main actor), never after `open()` returns.
    /// Set only on the playback probe demuxer; every other demuxer (side readers, still extraction)
    /// leaves it nil and emits nothing.
    var onOpenProgress: (@Sendable (DemuxerOpenStage) -> Void)?

    // MARK: - Disc titles / chapters (#67)

    private(set) var discTitles: [DiscTitle] = []
    private(set) var selectedDiscTitleIndex: Int = 0

    /// Per-clip presentation-offset spans for a selected multi-clip Blu-ray title (empty otherwise). When
    /// non-empty, `readPacket` and `indexedKeyframes` fold each clip's timestamps onto one contiguous
    /// timeline so the playhead does not leap at clip boundaries (AE#105). Guarded by `accessLock`.
    private var clipTimeline: [ClipSpan] = []
    /// Last clip index resolved from a packet byte position; reused when a packet reports pos < 0
    /// (reads are sequential, so the clip only advances). Guarded by `accessLock`.
    private var lastClipIndex: Int = 0
    /// Clip index of the previous packet READ (not the pos<0 fallback), reset to -1 on adopt and on seek.
    /// A clip's observed base is only trusted on a clean forward crossing (`idx == lastReadClipIdx + 1`),
    /// so a seek landing mid-clip cannot mis-anchor that clip's fold offset. AE#105.
    private var lastReadClipIdx: Int = -1
    /// Observed raw STC base (seconds) of clip 0's first read packet. The fold anchors every clip to this so
    /// the folded timeline stays in clip 0's raw domain (the producer gate then zero-bases it). NaN until the
    /// first packet is read. Guarded by `accessLock`. AE#105.
    private var clipBase0Sec: Double = .nan
    /// Per-clip fold offset actually applied to packets (seconds), resolved from the clip's OBSERVED raw base
    /// the first time it is read and cached (stable across seeks). NaN = not yet resolved. Guarded by
    /// `accessLock`. AE#105.
    private var clipResolvedShiftSec: [Double] = []
    /// AE#105 diag: last clip index we logged a boundary crossing for, and the last folded PTS
    /// (seconds) seen, so a crossing can print the true raw jump against the applied offset.
    private var diagLastLoggedClipIndex: Int = -1
    private var diagPrevFoldedSec: Double = .nan

    private func adoptDiscInfo(_ info: DiscInfo) {
        discTitles = info.titles
        selectedDiscTitleIndex = info.selectedTitleIndex
        clipTimeline = info.clipTimeline
        lastClipIndex = 0
        lastReadClipIdx = -1
        clipBase0Sec = .nan
        clipResolvedShiftSec = info.clipTimeline.isEmpty
            ? []
            : [0] + Array(repeating: Double.nan, count: info.clipTimeline.count - 1)
        diagLastLoggedClipIndex = -1
        diagPrevFoldedSec = .nan
    }

    /// Predicted (MPLS-derived) seconds to subtract from a raw timestamp/index entry at byte position `pos`.
    /// Used only by `normalizedTimestamp` for the keyframe-index hint; actual packet folding uses the
    /// OBSERVED offset in `readPacket`. 0 when normalization is off or `pos` is in clip 0. Under `accessLock`.
    private func clipSubtractSeconds(forPos pos: Int64) -> Double {
        guard !clipTimeline.isEmpty else { return 0 }
        let idx = ClipSpan.index(forPos: pos, in: clipTimeline, fallback: lastClipIndex)
        lastClipIndex = idx
        return clipTimeline[idx].predictedShiftSec
    }

    /// Fold a raw timestamp onto the contiguous presentation timeline given its byte position and time base.
    /// Must be called under `accessLock`.
    private func normalizedTimestamp(_ ts: Int64, pos: Int64, timeBase: AVRational) -> Int64 {
        guard ts != Int64.min, !clipTimeline.isEmpty else { return ts }
        let sub = clipSubtractSeconds(forPos: pos)
        guard sub != 0, timeBase.num > 0, timeBase.den > 0 else { return ts }
        let subTicks = Int64((sub * Double(timeBase.den) / Double(timeBase.num)).rounded())
        return ts &- subTicks
    }

    /// True once a disc structure (BD/DVD/UDF) was recognized at open. Disc sources concat
    /// MPEG-TS / VOB clips and have no EOF cue index, so the MKV cue-index prewarm seek is
    /// useless there and a cold mid-disc range read is expensive on a remote ISO (#76).
    var isDiscSource: Bool { !discTitles.isEmpty }

    /// The disc's titles mapped to the public model (empty for non-disc sources).
    func discTitleInfos() -> [TitleInfo] { discTitles.map { $0.titleInfo() } }
    /// Chapters of the currently selected title (empty until BD/DVD chapters are populated).
    func discChapterInfos() -> [ChapterInfo] { discTitles.chapterInfos(selectedIndex: selectedDiscTitleIndex) }
    /// The id of the selected title, or nil for a non-disc source.
    var selectedDiscTitleID: Int? {
        discTitles.indices.contains(selectedDiscTitleIndex) ? discTitles[selectedDiscTitleIndex].id : nil
    }

    /// Authoritative playlist/IFO duration of the selected disc title, or nil when there is no disc
    /// title or its duration is unparsed (ticks 0). This is trusted over FFmpeg's container estimate
    /// (see `duration`).
    var selectedDiscTitleDurationSeconds: Double? {
        guard discTitles.indices.contains(selectedDiscTitleIndex) else { return nil }
        let ticks = discTitles[selectedDiscTitleIndex].durationTicks
        return ticks > 0 ? Double(ticks) / discTickRate : nil
    }

    /// Pick the trustworthy duration for a disc-backed source. FFmpeg's mpegts estimate over
    /// concatenated multi-clip Blu-ray m2ts with discontinuous PTS is unreliable (AE#105: a 42s title
    /// probed as 25.5h, a 35s title as 5s), so the MPLS/IFO playlist duration wins whenever it is
    /// present (> 0). Non-disc sources (`discTitle == nil`) keep the container estimate verbatim.
    static func effectiveDurationSeconds(discTitle: Double?, container: Double) -> Double {
        if let discTitle, discTitle > 0 { return discTitle }
        return container
    }

    /// Full duration-precedence chain: a caller-declared duration
    /// (`DemuxerOpenProfile.declaredDurationSeconds`, the sequential-origin pair) outranks
    /// everything - the non-seekable pb ran no tail estimate, so the container value is 0 or
    /// garbage from fabricated range data - then a custom time-seekable reader's own duration,
    /// then the disc/container resolution above.
    static func effectiveDurationSeconds(
        declared: Double?, readerDuration: Double?, discTitle: Double?, container: Double
    ) -> Double {
        if let declared, declared > 0 { return declared }
        if let readerDuration, readerDuration > 0 { return readerDuration }
        return effectiveDurationSeconds(discTitle: discTitle, container: container)
    }

    /// Open a media URL and probe its streams.
    /// - Parameters:
    ///   - extraHeaders: Attached to every HTTP request (ignored for file:// URLs).
    ///   - isLive: Suppresses EOF synthesis and surfaces terminal error on reconnect cap.
    func open(url: URL, extraHeaders: [String: String] = [:], profile: DemuxerOpenProfile = .playback, isLive: Bool = false, selectTitleID: Int? = nil) throws {
        self.openProfile = profile
        let isHTTP = url.scheme == "http" || url.scheme == "https"

        if isHTTP {
            try openHTTP(url: url, extraHeaders: extraHeaders, isLive: isLive, selectTitleID: selectTitleID)
        } else {
            // Route a local DVD ISO through the disc adapter (FileIOReader keeps it
            // out of RAM). Falls back to the normal local open when not a disc.
            if url.isFileURL, let fileReader = FileIOReader(url: url),
               let discInfo = try DiscReader.wrap(fileReader, selectTitleID: selectTitleID, cacheKey: url.absoluteString) {
                adoptDiscInfo(discInfo)
                let bridge = CustomIOReaderBridge(reader: discInfo.reader)
                let inputFormat = av_find_input_format(discInfo.formatHint)
                try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
                return
            }
            try openLocal(url: url)
        }
    }

    // MARK: - Open Strategies

    private func openLocal(url: URL) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = ctx else {
            throw DemuxerError.openFailed(code: -1)
        }
        applyProbeBudget(allocated)

        let urlString = url.isFileURL ? url.path : url.absoluteString
        var opts: OpaquePointer? = nil
        Self.applyDemuxerOptions(&opts)
        let ret = avformat_open_input(&ctx, urlString, nil, &opts)
        av_dict_free(&opts)
        guard ret == 0, let openedCtx = ctx else {
            throw DemuxerError.openFailed(code: ret)
        }
        formatContext = openedCtx
        // #361: a local file has no connection to come up, so the source stage is credited by this
        // one rather than reported separately.
        onOpenProgress?(.containerOpened)

        try probeStreams(openedCtx)
        onOpenProgress?(.streamsProbed)
    }

    /// Open a custom `IOReader` source. `formatHint` disambiguates probing when
    /// no filename is available. `isLive` suppresses SEEK_END that latches EOF
    /// on forward-only readers (38ad60b). AetherEngine#36: DiscReader adapts
    /// DVD/BD ISOs to VOB/MPEGTS concat streams unless the reader opts out via
    /// `discImageProbeEnabled`.
    func open(reader: IOReader, formatHint: String? = nil, profile: DemuxerOpenProfile = .playback, isLive: Bool = false, selectTitleID: Int? = nil, discCacheKey: String? = nil) throws {
        self.openProfile = profile
        if reader.discImageProbeEnabled,
           let discInfo = try DiscReader.wrap(reader, selectTitleID: selectTitleID, cacheKey: discCacheKey) {
            adoptDiscInfo(discInfo)
            let bridge = CustomIOReaderBridge(reader: discInfo.reader)
            let inputFormat = av_find_input_format(discInfo.formatHint)
            try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
            return
        }
        let bridge = CustomIOReaderBridge(reader: reader)
        let inputFormat: UnsafePointer<AVInputFormat>? = formatHint.flatMap { av_find_input_format($0) }
        try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
    }

    /// A remote disc image (ISO 9660 / UDF / BDMV) by URL extension. Gates the HTTP disc-adapter
    /// path so a normal media URL keeps the optimized streaming AVIOReader open with no probe cost.
    static func isDiscImageURL(_ url: URL) -> Bool {
        ["iso", "img", "udf"].contains(url.pathExtension.lowercased())
    }

    private func openHTTP(url: URL, extraHeaders: [String: String], isLive: Bool = false, selectTitleID: Int? = nil) throws {
        // A remote disc image goes through the same disc adapter as a local ISO (a raw .iso handed
        // straight to libavformat fails to probe; it is a filesystem, not a media container, #64).
        // Gated on the disc-image extension so normal media URLs skip the range-probe entirely; if
        // the source is not a recognizable disc, fall through to the streaming reader.
        if !isLive, Self.isDiscImageURL(url),
           let discReader = HTTPDiscIOReader(url: url, extraHeaders: extraHeaders) {
            if let discInfo = try DiscReader.wrap(discReader, selectTitleID: selectTitleID, cacheKey: url.absoluteString) {
                adoptDiscInfo(discInfo)
                let bridge = CustomIOReaderBridge(reader: discInfo.reader)
                let inputFormat = av_find_input_format(discInfo.formatHint)
                try openWithProvider(bridge, inputFormat: inputFormat, isLive: false)
                return
            }
            discReader.close()
        }
        let reader = AVIOReader(
            url: url,
            extraHeaders: extraHeaders,
            label: openProfile.readerLabel,
            chunkSize: openProfile.avioChunkSize,
            prefetchEnabled: openProfile.avioPrefetch,
            isLive: isLive,
            chunkRequestTimeout: openProfile.avioRequestTimeout,
            chunkMaxRetries: openProfile.avioMaxRetries,
            boundedInitialFetch: openProfile.boundedInitialFetch,
            sequentialOnly: openProfile.avioSequentialOnly
        )
        reader.onNetworkPhaseChanged = onNetworkPhaseChanged
        try openWithProvider(reader, isLive: isLive)
    }

    /// Common AVIO open path. `inputFormat` forces a demuxer (custom sources with
    /// a format hint). `isLive` suppresses duration-estimate SEEK_END that latches
    /// EOF on unknown-length live sources.
    private func openWithProvider(
        _ provider: AVIOProvider,
        inputFormat: UnsafePointer<AVInputFormat>? = nil,
        isLive: Bool = false
    ) throws {
        try provider.open()
        avioProvider = provider
        onOpenProgress?(.sourceOpened)   // #361

        guard let ctx = avformat_alloc_context() else {
            avioProvider?.close()
            avioProvider = nil
            throw DemuxerError.openFailed(code: -1)
        }
        ctx.pointee.pb = provider.context
        applyProbeBudget(ctx)
        formatContext = ctx

        // URL is nil because pb is already set.
        var ctxPtr: UnsafeMutablePointer<AVFormatContext>? = ctx
        var opts: OpaquePointer? = nil
        Self.applyDemuxerOptions(&opts, isLive: isLive,
                                 skipDurationEstimate: openProfile.avioSequentialOnly)
        let ret = avformat_open_input(&ctxPtr, nil, inputFormat, &opts)
        av_dict_free(&opts)
        guard ret == 0 else {
            formatContext = nil
            avioProvider?.close()
            avioProvider = nil
            throw DemuxerError.openFailed(code: ret)
        }
        formatContext = ctxPtr  // avformat_open_input may reallocate
        onOpenProgress?(.containerOpened)   // #361

        try probeStreams(ctxPtr!)
        onOpenProgress?(.streamsProbed)     // #361
        // #281: every parse seek this open performs has happened by now, so the provider can drop
        // the cold-start state that only exists to serve them. Deliberately after probeStreams:
        // find_stream_info is where the trailing-index ping-pong lives, not avformat_open_input.
        avioProvider?.markOpenPhaseFinished()
    }

    /// Default 5 MB/5s budgets miss sparse PGS/DVB tracks on 10-20 GB Blu-ray rips.
    /// 50 MB/60 s ensures codec params are populated without noticeably slowing open.
    private func applyProbeBudget(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        ctx.pointee.probesize = openProfile.probesize
        ctx.pointee.max_analyze_duration = openProfile.maxAnalyzeDuration
    }

    /// Demuxer fflags applied to every avformat_open_input.
    /// +genpts: libavformat regenerates missing pts/dts; per AetherEngine#4 this is
    /// what Jellyfin's server-side remux uses. Cuts 4K HDR HEVC RSS growth ~50%
    /// (3.24 MB/s -> ~1.7 MB/s). Tried+reverted: +sortdts (worse RSS), +discardcorrupt
    /// (worse RSS), +igndts (AetherEngine#5: matroska still emits dts=0 on HEVC open-GOP
    /// CRA B-frames, NOPTS repair stack stayed load-bearing).
    private static func applyDemuxerOptions(_ opts: inout OpaquePointer?, isLive: Bool = false, skipDurationEstimate: Bool = false) {
        av_dict_set(&opts, "fflags", "+genpts", 0)
        if isLive || skipDurationEstimate {
            // Live sources have no Content-Length; stream-info pass seeks SEEK_END,
            // which latches pb->eof_reached and collapses av_read_frame ~10s in.
            // skip_estimate_duration_from_pts avoids that SEEK_END entirely.
            // A sequential-origin VOD skips it for the same reason from the other
            // side: its pb is non-seekable by declaration, and the caller supplies
            // the duration (`declaredDurationSeconds`) the estimate would have fed.
            av_dict_set(&opts, "skip_estimate_duration_from_pts", "1", 0)
        }
    }

    /// True for streams carrying a single cover-art still (e.g. mjpeg poster). FFmpeg flags these
    /// with `AV_DISPOSITION_ATTACHED_PIC` at open, independent of codec type. (#75)
    static func isAttachedPicture(disposition: Int32) -> Bool {
        (disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
    }

    /// Reclassify cover-art streams to `AVMEDIA_TYPE_ATTACHMENT` BEFORE `avformat_find_stream_info`.
    /// An unresolvable cover (mjpeg with no decodable frame, reported size 0x0) otherwise keeps
    /// `has_codec_parameters` false, so find_stream_info reads to the full probe budget (tens of MB
    /// on a remote source) before giving up, dominating open. find_stream_info syncs codecpar into
    /// its internal avctx unconditionally at setup, and `has_codec_parameters` returns true for an
    /// ATTACHMENT stream with no width/pixfmt/decoder dependency, so the probe stops once the real
    /// streams resolve. Cover extraction reads `attached_pic` + the unchanged disposition (queued at
    /// open), so it is unaffected. Discard is deliberately left untouched: `AVDISCARD_ALL` would make
    /// `avformat_queue_attached_pictures` skip the cover. (#75)
    private func reclassifyAttachedPictures(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        var count = 0
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  Self.isAttachedPicture(disposition: stream.pointee.disposition) else { continue }
            codecpar.pointee.codec_type = AVMEDIA_TYPE_ATTACHMENT
            count += 1
        }
        attachedPictureStreamsReclassified = count
    }

    private func probeStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) throws {
        // #87: the subtitle side demuxer opts out of find_stream_info. avformat_open_input already
        // carries codec_id / codec_type for every subtitle track (container header / PMT), and
        // reclassifyAttachedPictures only exists to bound the find_stream_info cost, so both are skipped.
        // The reader runs `resolveStreamInfo()` on demand if its target stream's codec is unresolved.
        guard !openProfile.skipStreamInfo else {
            logStreams(ctx)
            return
        }
        reclassifyAttachedPictures(ctx)
        let findRet = avformat_find_stream_info(ctx, nil)
        guard findRet >= 0 else {
            throw DemuxerError.streamInfoFailed(code: findRet)
        }
        logStreams(ctx)
    }

    /// Run a bounded `avformat_find_stream_info` on an already-open context (#87). Used by the subtitle
    /// side reader as a fallback when its target stream's codec is still unresolved after a `skipStreamInfo`
    /// open (a container that does not declare the subtitle codec in its header). The probe budget applied
    /// at open already caps the pass, so this stays bounded by the side demuxer's subtitle-sized ceiling.
    func resolveStreamInfo() {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return }
        reclassifyAttachedPictures(ctx)
        _ = avformat_find_stream_info(ctx, nil)
    }

    /// True if the stream at `index` is missing or carries no resolved codec yet (`AV_CODEC_ID_NONE`).
    /// The side reader uses this to decide whether a `skipStreamInfo` open needs a `resolveStreamInfo()`
    /// fallback before handing the stream to `EmbeddedSubtitleDecoder` (#87).
    func streamCodecUnresolved(at index: Int32) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams,
              let stream = ctx.pointee.streams[Int(index)],
              let codecpar = stream.pointee.codecpar else { return true }
        return codecpar.pointee.codec_id == AV_CODEC_ID_NONE
    }

    private func logStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        #if DEBUG
        EngineLog.emit("[Demuxer] Opened: \(ctx.pointee.nb_streams) streams, duration=\(ctx.pointee.duration) us", category: .demux)
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar else { continue }
            let codecType = codecpar.pointee.codec_type
            let typeName: String
            switch codecType {
            case AVMEDIA_TYPE_VIDEO: typeName = "video"
            case AVMEDIA_TYPE_AUDIO: typeName = "audio"
            case AVMEDIA_TYPE_SUBTITLE: typeName = "subtitle"
            default: typeName = "other"
            }
            let codecName = String(cString: avcodec_get_name(codecpar.pointee.codec_id))
            EngineLog.emit("[Demuxer]   stream[\(i)] type=\(typeName) codec=\(codecName) \(codecpar.pointee.width)x\(codecpar.pointee.height)", category: .demux)
        }
        #endif
    }

    var duration: Double {
        let container: Double = {
            guard let ctx = formatContext else { return 0 }
            let dur = ctx.pointee.duration
            return dur > 0 ? Double(dur) / Double(AV_TIME_BASE) : 0
        }()
        // Declared (sequential-origin caller trust) > custom reader > disc MPLS/IFO (AE#105) > container.
        return Self.effectiveDurationSeconds(
            declared: openProfile.declaredDurationSeconds,
            readerDuration: (avioProvider as? CustomIOReaderBridge)?.timeSeekableReader?.mediaDuration,
            discTitle: selectedDiscTitleDurationSeconds,
            container: container)
    }

    /// AVFormatContext.bit_rate in bps, or 0 if unknown. Used by
    /// HLSVideoEngine.masterBandwidth to populate HLS BANDWIDTH attributes.
    var bitRate: Int64 {
        guard let ctx = formatContext else { return 0 }
        return ctx.pointee.bit_rate
    }

    /// AVFormatContext.start_time in AV_TIME_BASE units. Non-zero on re-muxed
    /// MKV/TS; subtract from packet PTS for file-relative playback time.
    var formatStartTime: Int64 {
        guard let ctx = formatContext else { return 0 }
        return ctx.pointee.start_time
    }

    /// Index of the best video stream, or -1.
    /// Clamped: av_find_best_stream returns AVERROR_STREAM_NOT_FOUND (-1381258232)
    /// on failure, not -1; normalize to -1 to avoid garbage in logs.
    var videoStreamIndex: Int32 {
        guard let ctx = formatContext else { return -1 }
        return max(-1, av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
    }

    /// True if `index` names a video stream. Live producer uses this to detect
    /// an SSAI program change that introduces a new video PID mid-stream.
    func isVideoStream(_ index: Int32) -> Bool {
        accessLock.lock(); defer { accessLock.unlock() }
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams,
              let stream = ctx.pointee.streams[Int(index)] else { return false }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
    }


    /// Best audio stream index, or -1 (same AVERROR_STREAM_NOT_FOUND clamp as videoStreamIndex).
    /// GOTCHA: av_find_best_stream skips streams with no channels/sample_rate (live MPEG-TS
    /// probe may leave them that way). Use `firstAudioStreamIndexByType` as fallback.
    var audioStreamIndex: Int32 {
        guard let ctx = formatContext else { return -1 }
        return max(-1, av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0))
    }

    /// First audio stream by codec_type regardless of codecpar completeness.
    /// Fallback for live MPEG-TS where av_find_best_stream skips empty-codecpar
    /// streams; the engine's live AAC codecpar repair fills them downstream.
    var firstAudioStreamIndexByType: Int32 {
        guard let ctx = formatContext else { return -1 }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            return Int32(i)
        }
        return -1
    }

    func audioTrackInfos() -> [TrackInfo] {
        guard let ctx = formatContext else { return [] }
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    func subtitleTrackInfos() -> [TrackInfo] {
        guard let ctx = formatContext else { return [] }
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    /// #112: PGS subtitle streams whose display sets arrive split across PES packets and need
    /// reassembly in the SubtitlePacketStore. Only the MPEG-TS demuxer splits them (Blu-ray
    /// authoring: PCS|WDS|PDS|ODS|END as separate PES packets, some without a PTS); Matroska
    /// carries one complete set per packet and must NOT be assembled (converters there strip
    /// the trailing END, which the decoder's synthetic-END flush rescues per packet).
    /// #151: every AVMEDIA_TYPE_SUBTITLE stream index; the forward prefetcher's route + keep set.
    func subtitleStreamIndices() -> Set<Int32> {
        guard let ctx = formatContext else { return [] }
        var indices: Set<Int32> = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            indices.insert(Int32(i))
        }
        return indices
    }

    /// #230: the stream whose packets pace the subtitle side reader's forward park, or -1.
    ///
    /// The park can only be evaluated on a packet the loop actually receives, and with every
    /// non-subtitle stream on `AVDISCARD_ALL` the only packets that arrive are subtitle packets.
    /// Between two cues the reader therefore has no control point at all: a single `av_read_frame`
    /// call walks however many bytes lie between them, and on a sparse or forced track that is the
    /// rest of the file. Delivering one non-subtitle stream at `AVDISCARD_NONKEY` restores a
    /// control point without restoring the payload: video yields one packet per IRAP, which is the
    /// natural granularity for a 60 s park window.
    ///
    /// Video is preferred because `AVDISCARD_NONKEY` genuinely thins it; audio (where every packet
    /// is a keyframe, so nothing is thinned) is the fallback, and its packets are small. Selection
    /// walks `codec_type` rather than `av_find_best_stream` because the side demuxer opts out of
    /// `find_stream_info` (#87), so codecpar may be incomplete and cover art is still typed as
    /// video (`reclassifyAttachedPictures` does not run either). A cover-art stream would deliver
    /// exactly one packet and pace nothing, so it is excluded by disposition.
    func prefetchPacingStreamIndex() -> Int32 {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return -1 }
        var audioFallback: Int32 = -1
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  !Self.isAttachedPicture(disposition: stream.pointee.disposition) else { continue }
            switch codecpar.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                return Int32(i)
            case AVMEDIA_TYPE_AUDIO where audioFallback < 0:
                audioFallback = Int32(i)
            default:
                continue
            }
        }
        return audioFallback
    }

    /// Name libavformat gave the container it opened ("matroska,webm", "mpegts", "mov,mp4,m4a,3gp,3g2,mj2"),
    /// nil before open. This is what the demuxer is actually reading, which on a remux or transcode session
    /// is the delivered container and not the one the library holds; the two differ exactly when a host's
    /// server-side metadata would mislead.
    var containerFormatName: String? {
        guard let ctx = formatContext, let name = ctx.pointee.iformat?.pointee.name else { return nil }
        return String(cString: name)
    }

    func splitDisplaySetSubtitleStreamIndices() -> Set<Int32> {
        guard let ctx = formatContext,
              let formatName = ctx.pointee.iformat?.pointee.name,
              String(cString: formatName).split(separator: ",").contains("mpegts")
        else { return [] }
        var indices: Set<Int32> = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE,
                  codecpar.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE else { continue }
            indices.insert(Int32(i))
        }
        return indices
    }

    func mediaMetadata() -> MediaMetadata {
        guard let ctx = formatContext else {
            return MediaMetadata(title: nil, artist: nil, album: nil, artworkData: nil)
        }
        let dict = ctx.pointee.metadata
        return MediaMetadata.from(
            title: metadataValue(dict, key: "title"),
            artist: metadataValue(dict, key: "artist"),
            album: metadataValue(dict, key: "album"),
            albumArtist: metadataValue(dict, key: "album_artist"),
            artworkData: attachedPictureData()
        )
    }

    /// One container chapter as read off `AVChapter`, decoupled from the C struct so the mapping
    /// below is a pure function.
    struct RawContainerChapter: Equatable {
        let start: Double
        let end: Double
        let title: String?
    }

    /// Map raw container chapters onto the public model: sorted by start, re-ided sequentially so ids
    /// stay stable list indices for hosts, untitled entries numbered "Chapter N" (matching the disc
    /// naming).
    ///
    /// A chapter's declared end is never trusted for its duration when a successor exists, because
    /// real-world MKV muxes routinely write `end == start`; the duration runs to the next chapter's
    /// start instead. The last entry has no successor, so it falls back to its declared end, and
    /// then to the container duration when that end is degenerate too, which is the same mux bug
    /// landing on the one chapter the next-start rule cannot cover.
    static func chapterInfos(from raw: [RawContainerChapter], containerDuration: Double?) -> [ChapterInfo] {
        let sorted = raw.sorted { $0.start < $1.start }
        return sorted.enumerated().map { i, ch in
            let end: Double
            if i + 1 < sorted.count {
                end = sorted[i + 1].start
            } else if ch.end > ch.start {
                end = ch.end
            } else if let duration = containerDuration, duration > ch.start {
                end = duration
            } else {
                end = ch.start
            }
            let trimmed = ch.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmed?.isEmpty == false) ? trimmed! : "Chapter \(i + 1)"
            return ChapterInfo(id: i, name: name,
                               startSeconds: ch.start,
                               durationSeconds: Swift.max(0, end - ch.start))
        }
    }

    /// Container (Matroska/MP4) chapters mapped to the public model. Empty when the container declares
    /// none. Disc sources keep their playlist/IFO chapters via `discChapterInfos`; both can coexist and
    /// the engine picks. See `chapterInfos(from:containerDuration:)` for the id, naming and duration rules.
    func mediaChapterInfos() -> [ChapterInfo] {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext,
              ctx.pointee.nb_chapters > 0,
              let chapterList = ctx.pointee.chapters else { return [] }

        var raw: [RawContainerChapter] = []
        raw.reserveCapacity(Int(ctx.pointee.nb_chapters))
        for i in 0..<Int(ctx.pointee.nb_chapters) {
            guard let chapter = chapterList[i]?.pointee else { continue }
            let tb = chapter.time_base
            // num == 0 would scale every timestamp to zero, collapsing the whole list onto 0 s.
            guard tb.den > 0, tb.num > 0, chapter.start != Int64.min else { continue }
            let scale = Double(tb.num) / Double(tb.den)
            let start = Swift.max(0, Double(chapter.start) * scale)
            let end = chapter.end != Int64.min ? Double(chapter.end) * scale : start
            raw.append(RawContainerChapter(
                start: start,
                end: end,
                title: metadataValue(chapter.metadata, key: "title")
            ))
        }
        let declared = ctx.pointee.duration
        let containerDuration = declared > 0 ? Double(declared) / Double(AV_TIME_BASE) : nil
        return Self.chapterInfos(from: raw, containerDuration: containerDuration)
    }

    private func attachedPictureData() -> Data? {
        guard let ctx = formatContext else { return nil }
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  (stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0
            else { continue }
            let pkt = stream.pointee.attached_pic
            guard pkt.size > 0, let dataPtr = pkt.data else { return nil }
            return Data(bytes: dataPtr, count: Int(pkt.size))
        }
        return nil
    }

    private func trackInfo(from stream: UnsafeMutablePointer<AVStream>, index: Int) -> TrackInfo {
        let codecpar = stream.pointee.codecpar!
        let codecName: String
        if let codec = avcodec_find_decoder(codecpar.pointee.codec_id) {
            codecName = String(cString: codec.pointee.name)
        } else if let namePtr = avcodec_get_name(codecpar.pointee.codec_id) {
            // No decoder built (e.g. eia_608): fall back to the codec-descriptor name so the track is
            // identifiable. #77 routes in-band CEA-608/708 on this name ("eia_608").
            codecName = String(cString: namePtr)
        } else {
            codecName = "unknown"
        }

        let language = metadataValue(stream.pointee.metadata, key: "language")
        let title = metadataValue(stream.pointee.metadata, key: "title")
        let name: String
        if let title = title, !title.isEmpty {
            name = title
        } else if let lang = language {
            name = "\(lang.uppercased()) (\(codecName))"
        } else {
            name = "Track \(index) (\(codecName))"
        }

        let disposition = stream.pointee.disposition
        let isDefault = (disposition & AV_DISPOSITION_DEFAULT) != 0
        let isForced = (disposition & AV_DISPOSITION_FORCED) != 0
        let isHearingImpaired = (disposition & AV_DISPOSITION_HEARING_IMPAIRED) != 0
        let isCommentary = (disposition & AV_DISPOSITION_COMMENT) != 0
        let channels = Int(codecpar.pointee.ch_layout.nb_channels)
        let bitrate = declaredBitrate(stream: stream)

        // EAC3 profile 30 = JOC (Dolby Atmos on streaming). Lets UI label "Atmos".
        let isAtmos = (codecpar.pointee.codec_id == AV_CODEC_ID_EAC3)
            && codecpar.pointee.profile == 30

        // ASS/SSA codec extradata = script header ([Script Info] + [V4+ Styles] +
        // [Events] format line). Surfaced for LoadOptions.preserveASSMarkup hosts.
        var assHeader: String? = nil
        let codecID = codecpar.pointee.codec_id
        if codecID == AV_CODEC_ID_ASS || codecID == AV_CODEC_ID_SSA,
           let extradata = codecpar.pointee.extradata,
           codecpar.pointee.extradata_size > 0 {
            let bytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            // MKV CodecPrivate is frequently NUL-terminated; strip NULs so libass
            // (C-string-style parser) doesn't silently stop before host-appended content.
            assHeader = String(data: bytes, encoding: .utf8)?
                .replacingOccurrences(of: "\0", with: "")
        }

        return TrackInfo(
            id: index,
            name: name,
            codec: codecName,
            language: language,
            channels: channels,
            bitrate: bitrate,
            isDefault: isDefault,
            isForced: isForced,
            isHearingImpaired: isHearingImpaired,
            isCommentary: isCommentary,
            isAtmos: isAtmos,
            assHeader: assHeader
        )
    }

    /// MKV font attachments. Payload in codec extradata; filename/MIME in stream metadata.
    /// Non-font attachments filtered by isFontPayload.
    func fontAttachmentInfos() -> [FontAttachment] {
        guard let ctx = formatContext else { return [] }
        var fonts: [FontAttachment] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT,
                  let extradata = codecpar.pointee.extradata,
                  codecpar.pointee.extradata_size > 0
            else { continue }
            let filename = metadataValue(stream.pointee.metadata, key: "filename")
            let mimeType = metadataValue(stream.pointee.metadata, key: "mimetype")
            guard FontAttachment.isFontPayload(mimeType: mimeType, filename: filename) else { continue }
            let fallbackExt: String
            switch mimeType?.lowercased() {
            case "font/otf", "application/vnd.ms-opentype", "application/x-font-otf": fallbackExt = "otf"
            case "font/collection": fallbackExt = "ttc"
            default: fallbackExt = "ttf"
            }
            fonts.append(FontAttachment(
                filename: filename ?? "font-\(i).\(fallbackExt)",
                mimeType: mimeType ?? "",
                data: Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            ))
        }
        return fonts
    }

    private func metadataValue(_ dict: OpaquePointer?, key: String, flags: Int32 = 0) -> String? {
        guard let dict = dict else { return nil }
        guard let entry = av_dict_get(dict, key, nil, flags) else { return nil }
        return String(cString: entry.pointee.value)
    }

    /// Declared per-stream bitrate in bits/second. Prefers `codecpar.bit_rate` (populated for MP4/TS);
    /// falls back to the Matroska per-track `BPS` statistics tag that mkvmerge writes (as `BPS` or a
    /// language-suffixed `BPS-eng`), because Matroska leaves `codecpar.bit_rate` at 0. Returns 0 when the
    /// container declares neither, matching the "unavailable" contract of `TrackInfo.bitrate`.
    func declaredBitrate(stream: UnsafeMutablePointer<AVStream>) -> Int64 {
        let codecparRate = Int64(stream.pointee.codecpar.pointee.bit_rate)
        // AV_DICT_IGNORE_SUFFIX matches `BPS-eng`/`BPS-deu` when querying `BPS`.
        let bpsTag = metadataValue(stream.pointee.metadata, key: "BPS", flags: Int32(AV_DICT_IGNORE_SUFFIX))
        return Self.resolveBitrate(codecparBitrate: codecparRate, bpsTag: bpsTag)
    }

    /// Pure bitrate resolution: a positive declared `codecpar.bit_rate` wins; otherwise a positive parsed
    /// `BPS` tag; otherwise 0. Factored out so the codecpar-vs-tag precedence is unit-testable without a fixture.
    static func resolveBitrate(codecparBitrate: Int64, bpsTag: String?) -> Int64 {
        if codecparBitrate > 0 { return codecparBitrate }
        if let bpsTag, let parsed = Int64(bpsTag.trimmingCharacters(in: .whitespaces)), parsed > 0 {
            return parsed
        }
        return 0
    }

    func stream(at index: Int32) -> UnsafeMutablePointer<AVStream>? {
        guard let ctx = formatContext, index >= 0, index < ctx.pointee.nb_streams else {
            return nil
        }
        return ctx.pointee.streams[Int(index)]
    }

    /// Sets AVDISCARD_ALL on streams outside `keep`. Without this, matroska reads
    /// cluster blocks for all streams on every video packet and queues unused PGS
    /// bitmaps and audio frames. AVDISCARD_ALL drops before AVPacket alloc, eliminating
    /// that cycle. Call after open, before readPacket. Safe to call multiple times.
    /// `pacing`, when >= 0 and not already in `keep`, is delivered at `AVDISCARD_NONKEY` instead of
    /// being dropped: keyframes only, enough to give a side reader a read-position control point
    /// between sparse target packets (#230). -1 keeps the original all-or-nothing behavior.
    func discardAllStreamsExcept(_ keep: Set<Int32>, pacing: Int32 = -1) {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return }
        for i in 0..<Int32(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[Int(i)] else { continue }
            // AVDISCARD_DEFAULT = 0 (= passthrough), AVDISCARD_NONKEY = 32, AVDISCARD_ALL = 48.
            if keep.contains(i) {
                stream.pointee.discard = AVDISCARD_DEFAULT
            } else if i == pacing {
                stream.pointee.discard = AVDISCARD_NONKEY
            } else {
                stream.pointee.discard = AVDISCARD_ALL
            }
        }
    }

    /// Keyframe timestamps in stream native timebase from libavformat's index.
    /// MKV populates from Cues lazily on first seek (cue-prewarm in
    /// HLSVideoEngine.start() ensures it's ready). MP4 stss / MPEG-TS populate
    /// during avformat_find_stream_info. Empty = no usable index, fall back to
    /// uniform-stride plan. AVINDEX_KEYFRAME checked defensively.
    func indexedKeyframes(streamIndex: Int32) -> [Int64] {
        accessLock.lock()
        defer { accessLock.unlock() }
        let activeCompositionRepair = compositionRepair?.isRepairing == true ? compositionRepair : nil
        guard let ctx = formatContext,
              streamIndex >= 0,
              streamIndex < Int32(ctx.pointee.nb_streams),
              let stream = ctx.pointee.streams[Int(streamIndex)] else {
            return []
        }
        let count = avformat_index_get_entries_count(stream)
        guard count > 0 else { return [] }
        let tb = stream.pointee.time_base
        var result: [Int64] = []
        result.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(stream, i) else { continue }
            // AVINDEX_KEYFRAME = 0x0001
            if entry.pointee.flags & 0x0001 != 0,
               entry.pointee.timestamp != Int64.min {
                // Fold each entry onto the contiguous timeline (multi-clip disc) so the segment plan
                // built from these IRAP positions matches the normalized packets (AE#105), then onto
                // the repaired decode ladder if #409 moved it.
                let folded = normalizedTimestamp(entry.pointee.timestamp, pos: entry.pointee.pos, timeBase: tb)
                if let activeCompositionRepair {
                    // An unplaceable index entry is safer omitted: mixing one raw timestamp into a
                    // repaired rational ladder can cut a segment one picture away from its keyframe.
                    if let repaired = activeCompositionRepair.repairedDecodeTimestamp(folded) {
                        result.append(repaired)
                    }
                } else {
                    result.append(folded)
                }
            }
        }
        return result
    }

    func readPacket() throws -> UnsafeMutablePointer<AVPacket>? {
        accessLock.lock()
        defer { accessLock.unlock() }
        while true {
            // #409: a packet the repair held during its sampling window is handed back before any
            // new read, so the container's own order survives the verdict. Checked every pass, not
            // once on entry: the packet that completes the sample flips the phase, and the queue
            // behind it has to drain before the read that follows it is emitted.
            if let held = compositionRepair?.dequeue() { return held }
            guard let packet = try readPacketLocked() else {
                // EOF can arrive mid-sample on a very short source; the verdict has to be reached
                // now or the held packets would never be delivered.
                compositionRepair?.endOfStream()
                if let held = compositionRepair?.dequeue() { return held }
                return nil
            }
            guard let repair = armCompositionRepairIfNeeded() else { return packet }
            if !repair.ingest(packet) { return packet }
        }
    }

    /// #409: settles the repair verdict now rather than on the first packet read. Call it while the
    /// source still stands where playback will start: the sample is taken from wherever the demuxer
    /// currently is, and every consumer that reads a timestamp axis (the segment plan above all) has
    /// to see the same ladder the packets will carry.
    func decideCompositionOffsetRepair() {
        accessLock.lock()
        defer { accessLock.unlock() }
        decideCompositionRepairLocked()
    }

    /// #409: reads far enough into the source for the verdict, holding every
    /// packet it consumed so nothing is lost. Called before anything reads a timestamp axis off this
    /// demuxer: the container index and the packets must describe the same ladder, and only the
    /// verdict says which ladder that is. Caller holds `accessLock`.
    private func decideCompositionRepairLocked() {
        guard let repair = armCompositionRepairIfNeeded(), !repair.isDecided else { return }
        while !repair.isDecided {
            guard let packet = try? readPacketLocked() else {
                repair.endOfStream()
                return
            }
            if !repair.ingest(packet) {
                // Not held: the session is done with the sample and this packet is already on the
                // final axis, so it goes to the front of the queue rather than out of order.
                repair.enqueueFront(packet)
                return
            }
        }
    }

    /// #409: resolved once per demuxer, at the first read or at the explicit decision above,
    /// because it needs the stream parameters `avformat_find_stream_info` fills in and costs nothing
    /// for the streams it does not apply to.
    private func armCompositionRepairIfNeeded() -> H264CompositionOffsetRepairSession? {
        if compositionRepairEvaluated { return compositionRepair }
        compositionRepairEvaluated = true
        guard let ctx = formatContext else { return nil }
        // Three sources pay a sample they have no use for: a still extraction decodes one keyframe
        // per open and publishes no axis, a demuxer whose video is discarded (the subtitle side
        // reader, #104) has no pictures to sample at all, and a non-seekable source is a live feed,
        // where holding a dozen packets for a defect that lives in a VOD sample table is latency
        // spent for nothing.
        guard openProfile.readerLabel != DemuxerOpenProfile.stillExtraction.readerLabel,
              isSourceSeekable else { return nil }
        let index = max(-1, av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        guard index >= 0, index < Int32(ctx.pointee.nb_streams),
              let stream = ctx.pointee.streams[Int(index)] else { return nil }
        guard stream.pointee.discard != AVDISCARD_ALL else { return nil }
        compositionRepair = H264CompositionOffsetRepairSession(
            containerFormatName: containerFormatName,
            stream: stream,
            streamIndex: index,
            ladderStart: firstIndexedTimestamp(of: stream)
        )
        return compositionRepair
    }

    /// First entry of the container's own sample index, which is where the decode ladder starts even
    /// when this demuxer opened mid-file. Int64.min when the container has no index yet.
    private func firstIndexedTimestamp(of stream: UnsafeMutablePointer<AVStream>) -> Int64 {
        guard avformat_index_get_entries_count(stream) > 0,
              let entry = avformat_index_get_entry(stream, 0) else { return Int64.min }
        return entry.pointee.timestamp
    }

    /// The read itself. Caller holds `accessLock`.
    private func readPacketLocked() throws -> UnsafeMutablePointer<AVPacket>? {
        guard let ctx = formatContext else { return nil }
        var packet: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
        guard packet != nil else { return nil }
        let ret = av_read_frame(ctx, packet)
        if ret < 0 {
            trackedPacketFree(&packet)
            let isEOF = (ret == FFmpegErr.eof)
            if isEOF {
                return nil
            }
            throw DemuxerError.readFailed(code: ret)
        }
        if !clipTimeline.isEmpty, let pkt = packet {
            let si = Int(pkt.pointee.stream_index)
            if si >= 0, si < Int(ctx.pointee.nb_streams), let st = ctx.pointee.streams[si] {
                let pos = pkt.pointee.pos
                let idx = ClipSpan.index(forPos: pos, in: clipTimeline, fallback: lastClipIndex)
                let cleanForward = (idx == lastReadClipIdx + 1)
                lastClipIndex = idx
                let tb = st.pointee.time_base
                let tbSec = (tb.num > 0 && tb.den > 0) ? Double(tb.num) / Double(tb.den) : 0
                // Reference raw timestamp for base capture / offset resolution: prefer DTS (decode order,
                // monotonic within a clip); fall back to PTS.
                let rawRef = pkt.pointee.dts != Int64.min ? pkt.pointee.dts : pkt.pointee.pts
                let rawRefSec = (rawRef != Int64.min && tbSec > 0) ? Double(rawRef) * tbSec : Double.nan

                // Clip 0's observed raw base anchors the whole fold (playback starts at byte 0, so the first
                // clip-0 packet read is its true base).
                if idx == 0, clipBase0Sec.isNaN, rawRefSec.isFinite { clipBase0Sec = rawRefSec }

                // Fold offset actually applied. Clip 0 is untouched (the producer gate zero-bases it). For a
                // later clip, resolve once from its OBSERVED raw base minus clip 0's base minus the (small,
                // wrap-free) MPLS presentation offset. Trust the observed base only on a clean forward
                // crossing so a mid-clip seek cannot mis-anchor it; otherwise fall back to the predicted
                // offset without caching, so a subsequent clean crossing still resolves it correctly.
                var shift = 0.0
                var resolvedNow = false
                var usedObserved = false
                if idx > 0 {
                    let cached = idx < clipResolvedShiftSec.count ? clipResolvedShiftSec[idx] : 0
                    if cached.isFinite {
                        shift = cached
                    } else if cleanForward, clipBase0Sec.isFinite, rawRefSec.isFinite {
                        shift = ClipFold.offsetSeconds(observedBaseSec: rawRefSec, base0Sec: clipBase0Sec,
                                                       cumulativeBeforeSec: clipTimeline[idx].cumulativeBeforeSec)
                        if idx < clipResolvedShiftSec.count { clipResolvedShiftSec[idx] = shift }
                        resolvedNow = true
                        usedObserved = true
                    } else {
                        shift = clipTimeline[idx].predictedShiftSec
                    }
                }
                if shift != 0, tbSec > 0 {
                    let subTicks = Int64((shift / tbSec).rounded())
                    if pkt.pointee.pts != Int64.min { pkt.pointee.pts &-= subTicks }
                    if pkt.pointee.dts != Int64.min { pkt.pointee.dts &-= subTicks }
                }
                // AE#105 diag: print each clip-boundary crossing and each first-time offset resolution so the
                // observed raw base can be compared against the applied offset.
                if idx != diagLastLoggedClipIndex || resolvedNow {
                    diagLastLoggedClipIndex = idx
                    let foldedSec = (pkt.pointee.dts != Int64.min && tbSec > 0) ? Double(pkt.pointee.dts) * tbSec : Double.nan
                    EngineLog.emit("[Demuxer] AE#105 clip -> idx=\(idx) stream=\(si) clean=\(cleanForward) rawBaseSec=\(String(format: "%.3f", rawRefSec)) base0=\(String(format: "%.3f", clipBase0Sec)) cumBefore=\(String(format: "%.3f", clipTimeline[idx].cumulativeBeforeSec)) predicted=\(String(format: "%.3f", clipTimeline[idx].predictedShiftSec)) applied=\(String(format: "%.3f", shift))s obs=\(usedObserved) foldedDts=\(String(format: "%.3f", foldedSec)) prevFolded=\(String(format: "%.3f", diagPrevFoldedSec))", category: .demux)
                }
                if pkt.pointee.dts != Int64.min, tbSec > 0 {
                    diagPrevFoldedSec = Double(pkt.pointee.dts) * tbSec
                }
                lastReadClipIdx = idx
            }
        }
        return packet
    }

    /// Seek via avformat_seek_file (not av_seek_frame: assertion failures
    /// in matroskadec.c with nested elements).
    ///
    /// Returns whether the reposition took. Nearly every caller seeks somewhere it is about to read
    /// from regardless, so the result is discardable; a caller that would otherwise read the wrong
    /// region on a forward-only source (AE#366's prime hunt) has to be able to ask.
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return false }
        // #409: the read position moves, so the repair drops its picture-order anchor and
        // re-anchors on the next keyframe (a seek always lands on one).
        compositionRepair?.noteSeek()
        if let reader = timeSeekableReader {
            guard repositionTimeSeekable(reader, toSourceSeconds: seconds, streamIndex: -1) else { return false }
            resetAfterTimeSeek(ctx)
            return true
        }
        let timestamp = Int64(seconds * Double(AV_TIME_BASE))
        let ret = avformat_seek_file(ctx, -1, Int64.min, timestamp, Int64.max, 0)
        if ret < 0 {
            #if DEBUG
            EngineLog.emit("[Demuxer] Seek to \(seconds)s failed: \(ret)", category: .demux)
            #endif
        }
        avformat_flush(ctx)  // prevents assertion failures in matroskadec.c
        lastReadClipIdx = -1  // AE#105: post-seek reads may land mid-clip; require a fresh clean crossing
        return ret >= 0
    }

    /// Seek on one stream's native timestamp axis, never before `timestamp`.
    @discardableResult
    func seek(to timestamp: Int64, streamIndex: Int32) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext,
              streamIndex >= 0,
              streamIndex < Int32(ctx.pointee.nb_streams) else { return false }
        // #409: the read position moves, so the repair drops its picture-order anchor and
        // re-anchors on the next keyframe (a seek always lands on one).
        compositionRepair?.noteSeek()
        if let reader = timeSeekableReader,
           let stream = ctx.pointee.streams[Int(streamIndex)] {
            let timeBase = stream.pointee.time_base
            guard timeBase.num > 0, timeBase.den > 0 else { return false }
            let seconds = Double(timestamp) * Double(timeBase.num)
                / Double(timeBase.den)
            guard repositionTimeSeekable(reader, toSourceSeconds: seconds, streamIndex: streamIndex) else {
                return false
            }
            resetAfterTimeSeek(ctx)
            return true
        }
        let ret = avformat_seek_file(
            ctx,
            streamIndex,
            timestamp,
            timestamp,
            Int64.max,
            0
        )
        if ret < 0 {
            EngineLog.emit(
                "[Demuxer] Seek to stream \(streamIndex) timestamp \(timestamp) failed: \(ret)",
                category: .demux
            )
        }
        avformat_flush(ctx)
        lastReadClipIdx = -1
        return ret >= 0
    }

    private func resetAfterTimeSeek(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        if let pb = ctx.pointee.pb {
            avio_flush(pb)
            pb.pointee.eof_reached = 0
            pb.pointee.error = 0
        }
        avformat_flush(ctx)
        lastReadClipIdx = -1
    }

    /// #268: the source reader repositions itself on segmented sources whose natural axis is time.
    var timeSeekableReader: TimeSeekableIOReader? {
        (avioProvider as? CustomIOReaderBridge)?.timeSeekableReader
    }

    /// Every engine seek target is an ABSOLUTE source PTS, while a `TimeSeekableIOReader` addresses
    /// elapsed media time (for HLS: the EXTINF sum in front of a segment). MPEG-TS carries an
    /// arbitrary PTS origin, so the two axes differ by that origin: ffmpeg writes 1.4 s by default and
    /// broadcast-derived VOD routinely starts hours in. Handing the raw target to the reader sent a
    /// seek to item second 5 of a 1000 s-origin source to the LAST segment of its playlist, and the
    /// session clock left the item's own duration (measured on `hls-hevc-vod-long-offset`).
    private func repositionTimeSeekable(
        _ reader: TimeSeekableIOReader,
        toSourceSeconds seconds: Double,
        streamIndex: Int32
    ) -> Bool {
        reader.seek(to: max(0, seconds - sourcePTSOriginSeconds(streamIndex: streamIndex)))
    }

    /// PTS origin of the source axis in seconds: the anchoring stream's own `start_time` when it has
    /// one (a stream-anchored seek is measured against exactly that stream), else the container's.
    /// Unknown origins resolve to 0, which keeps the mapping identical to the pre-#268 behaviour.
    private func sourcePTSOriginSeconds(streamIndex: Int32) -> Double {
        guard let ctx = formatContext else { return 0 }
        if streamIndex >= 0, streamIndex < Int32(ctx.pointee.nb_streams),
           let stream = ctx.pointee.streams[Int(streamIndex)] {
            let start = stream.pointee.start_time
            let timeBase = stream.pointee.time_base
            if start != Int64.min, timeBase.num > 0, timeBase.den > 0 {
                return Double(start) * Double(timeBase.num) / Double(timeBase.den)
            }
        }
        let start = ctx.pointee.start_time
        guard start != Int64.min else { return 0 }
        return Double(start) / Double(AV_TIME_BASE)
    }

    /// #112 round 10: latched by the side reader once a timestamp positioning seek timed out or failed on this
    /// container (index-less MPEG-TS: read_timestamp binary search is either wedged or broken). Later re-arms on
    /// a reused demuxer skip straight to the byte estimate instead of paying the seek budget per positioning.
    /// Binary lockout, never re-armed for the demuxer's lifetime.
    private(set) var timestampSeekUnreliable = false

    func markTimestampSeekUnreliable() {
        accessLock.lock()
        defer { accessLock.unlock() }
        timestampSeekUnreliable = true
    }

    /// The stream libavformat would measure a `-1` seek against, or -1 when there is no context.
    ///
    /// Exposed because that choice is not stable across a session: `av_find_default_stream_index`
    /// scores `discard != AVDISCARD_ALL` at +200, so which stream anchors a seek changes with the
    /// discard configuration (#234).
    func defaultSeekReferenceStreamIndex() -> Int32 {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return -1 }
        return av_find_default_stream_index(ctx)
    }

    /// Seek with AVIO read deadline. Returns true if completed; false if aborted.
    /// Needed for VOD cue prewarm: missing/truncated MKV Cues causes matroska to
    /// degrade from "1-2 byte-range reads" into a linear half-file scan on a remote
    /// 70+ GB source (de-facto hang). Only AVIOReader honours the deadline.
    ///
    /// `anchorStreamIndex` names the stream the target is measured against. -1, the default, hands
    /// that choice to libavformat, which scores `discard != AVDISCARD_ALL` at +200 and therefore
    /// re-decides it whenever the discard configuration changes: a side reader that discarded
    /// everything but its subtitle stream was anchored on that stream by accident, and #230's
    /// pacing stream silently moved the anchor onto video keyframes (#234). A caller that reads one
    /// sparse stream wants its own axis, so it says so. An index outside the source falls back to
    /// the default rather than failing the seek.
    @discardableResult
    func seekBounded(to seconds: Double, anchorStreamIndex: Int32 = -1,
                     timeout: TimeInterval) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return false }
        // #409: the read position moves, so the repair drops its picture-order anchor and
        // re-anchors on the next keyframe (a seek always lands on one).
        compositionRepair?.noteSeek()
        // #268: a time-seekable source repositions itself instead of paying libavformat's byte-space
        // binary search, which on an index-less MPEG-TS is either wedged or broken (round 10 below) and
        // over HTTP would additionally be a request storm. No read deadline is armed: the reader's
        // reposition is a bookkeeping operation, the refetch happens behind the FIFO.
        if let reader = timeSeekableReader {
            guard repositionTimeSeekable(reader, toSourceSeconds: seconds, streamIndex: anchorStreamIndex) else {
                return false
            }
            resetAfterTimeSeek(ctx)
            return true
        }
        // #112 round 9: the deadline lives on the provider protocol. Casting to AVIOReader here left a
        // disc-adapter source (CustomIOReaderBridge over HTTPDiscIOReader) unbounded: one positioning
        // seek on a remote ISO sat wedged ~230 s and every later re-arm queued behind it.
        avioProvider?.beginReadDeadline(secondsFromNow: timeout)
        defer { avioProvider?.endReadDeadline() }
        // A stream-anchored seek carries the target in that stream's own time base; only the -1
        // form is expressed in AV_TIME_BASE units.
        var anchor: Int32 = -1
        var timestamp = Int64(seconds * Double(AV_TIME_BASE))
        if anchorStreamIndex >= 0, anchorStreamIndex < Int32(ctx.pointee.nb_streams),
           let tb = ctx.pointee.streams[Int(anchorStreamIndex)]?.pointee.time_base,
           tb.num > 0, tb.den > 0 {
            anchor = anchorStreamIndex
            timestamp = Int64(seconds * Double(tb.den) / Double(tb.num))
        }
        let ret = avformat_seek_file(ctx, anchor, Int64.min, timestamp, Int64.max, 0)
        avformat_flush(ctx)
        lastReadClipIdx = -1  // AE#105: post-seek reads may land mid-clip; require a fresh clean crossing
        // matroska may return success with a partial index after abort; deadline flag
        // is authoritative, not ret.
        let capped = avioProvider?.readDeadlineFired ?? false
        return ret >= 0 && !capped
    }

    /// How an off-actor reposition ended (#254). Named to mirror `SeekEvent.Outcome` so the engine's
    /// mapping onto the public seek-event stream is one line.
    enum RepositionOutcome: Sendable, Equatable {
        /// `avformat_seek_file` completed inside the budget; the read position is at the target.
        case landed
        /// The reposition did not complete: the read deadline fired, `avformat_seek_file` failed, or
        /// there was no open format context. The read position is undefined.
        case stalled
        /// A newer seek arrived before this one reached the demuxer, so it never ran.
        case superseded
    }

    /// `seekBounded` off the caller's actor (#254).
    ///
    /// `readPacket` holds `accessLock` for the whole of `av_read_frame`, so the `accessLock.lock()`
    /// inside every seek first waits out whatever read is in flight, up to `AVIOReader.connStallTimeout`
    /// (20 s), BEFORE the deadline armed inside `seekBounded` starts counting. A `@MainActor` host that
    /// calls the synchronous form therefore blocks the main thread for the length of one remote read;
    /// the field saw 4.4 s and 5.2 s "Fully Blocked" App Hangs on a WAN source that way. The deadline
    /// on its own does not fix that class, because it is armed on the far side of the lock.
    ///
    /// `queue` must be serial, so repositions stay in issue order, and must not be the queue the
    /// caller's demux loop occupies (that block never returns, so the seek would never run).
    /// `isSuperseded` is evaluated ON that queue, immediately before the FFmpeg call: a scrub burst
    /// then collapses onto its last target instead of paying one lock wait per seek.
    func seekBounded(to seconds: Double, anchorStreamIndex: Int32 = -1, timeout: TimeInterval,
                     on queue: DispatchQueue,
                     isSuperseded: (@Sendable () -> Bool)? = nil) async -> RepositionOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isSuperseded?() != true else {
                    continuation.resume(returning: .superseded)
                    return
                }
                let completed = seekBounded(to: seconds, anchorStreamIndex: anchorStreamIndex,
                                            timeout: timeout)
                continuation.resume(returning: completed ? .landed : .stalled)
            }
        }
    }

    /// #112 round 8/10: byte-position seek for an index-less container. On a remote MPEG-TS with no index, a
    /// timestamp `avformat_seek_file` binary-searches via read_timestamp: dozens of remote range reads, each
    /// able to ride a starved connection's full timeout while the video pipeline competes for the origin
    /// (device: the subtitle side reader sat in one seek for minutes and every later re-arm queued behind it).
    /// Round 10: the estimate maps `target` onto the byte axis on the FILE-RELATIVE time axis. A Blu-ray
    /// title's bytes cover source times [startOrigin, startOrigin + duration] (600 s origin on the reporter's
    /// disc); mapping the absolute source PTS landed 227 s PAST the target, and the forward-only read loop
    /// parked ahead of the playhead with nothing to show. The landing is now verified by probing the first
    /// packet PTS and corrected proportionally (calibrated by the landing itself, at most
    /// `byteEstimateMaxCorrections` probes), all under one read deadline. Returns false without touching the
    /// position when size or duration is unknown.
    @discardableResult
    func seekByteEstimate(to seconds: Double, knownDuration: Double, timeout: TimeInterval = 8.0) -> Bool {
        let origin = resolvedSourceStartOrigin
        let size: Int64? = {
            accessLock.lock()
            defer { accessLock.unlock() }
            return avioProvider?.resolvedByteSize
        }()
        guard let size,
              var byteTarget = Self.byteEstimateTarget(
                  fileSize: size, duration: knownDuration, target: seconds, startOrigin: origin)
        else { return false }
        avioProvider?.beginReadDeadline(secondsFromNow: timeout)
        defer { avioProvider?.endReadDeadline() }
        var attempt = 0
        var landedLog = "unverified"
        while true {
            guard byteSeek(to: byteTarget) else { return false }
            guard avioProvider?.readDeadlineFired != true,
                  let landed = probeLandedSeconds()
            else { break }  // cannot verify (deadline / no PTS in reach): keep the estimate as-is
            landedLog = String(format: "%.2f", landed) + "s"
            let decision = Self.byteEstimateCorrection(
                landed: landed, target: seconds, startOrigin: origin, duration: knownDuration,
                fileSize: size, currentByte: byteTarget, attempt: attempt)
            switch decision {
            case .accept:
                // Rewind the probe reads so the caller's read loop starts at the accepted landing.
                _ = byteSeek(to: byteTarget)
                EngineLog.emit(
                    "[Demuxer] byte-estimate landed \(landedLog) for target "
                    + "\(String(format: "%.2f", seconds))s (origin \(String(format: "%.2f", origin))s, "
                    + "\(attempt) correction(s))",
                    category: .demux)
                return true
            case .probe(let next):
                byteTarget = next
                attempt += 1
            }
        }
        EngineLog.emit(
            "[Demuxer] byte-estimate accepted \(landedLog) for target \(String(format: "%.2f", seconds))s "
            + "(origin \(String(format: "%.2f", origin))s, deadline/probe exhausted after \(attempt) correction(s))",
            category: .demux)
        return byteSeek(to: byteTarget)
    }

    /// #112 round 8/10: byte offset for `seekByteEstimate`. `startOrigin` is the source PTS of the file's first
    /// byte (Blu-ray titles do not start at 0); `earlyBiasSeconds` shifts the landing a fixed number of seconds
    /// earlier so bitrate variance around the target biases toward landing BEFORE the playhead, never past it.
    /// (Round 8 used a fraction-of-file bias: 5% of a 2 h title is 375 s of remote forward read.)
    nonisolated static func byteEstimateTarget(
        fileSize: Int64, duration: Double, target: Double,
        startOrigin: Double = 0, earlyBiasSeconds: Double = 12.0
    ) -> Int64? {
        guard fileSize > 0, duration > 0, target >= 0 else { return nil }
        let fraction = min(1.0, max(0.0, (target - startOrigin - earlyBiasSeconds) / duration))
        return Int64(Double(fileSize) * fraction)
    }

    /// Landing verdict for one byte-estimate probe (#112 round 10).
    enum ByteProbeDecision: Equatable {
        case accept
        case probe(Int64)
    }

    /// A late landing is unrecoverable for the forward-only side reader; a far-early landing wastes minutes of
    /// remote forward read. Both re-probe with the slope calibrated by the landing itself: `currentByte` covers
    /// `landed - startOrigin` seconds of media, so the corrected byte is proportional on the file-relative axis.
    nonisolated static let byteEstimateMaxCorrections = 2
    nonisolated static let byteEstimateAcceptEarlyWindowSeconds = 180.0
    nonisolated static func byteEstimateCorrection(
        landed: Double, target: Double, startOrigin: Double, duration: Double,
        fileSize: Int64, currentByte: Int64, attempt: Int, earlyBiasSeconds: Double = 12.0
    ) -> ByteProbeDecision {
        guard attempt < byteEstimateMaxCorrections, fileSize > 0, currentByte > 0 else { return .accept }
        let landedRel = landed - startOrigin
        let targetRel = target - startOrigin - earlyBiasSeconds
        guard landedRel > 1.0, targetRel > 0 else { return .accept }
        let late = landed > target
        let farEarly = landed < target - byteEstimateAcceptEarlyWindowSeconds
        guard late || farEarly else { return .accept }
        let corrected = min(fileSize, max(0, Int64(Double(currentByte) * (targetRel / landedRel))))
        guard corrected != currentByte else { return .accept }
        return .probe(corrected)
    }

    /// Source PTS of the file's first byte, for the byte-estimate axis (#112 round 10). The reporter's remote
    /// ISO reports format.start_time as NOPTS while the video stream carries start_time 54000000 (600 s) in
    /// 1/90000, so the stream start backs up the format-level value.
    nonisolated static func sourceStartOrigin(
        formatStartUs: Int64, videoStreamStart: Int64, videoTimeBaseNum: Int32, videoTimeBaseDen: Int32
    ) -> Double {
        if formatStartUs != Int64.min, formatStartUs >= 0 {
            return Double(formatStartUs) / 1_000_000
        }
        if videoStreamStart != Int64.min, videoStreamStart >= 0, videoTimeBaseNum > 0, videoTimeBaseDen > 0 {
            return Double(videoStreamStart) * Double(videoTimeBaseNum) / Double(videoTimeBaseDen)
        }
        return 0
    }

    /// `sourceStartOrigin` resolved from this demuxer's own metadata.
    var resolvedSourceStartOrigin: Double {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return 0 }
        var videoStart = Int64.min
        var tbNum: Int32 = 0
        var tbDen: Int32 = 0
        let vIdx = max(-1, av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        if vIdx >= 0, vIdx < Int32(ctx.pointee.nb_streams), let st = ctx.pointee.streams[Int(vIdx)] {
            videoStart = st.pointee.start_time
            tbNum = st.pointee.time_base.num
            tbDen = st.pointee.time_base.den
        }
        return Self.sourceStartOrigin(
            formatStartUs: ctx.pointee.start_time, videoStreamStart: videoStart,
            videoTimeBaseNum: tbNum, videoTimeBaseDen: tbDen)
    }

    /// One AVSEEK_FLAG_BYTE positioning seek + flush. Shared by the estimate probe loop.
    private func byteSeek(to byteTarget: Int64) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext else { return false }
        compositionRepair?.noteSeek()  // #409: re-anchor on the next keyframe
        let ret = avformat_seek_file(ctx, -1, Int64.min, byteTarget, Int64.max, AVSEEK_FLAG_BYTE)
        avformat_flush(ctx)
        lastReadClipIdx = -1  // AE#105: post-seek reads may land mid-clip; require a fresh clean crossing
        return ret >= 0
    }

    /// First packet PTS (seconds, folded source axis) after a byte-estimate landing. The side reader has every
    /// stream but its own subtitle discarded (#104), and subtitle packets are sparse; the video stream is
    /// temporarily re-enabled so the probe resolves within a few packets, then its discard is restored.
    private func probeLandedSeconds() -> Double? {
        let videoIndex: Int32 = {
            accessLock.lock()
            defer { accessLock.unlock() }
            guard let ctx = formatContext else { return -1 }
            return max(-1, av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        }()
        let restoreDiscard = setStreamDiscardForProbe(index: videoIndex)
        defer { if restoreDiscard { setStreamDiscard(index: videoIndex, discard: AVDISCARD_ALL) } }
        for _ in 0..<128 {
            guard let pkt = try? readPacket() else { return nil }
            var packet: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&packet) }
            let ts = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
            guard ts != Int64.min else { continue }
            let seconds: Double? = {
                accessLock.lock()
                defer { accessLock.unlock() }
                guard let ctx = formatContext,
                      pkt.pointee.stream_index >= 0,
                      pkt.pointee.stream_index < Int32(ctx.pointee.nb_streams),
                      let st = ctx.pointee.streams[Int(pkt.pointee.stream_index)]
                else { return nil }
                let tb = st.pointee.time_base
                guard tb.num > 0, tb.den > 0 else { return nil }
                return Double(ts) * Double(tb.num) / Double(tb.den)
            }()
            if let seconds { return seconds }
        }
        return nil
    }

    /// Re-enables a discarded probe stream. Returns true if it flipped the discard (caller restores it).
    private func setStreamDiscardForProbe(index: Int32) -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext, index >= 0, index < Int32(ctx.pointee.nb_streams),
              let st = ctx.pointee.streams[Int(index)], st.pointee.discard == AVDISCARD_ALL
        else { return false }
        st.pointee.discard = AVDISCARD_DEFAULT
        return true
    }

    private func setStreamDiscard(index: Int32, discard: AVDiscard) {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let ctx = formatContext, index >= 0, index < Int32(ctx.pointee.nb_streams),
              let st = ctx.pointee.streams[Int(index)] else { return }
        st.pointee.discard = discard
    }

    /// Arm a wall-clock read deadline on the AVIO reader so a stalled HTTP read
    /// (seek or readPacket) aborts instead of parking. Used by FrameExtractor still
    /// extraction so a disposable scrub thumbnail bounds its decode and never freezes
    /// the serial decode queue (issue #27). No-op for file:// / custom sources.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        avioProvider?.beginReadDeadline(secondsFromNow: seconds)
    }

    /// Disarm the read deadline armed by `beginReadDeadline`.
    func endReadDeadline() {
        avioProvider?.endReadDeadline()
    }

    /// Fast lock-free unblock: AVIO read callback returns -1, av_read_frame returns
    /// at once. No resource freeing. Call before close() when cancelling a pump.
    func markClosed() {
        avioProvider?.markClosed()
    }

    func close() {
        avioProvider?.markClosed()  // unblocks av_read_frame (tvOS suspends threads in background)
        accessLock.lock()
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        formatContext = nil
        compositionRepair = nil
        compositionRepairEvaluated = false
        accessLock.unlock()

        avioProvider?.close()
        avioProvider = nil
    }

    deinit {
        close()
    }
}

enum DemuxerError: Error, CustomStringConvertible, LocalizedError {
    case openFailed(code: Int32)
    case streamInfoFailed(code: Int32)
    case readFailed(code: Int32)

    /// AE#283: this is the most common error at the load boundary, and the AVERROR code is the whole
    /// diagnosis (INVALIDDATA vs a POSIX errno vs EOF). Rendering it keeps a refused transcode
    /// distinguishable from a corrupt file.
    var description: String {
        switch self {
        case .openFailed(let code): "Demuxer: open failed (\(FFmpegErr.text(for: code)))"
        case .streamInfoFailed(let code): "Demuxer: stream info failed (\(FFmpegErr.text(for: code)))"
        case .readFailed(let code): "Demuxer: read failed (\(FFmpegErr.text(for: code)))"
        }
    }

    var errorDescription: String? { description }
}
