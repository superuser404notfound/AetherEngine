import Foundation
import CoreMedia
import AudioToolbox
#if os(iOS) || os(tvOS) || os(visionOS)
import AVFoundation
#elseif os(macOS)
import CoreAudio
#endif
import AetherLibavcodec
import AetherLibavutil

/// The form a rendered object-audio bed is handed to the system in.
///
/// Measured 2026-10-28 on an Apple TV 4K (tvOS 27) into a Sonos with Continuous Audio Connection off,
/// with one noise burst per channel: 12 and 16 channels of linear PCM in the `Atmos_7_1_4` /
/// `Atmos_9_1_6` layouts reached the receiver as Dolby Atmos with every channel on its own speaker,
/// over HLS fMP4 (`ipcm`) through AVPlayer and through a sample-buffer renderer with
/// `AtmosOutputActivator` beside it. On an iPhone with AirPods and spatial audio the same streams
/// played with every channel in place, and on a MacBook Air (macOS 27) both through its own speakers
/// and AirPods. Over AirPlay to that Sonos neither PCM nor APAC arrived as more than stereo; APAC to a
/// HomePod pair has played as Atmos (#834), PCM there is unmeasured.
enum SpatialBedFormat: String, Sendable, Equatable {
    /// Apple Positional Audio, lossy, a few Mbit/s.
    case apac
    /// 24-bit linear PCM, the rendered bed bit for bit: 1.15 Mbit/s per channel.
    case lpcm

    /// The form `ObjectAudioRendering.render` takes: PCM unless the current route plays over AirPlay
    /// (an AirPlay port in the session's route, or on macOS an AirPlay default output device).
    /// visionOS follows iOS without a measurement of its own: same session, same AirPods.
    static func forCurrentRoute() -> SpatialBedFormat {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        return forRoute(portTypes: ports.map(\.rawValue))
        #elseif os(macOS)
        return defaultOutputIsAirPlay() ? .apac : .lpcm
        #else
        return .apac
        #endif
    }

    #if os(macOS)
    /// Whether the system's default output device is an AirPlay device, by its CoreAudio transport type.
    /// Unknown counts as not AirPlay: a device the HAL cannot describe is local.
    static func defaultOutputIsAirPlay() -> Bool {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeAirPlay
    }
    #endif

    /// Pure half of `forCurrentRoute`, for the tests.
    static func forRoute(portTypes: [String]) -> SpatialBedFormat {
        portTypes.contains(airPlayPortType) ? .apac : .lpcm
    }

    /// `AVAudioSession.Port.airPlay.rawValue`, spelled out so the rule compiles on every platform.
    static let airPlayPortType = "AirPlay"
}

/// Planar float planes, one per bed channel, that grow on demand. Owned by one side at a time: the
/// bridge between `acquire` and `submit`, the sink until it hands the buffer back.
final class SpatialBedBuffer: @unchecked Sendable {
    private(set) var planes: [UnsafeMutablePointer<Float>]
    private(set) var capacity: Int

    init(channels: Int, capacity: Int) {
        self.capacity = capacity
        planes = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
    }

    deinit { planes.forEach { $0.deallocate() } }

    /// Room for `frames`, keeping the first `keeping` frames of every plane.
    func ensureCapacity(_ frames: Int, keeping: Int) {
        guard frames > capacity else { return }
        let grown = max(frames, capacity * 2)
        for c in planes.indices {
            let plane = UnsafeMutablePointer<Float>.allocate(capacity: grown)
            plane.update(from: planes[c], count: keeping)
            planes[c].deallocate()
            planes[c] = plane
        }
        capacity = grown
    }
}

/// One packet of the delivered bed, stamped on the output time base (48 kHz frames).
struct SpatialBedPacket {
    let data: Data
    let isSync: Bool
    let pts: Int64
    let frames: Int
}

/// Where `SpatialAudioBridge` hands its rendered bed: the APAC encoder or the PCM packer. The bridge
/// renders into a buffer, submits it with its position and gets the next one back; packets come back
/// through `collect` and the drains.
protocol SpatialBedSink: AnyObject {
    /// Frames a decoder primes with before the first content frame, which the stamping already counts.
    var leadingFrames: Int { get }
    func takeInitialBuffer() -> SpatialBedBuffer
    func submit(_ buffer: SpatialBedBuffer, frames: Int, position: Int64) -> SpatialBedBuffer
    func restart()
    func shift(by frames: Int64)
    func finish() -> (packets: [SpatialBedPacket], errors: [Error])
    func reset()
    func collect() -> (packets: [SpatialBedPacket], errors: [Error])
    func settle() -> (packets: [SpatialBedPacket], errors: [Error])
    func close()
}

/// The bed as interleaved signed 24-bit little-endian PCM, in the bed's own channel order (CoreAudio's
/// for `SpatialSpeakerLayout.channelLayoutTag`), which is what movenc writes as `ipcm` and a sample
/// buffer carries as `lpcm`.
///
/// Packing is a copy and a scale, a fraction of what the render costs, so it runs on the caller's
/// thread and every submit's packets are ready at once. Packets are `framesPerPacket` long, the last
/// one of a submit shorter, each stamped on its own first frame: PCM has no priming and no inter-packet
/// state, so a restart or shift only moves the stamps of what follows.
final class PCMBedPacker: SpatialBedSink, @unchecked Sendable {
    static let framesPerPacket = 1024
    static let bytesPerSample = 3

    let channels: Int
    var leadingFrames: Int { 0 }

    private var buffer: SpatialBedBuffer
    private var ready: [SpatialBedPacket] = []

    init(channels: Int, bufferFrames: Int) {
        self.channels = channels
        buffer = SpatialBedBuffer(channels: channels, capacity: bufferFrames)
    }

    func takeInitialBuffer() -> SpatialBedBuffer { buffer }

    func submit(_ buffer: SpatialBedBuffer, frames: Int, position: Int64) -> SpatialBedBuffer {
        var offset = 0
        while offset < frames {
            let n = min(Self.framesPerPacket, frames - offset)
            ready.append(SpatialBedPacket(
                data: Self.interleave(buffer.planes, from: offset, frames: n),
                isSync: true, pts: position + Int64(offset), frames: n))
            offset += n
        }
        return buffer
    }

    func restart() {}
    func shift(by frames: Int64) {}
    func reset() { ready.removeAll() }
    func close() {}
    func finish() -> (packets: [SpatialBedPacket], errors: [Error]) { collect() }
    func settle() -> (packets: [SpatialBedPacket], errors: [Error]) { collect() }

    func collect() -> (packets: [SpatialBedPacket], errors: [Error]) {
        let out = ready
        ready.removeAll(keepingCapacity: true)
        return (out, [])
    }

    /// `frames` frames from `offset` of every plane, interleaved, rounded to 24 bits and clamped to
    /// full scale (the bridge's limiter keeps the bed under it; a stray sample must not wrap).
    static func interleave(_ planes: [UnsafeMutablePointer<Float>], from offset: Int, frames: Int) -> Data {
        let channels = planes.count
        var data = Data(count: frames * channels * bytesPerSample)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self).baseAddress!
            var i = 0
            for f in 0..<frames {
                for c in 0..<channels {
                    let scaled = (planes[c][offset + f] * 8_388_608).rounded()
                    let v = Int32(max(-8_388_608, min(8_388_607, scaled)))
                    out[i] = UInt8(truncatingIfNeeded: v)
                    out[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    out[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
                    i += 3
                }
            }
        }
        return data
    }

    /// The packets' format for a sample-buffer renderer: packed signed 24-bit PCM in the bed's layout.
    static func formatDescription(layout: SpatialSpeakerLayout, sampleRate: Int) -> CMAudioFormatDescription? {
        let channels = UInt32(layout.channelCount)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * UInt32(bytesPerSample), mFramesPerPacket: 1,
            mBytesPerFrame: channels * UInt32(bytesPerSample), mChannelsPerFrame: channels,
            mBitsPerChannel: UInt32(bytesPerSample * 8), mReserved: 0)
        var acl = AudioChannelLayout()
        acl.mChannelLayoutTag = layout.channelLayoutTag
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &acl,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    /// Codec parameters movenc writes the bed from: `pcm_s24le` with a custom channel layout in the
    /// bed's order. movenc turns that into a `chnl` box AVFoundation reads back as exactly
    /// `Atmos_7_1_4` / `Atmos_9_1_6` (measured on macOS 27 with FFmpeg 8.1), wides and top-middles
    /// included, so no reordering happens anywhere.
    static func makeCodecpar(layout: SpatialSpeakerLayout, sampleRate: Int) -> UnsafeMutablePointer<AVCodecParameters>? {
        guard let cp = avcodec_parameters_alloc() else { return nil }
        cp.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        cp.pointee.codec_id = AV_CODEC_ID_PCM_S24LE
        cp.pointee.sample_rate = Int32(sampleRate)
        cp.pointee.frame_size = Int32(framesPerPacket)
        cp.pointee.bits_per_raw_sample = 24
        cp.pointee.bits_per_coded_sample = 24
        cp.pointee.block_align = Int32(layout.channelCount * bytesPerSample)
        cp.pointee.bit_rate = Int64(layout.channelCount * bytesPerSample * 8 * sampleRate)
        guard av_channel_layout_custom_init(&cp.pointee.ch_layout, Int32(layout.channelCount)) >= 0 else {
            var p: UnsafeMutablePointer<AVCodecParameters>? = cp
            avcodec_parameters_free(&p)
            return nil
        }
        for (i, speaker) in layout.speakers.enumerated() {
            cp.pointee.ch_layout.u.map[i].id = speaker.avChannel
        }
        return cp
    }
}

extension SpatialSpeaker {
    /// libavutil's channel for this position, in the sense its `chnl` writer maps to ISO 23001-8 and
    /// AVFoundation maps on to the CoreAudio label `channelLabel` names.
    var avChannel: AVChannel {
        switch self {
        case .left: return AV_CHAN_FRONT_LEFT
        case .right: return AV_CHAN_FRONT_RIGHT
        case .center: return AV_CHAN_FRONT_CENTER
        case .lfe: return AV_CHAN_LOW_FREQUENCY
        case .surroundLeft, .sideLeft: return AV_CHAN_SIDE_LEFT
        case .surroundRight, .sideRight: return AV_CHAN_SIDE_RIGHT
        case .rearLeft: return AV_CHAN_BACK_LEFT
        case .rearRight: return AV_CHAN_BACK_RIGHT
        case .wideLeft: return AV_CHAN_WIDE_LEFT
        case .wideRight: return AV_CHAN_WIDE_RIGHT
        case .topFrontLeft: return AV_CHAN_TOP_FRONT_LEFT
        case .topFrontRight: return AV_CHAN_TOP_FRONT_RIGHT
        case .topMiddleLeft: return AV_CHAN_TOP_SIDE_LEFT
        case .topMiddleRight: return AV_CHAN_TOP_SIDE_RIGHT
        case .topRearLeft: return AV_CHAN_TOP_BACK_LEFT
        case .topRearRight: return AV_CHAN_TOP_BACK_RIGHT
        }
    }
}
