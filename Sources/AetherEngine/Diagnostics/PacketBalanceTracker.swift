import Foundation
import Libavcodec

/// Process-wide counters for `av_packet_alloc` / `av_packet_free` calls
/// we initiate from Swift. Reads as `pktAlive = allocs - frees` in the
/// engine memory probe.
///
/// Steady-state for a healthy pump is a low single digit:
///   - 1 for the source packet currently inside the pump's defer block
///   - 1 each for `pendingVideoPkt` / `pendingAudioPkt` look-behind
///   - 0..N for FLAC packets the bridge has emitted but the pump hasn't
///     yet handed to the muxer + freed
///
/// Linearly rising `pktAlive` across probe samples means we're leaking
/// packets — every leaked AVPacket carries a refcounted data buffer
/// that's typically 3-50 KB, so even a single leaked packet per video
/// frame ≈ ~75 KB/s = 4.5 MB/min, in the right ballpark for the
/// observed long-form memory leak.
///
/// All call-sites in the producer / bridge / demuxer / subtitle decoder
/// go through `trackedPacketAlloc()` + `trackedPacketFree(_:)` wrappers
/// so the counter is comprehensive across paths we control.
/// Libavformat-internal allocations (mp4 muxer's interleave queue,
/// matroska parser's side data, etc.) are not counted here — those
/// flow through `av_packet_ref` / `av_packet_unref` against the same
/// buffer ref, not separate `av_packet_alloc` calls.
enum PacketBalanceTracker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _allocs: Int = 0
    nonisolated(unsafe) private static var _frees: Int = 0

    static func recordAlloc() {
        lock.lock()
        _allocs &+= 1
        lock.unlock()
    }

    static func recordFree() {
        lock.lock()
        _frees &+= 1
        lock.unlock()
    }

    static var alive: Int {
        lock.lock()
        defer { lock.unlock() }
        return _allocs - _frees
    }

    static var totalAllocs: Int {
        lock.lock()
        defer { lock.unlock() }
        return _allocs
    }
}

/// Wrapper around `av_packet_alloc()` that increments the
/// PacketBalanceTracker on success. Use this in place of
/// `av_packet_alloc()` everywhere in producer / bridge / demuxer
/// pipelines.
@inline(__always)
func trackedPacketAlloc() -> UnsafeMutablePointer<AVPacket>? {
    let p = av_packet_alloc()
    if p != nil {
        PacketBalanceTracker.recordAlloc()
    }
    return p
}

/// Wrapper around `av_packet_free(_:)` that increments the
/// PacketBalanceTracker before delegating. A nil input records
/// NOTHING: defer chains routinely pass an already-nil'd pointer
/// through here, and counting those as frees would drift `pktAlive`
/// negative.
@inline(__always)
func trackedPacketFree(_ pkt: inout UnsafeMutablePointer<AVPacket>?) {
    if pkt != nil {
        PacketBalanceTracker.recordFree()
    }
    av_packet_free(&pkt)
}
