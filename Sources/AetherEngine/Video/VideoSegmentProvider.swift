import Foundation

// MARK: - Native subtitle rendition metadata

/// Per-rendition master-playlist metadata (#15): NAME must be unique within the subtitle group
/// (HLS requirement; duplicates make AVFoundation collapse same-language renditions into one
/// legible option), FORCED carries the container disposition into EXT-X-MEDIA. Built once at load
/// by `AetherEngine.nativeSubtitleRenditionInfos(for:)`.
struct NativeSubtitleRenditionInfo: Sendable, Equatable {
    let language: String?
    let name: String
    let isForced: Bool
}

// MARK: - Live window sizing

/// Single source of truth for sliding live window size. Playlist firstVisible and cache evictBelow
/// both read this so they can never drift (drift = playlist lists a segment the cache deleted, or vice versa).
/// effectiveWindowSeconds = dvrWindowSeconds ?? liveOnlyFloorSeconds;
/// windowSegmentCount = max(minSafeSegments, ceil(effective / targetSegmentDurationSeconds)).
struct LiveWindowSizing {
    /// Live-only floor: 60 s so disk and playlist stay finite even without DVR seek.
    static let liveOnlyFloorSeconds: Double = 60
    /// 8 segments: comfortably wider than AVPlayer's ~5-7 segment live-edge prefetch at 4 s segments.
    /// Smaller windows caused the 81 s spike stall (AVPlayer fell below MEDIA-SEQUENCE).
    static let minSafeSegments = 8

    let targetSegmentDurationSeconds: Double
    let dvrWindowSeconds: Double?

    /// Number of segments the playlist keeps visible (and the cache keeps
    /// resident). Clamped up to `minSafeSegments`.
    var windowSegmentCount: Int {
        let effective = dvrWindowSeconds ?? Self.liveOnlyFloorSeconds
        let raw = Int(ceil(effective / max(0.5, targetSegmentDurationSeconds)))
        return max(Self.minSafeSegments, raw)
    }
}

// MARK: - Live-edge holdback policy

/// Couples the served `#EXT-X-TARGETDURATION` / `HOLD-BACK` to the startup cushion so they can never
/// drift. AVPlayer's default live-edge holdback (absent an explicit `HOLD-BACK`) is `3 x TARGETDURATION`:
/// it wants to play that far behind the live edge. When the served window holds LESS than that behind the
/// edge, AVPlayer restarts inside its own stall-danger zone and spams
/// `-16832 restarting Ns from end of live playlist; target duration Ts - stall danger`, rebuffering until
/// the window naturally deepens (AE#189: long-GOP HEVC-in-TS, 5.76s segments -> TD=6 -> 18s holdback, but
/// the fixed 2-segment cushion only built ~9.6s). Both the served playlist
/// (`HLSLocalServer.buildMediaPlaylistText`) and the startup gate (`waitForFirstLiveSegment`) derive
/// TARGETDURATION here, so the depth the cushion builds to is exactly the depth AVPlayer enforces.
enum LiveEdgePolicy {
    /// Never serve an empty or single-segment live playlist (a 1-segment window is an instant -12888).
    static let minStartupSegments = 2

    /// Served `#EXT-X-TARGETDURATION`, in whole seconds: `>= ceil(max EXTINF)` (HLS requirement), floored
    /// by `ceil(1.5 x cut target)` (widens AVPlayer's unchanged-playlist patience, anti -12888) and the
    /// observed-cadence floor. `cutTargetSeconds` / `cadenceFloorSeconds` are nil for VOD/EVENT.
    static func targetDurationSeconds(maxSegmentDuration: Double,
                                      cutTargetSeconds: Double?,
                                      cadenceFloorSeconds: Double?) -> Int {
        var td = Int(ceil(max(1.0, maxSegmentDuration)))
        if let cut = cutTargetSeconds { td = max(td, Int(ceil(cut * 1.5))) }
        if let floor = cadenceFloorSeconds { td = max(td, Int(ceil(floor))) }
        return td
    }

    /// AVPlayer's default (and our explicitly advertised) live-edge holdback: `3 x TARGETDURATION`, the
    /// RFC 8216bis floor for `EXT-X-SERVER-CONTROL:HOLD-BACK`.
    static func holdBackSeconds(targetDuration: Int) -> Double { Double(3 * targetDuration) }

    /// First-serve gate: hold the first live manifest until the window carries at least the live-edge
    /// holdback (`3 x TD`) of content behind the edge, so AVPlayer's initial seek-to-edge-minus-holdback
    /// lands inside the window instead of the stall-danger zone. Bounded above by `windowSegmentCount`: a
    /// tiny-segment source can never be made to wait for more than the sliding window will ever hold (the
    /// wall-clock deadline in `waitForFirstLiveSegment` is the outer bound). A source that arrives with a
    /// backlog (Jellyfin transcode, or an upstream live window pulled at I/O speed) satisfies this almost
    /// immediately; only a strict-realtime origin pays the deepen-the-buffer latency, which is inherent to
    /// joining long-GOP live safely.
    static func startupCushionSatisfied(segmentCount: Int,
                                        summedDurationSeconds: Double,
                                        maxSegmentDuration: Double,
                                        cutTargetSeconds: Double?,
                                        cadenceFloorSeconds: Double?,
                                        windowSegmentCount: Int) -> Bool {
        guard segmentCount >= minStartupSegments else { return false }
        if segmentCount >= windowSegmentCount { return true }
        let td = targetDurationSeconds(maxSegmentDuration: maxSegmentDuration,
                                       cutTargetSeconds: cutTargetSeconds,
                                       cadenceFloorSeconds: cadenceFloorSeconds)
        return summedDurationSeconds >= holdBackSeconds(targetDuration: td)
    }
}

// MARK: - Cache-backed provider

/// Thin HLSSegmentProvider over SegmentCache. Cache misses block the HTTP server's connection
/// thread on a per-index condvar (backpressure model). Scrub policy: in-cache = fast path;
/// forward seek within forwardWaitWindow of cache.max = wait; anything else fires restartHandler.
final class VideoSegmentProvider: HLSSegmentProvider, @unchecked Sendable {

    private let cache: SegmentCache
    /// Immutable for VOD; grows under stateLock for live (producer appends via appendLiveSegment).
    private var segments: [HLSVideoEngine.Segment]
    private let isLive: Bool
    /// Drives both playlist firstVisible and cache eviction cutoff so they never drift.
    private let liveWindowSizing: LiveWindowSizing
    /// Host override for blocking-reload (`LoadOptions.liveBlockingReload`): nil = auto (observed policy for
    /// ingest, on by default for signal-less live), true/false = force. Wins over the policy (#167).
    private let blockingReloadOverride: Bool?
    /// Observed-cadence policy for live ingest sources; drives blocking-reload eligibility and the
    /// TARGETDURATION floor from real arrival cadence. nil for URL live (no cadence signal) and VOD (#167).
    private let liveCadencePolicy: LiveCadencePolicy?

    private let codecsString: String
    private let supplementalCodecsString: String?
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange
    private let frameRate: Double?
    private let hdcpLevel: String?
    private let sourceBitrate: Int64

    /// #15: native subtitle cue stores (one per text track) for the WebVTT rendition served to AVPlayer.
    /// Immutable references; each store is internally locked and filled lazily by the readers on selection.
    private let nativeSubStores: [NativeSubtitleCueStore]
    private let nativeSubLanguages: [String?]
    private let nativeSubRenditionInfos: [NativeSubtitleRenditionInfo]
    /// Ordinal advertised as DEFAULT=YES in the master SUBTITLES group (Sodalite#32).
    let nativeSubtitleDefaultOrdinal: Int
    /// Serve the SUBTITLES rendition as ONE whole-program .vtt (single VOD segment spanning the full duration)
    /// instead of one .vtt per video segment. The only AVPlayer-reliable sideload shape (Sodalite#32); requires
    /// eager readers (all cues available up front) and a bounded program (VOD).
    let nativeSubtitleWholeProgram: Bool
    /// Current engine playlist shift (AVPlayer clock = source_pts - shift), read at serve time so whole-program
    /// cues land on the same AVPlayer axis as the video even when the shift was not known at load (Sodalite#32).
    private let currentShiftSeconds: @Sendable () -> Double
    /// Sodalite#32 Phase 2: tap-fed stores can carry raw ASS event lines (the overlay renders the
    /// styling); the WebVTT rendition must serve plain text, so strip at build time.
    private let stripASSMarkupInVTT: Bool

    /// Synchronous teardown + relaunch at the given absolute segment index.
    private let restartHandler: ((Int) -> Void)?
    /// True while the engine's restart coalescer has an in-flight run (#93 residual): waiting
    /// fetches ride it instead of burning fixed retry budgets, and never re-fire at stale indices.
    private let restartActivity: (() -> Bool)?
    /// Base index of the active producer (#93 residual): a fetch for an index within the
    /// producer's forward march window waits for the march instead of tearing it down.
    private let activeProducerBase: (() -> Int?)?
    /// AE#169 round 2: whether the installed producer's pump has EXITED (any reason). A finished
    /// pump can never march, so a forward-window fetch must restart instead of backpressure-waiting
    /// on a front that is provably frozen. nil/false during a coalesced restart (no producer
    /// installed) keeps the normal wait+ride paths.
    private let producerFinished: (() -> Bool)?

    /// AE#169 round 2: single-slot record of the last forward-window fetch that burned its FULL
    /// backpressure wait. Same index + unmoved march front on the next fetch is proof the march is
    /// not coming (the wait would re-arm forever against a dead producer); a moved front overwrites
    /// the record and keeps the patience. Guarded by stateLock.
    private var _forwardMissIndex: Int = .min
    private var _forwardMissFront: Int = .min

    /// Base index of the engine's current producer. Guards against stale-producer waits:
    /// abs(index - lastRestartIndex) <= 2 = cold start, wait; larger = restart needed.
    /// Guarded by stateLock (concurrent workQueue can double-trigger on stale value).
    private var lastRestartIndex: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastRestartIndex }
        set { stateLock.lock(); _lastRestartIndex = newValue; stateLock.unlock() }
    }
    private var _lastRestartIndex: Int = 0

    /// 8 absorbs AVPlayer's 5-7 segment speculative prefetch at 4 s segments (~32 s headroom)
    /// while keeping user-initiated 30+ s scrubs below the threshold. Tightened to 3 once;
    /// every AVPlayer prefetch above cache.max+3 cascaded into restarts and produced cache holes.
    private static let forwardWaitWindow = 8

    /// #50: re-asserting reposition wait. Sliced waits re-fire restart only when lastRestartIndex
    /// changed (orphan signature: #35 coalescer's single slot was overwritten by a newer scrub).
    /// Slice is generous enough to absorb a cold 4K-HDR first-GOP decode. Instance lets so the
    /// wait shape is testable without 8 s sleeps (#93 residual).
    private let repositionWaitSlice: TimeInterval
    /// A cache index range can be sparse after scrubbing. Wait only when the active producer can
    /// actually fill an interior hole; otherwise restart immediately instead of burning this slice.
    private let sparseHoleWaitSlice: TimeInterval
    private static let repositionMaxWaits = 3
    /// Hard cap on riding an in-flight restart (#93 residual): a fetch waits past the fixed
    /// budget while a restart is genuinely executing, but never indefinitely.
    private let repositionRideCapSeconds: TimeInterval
    /// Blocking wait for a forward request the active producer is about to write (test-injectable;
    /// production stays at 30 s, matching AVPlayer's serve patience before it retries).
    private let forwardBackpressureWaitSeconds: TimeInterval
    /// #93 round 3: a VOD serve still running at this age signals `onSlow` so the server can emit
    /// an early chunked header, keeping time-to-first-byte under AVPlayer's ~3.5 s -12889 window.
    private let slowServeThresholdSeconds: TimeInterval

    // MARK: - Playlist state

    private let stateLock = NSLock()
    /// Separate from stateLock so the manifest handler can block without holding the segment-list lock.
    private let firstSegmentCondition = NSCondition()
    /// Set by cancelWaiters() on stop(). Without it, parked LL-HLS blocking-reload threads sleep
    /// their full timeout (18-30 s) and can write stale playlists into a recycled fd of the next session.
    private var waitersCancelled = false
    /// Terminal latch (#167 follow-up): the live pump exited for host retune (SSAI cutter wedge,
    /// source replay, custom-reader death), so no further segment will ever be cut into this provider.
    /// The cadence policy cannot see this (it observes ingest arrivals, which keep flowing while the
    /// cutter is wedged), so it is a separate, producer-level condition.
    private var _liveProductionHalted = false
    private var refreshCounter: Int = 0
    /// EXT-X-MEDIA-SEQUENCE first index; monotonically advancing, stays 0 for VOD.
    private var _liveFirstVisible: Int = 0
    /// EXT-X-DISCONTINUITY-SEQUENCE: incremented for each discontinuous segment that slides out.
    private var _discontinuitySequence: Int = 0

    init(
        cache: SegmentCache,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        supplementalCodecs: String?,
        resolution: (Int, Int),
        videoRange: HLSVideoRange,
        frameRate: Double?,
        hdcpLevel: String?,
        sourceBitrate: Int64,
        isLive: Bool = false,
        liveWindowSizing: LiveWindowSizing = LiveWindowSizing(targetSegmentDurationSeconds: 4.0, dvrWindowSeconds: nil),
        blockingReloadOverride: Bool? = nil,
        liveCadencePolicy: LiveCadencePolicy? = nil,
        restartHandler: ((Int) -> Void)? = nil,
        restartActivity: (() -> Bool)? = nil,
        activeProducerBase: (() -> Int?)? = nil,
        producerFinished: (() -> Bool)? = nil,
        initialRestartIndex: Int = 0,
        repositionWaitSlice: TimeInterval = 8.0,
        sparseHoleWaitSlice: TimeInterval = 2.0,
        repositionRideCapSeconds: TimeInterval = 90.0,
        forwardBackpressureWaitSeconds: TimeInterval = 30.0,
        slowServeThresholdSeconds: TimeInterval = 2.0,
        nativeSubtitleStores: [NativeSubtitleCueStore] = [],
        nativeSubtitleLanguages: [String?] = [],
        nativeSubtitleRenditionInfos: [NativeSubtitleRenditionInfo] = [],
        stripASSMarkupInVTT: Bool = false,
        nativeSubtitleDefaultOrdinal: Int = 0,
        nativeSubtitleWholeProgram: Bool = false,
        currentShiftSeconds: @escaping @Sendable () -> Double = { 0 }
    ) {
        self.cache = cache
        self.segments = segments
        self.isLive = isLive
        self.liveWindowSizing = liveWindowSizing
        self.blockingReloadOverride = blockingReloadOverride
        self.liveCadencePolicy = liveCadencePolicy
        self.codecsString = codecsString
        self.supplementalCodecsString = supplementalCodecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.hdcpLevel = hdcpLevel
        self.sourceBitrate = sourceBitrate
        self.restartHandler = restartHandler
        self.restartActivity = restartActivity
        self.activeProducerBase = activeProducerBase
        self.producerFinished = producerFinished
        self._lastRestartIndex = initialRestartIndex
        self.repositionWaitSlice = repositionWaitSlice
        self.sparseHoleWaitSlice = sparseHoleWaitSlice
        self.repositionRideCapSeconds = repositionRideCapSeconds
        self.forwardBackpressureWaitSeconds = forwardBackpressureWaitSeconds
        self.slowServeThresholdSeconds = slowServeThresholdSeconds
        self.nativeSubStores = nativeSubtitleStores
        self.nativeSubLanguages = nativeSubtitleLanguages
        self.nativeSubRenditionInfos = nativeSubtitleRenditionInfos
        self.stripASSMarkupInVTT = stripASSMarkupInVTT
        self.nativeSubtitleDefaultOrdinal = nativeSubtitleDefaultOrdinal
        self.nativeSubtitleWholeProgram = nativeSubtitleWholeProgram
        self.currentShiftSeconds = currentShiftSeconds
    }

    /// Append a finalized live segment. Index must equal segments.count; out-of-order ignored.
    func appendLiveSegment(index: Int, startSeconds: Double, durationSeconds: Double,
                           discontinuous: Bool = false) {
        stateLock.lock()
        guard index == segments.count else {
            stateLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] live segment append out of order: got index=\(index), "
                + "expected \(segments.count); ignoring",
                category: .session
            )
            return
        }
        // source TB not reachable here; DVR restart machinery will supply correct values when wired
        let startPts: Int64 = 0
        let endPts: Int64 = 0
        segments.append(HLSVideoEngine.Segment(
            startPts: startPts,
            endPts: endPts,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            discontinuous: discontinuous
        ))
        stateLock.unlock()
        firstSegmentCondition.lock()
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Called on each playlist build. For live: advances firstVisible to max(0, highWater - window),
    /// evicts cache below it, and increments _discontinuitySequence for each dropped discontinuous segment.
    /// VOD: returns full count so AVPlayer sees a complete asset (EVENT experiment that reported
    /// visibleHighWater+1 made AVPlayer think the asset was 2:13 and stop there).
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        refreshCounter += 1
        if isLive {
            let total = segments.count
            let window = liveWindowSizing.windowSegmentCount
            // highWater is the last produced index (total - 1). Keep the
            // last `window` segments visible: firstVisible = highWater -
            // window + 1 = total - window. Until at least `window`
            // segments exist, do not advance past 0 so AVPlayer's first
            // read sees all produced segments and can establish a live
            // edge without losing a not-yet-buffered position.
            let newFirst = max(0, total - window)
            if newFirst > _liveFirstVisible {
                // RFC 8216 §6.2.2: EXT-X-DISCONTINUITY-SEQUENCE must increment for each
                // discontinuity-tagged segment that slides out; segments array is never pruned.
                for i in _liveFirstVisible..<newFirst where segments[i].discontinuous {
                    _discontinuitySequence += 1
                }
                _liveFirstVisible = newFirst
                let cutoff = newFirst
                let cacheRef = cache
                DispatchQueue.global(qos: .utility).async {
                    cacheRef.evictBelow(cutoff)
                }
            }
            return (total, _liveFirstVisible, refreshCounter, false, _discontinuitySequence)
        }
        return (segments.count, 0, refreshCounter, false, 0)
    }

    var firstVisibleSegmentIndex: Int {
        guard isLive else { return 0 }
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveFirstVisible
    }

    // MARK: - Thumbnail lookup (engine-internal)

    /// Pure lookup for the segment whose [startSeconds, startSeconds+duration) window
    /// contains `seconds`. No clamp past the end (unlike segmentIndex(forPlaylistTime:)):
    /// a scrub past the produced range must miss, not pin to the last segment. Exposed
    /// static for unit tests. lastIndex mirrors the live lookup (picks the most recent
    /// match across a discontinuity; identical to firstIndex for contiguous VOD segments).
    static func thumbnailSegmentIndex(atSeconds seconds: Double,
                                      segments: [HLSVideoEngine.Segment]) -> Int? {
        segments.lastIndex(where: {
            $0.startSeconds <= seconds && seconds < $0.startSeconds + $0.durationSeconds
        })
    }

    /// Pure lookup for a scrub thumbnail: no side effects, no restarts; nil outside the
    /// resident window or on a cache miss. Works for live and VOD (VOD `segments` carry
    /// `startSeconds` from init); callers gate on session type one layer up.
    func thumbnailSegment(atSeconds seconds: Double) -> (index: Int, startSeconds: Double, fileURL: URL)? {
        stateLock.lock()
        let segs = segments
        stateLock.unlock()
        guard let idx = Self.thumbnailSegmentIndex(atSeconds: seconds, segments: segs) else { return nil }
        guard let url = cache.peekURL(index: idx) else { return nil }
        return (idx, segs[idx].startSeconds, url)
    }

    /// Non-blocking init.mp4 peek; the 30s blocking initSegment() is only for the HTTP server path.
    func peekInitSegment() -> Data? {
        cache.fetchInit(timeout: 0)
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        return cache.fetchInit(timeout: 30.0)
    }

    func initVersionID(forSegment index: Int) -> Int {
        cache.initVersionID(forSegment: index)
    }

    func initSegment(versionID: Int) -> Data? {
        if versionID == 0 { return cache.fetchInit(timeout: 30.0) }  // version 0 may not be ready yet at startup
        return cache.initData(versionID: versionID)
    }

    /// File URL for sendfile(2) fast path. Drives same side effects as mediaSegment(at:);
    /// without handleTargetChange the sendfile path would skip producer restarts on out-of-range fetches.
    func mediaSegmentURL(at index: Int) -> URL? {
        guard index >= 0, index < currentSegmentCount else { return nil }
        handleTargetChange(to: index)
        return cache.peekURL(index: index)
    }

    /// Total media-segment requests seen (both serve paths). The #65 consumer re-engage watchdog
    /// reads this after a wedge re-anchor: an unchanged count means AVPlayer stopped requesting
    /// entirely and needs a host-side nudge (#93 residual).
    var mediaFetchCount: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _mediaFetchCount
    }
    private var _mediaFetchCount: UInt64 = 0

    /// Shared by mediaSegment(at:) and mediaSegmentURL(at:). Without sharing, back-scrubs served
    /// via sendfile (cache hits) skip the proactive restart entirely, leaving seg-11+ to fall into
    /// a reactive prune-gap restart with AVPlayer's buffer at its thinnest.
    private func handleTargetChange(to index: Int) {
        stateLock.lock()
        _mediaFetchCount += 1
        stateLock.unlock()
        let previousTarget = cache.targetIndex
        cache.declareTarget(index)

        if previousTarget >= 0, index < previousTarget - 2, let restart = restartHandler {
            // Cache gate: backwardWindow=20 covers Continuous-Audio handover refetches (~7-10 segments
            // backward); unconditional proactive restart re-armed the FLAC bridge and caused audible glitches.
            if cache.peekURL(index: index) != nil {
                EngineLog.emit(
                    "[HLSVideoEngine] declareTarget backward jump \(previousTarget) -> \(index): resident in cache, no restart",
                    category: .session
                )
                return
            }
            EngineLog.emit(
                "[HLSVideoEngine] declareTarget backward jump \(previousTarget) → \(index), proactively restarting producer",
                category: .session
            )
            lastRestartIndex = index
            restart(index)
            cache.resetHighWaterForRestart()
        }
    }

    func mediaSegment(at index: Int) -> Data? {
        mediaSegment(at: index, onSlow: nil)
    }

    /// #93 round 3: VOD serves arm a one-shot slow signal so the server can emit an early chunked
    /// header once the serve outlives the threshold (a restart-window segment can take 25-50 s;
    /// AVPlayer -12889s at ~3.5 s of silence and three strikes kill the item). Live keeps its own
    /// contracts (below-window fast 404, LL-HLS blocking reload) and never signals.
    func mediaSegment(at index: Int, onSlow: (@Sendable () -> Void)?) -> Data? {
        guard let onSlow, !isLive else { return serveSegment(at: index) }
        let signal = SlowServeSignal(thresholdSeconds: slowServeThresholdSeconds, onSlow: onSlow)
        defer { signal.complete() }
        return serveSegment(at: index)
    }

    private func serveSegment(at index: Int) -> Data? {
        guard index >= 0, index < currentSegmentCount else { return nil }

        // Segment below the live window is evicted; returning nil = fast 404 so AVPlayer resyncs.
        // Without this, the 30 s cache.fetch parks the connection for a segment that will never reappear.
        if isLive {
            stateLock.lock()
            let firstVisible = _liveFirstVisible
            stateLock.unlock()
            if index < firstVisible {
                EngineLog.emit(
                    "[HLSVideoEngine] seg\(index): below live window (firstVisible=\(firstVisible)), fast 404",
                    category: .session
                )
                return nil
            }
        }

        let totalStart = DispatchTime.now()

        handleTargetChange(to: index)

        // Fast path: serve from cache.
        if let hit = cache.peek(index: index) {
            return logServed(index: index, bytes: hit, totalStart: totalStart, restarted: false)
        }

        // staleBelowProducer: indexRange() can still report stale lower bounds from a previous producer
        // (cold-start probe wrote seg-0/1 before resume restart at baseIndex=N); tolerance of 2 matches
        // the empty-cache cold-start heuristic.
        //
        // producerPassedAndPruned: highWater alone is not enough -- during normal forward-march the producer
        // races ahead while segments are still resident (repro: cache=0..24 highWater=24, request seg15 ->
        // needless restart). Only treat as a pruned gap when index falls OUTSIDE [r.0, r.1].
        // Concrete pruned-gap repro: 110-seg episode, jumped 8->12, back-scrubbed to 0, played 0..10 from cache,
        // seg-11..24 pruned; requested seg-11, waited 30 s, 404 because producer was past seg-24.
        let range = cache.indexRange()
        let highWater = cache.highestStoredIndex
        let staleBelowProducer = index < lastRestartIndex - 2
        let producerPassedAndPruned: Bool
        if highWater > index, let r = range {
            producerPassedAndPruned = index < r.0 || index > r.1
        } else {
            producerPassedAndPruned = highWater > index
        }
        let needsRestart: Bool
        // AE#169 round 2: set when the forward-wait branch has PROOF the active march is never
        // arriving (pump finished, or a full backpressure wait elapsed with zero front progress
        // for this same index). Bypasses the restart loop's producerCovers veto below, which
        // otherwise reads the dead producer's still-installed base and suppresses the fire.
        var marchProvenDead = false
        // AE#169 round 2: true when the fetch takes the VOD forward-window backpressure wait, so a
        // full-timeout miss records (index, front) for the frozen-march escalation above.
        var tookForwardWait = false
        if staleBelowProducer || producerPassedAndPruned {
            needsRestart = true
        } else if let r = range {
            if index < r.0 {
                needsRestart = true
            } else if index > r.1 + Self.forwardWaitWindow {
                needsRestart = true
            } else if index >= r.0 && index <= r.1 {
                // min...max is not proof of residency: retained scrub bands leave interior holes.
                // Only wait when the active producer can actually march into this index.
                if activeProducerCovers(index),
                   let waited = cache.fetch(index: index, timeout: sparseHoleWaitSlice) {
                    return logServed(
                        index: index, bytes: waited, totalStart: totalStart, restarted: false)
                }
                needsRestart = true
            } else {
                // r.1 < index <= r.1 + forwardWaitWindow: only backpressure-wait when the ACTIVE
                // producer's march front is actually near. The resident max alone is not that
                // signal: retained scrub bands (#93 budget) from a dead producer can sit far above
                // the active march (AE#141: band 150-158 from a 600 s scrub, producer re-anchored
                // at 75; the request for seg159 parked 3x30 s into -1017 item death while the
                // march was ~2 minutes away). highWater is reset per provider-fired restart, so
                // max(highWater, lastRestartIndex) tracks the active producer's front.
                //
                // AE#169 round 2: index distance alone is still not proof the march will ARRIVE.
                // A producer that died mid-session (source read error at the tail) freezes the
                // front just below the request, and the 30 s wait re-armed forever (seg719 miss
                // x11 into -12889). A finished pump, or a full wait already burned with zero
                // front progress for this same index, escalates to restart instead. VOD only:
                // live has its own pump watchdogs and reopen machinery.
                let front = activeMarchFront
                tookForwardWait = !isLive
                if !isLive {
                    stateLock.lock()
                    let missIndex = _forwardMissIndex
                    let missFront = _forwardMissFront
                    stateLock.unlock()
                    marchProvenDead = Self.forwardWaitMarchDead(
                        index: index, marchFront: front,
                        producerFinished: producerFinished?() ?? false,
                        lastMissIndex: missIndex, lastMissFront: missFront)
                    if marchProvenDead {
                        EngineLog.emit(
                            "[HLSVideoEngine] seg\(index): #169 forward-wait march dead "
                            + "(front=\(front) "
                            + (producerFinished?() ?? false
                                ? "producer finished" : "frozen across a full wait")
                            + "); escalating to restart",
                            category: .session
                        )
                    }
                }
                needsRestart = index > front + Self.forwardWaitWindow || marchProvenDead
            }
        } else {
            // Empty cache: cold start (producer at lastRestartIndex, hasn't written yet) vs. big scrub
            // (producer far from index, won't backfill). index > 2 heuristic missed the repro where
            // producer was at idx 1314 and AVPlayer requested seg-0 after a back-scrub (30 s timeout).
            needsRestart = abs(index - lastRestartIndex) > 2
        }

        if needsRestart, let restart = restartHandler {
            // #50: re-fire restart per slice only when lastRestartIndex changed (orphan: #35 coalescer
            // slot overwritten by newer scrub; producer settles elsewhere; plain 30 s wait 404s).
            // #93 residual: while a restart is in flight, the fetch RIDES it (slices don't consume
            // the fixed budget, bounded by repositionRideCapSeconds) and never fires its own,
            // possibly stale, index into the coalescer's pending slot. The fixed budget applies
            // only while no restart is executing.
            let rideDeadline = DispatchTime.now() + repositionRideCapSeconds
            var attempt = 0
            var firedThisCall = false
            while attempt < Self.repositionMaxWaits {
                if restartActivity?() == true {
                    if DispatchTime.now() > rideDeadline {
                        break
                    }
                } else {
                    // #93 residual: a fetch whose index was JUST restarted to (lastRestartIndex ==
                    // index) waits for the producer to deliver instead of re-firing; each AVPlayer
                    // re-request otherwise tore down the fresh producer mid-capture (device: three
                    // back-to-back restarts at the same index, one dropped frame each). The #50
                    // same-index orphan (producer settled elsewhere) is covered by one backstop
                    // re-fire on the final attempt. An index the ACTIVE producer demonstrably
                    // covers (base <= index <= base + forward window) never fires OR backstops:
                    // the march will deliver it, and the backstop killed a 75%-complete capture
                    // on device while a forward-march neighbor got its healthy producer restarted.
                    // AE#169 round 2: a march proven dead (finished pump / frozen front across a
                    // full wait) must not veto the fire; the still-installed dead producer's base
                    // covering the index is exactly the wedge being escaped.
                    let producerCovers = !marchProvenDead && activeProducerCovers(index)
                    // A request superseded by a NEWER declared target is an orphan of a skip
                    // storm: AVPlayer's newest request is what it actually wants (the same
                    // newest-wins semantics the coalescer applies to immediate restarts).
                    // Firing the orphan's index tears down the producer serving the REAL
                    // playhead (device: a stale seg262 fire evicted the settled base-252
                    // producer, restarts ping-ponged between stale and playhead indices,
                    // every capture was discarded and the playhead segment took 19.8 s).
                    // Orphans wait out their slices and 503; AVPlayer has abandoned them.
                    let isLatestTarget = cache.targetIndex == index
                    let orphanBackstop = attempt == Self.repositionMaxWaits - 1
                        && !firedThisCall && !producerCovers && isLatestTarget
                    if isLatestTarget
                        && ((lastRestartIndex != index && !producerCovers) || orphanBackstop) {
                        EngineLog.emit(
                            "[HLSVideoEngine] seg\(index): out-of-range fetch (cache.range=\(range.map { "\($0.0)..\($0.1)" } ?? "empty") highWater=\(highWater) attempt=\(attempt + 1)/\(Self.repositionMaxWaits)), restarting producer",
                            category: .session
                        )
                        lastRestartIndex = index
                        clearForwardWaitMiss()
                        restart(index)
                        // Reset highWater AFTER restart() returns (synchronous: old producer has exited).
                        // Pre-restart reset would be clobbered by the old producer's final write re-bumping
                        // highWater, re-arming producerPassedAndPruned and cascading into per-segment restarts.
                        cache.resetHighWaterForRestart()
                        firedThisCall = true
                    }
                    attempt += 1
                }
                if let bytes = cache.fetch(index: index, timeout: repositionWaitSlice) {
                    return logServed(index: index, bytes: bytes, totalStart: totalStart, restarted: true)
                }
            }
            return logServed(index: index, bytes: nil, totalStart: totalStart, restarted: true)
        }

        let bytes = cache.fetch(index: index, timeout: forwardBackpressureWaitSeconds)
        if tookForwardWait, !needsRestart {
            if bytes == nil {
                // Record the front as of the END of the burned wait: progress DURING the wait
                // resets the comparison base, so only a truly frozen march escalates next time.
                recordForwardWaitMiss(index: index, front: activeMarchFront)
            } else {
                clearForwardWaitMiss()
            }
        }
        return logServed(index: index, bytes: bytes, totalStart: totalStart, restarted: needsRestart)
    }

    /// AE#169 round 2 pure decision: whether the forward-window backpressure wait may still trust
    /// the active march to deliver `index`. A FINISHED pump can never march. A recorded full-wait
    /// miss for the same index with an unmoved front means the wait already failed empirically and
    /// re-arming it would park forever (rrgomes: seg719 miss x11 into -12889). Everything else
    /// keeps the wait: slow sources legitimately take most of the patience window for one segment.
    static func forwardWaitMarchDead(index: Int, marchFront: Int, producerFinished: Bool,
                                     lastMissIndex: Int, lastMissFront: Int) -> Bool {
        if producerFinished { return true }
        return lastMissIndex == index && lastMissFront == marchFront
    }

    private func recordForwardWaitMiss(index: Int, front: Int) {
        stateLock.lock()
        _forwardMissIndex = index
        _forwardMissFront = front
        stateLock.unlock()
    }

    private func clearForwardWaitMiss() {
        stateLock.lock()
        _forwardMissIndex = .min
        _forwardMissFront = .min
        stateLock.unlock()
    }

    private func logServed(index: Int, bytes: Data?, totalStart: DispatchTime, restarted: Bool) -> Data? {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - totalStart.uptimeNanoseconds) / 1_000_000
        if let bytes = bytes {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): served \(bytes.count) B (wait=\(String(format: "%.1f", elapsedMs))ms cache=\(cache.count) restarted=\(restarted))",
                category: .session
            )
        } else {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): cache miss after \(String(format: "%.0f", elapsedMs))ms (cache=\(cache.count) restarted=\(restarted))",
                category: .session
            )
        }
        return bytes
    }

    private func activeProducerCovers(_ index: Int) -> Bool {
        guard let base = activeProducerBase?() else { return false }
        return base <= index && index - base <= Self.forwardWaitWindow
    }

    /// The active producer's write front: the highest index written since its restart (highWater
    /// is reset per provider-fired restart) or its restart anchor before the first write (AE#141).
    private var activeMarchFront: Int {
        max(cache.highestStoredIndex, lastRestartIndex)
    }

    /// AE#141: whether the active producer's march can plausibly deliver `index` without a
    /// re-anchor — at or behind its anchor-to-front span, or within the forward-wait window
    /// ahead of the front. The engine's seek-deadline backstop asks this before preserving a
    /// "progressing" producer whose march would never reach the pending seek target.
    func activeMarchCovers(_ index: Int) -> Bool {
        index >= lastRestartIndex && index <= activeMarchFront + Self.forwardWaitWindow
    }

    private var currentSegmentCount: Int {
        guard isLive else { return segments.count }
        stateLock.lock()
        defer { stateLock.unlock() }
        return segments.count
    }

    var segmentCount: Int { currentSegmentCount }

    func segmentDuration(at index: Int) -> Double {
        if isLive {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard index >= 0, index < segments.count else { return 0 }
            return segments[index].durationSeconds
        }
        guard index >= 0, index < segments.count else { return 0 }
        return segments[index].durationSeconds
    }

    /// #95 audio tap: index of the segment containing playlist-axis time `t` (cumulative EXTINF).
    /// Clamps below 0 and past the end.
    static func segmentIndex(forPlaylistTime t: Double, durations: [Double]) -> Int {
        guard !durations.isEmpty, t > 0 else { return 0 }
        var acc = 0.0
        for (i, d) in durations.enumerated() {
            acc += d
            if t < acc { return i }
        }
        return durations.count - 1
    }

    func segmentIndex(forPlaylistTime t: Double) -> Int {
        if isLive {
            stateLock.lock()
            defer { stateLock.unlock() }
            return Self.segmentIndex(forPlaylistTime: t, durations: segments.map { $0.durationSeconds })
        }
        return Self.segmentIndex(forPlaylistTime: t, durations: segments.map { $0.durationSeconds })
    }

    func segmentIsDiscontinuous(at index: Int) -> Bool {
        if isLive {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard index >= 0, index < segments.count else { return false }
            return segments[index].discontinuous
        }
        guard index >= 0, index < segments.count else { return false }
        return segments[index].discontinuous
    }

    /// EVENT was tried (halved RSS growth 3.0->1.3 MB/s but did not bound it; AVPlayer retains ~93%
    /// regardless of playlist type); side effects: Control Center showed "LIVE" (asset.duration NaN),
    /// replay-from-beginning landed ~2 min in. .live is the only spec-correct shape for a sliding window
    /// (EVENT forbids segment removal; VOD stops playback). VOD stays .vod.
    var playlistType: HLSPlaylistType { isLive ? .live : .vod }
    /// Stable TARGETDURATION from the first manifest; avoids -12888 startup race for high-bitrate live.
    var liveTargetSegmentDuration: Double? {
        isLive ? liveWindowSizing.targetSegmentDurationSeconds : nil
    }
    var liveBlockingReloadEnabled: Bool {
        Self.resolveLiveBlockingReload(halted: liveProductionHalted,
                                       override: blockingReloadOverride,
                                       policy: liveCadencePolicy)
    }

    var liveProductionHalted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveProductionHalted
    }

    /// Live pump exited for host retune: no further segment will ever be cut into this provider.
    /// Latch blocking-reload off for every subsequent manifest render (including an item reload
    /// against this server) and release parked ?_HLS_msn= waiters so they 503 now instead of
    /// sleeping out their full hold against a dead producer (-15410, #167 follow-up).
    func markLiveProductionHalted() {
        stateLock.lock()
        _liveProductionHalted = true
        stateLock.unlock()
        cancelWaiters()
    }
    var liveTargetDurationFloorSeconds: Double? {
        // The floor tracks observed cadence regardless of the gate override: patience must cover the real
        // inter-batch gap even when a host forces blocking-reload on/off (#167).
        isLive ? liveCadencePolicy?.targetDurationFloorSeconds : nil
    }

    /// Resolve blocking-reload eligibility: a halted producer disables it unconditionally (no override
    /// can conjure segments from a dead pump, #167 follow-up); otherwise a host override wins; otherwise
    /// the observed-cadence policy decides for ingest sources; signal-less live (plain-url Jellyfin
    /// transcode) keeps the low-latency default. Pure so the precedence is unit-testable without a full
    /// provider (#167).
    static func resolveLiveBlockingReload(halted: Bool = false, override: Bool?, policy: LiveCadencePolicy?) -> Bool {
        if halted { return false }
        if let override { return override }
        if let policy { return policy.blockingReloadEnabled }
        return true
    }
    /// Under stateLock: (count, summed EXTINF, max EXTINF) over the resident segments. At startup the
    /// window has not slid yet, so this is the full first-served window (LiveEdgePolicy sizes the cushion).
    private func liveCushionSnapshot() -> (count: Int, summed: Double, maxDuration: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var summed = 0.0
        var maxDuration = 0.0
        for seg in segments {
            summed += seg.durationSeconds
            maxDuration = max(maxDuration, seg.durationSeconds)
        }
        return (segments.count, summed, maxDuration)
    }

    /// Block until the first live window holds the live-edge holdback (3 x TARGETDURATION) of content, so
    /// AVPlayer's initial seek to edge-minus-holdback lands inside the window instead of its stall-danger
    /// zone (-16832; AE#189). Also avoids -12888 on an empty playlist. Subsequent polls return instantly.
    /// The gate is `LiveEdgePolicy.startupCushionSatisfied`, computed from the SAME TARGETDURATION the
    /// served playlist advertises, so the depth built here is exactly the depth AVPlayer enforces.
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool {
        guard isLive else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        let window = liveWindowSizing.windowSegmentCount
        let cadenceFloor = liveCadencePolicy?.targetDurationFloorSeconds
        let cutTarget = liveWindowSizing.targetSegmentDurationSeconds
        firstSegmentCondition.lock()
        defer { firstSegmentCondition.unlock() }
        while true {
            if waitersCancelled { return false }
            let snap = liveCushionSnapshot()
            if LiveEdgePolicy.startupCushionSatisfied(segmentCount: snap.count,
                                                       summedDurationSeconds: snap.summed,
                                                       maxSegmentDuration: snap.maxDuration,
                                                       cutTargetSeconds: cutTarget,
                                                       cadenceFloorSeconds: cadenceFloor,
                                                       windowSegmentCount: window) {
                return true
            }
            if !firstSegmentCondition.wait(until: deadline) {
                // Re-read after the timed-out wait: an append racing the deadline would otherwise be judged
                // on the stale snapshot (waitForLiveSegment below already does this).
                let after = liveCushionSnapshot()
                // Degraded start: serving before the holdback cushion is built (transcode too slow, or a
                // strict-realtime origin that has not produced 3 x TD of content within the deadline) makes
                // a -16832 "restarting from end of live playlist" stall right after startup likely. Observe it.
                if after.count > 0 && !LiveEdgePolicy.startupCushionSatisfied(segmentCount: after.count,
                                                                             summedDurationSeconds: after.summed,
                                                                             maxSegmentDuration: after.maxDuration,
                                                                             cutTargetSeconds: cutTarget,
                                                                             cadenceFloorSeconds: cadenceFloor,
                                                                             windowSegmentCount: window) {
                    let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: after.maxDuration,
                                                                  cutTargetSeconds: cutTarget,
                                                                  cadenceFloorSeconds: cadenceFloor)
                    EngineLog.emit(
                        "[HLSVideoEngine] WARNING: live startup degraded, serving first playlist with "
                        + "\(after.count) segments / \(String(format: "%.1f", after.summed))s < "
                        + "\(String(format: "%.1f", LiveEdgePolicy.holdBackSeconds(targetDuration: td)))s holdback "
                        + "after \(Int(timeout))s timeout (undersized startup cushion)",
                        category: .session
                    )
                }
                return after.count > 0
            }
        }
    }

    func cancelWaiters() {
        firstSegmentCondition.lock()
        waitersCancelled = true
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Next index + output-timeline end (seconds) for a live-reopen producer to resume from tfdt.
    func liveContinuationPoint() -> (nextIndex: Int, outputEndSeconds: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let next = segments.count
        let end = segments.last.map { $0.startSeconds + $0.durationSeconds } ?? 0
        return (next, end)
    }

    /// LL-HLS blocking reload: block until segment index exists or timeout. Returns actual existence on timeout.
    func waitForLiveSegment(index: Int, timeout: TimeInterval) -> Bool {
        guard isLive else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        firstSegmentCondition.lock()
        defer { firstSegmentCondition.unlock() }
        while true {
            if waitersCancelled { return false }
            stateLock.lock()
            let count = segments.count
            stateLock.unlock()
            if count > index { return true }
            if !firstSegmentCondition.wait(until: deadline) {
                stateLock.lock()
                let final = segments.count
                stateLock.unlock()
                return final > index
            }
        }
    }
    var masterCodecs: String? { codecsString }
    var masterSupplementalCodecs: String? { supplementalCodecsString }
    var masterResolution: (width: Int, height: Int)? {
        return (resolution.0, resolution.1)
    }
    var masterVideoRange: HLSVideoRange? { videoRange }
    /// 25 Mbps fallback: under-declaring fires -12318 "Segment exceeds specified bandwidth" on every segment.
    var masterAverageBandwidth: Int? {
        sourceBitrate > 0 ? Int(sourceBitrate) : 25_000_000
    }

    /// 2x average as peak estimate (4K HDR action bursts to ~2x); 5 Mbps floor for corrupt-bitrate sources.
    var masterBandwidth: Int? {
        let avg = masterAverageBandwidth ?? 25_000_000
        return max(avg * 2, 5_000_000)
    }
    var masterFrameRate: Double? { frameRate }
    var masterHDCPLevel: String? { hdcpLevel }
    var masterClosedCaptions: String? { "NONE" }

    // MARK: - Native subtitle renditions (#15)

    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] {
        guard !nativeSubStores.isEmpty else { return [] }
        return nativeSubStores.indices.map { i in
            // Session-built infos carry deduped NAMEs + forced dispositions; the legacy per-ordinal
            // fallback stays for constructions that pass only languages (duplicate names collapse
            // AVFoundation's legible options, so real sessions should always pass infos).
            if i < nativeSubRenditionInfos.count {
                let info = nativeSubRenditionInfos[i]
                return (ordinal: i, language: info.language, name: info.name, isForced: info.isForced)
            }
            let lang = i < nativeSubLanguages.count ? nativeSubLanguages[i] : nil
            let name = lang.flatMap { Locale.current.localizedString(forIdentifier: $0) } ?? "Subtitle \(i + 1)"
            return (ordinal: i, language: lang, name: name, isForced: false)
        }
    }

    /// WebVTT for one subtitle segment: the cues overlapping video segment `segmentIndex`'s [start, end) on
    /// the AVPlayer timeline. `segments[i].startSeconds` is the absolute output-axis start (correct for both
    /// VOD and the live sliding window, where a cumulative EXTINF sum from firstVisible would not be), so the
    /// window is read straight off the segment plan rather than recomputed.
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> String? {
        guard ordinal >= 0, ordinal < nativeSubStores.count else { return nil }
        let store = nativeSubStores[ordinal]
        if nativeSubtitleWholeProgram {
            // Sodalite#32: serve the ENTIRE program's cues as one .vtt (the only AVPlayer-reliable sideload
            // shape). AVKit fetches this VOD single-segment file ONCE and never re-fetches it, so it MUST be
            // complete. Wait for the reader's definitive EOF signal (isFinished) rather than a cue-count plateau
            // heuristic, which fired early during dialogue gaps and served a truncated file (device-confirmed).
            let deadline = Date().addingTimeInterval(30.0)
            while !store.isFinished, Date() < deadline {
                usleep(100_000)
            }
            // Sodalite#32: the cues are stored at SOURCE pts; AVPlayer clock = source - shift. Apply the CURRENT
            // engine shift (read now, not the possibly-zero load-time value) so cues land on the video's axis.
            let shift = currentShiftSeconds()
            store.setShiftSeconds(shift)
            let cues = stripMarkupIfNeeded(store.allCues())
            EngineLog.emit("[HLSVideoEngine] whole-program subtitle .vtt ord=\(ordinal) cues=\(cues.count) finished=\(store.isFinished) shift=\(String(format: "%.2f", shift)) first=\(cues.first.map { String(format: "%.1f", $0.start) } ?? "-") last=\(cues.last.map { String(format: "%.1f", $0.end) } ?? "-")", category: .hlsServer)
            // PLAIN WebVTT, NO X-TIMESTAMP-MAP (matches the proven-working whole-file sideload). With the map,
            // AVKit anchors cues to the fMP4 sample PTS (which diverges from currentTime over our loopback) and
            // the subtitles render offset by the playback position; without it AVKit uses the cue times as the
            // AVPlayer timeline directly (= our absolute cue axis). Sodalite#32.
            return WebVTTBuilder.body(cues: cues)
        }
        stateLock.lock()
        guard segmentIndex >= 0, segmentIndex < segments.count else {
            stateLock.unlock()
            return nil
        }
        let start = segments[segmentIndex].startSeconds
        let end = start + segments[segmentIndex].durationSeconds
        stateLock.unlock()
        // Sodalite#32: bounded, distance-aware readiness wait replacing the 25 s wait-for-isFinished. AVKit
        // caches an empty-served window forever, so waiting is worth it; but blocking every fetch on a store
        // that never finishes serialized the loopback connection AVPlayer also uses for video (device:
        // scrubbing wedged while a rendition was selected). Wait only while the reader is plausibly about to
        // cover THIS window (read head within the horizon, or still warming up), and only briefly.
        let horizonSeconds = 30.0
        let deadline = Date().addingTimeInterval(3.0)
        while !store.isFinished,
              store.readMaxCueEnd() < end,
              end <= store.readMaxCueEnd() + horizonSeconds || store.readMaxCueEnd() <= 0,
              Date() < deadline {
            usleep(100_000)
        }
        let cues = stripMarkupIfNeeded(store.cuesInWindow(start: start, end: end))
        EngineLog.emit("[HLSVideoEngine] subtitle .vtt ord=\(ordinal) seg=\(segmentIndex) win=[\(String(format: "%.1f", start)),\(String(format: "%.1f", end))) inWin=\(cues.count) readMax=\(String(format: "%.1f", store.readMaxCueEnd()))", category: .hlsServer, level: .verbose)
        // Absolute media-timeline cue times + MPEGTS:0 identity map. Flip to segment-relative here (one line:
        // relativeToStart: true) if on-device PiP shows subtitles shifted by the segment start. See WebVTTBuilder.segment.
        return WebVTTBuilder.segment(cues: cues, segmentStart: start)
    }

    /// Sodalite#32 Phase 2: see `stripASSMarkupInVTT`.
    private func stripMarkupIfNeeded(
        _ cues: [(start: Double, end: Double, text: String)]
    ) -> [(start: Double, end: Double, text: String)] {
        guard stripASSMarkupInVTT else { return cues }
        return cues.compactMap { c in
            guard let plain = SubtitleRectText.plainText(fromASSEventLine: c.text) else { return nil }
            return (c.start, c.end, plain)
        }
    }
}
