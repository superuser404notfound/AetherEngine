import Foundation

/// Reorders A53 caption pair groups from decode order (video-packet/SEI order) into presentation
/// order (#131). The CEA-608 decoder is stateful and order-sensitive; on B-frame content, feeding
/// SEI in packet order garbles roll-up text.
///
/// Drain rule: for any packet j after i in decode order, `dts_j > dts_i` and `pts_j >= dts_j`, so
/// once a packet with DTS d has been seen, no packet with PTS <= d can still arrive; every pending
/// group at or below the DTS watermark is safe to emit. Streams without B-frames (pts == dts) drain
/// with zero latency. A backward DTS jump means the producer re-anchored (live reopen / restart);
/// pending groups belong to the abandoned region and are discarded. Not thread-safe; the owning
/// `ClosedCaptionTap` calls it under its lock.
struct A53ReorderBuffer {

    struct Pair: Equatable {
        let d0: UInt8
        let d1: UInt8
    }

    struct Group: Equatable {
        let pts: Double
        let pairs: [Pair]
    }

    /// A cap trip means broken DTS monotonicity upstream (or a DTS-less stream), not normal
    /// operation; the reorder depth of real B-frame content is a handful of frames.
    static let capacity = 512

    private var pending: [Group] = []   // sorted by pts ascending
    private var maxDTS = -Double.infinity
    /// Latched on first overflow so the tap can log once.
    private(set) var overflowed = false

    /// Insert one packet's caption pairs; returns every group now safe to feed, in presentation order.
    mutating func insert(pts: Double, pairs: [Pair], dts: Double?) -> [Group] {
        if let dts, dts < maxDTS - 1.0 {
            pending.removeAll(keepingCapacity: true)
            maxDTS = -.infinity
        }
        var lo = 0, hi = pending.count
        while lo < hi { let m = (lo + hi) / 2; if pending[m].pts < pts { lo = m + 1 } else { hi = m } }
        pending.insert(Group(pts: pts, pairs: pairs), at: lo)
        if let dts { maxDTS = max(maxDTS, dts) }
        var ready: [Group] = []
        while let first = pending.first, first.pts <= maxDTS {
            ready.append(pending.removeFirst())
        }
        if pending.count > Self.capacity {
            pending.removeFirst()
            overflowed = true
        }
        return ready
    }

    /// Drop all pending groups and the watermark. Called on a seek discontinuity.
    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        maxDTS = -.infinity
    }
}
