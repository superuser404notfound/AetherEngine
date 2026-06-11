import Foundation

/// A keyframe-indexed, disk-spooled sliding-window ring of compressed
/// packets for the software-decode DVR rewind buffer.
///
/// Packets arrive forward-only from the demux loop via `append`. Old
/// packets are evicted once they fall outside `windowSeconds` behind the
/// current edge, but eviction never cuts to a non-keyframe: the retained
/// span always starts at a decodable keyframe. Rewind reads packets back
/// via `packets(fromPts:)`, which rehydrates bytes from disk lazily.
///
/// Disk layout mirrors SegmentCache: each packet is written as a flat
/// file under the caller-supplied scratch directory, named by a
/// monotonically increasing counter. The in-RAM index holds only the
/// metadata tuple; actual bytes are read back through
/// `Data(contentsOf:, options: .alwaysMapped)` so the kernel manages
/// paging without inflating the process RSS.
///
/// Thread-safety: a single NSLock guards the index. The real caller
/// appends on the demux thread and reads on the seek thread; all public
/// methods lock on entry.
final class PacketRingBuffer {

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

    /// Ordered by pts (append-order; pts is expected to be monotonically
    /// non-decreasing from the demux loop).
    private var entries: [Entry] = []

    /// Sequence number of `entries[0]`. Every appended packet gets a
    /// stable, monotonically increasing sequence number (`firstSeq + i`
    /// for `entries[i]`); eviction advances `firstSeq` instead of
    /// renumbering. The live feeder consumes the ring through these
    /// numbers (`packet(atSeq:)`), so its cursor survives eviction
    /// races: a cursor below `firstSeq` simply means "fell out of the
    /// window".
    private var firstSeq: Int = 0

    /// Monotonic counter used to produce unique file names.
    private var counter: Int = 0

    /// Highest pts seen so far (the live edge of the buffer).
    private var edge: Double = -.infinity

    // MARK: - Init / close

    /// Create a new ring buffer.
    /// - Parameters:
    ///   - windowSeconds: How many seconds of packets to retain behind
    ///     the current edge. Eviction is keyframe-aligned: the oldest
    ///     retained packet is the newest keyframe at or before
    ///     `edge - windowSeconds`.
    ///   - scratch: A caller-managed directory to hold packet files.
    ///     The caller is responsible for creating it; `close()` removes
    ///     its contents and the directory itself.
    init(windowSeconds: Double, scratch: URL) throws {
        self.windowSeconds = windowSeconds
        self.scratch = scratch
    }

    /// Remove all packet files and clear the index. Safe to call from
    /// any thread.
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
        // Best-effort remove the scratch dir itself (may still have
        // stale files from a previous close or partial write).
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Writer

    /// Append a compressed packet to the ring.
    /// - Parameters:
    ///   - pts: Presentation timestamp in seconds.
    ///   - isKeyframe: Whether this packet starts a decodable group.
    ///     Only ever true for video keyframes; audio packets pass false.
    ///   - isVideo: Whether the packet belongs to the video stream. The
    ///     reseed path replays both video and audio, and a video
    ///     non-keyframe is otherwise indistinguishable from an audio
    ///     packet, so the stream identity is recorded here for routing.
    ///   - bytes: Raw compressed packet bytes.
    func append(pts: Double, isKeyframe: Bool, isVideo: Bool, bytes: Data) throws {
        // Write to disk outside the lock so we don't block readers.
        let fileURL = scratch.appendingPathComponent("pkt-\(nextCounter()).bin")
        try bytes.write(to: fileURL, options: [.atomic])
        let entry = Entry(pts: pts, isKeyframe: isKeyframe, isVideo: isVideo, fileURL: fileURL, byteCount: bytes.count)

        lock.lock()
        entries.append(entry)
        if pts > edge { edge = pts }
        let evictedURLs = evictLocked()
        lock.unlock()

        // File deletion off-lock: removeItem is filesystem I/O and was
        // previously holding the lock against the feeder/seek readers.
        for url in evictedURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Reader

    /// The newest keyframe pts at or before `target`, or nil if none
    /// exists in the current window.
    func keyframePts(atOrBefore target: Double) throws -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries
            .filter { $0.isKeyframe && $0.pts <= target }
            .last
            .map(\.pts)
    }

    /// All packets with `pts >= pts`, in order, with bytes read from
    /// disk. Entries whose backing file was evicted between the index
    /// snapshot and the off-lock read are skipped instead of failing the
    /// whole reseed (`packet(atSeq:)` handles the identical race the
    /// same way). Eviction only removes from the FRONT of the window, so
    /// skipping evicted leading entries preserves the keyframe-alignment
    /// guarantee of what remains.
    func packets(fromPts startPts: Double) throws -> [Packet] {
        lock.lock()
        let slice = entries.filter { $0.pts >= startPts }
        lock.unlock()

        return slice.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.fileURL, options: [.alwaysMapped, .uncached]) else {
                return nil
            }
            return Packet(pts: entry.pts, isKeyframe: entry.isKeyframe, isVideo: entry.isVideo, bytes: data)
        }
    }

    // MARK: - Sequential consumption (live feeder)

    /// `(first, end)` sequence bounds of the currently retained span:
    /// `first` is the oldest retained packet's sequence number, `end`
    /// the next number a future append will get. Empty ring: first == end.
    var seqBounds: (first: Int, end: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (firstSeq, firstSeq + entries.count)
    }

    /// The packet with sequence number `seq`, or nil when it has been
    /// evicted (`seq < seqBounds.first`) or not yet appended
    /// (`seq >= seqBounds.end`). Bytes are rehydrated from disk
    /// (kernel-paged mmap); the index lock is NOT held across the read.
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

    /// Sequence number of the newest video keyframe with pts <= target,
    /// or nil when no such keyframe is retained. Used by the DVR seek to
    /// move the feeder cursor onto a decodable access point.
    func seq(forKeyframeAtOrBefore target: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries.indices
            .last(where: { entries[$0].isKeyframe && entries[$0].pts <= target })
            .map { firstSeq + $0 }
    }

    // MARK: - Diagnostics

    /// PTS of the oldest retained packet, or nil when the buffer is empty.
    var oldestPts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first.map(\.pts)
    }

    /// PTS of the newest retained packet, or nil when the buffer is empty.
    var newestPts: Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last.map(\.pts)
    }

    // MARK: - Internal

    private func nextCounter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let c = counter
        counter += 1
        return c
    }

    /// Drop leading entries outside the retention window, keeping the
    /// retained span keyframe-aligned. Must be called with `lock` held.
    ///
    /// Algorithm:
    ///   cutoff = edge - windowSeconds
    ///   Find the newest keyframe whose pts <= cutoff.
    ///   If such a keyframe exists, drop everything STRICTLY before it
    ///   (i.e. the keyframe itself is the new oldest entry).
    ///   If no such keyframe exists, keep everything.
    ///
    /// This guarantees `oldestPts` is always a keyframe pts that is <=
    /// cutoff (when the buffer is large enough), so a decoder starting
    /// from `oldestPts` always begins at a clean access point.
    /// Returns the file URLs of evicted entries; the CALLER deletes them
    /// after releasing the lock.
    ///
    /// Forward scan from the front instead of `last(where:)` over the
    /// whole index: the previous backward scan walked from the newest
    /// entry down to the pivot near the front on EVERY append, i.e.
    /// nearly the entire index (a 1800 s window at ~80 pkts/s is ~150 k
    /// entries, scanned 80x per second on the demux thread). The
    /// evictable prefix is bounded by one GOP past the cutoff, so the
    /// forward scan touches a few hundred entries at most.
    private func evictLocked() -> [URL] {
        let cutoff = edge - windowSeconds
        // Walk the prefix of entries at or before the cutoff, remembering
        // the newest keyframe in it. (PTS within the prefix is only
        // loosely ordered across streams / B-frames, but the prefix scan
        // evicts strictly contiguous leading entries, which is exactly
        // the keyframe-aligned guarantee the reseed relies on.)
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
