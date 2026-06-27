import Foundation

/// The reusable result of recognizing a DVD / Blu-ray disc structure, minus the reader-bound
/// `ConcatIOReader`. A cache hit rebuilds the reader over the caller's fresh `IOReader` from
/// `extents`, so none of the UDF / ISO9660 directory parse or the per-playlist (.mpls) / .IFO reads
/// have to run again.
struct DiscRecognition: Sendable {
    let formatHint: String
    let titles: [DiscTitle]
    let selectedTitleIndex: Int
    let extents: [(offset: Int64, length: Int64)]
}

/// Memoizes `DiscReader.wrap` per source identity + selected title.
///
/// On a remote ISO every demuxer open re-runs disc recognition: the UDF / ISO9660 directory parse
/// plus a read of every `.mpls` (Blu-ray) or `.IFO` (DVD) over HTTP. The main pump does it at load,
/// and the subtitle side demuxer does it again on every track switch (#76), so a single subtitle
/// swap re-opens the "disc tray". Disc content at a URL is immutable within a session, so the parsed
/// title list and clip extents are safe to reuse: a hit skips straight to building the concat reader.
///
/// Thread-safe because the main demuxer and the subtitle side demuxer can open concurrently on
/// different threads. Entries are KB-scale (offset/length pairs + title metadata); a small LRU bounds
/// memory without needing explicit per-session eviction, though `AetherEngine` also clears it when a
/// new URL loads.
enum DiscRecognitionCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: DiscRecognition] = [:]
    nonisolated(unsafe) private static var order: [String] = []   // LRU recency, most-recent last
    private static let capacity = 6

    private static func compositeKey(_ key: String, selectTitleID: Int?) -> String {
        "\(key)#\(selectTitleID ?? -1)"
    }

    static func lookup(key: String, selectTitleID: Int?) -> DiscRecognition? {
        let ck = compositeKey(key, selectTitleID: selectTitleID)
        lock.lock(); defer { lock.unlock() }
        guard let hit = entries[ck] else { return nil }
        if let i = order.firstIndex(of: ck) { order.remove(at: i) }
        order.append(ck)
        return hit
    }

    static func store(key: String, selectTitleID: Int?, _ recognition: DiscRecognition) {
        let ck = compositeKey(key, selectTitleID: selectTitleID)
        lock.lock(); defer { lock.unlock() }
        if entries[ck] == nil, order.count >= capacity, let evict = order.first {
            order.removeFirst()
            entries[evict] = nil
        }
        entries[ck] = recognition
        if let i = order.firstIndex(of: ck) { order.remove(at: i) }
        order.append(ck)
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }
}
