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
    /// ISO 639-2 language codes from the PlayItems' STN tables, keyed by elementary-stream PID. A
    /// Blu-ray keeps its track languages here, not in the clip's PMT, so this is the only place a
    /// demuxed m2ts can learn them. Empty when no PlayItem declares one. See `parseSTNLanguages` (#527).
    var streamLanguages: [Int: String] = [:]
    /// The playlist's file name as the disc lists it ("00800.mpls"). Set by `DiscReader.scanPlaylists`,
    /// which is where the name is known; nil for a playlist parsed from bytes alone (#1034).
    var fileName: String? = nil
}

enum MPLSParser {
    /// BD-ROM caps a playlist at 999 PlayItems, and the count field is 16 bits wide (audit NET-103).
    static let maxPlayItems = 999

    static func parse(_ data: [UInt8]) -> MPLSPlaylist? {
        guard data.count >= 16,
              Array(data[0..<4]) == Array("MPLS".utf8) else { return nil }
        let plStart = be32(data, 8)
        guard plStart + 10 <= data.count else { return nil }
        let count = be16(data, plStart + 6)
        guard count <= maxPlayItems else { return nil }
        var pos = plStart + 10
        var clips: [String] = []
        var ticks: UInt64 = 0
        // Per-PlayItem state for chapter resolution: a mark's timestamp is on its clip's STC (which begins at
        // the PlayItem's in_time), so the title-relative chapter start needs in_time and the running offset.
        var inTimes: [UInt64] = []
        var cumulativeBefore: [UInt64] = []
        var languages: [Int: String] = [:]
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
            parseSTNLanguages(data, body: body, itemLen: itemLen, into: &languages)
            pos = body + itemLen
        }
        guard !clips.isEmpty else { return nil }
        let chapters = parseChapterStarts(data, inTimes: inTimes, cumulativeBefore: cumulativeBefore)
        return MPLSPlaylist(clipIDs: clips, durationTicks: ticks,
                            inTimes: inTimes, cumulativeBefore: cumulativeBefore,
                            chapterStartTicks: chapters, streamLanguages: languages)
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

    // MARK: - STN table languages (#527)

    /// Collect one PlayItem's declared ISO 639-2 languages, keyed by elementary-stream PID, into `langs`.
    ///
    /// A Blu-ray's clip PMTs carry no ISO 639 descriptor, so FFmpeg's MPEG-TS demuxer reports every track
    /// as undetermined and language-based track selection has nothing to match on. The languages live in
    /// each PlayItem's STN_table, which this walk reaches past the PlayItem's fixed header. Lenient
    /// throughout: a table that runs short or declares a shape this does not model contributes whatever it
    /// resolved before the malformed entry and never fails the playlist.
    ///
    /// First declaration wins. Every PlayItem of a title repeats the same STN table in practice, and where
    /// a seamless-branching title disagrees, the first clip is the one whose PIDs the demuxer opens with.
    private static func parseSTNLanguages(
        _ data: [UInt8], body: Int, itemLen: Int, into langs: inout [Int: String]
    ) {
        // PlayItem fixed header: clip_id(5) codec_id(4) flags(2) stc_id(1) in_time(4) out_time(4)
        // UO_mask(8) random_access_flag+reserved(1) still_mode(1) still_time(2) = 32 bytes.
        let itemEnd = body + itemLen
        guard itemEnd <= data.count else { return }
        var pos = body + 32
        // is_multi_angle is bit 4 of the 16-bit field at body+9 (11 reserved bits, the flag, then
        // connection_condition), and when set, an angle block sits between the header and the STN table:
        // angle_count(1) + flags(1), then clip_id(5) + codec_id(4) + stc_id(1) per ADDITIONAL angle.
        guard body + 11 <= data.count else { return }
        if (data[body + 10] >> 4) & 1 == 1 {
            guard pos < itemEnd else { return }
            let angleCount = max(1, Int(data[pos]))
            pos += 2 + (angleCount - 1) * 10
        }
        // STN_table header: length(2) reserved(2) num_video(1) num_audio(1) num_pg(1) num_ig(1)
        // num_secondary_audio(1) num_secondary_video(1) num_pip_pg(1) reserved(5) = 16 bytes.
        guard pos >= 0, pos + 16 <= itemEnd else { return }
        let numVideo = Int(data[pos + 4])
        let numAudio = Int(data[pos + 5])
        let numPG = Int(data[pos + 6])
        let numIG = Int(data[pos + 7])
        let numPIPPG = Int(data[pos + 10])
        pos += 16
        // Entries run video, audio, PG (+ PiP PG), IG, then the secondary streams. The walk stops after IG:
        // secondary audio and video carry extra attribute blocks this does not model, and nothing past IG
        // is a track the engine exposes anyway, so a wrong guess there could only corrupt what came before.
        for _ in 0..<(numVideo + numAudio + numPG + numPIPPG + numIG) {
            guard let entry = parseSTNStream(data, at: pos, end: itemEnd) else { return }
            pos = entry.next
            if let pid = entry.pid, let language = entry.language, langs[pid] == nil {
                langs[pid] = language
            }
        }
    }

    private struct STNStream {
        let pid: Int?
        let language: String?
        /// Byte offset of the next stream entry.
        let next: Int
    }

    /// One STN stream: a length-prefixed stream_entry (which names the PID) followed by a length-prefixed
    /// stream_attributes block (which names the language for the codings that have one). Both are
    /// length-prefixed, so the walk skips a coding it does not model instead of losing its place.
    private static func parseSTNStream(_ data: [UInt8], at pos: Int, end: Int) -> STNStream? {
        guard pos >= 0, pos < end, end <= data.count else { return nil }
        let entryLen = Int(data[pos])
        let entry = pos + 1
        let attrPos = entry + entryLen
        guard attrPos < end else { return nil }
        let attrLen = Int(data[attrPos])
        let attr = attrPos + 1
        let next = attr + attrLen
        guard next <= end else { return nil }

        // stream_entry: type(1) then the PID, placed per type. 1 = in the PlayItem's own clip,
        // 2 and 4 = a sub-path's clip (subpath_id + subclip_id first), 3 = in-mux sub-path (subpath_id).
        var pid: Int? = nil
        if entryLen >= 1 {
            switch data[entry] {
            case 1 where entryLen >= 3: pid = be16(data, entry + 1)
            case 2, 4: if entryLen >= 5 { pid = be16(data, entry + 3) }
            case 3 where entryLen >= 4: pid = be16(data, entry + 2)
            default: break
            }
        }

        // stream_attributes: coding_type(1) then, for the codings that declare one, a 3-byte ISO 639-2
        // code at a coding-dependent offset. Audio prefixes it with a format/rate byte, text subtitle
        // with a character-code byte, PG and IG with nothing.
        var language: String? = nil
        if attrLen >= 1 {
            let languageOffset: Int?
            switch data[attr] {
            case 0x03, 0x04, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0xA1, 0xA2: languageOffset = 2
            case 0x90, 0x91: languageOffset = 1
            case 0x92: languageOffset = 2
            default: languageOffset = nil
            }
            if let offset = languageOffset, attr + offset + 3 <= next {
                language = DiscLanguageCode.parse(data, at: attr + offset, length: 3)
            }
        }
        return STNStream(pid: pid, language: language, next: next)
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 8) | Int(b[i+1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
    }
}
