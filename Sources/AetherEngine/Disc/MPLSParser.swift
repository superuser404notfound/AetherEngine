import Foundation

struct MPLSPlaylist: Equatable {
    let clipIDs: [String]
    let durationTicks: UInt64
    /// Per-PlayItem in_time on the clip's STC, 45 kHz ticks, parallel to `clipIDs`. A clip's presented
    /// frames begin at this STC value, so it is the origin used to fold each clip onto the title's
    /// contiguous presentation timeline (AE#105 multi-clip position drift).
    var inTimes: [UInt64] = []
    /// Presentation offset of each PlayItem's start, 45 kHz ticks relative to the title's start (sum of the
    /// durations of all earlier PlayItems), parallel to `clipIDs`.
    var cumulativeBefore: [UInt64] = []
    /// Entry-mark chapter starts, 45 kHz ticks relative to the title's start, sorted ascending. Empty when
    /// the playlist declares no PlayListMark section (or only link-point marks). See `parseChapterStarts` (#67).
    var chapterStartTicks: [UInt64] = []
}

enum MPLSParser {
    static func parse(_ data: [UInt8]) -> MPLSPlaylist? {
        guard data.count >= 16,
              Array(data[0..<4]) == Array("MPLS".utf8) else { return nil }
        let plStart = be32(data, 8)
        guard plStart + 10 <= data.count else { return nil }
        let count = be16(data, plStart + 6)
        var pos = plStart + 10
        var clips: [String] = []
        var ticks: UInt64 = 0
        // Per-PlayItem state for chapter resolution: a mark's timestamp is on its clip's STC (which begins at
        // the PlayItem's in_time), so the title-relative chapter start needs in_time and the running offset.
        var inTimes: [UInt64] = []
        var cumulativeBefore: [UInt64] = []
        for _ in 0..<count {
            guard pos + 2 <= data.count else { return nil }
            let itemLen = be16(data, pos)
            let body = pos + 2
            guard body + 22 <= data.count, body + itemLen <= data.count else { return nil }
            let clip = String(decoding: data[body..<(body+5)], as: UTF8.self)
            let inT = UInt64(be32(data, body + 12))
            let outT = UInt64(be32(data, body + 16))
            clips.append(clip)
            inTimes.append(inT)
            cumulativeBefore.append(ticks)
            if outT >= inT { ticks += (outT - inT) }
            pos = body + itemLen
        }
        guard !clips.isEmpty else { return nil }
        let chapters = parseChapterStarts(data, inTimes: inTimes, cumulativeBefore: cumulativeBefore)
        return MPLSPlaylist(clipIDs: clips, durationTicks: ticks,
                            inTimes: inTimes, cumulativeBefore: cumulativeBefore,
                            chapterStartTicks: chapters)
    }

    /// Parse the PlayListMark section (header offset 12 = PlayListMarkStartAddress) into title-relative chapter
    /// starts. Lenient: any malformed mark data yields no chapters rather than failing the whole playlist.
    private static func parseChapterStarts(
        _ data: [UInt8], inTimes: [UInt64], cumulativeBefore: [UInt64]
    ) -> [UInt64] {
        guard data.count >= 16 else { return [] }
        let plmStart = be32(data, 12)
        // 0 (or out of range) = no PlayListMark section. Need length(4) + number_of_marks(2).
        guard plmStart > 0, plmStart + 6 <= data.count else { return [] }
        let markCount = be16(data, plmStart + 4)
        var entry = plmStart + 6
        var starts: [UInt64] = []
        for _ in 0..<markCount {
            guard entry + 14 <= data.count else { break }
            let markType = data[entry + 1]
            let ref = be16(data, entry + 2)
            let timeStamp = UInt64(be32(data, entry + 4))
            entry += 14
            // 1 = entry mark (chapter); 2 = link point (navigation, not a chapter). Skip unknown refs.
            guard markType == 1, ref < inTimes.count else { continue }
            let onClip = timeStamp >= inTimes[ref] ? timeStamp - inTimes[ref] : 0
            starts.append(cumulativeBefore[ref] + onClip)
        }
        // Marks can appear out of order; present chapters in playback order, deduped.
        var seen = Set<UInt64>()
        return starts.sorted().filter { seen.insert($0).inserted }
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 8) | Int(b[i+1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
    }
}
