import Foundation
import Libavutil

/// Funnels FFmpeg's av_log output into EngineLog under .ffmpeg via av_log_set_callback.
/// Without this bridge FFmpeg writes to stderr (invisible in App Store builds and in-app overlays).
/// av_log_format_line2 preserves FFmpeg's own [mp4@...]/[h264@...] prefixes.
/// Callback fires from arbitrary libav* threads; safe because EngineLog.emit is thread-safe.
enum FFmpegLogBridge {

    /// Install the callback and set the global FFmpeg log level + flags. Idempotent; call unconditionally from AetherEngine.init.
    /// Defaults to AV_LOG_WARNING (skips per-segment fMP4 muxing chatter from AV_LOG_INFO).
    /// AV_LOG_PRINT_LEVEL prepends severity to each line (EngineLog has no per-line severity channel).
    /// AV_LOG_SKIP_REPEATED is a no-op with a custom callback; collapse is implemented here via lastLine+counter.
    static func install(level: Int32 = AV_LOG_WARNING) {
        av_log_set_level(level)
        av_log_set_flags(AV_LOG_PRINT_LEVEL | AV_LOG_SKIP_REPEATED)
        av_log_set_callback { avcl, level, fmt, vl in
            FFmpegLogBridge.handleLogLine(avcl: avcl, level: level, fmt: fmt, vl: vl)
        }
    }

    private static func handleLogLine(
        avcl: UnsafeMutableRawPointer?, level: Int32,
        fmt: UnsafePointer<CChar>?, vl: CVaListPointer?
    ) {
        // av_log_set_callback bypasses the level check; re-gate so host bumps to the level still filter correctly.
        guard level <= av_log_get_level() else { return }
        guard let fmt = fmt, let vl = vl else { return }

        // 1024 matches ffmpeg's own default callback buffer; truncation is acceptable for diagnostic lines.
        let bufSize: Int32 = 1024
        var buf = [CChar](repeating: 0, count: Int(bufSize))
        _ = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
            // printPrefixState must persist across calls: libav* emits multi-part lines without trailing \n.
            repeatLock.lock()
            defer { repeatLock.unlock() }
            return av_log_format_line2(avcl, level, fmt, vl,
                                       bp.baseAddress, bufSize,
                                       &printPrefixState)
        }

        // buf is a NUL-terminated CChar buffer from av_log_format_line2; decode up to the NUL as
        // UTF-8 (String(cString:) is deprecated).
        var line = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if line.hasSuffix("\n") { line.removeLast() }  // av_log_format_line2 always appends \n
        if line.isEmpty { return }

        // Collapse repeated lines (AV_LOG_SKIP_REPEATED no-op with custom callback; implemented here).
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

    /// Guards repeat-suppression state and format-line prefix state (callback fires from arbitrary libav* threads).
    private static let repeatLock = NSLock()
    nonisolated(unsafe) private static var lastLine: String?
    nonisolated(unsafe) private static var repeatCount: Int = 0
    nonisolated(unsafe) private static var printPrefixState: Int32 = 1
}
