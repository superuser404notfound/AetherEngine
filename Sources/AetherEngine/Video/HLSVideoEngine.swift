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

    /// AE#443: whoever REPLACES one of these two mid-session owes the session the totals the outgoing
    /// instance held (`retireDemuxer` / `retireProducer` below). They carry the session's byte and
    /// restart counters, and a fresh instance starts them at zero.
    var demuxer: Demuxer?
    var cache: SegmentCache?   // internal for the teardown-partial witness test
    var producer: HLSSegmentProducer?
    private var server: HLSLocalServer?
    var provider: VideoSegmentProvider?

    /// The 2026-09-02 field session retained 64 segments spanning more than four minutes. Cache
    /// mutations can arrive much faster than a host timeline needs to redraw, so fold them into at
    /// most four snapshots a second while preserving every final resident shape.
    private let residentRangesPublishLock = NSLock()
    private var residentRangesPublishTask: Task<Void, Never>?
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
        guard residentRangesPublishTask == nil else {
            residentRangesPublishLock.unlock()
            return
        }
        residentRangesPublishTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.publishResidentRanges()
        }
        residentRangesPublishLock.unlock()
    }

    private func publishResidentRanges() {
        residentRangesPublishLock.lock()
        residentRangesPublishPending = false
        let observer = residentRangesObserver
        residentRangesPublishLock.unlock()

        observer?(residentRanges())

        residentRangesPublishLock.lock()
        residentRangesPublishTask = nil
        let publishAgain = residentRangesPublishPending
        residentRangesPublishLock.unlock()
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
        guard let dem = demuxer, let stream = dem.stream(at: streamIndex) else { return nil }
        let w = savedVideoConfig.map { Int32($0.codecpar.pointee.width) } ?? 1920
        let h = savedVideoConfig.map { Int32($0.codecpar.pointee.height) } ?? 1080
        return EmbeddedSubtitleDecoder(stream: stream,
                                       sourceVideoWidth: w > 0 ? w : 1920,
                                       sourceVideoHeight: h > 0 ? h : 1080,
                                       preserveASSMarkup: preserveASSMarkupForSubtitleTap,
                                       teletextPage: teletextPageForSubtitleTap)
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
            guard let sidx, ordinal < nativeSubtitleCueStoresForSession.count,
                  let stream = dem.stream(at: sidx),
                  let decoder = EmbeddedSubtitleDecoder(stream: stream,
                                                        sourceVideoWidth: w > 0 ? w : 1920,
                                                        sourceVideoHeight: h > 0 ? h : 1080,
                                                        preserveASSMarkup: preserveASSMarkupForSubtitleTap,
                                                        teletextPage: teletextPageForSubtitleTap)
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

    /// AE#270: source PTS the container's timeline starts at, clamped at 0. The published playhead folds
    /// it out so it stays on the same 0-based axis as `duration`.
    public private(set) var sourceStartSeconds: Double = 0

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

    /// AE#418 round 2: what each stored segment adds to AVPlayer's axis when AVPlayer PLACES it.
    ///
    /// Only an epoch's FIRST segment can carry a non-zero offset: a gate that had to open below its
    /// boundary puts that much extra content into that one segment, and every segment the epoch cuts
    /// after it starts exactly on its boundary. Keyed by index rather than kept as one pair, because
    /// several epochs can leave such a segment in the cache at once; an epoch marching through an
    /// index rewrites it axis-true, which is what `recordingEpochAt` drops the entries above for.
    private let anchorShiftLock = NSLock()
    private var epochShiftByIndex: [Int: Double] = [:]
    /// AE#418 round 5: what each recorded epoch's gating sample is presented AFTER its own decode
    /// time. Kept beside the offsets rather than inside them so the same rewrite rule governs both,
    /// and read only when a placement composes onto a run that is already in AVPlayer's timeline.
    private var epochLeadByIndex: [Int: Double] = [:]
    /// AE#418 round 6: what one presentation lead is WORTH to a composition on THIS source, read out
    /// of a placement rather than assumed. Round 5 published `1` as a law from one fixture pair, and
    /// the reporter's content falsified its sign. Measured with the picture as witness on two clips
    /// identical but for their reorder depth, three runs each: a source whose gating sample is
    /// presented TWO frames after it is decoded lands a whole lead below its base, and one presented a
    /// SINGLE frame after it lands ON its base. nil until a placement carrying a lead has been read
    /// back, and a composition invents nothing before then.
    private var measuredLeadCoefficient: Double?
    /// AE#418 round 5: whether any placement has established a mapping in this item's timeline. The
    /// first one does not compose onto anything (AVPlayer anchors the item on its first PRESENTED
    /// sample, measured base 0.000 on every arm of the fixture), every later one does.
    private var hasComposedPlacement = false
    /// AE#418 round 3: the placement this session last published an axis for, so the prediction can be
    /// checked against where AVPlayer actually put those bytes.
    private var lastPublishedPlacement: PublishedPlacement?
    /// The last index a fetch declared. A cold fetch reaches the provider BEFORE the producer has
    /// opened its gate, so the placement can precede the offset it is worth; this is what lets the
    /// gate publish for a placement that already happened.
    private var lastPlacedIndex: Int = .min
    /// AE#412: the index the most recent gate open belongs to and what it was worth. Separate from
    /// `epochShiftByIndex`, which deliberately keeps no entry for a zero offset, so it cannot answer
    /// "has this epoch opened yet" at all. Signalled through `gateOpenCondition`.
    private var lastGateOpen: (index: Int, shift: Double)?
    private let gateOpenCondition = NSCondition()
    /// AE#412: indices whose epoch an AE#412 re-cut started. Such a segment goes into a timeline
    /// AVPlayer is already building, and it puts it at its own tfdt there (measured 3 of 3 with
    /// `play --picture-probe`: `axisErr` 0.000 at offsets of 1, 5 and 9 s), so its distance to its
    /// advertised start is not an axis offset and must not compose into one. Guarded by
    /// `anchorShiftLock`, alongside the table it keeps entries out of.
    private var recutIndices: Set<Int> = []
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
    /// Fires on live program-boundary rebase: `(newShiftSeconds, seamOutputSeconds)`. AetherEngine
    /// defers applying the shift until playback crosses `seamOutputSeconds` so the clock doesn't jump.
    var onPlaylistShiftRebased: (@Sendable (Double, Double) -> Void)?
    /// Fires on `PumpExitReason.sourceReplay`; host must re-negotiate a fresh session.
    var onLiveSourceReset: (@Sendable () -> Void)?
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
        provider?.abortSequentialStartupWait()
        onVODSourceFailed?(code, reason, kind)
    }
    /// Session-long FLAC bridge for codecs illegal in fMP4. Engine-owned (not producer-owned) so
    /// encoder state survives producer restarts; `startSegment()` rebases PTS on each restart.
    var audioBridge: AudioBridge?
    var segmentPlan: [Segment] = []

    /// AE#408: true only while `segmentPlan` is the keyframe-aligned plan, whose boundaries are
    /// container index entries and therefore CLAIM to be random-access points. The producer re-aims
    /// below a boundary that breaks that claim; it must not do so for the uniform grid (which never
    /// claimed it) or a source-declared plan (which aims below its IRAP by design, AE#268).
    var planBoundariesClaimRandomAccess = false

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

    /// Target segment duration (4 s). Apple spec recommends 6 s; 4 s cuts ~370 ms first-segment
    /// latency on a 24 fps 1440p LAN source and stays within the spec's 2-6 s range.
    static let targetSegmentDuration: Double = 4.0

    /// Live cut target under `LiveJoinProfile.fastZap` (AE#195): cut at every keyframe past 0.5 s, so
    /// segments quantize to the source GOP and the served TARGETDURATION (whose 3 x holdback gates the
    /// first live manifest, AE#189) is driven by `ceil(max EXTINF)` instead of the
    /// `ceil(1.5 x cut target)` floor (which collapses to 1 at this value).
    static let fastZapLiveCutTargetSeconds: Double = 0.5

    /// Resolve a host `LiveJoinProfile` to the live segment cut target.
    static func liveCutTargetSeconds(for profile: LiveJoinProfile) -> Double {
        switch profile {
        case .standard: return targetSegmentDuration
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
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioSourceStreamIndexOverride: Int32? = nil,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLiveSession: Bool = false,
        dvrWindowSeconds: Double? = nil,
        liveJoinProfile: LiveJoinProfile = .standard,
        liveCutTargetSeconds: Double? = nil,
        blockingReloadOverride: Bool? = nil,
        liveCadenceObservation: (@Sendable () -> Double?)? = nil,
        liveClosedCadenceObservation: (@Sendable () -> Double?)? = nil,
        liveUpstreamSegmentDurationObservation: (@Sendable () -> Double?)? = nil,
        upstreamSelfReportedTargetDuration: Double? = nil,
        preopenedDemuxer: Demuxer? = nil,
        sourceReopenableByURL: Bool = true,
        customSourceReopenFactory: CustomSourceReopenFactory? = nil,
        companionAudioReader: IOReader? = nil,
        probesize: Int64? = nil,
        maxAnalyzeDuration: Int64? = nil,
        sequentialOrigin: Bool = false,
        declaredDurationSeconds: Double? = nil,
        forwardBufferSegments: Int? = nil
    ) {
        self.sourceURL = url
        self.sourceHTTPHeaders = sourceHTTPHeaders
        self.sequentialOrigin = sequentialOrigin
        self.declaredDurationSeconds = declaredDurationSeconds
        // Caller-bounded find_stream_info budget (#68); nil keeps the .playback default. Applied only to the
        // fallback open / live reopen here; the happy path reuses the already-budgeted preopenedDemuxer.
        self.openProfile = DemuxerOpenProfile.playback.withProbeBudget(
            probesize: probesize, maxAnalyzeDuration: maxAnalyzeDuration)
            .withSequentialOrigin(sequentialOrigin, declaredDuration: declaredDurationSeconds)
        self.dvModeAvailable = dvModeAvailable
        self.displaySupportsHDR = displaySupportsHDR
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.forceDolbyVisionOnNonDVDisplay = forceDolbyVisionOnNonDVDisplay
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.audioSourceStreamIndexOverride = audioSourceStreamIndexOverride
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
                        servedSegmentDurationSeconds: liveUpstreamSegmentDurationObservation?()
                    )
                },
                selfReportedTargetDurationSeconds: upstreamSelfReportedTargetDuration
            )
        }
        self.preopenedDemuxer = preopenedDemuxer
        self.sourceReopenableByURL = sourceReopenableByURL
        self.customSourceReopenFactory = customSourceReopenFactory
        self.companionAudioReader = companionAudioReader
        self.forwardWindowSegments = Self.clampedForwardWindow(forwardBufferSegments)
    }

    /// Session forward-buffer window in segments. Drives BOTH the producer's race-ahead
    /// (`HLSSegmentProducer.bufferAheadSegments`) and the cache's forward window
    /// (`SegmentCache.forwardWindow`); the two MUST stay identical (a drift is exactly what stalls
    /// AVPlayer, see `SegmentCache`). From `LoadOptions.forwardBufferSegments`; nil -> historical 10.
    let forwardWindowSegments: Int

    /// Session retention budget resolved in `start()`; also bounds the producer's race-ahead on disk
    /// (#207, see `PrefetchDiskBudget`). Live resolves the same budget, so the DVR history the
    /// playlist advertises stays resident; the producer-side prefetch park it also feeds is
    /// VOD-only (`advanceMuxer`), so live cannot park on it.
    private var retentionBudgetBytes: Int = 0

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
    /// `PlaybackErrorKind.sourceRefused` instead of a wrapped "invalid data". Every other failure
    /// keeps the historical wrapped shape.
    static func openFailure(from error: Error) -> Error {
        if let readerError = error as? AVIOReaderError {
            switch readerError {
            case .hlsPlaylistOnVODPath, .hlsPlaylistOnRawLivePath, .httpStatus:
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
            sourceBitrate = dem.bitRate

            // #409: settle the composition-offset repair while the demuxer still stands at the head.
            // It reads a short sample and holds those packets, so nothing is consumed; doing it later
            // would sample wherever the prewarm left the source, and hand the producer a head that is
            // six seconds into the file. The segment plan below needs the verdict either way, because
            // a repaired stream and the container's own index have to describe one ladder.
            dem.decideCompositionOffsetRepair()

            // 2. Prewarm MKV Cues so libavformat's keyframe index is populated (1-2 byte-range reads).
            //    Bounded: a missing/out-of-bounds Cues index degrades into a multi-GB linear scan;
            //    abort past the deadline and fall back to the uniform-stride plan.
            //    #268: a segmented time-seekable source (HLS VOD ingest) has no index libavformat could
            //    load, and each reposition refetches a segment, so prewarming would buy the same
            //    uniform-stride plan for the price of two segment downloads at every session start.
            if dem.timeSeekableReader != nil {
                EngineLog.emit("[HLSVideoEngine] cue prewarm: skipped for a segmented source (no index to load, every reposition refetches a segment)")
            } else {
                let prewarmStart = DispatchTime.now()
                let prewarmOK = dem.seekBounded(to: durationSeconds * 0.5, timeout: Self.cuePrewarmTimeout)
                let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
                if prewarmOK {
                    EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", durationSeconds * 0.5))s took \(String(format: "%.1f", prewarmMs))ms")
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
                    stride = Self.targetSegmentDuration
                } else {
                    spacing = measureKeyframeSpacing(
                        demuxer: dem,
                        videoStreamIndex: videoIndex,
                        videoTimeBase: videoTimeBase,
                        fromSeconds: anchorSeconds
                    )
                    stride = Self.uniformStrideSeconds(spacing: spacing)
                }
                plan = Self.buildUniformSegmentPlan(
                    videoTimeBase: videoTimeBase,
                    sourceDurationSeconds: durationSeconds,
                    startPts0: anchorPts,
                    strideSeconds: stride
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
        let capRelaxed = Self.retentionCapRelaxed(forwardWindowSegments: forwardWindowSegments)
        let retentionBudget = Self.sessionRetentionBudgetBytes(volumeAvailableBytes: availableBytes,
                                                               capRelaxed: capRelaxed)
        self.retentionBudgetBytes = retentionBudget
        let segmentCache = SegmentCache(
            forwardWindow: forwardWindowSegments,
            retentionBudgetBytes: retentionBudget,
            onResidentSetChanged: { [weak self] in self?.noteResidentSetChanged() }
        )
        self.cache = segmentCache
        EngineLog.emit(
            "[HLSVideoEngine] segment retention budget: \(retentionBudget / (1 << 20)) MiB "
            + "(volumeAvailable=\(availableBytes.map { "\($0 / (1 << 20)) MiB" } ?? "unknown"), "
            + "forwardWindow=\(forwardWindowSegments) seg"
            + (capRelaxed ? ", opt-in prefetch: default cap relaxed" : "") + ")",
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
        let p5ColorOverride: MP4SegmentMuxer.ColorOverride?
        if dvVariant == .profile5 || doviConfig == .rewriteToProfile5 {
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
        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: UnsafePointer(ownedVideoParams.ptr),
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride,
            doviConfig: doviConfig,
            convertP7ToProfile81: convertP7ToProfile81,
            colorOverride: p5ColorOverride,
            extradataOverride: hevcExtradataOverride,
            nalFramingOverride: measuredVideoNALFraming
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
            audioHLSCodecs: &audioHLSCodecs,
            audioLanguage: audioLanguage
        )
        self.producer = prod
        self.activeAudioSourceStreamIndex = savedAudioConfig != nil ? audioStreamIndex : -1

        // 7. Wire provider, server, and URL.
        let manifestCodecs = audioHLSCodecs.map { "\(primaryCodecs),\($0)" } ?? primaryCodecs
        // AE#418: a segment AVPlayer places is what moves the axis it reads.
        var segmentPlacedHandler: (@Sendable (Int) -> Void)?
        if !isLiveSession {
            segmentPlacedHandler = { [weak self] idx in
                guard let self else { return }
                self.handleSegmentPlaced(at: idx)
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
            // AE#458: only when the audio actually reached the variant. A cascade that fell through to
            // video-only must not advertise an audio rendition that is not in the segments.
            audioLanguage: savedAudioConfig != nil ? audioLanguage : nil,
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
            segmentPlacedHandler: segmentPlacedHandler
        )
        self.provider = prov
        if isLiveSession {
            prod.onLiveSegmentFinalized = { [weak prov] index, durationSeconds, startPtsSeconds, discontinuous in
                prov?.appendLiveSegment(index: index,
                                        startSeconds: startPtsSeconds,
                                        durationSeconds: durationSeconds,
                                        discontinuous: discontinuous)
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
            videoCodecNeedsMasterSignaling: videoCodecNeedsMasterSignaling)
        let resolvedURL: URL? = useMasterPlaylist
            ? srv.playlistURL
            : srv.mediaPlaylistURL
        guard let url = resolvedURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        self.servingMasterPlaylist = useMasterPlaylist
        self.servedSourceIsHDR = videoRange != .sdr
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable) effectiveDvMode=\(effectiveDvMode) panelIsHDR=\(panelIsInHDRMode) displaySupportsHDR=\(displaySupportsHDR) matchContent=\(matchContentEnabled) sourceIsHDR=\(videoRange != .sdr || effectiveDvMode) useMaster=\(useMasterPlaylist) videoRange=\(videoRange) dvVariant=\(dvVariant))")
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
        videoCodecNeedsMasterSignaling: Bool = false
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
        if (hasNativeSubs || videoCodecNeedsMasterSignaling) && routingSafeForMaster { return true }
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
    func markServingMediaAfterFallback() { servingMasterPlaylist = false }

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

    /// Bytes this session pulled from the SOURCE, across every demuxer it has had (see
    /// `retiredDemuxerBytes`). Not the same link as `LiveTelemetry.networkTransferredBytes`, which on
    /// the native path counts what AVPlayer pulled from the loopback server.
    var demuxerBytesFetched: Int64 {
        (subsystemSnapshot().demuxer?.avioBytesFetched ?? 0) + retiredTotals().demuxerBytes
    }
    var segmentCacheTotalBytes: Int { subsystemSnapshot().cache?.totalBytes ?? 0 }
    /// On-disk segment bytes (freshly stat-ed). Used by `aetherctl live --report-cache-bytes`.
    var segmentCacheDiskBytes: Int64 { subsystemSnapshot().cache?.diskBytes() ?? 0 }

    /// Presentation-axis spans currently backed by the VOD segment cache. Live returns no claim:
    /// its DVR history is a different contract, expressed by `seekableLiveRange` at the engine layer.
    func residentRanges() -> [ClosedRange<Double>] {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard !isLiveSession, let cache, !segmentPlan.isEmpty else { return [] }
        return cache.residentIndexRanges().compactMap { indexes in
            guard indexes.lowerBound >= 0, indexes.upperBound < segmentPlan.count else { return nil }
            let lower = segmentPlan[indexes.lowerBound].startSeconds
            let upperIndex = indexes.upperBound + 1
            let upper = upperIndex < segmentPlan.count
                ? segmentPlan[upperIndex].startSeconds
                : segmentPlan[indexes.upperBound].startSeconds
                    + segmentPlan[indexes.upperBound].durationSeconds
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

    func scrubThumbnailSource(atSeconds seconds: Double) -> (data: Data, segmentIndex: Int)? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        guard let prov else { return nil }
        guard let seg = prov.thumbnailSegment(atSeconds: seconds) else { return nil }
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
        // #199: factory-vended ingest reader feeding the current demuxer; session-owned, closed here.
        let reopenReader = reopenCustomReader
        reopenCustomReader = nil
        segmentPlan = []
        restartLock.unlock()
        reopening?.markClosed()
        // Close before waitForFinish: cancels the reader's FIFO so a pump parked in a blocking
        // custom-IO read unblocks (mirrors markClosed for URL demuxers).
        reopenReader?.close()

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
            bufferAheadSegments: forwardWindowSegments,
            prefetchDiskBudgetBytes: retentionBudgetBytes,
            // AE#222: nil until a pump proved this source cuts its first segment before any audio packet
            // arrives; from then on every producer of the session muxes moov from this frame.
            audioMoovPrimeFrame: sessionAudioMoovPrimeFrame,
            // AE#366: once one producer has searched the whole source for an audio frame and come
            // back empty, later ones must not repeat the search per revive attempt.
            audioMoovPrimeKnownUnobtainable: sessionAudioMoovPrimeUnobtainable,
            epoch: nextProducerEpoch()
        )
        // #240: threaded onto every producer (initial + restart), like the wedge-detector providers
        // below. The side readers read one gate for the whole session, so a restart must not leave
        // a gap where nobody claims the link.
        prod.sideReaderLinkGate = sideReaderLinkGate
        prod.onFirstHDR10PlusDetected = { [weak self] in
            self?.notifyHDR10PlusOnce()
        }
        prod.onVideoShiftKnown = { [weak self] shiftPts, firstItemTfdtPts, presentationLeadPts in
            self?.handleVideoShiftKnown(
                shiftPts, firstItemTfdtPts: firstItemTfdtPts, presentationLeadPts: presentationLeadPts)
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
    /// Live muxerFailed in-place rebuilds, bounded by progress like the reopen cycles above: new segments
    /// since the last death reset the budget (an hours-long channel legitimately crosses several encoder
    /// restarts, so a session-lifetime gate like the VOD #99 one would be wrong here); consecutive barren
    /// deaths exhaust it and the session halts + delegates to host retune.
    var liveMuxerRebuildCycles = 0
    var lastMuxerRebuildSegmentCount = -1
    static let maxLiveMuxerRebuildCycles = 3

    private func handleVideoShiftKnown(_ shiftPts: Int64, firstItemTfdtPts: Int64, presentationLeadPts: Int64) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        let seamItemSeconds = Double(firstItemTfdtPts) * sourceVideoTbSeconds
        let leadSeconds = Double(presentationLeadPts) * sourceVideoTbSeconds
        // Live rebases the whole timeline at a program boundary and nothing older comes back on
        // screen, so its axis is the epoch's own and it publishes here as it always has.
        guard !isLiveSession else {
            publishPlaylistShift(seconds, seamItemSeconds: seamItemSeconds)
            return
        }
        // AE#418 round 2: on VOD the axis moves when AVPlayer PLACES this segment, not when the
        // producer writes it. Record what the segment is worth and let the placement publish it; an
        // epoch AVPlayer never fetches from must not move the clock at all.
        let index = segmentIndexForPlaylistTime(seamItemSeconds)
        anchorShiftLock.lock()
        // AE#412: a re-cut opens below its boundary on purpose, and AVPlayer places what it produces
        // at its own tfdt, so the epoch is worth nothing to the axis. Recording zero still drops the
        // entries at and above it, which is what the rewrite calls for.
        let isRecut = recutIndices.remove(index) != nil
        epochShiftByIndex = Self.epochShiftTable(
            epochShiftByIndex, recordingEpochAt: index, shift: isRecut ? 0 : seconds)
        // A re-cut is placed at its own tfdt inside a timeline AVPlayer is already building (AE#412,
        // measured `axisErr` 0.000 at three offsets), so it composes nothing and carries no lead.
        epochLeadByIndex = Self.epochShiftTable(
            epochLeadByIndex, recordingEpochAt: index, shift: isRecut ? 0 : leadSeconds)
        let placementAlreadyHappened = lastPlacedIndex == index
        anchorShiftLock.unlock()
        gateOpenCondition.lock()
        lastGateOpen = (index: index, shift: seconds)
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
        let epochShift = epochShiftByIndex[index]
        // AE#418 round 5: the lead of the epoch being PLACED, and only once this item's timeline
        // already holds a placement to compose onto.
        let lead = hasComposedPlacement ? (epochLeadByIndex[index] ?? 0) : 0
        let learnedCoefficient = measuredLeadCoefficient
        let coefficient = learnedCoefficient ?? 0
        anchorShiftLock.unlock()
        guard let epochShift else { return }
        restartLock.lock()
        let plannedStart = index >= 0 && index < segmentPlan.count
            ? segmentPlan[index].startSeconds : nil
        restartLock.unlock()
        guard let plannedStart else { return }
        let current = playlistShiftSeconds
        // The base this placement lands on is the axis in force LESS the epoch's presentation lead,
        // which is where AVPlayer puts a segment it composes into a timeline it already has.
        let base = Self.placementBase(
            axis: current, presentationLead: lead, coefficient: coefficient)
        let composed = Self.axisShift(
            after: current, placing: epochShift, presentationLead: lead, coefficient: coefficient)
        let seam = Self.seamItemSeconds(advertisedStart: plannedStart, currentShift: base)
        // AE#418 round 3: keep what this composition assumed, so the placement can be checked against
        // AVPlayer's own account of where it put the bytes.
        anchorShiftLock.lock()
        let superseded = lastPublishedPlacement
        lastPublishedPlacement = PublishedPlacement(
            index: index, advertisedStart: plannedStart, worth: epochShift, assumedBase: base,
            axisInForce: current, presentationLead: lead)
        hasComposedPlacement = true
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
            + "worth \(String(format: "%.3f", epochShift))s, lead \(String(format: "%.3f", lead))s "
            + "x\(String(format: "%.2f", coefficient))\(learnedCoefficient == nil ? " unmeasured" : "")"
            + "): axis shift "
            + "\(String(format: "%.3f", current))s -> \(String(format: "%.3f", composed))s "
            + "from item \(String(format: "%.3f", seam))s",
            category: .session
        )
        publishPlaylistShift(composed, seamItemSeconds: seam)
    }

    /// AE#418 round 2: the axis after AVPlayer places a segment worth `epochShift`. It composes,
    /// because AVPlayer puts the placed segment's advertised start where its CURRENT mapping says
    /// that position is, not where the playlist says it is.
    ///
    /// AE#418 round 5: and it composes onto a BASE, which can sit below the axis by the epoch's
    /// presentation lead. Round 6: by HOW MUCH is a property of the source, not a constant, so it is
    /// measured. Three clips identical but for their reorder depth, same arm, three runs each, the
    /// picture agreeing with the reading in every one:
    ///
    /// | gating sample presented | base a composition lands on | coefficient |
    /// | --- | --- | --- |
    /// | at its decode time (no reordering) | the axis | 0 |
    /// | one frame after it (`-bf 1`) | the axis | 0 |
    /// | two frames after it (`-bf 3`, pyramid) | one lead below the axis | 1 |
    ///
    /// Round 5 shipped the third row as the rule for all of them, which put a 1-frame-reorder source
    /// two frames out on every composition (the reporter's asset is one, at 23.976 fps). The
    /// coefficient now comes from the reading that checks it. See
    /// [[reference_an_offset_about_presentation_is_measured_at_the_pts]].
    static func axisShift(
        after currentShift: Double, placing epochShift: Double, presentationLead: Double,
        coefficient: Double
    ) -> Double {
        return placementBase(
            axis: currentShift, presentationLead: presentationLead, coefficient: coefficient
        ) + epochShift
    }

    /// The base a placement lands on: the axis in force, less as much of its gating sample's
    /// presentation lead as this source has been MEASURED to place below it. This is the value the
    /// reading takes back out of AVPlayer's buffer, so the coefficient is checkable against it on
    /// every placement that opens a run of its own.
    static func placementBase(axis: Double, presentationLead: Double, coefficient: Double) -> Double {
        return axis - coefficient * presentationLead
    }

    /// AE#418 round 6: what the reading says one lead was worth, or nil when this placement carried
    /// no lead to learn from.
    ///
    /// Round 5 measured `1` on a fixture with a two-frame reorder depth and shipped it for every
    /// source. On the same arm, on a clip identical but for `-bf 1`, AVPlayer places the composition
    /// on the axis itself and the picture agrees: `0`. Both are geometries of the content, so the
    /// session reads this one off its own placements instead of carrying either as a law.
    static func leadCoefficient(
        axis: Double, measuredBase: Double, presentationLead: Double
    ) -> Double? {
        guard presentationLead > leadCoefficientMinimumLeadSeconds else { return nil }
        let raw = (axis - measuredBase) / presentationLead
        guard raw.isFinite else { return nil }
        return min(max(raw, -maxLeadCoefficient), maxLeadCoefficient)
    }

    /// Below one millisecond a lead divides into noise, and the coefficient it produces describes the
    /// reading's own resolution rather than the placement.
    static let leadCoefficientMinimumLeadSeconds = 0.001

    /// A reading can be wrong once (round 4 accepts that on purpose), so what it teaches the NEXT
    /// composition is bounded by the geometry any reorder depth could produce. Two leads is already
    /// past every case measured.
    static let maxLeadCoefficient = 2.0

    /// Worth saying out loud only when it moves: a coefficient restated every placement is noise, and
    /// one that changes is the source contradicting what the session learned from it.
    static let leadCoefficientReportEpsilon = 0.05

    /// The item position the placed segment's content begins at: its advertised start, read through
    /// the axis that was in effect before it landed. Everything below that is still the old epoch's.
    static func seamItemSeconds(advertisedStart: Double, currentShift: Double) -> Double {
        return advertisedStart - currentShift
    }

    /// Record what the epoch beginning at `index` is worth, dropping every entry at or above it: a
    /// producer that starts writing there rewrites those segments on their own boundaries, so an
    /// older epoch's offset must stop being claimed for them.
    ///
    /// AE#448: an epoch worth NOTHING is recorded too, and that is not bookkeeping. Its bytes still
    /// carry the axis in force when AVPlayer places them, and they still take over the stretch from
    /// their own placement upward. Dropping the entry left that stretch to whatever seam sat below it,
    /// which after a backward seek is an older epoch's, so the clock folded a shift the picture there
    /// no longer had.
    static func epochShiftTable(
        _ table: [Int: Double], recordingEpochAt index: Int, shift: Double
    ) -> [Int: Double] {
        var next = table.filter { $0.key < index }
        next[index] = shift
        return next
    }

    /// AVPlayer discards a sub-second axis offset at a seek and snaps back to the playlist; a larger
    /// one it keeps. Measured on the fixture: `-0.500` and `-0.875` read `axisErr=0.000` after a seek,
    /// `-1.000`, `-1.083`, `-1.292`, `-1.500`, `-3.000`, `-4.000`, `-7.000`, `-9.000` and `-11.000`
    /// all survive one unchanged. Anything below this is worth less than the frame it would move.
    static let axisSnapsBelowSeconds = 1.0

    static func axisShiftAfterSeek(_ shift: Double) -> Double {
        return abs(shift) < axisSnapsBelowSeconds ? 0 : shift
    }

    /// AE#418 round 2: the host seeked and the axis was small enough for AVPlayer to throw away.
    /// Publishing zero from the landing forward is what keeps the clock over the picture; the seam
    /// leaves everything below the landing on the axis its bytes were placed with.
    func snapAxisAfterSeek(landingItemSeconds: Double) {
        guard !isLiveSession else { return }
        let current = playlistShiftSeconds
        let snapped = Self.axisShiftAfterSeek(current)
        guard snapped != current else { return }
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
        publishPlaylistShift(snapped, seamItemSeconds: landingItemSeconds)
    }

    /// AE#418 round 3: one placement, kept so the composition that was published for it can be checked
    /// against AVPlayer's own account of where those bytes landed.
    struct PublishedPlacement: Sendable {
        let index: Int
        /// The segment's start in the playlist, which is the position AVPlayer reads through its axis.
        let advertisedStart: Double
        /// What the segment carries below that start. Negative for a gate that opened early.
        let worth: Double
        /// The axis the composition assumed AVPlayer's timeline was carrying when it placed this.
        let assumedBase: Double
        /// The axis in force when it was composed. With the lead below, this is what turns a reading
        /// into the coefficient the next composition uses.
        let axisInForce: Double
        /// What this epoch's gating sample is presented after its own decode time.
        let presentationLead: Double
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

    /// Two starts this close are the same run being reported twice, not two placements. A segment is
    /// seconds long, so nothing real lands inside this.
    static let runIdentityEpsilonSeconds = 0.025

    /// AE#418 round 4: the run AVPlayer opened for this placement, or nil when it opened none.
    ///
    /// `baseline` is what the item held when the placement was recorded, which is before AVPlayer can
    /// have taken the bytes. Two things separate a run opened since from the run that was already
    /// there, and both are needed:
    ///
    /// - A start the baseline already reported is that run, still holding the playhead. Its own start
    ///   describes an OLDER placement, and reading it was what round 3 called a confirmation.
    /// - A start BELOW a baseline range it overlaps is that same run moved, because AVPlayer backfills
    ///   below a run after it opens. Measured by the reporter on two devices: a run that opened at
    ///   1522.6 read 1507.1 fifteen seconds later, against a baseline range starting at 1510.6. A run
    ///   AVPlayer opened for this placement starts where it placed those bytes and does not walk.
    ///
    /// So a downward move is never read, which costs the measurement on a backward reopen inside the
    /// buffer (the composed axis stands there, as it did before any of this). An upward move cannot be
    /// backfill, and that is the case this needs: measured on the fixture, a seek that re-places the
    /// overlong segment opens `[61.000-81.969]` against a baseline of `[52.000-68.952]`.
    static func freshRunStart(
        ranges: [(Double, Double)], baseline: [(Double, Double)], itemClock: Double
    ) -> Double? {
        guard let start = placementRangeStart(ranges: ranges, itemClock: itemClock),
              let holding = ranges.first(where: { $0.0 == start && itemClock <= $0.1 })
        else { return nil }
        if baseline.contains(where: { abs($0.0 - start) <= runIdentityEpsilonSeconds }) { return nil }
        if baseline.contains(where: { $0.0 <= holding.1 && holding.0 <= $0.1 && start < $0.0 }) { return nil }
        return start
    }

    /// The loaded range holding `itemClock`, which is the run AVPlayer is presenting. Its start is where
    /// that run was placed. Ranges that end below the clock are older runs, ranges above it are not on
    /// screen yet, and neither says anything about the picture.
    static func placementRangeStart(ranges: [(Double, Double)], itemClock: Double) -> Double? {
        let holding = ranges.filter { $0.0.isFinite && $0.1.isFinite && itemClock >= $0.0 && itemClock <= $0.1 }
        return holding.max(by: { $0.0 < $1.0 })?.0
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
    func reconcileAxisWithObservedPlacement(observedItemStart: Double, itemClock: Double) {
        guard !isLiveSession else { return }
        anchorShiftLock.lock()
        let placement = lastPublishedPlacement
        // One placement is measured once. Publishing below re-enters this through the shift hook, and
        // the run this reading came from is by then part of the next baseline anyway.
        lastPublishedPlacement = nil
        anchorShiftLock.unlock()
        guard let placement,
              let reading = Self.placementReading(
                advertisedStart: placement.advertisedStart, worth: placement.worth,
                assumedBase: placement.assumedBase, observedItemStart: observedItemStart)
        else { return }
        learnLeadCoefficient(from: placement, measuredBase: reading.base)
        guard abs(reading.residual) > Self.axisRepublishEpsilonSeconds else {
            // Said out loud, because a check that only speaks when it disagrees cannot be told from one
            // that never ran. This is the line that says the axis is measured on this session.
            EngineLog.emit(
                "[HLSVideoEngine] #418 seg\(placement.index) placement confirmed: AVPlayer holds it "
                + "from item \(String(format: "%.3f", observedItemStart))s, base "
                + "\(String(format: "%.3f", reading.base))s as published",
                category: .session
            )
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] #418 seg\(placement.index) placed on base \(String(format: "%.3f", reading.base))s, "
            + "not \(String(format: "%.3f", placement.assumedBase))s (AVPlayer holds it from item "
            + "\(String(format: "%.3f", observedItemStart))s, clock \(String(format: "%.3f", itemClock))s, "
            + "residual \(String(format: "%+.3f", reading.residual))s): axis "
            + "\(String(format: "%.3f", placement.assumedBase + placement.worth))s -> "
            + "\(String(format: "%.3f", reading.axis))s",
            category: .session
        )
        publishPlaylistShift(reading.axis, seamItemSeconds: reading.seam)
    }

    /// AE#418 round 6: a placement that opened a run of its own says what a presentation lead is
    /// worth on this source, which is the one thing about the composition this side had been
    /// assuming. Learned from every reading, the confirmations included: a confirmation is the
    /// coefficient in force being right, and saying so is what keeps it from drifting unchallenged.
    private func learnLeadCoefficient(from placement: PublishedPlacement, measuredBase: Double) {
        guard let coefficient = Self.leadCoefficient(
            axis: placement.axisInForce, measuredBase: measuredBase,
            presentationLead: placement.presentationLead)
        else { return }
        anchorShiftLock.lock()
        let previous = measuredLeadCoefficient
        measuredLeadCoefficient = coefficient
        anchorShiftLock.unlock()
        guard previous == nil
            || abs(coefficient - (previous ?? 0)) > Self.leadCoefficientReportEpsilon else { return }
        EngineLog.emit(
            "[HLSVideoEngine] #418 seg\(placement.index) says a lead counts "
            + "\(String(format: "%.2f", coefficient))x on this source"
            + (previous.map { ", was \(String(format: "%.2f", $0))x" } ?? "")
            + " (axis \(String(format: "%.3f", placement.axisInForce))s, base measured "
            + "\(String(format: "%.3f", measuredBase))s, lead "
            + "\(String(format: "%.3f", placement.presentationLead))s)",
            category: .session
        )
    }

    /// AE#418 round 4: the window closed without AVPlayer opening a run for this placement, so nothing
    /// about it is readable and the composed axis is all this session has. Named rather than left
    /// silent: the reporter had placements that produced no verdict at all, and a missing line reads
    /// like a check that did not run.
    func reportPlacementUnreadable() {
        anchorShiftLock.lock()
        let placement = lastPublishedPlacement
        lastPublishedPlacement = nil
        anchorShiftLock.unlock()
        guard let placement else { return }
        EngineLog.emit(
            "[HLSVideoEngine] #418 seg\(placement.index) opened no run of its own to measure; keeping "
            + "the composed axis \(String(format: "%.3f", placement.assumedBase + placement.worth))s",
            category: .session
        )
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
        gateOpenCondition.lock()
        lastGateOpen = nil
        gateOpenCondition.unlock()
        anchorShiftLock.lock()
        recutIndices.insert(index)
        anchorShiftLock.unlock()
        requestRestart(at: index, authoritative: true)
        guard let shift = awaitGateOpen(forIndex: index, timeout: Self.recutGateWaitSeconds) else {
            anchorShiftLock.lock()
            recutIndices.remove(index)
            anchorShiftLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] #412 seg\(index) re-cut did not open a gate within "
                + "\(String(format: "%.1f", Self.recutGateWaitSeconds))s; seeking on the uncorrected position",
                category: .session
            )
            return itemSeconds
        }
        EngineLog.emit(
            "[HLSVideoEngine] #412 seg\(index) re-cut opened \(String(format: "%.3f", shift))s below its "
            + "boundary and now covers item \(String(format: "%.3f", itemSeconds))s",
            category: .session
        )
        return itemSeconds
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
    /// opened worth. nil on timeout. Polls against the condition rather than nesting locks: the pump
    /// records under `anchorShiftLock` and signals under `gateOpenCondition`, and taking them in the
    /// other order here would be the classic inversion.
    private func awaitGateOpen(forIndex index: Int, timeout: TimeInterval) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            gateOpenCondition.lock()
            if let open = lastGateOpen, open.index == index {
                gateOpenCondition.unlock()
                return open.shift
            }
            let signalled = gateOpenCondition.wait(until: deadline)
            gateOpenCondition.unlock()
            if !signalled, Date() >= deadline { return nil }
        }
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

    /// See `VideoSegmentProvider.servedLiveRejoinPlacement`.
    var servedLiveRejoinPlacement: (timeOffset: Double, playlistStartOutputSeconds: Double)? {
        provider?.servedLiveRejoinPlacement
    }

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
            if !isLiveSession, sideAudioDemuxer == nil {
                let reopenStart = DispatchTime.now()
                let fresh = Demuxer()
                do {
                    // .restartReopen: bounded find_stream_info budget; the FULL playback budget was
                    // the bulk of a 44 s wedge-reopen over WAN (#93 residual). The pass itself must
                    // run so video_delay resolves, else B-frame dts arrive broken (#93 judder).
                    // A sequential origin keeps its declaration on the fresh open too: a ranged
                    // reopen would splice fabricated-position bytes into the new pump.
                    try fresh.open(
                        url: sourceURL, extraHeaders: sourceHTTPHeaders,
                        profile: DemuxerOpenProfile.restartReopen
                            .withSequentialOrigin(sequentialOrigin, declaredDuration: declaredDurationSeconds),
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
