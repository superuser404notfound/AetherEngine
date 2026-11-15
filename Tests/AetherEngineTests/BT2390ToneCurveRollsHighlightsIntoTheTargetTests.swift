import Foundation
import Testing
@testable import AetherEngine

/// AE#957: the BT.2390 tone curve the tone-map stage runs. Below the knee nothing changes; above it the rest
/// of the source range rolls off into the target's top, with no step and no reversal; the source peak lands on
/// the target peak. The mapped picture's metadata says what the display now gets.
@Suite("BT.2390 tone curve rolls highlights into the target (AE#957)")
struct BT2390ToneCurveRollsHighlightsIntoTheTargetTests {

    private static let master = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                                    masteringMinNits: 0.005)

    @Test func issue957PQMatchesST2084() {
        #expect(abs(BT2390ToneCurve.pq(nits: 100) - 0.508078) < 1e-5)
        #expect(abs(BT2390ToneCurve.pq(nits: 1000) - 0.751827) < 1e-5)
        #expect(BT2390ToneCurve.pq(nits: 10_000) == 1)
        for nits in [0.005, 1, 100, 464, 1000, 4000] {
            #expect(abs(BT2390ToneCurve.nits(pq: BT2390ToneCurve.pq(nits: nits)) - nits) < nits * 1e-9 + 1e-9)
        }
    }

    @Test func issue957NothingBelowTheKneeChanges() throws {
        let curve = try #require(BT2390ToneCurve(sourcePeakNits: 1000, targetPeakNits: 600))
        let kneePQ = curve.kneeStart * curve.sourcePeakPQ
        #expect(BT2390ToneCurve.nits(pq: kneePQ).rounded() == 464)
        for e in stride(from: 0.0, to: kneePQ, by: 0.01) {
            #expect(curve.map(pq: e) == e)
        }
    }

    @Test(arguments: [(1000.0, 600.0), (4000.0, 800.0), (10_000.0, 100.0), (1000.0, 6.0)])
    func issue957TheSourcePeakLandsOnTheTargetWithoutAStep(source: Double, target: Double) throws {
        let curve = try #require(BT2390ToneCurve(sourcePeakNits: source, targetPeakNits: target))
        #expect(abs(curve.map(nits: source) - target) < target * 1e-9)
        #expect(abs(curve.map(nits: 10_000) - target) < target * 1e-9, "above the source peak: the target")
        // Rising everywhere, and no jump at the knee (steps of 1/4096 move the output by less than 1/1024).
        var previous = curve.map(pq: 0)
        for i in 1 ... 4096 {
            let now = curve.map(pq: Double(i) / 4096)
            #expect(now >= previous)
            #expect(now - previous < 1.0 / 1024)
            previous = now
        }
        #expect(curve.kneeStart >= 0)
    }

    @Test func issue957NoCurveWhenThereIsNothingToMap() {
        #expect(BT2390ToneCurve(sourcePeakNits: 600, targetPeakNits: 600) == nil)
        #expect(BT2390ToneCurve(sourcePeakNits: 500, targetPeakNits: 600) == nil)
        #expect(BT2390ToneCurve(sourcePeakNits: 1000, targetPeakNits: 0) == nil)
        #expect(BT2390ToneCurve(sourcePeakNits: 20_000, targetPeakNits: 600) == nil)
        #expect(BT2390ToneCurve(sourcePeakNits: .nan, targetPeakNits: 600) == nil)
        // Below a third of the source peak on the curve's scale the knee would be negative.
        #expect(BT2390ToneCurve(sourcePeakNits: 1000, targetPeakNits: 5) == nil)
    }

    @Test func issue957TheMappedMetadataSaysWhatTheDisplayGets() throws {
        let curve = try #require(BT2390ToneCurve(sourcePeakNits: 1000, targetPeakNits: 600))
        let out = curve.outputMetadata(from: Self.master)
        #expect(out.masteringPeakNits == 600)
        #expect(out.masteringMinNits == 0.005)
        #expect(out.maxCLL == 600)
        #expect(out.maxFALL == 400, "400 nit is below the 464 nit knee")
        let unknown = curve.outputMetadata(from: HDR10StaticMetadata(maxCLL: 0, maxFALL: 0, masteringPeakNits: 1000,
                                                                     masteringMinNits: 0.005))
        #expect(unknown.maxCLL == 0 && unknown.maxFALL == 0)
    }

    @Test func issue957MaxCLLSetsThePeakOnlyWhenItIsLower() {
        #expect(ToneMapSourcePeak.choose(masteringPeakNits: 4000, maxCLL: 1200).map { $0.from } == .maxCLL)
        #expect(ToneMapSourcePeak.choose(masteringPeakNits: 4000, maxCLL: 1200).map { $0.nits } == 1200)
        #expect(ToneMapSourcePeak.choose(masteringPeakNits: 1000, maxCLL: 1000).map { $0.from } == .mastering)
        #expect(ToneMapSourcePeak.choose(masteringPeakNits: 1000, maxCLL: 0).map { $0.from } == .mastering)
        #expect(ToneMapSourcePeak.choose(masteringPeakNits: 0, maxCLL: 800).map { $0.from } == .maxCLL)
        #expect(ToneMapSourcePeak.choose(masteringPeakNits: 0, maxCLL: 0) == nil)
        #expect(ToneMapSourcePeak.choose(masteringPeakNits: nil, maxCLL: nil) == nil)
    }

    @Test func issue957AFramesAttachmentsReadBackAsMetadata() {
        let read = HDR10StaticMetadata(masteringDisplayColorVolume: Self.master.masteringDisplayColorVolume,
                                       contentLightLevel: Self.master.contentLightLevel)
        #expect(read == Self.master)
        let lightLevelOnly = HDR10StaticMetadata(masteringDisplayColorVolume: Data([1, 2]),
                                                 contentLightLevel: Self.master.contentLightLevel)
        #expect(lightLevelOnly?.masteringPeakNits == 0 && lightLevelOnly?.maxCLL == 1000)
        #expect(HDR10StaticMetadata(masteringDisplayColorVolume: nil, contentLightLevel: Data([1])) == nil)
    }

    /// The shader's cubic is the same curve: evaluated the shader's way in Float, it stays within a tenth of
    /// a 10-bit code of the reference everywhere, and below the knee it is not used.
    @Test(arguments: [(1000.0, 600.0), (4000.0, 800.0), (10_000.0, 100.0)])
    func issue957TheShadersCubicIsTheSameCurve(source: Double, target: Double) throws {
        let curve = try #require(BT2390ToneCurve(sourcePeakNits: source, targetPeakNits: target))
        let t = FrameChainToneMapParams(curve)
        var worst: Float = 0
        for i in 0 ... 1023 {
            let e = Float(i) / 1023
            let x = min(max(e * t.xScale - t.xOffset, 0), 1)
            let p = ((t.c3 * x + t.c2) * x + t.c1) * x + t.c0
            let mapped = e < t.kneePQ ? e : p
            worst = max(worst, abs(mapped - Float(curve.map(pq: Double(e)))) * 1023)
        }
        #expect(worst < 0.1, "max \(worst) codes")
        #expect(MemoryLayout<FrameChainToneMapParams>.size == 7 * MemoryLayout<Float>.size)
    }

    @Test func issue957TheProbesToneMapModeReadsItsTarget() throws {
        let set = try HDR10ProbeSettings.parse(mode: "chain+tonemap", metadata: nil, target: "800").get()
        #expect(set.mode == .chainToneMap && set.targetPeakNits == 800)
        #expect(set.mode.runsChain && !set.mode.setsMetadata && !set.mode.pulses)
        let fallback = try HDR10ProbeSettings.parse(mode: "chain+tonemap", metadata: nil).get()
        #expect(fallback.targetPeakNits == HDR10ProbeSettings.defaultTargetPeakNits)
        // Only values the host set stand in for a frame without metadata, never the probe's defaults.
        #expect(!set.metadataGiven && !fallback.metadataGiven)
        let standIn = try HDR10ProbeSettings.parse(mode: "chain+tonemap", metadata: "maxcll=1000,maxfall=400,peak=1000",
                                                   target: "600").get()
        #expect(standIn.metadataGiven && standIn.metadata.masteringPeakNits == 1000)
        for bad in ["0", "abc", "20000"] {
            #expect(throws: HDR10ProbeSettings.ParseError.self) {
                _ = try HDR10ProbeSettings.parse(mode: "chain+tonemap", metadata: nil, target: bad).get()
            }
        }
    }
}
