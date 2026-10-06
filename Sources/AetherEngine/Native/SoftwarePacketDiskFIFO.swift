import Darwin
import Foundation

/// A session-owned, disk-backed FIFO of opaque compressed-packet records.
///
/// Payloads and record lengths live on disk, not in an in-memory packet index. Only head/tail
/// offsets and aggregate counters are retained, independent of the number of packets/chunks.
/// Call all I/O methods from background workers: the lock intentionally serializes disk access
/// with reset/close. The caller owns byte/time backpressure and packet serialization.
final class SoftwarePacketDiskFIFO: @unchecked Sendable {
    /// An immutable record boundary, valid only while its chunk remains in this reset generation.
    /// Clients can index keyframes by token without retaining packet payloads or forging offsets.
    struct Cursor: Hashable, Sendable {
        let chunkID: UInt64
        fileprivate let generation: UUID
        fileprivate let offset: UInt64
        fileprivate let recordIndex: Int
        fileprivate let payloadPrefix: Int
    }

    struct StaleSweepResult: Sendable {
        let inspectedCount: Int
        let removedCount: Int
        let failureCount: Int
    }

    struct Snapshot: Sendable {
        let count: Int
        /// Payload bytes not yet popped; excludes record headers and the consumed head prefix.
        let byteCount: Int
        /// Logical file bytes, including headers, consumed prefixes and opt-in retained history.
        let diskByteCount: Int
        /// Includes consumed history in retained mode; unlike byteCount, this is a residency limit.
        var residentByteCount: Int { diskByteCount }
        let chunkCount: Int
        /// Tokens in smaller chunks have been evicted and must be removed from a client's index.
        let oldestRetainedChunkID: UInt64?
        let isClosed: Bool
        let hasFailure: Bool
    }

    enum Failure: Error, Equatable {
        case invalidChunkTarget
        case closed
        case corruptRecord
        case capacityExceeded
        case sessionLeaseLost
        case retentionDisabled
        case invalidCursor
    }

    static let directoryPrefix = "aether-software-packets-"
    private static let liveMarkerName = "session.lock"

    /// Always an explicitly created, unique child, never the caller's parent directory.
    let storageDirectory: URL
    let staleSweepResult: StaleSweepResult
    private let chunkTargetBytes: Int
    private let retainConsumed: Bool
    private let lock = NSLock()
    private var writer: FileHandle?
    private var reader: FileHandle?
    /// An open-file-description lock also protects against other sessions in this process.
    /// Unlike an age-only marker, the kernel releases it when a process crashes.
    private var leaseFD: Int32 = -1
    private var pendingChunkID: UInt64?
    private var generation = UUID()
    private var oldestChunkID: UInt64 = 0
    private var headID: UInt64 = 0
    private var tailID: UInt64 = 0
    private var headOffset: UInt64 = 0
    private var tailBytes: UInt64 = 0
    private var sealedHeadBytes: UInt64?
    private var recordCount = 0
    private var payloadBytes = 0
    private var diskBytes = 0
    private var chunks = 0
    /// Monotonic append prefixes let a restored cursor compute unread counts in constant space.
    private var writtenRecordCount = 0
    private var writtenPayloadBytes = 0
    private var isClosed = false
    /// A partial disk operation cannot be retried as if it had succeeded. Only reset recovers it.
    private var failure: (any Error)?

    init(chunkTargetBytes: Int = 4 * 1024 * 1024,
         retainConsumed: Bool = false,
         parentDirectory: URL = FileManager.default.temporaryDirectory,
         now: Date = Date(),
         leaseAcquisition: ((URL) throws -> Int32)? = nil) throws {
        guard chunkTargetBytes >= 8 else { throw Failure.invalidChunkTarget }
        self.chunkTargetBytes = chunkTargetBytes
        self.retainConsumed = retainConsumed
        storageDirectory = parentDirectory.appendingPathComponent(
            "\(Self.directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        // mkdir, not createDirectory's existing-directory success: cleanup must own this root.
        guard mkdir(storageDirectory.path, 0o700) == 0 else { throw Self.posixError() }
        do {
            // The injectable acquisition is used only by focused interrupted-init tests.
            leaseFD = try (leaseAcquisition ?? Self.acquireNewLease)(storageDirectory)
            guard leaseFD >= 0 else { throw Failure.sessionLeaseLost }
        } catch {
            try? FileManager.default.removeItem(at: storageDirectory)
            if leaseFD >= 0 { Darwin.close(leaseFD) }
            throw error
        }
        staleSweepResult = Self.sweepStaleSessionDirs(parentDirectory: parentDirectory,
            currentSession: storageDirectory.lastPathComponent, now: now)
    }

    deinit {
        try? close()
        // A failed best-effort removal must not leak the advisory lease descriptor.
        if leaseFD >= 0 { Darwin.close(leaseFD) }
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(count: recordCount, byteCount: payloadBytes, diskByteCount: diskBytes,
                        chunkCount: chunks, oldestRetainedChunkID: chunks > 0 ? oldestChunkID : nil,
                        isClosed: isClosed, hasFailure: failure != nil)
    }

    @discardableResult
    func append(_ data: Data) throws -> Cursor {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        do {
            let recordBytes = try checkedSum(data.count, 8)
            let nextCount = try checkedSum(recordCount, 1)
            let nextPayloadBytes = try checkedSum(payloadBytes, data.count)
            let nextDiskBytes = try checkedSum(diskBytes, recordBytes)
            let nextWrittenCount = try checkedSum(writtenRecordCount, 1)
            let nextWrittenBytes = try checkedSum(writtenPayloadBytes, data.count)
            if writer == nil {
                try openFirstChunk()
            } else if tailBytes > 0,
                      UInt64(recordBytes) > UInt64(chunkTargetBytes) - min(tailBytes, UInt64(chunkTargetBytes)) {
                try openNextChunk()
            }
            guard let writer else { throw Failure.corruptRecord }
            let cursor = Cursor(chunkID: tailID, generation: generation, offset: tailBytes,
                                recordIndex: writtenRecordCount, payloadPrefix: writtenPayloadBytes)
            try Self.writeRecord(data, to: writer.fileDescriptor)
            tailBytes += UInt64(recordBytes)
            recordCount = nextCount
            payloadBytes = nextPayloadBytes
            diskBytes = nextDiskBytes
            writtenRecordCount = nextWrittenCount
            writtenPayloadBytes = nextWrittenBytes
            return cursor
        } catch {
            failure = error
            throw error
        }
    }

    func pop() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        guard recordCount > 0 else { return nil }
        do {
            var limit = try currentReadLimit()
            // A retained reader can be at the old tail's EOF when the producer rolls to a new
            // chunk. Crossing that boundary must neither return false EOF nor remove history.
            if retainConsumed, headOffset == limit, headID < tailID {
                try advanceRetainedHead()
                limit = try currentReadLimit()
            }
            guard let reader else { throw Failure.corruptRecord }
            guard headOffset <= limit, limit - headOffset >= 8 else { throw Failure.corruptRecord }
            let length = try Self.readRecordLength(from: reader)
            guard length <= UInt64(payloadBytes), length <= limit - headOffset - 8 else {
                throw Failure.corruptRecord
            }
            let data = try readExactly(Int(length), from: reader)
            let nextOffset = headOffset + 8 + length
            if nextOffset == limit {
                if retainConsumed {
                    headOffset = nextOffset
                    if headID < tailID { try advanceRetainedHead() }
                } else {
                    try reclaimHead(byteCount: limit)
                }
            } else {
                headOffset = nextOffset
            }
            recordCount -= 1
            payloadBytes -= Int(length)
            return data
        } catch {
            failure = error
            throw error
        }
    }

    /// Move only the consumer cursor; the producer, resident bytes and forward frontier survive.
    /// Rejected stale/cross-session tokens do not poison a healthy store, so callers can fall back
    /// to their normal uncached seek. Disk corruption/I/O failures still fail closed.
    func restore(to cursor: Cursor) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        guard retainConsumed else { throw Failure.retentionDisabled }
        guard cursor.generation == generation, chunks > 0,
              cursor.chunkID >= oldestChunkID, cursor.chunkID <= tailID,
              cursor.recordIndex >= 0, cursor.recordIndex < writtenRecordCount,
              cursor.payloadPrefix >= 0, cursor.payloadPrefix <= writtenPayloadBytes else {
            throw Failure.invalidCursor
        }
        do {
            let replacement = try FileHandle(forReadingFrom: chunkURL(cursor.chunkID))
            var adopted = false
            defer { if !adopted { try? replacement.close() } }
            let size = try replacement.seekToEnd()
            guard cursor.offset <= size, size - cursor.offset >= 8 else { throw Failure.corruptRecord }
            try replacement.seek(toOffset: cursor.offset)
            let length = try Self.readRecordLength(from: replacement)
            guard length <= size - cursor.offset - 8,
                  length <= UInt64(writtenPayloadBytes - cursor.payloadPrefix) else {
                throw Failure.corruptRecord
            }
            try replacement.seek(toOffset: cursor.offset)
            try reader?.close()
            reader = replacement
            adopted = true
            headID = cursor.chunkID
            headOffset = cursor.offset
            sealedHeadBytes = headID < tailID ? size : nil
            recordCount = writtenRecordCount - cursor.recordIndex
            payloadBytes = writtenPayloadBytes - cursor.payloadPrefix
        } catch {
            failure = error
            throw error
        }
    }

    /// AE#605: walks retained records from `cursor` on without touching the consumer's reader, so a
    /// scrub still can decode out of history while playback keeps reading its own position.
    ///
    /// The lock is held only to validate the cursor and to snapshot the tail. The disk reads run
    /// outside it on handles of their own, because a GOP is megabytes and the producer and the
    /// consumer both serialize on this lock. That is safe for two reasons: an unlinked chunk stays
    /// readable through a handle opened before the unlink, and the tail is read only up to the
    /// length snapshotted here, never into a record still being written. What it cannot see is a
    /// reset recreating the same chunk names underneath it, so the generation is checked again
    /// once the walk ends, and a walk that raced a reset throws `invalidCursor` AFTER visiting: the
    /// caller discards whatever it collected. `visit` returns false to stop early. Failures never
    /// poison the store: a still is optional, playback is not.
    func readHistory(from cursor: Cursor, visit: (Data) throws -> Bool) throws {
        lock.lock()
        do { try requireUsable() } catch { lock.unlock(); throw error }
        guard retainConsumed else { lock.unlock(); throw Failure.retentionDisabled }
        guard cursor.generation == generation, chunks > 0,
              cursor.chunkID >= oldestChunkID, cursor.chunkID <= tailID,
              cursor.recordIndex >= 0, cursor.recordIndex < writtenRecordCount else {
            lock.unlock()
            throw Failure.invalidCursor
        }
        let lastChunk = tailID
        let lastChunkBytes = tailBytes
        lock.unlock()

        var chunkID = cursor.chunkID
        var offset = cursor.offset
        walk: while chunkID <= lastChunk {
            guard let handle = try? FileHandle(forReadingFrom: chunkURL(chunkID)) else {
                throw Failure.invalidCursor
            }
            defer { try? handle.close() }
            let limit = chunkID == lastChunk ? lastChunkBytes : try handle.seekToEnd()
            try handle.seek(toOffset: offset)
            while offset < limit {
                guard limit - offset >= 8 else { throw Failure.corruptRecord }
                let length = try Self.readRecordLength(from: handle)
                guard length <= limit - offset - 8 else { throw Failure.corruptRecord }
                let record = try readExactly(Int(length), from: handle)
                offset += 8 + length
                if try !visit(record) { break walk }
            }
            chunkID += 1
            offset = 0
        }

        lock.lock()
        let stillValid = cursor.generation == generation && !isClosed
        lock.unlock()
        guard stillValid else { throw Failure.invalidCursor }
    }

    /// Evict only complete history chunks strictly before the reader, oldest first. A budget is
    /// not permission to discard unread packets or the current reader/writer chunk; the resident
    /// count can therefore remain above budget until the consumer advances. No packet/chunk index
    /// is built in memory. The next snapshot's oldest chunk invalidates evicted keyframe tokens.
    func trimConsumed(toByteBudget budget: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireUsable()
        guard retainConsumed else { return }
        do {
            while diskBytes > max(0, budget), oldestChunkID < headID, oldestChunkID < tailID {
                let url = chunkURL(oldestChunkID)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw Self.posixError() }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
                      UInt64(info.st_size) <= UInt64(diskBytes) else { throw Failure.corruptRecord }
                try FileManager.default.removeItem(at: url)
                diskBytes -= Int(info.st_size)
                chunks -= 1
                oldestChunkID += 1
            }
        } catch {
            failure = error
            throw error
        }
    }

    /// Discards this session's contents, including any partial record left by a failed operation.
    func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw Failure.closed }
        do {
            try closePacketHandles()
            if try restoreWhollyMissingDirectory() {
                // The OS already discarded all chunks; the replacement has its own live lease.
                clearCounters()
                failure = nil
                return
            }
            try verifyLeaseIdentity()
            if chunks > 0 {
                for id in oldestChunkID...tailID { try removeChunkIfPresent(id) }
            }
            if let pendingChunkID { try removeChunkIfPresent(pendingChunkID) }
            clearCounters()
            failure = nil
        } catch {
            failure = error
            throw error
        }
    }

    /// Idempotent; a failed cleanup can be retried, but the store stays closed in either case.
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        isClosed = true
        do {
            try removeOwnedStorage()
            clearCounters()
            if leaseFD >= 0 {
                Darwin.close(leaseFD)
                leaseFD = -1
            }
        } catch {
            failure = error
            throw error
        }
    }

    private func requireUsable() throws {
        guard !isClosed else { throw Failure.closed }
        if let failure { throw failure }
    }

    private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw Failure.capacityExceeded }
        return sum
    }

    private func chunkURL(_ id: UInt64) -> URL {
        storageDirectory.appendingPathComponent("\(id).packets", isDirectory: false)
    }

    private func makeWriter(_ id: UInt64) throws -> FileHandle {
        let url = chunkURL(id)
        pendingChunkID = id
        // Never truncate an unexpected existing file, even inside our own unique directory.
        try Data().write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        pendingChunkID = nil
        return handle
    }

    private func openFirstChunk() throws {
        writer = try makeWriter(0)
        headID = 0
        oldestChunkID = 0
        tailID = 0
        chunks = 1
    }

    private func openNextChunk() throws {
        guard tailID < UInt64.max else { throw Failure.capacityExceeded }
        let previousWriter = writer
        writer = nil
        try previousWriter?.close()
        let nextWriter = try makeWriter(tailID + 1)
        if headID == tailID { sealedHeadBytes = tailBytes }
        tailID += 1
        tailBytes = 0
        writer = nextWriter
        chunks += 1
    }

    /// Audit PERF-109: one allocation and no copy. `read(upToCount:)` allocated a `Data` per call and
    /// `append` copied it again into a second one, per payload.
    private func readExactly(_ length: Int, from handle: FileHandle) throws -> Data {
        guard length > 0 else { return Data() }
        var result = Data(count: length)
        try result.withUnsafeMutableBytes { raw in
            try Self.readFully(into: raw, from: handle.fileDescriptor)
        }
        return result
    }

    private static func readRecordLength(from handle: FileHandle) throws -> UInt64 {
        var big: UInt64 = 0
        try withUnsafeMutableBytes(of: &big) { try readFully(into: $0, from: handle.fileDescriptor) }
        return UInt64(bigEndian: big)
    }

    /// EOF before the buffer fills is a record the file does not hold.
    private static func readFully(into buffer: UnsafeMutableRawBufferPointer, from fd: Int32) throws {
        guard let base = buffer.baseAddress else { return }
        var done = 0
        while done < buffer.count {
            let n = Darwin.read(fd, base + done, buffer.count - done)
            if n > 0 { done += n; continue }
            if n < 0, errno == EINTR { continue }
            if n < 0 { throw posixError() }
            throw Failure.corruptRecord
        }
    }

    /// Audit PERF-109: the length and the payload leave in one `writev`, not two writes with a
    /// header `Data` allocated between them. A short count (full volume, quota) finishes with plain
    /// writes, and any failure throws into the caller's latch, so a half-written record is never
    /// appended to.
    private static func writeRecord(_ payload: Data, to fd: Int32) throws {
        var header = UInt64(payload.count).bigEndian
        try withUnsafeBytes(of: &header) { head in
            try payload.withUnsafeBytes { body in
                let total = head.count + body.count
                var sent = 0
                if body.count > 0 {
                    sent = try withUnsafeTemporaryAllocation(of: iovec.self, capacity: 2) { vec in
                        vec[0] = iovec(iov_base: UnsafeMutableRawPointer(mutating: head.baseAddress),
                                       iov_len: head.count)
                        vec[1] = iovec(iov_base: UnsafeMutableRawPointer(mutating: body.baseAddress),
                                       iov_len: body.count)
                        while true {
                            let n = Darwin.writev(fd, vec.baseAddress, 2)
                            if n >= 0 { return n }
                            if errno != EINTR { throw posixError() }
                        }
                    }
                }
                while sent < total {
                    let (base, offset) = sent < head.count
                        ? (head.baseAddress!, sent) : (body.baseAddress!, sent - head.count)
                    let limit = sent < head.count ? head.count : body.count
                    let n = Darwin.write(fd, base + offset, limit - offset)
                    if n > 0 { sent += n; continue }
                    if n < 0, errno == EINTR { continue }
                    if n < 0 { throw posixError() }
                    throw Failure.capacityExceeded
                }
            }
        }
    }

    private func currentReadLimit() throws -> UInt64 {
        if reader == nil { reader = try FileHandle(forReadingFrom: chunkURL(headID)) }
        guard let reader else { throw Failure.corruptRecord }
        if headID == tailID { return tailBytes }
        if let sealedHeadBytes { return sealedHeadBytes }
        let size = try reader.seekToEnd()
        sealedHeadBytes = size
        try reader.seek(toOffset: headOffset)
        return size
    }

    private func advanceRetainedHead() throws {
        let previous = reader
        reader = nil
        try previous?.close()
        headID += 1
        headOffset = 0
        sealedHeadBytes = nil
    }

    private func reclaimHead(byteCount: UInt64) throws {
        let previousReader = reader
        reader = nil
        try previousReader?.close()
        if headID == tailID {
            let previousWriter = writer
            writer = nil
            try previousWriter?.close()
        }
        try FileManager.default.removeItem(at: chunkURL(headID))
        diskBytes -= Int(byteCount)
        chunks -= 1
        headOffset = 0
        sealedHeadBytes = nil
        if chunks == 0 {
            headID = 0
            oldestChunkID = 0
            tailID = 0
            tailBytes = 0
        } else {
            headID += 1
            oldestChunkID = headID
        }
    }

    private func closePacketHandles() throws {
        var firstError: (any Error)?
        let handles = [reader, writer]
        reader = nil
        writer = nil
        for handle in handles {
            do { try handle?.close() } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func removeOwnedStorage() throws {
        var firstError: (any Error)?
        do { try closePacketHandles() } catch { firstError = error }
        do {
            try FileManager.default.removeItem(at: storageDirectory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A repeated close, or recovery after an externally purged temporary directory.
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    private func removeChunkIfPresent(_ id: UInt64) throws {
        let url = chunkURL(id)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.corruptRecord }
        try FileManager.default.removeItem(at: url)
    }

    private func verifyLeaseIdentity() throws {
        var held = stat()
        var named = stat()
        guard leaseFD >= 0, fstat(leaseFD, &held) == 0,
              lstat(storageDirectory.appendingPathComponent(Self.liveMarkerName).path, &named) == 0,
              named.st_mode & S_IFMT == S_IFREG,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
            throw Failure.sessionLeaseLost
        }
    }

    /// Normal reset never removes/replaces the marker. An OS-purged root is different: its
    /// unlinked lease no longer protects a path, so rebuild and acquire the replacement first.
    private func restoreWhollyMissingDirectory() throws -> Bool {
        var info = stat()
        if lstat(storageDirectory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.sessionLeaseLost }
            return false
        }
        guard errno == ENOENT else { throw Self.posixError() }
        guard mkdir(storageDirectory.path, 0o700) == 0 else { throw Self.posixError() }
        do {
            let replacement = try Self.acquireNewLease(storageDirectory)
            if leaseFD >= 0 { Darwin.close(leaseFD) }
            leaseFD = replacement
        } catch {
            try? FileManager.default.removeItem(at: storageDirectory)
            throw error
        }
        return true
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func acquireNewLease(_ directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent(liveMarkerName).path
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = posixError()
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// Bounded crash-remnant cleanup, never a recursive search of the caller's temporary root.
    /// Only our UUID-named direct-child directories older than one day are candidates. Keep the
    /// candidate's advisory lease held until removal finishes; age alone never proves abandonment.
    /// [MovieClaw P16] 死会话目录的最小年龄：只用来躲开「目录已建、租约还没拿到」的一瞬间。
    /// 原来要等 24 小时，被杀掉的软件通路会话（VP9、MPEG-2、VC-1、DVD）每个留下 1 GB 上下的包缓存，
    /// 真机一夜攒了 6.6 GB；租约（flock）才是活着的凭据，进程一死内核就放掉
    static let staleAgeSeconds: TimeInterval = 10

    static func sweepStaleSessionDirs(parentDirectory: URL, currentSession: String? = nil,
                                     now: Date = Date(), maxEntries: Int = 64,
                                     maxRemovals: Int = 32) -> StaleSweepResult {
        guard maxEntries > 0, maxRemovals > 0,
              let entries = FileManager.default.enumerator(at: parentDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            return StaleSweepResult(inspectedCount: 0, removedCount: 0, failureCount: 0)
        }
        var inspected = 0
        var removed = 0
        var failures = 0
        while inspected < maxEntries, removed < maxRemovals,
              let entry = entries.nextObject() as? URL {
            inspected += 1
            let name = entry.lastPathComponent
            guard name != currentSession, name.hasPrefix(directoryPrefix),
                  UUID(uuidString: String(name.dropFirst(directoryPrefix.count))) != nil else { continue }
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { failures += 1; continue }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            guard info.st_mode & S_IFMT == S_IFDIR,
                  now.timeIntervalSince1970 - modified >= Self.staleAgeSeconds else { continue }
            let dirFD = open(entry.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0 else { failures += 1; continue }
            defer { Darwin.close(dirFD) }
            // O_CREAT also lets us lease a root abandoned between mkdir and marker creation.
            let markerFD = openat(dirFD, liveMarkerName,
                                  O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard markerFD >= 0 else { failures += 1; continue }
            defer { Darwin.close(markerFD) }
            guard flock(markerFD, LOCK_EX | LOCK_NB) == 0 else {
                if errno != EWOULDBLOCK && errno != EAGAIN { failures += 1 }
                continue
            }
            // Recheck identity rather than following a replaced directory or marker symlink.
            var held = stat()
            var named = stat()
            guard fstat(dirFD, &held) == 0, lstat(entry.path, &named) == 0,
                  named.st_mode & S_IFMT == S_IFDIR,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
                failures += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1
            } catch { failures += 1 }
        }
        return StaleSweepResult(inspectedCount: inspected, removedCount: removed, failureCount: failures)
    }

    private func clearCounters() {
        generation = UUID()
        oldestChunkID = 0
        headID = 0
        tailID = 0
        headOffset = 0
        tailBytes = 0
        sealedHeadBytes = nil
        recordCount = 0
        payloadBytes = 0
        diskBytes = 0
        chunks = 0
        writtenRecordCount = 0
        writtenPayloadBytes = 0
        pendingChunkID = nil
    }
}
