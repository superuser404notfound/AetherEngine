import Foundation
import Libavcodec
import Libavutil

extension HLSVideoEngine {

    // MARK: - Segment plan model

    struct Segment {
        let startPts: Int64
        let endPts: Int64
        let startSeconds: Double
        let durationSeconds: Double
        /// True when this segment opened at a detected live PTS
        /// discontinuity (program boundary). The playlist builder prefixes
        /// such a segment with `#EXT-X-DISCONTINUITY`. Always false for VOD
        /// (the precomputed plan has no discontinuities).
        var discontinuous: Bool = false
    }

    // MARK: - Segment planning

    /// Build a uniform-duration segment plan from the source's
    /// reported duration. Used only as a fallback when libavformat's
    /// keyframe index is too sparse for the keyframe-aligned plan.
    /// The hls muxer will still snap actual cut points to real
    /// keyframes, so EXTINF / actual-duration drift accumulates with
    /// each segment in this fallback path. Phase B's restart machinery
    /// renegotiates timeline alignment after scrubs, so the drift
    /// stays bounded within one playback span.
    func buildUniformSegmentPlan(
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard sourceDurationSeconds > 0 else { return [] }
        let stride = Self.targetSegmentDuration
        let count = max(1, Int(ceil(sourceDurationSeconds / stride)))
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }

        var plan: [Segment] = []
        plan.reserveCapacity(count)
        for i in 0..<count {
            let startSeconds = Double(i) * stride
            let endSeconds = min(sourceDurationSeconds, Double(i + 1) * stride)
            let startPts = Int64(startSeconds / tb)
            let endPts = Int64(endSeconds / tb)
            plan.append(Segment(
                startPts: startPts,
                endPts: endPts,
                startSeconds: startSeconds,
                durationSeconds: max(0.001, endSeconds - startSeconds)
            ))
        }
        return plan
    }

    /// Build a segment plan from real keyframes using libavformat's
    /// hls muxer cut algorithm: segment N ends at the first keyframe
    /// whose absolute distance from `start_pts` reaches `(N+1) *
    /// targetSegmentDuration`. `start_pts` is taken as the first
    /// keyframe in the index (sorted ascending), which matches the
    /// muxer's behaviour of latching `vs->start_pts` to the first
    /// packet's pts.
    ///
    /// This algorithm replaces the previous one which walked the
    /// keyframe list with a relative threshold per segment. The
    /// relative walk diverged from libavformat's cut algorithm on
    /// sources with irregular GOPs (e.g. keyframes at 0, 5.8, 11.5,
    /// 17.4, 23.3 produce 3 segments under absolute thresholds but
    /// only 2 under the relative walk), which would translate into
    /// playlist drift the moment the muxer actually cut differently
    /// from what we'd advertised.
    func buildKeyframeSegmentPlan(
        keyframes: [Int64],
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard keyframes.count >= 2 else { return [] }
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }
        let target = Self.targetSegmentDuration

        let sorted = keyframes.sorted()
        let startPts0 = sorted[0]

        var plan: [Segment] = []
        plan.reserveCapacity(sorted.count)
        var i = 0
        var segIdx = 0
        while i < sorted.count {
            let segStartPts = sorted[i]
            let segStartSeconds = Double(segStartPts - startPts0) * tb
            let thresholdSeconds = Double(segIdx + 1) * target

            var j = i + 1
            while j < sorted.count {
                let candidateSeconds = Double(sorted[j] - startPts0) * tb
                if candidateSeconds >= thresholdSeconds { break }
                j += 1
            }

            let segEndPts: Int64
            let segEndSeconds: Double
            if j < sorted.count {
                segEndPts = sorted[j]
                segEndSeconds = Double(segEndPts - startPts0) * tb
            } else {
                segEndSeconds = sourceDurationSeconds
                // startPts0-anchored like every startPts: a bare
                // duration/tb sat on the from-zero axis while the rest of
                // the plan is absolute source PTS. Harmless today only
                // because segmentIndex() clamps past-the-end PTS into the
                // last segment; any new consumer of endPts would inherit
                // an off-by-one-GOP skew.
                segEndPts = startPts0 + Int64(sourceDurationSeconds / tb)
            }

            plan.append(Segment(
                startPts: segStartPts,
                endPts: segEndPts,
                startSeconds: segStartSeconds,
                durationSeconds: max(0.001, segEndSeconds - segStartSeconds)
            ))

            i = j
            segIdx += 1
        }

        return plan
    }

    /// When the source HEVC's `hvcC` (in `codecpar.extradata`) carries
    /// the configuration header but no VPS / SPS / PPS arrays, scan
    /// the first packets for in-band parameter sets and return a
    /// rebuilt `hvcC` byte sequence with those arrays populated.
    /// Returns nil when the source already has parameter set arrays,
    /// when the source uses a non-4-byte NALU length size, or when
    /// the scan exhausts the budget without finding all three NAL
    /// types.
    ///
    /// Some DV Profile 5 MP4 encoders write only the 23-byte hvcC
    /// header (`numOfArrays = 0`) and leave VPS / SPS / PPS in-band
    /// in every IRAP packet (issue #19 Wandering Earth 2 WEB-DL).
    /// FFmpeg's mp4 muxer stream-copies that hvcC through, so the
    /// output fMP4 has a `dvh1` sample entry that AVPlayer cannot
    /// build a `CMVideoFormatDescription` from. AVPlayer's symptom is
    /// `item.tracks count=2` but `fourCC=<no fdesc>` and
    /// `item.status .failed` with `CoreMediaErrorDomain -4`. The
    /// matroska demuxer doesn't hit this because matroska parameter
    /// sets are in the `CodecPrivate` block which FFmpeg lifts into
    /// `codecpar.extradata` as a complete annex-B sequence that the
    /// mp4 muxer's `ff_isom_write_hvcc` then rebuilds properly.
    ///
    /// Caller is expected to seek the demuxer back to a known
    /// position after this returns, since extracting consumes
    /// packets.
    func rebuildHEVCExtradataWithInBandParameterSets(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        codecpar: UnsafePointer<AVCodecParameters>
    ) -> [UInt8]? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else { return nil }
        let extradataSize = Int(codecpar.pointee.extradata_size)
        guard extradataSize >= 23, let extradata = codecpar.pointee.extradata else { return nil }
        // hvcC byte 22 is numOfArrays. Non-zero means parameter sets
        // already in the configuration record; nothing to do.
        guard extradata[22] == 0 else { return nil }
        // hvcC byte 21 lower 2 bits + 1 is NALU length size. Anything
        // other than 4 is exotic enough that we bail rather than risk
        // mis-parsing.
        let naluLengthSize = Int(extradata[21] & 0x03) + 1
        guard naluLengthSize == 4 else { return nil }

        var vps: [UInt8]?
        var sps: [UInt8]?
        var pps: [UInt8]?
        let packetBudget = 16
        var packetsScanned = 0

        while packetsScanned < packetBudget {
            let readResult: UnsafeMutablePointer<AVPacket>?
            do {
                readResult = try demuxer.readPacket()
            } catch {
                break
            }
            guard let pkt = readResult else { break }
            defer {
                // trackedPacketFree, not raw av_packet_free: readPacket
                // allocs via trackedPacketAlloc, and a raw free here left
                // the PacketBalanceTracker's pktAlive permanently high
                // (+N per DV5/empty-hvcC session), defeating the very
                // leak diagnostic the counter exists for. free() unrefs
                // internally, so no separate av_packet_unref needed.
                var maybePkt: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&maybePkt)
            }
            packetsScanned += 1
            if pkt.pointee.stream_index != videoStreamIndex { continue }
            guard let pktData = pkt.pointee.data else { continue }
            let pktSize = Int(pkt.pointee.size)

            var offset = 0
            while offset + naluLengthSize <= pktSize {
                var nalLen = 0
                for i in 0..<naluLengthSize {
                    nalLen = (nalLen << 8) | Int(pktData[offset + i])
                }
                offset += naluLengthSize
                if nalLen == 0 || offset + nalLen > pktSize { break }
                // HEVC NAL header: byte 0 = forbidden_zero_bit(1) +
                // nal_unit_type(6) + layer_id high bit(1). NAL unit
                // type is bits 1..6 of byte 0.
                let nalType = (Int(pktData[offset]) >> 1) & 0x3F
                let nalBytes = Array(UnsafeBufferPointer(start: pktData + offset, count: nalLen))
                switch nalType {
                case 32: if vps == nil { vps = nalBytes }
                case 33: if sps == nil { sps = nalBytes }
                case 34: if pps == nil { pps = nalBytes }
                default: break
                }
                offset += nalLen
            }

            if vps != nil && sps != nil && pps != nil { break }
        }

        guard let vps, let sps, let pps else { return nil }

        // Assemble a proper hvcC: keep the source's 22-byte header
        // (configurationVersion + profile / level / chroma / temporal
        // layer fields), set numOfArrays = 3, then append VPS / SPS /
        // PPS arrays. Each array: 1 byte (arrayCompleteness=1 +
        // reserved=0 + nalUnitType), 2 bytes numNalus = 1, 2 bytes
        // nalUnitLength, NAL bytes.
        var hvcC: [UInt8] = []
        hvcC.reserveCapacity(22 + 1 + 5 * 3 + vps.count + sps.count + pps.count)
        for i in 0..<22 { hvcC.append(extradata[i]) }
        hvcC.append(3)
        func appendArray(nalUnitType: UInt8, nal: [UInt8]) {
            hvcC.append(0x80 | (nalUnitType & 0x3F))
            hvcC.append(0); hvcC.append(1)
            let nl = UInt16(nal.count)
            hvcC.append(UInt8(nl >> 8)); hvcC.append(UInt8(nl & 0xFF))
            hvcC.append(contentsOf: nal)
        }
        appendArray(nalUnitType: 32, nal: vps)
        appendArray(nalUnitType: 33, nal: sps)
        appendArray(nalUnitType: 34, nal: pps)
        return hvcC
    }

    /// AAC carried as ADTS (the typical MPEG-TS shape) arrives with no
    /// AudioSpecificConfig in `extradata`, so the fMP4 `mp4a`/`esds` sample
    /// entry can't be written and the mux fails. Synthesise a 2-byte ASC from
    /// the codecpar's sample rate / channel count and install it as extradata,
    /// and clear the codec_tag the mpegts demuxer leaves (the mov muxer rejects
    /// the TS tag). Returns true when it applied the fix — the caller flags the
    /// pump to strip the per-frame ADTS header. No-op (false) for non-AAC or
    /// AAC that already carries an ASC (then the existing copy path works).
    static func prepareAACForFMP4(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_AAC else { return false }
        guard codecpar.pointee.extradata == nil || codecpar.pointee.extradata_size == 0 else { return false }
        let freqTable: [Int32] = [96000, 88200, 64000, 48000, 44100, 32000,
                                  24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard let freqIdx = freqTable.firstIndex(of: codecpar.pointee.sample_rate) else { return false }
        let channels = max(1, Int(codecpar.pointee.ch_layout.nb_channels))
        // AudioSpecificConfig channelConfiguration: 1-6 map 1:1, 7 means
        // EIGHT channels (7.1), and 7-channel audio has no config value
        // at all. The old `channels <= 7 ? channels : 2` declared 8-ch
        // sources as stereo (decoder garbage) and 6.1 as 7.1.
        let chanConfig: Int
        switch channels {
        case 1...6: chanConfig = channels
        case 8:     chanConfig = 7
        default:    return false  // 7-ch (or >8): no ASC representation; let the bridge handle it
        }
        // audioObjectType: basic AAC profiles map profile→profile+1 (LC = 2);
        // default to 2 (AAC-LC, the mp4a.40.2 the engine advertises) otherwise.
        let profile = Int(codecpar.pointee.profile)
        let aot = (profile >= 0 && profile <= 3) ? profile + 1 : 2
        let asc: [UInt8] = [
            UInt8((aot << 3) | (freqIdx >> 1)),
            UInt8(((freqIdx & 1) << 7) | (chanConfig << 3)),
        ]
        if codecpar.pointee.extradata != nil { av_freep(&codecpar.pointee.extradata) }
        codecpar.pointee.extradata_size = 0
        let total = asc.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buf = av_malloc(total)?.assumingMemoryBound(to: UInt8.self) else { return false }
        asc.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { memcpy(buf, base, asc.count) }
        }
        memset(buf + asc.count, 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))
        codecpar.pointee.extradata = buf
        codecpar.pointee.extradata_size = Int32(asc.count)
        codecpar.pointee.codec_tag = 0
        return true
    }

    /// Whether an AAC source must take the `AudioBridge` (decode → re-encode)
    /// instead of fMP4 stream-copy because it is HE-AAC (SBR) / HE-AACv2 (PS)
    /// AND carries no AudioSpecificConfig in `extradata`.
    ///
    /// HE-AAC stream-copies cleanly whenever the source already ships an ASC
    /// (any movie container: MP4 `esds`, MKV `CodecPrivate`). The ASC encodes
    /// the true core sample rate plus the SBR/PS signaling; AVPlayer reads it
    /// from the fMP4 init segment and decodes HE-AAC/HE-AACv2 natively
    /// (AetherEngine#33), exactly as a manual or Jellyfin server-side remux
    /// does. Bridging those was an unnecessary EAC3/FLAC re-encode.
    ///
    /// It only has to bridge when the ASC is ABSENT — live ADTS / MPEG-TS,
    /// where `prepareAACForFMP4` synthesizes a 2-byte ASC from the codecpar.
    /// That synthesized ASC declares plain LC at the SBR OUTPUT rate (e.g.
    /// mp4a.40.2 @ 48 kHz for a 24 kHz core), which AudioToolbox decodes as
    /// garbage (AVFoundationErrorDomain -11821, device repro: NBC HE-AAC).
    /// `find_stream_info` decodes a frame before this runs, so `profile`
    /// (4 = HE, 28 = HE-AACv2) and `frameSize` (SBR doubles the LC frame to
    /// 2048 samples) are both populated; either one flags HE-AAC.
    static func aacRequiresBridge(profile: Int32, frameSize: Int32, hasASC: Bool) -> Bool {
        guard !hasASC else { return false }
        return profile == 4        // FF_PROFILE_AAC_HE
            || profile == 28       // FF_PROFILE_AAC_HE_V2
            || frameSize == 2048   // SBR doubles the LC frame to 2048 samples
    }
}
