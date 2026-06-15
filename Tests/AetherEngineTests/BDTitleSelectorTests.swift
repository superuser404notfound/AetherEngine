import XCTest
@testable import AetherEngine

final class BDTitleSelectorTests: XCTestCase {
    func test_picksLongestPlaylist() {
        let a = MPLSPlaylist(clipIDs: ["00001"], durationTicks: 100)
        let b = MPLSPlaylist(clipIDs: ["00002", "00003"], durationTicks: 9000)
        let c = MPLSPlaylist(clipIDs: ["00004"], durationTicks: 500)
        XCTAssertEqual(BDTitleSelector.selectMainTitle([a, b, c]), b)
    }

    func test_nilWhenEmpty() {
        XCTAssertNil(BDTitleSelector.selectMainTitle([]))
    }
}
