import Foundation
import CoreMedia
import CoreAudio
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// FFmpeg software audio decoder. Takes compressed audio AVPackets and
/// produces interleaved PCM data wrapped in CMSampleBuffers, ready for
/// AVSampleBufferAudioRenderer.
///
/// Internally uses libswresample to convert whatever FFmpeg decoded
/// (planar float, int16, etc.) to interleaved Float32 at the source
/// sample rate — which is what AVSampleBufferAudioRenderer expects.
final class AudioDecoder {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?  // SwrContext
    private var audioFormatDescription: CMAudioFormatDescription?

    /// Source stream time base for PTS conversion.
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)

    /// Sample rate of the decoded audio (e.g. 48000).
    private(set) var sampleRate: Int32 = 0
    /// Number of channels.
    private(set) var channels: Int32 = 0

    /// Open the decoder for the given audio stream.
    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecpar = stream.pointee.codecpar else {
            throw AudioDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        sampleRate = codecpar.pointee.sample_rate
        let sourceChannels = codecpar.pointee.ch_layout.nb_channels
        // Force stereo output — AVSampleBufferAudioRenderer handles
        // 5.1→stereo downmix poorly, causing clock jitter and video stutter.
        // TODO: investigate proper multi-channel passthrough
        channels = 2
        #if DEBUG
        if sourceChannels != channels {
            print("[AudioDecoder] Downmixing \(sourceChannels)ch → \(channels)ch")
        }
        #endif

        // Find the decoder
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw AudioDecoderError.unsupportedCodec
        }

        // Allocate codec context
        guard let ctx = avcodec_alloc_context3(codec) else {
            throw AudioDecoderError.contextAllocationFailed
        }
        codecContext = ctx

        // Copy codec parameters
        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw AudioDecoderError.parameterCopyFailed
        }

        // Open the decoder
        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            throw AudioDecoderError.openFailed
        }

        // Set up libswresample for conversion to interleaved Float32
        try setupResampler(ctx: ctx)

        // Create CMAudioFormatDescription for the output format
        try createFormatDescription()

        #if DEBUG
        print("[AudioDecoder] Opened: \(sampleRate)Hz, \(channels)ch, codec=\(String(cString: codec.pointee.name))")
        #endif
    }

    /// Decode an audio packet. Returns an array of CMSampleBuffers
    /// (one per decoded frame — usually one, but can be multiple for
    /// some codecs).
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        guard let ctx = codecContext else { return [] }
        var results: [CMSampleBuffer] = []

        // Send packet to decoder
        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else { return [] }

        // Receive decoded frames
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else { return [] }

        while avcodec_receive_frame(ctx, f) >= 0 {
            if let sampleBuffer = convertFrameToSampleBuffer(f) {
                results.append(sampleBuffer)
            }
        }

        return results
    }

    /// Flush the decoder (call at EOF or seek).
    func flush() {
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
    }

    /// Close the decoder and release resources.
    func close() {
        if let ctx = codecContext {
            avcodec_free_context(&codecContext)
        }
        if let swr = swrContext {
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

    /// Set up libswresample to convert decoded audio to interleaved Float32.
    private func setupResampler(ctx: UnsafeMutablePointer<AVCodecContext>) throws {
        // Output: interleaved Float32 at source sample rate
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, channels)

        // swr_alloc_set_opts2 allocates the SwrContext internally —
        // do NOT call swr_alloc() first or the pre-allocated context leaks.
        let ret = swr_alloc_set_opts2(
            &swrContext,
            &outLayout,
            AV_SAMPLE_FMT_FLT,  // interleaved float32
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
            mBytesPerPacket: UInt32(channels) * 4,  // Float32 = 4 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
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

    // MARK: - Frame → CMSampleBuffer

    /// Convert a decoded AVFrame to a CMSampleBuffer with interleaved
    /// Float32 PCM data.
    private func convertFrameToSampleBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CMSampleBuffer? {
        guard let swr = swrContext, let formatDesc = audioFormatDescription else { return nil }

        let numSamples = Int(frame.pointee.nb_samples)
        guard numSamples > 0 else { return nil }

        // Ask libswresample how many output samples to expect (accounts
        // for sample rate conversion producing more/fewer samples).
        let maxOutputSamples = Int(swr_get_out_samples(swr, frame.pointee.nb_samples))
        guard maxOutputSamples > 0 else { return nil }

        // Allocate output buffer for resampled audio
        let bytesPerSample = Int(channels) * 4  // Float32 per channel
        let bufferSize = maxOutputSamples * bytesPerSample
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { outputBuffer.deallocate() }

        // Resample / convert
        var outPtr: UnsafeMutablePointer<UInt8>? = outputBuffer
        let convertedSamples = withUnsafeMutablePointer(to: &outPtr) { outBuf in
            // extended_data is UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
            // swr_convert wants UnsafePointer<UnsafePointer<UInt8>?> — bridge via OpaquePointer
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
        guard convertedSamples > 0 else { return nil }

        let actualSize = Int(convertedSamples) * bytesPerSample

        // Build CMBlockBuffer from the PCM data
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,  // let CoreMedia allocate
            blockLength: actualSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: actualSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        // Copy PCM data into the block buffer
        status = CMBlockBufferReplaceDataBytes(
            with: outputBuffer,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: actualSize
        )
        guard status == kCMBlockBufferNoErr else { return nil }

        // Build CMSampleBuffer with timing
        var sampleBuffer: CMSampleBuffer?
        let pts = frame.pointee.pts
        let avNoPTS: Int64 = Int64.min
        let cmPTS: CMTime
        if pts != avNoPTS {
            cmPTS = CMTimeMake(
                value: pts * Int64(timeBase.num),
                timescale: Int32(timeBase.den)
            )
        } else {
            cmPTS = .invalid
        }

        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(convertedSamples), timescale: sampleRate),
            presentationTimeStamp: cmPTS,
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(convertedSamples),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sample = sampleBuffer else { return nil }
        return sample
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
