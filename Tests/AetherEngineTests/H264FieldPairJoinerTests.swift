import Testing
import AetherLibavcodec
@testable import AetherEngine

/// AE#1070: PAFF broadcast (1080i in MPEG-TS) carries one field per packet. Muxed that way for the
/// native route, AVPlayer showed every field as a frame and the picture bounced on an Apple TV.
@Suite("AE#1070 H.264 field pairs become one sample")
struct H264FieldPairJoinerTests {
    private static let video: Int32 = 0
    private static let audio: Int32 = 1
    private static let context = H264SPS.SliceContext(separateColourPlane: false, log2MaxFrameNum: 4,
                                                      frameMbsOnly: false)

    private struct BitWriter {
        var bits: [Int] = []
        mutating func u(_ value: Int, _ n: Int) { for i in stride(from: n - 1, through: 0, by: -1) { bits.append((value >> i) & 1) } }
        mutating func ue(_ value: Int) {
            let v = value + 1
            let n = Int.bitWidth - v.leadingZeroBitCount
            u(0, n - 1); u(v, n)
        }
        var bytes: [UInt8] {
            var padded = bits + [1]
            while padded.count % 8 != 0 { padded.append(0) }
            return stride(from: 0, to: padded.count, by: 8).map { i in
                UInt8(padded[i..<(i + 8)].reduce(0) { ($0 << 1) | $1 })
            }
        }
    }

    /// An Annex-B access unit: an AUD, then one slice whose header codes a field (or a frame).
    private static func accessUnit(frameNum: Int, field: Bool?, idr: Bool = false,
                                   log2: Int = context.log2MaxFrameNum) -> [UInt8] {
        var w = BitWriter()
        w.ue(0); w.ue(idr ? 7 : 5); w.ue(0)
        w.u(frameNum, log2)
        if let bottom = field { w.u(1, 1); w.u(bottom ? 1 : 0, 1) } else { w.u(0, 1) }
        return [0, 0, 0, 1, 0x09, 0xf0, 0, 0, 1, idr ? 0x65 : 0x41] + w.bytes + [0xaa, 0xbb]
    }

    /// An Annex-B Main profile SPS, as an MPEG-TS demuxer exposes it in extradata.
    private static func spsExtradata(log2MaxFrameNum: Int, frameMbsOnly: Bool) -> [UInt8] {
        var w = BitWriter()
        w.u(77, 8); w.u(0, 8); w.u(30, 8)
        w.ue(0); w.ue(log2MaxFrameNum - 4); w.ue(2); w.ue(1); w.u(0, 1)
        w.ue(44); w.ue(frameMbsOnly ? 35 : 17); w.u(frameMbsOnly ? 1 : 0, 1)
        if !frameMbsOnly { w.u(0, 1) }
        w.u(1, 1); w.u(0, 1)
        return [0, 0, 0, 1, 0x67] + w.bytes + [0, 0, 0, 1, 0x68, 0xCE, 0x38, 0x80]   // SPS then a PPS
    }

    private static func packet(_ bytes: [UInt8], stream: Int32, pts: Int64, duration: Int64 = 1800,
                               key: Bool = false) -> UnsafeMutablePointer<AVPacket> {
        let p = trackedPacketAlloc()!
        _ = av_new_packet(p, Int32(bytes.count))
        bytes.withUnsafeBytes { _ = memcpy(p.pointee.data, $0.baseAddress!, bytes.count) }
        p.pointee.stream_index = stream
        p.pointee.pts = pts
        p.pointee.dts = pts
        p.pointee.duration = duration
        if key { p.pointee.flags |= AV_PKT_FLAG_KEY }
        return p
    }

    private static func drain(_ input: [UnsafeMutablePointer<AVPacket>])
        -> (out: [(stream: Int32, pts: Int64, duration: Int64, size: Int32, key: Bool)], joiner: H264FieldPairJoiner) {
        let joiner = H264FieldPairJoiner(videoStreamIndex: video, context: context, framing: .annexB)
        var queue = input
        var out: [(Int32, Int64, Int64, Int32, Bool)] = []
        while let p = try? joiner.next(read: { queue.isEmpty ? nil : queue.removeFirst() }) {
            out.append((p.pointee.stream_index, p.pointee.pts, p.pointee.duration, p.pointee.size,
                        p.pointee.flags & AV_PKT_FLAG_KEY != 0))
            var free: UnsafeMutablePointer<AVPacket>? = p
            trackedPacketFree(&free)
        }
        return (out.map { ($0.0, $0.1, $0.2, $0.3, $0.4) }, joiner)
    }

    @Test("the slice header reads frame_num and parity, and a frame picture is not a field")
    func readsFieldIdentity() {
        for (frameNum, bottom) in [(0, false), (5, true), (15, false)] {
            let au = Self.accessUnit(frameNum: frameNum, field: bottom)
            let field = au.withUnsafeBufferPointer {
                H264FieldPairJoiner.field(in: $0, framing: .annexB, context: Self.context)
            }
            #expect(field == .init(frameNum: frameNum, bottom: bottom))
        }
        let frame = Self.accessUnit(frameNum: 3, field: nil)
        #expect(frame.withUnsafeBufferPointer {
            H264FieldPairJoiner.field(in: $0, framing: .annexB, context: Self.context)
        } == nil)
    }

    @Test("two fields of a frame become one packet with the frame's timing, audio between them follows")
    func joinsPairsAndKeepsAudio() {
        let top0 = Self.accessUnit(frameNum: 0, field: false, idr: true)
        let bottom0 = Self.accessUnit(frameNum: 0, field: true)
        let top1 = Self.accessUnit(frameNum: 1, field: false)
        let bottom1 = Self.accessUnit(frameNum: 1, field: true)
        let input = [
            Self.packet(top0, stream: Self.video, pts: 1800, key: true),
            Self.packet([1, 2, 3], stream: Self.audio, pts: 1000),
            Self.packet(bottom0, stream: Self.video, pts: 3600),
            Self.packet(bottom1, stream: Self.video, pts: 9000),   // bottom first, pts order reversed
            Self.packet(top1, stream: Self.video, pts: 7200),
        ]
        let (out, joiner) = Self.drain(input)
        #expect(out.map(\.stream) == [Self.video, Self.audio, Self.video])
        #expect(out[0].pts == 1800 && out[0].duration == 3600 && out[0].key)
        #expect(out[0].size == Int32(top0.count + bottom0.count))
        #expect(out[2].pts == 7200 && out[2].duration == 3600)
        #expect(joiner.pairsJoined == 2 && joiner.unpairedFields == 0)
    }

    @Test("a field without its partner and frame pictures pass on alone")
    func unpairedAndFramesPassThrough() {
        let input = [
            Self.packet(Self.accessUnit(frameNum: 2, field: false), stream: Self.video, pts: 0),
            Self.packet(Self.accessUnit(frameNum: 3, field: false), stream: Self.video, pts: 1800),
            Self.packet(Self.accessUnit(frameNum: 3, field: true), stream: Self.video, pts: 3600),
            Self.packet(Self.accessUnit(frameNum: 4, field: nil), stream: Self.video, pts: 5400, duration: 3600),
        ]
        let (out, joiner) = Self.drain(input)
        #expect(out.map(\.pts) == [0, 1800, 5400])
        #expect(out.map(\.duration) == [1800, 3600, 3600])
        #expect(joiner.pairsJoined == 1 && joiner.unpairedFields == 1)
    }

    @Test("a progressive SPS does not arm the joiner")
    func progressiveSPSDoesNotArm() {
        // Baseline SPS, 1280x720, frame_mbs_only_flag = 1.
        let sps: [UInt8] = [0x67, 0x42, 0xc0, 0x1f, 0xda, 0x01, 0x40, 0x16, 0xec, 0x04, 0x40, 0x00,
                            0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0c, 0x83, 0xc6, 0x0c, 0xa8]
        #expect(H264SPS.sliceContext(fromNAL: sps)?.frameMbsOnly == true)
    }

    /// Audit BIT-203: an SPS change used to switch the joiner off for the rest of the session.
    @Test("a new PAFF SPS re-arms the joiner with its own frame_num width, a progressive one disarms it")
    func rearmFollowsTheNewSPS() {
        let joiner = H264FieldPairJoiner(videoStreamIndex: Self.video, context: Self.context, framing: .annexB)
        joiner.rearm(videoStreamIndex: Self.video,
                     extradata: Self.spsExtradata(log2MaxFrameNum: 8, frameMbsOnly: false))
        var queue = [
            Self.packet(Self.accessUnit(frameNum: 200, field: false, log2: 8), stream: Self.video, pts: 0),
            Self.packet(Self.accessUnit(frameNum: 200, field: true, log2: 8), stream: Self.video, pts: 1800),
        ]
        let joined = try? joiner.next(read: { queue.isEmpty ? nil : queue.removeFirst() })
        #expect(joined != nil)
        if let p = joined { var free: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&free) }
        #expect(joiner.pairsJoined == 1)

        joiner.rearm(videoStreamIndex: Self.video,
                     extradata: Self.spsExtradata(log2MaxFrameNum: 8, frameMbsOnly: true))
        queue = [
            Self.packet(Self.accessUnit(frameNum: 1, field: false, log2: 8), stream: Self.video, pts: 0),
            Self.packet(Self.accessUnit(frameNum: 1, field: true, log2: 8), stream: Self.video, pts: 1800),
        ]
        var count = 0
        while let p = try? joiner.next(read: { queue.isEmpty ? nil : queue.removeFirst() }) {
            count += 1
            var free: UnsafeMutablePointer<AVPacket>? = p
            trackedPacketFree(&free)
        }
        #expect(count == 2 && joiner.pairsJoined == 1)
    }
}
