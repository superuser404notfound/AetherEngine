import Darwin
import Foundation

/// Keyframe-indexed disk-spooled DVR ring buffer. Eviction is keyframe-aligned (once the ring has
/// evicted, the retained span starts at a decodable keyframe). Packet bytes are appended into a few
/// large chunk files under a scratch dir; the in-RAM index holds one 24-byte record per packet.
///
/// Audit PERF-101 / SEG-106: this used to write one atomically renamed file per packet and keep a
/// heap `URL` per index entry (554-586 B per entry measured, ~230 MB of index at a 90 min window, and
/// ~305 us of file work per packet). Audit VPERF-101: eviction was by time only and ran only after a
/// successful write, so a full disk stopped the ring, and with it the software live feeder, for good.
// Thread-safe: `lock` guards the index, the chunk table and the read-handle cache; `writeLock`
// serializes appends (tail chunk, tail offset). Lock order: writeLock, then lock.
final class PacketRingBuffer: @unchecked Sendable {

    // MARK: - Public types

    /// A single packet as returned by `packet(atSeq:)` and `packets(fromPts:)`.
    struct Packet {
        let pts: Double
        let isKeyframe: Bool
        let isVideo: Bool
        let bytes: Data
    }

    /// Writes all of `bytes` at `offset` or throws. Injectable so tests can fill the disk.
    typealias WriteAll = @Sendable (_ fd: Int32, _ bytes: UnsafeRawBufferPointer, _ offset: off_t) throws -> Void

    enum Failure: Error, Equatable {
        case closed
        case packetTooLarge
        case capacityExceeded
    }

    /// The software live route plays FROM this ring, so it is a playback buffer before it is seek
    /// history: the quarter-of-free-space retention rule may read 0 on a nearly full volume, and a
    /// ring that small evicts packets before the feeder reaches them. A disk that is really full is
    /// handled by the evict-and-retry in `append`.
    static let minimumLiveByteBudget = 64 << 20

    /// The native path's retention funnel (min(2 GiB, a quarter of free space)) with the live floor.
    /// A host's explicit `LoadOptions.liveDVRByteBudget` replaces the 2 GiB default and keeps the
    /// quarter-of-free-space clamp: a window meant to hold a whole recording in progress (hours of
    /// broadcast MPEG-2) does not fit in 2 GiB.
    static func liveByteBudget(volumeAvailableBytes: Int64?, capRelaxed: Bool = false,
                               requestedBytes: Int? = nil) -> Int {
        max(minimumLiveByteBudget,
            HLSVideoEngine.resolveSessionCacheBudget(requestedBytes: requestedBytes,
                                                     volumeAvailableBytes: volumeAvailableBytes,
                                                     capRelaxed: capRelaxed).baseEffectiveBytes)
    }

    // MARK: - Private types

    struct Entry {
        let pts: Double
        let offset: UInt32
        let length: UInt32
        let chunk: UInt32
        let flags: UInt8

        static let keyframeFlag: UInt8 = 1
        static let videoFlag: UInt8 = 2
        var isKeyframe: Bool { flags & Self.keyframeFlag != 0 }
        var isVideo: Bool { flags & Self.videoFlag != 0 }
    }

    /// Closed when the last holder lets go, so a reader that picked a handle up under the lock can
    /// finish its `pread` on a chunk that eviction unlinked meanwhile.
    private final class ChunkHandle: @unchecked Sendable {
        let id: UInt32
        let fd: Int32
        init(id: UInt32, fd: Int32) {
            self.id = id
            self.fd = fd
        }
        deinit { Darwin.close(fd) }
    }

    private struct ChunkRecord {
        let id: UInt32
        var bytes: Int
    }

    // MARK: - State

    private let lock = NSLock()
    private let writeLock = NSLock()
    private let windowSeconds: Double
    private let byteBudget: Int
    /// An opt-in capacity lease applies a strict startup and playback cap to this chunk spool.
    /// Callers without retention leases retain their original byteBudget behavior.
    private let strictRetention: Bool
    private let startupMaximumBytes: Int
    private let playbackCushionBytes: Int
    private let playbackCushionSeconds: Double
    private let retentionPolicy = LiveDVRRetentionPolicy()
    private let chunkTargetBytes: Int
    private let scratch: URL
    private let writeAll: WriteAll

    /// The retained span is `entries[head...]`; the dead prefix is compacted away in batches.
    private var entries: [Entry] = []
    private var head = 0
    /// Sequence number of `entries[head]`; eviction advances this instead of renumbering. Feeder cursor below `firstSeq` = fell out of window.
    private var firstSeq: Int = 0
    /// Absolute sequence numbers of retained keyframes, `keyframeSeqs[keyframeHead...]`. One per GOP,
    /// so eviction and keyframe lookups walk GOPs instead of packets.
    private var keyframeSeqs: [Int] = []
    private var keyframeHead = 0
    private var edge: Double = -.infinity
    private var closed: Bool = false
    /// Oldest first; the last record is the chunk the writer appends to.
    private var chunks: [ChunkRecord] = []
    private var retainedDiskBytes = 0
    private var residentBytes = 0
    private var awaitingKeyframe = false
    private var writesSuspended = false
    /// Most recently used first, at most `readHandleCap`. Opening a descriptor per retained chunk
    /// would hold hundreds at a 2 GiB budget.
    private var readHandles: [ChunkHandle] = []
    private static let readHandleCap = 4
    /// Audit SEG-105: the ring's directory sits beside the segment cache's under `aether-segments/`
    /// and must read as live to its stale sweep.
    private var markerFD: Int32 = -1

    // Writer state, guarded by `writeLock`.
    private var tail: ChunkHandle?
    private var tailOffset = 0
    private var nextChunkID: UInt32 = 0
    private var loggedOtherWriteFailure = false

    // MARK: - Init / close

    init(windowSeconds: Double, scratch: URL, byteBudget: Int = .max,
         retention: SoftwareDVRRetentionOptions? = nil, chunkTargetBytes: Int = 4 << 20,
         writeAll: WriteAll? = nil) throws {
        self.windowSeconds = windowSeconds
        self.scratch = scratch
        self.byteBudget = max(0, byteBudget)
        self.strictRetention = retention != nil
        self.startupMaximumBytes = max(1, min(retention?.startupMaximumBytes ?? .max, self.byteBudget))
        self.playbackCushionBytes = retention?.playbackCushionBytes ?? 0
        self.playbackCushionSeconds = retention?.playbackCushionSeconds ?? 0
        // A strict lease needs chunks smaller than its smallest startup cap, including tiny test
        // budgets. Callers without retention leases retain the normal 64 KiB minimum chunk size.
        let target = retention == nil
            ? min(chunkTargetBytes, max(64 << 10, self.byteBudget / 16))
            : min(chunkTargetBytes, max(1, self.startupMaximumBytes / 16))
        self.chunkTargetBytes = max(1, min(target, Int(UInt32.max / 2)))
        self.writeAll = writeAll ?? Self.pwriteAll
        self.markerFD = SessionDirectoryLiveness.acquire(sessionDir: scratch, logPrefix: "[PacketRingBuffer]")
    }

    deinit {
        if markerFD >= 0 { Darwin.close(markerFD) }
    }

    /// Idempotent teardown. State is cleared synchronously so the ring is immediately
    /// unusable; the scratch-directory removal is dispatched to a background queue so
    /// filesystem I/O never blocks the caller.
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        entries = []
        head = 0
        firstSeq = 0
        keyframeSeqs = []
        keyframeHead = 0
        edge = -.infinity
        chunks = []
        retainedDiskBytes = 0
        residentBytes = 0
        awaitingKeyframe = false
        readHandles = []
        let marker = markerFD
        markerFD = -1
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [scratch] in
            try? FileManager.default.removeItem(at: scratch)
            // Released after the removal, so the directory reads live until it is gone.
            if marker >= 0 { Darwin.close(marker) }
        }
    }

    // MARK: - Writer

    func append(pts: Double, isKeyframe: Bool, isVideo: Bool, bytes: Data) throws {
        try bytes.withUnsafeBytes { raw in
            try append(pts: pts, isKeyframe: isKeyframe, isVideo: isVideo, bytes: raw)
        }
    }

    /// Takes the packet's memory as is, so the host appends straight from the `AVPacket` without an
    /// intermediate copy.
    func append(pts: Double, isKeyframe: Bool, isVideo: Bool, bytes: UnsafeRawBufferPointer) throws {
        guard bytes.count <= Int(UInt32.max / 2) else { throw Failure.packetTooLarge }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else {
            tail = nil
            if strictRetention { return }
            throw Failure.closed
        }
        let limits = strictRetention ? retentionPolicy.snapshot : nil
        let cap = strictRetention
            ? min(byteBudget, limits.map { max(playbackCushionBytes, $0.retentionBytes) }
                            ?? startupMaximumBytes)
            : byteBudget
        if strictRetention {
            lock.lock()
            let suspended = writesSuspended
            let waiting = awaitingKeyframe
            lock.unlock()
            if suspended || (waiting && !(isVideo && isKeyframe)) { return }
            if bytes.count > cap {
                lock.lock()
                dropEntriesLocked(upTo: entries.count)
                let doomed = releaseUnreferencedChunksLocked(includingTail: true)
                awaitingKeyframe = true
                compactIfDueLocked()
                lock.unlock()
                tail = nil
                tailOffset = 0
                try deleteEvictedFiles(doomed)
                return
            }
        }

        let placement: (chunk: UInt32, offset: Int)
        do {
            placement = try writeLocked(bytes)
        } catch {
            // Audit VPERF-101: eviction used to run only after a successful write, so once the volume
            // filled, every append failed, nothing was ever freed, and the feeder waited at the live
            // edge forever. Shrink the window and try once more before dropping the packet. Only for a
            // full volume or quota: any other failure (no descriptors left, a purged tmp directory)
            // would evict real history on every packet and still fail.
            guard Self.isOutOfSpace(error) else {
                noteWriteFailureOnce(error)
                throw error
            }
            guard try makeRoomAfterFailedWrite(incomingKeyframe: isVideo && isKeyframe) else { throw error }
            placement = try writeLocked(bytes)
        }
        tailOffset = placement.offset + bytes.count

        var flags: UInt8 = 0
        if isKeyframe { flags |= Entry.keyframeFlag }
        if isVideo { flags |= Entry.videoFlag }
        let entry = Entry(pts: pts, offset: UInt32(placement.offset), length: UInt32(bytes.count),
                          chunk: placement.chunk, flags: flags)

        lock.lock()
        guard !closed else {
            lock.unlock()
            tail = nil
            throw Failure.closed
        }
        if isKeyframe { keyframeSeqs.append(firstSeq + (entries.count - head)) }
        entries.append(entry)
        residentBytes += bytes.count
        awaitingKeyframe = false
        if pts > edge { edge = pts }
        if let last = chunks.indices.last, chunks[last].id == placement.chunk {
            retainedDiskBytes += tailOffset - chunks[last].bytes
            chunks[last].bytes = tailOffset
        }
        let doomed = evictLocked(window: limits?.windowSeconds ?? (strictRetention && limits != nil ? playbackCushionSeconds : windowSeconds),
                                  maximumBytes: cap)
        let tailWasReleased = strictRetention && chunks.isEmpty
        lock.unlock()
        if tailWasReleased {
            tail = nil
            tailOffset = 0
        }
        try deleteEvictedFiles(doomed)
    }

    @discardableResult
    func setLimits(_ limits: LiveDVRLimits, availableBytes: Int64?) -> Bool {
        guard strictRetention else { return false }
        lock.lock()
        let resident = residentBytes
        lock.unlock()
        retentionPolicy.update(limits, availableBytes: availableBytes, residentBytes: resident)
        return true
    }

    var retainedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return residentBytes
    }

    var retainedWindowSeconds: Double? {
        guard oldestKeyframePts != nil else { return nil }
        if let limits = retentionPolicy.snapshot { return limits.windowSeconds }
        return windowSeconds
    }

    // MARK: - Reader

    func keyframePts(atOrBefore target: Double) throws -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return lastKeyframeIndexLocked(atOrBefore: target).map { entries[$0].pts }
    }

    /// Returns packets with `pts >= startPts`. Entries evicted between index snapshot and off-lock disk read are skipped (eviction is front-only, so skipping preserves keyframe alignment).
    func packets(fromPts startPts: Double) throws -> [Packet] {
        lock.lock()
        let start = firstSeq
        let seqs = entries[head...].indices.filter { entries[$0].pts >= startPts }.map { start + ($0 - head) }
        lock.unlock()

        var packets = seqs.compactMap { packet(atSeq: $0) }
        // Off-lock reads can race eviction: trim to the first video keyframe to guarantee a clean decode start.
        if packets.contains(where: { $0.isVideo }),
           let kf = packets.firstIndex(where: { $0.isVideo && $0.isKeyframe }) {
            if kf > 0 { packets.removeFirst(kf) }
        } else if packets.contains(where: { $0.isVideo }) {
            return []
        }
        return packets
    }

    // MARK: - Sequential consumption (live feeder)

    var seqBounds: (first: Int, end: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (firstSeq, firstSeq + (entries.count - head))
    }

    /// Whether `seq` is a video packet, from the index alone, or nil if evicted or not yet appended.
    /// Audit PERF-101: the audio pump and the feeder skip the other stream's packets through this,
    /// where they used to map every packet file only to read the flag.
    func isVideo(atSeq seq: Int) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return indexLocked(seq).map { entries[$0].isVideo }
    }

    /// Returns packet for `seq`, or nil if evicted, not yet appended, or unreadable. Index lock NOT held across the disk read.
    func packet(atSeq seq: Int) -> Packet? {
        lock.lock()
        guard let idx = indexLocked(seq) else {
            lock.unlock()
            return nil
        }
        let entry = entries[idx]
        let cached = cachedReadHandleLocked(entry.chunk)
        lock.unlock()
        guard let handle = cached ?? openReadHandle(entry.chunk),
              let bytes = Self.read(handle.fd, offset: entry.offset, length: entry.length) else { return nil }
        return Packet(pts: entry.pts, isKeyframe: entry.isKeyframe, isVideo: entry.isVideo, bytes: bytes)
    }

    func seq(forKeyframeAtOrBefore target: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return lastKeyframeIndexLocked(atOrBefore: target).map { firstSeq + ($0 - head) }
    }

    /// The first retained keyframe at or after `seq`, with its PTS, from the index alone (AE#844).
    func keyframe(atOrAfterSeq seq: Int) -> (seq: Int, pts: Double)? {
        lock.lock()
        defer { lock.unlock() }
        var low = keyframeHead
        var high = keyframeSeqs.count
        while low < high {
            let mid = (low + high) / 2
            if keyframeSeqs[mid] < seq { low = mid + 1 } else { high = mid }
        }
        guard low < keyframeSeqs.count, let idx = indexLocked(keyframeSeqs[low]) else { return nil }
        return (keyframeSeqs[low], entries[idx].pts)
    }

    /// The PTS of the packet at `seq`, from the index alone, or nil if evicted or not yet appended.
    func pts(atSeq seq: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return indexLocked(seq).map { entries[$0].pts }
    }

    /// Sequence of the EARLIEST retained keyframe, or nil if the ring holds no keyframe yet. DVR reseed
    /// floor when a target precedes every keyframe: seeding seqBounds.first (firstSeq) can land mid-GOP,
    /// since leading entries appended before the first eviction are not guaranteed keyframe-aligned.
    func firstKeyframeSeq() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return keyframeHead < keyframeSeqs.count ? keyframeSeqs[keyframeHead] : nil
    }

    // MARK: - Still runs (#544)

    /// One retained packet as the still planner sees it: no bytes, no file, just the three fields
    /// the decision needs.
    struct IndexEntry: Equatable {
        let pts: Double
        let isKeyframe: Bool
        let isVideo: Bool
    }

    /// The sequence span a still at `target` needs: from the newest video keyframe at or before it
    /// forward to the first video packet that reaches it, plus `reorderTail` further video packets.
    /// Nil when no keyframe at or before the target is retained, when the index holds no video, or
    /// when the span exceeds either bound.
    ///
    /// Two shapes decide the rules here. Packets are stored in DECODE order, so with B-frames the
    /// frame at the target can sit behind the first packet that reaches it, which is what the tail
    /// pays for. And a live scrub routinely aims a fraction past the newest packet, so a target
    /// beyond the end clamps to it rather than answering nil, which would blink the card out at
    /// exactly the edge the viewer sits on most.
    /// `indexReachesEnd` says whether `index` runs to the ring's newest entry. It is what separates
    /// the two ways the walk can run out of packets: the ring genuinely ending (clamp to it) from a
    /// caller's bounded window ending (refuse). Without it a truncated window silently returns a
    /// picture from before the requested time and calls it the answer.
    static func stillRunSpan(target: Double,
                             index: [IndexEntry],
                             firstSeq: Int,
                             maxPackets: Int,
                             maxSpanSeconds: Double,
                             reorderTail: Int,
                             indexReachesEnd: Bool) -> ClosedRange<Int>? {
        guard index.contains(where: \.isVideo) else { return nil }
        guard let start = index.indices.last(where: { index[$0].isKeyframe && index[$0].pts <= target })
        else { return nil }
        guard target - index[start].pts <= maxSpanSeconds else { return nil }

        let reached = index.indices[start...].first(where: { index[$0].isVideo && index[$0].pts >= target })
        guard reached != nil || indexReachesEnd else { return nil }
        guard var end = reached ?? index.indices.last(where: { index[$0].isVideo }) else { return nil }

        if reached != nil, reorderTail > 0 {
            var remaining = reorderTail
            var i = end + 1
            while i < index.count, remaining > 0 {
                if index[i].isVideo {
                    remaining -= 1
                    end = i
                }
                i += 1
            }
        }

        guard end >= start, end - start + 1 <= maxPackets else { return nil }
        return (firstSeq + start)...(firstSeq + end)
    }

    /// The video packets a still at `target` needs, keyframe-first. Nil when the target is not
    /// decodable from what the ring retains. Only the window the span can possibly cover is copied
    /// out under the lock: a 30 minute window holds ~150k entries and a still is asked for every
    /// 80 ms while a viewer holds the scrub.
    func stillRun(target: Double,
                  maxPackets: Int,
                  maxSpanSeconds: Double,
                  reorderTail: Int, isCancelled: (() -> Bool)? = nil) -> [Packet]? {
        guard target.isFinite, isCancelled?() != true else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        lock.lock()
        guard let startIdx = lastKeyframeIndexLocked(atOrBefore: target) else {
            lock.unlock()
            return nil
        }
        let upper = min(entries.count, startIdx + maxPackets + reorderTail + 1)
        let reachesEnd = upper == entries.count
        let window = entries[startIdx..<upper].map {
            IndexEntry(pts: $0.pts, isKeyframe: $0.isKeyframe, isVideo: $0.isVideo)
        }
        let base = firstSeq + (startIdx - head)
        lock.unlock()

        guard let span = Self.stillRunSpan(target: target, index: window, firstSeq: base,
                                           maxPackets: maxPackets, maxSpanSeconds: maxSpanSeconds,
                                           reorderTail: reorderTail,
                                           indexReachesEnd: reachesEnd) else { return nil }

        var run: [Packet] = []
        for seq in span {
            if isCancelled?() == true || (isCancelled != nil && ContinuousClock.now >= deadline) { return nil }
            if window[seq - base].isVideo, let packet = packet(atSeq: seq) { run.append(packet) }
        }
        // Eviction between the snapshot and the off-lock reads would cost the run its keyframe, and
        // a run that does not open on one decodes as garbage.
        guard let first = run.first, first.isKeyframe else { return nil }
        return run
    }

    // MARK: - Diagnostics

    var oldestPts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return head < entries.count ? entries[head].pts : nil
    }

    /// PTS of the earliest retained keyframe: the oldest position a DVR rewind can land on.
    var oldestKeyframePts: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard keyframeHead < keyframeSeqs.count, let idx = indexLocked(keyframeSeqs[keyframeHead]) else {
            return nil
        }
        return entries[idx].pts
    }

    /// The oldest position a rewind can land on, on the session axis, once eviction has taken history
    /// the window alone would have kept. nil until then, so a young session keeps its window arithmetic.
    /// Audit VPERF-101: the byte budget can shrink the ring below `windowSeconds`, and the transport rail
    /// must not advertise history that was evicted for space.
    func residentFloorSessionSeconds(sessionStartPts: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard firstSeq > 0, sessionStartPts.isFinite,
              keyframeHead < keyframeSeqs.count, let idx = indexLocked(keyframeSeqs[keyframeHead]) else {
            return nil
        }
        return max(0, entries[idx].pts - sessionStartPts)
    }

    /// Bytes the retained chunk files occupy, including the evicted prefix of the oldest chunk.
    var diskBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedDiskBytes
    }

    /// Heap the index occupies, dead prefix and spare capacity included.
    var indexFootprintBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.capacity * MemoryLayout<Entry>.stride + keyframeSeqs.capacity * MemoryLayout<Int>.stride
    }

    // MARK: - Internal

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func chunkURL(_ id: UInt32) -> URL {
        scratch.appendingPathComponent("chunk-\(id).bin", isDirectory: false)
    }

    private func indexLocked(_ seq: Int) -> Int? {
        let offset = seq - firstSeq
        guard !closed, offset >= 0, offset < entries.count - head else { return nil }
        return head + offset
    }

    private func lastKeyframeIndexLocked(atOrBefore target: Double) -> Int? {
        var k = keyframeSeqs.count
        while k > keyframeHead {
            k -= 1
            if let idx = indexLocked(keyframeSeqs[k]), entries[idx].pts <= target { return idx }
        }
        return nil
    }

    /// Writer side, `writeLock` held. Rolls to a fresh chunk when the packet would overflow a
    /// non-empty one, then writes it at the tail offset. Nothing moves on failure: a partial write
    /// is overwritten by the next attempt at the same offset.
    private func writeLocked(_ bytes: UnsafeRawBufferPointer) throws -> (chunk: UInt32, offset: Int) {
        if tail == nil || (tailOffset > 0 && tailOffset + bytes.count > chunkTargetBytes) {
            try rollChunkLocked()
        }
        guard let tail else { throw Failure.closed }
        try writeAll(tail.fd, bytes, off_t(tailOffset))
        return (tail.id, tailOffset)
    }

    private func rollChunkLocked() throws {
        guard nextChunkID < UInt32.max else { throw Failure.capacityExceeded }
        let id = nextChunkID
        let fd = open(chunkURL(id).path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        nextChunkID += 1
        let handle = ChunkHandle(id: id, fd: fd)
        tail = handle
        tailOffset = 0

        lock.lock()
        guard !closed else {
            lock.unlock()
            throw Failure.closed
        }
        chunks.append(ChunkRecord(id: id, bytes: 0))
        // Readers of the newest packets share the writer's descriptor.
        insertReadHandleLocked(handle)
        let doomed = releaseUnreferencedChunksLocked(includingTail: false)
        lock.unlock()
        try deleteEvictedFiles(doomed)
    }

    /// A write that failed because the volume or the quota has no room, which freeing a chunk can cure.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && (nsError.code == Int(ENOSPC) || nsError.code == Int(EDQUOT))
    }

    /// `writeLock` held. A failure that eviction cannot cure drops only its packet, so a steady one
    /// must not write a line per packet.
    private func noteWriteFailureOnce(_ error: Error) {
        guard !loggedOtherWriteFailure, error as? Failure != .closed else { return }
        loggedOtherWriteFailure = true
        EngineLog.emit("[PacketRingBuffer] write failed (\(error)); packet dropped, history kept "
                       + "(logged once)", category: .swPlayback)
    }

    /// `writeLock` held. Frees at least one chunk file while keeping the retained span on a keyframe:
    /// up to the first keyframe in a later chunk, or, when the incoming packet is itself a video
    /// keyframe that can open a fresh span, everything including the tail chunk. False when nothing
    /// could be freed, and the packet is dropped as before.
    private func makeRoomAfterFailedWrite(incomingKeyframe: Bool) throws -> Bool {
        lock.lock()
        var doomed: [URL] = []
        var releasedTail = false
        if let pivot = keyframeInLaterChunkLocked() {
            dropEntriesLocked(upTo: pivot)
            doomed = releaseUnreferencedChunksLocked(includingTail: false)
        } else if incomingKeyframe {
            dropEntriesLocked(upTo: entries.count)
            doomed = releaseUnreferencedChunksLocked(includingTail: true)
            releasedTail = chunks.isEmpty
        }
        compactIfDueLocked()
        lock.unlock()
        if releasedTail {
            tail = nil
            tailOffset = 0
        }
        try deleteEvictedFiles(doomed)
        if !doomed.isEmpty {
            EngineLog.emit("[PacketRingBuffer] write failed; freed \(doomed.count) chunk(s) and retrying "
                           + "(the rewind window shrinks instead of the live feed stopping)",
                           category: .swPlayback)
        }
        return !doomed.isEmpty
    }

    /// Evict by time, then by the effective host lease. A strict lease also bounds actual
    /// retained payload and chunk bytes; a GOP that cannot fit is dropped until its next keyframe.
    private func evictLocked(window: Double, maximumBytes: Int) -> [URL] {
        let cutoff = edge - window
        var pivot: Int? = nil
        var k = keyframeHead
        while k < keyframeSeqs.count, let idx = indexLocked(keyframeSeqs[k]), entries[idx].pts <= cutoff {
            pivot = idx
            k += 1
        }
        if let p = pivot, p > head { dropEntriesLocked(upTo: p) }
        var doomed = releaseUnreferencedChunksLocked(includingTail: false)

        if strictRetention {
            while residentBytes > maximumBytes || retainedDiskBytes > maximumBytes {
                if let p = nextRetainedKeyframeIndexLocked() {
                    dropEntriesLocked(upTo: p)
                    doomed += releaseUnreferencedChunksLocked(includingTail: false)
                } else {
                    dropEntriesLocked(upTo: entries.count)
                    doomed += releaseUnreferencedChunksLocked(includingTail: true)
                    awaitingKeyframe = true
                    break
                }
            }
        } else {
            // The standalone ring's soft byte budget remains unchanged.
            while retainedDiskBytes > byteBudget, chunks.count > 1 {
                if let p = keyframeInLaterChunkLocked() {
                    dropEntriesLocked(upTo: p)
                } else if retainedDiskBytes - byteBudget > byteBudget,
                          let p = firstIndexInLaterChunkLocked() {
                    dropEntriesLocked(upTo: p)
                } else {
                    break
                }
                let freed = releaseUnreferencedChunksLocked(includingTail: false)
                if freed.isEmpty { break }
                doomed += freed
            }
        }
        compactIfDueLocked()
        return doomed
    }

    private func nextRetainedKeyframeIndexLocked() -> Int? {
        var k = keyframeHead
        while k < keyframeSeqs.count {
            if let idx = indexLocked(keyframeSeqs[k]), idx > head { return idx }
            k += 1
        }
        return nil
    }

    private func dropEntriesLocked(upTo idx: Int) {
        guard idx > head else { return }
        for entry in entries[head..<idx] { residentBytes -= Int(entry.length) }
        firstSeq += idx - head
        head = idx
        while keyframeHead < keyframeSeqs.count, keyframeSeqs[keyframeHead] < firstSeq { keyframeHead += 1 }
        if head >= entries.count { awaitingKeyframe = true }
    }

    /// The first retained keyframe stored in a later chunk than the oldest retained entry.
    private func keyframeInLaterChunkLocked() -> Int? {
        guard head < entries.count else { return nil }
        let headChunk = entries[head].chunk
        var k = keyframeHead
        while k < keyframeSeqs.count {
            if let idx = indexLocked(keyframeSeqs[k]), entries[idx].chunk > headChunk { return idx }
            k += 1
        }
        return nil
    }

    private func firstIndexInLaterChunkLocked() -> Int? {
        guard head < entries.count else { return nil }
        let headChunk = entries[head].chunk
        var i = head + 1
        while i < entries.count {
            if entries[i].chunk > headChunk { return i }
            i += 1
        }
        return nil
    }

    /// Chunks wholly before the oldest retained entry. The tail stays unless asked for, because the
    /// writer is still appending to it.
    private func releaseUnreferencedChunksLocked(includingTail: Bool) -> [URL] {
        let floorChunk: UInt32? = head < entries.count ? entries[head].chunk : nil
        var doomed: [URL] = []
        while let first = chunks.first,
              chunks.count > 1 || includingTail,
              floorChunk.map({ first.id < $0 }) ?? true {
            chunks.removeFirst()
            retainedDiskBytes -= first.bytes
            readHandles.removeAll { $0.id == first.id }
            doomed.append(chunkURL(first.id))
        }
        return doomed
    }

    /// Batched, so the dead prefix costs one memmove per few minutes of packets rather than one per GOP.
    private func compactIfDueLocked() {
        if head >= 1024, head * 8 >= entries.count - head {
            entries.removeSubrange(0..<head)
            head = 0
        }
        if keyframeHead >= 256, keyframeHead * 8 >= keyframeSeqs.count - keyframeHead {
            keyframeSeqs.removeSubrange(0..<keyframeHead)
            keyframeHead = 0
        }
    }

    private func cachedReadHandleLocked(_ chunk: UInt32) -> ChunkHandle? {
        guard let i = readHandles.firstIndex(where: { $0.id == chunk }) else { return nil }
        let handle = readHandles[i]
        if i > 0 {
            readHandles.remove(at: i)
            readHandles.insert(handle, at: 0)
        }
        return handle
    }

    private func insertReadHandleLocked(_ handle: ChunkHandle) {
        readHandles.removeAll { $0.id == handle.id }
        readHandles.insert(handle, at: 0)
        if readHandles.count > Self.readHandleCap { readHandles.removeLast() }
    }

    private func openReadHandle(_ chunk: UInt32) -> ChunkHandle? {
        let fd = open(chunkURL(chunk).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = ChunkHandle(id: chunk, fd: fd)
        lock.lock()
        if !closed, let first = chunks.first, let last = chunks.last, first.id <= chunk, chunk <= last.id {
            insertReadHandleLocked(handle)
        }
        lock.unlock()
        return handle
    }

    private static func read(_ fd: Int32, offset: UInt32, length: UInt32) -> Data? {
        let count = Int(length)
        if count == 0 { return Data() }
        guard let buffer = malloc(count) else { return nil }
        var done = 0
        while done < count {
            let n = pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if n > 0 {
                done += n
            } else if n < 0, errno == EINTR {
                continue
            } else {
                free(buffer)
                return nil
            }
        }
        return Data(bytesNoCopy: buffer, count: count, deallocator: .free)
    }

    static let pwriteAll: WriteAll = { fd, bytes, offset in
        guard var base = bytes.baseAddress else { return }
        var remaining = bytes.count
        var at = offset
        while remaining > 0 {
            let n = pwrite(fd, base, remaining, at)
            if n > 0 {
                base += n
                remaining -= n
                at += off_t(n)
            } else if n < 0, errno == EINTR {
                continue
            } else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(n < 0 ? errno : EIO))
            }
        }
    }

    /// The strict host cannot keep writing if a failed unlink would leave orphaned disk bytes.
    private func deleteEvictedFiles(_ urls: [URL]) throws {
        if !strictRetention {
            for url in urls { unlink(url.path) }
            return
        }
        for url in urls {
            if unlink(url.path) == 0 || errno == ENOENT { continue }
            let failure = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            lock.lock()
            writesSuspended = true
            lock.unlock()
            throw failure
        }
    }
}
