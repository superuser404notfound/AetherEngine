// Only in DEBUG builds with the DualLayerDolbyVision trait: it pins metadata on composed frames.
#if DEBUG && DualLayerDolbyVision
import Foundation

/// Diagnostic controls (SPI, not host API) for the on-device Dolby Vision consumption test.
///
/// The pinned-RPU test holds the decoded pixels constant and changes only the metadata,
/// so a pulse on the panel is evidence regardless of where the composition happens.
///
/// Debug-only.
extension AetherEngine {

    /// Arms (or disarms) the pinned-RPU test.
    ///
    /// Drive it from a debug menu; `aetherctl play --fel --dv-pin` takes the same spec on the Mac.
    /// `aetherctl dvsurvey` prints a spec tuned to the title you intend to play.
    ///
    /// - Parameter spec: e.g. `"darkest:240,period:2"`, or nil to disarm.
    /// - Returns: false if `spec` carried no recognisable capture rule, in which case nothing was
    ///   armed, a typo leaves playback alone rather than pinning something arbitrary.
    @discardableResult
    @_spi(Diagnostics)
    public static func armDolbyVisionPinTest(_ spec: String?) -> Bool {
        guard let spec else {
            DoviDisplayMetadataDebug.configure(nil)
            return true
        }
        guard let config = DoviDisplayMetadataDebug.parse(spec: spec) else {
            EngineLog.emit("dv-pin: could not parse '\(spec)', expected something like "
                           + "'darkest:240,period:2' or 'avgpq<=1200,period:2'. Not armed.",
                           category: .engine)
            return false
        }
        DoviDisplayMetadataDebug.configure(config)
        return true
    }

    /// True once the pin test has captured a frame and is substituting metadata.
    @_spi(Diagnostics)
    public static var dolbyVisionPinIsActive: Bool { DoviDisplayMetadataDebug.isPinned }

    /// True while the pin test is armed (scanning or actively substituting).
    @_spi(Diagnostics)
    public static var dolbyVisionPinIsArmed: Bool { DoviDisplayMetadataDebug.isArmed }
}
#endif
