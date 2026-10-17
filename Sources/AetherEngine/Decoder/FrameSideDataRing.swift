// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation

/// Fixed-capacity ring buffer for Dolby Vision per-frame side data (dolby-vision-fel.md §5.3).
///
/// Stores `{ params, dmNAL }` keyed by canonical PTS.
/// Fixed capacity of 32 entries (reorder depth plus maximum layer skew with margin).
/// Insert overwrites the oldest entry when full.
/// Lookup scans up to 32 entries for the nearest key within ±300 ticks (~3.3 ms).
/// No heap reallocation on insert, no sorting, no dictionary overhead.
struct FrameSideDataRing: Sendable {
    static let capacity = 32
    static let jitterToleranceTicks: Int64 = 300

    /// Distance between two canonical keys, or nil when either is the missing-PTS key (`Int64.min`) or the
    /// distance does not fit. A frame without a timestamp has no neighbour, so nothing matches it; and
    /// the trapping `abs` of a plain subtraction overflows on exactly that key.
    static func distance(_ a: Int64, _ b: Int64) -> UInt64? {
        guard a != Int64.min, b != Int64.min else { return nil }
        let (d, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? nil : d.magnitude
    }

    /// True when both keys carry a timestamp and are within the pairing jitter of each other.
    static func isWithinJitter(_ a: Int64, _ b: Int64) -> Bool {
        guard let d = distance(a, b) else { return false }
        return d <= UInt64(jitterToleranceTicks)
    }

    struct Entry: Sendable {
        var key: Int64
        var params: DoviMetalParams?
        var dmNAL: [UInt8]?

        init(key: Int64, params: DoviMetalParams? = nil, dmNAL: [UInt8]? = nil) {
            self.key = key
            self.params = params
            self.dmNAL = dmNAL
        }
    }

    private var buffer: [Entry?]
    private var writeIndex: Int = 0
    private var entryCount: Int = 0

    init() {
        self.buffer = Array(repeating: nil, count: Self.capacity)
    }

    var count: Int { entryCount }
    var isEmpty: Bool { entryCount == 0 }

    var paramsCount: Int {
        var result = 0
        for i in 0..<entryCount {
            let idx = (writeIndex - entryCount + i + Self.capacity) % Self.capacity
            if buffer[idx]?.params != nil { result += 1 }
        }
        return result
    }

    var dmNALCount: Int {
        var result = 0
        for i in 0..<entryCount {
            let idx = (writeIndex - entryCount + i + Self.capacity) % Self.capacity
            if buffer[idx]?.dmNAL != nil { result += 1 }
        }
        return result
    }

    /// Inserts or updates an entry for `key`.
    /// If an entry already exists for this exact key, updates its fields.
    /// Otherwise overwrites the oldest slot in the ring.
    mutating func insert(key: Int64, params: DoviMetalParams? = nil, dmNAL: [UInt8]? = nil) {
        // If an entry exists for the exact key, update in-place without consuming a new slot:
        for i in 0..<entryCount {
            let idx = (writeIndex - entryCount + i + Self.capacity) % Self.capacity
            if let entry = buffer[idx], entry.key == key {
                if let params { buffer[idx]?.params = params }
                if let dmNAL { buffer[idx]?.dmNAL = dmNAL }
                return
            }
        }

        // Otherwise write at writeIndex (overwriting the oldest if at capacity):
        buffer[writeIndex] = Entry(key: key, params: params, dmNAL: dmNAL)
        writeIndex = (writeIndex + 1) % Self.capacity
        if entryCount < Self.capacity {
            entryCount += 1
        }
    }

    /// Finds the entry nearest to `key` within ±300 ticks.
    func findNearestIndex(key: Int64) -> Int? {
        var bestIndex: Int?
        var minDiff = UInt64.max

        for i in 0..<entryCount {
            let idx = (writeIndex - entryCount + i + Self.capacity) % Self.capacity
            guard let entry = buffer[idx] else { continue }
            guard let diff = Self.distance(entry.key, key) else { continue }
            if diff <= UInt64(Self.jitterToleranceTicks) && diff < minDiff {
                minDiff = diff
                bestIndex = idx
                if diff == 0 { break } // Exact match
            }
        }
        return bestIndex
    }

    /// Finds the nearest entry to `key` within ±300 ticks.
    func find(key: Int64) -> Entry? {
        guard let idx = findNearestIndex(key: key) else { return nil }
        return buffer[idx]
    }

    /// Removes and returns `dmNAL` for `key` (or nearest within ±300 ticks).
    mutating func removeDisplayMetadata(key: Int64) -> [UInt8]? {
        var bestIndex: Int?
        var minDiff = UInt64.max

        for i in 0..<entryCount {
            let idx = (writeIndex - entryCount + i + Self.capacity) % Self.capacity
            guard let entry = buffer[idx], entry.dmNAL != nil else { continue }
            guard let diff = Self.distance(entry.key, key) else { continue }
            if diff <= UInt64(Self.jitterToleranceTicks) && diff < minDiff {
                minDiff = diff
                bestIndex = idx
                if diff == 0 { break }
            }
        }

        guard let idx = bestIndex, let nal = buffer[idx]?.dmNAL else { return nil }
        buffer[idx]?.dmNAL = nil
        return nal
    }

    /// Removes and returns `params` for `key` (or nearest within ±300 ticks).
    mutating func removeParams(key: Int64) -> DoviMetalParams? {
        var bestIndex: Int?
        var minDiff = UInt64.max

        for i in 0..<entryCount {
            let idx = (writeIndex - entryCount + i + Self.capacity) % Self.capacity
            guard let entry = buffer[idx], entry.params != nil else { continue }
            guard let diff = Self.distance(entry.key, key) else { continue }
            if diff <= UInt64(Self.jitterToleranceTicks) && diff < minDiff {
                minDiff = diff
                bestIndex = idx
                if diff == 0 { break }
            }
        }

        guard let idx = bestIndex, let p = buffer[idx]?.params else { return nil }
        buffer[idx]?.params = nil
        return p
    }

    /// Removes all entries from the ring.
    mutating func removeAll() {
        buffer = Array(repeating: nil, count: Self.capacity)
        writeIndex = 0
        entryCount = 0
    }
}
#endif
