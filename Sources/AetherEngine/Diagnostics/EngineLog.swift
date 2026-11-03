import Foundation
import os

/// Central log sink. Two outputs: (1) os.Logger per category (always on, survives Release builds, filterable in Console.app);
/// (2) optional host handlers (`handler`, `structuredHandler`) for in-app overlays and aetherctl stdout. No stdio fallback; install a handler for that.
public enum EngineLog {

    /// OSLog category (raw value = category string for Console.app filters).
    public enum Category: String, Sendable, CaseIterable {
        case engine       // session start/stop, lifecycle, cross-subsystem
        case ffmpeg       // FFmpegLogBridge av_log forwarding (AV_LOG_WARNING threshold by default)
        case session      // HLSVideoEngine orchestration: segment plan, cache, muxer resets
        case muxer        // HLSSegmentProducer internals: init segment, packet writes, flush
        case demux        // Demuxer/AVIOReader: source open, seek, packet reads
        case hlsServer = "hls.server"    // HLSLocalServer: incoming GETs, playlist, segment dispatch
        case audioBridge = "audio.bridge" // AudioBridge: decode->S16PCM->FLAC, PTS rebase, lifecycle
        case swPlayback = "sw.playback"   // SoftwarePlaybackHost pipeline: SoftwareVideoDecoder, HardwareVideoDecoder, SampleBufferRenderer
        case scrub        // seek diagnostics: backward-seek detection, reset reasons, A/V watermarks
    }

    /// Optional host handler for every diagnostic line (in-app overlay, aetherctl stdout).
    /// Called on whatever thread emitted the line; must be thread-safe and non-blocking.
    /// Lock-guarded: multi-word closure swap against concurrent reads is a data race.
    public static var handler: ((String) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return _handler }
        set { handlerLock.lock(); _handler = newValue; handlerLock.unlock() }
    }
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var _handler: ((String) -> Void)?

    /// `handler` with the line's category and level attached (AE#897), for a host that files lines by
    /// subsystem instead of parsing the `[Prefix]` convention. Receives the same redacted lines as
    /// `handler`, in the same order and under the same threading rules; installing both delivers every
    /// line to each. The level is `.info` today, since `.verbose` lines never reach a host handler.
    public static var structuredHandler: ((String, Category, Level) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return _structuredHandler }
        set { handlerLock.lock(); _structuredHandler = newValue; handlerLock.unlock() }
    }
    nonisolated(unsafe) private static var _structuredHandler: ((String, Category, Level) -> Void)?

    /// Names a value that must never appear in a log line, such as an IPTV account password the host
    /// holds. Every line then has that exact value (and its percent-encoded form) replaced before it
    /// reaches OSLog or `handler`, wherever it sits. The engine already strips the credential shapes it
    /// can recognise (named parameters, userinfo, encoded payloads, the Xtream Codes path layout); this
    /// is for the ones only the host knows, such as a provider URL that carries the password as a bare
    /// path segment. Returns false, and registers nothing, for a value shorter than four bytes, which
    /// would black out ordinary text. Thread-safe.
    @discardableResult
    public static func registerSecret(_ value: String) -> Bool {
        LogRedaction.register(value)
    }

    /// Stops redacting a value passed to `registerSecret(_:)`, for example on logout. Registrations are
    /// counted, so a value two owners registered stays redacted until both have unregistered it.
    public static func unregisterSecret(_ value: String) {
        LogRedaction.unregister(value)
    }

    /// The line as `emit` would deliver it, with credentials stripped. For a tool or a host that prints
    /// a line of its own next to the engine's, such as aetherctl's banners, so the line it composes does
    /// not carry the token the engine's lines hide (audit OPS-106).
    public static func redacted(_ line: String) -> String {
        LogRedaction.redact(line)
    }

    public static let subsystem: String = "de.superuser404.AetherEngine"

    private static let loggers: [Category: Logger] = {
        var map: [Category: Logger] = [:]
        for cat in Category.allCases {
            map[cat] = Logger(subsystem: subsystem, category: cat.rawValue)
        }
        return map
    }()

    private static let osLogs: [Category: OSLog] = {
        var map: [Category: OSLog] = [:]
        for cat in Category.allCases {
            map[cat] = OSLog(subsystem: subsystem, category: cat.rawValue)
        }
        return map
    }()

    public enum Level: Sendable {
        /// Default: OSLog default level + host handler (in-app overlay, aetherctl stdout).
        case info
        /// Per-segment/per-request trace: OSLog .debug only, NOT mirrored to host handler.
        /// Retrieve with `log stream --level debug --predicate 'subsystem == "de.superuser404.AetherEngine"'`.
        case verbose
    }

    /// Emit under `.engine`. Kept for source compatibility; prefer the typed-category overload.
    public static func emit(_ line: String) {
        emit(line, category: .engine)
    }

    /// Emit under a specific category. `.public` privacy so Console shows the full string instead of `<private>`.
    public static func emit(_ line: String, category: Category) {
        deliver(line, category: category, level: .info)
    }

    public static func emit(_ line: String, category: Category, level: Level) {
        deliver(line, category: category, level: level)
    }

    /// The single funnel every line passes, which is where credentials come out (see LogRedaction).
    /// Doing it here rather than at the call sites is what makes a URL logged by code added later safe
    /// without its author knowing the redactor exists, and it covers OSLog as well as the host handler:
    /// `.public` privacy means a Console.app capture or a sysdiagnose would otherwise carry the token
    /// in clear text even for a host that scrubs its own log.
    private static func deliver(_ line: String, category: Category, level: Level) {
        switch level {
        case .info:
            let line = LogRedaction.redact(line)
            loggers[category]?.log("\(line, privacy: .public)")
            handler?(line)
            structuredHandler?(line, category, level)
        case .verbose:
            guard let osLog = osLogs[category], osLog.isEnabled(type: .debug) else { return }
            let line = LogRedaction.redact(line)
            loggers[category]?.debug("\(line, privacy: .public)")
        }
    }
}

extension EngineLog {
    /// Audit NET-114: `"\(error)"` of a URLError prints its userInfo, which is the failing URL twice
    /// with its whole query. The code and the host say what failed without handing the log the URL.
    /// Any other error keeps its own description.
    static func summary(of error: Error) -> String {
        let bridged = error as NSError
        guard bridged.domain == NSURLErrorDomain else { return "\(error)" }
        let failing = (bridged.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (bridged.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        return "NSURLError \(bridged.code)" + (failing?.host.map { " from \($0)" } ?? "")
    }
}
