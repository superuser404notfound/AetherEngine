import Foundation
import CoreMedia
import AetherLibavcodec

/// What the software host asks of whatever turns an audio packet into renderer input.
///
/// Three producers: `AudioDecoder` (PCM, the default), `SoftwareEAC3Passthrough` (the compressed
/// E-AC-3 JOC packets, for the system's Atmos decoder) and `SoftwareAPACProducer` (TrueHD Atmos and
/// DTS:X rendered into a speaker bed and encoded as APAC). The host's demux loop, seek path and clock
/// do not care which one it holds: buffers come out stamped on the source axis, and the renderer
/// is the only thing that learns the format.
protocol SoftwareAudioProducing: AnyObject, Sendable {
    /// One source packet in, zero or more stamped buffers out. Must not retain `packet`.
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer]
    /// AE#492 for audio: read before a packet is read, so a `flush()` that lands between the caller's
    /// last seek check and the feed retires the packet inside the producer, atomically with the feed.
    var feedEpoch: UInt64 { get }
    /// `decode(packet:)` unless `epoch` (the `feedEpoch` read before the packet was read) is no longer
    /// current, in which case the packet is dropped untouched and nothing is returned.
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64) -> [CMSampleBuffer]
    /// Audio packets this producer may take before its first buffer and still count as healthy. Past
    /// it with nothing produced, the demux loop anchors the clock on video ("decoder not recovering").
    var firstBufferPacketBudget: Int { get }
    /// Drop everything held (seek).
    func flush()
    func close()
    /// The end of the source: whatever the producer still holds, stamped like `decode`'s output.
    /// Only the APAC encoder holds anything (its last packets); the others have nothing.
    func endOfStream() -> [CMSampleBuffer]
    /// PCM for the audio tap, which feeds on decoded audio whatever the renderer was given.
    /// `produced` is what `decode` returned for `packet`; a PCM producer hands it straight back.
    func tapBuffers(for packet: UnsafeMutablePointer<AVPacket>, produced: [CMSampleBuffer]) -> [CMSampleBuffer]
}

extension SoftwareAudioProducing {
    /// A producer that stamps every buffer from its own packet's PTS keeps no anchor a stale packet
    /// could move: the one it lets through costs that packet's frames, which the caller's own seek
    /// check after the decode discards. Only the APAC producer anchors a whole run on one packet.
    var feedEpoch: UInt64 { 0 }
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64) -> [CMSampleBuffer] {
        decode(packet: packet)
    }
    /// A PCM decode or a passthrough has its first buffer within a packet or two.
    var firstBufferPacketBudget: Int { 50 }
    func endOfStream() -> [CMSampleBuffer] { [] }
    func tapBuffers(for packet: UnsafeMutablePointer<AVPacket>, produced: [CMSampleBuffer]) -> [CMSampleBuffer] {
        produced
    }
}

extension AudioDecoder: SoftwareAudioProducing {}
