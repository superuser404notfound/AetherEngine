import Foundation
import CoreMedia
import CoreAudio
import AudioToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import AetherLibswresample

/// FFmpeg software audio decoder: compressed AVPackets -> multichannel interleaved Float32 PCM in CMSampleBuffers
/// for AVSampleBufferAudioRenderer. Uses libswresample to interleaved Float32 at source rate/channels (up to 7.1)
/// with proper AudioChannelLayout. Non-Atmos tracks only; EAC3+JOC Atmos passes through AVPlayer.
final class AudioDecoder: @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?

    /// Serializes decode (demux thread) against flush/close (main actor). Without it a MainActor
    /// avcodec_flush_buffers could race an in-flight avcodec_send_packet on the same context (UB).
    /// Mirrors SoftwareVideoDecoder's lock discipline.
    private let stateLock = NSLock()
    private var swrContext: OpaquePointer?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// Source stream time base for PTS conversion.
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)

    /// TrueHD/MLP/lossless emit ~40-sample frames (0.83ms @48kHz); feeding 1200+ tiny CMSampleBuffers/sec makes
    /// AVSampleBufferAudioRenderer accept them then silently drop multichannel output. Coalesce to >= this many
    /// samples before building a buffer (~47 buffers/sec at ~21ms each, which the renderer handles).
    private static let minSamplesPerBuffer = 1024

    private var pendingBytes = Data()
    private var pendingStartPTS: CMTime = .invalid
    private var pendingSampleCount: Int = 0

    /// Gapless presentation clock (issue #89): stamps each buffer from a running sample count so
    /// consecutive buffers abut to the sample, instead of from each buffer's container-quantized PTS
    /// (which clicks at every frame for non-integer-ms frame durations like 1536-sample AC-3 @ 44.1 kHz).
    private var clock = AudioClockAnchor()

    #if DEBUG
    private var _loggedZeroConvert = false
    #endif

    /// Input parameters the current `swrContext` was built for (#452). `decode()`/`drain()` compare
    /// each frame against these and rebuild on a mid-stream change: a live splice can swap the
    /// stream's audio configuration (5.1 <-> stereo at a program boundary), and a context built for
    /// more input planes than the frame carries reads a NULL plane inside swr_convert.
    private var configuredInput = ResamplerInputParameters()

    private(set) var sampleRate: Int32 = 0
    /// The channels the decoder OUTPUTS: the source's, or fewer under an `AudioShaping` cap.
    private(set) var channels: Int32 = 0

    /// AE#923. Set before `open`; a change mid-session arrives as a new decoder or a re-anchor.
    var shaping = AudioShaping()
    private var shapingGraph: AudioShapingGraph?

    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecpar = stream.pointee.codecpar else {
            throw AudioDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        sampleRate = codecpar.pointee.sample_rate
        channels = codecpar.pointee.ch_layout.nb_channels
        if channels <= 0 || channels > 8 { channels = 2 }

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw AudioDecoderError.unsupportedCodec
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw AudioDecoderError.contextAllocationFailed
        }
        codecContext = ctx

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw AudioDecoderError.parameterCopyFailed
        }

        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            throw AudioDecoderError.openFailed
        }

        // Resampler built lazily from the first frame, not here: TrueHD (and codecs advertising
        // AV_CHANNEL_ORDER_UNSPEC or sample_fmt=NONE in codecpar pre-frame) would fail swr_alloc_set_opts2 here,
        // bubbling up as open-failed -> audioAvailable=false -> no sound. The first frame carries resolved layout/rate/format.

        #if DEBUG
        EngineLog.emit("[AudioDecoder] Opened: \(sampleRate)Hz, \(channels)ch, codec=\(String(cString: codec.pointee.name))", category: .swPlayback)
        #endif
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        var results: [CMSampleBuffer] = []

        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else { return [] }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else { return [] }

        while avcodec_receive_frame(ctx, f) >= 0 {
            // Lazy resampler init off a real frame with resolved layout/format. On failure drops one frame at
            // most and recovers immediately.
            if swrContext == nil {
                if !initResamplerFromFrame(f) { continue }
            } else if configuredInput.differ(from: f) {
                if let sampleBuffer = rebuildResampler(for: f) { results.append(sampleBuffer) }
                if swrContext == nil { continue }
            }
            appendFrameToPending(f)
            if pendingSampleCount >= Self.minSamplesPerBuffer {
                if let sampleBuffer = emitPending() {
                    results.append(sampleBuffer)
                }
            }
        }

        return results
    }

    /// Tear down and rebuild the resampler for a frame whose input parameters changed mid-stream
    /// (#452). Emits the accumulator first (its bytes are in the OLD output format and must be
    /// neither dropped nor mixed with the new format's) and returns that buffer, if any. The gapless
    /// clock's sample count is denominated in the old rate, so it resets and the next buffer
    /// re-anchors from its own container PTS. On a failed rebuild `swrContext` stays nil and the
    /// caller skips the frame; the next frame retries, mirroring the lazy-init failure mode.
    private func rebuildResampler(for frame: UnsafeMutablePointer<AVFrame>) -> CMSampleBuffer? {
        let flushed = emitPending()
        EngineLog.emit(
            "[AudioDecoder] input format changed mid-stream ("
            + "\(configuredInput.rate)Hz/\(configuredInput.layout.nb_channels)ch/fmt=\(configuredInput.format.rawValue)"
            + " -> \(frame.pointee.sample_rate)Hz/\(frame.pointee.ch_layout.nb_channels)ch/fmt=\(frame.pointee.format)"
            + "); rebuilding resampler",
            category: .swPlayback)
        swr_free(&swrContext)
        clock.reset()
        _ = initResamplerFromFrame(frame)
        return flushed
    }

    private func initResamplerFromFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        // Refresh rate/channels from the frame (codecpar was a hint, the frame is truth). Runs on the
        // first frame and again after a mid-stream format change tore the context down (#452).
        if frame.pointee.sample_rate > 0 { sampleRate = frame.pointee.sample_rate }
        let frameChannels = frame.pointee.ch_layout.nb_channels
        if frameChannels > 0 && frameChannels <= 8 { channels = frameChannels }
        if shaping.isActive { channels = shaping.outputChannels(forSource: channels) }

        var outLayout = AVChannelLayout()
        // #401: this is the order the stamped layout has to name, so both come from one place.
        makeResamplerOutputLayout(channels, into: &outLayout)

        // Input layout: frame's if valid, else a synthesised default. Key for TrueHD 7.1 (the frame has it right
        // after decoding even when codecpar didn't).
        var inLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, channels)
        }
        // copy() allocates a channel map for custom-order layouts; uninit the stack structs or that map leaks per init.
        defer {
            av_channel_layout_uninit(&inLayout)
            av_channel_layout_uninit(&outLayout)
        }

        let inFmt = AVSampleFormat(rawValue: frame.pointee.format)
        let inRate = frame.pointee.sample_rate > 0 ? frame.pointee.sample_rate : sampleRate

        let ret = swr_alloc_set_opts2(
            &swrContext,
            &outLayout,
            AV_SAMPLE_FMT_FLT,
            sampleRate,
            &inLayout,
            inFmt,
            inRate,
            0,
            nil
        )
        guard ret >= 0, let swr = swrContext else { return false }
        if shaping.isActive {
            AudioShapingMatrix.apply(to: swr, input: &inLayout, output: &outLayout,
                                     dialogueGain: shaping.dialogueGain)
            shapingGraph = AudioShapingGraph(shaping: shaping, sampleRate: sampleRate, layout: &outLayout,
                                             sourceHasCentre: AudioShapingMatrix.hasCentre(&inLayout),
                                             outputFormat: AV_SAMPLE_FMT_FLT)
            EngineLog.emit("[AudioDecoder] AE#923 shaping \(shaping.summary): "
                           + "\(frameChannels)ch -> \(channels)ch"
                           + (shapingGraph == nil ? ", filter graph unavailable, dynamics off" : ""),
                           category: .swPlayback)
        } else {
            shapingGraph = nil
        }
        guard swr_init(swr) >= 0 else {
            swr_free(&swrContext)
            return false
        }

        do {
            try createFormatDescription()
        } catch {
            swr_free(&swrContext)
            return false
        }

        // What this context was built for; every later frame is compared against it (#452).
        configuredInput.adopt(layout: &inLayout, format: inFmt, rate: inRate)

        #if DEBUG
        EngineLog.emit("[AudioDecoder] Resampler ready: \(sampleRate)Hz, \(channels)ch, inFmt=\(inFmt.rawValue)", category: .swPlayback)
        #endif
        return true
    }

    /// Flush the decoder (call at EOF or seek).
    func flush() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
        // Drop the coalesced samples; after a seek they'd be at the wrong PTS anyway.
        resetPending()
        // Re-anchor the gapless clock to the post-seek PTS on the next emitted buffer.
        clock.reset()
        shapingGraph?.reset()
        #if DEBUG
        _loggedZeroConvert = false
        #endif
    }

    /// Drain at source EOF: send a NULL packet to flush the decoder's internal delay frames into the
    /// accumulator, then force-emit the residual (< minSamplesPerBuffer) tail that the gated decode()
    /// path never emits. Without this the final ~21ms+ of every audio-only title was dropped (flush()
    /// discards pending). Mirrors AudioBridge.flush(). Call once at demuxer EOF, before flush()/close().
    func drain() -> [CMSampleBuffer] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        var results: [CMSampleBuffer] = []

        avcodec_send_packet(ctx, nil)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        if let f = frame {
            while avcodec_receive_frame(ctx, f) >= 0 {
                if swrContext == nil {
                    if !initResamplerFromFrame(f) { continue }
                } else if configuredInput.differ(from: f) {
                    if let sampleBuffer = rebuildResampler(for: f) { results.append(sampleBuffer) }
                    if swrContext == nil { continue }
                }
                appendFrameToPending(f)
                if pendingSampleCount >= Self.minSamplesPerBuffer {
                    if let sampleBuffer = emitPending() { results.append(sampleBuffer) }
                }
            }
        }
        // The shaping graph holds back its latency; the drain pushes it out, sample-aligned.
        shapingGraph?.drain { planes, count, pts in appendShaped(planes, count: count, pts: pts) }
        // Force-emit whatever is left below the coalescing threshold (emitPending only needs > 0 samples).
        if let sampleBuffer = emitPending() { results.append(sampleBuffer) }
        return results
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if swrContext != nil {
            swr_free(&swrContext)
        }
        // The stored copy may hold an allocated channel map for custom-order layouts (#452).
        configuredInput.release()
        codecContext = nil
        swrContext = nil
        audioFormatDescription = nil
    }

    deinit {
        close()
    }

    // MARK: - Format Description

    private func createFormatDescription() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let layoutTag = audioChannelLayoutTag(for: channels)
        var layout = AudioChannelLayout(
            mChannelLayoutTag: layoutTag,
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: (AudioChannelDescription())
        )
        let layoutSize = MemoryLayout<AudioChannelLayout>.size

        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: layoutSize,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else {
            throw AudioDecoderError.formatDescriptionFailed
        }
        audioFormatDescription = desc
    }

    // MARK: - Frame → pending buffer → CMSampleBuffer

    /// Resample one frame and append float-interleaved bytes to the pending accumulator. Captures the frame's PTS
    /// on the first append so emitPending() stamps the coalesced buffer correctly.
    private func appendFrameToPending(_ frame: UnsafeMutablePointer<AVFrame>) {
        guard let swr = swrContext else { return }

        let numSamples = Int(frame.pointee.nb_samples)
        guard numSamples > 0 else { return }

        // Every plane swr will read has to be there. The compare in decode() rebuilds on a DECLARED
        // input change; corrupt live MPEG-TS decodes to nb_samples > 0 with a NULL plane and declares
        // nothing, and swr_convert dereferences it just the same (#452).
        guard configuredInput.framePlanesArePresent(frame) else { return }

        let maxOutputSamples = Int(swr_get_out_samples(swr, frame.pointee.nb_samples))
        guard maxOutputSamples > 0 else { return }

        let bytesPerSample = Int(channels) * 4
        let bufferSize = maxOutputSamples * bytesPerSample
        let tempBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { tempBuffer.deallocate() }

        var outPtr: UnsafeMutablePointer<UInt8>? = tempBuffer
        let convertedSamples = withUnsafeMutablePointer(to: &outPtr) { outBuf in
            let srcData = UnsafePointer<UnsafePointer<UInt8>?>(
                OpaquePointer(frame.pointee.extended_data)
            )
            return swr_convert(
                swr,
                outBuf,
                Int32(maxOutputSamples),
                srcData,
                frame.pointee.nb_samples
            )
        }
        #if DEBUG
        if convertedSamples <= 0 && !_loggedZeroConvert {
            _loggedZeroConvert = true
            EngineLog.emit("[AudioDecoder] swr_convert returned \(convertedSamples), pipeline silent from here", category: .swPlayback)
        }
        #endif
        guard convertedSamples > 0 else { return }
        if let graph = shapingGraph {
            // The graph runs on its own sample count; the pts rides along in samples and comes back
            // with the output sample it belongs to (see AudioShapingGraph, Timing).
            let pts: Int64? = frame.pointee.pts == Self.noPTS ? nil
                : av_rescale_q(frame.pointee.pts, timeBase, AVRational(num: 1, den: sampleRate))
            tempBuffer.withMemoryRebound(to: Float.self, capacity: Int(convertedSamples) * Int(channels)) {
                graph.process($0, frames: Int(convertedSamples), pts: pts) { planes, count, pts in
                    appendShaped(planes, count: count, pts: pts)
                }
            }
            return
        }

        // First frame in a new accumulator captures the PTS; subsequent frames only extend the buffer.
        if pendingSampleCount == 0 {
            pendingStartPTS = SourceTimestampBounds.cmTime(ticks: frame.pointee.pts, timeBase: timeBase)
        }

        pendingBytes.append(tempBuffer, count: Int(convertedSamples) * bytesPerSample)
        pendingSampleCount += Int(convertedSamples)
    }

    private static let noPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1

    /// One shaped output chunk (interleaved Float32, `channels` wide) into the accumulator.
    private func appendShaped(_ planes: [UnsafeMutableRawPointer?], count: Int, pts: Int64?) {
        guard count > 0, let base = planes.first ?? nil else { return }
        if pendingSampleCount == 0 {
            pendingStartPTS = pts.map { CMTime(value: $0, timescale: sampleRate) } ?? .invalid
        }
        pendingBytes.append(base.assumingMemoryBound(to: UInt8.self), count: count * Int(channels) * 4)
        pendingSampleCount += count
    }

    /// Build a CMSampleBuffer from the pending accumulator and reset it. Nil if nothing pending.
    private func emitPending() -> CMSampleBuffer? {
        guard pendingSampleCount > 0,
              let formatDesc = audioFormatDescription,
              !pendingBytes.isEmpty
        else { return nil }

        let totalBytes = pendingBytes.count
        let totalSamples = pendingSampleCount
        let startPTS = pendingStartPTS

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
            resetPending()
            return nil
        }

        status = pendingBytes.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard status == kCMBlockBufferNoErr else {
            resetPending()
            return nil
        }

        // Gapless PTS (issue #89): derive this buffer's start from the running sample count so
        // consecutive buffers abut exactly, instead of from the container-quantized PTS (which leaves
        // +/-0.5 ms gaps and per-frame clicks for non-integer-ms frame durations). Committed only on
        // success below, so a dropped buffer never advances the clock.
        let (outPTS, reanchor) = clock.resolve(startPTS: startPTS, sampleRate: sampleRate)

        // Single timing entry: CoreMedia treats `duration` as per-SAMPLE, so LPCM must be 1/sampleRate. Stamping
        // the buffer total made GetDuration report totalSamples^2/sampleRate (~22s for 1024 samples), wedging
        // AudioPlaybackHost's buffer-ahead gate after one packet.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: outPTS,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(totalSamples),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        resetPending()
        guard status == noErr, let sample = sampleBuffer else { return nil }
        clock.commit(pts: outPTS, reanchor: reanchor, sampleCount: totalSamples)
        return sample
    }

    private func resetPending() {
        pendingBytes.removeAll(keepingCapacity: true)
        pendingSampleCount = 0
        pendingStartPTS = .invalid
    }
}

enum AudioDecoderError: Error, CustomStringConvertible, LocalizedError {
    case noCodecParameters
    case unsupportedCodec
    case contextAllocationFailed
    case parameterCopyFailed
    case openFailed
    case formatDescriptionFailed

    var description: String {
        switch self {
        case .noCodecParameters: "AudioDecoder: audio stream has no codec parameters"
        case .unsupportedCodec: "AudioDecoder: no decoder for the audio codec"
        case .contextAllocationFailed: "AudioDecoder: avcodec_alloc_context3 failed"
        case .parameterCopyFailed: "AudioDecoder: avcodec_parameters_to_context failed"
        case .openFailed: "AudioDecoder: decoder open failed"
        case .formatDescriptionFailed: "AudioDecoder: could not build the output format description"
        }
    }

    var errorDescription: String? { description }
}
