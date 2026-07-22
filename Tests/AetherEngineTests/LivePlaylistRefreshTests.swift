// Tests/AetherEngineTests/LivePlaylistRefreshTests.swift
// Pins live-playlist invariants across refresh-generation bumps (reproduction of the live-reload stall:
// playlist regenerated from seg0 while producer raced through a backlog). Guards: no ENDLIST/PLAYLIST-TYPE,
// CAN-BLOCK-RELOAD=YES, MEDIA-SEQUENCE==firstVisible, one EXTINF+URI per segment, refresh counter
// makes consecutive builds byte-distinct (anti -12888).
import XCTest
@testable import AetherEngine

/// Hand-controlled snapshot for driving exact (count, firstVisible, refreshCounter) sequences; only playlist-builder-relevant members are meaningful.
private final class ScriptedLiveProvider: HLSSegmentProvider, @unchecked Sendable {
    var count: Int
    var firstVisible: Int = 0
    var refresh: Int = 0

    init(count: Int) { self.count = count }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { 4.0 }

    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        refresh += 1
        return (count, firstVisible, refresh, false, 0)
    }
}

final class LivePlaylistRefreshTests: XCTestCase {

    private func lines(_ playlist: String) -> [String] {
        playlist.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Device repro shape: 20-segment backlog from seg0, no window slide. Must list all segments, stay open-ended, keep blocking-reload contract.
    func testBacklogJoinShapeIsValidAndComplete() {
        let provider = ScriptedLiveProvider(count: 20)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let ls = lines(playlist)

        XCTAssertTrue(ls.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        // Combined SERVER-CONTROL line carries CAN-BLOCK-RELOAD alongside the live-edge HOLD-BACK (AE#189).
        let serverControl = ls.first { $0.hasPrefix("#EXT-X-SERVER-CONTROL:") }
        XCTAssertTrue(serverControl?.contains("CAN-BLOCK-RELOAD=YES") ?? false)
        XCTAssertTrue(serverControl?.contains("HOLD-BACK=") ?? false)
        XCTAssertFalse(ls.contains("#EXT-X-ENDLIST"),
                       "a live playlist must stay open so AVPlayer keeps polling")
        XCTAssertFalse(ls.contains(where: { $0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }),
                       "sliding live playlists carry no PLAYLIST-TYPE tag")
        XCTAssertEqual(ls.filter { $0.hasPrefix("#EXTINF:") }.count, 20)
        XCTAssertEqual(ls.first(where: { $0.hasPrefix("seg") }), "seg0.mp4")
        XCTAssertTrue(ls.contains("seg19.mp4"))
    }

    /// Consecutive builds with no new segment must differ byte-for-byte via the refresh counter, preventing AVPlayer -12888 during quiet windows.
    func testConsecutiveBuildsDifferViaRefreshCounter() {
        let provider = ScriptedLiveProvider(count: 3)
        let first = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let second = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(lines(first).contains("#EXT-X-SODALITE-REFRESH:1"))
        XCTAssertTrue(lines(second).contains("#EXT-X-SODALITE-REFRESH:2"))

        // Refresh line is the ONLY difference: stripping it makes builds identical, proving the counter cannot disturb segment listing.
        func stripped(_ s: String) -> [String] {
            lines(s).filter { !$0.hasPrefix("#EXT-X-SODALITE-REFRESH:") }
        }
        XCTAssertEqual(stripped(first), stripped(second))
    }

    /// Racing producer appends across a refresh bump: MEDIA-SEQUENCE stays anchored to firstVisible, tail extends.
    func testAppendAcrossRefreshBumpKeepsSequenceAnchored() {
        let provider = ScriptedLiveProvider(count: 2)
        let first = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        XCTAssertEqual(lines(first).filter { $0.hasPrefix("#EXTINF:") }.count, 2)

        provider.count = 20
        let second = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let ls = lines(second)
        XCTAssertTrue(ls.contains("#EXT-X-MEDIA-SEQUENCE:0"),
                      "no window slide happened, so the sequence must stay 0")
        XCTAssertEqual(ls.filter { $0.hasPrefix("#EXTINF:") }.count, 20)

        // Window slide: MEDIA-SEQUENCE follows firstVisible, segments below it disappear.
        provider.firstVisible = 5
        let third = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let ls3 = lines(third)
        XCTAssertTrue(ls3.contains("#EXT-X-MEDIA-SEQUENCE:5"))
        XCTAssertFalse(ls3.contains("seg4.mp4"))
        XCTAssertEqual(ls3.first(where: { $0.hasPrefix("seg") }), "seg5.mp4")
        XCTAssertEqual(ls3.filter { $0.hasPrefix("#EXTINF:") }.count, 15)
    }
}
