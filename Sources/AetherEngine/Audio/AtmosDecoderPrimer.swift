import Foundation
import AVFoundation

/// Registers the system's Atmos decoders in this process, once.
///
/// `AVSampleBufferAudioRenderer` decodes compressed E-AC-3 as Atmos only when the process has the
/// Atmos decoder registered, and on a Mac that registration is a side effect of creating an
/// `AVPlayer` for an item: without one the renderer plays the same packets as 5.1. Creating the
/// player is enough, nothing has to play, and the registration holds for the process (measured on
/// macOS: a seek long after the player was released kept Atmos). The first player takes 0.2 to 0.35 s
/// to register and was kept for a second; releasing it sooner left the renderer on 5.1. A second
/// player in the same process only costs memory, so this runs once.
///
/// The item is the silent Atmos stream the tvOS output activator already ships (`AtmosOutputActivator`),
/// so nothing about the session's own media is needed and nothing is audible.
@MainActor
final class AtmosDecoderPrimer {
    static let shared = AtmosDecoderPrimer()

    /// How long the player is held. Registration finishes well inside it.
    static let holdSeconds: Double = 1

    private var player: AVPlayer?
    private var started: ContinuousClock.Instant?
    private var finished = false

    /// Creates the registration player now if this process has not, without waiting, so a caller can
    /// overlap the window with its own setup and `ensurePrimed` after it.
    func begin() {
        guard started == nil, !finished else { return }
        started = ContinuousClock().now
        player = AVPlayer(playerItem: AVPlayerItem(url: AtmosOutputActivator.silentAtmosStream))
        EngineLog.emit("[AtmosPrimer] creating the registration player", category: .swPlayback)
    }

    /// Starts the registration if this process has not, and returns once it is done. Cheap on every
    /// call after the first, and concurrent callers share the one wait.
    func ensurePrimed() async {
        guard !finished else { return }
        begin()
        let clock = ContinuousClock()
        if let started {
            let remaining = Duration.seconds(Self.holdSeconds) - (clock.now - started)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
        if !finished {
            finished = true
            player = nil
            EngineLog.emit("[AtmosPrimer] Atmos decoder registration window over", category: .swPlayback)
        }
    }
}
