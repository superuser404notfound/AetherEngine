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
        /// True at a live PTS discontinuity (program boundary); causes `#EXT-X-DISCONTINUITY` in the playlist. Always false for VOD.
        var discontinuous: Bool = false
    }

    // MARK: - Segment planning

    /// True when the indexed keyframe list is dense enough AND wide enough to trust for a keyframe-aligned plan (#64, #91).
    ///
    /// MPEG-TS / M2TS have no upfront keyframe table the way MKV Cues / MP4 stss do: the libavformat
    /// index holds only what `avformat_find_stream_info` plus the mid-file cue-prewarm seek happened to
    /// scan, so for a TS source it comes back sparse and clustered (e.g. one entry near the start, a
    /// handful near the seek point). `buildKeyframeSegmentPlan` would then emit a single multi-thousand-
    /// second first segment, and the `frag_custom` muxer buffers that whole span in libavformat's
    /// interleaver before its first flush, which on a 110 min Blu-ray climbed to ~13 GB of RAM and
    /// swapped until the device disk filled.
    ///
    /// Two witnesses, both required:
    ///
    /// - **Gap (#64)**: the largest gap between consecutive keyframes. A real index never gaps more than
    ///   a few GOPs (well under the cap); a clustered TS index gaps by thousands of seconds.
    /// - **Coverage (#91)**: the span from the first to the last indexed keyframe. When a remote MKV's
    ///   Cues tail read fails, the prewarm seek loads nothing and only the open-time keyframes survive,
    ///   all bunched within the first few seconds. Their gaps are tiny so the gap check passes, but the
    ///   index spans almost none of the title. The keyframe planner cuts segment 0 at the first keyframe
    ///   at-or-after `targetSegmentDuration`; with no keyframe that far out the plan degenerates to one
    ///   whole-file segment, from which AVPlayer loads zero tracks. Below one segment of coverage the
    ///   keyframe planner cannot make even the first cut, so such an index is rejected here.
    ///
    /// Coverage is the span between keyframes, never reaching to EOF, so a dense index that stops early
    /// (the trailing-gap-not-counted case) is unaffected: its span already exceeds one segment.
    /// An index failing either witness is routed to the uniform-stride fallback.
    static func keyframeIndexIsTrustworthy(
        keyframes: [Int64],
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double,
        maxTrustedGapSeconds: Double = Swift.max(HLSVideoEngine.targetSegmentDuration * 4, 30),
        minCoverageSeconds: Double = HLSVideoEngine.targetSegmentDuration
    ) -> Bool {
        guard keyframes.count >= 2,
              sourceDurationSeconds > 0,
              videoTimeBase.num > 0, videoTimeBase.den > 0 else { return false }
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        let sorted = keyframes.sorted()
        let coverageSeconds = Double(sorted[sorted.count - 1] - sorted[0]) * tb
        guard coverageSeconds >= minCoverageSeconds else { return false }
        var largestGapSeconds = 0.0
        for i in 1..<sorted.count {
            let gapSeconds = Double(sorted[i] - sorted[i - 1]) * tb
            if gapSeconds > largestGapSeconds { largestGapSeconds = gapSeconds }
        }
        return largestGapSeconds <= maxTrustedGapSeconds
    }

    /// Uniform-duration fallback plan when the keyframe index is too sparse. Source-axis boundaries are
    /// anchored at `startPts0` (the first keyframe PTS), exactly like the keyframe-aligned plan, so segment 0
    /// begins at the content start rather than at source PTS 0. A title whose content starts late (e.g. a
    /// Blu-ray beginning at 11.6s) would otherwise advertise empty leading segments that the producer never
    /// emits, leaving AVPlayer's seg0 fetch permanently out of range and playback stalled until a seek past
    /// the content start (#64 follow-up). The playlist axis (`startSeconds`) stays 0-based; the producer's
    /// shift maps source to playlist. The muxer still snaps cuts to real keyframes, so EXTINF drift
    /// accumulates per segment; restart machinery renegotiates alignment after scrubs.
    static func buildUniformSegmentPlan(
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double,
        startPts0: Int64 = 0
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
            let startPts = startPts0 + Int64(startSeconds / tb)
            let endPts = startPts0 + Int64(endSeconds / tb)
            plan.append(Segment(
                startPts: startPts,
                endPts: endPts,
                startSeconds: startSeconds,
                durationSeconds: max(0.001, endSeconds - startSeconds)
            ))
        }
        return plan
    }

    /// Keyframe-aligned plan mirroring libavformat's hls muxer cut algorithm: segment N ends at the first keyframe where `(keyframe_pts - start_pts) >= (N+1) * targetDuration`. Absolute thresholds match the muxer; relative per-segment thresholds diverged on irregular GOPs.
    static func buildKeyframeSegmentPlan(
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
                // GOTCHA: final endPts is startPts0-anchored; consumers must not use it raw: segmentIndex() clamps past-the-end PTS into the last segment.
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

    /// Segments shorter than this are folded into a neighbour by `collapseShortSegments`. A keyframe
    /// cluster (several IRAPs within a few frames) otherwise makes `buildKeyframeSegmentPlan` emit
    /// sub-frame segments whose narrow [start,end) window can miss every demuxed keyframe, so the producer
    /// never cuts that index and the advertised-but-unproduced segment wedges playback. Well above a single
    /// frame (~40 ms) and well below a normal ~`targetSegmentDuration` segment, so only degenerate cluster
    /// segments are affected.
    static let minSegmentDurationSeconds: Double = 1.0

    /// Fold every plan segment shorter than `minDurationSeconds` into a neighbour so no advertised segment
    /// has a window too narrow to contain a demuxed keyframe. Plan and producer share one boundary list
    /// (`segmentBoundaries = plan.map(startPts)`), and the producer only emits a segment index when a
    /// keyframe's PTS maps into its window (`segmentOffset`); a sub-frame window from a keyframe cluster can
    /// catch none, so that index is skipped and its later fetch wedges AVPlayer (CoreMedia -15628 ->
    /// endless item reload; Sodalite near-EOF resume hang, device-confirmed). Merging widens the window so
    /// a resident keyframe is guaranteed and the two agree. Interior/final short segments fold into the
    /// PRECEDING kept segment; a too-short first segment (no predecessor) folds forward into its successor.
    /// Every kept boundary is still an original plan boundary, and total duration is conserved.
    ///
    /// AE#169: also fold a final slot shorter than the normal cut target into its predecessor. The final
    /// boundary has no later IRAP that can rescue a Cues/runtime keyframe disagreement. Advertising that
    /// terminal slot left seg719 structurally unproducible while the producer correctly carried its tail
    /// in seg718. Folding only sub-target tails adds less than one ordinary segment span to the existing
    /// final segment while removing the unrecoverable boundary.
    ///
    /// Pure for offline testing.
    static func collapseShortSegments(_ plan: [Segment], minDurationSeconds: Double) -> [Segment] {
        guard plan.count > 1, minDurationSeconds > 0 else { return plan }
        var out: [Segment] = []
        out.reserveCapacity(plan.count)
        for seg in plan {
            if seg.durationSeconds < minDurationSeconds, let last = out.last {
                out[out.count - 1] = Segment(
                    startPts: last.startPts,
                    endPts: seg.endPts,
                    startSeconds: last.startSeconds,
                    durationSeconds: last.durationSeconds + seg.durationSeconds,
                    discontinuous: last.discontinuous)
            } else {
                out.append(seg)
            }
        }
        // A too-short FIRST segment has no predecessor to swallow it; fold it forward into its successor.
        if out.count > 1, out[0].durationSeconds < minDurationSeconds {
            let a = out[0], b = out[1]
            out[1] = Segment(
                startPts: a.startPts,
                endPts: b.endPts,
                startSeconds: a.startSeconds,
                durationSeconds: a.durationSeconds + b.durationSeconds,
                discontinuous: a.discontinuous)
            out.removeFirst()
        }
        if out.count > 1, let tail = out.last,
           tail.durationSeconds < Self.targetSegmentDuration {
            let previous = out[out.count - 2]
            out[out.count - 2] = Segment(
                startPts: previous.startPts,
                endPts: tail.endPts,
                startSeconds: previous.startSeconds,
                durationSeconds: previous.durationSeconds + tail.durationSeconds,
                discontinuous: previous.discontinuous)
            out.removeLast()
        }
        return out
    }

    /// Scan packets for in-band VPS/SPS/PPS when hvcC `numOfArrays=0` (DV P5 MP4 encoders, e.g. Wandering Earth 2 WEB-DL, issue #19). AVPlayer symptom: `item.tracks count=2`, `fourCC=<no fdesc>`, `CoreMediaErrorDomain -4`. Caller must seek back after this consumes packets.
    func rebuildHEVCExtradataWithInBandParameterSets(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        codecpar: UnsafePointer<AVCodecParameters>
    ) -> [UInt8]? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else { return nil }
        let extradataSize = Int(codecpar.pointee.extradata_size)
        guard extradataSize >= 23, let extradata = codecpar.pointee.extradata else { return nil }
        guard extradata[22] == 0 else { return nil }  // hvcC byte 22 = numOfArrays; non-zero means already populated
        let naluLengthSize = Int(extradata[21] & 0x03) + 1  // hvcC byte 21 lower 2 bits + 1
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
                // trackedPacketFree not raw av_packet_free: readPacket allocs via trackedPacketAlloc; raw free leaves PacketBalanceTracker.pktAlive permanently high.
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
                let nalType = (Int(pktData[offset]) >> 1) & 0x3F  // HEVC NAL type: bits 1..6 of byte 0
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

        // Assemble hvcC: keep source 22-byte header, set numOfArrays=3, append VPS/SPS/PPS arrays (1-byte type, 2-byte numNalus=1, 2-byte nalUnitLength, NAL bytes).
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

    /// Rewrite an hvcC config record to keep only the VPS(32)/SPS(33)/PPS(34) parameter-set arrays, dropping
    /// SEI_PREFIX(39)/SEI_SUFFIX(40) and any other NAL arrays. libx265 (and other encoders) embed a large
    /// user-data SEI_PREFIX array in the hvcC; the VOD muxer forwards the source config record verbatim, so
    /// that array reaches the fMP4 init sample description. Apple TV hardware builds the HEVC format
    /// description straight from the hvcC parameter-set arrays and rejects a record carrying non-parameter-set
    /// arrays: `asset.tracks count=0`, `AVFoundationErrorDomain -11829`, `CoreMediaErrorDomain -12848` (AE#187).
    /// macOS and the tvOS Simulator tolerate it, so it only surfaces on device. The live MPEG-TS and direct
    /// fMP4-HLS paths never hit this because their hvcC is rebuilt from parameter sets alone; canonicalizing
    /// here aligns the VOD path with them. HDR10 static metadata is unaffected: it rides in-band per-IRAP in
    /// the media packets (untouched) and in the muxer's `mdcv`/`clli` boxes, not the hvcC SEI array. DV is
    /// unaffected too: the dvcC/dvvC boxes and RPU live outside the hvcC extradata. Returns nil when the record
    /// already holds only parameter-set arrays (no rewrite needed) or cannot be parsed as an hvcC.
    static func canonicalizeHEVCConfigRecord(_ extradata: [UInt8]) -> [UInt8]? {
        guard extradata.count >= 23 else { return nil }
        guard extradata[0] == 1 else { return nil }  // configurationVersion; guards against Annex-B / non-hvcC
        let numOfArrays = Int(extradata[22])
        guard numOfArrays > 0 else { return nil }  // numOfArrays=0 is the in-band-rebuild path, not this one

        // Collect each array's [start, end) byte range and its NAL type, bounds-checked. Any inconsistency
        // (truncated record) returns nil so a malformed source is forwarded unchanged rather than corrupted.
        var arrays: [(type: Int, range: Range<Int>)] = []
        var offset = 23
        for _ in 0..<numOfArrays {
            let arrayStart = offset
            guard offset + 3 <= extradata.count else { return nil }
            let nalType = Int(extradata[offset]) & 0x3F
            let numNalus = (Int(extradata[offset + 1]) << 8) | Int(extradata[offset + 2])
            offset += 3
            for _ in 0..<numNalus {
                guard offset + 2 <= extradata.count else { return nil }
                let nalLen = (Int(extradata[offset]) << 8) | Int(extradata[offset + 1])
                offset += 2 + nalLen
                guard offset <= extradata.count else { return nil }
            }
            arrays.append((type: nalType, range: arrayStart..<offset))
        }

        let parameterSetTypes: Set<Int> = [32, 33, 34]  // VPS, SPS, PPS
        let kept = arrays.filter { parameterSetTypes.contains($0.type) }
        guard kept.count < arrays.count else { return nil }  // nothing to drop: already canonical

        var out: [UInt8] = []
        out.reserveCapacity(23 + kept.reduce(0) { $0 + $1.range.count })
        out.append(contentsOf: extradata[0..<22])  // header verbatim (profile/tier/level/lengthSize)
        out.append(UInt8(kept.count))               // rewritten numOfArrays
        for array in kept { out.append(contentsOf: extradata[array.range]) }
        return out
    }

    /// ADTS AAC from MPEG-TS arrives without an AudioSpecificConfig in `extradata`; the fMP4 `mp4a`/`esds` sample entry can't be written. Synthesizes a 2-byte ASC, installs it, and clears the TS codec_tag the mov muxer rejects. Returns true when applied; caller strips per-frame ADTS headers.
    static func prepareAACForFMP4(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_AAC else { return false }
        guard codecpar.pointee.extradata == nil || codecpar.pointee.extradata_size == 0 else { return false }
        let freqTable: [Int32] = [96000, 88200, 64000, 48000, 44100, 32000,
                                  24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard let freqIdx = freqTable.firstIndex(of: codecpar.pointee.sample_rate) else { return false }
        let channels = max(1, Int(codecpar.pointee.ch_layout.nb_channels))
        // ASC channelConfiguration: 1-6 map 1:1, 7 = 8ch (7.1); 7-ch has no ASC value. Old `channels<=7?channels:2` mapped 8ch as stereo and 6.1 as 7.1.
        let chanConfig: Int
        switch channels {
        case 1...6: chanConfig = channels
        case 8:     chanConfig = 7
        default:    return false  // 7-ch or >8: no ASC representation; bridge handles it
        }
        let profile = Int(codecpar.pointee.profile)
        // audioObjectType: profile maps profile+1 (LC=2); default to 2 (mp4a.40.2) for unknown profiles.
        let aot = (profile >= 0 && profile <= 3) ? profile + 1 : 2  // audioObjectType
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

    /// HE-AAC (SBR, profile=4) and HE-AACv2 (PS, profile=28) stream-copy cleanly when an ASC is present (MP4 esds, MKV CodecPrivate). Bridge only when ASC is absent (live ADTS/MPEG-TS): the synthesized 2-byte ASC declares LC at the SBR output rate, which AudioToolbox decodes as garbage (-11821; device repro: NBC HE-AAC). frameSize=2048 also flags SBR.
    static func aacRequiresBridge(profile: Int32, frameSize: Int32, hasASC: Bool) -> Bool {
        guard !hasASC else { return false }
        return profile == 4        // FF_PROFILE_AAC_HE
            || profile == 28       // FF_PROFILE_AAC_HE_V2
            || frameSize == 2048   // SBR doubles the LC frame to 2048 samples
    }

    /// AE#187 defense-in-depth: strip a zero-sample `sdtp` box from the video track's `stbl` in the captured init.
    ///
    /// Our init is a fragmented `empty_moov` init: the `moov` describes no samples (they live in each
    /// `moof`), so an `sdtp` (per-sample dependency flags) covering zero samples is meaningless. Apple TV's
    /// HEVC hardware track builder validates the box against the empty sample table and drops the video track
    /// (item fails -11829 / -12848); macOS and the Simulator ignore the stray box, and FFmpeg's own
    /// fragmented init omits it. movenc (n8.1.2, the pinned FFmpegBuild) cannot emit this box under
    /// `empty_moov` (it zeroes `track->entry` before writing the `stbl`), but a consumer that links an older
    /// FFmpeg the wrong way (AE#187: a `-force_load`ed 7.1.5 shadowing the vendored 2.2.0) still does, so the
    /// guard runs on the emitted init bytes and neutralizes the box regardless of who wrote it. Returns nil
    /// (init forwarded unchanged) when the init is not parseable, has no `moov`/video track, or the video
    /// `stbl` carries no zero-sample `sdtp`.
    static func stripEmptyVideoSampleDependencyBox(fromInit initBytes: [UInt8]) -> [UInt8]? {
        let b = initBytes
        let n = b.count
        guard n >= 8 else { return nil }

        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= n else { return nil }
            return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
        }
        func fourcc(_ o: Int) -> String? {
            guard o >= 0, o + 4 <= n else { return nil }
            return String(bytes: b[o..<o + 4], encoding: .ascii)
        }
        func boxes(in start: Int, _ end: Int) -> [(boxStart: Int, type: String, payloadStart: Int, boxEnd: Int)] {
            var out: [(Int, String, Int, Int)] = []
            var o = start
            while o + 8 <= end {
                guard let size = u32(o), size != 1, let t = fourcc(o + 4) else { break }
                let boxSize = size == 0 ? (end - o) : Int(size)
                guard boxSize >= 8, o + boxSize <= end else { break }
                out.append((o, t, o + 8, o + boxSize))
                o += boxSize
            }
            return out.map { (boxStart: $0.0, type: $0.1, payloadStart: $0.2, boxEnd: $0.3) }
        }

        guard let moov = boxes(in: 0, n).first(where: { $0.type == "moov" }) else { return nil }
        let moovChildren = boxes(in: moov.payloadStart, moov.boxEnd)

        for trak in moovChildren where trak.type == "trak" {
            let trakChildren = boxes(in: trak.payloadStart, trak.boxEnd)
            guard let mdia = trakChildren.first(where: { $0.type == "mdia" }) else { continue }
            let mdiaChildren = boxes(in: mdia.payloadStart, mdia.boxEnd)
            guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
                  fourcc(hdlr.payloadStart + 8) == "vide" else { continue }   // hdlr: v/flags(4)+pre_defined(4)+handler_type(4)
            guard let minf = mdiaChildren.first(where: { $0.type == "minf" }) else { continue }
            let minfChildren = boxes(in: minf.payloadStart, minf.boxEnd)
            guard let stbl = minfChildren.first(where: { $0.type == "stbl" }) else { continue }
            let stblChildren = boxes(in: stbl.payloadStart, stbl.boxEnd)
            // A fragmented init's stbl holds no samples; a zero-sample sdtp (box size 12 = 8 header +
            // 4 version/flags, no per-sample bytes) is the anomaly Apple TV rejects. Leave any sdtp that
            // actually describes samples (a non-fragmented init) untouched.
            guard let sdtp = stblChildren.first(where: { $0.type == "sdtp" && ($0.boxEnd - $0.boxStart) == 12 })
            else { continue }

            var out = Array(b[0..<sdtp.boxStart]) + Array(b[sdtp.boxEnd..<n])
            let removed = sdtp.boxEnd - sdtp.boxStart
            // sdtp is nested stbl>minf>mdia>trak>moov; every ancestor header precedes sdtp.boxStart (so its
            // offset is unchanged in `out`), and each ancestor shrinks by the removed box's size.
            func patchSize(at boxStart: Int, sub: Int) {
                let old = (UInt32(out[boxStart]) << 24) | (UInt32(out[boxStart + 1]) << 16)
                        | (UInt32(out[boxStart + 2]) << 8) | UInt32(out[boxStart + 3])
                let new = old - UInt32(sub)
                out[boxStart] = UInt8(new >> 24 & 0xFF); out[boxStart + 1] = UInt8(new >> 16 & 0xFF)
                out[boxStart + 2] = UInt8(new >> 8 & 0xFF); out[boxStart + 3] = UInt8(new & 0xFF)
            }
            for ancestor in [stbl.boxStart, minf.boxStart, mdia.boxStart, trak.boxStart, moov.boxStart] {
                patchSize(at: ancestor, sub: removed)
            }
            return out
        }
        return nil
    }
}
