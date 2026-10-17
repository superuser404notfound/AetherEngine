// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreVideo

/// Per-frame Dolby Vision display metadata carried on a `CVPixelBuffer`.
///
/// The FEL composer reconstructs the 12-bit master on the GPU, but reconstruction only
/// restores *pixels*. The display side of Dolby Vision — L1 frame statistics, L2 creative
/// trims, L5 active area, L8/L9/L11 — is metadata that has to travel alongside the frame
/// so the compositor can drive the panel (or hand it to the TV over HDMI). On the
/// `AVPlayer` path VideoToolbox does this itself; on the `AVSampleBufferDisplayLayer` path
/// the buffers are ours, so the metadata is ours to attach.
///
/// ## The channel
/// CoreVideo and IOSurface both expose this channel under plain string keys
/// (`kCVImageBufferDolbyVisionRPUDataKey`, `kIOSurfaceDolbyVisionRPUData`), so it can be
/// driven with `CVBufferSetAttachment` with no private symbol linkage. It is still
/// SPI in spirit: the keys are not in any header, and nothing contractual says a
/// given OS release will consume them.
///
/// ## The payload, established empirically
/// Decoding a Profile 8.1 asset through `AVAssetReader` and dumping every attachment on the
/// output buffers shows VideoToolbox setting exactly two keys per frame — `DolbyVisionRPUData`
/// (a 188/189-byte `CFData` that changes frame to frame) and `DolbyCompatibilityID` (`1`) —
/// on both the `CVBuffer` and its backing `IOSurface`. Comparing those payloads byte-for-byte
/// against the source bitstream identifies them exactly: **the `unspec62` NAL with its 2-byte
/// HEVC NAL header (`0x7C 0x01`) removed and emulation-prevention bytes retained.** The
/// EPB-stripped RBSP is 176 bytes and does not match, which rules out the other plausible
/// reading.
///
/// That is precisely what `DoviRpuConverter.separateDualLayers` already produces: libdovi
/// converts the stream's Profile 7 RPU to Profile 8.1 with
/// `dovi_convert_rpu_with_mode(rpu, 2)`, which preserves the full DM payload (L1/L2/L5/L8/L9/L11)
/// and only rewrites the profile-specific container. The consumer on Apple platforms is the
/// private `HDRProcessing.framework` (`DolbyVisionComposer`, `DolbyVisionDisplayManagement`,
/// destination display types `…DolbyVisionTV` / `…LowLatencyDolbyVisionTV`).
///
/// ## What is verified
/// Verified on macOS: VideoToolbox *produces* these attachments in this exact format, and a
/// hand-set attachment propagates to the backing `IOSurface` and survives into `CMSampleBuffer`.
///
/// Verified on an Apple TV 4K (tvOS 27.0): the compositor **does** consume them from a
/// client-supplied buffer on the `AVSampleBufferDisplayLayer` path. The proof arrived the hard
/// way — as a `backboardd` crash report — but it is unambiguous, because the whole stack is in
/// the trace:
///
/// ```
/// CA::WindowServer::IOMFBServer::vsync_callback          (thread com.apple.coreanimation.display.external-0)
/// CA::Render::ImageQueue::forward_dm
/// CA::HDRProcessorInternal::create_surface_with_forward_dm
/// CA::HDRProcessorInternal::tonemap_surface_internal(__IOSurface*, …, __CFData const*, …)
/// -[HDRProcessor generateMSRColorConfigWithOperation:inputSurface:outputSurface:metadata:…]
/// -[HDRProcessor processFrameInternalWithLayer0:layer1:outout:metadata:…]
/// -[HDRProcessor applyDoVi81PolicyWithInput:WithRPU:]
/// ```
///
/// That is the *external display* CoreAnimation thread, on the vsync callback, pulling forward
/// display management off our `IOSurface` and applying Dolby Vision 8.1 policy with our RPU.
/// Nothing else puts `HDRProcessor` on that thread with a `__CFData` in hand. The attachment
/// channel works, and it reaches the HDMI output.
enum DoviDisplayMetadata {

    // MARK: Undocumented attachment keys
    //
    // These two strings are the ONLY undocumented platform contract the FEL route depends on, and
    // this is the only place they are spelled (`UndocumentedDolbyVisionKeysTests` fails the build if
    // either literal appears anywhere else in `Sources/`). Neither is in a public header; both are
    // what VideoToolbox itself attaches with `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata`,
    // and what tvOS's compositor reads back. No OS release promises to keep honouring them. If one
    // stops (the dv-pulse test in `Probes/DolbyVisionPulse` shows it: the pulse goes flat, like its "S" arm),
    // this is the one spot to change, and `preferDualLayerDolbyVision = false` is the fallback.

    /// `kCVImageBufferDolbyVisionRPUDataKey` / `kIOSurfaceDolbyVisionRPUData`. Undocumented.
    static let rpuDataKey = "DolbyVisionRPUData"
    /// `kCVImageBufferDolbyCompatibilityIDKey`. Undocumented.
    static let compatibilityIDKey = "DolbyCompatibilityID"

    /// Profile 8 compatibility ID 1 — HDR10-compatible base layer, which is what
    /// `dovi_convert_rpu_with_mode(rpu, 2)` targets and what the composed frame is.
    ///
    /// A **string**, deliberately. VideoToolbox emits this attachment as a `CFString` `"1"`
    /// (`NSTaggedPointerString`), not as a number, and tvOS depends on that: inside
    /// `-[HDRProcessor applyDoVi81PolicyWithInput:WithRPU:]` the value is parsed with
    /// `CFStringGetIntValue`, which messages `-length` on whatever it is handed. A `CFNumber`
    /// here does not respond to `-length`, so it raises `NSInvalidArgumentException` on
    /// backboardd's `com.apple.coreanimation.display.external-0` thread and aborts the render
    /// server — which takes this app down with it, roughly a third of a second after the first
    /// composed frame reaches the display. Confirmed twice on an Apple TV 4K (tvOS 27.0) and
    /// diagnosed from the resulting `backboardd-*.ips`; the type was then read back off
    /// VideoToolbox's own output to be sure. Do not "simplify" this to an integer.
    static let profile81CompatibilityID = "1"

    /// Attaches (or clears) the per-frame RPU on `buffer`.
    ///
    /// Pass `nil` to clear. Clearing matters: decoder output buffers are recycled from a
    /// CoreVideo pool, so a frame that has no RPU must actively remove any attachment left
    /// behind by a previous tenant rather than silently inherit stale trims.
    ///
    /// - Parameter nal: the Profile 8.1 `unspec62` NAL *including* its 2-byte header, as
    ///   returned by `dovi_write_unspec62_nalu`. The header is stripped here.
    static func attach(rpuNAL nal: [UInt8]?, to buffer: CVPixelBuffer) {
        #if DEBUG
        // Compiles out of Release entirely. Substitutes a pinned RPU when the consumption test
        // is armed; a no-op returning `nal` unchanged otherwise. See `DoviDisplayMetadataDebug`.
        let nal = DoviDisplayMetadataDebug.substitute(nal)
        #endif
        guard let payload = payload(fromNAL: nal) else {
            CVBufferRemoveAttachment(buffer, rpuDataKey as CFString)
            CVBufferRemoveAttachment(buffer, compatibilityIDKey as CFString)
            return
        }
        CVBufferSetAttachment(buffer, rpuDataKey as CFString, payload as CFData, .shouldPropagate)
        CVBufferSetAttachment(buffer, compatibilityIDKey as CFString, profile81CompatibilityID as CFString, .shouldPropagate)
    }

    /// Strips the `0x7C 0x01` unspec62 NAL header, leaving the RPU payload the attachment wants.
    /// Emulation-prevention bytes are deliberately left in place — that is the form VideoToolbox
    /// itself emits.
    static func payload(fromNAL nal: [UInt8]?) -> Data? {
        guard let nal, nal.count > 2 else { return nil }
        if nal[0] == 0x7C && nal[1] == 0x01 {
            return Data(nal.dropFirst(2))
        }
        // Already header-less (payload starts with the DV RPU prefix byte 0x19).
        if nal[0] == 0x19 { return Data(nal) }
        return nil
    }
}
#endif
