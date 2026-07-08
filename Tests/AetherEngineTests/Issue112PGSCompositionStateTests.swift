import Foundation
import Testing
@testable import AetherEngine

/// #112 full umbau: a PGS composition can be a Normal update, an Acquisition Point, or an Epoch Start. The latter
/// two are self-contained restatements of the on-screen line (the disc's own random-access anchors), so a
/// reconstruction pass that decodes one can publish the line immediately instead of holding it as a stale replay.
/// `pgsCompositionState` reads that state from the PCS (0x16) segment's `composition_state` byte (body offset 7:
/// 0x00 Normal / 0x40 Acquisition Point / 0x80 Epoch Start).
struct Issue112PGSCompositionStateTests {

    /// Build a PGS segment run: each segment is [type:1][len:2 BE][body:len].
    private func segment(type: UInt8, body: [UInt8]) -> [UInt8] {
        let len = body.count
        return [type, UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)] + body
    }

    /// A PCS (0x16) body with a given composition_state at offset 7.
    /// Layout: width[2] height[2] frame_rate[1] composition_number[2] composition_state[1] ...
    private func pcsBody(compositionState: UInt8) -> [UInt8] {
        [0x07, 0x80, 0x04, 0x38, 0x10, 0x00, 0x01, compositionState, 0x00, 0x00]
    }

    private func state(_ bytes: [UInt8]) -> EmbeddedSubtitleDecoder.PGSCompositionState? {
        bytes.withUnsafeBufferPointer {
            EmbeddedSubtitleDecoder.pgsCompositionState($0.baseAddress, count: $0.count)
        }
    }

    @Test("an epoch-start PCS reads as .epochStart")
    func epochStart() {
        #expect(state(segment(type: 0x16, body: pcsBody(compositionState: 0x80))) == .epochStart)
    }

    @Test("an acquisition-point PCS reads as .acquisitionPoint")
    func acquisitionPoint() {
        #expect(state(segment(type: 0x16, body: pcsBody(compositionState: 0x40))) == .acquisitionPoint)
    }

    @Test("a normal PCS reads as .normal")
    func normalComposition() {
        #expect(state(segment(type: 0x16, body: pcsBody(compositionState: 0x00))) == .normal)
    }

    @Test("only the top two composition_state bits matter")
    func ignoresLowBits() {
        // Real streams carry the palette_update_flag / palette_id in the low bits of the same byte; the state is
        // the top two bits, so an acquisition point with low bits set still reads as .acquisitionPoint.
        #expect(state(segment(type: 0x16, body: pcsBody(compositionState: 0x40 | 0x1F))) == .acquisitionPoint)
    }

    @Test("the PCS is found after a leading PDS/ODS segment")
    func findsPCSAmongSegments() {
        let pds = segment(type: 0x14, body: [0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        let pcs = segment(type: 0x16, body: pcsBody(compositionState: 0x80))
        #expect(state(pds + pcs) == .epochStart)
    }

    @Test("a payload with no PCS returns nil")
    func noPCSReturnsNil() {
        let ods = segment(type: 0x15, body: [0x00, 0x00, 0x01, 0xC0, 0x00, 0x10, 0x00, 0x10])
        let end = segment(type: 0x80, body: [])
        #expect(state(ods + end) == nil)
    }

    @Test("a PCS body too short to hold composition_state returns nil")
    func truncatedPCSReturnsNil() {
        // A body shorter than 8 bytes cannot carry composition_state at offset 7; refuse rather than read OOB.
        #expect(state(segment(type: 0x16, body: [0x07, 0x80, 0x04, 0x38])) == nil)
    }
}
