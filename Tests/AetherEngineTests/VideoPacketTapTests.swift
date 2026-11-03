import Testing
import CoreMedia
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The enhancement-layer route reads each source packet once, in the segment producer: the tap copies it
/// before the Profile 7 conversion changes it and hands the copy over once the muxer has written it, with the
/// instant the stream shows it.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct VideoPacketTapTests {

    private final class Receiver: VideoPacketTapReceiver, @unchecked Sendable {
        struct Got { let bytes: [UInt8]; let item: Double; let decode: Double; let epoch: UInt64; let key: Bool }
        private let lock = NSLock()
        private var _got: [Got] = []
        private var _starts: [UInt64] = []
        var got: [Got] { lock.lock(); defer { lock.unlock() }; return _got }
        var starts: [UInt64] { lock.lock(); defer { lock.unlock() }; return _starts }
        func tapDidStart(codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational, epoch: UInt64) {
            lock.lock(); _starts.append(epoch); lock.unlock()
        }
        func tapDidReceive(_ unit: TappedVideoPacket) {
            var packet: UnsafeMutablePointer<AVPacket>? = unit.packet
            defer { trackedPacketFree(&packet) }
            let bytes = Array(UnsafeBufferPointer(start: unit.packet.pointee.data, count: Int(unit.packet.pointee.size)))
            lock.lock()
            _got.append(Got(bytes: bytes, item: unit.item.seconds, decode: unit.decode.seconds, epoch: unit.epoch, key: unit.isKeyframe))
            lock.unlock()
        }
    }

    private static func withPacket(_ bytes: [UInt8], pts: Int64, _ body: (UnsafeMutablePointer<AVPacket>) -> Void) {
        var packet: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc()
        defer { trackedPacketFree(&packet) }
        guard let p = packet, av_new_packet(p, Int32(bytes.count)) >= 0, let data = p.pointee.data else { return }
        _ = bytes.withUnsafeBytes { memcpy(data, $0.baseAddress!, bytes.count) }
        p.pointee.pts = pts
        body(p)
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 90000) }

    @Test("a packet is handed over after its write with the served time, and the conversion cannot change the copy")
    func copyIsHandedOverWithItsServedTime() {
        let receiver = Receiver()
        let tap = VideoPacketTap(receiver: receiver)
        Self.withPacket([1, 2, 3, 4], pts: 9000) { packet in
            tap.stash(sourceKey: 9000, packet: packet)
            // The producer rewrites the packet in place right after the stash.
            packet.pointee.data[0] = 99
        }
        #expect(receiver.got.isEmpty, "nothing is handed over before the write")
        tap.commit(sourceKey: 9000, item: Self.time(1.0), decode: Self.time(0.9), epoch: 7, isKeyframe: true)
        let got = receiver.got
        #expect(got.count == 1)
        #expect(got.first?.bytes == [1, 2, 3, 4])
        #expect(got.first?.item == 1.0)
        #expect(got.first?.decode == 0.9)
        #expect(got.first?.epoch == 7)
        #expect(got.first?.key == true)
        #expect(tap.counts.copied == 1 && tap.counts.handed == 1)
    }

    @Test("a commit for a packet that was never stashed hands nothing over")
    func unknownKeyIsIgnored() {
        let receiver = Receiver()
        let tap = VideoPacketTap(receiver: receiver)
        tap.commit(sourceKey: 1, item: Self.time(0), decode: Self.time(0), epoch: 1, isKeyframe: false)
        #expect(receiver.got.isEmpty)
    }

    @Test("a packet that is never written is dropped once the table is full, oldest first")
    func pendingTableIsBounded() {
        let receiver = Receiver()
        let tap = VideoPacketTap(receiver: receiver)
        let total = VideoPacketTap.maximumPendingPackets + 5
        for n in 0..<total {
            Self.withPacket([UInt8(n)], pts: Int64(n)) { tap.stash(sourceKey: Int64(n), packet: $0) }
        }
        tap.commit(sourceKey: 0, item: Self.time(0), decode: Self.time(0), epoch: 1, isKeyframe: false)
        #expect(receiver.got.isEmpty, "the oldest copy was evicted")
        tap.commit(sourceKey: Int64(total - 1), item: Self.time(1), decode: Self.time(1), epoch: 1, isKeyframe: false)
        #expect(receiver.got.map(\.bytes) == [[UInt8(total - 1)]])
    }

    @Test("a packet with no timestamp or no payload is not copied")
    func unusablePacketsAreSkipped() {
        let receiver = Receiver()
        let tap = VideoPacketTap(receiver: receiver)
        Self.withPacket([5], pts: 1) { tap.stash(sourceKey: Int64.min, packet: $0) }
        #expect(tap.counts.copied == 0)
    }

    @Test("a producer generation is announced once to the receiver")
    func beginReportsTheGeneration() {
        let receiver = Receiver()
        let tap = VideoPacketTap(receiver: receiver)
        let par = avcodec_parameters_alloc()
        defer { var p = par; avcodec_parameters_free(&p) }
        tap.begin(codecpar: par!, timeBase: AVRational(num: 1, den: 1000), epoch: 3)
        #expect(receiver.starts == [3])
    }
}
