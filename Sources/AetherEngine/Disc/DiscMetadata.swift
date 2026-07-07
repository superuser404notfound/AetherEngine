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

/// A chapter within the selected title. `startSeconds` is the offset from the title's start.
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
    /// DVD: the title-set number whose VOBs back this title.
    let dvdVTSN: Int?
    /// DVD: the title number within its VTS.
    let dvdTitleNumber: Int?

    init(id: Int, durationTicks: UInt64, chapters: [DiscChapter] = [],
         bdClipIDs: [String]? = nil, bdClipSubtractTicks: [Int64]? = nil,
         dvdVTSN: Int? = nil, dvdTitleNumber: Int? = nil) {
        self.id = id
        self.durationTicks = durationTicks
        self.chapters = chapters
        self.bdClipIDs = bdClipIDs
        self.bdClipSubtractTicks = bdClipSubtractTicks
        self.dvdVTSN = dvdVTSN
        self.dvdTitleNumber = dvdTitleNumber
    }
}

/// One clip's span inside a `ConcatIOReader` stream, plus how far to pull its timestamps back so the clip
/// continues contiguously from the previous one. Built once at disc recognition for the SELECTED title and
/// applied per packet by `Demuxer` (attributing packets to clips by their byte position). Empty / all-zero
/// for single-clip titles and non-disc sources, where it is a no-op. See AE#105.
struct ClipSpan: Sendable, Equatable {
    /// Byte offset in the concatenated stream where this clip's bytes begin.
    let concatByteStart: Int64
    /// Seconds to subtract from a raw source timestamp of a packet in this clip (0 for the first clip).
    let subtractSeconds: Double
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

    init(reader: IOReader, formatHint: String, titles: [DiscTitle], selectedTitleIndex: Int,
         clipTimeline: [ClipSpan] = []) {
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
