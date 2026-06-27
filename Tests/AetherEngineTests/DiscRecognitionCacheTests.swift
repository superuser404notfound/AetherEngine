import XCTest
@testable import AetherEngine

/// #76: a subtitle / audio track switch on a remote ISO re-opens a demuxer, which re-runs disc
/// recognition (UDF/ISO directory parse + every .mpls/.IFO read). `DiscReader.wrap` must memoize the
/// parsed structure per source key so a second open reuses it instead of re-reading the disc.
final class DiscRecognitionCacheTests: XCTestCase {
    override func setUp() { super.setUp(); DiscReader.clearCache() }
    override func tearDown() { DiscReader.clearCache(); super.tearDown() }

    /// Counts every `read` so a cache hit (which must not touch the fresh reader's bytes during
    /// recognition) is observable. Payload reads through the rebuilt concat reader come after the
    /// count is sampled, so they don't pollute the assertion.
    private final class CountingIOReader: IOReader, @unchecked Sendable {
        private let base: DataIOReader
        private(set) var readCount = 0
        init(_ data: Data) { base = DataIOReader(data: data) }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            readCount += 1
            return base.read(buffer, size: size)
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { base.seek(offset: offset, whence: whence) }
        func close() { base.close() }
    }

    /// Minimal single-title Blu-ray UDF image (one .mpls, one m2ts clip).
    private func bdImage() -> Data {
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        var pi: [UInt8] = []
        pi += Array("00001".utf8); pi += Array("M2TS".utf8); pi += be16(0); pi.append(0)
        pi += be32(0); pi += be32(90000); pi += [UInt8](repeating: 0, count: 8)
        var playlist: [UInt8] = []
        playlist += be32(0); playlist += be16(0); playlist += be16(1); playlist += be16(0)
        playlist += be16(pi.count); playlist += pi
        var mpls: [UInt8] = []
        mpls += Array("MPLS".utf8); mpls += Array("0200".utf8); mpls += be32(40); mpls += be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count); mpls += playlist
        var m2ts: [UInt8] = []
        for _ in 0..<400 { m2ts += [0x00, 0x00, 0x00, 0x00, 0x47]; m2ts += [UInt8](repeating: 0x10, count: 187) }
        return UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts)
    }

    func test_secondWrapWithSameKeyReusesRecognitionWithoutReparsing() throws {
        let image = bdImage()

        let r1 = CountingIOReader(image)
        _ = try XCTUnwrap(try DiscReader.wrap(r1, cacheKey: "disc://movie.iso"))
        XCTAssertGreaterThan(r1.readCount, 0, "first wrap should parse the disc directory")

        let r2 = CountingIOReader(image)
        let info2 = try XCTUnwrap(try DiscReader.wrap(r2, cacheKey: "disc://movie.iso"))
        XCTAssertEqual(r2.readCount, 0, "cache hit must not re-read the disc directory")

        // The rebuilt concat reader is still bound to r2, so payload reads resolve correctly.
        XCTAssertEqual(info2.formatHint, "mpegts")
        XCTAssertEqual(info2.titles.count, 1)
        var buf = [UInt8](repeating: 0, count: 5)
        _ = buf.withUnsafeMutableBufferPointer { info2.reader.read($0.baseAddress, size: 5) }
        XCTAssertEqual(buf, [0x00, 0x00, 0x00, 0x00, 0x47])
    }

    func test_differentKeyDoesNotHitCache() throws {
        let image = bdImage()
        _ = try XCTUnwrap(try DiscReader.wrap(CountingIOReader(image), cacheKey: "disc://a.iso"))

        let r2 = CountingIOReader(image)
        _ = try XCTUnwrap(try DiscReader.wrap(r2, cacheKey: "disc://b.iso"))
        XCTAssertGreaterThan(r2.readCount, 0, "a different source key must re-parse, not bleed across discs")
    }

    func test_nilKeyNeverCaches() throws {
        let image = bdImage()
        _ = try XCTUnwrap(try DiscReader.wrap(CountingIOReader(image), cacheKey: nil))

        let r2 = CountingIOReader(image)
        _ = try XCTUnwrap(try DiscReader.wrap(r2, cacheKey: nil))
        XCTAssertGreaterThan(r2.readCount, 0, "a nil key opts out of caching entirely")
    }
}
