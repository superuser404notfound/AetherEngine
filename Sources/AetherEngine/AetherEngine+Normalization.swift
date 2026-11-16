import Foundation

/// Sodalite#242: a per-track loudness correction for audio-only sessions.
///
/// Music servers measure every track's loudness and hand a client the gain that brings it to a
/// common level (ReplayGain, Jellyfin's `NormalizationGain` against -18 LUFS). Most modern masters
/// need a cut, which `volume` could carry, but a quiet older master needs a lift, and `volume` stops
/// at 1.0. This applies the gain inside the engine on both audio-only hosts, so a lift works too,
/// with a -1 dBFS lookahead limiter behind it so the lift cannot clip.
///
/// - On the AVPlayer audio host the gain runs in an `MTAudioProcessingTap` on the item, so a track
///   never changes host because of it.
/// - On the FFmpeg audio host it runs in the decoder, ahead of any `AudioShaping`.
///
/// Video sessions ignore it.
extension AetherEngine {

    /// The loudness correction in force for this audio-only session, in dB, as clamped by the engine
    /// (`NormalizationGainReport.gainRange`). nil is none.
    public var normalizationGainDB: Double? { loadedOptions.normalizationGainDB }

    /// Change the loudness correction of the running audio-only session. The gain ramps to the new
    /// value over one audio buffer, without a rebuild. nil turns it off (a tap already in place stays
    /// at 0 dB until the track ends). Stored in the options, so it is also what the next reload uses.
    public func setNormalizationGain(_ gainDB: Double?) {
        let next = gainDB.flatMap { $0.isFinite ? NormalizationGainProcessor.clampedGainDB($0) : nil }
        guard next != loadedOptions.normalizationGainDB else { return }
        setLoadedNormalizationGain(next)
        if audioAVPlayerActive, let host = audioAVPlayerHost {
            host.setNormalizationGain(next)
        } else if let host = audioHost {
            host.normalizationGainDB = next
        }
        EngineLog.emit("[AetherEngine] Sodalite#242: normalization gain = "
                       + (next.map { String(format: "%+.1f dB", $0) } ?? "off"), category: .engine)
    }

    /// What the loudness correction is doing on the current audio-only session, or, between sessions,
    /// what it did on the last one (captured when that session was torn down). nil when no gain was
    /// asked for. Read it before loading the next track to log the finished one.
    public var normalizationGainReport: NormalizationGainReport? {
        liveNormalizationGainReport ?? lastNormalizationGainReport
    }

    var liveNormalizationGainReport: NormalizationGainReport? {
        if audioAVPlayerActive, let host = audioAVPlayerHost { return host.normalizationReport }
        if let host = audioHost { return host.normalizationReport }
        return nil
    }

    /// Called from `stopInternal` before the audio hosts stop: keeps the finished session's figures
    /// and writes them to the log.
    func captureNormalizationGainReport() {
        guard let report = liveNormalizationGainReport else { return }
        lastNormalizationGainReport = report
        EngineLog.emit("[AetherEngine] Sodalite#242: normalization " + report.summary, category: .engine)
    }
}

/// What the engine did with `LoadOptions.normalizationGainDB` on an audio-only session.
public struct NormalizationGainReport: Sendable, Equatable {

    /// The gains the engine applies, in dB. A lift past +18 dB would mostly raise noise, and nothing
    /// a loudness scan reports needs a cut past -30.
    public static let gainRange: ClosedRange<Double> = NormalizationGainProcessor.gainRange

    /// The limiter's ceiling, in dBFS.
    public static let ceilingDBFS: Double = NormalizationGainProcessor.ceilingDBFS

    public enum Host: String, Sendable, Equatable {
        case avPlayer = "AVPlayer"
        case ffmpeg = "FFmpeg"
    }

    public enum Stage: String, Sendable, Equatable {
        /// An `MTAudioProcessingTap` on the AVPlayer item: full gain, lift included, and the limiter.
        case tap
        /// The FFmpeg host's decoder: full gain and the limiter.
        case decoder
        /// No tap could be installed, so `AVPlayer.volume` carries the cut part of the gain; a lift
        /// is not applied.
        case volume
        /// Nothing is applied.
        case none
    }

    /// The gain asked for, clamped to `gainRange`.
    public var requestedDB: Double
    /// The gain actually applied. Below `requestedDB` when the stage cannot lift.
    public var appliedDB: Double
    public var host: Host
    public var stage: Stage
    /// The largest gain reduction the limiter applied, in dB; 0 when it never acted.
    public var limiterMaxReductionDB: Double
    /// Share of the played audio during which the limiter reduced gain, 0...1.
    public var limitingShare: Double
    /// Why less was applied than asked for, when the engine knows.
    public var note: String?

    public init(requestedDB: Double, appliedDB: Double, host: Host, stage: Stage,
                limiterMaxReductionDB: Double = 0, limitingShare: Double = 0, note: String? = nil) {
        self.requestedDB = requestedDB
        self.appliedDB = appliedDB
        self.host = host
        self.stage = stage
        self.limiterMaxReductionDB = limiterMaxReductionDB
        self.limitingShare = limitingShare
        self.note = note
    }

    init(requestedDB: Double, appliedDB: Double, host: Host, stage: Stage,
         statistics: NormalizationGainProcessor.Statistics?, note: String?) {
        self.init(requestedDB: requestedDB, appliedDB: appliedDB, host: host, stage: stage,
                  limiterMaxReductionDB: statistics?.maxReductionDB ?? 0,
                  limitingShare: statistics?.limitingShare ?? 0, note: note)
    }

    /// One line in the engine's log wording, e.g.
    /// `requested=+3.0 applied=+3.0 host=AVPlayer stage=tap limiter=2.3 dB 0.4%`.
    public var summary: String {
        let limiter = limiterMaxReductionDB > 0
            ? String(format: "%.1f dB %.1f%%", limiterMaxReductionDB, limitingShare * 100)
            : "none"
        var line = String(format: "requested=%+.1f applied=%+.1f", requestedDB, appliedDB)
            + " host=\(host.rawValue) stage=\(stage.rawValue) limiter=\(limiter)"
        if let note { line += " (\(note))" }
        return line
    }
}
