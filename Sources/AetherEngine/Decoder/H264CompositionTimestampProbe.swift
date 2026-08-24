import Foundation
import Libavcodec
import Libavutil

/// #409: detects seekable MP4/H.264 VOD whose container omitted composition timestamps even though the
/// bitstream uses reordered pictures. Stream-copying that shape into HLS-fMP4 preserves `PTS == DTS`;
/// AVPlayer then presents each future reference picture before the B pictures that precede it, producing
/// a small but continuous forward/backward judder. libavcodec's decoded `best_effort_timestamp` repairs
/// the presentation axis from picture order, so a confirmed source is routed through the software host.
enum H264CompositionTimestampProbe {

    enum Verdict: Equatable, Sendable {
        case notApplicable
        case healthy
        case repairWithBestEffortPTS
        case inconclusive
    }

    struct RoutingDecision: Equatable, Sendable {
        let useSoftwarePath: Bool
        let frameTimestampPolicy: SoftwareFrameTimestampPolicy
        let appliesTimestampRepair: Bool
    }

    /// Tracks whether libavformat's read position is still reusable. The state flips before
    /// `readPacket()` because an EOF/error return may follow partial input consumption.
    struct InputPositionState: Equatable, Sendable {
        private(set) var requiresRewind = false

        mutating func beginReadAttempt() {
            requiresRewind = true
        }
    }

    struct Evidence: Equatable, Sendable {
        var videoPackets = 0
        var validTimestampPairs = 0
        var nonKeyPackets = 0
        var sawCompositionOffset = false
        var decodedFrames = 0
        var validBestEffortFrames = 0
        var bestEffortAdvances = 0
        var bestEffortRegressions = 0
        var rawPTSRegressions = 0
        var rawPTSDiffersFromBestEffort = 0
    }

    struct Result: Sendable {
        let verdict: Verdict
        let evidence: Evidence
        let reason: String
        /// `true` after any `readPacket()` attempt, including one that returned EOF or threw after
        /// libavformat had already consumed bytes. The caller must then rewind or discard the demuxer.
        let requiresRewind: Bool

        init(
            verdict: Verdict,
            evidence: Evidence,
            reason: String,
            requiresRewind: Bool = false
        ) {
            self.verdict = verdict
            self.evidence = evidence
            self.reason = reason
            self.requiresRewind = requiresRewind
        }

        var summary: String {
            let e = evidence
            return "verdict=\(verdict) reason=\(reason) rewind_required=\(requiresRewind ? 1 : 0) "
                + "packets=\(e.videoPackets) "
                + "valid_pairs=\(e.validTimestampPairs) nonkey=\(e.nonKeyPackets) "
                + "decoded=\(e.decodedFrames) best_valid=\(e.validBestEffortFrames) "
                + "best_advances=\(e.bestEffortAdvances) best_regressions=\(e.bestEffortRegressions) "
                + "raw_regressions=\(e.rawPTSRegressions) raw_best_differences=\(e.rawPTSDiffersFromBestEffort)"
        }
    }

    static let videoPacketTarget = 64
    static let minimumTimestampPairs = 32
    static let minimumNonKeyPackets = 16
    static let minimumDecodedFrames = 16
    static let minimumBestEffortAdvances = 8
    static let packetBudget = 600
    static let wallClockBudget: TimeInterval = 3.0
    static let rewindBudget: TimeInterval = 3.0

    /// Bridges probe evidence into the two engine settings that must move together. Non-repair
    /// verdicts preserve whatever route the codec/interlace policy already selected and leave the
    /// normal decoded-PTS policy in place.
    static func routingDecision(
        for verdict: Verdict,
        preservingSoftwarePath useSoftwarePath: Bool
    ) -> RoutingDecision {
        guard verdict == .repairWithBestEffortPTS else {
            return RoutingDecision(
                useSoftwarePath: useSoftwarePath,
                frameTimestampPolicy: .decodedPTS,
                appliesTimestampRepair: false
            )
        }
        return RoutingDecision(
            useSoftwarePath: true,
            frameTimestampPolicy: .bestEffort,
            appliesTimestampRepair: true
        )
    }

    /// Pure evidence decision, split out so every fail-closed threshold has focused coverage.
    static func classify(_ evidence: Evidence) -> Verdict {
        if evidence.sawCompositionOffset { return .healthy }
        guard evidence.validTimestampPairs >= minimumTimestampPairs,
              evidence.nonKeyPackets >= minimumNonKeyPackets,
              evidence.decodedFrames >= minimumDecodedFrames,
              evidence.validBestEffortFrames >= minimumDecodedFrames,
              evidence.bestEffortAdvances >= minimumBestEffortAdvances,
              evidence.bestEffortRegressions == 0 else {
            return .inconclusive
        }
        // A raw/best-effort difference alone is not enough to leave hardware decode: only an
        // observed backward step on the raw axis proves the native stream-copy result is unstable.
        return evidence.rawPTSRegressions > 0 ? .repairWithBestEffortPTS : .healthy
    }

    static func isMeaningfulRawPTSRegression(
        previous: Int64,
        current: Int64,
        nominalFrameTicks: Int64
    ) -> Bool {
        guard current < previous else { return false }
        let threshold = max(1, nominalFrameTicks / 2)
        let (delta, overflowed) = previous.subtractingReportingOverflow(current)
        return overflowed || delta >= threshold
    }

    /// Reads a bounded head sample and decodes only enough frames to prove that the raw frame PTS
    /// regresses while libavcodec's best-effort presentation clock stays monotonic. This moves the
    /// demuxer read position; the caller must seek it back before handing it to a playback host.
    static func run(
        demuxer: Demuxer,
        streamIndex: Int32,
        packetBudget: Int = H264CompositionTimestampProbe.packetBudget,
        wallClockBudget: TimeInterval = H264CompositionTimestampProbe.wallClockBudget
    ) -> Result {
        let empty = Evidence()
        let containerNames = demuxer.containerFormatName?.split(separator: ",") ?? []
        guard containerNames.contains("mov") || containerNames.contains("mp4") else {
            return Result(verdict: .notApplicable, evidence: empty, reason: "not ISO-BMFF")
        }
        guard streamIndex >= 0,
              let stream = demuxer.stream(at: streamIndex),
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_id == AV_CODEC_ID_H264,
              codecpar.pointee.field_order == AV_FIELD_PROGRESSIVE,
              codecpar.pointee.video_delay > 0 else {
            return Result(
                verdict: .notApplicable, evidence: empty,
                reason: "requires progressive H.264 with reorder delay")
        }
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264),
              let context = avcodec_alloc_context3(codec) else {
            return Result(verdict: .inconclusive, evidence: empty, reason: "decoder unavailable")
        }
        var ownedContext: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&ownedContext) }

        guard avcodec_parameters_to_context(context, codecpar) >= 0 else {
            return Result(verdict: .inconclusive, evidence: empty, reason: "parameters_to_context failed")
        }
        context.pointee.pkt_timebase = stream.pointee.time_base
        context.pointee.get_format = { _, formats in
            guard let formats else { return AV_PIX_FMT_NONE }
            var index = 0
            while formats[index] != AV_PIX_FMT_NONE {
                if formats[index] != AV_PIX_FMT_VIDEOTOOLBOX { return formats[index] }
                index += 1
            }
            return AV_PIX_FMT_YUV420P
        }
        context.pointee.skip_loop_filter = AVDISCARD_ALL
        context.pointee.thread_count = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        context.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        var options: OpaquePointer?
        av_dict_set(&options, "hwaccel", "none", 0)
        let openResult = avcodec_open2(context, codec, &options)
        av_dict_free(&options)
        guard openResult >= 0 else {
            return Result(
                verdict: .inconclusive, evidence: empty,
                reason: "decoder open failed (\(openResult))")
        }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let decodedFrame = frame else {
            return Result(verdict: .inconclusive, evidence: empty, reason: "frame alloc failed")
        }
        defer { av_frame_free(&frame) }

        let rate = stream.pointee.avg_frame_rate.num > 0 && stream.pointee.avg_frame_rate.den > 0
            ? stream.pointee.avg_frame_rate : stream.pointee.r_frame_rate
        let timeBase = stream.pointee.time_base
        let nominalFrameTicks: Int64 = {
            guard rate.num > 0, rate.den > 0, timeBase.num > 0, timeBase.den > 0 else { return 1 }
            let ticks = Double(rate.den) * Double(timeBase.den)
                / (Double(rate.num) * Double(timeBase.num))
            return max(1, Int64(ticks.rounded()))
        }()
        var evidence = Evidence()
        var packetsRead = 0
        var inputPosition = InputPositionState()
        var lastRawPTS: Int64?
        var lastBestEffortPTS: Int64?
        let boundedWallClockBudget = max(0, wallClockBudget)
        let deadline = Date(timeIntervalSinceNow: boundedWallClockBudget)

        // The Date check bounds CPU work and packet count; the AVIO deadline also wakes a stalled
        // read between transport callbacks. As with the engine's other bounded demuxer operations,
        // one already-running transport request may overshoot by its own request timeout.
        demuxer.beginReadDeadline(secondsFromNow: boundedWallClockBudget)
        defer { demuxer.endReadDeadline() }

        func drainFrames() {
            while avcodec_receive_frame(context, decodedFrame) >= 0 {
                evidence.decodedFrames += 1
                let rawPTS = decodedFrame.pointee.pts
                let bestPTS = decodedFrame.pointee.best_effort_timestamp

                if rawPTS != Int64.min {
                    if let lastRawPTS,
                       isMeaningfulRawPTSRegression(
                           previous: lastRawPTS,
                           current: rawPTS,
                           nominalFrameTicks: nominalFrameTicks) {
                        evidence.rawPTSRegressions += 1
                    }
                    lastRawPTS = rawPTS
                }
                if bestPTS != Int64.min {
                    evidence.validBestEffortFrames += 1
                    if let lastBestEffortPTS {
                        if bestPTS < lastBestEffortPTS {
                            evidence.bestEffortRegressions += 1
                        } else if bestPTS > lastBestEffortPTS {
                            evidence.bestEffortAdvances += 1
                        }
                    }
                    lastBestEffortPTS = bestPTS
                }
                if rawPTS != Int64.min, bestPTS != Int64.min, rawPTS != bestPTS {
                    evidence.rawPTSDiffersFromBestEffort += 1
                }
                av_frame_unref(decodedFrame)
            }
        }

        while evidence.videoPackets < videoPacketTarget,
              packetsRead < packetBudget,
              Date() < deadline {
            // av_read_frame may consume input before returning EOF or an error. Mark the position
            // dirty before entering it, not only after a packet was produced.
            inputPosition.beginReadAttempt()
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                break
            }
            guard let packet else { break }
            packetsRead += 1
            var ownedPacket: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&ownedPacket) }
            guard packet.pointee.stream_index == streamIndex else { continue }

            evidence.videoPackets += 1
            if (packet.pointee.flags & AV_PKT_FLAG_KEY) == 0 {
                evidence.nonKeyPackets += 1
            }
            let pts = packet.pointee.pts
            let dts = packet.pointee.dts
            if pts != Int64.min, dts != Int64.min {
                evidence.validTimestampPairs += 1
                if pts != dts {
                    evidence.sawCompositionOffset = true
                    return Result(
                        verdict: .healthy,
                        evidence: evidence,
                        reason: "observed PTS-DTS offset",
                        requiresRewind: true
                    )
                }
            }

            var sendResult = avcodec_send_packet(context, packet)
            if sendResult == FFmpegErr.eagain {
                drainFrames()
                sendResult = avcodec_send_packet(context, packet)
            }
            if sendResult >= 0 { drainFrames() }
        }

        let verdict = classify(evidence)
        let reason: String
        switch verdict {
        case .repairWithBestEffortPTS:
            reason = "missing composition offsets with decoded PTS regression"
        case .healthy:
            reason = "decoded presentation timestamps are coherent"
        case .inconclusive:
            reason = "sample did not meet fail-closed evidence thresholds"
        case .notApplicable:
            reason = "not applicable"
        }
        return Result(
            verdict: verdict,
            evidence: evidence,
            reason: reason,
            requiresRewind: inputPosition.requiresRewind
        )
    }
}
