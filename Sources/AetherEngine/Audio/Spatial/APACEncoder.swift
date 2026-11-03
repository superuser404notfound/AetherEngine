import AVFAudio
import CoreMedia
import AudioToolbox
import Foundation

/// Apple Positional Audio Codec encoder over `AVAudioConverter`, fed planar float PCM in a
/// `SpatialSpeakerLayout` bed and producing packets for the fMP4 muxer.
///
/// APAC is the carrier because it is the one codec tvOS decodes that holds more than eight
/// channels AND reaches the receiver as Atmos: FLAC and ALAC stop at 7.1, E-AC-3 JOC needs an
/// encoder no Apple SDK ships, and the system renders APAC to Dolby MAT on an Atmos route the same
/// way it renders its own spatial content. Measured on the tvOS 27 simulator: 7.1.4 and 9.1.6
/// both encode, and AVPlayer plays the result over HLS with `CODECS="apac.31.LL"`.
///
/// Facts about the encoder this relies on, all measured on macOS 27 and the tvOS 27 simulator:
/// - packets are 1024 frames;
/// - the encoder primes 2048 frames (`primeInfo.leadingFrames`). AVFoundation removes them on
///   playback by presenting each packet's audio 2048 frames before its timestamp, so the caller
///   keeps the priming packets and stamps them from the anchor;
/// - with the converter's defaults every packet is independently decodable (an Audio Sync Packet),
///   which is what lets any fMP4 fragment, and so any HLS segment, start on one (HLS authoring 7.9);
/// - the magic cookie IS the complete `dapa` box the sample entry carries;
/// - the encoder's latency is set by its dynamic range control (DRC) analysis. With DRC off it
///   holds only the 2048 priming frames; the `.capture` default holds ~1.56 s (74,752 frames) and
///   `.movie` more than 5 s before its first packet. A multi-second lookahead would leave the first
///   segment after every seek without audio, so DRC is off and the stream carries no DRC metadata.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class APACEncoder {

    struct Packet {
        let data: Data
        /// Independently decodable (an APAC Audio Sync Packet).
        let isSync: Bool
    }

    enum EncoderError: Error, CustomStringConvertible {
        case formatUnavailable(SpatialSpeakerLayout)
        case converterUnavailable(SpatialSpeakerLayout)
        case convertFailed(String)
        case encodeAfterFlush

        var description: String {
            switch self {
            case .formatUnavailable(let l): return "APACEncoder: no APAC output format for \(l.rawValue)"
            case .converterUnavailable(let l): return "APACEncoder: this OS has no APAC encoder for \(l.rawValue)"
            case .convertFailed(let why): return "APACEncoder: convert failed (\(why))"
            case .encodeAfterFlush: return "APACEncoder: encode after flush (reset first)"
            }
        }
    }

    static let framesPerPacket = 1024

    let layout: SpatialSpeakerLayout
    let sampleRate: Double
    /// The complete `dapa` box, ready to append to an `apac` sample entry.
    let magicCookie: Data
    /// Frames of encoder delay at the head of the stream (and again after every `reset`).
    let leadingFrames: Int
    /// The packets' format as a sample-buffer format description, for a renderer fed the packets directly.
    /// It carries the `dapa` cookie and 1024 frames per packet: the encoder's own output format has
    /// neither, and a renderer given that cannot configure its decoder. It then fails every packet
    /// inside, while its status stays `rendering` and its error stays nil, so the output is silent
    /// and nothing says so.
    let formatDescription: CMAudioFormatDescription

    private let pcmFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    /// Reused by every `drain`: at 16 × `maximumOutputPacketSize` it is 393 KB for 7.1.4.
    private let outputBuffer: AVAudioCompressedBuffer
    private var ended = false

    /// `bitRate` is the target in bits per second. Apple's HLS table recommends 384 kbps for 7.1,
    /// but the source here is lossless and the bed carries height channels, so the caller asks for
    /// considerably more (a few Mbit/s, still a fraction of TrueHD's own rate).
    init(layout: SpatialSpeakerLayout, sampleRate: Double = 48_000, bitRate: Int, maxInputFrames: Int = 8192) throws {
        self.layout = layout
        self.sampleRate = sampleRate
        let channelLayout = AVAudioChannelLayout(layoutTag: layout.channelLayoutTag)!
        pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                  interleaved: false, channelLayout: channelLayout)
        var acl = AudioChannelLayout()
        acl.mChannelLayoutTag = layout.channelLayoutTag
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAPAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: layout.channelCount,
            AVChannelLayoutKey: Data(bytes: &acl, count: MemoryLayout<AudioChannelLayout>.size),
            AVEncoderBitRateKey: bitRate,
        ]
        guard let apac = AVAudioFormat(settings: settings) else { throw EncoderError.formatUnavailable(layout) }
        guard let conv = AVAudioConverter(from: pcmFormat, to: apac) else {
            throw EncoderError.converterUnavailable(layout)
        }
        conv.bitRate = bitRate
        // Film/TV mastered offline, which is what a TrueHD Atmos track is.
        conv.contentSource = .appleAV_Spatial_Offline
        conv.dynamicRangeControlConfiguration = .none
        converter = conv
        guard let cookie = conv.magicCookie, !cookie.isEmpty else { throw EncoderError.converterUnavailable(layout) }
        magicCookie = cookie
        leadingFrames = Int(conv.primeInfo.leadingFrames)
        guard let described = Self.cookiedFormatDescription(
            apac: apac, cookie: cookie, layoutTag: layout.channelLayoutTag) else {
            throw EncoderError.converterUnavailable(layout)
        }
        formatDescription = described
        precondition(maxInputFrames > 0, "APACEncoder needs room for at least one input frame")
        inputBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(maxInputFrames))!
        outputBuffer = AVAudioCompressedBuffer(
            format: apac, packetCapacity: 16, maximumPacketSize: max(conv.maximumOutputPacketSize, 1))
    }

    /// The APAC format description with a magic cookie and a packet size, which is what a decoder
    /// needs to start. Pure, so the tests can build it without playing anything.
    static func cookiedFormatDescription(
        apac: AVAudioFormat, cookie: Data, layoutTag: AudioChannelLayoutTag
    ) -> CMAudioFormatDescription? {
        // Without the cookie the description is the one that plays silence.
        guard !cookie.isEmpty else { return nil }
        var asbd = apac.streamDescription.pointee
        if asbd.mFramesPerPacket == 0 { asbd.mFramesPerPacket = UInt32(framesPerPacket) }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = layoutTag
        var description: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                magicCookieSize: bytes.count, magicCookie: bytes.baseAddress,
                extensions: nil, formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    /// Queue `frameCount` frames (one plane per layout channel) and return every packet the encoder
    /// completes. Larger inputs are fed in `maxInputFrames` slices.
    func encode(planes: [UnsafePointer<Float>], frameCount: Int) throws -> [Packet] {
        precondition(planes.count == layout.channelCount)
        // The converter has seen end of stream and would swallow everything fed after it.
        guard !ended else { throw EncoderError.encodeAfterFlush }
        var packets: [Packet] = []
        var offset = 0
        let capacity = Int(inputBuffer.frameCapacity)
        while offset < frameCount {
            let n = min(capacity, frameCount - offset)
            let dst = inputBuffer.floatChannelData!
            for c in 0..<layout.channelCount {
                (dst[c]).update(from: planes[c] + offset, count: n)
            }
            inputBuffer.frameLength = AVAudioFrameCount(n)
            try drain(feeding: inputBuffer, endOfStream: false, into: &packets)
            offset += n
        }
        return packets
    }

    /// Signal end of stream and return the encoder's tail. The encoder is unusable until `reset`.
    func flush() throws -> [Packet] {
        guard !ended else { return [] }
        ended = true
        var packets: [Packet] = []
        try drain(feeding: nil, endOfStream: true, into: &packets)
        return packets
    }

    /// Drop everything buffered. The next packet is an Audio Sync Packet, preceded again by
    /// `leadingFrames` of priming.
    func reset() {
        converter.reset()
        ended = false
    }

    private func drain(feeding input: AVAudioPCMBuffer?, endOfStream: Bool, into packets: inout [Packet]) throws {
        // One borrow spans the whole drain, including another conversion when output fills.
        let pendingInput = APACConverterInput(input)
        defer { pendingInput.clear() }
        let provideInput: @Sendable (AVAudioPacketCount, UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? = {
            _, inputStatus in
            let next = pendingInput.take()
            inputStatus.pointee = next != nil ? .haveData : (endOfStream ? .endOfStream : .noDataNow)
            return next
        }
        let output = outputBuffer
        while true {
            output.packetCount = 0
            output.byteLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: provideInput)
            if status == .error {
                throw EncoderError.convertFailed(error.map { "\($0)" } ?? "status error")
            }
            collect(output, into: &packets)
            // haveData: the output buffer filled and more may be waiting. Anything else means the
            // encoder has emitted all it can from what it was given. A haveData that produced
            // nothing would never change, so it ends the loop too.
            if status != .haveData || output.packetCount == 0 { break }
        }
    }

    private func collect(_ buffer: AVAudioCompressedBuffer, into packets: inout [Packet]) {
        let count = Int(buffer.packetCount)
        guard count > 0, let descriptions = buffer.packetDescriptions else { return }
        let dependencies = buffer.packetDependencies
        let base = buffer.data
        for k in 0..<count {
            let d = descriptions[k]
            let data = Data(bytes: base + Int(d.mStartOffset), count: Int(d.mDataByteSize))
            // No dependency table means a format without dependent packets, where every packet is sync.
            let sync = dependencies.map { $0[k].mIsIndependentlyDecodable != 0 } ?? true
            packets.append(Packet(data: data, isSync: sync))
        }
    }
}
