import Foundation
import Libavutil

/// Installs a process-wide `av_log_set_callback` that funnels FFmpeg's
/// internal diagnostic output into `EngineLog` under the `.ffmpeg`
/// category, so muxer / demuxer / decoder warnings surface alongside
/// the engine's own log lines in Console.app and in any host-supplied
/// `EngineLog.handler` (in-app overlay, `aetherctl` stdout).
///
/// Without this bridge, FFmpeg writes to stderr via its default
/// callback, which is invisible to App Store builds, in-app overlays,
/// and `aetherctl`'s timestamped stdout. After install, every
/// `av_log(...)` call at or above the configured level is formatted
/// with `av_log_format_line2` (same prefix/format as ffmpeg's default
/// stderr output) and emitted under `.ffmpeg`.
///
/// The callback fires from whichever thread inside libav* did the
/// logging — demuxer workers, decoder threads, the muxer's interleave
/// queue. Safe because `EngineLog.emit` is itself thread-safe (OSLog
/// is, and any host handler is required to be by `EngineLog`'s
/// contract).
enum FFmpegLogBridge {

    /// Installs the callback and sets the global FFmpeg log level +
    /// flags. Idempotent: re-calling overwrites the callback with
    /// the same function pointer, so `AetherEngine.init` can invoke
    /// it unconditionally without a once-guard.
    ///
    /// `level` defaults to `AV_LOG_WARNING` — surfaces real problems
    /// (corrupt headers, missing PTS, decoder errors) without the
    /// per-segment `[mp4 @ ...] track ...` chatter that `AV_LOG_INFO`
    /// emits during normal fMP4 muxing. Hosts that want verbose
    /// diagnostics can re-call `install(level: AV_LOG_VERBOSE)` (or
    /// `AV_LOG_DEBUG`) after engine init.
    ///
    /// Flags set:
    ///   - `AV_LOG_PRINT_LEVEL` so each forwarded line carries its
    ///     severity (`[warning]`, `[error]`); `EngineLog` itself has
    ///     no per-line severity channel, so this is how the level
    ///     survives into Console.app.
    ///   - `AV_LOG_SKIP_REPEATED` for parity with the default callback,
    ///     though FFmpeg only honours it INSIDE
    ///     `av_log_default_callback`: with a custom callback installed
    ///     the flag does nothing, so the collapse of repeated lines is
    ///     implemented here (last-line + counter under a lock).
    static func install(level: Int32 = AV_LOG_WARNING) {
        av_log_set_level(level)
        av_log_set_flags(AV_LOG_PRINT_LEVEL | AV_LOG_SKIP_REPEATED)
        av_log_set_callback { avcl, level, fmt, vl in
            FFmpegLogBridge.handleLogLine(avcl: avcl, level: level, fmt: fmt, vl: vl)
        }
    }

    /// Callback body, kept out of the C-function-pointer closure (the
    /// closure must stay context-free).
    private static func handleLogLine(
        avcl: UnsafeMutableRawPointer?, level: Int32,
        fmt: UnsafePointer<CChar>?, vl: CVaListPointer?
    ) {
        // `av_log_set_callback` bypasses the level check the
        // default callback applies, so re-gate here. Cheap, and
        // means a host bumping the level after install still
        // sees the filter take effect.
        guard level <= av_log_get_level() else { return }
        guard let fmt = fmt, let vl = vl else { return }

        // 1024 matches ffmpeg's own default callback buffer.
        // Truncation is acceptable for diagnostic lines; no
        // re-alloc loop on overflow.
        let bufSize: Int32 = 1024
        var buf = [CChar](repeating: 0, count: Int(bufSize))
        _ = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
            // The print-prefix state must persist across calls:
            // libav* emits multi-part lines (no trailing \n) that
            // continue in the next call, and a per-call local gave
            // every continuation its own prefix.
            repeatLock.lock()
            defer { repeatLock.unlock() }
            return av_log_format_line2(avcl, level, fmt, vl,
                                       bp.baseAddress, bufSize,
                                       &printPrefixState)
        }

        var line = String(cString: buf)
        // av_log_format_line2 always terminates with `\n`; strip
        // it so OSLog doesn't render a trailing blank line.
        if line.hasSuffix("\n") { line.removeLast() }
        if line.isEmpty { return }

        // Collapse repeated lines (AV_LOG_SKIP_REPEATED is a no-op
        // with a custom callback, see install doc): a decoder
        // spamming the identical warning otherwise floods OSLog and
        // every host ring buffer unbounded.
        repeatLock.lock()
        if line == lastLine {
            repeatCount &+= 1
            repeatLock.unlock()
            return
        }
        let suppressed = repeatCount
        let previous = lastLine
        lastLine = line
        repeatCount = 0
        repeatLock.unlock()
        if suppressed > 0, let previous {
            EngineLog.emit("Last message repeated \(suppressed) times: \(previous)", category: .ffmpeg)
        }

        EngineLog.emit(line, category: .ffmpeg)
    }

    /// Guards the repeat-suppression state and the format-line prefix
    /// state; the callback fires from arbitrary libav* threads.
    private static let repeatLock = NSLock()
    nonisolated(unsafe) private static var lastLine: String?
    nonisolated(unsafe) private static var repeatCount: Int = 0
    nonisolated(unsafe) private static var printPrefixState: Int32 = 1
}
