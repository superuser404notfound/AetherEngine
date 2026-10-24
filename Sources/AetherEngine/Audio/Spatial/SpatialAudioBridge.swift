// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Foundation
import CoreMedia
import AetherLibavcodec
import AetherLibavutil

/// TrueHD Atmos or DTS:X in, APAC out: decodes the object presentation, renders its beds and objects
/// into a `SpatialSpeakerLayout` bed and encodes that as Apple Positional Audio, which tvOS delivers
/// to an Atmos receiver as Dolby MAT with the heights intact.
///
/// The FLAC bridge keeps TrueHD and DTS-HD lossless but can only carry the 7.1 presentation, so every
/// height and every object position is gone before the audio leaves the engine. This bridge trades the
/// lossless bed for the Atmos mix: APAC is lossy, at a few Mbit/s, several times the rate streaming
/// services deliver Atmos at.
///
/// libavformat can neither encode nor mux APAC, so the muxer is handed an ALAC stand-in stream
/// (`encoderCodecpar`) whose sample entry the init segment rewrite replaces with the real one
/// (`soundSampleEntryOverride`). Packets pass through movenc untouched.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class SpatialAudioBridge: AudioTranscodingBridge, @unchecked Sendable {

    static let sampleRate = ObjectAudioRendering.sampleRate

    /// Default encode rate per bed channel. 3.84 Mbit/s for 7.1.4, 5.12 for 9.1.6.
    static let bitRatePerChannel = 320_000

    enum BridgeError: Error, CustomStringConvertible {
        case codecparAllocFailed
        case unsupportedSampleRate(Int)

        var description: String {
            switch self {
            case .codecparAllocFailed: return "SpatialAudioBridge: avcodec_parameters_alloc failed"
            case .unsupportedSampleRate(let r): return "SpatialAudioBridge: object audio at \(r) Hz (48 kHz only)"
            }
        }
    }

    let layout: SpatialSpeakerLayout
    private(set) var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>?
    let encoderTimeBase = AVRational(num: 1, den: Int32(SpatialAudioBridge.sampleRate))
    let soundSampleEntryOverride: Data?
    /// HLS `CODECS` value for the track.
    let hlsCodecs: String
    var servedChannelCount: Int? { layout.channelCount }
    let peakOutputBitRate: Int64
    /// The encoder's packets as a sample-buffer format description, and the frames the encoder
    /// primes with, for a host that feeds an audio renderer instead of a muxer (see `wrap`).
    let packetFormatDescription: CMAudioFormatDescription
    let encoderLeadingFrames: Int

    private let srcTimeBase: AVRational
    private let decoder: ObjectAudioDecoding
    private let pipeline: APACEncodePipeline
    private var renderer: ObjectAudioRenderer?
    private var rendererGeneration = -1
    /// What the encoder is fed, per bed channel, for the session log (see `BedLevelMeter`).
    private var levelMeter: BedLevelMeter
    /// Keeps the bed under full scale, since the encoder carries anything over it on (see `PeakLimiter`).
    private var limiter: PeakLimiter

    /// Rendered bed awaiting the encoder. TrueHD decodes one 40-frame access unit per block, 1200
    /// a second; feeding the converter that often costs more in call overhead than the encode, so
    /// blocks are rendered straight into this buffer and it is handed to the encoder's queue
    /// `encodeChunkFrames` at a time (see `APACEncodePipeline`).
    private var output: APACEncodePipeline.PlaneBuffer
    private var pendingFrames = 0
    private static let encodeChunkFrames = 2048

    /// Timeline, in 48 kHz frames on the output time base.
    /// `originFrame`: the source PTS of the first packet pushed since the last reset.
    /// `encoderStartFrame`: where the first frame handed to the encoder since the reset sits.
    /// `encoderFramesIn`: frames handed to the encoder since the reset, so the next chunk sits at
    /// `encoderStartFrame + encoderFramesIn`. The pipeline stamps the packets; see `wrap`.
    private var originFrame: Int64?
    private var encoderStartFrame: Int64?
    private var encoderFramesIn: Int64 = 0
    private var nextExpectedInputOffset: Int64?
    private var drainedAtEOF = false
    /// The decoder reset itself after an internal failure: its offsets count from zero again, so the
    /// next block re-anchors on the next packet's timestamp instead of being appended to the encoder.
    private var decoderSelfResetsSeen = 0
    private var reanchorPending = false
    /// Feeds in a row that threw, for a rate-limited log and the AE#641 report of a bridge that
    /// keeps failing (a decoder that panics on every unit, a rate the renderer refuses).
    private var consecutiveFeedFailures = 0

    private let opLock = NSLock()
    private var stats = AudioBridge.FeedStats()
    private(set) var outputBytesLifetime: Int64 = 0

    /// `LiveTelemetry.objectAudio`: written on the pump thread for every rendered block, read at 1 Hz
    /// by the telemetry sampler. Behind a lock of its own, so that read never waits for a decode or
    /// an encode holding `opLock`.
    private let activityLock = NSLock()
    private var latestActivity: ObjectAudioActivity?
    var objectAudioActivity: ObjectAudioActivity? { activityLock.withLock { latestActivity } }

    /// AE#641: called once, on the pump thread, when the object decoder has been fed
    /// `silentFeedPacketThreshold` packets in a row without returning a block. The APAC
    /// sample entry is written up front, like FLAC's, so nothing downstream fails on its own and the
    /// session would otherwise play the picture over silence. Set before the producer starts feeding.
    var onDecoderProducedNothing: (@Sendable (AudioBridge.FeedStats) -> Void)?
    private var decodedNothingReported = false

    private static let avNoPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1

    /// Packets the object decoder may take without a block before it counts as producing nothing.
    /// Not the channel bridge's default 64 (it takes this bound for TrueHD too, AE#786): a TrueHD
    /// packet is one 40-frame access unit, and after a start or resume mid-stream the decoder waits
    /// for the next major sync before its first block. Measured
    /// on Dolby's Unfold demo, that wait was up to 102 access units; at 64 every resume past the
    /// opening seconds was reported as a dead decoder and the session went to `.error` while it
    /// played, ignoring every seek after it. 1200 is a second of TrueHD, still a fraction of a second
    /// of the producer's time. A DTS-HD packet is a 512-frame frame, so for DTS:X it is 12.8 s; the
    /// track was confirmed as DTS:X before the bridge was built, and its decoder outputs from the
    /// third packet after every reset.
    static let silentFeedPacketThreshold = AudioBridge.trueHDSilentFeedPacketThreshold

    init(
        srcTimeBase: AVRational,
        layout: SpatialSpeakerLayout,
        decoder: ObjectAudioDecoding,
        bitRate: Int? = nil
    ) throws {
        self.srcTimeBase = srcTimeBase
        self.layout = layout
        self.decoder = decoder
        levelMeter = BedLevelMeter(layout: layout, sampleRate: Self.sampleRate)
        limiter = PeakLimiter(sampleRate: Self.sampleRate)
        let rate = bitRate ?? layout.channelCount * Self.bitRatePerChannel
        peakOutputBitRate = Int64(rate)
        let encoder = try APACEncoder(layout: layout, sampleRate: Double(Self.sampleRate), bitRate: rate)
        let pipeline = APACEncodePipeline(
            encoder: encoder, channels: layout.channelCount, bufferFrames: Self.encodeChunkFrames * 4)
        self.pipeline = pipeline
        packetFormatDescription = encoder.formatDescription
        encoderLeadingFrames = encoder.leadingFrames
        output = pipeline.takeInitialBuffer()
        soundSampleEntryOverride = APACSampleEntry.sampleEntry(
            magicCookie: encoder.magicCookie, sampleRate: Self.sampleRate)
        hlsCodecs = APACSampleEntry.codecsString(channelCount: layout.channelCount)
        guard let cp = Self.makeStandInCodecpar() else { throw BridgeError.codecparAllocFailed }
        encoderCodecpar = cp
        EngineLog.emit(
            "[SpatialAudioBridge] init: layout=\(layout.rawValue) bitRate=\(rate / 1000) kbps "
            + "codecs=\(hlsCodecs) priming=\(encoder.leadingFrames) frames",
            category: .session
        )
    }

    deinit { cleanup() }

    /// ALAC, 2 channels, 48 kHz, 1024-frame packets: a stream movenc writes from parameters alone and
    /// never inspects the packets of. Its sample entry is replaced wholesale, so only the timing
    /// fields matter to anything downstream.
    private static func makeStandInCodecpar() -> UnsafeMutablePointer<AVCodecParameters>? {
        guard let cp = avcodec_parameters_alloc() else { return nil }
        cp.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        cp.pointee.codec_id = AV_CODEC_ID_ALAC
        cp.pointee.sample_rate = Int32(sampleRate)
        cp.pointee.frame_size = Int32(APACEncoder.framesPerPacket)
        cp.pointee.bits_per_raw_sample = 16
        cp.pointee.bits_per_coded_sample = 16
        av_channel_layout_default(&cp.pointee.ch_layout, 2)
        // A well-formed 36-byte ALAC `alac` atom (ALACSpecificConfig), so movenc writes a sane box.
        var cookie: [UInt8] = [0, 0, 0, 36] + Array("alac".utf8) + [0, 0, 0, 0]
        cookie += [0, 0, 4, 0]                  // frameLength 1024
        cookie += [0, 16, 40, 10, 14, 2]        // compatibleVersion, bitDepth, pb, mb, kb, numChannels
        cookie += [0, 255]                      // maxRun
        cookie += [0, 0, 0, 0, 0, 0, 0, 0]      // maxFrameBytes, avgBitRate
        cookie += [0, 0, 0xBB, 0x80]            // sampleRate 48000
        if let extradata = av_mallocz(cookie.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))?
            .assumingMemoryBound(to: UInt8.self) {
            extradata.update(from: cookie, count: cookie.count)
            cp.pointee.extradata = extradata
            cp.pointee.extradata_size = Int32(cookie.count)
        }
        return cp
    }

    // MARK: - AudioTranscodingBridge

    var feedStats: AudioBridge.FeedStats { stats }
    var fifoSampleCount: Int { 0 }
    var liveBytes: AudioBridge.LiveBytes {
        AudioBridge.LiveBytes(fifoSamples: 0, fifoBytes: 0, swrDelaySamples: 0, swrDelayBytes: 0)
    }

    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        stats.packetsFed += 1
        stats.packetsFedSinceLastEnqueue += 1
        // Every exit: a decoder that rejects each packet has decoded nothing too.
        defer { noteDecodedNothingIfNeeded() }

        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return [] }
        do {
            try decoder.push(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
        } catch {
            stats.packetsRejected += 1
            noteDecoderSelfReset()
            noteFeedFailure(error)
            var results: [UnsafeMutablePointer<AVPacket>] = []
            // This feed has already counted as failed.
            collectEncoded(into: &results, noteFailure: false)
            return results
        }
        // The anchor is the first packet the decoder actually took, so its input offsets count from
        // this packet. dts covers a packet whose pts the demuxer left unset.
        if originFrame == nil {
            let ts = packet.pointee.pts != Self.avNoPTS ? packet.pointee.pts : packet.pointee.dts
            if ts != Self.avNoPTS { originFrame = av_rescale_q(ts, srcTimeBase, encoderTimeBase) }
        }

        // Packets already stamped stay in the result when a later block of the same packet fails:
        // their timestamps are right, and dropping them would leave a hole the source never had.
        var results: [UnsafeMutablePointer<AVPacket>] = []
        do {
            while let block = try decoder.nextBlock() {
                stats.framesDecoded += 1
                try renderAndEncode(block, into: &results)
            }
            consecutiveFeedFailures = 0
        } catch {
            stats.decodeErrors += 1
            noteDecoderSelfReset()
            noteFeedFailure(error)
        }
        collectEncoded(into: &results)
        return results
    }

    /// Caller holds `opLock`. After the decoder reset itself, the bytes of the failing packet are gone
    /// and its offsets restart at zero: anchor again on the next packet it takes.
    private func noteDecoderSelfReset() {
        guard decoder.selfResetCount != decoderSelfResetsSeen else { return }
        decoderSelfResetsSeen = decoder.selfResetCount
        originFrame = nil
        nextExpectedInputOffset = nil
        reanchorPending = encoderStartFrame != nil
    }

    /// Caller holds `opLock`. The first failure and every `silentFeedPacketThreshold`th after it are
    /// logged; a run that long is reported once as a bridge that produces nothing.
    private func noteFeedFailure(_ error: Error) {
        consecutiveFeedFailures += 1
        if consecutiveFeedFailures == 1 || consecutiveFeedFailures % Self.silentFeedPacketThreshold == 0 {
            EngineLog.emit(
                "[SpatialAudioBridge] feed failed (\(consecutiveFeedFailures) in a row): \(error)",
                category: .session)
        }
        guard !decodedNothingReported,
              consecutiveFeedFailures >= Self.silentFeedPacketThreshold else { return }
        // One latch with the decoded-nothing report: a decoder that refuses every packet is both.
        decodedNothingReported = true
        EngineLog.emit(
            "[SpatialAudioBridge] ERROR: AE#641 every feed has failed for \(consecutiveFeedFailures) packets: "
            + "\(stats.summary)", category: .session)
        onDecoderProducedNothing?(stats)
    }

    /// Caller holds `opLock`.
    private func noteDecodedNothingIfNeeded() {
        guard !decodedNothingReported, stats.decodedNothing,
              stats.packetsFedSinceLastEnqueue >= Self.silentFeedPacketThreshold else { return }
        decodedNothingReported = true
        EngineLog.emit(
            "[SpatialAudioBridge] ERROR: AE#641 the object decoder has produced nothing: "
            + "\(stats.summary)", category: .session)
        onDecoderProducedNothing?(stats)
    }

    func settle() -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        var results: [UnsafeMutablePointer<AVPacket>] = []
        // Audio the decoder holds for metadata sits before the cut; released here, the cut sees what
        // it saw before the hold existed, rather than up to 100 ms of it landing in the next segment.
        renderHeldBlocks(into: &results)
        let settled = pipeline.settle()
        wrap(settled.packets, into: &results)
        noteEncodeErrors(settled.errors)
        return results
    }

    func flush() -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard !drainedAtEOF else { return [] }
        drainedAtEOF = true
        var results: [UnsafeMutablePointer<AVPacket>] = []
        // Audio the decoder held back for metadata that never came plays as it is.
        renderHeldBlocks(into: &results)
        encodePending()
        logLevels(levelMeter.restart())
        let finished = pipeline.finish()
        wrap(finished.packets, into: &results)
        noteEncodeErrors(finished.errors)
        if !results.isEmpty {
            EngineLog.emit("[SpatialAudioBridge] EOF flush emitted \(results.count) tail packet(s)", category: .session)
        }
        return results
    }

    func startSegment() {
        opLock.lock()
        defer { opLock.unlock() }
        decoder.reset()
        renderer?.reset()
        pipeline.reset()
        limiter.reset()
        logLevels(levelMeter.restart())
        pendingFrames = 0
        originFrame = nil
        encoderStartFrame = nil
        encoderFramesIn = 0
        nextExpectedInputOffset = nil
        drainedAtEOF = false
        decoderSelfResetsSeen = decoder.selfResetCount
        reanchorPending = false
        consecutiveFeedFailures = 0
    }

    func noteTimelineJump(deltaSeconds: Double) {
        opLock.lock()
        defer { opLock.unlock() }
        guard deltaSeconds > 0, let start = encoderStartFrame else { return }
        let frames = Int64((deltaSeconds * Double(Self.sampleRate)).rounded())
        encoderStartFrame = start + frames
        pipeline.shift(by: frames)
    }

    func close() {
        opLock.lock()
        defer { opLock.unlock() }
        // A viewer who hears no heights stops playback: the window they stopped in is the one to log.
        logLevels(levelMeter.restart())
        pipeline.close()
        cleanup()
    }

    private func cleanup() {
        if encoderCodecpar != nil { avcodec_parameters_free(&encoderCodecpar) }
    }

    // MARK: - Pipeline

    /// Caller holds `opLock`.
    private func renderHeldBlocks(into results: inout [UnsafeMutablePointer<AVPacket>]) {
        decoder.releaseHeldBlocks()
        do {
            while let block = try decoder.nextBlock() {
                stats.framesDecoded += 1
                try renderAndEncode(block, into: &results)
            }
        } catch {
            EngineLog.emit("[SpatialAudioBridge] drain of held blocks failed: \(error)", category: .session)
        }
    }

    private func renderAndEncode(_ block: ObjectAudioDecodedBlock, into results: inout [UnsafeMutablePointer<AVPacket>]) throws {
        guard block.sampleRate == Self.sampleRate else { throw BridgeError.unsupportedSampleRate(block.sampleRate) }
        guard block.frameCount > 0 else { return }

        let rebuilt = renderer == nil || block.configurationGeneration != rendererGeneration
        if rebuilt {
            // Whether the presentation has an LFE element at all is the first question a missing-LFE
            // report asks.
            EngineLog.emit(
                "[SpatialAudioBridge] object configuration\(renderer == nil ? "" : " changed, renderer rebuilt"): "
                    + BedLevelMeter.configurationSummary(block.roles),
                category: .session
            )
            renderer = ObjectAudioRenderer(layout: layout, roles: block.roles)
            rendererGeneration = block.configurationGeneration
        } else if block.isDiscontinuity {
            renderer?.markDiscontinuity()
        }
        levelMeter.observe(roles: block.roles, updates: block.updates, configurationChanged: rebuilt)
        levelMeter.measureInput(roles: block.roles, planes: block.planes, frameCount: block.frameCount)
        let activity = levelMeter.activity
        activityLock.withLock { latestActivity = activity }
        // Anchor the encoder on the first block after a reset, and keep the encoder's input
        // contiguous with the source afterwards: a gap the decoder skipped (corrupt access units) is
        // filled with silence so everything after it stays on its timestamp.
        if encoderStartFrame == nil {
            encoderStartFrame = (originFrame ?? 0) + block.inputFrameOffset
        } else if reanchorPending, let start = encoderStartFrame {
            // After the decoder's own reset: put this block where the source says it plays.
            reanchorPending = false
            let target = (originFrame ?? start + encoderFramesIn + Int64(pendingFrames)) + block.inputFrameOffset
            place(at: target)
        } else if let expected = nextExpectedInputOffset, block.inputFrameOffset > expected,
                  let start = encoderStartFrame {
            let end = start + encoderFramesIn + Int64(pendingFrames)
            place(at: end + (block.inputFrameOffset - expected))
        }
        nextExpectedInputOffset = block.inputFrameOffset + Int64(block.frameCount)

        output.ensureCapacity(pendingFrames + block.frameCount, keeping: pendingFrames)
        renderer!.render(
            inputs: block.planes, frameCount: block.frameCount, updates: block.updates,
            outputs: output.planes.map { $0 + pendingFrames })
        pendingFrames += block.frameCount
        stats.samplesEnqueued += Int64(block.frameCount)
        stats.packetsFedSinceLastEnqueue = 0
        if pendingFrames >= Self.encodeChunkFrames { encodePending() }
    }

    /// Continue the encoder's input at `target` (a source position in 48 kHz frames): a short gap
    /// ahead is filled with silence, anything longer or behind restarts the encoder there, so every
    /// later packet keeps its source position.
    private func place(at target: Int64) {
        guard let start = encoderStartFrame else { return }
        let end = start + encoderFramesIn + Int64(pendingFrames)
        let gap = target - end
        if gap == 0 { return }
        if gap > 0, gap <= Int64(Self.maxSilenceFillFrames) {
            encodeSilence(frames: Int(gap))
            return
        }
        encodePending()
        pipeline.restart()
        limiter.reset()
        encoderStartFrame = target
        encoderFramesIn = 0
        EngineLog.emit(
            "[SpatialAudioBridge] encoder re-anchored \(String(format: "%+.3f", Double(gap) / Double(Self.sampleRate))) s "
            + "off its running position", category: .session)
    }

    /// The longest gap filled with silence rather than by restarting the encoder.
    private static let maxSilenceFillFrames = sampleRate * 5

    /// In chunks, like rendered audio: a 5 s fill handed over in one piece would hold the encoder
    /// for its whole length and grow every pooled buffer to it.
    private func encodeSilence(frames: Int) {
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, max(Self.encodeChunkFrames - pendingFrames, 0))
            if n == 0 { encodePending(); continue }
            output.ensureCapacity(pendingFrames + n, keeping: pendingFrames)
            for plane in output.planes { (plane + pendingFrames).update(repeating: 0, count: n) }
            pendingFrames += n
            remaining -= n
            if pendingFrames >= Self.encodeChunkFrames { encodePending() }
        }
    }

    /// Hand the rendered frames to the encoder's queue. Its packets come back through
    /// `collectEncoded` on a later call.
    private func encodePending() {
        guard pendingFrames > 0 else { return }
        let frames = pendingFrames
        pendingFrames = 0
        guard let start = encoderStartFrame else { return }
        limiter.process(output.planes, frameCount: frames)
        let position = start + encoderFramesIn
        // Where this chunk plays, for the level line: the anchor is a source PTS in 48 kHz frames.
        logLevels(levelMeter.add(output.planes.map { UnsafePointer($0) }, frameCount: frames,
                                 startSeconds: Double(position) / Double(Self.sampleRate)))
        output = pipeline.submit(output, frames: frames, position: position)
        encoderFramesIn += Int64(frames)
    }

    /// Caller holds `opLock`. Everything the encoder has finished since the last call.
    private func collectEncoded(into results: inout [UnsafeMutablePointer<AVPacket>], noteFailure: Bool = true) {
        let encoded = pipeline.collect()
        wrap(encoded.packets, into: &results)
        noteEncodeErrors(encoded.errors, noteFailure: noteFailure)
    }

    /// Caller holds `opLock`. A failed chunk is a gap the pipeline already stepped over; it counts
    /// as a failed feed for the log.
    private func noteEncodeErrors(_ errors: [Error], noteFailure: Bool = true) {
        guard let first = errors.first else { return }
        stats.encodeErrors += errors.count
        if noteFailure { noteFeedFailure(first) }
    }

    /// The level line, with the limiter's work over the same window when it had any.
    private func logLevels(_ line: String?) {
        guard let line else { return }
        let limited = limiter.takeLimitedFrames()
        let limiterNote = limited.frames > 0
            ? String(format: "; limiter reduced %d frames, deepest %.1f dB", limited.frames, limited.deepestDB)
            : ""
        EngineLog.emit("[SpatialAudioBridge] \(line)\(limiterNote)", category: .session)
    }

    /// Wrap stamped encoder packets for the muxer. The pipeline stamps packet k of an encoder run
    /// at the run's first position plus k·1024, the encoder's priming packets included, because
    /// AVFoundation presents an APAC packet's audio `leadingFrames` (2048) before its timestamp: it
    /// counts the priming as part of the stream, the way AVAssetWriter writes it. So the priming
    /// packets take the anchor's timestamp, their output falls before it and is never heard, and the
    /// first content frame plays on the source position. Dropping them and stamping the first
    /// content packet on the anchor played every session 2048 frames (42.7 ms) ahead of the video,
    /// at load and after every seek (AVPlayer over HLS on macOS 27, with 5.1 APAC since macOS rejects
    /// 7.1.4, against an ALAC reference; AVAssetReader shows the same 2048 frames for 7.1.4).
    private func wrap(_ packets: [APACEncodePipeline.StampedPacket], into results: inout [UnsafeMutablePointer<AVPacket>]) {
        let frames = Int64(APACEncoder.framesPerPacket)
        for packet in packets {
            guard let avpkt = trackedPacketAlloc() else { continue }
            guard av_new_packet(avpkt, Int32(packet.data.count)) >= 0 else {
                var p: UnsafeMutablePointer<AVPacket>? = avpkt
                trackedPacketFree(&p)
                continue
            }
            packet.data.withUnsafeBytes { raw in
                avpkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: packet.data.count)
            }
            avpkt.pointee.pts = packet.pts
            avpkt.pointee.dts = packet.pts
            avpkt.pointee.duration = frames
            if packet.isSync { avpkt.pointee.flags |= AV_PKT_FLAG_KEY }
            outputBytesLifetime += Int64(packet.data.count)
            stats.packetsEmitted += 1
            results.append(avpkt)
        }
    }
}
#endif
