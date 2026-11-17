import AetherLibavcodec
import Foundation

/// AE#1070: puts the two fields of a field-coded (PAFF) H.264 frame into one packet before the native
/// route muxes it.
///
/// Broadcast 1080i in MPEG-TS often codes each field as a picture of its own, in its own PES, so the
/// demuxer hands out 50 packets a second for 25 frames. Muxed one field per sample, AVPlayer presents
/// every field as a frame of its own, alternating top and bottom, and the picture bounces up and down
/// for as long as it plays (reported on an Apple TV receiving the stream over AirPlay). ISO/IEC 14496-15
/// wants both fields of a frame in one sample, which is what VideoToolbox then decodes into one frame.
///
/// Non-video packets read while looking for the second field are handed out after the joined one, in
/// read order. A field without a partner (a broken pair, a cut at the start of a read) passes on alone.
final class H264FieldPairJoiner {
    /// The identity of a field picture, from its first slice header.
    struct Field: Equatable, Sendable {
        let frameNum: Int
        let bottom: Bool
    }

    /// Non-video packets held while looking for a second field. A TS multiplex puts a few audio packets
    /// between two fields; anything far beyond that is not a field pair.
    static let maxHeldPackets = 64

    private var videoStreamIndex: Int32
    private var context: H264SPS.SliceContext
    private let framing: VideoNALFraming
    private var pending: [UnsafeMutablePointer<AVPacket>] = []
    /// Set when the stream changes under the joiner (an SSAI creative with an SPS of its own): its
    /// slice context no longer describes the packets, so they pass through.
    private var disarmed = false

    private(set) var pairsJoined = 0
    private(set) var unpairedFields = 0

    init(videoStreamIndex: Int32, context: H264SPS.SliceContext, framing: VideoNALFraming) {
        self.videoStreamIndex = videoStreamIndex
        self.context = context
        self.framing = framing
    }

    deinit { reset() }

    /// Armed only for a stream that can code field pictures at all.
    static func make(videoStreamIndex: Int32, codecpar: UnsafePointer<AVCodecParameters>,
                     framing: VideoNALFraming) -> H264FieldPairJoiner? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_H264,
              let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: extradata, count: Int(codecpar.pointee.extradata_size)))
        guard let sps = H264SPS.spsNAL(fromExtradata: bytes),
              let context = H264SPS.sliceContext(fromNAL: sps), !context.frameMbsOnly else { return nil }
        return H264FieldPairJoiner(videoStreamIndex: videoStreamIndex, context: context, framing: framing)
    }

    func reset() {
        for packet in pending {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        pending.removeAll()
    }

    func disarm() { disarmed = true }

    /// The stream changed under the joiner (an SSAI creative, or an in-band SPS change on the same
    /// PID). The new SPS says whether fields still pair: it re-arms the joiner with the new slice
    /// context, or disarms it for a progressive or unreadable one (audit BIT-203).
    func rearm(videoStreamIndex newIndex: Int32, extradata: [UInt8]) {
        if let sps = H264SPS.spsNAL(fromExtradata: extradata),
           let newContext = H264SPS.sliceContext(fromNAL: sps), !newContext.frameMbsOnly {
            videoStreamIndex = newIndex
            context = newContext
            disarmed = false
        } else {
            disarmed = true
        }
    }

    func next(read: () throws -> UnsafeMutablePointer<AVPacket>?) throws -> UnsafeMutablePointer<AVPacket>? {
        let first: UnsafeMutablePointer<AVPacket>
        if !pending.isEmpty {
            first = pending.removeFirst()
        } else {
            guard let packet = try read() else { return nil }
            first = packet
        }
        guard !disarmed, first.pointee.stream_index == videoStreamIndex, let firstField = field(of: first) else {
            return first
        }
        var index = 0
        while true {
            let candidate: UnsafeMutablePointer<AVPacket>
            if index < pending.count {
                candidate = pending[index]
            } else {
                guard pending.count < Self.maxHeldPackets, let packet = try read() else {
                    unpairedFields += 1
                    return first
                }
                pending.append(packet)
                candidate = packet
            }
            guard candidate.pointee.stream_index == videoStreamIndex else {
                index += 1
                continue
            }
            guard let second = field(of: candidate), Self.completesPair(firstField, second) else {
                unpairedFields += 1
                return first
            }
            guard Self.append(candidate, to: first) else {
                unpairedFields += 1
                return first
            }
            pending.remove(at: index)
            var consumed: UnsafeMutablePointer<AVPacket>? = candidate
            trackedPacketFree(&consumed)
            pairsJoined += 1
            return first
        }
    }

    /// The second field of the same frame: same frame_num, the other parity.
    static func completesPair(_ first: Field, _ second: Field) -> Bool {
        first.frameNum == second.frameNum && first.bottom != second.bottom
    }

    private func field(of packet: UnsafeMutablePointer<AVPacket>) -> Field? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let buffer = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
        return Self.field(in: buffer, framing: framing, context: context)
    }

    /// The field identity of the first coded slice in an access unit; nil for a frame picture or a
    /// packet with no parsable slice.
    static func field(in data: UnsafeBufferPointer<UInt8>, framing: VideoNALFraming,
                      context: H264SPS.SliceContext) -> Field? {
        guard !context.frameMbsOnly, let slice = firstSliceNAL(in: data, framing: framing) else { return nil }
        // The header fields read here fit well inside 32 bytes of RBSP.
        let rbsp = H264SPS.unescape(Array(slice.dropFirst().prefix(40)))
        var r = H264SPS.BitReader(rbsp)
        guard r.ue() != nil,                      // first_mb_in_slice
              r.ue() != nil,                      // slice_type
              r.ue() != nil else { return nil }   // pic_parameter_set_id
        if context.separateColourPlane { guard r.u(2) != nil else { return nil } }
        guard let frameNum = r.u(context.log2MaxFrameNum),
              let fieldPic = r.flag(), fieldPic, let bottom = r.flag() else { return nil }
        return Field(frameNum: frameNum, bottom: bottom)
    }

    /// The head of the first NAL of type 1 (non-IDR slice) or 5 (IDR slice), with its header byte. Only
    /// the slice header is read, so the NAL is cut after 48 bytes.
    static func firstSliceNAL(in bytes: UnsafeBufferPointer<UInt8>, framing: VideoNALFraming) -> ArraySlice<UInt8>? {
        func head(_ start: Int, _ end: Int) -> ArraySlice<UInt8> {
            ArraySlice(bytes[start..<min(end, start + 48)])
        }
        switch framing {
        case .lengthPrefixed(let size):
            guard size > 0, size <= 4 else { return nil }
            var p = 0
            while p + size <= bytes.count {
                var length = 0
                for i in 0..<size { length = (length << 8) | Int(bytes[p + i]) }
                let start = p + size
                guard length > 0, start + length <= bytes.count else { return nil }
                let type = bytes[start] & 0x1f
                if type == 1 || type == 5 { return head(start, start + length) }
                p = start + length
            }
            return nil
        case .annexB:
            let ranges = bytes.baseAddress.map { base in
                AnnexB.nalRanges(UnsafeRawBufferPointer(start: base, count: bytes.count))
            } ?? []
            for range in ranges {
                let type = bytes[range.lowerBound] & 0x1f
                if type == 1 || type == 5 { return head(range.lowerBound, range.upperBound) }
            }
            return nil
        }
    }

    /// Appends the second field's bytes to the first and widens its timing to the frame: earliest PTS,
    /// the first field's DTS, both durations.
    private static func append(_ second: UnsafeMutablePointer<AVPacket>,
                               to first: UnsafeMutablePointer<AVPacket>) -> Bool {
        let oldSize = Int(first.pointee.size)
        let extra = Int(second.pointee.size)
        guard let source = second.pointee.data, extra > 0,
              av_grow_packet(first, Int32(extra)) == 0, let target = first.pointee.data else { return false }
        memcpy(target + oldSize, source, extra)
        let noPts = Int64.min
        if second.pointee.pts != noPts, first.pointee.pts == noPts || second.pointee.pts < first.pointee.pts {
            first.pointee.pts = second.pointee.pts
        }
        if first.pointee.duration > 0, second.pointee.duration > 0 {
            first.pointee.duration += second.pointee.duration
        }
        return true
    }
}
