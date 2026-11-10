#if DolbyVisionFelCurves
import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// AE#1018: the curve fold pauses where its RPU cannot reach the picture.
@Suite("AE#1018 FEL fold gate")
struct Issue1018FelFoldGateTests {

    @Test("only a tvOS panel proven in HDR, without Dolby Vision and off the Profile 5 route, hides the fold",
          arguments: [
              (true, false, false, true, true),
              (false, false, false, true, false),   // a Mac applies the RPU
              (true, true, false, true, false),     // the display takes Dolby Vision
              (true, false, true, true, false),     // AE#455: AVPlayer composes the RPU
              (true, false, false, false, false),   // SDR or unproven panel: the RPU is applied
          ])
    func verdict(_ row: (Bool, Bool, Bool, Bool, Bool)) {
        #expect(HLSVideoEngine.felFoldIsUnseen(isTVOS: row.0, effectiveDvMode: row.1, servesAsProfile5: row.2,
                                               panelPresentsHDR: row.3) == row.4)
    }

    /// Reads until the lookahead hands out its first video packet; returns how many source reads that took.
    private static func readsToFirstVideo(unseen: Bool) throws -> (reads: Int, folding: Bool?) {
        let demuxer = Demuxer()
        try demuxer.open(url: HeavyDualLayerSuites.DoviFelRealFileTests.url("fel-clip-a.mkv"))
        defer { demuxer.close() }
        let index = Int32(demuxer.videoStreamIndex)
        let stream = try #require(demuxer.stream(at: index))
        let lookahead = FelCurveLookahead(videoStreamIndex: index, stream: stream, framing: .lengthPrefixed(size: 4),
                                          foldIsUnseen: { unseen })
        var reads = 0
        while let packet = try lookahead.next(read: { reads += 1; return try demuxer.readPacket() }) {
            let isVideo = packet.pointee.stream_index == index
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
            if isVideo { break }
        }
        let folding = lookahead.isFolding
        lookahead.reset()
        return (reads, folding)
    }

    private static func rawReadsToFirstVideo() throws -> Int {
        let demuxer = Demuxer()
        try demuxer.open(url: HeavyDualLayerSuites.DoviFelRealFileTests.url("fel-clip-a.mkv"))
        defer { demuxer.close() }
        let index = Int32(demuxer.videoStreamIndex)
        var reads = 0
        while let packet = try demuxer.readPacket() {
            reads += 1
            let isVideo = packet.pointee.stream_index == index
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
            if isVideo { break }
        }
        return reads
    }

    @Test("while the fold is unseen the lookahead holds nothing back",
          .enabled(if: HeavyDualLayerSuites.DoviFelRealFileTests.available("fel-clip-a.mkv"),
                   HeavyDualLayerSuites.DoviFelRealFileTests.needsClips))
    func bypassHoldsNothing() throws {
        let folding = try Self.readsToFirstVideo(unseen: false)
        let bypassed = try Self.readsToFirstVideo(unseen: true)
        #expect(folding.folding == true)
        #expect(bypassed.folding == true)
        // Folding releases the first GOP only once the next keyframe has been read.
        #expect(folding.reads > 10)
        #expect(bypassed.reads == (try Self.rawReadsToFirstVideo()))
    }
}
#endif
