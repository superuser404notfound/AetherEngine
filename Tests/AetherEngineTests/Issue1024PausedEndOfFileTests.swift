import CoreMedia
import Foundation
import Testing
import AetherLibavformat
import AetherLibavcodec
@testable import AetherEngine

/// AE#1024: a software host whose loops run only for the first frame of a paused session can read to
/// the end of the file before that frame is in (a paused rebuild in the last half second, whose decoder
/// still holds the frames at the playhead). That end belongs to a running clock, so it waits for
/// `play()` instead of finishing the session.
@Suite("AE#1024 end of file under a pause waits for play", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct Issue1024PausedEndOfFileTests {

    @Test("a paused host that reads to the end of the file before its first frame stays unfinished until play()")
    func endOfFileUnderPauseWaitsForPlay() async throws {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { host.stop() }
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        try await host.load(demuxer: dem, startPosition: nil, audioSourceStreamIndex: nil)
        // Holds every frame, so the loops reach the end of the file with the first frame still owed.
        host.setVideoDecoderForTesting(FramelessDecoder())

        host.pause()

        try await waitFor { host.endOfMediaOwedOnPlayForTesting || host.didReachEnd }
        #expect(!host.didReachEnd)
        #expect(!host.isPlaying)

        host.play()

        try await waitFor { host.didReachEnd }
        #expect(!host.endOfMediaOwedOnPlayForTesting)
    }

    /// The picture half: the end-of-file branch drains the decoder before it flushes it, and the software
    /// decoder's `flush()` discards. Without a drain of its own the frames its threads still held never
    /// reached the renderer, which on a paused rebuild in the last half second was every frame there was.
    @Test("the software decoder hands over every frame it still holds at the end of the stream")
    func softwareDecoderDrainsAtEndOfStream() throws {
        let data = try #require(Data(base64Encoded: Issue220SoftwareDecoderDrainTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let frames = FrameCount()
        let decoder = SoftwareVideoDecoder()
        try decoder.open(stream: stream) { _, _, _ in frames.add() }
        defer { decoder.close() }

        var packets = 0
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == videoIndex {
                packets += 1
                decoder.decode(packet: pkt)
            }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        decoder.drainForEndOfStream()
        decoder.flush()

        #expect(packets == 40)
        #expect(frames.value == packets)
    }

    @Test("only a host the viewer paused holds its end for play()")
    func onlyAHostPauseHoldsTheEnd() {
        #expect(PausedFirstFrame.endOfMediaWaitsForPlay(transportPlaying: false, pausedByHost: true))
        #expect(!PausedFirstFrame.endOfMediaWaitsForPlay(transportPlaying: true, pausedByHost: false))
        #expect(!PausedFirstFrame.endOfMediaWaitsForPlay(transportPlaying: false, pausedByHost: false))
    }
}

private final class FramelessDecoder: VideoDecodingPipeline, @unchecked Sendable {
    var onFrame: DecodedFrameHandler?
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
    var skipUntilPTS: CMTime?
    var feedEpoch: UInt64 { 0 }
    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {}
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {}
    func flush() {}
    func close() {}
}

private final class FrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
