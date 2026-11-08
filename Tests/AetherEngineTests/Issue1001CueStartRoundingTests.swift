import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

/// AE#1001: a DVB set whose start rounds DOWN on the reconstruction grid was closed at its own packet.
/// The packet PTS below are the report's fixture as `ffprobe -show_packets` reads it.
@Suite("AE#1001: a rounded cue start does not find its own packet as successor")
struct Issue1001CueStartRoundingTests {

    private let packets: [(pts: Double, size: Int)] = [
        (6.976167, 312), (9.169522, 25), (9.249522, 312), (11.522233, 25),
    ]

    private func store() -> SubtitlePacketStore {
        let store = SubtitlePacketStore()
        for packet in packets {
            store.append(streamIndex: 1, ptsSeconds: packet.pts, durationSeconds: 0,
                         payload: Data(count: packet.size))
        }
        return store
    }

    /// The start a decoded cue carries: its packet's PTS on the reconstruction grid.
    private func decodedStart(_ pts: Double) -> Double {
        let ticks = Double(AetherEngine.storedSubtitlePacketTicksPerSecond)
        return (pts * ticks).rounded() / ticks
    }

    private func imageCue(id: Int, start: Double) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)
        return SubtitleCue(id: id, startTime: start, endTime: start + 4_294_967.295, body: .image(image))
    }

    @Test("both sets end at their authored clear, whichever way their start rounded")
    func setsEndAtTheirClears() {
        let store = store()
        var cues = [imageCue(id: 0, start: decodedStart(6.976167)),
                    imageCue(id: 1, start: decodedStart(9.249522))]
        #expect(cues[0].startTime < 6.976167)   // rounded down: the reported case
        #expect(cues[1].startTime > 9.249522)   // rounded up: the case that already worked
        #expect(AetherEngine.alignCueEnds(&cues, toNextPacket: {
            AetherEngine.authoredSuccessorPTS(in: store, streamIndex: 1, afterCueStart: $0)
        }))
        #expect(cues[0].endTime == 9.169522)
        #expect(cues[1].endTime == 11.522233)
    }

    @Test("a strict lookup from the rounded start is what returned the set's own packet")
    func strictLookupFindsTheOwnPacket() {
        #expect(store().firstPTS(streamIndex: 1, after: decodedStart(6.976167)) == 6.976167)
    }
}
