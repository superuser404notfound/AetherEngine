import AetherLibavcodec
import AetherLibavutil

/// Pure codec-and-field-order routing decision extracted from AetherEngine.load's dispatch so it is
/// unit-testable. Native carries HEVC, H.264 and HW-decodable AV1; every other video codec is
/// software. The #107 rule sits on top: interlaced H.264 goes software too, so DeinterlaceFilter
/// (bwdif) can deinterlace it. tvOS AVPlayer does not deinterlace, so 1080i broadcast otherwise combs.
enum VideoRoutingPolicy {

    /// Field orders that indicate interlaced content warranting software deinterlacing.
    static let interlacedFieldOrders: Set<AVFieldOrder> = [
        AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT
    ]

    /// Whether the Profile 7 dual-layer route is both requested and possible, which is everything that
    /// decides it except the stream's `el_type`. `requiresSoftwarePath` adds the FEL condition; the load
    /// asks this one first, so the `el_type` probe (a packet scan and a seek) only runs when its answer
    /// can change the route. A nil `canHardwareDecode` assumes hardware decode.
    static func dualLayerRouteIsWanted(
        codecID: AVCodecID,
        dvProfile: Int?,
        dolbyVisionHandling: DolbyVisionHandling,
        preferDualLayerDolbyVision: Bool,
        canHardwareDecode: (() -> Bool)?
    ) -> Bool {
        guard codecID == AV_CODEC_ID_HEVC, dvProfile == 7,
              preferDualLayerDolbyVision, DualLayerRouteDecision.isBuiltIn,
              dolbyVisionHandling == .automatic else { return false }
        return canHardwareDecode?() ?? true
    }

    /// True when a video codec must use the software decode path (SoftwarePlaybackHost) instead of
    /// native AVPlayer. `av1Available` is `VTCapabilityProbe.av1Available` (HW AV1 decode support).
    /// Evaluated only for AV1; registering its decoder must not delay unrelated formats.
    /// #150: `spsIndicatesInterlaced` (SPS frame_mbs_only_flag == 0) breaks the tie when the demuxer's
    /// field_order probe stays UNKNOWN; a concrete PROGRESSIVE probe analyzed actual frames and wins.
    /// A false positive costs an unnecessary SW decode (deint=interlaced passes progressive frames
    /// through untouched), never a wrong deinterlace. #232 narrows that class: on a seekable VOD
    /// source the declaration is checked against decoded frames before it routes (see
    /// `InterlaceProbe` and `routesSoftwareForDeclaredInterlace`).
    ///
    /// FFmpegBuild#1: the native side is an allowlist, not a denylist. `HLSVideoEngine` refuses
    /// anything that is not HEVC / H.264 / HW-decodable AV1 (`unsupportedCodec`), so a codec that is
    /// merely absent from the software list did not fall back, it failed the load. That took every
    /// codec nobody had enumerated (qtrle, ProRes, MJPEG, Theora, the QuickTime long tail) to the one
    /// path that cannot play it, while the software path decodes them. Only `AV_CODEC_ID_NONE` stays
    /// native by default: an audio-only source probes as NONE and has no video route to get wrong.
    static func requiresSoftwarePath(
        codecID: AVCodecID,
        fieldOrder: AVFieldOrder,
        av1Available: @autoclosure () -> Bool,
        spsIndicatesInterlaced: Bool = false,
        stereo3DType: AVStereo3DType? = nil,
        dvProfile: Int? = nil,
        dolbyVisionHandling: DolbyVisionHandling = .automatic,
        preferDualLayerDolbyVision: Bool = false,
        canHardwareDecode: (() -> Bool)? = nil,
        elType: String? = nil
    ) -> Bool {
        // Profile 7 FEL dual-layer Metal reconstruction routes to the software host pipeline
        // when preferDualLayerDolbyVision is enabled, dolbyVisionHandling is .automatic, and hardware decode is confirmed (or assumed true if closure
        // not provided).
        // Only elType == "FEL" routes to software; MEL, nil, or unknown stay native
        // (the 8.1 conversion where the display takes Dolby Vision, the HDR10 base layer where it does
        // not; the conversion is lossless only for MEL).
        // If dolbyVisionHandling is .baseLayerOnly, it also stays native (HDR10 base layer).
        if codecID == AV_CODEC_ID_HEVC, dvProfile == 7 {
            return elType == "FEL" && dualLayerRouteIsWanted(
                codecID: codecID,
                dvProfile: dvProfile,
                dolbyVisionHandling: dolbyVisionHandling,
                preferDualLayerDolbyVision: preferDualLayerDolbyVision,
                canHardwareDecode: canHardwareDecode
            )
        }
        switch codecID {
        case AV_CODEC_ID_NONE, AV_CODEC_ID_HEVC:
            return false
        case AV_CODEC_ID_AV1:
            return !av1Available()
        case AV_CODEC_ID_H264:
            if routesSoftwareForMultiviewCarriage(codecID: codecID, stereo3DType: stereo3DType) {
                return true
            }
            return routesSoftwareForDeclaredInterlace(
                codecID: codecID, fieldOrder: fieldOrder,
                spsIndicatesInterlaced: spsIndicatesInterlaced)
        default:
            return true
        }
    }

    /// #435: H.264 that carries both stereo views inside one track, which is how a 3D Blu-ray MVC remux
    /// is muxed: Matroska StereoMode 13 / 14 (`block_lr` / `block_rl`, both eyes in one block), reported
    /// by libavformat as stream-level `AV_PKT_DATA_STEREO3D` of type `AV_STEREO3D_FRAMESEQUENCE`. The
    /// dependent view's slices reference a subset SPS the base decoder does not have, so a decoder that
    /// only knows plain H.264 has to skip them, and VideoToolbox gets no say in that: it is handed whole
    /// samples with both views' NALs inside and renders nothing (reported as black video with audio
    /// playing). libavcodec skips the extension NALs and decodes the base view, which is the left eye and
    /// exactly the 2D fallback every non-3D player shows, so the software path is the one that produces a
    /// picture. Same shape as the interlaced and High 4:2:2 rules: native on paper, no picture in practice.
    ///
    /// Only these two carriages qualify. The frame-packed modes (side by side, top / bottom, checkerboard,
    /// row or column interleaved, anaglyph) are single self-contained pictures that decode natively and
    /// keep the native route; the host, not the engine, decides whether to crop an eye out of them.
    /// HEVC is excluded on purpose: MV-HEVC is Apple's own spatial-video format, and the native path
    /// plays its base layer.
    static func routesSoftwareForMultiviewCarriage(
        codecID: AVCodecID,
        stereo3DType: AVStereo3DType?
    ) -> Bool {
        guard codecID == AV_CODEC_ID_H264 else { return false }
        return stereo3DType == AV_STEREO3D_FRAMESEQUENCE
    }

    /// #232: true when the declared-interlace rule, and only that rule, is what sends this stream to
    /// software. That is the single routing decision `InterlaceProbe` is allowed to overrule, so the
    /// load path asks this before paying for a decode sample: a codec that is software-bound anyway
    /// (MPEG-2, VC-1, AV1 without HW) must not trigger a probe whose answer changes nothing.
    static func routesSoftwareForDeclaredInterlace(
        codecID: AVCodecID,
        fieldOrder: AVFieldOrder,
        spsIndicatesInterlaced: Bool
    ) -> Bool {
        guard codecID == AV_CODEC_ID_H264 else { return false }
        if interlacedFieldOrders.contains(fieldOrder) { return true }
        return fieldOrder == AV_FIELD_UNKNOWN && spsIndicatesInterlaced
    }

    /// #150: pure extradata classifier feeding `spsIndicatesInterlaced`. Accepts Annex-B (MPEG-TS) and
    /// avcC (MP4/MKV) extradata; anything unparseable classifies as not-interlaced so a missing or
    /// malformed config never forces the software path.
    static func spsIndicatesInterlaced(extradata: [UInt8]) -> Bool {
        guard let sps = H264SPS.spsNAL(fromExtradata: extradata) else { return false }
        return H264SPS.frameMbsOnly(fromNAL: sps) == false
    }

    /// Second-stage gate (#2): a codec that passed `requiresSoftwarePath` as native (H.264 / HEVC) but whose
    /// specific format VideoToolbox cannot HARDWARE-decode must still fall back to software, or the native
    /// AVPlayer path reaches readyToPlay and then renders nothing (H.264 High 4:2:2/4:4:4/High-10, HEVC Rext
    /// on Intel Macs / older Apple TV). Pure so it is unit-testable; the impure VT probe
    /// (`VTCapabilityProbe.canHardwareDecode`) is injected as the `canHardwareDecode` closure and only runs
    /// when the gate actually consults it. H.264 / HEVC and HW-routed AV1 consult this gate (AV1 by
    /// profile, see `av1FitsHardwareDecoder`); VP9 / etc. have their own routing above.
    ///
    /// #176: HEVC DV Profile 5 bypasses the gate entirely. The probe builds a plain-HEVC format description
    /// from the raw hvcC, which is not what the native path plays (dvh1 + dvcC, decoded by Apple's DV
    /// decoder), so a probe rejection there is not evidence the dvh1 route fails. And P5 has no compatible
    /// base layer: libavcodec decodes its IPT-PQ-c2 signal as YCbCr (green/purple cast), so the software
    /// path is never a correct fallback for it. P7 / P8.x keep the gate; their base layer is standard
    /// Main10 that the software path decodes with correct color.
    static func forcesSoftwareForUndecodableFormat(
        codecID: AVCodecID,
        dvProfile: Int?,
        canHardwareDecode: () -> Bool
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_HEVC where dvProfile == 5:
            return false
        case AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_AV1:
            return !canHardwareDecode()
        default:
            return false
        }
    }

    /// Whether a load consults `forcesSoftwareForUndecodableFormat` at all. H.264 / HEVC keep it VOD-only:
    /// broadcast live is hardware-decodable and forced-native live keeps its verified path. AV1 is
    /// consulted on live too (audit HLS-5 follow-up): a live AV1 High / Professional stream on a
    /// hardware-AV1 device has no native picture, and live AV1 already goes to the software host
    /// wherever hardware AV1 is missing entirely.
    static func consultsUndecodableFormatGate(codecID: AVCodecID, isLive: Bool) -> Bool {
        !isLive || codecID == AV_CODEC_ID_AV1
    }

    /// Audit HLS-5: Apple's hardware AV1 decoders (A17 Pro, M3 and later) decode Main profile only,
    /// 8/10-bit 4:2:0. `av1Available` is a codec-level answer, so High (4:4:4) and Professional
    /// (4:2:2, 12-bit) reached AVPlayer and rendered nothing while dav1d would have played them.
    /// The av1C states `seq_profile` in the top 3 bits of its second byte; the codecpar profile is the
    /// fallback. Unknown on both counts keeps the native route, like the H.264 / HEVC probe gap.
    static func av1FitsHardwareDecoder(av1C: [UInt8]?, codecparProfile: Int32) -> Bool {
        if let av1C, av1C.count >= 4, av1C[0] & 0x80 != 0 {
            return av1C[1] >> 5 == 0
        }
        guard codecparProfile >= 0 else { return true }
        return codecparProfile == 0
    }

    /// AE#461: the decode path a session ends up on, given what the routing concluded and what the
    /// host asked for. Pure so the override is unit-testable next to the decisions it overrules.
    ///
    /// One-way by construction: `.software` moves a session onto `SoftwarePlaybackHost`, and nothing
    /// moves one off it. Every route the engine sends to software it sends there because the native
    /// path cannot serve it (AV1 without hardware decode, VP9, a forward-only source, MVC carriage,
    /// a format VideoToolbox cannot hardware-decode), so a `.native` preference would buy a black
    /// screen and does not exist. The host's evidence is only ever "this native session is not
    /// decoding", never "this software session should be native".
    ///
    /// This does NOT suspend the guards that run after the routing decision. A source whose only
    /// signal is IPT-PQ-c2 still fails the load through `softwarePathCannotRepresent`, and a
    /// demuxed-audio live source still fails rather than playing silent: an override says which host
    /// serves the session, not what that host is able to represent.
    static func usesSoftwarePath(routedSoftware: Bool, preferred: DecodePath) -> Bool {
        switch preferred {
        case .automatic: return routedSoftware
        case .software: return true
        }
    }

    /// A URL source that turned out forward-only (the origin ignores `Range` and names no length, so
    /// the reader could only stream it front to back) is served the way a declared sequential origin
    /// is, when its container states a duration: native path, one linear pass, seeks unavailable.
    /// The software path it used to take cannot seek on such a source either, so the promotion costs
    /// nothing it had, and it buys what only the native path has: hardware decode, AVPlayer's
    /// buffering, and a picture on an AirPlay receiver (the software host renders on the device,
    /// only its audio follows the route).
    ///
    /// Only when the routing had already chosen native and the host did not ask for software, so
    /// the promotion never moves a session between hosts on its own. A custom reader is the host's
    /// to describe. Without a duration the segment plan has nothing to stride over, so that source
    /// keeps the software path.
    static func promotesForwardOnlySourceToSequential(
        isSourceSeekable: Bool,
        isLive: Bool,
        declaredSequential: Bool,
        isCustomSource: Bool,
        routedSoftware: Bool,
        preferred: DecodePath,
        containerDurationSeconds: Double
    ) -> Bool {
        !isSourceSeekable && !isLive && !declaredSequential && !isCustomSource
            && !routedSoftware && preferred == .automatic
            && containerDurationSeconds.isFinite && containerDurationSeconds > 0
    }

    /// #176 follow-up: DV variants whose only signal is IPT-PQ-c2 (no compatible base layer) cannot be
    /// color-correctly decoded by the software path: libavcodec / dav1d hand the IPT signal on as YCbCr,
    /// which renders with a green/purple cast. That is HEVC P5 and AV1 P10.0 (compat 0). P7 / P8.x /
    /// P10.1 / P10.2 / P10.4 base layers are self-contained HDR10 / SDR / HLG and stay software-eligible.
    /// Consulted after the final routing decision; a true here fails the load instead of playing wrong color
    /// (AV1 P10.0 without HW AV1 has no native fallback, HEVC P5 reaches software only off forward-only
    /// sources the native path cannot serve).
    static func softwarePathCannotRepresent(
        codecID: AVCodecID,
        dvProfile: Int?,
        dvBlCompatID: Int?,
        presentsDolbyVisionBaseLayer: Bool = false
    ) -> Bool {
        // The base-layer route exists for a record the VUI contradicts, and it is only taken when the
        // VUI names a YCbCr base (`dolbyVisionBaseLayerIsPresentable`), so the IPT class this guard
        // exists for never reaches it.
        if presentsDolbyVisionBaseLayer { return false }
        switch codecID {
        case AV_CODEC_ID_HEVC:
            return dvProfile == 5
        case AV_CODEC_ID_AV1:
            return dvProfile == 10 && dvBlCompatID == 0
        default:
            return false
        }
    }

    /// Whether a Dolby Vision source carries a base layer that can be presented on its own as HDR10 /
    /// HLG, i.e. what `LoadOptions.dolbyVisionHandling = .baseLayerOnly` can act on.
    ///
    /// For HEVC Profile 7 / 8.1 / 8.4 and AV1 Profile 10.1 / 10.4 the record says so (a compatibility
    /// id of 1 or 4, or the dual-layer profile whose base layer is HDR10 by definition); 8.2 and 10.2
    /// declare an SDR base and are admitted with them, though there the option moves nothing but the
    /// display criteria, the engine already serving that base layer as plain `hvc1` / `av01` (the
    /// predicate table in `DolbyVisionBaseLayerTests` pins that). Profile 5 and AV1 Profile 10.0 say the
    /// opposite: compatibility 0 is IPT-PQ-c2, a signal no YCbCr pipeline can show, which is why the
    /// software path refuses them (#176). The VUI is the tie-breaker for that class. A genuine Profile 5
    /// leaves `matrix_coeffs` and `transfer_characteristics` unspecified because IPT has no VUI code
    /// point, so a Profile 5 record over a VUI that declares BT.2020 YCbCr with a PQ or HLG transfer is
    /// a container contradicting its own bitstream, and the bitstream is the half a decoder consumes.
    /// The measured shape is a Profile 7 remux whose record was rewritten to Profile 5: the RPU still
    /// carries the NLQ and residual fields only Profile 7 has, the mapping is the identity, and the base
    /// layer is plain HDR10 with its own static metadata. Presenting that base layer is what every
    /// player that ignores the record does with it, and what this predicate admits.
    static func dolbyVisionBaseLayerIsPresentable(
        codecID: AVCodecID,
        dvProfile: Int?,
        dvBlCompatID: Int?,
        colorTransfer: AVColorTransferCharacteristic,
        colorMatrix: AVColorSpace
    ) -> Bool {
        guard let dvProfile else { return false }
        switch codecID {
        case AV_CODEC_ID_HEVC:
            switch dvProfile {
            case 7: return true
            case 8: return true
            case 5: return vuiDeclaresYCbCrHDRBase(colorTransfer: colorTransfer, colorMatrix: colorMatrix)
            default: return false
            }
        case AV_CODEC_ID_AV1:
            guard dvProfile == 10 else { return false }
            if let dvBlCompatID, dvBlCompatID != 0 { return true }
            return vuiDeclaresYCbCrHDRBase(colorTransfer: colorTransfer, colorMatrix: colorMatrix)
        default:
            return false
        }
    }

    /// A VUI that names a BT.2020 YCbCr base with an HDR transfer: what an HDR10 or HLG base layer
    /// declares, and what IPT-PQ-c2 cannot (its matrix has no code point, so a genuine Profile 5 leaves
    /// both unspecified).
    static func vuiDeclaresYCbCrHDRBase(
        colorTransfer: AVColorTransferCharacteristic,
        colorMatrix: AVColorSpace
    ) -> Bool {
        let hdrTransfer = colorTransfer == AVCOL_TRC_SMPTE2084 || colorTransfer == AVCOL_TRC_ARIB_STD_B67
        let ycbcrMatrix = colorMatrix == AVCOL_SPC_BT2020_NCL || colorMatrix == AVCOL_SPC_BT2020_CL
        return hdrTransfer && ycbcrMatrix
    }

    /// `LoadOptions.dolbyVisionHandling` resolved against the source: true when the host asked for the
    /// base layer AND the source has one to present. Both halves are here so the format clamp, the
    /// criteria request, the codec route and the software-path guard read one answer.
    static func presentsDolbyVisionBaseLayer(
        handling: DolbyVisionHandling,
        codecID: AVCodecID,
        dvProfile: Int?,
        dvBlCompatID: Int?,
        colorTransfer: AVColorTransferCharacteristic,
        colorMatrix: AVColorSpace
    ) -> Bool {
        guard handling == .baseLayerOnly else { return false }
        return dolbyVisionBaseLayerIsPresentable(
            codecID: codecID, dvProfile: dvProfile, dvBlCompatID: dvBlCompatID,
            colorTransfer: colorTransfer, colorMatrix: colorMatrix)
    }
}
