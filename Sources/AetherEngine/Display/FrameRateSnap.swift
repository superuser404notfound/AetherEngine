import Foundation

/// Snap a raw frame rate from the demuxer (libavformat
/// `avg_frame_rate` / `r_frame_rate`) to the nearest standard rate
/// supported by tvOS' Match Frame Rate. Real-world sources rarely
/// probe at exact rates (a 23.976 fps film commonly probes at
/// 23.97-23.98 depending on container rounding), so a tolerance
/// is necessary.
///
/// Returns `nil` for zero or out-of-range rates, in which case the
/// caller should program the display criteria without a refresh-rate
/// hint and let the panel keep its current rate.
enum FrameRateSnap {
    /// Standard rates Apple TV's HDMI handshake will switch to.
    /// Source: AVDisplayManager documentation + empirical testing on
    /// LG / Sony / Philips panels. Anything outside this set is either
    /// VFR / weird capture rates or a probe failure.
    static let standard: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60]

    /// Snap `raw` to the nearest member of `standard` within ±0.5 fps,
    /// or `nil` if it falls outside that tolerance from every standard
    /// rate. Special case: 23.976 wins the [23.5, 24.05] window over
    /// 24.0 because film-cadence sources commonly probe to 23.976 and
    /// 23.976 ↔ 24 matters for 3:2 pulldown / judder visibility.
    static func snap(_ raw: Double) -> Double? {
        guard raw > 0, raw.isFinite else { return nil }

        // Film-cadence shortcut. 24.000-fps probes land here too;
        // sending 23.976 to the panel for them is the conservative
        // choice (panels that support 24 also support 23.976; the
        // reverse isn't guaranteed).
        if raw >= 23.5 && raw <= 24.05 {
            return 23.976
        }

        var best: (rate: Double, delta: Double)?
        for candidate in standard where candidate != 23.976 {
            let delta = abs(candidate - raw)
            if delta <= 0.5 {
                if let current = best {
                    if delta < current.delta { best = (candidate, delta) }
                } else {
                    best = (candidate, delta)
                }
            }
        }
        return best?.rate
    }
}
