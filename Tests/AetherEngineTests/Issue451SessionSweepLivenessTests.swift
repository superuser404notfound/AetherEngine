import Foundation
import Testing
@testable import AetherEngine

/// AE#451: `SegmentCache.init` sweeps sibling session dirs by AGE alone. A directory's creation
/// date is its session's START time, so a session an hour in is indistinguishable from a crashed
/// one, and a second engine constructed in the same process (or a second non-sandboxed process,
/// which shares NSTemporaryDirectory with the first) deletes a running session's segments.
@Suite("AE#451 stale-session sweep liveness")
struct Issue451SessionSweepLivenessTests {

    private func makeBase() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ae451-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Backdate a directory past the one-hour cutoff the sweep uses.
    @discardableResult
    private func backdate(_ url: URL, seconds: TimeInterval = 7200) -> Bool {
        let past = Date().addingTimeInterval(-seconds)
        try? FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: url.path)
        let read = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return read.map { $0 < Date().addingTimeInterval(-3600) } ?? false
    }

    @Test("A crashed sibling older than the cutoff is still swept")
    func deadSiblingIsSwept() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let dead = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        #expect(backdate(dead), "the fixture must actually be older than the cutoff")

        let c = SegmentCache(baseDirectory: base)
        defer { c.close() }

        #expect(!FileManager.default.fileExists(atPath: dead.path),
                "an unheld directory past the cutoff is exactly what the sweep exists for")
    }

    /// Audit NAT-201: the software packet spool shares the sweep. Unrelated entries in a busy temporary
    /// directory do not use up its budget, and the one-hour age applies instead of one day.
    @Test("The packet spool sweep reaches an old spool behind 100 unrelated entries and spares a leased one")
    func packetSpoolRemnantIsSweptBehindUnrelatedEntries() throws {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        for index in 0..<100 {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("unrelated-\(index)", isDirectory: true),
                withIntermediateDirectories: true)
        }
        let prefix = SoftwarePacketDiskFIFO.directoryPrefix
        let dead = base.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        let live = base.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        for url in [dead, live] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #expect(backdate(url))
        }
        let lease = try SessionDirectoryLiveness.acquireExclusive(sessionDir: live)
        defer { Darwin.close(lease) }

        let result = SoftwarePacketDiskFIFO.sweepStaleSessionDirs(parentDirectory: base)

        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(result.removedCount == 1)
    }

    @Test("A sibling younger than the cutoff is spared")
    func youngSiblingIsSpared() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let young = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: young, withIntermediateDirectories: true)

        let c = SegmentCache(baseDirectory: base)
        defer { c.close() }

        #expect(FileManager.default.fileExists(atPath: young.path))
    }

    @Test("A LIVE sibling older than the cutoff survives a second cache's sweep")
    func liveSiblingSurvivesTheSweep() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let live = SegmentCache(baseDirectory: base)
        defer { live.close() }
        live.store(index: 0, data: Data(repeating: 0xAA, count: 128))
        #expect(live.peekURL(index: 0) != nil)

        // An hour into a film: the directory's creation date is the session's start.
        #expect(backdate(live.sessionDir), "the fixture must actually be older than the cutoff")

        let second = SegmentCache(baseDirectory: base)
        defer { second.close() }

        #expect(FileManager.default.fileExists(atPath: live.sessionDir.path),
                "the running session's directory must survive a sibling's construction")
        #expect(live.peekURL(index: 0) != nil,
                "and its stored segments with it")
    }

    @Test("A stale marker nobody holds does not protect a dead directory")
    func unheldMarkerDoesNotProtect() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let dead = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        // Same file a live session would leave behind, but no process holds it.
        FileManager.default.createFile(atPath: dead.appendingPathComponent("session.lock").path,
                                       contents: Data())
        #expect(backdate(dead))

        let c = SegmentCache(baseDirectory: base)
        defer { c.close() }

        #expect(!FileManager.default.fileExists(atPath: dead.path),
                "liveness is the held lock, not the file's presence")
    }

    /// The second half: bookkeeping outlives the file, and every consumer of "is it stored"
    /// inherits the lie. The server's file path answers a 404 the #50 in-range rule forbids,
    /// and AVPlayer treats a 404 on a VOD segment as terminal.
    @Test("A segment whose file vanished stops answering 'stored'")
    func vanishedFileStopsAnsweringStored() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let c = SegmentCache(baseDirectory: base)
        defer { c.close() }
        c.store(index: 4, data: Data(repeating: 0xBB, count: 512))
        #expect(c.peekURL(index: 4) != nil)
        #expect(c.totalBytes == 512)

        // Whatever removed it (a sibling's sweep, the OS reclaiming tmp) is outside this class.
        if let url = c.peekURL(index: 4) { try? FileManager.default.removeItem(at: url) }

        #expect(c.peekURL(index: 4) == nil,
                "a URL handed to a response must name a file that exists")
        #expect(c.peek(index: 4) == nil)
        #expect(c.totalBytes == 0, "the byte ledger must drop what the disk no longer holds")
    }

    @Test("The blocking fetch path drops a vanished entry instead of failing every retry")
    func fetchDropsAVanishedEntry() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let c = SegmentCache(baseDirectory: base)
        defer { c.close() }
        c.store(index: 2, data: Data(repeating: 0xDD, count: 64))
        if let url = c.peekURL(index: 2) { try? FileManager.default.removeItem(at: url) }

        // The serve that finds nothing answers a retriable 503; without dropping the entry, the
        // next fetch takes the same branch and the producer is never asked to make it again.
        #expect(c.fetch(index: 2, timeout: 0.05) == nil)
        #expect(c.peekURL(index: 2) == nil)
        #expect(c.count == 0)

        c.store(index: 2, data: Data(repeating: 0xEE, count: 96))
        #expect(c.fetch(index: 2, timeout: 0.05)?.count == 96,
                "and the index is producible again")
    }

    @Test("A store into a session directory that vanished re-creates it")
    func storeRecreatesAVanishedSessionDirectory() {
        let base = makeBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let c = SegmentCache(baseDirectory: base)
        defer { c.close() }

        try? FileManager.default.removeItem(at: c.sessionDir)

        c.store(index: 7, data: Data(repeating: 0xCC, count: 256))
        #expect(c.peekURL(index: 7) != nil,
                "a session must stay writable after something else deleted its directory")
        #expect(c.peek(index: 7)?.count == 256)
    }
}
