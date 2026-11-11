import Testing
import Foundation
import AetherLibavutil
@testable import AetherEngine

/// AE#1036: the loudness target and the plain gain, measured on steady tones through the real
/// shaping graph. A steady stereo sine of peak amplitude A reads 20*log10(A) LUFS (the K-weighting
/// adds +0.69 dB at 1 kHz, which BS.1770's -0.691 offset takes back out), so a level in and a level
/// out compare directly.
@Suite("AE#1036 loudness target and plain gain", .serialized, .offCooperativePoolOneLane)
struct LoudnessTargetTests {

    private static let rate: Int32 = 48_000

    private func sine(seconds: Double, amplitudeDB: Double, channels: Int = 2, only: Int? = nil,
                      rate: Int32 = rate, hz: Double = 997) -> [Float] {
        let frames = Int(seconds * Double(rate))
        let a = Float(pow(10, amplitudeDB / 20))
        var out = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = a * Float(sin(2 * .pi * hz * Double(f) / Double(rate)))
            for c in 0..<channels where only == nil || only == c { out[f * channels + c] = v }
        }
        return out
    }

    private func measure(_ samples: [Float], channels: Int32 = 2, rate: Int32 = rate) -> Double? {
        var layout = AVChannelLayout()
        defer { av_channel_layout_uninit(&layout) }
        av_channel_layout_default(&layout, channels)
        let meter = LoudnessNormalizer(targetLUFS: -24, maxGainDB: 0, sampleRate: rate, layout: &layout)
        var scratch = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { input in
            scratch.withUnsafeMutableBufferPointer { meter.process(input.baseAddress!, into: $0.baseAddress!, frames: samples.count / Int(channels)) }
        }
        return meter.integratedLUFS
    }

    private func makeGraph(_ shaping: AudioShaping, channels: Int32 = 2) throws -> AudioShapingGraph {
        var layout = AVChannelLayout()
        defer { av_channel_layout_uninit(&layout) }
        av_channel_layout_default(&layout, channels)
        return try #require(AudioShapingGraph(shaping: shaping, sampleRate: Self.rate, layout: &layout,
                                              sourceHasCentre: false, outputFormat: AV_SAMPLE_FMT_FLT))
    }

    /// Pushes `input` in 1024-frame chunks and returns everything that came out.
    private func run(_ graph: AudioShapingGraph, _ input: [Float], channels: Int = 2, drain: Bool = true) -> [Float] {
        var out: [Float] = []
        let collect: ([UnsafeMutableRawPointer?], Int, Int64?) -> Void = { planes, count, _ in
            out.append(contentsOf: UnsafeBufferPointer(start: planes[0]!.assumingMemoryBound(to: Float.self),
                                                       count: count * channels))
        }
        let frames = input.count / channels
        input.withUnsafeBufferPointer { buf in
            var at = 0
            while at < frames {
                let n = min(1024, frames - at)
                graph.process(buf.baseAddress! + at * channels, frames: n, pts: nil, emit: collect)
                at += n
            }
        }
        if drain { graph.drain(emit: collect) }
        return out
    }

    private func peakDB(_ samples: ArraySlice<Float>) -> Double {
        20 * log10(Double(samples.map { abs($0) }.max() ?? 0))
    }

    // MARK: - The value

    @Test("the target turns shaping on, is clamped, and reads back in the summary")
    func value() {
        #expect(AudioShaping(loudnessTargetLUFS: -24).isActive)
        #expect(AudioShaping(loudnessTargetLUFS: -60).clamped.loudnessTargetLUFS == -36)
        #expect(AudioShaping(loudnessTargetLUFS: 0).clamped.loudnessTargetLUFS == -12)
        #expect(AudioShaping(loudnessTargetLUFS: .nan).clamped.loudnessTargetLUFS == nil)
        #expect(!AudioShaping(loudnessTargetLUFS: .nan).isActive)
        #expect(AudioShaping(loudnessTargetLUFS: -24).summary == "loudness -24 LUFS")
    }

    @Test("the filter chain is the same with or without a target: the gain is applied before it")
    func chainUnchanged() {
        let plain = AudioShapingGraph.chain(shaping: AudioShaping(maxChannels: 2), stereoDialogueEnhance: false,
                                            outputFormat: AV_SAMPLE_FMT_FLT, layoutDescription: "stereo")
        let target = AudioShapingGraph.chain(shaping: AudioShaping(loudnessTargetLUFS: -24), stereoDialogueEnhance: false,
                                             outputFormat: AV_SAMPLE_FMT_FLT, layoutDescription: "stereo")
        #expect(plain == target)
    }

    // MARK: - The meter (BS.1770 reference readings)

    @Test("a 0 dBFS 997 Hz sine reads 0 LUFS on both fronts and -3.01 on one, at 44.1, 48 and 96 kHz")
    func meterReference() throws {
        for rate: Int32 in [44_100, 48_000, 96_000] {
            let both = try #require(measure(sine(seconds: 5, amplitudeDB: -20, rate: rate), rate: rate))
            let left = try #require(measure(sine(seconds: 5, amplitudeDB: -20, only: 0, rate: rate), rate: rate))
            #expect(abs(both - -20) < 0.1, "\(rate) Hz, both fronts: \(both)")
            #expect(abs(left - -23.01) < 0.1, "\(rate) Hz, left only: \(left)")
        }
    }

    @Test("5.1 weights: the LFE does not count, a surround counts 1.41 times a front")
    func meterWeights() throws {
        // av_channel_layout_default(6) is FL FR FC LFE BL BR.
        #expect(measure(sine(seconds: 5, amplitudeDB: -20, channels: 6, only: 3, hz: 60), channels: 6) == nil)
        let front = try #require(measure(sine(seconds: 5, amplitudeDB: -20, channels: 6, only: 0), channels: 6))
        let back = try #require(measure(sine(seconds: 5, amplitudeDB: -20, channels: 6, only: 4), channels: 6))
        #expect(abs((back - front) - 10 * log10(1.41)) < 0.05, "surround minus front: \(back - front)")
    }

    @Test("the gates: 20 s of silence after a tone moves the reading only by the three blocks that straddle the edge")
    func meterGates() throws {
        let tone = sine(seconds: 5, amplitudeDB: -30)
        let withSilence = tone + [Float](repeating: 0, count: 20 * Int(Self.rate) * 2)
        let a = try #require(measure(tone)), b = try #require(measure(withSilence))
        #expect(abs(a - b) < 0.2, "\(a) vs \(b)")
    }

    // MARK: - The gain through the graph

    @Test("a source 12 LU under a -24 target comes up to -24")
    func liftsToTarget() throws {
        let graph = try makeGraph(AudioShaping(loudnessTargetLUFS: -24))
        let out = run(graph, sine(seconds: 15, amplitudeDB: -36))
        let settled = peakDB(out.suffix(2 * Int(Self.rate) * 2))
        #expect(abs(settled - -24) < 0.2, "settled at \(settled) dBFS")
        #expect(abs((graph.loudnessGainDB ?? 0) - 12) < 0.05)
    }

    @Test("the gain rises at most 2 dB a second, so a quiet start fades up instead of stepping")
    func riseIsBounded() throws {
        let graph = try makeGraph(AudioShaping(loudnessTargetLUFS: -24))
        _ = run(graph, sine(seconds: 2, amplitudeDB: -36), drain: false)
        let gain = try #require(graph.loudnessGainDB)
        #expect(gain > 0 && gain <= 4.01, "gain after 2 s: \(gain)")
    }

    @Test("a source already above the target is left as it was")
    func neverLowers() throws {
        let graph = try makeGraph(AudioShaping(loudnessTargetLUFS: -24))
        let out = run(graph, sine(seconds: 8, amplitudeDB: -12))
        #expect(abs(peakDB(out.suffix(Int(Self.rate) * 2)) - -12) < 0.05)
        #expect(graph.loudnessGainDB == 0)
    }

    @Test("the lift stops at 18 dB")
    func liftIsCapped() throws {
        let graph = try makeGraph(AudioShaping(loudnessTargetLUFS: -24))
        let out = run(graph, sine(seconds: 15, amplitudeDB: -50))
        #expect(graph.loudnessGainDB == AudioShaping.maxLoudnessGainDB)
        #expect(abs(peakDB(out.suffix(Int(Self.rate) * 2)) - -32) < 0.2)
    }

    @Test("a seek keeps the measurement and the gain: the next chunk plays lifted at once")
    func seekKeepsGain() throws {
        let graph = try makeGraph(AudioShaping(loudnessTargetLUFS: -24))
        _ = run(graph, sine(seconds: 12, amplitudeDB: -36), drain: false)
        let before = try #require(graph.loudnessGainDB)
        graph.reset()
        #expect(graph.loudnessGainDB == before)
        let out = run(graph, sine(seconds: 0.5, amplitudeDB: -36))
        #expect(abs(peakDB(out.suffix(Int(Self.rate) / 4 * 2)) - (-36 + before)) < 0.2)
    }

    @Test("the limiter still holds the ceiling under a lifted loud burst")
    func limiterHoldsUnderLift() throws {
        let graph = try makeGraph(AudioShaping(loudnessTargetLUFS: -12))
        let quiet = sine(seconds: 15, amplitudeDB: -40)
        let burst = sine(seconds: 1, amplitudeDB: -3)
        let out = run(graph, quiet + burst)
        let ceiling = Float(pow(10, AudioShapingGraph.ceilingDBFS / 20))
        #expect((out.map { abs($0) }.max() ?? 0) <= ceiling + 1e-4)
    }

    // MARK: - The plain gain

    @Test("ratio 1 is a plain gain into the limiter: -20 dBFS at +6 dB is -14, 0 dBFS at +12 stays at -1")
    func plainGain() throws {
        let plus6 = AudioShaping(compressor: .init(thresholdDB: 0, ratio: 1, makeupGainDB: 6))
        let quiet = run(try makeGraph(plus6), sine(seconds: 2, amplitudeDB: -20))
        #expect(abs(peakDB(quiet.suffix(Int(Self.rate))) - -14) < 0.05, "got \(peakDB(quiet.suffix(Int(Self.rate))))")
        let plus12 = AudioShaping(compressor: .init(thresholdDB: 0, ratio: 1, makeupGainDB: 12))
        let loud = run(try makeGraph(plus12), sine(seconds: 2, amplitudeDB: 0))
        let peak = peakDB(loud.suffix(Int(Self.rate)))
        #expect(peak <= AudioShapingGraph.ceilingDBFS + 0.001 && peak > AudioShapingGraph.ceilingDBFS - 0.2, "got \(peak)")
    }
}
