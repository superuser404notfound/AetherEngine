import Foundation

extension AetherEngine {
    /// Vends a `FrameExtractor` for the currently loaded source, or nil if
    /// nothing is loaded. URL sources use the URL and its HTTP headers; custom
    /// `IOReader` sources use an independent reader clone (nil when the reader
    /// cannot provide a second cursor, e.g. forward-only).
    ///
    /// The engine does NOT retain the returned extractor; the caller
    /// owns its lifecycle. Call `await shutdown()` for prompt teardown
    /// of the decode context; merely releasing the reference is also
    /// safe but defers cleanup until the idle-close timer fires.
    /// Used for scrub-preview of the playing item.
    /// Recents-style callers that need frames from arbitrary items
    /// should construct `FrameExtractor(url:httpHeaders:)` directly.
    public func makeFrameExtractor() -> FrameExtractor? {
        if isCustomSource {
            // Scrub preview runs a second demuxer concurrently with playback,
            // so it needs an independent reader. nil when the source cannot
            // clone (forward-only / one-shot), then scrub preview is skipped.
            guard let clone = customReader?.makeIndependentReader() else { return nil }
            return FrameExtractor(reader: clone, formatHint: customFormatHint)
        }
        guard let url = loadedURL else { return nil }
        return FrameExtractor(url: url, httpHeaders: loadedOptions.httpHeaders)
    }
}
