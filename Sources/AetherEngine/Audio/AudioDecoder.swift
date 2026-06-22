import Foundation
import CoreMedia
import CoreAudio
import AudioToolbox
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

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

    #if DEBUG
    private var _loggedZeroConvert = false
    #endif

    private(set) var sampleRate: Int32 = 0
    private(set) var channels: Int32 = 0

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

    private func initResamplerFromFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        // Refresh rate/channels from the frame (codecpar was a hint, the frame is truth). Once per track.
        if frame.pointee.sample_rate > 0 { sampleRate = frame.pointee.sample_rate }
        let frameChannels = frame.pointee.ch_layout.nb_channels
        if frameChannels > 0 && frameChannels <= 8 { channels = frameChannels }

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, channels)

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
        guard ret >= 0, swrContext != nil else { return false }
        guard swr_init(swrContext) >= 0 else {
            swr_free(&swrContext)
            return false
        }

        do {
            try createFormatDescription()
        } catch {
            swr_free(&swrContext)
            return false
        }

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
                }
                appendFrameToPending(f)
                if pendingSampleCount >= Self.minSamplesPerBuffer {
                    if let sampleBuffer = emitPending() { results.append(sampleBuffer) }
                }
            }
        }
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

        // First frame in a new accumulator captures the PTS; subsequent frames only extend the buffer.
        if pendingSampleCount == 0 {
            let pts = frame.pointee.pts
            pendingStartPTS = (pts != Int64.min)
                ? CMTimeMake(value: pts * Int64(timeBase.num), timescale: Int32(timeBase.den))
                : .invalid
        }

        pendingBytes.append(tempBuffer, count: Int(convertedSamples) * bytesPerSample)
        pendingSampleCount += Int(convertedSamples)
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

        // Single timing entry: CoreMedia treats `duration` as per-SAMPLE, so LPCM must be 1/sampleRate. Stamping
        // the buffer total made GetDuration report totalSamples^2/sampleRate (~22s for 1024 samples), wedging
        // AudioPlaybackHost's buffer-ahead gate after one packet.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: startPTS,
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
        return sample
    }

    private func resetPending() {
        pendingBytes.removeAll(keepingCapacity: true)
        pendingSampleCount = 0
        pendingStartPTS = .invalid
    }
}

enum AudioDecoderError: Error {
    case noCodecParameters
    case unsupportedCodec
    case contextAllocationFailed
    case parameterCopyFailed
    case openFailed
    case formatDescriptionFailed
}
