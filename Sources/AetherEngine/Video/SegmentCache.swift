import Foundation

/// Sliding-window cache for HLS-fMP4 segment bytes plus a pinned
/// init.mp4 slot. Indexed by absolute segment number; eviction is
/// index-window-based, centred on the highest segment AVPlayer has
/// actually fetched (`currentTargetIndex`).
///
/// Storage is disk-backed: every `store(index:data:)` writes the
/// bytes to `<NSTemporaryDirectory>/aether-session-<uuid>/seg-<n>.m4s`
/// and only the file URL stays in RAM. Reads go through
/// `Data(contentsOf:, options: .alwaysMapped)` so the kernel pages
/// in on-demand and frees on memory pressure without our
/// involvement. This caps our own RAM contribution at the size of
/// the index map (~few KB for 2k segments) plus the one segment
/// currently being written by the producer or read by the server,
/// instead of `windowSize × avg-segment-size` (was ~120 MB at 4K
/// HDR HEVC). The init segment is small (~3.5 KB) and lives in RAM.
///
/// Window semantics: the producer pauses (via `awaitFetchHighWater`)
/// once it's `forwardWindow` segments past `currentTargetIndex`; the
/// `bufferAheadSegments` constant on `HLSSegmentProducer` matches
/// that, so the muxer never writes beyond the cache's forward edge.
/// Eviction (file deletion) keeps a tight band
/// `[currentTarget - backwardWindow, currentTarget + forwardWindow]`
/// regardless of when the entries were created, so AVPlayer's
/// next-up segments stay resident on disk.
final class SegmentCache {

    private let condition = NSCondition()

    /// How many segments past `currentTargetIndex` the cache keeps
    /// resident on disk. The producer's backpressure setting uses
    /// the same number so the cache never sees a write past this
    /// edge.
    private let forwardWindow: Int

    /// How many segments behind `currentTargetIndex` the cache keeps
    /// resident on disk. Bounds the cheap-backward-scrub distance:
    /// smaller scrubs hit disk cache, larger ones trigger a producer
    /// restart.
    private let backwardWindow: Int

    /// On-disk segment files, indexed by absolute segment number.
    /// Values are URLs to files inside `sessionDir`. Reads use mmap
    /// so the bytes don't sit in our heap.
    private var entries: [Int: URL] = [:]
    /// Per-index byte counts backing `_totalBytes`. Subtracting via a
    /// fresh stat of the entry's PATH was wrong whenever the same index
    /// was overwritten (store/adopt replace the file BEFORE the
    /// accounting runs, so the stat returned the NEW size and the old
    /// segment's bytes stayed counted forever). Diagnostics-only impact
    /// (memprobe cacheMB drifted upward), but the ledger makes the
    /// number trustworthy again.
    private var entryBytes: [Int: Int] = [:]

    /// Pinned init segment. Stays in RAM because it's tiny
    /// (~3.5 KB) and AVPlayer fetches it exactly once per session.
    /// Never evicted — identical bytes are valid for every fragment
    /// in the session (and across producer restarts, because the
    /// same stream configs deterministically reproduce the same
    /// moov / track IDs).
    private var initSegment: Data?

    /// True once `close()` has been called. Pending `fetch` calls
    /// wake up and return nil instead of looping forever.
    private var closed = false

    /// AVPlayer's current target segment index, declared by the
    /// provider at the top of each `mediaSegment(at:)` call. Both
    /// pruning and producer-backpressure read this. Not monotonic:
    /// a backward scrub legitimately moves the target back, so the
    /// cache window can slide either direction.
    private var currentTargetIndex: Int = -1

    /// Session-scoped scratch directory. Created on init, removed
    /// on `close()`. Naming includes a UUID so concurrent or
    /// crash-recovered sessions don't collide.
    let sessionDir: URL

    /// Cached cumulative byte count across all on-disk segments.
    /// Updated on every `store(index:data:)` and `pruneOutsideWindow()`.
    /// Read by the engine memprobe; kept here so the probe doesn't
    /// have to stat every file in the session directory on each tick.
    private var _totalBytes: Int = 0

    /// Highest segment index ever written into this cache, monotonic
    /// over the session. Updated by `store` and `adopt`, NOT
    /// decremented by `pruneOutsideWindow` — its purpose is to
    /// remember "the producer once wrote this far" after eviction
    /// has erased that signal from `indexRange()`. Used by
    /// `VideoSegmentProvider` to recognise gaps below the producer's
    /// write head and force a restart instead of waiting for a
    /// segment the current producer will never backfill. Reset by
    /// `close()`.
    private var _highestStoredIndex: Int = -1

    /// (10, 20)=30 entries. At 4K HDR HEVC segment sizes (~10 MB/seg)
    /// this holds ~300 MB on disk: 10 forward, 20 backward. The
    /// asymmetric weighting toward backward is intentional. The
    /// forward window has a hard cap from `bufferAheadSegments` on
    /// the producer (we don't want to race ahead of AVPlayer's
    /// playback head), but the backward window only costs disk and
    /// directly determines how often AVPlayer's backward refetches
    /// trigger a producer restart. With Continuous Audio Connection
    /// active on tvOS, AVPlayer commonly refetches ~7-10 segments
    /// backward for audio gapless handover to the HDMI sink. A small
    /// backward window made every such refetch cascade into a chain
    /// of restarts, each one resetting the audio bridge encoder PTS
    /// and producing audible glitches. 20 covers the observed
    /// backward range comfortably without doubling disk pressure.
    init(forwardWindow: Int = 10, backwardWindow: Int = 20) {
        self.forwardWindow = forwardWindow
        self.backwardWindow = backwardWindow

        // Scratch directory: <tmpdir>/aether-segments/<session-uuid>/
        // The intermediate `aether-segments` folder makes it easy
        // for `sweepStaleSessionDirs()` to find sibling directories
        // from previous (possibly crashed) sessions to clean up.
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aether-segments", isDirectory: true)
        let sessionID = UUID().uuidString
        self.sessionDir = baseDir.appendingPathComponent(sessionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDir,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            // Disk creation failed (probably out of space). The
            // cache will degrade to "no segments stored" mode which
            // surfaces as cache misses; the producer-restart path
            // will keep retrying. Better than crashing here.
            EngineLog.emit("[SegmentCache] session dir create failed at \(sessionDir.path): \(error)",
                           category: .session)
        }

        Self.sweepStaleSessionDirs(baseDir: baseDir, currentSession: sessionID)
    }

    /// Best-effort cleanup of session dirs left behind by previous
    /// process runs (crash / force-quit). Anything older than 1 hour
    /// is fair game. Called once at init.
    private static func sweepStaleSessionDirs(baseDir: URL, currentSession: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: baseDir,
                                                        includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries where entry.lastPathComponent != currentSession {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if created == nil || created! < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Writer side

    func setInit(_ data: Data) {
        condition.lock()
        initSegment = data
        condition.broadcast()
        condition.unlock()
    }

    func store(index: Int, data: Data) {
        let fileURL = sessionDir.appendingPathComponent("seg-\(index).m4s")
        let writeOK: Bool
        do {
            try data.write(to: fileURL, options: [.atomic])
            writeOK = true
        } catch {
            EngineLog.emit("[SegmentCache] write failed seg-\(index): \(error)",
                           category: .session)
            writeOK = false
        }

        condition.lock()
        defer { condition.unlock() }
        if writeOK {
            // If an old file existed at this index (rare: same index
            // written twice across a producer restart) the new write
            // overwrote it on disk via .atomic; just update the byte
            // accounting.
            if let oldBytes = entryBytes[index] {
                _totalBytes -= oldBytes
            }
            entries[index] = fileURL
            entryBytes[index] = data.count
            _totalBytes += data.count
            if index > _highestStoredIndex { _highestStoredIndex = index }
        }
        pruneOutsideWindow()
        condition.broadcast()
    }

    /// Adopt a fully-written staging file as the cache entry for
    /// `index` via `rename(2)`. The producer streams libavformat's
    /// muxer output straight to disk under our `sessionDir`, then
    /// calls this method at sink-close time. Rename keeps the bytes
    /// kernel-side: the page cache pages used while writing are
    /// preserved (warmed-up pages for the segment we're about to
    /// serve), and the rename itself is metadata-only. Compared to
    /// `store(index:data:)`, this skips a Swift Data round trip and
    /// keeps the segment out of our heap entirely.
    func adopt(index: Int, stagingPath: URL, byteCount: Int) {
        let fileURL = sessionDir.appendingPathComponent("seg-\(index).m4s")
        let renameOK: Bool
        do {
            // .replacing handles the rare same-index re-adopt
            // (producer restart over an existing entry) by clobbering
            // the previous file. Same-volume because both paths live
            // under sessionDir, so this is a metadata-only rename.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: stagingPath, to: fileURL)
            renameOK = true
        } catch {
            EngineLog.emit("[SegmentCache] adopt failed seg-\(index): \(error)",
                           category: .session)
            try? FileManager.default.removeItem(at: stagingPath)
            renameOK = false
        }

        condition.lock()
        defer { condition.unlock() }
        if renameOK {
            if let oldBytes = entryBytes[index] {
                _totalBytes -= oldBytes
            }
            entries[index] = fileURL
            entryBytes[index] = byteCount
            _totalBytes += byteCount
            if index > _highestStoredIndex { _highestStoredIndex = index }
        }
        pruneOutsideWindow()
        condition.broadcast()
    }

    func close() {
        condition.lock()
        closed = true
        let dir = sessionDir
        entries.removeAll(keepingCapacity: false)
        entryBytes.removeAll(keepingCapacity: false)
        initSegment = nil
        _totalBytes = 0
        _highestStoredIndex = -1
        condition.broadcast()
        condition.unlock()

        // Best-effort delete the whole session dir off-lock so we
        // don't block any pending fetch waiters longer than needed.
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Reader side

    /// Declare AVPlayer's current target segment index. Slides the
    /// cache window to centre on that target, deletes any files
    /// outside the new window, and wakes any pump worker waiting in
    /// `awaitFetchHighWater`. Called by the provider at the top of
    /// each `mediaSegment(at:)` so the cache learns the player's
    /// intent BEFORE the producer's restart-fires-and-immediately-
    /// evicts-its-own-output race window opens.
    func declareTarget(_ index: Int) {
        condition.lock()
        defer { condition.unlock() }
        if index != currentTargetIndex {
            currentTargetIndex = index
            pruneOutsideWindow()
            condition.broadcast()
        }
    }

    /// Non-blocking lookup. Returns the segment bytes via mmap; the
    /// kernel pages in on access and we never hold the full segment
    /// in our heap.
    func peek(index: Int) -> Data? {
        condition.lock()
        let fileURL = entries[index]
        condition.unlock()
        guard let url = fileURL else { return nil }
        return readMapped(url)
    }

    /// Non-blocking URL lookup. Returns the cache file URL without
    /// reading any bytes; used by the `sendfile(2)` fast path in the
    /// local server. Returns nil when the segment isn't yet cached.
    func peekURL(index: Int) -> URL? {
        condition.lock()
        defer { condition.unlock() }
        return entries[index]
    }

    /// Blocking lookup. Returns nil on timeout, on close, or when
    /// the producer never stores this index.
    func fetch(index: Int, timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        if let url = entries[index] {
            condition.unlock()
            return readMapped(url)
        }
        if closed {
            condition.unlock()
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, entries[index] == nil {
            if !condition.wait(until: deadline) { break }
        }
        let fileURL = entries[index]
        condition.unlock()
        guard let url = fileURL else { return nil }
        return readMapped(url)
    }

    /// Blocking init lookup. Same semantics as `fetch(index:)` but for
    /// the pinned init segment.
    func fetchInit(timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if let i = initSegment { return i }
        if closed { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, initSegment == nil {
            if !condition.wait(until: deadline) { break }
        }
        return initSegment
    }

    /// Pump-side backpressure: wait once for `target` to be reached,
    /// or for `timeout`, or for any explicit broadcast (declareTarget,
    /// store, wakeWaiters). One-shot: returns to the caller on the
    /// first wake-up event regardless of whether `target` was met, so
    /// the caller's outer loop can re-check its own cancellation
    /// state between waits. Returns `true` if the target is now met,
    /// `false` otherwise.
    func awaitFetchHighWater(reaching target: Int, timeout: TimeInterval = 1.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if currentTargetIndex >= target { return true }
        if closed { return false }
        let deadline = Date().addingTimeInterval(timeout)
        _ = condition.wait(until: deadline)
        return currentTargetIndex >= target
    }

    /// Evict all on-disk segments with index strictly `< cutoff`. Called
    /// by `VideoSegmentProvider.notePlaylistBuild` when the live playlist's
    /// firstVisible index advances; `cutoff` is that firstVisible. Because
    /// firstVisible is always `<= currentTargetIndex` (the playlist never
    /// drops a segment at or after the live edge AVPlayer is reading), this
    /// only removes segments the playlist has already dropped from the
    /// MEDIA-SEQUENCE window, so it cannot evict a not-yet-played forward
    /// segment. This keeps the on-disk footprint bounded to the DVR window
    /// in lockstep with the playlist (`pruneOutsideWindow` continues to
    /// bound the band around the target independently; for a live session
    /// the firstVisible cutoff is the tighter of the two on the back side).
    func evictBelow(_ cutoff: Int) {
        condition.lock()
        defer { condition.unlock() }
        for (k, url) in entries where k < cutoff {
            _totalBytes -= entryBytes[k] ?? byteSize(of: url)
            entryBytes.removeValue(forKey: k)
            entries.removeValue(forKey: k)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Sum of the actual on-disk sizes of all resident segment files
    /// (excluding the pinned init segment), freshly stat-ed rather than
    /// read from the running `_totalBytes` accumulator. The accumulator
    /// is the cheap steady-state path; this method gives an authoritative
    /// disk-footprint number for the harness / diagnostics where a stat
    /// per segment is acceptable. Bounded by the live window so it stays
    /// O(windowSegmentCount).
    func diskBytes() -> Int64 {
        condition.lock()
        let urls = Array(entries.values)
        condition.unlock()
        var total: Int64 = 0
        for url in urls {
            total += Int64(byteSize(of: url))
        }
        return total
    }

    /// Broadcast on the cache's condition variable without changing
    /// any state. Used by `HLSSegmentProducer.stop()` so any pump
    /// currently parked in `awaitFetchHighWater` returns immediately.
    func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Diagnostics

    /// AVPlayer's current target segment index (highest fetched), or
    /// -1 if no fetch has happened yet. Read by HLSVideoEngine's
    /// periodic-restart watchdog to compute the safe restart index
    /// (currentTarget + N where N is small enough that the cache still
    /// covers the lookahead window during the restart's setup gap).
    var targetIndex: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentTargetIndex
    }

    /// (lowestIndex, highestIndex) currently held, or nil when empty.
    /// Used by the restart-decision logic in `VideoSegmentProvider`.
    func indexRange() -> (Int, Int)? {
        condition.lock()
        defer { condition.unlock() }
        guard !entries.isEmpty else { return nil }
        let keys = entries.keys
        return (keys.min()!, keys.max()!)
    }

    /// Highest segment index the *current* producer has stored,
    /// monotonic across pruning but reset on every producer restart
    /// via `resetHighWaterForRestart()`. Returns -1 before the
    /// current producer's first store. `indexRange()` reports only
    /// currently-resident entries and loses the "producer wrote past
    /// here" signal once `pruneOutsideWindow` evicts the high end of
    /// the window; the restart-decision logic needs that signal to
    /// detect prune-created gaps no amount of waiting will backfill.
    /// Reset on restart so the previous producer's high-water doesn't
    /// keep the gate hot on every subsequent fetch (which cascades
    /// into a restart-per-segment storm that drains AVPlayer's
    /// buffer and stalls playback).
    var highestStoredIndex: Int {
        condition.lock()
        defer { condition.unlock() }
        return _highestStoredIndex
    }

    /// Reset the high-water mark. Called by `VideoSegmentProvider`
    /// immediately before triggering a producer restart so the new
    /// producer's writes seed a fresh counter. Without this, the
    /// previous producer's write head (often well above the new
    /// launch index) keeps `producerPassedAndPruned` hot on every
    /// subsequent fetch and a single legitimate restart cascades
    /// into a restart-per-segment storm.
    func resetHighWaterForRestart() {
        condition.lock()
        defer { condition.unlock() }
        _highestStoredIndex = -1
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return entries.count
    }

    /// Sum of all resident segment bytes (excluding the pinned init
    /// segment). With disk-backed storage this counts bytes on disk,
    /// not in RAM — useful for the memprobe so the disk pressure is
    /// visible alongside RSS.
    var totalBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return _totalBytes
    }

    // MARK: - Internal

    /// Drop any entries outside `[currentTarget - backwardWindow,
    /// currentTarget + forwardWindow]`. Bounds the on-disk cache to a
    /// fixed segment window centred on AVPlayer's declared target.
    /// Must be called with `condition` held.
    private func pruneOutsideWindow() {
        let lo = currentTargetIndex - backwardWindow
        // Forward bound: keep forwardWindow ahead of the target, but never
        // evict segments the current producer already wrote. A transient
        // backward refetch (AVPlayer re-pulling recent segments for audio
        // handover or a decode flush) drops currentTargetIndex back for one
        // request; if the forward bound collapsed to target+forwardWindow it
        // would evict already-produced forward segments the paused producer
        // won't backfill, turning the next forward request into a cache-miss
        // producer restart (re-mux with a fresh init.mp4 -> stall + audible
        // A/V discontinuity, repro: produce seg0..25, AVPlayer refetches
        // seg4 so target=4 prunes seg15+, then stalls when it reaches seg15).
        // Anchoring on _highestStoredIndex keeps produced-but-unconsumed
        // segments resident through the dip. Bounded: the producer paces
        // itself to target+forwardWindow, and resetHighWaterForRestart()
        // drops the high-water to -1 on a real (far-scrub) restart, so this
        // can only exceed target+forwardWindow transiently during a backward
        // dip, by at most the dip distance.
        let hi = max(currentTargetIndex + forwardWindow, _highestStoredIndex)
        for (k, url) in entries {
            if k < lo || k > hi {
                _totalBytes -= entryBytes[k] ?? byteSize(of: url)
                entryBytes.removeValue(forKey: k)
                entries.removeValue(forKey: k)
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Read a segment file as mmap-backed Data. The kernel pages in
    /// on access and frees on memory pressure; we never hold the
    /// full segment in our heap. Errors degrade to `nil` (cache miss);
    /// the caller handles that by retrying or restarting the producer.
    private func readMapped(_ url: URL) -> Data? {
        do {
            return try Data(contentsOf: url, options: [.alwaysMapped, .uncached])
        } catch {
            EngineLog.emit("[SegmentCache] mmap read failed \(url.lastPathComponent): \(error)",
                           category: .session)
            return nil
        }
    }

    /// On-disk size of a segment file. Cached size accounting only
    /// queries the file system when needed; in steady state `store`
    /// + `prune` keep `_totalBytes` accurate via Data.count and this
    /// path is a fallback.
    private func byteSize(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
