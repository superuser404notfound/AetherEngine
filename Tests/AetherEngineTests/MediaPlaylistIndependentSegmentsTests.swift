import Foundation
import Testing
@testable import AetherEngine

/// A VOD media playlist says its segments are independent, as the master already did.
///
/// The engine hands AVPlayer the media playlist directly whenever it needs no master (SDR H.264 with no
/// subtitle or audio rendition, which is most films). Without `EXT-X-INDEPENDENT-SEGMENTS` there,
/// AVPlayer assumed a segment could depend on the one before and began every exact seek 1 to 3 segments
/// early, more the longer the GOP: a seek to 60 s (seg15, 4 s segments) asked seg14 / seg13 / seg12 for
/// 1 / 2 / 4 s GOPs. Over the master, which carries the tag, the same bytes asked seg15. On a link near
/// the media rate those extra segments are seconds per seek.
private final class StubProvider: HLSSegmentProvider, @unchecked Sendable {
    let type: HLSPlaylistType
    let outage: Bool
    let keyframeAligned: Bool

    init(type: HLSPlaylistType, outage: Bool = false, keyframeAligned: Bool = true) {
        self.type = type
        self.outage = outage
        self.keyframeAligned = keyframeAligned
    }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 10 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { type }
    var liveTargetSegmentDuration: Double? { 4.0 }
    var liveOutageEndlist: Bool { outage }
    var segmentsStartOnRandomAccess: Bool { keyframeAligned }
    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int,
                                 endlistAdded: Bool, discontinuitySequence: Int) {
        (10, 0, 0, type == .vod, 0)
    }
}

@Suite("Media playlist EXT-X-INDEPENDENT-SEGMENTS", .timeLimit(.minutes(3)))
struct MediaPlaylistIndependentSegmentsTests {

    private func lines(_ provider: StubProvider) -> [String] {
        HLSLocalServer.buildMediaPlaylistText(provider: provider)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    @Test("AE#1128: a keyframe-aligned VOD media playlist declares independent segments before its first segment")
    func vodDeclaresIndependentSegments() throws {
        let ls = lines(StubProvider(type: .vod))
        let tag = try #require(ls.firstIndex(of: "#EXT-X-INDEPENDENT-SEGMENTS"))
        let firstSegment = try #require(ls.firstIndex { $0.hasPrefix("#EXTINF:") })
        #expect(tag < firstSegment)
    }

    /// A uniform stride (no usable index, a sequential archive) opens a segment at the first keyframe
    /// past its boundary, up to a GOP late: the frames before it sit in the segment before.
    @Test("AE#1128: a VOD playlist on a uniform-stride plan makes no such claim")
    func uniformPlanStaysUnclaimed() {
        #expect(!lines(StubProvider(type: .vod, keyframeAligned: false)).contains("#EXT-X-INDEPENDENT-SEGMENTS"))
    }

    /// Live cuts can be forced (an ad seam) and a join starts mid-GOP, so the claim would not hold there.
    @Test("AE#1128: live, event and an outage window make no such claim", arguments: [
        (HLSPlaylistType.live, false), (.event, false), (.live, true),
    ])
    func othersStayUnclaimed(type: HLSPlaylistType, outage: Bool) {
        #expect(!lines(StubProvider(type: type, outage: outage)).contains("#EXT-X-INDEPENDENT-SEGMENTS"))
    }
}
