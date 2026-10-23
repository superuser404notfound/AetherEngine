import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// E-AC-3 JOC for the software host: the packets go to `AVSampleBufferAudioRenderer` compressed,
/// the way the AVPlayer route stream-copies them into its fMP4, so the system's Atmos decoder gets
/// the whole stream (core and objects) instead of libavcodec's 5.1 core.
///
/// The renderer decides what to decode from the format description, and for E-AC-3 it reads the
/// JOC signal out of the `dec3` sample-entry box in the magic cookie. A format description built
/// from the bare stream description (no cookie) decodes as 5.1 even after the Atmos decoder is
/// registered (`AtmosDecoderPrimer`). Neither FFmpeg's demuxers nor Matroska hand the box over, so
/// it is built the way the engine's own muxer builds it: one real packet through FFmpeg's mp4
/// muxer, and the box read back out of the result.
final class SoftwareEAC3Passthrough: SoftwareAudioProducing, @unchecked Sendable {

    /// What a first look at the stream's packets found.
    struct Entry {
        let formatDescription: CMAudioFormatDescription
        let carriesJOC: Bool
    }

    /// What looking at the stream's first packets found.
    enum Probe {
        case notEAC3
        /// No audio packet of the stream turned up in the packets looked at.
        case noAudioPacket
        /// The look ran out of its byte budget before an audio packet showed up.
        case budgetExhausted
        /// Audio packets were there but no `dec3` box could be built from them.
        case dec3BuildFailed
        case found(Entry)

        var entry: Entry? {
            if case .found(let entry) = self { return entry }
            return nil
        }

        /// Why the stream stays on the PCM decode, for the log.
        func pcmReason(channels: Int32) -> String {
            switch self {
            case .notEAC3: return "not E-AC-3"
            case .noAudioPacket: return "no audio packet in the first packets"
            case .budgetExhausted: return "the look at the stream ran out of its byte budget"
            case .dec3BuildFailed: return "the dec3 box could not be built from the first packets"
            case .found(let entry):
                return entry.carriesJOC ? "JOC, but \(channels) channels is not the 5.1 bed"
                                        : "no JOC in the dec3 box"
            }
        }
    }

    private static let framesPerPacket: Int64 = 1536
    private static let sampleRate: Double = 48_000

    private let formatDescription: CMAudioFormatDescription
    private let timeBase: AVRational
    private let stream: UnsafeMutablePointer<AVStream>
    /// Decodes for the audio tap only: `decode` itself never runs it. Opened on the first tap, since
    /// most sessions never tap, and under the lock because the tap runs on the demux thread while
    /// `close` can come from the main actor.
    private var tapDecoder: AudioDecoder?
    private var tapOpenFailed = false
    private var closed = false
    private let lock = NSLock()
    /// Where the next packet sits when the container left its stamps out.
    private var nextSeconds: Double?

    init(stream: UnsafeMutablePointer<AVStream>, formatDescription: CMAudioFormatDescription) throws {
        self.formatDescription = formatDescription
        self.timeBase = stream.pointee.time_base
        self.stream = stream
    }

    // MARK: - Format description

    /// The format description for a stream whose first packet is `packet`, and whether that packet
    /// carries the JOC flag. Nil when the box cannot be built, which keeps the PCM decode.
    static func entry(
        codecpar: UnsafePointer<AVCodecParameters>, packet: UnsafePointer<AVPacket>
    ) -> Entry? {
        guard let box = dec3Box(codecpar: codecpar, packet: packet),
              let description = formatDescription(dec3Box: box) else { return nil }
        return Entry(formatDescription: description,
                     carriesJOC: RemoteHLSStreamDescription.eac3CarriesJOC(dec3: box))
    }

    /// The description is fixed at 6 channels, 48 kHz and 1536 frames a packet on purpose: JOC is
    /// carried in a 5.1 E-AC-3 bed at that rate and frame size, `SoftwareAtmosRoute` admits nothing
    /// else, and the renderer takes the object layout from the `dec3` cookie rather than from here.
    static func formatDescription(dec3Box: Data) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatEnhancedAC3, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: 6, mBitsPerChannel: 0, mReserved: 0)
        // The AC-3 channel order, which is the one the decoder delivers.
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_C
        var description: CMAudioFormatDescription?
        let status = dec3Box.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                magicCookieSize: cookie.count, magicCookie: cookie.baseAddress,
                extensions: nil, formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    /// The `dec3` box FFmpeg's mp4 muxer writes for a stream, size and type included, which is the
    /// form AVFoundation's own format descriptions carry as their magic cookie.
    static func dec3Box(codecpar: UnsafePointer<AVCodecParameters>, packet: UnsafePointer<AVPacket>) -> Data? {
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&ctxOut, nil, "mp4", "dec3.mp4") == 0, let ctx = ctxOut else { return nil }
        defer { avformat_free_context(ctx) }
        var pb: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&pb) >= 0, let pbCtx = pb else { return nil }
        ctx.pointee.pb = pbCtx
        let written = muxOnePacket(ctx: ctx, codecpar: codecpar, packet: packet)
        var bytes: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(pbCtx, &bytes)
        defer { if bytes != nil { av_free(bytes) } }
        guard written, size > 8, let bytes else { return nil }
        return findBox("dec3", in: UnsafeBufferPointer(start: bytes, count: Int(size)))
    }

    private static func muxOnePacket(
        ctx: UnsafeMutablePointer<AVFormatContext>,
        codecpar: UnsafePointer<AVCodecParameters>, packet: UnsafePointer<AVPacket>
    ) -> Bool {
        guard let stream = avformat_new_stream(ctx, nil),
              avcodec_parameters_copy(stream.pointee.codecpar, codecpar) >= 0 else { return false }
        stream.pointee.codecpar.pointee.codec_tag = 0
        stream.pointee.time_base = AVRational(num: 1, den: Int32(sampleRate))
        guard avformat_write_header(ctx, nil) >= 0 else { return false }
        var cloned: UnsafeMutablePointer<AVPacket>? = av_packet_clone(packet)
        defer { av_packet_free(&cloned) }
        guard let copy = cloned else { return false }
        copy.pointee.stream_index = 0
        copy.pointee.pts = 0
        copy.pointee.dts = 0
        copy.pointee.duration = framesPerPacket
        guard av_write_frame(ctx, copy) >= 0 else { return false }
        return av_write_trailer(ctx) >= 0
    }

    /// The first box of `type` inside the `moov` box of an ISO BMFF byte run, found by its
    /// four-character code, checked against the size in front of it and returned whole. Looking only
    /// inside `moov` keeps payload bytes that happen to spell the code from being taken for a box.
    static func findBox(_ type: String, in bytes: UnsafeBufferPointer<UInt8>) -> Data? {
        let code = Array(type.utf8)
        guard code.count == 4, let moov = topLevelPayload("moov", in: bytes) else { return nil }
        var i = moov.lowerBound + 4
        while i + 4 <= moov.upperBound {
            if Array(bytes[i..<(i + 4)]) == code {
                let start = i - 4
                let size = Int(boxSize(bytes, at: start))
                if size >= 8, start >= moov.lowerBound, start + size <= moov.upperBound {
                    return Data(bytes[start..<(start + size)])
                }
            }
            i += 1
        }
        return nil
    }

    private static func boxSize(_ bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> UInt32 {
        (UInt32(bytes[i]) << 24) | (UInt32(bytes[i + 1]) << 16) | (UInt32(bytes[i + 2]) << 8) | UInt32(bytes[i + 3])
    }

    /// The payload range of the first top-level box of `type`.
    private static func topLevelPayload(_ type: String, in bytes: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        let code = Array(type.utf8)
        var i = 0
        while i + 8 <= bytes.count {
            let size32 = boxSize(bytes, at: i)
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard i + 16 <= bytes.count else { return nil }
                size = 0
                for k in 8..<16 { size = (size << 8) | Int(bytes[i + k]) }
                header = 16
            } else if size32 == 0 {
                size = bytes.count - i
            }
            guard size >= header, i + size <= bytes.count else { return nil }
            if Array(bytes[(i + 4)..<(i + 8)]) == code { return (i + header)..<(i + size) }
            i += size
        }
        return nil
    }

    // MARK: - SoftwareAudioProducing

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return [] }
        let tb = timeBase
        let ticks = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        let seconds: Double
        lock.lock()
        if ticks != Int64.min, tb.den > 0 {
            seconds = Double(ticks) * Double(tb.num) / Double(tb.den)
        } else if let next = nextSeconds {
            seconds = next
        } else {
            lock.unlock()
            return []
        }
        nextSeconds = seconds + Double(Self.framesPerPacket) / Self.sampleRate
        lock.unlock()
        guard let buffer = Self.sampleBuffer(
            bytes: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
            seconds: seconds, formatDescription: formatDescription) else { return [] }
        return [buffer]
    }

    /// One compressed packet as a sample buffer of one sample. The bytes are copied: the packet is
    /// freed by the demux loop as soon as `decode` returns.
    static func sampleBuffer(
        bytes: UnsafeRawBufferPointer, seconds: Double, formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: bytes.count) == noErr else { return nil }
        var description = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 90_000),
            packetDescriptions: &description, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    func flush() {
        lock.lock()
        nextSeconds = nil
        let tap = tapDecoder
        lock.unlock()
        tap?.flush()
    }

    func close() {
        lock.lock()
        closed = true
        let tap = tapDecoder
        tapDecoder = nil
        lock.unlock()
        tap?.close()
    }

    func tapBuffers(for packet: UnsafeMutablePointer<AVPacket>, produced: [CMSampleBuffer]) -> [CMSampleBuffer] {
        lock.lock()
        if tapDecoder == nil, !tapOpenFailed, !closed {
            let decoder = AudioDecoder()
            if (try? decoder.open(stream: stream)) != nil { tapDecoder = decoder } else { tapOpenFailed = true }
        }
        let tap = tapDecoder
        lock.unlock()
        return tap?.decode(packet: packet) ?? []
    }
}
