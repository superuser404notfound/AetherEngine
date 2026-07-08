import XCTest
@testable import AetherEngine

// #3 (AetherPlayer stats): the declared video bitrate must survive Matroska, where mkvmerge leaves
// codecpar.bit_rate at 0 and writes the per-track rate as a `BPS`/`BPS-eng` statistics tag instead.
// resolveBitrate encodes the codecpar-wins-then-BPS-tag precedence; these cover it without a media fixture.
final class DemuxerBitrateTests: XCTestCase {
    func test_prefersCodecparBitrateWhenPresent() {
        // MP4/TS path: codecpar carries the rate, tag ignored even if also present.
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: 8_000_000, bpsTag: "5000000"), 8_000_000)
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: 8_000_000, bpsTag: nil), 8_000_000)
    }

    func test_fallsBackToBPSTagWhenCodecparIsZero() {
        // Matroska path: codecpar.bit_rate == 0, mkvmerge BPS tag supplies the rate.
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: 0, bpsTag: "12000000"), 12_000_000)
    }

    func test_trimsWhitespaceInBPSTag() {
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: 0, bpsTag: " 12000000 "), 12_000_000)
    }

    func test_returnsZeroWhenNeitherDeclared() {
        // Lossless VBR / stripped stats: honest "unavailable" so the host shows a placeholder.
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: 0, bpsTag: nil), 0)
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: 0, bpsTag: ""), 0)
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: 0, bpsTag: "not-a-number"), 0)
    }

    func test_ignoresNonPositiveValues() {
        // Negative/zero codecpar values are treated as unavailable, not surfaced as a rate.
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: -1, bpsTag: "9000000"), 9_000_000)
        XCTAssertEqual(Demuxer.resolveBitrate(codecparBitrate: 0, bpsTag: "0"), 0)
    }
}
