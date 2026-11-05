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

    @Test("an element is a point at its position with its gain, and nothing else")
    func pointSource() {
        let flags = TRUEHD_ATMOS_ELEMENT_ACTIVE | TRUEHD_ATMOS_ELEMENT_SNAP | TRUEHD_ATMOS_ELEMENT_SCREEN_REF
        let state = TrueHDObjectAudioDecoder.pointSource(
            for: element(flags: flags, position: (0.8, 0.6, 1), size: (0.4, 0.4, 0.4), zone: TRUEHD_ATMOS_ZONE_NO_BACK))
        #expect(state == ObjectAudioElementState(position: SIMD3(0.8, 0.6, 1), gain: 0.5))
        #expect(TrueHDObjectAudioDecoder.pointSource(for: element(flags: 0)).gain == 0)
        #expect(TrueHDObjectAudioDecoder.pointSource(for: element(position: (0.5, 0.5, -0.6))).position.z == 0)
        #expect(TrueHDObjectAudioDecoder.pointSource(for: element(kind: TRUEHD_ATMOS_ELEMENT_ISF)).position
                == SIMD3(0.5, 0.5, 0.5))
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
