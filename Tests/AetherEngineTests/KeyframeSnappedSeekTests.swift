import Foundation
import Testing
@testable import AetherEngine

/// A seek on the software host's AV1 through dav1d lands on the indexed keyframe nearest its target
/// (`SWKeyframeSnap`), so dav1d starts on a picture instead of decoding up to a whole GOP to reach
/// the target. The keyframes below are a 6.7 s GOP, SvtAv1EncApp's default keyint at 23.976 fps.
@Suite("Keyframe-snapped seeks on the software host")
struct KeyframeSnappedSeekTests {

    private static let keyframes: [Double] = [0, 6.7, 13.4, 20.1, 26.8]

    private func snap(_ target: Double, from current: Double,
                      keyframes: [Double] = Self.keyframes) -> Double? {
        SWKeyframeSnap.snappedSeconds(target: target, current: current, keyframes: keyframes)
    }

    @Test("A forward seek lands on the nearest keyframe, after the target when that one is nearer")
    func forwardSeekLandsOnNearestKeyframe() {
        #expect(snap(12, from: 1) == 13.4)
        #expect(snap(8, from: 1) == 6.7)
        #expect(snap(20.1, from: 1) == 20.1)
    }

    @Test("A backward seek lands on the nearest keyframe")
    func backwardSeekLandsOnNearestKeyframe() {
        #expect(snap(8, from: 25) == 6.7)
        #expect(snap(12, from: 25) == 13.4)
    }

    @Test("A forward seek never lands behind the playhead, a backward one never ahead of it")
    func seekNeverCrossesThePlayhead() {
        // Nearest keyframe 6.7 s is behind a playhead at 7 s: a +1 s press must not jump back.
        #expect(snap(8, from: 7) == nil)
        // Nearest keyframe 13.4 s is ahead of a playhead at 13 s: a -1 s press must not jump forward.
        #expect(snap(12, from: 13) == nil)
    }

    /// Matroska parses its Cues at the first seek, so before it the index holds only the keyframes
    /// read so far. Measured before this held: a seek to 70 s from 11 s landed on 13.4 s.
    @Test("An index that does not reach the target yet keeps the seek exact")
    func indexShortOfTheTargetKeepsTheSeekExact() {
        #expect(snap(70, from: 11, keyframes: [0, 6.7, 13.4]) == nil)
        // 13.4 s is within reach of 16 s, but the index does not know the keyframes after it.
        #expect(snap(16, from: 11, keyframes: [0, 6.7, 13.4]) == nil)
        #expect(snap(13, from: 11, keyframes: [0, 6.7, 13.4]) == 13.4)
    }

    @Test("An index sparser than the stream's keyframes never moves a seek further than the reach")
    func sparseIndexKeepsTheSeekExact() {
        #expect(SWKeyframeSnap.reachSeconds == 10)
        #expect(snap(37, from: 1, keyframes: [0, 25, 50]) == nil)
        #expect(snap(32, from: 1, keyframes: [0, 25, 50]) == 25)
    }

    @Test("No index, or a target that is not a time, keeps the seek exact")
    func noIndexKeepsTheSeekExact() {
        #expect(snap(12, from: 1, keyframes: []) == nil)
        #expect(snap(.nan, from: 1) == nil)
        #expect(snap(12, from: .infinity) == nil)
    }

    /// Measured on an Apple TV 4K: +30 s seeks the packet cache served never repositioned the demuxer,
    /// so the Matroska index held only the keyframes read so far and none of the five seeks snapped.
    @Test("The packet cache's retained keyframes count beside the index")
    func retainedKeyframesCountBesideTheIndex() {
        let indexed: [Double] = [0, 6.7, 13.4]
        let retained: [Double] = [13.4, 20.1, 26.8, 33.5]
        let keys = SWKeyframeSnap.candidates(retained: retained, indexed: indexed)
        #expect(keys == [0, 6.7, 13.4, 20.1, 26.8, 33.5])
        #expect(snap(25, from: 5, keyframes: indexed) == nil)
        #expect(snap(25, from: 5, keyframes: keys) == 26.8)
    }

    @Test("A short skip never moves by less than half its distance: the reach shrinks with the seek")
    func reachShrinksWithTheSeek() {
        // +10 s from 6.6 s: 6.7 s is within 10 s of the target, but would turn the skip into 0.1 s.
        #expect(snap(16.6, from: 6.6, keyframes: [0, 6.7, 30]) == nil)
        #expect(snap(16.6, from: 6.6, keyframes: [0, 6.7, 13.4, 20.1]) == 13.4)
    }

    /// The cache converts ticks as `pts * num / den`, the index as `pts * (num / den)`; at 1/24000 the
    /// index value sits one bit below the cache's for about one keyframe in five.
    @Test("A keyframe both lists hold keeps the cache's value, which a cache hit compares exactly")
    func sharedKeyframeKeepsTheCacheValue() {
        let cached = Double(300_003) * 1 / 24000
        let indexed = Double(300_003) * (1.0 / 24000)
        #expect(indexed < cached)
        #expect(SWKeyframeSnap.candidates(retained: [cached], indexed: [0, indexed]) == [0, cached])
        #expect(SWKeyframeSnap.candidates(retained: [], indexed: [0, indexed]) == [0, indexed])
    }

    private final class Input: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [SoftwareStoredPacket]
        private var index = 0
        init(_ packets: [SoftwareStoredPacket]) { self.packets = packets }
        func next() -> SoftwareStoredPacket? {
            lock.lock(); defer { lock.unlock() }
            guard index < packets.count else { return nil }
            defer { index += 1 }; return packets[index]
        }
    }

    /// The first packet a cache hit at 5.5 s hands the decoder: 10 s at 25 fps on a 1/1000 time base,
    /// a keyframe every second.
    private func cacheHitStart(anchorsOnLastKeyframe: Bool) async throws -> Int64? {
        let input = Input((0..<250).map { i in
            SoftwareStoredPacket(pts: Int64(i) * 40, dts: Int64(i) * 40, duration: 40, position: 0,
                                 streamIndex: 0, flags: i % 25 == 0 ? 1 : 0, timeBaseNumerator: 1,
                                 timeBaseDenominator: 1000, bytes: Data(repeating: 7, count: 100),
                                 sideData: [])
        })
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 1024, retainConsumed: true)
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000), audio: nil,
            byteBudget: 1_000_000, forwardSeconds: 3600, initialSourceClock: 0, fifo: fifo,
            anchorsOnLastKeyframe: anchorsOnLastKeyframe) { _ in input.next() }
        source.start()
        defer { source.close() }
        try await waitFor { source.snapshot.sourceEnded }
        let token = source.beginSeek(to: 5.5)
        guard try source.prepareSeek(token, to: 5.5) else { return nil }
        source.endSeek(token, sourceClock: 5.5)
        return try source.read()?.pts
    }

    /// Measured on an Apple TV 4K (A15), 4K AV1 with a 6.7 s GOP: a hit onto a keyframe held the
    /// clock 1.8 to 2.5 s while dav1d decoded the GOP before it, a miss onto one 0.48 s.
    @Test("A cache hit for AV1 starts on the last keyframe before the target, not on the one before it",
          .timeLimit(.minutes(3)))
    func cacheHitStartsOnTheLastKeyframe() async throws {
        #expect(try await cacheHitStart(anchorsOnLastKeyframe: false) == 4000)
        #expect(try await cacheHitStart(anchorsOnLastKeyframe: true) == 5000)
    }

    @Test("Snapping is on by default")
    func snappingIsOnByDefault() {
        #expect(SWKeyframeSnap.enabled)
    }
}
