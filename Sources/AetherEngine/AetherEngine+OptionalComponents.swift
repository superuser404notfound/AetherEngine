import Foundation

extension AetherEngine {

    /// The parts of the engine that are compiled only when a host enables their package trait, all off
    /// by default (README, "Optional components"). Without its trait a component is not in the binary
    /// and the option that asks for it changes nothing, so a host reads `isBuiltIn` to hide a setting
    /// that would do nothing in its build.
    public enum OptionalComponent: String, CaseIterable, Sendable {
        /// TrueHD Atmos object rendering for `LoadOptions.objectAudioRendering` (trait `TrueHDObjectAudio`).
        case trueHDObjectAudio = "TrueHDObjectAudio"
        /// DTS:X height and object rendering for `LoadOptions.objectAudioRendering` (trait `DTSXObjectAudio`).
        case dtsxObjectAudio = "DTSXObjectAudio"
        /// Profile 7 FEL dual-layer composition for `LoadOptions.preferDualLayerDolbyVision`
        /// (trait `DualLayerDolbyVision`).
        case dualLayerDolbyVision = "DualLayerDolbyVision"
        /// Stills (scrub thumbnails, I-frame stills, held pictures) of Dolby Vision Profile 5 / 10.0
        /// sources, which have no base layer to show (trait `DolbyVisionStillReshaping`).
        case dolbyVisionStillReshaping = "DolbyVisionStillReshaping"

        /// The package trait that compiles the component.
        public var traitName: String { rawValue }

        /// Whether this build carries the component.
        public var isBuiltIn: Bool {
            switch self {
            case .trueHDObjectAudio:
                #if TrueHDObjectAudio
                return true
                #else
                return false
                #endif
            case .dtsxObjectAudio:
                #if DTSXObjectAudio
                return true
                #else
                return false
                #endif
            case .dualLayerDolbyVision:
                #if DualLayerDolbyVision
                return true
                #else
                return false
                #endif
            case .dolbyVisionStillReshaping:
                #if DolbyVisionStillReshaping
                return true
                #else
                return false
                #endif
            }
        }
    }
}
