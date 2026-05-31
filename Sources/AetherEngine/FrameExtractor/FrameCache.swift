import Foundation
import CoreGraphics

/// Size-bounded LRU cache of rendered frames, keyed by
/// `(mode, position bucket)`. The hard per-mode count limit is the
/// leak guard: the cache can never hold more than
/// `thumbnailLimit + snapshotLimit` CGImages.
///
/// Bucketing rounds the requested position down to a grid so that
/// neighbouring scrub requests resolve to the same entry. Thumbnails
/// bucket coarsely (default 1 s); snapshots bucket finely (0.1 s) since
/// they are frame-accurate.
///
/// Not thread-safe on its own. `FrameExtractor` owns the only instance
/// and touches it solely from its actor-isolated context.
final class FrameCache {
    private let thumbnailLimit: Int
    private let snapshotLimit: Int
    private let thumbnailBucketSeconds: Double
    private static let snapshotBucketSeconds: Double = 0.1

    /// Insertion/use order per mode, front = most recently used. Holds
    /// the bucket keys; `store` holds the payloads.
    private var thumbnailOrder: [Int] = []
    private var snapshotOrder: [Int] = []
    private var thumbnailStore: [Int: CGImage] = [:]
    private var snapshotStore: [Int: CGImage] = [:]

    init(thumbnailLimit: Int, snapshotLimit: Int, thumbnailBucketSeconds: Double) {
        self.thumbnailLimit = thumbnailLimit
        self.snapshotLimit = snapshotLimit
        self.thumbnailBucketSeconds = thumbnailBucketSeconds
    }

    private func bucket(_ seconds: Double, mode: FrameMode) -> Int {
        let grid = mode == .thumbnail ? thumbnailBucketSeconds : Self.snapshotBucketSeconds
        let scaled = max(0, seconds) / grid
        // Thumbnails floor to the coarse grid boundary.
        // Snapshots round to nearest so that values within half a bucket
        // of a stored position still resolve to the same entry.
        let rounded = mode == .thumbnail ? scaled.rounded(.down) : scaled.rounded()
        return Int(rounded)
    }

    func get(mode: FrameMode, seconds: Double) -> CGImage? {
        let key = bucket(seconds, mode: mode)
        switch mode {
        case .thumbnail:
            guard let img = thumbnailStore[key] else { return nil }
            touch(&thumbnailOrder, key)
            return img
        case .snapshot:
            guard let img = snapshotStore[key] else { return nil }
            touch(&snapshotOrder, key)
            return img
        }
    }

    func set(_ image: CGImage, mode: FrameMode, seconds: Double) {
        let key = bucket(seconds, mode: mode)
        switch mode {
        case .thumbnail:
            thumbnailStore[key] = image
            touch(&thumbnailOrder, key)
            evict(&thumbnailOrder, &thumbnailStore, limit: thumbnailLimit)
        case .snapshot:
            snapshotStore[key] = image
            touch(&snapshotOrder, key)
            evict(&snapshotOrder, &snapshotStore, limit: snapshotLimit)
        }
    }

    func clear() {
        thumbnailOrder.removeAll()
        snapshotOrder.removeAll()
        thumbnailStore.removeAll()
        snapshotStore.removeAll()
    }

    /// Move `key` to the front of the recency list.
    private func touch(_ order: inout [Int], _ key: Int) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.insert(key, at: 0)
    }

    /// Drop least-recently-used entries until `store.count <= limit`.
    private func evict(_ order: inout [Int], _ store: inout [Int: CGImage], limit: Int) {
        while store.count > limit, let lru = order.popLast() {
            store[lru] = nil
        }
    }
}
