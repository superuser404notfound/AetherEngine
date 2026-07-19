import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// #143 (cmcpherson274): a seek landing mid-cue (or exactly on a display-set start boundary) on a
/// PGS stream WITHOUT acquisition points never re-showed the landing line, forced cues included,
/// until the next authored composition arrived. On sparse dialogue the blackout ran tens of seconds.
///
/// Root cause: the reconstruction pass seeded its active-line candidate only from a self-contained
/// composition (Acquisition Point / Epoch Start). On AP-less/sparse-authored streams every lead-in
/// composition is Normal, so no candidate was ever seeded and the landing-span line was silently
/// discarded; the pass-ending composition (the NEXT line) published fine, which is why "first new
/// cue after seek" instruments looked clean.
///
/// The fix seeds the candidate from ANY successfully decoded composition behind the playhead. A
/// composition that decodes at all is renderable by definition (a fresh drain decoder has no stale
/// state; a state-dependent set with missing references fails decode and never reaches the gate),
/// and the steady-state path outside reconstruction already publishes Normal compositions without a
/// self-contained check. Companion fix: every PGS composition and clear broadcasts its start as
/// `pgsTrimAt`; that trim now also closes the candidate's open window, so a line authored to be
/// gone by the playhead (a clear in the lead-in) cannot resurrect at pass end.
struct Issue143PGSLandingLineTests {

    private func imageCue(id: Int, start: Double, end: Double = 4_296_178) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleCue(id: id, startTime: start, endTime: end,
                           body: .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)))
    }

    @Test("AP-less lead-in: the landing-span line seeds the candidate and publishes at pass end")
    func aplessLandingLinePublishes() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Normal-state composition (no acquisition point anywhere in the lead-in) 8 s behind the
        // landing, still open at the playhead. Held as candidate, published once the decode reaches
        // the playhead.
        #expect(gate.admit(cues: [imageCue(id: 1, start: 92)], isPGS: true,
                           isSelfContained: false, playhead: 100).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 2, start: 106)], isPGS: true,
                             isSelfContained: false, playhead: 100)
        #expect(out.map(\.id).sorted() == [1, 2])
        #expect(gate.reconstructing == false)
        #expect(!gate.hasHeld)
    }

    @Test("boundary landing with the tick playhead already past the boundary still paints the landing line")
    func boundaryLandingWithAdvancedPlayhead() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Seek lands exactly on the display set's start (120.0) but the drain tick's playhead has
        // advanced a few frames by the time the backscan decodes it, turning it into the mid-cue
        // shape. The reporter measured this variant dropping the line 13/14 batteries.
        #expect(gate.admit(cues: [imageCue(id: 1, start: 120.0)], isPGS: true,
                           isSelfContained: false, playhead: 120.3).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 2, start: 126)], isPGS: true,
                             isSelfContained: false, playhead: 120.3)
        #expect(out.map(\.id).sorted() == [1, 2])
    }

    @Test("AP-less lead-in does not scroll: only the newest line behind the playhead publishes")
    func aplessLeadInNoScroll() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        let p = 100.0
        // The #112 no-scroll invariant must hold for Normal compositions exactly as it does for
        // acquisition points: nothing publishes until the pass ends, then only the newest.
        #expect(gate.admit(cues: [imageCue(id: 1, start: 78)], isPGS: true,
                           isSelfContained: false, playhead: p).isEmpty)
        #expect(gate.admit(cues: [imageCue(id: 2, start: 85)], isPGS: true,
                           isSelfContained: false, playhead: p).isEmpty)
        #expect(gate.admit(cues: [imageCue(id: 3, start: 92)], isPGS: true,
                           isSelfContained: false, playhead: p).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 4, start: 106)], isPGS: true,
                             isSelfContained: false, playhead: p)
        #expect(out.map(\.id).sorted() == [3, 4])
    }

    @Test("a clear in the lead-in ends the candidate: the cleared line does not resurrect at pass end")
    func clearedLineDoesNotResurrect() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Line at 90 followed by an authored clear at 95; the viewer lands at 100 during silence.
        _ = gate.admit(cues: [imageCue(id: 1, start: 90)], isPGS: true,
                       isSelfContained: false, playhead: 100)
        // The clear composition carries no cues; its pgsTrimAt is the only thing that reaches the
        // gate. It must close the candidate's open placeholder window.
        #expect(gate.resolveHeld(trimAt: 95, playhead: 100).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 2, start: 106)], isPGS: true,
                             isSelfContained: false, playhead: 100)
        #expect(out.map(\.id) == [2])
    }

    @Test("acquisition-point content: a cleared candidate does not resurrect either")
    func clearedSelfContainedCandidateDoesNotResurrect() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Same shape with an acquisition point: this hole predates #143 (the candidate ignored
        // clears entirely) and is locked here for AP-full content too.
        _ = gate.admit(cues: [imageCue(id: 1, start: 90)], isPGS: true,
                       isSelfContained: true, playhead: 100)
        #expect(gate.resolveHeld(trimAt: 95, playhead: 100).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 2, start: 106)], isPGS: true,
                             isSelfContained: true, playhead: 100)
        #expect(out.map(\.id) == [2])
    }

    @Test("a clear ahead of the playhead closes the emitted landing line at the clear, not the successor")
    func aheadClearClosesEmittedLine() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Landing line open at the playhead, authored to end at 103 (clear), next line at 130.
        _ = gate.admit(cues: [imageCue(id: 1, start: 92)], isPGS: true,
                       isSelfContained: false, playhead: 100)
        #expect(gate.resolveHeld(trimAt: 103, playhead: 100).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 2, start: 130)], isPGS: true,
                             isSelfContained: false, playhead: 100)
        let landing = out.first { $0.id == 1 }
        #expect(landing != nil)
        #expect(landing?.endTime == 103)
    }

    @Test("a later composition still refines a candidate seeded from a Normal composition")
    func normalSeedRefinedByNewerComposition() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        _ = gate.admit(cues: [imageCue(id: 1, start: 80)], isPGS: true,
                       isSelfContained: false, playhead: 100)
        _ = gate.admit(cues: [imageCue(id: 2, start: 95)], isPGS: true,
                       isSelfContained: false, playhead: 100)
        let out = gate.admit(cues: [imageCue(id: 3, start: 110)], isPGS: true,
                             isSelfContained: false, playhead: 100)
        #expect(out.map(\.id).sorted() == [2, 3])
    }
}
