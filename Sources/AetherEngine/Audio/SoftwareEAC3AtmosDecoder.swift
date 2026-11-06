import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// E-AC-3 JOC for the software host on tvOS: the system's own Atmos decoder, run here through an
/// `AudioConverter`, renders the objects into the session's speaker bed, and the bed goes to the audio
/// renderer as PCM, the form the TrueHD Atmos route already delivers (`PCMBedPacker`).
///
/// Why not hand the renderer the compressed stream, as macOS does (`SoftwareEAC3Passthrough`):
/// measured on an Apple TV 4K (tvOS 27) over HDMI into a Marantz CINEMA 50, compressed E-AC-3 JOC
/// with its `dec3` cookie plays SILENT on `AVSampleBufferAudioRenderer`. The renderer reports
/// `rendering` with no error and consumes in real time; only the LFE is heard for a moment at the
/// start, and a blip at stop. Each of these alone left it silent: without `AtmosOutputActivator`,
/// without `AtmosDecoderPrimer`, with both off, with 8 output channels preferred instead of 6, and with
/// `allowedAudioSpatializationFormats` empty. The same packets with no cookie (5.1 core) are audible,
/// so is the stream through AVPlayer, and the `dec3` box is byte-identical to the one AVFoundation
/// reads from an mp4 of the same track. The decoder itself is fine on that device: an
/// `ExtAudioFile` read of the track asked for `Atmos_7_1_4` reports the `ec+3` format at 16 channels
/// and returns every channel, heights included (-65 to -67 dB RMS on the four tops of a film scene).
///
/// The converter is opened in the `ec+3` form at 16 channels; the plain `ec-3` form decodes the 5.1
/// core only, whatever the cookie says. On macOS that form exists only once the process has registered
/// the Atmos decoder (`AtmosDecoderPrimer`), so the host opens this after the primer's window.
final class SoftwareEAC3AtmosDecoder: SoftwareAudioProducing, @unchecked Sendable {

    enum OpenError: Error, CustomStringConvertible {
        case noCookie
        case converter(OSStatus)
        case cookie(OSStatus)
        case layout(OSStatus)
        case bedFormat

        var description: String {
            switch self {
            case .noCookie: return "no dec3 cookie"
            case .converter(let s): return "AudioConverterNew \(s)"
            case .cookie(let s): return "decompression cookie \(s)"
            case .layout(let s): return "output channel layout \(s)"
            case .bedFormat: return "no PCM bed format description"
            }
        }
    }

    /// `ec+3`: E-AC-3 with Joint Object Coding, the form AudioToolbox decodes the objects of.
    static let jocFormatID = AudioFormatID(0x6563_2B33)
    static let sampleRate: Double = 48_000
    static let framesPerPacket = 1536
    /// Where the converter's first frame after an open or a reset sits, in frames after the first
    /// packet's stamp. The converter trims its own lead-in and reports none of it (`PrimeInfo` reads 0/0,
    /// `PrimeMethod` is not settable): the first packet yields 63 frames, every later one 1536. Measured
    /// against libavcodec's decode of the same packets (the PCM route, stamped at the packet's PTS) by
    /// cross-correlating L and C on a DD+ JOC programme, macOS 27, at the start and after a reset: the
    /// first frame is source frame 224, r > 0.9999. Without it the bed played 5.3 ms early.
    static let leadingFrameOffset: Int64 = 224
    /// A packet further than this from where the previous one ended moves the run's anchor by the gap.
    static let reanchorThresholdSeconds = 0.1
    /// The converter's "no more input for now" answer from the input callback; not an error.
    private static let needMoreInput: OSStatus = 0x6E6D_6F72  // 'nmor'

    let layout: SpatialSpeakerLayout
    private let channels: Int
    private let bytesPerFrame: Int
    private let bedFormat: CMAudioFormatDescription
    private let timeBase: AVRational
    private let stream: UnsafeMutablePointer<AVStream>
    private var converter: AudioConverterRef?
    private let lock = NSLock()
    private var _feedEpoch: UInt64 = 0
    /// The source time of the first packet since the last flush, and the frames produced since.
    private var anchorSeconds: Double?
    private var producedFrames: Int64 = 0
    /// Where the next packet sits when the container left its stamps out.
    private var nextSeconds: Double?
    private var output: [UInt8]
    private var loggedError = false
    private var tapDecoder: AudioDecoder?
    private var tapOpenFailed = false
    private var closed = false

    /// The packet the input callback hands the converter, one per `decode`.
    private final class Pending {
        var bytes: UnsafeMutableRawPointer?
        var count = 0
        /// Heap storage: the converter reads the description through the pointer the callback hands it,
        /// after the callback has returned, so it may not point into a temporary.
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        var consumed = true
        /// Set for the end-of-stream drain: the callback then reports the end, which releases the tail.
        var atEnd = false

        init() { description.initialize(to: AudioStreamPacketDescription()) }
        deinit { description.deallocate() }
    }
    private let pending = Pending()

    init(stream: UnsafeMutablePointer<AVStream>, entry: SoftwareEAC3Passthrough.Entry,
         layout: SpatialSpeakerLayout) throws {
        var cookieSize = 0
        guard let cookie = CMAudioFormatDescriptionGetMagicCookie(entry.formatDescription, sizeOut: &cookieSize),
              cookieSize > 0 else { throw OpenError.noCookie }
        guard let bed = PCMBedPacker.formatDescription(layout: layout, sampleRate: Int(Self.sampleRate)) else {
            throw OpenError.bedFormat
        }
        var input = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: Self.jocFormatID, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 16,
            mBitsPerChannel: 0, mReserved: 0)
        var out = CMAudioFormatDescriptionGetStreamBasicDescription(bed)!.pointee
        var made: AudioConverterRef?
        let status = AudioConverterNew(&input, &out, &made)
        guard status == noErr, let made else { throw OpenError.converter(status) }
        let cookieStatus = AudioConverterSetProperty(
            made, kAudioConverterDecompressionMagicCookie, UInt32(cookieSize), cookie)
        guard cookieStatus == noErr else { AudioConverterDispose(made); throw OpenError.cookie(cookieStatus) }
        var acl = AudioChannelLayout()
        acl.mChannelLayoutTag = layout.channelLayoutTag
        let layoutStatus = AudioConverterSetProperty(
            made, kAudioConverterOutputChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &acl)
        guard layoutStatus == noErr else { AudioConverterDispose(made); throw OpenError.layout(layoutStatus) }
        self.layout = layout
        self.channels = layout.channelCount
        self.bytesPerFrame = Int(out.mBytesPerFrame)
        self.bedFormat = bed
        self.timeBase = stream.pointee.time_base
        self.stream = stream
        self.converter = made
        self.output = [UInt8](repeating: 0, count: Self.framesPerPacket * 2 * Int(out.mBytesPerFrame))
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    var feedEpoch: UInt64 { lock.withLock { _feedEpoch } }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        lock.withLock { feed(packet) }
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64) -> [CMSampleBuffer] {
        lock.withLock { epoch == _feedEpoch ? feed(packet) : [] }
    }

    /// Caller holds `lock`.
    private func feed(_ packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        guard let converter, let data = packet.pointee.data, packet.pointee.size > 0 else { return [] }
        let tb = timeBase
        let ticks = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        let seconds: Double
        if ticks != Int64.min, tb.den > 0 {
            seconds = Double(ticks) * Double(tb.num) / Double(tb.den)
        } else if let next = nextSeconds {
            seconds = next
        } else {
            return []
        }
        if let expected = nextSeconds, let anchor = anchorSeconds,
           abs(seconds - expected) > Self.reanchorThresholdSeconds {
            // The stamps run from one anchor, so a jump in the source (a splice, a lost packet) would
            // otherwise shift every later buffer against the picture by the size of the jump.
            anchorSeconds = anchor + (seconds - expected)
        }
        nextSeconds = seconds + Double(Self.framesPerPacket) / Self.sampleRate
        if anchorSeconds == nil {
            anchorSeconds = seconds
            producedFrames = 0
        }
        pending.bytes = UnsafeMutableRawPointer(data)
        pending.count = Int(packet.pointee.size)
        pending.description.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.pointee.size))
        pending.consumed = false
        defer { pending.bytes = nil }
        return drain(converter)
    }

    /// Pulls everything the converter can produce from the pending packet. Caller holds `lock`.
    private func drain(_ converter: AudioConverterRef) -> [CMSampleBuffer] {
        var buffers: [CMSampleBuffer] = []
        while true {
            let capacity = output.count / bytesPerFrame
            var frames = UInt32(capacity)
            let status: OSStatus = output.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(
                    converter, Self.supplyInput, Unmanaged.passUnretained(pending).toOpaque(),
                    &frames, &list, nil)
            }
            if frames > 0, let buffer = makeBuffer(frames: Int(frames)) { buffers.append(buffer) }
            if status == Self.needMoreInput || status == noErr && frames == 0 { break }
            if status != noErr {
                if !loggedError {
                    loggedError = true
                    EngineLog.emit("[SWHost] ERROR: E-AC-3 JOC decode failed (\(status)); later ones are not logged",
                                   category: .swPlayback)
                }
                break
            }
            if frames < UInt32(capacity) && pending.consumed { break }
        }
        return buffers
    }

    private static let supplyInput: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, ioDescription, user in
        let pending = Unmanaged<Pending>.fromOpaque(user!).takeUnretainedValue()
        guard !pending.consumed, let bytes = pending.bytes else {
            ioPackets.pointee = 0
            return pending.atEnd ? noErr : SoftwareEAC3AtmosDecoder.needMoreInput
        }
        pending.consumed = true
        ioPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = bytes
        ioData.pointee.mBuffers.mDataByteSize = UInt32(pending.count)
        ioData.pointee.mBuffers.mNumberChannels = 0
        ioDescription?.pointee = pending.description
        return noErr
    }

    /// `frames` of the output buffer as one PCM sample buffer, stamped from the run's anchor.
    private func makeBuffer(frames: Int) -> CMSampleBuffer? {
        guard let anchor = anchorSeconds else { return nil }
        let seconds = anchor + Double(producedFrames + Self.leadingFrameOffset) / Self.sampleRate
        producedFrames += Int64(frames)
        let count = frames * bytesPerFrame
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = output.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: bedFormat,
            sampleCount: frames, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 90_000),
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// The decoder's last frames once the source has ended.
    func endOfStream() -> [CMSampleBuffer] {
        lock.withLock {
            guard let converter else { return [] }
            pending.bytes = nil
            pending.consumed = true
            pending.atEnd = true
            defer { pending.atEnd = false }
            return drain(converter)
        }
    }

    func flush() {
        lock.withLock {
            _feedEpoch &+= 1
            if let converter { AudioConverterReset(converter) }
            anchorSeconds = nil
            producedFrames = 0
            nextSeconds = nil
            pending.bytes = nil
            pending.consumed = true
        }
        let tap = lock.withLock { tapDecoder }
        tap?.flush()
    }

    func close() {
        let tap: AudioDecoder? = lock.withLock {
            closed = true
            if let converter { AudioConverterDispose(converter) }
            converter = nil
            let tap = tapDecoder
            tapDecoder = nil
            return tap
        }
        tap?.close()
    }

    /// PCM for the audio tap, which wants the source's own channels: the 5.1 core, decoded by libavcodec.
    func tapBuffers(for packet: UnsafeMutablePointer<AVPacket>, produced: [CMSampleBuffer]) -> [CMSampleBuffer] {
        let tap: AudioDecoder? = lock.withLock {
            if tapDecoder == nil, !tapOpenFailed, !closed {
                let decoder = AudioDecoder()
                if (try? decoder.open(stream: stream)) != nil { tapDecoder = decoder } else { tapOpenFailed = true }
            }
            return tapDecoder
        }
        return tap?.decode(packet: packet) ?? []
    }
}
