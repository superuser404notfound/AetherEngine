import Foundation
import os

/// Single point where the engine emits human-readable diagnostic
/// lines. Three sinks fan out from every call:
///
///   1. **OSLog** (`os.Logger`) — structured per-category logging that
///      shows up in Console.app and `log stream` and survives Release
///      builds without a debugger. Filterable per subsystem/category,
///      e.g. `log stream --predicate 'subsystem == "de.superuser404.AetherEngine" AND category == "muxer"'`.
///   2. **stdout** (`print`) — kept as a no-cost fallback so paired-Mac
///      Xcode runs and the macOS `aetherctl` CLI keep their existing
///      flow.
///   3. **Host handler** — invoked synchronously on the emit thread,
///      lets a host like Sodalite mirror diagnostics into an in-app
///      overlay or ring buffer. Required because tvOS Release builds
///      often redirect stdout to /dev/null when no debugger is
///      attached, and because handlers can outlive a `#if DEBUG` gate.
///
/// Centralising on `EngineLog.emit(...)` means the call site never
/// has to gate on build config or thread-safety; the dispatch happens
/// here.
public enum EngineLog {

    /// Categories partition diagnostic output so OSLog filters can
    /// isolate the muxer, the demuxer, or the HLS server independently
    /// of the rest. The raw value is the OSLog category string (dot
    /// notation is fine; reads cleanly in Console.app filters).
    public enum Category: String, Sendable, CaseIterable {
        /// Generic engine plumbing that doesn't fit a more specific
        /// category — session start/stop, lifecycle errors, anything
        /// that crosses subsystem boundaries.
        case engine
        /// `HLSVideoEngine` session orchestration: segment plan,
        /// segment-cache lifecycle, muxer resets, anything in
        /// `VideoSegmentProvider.mediaSegment(at:)`.
        case session
        /// `HLSSegmentProducer` muxer-side internals: init segment
        /// construction, per-fragment packet writes, flush, box
        /// summaries.
        case muxer
        /// `Demuxer` / `AVIOReader`: source open, seek, packet reads,
        /// HTTP byte-range fetch decisions.
        case demux
        /// `HLSLocalServer` HTTP request handling: incoming GETs,
        /// playlist generation, segment dispatch.
        case hlsServer = "hls.server"
        /// `AudioBridge` transcoding path: source decode → S16 PCM →
        /// FLAC encode, per-segment PTS rebase, encoder lifecycle.
        case audioBridge = "audio.bridge"
        /// Scrub / seek diagnostics: backward-seek detection, reset
        /// reasons, A/V watermarks.
        case scrub
    }

    /// Set by the host (e.g. on app start) to receive every
    /// diagnostic line. Called on whatever thread emitted the line,
    /// so handlers must be thread-safe and should not block. Typical
    /// shape: append to a ring buffer that an in-app overlay reads.
    nonisolated(unsafe) public static var handler: ((String) -> Void)?

    /// Subsystem used for OSLog. Kept here as a public constant so
    /// hosts can match it in `log stream` filters or pull it into UI
    /// copy without re-typing the string.
    public static let subsystem: String = "de.superuser404.AetherEngine"

    /// Per-category `os.Logger` instances. Created lazily on first
    /// access and reused. `Logger` is thread-safe and inherently
    /// `Sendable` from the OSLog framework, so the static dictionary
    /// is read-only after init and safe across threads.
    private static let loggers: [Category: Logger] = {
        var map: [Category: Logger] = [:]
        for cat in Category.allCases {
            map[cat] = Logger(subsystem: subsystem, category: cat.rawValue)
        }
        return map
    }()

    /// Emit one diagnostic line under the generic `.engine` category.
    /// Kept for source compatibility with the original call sites;
    /// new code should prefer the typed-category overload.
    public static func emit(_ line: String) {
        emit(line, category: .engine)
    }

    /// Emit one diagnostic line under a specific category. Always
    /// writes to OSLog and stdout, additionally calls the registered
    /// host handler if any. Cheap when no handler is installed.
    ///
    /// The OSLog `\(..., privacy: .public)` interpolation marks the
    /// payload as non-sensitive — engine logs never contain user
    /// data, just file paths / timestamps / byte counts — so Console
    /// shows the full string instead of `<private>`.
    public static func emit(_ line: String, category: Category) {
        loggers[category]?.log("\(line, privacy: .public)")
        print(line)
        handler?(line)
    }
}
