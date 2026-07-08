import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// #112 full umbau: an audio-track switch does not move the playhead, so the PGS line already on screen is known
/// state. The old path tore the pipeline down and reconstructed it from a back-scan (the line vanished for the
/// reconstruct duration). Instead the engine snapshots the image cues visible at the playhead before the reload
/// and restores them after, so the line stays put. `activeImageCues(in:at:)` is that snapshot.
struct Issue112PGSAudioSwitchPreserveTests {

    private func tinyImage() -> SubtitleImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleImage(cgImage: ctx.makeImage()!, position: CGRect(x: 0, y: 0.8, width: 1, height: 0.15))
    }

    private func imageCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .image(tinyImage()))
    }

    private func textCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text("hello"))
    }

    @Test("the image cue whose window covers the playhead is snapshotted")
    func coveringImageCueIsReturned() {
        let cues = [imageCue(id: 1, start: 100, end: 200)]
        let active = AetherEngine.activeImageCues(in: cues, at: 150)
        #expect(active.map(\.id) == [1])
    }

    @Test("an image cue that ended before the playhead is not snapshotted")
    func endedCueExcluded() {
        let cues = [imageCue(id: 1, start: 100, end: 140)]
        #expect(AetherEngine.activeImageCues(in: cues, at: 150).isEmpty)
    }

    @Test("an image cue starting after the playhead is not snapshotted")
    func futureCueExcluded() {
        let cues = [imageCue(id: 1, start: 160, end: 200)]
        #expect(AetherEngine.activeImageCues(in: cues, at: 150).isEmpty)
    }

    @Test("a text cue covering the playhead is not snapshotted (image-only)")
    func textCueExcluded() {
        // Only bitmap lines need reconstruction across a reload; text tracks re-decode cheaply from their index.
        let cues = [textCue(id: 1, start: 100, end: 200)]
        #expect(AetherEngine.activeImageCues(in: cues, at: 150).isEmpty)
    }

    @Test("an open-ended tail cue on screen at the playhead is snapshotted")
    func openEndedTailCueIncluded() {
        // A PGS line with no successor yet carries an open-ended placeholder end; if it started at or before the
        // playhead it is the visible line and must survive the reload.
        let cues = [imageCue(id: 1, start: 100, end: 4_296_178)]
        #expect(AetherEngine.activeImageCues(in: cues, at: 150).map(\.id) == [1])
    }
}
