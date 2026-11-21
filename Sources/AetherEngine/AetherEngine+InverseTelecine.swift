import Foundation
import AetherLibavcodec

/// #853: the load's side of inverse telecine. The decision is made before the display criteria are
/// written, because it changes the rate they ask for (23.976 instead of 29.97), and it is kept for the
/// whole session: every session-preserving rebuild reuses it, so the panel's refresh rate never moves
/// mid-session and the sample is never paid twice.
extension AetherEngine {

    /// The display and picture-stage rate of a load: 4/5 of the stream's rate under inverse telecine.
    nonisolated static func presentationFrameRate(source: Double?, inverseTelecine: Bool) -> Double? {
        guard inverseTelecine else { return source }
        return source.map { $0 * 0.8 }
    }

    /// Why the graph could not run inverse telecine for this stream, or nil when it can. Checked before
    /// the decision, because the decision also picks the display rate: a 23.976 Hz panel fed by a graph
    /// that fell back to 29.97 drops one frame in five.
    nonisolated static func inverseTelecineUnbuildable(rate: DeinterlaceConfig.SourceFrameRate) -> String? {
        if !DeinterlaceFilter.inverseTelecineFiltersLinked { return "no fieldmatch / decimate in the linked FFmpeg build" }
        if !rate.isKnown { return "the stream states no frame rate" }
        return nil
    }

    /// Whether this load runs inverse telecine. A rebuild takes its session's decision
    /// (`LoadOptions.inverseTelecineCarryover`); a fresh load reads `LoadOptions.inverseTelecine`
    /// through `TelecineCadenceProbe.gate` and, for `.auto`, samples the source. The sample moves the
    /// probe demuxer and rewinds it to the head, as the #232 probe does.
    func decideInverseTelecine(
        options: LoadOptions,
        probe: Demuxer,
        probeOpened: Bool,
        codecID: AVCodecID,
        fieldOrder: AVFieldOrder,
        frameRate: Double?,
        codedHeight: Int32,
        startPosition: Double?,
        generation gen: UInt64
    ) async throws -> Bool {
        lastInverseTelecineVerdict = nil
        if let carried = options.inverseTelecineCarryover {
            // Said only when it runs: every reload of every session carries a decision, mostly "off".
            if carried {
                EngineLog.emit("[Deinterlace] inverse telecine on: the decision of the session this reload rebuilds (#853)",
                               category: .swPlayback)
            }
            return carried
        }
        guard probeOpened, probe.videoStreamIndex >= 0 else { return false }
        // An audio-only load shows no picture, so the sample would only delay the first sound.
        guard !options.audioOnly else { return false }
        let gate = TelecineCadenceProbe.gate(
            mode: options.inverseTelecine, isLive: options.isLive, isSeekable: probe.isSourceSeekable,
            codecID: codecID, fieldOrder: fieldOrder, frameRate: frameRate, codedHeight: codedHeight)
        switch gate {
        case .skip(let reason):
            // Said only for a source that could have been a candidate, so a progressive load stays quiet.
            if fieldOrder != AV_FIELD_PROGRESSIVE, fieldOrder != AV_FIELD_UNKNOWN {
                EngineLog.emit("[Deinterlace] inverse telecine off: \(reason) (#853)", category: .swPlayback)
            }
            return false
        case .force:
            let rate = probe.stream(at: probe.videoStreamIndex).map { DeinterlaceConfig.SourceFrameRate(stream: $0) }
                ?? DeinterlaceConfig.SourceFrameRate()
            if let missing = Self.inverseTelecineUnbuildable(rate: rate) {
                EngineLog.emit("[Deinterlace] inverse telecine off: \(missing) (#853)", category: .swPlayback)
                return false
            }
            EngineLog.emit("[Deinterlace] inverse telecine on: LoadOptions.inverseTelecine is .force (#853)",
                           category: .swPlayback)
            return true
        case .sample:
            break
        }

        let videoIndex = probe.videoStreamIndex
        let rate = probe.stream(at: videoIndex).map { DeinterlaceConfig.SourceFrameRate(stream: $0) }
            ?? DeinterlaceConfig.SourceFrameRate()
        if let missing = Self.inverseTelecineUnbuildable(rate: rate) {
            EngineLog.emit("[Deinterlace] inverse telecine off: \(missing) (#853)", category: .swPlayback)
            return false
        }
        let started = DispatchTime.now()
        let verdict = await BlockingWork.detached(priority: .userInitiated) { [probe] in
            let verdict = TelecineCadenceProbe.run(
                demuxer: probe, streamIndex: videoIndex, startSeconds: startPosition, frameRate: rate)
            // The sample consumed packets and the session reuses this demuxer. A rewind that stalls
            // leaves the deinterlacer: the sample says nothing the session can act on.
            guard probe.seekBounded(to: 0, timeout: Self.probeRewindSeekTimeout) else {
                return TelecineCadenceProbe.Verdict.inconclusive(reason: "source did not rewind", verdict.report)
            }
            return verdict
        }.value
        let totalMs = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        if loadGeneration != gen {
            probe.markClosed()
            BlockingWork.detached { [probe] in probe.close() }
            try checkLoadCurrent(gen)
        }
        lastInverseTelecineVerdict = verdict
        EngineLog.emit(
            "[Deinterlace] inverse telecine \(verdict.isFilm ? "on" : "off"): \(verdict.label), "
            + "\(verdict.report.summary), \(totalMs) ms with the rewind (#853)",
            category: .swPlayback)
        return verdict.isFilm
    }
}
