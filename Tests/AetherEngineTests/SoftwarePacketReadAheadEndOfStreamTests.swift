import Foundation
import Testing
@testable import AetherEngine

/// An empty read-ahead store is the end of the stream only when the source said so.
///
/// A seek that misses the cache empties the store while holding `operations`. A consumer read that
/// started inside the seek's window left its wait at once (its reader was not current), then waited
/// for `operations`; by the time it got the lock the seek had landed, its reader was current again,
/// and it found the store empty and returned nil, which the host takes for the end of the media.
/// Playback stopped at the landing (a DVD seek past the first cell: 7 of 8 runs).
@Suite("Software read-ahead end of stream", .offCooperativePool, .timeLimit(.minutes(3)))
struct SoftwarePacketReadAheadEndOfStreamTests {

    /// A reader that is not current on its first check and current on every later one: the
    /// seek's window closing between the read's wait and its admission check.
    private final class CurrentAfterFirstCheck: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        func check() -> Bool { lock.lock(); defer { lock.unlock() }; checks += 1; return checks > 1 }
    }

    private static func readAhead(_ root: URL,
                                  source: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?
    ) throws -> SoftwarePacketReadAhead {
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        return SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000), audio: nil,
            byteBudget: 1 << 20, forwardSeconds: 10, initialSourceClock: 0, fifo: fifo,
            readSource: source)
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readahead-eos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("an empty store whose reader becomes current again is not the end of the stream")
    func emptyStoreBeforeTheSourceEndsIsInterrupted() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not started: nothing is read, the store stays empty, the source has not ended.
        let source = try Self.readAhead(root) { _ in nil }
        defer { source.close() }
        let reader = CurrentAfterFirstCheck()
        #expect(throws: SoftwarePacketReadAhead.ReadError.interrupted) {
            _ = try source.read(isCurrent: { reader.check() })
        }
    }

    @Test("the source's own end is the end of the stream")
    func sourceEndIsEndOfStream() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Self.readAhead(root) { _ in nil }
        defer { source.close() }
        source.start()
        // The producer has to have seen the end before there is anything to measure.
        try await waitFor { source.snapshot.sourceEnded }
        #expect(try source.read() == nil)
    }
}
