import Foundation
import AetherLibavcodec
import AetherLibavutil

extension HLSVideoEngine {

    /// DV profile + base-layer compatibility classification per the
    /// table in DrHurt's KSPlayer notes (AetherEngine#1), Apple's HLS
    /// Authoring Spec, and Dolby's ETSI TS 103 572. HEVC profiles
    /// 5 / 8 carry HEVC streams; profile 10 carries AV1 streams.
    enum DVVariant {
        case none              // not DV
        case profile5          // HEVC P5  (IPT-PQ-c2, no base)     → dvh1 + PQ
        case profile20         // HEVC P20 (MV-HEVC 3D, P5 base)    → dvh1.20 in 3D, served as P5 in 2D
        case profile81         // HEVC P8.1 with HDR10-compat base  → dvh1 + PQ  (on DV display)
        case profile84         // HEVC P8.4 with HLG-compat base    → hvc1 + HLG + SUPPLEMENTAL dvh1/db4h
        case profile7          // HEVC P7 dual-layer (BL = HDR10)   → RPU converted to 8.1, EL dropped, routed as P8.1
        case profile82         // HEVC P8.2 with SDR-compat base    → play Rec.709 base as plain hvc1
        case av1Profile10      // AV1 P10.0 (no base)               → dav1 + PQ
        case av1Profile101     // AV1 P10.1 with HDR10-compat base  → av01 + PQ + SUPPLEMENTAL dav1
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
            if profile == 20 { return .profile20 }
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
        /// What the muxer does with the source dvcC on the way into init.mp4.
        /// See `MP4SegmentMuxer.DoviConfigPolicy`.
        let doviConfig: MP4SegmentMuxer.DoviConfigPolicy
        /// Per-packet RPU rewrite P7 -> P8.1 via DoviRpuConverter; true for every P7 not served as its base layer.
        let convertP7ToProfile81: Bool
        let dvVariant: DVVariant

        init(
            codecTagOverride: String?,
            videoRange: HLSVideoRange,
            primaryCodecs: String,
            supplementalCodecs: String?,
            doviConfig: MP4SegmentMuxer.DoviConfigPolicy,
            convertP7ToProfile81: Bool,
            dvVariant: DVVariant
        ) {
            self.codecTagOverride = codecTagOverride
            self.videoRange = videoRange
            self.primaryCodecs = primaryCodecs
            self.supplementalCodecs = supplementalCodecs
            self.doviConfig = doviConfig
            self.convertP7ToProfile81 = convertP7ToProfile81
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

    /// Build the RFC 6381 codecs string for a plain (non-DV) HEVC track from its hvcC config-record
    /// header (bytes 1..12 = profile_tier_level + general_level_idc). Matches the GPAC / ffmpeg form,
    /// e.g. 8-bit Main L3.1 -> `hvc1.1.6.L93.90`, 10-bit Main10 -> `hvc1.2.4.L<level>.<constraints>`.
    /// Returns nil when the buffer is not a parseable hvcC (configurationVersion != 1, or too short),
    /// so the caller can fall back.
    ///
    /// AE#187: the `.none` / `.profile82` branch hardcoded `hvc1.2.4.L<level>` (Main10, profile_idc=2)
    /// for EVERY plain HEVC stream, mis-declaring an 8-bit Main source as Main10. The device path
    /// (media-direct, no CODECS) hid it, but once HEVC is signaled through a master (below) a strict
    /// Apple TV rejects the Main10 declaration against the Main hvcC in the init; macOS / the Simulator
    /// tolerate the mismatch. Deriving the string from the actual hvcC keeps master and init consistent.
    /// AE#674: the highest `general_level_idc` a master's CODECS declares (5.1, which covers 2160p60).
    /// Encoders stamp 5.2 (156) on 1080p24 streams, and AVPlayer screens a master variant's declared
    /// level against the device: an Apple TV 4K refuses 5.2 with -11848 / CoreMedia -15517 on every
    /// attempt, DV and reduced master alike, while the same bytes decode media-direct, where nothing
    /// is declared. The init's hvcC keeps the stated level; only the attribute is capped. A stream
    /// that genuinely needs more would end on the media playlist anyway, so capping costs it nothing.
    static let maxDeclaredHEVCLevel = 153

    static func hevcCodecsString(
        fromConfigRecord hvcC: [UInt8],
        sampleEntry: String = "hvc1"
    ) -> String? {
        // Need the fixed header through general_level_idc (byte 12); configurationVersion must be 1.
        guard hvcC.count >= 13, hvcC[0] == 1 else { return nil }
        let b1 = hvcC[1]
        let profileSpace = (b1 >> 6) & 0x3
        let tierFlag = (b1 >> 5) & 0x1
        let profileIDC = b1 & 0x1F
        let compat = (UInt32(hvcC[2]) << 24) | (UInt32(hvcC[3]) << 16)
            | (UInt32(hvcC[4]) << 8) | UInt32(hvcC[5])
        let constraintBytes = Array(hvcC[6..<12])   // general_constraint_indicator_flags, 6 bytes
        let levelIDC = hvcC[12]

        let spacePrefix: String
        switch profileSpace {
        case 1: spacePrefix = "A"
        case 2: spacePrefix = "B"
        case 3: spacePrefix = "C"
        default: spacePrefix = ""
        }
        // Compatibility flags: RFC 6381 / ISO 14496-15 Annex E write them in REVERSE bit order
        // (general_profile_compatibility_flag[31] as the most significant bit), then as hex with
        // leading zeroes omitted. Trimming trailing zeroes off the stored value only coincides with
        // that for nibble-palindromic values like 0x60000000 ("6"); a real Main10 record stores
        // 0x20000000, which must print as "4" (MP4Box, Dolby's own P8.1 manifest), not "2".
        var reversedCompat: UInt32 = 0
        for i in 0..<32 where (compat >> (31 - i)) & 1 == 1 { reversedCompat |= 1 << i }
        let compatHex = String(reversedCompat, radix: 16)
        // Constraint bytes: each as 2-hex, dot-joined, trailing all-zero bytes dropped (0x90,0,0,0,0,0 -> "90").
        var trimmedConstraints = constraintBytes
        while let last = trimmedConstraints.last, last == 0 { trimmedConstraints.removeLast() }
        let tier = tierFlag == 1 ? "H" : "L"
        let declaredLevel = min(Int(levelIDC), maxDeclaredHEVCLevel)
        var s = "\(sampleEntry).\(spacePrefix)\(profileIDC).\(compatHex).\(tier)\(declaredLevel)"
        if !trimmedConstraints.isEmpty {
            s += "." + trimmedConstraints.map { String(format: "%02x", $0) }.joined(separator: ".")
        }
        return s
    }

    /// Same string read off the first SPS of Annex-B extradata (MPEG-TS, Annex-B Matroska), which
    /// carries no hvcC. The SPS's profile_tier_level general part is byte for byte the hvcC header
    /// bytes 1..12, and it is what the mp4 muxer builds the init's hvcC from, so the two agree.
    /// Audit HLS-3: without this an 8-bit Main TS source fell back to the Main10 declaration.
    static func hevcCodecsString(
        fromAnnexBExtradata extradata: [UInt8],
        sampleEntry: String = "hvc1"
    ) -> String? {
        guard let sps = VideoConfigRecord.splitAnnexBNALs(extradata)
            .first(where: { $0.count > 2 && (($0[0] >> 1) & 0x3F) == 33 }) else { return nil }
        // Past the 2-byte NAL header: one byte of vps_id / max_sub_layers / nesting, then the PTL.
        let rbsp = H264SPS.unescape(Array(sps.dropFirst(2)))
        guard rbsp.count >= 13 else { return nil }
        return hevcCodecsString(fromConfigRecord: [1] + Array(rbsp[1...12]), sampleEntry: sampleEntry)
    }

    /// RFC 6381 `avc1.PPCCLL` read straight off the avcC configuration record, which states all three
    /// bytes outright: AVCProfileIndication, profile_compatibility (the constraint_set flags) and
    /// AVCLevelIndication are bytes 1..3. Same reasoning as `hevcCodecsString`: the record is what the
    /// muxer writes into the sample entry, so deriving the attribute from anything else invites the
    /// two to disagree. nil for Annex-B extradata (MPEG-TS carries no record; byte 0 is a start code,
    /// not configurationVersion 1) and for a record too short to hold the three bytes.
    static func avcCodecsString(fromConfigRecord avcC: [UInt8]) -> String? {
        guard avcC.count >= 4, avcC[0] == 1 else { return nil }
        return String(format: "avc1.%02X%02X%02X", avcC[1], avcC[2], avcC[3])
    }

    /// Same three bytes read off the SPS instead, which is what MPEG-TS carries in place of a record:
    /// profile_idc, the constraint_set flags byte and level_idc are the first three bytes of the RBSP,
    /// right behind the NAL header. This keeps the live path exact rather than reconstructing the
    /// compatibility byte from the two flags libavcodec preserved. nil unless the NAL really is an SPS
    /// (type 7) and long enough to hold them.
    static func avcCodecsString(fromSPSNAL sps: [UInt8]) -> String? {
        guard sps.count >= 4, (sps[0] & 0x1F) == 7 else { return nil }
        return String(format: "avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
    }

    /// Fallback for sources with no avcC. `AVCodecParameters.profile` is NOT a bare profile_idc:
    /// libavcodec ORs the constraint flags into the high bits, so Constrained Baseline arrives as
    /// `66|AV_PROFILE_H264_CONSTRAINED` = 578 and the Intra profiles as `idc|AV_PROFILE_H264_INTRA`.
    /// Formatting that raw overflowed `%02X` to three digits and produced `avc1.2420028`, seven hex
    /// digits where the grammar defines six. Masking recovers profile_idc, and the two flags map back
    /// into the compatibility byte they came from (constraint_set1 is bit 6, constraint_set3 is bit 4),
    /// so the fallback states them instead of the hardcoded zero the branch used to emit.
    static func avcCodecsString(profile: Int32, level: Int32) -> String {
        let raw = profile > 0 ? Int(profile) : 100   // High
        let safeLevel = level > 0 ? Int(level) : 40  // 4.0
        var compatibility = 0
        if raw & 0x200 != 0 { compatibility |= 0x40 }   // AV_PROFILE_H264_CONSTRAINED -> constraint_set1
        if raw & 0x800 != 0 { compatibility |= 0x10 }   // AV_PROFILE_H264_INTRA       -> constraint_set3
        return String(format: "avc1.%02X%02X%02X", raw & 0xFF, compatibility, safeLevel)
    }

    /// The source states these bytes; prefer whichever form it carries them in (avcC, then the SPS a
    /// TS stream carries instead), and only reconstruct from the codecpar fields when it carries
    /// neither. Mirrors `plainHEVCCodecs`. Deriving the attribute from the same extradata the muxer
    /// stream-copies into the sample entry is what keeps the manifest and the init from disagreeing.
    private func avcCodecs(codecpar: UnsafePointer<AVCodecParameters>) -> String {
        if let ed = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 {
            let bytes = Array(UnsafeBufferPointer(
                start: ed, count: Int(codecpar.pointee.extradata_size)))
            if let derived = Self.avcCodecsString(fromConfigRecord: bytes) {
                return derived
            }
            // Annex-B (MPEG-TS): no record, but the SPS states the same three bytes.
            if let sps = H264SPS.spsNAL(fromExtradata: bytes),
               let derived = Self.avcCodecsString(fromSPSNAL: sps) {
                return derived
            }
        }
        return Self.avcCodecsString(
            profile: codecpar.pointee.profile, level: codecpar.pointee.level)
    }

    /// Derive the HEVC CODECS string from the source hvcC (or the SPS of Annex-B extradata) when
    /// parseable, else fall back to the Main10 form. Every hvc1 route uses it, the DV ones included
    /// (AE#674): their base layer is the hvcC in the init, so the master declares what that states.
    private func plainHEVCCodecs(
        codecpar: UnsafePointer<AVCodecParameters>,
        fallbackLevel hevcLevel: Int
    ) -> String {
        if let ed = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 {
            let bytes = Array(UnsafeBufferPointer(
                start: ed, count: Int(codecpar.pointee.extradata_size)))
            if let derived = Self.hevcCodecsString(fromConfigRecord: bytes)
                ?? Self.hevcCodecsString(fromAnnexBExtradata: bytes) {
                return derived
            }
        }
        return "hvc1.2.4.L\(hevcLevel)"
    }

    /// `stereoMultiview` is whether the session presents an MV-HEVC source's second view
    /// (`StereoVideoSignal.multiview`). Only Dolby Vision Profile 20 routes differently on it.
    func resolveCodecRoute(
        codecpar: UnsafePointer<AVCodecParameters>,
        stereoMultiview: Bool = false
    ) throws -> CodecRoute {
        let codecID = codecpar.pointee.codec_id

        if codecID == AV_CODEC_ID_H264 {
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
                primaryCodecs: avcCodecs(codecpar: codecpar),
                supplementalCodecs: nil,
                doviConfig: hasDV ? .strip : .keep,
                convertP7ToProfile81: false,
                dvVariant: .none
            )
        }

        if codecID == AV_CODEC_ID_AV1 {
            let sourceRecord = doviConfigRecord(from: codecpar)
            // `dolbyVisionHandling = .baseLayerOnly`: read the record for nothing but the log, and
            // strip it on the way out, so the source takes the plain av01 branch below whatever the
            // display can do. Same predicate as the HEVC path and the format clamp.
            let presentsBaseLayer = sourceRecord.map { r in
                VideoRoutingPolicy.presentsDolbyVisionBaseLayer(
                    handling: dolbyVisionHandling,
                    codecID: AV_CODEC_ID_AV1,
                    dvProfile: Int(r.dv_profile),
                    dvBlCompatID: Int(r.dv_bl_signal_compatibility_id),
                    colorTransfer: codecpar.pointee.color_trc,
                    colorMatrix: codecpar.pointee.color_space)
            } ?? false
            if presentsBaseLayer, let r = sourceRecord {
                EngineLog.emit(
                    "[HLSVideoEngine] AV1 DV Profile \(r.dv_profile) compat=\(r.dv_bl_signal_compatibility_id): "
                    + "presenting the base layer only (dolbyVisionHandling=baseLayerOnly), plain av01, "
                    + "dvcC stripped, no SUPPLEMENTAL-CODECS",
                    category: .session
                )
            }
            let dvRecord = (effectiveDvMode && !presentsBaseLayer) ? sourceRecord : nil
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
                    doviConfig: .keep,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            case .av1Profile101:
                // P10.1: HDR10-compat base; av01 + SUPPLEMENTAL dav1/db1p. Analogous to HEVC P8.1, and
                // the same shape as P10.4 one branch below with PQ and db1p in place of HLG and db4h.
                // The bare dav1 that stood here is the packaging of a source WITHOUT a base layer
                // (P10.0, the analogue of HEVC P5); a cross-compatible profile carries its base layer's
                // own sample entry so a client that does not know Dolby Vision still plays it, and the
                // brand in SUPPLEMENTAL-CODECS is what makes AVPlayer engage the RPU (AE#547).
                let bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                let primary = String(
                    format: "av01.%d.%02dM.%02d.0.111.09.16.09.0",
                    av1Profile, av1Level, bd
                )
                return CodecRoute(
                    codecTagOverride: "av01",
                    videoRange: .pq,
                    primaryCodecs: primary,
                    supplementalCodecs: "dav1.10.\(dvLevelStr)/db1p",
                    doviConfig: .keep,
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
                    doviConfig: .keep,
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
                    doviConfig: (dvVariant == .av1Profile102 || presentsBaseLayer) ? .strip : .keep,
                    convertP7ToProfile81: false,
                    // The source is still what it is; the log should name it even when the record
                    // was read for nothing else.
                    dvVariant: presentsBaseLayer
                        ? classifyDVVariant(sourceRecord, codecID: AV_CODEC_ID_AV1) : dvVariant
                )
            // HEVC DV variants can't reach this switch (classifyDVVariant
            // is called with AV_CODEC_ID_AV1) but Swift's exhaustivity
            // check needs explicit handling.
            case .profile5, .profile20, .profile81, .profile84, .profile7, .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
            }
        }

        // HEVC path. Always classify DV: P5 needs dvh1 even on non-DV panels because AVPlayer's system
        // DV decoder tonemaps IPT-PQ-c2 internally; without dvh1 IPT chroma reads as YCbCr (green/purple
        // cast, AetherEngine#4 Build 160+163 / DrHurt#19). The dvh1.05 master is accepted on non-DV
        // HDR10 panels and tonemapped (#98), so P5 routes like any HDR source (resolveUseMasterPlaylist).
        let sourceDVRecord = doviConfigRecord(from: codecpar)
        // AE#532: a Profile 5 record its own RPU contradicts is served as what the RPU says. The audit
        // ran at load time and only for that class (`DolbyVisionRecordAudit`), so this is a verdict
        // already reached, not a question asked here. Correcting the record before the classification is
        // the whole change: a 7 lands on the Profile 7 branch and a 8 on the Profile 8.1 branch, whose
        // compatibility rewrite turns the record's 0 into the 1 it should have carried.
        var dvRecord = sourceDVRecord
        let correctedDVProfile = DolbyVisionRecordAudit.correctedProfile(
            record: sourceDVRecord.map { Int($0.dv_profile) }, rpu: dolbyVisionRPUProfile)
        if let corrected = correctedDVProfile {
            dvRecord?.dv_profile = UInt8(corrected)
            EngineLog.emit(
                "[HLSVideoEngine] AE#532: DV Profile 5 record contradicted by its own RPU "
                + "(RPU reads profile \(corrected)); serving it as Profile \(corrected), not as "
                + "Profile 5. A Profile 5 RPU cannot carry a residual or an NLQ",
                category: .session
            )
        }
        let dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_HEVC)

        if let r = sourceDVRecord {
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
        let hevcLevel = hevcLevelRaw > 0 ? min(hevcLevelRaw, Self.maxDeclaredHEVCLevel) : 150
        let dvLevelStr = String(format: "%02d", dvLevel)

        if let r = dvRecord {
            let recordProfile = Int(r.dv_profile)
            let recordCompat = Int(r.dv_bl_signal_compatibility_id)
            let vuiNamesYCbCrBase = VideoRoutingPolicy.vuiDeclaresYCbCrHDRBase(
                colorTransfer: codecpar.pointee.color_trc, colorMatrix: codecpar.pointee.color_space)
            // A Profile 5 record over a VUI that names a YCbCr HDR base is a container contradicting
            // its bitstream (the measured shape is a Profile 7 remux relabelled 5: NLQ and residual in
            // the RPU, identity mapping, HDR10 static metadata on the base). Served as dvh1.05 the
            // decoder reads YCbCr as IPT and the picture comes out green / violet. Said out loud on the
            // default route, because the fix is a host option and the host has to know to offer it.
            if dvVariant == .profile5, vuiNamesYCbCrBase, dolbyVisionHandling == .automatic {
                EngineLog.emit(
                    "[HLSVideoEngine] DV Profile 5 record over a BT.2020 YCbCr VUI "
                    + "(trc=\(codecpar.pointee.color_trc.rawValue) matrix=\(codecpar.pointee.color_space.rawValue)); "
                    + "a genuine Profile 5 leaves both unspecified. If the picture is green / violet the record "
                    + "is wrong and the base layer is HDR10: LoadOptions.dolbyVisionHandling = .baseLayerOnly "
                    + "presents it as such",
                    category: .session
                )
            }
            if VideoRoutingPolicy.presentsDolbyVisionBaseLayer(
                handling: dolbyVisionHandling,
                codecID: AV_CODEC_ID_HEVC,
                dvProfile: recordProfile,
                dvBlCompatID: recordCompat,
                colorTransfer: codecpar.pointee.color_trc,
                colorMatrix: codecpar.pointee.color_space
            ) {
                // The base layer on its own, on every display: plain hvc1, the record stripped so no
                // dvcC reaches the sample entry, no SUPPLEMENTAL, and no P7 conversion (its RPU is
                // dropped with the record). The RPU NAL units stay in the samples and are ignored, the
                // route a Profile 7 already takes on a display without Dolby Vision. The range is the
                // base layer's: PQ for 7 / 8.1 and a relabelled 5, HLG for 8.4, the VUI's for 8.2.
                let baseRange: HLSVideoRange
                switch dvVariant {
                case .profile84: baseRange = .hlg
                case .profile81, .profile7: baseRange = .pq
                default: baseRange = manifestVideoRange(codecpar)
                }
                EngineLog.emit(
                    "[HLSVideoEngine] DV Profile \(recordProfile) compat=\(recordCompat): presenting the "
                    + "\(baseRange.rawValue) base layer only (dolbyVisionHandling=baseLayerOnly), plain hvc1, "
                    + "dvcC stripped, no SUPPLEMENTAL-CODECS"
                    + (dvVariant == .profile7 ? ", no P7 -> P8.1 conversion" : ""),
                    category: .session
                )
                return CodecRoute(
                    codecTagOverride: "hvc1",
                    videoRange: baseRange,
                    primaryCodecs: plainHEVCCodecs(codecpar: codecpar, fallbackLevel: hevcLevel),
                    supplementalCodecs: nil,
                    doviConfig: .strip,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            }
        }

        switch dvVariant {
        case .profile5:
            // P5: DV-only (IPT-PQ-c2, no base). dvh1 always required; see HEVC-path comment above.
            // A well-formed bare dvh1.05 master is accepted on non-DV HDR10 panels and tonemapped to
            // HDR10 (#98, device-verified tvOS 26.5). No routing special-case; see resolveUseMasterPlaylist.
            return CodecRoute(
                codecTagOverride: "dvh1",
                videoRange: .pq,
                primaryCodecs: "dvh1.05.\(dvLevelStr)",
                supplementalCodecs: nil,
                doviConfig: .keep,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        case .profile20:
            if stereoMultiview {
                // 3D: the source as it is. The record stays Profile 20, the samples keep both views, and
                // the muxer writes lhvC beside hvcC (`StereoVideoSignal.multiview`).
                return CodecRoute(
                    codecTagOverride: "dvh1",
                    videoRange: .pq,
                    primaryCodecs: "dvh1.20.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    doviConfig: .keep,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            }
            // 2D: served as Profile 5. The base view is a Profile 5 base view and its RPU a Profile 5 RPU;
            // the second view's NAL units stay in the samples and the decoder skips them, since without
            // lhvC nothing declares their layer. The record rewrite also moves the version from 3.0 to
            // 1.0: VideoToolbox refuses a Profile 5 record that says 3.0 (-12910, measured on macOS 27
            // against a real Profile 20 sample, every other box and the samples ruled out one by one).
            EngineLog.emit(
                "[HLSVideoEngine] DV Profile 20 (MV-HEVC) in 2D: serving the base view as Profile 5 "
                + "(dvh1, dvcC profile=5 version=1.0, CODECS=dvh1.05.\(dvLevelStr)), second view skipped",
                category: .session
            )
            return CodecRoute(
                codecTagOverride: "dvh1",
                videoRange: .pq,
                primaryCodecs: "dvh1.05.\(dvLevelStr)",
                supplementalCodecs: nil,
                doviConfig: .rewriteToProfile5,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        case .profile81:
            // P8.1 (HDR10-compat base).
            // DV panel: hvc1 + dvvC (muxer writes dvvC automatically) + SUPPLEMENTAL dvh1.08.XX/db1p.
            //   db1p required; without it AVPlayer treats variant as plain HDR10 and DV never engages.
            // Non-DV panel: keep the dvvC, no SUPPLEMENTAL. The strip that stood here was measured
            //   against tvOS 26.0 in May 2026 (hvc1 + dvvC trips -11868 even without SUPPLEMENTAL) and no
            //   longer reproduces: on tvOS 26.6, an Apple TV 4K 3rd gen at an HDR10-only Samsung plays the
            //   unstripped packaging with no error log entry at all, and on the media-direct route (panel
            //   parked in SDR) the dvvC is what makes AVPlayer put the RPU on the pixels instead of
            //   tone-mapping the flat base layer. The box is the whole gain: the same run showed the
            //   SUPPLEMENTAL inert on a panel without DV (AVPlayer resolves the item as hdr10 either way),
            //   so it stays gated on effectiveDvMode where its own black-picture history is (f7e9f77f).
            // "P8.6" malformed compat (#53): normalize the container to compat=1 on both branches now that
            //   the non-DV branch keeps the record rather than dropping it.
            // AE#455, opt-in: on a display with no Dolby Vision of its own, serve the P8.1 the way a P5
            // is served, so AVPlayer composes the RPU itself instead of the panel receiving the bare
            // HDR10 base layer with its one static grade. The bitstream is untouched; what moves is the
            // container's claim about it, and a P8.1 RPU already carries the mapping out of its own base
            // layer. See `LoadOptions.forceDolbyVisionOnNonDVDisplay` for the risk this buys.
            //
            // P8.1 only. P8.4's base layer is HLG, and a profile-5 dvcC on an HLG `colr` is a container
            // that contradicts itself; nobody has measured that and it is not what was reported.
            if !effectiveDvMode && forceDolbyVisionOnNonDVDisplay {
                EngineLog.emit(
                    "[HLSVideoEngine] AE#455: serving HEVC DV Profile 8.1 as Profile 5 "
                    + "(dvh1 sample entry, dvcC profile=5 compat=0, CODECS=dvh1.05.\(dvLevelStr)) "
                    + "so AVPlayer composes the RPU on a display without Dolby Vision",
                    category: .session
                )
                return CodecRoute(
                    codecTagOverride: "dvh1",
                    videoRange: .pq,
                    primaryCodecs: "dvh1.05.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    doviConfig: .rewriteToProfile5,
                    convertP7ToProfile81: false,
                    dvVariant: dvVariant
                )
            }
            let compat = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 1)
            let needsCompatRewrite = compat != 1
            // Emitted on every display, not only a DV-capable one. The pairing of a plain `hvc1` CODECS
            // with a DV SUPPLEMENTAL is what the HLS authoring spec asks for, and it exists precisely so a
            // client that does not know `dvh1` reads the base layer instead of failing, which is not a
            // hypothetical audience here: the loopback master is handed to wireless AirPlay receivers, and
            // an AirPlay 2 television is that client. The gate that stood here was a real measurement
            // (f7e9f77f: black picture on an HDR10-only panel) from the same afternoon as the strip above,
            // and it does not reproduce on tvOS 26.6 either.
            let supplemental: String? = "dvh1.08.\(dvLevelStr)/db1p"
            let doviConfig: MP4SegmentMuxer.DoviConfigPolicy =
                needsCompatRewrite ? .rewriteToProfile81 : .keep
            if needsCompatRewrite {
                EngineLog.emit(
                    "[HLSVideoEngine] HEVC DV Profile 8 with invalid compat="
                    + "\(compat) (\"P8.6\"); normalizing container dvcC to "
                    + "P8.1 (compat=1)",
                    category: .session
                )
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .pq,
                primaryCodecs: plainHEVCCodecs(codecpar: codecpar, fallbackLevel: hevcLevel),
                supplementalCodecs: supplemental,
                doviConfig: doviConfig,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        case .profile84:
            // P8.4 (HLG-compat base). Mirrors P8.1 routing.
            // DV panel: hvc1 + dvvC + SUPPLEMENTAL dvh1.08.XX/db4h. db4h marks HLG-base for AVKit criteria.
            // Non-DV panel: keep the dvvC, no SUPPLEMENTAL, for the reason written out on the P8.1 branch
            //   above. The -11868 that both strips were built against was one panel on tvOS 26.0 and does
            //   not reproduce on 26.6. P8.4 is measured separately from P8.1 rather than assumed: its base
            //   layer is HLG, so the conversion AVPlayer performs on a panel that is not in HDR is a
            //   different one, and the dvcC it would consult claims compat=4 rather than 1.
            // Note: dvh1 sample entry is never valid for HLG-base (AVPlayer rejects it, DrHurt#4 Build 160),
            //   so there is no P5-style masquerade here, only the record itself.
            // Unconditional for the same reason as P8.1 above; db4h is the HLG-base brand.
            let supplemental: String? = "dvh1.08.\(dvLevelStr)/db4h"
            let doviConfig: MP4SegmentMuxer.DoviConfigPolicy = .keep
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .hlg,
                primaryCodecs: plainHEVCCodecs(codecpar: codecpar, fallbackLevel: hevcLevel),
                supplementalCodecs: supplemental,
                doviConfig: doviConfig,
                convertP7ToProfile81: false,
                dvVariant: dvVariant
            )
        case .profile7:
            // P7 dual-layer (UHD-BD). With preferDualLayerDolbyVision on and the box able to afford it,
            // VideoRoutingPolicy sends a FEL to the software dual-layer route instead (SoftwarePlaybackHost +
            // DualLayerVideoDecoder), which keeps the enhancement layer; every other P7 load lands here.
            //
            // Native route: convert the RPU P7 -> P8.1 per packet (DoviRpuConverter, libdovi
            // mode 2), drop the EL, rewrite the container dvcC to P8.1, and from there on serve exactly
            // what a P8.1 source is served, on every display. The way mpv treats Profile 7 without an EL
            // decoder: base layer plus RPU, never the bare base layer.
            //
            // The non-DV branch used to strip the record and skip the conversion, playing the HDR10 base
            // with its static metadata only. That was the P8.1 non-DV route of the same era (tvOS 26.0
            // -11868), and P8.1 dropped the strip once it stopped reproducing on 26.6 (see that branch):
            // the kept dvvC is what makes AVPlayer tone-map from the RPU on a panel without DV, the
            // SUPPLEMENTAL is inert there. A converted P7 is a P8.1 bitstream, so the reasoning carries
            // over unchanged; leaving P7 behind cost every P7 source its RPU on HDR10 / SDR panels, on
            // every Mac (no per-mode table, so `effectiveDvMode` is false unless the host asserts DV),
            // and shipped the EL NAL units (up to a FEL's bitrate) into segments that nothing decodes.
            // AE#455 applies to the converted stream the way it applies to a native P8.1.
            if !effectiveDvMode && forceDolbyVisionOnNonDVDisplay {
                EngineLog.emit(
                    "[HLSVideoEngine] AE#455: serving HEVC DV Profile 7 (converted to 8.1) as Profile 5 "
                    + "(dvh1 sample entry, dvcC profile=5 compat=0, CODECS=dvh1.05.\(dvLevelStr)) "
                    + "so AVPlayer composes the RPU on a display without Dolby Vision",
                    category: .session
                )
                return CodecRoute(
                    codecTagOverride: "dvh1",
                    videoRange: .pq,
                    primaryCodecs: "dvh1.05.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    doviConfig: .rewriteToProfile5,
                    convertP7ToProfile81: true,
                    dvVariant: dvVariant
                )
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .pq,
                primaryCodecs: plainHEVCCodecs(codecpar: codecpar, fallbackLevel: hevcLevel),
                supplementalCodecs: "dvh1.08.\(dvLevelStr)/db1p",
                doviConfig: .rewriteToProfile81,
                convertP7ToProfile81: true,
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
                primaryCodecs: plainHEVCCodecs(codecpar: codecpar, fallbackLevel: hevcLevel),
                supplementalCodecs: nil,
                doviConfig: dvVariant == .profile82 ? .strip : .keep,
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
