import Foundation
import AetherLibavutil

/// Sodalite#236: a declared frame rate that is not a broadcast rate, checked against the packets.
///
/// libavformat takes a Matroska track's rate from its DefaultDuration. mkvmerge writes the first
/// frame's duration there, and on film stamped with 2:3 pulldown timing (50 and 33 ms frames) that
/// is 50 ms: the track declares 20 fps while it runs at 23.976. The engine then asked the panel for
/// 24 Hz, advertised FRAME-RATE=20.000, and built no frame grid. A declared rate that IS a standard
/// rate is trusted as before; only an odd one is measured, so ordinary sources read no packet.
enum SourceFrameRateMeasurement {
    /// Frames a measurement needs before it says anything.
    static let minimumFrames = 48
    /// Video frames worth reading: five seconds of film, enough for the fitted slope to tell 24 from
    /// 23.976 (0.1% apart) through millisecond rounding and the 2:3 alternation.
    static let targetFrames = 120
    /// Packets of all streams a load may hold back to find them, and the bytes they may hold: the
    /// packets stay queued for playback, so a high-bitrate source stops early rather than buffering.
    static let packetBudget = 600
    static let byteBudget = 24 << 20
    /// How close a measured rate has to come to a standard one to be taken for it.
    static let matchTolerance = 0.005

    /// True when `rate` is one of `CFRFrameGrid.standardRates` within its tolerance.
    static func isStandard(_ rate: AVRational) -> Bool {
        standardRate(near: rate.num > 0 && rate.den > 0 ? Double(rate.num) / Double(rate.den) : 0,
                     tolerance: CFRFrameGrid.rateTolerance) != nil
    }

    /// The standard rate the packets run at, or nil when the declared rate stands: it is already
    /// standard, there are too few timestamps, or they match no standard rate.
    ///
    /// The rate is the slope of a least-squares line through the sorted timestamps against their
    /// rank, so the 2:3 alternation (8 ms either side of the line) and millisecond rounding average
    /// out instead of deciding the answer through two endpoints.
    static func measuredRate(declared: AVRational, videoPts: [Int64], timeBase: AVRational) -> AVRational? {
        guard !isStandard(declared), timeBase.num > 0, timeBase.den > 0 else { return nil }
        let sorted = videoPts.filter { $0 != Int64.min }.sorted()
        guard sorted.count >= minimumFrames else { return nil }
        let seconds = sorted.map { Double($0 - sorted[0]) * Double(timeBase.num) / Double(timeBase.den) }
        let n = Double(seconds.count)
        let meanRank = (n - 1) / 2
        let meanTime = seconds.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for (rank, time) in seconds.enumerated() {
            let r = Double(rank) - meanRank
            covariance += r * (time - meanTime)
            variance += r * r
        }
        guard variance > 0, covariance > 0 else { return nil }
        return standardRate(near: variance / covariance, tolerance: matchTolerance)
    }

    /// Reads the head video timestamps without consuming them (`Demuxer.peekPackets`: playback gets
    /// the same packets next) and measures them. Blocking; call off the main actor.
    static func measure(demuxer: Demuxer, videoStreamIndex: Int32, declared: AVRational,
                        timeBase: AVRational) -> AVRational? {
        var pts: [Int64] = []
        var bytes = 0
        try? demuxer.peekPackets(maxPackets: packetBudget) { packet in
            bytes += Int(packet.pointee.size)
            if packet.pointee.stream_index == videoStreamIndex { pts.append(packet.pointee.pts) }
            return pts.count >= targetFrames || bytes >= byteBudget
        }
        return measuredRate(declared: declared, videoPts: pts, timeBase: timeBase)
    }

    private static func standardRate(near measured: Double, tolerance: Double) -> AVRational? {
        guard measured > 0 else { return nil }
        return CFRFrameGrid.standardRates
            .map { (rate: $0, error: abs(measured - Double($0.num) / Double($0.den)) / (Double($0.num) / Double($0.den))) }
            .filter { $0.error <= tolerance }
            .min { $0.error < $1.error }?
            .rate
    }
}
