import Foundation

/// Thread-safe mirror of the active session's starvation inputs for extractor yield closures,
/// which run on the extractor's decode queue off the main actor. MainActor writes (load / stop /
/// telemetry tick), off-main reads. The session reference stays weak so a dangling extractor
/// from a previous session can never gate or retain a torn-down pipeline.
final class ExtractorYieldState: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _session: HLSVideoEngine?
    /// Consecutive 1 Hz ticks with a healthy (>= floor) forward buffer; any thin or unknown
    /// tick resets the run. Hysteresis against post-load buffer spikes (#93 startup).
    private var _consecutiveHealthyTicks = 0

    func activate(session: HLSVideoEngine) {
        lock.lock()
        _session = session
        _consecutiveHealthyTicks = 0
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        _session = nil
        _consecutiveHealthyTicks = 0
        lock.unlock()
    }

    func setForwardBuffer(_ seconds: Double?) {
        lock.lock()
        if let seconds, seconds >= FrameExtractor.yieldMinForwardBufferSeconds {
            _consecutiveHealthyTicks += 1
        } else {
            _consecutiveHealthyTicks = 0
        }
        lock.unlock()
    }

    /// Session returned outside the lock so its own lock-guarded accessors are never
    /// nested under this one.
    func snapshot() -> (session: HLSVideoEngine?, consecutiveHealthyTicks: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_session, _consecutiveHealthyTicks)
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
        return FrameExtractor(url: url, httpHeaders: loadedOptions.httpHeaders,
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
    /// host may build the extractor before the session finishes wiring); no active native
    /// session means no gate.
    private func sessionYieldSignal() -> (@Sendable () -> Bool) {
        let state = extractorYieldState
        return {
            let snap = state.snapshot()
            guard let session = snap.session else { return false }
            return FrameExtractor.shouldYield(
                restartInFlight: session.restartInFlight,
                consecutiveHealthyTicks: snap.consecutiveHealthyTicks
            )
        }
    }
}
