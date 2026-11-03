import Foundation

/// The enhancement layer a Dolby Vision Profile 7 source carries, from its first RPU's `el_type`.
public enum DolbyVisionEnhancementLayer: String, Sendable, Codable {
    /// Full Enhancement Layer: the residual changes the picture, and only the dual-layer route shows it.
    case fel = "FEL"
    /// Minimal Enhancement Layer: the residual is empty, so the base layer and the RPU are the picture.
    case mel = "MEL"
}

extension AetherEngine {

    /// Reads which enhancement layer a Dolby Vision Profile 7 source carries, for a details screen or a
    /// badge: no container declares it, so the first RPU in the stream is parsed for its `el_type`.
    ///
    /// Bounded by the same packet and byte ceilings the load path's own `el_type` probe uses, so it
    /// reads the head of the stream and nothing more. No decode, no session. Not for the playback-start
    /// path. Returns nil when the source is not Profile 7 or no RPU turns up within the budget.
    ///
    /// - Parameters:
    ///   - url: Media source.
    ///   - options: Only `httpHeaders` is read.
    /// - Throws: Open errors.
    public nonisolated static func probeDolbyVisionEnhancementLayer(
        url: URL,
        options: LoadOptions = .init()
    ) throws -> DolbyVisionEnhancementLayer? {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        // The record audit's cheap open: no `find_stream_info`, and the extradata the RPU walk needs for
        // its NAL framing survives it.
        try demuxer.open(
            url: url, extraHeaders: options.httpHeaders,
            profile: .dolbyVisionRecordAuditDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil))
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0 else { return nil }
        return DolbyVisionRecordAudit.probeEnhancementLayerType(demuxer: demuxer, streamIndex: videoIdx)
            .flatMap(DolbyVisionEnhancementLayer.init(rawValue:))
    }
}
