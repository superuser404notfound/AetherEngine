import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// #112 round 8 (ijuniorfu, 0.9.17): "Subtitles occasionally overlap" after a fast-forward / audio-track switch.
///
/// Root cause: when a reconstruction pass ends, the gate emits the held candidate active line together with the
/// pass-ending event's ahead-of-playhead cues. The candidate still carries its open-ended placeholder window: the
/// successor composition's `pgsTrimAt` ran against the retained store while the candidate was held inside the
/// gate, so nothing ever closed it. Once the playhead reaches the successor's start, BOTH lines cover it and both
/// render until the next composition's trim finally lands, stacking two PGS bitmaps on screen.
///
/// The fix trims the emitted active line at the earliest published ahead cue's start. A pass that ends with no
/// ahead cue (the live line decoded exactly at the playhead) keeps its open window as before; the next
/// composition trims it through the store.
struct Issue112PGSReconstructionOverlapTests {

    private static let openPlaceholderEnd = 4_296_178.0

    private func imageCue(id: Int, start: Double, end: Double = openPlaceholderEnd) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleCue(id: id, startTime: start, endTime: end,
                           body: .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)))
    }

    @Test("the emitted active line is trimmed at its successor's start, so the two never overlap")
    func activeLineTrimmedAtSuccessorStart() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Active line composed 8 s before the playhead, held as the candidate.
        #expect(gate.admit(cues: [imageCue(id: 1, start: 92)], isPGS: true, isSelfContained: true, playhead: 100).isEmpty)
        // The pass ends: successor composition 6 s ahead. Both publish, but the candidate must be closed at the
        // successor's start instead of keeping the open placeholder.
        let out = gate.admit(cues: [imageCue(id: 2, start: 106)], isPGS: true, isSelfContained: true, playhead: 100)
        #expect(out.map(\.id).sorted() == [1, 2])
        #expect(out.first { $0.id == 1 }?.endTime == 106)
        // Once the playhead passes the successor's start, exactly one published cue covers it.
        let covering = out.filter { $0.startTime <= 107 && 107 < $0.endTime }
        #expect(covering.map(\.id) == [2])
    }

    @Test("a multi-region successor (several cues sharing one start) trims the active line once at that start")
    func multiRegionSuccessorTrimsAtSharedStart() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        #expect(gate.admit(cues: [imageCue(id: 1, start: 95)], isPGS: true, isSelfContained: true, playhead: 100).isEmpty)
        // One composition, two window regions: both belong on screen together and keep their own windows.
        let out = gate.admit(cues: [imageCue(id: 2, start: 110), imageCue(id: 3, start: 110)],
                             isPGS: true, isSelfContained: true, playhead: 100)
        #expect(out.first { $0.id == 1 }?.endTime == 110)
        #expect(out.filter { $0.startTime == 110 }.count == 2)
    }

    @Test("a pass ending with no ahead cue keeps the live line's open window (store trim owns it)")
    func activeLineOpenEndedWithoutSuccessor() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // The reader catches up exactly at the playhead: the line IS the live line, no successor published.
        let out = gate.admit(cues: [imageCue(id: 1, start: 100)], isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.map(\.id) == [1])
        #expect(out.first?.endTime == Self.openPlaceholderEnd)
    }
}
