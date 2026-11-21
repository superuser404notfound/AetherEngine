import Foundation
import AetherLibavcodec
import AetherLibavfilter
import AetherLibavutil

/// #853: decides at load whether an interlaced NTSC source is hard-telecined film (24p put on 29.97i
/// video with the 3:2 pulldown baked into the pictures) or video shot interlaced. Film gets inverse
/// telecine and a 23.976 Hz display; everything else keeps the deinterlacer. The decision has to land
/// before the display criteria are written, so the probe sits on time-to-first-frame and is bounded by
/// frame, packet and wall-clock ceilings. Expiry is `.inconclusive`, which keeps today's behaviour.
///
/// Two signals, both after `fieldmatch` has rebuilt what film frames it can:
/// - `idet`'s per-frame verdict. Film reads progressive once its fields are matched, video stays combed
///   wherever it moves. Alone it is not enough: realistic interlaced video reads about half progressive
///   (its still stretches match trivially), and a film episode that opens on a fade made at field rate
///   reads about two thirds progressive over its first 120 frames.
/// - The 3:2 signature itself: matched film repeats one frame in every five, always at the same place
///   in the cycle, so the lowest frame-to-frame difference of each five sits at the same phase cycle
///   after cycle. The difference is the WORST 16x16 block's, not the frame mean, because a repeat is
///   exact everywhere: video made from film by motion interpolation (24p to 59.94 fields) keeps a
///   five-frame rhythm in its mean differences, but every one of its frames moves somewhere.
///
/// The sample is taken at the load's start position and decides as soon as the evidence is clean. One
/// fixed window at the middle of the file was measured against it and dropped: its seeks cost about a
/// second more on a fast link and far more on a slow one, and it never decided sooner.
///
/// Measured on the Friends S1 NTSC DVDs and video made from them (`docs/measurements.md`, #853).
enum TelecineCadenceProbe {

    /// Frame ceiling of the sample: about 10 s of 29.97 video. Every Friends S1 episode decides by
    /// frame 206 from its first frame (the opening black and fade-in come first).
    static let startFrameCeiling = 300
    /// Packet ceiling (audio and subtitle packets count too).
    static let packetBudget = 3000
    /// Wall-clock ceiling, the seek to the start position included.
    static let wallClockBudget: TimeInterval = 2.0
    /// A sample whose first this-many decoded frames carry no interlaced flag is not hard telecine
    /// (soft telecine and progressive pictures decode unflagged).
    static let unflaggedFrameLimit = 30

    /// What the load does with a source.
    enum Gate: Equatable {
        case sample
        case force
        case skip(String)
    }

    /// Whether a source is sampled, forced or left alone. `.auto` samples only VOD, seekable,
    /// NTSC-rate, SD, interlaced sources on a codec that always decodes on the software path (where
    /// the filter lives); `.force` needs the codec and the rate only.
    static func gate(
        mode: InverseTelecineMode, isLive: Bool, isSeekable: Bool, codecID: AVCodecID,
        fieldOrder: AVFieldOrder, frameRate: Double?, codedHeight: Int32
    ) -> Gate {
        if mode == .off { return .skip("LoadOptions.inverseTelecine is .off") }
        guard alwaysDecodesInSoftware(codecID) else { return .skip("the codec can route native") }
        guard let frameRate, isNTSCRate(frameRate) else { return .skip("not a 29.97 / 30 fps source") }
        guard fieldOrder != AV_FIELD_PROGRESSIVE else { return .skip("declared progressive") }
        if mode == .force { return .force }
        guard codecID == AV_CODEC_ID_MPEG2VIDEO else { return .skip("not MPEG-2") }
        guard !isLive else { return .skip("live") }
        guard isSeekable else { return .skip("the source cannot seek back after a sample") }
        guard codedHeight > 0, codedHeight <= 576 else { return .skip("not SD") }
        return .sample
    }

    /// Codecs with no native route (`VideoRoutingPolicy.requiresSoftwarePath`'s default branch): the
    /// display rate chosen for inverse telecine is then sure to meet the filter that delivers it.
    static func alwaysDecodesInSoftware(_ codecID: AVCodecID) -> Bool {
        codecID != AV_CODEC_ID_NONE && codecID != AV_CODEC_ID_H264 && codecID != AV_CODEC_ID_HEVC
            && codecID != AV_CODEC_ID_AV1
    }

    static func isNTSCRate(_ fps: Double) -> Bool {
        abs(fps - 30000.0 / 1001.0) < 0.01 || abs(fps - 30) < 0.01
    }

    /// What a sample measured, for the decision line and the comparison runs. The shares describe the
    /// span the decision read: the trailing window for an early film verdict, else the whole sample.
    struct Report: Sendable, Equatable {
        /// Frames analysed (out of `fieldmatch`).
        var frames = 0
        /// Frames of the decisive span `idet` called progressive or interlaced (the rest are
        /// undetermined: black, still).
        var decided = 0
        var progressiveShare = 0.0
        var cadenceShare = 0.0
        var elapsedMs = 0

        var summary: String {
            "progressive \(Int((progressiveShare * 100).rounded()))% of \(decided) decided frames, "
                + "cadence \(Int((cadenceShare * 100).rounded()))%, \(frames) frames in \(elapsedMs) ms"
        }
    }

    enum Verdict: Sendable, Equatable {
        case film(Report)
        case video(Report)
        case inconclusive(reason: String, Report)

        var isFilm: Bool {
            if case .film = self { return true }
            return false
        }

        var report: Report {
            switch self {
            case .film(let r), .video(let r), .inconclusive(_, let r): return r
            }
        }

        var label: String {
            switch self {
            case .film: return "film"
            case .video: return "video"
            case .inconclusive(let reason, _): return "inconclusive (\(reason))"
            }
        }
    }

    /// Sample `demuxer`'s video stream from `startSeconds` and decide. MOVES the demuxer's read position
    /// (it seeks to the start position and reads packets); the caller rewinds, as for `InterlaceProbe`.
    static func run(
        demuxer: Demuxer,
        streamIndex: Int32,
        startSeconds: Double?,
        frameRate: DeinterlaceConfig.SourceFrameRate,
        frameCeiling: Int = TelecineCadenceProbe.startFrameCeiling,
        packetBudget: Int = TelecineCadenceProbe.packetBudget,
        wallClockBudget: TimeInterval = TelecineCadenceProbe.wallClockBudget
    ) -> Verdict {
        let started = DispatchTime.now()
        var report = Report()
        func elapsedMs() -> Int { Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000) }
        func finish(_ make: (Report) -> Verdict) -> Verdict {
            report.elapsedMs = elapsedMs()
            return make(report)
        }

        guard streamIndex >= 0, let stream = demuxer.stream(at: streamIndex),
              let codecpar = stream.pointee.codecpar else {
            return finish { .inconclusive(reason: "no video stream", $0) }
        }
        let deadline = Date(timeIntervalSinceNow: wallClockBudget)
        let ceiling = frameCeiling
        // The seek spends the same budget as the reads: on a slow origin a seek alone can outlast it.
        if let startSeconds, startSeconds > 1 {
            guard demuxer.seekBounded(to: startSeconds, timeout: max(0.05, deadline.timeIntervalSinceNow)) else {
                return finish { .inconclusive(reason: "the start position did not seek", $0) }
            }
        }

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            return finish { .inconclusive(reason: "no decoder", $0) }
        }
        let ctx: UnsafeMutablePointer<AVCodecContext>
        do {
            // Software decode, as the session's software host decodes it. Unlike InterlaceProbe the
            // pixels are what is measured, so nothing that changes them (loop filter) is skipped.
            ctx = try FFmpegDecoderContext.open(
                codec: codec, codecpar: codecpar, maxPixels: FFmpegDecoderContext.maxVideoPixels,
                options: ["hwaccel": "none"]
            ) { ctx in
                ctx.pointee.get_format = FFmpegDecoderContext.softwareOnlyGetFormat
                ctx.pointee.thread_count = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
                ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
            }
        } catch {
            return finish { .inconclusive(reason: "decoder open failed", $0) }
        }
        var ownedCtx: UnsafeMutablePointer<AVCodecContext>? = ctx
        defer { avcodec_free_context(&ownedCtx) }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else { return finish { .inconclusive(reason: "frame alloc failed", $0) } }
        defer { av_frame_free(&frame) }

        let sampler = TelecineCadenceSampler(timeBase: stream.pointee.time_base, frameRate: frameRate)
        var analyzer = TelecineCadenceAnalyzer()
        var decodedFrames = 0
        var flaggedFrames = 0
        var packetsRead = 0
        var stop: Verdict?

        func record(_ evidence: TelecineCadenceAnalyzer.Evidence? = nil) {
            report.frames = analyzer.samples.count
            let evidence = evidence ?? analyzer.evidence(from: 0)
            report.decided = evidence.decided
            report.progressiveShare = evidence.progressiveShare
            report.cadenceShare = evidence.cadenceShare
        }

        /// Feeds what the decoder holds through the sampler; sets `stop` when the sample decided.
        func drain() {
            while stop == nil, avcodec_receive_frame(ctx, f) >= 0 {
                decodedFrames += 1
                if f.pointee.repeat_pict > 0 {
                    av_frame_unref(f)
                    record()
                    stop = finish { .inconclusive(reason: "soft telecine (the decoder repeats fields)", $0) }
                    return
                }
                if (f.pointee.flags & (1 << 3)) != 0 { flaggedFrames += 1 }  // AV_FRAME_FLAG_INTERLACED
                if flaggedFrames == 0, decodedFrames >= unflaggedFrameLimit {
                    av_frame_unref(f)
                    record()
                    stop = finish { .inconclusive(reason: "the frames are not interlaced", $0) }
                    return
                }
                guard let samples = sampler.push(f) else {
                    av_frame_unref(f)
                    record()
                    stop = finish { .inconclusive(reason: "the sample graph failed", $0) }
                    return
                }
                av_frame_unref(f)
                for sample in samples { analyzer.append(sample) }
                if let (decision, evidence) = analyzer.adaptiveDecision() {
                    record(evidence)
                    stop = finish { decision == .film ? .film($0) : .video($0) }
                    return
                }
                if analyzer.samples.count >= ceiling { return }
            }
        }

        while stop == nil, analyzer.samples.count < ceiling, packetsRead < packetBudget, Date() < deadline {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                break  // a read error ends the sample; what was analysed still counts
            }
            guard let packet else { break }  // EOF
            packetsRead += 1
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)  // demuxer allocs are tracked; free must stay on the tracker
            }
            guard packet.pointee.stream_index == streamIndex else { continue }
            if avcodec_send_packet(ctx, packet) == FFmpegErr.eagain {
                drain()
                _ = avcodec_send_packet(ctx, packet)
            }
            drain()
        }
        if let stop { return stop }

        let ranOutOfTime = Date() >= deadline
        let ranOutOfPackets = packetsRead >= packetBudget
        // The frames frame threading still holds, and the ones the sample graph holds back.
        if analyzer.samples.count < ceiling {
            _ = avcodec_send_packet(ctx, nil)
            drain()
            if let stop { return stop }
        }
        for sample in sampler.finish() { analyzer.append(sample) }
        if let (decision, evidence) = analyzer.adaptiveDecision() {
            record(evidence)
            return finish { decision == .film ? .film($0) : .video($0) }
        }
        record()
        if analyzer.samples.count < ceiling, ranOutOfTime || ranOutOfPackets {
            let reason = ranOutOfTime ? "wall-clock budget" : "packet budget"
            return finish { .inconclusive(reason: "\(reason) spent after \(analyzer.samples.count) frames", $0) }
        }
        let (decision, evidence) = analyzer.finalDecision()
        record(evidence)
        switch decision {
        case .film: return finish { .film($0) }
        case .video: return finish { .video($0) }
        case .undecided(let reason): return finish { .inconclusive(reason: reason, $0) }
        }
    }
}

/// #853: the pure half of the probe, the decision over per-frame samples. Unit-tested without FFmpeg.
struct TelecineCadenceAnalyzer: Sendable {

    enum FieldClass: Sendable, Equatable {
        case progressive
        case interlaced
        case undetermined
    }

    struct Sample: Sendable, Equatable {
        var fieldClass: FieldClass
        /// The largest mean absolute luma difference of any 16x16 block to the previous matched frame
        /// (0-255 scale); nil for the first frame of a sample.
        var difference: Double?
    }

    enum Decision: Sendable, Equatable {
        case film
        case video
        case undecided(String)
    }

    struct Evidence: Sendable, Equatable {
        var decided = 0
        var progressive = 0
        /// Five-frame cycles with motion (not black or frozen) in the span.
        var movingCycles = 0
        /// Consecutive moving cycles whose clear minimum sits at the same phase.
        var cadenceHits = 0
        /// Moving cycles in which even the lowest difference is real motion (`everyFrameMovesFloor`): every
        /// frame moved, so a film repeat would have shown.
        var everyFrameMovingCycles = 0

        var progressiveShare: Double { decided > 0 ? Double(progressive) / Double(decided) : 0 }
        var cadenceShare: Double { movingCycles > 1 ? Double(cadenceHits) / Double(movingCycles - 1) : 0 }
    }

    /// Decided frames the trailing window holds: two seconds of video, as little as the decision can
    /// stand on, because over a network the sample's cost is the video it has to download first.
    static let decidedWindow = 60
    /// Film: at least this share of the window's decided frames progressive after matching.
    static let filmProgressiveShare = 0.90
    /// Film: at least this share of the window's moving cycle pairs repeat a frame at the same phase.
    /// Friends S1 film reads 27-100% per window, true interlaced video 0-2% (#853).
    static let filmCadenceShare = 0.15
    /// ... and at least this many such pairs, so a short run of luck is not a cadence.
    static let minimumCadenceHits = 4
    /// A cycle's lowest difference counts as a repeated frame below this fraction of the next lowest.
    /// Strict on purpose: a 3:2 repeat differs only by coding noise, an interpolated frame by its motion.
    static let repeatedFrameRatio = 0.35
    /// A cycle whose second-lowest difference is below this has no motion to judge (black, frozen).
    static let stillCycleFloor = 1.0
    /// Early "video": the whole sample at or below this share progressive, with no cadence at all.
    static let videoProgressiveShare = 0.25
    /// Early "video" as well: this many cycles in which every frame moved, with at most
    /// `videoCadenceHits` repeats. It saves true interlaced video most of the sample's ceiling.
    /// Measured on Friends S1: 0-22% of film cycles have every frame moving (the repeat is near still),
    /// 66-95% of true video cycles, so film does not reach 20 within the 300-frame ceiling (#853).
    static let videoMovingCycles = 20
    static let videoCadenceHits = 1
    /// A cycle's lowest difference at or above this is motion, not the noise of a repeated frame.
    static let everyFrameMovesFloor = 8.0
    /// Fewer decided frames than this is no evidence either way.
    static let minimumDecided = 60

    private(set) var samples: [Sample] = []

    mutating func append(_ sample: Sample) { samples.append(sample) }

    /// Evidence over `samples[start...]`, cycles aligned on `start`.
    func evidence(from start: Int) -> Evidence {
        var e = Evidence()
        guard start < samples.count else { return e }
        for sample in samples[start...] {
            switch sample.fieldClass {
            case .progressive: e.decided += 1; e.progressive += 1
            case .interlaced: e.decided += 1
            case .undetermined: break
            }
        }
        var previousPhase: Int?
        var index = start
        while index + 5 <= samples.count {
            let cycle = samples[index..<(index + 5)].map(\.difference)
            index += 5
            guard cycle.allSatisfy({ $0 != nil }) else { previousPhase = nil; continue }
            let values = cycle.map { $0! }
            let sorted = values.enumerated().sorted { $0.element < $1.element }
            let lowest = sorted[0], second = sorted[1]
            guard second.element >= Self.stillCycleFloor else { previousPhase = nil; continue }
            e.movingCycles += 1
            if lowest.element >= Self.everyFrameMovesFloor { e.everyFrameMovingCycles += 1 }
            let repeats = lowest.element < Self.repeatedFrameRatio * second.element
            if repeats, previousPhase == lowest.offset { e.cadenceHits += 1 }
            previousPhase = repeats ? lowest.offset : nil
        }
        return e
    }

    /// Start of the trailing span that holds the last `decidedWindow` decided frames, nil while fewer.
    func trailingWindowStart() -> Int? {
        var decided = 0
        var index = samples.count
        while index > 0 {
            index -= 1
            if samples[index].fieldClass != .undetermined {
                decided += 1
                if decided == Self.decidedWindow { return index }
            }
        }
        return nil
    }

    static func isFilm(_ e: Evidence) -> Bool {
        e.decided >= minimumDecided && e.progressiveShare >= filmProgressiveShare
            && e.cadenceShare >= filmCadenceShare && e.cadenceHits >= minimumCadenceHits
    }

    /// After every frame of the sample: film as soon as the trailing window is clean film,
    /// video only when the whole sample is overwhelmingly combed with no cadence, else keep reading.
    /// Returns the evidence the decision read.
    func adaptiveDecision() -> (Decision, Evidence)? {
        guard let windowStart = trailingWindowStart() else { return nil }
        let window = evidence(from: windowStart)
        if Self.isFilm(window) { return (.film, window) }
        let all = evidence(from: 0)
        if all.progressiveShare <= Self.videoProgressiveShare, all.cadenceHits == 0 { return (.video, all) }
        if all.everyFrameMovingCycles >= Self.videoMovingCycles, all.cadenceHits <= Self.videoCadenceHits {
            return (.video, all)
        }
        return nil
    }

    /// The decision over the whole sample, when it ends without an early one: it reached its ceiling or
    /// the end of the stream. Returns the evidence
    /// the decision read.
    func finalDecision() -> (Decision, Evidence) {
        let all = evidence(from: 0)
        guard all.decided >= Self.minimumDecided else {
            return (.undecided("only \(all.decided) decided frames"), all)
        }
        if Self.isFilm(all) { return (.film, all) }
        if let windowStart = trailingWindowStart() {
            let window = evidence(from: windowStart)
            if Self.isFilm(window) { return (.film, window) }
        }
        if all.progressiveShare < 0.75 || all.cadenceShare < Self.filmCadenceShare { return (.video, all) }
        return (.undecided("no clean film window"), all)
    }
}

/// #853: runs decoded frames through `fieldmatch` (no comb scores: the probe only needs the matched
/// frames) and `idet`, and turns each output frame into a `TelecineCadenceAnalyzer.Sample`.
final class TelecineCadenceSampler {

    /// The probe's graph. `combmatch=none` matches on field differences alone, about a third of the
    /// cost of `full`, and `idet` reads the same verdict on Friends either way.
    static let chain = "fieldmatch=order=auto:combmatch=none,idet"

    private let timeBase: AVRational
    private let frameRate: DeinterlaceConfig.SourceFrameRate
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var srcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var sinkCtx: UnsafeMutablePointer<AVFilterContext>?
    private var out: UnsafeMutablePointer<AVFrame>?
    private var previousLuma: [UInt8] = []
    private var failed = false

    init(timeBase: AVRational, frameRate: DeinterlaceConfig.SourceFrameRate) {
        self.timeBase = timeBase
        self.frameRate = frameRate
    }

    deinit {
        if graph != nil { avfilter_graph_free(&graph) }
        if out != nil { av_frame_free(&out) }
    }

    /// Push one decoded frame (left intact). Returns the samples the graph released, nil when the graph
    /// could not be built or failed.
    func push(_ frame: UnsafeMutablePointer<AVFrame>) -> [TelecineCadenceAnalyzer.Sample]? {
        guard !failed else { return nil }
        if graph == nil, !build(for: frame) { failed = true; return nil }
        guard let src = srcCtx,
              av_buffersrc_add_frame_flags(src, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)) >= 0 else {
            failed = true
            return nil
        }
        return pull()
    }

    /// End of the sample: the frames `fieldmatch` still holds as look-ahead.
    func finish() -> [TelecineCadenceAnalyzer.Sample] {
        guard !failed, let src = srcCtx else { return [] }
        guard av_buffersrc_add_frame_flags(src, nil, 0) >= 0 else { return [] }
        return pull() ?? []
    }

    private func pull() -> [TelecineCadenceAnalyzer.Sample]? {
        guard let sink = sinkCtx else { return nil }
        if out == nil { out = av_frame_alloc() }
        guard let out else { return nil }
        var samples: [TelecineCadenceAnalyzer.Sample] = []
        while true {
            let ret = av_buffersink_get_frame(sink, out)
            if ret == FFmpegErr.eagain || ret == FFmpegErr.eof { break }
            guard ret >= 0 else { failed = true; return samples.isEmpty ? nil : samples }
            samples.append(TelecineCadenceAnalyzer.Sample(fieldClass: Self.fieldClass(of: out),
                                                          difference: difference(of: out)))
            av_frame_unref(out)
        }
        return samples
    }

    static func fieldClass(of frame: UnsafeMutablePointer<AVFrame>) -> TelecineCadenceAnalyzer.FieldClass {
        guard let entry = av_dict_get(frame.pointee.metadata, "lavfi.idet.multiple.current_frame", nil, 0),
              let value = entry.pointee.value else {
            return .undetermined
        }
        switch String(cString: value) {
        case "progressive": return .progressive
        case "tff", "bff": return .interlaced
        default: return .undetermined
        }
    }

    /// Block side for the difference, and the rows and columns sampled inside a block: both fields
    /// (rows 0, 1, 4, 5, ...), every second column, so 64 samples a block.
    static let blockSide = 16
    private static let blockRows = [0, 1, 4, 5, 8, 9, 12, 13]
    private static let samplesPerBlock = 64

    /// The worst 16x16 block's mean absolute luma difference to the previous output frame (an 8-pixel
    /// margin off the edges), the way `decimate` judges a duplicate by its worst block. 8-bit luma only.
    private func difference(of frame: UnsafeMutablePointer<AVFrame>) -> Double? {
        guard let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format)),
              desc.pointee.comp.0.depth == 8, let base = frame.pointee.data.0 else {
            previousLuma = []
            return nil
        }
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        let rowBytes = Int(frame.pointee.linesize.0)
        let margin = 8
        let side = Self.blockSide
        let blocksX = (width - 2 * margin) / side, blocksY = (height - 2 * margin) / side
        guard blocksX > 0, blocksY > 0 else {
            previousLuma = []
            return nil
        }
        var current = [UInt8](repeating: 0, count: blocksX * blocksY * Self.samplesPerBlock)
        var index = 0
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let x0 = margin + bx * side, y0 = margin + by * side
                for dy in Self.blockRows {
                    let row = base + (y0 + dy) * rowBytes + x0
                    var dx = 0
                    while dx < side {
                        current[index] = row[dx]
                        index += 1
                        dx += 2
                    }
                }
            }
        }
        defer { previousLuma = current }
        guard previousLuma.count == current.count else { return nil }
        var worst = 0
        var offset = 0
        while offset < current.count {
            var sum = 0
            for k in offset..<(offset + Self.samplesPerBlock) {
                sum += abs(Int(current[k]) - Int(previousLuma[k]))
            }
            worst = max(worst, sum)
            offset += Self.samplesPerBlock
        }
        return Double(worst) / Double(Self.samplesPerBlock)
    }

    private func build(for frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        guard let g = avfilter_graph_alloc(),
              let bufferFilter = avfilter_get_by_name("buffer"),
              let sinkFilter = avfilter_get_by_name("buffersink") else { return false }
        var built = false
        var gOpt: UnsafeMutablePointer<AVFilterGraph>? = g
        defer { if !built { avfilter_graph_free(&gOpt) } }
        let sar = frame.pointee.sample_aspect_ratio
        var args = "video_size=\(frame.pointee.width)x\(frame.pointee.height)"
            + ":pix_fmt=\(frame.pointee.format)"
            + ":time_base=\(max(1, timeBase.num))/\(max(1, timeBase.den))"
            + ":pixel_aspect=\(sar.num > 0 ? sar.num : 1)/\(sar.den > 0 ? sar.den : 1)"
        if frameRate.isKnown { args += ":frame_rate=\(frameRate.num)/\(frameRate.den)" }
        var src: UnsafeMutablePointer<AVFilterContext>?
        var sink: UnsafeMutablePointer<AVFilterContext>?
        guard avfilter_graph_create_filter(&src, bufferFilter, "in", args, nil, g) >= 0,
              avfilter_graph_create_filter(&sink, sinkFilter, "out", nil, nil, g) >= 0,
              let srcC = src, let sinkC = sink else { return false }
        var inputs = avfilter_inout_alloc()
        var outputs = avfilter_inout_alloc()
        defer { avfilter_inout_free(&inputs); avfilter_inout_free(&outputs) }
        guard let inp = inputs, let outp = outputs else { return false }
        outp.pointee.name = strdup("in")
        outp.pointee.filter_ctx = srcC
        outp.pointee.pad_idx = 0
        outp.pointee.next = nil
        inp.pointee.name = strdup("out")
        inp.pointee.filter_ctx = sinkC
        inp.pointee.pad_idx = 0
        inp.pointee.next = nil
        guard avfilter_graph_parse_ptr(g, Self.chain, &inputs, &outputs, nil) >= 0,
              avfilter_graph_config(g, nil) >= 0 else { return false }
        built = true
        graph = g
        srcCtx = srcC
        sinkCtx = sinkC
        return true
    }
}
