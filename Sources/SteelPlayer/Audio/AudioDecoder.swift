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
final class AudioDecoder: @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// Source stream time base for PTS conversion.
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)

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

        try setupResampler(ctx: ctx)
        try createFormatDescription()

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

    /// Set up libswresample to convert decoded audio to interleaved Float32.
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
        switch channels {
        case 1:  return kAudioChannelLayoutTag_Mono
        case 2:  return kAudioChannelLayoutTag_Stereo
        case 3:  return kAudioChannelLayoutTag_MPEG_3_0_A
        case 4:  return kAudioChannelLayoutTag_Quadraphonic
        case 5:  return kAudioChannelLayoutTag_MPEG_5_0_A
        case 6:  return kAudioChannelLayoutTag_MPEG_5_1_A
        case 7:  return kAudioChannelLayoutTag_MPEG_6_1_A
        case 8:  return kAudioChannelLayoutTag_MPEG_7_1_A
        default: return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        }
    }

    // MARK: - Frame → CMSampleBuffer

    private func convertFrameToSampleBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CMSampleBuffer? {
        guard let swr = swrContext, let formatDesc = audioFormatDescription else { return nil }

        let numSamples = Int(frame.pointee.nb_samples)
        guard numSamples > 0 else { return nil }

        let maxOutputSamples = Int(swr_get_out_samples(swr, frame.pointee.nb_samples))
        guard maxOutputSamples > 0 else { return nil }

        let bytesPerSample = Int(channels) * 4
        let bufferSize = maxOutputSamples * bytesPerSample
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { outputBuffer.deallocate() }

        var outPtr: UnsafeMutablePointer<UInt8>? = outputBuffer
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
        guard convertedSamples > 0 else { return nil }

        let actualSize = Int(convertedSamples) * bytesPerSample

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: actualSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: actualSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = CMBlockBufferReplaceDataBytes(
            with: outputBuffer, blockBuffer: block, offsetIntoDestination: 0, dataLength: actualSize
        )
        guard status == kCMBlockBufferNoErr else { return nil }

        let pts = frame.pointee.pts
        let cmPTS: CMTime
        if pts != Int64.min {
            cmPTS = CMTimeMake(value: pts * Int64(timeBase.num), timescale: Int32(timeBase.den))
        } else {
            cmPTS = .invalid
        }

        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(convertedSamples), timescale: sampleRate),
            presentationTimeStamp: cmPTS,
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
