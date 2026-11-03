import Foundation

/// Where a seek lands on the software host when dav1d decodes AV1: on the keyframe nearest its
/// target instead of exactly on it.
///
/// A seek decodes from the keyframe at or before its target up to the target, and AV1 encodes run
/// long GOPs (6.7 s from SvtAv1EncApp's default keyint at 23.976 fps). On an Apple TV 4K (3rd
/// generation, A15), +30 s seeks into a 4K AV1 encode (CRF 22, 19 Mbit/s in that passage) held the
/// clock 2.5 to 4.6 s while dav1d caught up, and 0.13 to 0.54 s landed on the keyframe (with the
/// packet cache's `anchorsOnLastKeyframe`; 10 seeks each way, same build).
///
/// A Matroska cue that is not a sync point (CLAUDE.md) costs the snap nothing the exact seek does
/// not already pay: both reposition onto an entry of the same index.
enum SWKeyframeSnap {
    /// Process switch for comparisons (`AetherEngine.snapsAV1SeeksToKeyframes`). Read when a session
    /// opens its decoder.
    nonisolated(unsafe) static var enabled = true

    /// The furthest a seek moves to land on a keyframe: past half of the GOPs this is for, short enough
    /// that an index with entries further apart than the stream's keyframes never moves a seek by more.
    static let reachSeconds: Double = 10

    /// The keyframe nearest `target` (source seconds) among `keyframes` (sorted ascending), or nil to
    /// keep the seek exact: no keyframe at or after the target, no keyframe within `reach` or within
    /// half the seek's own distance, or the nearest one on the other side of `current`, since a
    /// forward seek never lands behind the playhead and a backward one never ahead of it. The half
    /// distance keeps a short skip a skip: with keyframes at 6.7 s and 30 s, +10 s from 6.6 s would
    /// otherwise land on 6.7 s.
    ///
    /// The first condition is for keyframes that have not reached the target yet: Matroska reads its
    /// Cues only when the demuxer repositions, so until then the index holds only the keyframes read
    /// so far, and its last entry says nothing about the keyframes after it (measured before this
    /// held: a seek to 70 s from 11 s landed on 13.4 s).
    static func snappedSeconds(target: Double, current: Double, keyframes: [Double],
                               reach: Double = reachSeconds) -> Double? {
        guard target.isFinite, current.isFinite, !keyframes.isEmpty else { return nil }
        let reach = min(reach, abs(target - current) / 2)
        var lo = 0, hi = keyframes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keyframes[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        guard lo < keyframes.count else { return nil }
        guard let nearest = [lo - 1, lo].filter(keyframes.indices.contains).map({ keyframes[$0] })
            .min(by: { abs($0 - target) < abs($1 - target) }),
              abs(nearest - target) <= reach else { return nil }
        guard target > current ? nearest > current : nearest < current else { return nil }
        return nearest
    }

    /// The keyframes a seek can snap to: the packet cache's retained ones, current as the read-ahead
    /// moves (a seek it serves never repositions the demuxer, so Matroska's Cues stay unread), and the
    /// index as last read, which past the cache covers what Cues or an `stss` hold. Ascending, with
    /// one entry per keyframe the two lists share, and that entry the cache's own value: the two
    /// convert ticks to seconds in a different order and can differ in the last bit (an MP4 at 1/24000
    /// does for about one keyframe in five), and a cache hit compares its keyframes against the target
    /// exactly, so an index value a bit below the cache's would restore to the keyframe before it.
    static func candidates(retained: [Double], indexed: [Double]) -> [Double] {
        var merged: [(seconds: Double, retained: Bool)] = []
        merged.reserveCapacity(retained.count + indexed.count)
        let tagged = retained.map { (seconds: $0, retained: true) } + indexed.map { (seconds: $0, retained: false) }
        for entry in tagged.sorted(by: { $0.seconds < $1.seconds }) where entry.seconds.isFinite {
            if let last = merged.last, entry.seconds - last.seconds < 0.001 {
                if entry.retained, !last.retained { merged[merged.count - 1] = entry }
                continue
            }
            merged.append(entry)
        }
        return merged.map(\.seconds)
    }
}

extension AetherEngine {
    /// True (the default) lands a seek on the software host's AV1 through dav1d on the keyframe
    /// nearest its target unless the host asked for `seek(to:exact: true)`; false keeps every seek
    /// exact, for comparisons. Read when a
    /// session opens its decoder, so it takes effect on the next load or reload.
    @_spi(Diagnostics)
    public nonisolated static var snapsAV1SeeksToKeyframes: Bool {
        get { SWKeyframeSnap.enabled }
        set { SWKeyframeSnap.enabled = newValue }
    }
}
