import Foundation

/// Qualified compressed-packet presentation coverage matching the renderer's successor-PTS
/// duration.
///
/// AVPacket.duration may describe decode cadence rather than how long a variable-rate picture is
/// displayed. The renderer holds a picture until its presentation-order successor (positive gaps
/// up to one second). This model publishes only those successor intervals, without rewriting any
/// packet timestamp or duration. A larger gap remains a discontinuity, not a tolerance to bridge.
///
/// H.264/HEVC/VC-1 caller contract: complete selected-stream packets, with valid presentation timestamps,
/// enter in demux/decode order after they are retained in the packet store. FFmpeg n8.1.2 h264_ps.c
/// rejects num_reorder_frames > 16 and hevc/ps.c rejects sps_max_num_reorder_pics > 15; the default
/// holds 32 distinct timestamps as a conservative field-picture margin. VC-1's max_b_frames is
/// either read from three bits or set to 7, also within that queue. That codec picture bound
/// does NOT prove arbitrary container PTS obey the bound. A timestamp behind the emitted watermark
/// therefore invalidates all coverage until reset.
/// Sources: https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavcodec/h264_ps.c#L174-L180
/// https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavcodec/hevc/ps.c#L1397-L1403
/// https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavcodec/vc1.c#L346
/// https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavcodec/vc1.c#L426
/// WMV1/2 use depth 1: msmpeg4dec.c rejects pictures other than I/P for WMV1 and wmv2dec.c
/// reads a one-bit I/P type. WMV3 is distinct and remains unqualified. Complete packets and valid
/// PTS are still required; missing or late timestamps invalidate coverage for these codecs too.
///
/// This metadata-only value neither owns packets nor synchronizes access. The owner must reset it
/// together with its packet store on seek/flush/discard. Other codecs must keep their strict packet
/// duration coverage unless their presentation reordering has a separately established bound.
struct SoftwareVideoPacketCoverage: Sendable {
    private var coverage: SoftwarePacketCoverage
    private var pending: [Int64] = []
    private var emittedPTS: Int64?
    private let timeBaseNumerator: Int32
    private let timeBaseDenominator: Int32
    private let validConfiguration: Bool
    let reorderDepth: Int

    private(set) var isInvalidated: Bool
    private(set) var lateTimestampCount = 0
    private(set) var isFinished = false

    init(timeBaseNumerator: Int32, timeBaseDenominator: Int32, reorderDepth: Int = 32,
         maximumRangeCount: Int = 4096) {
        coverage = SoftwarePacketCoverage(maximumRangeCount: maximumRangeCount)
        self.timeBaseNumerator = timeBaseNumerator
        self.timeBaseDenominator = timeBaseDenominator
        self.reorderDepth = min(32, max(1, reorderDepth))
        validConfiguration = timeBaseNumerator > 0 && timeBaseDenominator > 0
            && (1...32).contains(reorderDepth)
        isInvalidated = !validConfiguration
    }

    var pendingCount: Int { pending.count }
    var rangeCount: Int { coverage.rangeCount }
    var isFull: Bool { coverage.isFull }

    var rangesSeconds: [ClosedRange<Double>] {
        guard !isInvalidated else { return [] }
        return coverage.rangesSeconds(timeBaseNumerator: timeBaseNumerator,
                                      timeBaseDenominator: timeBaseDenominator)
    }

    /// Duration/DTS are deliberately not inputs. Duplicate pending PTS do not advance the reorder
    /// watermark. At most depth + 1 timestamps are held transiently, then the minimum is emitted.
    @discardableResult
    mutating func insert(pts: Int64) -> Bool {
        guard !isInvalidated, !isFinished else { return false }
        guard pts != Int64.min else { invalidate(); return false }
        if let emittedPTS {
            if pts < emittedPTS {
                lateTimestampCount += 1
                invalidate()
                return false
            }
            if pts == emittedPTS { return true }
        }

        var lower = 0
        var upper = pending.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pending[middle] < pts { lower = middle + 1 } else { upper = middle }
        }
        if lower < pending.count, pending[lower] == pts { return true }
        pending.insert(pts, at: lower)
        if pending.count > reorderDepth { return emit(pending.removeFirst()) }
        return true
    }

    /// Call only after the complete selected-stream input reaches EOF. The final picture has no
    /// verified successor: its end remains unknown, regardless of packet duration or movie length.
    mutating func finish() {
        guard !isInvalidated, !isFinished else { return }
        while !pending.isEmpty {
            if !emit(pending.removeFirst()) { break }
        }
        isFinished = true
    }

    func frontier(containing tick: Int64) -> Int64? {
        guard !isInvalidated else { return nil }
        return coverage.frontier(containing: tick)
    }

    func frontierSeconds(
        containing seconds: Double,
        timeBaseNumerator: Int32,
        timeBaseDenominator: Int32
    ) -> Double? {
        guard !isInvalidated, timeBaseNumerator == self.timeBaseNumerator,
              timeBaseDenominator == self.timeBaseDenominator else { return nil }
        return coverage.frontierSeconds(containing: seconds, timeBaseNumerator: timeBaseNumerator,
                                        timeBaseDenominator: timeBaseDenominator)
    }

    mutating func prune(before tick: Int64) {
        coverage.prune(before: tick)
    }

    mutating func reset() {
        coverage.reset()
        pending.removeAll(keepingCapacity: true)
        emittedPTS = nil
        lateTimestampCount = 0
        isInvalidated = !validConfiguration
        isFinished = false
    }

    private mutating func emit(_ pts: Int64) -> Bool {
        if let previous = emittedPTS {
            let (delta, overflow) = pts.subtractingReportingOverflow(previous)
            guard !overflow, delta > 0 else { invalidate(); return false }
            // Exact rational comparison against the renderer's one-second policy. Division before
            // comparison avoids overflowing delta * numerator, and never rounds a long gap down.
            let maximumHoldTicks = Int64(timeBaseDenominator) / Int64(timeBaseNumerator)
            if delta <= maximumHoldTicks, !coverage.insert(pts: previous, duration: delta) {
                invalidate()
                return false
            }
        }
        emittedPTS = pts
        return true
    }

    private mutating func invalidate() {
        isInvalidated = true
        coverage.reset()
        pending.removeAll(keepingCapacity: true)
        emittedPTS = nil
    }
}
