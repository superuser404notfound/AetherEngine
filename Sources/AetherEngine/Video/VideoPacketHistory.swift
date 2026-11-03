import CoreMedia
import Darwin
import Foundation

/// A bounded on-disk history of the source packets a `VideoPacketTap` handed out, in the order the
/// segment producer wrote them.
///
/// The enhancement-layer route needs the enhancement layer of whatever AVPlayer shows next. AVPlayer
/// can be sent anywhere the segment cache holds (a backward seek into watched content is a cache hit and
/// the producer does not run again), so the packets cannot be consumed once as they are produced: the
/// history keeps them. They go to a ring file, not to memory, so the ring costs disk cache and no
/// footprint (the route as a whole is measured at about 1.6 GB), and the ring's size is the longest stretch
/// a seek can jump back over and still find its enhancement layer. A seek past it finds no keyframe in the
/// history and the picture is the base layer until the playhead reaches packets the ring holds, because
/// the segment cache serves the segments without the producer reading them again.
final class VideoPacketHistory: @unchecked Sendable {

    struct Entry: Equatable {
        /// Append order, consecutive. Decode order within a producer generation.
        let seq: UInt64
        /// Served presentation time in seconds (`NativeVideoFrameTime.item`).
        let item: Double
        /// Decode time in seconds on the same axis.
        let decode: Double
        let epoch: UInt64
        let isKeyframe: Bool
        fileprivate let offset: Int
        fileprivate let length: Int
    }

    static let defaultCapacityBytes = 1 << 30

    private let lock = NSLock()
    private let fd: Int32
    private let capacity: Int
    private var head = 0
    private var entries: [Entry] = []
    private var firstSeq: UInt64 = 0
    private var nextSeq: UInt64 = 0
    private var writeFailures = 0
    /// False until the first wrap: before it nothing can overlap, so the append skips the scan.
    private var wrapped = false

    /// Creates the ring in the temporary directory and unlinks it at once, so nothing outlives the process.
    init?(capacityBytes: Int = VideoPacketHistory.defaultCapacityBytes) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-fel-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(UUID().uuidString).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return nil }
        unlink(path)
        fd = descriptor
        capacity = max(capacityBytes, 1 << 20)
    }

    deinit { close(fd) }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var failedWrites: Int { lock.lock(); defer { lock.unlock() }; return writeFailures }

    /// Appends one packet. Returns its sequence number, or nil when the packet could not be stored.
    @discardableResult
    func append(_ bytes: UnsafeRawBufferPointer, item: CMTime, decode: CMTime, epoch: UInt64, isKeyframe: Bool) -> UInt64? {
        let length = bytes.count
        guard length > 0, length <= capacity, let base = bytes.baseAddress, item.isNumeric else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if head + length > capacity { head = 0; wrapped = true }
        var written = 0
        while written < length {
            let n = pwrite(fd, base + written, length - written, off_t(head + written))
            if n <= 0 { writeFailures += 1; return nil }
            written += n
        }
        // Evict everything the new bytes overwrote. The entries are in append order and `entry(seq:)` indexes
        // them by `seq - firstSeq`, so the sequence numbers must stay contiguous: drop every entry up to the
        // LAST one that overlaps, not only the leading run. A write that wraps early (the packet before it
        // left a gap at the end of the file) leaves older entries at the high offsets that the new bytes do
        // not touch, in front of newer entries at the low offsets that they do; stopping at the first
        // non-overlap kept the overwritten ones and served another packet's bytes as theirs.
        var lastOverlap = -1
        if wrapped {
            for (index, held) in entries.enumerated() where held.offset < head + length && head < held.offset + held.length {
                lastOverlap = index
            }
        }
        if lastOverlap >= 0 {
            entries.removeFirst(lastOverlap + 1)
            firstSeq += UInt64(lastOverlap + 1)
        }
        let entry = Entry(seq: nextSeq, item: CMTimeGetSeconds(item),
                          decode: decode.isNumeric ? CMTimeGetSeconds(decode) : CMTimeGetSeconds(item), epoch: epoch, isKeyframe: isKeyframe,
                          offset: head, length: length)
        if entries.isEmpty { firstSeq = entry.seq }
        entries.append(entry)
        nextSeq += 1
        head += length
        return entry.seq
    }

    func entry(seq: UInt64) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard seq >= firstSeq, seq < nextSeq, !entries.isEmpty else { return nil }
        return entries[Int(seq - firstSeq)]
    }

    /// The newest sequence number appended, or nil when nothing is held.
    var newestSeq: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return entries.isEmpty ? nil : nextSeq - 1
    }

    /// Reads an entry's bytes back. nil when it has been overwritten since.
    func read(_ entry: Entry) -> Data? {
        lock.lock()
        let stillHeld = entry.seq >= firstSeq && entry.seq < nextSeq
        lock.unlock()
        guard stillHeld else { return nil }
        var data = Data(count: entry.length)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var done = 0
            while done < entry.length {
                let n = pread(fd, base + done, entry.length - done, off_t(entry.offset + done))
                if n <= 0 { return false }
                done += n
            }
            return true
        }
        // A concurrent append may have overwritten the range while it was read.
        lock.lock()
        let intact = entry.seq >= firstSeq
        lock.unlock()
        return ok && intact ? data : nil
    }

    /// The keyframe to restart decoding from for a playhead at `seconds`: the held keyframe nearest below
    /// it (the later append wins a tie), if it is within `maximumLookBack` seconds. Nil means the history
    /// does not cover that position.
    ///
    /// `notBefore` skips keyframes older than that sequence number: a restart that must not land before a
    /// hole in the history (packets the history never stored), where decoding from the keyframe in front
    /// of the hole would run into the gap again.
    func restartPoint(atOrBefore seconds: Double, maximumLookBack: Double = 12, notBefore floor: UInt64 = 0) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var best: Entry?
        for entry in entries where entry.isKeyframe && entry.seq >= floor && entry.item <= seconds + 0.0005 {
            if let current = best {
                if entry.item > current.item || (entry.item == current.item && entry.seq > current.seq) { best = entry }
            } else {
                best = entry
            }
        }
        guard let best, seconds - best.item <= maximumLookBack else { return nil }
        return best
    }

    /// The span of served time the held packets cover, for logs.
    var coveredSeconds: ClosedRange<Double>? {
        lock.lock(); defer { lock.unlock() }
        guard let lo = entries.map(\.item).min(), let hi = entries.map(\.item).max() else { return nil }
        return lo...hi
    }
}
