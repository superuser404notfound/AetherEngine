import Testing
import AVFoundation
import CoreMedia
import AudioToolbox
@testable import AetherEngine

/// The renderer is handed APAC packets with the encoder's format description. A description without the
/// `dapa` cookie and a packet size lets the renderer start, report `rendering` and no error, and fail
/// every packet inside: the route is silent and nothing says so. These decode the packets from nothing
/// but the sample buffer's own description, which is all the renderer has.
@Suite("Software APAC route format description")
struct SoftwareAPACFormatDescriptionTests {

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func encoded(_ layout: SpatialSpeakerLayout) throws -> (APACEncoder, [APACEncoder.Packet]) {
        let encoder = try APACEncoder(layout: layout, bitRate: 1_000_000)
        let frames = 48_000
        var planes = [[Float]](repeating: [Float](repeating: 0, count: frames), count: layout.channelCount)
        for i in 0..<frames { planes[2][i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000)) }
        let pointers = planes.map { plane -> UnsafePointer<Float> in
            let copy = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            copy.update(from: plane, count: frames)
            return UnsafePointer(copy)
        }
        defer { pointers.forEach { $0.deallocate() } }
        var packets = try encoder.encode(planes: pointers, frameCount: frames)
        packets += try encoder.flush()
        return (encoder, packets)
    }

    @Test("the description the renderer gets carries the dapa cookie and 1024 frames per packet")
    func descriptionHasCookieAndPacketSize() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let (encoder, _) = try encoded(.l512)
        var size = 0
        let found = CMAudioFormatDescriptionGetMagicCookie(encoder.formatDescription, sizeOut: &size)
        let cookie = try #require(found)
        #expect(size > 0)
        #expect(Data(bytes: cookie, count: size) == encoder.magicCookie)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(encoder.formatDescription)?.pointee)
        #expect(asbd.mFramesPerPacket == 1024)
        #expect(asbd.mChannelsPerFrame == UInt32(SpatialSpeakerLayout.l512.channelCount))
    }

    private final class Feed {
        var packets: [Data]
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

    #if TrueHDObjectAudio || DTSXObjectAudio
    @Test("packets decode from the sample buffer's own format description")
    func packetsDecodeFromTheirOwnDescription() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l512
        let channels = layout.channelCount
        let (encoder, packets) = try encoded(layout)
        let sample = try #require(packets.first?.data.withUnsafeBytes {
            SoftwareAPACProducer.sampleBuffer(bytes: $0, seconds: 0, formatDescription: encoder.formatDescription)
        })
        // Everything the decoder is configured with comes from the buffer, not from the encoder.
        let description = try #require(CMSampleBufferGetFormatDescription(sample))
        var source = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        var target = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var converterOut: AudioConverterRef?
        #expect(AudioConverterNew(&source, &target, &converterOut) == noErr)
        let converter = try #require(converterOut)
        defer { AudioConverterDispose(converter) }
        var cookieSize = 0
        if let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &cookieSize), cookieSize > 0 {
            #expect(AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                              UInt32(cookieSize), cookie) == noErr)
        }
        var acl = AudioChannelLayout()
        acl.mChannelLayoutTag = layout.channelLayoutTag
        let aclSize = UInt32(MemoryLayout<AudioChannelLayout>.size)
        _ = AudioConverterSetProperty(converter, kAudioConverterInputChannelLayout, aclSize, &acl)
        _ = AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout, aclSize, &acl)

        let feed = Feed(Array(packets.prefix(12).map(\.data)))
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
        var decodedFrames = 0
        var failure: OSStatus = noErr
        // The converter holds `feed` unretained, so it has to outlive every call.
        withExtendedLifetime(feed) {
            for _ in 0..<64 {
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
                if status != noErr && frames == 0 { failure = status; break }
                decodedFrames += Int(frames)
                if frames == 0 { break }
            }
        }
        #expect(failure == noErr, "decode failed with \(failure)")
        #expect(decodedFrames > 0)
    }
    #endif
}
