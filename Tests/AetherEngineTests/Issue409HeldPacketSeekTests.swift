import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// #409 follow-up. The repair settles its verdict by reading ahead and HOLDING what it read, so the
/// container's own order survives the decision. `noteSeek()` dropped that queue only while the sample was
/// still open: once the verdict had landed (a healthy file decides `.off` on its first packet, with the
/// sample still held), the queue outlived the seek and `dequeue()` handed the abandoned position's packets
/// out ahead of the landing's. On the producer path that put duplicate pictures into a stream it had
/// already emitted, which `Issue259A53CaptionAxisTests` sees as two repeated A/53 observations.
private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

@Suite("Held packets and seeks (#409)")
struct Issue409HeldPacketSeekTests {

    private static func videoPTS(_ dem: Demuxer, count: Int) throws -> [Int64] {
        var out: [Int64] = []
        while out.count < count, let pkt = try dem.readPacket() {
            if Int(pkt.pointee.stream_index) == dem.videoStreamIndex, pkt.pointee.pts != Int64.min {
                out.append(pkt.pointee.pts)
            }
            var owned: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&owned)
        }
        return out
    }

    @Test("a seek drops the sample the verdict left held",
          .enabled(if: fixtureExists("a53-captions.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the A/53 caption clip"),
          .timeLimit(.minutes(3)))
    func heldSampleDoesNotSurviveASeek() throws {
        let url = fixtureURL("a53-captions.mp4")

        // The reference arm never samples, so what it delivers after the seek is what the container
        // holds there. Comparing against it makes the pin independent of where the seek lands, which on
        // a fixture with one IDR is the head itself.
        let reference = Demuxer()
        try reference.open(url: url, extraHeaders: [:], profile: .playback, isLive: false)
        defer { reference.close() }
        #expect(reference.seek(to: 1.0), "fixture must be seekable")
        let expected = try Self.videoPTS(reference, count: 24)
        #expect(expected.count == 24, "fixture must deliver a landing to compare against")

        let decided = Demuxer()
        try decided.open(url: url, extraHeaders: [:], profile: .playback, isLive: false)
        defer { decided.close() }
        // The engine settles the verdict at the head, before the cue prewarm, and only then does
        // anything seek (`HLSVideoEngine.prepare`). This is that order.
        decided.decideCompositionOffsetRepair()
        #expect(decided.seek(to: 1.0))
        let observed = try Self.videoPTS(decided, count: 24)

        #expect(observed == expected,
                "the landing re-served packets the verdict was still holding: \(observed) vs \(expected)")
    }

    @Test("without a seek the held sample is still delivered in full",
          .enabled(if: fixtureExists("a53-captions.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the A/53 caption clip"),
          .timeLimit(.minutes(3)))
    func heldSampleSurvivesWhenNothingSeeks() throws {
        let url = fixtureURL("a53-captions.mp4")

        let plain = Demuxer()
        try plain.open(url: url, extraHeaders: [:], profile: .playback, isLive: false)
        defer { plain.close() }
        let expected = try Self.videoPTS(plain, count: 12)

        let decided = Demuxer()
        try decided.open(url: url, extraHeaders: [:], profile: .playback, isLive: false)
        defer { decided.close() }
        decided.decideCompositionOffsetRepair()
        let observed = try Self.videoPTS(decided, count: 12)

        #expect(observed == expected,
                "deciding the verdict must not cost a packet: \(observed) vs \(expected)")
    }
}
