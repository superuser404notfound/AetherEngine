import XCTest
@testable import AetherEngine

final class MPLSParserTests: XCTestCase {
    private func makeMPLS() -> [UInt8] {
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff), UInt8((v>>16)&0xff), UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func playItem(clip: String, inT: Int, outT: Int) -> [UInt8] {
            var body = [UInt8]()
            body += Array(clip.utf8)
            body += Array("M2TS".utf8)
            body += be16(0)
            body.append(0)
            body += be32(inT)
            body += be32(outT)
            body += [UInt8](repeating: 0, count: 8)
            return be16(body.count) + body
        }
        let items = playItem(clip: "00002", inT: 0, outT: 90000)
                  + playItem(clip: "00005", inT: 0, outT: 180000)
        var playlist = [UInt8]()
        playlist += be32(0)
        playlist += be16(0)
        playlist += be16(2)
        playlist += be16(0)
        playlist += items
        var out = [UInt8]()
        out += Array("MPLS".utf8)
        out += Array("0200".utf8)
        let plStart = 40
        out += be32(plStart)
        out += be32(0)
        out += [UInt8](repeating: 0, count: plStart - out.count)
        out += playlist
        return out
    }

    func test_parsesClipOrderAndDuration() {
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS()))
        XCTAssertEqual(pl.clipIDs, ["00002", "00005"])
        XCTAssertEqual(pl.durationTicks, 270000)
    }

    // AE#105: per-clip in_time and cumulative presentation offset are retained (parallel to clipIDs) so a
    // multi-clip title can fold each clip's discontinuous STC onto one contiguous presentation timeline.
    func test_retainsPerClipInTimesAndCumulativeOffsets() {
        // makeMPLS: item0 in=0/out=90000 (dur 90000), item1 in=0/out=180000 (dur 180000).
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS()))
        XCTAssertEqual(pl.inTimes, [0, 0])
        XCTAssertEqual(pl.cumulativeBefore, [0, 90000])   // item1 starts after item0's 90000-tick duration
    }

    func test_rejectsBadMagic() {
        XCTAssertNil(MPLSParser.parse(Array("NOPE0200".utf8) + [UInt8](repeating: 0, count: 40)))
    }

    // MARK: - PlayListMark chapters (#67 Phase 2)

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v>>24)&0xff), UInt8((v>>16)&0xff), UInt8((v>>8)&0xff), UInt8(v&0xff)]
    }
    private func playItem(clip: String, inT: Int, outT: Int) -> [UInt8] {
        var body = [UInt8]()
        body += Array(clip.utf8); body += Array("M2TS".utf8)
        body += be16(0); body.append(0)
        body += be32(inT); body += be32(outT)
        body += [UInt8](repeating: 0, count: 8)
        return be16(body.count) + body
    }
    private func mark(type: Int, ref: Int, time: Int) -> [UInt8] {
        var e = [UInt8]()
        e.append(0)            // reserved
        e.append(UInt8(type))  // mark_type: 1 = entry (chapter), 2 = link point
        e += be16(ref)         // ref_to_play_item_id
        e += be32(time)        // mark_time_stamp (45 kHz, on the referenced clip's STC)
        e += be16(0xFFFF)      // entry ES PID
        e += be32(0)           // duration
        return e
    }
    /// Two play items (item0 in=0/out=90000, item1 in=10000/out=190000) + 5 marks at header offset 12.
    private func makeMPLSWithMarks() -> [UInt8] {
        let items = playItem(clip: "00002", inT: 0, outT: 90000)
                  + playItem(clip: "00005", inT: 10000, outT: 190000)
        var playlist = [UInt8]()
        playlist += be32(0); playlist += be16(0); playlist += be16(2); playlist += be16(0)
        playlist += items
        let entries = mark(type: 1, ref: 0, time: 0)        // item0 start -> 0
                    + mark(type: 1, ref: 0, time: 45000)    // item0 +1s   -> 45000
                    + mark(type: 2, ref: 0, time: 67500)    // link point  -> ignored
                    + mark(type: 1, ref: 1, time: 100000)   // item1: 90000 + (100000-10000) = 180000
                    + mark(type: 1, ref: 5, time: 0)        // out-of-range play item -> skipped
        var markSection = [UInt8]()
        markSection += be32(2 + entries.count)  // length
        markSection += be16(5)                  // number_of_PlayList_marks
        markSection += entries
        var out = [UInt8]()
        out += Array("MPLS".utf8); out += Array("0200".utf8)
        let plStart = 40
        let plmStart = plStart + playlist.count
        out += be32(plStart)    // @8  PlayListStartAddress
        out += be32(plmStart)   // @12 PlayListMarkStartAddress
        out += be32(0)          // @16 ExtensionDataStartAddress
        out += [UInt8](repeating: 0, count: plStart - out.count)  // reserved up to 40
        out += playlist
        out += markSection
        return out
    }

    func test_parsesEntryMarkChaptersTitleRelative() {
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLSWithMarks()))
        XCTAssertEqual(pl.clipIDs, ["00002", "00005"])
        XCTAssertEqual(pl.durationTicks, 270000)
        // Entry marks only (link point dropped, out-of-range ref skipped), each made title-relative:
        // mark_time - in_time(ref) + sum(durations of preceding play items).
        XCTAssertEqual(pl.chapterStartTicks, [0, 45000, 180000])
    }

    func test_noChaptersWhenMarkAddressZero() {
        // The base fixture leaves PlayListMarkStartAddress (offset 12) at 0 -> no chapters.
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS()))
        XCTAssertTrue(pl.chapterStartTicks.isEmpty)
    }
}
