// Only with an object-audio trait: the regression is not built without one.
#if TrueHDObjectAudio || DTSXObjectAudio
import Testing
import Foundation
@testable import AetherEngine

/// The TrueHD bed path builds every output out of the stream's channel presentation, regressed onto
/// the layout through the elements' cross-spectra. These pin the timeline, the LFE, the channel
/// assignment for an element at every speaker of the layout, a 5.1 bed on a 7.1.4 layout, the
/// energy bound that keeps a drifting element from adding energy, and DTS:X's folded heights.
@Suite("Bed regression")
struct BedRegressionTests {

    static let bed71: [ObjectAudioRole] = [.bed(.left), .bed(.right), .bed(.center), .lfe,
                                           .bed(.sideLeft), .bed(.sideRight), .bed(.rearLeft), .bed(.rearRight)]
    static let bed51: [ObjectAudioRole] = [.bed(.left), .bed(.right), .bed(.center), .lfe,
                                           .bed(.sideLeft), .bed(.sideRight)]

    static func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000 - 1000) / 10_000
        }
    }

    static func energy(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } }
    static func silent(_ count: Int) -> [Float] { [Float](repeating: 0, count: count) }

    /// The bed a channel presentation would carry for elements at `positions`: each element panned at
    /// ear level into the bed's speakers.
    static func fold(_ elements: [[Float]], positions: [SIMD3<Float>], bedRoles: [ObjectAudioRole], frames: Int) -> [[Float]] {
        let speakers = bedRoles.compactMap { role -> SpatialSpeaker? in if case .bed(let s) = role { return s }; return nil }
        let bedLayout = SpatialSpeakerLayout.l916
        let panner = AllocentricPanner(layout: bedLayout, excluded: Set(bedLayout.speakers.filter { !speakers.contains($0) }))
        var bed = bedRoles.map { _ in silent(frames) }
        var gains: [Float] = []
        for (e, p) in zip(elements, positions) {
            panner.pointGains(SIMD3(p.x, p.y, 0), into: &gains)
            for (i, role) in bedRoles.enumerated() {
                guard case .bed(let s) = role, let c = bedLayout.speakers.firstIndex(of: s), gains[c] != 0 else { continue }
                for t in 0..<frames { bed[i][t] += gains[c] * e[t] }
            }
        }
        return bed
    }

    static func run(layout: SpatialSpeakerLayout, bedRoles: [ObjectAudioRole], bed: [[Float]],
                    elements: [[Float]], positions: [SIMD3<Float>], frames: Int,
                    folds: [ObjectAudioBedFold] = []) -> [[Float]] {
        let regression = BedRegression(layout: layout, bedRoles: bedRoles, folds: folds)
        if !elements.isEmpty {
            var snapshot = ObjectAudioGainSnapshot()
            snapshot.resize(elements: elements.count, channels: layout.channelCount)
            var gains: [Float] = []
            for (k, p) in positions.enumerated() {
                AllocentricPanner(layout: layout).pointGains(p, into: &gains)
                for c in 0..<layout.channelCount { snapshot.layoutGains[k * layout.channelCount + c] = gains[c] }
                snapshot.positions[k] = p
                snapshot.gains[k] = 1
            }
            regression.setGains(snapshot)
        }
        let out = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { out.forEach { $0.deallocate() } }
        var written = 0, offset = 0
        let bedPointers = bed.map { $0.withUnsafeBufferPointer { UnsafeMutablePointer(mutating: $0.baseAddress!) } }
        let elementPointers = elements.map { $0.withUnsafeBufferPointer { UnsafeMutablePointer(mutating: $0.baseAddress!) } }
        while offset < frames {
            let n = min(40, frames - offset)
            written += regression.process(
                elements: elementPointers.map { UnsafePointer($0 + offset) },
                bed: bedPointers.map { UnsafePointer($0 + offset) }, frameCount: n,
                output: out.map { $0 + written })
            offset += n
        }
        written += regression.drain(output: out.map { $0 + written })
        #expect(written == frames)
        return out.map { Array(UnsafeBufferPointer(start: $0, count: written)) }
    }

    @Test("output frame i is input frame i, the LFE a pure delay, nothing lost at the end",
          arguments: [300, 2047, 2048, 2049, 9_000])
    func timeline(frames: Int) {
        let layout = SpatialSpeakerLayout.l714
        var pulse = Self.silent(frames)
        let at = frames / 2
        pulse[at] = 0.5
        var bed = Self.bed71.map { _ in Self.silent(frames) }
        bed[0] = pulse
        bed[3] = pulse
        // No element: the bed plays where its channels are.
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, elements: [], positions: [], frames: frames)
        let peak = out[0].indices.max { abs(out[0][$0]) < abs(out[0][$1]) }!
        #expect(peak == at)
        #expect(abs(out[0][at] - 0.5) < 1e-3)
        let lfe = out[layout.lfeIndex]
        #expect(lfe.indices.allSatisfy { abs(lfe[$0] - pulse[$0]) < 1e-4 })
    }

    /// Every speaker of 7.1.4 in turn: one element there, the bed its ear-level fold, the output on
    /// that speaker alone. This is the channel assignment test.
    static let speakerCases: [(SpatialSpeakerLayout, SpatialSpeaker)] =
        [SpatialSpeakerLayout.l714, .l916].flatMap { layout in layout.speakers.filter { $0 != .lfe }.map { (layout, $0) } }

    @Test("an element at each speaker of 7.1.4 and 9.1.6 plays from that speaker", arguments: speakerCases)
    func channelAssignment(layout: SpatialSpeakerLayout, speaker: SpatialSpeaker) {
        let frames = 24_000
        let signal = Self.noise(frames, seed: 7)
        let p = speaker.position
        let bed = Self.fold([signal], positions: [p], bedRoles: Self.bed71, frames: frames)
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, elements: [signal], positions: [p], frames: frames)
        let target = layout.speakers.firstIndex(of: speaker)!
        let total = out.map(Self.energy).reduce(0, +)
        #expect(Self.energy(out[target]) / total > 0.97, "\(speaker): \(Self.energy(out[target]) / total)")
        #expect(abs(total / Self.energy(signal) - 1) < 0.1)
    }

    @Test("a 5.1 bed's surround reaches the 7.1.4 side and rear an element sits between")
    func fiveOneBed() {
        let layout = SpatialSpeakerLayout.l714, frames = 24_000
        let signal = Self.noise(frames, seed: 3)
        let p = SIMD3<Float>(0, 1, 0)
        let bed = Self.fold([signal], positions: [p], bedRoles: Self.bed51, frames: frames)
        let out = Self.run(layout: layout, bedRoles: Self.bed51, bed: bed, elements: [signal], positions: [p], frames: frames)
        let rear = layout.speakers.firstIndex(of: .rearLeft)!
        let total = out.map(Self.energy).reduce(0, +)
        #expect(Self.energy(out[rear]) / total > 0.95)
    }

    @Test("two elements on one bed channel, floor and ceiling, separate where their spectra do")
    func floorAndCeiling() {
        let layout = SpatialSpeakerLayout.l714, frames = 48_000
        // Low noise on the floor, high noise overhead: both fold into the bed's left.
        let raw1 = Self.noise(frames, seed: 11), raw2 = Self.noise(frames, seed: 12)
        var low = Self.silent(frames), high = Self.silent(frames)
        var a: Float = 0
        for t in 0..<frames { a = 0.97 * a + 0.03 * raw1[t]; low[t] = a * 8 }
        for t in 1..<frames { high[t] = raw2[t] - raw2[t - 1] }
        let floor = SIMD3<Float>(0, 0, 0), ceiling = SpatialSpeaker.topFrontLeft.position
        let bed = Self.fold([low, high], positions: [floor, ceiling], bedRoles: Self.bed71, frames: frames)
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, elements: [low, high],
                           positions: [floor, ceiling], frames: frames)
        let tfl = layout.speakers.firstIndex(of: .topFrontLeft)!
        #expect(abs(Self.energy(out[0]) / Self.energy(low) - 1) < 0.1)
        #expect(abs(Self.energy(out[tfl]) / Self.energy(high) - 1) < 0.15)
    }

    @Test("an element far louder than the bed cannot add energy")
    func energyBound() {
        let layout = SpatialSpeakerLayout.l714, frames = 24_000
        let signal = Self.noise(frames, seed: 5)
        let p = SpatialSpeaker.topRearRight.position
        let bed = Self.fold([signal], positions: [p], bedRoles: Self.bed71, frames: frames)
        let loud = signal.map { $0 * 6 }
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, elements: [loud], positions: [p], frames: frames)
        let total = out.map(Self.energy).reduce(0, +)
        let bedEnergy = bed.enumerated().filter { $0.offset != 3 }.map { Self.energy($0.element) }.reduce(0, +)
        #expect(total / bedEnergy < Float(BedRegression.energyBounds.upperBound) * 1.05)
    }

    // MARK: - Folded heights (DTS:X)

    static let dtsxHeights: [SpatialSpeaker] = [.topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight]
    static let dtsxUnder: [SpatialSpeaker] = [.left, .right, .rearLeft, .rearRight]
    static let dtsxFolds: [ObjectAudioBedFold] = zip(dtsxHeights.indices, dtsxUnder).map { k, speaker in
        ObjectAudioBedFold(element: k, plane: bed71.firstIndex(of: .bed(speaker))!, gain: 23170 / 32768)
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        var ab: Float = 0
        for i in a.indices { ab += a[i] * b[i] }
        return ab / (energy(a) * energy(b)).squareRoot()
    }

    /// The bed DTS:X carries: every bed channel `floor`, each height folded at -3 dB into the one under it.
    static func dtsxBed(floor: [[Float]], heights: [[Float]]) -> [[Float]] {
        var bed = floor
        for fold in dtsxFolds {
            for t in bed[fold.plane].indices { bed[fold.plane][t] += fold.gain * heights[fold.element][t] }
        }
        return bed
    }

    static let foldCases: [(SpatialSpeakerLayout, Int)] = [SpatialSpeakerLayout.l714, .l916].flatMap { l in (0..<4).map { (l, $0) } }

    @Test("a folded height plays overhead and leaves the floor under it on its speaker", arguments: foldCases)
    func foldedHeight(layout: SpatialSpeakerLayout, height: Int) {
        let frames = 48_000
        // Low noise on every floor channel, high noise in one height: both share the bed speaker under it.
        let raw = Self.noise(frames, seed: 21)
        var low = Self.silent(frames), high = Self.silent(frames)
        var a: Float = 0
        for t in 0..<frames { a = 0.97 * a + 0.03 * raw[t]; low[t] = a * 8 }
        let rawHigh = Self.noise(frames, seed: 22)
        for t in 1..<frames { high[t] = rawHigh[t] - rawHigh[t - 1] }
        var floor = Self.bed71.map { _ in Self.silent(frames) }
        let under = Self.dtsxFolds[height].plane
        floor[under] = low
        var heights = (0..<4).map { _ in Self.silent(frames) }
        heights[height] = high
        let bed = Self.dtsxBed(floor: floor, heights: heights)
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, elements: heights,
                           positions: Self.dtsxHeights.map(\.position), frames: frames, folds: Self.dtsxFolds)
        let top = layout.speakers.firstIndex(of: Self.dtsxHeights[height])!
        let below = layout.speakers.firstIndex(of: Self.dtsxUnder[height])!
        // 0.98 is where the two test spectra overlap; the energy and the leak elsewhere are the tight checks.
        #expect(Self.correlation(out[top], high) > 0.97, "\(layout.rawValue) \(Self.dtsxHeights[height])")
        #expect(abs(Self.energy(out[top]) / Self.energy(high) - 1) < 0.05)
        #expect(Self.correlation(out[below], low) > 0.97)
        #expect(abs(Self.energy(out[below]) / Self.energy(low) - 1) < 0.05)
        let elsewhere = out.indices.filter { $0 != top && $0 != below }.map { Self.energy(out[$0]) }.reduce(0, +)
        #expect(elsewhere / (Self.energy(high) + Self.energy(low)) < 1e-3)
    }

    @Test("silent heights leave the bed exactly as coded on its own speakers")
    func silentHeights() {
        let layout = SpatialSpeakerLayout.l714, frames = 24_000
        let floor = Self.bed71.indices.map { Self.noise(frames, seed: 40 + UInt64($0)) }
        let heights = (0..<4).map { _ in Self.silent(frames) }
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: floor, elements: heights,
                           positions: Self.dtsxHeights.map(\.position), frames: frames, folds: Self.dtsxFolds)
        for (plane, role) in Self.bed71.enumerated() {
            let speaker: SpatialSpeaker = role == .lfe ? .lfe : { if case .bed(let s) = role { return s }; return .lfe }()
            let c = layout.speakers.firstIndex(of: speaker)!
            let error = zip(out[c], floor[plane]).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
            #expect(error / Self.energy(floor[plane]) < 1e-6, "\(speaker)")
        }
        for speaker in Self.dtsxHeights {
            #expect(Self.energy(out[layout.speakers.firstIndex(of: speaker)!]) < 1e-9)
        }
    }

    @Test("a height alone keeps its full level: the folded bound allows twice the bed's energy")
    func heightAloneKeepsLevel() {
        let layout = SpatialSpeakerLayout.l714, frames = 24_000
        let high = Self.noise(frames, seed: 9)
        var heights = (0..<4).map { _ in Self.silent(frames) }
        heights[3] = high
        let bed = Self.dtsxBed(floor: Self.bed71.map { _ in Self.silent(frames) }, heights: heights)
        let out = Self.run(layout: layout, bedRoles: Self.bed71, bed: bed, elements: heights,
                           positions: Self.dtsxHeights.map(\.position), frames: frames, folds: Self.dtsxFolds)
        let top = layout.speakers.firstIndex(of: .topRearRight)!
        #expect(abs(Self.energy(out[top]) / Self.energy(high) - 1) < 0.05)
        let total = out.map(Self.energy).reduce(0, +)
        #expect(Self.energy(out[top]) / total > 0.99)
    }
}
#endif

