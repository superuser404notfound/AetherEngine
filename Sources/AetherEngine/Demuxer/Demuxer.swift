import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import os


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

    /// [MovieClaw P56] 这次播放从文件头起（没有续播点）。读取器据此决定索引提前取一到就把文件头连接续上：从头播时
    /// 那正是接下来要播的字节；续播时引擎马上要跳到续播点，续上文件头只会在慢线路上白占带宽。默认 true（原来的行为）
    var playbackStartsAtHead: Bool = true

    /// [MovieClaw P58] 服务端给的 Matroska 精简索引：读取器在解复用器读 SeekHead 登记的 Cues 位置时直接给它。只挂在
    /// 主播放的配置上（探测兼会话的那次打开、HLS 生成器的兜底打开与卡死重开）；旁路解复用器从 `.playback` 另起配置，
    /// 照旧读原索引
    var hostMatroskaCues: MatroskaHostCues? = nil

    /// `LoadOptions.sequentialOrigin`: the origin fabricates range answers, so the AVIO reader must
    /// run its forward-only streaming mode (one unranged GET from byte 0) and never issue a ranged
    /// request. Lives in the profile so the probe demuxer, the session demuxer, and every fresh
    /// reopen (wedge restart, revive) inherit it together.
    var avioSequentialOnly: Bool = false

    /// `LoadOptions.heldSourceConnection` (#377): the playback reader asks the origin once and
    /// pulls, rather than ending at the window high water and asking again at low water. Rides in
    /// the profile next to `avioSequentialOnly` so every reopen of the session (wedge restart,
    /// revive) inherits it. The side demuxers build their own profiles from `playback` and are
    /// deliberately left on the pushed path: their readers park for minutes at a time, which is
    /// the one shape a held connection must not take.
    var avioHeldConnection: Bool = false

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

    /// Whether a probe of an untagged 10-bit HEVC source may read its first RPU to find a Dolby Vision
    /// Profile 5 the container never recorded (`DolbyVisionRecordAudit.addRecordIfProfile5`). On for every
    /// playback open, so the probe, the HLS producer's own open and every rebuild agree; off for the
    /// disposable still extractor.
    var auditsRecordlessDolbyVision: Bool = true

    /// [MovieClaw P56] 带上「这次从文件头起播」的声明，写法同 `withSequentialOrigin`，调用点链在已有的配置后面
    func withPlaybackStartsAtHead(_ startsAtHead: Bool) -> DemuxerOpenProfile {
        var copy = self
        copy.playbackStartsAtHead = startsAtHead
        return copy
    }

    /// [MovieClaw P58] 带上服务端给的精简索引（开关 `AetherEngine.usesHostMatroskaCues` 关着时不带），写法同上
    func withHostMatroskaCues(_ cues: MatroskaHostCues?) -> DemuxerOpenProfile {
        var copy = self
        copy.hostMatroskaCues = AetherEngine.usesHostMatroskaCues ? cues : nil
        return copy
    }

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
        readerLabel: "extract",
        auditsRecordlessDolbyVision: false
    )

    /// AE#682: the I-frame rendition's side reader. Reads one keyframe per request, so it takes the
    /// still extractor's tuning under a name of its own (#240: a connection line without a name
    /// cannot say which reader opened it).
    static let iFrameSideDemuxer = stillExtraction.withReaderLabel("iframe")

    /// Readers that fetch single keyframes and publish no timestamp axis, so the #409 repair's
    /// sample window would be packets read for nothing.
    static let labelsWithoutCompositionRepair: Set<String> = [
        stillExtraction.readerLabel, iFrameSideDemuxer.readerLabel,
    ]

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

    /// A copy of `self` carrying the host's held-connection request (#377), chainable in the style
    /// of `withSequentialOrigin` so a call site can add it to the profile it already built.
    func withHeldSourceConnection(_ held: Bool) -> DemuxerOpenProfile {
        var copy = self
        copy.avioHeldConnection = held
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

    /// Open profile for the AE#532 Dolby Vision record audit. Same shape and the same reasoning as the
    /// Atmos pass above: the audit wants packets, not stream info, and the sample entry the framing is
    /// read from is already resolved by `avformat_open_input`. It reaches its answer in the first video
    /// packet rather than deep in the interleave, so it is the cheaper of the two by construction.
    static func dolbyVisionRecordAuditDemuxer(callerProbesize: Int64?, callerMaxAnalyzeDuration: Int64?)
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

    /// Audit DMX-11: `markClosed()` is the lock-free cross-thread abort, so it loads this reference
    /// while the demux thread may be clearing it in `close()` or a failed open. A leaf lock of its
    /// own (never `accessLock`, which `av_read_frame` holds for a whole network read) makes that
    /// load a retained snapshot instead of a race.
    private let providerLock = NSLock()
    private var _avioProvider: AVIOProvider?
    private var avioProvider: AVIOProvider? {
        get {
            providerLock.lock()
            defer { providerLock.unlock() }
            return _avioProvider
        }
        set {
            providerLock.lock()
            _avioProvider = newValue
            providerLock.unlock()
        }
    }

    /// Audit NET-110: the disc reader `openHTTP` builds for a remote disc image. The disc adapter's
    /// `ConcatIOReader.close()` is a no-op and the bridge does not own its reader, so this is the only
    /// owner left to end the reader's `URLSession`. Guarded by `providerLock`.
    private var _ownedSourceReader: IOReader?

    private func adoptOwnedSourceReader(_ reader: IOReader) {
        providerLock.lock()
        let previous = _ownedSourceReader
        _ownedSourceReader = reader
        providerLock.unlock()
        previous?.close()
    }

    private func releaseOwnedSourceReader() {
        providerLock.lock()
        let reader = _ownedSourceReader
        _ownedSourceReader = nil
        providerLock.unlock()
        reader?.close()
    }

    /// Audit DMX-102: unblocks the disc reader while `DiscReader.wrap` is still reading through it,
    /// before any provider exists for `markClosed()` to reach.
    private func cancelOwnedSourceReader() {
        providerLock.lock()
        let reader = _ownedSourceReader
        providerLock.unlock()
        reader?.cancel()
    }

    /// Audit HLS-2: `markClosed()` before the provider exists used to be a no-op, so a teardown
    /// that raced an in-flight open let it finish its connect and probe.
    private let closeRequestLock = NSLock()
    private var closeRequested = false
    private var isCloseRequested: Bool { closeRequestLock.withLock { closeRequested } }
    private var openProfile: DemuxerOpenProfile = .playback

    /// Audit NAT-7: the stream pointers `stream(at:)` hands out, copied out of `formatContext`
    /// under `accessLock`. MPEG-TS adds streams inside `av_read_frame`, which reallocates the
    /// `streams` array, so a caller on another thread must not index the live array while a read
    /// holds the lock. The `AVStream`s themselves live until `avformat_close_input`. Guarded by
    /// `streamTableLock`, a leaf lock; `streamTableSize` is its length, guarded by `accessLock`.
    ///
    /// Audit DMX-108: also the gate `withStream` and `close()` meet at. A caller inside
    /// `withStream` counts itself in `streamUsers`, and `close()` empties the table (so no new one
    /// can start) and waits for the count to reach zero before `avformat_close_input` frees the
    /// `AVStream`s. The condition is on the leaf lock, so the wait never holds `accessLock`'s
    /// network reads against anyone.
    private let streamTableLock = NSCondition()
    private var streamTable: [UnsafeMutablePointer<AVStream>] = []
    private var streamTableSize = 0
    private var streamUsers = 0

    /// Audit DMX-108: what the track accessors answer with when a read holds `accessLock`.
    /// MPEG-TS adds streams inside `av_read_frame`, which reallocates `streams`, so the accessors
    /// walk the live array only under the lock, and the lock can be held for a whole network read.
    /// An accessor that finds it busy answers from the last snapshot instead of waiting, the same
    /// contract NAT-7 gave `stream(at:)`. Guarded by `streamTableLock`.
    private struct TrackSnapshot {
        var videoStreamIndex: Int32 = -1
        var audioStreamIndex: Int32 = -1
        var firstAudioStreamIndexByType: Int32 = -1
        var audioTracks: [TrackInfo] = []
        var subtitleTracks: [TrackInfo] = []
        var subtitleStreamIndices: Set<Int32> = []
        var splitDisplaySetSubtitleStreamIndices: Set<Int32> = []
    }
    private var trackSnapshot = TrackSnapshot()

    /// The URL and headers this demuxer was opened from, kept for the recordless Dolby Vision audit's
    /// second open. nil for a custom reader (no second open to give) and for a live source.
    private var auditSource: (url: URL, headers: [String: String])?

    /// #409: rewrites the timestamps of an MP4 whose writer dropped the composition-offset table.
    /// Lives here rather than in a playback host so that every consumer of this demuxer (the fMP4
    /// producer, the segment plan, the software decoder, the still extractor) reads the same axis;
    /// a repair applied per host would have them disagree by the reorder delay. nil for every stream
    /// that is not the exact defect shape, which is decided once, on the first read.
    private var compositionRepair: (any H264TimestampRepairSession)?
    private var compositionRepairEvaluated = false

    /// Audit HLS-103: packets `peekPackets` read ahead of the cursor on a source that cannot rewind.
    /// They are already through everything `readPacket` does to a packet (the #409 repair, the
    /// timestamp bound), so `readPacket` hands them out first and as they are. Freed by a
    /// reposition and by `close()`. Guarded by `accessLock`.
    private var peekedPackets: [UnsafeMutablePointer<AVPacket>] = []

    /// #407: video streams whose PTS `+genpts` invented out of decode order, because the container
    /// carries none of its own. Cleared on the way out of `readPacketLocked` so the decoder's reorder
    /// owns the presentation axis. Decided once at open, see `armGeneratedPTSSuppression`.
    private var generatedPTSStreams: Set<Int32> = []

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

    /// True when libavformat opened the source itself, which it does only for a local path
    /// (`openLocal`). Every network, disc and custom source is read through an `AVIOProvider`.
    /// A caller that only wants to spend disk to avoid a re-READ asks this: re-reading a local
    /// file costs a page-cache hit, so a second copy of it in the temporary directory buys nothing.
    var readsSourceDirectly: Bool { avioProvider == nil }

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

    /// Passed to the source reader so a held connection can tell a parked producer from a paused
    /// viewer. Same provider the segment producer reads. `didSet` re-forwards for the same reason
    /// `onNetworkPhaseChanged` does: it may be set before or after `open()`.
    var playIntentProvider: (@Sendable () -> Bool)? {
        didSet { (avioProvider as? AVIOReader)?.playIntentProvider = playIntentProvider }
    }

    /// #361: emitted as each stage of `open()` finishes, so the engine can publish startup progress
    /// through the one stretch of a load a host cannot otherwise see. Called on whatever thread the
    /// open runs on (the playback open is detached off the main actor), never after `open()` returns.
    /// Set only on the playback probe demuxer; every other demuxer (side readers, still extraction)
    /// leaves it nil and emits nothing.
    var onOpenProgress: (@Sendable (DemuxerOpenStage) -> Void)?

    /// AE#678: when this open started and when each stage finished, for the one timing line an open
    /// emits. `#361`'s checkpoints carry the same boundaries to the host, but only as a ladder with no
    /// durations, and a downstream integrator had to guess whether the connect, the container or the
    /// stream analysis was the slow leg.
    private var openStartedAt: DispatchTime?
    private var openStageTimes: [DemuxerOpenStage: DispatchTime] = [:]

    private func beginOpenTiming() {
        openStartedAt = DispatchTime.now()
        openStageTimes = [:]
    }

    private func reportOpenStage(_ stage: DemuxerOpenStage) {
        openStageTimes[stage] = DispatchTime.now()
        onOpenProgress?(stage)
        if stage == .streamsProbed { emitOpenTimings(outcome: nil) }
    }

    /// Stills and the subtitle side reader open far too often to narrate, and the latter skips the
    /// stream analysis the line exists to time.
    private var reportsOpenTimings: Bool {
        openProfile.readerLabel != DemuxerOpenProfile.stillExtraction.readerLabel && !openProfile.skipStreamInfo
    }

    private func emitOpenTimings(outcome: String?) {
        guard reportsOpenTimings, let start = openStartedAt else { return }
        openStartedAt = nil
        func ms(_ from: DispatchTime?, _ to: DispatchTime?) -> String {
            guard let from, let to, to.uptimeNanoseconds >= from.uptimeNanoseconds else { return "-" }
            return "\((to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000)ms"
        }
        let source = openStageTimes[.sourceOpened]
        let container = openStageTimes[.containerOpened]
        let probed = openStageTimes[.streamsProbed] ?? (outcome == nil ? nil : DispatchTime.now())
        let streams = formatContext.map { Int($0.pointee.nb_streams) } ?? 0
        EngineLog.emit(
            "[Demuxer] open timings (\(openProfile.readerLabel)): connect \(ms(start, source)), "
            + "open_input \(ms(source ?? start, container)), find_stream_info \(ms(container, probed)), "
            + "total \(ms(start, probed)); \(streams) stream(s), probesize \(openProfile.probesize / 1_048_576) MiB, "
            + "analyzeduration \(openProfile.maxAnalyzeDuration / 1_000_000) s"
            + (outcome.map { "; \($0)" } ?? ""),
            category: .demux
        )
    }

    // MARK: - Disc titles / chapters (#67)

    private(set) var discTitles: [DiscTitle] = []
    private(set) var selectedDiscTitleIndex: Int = 0

    /// Language codes the selected disc title declares for its elementary streams, keyed by `AVStream.id`
    /// (MPEG-TS PID on Blu-ray, MPEG-PS stream / substream id on DVD). Neither disc format repeats the
    /// language inside the stream, so `trackInfo` backfills undetermined tracks from this; empty for every
    /// non-disc source, where it is a no-op (#527).
    private(set) var discStreamLanguages: [Int: String] = [:]
    /// #651: the selected DVD title's declared subpicture substream ids, created before the probe.
    private var discSubpictureStreamIDs: [Int]?
    /// #651: one assembler per stream `declareDiscSubpictureStreams` created, keyed by stream index.
    /// Those streams have no libavformat parser, so their fragments are joined here. Under `accessLock`.
    private var subpictureAssemblers: [Int32: DVDSubpictureAssembler] = [:]

    /// Per-clip presentation-offset spans for a selected multi-clip Blu-ray title (empty otherwise). When
    /// non-empty, `readPacket` and `indexedKeyframes` fold each clip's timestamps onto one contiguous
    /// timeline so the playhead does not leap at clip boundaries (AE#105). Guarded by `accessLock`.
    private var clipTimeline: [ClipSpan] = []
    /// [MovieClaw P7] 选中蓝光标题的 CLPI 定位表：有它就按 EP map 按字节定位，不再按时间二分
    private var discSeekTable: DiscSeekTable?
    /// [MovieClaw P13] 选中 DVD 标题按 cell 折叠：cell 的时间戳基准从导航包算（见 `adoptDVDNav`）
    private var dvdCellFold = false
    /// [MovieClaw P13] 选中 DVD 标题的时间表：有它就「标题时间 → VOBU 字节偏移」一次定位
    private var dvdTimeMap: DVDTimeMap?
    /// [MovieClaw P18] 没有可用 Cues 的 MKV（文件头判定，见 `MatroskaCuesProbe`）：引擎起播前不做索引预热，
    /// 按时间定位前先按字节探一个 Cluster 登记成索引项（`assistIndexlessMatroskaSeek`）
    private(set) var indexlessMatroska = false
    private var matroskaTimestampScale: UInt64 = 1_000_000
    /// [MovieClaw P9] UHD 原盘双 PID 杜比视界：基础层（PID 0x1011）与增强层（PID 0x1015）的流下标，
    /// 没有这种结构时为 -1。增强层只取它的 RPU 挂到同一时间戳的基础层包上，包本身不往下游送
    private var dvBaseLayerStream: Int32 = -1
    private var dvEnhancementStream: Int32 = -1
    /// 增强层里取出的 RPU（按 PTS），等同一时间戳的基础层访问单元来取
    private var dvPendingRPU: [Int64: [UInt8]] = [:]
    /// 在等 RPU 的基础层包（保持解码顺序）
    private var dvHeldBase: [UnsafeMutablePointer<AVPacket>] = []
    /// 已挂好 RPU、等着交出的基础层包（保持解码顺序）
    private var dvReady: [UnsafeMutablePointer<AVPacket>] = []
    private var dvStats = (attached: 0, missed: 0)
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
        discStreamLanguages = info.selectedTitle?.streamLanguages ?? [:]
        discSubpictureStreamIDs = info.selectedTitle?.dvdSubpictureStreamIDs
        clipTimeline = info.clipTimeline
        discSeekTable = info.seekTable
        dvdTimeMap = info.dvdTimeMap
        dvdCellFold = info.formatHint == "mpeg" && !info.clipTimeline.isEmpty
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
    private func normalizedTimestamp(_ ts: Int64, pos: Int64, timeBase: AVRational) -> Int64? {
        guard ts != Int64.min, !clipTimeline.isEmpty else { return ts }
        return Self.foldedIndexTimestamp(ts, subtractSeconds: clipSubtractSeconds(forPos: pos), timeBase: timeBase)
    }

    /// The AE#105 fold of one index entry, nil when the shift or the result leaves the tick range. The
    /// shift comes from the disc's own playlist, and a wrapped entry is worse than a missing one: the
    /// plan built from it lands wherever the wrap put it (audit HLS-102).
    static func foldedIndexTimestamp(_ ts: Int64, subtractSeconds sub: Double, timeBase: AVRational) -> Int64? {
        guard sub != 0, timeBase.num > 0, timeBase.den > 0 else { return ts }
        let subTicks = (sub * Double(timeBase.den) / Double(timeBase.num)).rounded()
        guard subTicks.isFinite, abs(subTicks) < Self.maxPlausibleIndexTicks else { return nil }
        let (folded, overflow) = ts.subtractingReportingOverflow(Int64(subTicks))
        return overflow ? nil : folded
    }

    /// The #409 decode-ladder offset applied to one index entry, nil on overflow (audit HLS-102).
    static func offsetIndexTimestamp(_ ts: Int64, by offset: Int64?) -> Int64? {
        guard let offset else { return ts }
        let (placed, overflow) = ts.addingReportingOverflow(offset)
        return overflow ? nil : placed
    }

    /// Whether an index entry can be a real position (audit HLS-102), by the same rule the packet
    /// funnel applies (`SourceTimestampBounds.plausible(_:timeBase:)`). libavformat rejects only NOPTS
    /// and the relative-timestamp band near `Int64.max`; entries near `Int64.min` and just below the
    /// band reach the plan builders otherwise.
    static func isPlausibleIndexTimestamp(_ ts: Int64, timeBase: AVRational) -> Bool {
        guard timeBase.num > 0, timeBase.den > 0 else { return false }
        return SourceTimestampBounds.plausible(ts, timeBase: timeBase) != Int64.min
    }

    static let maxPlausibleIndexTicks = Double(SourceTimestampBounds.demuxedMagnitude)

    /// Seconds as ticks on `timeBase`, nil unless the result is finite and under 2^62 ticks (audit
    /// DMX-113, BIT-105). This is where every seconds-based reposition becomes an integer, and
    /// `Int64(_:)` traps on NaN, infinity and anything past `Int64`; every caller already treats a
    /// failed seek as one. Truncates like the plain conversion it replaces.
    nonisolated static func ticks(forSeconds seconds: Double, timeBase: AVRational) -> Int64? {
        guard timeBase.num > 0, timeBase.den > 0 else { return nil }
        let ticks = seconds * Double(timeBase.den) / Double(timeBase.num)
        guard ticks.isFinite, abs(ticks) < maxPlausibleIndexTicks else { return nil }
        return Int64(ticks)
    }

    nonisolated static let avTimeBase = AVRational(num: 1, den: AV_TIME_BASE)

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
    ///
    /// The result is clamped to `[0, MediaDurationCeiling.seconds]` (audit HLS-102): a corrupt header
    /// can state about 9.2e12 s, which the segment plan turned into a trapping tick conversion or a
    /// multi-terabyte reservation. Clamped rather than zeroed, so a slightly broken header still plays.
    static func effectiveDurationSeconds(
        declared: Double?, readerDuration: Double?, discTitle: Double?, container: Double
    ) -> Double {
        let resolved: Double
        if let declared, declared > 0 {
            resolved = declared
        } else if let readerDuration, readerDuration > 0 {
            resolved = readerDuration
        } else {
            resolved = effectiveDurationSeconds(discTitle: discTitle, container: container)
        }
        guard resolved.isFinite, resolved > 0 else { return 0 }
        return min(resolved, MediaDurationCeiling.seconds)
    }

    /// Open a media URL and probe its streams.
    /// - Parameters:
    ///   - extraHeaders: Attached to every HTTP request (ignored for file:// URLs).
    ///   - isLive: Suppresses EOF synthesis and surfaces terminal error on reconnect cap.
    func open(url: URL, extraHeaders: [String: String] = [:], profile: DemuxerOpenProfile = .playback, isLive: Bool = false, selectTitleID: Int? = nil) throws {
        if isCloseRequested { throw DemuxerError.openFailed(code: -1) }
        self.openProfile = profile
        beginOpenTiming()
        self.auditSource = isLive ? nil : (url, extraHeaders)
        let isHTTP = url.scheme == "http" || url.scheme == "https"

        if isHTTP {
            try openHTTP(url: url, extraHeaders: extraHeaders, isLive: isLive, selectTitleID: selectTitleID)
        } else {
            // Route a local DVD ISO through the disc adapter (FileIOReader keeps it
            // out of RAM). Falls back to the normal local open when not a disc.
            if url.isFileURL, let fileReader = FileIOReader(url: url),
               let discInfo = try DiscReader.wrap(fileReader, selectTitleID: selectTitleID, cacheKey: url.absoluteString) {
                adoptDiscInfo(discInfo)
                auditSource = nil
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
        reportOpenStage(.containerOpened)

        try probeStreams(openedCtx)
        accessLock.lock()
        refreshStreamTableLocked()
        accessLock.unlock()
        reportOpenStage(.streamsProbed)
    }

    /// Open a custom `IOReader` source. `formatHint` disambiguates probing when
    /// no filename is available. `isLive` suppresses SEEK_END that latches EOF
    /// on forward-only readers (38ad60b). AetherEngine#36: DiscReader adapts
    /// DVD/BD ISOs to VOB/MPEGTS concat streams unless the reader opts out via
    /// `discImageProbeEnabled`.
    func open(reader: IOReader, formatHint: String? = nil, profile: DemuxerOpenProfile = .playback, isLive: Bool = false, selectTitleID: Int? = nil, discCacheKey: String? = nil) throws {
        if isCloseRequested { throw DemuxerError.openFailed(code: -1) }
        self.openProfile = profile
        beginOpenTiming()
        self.auditSource = nil
        if reader.discImageProbeEnabled,
           let discInfo = try DiscReader.wrap(reader, selectTitleID: selectTitleID, cacheKey: discCacheKey) {
            adoptDiscInfo(discInfo)
            let bridge = CustomIOReaderBridge(reader: discInfo.reader, preservesSourcePosition: isLive)
            let inputFormat = av_find_input_format(discInfo.formatHint)
            try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
            return
        }
        let bridge = CustomIOReaderBridge(reader: reader, preservesSourcePosition: isLive)
        let inputFormat: UnsafePointer<AVInputFormat>? = formatHint.flatMap { av_find_input_format($0) }
        try openWithProvider(bridge, inputFormat: inputFormat, isLive: isLive)
    }

    /// A remote disc image (ISO 9660 / UDF / BDMV) by URL extension. Gates the HTTP disc-adapter
    /// path so a normal media URL keeps the optimized streaming AVIOReader open with no probe cost.
    /// [MovieClaw P4] 宿主也可以用 URL 片段 `#aether-disc-image` 声明「这是光盘镜像」：MovieClaw 的取流地址
    /// 是 `/playback/files/{id}/stream?token=…`，没有 .iso 后缀。片段只在本机，不随 HTTP 请求发出，
    /// 重新装载（选标题、换音轨）时随 URL 原样沿用。
    static func isDiscImageURL(_ url: URL) -> Bool {
        url.fragment == discImageFragment || ["iso", "img", "udf"].contains(url.pathExtension.lowercased())
    }

    /// [MovieClaw P4] 声明光盘镜像的 URL 片段
    public static let discImageFragment = "aether-disc-image"

    private func openHTTP(url: URL, extraHeaders: [String: String], isLive: Bool = false, selectTitleID: Int? = nil) throws {
        // A remote disc image goes through the same disc adapter as a local ISO (a raw .iso handed
        // straight to libavformat fails to probe; it is a filesystem, not a media container, #64).
        // Gated on the disc-image extension so normal media URLs skip the range-probe entirely; if
        // the source is not a recognizable disc, fall through to the streaming reader.
        if !isLive, Self.isDiscImageURL(url) {
            let warm = HTTPDiscIOReader.takePrewarm(for: url, extraHeaders: extraHeaders)
            if let discReader = try HTTPDiscIOReader.open(url: url, extraHeaders: extraHeaders, prewarmed: warm) {
                adoptOwnedSourceReader(discReader)
                if isCloseRequested {
                    releaseOwnedSourceReader()
                    throw DemuxerError.openFailed(code: -1)
                }
                let discInfo: DiscInfo?
                do {
                    discInfo = try DiscReader.wrap(discReader, selectTitleID: selectTitleID, cacheKey: url.absoluteString)
                } catch {
                    releaseOwnedSourceReader()
                    if let warm { SourcePrewarmStore.shared.store(warm, for: url) }
                    throw error
                }
                if let discInfo {
                    adoptDiscInfo(discInfo)
                    auditSource = nil
                    let bridge = CustomIOReaderBridge(reader: discInfo.reader)
                    let inputFormat = av_find_input_format(discInfo.formatHint)
                    do {
                        try openWithProvider(bridge, inputFormat: inputFormat, isLive: false)
                    } catch {
                        releaseOwnedSourceReader()
                        throw error
                    }
                    return
                }
                releaseOwnedSourceReader()
            }
            // Not a disc: hand the warm back so the streaming reader below adopts it (#647).
            if let warm { SourcePrewarmStore.shared.store(warm, for: url) }
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
            sequentialOnly: openProfile.avioSequentialOnly,
            heldConnection: openProfile.avioHeldConnection,
            expectsHeadPlayback: openProfile.playbackStartsAtHead,
            hostMatroskaCues: openProfile.hostMatroskaCues   // [MovieClaw P58]
        )
        reader.onNetworkPhaseChanged = onNetworkPhaseChanged
        reader.playIntentProvider = playIntentProvider
        try openWithProvider(reader, isLive: isLive)
    }

    /// A provider that connected (or tried to) for an open that is not going to finish.
    private func abandonProvider(_ provider: AVIOProvider) {
        provider.markClosed()
        provider.close()
        avioProvider = nil
    }

    /// Common AVIO open path. `inputFormat` forces a demuxer (custom sources with
    /// a format hint). `isLive` suppresses duration-estimate SEEK_END that latches
    /// EOF on unknown-length live sources.
    private func openWithProvider(
        _ provider: AVIOProvider,
        inputFormat: UnsafePointer<AVInputFormat>? = nil,
        isLive: Bool = false
    ) throws {
        // Audit DMX-102: the provider is published BEFORE it connects, under the same lock that
        // decides "already closed", so a `markClosed()` that lands during the connect (up to 15 s on
        // a live source, longer for a remote disc probe) reaches the provider instead of finding
        // nothing and leaving the open holding its origin slot.
        closeRequestLock.lock()
        let closedBeforeConnect = closeRequested
        if !closedBeforeConnect { avioProvider = provider }
        closeRequestLock.unlock()
        if closedBeforeConnect { throw DemuxerError.openFailed(code: -1) }
        do {
            try provider.open()
        } catch {
            abandonProvider(provider)
            throw error
        }
        if isCloseRequested {
            abandonProvider(provider)
            throw DemuxerError.openFailed(code: -1)
        }
        reportOpenStage(.sourceOpened)   // #361

        // AE#460 follow-up: a live source rebuilt on a RETAINED reader resumes where that reader
        // is, not at the host's base. A fresh AVIOContext starts its byte axis at 0 regardless, so
        // without this the rebuild reads the spool from the beginning: the playhead jumps back to
        // the join and the host is asked to re-deliver every byte it has already delivered
        // (measured on `customio --live`: playhead 41.5 s -> 1.9 s, 15 MB re-read). Aligning the
        // axis to the cursor makes the rebuild the edge rejoin the live contract already promises
        // on the URL branch. A first open has the cursor at 0 and takes no action; a reader that
        // will not report its position keeps the old behaviour and says so.
        switch LiveReopenAlignment.decision(
            isLive: isLive,
            isSeekable: provider.isSeekable,
            sourceSurvivesReopen: provider.sourceSurvivesReopen,
            currentSourceOffset: provider.currentSourceOffset
        ) {
        case .alignTo(let offset):
            let landed = avio_seek(provider.context, offset, SEEK_SET)
            // AE#460 round 3: the seek's own return says the reader ACCEPTED it, never that the
            // reader stayed put, so the reader is asked once more where it is. Aligning the axis
            // round-trips the reported cursor back through the host's `SEEK_SET`, which only leaves
            // the source untouched while its position report and its `SEEK_SET` argument are on the
            // same axis. One extra host callback, on live reopens only.
            switch LiveReopenAlignment.verify(
                requestedOffset: offset,
                avioLanded: landed,
                readerReportsAfter: provider.currentSourceOffset
            ) {
            case .aligned:
                EngineLog.emit(
                    "[Demuxer] live reopen aligned to the reader's cursor at \(offset) bytes",
                    category: .demux)
            case .seekRefused(let landed):
                EngineLog.emit(
                    "[Demuxer] live reopen could not align to \(offset) bytes (avio_seek -> \(landed))",
                    category: .demux)
            case .readerMovedUnderAlignment(let after):
                EngineLog.emit(
                    "[Demuxer] live reopen aligned the axis to \(offset) bytes, but the reader then "
                    + "reported \(after): its position report and its SEEK_SET argument are on "
                    + "different axes, so the source has been repositioned by the alignment "
                    + "(see docs/formats.md, custom byte sources)",
                    category: .demux)
            }
        case .cannotAlignReaderSilentOnPosition:
            EngineLog.emit(
                "[Demuxer] live reopen: the retained reader does not report its position, "
                + "so the source is read from its base",
                category: .demux
            )
        case .readFromCurrentPosition:
            break
        }

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
        // [MovieClaw P15] 光盘标题的时长 MPLS / IFO 里就有（`duration` 优先用它）：不再让 libavformat 从文件尾倒着
        // 一段段读去估时长——经 HTTP 读几十 GB 的镜像尾部，实测蓝光镜像开播前多出 10 来次请求
        Self.applyDemuxerOptions(&opts, isLive: isLive,
                                 skipDurationEstimate: openProfile.avioSequentialOnly
                                     || selectedDiscTitleDurationSeconds != nil)
        let ret = avformat_open_input(&ctxPtr, nil, inputFormat, &opts)
        av_dict_free(&opts)
        guard ret == 0 else {
            formatContext = nil
            avioProvider?.close()
            avioProvider = nil
            throw DemuxerError.openFailed(code: ret)
        }
        formatContext = ctxPtr  // avformat_open_input may reallocate
        reportOpenStage(.containerOpened)   // #361
        declareDiscSubpictureStreams(ctxPtr!)

        try probeStreams(ctxPtr!)
        accessLock.lock()
        refreshStreamTableLocked()
        accessLock.unlock()
        reportOpenStage(.streamsProbed)     // #361
        // #281: every parse seek this open performs has happened by now, so the provider can drop
        // the cold-start state that only exists to serve them. Deliberately after probeStreams:
        // find_stream_info is where the trailing-index ping-pong lives, not avformat_open_input.
        avioProvider?.markOpenPhaseFinished()
    }

    /// AE#585: bracket the host's bounded index pass (the cue prewarm and the cursor reset that
    /// follows it), so a provider holding cold-start state does not release it to a read that is
    /// index work and is followed immediately by a read at the position it started from.
    func beginIndexPass() { avioProvider?.beginIndexPass() }

    /// AE#585: ends the bracket above. Safe to call without a matching `beginIndexPass`.
    func endIndexPass() { avioProvider?.endIndexPass() }

    /// Default 5 MB/5s budgets miss sparse PGS/DVB tracks on 10-20 GB Blu-ray rips.
    /// 50 MB/60 s ensures codec params are populated without noticeably slowing open.
    private func applyProbeBudget(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        ctx.pointee.probesize = openProfile.probesize
        ctx.pointee.max_analyze_duration = openProfile.maxAnalyzeDuration
        // Installed unconditionally: a local input's URLContext copies the callback at open, so the
        // input byte budget could not reach it later.
        ctx.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { opaque in
                guard let opaque else { return 0 }
                return Unmanaged<DemuxInterrupt>.fromOpaque(opaque).takeUnretainedValue()
                    .shouldInterrupt() ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(interrupt).toOpaque())
    }

    /// #651: the probe budget of a DVD title whose IFO declared its streams.
    ///
    /// MPEG-PS sets `AVFMTCTX_NOHEADER` and never clears it, so `find_stream_info` never takes its
    /// "all info found" exit and reads the whole budget on every open: 50 MB, most of a first frame on
    /// a remote ISO. The long window only ever existed to discover streams that start late, and on a
    /// DVD those are the subpictures, which the IFO has already declared. What is left to resolve is
    /// the continuous streams (MPEG-2 video's rate, the audio's parameters), which a few seconds give.
    static let declaredDiscTitleProbesize: Int64 = 8 * 1024 * 1024
    static let declaredDiscTitleMaxAnalyzeDuration: Int64 = 5 * 1_000_000

    /// #651: create the subpicture streams the selected DVD title's IFO declares, before anything is
    /// read. `mpegps` looks a packet's stream up by `AVStream.id` before it creates one, so these
    /// receive their packets exactly as if the demuxer had made them on the first one, and a subtitle
    /// whose first packet is minutes in is a track from the first frame. Mirrors what `mpegps` sets
    /// on a stream it creates, apart from `need_parsing`, which is internal: `dvdsubdec` reassembles
    /// a subpicture split across packets itself.
    private func declareDiscSubpictureStreams(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard let ids = discSubpictureStreamIDs, !ids.isEmpty,
              let name = ctx.pointee.iformat?.pointee.name, String(cString: name) == "mpeg" else { return }
        var existing = Set<Int32>()
        for i in 0..<Int(ctx.pointee.nb_streams) {
            if let stream = ctx.pointee.streams[i] { existing.insert(stream.pointee.id) }
        }
        var declared = 0
        for id in ids where !existing.contains(Int32(id)) {
            guard let stream = avformat_new_stream(ctx, nil), let codecpar = stream.pointee.codecpar else { break }
            stream.pointee.id = Int32(id)
            subpictureAssemblers[stream.pointee.index] = DVDSubpictureAssembler()
            stream.pointee.time_base = AVRational(num: 1, den: 90000)
            stream.pointee.pts_wrap_bits = 64
            codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            codecpar.pointee.codec_id = AV_CODEC_ID_DVD_SUBTITLE
            declared += 1
        }
        if declared > 0 {
            EngineLog.emit("[Demuxer] declared \(declared) DVD subpicture stream(s) from the IFO (#651)",
                           category: .demux)
        }
    }

    /// #651: shrink the probe to `declaredDiscTitle*` once the IFO has declared the title's streams.
    /// Never raises a budget: a tighter caller budget (#68) still wins.
    private func boundProbeForDeclaredDiscTitle(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        guard discSubpictureStreamIDs != nil,
              let name = ctx.pointee.iformat?.pointee.name, String(cString: name) == "mpeg" else { return }
        ctx.pointee.probesize = min(ctx.pointee.probesize, Self.declaredDiscTitleProbesize)
        ctx.pointee.max_analyze_duration = min(ctx.pointee.max_analyze_duration,
                                               Self.declaredDiscTitleMaxAnalyzeDuration)
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
        unresolvableAudioStreams = []
        // #87: the subtitle side demuxer opts out of find_stream_info. avformat_open_input already
        // carries codec_id / codec_type for every subtitle track (container header / PMT), and
        // reclassifyAttachedPictures only exists to bound the find_stream_info cost, so both are skipped.
        // The reader runs `resolveStreamInfo()` on demand if its target stream's codec is unresolved.
        guard !openProfile.skipStreamInfo else {
            logStreams(ctx)
            detectIndexlessMatroska(ctx)  // [MovieClaw P18]
            return
        }
        reclassifyAttachedPictures(ctx)
        boundProbeForDeclaredDiscTitle(ctx)
        let parked = parkUnresolvableAudio(ctx)
        let parkedPGS = parkUnsizedPGS(ctx)  // [MovieClaw P12]
        // [MovieClaw] 探测流的耗时与读量：起播分段里「探测」一段慢在读数据还是慢在解码，看这一行
        let probeStarted = DispatchTime.now()
        let bytesBefore = ctx.pointee.pb?.pointee.bytes_read ?? 0
        let findRet = avformat_find_stream_info(ctx, nil)
        let probeMs = Double(DispatchTime.now().uptimeNanoseconds - probeStarted.uptimeNanoseconds) / 1_000_000
        let bytesRead = (ctx.pointee.pb?.pointee.bytes_read ?? 0) - bytesBefore
        EngineLog.emit(
            "[Demuxer] [MovieClaw] find_stream_info took \(Int(probeMs))ms, read \(bytesRead / 1024) KB "
            + "(fps_probe_size=\(ctx.pointee.fps_probe_size))",
            category: .demux)
        unparkUnsizedPGS(ctx, parkedPGS)
        unparkUnresolvableAudio(ctx, parked)
        guard findRet >= 0 else {
            emitOpenTimings(outcome: "find_stream_info failed (\(findRet))")
            throw DemuxerError.streamInfoFailed(code: findRet)
        }
        logStreams(ctx)
        pairDolbyVisionDualPID(ctx)  // [MovieClaw P9]
        detectIndexlessMatroska(ctx)  // [MovieClaw P18]
        // [MovieClaw P13] DVD 按 cell 折叠：cell 0 的时间戳基准就是流的起始时间（引擎的源时间轴也以它为原点），
        // 续播直接落在后面的 cell 时也有基准可折
        if dvdCellFold, clipBase0Sec.isNaN, ctx.pointee.start_time != Int64.min {
            clipBase0Sec = Double(ctx.pointee.start_time) / Double(AV_TIME_BASE)
        }
        armGeneratedPTSSuppression(ctx)
        if openProfile.auditsRecordlessDolbyVision, let source = auditSource {
            let idx = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
            if idx >= 0, let codecpar = ctx.pointee.streams[Int(idx)]?.pointee.codecpar {
                DolbyVisionRecordAudit.addRecordIfProfile5(
                    codecpar: codecpar, url: source.url, extraHeaders: source.headers)
            }
        }
    }

    /// An audio stream this build can never resolve, named so a report can say why a source came up
    /// without sound. Recorded per open by `parkUnresolvableAudio`. (#466)
    struct UnresolvableAudioStream: Equatable, Sendable {
        let index: Int
        /// Lower-case libavcodec name, e.g. "ac4".
        let codec: String
    }

    /// Audio streams parked out of the way of the most recent `find_stream_info`. (#466)
    private(set) var unresolvableAudioStreams: [UnresolvableAudioStream] = []

    /// Whether `find_stream_info` can ever resolve this audio stream in THIS build, given what the
    /// container already declared. (#466)
    ///
    /// `has_codec_parameters` fails an audio stream with no sample rate or no channel count, and both
    /// can only arrive from the container or from opening a decoder. With no decoder compiled in,
    /// `try_decode_frame` gives up on the first packet (`found_decoder` goes negative) and the outer
    /// loop keeps reading anyway, because its only exit is every stream satisfying
    /// `has_codec_parameters`. One such stream therefore costs the whole probe budget, and on a live
    /// source that budget is spent at the wire rate (#466, Sodalite#100: an ATSC 3.0 channel whose
    /// audio is AC-4, most of a minute of tuning indicator and then a silent fail-open).
    ///
    /// Three deliberate exclusions. `AV_CODEC_ID_NONE` is a stream still being identified, which is
    /// what the probe is for. A codec whose parameters the container already carries is never chased,
    /// so it is none of this decision's business. And video is out of scope: the native path decodes
    /// formats libavcodec was not built with (ProRes is the standing example), while every container
    /// that describes a video stream at all carries its size, so the case does not arise.
    static func audioCannotResolve(
        codecID: AVCodecID, codecType: AVMediaType, sampleRate: Int32, channels: Int32
    ) -> Bool {
        guard codecType == AVMEDIA_TYPE_AUDIO, codecID != AV_CODEC_ID_NONE else { return false }
        guard sampleRate == 0 || channels == 0 else { return false }
        return avcodec_find_decoder(codecID) == nil
    }

    /// Reclassify audio streams that can never resolve to ATTACHMENT for the duration of the probe,
    /// the same lever `reclassifyAttachedPictures` uses: `has_codec_parameters` asks nothing of an
    /// ATTACHMENT stream, so the pass can take its "all info found" exit as soon as the real streams
    /// are known. (#466)
    ///
    /// Parked FOR the probe, not permanently, because the stream is not an attachment and every
    /// consumer downstream is entitled to see it. `find_stream_info` writes its internal context back
    /// over `codecpar` on the way out, so the restore has to follow it rather than being skipped as
    /// redundant. What the caller ends up with is exactly the state a full-budget probe would have
    /// left (audio stream present, parameters unresolved), reached without paying for it.
    private func parkUnresolvableAudio(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> [Int] {
        var parked: [Int] = []
        var found: [UnresolvableAudioStream] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  Self.audioCannotResolve(codecID: codecpar.pointee.codec_id,
                                          codecType: codecpar.pointee.codec_type,
                                          sampleRate: codecpar.pointee.sample_rate,
                                          channels: codecpar.pointee.ch_layout.nb_channels)
            else { continue }
            found.append(UnresolvableAudioStream(
                index: i, codec: String(cString: avcodec_get_name(codecpar.pointee.codec_id))))
            codecpar.pointee.codec_type = AVMEDIA_TYPE_ATTACHMENT
            parked.append(i)
        }
        unresolvableAudioStreams = found
        if !found.isEmpty {
            let listed = found.map { "\($0.index)=\($0.codec)" }.joined(separator: " ")
            EngineLog.emit(
                "[Demuxer] no decoder for audio stream(s) \(listed); not probed, source plays without them",
                category: .demux)
        }
        return parked
    }

    private func unparkUnresolvableAudio(_ ctx: UnsafeMutablePointer<AVFormatContext>, _ parked: [Int]) {
        for i in parked where i < Int(ctx.pointee.nb_streams) {
            ctx.pointee.streams[i]?.pointee.codecpar?.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        }
    }

    /// [MovieClaw P12] PGS 字幕流在 find_stream_info 期间暂时当附件（同 `parkUnresolvableAudio` 的做法），探测完原样放回。
    ///
    /// libavformat 认定 PGS 流「参数不全」直到知道画布尺寸（has_codec_parameters：unspecified size），而容器头里没有这个
    /// 尺寸、字幕包又稀疏，探测于是一直读到预算上限（50 MB）。真机实测带 PGS 的片子起播里「探测流」一项 0.6～1.1 秒，
    /// 同样是 DTS 转码、不带 PGS 的《九门》只要 0.00 秒；蓝光原盘几乎都带 PGS。引擎画 PGS 时画布尺寸取自画面
    /// （旁路读字幕的解复用器本来就不跑 find_stream_info），用不上这里探出来的尺寸
    private func parkUnsizedPGS(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> [(index: Int, type: AVMediaType, placeholderCodec: Bool)] {
        var parked: [(index: Int, type: AVMediaType, placeholderCodec: Bool)] = []
        var sawTrueHD = false
        let formatName = ctx.pointee.iformat.map { String(cString: $0.pointee.name) } ?? ""
        let declaresCodecs = formatName.hasPrefix("mov,") || formatName.hasPrefix("matroska")
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let codecpar = ctx.pointee.streams[i]?.pointee.codecpar else { continue }
            let type = codecpar.pointee.codec_type
            let unsizedPGS = type == AVMEDIA_TYPE_SUBTITLE && codecpar.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
                && codecpar.pointee.width == 0
            // 认不出编码的数据流（广播录像里的 DSM-CC 数据轮播，stream_type 0x0D）同样永远「参数不全」：
            // 真机日本电视台录像《再见我们的幼儿园》探测 0.79 秒就耗在这两路上。引擎从不读它们
            let unknownData = (type == AVMEDIA_TYPE_DATA || type == AVMEDIA_TYPE_UNKNOWN)
                && codecpar.pointee.codec_id == AV_CODEC_ID_NONE
            // MP4 / MKV 由容器声明编码，认不出就是真没有解码器（国产 4K 剧的 Audio Vivid「av3a」5.1.4 音轨）：
            // 同样判「参数不全」拖满探测预算，真机《交锋》探测 1.5 秒。TS / PS 的未知流可能靠嗅探认出来，不动
            let unknownAudio = declaresCodecs && type == AVMEDIA_TYPE_AUDIO && codecpar.pointee.codec_id == AV_CODEC_ID_NONE
            // [MovieClaw P34] 第二条起的 TrueHD：容器已声明采样率与声道，探测只差「采样格式」一项，要解出一帧才有；
            // 解不出来（真机《变形金刚4》第二条 TrueHD）就读满 50 MB 预算，探测 0.76 秒。TrueHD 一律经音频桥接，
            // 桥接自己开解码器、按解出的帧配重采样，用不上探出来的采样格式。第一条照常探（全景声等判定不受影响）
            let isTrueHD = declaresCodecs && type == AVMEDIA_TYPE_AUDIO && codecpar.pointee.codec_id == AV_CODEC_ID_TRUEHD
                && codecpar.pointee.sample_rate > 0 && codecpar.pointee.ch_layout.nb_channels > 0
            let secondaryTrueHD = isTrueHD && sawTrueHD && AetherEngine.parkSecondaryTrueHDDuringProbe
            if isTrueHD { sawTrueHD = true }
            guard unsizedPGS || unknownData || unknownAudio || secondaryTrueHD else { continue }
            codecpar.pointee.codec_type = AVMEDIA_TYPE_ATTACHMENT
            // 编码号为 NONE 的流不论什么类型都判「参数不全」（unknown codec），探测期间给个占位的二进制数据编码号
            if unknownData || unknownAudio { codecpar.pointee.codec_id = AV_CODEC_ID_BIN_DATA }
            parked.append((i, type, unknownData || unknownAudio))
        }
        if !parked.isEmpty {
            EngineLog.emit("[Demuxer] [MovieClaw P12/P34] \(parked.count) PGS / unknown data / unknown audio / secondary TrueHD stream(s) held out of find_stream_info", category: .demux)
        }
        return parked
    }

    private func unparkUnsizedPGS(_ ctx: UnsafeMutablePointer<AVFormatContext>,
                                  _ parked: [(index: Int, type: AVMediaType, placeholderCodec: Bool)]) {
        for (i, type, placeholderCodec) in parked where i < Int(ctx.pointee.nb_streams) {
            guard let codecpar = ctx.pointee.streams[i]?.pointee.codecpar else { continue }
            codecpar.pointee.codec_type = type
            if placeholderCodec { codecpar.pointee.codec_id = AV_CODEC_ID_NONE }
        }
    }

    /// #407: find the video streams whose PTS `+genpts` is inventing out of decode order, so
    /// `readPacketLocked` can clear it and leave the axis to the decoder's own reorder. Needs the
    /// stream parameters `avformat_find_stream_info` fills in, hence the call site right below it.
    /// See `VFWDecodeOrderPTSRepair` for why the gate is an equivalence rather than a heuristic.
    private func armGeneratedPTSSuppression(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        generatedPTSStreams.removeAll()
        guard let nameC = ctx.pointee.iformat?.pointee.name else { return }
        let formatName = String(cString: nameC)
        guard VFWDecodeOrderPTSRepair.containerWithholdsPTS(formatName) else { return }
        for index in 0..<Int32(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[Int(index)],
                  let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            let shape = VFWDecodeOrderPTSRepair.StreamShape(
                codecTag: par.pointee.codec_tag,
                videoDelay: par.pointee.video_delay,
                codecID: par.pointee.codec_id
            )
            guard VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(formatName: formatName, shape: shape)
            else { continue }
            generatedPTSStreams.insert(index)
            EngineLog.emit(
                "[Demuxer] AE#407 stream=\(index) in \(formatName) is FourCC-carried "
                + "(tag=\(fourCC(par.pointee.codec_tag)) "
                + "videoDelay=\(par.pointee.video_delay)); the container carries no PTS, so the "
                + "+genpts axis is decode order. Clearing PTS, the decoder's reorder owns presentation.",
                category: .demux
            )
        }
    }

    /// A `codec_tag` printed the way the VFW header spells it, for the diagnostic above.
    private func fourCC(_ tag: UInt32) -> String {
        let bytes = [tag, tag >> 8, tag >> 16, tag >> 24].map { UInt8($0 & 0xFF) }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.allSatisfy { $0.isASCII && !$0.isNewline && $0 != "\0" }
            ? text
            : String(format: "0x%08X", tag)
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
        refreshStreamTableLocked(rebuildTracks: true)
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

    /// [MovieClaw P37] 平均码率：容器声明了就用它，没声明（原盘 / 光盘镜像的 MPEG-TS 时长是 NOPTS、bit_rate 为 0）
    /// 按片源总字节 × 8 ÷ 时长估。宿主拿它填 HLS 的 BANDWIDTH：原来这时兜底 25 Mbit/s、峰值声明 50 Mbit/s，
    /// UHD 原盘一段 2 秒 12～15 MB（约 60 Mbit/s）超出声明，真机 AVPlayer 报 -12318 后只放声音不出画面（《黑豹2》续播 20 秒无画）
    func estimatedBitRate(durationSeconds: Double) -> Int64 {
        let declared = bitRate
        if declared > 0 { return declared }
        let size: Int64? = {
            accessLock.lock()
            defer { accessLock.unlock() }
            return avioProvider?.resolvedByteSize
        }()
        guard let size, size > 0, durationSeconds > 0 else { return 0 }
        return Int64(Double(size) * 8 / durationSeconds)
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
        answeredFromStreams(\.videoStreamIndex) { Self.bestStreamIndex($0, AVMEDIA_TYPE_VIDEO) }
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
        answeredFromStreams(\.audioStreamIndex) { firstLanguageAudioIndex($0, best: Self.bestStreamIndex($0, AVMEDIA_TYPE_AUDIO)) }
    }

    /// [MovieClaw P10] 没有一条音轨标了默认（蓝光 / DVD / TS 都不标）时，av_find_best_stream 按帧数、码率挑，
    /// 常常挑到配音轨：真机《怦然心动》蓝光镜像起播放的是西班牙语 AC-3，第一条是英语 DTS。光盘按作者排定的
    /// 顺序列音轨，第一条就是正片原声，所以语言以第一条为准；同语言里仍信 FFmpeg 的挑选（TrueHD 与它内嵌的
    /// AC-3 核心之间挑哪条，对用户几乎没区别）。服务端的默认音轨同样是「标了默认的，否则第一条」
    /// （decide.py `_preferred_audio`），两边因此一致，App 起播后也就不必为换语言再重载一次
    private func firstLanguageAudioIndex(_ ctx: UnsafeMutablePointer<AVFormatContext>, best: Int32) -> Int32 {
        guard best >= 0 else { return best }
        var audio: [(index: Int32, language: String?, codec: AVCodecID)] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i], let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            if (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0 { return best }
            let language = Self.resolvedLanguage(declared: metadataValue(stream.pointee.metadata, key: "language"),
                                                  streamID: stream.pointee.id, discLanguages: discStreamLanguages)
            audio.append((Int32(i), Self.isUndeterminedLanguage(language) ? nil : language?.lowercased(), par.pointee.codec_id))
        }
        guard let first = audio.first?.language, let picked = audio.first(where: { $0.index == best }),
              let pickedLanguage = picked.language, pickedLanguage != first else { return best }
        let sameLanguage = audio.filter { $0.language == first }
        // 同语言里优先 AVPlayer 能原样拷贝的编码（免本机转码），否则第一条
        let copyable: Set<AVCodecID> = [AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_AAC]
        let chosen = sameLanguage.first(where: { copyable.contains($0.codec) }) ?? sameLanguage[0]
        EngineLog.emit("[Demuxer] [MovieClaw P10] default audio: best stream #\(best) is \(pickedLanguage), "
                       + "first track is \(first); using #\(chosen.index)", category: .demux)
        return chosen.index
    }

    /// First audio stream by codec_type regardless of codecpar completeness.
    /// Fallback for live MPEG-TS where av_find_best_stream skips empty-codecpar
    /// streams; the engine's live AAC codecpar repair fills them downstream.
    var firstAudioStreamIndexByType: Int32 {
        answeredFromStreams(\.firstAudioStreamIndexByType) { Self.firstAudioStreamIndexByType($0) }
    }

    func audioTrackInfos() -> [TrackInfo] {
        answeredFromStreams(\.audioTracks) { trackInfos(in: $0, ofType: AVMEDIA_TYPE_AUDIO) }
    }

    func subtitleTrackInfos() -> [TrackInfo] {
        answeredFromStreams(\.subtitleTracks) { trackInfos(in: $0, ofType: AVMEDIA_TYPE_SUBTITLE) }
    }

    /// Runs `compute` over the live format context under `accessLock` when the lock is free, and
    /// remembers the answer; answers from the last snapshot when a read holds it (audit DMX-108).
    /// `try`, not `lock`, for the reason `stream(at:)` gives: a caller on the main actor must not
    /// wait out a network read.
    private func answeredFromStreams<T>(
        _ field: WritableKeyPath<TrackSnapshot, T>,
        _ compute: (UnsafeMutablePointer<AVFormatContext>) -> T
    ) -> T {
        if accessLock.try() {
            defer { accessLock.unlock() }
            let answer = formatContext.map(compute) ?? TrackSnapshot()[keyPath: field]
            streamTableLock.lock()
            trackSnapshot[keyPath: field] = answer
            streamTableLock.unlock()
            return answer
        }
        streamTableLock.lock()
        defer { streamTableLock.unlock() }
        return trackSnapshot[keyPath: field]
    }

    private static func bestStreamIndex(_ ctx: UnsafeMutablePointer<AVFormatContext>,
                                        _ type: AVMediaType) -> Int32 {
        max(-1, av_find_best_stream(ctx, type, -1, -1, nil, 0))
    }

    private static func firstAudioStreamIndexByType(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> Int32 {
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            return Int32(i)
        }
        return -1
    }

    private func trackInfos(in ctx: UnsafeMutablePointer<AVFormatContext>,
                            ofType type: AVMediaType) -> [TrackInfo] {
        var tracks: [TrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == type else { continue }
            tracks.append(trackInfo(from: stream, index: i))
        }
        return tracks
    }

    private static func subtitleStreamIndices(in ctx: UnsafeMutablePointer<AVFormatContext>) -> Set<Int32> {
        var indices: Set<Int32> = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[i],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            indices.insert(Int32(i))
        }
        return indices
    }

    private static func splitDisplaySetSubtitleStreamIndices(
        in ctx: UnsafeMutablePointer<AVFormatContext>
    ) -> Set<Int32> {
        guard let formatName = ctx.pointee.iformat?.pointee.name,
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

    /// Caller holds `accessLock`.
    private func buildTrackSnapshotLocked() -> TrackSnapshot {
        guard let ctx = formatContext else { return TrackSnapshot() }
        return TrackSnapshot(
            videoStreamIndex: Self.bestStreamIndex(ctx, AVMEDIA_TYPE_VIDEO),
            audioStreamIndex: firstLanguageAudioIndex(ctx, best: Self.bestStreamIndex(ctx, AVMEDIA_TYPE_AUDIO)),
            firstAudioStreamIndexByType: Self.firstAudioStreamIndexByType(ctx),
            audioTracks: trackInfos(in: ctx, ofType: AVMEDIA_TYPE_AUDIO),
            subtitleTracks: trackInfos(in: ctx, ofType: AVMEDIA_TYPE_SUBTITLE),
            subtitleStreamIndices: Self.subtitleStreamIndices(in: ctx),
            splitDisplaySetSubtitleStreamIndices: Self.splitDisplaySetSubtitleStreamIndices(in: ctx))
    }

    /// #112: PGS subtitle streams whose display sets arrive split across PES packets and need
    /// reassembly in the SubtitlePacketStore. Only the MPEG-TS demuxer splits them (Blu-ray
    /// authoring: PCS|WDS|PDS|ODS|END as separate PES packets, some without a PTS); Matroska
    /// carries one complete set per packet and must NOT be assembled (converters there strip
    /// the trailing END, which the decoder's synthetic-END flush rescues per packet).
    /// #151: every AVMEDIA_TYPE_SUBTITLE stream index; the forward prefetcher's route + keep set.
    func subtitleStreamIndices() -> Set<Int32> {
        answeredFromStreams(\.subtitleStreamIndices) { Self.subtitleStreamIndices(in: $0) }
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
        answeredFromStreams(\.splitDisplaySetSubtitleStreamIndices) {
            Self.splitDisplaySetSubtitleStreamIndices(in: $0)
        }
    }

    /// Load-time only (the probe demuxer has no reader yet), so it takes `accessLock` outright
    /// rather than answering from a snapshot: it reads the attached picture's bytes.
    func mediaMetadata() -> MediaMetadata {
        accessLock.lock()
        defer { accessLock.unlock() }
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

        let language = Self.resolvedLanguage(
            declared: metadataValue(stream.pointee.metadata, key: "language"),
            streamID: stream.pointee.id,
            discLanguages: discStreamLanguages
        )
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
        let isAudio = codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
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
            assHeader: assHeader,
            sampleRate: isAudio ? Int(codecpar.pointee.sample_rate) : 0,
            bitsPerSample: isAudio ? Int(max(codecpar.pointee.bits_per_raw_sample, 0)) : 0,
            sampleFormat: isAudio ? Self.sampleFormatName(codecpar.pointee.format) : nil,
            channelLayout: isAudio ? Self.channelLayoutDescription(&codecpar.pointee.ch_layout) : nil,
            profile: VideoStreamFormat.profileName(codecID: codecID, profile: codecpar.pointee.profile)
        )
    }

    static func sampleFormatName(_ raw: Int32) -> String? {
        let fmt = AVSampleFormat(rawValue: raw)
        guard fmt != AV_SAMPLE_FMT_NONE else { return nil }
        return av_get_sample_fmt_name(fmt).map { String(cString: $0) }
    }

    static func channelLayoutDescription(_ layout: UnsafePointer<AVChannelLayout>) -> String? {
        guard layout.pointee.nb_channels > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 64)
        guard av_channel_layout_describe(layout, &buffer, buffer.count) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The language to publish for a stream. A disc keeps its track languages in its navigation data
    /// rather than in the streams, so an m2ts / VOB demuxed on its own reports every track as
    /// undetermined and no preferred-language selection can match. `discLanguages` (empty for every
    /// non-disc source) fills those in, keyed by the stream's container id. A language the container
    /// actually declared always wins: the disc tables describe the authored title, the stream describes
    /// itself (#527).
    static func resolvedLanguage(declared: String?, streamID: Int32,
                                 discLanguages: [Int: String]) -> String? {
        guard isUndeterminedLanguage(declared) else { return declared }
        return discLanguages[Int(streamID)] ?? declared
    }

    /// True for a container language that names no language: absent, empty, or the ISO 639-2
    /// "undetermined" code. This is what every Blu-ray and DVD track reports, since neither format
    /// carries the language in the stream (#527).
    static func isUndeterminedLanguage(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(),
              !value.isEmpty else { return true }
        return value == "und" || value == "undetermined"
    }

    /// MKV font attachments. Payload in codec extradata; filename/MIME in stream metadata.
    /// Non-font attachments filtered by isFontPayload.
    func fontAttachmentInfos() -> [FontAttachment] {
        accessLock.lock()
        defer { accessLock.unlock() }
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
        guard index >= 0 else { return nil }
        // `try`, not `lock`: a read can hold `accessLock` for a whole network stall, and a caller
        // on the main actor must not wait that out. The table a busy read leaves behind is current
        // anyway, since `readPacketLocked` refreshes it whenever a read adds a stream.
        if accessLock.try() {
            refreshStreamTableLocked()
            accessLock.unlock()
        }
        streamTableLock.lock()
        defer { streamTableLock.unlock() }
        return Int(index) < streamTable.count ? streamTable[Int(index)] : nil
    }

    /// Caller holds `accessLock`. The track snapshot is rebuilt when the stream count changed, when
    /// the context is gone, and when the caller says codec parameters moved under an unchanged count
    /// (`rebuildTracks`, after a `find_stream_info`).
    private func refreshStreamTableLocked(rebuildTracks: Bool = false) {
        var table: [UnsafeMutablePointer<AVStream>] = []
        if let ctx = formatContext, let streams = ctx.pointee.streams {
            let count = Int(ctx.pointee.nb_streams)
            table.reserveCapacity(count)
            for i in 0..<count {
                guard let stream = streams[i] else { break }
                table.append(stream)
            }
        }
        let snapshot = (rebuildTracks || table.count != streamTableSize || formatContext == nil)
            ? buildTrackSnapshotLocked() : nil
        streamTableSize = table.count
        streamTableLock.lock()
        streamTable = table
        if let snapshot { trackSnapshot = snapshot }
        streamTableLock.unlock()
    }

    /// The stream at `index`, for the length of `body` only (audit DMX-108). `stream(at:)` hands out
    /// a raw `AVStream*`, and a live reopen's `close()` frees every stream the moment it runs, so a
    /// caller on another thread that holds one across that point reads freed memory. A caller in
    /// here is counted, `close()` waits for the count to drain before it frees anything, and once
    /// `close()` has started no new caller gets a stream. Never waits on `accessLock`, so it cannot
    /// wait out a network read either. `body` must be short and must not call back into the demuxer.
    func withStream<T>(at index: Int32, _ body: (UnsafeMutablePointer<AVStream>) -> T) -> T? {
        guard index >= 0 else { return nil }
        streamTableLock.lock()
        guard Int(index) < streamTable.count else {
            streamTableLock.unlock()
            return nil
        }
        let stream = streamTable[Int(index)]
        streamUsers += 1
        streamTableLock.unlock()
        defer {
            streamTableLock.lock()
            streamUsers -= 1
            if streamUsers == 0 { streamTableLock.broadcast() }
            streamTableLock.unlock()
        }
        return body(stream)
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
            if keep.contains(i) || (i == dvEnhancementStream && keep.contains(dvBaseLayerStream)) {
                // [MovieClaw P9] 增强层要读：它的 RPU 挂到基础层上
                stream.pointee.discard = AVDISCARD_DEFAULT
            } else if dvdCellFold, stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_DVD_NAV {
                // [MovieClaw P13] DVD 导航包要读：cell 的时间戳基准从它算，读完即丢、不往下游送
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
        let compositionOffset = compositionRepair?.decodeTimestampOffset
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
        for i in 0..<count {
            // AVINDEX_KEYFRAME = 0x0001. Fold each entry onto the contiguous timeline (multi-clip disc)
            // so the segment plan built from these IRAP positions matches the normalized packets
            // (AE#105), then onto the repaired decode ladder if #409 moved it.
            guard let entry = avformat_index_get_entry(stream, i),
                  entry.pointee.flags & 0x0001 != 0,
                  Self.isPlausibleIndexTimestamp(entry.pointee.timestamp, timeBase: tb),
                  let folded = normalizedTimestamp(entry.pointee.timestamp, pos: entry.pointee.pos, timeBase: tb),
                  let placed = Self.offsetIndexTimestamp(folded, by: compositionOffset)
            else { continue }
            result.append(placed)
        }
        return result
    }

    func readPacket(isCurrent: @Sendable () -> Bool = { true }) throws -> UnsafeMutablePointer<AVPacket>? {
        accessLock.lock()
        defer { accessLock.unlock() }
        if !peekedPackets.isEmpty {
            guard isCurrent() else { throw CancellationError() }
            return peekedPackets.removeFirst()
        }
        return try readPipelinePacketLocked(isCurrent: isCurrent)
    }

    /// Shows the packets at the read position to `inspect`, in order, WITHOUT consuming them: what it
    /// looked at is held and the next `readPacket()` calls return it first (audit HLS-103). For a source
    /// that cannot rewind, where a probe that reads packets and seeks back has nothing to seek back
    /// with. `inspect` returns true once it has seen enough. Stops at `maxPackets` held, at the end of
    /// the source, or on a read error, which is thrown with the packets read so far still held.
    func peekPackets(maxPackets: Int,
                     _ inspect: (UnsafeMutablePointer<AVPacket>) -> Bool) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        var index = 0
        while index < maxPackets {
            if index == peekedPackets.count {
                guard let packet = try readPipelinePacketLocked() else { return }
                peekedPackets.append(packet)
            }
            if inspect(peekedPackets[index]) { return }
            index += 1
        }
    }

    /// Caller holds `accessLock`.
    private func dropPeekedPacketsLocked() {
        for held in peekedPackets {
            var packet: UnsafeMutablePointer<AVPacket>? = held
            trackedPacketFree(&packet)
        }
        peekedPackets.removeAll()
    }

    /// One packet through the demuxer's own pipeline, bypassing the peek queue. Caller holds `accessLock`.
    private func readPipelinePacketLocked(isCurrent: @Sendable () -> Bool = { true }) throws -> UnsafeMutablePointer<AVPacket>? {
        while true {
            // A read-ahead decision made before a seek cannot start a NEW-position read after
            // the seek releases this lock, then throw that first new packet away as stale.
            guard isCurrent() else { throw CancellationError() }
            // #409: a packet the repair held during its sampling window is handed back before any
            // new read, so the container's own order survives the verdict. Checked every pass, not
            // once on entry: the packet that completes the sample flips the phase, and the queue
            // behind it has to drain before the read that follows it is emitted.
            // Every exit is bounded again: #409 rewrites pts/dts after the funnel in
            // `readDemuxedPacketLocked`, with wrapping arithmetic.
            if let held = compositionRepair?.dequeue() { return boundTimestampsLocked(held) }
            guard let packet = try readPacketLocked() else {
                // EOF can arrive mid-sample on a very short source; the verdict has to be reached
                // now or the held packets would never be delivered.
                compositionRepair?.endOfStream()
                if let held = compositionRepair?.dequeue() { return boundTimestampsLocked(held) }
                return nil
            }
            guard let repair = armCompositionRepairIfNeeded() else { return boundTimestampsLocked(packet) }
            if !repair.ingest(packet) { return boundTimestampsLocked(packet) }
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
    private func armCompositionRepairIfNeeded() -> (any H264TimestampRepairSession)? {
        if compositionRepairEvaluated { return compositionRepair }
        compositionRepairEvaluated = true
        guard let ctx = formatContext else { return nil }
        // Three sources pay a sample they have no use for: a still extraction decodes one keyframe
        // per open and publishes no axis, a demuxer whose video is discarded (the subtitle side
        // reader, #104) has no pictures to sample at all, and a non-seekable source is a live feed,
        // where holding a dozen packets for a defect that lives in a VOD sample table is latency
        // spent for nothing.
        guard !DemuxerOpenProfile.labelsWithoutCompositionRepair.contains(openProfile.readerLabel),
              isSourceSeekable else { return nil }
        let index = max(-1, av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        guard index >= 0, index < Int32(ctx.pointee.nb_streams),
              let stream = ctx.pointee.streams[Int(index)] else { return nil }
        guard stream.pointee.discard != AVDISCARD_ALL else { return nil }
        // #511: the same defect on a container that never had composition offsets to lose. Its
        // policy reads the presentation slots the writer misassigned rather than rebuilding them,
        // so the two never apply to one stream and the container picks between them.
        compositionRepair = H264CompositionOffsetRepairSession(
            containerFormatName: containerFormatName,
            stream: stream,
            streamIndex: index,
            ladderStart: firstIndexedTimestamp(of: stream)
        ) ?? H264MatroskaSlotPermutationSession(
            containerFormatName: containerFormatName,
            stream: stream,
            streamIndex: index
        )
        return compositionRepair
    }

    /// First entry of the container's own sample index, which is where the decode ladder starts even
    /// when this demuxer opened mid-file. Int64.min when the container has no index yet.
    private func firstIndexedTimestamp(of stream: UnsafeMutablePointer<AVStream>) -> Int64 {
        guard avformat_index_get_entries_count(stream) > 0,
              let entry = avformat_index_get_entry(stream, 0),
              Self.isPlausibleIndexTimestamp(entry.pointee.timestamp, timeBase: stream.pointee.time_base)
        else { return Int64.min }
        return entry.pointee.timestamp
    }

    /// The read itself, with the fragments of a declared DVD subpicture stream joined (#651).
    /// Caller holds `accessLock`.
    private func readPacketLocked() throws -> UnsafeMutablePointer<AVPacket>? {
        while true {
            if !dvReady.isEmpty { return dvReady.removeFirst() }  // [MovieClaw P9]
            guard let read = try readDemuxedPacketLocked() else {
                // [MovieClaw P9] 读到尾：还在等 RPU 的基础层包原样放行
                if !dvHeldBase.isEmpty {
                    dvReady.append(contentsOf: dvHeldBase)
                    dvHeldBase.removeAll()
                    continue
                }
                return nil
            }
            if dvEnhancementStream >= 0, !dvMergeDualLayer(read) { continue }  // [MovieClaw P9]
            if dvdCellFold, adoptDVDNav(read) {  // [MovieClaw P13]
                var owned: UnsafeMutablePointer<AVPacket>? = read
                trackedPacketFree(&owned)
                continue
            }
            var packet: UnsafeMutablePointer<AVPacket>? = read
            let index = read.pointee.stream_index
            guard subpictureAssemblers[index] != nil else { return read }
            let timing = DVDSubpictureAssembler.Timing(
                pts: read.pointee.pts, dts: read.pointee.dts,
                pos: read.pointee.pos, duration: read.pointee.duration)
            // In place (audit DMX-106): a copied-out assembler shares the dictionary's buffer, so
            // every fragment's append copied the whole partial unit.
            let unit = subpictureAssemblers[index]?.ingest(
                UnsafeRawBufferPointer(start: read.pointee.data, count: Int(max(0, read.pointee.size))),
                timing: timing)
            guard let unit else {
                trackedPacketFree(&packet)
                continue
            }
            // The first fragment's props, then the joined payload in place of its own.
            guard let joined = trackedPacketAlloc() else { trackedPacketFree(&packet); return nil }
            var out: UnsafeMutablePointer<AVPacket>? = joined
            // `av_new_packet` resets every prop, so the copy comes after it.
            guard let joinedSize = Int32(exactly: unit.data.count),
                  av_new_packet(joined, joinedSize) >= 0,
                  av_packet_copy_props(joined, read) >= 0 else {
                trackedPacketFree(&out)
                trackedPacketFree(&packet)
                continue
            }
            unit.data.withUnsafeBytes { joined.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: unit.data.count) }
            joined.pointee.stream_index = index
            joined.pointee.pts = unit.timing.pts
            joined.pointee.dts = unit.timing.dts
            joined.pointee.pos = unit.timing.pos
            joined.pointee.duration = unit.timing.duration
            trackedPacketFree(&packet)
            return joined
        }
    }

    /// #651: drop half-joined subpicture units along with libavformat's own parser state.
    private func resetSubpictureAssembly() {
        for key in subpictureAssemblers.keys { subpictureAssemblers[key]?.reset() }
        dvResetDualLayer()  // [MovieClaw P9] 定位后挂起的包与暂存的 RPU 都作废
    }

    /// An out-of-range source timestamp was logged once for this demuxer. Guarded by `accessLock`.
    private var implausibleTimestampLogged = false

    /// Audit NAT-101 / DEC-101 / FEA-101 / SUB-105 / SEG-101: libavformat hands back whatever the
    /// container wrote (matroskadec stores a uint64 cluster time into an int64 pts and clamps
    /// BlockDuration to INT64_MAX, a live fMP4 tfdt is the origin's choice), and every consumer of
    /// this demuxer does tick arithmetic on it. One bound here covers them all. Caller holds
    /// `accessLock`.
    @discardableResult
    private func boundTimestampsLocked(_ packet: UnsafeMutablePointer<AVPacket>) -> UnsafeMutablePointer<AVPacket> {
        guard let ctx = formatContext else { return packet }
        let index = Int(packet.pointee.stream_index)
        let timeBase = index >= 0 && index < Int(ctx.pointee.nb_streams)
            ? ctx.pointee.streams[index]?.pointee.time_base : nil
        let pts = packet.pointee.pts, dts = packet.pointee.dts, duration = packet.pointee.duration
        guard SourceTimestampBounds.sanitize(packet, timeBase: timeBase ?? AVRational(num: 0, den: 0)),
              !implausibleTimestampLogged else { return packet }
        implausibleTimestampLogged = true
        EngineLog.emit(
            "[Demuxer] stream \(index) carries an out-of-range timestamp "
            + "(pts=\(pts) dts=\(dts) duration=\(duration)), treated as unset",
            category: .demux
        )
        return packet
    }

    /// What a failed `av_read_frame` means for a demuxer in this state: the code to throw, or nil for
    /// the source's own end of file.
    ///
    /// Audit SEG-104: the abort of a parked read (`markClosed()`) reaches some demuxers as end of
    /// file, and "the source ended" is a verdict every consumer acts on (tail adopt, bridge flush,
    /// `onSequentialSourceEnded`). A closed demuxer has no verdict to give, so an EOF it reports is
    /// the abort, and it says so.
    static func readFailureCode(_ ret: Int32, closeRequested: Bool) -> Int32? {
        guard ret == FFmpegErr.eof else { return ret }
        return closeRequested ? FFmpegErr.exit : nil
    }

    /// One `av_read_frame`, as libavformat delivers it. Caller holds `accessLock`.
    private func readDemuxedPacketLocked() throws -> UnsafeMutablePointer<AVPacket>? {
        guard let ctx = formatContext else { return nil }
        try probeControl?.willReadPacket()
        var packet: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
        guard packet != nil else { return nil }
        let ret = av_read_frame(ctx, packet)
        if Int(ctx.pointee.nb_streams) != streamTableSize { refreshStreamTableLocked() }
        do {
            try probeControl?.check()
            if ret >= 0, let packet { try probeControl?.receivedPacket(packet) }
        } catch {
            trackedPacketFree(&packet)
            throw error
        }
        if ret < 0 {
            trackedPacketFree(&packet)
            guard let code = Self.readFailureCode(ret, closeRequested: isCloseRequested) else { return nil }
            throw DemuxerError.readFailed(code: code)
        }
        if let pkt = packet { boundTimestampsLocked(pkt) }
        // #407: before anything reads a timestamp off this packet. The PTS on these streams was
        // invented by `+genpts` out of decode order and transposes every B/P pair; dropping it leaves
        // the decoder's own reorder to place the picture. See `VFWDecodeOrderPTSRepair`.
        if !generatedPTSStreams.isEmpty, let pkt = packet,
           generatedPTSStreams.contains(pkt.pointee.stream_index) {
            pkt.pointee.pts = Int64.min
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
        guard let ctx = formatContext,
              let timestamp = Self.ticks(forSeconds: seconds, timeBase: Self.avTimeBase) else { return false }
        // #409: the read position moves, so the repair drops its picture-order anchor and
        // re-anchors on the next keyframe (a seek always lands on one).
        compositionRepair?.noteSeek()
        if let reader = timeSeekableReader {
            dropPeekedPacketsLocked()
            guard repositionTimeSeekable(reader, toSourceSeconds: seconds, streamIndex: -1) else { return false }
            resetAfterTimeSeek(ctx)
            return true
        }
        // Audit HLS-103: libavformat flushes its packet queue before it even tries a seek, so on a
        // source that cannot rewind a refused seek is pure loss. A live AVIOReader reports itself
        // seekable by design, so live callers keep their own rules.
        guard isSourceSeekable else { return false }
        dropPeekedPacketsLocked()
        // [MovieClaw P7] 蓝光有 CLPI：按折叠后的时间找剪辑、查 EP map 得到关键帧的字节偏移，按字节一次到位。
        // 时间二分在各剪辑时间戳互相重叠时会落到别的剪辑里，经 HTTP 读机械盘时每一步还是一次请求加一次寻道
        if let table = discSeekTable,
           let hit = table.keyframe(forSourceSeconds: seconds, base0Sec: clipBase0Sec),
           avformat_seek_file(ctx, -1, hit.offset, hit.offset, hit.offset, AVSEEK_FLAG_BYTE) >= 0 {
            EngineLog.emit("[Demuxer] [MovieClaw P7] EP map seek: source=\(String(format: "%.3f", seconds))s → clip \(hit.clip) keyframe raw=\(String(format: "%.3f", hit.keyframeSec))s byte=\(hit.offset)", category: .demux)
            avformat_flush(ctx)
            resetSubpictureAssembly()
            lastReadClipIdx = -1  // AE#105：落在剪辑中间，别把它当成顺序跨入
            return true
        }
        // [MovieClaw P13] DVD 有时间表：标题时间 → VOBU 字节偏移。cell 之间 PTS 归零时按时间二分找不到落点
        if dvdSeekByTimeMap(ctx, sourceSeconds: seconds) { return true }
        assistIndexlessMatroskaSeek(ctx, targetSeconds: seconds)  // [MovieClaw P18]
        let ret = avformat_seek_file(ctx, -1, Int64.min, timestamp, Int64.max, 0)
        if ret < 0 {
            #if DEBUG
            EngineLog.emit("[Demuxer] Seek to \(seconds)s failed: \(ret)", category: .demux)
            #endif
        }
        avformat_flush(ctx)  // prevents assertion failures in matroskadec.c
        resetSubpictureAssembly()  // #651: libavformat just dropped the parsers this stands in for
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
            dropPeekedPacketsLocked()
            guard repositionTimeSeekable(reader, toSourceSeconds: seconds, streamIndex: streamIndex) else {
                return false
            }
            resetAfterTimeSeek(ctx)
            return true
        }
        guard isSourceSeekable else { return false }  // audit HLS-103, see `seek(to:)`
        dropPeekedPacketsLocked()
        // [MovieClaw P13] 同上：DVD 按时间表定位（时间戳是折叠后的源时间轴）
        if dvdTimeMap != nil, let stream = ctx.pointee.streams[Int(streamIndex)],
           stream.pointee.time_base.num > 0, stream.pointee.time_base.den > 0,
           dvdSeekByTimeMap(ctx, sourceSeconds: Double(timestamp) * Double(stream.pointee.time_base.num)
                                / Double(stream.pointee.time_base.den)) {
            return true
        }
        // [MovieClaw P18] 没有 Cues 的 MKV：先按字节探一个目标前的 Cluster 登记成索引项
        if indexlessMatroska, let stream = ctx.pointee.streams[Int(streamIndex)],
           stream.pointee.time_base.num > 0, stream.pointee.time_base.den > 0 {
            assistIndexlessMatroskaSeek(ctx, targetSeconds: Double(timestamp) * Double(stream.pointee.time_base.num)
                                            / Double(stream.pointee.time_base.den))
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
        resetSubpictureAssembly()  // #651: libavformat just dropped the parsers this stands in for
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
        resetSubpictureAssembly()  // #651: libavformat just dropped the parsers this stands in for
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
        guard probeControl?.isStopped != true else { return false }
        // A stream-anchored seek carries the target in that stream's own time base; only the -1
        // form is expressed in AV_TIME_BASE units.
        var anchor: Int32 = -1
        var timeBase = Self.avTimeBase
        if anchorStreamIndex >= 0, anchorStreamIndex < Int32(ctx.pointee.nb_streams),
           let tb = ctx.pointee.streams[Int(anchorStreamIndex)]?.pointee.time_base,
           tb.num > 0, tb.den > 0 {
            anchor = anchorStreamIndex
            timeBase = tb
        }
        guard let timestamp = Self.ticks(forSeconds: seconds, timeBase: timeBase) else { return false }
        // #409: the read position moves, so the repair drops its picture-order anchor and
        // re-anchors on the next keyframe (a seek always lands on one).
        compositionRepair?.noteSeek()
        // #268: a time-seekable source repositions itself instead of paying libavformat's byte-space
        // binary search, which on an index-less MPEG-TS is either wedged or broken (round 10 below) and
        // over HTTP would additionally be a request storm. No read deadline is armed: the reader's
        // reposition is a bookkeeping operation, the refetch happens behind the FIFO.
        if let reader = timeSeekableReader {
            dropPeekedPacketsLocked()
            guard repositionTimeSeekable(reader, toSourceSeconds: seconds, streamIndex: anchorStreamIndex) else {
                return false
            }
            resetAfterTimeSeek(ctx)
            return true
        }
        guard isSourceSeekable else { return false }  // audit HLS-103, see `seek(to:)`
        dropPeekedPacketsLocked()
        // #112 round 9: the deadline lives on the provider protocol. Casting to AVIOReader here left a
        // disc-adapter source (CustomIOReaderBridge over HTTPDiscIOReader) unbounded: one positioning
        // seek on a remote ISO sat wedged ~230 s and every later re-arm queued behind it.
        avioProvider?.beginReadDeadline(secondsFromNow: timeout)
        defer { avioProvider?.endReadDeadline() }
        // [MovieClaw P7 / P13] 光盘有定位表就按字节一次到位（同 `seek(to:)`）：软件通路（VC-1 原盘、DVD 的 MPEG-2）
        // 与字幕旁路都走这里，原来绕过了定位表、在 PTS 归零或互相重叠的剪辑里按时间二分
        if discTableSeek(ctx, sourceSeconds: seconds) {
            return !(avioProvider?.readDeadlineFired ?? false) && probeControl?.isStopped != true
        }
        assistIndexlessMatroskaSeek(ctx, targetSeconds: seconds)  // [MovieClaw P18]
        let ret = avformat_seek_file(ctx, anchor, Int64.min, timestamp, Int64.max, 0)
        avformat_flush(ctx)
        resetSubpictureAssembly()  // #651: libavformat just dropped the parsers this stands in for
        lastReadClipIdx = -1  // AE#105: post-seek reads may land mid-clip; require a fresh clean crossing
        // matroska may return success with a partial index after abort; deadline flag
        // is authoritative, not ret.
        let capped = avioProvider?.readDeadlineFired ?? false
        return ret >= 0 && !capped && probeControl?.isStopped != true
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
        return clampedByteOffset(Double(fileSize) * fraction, fileSize: fileSize)
    }

    /// `raw` as a byte offset in `[0, fileSize]` (audit DMX-103). The compare runs on the Double:
    /// the total is whatever the origin wrote in `Content-Range`, and a `min(fileSize, ...)` after
    /// `Int64(_:)` comes too late for a product that rounds up to 2^63 or past it.
    nonisolated static func clampedByteOffset(_ raw: Double, fileSize: Int64) -> Int64 {
        guard raw > 0 else { return 0 }
        return raw >= Double(fileSize) ? fileSize : Int64(raw)
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
        let corrected = clampedByteOffset(Double(currentByte) * (targetRel / landedRel), fileSize: fileSize)
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
        guard isSourceSeekable else { return false }  // audit HLS-103, see `seek(to:)`
        dropPeekedPacketsLocked()
        let ret = avformat_seek_file(ctx, -1, Int64.min, byteTarget, Int64.max, AVSEEK_FLAG_BYTE)
        avformat_flush(ctx)
        resetSubpictureAssembly()  // #651: libavformat just dropped the parsers this stands in for
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
        interrupt.requestClose()
        closeRequestLock.lock()
        closeRequested = true
        let provider = avioProvider
        closeRequestLock.unlock()
        provider?.markClosed()
        cancelOwnedSourceReader()
    }

    /// Static metadata probes only. Strong ownership outlives the native interrupt callback.
    var probeControl: ProbeControl? {
        get { interrupt.probeControl }
        set { interrupt.probeControl = newValue }
    }

    /// Target of the format context's interrupt callback, owned for the demuxer's whole life so the
    /// unretained pointer libavformat holds cannot dangle.
    private let interrupt = DemuxInterrupt()

    /// Caps the source bytes libavformat may consume until `endInputByteBudget`, enforced below
    /// `av_read_frame`. A pass that sets AVDISCARD_ALL on other streams needs this: the demuxer reads
    /// and drops their blocks inside one `av_read_frame`, where no packet or packet-byte cap sees them.
    /// Overshoot is at most one read. Call from the thread that reads packets.
    func beginInputByteBudget(_ bytes: Int64) {
        accessLock.lock()
        defer { accessLock.unlock() }
        if let provider = avioProvider {
            provider.beginReadByteBudget(bytes)
        } else if let pb = formatContext?.pointee.pb {
            interrupt.armInputCeiling(pb: pb, bytes: bytes)
        }
    }

    func endInputByteBudget() {
        accessLock.lock()
        defer { accessLock.unlock() }
        avioProvider?.endReadByteBudget()
        interrupt.disarmInputCeiling()
    }

    /// True when a read was refused because the budget armed by `beginInputByteBudget` was spent.
    var inputByteBudgetExhausted: Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        return (avioProvider?.readByteBudgetExhausted ?? false) || interrupt.inputCeilingHit
    }

    func close() {
        interrupt.requestClose()
        avioProvider?.markClosed()  // unblocks av_read_frame (tvOS suspends threads in background)
        accessLock.lock()
        interrupt.disarmInputCeiling()
        // Audit DMX-108: the table is emptied BEFORE the streams are freed, and close waits for
        // every `withStream` caller already inside, so no thread is left holding a freed `AVStream*`.
        streamTableLock.lock()
        streamTable = []
        trackSnapshot = TrackSnapshot()
        while streamUsers > 0 { streamTableLock.wait() }
        streamTableLock.unlock()
        dropPeekedPacketsLocked()
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        formatContext = nil
        compositionRepair = nil
        compositionRepairEvaluated = false
        refreshStreamTableLocked()
        accessLock.unlock()

        avioProvider?.close()
        avioProvider = nil
        releaseOwnedSourceReader()
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

/// Answers libavformat's interrupt callback. `probeControl` is set before open; the input ceiling is
/// armed and read only on the thread that holds the demuxer's access lock for the native call.
private final class DemuxInterrupt: @unchecked Sendable {
    var probeControl: ProbeControl?
    private var pb: UnsafeMutablePointer<AVIOContext>?
    private var ceiling: Int64 = .max
    private(set) var inputCeilingHit = false

    /// Audit DMX-109: set by `Demuxer.markClosed()` from any thread, read by libavformat's callback
    /// on the demux thread. A provider-backed input stops on its provider's own flag; a local-path
    /// input has no provider, so this is the only way a close reaches a read parked on a slow volume.
    private let closeRequested = OSAllocatedUnfairLock<Bool>(initialState: false)

    func requestClose() { closeRequested.withLock { $0 = true } }
    var isCloseRequested: Bool { closeRequested.withLock { $0 } }

    /// Local (URLContext) inputs only: a provider-backed input never consults this callback per read.
    func armInputCeiling(pb: UnsafeMutablePointer<AVIOContext>, bytes: Int64) {
        self.pb = pb
        let (sum, overflow) = pb.pointee.bytes_read.addingReportingOverflow(max(0, bytes))
        ceiling = overflow ? .max : sum
        inputCeilingHit = false
    }

    func disarmInputCeiling() {
        pb = nil
        ceiling = .max
    }

    func shouldInterrupt() -> Bool {
        if isCloseRequested { return true }
        if probeControl?.isStopped == true { return true }
        if let pb, pb.pointee.bytes_read >= ceiling {
            inputCeilingHit = true
            return true
        }
        return false
    }
}

// MARK: - [MovieClaw P9] UHD 原盘双 PID 杜比视界（仓库 docs/design/player-engine.md）
//
// UHD 蓝光的杜比视界是 Profile 7：基础层（HDR10）在 PID 0x1011，增强层与 RPU 在单独的 PID 0x1015。
// 引擎只看选中的基础层，于是按 HDR10 播放；增强层还被「只保留选中流」一并丢掉。这里在解复用层把两路配对：
// 基础层补上 P7 记录（bl_present_flag=1），增强层每个访问单元的 RPU 按 PTS 追加到同一时间戳的基础层包尾
// （Annex-B），下游现成的 P7 → 8.1 转换（只取 RPU、丢弃增强层）原样接手。增强层视频本身不送下游（FEL 的
// 增强信息在 Apple 平台上本来也用不上）。
//
// 配对依据：
// - 节目映射表里带 DOVI 描述符（0xB0）、bl_present_flag=0 的 HEVC 流就是增强层，记录照抄；
// - 实测 UHD 原盘（《疾速追杀4》）的节目映射表根本没有 DOVI 描述符，两路都只有 HDMV 注册描述符，杜比视界
//   只记在盘的 CLPI/MPLS 里。蓝光规格把 PID 0x1015 固定分给 HDR 增强层，所以 mpegts 里 PID 0x1011 与
//   0x1015 两路 HEVC 并存就按双层杜比视界配对，P7 记录按基础层的分辨率与帧率合成（兼容 ID 6 = HDR10 基础层）。
extension Demuxer {
    /// 基础层包挂起的上限：超过就原样放行最早的那个（它的 RPU 没来，宁可按 HDR10 放这一帧也不能卡住）
    fileprivate static let dvHoldLimit = 16
    /// 蓝光规格的 PID 分配：主视频（基础层）与 HDR 增强层
    fileprivate static let bdBaseLayerPID: Int32 = 0x1011
    fileprivate static let bdEnhancementLayerPID: Int32 = 0x1015

    /// 探测完成后找增强层与基础层这一对，给基础层写上 P7 记录
    fileprivate func pairDolbyVisionDualPID(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        dvBaseLayerStream = -1
        dvEnhancementStream = -1
        dvResetDualLayer()
        guard let iformat = ctx.pointee.iformat, let name = iformat.pointee.name,
              String(cString: name).contains("mpegts") else { return }
        struct Candidate { let index: Int32; let pid: Int32; let record: AVDOVIDecoderConfigurationRecord? }
        var hevc: [Candidate] = []
        for i in 0..<Int32(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams[Int(i)], let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_VIDEO, par.pointee.codec_id == AV_CODEC_ID_HEVC else { continue }
            var record: AVDOVIDecoderConfigurationRecord?
            if let item = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data,
                                                  AV_PKT_DATA_DOVI_CONF),
               let data = item.pointee.data,
               item.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size {
                record = data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
            }
            hevc.append(Candidate(index: i, pid: stream.pointee.id, record: record))
        }
        let enhancement = hevc.first { $0.record?.dv_profile == 7 && $0.record?.bl_present_flag == 0 }
            ?? hevc.first { $0.record == nil && $0.pid == Self.bdEnhancementLayerPID }
        guard let enhancement else { return }
        let bare = hevc.filter { $0.record == nil && $0.index != enhancement.index }
        guard let base = bare.first(where: { $0.pid == Self.bdBaseLayerPID }) ?? bare.first,
              let baseStream = ctx.pointee.streams[Int(base.index)],
              let basePar = baseStream.pointee.codecpar else { return }
        let record: AVDOVIDecoderConfigurationRecord
        if var declared = enhancement.record {
            declared.bl_present_flag = 1
            record = declared
        } else {
            var synthesized = AVDOVIDecoderConfigurationRecord()
            synthesized.dv_version_major = 1
            synthesized.dv_version_minor = 0
            synthesized.dv_profile = 7
            synthesized.dv_level = Self.dolbyVisionLevel(width: basePar.pointee.width, height: basePar.pointee.height,
                                                         fps: av_q2d(baseStream.pointee.avg_frame_rate))
            synthesized.rpu_present_flag = 1
            synthesized.el_present_flag = 1
            synthesized.bl_present_flag = 1
            synthesized.dv_bl_signal_compatibility_id = 6
            record = synthesized
        }
        let size = MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        guard let item = av_packet_side_data_new(&basePar.pointee.coded_side_data, &basePar.pointee.nb_coded_side_data,
                                                 AV_PKT_DATA_DOVI_CONF, size, 0),
              let raw = item.pointee.data else { return }
        memset(raw, 0, size)
        raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee = record }
        dvBaseLayerStream = base.index
        dvEnhancementStream = enhancement.index
        EngineLog.emit("[Demuxer] [MovieClaw P9] dual-PID Dolby Vision: base=#\(base.index) (pid 0x\(String(base.pid, radix: 16))) "
                       + "enhancement=#\(enhancement.index) (pid 0x\(String(enhancement.pid, radix: 16))) "
                       + "record=\(enhancement.record == nil ? "synthesized" : "declared") profile=7 level=\(record.dv_level) "
                       + "compat=\(record.dv_bl_signal_compatibility_id); RPUs will ride on the base layer", category: .demux)
    }

    /// 杜比视界级别：按每秒像素数与画面宽度，取 Dolby 级别表里第一个装得下的（只用于编码串 dvh1.08.LL）
    fileprivate static func dolbyVisionLevel(width: Int32, height: Int32, fps: Double) -> UInt8 {
        let rate = fps.isFinite && fps > 0 ? fps : 24
        let pixelsPerSecond = Double(width) * Double(height) * rate
        let table: [(level: UInt8, maxPixelsPerSecond: Double, maxWidth: Int32)] = [
            (1, 22_118_400, 1280), (2, 27_648_000, 1280), (3, 49_766_400, 1920), (4, 62_208_000, 2560),
            (5, 124_416_000, 3840), (6, 199_065_600, 3840), (7, 248_832_000, 3840), (8, 398_131_200, 3840),
            (9, 497_664_000, 3840), (10, 995_328_000, 3840), (11, 995_328_000, 7680), (12, 1_990_656_000, 7680),
            (13, 3_981_312_000, 7680),
        ]
        return table.first { pixelsPerSecond <= $0.maxPixelsPerSecond * 1.001 && width <= $0.maxWidth }?.level ?? 6
    }

    /// 处理一个读到的包：返回 true = 照常交出；false = 已吸收（增强层）或挂起（等 RPU 的基础层）
    fileprivate func dvMergeDualLayer(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        let index = packet.pointee.stream_index
        if index == dvEnhancementStream {
            if packet.pointee.pts != Int64.min, let rpu = Self.extractRPU(packet) {
                dvPendingRPU[packet.pointee.pts] = rpu
                if dvPendingRPU.count > 64, let oldest = dvPendingRPU.keys.min() { dvPendingRPU.removeValue(forKey: oldest) }
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
            dvReleaseHeld()
            return false
        }
        guard index == dvBaseLayerStream else { return true }
        if dvHeldBase.isEmpty, dvAttachRPU(to: packet) { return true }
        dvHeldBase.append(packet)
        dvReleaseHeld()
        return false
    }

    /// 从队首依次放行：挂上了 RPU 的、或挂起太多只能原样放行的
    fileprivate func dvReleaseHeld() {
        while let front = dvHeldBase.first {
            if dvAttachRPU(to: front) || dvHeldBase.count > Self.dvHoldLimit {
                dvReady.append(dvHeldBase.removeFirst())
            } else {
                break
            }
        }
    }

    /// 同一 PTS 的 RPU 已到：追加到包尾（00 00 00 01 + RPU NAL），返回 true
    fileprivate func dvAttachRPU(to packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        let pts = packet.pointee.pts
        guard pts != Int64.min, let rpu = dvPendingRPU.removeValue(forKey: pts) else {
            if dvHeldBase.count > Self.dvHoldLimit { dvStats.missed += 1 }
            return false
        }
        let oldSize = Int(packet.pointee.size)
        guard av_grow_packet(packet, Int32(4 + rpu.count)) >= 0, let data = packet.pointee.data else { return false }
        let tail = data.advanced(by: oldSize)
        tail[0] = 0; tail[1] = 0; tail[2] = 0; tail[3] = 1
        rpu.withUnsafeBufferPointer { tail.advanced(by: 4).update(from: $0.baseAddress!, count: rpu.count) }
        dvStats.attached += 1
        if dvStats.attached == 1 || dvStats.attached % 2000 == 0 {
            EngineLog.emit("[Demuxer] [MovieClaw P9] RPU attached to base layer: \(dvStats.attached) (missed \(dvStats.missed))", category: .demux)
        }
        return true
    }

    /// 增强层访问单元（Annex-B）里的 RPU NAL（类型 62），含 2 字节 NAL 头、去掉尾随的零字节
    fileprivate static func extractRPU(_ packet: UnsafeMutablePointer<AVPacket>) -> [UInt8]? {
        guard let data = packet.pointee.data, packet.pointee.size > 5 else { return nil }
        let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
        var starts: [Int] = []  // 每个 NAL 头字节的下标
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        for (k, start) in starts.enumerated() where start < bytes.count {
            guard (bytes[start] >> 1) & 0x3F == 62 else { continue }
            var end = k + 1 < starts.count ? starts[k + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            guard end - start > 2 else { return nil }
            return Array(bytes[start..<end])
        }
        return nil
    }

    /// 定位后挂起的包与暂存的 RPU 都作废（包归还给跟踪分配器）
    fileprivate func dvResetDualLayer() {
        for packet in dvHeldBase + dvReady {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
        }
        dvHeldBase.removeAll()
        dvReady.removeAll()
        dvPendingRPU.removeAll()
    }
}


// MARK: - [MovieClaw P13] DVD 按 cell 折叠时间轴、按时间表定位（仓库 docs/design/disc-direct-play.md）
extension Demuxer {
    /// 导航包（MPEG-PS 私有流 2 里的 PCI）：记下它所在 cell 的时间戳基准，返回 true 表示这是导航包、已吸收。
    /// PCI 里 VOBU 起始 PTS（90 kHz）减去 cell 内已播时间（C_ELTM）就是这个 cell 开头的原始时间戳，
    /// 折叠偏移 = 基准 − cell 0 的基准 − 标题时间轴上这个 cell 之前的总时长。导航包在每个 VOBU 的最前面，
    /// 顺序跨入新 cell、跳转落在 cell 中间，都是先读到它、再读到这个 cell 的音视频包，偏移总赶在前面
    fileprivate func adoptDVDNav(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard let ctx = formatContext,
              let stream = ctx.pointee.streams[Int(packet.pointee.stream_index)],
              stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_DVD_NAV else { return false }
        // libavformat 按子流拆成两种包：PCI（首字节 0x00，980 字节）与 DSI（0x01），只用 PCI
        guard let data = packet.pointee.data, packet.pointee.size >= 0x1D, data[0] == 0x00 else { return true }
        let startPTS = (UInt32(data[0x0D]) << 24) | (UInt32(data[0x0E]) << 16) | (UInt32(data[0x0F]) << 8) | UInt32(data[0x10])
        func bcd(_ b: UInt8) -> Double { Double(Int(b >> 4) * 10 + Int(b & 0x0F)) }
        let frameByte = data[0x1C]
        let fps: Double = (frameByte >> 6) == 1 ? 25 : ((frameByte >> 6) == 3 ? 30000.0 / 1001.0 : 0)
        let elapsed = bcd(data[0x19]) * 3600 + bcd(data[0x1A]) * 60 + bcd(data[0x1B])
            + (fps > 0 ? bcd(frameByte & 0x3F) / fps : 0)
        let cellBase = Double(startPTS) / 90000 - elapsed
        let idx = ClipSpan.index(forPos: packet.pointee.pos, in: clipTimeline, fallback: lastClipIndex)
        if idx == 0 {
            if clipBase0Sec.isNaN { clipBase0Sec = cellBase }
            return true
        }
        guard clipBase0Sec.isFinite, idx < clipResolvedShiftSec.count else { return true }
        let shift = ClipFold.offsetSeconds(observedBaseSec: cellBase, base0Sec: clipBase0Sec,
                                           cumulativeBeforeSec: clipTimeline[idx].cumulativeBeforeSec)
        if !clipResolvedShiftSec[idx].isFinite || abs(clipResolvedShiftSec[idx] - shift) > 0.05 {
            clipResolvedShiftSec[idx] = shift
            EngineLog.emit("[Demuxer] [MovieClaw P13] DVD cell \(idx): base=\(String(format: "%.3f", cellBase))s "
                           + "cumBefore=\(String(format: "%.1f", clipTimeline[idx].cumulativeBeforeSec))s → shift \(String(format: "%.3f", shift))s",
                           category: .demux)
        }
        return true
    }

    /// 光盘的定位表（蓝光 CLPI 的 EP map、DVD 的时间表）按字节一次到位；都没有、或按字节定位失败时返回 false。调用方持有 accessLock
    /// [MovieClaw P18] 读文件头判断 MKV 有没有可用的 Cues（`MatroskaCuesProbe.headInfo`）。只在可随机读、知道总长的
    /// matroska 源上做；文件头读取器本来就留着，不多发请求。读完把读位置放回原处，libavformat 接着读不受影响。
    private func detectIndexlessMatroska(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        indexlessMatroska = false
        guard let name = ctx.pointee.iformat?.pointee.name, String(cString: name).hasPrefix("matroska"),
              timeSeekableReader == nil, !isDiscSource,
              let pb = ctx.pointee.pb, pb.pointee.seekable != 0,
              let size = avioProvider?.resolvedByteSize, size > 0
        else { return }
        let saved = avio_seek(pb, 0, SEEK_CUR)
        guard saved >= 0 else { return }
        defer { avio_seek(pb, saved, SEEK_SET) }
        guard avio_seek(pb, 0, SEEK_SET) >= 0 else { return }
        var head = [UInt8](repeating: 0, count: 64 * 1024)
        let got = head.withUnsafeMutableBufferPointer { avio_read(pb, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return }
        let info = MatroskaCuesProbe.headInfo(Array(head.prefix(Int(got))), fileSize: size)
        matroskaTimestampScale = info.timestampScale
        switch info.cues {
        case .missing, .pastEndOfFile:
            indexlessMatroska = true
            EngineLog.emit("[Demuxer] [MovieClaw P18] MKV has no usable Cues (\(info.cues)); seeks will be assisted by cluster probes", category: .demux)
        case .present, .unknown:
            break
        }
    }

    /// [MovieClaw P18] 没有 Cues 的 MKV 在按时间定位前调用：按字节比例估一个位置、往后找最近的 Cluster 读出时间码，
    /// 至多校正两次，得到目标之前最近的一个 Cluster；再从它按平均码率估到目标之后半秒处探一次，得到目标之后最近的
    /// 一个。两个（连同途中探到的）都登记成视频流的索引项，libavformat 的两种定位于是都有落脚点：反向（`seek(to:)`、
    /// `seekBounded`）落在目标前最近的一项，正向（生产端「不早于目标」的 `seek(to:streamIndex:)`）落在目标后最近的
    /// 一项。只登记目标前那一个时，正向定位会跳到索引里下一个已知项——真机往回跳到 300 秒落在了续播时读过的 885 秒；
    /// 按 Cluster 长度逐个往后跳又太贵——《饥饿站台》的 Cluster 约 0.3 秒一个，跳 13 秒读了 50 MB、定位花 2 秒。
    /// 不登记则 matroska_read_seek 只能从上一个已知位置逐个 Cluster 线性读过去（续播到 900 秒约 1.8 GB）。
    /// 落点前后都已经读过（播放时 libavformat 边读边登记关键帧）就不再探。
    private func assistIndexlessMatroskaSeek(_ ctx: UnsafeMutablePointer<AVFormatContext>, targetSeconds: Double) {
        guard indexlessMatroska, targetSeconds > 0, let pb = ctx.pointee.pb,
              let size = avioProvider?.resolvedByteSize, size > 0, ctx.pointee.duration > 0 else { return }
        let videoIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard videoIndex >= 0, let stream = ctx.pointee.streams[Int(videoIndex)] else { return }
        let tb = stream.pointee.time_base
        guard tb.num > 0, tb.den > 0 else { return }
        let tbSeconds = Double(tb.num) / Double(tb.den)
        let targetTs = Int64(targetSeconds / tbSeconds)
        let knownBefore = av_index_search_timestamp(stream, targetTs, AVSEEK_FLAG_BACKWARD)
        let knownAfter = av_index_search_timestamp(stream, targetTs, 0)
        if knownBefore >= 0, knownAfter >= 0,
           let low = avformat_index_get_entry(stream, knownBefore), let high = avformat_index_get_entry(stream, knownAfter),
           Double(targetTs - low.pointee.timestamp) * tbSeconds < 20,
           Double(high.pointee.timestamp - targetTs) * tbSeconds < 20 {
            return
        }
        let duration = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)
        let scale = Double(matroskaTimestampScale) / 1e9
        let aim = max(0, targetSeconds - 3)  // 宁早勿晚：按字节估的位置常有码率误差
        var estimate = min(size - 1, Int64(Double(size) * min(1, aim / duration)))
        var best: MatroskaClusterHit?
        for _ in 0 ..< 3 {
            guard let hit = probeMatroskaCluster(pb, from: estimate, size: size) else { break }
            let seconds = Double(hit.timestamp) * scale
            if seconds <= targetSeconds, best.map({ seconds > Double($0.timestamp) * scale }) ?? true { best = hit }
            if seconds <= targetSeconds, seconds >= targetSeconds - 10 { break }
            guard seconds > 1, hit.pos > 0 else { break }
            // 按这一次落点校准的码率重估（同 `byteEstimateCorrection`）
            let corrected = min(size - 1, max(0, Int64(Double(hit.pos) * aim / seconds)))
            guard corrected != estimate else { break }
            estimate = corrected
        }
        guard let first = best else { return }
        func register(_ hit: MatroskaClusterHit) {
            av_add_index_entry(stream, hit.pos, Int64(Double(hit.timestamp) * scale / tbSeconds), 0, 0, AVINDEX_KEYFRAME)
        }
        register(first)
        // 目标之后最近的一个：按本地码率从目标前那个估到目标之后（多估 10%）往后找；还落在目标前就当作更近的「之前」、
        // 用这两点的斜率更新码率再探。码率不能用「文件大小 ÷ 片长」：截断的文件片长照写全片（《饥饿站台》按它算每秒
        // 2 MB，实际 3.6 MB，每次只跳到剩余距离的一半）
        var before = first
        var bytesPerSecond = Double(first.timestamp) * scale > 1
            ? Double(first.pos) / (Double(first.timestamp) * scale) : Double(size) / duration
        var after: MatroskaClusterHit?
        for _ in 0 ..< 4 {
            let gap = max(0.5, targetSeconds + 0.5 - Double(before.timestamp) * scale)
            let from = min(size - 1, before.pos + Int64(gap * bytesPerSecond * 1.1))
            guard let hit = probeMatroskaCluster(pb, from: from, size: size), hit.timestamp > before.timestamp else { break }
            register(hit)
            if Double(hit.timestamp) * scale >= targetSeconds { after = hit; break }
            let span = Double(hit.timestamp - before.timestamp) * scale
            if span >= 0.5 { bytesPerSecond = Double(hit.pos - before.pos) / span }
            before = hit
        }
        let beforeText = String(format: "%.1fs", Double(before.timestamp) * scale)
        let afterText = after.map { String(format: "%.1fs", Double($0.timestamp) * scale) } ?? "none"
        EngineLog.emit("[Demuxer] [MovieClaw P18] cluster probe for \(String(format: "%.1f", targetSeconds))s → "
                       + "before \(beforeText), after \(afterText) registered as index entries",
                       category: .demux)
    }

    private struct MatroskaClusterHit {
        let pos: Int64
        let timestamp: UInt64
    }

    /// 从 `offset` 往后读（至多 8 MB）找第一个 Cluster。块与块之间留 32 字节重叠，免得 Cluster 头正好切在块边界上
    private func probeMatroskaCluster(_ pb: UnsafeMutablePointer<AVIOContext>, from offset: Int64,
                                      size: Int64) -> MatroskaClusterHit? {
        let chunk = 512 * 1024
        var start = offset
        var carry: [UInt8] = []
        while start - offset < 8 * 1024 * 1024, start < size {
            guard avio_seek(pb, start, SEEK_SET) >= 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: chunk)
            let got = buffer.withUnsafeMutableBufferPointer { avio_read(pb, $0.baseAddress, Int32(chunk)) }
            guard got > 0 else { return nil }
            let bytes = carry + buffer.prefix(Int(got))
            if let hit = MatroskaCuesProbe.firstCluster(in: bytes) {
                return MatroskaClusterHit(pos: start - Int64(carry.count) + Int64(hit.index), timestamp: hit.timestamp)
            }
            carry = Array(bytes.suffix(32))
            start += Int64(got)
        }
        return nil
    }

    fileprivate func discTableSeek(_ ctx: UnsafeMutablePointer<AVFormatContext>, sourceSeconds seconds: Double) -> Bool {
        if let table = discSeekTable,
           let hit = table.keyframe(forSourceSeconds: seconds, base0Sec: clipBase0Sec),
           avformat_seek_file(ctx, -1, hit.offset, hit.offset, hit.offset, AVSEEK_FLAG_BYTE) >= 0 {
            EngineLog.emit("[Demuxer] [MovieClaw P7] EP map seek: source=\(String(format: "%.3f", seconds))s → clip \(hit.clip) keyframe raw=\(String(format: "%.3f", hit.keyframeSec))s byte=\(hit.offset)", category: .demux)
            avformat_flush(ctx)
            resetSubpictureAssembly()
            lastReadClipIdx = -1
            return true
        }
        return dvdSeekByTimeMap(ctx, sourceSeconds: seconds)
    }

    /// 按时间表定位：源时间（cell 0 的时间戳基准 + 标题时间）→ 标题时间 → 不晚于它的 VOBU 的字节偏移，按字节一次到位。
    /// 没有时间表、还不知道 cell 0 的基准、或按字节定位失败时返回 false（调用方退回原来的按时间定位）。调用方持有 accessLock
    fileprivate func dvdSeekByTimeMap(_ ctx: UnsafeMutablePointer<AVFormatContext>, sourceSeconds seconds: Double) -> Bool {
        guard let map = dvdTimeMap, clipBase0Sec.isFinite else { return false }
        let titleSeconds = max(0, seconds - clipBase0Sec)
        let offset = map.byteOffset(forTitleSeconds: titleSeconds)
        guard avformat_seek_file(ctx, -1, offset, offset, offset, AVSEEK_FLAG_BYTE) >= 0 else { return false }
        EngineLog.emit("[Demuxer] [MovieClaw P13] DVD time map seek: title=\(String(format: "%.3f", titleSeconds))s → byte \(offset)",
                       category: .demux)
        avformat_flush(ctx)
        resetSubpictureAssembly()
        lastReadClipIdx = -1  // 落在 cell 中间，偏移等导航包来算
        return true
    }
}
