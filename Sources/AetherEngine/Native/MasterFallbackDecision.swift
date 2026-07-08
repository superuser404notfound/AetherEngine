import Foundation

/// A display rejecting the served HLS master playlist: the `AVPlayerItem` failed with a
/// display-incompatibility error. `-11868` (AVErrorNoCompatibleAlternatesForExternalDisplay) is the
/// iOS external-SDR-monitor case; `-11848` is an HDR master shipped to an SDR-parked panel.
struct DisplayRejection: Sendable, Equatable {
    let code: Int
    let message: String
}

/// Pure display-rejection fallback decision (#98). Kept separate and pure so the state machine is
/// testable offline, matching the style of `ItemDeathReviveGate`. Stage 1.5 of the master-always
/// initiative: on an actual master rejection, reload a reduced master that keeps the subtitle
/// renditions before the bare media playlist, instead of dropping straight to the subtitle-less media.
enum MasterFallbackDecision {

    /// The two AVFoundationErrorDomain codes that mean "this display cannot present the master".
    static func isDisplayRejectionCode(_ code: Int) -> Bool {
        code == -11868 || code == -11848
    }

    /// Which playlist is being served now, for the display-rejection fallback chain.
    enum FallbackStage: Equatable {
        case primaryMaster   // the DV/HDR master start() chose
        case reducedMaster   // a reduced master (DV signaling dropped, subtitle renditions kept)
        case media           // the bare media playlist (no subtitle renditions)
    }

    /// What to reload next, or `.none` to surface the failure. Bounded chain
    /// primaryMaster -> reducedMaster -> media -> stop: single pass, so a repeatedly rejected reload
    /// cannot loop. `.primaryMaster` skips straight to `.media` only when no reduced master exists
    /// (no master metadata at all); every real HDR/DV master has a reduced variant.
    enum FallbackTarget: Equatable {
        case reducedMaster
        case media
        case none
    }

    static func nextFallbackTarget(
        errorCode: Int, currentStage: FallbackStage, reducedMasterAvailable: Bool
    ) -> FallbackTarget {
        guard isDisplayRejectionCode(errorCode) else { return .none }
        switch currentStage {
        case .primaryMaster: return reducedMasterAvailable ? .reducedMaster : .media
        case .reducedMaster: return .media
        case .media:         return .none
        }
    }
}
