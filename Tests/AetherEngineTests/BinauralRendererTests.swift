import Testing
import Foundation
import AudioToolbox
import AetherLibavutil
@testable import AetherEngine

/// The headphone render: every channel of a bed lands at its own direction around the listener, and
/// a full bed comes out about as loud as the plain fold it replaces.
@Suite("Binaural renderer", .serialized, .timeLimit(.minutes(3)))
struct BinauralRendererTests {

    private static let rate: Int32 = 48_000

    private static func noise(_ frames: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max) * 0.25
        }
    }

    private static func layout(_ name: String) -> AVChannelLayout {
        var l = AVChannelLayout()
        _ = av_channel_layout_from_string(&l, name)
        return l
    }

    /// Energy on each ear and the far ear's delay in samples for noise on `channel` alone.
    private static func measure(_ renderer: BinauralRenderer, channel: Int, frames: Int = 24_000)
        -> (left: Double, right: Double, rightLag: Int) {
        let burst = noise(frames, seed: UInt64(channel + 1))
        var input = [Float](repeating: 0, count: frames * renderer.inputChannels)
        for f in 0..<frames { input[f * renderer.inputChannels + channel] = burst[f] }
        var out = [Float](repeating: 0, count: frames * 2)
        renderer.reset()
        input.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { renderer.render(.interleaved(inp.baseAddress!), frames: frames, into: $0.baseAddress!) }
        }
        var l = 0.0, r = 0.0
        for f in 0..<frames { l += Double(out[2 * f] * out[2 * f]); r += Double(out[2 * f + 1] * out[2 * f + 1]) }
        var best = 0, bestValue = -Double.infinity
        for lag in -48...48 {
            var s = 0.0
            for f in 1000..<6000 { s += Double(out[2 * f] * out[2 * (f + lag) + 1]) }
            if s > bestValue { bestValue = s; best = lag }
        }
        return (l, r, best)
    }

    @Test("labels follow FFmpeg's layouts, a lone back pair counts as the surrounds")
    func labelMapping() {
        var five = Self.layout("5.1")
        defer { av_channel_layout_uninit(&five) }
        #expect(BinauralRenderer.labels(for: &five) == [kAudioChannelLabel_Left, kAudioChannelLabel_Right,
            kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround])
        var seven = Self.layout("7.1")
        defer { av_channel_layout_uninit(&seven) }
        #expect(BinauralRenderer.labels(for: &seven)?[4...] == [kAudioChannelLabel_RearSurroundLeft,
            kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround])
        var atmos = Self.layout("7.1.4")
        defer { av_channel_layout_uninit(&atmos) }
        #expect(BinauralRenderer.labels(for: &atmos)?.count == 12)
        var ambisonic = AVChannelLayout()
        defer { av_channel_layout_uninit(&ambisonic) }
        _ = av_channel_layout_from_string(&ambisonic, "ambisonic 1")
        #expect(BinauralRenderer.labels(for: &ambisonic) == nil)
    }

    @Test("each speaker is placed: the near ear louder and earlier, the centre even")
    func placement() throws {
        try #require(BinauralRenderer.isAvailable)
        var bed = Self.layout("7.1.4")
        defer { av_channel_layout_uninit(&bed) }
        let labels = try #require(BinauralRenderer.labels(for: &bed))
        let renderer = try #require(BinauralRenderer(labels: labels, sampleRate: Self.rate))
        // FFmpeg 7.1.4: FL FR FC LFE BL BR SL SR TFL TFR TBL TBR.
        let leftSide = [0, 4, 6, 8, 10], rightSide = [1, 5, 7, 9, 11]
        for ch in leftSide {
            let m = Self.measure(renderer, channel: ch)
            #expect(10 * log10(m.left / m.right) > 6, "channel \(ch) not on the left")
            #expect(m.rightLag > 5, "channel \(ch) reaches the right ear too early (\(m.rightLag))")
        }
        for ch in rightSide {
            let m = Self.measure(renderer, channel: ch)
            #expect(10 * log10(m.right / m.left) > 6, "channel \(ch) not on the right")
            #expect(m.rightLag < -5, "channel \(ch) reaches the left ear too early (\(m.rightLag))")
        }
        let centre = Self.measure(renderer, channel: 2)
        #expect(abs(10 * log10(centre.left / centre.right)) < 1.5)
        #expect(centre.rightLag == 0)
        // The side surrounds sit further round than the fronts, so the far ear hears them later.
        #expect(Self.measure(renderer, channel: 6).rightLag > Self.measure(renderer, channel: 0).rightLag + 8)
    }

    @Test("a full 5.1 bed comes out within 1 dB of the plain fold's loudness")
    func loudnessMatchesFold() throws {
        try #require(BinauralRenderer.isAvailable)
        var five = Self.layout("5.1")
        defer { av_channel_layout_uninit(&five) }
        let labels = try #require(BinauralRenderer.labels(for: &five))
        let renderer = try #require(BinauralRenderer(labels: labels, sampleRate: Self.rate))
        let frames = 48_000
        let channels = (0..<6).map { $0 == 3 ? [Float](repeating: 0, count: frames) : Self.noise(frames, seed: UInt64(10 + $0)) }
        var input = [Float](repeating: 0, count: frames * 6)
        for f in 0..<frames { for c in 0..<6 { input[f * 6 + c] = channels[c][f] } }
        var out = [Float](repeating: 0, count: frames * 2)
        input.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { renderer.render(.interleaved(inp.baseAddress!), frames: frames, into: $0.baseAddress!) }
        }
        // libswresample's fold at the shaping matrix's levels: front + 0.707 centre + 0.707 surround.
        var folded = 0.0, rendered = 0.0
        let g = Float(0.5.squareRoot())
        for f in 0..<frames {
            let l = channels[0][f] + g * channels[2][f] + g * channels[4][f]
            let r = channels[1][f] + g * channels[2][f] + g * channels[5][f]
            folded += Double(l * l + r * r)
            rendered += Double(out[2 * f] * out[2 * f] + out[2 * f + 1] * out[2 * f + 1])
        }
        let difference = 10 * log10(rendered / folded)
        print("binaural vs fold: \(String(format: "%+.2f", difference)) dB")
        #expect(abs(difference) < 1)
    }

    @Test("slices longer than the mixer's maximum render the same as short ones")
    func longSlices() throws {
        try #require(BinauralRenderer.isAvailable)
        var five = Self.layout("5.1")
        defer { av_channel_layout_uninit(&five) }
        let labels = try #require(BinauralRenderer.labels(for: &five))
        let a = try #require(BinauralRenderer(labels: labels, sampleRate: Self.rate))
        let b = try #require(BinauralRenderer(labels: labels, sampleRate: Self.rate))
        let frames = BinauralRenderer.maxFramesPerSlice * 2 + 333
        let input = Self.noise(frames * 6, seed: 99)
        var one = [Float](repeating: 0, count: frames * 2), split = one
        input.withUnsafeBufferPointer { inp in
            one.withUnsafeMutableBufferPointer { a.render(.interleaved(inp.baseAddress!), frames: frames, into: $0.baseAddress!) }
            split.withUnsafeMutableBufferPointer { out in
                var done = 0
                while done < frames {
                    let n = min(1024, frames - done)
                    b.render(.interleaved(inp.baseAddress! + done * 6), frames: n, into: out.baseAddress! + done * 2)
                    done += n
                }
            }
        }
        let worst = zip(one, split).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-4)
    }
}
