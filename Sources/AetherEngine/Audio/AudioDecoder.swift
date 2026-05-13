import Foundation
import CoreMedia
import CoreAudio
import AudioToolbox
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// FFmpeg software audio decoder. Takes compressed audio AVPackets and
/// produces multichannel interleaved Float32 PCM wrapped in CMSampleBuffers,
/// ready for AVSampleBufferAudioRenderer.
///
/// Uses libswresample to convert whatever FFmpeg decoded (planar float,
/// int16, etc.) to interleaved Float32 at the source sample rate and
/// channel count (up to 7.1). Proper AudioChannelLayout ensures correct
/// speaker mapping for surround output.
///
/// For Dolby Atmos (EAC3+JOC), HLSAudioEngine handles passthrough via
/// AVPlayer, this decoder is used for non-Atmos audio tracks only.
final class AudioDecoder: @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// Source stream time base for PTS conversion.
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)

    /// TrueHD / MLP / lossless codecs emit 40-sample frames (≈0.83ms at
    /// 48kHz). Feeding 1200+ tiny CMSampleBuffers per second to
    /// AVSampleBufferAudioRenderer makes it accept them (no error) and
    /// then silently drop the stream on multichannel output. Coalesce
    /// decoded frames until we have at least this many samples before
    /// building a CMSampleBuffer, renders ~47 buffers/sec at ~21ms
    /// each, which the renderer handles normally.
    private static let minSamplesPerBuffer = 1024

    private var pendingBytes = Data()
    private var pendingStartPTS: CMTime = .invalid
    private var pendingSampleCount: Int = 0

    #if DEBUG
    private var _loggedZeroConvert = false
    #endif

    /// Sample rate of the decoded audio (e.g. 48000).
    private(set) var sampleRate: Int32 = 0
    /// Number of channels (up to 8 for 7.1).
    private(set) var channels: Int32 = 0

    /// Open the decoder for the given audio stream.
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

        // Don't build the resampler yet. TrueHD (and other codecs that
        // advertise AV_CHANNEL_ORDER_UNSPEC or sample_fmt=NONE in
        // codecpar until the first frame is decoded) would make
        // swr_alloc_set_opts2 fail here, bubbling up as "open failed"
        // → audioAvailable=false → no sound. The first frame carries
        // fully resolved layout/rate/format; initialise from it.

        #if DEBUG
        print("[AudioDecoder] Opened: \(sampleRate)Hz, \(channels)ch, codec=\(String(cString: codec.pointee.name))")
        #endif
    }

    /// Decode an audio packet. Returns an array of CMSampleBuffers.
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        guard let ctx = codecContext else { return [] }
        var results: [CMSampleBuffer] = []

        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else { return [] }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else { return [] }

        while avcodec_receive_frame(ctx, f) >= 0 {
            // Lazy resampler init, waits until we have a real frame
            // with fully resolved layout and sample format. Drops the
            // very first frame on failure, but that's one audio block
            // at the most and the stream recovers immediately.
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
        // Refresh sample-rate / channels from the frame, codecpar was
        // a hint, the frame is truth. Happens once at the start of a
        // track so the rest of the pipeline sees the final values.
        if frame.pointee.sample_rate > 0 { sampleRate = frame.pointee.sample_rate }
        let frameChannels = frame.pointee.ch_layout.nb_channels
        if frameChannels > 0 && frameChannels <= 8 { channels = frameChannels }

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, channels)

        // Input layout: use the frame's if valid, otherwise synthesise
        // a default for the channel count. For TrueHD 7.1 this is the
        // key line, the frame always has it right after decoding even
        // when codecpar didn't.
        var inLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, channels)
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
        print("[AudioDecoder] Resampler ready: \(sampleRate)Hz, \(channels)ch, inFmt=\(inFmt.rawValue)")
        #endif
        return true
    }

    /// Flush the decoder (call at EOF or seek).
    func flush() {
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
        // Drop whatever we were coalescing, after a seek the old
        // samples would be at the wrong PTS anyway.
        resetPending()
        #if DEBUG
        _loggedZeroConvert = false
        #endif
    }

    /// Close the decoder and release resources.
    func close() {
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

    // MARK: - Resampler

    private func setupResampler(ctx: UnsafeMutablePointer<AVCodecContext>) throws {
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, channels)

        let ret = swr_alloc_set_opts2(
            &swrContext,
            &outLayout,
            AV_SAMPLE_FMT_FLT,
            sampleRate,
            &ctx.pointee.ch_layout,
            ctx.pointee.sample_fmt,
            ctx.pointee.sample_rate,
            0,
            nil
        )
        guard ret >= 0, swrContext != nil else {
            throw AudioDecoderError.resamplerFailed
        }

        guard swr_init(swrContext) >= 0 else {
            swr_free(&swrContext)
            throw AudioDecoderError.resamplerFailed
        }
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

        let layoutTag = channelLayoutTag(for: channels)
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

    private func channelLayoutTag(for channels: Int32) -> AudioChannelLayoutTag {
        audioChannelLayoutTag(for: channels)
    }

    // MARK: - Frame → pending buffer → CMSampleBuffer

    /// Resample one decoded frame and append the float-interleaved bytes
    /// to the pending accumulator. Remembers the frame's PTS the first
    /// time the accumulator is non-empty so emitPending() can stamp the
    /// coalesced buffer correctly.
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
            print("[AudioDecoder] swr_convert returned \(convertedSamples), pipeline silent from here")
        }
        #endif
        guard convertedSamples > 0 else { return }

        // First frame in a new accumulator → capture its PTS. Subsequent
        // frames extend the same buffer, so only the start matters.
        if pendingSampleCount == 0 {
            let pts = frame.pointee.pts
            pendingStartPTS = (pts != Int64.min)
                ? CMTimeMake(value: pts * Int64(timeBase.num), timescale: Int32(timeBase.den))
                : .invalid
        }

        pendingBytes.append(tempBuffer, count: Int(convertedSamples) * bytesPerSample)
        pendingSampleCount += Int(convertedSamples)
    }

    /// Build a CMSampleBuffer from whatever is currently in the pending
    /// accumulator and reset it. Returns nil if nothing was pending.
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

        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(totalSamples), timescale: sampleRate),
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
    case resamplerFailed
    case formatDescriptionFailed
}
