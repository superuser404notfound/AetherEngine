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
    ///
    /// Earlier versions of this probe assumed Apple ships an AV1 SW
    /// decoder (dav1d) on every Apple platform from iOS 17 / tvOS 17 /
    /// macOS 14, and returned `true` unconditionally on those OS
    /// versions. That assumption is wrong for tvOS: dav1d ships only
    /// on iOS / macOS, and current Apple TV hardware has no HW AV1
    /// decoder, so AVPlayer fails mid-load with a decode error.
    ///
    /// Gate strictly on `VTIsHardwareDecodeSupported` (same shape as
    /// the VP9 probe). On tvOS this evaluates to false on every chip
    /// shipping today; the engine refuses AV1 sources up front with a
    /// clean `unsupportedCodec` instead of muxing them and letting
    /// AVPlayer blow up. If Apple ever ships HW AV1 on Apple TV (or
    /// adds a tvOS-side SW decoder that VT advertises post-supplemental-
    /// registration) this probe lights up automatically.
    static let av1Available: Bool = {
        if #available(tvOS 26.2, iOS 19.0, macOS 16.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            let supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
            EngineLog.emit("[VTProbe] codec=av01 hwSupported=\(supported)", category: .engine)
            return supported
        }
        EngineLog.emit("[VTProbe] codec=av01 hwSupported=false (pre-iOS17/tvOS17)", category: .engine)
        return false
    }()

}
