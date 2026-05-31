import Foundation

extension AetherEngine {
    /// Vends a `FrameExtractor` for the currently loaded URL and its
    /// HTTP headers, or nil if nothing is loaded.
    ///
    /// The engine does NOT retain the returned extractor; the caller
    /// owns its lifecycle (and should call `shutdown()` or release it
    /// when done). Used for scrub-preview of the playing item.
    /// Recents-style callers that need frames from arbitrary items
    /// should construct `FrameExtractor(url:httpHeaders:)` directly.
    public func makeFrameExtractor() -> FrameExtractor? {
        guard let url = loadedURL else { return nil }
        return FrameExtractor(url: url, httpHeaders: loadedOptions.httpHeaders)
    }
}
