import AVFoundation
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

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

    /// From `LoadOptions.forceDolbyVisionOnNonDVDisplay` (AE#455); default OFF. Read only by the P8.1
    /// route, and only while `effectiveDvMode` is false.
    let forceDolbyVisionOnNonDVDisplay: Bool

    /// From `LoadOptions.dolbyVisionHandling`; default `.automatic`. `.baseLayerOnly` sends a Dolby
    /// Vision source with a presentable base layer down the plain hvc1 / av01 route on every display
    /// (`VideoRoutingPolicy.presentsDolbyVisionBaseLayer`), ahead of every DV branch including AE#455.
    let dolbyVisionHandling: DolbyVisionHandling

    /// AE#532: the profile this source's own RPU reports, when the container record was worth doubting
    /// (`DolbyVisionRecordAudit`). nil when nothing was read, which is every source but a Profile 5
    /// record over a BT.2020 YCbCr HDR VUI. The route believes it over the record.
    let dolbyVisionRPUProfile: Int?

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
    /// AE#641: the source audio streams this session already found undecodable (their bridge decoded
    /// nothing). When the pick lands on one again, the cascade goes straight to its video-only tail.
    let undecodableAudioStreamIndices: Set<Int32>

    /// Whether the cascade has to skip the stream it is about to build a pipeline for.
    nonisolated static func isKnownUndecodable(_ indices: Set<Int32>, sourceAudioStreamIndex: Int32) -> Bool {
        sourceAudioStreamIndex >= 0 && indices.contains(sourceAudioStreamIndex)
    }

    /// AE#443: whoever REPLACES one of these two mid-session owes the session the totals the outgoing
    /// instance held (`retireDemuxer` / `retireProducer` below). They carry the session's byte and
    /// restart counters, and a fresh instance starts them at zero.
    var demuxer: Demuxer?
    var cache: SegmentCache?   // internal for the teardown-partial witness test
    var producer: HLSSegmentProducer? {
        didSet {
            // Audit SEG-104: a gate open is checked against this under `anchorShiftLock`, atomically
            // with what it records, so a producer that was replaced cannot record after.
            anchorShiftLock.lock()
            installedProducerEpoch = producer?.epoch
            anchorShiftLock.unlock()
        }
    }
    private var server: HLSLocalServer?
    var provider: VideoSegmentProvider?

    /// The 2026-09-02 field session retained 64 segments spanning more than four minutes. Cache
    /// mutations can arrive much faster than a host timeline needs to redraw, so fold them into at
    /// most four snapshots a second while preserving every final resident shape.
    ///
    /// The fold is timed on a private-queue `DispatchSourceTimer`, not on `Task.sleep` in a detached
    /// task. The cooperative pool is capped at the core count and never overcommits, and this engine's
    /// own reader work blocks threads in it (AE#422), so a delayed job there arrives when a thread
    /// frees up rather than when it was due: `SlowServeSignal` records a `userInitiated` `asyncAfter`
    /// that did not fire within 15 s on a loaded CI runner. A band is wanted exactly while the engine
    /// is busiest, which is precisely when that queue is worst.
    private let residentRangesPublishLock = NSLock()
    private let residentRangesPublishQueue = DispatchQueue(
        label: "aether.residentranges.publish", qos: .utility)
    private var residentRangesPublishTimer: DispatchSourceTimer?
    private var residentRangesPublishPending = false
    private var residentRangesObserver: (@Sendable ([ClosedRange<Double>]) -> Void)?

    func setResidentRangesObserver(
        _ observer: (@Sendable ([ClosedRange<Double>]) -> Void)?
    ) {
        residentRangesPublishLock.lock()
        residentRangesObserver = observer
        residentRangesPublishLock.unlock()
    }

    func noteResidentSetChanged() {
        residentRangesPublishLock.lock()
        residentRangesPublishPending = true
        guard residentRangesPublishTimer == nil else {
            residentRangesPublishLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: residentRangesPublishQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .never,
                       leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.publishResidentRanges() }
        residentRangesPublishTimer = timer
        residentRangesPublishLock.unlock()
        timer.resume()
    }

    /// Drops a fold that has not fired yet. The engine clears its published band on teardown, so a
    /// snapshot that lands after this would describe a cache that is already gone.
    private func cancelResidentRangesPublish() {
        residentRangesPublishLock.lock()
        let timer = residentRangesPublishTimer
        residentRangesPublishTimer = nil
        residentRangesPublishPending = false
        residentRangesPublishLock.unlock()
        timer?.cancel()
    }

    private func publishResidentRanges() {
        residentRangesPublishLock.lock()
        residentRangesPublishPending = false
        let observer = residentRangesObserver
        residentRangesPublishLock.unlock()

        observer?(residentPlaylistRanges())

        residentRangesPublishLock.lock()
        let fired = residentRangesPublishTimer
        residentRangesPublishTimer = nil
        let publishAgain = residentRangesPublishPending
        residentRangesPublishLock.unlock()
        fired?.cancel()
        if publishAgain { noteResidentSetChanged() }
    }

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

    /// When true, the session exposes the native subtitle WebVTT rendition (separate from the A/V
    /// variant, served by HLSLocalServer) and arms its cue readers on track selection (#15 / Sodalite#32).
    /// Set before `start()`.
    var enableNativeSubtitleTrackForSession: Bool = false

    /// AE#682: the host asked for an I-frame rendition. Whether the session can serve one is decided
    /// in `start()` and read back as `iFrameRenditionVerdict`.
    var iFramePlaylistRequested = false
    /// AE#682: an independent reader for a custom-IO source, which this session cannot reopen by URL.
    /// Set before `start()`. The session owns it from then on and closes it: through the side reader
    /// that took it, at once when the rendition stays absent, or in `stop()`.
    var customIFrameReader: (reader: IOReader, formatHint: String?)?
    private(set) var iFrameRenditionVerdict: IFrameRenditionEligibility.Verdict = .absent(.notRequested)
    private var iFrameRendition: IFrameRendition?

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
    // Public so aetherctl's serve --start-position can repro the anchored resume path (#99).
    public var initialStartSeconds: Double?
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

    /// #131: A53/SEI caption observer, re-threaded onto every producer like the #77 CC observer.
    /// Set before start() when the source has no demuxable CC stream.
    var a53CaptionObserverForSession: (@Sendable ([CCDataParser.CCTriplet], Int64, Int64, AVRational) -> Void)?

    /// #260: per-frame presentation times on both axes. Lock-guarded because the pump reads it once per muxed
    /// frame while the host can install or clear it from any thread at any time (a subtitle track switched
    /// mid-title must not have to wait for the next producer).
    private let frameTimeObserverLock = NSLock()
    private var _nativeVideoFrameTimeObserver: NativeVideoFrameTimeObserver?

    func setNativeVideoFrameTimeObserver(_ observer: NativeVideoFrameTimeObserver?) {
        frameTimeObserverLock.lock()
        _nativeVideoFrameTimeObserver = observer
        frameTimeObserverLock.unlock()
    }

    private func nativeVideoFrameTimeObserverSnapshot() -> NativeVideoFrameTimeObserver? {
        frameTimeObserverLock.lock(); defer { frameTimeObserverLock.unlock() }
        return _nativeVideoFrameTimeObserver
    }

    /// Monotonic producer generation handed to each producer (#260). Process-wide rather than per
    /// session (#314): a `load()` builds a new HLSVideoEngine, and a per-instance counter would restart
    /// under a host that is still holding the outgoing session's reports. Its own allocator, with its
    /// own lock, because `makeProducer` runs both under `restartLock` (live reopen) and outside it
    /// (initial bring-up), and because two sessions overlap while the outgoing one unwinds.
    private static let producerEpochs = FrameTimeSequence()

    private func nextProducerEpoch() -> UInt64 {
        HLSVideoEngine.producerEpochs.next()
    }

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

    /// #112 rework: session-lifetime retention of every embedded subtitle stream's packets,
    /// harvested by the producer pump (no second connection, no side demuxer). The MainActor
    /// overlay drainer decodes from it near the playhead. Survives producer restarts.
    let subtitlePacketStore = SubtitlePacketStore()

    /// #112 rework: every embedded subtitle stream in the session demuxer, text AND bitmap.
    /// These all stay in the producer keep-set so late track enables need no restart.
    var allEmbeddedSubtitleStreamIndices: Set<Int32> {
        Set((demuxer?.subtitleTrackInfos() ?? []).map { Int32($0.id) })
    }

    /// #112 rework: build an overlay decoder for any embedded subtitle stream (text or
    /// bitmap), seeded exactly like the tap routes. The drainer owns the returned decoder.
    func makeOverlayDecoder(streamIndex: Int32) -> EmbeddedSubtitleDecoder? {
        guard let dem = demuxer else { return nil }
        let w = savedVideoConfig.map { Int32($0.codecpar.pointee.width) } ?? 1920
        let h = savedVideoConfig.map { Int32($0.codecpar.pointee.height) } ?? 1080
        // Audit DMX-108: the decoder copies what it needs out of the stream inside the call, so a
        // live reopen's close() cannot free the stream underneath it.
        let made = dem.withStream(at: streamIndex) { stream in
            EmbeddedSubtitleDecoder(stream: stream,
                                    sourceVideoWidth: w > 0 ? w : 1920,
                                    sourceVideoHeight: h > 0 ? h : 1080,
                                    preserveASSMarkup: preserveASSMarkupForSubtitleTap,
                                    teletextPage: teletextPageForSubtitleTap)
        }
        return made ?? nil
    }

    /// Sodalite#32 Phase 2: tap decoders honor the host's markup preference so the overlay can render
    /// styled ASS from tap-fed cues; the WebVTT rendition strips the markup at serve time instead.
    /// Set before start() (AetherEngine+Loading).
    var preserveASSMarkupForSubtitleTap = false
    var teletextPageForSubtitleTap: Int? = nil

    var subtitleTapActive: Bool {
        subtitleTapLock.lock(); defer { subtitleTapLock.unlock() }
        return !subtitleTapRoutes.isEmpty
    }

    func subtitleTapCoversStream(_ idx: Int32) -> Bool {
        subtitleTapLock.lock(); defer { subtitleTapLock.unlock() }
        return subtitleTapRoutes[idx] != nil
    }

    /// Enable the native WebVTT subtitle renditions for the session (#55). Call before `start()`
    /// so the master playlist declares the SUBTITLES group. `aetherctl serve --native-subs` uses
    /// this; a full session wires it via `LoadOptions.prepareNativeSubtitles`.
    public func requestNativeSubtitleTrack() {
        enableNativeSubtitleTrackForSession = true
    }

    /// Ask for an I-frame rendition in the master (AE#682), the `LoadOptions.serveIFramePlaylist`
    /// path a full session uses. Must precede `start()`.
    public func requestIFramePlaylist() {
        iFramePlaylistRequested = true
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
        armSubtitleTap(on: prod)
    }

    /// Attach one store per non-bitmap subtitle track from the engine's demuxer (#55, all-tracks).
    /// Call after `start()`. Returns per-track languages for logging.
    @discardableResult
    public func attachAllNativeSubtitleStores() -> [String?] {
        // Decoder-name classifier: an exact-match Set of descriptor names here never matched TrackInfo.codec
        // (the libavcodec decoder name), so bitmap tracks leaked into the native subtitle store set.
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
            guard let sidx, ordinal < nativeSubtitleCueStoresForSession.count else { continue }
            // Audit DMX-108: see `makeOverlayDecoder`.
            let made = dem.withStream(at: sidx) { stream in
                EmbeddedSubtitleDecoder(stream: stream,
                                        sourceVideoWidth: w > 0 ? w : 1920,
                                        sourceVideoHeight: h > 0 ? h : 1080,
                                        preserveASSMarkup: preserveASSMarkupForSubtitleTap,
                                        teletextPage: teletextPageForSubtitleTap)
            }
            guard let decoder = made ?? nil else { continue }
            subtitleTapRoutes[sidx] = (decoder, nativeSubtitleCueStoresForSession[ordinal])
        }
        if !subtitleTapRoutes.isEmpty {
            EngineLog.emit(
                "[HLSVideoEngine] subtitle pump tap armed for streams \(subtitleTapRoutes.keys.sorted())",
                category: .session
            )
        }
    }

    /// #364: re-seed the tap decoders after a session decode option changed under them (the teletext
    /// page). Same rebuild `attachNativeSubtitleStores` performs, minus the store swap, so the routes
    /// keep their cue stores and only the decoders are new. Cues already harvested keep the page they
    /// were decoded with: they are in the rendition the host is serving and are not ours to rewrite.
    func refreshSubtitleTapDecoders() {
        restartLock.lock()
        let hasRoutes = !nativeSubtitleSourceStreamIndicesForSession.isEmpty
        let prod = producer
        restartLock.unlock()
        guard hasRoutes else { return }
        rebuildSubtitleTapRoutes()
        armSubtitleTap(on: prod)
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
        // #112 rework: harvest every embedded subtitle stream's packets into the session
        // store. Runs on the pump thread; the store is lock-guarded. Split-PES PGS streams
        // (MPEG-TS) go through the store's display-set reassembly.
        let assemblyIndices = demuxer?.splitDisplaySetSubtitleStreamIndices() ?? []
        prod.subtitlePacketSink = { [subtitlePacketStore] idx, pkt, tb in
            subtitlePacketStore.harvest(streamIndex: idx, packet: pkt, timeBase: tb,
                                        assembleSplitDisplaySets: assemblyIndices.contains(idx))
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

    /// [MovieClaw P36] 可信关键帧表（MKV Cues / MP4 stss，与关键帧对齐的分片计划同源），源时间轴上的秒，升序。
    /// 没有可信索引（TS、均匀切分）时为空：跳转照旧精确落点。见 `KeyframeSnapPolicy`
    private(set) var seekKeyframeSourceSeconds: [Double] = []
    /// [MovieClaw P36] 每秒源时长逐帧解码的估计耗时（秒），按帧率与画面尺寸折算
    private(set) var seekDecodeCostPerSecond: Double = 0

    /// AE#270: source PTS the container's timeline starts at, clamped at 0. The published playhead folds
    /// it out so it stays on the same 0-based axis as `duration`.
    public private(set) var sourceStartSeconds: Double = 0

    /// Result of the stream-copy / FLAC-bridge / video-only cascade. Possible values:
    /// `"Stream-copy (EAC3+JOC Atmos)"`, `"Stream-copy (<CODEC>)"`, `"<CODEC> → FLAC bridge"`.
    /// nil when no audio pipeline is live.
    public internal(set) var audioPipelineDescription: String?

    /// AE#462: the same cascade result as a typed fact, so a host can act on it. The label above is
    /// for a human and cannot separate the two ways of ending up with no pipeline: a source that has
    /// no audio track and a source whose audio could not be delivered both leave it nil, and only the
    /// second is a reason for a fallback ladder to demote. Set at each of the cascade's three exits.
    public internal(set) var audioDelivery: AudioDelivery = .none

    /// AE#520: the stream-copied audio bitstream carries JOC, so this session's `ec-3` track is
    /// Atmos and reaches the receiver as a 2-channel MAT carrier. A host that reads a channel count
    /// off the HDMI route has to know that, or it reads the carrier as a downmix.
    public internal(set) var audioIsAtmosStreamCopy = false

    /// Producer's `videoShiftPts` in seconds, updated on every gate open. AVPlayer clock =
    /// `source_pts - playlistShiftSeconds`. Lock-guarded: written on pump thread, read on others.
    public var playlistShiftSeconds: Double {
        shiftLock.lock(); defer { shiftLock.unlock() }; return _playlistShiftSeconds
    }
    private func setPlaylistShiftSeconds(_ value: Double) {
        shiftLock.lock(); _playlistShiftSeconds = value; shiftLock.unlock()
    }

    /// AE#418 round 2 + PR #533: what each epoch left at the index it opened on, both what its first
    /// segment adds to the axis and what all of its bytes carry. See `EpochAxisTable`.
    private let anchorShiftLock = NSLock()
    private(set) var epochAxisByIndex = EpochAxisTable()   // internal read for the superseded-producer tests
    /// PR #533 round 2: how far AVPlayer's OWN timeline is displaced from the playlist, which is the
    /// quantity every AE#418 rule is about.
    ///
    /// The published axis is this plus the normalization the bytes carry, and on a source whose
    /// timestamps start at zero those are one number, which is why eleven rounds could compose the
    /// whole axis and be right. Measured on the 600 s twin: a second placement worth 596.833 s
    /// composed onto a standing 599.625 s published **1196.458 s** and put the seam at item
    /// -531.625 s, i.e. it added the source origin a second time. Zero at load, because a fresh
    /// item's timeline is undisplaced on any source.
    private var placementOffsetSeconds: Double = 0
    /// AE#418 round 8: how far below the axis it composed on the last measured placement actually
    /// landed, in seconds. Zero until a placement has been read back, which is also what makes an
    /// item's FIRST placement compose onto the axis itself.
    ///
    /// Rounds 5 to 7 carried this as a multiple of the epoch's presentation lead, on the premise that
    /// the distance is a geometry of the source. It is not: `tc-cues-lie.mkv` has no frame reordering
    /// at all, so every gate opens with a lead of exactly zero, and its third placement still sits a
    /// frame below its axis (2 runs of 2). No coefficient can express that, and on `tc-bf1-cues-lie`
    /// one source places twice and reads 0.000 then 0.083. So the distance is measured in the units
    /// it corrects, and every reading teaches it, including the ones that confirm.
    private var lastPlacementDisplacement: Double = 0
    /// AE#418 round 7: what the local server did with the request each placement was counted from,
    /// stamped with the serial of the answer. `true` once its bytes went out, `false` when the
    /// response failed. A placement is a request that was ANSWERED, and until it is answered there is
    /// nothing to conclude from an empty buffer. The serial is what keeps an OLD answer for the same
    /// index (a segment served once, seeked back to, and requested again) from answering for a
    /// request still in flight.
    private var segmentDeliveryByIndex: [Int: (serial: Int, delivered: Bool)] = [:]
    private var segmentDeliverySerial = 0
    /// AE#418 round 3: the placement this session last published an axis for, so the prediction can be
    /// checked against where AVPlayer actually put those bytes.
    private var lastPublishedPlacement: PublishedPlacement?
    /// AE#481: the first segment the local server answered after the most recent seek, which is the one
    /// whose content opens the run that landing sits in. Identifying it is what makes the landing
    /// reading a question about ONE segment: asked of the whole plan, "does this run open on a playlist
    /// position" is a coincidence 31 boundaries wide.
    private var firstDeliveredIndexSinceSeek: Int?
    /// The last index a fetch declared. A cold fetch reaches the provider BEFORE the producer has
    /// opened its gate, so the placement can precede the offset it is worth; this is what lets the
    /// gate publish for a placement that already happened.
    private var lastPlacedIndex: Int = .min
    /// AE#412: the index the most recent gate open belongs to and what it opened with. Separate from
    /// `epochAxisByIndex` because a re-cut BLOCKS on it: a waiter needs something to be signalled on,
    /// which a dictionary is not. Signalled through `gateOpenCondition`.
    private var lastGateOpen: (index: Int, axis: EpochAxis)?
    private let gateOpenCondition = NSCondition()
    /// AE#412: indices whose epoch an AE#412 re-cut started. Such a segment goes into a timeline
    /// AVPlayer is already building, and it puts it at its own tfdt there (measured 3 of 3 with
    /// `play --picture-probe`: `axisErr` 0.000 at offsets of 1, 5 and 9 s), so its distance to its
    /// advertised start is not an axis offset and must not compose into one. Guarded by
    /// `anchorShiftLock`, alongside the table it keeps entries out of.
    private var recutMark: RecutMark?
    /// Epoch of `producer`, mirrored under `anchorShiftLock` (audit SEG-104).
    private var installedProducerEpoch: UInt64?
    private let shiftLock = NSLock()
    private var _playlistShiftSeconds: Double = 0

    private var sourceVideoTbSeconds: Double = 1.0 / 1000.0

    /// Source bitrate in bps for HLS BANDWIDTH/AVERAGE-BANDWIDTH. 0 when libavformat can't
    /// compute it; callers fall back to an over-declared estimate to avoid CoreMediaErrorDomain -12318.
    private var sourceBitrate: Int64 = 0

    /// Fires on each gate open (initial + restart) so AetherEngine keeps its shift in step
    /// for subtitle cue lookup.
    /// `(shiftSeconds, seamItemSeconds)`: the new shift, and the item-axis position from which it applies
    /// (this producer's planned first tfdt). Content below that position was muxed under the previous shift
    /// and can still be in AVPlayer's buffer, so the host records a seam rather than replacing the scalar (#260).
    var onPlaylistShiftChanged: (@Sendable (Double, Double) -> Void)?

    /// #240: link arbitration shared with the engine's subtitle side readers. Set by `AetherEngine`
    /// before `start()`; nil when the session is driven without one (`aetherctl`, tests), which
    /// leaves the readers ungated exactly as before.
    var sideReaderLinkGate: SideReaderLinkGate?

    /// Fires when AVKit scrub drives a producer restart (AetherEngine#38). `(true, playlistTime)`
    /// at restart-run start; `(false, nil)` when settled. `playlistTime` folds with
    /// `playlistShiftSeconds` onto the source-PTS `seekTarget`, and is a LOWER BOUND on where the
    /// picture will land (the restart aims at the segment containing the requested time).
    ///
    /// The falling edge is "the producer is now producing at the new index", NOT "AVPlayer rendered it".
    /// The engine no longer treats it as a landing; see `AetherEngine.setNativeScrubSeek`.
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
    /// frozen fetch target is not a wedge, issue #65 pause false-positive).
    var playIntentProvider: (@Sendable () -> Bool)?

    /// AE#520 round 2: how long the consumer can keep playing out of what it already holds, readable
    /// off the main actor. Wired by AetherEngine to a thread-safe mirror the telemetry sampler writes,
    /// and handed to the segment provider, whose outage close spends a depth: the segments it has not
    /// fetched yet are only half of one. nil on the software path and between item swaps.
    var consumerBufferedSecondsProvider: (@Sendable () -> Double?)?

    /// Whether AVPlayer has ever presented a frame this item (its `timeControlStatus` reached `.playing`
    /// at least once), readable off the main actor. Wired by AetherEngine to a thread-safe mirror and
    /// threaded onto every producer so the VOD backpressure wedge detector stays suspended through cold
    /// pre-roll (#35/#93 startup: a flat clock before the first frame is not a wedge).
    var hasStartedRenderingProvider: (@Sendable () -> Bool)?

    /// The requested-but-unlanded user seek target (AVPlayer/item clock axis), readable off the main
    /// actor; nil = none pending. Wired by AetherEngine to a thread-safe mirror of its recovery seek
    /// intent (#93 retest). A wedge re-anchor must aim the producer here, not at the frozen clock:
    /// after a hard zero-tolerance seek AVPlayer only requests media at the TARGET, so re-producing
    /// the frozen position serves segments nobody will ever fetch (and its window refill can evict
    /// the target's segments from retention).
    var recoverySeekTargetProvider: (@Sendable () -> Double?)?

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
    /// The #79 / #169 restart's replacement demuxer, from before its open until the restart installs
    /// or drops it, so `stop()` can abort that open and the seek after it (audit SEG-3 follow-up).
    private var restartReopenDemuxer: Demuxer?
    /// Fires on live program-boundary rebase: `(newShiftSeconds, seamOutputSeconds)`. AetherEngine
    /// defers applying the shift until playback crosses `seamOutputSeconds` so the clock doesn't jump.
    var onPlaylistShiftRebased: (@Sendable (Double, Double) -> Void)?
    /// Fires on `PumpExitReason.sourceReplay`; host must re-negotiate a fresh session.
    var onLiveSourceReset: (@Sendable () -> Void)?
    /// AE#627: the first join read video for the whole keyframe wait and found no point the native
    /// route can open a segment on. Reopening joins the same bitstream, so the engine decides between
    /// the software path and telling the host (`escalateLiveReopenExhaustion`) instead. Unset, the
    /// session falls back to the ordinary reopen budget.
    var onLiveJoinWithoutEntryPoint: (@Sendable () -> Void)?
    /// AE#641: the live audio bridge decoded not one frame of the selected stream (index, bridge
    /// summary). Nothing inside the session can recover it: a producer rebuild hands the same decoder
    /// the same bytes, and the served media keeps an audio track that will never be filled.
    var onLiveAudioDecodesNothing: (@Sendable (Int32, String) -> Void)?
    /// #126: fires when a VOD pump dies on a read error having produced nothing (zero packets
    /// written, empty cache). The playlist exists but no segment will ever land, so AVPlayer
    /// would sit in waitingToPlay forever; the engine surfaces a fatal error instead.
    ///
    /// Never call this directly; go through `surfaceVODSourceFailure` so the sequential startup
    /// gate is released with it (#370 follow-up).
    /// #377: the third parameter classifies the failure. A source that is being metered is not a
    /// source that is gone, and the reader's `-1` cannot say which, so the kind is decided here
    /// and published rather than inferred from the code downstream.
    var onVODSourceFailed: (@Sendable (Int32, String, PlaybackErrorKind) -> Void)?

    /// The one way a VOD session surfaces a terminal source failure (#370 follow-up).
    ///
    /// #370 released a held startup-playlist GET at the two surfaces its own trace ran through, but
    /// a sequential origin reaches three more: `.muxerFailed` revives into `requestRestart`, which a
    /// sequential origin refuses, and the AE#366 moov-prime exhaustion and AE#169 read-error
    /// exhaustion end on their own surfaces. Each of those can fire before the first duration is
    /// published (an E-AC-3 archive whose first segment carries no audio packet is the field shape),
    /// and the server thread then sat out the remaining ~30 s of a session that had already failed.
    /// Pairing the release with the surface makes that structural instead of a call site to remember.
    func surfaceVODSourceFailure(_ code: Int32, _ reason: String,
                                 kind: PlaybackErrorKind = .vodSourceFailed) {
        // AE#641: a silent bridge is reported the moment it is structural and again by the muxer arms
        // that follow it on the E-AC-3 route; the session learns it once.
        if kind == .audioBridgeProducedNoOutput {
            silentBridgeSurfaceLock.lock()
            let first = !silentBridgeFailureSurfaced
            silentBridgeFailureSurfaced = true
            silentBridgeSurfaceLock.unlock()
            guard first else { return }
        }
        provider?.abortSequentialStartupWait()
        onVODSourceFailed?(code, reason, kind)
    }
    private let silentBridgeSurfaceLock = NSLock()
    private var silentBridgeFailureSurfaced = false
    /// Session-long FLAC bridge for codecs illegal in fMP4. Engine-owned (not producer-owned) so
    /// encoder state survives producer restarts; `startSegment()` rebases PTS on each restart.
    var audioBridge: AudioBridge?
    var segmentPlan: [Segment] = []

    /// AE#408: true only while `segmentPlan` is the keyframe-aligned plan, whose boundaries are
    /// container index entries and therefore CLAIM to be random-access points. The producer re-aims
    /// below a boundary that breaks that claim; it must not do so for the uniform grid (which never
    /// claimed it) or a source-declared plan (which aims below its IRAP by design, AE#268).
    var planBoundariesClaimRandomAccess = false

    /// AE#561: the axis `segmentPlan`'s boundaries are stamped on, handed to every producer this
    /// session builds so its cutter gate compares a packet on the plan's own axis. Set together with
    /// `planBoundariesClaimRandomAccess`, because it is the same plan that makes it meaningful: only
    /// the keyframe-aligned plan's boundaries ARE index entries. `.decode` for every other plan,
    /// which is what the cutter compared before the axis existed.
    var planBoundaryAxis: PlanBoundaryAxis = .decode

    /// Guards subsystem refs + `sessionEpoch`. Never held across waits or network I/O so
    /// `stop()` on the main thread is never blocked behind a restart's 5 s waitForFinish.
    let restartLock = NSLock()

    /// AE#464: the host's audio presentation offset, in seconds, that `makeProducer` hands to every
    /// muxer it builds. A muxer's offset is fixed for its life, so setting this alone changes nothing
    /// that has already been cut; `AetherEngine.setAudioDelay` writes it as part of a reload, which is
    /// what actually replaces the segments and the item holding them.
    public var audioDelaySeconds: Double = 0

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
    /// How many pumps must have folded the index the consumer waits on before the wedge handler
    /// treats the gap as unrecoverable rather than re-anchoring into it again (#358). One fold can
    /// still be filled by a rebase; two is the recovery reproducing its own trigger.
    static let foldsProvingUnrecoverableGap = 2

    /// #99: bounded revive for a VOD pump that died with muxerFailed (under `restartLock`).
    /// performRestart rebuilds muxer AND re-arms the audio bridge, so transient causes heal;
    /// a persistent cause exhausts the cap instead of restart-storming.
    var muxerFailureReviveGate = MuxerFailureReviveGate(maxAttempts: 2)

    /// AE#169 round 2: bounded revive for a VOD pump that died on a MID-SESSION read error (under
    /// `restartLock`). #126 only surfaced the nothing-ever-produced case as fatal and assumed the
    /// scrub/wedge arms covered the rest; a tail request within the forward-wait window of the dead
    /// producer's front reached neither (rrgomes: seg719 miss x11 into -12889), so the exit gets
    /// its own event-driven arm. Same gate shape as #99.
    var readErrorReviveGate = MuxerFailureReviveGate(maxAttempts: 2)
    /// #377: a separate, larger budget for read errors caused by an origin REFUSING us rather than
    /// failing. Separate because the two must not spend each other: two attempts is right for a
    /// source that may be gone, and wrong for one that is merely refusing for a while, where each
    /// attempt is spaced by a growing backoff and is expected to succeed eventually.
    ///
    /// Round 6 made it a wall clock per refusal window rather than an attempt count per session.
    /// See `RefusingSourceReviveBudget` for why: the old figure was the emergent product of two
    /// constants that did not know about each other, and it was never reset.
    var rateLimitReviveGate = RefusingSourceReviveBudget()

    /// AE#169 round 2 (under `restartLock`): the demuxer's last read threw, so the next
    /// performRestart replaces it via the #79 fresh-demuxer path instead of seeking a connection
    /// that just failed (a sticky pb error would burn the revive gate without one fresh attempt).
    var mainDemuxerSuspectDead = false

    /// AE#222 (under `restartLock`): one real audio frame from this source, kept for the whole session so
    /// every muxer built from here on writes moov (with the packet-derived dec3/dac3/dmlp built from THIS
    /// frame) at init. Set only after a pump proved the source cuts its first segment before any audio packet
    /// arrives, which no probe can predict: movenc rejects an immediate moov for E-AC-3 regardless of
    /// extradata, so a pre-flight cannot tell a video-first interleave apart from a healthy source.
    var sessionAudioMoovPrimeFrame: [UInt8]?
    /// AE#366: a producer searched the whole source for a frame that can build the audio sample
    /// entry and found none. Structural (never set from a read failure), so the session stops paying
    /// for the search on every later revive attempt.
    var sessionAudioMoovPrimeUnobtainable = false

    /// AE#222 (under `restartLock`): bounded rebuild for a pump that deferred its first cut. One attempt is
    /// enough by construction (the prime is captured before the restart and reused for the session's whole
    /// life); the gate exists so a source that somehow defers again cannot restart-storm.
    var audioSampleEntryPrimeGate = MuxerFailureReviveGate(maxAttempts: 1)

    /// AE#169 round 3 (under `restartLock`): bounded re-anchor for a VOD pump whose restart
    /// scan-forward gate starved to EOF (no runtime keyframe at/after the targeted plan boundary,
    /// the unproducible tail segment). Same gate shape as #99.
    var gateStarvationReviveGate = MuxerFailureReviveGate(maxAttempts: 2)

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

    /// Target segment duration. Apple spec recommends 6 s; 4 s cuts ~370 ms first-segment
    /// latency on a 24 fps 1440p LAN source and stays within the spec's 2-6 s range.
    /// [MovieClaw P33] 点播改为 2 秒（`AetherEngine.vodSegmentTargetSeconds`，宿主可在装载前改）；直播仍按 4 秒切
    static var targetSegmentDuration: Double { AetherEngine.vodSegmentTargetSeconds }

    /// [MovieClaw P33] 上游的 4 秒。直播标准档、量不出关键帧间隔的均匀切分仍用它：
    /// 步长短于 GOP 会切出没有关键帧的空段（#358），间隔未知时不冒这个险
    static let upstreamSegmentTargetSeconds: Double = 4.0

    /// [MovieClaw patch P3] Cut target for segment 0 only. AVPlayer cannot start before the first
    /// segment is fully produced and served, so its size is start latency: on an 87 Mbit/s UHD remux
    /// a 4 s segment 0 is 43 MB, measured at 0.84 s of producer wait from a NAS on device. A ~1 s
    /// first segment brings that to about a quarter; every later boundary keeps the 4 s cadence
    /// (thresholds F, F+T, F+2T, ... stay absolute, as the planner requires).
    static let firstSegmentTargetDuration: Double = 1.0

    /// Live cut target under `LiveJoinProfile.fastZap` (AE#195): cut at every keyframe past 0.5 s, so
    /// segments quantize to the source GOP and the served TARGETDURATION (whose 3 x holdback gates the
    /// first live manifest, AE#189) is driven by `ceil(max EXTINF)` instead of the
    /// `ceil(1.5 x cut target)` floor (which collapses to 1 at this value).
    static let fastZapLiveCutTargetSeconds: Double = 0.5

    /// Resolve a host `LiveJoinProfile` to the live segment cut target.
    static func liveCutTargetSeconds(for profile: LiveJoinProfile) -> Double {
        switch profile {
        case .standard: return upstreamSegmentTargetSeconds   // [MovieClaw P33]
        case .fastZap: return fastZapLiveCutTargetSeconds
        }
    }

    /// Cue-prewarm seek deadline. MKV Cues resolve in under 1 s; a missing/out-of-bounds index
    /// degrades into a multi-GB linear scan. Beyond this, abort and build a uniform-stride plan.
    static let cuePrewarmTimeout: TimeInterval = 10.0

    /// SegmentCache retention budget (#93 / Sodalite#32): capped at 2 GiB and clamped to a quarter
    /// of the tmp volume's available capacity, so a nearly-full device never trades playback
    /// headroom for seek history.
    ///
    /// Live used to pass 0 on the reasoning that the sliding playlist had already dropped
    /// everything behind the window, so retention would serve nothing. That had it backwards. The
    /// playlist is the LOOSER bound (`windowSegmentCount`, e.g. 300 segments for a 600 s DVR window
    /// at a 2 s cadence); `pruneOutsideWindow` is the tighter one, and with a 0 budget it takes the
    /// hard-window branch and cuts at `currentTargetIndex - backwardWindow`, i.e. 20 segments. A
    /// live session therefore retained ~42 s no matter what `dvrWindowSeconds` promised, while the
    /// playlist and `liveSeekableRange` advertised the full window: a rewind past ~42 s asked for a
    /// segment the cache had deleted, and live has no `restartHandler` to re-produce it. The budget
    /// is exactly the mechanism that keeps that history resident, so live gets it too.
    ///
    /// `capRelaxed` (#207) drops the 2 GiB default for a host that explicitly asked to pre-buffer more
    /// than the historical window could hold; the quarter-of-free-space clamp, which is what actually
    /// protects the volume, always applies. Unknown capacity keeps the conservative cap either way.
    static func sessionRetentionBudgetBytes(volumeAvailableBytes: Int64?, capRelaxed: Bool = false) -> Int {
        let cap = 2 << 30
        guard let available = volumeAvailableBytes else { return cap }
        let quarterOfFree = max(0, Int(available / 4))
        return capRelaxed ? quarterOfFree : min(cap, quarterOfFree)
    }

    /// Largest forward window the default 2 GiB retention budget covers by construction
    /// (150 segments x ~10 MB for 4K HEVC ~ 1.5 GB), i.e. the old `clampedForwardWindow` ceiling.
    static let defaultRetentionCapWindowCeiling = 150

    /// #207: a window past `defaultRetentionCapWindowCeiling` is an explicit host opt-in into a
    /// whole-source prefetch, so the budget follows it up (see `sessionRetentionBudgetBytes`).
    static func retentionCapRelaxed(forwardWindowSegments: Int) -> Bool {
        forwardWindowSegments > defaultRetentionCapWindowCeiling
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
        forceDolbyVisionOnNonDVDisplay: Bool = false,
        dolbyVisionHandling: DolbyVisionHandling = .automatic,
        dolbyVisionRPUProfile: Int? = nil,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioSourceStreamIndexOverride: Int32? = nil,
        undecodableAudioStreamIndices: Set<Int32> = [],
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLiveSession: Bool = false,
        dvrWindowSeconds: Double? = nil,
        liveJoinProfile: LiveJoinProfile = .standard,
        liveCutTargetSeconds: Double? = nil,
        blockingReloadOverride: Bool? = nil,
        liveCadenceObservation: (@Sendable () -> Double?)? = nil,
        liveClosedCadenceObservation: (@Sendable () -> Double?)? = nil,
        liveUpstreamSegmentDurationObservation: (@Sendable () -> Double?)? = nil,
        liveJoinBacklogObservation: (@Sendable () -> Double?)? = nil,
        liveJoinSpentObservation: (@Sendable () -> Bool?)? = nil,
        upstreamSelfReportedTargetDuration: Double? = nil,
        preopenedDemuxer: Demuxer? = nil,
        sourceReopenableByURL: Bool = true,
        customSourceReopenFactory: CustomSourceReopenFactory? = nil,
        companionAudioReader: IOReader? = nil,
        probesize: Int64? = nil,
        maxAnalyzeDuration: Int64? = nil,
        sequentialOrigin: Bool = false,
        heldSourceConnection: Bool = false,
        declaredDurationSeconds: Double? = nil,
        forwardBufferSegments: Int? = nil,
        backwardBufferSegments: Int? = nil,
        hostMatroskaCues: MatroskaHostCues? = nil
    ) {
        self.sourceURL = url
        self.sourceHTTPHeaders = sourceHTTPHeaders
        self.sequentialOrigin = sequentialOrigin
        self.heldSourceConnection = heldSourceConnection
        self.declaredDurationSeconds = declaredDurationSeconds
        // Caller-bounded find_stream_info budget (#68); nil keeps the .playback default. Applied only to the
        // fallback open / live reopen here; the happy path reuses the already-budgeted preopenedDemuxer.
        // #377: the held transport is carried too. It is chosen at open time, so a reopen that leaves
        // it out puts the session silently back on ranged requests against the one kind of origin the
        // host turned it on for, and the flag reads as having stopped working half way through.
        self.openProfile = DemuxerOpenProfile.playback.withProbeBudget(
            probesize: probesize, maxAnalyzeDuration: maxAnalyzeDuration)
            .withSequentialOrigin(sequentialOrigin, declaredDuration: declaredDurationSeconds)
            .withHeldSourceConnection(heldSourceConnection)
            .withHostMatroskaCues(hostMatroskaCues)   // [MovieClaw P58]
        self.hostMatroskaCues = hostMatroskaCues
        self.dvModeAvailable = dvModeAvailable
        self.displaySupportsHDR = displaySupportsHDR
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.forceDolbyVisionOnNonDVDisplay = forceDolbyVisionOnNonDVDisplay
        self.dolbyVisionHandling = dolbyVisionHandling
        self.dolbyVisionRPUProfile = dolbyVisionRPUProfile
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.audioSourceStreamIndexOverride = audioSourceStreamIndexOverride
        self.undecodableAudioStreamIndices = undecodableAudioStreamIndices
        self.audioBridgeMode = audioBridgeMode
        self.isLiveSession = isLiveSession
        self.dvrWindowSeconds = dvrWindowSeconds
        self.liveJoinProfile = liveJoinProfile
        // An explicit cut target keeps precedence for direct callers. Otherwise resolve the profile.
        let resolvedLiveCutTarget = liveCutTargetSeconds
            ?? Self.liveCutTargetSeconds(for: liveJoinProfile)
        self.liveCutTargetSeconds = resolvedLiveCutTarget
        self.blockingReloadOverride = blockingReloadOverride
        // Trust OBSERVED arrival cadence, not the upstream's self-reported TARGETDURATION, for blocking-reload
        // eligibility and the TARGETDURATION floor (-15410, AetherEngine#167). Built only for live ingest
        // sources that expose a cadence observation; URL live and VOD leave it nil and fall back to the
        // signal-less default (blocking-reload on, server's own 1.5x-cut-target floor). AE#447: the advert
        // is passed for the seal log, it no longer seeds the floor.
        self.liveCadencePolicy = liveCadenceObservation.map { observe in
            LiveCadencePolicy(
                observe: observe,
                cutTargetSeconds: resolvedLiveCutTarget,
                observeSealEvidence: {
                    LiveCadenceEvidence(
                        closedCadenceSeconds: liveClosedCadenceObservation?(),
                        servedSegmentDurationSeconds: liveUpstreamSegmentDurationObservation?(),
                        joinBacklogSeconds: liveJoinBacklogObservation?(),
                        joinIsSpent: liveJoinSpentObservation?()
                    )
                },
                selfReportedTargetDurationSeconds: upstreamSelfReportedTargetDuration
            )
        }
        self.preopenedDemuxer = preopenedDemuxer
        self.sourceReopenableByURL = sourceReopenableByURL
        self.customSourceReopenFactory = customSourceReopenFactory
        self.companionAudioReader = companionAudioReader
        self._forwardWindowSegments = Self.clampedForwardWindow(forwardBufferSegments)
        self.backwardWindowSegments = Self.clampedBackwardWindow(backwardBufferSegments)
    }

    /// [MovieClaw P25] 分片缓存的后方窗口（段数）。默认 20 段（AVPlayer 换音频交接时会回头重取 7～10 段，
    /// 窗口太小会连环重启生产者），宿主在存储紧张时可以收小（`LoadOptions.backwardBufferSegments`），
    /// 代价是回头重取要重新生产。至少留 2 段
    let backwardWindowSegments: Int

    static func clampedBackwardWindow(_ requested: Int?) -> Int {
        guard let requested else { return 20 }
        return min(20, max(2, requested))
    }

    /// Session forward-buffer window in segments. Drives BOTH the producer's race-ahead
    /// (`HLSSegmentProducer.bufferAheadSegments`) and the cache's forward window
    /// (`SegmentCache.forwardWindow`); the two MUST stay identical (a drift is exactly what stalls
    /// AVPlayer, see `SegmentCache`). From `LoadOptions.forwardBufferSegments`; nil -> historical 10.
    /// [MovieClaw P20] 可在运行中放大（`setForwardWindowSegments`），经独立的锁读写
    /// （建生产者时可能正持有 restartLock，不能复用它）
    var forwardWindowSegments: Int {
        forwardWindowLock.lock(); defer { forwardWindowLock.unlock() }
        return _forwardWindowSegments
    }
    private var _forwardWindowSegments: Int
    private let forwardWindowLock = NSLock()

    /// [MovieClaw P20] 运行中调整前向窗口：当前生产者、会话缓存、之后因跳转重建的生产者都按新值。
    ///
    /// 磁盘仍受开播时算好的留存预算约束（`PrefetchDiskBudget`：默认 min(2 GiB, 剩余空间 1/4)），
    /// 高码率片子窗口装不满时由磁盘停泊兜底，不会把手机存储写满
    func setForwardWindowSegments(_ requested: Int) {
        let segments = Self.clampedForwardWindow(requested)
        forwardWindowLock.lock()
        let unchanged = _forwardWindowSegments == segments
        _forwardWindowSegments = segments
        forwardWindowLock.unlock()
        guard !unchanged else { return }
        let subsystems = subsystemSnapshot()
        subsystems.producer?.setBufferAheadSegments(producerBufferAheadSegments)   // 暂停下载时仍为 0（P23）
        subsystems.cache?.setForwardWindow(segments)
        EngineLog.emit(
            "[HLSVideoEngine] [MovieClaw P20] forwardWindow -> \(segments) seg "
            + "(retention budget \(retentionBudgetBytes / (1 << 20)) MiB still bounds the disk)",
            category: .session
        )
    }

    /// [MovieClaw P23] 宿主要求暂停下载（蜂窝网 / 低数据模式下用户按了暂停）：生产者的前向窗口压到 0，
    /// 只产 AVPlayer 真来要的段（暂停时它最多再要一两段），不再往前读；恢复时还原窗口，停泊中的泵按 P20 的
    /// 重算立即放行。因跳转新建的生产者也按这个状态起步
    private var prefetchSuspended = false

    func setPrefetchSuspended(_ suspended: Bool) {
        forwardWindowLock.lock()
        let changed = prefetchSuspended != suspended
        prefetchSuspended = suspended
        let window = _forwardWindowSegments
        forwardWindowLock.unlock()
        guard changed else { return }
        subsystemSnapshot().producer?.setBufferAheadSegments(suspended ? 0 : window)
        EngineLog.emit("[HLSVideoEngine] [MovieClaw P23] prefetch \(suspended ? "suspended" : "resumed (window \(window) seg)")",
                       category: .session)
    }

    /// 新建生产者用的前向段数：暂停下载时为 0
    private var producerBufferAheadSegments: Int {
        forwardWindowLock.lock(); defer { forwardWindowLock.unlock() }
        return prefetchSuspended ? 0 : _forwardWindowSegments
    }

    /// [MovieClaw P20] 按「多少秒内容」设前向窗口：用本场分段计划的平均段长换算成段数。
    /// 段长随片源的关键帧间隔走，长 GOP 的片子一段有 8～10 秒，按固定段数会多攒好几倍。返回生效的段数
    @discardableResult
    func setForwardWindowDuration(_ seconds: Double) -> Int {
        let averageSegmentSeconds: Double = {
            restartLock.lock()
            defer { restartLock.unlock() }
            guard let first = segmentPlan.first, let last = segmentPlan.last else { return 4 }
            let span = last.startSeconds + last.durationSeconds - first.startSeconds
            return span > 0 ? span / Double(segmentPlan.count) : 4
        }()
        let segments = Self.clampedForwardWindow(Int((seconds / max(0.5, averageSegmentSeconds)).rounded(.up)))
        setForwardWindowSegments(segments)
        return segments
    }

    /// Session retention budget resolved in `start()`; also bounds the producer's race-ahead on disk
    /// (#207, see `PrefetchDiskBudget`). Live resolves the same budget, so the DVR history the
    /// playlist advertises stays resident; the producer-side prefetch park it also feeds is
    /// VOD-only (`advanceMuxer`), so live cannot park on it.
    private var retentionBudgetBytes: Int = 0
    /// #687: this session's entry in the process-wide ledger, released on `stop()`.
    private var retentionClaim: RetentionClaims.Claim?

    /// Clamp for `forwardWindowSegments`: below 4 the window would undercut AVPlayer's own ~5-7-segment
    /// prefetch and starve it (see `LiveWindowSizing.minSafeSegments`). The 2700 ceiling (~3 h at 4 s
    /// segments) is a sanity bound against accidental values, not a cost bound: it covers a whole
    /// feature film, so a host's "buffer without limit" option can pass `Int.max` (#207). The disk cost
    /// is bounded in bytes rather than segments, by the session retention budget the producer parks on
    /// (`PrefetchDiskBudget`, `sessionRetentionBudgetBytes`). nil keeps the historical default of 10.
    static func clampedForwardWindow(_ requested: Int?) -> Int {
        min(max(requested ?? 10, 4), 2700)
    }

    /// When true, `start()` skips the VOD duration guard / cue prewarm / precomputed plan and
    /// uses the forward-only live cut mode (producer cuts at each IDR past the duration target).
    let isLiveSession: Bool

    /// Controls whether the first live manifest may take the bounded shallow-window path.
    private let liveJoinProfile: LiveJoinProfile

    /// Live segment cut target for this session, resolved from the host's `LiveJoinProfile` (AE#195).
    /// Drives the producer's keyframe cut, `LiveWindowSizing`, and (via the served TARGETDURATION floor)
    /// the AE#189 startup-cushion depth. VOD ignores it (cuts come from the precomputed plan).
    let liveCutTargetSeconds: Double

    /// False for IOReader-backed sources (`aether-custom://source` placeholder); `handlePumpFinished`
    /// surfaces loss via `onLiveSourceReset` immediately instead of burning 6 reopen attempts.
    let sourceReopenableByURL: Bool

    /// #199: vends a fresh reader (plus FFmpeg format hint) for an engine-created ingest source, so a
    /// live pump exit reopens in-session instead of delegating to host retune. Called once per reopen
    /// attempt; each vended reader is owned by this session (closed on replacement and on stop). nil for
    /// URL sources and host-provided custom readers.
    public typealias CustomSourceReopenFactory = @Sendable () -> (reader: IOReader, formatHint: String?)?
    let customSourceReopenFactory: CustomSourceReopenFactory?

    /// #199: the reader vended by `customSourceReopenFactory` that the CURRENT demuxer reads from.
    /// Guarded by `restartLock`. The original load's reader stays engine-owned (AetherEngine closes it
    /// in stopInternal); only factory-vended replacements are owned here.
    var reopenCustomReader: IOReader?

    /// Demuxed audio rendition reader for live HLS ingest. When the main demuxer finds no audio and
    /// this is non-nil, `start()` opens `sideAudioDemuxer` over it. Engine owns the side demuxer, not
    /// this reader (owned by the host's main reader). nil for muxed-audio sessions.
    private let companionAudioReader: IOReader?

    /// Host override for LL-HLS blocking-reload (`LoadOptions.liveBlockingReload`); nil = auto (#167).
    private let blockingReloadOverride: Bool?

    /// Observed-cadence policy driving blocking-reload eligibility and the TARGETDURATION floor for live
    /// ingest sources; nil for URL live and VOD (#167).
    private let liveCadencePolicy: LiveCadencePolicy?

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
    /// #377: opt-in held source transport, carried onto every open this session makes itself.
    let heldSourceConnection: Bool
    /// [MovieClaw P58] 服务端给的 Matroska 精简索引：卡死重开的新解复用器也要带上，否则它得把原索引整段重新下载
    let hostMatroskaCues: MatroskaHostCues?

    /// The profile the VOD scrub restart opens its replacement demuxer with. Bounded
    /// find_stream_info budget, and the same SOURCE declarations as the first open: a ranged reopen
    /// would splice fabricated-position bytes into a sequential pump, and one that dropped the held
    /// transport would put a session the host asked to hold a connection back on ranged requests
    /// against the origin that punishes them, half way through and with nothing saying so.
    var restartReopenProfile: DemuxerOpenProfile {
        DemuxerOpenProfile.restartReopen
            .withSequentialOrigin(sequentialOrigin, declaredDuration: declaredDurationSeconds)
            .withHeldSourceConnection(heldSourceConnection)
            .withHostMatroskaCues(hostMatroskaCues)   // [MovieClaw P58]
    }

    /// `LoadOptions.sequentialOrigin` for this session. Gates the VOD readError revive
    /// (`+LiveReopen`): a revive's fresh demuxer can only reopen from byte 0 and then fails its
    /// anchor seek on the non-seekable pb, burning a connection slot on origins that are typically
    /// connection-capped, so the session surfaces `onVODSourceFailed` directly instead.
    let sequentialOrigin: Bool

    /// `LoadOptions.declaredDurationSeconds`, threaded into every fresh-demuxer profile this
    /// session builds (wedge restart) so a reopened demuxer reports the same trusted duration.
    let declaredDurationSeconds: Double?

    /// Every site that would set the producer down somewhere other than byte 0 asks this first:
    /// the readError revive (`+LiveReopen`), the restart coalescer (`requestRestart`), and the
    /// resume anchor for the first producer. A sequential origin answers only from byte 0, and
    /// the demuxer seek that would move the cursor fails silently on a non-seekable pb, so a
    /// reposition does not fail loudly, it mislabels content. Live sessions are untouched: their
    /// reopen path re-requests the feed by URL and never seeks.
    var sequentialOriginPinsProducerToZero: Bool { sequentialOrigin && !isLiveSession }


    // MARK: - Public API

    /// AE#246: map a failed fallback open onto the error the caller sees.
    ///
    /// The fallback open runs when the load-time probe did not hand over a demuxer, which includes
    /// the case where that probe failed for a transient reason. It is then the FIRST open to read
    /// the source body, so it is the one that produces the reader's HLS classification. Interpolating
    /// that typed error into `openFailed(reason:)` erased its domain and made a reroutable remote-HLS
    /// source terminal; the classification is rethrown verbatim so `load()` can still reach the AE#154
    /// reroute (`hlsPlaylistOnVODPath`) or the live-path classification (`hlsPlaylistOnRawLivePath`,
    /// which AE#363 routes onto the live ingest for a URL source and rejects for a custom reader).
    /// A refused source (`httpStatus`) keeps its status the same way, so `load()` can publish it as
    /// `PlaybackErrorKind.sourceRefused` instead of a wrapped "invalid data", and a refused handshake
    /// (`transportSecurityFailed`, AE#495) keeps its `NSURLError` code so it can publish as
    /// `sourceCertificateRejected` rather than as a source that is merely unreadable. Every other
    /// failure keeps the historical wrapped shape.
    static func openFailure(from error: Error) -> Error {
        if let readerError = error as? AVIOReaderError {
            switch readerError {
            case .hlsPlaylistOnVODPath, .hlsPlaylistOnRawLivePath, .httpStatus,
                 .transportSecurityFailed:
                return readerError
            default:
                break
            }
        }
        return HLSVideoEngineError.openFailed(reason: "\(error)")
    }

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
                throw Self.openFailure(from: error)
            }
        }
        demuxer = dem
        dem.onNetworkPhaseChanged = onNetworkPhaseChanged   // surface source stall/reconnect to playbackPhase (#85)
        dem.playIntentProvider = playIntentProvider   // a held connection ends on a pause, not on a parked producer

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
        // AE#270: the source PTS the container's own timeline starts at. `duration` is measured from here,
        // so this is the PTS that maps to display-0 for the host (0 for an MP4, 1.4 s for anything ffmpeg
        // wrote as MPEG-TS, hours for VOD carved out of a broadcast stream). A negative start time is an
        // encoder-side reorder artifact rather than an origin, so it clamps to 0.
        let formatStart = dem.formatStartTime
        sourceStartSeconds = formatStart == Int64.min ? 0 : max(0, Double(formatStart) / Double(AV_TIME_BASE))
        let durationSeconds = dem.duration
        var plan: [Segment]
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
            // [MovieClaw P37] 容器没声明码率时按总字节 ÷ 时长估，别让 BANDWIDTH 落到兜底值
            sourceBitrate = dem.estimatedBitRate(durationSeconds: durationSeconds)
            if dem.bitRate <= 0, sourceBitrate > 0 {
                EngineLog.emit("[HLSVideoEngine] [MovieClaw P37] 容器未声明码率，按片源大小估 \(sourceBitrate / 1_000_000) Mbit/s", category: .session)
            }

            // #409: settle the composition-offset repair while the demuxer still stands at the head.
            // It reads a short sample and holds those packets, so nothing is consumed; doing it later
            // would sample wherever the prewarm left the source, and hand the producer a head that is
            // six seconds into the file. The segment plan below needs the verdict either way, because
            // a repaired stream and the container's own index have to describe one ladder.
            dem.decideCompositionOffsetRepair()

            // AE#585: everything from here to the cursor reset in step 6 is index work, and it ends
            // where it began. Without this bracket the prewarm's seek to the middle reads as
            // playback moving away, the retained head is released, and playback's first read at
            // offset zero re-fetches the bytes the open (or the warm) already paid for.
            dem.beginIndexPass()

            // 2. Prewarm MKV Cues so libavformat's keyframe index is populated (1-2 byte-range reads).
            //    Bounded: a missing/out-of-bounds Cues index degrades into a multi-GB linear scan;
            //    abort past the deadline and fall back to the uniform-stride plan.
            //    #268: a segmented time-seekable source (HLS VOD ingest) has no index libavformat could
            //    load, and each reposition refetches a segment, so prewarming would buy the same
            //    uniform-stride plan for the price of two segment downloads at every session start.
            if dem.containerFormatName == "mpegts" {
                // [MovieClaw patch P1] MPEG-TS / M2TS carry no container index, so the mid-file seek
                // loads nothing: the plan falls back to uniform stride either way (see
                // `keyframeIndexIsTrustworthy`). On a Blu-ray m2ts served from a NAS the seek alone
                // measured 1.9 s of dead startup time, paid twice when an audio switch reloads.
                EngineLog.emit("[HLSVideoEngine] cue prewarm: skipped for MPEG-TS (no container index to load) [MovieClaw P1]")
            } else if dem.indexlessMatroska {
                // [MovieClaw P18] 文件头说这个 MKV 没有可用的 Cues（没写，或下载不完整、指针在文件尾之外）：往片中间跳
                // 加载不到任何索引，只会线性读到预热上限（真机 10 秒），分片计划照样退回均匀切分
                EngineLog.emit("[HLSVideoEngine] cue prewarm: skipped, the MKV has no usable Cues index (the seek would be a linear scan) [MovieClaw P18]")
            } else if !Self.cuePrewarmMayRun(hasSegmentedReader: dem.timeSeekableReader != nil,
                                      isSourceSeekable: dem.isSourceSeekable) {
                EngineLog.emit(
                    dem.timeSeekableReader != nil
                        ? "[HLSVideoEngine] cue prewarm: skipped for a segmented source (no index to load, every reposition refetches a segment)"
                        : "[HLSVideoEngine] cue prewarm: skipped for a forward-only source (the seek would be a linear read, "
                          + "and the prefix it consumes is the producer's only pass)"
                )
            } else {
                // [MovieClaw P45] 跳到起播点而不是片中间：任何一次跳转都会让 libavformat 加载延后的 Cues，索引一样到手；
                // 跳完读到的那一簇正是生产者接下来要读的。片源字节缓存跨启动保留（P42）以后，续播时文件头、Cues 与续播点
                // 附近都在本机，片中间那一簇却多半不在——真机开着 P42 续播 MKV，这一步仍有 45～70 毫秒是它的网络冷读
                let prewarmTarget = AetherEngine.cuePrewarmTargetsStart
                    ? min(max(0, initialStartSeconds ?? 0), max(0, durationSeconds - 1))
                    : durationSeconds * 0.5
                let prewarmStart = DispatchTime.now()
                let prewarmOK = dem.seekBounded(to: prewarmTarget, timeout: Self.cuePrewarmTimeout)
                let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
                if prewarmOK {
                    EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", prewarmTarget))s took \(String(format: "%.1f", prewarmMs))ms")
                } else {
                    EngineLog.emit("[HLSVideoEngine] cue prewarm: capped at \(String(format: "%.1f", prewarmMs))ms (no usable Cues index, index points past EOF or is absent); building plan from whatever keyframes were scanned")
                }
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
            // AE#268: a segmented source declares its own random-access points. Prefer them over both
            // builders below: the index is sparse on MPEG-TS, and the uniform grid advertises
            // boundaries no keyframe sits on (a 4 s grid over a 10 s GOP is producible on one boundary
            // in five; a restart at any other one opens its gate a GOP late and skews every index
            // mapping until AVPlayer starves).
            let declaredSegmentStarts = dem.timeSeekableReader?.segmentStartTimesSeconds ?? []
            let segmentedAnchorPts: Int64 = keyframes.sorted().first
                ?? (videoStream.pointee.start_time != Int64.min
                    ? max(0, videoStream.pointee.start_time) : 0)
            let segmentedPlan = Self.buildSegmentedSourcePlan(
                segmentStartsSeconds: declaredSegmentStarts,
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds,
                startPts0: segmentedAnchorPts
            )
            if !segmentedPlan.isEmpty {
                plan = segmentedPlan
                self.firstKeyframePts = segmentedAnchorPts
                self.firstKeyframeSeconds = Double(segmentedAnchorPts)
                    * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                EngineLog.emit(
                    "[HLSVideoEngine] segment plan: source-declared boundaries, "
                    + "\(plan.count) segments [anchorPts=\(segmentedAnchorPts) "
                    + "shortestSegment=\(String(format: "%.3f", plan.map { $0.durationSeconds }.min() ?? 0))s]",
                    category: .session
                )
            } else if keyframes.count >= 2, indexTrustworthy {
                plan = Self.buildKeyframeSegmentPlan(
                    keyframes: keyframes,
                    videoTimeBase: videoTimeBase,
                    sourceDurationSeconds: durationSeconds
                )
                planBoundariesClaimRandomAccess = true
                // [MovieClaw P36] 留下关键帧表与解码代价，供主力通路跳转按代价吸附
                let tbSeconds = Double(videoTimeBase.num) / Double(videoTimeBase.den)
                seekKeyframeSourceSeconds = keyframes.sorted().map { Double($0) * tbSeconds }
                seekDecodeCostPerSecond = KeyframeSnapPolicy.decodeCostPerSecond(
                    frameRate: AetherEngine.detectFrameRate(stream: videoStream),
                    width: Int(videoStream.pointee.codecpar.pointee.width),
                    height: Int(videoStream.pointee.codecpar.pointee.height))
                // AE#561: these boundaries ARE this container's index entries, so they carry its
                // stamping. Read from the demuxer that produced them, never from the URL or the
                // host's metadata: on a remux session the delivered container is the one indexed.
                planBoundaryAxis = PlanBoundaryAxis.forContainer(formatName: dem.containerFormatName)
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
                // #358: a grid finer than the GOP advertises boundaries no keyframe sits on, and the
                // keyframe-gated cutter leaves every one of them without a segment while the playlist
                // still offers it. Measure the spacing instead of assuming the target fits it.
                let anchorSeconds = Double(anchorPts) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                let spacing: KeyframeSpacing
                let stride: Double
                if sequentialOriginPinsProducerToZero {
                    // #370: the spacing scan starts with a seek (a silent no-op on the non-seekable
                    // sequential pb) and then consumes up to 30 s of the single byte-0-only
                    // connection; those packets never reach the pump, so the session starts late and
                    // silently drops the archive's first GOP(s). The #358 holes the scan exists to
                    // soften don't bite this path: the append playlist gives zero-duration holes no
                    // URI and its EXTINF is real by construction.
                    spacing = .unknown
                    stride = Self.upstreamSegmentTargetSeconds   // [MovieClaw P33]
                } else {
                    spacing = measureKeyframeSpacing(
                        demuxer: dem,
                        videoStreamIndex: videoIndex,
                        videoTimeBase: videoTimeBase,
                        fromSeconds: anchorSeconds
                    )
                    stride = Self.uniformStrideSeconds(spacing: spacing)
                }
                // [MovieClaw patch P3] The short first window still has to contain a keyframe, so it
                // never goes below the measured IRAP spacing (#358's reason for the stride floor).
                let firstWindow: Double
                if case .measured(let seconds) = spacing, seconds.isFinite, seconds > 0 {
                    firstWindow = Swift.min(stride, Swift.max(Self.firstSegmentTargetDuration, seconds))
                } else {
                    firstWindow = stride
                }
                plan = Self.buildUniformSegmentPlan(
                    videoTimeBase: videoTimeBase,
                    sourceDurationSeconds: durationSeconds,
                    startPts0: anchorPts,
                    strideSeconds: stride,
                    firstSegmentSeconds: firstWindow
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
                let spacingText: String
                if sequentialOriginPinsProducerToZero {
                    spacingText = "spacing scan skipped (sequential origin: the scan would consume the non-replayable prefix)"
                } else {
                    switch spacing {
                    case .measured(let s): spacingText = "measured IRAP spacing \(String(format: "%.3f", s))s"
                    case .exceedsBudget(let s): spacingText = "IRAP spacing exceeds the \(String(format: "%.0f", s))s scan budget"
                    case .singleKeyframeInSource: spacingText = "source holds one IRAP, no second to space against"
                    case .unknown: spacingText = "IRAP spacing unknown (no keyframe scanned)"
                    }
                }
                EngineLog.emit(
                    "[HLSVideoEngine] segment plan: uniform stride fallback (\(reason), anchorPts=\(anchorPts), "
                    + "\(spacingText) → stride=\(String(format: "%.3f", stride))s, \(plan.count) segments)",
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
        let doviConfig = route.doviConfig
        let convertP7ToProfile81 = route.convertP7ToProfile81
        let dvVariant = route.dvVariant

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))

        // #130: same avg -> r_frame_rate chain the host probe uses. A live MPEG-TS probe often
        // leaves avg_frame_rate unset while the parser still fills r_frame_rate; the master's
        // FRAME-RATE attribute is load-bearing for PQ/HLG variants (AVPlayer filters a
        // VIDEO-RANGE=PQ/HLG EXT-X-STREAM-INF without FRAME-RATE and fails -1002).
        let frameRate: Double? = AetherEngine.detectFrameRate(stream: videoStream)
        // HDCP-LEVEL omitted: local loopback has no DRM scope, and emitting TYPE-1 caused
        // AVFoundationErrorDomain -11868 / tracks count=0 when the HDMI link's HDCP 2.2
        // negotiation state didn't match (Vincent test 2026-05-26, HDR10 panel).
        let hdcpLevel: String? = nil

        // 5. Normalize the HEVC config record shipped in init.mp4:
        //    a) numOfArrays=0 (DV P5 MP4 encoders shipping VPS/SPS/PPS per-IRAP, #19 Wandering Earth 2):
        //       rebuild the hvcC from in-band parameter sets, else the dvh1 sample entry fails CME -4.
        //    b) numOfArrays>0 but carrying non-parameter-set arrays (libx265's user-data SEI_PREFIX, AE#187):
        //       strip everything but VPS/SPS/PPS. Apple TV hardware rejects an hvcC with an SEI array
        //       (tracks count=0 / -12848); macOS + the tvOS Simulator tolerate it, so it is device-only.
        //    c) Annex-B extradata (#365): a Matroska remux whose CodecPrivate is Annex B, or one with
        //       none at all where libavformat synthesised it from in-band parameter sets. The mp4
        //       muxer reads that as "the bitstream is Annex B too" and rewrites every sample; when the
        //       packets are in fact length-prefixed it empties them. Measured on packets, then the
        //       record is converted so the muxer's own test comes out right.
        let framingNormalization = normalizeVideoFraming(
            demuxer: dem,
            videoStreamIndex: videoIndex,
            codecpar: codecpar,
            isLive: isLiveSession
        )
        let measuredVideoNALFraming = framingNormalization.measuredFraming

        let hevcExtradataOverride: [UInt8]?
        if let normalized = framingNormalization.extradataOverride {
            hevcExtradataOverride = normalized
        } else if let rebuilt = rebuildHEVCExtradataWithInBandParameterSets(
            demuxer: dem,
            videoStreamIndex: videoIndex,
            codecpar: codecpar,
            rewindBeforeScan: !isLiveSession
        ) {
            hevcExtradataOverride = rebuilt
            EngineLog.emit(
                "[HLSVideoEngine] rebuilt hvcC with in-band parameter sets: "
                + "\(codecpar.pointee.extradata_size) B → \(rebuilt.count) B",
                category: .session
            )
        } else if codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
                  let ed = codecpar.pointee.extradata,
                  case let source = Array(UnsafeBufferPointer(start: ed, count: Int(codecpar.pointee.extradata_size))),
                  let canonical = Self.canonicalizeHEVCConfigRecord(source) {
            hevcExtradataOverride = canonical
            EngineLog.emit(
                "[HLSVideoEngine] canonicalized hvcC (stripped non-parameter-set NAL arrays): "
                + "\(source.count) B → \(canonical.count) B (AE#187)",
                category: .session
            )
        } else {
            hevcExtradataOverride = nil
        }

        // 6. Reset demuxer cursor to 0 (cue prewarm moved it mid-file). Skipped for live
        //    (no prewarm, forward-only feed), and for a forward-only VOD source: the prewarm did not
        //    run there, so the cursor never left the head, and a seek on a pb that cannot rewind
        //    drops the probe's buffered packets and leaves matroskadec resyncing from wherever the
        //    stream has got to (a remote MKV lost its first second, on the software path 30 s).
        if !isLiveSession {
            if dem.isSourceSeekable { dem.seek(to: 0) }
            dem.endIndexPass()      // AE#585: the next read that lands outside a span is playback's
        }

        // volumeAvailableCapacityForImportantUsage is unavailable on tvOS; the plain capacity key
        // exists on every platform and is close enough for the quarter-of-free-space clamp.
        // [MovieClaw P25] 经统一入口读（测试可覆盖；tvOS 没有「重要用途可用」，入口里按普通可用读）
        let availableBytes = AetherEngine.temporaryVolumeAvailableBytes(importantUsage: true)
        let capRelaxed = Self.retentionCapRelaxed(forwardWindowSegments: forwardWindowSegments)
        // #687: sized from what the other running sessions leave, not from the raw free space.
        let claim = RetentionClaims.shared.claim(volumeAvailableBytes: availableBytes) {
            Self.sessionRetentionBudgetBytes(volumeAvailableBytes: $0, capRelaxed: capRelaxed)
        }
        let retentionBudget = claim.bytes
        self.retentionBudgetBytes = retentionBudget
        let segmentCache = SegmentCache(
            forwardWindow: forwardWindowSegments,
            backwardWindow: backwardWindowSegments,   // [MovieClaw P25]
            retentionBudgetBytes: retentionBudget,
            onResidentSetChanged: { [weak self] in self?.noteResidentSetChanged() }
        )
        claim.track { [weak segmentCache] in segmentCache?.totalBytes ?? 0 }
        self.retentionClaim = claim
        self.cache = segmentCache
        EngineLog.emit(
            "[HLSVideoEngine] segment retention budget: \(retentionBudget / (1 << 20)) MiB "
            + "(volumeAvailable=\(availableBytes.map { "\($0 / (1 << 20)) MiB" } ?? "unknown"), "
            + "forwardWindow=\(forwardWindowSegments) seg, backwardWindow=\(backwardWindowSegments) seg"
            + (capRelaxed ? ", opt-in prefetch: default cap relaxed" : "")
            + (claim.heldBackBytes > 0
                ? ", \(claim.heldBackBytes / (1 << 20)) MiB held back for other sessions" : "") + ")",
            category: .session
        )

        // DV P5 MP4 encoders can omit the HEVC SPS VUI and `colr` atom (#19 Wandering Earth 2 WEB-DL):
        // color_trc/primaries/space all unspecified, so AVPlayer's DV decoder won't engage on the dvh1
        // sample entry (MKV reads Colour element directly into codecpar; MP4 demuxer has no fallback).
        // Forcing the canonical IPT-PQ-c2 tuple writes `colr nclx` so AVPlayer sees the PQ signal.
        // Primaries/transfer/matrix are spec-fixed for P5, so this is a repair. Range is preserved if
        // already signaled (full-range P5 is legal, #20); unspecified defaults to limited.
        // The AE#455 P8.1-as-P5 route needs the same guarantee for the same reason, and lands on the
        // same tuple: an HDR10 base layer is BT.2020 / PQ / BT.2020-NCL by definition.
        // Keyed on the sample entry the route chose, not on the variant: a Profile 5 record served as
        // its base layer (`dolbyVisionHandling = .baseLayerOnly`) is plain hvc1 whose VUI the muxer
        // stream-copies as it stands.
        // A record the engine synthesized from the RPU (AE#recordless) needs the repair most of all:
        // its gate IS an unspecified VUI, which is the signal shape #19 was reported on, and a source
        // is the same bytes whether the container recorded its profile or not. Measured on one
        // bitstream in two containers, Dolby's P5 asset with and without its `dvcC`: with the record
        // `init.mp4` is 883 B carrying `colr nclx` 9 / 16 / 9 full range, without it and without this
        // override 864 B and no `colr` at all, which would be two deliveries of one picture.
        let colorOverride: MP4SegmentMuxer.ColorOverride?
        if codecTagOverride == "dvh1" {
            let sourceRange = codecpar.pointee.color_range
            colorOverride = MP4SegmentMuxer.ColorOverride(
                primaries: AVCOL_PRI_BT2020,
                trc: AVCOL_TRC_SMPTE2084,
                space: AVCOL_SPC_BT2020_NCL,
                range: sourceRange == AVCOL_RANGE_UNSPECIFIED
                    ? AVCOL_RANGE_MPEG
                    : sourceRange
            )
        } else if videoRange == .sdr, ColorAttachments.presentsSDRAsSRGB,
                  let declared = Self.bt709CurveColor(codecpar) {
            // [MovieClaw P60] SDR shown as sRGB, see `ColorAttachments.presentsSDRAsSRGB`. AVPlayer reads
            // `colr nclx` over the SPS VUI (measured: VUI 1/1/1 + colr 1/13/1 comes out IEC_sRGB), so this
            // retags a BT.709-tagged source as well as an untagged one. Gaps filled as VideoToolbox does.
            let filled = ColorAttachments.filled(declared)
            let sourceRange = codecpar.pointee.color_range
            colorOverride = MP4SegmentMuxer.ColorOverride(
                primaries: filled.primaries,
                trc: AVCOL_TRC_IEC61966_2_1,
                space: filled.matrix,
                range: sourceRange == AVCOL_RANGE_UNSPECIFIED ? AVCOL_RANGE_MPEG : sourceRange
            )
        } else {
            colorOverride = nil
        }
        // Deep-copy codecpar so configs outlive the demuxer (live reopen closes it; see OwnedCodecParameters).
        guard let ownedVideoParams = OwnedCodecParameters(copying: codecpar) else {
            throw HLSVideoEngineError.openFailed(reason: "codecpar copy failed")
        }
        ownedCodecParams.append(ownedVideoParams)
        // movenc writes `pasp` from the output codecpar alone, and a container-declared ratio never
        // reaches codecpar: Matroska's DisplayWidth quotient and MP4's own `pasp` land on AVStream
        // (matroskadec.c / mov.c), which is where a DVD remuxed to MKV carries its anamorphic ratio.
        // Without this the loopback item presented such a source at its coded shape, 720x576 for a
        // 1024x576 picture, and every consumer downstream of AVPlayer inherited the wrong rectangle.
        // Resolved through the same policy the two decoders run, so a ratio the software path
        // disbelieves (#290) is not one the native path stretches to.
        let declaredSAR = PixelAspectPolicy.declaredPixelAspect(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: videoStream.pointee.sample_aspect_ratio,
            width: codecpar.pointee.width,
            height: codecpar.pointee.height
        )
        ownedVideoParams.ptr.pointee.sample_aspect_ratio = declaredSAR ?? AVRational(num: 0, den: 1)
        if let declaredSAR {
            EngineLog.emit(
                "[HLSVideoEngine] SAR \(declaredSAR.num):\(declaredSAR.den) on "
                + "\(codecpar.pointee.width)x\(codecpar.pointee.height) into the fMP4 sample entry "
                + "(bitstream=\(codecpar.pointee.sample_aspect_ratio.num):"
                + "\(codecpar.pointee.sample_aspect_ratio.den) "
                + "container=\(videoStream.pointee.sample_aspect_ratio.num):"
                + "\(videoStream.pointee.sample_aspect_ratio.den))",
                category: .session
            )
        }
        // Audit BIT-104: one framing verdict for the session, seeded only by a measurement (#365).
        // The extradata-derived framing is a claim, not a measurement.
        var framingMeasuredLengthPrefixed = false
        if case .lengthPrefixed? = measuredVideoNALFraming { framingMeasuredLengthPrefixed = true }
        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: UnsafePointer(ownedVideoParams.ptr),
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride,
            doviConfig: doviConfig,
            convertP7ToProfile81: convertP7ToProfile81,
            colorOverride: colorOverride,
            extradataOverride: hevcExtradataOverride,
            nalFramingOverride: measuredVideoNALFraming,
            annexBSamplesKeepParameterSets: framingNormalization.annexBSamplesKeepParameterSets,
            nalFramingLatch: NALFramingLatch(confirmed: framingMeasuredLengthPrefixed)
        )
        self.videoStreamIndex = videoIndex
        self.savedVideoConfig = videoConfig
        // Fold degenerate sub-frame segments (keyframe clusters make buildKeyframeSegmentPlan emit
        // ~40 ms segments the producer cannot cut, wedging the near-EOF resume; the plan and producer
        // share these boundaries, so the merge fixes both at once).
        plan = Self.collapseShortSegments(plan, minDurationSeconds: Self.minSegmentDurationSeconds)
        self.segmentPlan = plan

        // #93 residual: anchor the FIRST producer at the session's start position instead of seg0.
        // A resume start otherwise produces seg0 (torn down and discarded seconds later when
        // AVPlayer's initial seek fetches the resume segment), restarts, and the fetch/restart race
        // can 404 the item into a host reload (device: double spinner). The baseIndex > 0 anchor is
        // the battle-tested restart path (gate at plan[base].startPts, tfdt continuity per 4.9.1).
        if !isLiveSession, let startSeconds = initialStartSeconds, startSeconds > 0 {
            // A sequential origin cannot honour a resume anchor: the first producer would read
            // from byte 0 (the only addressable offset) while labelling those bytes segment
            // idx > 0, and the append playlist - which requires reports contiguous from 0 -
            // would drop every one of them and serve an empty asset. Produce from 0 and say so;
            // seeking into an archive means re-requesting it with a shifted start timestamp.
            if sequentialOriginPinsProducerToZero {
                EngineLog.emit(
                    "[HLSVideoEngine] sequential origin ignores startPosition="
                    + "\(String(format: "%.2f", startSeconds))s: only byte 0 is addressable, "
                    + "producing from the beginning",
                    category: .session
                )
            } else {
                initialProducerBaseIndex = segmentIndexForPlaylistTime(startSeconds)
                EngineLog.emit(
                    "[HLSVideoEngine] initial producer anchored at idx=\(initialProducerBaseIndex) "
                    + "(startPosition=\(String(format: "%.2f", startSeconds))s)",
                    category: .session
                )
            }
        }

        // Fallback duration from avg_frame_rate for MKVs that drop TrackEntry DefaultDuration
        // (HandBrake/web-rip pipelines). Without it, trun.last.duration=0 and AVPlayer parks on
        // WaitingToMinimizeStallsReason. 25 fps / 1 ms TB = 40 ticks; 23.976 fps = 41 ticks.
        let videoFallbackDuration: Int64 = {
            let avgFR = videoStream.pointee.avg_frame_rate
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
        // AE#458: resolved once here so the stream-copy config and the bridge cascade below label the
        // track identically; both end up in the same fMP4 mdhd.
        let audioLanguage = AudioLanguageMap.iso639_2T(
            forSourceLanguage: audioStreamIndex >= 0
                ? audioDem.audioTrackInfos().first(where: { $0.id == Int(audioStreamIndex) })?.language
                : nil
        )

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
                        : "[HLSVideoEngine] audio: codec=\(compat) (bridge required), decoding + "
                          + Self.encoderLabel(AudioBridge.bridgeEncoder(
                                for: audioBridgeMode,
                                sourceChannels: acpForHE.ch_layout.nb_channels)).uppercased()
                          + " re-encode",
                    category: .session
                )
            } else if compat != .unsupported {
                // ADTS-AAC from MPEG-TS has no ASC in extradata, so mp4a/esds can't be built
                // (EINVAL/"Could not find tag for codec aac"). Synthesize ASC + clear TS codec_tag;
                // pump strips per-frame ADTS headers.
                let stripAdts = Self.prepareAACForFMP4(audioStream.pointee.codecpar)
                if stripAdts {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio: AAC/ADTS from TS, synthesised ASC + stripping ADTS for fMP4 stream-copy (no FLAC bridge)",
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
                    stripAacAdts: stripAdts,
                    language: audioLanguage
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
                audioIsAtmosStreamCopy = isJOC
                audioHLSCodecs = compat.hlsCodecsString
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) → stream-copy as `\(audioHLSCodecs ?? "?")` "
                    + "\(isJOC ? "[JOC=Atmos] " : "")"
                    + "(fallback duration=\(audioFallbackDurationPts) in audioTb \(audioTb.num)/\(audioTb.den))",
                    category: .session
                )
            } else {
                // Not video-only, and the line used to say so. The bridge cascade below asks for a
                // decoder by id, not for a routing-table entry, so a codec the table does not name
                // still gets sound as long as the FFmpeg build carries its decoder (measured
                // 2026-09-10 on Nellymoser-in-FLV before its table entry existed: this line, then a
                // NELLYMOSER -> FLAC bridge and a session with audio). What the missing entry costs
                // is the stream-copy decision, which is why the next thing that happens is a bridge.
                // The genuinely silent case is one line further down: no decoder in the build at
                // all, which the cascade reports as `falling back to SILENT video-only`.
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec id=\(codecID.rawValue) is not in the routing table, "
                    + "no stream-copy decision to make; the bridge cascade decides whether it plays",
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
            sourceCarriesAudio: audioDem.firstAudioStreamIndexByType >= 0,
            audioHLSCodecs: &audioHLSCodecs,
            audioLanguage: audioLanguage
        )
        self.producer = prod
        self.activeAudioSourceStreamIndex = savedAudioConfig != nil ? audioStreamIndex : -1
        // AE#458: only when the audio actually reached the variant. A cascade that fell through to
        // video-only must not advertise an audio rendition that is not in the segments, and must not
        // force the master for one either.
        let servedAudioLanguage = savedAudioConfig != nil ? audioLanguage : nil

        // 7. Wire provider, server, and URL.
        let manifestCodecs = audioHLSCodecs.map { "\(primaryCodecs),\($0)" } ?? primaryCodecs
        // AE#418: a segment AVPlayer places is what moves the axis it reads.
        var segmentPlacedHandler: (@Sendable (Int) -> Void)?
        var segmentServedHandler: (@Sendable (Int, Bool) -> Void)?
        if !isLiveSession {
            segmentPlacedHandler = { [weak self] idx in
                guard let self else { return }
                self.handleSegmentPlaced(at: idx)
            }
            // AE#418 round 7: a placement is a request that was ANSWERED, and an empty buffer says
            // nothing while the answer is outstanding.
            segmentServedHandler = { [weak self] idx, delivered in
                self?.recordSegmentDelivery(index: idx, delivered: delivered)
            }
        }
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
            audioLanguage: servedAudioLanguage,
            isLive: isLiveSession,
            // Sequential archives: playlist grows with the producer's REAL cut durations. The
            // static plan's uniform EXTINF lies whenever the archive's GOP cadence does not
            // divide the cut target (1.92 s GOPs vs a 4.0 s plan put every segment's media up
            // to 1.9 s outside its advertised window; AVPlayer visibly jumped at each resync).
            sequentialAppendPlaylist: sequentialOrigin && !isLiveSession,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: liveCutTargetSeconds,
                dvrWindowSeconds: dvrWindowSeconds,
                // AE#443: the window is a promise in seconds and the disk is a fact in bytes. Handing
                // the sizing the budget is what lets the two meet, instead of the producer meeting a
                // resident cap it can never pass.
                retentionBudgetBytes: retentionBudgetBytes
            ),
            allowsBoundedDegradedStart: liveJoinProfile == .fastZap,
            boundedStartFloorsAtHoldback: LiveEdgePolicy.boundedStartFloorArmed,
            firstServeLatchCoversEngineCut: LiveEdgePolicy.firstServeLatchAllArmed,
            blockingReloadOverride: blockingReloadOverride,
            liveCadencePolicy: liveCadencePolicy,
            restartHandler: isLiveSession ? nil : { [weak self] idx in
                self?.requestRestart(at: idx)
            },
            // #358: a plan index no keyframe can open, asked for twice. Nothing downstream recovers
            // from it, so the session ends with an error the host can act on instead of a picture
            // that never moves again while the engine still reports playing.
            unrecoverableGapHandler: isLiveSession ? nil : { [weak self] _ in
                self?.surfaceVODSourceFailure(FFmpegErr.eio, "Source segment could not be produced")
            },
            restartActivity: isLiveSession ? nil : { [weak self] in
                self?.restartInFlight ?? false
            },
            activeProducerBase: isLiveSession ? nil : { [weak self] in
                self?.currentProducerBaseIndex
            },
            // AE#169 round 2: a finished pump can never march; the forward-window wait must
            // escalate to restart instead of parking on its frozen front.
            producerFinished: isLiveSession ? nil : { [weak self] in
                self?.currentProducerFinished ?? false
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
            currentShiftSeconds: { [weak self] in (self?.playlistShiftSeconds ?? 0) + (self?.subtitleStreamStartSeconds ?? 0) },
            segmentPlacedHandler: segmentPlacedHandler,
            segmentServedHandler: segmentServedHandler
        )
        self.provider = prov
        // AE#520 round 2: the close reads it on the playlist-build thread, so it is a closure over a
        // mirror rather than a read of the item.
        prov.consumerBufferedSecondsProvider = consumerBufferedSecondsProvider
        wireProviderCallbacks(prod, to: prov)

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

        // 8. Kick the pump. Seek on the video stream's exact plan timestamp and forbid an earlier
        // landing. A global time seek can choose the previous sync point in a multi-stream MP4,
        // leaving the producer to scan a whole GOP over the origin before writing anything (#191).
        if initialProducerBaseIndex > 0, initialProducerBaseIndex < plan.count {
            let targetPts = plan[initialProducerBaseIndex].startPts
            // Disc plans use folded multi-clip timestamps that are not valid raw seek targets.
            if dem.isDiscSource || !dem.seek(to: targetPts, streamIndex: videoStreamIndex) {
                let tb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
                dem.seek(to: Double(targetPts) * Double(tb.num) / Double(tb.den))
            }
        }
        // #416: the pump harvests every subtitle packet it demuxes, so where it OPENS is where its
        // coverage of the source begins. The subtitle drain reads "nothing between this set and the
        // playhead" out of the same store, and below this position that answer means nothing.
        if !plan.isEmpty {
            let openIndex = max(0, min(initialProducerBaseIndex, plan.count - 1))
            let tb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
            subtitlePacketStore.noteHarvestAnchor(
                .pump, at: Double(plan[openIndex].startPts) * Double(tb.num) / Double(tb.den))
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
        // AE#682: decided before the routing below, because an I-frame rendition is one of the
        // reasons to serve a master at all.
        let iFrameCandidate = IFrameRenditionEligibility.candidate(.init(
            requested: iFramePlaylistRequested,
            isLive: isLiveSession,
            planBoundariesClaimRandomAccess: planBoundariesClaimRandomAccess,
            sequentialOrigin: sequentialOrigin,
            heldSourceConnection: openProfile.avioHeldConnection,
            originIsSerial: sourceReopenableByURL
                && OriginRequestBudget.shared.requiresSerialRequests(sourceURL),
            isDiscSource: dem.isDiscSource,
            secondReaderAvailable: sourceReopenableByURL || customIFrameReader != nil))
        let hasNativeSubs = enableNativeSubtitleTrackForSession && !nativeSubtitleCueStoresForSession.isEmpty
        // AE#187: tvOS HW HEVC needs the codec advertised in a master's CODECS attribute; a bare media
        // playlist (H.264 is fine media-direct) fails the item with tracks count=0 / -12848. Scope to
        // tvOS: iOS/macOS build the HEVC track from the init hvcC media-direct and are left unperturbed.
        #if os(tvOS)
        let videoCodecNeedsMasterSignaling = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        #else
        let videoCodecNeedsMasterSignaling = false
        #endif
        let useMasterPlaylist = AetherEngine.forceMasterPlaylistForTesting
            || Self.resolveUseMasterPlaylist(
            videoRange: videoRange, effectiveDvMode: effectiveDvMode,
            panelIsInHDRMode: panelIsInHDRMode, displaySupportsHDR: displaySupportsHDR,
            hasNativeSubs: hasNativeSubs,
            builtInPanelEngagesOnDemand: Self.builtInPanelEngagesOnDemand,
            frameRateKnown: frameRate != nil,
            videoCodecNeedsMasterSignaling: videoCodecNeedsMasterSignaling,
            hasAudioRendition: servedAudioLanguage != nil,
            hasIFrameRendition: iFrameCandidate == .served)
        let resolvedURL: URL? = useMasterPlaylist
            ? srv.playlistURL
            : srv.mediaPlaylistURL
        guard let url = resolvedURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        self.servingMasterPlaylist = useMasterPlaylist
        iFrameRenditionVerdict = IFrameRenditionEligibility.resolve(
            candidate: iFrameCandidate, servingMaster: useMasterPlaylist)
        if iFrameRenditionVerdict == .served, let rendition = makeIFrameRendition(plan: plan, cache: segmentCache) {
            iFrameRendition = rendition
            prov.setIFrameSource(rendition)
            EngineLog.emit("[HLSVideoEngine] i-frame rendition: served segments=\(plan.count)",
                           category: .session)
        } else if iFramePlaylistRequested {
            closeUnusedCustomIFrameReader()
            if iFrameRenditionVerdict == .served { iFrameRenditionVerdict = .absent(.noSecondReader) }
            if case .absent(let reason) = iFrameRenditionVerdict {
                EngineLog.emit("[HLSVideoEngine] i-frame rendition: absent reason=\(reason.rawValue)",
                               category: .session)
            }
        }
        self.servedSourceIsHDR = videoRange != .sdr
        self.servedDolbyVisionConversion = convertP7ToProfile81 ? .profile7ToProfile81 : nil
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable) effectiveDvMode=\(effectiveDvMode) panelIsHDR=\(panelIsInHDRMode) displaySupportsHDR=\(displaySupportsHDR) matchContent=\(matchContentEnabled) sourceIsHDR=\(videoRange != .sdr || effectiveDvMode) useMaster=\(useMasterPlaylist) videoRange=\(videoRange) dvVariant=\(dvVariant) audioLang=\(servedAudioLanguage ?? "none"))")
        return url
    }

    /// Built-in panels that engage EDR on demand once HDR content renders; the tvOS SDR-parked-
    /// panel failure mode (-11848) exists only behind the HDMI mode switch, so HDR-eligibility is
    /// the readiness signal on these platforms (Sodalite AE#88 retest: every HDR/DV film on iPhone
    /// routed media-direct and PiP subtitles silently never worked for them). macOS composites EDR
    /// per-window with no display mode switch, same physics as the iOS built-in panel; an SDR-only
    /// Mac reads ineligible and stays media-direct (#98).
    static let builtInPanelEngagesOnDemand: Bool = {
        #if os(iOS) || os(macOS)
        return true
        #else
        return false
        #endif
    }()

    /// Pure master-vs-media playlist routing decision (#4, #15, #63, #98). A master claiming HDR
    /// while the panel sits in SDR fails with -11848, so HDR/DV sources need a ready panel. SDR
    /// content is routable on any panel, so native subtitles force the master there.
    /// `builtInPanelEngagesOnDemand` (iOS/macOS) treats HDR-eligibility
    /// (`AVPlayer.eligibleForHDRPlayback`, passed as `displaySupportsHDR`) as panel readiness: the
    /// built-in panel engages EDR when HDR content renders, and an SDR-only device or route still
    /// reads ineligible and stays media-direct.
    ///
    /// P5 has no routing special-case. The single-variant `dvh1.05` master (no backward-compat
    /// brand) is accepted on a non-DV HDR10 panel and tonemapped by the system DV decoder (tvOS 26.5
    /// device test 2026-07-05, iOS 26.5 DrHurt #98). The removed always-media-direct P5 guard was
    /// compensating for an earlier engine deficiency that emitted a P5 master AVPlayer rejected with
    /// -11868 (2026-05-26); the engine now emits a well-formed one, so P5 follows the standard HDR
    /// gate: master on a ready HDR panel, media-direct on an SDR route (also the graceful path for
    /// DrHurt's external SDR monitor, #98). Do not reinstate an OS-version gate: the fault was the
    /// engine's own master, not a stricter platform codec filter.
    ///
    /// AE#458: `hasAudioRendition` is the same shape of reason as `hasNativeSubs`. An
    /// `EXT-X-MEDIA:TYPE=AUDIO` tag lives only in a master, and it is the only place AVFoundation reads
    /// an audio language from on an HLS asset, so a media-direct SDR source reports
    /// `languageCode == nil` and AVKit's audio menu reads "Not Specified" no matter what the segment's
    /// mdhd says. 6.60.0 wrote the rendition but did not route to it, so the label landed only where
    /// HDR or AE#187 had already forced the master; SDR H.264 (and SDR HEVC off tvOS) kept the old
    /// symptom (htrung14, tvOS transport bar, Apple TV 4K 3rd gen). Routing-safety still decides: an
    /// unready HDR panel is a -11848 rejection, and a language is not worth one.
    ///
    /// AE#682: `hasIFrameRendition` is a third reason of the same shape. `EXT-X-I-FRAME-STREAM-INF`
    /// lives only in a master, and it is likewise not worth a display rejection.
    ///
    /// #130: `frameRateKnown` gates PQ/HLG masters. AVPlayer filters a VIDEO-RANGE=PQ/HLG
    /// EXT-X-STREAM-INF that has no FRAME-RATE attribute out of the master at parse time and fails
    /// the item with NSURLErrorDomain -1002 without ever fetching media.m3u8 (byte-exact local
    /// repro; SDR variants are accepted without FRAME-RATE). Live MPEG-TS probes can leave the
    /// frame rate unknown even after the r_frame_rate fallback, so a frame-rate-less HDR source
    /// routes media-direct instead of serving a master AVPlayer provably rejects.
    static func resolveUseMasterPlaylist(
        videoRange: HLSVideoRange,
        effectiveDvMode: Bool,
        panelIsInHDRMode: Bool,
        displaySupportsHDR: Bool,
        hasNativeSubs: Bool,
        builtInPanelEngagesOnDemand: Bool,
        frameRateKnown: Bool,
        videoCodecNeedsMasterSignaling: Bool = false,
        hasAudioRendition: Bool = false,
        hasIFrameRendition: Bool = false
    ) -> Bool {
        let sourceIsHDR = videoRange != .sdr || effectiveDvMode
        let panelReadyForHDR = panelIsInHDRMode
            || (builtInPanelEngagesOnDemand && displaySupportsHDR)
        // #130: a PQ/HLG master without FRAME-RATE is unloadable regardless of panel state.
        let masterManifestViable = (videoRange == .sdr) || frameRateKnown
        guard masterManifestViable else { return false }
        // Gate on the ACTUAL videoRange, not sourceIsHDR: sourceIsHDR is inflated by
        // effectiveDvMode (a device DV capability) even for SDR content, which wrongly sent SDR
        // sources on DV-capable devices to media-direct, so the WebVTT rendition never appeared (#15).
        let routingSafeForMaster = (videoRange == .sdr) || panelReadyForHDR
        // AE#187: Apple TV HW builds an H.264 track from a bare media playlist + init, but HEVC needs
        // the codec advertised in a master's EXT-X-STREAM-INF CODECS. SDR HEVC otherwise routed
        // media-direct (below), leaving the device with no HEVC signaling -> tracks count=0 / -12848
        // before any media fetch (macOS / the Simulator build the track from the init hvcC and never
        // reproduce it). Forcing the master where it is routing-safe (SDR on any panel, HDR on a ready
        // one) closes that gap; the caller scopes the flag to tvOS + HEVC.
        if (hasNativeSubs || videoCodecNeedsMasterSignaling || hasAudioRendition || hasIFrameRendition)
            && routingSafeForMaster { return true }
        return sourceIsHDR && panelReadyForHDR
    }

    /// `true` when `start()` chose the master playlist (HDR/DV signaling). Read after `start()`.
    public private(set) var servingMasterPlaylist: Bool = false

    /// `true` when the served variant advertises HDR (`VIDEO-RANGE` other than SDR), i.e. the master an
    /// external receiver rejects (#227). Read after `start()`.
    ///
    /// Deliberately NOT `sourceIsHDR` (`videoRange != .sdr || effectiveDvMode`): `effectiveDvMode` is a
    /// DEVICE capability, so that expression reads true for SDR content on any DV-capable iPhone or iPad and
    /// sent every such source down the HDR branch (device log 2026-07-27: `sourceIsHDR=true videoRange=sdr
    /// dvVariant=none`), which made the 5.23.8 AirPlay fix a no-op on exactly the devices it was written for.
    /// `resolveUseMasterPlaylist` carries the same warning for the same reason (#15).
    /// Internal on purpose: it feeds the engine's own AirPlay routing, and hosts read the consequence
    /// (`AetherEngine.nativeSubtitleRenditionsServed`) rather than the input.
    private(set) var servedSourceIsHDR: Bool = false

    /// The Dolby Vision rewrite the producer applies to every served video packet, nil when it serves the
    /// source's own profile. Read after `start()`; published as `AetherEngine.dolbyVisionConversion`.
    private(set) var servedDolbyVisionConversion: DolbyVisionConversion?

    /// The loopback server's media (single-variant) playlist URL, for the reactive master->media
    /// fallback (#98). Nil before the server starts.
    public var mediaPlaylistURL: URL? { server?.mediaPlaylistURL }

    /// The loopback server's master playlist URL, for the #35 cold-DV-master readiness gate that
    /// reloads the same master with a fresh asset while the DV/HDCP link warms. Nil before start.
    public var masterPlaylistURL: URL? { server?.playlistURL }

    /// HDR-preserving reduced master URL (#98), subtitle-preserving fallback for the #35 cold-DV gate.
    public var reducedHDRMasterPlaylistURL: URL? { server?.reducedHDRMasterPlaylistURL }

    /// True once the loopback server has handed out an init or media segment this session (#227). The
    /// AirPlay watchdog reads it: a receiver that refuses the manifest asks for playlists and never for a
    /// segment, which separates a refusal from a clock that is merely paused.
    public var hasServedMediaSegment: Bool { server?.hasServedMediaSegment ?? false }

    /// Flip the serving flag after the engine has reloaded the media playlist on a display rejection.
    func markServingMediaAfterFallback() {
        servingMasterPlaylist = false
        // AE#682: the rendition lives only in the master this session just stopped serving.
        tearDownIFrameRendition()
    }

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
        /// Cumulative bytes emitted by the MP4SegmentMuxer; muxer-leak attribution baseline. Spans muxer
        /// rotations and producer replacements (AE#443), or a session with a recovery in it would read
        /// as a drop to near zero exactly where the leak question is interesting.
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
        /// Producer restarts in the session (0 for non-restart sessions), across every producer the
        /// session has had. Live sessions read 0 by construction: they replace the producer instead.
        public let producerRestartCount: Int
        /// Most recent audio-gate vs video-gate gap in source-clock ms; 0 until first audio gate.
        public let lastAVGapMs: Double
        /// Lifetime HTTP requests served (playlist + init + segment fetches).
        public let serverRequestCount: Int
    }

    // MARK: - Session-lifetime counters

    /// Totals folded off the subsystems a recovery REPLACES.
    ///
    /// AE#443: every counter below used to be read straight off the live instance, so a live reopen
    /// (fresh demuxer, fresh producer) restarted all of them from zero at exactly the moment a session
    /// became worth measuring, and a telemetry line carried no sign that it had. The scope of a
    /// session-lifetime number is the SESSION, which is this object; it cannot live on the parts the
    /// session rebuilds under itself.
    ///
    /// Folded once a swap is FINAL (the live reopen puts its old demuxer back when the producer build
    /// fails, and folding at the swap would then count one reader twice) and always after the successor
    /// is installed, so the ordering can undercount for the microseconds in between but never double
    /// count. The producer fold also stays off `restartLock`: its byte total is read through the
    /// producer's own `stateLock`, while the demuxer's counter is a leaf.
    private let retiredCounterLock = NSLock()
    private var retiredDemuxerBytes: Int64 = 0
    private var retiredMuxedBytes: Int = 0
    private var retiredProducerRestarts: Int = 0

    /// Fold a replaced producer's totals into the session's. Call once per outgoing instance, before
    /// stopping it (`stop()` releases the muxer its byte total is read from).
    func retireProducer(_ old: HLSSegmentProducer?) {
        guard let old else { return }
        let bytes = old.muxerLifetimeFragmentBytes
        let restarts = old.restartCount
        retiredCounterLock.lock()
        retiredMuxedBytes &+= bytes
        retiredProducerRestarts &+= restarts
        retiredCounterLock.unlock()
    }

    /// Fold a replaced demuxer's fetched bytes into the session's. Call before closing it.
    func retireDemuxer(_ old: Demuxer?) {
        guard let old else { return }
        let bytes = old.avioBytesFetched
        retiredCounterLock.lock()
        retiredDemuxerBytes &+= bytes
        retiredCounterLock.unlock()
    }

    private func retiredTotals() -> (demuxerBytes: Int64, muxedBytes: Int, producerRestarts: Int) {
        retiredCounterLock.lock()
        defer { retiredCounterLock.unlock() }
        return (retiredDemuxerBytes, retiredMuxedBytes, retiredProducerRestarts)
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

    /// AE#514: bytes of the played streams by presentation time, fed by every producer of the session
    /// (initial, seek restart, live reopen, revive), read by the telemetry sampler at the playhead.
    let playedMediaLedger = PlayedMediaLedger()

    /// Bytes this session pulled from the SOURCE, across every demuxer it has had (see
    /// `retiredDemuxerBytes`). Not the same link as `LiveTelemetry.networkTransferredBytes`, which on
    /// the native path counts what AVPlayer pulled from the loopback server.
    var demuxerBytesFetched: Int64 {
        (subsystemSnapshot().demuxer?.avioBytesFetched ?? 0) + retiredTotals().demuxerBytes
    }
    var segmentCacheTotalBytes: Int { subsystemSnapshot().cache?.totalBytes ?? 0 }
    /// On-disk segment bytes (freshly stat-ed). Used by `aetherctl live --report-cache-bytes`.
    var segmentCacheDiskBytes: Int64 { subsystemSnapshot().cache?.diskBytes() ?? 0 }

    /// Spans currently backed by the VOD segment cache, on the **playlist axis** the plan is cut on,
    /// which is the axis `segmentIndexForPlaylistTime` reads and NOT the 0-based display axis the
    /// engine publishes. `AetherEngine` folds them onto that axis the same way it folds a scrub
    /// target (#38); naming the axis here is what keeps the fold from being forgotten. Live returns
    /// no claim: its DVR history is a different contract, expressed by `seekableLiveRange` at the
    /// engine layer.
    ///
    /// The cache read stays OUTSIDE `restartLock` like every other forwarder above: the plan is a
    /// COW array, so snapshotting it is a retain, and nesting the cache's condition under the
    /// restart lock would add a lock order this file does not otherwise have.
    func residentPlaylistRanges() -> [ClosedRange<Double>] {
        restartLock.lock()
        let live = isLiveSession
        let cacheRef = cache
        let plan = segmentPlan
        restartLock.unlock()
        guard !live, let cacheRef, !plan.isEmpty else { return [] }
        return cacheRef.residentIndexRanges().compactMap { indexes in
            guard indexes.lowerBound >= 0, indexes.upperBound < plan.count else { return nil }
            let lower = plan[indexes.lowerBound].startSeconds
            let upperIndex = indexes.upperBound + 1
            let upper = upperIndex < plan.count
                ? plan[upperIndex].startSeconds
                : plan[indexes.upperBound].startSeconds + plan[indexes.upperBound].durationSeconds
            return lower...upper
        }
    }

    /// Seconds of contiguous *safe* content ahead of the playhead on the media-playlist axis: what the
    /// consumer already holds, plus what sits contiguously above it in the disk SegmentCache (which is
    /// what the Network Buffer setting controls). Returns 0 when nothing is cached ahead or the plan is
    /// empty.
    ///
    /// The frontier walk is anchored at `max(playhead, consumer fetch target)`, see
    /// `SegmentCache.contiguousForwardFrontier(fromPlayhead:)`: the cache retains from
    /// `fetchTarget - backwardWindow` upward, so under an opt-in whole-source prefetch the playhead's own
    /// segment is evicted and a playhead-anchored walk collapsed to 0 while the whole band was resident
    /// (#207 follow-up). A frontier below the playhead still reports 0, which keeps the #54 contract that
    /// the frontier never trails the rendered frame.
    ///
    /// The target anchor holds only inside the consumer's current fetch sequence; a seek ends it, since
    /// `declareTarget` lands at the destination while `currentTime()` still reports the position the seek
    /// left, and the target would otherwise measure the band at the destination against that stale
    /// playhead. What remains is bounded rather than seek-sized: a scrub shorter than the backward window
    /// stays inside the sequence, so a tick or two around it can still anchor on the old target, and the
    /// error is at most that window.
    ///
    /// segmentIndexForPlaylistTime and the plan read each take restartLock briefly and sequentially
    /// (no nesting); a plan rebuilt between them at worst yields one transiently wrong tick, acceptable
    /// for a visual bar.
    func contiguousForwardReadAheadSeconds(playlistSeconds: Double) -> Double {
        guard let cache = subsystemSnapshot().cache else { return 0 }
        let playheadIdx = segmentIndexForPlaylistTime(playlistSeconds)
        let frontier = cache.contiguousForwardFrontier(fromPlayhead: playheadIdx)
        guard frontier >= playheadIdx else { return 0 }
        restartLock.lock()
        defer { restartLock.unlock() }
        guard frontier >= 0, frontier < segmentPlan.count else { return 0 }
        let seg = segmentPlan[frontier]
        return max(0, (seg.startSeconds + seg.durationSeconds) - playlistSeconds)
    }
    /// Producer restarts in this SESSION, across every producer it has had. A single producer restarts
    /// at most once (it is built for one aim and replaced for the next), so before AE#443 this read as
    /// a 0/1 flag on the current instance, and on live it read 0 always: the live paths replace the
    /// producer rather than restarting one, and `performRestart` bails on the empty live segment plan.
    var producerRestartCount: Int {
        (subsystemSnapshot().producer?.restartCount ?? 0) + retiredTotals().producerRestarts
    }
    /// Muxed fragment bytes for the SESSION: across muxer rotations (folded inside the producer) and
    /// across producer replacements (folded here). A leak baseline has to outlive both, or it reads as
    /// a drop to zero on the one session that had a recovery in it.
    var muxedBytesLifetime: Int {
        (subsystemSnapshot().producer?.muxerLifetimeFragmentBytes ?? 0) + retiredTotals().muxedBytes
    }
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
    var audioBridgeOutputBytesLifetime: Int64 { subsystemSnapshot().audioBridge?.outputBytesLifetime ?? 0 }
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

    /// init.mp4 + segment bytes for a scrub thumbnail (synchronous local I/O; call off-main).
    /// Live and VOD: reads already-produced SegmentCache bytes over the single playback
    /// connection, never opening a second one (#106). Returns nil if there is no provider
    /// or the file was evicted between lookup and read. `segmentIndex` enables extractor reuse.
    /// AE#441: the oldest resident, contiguously-playable position in output seconds, or nil when the
    /// session has no provider yet. The engine intersects this with the DVR window so the advertised
    /// rewind range is what the cache actually holds.
    func residentFloorOutputSeconds() -> Double? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.residentFloorOutputSeconds()
    }

    /// AE#446 round 4: the newest resident position in output seconds, the other end of the floor above.
    func residentCeilingOutputSeconds() -> Double? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.residentCeilingOutputSeconds()
    }

    /// AE#442: the sealed live TARGETDURATION, or nil before the first playlist build.
    func sealedLiveTargetDurationSeconds() -> Int? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.sealedLiveTargetDurationSeconds
    }

    /// A resident segment a scrub still can decode from. Resolving it reads nothing, so an extractor
    /// LRU hit costs no I/O; `makeReader()` maps the segment file rather than reading it into the heap
    /// (audit SEG-2). SegmentCache only ever replaces or unlinks a segment file, never rewrites it in
    /// place, so a mapping stays valid for as long as the reader holds it.
    struct ScrubThumbnailSource: Sendable {
        let segmentIndex: Int
        let initData: Data
        let segmentURL: URL

        func makeReader() -> DataIOReader? {
            guard let segment = try? Data(contentsOf: segmentURL, options: .alwaysMapped) else { return nil }
            return DataIOReader(parts: [initData, segment])
        }
    }

    func scrubThumbnailSource(atSeconds seconds: Double) -> ScrubThumbnailSource? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        guard let prov else { return nil }
        guard let seg = prov.thumbnailSegment(atSeconds: seconds),
              let initData = prov.peekInitSegment() else { return nil }
        return ScrubThumbnailSource(segmentIndex: seg.index, initData: initData, segmentURL: seg.fileURL)
    }

    public func stop() {
        cancelResidentRangesPublish()
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
        retentionClaim?.release()
        retentionClaim = nil
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
        let iFrames = iFrameRendition
        iFrameRendition = nil
        closeUnusedCustomIFrameReader()
        savedVideoConfig = nil
        savedAudioConfig = nil
        let ownedParams = ownedCodecParams
        ownedCodecParams = []
        let reopening = reopenDemuxer
        reopenDemuxer = nil
        let restartReopening = restartReopenDemuxer
        restartReopenDemuxer = nil
        // #199: factory-vended ingest reader feeding the current demuxer; session-owned, closed here.
        let reopenReader = reopenCustomReader
        reopenCustomReader = nil
        segmentPlan = []
        restartLock.unlock()
        reopening?.markClosed()
        // The restart that opened it closes it once it sees the epoch moved.
        restartReopening?.markClosed()
        // Close before waitForFinish: cancels the reader's FIFO so a pump parked in a blocking
        // custom-IO read unblocks (mirrors markClosed for URL demuxers).
        reopenReader?.close()

        p?.stop()

        // Wake LL-HLS blocking-reload waiters; without this they sleep out their full 18-30 s timeout.
        prov?.cancelWaiters()
        prov?.setIFrameSource(nil)

        // markClosed unblocks a live pump parked in the AVIO reconnect loop (exits on closed flag,
        // not the producer cancel flag). Without this, waitForFinish blocks ~3 s while reconnects
        // storm against a superseded transcode, polluting the next session.
        d?.markClosed()
        sd?.markClosed()
        preopened?.markClosed()

        // Detached cleanup: producer waitForFinish must precede demuxer/cache/server close
        // (pump accesses them during unwind). ownedParams released last (pump read them).
        Task.detached {
            iFrames?.shutdown()
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

    // MARK: - I-frame rendition (AE#682)

    private func makeIFrameRendition(plan: [Segment], cache segmentCache: SegmentCache) -> IFrameRendition? {
        guard let cfg = savedVideoConfig, !plan.isEmpty else { return nil }
        let directory = segmentCache.sessionDir.appendingPathComponent("iframes", isDirectory: true)
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            EngineLog.emit("[HLSVideoEngine] i-frame rendition: staging dir failed: \(error)",
                           category: .session)
            return nil
        }
        let builder = IFrameFragmentBuilder(
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: cfg.codecpar, timeBase: cfg.timeBase,
                codecTagOverride: cfg.codecTagOverride, doviConfig: cfg.doviConfig,
                colorOverride: cfg.colorOverride, extradataOverride: cfg.extradataOverride,
                nalFramingLatch: cfg.nalFramingLatch),
            stagingDir: staging)
        let framing = cfg.nalFramingOverride ?? A53SEIParser.nalFraming(
            codec: cfg.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC ? .hevc : .h264,
            extradata: cfg.codecpar.pointee.extradata.map { UnsafePointer($0) },
            size: Int(cfg.codecpar.pointee.extradata_size))
        let url = sourceURL, headers = sourceHTTPHeaders, custom = customIFrameReader
        // The side reader owns the clone from here; `stop()` must not close it a second time.
        customIFrameReader = nil
        let reader = IFrameSideReader(
            open: { dem in
                if let custom {
                    try dem.open(reader: custom.reader, formatHint: custom.formatHint,
                                 profile: .iFrameSideDemuxer)
                } else {
                    try dem.open(url: url, extraHeaders: headers, profile: .iFrameSideDemuxer, isLive: false)
                }
            },
            cleanup: { custom?.reader.close() },
            convertP7ToProfile81: cfg.convertP7ToProfile81,
            nalFraming: framing)
        let entries = plan.map {
            IFrameRendition.Entry(startPts: $0.startPts, startSeconds: $0.startSeconds,
                                  durationSeconds: $0.durationSeconds)
        }
        return IFrameRendition(
            entries: entries,
            cache: IFramePayloadCache(directory: directory.appendingPathComponent("payloads", isDirectory: true)),
            readPayload: { reader.payload(startPts: $0.startPts) },
            buildFragment: { payload, index, entry in
                builder.build(payload: payload, index: index,
                              startSeconds: entry.startSeconds, durationSeconds: entry.durationSeconds)
            },
            waitForLink: { [weak self] shouldStop in
                // A seek or a producer restart owns the link for a moment; a thumbnail can wait that
                // out, but not ordinary fetching, or it would stall whenever the pump is busy.
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline, !shouldStop(), let self,
                      self.restartInFlight || (self.sideReaderLinkGate?.state.seeking ?? false) {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            },
            // The budget learns its limits mid-session (a 429 halves them and arms a pacer), so the
            // check `start()` made is repeated before every read. A custom reader has no origin.
            sourceReadsAllowed: {
                custom != nil || !(OriginRequestBudget.shared.requiresSerialRequests(url)
                                   || OriginRequestBudget.shared.isPaced(url))
            },
            interruptReads: { reader.interrupt() },
            closeReader: { reader.close() })
    }

    /// Stop answering I-frame requests. The shutdown waits for a read in flight, so it runs off the
    /// caller's thread; the provider is cleared first, so no new request reaches the rendition. The
    /// reference stays, because `stop()` has to drain the same shutdown before it frees the codec
    /// parameters the builder reads.
    private func tearDownIFrameRendition() {
        provider?.setIFrameSource(nil)
        guard let rendition = iFrameRendition else { return }
        DispatchQueue.global(qos: .utility).async { rendition.shutdown() }
    }

    private func closeUnusedCustomIFrameReader() {
        customIFrameReader?.reader.close()
        customIFrameReader = nil
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

        // Scan-forward + dynamic-shift: producer scans for the first AV_PKT_FLAG_KEY packet whose
        // presentation time reaches videoTarget (a plan-boundary PTS; judging by DTS dropped the
        // anchor IRAP under B-frame reorder, AE#169 round 3), then computes
        // shift = actualFirstDts - desiredFirstTfdt and applies it to all subsequent packets.
        // Audio target set dynamically after video lands.
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
            // The produced timeline continues at the segment's ADVERTISED item-axis start, never at
            // its (possibly backed-off) source boundary: `startPts` is a gate/seek target chosen to sit
            // at-or-below the segment's IRAP (AE#268), while `startSeconds` is what the playlist told
            // AVPlayer this segment starts at. Identical for the keyframe and uniform plans, where the
            // boundary is the item-axis start plus the anchor.
            desiredVideoTfdt = sourceVideoTbSeconds > 0
                ? Int64((segmentPlan[baseIndex].startSeconds / sourceVideoTbSeconds).rounded())
                : segmentPlan[baseIndex].startPts - firstKeyframePts
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

        let producerEpoch = nextProducerEpoch()
        let prod = try HLSSegmentProducer(
            demuxer: dem,
            videoStreamIndex: videoStreamIndex,
            video: cfg,
            audio: savedAudioConfig,
            sideAudioDemuxer: sideAudioDemuxer,
            cache: cache,
            baseIndex: baseIndex,
            targetSegmentDurationSeconds: liveCutTargetSeconds,
            videoFallbackDurationPts: videoFallbackDurationPts,
            audioFallbackDurationPts: audioFallbackDurationPts,
            restartTargetVideoPts: videoTarget,
            boundaryClaimsRandomAccess: planBoundariesClaimRandomAccess,
            planBoundaryAxis: planBoundaryAxis,
            closedCaptionStreamIndex: closedCaptionStreamIndexForSession,
            subtitleTapStreamIndices: Set(nativeSubtitleSourceStreamIndicesForSession.compactMap { $0 }),
            subtitlePacketStreamIndices: allEmbeddedSubtitleStreamIndices,   // #112 rework
            desiredFirstVideoTfdtPts: desiredVideoTfdt,
            desiredFirstAudioTfdtPts: desiredAudioTfdt,
            segmentBoundaries: segmentBoundaries,
            planAnchorVideoPts: firstKeyframePts,
            isLive: isLiveSession,
            // #368: a forward-only chunked archive folds its chunk-seam PTS resets (incl. the
            // libavformat 33-bit wrap correction) the way live folds program boundaries; without
            // it the leap walks the cutter to the plan tail and the session deadlocks.
            foldsSequentialTimeline: sequentialOriginPinsProducerToZero,
            packedSideAudioStartPts: packedSideAudioStartPts,
            packedSideAudioFallbackDurationPts: packedSideAudioFallbackDurationPts,
            bufferAheadSegments: producerBufferAheadSegments,   // [MovieClaw P23] 暂停下载时为 0
            prefetchDiskBudgetBytes: retentionBudgetBytes,
            // AE#222: nil until a pump proved this source cuts its first segment before any audio packet
            // arrives; from then on every producer of the session muxes moov from this frame.
            audioMoovPrimeFrame: sessionAudioMoovPrimeFrame,
            // AE#366: once one producer has searched the whole source for an audio frame and come
            // back empty, later ones must not repeat the search per revive attempt.
            audioMoovPrimeKnownUnobtainable: sessionAudioMoovPrimeUnobtainable,
            // AE#464: read here rather than pushed, so every producer this session builds (seek
            // restart, live reopen, #99 revive) cuts with the offset currently in force.
            audioDelaySeconds: audioDelaySeconds,
            epoch: producerEpoch
        )
        // #240: threaded onto every producer (initial + restart), like the wedge-detector providers
        // below. The side readers read one gate for the whole session, so a restart must not leave
        // a gap where nobody claims the link.
        prod.sideReaderLinkGate = sideReaderLinkGate
        prod.playedMediaLedger = playedMediaLedger
        prod.onFirstHDR10PlusDetected = { [weak self] in
            self?.notifyHDR10PlusOnce()
        }
        prod.onVideoShiftKnown = { [weak self] shiftPts, firstItemTfdtPts, normalizationShiftPts in
            self?.handleVideoShiftKnown(
                shiftPts, firstItemTfdtPts: firstItemTfdtPts,
                normalizationShiftPts: normalizationShiftPts, producerEpoch: producerEpoch)
        }
        prod.onLiveTimelineRebase = { [weak self] shiftPts, seamOutputSeconds in
            self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: seamOutputSeconds,
                                           producerEpoch: producerEpoch)
        }
        prod.onPumpFinished = { [weak self, weak prod] reason in
            guard let self, let prod else { return }
            self.handlePumpFinished(prod, reason: reason)
        }
        // #65: let the pump suspend its backpressure wedge detector while AVPlayer is paused (a paused
        // consumer issues no forward fetch; its frozen fetch target is not a wedge). Threaded onto every
        // producer (initial + restart) so the guard survives scrub/audio-switch rebuilds.
        prod.wantsToPlayProvider = playIntentProvider
        // #93 retest: the rendered clock feeds the wedge detector's fast path (park + both signals
        // frozen -> single-digit detection). Threaded onto every producer like the play-intent guard.
        prod.playbackPositionProvider = currentPlaybackPositionProvider
        // #35/#93 cold-startup: suspend the wedge detector until the first frame lands (pre-roll of a
        // slow high-bitrate DV master must not be misread as a wedge). Threaded onto every producer.
        prod.hasStartedRenderingProvider = hasStartedRenderingProvider
        // AE#446 round 3: the no-cut watchdog's starvation exit tears down the read a closed window
        // is waiting on. Threaded onto every producer like the guards above, so a reopen does not
        // leave the exit unguarded while the consumer is still walking the runway.
        prod.outageRunwayProvider = { [weak self] in
            self?.provider?.outageRunwayAheadOfConsumer ?? false
        }
        prod.closedCaptionObserver = closedCaptionObserverForSession   // #77
        prod.a53CaptionObserver = a53CaptionObserverForSession   // #131
        // #260: resolved per frame, so installing an observer mid-session reaches this producer too.
        prod.nativeVideoFrameTimeObserverProvider = { [weak self] in
            self?.nativeVideoFrameTimeObserverSnapshot()
        }
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
        // Audit HLS-101: the first producer is built before the provider exists and `start()` wires
        // it; every later one (live reopen, in-place rebuild, AE#222 rebuild) is wired here.
        if let prov = provider {
            wireProviderCallbacks(prod, to: prov)
        }
        return prod
    }

    /// The producer-to-provider reports the playlist is built from. A live producer without them
    /// cuts segments the playlist never lists (audit HLS-101).
    func wireProviderCallbacks(_ prod: HLSSegmentProducer, to prov: VideoSegmentProvider) {
        if isLiveSession {
            prod.onLiveSegmentFinalized = { [weak prov] index, durationSeconds, startPtsSeconds, discontinuous in
                prov?.appendLiveSegment(index: index,
                                        startSeconds: startPtsSeconds,
                                        durationSeconds: durationSeconds,
                                        discontinuous: discontinuous)
            }
            prod.onLiveSegmentSound = { [weak prov] index, first, last in
                prov?.noteLiveSegmentSound(index: index, firstSeconds: first, lastSeconds: last)
            }
            // AE#443: the runaway park has to sit above the window this session actually serves, or it
            // bounds the window instead of backstopping it, and its enforcement (a sleeping read
            // thread) stops the origin from being drained.
            prod.liveResidentCapProvider = { [weak prov] in prov?.liveResidentParkCap() ?? 0 }
        } else if sequentialOrigin {
            prod.onSequentialSegmentFinalized = { [weak prov] index, durationSeconds in
                prov?.appendSequentialSegmentDuration(index: index, durationSeconds: durationSeconds)
            }
        }
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
    /// Live muxerFailed in-place rebuilds, bounded by progress like the reopen cycles above: new segments
    /// since the last death reset the budget (an hours-long channel legitimately crosses several encoder
    /// restarts, so a session-lifetime gate like the VOD #99 one would be wrong here); consecutive barren
    /// deaths exhaust it and the session halts + delegates to host retune.
    var liveMuxerRebuildCycles = 0
    var lastMuxerRebuildSegmentCount = -1
    static let maxLiveMuxerRebuildCycles = 3

    private func handleVideoShiftKnown(_ shiftPts: Int64, firstItemTfdtPts: Int64,
                                      normalizationShiftPts: Int64, producerEpoch: UInt64) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        let seamItemSeconds = Double(firstItemTfdtPts) * sourceVideoTbSeconds
        // Live rebases the whole timeline at a program boundary and nothing older comes back on
        // screen, so its axis is the epoch's own and it publishes here as it always has.
        guard !isLiveSession else {
            guard isInstalledProducer(producerEpoch) else { return }
            // Live has no placement model: the epoch's shift IS the axis, so the displacement this
            // session tracks for VOD stays where it is (nothing below reads it on a live session).
            publishPlaylistShift(seconds, seamItemSeconds: seamItemSeconds)
            return
        }
        // AE#418 round 2: on VOD the axis moves when AVPlayer PLACES this segment, not when the
        // producer writes it. Record what the segment is worth and let the placement publish it; an
        // epoch AVPlayer never fetches from must not move the clock at all.
        let index = segmentIndexForPlaylistTime(seamItemSeconds)
        anchorShiftLock.lock()
        // Audit SEG-104: a restart that was replaced while its first read was in flight can still
        // open its gate. Its epoch describes bytes nobody will store, and recording it would drop
        // the entries at and above its index.
        guard installedProducerEpoch == producerEpoch else {
            anchorShiftLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] gate open at seg\(index) from a superseded producer, ignored",
                category: .session)
            return
        }
        // AE#412: a re-cut opens below its boundary on purpose, and AVPlayer places what it produces
        // at its own tfdt, so the epoch is worth nothing to the axis. Recording zero still drops the
        // entries at and above it, which is what the rewrite calls for.
        let isRecut = recutMark?.isOpened(byProducerEpoch: producerEpoch, at: index) == true
        if isRecut { recutMark = nil }
        // PR #533: the run keeps the source-to-item normalization its bytes were written with, even
        // where its opening segment has no placement offset left to carry. Those are the same number
        // only on a source whose timestamps start at zero.
        let axis = EpochAxis(
            presented: seconds,
            carried: normalizationShiftPts == Int64.min
                ? 0 : Double(normalizationShiftPts) * sourceVideoTbSeconds,
            isRecut: isRecut)
        epochAxisByIndex.record(axis, at: index)
        let placementAlreadyHappened = lastPlacedIndex == index
        anchorShiftLock.unlock()
        gateOpenCondition.lock()
        lastGateOpen = (index: index, axis: axis)
        gateOpenCondition.broadcast()
        gateOpenCondition.unlock()
        if placementAlreadyHappened {
            handleSegmentPlaced(at: index)
        }
    }

    /// AE#418 round 2: AVPlayer put the segment at `index` into its timeline, so whatever that
    /// segment carries below its advertised start moves the axis by that much.
    ///
    /// Measured with `play --picture-probe` on a fixture whose picture states its own source time,
    /// at re-aims of 1, 3, 5, 7, 9 and 11 s: the offset **composes**. A run keeps the offset it has
    /// across every boundary it plays through (round 1 measured that), and re-placing an overlong
    /// segment adds its offset again on top: a resume that opened 9 s below its boundary reads
    /// `axisErr=-9.000`, and a seek that makes AVPlayer fetch that same segment a second time reads
    /// `-18.000`, not `-9.000` and not the `0.000` round 1 published there.
    ///
    /// Round 1 keyed this to "the run began here" and answered it from the fetch sequence, which is
    /// what the reporter's seek burst falsified: a fetch that does not follow its predecessor happens
    /// while AVPlayer stays inside the run it is already playing, and the axis was then dropped to
    /// zero under a picture that had not moved. Reproduced on the fixture (`start 53`, seek to 80:
    /// `capErr=-8.983`), and gone once the axis only ever moves by what a placed segment is worth.
    func handleSegmentPlaced(at index: Int) {
        guard !isLiveSession else { return }
        anchorShiftLock.lock()
        lastPlacedIndex = index
        // AE#448: the table answers "is this an epoch's FIRST segment", not "is it worth anything".
        // Every other index is cut on its own boundary inside a run that already carries an axis, and
        // has nothing to say about where that run begins.
        let epoch = epochAxisByIndex.opening(at: index)
        // AE#418 round 8: how far below its axis the last measured placement landed. Zero until one
        // has been read back, which is what makes an item's first placement compose onto the axis.
        let displacement = lastPlacementDisplacement
        let offset = placementOffsetSeconds
        anchorShiftLock.unlock()
        guard let epoch else { return }
        restartLock.lock()
        let plannedStart = index >= 0 && index < segmentPlan.count
            ? segmentPlan[index].startSeconds : nil
        restartLock.unlock()
        guard let plannedStart else { return }
        let current = playlistShiftSeconds
        // The base this placement lands on is the displacement in force LESS however far below it the
        // last placement was measured to sit, which is where AVPlayer puts a segment it composes into
        // a timeline it already has.
        //
        // PR #533 round 2: in DISPLACEMENT, not in axis. What composes is what AVPlayer's timeline is
        // displaced by; the normalization the bytes carry is added once, at the end, by the epoch
        // that wrote them. Composing the axis added the source origin again per placement.
        let base = Self.placementBase(offset: offset, displacement: displacement)
        let composedOffset = Self.placementOffset(
            after: offset, placing: epoch.placedOffset, displacement: displacement)
        let composed = epoch.carried + composedOffset
        let seam = Self.seamItemSeconds(advertisedStart: plannedStart, currentShift: base)
        // AE#418 round 3: keep what this composition assumed, so the placement can be checked against
        // AVPlayer's own account of where it put the bytes.
        anchorShiftLock.lock()
        let superseded = lastPublishedPlacement
        lastPublishedPlacement = PublishedPlacement(
            index: index, advertisedStart: plannedStart, epoch: epoch, assumedBase: base,
            offsetInForce: offset, deliverySerialAtCompose: segmentDeliverySerial)
        placementOffsetSeconds = composedOffset
        anchorShiftLock.unlock()
        if let superseded {
            // AE#418 round 4: named rather than left silent. A placement whose successor arrives before
            // its window closes never gets a verdict, and the reporter read that silence as a check
            // that had not run. It needs none: this placement measures the base AVPlayer composed onto,
            // which is the whole composition below it, including the one being dropped here.
            EngineLog.emit(
                "[HLSVideoEngine] #418 seg\(superseded.index) superseded before it was measured; "
                + "seg\(index) measures the axis it left behind",
                category: .session
            )
        }
        EngineLog.emit(
            "[HLSVideoEngine] #418 seg\(index) placed (advertised \(String(format: "%.3f", plannedStart))s, "
            + "worth \(String(format: "%.3f", epoch.openingSourceAxis))s, sitting "
            + "\(String(format: "%.3f", displacement))s below its axis): axis shift "
            + "\(String(format: "%.3f", current))s -> \(String(format: "%.3f", composed))s "
            + "from item \(String(format: "%.3f", seam))s",
            category: .session
        )
        publishPlaylistShift(composed, seamItemSeconds: seam, offset: composedOffset)
    }

    /// AE#418 round 2: how far AVPlayer's timeline is displaced after it places a segment whose gate
    /// opened `epochOffset` below its boundary. It composes, because AVPlayer puts the placed
    /// segment's advertised start where its CURRENT mapping says that position is, not where the
    /// playlist says it is.
    ///
    /// PR #533 round 2: in DISPLACEMENT. Rounds 2 to 9 measured this on sources whose timestamps
    /// start at zero, where the displacement and the published axis are one number, and composing the
    /// axis then added the source origin once per placement (measured: 599.625 + 596.833 = 1196.458).
    /// The normalization is not composed, it is added once by the epoch that wrote the bytes.
    ///
    /// AE#418 round 5: and it composes onto a BASE, which can sit below the axis. Rounds 5 to 7 read
    /// that distance as a multiple of the epoch's presentation lead: round 5 shipped the multiple as
    /// arithmetic, round 6 measured it per source, round 7 took the median of its readings. Round 8
    /// measured the distance itself with `play --picture-probe` over a throttled origin, on three
    /// clips identical but for their reorder depth and the same burst arm, 2 runs each, every run
    /// identical:
    ///
    /// | fixture | reorder | lead | placement 2 | placement 3 |
    /// | --- | --- | --- | --- | --- |
    /// | `tc-cues-lie.mkv` | none | 0.000 | 0.000 | **0.042** |
    /// | `tc-bf1-cues-lie.mkv` | one frame | 0.042 | 0.000 | 0.083 |
    /// | `tc-bf-cues-lie.mkv` | two frames | 0.083 | 0.083 | 0.125 |
    ///
    /// The bold cell is what retires the model: that clip has `has_b_frames=0` and every gate opens
    /// with `lead=0`, yet its third placement sits a frame below its axis. A quantity that is nonzero
    /// where the lead is exactly zero is not a multiple of the lead. The middle row retires the
    /// source-law premise separately: one source, two placements, 0.000 then 0.083.
    ///
    /// So the distance is carried in the units it corrects, and the reading that already measures the
    /// base measures it. See [[reference_an_offset_about_presentation_is_measured_at_the_pts]].
    static func placementOffset(
        after currentOffset: Double, placing epochOffset: Double, displacement: Double
    ) -> Double {
        return placementBase(offset: currentOffset, displacement: displacement) + epochOffset
    }

    /// The base a placement lands on: the displacement in force, less how far below it the last
    /// placement was measured to sit. This is the value the reading takes back out of AVPlayer's
    /// buffer (`advertisedStart - observedItemStart` is a statement about its timeline and nothing
    /// else), so the prediction is checkable against it on every placement that opens its own run.
    static func placementBase(offset: Double, displacement: Double) -> Double {
        return offset - displacement
    }

    /// AE#418 round 8: how far below the displacement it composed on a placement actually landed.
    ///
    /// Every reading produces one, a confirmation included, which is what the lead coefficient could
    /// not do: it needed a placement carrying a lead, and on a source with no frame reordering, or a
    /// session whose placements are AE#412 re-cuts (worth 0 and lead 0 by construction), there is
    /// never one. Measured on `tc-wide-cues-lie.mkv`, 13 of 13 placements across two runs carried
    /// `lead 0.000s`; the reporter's three arms produced a single sample between them.
    ///
    /// AE#418 round 9: the distance is a MEASUREMENT of a session, and a session's readings can
    /// disagree by a frame. Reproduced on a ten-placement chain (`--seek-count 24` over a throttled
    /// origin, 3 of 3 runs byte-identical): nine placements read 0.000 and `seg5` reads 0.042, so the
    /// composition after it is one frame out and the reading after THAT puts it back. That is the
    /// reporter's arm 1 exactly (`-0.036`, then `+0.004`, then a placement a frame out). What the two
    /// disagree on is which reading is the outlier: on the fixture the standing value is 0.000 and one
    /// reading deviates, on his 23.976 fps asset it is -0.041 and holds to 2 ms across two arms and
    /// two placements. So neither a median (round 7's rule, which lags a genuine step by one reading
    /// and would have cost him 0.041 s at `seg589`) nor a hold-until-confirmed rule is right on both,
    /// and last-wins is kept: the deviation is one frame, it is undone by the next measurable
    /// placement, and no instrument here resolves better than the frame it would be chasing. The
    /// picture probe quantises at one frame too.
    static func placementDisplacement(offset: Double, measuredBase: Double) -> Double {
        let raw = offset - measuredBase
        guard raw.isFinite else { return 0 }
        // Below the epsilon a re-publish moves nothing anyone can see, so the placement is ON its
        // axis rather than a signed hair off it. This is also what keeps a chain of confirmations
        // from printing `-0.000s` at a reader.
        guard abs(raw) > axisRepublishEpsilonSeconds else { return 0 }
        return min(max(raw, -maxPlacementDisplacementSeconds), maxPlacementDisplacementSeconds)
    }

    /// A reading can be wrong once (round 4 accepts that on purpose), so what it carries into the NEXT
    /// composition is bounded. The widest placement measured is three frames at 24 fps; this is well
    /// past that and well inside `placementSeamToleranceSeconds`, so a stray can never move a
    /// composition by anything a reader would call a seam.
    static let maxPlacementDisplacementSeconds = 0.25

    /// The item position the placed segment's content begins at: its advertised start, read through
    /// the axis that was in effect before it landed. Everything below that is still the old epoch's.
    static func seamItemSeconds(advertisedStart: Double, currentShift: Double) -> Double {
        return advertisedStart - currentShift
    }

    /// AVPlayer discards a sub-second axis offset at a seek and snaps back to the playlist; a larger
    /// one it keeps. Measured on the fixture: `-0.500` and `-0.875` read `axisErr=0.000` after a seek,
    /// `-1.000`, `-1.083`, `-1.292`, `-1.500`, `-3.000`, `-4.000`, `-7.000`, `-9.000` and `-11.000`
    /// all survive one unchanged. Anything below this is worth less than the frame it would move.
    static let axisSnapsBelowSeconds = 1.0

    /// AE#534: the size of the axis was never the thing that decided this, it only correlated with it.
    /// What AVPlayer actually throws an offset away at is a seek that makes it REBUILD its timeline,
    /// and a seek whose landing it already holds rebuilds nothing, so it keeps the displacement and
    /// this rule has to keep it too. Measured on `tc-cues-lie.mkv` over `slowrange.py` at 600 kbps /
    /// 300 ms, same standing axis of -0.375 in both arms, 2 of 2 runs each:
    ///
    /// | seek | landing | placed ranges | AVPlayer | `capErr` on `main` |
    /// | --- | --- | --- | --- | --- |
    /// | 73 -> 78 | 78.375 | 72.000-84.337, holds it | KEEPS -0.375 | **-0.400**, wrong for the run |
    /// | 73 -> 80 | 80.375 | 72.000-80.343, does not | discards it | -0.025, right |
    ///
    /// The round 2 arms that measured the size boundary all LEFT the buffer, which is why the proxy
    /// held for them and why they stay exactly as they were here.
    ///
    /// Read the placement off `AVPlayerItem.loadedTimeRanges` and nothing else. The producer's own
    /// buffered frontier is a different number in both directions on these very arms (95.62 against a
    /// placed 84.337, and 75.62 against a placed 80.343): a fetch is not a placement (AE#418), and
    /// only the placement says whether there is a timeline to rebuild.
    static func axisShiftAfterSeek(_ shift: Double, landingIsPlaced: Bool) -> Double {
        if landingIsPlaced { return shift }
        return abs(shift) < axisSnapsBelowSeconds ? 0 : shift
    }

    /// AE#418 round 2: the host seeked and the axis was small enough for AVPlayer to throw away.
    /// Publishing zero from the landing forward is what keeps the clock over the picture; the seam
    /// leaves everything below the landing on the axis its bytes were placed with.
    func snapAxisAfterSeek(landingItemSeconds: Double, landingIsPlaced: Bool) {
        guard !isLiveSession else { return }
        // AE#481: the landing reading asks about the segment that opens the run it lands in, so the
        // record starts empty at every seek. A stale one would describe the run before this seek.
        anchorShiftLock.lock()
        firstDeliveredIndexSinceSeek = nil
        anchorShiftLock.unlock()
        let current = playlistShiftSeconds
        let snapped = Self.axisShiftAfterSeek(current, landingIsPlaced: landingIsPlaced)
        guard snapped != current else {
            // AE#534: say so when the gate is what kept it. Without this the two cases that matter,
            // "the axis was too large to discard" and "the landing was already held", leave the same
            // silence behind, and a report about a clock sitting off the picture cannot be read.
            if landingIsPlaced, current != 0, abs(current) < Self.axisSnapsBelowSeconds {
                EngineLog.emit(String(
                    format: "[HLSVideoEngine] #534 axis %.3fs kept at the seek landing %.3fs "
                    + "(AVPlayer already holds it, so nothing rebuilds)",
                    current, landingItemSeconds), category: .session)
            }
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] #418 axis \(String(format: "%.3f", current))s discarded at the seek "
            + "landing \(String(format: "%.3f", landingItemSeconds))s (AVPlayer snaps a sub-second axis)",
            category: .session
        )
        // Round 3: AVPlayer threw this placement's offset away, so there is no longer a placement for
        // the check to measure. Left standing, the record would be read against a run now sitting on
        // the raw playlist, the base would measure 0, and the correction would put back exactly the
        // axis this snap just removed.
        anchorShiftLock.lock()
        lastPublishedPlacement = nil
        anchorShiftLock.unlock()
        // Still asked of the AXIS rather than of the displacement, which is the second half of AE#534
        // and deliberately not this change: on a source whose timestamps begin at 600 s the rule
        // cannot fire at all, and the one arm that separates the two geometries says inert is the
        // right answer there. With the placement gate above that arm is now inert for the right
        // reason rather than by accident, which is what the displacement half needs before it moves.
        publishPlaylistShift(
            snapped, seamItemSeconds: landingItemSeconds, offset: snapped - sourceStartSeconds)
    }

    /// AE#481: what the run holding a seek landing carries, read off the playlist instead of inherited
    /// from a composition measured somewhere else.
    ///
    /// The #418 axis is published once, at the advertised start of the segment whose gate re-aimed, and
    /// it stands for everything after that seam. Measured with `play --picture-probe` on the #418 chain
    /// with the re-anchoring seek LAST (`--seek-count 5 --seek-pattern 65,60,70,58,75`, `slowrange.py`
    /// at 600 kbps / 300 ms), the picture says the axis is narrower than that:
    ///
    /// | item | 53.000 | 67.833 | 79.000 | 84.917 | ... | 119.958 |
    /// | --- | --- | --- | --- | --- | --- | --- |
    /// | `pic - picItem` | **-9.000** | 0.000 | 0.000 | 0.000 | | 0.000 |
    ///
    /// The offset belongs to the run `seg13` opened. A seek that opens a NEW run at a segment the
    /// producer wrote at its planned position lands on a source-true stretch, and nothing tells this
    /// side: `capErr` reads `+9.017` from the landing to the end of the session (2 of 2 runs at
    /// 600 kbps / 300 ms, 1 of 1 at 1200 kbps / 200 ms, and not at 3200 kbps / 100 ms, where the
    /// landing stays inside the run already playing). Ten rounds of #418 never saw it standing because
    /// a seek burst heals it inside a second: the next seek composes a placement, and its reading comes
    /// off the changed timeline.
    ///
    /// **The discriminator is where the run OPENS, asked of ONE segment.** A segment advertised at A
    /// goes into a timeline carrying an axis at the seam that axis predicts, and into a timeline
    /// carrying nothing at A itself, which is round 7's pair of admissible answers. The segment to ask
    /// is the first one the local server answered after the seek, because that is the one whose content
    /// opens the run the landing sits in. Asked of the PLAN instead ("does this run open on some
    /// playlist position"), the same rule publishes on a coincidence: 31 boundaries over 120 s against a
    /// half-second tolerance, and measured on the #418 chain it wrote a 0.000 axis into a timeline
    /// carrying -27.875 s, taking `capErr` from +0.092 to -27.883 in one tick. A wrong candidate now
    /// costs silence rather than an axis: neither answer matches and nothing is published.
    static func landingAxisReading(
        landingItemSeconds: Double,
        ranges: [(Double, Double)],
        openingSegmentStart: Double,
        worth: Double,
        assumedBase: Double,
        standingAxis: Double
    ) -> (axis: Double, runStart: Double)? {
        guard let holding = ranges.first(where: {
            $0.0.isFinite && $0.1.isFinite && $0.0 <= landingItemSeconds && landingItemSeconds <= $0.1
        }) else { return nil }
        let predicted = seamItemSeconds(advertisedStart: openingSegmentStart, currentShift: assumedBase)
        // Round 7's two admissible answers, asked at a landing instead of at a placement: a run opens
        // where the timeline this session knows would put this segment, or at the segment's own
        // playlist position, which is what a timeline carrying nothing there does.
        //
        // Both halves are load-bearing. Asking only "does the run open on SOME playlist position"
        // publishes on a coincidence: the plan has 31 boundaries over 120 s and the tolerance is half a
        // second, and measured on the #418 chain that read a 0.000 axis into a timeline carrying
        // -27.875 s (`capErr` +0.092 to -27.883 in one tick). One segment can be asked; the plan cannot.
        guard abs(holding.0 - predicted) > placementSeamToleranceSeconds,
              abs(holding.0 - openingSegmentStart) <= placementSeamToleranceSeconds else { return nil }
        let base = measuredPlacementBase(
            advertisedStart: openingSegmentStart, observedItemStart: holding.0)
        let axis = base + worth
        guard abs(axis - standingAxis) > axisRepublishEpsilonSeconds else { return nil }
        return (axis, holding.0)
    }

    /// AE#481: read the axis where a seek landed and publish it when the timeline disagrees with the
    /// composition it inherited. Returns whether anything was published.
    func applyLandingAxisReading(landingItemSeconds: Double, ranges: [(Double, Double)]) -> Bool {
        guard !isLiveSession else { return false }
        anchorShiftLock.lock()
        let pending = lastPublishedPlacement
        let epochs = epochAxisByIndex
        let displacement = lastPlacementDisplacement
        let standingOffset = placementOffsetSeconds
        let opening = firstDeliveredIndexSinceSeek
        anchorShiftLock.unlock()
        // A placement awaiting measurement has the more specific reading (round 7) and measures the
        // same ranges; two writers on one axis would race, and the placement knows what it composed.
        //
        // PR #533: a run AVPlayer rebuilt at the segment's own playlist position has no placement
        // offset left, and is NOT therefore source-true. Its bytes still map item time back onto the
        // source with the normalization the producer folded into them, and reading a zero there cost
        // a 600 s source origin its whole axis.
        guard pending == nil, let opening,
              let openingSourceShift = epochs.sourceAxis(at: opening) else { return false }
        restartLock.lock()
        let advertisedStart = opening >= 0 && opening < segmentPlan.count
            ? segmentPlan[opening].startSeconds : nil
        restartLock.unlock()
        guard let advertisedStart else { return false }
        let standing = playlistShiftSeconds
        guard let reading = Self.landingAxisReading(
            landingItemSeconds: landingItemSeconds, ranges: ranges,
            openingSegmentStart: advertisedStart, worth: openingSourceShift,
            assumedBase: Self.placementBase(offset: standingOffset, displacement: displacement),
            standingAxis: standing)
        else { return false }
        EngineLog.emit(
            "[HLSVideoEngine] #481 the run holding the landing at item "
            + "\(String(format: "%.3f", landingItemSeconds))s opens at "
            + "\(String(format: "%.3f", reading.runStart))s, which is seg\(opening)'s own playlist "
            + "position \(String(format: "%.3f", advertisedStart))s, so it carries "
            + "\(String(format: "%.3f", reading.axis))s and not the "
            + "\(String(format: "%.3f", standing))s this session was mapping with",
            category: .session
        )
        let carried: Double = epochs.carried(at: opening) ?? 0
        publishPlaylistShift(
            reading.axis, seamItemSeconds: reading.runStart, offset: reading.axis - carried)
        return true
    }

    /// AE#418 round 3: one placement, kept so the composition that was published for it can be checked
    /// against AVPlayer's own account of where those bytes landed.
    struct PublishedPlacement: Sendable {
        let index: Int
        /// The segment's start in the playlist, which is the position AVPlayer reads through its axis.
        let advertisedStart: Double
        /// PR #533: the epoch that wrote these bytes, both what its first segment shows against its
        /// advertised start and the normalization every packet of the run carries. Kept here rather
        /// than looked up at measurement time: a backward restart between the composition and its
        /// reading drops this epoch's entry, which is the pruning rule working, and the late lookup
        /// would then answer with an older run's numbers.
        let epoch: EpochAxis
        /// What the segment carries below its advertised start, in AXIS terms, which is what a
        /// reading adds the measured base to. Negative for a gate that opened early on a source whose
        /// timestamps start at zero.
        var worth: Double { epoch.openingSourceAxis }
        /// The displacement the composition assumed AVPlayer's timeline was carrying when it placed
        /// this.
        let assumedBase: Double
        /// The displacement in force when it was composed. This is what turns a reading into the
        /// distance the next composition uses, and what a rollback returns to.
        let offsetInForce: Double
        /// AE#418 round 7: how many segment responses this session had completed when the placement
        /// was composed, so a later answer can be told from the one before it.
        let deliverySerialAtCompose: Int
    }

    /// Below this a re-publish moves nothing anyone can see, and publishing anyway would have the
    /// measurement re-trigger its own verification for the rest of the session.
    static let axisRepublishEpsilonSeconds = 0.001

    /// The axis AVPlayer's timeline was carrying when it placed a segment advertised at
    /// `advertisedStart` with its content beginning at `observedItemStart`.
    ///
    /// AVPlayer puts a placed segment's first sample at its advertised start read through the axis the
    /// timeline already carries, so that one subtraction inverts the placement: the reading is the base
    /// it composed onto, whatever this side assumed.
    static func measuredPlacementBase(advertisedStart: Double, observedItemStart: Double) -> Double {
        return advertisedStart - observedItemStart
    }

    /// AE#418 round 7: the run AVPlayer opened for THIS placement, identified by where it begins.
    ///
    /// A placed segment's first sample goes to its advertised start read through the base its timeline
    /// carries, so the run it opens begins at the seam the composition predicts, give or take the
    /// presentation lead the reading exists to measure. That is an identity, not a yardstick: the run
    /// is picked by where it opens, and the base is then read off it, residual and all.
    ///
    /// A timeline AVPlayer threw away carries no base at all, so the same segment then opens at its
    /// advertised start itself. Measured on `tc-wide-cues-lie.mkv` (a 60 s keyframe drought), seeking
    /// 35 s back out of the buffer: the composition predicted item 62.333 on an axis of -10.333 and
    /// AVPlayer opened `[52.000-75.969]` for an advertised 52.000, base 0.000. That reading is 10.3 s
    /// from the prediction and it is right, the picture reads -12.000 for the rest of the run. So the
    /// placement has two admissible answers, both of them "the run begins where the segment begins".
    ///
    /// Round 4 asked instead which run was NEW against a baseline of what the item held, and during a
    /// seek burst that is a different question with a different answer. Measured on the fixture over a
    /// throttled origin (`--seek-every 1 --seek-count 4 --seek-pattern 70,53,71,54`), with the picture
    /// as witness: a placement predicting its seam at item 53.000 had its own run in hand for four
    /// samples (`[53.083-70.035]`, one lead above the seam) and every one was refused for opening
    /// below an overlapping baseline; the fifth sample found a later seek's run at `[74.208-86.099]`,
    /// which is new by every baseline test, and adopting it published a 21 s error against a picture
    /// that read -10.125. The same burst on the wide fixture adopted a run 41.667 s away by the
    /// disjoint-from-the-baseline test, for a segment whose bytes were nowhere near it.
    static func placementRunStart(
        ranges: [(Double, Double)], predictedSeam: Double, rawSeam: Double? = nil
    ) -> (start: Double, source: ReadingSource)? {
        if let own = runOpening(at: predictedSeam, in: ranges) { return (own, .ownRun) }
        if let raw = rawSeam, let rebuilt = runOpening(at: raw, in: ranges) {
            return (rebuilt, .rebuiltTimeline)
        }
        return nil
    }

    private static func runOpening(at seam: Double, in ranges: [(Double, Double)]) -> Double? {
        return ranges
            .filter { $0.0.isFinite && abs($0.0 - seam) <= placementSeamToleranceSeconds }
            .min(by: { abs($0.0 - seam) < abs($1.0 - seam) })?.0
    }

    /// How far from its predicted seam a run can open and still be this placement's.
    ///
    /// The distance is a presentation lead or two: 0.083 s on the two-frame-reorder fixture, 0.042 s
    /// on the reporter's 23.976 fps asset. Half a second is past every geometry measured and still far
    /// inside one segment, so nothing that belongs to another placement can be inside it.
    static let placementSeamToleranceSeconds = 0.5

    /// Whether AVPlayer holds anything where this placement said its bytes would land.
    ///
    /// AE#418 round 7: the composition is a statement about bytes in AVPlayer's timeline, so bytes
    /// nobody holds never moved the axis. The reporter's run 1 kept a composition of -28.028 s for a
    /// placement whose producer was torn down with its segment discarded: unmeasurable, kept, and
    /// 4.5 s later the next measurable placement found the axis 33 ms from where it stood before it.
    static func placementIsHeld(ranges: [(Double, Double)], seam: Double) -> Bool {
        return ranges.contains { $0.0.isFinite && $0.1.isFinite && $0.0 <= seam && seam <= $0.1 }
    }

    /// What a placement measured out of AVPlayer's own buffer says the axis is.
    struct PlacementReading: Equatable {
        /// The base AVPlayer composed onto, read out of where it holds the bytes.
        let base: Double
        /// The axis that base and this segment's worth make together.
        let axis: Double
        /// The item position the segment's content begins at, read through the measured base.
        let seam: Double
        /// What the composition had wrong. Zero on a session whose predictions are all landing.
        let residual: Double
    }

    /// AE#418 round 4: the reading IS the axis. Round 3 measured the same number and then collapsed it
    /// onto the nearest value this side had already published, which made the prediction the yardstick
    /// for the measurement that was supposed to check it: a placement whose real base matched no
    /// prediction was thrown away (the reporter's session kept composing to -26.152 s while two
    /// readings 400 s of media apart both said -10.93 s), and a placement whose real base was a frame
    /// or two off the prediction was called a confirmation, so that difference stayed in the axis and
    /// the next placement composed on top of it. Six such confirmations walked the error from 0.000 to
    /// 0.290 s, at which point the same check refused every reading for the rest of the session.
    static func placementReading(
        advertisedStart: Double, worth: Double, assumedBase: Double, observedItemStart: Double
    ) -> PlacementReading? {
        let base = measuredPlacementBase(
            advertisedStart: advertisedStart, observedItemStart: observedItemStart)
        guard base.isFinite else { return nil }
        return PlacementReading(
            base: base, axis: base + worth, seam: advertisedStart - base, residual: base - assumedBase)
    }

    /// AE#418 round 3: check the axis just published against where AVPlayer says it put the bytes, and
    /// correct it when the two disagree.
    ///
    /// The composition itself is right and measured: AVPlayer places a segment at its advertised start
    /// read through the axis its timeline already carries, so an epoch that opens below its boundary
    /// moves the axis by that much on top of what was there. What this side cannot see is whether a
    /// placement it counted ever reached that timeline. A fetch is not a placement: during a seek burst
    /// AVPlayer asks for a segment and then seeks away before the bytes are used, so the axis was
    /// composed onto a base its timeline never carried, permanently, for every placement after it.
    ///
    /// The reporting case (a six-seek burst): a resume worth `-3.045` and then two restarts worth
    /// `-2.043` and `-5.589` published `-10.677`, while the item's own loaded range began at `791.2`
    /// against an advertised `788.204`, which is a base of `-3.045`. The middle fetch moved nothing,
    /// the honest axis was `-8.634`, and the captions ran the difference behind the picture.
    ///
    /// Round 4 ADOPTS what it reads. What is left open is a seek that opens a fresh run at some other
    /// segment inside the window, without restarting the producer and so without recording a placement
    /// of its own: this would then measure one segment's advertised start against another segment's
    /// run. That is a wrong adoption, and it is undone by the next placement, which measures again from
    /// nothing. The refusal it replaces was permanent, and cost a reporter 42.6 s of axis for the rest
    /// of a session, so the asymmetry decides it: a measurement that can be wrong once beats a
    /// prediction that cannot be corrected.
    func reconcileAxisWithObservedPlacement(
        observedItemStart: Double, itemClock: Double, source: ReadingSource = .ownRun
    ) {
        guard !isLiveSession else { return }
        anchorShiftLock.lock()
        let placement = lastPublishedPlacement
        // One placement is measured once. Publishing below re-enters this through the shift hook, and
        // the run this reading came from is by then part of the next baseline anyway.
        lastPublishedPlacement = nil
        anchorShiftLock.unlock()
        guard let placement else { return }
        // PR #533 round 2: one worth, whichever timeline this was read off. A placement's bytes map
        // item time onto the source with the normalization they carry plus what their gate backed
        // off, and that is true of the run AVPlayer opened for them and of one it rebuilt; what the
        // two disagree about is the BASE, which is measured. Round 1 branched here because the
        // composition still worked in axis terms, where an AE#412 re-cut is worth nothing.
        guard let reading = Self.placementReading(
                advertisedStart: placement.advertisedStart, worth: placement.worth,
                assumedBase: placement.assumedBase, observedItemStart: observedItemStart)
        else { return }
        // Round 7: only the run this placement opened says anything about where a placement sits. A
        // timeline AVPlayer rebuilt puts the segment on a base that is a statement about the rebuild,
        // and round 6 let exactly those readings set the parameter (the reporter's 2.00x, and a 21 s
        // residual on the fixture teaching the same value).
        let teaching: DisplacementTeaching
        if source == .ownRun {
            teaching = learnPlacementDisplacement(from: placement, measuredBase: reading.base)
        } else {
            anchorShiftLock.lock()
            let standing = lastPlacementDisplacement
            anchorShiftLock.unlock()
            teaching = .notTaught(standing: standing)
        }
        // PR #533: against the axis this placement COMPOSED, not against the residual. They are the
        // same test only while the reading is worth what the composition was: a rebuilt reading
        // measures the same base and arrives at a different axis, and asking the residual would call
        // that a confirmation and publish nothing.
        let composedAxis = placement.assumedBase + placement.worth
        guard abs(reading.axis - composedAxis) > Self.axisRepublishEpsilonSeconds else {
            // Said out loud, because a check that only speaks when it disagrees cannot be told from one
            // that never ran. This is the line that says the axis is measured on this session.
            EngineLog.emit(
                "[HLSVideoEngine] #418 seg\(placement.index) placement confirmed: AVPlayer holds it "
                + "from item \(String(format: "%.3f", observedItemStart))s, base "
                + "\(String(format: "%.3f", reading.base))s as published; \(teaching.clause)",
                category: .session
            )
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] #418 seg\(placement.index) placed on base \(String(format: "%.3f", reading.base))s, "
            + "not \(String(format: "%.3f", placement.assumedBase))s (AVPlayer holds it from item "
            + "\(String(format: "%.3f", observedItemStart))s, clock \(String(format: "%.3f", itemClock))s, "
            + "residual \(String(format: "%+.3f", reading.residual))s): axis "
            + "\(String(format: "%.3f", composedAxis))s -> "
            + "\(String(format: "%.3f", reading.axis))s; \(teaching.clause)",
            category: .session
        )
        publishPlaylistShift(
            reading.axis, seamItemSeconds: reading.seam,
            offset: reading.base + placement.epoch.placedOffset)
    }

    /// AE#418 round 8: a placement that opened a run of its own says how far below the axis it
    /// composed on AVPlayer actually put it, and the next composition starts there.
    ///
    /// Learned from every reading, the confirmations included: a confirmation is the standing value
    /// being right, and recording it is what keeps it from drifting unchallenged. Round 6 and 7
    /// learned instead from the subset of placements carrying a presentation lead, which on a source
    /// without frame reordering, and on any session whose placements are AE#412 re-cuts, is none of
    /// them.
    @discardableResult
    private func learnPlacementDisplacement(
        from placement: PublishedPlacement, measuredBase: Double
    ) -> DisplacementTeaching {
        let sample = Self.placementDisplacement(
            offset: placement.offsetInForce, measuredBase: measuredBase)
        anchorShiftLock.lock()
        let previous = lastPlacementDisplacement
        lastPlacementDisplacement = sample
        anchorShiftLock.unlock()
        guard abs(sample - previous) > Self.axisRepublishEpsilonSeconds else {
            return .taught(sample: sample, moved: false)
        }
        EngineLog.emit(
            "[HLSVideoEngine] #418 seg\(placement.index) sat "
            + "\(String(format: "%.3f", sample))s below the axis it composed on, not "
            + "\(String(format: "%.3f", previous))s; the next composition starts there "
            + "(displacement \(String(format: "%.3f", placement.offsetInForce))s, base measured "
            + "\(String(format: "%.3f", measuredBase))s)",
            category: .session
        )
        return .taught(sample: sample, moved: true)
    }

    /// AE#418 round 9: what a reading did to the standing distance, said on the reading's own line.
    ///
    /// Round 8 taught from every own-run reading and printed only the moves, so a reading that taught
    /// the value it already had and a reading that was not allowed to teach at all printed the same
    /// verdict. The reporter's round-8 retest ends on exactly that: three `placement confirmed` lines
    /// with no `sat` line under them, and no way from the log to tell which of the two had happened.
    /// A standing value that every later `placed` line quotes needs its provenance on the line that
    /// sets it, not in the reader's head.
    enum DisplacementTeaching: Equatable {
        /// An own-run reading. `moved` is false when it taught the value already standing, which is a
        /// confirmation of the distance rather than silence about it.
        case taught(sample: Double, moved: Bool)
        /// A reading off a timeline AVPlayer rebuilt, which is a statement about the rebuild and not
        /// about where a placement sits below its axis (round 7). It corrects the axis and teaches
        /// nothing.
        case notTaught(standing: Double)

        var clause: String {
            switch self {
            case .taught(let sample, let moved):
                return moved
                    ? "taught the distance \(String(format: "%.3f", sample))s"
                    : "taught the standing distance \(String(format: "%.3f", sample))s again"
            case .notTaught(let standing):
                return "taught nothing, read off a rebuilt timeline; the distance stays "
                    + "\(String(format: "%.3f", standing))s"
            }
        }
    }

    /// AE#418 round 7: the window closed with no run this placement could be read from, so the
    /// question left is whether AVPlayer holds those bytes at all.
    ///
    /// Round 4 named this case and kept the composition, which is right when the placement happened
    /// and its run merged into one already there, and wrong when the placement never reached the
    /// timeline. Both printed the same line. The reporter's run 1: a placement worth -28.028 s was
    /// composed, could not be measured, was kept, and the producer that opened for it was torn down
    /// with its segment discarded (`seg-738.m4s partial at teardown ... not adopted`); 4.5 s later the
    /// next measurable placement found the axis 33 ms from where it had stood before. A composition is
    /// a statement about bytes in AVPlayer's timeline, so bytes nobody holds never moved the axis.
    func resolveUnreadablePlacement(heldInBuffer: Bool, answered: Bool) {
        anchorShiftLock.lock()
        let placement = lastPublishedPlacement
        lastPublishedPlacement = nil
        anchorShiftLock.unlock()
        guard let placement else { return }
        let composed = placement.assumedBase + placement.worth
        // A request still being answered says nothing: a deep re-aim can leave the producer scanning
        // for seconds, and rolling back there would drop a placement that is about to land. Only a
        // request that WAS answered turns an empty buffer into a verdict.
        guard answered else {
            EngineLog.emit(
                "[HLSVideoEngine] #418 seg\(placement.index) is still being served; nothing to read "
                + "yet, keeping the composed axis \(String(format: "%.3f", composed))s",
                category: .session
            )
            return
        }
        guard !heldInBuffer else {
            EngineLog.emit(
                "[HLSVideoEngine] #418 seg\(placement.index) opened no run of its own to measure, but "
                + "AVPlayer holds those bytes; keeping the composed axis "
                + "\(String(format: "%.3f", composed))s",
                category: .session
            )
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] #418 seg\(placement.index) never reached AVPlayer's timeline (nothing "
            + "held at item \(String(format: "%.3f", placement.advertisedStart - placement.assumedBase))s); "
            + "rolling the composed axis \(String(format: "%.3f", composed))s back to "
            + "\(String(format: "%.3f", placement.epoch.carried + placement.offsetInForce))s",
            category: .session
        )
        publishPlaylistShift(
            placement.epoch.carried + placement.offsetInForce,
            seamItemSeconds: Self.seamItemSeconds(
                advertisedStart: placement.advertisedStart, currentShift: placement.assumedBase),
            offset: placement.offsetInForce)
    }

    /// AE#418 round 7: what the local server made of the request this placement was counted from. A
    /// placement is a request that was ANSWERED, and a buffer that holds nothing says nothing while
    /// the answer is still outstanding.
    func recordSegmentDelivery(index: Int, delivered: Bool) {
        guard !isLiveSession else { return }
        anchorShiftLock.lock()
        segmentDeliverySerial += 1
        if segmentDeliveryByIndex.count > 128 {
            // Only the neighbourhood of what is being served can still be waited on; a placement is
            // checked within seconds of its own request.
            segmentDeliveryByIndex = segmentDeliveryByIndex.filter { abs($0.key - index) <= 64 }
        }
        segmentDeliveryByIndex[index] = (segmentDeliverySerial, delivered)
        if delivered, firstDeliveredIndexSinceSeek == nil { firstDeliveredIndexSinceSeek = index }
        anchorShiftLock.unlock()
    }

    /// Where a reading came from, which decides what it is allowed to teach.
    enum ReadingSource: Sendable { case ownRun, rebuiltTimeline }

    /// nil while the request behind the pending placement is still outstanding. An answer recorded
    /// BEFORE that placement was composed belongs to an earlier request for the same index.
    var pendingPlacementDelivery: Bool? {
        anchorShiftLock.lock()
        defer { anchorShiftLock.unlock() }
        guard let placement = lastPublishedPlacement,
              let answer = segmentDeliveryByIndex[placement.index],
              answer.serial > placement.deliverySerialAtCompose
        else { return nil }
        return answer.delivered
    }

    /// Where the placement being checked says its bytes begin: through the base the composition
    /// assumed, and through no base at all for a timeline AVPlayer rebuilt.
    var pendingPlacement: (seam: Double, rawSeam: Double)? {
        anchorShiftLock.lock()
        defer { anchorShiftLock.unlock() }
        guard let placement = lastPublishedPlacement else { return nil }
        return (placement.advertisedStart - placement.assumedBase, placement.advertisedStart)
    }

    /// Whether a placement is waiting to be measured. Nothing to verify means nothing to sample for.
    var hasPlacementAwaitingMeasurement: Bool {
        anchorShiftLock.lock()
        defer { anchorShiftLock.unlock() }
        return lastPublishedPlacement != nil
    }

    /// AE#412: how long to give a re-cut its gate open before the seek goes out without it. A restart
    /// is a demuxer seek plus a scan to the covering random-access point; past this the seek is worth
    /// more than the correction, and the landing degrades to what it does today.
    static let recutGateWaitSeconds: TimeInterval = 2.0

    /// AE#412: how far below a cold seek target AVPlayer is assumed to reach for a random-access
    /// point. It reaches back a fixed span and does NOT search for one: measured with
    /// `play --picture-probe` on a 4 s grid, the first fetch of a cold seek was the segment holding
    /// `target - 8 s` in one run shape and `target - 6 s` in another, on the case fixture and on a
    /// control whose every segment is independent alike. 4 s is deliberately below both, so a landing
    /// AVPlayer would have managed on its own is never re-cut; the cost of the margin is a re-cut
    /// that was not strictly needed, not a landing that is wrong.
    static let coldSeekLookbackSeconds: Double = 4.0

    /// AE#412: the item position to seek AVPlayer to, having first made sure the segment it lands in
    /// can start a decode run there.
    ///
    /// Audio routes packets by plan boundary while video routes them keyframe-gated, so inside a
    /// keyframe drought audio opens boundaries the cutter folded and those segments carry no
    /// random-access point at all. Because AVPlayer's reach back is fixed rather than a search, a
    /// drought wider than that reach leaves the picture starting at the next sync sample ABOVE the
    /// target, and the seek silently skips content. Measured on a 12 s drought, seeking back from
    /// 88 s: a seek to 50.0 s landed at 55.0 s and one to 54.0 s at 54.96 s, while the same source cut
    /// on its real sync samples landed exactly on every target tested.
    ///
    /// The repair is the producer's own gate: a restart anchored at that index opens on the covering
    /// random-access point, so the segment begins at or below its advertised start and covers the
    /// target. The seek target is NOT moved to compensate: measured 3 of 3, AVPlayer puts the re-cut
    /// segment at its own tfdt inside the timeline it is already building (`axisErr` 0.000), so item
    /// time is source time and a correction would land exactly that far past the target instead.
    ///
    /// Runs off the main actor (it parks on the pump). Returns `itemSeconds` unchanged whenever there
    /// is nothing to act on: live, no recorded reach for the landing segment, a random-access point
    /// already within reach below the target, or a re-cut whose gate did not open in time.
    func preparedSeekLanding(itemSeconds: Double) -> Double {
        guard !isLiveSession, let provider else { return itemSeconds }
        dropUnstartedRecut()
        let index = segmentIndexForPlaylistTime(itemSeconds)
        guard let reach = provider.videoReach(at: index) else { return itemSeconds }
        guard let advertised = advertisedStartSeconds(index) else { return itemSeconds }
        let covering = coveringSyncItemSeconds(atOrBelow: itemSeconds, from: index, provider: provider)
        guard Self.needsRecut(landingReach: reach,
                              offsetIntoSegment: itemSeconds - advertised,
                              coveringSyncDistance: covering.map { itemSeconds - $0 }) else {
            return itemSeconds
        }
        EngineLog.emit(
            "[HLSVideoEngine] #412 seek to item \(String(format: "%.3f", itemSeconds))s lands in seg\(index) "
            + "(advertised \(String(format: "%.3f", advertised))s), which cannot start a decode run there "
            + "and no random-access point is within reach below it; re-cutting from the covering one",
            category: .session
        )
        markRecut(at: index)
        // Audit HLS-4: off this task, so the gate wait below bounds the whole re-cut. Inline, an idle
        // coalescer ran the restart here (a 5 s stop wait, a #79 reopen, the demuxer seek) before the
        // wait began, all outside the seek's 8 s landing bound.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.requestRestart(at: index, authoritative: true)
        }
        // Audit HLS-105: a timeout leaves the mark with the restart, whose gate may open later.
        guard let opened = awaitGateOpen(forIndex: index, timeout: Self.recutGateWaitSeconds) else {
            EngineLog.emit(
                "[HLSVideoEngine] #412 seg\(index) re-cut did not open a gate within "
                + "\(String(format: "%.1f", Self.recutGateWaitSeconds))s; seeking on the uncorrected position",
                category: .session
            )
            return itemSeconds
        }
        EngineLog.emit(
            // PR #533: the BACKOFF, not the gate's shift. The shift also carries the source origin,
            // so on a source whose timestamps start at 600 s this line read "opened 591.000s below
            // its boundary" for a re-cut that opened 9 s below it.
            "[HLSVideoEngine] #412 seg\(index) re-cut opened "
            + "\(String(format: "%.3f", opened.gateBackoffSeconds))s below its "
            + "boundary and now covers item \(String(format: "%.3f", itemSeconds))s",
            category: .session
        )
        return itemSeconds
    }

    /// Audit HLS-105: an AE#412 re-cut, owned by the restart that performs it rather than by the seek
    /// waiting on it. The restart binds its producer's epoch at install, and only that producer's gate
    /// open is the re-cut; the seek's wait timing out leaves it alone.
    struct RecutMark: Equatable {
        let index: Int
        private(set) var producerEpoch: UInt64?

        init(index: Int) { self.index = index }

        /// The mark that survives a restart installing `producerEpoch` at `restartIndex`: bound when
        /// it is the marked index, kept while the marked restart has yet to run, dropped once the
        /// restart it was bound to has been replaced by one elsewhere.
        func installing(producerEpoch epoch: UInt64, at restartIndex: Int) -> RecutMark? {
            guard restartIndex == index else { return producerEpoch == nil ? self : nil }
            var bound = self
            bound.producerEpoch = epoch
            return bound
        }

        func isOpened(byProducerEpoch epoch: UInt64, at gateIndex: Int) -> Bool {
            producerEpoch == epoch && gateIndex == index
        }
    }

    func markRecut(at index: Int) {
        gateOpenCondition.lock()
        lastGateOpen = nil
        gateOpenCondition.unlock()
        anchorShiftLock.lock()
        recutMark = RecutMark(index: index)
        anchorShiftLock.unlock()
    }

    /// A newer seek supersedes a re-cut whose restart never installed a producer (dropped with the
    /// coalescer's superseded slot, or failed), so a later unrelated restart at that index does not
    /// inherit the mark.
    private func dropUnstartedRecut() {
        anchorShiftLock.lock()
        if recutMark?.producerEpoch == nil { recutMark = nil }
        anchorShiftLock.unlock()
    }

    private func isInstalledProducer(_ epoch: UInt64) -> Bool {
        anchorShiftLock.lock()
        defer { anchorShiftLock.unlock() }
        return installedProducerEpoch == epoch
    }

    /// AE#412 pure decision: whether the segment a cold seek lands in has to be re-cut before the
    /// seek goes out.
    ///
    /// Three ways it does not. The segment carries a random-access point at or below the target, so
    /// it opens a run there itself. Or one sits close enough below the target that AVPlayer's fixed
    /// reach back picks it up out of an earlier segment, which is the case that lands exactly today.
    /// Anything else leaves the picture starting above the target, which is the defect.
    ///
    /// `coveringSyncDistance` is how far BELOW the target the nearest known random-access point sits;
    /// nil when none is known down there.
    static func needsRecut(
        landingReach: SegmentCache.VideoReach,
        offsetIntoSegment: Double,
        coveringSyncDistance: Double?
    ) -> Bool {
        if landingReach.serves(offsetSeconds: offsetIntoSegment) { return false }
        guard let coveringSyncDistance else { return true }
        return coveringSyncDistance > coldSeekLookbackSeconds
    }

    /// `segmentPlan[index].startSeconds` on the AVPlayer/playlist axis, taking `restartLock` itself.
    private func advertisedStartSeconds(_ index: Int) -> Double? {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard index >= 0, index < segmentPlan.count else { return nil }
        return segmentPlan[index].startSeconds
    }

    /// AE#412: the highest recorded random-access point at or below `itemSeconds`, walking down from
    /// `index` until one segment starts below AVPlayer's reach. nil when nothing down there carries
    /// one, and also when a walked segment made no claim: an unrecorded segment might well carry a
    /// sync sample, and re-cutting on a guess would cost a restart on a landing that works today.
    private func coveringSyncItemSeconds(
        atOrBelow itemSeconds: Double, from index: Int, provider: VideoSegmentProvider
    ) -> Double? {
        var best: Double?
        var j = index
        while j >= 0 {
            guard let advertised = advertisedStartSeconds(j) else { return best }
            guard let reach = provider.videoReach(at: j) else { return itemSeconds }
            if case .syncAt(let offset) = reach {
                let sync = advertised + offset
                if sync <= itemSeconds { best = max(best ?? sync, sync) }
            }
            if advertised <= itemSeconds - Self.coldSeekLookbackSeconds { return best }
            j -= 1
        }
        return best
    }

    /// Blocks until the epoch anchored at `index` has opened its video gate, and answers what it
    /// opened with. nil on timeout. Polls against the condition rather than nesting locks: the pump
    /// records under `anchorShiftLock` and signals under `gateOpenCondition`, and taking them in the
    /// other order here would be the classic inversion.
    private func awaitGateOpen(forIndex index: Int, timeout: TimeInterval) -> EpochAxis? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            gateOpenCondition.lock()
            if let open = lastGateOpen, open.index == index {
                gateOpenCondition.unlock()
                return open.axis
            }
            let signalled = gateOpenCondition.wait(until: deadline)
            gateOpenCondition.unlock()
            if !signalled, Date() >= deadline { return nil }
        }
    }

    /// Publishes an axis together with the displacement it is made of, so the two cannot drift apart:
    /// every axis this session states is `the run's normalization + displacement`, and the next
    /// composition works on the second term alone (PR #533 round 2).
    private func publishPlaylistShift(
        _ seconds: Double, seamItemSeconds: Double, offset: Double
    ) {
        anchorShiftLock.lock()
        placementOffsetSeconds = offset
        anchorShiftLock.unlock()
        publishPlaylistShift(seconds, seamItemSeconds: seamItemSeconds)
    }

    private func publishPlaylistShift(_ seconds: Double, seamItemSeconds: Double) {
        setPlaylistShiftSeconds(seconds)
        // Refresh every native subtitle store's shift so cuesInWindow stays on the correct AVPlayer
        // axis after a restart (matroska seek can land past the planned keyframe, #55). Snapshot under
        // restartLock: this runs on the pump thread and the array is reassigned by attach* on another
        // thread, so iterating the live array would race a CoW reassignment.
        restartLock.lock()
        let stores = nativeSubtitleCueStoresForSession
        restartLock.unlock()
        stores.forEach { $0.setShiftSeconds(seconds) }
        onPlaylistShiftChanged?(seconds, seamItemSeconds)
    }

    /// Live program-boundary rebase. Unlike `handleVideoShiftKnown`, does NOT fire `onPlaylistShiftChanged`:
    /// AVPlayer renders at ~buffer+holdback behind the producer edge, so the host must keep the OLD shift
    /// until playback crosses `seamOutputSeconds`. Internal `playlistShiftSeconds` tracks the edge immediately.
    /// #368: sequential chunk-seam rebases arrive here too, deliberately; same deferred-shift contract.
    func handleLiveTimelineRebase(_ shiftPts: Int64, seamOutputSeconds: Double, producerEpoch: UInt64) {
        guard isInstalledProducer(producerEpoch) else { return }
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

    /// AE#169 round 2: whether the installed producer's pump has exited. nil producer (mid-restart)
    /// reads as false; the coalescer's restartActivity covers that window.
    var currentProducerFinished: Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return producer?.didFinish ?? false
    }

    /// Total media-segment requests seen this session (#93 residual): the stall-triggered
    /// re-engage watchdog compares snapshots to detect a consumer that stopped requesting.
    var mediaFetchCountSnapshot: UInt64 {
        restartLock.lock()
        defer { restartLock.unlock() }
        return provider?.mediaFetchCount ?? 0
    }

    /// #405: segments the producer has finalized this session, the counterpart to
    /// `mediaFetchCountSnapshot`. One counts the consumer asking, this one counts the producer
    /// delivering, and the stall ladder needs both to tell a dead consumer from a starved origin.
    /// nil when there is no local producer at all (a remote HLS session AVPlayer fetches directly),
    /// which is a different situation from a producer that stopped: callers must not read the
    /// absence as zero progress. Monotonic: the live window slides by moving `firstVisible` and
    /// evicting cache, never by dropping entries from the segment list.
    var liveSegmentCountSnapshot: Int? {
        restartLock.lock()
        defer { restartLock.unlock() }
        return provider.map { $0.liveContinuationPoint().nextIndex }
    }

    /// AE#443: is the live pump held in its runaway headroom park?
    ///
    /// nil when there is no local producer, for the same reason as the count above: absence is not a
    /// "no". A parked pump finalizes nothing and drains no origin, so a ladder that reads only the
    /// finalized count sees a starved source and says so, which is what sent the reporter of #443 to
    /// his server logs three times.
    var liveProducerParkedSnapshot: Bool? {
        subsystemSnapshot().producer?.isLiveHeadroomParked
    }

    /// AE#446 round 2: this session's window is being served as a finished asset because its source
    /// stopped delivering while a viewer still had resident segments ahead. See
    /// `VideoSegmentProvider.liveOutageEndlist`.
    var liveOutageEndlistActive: Bool { provider?.liveOutageEndlistLatched ?? false }

    /// AE#446 round 2: the source has cut again since that happened.
    var liveOutageProductionResumed: Bool { provider?.liveOutageProductionResumed ?? false }

    /// AE#446 round 2: re-open the window as live for the next item. Call it immediately before the
    /// item swap that will fetch the playlist again, never while the current item could still poll.
    func clearLiveOutageEndlist() { provider?.clearLiveOutageEndlist() }

    /// AE#454: tell the item the next swap loads where to start, in its own playlist. Call immediately
    /// before the swap, so the first manifest that item fetches already carries the placement.
    /// See `VideoSegmentProvider.armLiveRejoinStart`.
    @discardableResult
    func armLiveRejoinStart(atOutputSeconds seconds: Double) -> (segmentIndex: Int, secondsIntoSegment: Double)? {
        provider?.armLiveRejoinStart(atOutputSeconds: seconds)
    }

    /// AE#454: the placement is spent once the item that asked for it is running.
    func clearLiveRejoinStart() { provider?.clearLiveRejoinStart() }

    /// See `VideoSegmentProvider.liveSegmentHeads(atOutputSeconds:)`.
    func liveSegmentHeads(atOutputSeconds seconds: Double)
        -> (index: Int, secondsIntoSegment: Double, pictureStart: Double, sound: (first: Double, last: Double)?)? {
        provider?.liveSegmentHeads(atOutputSeconds: seconds)
    }

    /// See `VideoSegmentProvider.servedLiveRejoinPlacement`.
    var servedLiveRejoinPlacement: (timeOffset: Double, playlistStartOutputSeconds: Double)? {
        provider?.servedLiveRejoinPlacement
    }

    /// AE#446 round 5: a fresh item is attaching, so the axis the last one came up on is spent.
    /// See `VideoSegmentProvider.armLiveItemAxisStatement`.
    func armLiveItemAxisStatement() { provider?.armLiveItemAxisStatement() }

    /// See `VideoSegmentProvider.servedLiveItemAxisOutputSeconds`.
    var servedLiveItemAxisOutputSeconds: Double? { provider?.servedLiveItemAxisOutputSeconds }

    /// #178: called by the engine when a NEW user seek is dispatched. A recovery re-anchor still
    /// holding the coalescer's authoritative slot belongs to the superseded seek; left in place it
    /// would drop the new seek's segment-driven restart and land the producer on the stale
    /// recovery position. Runs before the host seek so AVPlayer's new segment GETs never race a
    /// locked slot.
    func releaseSupersededAuthoritativeRestart() {
        restartLock.lock()
        restartCoalescer.clearSupersededAuthoritativePending()
        restartLock.unlock()
    }

    func requestRestart(at idx: Int, authoritative: Bool = false) {
        // A sequential origin has no restart. performRestart's demuxer seek has nowhere to land
        // on a non-seekable pb, and it ignores that failure: the new producer would keep reading
        // wherever the stream stands (or from byte 0 after a fresh reopen) and label those bytes
        // segment `idx`. That is the same fabricated-position content the declaration exists to
        // keep out, only silent instead of audible. Surface the loss; the host's re-request with
        // a shifted start timestamp is the recovery path.
        if sequentialOriginPinsProducerToZero {
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) refused: a sequential origin can only be "
                + "read from byte 0, so the reposition would mislabel content; surfacing source failure",
                category: .session
            )
            surfaceVODSourceFailure(FFmpegErr.eio, "Source cannot be repositioned")
            return
        }
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
        onSeekStateChanged?(false, nil) // run settled; hand the falling edge to the landing watch (#38)
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

    /// AE#141: whether the active producer's march can plausibly deliver the segment covering
    /// playlist time `seconds` without a re-anchor. The seek-deadline path asks this before
    /// preserving a "progressing" producer: progress toward a region the pending target is not
    /// in is not worth preserving (640 s target, march at ~316 s: 3x30 s serve timeouts ride to
    /// item death long before the march arrives). `true` with no provider (nothing to judge).
    func producerCoversPlaylistTime(_ seconds: Double) -> Bool {
        guard let prov = provider else { return true }
        return prov.activeMarchCovers(segmentIndexForPlaylistTime(seconds))
    }

    /// #93 restart latency: phase split for the "restart took" line, so a slow restart names the
    /// phase that ate the time (old-pump stop wait, wedged-reopen, demuxer seek, producer build).
    nonisolated static func restartPhaseSummary(
        stopWaitMs: Double, reopenMs: Double?, seekMs: Double, buildMs: Double
    ) -> String {
        var parts = ["stopWait=\(Int(stopWaitMs))ms"]
        if let reopenMs { parts.append("reopen=\(Int(reopenMs))ms") }
        parts.append("seek=\(Int(seekMs))ms")
        parts.append("build=\(Int(buildMs))ms")
        return parts.joined(separator: " ")
    }

    /// A new demuxer for the #79 / #169 reopen, registered for `stop()` before its blocking open, or
    /// nil when a stop already superseded the restart at `epoch`.
    func registerRestartReopenDemuxer(epoch: UInt64) -> Demuxer? {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard sessionEpoch == epoch else { return nil }
        let fresh = Demuxer()
        restartReopenDemuxer = fresh
        return fresh
    }

    private func unregisterRestartReopenDemuxer(_ dem: Demuxer) {
        restartLock.lock()
        if restartReopenDemuxer === dem { restartReopenDemuxer = nil }
        restartLock.unlock()
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
        // AE#169 round 2: consume the suspect-dead mark (the demuxer's last read threw); this
        // restart replaces it via the #79 fresh-demuxer path instead of seeking the failed
        // connection.
        let demuxerSuspectDead = mainDemuxerSuspectDead
        mainDemuxerSuspectDead = false
        restartLock.unlock()

        // AE#443: off `restartLock`, and before `old.stop()` releases the muxer its byte total is read
        // from.
        retireProducer(old)

        let restartStart = DispatchTime.now()
        func msSince(_ t: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        }
        var stopWaitMs: Double = 0
        var reopenMs: Double? = nil
        var seekMs: Double = 0

        // The new producer reuses this demuxer unless we have to replace a wedged (#79) or
        // suspect-dead (#169) one, below.
        var activeDem = dem
        var freshDemuxer: Demuxer?
        var oldPumpExited = true
        if let old {
            old.stop()
            oldPumpExited = old.waitForFinish(timeout: 5.0)
            stopWaitMs = msSince(restartStart)
        }
        if !oldPumpExited || demuxerSuspectDead {
            // #79: the old pump is wedged in a blocking network read on the SHARED demuxer; stop() can't
            // unblock a socket read, so waitForFinish timed out. Reusing this demuxer makes the new
            // producer's first post-seek read queue behind that stuck read for the full ~20s
            // connStallTimeout (the reporter's ~25s restart), after which the abandoned reader also steals
            // the first packet. markClosed() aborts the stuck read immediately (the existing thread-safe
            // unblock) but dooms the demuxer, so open a FRESH one and hand it to the new producer. Open
            // FIRST, abort only on success, so a reopen failure falls back to the prior abandon behaviour
            // (no regression) rather than poisoning the only demuxer. Scoped to the VOD single-demuxer
            // scrub case; the side-source / live-reopen paths keep their existing behaviour.
            // AE#169 round 2 takes the same path when the pump exited BECAUSE the demuxer's read
            // threw: the connection is known-bad, so the revive gets one fresh connection instead
            // of seeking the demuxer that just failed.
            if !isLiveSession, sideAudioDemuxer == nil, let fresh = registerRestartReopenDemuxer(epoch: epoch) {
                let reopenStart = DispatchTime.now()
                do {
                    // .restartReopen: bounded find_stream_info budget; the FULL playback budget was
                    // the bulk of a 44 s wedge-reopen over WAN (#93 residual). The pass itself must
                    // run so video_delay resolves, else B-frame dts arrive broken (#93 judder).
                    // A sequential origin keeps its declaration on the fresh open too: a ranged
                    // reopen would splice fabricated-position bytes into the new pump.
                    try fresh.open(
                        url: sourceURL, extraHeaders: sourceHTTPHeaders,
                        profile: restartReopenProfile,
                        isLive: false)
                    dem.markClosed() // abort any wedged read now that the replacement is ready
                    freshDemuxer = fresh
                    activeDem = fresh
                    EngineLog.emit(
                        "[HLSVideoEngine] restart at idx=\(idx): "
                        + (oldPumpExited
                            ? "#169 demuxer suspect-dead after read error; "
                            : "old producer wedged in a read past 5s; aborted it and ")
                        + "reopened a fresh demuxer",
                        category: .session
                    )
                } catch {
                    unregisterRestartReopenDemuxer(fresh)
                    fresh.close()
                    EngineLog.emit(
                        "[HLSVideoEngine] restart at idx=\(idx): "
                        + (oldPumpExited ? "#169 suspect-dead demuxer" : "old producer wedged")
                        + "; reopen failed (\(error)), reusing the demuxer",
                        category: .session
                    )
                }
                reopenMs = msSince(reopenStart)
            } else if !oldPumpExited {
                EngineLog.emit(
                    "[HLSVideoEngine] restart at idx=\(idx): old producer didn't exit within 5s, abandoning it "
                    + "(its in-flight read shares the demuxer and may consume the first post-seek packet; "
                    + "if the new session starts a GOP late, this is why)",
                    category: .session
                )
            }
        }

        // Seek to the exact video-stream plan timestamp with the target as the lower bound. A
        // global time seek can choose a much earlier sync point in a multi-stream MP4 (#191).
        // Seek outside restartLock (network-bound). Concurrent stop() calls markClosed() so the
        // seek fails fast instead of racing teardown.
        let seekStart = DispatchTime.now()
        // Disc plans use folded multi-clip timestamps that are not valid raw seek targets.
        if activeDem.isDiscSource || !activeDem.seek(to: targetStartPts, streamIndex: videoStreamIndex) {
            let absoluteTargetSeconds = Double(targetStartPts) * Double(videoTb.num) / Double(videoTb.den)
            activeDem.seek(to: absoluteTargetSeconds)
        }
        // Re-arm bridge PTS rebase so the encoder timeline starts from the new demuxer cursor.
        ab?.startSegment()
        seekMs = msSince(seekStart)

        // Re-validate: a stop() landing during waits bumped sessionEpoch; don't resurrect into a torn-down session.
        restartLock.lock()
        if let freshDemuxer, restartReopenDemuxer === freshDemuxer { restartReopenDemuxer = nil }
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
            retireDemuxer(dem)   // AE#443: nothing puts this one back, so the swap is already final
            // #433: the network axis belongs to the reader that is SERVING. The aborted one owned the
            // `.reconnecting` the host is still reading, and its pump can outlive this swap, so it is
            // unwired here rather than left able to speak for a session it no longer feeds. The incoming
            // reader takes the sink, and (new-listener rule in `NetworkPhaseGate`) announces its own first
            // delivery even though it already served this session's `find_stream_info` into a nil sink.
            dem.onNetworkPhaseChanged = nil
            freshDemuxer.onNetworkPhaseChanged = onNetworkPhaseChanged   // re-wire stall signal onto the reopened demuxer (#85)
            freshDemuxer.playIntentProvider = playIntentProvider   // and the pause bound its held connection is judged on (#377)
        }
        do {
            let newProd = try makeProducer(baseIndex: idx)
            producer = newProd
            anchorShiftLock.lock()
            recutMark = recutMark?.installing(producerEpoch: newProd.epoch, at: idx)
            anchorShiftLock.unlock()
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

        let elapsedMs = msSince(restartStart)
        let absoluteTargetSeconds = Double(targetStartPts) * Double(videoTb.num) / Double(videoTb.den)
        // #416: the outgoing pump's run ends where it got to and the new one begins here. Whatever
        // lies between the two was skipped, and a subtitle set stranded on the near side of that
        // gap can no longer be read as the line still on screen at the landing.
        subtitlePacketStore.noteHarvestAnchor(.pump, at: absoluteTargetSeconds)
        // build = everything after the seek (re-validation, muxer/producer construction, start).
        let buildMs = max(0, elapsedMs - stopWaitMs - (reopenMs ?? 0) - seekMs)
        EngineLog.emit(
            "[HLSVideoEngine] producer restarted at idx=\(idx) (seek=\(String(format: "%.2f", absoluteTargetSeconds))s [absolute source-PTS], restart took \(String(format: "%.0f", elapsedMs))ms; "
            + Self.restartPhaseSummary(stopWaitMs: stopWaitMs, reopenMs: reopenMs, seekMs: seekMs, buildMs: buildMs) + ")",
            category: .session
        )
    }

}

extension HLSVideoEngine {
    /// [MovieClaw P60] The colour of a stream the display would show with the BT.709 curve, nil for any
    /// other. The container's description, gaps filled from the SPS: `colr` outranks the VUI, so an HDR
    /// stream whose container never named the transfer must not be written out as sRGB. Declaring no
    /// transfer anywhere counts for HEVC once its SPS was read and for H.264 (no HDR in the wild); any
    /// other codec keeps its tags as they are.
    static func bt709CurveColor(_ codecpar: UnsafePointer<AVCodecParameters>) -> ColorDescription? {
        var declared = ColorDescription(codecpar: codecpar)
        if declared.transfer == AVCOL_TRC_UNSPECIFIED {
            switch codecpar.pointee.codec_id {
            case AV_CODEC_ID_HEVC:
                guard codecpar.pointee.extradata_size > 0,
                      let sps = ColorDescription.parameterSets(codecpar: codecpar) else { return nil }
                declared = ColorDescription.resolved(bitstream: sps, container: declared)
            case AV_CODEC_ID_H264:
                break
            default:
                return nil
            }
        }
        let tag = ColorAttachments.transfer(declared.transfer)
        guard tag == nil || tag == kCVImageBufferTransferFunction_ITU_R_709_2 else { return nil }
        return declared
    }
}
