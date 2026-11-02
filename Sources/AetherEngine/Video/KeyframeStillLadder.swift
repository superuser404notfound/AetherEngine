// Sources/AetherEngine/Video/KeyframeStillLadder.swift
import Foundation

/// Sparse scrub stills for the parts of a VOD title nothing resident covers (StreamX, 7.48.0). While
/// the link is idle, one keyframe per rung is read off the source, on the same per-origin request
/// budget the pump uses. A one-request origin gets no ladder (AE#937). A scrub miss
/// then answers with the nearest rung instead of nothing.
///
/// Pure: the session owns the reader and the cache, this decides which rung comes next and whether
/// the link may be touched at all.
enum KeyframeStillLadder {
    /// Rung spacing, coarse first: the whole title at one still a minute before any gap is narrowed.
    static let strideSeconds: [Double] = [60, 30]
    /// How far from a rung a scrub target may sit and still be answered by it.
    static let maximumAnswerDistanceSeconds: Double = 60
    /// Disk budget for the rungs. A 30 s ladder over a two-hour 1080p title is about 240 keyframes.
    static let payloadByteLimit = 160 * 1024 * 1024

    /// The plan index of the next rung to read: the unread rung nearest the playhead on the coarsest
    /// stride that still has one. Rungs inside the resident window are skipped, the segment cache
    /// already answers there. nil when the ladder is complete.
    static func nextRung(segmentStarts: [Double], totalSeconds: Double, playheadSeconds: Double,
                         isCached: (Int) -> Bool, isResident: (Int) -> Bool) -> Int? {
        guard !segmentStarts.isEmpty, totalSeconds.isFinite, totalSeconds > 0 else { return nil }
        for stride in strideSeconds {
            var seen = Set<Int>()
            var rungs: [(index: Int, distance: Double)] = []
            var t = 0.0
            while t < totalSeconds {
                if let index = planIndex(atOrBefore: t, in: segmentStarts), seen.insert(index).inserted,
                   !isCached(index), !isResident(index) {
                    rungs.append((index, abs(segmentStarts[index] - playheadSeconds)))
                }
                t += stride
            }
            if let next = rungs.min(by: { $0.distance != $1.distance ? $0.distance < $1.distance : $0.index < $1.index }) {
                return next.index
            }
        }
        return nil
    }

    /// The cached rung that answers a scrub at `seconds`: the nearest one at or before it, else the
    /// nearest after it, within `maximumAnswerDistanceSeconds`.
    static func answeringRung(for seconds: Double, segmentStarts: [Double], cached: [Int]) -> Int? {
        guard seconds.isFinite else { return nil }
        let candidates = cached.filter { segmentStarts.indices.contains($0) }
        let before = candidates.filter { segmentStarts[$0] <= seconds }
            .max { segmentStarts[$0] < segmentStarts[$1] }
        let after = candidates.filter { segmentStarts[$0] > seconds }
            .min { segmentStarts[$0] < segmentStarts[$1] }
        for index in [before, after].compactMap({ $0 })
        where abs(segmentStarts[index] - seconds) <= maximumAnswerDistanceSeconds {
            return index
        }
        return nil
    }

    struct LinkState: Equatable {
        var restartInFlight: Bool
        var seeking: Bool
        /// Contiguous seconds the consumer can play without another fetch.
        var forwardBufferSeconds: Double
        var originInflight: Int
        var originWaiting: Int
        var originPaced: Bool
        /// The origin's limit was declared or learned to be one request (AE#937).
        var originSerial: Bool
        var secondsSinceOriginRefusal: Double?
        var secondsSinceSessionStart: Double
        var secondsSinceLastRung: Double?
    }

    /// Below this the pump may need the link any moment, and a rung read could be the request it waits on.
    static let minimumForwardBufferSeconds: Double = 30
    /// Startup belongs to the pump: the first segments, the probe and AVPlayer's own requests.
    static let startupGraceSeconds: Double = 15
    /// An origin that refused anything recently is metering; the ladder is elective and stays away.
    static let refusalQuietSeconds: Double = 120
    /// At most one rung read per this many seconds, however idle the link looks.
    static let rungSpacingSeconds: Double = 2

    /// True when one rung read may go out now. It requires the origin to have NOTHING in flight and
    /// nobody queued, not merely a free slot, so on an origin whose limit nobody has learned yet the
    /// ladder is never the second concurrent request. A one-request origin is never read at all
    /// (AE#937): the gap between two pump ranges does not hold a side reader's open plus its ranges,
    /// and a panel guarding one slot blocked the client's address over them.
    static func linkIsIdle(_ s: LinkState) -> Bool {
        guard !s.originSerial else { return false }
        guard !s.restartInFlight, !s.seeking else { return false }
        guard s.forwardBufferSeconds >= minimumForwardBufferSeconds else { return false }
        guard s.secondsSinceSessionStart >= startupGraceSeconds else { return false }
        guard s.originInflight == 0, s.originWaiting == 0, !s.originPaced else { return false }
        if let refusal = s.secondsSinceOriginRefusal, refusal < refusalQuietSeconds { return false }
        if let last = s.secondsSinceLastRung, last < rungSpacingSeconds { return false }
        return true
    }

    /// The last segment starting at or before `seconds`.
    static func planIndex(atOrBefore seconds: Double, in starts: [Double]) -> Int? {
        guard let first = starts.first else { return nil }
        if seconds < first { return 0 }
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= seconds { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
