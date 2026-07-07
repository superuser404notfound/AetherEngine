import XCTest
@testable import AetherEngine

/// AE#105: a multi-clip Blu-ray title concatenates m2ts clips that each carry their own STC, so the raw
/// source PTS leaps at every clip boundary. The demuxer folds each clip onto one contiguous presentation
/// timeline by subtracting a per-clip offset, attributing packets to clips by byte position. These cover
/// the pure pieces of that transform (the end-to-end packet rewrite is device-verified on the real disc).
final class Issue105MultiClipTimelineTests: XCTestCase {

    // MARK: - Byte-position -> clip attribution (ClipSpan.index)

    func test_indexAttributesByByteBoundary() {
        let spans = [ClipSpan(concatByteStart: 0, subtractSeconds: 0),
                     ClipSpan(concatByteStart: 1_000, subtractSeconds: 5),
                     ClipSpan(concatByteStart: 2_000, subtractSeconds: 9)]
        XCTAssertEqual(ClipSpan.index(forPos: 0, in: spans, fallback: 0), 0)
        XCTAssertEqual(ClipSpan.index(forPos: 999, in: spans, fallback: 0), 0)
        XCTAssertEqual(ClipSpan.index(forPos: 1_000, in: spans, fallback: 0), 1)   // boundary belongs to the new clip
        XCTAssertEqual(ClipSpan.index(forPos: 1_500, in: spans, fallback: 0), 1)
        XCTAssertEqual(ClipSpan.index(forPos: 2_000, in: spans, fallback: 0), 2)
        XCTAssertEqual(ClipSpan.index(forPos: 9_999, in: spans, fallback: 0), 2)
    }

    func test_indexNegativePosUsesFallback() {
        // A packet / index entry that reports no byte position keeps the last clip (reads are sequential).
        let spans = [ClipSpan(concatByteStart: 0, subtractSeconds: 0),
                     ClipSpan(concatByteStart: 1_000, subtractSeconds: 5)]
        XCTAssertEqual(ClipSpan.index(forPos: -1, in: spans, fallback: 1), 1)
        XCTAssertEqual(ClipSpan.index(forPos: -1, in: spans, fallback: 9), 1)   // clamped into range
    }

    func test_indexEmptyReturnsFallback() {
        XCTAssertEqual(ClipSpan.index(forPos: 500, in: [], fallback: 3), 3)
    }

    // MARK: - Normalized timeline is contiguous

    /// Replicates the Demuxer's per-packet transform (subtract the clip's seconds converted to the stream
    /// time base) and asserts the two-clip title presents one contiguous 90 kHz timeline instead of leaping
    /// to ~1:10:xx at the boundary (the reported symptom).
    func test_normalizationYieldsContiguousTimeline() {
        let tbDen = 90_000, tbNum = 1
        let clip1SubSeconds = 91_803.0     // BDTitleSelector.clipSubtractTicks -> 4_131_135_000 / 45000
        let spans = [ClipSpan(concatByteStart: 0, subtractSeconds: 0),
                     ClipSpan(concatByteStart: 1_000_000, subtractSeconds: clip1SubSeconds)]

        func normalized(rawPts: Int64, pos: Int64) -> Int64 {
            let idx = ClipSpan.index(forPos: pos, in: spans, fallback: 0)
            let sub = spans[idx].subtractSeconds
            guard sub != 0 else { return rawPts }
            let subTicks = Int64((sub * Double(tbDen) / Double(tbNum)).rounded())
            return rawPts - subTicks
        }

        // Last frame of clip0 (its byte range) and first frame of clip1 (raw PTS jumps by +91803s).
        let clip0LastRaw: Int64 = 381_600_000      // 4240.0s
        let clip1FirstRaw: Int64 = 8_643_870_000   // 96043.0s
        let clip0LastNorm = normalized(rawPts: clip0LastRaw, pos: 500_000)
        let clip1FirstNorm = normalized(rawPts: clip1FirstRaw, pos: 1_000_000)

        // Clip0 is untouched; clip1 is pulled back to continue right where clip0 ended (~4240s), not 96043s.
        XCTAssertEqual(clip0LastNorm, 381_600_000)
        XCTAssertEqual(Double(clip1FirstNorm) / 90_000.0, 4240.0, accuracy: 0.01)
        // Without normalization the boundary gap is ~91803s; with it, sub-second.
        XCTAssertLessThan(abs(Double(clip1FirstNorm - clip0LastNorm) / 90_000.0), 0.5)
    }
}
