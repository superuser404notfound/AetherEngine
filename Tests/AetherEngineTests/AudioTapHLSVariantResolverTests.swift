import XCTest
@testable import AetherEngine

final class AudioTapHLSVariantResolverTests: XCTestCase {
    private func master(_ variants: [HLSVariant], _ renditions: [HLSAudioRendition], _ demuxed: Set<String>) -> HLSPlaylist {
        .master(HLSMasterPlaylist(variants: variants, demuxedAudioGroupIDs: demuxed, audioRenditions: renditions))
    }

    func testPrefersDefaultAudioRendition() {
        let pl = master(
            [HLSVariant(bandwidth: 5_000_000, uri: "v-hi.m3u8", audioGroupID: "aud")],
            [HLSAudioRendition(groupID: "aud", uri: "a-eng.m3u8", isDefault: true),
             HLSAudioRendition(groupID: "aud", uri: "a-ger.m3u8", isDefault: false)],
            ["aud"])
        XCTAssertEqual(AudioTapHLSVariantResolver.pickAudioURI(from: pl), "a-eng.m3u8")
    }

    func testFallsBackToLowestVariantWhenMuxed() {
        let pl = master(
            [HLSVariant(bandwidth: 5_000_000, uri: "v-hi.m3u8", audioGroupID: nil),
             HLSVariant(bandwidth: 800_000, uri: "v-lo.m3u8", audioGroupID: nil)],
            [], [])
        XCTAssertEqual(AudioTapHLSVariantResolver.pickAudioURI(from: pl), "v-lo.m3u8")
    }

    func testDirectMediaReturnsNil() {
        let media = HLSMediaPlaylist(targetDuration: 6, mediaSequence: 0,
            segments: [HLSMediaSegment(uri: "s0.ts", duration: 6, discontinuityBefore: false)],
            hasEndList: true, isEncrypted: false, hasUnsupportedEncryption: false, hasMap: false)
        XCTAssertNil(AudioTapHLSVariantResolver.pickAudioURI(from: .media(media)))
    }
}
