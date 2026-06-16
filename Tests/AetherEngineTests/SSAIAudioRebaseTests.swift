// Tests/AetherEngineTests/SSAIAudioRebaseTests.swift
//
// Guards the audio-shift derivation across an SSAI program boundary
// (HLSSegmentProducer.seamDerivedAudioShift). Pluto's amux ad creatives
// mux their audio on a DIFFERENT source clock than their video: the ad
// video restarts at source dts 0 while the amux audio restarts near 2^33
// (the MPEG-TS 33-bit modulus). Handing audio the video's shift verbatim
// (the pre-fix behavior) then offsets audio by that ~2^33 base difference,
// launching it ~26 h into the future so the audio renderer hangs. These
// values are taken verbatim from the device log of the freeze repro.
import XCTest
@testable import AetherEngine

final class SSAIAudioRebaseTests: XCTestCase {

    private let ptsModulus: Int64 = 8_589_934_592 // 2^33, MPEG-TS wrap

    /// Output dts is `srcDts - shift`; the boundary packet must land on the
    /// video seam regardless of the audio source base.
    private func audioOutput(srcDts: Int64, shift: Int64) -> Int64 {
        srcDts - shift
    }

    // The breaking transition: bumper -> amux ad creative. Video seam output
    // is 15_675_000 (90 kHz); the amux audio boundary packet is at 2^33.
    func testAmuxAdAudioLandsOnVideoSeamDespiteDifferentBase() {
        let videoSeamOut: Int64 = 15_675_000
        let audioBoundarySrcDts = ptsModulus // 8_589_934_592, the amux base

        let shift = HLSSegmentProducer.seamDerivedAudioShift(
            audioBoundarySrcDts: audioBoundarySrcDts,
            seamOutAudioTb: videoSeamOut
        )
        let out = audioOutput(srcDts: audioBoundarySrcDts, shift: shift)

        // Audio's first packet must sit exactly on the video seam.
        XCTAssertEqual(out, videoSeamOut)
    }

    // Regression sentinel: the pre-fix path copied the video shift verbatim
    // (-15_675_000 in the log). Prove that approach hurled audio ~2^33 ticks
    // into the future, which is what hung the renderer.
    func testCopyingVideoShiftVerbatimWouldHangAudio() {
        let videoShift: Int64 = -15_675_000 // from the device log
        let audioBoundarySrcDts = ptsModulus

        let brokenOut = audioOutput(srcDts: audioBoundarySrcDts, shift: videoShift)

        // ~8.6 billion ticks (~26.5 h at 90 kHz) ahead: the hang.
        XCTAssertGreaterThan(brokenOut, ptsModulus)
        // The fix keeps audio in the same neighborhood as the video seam.
        let fixedShift = HLSSegmentProducer.seamDerivedAudioShift(
            audioBoundarySrcDts: audioBoundarySrcDts,
            seamOutAudioTb: 15_675_000
        )
        let fixedOut = audioOutput(srcDts: audioBoundarySrcDts, shift: fixedShift)
        XCTAssertLessThan(abs(fixedOut - 15_675_000), 90_000) // within 1 s
    }

    // Shared-base case (content -> bumper, both streams at 2^33): the fix must
    // reproduce the old, correct result so it is a strict improvement. From the
    // log: audio srcDts 8_590_024_592, video seam output 15_231_000, the old
    // path produced shift 8_574_793_592.
    func testSharedBaseMatchesLegacyShift() {
        let audioBoundarySrcDts: Int64 = 8_590_024_592
        let videoSeamOut: Int64 = 15_231_000

        let shift = HLSSegmentProducer.seamDerivedAudioShift(
            audioBoundarySrcDts: audioBoundarySrcDts,
            seamOutAudioTb: videoSeamOut
        )
        XCTAssertEqual(shift, 8_574_793_592)
        XCTAssertEqual(audioOutput(srcDts: audioBoundarySrcDts, shift: shift), videoSeamOut)
    }
}
