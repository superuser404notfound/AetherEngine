import Foundation

/// Final-stage timestamp guard sitting immediately in front of the fMP4
/// muxer. It enforces the two invariants `av_interleaved_write_frame`
/// requires, per output stream, regardless of how mangled the upstream
/// timestamps are:
///
///   1. DTS strictly increases (each packet's dts > the last one written
///      on that stream). libavformat rejects a non-increasing dts with
///      "Application provided invalid, non monotonically increasing dts".
///   2. PTS is never below DTS (`pts >= dts`). Audio carries no
///      reordering so its pts must equal its dts; video B-frames keep
///      pts > dts. libavformat rejects `pts < dts`.
///
/// Why a final guard rather than fixing it upstream: server-side ad
/// insertion (Pluto/Samsung-TV+ FAST channels) splices ad creatives that
/// each restart their source clock at 2^33 (the MPEG-TS timestamp
/// modulus) with independently muxed audio. The producer's per-stream
/// shift + source-level monotonic repair cannot keep pts and dts
/// consistent across that, and a single bad audio packet (pts < dts)
/// makes the muxer drop EVERY audio packet of the ad segment, so the
/// segment plays silent and AVPlayer stalls forever. This guard makes
/// the muxer input always valid; for healthy content (monotonic dts,
/// pts >= dts already) every call is a no-op.
///
/// Operates on already-rescaled muxer-time-base values, keyed by output
/// `stream_index`. `AV_NOPTS_VALUE` (Int64.min) inputs are passed through
/// untouched (the producer repairs NOPTS before this stage).
struct OutputTimestampSanitizer {
    /// Last dts written per output stream index (muxer time base).
    private var lastDtsByStream: [Int32: Int64] = [:]

    /// Sanitize one packet's (pts, dts) for `streamIndex`. Returns the
    /// values to write. Records the resulting dts as this stream's new
    /// high-water mark.
    mutating func sanitize(streamIndex: Int32, pts: Int64, dts: Int64) -> (pts: Int64, dts: Int64) {
        // NOPTS dts: nothing to enforce, don't record (a later valid dts
        // sets the baseline). Leave pts as-is.
        guard dts != Int64.min else { return (pts, dts) }

        var outDts = dts
        if let last = lastDtsByStream[streamIndex], outDts <= last {
            outDts = last + 1
        }
        // pts >= dts. A NOPTS pts collapses to the (sanitized) dts, which
        // is correct for audio and a safe floor for video.
        let outPts = pts == Int64.min ? outDts : max(pts, outDts)

        lastDtsByStream[streamIndex] = outDts
        return (outPts, outDts)
    }
}
