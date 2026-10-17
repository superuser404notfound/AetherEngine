// Only with the DTSXObjectAudio trait (off by default): the decoder and its library are not built without it.
#if DTSXObjectAudio
import Testing
import Foundation
import DTSX
@testable import AetherEngine

/// LibDTSX places DTS:X in the renderer's room itself; `DTSXObjectAudioDecoder` only names the
/// channels. These pin what a listener would hear wrong: a bed or height channel on the wrong
/// speaker, or an object somewhere other than where the library put it.
@Suite("DTS:X metadata maps onto the renderer's room")
struct DTSXObjectMetadataMappingTests {

    @Test("bed and fixed-height speaker codes route to the matching speaker, LFE to LFE, objects are positioned")
    func speakerRoles() {
        // The standard DTS:X presentation: a 7.1 bed and the top front and top back pairs.
        let standard: [(UInt8, ObjectAudioRole)] = [
            (DTSX_SPEAKER_C, .bed(.center)), (DTSX_SPEAKER_L, .bed(.left)), (DTSX_SPEAKER_R, .bed(.right)),
            (DTSX_SPEAKER_LS, .bed(.sideLeft)), (DTSX_SPEAKER_RS, .bed(.sideRight)), (DTSX_SPEAKER_LFE, .lfe),
            (DTSX_SPEAKER_LB, .bed(.rearLeft)), (DTSX_SPEAKER_RB, .bed(.rearRight)),
            (DTSX_SPEAKER_TFL, .bed(.topFrontLeft)), (DTSX_SPEAKER_TFR, .bed(.topFrontRight)),
            (DTSX_SPEAKER_TBL, .bed(.topRearLeft)), (DTSX_SPEAKER_TBR, .bed(.topRearRight)),
        ]
        for (code, role) in standard {
            #expect(DTSXObjectAudioDecoder.role(forSpeaker: code) == role, "speaker \(code)")
        }
        #expect(DTSXObjectAudioDecoder.role(forSpeaker: DTSX_SPEAKER_LW) == .bed(.wideLeft))
        #expect(DTSXObjectAudioDecoder.role(forSpeaker: DTSX_SPEAKER_TSR) == .bed(.topMiddleRight))
        #expect(DTSXObjectAudioDecoder.role(forSpeaker: DTSX_SPEAKER_TFC) == .fixed(SIMD3(0.5, 0.25, 1)))
        #expect(DTSXObjectAudioDecoder.role(forSpeaker: DTSX_SPEAKER_LSD) == .fixed(SpatialSpeaker.sideLeft.position))
        #expect(DTSXObjectAudioDecoder.role(forSpeaker: DTSX_SPEAKER_RSD) == .fixed(SpatialSpeaker.sideRight.position))
        #expect(DTSXObjectAudioDecoder.role(forSpeaker: DTSX_SPEAKER_OBJECT) == .object)
        #expect(DTSXObjectAudioDecoder.role(forSpeaker: DTSX_SPEAKER_UNKNOWN) == .object)
    }

    @Test("an object keeps the room position the library gave it, at its gain")
    func object() {
        var element = DTSXElement()
        element.kind = DTSX_ELEMENT_OBJECT
        element.speaker = DTSX_SPEAKER_OBJECT
        element.flags = DTSX_ELEMENT_ACTIVE
        element.position = (1, 0.0375, 0.2667)
        element.gain = 1
        let state = DTSXObjectAudioDecoder.state(for: element)
        #expect(state.position == SIMD3(1, 0.0375, 0.2667))
        #expect(state.gain == 1)
        #expect(state.size == 0 && !state.snap && state.excluded.isEmpty)

        element.flags = 0
        #expect(DTSXObjectAudioDecoder.state(for: element).gain == 0)
    }

    @Test("an IMAX front object at 34.5°, 12° up plays mostly from its front speaker, partly from the top front")
    func imaxFrontObjectThroughThePanner() {
        // Independence Day's DTS:X carries two static objects at azimuth ±34.5°, elevation 12°.
        // LibDTSX places the right one on the right wall 0.0375 of the way back, 12/45 up; panned,
        // the floor gets cos and the ceiling sin of 12/45 of a quarter turn, as by angle.
        let layout = SpatialSpeakerLayout.l714
        var gains: [Float] = []
        AllocentricPanner(layout: layout).objectGains(
            position: SIMD3(1, 0.0375, 12.0 / 45), size: 0, snap: false, into: &gains)
        let gain = { (speaker: SpatialSpeaker) in gains[layout.speakers.firstIndex(of: speaker)!] }
        let floor = cos(Float(12.0 / 45) * .pi / 2), ceiling = sin(Float(12.0 / 45) * .pi / 2)
        #expect(abs(gain(.right) - floor * cos(0.075 * .pi / 2)) < 1e-4)
        #expect(abs(gain(.sideRight) - floor * sin(0.075 * .pi / 2)) < 1e-4)
        #expect(gain(.topFrontRight) > 0.95 * ceiling)
        #expect(gain(.left) == 0 && gain(.topFrontLeft) == 0 && gain(.rearRight) == 0)
    }

    @Test("the decoder opens, takes input and asks for more")
    func decoderLifecycle() throws {
        let decoder = try DTSXObjectAudioDecoder()
        try [UInt8](repeating: 0, count: 64).withUnsafeBytes { try decoder.push($0) }
        #expect(try decoder.nextBlock() == nil)
        decoder.reset()
        #expect(decoder.selfResetCount == 0)
    }

    @Test("input with no DTS frame in it is refused, and the verdict says so")
    func verdictRefusesNonDTS() throws {
        let decoder = try DTSXObjectAudioDecoder()
        let garbage = [UInt8](repeating: 0x55, count: 1 << 20 | 4096)
        let verdict = garbage.withUnsafeBytes { decoder.verdict(feeding: $0) }
        guard case .refused(let reason) = verdict else {
            Issue.record("expected a refusal, got \(String(describing: verdict))")
            return
        }
        #expect(reason.contains("no DTS frame"))
        // The refusal sticks, so a bridge built on it anyway would fail rather than play nothing.
        #expect(throws: DTSXObjectAudioDecoder.DecoderError.self) { try decoder.nextBlock() }
    }
}
#endif
