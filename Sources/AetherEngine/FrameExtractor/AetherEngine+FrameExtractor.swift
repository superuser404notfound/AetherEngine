import Foundation

/// Thread-safe mirror of the active session's starvation inputs for extractor yield closures,
/// which run on the extractor's decode queue off the main actor. MainActor writes (load / stop /
/// telemetry tick), off-main reads. The session reference stays weak so a dangling extractor
/// from a previous session can never gate or retain a torn-down pipeline.
final class ExtractorYieldState: @unchecked Sendable {
    private let lock = NSLock()
    /// A pipeline is playing and stills must defer to it. Set on every playback path; before
    /// Sodalite#118 only the loopback session set it, so a transcode or software session had no gate.
    private var _active = false
    private weak var _session: HLSVideoEngine?
    /// Consecutive 1 Hz ticks with a healthy pipeline; any thin or unknown tick resets the run.
    /// Hysteresis against post-load buffer spikes (#93 startup).
    private var _consecutiveHealthyTicks = 0

    func activate(session: HLSVideoEngine) {
        lock.lock()
        _active = true
        _session = session
        _consecutiveHealthyTicks = 0
        lock.unlock()
    }

    /// Remote HLS and the software host: no producer session to ask about restarts, only ticks.
    func activatePipeline() {
        lock.lock()
        _active = true
        _session = nil
        _consecutiveHealthyTicks = 0
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        _active = false
        _session = nil
        _consecutiveHealthyTicks = 0
        lock.unlock()
    }

    func recordTick(healthy: Bool) {
        lock.lock()
        _consecutiveHealthyTicks = healthy ? _consecutiveHealthyTicks + 1 : 0
        lock.unlock()
    }

    /// The native paths' tick: AVPlayer's forward buffer against the floor. nil (unknown) is unhealthy.
    func setForwardBuffer(_ seconds: Double?) {
        recordTick(healthy: (seconds ?? -1) >= FrameExtractor.yieldMinForwardBufferSeconds)
    }

    /// The software path has no forward buffer in seconds (the pump is renderer-back-pressured), so a
    /// tick is healthy while the decoded cushion is not empty and the host is not rebuffering.
    static func softwareTickIsHealthy(state: PlaybackState, isRebuffering: Bool,
                                      displayCushionSeconds: Double?) -> Bool {
        guard state == .playing || state == .paused, !isRebuffering else { return false }
        return (displayCushionSeconds ?? 0) > 0
    }

    /// Session returned outside the lock so its own lock-guarded accessors are never
    /// nested under this one.
    func snapshot() -> (active: Bool, session: HLSVideoEngine?, consecutiveHealthyTicks: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_active, _session, _consecutiveHealthyTicks)
    }

    func shouldYieldNow() -> Bool {
        let snap = snapshot()
        guard snap.active else { return false }
        return FrameExtractor.shouldYield(
            restartInFlight: snap.session?.restartInFlight ?? false,
            consecutiveHealthyTicks: snap.consecutiveHealthyTicks
        )
    }
}

extension AetherEngine {
    /// Vends a `FrameExtractor` for the currently loaded source, or nil if nothing
    /// loaded. URL sources use URL + HTTP headers; custom IOReader sources use an
    /// independent reader clone (nil when the reader is forward-only / one-shot).
    /// Caller owns the extractor's lifecycle (engine does not retain it); call
    /// shutdown() for prompt teardown, else the idle-close timer cleans up.
    /// Session-coupled: elective thumbnail decodes yield while the playback pipeline
    /// is starved (#93 startup). For arbitrary items with no active session (Recents),
    /// construct FrameExtractor(url:httpHeaders:) directly.
    public func makeFrameExtractor() -> FrameExtractor? {
        if isCustomSource {
            // Scrub preview runs a second demuxer concurrently with playback, so it
            // needs an independent reader; nil (scrub skipped) if the source can't clone.
            guard let clone = customReader?.makeIndependentReader() else { return nil }
            return FrameExtractor(reader: clone, formatHint: customFormatHint,
                                  yieldWhile: sessionYieldSignal())
        }
        guard let url = loadedURL else { return nil }
        // For a disc image, pin the extractor to the currently-selected title so stills follow the
        // title switch instead of always decoding the default one (AE#105). The host rebuilds the
        // extractor when the disc title changes.
        return FrameExtractor(url: url, requestHeaderStore: sessionRequestHeaders,
                              selectTitleID: activeDiscTitleID,
                              yieldWhile: sessionYieldSignal())
    }

    /// Session-coupled extractor over a HOST-chosen URL: stills often come from the original
    /// file even while playback runs a different representation (e.g. a transcode), so the
    /// extraction URL cannot be derived from the loaded one. The yield coupling is the same
    /// as `makeFrameExtractor()`: the extractor's link traffic defers to a starved pipeline.
    public func makeFrameExtractor(url: URL, httpHeaders: [String: String] = [:]) -> FrameExtractor {
        FrameExtractor(url: url, httpHeaders: httpHeaders, yieldWhile: sessionYieldSignal())
    }

    /// Starvation signal for session-coupled extractors. Reads live state at call time (the
    /// host may build the extractor before the session finishes wiring); no active pipeline
    /// means no gate.
    private func sessionYieldSignal() -> (@Sendable () -> Bool) {
        let state = extractorYieldState
        return { state.shouldYieldNow() }
    }
}
