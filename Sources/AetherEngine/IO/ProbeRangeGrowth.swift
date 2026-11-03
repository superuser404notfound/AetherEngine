import Foundation

/// AE#927: range sizing for a controlled probe's seekable reads. A fixed 64 KiB range made a
/// 50 MiB stream analysis cost ~800 serial round trips, which a 100 ms origin turned into a timeout.
///
/// A range that continues the previous one in full doubles it, up to `ceiling`; a seek or a short
/// body starts over at `floor`. A range is never longer than the input the probe may still consume,
/// since bytes past that can never be delivered, but `floor` stays the minimum, so a small allowance
/// asks for what it always did. Doubling also bounds what a probe can fetch and not use by what it
/// has already read in that run.
struct ProbeRangeGrowth: Sendable {
    let floor: Int
    let ceiling: Int
    private var nextOffset: Int64 = -1
    private var nextSize: Int

    init(floor: Int, ceiling: Int) {
        self.floor = max(1, floor)
        self.ceiling = max(self.floor, ceiling)
        nextSize = self.floor
    }

    func size(at offset: Int64, remainingInput: Int64?) -> Int {
        var size = offset == nextOffset ? nextSize : floor
        if let remainingInput { size = Int(min(Int64(size), max(Int64(floor), remainingInput))) }
        return size
    }

    mutating func record(offset: Int64, requested: Int, received: Int) {
        nextOffset = offset + Int64(received)
        nextSize = received >= requested ? min(ceiling, requested * 2) : floor
    }

    /// A grown range keeps the throughput floor the 64 KiB range had under the same budget, rather
    /// than the same wall clock. Stalls stay bounded by the request's idle timeout.
    func budget(for size: Int, base: TimeInterval) -> TimeInterval {
        base * max(1, Double(size) / Double(floor))
    }
}
