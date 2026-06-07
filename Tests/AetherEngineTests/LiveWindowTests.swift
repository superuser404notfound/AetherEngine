// Tests/AetherEngineTests/LiveWindowTests.swift
import XCTest
@testable import AetherEngine

final class LiveWindowTests: XCTestCase {
    func testEdgeAdvances() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(10); w.noteEdge(25)
        XCTAssertEqual(w.edgeTime, 25, accuracy: 0.001)
    }
    func testEdgeIsMonotonic() {
        var w = LiveWindow(windowSeconds: 1800)
        w.noteEdge(25); w.noteEdge(10)
        XCTAssertEqual(w.edgeTime, 25, accuracy: 0.001)
    }
    func testRangeRampsThenCaps() {
        var w = LiveWindow(windowSeconds: 60)
        w.noteEdge(30)
        XCTAssertEqual(w.seekableRange, 0...30)
        w.noteEdge(200)
        XCTAssertEqual(w.seekableRange, 140...200)
    }
    func testClampInsideRange() {
        var w = LiveWindow(windowSeconds: 60); w.noteEdge(200)
        XCTAssertEqual(w.clamp(10), 140)
        XCTAssertEqual(w.clamp(300), 200)
        XCTAssertEqual(w.clamp(170), 170)
    }
    func testBehindLiveAndAtEdge() {
        var w = LiveWindow(windowSeconds: 60); w.noteEdge(200)
        w.notePlayhead(200)
        XCTAssertTrue(w.isAtEdge); XCTAssertEqual(w.behindLiveSeconds, 0, accuracy: 0.001)
        w.notePlayhead(190)
        XCTAssertFalse(w.isAtEdge); XCTAssertEqual(w.behindLiveSeconds, 10, accuracy: 0.001)
    }
    func testNilWhenDisabled() {
        var w = LiveWindow(windowSeconds: nil); w.noteEdge(100)
        XCTAssertNil(w.seekableRange)
    }
}
