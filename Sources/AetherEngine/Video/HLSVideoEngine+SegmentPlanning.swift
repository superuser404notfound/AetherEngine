import Foundation
import AetherLibavcodec
import AetherLibavutil

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

    /// Whether the cue prewarm may run at all (AE#550).
    ///
    /// The prewarm exists to make libavformat load a container index by seeking into the middle of the
    /// file, and it is priced as "one or two byte-range reads, and a seek that fails fast where it
    /// cannot". On a source the demuxer cannot reposition, the second half of that price is wrong:
    /// libavformat implements a forward seek on a non-seekable pb by READING and discarding, so the
    /// prewarm walks to the middle of the source, and on an origin that answers exactly one unranged
    /// GET there is no second pass for the producer to read.
    ///
    /// Measured on a range-less HTTPS origin (a 30.9 MB MKV, `--sequential-origin`): the prewarm
    /// reported success after 2.5 s having consumed the whole file, and the session died on
    /// `#126 VOD pump reached eof without producing anything (0 packets written, 0 segments cached)`.
    /// With the prewarm skipped the same source plans on uniform stride and plays.
    ///
    /// The line below this one in the planner already skips its IRAP spacing scan for the same reason
    /// ("the scan would consume the non-replayable prefix"); this closes the larger hole above it.
    /// A segmented reader is excluded for the AE#268 reason instead: it has no index to load and every
    /// reposition refetches a segment.
    static func cuePrewarmMayRun(hasSegmentedReader: Bool, isSourceSeekable: Bool) -> Bool {
        !hasSegmentedReader && isSourceSeekable
    }

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
    ///
    /// [MovieClaw P18] A third witness, **tail**: the span must also reach to within `maxTrailingGapSeconds` of the
    /// source duration. An index that stops early by minutes is not "dense but short", it is a partial scan:
    /// an MKV whose Cues are missing or point past EOF (an incomplete download) leaves only what the capped
    /// prewarm walked, and the keyframe planner then emits a last segment from the final scanned keyframe to
    /// the end of the title (device, 2026-09-28: 205 s → 5933 s), which the producer can never finish and
    /// AVPlayer waits on forever. 60 s tolerates a long final GOP or a container duration padded by a
    /// trailing audio / subtitle track.
    /// An index failing any witness is routed to the uniform-stride fallback.
    static func keyframeIndexIsTrustworthy(
        keyframes: [Int64],
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double,
        maxTrustedGapSeconds: Double = Swift.max(HLSVideoEngine.targetSegmentDuration * 4, 30),
        minCoverageSeconds: Double = HLSVideoEngine.targetSegmentDuration,
        maxTrailingGapSeconds: Double = 60
    ) -> Bool {
        guard keyframes.count >= 2,
              sourceDurationSeconds > 0,
              videoTimeBase.num > 0, videoTimeBase.den > 0 else { return false }
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        let sorted = keyframes.sorted()
        // In Double: an index spanning both Int64 extremes overflows the integer difference (audit HLS-102).
        let coverageSeconds = (Double(sorted[sorted.count - 1]) - Double(sorted[0])) * tb
        guard coverageSeconds >= minCoverageSeconds else { return false }
        guard sourceDurationSeconds - coverageSeconds <= maxTrailingGapSeconds else { return false }  // [MovieClaw P18]
        var largestGapSeconds = 0.0
        for i in 1..<sorted.count {
            let gapSeconds = (Double(sorted[i]) - Double(sorted[i - 1])) * tb
            if gapSeconds > largestGapSeconds { largestGapSeconds = gapSeconds }
        }
        return largestGapSeconds <= maxTrustedGapSeconds
    }

    /// What a bitstream scan learned about the source's random-access spacing (#358).
    enum KeyframeSpacing: Equatable {
        /// Two consecutive IRAPs were seen this far apart.
        case measured(Double)
        /// The budget was spent holding one IRAP, so the spacing is at least this.
        case exceedsBudget(Double)
        /// The scan reached the end of the source holding one IRAP: it has no second random-access
        /// point at all, so no grid can be finer than the source itself.
        case singleKeyframeInSource(Double)
        /// No IRAP at all, or the scan could not read.
        case unknown
    }

    /// How far the #358 spacing scan reads before giving up, in seconds of content.
    static let keyframeSpacingScanBudgetSeconds: Double = 30

    /// Stride for the uniform fallback plan: never finer than the source's measured IRAP spacing (#358).
    ///
    /// A grid finer than the GOP advertises boundaries no keyframe sits on, and the keyframe-gated
    /// cutter (#92) opens a segment only at the IRAP that reaches a boundary. Every boundary the IRAP
    /// stepped over is then an index that gets no segment while the playlist still offers it, so
    /// AVPlayer fetches it, waits out the slow threshold and stalls for good. A stride at or above the
    /// spacing puts at least one IRAP in every window, so every index is opened.
    ///
    /// The index cannot answer this. It is untrustworthy by the time this path runs, and its entries
    /// are whatever `find_stream_info` plus the cue prewarm happened to scan: a 10 s-GOP TS measured
    /// here indexed 1.400, 59.960, 60.000, 60.280, 121.360, whose smallest gap (0.04 s) and largest
    /// (58.6 s) both miss the real 10 s by an order of magnitude in opposite directions.
    static func uniformStrideSeconds(spacing: KeyframeSpacing) -> Double {
        switch spacing {
        case .measured(let seconds) where seconds.isFinite && seconds > 0:
            return Swift.max(targetSegmentDuration, seconds)
        case .exceedsBudget(let seconds) where seconds.isFinite && seconds > 0,
             .singleKeyframeInSource(let seconds) where seconds.isFinite && seconds > 0:
            // Coarser than anything the scan could confirm. A source whose GOP outruns the budget
            // keeps holes, which is why the budget is logged with the plan rather than hidden.
            return Swift.max(targetSegmentDuration, seconds)
        default:
            return upstreamSegmentTargetSeconds   // [MovieClaw P33] 间隔未知不按 2 秒切
        }
    }

    /// Distance between the first two IRAPs at-or-after `fromSeconds`, read from the bitstream (#358).
    ///
    /// Only the untrusted-index path needs this, so the cost is paid exactly where the alternative is
    /// a plan that starves the session. Consumes packets and leaves the demuxer wherever it stopped,
    /// which matches `rebuildHEVCExtradataWithInBandParameterSets` above and the cue prewarm before it:
    /// nothing downstream of planning depends on the read cursor.
    func measureKeyframeSpacing(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        videoTimeBase: AVRational,
        fromSeconds: Double
    ) -> KeyframeSpacing {
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return .unknown }
        let budget = Self.keyframeSpacingScanBudgetSeconds
        demuxer.seek(to: Swift.max(0, fromSeconds))

        var firstKeyframe: Int64?
        // Backstop against a stream that yields no video packet at all; the budget below is the
        // real bound for anything that does.
        var packetsRead = 0
        let readBudget = 20_000

        while packetsRead < readBudget {
            let readResult: UnsafeMutablePointer<AVPacket>?
            do {
                readResult = try demuxer.readPacket()
            } catch {
                break
            }
            guard let pkt = readResult else { break }
            defer {
                var maybePkt: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&maybePkt)
            }
            packetsRead += 1
            guard pkt.pointee.stream_index == videoStreamIndex else { continue }
            let stamp = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
            guard stamp != Int64.min else { continue }
            guard let first = firstKeyframe else {
                if pkt.pointee.flags & AV_PKT_FLAG_KEY != 0 { firstKeyframe = stamp }
                continue
            }
            let elapsed = Double(stamp &- first) * tb
            if pkt.pointee.flags & AV_PKT_FLAG_KEY != 0, elapsed > 0 {
                return .measured(elapsed)
            }
            if elapsed > budget { return .exceedsBudget(budget) }
        }
        // Loop left on EOF or on the read backstop, not on the content budget: with one IRAP in hand
        // the source has no second one, which is a different statement from "the GOP is long".
        return firstKeyframe != nil ? .singleKeyframeInSource(budget) : .unknown
    }

    /// Most segments any plan builder emits (audit HLS-102). A week at the 4 s target is 151,200.
    static let maxPlanSegments = 200_000

    /// `base + seconds / tb` in ticks, nil when the result leaves the tick range (audit HLS-102): the
    /// builders are fed container durations and manifest sums, and `Int64(_:)` traps on NaN, infinity
    /// and anything past `Int64`. Truncates like the plain conversion it replaces.
    static func planPts(_ base: Int64, plusSeconds seconds: Double, timeBase tb: Double) -> Int64? {
        let ticks = seconds / tb
        guard ticks.isFinite, abs(ticks) < Demuxer.maxPlausibleIndexTicks else { return nil }
        let (pts, overflow) = base.addingReportingOverflow(Int64(ticks))
        return overflow ? nil : pts
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
        startPts0: Int64 = 0,
        strideSeconds: Double = HLSVideoEngine.targetSegmentDuration,
        firstSegmentSeconds: Double? = nil   // [MovieClaw patch P3]
    ) -> [Segment] {
        guard sourceDurationSeconds > 0, sourceDurationSeconds.isFinite else { return [] }
        var stride = strideSeconds.isFinite && strideSeconds > 0 ? strideSeconds : Self.targetSegmentDuration
        // Audit HLS-102: a stride this fine over a header-stated duration asked for trillions of
        // segments. Widen it instead, so the plan still covers the whole duration.
        if sourceDurationSeconds / stride > Double(maxPlanSegments) {
            stride = sourceDurationSeconds / Double(maxPlanSegments)
        }
        // [MovieClaw patch P3] segment 0 spans [0, first), segment i >= 1 spans [first + (i-1)*stride, first + i*stride)
        let first = firstSegmentSeconds.flatMap { $0.isFinite && $0 > 0 ? Swift.min($0, stride) : nil } ?? stride
        let count = min(maxPlanSegments, sourceDurationSeconds <= first
            ? 1 : 1 + Int(ceil((sourceDurationSeconds - first) / stride)))
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }

        var plan: [Segment] = []
        plan.reserveCapacity(count)
        for i in 0..<count {
            let startSeconds = i == 0 ? 0 : first + Double(i - 1) * stride
            let endSeconds = i + 1 == count ? sourceDurationSeconds : min(sourceDurationSeconds, first + Double(i) * stride)
            guard let startPts = planPts(startPts0, plusSeconds: startSeconds, timeBase: tb),
                  let endPts = planPts(startPts0, plusSeconds: endSeconds, timeBase: tb) else { return [] }
            plan.append(Segment(
                startPts: startPts,
                endPts: endPts,
                startSeconds: startSeconds,
                durationSeconds: max(0.001, endSeconds - startSeconds)
            ))
        }
        return plan
    }

    /// Backoff applied to every boundary of a plan built from a source's DECLARED segment starts.
    ///
    /// The manifest axis (EXTINF sums) and the container's real PTS are two measurements of the same
    /// boundary, and they differ by whatever the segmenter rounded. A boundary that lands even a
    /// millisecond PAST its own IRAP is worse than one that lands early: the producer's scan-forward
    /// gate takes the first keyframe at-or-after the boundary, so it skips the whole segment and opens
    /// a GOP late. Pulling each boundary slightly below its segment start keeps the IRAP inside the
    /// segment it is supposed to open. Capped below half the shortest segment so a backed-off boundary
    /// can never reach back to the PREVIOUS segment's IRAP.
    static func segmentedPlanBoundaryBackoff(shortestSegmentSeconds: Double) -> Double {
        guard shortestSegmentSeconds > 0 else { return 0 }
        return min(0.5, shortestSegmentSeconds / 2)
    }

    /// Plan built from a segmented source's own boundaries (AE#268: the HLS VOD ingest's EXTINF sums).
    ///
    /// A segmented source declares where its random-access points are, and those are the only
    /// boundaries the plan may advertise. The uniform fallback ignores that and lays a 4 s grid over a
    /// source whose GOP can be much longer: on the reporter's 10 s-GOP MPEG-TS VOD only every fifth
    /// grid boundary coincided with an IRAP, so a restart at any other index opened its gate up to 8 s
    /// (two whole plan segments) late, and every downstream index mapping skewed by that overshoot
    /// until AVPlayer starved on a segment that never arrived (CoreMediaErrorDomain -12889). Boundaries
    /// that ARE the source's own segment starts make the overshoot structurally zero.
    ///
    /// `startPts0` anchors the source axis exactly like the other two builders (plan time 0 = the
    /// content start), so `startSeconds` stays 0-based and every consumer's source <-> item mapping is
    /// unchanged.
    static func buildSegmentedSourcePlan(
        segmentStartsSeconds: [Double],
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double,
        startPts0: Int64
    ) -> [Segment] {
        guard segmentStartsSeconds.count >= 2, sourceDurationSeconds > 0,
              videoTimeBase.num > 0, videoTimeBase.den > 0 else { return [] }
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }
        let starts = segmentStartsSeconds
        guard starts[0] == 0 else { return [] }

        var shortest = Double.greatestFiniteMagnitude
        for i in 1..<starts.count {
            let span = starts[i] - starts[i - 1]
            guard span > 0 else { return [] }  // non-monotonic manifest: leave the source on the fallback
            shortest = Swift.min(shortest, span)
        }
        // The manifest's own duration ends the final segment. A duration that does not even reach the
        // last start is not usable (an estimate on a truncated container), so that case falls back to
        // one more segment rather than a zero-length tail.
        let lastStart = starts[starts.count - 1]
        let end = sourceDurationSeconds > lastStart ? sourceDurationSeconds : lastStart + shortest
        let backoff = segmentedPlanBoundaryBackoff(shortestSegmentSeconds: shortest)

        // Segment 0 keeps the content start itself: there is nothing below it to back off toward, and
        // the head-of-stream gate has no restart target anyway.
        func boundaryPts(_ i: Int) -> Int64? {
            i == 0 ? startPts0 : planPts(startPts0, plusSeconds: starts[i] - backoff, timeBase: tb)
        }

        var plan: [Segment] = []
        plan.reserveCapacity(starts.count)
        for i in 0..<starts.count {
            let endSeconds = i + 1 < starts.count ? starts[i + 1] : end
            guard let startPts = boundaryPts(i),
                  let endPts = i + 1 < starts.count
                    ? boundaryPts(i + 1) : planPts(startPts0, plusSeconds: end, timeBase: tb)
            else { return [] }
            plan.append(Segment(
                startPts: startPts,
                endPts: endPts,
                startSeconds: starts[i],
                durationSeconds: Swift.max(0.001, endSeconds - starts[i])
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
        let firstTarget = Self.firstSegmentTargetDuration   // [MovieClaw patch P3]

        let sorted = keyframes.sorted()
        let startPts0 = sorted[0]

        var plan: [Segment] = []
        plan.reserveCapacity(sorted.count)
        var i = 0
        var segIdx = 0
        // Audit HLS-102: the index spread must fit `Int64` for the offsets below.
        guard !sorted[sorted.count - 1].subtractingReportingOverflow(startPts0).overflow else { return [] }
        while i < sorted.count {
            let segStartPts = sorted[i]
            let segStartSeconds = Double(segStartPts - startPts0) * tb
            // [MovieClaw patch P3] absolute thresholds F, F+T, F+2T, ... (upstream: (N+1)*T)
            let thresholdSeconds = firstTarget + Double(segIdx) * target

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
                guard let finalEndPts = planPts(startPts0, plusSeconds: sourceDurationSeconds, timeBase: tb) else {
                    return []
                }
                segEndPts = finalEndPts
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

    /// Scan packets for in-band VPS/SPS/PPS when hvcC `numOfArrays=0` (DV P5 MP4 encoders, e.g. Wandering Earth 2 WEB-DL, issue #19). AVPlayer symptom: `item.tracks count=2`, `fourCC=<no fdesc>`, `CoreMediaErrorDomain -4`. On a source that can rewind the scan consumes packets and the caller must seek back; on a forward-only one it only peeks (`scanSourceHead`).
    ///
    /// `rewindBeforeScan` rewinds to the head first, because in-band parameter sets are guaranteed at
    /// the first IRAP but only recur every GOP after it. Without the rewind the scan inherited whatever
    /// cursor the cue prewarm and the plan pass had left behind and read 16 mid-GOP packets, so on a
    /// real film (263 s, IRAPs ~2 s apart) it found nothing, the muxer emitted an empty hvcC, and
    /// AVPlayer buffered the forward window without ever rendering a frame (AetherPlayer#2). Pass
    /// `false` for a live, forward-only feed, which cannot rewind.
    /// Is this an hvcC that declares no parameter-set arrays, i.e. the #19 case the scan exists for?
    ///
    /// The `configurationVersion == 1` check is what keeps Annex-B extradata out. Bytes 21 and 22 of
    /// an Annex-B HEVC config record pass the other two checks by construction, not by luck: the
    /// profile_tier_level in a Main10 VPS carries the emulation-prevention pattern `00 00 03` right
    /// there, so byte 21 reads back as naluLengthSize 4 and byte 22 as numOfArrays 0, and the scan
    /// would run over a buffer that is not a record at all (#365). `canonicalizeHEVCConfigRecord`
    /// has always had this guard; this path never did.
    static func configRecordNeedsInBandRebuild(
        _ extradata: UnsafePointer<UInt8>, size: Int
    ) -> Bool {
        guard size >= 23 else { return false }
        guard extradata[0] == 1 else { return false }
        guard extradata[22] == 0 else { return false }   // numOfArrays; non-zero means already populated
        return Int(extradata[21] & 0x03) + 1 == 4        // naluLengthSize, byte 21 lower 2 bits + 1
    }

    func rebuildHEVCExtradataWithInBandParameterSets(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        codecpar: UnsafePointer<AVCodecParameters>,
        rewindBeforeScan: Bool = true
    ) -> [UInt8]? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else { return nil }
        let extradataSize = Int(codecpar.pointee.extradata_size)
        guard extradataSize >= 23, let extradata = codecpar.pointee.extradata else { return nil }
        guard Self.configRecordNeedsInBandRebuild(extradata, size: extradataSize) else { return nil }
        let naluLengthSize = 4   // the predicate above already required it

        var vps: [UInt8]?
        var sps: [UInt8]?
        var pps: [UInt8]?
        // Counted in VIDEO packets: a film interleaves audio and dozens of subtitle tracks, which
        // would otherwise exhaust the budget before the first video packet.
        let packetBudget = 16
        var packetsScanned = 0
        // Second cap so a stream that never yields a video packet cannot walk the whole source.
        let readBudget = 512

        scanSourceHead(demuxer: demuxer, rewind: rewindBeforeScan, readBudget: readBudget) { pkt in
            if pkt.pointee.stream_index != videoStreamIndex { return false }
            packetsScanned += 1
            guard let pktData = pkt.pointee.data else { return packetsScanned >= packetBudget }
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

            return (vps != nil && sps != nil && pps != nil) || packetsScanned >= packetBudget
        }

        guard let vps, let sps, let pps else {
            EngineLog.emit(
                "[HLSVideoEngine] in-band parameter-set scan found none: "
                + "packets=\(packetsScanned) vps=\(vps != nil) sps=\(sps != nil) pps=\(pps != nil)",
                category: .session
            )
            return nil
        }

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

    /// Shows the packets at the head of the source to `inspect`, which returns true once it has seen
    /// enough, looking at no more than `readBudget` of them.
    ///
    /// A source that can rewind is rewound (when `rewind`) and the packets are CONSUMED, which is
    /// what these scans always did: `start()` seeks back to 0 afterwards. A source that cannot rewind
    /// has nothing to seek back with, so whatever the scan consumed is gone from the archive
    /// (audit HLS-103: a sequential origin lost its opening GOP to the framing probe). Those are
    /// PEEKED instead: the packets the scan looked at stay queued for the producer.
    func scanSourceHead(
        demuxer: Demuxer,
        rewind: Bool,
        readBudget: Int,
        _ inspect: (UnsafeMutablePointer<AVPacket>) -> Bool
    ) {
        guard demuxer.isSourceSeekable else {
            try? demuxer.peekPackets(maxPackets: readBudget, inspect)
            return
        }
        if rewind { demuxer.seek(to: 0) }
        var packetsRead = 0
        while packetsRead < readBudget {
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
            packetsRead += 1
            if inspect(pkt) { break }
        }
    }

    /// What the muxer should ship for a source whose config record is Annex B (#365), and the
    /// framing every NAL walker in the session should use.
    struct VideoFramingNormalization {
        /// Replacement config record, or nil to forward the source extradata unchanged.
        let extradataOverride: [UInt8]?
        /// Framing measured on real packets, or nil when nothing was measured (live, or the muxer was
        /// never going to reformat this track anyway). Callers fall back to deriving it from the
        /// extradata, which is only safe while the two agree.
        let measuredFraming: VideoNALFraming?
        /// [MovieClaw P38] 样本仍是 Annex B，但配置记录已换成 hvcC：封装层自己把样本转成长度前缀、保留带内参数集
        var annexBSamplesKeepParameterSets = false
    }

    /// Measure the video NAL framing on packets, then decide what config record the muxer gets.
    ///
    /// The framing question has always been answered from the extradata (`A53SEIParser.nalFraming`,
    /// and movenc's own test). That answer is right for every source where the two agree and silently
    /// destructive for one where they do not: with Annex-B extradata movenc converts every sample
    /// through `ff_hevc_annexb2mp4`, which on MP4-framed samples finds start codes only where a NAL
    /// length happens to read as `00 00 01` and drops everything else. Measured 1080p: a 2,158,448 B
    /// segment came out at 61,912 B, AVPlayer reached `readyToPlay` and never produced a frame.
    ///
    /// On a source that can rewind it consumes packets and leaves the demuxer cursor where it
    /// stopped; `start()` seeks back to 0 afterwards, same contract as the in-band scan and the cue
    /// prewarm. A forward-only source is peeked instead (`scanSourceHead`), so the producer still
    /// receives the packets the probe looked at.
    func normalizeVideoFraming(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        codecpar: UnsafePointer<AVCodecParameters>,
        isLive: Bool
    ) -> VideoFramingNormalization {
        let codecID = codecpar.pointee.codec_id
        guard VideoConfigRecord.muxerWillReformatPackets(
            codecID: codecID,
            extradata: codecpar.pointee.extradata.map { UnsafePointer($0) },
            size: Int(codecpar.pointee.extradata_size))
        else { return VideoFramingNormalization(extradataOverride: nil, measuredFraming: nil) }

        // Live is Annex B on both ends by construction (MPEG-TS, HLS ingest), so the two agree and
        // there is nothing to repair; the probe would only cost packets off a forward-only feed.
        guard !isLive else {
            return VideoFramingNormalization(extradataOverride: nil, measuredFraming: .annexB)
        }

        let framing = probeVideoNALFraming(demuxer: demuxer, videoStreamIndex: videoStreamIndex)
        guard case .lengthPrefixed = framing else {
            // The record stays Annex B here: movenc reads it to decide whether to convert the samples,
            // and these samples do need converting. What it must not keep is a prefix SEI, because the
            // hvcC movenc then builds carries it as a fourth array (`ff_isom_write_hvcc` collects five
            // NAL types) and Apple TV's HEVC track builder rejects such a record (AE#187). That defense
            // sits on the record path and cannot see this one, so the SEI goes before the muxer runs.
            let source = codecpar.pointee.extradata.map {
                [UInt8](UnsafeBufferPointer(start: $0, count: Int(codecpar.pointee.extradata_size)))
            } ?? []
            let canonical = codecID == AV_CODEC_ID_HEVC
                ? VideoConfigRecord.canonicalizeAnnexBHEVCConfigRecord(source) : nil
            EngineLog.emit(
                "[HLSVideoEngine] #365 the muxer will reformat this track's samples and the packets "
                + "are \(framing == nil ? "not conclusively framed" : "Annex B"); the muxer builds the "
                + "config record itself out of \(source.count) B of Annex B "
                + "[\(VideoConfigRecord.annexBNALSummary(source))]"
                + (canonical.map {
                    ", dropped the non-parameter-set NALs before it does (→ \($0.count) B, AE#187)"
                } ?? ", nothing to drop"),
                category: .session
            )
            // [MovieClaw P38] HEVC 点播：movenc 对 hvc1 转换时会剥掉样本里的 VPS/SPS/PPS（filter_ps），init 只剩片头那一套。
            // 片中换过参数集的原盘（《黑豹2》118 秒、345.7 秒两次换 PPS）续播或播到换点后，硬解拿旧 PPS 解新切片
            // 报 Cannot Decode，真机只有声音没有画面。改由封装层自己转换并保留带内参数集，配置记录给 hvcC，movenc 不再转换
            if codecID == AV_CODEC_ID_HEVC, case .annexB = framing,
               let record = VideoConfigRecord.fromAnnexB(
                   canonical ?? source, codecID: codecID,
                   width: codecpar.pointee.width, height: codecpar.pointee.height) {
                EngineLog.emit(
                    "[HLSVideoEngine] [MovieClaw P38] HEVC Annex B 样本由封装层转换并保留带内参数集（配置记录 \(source.count) B → hvcC \(record.count) B）",
                    category: .session)
                var result = VideoFramingNormalization(extradataOverride: record, measuredFraming: framing)
                result.annexBSamplesKeepParameterSets = true
                return result
            }
            return VideoFramingNormalization(extradataOverride: canonical, measuredFraming: framing)
        }

        let source = [UInt8](UnsafeBufferPointer(
            start: codecpar.pointee.extradata!, count: Int(codecpar.pointee.extradata_size)))
        guard let record = VideoConfigRecord.fromAnnexB(
            source, codecID: codecID,
            width: codecpar.pointee.width, height: codecpar.pointee.height)
        else {
            EngineLog.emit(
                "[HLSVideoEngine] #365 Annex-B config record on a length-prefixed source, but no "
                + "config record could be built from it (\(source.count) B); the muxer will empty "
                + "the video samples", category: .session
            )
            return VideoFramingNormalization(extradataOverride: nil, measuredFraming: framing)
        }
        EngineLog.emit(
            "[HLSVideoEngine] #365 converted the Annex-B config record to a length-prefixed one: "
            + "\(source.count) B → \(record.count) B; source packets are length-prefixed, so the "
            + "muxer must not run its Annex-B converter over them",
            category: .session
        )
        return VideoFramingNormalization(extradataOverride: record, measuredFraming: framing)
    }

    /// Framing of the video packets themselves, or nil when the sample is not conclusive.
    ///
    /// Decided by "does a length-prefixed walk consume the packet exactly", never by the head bytes:
    /// a NAL of 256 to 511 bytes carries the length prefix `00 00 01 xx`, which reads as a start code
    /// to anything that only looks at the front.
    func probeVideoNALFraming(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        packetBudget: Int = 4,
        readBudget: Int = 512
    ) -> VideoNALFraming? {
        var lengthPrefixed = 0
        var annexB = 0
        var inspected = 0

        scanSourceHead(demuxer: demuxer, rewind: true, readBudget: readBudget) { pkt in
            guard pkt.pointee.stream_index == videoStreamIndex,
                  let data = pkt.pointee.data, pkt.pointee.size > 4 else { return false }
            inspected += 1
            let size = Int(pkt.pointee.size)
            if VideoConfigRecord.walksAsLengthPrefixed(data, size: size) {
                lengthPrefixed += 1
            } else if VideoConfigRecord.startsWithStartCode(data, size: size) {
                annexB += 1
            }
            return inspected >= packetBudget
        }

        let framing: VideoNALFraming?
        if lengthPrefixed > 0 && annexB == 0 {
            framing = .lengthPrefixed(size: 4)
        } else if annexB > 0 && lengthPrefixed == 0 {
            framing = .annexB
        } else {
            framing = nil
        }
        EngineLog.emit(
            "[HLSVideoEngine] video NAL framing probe: inspected=\(inspected) "
            + "lengthPrefixed=\(lengthPrefixed) annexB=\(annexB) → "
            + "\(framing.map { "\($0)" } ?? "inconclusive")",
            category: .session
        )
        return framing
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
