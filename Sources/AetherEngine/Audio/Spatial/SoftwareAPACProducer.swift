// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default): it renders on a SpatialAudioBridge.
#if TrueHDObjectAudio || DTSXObjectAudio
import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// TrueHD Atmos or DTS:X for the software host: the same render-and-encode bridge the AVPlayer route
/// uses (`SpatialAudioBridge`), with its APAC packets handed to the audio renderer as sample buffers
/// where the HLS route muxes them into fMP4.
///
/// The bridge stamps packet k of an encoder run at the run's anchor plus k * 1024, priming packets
/// included, because AVFoundation's HLS path presents an APAC packet's audio `encoderLeadingFrames`
/// before its timestamp. A sample buffer carries the presentation time itself, so the same shift is
/// applied here (see `buffers(from:)` for the measurement).
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class SoftwareAPACProducer: SoftwareAudioProducing, @unchecked Sendable {

    private let bridge: SpatialAudioBridge
    private let sampleRate = Double(SpatialAudioBridge.sampleRate)
    private let stream: UnsafeMutablePointer<AVStream>
    /// PCM for the audio tap, which wants the 7.1 channel presentation the renderer is not given.
    /// Opened on the first tap, since most sessions never tap, and under the lock because the tap
    /// runs on the demux thread while `close` can come from the main actor.
    private var tapDecoder: AudioDecoder?
    private var tapOpenFailed = false
    private var closed = false
    private let lock = NSLock()
    private var loggedFeedError = false

    init(bridge: SpatialAudioBridge, stream: UnsafeMutablePointer<AVStream>) {
        self.bridge = bridge
        self.stream = stream
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        let packets: [UnsafeMutablePointer<AVPacket>]
        do {
            packets = try bridge.feed(packet: packet)
        } catch {
            lock.lock()
            let first = !loggedFeedError
            loggedFeedError = true
            lock.unlock()
            if first {
                EngineLog.emit("[SWHost] ERROR: APAC bridge refused a packet (\(error)); later ones are not logged",
                               category: .swPlayback)
            }
            return []
        }
        return buffers(from: packets)
    }

    /// The encoder's last packets once the source has ended, so the tail of the track plays.
    func endOfStream() -> [CMSampleBuffer] {
        buffers(from: bridge.flush())
    }

    /// Stamps the bridge's packets and frees them. The bridge stamps packet k of an encoder run at the
    /// run's anchor plus k * 1024, and the shift below puts the first content frame on the source position.
    ///
    /// Measured on macOS: with the packets stamped at the PTS minus the encoder's priming frames
    /// (2048 at 48 kHz), the APAC output lines up with the PCM decode of the same track on one
    /// synchronizer at 0.00 ms; stamped at the PTS unshifted it is off by +42.69 ms. So
    /// `AVSampleBufferAudioRenderer` does not remove the priming itself, and the `- leading` below is
    /// right. Not measured on tvOS.
    private func buffers(from packets: [UnsafeMutablePointer<AVPacket>]) -> [CMSampleBuffer] {
        let leading = Int64(bridge.encoderLeadingFrames)
        var buffers: [CMSampleBuffer] = []
        for encoded in packets {
            if let data = encoded.pointee.data, encoded.pointee.size > 0,
               let sample = Self.sampleBuffer(
                bytes: UnsafeRawBufferPointer(start: data, count: Int(encoded.pointee.size)),
                seconds: Double(encoded.pointee.pts - leading) / sampleRate,
                formatDescription: bridge.packetFormatDescription) {
                buffers.append(sample)
            }
            var owned: UnsafeMutablePointer<AVPacket>? = encoded
            trackedPacketFree(&owned)
        }
        return buffers
    }

    /// One APAC packet as a one-sample buffer.
    static func sampleBuffer(
        bytes: UnsafeRawBufferPointer, seconds: Double, formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        SoftwareEAC3Passthrough.sampleBuffer(bytes: bytes, seconds: seconds, formatDescription: formatDescription)
    }

    func flush() {
        bridge.startSegment()
        lock.lock()
        let tap = tapDecoder
        lock.unlock()
        tap?.flush()
    }

    func close() {
        bridge.close()
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
#endif
