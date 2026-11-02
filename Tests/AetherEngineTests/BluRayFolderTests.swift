import Foundation
import Testing
@testable import AetherEngine

/// A Blu-ray served as a folder (`DiscDirectoryReader`) rather than an image: recognition, clip assembly,
/// the concatenating reader, and the same over HTTP and through the public probe.
@Suite("Blu-ray folder sources", .offCooperativePool)
struct BluRayFolderTests {

    // MARK: - Fixtures

    /// A folder held in memory. Records every file it opens, so a test can tell what recognition read.
    final class MemoryFolder: DiscDirectoryReader, @unchecked Sendable {
        let files: [String: Data]
        let order: [String]
        let preferredPlaylist: String?
        private let lock = NSLock()
        private var opened: [String] = []

        init(_ files: [(String, Data)], preferredPlaylist: String? = nil) {
            self.files = Dictionary(files, uniquingKeysWith: { first, _ in first })
            self.order = files.map(\.0)
            self.preferredPlaylist = preferredPlaylist
        }

        var openedPaths: [String] { lock.withLock { opened } }
        var discFiles: [(path: String, size: Int64)] { order.map { ($0, Int64(files[$0]!.count)) } }

        func openDiscFile(_ path: String) -> IOReader? {
            guard let key = order.first(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) else { return nil }
            lock.withLock { opened.append(key) }
            return DataIOReader(data: files[key]!)
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { -1 }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    /// An `.mpls` whose play items reference `clips` with the given in / out times (45 kHz ticks).
    static func mpls(_ clips: [(id: String, inT: Int, outT: Int)]) -> Data {
        var items: [UInt8] = []
        for clip in clips {
            var body: [UInt8] = []
            body += Array(clip.id.utf8); body += Array("M2TS".utf8); body += be16(0); body.append(0)
            body += be32(clip.inT); body += be32(clip.outT); body += [UInt8](repeating: 0, count: 8)
            items += be16(body.count); items += body
        }
        var playlist: [UInt8] = []
        playlist += be32(0); playlist += be16(0); playlist += be16(clips.count); playlist += be16(0)
        playlist += items
        var out: [UInt8] = []
        out += Array("MPLS".utf8); out += Array("0200".utf8); out += be32(40); out += be32(0)
        out += [UInt8](repeating: 0, count: 40 - out.count)
        out += playlist
        return Data(out)
    }

    /// Bytes that say which clip they came from, so a concatenation can be checked byte for byte.
    static func clipBytes(_ seed: UInt8, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &* 31 &+ $0) })
    }

    /// The tiny 8 s transport stream split into two clips at a packet boundary, with a main playlist whose
    /// two items continue each other (the stream's PTS start at 1.4 s, 63000 ticks), and a 1 s menu
    /// playlist. Both are under the selector's 10 s floor, so both stay titles, longest first.
    static func tinyStreamFolder(preferredPlaylist: String? = nil) -> (folder: MemoryFolder, stream: Data) {
        let stream = TinyTransportStreamFixture.data
        let split = (stream.count / 188 / 2) * 188
        let main = mpls([(id: "00001", inT: 63000, outT: 243000), (id: "00002", inT: 243000, outT: 423000)])
        let menu = mpls([(id: "00009", inT: 0, outT: 45000)])
        let folder = MemoryFolder([
            ("BDMV/index.bdmv", Data([0x49, 0x4E, 0x44, 0x58])),
            ("BDMV/PLAYLIST/00000.mpls", menu),
            ("BDMV/PLAYLIST/00800.mpls", main),
            ("BDMV/STREAM/00001.m2ts", Data(stream.prefix(split))),
            ("BDMV/STREAM/00002.m2ts", Data(stream.suffix(from: split))),
            ("BDMV/STREAM/00009.m2ts", Data(repeating: 0x47, count: 188)),
        ], preferredPlaylist: preferredPlaylist)
        return (folder, stream)
    }

    static func readToEnd(_ reader: IOReader, chunk: Int32 = 1000) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: Int(chunk))
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: chunk) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<Int(n)])
        }
        return out
    }

    // MARK: - Recognition

    @Test("the main title's clips play back to back as one transport stream")
    func mainTitleConcatenatesItsClips() throws {
        let (folder, stream) = Self.tinyStreamFolder()
        let info = try #require(try DiscReader.wrap(folder))
        #expect(info.formatHint == "mpegts")
        #expect(info.titles.count == 2)
        #expect(info.selectedTitleIndex == 0)
        #expect(info.selectedTitle?.bdClipIDs == ["00001", "00002"])
        #expect(info.clipTimeline.isEmpty)  // the clips continue each other: nothing to fold
        #expect(Self.readToEnd(info.reader) == stream)
        #expect(info.reader.seek(offset: 0, whence: 65536) == Int64(stream.count))
    }

    @Test("clips that restart their clock are folded onto one timeline, as on an image (AE#105)")
    func discontinuousClipsGetATimeline() throws {
        let main = Self.mpls([(id: "00001", inT: 0, outT: 900_000), (id: "00002", inT: 0, outT: 900_000)])
        let folder = MemoryFolder([
            ("BDMV/PLAYLIST/00001.mpls", main),
            ("BDMV/STREAM/00001.m2ts", Self.clipBytes(1, count: 4096)),
            ("BDMV/STREAM/00002.m2ts", Self.clipBytes(2, count: 2048)),
        ])
        let info = try #require(try DiscReader.wrap(folder))
        #expect(info.clipTimeline.map(\.concatByteStart) == [0, 4096])
        #expect(info.clipTimeline.map(\.cumulativeBeforeSec) == [0, 20])
        #expect(info.clipTimeline.map(\.predictedShiftSec) == [0, -20])
    }

    @Test("a preferred playlist is the only playlist read, and the only title")
    func preferredPlaylistIsTheOnlyOneRead() throws {
        let (folder, _) = Self.tinyStreamFolder(preferredPlaylist: "00800.mpls")
        let info = try #require(try DiscReader.wrap(folder))
        #expect(info.titles.count == 1)
        #expect(folder.openedPaths.filter { $0.contains("/PLAYLIST/") } == ["BDMV/PLAYLIST/00800.mpls"])
    }

    @Test("a preferred playlist missing from the listing falls back to scanning every playlist")
    func missingPreferredPlaylistScansAll() throws {
        let (folder, _) = Self.tinyStreamFolder(preferredPlaylist: "00042.mpls")
        let info = try #require(try DiscReader.wrap(folder))
        #expect(info.selectedTitle?.bdClipIDs == ["00001", "00002"])
        #expect(Set(folder.openedPaths.filter { $0.contains("/PLAYLIST/") })
                == ["BDMV/PLAYLIST/00000.mpls", "BDMV/PLAYLIST/00800.mpls"])
    }

    @Test("selectTitleID chooses among the folder's titles and clamps out-of-range ids to the main one")
    func titleSelection() throws {
        let long = Self.mpls([(id: "00001", inT: 0, outT: 2_700_000)])
        let shorter = Self.mpls([(id: "00002", inT: 0, outT: 900_000)])
        let folder = MemoryFolder([
            ("BDMV/PLAYLIST/00001.mpls", shorter),
            ("BDMV/PLAYLIST/00002.mpls", long),
            ("BDMV/STREAM/00001.m2ts", Self.clipBytes(1, count: 1000)),
            ("BDMV/STREAM/00002.m2ts", Self.clipBytes(2, count: 500)),
        ])
        let main = try #require(try DiscReader.wrap(folder))
        #expect(main.selectedTitle?.bdClipIDs == ["00001"])  // longest first
        #expect(Self.readToEnd(main.reader) == Self.clipBytes(1, count: 1000))
        let second = try #require(try DiscReader.wrap(folder, selectTitleID: 1))
        #expect(Self.readToEnd(second.reader) == Self.clipBytes(2, count: 500))
        #expect(try DiscReader.wrap(folder, selectTitleID: 9)?.selectedTitleIndex == 0)
    }

    @Test("a clip missing from STREAM is skipped; a title with none left is not a disc")
    func missingClips() throws {
        let main = Self.mpls([(id: "00001", inT: 0, outT: 900_000), (id: "00002", inT: 900_000, outT: 1_800_000)])
        let partial = MemoryFolder([
            ("BDMV/PLAYLIST/00001.mpls", main),
            ("BDMV/STREAM/00002.m2ts", Self.clipBytes(2, count: 700)),
        ])
        let info = try #require(try DiscReader.wrap(partial))
        #expect(Self.readToEnd(info.reader) == Self.clipBytes(2, count: 700))

        let empty = MemoryFolder([("BDMV/PLAYLIST/00001.mpls", main)])
        #expect(try DiscReader.wrap(empty) == nil)
        #expect(try DiscReader.wrap(MemoryFolder([("BDMV/index.bdmv", Data([1]))])) == nil)
    }

    @Test("a title whose clips restart their clock declares its rate over the playlist duration")
    func bitRateOverThePlaylistDuration() throws {
        // Two clips that both start at 1.4 s: libavformat reads the concatenation as about 8 s long and
        // divides the whole size by that, twice the real rate of the 16 s title.
        let stream = TinyTransportStreamFixture.data
        let folder = MemoryFolder([
            ("BDMV/PLAYLIST/00001.mpls", Self.mpls([(id: "00001", inT: 63000, outT: 423000),
                                                    (id: "00002", inT: 63000, outT: 423000)])),
            ("BDMV/STREAM/00001.m2ts", stream),
            ("BDMV/STREAM/00002.m2ts", stream),
        ])
        let demuxer = Demuxer()
        try demuxer.open(reader: folder)
        defer { demuxer.close() }
        let expected = Double(stream.count * 2) * 8 / 16
        #expect(abs(Double(demuxer.bitRate) - expected) / expected < 0.01)
    }

    // MARK: - The concatenating reader

    /// A file reader that counts its bytes as if they came from an origin, and whether it was closed.
    final class CountingReader: IOReader, SourceTransferCounting, @unchecked Sendable {
        private let base: DataIOReader
        private let lock = NSLock()
        private var fetched: Int64 = 0
        private(set) var closed = false

        init(_ data: Data) { base = DataIOReader(data: data) }

        var sourceBytesFetched: Int64 { lock.withLock { fetched } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            let n = base.read(buffer, size: size)
            if n > 0 { lock.withLock { fetched += Int64(n) } }
            return n
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { base.seek(offset: offset, whence: whence) }
        func close() { lock.withLock { closed = true } }
    }

    final class Opener: @unchecked Sendable {
        let files: [String: Data]
        private let lock = NSLock()
        private(set) var readers: [CountingReader] = []
        init(_ files: [String: Data]) { self.files = files }
        func open(_ path: String) -> IOReader? {
            guard let data = files[path] else { return nil }
            let reader = CountingReader(data)
            lock.withLock { readers.append(reader) }
            return reader
        }
        var openCount: Int { lock.withLock { readers.filter { !$0.closed }.count } }
    }

    @Test("reads cross file boundaries, and every seek origin lands where a single file would")
    func concatenatedReads() {
        let parts = (1...4).map { Self.clipBytes(UInt8($0), count: 100 * $0) }
        let opener = Opener(Dictionary(uniqueKeysWithValues: parts.enumerated().map { ("f\($0.offset)", $0.element) }))
        let reader = MultiFileConcatIOReader(
            segments: parts.enumerated().map { .init(path: "f\($0.offset)", size: Int64($0.element.count)) },
            opener: { opener.open($0) })
        let whole = parts.reduce(Data(), +)
        #expect(Self.readToEnd(reader, chunk: 77) == whole)
        #expect(reader.seek(offset: 0, whence: 65536) == 1000)
        #expect(reader.seek(offset: 250, whence: SEEK_SET) == 250)
        #expect(Self.readToEnd(reader, chunk: 120).first == whole[250])
        #expect(reader.seek(offset: -10, whence: SEEK_END) == 990)
        #expect(reader.seek(offset: -5, whence: SEEK_CUR) == 985)
        #expect(Self.readToEnd(reader) == whole.suffix(15))
        #expect(reader.seek(offset: -1, whence: SEEK_SET) < 0)
    }

    @Test("at most three files stay open, and closed ones keep counting toward the bytes fetched")
    func boundedOpenFiles() {
        let parts = (0..<6).map { Self.clipBytes(UInt8($0), count: 64) }
        let opener = Opener(Dictionary(uniqueKeysWithValues: parts.enumerated().map { ("f\($0.offset)", $0.element) }))
        let reader = MultiFileConcatIOReader(
            segments: parts.indices.map { .init(path: "f\($0)", size: 64) }, opener: { opener.open($0) })
        _ = Self.readToEnd(reader, chunk: 64)
        #expect(opener.readers.count == 6)
        #expect(opener.openCount == MultiFileConcatIOReader.openLimit)
        #expect(reader.sourceBytesFetched == 6 * 64)
        reader.close()
        #expect(opener.openCount == 0)
        #expect(reader.sourceBytesFetched == 6 * 64)
    }

    @Test("a file shorter than listed ends the read early instead of inventing bytes")
    func shortFile() {
        let opener = Opener(["a": Self.clipBytes(1, count: 50), "b": Self.clipBytes(2, count: 100)])
        let reader = MultiFileConcatIOReader(segments: [.init(path: "a", size: 80), .init(path: "b", size: 100)],
                                             opener: { opener.open($0) })
        var buffer = [UInt8](repeating: 0, count: 200)
        let n = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 200) }
        #expect(n == 50)
    }

    /// A file whose reads park until `cancel`, the way a network read waits on a stalled origin.
    final class ParkingReader: IOReader, @unchecked Sendable {
        let parked = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            parked.signal()
            release.wait()
            return -1
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { offset }
        func close() {}
        func cancel() { release.signal() }
    }

    @Test("a cancel unblocks a read parked inside a file", .timeLimit(.minutes(3)))
    func cancelUnblocksAParkedRead() {
        let file = ParkingReader()
        let reader = MultiFileConcatIOReader(segments: [.init(path: "f", size: 100)], opener: { _ in file })
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 10)
            _ = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 10) }
            returned.signal()
        }
        #expect(file.parked.wait(timeout: .now() + 10) == .success)
        reader.cancel()
        #expect(returned.wait(timeout: .now() + 10) == .success)
    }

    @Test("a cancel that arrives while a file is still opening cancels that file once it exists", .timeLimit(.minutes(3)))
    func cancelDuringOpen() {
        let file = ParkingReader()
        let opening = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let reader = MultiFileConcatIOReader(segments: [.init(path: "f", size: 100)], opener: { _ in
            opening.signal()
            proceed.wait()
            return file
        })
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 10)
            _ = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 10) }
            returned.signal()
        }
        #expect(opening.wait(timeout: .now() + 10) == .success)
        reader.cancel()
        proceed.signal()
        #expect(returned.wait(timeout: .now() + 10) == .success)
    }

    // MARK: - Over HTTP, and through the engine

    @Test("an HTTP folder plays the same bytes, with an independent reader of its own", .timeLimit(.minutes(3)))
    func httpFolder() throws {
        let (memory, stream) = Self.tinyStreamFolder()
        var origins: [KeepAliveRangeOrigin] = []
        defer { origins.forEach { $0.stop() } }
        var files: [HTTPDiscDirectoryReader.File] = []
        for path in memory.order {
            let origin = try #require(KeepAliveRangeOrigin(data: memory.files[path]!))
            origins.append(origin)
            files.append(.init(path: path, size: Int64(memory.files[path]!.count),
                               url: URL(string: "http://127.0.0.1:\(origin.port)/\(path)")!))
        }
        let folder = HTTPDiscDirectoryReader(files: files)
        let info = try #require(try DiscReader.wrap(folder))
        #expect(Self.readToEnd(info.reader, chunk: 4096) == stream)
        #expect((info.reader as? SourceTransferCounting)?.sourceBytesFetched ?? 0 >= Int64(stream.count))
        info.reader.close()

        let clone = try #require(folder.makeIndependentReader() as? DiscDirectoryReader)
        let again = try #require(try DiscReader.wrap(clone))
        #expect(Self.readToEnd(again.reader, chunk: 4096) == stream)
        again.reader.close()
    }

    @Test("the public probe reads a folder source as its main title's stream")
    func probeOfAFolder() throws {
        let (folder, _) = Self.tinyStreamFolder()
        let probe = try AetherEngine.probe(source: .custom(folder))
        #expect(probe.videoCodecName == "h264")
        #expect(abs(probe.durationSeconds - 8) < 1)
        #expect(folder.openedPaths.contains("BDMV/STREAM/00002.m2ts"))
    }
}
