import Foundation

/// The software path's PTS-discontinuity fold, per stream. A jump of `thresholdSeconds` or more on a
/// stream's own raw timeline moves that stream's offset by the jump, so everything downstream (decoders,
/// renderers, the DVR ring, the live edge) sees one continuous timeline.
///
/// AE#1053: the fold used to be detected on video packets only and applied to audio in read order. An
/// MPEG-TS splice does not put the two streams' seams at the same byte, so the audio packets read between
/// the video seam and the audio seam landed a whole jump off the clock: on a +347 s spike, the AC-3 read
/// just before the first spiked video packet went to the renderer 347 s ahead and muted the session for
/// good, and the audio that returned before the video did went 347 s into the past. Each stream now finds
/// its own seams. A seam the other stream has already crossed adopts that stream's offset exactly, so a
/// splice that moves both streams keeps them in sync to the tick; a stream whose timestamps jump on their
/// own keeps its own continuity.
struct LiveTimelineFold: Sendable {
    enum Stream: Sendable { case video, audio }

    struct Seam: Equatable, Sendable {
        let stream: Stream
        let previousSeconds: Double
        let rawSeconds: Double
        let offsetSeconds: Double
        /// The offset was taken over from the other stream, which had already crossed this seam.
        let adopted: Bool
        var deltaSeconds: Double { rawSeconds - previousSeconds }
    }

    static let thresholdSeconds = 10.0
    /// How close a seam's own estimate has to come to the other stream's offset to count as the same
    /// seam. The estimate is off by one packet's spacing at most on a clean splice, and two unrelated
    /// seams are at least `thresholdSeconds` apart, so a second leaves room either way.
    static let adoptToleranceSeconds = 1.0

    private struct Track {
        var previousRaw = Double.nan
        var interval = 0.0
        var offset = 0.0
    }

    private var video = Track()
    private var audio = Track()

    /// Seams logged per session. A chunked archive seams every minute or two and each seam now logs
    /// once per stream, so the cap keeps a pathological source from flooding the log.
    static let loggedSeamCap = 40

    static func logLine(_ seam: Seam, number: Int, route: String) -> String {
        "[SWHost] PTS discontinuity #\(number) (\(route), \(seam.stream == .video ? "video" : "audio")): "
            + "prevPts=\(String(format: "%.2f", seam.previousSeconds))s "
            + "rawPts=\(String(format: "%.2f", seam.rawSeconds))s "
            + "delta=\(String(format: "%.2f", seam.deltaSeconds))s -> "
            + "offset=\(String(format: "%.2f", seam.offsetSeconds))s"
            + (seam.adopted ? " (adopted from the other stream)" : "")
            + " (timeline held continuous)"
            + (number == loggedSeamCap ? " [further seams unlogged]" : "")
    }

    func offsetSeconds(for stream: Stream) -> Double {
        stream == .video ? video.offset : audio.offset
    }

    /// Feeds one packet's raw presentation time (seconds) and returns the seam it opened, if any.
    @discardableResult
    mutating func observe(_ stream: Stream, rawSeconds: Double) -> Seam? {
        guard rawSeconds.isFinite else { return nil }
        var track = stream == .video ? video : audio
        let other = stream == .video ? audio : video
        defer {
            track.previousRaw = rawSeconds
            if stream == .video { video = track } else { audio = track }
        }
        guard !track.previousRaw.isNaN else {
            // A stream's first packet starts on whatever axis the other one already folded onto, which is
            // what a single shared offset gave it before.
            track.offset = other.offset
            return nil
        }
        let delta = rawSeconds - track.previousRaw
        guard abs(delta) >= Self.thresholdSeconds else {
            if delta > 0 { track.interval = delta }
            return nil
        }
        let expected = track.previousRaw + track.interval
        let estimate = track.offset + (rawSeconds - expected)
        let adopted = !other.previousRaw.isNaN && abs(estimate - other.offset) < Self.adoptToleranceSeconds
        track.offset = adopted ? other.offset : estimate
        return Seam(stream: stream, previousSeconds: track.previousRaw, rawSeconds: rawSeconds,
                    offsetSeconds: track.offset, adopted: adopted)
    }
}
