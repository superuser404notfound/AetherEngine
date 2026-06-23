import Foundation

/// Keyframe-indexed disk-spooled DVR ring buffer. Eviction is keyframe-aligned (retained span always starts at a decodable keyframe). Bytes stored as flat files under a scratch dir; in-RAM index holds only metadata; `Data(contentsOf:,.alwaysMapped)` keeps RSS flat. NSLock guards the index (demux-thread appends, seek-thread reads).
// Thread-safe: all mutable state is guarded by `lock` (NSLock), so it is safe to share across the
// demux/seek/feeder threads and capture in @Sendable closures.
final class PacketRingBuffer: @unchecked Sendable {

    // MARK: - Public types

    /// A single packet as returned by `packets(fromPts:)`.
    struct Packet {
        let pts: Double
        let isKeyframe: Bool
        let isVideo: Bool
        let bytes: Data
    }

    // MARK: - Private types

    private struct Entry {
        let pts: Double
        let isKeyframe: Bool
        let isVideo: Bool
        let fileURL: URL
        let byteCount: Int
    }

    // MARK: - State

    private let lock = NSLock()
    private let windowSeconds: Double
    private let scratch: URL

    private var entries: [Entry] = []
    /// Sequence number of `entries[0]`; eviction advances this instead of renumbering. Feeder cursor below `firstSeq` = fell out of window.
    private var firstSeq: Int = 0
    private var counter: Int = 0
    private var edge: Double = -.infinity

    // MARK: - Init / close

    init(windowSeconds: Double, scratch: URL) throws {
        self.windowSeconds = windowSeconds
        self.scratch = scratch
    }

    func close() {
        lock.lock()
        let toDelete = entries.map(\.fileURL)
        entries.removeAll(keepingCapacity: false)
        edge = -.infinity
        counter = 0
        firstSeq = 0
        lock.unlock()

        for url in toDelete {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: scratch)  // best-effort; may have stale files from a previous partial write
    }

    // MARK: - Writer

    func append(pts: Double, isKeyframe: Bool, isVideo: Bool, bytes: Data) throws {
        let fileURL = scratch.appendingPathComponent("pkt-\(nextCounter()).bin")
        try bytes.write(to: fileURL, options: [.atomic])
        let entry = Entry(pts: pts, isKeyframe: isKeyframe, isVideo: isVideo, fileURL: fileURL, byteCount: bytes.count)

        lock.lock()
        entries.append(entry)
        if pts > edge { edge = pts }
        let evictedURLs = evictLocked()
        lock.unlock()

        for url in evictedURLs {  // delete outside the lock; removeItem is filesystem I/O
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Reader

    func keyframePts(atOrBefore target: Double) throws -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries
            .filter { $0.isKeyframe && $0.pts <= target }
            .last
            .map(\.pts)
    }

    /// Returns packets with `pts >= startPts`. Entries evicted between index snapshot and off-lock disk read are skipped (eviction is front-only, so skipping preserves keyframe alignment).
    func packets(fromPts startPts: Double) throws -> [Packet] {
        lock.lock()
        let slice = entries.filter { $0.pts >= startPts }
        lock.unlock()

        var packets = slice.compactMap { entry -> Packet? in
            guard let data = try? Data(contentsOf: entry.fileURL, options: [.alwaysMapped, .uncached]) else {
                return nil
            }
            return Packet(pts: entry.pts, isKeyframe: entry.isKeyframe, isVideo: entry.isVideo, bytes: data)
        }
        // Off-lock reads can race deferred eviction deletions: trim to the first video keyframe to guarantee a clean decode start.
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
        return (firstSeq, firstSeq + entries.count)
    }

    /// Returns packet for `seq`, or nil if evicted or not yet appended. Index lock NOT held across the disk read.
    func packet(atSeq seq: Int) -> Packet? {
        lock.lock()
        let idx = seq - firstSeq
        guard idx >= 0, idx < entries.count else {
            lock.unlock()
            return nil
        }
        let entry = entries[idx]
        lock.unlock()
        guard let data = try? Data(contentsOf: entry.fileURL,
                                   options: [.alwaysMapped, .uncached]) else { return nil }
        return Packet(pts: entry.pts, isKeyframe: entry.isKeyframe,
                      isVideo: entry.isVideo, bytes: data)
    }

    func seq(forKeyframeAtOrBefore target: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries.indices
            .last(where: { entries[$0].isKeyframe && entries[$0].pts <= target })
            .map { firstSeq + $0 }
    }

    /// Sequence of the EARLIEST retained keyframe, or nil if the ring holds no keyframe yet. DVR reseed
    /// floor when a target precedes every keyframe: seeding seqBounds.first (firstSeq) can land mid-GOP,
    /// since leading entries appended before the first eviction are not guaranteed keyframe-aligned.
    func firstKeyframeSeq() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries.indices
            .first(where: { entries[$0].isKeyframe })
            .map { firstSeq + $0 }
    }

    // MARK: - Diagnostics

    var oldestPts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first.map(\.pts)
    }

    // MARK: - Internal

    private func nextCounter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let c = counter
        counter += 1
        return c
    }

    /// Drop leading entries outside `edge - windowSeconds`, keyframe-aligned. Forward scan: backward scan walked ~150k entries per append at 80 pkt/s; forward scan touches a few hundred at most. Caller deletes returned URLs after releasing the lock.
    private func evictLocked() -> [URL] {
        let cutoff = edge - windowSeconds
        var pivot: Int? = nil
        var i = 0
        while i < entries.count, entries[i].pts <= cutoff {
            if entries[i].isKeyframe { pivot = i }
            i += 1
        }
        guard let p = pivot, p > 0 else { return [] }
        let urls = entries[..<p].map(\.fileURL)
        entries.removeSubrange(..<p)
        firstSeq += p
        return urls
    }
}
