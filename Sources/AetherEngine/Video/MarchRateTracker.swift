import Foundation

/// The producer's march rate in segments per second, from segment completions.
/// A run is a sequence of consecutive indices written without a park, so a restart (which cuts from a
/// new anchor) and a backpressure park both start a new run. A parked producer writes at the pace the
/// consumer frees room, which on a fast link is playback speed and not the link: with the default
/// forward window that read about 0.25 segments per second and restarted a producer that would have
/// reached the target in a second. The estimate falls back in order: the active run, the previous run,
/// then the source throughput over the average segment size, cut at parks the same way. nil only when
/// the session has no measurement at all.
struct MarchRateTracker {
    struct Sample: Equatable {
        let index: Int
        let time: Double
        let bytes: Int
        let sourceBytes: Int64?
    }

    enum Source: String { case current, previous, throughput }

    /// Intervals a run needs before its own rate is trusted (three completed segments after the first).
    static let minimumIntervals = 3
    /// Newest intervals a rate is read from. The median, so one stall does not read as a slow link.
    static let rateWindow = 8
    static let throughputWindow = 8

    private(set) var run: [Sample] = []
    private(set) var previousRunRate: Double?
    /// Newest completions across runs since the last park, for the throughput fallback.
    private(set) var recent: [Sample] = []
    /// The throughput of the span before the last park.
    private(set) var previousThroughputRate: Double?

    var lastSample: Sample? { recent.last }

    /// `parkedBefore`: the producer parked on backpressure since the completion before this one, so the
    /// interval up to this one is not a measurement of the link.
    mutating func record(index: Int, time: Double, bytes: Int, sourceBytes: Int64?, parkedBefore: Bool = false) {
        let sample = Sample(index: index, time: time, bytes: bytes, sourceBytes: sourceBytes)
        if let last = run.last, parkedBefore || index != last.index + 1 {
            if let rate = Self.rate(of: run) { previousRunRate = rate }
            run.removeAll(keepingCapacity: true)
        }
        if parkedBefore {
            if let rate = currentThroughputRate() { previousThroughputRate = rate }
            recent.removeAll(keepingCapacity: true)
        }
        run.append(sample)
        if run.count > Self.rateWindow + 1 { run.removeFirst(run.count - Self.rateWindow - 1) }
        recent.append(sample)
        if recent.count > Self.throughputWindow { recent.removeFirst(recent.count - Self.throughputWindow) }
    }

    /// `activeAnchor` is the active producer's restart index: a run that ends below it was cut by the
    /// producer before, which has not been split off yet only because the new one has stored nothing.
    func estimate(activeAnchor: Int) -> (rate: Double, source: Source)? {
        let runIsActive = (run.last?.index ?? Int.min) >= activeAnchor
        if let rate = Self.rate(of: run) { return (rate, runIsActive ? .current : .previous) }
        if let previousRunRate { return (previousRunRate, .previous) }
        if let rate = throughputRate() { return (rate, .throughput) }
        return nil
    }

    /// 1 / median interval over the newest `rateWindow` intervals, or nil below `minimumIntervals`.
    static func rate(of run: [Sample]) -> Double? {
        guard run.count >= minimumIntervals + 1 else { return nil }
        var intervals: [Double] = []
        for i in 1..<run.count { intervals.append(run[i].time - run[i - 1].time) }
        intervals.sort()
        let median = intervals.count % 2 == 1
            ? intervals[intervals.count / 2]
            : (intervals[intervals.count / 2 - 1] + intervals[intervals.count / 2]) / 2
        return median > 0 ? 1 / median : nil
    }

    private func throughputRate() -> Double? {
        currentThroughputRate() ?? previousThroughputRate
    }

    private func currentThroughputRate() -> Double? {
        let measured = recent.filter { $0.sourceBytes != nil }
        guard let first = measured.first, let last = measured.last, last.time > first.time,
              let firstBytes = first.sourceBytes, let lastBytes = last.sourceBytes, lastBytes > firstBytes
        else { return nil }
        let bytesPerSecond = Double(lastBytes - firstBytes) / (last.time - first.time)
        let averageSegment = Double(measured.map(\.bytes).reduce(0, +)) / Double(measured.count)
        // Segments written smaller than read (an audio bridge, TrueHD in, E-AC3 out) overestimate the rate,
        // which leans toward waiting for the march, the stock behaviour, so the error is on the safe side.
        guard averageSegment > 0 else { return nil }
        return bytesPerSecond / averageSegment
    }
}
