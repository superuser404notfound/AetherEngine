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

    /// True iff AVPlayer's HLS-fMP4 pipeline can decode AV1 on the
    /// current device.
    ///
    /// Gated strictly on `VTIsHardwareDecodeSupported` after running
    /// `VTRegisterSupplementalVideoDecoderIfAvailable`. Apple's
    /// marketing for "dav1d in macOS 14+ / iOS 17+" suggests AV1 SW
    /// decode is universally available — but in practice (verified
    /// 2026-05-14 on M1 macOS 26.4), `VTIsHardwareDecodeSupported`
    /// returns false and `AVURLAsset.isPlayable` returns false for
    /// AV1 sources on chips without HW AV1, even after explicit
    /// supplemental-decoder registration. Apple's HLS-fMP4 path
    /// requires HW AV1 in practice; the dav1d shipped on macOS / iOS
    /// is reachable via direct file playback on some devices but not
    /// via AVPlayer's HLS pipeline.
    ///
    /// Net effect:
    ///
    /// - M3+ Mac / iPhone 15 Pro+ / future HW-AV1 Apple TV chip →
    ///   `true` → AV1 sources route through the native AVPlayer path
    ///   with Atmos / DV / HDR signaling intact.
    /// - Everything else (M1 / M2 Mac, A12-A16 iPhone, all current
    ///   Apple TV chips) → `false` → AV1 routes through
    ///   `SoftwarePlaybackHost`'s dav1d pipeline.
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
