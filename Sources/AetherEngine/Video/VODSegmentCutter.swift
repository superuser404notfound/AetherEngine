import Foundation

/// Decode-order, keyframe-gated VOD segment cutter.
///
/// A new segment opens only when a keyframe whose presentation time reaches the next plan boundary
/// arrives, so the IRAP becomes that segment's first sample and its open-GOP RASL leading pictures
/// (which follow it in decode order) stay with it. This matches how FFmpeg's hls muxer and Apple's
/// tools cut, and makes every segment start on a clean random-access point.
///
/// It replaces routing each packet by its DTS against PTS-valued boundaries: under B-frame reorder a
/// keyframe's DTS is below its PTS, so `dts < boundary[N]` dropped the keyframe into segment N-1 and
/// left segment N starting mid-GOP, decode-dependent on its predecessor (#92). Both open-GOP (CRA +
/// RASL) and closed-GOP-with-B-frames were affected because the reorder delay is constant across the
/// stream. The cut point is the only thing that changes; EXTINF still comes from the plan boundaries.
struct VODSegmentCutter {

    /// Plan boundaries on the ITEM axis, in the timestamps the PLAN is expressed in: `boundaries[i]`
    /// is the start of segment `baseIndex + i`, i.e. the plan's source timestamp minus the plan anchor.
    ///
    /// #358 / AE#561: for a keyframe-aligned plan those timestamps come from the container index, and
    /// the caller feeds the gate the packet timestamp stamped on the SAME axis (`PlanBoundaryAxis`):
    /// decode for a mov/mp4 sample table, presentation for a Matroska Cue. Both mismatches have been
    /// paid for. Presentation against decode boundaries let a keyframe reach boundaries beyond its own
    /// by its composition offset (a couple of frames on an ordinary encode, 3 s on a remux carrying an
    /// edit list), and every boundary inside that offset was consumed without opening a segment while
    /// the playlist kept offering it (#358). Decode against presentation boundaries let no keyframe
    /// reach its own boundary at all, so audio opened every segment and each one began mid-GOP,
    /// carrying no random-access point a cold decode could start on (AE#561).
    /// `boundaries.count` is the segment count + 1 (the last entry is the end of the final segment).
    ///
    /// AE#268: packets reach the cutter with the producer's shift already subtracted, so they are on
    /// the item axis; comparing them against SOURCE-axis boundaries offset every cut by the anchor,
    /// and by the whole gate overshoot after a restart that landed off a random-access point. Both
    /// axes now agree, which also lets a plan whose boundaries ARE the source's IRAPs cut on them
    /// (against source boundaries such a keyframe never reaches its own boundary, so the cutter would
    /// never advance).
    let boundaries: [Int64]
    let baseIndex: Int
    /// How far before each boundary (same local indices as `boundaries`, missing entries 0) the
    /// keyframe that boundary names may arrive. A #409 repair that synthesizes the decode ladder
    /// places a late-written IDR back on its sequence, before the index entry the plan was built from
    /// (`Demuxer.indexedKeyframeAdvanceTicks`); without the reach that keyframe stays in the previous
    /// segment and the next one opens mid-GOP (25 of 40 segments on the 23 fps reporting asset). The
    /// engine keeps each reach below the distance to the keyframe before, so that one never reaches.
    let reachTicks: [Int64]
    private(set) var current: Int

    init(sourceBoundaries: [Int64], planAnchorPts: Int64, baseIndex: Int, reachTicks: [Int64] = []) {
        self.boundaries = sourceBoundaries.map { $0 &- planAnchorPts }
        self.baseIndex = baseIndex
        self.reachTicks = reachTicks.map { max(0, $0) }
        self.current = baseIndex
    }

    /// The reach of local boundary `index`.
    func reach(at index: Int) -> Int64 {
        index >= 0 && index < reachTicks.count ? reachTicks[index] : 0
    }

    /// Segment index for a video packet, in decode order, from its ITEM-axis presentation time.
    /// Advances on a keyframe that has reached the next boundary; every other packet (and an
    /// intra-segment keyframe that has not yet reached the next boundary, e.g. when the GOP is shorter
    /// than the segment) stays in the current segment.
    mutating func index(pts: Int64, isKeyframe: Bool) -> Int {
        guard isKeyframe, pts != Int64.min else { return current }
        // boundaries[count-1] is the end of the final segment, not a segment start, so the last segment
        // a keyframe can open is local (count-2): advance only while the next entry is a real start.
        var nextLocal = (current - baseIndex) + 1
        while nextLocal < boundaries.count - 1,
              SourceTimestampBounds.sum(pts, reach(at: nextLocal)) >= boundaries[nextLocal] {
            current += 1
            nextLocal += 1
        }
        return current
    }

    /// What `index` would return, without advancing.
    func peekIndex(pts: Int64, isKeyframe: Bool) -> Int {
        var copy = self
        return copy.index(pts: pts, isKeyframe: isKeyframe)
    }
}
