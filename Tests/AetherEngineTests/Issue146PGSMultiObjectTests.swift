import Foundation
import CoreGraphics
import Testing
import Libavcodec
@testable import AetherEngine

/// #146 (cmcpherson274): a PGS display set can carry MULTIPLE composition objects at the same start
/// PTS (a forced sign at the top plus dialogue at the bottom, a common real-disc shape). The decoder
/// correctly fans N objects into N same-start image cues, but the retained store's same-start image
/// replacement then collapsed the siblings onto the last object: "a PGS composition has a unique
/// start PTS" is true per COMPOSITION, false per composition OBJECT.
///
/// Fix: the replacement is keyed on (start, object geometry). A re-decode of the same object (the
/// audio-switch preserved placeholder vs its reconstruction, or a post-seek backscan re-decode)
/// reproduces its position and pixel size exactly (the alpha-bounding-box crop is deterministic),
/// so it still replaces; a sibling object differs in geometry and both are kept, mirroring the text
/// path's "distinct simultaneous speakers" rule.
///
/// Same class of collapse one level up: the reconstruction pass held a SINGLE candidate cue, so a
/// multi-object landing set lost all but one object at seek time. The candidate is now the whole
/// same-start group.
///
/// API half: `AVSubtitleRect.flags` (AV_SUBTITLE_FLAG_FORCED) is now read into
/// `SubtitleImage.isForced`, surfaced per cue via `SubtitleCue.isForced`, so hosts can distinguish
/// a forced sign from dialogue.
struct Issue146PGSMultiObjectTests {

    /// Reporter geometry: forced top sign [685,110,550,59] + dialogue [685,910,550,59] on 1920x1080.
    private static let signRect = CGRect(x: 685.0 / 1920, y: 110.0 / 1080,
                                         width: 550.0 / 1920, height: 59.0 / 1080)
    private static let dialogueRect = CGRect(x: 685.0 / 1920, y: 910.0 / 1080,
                                             width: 550.0 / 1920, height: 59.0 / 1080)

    private func body(position: CGRect, forced: Bool = false) -> SubtitleCue.Body {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return .image(SubtitleImage(cgImage: ctx.makeImage()!, position: position,
                                    canvasSize: CGSize(width: 1920, height: 1080),
                                    isForced: forced))
    }

    private func imageCue(id: Int, start: Double, end: Double = 4_296_178,
                          position: CGRect, forced: Bool = false) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: body(position: position, forced: forced))
    }

    // MARK: - Retained store

    @Test("sibling objects of one display set (same start, different geometry) are both kept")
    func sameStartSiblingObjectsBothKept() {
        var cues: [SubtitleCue] = []
        var nextID = 1
        AetherEngine.insertCueSorted(imageCue(id: 0, start: 30, position: Self.signRect, forced: true),
                                     into: &cues, nextID: &nextID)
        AetherEngine.insertCueSorted(imageCue(id: 0, start: 30, position: Self.dialogueRect),
                                     into: &cues, nextID: &nextID)
        #expect(cues.count == 2)
        #expect(cues.allSatisfy { $0.startTime == 30 })
    }

    @Test("a same-start re-decode of the SAME object still replaces its placeholder (#112 contract)")
    func sameStartSameGeometryReplaces() {
        var cues: [SubtitleCue] = []
        var nextID = 1
        AetherEngine.insertCueSorted(imageCue(id: 0, start: 100, position: Self.dialogueRect),
                                     into: &cues, nextID: &nextID)
        // Reconstruction re-decodes the same object at start=100 with a real (trimmed) end.
        AetherEngine.insertCueSorted(imageCue(id: 0, start: 100, end: 118, position: Self.dialogueRect),
                                     into: &cues, nextID: &nextID)
        #expect(cues.count == 1)
        #expect(cues[0].endTime == 118)
    }

    @Test("each sibling's re-decode replaces its own geometric twin, not the other sibling")
    func siblingRedecodeReplacesTwinOnly() {
        var cues: [SubtitleCue] = []
        var nextID = 1
        AetherEngine.insertCueSorted(imageCue(id: 0, start: 30, position: Self.signRect, forced: true),
                                     into: &cues, nextID: &nextID)
        AetherEngine.insertCueSorted(imageCue(id: 0, start: 30, position: Self.dialogueRect),
                                     into: &cues, nextID: &nextID)
        AetherEngine.insertCueSorted(imageCue(id: 0, start: 30, end: 60, position: Self.dialogueRect),
                                     into: &cues, nextID: &nextID)
        #expect(cues.count == 2)
        let dialogue = cues.first { cue in
            guard case .image(let img) = cue.body else { return false }
            return img.position == Self.dialogueRect
        }
        #expect(dialogue?.endTime == 60)
    }

    // MARK: - Reconstruction gate

    @Test("a multi-object landing set publishes ALL its objects at pass end, trimmed to the successor")
    func multiObjectLandingSetPublishesAllObjects() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        let landing = [imageCue(id: 1, start: 92, position: Self.signRect, forced: true),
                       imageCue(id: 2, start: 92, position: Self.dialogueRect)]
        #expect(gate.admit(cues: landing, isPGS: true, isSelfContained: false, playhead: 100).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 3, start: 106, position: Self.dialogueRect)],
                             isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.map(\.id).sorted() == [1, 2, 3])
        for cue in out where cue.startTime == 92 {
            #expect(cue.endTime == 106)
        }
        #expect(gate.reconstructing == false)
        #expect(!gate.hasHeld)
    }

    @Test("a newer single-object composition supersedes the whole multi-object candidate group")
    func newerCompositionSupersedesWholeGroup() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        let landing = [imageCue(id: 1, start: 80, position: Self.signRect, forced: true),
                       imageCue(id: 2, start: 80, position: Self.dialogueRect)]
        #expect(gate.admit(cues: landing, isPGS: true, isSelfContained: false, playhead: 100).isEmpty)
        #expect(gate.admit(cues: [imageCue(id: 3, start: 95, position: Self.dialogueRect)],
                           isPGS: true, isSelfContained: false, playhead: 100).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 4, start: 106, position: Self.dialogueRect)],
                             isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.map(\.id).sorted() == [3, 4])
    }

    @Test("a clear before the playhead closes the whole candidate group (#143 trim, per member)")
    func clearTrimsWholeCandidateGroup() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        let landing = [imageCue(id: 1, start: 92, position: Self.signRect, forced: true),
                       imageCue(id: 2, start: 92, position: Self.dialogueRect)]
        #expect(gate.admit(cues: landing, isPGS: true, isSelfContained: false, playhead: 100).isEmpty)
        // Author cleared the set at 95, behind the playhead: neither member may resurrect.
        #expect(gate.resolveHeld(trimAt: 95, playhead: 100).isEmpty)
        let out = gate.admit(cues: [imageCue(id: 3, start: 106, position: Self.dialogueRect)],
                             isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.map(\.id) == [3])
    }

    @Test("steady-state stale hold resolves ALL objects of a held multi-object event")
    func staleHoldResolvesAllObjects() {
        var gate = PGSStaleArrivalGate()
        let stale = [imageCue(id: 1, start: 40, position: Self.signRect, forced: true),
                     imageCue(id: 2, start: 40, position: Self.dialogueRect)]
        #expect(gate.admit(cues: stale, isPGS: true, playhead: 60).isEmpty)
        let resolved = gate.resolveHeld(trimAt: 70, playhead: 60)
        #expect(resolved.map(\.id).sorted() == [1, 2])
    }

    // MARK: - Forced flag surface

    @Test("SubtitleCue.isForced reflects the image's forced flag; text cues are never forced")
    func forcedFlagSurface() {
        let forced = imageCue(id: 1, start: 0, position: Self.signRect, forced: true)
        let plain = imageCue(id: 2, start: 0, position: Self.dialogueRect)
        let text = SubtitleCue(id: 3, startTime: 0, endTime: 1, body: .text("dialogue"))
        #expect(forced.isForced)
        #expect(!plain.isForced)
        #expect(!text.isForced)
    }

    @Test("AV_SUBTITLE_FLAG_FORCED on the decoded rect lands in SubtitleImage.isForced")
    func forcedFlagReadFromRect() {
        var pixels: [UInt8] = [1, 1]
        var palette: [UInt8] = [0, 0, 0, 0, 255, 255, 255, 255]
        pixels.withUnsafeMutableBufferPointer { pix in
            palette.withUnsafeMutableBufferPointer { pal in
                var rect = AVSubtitleRect()
                rect.type = SUBTITLE_BITMAP
                rect.x = 685; rect.y = 110
                rect.w = 2; rect.h = 1
                rect.linesize.0 = 2
                rect.data.0 = pix.baseAddress
                rect.data.1 = pal.baseAddress
                rect.flags = AV_SUBTITLE_FLAG_FORCED
                withUnsafeMutablePointer(to: &rect) { r in
                    let image = EmbeddedSubtitleDecoder.imageForSubtitleRect(r, videoWidth: 1920, videoHeight: 1080)
                    #expect(image?.isForced == true)
                }
                rect.flags = 0
                withUnsafeMutablePointer(to: &rect) { r in
                    let image = EmbeddedSubtitleDecoder.imageForSubtitleRect(r, videoWidth: 1920, videoHeight: 1080)
                    #expect(image?.isForced == false)
                }
            }
        }
    }
}
