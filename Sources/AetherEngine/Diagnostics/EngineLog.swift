import Foundation

/// Single point where the engine emits human-readable diagnostic
/// lines. Always writes to `print` (stdout), additionally invokes a
/// host-supplied handler so a host like Sodalite can mirror the
/// stream into its own UI overlay or log file. The handler hook
/// matters because:
///
///   1. tvOS / iOS Release builds often have stdout silently
///      redirected to /dev/null when no debugger is attached, so a
///      `dup2`-based stdout-tap on the host side is unreliable.
///   2. Many engine prints used to be wrapped in `#if DEBUG` and
///      vanished in TestFlight builds, where we actually need them
///      for beta-tester diagnostics.
///
/// Centralising on `EngineLog.emit(...)` solves both: the line is
/// always handed to the handler regardless of build config, and
/// `print` stays as a no-cost fallback for paired-Mac flows.
public enum EngineLog {

    /// Set by the host (e.g. on app start) to receive every
    /// diagnostic line. Called on whatever thread emitted the line,
    /// so handlers must be thread-safe and should not block. Typical
    /// shape: append to a ring buffer that an in-app overlay reads.
    nonisolated(unsafe) public static var handler: ((String) -> Void)?

    /// Emit one diagnostic line. Always prints, additionally calls
    /// the registered handler if any. Cheap when no handler is
    /// installed (App Store builds), so callers don't need to gate
    /// on build config.
    public static func emit(_ line: String) {
        print(line)
        handler?(line)
    }
}
