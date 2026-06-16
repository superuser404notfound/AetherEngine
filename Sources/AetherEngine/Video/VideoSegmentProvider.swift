import Foundation

// MARK: - Live window sizing

/// Single source of truth for how large the sliding live window is, in
/// segments. Both the playlist's visible window (`firstVisible = highWater -
/// windowSegmentCount`) and the on-disk cache eviction (`evictBelow(
/// firstVisible)`) read this so the two can never drift apart (a drift is
/// exactly what stalls AVPlayer: the playlist keeps listing a segment the
/// cache already deleted, or the cache keeps a segment the playlist dropped).
///
/// `effectiveWindowSeconds = dvrWindowSeconds ?? liveOnlyFloorSeconds`.
/// Live-only (no DVR seek) still gets a bounded floor so disk and the
/// playlist stay finite. `windowSegmentCount = max(minSafeSegments,
/// ceil(effectiveWindowSeconds / targetSegmentDurationSeconds))`.
struct LiveWindowSizing {
    /// Bound applied to a live-only session (no `dvrWindowSeconds`). No DVR
    /// seek is offered, but the window is still capped so memory and disk
    /// do not grow without bound. 60 s at 4 s segments is 15 segments.
    static let liveOnlyFloorSeconds: Double = 60

    /// Floor on the segment count regardless of how small the requested
    /// window is. AVPlayer keeps several target-durations of media buffered
    /// near the live edge (it prefetches ~5-7 segments ahead during normal
    /// playback, see `forwardWaitWindow`). If the window were smaller than
    /// that buffer, AVPlayer's forward/backward live-edge reads would
    /// routinely fall below MEDIA-SEQUENCE and it would lose its position
    /// (the spike's 81 s stall). 8 keeps the window comfortably wider than
    /// AVPlayer's live-edge buffer at 4 s segments (32 s of runway).
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

/// Thin `HLSSegmentProvider` over a `SegmentCache`. The cache is
/// populated by the session's `HLSSegmentProducer`. AVPlayer GETs are
/// served from cache hits when the producer is ahead of the playhead;
/// misses block on the cache's per-index condvar with a generous
/// timeout (the producer is on a worker thread, so blocking the HTTP
/// server's connection thread is the natural backpressure model).
///
/// Scrub policy:
///  - In-cache: fast path, no waiting.
///  - Forward seek within `forwardWaitWindow` of cache.max: wait for
///    the producer to catch up. AVPlayer's normal sequential playback
///    falls in this bucket.
///  - Forward seek beyond that, or any backward seek beyond cache.min:
///    fire `restartHandler` so the engine can teardown + reseek
///    + spin up a fresh producer rooted at the new segment index,
///    then re-block on cache.fetch.
final class VideoSegmentProvider: HLSSegmentProvider, @unchecked Sendable {

    private let cache: SegmentCache
    /// Segment list. Immutable for VOD (the precomputed plan). For live
    /// it starts empty and the producer appends one entry per finalized
    /// segment via `appendLiveSegment`, guarded by `stateLock`. All reads
    /// (`segmentCount`, `segmentDuration(at:)`, `mediaSegmentURL(at:)`,
    /// `notePlaylistBuild`) take the lock when `isLive` so the growing
    /// list is observed consistently from the server's playlist-build
    /// thread.
    private var segments: [HLSVideoEngine.Segment]

    /// Whether this provider backs a live (unbounded, growing) session.
    /// Gates the mutable-segments path, the `.event` playlist type (no
    /// ENDLIST so AVPlayer re-polls), and the locked reads. VOD leaves
    /// this false and behaves byte-for-byte as before.
    private let isLive: Bool

    /// Sliding live window sizing. Drives both the playlist's visible
    /// window (`firstVisible = highWater - windowSegmentCount`) and the
    /// cache eviction cutoff, so the two never drift. Dormant for VOD.
    private let liveWindowSizing: LiveWindowSizing

    /// Whether the live playlist may advertise LL-HLS blocking reload.
    /// Derived by HLSVideoEngine from the ingest source's cadence hint
    /// (false for bursty upstreams that cannot honor the blocking-reload
    /// contract); true for URL live sources and VOD (where it is unused).
    private let blockingReloadEnabled: Bool

    /// Extra #EXT-X-TARGETDURATION floor (seconds) for bursty ingest
    /// sources, derived by HLSVideoEngine (ceil of the upstream cadence).
    /// nil for URL live sources and VOD.
    private let targetDurationFloorSeconds: Double?

    private let codecsString: String
    private let supplementalCodecsString: String?
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange
    private let frameRate: Double?
    private let hdcpLevel: String?
    private let sourceBitrate: Int64

    /// Decoy subtitle renditions to advertise in the master playlist
    /// (native-picker path). Set by the engine at load time before the
    /// server is started; empty means the feature is off and the master
    /// emits no subtitle lines. Plain stored value: written once on the
    /// load thread before `HLSLocalServer.start()`, then read-only for
    /// the session, so it needs no lock.
    var subtitleRenditionList: [(renditionID: String, name: String, language: String)] = []

    /// Total source duration in seconds (0 for live / unknown), used to
    /// size the decoy WebVTT rendition playlist's single EXTINF.
    private let durationSeconds: Double

    /// Closure into the engine that tears down the current producer
    /// and brings up a fresh one rooted at the given absolute segment
    /// index. Synchronous: returns after the new producer's pump has
    /// started writing, which is typically within 50-200 ms on Apple
    /// TV against a local Jellyfin source.
    private let restartHandler: ((Int) -> Void)?

    /// Last index passed to `restartHandler`, also used as the assumed
    /// base index of the engine's currently-active producer. Used by
    /// the empty-cache branch in `mediaSegment(at:)` to distinguish
    /// between "producer just launched here, wait for it" (`abs(index
    /// − lastRestartIndex) ≤ 2`) and "producer is far away from this
    /// index, restart needed" (large diff). Initialised to 0 since
    /// every session starts with an initial producer at baseIndex 0
    /// or the host's resume target, with the engine updating this
    /// after the first explicit restart it triggers via the public
    /// `requestRestart(at:)` path.
    ///
    /// Guarded by `stateLock`: the server's workQueue is concurrent, so
    /// `mediaSegment(at:)` / `handleTargetChange(to:)` can race on this
    /// from multiple connection threads (an unsynchronized read/write is
    /// a Swift data race; two racing GETs could also both read a stale
    /// value and double-trigger a restart).
    private var lastRestartIndex: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastRestartIndex }
        set { stateLock.lock(); _lastRestartIndex = newValue; stateLock.unlock() }
    }
    private var _lastRestartIndex: Int = 0

    /// Forward-distance threshold beyond which a fetch triggers a
    /// restart instead of waiting for the producer to catch up.
    /// 8 is the value that survives both failure modes:
    ///
    ///   - Tightened to 3 briefly to fix a Vincent repro where a
    ///     seg-13 request waited 26 s for the existing producer to
    ///     sequentially write 11 segments. The smaller window did
    ///     trigger restart at the target index for that case, but
    ///     also restarted on every AVPlayer prefetch above the cache
    ///     edge. AVPlayer's HLS engine speculatively prefetches 5-7
    ///     segments ahead of the playhead during normal playback, so
    ///     with window 3 every prefetch above cache.max+3 triggered
    ///     a restart that killed the in-flight producer mid-write,
    ///     leaving cache holes that AVPlayer hit on its next sequential
    ///     request, restarting again, and so on. Vincent's "video
    ///     hängt nach Scrub nach vorn" was the cascade outcome.
    ///   - 8 is wide enough to absorb AVPlayer's prefetch (any request
    ///     within ~32 s of source content above cache.max waits) and
    ///     narrow enough that user-initiated scrubs of 30+ seconds
    ///     still trigger a restart at the target. The 26 s wait
    ///     in the original repro is the worst-case for "wait within
    ///     window"; it's annoying but not a hang, and stays bounded
    ///     by segment-write-rate × window. Tightening below 8
    ///     requires distinguishing user scrubs from AVPlayer's
    ///     speculative prefetch, which we currently cannot do from
    ///     the segment-server side.
    private static let forwardWaitWindow = 8

    // MARK: - Playlist state

    /// Guards `segments`, the live window fields, and `refreshCounter`.
    /// (The historical VOD sliding-window machinery that once lived
    /// here was dead code: notePlaylistBuild always reported the full
    /// VOD count and never consulted the window. Removed; VOD playlists
    /// are complete from the first build.)
    private let stateLock = NSLock()
    /// Condition variable used to signal `waitForFirstLiveSegment` when
    /// the first live segment is appended. A separate NSCondition (not
    /// the NSLock above) so the manifest handler can block without
    /// holding the segment-list lock. Signaled once from
    /// `appendLiveSegment` when `segments.count` transitions from 0 to 1.
    private let firstSegmentCondition = NSCondition()
    /// Set by `cancelWaiters()` when the engine tears the session down.
    /// With LL-HLS blocking reload, AVPlayer has a parked playlist request
    /// open at essentially all times during steady-state live playback
    /// (waiting on the next segment, which only arrives ~one target
    /// duration later). Once the producer is stopped no append will ever
    /// broadcast again, so without this flag the parked server thread
    /// sleeps out its full timeout (18-30 s) after stop(), pinning the
    /// provider + SegmentCache via its strong reference and then writing
    /// a stale playlist into a connection of the NEXT session if the fd
    /// number was recycled (engine is a process-wide singleton; channel
    /// zap restarts immediately). Guarded by `firstSegmentCondition`.
    private var waitersCancelled = false
    private var refreshCounter: Int = 0
    /// First segment index visible in the live sliding-window playlist
    /// (`#EXT-X-MEDIA-SEQUENCE`). Monotonically increasing; advanced by
    /// `notePlaylistBuild` to `max(0, highWater - windowSegmentCount)`.
    /// Stays 0 for VOD and the append-only EVENT audio path.
    private var _liveFirstVisible: Int = 0
    /// Running count of discontinuity-tagged segments that have slid out
    /// of the visible live window; the playlist's
    /// `#EXT-X-DISCONTINUITY-SEQUENCE` value. Guarded by `stateLock`.
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
        durationSeconds: Double = 0,
        isLive: Bool = false,
        liveWindowSizing: LiveWindowSizing = LiveWindowSizing(targetSegmentDurationSeconds: 4.0, dvrWindowSeconds: nil),
        blockingReloadEnabled: Bool = true,
        targetDurationFloorSeconds: Double? = nil,
        restartHandler: ((Int) -> Void)? = nil
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
        self.durationSeconds = durationSeconds
        self.restartHandler = restartHandler

    }

    /// Append a producer-finalized live segment to the growing list under
    /// the state lock. Called once per fragment cut from the producer's
    /// pump thread (live mode only). `index` is the absolute segment
    /// index the producer assigned; appends are sequential so the list's
    /// position equals `index`. Defensive: an out-of-order or duplicate
    /// index is ignored so the list stays a dense `[0, n)`.
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
        // unused for live; left 0 to avoid a wrong-timebase latent value
        // (source video TB is not reachable from this provider without a
        // large new dependency; DVR restart machinery will supply correct
        // values when wired)
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
        // Wake the manifest handler's startup-buffer wait on every append (not
        // just the first), so it can unblock once the configured startup
        // segment count exists. One broadcast per ~4 s segment is negligible.
        firstSegmentCondition.lock()
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Atomic snapshot the playlist build reads from. For VOD this
    /// reports the full segment count so AVPlayer sees a complete asset
    /// with a correct duration (the historical EVENT experiment that
    /// reported visibleHighWater+1 made AVPlayer think the asset was
    /// 2:13 and stop there).
    ///
    /// For a live session this advances `_liveFirstVisible` to
    /// `max(0, highWater - windowSegmentCount)` so the playlist window
    /// slides forward, then evicts everything strictly below the new
    /// firstVisible from the cache. The same `windowSegmentCount` drives
    /// both, so the playlist and the cache stay byte-for-byte aligned.
    /// firstVisible only advances once enough segments exist to seed
    /// AVPlayer's live edge (the window stays anchored at 0 until then),
    /// which is the anti-stall guarantee.
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
                // RFC 8216 §6.2.2: EXT-X-DISCONTINUITY-SEQUENCE MUST be
                // incremented for every discontinuity-tagged segment that
                // falls out of the window. The live `segments` array is
                // never pruned, so the slid-out range is still readable.
                for i in _liveFirstVisible..<newFirst where segments[i].discontinuous {
                    _discontinuitySequence += 1
                }
                _liveFirstVisible = newFirst
                // Evict everything below the new firstVisible. Off-lock to
                // avoid holding stateLock during file I/O; evictBelow takes
                // its own lock. Strictly below firstVisible, so no segment
                // the playlist still lists (or AVPlayer's live-edge buffer
                // still references) is ever removed.
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

    /// First segment index visible in the current playlist window.
    /// For VOD (and the append-only EVENT audio path) this is always 0.
    /// For a live session this is `_liveFirstVisible`, which advances as
    /// old segments fall off the back of the sliding window.
    var firstVisibleSegmentIndex: Int {
        guard isLive else { return 0 }
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveFirstVisible
    }

    // MARK: - Thumbnail lookup (engine-internal)

    /// Pure lookup for the live scrub-thumbnail path: the segment whose
    /// [start, start+duration) span contains `seconds`, plus its cache
    /// file URL. NO side effects: unlike `mediaSegmentURL(at:)` this must
    /// not extend the visible window or trigger a producer restart; a
    /// thumbnail probe outside the resident window simply returns nil.
    /// A probe at or past the end of the last finalized segment (the live
    /// edge) returns nil by design; the consumer treats nil as time-only
    /// fallback.
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

    /// Non-blocking init.mp4 peek for the thumbnail path. The blocking
    /// `initSegment()` (30s) is for the HTTP server, where waiting on the
    /// muxer is the backpressure model; a cosmetic preview must not park.
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
        // Version 0 may not be captured yet at startup; keep the blocking
        // fetch for it so AVPlayer's first /init.mp4 waits. Higher versions
        // are captured synchronously at the switch, so a plain lookup is fine.
        if versionID == 0 { return cache.fetchInit(timeout: 30.0) }
        return cache.initData(versionID: versionID)
    }

    /// File URL for a cached segment without materializing any bytes.
    /// Used by `HLSLocalServer` to take the `sendfile(2)` fast path
    /// (file → socket entirely kernel-side, no Foundation `Data`
    /// involvement). Returns nil when the segment isn't yet cached,
    /// is out of range, or its cache entry has been pruned. This is
    /// intentionally a pure-lookup: no producer restart, no window
    /// extension, no `declareTarget`. The caller falls back to
    /// `mediaSegment(at:)` (which does drive those side effects) on
    /// nil.
    func mediaSegmentURL(at index: Int) -> URL? {
        guard index >= 0, index < currentSegmentCount else { return nil }
        // Drive cache-window + restart side effects same as the Data
        // path; only the byte materialization changes. Without this
        // the sendfile path would skip the producer restart on
        // out-of-range fetches and AVPlayer would 404 indefinitely.
        handleTargetChange(to: index)
        return cache.peekURL(index: index)
    }

    /// Update the cache's target index AND, if the change represents
    /// a big backward jump, proactively relocate the producer.
    /// Shared by both `mediaSegment(at:)` (Data path) and
    /// `mediaSegmentURL(at:)` (sendfile path) — without unifying,
    /// the sendfile path skips the proactive restart entirely, and
    /// since the FIRST segment a back-scrub touches is almost always
    /// a cache hit (seg-0..seg-N from the initial burst, served via
    /// sendfile), the proactive restart would never fire when it
    /// matters most. Symptom: user back-scrubs, AVPlayer fetches
    /// cached seg-0..seg-10 via sendfile (target advances 0→10
    /// without ever going through `mediaSegment(at:)`), then hits
    /// seg-11 and falls into the reactive prune-gap restart with
    /// AVPlayer's buffer at the thinnest — exactly the user-visible
    /// post-scrub hang.
    private func handleTargetChange(to index: Int) {
        let previousTarget = cache.targetIndex
        cache.declareTarget(index)

        // Proactive relocation on backward-jump declareTarget.
        // Threshold of 2 mirrors the empty-cache branch's tolerance
        // for "near the producer's launch point, just wait" — small
        // backward jumps (e.g. tvOS HLS's occasional speculative
        // re-fetch of a recently-played segment) don't justify
        // tearing down the producer.
        if previousTarget >= 0, index < previousTarget - 2, let restart = restartHandler {
            // Cache gate: only relocate when the requested segment is NOT
            // resident. The cache's backwardWindow (20 segments) was sized
            // so AVPlayer's Continuous-Audio handover refetches (~7-10
            // segments backward) serve from cache WITHOUT a producer
            // restart, because each restart re-arms the FLAC bridge
            // timeline and produced audible glitches. The unconditional
            // proactive restart reintroduced exactly that teardown for
            // resident-window refetches; the back-scrub hang it was added
            // for involves a segment the window already pruned, which
            // still restarts below.
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

        // Live fast-404: a request below the sliding window can never be
        // satisfied. The producer is forward-only (restartHandler is nil
        // for live) and the cache evicted the file when the window slid,
        // so falling through would park the connection in the 30 s
        // cache.fetch below for a segment that will never reappear.
        // Concrete trigger: pause live TV past the window, resume;
        // AVPlayer drains its buffer and fetches an evicted segment, and
        // playback freezes for 30 s instead of AVPlayer resyncing from
        // the playlist edge. An immediate nil turns into a fast 404 and
        // lets AVPlayer recover (the engine's resume clamp jumps the
        // playhead back inside the window in parallel).
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

        // Update target + proactive-restart on big backward jump.
        // See `handleTargetChange` for rationale; this path and the
        // sendfile `mediaSegmentURL` path share the same logic so a
        // back-scrub's first cache-hit doesn't slip past unnoticed.
        handleTargetChange(to: index)

        // Fast path: serve from cache.
        if let hit = cache.peek(index: index) {
            return logServed(index: index, bytes: hit, totalStart: totalStart, restarted: false)
        }

        // Decide whether to restart the producer or wait. Four cases:
        //   - range is empty → the producer hasn't produced (or hasn't
        //     produced anything in our current window after declareTarget
        //     pruned). If the requested index is beyond the producer's
        //     plausible cold-start reach (a few seg-0s), restart at
        //     `index`. Otherwise wait — the producer is about to write
        //     seg-0 / seg-1 / seg-2 and we don't want to thrash.
        //   - index below the cache's low edge → backward seek past
        //     the kept window, restart.
        //   - index too far above the cache's high edge → forward
        //     seek past where the producer can reach via backpressure,
        //     restart.
        //   - index nominally within the cache's [min..max] range but
        //     peek failed → could be a real hole OR producer-in-flight
        //     that hasn't yet written this segment. Wait briefly; only
        //     restart if the wait times out. Without this short wait
        //     every restart cascades: producer restarts at N, finishes
        //     writing N, returns to caller; AVPlayer then GETs N+1, but
        //     producer hasn't written N+1 yet so peek returns nil while
        //     cache.range is (N..M) from the previous producer's leftover.
        //     The "hole" branch triggers a fresh restart at N+1, which
        //     repeats the pattern for N+2, N+3, etc. A 2s wait absorbs
        //     the typical 100-500ms producer write cadence and breaks
        //     the cascade. True holes (rare; happen after CC's +10s skip
        //     when AVPlayer rebuffers behind the skip target and the
        //     declareTarget prune evicts a segment AVPlayer will need
        //     later) still trigger a restart after the wait times out.
        // Stale-leftover guard: the request is well below where the
        // current producer was launched. `cache.indexRange()` can still
        // report a lower bound from segments left over by a previous
        // producer (typical case: cold-start probe wrote seg-0 / seg-1
        // before the host's resume target triggered a restart at
        // baseIndex=N), and the range-based branch below would mis-
        // classify the request as "producer is about to write this;
        // wait" and stall on a segment the current producer will never
        // generate. Force a restart at the requested index so the
        // producer relocates to where AVPlayer is actually fetching.
        // Tolerance of 2 matches the empty-cache branch's heuristic
        // for "near the producer's launch point, just wait."
        //
        // Pruned-gap guard: the cache once held `index` but
        // `pruneOutsideWindow` evicted it (typical case: AVPlayer
        // jumped past `index` on a forward skip so the producer
        // wrote it but AVPlayer never fetched it, then a back-scrub
        // re-centred the window and the next slide pruned `index`
        // out from under us). `indexRange()` reports only currently-
        // resident entries — once the high end is pruned, the
        // range-based branch sees `r.1 < index <= r.1 + window`,
        // hits the else-clause, and concludes "producer is about
        // to write this; backpressure-wait." But the producer is
        // already past `index` and won't backfill without a restart.
        // `highestStoredIndex` is monotonic across prunes so it
        // remembers the producer's true high-water and catches the
        // case. Concrete repro: 110-segment episode, AVPlayer jumped
        // 8→12, then back-scrubbed to 0, then played seg-0..seg-10
        // from cache (seg-11..seg-24 pruned by the seg-0 declareTarget),
        // requested seg-11, hit the else-branch, waited 30 s, and
        // 404'd because the current producer was past seg-24.
        let range = cache.indexRange()
        let highWater = cache.highestStoredIndex
        let staleBelowProducer = index < lastRestartIndex - 2
        // Prune-created gap the producer already advanced past: `highWater`
        // says the current producer wrote beyond `index`, but that alone is
        // NOT a pruned gap. During normal forward-march the producer races
        // ahead of AVPlayer (highWater well above the requested index) while
        // the low segments are still resident and unpruned. Restarting on a
        // resident in-window index was a false positive that threw away the
        // producer's forward progress and forced an AVIO reconnect mid-
        // playback, eroding AVPlayer's forward buffer and stuttering (repro:
        // `cache.range=0..24 highWater=24`, request seg15 -> needless restart).
        // Only treat it as a real gap when `index` falls OUTSIDE the resident
        // window: above `r.1` means the high end was pruned after a window
        // slide (the documented seg-11 repro), below `r.0` means the low end
        // was pruned. When `index` is inside `[r.0, r.1]` the range branch
        // below serves it from cache (or waits briefly, then restarts only on
        // a genuine internal gap). Empty cache keeps the bare highWater test.
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
                // r.1 < index <= r.1 + forwardWaitWindow — producer is
                // about to write this; backpressure-wait.
                needsRestart = false
            }
        } else {
            // Empty cache. Two scenarios:
            //  1. Cold start: producer just launched at lastRestartIndex,
            //     hasn't written anything yet. AVPlayer's first GET for
            //     a nearby segment should wait briefly while the producer
            //     fills the cache (restarting would just churn the
            //     producer we already have).
            //  2. Big scrub after the cache window slid away: the
            //     producer is far from `index` (different baseIndex)
            //     and won't ever write into the requested region.
            //     Restart is mandatory; waiting just times out.
            //
            // Discriminate on lastRestartIndex (the absolute segment
            // index the engine's current producer was launched at):
            // close to `index` means cold-start case → wait; far from
            // it means scrub case → restart. The previous heuristic
            // (`index > 2`) only handled cold-start from index 0 and
            // missed Vincent's repro where the producer was at idx
            // 1314 and AVPlayer requested seg-0 after a back-scrub,
            // leaving AVPlayer to time out for 30 s and 404.
            needsRestart = abs(index - lastRestartIndex) > 2
        }

        if needsRestart, let restart = restartHandler {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): out-of-range fetch (cache.range=\(range.map { "\($0.0)..\($0.1)" } ?? "empty") highWater=\(highWater)), restarting producer",
                category: .session
            )
            lastRestartIndex = index
            restart(index)
            // Reset cache's high-water AFTER `restart(index)` returns.
            // restart() is synchronous: it calls `old.stop()` then
            // `waitForFinish` so the old producer has fully exited
            // (or been abandoned after 5 s) before returning. The
            // new producer was just `start()`-ed but its pump loop
            // is async and hasn't stored anything yet. Resetting
            // here closes the race where the old producer's final
            // segment write (e.g. seg-21 captured immediately after
            // we triggered the restart at 11) re-bumps `highWater`
            // *after* a pre-restart reset would have cleared it,
            // re-arming the producerPassedAndPruned gate and
            // cascading into a per-segment restart storm. With the
            // reset positioned post-restart, only the new producer's
            // forward writes feed the high-water and the gate stays
            // inert for forward-march fetches.
            cache.resetHighWaterForRestart()
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

    /// Segment-count read that takes `stateLock` for live (the list grows
    /// on the producer thread) and reads directly for VOD (immutable list,
    /// no lock needed, byte-for-byte unchanged behaviour).
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

    /// Reverted to .vod after the sliding-window EVENT experiment:
    /// EVENT halved RSS growth (3.0 → 1.3 MB/sec) but did not bound
    /// it (AVPlayer still retains ~93% of consumed source bytes
    /// regardless of playlist type), and the side effects were
    /// unacceptable — Control Center showed "LIVE" instead of a
    /// scrub bar (caused by EVENT making asset.duration NaN), and
    /// replay-from-beginning landed ~2 min in (AVPlayer's EVENT
    /// live-edge default overrode EXT-X-START even with the
    /// explicit seek-to-0). The leak is fundamental to the
    /// AVPlayer + HLS-loopback pipeline for 4K HDR HEVC content.
    /// Live sessions serve a `.live` playlist: no `#EXT-X-PLAYLIST-TYPE`
    /// and no `#EXT-X-ENDLIST`, with an advancing `#EXT-X-MEDIA-SEQUENCE`
    /// as the sliding window drops consumed segments. EVENT was tried
    /// first but forbids segment removal (the spec), which contradicts a
    /// sliding window and was the likely cause of the spike's 81 s stall;
    /// VOD implies a finished asset and stops playback at the first read.
    /// `.live` is the only spec-correct shape for a window that grows at
    /// the edge AND drops the back. VOD stays `.vod` (the reverted-EVENT
    /// rationale below applies only to finite files); the audio-append
    /// path keeps `.event` available.
    var playlistType: HLSPlaylistType { isLive ? .live : .vod }
    /// Expose the producer's cut target so the playlist builder can anchor
    /// `#EXT-X-TARGETDURATION` to a stable, generous value from the first
    /// manifest, avoiding the -12888 startup race for high-bitrate live
    /// sources. Returns nil for VOD (the default extension nil suffices).
    var liveTargetSegmentDuration: Double? {
        isLive ? liveWindowSizing.targetSegmentDurationSeconds : nil
    }
    /// Blocking-reload eligibility, decided by HLSVideoEngine from the
    /// ingest source's cadence (see the engine init comment). The playlist
    /// builder gates #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES on this,
    /// and the server's media.m3u8 handler skips the blocking hold when
    /// false. Only meaningful for live; harmless true otherwise.
    var liveBlockingReloadEnabled: Bool { blockingReloadEnabled }
    /// Extra TARGETDURATION floor for bursty ingest sources, nil otherwise.
    var liveTargetDurationFloorSeconds: Double? {
        isLive ? targetDurationFloorSeconds : nil
    }
    /// Live startup buffer, in segments. The manifest handler holds the FIRST
    /// playlist response until this many segments exist, so AVPlayer (which
    /// starts a live `.live` playlist at its oldest listed segment, reinforced
    /// by the host's explicit seek-to-0) begins `liveStartupSegments - 1`
    /// segments BEHIND the production edge and keeps that gap (production and
    /// playback both run at 1x, so the cushion is constant). This absorbs the
    /// real-time-transcode jitter that otherwise starves the bleeding edge
    /// (-16832 "restarting from end of live playlist" + playbackStalled). 2 =
    /// one segment (~4 s) of cushion: the minimum that gives any headroom, at
    /// the cost of ~one extra segment of startup latency. Distinct from the
    /// reverted live-edge hold-back, which trailed the ADVERTISED edge while
    /// still starting AVPlayer at the bleeding edge (1 segment) and so never
    /// built a cushion. 1 disables (serve at the first segment, old behaviour).
    private static let liveStartupSegments = 2

    /// Block the calling thread until at least `liveStartupSegments` live
    /// segments have been appended, or until `timeout` seconds elapse. Returns
    /// true if enough segments are available, false on timeout. Non-live
    /// sessions return immediately. Holding the first manifest response this
    /// way (a) avoids serving an empty live playlist that fires
    /// CoreMediaErrorDomain -12888 on the very first poll, and (b) gives
    /// AVPlayer a startup cushion behind the live edge (see
    /// `liveStartupSegments`). Subsequent polls return instantly once the
    /// count is reached, so only the first response is delayed.
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

    /// Wake every thread parked in `waitForFirstLiveSegment` /
    /// `waitForLiveSegment` and make all future waits return immediately.
    /// Called from `HLSVideoEngine.stop()`; see `waitersCancelled`.
    func cancelWaiters() {
        firstSegmentCondition.lock()
        waitersCancelled = true
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// Where a live-reopen producer must continue: the next segment
    /// index to append, and the OUTPUT-timeline end (seconds) of the
    /// last appended segment, which becomes the new producer's desired
    /// first tfdt so the output timeline stays continuous across the
    /// reopen seam.
    func liveContinuationPoint() -> (nextIndex: Int, outputEndSeconds: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let next = segments.count
        let end = segments.last.map { $0.startSeconds + $0.durationSeconds } ?? 0
        return (next, end)
    }

    /// LL-HLS blocking reload: block until segment `index` (0-based absolute
    /// index = the requested Media Sequence Number) has been appended, or
    /// until `timeout`. `segments.count > index` means the segment exists.
    /// Reuses the same per-append broadcast as `waitForFirstLiveSegment`, so
    /// the wait wakes the instant the producer finalizes the next segment.
    /// On timeout returns whether the segment happens to exist by then; the
    /// caller serves the current playlist either way (AVPlayer retries).
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
    /// AVERAGE-BANDWIDTH reflects the source container's reported
    /// bitrate. Falls back to a high default (25 Mbps) when libavformat
    /// can't compute it, since under-declaring causes AVPlayer to log
    /// `CoreMediaErrorDomain -12318 'Segment exceeds specified
    /// bandwidth for variant'` for every above-average segment.
    /// Over-declaring is harmless to AVPlayer's variant-selection on a
    /// single-variant master.
    var masterAverageBandwidth: Int? {
        sourceBitrate > 0 ? Int(sourceBitrate) : 25_000_000
    }

    /// BANDWIDTH represents the peak segment bitrate. Per HLS spec it
    /// MUST NOT be smaller than any individual segment's bitrate.
    /// 4K HDR HEVC sources have heavily variable per-second bitrates
    /// (action-heavy scenes burst to ~2x average) so we publish 2x
    /// the source's average as a safety margin. 5 Mbps floor keeps
    /// us above AVPlayer's internal sanity thresholds even when the
    /// source reports a tiny / corrupt bitrate.
    var masterBandwidth: Int? {
        let avg = masterAverageBandwidth ?? 25_000_000
        return max(avg * 2, 5_000_000)
    }
    var masterFrameRate: Double? { frameRate }
    var masterHDCPLevel: String? { hdcpLevel }
    var masterClosedCaptions: String? { "NONE" }

    /// Decoy subtitle renditions the engine installed at load time.
    var subtitleRenditions: [(renditionID: String, name: String, language: String)] {
        subtitleRenditionList
    }

    /// Source duration for the decoy WebVTT playlist sizing; nil when
    /// unknown (0).
    var mediaDurationSeconds: Double? {
        durationSeconds > 0 ? durationSeconds : nil
    }
}
