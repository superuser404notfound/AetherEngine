import Foundation
import os

/// Single point where the engine emits human-readable diagnostic
/// lines. Two sinks:
///
///   1. **OSLog** (`os.Logger`, always on): structured per-category
///      logging that shows up in Console.app, `log stream`, and
///      Xcode's debug console, and survives Release builds without
///      a debugger. Filterable per subsystem/category, e.g.
///      `log stream --predicate 'subsystem == "de.superuser404.AetherEngine" AND category == "muxer"'`.
///   2. **Host handler** (optional): if a host sets
///      `EngineLog.handler`, every line is mirrored there. Used by
///      apps mirroring into an in-app overlay/ring buffer, and by
///      `aetherctl serve`/`validate`/`probe` to add a timestamp
///      prefix and route to stdout. No stdio fallback inside
///      `EngineLog`; any context that wants live stdout must
///      install a handler explicitly.
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
        /// FFmpeg-internal diagnostics forwarded by `FFmpegLogBridge`
        /// from `av_log_set_callback`. Covers the muxer, demuxer,
        /// encoders, and decoders as a single stream — FFmpeg's own
        /// `[mp4 @ ...]` / `[h264 @ ...]` prefixes preserved by
        /// `av_log_format_line2` identify the originating subsystem.
        /// Threshold defaults to `AV_LOG_WARNING`; hosts that want
        /// verbose output call `FFmpegLogBridge.install(level:)`.
        case ffmpeg
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
        /// `SoftwarePlaybackHost` and its decode/render pipeline:
        /// `SoftwareVideoDecoder`, `HardwareVideoDecoder`,
        /// `SampleBufferRenderer`, `AudioDecoder`, `AudioOutput`.
        /// Covers the custom playback route AVPlayer doesn't drive.
        case swPlayback = "sw.playback"
        /// Scrub / seek diagnostics: backward-seek detection, reset
        /// reasons, A/V watermarks.
        case scrub
    }

    /// Set by the host (e.g. on app start) to receive every
    /// diagnostic line. Called on whatever thread emitted the line,
    /// so handlers must be thread-safe and should not block. Typical
    /// shape: append to a ring buffer that an in-app overlay reads.
    ///
    /// Lock-guarded: emit() reads this from arbitrary threads while a
    /// host may (re)assign it; an unsynchronized closure swap against
    /// those reads is a data race (multi-word write + release of the
    /// old closure).
    public static var handler: ((String) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return _handler }
        set { handlerLock.lock(); _handler = newValue; handlerLock.unlock() }
    }
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var _handler: ((String) -> Void)?

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

    /// Severity of a diagnostic line, controlling which sinks see it.
    public enum Level: Sendable {
        /// Decision points, lifecycle, and errors. Written to OSLog at
        /// the default level (visible in Console.app / `log stream`) and
        /// mirrored to the host handler (in-app Support screen,
        /// aetherctl stdout). This is the default.
        case info
        /// High-frequency, per-segment / per-request trace (local-server
        /// GETs, each captured segment). Written to OSLog at `.debug`
        /// level only — suppressed in the default Console stream and NOT
        /// mirrored to the host handler, so it stays out of the in-app
        /// log buffer. Retrieve on demand with
        /// `log stream --level debug --predicate 'subsystem == "de.superuser404.AetherEngine"'`.
        case verbose
    }

    /// Emit one diagnostic line under the generic `.engine` category.
    /// Kept for source compatibility with the original call sites;
    /// new code should prefer the typed-category overload.
    public static func emit(_ line: String) {
        emit(line, category: .engine)
    }

    /// Emit one diagnostic line under a specific category. Always
    /// writes to OSLog so Console.app, `log stream`, and Xcode's
    /// debug console see everything. If a host has installed a
    /// `handler`, the line is mirrored there too (in-app overlay,
    /// or aetherctl's own timestamp-prefixed stdout). No stdio
    /// fallback: any context that wants live stdout must install
    /// a handler.
    ///
    /// The OSLog `\(..., privacy: .public)` interpolation marks the
    /// payload as non-sensitive (engine logs never contain user data,
    /// just file paths, timestamps, byte counts) so Console shows the
    /// full string instead of `<private>`.
    public static func emit(_ line: String, category: Category) {
        loggers[category]?.log("\(line, privacy: .public)")
        handler?(line)
    }

    /// Emit at a chosen severity. `.info` behaves exactly like
    /// `emit(_:category:)`; `.verbose` routes to OSLog `.debug` only and
    /// skips the host handler, keeping per-segment / per-request trace
    /// out of the default Console stream and the in-app log buffer while
    /// remaining retrievable via `log stream --level debug`.
    public static func emit(_ line: String, category: Category, level: Level) {
        switch level {
        case .info:
            loggers[category]?.log("\(line, privacy: .public)")
            handler?(line)
        case .verbose:
            loggers[category]?.debug("\(line, privacy: .public)")
        }
    }
}
