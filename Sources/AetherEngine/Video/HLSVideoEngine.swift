import AVFoundation
import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// HLS-fMP4 loopback session: libavformat `hls` muxer fed by `Demuxer`, fragments
/// redirected into `SegmentCache` via custom `io_open`/`io_close2`, served to
/// AVPlayer by a local HTTP server that blocks on a condvar until the requested
/// segment is muxed.
public final class HLSVideoEngine: @unchecked Sendable {

    // MARK: - Errors

    public enum HLSVideoEngineError: Error, CustomStringConvertible, LocalizedError {
        case openFailed(reason: String)
        case noVideoStream
        case unsupportedCodec(rawCodecID: UInt32)
        case zeroDuration
        case unsupportedDVProfile(profile: Int, compatID: Int)
        case muxerInit(underlying: Error)
        case alreadyStarted
        case notStarted

        public var description: String {
            switch self {
            case .openFailed(let r):     return "HLSVideoEngine: open failed (\(r))"
            case .noVideoStream:         return "HLSVideoEngine: source has no video stream"
            case .unsupportedCodec(let id): return "HLSVideoEngine: unsupported codec id \(id) (only HEVC and H.264 supported)"
            case .zeroDuration:          return "HLSVideoEngine: source has zero duration (cannot build segment plan)"
            case .unsupportedDVProfile(let p, let c): return "HLSVideoEngine: unsupported Dolby Vision profile \(p).\(c)"
            case .muxerInit(let e):      return "HLSVideoEngine: muxer init failed (\(e))"
            case .alreadyStarted:        return "HLSVideoEngine: session already started"
            case .notStarted:            return "HLSVideoEngine: session not started"
            }
        }

        public var errorDescription: String? { description }
    }

    // MARK: - State

    let sourceURL: URL
    let sourceHTTPHeaders: [String: String]
    private let dvModeAvailable: Bool

    /// From `LoadOptions.keepDvh1TagWithoutDV`; default OFF, set only for misreporting DV panels.
    private let keepDvh1TagWithoutDV: Bool

    /// Match Content master toggle at load time; one input to the master-vs-media-playlist routing decision.
    private let matchContentEnabled: Bool

    /// Whether the connected display can present any HDR (HDR10, HLG, HDR10+, or DV).
    private let displaySupportsHDR: Bool

    /// Whether the panel was already in HDR at load time (`currentEDRHeadroom > 1`). When true,
    /// master-playlist routing is safe regardless of `matchContentEnabled` (AetherEngine#4).
    private let panelIsInHDRMode: Bool

    /// `dvModeAvailable || keepDvh1TagWithoutDV`; DV routing branches key off this.
    var effectiveDvMode: Bool { dvModeAvailable || keepDvh1TagWithoutDV }

    /// Caller-chosen audio stream index; nil falls back to `av_find_best_stream`. Enables
    /// host-driven track switching via `AetherEngine.selectAudioTrack(index:)` reload.
    private let audioSourceStreamIndexOverride: Int32?

    var demuxer: Demuxer?
    var cache: SegmentCache?   // internal for the teardown-partial witness test
    var producer: HLSSegmentProducer?
    private var server: HLSLocalServer?
    var provider: VideoSegmentProvider?

    /// Side demuxer for live HLS ingest with a separate audio rendition playlist; nil for muxed-audio
    /// sessions. Torn down by `stop()` identically to the main demuxer (markClosed + detached close).
    var sideAudioDemuxer: Demuxer?

    /// Packed-audio companion (Apple HLS packed audio: raw ADTS AAC + ID3 PRIV program-clock anchor).
    /// `startPts` is the PRIV timestamp rescaled into the side stream's time base; the fallback duration is
    /// one AAC frame. Both threaded onto the producer for synthesized side-audio timestamps. nil for TS / muxed.
    private var packedSideAudioStartPts: Int64?
    private var packedSideAudioFallbackDurationPts: Int64 = 0

    /// Stream index actually muxed (post override-validation and stream-copy/bridge cascade), or -1
    /// for video-only. For demuxed-audio sessions indexes the SIDE demuxer. Set once in `start()`;
    /// host reads this to avoid triggering a pointless reload of the track already on air.
    public private(set) var activeAudioSourceStreamIndex: Int32 = -1

    /// Audio tracks from the side demuxer, snapshotted at `start()`. Empty for muxed-audio sessions.
    public private(set) var companionAudioTracks: [TrackInfo] = []

    var videoStreamIndex: Int32 = -1
    var savedVideoConfig: HLSSegmentProducer.StreamConfig?
    var savedAudioConfig: HLSSegmentProducer.AudioConfig?

    /// When true, `makeProducer` sets `enableNativeSubtitleTrack` on every producer so the
    /// init moov always declares the mov_text track (#55). Set before `start()`.
    var enableNativeSubtitleTrackForSession: Bool = false

    /// Native subtitle rendition marked DEFAULT=YES in the master (Sodalite#32). Set before `start()`; the
    /// provider advertises this ordinal as the group default so a host-selected legible track renders.
    var nativeSubtitleDefaultOrdinal: Int = 0

    /// Serve the SUBTITLES rendition as one whole-program .vtt (Sodalite#32). Set before `start()`.
    var nativeSubtitleWholeProgram: Bool = false

    /// Source position (seconds) the playback stream started at (resume/seek). Device-confirmed AVKit anchors a
    /// whole-program VOD .vtt's time 0 to the stream start, so whole-program cues shift by this so cue-for-source-S
    /// lands at currentTime S (from-start = 0 = no shift). Set before `start()`. Sodalite#32.
    var subtitleStreamStartSeconds: Double = 0

    /// Source position (seconds, playlist axis) the session will start at (resume/seek). Set
    /// before `start()`; anchors the FIRST producer at the matching segment instead of seg0
    /// (#93 residual: the seg0 cold start was torn down unwatched on every resume, and the
    /// fetch/restart race could 404 the item into a host reload). nil/0 keeps baseIndex 0.
    var initialStartSeconds: Double?
    /// Resolved in start() from `initialStartSeconds` once the segment plan exists.
    private(set) var initialProducerBaseIndex: Int = 0

    /// One cue store per declared text track (#55, all-tracks), ordinal-aligned with
    /// `nativeSubtitleLanguagesForSession`. Re-threaded onto every producer restart so
    /// per-segment cue drain survives seek/audio-switch. Empty = no native subtitles active.
    var nativeSubtitleCueStoresForSession: [NativeSubtitleCueStore] = []

    /// ISO 639-2 / BCP-47 language tags parallel to `nativeSubtitleCueStoresForSession`.
    /// nil entry = no language box for that track.
    var nativeSubtitleLanguagesForSession: [String?] = []

    /// Per-rendition master metadata parallel to the stores (unique NAMEs + FORCED dispositions);
    /// empty falls back to per-ordinal locale names, which collapse in AVFoundation when a
    /// language repeats. Built by `AetherEngine.nativeSubtitleRenditionInfos(for:)` at load.
    var nativeSubtitleRenditionInfosForSession: [NativeSubtitleRenditionInfo] = []

    /// #77: in-band CC stream index + observer, re-threaded onto every producer so the tap survives
    /// seek/reload/wedge. Set before start(). -1 / nil = no CC tap.
    var closedCaptionStreamIndexForSession: Int32 = -1
    var closedCaptionObserverForSession: (@Sendable (UnsafePointer<AVPacket>, AVRational) -> Void)?

    /// Sodalite#32: ordinal-aligned source stream indices for the native subtitle cue stores (nil entry =
    /// no demuxable stream, e.g. a sidecar). Drives the producer's subtitle tap: the pump keeps these
    /// streams and hands their packets to the session tap, which decodes into the ordinal's store. Set
    /// before start() by the host, or by the auto-attach/attach APIs.
    var nativeSubtitleSourceStreamIndicesForSession: [Int32?] = []

    /// Session-lifetime tap decode routes keyed by source stream index. Decoders persist across producer
    /// restarts so their internal dedup absorbs the re-read overlap; the store dedups again on append.
    /// Guarded by subtitleTapLock: an abandoned wedged producer's final packets can race the replacement
    /// producer's tap.
    private var subtitleTapRoutes: [Int32: (decoder: EmbeddedSubtitleDecoder, store: NativeSubtitleCueStore)] = [:]
    private let subtitleTapLock = NSLock()

    /// Sodalite#32 Phase 2: tap decoders honor the host's markup preference so the overlay can render
    /// styled ASS from tap-fed cues; the WebVTT rendition strips the markup at serve time instead.
    /// Set before start() (AetherEngine+Loading).
    var preserveASSMarkupForSubtitleTap = false

    /// Sodalite#32 Phase 2: decoded tap events, forwarded after the store append. AetherEngine routes
    /// the ACTIVE track's events into the host overlay (subtitleCues), replacing the side reader.
    var onSubtitleTapEvent: (@Sendable (Int32, EmbeddedSubtitleDecoder.SubtitleEvent) -> Void)?

    var subtitleTapActive: Bool {
        subtitleTapLock.lock(); defer { subtitleTapLock.unlock() }
        return !subtitleTapRoutes.isEmpty
    }

    func subtitleTapCoversStream(_ idx: Int32) -> Bool {
        subtitleTapLock.lock(); defer { subtitleTapLock.unlock() }
        return subtitleTapRoutes[idx] != nil
    }

    /// Request the native mov_text track in the init moov (#55). Call before `start()`.
    /// `aetherctl serve --native-subs N` uses this; a full session wires it automatically.
    public func requestNativeSubtitleTrack() {
        enableNativeSubtitleTrackForSession = true
    }

    /// Attach `count` fresh cue stores (one per declared text track) to the current producer (#55).
    /// Call after `start()`. `languages` and `sourceStreamIndices` are ordinal-aligned, nil-padded.
    public func attachNativeSubtitleStores(count: Int, languages: [String?] = [],
                                           sourceStreamIndices: [Int32?] = []) {
        guard count > 0 else { return }
        let stores = (0..<count).map { _ in NativeSubtitleCueStore() }
        let langs = (0..<count).map { i in i < languages.count ? languages[i] : nil }
        let indices = (0..<count).map { i in i < sourceStreamIndices.count ? sourceStreamIndices[i] : nil }
        // Guard the session arrays under restartLock: a runtime attach (this call, host thread) otherwise
        // races the pump thread iterating them in handleVideoShiftKnown and makeProducer's read (#55).
        restartLock.lock()
        nativeSubtitleCueStoresForSession = stores
        nativeSubtitleLanguagesForSession = langs
        nativeSubtitleSourceStreamIndicesForSession = indices
        let prod = producer
        restartLock.unlock()
        rebuildSubtitleTapRoutes()
        prod?.subtitleCueStores = stores
        prod?.nativeSubtitleLanguages = langs
        armSubtitleTap(on: prod)
    }

    /// Attach one store per non-bitmap subtitle track from the engine's demuxer (#55, all-tracks).
    /// Call after `start()`. Returns per-track languages for logging.
    @discardableResult
    public func attachAllNativeSubtitleStores() -> [String?] {
        // Decoder-name classifier: an exact-match Set of descriptor names here never matched TrackInfo.codec
        // (the libavcodec decoder name), so bitmap tracks leaked into the native mov_text store set.
        let text = (demuxer?.subtitleTrackInfos() ?? []).filter { !AetherEngine.isBitmapSubtitleCodec($0.codec) }
        let languages = text.map { $0.language }
        attachNativeSubtitleStores(count: text.count, languages: languages,
                                   sourceStreamIndices: text.map { Int32($0.id) })
        return languages
    }

    // MARK: - Subtitle pump tap (Sodalite#32)

    /// (Re)build the session tap routes from the current stores + stream indices. One
    /// EmbeddedSubtitleDecoder per demuxable text track, plain text (the native rendition carries no
    /// markup). Decoders live for the session, not the producer, so a restart's re-read dedups.
    private func rebuildSubtitleTapRoutes() {
        subtitleTapLock.lock()
        defer { subtitleTapLock.unlock() }
        subtitleTapRoutes.removeAll()
        guard let dem = demuxer else { return }
        let w = savedVideoConfig.map { Int32($0.codecpar.pointee.width) } ?? 1920
        let h = savedVideoConfig.map { Int32($0.codecpar.pointee.height) } ?? 1080
        for (ordinal, sidx) in nativeSubtitleSourceStreamIndicesForSession.enumerated() {
            guard let sidx, ordinal < nativeSubtitleCueStoresForSession.count,
                  let stream = dem.stream(at: sidx),
                  let decoder = EmbeddedSubtitleDecoder(stream: stream,
                                                        sourceVideoWidth: w > 0 ? w : 1920,
                                                        sourceVideoHeight: h > 0 ? h : 1080,
                                                        preserveASSMarkup: preserveASSMarkupForSubtitleTap)
            else { continue }
            subtitleTapRoutes[sidx] = (decoder, nativeSubtitleCueStoresForSession[ordinal])
        }
        if !subtitleTapRoutes.isEmpty {
            EngineLog.emit(
                "[HLSVideoEngine] subtitle pump tap armed for streams \(subtitleTapRoutes.keys.sorted())",
                category: .session
            )
        }
    }

    /// Wire the tap onto a producer (initial + every restart).
    private func armSubtitleTap(on prod: HLSSegmentProducer?) {
        guard let prod else { return }
        subtitleTapLock.lock()
        let indices = Set(subtitleTapRoutes.keys)
        subtitleTapLock.unlock()
        prod.subtitleTapStreamIndices = indices
        if indices.isEmpty {
            prod.subtitleTapObserver = nil
        } else {
            prod.subtitleTapObserver = { [weak self] idx, pkt, tb in
                self?.handleSubtitleTapPacket(streamIndex: idx, packet: pkt, timeBase: tb)
            }
        }
    }

    /// Pump-thread callback: decode the tapped packet into its ordinal's cue store. Text subtitle decode
    /// is a parse (microseconds), so it runs inline; the lock serializes an abandoned producer's tail
    /// against the replacement producer.
    private func handleSubtitleTapPacket(streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>,
                                         timeBase: AVRational) {
        subtitleTapLock.lock()
        defer { subtitleTapLock.unlock() }
        guard let route = subtitleTapRoutes[streamIndex] else { return }
        if let event = route.decoder.decode(packet: packet, streamTimeBase: timeBase),
           !event.cues.isEmpty {
            route.store.appendCues(event.cues)
            onSubtitleTapEvent?(streamIndex, event)
        }
    }

    /// Per-frame fallback durations in source time_base for backfilling `pkt->duration`
    /// when the matroska demuxer drops per-block durations. Computed once in `start()`.
    private var videoFallbackDurationPts: Int64 = 40
    private var audioFallbackDurationPts: Int64 = 0

    /// First video keyframe PTS in source video TB. Non-zero on MKV remuxes where the IDR lives
    /// past PTS=0. Producer subtracts this from every packet so seg-0's tfdt aligns with the
    /// playlist's cumulative-EXTINF origin of 0 (AVPlayer stalls at `waitingToPlay` otherwise).
    private var firstKeyframePts: Int64 = 0

    /// `firstKeyframePts` in seconds; diagnostic. The authoritative clock translation is
    /// `playlistShiftSeconds` (updated dynamically per gate open).
    public private(set) var firstKeyframeSeconds: Double = 0

    /// Result of the stream-copy / FLAC-bridge / video-only cascade. Possible values:
    /// `"Stream-copy (EAC3+JOC Atmos)"`, `"Stream-copy (<CODEC>)"`, `"<CODEC> → FLAC bridge"`.
    /// nil when no audio pipeline is live.
    public internal(set) var audioPipelineDescription: String?

    /// Producer's `videoShiftPts` in seconds, updated on every gate open. AVPlayer clock =
    /// `source_pts - playlistShiftSeconds`. Lock-guarded: written on pump thread, read on others.
    public var playlistShiftSeconds: Double {
        shiftLock.lock(); defer { shiftLock.unlock() }; return _playlistShiftSeconds
    }
    private func setPlaylistShiftSeconds(_ value: Double) {
        shiftLock.lock(); _playlistShiftSeconds = value; shiftLock.unlock()
    }
    private let shiftLock = NSLock()
    private var _playlistShiftSeconds: Double = 0

    private var sourceVideoTbSeconds: Double = 1.0 / 1000.0

    /// Source bitrate in bps for HLS BANDWIDTH/AVERAGE-BANDWIDTH. 0 when libavformat can't
    /// compute it; callers fall back to an over-declared estimate to avoid CoreMediaErrorDomain -12318.
    private var sourceBitrate: Int64 = 0

    /// Fires on each gate open (initial + restart) so AetherEngine keeps its shift in step
    /// for subtitle cue lookup.
    var onPlaylistShiftChanged: (@Sendable (Double) -> Void)?

    /// Fires when AVKit scrub drives a producer restart (AetherEngine#38). `(true, playlistTime)`
    /// at restart-run start; `(false, nil)` when settled. `playlistTime` folds with
    /// `playlistShiftSeconds` onto the source-PTS `seekTarget`.
    var onSeekStateChanged: (@Sendable (Bool, Double?) -> Void)?

    /// Source stall/reconnect transitions from the main demuxer's `AVIOReader` (#85). Forwarded to
    /// `demuxer` at every install site (start + live/restart reopen); the side-audio demuxer stays unwired.
    var onNetworkPhaseChanged: (@Sendable (ReaderNetworkPhase) -> Void)?

    /// AVPlayer's rendered (playlist-axis) position, readable off the main actor. Wired by AetherEngine
    /// to a thread-safe mirror of the host clock. Used to re-anchor the producer on AVPlayer's REAL
    /// position when a VOD backpressure wedge breaks (#65).
    var currentPlaybackPositionProvider: (@Sendable () -> Double?)?

    /// Whether AVPlayer wants to play (`timeControlStatus != .paused`), readable off the main actor. Wired
    /// by AetherEngine to a thread-safe mirror and threaded onto every producer so the VOD backpressure
    /// wedge detector suspends while the consumer is paused (a paused player issues no forward fetch, so its
    /// frozen fetch target is not a wedge — issue #65 pause false-positive).
    var playIntentProvider: (@Sendable () -> Bool)?

    /// Deep copy of AVCodecParameters decoupled from the demuxer's lifetime. Raw pointers into
    /// AVStreams become use-after-free on live reopen (avformat_close_input frees them while the
    /// continuation producer still reads via saved configs). Freed after pump unwinds.
    final class OwnedCodecParameters: @unchecked Sendable {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        init?(copying src: UnsafePointer<AVCodecParameters>) {
            guard let copy = avcodec_parameters_alloc() else { return nil }
            guard avcodec_parameters_copy(copy, src) >= 0 else {
                var c: UnsafeMutablePointer<AVCodecParameters>? = copy
                avcodec_parameters_free(&c)
                return nil
            }
            self.ptr = copy
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    private var ownedCodecParams: [OwnedCodecParameters] = []

    /// In-flight live reopen demuxer, registered before its blocking open so `stop()` can abort it
    /// (prevents orphan reconnect loops across channel zaps).
    var reopenDemuxer: Demuxer?
    /// Fires on live program-boundary rebase: `(newShiftSeconds, seamOutputSeconds)`. AetherEngine
    /// defers applying the shift until playback crosses `seamOutputSeconds` so the clock doesn't jump.
    var onPlaylistShiftRebased: (@Sendable (Double, Double) -> Void)?
    /// Fires on `PumpExitReason.sourceReplay`; host must re-negotiate a fresh session.
    var onLiveSourceReset: (@Sendable () -> Void)?
    /// Session-long FLAC bridge for codecs illegal in fMP4. Engine-owned (not producer-owned) so
    /// encoder state survives producer restarts; `startSegment()` rebases PTS on each restart.
    var audioBridge: AudioBridge?
    private var segmentPlan: [Segment] = []

    /// Guards subsystem refs + `sessionEpoch`. Never held across waits or network I/O so
    /// `stop()` on the main thread is never blocked behind a restart's 5 s waitForFinish.
    let restartLock = NSLock()

    /// Serializes restart requests among themselves. Held across waits (unlike `restartLock`);
    /// only other restarts contend on it.
    private let restartGate = NSLock()

    /// Coalesces burst seek restart requests (#35). Mutated only under `restartLock`.
    private var restartCoalescer = RestartCoalescer()

    /// #65 wedge re-anchor storm guard (under `restartLock`). If AVPlayer never resumes requesting even
    /// after we re-anchor the producer on its real position, the producer re-wedges at the same spot;
    /// cap consecutive re-anchors to the same position so we stop spinning restarts (the clock is already
    /// reconciled by the engine-seek deadline path, so the engine no longer lies even if we give up here).
    var consecutiveWedgeReanchors = 0
    var lastWedgeReanchorPosition = -Double.greatestFiniteMagnitude
    static let maxConsecutiveWedgeReanchors = 5

    /// #93 residual: a stalled AVPlayer sometimes never resumes REQUESTING after a wedge re-anchor
    /// (device: plain playback, one -15628 errorLog, then zero segment GETs while parked in
    /// waitingToMinimizeStalls forever, item never fails). The served playlist alone cannot reach
    /// it, so after this grace window with no fetch and intact play intent the engine asks the
    /// host to re-engage the consumer (zero-tolerance nudge seek, the same effect a manual
    /// back-out had). Fired at most once per re-anchor attempt; the re-anchor cap bounds the storm.
    var onConsumerReengageNeeded: (@Sendable (Double) -> Void)?
    static let consumerReengageGraceSeconds: TimeInterval = 6.0

    /// Locked snapshot/compare of the session epoch so detached watchdogs can verify the session
    /// they were armed for is still the live one (stop() bumps the epoch).
    func sessionEpochSnapshot() -> UInt64 {
        restartLock.lock()
        defer { restartLock.unlock() }
        return sessionEpoch
    }
    func isSessionEpochCurrent(_ epoch: UInt64) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return sessionEpoch == epoch
    }

    /// Bumped by `stop()` under `restartLock`. Restarts re-validate before installing the new
    /// producer; a mid-restart stop() wins and the restart unwinds.
    private var sessionEpoch: UInt64 = 0

    /// Fires once per session on first HDR10+ T.35 detection so AetherEngine can upgrade
    /// `videoFormat` from `.hdr10` to `.hdr10Plus`. Debounced across producer restarts.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    private var hasReportedHDR10Plus = false
    private let hdr10PlusLock = NSLock()

    /// Target segment duration (4 s). Apple spec recommends 6 s; 4 s cuts ~370 ms first-segment
    /// latency on a 24 fps 1440p LAN source and stays within the spec's 2-6 s range.
    static let targetSegmentDuration: Double = 4.0

    /// Cue-prewarm seek deadline. MKV Cues resolve in under 1 s; a missing/out-of-bounds index
    /// degrades into a multi-GB linear scan. Beyond this, abort and build a uniform-stride plan.
    static let cuePrewarmTimeout: TimeInterval = 10.0

    /// SegmentCache retention budget for a VOD session (#93 / Sodalite#32): capped at 2 GiB and
    /// clamped to a quarter of the tmp volume's available capacity, so a nearly-full device never
    /// trades playback headroom for seek history. Live passes 0 (window-only pruning; the sliding
    /// playlist already dropped everything behind the window, so retention would serve nothing).
    static func vodRetentionBudgetBytes(volumeAvailableBytes: Int64?) -> Int {
        let cap = 2 << 30
        guard let available = volumeAvailableBytes else { return cap }
        return min(cap, max(0, Int(available / 4)))
    }

    // MARK: - Measurement spike: sliding-window prototype (superseded)
    //
    // Sliding MEDIA-SEQUENCE is now unconditional for live (see `LiveWindowSizing`).
    // The 2026-06-07 macOS spike (_liveSlidingPrototype flag, h264-ts-sample.ts, 300 s):
    //   - Baseline (append-only EVENT): phys flat after 90 s (~7088 MB); resident flat ~40 MB.
    //   - Sliding prototype: phys flat (~8311 MB); resident declining (-0.83 MB/min, eviction working)
    //     but AVPlayer STALLED at 81 s (lost playlist window when segments fell off the back).
    // Root cause of stall: EVENT-vs-removal contradiction + uncoordinated MEDIA-SEQUENCE slide.
    // Fix: `.live` playlist type + `minSafeSegments` floor (keeps AVPlayer's live-edge buffer
    // inside the window). macOS phys_footprint is not representative of tvOS jetsam pressure
    // (~500-800 MB budget vs 7-8 GB on macOS); device-level tvOS measurement still open.

    public init(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        dvModeAvailable: Bool = true,
        displaySupportsHDR: Bool = true,
        keepDvh1TagWithoutDV: Bool = false,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioSourceStreamIndexOverride: Int32? = nil,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLiveSession: Bool = false,
        dvrWindowSeconds: Double? = nil,
        liveSourceCadenceHint: Double? = nil,
        preopenedDemuxer: Demuxer? = nil,
        sourceReopenableByURL: Bool = true,
        companionAudioReader: IOReader? = nil,
        probesize: Int64? = nil,
        maxAnalyzeDuration: Int64? = nil
    ) {
        self.sourceURL = url
        self.sourceHTTPHeaders = sourceHTTPHeaders
        // Caller-bounded find_stream_info budget (#68); nil keeps the .playback default. Applied only to the
        // fallback open / live reopen here; the happy path reuses the already-budgeted preopenedDemuxer.
        self.openProfile = DemuxerOpenProfile.playback.withProbeBudget(
            probesize: probesize, maxAnalyzeDuration: maxAnalyzeDuration)
        self.dvModeAvailable = dvModeAvailable
        self.displaySupportsHDR = displaySupportsHDR
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.audioSourceStreamIndexOverride = audioSourceStreamIndexOverride
        self.audioBridgeMode = audioBridgeMode
        self.isLiveSession = isLiveSession
        self.dvrWindowSeconds = dvrWindowSeconds
        self.liveSourceCadenceHint = liveSourceCadenceHint
        // Bursty ingest sources whose upstream cadence exceeds 1.5x our cut target can't honor
        // LL-HLS blocking reload (-15410, device repro 2026-06-11). For those, disable blocking
        // reload and raise TARGETDURATION to cadence so plain 1.5x-TD patience covers the gap.
        self.liveBlockingReloadEnabled = liveSourceCadenceHint
            .map { $0 <= Self.targetSegmentDuration * 1.5 } ?? true
        self.liveTargetDurationFloorSeconds = liveSourceCadenceHint.map { ceil($0) }
        self.preopenedDemuxer = preopenedDemuxer
        self.sourceReopenableByURL = sourceReopenableByURL
        self.companionAudioReader = companionAudioReader
    }

    /// When true, `start()` skips the VOD duration guard / cue prewarm / precomputed plan and
    /// uses the forward-only live cut mode (producer cuts at each IDR past the duration target).
    let isLiveSession: Bool

    /// False for IOReader-backed sources (`aether-custom://source` placeholder); `handlePumpFinished`
    /// surfaces loss via `onLiveSourceReset` immediately instead of burning 6 reopen attempts.
    let sourceReopenableByURL: Bool

    /// Upstream segment cadence for custom-ingest live sessions (`LiveIngestSourceInfo`). nil for URL
    /// live sources and VOD.
    private let liveSourceCadenceHint: Double?

    /// Demuxed audio rendition reader for live HLS ingest. When the main demuxer finds no audio and
    /// this is non-nil, `start()` opens `sideAudioDemuxer` over it. Engine owns the side demuxer, not
    /// this reader (owned by the host's main reader). nil for muxed-audio sessions.
    private let companionAudioReader: IOReader?

    /// Whether the local live playlist may advertise LL-HLS CAN-BLOCK-RELOAD (derived from cadence hint).
    private let liveBlockingReloadEnabled: Bool

    /// TARGETDURATION floor = ceil(upstream cadence) for bursty ingest; nil when no cadence hint.
    private let liveTargetDurationFloorSeconds: Double?

    /// DVR window in seconds; nil = live-only (window still bounded to `liveOnlyFloorSeconds`).
    private let dvrWindowSeconds: Double?

    /// Bridge encoder for codecs illegal in fMP4 (TrueHD, DTS, DTS-HD MA, MP3, Opus,
    /// EAC3 from MKV without dec3 extradata).
    let audioBridgeMode: AudioBridgeMode

    /// Pre-opened demuxer reused by `start()` to skip `avformat_find_stream_info` (~1-3 s on slow CDN).
    /// Consumed in `start()`; unconsumed instances are closed by `stop()`.
    private var preopenedDemuxer: Demuxer?

    /// Open profile carrying the caller-bounded probe budget (#68) for the fallback open and live reopen;
    /// `.playback` unless the caller set `LoadOptions.probesize` / `maxAnalyzeDuration`. Read in the
    /// `+LiveReopen` extension, so it cannot be file-private.
    let openProfile: DemuxerOpenProfile


    // MARK: - Public API

    public func start() throws -> URL {
        guard demuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the source; reuse the pre-opened demuxer when available (saves ~1-3 s on slow CDN).
        let dem: Demuxer
        if let preopened = preopenedDemuxer {
            dem = preopened
            preopenedDemuxer = nil
        } else {
            dem = Demuxer()
            do {
                try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders, profile: openProfile, isLive: isLiveSession)
            } catch {
                throw HLSVideoEngineError.openFailed(reason: "\(error)")
            }
        }
        demuxer = dem
        dem.onNetworkPhaseChanged = onNetworkPhaseChanged   // surface source stall/reconnect to playbackPhase (#85)

        let videoIndex = dem.videoStreamIndex
        guard videoIndex >= 0, let videoStream = dem.stream(at: videoIndex) else {
            throw HLSVideoEngineError.noVideoStream
        }
        let codecpar = videoStream.pointee.codecpar!
        let isHEVC = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        let isH264 = codecpar.pointee.codec_id == AV_CODEC_ID_H264
        let isAV1 = codecpar.pointee.codec_id == AV_CODEC_ID_AV1

        // Log codecpar for AVPlayer -11821 triage: interlaced field_order and malformed Annex-B
        // extradata are the two candidates when channels mux cleanly but VT chokes post readyToPlay.
        let extraSize = Int(codecpar.pointee.extradata_size)
        var extraHead = "none"
        if extraSize > 0, let extra = codecpar.pointee.extradata {
            let n = min(extraSize, 8)
            extraHead = (0..<n).map { String(format: "%02x", extra[$0]) }.joined()
        }
        EngineLog.emit(
            "[HLSVideoEngine] video codecpar: codec=\(codecpar.pointee.codec_id.rawValue) "
            + "\(codecpar.pointee.width)x\(codecpar.pointee.height) "
            + "profile=\(codecpar.pointee.profile) level=\(codecpar.pointee.level) "
            + "fieldOrder=\(codecpar.pointee.field_order.rawValue) "
            + "extradata=\(extraSize)B head=\(extraHead)",
            category: .session
        )

        // AV1: gated on VTCapabilityProbe.av1Available (false on all current Apple TV chips;
        // load() routes AV1 to SoftwarePlaybackHost instead). VP9: excluded despite VT HW
        // decode capability because AVPlayer's HLS manifest parser rejects the `vp09` CODECS
        // attribute; load() routes VP9 to SoftwarePlaybackHost.
        let av1OK = isAV1 && VTCapabilityProbe.av1Available
        guard isHEVC || isH264 || av1OK else {
            throw HLSVideoEngineError.unsupportedCodec(rawCodecID: codecpar.pointee.codec_id.rawValue)
        }

        let videoTimeBase = videoStream.pointee.time_base
        if videoTimeBase.num > 0, videoTimeBase.den > 0 {
            sourceVideoTbSeconds = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        }
        let durationSeconds = dem.duration
        let plan: [Segment]
        if isLiveSession {
            sourceBitrate = dem.bitRate
            self.firstKeyframePts = 0
            self.firstKeyframeSeconds = 0
            plan = []
            EngineLog.emit(
                "[HLSVideoEngine] LIVE session: skipping duration guard / prewarm / plan "
                + "(dem.duration=\(String(format: "%.1f", durationSeconds))s, producer cuts segments forward)",
                category: .session
            )
        } else {
            guard durationSeconds > 0 else {
                throw HLSVideoEngineError.zeroDuration
            }
            sourceBitrate = dem.bitRate

            // 2. Prewarm MKV Cues so libavformat's keyframe index is populated (1-2 byte-range reads).
            //    Bounded: a missing/out-of-bounds Cues index degrades into a multi-GB linear scan;
            //    abort past the deadline and fall back to the uniform-stride plan.
            let prewarmStart = DispatchTime.now()
            let prewarmOK = dem.seekBounded(to: durationSeconds * 0.5, timeout: Self.cuePrewarmTimeout)
            let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
            if prewarmOK {
                EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", durationSeconds * 0.5))s took \(String(format: "%.1f", prewarmMs))ms")
            } else {
                EngineLog.emit("[HLSVideoEngine] cue prewarm: capped at \(String(format: "%.1f", prewarmMs))ms (no usable Cues index — index points past EOF or is absent); building plan from whatever keyframes were scanned")
            }

            // 3. Build the segment plan. Uses the same cut algorithm as libavformat's hls muxer
            //    (first IDR at-or-after `(segIdx+1) * hls_time`); falls back to uniform stride
            //    if the index has < 2 entries (restart machinery handles any plan/muxer drift).
            let keyframes = dem.indexedKeyframes(streamIndex: videoIndex)
            let indexTrustworthy = Self.keyframeIndexIsTrustworthy(
                keyframes: keyframes,
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            if keyframes.count >= 2, indexTrustworthy {
                plan = Self.buildKeyframeSegmentPlan(
                    keyframes: keyframes,
                    videoTimeBase: videoTimeBase,
                    sourceDurationSeconds: durationSeconds
                )
                let firstKeyframePts = keyframes.sorted().first ?? 0
                self.firstKeyframePts = firstKeyframePts
                let firstKeyframeSeconds = Double(firstKeyframePts) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                self.firstKeyframeSeconds = firstKeyframeSeconds
                let videoStreamStart = videoStream.pointee.start_time
                let formatStart = dem.formatStartTime
                EngineLog.emit(
                    "[HLSVideoEngine] segment plan: keyframe-aligned, \(keyframes.count) IRAPs → \(plan.count) segments " +
                    "[firstKeyframePts=\(firstKeyframePts) (\(String(format: "%.3f", firstKeyframeSeconds))s) " +
                    "videoStream.start_time=\(videoStreamStart) format.start_time=\(formatStart)us " +
                    "plan[0].startSeconds=\(String(format: "%.3f", plan.first?.startSeconds ?? -1))]",
                    category: .session
                )
            } else {
                // Anchor the uniform plan at the content start so seg 0 is the first real keyframe, not an
                // empty source-0 segment the producer never emits (which strands AVPlayer's seg0 fetch; #64
                // follow-up). Prefer the first indexed keyframe; fall back to the video stream start_time.
                let sorted = keyframes.sorted()
                let streamStart = videoStream.pointee.start_time
                let anchorPts = sorted.first ?? (streamStart != Int64.min ? max(0, streamStart) : 0)
                plan = Self.buildUniformSegmentPlan(
                    videoTimeBase: videoTimeBase,
                    sourceDurationSeconds: durationSeconds,
                    startPts0: anchorPts
                )
                self.firstKeyframePts = anchorPts
                self.firstKeyframeSeconds = Double(anchorPts) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                // A sparse/clustered index (MPEG-TS / M2TS: no Cues, only what find_stream_info + the
                // mid-file seek scanned) would otherwise build a multi-thousand-second first segment that
                // the frag_custom muxer buffers whole in RAM (#64). A bunched index (remote MKV whose Cues
                // tail read failed: only open-time keyframes, all within the first few seconds) would build
                // a single whole-file segment AVPlayer loads zero tracks from (#91). Report both witnesses.
                let tb = (videoTimeBase.num > 0 && videoTimeBase.den > 0)
                    ? Double(videoTimeBase.num) / Double(videoTimeBase.den) : 0
                var largestGapSeconds = 0.0
                if tb > 0, sorted.count >= 2 {
                    for i in 1..<sorted.count {
                        let g = Double(sorted[i] - sorted[i - 1]) * tb
                        if g > largestGapSeconds { largestGapSeconds = g }
                    }
                }
                let coverageSeconds = (tb > 0 && sorted.count >= 2)
                    ? Double(sorted[sorted.count - 1] - sorted[0]) * tb : 0
                let reason = keyframes.count < 2
                    ? "\(keyframes.count) IRAPs in index, need >=2"
                    : "index unusable (\(keyframes.count) IRAPs, coverage=\(String(format: "%.1f", coverageSeconds))s, largestGap=\(String(format: "%.1f", largestGapSeconds))s)"
                EngineLog.emit(
                    "[HLSVideoEngine] segment plan: uniform stride fallback (\(reason), anchorPts=\(anchorPts))",
                    category: .session
                )
            }
        }

        // 4. Classify DV variant; per-profile policy in `resolveCodecRoute`.
        let route = try resolveCodecRoute(codecpar: codecpar)
        let codecTagOverride = route.codecTagOverride
        let videoRange = route.videoRange
        let primaryCodecs = route.primaryCodecs
        let supplementalCodecs = route.supplementalCodecs
        let stripDolbyVisionMetadata = route.stripDolbyVisionMetadata
        let convertP7ToProfile81 = route.convertP7ToProfile81
        let rewriteDoviConfigTo81 = route.rewriteDoviConfigTo81
        let dvVariant = route.dvVariant

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))

        let avgFR = videoStream.pointee.avg_frame_rate
        let frameRate: Double? = (avgFR.den > 0 && avgFR.num > 0)
            ? Double(avgFR.num) / Double(avgFR.den)
            : nil
        // HDCP-LEVEL omitted: local loopback has no DRM scope, and emitting TYPE-1 caused
        // AVFoundationErrorDomain -11868 / tracks count=0 when the HDMI link's HDCP 2.2
        // negotiation state didn't match (Vincent test 2026-05-26, HDR10 panel).
        let hdcpLevel: String? = nil

        // 5. Rebuild hvcC from in-band parameter sets when numOfArrays=0 (DV P5 MP4 encoders
        //    that ship VPS/SPS/PPS per-IRAP instead of in the config record, #19 Wandering Earth 2).
        //    Without VPS/SPS/PPS in hvcC, AVPlayer fails the dvh1 sample entry with CME -4.
        let hevcExtradataOverride = rebuildHEVCExtradataWithInBandParameterSets(
            demuxer: dem,
            videoStreamIndex: videoIndex,
            codecpar: codecpar
        )
        if let rebuilt = hevcExtradataOverride {
            EngineLog.emit(
                "[HLSVideoEngine] rebuilt hvcC with in-band parameter sets: "
                + "\(codecpar.pointee.extradata_size) B → \(rebuilt.count) B",
                category: .session
            )
        }

        // 6. Reset demuxer cursor to 0 (cue prewarm moved it mid-file). Skipped for live
        //    (no prewarm, forward-only feed).
        if !isLiveSession {
            dem.seek(to: 0)
        }

        // volumeAvailableCapacityForImportantUsage is unavailable on tvOS; the plain capacity key
        // exists on every platform and is close enough for the quarter-of-free-space clamp.
        #if os(tvOS)
        let availableBytes = (try? URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
        #else
        let availableBytes = (try? URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        #endif
        let retentionBudget = isLiveSession
            ? 0
            : Self.vodRetentionBudgetBytes(volumeAvailableBytes: availableBytes)
        let segmentCache = SegmentCache(retentionBudgetBytes: retentionBudget)
        self.cache = segmentCache
        EngineLog.emit(
            "[HLSVideoEngine] segment retention budget: \(retentionBudget / (1 << 20)) MiB "
            + "(volumeAvailable=\(availableBytes.map { "\($0 / (1 << 20)) MiB" } ?? "unknown"))",
            category: .session
        )

        // DV P5 MP4 encoders can omit the HEVC SPS VUI and `colr` atom (#19 Wandering Earth 2 WEB-DL):
        // color_trc/primaries/space all unspecified, so AVPlayer's DV decoder won't engage on the dvh1
        // sample entry (MKV reads Colour element directly into codecpar; MP4 demuxer has no fallback).
        // Forcing the canonical IPT-PQ-c2 tuple writes `colr nclx` so AVPlayer sees the PQ signal.
        // Primaries/transfer/matrix are spec-fixed for P5, so this is a repair. Range is preserved if
        // already signaled (full-range P5 is legal, #20); unspecified defaults to limited.
        let p5ColorOverride: MP4SegmentMuxer.ColorOverride?
        if dvVariant == .profile5 {
            let sourceRange = codecpar.pointee.color_range
            p5ColorOverride = MP4SegmentMuxer.ColorOverride(
                primaries: AVCOL_PRI_BT2020,
                trc: AVCOL_TRC_SMPTE2084,
                space: AVCOL_SPC_BT2020_NCL,
                range: sourceRange == AVCOL_RANGE_UNSPECIFIED
                    ? AVCOL_RANGE_MPEG
                    : sourceRange
            )
        } else {
            p5ColorOverride = nil
        }
        // Deep-copy codecpar so configs outlive the demuxer (live reopen closes it; see OwnedCodecParameters).
        guard let ownedVideoParams = OwnedCodecParameters(copying: codecpar) else {
            throw HLSVideoEngineError.openFailed(reason: "codecpar copy failed")
        }
        ownedCodecParams.append(ownedVideoParams)
        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: UnsafePointer(ownedVideoParams.ptr),
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride,
            stripDolbyVisionMetadata: stripDolbyVisionMetadata,
            convertP7ToProfile81: convertP7ToProfile81,
            rewriteDoviConfigTo81: rewriteDoviConfigTo81,
            colorOverride: p5ColorOverride,
            extradataOverride: hevcExtradataOverride
        )
        self.videoStreamIndex = videoIndex
        self.savedVideoConfig = videoConfig
        self.segmentPlan = plan

        // #93 residual: anchor the FIRST producer at the session's start position instead of seg0.
        // A resume start otherwise produces seg0 (torn down and discarded seconds later when
        // AVPlayer's initial seek fetches the resume segment), restarts, and the fetch/restart race
        // can 404 the item into a host reload (device: double spinner). The baseIndex > 0 anchor is
        // the battle-tested restart path (gate at plan[base].startPts, tfdt continuity per 4.9.1).
        if !isLiveSession, let startSeconds = initialStartSeconds, startSeconds > 0 {
            initialProducerBaseIndex = segmentIndexForPlaylistTime(startSeconds)
            EngineLog.emit(
                "[HLSVideoEngine] initial producer anchored at idx=\(initialProducerBaseIndex) "
                + "(startPosition=\(String(format: "%.2f", startSeconds))s)",
                category: .session
            )
        }

        // Fallback duration from avg_frame_rate for MKVs that drop TrackEntry DefaultDuration
        // (HandBrake/web-rip pipelines). Without it, trun.last.duration=0 and AVPlayer parks on
        // WaitingToMinimizeStallsReason. 25 fps / 1 ms TB = 40 ticks; 23.976 fps = 41 ticks.
        let videoFallbackDuration: Int64 = {
            guard avgFR.num > 0 && avgFR.den > 0,
                  videoTimeBase.num > 0, videoTimeBase.den > 0 else {
                return 40 // 25 fps / 1 ms TB defensive default
            }
            let num = Int64(avgFR.den) * Int64(videoTimeBase.den)
            let den = Int64(avgFR.num) * Int64(videoTimeBase.num)
            return max(1, num / den)
        }()
        self.videoFallbackDurationPts = videoFallbackDuration

        // 6a-pre. Open a side demuxer for demuxed-audio live HLS ingest (separate rendition
        //     playlist). Companion classifies its first segment to select "mpegts" vs "aac"
        //     format hint. Failure here fails the load so the host falls back to server-muxed.
        let audioDem: Demuxer
        if isLiveSession, dem.audioStreamIndex < 0, let companion = companionAudioReader {
            let formatHint: String
            if let info = companion as? LiveIngestSourceInfo {
                guard let resolved = info.resolveSegmentFormatHint() else {
                    // Terminal ingest (or no first segment inside the
                    // resolve bound): the companion can't deliver audio.
                    throw HLSVideoEngineError.openFailed(
                        reason: "demuxed-audio companion produced no classifiable first segment")
                }
                formatHint = resolved
            } else {
                // Non-ingest custom companions keep the previous TS contract.
                formatHint = "mpegts"
            }
            let side = Demuxer()
            do {
                try side.open(reader: companion, formatHint: formatHint, isLive: true)
            } catch {
                throw HLSVideoEngineError.openFailed(
                    reason: "demuxed-audio companion open failed (\(error))")
            }
            guard side.audioStreamIndex >= 0,
                  let sideAudioStream = side.stream(at: side.audioStreamIndex) else {
                side.close()
                throw HLSVideoEngineError.openFailed(
                    reason: "demuxed-audio companion has no audio stream")
            }
            // Packed audio: anchor synthesized side-audio clock on the ID3 PRIV program-clock timestamp
            // rescaled into the side stream's own time base (raw "aac" demuxer: 1/28224000).
            if formatHint == "aac" {
                guard let offset90k = (companion as? LiveIngestSourceInfo)?
                    .packedAudioTimestampOffset90k else {
                    side.close()
                    throw HLSVideoEngineError.openFailed(
                        reason: "packed-audio companion carries no program-clock timestamp")
                }
                let tb = sideAudioStream.pointee.time_base
                packedSideAudioStartPts = av_rescale_q(
                    offset90k, AVRational(num: 1, den: 90000), tb)
            }
            restartLock.lock()
            sideAudioDemuxer = side
            restartLock.unlock()
            audioDem = side
            companionAudioTracks = side.audioTrackInfos()
            EngineLog.emit(
                "[HLSVideoEngine] demuxed-audio companion opened: format=\(formatHint) "
                + "side demuxer audioStreamIndex=\(side.audioStreamIndex)"
                + (packedSideAudioStartPts.map { " packedStartPts=\($0) (side TB)" } ?? ""),
                category: .session
            )
        } else {
            audioDem = dem
        }

        // 6a. Audio routing: stream-copy (common case: ec-3/Atmos JOC) → FLAC bridge (EINVAL on
        //     EAC3-from-MKV without dec3) → video-only. Override validated; stale index logs + falls back.
        var autoAudioStreamIndex = audioDem.audioStreamIndex
        // av_find_best_stream skips streams with empty codecpar (live TS probe bails early, -1381258232).
        // Fall back to first audio-type stream so the AAC repair below is reachable.
        if autoAudioStreamIndex < 0, isLiveSession {
            let byType = audioDem.firstAudioStreamIndexByType
            if byType >= 0 {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: av_find_best_stream found no usable audio "
                    + "(live probe left empty codecpar?); falling back to first "
                    + "audio-type stream \(byType)",
                    category: .session
                )
                autoAudioStreamIndex = byType
            }
        }
        let audioStreamIndex: Int32
        if let override = audioSourceStreamIndexOverride {
            if Self.isAudioStream(demuxer: audioDem, index: override) {
                audioStreamIndex = override
                EngineLog.emit(
                    "[HLSVideoEngine] audio: override accepted, sourceStreamIndex=\(override) (auto would have picked \(autoAudioStreamIndex))",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: override sourceStreamIndex=\(override) invalid (not an audio stream), falling back to auto=\(autoAudioStreamIndex)",
                    category: .session
                )
                audioStreamIndex = autoAudioStreamIndex
            }
        } else {
            audioStreamIndex = autoAudioStreamIndex
        }
        var streamCopyAudio: HLSSegmentProducer.AudioConfig?
        var bridgePreferred = false
        var audioHLSCodecs: String?

        if audioStreamIndex >= 0, let audioStream = audioDem.stream(at: audioStreamIndex) {
            let codecID = audioStream.pointee.codecpar.pointee.codec_id
            // Live MPEG-TS probe (KiKA repro): find_stream_info bails before decoding an audio frame,
            // leaving sample_rate=0. ASC synthesis and stream-copy both fail, silently degrading to
            // video-only. Fill 48 kHz stereo AAC-LC (Jellyfin live transcode + DVB/IPTV ADTS default).
            if isLiveSession, codecID == AV_CODEC_ID_AAC,
               audioStream.pointee.codecpar.pointee.sample_rate == 0 {
                audioStream.pointee.codecpar.pointee.sample_rate = 48000
                if audioStream.pointee.codecpar.pointee.ch_layout.nb_channels <= 0 {
                    av_channel_layout_default(&audioStream.pointee.codecpar.pointee.ch_layout, 2)
                }
                if audioStream.pointee.codecpar.pointee.profile < 0 {
                    audioStream.pointee.codecpar.pointee.profile = 1  // FF_PROFILE_AAC_LOW
                }
                EngineLog.emit(
                    "[HLSVideoEngine] audio: AAC stream had no codec parameters from the live "
                    + "probe; assuming 48 kHz stereo AAC-LC (Jellyfin live transcode default)",
                    category: .session
                )
            }
            let compat = AudioCodecCompat.from(codecID)
            // HE-AAC needs bridging only when there is no ASC (live ADTS/MPEG-TS): synthesized ASC
            // would declare LC at the SBR output rate, decoded as garbage by AudioToolbox (-11821).
            // Movie containers already carry a correct ASC so stream-copy works (AetherEngine#33).
            let acpForHE = audioStream.pointee.codecpar.pointee
            let hasASC = acpForHE.extradata != nil && acpForHE.extradata_size > 0
            let isHEAAC = acpForHE.codec_id == AV_CODEC_ID_AAC
                && Self.aacRequiresBridge(
                    profile: acpForHE.profile,
                    frameSize: acpForHE.frame_size,
                    hasASC: hasASC
                )
            if compat.requiresBridge || isHEAAC {
                bridgePreferred = true
                EngineLog.emit(
                    isHEAAC
                        ? "[HLSVideoEngine] audio: HE-AAC (profile=\(acpForHE.profile) frameSize=\(acpForHE.frame_size)), ADTS stream-copy would mis-signal SBR, bridging instead"
                        : "[HLSVideoEngine] audio: codec=\(compat) (bridge required), decoding + FLAC re-encode",
                    category: .session
                )
            } else if compat != .unsupported {
                // ADTS-AAC from MPEG-TS has no ASC in extradata, so mp4a/esds can't be built
                // (EINVAL/"Could not find tag for codec aac"). Synthesize ASC + clear TS codec_tag;
                // pump strips per-frame ADTS headers.
                let stripAdts = Self.prepareAACForFMP4(audioStream.pointee.codecpar)
                if stripAdts {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio: AAC/ADTS from TS — synthesised ASC + stripping ADTS for fMP4 stream-copy (no FLAC bridge)",
                        category: .session
                    )
                }
                // Deep-copy AFTER prepareAACForFMP4 so the synthesized ASC is included.
                guard let ownedAudioParams = OwnedCodecParameters(copying: audioStream.pointee.codecpar) else {
                    throw HLSVideoEngineError.openFailed(reason: "audio codecpar copy failed")
                }
                ownedCodecParams.append(ownedAudioParams)
                streamCopyAudio = HLSSegmentProducer.AudioConfig(
                    codecpar: UnsafePointer(ownedAudioParams.ptr),
                    timeBase: audioStream.pointee.time_base,
                    sourceStreamIndex: audioStreamIndex,
                    inputTimeBase: audioStream.pointee.time_base,
                    sourceTimeBase: audioStream.pointee.time_base,
                    bridge: nil,
                    stripAacAdts: stripAdts
                )
                // Audio fallback duration from codec-fixed frame sizes (AC3/EAC3=1536, AAC=1024).
                let acp = audioStream.pointee.codecpar.pointee
                let sampleRate = Int64(acp.sample_rate)
                let frameSamples: Int64 = {
                    if acp.frame_size > 0 { return Int64(acp.frame_size) }
                    switch acp.codec_id {
                    case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: return 1536
                    case AV_CODEC_ID_AAC: return 1024
                    case AV_CODEC_ID_MP3: return 1152
                    case AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC: return 4096
                    default: return 1024
                    }
                }()
                let audioTb = audioStream.pointee.time_base
                self.audioFallbackDurationPts = {
                    guard sampleRate > 0, audioTb.num > 0, audioTb.den > 0 else { return 1 }
                    let num = frameSamples * Int64(audioTb.den)
                    let den = sampleRate * Int64(audioTb.num)
                    return max(1, num / den)
                }()
                // Always `ec-3` per RFC 6381 (never `ec+3`: tvOS 26.5 enforces strict RFC 6381,
                // same as iOS; `ec+3` produced -11848/-15517, Vincent test 2026-05-26). JOC/Atmos
                // signaling lives in the per-segment `dec3` box, not the CODECS string (#34).
                // The only EAC3 case that can't stream-copy is EAC3-from-MKV without dec3 extradata;
                // `probeWriteHeader` in buildProducerWithAudioCascade catches and bridges that.
                let isJOC = compat == .eac3 && acp.profile == 30
                audioHLSCodecs = compat.hlsCodecsString
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) → stream-copy as `\(audioHLSCodecs ?? "?")` "
                    + "\(isJOC ? "[JOC=Atmos] " : "")"
                    + "(fallback duration=\(audioFallbackDurationPts) in audioTb \(audioTb.num)/\(audioTb.den))",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec id=\(codecID.rawValue) unsupported, video-only",
                    category: .session
                )
            }
        }

        // 6a-post. Packed side audio: one AAC frame in the side stream's TB. Computed after the
        //     codec repair above so frame_size/sample_rate are fully filled in.
        if packedSideAudioStartPts != nil, audioStreamIndex >= 0,
           let sideStream = audioDem.stream(at: audioStreamIndex) {
            let acp = sideStream.pointee.codecpar.pointee
            let samples = acp.frame_size > 0 ? Int64(acp.frame_size) : 1024
            let rate = acp.sample_rate > 0 ? Int64(acp.sample_rate) : 48000
            let tb = sideStream.pointee.time_base
            packedSideAudioFallbackDurationPts = (tb.num > 0 && tb.den > 0)
                ? max(1, samples * Int64(tb.den) / (rate * Int64(tb.num)))
                : 1
        }

        // #15: native subtitles requested but no host pre-populated the cue stores (the `aetherctl serve
        // --native-subs` path). Auto-attach one store per non-bitmap text track BEFORE the producer is
        // built: the producer's init applies the demuxer discard set, and the subtitle tap streams must
        // be in it (Sodalite#32; a post-init arm only ever saw open-time queued packets). The host's
        // full-session path sets these before start() (AetherEngine+Loading), so the isEmpty guard makes
        // this a no-op there. makeProducer threads the stores + tap onto the producer.
        if enableNativeSubtitleTrackForSession && nativeSubtitleCueStoresForSession.isEmpty {
            let textTracks = dem.subtitleTrackInfos().filter { !AetherEngine.isBitmapSubtitleCodec($0.codec) }
            if !textTracks.isEmpty {
                nativeSubtitleCueStoresForSession = textTracks.map { _ in NativeSubtitleCueStore() }
                nativeSubtitleLanguagesForSession = textTracks.map { $0.language }
                nativeSubtitleSourceStreamIndicesForSession = textTracks.map { Int32($0.id) }
                EngineLog.emit(
                    "[HLSVideoEngine] #15 auto-attached \(nativeSubtitleCueStoresForSession.count) native "
                    + "subtitle store(s) for the WebVTT rendition "
                    + "(langs=\(nativeSubtitleLanguagesForSession.map { $0 ?? "und" }))",
                    category: .session
                )
            }
        }

        // 6b. Run the stream-copy / FLAC-bridge / video-only cascade.
        let prod: HLSSegmentProducer
        prod = try buildProducerWithAudioCascade(
            preferBridge: bridgePreferred,
            streamCopyAudio: streamCopyAudio,
            sourceAudioStreamIndex: audioStreamIndex,
            sourceAudioStream: audioStreamIndex >= 0 ? audioDem.stream(at: audioStreamIndex) : nil,
            audioHLSCodecs: &audioHLSCodecs
        )
        self.producer = prod
        self.activeAudioSourceStreamIndex = savedAudioConfig != nil ? audioStreamIndex : -1

        // 7. Wire provider, server, and URL.
        let manifestCodecs = audioHLSCodecs.map { "\(primaryCodecs),\($0)" } ?? primaryCodecs
        let prov = VideoSegmentProvider(
            cache: segmentCache,
            segments: plan,
            codecsString: manifestCodecs,
            supplementalCodecs: supplementalCodecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel,
            sourceBitrate: sourceBitrate,
            isLive: isLiveSession,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: Self.targetSegmentDuration,
                dvrWindowSeconds: dvrWindowSeconds
            ),
            blockingReloadEnabled: liveBlockingReloadEnabled,
            targetDurationFloorSeconds: liveTargetDurationFloorSeconds,
            restartHandler: isLiveSession ? nil : { [weak self] idx in
                self?.requestRestart(at: idx)
            },
            restartActivity: isLiveSession ? nil : { [weak self] in
                self?.restartInFlight ?? false
            },
            activeProducerBase: isLiveSession ? nil : { [weak self] in
                self?.currentProducerBaseIndex
            },
            // #93 residual: the first producer may be anchored at the resume segment; without this
            // the cold-start heuristic (abs(index - lastRestartIndex) > 2) restarts it immediately.
            initialRestartIndex: initialProducerBaseIndex,
            nativeSubtitleStores: nativeSubtitleCueStoresForSession,
            nativeSubtitleLanguages: nativeSubtitleLanguagesForSession,
            nativeSubtitleRenditionInfos: nativeSubtitleRenditionInfosForSession,
            stripASSMarkupInVTT: preserveASSMarkupForSubtitleTap,
            nativeSubtitleDefaultOrdinal: nativeSubtitleDefaultOrdinal,
            nativeSubtitleWholeProgram: nativeSubtitleWholeProgram,
            currentShiftSeconds: { [weak self] in (self?.playlistShiftSeconds ?? 0) + (self?.subtitleStreamStartSeconds ?? 0) }
        )
        self.provider = prov
        if isLiveSession {
            prod.onLiveSegmentFinalized = { [weak prov] index, durationSeconds, startPtsSeconds, discontinuous in
                prov?.appendLiveSegment(index: index,
                                        startSeconds: startPtsSeconds,
                                        durationSeconds: durationSeconds,
                                        discontinuous: discontinuous)
            }
        }

        EngineLog.emit(
            "[HLSVideoEngine] prepared: codec=\(manifestCodecs)"
            + (supplementalCodecs.map { " supplemental=\($0)" } ?? "")
            + " resolution=\(resolution.0)x\(resolution.1) "
            + "fps=\(frameRate.map { String(format: "%.3f", $0) } ?? "nil") "
            + "range=\(videoRange.rawValue) DV=\(dvVariant) segments=\(plan.count) "
            + "duration=\(String(format: "%.1f", durationSeconds))s"
        )

        let srv = HLSLocalServer(provider: prov)
        try srv.start()
        self.server = srv

        // 8. Kick the pump. An anchored first producer (#93 residual) needs the demuxer positioned
        // at the anchor BEFORE the pump reads, exactly like performRestart's pre-makeProducer seek:
        // the gate only DROPS pre-target packets, so an unseeked pump would read (and discard) the
        // whole file up to the resume point. Absolute source-PTS for the same reason as the
        // restart path (relative playlist time lands a keyframe behind on non-zero startPts0).
        if initialProducerBaseIndex > 0, initialProducerBaseIndex < plan.count {
            let tb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
            let anchorSeconds = Double(plan[initialProducerBaseIndex].startPts) * Double(tb.num) / Double(tb.den)
            dem.seek(to: anchorSeconds)
        }
        prod.start()

        // URL routing: master playlist (VIDEO-RANGE=PQ + SUPPLEMENTAL-CODECS=dvh1) only when
        // the panel is already in HDR at load time (`panelIsInHDRMode`). A master claiming HDR
        // while the panel sits in SDR fails with AVFoundationErrorDomain -11848. `panelIsInHDRMode`
        // is read after waitForSwitch settles so a transitioning panel already reads as HDR.
        //
        // `(displaySupportsHDR && matchContentEnabled)` was previously used as a proxy, but
        // tvOS exposes only one combined `isDisplayCriteriaMatchingEnabled` flag; rate-match ON +
        // range-match OFF caused -11848/-11868 (DrHurt #4 2026-05-27).
        //
        // DV P5 on non-DV panels: ALWAYS media. Single-variant P5 master has no backward-compat
        // brand (/db1p//db4h are P8.1/P8.4 only), so AVPlayer rejects with -11868
        // (AVErrorNoCompatibleAlternatesForExternalDisplay, Vincent test 2026-05-26, #4 #63).
        // DV8.1/8.4 on non-DV panels already downgrade to hvc1.* + strip DV side data above, so
        // the standard sourceIsHDR && panelReadyForHDR check routes them correctly.
        // #15: a SUBTITLES rendition lives only in a master; the pure decision below forces the
        // master for routing-safe subtitled sources so PiP can show subtitles.
        let hasNativeSubs = enableNativeSubtitleTrackForSession && !nativeSubtitleCueStoresForSession.isEmpty
        // iOS built-in panels engage EDR on demand once HDR content renders; the tvOS SDR-parked-
        // panel failure mode (-11848) does not exist there, so HDR-eligibility is the readiness
        // signal (Sodalite AE#88 retest: every HDR/DV film on iPhone routed media-direct and PiP
        // subtitles silently never worked for them).
        #if os(iOS)
        let builtInPanelEngagesOnDemand = true
        #else
        let builtInPanelEngagesOnDemand = false
        #endif
        let useMasterPlaylist = Self.resolveUseMasterPlaylist(
            videoRange: videoRange, dvVariant: dvVariant, effectiveDvMode: effectiveDvMode,
            panelIsInHDRMode: panelIsInHDRMode, displaySupportsHDR: displaySupportsHDR,
            hasNativeSubs: hasNativeSubs, builtInPanelEngagesOnDemand: builtInPanelEngagesOnDemand)
        let resolvedURL: URL? = useMasterPlaylist
            ? srv.playlistURL
            : srv.mediaPlaylistURL
        guard let url = resolvedURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        self.servingMasterPlaylist = useMasterPlaylist
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable) effectiveDvMode=\(effectiveDvMode) panelIsHDR=\(panelIsInHDRMode) displaySupportsHDR=\(displaySupportsHDR) matchContent=\(matchContentEnabled) sourceIsHDR=\(videoRange != .sdr || effectiveDvMode) useMaster=\(useMasterPlaylist) videoRange=\(videoRange) dvVariant=\(dvVariant))")
        return url
    }

    /// Pure master-vs-media playlist routing decision (#4, #15, #63). A master claiming HDR while
    /// the panel sits in SDR fails with -11848, so HDR/DV sources need a ready panel; a
    /// single-variant DV P5 master has no backward-compat brand and non-DV panels reject it with
    /// -11868, so it is always media-direct. SDR content is routable on any panel, so native
    /// subtitles force the master there. `builtInPanelEngagesOnDemand` (iOS) treats
    /// HDR-eligibility (`AVPlayer.eligibleForHDRPlayback`, passed as `displaySupportsHDR`) as
    /// panel readiness: the built-in panel engages EDR when HDR content renders, and an
    /// SDR-only device or route still reads ineligible and stays media-direct.
    static func resolveUseMasterPlaylist(
        videoRange: HLSVideoRange,
        dvVariant: DVVariant,
        effectiveDvMode: Bool,
        panelIsInHDRMode: Bool,
        displaySupportsHDR: Bool,
        hasNativeSubs: Bool,
        builtInPanelEngagesOnDemand: Bool
    ) -> Bool {
        let sourceIsHDR = videoRange != .sdr || effectiveDvMode
        let panelReadyForHDR = panelIsInHDRMode
            || (builtInPanelEngagesOnDemand && displaySupportsHDR)
        let dv5OnNonDVPanel = dvVariant == .profile5 && !effectiveDvMode
        // Gate on the ACTUAL videoRange, not sourceIsHDR: sourceIsHDR is inflated by
        // effectiveDvMode (a device DV capability) even for SDR content, which wrongly sent SDR
        // sources on DV-capable devices to media-direct, so the WebVTT rendition never appeared (#15).
        let routingSafeForMaster = (videoRange == .sdr) || panelReadyForHDR
        if dv5OnNonDVPanel { return false }
        if hasNativeSubs && routingSafeForMaster { return true }
        return sourceIsHDR && panelReadyForHDR
    }

    /// `true` when `start()` chose the master playlist (HDR/DV signaling). Read after `start()`.
    public private(set) var servingMasterPlaylist: Bool = false

    // MARK: - Diagnostics

    /// Point-in-time pipeline counters for the memory probe. Fields are uncoordinated snapshots
    /// (acceptable for a 30 s probe interval).
    public struct DiagnosticStats {
        public let segmentCacheCount: Int
        public let segmentCacheBytes: Int
        public let producerPacketsWritten: Int
        public let avioBytesFetched: Int64
        public let audioFifoSamples: Int
        /// Bytes in AudioBridge FIFO + swr delay; zero for stream-copy/video-only. Linear growth = bridge leak.
        public let audioBridgeFifoBytes: Int
        public let audioBridgeSwrBytes: Int
        public var audioBridgeTotalBytes: Int { audioBridgeFifoBytes + audioBridgeSwrBytes }
        /// Cumulative bytes emitted by the MP4SegmentMuxer; muxer-leak attribution baseline.
        public let muxerLifetimeFragmentBytes: Int
        public let muxerFragmentCuts: Int
        /// Active server connections; steady 1-3 = normal AVPlayer keep-alive; rising = CFNetwork leak.
        public let serverConnectionCount: Int
        /// Lifetime bytes sent (Data writeAll + sendfile). Should track `muxerLifetimeFragmentBytes`
        /// modulo init.mp4 + playlist; divergence = drop or duplicate.
        public let serverLifetimeBytesSent: Int
        /// Of `serverLifetimeBytesSent`, bytes via sendfile(2) fast path. Used to verify fast path is taken.
        public let serverSendfileBytesSent: Int
        /// av_packet_alloc minus av_packet_free (PacketBalanceTracker). Steady low = balanced; growth = leak.
        public let packetsAlive: Int
        public let packetsTotalAllocs: Int
        /// Producer restarts in the session (0 for non-restart sessions).
        public let producerRestartCount: Int
        /// Most recent audio-gate vs video-gate gap in source-clock ms; 0 until first audio gate.
        public let lastAVGapMs: Double
        /// Lifetime HTTP requests served (playlist + init + segment fetches).
        public let serverRequestCount: Int
    }

    // MARK: - Live telemetry forwarders

    // All forwarders snapshot the subsystem ref under `restartLock` first (stop()/restart
    // nil these under that lock; lock-free reads were an ARC data race). Counter reads
    // happen after unlock so telemetry never blocks a restart.

    /// Snapshot subsystem refs under `restartLock`.
    private func subsystemSnapshot() -> (
        producer: HLSSegmentProducer?, cache: SegmentCache?,
        server: HLSLocalServer?, demuxer: Demuxer?, audioBridge: AudioBridge?
    ) {
        restartLock.lock()
        defer { restartLock.unlock() }
        return (producer, cache, server, demuxer, audioBridge)
    }

    var demuxerBytesFetched: Int64 { subsystemSnapshot().demuxer?.avioBytesFetched ?? 0 }
    var segmentCacheTotalBytes: Int { subsystemSnapshot().cache?.totalBytes ?? 0 }
    /// On-disk segment bytes (freshly stat-ed). Used by `aetherctl live --report-cache-bytes`.
    var segmentCacheDiskBytes: Int64 { subsystemSnapshot().cache?.diskBytes() ?? 0 }
    var producerRestartCount: Int { subsystemSnapshot().producer?.restartCount ?? 0 }
    var muxedBytesLifetime: Int { subsystemSnapshot().producer?.muxerLifetimeFragmentBytes ?? 0 }
    var serverLifetimeBytesSent: Int { subsystemSnapshot().server?.lifetimeBytesSent ?? 0 }
    var serverRequestCount: Int { subsystemSnapshot().server?.requestCount ?? 0 }

    /// Live segment count. >= 2 = startup cushion released, AVPlayer has real content.
    var liveSegmentCount: Int {
        guard isLiveSession else { return 0 }
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.segmentCount ?? 0
    }

    var audioBridgeLiveBytes: Int { subsystemSnapshot().audioBridge?.liveBytes.totalBytes ?? 0 }
    var lastAVGapMs: Double { subsystemSnapshot().producer?.lastAVGapMs ?? 0 }

    public func diagnosticStats() -> DiagnosticStats {
        let subs = subsystemSnapshot()
        let abLive = subs.audioBridge?.liveBytes
        return DiagnosticStats(
            segmentCacheCount: subs.cache?.count ?? 0,
            segmentCacheBytes: subs.cache?.totalBytes ?? 0,
            producerPacketsWritten: subs.producer?.packetsWrittenCount ?? 0,
            avioBytesFetched: subs.demuxer?.avioBytesFetched ?? 0,
            audioFifoSamples: subs.audioBridge?.fifoSampleCount ?? 0,
            audioBridgeFifoBytes: abLive?.fifoBytes ?? 0,
            audioBridgeSwrBytes: abLive?.swrDelayBytes ?? 0,
            muxerLifetimeFragmentBytes: subs.producer?.muxerLifetimeFragmentBytes ?? 0,
            muxerFragmentCuts: subs.producer?.muxerFragmentCuts ?? 0,
            serverConnectionCount: subs.server?.activeConnectionCount ?? 0,
            serverLifetimeBytesSent: subs.server?.lifetimeBytesSent ?? 0,
            serverSendfileBytesSent: subs.server?.lifetimeSendfileBytes ?? 0,
            packetsAlive: PacketBalanceTracker.alive,
            packetsTotalAllocs: PacketBalanceTracker.totalAllocs,
            producerRestartCount: subs.producer?.restartCount ?? 0,
            lastAVGapMs: subs.producer?.lastAVGapMs ?? 0,
            serverRequestCount: subs.server?.requestCount ?? 0
        )
    }

    /// init.mp4 + segment bytes for live scrub-thumbnail (synchronous local I/O; call off-main).
    /// Returns nil if the file was evicted between lookup and read. `segmentIndex` enables extractor reuse.
    func liveScrubThumbnailSource(atSeconds seconds: Double) -> (data: Data, segmentIndex: Int)? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        guard isLiveSession, let prov else { return nil }
        guard let seg = prov.liveThumbnailSegment(atSeconds: seconds) else { return nil }
        guard let initData = prov.peekInitSegment(),
              let segData = try? Data(contentsOf: seg.fileURL) else { return nil }
        return (initData + segData, seg.index)
    }

    public func stop() {
        // Sodalite#32: drop the tap routes first so a pump still draining its last packets no-ops
        // instead of decoding into stores being torn down.
        subtitleTapLock.lock()
        subtitleTapRoutes.removeAll()
        subtitleTapLock.unlock()
        // Snapshot resources under the lock, then clear instance state and hand them to a
        // detached cleanup task (#10: SwiftUI releases @State on main; detach avoids a 3 s freeze
        // while the pump exits a parked HTTP byte-range read).
        restartLock.lock()
        sessionEpoch &+= 1
        let p = producer
        producer = nil
        let s = server
        server = nil
        let c = cache
        cache = nil
        let ab = audioBridge
        audioBridge = nil
        let d = demuxer
        demuxer = nil
        let sd = sideAudioDemuxer
        sideAudioDemuxer = nil
        // Preopened demuxer: nil if start() consumed it; close is idempotent.
        let preopened = preopenedDemuxer
        preopenedDemuxer = nil
        let prov = provider
        provider = nil
        savedVideoConfig = nil
        savedAudioConfig = nil
        let ownedParams = ownedCodecParams
        ownedCodecParams = []
        let reopening = reopenDemuxer
        reopenDemuxer = nil
        segmentPlan = []
        restartLock.unlock()
        reopening?.markClosed()

        p?.stop()

        // Wake LL-HLS blocking-reload waiters; without this they sleep out their full 18-30 s timeout.
        prov?.cancelWaiters()

        // markClosed unblocks a live pump parked in the AVIO reconnect loop (exits on closed flag,
        // not the producer cancel flag). Without this, waitForFinish blocks ~3 s while reconnects
        // storm against a superseded transcode, polluting the next session.
        d?.markClosed()
        sd?.markClosed()
        preopened?.markClosed()

        // Detached cleanup: producer waitForFinish must precede demuxer/cache/server close
        // (pump accesses them during unwind). ownedParams released last (pump read them).
        Task.detached {
            _ = p?.waitForFinish(timeout: 3.0)
            s?.stop()
            c?.close()
            ab?.close()
            d?.close()
            sd?.close()
            preopened?.close()
            _ = ownedParams
        }
    }

    deinit {
        stop()
    }

    // MARK: - Producer construction + restart

    /// Allocate a new `HLSSegmentProducer` at the given segment index (initial bring-up and scrub restarts).
    func makeProducer(
        baseIndex: Int,
        liveReopenOutputEndSeconds: Double? = nil
    ) throws -> HLSSegmentProducer {
        guard let dem = demuxer, let cache = cache, let cfg = savedVideoConfig else {
            throw HLSVideoEngineError.notStarted
        }

        // Scan-forward + dynamic-shift: producer scans for the first AV_PKT_FLAG_KEY packet with
        // dts >= videoTarget, then computes shift = actualFirstDts - desiredFirstTfdt and applies
        // it to all subsequent packets. Audio target set dynamically after video lands.
        let videoTarget: Int64
        let desiredVideoTfdt: Int64
        let desiredAudioTfdt: Int64
        if let endSeconds = liveReopenOutputEndSeconds {
            // Live reopen: no scan target (join head), but tfdt must continue where the
            // failed producer's last segment ended (seam carries #EXT-X-DISCONTINUITY).
            videoTarget = Int64.min
            desiredVideoTfdt = sourceVideoTbSeconds > 0
                ? Int64(endSeconds / sourceVideoTbSeconds)
                : 0
            desiredAudioTfdt = savedAudioConfig.map {
                av_rescale_q(desiredVideoTfdt, cfg.timeBase, $0.sourceTimeBase)
            } ?? 0
        } else if baseIndex > 0, baseIndex < segmentPlan.count {
            videoTarget = segmentPlan[baseIndex].startPts
            desiredVideoTfdt = segmentPlan[baseIndex].startPts - firstKeyframePts
            // Rescale into source audio TB (not bridge.inputTimeBase=1/48000). The pre-fix bug
            // was FLAC-bridge-only: shift=-152485195 (off by 48x); stream-copy unaffected.
            desiredAudioTfdt = savedAudioConfig.map {
                av_rescale_q(desiredVideoTfdt, cfg.timeBase, $0.sourceTimeBase)
            } ?? 0
        } else {
            videoTarget = Int64.min
            desiredVideoTfdt = 0
            desiredAudioTfdt = 0
        }

        // Segment boundary slice: startPts per segment + endPts of final (producer upper bound).
        // Lower bound clamped: live reopen passes baseIndex > segmentPlan.count (empty plan).
        let plannedSegs = segmentPlan[min(baseIndex, segmentPlan.count)..<segmentPlan.count]
        var segmentBoundaries: [Int64] = plannedSegs.map { $0.startPts }
        if let last = plannedSegs.last {
            segmentBoundaries.append(last.endPts)
        }

        let prod = try HLSSegmentProducer(
            demuxer: dem,
            videoStreamIndex: videoStreamIndex,
            video: cfg,
            audio: savedAudioConfig,
            sideAudioDemuxer: sideAudioDemuxer,
            cache: cache,
            baseIndex: baseIndex,
            targetSegmentDurationSeconds: Self.targetSegmentDuration,
            videoFallbackDurationPts: videoFallbackDurationPts,
            audioFallbackDurationPts: audioFallbackDurationPts,
            restartTargetVideoDts: videoTarget,
            closedCaptionStreamIndex: closedCaptionStreamIndexForSession,
            subtitleTapStreamIndices: Set(nativeSubtitleSourceStreamIndicesForSession.compactMap { $0 }),
            desiredFirstVideoTfdtPts: desiredVideoTfdt,
            desiredFirstAudioTfdtPts: desiredAudioTfdt,
            segmentBoundaries: segmentBoundaries,
            isLive: isLiveSession,
            packedSideAudioStartPts: packedSideAudioStartPts,
            packedSideAudioFallbackDurationPts: packedSideAudioFallbackDurationPts
        )
        prod.onFirstHDR10PlusDetected = { [weak self] in
            self?.notifyHDR10PlusOnce()
        }
        prod.onVideoShiftKnown = { [weak self] shiftPts in
            self?.handleVideoShiftKnown(shiftPts)
        }
        prod.onLiveTimelineRebase = { [weak self] shiftPts, seamOutputSeconds in
            self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: seamOutputSeconds)
        }
        prod.onPumpFinished = { [weak self, weak prod] reason in
            guard let self, let prod else { return }
            self.handlePumpFinished(prod, reason: reason)
        }
        // #65: let the pump suspend its backpressure wedge detector while AVPlayer is paused (a paused
        // consumer issues no forward fetch; its frozen fetch target is not a wedge). Threaded onto every
        // producer (initial + restart) so the guard survives scrub/audio-switch rebuilds.
        prod.wantsToPlayProvider = playIntentProvider
        // Thread native subtitle state onto every producer (initial + restart) so the init moov is
        // consistent and per-segment cue drain survives seek/audio-switch (#55). Set unconditionally:
        // empty set keeps byte-identical output and clears stale stores after clearSubtitle.
        prod.enableNativeSubtitleTrack = enableNativeSubtitleTrackForSession
        prod.subtitleCueStores = nativeSubtitleCueStoresForSession
        prod.nativeSubtitleLanguages = nativeSubtitleLanguagesForSession
        prod.closedCaptionObserver = closedCaptionObserverForSession   // #77
        // Sodalite#32: build the tap routes lazily on the first producer that has stores + stream
        // indices (the host sets both before start()), then wire the tap onto every producer.
        subtitleTapLock.lock()
        let routesEmpty = subtitleTapRoutes.isEmpty
        subtitleTapLock.unlock()
        if routesEmpty, !nativeSubtitleSourceStreamIndicesForSession.isEmpty,
           !nativeSubtitleCueStoresForSession.isEmpty {
            rebuildSubtitleTapRoutes()
        }
        armSubtitleTap(on: prod)
        return prod
    }

    // MARK: - Live source-loss recovery

    /// Max reopen attempts per lost-source event (AVIO absorbs transient drops internally;
    /// pump exits only on exhausted sources: dead transcode, dropped tuner, blown budget).
    static let liveReopenMaxAttempts = 6

    /// Barren-cycle backstop: an open-then-starve source would cycle forever without this.
    /// After `maxBarrenReopenCycles` consecutive cycles producing no new segment, stop reviving.
    var barrenReopenCycles = 0
    var lastReopenSegmentCount = -1
    static let maxBarrenReopenCycles = 3

    private func handleVideoShiftKnown(_ shiftPts: Int64) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        setPlaylistShiftSeconds(seconds)
        // Refresh every native subtitle store's shift so cuesInWindow stays on the correct AVPlayer
        // axis after a restart (matroska seek can land past the planned keyframe, #55). Snapshot under
        // restartLock: this runs on the pump thread and the array is reassigned by attach* on another
        // thread, so iterating the live array would race a CoW reassignment.
        restartLock.lock()
        let stores = nativeSubtitleCueStoresForSession
        restartLock.unlock()
        stores.forEach { $0.setShiftSeconds(seconds) }
        onPlaylistShiftChanged?(seconds)
    }

    /// Live program-boundary rebase. Unlike `handleVideoShiftKnown`, does NOT fire `onPlaylistShiftChanged`:
    /// AVPlayer renders at ~buffer+holdback behind the producer edge, so the host must keep the OLD shift
    /// until playback crosses `seamOutputSeconds`. Internal `playlistShiftSeconds` tracks the edge immediately.
    func handleLiveTimelineRebase(_ shiftPts: Int64, seamOutputSeconds: Double) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        setPlaylistShiftSeconds(seconds)
        onPlaylistShiftRebased?(seconds, seamOutputSeconds)
    }

    /// Session-level debounce: prevents re-firing after a scrub restart builds a fresh producer.
    private func notifyHDR10PlusOnce() {
        hdr10PlusLock.lock()
        let alreadyFired = hasReportedHDR10Plus
        hasReportedHDR10Plus = true
        hdr10PlusLock.unlock()
        if !alreadyFired {
            onFirstHDR10PlusDetected?()
        }
    }

    /// Entry point from `VideoSegmentProvider` when AVPlayer requests a segment outside the LRU window.
    /// Coalesces burst seeks so only the in-flight restart + one final settled-target restart run (#35).
    /// init.mp4 is byte-deterministic for a fixed `StreamConfig` so AVPlayer's cached copy stays valid.
    /// True while a coalesced restart run is executing (#93 residual: the provider's waiting
    /// segment fetches ride this instead of burning fixed retry budgets, and skip re-firing
    /// restarts at stale indices against the coalescer's newer target).
    var restartInFlight: Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return restartCoalescer.isInFlight
    }

    /// Base index of the currently-installed producer, nil when none (#93 residual: a fetch for
    /// an index the active producer covers must WAIT for its march, not tear it down; device saw
    /// a 75%-complete capture killed by a backstop re-fire and a fresh forward march restarted).
    var currentProducerBaseIndex: Int? {
        restartLock.lock()
        defer { restartLock.unlock() }
        return producer?.anchoredBaseIndex
    }

    /// Total media-segment requests seen this session (#93 residual): the stall-triggered
    /// re-engage watchdog compares snapshots to detect a consumer that stopped requesting.
    var mediaFetchCountSnapshot: UInt64 {
        restartLock.lock()
        defer { restartLock.unlock() }
        return provider?.mediaFetchCount ?? 0
    }

    func requestRestart(at idx: Int, authoritative: Bool = false) {
        restartLock.lock()
        let shouldRun = restartCoalescer.begin(idx, authoritative: authoritative)
        let seekTime = segmentStartSecondsLocked(idx) // under lock; segmentPlan guarded by restartLock (#38)
        restartLock.unlock()
        guard shouldRun else {
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) coalesced behind in-flight restart",
                category: .session
            )
            return
        }
        onSeekStateChanged?(true, seekTime) // publish seek in-flight until coalesced run drains (#38)
        var target = idx
        while true {
            performRestart(at: target)
            restartLock.lock()
            let nextTarget = restartCoalescer.next(justRan: target)
            let nextSeekTime = nextTarget.flatMap { segmentStartSecondsLocked($0) }
            restartLock.unlock()
            guard let nextTarget else { break }
            EngineLog.emit(
                "[HLSVideoEngine] coalesced restart advancing to settled target idx=\(nextTarget)",
                category: .session
            )
            onSeekStateChanged?(true, nextSeekTime)
            target = nextTarget
        }
        onSeekStateChanged?(false, nil) // run settled; clear in-flight seek signal
    }

    /// `segmentPlan[idx].startSeconds` on the AVPlayer/playlist axis, or nil
    /// if out of range. Caller must hold `restartLock` (segmentPlan is
    /// guarded by it).
    private func segmentStartSecondsLocked(_ idx: Int) -> Double? {
        guard idx >= 0, idx < segmentPlan.count else { return nil }
        return segmentPlan[idx].startSeconds
    }

    /// Segment index whose plan span covers `seconds` on the AVPlayer/playlist axis (the same axis
    /// `segmentStartSecondsLocked` uses). Last segment whose `startSeconds <= seconds`, clamped. Used to
    /// re-anchor the producer on AVPlayer's real position after a backpressure wedge (#65). Thread-safe.
    func segmentIndexForPlaylistTime(_ seconds: Double) -> Int {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard !segmentPlan.isEmpty else { return 0 }
        var lo = 0
        var hi = segmentPlan.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if segmentPlan[mid].startSeconds <= seconds { lo = mid + 1 } else { hi = mid }
        }
        return min(max(lo - 1, 0), segmentPlan.count - 1)
    }

    // Driven exclusively through requestRestart(at:) so bursts coalesce (#35).
    private func performRestart(at idx: Int) {
        restartGate.lock()
        defer { restartGate.unlock() }

        restartLock.lock()
        guard idx >= 0, idx < segmentPlan.count, let dem = demuxer else {
            restartLock.unlock()
            return
        }
        let epoch = sessionEpoch
        let old = producer
        producer = nil
        let ab = audioBridge
        let targetStartPts = segmentPlan[idx].startPts
        let videoTb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
        restartLock.unlock()

        let restartStart = DispatchTime.now()

        // The new producer reuses this demuxer unless we have to replace a wedged one (#79, below).
        var activeDem = dem
        var freshDemuxer: Demuxer?
        if let old {
            old.stop()
            let ok = old.waitForFinish(timeout: 5.0)
            if !ok {
                // #79: the old pump is wedged in a blocking network read on the SHARED demuxer; stop() can't
                // unblock a socket read, so waitForFinish timed out. Reusing this demuxer makes the new
                // producer's first post-seek read queue behind that stuck read for the full ~20s
                // connStallTimeout (the reporter's ~25s restart), after which the abandoned reader also steals
                // the first packet. markClosed() aborts the stuck read immediately (the existing thread-safe
                // unblock) but dooms the demuxer, so open a FRESH one and hand it to the new producer. Open
                // FIRST, abort only on success, so a reopen failure falls back to the prior abandon behaviour
                // (no regression) rather than poisoning the only demuxer. Scoped to the VOD single-demuxer
                // scrub case; the side-source / live-reopen paths keep their existing behaviour.
                if !isLiveSession, sideAudioDemuxer == nil {
                    let fresh = Demuxer()
                    do {
                        // .restartReopen: bounded find_stream_info budget; the FULL playback budget was
                        // the bulk of a 44 s wedge-reopen over WAN (#93 residual). The pass itself must
                        // run so video_delay resolves, else B-frame dts arrive broken (#93 judder).
                        try fresh.open(url: sourceURL, extraHeaders: sourceHTTPHeaders, profile: .restartReopen, isLive: false)
                        dem.markClosed() // abort the wedged read now that the replacement is ready
                        freshDemuxer = fresh
                        activeDem = fresh
                        EngineLog.emit(
                            "[HLSVideoEngine] restart at idx=\(idx): old producer wedged in a read past 5s; "
                            + "aborted it and reopened a fresh demuxer (avoids the ~20s shared-read stall)",
                            category: .session
                        )
                    } catch {
                        fresh.close()
                        EngineLog.emit(
                            "[HLSVideoEngine] restart at idx=\(idx): old producer wedged; reopen failed (\(error)), "
                            + "abandoning it and reusing the demuxer",
                            category: .session
                        )
                    }
                } else {
                    EngineLog.emit(
                        "[HLSVideoEngine] restart at idx=\(idx): old producer didn't exit within 5s, abandoning it "
                        + "(its in-flight read shares the demuxer and may consume the first post-seek packet; "
                        + "if the new session starts a GOP late, this is why)",
                        category: .session
                    )
                }
            }
        }

        // Seek to ABSOLUTE source-PTS, not relative playlist time. segmentPlan[N].startSeconds is
        // relative to startPts0; if startPts0 != 0 (B-frame head or remux), seeking the relative
        // value lands a-keyframe-or-more behind (AVSEEK_FLAG_BACKWARD rolls back). Subtitle cue
        // timestamps are absolute source-PTS, so a wrong seek shifts them up to one segment ahead.
        let absoluteTargetSeconds = Double(targetStartPts) * Double(videoTb.num) / Double(videoTb.den)
        // Seek outside restartLock (network-bound). Concurrent stop() calls markClosed() so the
        // seek fails fast instead of racing teardown.
        activeDem.seek(to: absoluteTargetSeconds)
        // Re-arm bridge PTS rebase so the encoder timeline starts from the new demuxer cursor.
        ab?.startSegment()

        // Re-validate: a stop() landing during waits bumped sessionEpoch; don't resurrect into a torn-down session.
        restartLock.lock()
        guard sessionEpoch == epoch else {
            restartLock.unlock()
            // #79: a reopened demuxer (replacing a wedged one) must not leak when stop() superseded us.
            freshDemuxer?.close()
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx): superseded by stop(), unwinding",
                category: .session
            )
            return
        }
        // #79: install the reopened demuxer only inside the validated section so makeProducer reads it and a
        // concurrent teardown can't race a resurrected demuxer into a torn-down session.
        if let freshDemuxer {
            demuxer = freshDemuxer
            freshDemuxer.onNetworkPhaseChanged = onNetworkPhaseChanged   // re-wire stall signal onto the reopened demuxer (#85)
        }
        do {
            let newProd = try makeProducer(baseIndex: idx)
            producer = newProd
            restartLock.unlock()
            newProd.start()
        } catch {
            restartLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) failed: \(error)",
                category: .session
            )
            return
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - restartStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSVideoEngine] producer restarted at idx=\(idx) (seek=\(String(format: "%.2f", absoluteTargetSeconds))s [absolute source-PTS], restart took \(String(format: "%.0f", elapsedMs))ms)",
            category: .session
        )
    }

}
