import Foundation

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
    /// false for bursty upstreams that cannot honor the blocking-reload contract.
    private let blockingReloadEnabled: Bool
    /// #EXT-X-TARGETDURATION floor for bursty ingest sources; nil for URL live and VOD.
    private let targetDurationFloorSeconds: Double?

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
    /// Slice is generous enough to absorb a cold 4K-HDR first-GOP decode.
    private static let repositionWaitSlice: TimeInterval = 8.0
    private static let repositionMaxWaits = 3

    // MARK: - Playlist state

    private let stateLock = NSLock()
    /// Separate from stateLock so the manifest handler can block without holding the segment-list lock.
    private let firstSegmentCondition = NSCondition()
    /// Set by cancelWaiters() on stop(). Without it, parked LL-HLS blocking-reload threads sleep
    /// their full timeout (18-30 s) and can write stale playlists into a recycled fd of the next session.
    private var waitersCancelled = false
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
        blockingReloadEnabled: Bool = true,
        targetDurationFloorSeconds: Double? = nil,
        restartHandler: ((Int) -> Void)? = nil,
        nativeSubtitleStores: [NativeSubtitleCueStore] = [],
        nativeSubtitleLanguages: [String?] = [],
        stripASSMarkupInVTT: Bool = false,
        nativeSubtitleDefaultOrdinal: Int = 0,
        nativeSubtitleWholeProgram: Bool = false,
        currentShiftSeconds: @escaping @Sendable () -> Double = { 0 }
    ) {
        self.cache = cache
        self.segments = segments
        self.isLive = isLive
        self.liveWindowSizing = liveWindowSizing
        self.blockingReloadEnabled = blockingReloadEnabled
        self.targetDurationFloorSeconds = targetDurationFloorSeconds
        self.codecsString = codecsString
        self.supplementalCodecsString = supplementalCodecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.hdcpLevel = hdcpLevel
        self.sourceBitrate = sourceBitrate
        self.restartHandler = restartHandler
        self.nativeSubStores = nativeSubtitleStores
        self.nativeSubLanguages = nativeSubtitleLanguages
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

    /// Pure lookup for live scrub thumbnail: no side effects, no restarts; nil outside resident window.
    func liveThumbnailSegment(atSeconds seconds: Double) -> (index: Int, startSeconds: Double, fileURL: URL)? {
        guard isLive else { return nil }
        stateLock.lock()
        let segs = segments
        stateLock.unlock()
        guard let idx = segs.lastIndex(where: {
            $0.startSeconds <= seconds && seconds < $0.startSeconds + $0.durationSeconds
        }) else { return nil }
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

    /// Shared by mediaSegment(at:) and mediaSegmentURL(at:). Without sharing, back-scrubs served
    /// via sendfile (cache hits) skip the proactive restart entirely, leaving seg-11+ to fall into
    /// a reactive prune-gap restart with AVPlayer's buffer at its thinnest.
    private func handleTargetChange(to index: Int) {
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
        if staleBelowProducer || producerPassedAndPruned {
            needsRestart = true
        } else if let r = range {
            if index < r.0 {
                needsRestart = true
            } else if index > r.1 + Self.forwardWaitWindow {
                needsRestart = true
            } else if index >= r.0 && index <= r.1 {
                // Producer might still be writing this index forward
                // from its current write head. Wait briefly first.
                if let waited = cache.fetch(index: index, timeout: 2.0) {
                    return logServed(index: index, bytes: waited, totalStart: totalStart, restarted: false)
                }
                needsRestart = true
            } else {
                // r.1 < index <= r.1 + forwardWaitWindow: producer about to write; backpressure-wait.
                needsRestart = false
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
            for attempt in 0..<Self.repositionMaxWaits {
                if attempt == 0 || lastRestartIndex != index {
                    EngineLog.emit(
                        "[HLSVideoEngine] seg\(index): out-of-range fetch (cache.range=\(range.map { "\($0.0)..\($0.1)" } ?? "empty") highWater=\(highWater) attempt=\(attempt + 1)/\(Self.repositionMaxWaits)), restarting producer",
                        category: .session
                    )
                    lastRestartIndex = index
                    restart(index)
                    // Reset highWater AFTER restart() returns (synchronous: old producer has exited).
                    // Pre-restart reset would be clobbered by the old producer's final write re-bumping
                    // highWater, re-arming producerPassedAndPruned and cascading into per-segment restarts.
                    cache.resetHighWaterForRestart()
                }
                if let bytes = cache.fetch(index: index, timeout: Self.repositionWaitSlice) {
                    return logServed(index: index, bytes: bytes, totalStart: totalStart, restarted: true)
                }
            }
            return logServed(index: index, bytes: nil, totalStart: totalStart, restarted: true)
        }

        let bytes = cache.fetch(index: index, timeout: 30.0)
        return logServed(index: index, bytes: bytes, totalStart: totalStart, restarted: needsRestart)
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
    var liveBlockingReloadEnabled: Bool { blockingReloadEnabled }
    var liveTargetDurationFloorSeconds: Double? {
        isLive ? targetDurationFloorSeconds : nil
    }
    /// 2 = one segment (~4 s) of startup cushion absorbing transcode jitter that caused -16832
    /// "restarting from end of live playlist". 1 disables. Distinct from the reverted hold-back
    /// which trailed the ADVERTISED edge without building an actual buffer.
    private static let liveStartupSegments = 2

    /// Block until liveStartupSegments segments exist. Avoids -12888 on an empty playlist
    /// and gives AVPlayer its startup cushion. Subsequent polls return instantly.
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool {
        guard isLive else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        firstSegmentCondition.lock()
        defer { firstSegmentCondition.unlock() }
        while true {
            if waitersCancelled { return false }
            stateLock.lock()
            let count = segments.count
            stateLock.unlock()
            if count >= Self.liveStartupSegments { return true }
            if !firstSegmentCondition.wait(until: deadline) {
                // Re-read after the timed-out wait: an append racing the
                // deadline would otherwise be judged on the stale count
                // (waitForLiveSegment below already does this).
                stateLock.lock()
                let count = segments.count
                stateLock.unlock()
                // Degraded start: serving the first playlist with fewer
                // than liveStartupSegments segments loses the startup
                // cushion that absorbs transcode jitter, so a -16832
                // "restarting from end of live playlist" stall right
                // after startup becomes likely. Make it observable.
                if count > 0 && count < Self.liveStartupSegments {
                    EngineLog.emit(
                        "[HLSVideoEngine] WARNING: live startup degraded, serving first "
                        + "playlist with \(count)/\(Self.liveStartupSegments) segments after "
                        + "\(Int(timeout))s timeout (no startup cushion)",
                        category: .session
                    )
                }
                return count > 0
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

    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String)] {
        guard !nativeSubStores.isEmpty else { return [] }
        return nativeSubStores.indices.map { i in
            let lang = i < nativeSubLanguages.count ? nativeSubLanguages[i] : nil
            let name = lang.flatMap { Locale.current.localizedString(forIdentifier: $0) } ?? "Subtitle \(i + 1)"
            return (ordinal: i, language: lang, name: name)
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
            EngineLog.emit("[PiPSubsDiag] whole-program ord=\(ordinal) cues=\(cues.count) finished=\(store.isFinished) shift=\(String(format: "%.2f", shift)) first=\(cues.first.map { String(format: "%.1f", $0.start) } ?? "-") last=\(cues.last.map { String(format: "%.1f", $0.end) } ?? "-")", category: .hlsServer)
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
        EngineLog.emit("[PiPSubsDiag] ord=\(ordinal) seg=\(segmentIndex) win=[\(String(format: "%.1f", start)),\(String(format: "%.1f", end))) inWin=\(cues.count) readMax=\(String(format: "%.1f", store.readMaxCueEnd()))", category: .hlsServer)
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
