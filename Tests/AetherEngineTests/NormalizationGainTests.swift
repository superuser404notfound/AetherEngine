import Testing
import Foundation
import AVFoundation
@testable import AetherEngine

/// Sodalite#242: the per-track loudness correction. The processor is measured on steady sines, the
/// tap end to end through `AVAssetReaderAudioMixOutput`, which runs an item's audio mix (tap
/// included) the way AVPlayer does.
@Suite("Sodalite#242 normalization gain", .serialized)
struct NormalizationGainTests {

    private static let rate = 48_000.0

    private func sine(seconds: Double, amplitudeDB: Double, channels: Int = 2) -> [Float] {
        let frames = Int(seconds * Self.rate)
        let a = Float(pow(10, amplitudeDB / 20))
        var out = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = a * Float(sin(2 * .pi * 997 * Double(f) / Self.rate))
            for c in 0..<channels { out[f * channels + c] = v }
        }
        return out
    }

    private func run(_ processor: NormalizationGainProcessor, _ input: [Float], chunk: Int = 512) -> [Float] {
        var samples = input
        let channels = processor.channels
        let frames = samples.count / channels
        samples.withUnsafeMutableBufferPointer { buffer in
            var at = 0
            while at < frames {
                let n = min(chunk, frames - at)
                processor.process(interleaved: buffer.baseAddress! + at * channels, frames: n)
                at += n
            }
        }
        return samples
    }

    private func peakDB(_ samples: ArraySlice<Float>) -> Double {
        20 * log10(Double(samples.map(abs).max() ?? 0))
    }

    @Test("a cut is plain gain, delayed by the lookahead")
    func cutIsPlainGain() {
        let processor = NormalizationGainProcessor(gainDB: -6, sampleRate: Self.rate, channels: 2)
        let input = sine(seconds: 0.5, amplitudeDB: -3)
        let output = run(processor, input)
        let delay = processor.lookaheadFrames * 2
        let gain = Float(pow(10, -6.0 / 20))
        for i in stride(from: 10_000, to: 20_000, by: 7) {
            #expect(abs(output[i + delay] - input[i] * gain) < 1e-5)
        }
        #expect(processor.statistics.maxReductionDB == 0)
        #expect(processor.statistics.limitedFrames == 0)
    }

    @Test("a lift into full scale never passes the ceiling, and the limiter reports its work")
    func liftIsLimited() {
        let processor = NormalizationGainProcessor(gainDB: 12, sampleRate: Self.rate, channels: 2)
        let output = run(processor, sine(seconds: 1, amplitudeDB: -6))
        // Ceiling is -1 dBFS; a hair of float slack.
        #expect(peakDB(output[...]) <= NormalizationGainProcessor.ceilingDBFS + 0.01)
        // +12 on -6 asks for +6 dBFS, so the limiter takes about 7 dB.
        let stats = processor.statistics
        #expect(abs(stats.maxReductionDB - 7) < 0.3)
        #expect(stats.limitingShare > 0.9)
    }

    @Test("a lift below the ceiling is exact and leaves the limiter idle")
    func cleanLift() {
        let processor = NormalizationGainProcessor(gainDB: 9, sampleRate: Self.rate, channels: 2)
        let output = run(processor, sine(seconds: 0.5, amplitudeDB: -20))
        #expect(abs(peakDB(output[24_000...]) - (-11)) < 0.05)
        #expect(processor.statistics.maxReductionDB == 0)
    }

    @Test("a single-sample spike is caught before it reaches the output")
    func transientIsCaught() {
        let processor = NormalizationGainProcessor(gainDB: 10, sampleRate: Self.rate, channels: 1)
        var input = [Float](repeating: 0.01, count: 48_000)
        input[30_000] = 0.9
        let output = run(processor, input, chunk: 333)
        #expect(peakDB(output[...]) <= NormalizationGainProcessor.ceilingDBFS + 0.01)
    }

    @Test("a live change ramps instead of stepping")
    func liveChangeRamps() {
        let processor = NormalizationGainProcessor(gainDB: 0, sampleRate: Self.rate, channels: 1)
        let ones = [Float](repeating: 0.1, count: 4_800)
        _ = run(processor, ones)
        processor.setGainDB(6)
        let output = run(processor, [Float](repeating: 0.1, count: 4_800), chunk: 4_800)
        var largestStep: Float = 0
        for i in 1 ..< output.count { largestStep = max(largestStep, abs(output[i] - output[i - 1])) }
        // A step would be 0.1 * (2 - 1) = 0.1 in one sample; a ramp over 4800 frames is far below.
        #expect(largestStep < 0.001)
        // The ramp's tail is still in the delay line; the next buffer plays at the new gain.
        let settled = run(processor, [Float](repeating: 0.1, count: 4_800))
        #expect(abs(settled.last! - 0.1 * Float(pow(10, 6.0 / 20))) < 1e-4)
    }

    @Test("gains outside the range are clamped, non-finite ones are 0 dB")
    func clamping() {
        #expect(NormalizationGainProcessor.clampedGainDB(40) == 18)
        #expect(NormalizationGainProcessor.clampedGainDB(-90) == -30)
        #expect(NormalizationGainProcessor.clampedGainDB(.nan) == 0)
        #expect(LoadOptions(normalizationGainDB: 25).normalizationGainDB == 18)
        #expect(LoadOptions(normalizationGainDB: .infinity).normalizationGainDB == nil)
    }

    @Test("the report line names gain, host, stage and limiter")
    func reportSummary() {
        let report = NormalizationGainReport(requestedDB: 3, appliedDB: 3, host: .avPlayer, stage: .tap,
                                             limiterMaxReductionDB: 2.3, limitingShare: 0.004)
        #expect(report.summary == "requested=+3.0 applied=+3.0 host=AVPlayer stage=tap limiter=2.3 dB 0.4%")
        let idle = NormalizationGainReport(requestedDB: -7.9, appliedDB: -7.9, host: .ffmpeg, stage: .decoder)
        #expect(idle.summary == "requested=-7.9 applied=-7.9 host=FFmpeg stage=decoder limiter=none")
    }

    // MARK: - Tap

    /// Writes a stereo 997 Hz sine to a temporary AIFF file.
    private func writeSine(amplitudeDB: Double, seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("normalization-\(UUID().uuidString).aiff")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: true,
        ])
        let frames = AVAudioFrameCount(seconds * Self.rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let a = Float(pow(10, amplitudeDB / 20))
        for f in 0 ..< Int(frames) {
            let v = a * Float(sin(2 * .pi * 997 * Double(f) / Self.rate))
            buffer.floatChannelData![0][f] = v
            buffer.floatChannelData![1][f] = v
        }
        try file.write(from: buffer)
        return url
    }

    /// Reads the asset through an audio mix output carrying `mix`, returns the peak in dBFS.
    private func readPeak(_ asset: AVURLAsset, track: AVAssetTrack, mix: AVAudioMix?) throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = mix
        reader.add(output)
        #expect(reader.startReading())
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            // Copy rather than take the data pointer: a block buffer can be several segments, and
            // the pointer only covers the first. Reading totalLength through it ran off the end on a
            // loaded CI runner and measured garbage (an inf peak).
            var floats = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            let status = floats.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            #expect(status == kCMBlockBufferNoErr)
            for value in floats { peak = max(peak, abs(value)) }
        }
        #expect(reader.status == .completed, "reader ended \(reader.status.rawValue): \(String(describing: reader.error))")
        return 20 * log10(Double(peak))
    }

    @Test("the tap lifts a quiet file inside an audio mix")
    func tapLiftsThroughAudioMix() async throws {
        let url = try writeSine(amplitudeDB: -15, seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)

        let untouched = try readPeak(asset, track: track, mix: nil)
        #expect(abs(untouched - (-15)) < 0.05)

        let tap = try #require(NormalizationTap(gainDB: 12))
        let lifted = try readPeak(asset, track: track, mix: tap.audioMix(for: track))
        #expect(abs(lifted - (-3)) < 0.1)
        if case .running(let rate, let channels) = tap.context.preparation {
            #expect(rate == Self.rate)
            #expect(channels == 2)
        } else {
            Issue.record("tap was not prepared: \(tap.context.preparation)")
        }
        #expect(tap.context.statistics?.frames ?? 0 > 0)
        #expect(tap.context.statistics?.maxReductionDB == 0)

        let limited = try #require(NormalizationTap(gainDB: 18))
        let ceilinged = try readPeak(asset, track: track, mix: limited.audioMix(for: track))
        #expect(ceilinged <= NormalizationGainProcessor.ceilingDBFS + 0.01)
        #expect((limited.context.statistics?.maxReductionDB ?? 0) > 0)
    }

    /// Audit AUD-204: the tap or the volume cut was written after the asset's track read, and the
    /// load's own supersede check came only after that. A track whose read failed once a skip had
    /// replaced it put its cut on the shared `avPlayer.volume`, so the next track played quieter.
    @Test("a load replaced during its track read leaves the next track's volume alone",
          .timeLimit(.minutes(3)))
    @MainActor
    func supersededLoadKeepsItsCutToItself() async throws {
        let origin = try #require(HeldHTTPOrigin())
        defer { origin.stop() }
        let host = AudioAVPlayerHost(ownsNowPlaying: false)
        defer { host.stop() }
        host.normalizationGainDB = -12

        let first = Task { @MainActor in
            try await host.load(url: origin.url("/replaced.m4a"), startPosition: nil, httpHeaders: [:])
        }
        try await waitFor { origin.connectionCount > 0 }
        host.normalizationGainDB = nil
        try await host.load(url: URL(string: "http://127.0.0.1:9/next.m4a")!, startPosition: nil,
                            httpHeaders: [:])
        origin.release()
        _ = await first.result

        #expect(host.avPlayer.volume == 1)
        #expect(host.normalizationReport == nil)
    }
}
