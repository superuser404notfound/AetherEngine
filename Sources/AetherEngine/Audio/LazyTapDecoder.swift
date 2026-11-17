import Foundation
import CoreMedia
import AetherLibavformat
import AetherLibavcodec

/// The PCM decode the audio tap reads on a software producer that does not decode itself
/// (E-AC-3 passthrough, the Atmos converter, the APAC encoder): an `AudioDecoder` opened on the
/// first tap, since most sessions never tap.
///
/// The tap runs on the demux thread while `close` can come from the main actor, so open, use and
/// close go through one lock, and a close that lands first keeps a later tap from opening anything.
final class LazyTapDecoder: @unchecked Sendable {
    private let stream: UnsafeMutablePointer<AVStream>
    private let lock = NSLock()
    private var decoder: AudioDecoder?
    private var openFailed = false
    private var closed = false

    init(stream: UnsafeMutablePointer<AVStream>) {
        self.stream = stream
    }

    func buffers(for packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        let tap: AudioDecoder? = lock.withLock {
            if decoder == nil, !openFailed, !closed {
                let candidate = AudioDecoder()
                if (try? candidate.open(stream: stream)) != nil { decoder = candidate } else { openFailed = true }
            }
            return decoder
        }
        return tap?.decode(packet: packet) ?? []
    }

    func flush() {
        let tap = lock.withLock { decoder }
        tap?.flush()
    }

    func close() {
        let tap: AudioDecoder? = lock.withLock {
            closed = true
            let tap = decoder
            decoder = nil
            return tap
        }
        tap?.close()
    }
}
