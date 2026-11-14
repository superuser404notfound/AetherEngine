import AudioToolbox
import CoreMedia
import Foundation
@testable import AetherEngine

/// Decodes APAC packets back to PCM, so a test can compare two encodes by what they sound like.
///
/// Two separately created encoders fed the same PCM do not always produce the same bytes. On an
/// M6 under macOS 27.0.1 they differed on every run while the decoded audio matched at a signal
/// to error ratio of about 93 dB (AetherEngine#1063); on an M1 they matched. So a test that means "the same
/// encode" compares decoded audio, with a bound far tighter than any reorder, repeat or drop.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
enum APACTestDecoding {

    /// Every packet decoded in order, one array per channel. Goes through `AudioConverter`
    /// with both channel layouts set, the way `SoftwareAPACFormatDescriptionTests` decodes:
    /// `AVAudioConverter` built from the same format refuses the first packet with '!stt'.
    static func decode(_ packets: [Data], format: CMAudioFormatDescription,
                       layoutTag: AudioChannelLayoutTag) throws -> [[Float]] {
        guard var source = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw DecodeError.noDecoder
        }
        let channels = Int(source.mChannelsPerFrame)
        var target = AudioStreamBasicDescription(
            mSampleRate: source.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var made: AudioConverterRef?
        guard AudioConverterNew(&source, &target, &made) == noErr, let converter = made else {
            throw DecodeError.noDecoder
        }
        defer { AudioConverterDispose(converter) }
        var cookieSize = 0
        if let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieSize), cookieSize > 0 {
            let status = AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                                   UInt32(cookieSize), cookie)
            guard status == noErr else { throw DecodeError.failed(status) }
        }
        var acl = AudioChannelLayout()
        acl.mChannelLayoutTag = layoutTag
        let aclSize = UInt32(MemoryLayout<AudioChannelLayout>.size)
        _ = AudioConverterSetProperty(converter, kAudioConverterInputChannelLayout, aclSize, &acl)
        _ = AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout, aclSize, &acl)

        let feed = Feed(packets)
        let chunk = 1024
        let planes = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: chunk) }
        defer { planes.forEach { $0.deallocate() } }
        let listSize = MemoryLayout<AudioBufferList>.size + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let input: AudioConverterComplexInputDataProc = { _, count, data, packetDescription, user in
            let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
            guard feed.index < feed.packets.count else { count.pointee = 0; return noErr }
            let packet = feed.packets[feed.index]
            feed.index += 1
            guard packet.count <= feed.capacity else { count.pointee = 0; return -1 }
            packet.withUnsafeBytes { feed.buffer.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            feed.description.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            count.pointee = 1
            data.pointee.mBuffers.mData = feed.buffer
            data.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
            data.pointee.mBuffers.mNumberChannels = 0
            packetDescription?.pointee = feed.description
            return noErr
        }

        var result = [[Float]](repeating: [], count: channels)
        var failure: OSStatus = noErr
        // The converter holds `feed` unretained, so it has to outlive every call.
        withExtendedLifetime(feed) {
            while true {
                list.pointee.mNumberBuffers = UInt32(channels)
                withUnsafeMutablePointer(to: &list.pointee.mBuffers) { base in
                    let buffers = UnsafeMutableBufferPointer(start: base, count: channels)
                    for c in 0..<channels {
                        buffers[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(chunk * 4), mData: planes[c])
                    }
                }
                var frames = UInt32(chunk)
                let status = AudioConverterFillComplexBuffer(
                    converter, input, Unmanaged.passUnretained(feed).toOpaque(), &frames, list, nil)
                for c in 0..<channels {
                    result[c] += UnsafeBufferPointer(start: planes[c], count: Int(frames))
                }
                if status != noErr { failure = status; break }
                if frames == 0 { break }
            }
        }
        guard failure == noErr else { throw DecodeError.failed(failure) }
        return result
    }

    /// How far apart two packet runs sound, as a signal to error ratio in dB over every channel:
    /// infinite when they decode identically, around 0 dB when the audio is shifted, repeated or
    /// out of order. Two runs that decode to different lengths, or to nothing, come out at -inf,
    /// so an empty decode can never pass as a perfect match.
    static func snr(_ actual: [Data], _ expected: [Data], format: CMAudioFormatDescription,
                    layoutTag: AudioChannelLayoutTag) throws -> Double {
        let a = try decode(actual, format: format, layoutTag: layoutTag)
        let e = try decode(expected, format: format, layoutTag: layoutTag)
        guard a.map(\.count) == e.map(\.count), let frames = e.first?.count, frames > 0 else { return -.infinity }
        var signal = 0.0
        var noise = 0.0
        for (ac, ec) in zip(a, e) {
            for (x, y) in zip(ac, ec) {
                signal += Double(y) * Double(y)
                noise += Double(x - y) * Double(x - y)
            }
        }
        return noise == 0 ? .infinity : 10 * log10(signal / noise)
    }

    /// The bound a test holds two encodes of the same PCM to. Independent encoders matched at about
    /// 93 dB on the machine where they differed. Against the pipeline test's 82 packets,
    /// one swapped pair measured 12.7 dB and one repeated packet 15.7 dB (M1, macOS 27.0).
    static let sameEncodeSNR = 60.0

    private final class Feed {
        let packets: [Data]
        var index = 0
        let capacity = 1 << 16
        /// Stable storage the converter reads after the callback returns.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16)
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        init(_ packets: [Data]) { self.packets = packets }
        deinit {
            buffer.deallocate()
            description.deallocate()
        }
    }

    enum DecodeError: Error {
        case noDecoder
        case failed(OSStatus)
    }
}
