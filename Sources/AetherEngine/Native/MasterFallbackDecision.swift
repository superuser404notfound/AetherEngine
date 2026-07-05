import Foundation

/// A display rejecting the served HLS master playlist: the `AVPlayerItem` failed with a
/// display-incompatibility error. `-11868` (AVErrorNoCompatibleAlternatesForExternalDisplay) is the
/// iOS external-SDR-monitor case; `-11848` is an HDR master shipped to an SDR-parked panel.
struct DisplayRejection: Sendable, Equatable {
    let code: Int
    let message: String
}

/// Pure master to media fallback decision (#98). Kept separate and pure so the gate is testable
/// offline, matching the style of `ItemDeathReviveGate`. Stage 1 of the master-always initiative:
/// react to an actual master rejection instead of predicting per-route display capability.
enum MasterFallbackDecision {

    /// The two AVFoundationErrorDomain codes that mean "this display cannot present the master".
    static func isDisplayRejectionCode(_ code: Int) -> Bool {
        code == -11868 || code == -11848
    }

    /// Fall back to the media playlist only when a display-rejection failed the item, the engine was
    /// serving the master, and this session has not already fallen back (single-shot, no loop).
    static func shouldFallBackToMediaPlaylist(
        errorCode: Int, servingMasterPlaylist: Bool, alreadyFellBack: Bool
    ) -> Bool {
        isDisplayRejectionCode(errorCode) && servingMasterPlaylist && !alreadyFellBack
    }
}
