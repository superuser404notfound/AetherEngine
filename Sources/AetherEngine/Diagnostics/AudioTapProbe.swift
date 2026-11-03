import Foundation
import AVFAudio

/// #95 verification probe: headless native session, LoopbackAudioReader decoding as fast as
/// segments are produced, mono Float32 48 kHz WAV out. Public so aetherctl can drive it
/// (SegmentCache / VideoSegmentProvider are internal); precedent: PacketTimingProbe (#93).
public enum AudioTapProbe {

    public enum ProbeError: Error, CustomStringConvertible, LocalizedError {
        case noCacheOrProvider
        case noInitSegment
        case wavWriteFailed(String)
        case notSoftwareRouted(String)
        public var description: String {
            switch self {
            case .noCacheOrProvider: return "session has no cache/provider"
            case .noInitSegment: return "no init segment after 30s"
            case .wavWriteFailed(let p): return "WAV write failed at \(p)"
            case .notSoftwareRouted(let b):
                return "source routed to \(b), not the software host; the SW sink cannot run"
            }
        }

        public var errorDescription: String? { description }
    }

    public static func run(url: URL, durationSeconds: Double, outPath: String,
                           channels: AudioTapChannels = .downmix) throws -> String {
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
            var dialogueBuffers = 0
            var firstSource: Double?
            var lastSource: Double = 0
            var lastEmittedEndPTS: Double = 0
        }
        let sink = Sink()
        let decoder = AudioTapSegmentDecoder(channels: channels)

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
                if buf.channels == .dialogue { sink.dialogueBuffers += 1 }
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
            + "dialogue=\(sink.dialogueBuffers)/\(sink.buffers) "
            + "sourceTime=[\(sink.firstSource ?? -1) ... \(sink.lastSource)] "
            + "wrote=\(outPath)"
    }

    /// What the software-path tap delivered. `run` / `runRemote` report the same numbers as a
    /// string, but this path has to distinguish two outcomes a string hides from a caller: no
    /// buffers at all and buffers of digital silence are different defects, and neither passes.
    public struct SoftwareTapReport: CustomStringConvertible, Sendable {
        public let buffers: Int
        public let pcmSeconds: Double
        public let discontinuities: Int
        /// Buffers that carried the centre channel alone (#908); 0 on a downmix install.
        public let dialogueBuffers: Int
        public let firstSource: Double?
        public let lastSource: Double
        public let peak: Float
        public let outPath: String

        /// True only if the tap yielded audible PCM.
        public var delivered: Bool { buffers > 0 && peak > 0.0001 }

        public var description: String {
            "audiotap (software): buffers=\(buffers) "
                + "pcmSeconds=\(String(format: "%.2f", pcmSeconds)) "
                + "discontinuities=\(discontinuities) "
                + "dialogue=\(dialogueBuffers)/\(buffers) "
                + "peak=\(String(format: "%.4f", peak)) "
                + "sourceTime=[\(firstSource ?? -1) ... \(lastSource)] "
                + "wrote=\(outPath)"
        }
    }

    /// #400 software-path variant, and the reason it exists: `run` and `runRemote` drive their
    /// readers directly, so the SW sink (`AudioTapPCMConverter`) was the one delivery path no
    /// probe could reach, and a crash on its first multichannel buffer shipped and stayed.
    /// This loads a real session, asserts it routed to the software host, installs the tap
    /// through the public API and plays, so the sink runs exactly as it does in a host.
    /// Unlike the other two modes this is bound to wall clock: the SW host decodes in real time.
    @MainActor
    public static func runSoftware(url: URL, durationSeconds: Double,
                                   outPath: String,
                                   channels: AudioTapChannels = .downmix) async throws -> SoftwareTapReport {
        let engine = try AetherEngine()
        try await engine.load(url: url)
        guard engine.playbackBackend == .software else {
            throw ProbeError.notSoftwareRouted(engine.playbackBackend.rawValue)
        }
        let stream = engine.installAudioTap(channels: channels)
        engine.play()

        // The stream only ends when the tap is removed, so nothing else would bound a source
        // that never yields. removeAudioTap() finishes it, which is what releases the loop.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 3 * 1_000_000_000))
            engine.removeAudioTap()
        }
        defer {
            deadline.cancel()
            engine.removeAudioTap()
            engine.stop()
        }

        var samples: [Float] = []
        var buffers = 0
        var discontinuities = 0
        var dialogueBuffers = 0
        var firstSource: Double?
        var lastSource: Double = 0
        var peak: Float = 0
        for await buf in stream {
            buffers += 1
            if buf.discontinuity { discontinuities += 1 }
            if buf.channels == .dialogue { dialogueBuffers += 1 }
            if firstSource == nil { firstSource = buf.sourceTime }
            lastSource = buf.sourceTime
            let frames = Int(buf.buffer.frameLength)
            if let channel = buf.buffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
                for i in 0..<frames { peak = max(peak, abs(channel[i])) }
            }
            if Double(samples.count) / AudioTapDefaults.sampleRate >= durationSeconds { break }
        }

        guard writeFloat32WAV(samples: samples,
                              sampleRate: Int(AudioTapDefaults.sampleRate), to: outPath) else {
            throw ProbeError.wavWriteFailed(outPath)
        }
        return SoftwareTapReport(
            buffers: buffers,
            pcmSeconds: Double(samples.count) / AudioTapDefaults.sampleRate,
            discontinuities: discontinuities,
            dialogueBuffers: dialogueBuffers,
            firstSource: firstSource, lastSource: lastSource,
            peak: peak, outPath: outPath)
    }

    /// #95 remote-HLS variant: drives AudioTapHLSReader against a remote HLS URL through the real
    /// AudioTapHLSFetcher (no loopback producer, no AVPlayer). A synthetic playhead trails the
    /// decode position so the reader decodes as-fast-as-available, the same trick as `run`.
    public static func runRemote(url: URL, durationSeconds: Double, outPath: String,
                                 channels: AudioTapChannels = .downmix) throws -> String {
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var samples: [Float] = []
            var buffers = 0
            var discontinuities = 0
            var dialogueBuffers = 0
            var firstSource: Double?
            var lastSource: Double = 0
            var lastEmittedEndPTS: Double = 0
        }
        let sink = Sink()
        let fetcher = AudioTapHLSFetcher()
        let decoder = AudioTapSegmentDecoder(channels: channels)
        let base = AudioTapBaseBox(url)

        let deps = AudioTapHLSReader.Dependencies(
            playhead: { [sink] in
                sink.lock.lock(); defer { sink.lock.unlock() }
                return max(0, sink.lastEmittedEndPTS - (AudioTapDefaults.leadSeconds - 1))
            },
            mediaURL: url,
            fetchPlaylist: { u in
                let (playlist, finalURL) = try await fetcher.fetchPlaylist(u)
                if let audioURI = AudioTapHLSVariantResolver.pickAudioURI(from: playlist),
                   let audioURL = HLSPlaylistParser.resolve(uri: audioURI, against: finalURL) {
                    let (mediaPlaylist, mediaFinal) = try await fetcher.fetchPlaylist(audioURL)
                    base.set(mediaFinal)
                    guard case .media(let media) = mediaPlaylist else {
                        throw AudioTapHLSFetcher.FetchError.invalidPlaylist("expected media playlist")
                    }
                    return media
                }
                base.set(finalURL)
                guard case .media(let media) = playlist else {
                    throw AudioTapHLSFetcher.FetchError.invalidPlaylist("expected media playlist")
                }
                return media
            },
            fetchSegment: { uri, crypt in
                guard let segURL = HLSPlaylistParser.resolve(uri: uri, against: base.get()) else {
                    throw AudioTapHLSFetcher.FetchError.unresolvable
                }
                return try await fetcher.fetchSegment(segURL, crypt: crypt, base: base.get())
            },
            decodeSegment: { decoder.decode(selfContainedSegment: $0) },
            emit: { [sink] buf in
                sink.lock.lock(); defer { sink.lock.unlock() }
                sink.buffers += 1
                if buf.discontinuity { sink.discontinuities += 1 }
                if buf.channels == .dialogue { sink.dialogueBuffers += 1 }
                if sink.firstSource == nil { sink.firstSource = buf.sourceTime }
                sink.lastSource = buf.sourceTime
                sink.lastEmittedEndPTS = buf.sourceTime
                    + Double(buf.buffer.frameLength) / AudioTapDefaults.sampleRate
                let n = Int(buf.buffer.frameLength)
                sink.samples.append(contentsOf: UnsafeBufferPointer(
                    start: buf.buffer.floatChannelData![0], count: n))
            })
        let reader = AudioTapHLSReader(deps: deps)
        reader.start()

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
        return "audiotap(remote): buffers=\(sink.buffers) "
            + "pcmSeconds=\(String(format: "%.2f", seconds)) "
            + "discontinuities=\(sink.discontinuities) "
            + "dialogue=\(sink.dialogueBuffers)/\(sink.buffers) "
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
