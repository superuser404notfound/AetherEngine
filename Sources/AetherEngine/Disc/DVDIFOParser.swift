import Foundation

/// A DVD-Video title from the VMGI Title Search Pointer Table (TT_SRPT). Maps the disc's user-visible
/// titles onto the title sets (VTS) that back them, with each title's chapter count (#67).
struct DVDIFOTitle: Equatable {
    /// 1-based title-set number (VTS_NN_*). The whole-VTS title resolution concatenates this VTS's VOBs.
    let vtsn: Int
    /// Title number within its VTS (vts_ttn). Multiple titles can share a VTS (episodic TV).
    let vtsTitleNumber: Int
    /// Number of parts-of-title (PTTs = chapters) in this title. Surfaced for chapter enumeration (Phase 4).
    let chapterCount: Int
    /// Number of angles (1 for non-multiangle titles).
    let angleCount: Int
}

/// Parses the DVD-Video Video Manager (VIDEO_TS.IFO / VMGI) just far enough to enumerate titles. The
/// VMGI_MAT holds the TT_SRPT start sector at byte offset 0xC4; TT_SRPT lists every title with the VTS
/// that backs it. Byte layout per libdvdread's ifo_types (tt_srpt_t / title_info_t).
enum DVDIFOParser {
    private static let vmgMagic = Array("DVDVIDEO-VMG".utf8)
    private static let sectorSize = 2048
    /// VMGI_MAT offset of the 4-byte TT_SRPT start-sector pointer.
    private static let ttSrptPointerOffset = 0xC4

    /// Returns the disc's titles from TT_SRPT, or nil if the bytes are not a recognizable VMGI / the table
    /// is malformed or out of range (the caller then falls back to the VOB-size heuristic).
    static func parseTitles(_ data: [UInt8]) -> [DVDIFOTitle]? {
        guard data.count >= ttSrptPointerOffset + 4,
              Array(data[0..<12]) == vmgMagic else { return nil }
        let ttSrptSector = be32(data, ttSrptPointerOffset)
        // Sector 0 would overlap the VMGI header; treat as absent.
        guard ttSrptSector > 0 else { return nil }
        let base = ttSrptSector * sectorSize
        // TT_SRPT header: nr_of_titles(2) + reserved(2) + last_byte(4) = 8 bytes, then 12-byte entries.
        guard base + 8 <= data.count else { return nil }
        let nrTitles = be16(data, base)
        guard nrTitles > 0 else { return nil }
        var titles: [DVDIFOTitle] = []
        titles.reserveCapacity(nrTitles)
        for i in 0..<nrTitles {
            let entry = base + 8 + i * 12
            guard entry + 12 <= data.count else { break }
            let angles = Int(data[entry + 1])
            let ptts = be16(data, entry + 2)
            let vtsn = Int(data[entry + 6])
            let ttn = Int(data[entry + 7])
            // A title must name a real (1-based) title set; skip a corrupt zero entry rather than abort.
            guard vtsn > 0 else { continue }
            titles.append(DVDIFOTitle(vtsn: vtsn, vtsTitleNumber: ttn, chapterCount: ptts, angleCount: angles))
        }
        return titles.isEmpty ? nil : titles
    }

    // MARK: - VTS IFO (per-title duration + chapters)

    private static let vtsMagic = Array("DVDVIDEO-VTS".utf8)
    /// VTSI_MAT offset of the 4-byte VTS_PGCIT start-sector pointer.
    private static let vtsPgcitPointerOffset = 0xCC
    /// PGC header field offsets (relative to the PGC start), per libdvdread pgc_t.
    private static let pgcNrProgramsOffset = 0x02
    private static let pgcNrCellsOffset = 0x03
    private static let pgcPlaybackTimeOffset = 0x04
    private static let pgcProgramMapOffsetField = 0xE6
    private static let pgcCellPlaybackOffsetField = 0xE8
    /// PGC header length (through cell_position_offset); a PGC must have at least this many bytes.
    private static let pgcHeaderLength = 0xEC
    private static let cellPlaybackEntrySize = 24

    /// Parses a VTS IFO (VTS_NN_0.IFO) for the title's duration and chapter start times. Uses the longest
    /// program chain in the title set (the main feature) and resolves chapters from its program map +
    /// cumulative cell playback times. Returns nil if the bytes are not a recognizable VTSI or the PGCIT is
    /// malformed (the caller then leaves the title's duration at 0 with no chapters).
    static func parseTitleDetail(_ data: [UInt8]) -> (durationTicks: UInt64, chapterStartTicks: [UInt64])? {
        guard let pgcOffset = mainPGCOffset(data) else { return nil }
        return (durationTicks: dvdTimeTicks(data, pgcOffset + pgcPlaybackTimeOffset),
                chapterStartTicks: parsePGCChapters(data, pgcOffset: pgcOffset))
    }

    /// Byte offset of the title set's main program chain: the longest PGC across the VTS_PGCIT search
    /// pointers. nil when the bytes are not a recognizable VTSI or the PGCIT is malformed. Shared, so the
    /// duration, the chapters and the stream-language tables all describe the same chain.
    private static func mainPGCOffset(_ data: [UInt8]) -> Int? { mainPGC(data)?.offset }

    /// 主 PGC 的字节偏移与它在 VTS_PGCIT 里的下标（时间表 VTS_TMAPT 按同一个下标排）
    private static func mainPGC(_ data: [UInt8]) -> (offset: Int, index: Int)? {
        guard data.count >= vtsPgcitPointerOffset + 4,
              Array(data[0..<12]) == vtsMagic else { return nil }
        let pgcitSector = be32(data, vtsPgcitPointerOffset)
        guard pgcitSector > 0 else { return nil }
        let pgcitBase = pgcitSector * sectorSize
        guard pgcitBase + 8 <= data.count else { return nil }
        let nrSrp = be16(data, pgcitBase)
        guard nrSrp > 0 else { return nil }
        var bestOffset = -1
        var bestIndex = -1
        var bestTicks: UInt64 = 0
        for i in 0..<nrSrp {
            let srp = pgcitBase + 8 + i * 8
            guard srp + 8 <= data.count else { break }
            let pgcOffset = pgcitBase + be32(data, srp + 4)
            guard pgcOffset >= 0, pgcOffset + pgcHeaderLength <= data.count else { continue }
            let ticks = dvdTimeTicks(data, pgcOffset + pgcPlaybackTimeOffset)
            if bestOffset < 0 || ticks > bestTicks { bestOffset = pgcOffset; bestIndex = i; bestTicks = ticks }
        }
        return bestOffset >= 0 ? (bestOffset, bestIndex) : nil
    }

    // MARK: - [MovieClaw P13] 主 PGC 的 cell 与时间表（DVD 时间轴折叠与按字节定位）

    /// 主 PGC 的一个 cell：在标题 VOB（VTSTT_VOBS，从 VTS_NN_1.VOB 起连续编号）里的首尾扇区、播放时长、
    /// 是否在多角度块里
    struct Cell: Sendable, Equatable {
        let firstSector: Int
        let lastSector: Int
        let durationSec: Double
        let inAngleBlock: Bool
    }

    private static let vtsTmaptiPointerOffset = 0xD4

    /// 主 PGC 按播放顺序的 cell 表；读不懂返回 nil
    static func parseMainPGCCells(_ data: [UInt8]) -> [Cell]? {
        guard let pgc = mainPGC(data) else { return nil }
        let nrCells = Int(data[pgc.offset + pgcNrCellsOffset])
        guard nrCells > 0 else { return nil }
        let cellTable = pgc.offset + be16(data, pgc.offset + pgcCellPlaybackOffsetField)
        guard cellTable + nrCells * cellPlaybackEntrySize <= data.count else { return nil }
        return (0..<nrCells).map { c in
            let e = cellTable + c * cellPlaybackEntrySize
            // 第 0 字节：块模式（高 2 位）、块类型（其后 2 位，1 = 多角度块）
            let blockType = (Int(data[e]) >> 4) & 0x3
            return Cell(firstSector: be32(data, e + 8), lastSector: be32(data, e + 20),
                        durationSec: dvdTimeSeconds(data, e + pgcPlaybackTimeOffset), inAngleBlock: blockType == 1)
        }
    }

    /// 主 PGC 的时间表（VTS_TMAPT）：第 i 项是标题时间 (i+1)×unit 秒所在 VOBU 的起始扇区（相对 VTSTT_VOBS）。
    /// 光盘可以不带时间表，这时返回 nil
    static func parseMainTimeMap(_ data: [UInt8]) -> (unitSec: Double, sectors: [Int])? {
        guard let pgc = mainPGC(data), data.count >= vtsTmaptiPointerOffset + 4 else { return nil }
        let tmaptiSector = be32(data, vtsTmaptiPointerOffset)
        guard tmaptiSector > 0 else { return nil }
        let base = tmaptiSector * sectorSize
        guard base + 8 <= data.count else { return nil }
        let count = be16(data, base)
        guard pgc.index < count, base + 8 + (pgc.index + 1) * 4 <= data.count else { return nil }
        let tmap = base + be32(data, base + 8 + pgc.index * 4)
        guard tmap + 4 <= data.count else { return nil }
        let unit = Int(data[tmap])
        let entries = be16(data, tmap + 2)
        guard unit > 0, entries > 0, tmap + 4 + entries * 4 <= data.count else { return nil }
        // 最高位是「不连续」标志，其余 31 位是扇区号
        return (Double(unit), (0..<entries).map { be32(data, tmap + 4 + $0 * 4) & 0x7FFF_FFFF })
    }

    /// Title-relative chapter starts from a PGC's program map + cumulative cell playback times. A chapter
    /// (program) begins at its entry cell, whose start is the sum of the durations of all preceding cells.
    private static func parsePGCChapters(_ data: [UInt8], pgcOffset: Int) -> [UInt64] {
        let nrPrograms = Int(data[pgcOffset + pgcNrProgramsOffset])
        let nrCells = Int(data[pgcOffset + pgcNrCellsOffset])
        guard nrPrograms > 0, nrCells > 0 else { return [] }
        let programMap = pgcOffset + be16(data, pgcOffset + pgcProgramMapOffsetField)
        let cellTable = pgcOffset + be16(data, pgcOffset + pgcCellPlaybackOffsetField)
        guard programMap + nrPrograms <= data.count,
              cellTable + nrCells * cellPlaybackEntrySize <= data.count else { return [] }
        // Cumulative start (seconds) before each cell; index c is the start of the (1-based) cell c+1.
        var cellStartSeconds = [Double](repeating: 0, count: nrCells + 1)
        for c in 0..<nrCells {
            let dur = dvdTimeSeconds(data, cellTable + c * cellPlaybackEntrySize + pgcPlaybackTimeOffset)
            cellStartSeconds[c + 1] = cellStartSeconds[c] + dur
        }
        var starts: [UInt64] = []
        for p in 0..<nrPrograms {
            let entryCell = Int(data[programMap + p])   // 1-based cell number
            guard entryCell >= 1, entryCell <= nrCells else { continue }
            starts.append(UInt64((cellStartSeconds[entryCell - 1] * discTickRate).rounded()))
        }
        var seen = Set<UInt64>()
        return starts.sorted().filter { seen.insert($0).inserted }
    }

    // MARK: - VTS IFO stream languages (#527)

    /// VTSI_MAT offsets of the title-set stream attribute tables (DVD-Video VTSI_MAT from RBP 0x0200),
    /// per libdvdread's vtsi_mat_t.
    private static let vtsAudioCountOffset = 0x203
    private static let vtsAudioAttrOffset = 0x204
    private static let vtsAudioAttrSize = 8
    private static let vtsMaxAudioStreams = 8
    private static let vtsSubpictureCountOffset = 0x255
    private static let vtsSubpictureAttrOffset = 0x256
    private static let vtsSubpictureAttrSize = 6
    private static let vtsMaxSubpictureStreams = 32
    /// PGC stream control tables (libdvdread pgc_t): which substream number each attribute entry is
    /// actually carried as, which is not always its position in the attribute table.
    private static let pgcAudioControlOffset = 0x0C
    private static let pgcSubpictureControlOffset = 0x1C
    private static let subpictureSubstreamBase = 0x20

    /// Languages a VTS IFO declares for its audio and subpicture streams, keyed by the `AVStream.id`
    /// FFmpeg's MPEG-PS demuxer reports (it sets `st->id` to the stream / substream start code). A DVD's
    /// VOBs carry no language anywhere in the bitstream, so without the IFO every track demuxes as
    /// undetermined and language-based selection has nothing to match on.
    ///
    /// The attribute tables say WHICH language; the main PGC's control tables say which substream number
    /// carries it, and an entry the PGC marks unavailable is not in this title's VOBs at all. Without a
    /// readable PGC the attribute position is used as the substream number, which is what the great
    /// majority of discs author anyway.
    ///
    /// Empty (never nil) on an unreadable IFO: a missing language costs auto-selection, not playback, so
    /// every guard here degrades rather than failing the title (#527).
    static func parseStreamLanguages(_ data: [UInt8]) -> [Int: String] {
        guard data.count >= 12, Array(data[0..<12]) == vtsMagic else { return [:] }
        let pgc = mainPGCOffset(data)
        var languages: [Int: String] = [:]
        /// First declaration wins: the attribute tables are ordered, and a later entry's padded-out
        /// control field must not overwrite a number an earlier entry claimed outright.
        func claim(_ id: Int, _ language: String) {
            if languages[id] == nil { languages[id] = language }
        }

        // audio_attr_t: byte 0 packs audio_format(3) multichannel_extension(1) lang_type(2)
        // application_mode(2); the ISO 639-1 code sits at bytes 2-3 and is only meaningful when
        // lang_type == 1. audio_control: bit 15 = present, bits 14-8 = the substream number.
        if data.count > vtsAudioCountOffset {
            let count = min(Int(data[vtsAudioCountOffset]), vtsMaxAudioStreams)
            for n in 0..<count {
                let attr = vtsAudioAttrOffset + n * vtsAudioAttrSize
                guard attr + vtsAudioAttrSize <= data.count else { break }
                guard (Int(data[attr]) >> 2) & 0x3 == 1,
                      let language = DiscLanguageCode.parse(data, at: attr + 2, length: 2),
                      let base = audioSubstreamBase(format: Int(data[attr]) >> 5) else { continue }
                var number = n
                if let pgc, pgc + pgcAudioControlOffset + n * 2 + 2 <= data.count {
                    let control = be16(data, pgc + pgcAudioControlOffset + n * 2)
                    guard control & 0x8000 != 0 else { continue }
                    number = (control >> 8) & 0x7F
                }
                claim(base + number, language)
            }
        }

        // subp_attr_t: byte 0 packs code_mode(3) reserved(3) type(2); language at bytes 2-3, meaningful
        // when type == 1. subp_control: bit 31 = present, then four 5-bit substream numbers, one per
        // display mode (4:3, wide, letterbox, pan-and-scan). A disc authors the same subtitle several
        // times, once per mode, so every number the entry names gets its language; the three secondary
        // fields are skipped when zero, where "unused" and "stream 0" are indistinguishable.
        if data.count > vtsSubpictureCountOffset {
            let count = min(Int(data[vtsSubpictureCountOffset]), vtsMaxSubpictureStreams)
            for n in 0..<count {
                let attr = vtsSubpictureAttrOffset + n * vtsSubpictureAttrSize
                guard attr + vtsSubpictureAttrSize <= data.count else { break }
                guard Int(data[attr]) & 0x3 == 1,
                      let language = DiscLanguageCode.parse(data, at: attr + 2, length: 2) else { continue }
                guard let pgc, pgc + pgcSubpictureControlOffset + n * 4 + 4 <= data.count else {
                    claim(subpictureSubstreamBase + n, language)
                    continue
                }
                let control = be32(data, pgc + pgcSubpictureControlOffset + n * 4)
                guard control & 0x8000_0000 != 0 else { continue }
                claim(subpictureSubstreamBase + ((control >> 24) & 0x1F), language)
                for shift in [16, 8, 0] {
                    let number = (control >> shift) & 0x1F
                    if number != 0 { claim(subpictureSubstreamBase + number, language) }
                }
            }
        }
        return languages
    }

    /// Every subpicture substream id the title's IFO declares, with or without a language, ascending.
    ///
    /// The same control-table reading as `parseStreamLanguages`: an entry the main PGC marks
    /// unavailable is not in the VOBs, and each display-mode number an entry names is its own
    /// MPEG-PS substream. Without a readable PGC the attribute position is the number (#651). nil when
    /// the bytes are no VTS IFO, which is not the same answer as a title with no subpictures.
    static func parseSubpictureStreamIDs(_ data: [UInt8]) -> [Int]? {
        guard data.count >= 12, Array(data[0..<12]) == vtsMagic,
              data.count > vtsSubpictureCountOffset else { return nil }
        let pgc = mainPGCOffset(data)
        let count = min(Int(data[vtsSubpictureCountOffset]), vtsMaxSubpictureStreams)
        var ids = Set<Int>()
        for n in 0..<count {
            guard let pgc, pgc + pgcSubpictureControlOffset + n * 4 + 4 <= data.count else {
                ids.insert(subpictureSubstreamBase + n)
                continue
            }
            let control = be32(data, pgc + pgcSubpictureControlOffset + n * 4)
            guard control & 0x8000_0000 != 0 else { continue }
            ids.insert(subpictureSubstreamBase + ((control >> 24) & 0x1F))
            for shift in [16, 8, 0] {
                let number = (control >> shift) & 0x1F
                if number != 0 { ids.insert(subpictureSubstreamBase + number) }
            }
        }
        return ids.sorted()
    }

    /// Base substream id for a DVD audio coding mode; a stream's id is this plus its substream number.
    /// AC-3, DTS and LPCM ride in private_stream_1, where FFmpeg reports the substream byte; MPEG audio
    /// has its own PES stream id, where FFmpeg reports the full start code. nil for the reserved coding
    /// modes, whose carriage is undefined.
    private static func audioSubstreamBase(format: Int) -> Int? {
        switch format & 0x7 {
        case 0: return 0x80         // AC-3
        case 2, 3: return 0x1C0     // MPEG-1 / MPEG-2 extension audio
        case 4: return 0xA0         // LPCM
        case 6: return 0x88         // DTS
        default: return nil
        }
    }

    /// dvd_time_t (4 bytes) -> seconds. BCD hour/minute/second; the frame byte's top 2 bits select the
    /// frame rate (1 = 25 fps, 3 = 30000/1001), its low 6 bits are the BCD frame count.
    private static func dvdTimeSeconds(_ b: [UInt8], _ i: Int) -> Double {
        func bcd(_ x: UInt8) -> Int { Int(x >> 4) * 10 + Int(x & 0x0F) }
        let h = bcd(b[i]); let m = bcd(b[i + 1]); let s = bcd(b[i + 2])
        let frameByte = b[i + 3]
        let fpsCode = (Int(frameByte) & 0xC0) >> 6
        let fps: Double = fpsCode == 1 ? 25.0 : (fpsCode == 3 ? 30000.0 / 1001.0 : 0)
        let frames = bcd(frameByte & 0x3F)
        return Double(h * 3600 + m * 60 + s) + (fps > 0 ? Double(frames) / fps : 0)
    }
    private static func dvdTimeTicks(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64((dvdTimeSeconds(b, i) * discTickRate).rounded())
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 8) | Int(b[i+1]) }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
    }
}
