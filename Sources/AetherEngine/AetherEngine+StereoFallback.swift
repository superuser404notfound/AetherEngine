import Foundation

/// A 3D session the system refuses at startup is rebuilt once in 2D.
///
/// Stereo is only ever offered where the system presents it (visionOS, `StereoVideoSignal`), and a
/// source that carries a second view or a packed frame always has a 2D form: the base view, or the
/// frame as it is. So a refusal of the stereo session is not the end of the source. The rebuild is
/// `startTakeoverRebuild` with `stereoPresentation = .mono`, which keeps the playhead and lets a
/// waiting `load()` follow it. It cannot loop: a 2D session arms nothing.
///
/// Measured with Dolby Vision Profile 20 over HLS: the macOS 27 AVPlayer and the visionOS 27 simulator
/// fail the stereo master with -12927, while the same init and segments play as a local file on both.
extension AetherEngine {
    @MainActor
    func fallBackToTwoDimensional(_ message: String, expectedGeneration: UInt64) async {
        guard loadGeneration == expectedGeneration else {
            EngineLog.emit(
                "[AetherEngine] stereo fallback dropped: the session it was raised for has ended",
                category: .engine)
            return
        }
        EngineLog.emit(
            "[AetherEngine] stereo: AVPlayer refused the 3D session at startup; rebuilding it in 2D: \(message)",
            category: .engine)
        let rebuild = startTakeoverRebuild { $0.stereoPresentation = .mono }
        do {
            try await rebuild.value
            EngineLog.emit("[AetherEngine] stereo: rebuilt in 2D", category: .engine)
        } catch is CancellationError {
            EngineLog.emit("[AetherEngine] stereo: 2D rebuild superseded; nothing to surface", category: .engine)
        } catch {
            // A rebuild that failed after its teardown surfaced its own failure already.
            guard loadGeneration == expectedGeneration else { return }
            EngineLog.emit(
                "[AetherEngine] stereo: the 2D rebuild failed (\(error)); surfacing the original failure",
                category: .engine)
            publishError(NativeAVPlayerHost.itemFailureInfo(desc: message, itemError: nil))
        }
    }
}
