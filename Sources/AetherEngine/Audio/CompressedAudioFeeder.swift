import Foundation
import CoreMedia
import CoreAudio
import AudioToolbox
import Libavformat
import Libavcodec
import Libavutil

/// Feeds raw AC3/EAC3 compressed audio directly to AVSampleBufferAudioRenderer
/// without FFmpeg decoding. The renderer handles decoding internally and can
/// preserve Dolby Atmos object metadata for EAC3+JOC passthrough.
///
/// This avoids the complexity of AVPlayer + HTTP server + fMP4 muxing.
/// Uses the same AVSampleBufferRenderSynchronizer as the PCM path.
final class CompressedAudioFeeder: @unchecked Sendable {

    private var formatDescription: CMAudioFormatDescription?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)

    /// The codec being used (for logging).
    private(set) var codecName: String = ""
    private(set) var sampleRate: Int32 = 0
    private(set) var channels: Int32 = 0

    /// Open the feeder for a given audio stream. Creates the compressed
    /// format description from stream parameters.
    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecpar = stream.pointee.codecpar else {
            throw CompressedAudioFeederError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        sampleRate = codecpar.pointee.sample_rate
        channels = codecpar.pointee.ch_layout.nb_channels
        if sampleRate <= 0 { sampleRate = 48000 }
        if channels <= 0 { channels = 6 }

        let codecId = codecpar.pointee.codec_id
        let formatID: AudioFormatID
        if codecId == AV_CODEC_ID_EAC3 {
            formatID = kAudioFormatEnhancedAC3
            codecName = "eac3"
        } else if codecId == AV_CODEC_ID_AC3 {
            formatID = kAudioFormatAC3
            codecName = "ac3"
        } else {
            throw CompressedAudioFeederError.unsupportedCodec
        }

        // Create AudioStreamBasicDescription for compressed format.
        // For compressed formats: mBytesPerPacket=0 (variable),
        // mFramesPerPacket=samples per frame, mBytesPerFrame=0.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,    // Variable for compressed
            mFramesPerPacket: 1536, // AC3/EAC3 standard: 6 blocks × 256
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // Channel layout
        let layoutTag = channelLayoutTag(for: channels)
        var layout = AudioChannelLayout(
            mChannelLayoutTag: layoutTag,
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: (AudioChannelDescription())
        )

        // Magic cookie: for AC3/EAC3 in CoreAudio, the magic cookie
        // can be the codec-specific data (extradata from FFmpeg).
        // If not available, pass nil — CoreAudio can often work without it.
        let magicCookie: UnsafeRawPointer?
        let magicCookieSize: Int
        if codecpar.pointee.extradata != nil && codecpar.pointee.extradata_size > 0 {
            magicCookie = UnsafeRawPointer(codecpar.pointee.extradata)
            magicCookieSize = Int(codecpar.pointee.extradata_size)
        } else {
            magicCookie = nil
            magicCookieSize = 0
        }

        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: magicCookieSize,
            magicCookie: magicCookie,
            extensions: nil,
            formatDescriptionOut: &desc
        )
        guard status == noErr, let formatDesc = desc else {
            throw CompressedAudioFeederError.formatDescriptionFailed(status)
        }
        formatDescription = formatDesc

        #if DEBUG
        print("[CompressedAudioFeeder] Opened: \(codecName), \(sampleRate)Hz, \(channels)ch, formatID=\(String(format: "0x%08x", formatID))")
        #endif
    }

    /// Wrap a raw compressed audio packet as a CMSampleBuffer.
    /// Returns nil if the packet can't be wrapped.
    func wrapPacket(_ packet: UnsafeMutablePointer<AVPacket>) -> CMSampleBuffer? {
        guard let formatDesc = formatDescription else { return nil }
        guard packet.pointee.size > 0, packet.pointee.data != nil else { return nil }

        let dataSize = Int(packet.pointee.size)

        // Create CMBlockBuffer with the compressed audio data
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
            with: packet.pointee.data,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )
        guard status == kCMBlockBufferNoErr else { return nil }

        // PTS from the packet
        let pts = packet.pointee.pts
        let cmPTS: CMTime
        if pts != Int64.min && pts >= 0 {
            cmPTS = CMTimeMake(value: pts * Int64(timeBase.num), timescale: Int32(timeBase.den))
        } else {
            cmPTS = .invalid
        }

        // Duration: 1536 samples at sample rate
        let duration = CMTimeMake(value: 1536, timescale: sampleRate)

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: cmPTS,
            decodeTimeStamp: .invalid
        )

        // For compressed audio: 1 sample = 1 access unit (the entire packet)
        var sampleSize = dataSize
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
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sample = sampleBuffer else { return nil }
        return sample
    }

    func flush() {
        // No internal state to flush — just a wrapper
    }

    func close() {
        formatDescription = nil
    }

    deinit {
        close()
    }

    // MARK: - Channel Layout

    private func channelLayoutTag(for channels: Int32) -> AudioChannelLayoutTag {
        audioChannelLayoutTag(for: channels)
    }
}

enum CompressedAudioFeederError: Error {
    case noCodecParameters
    case unsupportedCodec
    case formatDescriptionFailed(OSStatus)
}
