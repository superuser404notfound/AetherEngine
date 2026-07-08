import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// #112 full umbau: when reconstructing the line active at a fresh seek target, the reader decodes the region just
/// behind the playhead. A self-contained composition there (an Acquisition Point / Epoch Start) IS the current
/// on-screen line, so the gate publishes it immediately instead of holding it for successor resolution (the
/// "several tens of seconds" gap). This is confined to the reconstruction pass: once the reader decodes past the
/// playhead the gate leaves reconstruction mode, so a #100 catch-up backlog (which replays NORMAL compositions,
/// or historical acquisition points long behind the playhead) still cannot flash through the overlay.
struct Issue112PGSAcquisitionBypassTests {

    private func imageCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleCue(id: id, startTime: start, endTime: end,
                           body: .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)))
    }

    @Test("during reconstruction a self-contained composition covering the playhead publishes immediately")
    func reconstructedSelfContainedLinePublishes() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Acquisition point composed 10 s before the seek target, still on screen (open-ended). Old code held it
        // until a successor trimmed it; now it publishes at once.
        let cue = imageCue(id: 1, start: 90, end: 4_296_178)
        let out = gate.admit(cues: [cue], isPGS: true, isSelfContained: true, playhead: 100)
        #expect(out.map(\.id) == [1])
    }

    @Test("during reconstruction a normal (delta) composition behind the playhead is still held")
    func reconstructedNormalCompositionHeld() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // A Normal update is not self-contained; it cannot rebuild the line alone, so the stale hold still applies.
        let cue = imageCue(id: 1, start: 90, end: 4_296_178)
        let out = gate.admit(cues: [cue], isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.isEmpty)
        #expect(gate.hasHeld)
    }

    @Test("outside reconstruction a historical acquisition point is held (no catch-up flash)")
    func historicalAcquisitionOutsideReconstructionHeld() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = false
        // A #100 catch-up backlog can contain an acquisition point 70 s behind the playhead; it is NOT the current
        // line and must not flash. Confinement to the reconstruction pass keeps #100 intact.
        let cue = imageCue(id: 1, start: 30, end: 4_296_178)
        let out = gate.admit(cues: [cue], isPGS: true, isSelfContained: true, playhead: 100)
        #expect(out.isEmpty)
        #expect(gate.hasHeld)
    }

    @Test("reaching the playhead leaves reconstruction mode")
    func caughtUpCueExitsReconstruction() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // A live cue at the playhead means the reader has caught up; reconstruction mode ends and the cue passes.
        let live = imageCue(id: 1, start: 100, end: 4_296_178)
        let out = gate.admit(cues: [live], isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.map(\.id) == [1])
        #expect(gate.reconstructing == false)
    }

    @Test("a non-stale live composition passes through unchanged as before")
    func liveCompositionPassesThrough() {
        var gate = PGSStaleArrivalGate()
        let live = imageCue(id: 1, start: 99, end: 4_296_178)
        let out = gate.admit(cues: [live], isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.map(\.id) == [1])
    }
}
