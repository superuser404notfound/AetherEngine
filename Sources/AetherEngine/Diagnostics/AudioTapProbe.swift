import Foundation
import AVFAudio

/// #95 verification probe: headless native session, LoopbackAudioReader decoding as fast as
/// segments are produced, mono Float32 48 kHz WAV out. Public so aetherctl can drive it
/// (SegmentCache / VideoSegmentProvider are internal); precedent: PacketTimingProbe (#93).
public enum AudioTapProbe {

    public enum ProbeError: Error, CustomStringConvertible {
        case noCacheOrProvider
        case noInitSegment
        case wavWriteFailed(String)
        public var description: String {
            switch self {
            case .noCacheOrProvider: return "session has no cache/provider"
            case .noInitSegment: return "no init segment after 30s"
            case .wavWriteFailed(let p): return "WAV write failed at \(p)"
            }
        }
    }

    public static func run(url: URL, durationSeconds: Double, outPath: String) throws -> String {
        let session = HLSVideoEngine(url: url, dvModeAvailable: false)
        _ = try session.start()
        defer { session.stop() }
        guard let cache = session.cache, let provider = session.provider else {
            throw ProbeError.noCacheOrProvider
        }
        guard cache.fetchInit(timeout: 30) != nil else {
            throw ProbeError.noInitSegment
        }

        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var samples: [Float] = []
            var buffers = 0
            var discontinuities = 0
            var firstSource: Double?
            var lastSource: Double = 0
            var lastEmittedEndPTS: Double = 0
        }
        let sink = Sink()
        let decoder = AudioTapSegmentDecoder()

        let deps = LoopbackAudioReader.Dependencies(
            // As-fast-as-available: the synthetic playhead trails the decode position by
            // (lead - 1 s), so the pacing gate always decides decodeNext until the producer
            // runs out of segments.
            playhead: { [sink] in
                sink.lock.lock(); defer { sink.lock.unlock() }
                return max(0, sink.lastEmittedEndPTS - (AudioTapDefaults.leadSeconds - 1))
            },
            shiftSeconds: { [weak session] in session?.playlistShiftSeconds ?? 0 },
            anchorIndex: { t in provider.segmentIndex(forPlaylistTime: t) },
            initData: { idx in cache.initData(versionID: cache.initVersionID(forSegment: idx)) },
            segmentData: { idx in cache.peek(index: idx) },
            highestStoredIndex: { cache.highestStoredIndex },
            decodeSegment: { initBlob, seg in decoder.decode(initData: initBlob, segment: seg) },
            emit: { [sink] buf in
                sink.lock.lock(); defer { sink.lock.unlock() }
                sink.buffers += 1
                if buf.discontinuity { sink.discontinuities += 1 }
                if sink.firstSource == nil { sink.firstSource = buf.sourceTime }
                sink.lastSource = buf.sourceTime
                sink.lastEmittedEndPTS = buf.sourceTime
                    + Double(buf.buffer.frameLength) / AudioTapDefaults.sampleRate
                let n = Int(buf.buffer.frameLength)
                sink.samples.append(contentsOf: UnsafeBufferPointer(
                    start: buf.buffer.floatChannelData![0], count: n))
            }
        )
        let reader = LoopbackAudioReader(deps: deps)
        reader.start()

        // Until `durationSeconds` of PCM exist or 3x that in wall-clock elapsed.
        let deadline = Date().addingTimeInterval(durationSeconds * 3)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            sink.lock.lock()
            let seconds = Double(sink.samples.count) / AudioTapDefaults.sampleRate
            sink.lock.unlock()
            if seconds >= durationSeconds { break }
        }
        reader.stop()

        sink.lock.lock()
        defer { sink.lock.unlock() }
        let seconds = Double(sink.samples.count) / AudioTapDefaults.sampleRate
        guard writeFloat32WAV(samples: sink.samples,
                              sampleRate: Int(AudioTapDefaults.sampleRate), to: outPath) else {
            throw ProbeError.wavWriteFailed(outPath)
        }
        return "audiotap: buffers=\(sink.buffers) "
            + "pcmSeconds=\(String(format: "%.2f", seconds)) "
            + "discontinuities=\(sink.discontinuities) "
            + "sourceTime=[\(sink.firstSource ?? -1) ... \(sink.lastSource)] "
            + "wrote=\(outPath)"
    }

    /// Minimal IEEE-float WAV writer (format tag 3).
    static func writeFloat32WAV(samples: [Float], sampleRate: Int, to path: String) -> Bool {
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let byteCount = samples.count * 4
        str("RIFF"); u32(UInt32(36 + byteCount)); str("WAVE")
        str("fmt "); u32(16); u16(3); u16(1); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 4)); u16(4); u16(32)
        str("data"); u32(UInt32(byteCount))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return (try? d.write(to: URL(fileURLWithPath: path))) != nil
    }
}
