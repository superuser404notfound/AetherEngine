import Testing
import Foundation
import AetherLibavutil
@testable import AetherEngine

/// Audit AUD-203, AUD-207, AUD-R202, AUD-R204: one shaping stage for the bridge and the software
/// decoder, which follows a source layout change instead of keeping the layout it started with.
@Suite("AUD-R202 audio shaping stage", .serialized, .offCooperativePoolOneLane)
struct AudioShapingStageTests {

    private static let rate: Int32 = 48_000

    private func layout(_ channels: Int32) -> AVChannelLayout {
        var l = AVChannelLayout()
        av_channel_layout_default(&l, channels)
        return l
    }

    private func sine(frames: Int, channels: Int, amplitudeDB: Double) -> [Float] {
        let a = Float(pow(10, amplitudeDB / 20))
        var out = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v = a * Float(sin(2 * .pi * 997 * Double(f) / Double(Self.rate)))
            for c in 0..<channels { out[f * channels + c] = v }
        }
        return out
    }

    @Test("a stereo source gets the stereo enhancer, and 5.1 arriving mid-stream takes it away")
    func stereoToSurroundDropsTheEnhancer() throws {
        var stereo = layout(2), surround = layout(6)
        defer { av_channel_layout_uninit(&stereo); av_channel_layout_uninit(&surround) }
        let stage = AudioShapingStage(shaping: AudioShaping(dialogueGainDB: 6), outputFormat: AV_SAMPLE_FMT_FLT)
        #expect(stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &stereo, emit: nil))
        #expect(stage.graph?.enhancesDialogue == true)
        let first = try #require(stage.graph)

        #expect(stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &surround) { _, _, _ in })
        #expect(stage.graph?.enhancesDialogue == false, "the matrix lifts the centre now, the graph must not as well")
        #expect(stage.graph !== first)
    }

    @Test("a 5.1 source that falls back to stereo gets the enhancer back")
    func surroundToStereoRestoresTheEnhancer() throws {
        var stereo = layout(2), surround = layout(6)
        defer { av_channel_layout_uninit(&stereo); av_channel_layout_uninit(&surround) }
        let stage = AudioShapingStage(shaping: AudioShaping(dialogueGainDB: 6), outputFormat: AV_SAMPLE_FMT_FLT)
        stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &surround, emit: nil)
        #expect(stage.graph?.enhancesDialogue == false)
        stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &stereo) { _, _, _ in }
        #expect(stage.graph?.enhancesDialogue == true)
    }

    @Test("a layout change that leaves the route alone keeps the graph")
    func sameRouteKeepsTheGraph() throws {
        var stereo = layout(2), mono = layout(1)
        defer { av_channel_layout_uninit(&stereo); av_channel_layout_uninit(&mono) }
        let stage = AudioShapingStage(shaping: AudioShaping(dialogueGainDB: 6), outputFormat: AV_SAMPLE_FMT_FLT)
        stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &stereo, emit: nil)
        let first = try #require(stage.graph)
        stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &mono) { _, _, _ in }
        #expect(stage.graph === first)
    }

    @Test("the old graph's held tail is emitted before the new one takes over")
    func rebuildEmitsTheTail() throws {
        var stereo = layout(2), surround = layout(6)
        defer { av_channel_layout_uninit(&stereo); av_channel_layout_uninit(&surround) }
        let stage = AudioShapingStage(shaping: AudioShaping(dialogueGainDB: 6), outputFormat: AV_SAMPLE_FMT_FLT)
        stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &stereo, emit: nil)
        let input = sine(frames: 10_000, channels: 2, amplitudeDB: -20)
        var emitted = 0
        input.withUnsafeBufferPointer {
            stage.process($0.baseAddress!, frames: 10_000, pts: nil) { _, count, _ in emitted += count }
        }
        let beforeRebuild = emitted
        #expect(beforeRebuild < 10_000, "the enhancer holds its latency back")
        stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &surround) { _, count, _ in
            emitted += count
        }
        #expect(emitted == 10_000, "every input sample comes out once, none lost at the rebuild")
    }

    @Test("the loudness measurement survives a rebuild, also onto another layout and rate")
    func loudnessCarriesAcrossARebuild() throws {
        var stereo = layout(2), surround = layout(6)
        defer { av_channel_layout_uninit(&stereo); av_channel_layout_uninit(&surround) }
        let shaping = AudioShaping(loudnessTargetLUFS: -16)
        let stage = AudioShapingStage(shaping: shaping, outputFormat: AV_SAMPLE_FMT_FLT)
        stage.configure(sampleRate: Self.rate, outputLayout: &stereo, sourceLayout: &stereo, emit: nil)
        let quiet = sine(frames: Int(Self.rate) * 12, channels: 2, amplitudeDB: -40)
        quiet.withUnsafeBufferPointer { buf in
            var at = 0
            while at < quiet.count / 2 {
                let n = min(1024, quiet.count / 2 - at)
                stage.process(buf.baseAddress! + at * 2, frames: n, pts: nil) { _, _, _ in }
                at += n
            }
        }
        let before = try #require(stage.loudnessGainDB)
        #expect(before > 4, "the quiet source was lifted (\(before) dB)")

        stage.configure(sampleRate: Self.rate, outputLayout: &surround, sourceLayout: &surround) { _, _, _ in }
        let after = try #require(stage.loudnessGainDB)
        #expect(abs(after - before) < 0.01, "the gain stayed at \(before) dB, read \(after) dB")

        stage.configure(sampleRate: 44_100, outputLayout: &surround, sourceLayout: &surround) { _, _, _ in }
        #expect(abs((stage.loudnessGainDB ?? -1) - before) < 0.01)
    }

    @Test("the front-centre helper: mono and stereo have none, 5.1 has index 2, a bare count reads the default order")
    func centreHelper() throws {
        var mono = layout(1), stereo = layout(2), surround = layout(6)
        var bare = AVChannelLayout()
        bare.order = AV_CHANNEL_ORDER_UNSPEC
        bare.nb_channels = 6
        defer { for case var l in [mono, stereo, surround] { av_channel_layout_uninit(&l) } }
        #expect(frontCentreIndex(of: &mono) == nil)
        #expect(frontCentreIndex(of: &stereo) == nil)
        #expect(frontCentreIndex(of: &surround) == 2)
        #expect(frontCentreIndex(of: &bare) == 2)
        #expect(AudioTapDecoder.centreIndex(of: &bare) == 2)
        #expect(AudioShapingMatrix.hasCentre(&surround))
        #expect(!AudioShapingMatrix.hasCentre(&mono))
    }

    @Test("a mono source is lifted by the graph only, never by the matrix as well")
    func monoIsNotLiftedTwice() throws {
        var mono = layout(1), stereo = layout(2)
        defer { av_channel_layout_uninit(&mono); av_channel_layout_uninit(&stereo) }
        let lifted = try #require(AudioShapingMatrix.coefficients(input: &mono, output: &stereo, dialogueGain: 2))
        let plain = try #require(AudioShapingMatrix.coefficients(input: &mono, output: &stereo, dialogueGain: 1))
        #expect(lifted == plain)
    }
}
