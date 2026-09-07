import Foundation
import Combine

/// Separate ObservableObject for liveTelemetry (AetherEngine#29).
/// Keeping it on the engine itself caused 1 Hz objectWillChange storms that blinked native Menu on tvOS.
/// Stats overlays observe this object; everything else observes the engine and is unaffected by telemetry samples.
@MainActor
public final class EngineDiagnostics: ObservableObject {

    /// Positive non-IDR immediate/exact recovery keys in the bounded VOD routing sample.
    /// nil means no sample was taken; cleared when the session stops.
    @Published public internal(set) var h264RecoveryPointKeyCount: Int?

    /// 1 Hz snapshot while playing/paused; nil while idle. Cleared in stopInternal so sessions don't inherit stale numbers.
    @Published public internal(set) var liveTelemetry: LiveTelemetry?
}
