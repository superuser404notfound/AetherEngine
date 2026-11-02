import Foundation
import Testing
@testable import AetherEngine

/// Audit HLS-101: only the session's first live producer was wired to the provider, so a producer
/// that replaced a dead one (live reopen, the in-place muxerFailed rebuild, the AE#222 live rebuild)
/// cut segments into the cache that the playlist never listed. The playlist ended where the dead
/// producer stopped, and "live reopen succeeded" was logged over a frozen picture.
@Suite("A live playlist keeps growing after an in-engine recovery", .serialized)
struct LiveRecoveryPlaylistGrowthTests {

    private final class Observed: @unchecked Sendable {
        private let lock = NSLock()
        private weak var _engine: HLSVideoEngine?
        private var _countAtFirstReopen: Int?
        private var _sourceResets = 0
        private var _allowNewMedia = false

        func watch(_ engine: HLSVideoEngine) { lock.withLock { _engine = engine } }

        /// Runs inside the reopen, after the dead pump's own segments were reported.
        func noteReopen() {
            let engine = lock.withLock { _engine }
            let count = engine?.liveSegmentCountSnapshot
            lock.withLock { if _countAtFirstReopen == nil { _countAtFirstReopen = count } }
        }

        func noteSourceReset() { lock.withLock { _sourceResets += 1 } }

        var countAtFirstReopen: Int? { lock.withLock { _countAtFirstReopen } }
        var sourceResets: Int { lock.withLock { _sourceResets } }
        var allowNewMedia: Bool { lock.withLock { _allowNewMedia } }
        func admitNewMedia() { lock.withLock { _allowNewMedia = true } }
    }

    private static func openLiveDemuxer() throws -> Demuxer {
        let dem = Demuxer()
        try dem.open(reader: TinyTransportStreamFixture.LiveReader(),
                     formatHint: "mpegts", isLive: true)
        return dem
    }

    /// A fresh broadcast has new source timestamps; replaying the same fixture would
    /// now correctly be rejected by the retained cache's exact-packet history.
    private static func nextBroadcast() -> Data {
        var bytes = TinyTransportStreamFixture.data
        let pesHeader = Data([0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 5])
        var offset = 0
        while let range = bytes.range(of: pesHeader, in: offset..<bytes.count) {
            let p = range.upperBound
            let pts = (UInt64(bytes[p] & 0x0E) << 29) | (UInt64(bytes[p + 1]) << 22)
                | (UInt64(bytes[p + 2] & 0xFE) << 14) | (UInt64(bytes[p + 3]) << 7)
                | (UInt64(bytes[p + 4]) >> 1)
            let next = pts + 8 * 90_000
            bytes[p] = (bytes[p] & 0xF1) | UInt8((next >> 29) & 0x0E)
            bytes[p + 1] = UInt8((next >> 22) & 0xFF)
            bytes[p + 2] = UInt8((next >> 14) & 0xFE) | 1
            bytes[p + 3] = UInt8((next >> 7) & 0xFF)
            bytes[p + 4] = UInt8((next << 1) & 0xFE) | 1
            offset = p + 5
        }
        return bytes
    }

    @Test("segments a reopened live producer cuts reach the playlist", .timeLimit(.minutes(3)))
    func reopenedProducerGrowsThePlaylist() async throws {
        let observed = Observed()
        let engine = HLSVideoEngine(
            url: URL(string: "aether-custom://source")!,
            dvModeAvailable: false,
            isLiveSession: true,
            liveCutTargetSeconds: 1,
            preopenedDemuxer: try Self.openLiveDemuxer(),
            sourceReopenableByURL: false,
            customSourceReopenFactory: {
                observed.noteReopen()
                return (reader: TinyTransportStreamFixture.LiveReader(bytes: Self.nextBroadcast()), formatHint: "mpegts")
            })
        observed.watch(engine)
        _ = try engine.start()
        defer { engine.stop() }

        // The reader ends after one pass, which is the source loss; the factory is the reconnect.
        try await waitFor { observed.countAtFirstReopen != nil }
        let beforeLoss = try #require(observed.countAtFirstReopen)
        #expect(beforeLoss > 0, "the first producer never reported a segment")

        try await waitFor { (engine.liveSegmentCountSnapshot ?? 0) > beforeLoss }
    }

    @Test("an exhausted repeated source resumes into the same DVR when new media arrives", .timeLimit(.minutes(3)))
    func parkedReplayRecoveryResumesWithoutAppendingOldMedia() async throws {
        let observed = Observed()
        let engine = HLSVideoEngine(url: URL(string: "aether-custom://source")!,
            dvModeAvailable: false, isLiveSession: true, liveCutTargetSeconds: 1,
            preopenedDemuxer: try Self.openLiveDemuxer(), sourceReopenableByURL: false,
            customSourceReopenFactory: {
                observed.noteReopen()
                let bytes = observed.allowNewMedia ? Self.nextBroadcast() : TinyTransportStreamFixture.data
                return (reader: TinyTransportStreamFixture.LiveReader(bytes: bytes), formatHint: "mpegts")
            })
        observed.watch(engine)
        engine.onLiveSourceReplayExhausted = { observed.noteSourceReset() }
        _ = try engine.start()
        defer { engine.stop() }
        let cache = try #require(engine.cache)
        let provider = try #require(engine.provider)
        try await waitFor { observed.sourceResets > 0 }
        let originalCount = try #require(observed.countAtFirstReopen)
        #expect(engine.liveSegmentCountSnapshot == originalCount,
                "every repeated source must leave the admitted timeline unchanged")
        #expect(provider.liveProductionHalted)
        observed.admitNewMedia()
        let resetsBeforeRetry = observed.sourceResets
        #expect(engine.retryLiveSourceRecovery())
        #expect(!provider.liveProductionHalted, "the retry lifts the halt before the reopen runs")
        #expect(engine.retryLiveSourceRecovery(), "duplicate host notification coalesces")
        try await waitFor { (engine.liveSegmentCountSnapshot ?? 0) > originalCount }
        #expect(engine.cache === cache)
        #expect(engine.provider === provider)
        // The new broadcast is finite and every later reopen repeats it, so a slow runner can see the
        // source exhausted a second time and halted again by now. Only that may halt it, and the halt
        // lands before the exhaustion callback, so a halted provider waits for the callback.
        if provider.liveProductionHalted {
            try await waitFor { observed.sourceResets > resetsBeforeRetry }
        }
    }

    @Test("a producer rebuilt in place reports into the same playlist", .timeLimit(.minutes(3)))
    func rebuiltProducerReportsIntoThePlaylist() async throws {
        let observed = Observed()
        let engine = HLSVideoEngine(
            url: URL(string: "aether-custom://source")!,
            dvModeAvailable: false,
            isLiveSession: true,
            liveCutTargetSeconds: 1,
            preopenedDemuxer: try Self.openLiveDemuxer(),
            sourceReopenableByURL: false)
        engine.onLiveSourceReset = { observed.noteSourceReset() }
        _ = try engine.start()
        defer { engine.stop() }

        try await waitFor { observed.sourceResets > 0 }
        let failed = try #require(engine.producer)
        engine.rebuildLiveProducerInPlace(failed: failed)
        let rebuilt = try #require(engine.producer)
        #expect(rebuilt !== failed)
        #expect(rebuilt.liveResidentCapProvider != nil)

        let continuation = try #require(engine.provider?.liveContinuationPoint())
        let report = try #require(rebuilt.onLiveSegmentFinalized, "the rebuilt producer reports to nobody")
        report(continuation.nextIndex, 1.0, continuation.outputEndSeconds, true)
        #expect(engine.liveSegmentCountSnapshot == continuation.nextIndex + 1)
    }
}
