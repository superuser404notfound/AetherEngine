// Tests/AetherEngineTests/SubtitleInjectionWindowTests.swift
import XCTest
@testable import AetherEngine

final class SubtitleInjectionWindowTests: XCTestCase {
    func test_gapsAreFilledWithEmptySamplesContiguous() {
        // window [0,6): cue "a" at [1,2), cue "b" at [4,5)
        let cues: [(start: Double, end: Double, text: String)] = [
            (1, 2, "a"), (4, 5, "b")
        ]
        let samples = HLSSegmentProducer.movTextSamples(forWindow: (0, 6), cues: cues)
        // expect: empty[0,1), "a"[1,2), empty[2,4), "b"[4,5), empty[5,6)
        XCTAssertEqual(samples.map { $0.pts }, [0, 1, 2, 4, 5])
        XCTAssertEqual(samples.map { $0.duration }, [1, 1, 2, 1, 1])
        XCTAssertEqual([UInt8](samples[0].payload), [0x00, 0x00])           // empty
        XCTAssertEqual([UInt8](samples[1].payload), [0x00, 0x01, 0x61])      // "a"
        XCTAssertEqual([UInt8](samples[3].payload), [0x00, 0x01, 0x62])      // "b"
    }

    func test_emptyWindowProducesSingleEmptySample() {
        let samples = HLSSegmentProducer.movTextSamples(forWindow: (0, 6), cues: [])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].pts, 0)
        XCTAssertEqual(samples[0].duration, 6)
        XCTAssertEqual([UInt8](samples[0].payload), [0x00, 0x00])
    }

    func test_perTrackWindowsAreIndependent() {
        // Two tracks with different cues in the same window; each plan covers only its own cues.
        let a: [(start: Double, end: Double, text: String)] = [(1, 2, "a")]
        let b: [(start: Double, end: Double, text: String)] = [(3, 4, "b")]
        let planA = HLSSegmentProducer.movTextSamples(forWindow: (0, 6), cues: a)
        let planB = HLSSegmentProducer.movTextSamples(forWindow: (0, 6), cues: b)
        XCTAssertTrue(planA.contains { String(bytes: $0.payload.suffix(1), encoding: .utf8) == "a" })
        XCTAssertFalse(planA.contains { String(bytes: $0.payload.suffix(1), encoding: .utf8) == "b" })
        XCTAssertTrue(planB.contains { String(bytes: $0.payload.suffix(1), encoding: .utf8) == "b" })
    }
}
