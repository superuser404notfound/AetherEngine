// Only with the TrueHDObjectAudio trait (off by default): the decoder and its library are not built without it.
#if TrueHDObjectAudio
import Testing
import Foundation
import TrueHD
@testable import AetherEngine

/// The TrueHD decoder reports OAMD as the bitstream states it; `TrueHDObjectAudioDecoder` turns
/// that into what the renderer acts on (#731). These pin the translations a listener would hear
/// wrong: a bed channel on the wrong speaker, a floor-only object in the ceiling, a zone mask
/// that does not keep an object off the speakers it names.
@Suite("TrueHD object metadata maps onto the renderer's room")
struct TrueHDObjectMetadataMappingTests {

    private func element(
        kind: UInt8 = TRUEHD_ATMOS_ELEMENT_OBJECT,
        flags: UInt32 = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION,
        position: (Float, Float, Float) = (0.25, 0.5, 0.75),
        gain: Float = 0.5,
        size: (Float, Float, Float) = (0, 0, 0),
        zone: UInt8 = TRUEHD_ATMOS_ZONE_ALL
    ) -> TrueHDAtmosElement {
        var e = TrueHDAtmosElement()
        e.kind = kind
        e.speaker = TRUEHD_ATMOS_SPEAKER_OBJECT
        e.zone = zone
        e.flags = flags
        e.position = position
        e.gain = gain
        e.size = size
        return e
    }

    @Test("bed speaker codes route to the matching speaker, LFE to LFE, the rest are positioned")
    func speakerRoles() {
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_L) == .bed(.left))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_LS) == .bed(.sideLeft))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_RB) == .bed(.rearRight))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_TSR) == .bed(.topMiddleRight))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_LFE) == .lfe)
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_LFE2) == .lfe)
        // No home layout has the screen, centre back or top centre channels; they sit at their
        // nominal position so a presentation without metadata still plays them.
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_TC) == .fixed(SIMD3(0.5, 0.5, 1)))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_TFC) == .fixed(SIMD3(0.5, 0.25, 1)))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_CB) == .fixed(SIMD3(0.5, 1, 0)))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_LSC) == .fixed(SIMD3(0.25, 0, 0)))
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_OBJECT) == .object)
        #expect(TrueHDObjectAudioDecoder.role(forSpeaker: TRUEHD_ATMOS_SPEAKER_UNKNOWN) == .object)
    }

    @Test("an active elevated object keeps its position, gain and largest size dimension")
    func plainObject() {
        let state = TrueHDObjectAudioDecoder.state(for: element(size: (0.1, 0.3, 0.2)))
        #expect(state.position == SIMD3(0.25, 0.5, 0.75))
        #expect(state.gain == 0.5)
        #expect(state.size == 0.3)
        #expect(state.excluded.isEmpty)
        #expect(!state.snap)
    }

    @Test("an inactive object is silent")
    func inactiveObject() {
        let state = TrueHDObjectAudioDecoder.state(for: element(flags: TRUEHD_ATMOS_ELEMENT_ELEVATION))
        #expect(state.gain == 0)
    }

    @Test("an object without elevation stays off every height speaker")
    func noElevation() {
        let state = TrueHDObjectAudioDecoder.state(for: element(flags: TRUEHD_ATMOS_ELEMENT_ACTIVE))
        let heights = Set(SpatialSpeaker.allCases.filter(\.isHeight))
        #expect(heights.isSubset(of: state.excluded))
        #expect(!state.excluded.contains(.left))
    }

    @Test("a position below the ear-level plane is clamped to it")
    func belowEarLevel() {
        let state = TrueHDObjectAudioDecoder.state(for: element(position: (0.5, 0.5, -0.6)))
        #expect(state.position.z == 0)
    }

    @Test("a screen-anchored object keeps its room depth, the top of the screen halfway up the room")
    func screenReference() {
        let flags = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION | TRUEHD_ATMOS_ELEMENT_SCREEN_REF
        // Only x and z are screen-anchored; y is still depth, so an object flying from the screen to
        // the back wall travels (review of eae933d0 found it pinned to the front wall).
        let state = TrueHDObjectAudioDecoder.state(for: element(flags: flags, position: (0.8, 0.6, 1)))
        #expect(state.position == SIMD3(0.8, 0.6, 0.5))
    }

    @Test("an ISF object, whose position is not decoded, is spread over the room")
    func isfSpread() {
        let state = TrueHDObjectAudioDecoder.state(for: element(kind: TRUEHD_ATMOS_ELEMENT_ISF, position: (0, 0, 0)))
        #expect(state.position == SIMD3(0.5, 0.5, 0.5))
        #expect(state.size == 1)
    }

    @Test("snap is carried through")
    func snap() {
        let flags = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_ELEVATION | TRUEHD_ATMOS_ELEMENT_SNAP
        #expect(TrueHDObjectAudioDecoder.state(for: element(flags: flags)).snap)
    }

    @Test("zone masks keep an object off the speakers they name")
    func zoneMasks() {
        let noBack = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_NO_BACK)
        #expect(noBack.isSuperset(of: [.rearLeft, .rearRight]))
        #expect(!noBack.contains(.sideLeft))
        // TS 103 448 table 4: on a 3/2 floor neither no-back nor no-sides removes the surrounds.
        #expect(!noBack.contains(.surroundLeft) && !noBack.contains(.surroundRight))

        let noSides = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_NO_SIDES)
        #expect(noSides.isSuperset(of: [.sideLeft, .sideRight]))
        #expect(!noSides.contains(.rearLeft) && !noSides.contains(.surroundLeft))

        let screen = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_SCREEN_ONLY)
        #expect(!screen.contains(.left) && !screen.contains(.center) && !screen.contains(.right))
        #expect(screen.isSuperset(of: [.sideLeft, .rearRight, .surroundLeft, .surroundRight]))

        let surround = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_SURROUND_ONLY)
        #expect(surround.isSuperset(of: [.left, .right, .center]))
        #expect(!surround.contains(.sideLeft))

        let centerBack = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_CENTER_BACK)
        #expect(centerBack.isSuperset(of: [.left, .right, .sideLeft, .sideRight]))
        #expect(!centerBack.contains(.center) && !centerBack.contains(.rearLeft))

        #expect(TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_ALL).isEmpty)
    }

    @Test("a zone mask applied through the panner keeps the object's power on the allowed speakers")
    func zoneMaskThroughPanner() {
        let layout = SpatialSpeakerLayout.l714
        let excluded = TrueHDObjectAudioDecoder.excludedSpeakers(zone: TRUEHD_ATMOS_ZONE_NO_BACK)
        let panner = AllocentricPanner(layout: layout, excluded: excluded)
        var gains: [Float] = []
        panner.objectGains(position: SIMD3(0.1, 1, 0), size: 0, snap: false, into: &gains)
        for (channel, speaker) in layout.speakers.enumerated() where excluded.contains(speaker) {
            #expect(gains[channel] == 0, "\(speaker)")
        }
        #expect(abs(gains.reduce(0) { $0 + $1 * $1 } - 1) < 1e-5)
    }

    @Test("the decoder opens, takes input and asks for more")
    func decoderLifecycle() throws {
        let decoder = try TrueHDObjectAudioDecoder()
        let junk = [UInt8](repeating: 0x5A, count: 4096)
        try junk.withUnsafeBytes { try decoder.push($0) }
        #expect(try decoder.nextBlock() == nil)
        decoder.reset()
        #expect(try decoder.nextBlock() == nil)
    }
}
#endif
