import Foundation
import VideoToolbox
import CoreMedia
import Libavcodec
import Libavutil

/// Cached VTIsHardwareDecodeSupported probe after VTRegisterSupplementalVideoDecoderIfAvailable. Cached on first access; registration is idempotent.
enum VTCapabilityProbe {

    /// True only when AVPlayer's HLS-fMP4 pipeline can HW-decode AV1. Apple's dav1d (macOS 14+/iOS 17+) is reachable via direct file playback but NOT via AVPlayer HLS in practice (verified 2026-05-14 on M1 macOS 26.4): VTIsHardwareDecodeSupported returns false, AVURLAsset.isPlayable returns false. False routes to SoftwarePlaybackHost/dav1d.
    static let av1Available: Bool = {
        if #available(tvOS 26.2, iOS 26.2, macOS 16.0, *) {
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

    /// True when VideoToolbox can build a HARDWARE-accelerated decompression session for this exact
    /// H.264 / HEVC format (profile + chroma + bit depth encoded in the avcC / hvcC config). AV1's coarse
    /// `av1Available` gate has no per-format analogue because H.264 / HEVC decodability is profile-specific:
    /// AVPlayer accepts the HLS CODECS string for H.264 High 4:2:2 / 4:4:4 / High-10 and HEVC Rext, but the
    /// underlying VT decoder only exists on some silicon (Apple Silicon: yes; Intel Macs / older Apple TV: no
    /// HW decoder), so the item reaches readyToPlay then renders nothing (issue #2, DrHurt Intel Mac mini).
    /// Callers route `false` to the SoftwarePlaybackHost (libavcodec), which decodes these profiles fine.
    ///
    /// Returns `true` (keep the native path) whenever the format can't be classified (no extradata, Annex-B
    /// extradata, format-description build failure), so a probe gap never wrongly forces the software path.
    /// The throwaway session is invalidated immediately; the whole probe costs well under a millisecond and
    /// runs once per load.
    static func canHardwareDecode(codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        let codecID = codecpar.pointee.codec_id
        let vtCodecType: CMVideoCodecType
        let atomKey: String
        switch codecID {
        case AV_CODEC_ID_H264: vtCodecType = kCMVideoCodecType_H264; atomKey = "avcC"
        case AV_CODEC_ID_HEVC: vtCodecType = kCMVideoCodecType_HEVC; atomKey = "hvcC"
        default: return true  // only H.264 / HEVC use this gate; other codecs route via their own policy
        }

        guard let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else {
            return true  // nothing to classify; don't force software off a missing config
        }
        // avcC / hvcC config records start with a configurationVersion byte (0x01). Annex-B extradata starts
        // with a 0x00 00 (00) 01 start code and can't seed the atom-based format description, so keep native.
        if extradata.pointee == 0x00 { return true }

        let configData = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        var formatDescription: CMVideoFormatDescription?
        let atoms: NSDictionary = [atomKey: configData]
        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
        ]
        let fdStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: vtCodecType,
            width: codecpar.pointee.width,
            height: codecpar.pointee.height,
            extensions: extensions,
            formatDescriptionOut: &formatDescription
        )
        guard fdStatus == noErr, let formatDesc = formatDescription else { return true }

        // Require hardware, matching HardwareVideoDecoder's session spec: a format VT can only software-decode
        // is exactly what we want to hand to libavcodec instead (predictable path, no black screen).
        let decoderSpec: NSDictionary = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec,
            imageBufferAttributes: nil,  // don't constrain output; probe decodability, not pixel conversion
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if let session { VTDecompressionSessionInvalidate(session) }
        let ok = status == noErr && session != nil
        EngineLog.emit(
            "[VTProbe] canHardwareDecode codec=\(codecID.rawValue) "
            + "\(codecpar.pointee.width)x\(codecpar.pointee.height) -> \(ok) (status=\(status))",
            category: .engine
        )
        return ok
    }

}
