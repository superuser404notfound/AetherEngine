import Testing
import Foundation
@testable import AetherEngine

/// EXT-X-BYTERANGE (RFC 8216 4.3.2.2): a packager that writes one file per stream lists every segment
/// as a sub-range of that file. The ingest fetched each URI whole, so every segment delivered the
/// entire file and a live channel never advanced past its first seconds.
@Suite("HLS byte-range segments are read as their sub-range", .offCooperativePool, .timeLimit(.minutes(2)))
struct HLSByteRangeSegmentTests {

    private func mediaPlaylist(_ lines: [String]) throws -> HLSMediaPlaylist {
        let text = (["#EXTM3U", "#EXT-X-VERSION:4", "#EXT-X-TARGETDURATION:2"] + lines).joined(separator: "\n")
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            throw HLSIngestError.playlistInvalid(reason: "not a media playlist")
        }
        return media
    }

    // MARK: - Parser

    @Test("an explicit offset is taken as written and an omitted one continues the previous sub-range")
    func explicitAndImplicitOffsets() throws {
        let media = try mediaPlaylist([
            "#EXTINF:2,", "#EXT-X-BYTERANGE:1000@0", "stream.ts",
            "#EXTINF:2,", "#EXT-X-BYTERANGE:1500", "stream.ts",
            "#EXTINF:2,", "#EXT-X-BYTERANGE:700@4000", "stream.ts",
            "#EXTINF:2,", "#EXT-X-BYTERANGE:300", "stream.ts",
            "#EXTINF:2,", "whole.ts",
        ])
        #expect(media.segments.map(\.byteRange) == [
            HLSByteRange(offset: 0, length: 1000),
            HLSByteRange(offset: 1000, length: 1500),
            HLSByteRange(offset: 4000, length: 700),
            HLSByteRange(offset: 4700, length: 300),
            nil,
        ])
    }

    @Test("a map's BYTERANGE attribute neither ranges the first segment nor starts its offset chain")
    func mapByteRangeStaysOnTheMap() throws {
        let media = try mediaPlaylist([
            "#EXT-X-MAP:URI=\"stream.mp4\",BYTERANGE=\"720@0\"",
            "#EXTINF:2,", "#EXT-X-BYTERANGE:5000@720", "stream.mp4",
            "#EXTINF:2,", "#EXT-X-BYTERANGE:4000", "stream.mp4",
        ])
        #expect(media.hasMap)
        #expect(media.segments.map(\.byteRange) == [
            HLSByteRange(offset: 720, length: 5000),
            HLSByteRange(offset: 5720, length: 4000),
        ])
        // The implicit form needs a previous segment; the map is not one.
        #expect(throws: HLSIngestError.self) {
            try mediaPlaylist([
                "#EXT-X-MAP:URI=\"stream.mp4\",BYTERANGE=\"720@0\"",
                "#EXTINF:2,", "#EXT-X-BYTERANGE:5000", "stream.mp4",
            ])
        }
    }

    @Test("an omitted offset with no previous sub-range of the same URI fails the playlist")
    func implicitOffsetNeedsAPreviousSubRange() {
        // RFC 8216: the client MUST fail to parse such a playlist. Guessing 0 would play the wrong bytes.
        let error = #expect(throws: HLSIngestError.self) {
            try mediaPlaylist(["#EXTINF:2,", "#EXT-X-BYTERANGE:1000", "stream.ts"])
        }
        #expect(error?.diagnosticReason == .invalidByteRange)
        #expect(throws: HLSIngestError.self) {
            try mediaPlaylist([
                "#EXTINF:2,", "#EXT-X-BYTERANGE:1000@0", "a.ts",
                "#EXTINF:2,", "#EXT-X-BYTERANGE:1000", "b.ts",
            ])
        }
        #expect(throws: HLSIngestError.self) {
            try mediaPlaylist([
                "#EXTINF:2,", "#EXT-X-BYTERANGE:1000@0", "stream.ts",
                "#EXTINF:2,", "whole.ts",
                "#EXTINF:2,", "#EXT-X-BYTERANGE:1000", "stream.ts",
            ])
        }
    }

    @Test("a malformed or empty BYTERANGE fails the playlist", arguments: [
        "#EXT-X-BYTERANGE:", "#EXT-X-BYTERANGE:0@0", "#EXT-X-BYTERANGE:-5@0", "#EXT-X-BYTERANGE:10@-1",
        "#EXT-X-BYTERANGE:10@", "#EXT-X-BYTERANGE:10@2@3", "#EXT-X-BYTERANGE:ten",
        "#EXT-X-BYTERANGE:10@\(Int.max)",
    ])
    func malformedByteRangeFails(tag: String) {
        let error = #expect(throws: HLSIngestError.self) {
            try mediaPlaylist(["#EXTINF:2,", tag, "stream.ts"])
        }
        #expect(error?.diagnosticReason == .invalidByteRange)
    }

    @Test("a rejoin keeps the sub-range of the segment it marks as a seam")
    func rejoinKeepsTheSubRange() throws {
        var tracker = HLSPlaylistTracker()
        func window(from sequence: Int) throws -> HLSMediaPlaylist {
            var lines = ["#EXT-X-MEDIA-SEQUENCE:\(sequence)"]
            for index in sequence..<(sequence + 3) {
                lines += ["#EXTINF:2,", "#EXT-X-BYTERANGE:100@\(index * 100)", "stream.ts"]
            }
            return try mediaPlaylist(lines)
        }
        _ = tracker.newSegments(in: try window(from: 0))
        let rejoined = tracker.newSegments(in: try window(from: 10))
        #expect(rejoined.first?.discontinuityBefore == true)
        #expect(rejoined.map(\.byteRange) == (10..<13).map { HLSByteRange(offset: $0 * 100, length: 100) })
    }

    // MARK: - Answers

    @Test("a 206 is the sub-range, and one that starts elsewhere or ends short fails")
    func partialContentAnswer() throws {
        let range = HLSByteRange(offset: 100, length: 4)
        #expect(range.requestHeaderValue == "bytes=100-103")
        let body = Data([1, 2, 3, 4])
        #expect(try range.segmentBytes(from: body, status: 206, contentRange: "bytes 100-103/400") == body)
        #expect(try range.segmentBytes(from: body + Data([9, 9]), status: 206, contentRange: nil) == body)
        let elsewhere = #expect(throws: HLSIngestError.self) {
            try range.segmentBytes(from: body, status: 206, contentRange: "bytes 0-3/400")
        }
        #expect(elsewhere?.diagnosticReason == .invalidByteRange)
        let short = #expect(throws: HLSIngestError.self) {
            try range.segmentBytes(from: body.prefix(3), status: 206, contentRange: "bytes 100-102/400")
        }
        #expect(short?.diagnosticReason == .invalidByteRange)
    }

    @Test("a 200 carrying the whole resource is cut to the sub-range, and one too short for it fails")
    func wholeResourceAnswer() throws {
        let resource = Data((0..<200).map { UInt8($0) })
        let range = HLSByteRange(offset: 100, length: 4)
        #expect(try range.segmentBytes(from: resource, status: 200, contentRange: nil) == Data([100, 101, 102, 103]))
        let error = #expect(throws: HLSIngestError.self) {
            try range.segmentBytes(from: resource.prefix(102), status: 200, contentRange: nil)
        }
        #expect(error?.diagnosticReason == .invalidByteRange)
    }

    // MARK: - Live ingest

    /// Four MPEG-TS packets whose payload bytes carry `index`, so a segment from the wrong offset shows.
    private static func transportSegment(_ index: Int) -> Data {
        var data = Data(capacity: 4 * 188)
        for packet in 0..<4 {
            var ts = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 188)
            ts[0] = 0x47
            ts[1] = UInt8(truncatingIfNeeded: packet)
            data.append(contentsOf: ts)
        }
        return data
    }

    private func drain(_ reader: any IOReader, expectedBytes: Int) async throws -> Data {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var done = false
        }
        let box = Box()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = buf.withUnsafeMutableBufferPointer {
                    reader.read($0.baseAddress, size: Int32($0.count))
                }
                if n <= 0 { break }
                box.lock.lock()
                box.data.append(contentsOf: buf[0..<Int(n)])
                let enough = box.data.count >= expectedBytes
                box.lock.unlock()
                if enough { break }
            }
            box.lock.withLock { box.done = true }
        }
        try await waitFor { box.lock.withLock { box.done } }
        return box.lock.withLock { box.data }
    }

    @Test("the live ingest asks for each sub-range, and cuts it from an origin that ignores Range",
          arguments: [false, true])
    func liveIngestReadsSubRanges(originIgnoresRange: Bool) async throws {
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        let file = (0..<3).map(Self.transportSegment).reduce(Data(), +)
        let length = file.count / 3
        origin.serve("/live/stream.ts", file, contentType: "video/mp2t")
        origin.serve("/live/media.m3u8", Data([
            "#EXTM3U", "#EXT-X-VERSION:4", "#EXT-X-TARGETDURATION:1", "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXTINF:1.0,", "#EXT-X-BYTERANGE:\(length)@0", "stream.ts",
            "#EXTINF:1.0,", "#EXT-X-BYTERANGE:\(length)", "stream.ts",
            "#EXTINF:1.0,", "#EXT-X-BYTERANGE:\(length)@\(2 * length)", "stream.ts",
            "#EXT-X-ENDLIST",
        ].joined(separator: "\n").utf8), contentType: "application/vnd.apple.mpegurl")
        origin.ignoresRange = originIgnoresRange

        let playlistURL = try #require(URL(string: origin.baseURL + "/live/media.m3u8"))
        let reader = HLSLiveIngestReader(playlistURL: playlistURL)
        defer { reader.close() }
        let got = try await drain(reader, expectedBytes: file.count)

        #expect(reader.terminalError == nil)
        #expect(got == file)
        #expect(Set(origin.requests(to: "/live/stream.ts").map(\.range)) == [
            "bytes=0-\(length - 1)", "bytes=\(length)-\(2 * length - 1)", "bytes=\(2 * length)-\(3 * length - 1)",
        ])
    }

    // MARK: - VOD ingest

    @Test("a persistent HTTP/1 whole-resource request carries the caller's Range, an offset read its own")
    func persistentRequestRange() throws {
        let url = try #require(URL(string: "http://media.example/stream.ts"))
        let ranged = String(decoding: try HeldSourceConnection.requestBytes(
            target: url, host: "media.example", port: 80, secure: false,
            offset: nil, extraHeaders: ["Range": "bytes=100-199"], userAgent: nil), as: UTF8.self)
        #expect(ranged.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("range:") }
            == ["Range: bytes=100-199"])
        let offsetRead = String(decoding: try HeldSourceConnection.requestBytes(
            target: url, host: "media.example", port: 80, secure: false,
            offset: 5, extraHeaders: ["Range": "bytes=100-199"], userAgent: nil), as: UTF8.self)
        #expect(offsetRead.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("range:") }
            == ["Range: bytes=5-"])
    }

    /// A PMT for one HEVC (0x24) elementary stream, the carriage the VOD ingest admits (the shape
    /// `Issue268HLSVODIngestTests` probes with). `marker` sits in the filler of the third packet, so each
    /// segment's bytes are its own.
    private static func hevcTransportSegment(marker: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188 * 3)
        for packet in 0..<3 {
            bytes[packet * 188] = 0x47
            bytes[packet * 188 + 3] = 0x10
        }
        bytes.replaceSubrange(1...21, with: [0x40, 0x64, 0x10, 0x00, 0x02, 0xB0, 18, 0x00, 0x01, 0xC1, 0x00, 0x00,
                                             0xE1, 0x00, 0xF0, 0x00, 0x24, 0xE1, 0x01, 0xF0, 0x00])
        bytes[2 * 188 + 100] = marker
        return Data(bytes)
    }

    @Test("the VOD ingest asks for each sub-range, and cuts it from an origin that ignores Range",
          arguments: [false, true], [false, true])
    func vodIngestReadsSubRanges(originIgnoresRange: Bool, persistentHTTP1: Bool) async throws {
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        let file = (1...3).map { Self.hevcTransportSegment(marker: UInt8($0)) }.reduce(Data(), +)
        let length = file.count / 3
        origin.serve("/vod/stream.ts", file, contentType: "video/mp2t")
        origin.serve("/vod/media.m3u8", Data([
            "#EXTM3U", "#EXT-X-VERSION:4", "#EXT-X-TARGETDURATION:6", "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXTINF:6,", "#EXT-X-BYTERANGE:\(length)@0", "stream.ts",
            "#EXTINF:6,", "#EXT-X-BYTERANGE:\(length)", "stream.ts",
            "#EXTINF:6,", "#EXT-X-BYTERANGE:\(length)", "stream.ts",
            "#EXT-X-ENDLIST",
        ].joined(separator: "\n").utf8), contentType: "application/vnd.apple.mpegurl")
        origin.ignoresRange = originIgnoresRange

        let playlistURL = try #require(URL(string: origin.baseURL + "/vod/media.m3u8"))
        let admitted = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: playlistURL, httpHeaders: [:], persistentHTTP1: persistentHTTP1)
        let reader = try #require(admitted)
        defer { reader.close() }
        #expect(reader.mediaDuration == 18)
        let got = try await drain(reader, expectedBytes: file.count + 1)

        #expect(got == file)
        // The carriage probe reads on a request of its own, ranged as well: unranged, the persistent path
        // opens the whole file, which for a real single-file VOD overruns the segment limit.
        let requests = origin.requests(to: "/vod/stream.ts")
        #expect(requests.allSatisfy { $0.range != nil })
        let ranged = Set(requests.compactMap(\.range))
        #expect(ranged.isSuperset(of: [
            "bytes=0-\(length - 1)", "bytes=\(length)-\(2 * length - 1)", "bytes=\(2 * length)-\(3 * length - 1)",
        ]))
    }
}
