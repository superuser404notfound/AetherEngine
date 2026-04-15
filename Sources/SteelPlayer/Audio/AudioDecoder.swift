import Foundation
import CoreMedia
import CoreAudio
import AudioToolbox
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// FFmpeg audio decoder with passthrough support for EAC3/AC3.
///
/// Two modes:
/// - **Passthrough** (EAC3, AC3): Raw compressed packets are wrapped in
///   CMSampleBuffers and fed directly to AVSampleBufferAudioRenderer.
///   Apple's internal decoder handles decompression + Dolby MAT 2.0 output.
///   This preserves Dolby Atmos object metadata and height channels.
/// - **Decode** (everything else): FFmpeg decodes to PCM, libswresample
///   converts to interleaved Float32 at source sample rate.
final class AudioDecoder: @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// Source stream time base for PTS conversion.
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)

    /// Sample rate of the decoded audio (e.g. 48000).
    private(set) var sampleRate: Int32 = 0
    /// Number of channels.
    private(set) var channels: Int32 = 0

    /// True when using compressed passthrough (EAC3/AC3) instead of FFmpeg decode.
    private(set) var isPassthrough = false

    /// Frames per packet for compressed formats (EAC3=1536, AC3=1536).
    private var framesPerPacket: UInt32 = 0

    /// Open the decoder for the given audio stream.
    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecpar = stream.pointee.codecpar else {
            throw AudioDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        sampleRate = codecpar.pointee.sample_rate
        channels = codecpar.pointee.ch_layout.nb_channels
        if channels <= 0 || channels > 8 { channels = 2 }

        let codecId = codecpar.pointee.codec_id

        // EAC3 and AC3: use passthrough — Apple's renderer handles decode
        // internally and preserves Dolby Atmos metadata for HDMI output.
        if codecId == AV_CODEC_ID_EAC3 || codecId == AV_CODEC_ID_AC3 {
            isPassthrough = true
            framesPerPacket = 1536  // Standard for AC3/EAC3
            try createPassthroughFormatDescription(codecId: codecId)
            #if DEBUG
            let name = codecId == AV_CODEC_ID_EAC3 ? "eac3" : "ac3"
            print("[AudioDecoder] Passthrough: \(sampleRate)Hz, \(channels)ch, codec=\(name)")
            #endif
            return
        }

        // All other codecs: FFmpeg decode to PCM
        isPassthrough = false
        guard let codec = avcodec_find_decoder(codecId) else {
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
        try createPCMFormatDescription()

        #if DEBUG
        print("[AudioDecoder] Decode: \(sampleRate)Hz, \(channels)ch, codec=\(String(cString: codec.pointee.name))")
        #endif
    }

    /// Process an audio packet. Returns CMSampleBuffers.
    /// In passthrough mode, wraps raw compressed data.
    /// In decode mode, decodes to PCM via FFmpeg.
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        if isPassthrough {
            if let sb = wrapCompressedPacket(packet) { return [sb] }
            return []
        }
        return decodeToPCM(packet: packet)
    }

    /// Flush the decoder (call at EOF or seek).
    func flush() {
        guard !isPassthrough, let ctx = codecContext else { return }
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
        isPassthrough = false
    }

    deinit {
        close()
    }

    // MARK: - Passthrough (EAC3/AC3)

    /// Create a format description for compressed EAC3 or AC3.
    /// AVSampleBufferAudioRenderer accepts these and decodes internally,
    /// preserving Dolby Atmos object metadata for HDMI output.
    private func createPassthroughFormatDescription(codecId: AVCodecID) throws {
        let formatID: AudioFormatID = codecId == AV_CODEC_ID_EAC3
            ? kAudioFormatEnhancedAC3
            : kAudioFormatAC3

        // Compressed formats: mBytesPerPacket, mBytesPerFrame, mBitsPerChannel must be 0
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
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

    /// Wrap a raw compressed AVPacket into a CMSampleBuffer for passthrough.
    private func wrapCompressedPacket(_ packet: UnsafeMutablePointer<AVPacket>) -> CMSampleBuffer? {
        guard let formatDesc = audioFormatDescription,
              let data = packet.pointee.data,
              packet.pointee.size > 0 else { return nil }

        let dataSize = Int(packet.pointee.size)

        // Create block buffer with packet data
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = CMBlockBufferReplaceDataBytes(
            with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize
        )
        guard status == kCMBlockBufferNoErr else { return nil }

        // PTS conversion
        let pts = packet.pointee.pts
        let cmPTS: CMTime
        if pts != Int64.min {
            cmPTS = CMTimeMake(value: pts * Int64(timeBase.num), timescale: Int32(timeBase.den))
        } else {
            cmPTS = .invalid
        }

        // For compressed formats, use packet descriptions
        var packetSize = dataSize
        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(framesPerPacket), timescale: sampleRate),
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
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &packetSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sample = sampleBuffer else { return nil }
        return sample
    }

    // MARK: - FFmpeg Decode (PCM output)

    private func decodeToPCM(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
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

    // MARK: - Resampler (PCM mode)

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

    // MARK: - Format Description (PCM mode)

    private func createPCMFormatDescription() throws {
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

    // MARK: - Frame → CMSampleBuffer (PCM mode)

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
