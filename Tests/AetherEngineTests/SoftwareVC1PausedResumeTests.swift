import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Packet admission tests use a synthetic HEVC demuxer; they do not qualify VC-1 decoding.
@Suite(.offCooperativePool, .timeLimit(.minutes(3)))
struct SoftwareVC1PausedResumeTests {
    private func source() throws -> Demuxer {
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        return dem
    }

    @Test("reference admission preserves the key packet for the actual decode/cache reader")
    func preservesKeyPacket() throws {
        let dem = try source()
        defer { dem.close() }
        let stream = try #require(dem.stream(at: dem.videoStreamIndex))
        let tb = stream.pointee.time_base
        let timeBase = Double(tb.num) / Double(tb.den)
        var expected: Int64?
        try dem.peekPackets(maxPackets: 1) { expected = $0.pointee.pts; return true }
        let ticks = try #require(expected)
        let pts = Double(ticks) * timeBase
        let admitted = try SoftwareVC1PausedResume.findKeyframe(
            dem: dem, target: pts, videoIndex: dem.videoStreamIndex, timeBase: timeBase,
            deadline: .infinity, isCurrent: { true })
        #expect(admitted == pts)
        var packet = try dem.readPacket()
        defer { av_packet_free(&packet) }
        #expect(packet?.pointee.pts == ticks)
        #expect((try #require(packet)).pointee.flags & AV_PKT_FLAG_KEY != 0)
    }

    @Test("missing keys, EOF, expired time and byte/packet bounds never fail open",
          arguments: ["missing", "eof", "time", "bytes", "packets", "future"])
    func boundedFailure(reason: String) throws {
        let dem = try source()
        defer { dem.close() }
        if reason == "missing" {
            try dem.peekPackets(maxPackets: 128) { $0.pointee.flags &= ~AV_PKT_FLAG_KEY; return false }
        }
        do {
            _ = try SoftwareVC1PausedResume.findKeyframe(
                dem: dem, target: reason == "future" ? -1 : 0,
                videoIndex: reason == "eof" ? -1 : dem.videoStreamIndex,
                timeBase: 1, deadline: reason == "time" ? -.infinity : .infinity,
                packetLimit: reason == "packets" ? 0 : 128,
                byteLimit: reason == "bytes" ? 1 : 1024 * 1024, isCurrent: { true })
            Issue.record("unusable reference source was accepted: \(reason)")
        } catch SoftwarePlaybackHost.HostError.repositionFailed { }
    }

    @Test("a cancelled preparation cannot reposition or admit a reference")
    func cancelled() throws {
        let dem = Demuxer()
        do {
            _ = try SoftwareVC1PausedResume.prepare(dem: dem, target: 1390, origin: 600,
                                                    videoIndex: 0, timeBase: 1, isCurrent: { false })
            Issue.record("cancelled preparation returned")
        } catch is CancellationError { }
    }

    @Test("offset-origin targets keep the same before-target and bounded-GOP contract")
    func targetBoundary() {
        #expect(SoftwareVC1PausedResume.acceptsKeyframe(pts: 1386, target: 1390))
        #expect(!SoftwareVC1PausedResume.acceptsKeyframe(pts: 1390.001, target: 1390))
        #expect(!SoftwareVC1PausedResume.acceptsKeyframe(pts: 1381, target: 1390))
        #expect(!SoftwareVC1PausedResume.acceptsKeyframe(pts: .nan, target: 1390))
        #expect(!SoftwareVC1PausedResume.acceptsKeyframe(pts: 1390, target: .infinity))
    }
}
