import Foundation

enum BDTitleSelector {
    /// Playlists shorter than this are dropped from the title list: discs pad PLAYLIST with FBI
    /// warnings, menu loops, and (on anti-rip discs) hundreds of decoy playlists. If filtering would
    /// leave nothing, the unfiltered set is used so a disc never ends up with zero titles.
    static let minTitleSeconds: Double = 10

    /// A single clip repeated at least this many times, and supplying most of a playlist's PlayItems,
    /// marks that playlist as a repeated-clip decoy (see `isRepeatedClipDecoy`).
    static let decoyMinRepeats = 3

    /// Anti-rip Blu-rays pad PLAYLIST with decoy .mpls that reference one short clip dozens or hundreds
    /// of times, inflating the declared duration to 5+ hours while the demuxer only ever probes the
    /// first clip's worth of PTS. A decoy is dominated by one repeated clip; a real feature lists
    /// distinct clips (one, or a handful for seamless branching / multi-angle). Flag a playlist as a
    /// decoy only when a single clip both repeats past the floor and supplies more than half its
    /// PlayItems, so light legitimate clip reuse is preserved. (AE#105: TRON: Legacy 4K crowned a clip
    /// looped 252x over its 2:05 feature under duration-max selection, so scrubs past 76s came back blank.)
    static func isRepeatedClipDecoy(_ playlist: MPLSPlaylist) -> Bool {
        let clips = playlist.clipIDs
        guard clips.count > 1 else { return false }
        var counts: [String: Int] = [:]
        for c in clips { counts[c, default: 0] += 1 }
        guard let maxRepeat = counts.values.max() else { return false }
        return maxRepeat >= decoyMinRepeats && maxRepeat * 2 > clips.count
    }

    static func selectMainTitle(_ playlists: [MPLSPlaylist]) -> MPLSPlaylist? {
        let real = playlists.filter { !isRepeatedClipDecoy($0) }
        let pool = real.isEmpty ? playlists : real
        return pool.max { $0.durationTicks < $1.durationTicks }
    }

    /// All playlists as selectable titles, longest first so id 0 is the main feature (preserving the
    /// "default plays the main title" behavior). Trivially-short playlists and repeated-clip decoys are
    /// filtered (see above); if filtering would leave nothing, the unfiltered set is used.
    static func enumerateTitles(_ playlists: [MPLSPlaylist]) -> [DiscTitle] {
        let minTicks = UInt64(minTitleSeconds * discTickRate)
        let real = playlists.filter { $0.durationTicks >= minTicks && !isRepeatedClipDecoy($0) }
        let pool = real.isEmpty ? playlists : real
        return pool.sorted { $0.durationTicks > $1.durationTicks }
            .enumerated()
            .map { index, playlist in
                let chapters = playlist.chapterStartTicks.enumerated().map { i, start in
                    DiscChapter(id: i, startTicks: start)
                }
                return DiscTitle(id: index, durationTicks: playlist.durationTicks,
                                 chapters: chapters, bdClipIDs: playlist.clipIDs,
                                 bdClipSubtractTicks: clipSubtractTicks(playlist))
            }
    }

    /// Per-clip amount to subtract from a raw source timestamp (45 kHz ticks) so each PlayItem continues
    /// contiguously from the previous one on the title's presentation timeline, with clip 0 left untouched
    /// (offset 0). For clip k: `inTime[k] - inTime[0] - cumulativeBefore[k]`. Derivation: clip k's presented
    /// content must land at `inTime[0] + cumulativeBefore[k] + (raw - inTime[k])`, so the constant to remove
    /// from `raw` is `inTime[k] - inTime[0] - cumulativeBefore[k]`. Nil when the playlist carried no per-clip
    /// timing (older parse / malformed), leaving normalization disabled. See AE#105.
    static func clipSubtractTicks(_ playlist: MPLSPlaylist) -> [Int64]? {
        let inT = playlist.inTimes
        let cumB = playlist.cumulativeBefore
        guard inT.count == playlist.clipIDs.count, cumB.count == playlist.clipIDs.count,
              let first = inT.first else { return nil }
        return inT.indices.map { k in
            Int64(bitPattern: inT[k]) - Int64(bitPattern: first) - Int64(bitPattern: cumB[k])
        }
    }
}
