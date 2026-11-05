// Only with the DTSXObjectAudio trait (off by default).
#if DTSXObjectAudio
import Foundation
import AetherLibavcodec
import AetherLibavutil

/// DTS:X decoder over FFmpeg's own `dca` decoder: lossless decode of the DTS-HD Master Audio stream
/// DTS:X is carried on, in its standard presentation only. The standard presentation carries its four
/// heights in a regular XLL channel set at the end of every frame, and the encoder folds each of them at
/// -3 dB into the bed speaker under it. FFmpegBuild's `x_heights` option (a local patch, #798) decodes
/// that channel set and outputs it next to the bed as coded, heights still folded in. The alternate
/// presentations, which carry objects, keep their plain 7.1 and are refused here.
///
/// Every block hands over that bed with the four heights as its elements and their folds, and every
/// output is built from the bed alone (`BedRegression`): the heights steer it, as statistics, and never
/// play themselves. Each of the twelve channels has its own speaker in a 7.1.4 or 9.1.6 layout.
final class DTSXObjectAudioDecoder: ObjectAudioDecoding {

    struct DecoderError: Error, CustomStringConvertible {
        let message: String
        var description: String { "DTSXObjectAudioDecoder: \(message)" }
    }

    /// What the first frames of a stream showed (see `verdict(feeding:)`).
    enum Verdict: Equatable {
        /// DTS:X the decoder renders, named by its layout ("7.1.4").
        case renders(String)
        /// Not DTS:X, or DTS:X in a presentation this decoder does not render; the message says which.
        case refused(String)
    }

    /// The standard presentation's channels in the order every block carries them, whatever the frame
    /// had: the 7.1 bed, then the top front and top back pairs.
    static let channels: [(AVChannel, ObjectAudioRole)] = [
        (AV_CHAN_FRONT_CENTER, .bed(.center)), (AV_CHAN_FRONT_LEFT, .bed(.left)),
        (AV_CHAN_FRONT_RIGHT, .bed(.right)), (AV_CHAN_SIDE_LEFT, .bed(.sideLeft)),
        (AV_CHAN_SIDE_RIGHT, .bed(.sideRight)), (AV_CHAN_LOW_FREQUENCY, .lfe),
        (AV_CHAN_BACK_LEFT, .bed(.rearLeft)), (AV_CHAN_BACK_RIGHT, .bed(.rearRight)),
        (AV_CHAN_TOP_FRONT_LEFT, .bed(.topFrontLeft)), (AV_CHAN_TOP_FRONT_RIGHT, .bed(.topFrontRight)),
        (AV_CHAN_TOP_BACK_LEFT, .bed(.topRearLeft)), (AV_CHAN_TOP_BACK_RIGHT, .bed(.topRearRight)),
    ]
    /// The first eight channels, the 7.1 bed as coded.
    static let bedCount = 8
    static let bedRoles = channels.prefix(bedCount).map(\.1)
    /// The four heights, a block's elements.
    static let roles = channels.dropFirst(bedCount).map(\.1)
    /// The encoder's fold of each height into the bed: front heights into L and R, rear heights into
    /// the rear surrounds, at gain code 23170/32768 (-3 dB). The same in every frame of all 12 DTS:X
    /// tracks measured (8.76 million frames), so it is the format's, not read from the stream.
    static let folds: [ObjectAudioBedFold] = [
        (SpatialSpeaker.topFrontLeft, SpatialSpeaker.left), (.topFrontRight, .right),
        (.topRearLeft, .rearLeft), (.topRearRight, .rearRight),
    ].map { height, speaker in
        ObjectAudioBedFold(element: roles.firstIndex(of: .bed(height))!,
                           plane: bedRoles.firstIndex(of: .bed(speaker))!,
                           gain: 23170 / 32768)
    }

    /// Frames decoded after a reset only to rebuild the core's filter history, which the lossless
    /// residual is coded against. Entered mid-stream, the first frame reconstructs as distorted audio
    /// and the second can still err by -16 dBFS (measured with LibDTSX over 110 seeks into four DTS:X
    /// streams); from the third the error decays to bit-exact within about ten frames.
    static let primingFrames = 2
    /// Decoded frames without heights after which `verdict(feeding:)` refuses a stream.
    static let verdictFrames = 8

    private struct Pending {
        var samples: UnsafeMutablePointer<Float>
        var frameCount: Int
        var inputFrameOffset: Int64
        var isDiscontinuity: Bool
    }

    private let context: UnsafeMutablePointer<AVCodecContext>
    private var parser: UnsafeMutablePointer<AVCodecParserContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    private var pending: [Pending] = []
    private var lent: UnsafeMutablePointer<Float>?
    private var planes: [UnsafePointer<Float>] = []
    private var bedPlanes: [UnsafePointer<Float>] = []
    /// Frames of input taken since the last reset, decoded or not.
    private var inputFrames: Int64 = 0
    private var priming = primingFrames
    private var discontinuity = true
    /// Samples in the last frame that decoded, for one that did not.
    private var nominalFrames = 512
    private var framesWithoutHeights = 0

    init() throws {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_DTS),
              let context = avcodec_alloc_context3(codec) else {
            throw DecoderError(message: "no dca decoder in this FFmpeg")
        }
        var options: OpaquePointer?
        av_dict_set(&options, "x_heights", "1", 0)
        let opened = avcodec_open2(context, codec, &options)
        // An option the decoder does not know stays in the dictionary: an FFmpegBuild without the patch.
        let unknown = av_dict_get(options, "x_heights", nil, 0) != nil
        av_dict_free(&options)
        var parser = av_parser_init(Int32(AV_CODEC_ID_DTS.rawValue))
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        guard opened >= 0, !unknown, let parser, let packet, let frame else {
            if let parser { av_parser_close(parser) }
            av_packet_free(&packet)
            av_frame_free(&frame)
            var owned: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&owned)
            throw DecoderError(message: unknown
                ? "this FFmpegBuild cannot decode DTS:X heights (no x_heights option)"
                : "dca decoder did not open (\(FFmpegErr.text(for: opened)))")
        }
        self.context = context
        self.parser = parser
        self.packet = packet
        self.frame = frame
    }

    deinit {
        dropPending()
        av_parser_close(parser)
        var packet: UnsafeMutablePointer<AVPacket>? = self.packet
        av_packet_free(&packet)
        var frame: UnsafeMutablePointer<AVFrame>? = self.frame
        av_frame_free(&frame)
        var context: UnsafeMutablePointer<AVCodecContext>? = self.context
        avcodec_free_context(&context)
    }

    /// Feeds packets from the head of a stream and reports what its decoded frames are, or nil while
    /// that is undecided. The probe's profile label rests on the frames it read, so only a decoded
    /// frame tells: a stream renders once one comes out as 7.1.4. One that does not is refused after
    /// `verdictFrames` of them, since a stream entered inside a peak-bit-rate smoothing period
    /// decodes its first frames from the lossy core alone.
    func verdict(feeding bytes: UnsafeRawBufferPointer) -> Verdict? {
        var verdict: Verdict?
        do {
            try parse(bytes) { [self] in
                guard verdict == nil else { return }
                guard frame.pointee.sample_rate == Int32(ObjectAudioRendering.sampleRate) else {
                    verdict = .refused("\(frame.pointee.sample_rate) Hz")
                    return
                }
                if (8..<12).allSatisfy({ carries(Self.channels[$0].0) }) {
                    verdict = .renders("7.1.4")
                } else {
                    framesWithoutHeights += 1
                    if framesWithoutHeights >= Self.verdictFrames { verdict = .refused(presentationText) }
                }
            }
        } catch {
            return .refused("\(error)")
        }
        return verdict
    }

    func push(_ bytes: UnsafeRawBufferPointer) throws {
        releaseLent()
        try parse(bytes) { [self] in try takeFrame() }
    }

    func nextBlock() throws -> ObjectAudioDecodedBlock? {
        releaseLent()
        guard !pending.isEmpty else { return nil }
        let block = pending.removeFirst()
        lent = block.samples
        planes.removeAll(keepingCapacity: true)
        bedPlanes.removeAll(keepingCapacity: true)
        for c in 0..<Self.channels.count {
            let plane = UnsafePointer(block.samples + c * block.frameCount)
            if c < Self.bedCount { bedPlanes.append(plane) } else { planes.append(plane) }
        }
        // Every height sits on its speaker at unity. The placement holds an element nowhere until its
        // first state, so the whole set is restated, as a jump, wherever the decoder started over.
        var updates: [ObjectAudioMetadataUpdate] = []
        if block.isDiscontinuity {
            updates.append(ObjectAudioMetadataUpdate(
                frameOffset: 0, states: Self.roles.map(Self.state(for:))))
        }
        return ObjectAudioDecodedBlock(
            sampleRate: ObjectAudioRendering.sampleRate,
            frameCount: block.frameCount,
            inputFrameOffset: block.inputFrameOffset,
            configurationGeneration: 1,
            isDiscontinuity: block.isDiscontinuity,
            roles: Self.roles,
            planes: planes,
            updates: updates,
            bed: ObjectAudioBed(roles: Self.bedRoles, planes: bedPlanes, folds: Self.folds))
    }


    func reset() {
        dropPending()
        avcodec_flush_buffers(context)
        av_parser_close(parser)
        parser = av_parser_init(Int32(AV_CODEC_ID_DTS.rawValue))!
        inputFrames = 0
        priming = Self.primingFrames
        discontinuity = true
        framesWithoutHeights = 0
    }

    /// The parser holds the last frame until the next one's syncword shows where it ends; this hands
    /// it to the decoder now. A new parser takes the input that follows.
    func releaseHeldBlocks() {
        releaseLent()
        try? parse(nil) { [self] in try takeFrame() }
        av_parser_close(parser)
        parser = av_parser_init(Int32(AV_CODEC_ID_DTS.rawValue))!
    }

    // MARK: - Decoding

    /// Splits `bytes` into frames, decodes each and calls `onFrame` with every decoded frame in
    /// `frame`. A frame that does not decode still counts towards the input offsets. Nil flushes the
    /// frame the parser holds.
    private func parse(_ bytes: UnsafeRawBufferPointer?, onFrame: () throws -> Void) throws {
        var data = bytes?.baseAddress?.assumingMemoryBound(to: UInt8.self)
        var remaining = Int32(bytes?.count ?? 0)
        repeat {
            var out: UnsafeMutablePointer<UInt8>?
            var outSize: Int32 = 0
            let used = av_parser_parse2(parser, context, &out, &outSize, data, remaining,
                                        Int64.min, Int64.min, 0)
            guard used >= 0 else { throw DecoderError(message: "parser: \(FFmpegErr.text(for: used))") }
            data = data.map { $0 + Int(used) }
            remaining -= used
            if let out, outSize > 0 {
                try decode(out, outSize, onFrame: onFrame)
            } else if used == 0 {
                break
            }
        } while remaining > 0
    }

    private func decode(_ data: UnsafeMutablePointer<UInt8>, _ size: Int32, onFrame: () throws -> Void) throws {
        packet.pointee.data = data
        packet.pointee.size = size
        defer { packet.pointee.data = nil; packet.pointee.size = 0 }
        let parsedFrames = parser.pointee.duration > 0 ? Int(parser.pointee.duration) : nominalFrames
        guard avcodec_send_packet(context, packet) >= 0 else {
            // EINVAL and INVALIDDATA reject this frame and leave the decoder usable for the next (#64).
            skip(frames: parsedFrames)
            return
        }
        var decodedAny = false
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            decodedAny = true
            nominalFrames = Int(frame.pointee.nb_samples)
            try onFrame()
        }
        if !decodedAny { skip(frames: parsedFrames) }
    }

    private func skip(frames: Int) {
        inputFrames += Int64(frames)
        discontinuity = true
    }

    /// Converts the decoded frame into the block layout, or counts it as priming.
    private func takeFrame() throws {
        let frames = Int(frame.pointee.nb_samples)
        let offset = inputFrames
        inputFrames += Int64(frames)
        guard frames > 0 else { return }
        if priming > 0 {
            priming -= 1
            return
        }
        guard frame.pointee.sample_rate == Int32(ObjectAudioRendering.sampleRate) else {
            throw DecoderError(message: "\(frame.pointee.sample_rate) Hz frame")
        }
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames * Self.channels.count)
        samples.initialize(repeating: 0, count: frames * Self.channels.count)
        var layout = frame.pointee.ch_layout
        for index in 0..<Int(layout.nb_channels) {
            let channel = av_channel_layout_channel_from_index(&layout, UInt32(index))
            guard let slot = Self.channels.firstIndex(where: { $0.0 == channel }) else {
                samples.deallocate()
                throw DecoderError(message: "channel \(channel.rawValue) outside DTS:X's 7.1.4")
            }
            guard let source = frame.pointee.extended_data[index] else { continue }
            let target = samples + slot * frames
            switch AVSampleFormat(rawValue: frame.pointee.format) {
            case AV_SAMPLE_FMT_S32P:
                let input = UnsafeRawPointer(source).assumingMemoryBound(to: Int32.self)
                for n in 0..<frames { target[n] = Float(input[n]) * (1.0 / 2_147_483_648.0) }
            case AV_SAMPLE_FMT_S16P:
                let input = UnsafeRawPointer(source).assumingMemoryBound(to: Int16.self)
                for n in 0..<frames { target[n] = Float(input[n]) * (1.0 / 32_768.0) }
            case AV_SAMPLE_FMT_FLTP:
                target.update(from: UnsafeRawPointer(source).assumingMemoryBound(to: Float.self), count: frames)
            default:
                samples.deallocate()
                throw DecoderError(message: "sample format \(frame.pointee.format)")
            }
        }
        pending.append(Pending(samples: samples, frameCount: frames, inputFrameOffset: offset,
                               isDiscontinuity: discontinuity))
        discontinuity = false
    }

    private func carries(_ channel: AVChannel) -> Bool {
        var layout = frame.pointee.ch_layout
        return av_channel_layout_index_from_channel(&layout, channel) >= 0
    }

    /// Why a decoded frame without heights is not rendered, from FFmpeg's profile.
    private var presentationText: String {
        switch context.pointee.profile {
        case AV_PROFILE_DTS_HD_MA_X_IMAX:
            return "DTS:X in a presentation with objects, which plays as its 7.1 bed"
        case AV_PROFILE_DTS_HD_MA_X:
            return "DTS:X whose heights did not decode"
        default:
            return "no DTS:X extension in the standard presentation, \(frame.pointee.ch_layout.nb_channels) channels"
        }
    }

    private func releaseLent() {
        lent?.deallocate()
        lent = nil
    }

    private func dropPending() {
        releaseLent()
        for block in pending { block.samples.deallocate() }
        pending.removeAll()
    }

    // MARK: - Mapping

    /// A channel's element: its speaker's position, playing at unity.
    static func state(for role: ObjectAudioRole) -> ObjectAudioElementState {
        if case .bed(let speaker) = role { return ObjectAudioElementState(position: speaker.position, gain: 1) }
        return ObjectAudioElementState(gain: 1)
    }
}
#endif
