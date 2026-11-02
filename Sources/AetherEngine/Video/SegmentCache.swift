import Darwin
import Foundation

/// Sliding-window disk-backed cache for HLS-fMP4 segments. Bytes go to
/// <NSTemporaryDirectory>/aether-segments/<uuid>/seg-N-G.m4s; only URLs stay in RAM.
/// Reads use .alwaysMapped (kernel pages in/out under memory pressure). Window:
/// [currentTargetIndex - backwardWindow, currentTargetIndex + forwardWindow].
/// The producer pauses via awaitFetchHighWater once forwardWindow ahead of target.
// Thread-safe: all mutable state is guarded by `condition` (NSCondition), so it is safe to share
// across the producer/provider threads and capture in @Sendable closures.
final class SegmentCache: @unchecked Sendable {

    static let defaultBackwardWindow = 20

    struct StaleSweepResult: Sendable, Equatable {
        let inspectedCount: Int
        let removedCount: Int
        let failureCount: Int
    }

    /// AE#412: where a stored segment's first random-access point sits, as an offset from the
    /// segment's ADVERTISED start (its plan boundary). An offset, not an absolute time, so it is
    /// independent of the item / source / display axes and survives an epoch that opened early.
    ///
    /// `<= 0` means the segment opens on a sync sample and serves any position inside it. A positive
    /// offset means the first sync sample sits that far in, so only positions at or after it can
    /// start a decode run. `.none` means the segment carries no sync sample at all: audio cut it on
    /// a plan boundary the keyframe-gated cutter had folded, so nothing in it can start one.
    enum VideoReach: Equatable, Sendable {
        case syncAt(offsetSeconds: Double)
        case none

        /// Whether a cold arrival aiming `offsetSeconds` into this segment can be served from it.
        func serves(offsetSeconds: Double) -> Bool {
            guard case .syncAt(let syncOffset) = self else { return false }
            return syncOffset <= offsetSeconds
        }
    }

    private let condition = NSCondition()
    private let onResidentSetChanged: (@Sendable () -> Void)?

    private let forwardWindow: Int
    /// 20 covers Continuous-Audio handover refetches (~7-10 segments backward); smaller values
    /// cascaded into restart chains that reset the FLAC bridge PTS and caused audible glitches.
    private let backwardWindow: Int
    /// Byte budget for retaining segments OUTSIDE the hard window (#93 / Sodalite#32). While the
    /// cache's total footprint fits the budget, already-produced segments beyond the window stay
    /// resident (evicted farthest-from-target first once it fills), so a backward seek into watched
    /// content is a cache hit and never fires the producer restart that wedges slow sources (#93)
    /// and detaches AVKit's PiP legible renderer (Sodalite#32). 0 = window-only legacy pruning
    /// (live sessions, where the sliding playlist already dropped everything behind the window).
    private let retentionBudgetBytes: Int
    private let nativeLiveDVRPolicy: LiveDVRRetentionPolicy?
    private var nativeLiveRetentionFloor = 0
    private lazy var nativeLiveExpiryQueue = DispatchQueue(label: "com.aetherengine.live-expiry", qos: .utility)
    private var nativeLiveExpiryTimer: DispatchSourceTimer? // condition; opt-in, cancelled by close

    private var entries: [Int: URL] = [:]
    /// Per-index byte ledger for _totalBytes. Stat-on-eviction was wrong when same index was
    /// overwritten (stat returned new size, old bytes stayed counted forever).
    private var entryBytes: [Int: Int] = [:]

    /// Progressive delivery: the segments a producer is writing right now, index to staging file.
    /// Registered when the producer opens the segment (`beginInProgress`), removed when it is
    /// adopted or abandoned. A serve that finds its index here reads the staging file as it grows
    /// (`ProgressiveSegmentReader`) instead of waiting for the cut.
    private var inProgress: [Int: URL] = [:]
    /// The staging file each recently adopted segment was renamed from, and its final size, so a
    /// progressive reader can tell that the file IT holds was sealed, rather than the same index
    /// produced again by a later epoch. Keyed by staging file (unique per segment and epoch) and
    /// bounded to the most recent adoptions in adoption order: evicting by index dropped every
    /// adoption below the 64 highest at once, so after a backward seek each reader read as abandoned.
    private var sealedFromStaging: [URL: Int] = [:]
    private var sealedStagingOrder: [URL] = []

    /// Pinned in RAM (~3.5 KB); AVPlayer fetches exactly once per session; never evicted.
    private var initSegment: Data?

    /// Mid-session SSAI program-switch inits: (versionID, fromSegment, data). Version 0 = session init.
    private var initVersions: [(versionID: Int, fromSegment: Int, data: Data)] = []

    private var closed = false
    /// (index, bytes, parked) of every segment the producer completes, for the provider's
    /// march-rate estimate. `parked`: the producer waited on backpressure since the store before, so
    /// the interval measures the consumer, not the link. Guarded by `condition`, called after it is released.
    private var storeObserver: (@Sendable (Int, Int, Bool) -> Void)?
    /// Set by a backpressure or disk-headroom park, cleared by the next store. Guarded by `condition`.
    private var _parkedSinceStore = false
    private var _producerParked = false
    private var _evictionCount = 0
    private var _lastFailure: SessionCacheFailureReason?
    private var _lastCleanupReason: SessionCacheCleanupReason?
    private var _lastCleanupResult: SessionCacheCleanupResult = .notRun
    /// Declared by provider at top of each mediaSegment(at:); non-monotonic (backward scrub is valid).
    private var currentTargetIndex: Int = -1

    /// Lowest index of the consumer's current uninterrupted fetch sequence, and the highest index it has
    /// reached in it. A seek flushes the consumer's buffer, so only within one sequence does everything
    /// between the playhead and the target sit in that buffer, which is what
    /// `contiguousForwardFrontier(fromPlayhead:)` rests on.
    private var fetchFloor: Int = -1
    private var fetchFront: Int = -1

    let sessionDir: URL

    /// AE#451: the `SessionDirectoryLiveness` marker held for as long as this cache lives. -1 means
    /// unheld (open or flock failed); such a session is swept by age like before AE#451.
    private var lockFD: Int32 = -1

    private var _totalBytes: Int = 0

    /// Monotonic across prunes; NOT decremented by pruneOutsideWindow. Lets VideoSegmentProvider
    /// detect gaps below the producer's write head after eviction erases them from indexRange().
    private var _highestStoredIndex: Int = -1

    /// Audit SEG-4: every stored generation of an index gets its own file name, so a URL names exactly
    /// one set of bytes. A reader dropping a vanished entry, or a prune deleting a doomed one after
    /// unlocking, can then never hit a newer adoption of the same index.
    private var fileGeneration: UInt64 = 0

    private func nextSegmentFileURL(index: Int) -> URL {
        condition.lock()
        fileGeneration += 1
        let generation = fileGeneration
        condition.unlock()
        return sessionDir.appendingPathComponent("seg-\(index)-\(generation).m4s")
    }
    /// Plan index -> how many pumps passed it without opening a segment (#358). Survives producer
    /// restarts on purpose: the repeat across a restart is the signal.
    private var foldCounts: [Int: Int] = [:]
    /// AE#412: what a stored segment's video is worth to a COLD arrival, per index. Absent = the
    /// producer did not record it (live, or an unresolved time base), and callers must treat that
    /// as "no claim" rather than as bad news.
    private var videoReaches: [Int: VideoReach] = [:]
    /// #369: log-classification threshold: a run wider than this is a discontinuity-scale cut
    /// leap, not a long GOP. (It used to DROP such runs from the counters on the assumption they
    /// were repositions; the field case was a 2^33 wrap folding 312 indices, and dropping it left
    /// every fold counter at 0, which is exactly what disarms the #358 recovery arms.)
    static let maxFoldRunLength = 64

    /// The volume holding `sessionDir` ran out of space while this session wrote to it: the
    /// directory, a segment, or a muxer's staging file. Read when the pump gives up, so the failure
    /// names the full disk instead of the audio or the source, neither of which is at fault.
    /// Guarded by `condition`.
    private var storageExhaustedLatch = false

    var storageExhausted: Bool {
        condition.lock(); defer { condition.unlock() }
        return storageExhaustedLatch
    }

    func noteStorageExhausted() {
        condition.lock()
        let first = !storageExhaustedLatch
        storageExhaustedLatch = true
        condition.unlock()
        if first {
            EngineLog.emit("[SegmentCache] the segment volume is out of space at \(sessionDir.path)",
                           category: .session)
        }
    }

    /// A write that failed because the volume is full: `NSFileWriteOutOfSpaceError` from Foundation,
    /// `ENOSPC` from POSIX, or either one underneath a wrapping error.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    /// (10, 20)=30 entries, ~300 MB at 4K HDR HEVC ~10 MB/seg.
    init(
        forwardWindow: Int = 10,
        backwardWindow: Int = SegmentCache.defaultBackwardWindow,
        retentionBudgetBytes: Int = 0,
        baseDirectory: URL? = nil,
        sessionID: String = UUID().uuidString,
        now: Date = Date(),
        nativeLiveDVRPolicy: LiveDVRRetentionPolicy? = nil,
        onResidentSetChanged: (@Sendable () -> Void)? = nil
    ) {
        self.forwardWindow = forwardWindow
        self.backwardWindow = backwardWindow
        self.retentionBudgetBytes = retentionBudgetBytes
        self.nativeLiveDVRPolicy = nativeLiveDVRPolicy
        self.onResidentSetChanged = onResidentSetChanged

        // aether-segments/ prefix lets sweepStaleSessionDirs() find sibling dirs from crashed sessions.
        let baseDir = baseDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aether-segments", isDirectory: true)
        self.sessionDir = baseDir.appendingPathComponent(sessionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDir,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            _lastFailure = .sessionDirectoryCreationFailed
            EngineLog.emit("[SegmentCache] session dir create failed at \(sessionDir.path): \(error)",
                           category: .session)
            if Self.isOutOfSpace(error) { storageExhaustedLatch = true }
        }

        // Before the sweep, so a sibling constructed in the same breath cannot read this session
        // as unheld (AE#451). The age check covers the remaining microseconds: a directory this
        // young is never a sweep candidate.
        self.lockFD = Self.acquireLiveMarker(sessionDir: sessionDir)
        let sweep = Self.sweepStaleSessionDirs(baseDir: baseDir, currentSession: sessionID, now: now)
        if sweep.failureCount > 0 {
            _lastFailure = .staleSweepFailed
            EngineLog.emit(
                "[SegmentCache] bounded stale sweep: inspected=\(sweep.inspectedCount) "
                + "removed=\(sweep.removedCount) failures=\(sweep.failureCount)",
                category: .session
            )
        }
    }

    deinit {
        nativeLiveExpiryTimer?.cancel()
        releaseLiveMarker()
    }

    private static func acquireLiveMarker(sessionDir: URL) -> Int32 {
        SessionDirectoryLiveness.acquire(sessionDir: sessionDir, logPrefix: "[SegmentCache]")
    }

    private func releaseLiveMarker() {
        condition.lock()
        let fd = lockFD
        lockFD = -1
        condition.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Bounded crash-remnant cleanup. Only expired sibling directories are eligible; the current
    /// UUID and fresh sessions are never removed. Preserve upstream creation-time age and held-lock
    /// liveness checks. Both directory inspection and deletion are capped
    /// so a cache root with many crash remnants cannot create an unbounded startup I/O burst.
    static func sweepStaleSessionDirs(
        baseDir: URL,
        currentSession: String,
        now: Date = Date(),
        maxEntries: Int = 128,
        maxRemovals: Int = 16
    ) -> StaleSweepResult {
        let fm = FileManager.default
        guard maxEntries > 0, maxRemovals > 0 else {
            return StaleSweepResult(inspectedCount: 0, removedCount: 0, failureCount: 0)
        }
        var failures = 0
        guard let enumerator = fm.enumerator(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in failures += 1; return false }
        ) else {
            return StaleSweepResult(inspectedCount: 0, removedCount: 0, failureCount: max(1, failures))
        }

        let cutoff = now.addingTimeInterval(-3600)
        var inspected = 0
        var removed = 0
        while inspected < maxEntries, let entry = enumerator.nextObject() as? URL {
            inspected += 1
            guard entry.lastPathComponent != currentSession, removed < maxRemovals else { continue }
            let values: URLResourceValues
            do { values = try entry.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey]) }
            catch { failures += 1; continue }
            // An unreadable creation date counts as old, as before; liveness still spares a held one.
            guard values.isDirectory == true, (values.creationDate.map { $0 < cutoff } ?? true) else { continue }
            // Old does not mean abandoned: spare sessions whose marker is held (AE#451).
            if SessionDirectoryLiveness.isLive(entry) {
                EngineLog.emit("[SegmentCache] sweep spared live session dir \(entry.lastPathComponent)",
                               category: .session)
                continue
            }
            do {
                try fm.removeItem(at: entry)
                removed += 1
            } catch {
                failures += 1
            }
        }
        return StaleSweepResult(inspectedCount: inspected, removedCount: removed, failureCount: failures)
    }

    // MARK: - Writer side

    func setInit(_ data: Data) {
        condition.lock()
        initSegment = data
        condition.broadcast()
        condition.unlock()
    }

    /// Register fresh init at SSAI program switch valid from `fromSegment`. Idempotent on fromSegment.
    func addInitVersion(_ data: Data, fromSegment: Int) {
        condition.lock()
        defer { condition.unlock() }
        if let i = initVersions.firstIndex(where: { $0.fromSegment == fromSegment }) {
            initVersions[i].data = data
        } else {
            let nextID = (initVersions.map { $0.versionID }.max() ?? 0) + 1
            initVersions.append((versionID: nextID, fromSegment: fromSegment, data: data))
            initVersions.sort { $0.fromSegment < $1.fromSegment }
        }
        condition.broadcast()
    }

    func initVersionID(forSegment index: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        var id = 0
        for v in initVersions where v.fromSegment <= index { id = v.versionID }
        return id
    }

    func initData(versionID: Int) -> Data? {
        condition.lock(); defer { condition.unlock() }
        if versionID == 0 { return initSegment }
        return initVersions.first(where: { $0.versionID == versionID })?.data
    }

    /// AE#451: a write into a directory that is no longer there is not a dead session. Whatever
    /// removed it (a sibling's sweep on an older build, the OS reclaiming tmp) is outside this
    /// class, and without this a single deletion leaves the session permanently unable to store,
    /// so it never recovers by re-producing. Re-takes the live marker too: the old one went with
    /// the directory, and an unmarked directory is the next sweeper's candidate.
    private func restoreSessionDirIfMissing() -> Bool {
        condition.lock()
        let isClosed = closed
        condition.unlock()
        // A store racing close() must not resurrect the directory close() just deleted, and must
        // not leave a held marker behind that keeps the next sweep away from it.
        guard !isClosed else { return false }
        guard !FileManager.default.fileExists(atPath: sessionDir.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: sessionDir,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        } catch {
            EngineLog.emit("[SegmentCache] session dir restore failed at \(sessionDir.path): \(error)",
                           category: .session)
            if Self.isOutOfSpace(error) { noteStorageExhausted() }
            return false
        }
        releaseLiveMarker()
        let fd = Self.acquireLiveMarker(sessionDir: sessionDir)
        condition.lock()
        lockFD = fd
        condition.unlock()
        EngineLog.emit("[SegmentCache] session dir was deleted underneath a live session; restored (AE#451)",
                       category: .session)
        return true
    }

    @discardableResult
    func store(index: Int, data: Data) -> Bool {
        let fileURL = nextSegmentFileURL(index: index)
        var writeOK: Bool
        do {
            try data.write(to: fileURL, options: [.atomic])
            writeOK = true
        } catch {
            // The retry's own error decides: a missing directory restored onto a full volume fails
            // the second write with ENOSPC, behind a first error that only said the file was missing.
            var finalError: Error? = error
            if restoreSessionDirIfMissing() {
                do {
                    try data.write(to: fileURL, options: [.atomic])
                    finalError = nil
                } catch {
                    finalError = error
                }
            }
            if let finalError {
                EngineLog.emit("[SegmentCache] write failed seg-\(index): \(finalError)",
                               category: .session)
                if Self.isOutOfSpace(finalError) { noteStorageExhausted() }
                writeOK = false
                condition.lock()
                _lastFailure = .writeFailed
                condition.unlock()
            } else {
                writeOK = true
            }
        }
        condition.lock()
        // store racing close() must not resurrect bookkeeping; entry would point into deleted sessionDir.
        guard !closed else {
            condition.unlock()
            try? FileManager.default.removeItem(at: fileURL)
            return false
        }
        // A re-store of a resident index changes bytes, not residency; only an insertion or an
        // eviction moves the set, and both are already known here without walking it.
        var residentSetChanged = false
        var supersededFile: URL?
        if writeOK {
            if let oldBytes = entryBytes[index] {
                _totalBytes -= oldBytes
            }
            let superseded = entries.updateValue(fileURL, forKey: index)
            residentSetChanged = superseded == nil
            if let superseded { supersededFile = superseded }
            entryBytes[index] = data.count
            _totalBytes += data.count
            if index > _highestStoredIndex { _highestStoredIndex = index }
        }
        let doomed = pruneOutsideWindow()
        if !doomed.isEmpty { residentSetChanged = true }
        let observer = storeObserver
        let parked = _parkedSinceStore
        _parkedSinceStore = false
        condition.broadcast()
        condition.unlock()
        if let supersededFile { try? FileManager.default.removeItem(at: supersededFile) }
        for url in doomed { try? FileManager.default.removeItem(at: url) }
        if residentSetChanged { onResidentSetChanged?() }
        if writeOK { observer?(index, data.count, parked) }
        return writeOK
    }

    /// Adopt a staging file via rename(2). Page cache pages stay warm; skips a Swift Data round trip.
    ///
    /// `videoReach` (AE#412) is what this segment's video offers a cold arrival; nil leaves the
    /// previous claim in place only if the index is re-adopted without one, which no caller does.
    @discardableResult
    func adopt(index: Int, stagingPath: URL, byteCount: Int, videoReach: VideoReach? = nil) -> Bool {
        let fileURL = nextSegmentFileURL(index: index)
        var renameOK: Bool
        do {
            try FileManager.default.moveItem(at: stagingPath, to: fileURL)
            renameOK = true
        } catch {
            if restoreSessionDirIfMissing(),
               (try? FileManager.default.moveItem(at: stagingPath, to: fileURL)) != nil {
                renameOK = true
            } else {
                EngineLog.emit("[SegmentCache] adopt failed seg-\(index): \(error)",
                               category: .session)
                try? FileManager.default.removeItem(at: stagingPath)
                renameOK = false
                condition.lock()
                _lastFailure = .adoptFailed
                condition.unlock()
            }
        }
        condition.lock()
        // Sealed or not, this staging file is no longer being written.
        if inProgress[index] == stagingPath { inProgress.removeValue(forKey: index) }
        if renameOK {
            if sealedFromStaging.updateValue(byteCount, forKey: stagingPath) == nil {
                sealedStagingOrder.append(stagingPath)
            }
            while sealedStagingOrder.count > Self.sealedStagingMemory {
                sealedFromStaging.removeValue(forKey: sealedStagingOrder.removeFirst())
            }
        }
        guard !closed else {
            condition.broadcast()
            condition.unlock()
            try? FileManager.default.removeItem(at: fileURL)
            return false
        }
        var residentSetChanged = false
        var supersededFile: URL?
        if renameOK {
            if let oldBytes = entryBytes[index] {
                _totalBytes -= oldBytes
            }
            let superseded = entries.updateValue(fileURL, forKey: index)
            residentSetChanged = superseded == nil
            if let superseded { supersededFile = superseded }
            entryBytes[index] = byteCount
            _totalBytes += byteCount
            if index > _highestStoredIndex { _highestStoredIndex = index }
            // A later epoch produced what an earlier one passed over: a re-anchor moved the
            // boundaries and this index is no longer a hole (#358).
            foldCounts.removeValue(forKey: index)
            // AE#412: the claim describes THESE bytes, so a re-adoption replaces it, and an
            // adoption that cannot state one must not leave the old epoch's claim standing.
            videoReaches[index] = videoReach
        }
        let doomed = pruneOutsideWindow()
        if !doomed.isEmpty { residentSetChanged = true }
        let observer = storeObserver
        let parked = _parkedSinceStore
        _parkedSinceStore = false
        condition.broadcast()
        condition.unlock()
        if let supersededFile { try? FileManager.default.removeItem(at: supersededFile) }
        for url in doomed { try? FileManager.default.removeItem(at: url) }
        if residentSetChanged { onResidentSetChanged?() }
        if renameOK { observer?(index, byteCount, parked) }
        return renameOK
    }

    @discardableResult
    func close(reason: SessionCacheCleanupReason = .sessionStopped) -> SessionCacheCleanupResult {
        condition.lock()
        if closed {
            let prior = _lastCleanupResult
            condition.unlock()
            return prior
        }
        closed = true
        _lastCleanupReason = reason
        let expiryTimer = nativeLiveExpiryTimer
        nativeLiveExpiryTimer = nil
        let dir = sessionDir
        let hadEntries = !entries.isEmpty
        entries.removeAll(keepingCapacity: false)
        entryBytes.removeAll(keepingCapacity: false)
        videoReaches.removeAll(keepingCapacity: false)
        initSegment = nil
        initVersions.removeAll(keepingCapacity: false)
        inProgress.removeAll(keepingCapacity: false)
        sealedFromStaging.removeAll(keepingCapacity: false)
        sealedStagingOrder.removeAll(keepingCapacity: false)
        _totalBytes = 0
        _highestStoredIndex = -1
        _producerParked = false
        _parkedSinceStore = false
        condition.broadcast()
        condition.unlock()

        expiryTimer?.cancel()
        releaseLiveMarker()
        let result: SessionCacheCleanupResult
        do {
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
            result = .succeeded
        } catch {
            result = .failed
            EngineLog.emit("[SegmentCache] session cleanup failed: \(error)", category: .session)
        }
        condition.lock()
        _lastCleanupResult = result
        if result == .failed { _lastFailure = .cleanupFailed }
        condition.unlock()
        if hadEntries { onResidentSetChanged?() }
        return result
    }

    // MARK: - Reader side

    func declareTarget(_ index: Int) {
        condition.lock()
        var doomed: [URL] = []
        trackFetchSequenceLocked(index)
        if index != currentTargetIndex {
            currentTargetIndex = index
            doomed = pruneOutsideWindow()
            condition.broadcast()
        }
        condition.unlock()
        for url in doomed { try? FileManager.default.removeItem(at: url) }
        if !doomed.isEmpty { onResidentSetChanged?() }
    }

    /// Must be called with condition held.
    ///
    /// A fetch that leaves a gap above the front, or that drops further back than a handover refetch
    /// reaches, is the consumer arriving from somewhere else: it flushed its buffer and starts a new
    /// sequence here. Anything else extends the current one, including the ~7-10 segment backward
    /// refetch of the Continuous-Audio handover and its return to the front, which must NOT count as a
    /// jump: under an opt-in prefetch the playhead sits below the retained low end, so falling back to
    /// the playhead anchor there would re-open the #207 collapse the anchor exists to prevent.
    private func trackFetchSequenceLocked(_ index: Int) {
        if index > fetchFront + 1 || index < fetchFront - backwardWindow {
            fetchFloor = index
            fetchFront = index
        } else {
            fetchFront = max(fetchFront, index)
        }
    }

    func peek(index: Int) -> Data? {
        guard let url = peekURL(index: index) else { return nil }
        return readOrDrop(index: index, url: url)
    }

    /// AE#451: the bookkeeping is not the file, and this is where the bookkeeping is redeemed.
    ///
    /// Every caller reads this answer as "the segment is on disk": the server streams the URL it
    /// gets (a file that has gone answers a 404, which the #50 rule forbids for an in-range index
    /// and AVPlayer treats as terminal on VOD), the AE#421 wedge split asks it to tell a starved
    /// consumer from a silent one, and the byte ledger bills for it. So an entry whose file has
    /// gone stops answering here, and the producer is free to make it again.
    func peekURL(index: Int) -> URL? {
        condition.lock()
        let fileURL = entries[index]
        condition.unlock()
        guard let url = fileURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            dropVanishedEntry(index: index, url: url)
            return nil
        }
        return url
    }

    /// Forget an entry whose file is gone. Keeps `_highestStoredIndex`: it records how far the
    /// producer got, which an external deletion does not undo.
    private func dropVanishedEntry(index: Int, url: URL) {
        condition.lock()
        guard entries[index] == url else {
            condition.unlock()
            return
        }
        entries.removeValue(forKey: index)
        _totalBytes -= entryBytes.removeValue(forKey: index) ?? 0
        videoReaches.removeValue(forKey: index)
        condition.broadcast()
        condition.unlock()
        EngineLog.emit("[SegmentCache] seg-\(index) vanished from disk; entry dropped (AE#451)",
                       category: .session)
    }

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    func fetch(index: Int, timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        if let url = entries[index] {
            condition.unlock()
            return readOrDrop(index: index, url: url)
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
        return readOrDrop(index: index, url: url)
    }

    // MARK: - Progressive delivery

    /// How many adoptions `sealedFromStaging` remembers: enough for every reader still draining.
    static let sealedStagingMemory = 64

    /// The producer opened segment `index` in `stagingPath`, which from here on is only appended to
    /// until it is adopted under its final name.
    func beginInProgress(index: Int, stagingPath: URL) {
        condition.lock()
        if !closed {
            inProgress[index] = stagingPath
            condition.broadcast()
        }
        condition.unlock()
    }

    /// The producer gave up the segment it was writing (restart, failed cut, teardown), so its
    /// partial bytes are never adopted. A reader draining it learns that on its next poll.
    func abandonInProgress(index: Int) {
        condition.lock()
        if inProgress.removeValue(forKey: index) != nil { condition.broadcast() }
        condition.unlock()
    }

    enum InProgressState: Equatable {
        case writing
        case sealed(bytes: Int)
        case abandoned
    }

    /// What became of the staging file a progressive reader holds.
    func inProgressState(index: Int, stagingPath: URL) -> InProgressState {
        condition.lock()
        defer { condition.unlock() }
        if inProgress[index] == stagingPath { return .writing }
        if let bytes = sealedFromStaging[stagingPath] { return .sealed(bytes: bytes) }
        return .abandoned
    }

    /// `fetch` for the loopback server. With `progressive`, a segment that is being written is
    /// answered at once with a reader over its staging file, so AVPlayer receives each fragment as
    /// the muxer flushes it instead of the whole segment after its cut.
    func fetchSource(index: Int, timeout: TimeInterval, progressive: Bool) -> SegmentSource? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while true {
            if let url = entries[index] {
                condition.unlock()
                return readOrDrop(index: index, url: url).map { .data($0) }
            }
            if closed {
                condition.unlock()
                return nil
            }
            if progressive, let staging = inProgress[index] {
                condition.unlock()
                if let reader = ProgressiveSegmentReader(cache: self, index: index, stagingPath: staging) {
                    return .progressive(reader)
                }
                // The staging file was renamed or removed between the lookup and the open: look again.
                condition.lock()
                if inProgress[index] == staging { inProgress.removeValue(forKey: index) }
                continue
            }
            if !condition.wait(until: deadline) {
                condition.unlock()
                return nil
            }
        }
    }

    /// AE#451: a read that comes back empty for a file the bookkeeping still lists is the same lie
    /// `peekURL` guards against, and here it is load-bearing: this serve answers a retriable 503,
    /// and an entry left standing means every retry takes this branch again while the producer,
    /// which asks whether the segment is stored, is never told to make it.
    private func readOrDrop(index: Int, url: URL) -> Data? {
        guard let data = readMapped(url) else {
            dropVanishedEntry(index: index, url: url)
            return nil
        }
        return data
    }

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

    /// Pump-side backpressure: one-shot wait for target or any broadcast. Returns true if target met.
    func awaitFetchHighWater(reaching target: Int, timeout: TimeInterval = 1.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if currentTargetIndex >= target { return true }
        if closed { return false }
        _parkedSinceStore = true
        let deadline = Date().addingTimeInterval(timeout)
        _ = condition.wait(until: deadline)
        return currentTargetIndex >= target
    }

    /// Evict segments strictly below cutoff, which the live caller bounds at the consumer's own fetch
    /// point (`VideoSegmentProvider.liveEvictionFloor`) so this never unlinks the segment a response is
    /// about to stat; pruneOutsideWindow handles the forward bound.
    func evictBelow(_ cutoff: Int) {
        condition.lock()
        var doomed: [URL] = []
        for (k, url) in entries where k < cutoff {
            _totalBytes -= entryBytes[k] ?? byteSize(of: url)
            entryBytes.removeValue(forKey: k)
            entries.removeValue(forKey: k)
            doomed.append(url)
        }
        _evictionCount += doomed.count
        condition.unlock()
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
        if !doomed.isEmpty { onResidentSetChanged?() }
    }

    /// Authoritative disk footprint via fresh stat (not _totalBytes accumulator); diagnostics path.
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

    func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Diagnostics

    var targetIndex: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentTargetIndex
    }

    var producerParked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return _producerParked
    }

    var lastCleanupReason: SessionCacheCleanupReason? {
        condition.lock()
        defer { condition.unlock() }
        return _lastCleanupReason
    }

    var lastFailure: SessionCacheFailureReason? {
        condition.lock()
        defer { condition.unlock() }
        return _lastFailure
    }

    func status(
        route: SessionCacheRoute,
        requestedBudgetBytes: Int?,
        baseEffectiveBudgetBytes: Int,
        volumeSafetyLimitBytes: Int?,
        capability: SessionCacheCapability = .active
    ) -> SessionCacheStatus {
        condition.lock()
        defer { condition.unlock() }
        let lo = currentTargetIndex - backwardWindow
        let hi = max(currentTargetIndex + forwardWindow, _highestStoredIndex)
        var hardFloor = 0
        for (index, bytes) in entryBytes where index >= lo && index <= hi {
            hardFloor += bytes
        }
        let effective = max(baseEffectiveBudgetBytes, hardFloor)
        return SessionCacheStatus(
            route: route,
            capability: closed ? .inactive : capability,
            requestedBudgetBytes: requestedBudgetBytes,
            volumeSafetyLimitBytes: volumeSafetyLimitBytes,
            baseEffectiveBudgetBytes: baseEffectiveBudgetBytes,
            playbackSafeFloorBytes: hardFloor,
            effectiveBudgetBytes: effective,
            currentResidentBytes: _totalBytes,
            currentForwardBytes: currentForwardBytes(),
            forwardWindowSegments: forwardWindow,
            backwardWindowSegments: backwardWindow,
            producerParked: _producerParked,
            evictionCount: _evictionCount,
            hardWindowFloorExceeded: hardFloor > baseEffectiveBudgetBytes,
            cleanupReason: _lastCleanupReason,
            cleanupResult: _lastCleanupResult,
            lastFailure: _lastFailure
        )
    }

    /// How often a pump has passed a plan index without opening a segment for it (#358).
    ///
    /// The keyframe-gated cutter opens a segment at the IRAP that reaches a boundary, so a boundary
    /// no IRAP reaches is stepped over while the playlist keeps offering it. One fold is not proof of
    /// a dead index: a re-anchor rebases the producer, which moves the boundaries, and the index can
    /// come out producible (measured: a re-anchor at a different base filled exactly such a gap).
    /// A SECOND fold of the same index is the proof, because it is the recovery reproducing its own
    /// trigger. Cleared by `adopt` when the index does arrive.
    func foldCount(_ index: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return foldCounts[index] ?? 0
    }

    /// AE#412: what the stored segment at `index` offers a cold arrival, or nil when nothing was
    /// recorded for it (live, or a producer that could not resolve its time base). A caller must not
    /// read nil as "unreachable": an unrecorded segment is exactly today's behaviour, not a defect.
    func videoReach(_ index: Int) -> VideoReach? {
        condition.lock()
        defer { condition.unlock() }
        guard entries[index] != nil else { return nil }
        return videoReaches[index]
    }

    /// Record plan indices a cut jumped over. VOD only: a live playlist is built from what was
    /// finalized, so it never offers an index the pump skipped.
    /// #369: runs wider than `maxFoldRunLength` count too, the #358 arms exist precisely for a
    /// consumer that requests a folded index, and the widest folds are the ones most certain to
    /// produce such a request. Memory is one Int per folded index, bounded by the plan size.
    func noteFolded(_ indices: Range<Int>) {
        guard !indices.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        for index in indices where entries[index] == nil {
            foldCounts[index, default: 0] += 1
        }
    }

    func indexRange() -> (Int, Int)? {
        condition.lock()
        defer { condition.unlock() }
        guard !entries.isEmpty else { return nil }
        let keys = entries.keys
        return (keys.min()!, keys.max()!)
    }

    /// Contiguous runs of segment indexes that are resident on disk. A 2026-09-02 field session
    /// retained 64 segments across several islands, so min/max alone cannot describe the picture
    /// a host can truthfully mark as loaded.
    func residentIndexRanges() -> [ClosedRange<Int>] {
        condition.lock()
        defer { condition.unlock() }
        let indexes = entries.keys.sorted()
        guard let first = indexes.first else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var lower = first
        var upper = first
        for index in indexes.dropFirst() {
            if index == upper + 1 {
                upper = index
            } else {
                ranges.append(lower...upper)
                lower = index
                upper = index
            }
        }
        ranges.append(lower...upper)
        return ranges
    }

    /// Monotonic across prunes; reset per restart via resetHighWaterForRestart().
    /// indexRange() only shows resident entries and loses the signal after pruning the high end;
    /// highestStoredIndex retains it so VideoSegmentProvider can detect prune-created gaps.
    var highestStoredIndex: Int {
        condition.lock()
        defer { condition.unlock() }
        return _highestStoredIndex
    }

    /// Largest K such that every index in [startIdx ... K] is resident, walking forward until the first
    /// gap. Returns startIdx - 1 when startIdx itself is absent (nothing cached from there). Used to
    /// express the disk read-ahead frontier as a segment index. Thread-safe.
    func contiguousForwardFrontier(from startIdx: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return frontierLocked(from: startIdx)
    }

    /// Frontier of the contiguous *safe* range for a playhead at `playheadIdx`, anchored at
    /// `max(playheadIdx, currentTargetIndex)` (#207 follow-up).
    ///
    /// Walking from the playhead alone under-reports whenever the consumer's fetch target runs ahead of
    /// it: `pruneOutsideWindow` retains from `currentTargetIndex - backwardWindow` upward, so the
    /// playhead's own segment is an evictable extra, and an opt-in whole-source prefetch (which is the
    /// only case that reaches the retention budget) really does evict it. The walk then starts on a hole
    /// and reports nothing ahead while the whole band is resident.
    ///
    /// Anchoring on the fetch target is safe rather than merely optimistic: `declareTarget` is only ever
    /// called from the segment-serve path, so everything below `currentTargetIndex` has been handed to
    /// the consumer and sits in its own buffer. Skipping the leading hole *without* that bound would
    /// instead land on a stale band above a backward seek (nothing forces its eviction while the budget
    /// has room) and report it as buffered, which fails in the dangerous direction; anchoring at the new
    /// target stops the walk at the hole above the freshly produced segments. `max` keeps a backward
    /// refetch behind the playhead (Continuous-Audio handover) from dragging the anchor back.
    ///
    /// Anchor and walk share one lock hold: reading `targetIndex` separately would let a target change
    /// land between the two and walk from an anchor that does not match the entries observed.
    ///
    /// The target anchor only holds while the playhead is inside the consumer's current fetch sequence.
    /// AVPlayer fetches no further ahead than its own buffer reaches, which is what keeps everything
    /// between the playhead and the target genuinely held; a seek removes that bound, and since
    /// `declareTarget` lands at the destination before `currentTime()` reports it, the target would
    /// otherwise measure the band at the destination against the position the seek jumped away from and
    /// claim a lead the size of the seek distance (#207 field report on 5.23.4). Outside the sequence the
    /// walk falls back to the playhead, which reports the band that is genuinely reachable from there,
    /// or nothing when its own segment is gone.
    func contiguousForwardFrontier(fromPlayhead playheadIdx: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        let anchor = playheadIdx >= fetchFloor ? max(playheadIdx, currentTargetIndex) : playheadIdx
        return frontierLocked(from: anchor)
    }

    /// Must be called with condition held.
    private func frontierLocked(from startIdx: Int) -> Int {
        var k = startIdx
        while entries[k] != nil { k += 1 }
        return k - 1
    }

    /// AE#441: the mirror of `contiguousForwardFrontier`, walking DOWN. Smallest K such that every index
    /// in `K ... topIdx` is resident, or `topIdx + 1` when `topIdx` itself is absent (nothing to walk).
    ///
    /// This, not `indexRange().0`, is the honest floor of a rewind: `min ... max` is not proof of
    /// residency, because retained scrub bands leave interior holes (the same reason the segment-serve
    /// path refuses to treat that range as coverage). A floor advertised below a hole promises a rewind
    /// that cannot then play forward.
    func contiguousBackwardFloor(from topIdx: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        var k = topIdx
        while entries[k] != nil { k -= 1 }
        return k + 1
    }

    /// AE#441: the newest resident index, which is where a backward floor walk starts. `highestStoredIndex`
    /// is monotonic across prunes and would start the walk on a hole after the high end is pruned.
    var highestResidentIndex: Int? {
        condition.lock()
        defer { condition.unlock() }
        return entries.keys.max()
    }

    /// See `storeObserver`.
    func setStoreObserver(_ observer: (@Sendable (Int, Int, Bool) -> Void)?) {
        condition.lock()
        storeObserver = observer
        condition.unlock()
    }

    /// True when the producer parked on backpressure after its last store: the time since that store
    /// was spent waiting for the consumer, not writing.
    var parkedSinceLastStore: Bool {
        condition.lock()
        defer { condition.unlock() }
        return _parkedSinceStore
    }

    /// Reset before triggering a restart; previous producer's highWater would keep producerPassedAndPruned
    /// hot on every fetch, cascading a single restart into a per-segment storm.
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

    /// On-disk bytes (not RAM); useful for memprobe alongside RSS.
    var totalBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return _totalBytes
    }

    /// AE#443: mean on-disk size of a resident segment, which is what turns a window in seconds into a
    /// window in bytes (`LiveWindowSizing.affordableSegments`). nil while nothing is resident, so an
    /// empty cache states that it cannot answer rather than answering zero.
    var meanEntryBytes: Int? {
        condition.lock()
        defer { condition.unlock() }
        guard !entries.isEmpty, _totalBytes > 0 else { return nil }
        return Int(_totalBytes) / entries.count
    }

    /// On-disk bytes at or above the consumer's current target: what the producer's race-ahead owns
    /// (#207). Everything behind the playhead is either the small backward window or budget-evictable
    /// extras, so this is the only footprint an opt-in whole-source window grows without bound.
    var forwardBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return currentForwardBytes()
    }

    /// #207 producer park step: true once the producer may write `head`. Withheld while its race-ahead
    /// has reached `budgetBytes` and the consumer still has a safe lead behind it; the extras eviction
    /// that follows the advancing playhead is what frees the room again.
    func awaitPrefetchDiskHeadroom(head: Int, budgetBytes: Int, timeout: TimeInterval = 1.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if !shouldParkLocked(head: head, budgetBytes: budgetBytes) {
            _producerParked = false
            return true
        }
        _producerParked = true
        _parkedSinceStore = true
        _ = condition.wait(until: Date().addingTimeInterval(timeout))
        let released = !shouldParkLocked(head: head, budgetBytes: budgetBytes)
        _producerParked = !released
        return released
    }

    /// Must be called with condition held.
    private func shouldParkLocked(head: Int, budgetBytes: Int) -> Bool {
        PrefetchDiskBudget.shouldPark(forwardBytes: currentForwardBytes(),
                                      budgetBytes: budgetBytes,
                                      head: head,
                                      consumerTarget: currentTargetIndex)
    }

    /// Must be called with condition held.
    private func currentForwardBytes() -> Int {
        var bytes = 0
        for (k, b) in entryBytes where k >= currentTargetIndex { bytes += b }
        return bytes
    }

    /// Metadata-only admission from the host setter. Exactly one weakly-owned timer per opted-in
    /// cache; it progresses even when the pump is parked and AVPlayer makes no playlist requests.
    func startNativeLiveDVRExpiryChecks() {
        condition.lock()
        guard !closed, nativeLiveDVRPolicy != nil, nativeLiveExpiryTimer == nil else {
            condition.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: nativeLiveExpiryQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in _ = self?.reconcileExpiredNativeLiveDVRRetention() }
        nativeLiveExpiryTimer = timer
        timer.resume()
        condition.unlock()
    }

    /// Both the independent timer and the producer use this implementation. The cap is evaluated
    /// by the caller FIRST; then expiry pruning and the current entry count share this lock hold.
    /// An expired smaller cap cannot park a pump behind unpruned expanded history.
    @discardableResult
    func reconcileExpiredNativeLiveDVRRetention(headroomCap: Int? = nil) -> Bool {
        condition.lock()
        guard !closed else { condition.unlock(); return false }
        let expiredOrDenied = nativeLiveDVRPolicy?.snapshot?.retentionBytes == 0
        let doomed = expiredOrDenied ? pruneOutsideWindow() : []
        let hasHeadroom = headroomCap.map { entries.count < $0 } ?? true
        if !doomed.isEmpty { condition.broadcast() }
        condition.unlock()
        for url in doomed { try? FileManager.default.removeItem(at: url) }
        if !doomed.isEmpty { onResidentSetChanged?() }
        return hasHeadroom
    }

    /// Called off the main actor after a native limit update and each finalized live segment.
    func applyNativeLiveRetentionFloor(_ floor: Int) {
        condition.lock()
        nativeLiveRetentionFloor = max(nativeLiveRetentionFloor, floor)
        let doomed = pruneOutsideWindow()
        condition.broadcast()
        condition.unlock()
        for url in doomed { try? FileManager.default.removeItem(at: url) }
        if !doomed.isEmpty { onResidentSetChanged?() }
    }

    /// The finite exception consists of the consumer's existing handover/prefetch band and
    /// eight newest segments. No unbounded `[target ... highestStoredIndex]` exception for live.
    private func isNativeLiveMandatory(_ index: Int) -> Bool {
        let consumer = currentTargetIndex >= 0 &&
            index >= currentTargetIndex - backwardWindow && index <= currentTargetIndex + forwardWindow
        return consumer || index > _highestStoredIndex - LiveWindowSizing.minSafeSegments
    }

    var nativeLiveMandatoryBytes: Int {
        condition.lock(); defer { condition.unlock() }
        return entryBytes.reduce(0) { $0 + (isNativeLiveMandatory($1.key) ? $1.value : 0) }
    }

    // MARK: - Internal

    /// Prune to [currentTarget - backwardWindow, max(currentTarget + forwardWindow, highestStoredIndex)].
    /// Must be called with condition held.
    /// hi anchors on highestStoredIndex so a transient backward refetch (AVPlayer audio handover)
    /// doesn't evict already-produced forward segments (repro: seg0..25 produced, refetch seg4 -> target=4
    /// pruned seg15+, stalled when playback reached seg15).
    /// With a retention budget (#93 / Sodalite#32), entries outside that hard window survive,
    /// nearest-to-target first, while the cache's total footprint fits the budget; the window itself
    /// is never evicted even when it alone exceeds the budget. Nearest-first eviction from the far
    /// ends keeps each side of the resident span contiguous, so the provider's residency gate
    /// (a resident backward target = no producer restart) holds across the whole retained span.
    private func pruneOutsideWindow() -> [URL] {
        if let limits = nativeLiveDVRPolicy?.snapshot {
            var keptBytes = entryBytes.reduce(0) { $0 + (isNativeLiveMandatory($1.key) ? $1.value : 0) }
            var doomed: [URL] = []
            // Newest-first produces a contiguous playable suffix, even when an older consumer
            // band must remain pinned. The published DVR range already walks this suffix.
            for index in entries.keys.sorted(by: >) where !isNativeLiveMandatory(index) {
                let bytes = entryBytes[index] ?? 0
                if index >= nativeLiveRetentionFloor && bytes <= max(0, limits.retentionBytes - keptBytes) {
                    keptBytes += bytes
                } else if let url = entries.removeValue(forKey: index) {
                    _totalBytes -= bytes
                    entryBytes.removeValue(forKey: index)
                    videoReaches.removeValue(forKey: index)
                    doomed.append(url)
                }
            }
            return doomed
        }
        let lo = currentTargetIndex - backwardWindow
        let hi = max(currentTargetIndex + forwardWindow, _highestStoredIndex)
        var doomed: [URL] = []
        if retentionBudgetBytes > 0 {
            var extras: [(index: Int, bytes: Int)] = []
            var keptBytes = 0
            for (k, _) in entries {
                let bytes = entryBytes[k] ?? 0
                if k < lo || k > hi {
                    extras.append((k, bytes))
                } else {
                    keptBytes += bytes
                }
            }
            guard !extras.isEmpty else { return [] }
            extras.sort { abs($0.index - currentTargetIndex) < abs($1.index - currentTargetIndex) }
            for (k, bytes) in extras {
                if keptBytes + bytes <= retentionBudgetBytes {
                    keptBytes += bytes
                } else if let url = entries[k] {
                    _totalBytes -= bytes
                    entryBytes.removeValue(forKey: k)
                    entries.removeValue(forKey: k)
                    videoReaches.removeValue(forKey: k)
                    doomed.append(url)
                }
            }
            _evictionCount += doomed.count
            return doomed
        }
        for (k, url) in entries {
            if k < lo || k > hi {
                _totalBytes -= entryBytes[k] ?? byteSize(of: url)
                entryBytes.removeValue(forKey: k)
                entries.removeValue(forKey: k)
                videoReaches.removeValue(forKey: k)
                doomed.append(url)
            }
        }
        _evictionCount += doomed.count
        // Collected under the lock, deleted by the caller AFTER
        // unlocking: removeItem is filesystem I/O on the segment-serve
        // hot path (fetch waiters + the pump's backpressure wait park on
        // this condition; PacketRingBuffer's eviction uses the same
        // pattern). A racing reader that still resolves a doomed URL
        // degrades to an mmap miss -> nil, same as before.
        return doomed
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

/// A segment as the loopback server gets it: complete bytes, or a reader over one being written.
enum SegmentSource {
    case data(Data)
    case progressive(ProgressiveSegmentReader)
}

/// Reads a segment while its producer is still writing it.
///
/// The muxer appends each flushed fragment (moof+mdat) to the staging file and never rewrites what
/// it wrote, and adoption renames the file as it stands. So a descriptor opened on the staging file
/// reads a growing prefix of the final segment, the rename does not disturb it, and the read is
/// complete at the byte count the cache records for the adoption. A segment the producer abandons
/// reads as `.abandoned`, and the server closes the connection so AVPlayer asks for it again.
final class ProgressiveSegmentReader: @unchecked Sendable {
    let index: Int
    let stagingPath: URL
    private let fd: Int32
    private weak var cache: SegmentCache?
    private(set) var offset: Int64 = 0

    enum Next: Equatable {
        case bytes(Data)
        case finished
        case abandoned
    }

    init?(cache: SegmentCache, index: Int, stagingPath: URL) {
        let fd = open(stagingPath.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        self.fd = fd
        self.cache = cache
        self.index = index
        self.stagingPath = stagingPath
    }

    deinit { close(fd) }

    /// The next bytes past `offset`, waiting for the producer to write them. `.finished` once the
    /// sealed segment is read to its end; `.abandoned` when the producer gave it up, or wrote nothing
    /// for `idleTimeout` (a wedged producer must not hold a connection forever).
    func next(maxBytes: Int = 256 * 1024, pollInterval: TimeInterval = 0.02,
              idleTimeout: TimeInterval = 60) -> Next {
        let deadline = Date().addingTimeInterval(idleTimeout)
        while true {
            var st = stat()
            let statOK = fstat(fd, &st) == 0
            if statOK, st.st_size > offset {
                let count = Int(min(Int64(maxBytes), st.st_size - offset))
                var data = Data(count: count)
                let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
                if read > 0 {
                    if read < count { data.removeSubrange(read ..< count) }
                    offset += Int64(read)
                    return .bytes(data)
                }
            }
            switch cache?.inProgressState(index: index, stagingPath: stagingPath) ?? .abandoned {
            case .writing:
                break
            case .sealed(let bytes):
                if offset >= Int64(bytes) { return .finished }
                // The last fragment can land with the seal, after the stat above, so stat again and
                // read on. A file shorter than its recorded size is not a state to spin in.
                var sealedStat = stat()
                if fstat(fd, &sealedStat) == 0, sealedStat.st_size > offset { continue }
                return .abandoned
            case .abandoned:
                return .abandoned
            }
            if Date() >= deadline { return .abandoned }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// Reads to the seal, for a caller that needs the whole segment. nil when it was abandoned.
    func readToEnd() -> Data? {
        var all = Data()
        while true {
            switch next() {
            case .bytes(let d): all.append(d)
            case .finished: return all
            case .abandoned: return nil
            }
        }
    }
}
