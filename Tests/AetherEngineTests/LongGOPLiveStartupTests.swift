import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// Optional real-media witness. Generate 40 s H.264/AAC MPEG-TS fixtures with 5 s and 10 s closed GOPs
/// and a 700 kbit/s constant mux rate. Scripts/test-long-gop-startup.sh supplies the fixtures.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct LongGOPLiveStartupTests {
    private final class PacedReader: IOReader, @unchecked Sendable {
        private let data: Data
        private let condition = NSCondition()
        private let started = ContinuousClock.now
        private var cursor = 0
        private var closed = false
        private let preroll: Double
        init(data: Data, preroll: Double) { self.data = data; self.preroll = preroll }
        var discImageProbeEnabled: Bool { false }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return 0 }
            condition.lock()
            defer { condition.unlock() }
            while !closed {
                let elapsed = started.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let frontier = min(data.count, Int((preroll + seconds) * 87_500))
                let count = min(Int(size), 188 * 7, frontier - cursor)
                if count > 0 {
                    data.copyBytes(to: buffer, from: cursor..<(cursor + count))
                    cursor += count
                    return Int32(count)
                }
                if cursor == data.count { return 0 }
                condition.wait(until: Date(timeIntervalSinceNow: 0.01))
            }
            return -1
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() { condition.withLock { closed = true; condition.broadcast() } }
        func cancel() { close() }
        func makeIndependentReader() -> IOReader? { nil }
    }

    @Test("A fast join can consume a long finalized GOP before a second GOP is available",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_LONG_GOP_FIXTURES"] != nil),
          arguments: [5, 10])
    func longGOPNativeJoin(_ gopSeconds: Int) async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AETHER_LONG_GOP_FIXTURES"])
        let path = URL(fileURLWithPath: directory).appendingPathComponent("gop-\(gopSeconds).ts")
        let reader = PacedReader(data: try Data(contentsOf: path), preroll: Double(gopSeconds - 3))
        let engine = try AetherEngine()
        let log = EngineLogCapture()
        defer { engine.stop(); log.end() }
        var options = LoadOptions(isLive: true, dvrWindowSeconds: 60, liveJoinProfile: .fastZap,
                                  liveStartupGraceSeconds: 0,
                                  liveStartupSingleSegmentMinimumSeconds: 5)
        options.suppressDisplayCriteria = true
        let start = ContinuousClock.now
        try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: options)
        try await waitFor { engine.isSessionReady }
        let joined = start.duration(to: .now)
        print("LONG_GOP=\(gopSeconds) JOIN_SECONDS=\(joined)")
        for line in log.matching("first live manifest") { print(line) }
        #expect(joined < .seconds(7), "a second full GOP must not be required after a playable first GOP")
        let seekable = try await waitFor(upTo: .seconds(2)) {
            guard let range = engine.seekableLiveRange else { return false }
            return range.upperBound - range.lowerBound >= 1
        }
        #expect(seekable, "an advancing played frontier must not wait for a second long GOP")
        print("LONG_GOP_SEEKABLE_SECONDS=\(start.duration(to: .now))")
        let initial = engine.currentTime
        try await waitFor { engine.currentTime - initial > 10 || engine.errorInfo != nil }
        print("LONG_GOP_ADVANCE=\(engine.currentTime - initial) state=\(engine.state)")
        #expect(engine.videoRoute == .loopback)
        #expect(engine.currentTime - initial > 10)
        #expect(engine.currentAVPlayer?.currentItem?.error == nil)
        let beforeRewind = engine.currentTime
        let range = try #require(engine.seekableLiveRange)
        await engine.seek(to: max(range.lowerBound, beforeRewind - 3))
        #expect(engine.currentTime < beforeRewind - 1)
        await engine.seekToLiveEdge(offsetSeconds: 5)
        let afterReturn = engine.currentTime
        try await waitFor { engine.currentTime > afterReturn + 1 || engine.errorInfo != nil }
        #expect(engine.currentTime > afterReturn + 1)
        #expect(engine.currentAVPlayer?.currentItem?.error == nil)
    }
}
