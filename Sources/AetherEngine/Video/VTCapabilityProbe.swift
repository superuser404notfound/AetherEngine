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

    /// True iff VideoToolbox can hardware-decode VP9 on the current
    /// device + OS combination. Lazily probed on first access.
    static let vp9Available: Bool = {
        return registerAndCheck(kCMVideoCodecType_VP9)
    }()

    /// True iff VideoToolbox can hardware-decode AV1 Profile 0 on the
    /// current device + OS combination. Lazily probed on first access.
    static let av1Available: Bool = {
        return registerAndCheck(kCMVideoCodecType_AV1)
    }()

    /// Register a supplemental decoder for `codecType` and check
    /// whether the hardware can decode it. Returns false if the
    /// registration fails or hardware decode is unsupported.
    private static func registerAndCheck(_ codecType: CMVideoCodecType) -> Bool {
        if #available(iOS 14.0, tvOS 14.0, macOS 11.0, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(codecType)
        }
        if #available(iOS 17.0, tvOS 17.0, macOS 14.0, *) {
            let supported = VTIsHardwareDecodeSupported(codecType)
            EngineLog.emit("[VTProbe] codec=\(fourccString(codecType)) hwSupported=\(supported)", category: .engine)
            return supported
        }
        // On older OS we can't probe reliably; assume not supported so
        // the native path falls through to aether.
        return false
    }

    private static func fourccString(_ code: CMVideoCodecType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        let chars = bytes.map { (b: UInt8) -> Character in
            (b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : "."
        }
        return String(chars)
    }
}
