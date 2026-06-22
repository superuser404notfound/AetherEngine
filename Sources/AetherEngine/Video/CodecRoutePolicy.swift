import Foundation
import Libavcodec
import Libavutil

extension HLSVideoEngine {

    /// DV profile + base-layer compatibility classification per the
    /// table in DrHurt's KSPlayer notes (AetherEngine#1), Apple's HLS
    /// Authoring Spec, and Dolby's ETSI TS 103 572. HEVC profiles
    /// 5 / 8 carry HEVC streams; profile 10 carries AV1 streams.
    enum DVVariant {
        case none              // not DV
        case profile5          // HEVC P5  (IPT-PQ-c2, no base)     → dvh1 + PQ
        case profile81         // HEVC P8.1 with HDR10-compat base  → dvh1 + PQ  (on DV display)
        case profile84         // HEVC P8.4 with HLG-compat base    → hvc1 + HLG + SUPPLEMENTAL dvh1/db4h
        case profile7          // HEVC P7 dual-layer (BL = HDR10)   → hvc1 + PQ (BL only)
        case profile82         // HEVC P8.2 with SDR-compat base    → play Rec.709 base as plain hvc1
        case av1Profile10      // AV1 P10.0 (no base)               → dav1 + PQ
        case av1Profile101     // AV1 P10.1 with HDR10-compat base  → dav1 + PQ
        case av1Profile104     // AV1 P10.4 with HLG-compat base    → av01 + HLG + SUPPLEMENTAL dav1
        case av1Profile102     // AV1 P10.2 with SDR-compat base    → play Rec.709 base as plain av01
        case unknown           // anything else                     → reject
    }

    // MARK: - DV / HDR detection

    private func doviConfigRecord(
        from codecpar: UnsafePointer<AVCodecParameters>
    ) -> AVDOVIDecoderConfigurationRecord? {
        let count = Int(codecpar.pointee.nb_coded_side_data)
        guard count > 0, let sideData = codecpar.pointee.coded_side_data else {
            return nil
        }
        for i in 0..<count {
            let item = sideData.advanced(by: i).pointee
            guard item.type == AV_PKT_DATA_DOVI_CONF else { continue }
            guard let raw = item.data, item.size >= 8 else { continue }
            return raw.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self,
                capacity: 1
            ) { $0.pointee }
        }
        return nil
    }

    private func classifyDVVariant(
        _ record: AVDOVIDecoderConfigurationRecord?,
        codecID: AVCodecID
    ) -> DVVariant {
        guard let r = record else { return .none }
        let profile = Int(r.dv_profile)
        let compat = Int(r.dv_bl_signal_compatibility_id)

        // HEVC + DV: profiles 5, 7, 8 per Dolby's ETSI TS 103 572.
        // Profile 9 is AVC+DV which AetherEngine doesn't support
        // (AVPlayer accepts AVC but not AVC+DV per DrHurt's matrix).
        if codecID == AV_CODEC_ID_HEVC {
            if profile == 5 { return .profile5 }
            if profile == 7 { return .profile7 }
            if profile == 8 {
                switch compat {
                case 1: return .profile81
                case 2: return .profile82
                case 4: return .profile84
                default: return .profile81  // P8.6 etc → treat as P8.1
                }
            }
            return .unknown
        }

        // AV1 + DV: profile 10 per Dolby's spec. compat == 0 means
        // P10.0 (no base layer); compat == 1 / 2 / 4 mirror P8's HDR10
        // / SDR / HLG base-layer compatibility flags.
        if codecID == AV_CODEC_ID_AV1 {
            if profile == 10 {
                switch compat {
                case 0: return .av1Profile10
                case 1: return .av1Profile101
                case 2: return .av1Profile102
                case 4: return .av1Profile104
                default: return .av1Profile10
                }
            }
            return .unknown
        }

        return .unknown
    }

    /// Codec + DV routing decision computed once at start(); consumed by the producer (codec tag override)
    /// and the playlist builder (CODECS, SUPPLEMENTAL-CODECS, VIDEO-RANGE).
    struct CodecRoute {
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let primaryCodecs: String
        let supplementalCodecs: String?
        /// Drop dvcC before write_header. Used for P7 (BL routed as plain HDR10; VT rejects dvcC with
        /// -12906) and P8.1/P8.4 on non-DV panels (tvOS 26 filter rejects dvvC + plain hvc1 with -11868).
        let stripDolbyVisionMetadata: Bool
        /// Per-packet RPU rewrite P7 -> P8.1 via DoviRpuConverter; true only for P7 on a DV panel.
        let convertP7ToProfile81: Bool
        /// Rewrite container dvcC to P8.1 in init.mp4: P7-on-DV (alongside convertP7ToProfile81)
        /// and the "P8.6" malformed-compat case (#53). Mutually exclusive with stripDolbyVisionMetadata.
        let rewriteDoviConfigTo81: Bool
        let dvVariant: DVVariant

        init(
            codecTagOverride: String?,
            videoRange: HLSVideoRange,
            primaryCodecs: String,
            supplementalCodecs: String?,
            stripDolbyVisionMetadata: Bool,
            convertP7ToProfile81: Bool,
            rewriteDoviConfigTo81: Bool = false,
            dvVariant: DVVariant
        ) {
            self.codecTagOverride = codecTagOverride
            self.videoRange = videoRange
            self.primaryCodecs = primaryCodecs
            self.supplementalCodecs = supplementalCodecs
            self.stripDolbyVisionMetadata = stripDolbyVisionMetadata
            self.convertP7ToProfile81 = convertP7ToProfile81
            self.rewriteDoviConfigTo81 = rewriteDoviConfigTo81
            self.dvVariant = dvVariant
        }
    }

    /// PQ and HLG are distinct manifest values; collapsing both to PQ caused wrong EOTF on HLG panels.
    private func manifestVideoRange(_ codecpar: UnsafePointer<AVCodecParameters>) -> HLSVideoRange {
        switch codecpar.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084:    return .pq
        case AVCOL_TRC_ARIB_STD_B67: return .hlg
        default:                     return .sdr
        }
    }

    func resolveCodecRoute(
        codecpar: UnsafePointer<AVCodecParameters>
    ) throws -> CodecRoute {
        let codecID = codecpar.pointee.codec_id

        if codecID == AV_CODEC_ID_H264 {
            let profileIDC = Int(codecpar.pointee.profile)
            let levelIDC = Int(codecpar.pointee.level)
            let safeProfile = profileIDC > 0 ? profileIDC : 100  // High
            let safeLevel = levelIDC > 0 ? levelIDC : 40         // 4.0
            // AVC+DV P9: no Apple AVC+DV decoder; strip dvcC so muxer writes clean avc1 (dvvC trips -11868).
            let hasDV = doviConfigRecord(from: codecpar) != nil
            if hasDV {
                EngineLog.emit(
                    "[HLSVideoEngine] AVC+DV (Profile 9) detected; "
                    + "no Apple AVC+DV decoder, playing Rec.709 base as "
                    + "plain avc1 (DV config stripped)",
                    category: .session
                )
            }
            return CodecRoute(
                codecTagOverride: "avc1",
                videoRange: manifestVideoRange(codecpar),
                primaryCodecs: String(format: "avc1.%02X%02X%02X", safeProfile, 0, safeLevel),
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: hasDV,
                convertP7ToProfile81: false,
                dvVariant: .none
            )
        }

        if codecID == AV_CODEC_ID_AV1 {
            let dvRecord = effectiveDvMode ? doviConfigRecord(from: codecpar) : nil
            let dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_AV1)

            let av1ProfileRaw = Int(codecpar.pointee.profile)
            let av1Profile = (av1ProfileRaw >= 0 && av1ProfileRaw <= 2) ? av1ProfileRaw : 0
            let av1LevelRaw = Int(codecpar.pointee.level)
            // seq_level_idx 0..23; default 8 = level 4.0 (~4K@30fps).
            let av1Level = (av1LevelRaw >= 0 && av1LevelRaw <= 23) ? av1LevelRaw : 8
            let bitDepthRaw = Int(codecpar.pointee.bits_per_raw_sample)
            let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
            let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
            let dvLevelStr = String(format: "%02d", dvLevel)

            switch dvVariant {
            case .av1Profile10:
                // P10.0: DV-only (no base layer); same shape as HEVC P5.
                return CodecRoute(
                    codecTagOverride: "dav1",
                    videoRange: .pq,
                    primaryCodecs: "dav1.10.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: false,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            case .av1Profile101:
                // P10.1: HDR10-compat base; analogous to HEVC P8.1.
                return CodecRoute(
                    codecTagOverride: "dav1",
                    videoRange: .pq,
                    primaryCodecs: "dav1.10.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: false,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            case .av1Profile104:
                // P10.4: HLG-compat base; av01 + SUPPLEMENTAL dav1/db4h. Analogous to HEVC P8.4.
                let bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                let primary = String(
                    format: "av01.%d.%02dM.%02d.0.111.09.18.09.0",
                    av1Profile, av1Level, bd
                )
                return CodecRoute(
                    codecTagOverride: "av01",
                    videoRange: .hlg,
                    primaryCodecs: primary,
                    supplementalCodecs: "dav1.10.\(dvLevelStr)/db4h",
                    stripDolbyVisionMetadata: false,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            case .unknown:
                let p = Int(dvRecord?.dv_profile ?? 0)
                let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
                throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
            case .none, .av1Profile102:
                // P10.2 (SDR-compat base): no Apple P10.2 DV decoder; strip dvcC and play as plain av01.
                if dvVariant == .av1Profile102 {
                    EngineLog.emit(
                        "[HLSVideoEngine] AV1 DV Profile 10.2 (SDR base) "
                        + "detected; not DV-routable, playing Rec.709 base "
                        + "as plain av01 (DV config stripped)",
                        category: .session
                    )
                }
                let trc = codecpar.pointee.color_trc
                let videoRange: HLSVideoRange
                let cp: Int, tc: Int, mc: Int, bd: Int
                if trc == AVCOL_TRC_ARIB_STD_B67 {
                    videoRange = .hlg; cp = 9; tc = 18; mc = 9
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                } else if trc == AVCOL_TRC_SMPTE2084 {
                    videoRange = .pq; cp = 9; tc = 16; mc = 9
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                } else {
                    videoRange = .sdr; cp = 1; tc = 1; mc = 1
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 8
                }
                let primary = String(
                    format: "av01.%d.%02dM.%02d.0.111.%02d.%02d.%02d.0",
                    av1Profile, av1Level, bd, cp, tc, mc
                )
                return CodecRoute(
                    codecTagOverride: "av01",
                    videoRange: videoRange,
                    primaryCodecs: primary,
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: dvVariant == .av1Profile102,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            // HEVC DV variants can't reach this switch (classifyDVVariant
            // is called with AV_CODEC_ID_AV1) but Swift's exhaustivity
            // check needs explicit handling.
            case .profile5, .profile81, .profile84, .profile7, .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
            }
        }

        // HEVC path. Always classify DV: P5 needs dvh1 even on non-DV panels because AVPlayer's system
        // DV decoder tonemaps IPT-PQ-c2 internally; without dvh1 IPT chroma reads as YCbCr (green/purple
        // cast, AetherEngine#4 Build 160+163 / DrHurt#19). Routing forces media playlist for P5-on-non-DV.
        let dvRecord = doviConfigRecord(from: codecpar)
        let dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_HEVC)

        if let r = dvRecord {
            let cp = Int(codecpar.pointee.color_primaries.rawValue)
            let trc = Int(codecpar.pointee.color_trc.rawValue)
            let csp = Int(codecpar.pointee.color_space.rawValue)
            EngineLog.emit(
                "[HLSVideoEngine] DV source: profile=\(r.dv_profile) "
                + "compat=\(r.dv_bl_signal_compatibility_id) "
                + "level=\(r.dv_level) rpu=\(r.rpu_present_flag) "
                + "el=\(r.el_present_flag) bl=\(r.bl_present_flag) "
                + "color_primaries=\(cp) color_trc=\(trc) color_space=\(csp)",
                category: .session
            )
        }

        let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
        let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
        let hevcLevelRaw = Int(codecpar.pointee.level)
        let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
        let dvLevelStr = String(format: "%02d", dvLevel)

        switch dvVariant {
        case .profile5:
            // P5: DV-only (IPT-PQ-c2, no base). dvh1 always required; see HEVC-path comment above.
            // Bare dvh1.05 in master playlist fires -11868 on non-DV panels; routing forces media playlist.
            return CodecRoute(
                codecTagOverride: "dvh1",
                videoRange: .pq,
                primaryCodecs: "dvh1.05.\(dvLevelStr)",
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: false,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        case .profile81:
            // P8.1 (HDR10-compat base).
            // DV panel: hvc1 + dvvC (muxer writes dvvC automatically) + SUPPLEMENTAL dvh1.08.XX/db1p.
            //   db1p required; without it AVPlayer treats variant as plain HDR10 and DV never engages.
            // Non-DV panel: strip dvvC (hvc1 + dvvC trips -11868 even without SUPPLEMENTAL, 2026-05-26).
            // "P8.6" malformed compat (#53): rewriteDoviConfigTo81 normalizes container to compat=1;
            //   on non-DV panel the strip path handles it without rewrite.
            let compat = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 1)
            let needsCompatRewrite = compat != 1
            let supplemental: String?
            let strip: Bool
            if effectiveDvMode {
                supplemental = "dvh1.08.\(dvLevelStr)/db1p"
                strip = false
            } else {
                supplemental = nil
                strip = true
            }
            if needsCompatRewrite && effectiveDvMode {
                EngineLog.emit(
                    "[HLSVideoEngine] HEVC DV Profile 8 with invalid compat="
                    + "\(compat) (\"P8.6\"); normalizing container dvcC to "
                    + "P8.1 (compat=1) for AVPlayer on DV panel",
                    category: .session
                )
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .pq,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: supplemental,
                stripDolbyVisionMetadata: strip,
                convertP7ToProfile81: false,
                rewriteDoviConfigTo81: needsCompatRewrite && effectiveDvMode,
                dvVariant: dvVariant
            )
        case .profile84:
            // P8.4 (HLG-compat base). Mirrors P8.1 routing.
            // DV panel: hvc1 + dvvC + SUPPLEMENTAL dvh1.08.XX/db4h. db4h marks HLG-base for AVKit criteria.
            // Non-DV panel: strip dvvC (same -11868 risk as P8.1). Plain HLG plays + tonemaps on all panels.
            // Note: dvh1 sample entry is never valid for HLG-base (AVPlayer rejects it, DrHurt#4 Build 160).
            let supplemental: String?
            let strip: Bool
            if effectiveDvMode {
                supplemental = "dvh1.08.\(dvLevelStr)/db4h"
                strip = false
            } else {
                supplemental = nil
                strip = true
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .hlg,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: supplemental,
                stripDolbyVisionMetadata: strip,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        case .profile7:
            // P7 dual-layer (UHD-BD). DV panel: convert RPU P7->P8.1 per-packet (DoviRpuConverter),
            // drop EL, rewrite container dvcC to P8.1, route as hvc1 + SUPPLEMENTAL dvh1.08.XX/db1p.
            // Non-DV panel: no Apple P7 decoder; strip dvcC, play PQ HEVC HDR10 base.
            let supplemental: String?
            let strip: Bool
            if effectiveDvMode {
                supplemental = "dvh1.08.\(dvLevelStr)/db1p"
                strip = false
            } else {
                supplemental = nil
                strip = true
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .pq,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: supplemental,
                stripDolbyVisionMetadata: strip,
                convertP7ToProfile81: effectiveDvMode,
                rewriteDoviConfigTo81: effectiveDvMode,
                dvVariant: dvVariant
            )
        case .unknown:
            let p = Int(dvRecord?.dv_profile ?? 0)
            let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
            throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
        case .none, .profile82:
            // P8.2 (SDR-compat base): no Apple P8.2 DV decoder; strip dvcC and play as plain hvc1.
            if dvVariant == .profile82 {
                EngineLog.emit(
                    "[HLSVideoEngine] HEVC DV Profile 8.2 (SDR base) "
                    + "detected; not DV-routable, playing Rec.709 base as "
                    + "plain hvc1 (DV config stripped)",
                    category: .session
                )
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: manifestVideoRange(codecpar),
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: dvVariant == .profile82,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        // AV1 DV variants unreachable here (classify was called with
        // AV_CODEC_ID_HEVC) but exhaustivity needs them.
        case .av1Profile10, .av1Profile101, .av1Profile104, .av1Profile102:
            throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
        }
    }
}
