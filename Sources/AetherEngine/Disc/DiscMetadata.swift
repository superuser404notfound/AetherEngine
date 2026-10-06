import Foundation

// MARK: - Public disc title / chapter model (#67)

/// A selectable title on a disc image (a Blu-ray playlist, or a DVD-Video title). Mirrors the
/// `TrackInfo` conventions so a host renders it the same way as an audio/subtitle track.
public struct TitleInfo: Identifiable, Sendable, Equatable {
    /// 0-based ordinal across the disc's titles, sorted longest first (id 0 is the main feature).
    /// This is the selection key passed to `selectTitle(id:)`.
    public let id: Int
    /// A display label the host may re-label, e.g. "Title 1".
    public let name: String
    public let durationSeconds: Double
    public let chapterCount: Int

    public init(id: Int, name: String, durationSeconds: Double, chapterCount: Int) {
        self.id = id
        self.name = name
        self.durationSeconds = durationSeconds
        self.chapterCount = chapterCount
    }
}

/// A chapter of the loaded source. Two publishers use this shape and their time axes differ:
/// `discChapters` are title-relative (0-based, offset from the selected title's start) and are seeked
/// through `selectChapter(id:)`, which adds the backend's content-start base. `mediaChapters` are
/// container (Matroska/MP4) chapters whose `startSeconds` are already content timestamps on the
/// `seek(to:)` axis, so a host passes them straight to `seek(to:)`; `selectChapter(id:)` resolves
/// against `discChapters` only and no-ops for them.
public struct ChapterInfo: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let startSeconds: Double
    public let durationSeconds: Double

    public init(id: Int, name: String, startSeconds: Double, durationSeconds: Double) {
        self.id = id
        self.name = name
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Internal disc-layer model

/// Disc-layer title: keeps the binary/extent resolution detail the public `TitleInfo` hides.
/// Durations are in the 45 kHz tick base (Blu-ray MPLS native; DVD PGC time is converted to it).
struct DiscTitle: Sendable, Equatable {
    let id: Int
    let durationTicks: UInt64
    let chapters: [DiscChapter]
    /// Blu-ray: the m2ts clip basenames to concatenate for this title (exactly one of the resolution keys is set).
    let bdClipIDs: [String]?
    /// Blu-ray: per-clip amount to SUBTRACT from a raw source timestamp, 45 kHz ticks, parallel to `bdClipIDs`.
    /// Each m2ts clip carries its own STC, so a multi-clip title's concatenated source jumps at every clip
    /// boundary. Subtracting this per-clip offset folds every clip onto one contiguous presentation timeline
    /// that continues from clip 0 (whose offset is always 0, so the plan/anchor/seeks stay untouched). See
    /// `Demuxer.readPacket` normalization and AE#105.
    let bdClipSubtractTicks: [Int64]?
    /// Blu-ray: per-clip presentation offset (sum of earlier clips' OUT-IN durations), 45 kHz ticks,
    /// parallel to `bdClipIDs`. Small and wrap-free, so the demuxer folds each clip using its observed raw
    /// STC base plus this, instead of the wrap-prone `inTime` in `bdClipSubtractTicks`. See AE#105.
    let bdClipCumulativeBeforeTicks: [UInt64]?
    /// DVD: the title-set number whose VOBs back this title.
    let dvdVTSN: Int?
    /// DVD: the title number within its VTS.
    let dvdTitleNumber: Int?
    /// ISO 639 language codes the disc's own navigation data declares for this title's elementary
    /// streams, keyed by the `AVStream.id` FFmpeg gives them: the MPEG-TS PID on Blu-ray (from the
    /// MPLS STN table) and the MPEG-PS stream / substream id on DVD (from the VTS IFO attribute
    /// tables). Neither disc format puts the language in the stream itself, so a demuxed title reports
    /// every track as undetermined without this; `Demuxer.trackInfo` backfills from it. Empty when the
    /// disc declares none (#527).
    let streamLanguages: [Int: String]
    /// DVD: every subpicture substream id (`0x20` + number) the VTS IFO declares for this title,
    /// language or not, ascending. `Demuxer` creates these streams before the probe, so a subtitle
    /// whose first packet comes late is a track from the start rather than whenever the probe
    /// happens to reach it (#651). Empty when the IFO declares none, nil when it is unreadable: only a
    /// title whose IFO was read gets the short probe, since only then is nothing left to discover.
    let dvdSubpictureStreamIDs: [Int]?
    /// [MovieClaw P7] 每个 PlayItem 的 in_time（45 kHz，剪辑 STC 上的原始值），与 `bdClipIDs` 平行；
    /// 按 CLPI 的 EP map 定位时用它把标题时间换回剪辑内的原始 PTS
    let bdClipInTimes: [UInt64]?

    init(id: Int, durationTicks: UInt64, chapters: [DiscChapter] = [],
         bdClipIDs: [String]? = nil, bdClipSubtractTicks: [Int64]? = nil,
         bdClipCumulativeBeforeTicks: [UInt64]? = nil,
         dvdVTSN: Int? = nil, dvdTitleNumber: Int? = nil,
         streamLanguages: [Int: String] = [:],
         dvdSubpictureStreamIDs: [Int]? = nil,
         bdClipInTimes: [UInt64]? = nil) {
        self.bdClipInTimes = bdClipInTimes
        self.id = id
        self.durationTicks = durationTicks
        self.chapters = chapters
        self.bdClipIDs = bdClipIDs
        self.bdClipSubtractTicks = bdClipSubtractTicks
        self.bdClipCumulativeBeforeTicks = bdClipCumulativeBeforeTicks
        self.dvdVTSN = dvdVTSN
        self.dvdTitleNumber = dvdTitleNumber
        self.streamLanguages = streamLanguages
        self.dvdSubpictureStreamIDs = dvdSubpictureStreamIDs
    }
}

/// One clip's span inside a `ConcatIOReader` stream, plus how far to pull its timestamps back so the clip
/// continues contiguously from the previous one. Built once at disc recognition for the SELECTED title and
/// applied per packet by `Demuxer` (attributing packets to clips by their byte position). Empty / all-zero
/// for single-clip titles and non-disc sources, where it is a no-op. See AE#105.
struct ClipSpan: Sendable, Equatable {
    /// Byte offset in the concatenated stream where this clip's bytes begin.
    let concatByteStart: Int64
    /// MPLS presentation offset of this clip's start (seconds, title-relative): a sum of earlier clips'
    /// durations, so small and wrap-free. Combined with the OBSERVED raw STC base of clip 0 and clip k at
    /// read time, it yields the fold offset without trusting the wrap-prone `inTime` fields (AE#105).
    let cumulativeBeforeSec: Double
    /// Old MPLS-predicted fold offset (`inTime[k] - inTime[0] - cumulativeBefore[k]`). `inTime` is a 32-bit
    /// 45 kHz field that wraps at ~95443 s, so this is wrong when a clip's STC base crosses the wrap point.
    /// Kept only as the keyframe-index hint (`normalizedTimestamp`) and as a fallback used before the
    /// observed raw base of a clip has been read.
    let predictedShiftSec: Double
}

extension ClipSpan {
    /// Index of the clip span containing byte position `pos` (the last span whose `concatByteStart` <= pos).
    /// `pos < 0` (a packet / index entry that reported no byte position) returns `fallback` clamped into
    /// range, since reads are sequential and the clip only advances. Empty list returns `fallback`.
    static func index(forPos pos: Int64, in spans: [ClipSpan], fallback: Int) -> Int {
        guard !spans.isEmpty else { return fallback }
        if pos < 0 { return min(max(fallback, 0), spans.count - 1) }
        var lo = 0
        var hi = spans.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if spans[mid].concatByteStart <= pos { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }
}

/// AE#105 fold arithmetic, isolated for testing. A later clip's fold offset pulls its OBSERVED raw STC base
/// back so its content continues right after all earlier clips' presentation duration, anchored to clip 0's
/// observed base. Using the observed (already 33-bit-unwrapped by the demuxer) base instead of the MPLS
/// `inTime` field is what makes it correct when a clip's STC base crosses the 32-bit `inTime` wrap (~95443s).
/// [MovieClaw P13] DVD 标题的时间表：标题时间每隔 unitSec 秒一个 VOBU 在拼接流里的字节起点
/// （第 i 项对应 (i+1)×unitSec 秒，头一个单位时间里的定位落在标题起点）
struct DVDTimeMap: Sendable, Equatable {
    let unitSec: Double
    let titleStartByte: Int64
    let byteOffsets: [Int64]

    /// 标题时间 → 不晚于它的 VOBU 的字节起点
    func byteOffset(forTitleSeconds t: Double) -> Int64 {
        let i = Int((max(0, t) / unitSec).rounded(.down)) - 1
        guard i >= 0, !byteOffsets.isEmpty else { return titleStartByte }
        return byteOffsets[min(i, byteOffsets.count - 1)]
    }
}

enum ClipFold {
    static func offsetSeconds(observedBaseSec: Double, base0Sec: Double, cumulativeBeforeSec: Double) -> Double {
        observedBaseSec - base0Sec - cumulativeBeforeSec
    }
}

/// A fixed-width ISO 639 code read out of disc navigation data, as lowercase ASCII letters. Blu-ray
/// STN tables carry three-byte 639-2 codes and DVD attribute tables two-byte 639-1 ones;
/// `AetherEngine.languageMatches` already treats the two as equivalent, so neither is widened here.
/// Returns nil for padding, an unset field, or the explicit "undetermined" code, none of which say
/// more than the `und` the container already reports (#527).
enum DiscLanguageCode {
    static func parse(_ data: [UInt8], at index: Int, length: Int) -> String? {
        guard index >= 0, length > 0, index + length <= data.count else { return nil }
        var code = ""
        for byte in data[index..<(index + length)] {
            let lower = byte | 0x20
            guard lower >= UInt8(ascii: "a"), lower <= UInt8(ascii: "z") else { return nil }
            code.append(Character(UnicodeScalar(lower)))
        }
        return code == "und" ? nil : code
    }
}

struct DiscChapter: Sendable, Equatable {
    let id: Int
    /// 45 kHz ticks, relative to the title's start.
    let startTicks: UInt64
}

/// What `DiscReader.wrap` returns: the synthetic reader for the SELECTED title, the demuxer format
/// hint, and the full title list so the engine can publish the others for `selectTitle(id:)`.
struct DiscInfo: Sendable {
    let reader: IOReader
    let formatHint: String
    let titles: [DiscTitle]
    let selectedTitleIndex: Int
    /// Per-clip presentation-offset spans for the SELECTED multi-clip Blu-ray title, sorted by
    /// `concatByteStart`. Empty for single-clip / DVD / non-disc sources (Demuxer normalization no-ops).
    let clipTimeline: [ClipSpan]
    /// [MovieClaw P7] 选中蓝光标题的 CLPI 定位表；DVD、读不到 CLPI 时为 nil（定位退回时间二分）
    let seekTable: DiscSeekTable?
    /// [MovieClaw P13] 选中 DVD 标题的时间表（IFO 的 VTS_TMAPT）；蓝光、没有时间表的盘为 nil
    let dvdTimeMap: DVDTimeMap?

    init(reader: IOReader, formatHint: String, titles: [DiscTitle], selectedTitleIndex: Int,
         clipTimeline: [ClipSpan] = [], seekTable: DiscSeekTable? = nil, dvdTimeMap: DVDTimeMap? = nil) {
        self.seekTable = seekTable
        self.dvdTimeMap = dvdTimeMap
        self.reader = reader
        self.formatHint = formatHint
        self.titles = titles
        self.selectedTitleIndex = selectedTitleIndex
        self.clipTimeline = clipTimeline
    }

    var selectedTitle: DiscTitle? {
        titles.indices.contains(selectedTitleIndex) ? titles[selectedTitleIndex] : nil
    }
}

// MARK: - Mapping to the public model

/// 45 kHz is the Blu-ray MPLS / DVD time base used across the disc layer.
let discTickRate: Double = 45000.0

extension DiscTitle {
    func titleInfo() -> TitleInfo {
        TitleInfo(
            id: id,
            name: "Title \(id + 1)",
            durationSeconds: Double(durationTicks) / discTickRate,
            chapterCount: chapters.count
        )
    }
}

extension Array where Element == DiscTitle {
    /// Chapters of the selected title mapped to the public model, with each chapter's duration
    /// computed from the next chapter's start (the last runs to the title end).
    func chapterInfos(selectedIndex: Int) -> [ChapterInfo] {
        guard indices.contains(selectedIndex) else { return [] }
        let title = self[selectedIndex]
        let titleEnd = Double(title.durationTicks) / discTickRate
        return title.chapters.enumerated().map { i, ch in
            let start = Double(ch.startTicks) / discTickRate
            let end = i + 1 < title.chapters.count
                ? Double(title.chapters[i + 1].startTicks) / discTickRate
                : titleEnd
            return ChapterInfo(id: ch.id, name: "Chapter \(ch.id + 1)",
                               startSeconds: start, durationSeconds: Swift.max(0, end - start))
        }
    }
}
