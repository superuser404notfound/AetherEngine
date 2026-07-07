import Testing
import Foundation
@testable import AetherEngine

/// Issue #112: the synthetic PGS END flush (added for MKV converters that drop the trailing
/// 0x80 END segment) assumed every packet carries a COMPLETE display set. On a Blu-ray M2TS the
/// mpegts demuxer splits one display set across several PES packets (PCS | PDS | ODS | END), so
/// the flush fired on the intermediate PCS/PDS packet BEFORE the ODS arrived and forced a compose
/// against an object that was not defined yet: `[pgssub] Invalid object id 0`, once per display
/// set. The gate now only warrants a synthetic END when the payload already carries a complete
/// object (an ODS with the last-in-sequence flag) and no real END of its own.
struct PGSSyntheticEndGateTests {

    // PGS segment: [type:1][length:2 BE][body...]
    private func seg(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    // Segment type constants.
    private let PDS: UInt8 = 0x14
    private let ODS: UInt8 = 0x15
    private let PCS: UInt8 = 0x16
    private let WDS: UInt8 = 0x17
    private let END: UInt8 = 0x80

    // ODS body = object_id[2] + version[1] + sequence_flag[1] + (data). 0x40 = last, 0x80 = first, 0xC0 = only.
    private func ods(seqFlag: UInt8) -> [UInt8] {
        seg(ODS, [0x00, 0x00, 0x00, seqFlag, 0x00, 0x00, 0x00, 0x00])
    }

    private func warrants(_ payload: [UInt8]) -> Bool {
        payload.withUnsafeBufferPointer {
            EmbeddedSubtitleDecoder.pgsPayloadWarrantsSyntheticEnd($0.baseAddress, count: $0.count)
        }
    }

    // MARK: - The bug: intermediate M2TS fragment must NOT flush

    @Test("PCS + PDS with no object (the split-M2TS intermediate packet) does not warrant a flush")
    func intermediateFragmentDoesNotFlush() {
        let payload = seg(PCS, Array(repeating: 0x01, count: 16)) + seg(PDS, Array(repeating: 0x02, count: 20))
        #expect(payload.count > 30)          // clears the caller's size gate
        #expect(warrants(payload) == false)  // but no complete object yet -> no premature compose
    }

    @Test("a PCS-only packet does not warrant a flush")
    func pcsOnlyDoesNotFlush() {
        #expect(warrants(seg(PCS, Array(repeating: 0x01, count: 32))) == false)
    }

    @Test("a partial (first-but-not-last) object fragment does not warrant a flush")
    func firstObjectFragmentDoesNotFlush() {
        // Large bitmaps split across ODS segments; composing on the first fragment is unsafe.
        #expect(warrants(seg(PCS, [0x01]) + ods(seqFlag: 0x80)) == false)
    }

    // MARK: - The MKV case a9b493a targeted: complete block, dropped END -> flush

    @Test("a complete display set missing only its END warrants a flush")
    func completeSetMissingEndFlushes() {
        let payload = seg(PCS, [0x01, 0x02]) + seg(WDS, [0x03]) + seg(PDS, [0x04, 0x05])
            + ods(seqFlag: 0x40)   // last fragment -> object complete
        #expect(warrants(payload) == true)
    }

    @Test("an only-fragment object (first+last) warrants a flush")
    func onlyObjectFragmentFlushes() {
        #expect(warrants(seg(PCS, [0x01]) + ods(seqFlag: 0xC0)) == true)
    }

    // MARK: - A real END present -> the decoder emits naturally, never synthesize

    @Test("a payload that already contains an END never warrants a synthetic one")
    func realEndSuppressesFlush() {
        let payload = seg(PCS, [0x01]) + seg(PDS, [0x02]) + ods(seqFlag: 0x40) + seg(END, [])
        #expect(warrants(payload) == false)
    }

    @Test("END even after a complete object still suppresses the synthetic flush")
    func endAfterObjectSuppresses() {
        #expect(warrants(ods(seqFlag: 0xC0) + seg(END, [])) == false)
    }

    // MARK: - Degenerate inputs

    @Test("empty payload does not warrant a flush")
    func emptyDoesNotFlush() {
        #expect(warrants([]) == false)
    }

    @Test("a truncated header does not warrant a flush and does not crash")
    func truncatedHeaderSafe() {
        #expect(warrants([0x15, 0x00]) == false)
    }

    @Test("a segment claiming a length past the buffer end does not crash")
    func overlongLengthSafe() {
        // ODS header claims 255 body bytes but only 2 follow.
        #expect(warrants([ODS, 0x00, 0xFF, 0x01, 0x02]) == false)
    }
}
