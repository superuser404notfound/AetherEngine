import XCTest
@testable import AetherEngine

final class MovTextMuxerTests: XCTestCase {
    // The muxer's FFmpeg interop is validated end-to-end by the Phase 0
    // spike + ffprobe; here we pin the pure helper the muxer uses to map
    // seconds onto the subtitle stream time_base (1/1000), so the
    // sample-write timing cannot silently regress.
    func test_secondsToSubtitleTimeBaseTicks_millisecondBase() {
        XCTAssertEqual(MP4SegmentMuxer.subtitleTicks(forSeconds: 1.5, timescale: 1000), 1500)
        XCTAssertEqual(MP4SegmentMuxer.subtitleTicks(forSeconds: 0.0, timescale: 1000), 0)
        XCTAssertEqual(MP4SegmentMuxer.subtitleTicks(forSeconds: 90.0, timescale: 1000), 90000)
    }

    func test_iso639_2_mapsCommonBCP47Tags() {
        XCTAssertEqual(MP4SegmentMuxer.iso639_2(fromBCP47: "en"), "eng")
        XCTAssertEqual(MP4SegmentMuxer.iso639_2(fromBCP47: "de"), "deu")
        XCTAssertEqual(MP4SegmentMuxer.iso639_2(fromBCP47: "ja"), "jpn")
        XCTAssertEqual(MP4SegmentMuxer.iso639_2(fromBCP47: "en-US"), "eng") // region stripped
        XCTAssertNil(MP4SegmentMuxer.iso639_2(fromBCP47: nil))
        XCTAssertEqual(MP4SegmentMuxer.iso639_2(fromBCP47: "eng"), "eng") // 3-letter passthrough
        XCTAssertNil(MP4SegmentMuxer.iso639_2(fromBCP47: "xx")) // unknown tag
    }
}
