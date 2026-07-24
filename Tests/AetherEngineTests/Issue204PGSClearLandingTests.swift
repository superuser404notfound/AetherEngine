import CoreGraphics
import Testing
@testable import AetherEngine

struct Issue204PGSClearLandingTests {
    private func imageCue(id: Int, start: Double, end: Double = 4_296_178) -> SubtitleCue {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return SubtitleCue(
            id: id,
            startTime: start,
            endTime: end,
            body: .image(SubtitleImage(cgImage: context.makeImage()!, position: .zero))
        )
    }

    @Test("a landing line followed only by its clear finalizes with the authored end")
    func clearAheadDoesNotBlockFinalization() {
        let playhead = 30.3
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true

        #expect(gate.admit(
            cues: [imageCue(id: 1, start: 30)],
            isPGS: true,
            isSelfContained: false,
            playhead: playhead
        ).isEmpty)
        #expect(gate.resolveHeld(trimAt: 33, playhead: playhead).isEmpty)

        #expect(SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: gate.reconstructing,
            hasCandidate: gate.hasReconstructionCandidate
        ))
        let output = gate.finalizeReconstruction(playhead: playhead)
        #expect(output.map(\.id) == [1])
        #expect(output.first?.endTime == 33)
    }
}
