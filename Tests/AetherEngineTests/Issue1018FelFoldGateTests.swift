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

    @Test("an HDR write with range matching on counts as HDR from the start, unless the display refused one",
          arguments: [
              (false, true, true, false, true),
              (false, true, true, true, false),     // the display refused an HDR master in this process
              (false, false, true, false, false),   // matching off: the panel stays where it is
              (false, true, false, false, false),   // no HDR criteria written (SDR, or a host that owns them)
              (true, false, false, true, true),     // a proven panel wins over everything
          ])
    func startingAnswer(_ row: (Bool, Bool, Bool, Bool, Bool)) {
        #expect(AetherEngine.felGatePanelPresentsHDR(labelPresentsHDR: row.0, hdrWriteEngagesPanel: row.1,
                                                     engineWritesHDRCriteria: row.2,
                                                     panelRefusedHDRMaster: row.3) == row.4)
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

    private struct Stamp: Equatable { let stream: Int32; let pts: Int64; let dts: Int64 }

    private static func rawOrder(limit: Int) throws -> [Stamp] {
        let demuxer = Demuxer()
        try demuxer.open(url: HeavyDualLayerSuites.DoviFelRealFileTests.url("fel-clip-a.mkv"))
        defer { demuxer.close() }
        var out: [Stamp] = []
        while out.count < limit, let packet = try demuxer.readPacket() {
            out.append(Stamp(stream: packet.pointee.stream_index, pts: packet.pointee.pts, dts: packet.pointee.dts))
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        return out
    }

    @Test("the fold leaves and rejoins at keyframes during playback, in read order",
          .enabled(if: HeavyDualLayerSuites.DoviFelRealFileTests.available("fel-clip-a.mkv"),
                   HeavyDualLayerSuites.DoviFelRealFileTests.needsClips))
    func togglesBothWaysInOrder() throws {
        let limit = 900
        let demuxer = Demuxer()
        try demuxer.open(url: HeavyDualLayerSuites.DoviFelRealFileTests.url("fel-clip-a.mkv"))
        defer { demuxer.close() }
        let index = Int32(demuxer.videoStreamIndex)
        let stream = try #require(demuxer.stream(at: index))
        var videoRead = 0
        // Folding at first, unseen from video packet 150 to 450, folding again after.
        let lookahead = FelCurveLookahead(videoStreamIndex: index, stream: stream, framing: .lengthPrefixed(size: 4),
                                          foldIsUnseen: { videoRead >= 150 && videoRead < 450 })
        var out: [Stamp] = []
        var states: [Bool] = []
        while out.count < limit, let packet = try lookahead.next(read: {
            let p = try demuxer.readPacket()
            if let p, p.pointee.stream_index == index { videoRead += 1 }
            return p
        }) {
            out.append(Stamp(stream: packet.pointee.stream_index, pts: packet.pointee.pts, dts: packet.pointee.dts))
            states.append(lookahead.bypassing)
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        lookahead.reset()
        #expect(out == (try Self.rawOrder(limit: out.count)))
        let transitions = zip(states, states.dropFirst()).filter { $0 != $1 }.count
        #expect(states.first == false)
        #expect(states.contains(true))
        #expect(transitions == 2)
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
