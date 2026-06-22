// Tests/AetherEngineTests/NativeSubtitleCueStoreTests.swift
import XCTest
@testable import AetherEngine

final class NativeSubtitleCueStoreTests: XCTestCase {
    private func cue(_ id: Int, _ a: Double, _ b: Double, _ s: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: a, endTime: b, body: .text(s))
    }

    func test_windowReturnsOverlappingCuesOnAVPlayerAxis() {
        let store = NativeSubtitleCueStore()
        store.setShiftSeconds(10)
        store.replaceCues([cue(1, 100, 102, "a"), cue(2, 200, 201, "b")]) // axis: 90-92, 190-191
        let win = store.cuesInWindow(start: 88, end: 94)
        XCTAssertEqual(win.count, 1)
        XCTAssertEqual(win[0].text, "a")
        XCTAssertEqual(win[0].start, 90, accuracy: 0.0001)
    }

    func test_filtersBitmapCues_clearReleases() {
        let store = NativeSubtitleCueStore()
        store.appendCues([cue(1, 0, 1, "t")])
        XCTAssertEqual(store.cueCount, 1)
        store.clear()
        XCTAssertEqual(store.cueCount, 0)
    }
}
