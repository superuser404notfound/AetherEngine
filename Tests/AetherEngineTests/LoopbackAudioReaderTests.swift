import XCTest
import AVFAudio
@testable import AetherEngine

/// #95: loop logic of the loopback reader, driven step-by-step with stubbed dependencies.
/// No media involved; decode is stubbed to return one 1 s chunk per decode call.
final class LoopbackAudioReaderTests: XCTestCase {

    /// Mutable stub world shared with the closures. Single-threaded in these tests.
    final class World: @unchecked Sendable {
        var playhead: Double? = 0
        var shift: Double = 0
        var segments: Set<Int> = []          // resident segment indices
        var highestStored = -1
        var decoded: [Int] = []              // one entry per decode call
        var emitted: [AudioTapBuffer] = []
        var segmentSeconds: Double = 1.0
        /// Stamp each decode with its segment's own time rather than the count of decodes.
        var stampsBySegmentIndex = false
    }

    private func makeReader(_ w: World) -> LoopbackAudioReader {
        let deps = LoopbackAudioReader.Dependencies(
            playhead: { w.playhead },
            shiftSeconds: { w.shift },
            anchorIndex: { Int($0 / w.segmentSeconds) },
            initData: { _ in Data([0]) },
            segmentData: { w.segments.contains($0) ? Data(String($0).utf8) : nil },
            highestStoredIndex: { w.highestStored },
            decodeSegment: { _, segment in
                w.decoded.append(w.decoded.count)
                let idx = w.stampsBySegmentIndex
                    ? Double(String(decoding: segment, as: UTF8.self)) ?? 0
                    : Double(w.decoded.count - 1)
                let frames = AVAudioFrameCount(48_000 * w.segmentSeconds)
                let buf = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat,
                                           frameCapacity: frames)!
                buf.frameLength = frames
                return [AudioTapChunk(buffer: buf, ptsSeconds: idx * w.segmentSeconds)]
            },
            emit: { w.emitted.append($0) }
        )
        return LoopbackAudioReader(deps: deps)
    }

    func testDecodesForwardWithinLeadThenSleeps() {
        let w = World()
        w.segments = Set(0...30); w.highestStored = 30
        let reader = makeReader(w)
        // Lead is 10 s and each segment is 1 s: expect 10 decode steps, then a sleep.
        for _ in 0..<10 { XCTAssertEqual(reader.runOnce(), .decoded) }
        XCTAssertEqual(reader.runOnce(), .slept)
        XCTAssertEqual(w.emitted.count, 10)
        // First buffer after install is a discontinuity, the rest abut.
        XCTAssertTrue(w.emitted[0].discontinuity)
        XCTAssertFalse(w.emitted[1].discontinuity)
    }

    /// Ten-second segments, as an IPTV panel's live channels and many VOD remuxes have: the
    /// reader decodes one segment past the lead and then waits for the playhead, and never goes
    /// back over what it decoded while the playhead only moves forward.
    func testLongSegmentsAreDecodedOnceEachAsThePlayheadMovesOn() {
        let w = World()
        w.segmentSeconds = 10
        w.stampsBySegmentIndex = true
        w.segments = Set(0...30); w.highestStored = 30
        let reader = makeReader(w)
        var playhead = 0.0
        var steps: [LoopbackAudioReader.StepResult] = []
        while playhead < 60 {
            w.playhead = playhead
            steps.append(reader.runOnce())
            playhead += 0.25
        }
        XCTAssertFalse(steps.contains(.reanchored), "no backward jumps while playing forward")
        let starts = w.emitted.map(\.sourceTime)
        XCTAssertEqual(starts, starts.sorted(), "every segment once, in order")
        XCTAssertEqual(Set(starts).count, starts.count)
        XCTAssertEqual(w.emitted.filter(\.discontinuity).count, 1, "only the first is a discontinuity")
        // The lead holds: at most a segment past it, and never behind the playhead.
        XCTAssertGreaterThanOrEqual((starts.last ?? 0) + 10, 60)
        XCTAssertLessThanOrEqual(starts.last ?? 0, 60 + 10)
    }

    func testLongSegmentsReanchorOnABackwardSeek() {
        let w = World()
        w.segmentSeconds = 10
        w.stampsBySegmentIndex = true
        w.segments = Set(0...30); w.highestStored = 30
        w.playhead = 100
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded, "segment 10, 100–110 s")
        XCTAssertEqual(reader.runOnce(), .slept, "the lead is full")
        w.playhead = 40
        XCTAssertEqual(reader.runOnce(), .reanchored)
        XCTAssertEqual(reader.runOnce(), .decoded)
        XCTAssertEqual(w.emitted.last?.sourceTime ?? 0, 40, accuracy: 0.001, "from the playhead's segment")
        XCTAssertTrue(w.emitted.last?.discontinuity ?? false)
    }

    func testSourceTimeFoldsShift() {
        let w = World()
        w.segments = Set(0...5); w.highestStored = 5
        w.shift = 42.0
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded)
        XCTAssertEqual(w.emitted[0].sourceTime, 42.0, accuracy: 0.001)
    }

    func testNotYetProducedSleepsInsteadOfSkipping() {
        let w = World()
        w.segments = [0]; w.highestStored = 0
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded)
        // Segment 1 not produced yet (beyond highestStored): wait, do not skip.
        XCTAssertEqual(reader.runOnce(), .slept)
    }

    func testEvictedSegmentSkipsForwardWithDiscontinuity() {
        let w = World()
        w.segments = Set(0...10).subtracting([1]); w.highestStored = 10
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded)    // seg 0
        // Seg 1 missing but below highestStored: repeated misses then skip to seg 2.
        for _ in 0..<LoopbackAudioReader.maxMissStreak { XCTAssertEqual(reader.runOnce(), .slept) }
        XCTAssertEqual(reader.runOnce(), .decoded)    // seg 2 after skip
        XCTAssertTrue(w.emitted.last!.discontinuity)
    }

    func testPlayheadJumpReanchors() {
        let w = World()
        w.segments = Set(0...400); w.highestStored = 400
        let reader = makeReader(w)
        XCTAssertEqual(reader.runOnce(), .decoded)
        w.playhead = 300.0                             // far forward seek
        XCTAssertEqual(reader.runOnce(), .reanchored)
        XCTAssertEqual(reader.runOnce(), .decoded)
        XCTAssertTrue(w.emitted.last!.discontinuity)
    }
}
