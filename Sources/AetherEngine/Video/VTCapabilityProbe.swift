import Foundation
import VideoToolbox
import CoreMedia

/// Cached runtime probe of VideoToolbox decoder support for the
/// codecs the HLS native path can mux into fMP4. The probe registers
/// supplemental decoders (Apple ships VP9 and AV1 as runtime-
/// registered components even on hardware that natively supports
/// them) and then queries `VTIsHardwareDecodeSupported`.
///
/// Results are cached after first access; subsequent reads are cheap.
/// Registration is idempotent on Apple's side, but we still gate on
/// the first call so the OS doesn't see a flood of registration
/// requests during fast spin-up.
enum VTCapabilityProbe {

    /// True iff VideoToolbox can decode VP9 on the current device.
    /// VP9 has real hardware decoders on Apple silicon from A12+
    /// (Apple TV 4K gen 2+) so a `VTIsHardwareDecodeSupported` probe
    /// is the right gate.
    static let vp9Available: Bool = {
        if #available(tvOS 26.2, iOS 19.0, macOS 16.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        }
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            let supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
            EngineLog.emit("[VTProbe] codec=vp09 hwSupported=\(supported)", category: .engine)
            return supported
        }
        return false
    }()

    /// True iff VideoToolbox can decode AV1 on the current device.
    /// Apple ships AV1 as a software decoder via integrated dav1d on
    /// tvOS 17+ / iOS 17+ / macOS 14+ — `VTIsHardwareDecodeSupported`
    /// returns false on every Apple TV (no chip ships HW AV1; the A17
    /// Pro / M3 only land in iPhone and Mac respectively) but AVPlayer
    /// still plays AV1 sources via dav1d. Gate on availability, not
    /// the HW check.
    static let av1Available: Bool = {
        if #available(tvOS 26.2, iOS 19.0, macOS 16.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            EngineLog.emit("[VTProbe] codec=av01 swSupported=true (dav1d)", category: .engine)
            return true
        }
        EngineLog.emit("[VTProbe] codec=av01 swSupported=false (pre-iOS17/tvOS17)", category: .engine)
        return false
    }()

}
