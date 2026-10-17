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
    func endOfStream() -> [CMSampleBuffer] { [] }
    func tapBuffers(for packet: UnsafeMutablePointer<AVPacket>, produced: [CMSampleBuffer]) -> [CMSampleBuffer] {
        produced
    }
}

extension AudioDecoder: SoftwareAudioProducing {}
