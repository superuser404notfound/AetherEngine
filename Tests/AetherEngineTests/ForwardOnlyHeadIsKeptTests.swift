import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// Audit HLS-103 (70dc485d was incomplete): a forward-only source cannot rewind, so whatever the
/// start-up probes read off its head is gone from the archive. `probeVideoNALFraming` (Annex-B
/// extradata) and the in-band hvcC rebuild both did `seek(to: 0)` and then consumed packets; FFmpeg
/// flushes the packet queue before it even tries the seek, and 70dc485d's step-6 rewind is skipped
/// on these sources, so the opening GOP never reached the producer.
@Suite("A forward-only source keeps its opening packets", .serialized)
struct ForwardOnlyHeadIsKeptTests {

    /// The tiny H.264 TS as a source that cannot be repositioned: every seek is refused, which is how
    /// the demuxer learns the source is forward-only.
    private final class ForwardOnlyReader: IOReader, @unchecked Sendable {
        private let bytes = TinyTransportStreamFixture.data
        private let lock = NSLock()
        private var position = 0

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                let n = min(Int(size), bytes.count - position)
                guard n > 0 else { return 0 }
                bytes.withUnsafeBytes { raw in _ = memcpy(buffer, raw.baseAddress! + position, n) }
                position += n
                return Int32(n)
            }
        }

        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    struct Signature: Equatable {
        let streamIndex: Int32
        let pts: Int64
        let dts: Int64
        let size: Int32
    }

    private static func signature(_ packet: UnsafeMutablePointer<AVPacket>) -> Signature {
        Signature(streamIndex: packet.pointee.stream_index, pts: packet.pointee.pts,
                  dts: packet.pointee.dts, size: packet.pointee.size)
    }

    private func openForwardOnly() throws -> Demuxer {
        let demuxer = Demuxer()
        try demuxer.open(reader: ForwardOnlyReader(), formatHint: "mpegts")
        return demuxer
    }

    /// The packets a plain read delivers, in order: what the producer would see with no probe at all.
    private func firstPackets(_ count: Int) throws -> [Signature] {
        let demuxer = try openForwardOnly()
        defer { demuxer.close() }
        var out: [Signature] = []
        while out.count < count, let read = try demuxer.readPacket() {
            out.append(Self.signature(read))
            var packet: UnsafeMutablePointer<AVPacket>? = read
            trackedPacketFree(&packet)
        }
        return out
    }

    private func readSome(_ demuxer: Demuxer, _ count: Int) throws -> [Signature] {
        var out: [Signature] = []
        while out.count < count, let read = try demuxer.readPacket() {
            out.append(Self.signature(read))
            var packet: UnsafeMutablePointer<AVPacket>? = read
            trackedPacketFree(&packet)
        }
        return out
    }

    @Test("packets peeked on a forward-only source are read again, in order, from the first")
    func peekedPacketsAreReadAgain() throws {
        let expected = try firstPackets(12)

        let demuxer = try openForwardOnly()
        defer { demuxer.close() }
        #expect(!demuxer.isSourceSeekable)
        var peeked: [Signature] = []
        try demuxer.peekPackets(maxPackets: 6) { packet in
            peeked.append(Self.signature(packet))
            return false
        }
        #expect(peeked == Array(expected.prefix(6)))

        // A second look starts from the head again and extends the held run.
        var second: [Signature] = []
        try demuxer.peekPackets(maxPackets: 9) { packet in
            second.append(Self.signature(packet))
            return false
        }
        #expect(second == Array(expected.prefix(9)))

        #expect(try readSome(demuxer, 12) == expected,
                "a peek changed what the producer reads")
    }

    @Test("a peek that has seen enough stops and holds only what it read")
    func peekStopsWhenSatisfied() throws {
        let expected = try firstPackets(4)
        let demuxer = try openForwardOnly()
        defer { demuxer.close() }
        var inspected = 0
        try demuxer.peekPackets(maxPackets: 100) { _ in
            inspected += 1
            return inspected == 3
        }
        #expect(inspected == 3)
        #expect(try readSome(demuxer, 4) == expected)
    }

    @Test("a refused seek on a forward-only source leaves its packets alone")
    func refusedSeeksKeepTheHead() throws {
        let expected = try firstPackets(12)
        let demuxer = try openForwardOnly()
        defer { demuxer.close() }
        try demuxer.peekPackets(maxPackets: 4) { _ in false }

        #expect(!demuxer.seek(to: 0), "a forward-only source was asked to rewind")
        #expect(!demuxer.seek(to: 0, streamIndex: demuxer.videoStreamIndex))
        #expect(!demuxer.seekBounded(to: 0, timeout: 1))
        #expect(!demuxer.seekByteEstimate(to: 1, knownDuration: 8, timeout: 1))

        #expect(try readSome(demuxer, 12) == expected, "a refused seek flushed the packets behind it")
    }

    @Test("a refused seek on a forward-only source keeps the packets the open read ahead")
    func refusedSeekKeepsTheOpenQueue() throws {
        let expected = try firstPackets(12)
        let demuxer = try openForwardOnly()
        defer { demuxer.close() }

        #expect(!demuxer.seek(to: 0), "a forward-only source was asked to rewind")
        #expect(try readSome(demuxer, 12) == expected,
                "the refused seek flushed what find_stream_info had buffered")
    }

    @Test("a seek on a source that can rewind drops what was peeked")
    func seekableSourcesDropThePeek() throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: TinyTransportStreamFixture.LiveReader(), formatHint: "mpegts")
        defer { demuxer.close() }
        #expect(demuxer.isSourceSeekable)
        var seen: [Signature] = []
        try demuxer.peekPackets(maxPackets: 8) { seen.append(Self.signature($0)); return false }
        #expect(seen.count == 8)

        // Three of the held packets go out, five stay held; a rewind must not hand those five out.
        _ = try readSome(demuxer, 3)
        #expect(demuxer.seek(to: 0))
        let after = try #require(try readSome(demuxer, 1).first)
        #expect(after == seen[0], "a held packet came back after the rewind instead of the head")
    }

    @Test("the NAL framing probe leaves the packets it looked at for the producer")
    func framingProbeDoesNotConsume() throws {
        let expected = try firstPackets(12)
        #expect(expected.count == 12)

        let demuxer = try openForwardOnly()
        defer { demuxer.close() }
        #expect(!demuxer.isSourceSeekable, "the fixture reader must read as forward-only")
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/forward-only.ts"),
                                    dvModeAvailable: false)
        let framing = engine.probeVideoNALFraming(demuxer: demuxer, videoStreamIndex: demuxer.videoStreamIndex)
        #expect(framing == .annexB)

        #expect(try readSome(demuxer, 12) == expected,
                "the probe consumed packets the producer will never see")
    }

    /// Video samples (track 1) across every fragment of a segment, from the `trun` sample counts.
    private static func videoSampleCount(_ segment: Data) -> Int {
        func u32(_ off: Int) -> UInt32 {
            segment.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)) }
        }
        func boxes(_ range: Range<Int>) -> [(String, Range<Int>)] {
            var out: [(String, Range<Int>)] = []
            var off = range.lowerBound
            while off + 8 <= range.upperBound {
                let size = Int(u32(off))
                guard size >= 8, off + size <= range.upperBound else { break }
                out.append((String(decoding: segment[off + 4..<off + 8], as: UTF8.self), (off + 8)..<(off + size)))
                off += size
            }
            return out
        }
        var count = 0
        for (type, moof) in boxes(0..<segment.count) where type == "moof" {
            for (t2, traf) in boxes(moof) where t2 == "traf" {
                var track: UInt32 = 0
                var samples = 0
                for (t3, body) in boxes(traf) {
                    if t3 == "tfhd" { track = u32(body.lowerBound + 4) }
                    if t3 == "trun" { samples += Int(u32(body.lowerBound + 4)) }
                }
                if track == 1 { count += samples }
            }
        }
        return count
    }

    /// The whole path: a range-less origin serves the TS as one plain 200, the session plans on a
    /// uniform stride, and the finished playlist has to list every frame the source carries. The
    /// 8 s clip is well inside the reader's 1 MB back window, which is exactly the shape where the
    /// probe's rewind appeared to work and ate the opening.
    @Test("the finished playlist of a forward-only Annex-B TS lists every video frame",
          .timeLimit(.minutes(3)))
    func playlistKeepsTheOpeningFrames() async throws {
        let body = TinyTransportStreamFixture.data
        let origin = ScriptedOriginServer { _ in
            .init(status: 200, declaredLength: nil, close: true, body: body)
        }
        let server = try #require(origin)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/forward-only.ts")!
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false,
                                    sequentialOrigin: true, declaredDurationSeconds: 8)
        _ = try engine.start()
        defer { engine.stop() }
        let mediaURL = try #require(engine.mediaPlaylistURL)

        var playlist = ""
        try await waitFor {
            playlist = (try? String(contentsOf: mediaURL, encoding: .utf8)) ?? ""
            return playlist.contains("#EXT-X-ENDLIST")
        }

        let uris = playlist.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.hasSuffix(".mp4") && !$0.hasPrefix("#") }
        #expect(!uris.isEmpty, "no segment was listed:\n\(playlist)")
        var frames = 0
        for uri in uris {
            let data = try Data(contentsOf: mediaURL.deletingLastPathComponent().appendingPathComponent(uri))
            frames += Self.videoSampleCount(data)
        }
        #expect(frames == 16, "the listed segments carry \(frames) of 16 video frames:\n\(playlist)")
    }
}
