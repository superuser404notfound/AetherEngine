import CoreMedia
import Foundation
import AetherLibavcodec
import AetherLibavutil

/// One source video packet as the segment producer read it, copied before the Profile 7 conversion strips
/// its enhancement layer, with the instant the served stream shows it.
///
/// The packet is a private copy that the receiver owns: free it with `trackedPacketFree`.
struct TappedVideoPacket {
    /// The whole source access unit: base layer, enhancement layer and RPU, as the demuxer delivered it.
    let packet: UnsafeMutablePointer<AVPacket>
    /// Presentation time as written into the served segment, on the axis `AVPlayerItem` reads
    /// (`NativeVideoFrameTime.item`).
    let item: CMTime
    /// Its decode time on the same axis, which the enhancement decoder needs to order a reordered stream.
    let decode: CMTime
    /// The producer generation that wrote it. A restart (a seek, a reopen) starts a new one.
    let epoch: UInt64
    let isKeyframe: Bool
}

/// Receives the packets a `VideoPacketTap` hands out.
protocol VideoPacketTapReceiver: AnyObject, Sendable {
    /// A producer started a generation. `codecpar` is valid for the call only.
    func tapDidStart(codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational, epoch: UInt64)
    func tapDidReceive(_ unit: TappedVideoPacket)
}

/// An in-process tap on the segment producer's single read of the source (the enhancement-layer route of
/// `LoadOptions.dualLayerRoute`). The producer already reads every packet once to build the base-layer
/// segments; where it converts a Profile 7 packet to 8.1 it first hands the tap a copy, and once the
/// packet is written it tells the tap the time the stream shows it at. No second connection, no second
/// demuxer.
///
/// The two calls are separate because the segment write happens a packet later than the conversion (the
/// producer looks one packet behind), and because only the write knows the served time: it applies the
/// frame grid and the timestamp sanitizer. The copy waits in a small table keyed by the shifted source
/// timestamp, which is the same value at both sites.
final class VideoPacketTap: @unchecked Sendable {

    /// Copies waiting for their write. A packet is written within a few iterations of its conversion, so
    /// the table is a handful deep; the bound only stops a packet that is never written from growing it.
    static let maximumPendingPackets = 32

    private let lock = NSLock()
    private var pending: [Int64: UnsafeMutablePointer<AVPacket>] = [:]
    private var order: [Int64] = []
    private weak var receiver: VideoPacketTapReceiver?
    private var copiedCount = 0
    private var handedCount = 0

    init(receiver: VideoPacketTapReceiver) {
        self.receiver = receiver
    }

    deinit { discardPending() }

    var counts: (copied: Int, handed: Int) {
        lock.lock(); defer { lock.unlock() }
        return (copiedCount, handedCount)
    }

    /// A producer generation began. Called once per producer, on its thread, before the first packet.
    func begin(codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational, epoch: UInt64) {
        discardPending()
        receiver?.tapDidStart(codecpar: codecpar, timeBase: timeBase, epoch: epoch)
    }

    /// Copies `packet` (before the conversion changes it) under `sourceKey`, the packet's timestamp as the
    /// producer holds it at this point.
    func stash(sourceKey: Int64, packet: UnsafePointer<AVPacket>) {
        guard sourceKey != Int64.min, let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        guard let copy = trackedPacketAlloc() else { return }
        guard av_new_packet(copy, packet.pointee.size) >= 0, let target = copy.pointee.data else {
            var failed: UnsafeMutablePointer<AVPacket>? = copy
            trackedPacketFree(&failed)
            return
        }
        memcpy(target, data, Int(packet.pointee.size))
        copy.pointee.pts = packet.pointee.pts
        copy.pointee.dts = packet.pointee.dts
        copy.pointee.duration = packet.pointee.duration
        copy.pointee.flags = packet.pointee.flags
        lock.lock()
        var evicted: [UnsafeMutablePointer<AVPacket>] = []
        if let old = pending.removeValue(forKey: sourceKey) {
            evicted.append(old)
            order.removeAll { $0 == sourceKey }
        }
        pending[sourceKey] = copy
        order.append(sourceKey)
        while order.count > Self.maximumPendingPackets {
            let key = order.removeFirst()
            if let old = pending.removeValue(forKey: key) { evicted.append(old) }
        }
        copiedCount += 1
        lock.unlock()
        for old in evicted {
            var o: UnsafeMutablePointer<AVPacket>? = old
            trackedPacketFree(&o)
        }
    }

    /// The packet stashed under `sourceKey` was written to the stream at `item`. Hands the copy to the
    /// receiver. Nothing happens when no copy is waiting under that key.
    func commit(sourceKey: Int64, item: CMTime, decode: CMTime, epoch: UInt64, isKeyframe: Bool) {
        lock.lock()
        let copy = pending.removeValue(forKey: sourceKey)
        if copy != nil { order.removeAll { $0 == sourceKey }; handedCount += 1 }
        lock.unlock()
        guard let copy else { return }
        guard let receiver else {
            var o: UnsafeMutablePointer<AVPacket>? = copy
            trackedPacketFree(&o)
            return
        }
        receiver.tapDidReceive(TappedVideoPacket(packet: copy, item: item, decode: decode, epoch: epoch, isKeyframe: isKeyframe))
    }

    /// Frees every copy still waiting.
    func discardPending() {
        lock.lock()
        let all = Array(pending.values)
        pending.removeAll()
        order.removeAll()
        lock.unlock()
        for packet in all {
            var o: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&o)
        }
    }
}
