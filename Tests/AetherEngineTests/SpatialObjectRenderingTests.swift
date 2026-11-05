// Only with the TrueHDObjectAudio or DTSXObjectAudio trait: the renderer is not built without one.
#if TrueHDObjectAudio || DTSXObjectAudio
import Testing
import Foundation
@testable import AetherEngine

/// The elements of TrueHD Atmos and DTS:X are placed in the layout as point sources, and
/// `BedRegression` builds each speaker from the stream's bed by those places. These pin the two
/// properties a placement cannot get wrong without the room hearing it: an object at a speaker
/// belongs to that speaker alone, and moving an object never changes its loudness.
@Suite("Object audio elements are placed in the speaker layout")
struct SpatialObjectRenderingTests {

    private func power(_ g: [Float]) -> Float { g.reduce(0) { $0 + $1 * $1 } }

    @Test("an object at a speaker's position plays from that speaker alone", arguments: SpatialSpeakerLayout.allCases)
    func objectAtSpeakerIsDiscrete(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        for (channel, speaker) in layout.speakers.enumerated() where !speaker.isLFE {
            panner.pointGains(speaker.position, into: &gains)
            #expect(abs(gains[channel] - 1) < 1e-5, "\(layout.rawValue) \(speaker)")
            #expect(abs(power(gains) - 1) < 1e-5)
        }
    }

    @Test("panning keeps unit power everywhere in the room and never feeds LFE", arguments: SpatialSpeakerLayout.allCases)
    func unitPower(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        var gains: [Float] = []
        let steps: [Float] = [0, 0.13, 0.25, 0.5, 0.61, 0.9, 1]
        for x in steps { for y in steps { for z in steps {
            panner.pointGains(SIMD3(x, y, z), into: &gains)
            #expect(abs(power(gains) - 1) < 1e-4, "\(layout.rawValue) at \(x),\(y),\(z)")
            #expect(gains[layout.lfeIndex] == 0)
        } } }
    }

    @Test("an overhead object in the middle of the room splits evenly across the four tops")
    func overheadCentre() {
        let layout = SpatialSpeakerLayout.l714
        var gains: [Float] = []
        AllocentricPanner(layout: layout).pointGains(SIMD3(0.5, 0.5, 1), into: &gains)
        for (channel, speaker) in layout.speakers.enumerated() {
            #expect(abs(gains[channel] - (speaker.isHeight ? 0.5 : 0)) < 1e-5, "\(speaker)")
        }
    }

    @Test("ceiling speakers sit a quarter of the room in from the walls, as TS 103 448 places them")
    func ceilingTargetsAreInset() {
        let layout = SpatialSpeakerLayout.l714
        let panner = AllocentricPanner(layout: layout)
        let channel = { (speaker: SpatialSpeaker) in layout.speakers.firstIndex(of: speaker)! }
        var gains: [Float] = []
        // Out at the front-left ceiling corner, beyond the targets: the nearest top alone.
        panner.pointGains(SIMD3(0, 0, 1), into: &gains)
        #expect(abs(gains[channel(.topFrontLeft)] - 1) < 1e-5)
        // A third of the way back: mostly the front tops (93%), where corner targets gave 75%.
        panner.pointGains(SIMD3(0.5, 1 / 3, 1), into: &gains)
        let front = power([gains[channel(.topFrontLeft)], gains[channel(.topFrontRight)]])
        #expect(abs(front - 0.933) < 0.001)
    }

    @Test("a 5.1 layout's surrounds sit halfway down the side walls, as TS 103 448 places them",
          arguments: [SpatialSpeakerLayout.l512, .l514])
    func fiveOneSurroundsOnTheSideWalls(layout: SpatialSpeakerLayout) {
        let panner = AllocentricPanner(layout: layout)
        let channel = { (speaker: SpatialSpeaker) in layout.speakers.firstIndex(of: speaker)! }
        var gains: [Float] = []
        // Halfway down the left wall, and at the back-left corner beyond it: the surround alone.
        for y: Float in [0.5, 1] {
            panner.pointGains(SIMD3(0, y, 0), into: &gains)
            #expect(abs(gains[channel(.surroundLeft)] - 1) < 1e-5)
        }
        // A quarter of the way back: an even split with the front, where corner surrounds gave 15%.
        panner.pointGains(SIMD3(0, 0.25, 0), into: &gains)
        #expect(abs(gains[channel(.surroundLeft)] * gains[channel(.surroundLeft)] - 0.5) < 1e-5)
    }

    @Test("height content with no ceiling to go to folds onto the floor")
    func heightFoldsWithoutTops() {
        let layout = SpatialSpeakerLayout.l714
        let tops = Set(layout.speakers.filter(\.isHeight))
        var gains: [Float] = []
        AllocentricPanner(layout: layout, excluded: tops).pointGains(SIMD3(0, 0, 1), into: &gains)
        #expect(abs(gains[layout.speakers.firstIndex(of: .left)!] - 1) < 1e-5)
        #expect(abs(power(gains) - 1) < 1e-5)
    }


    // MARK: - Placement

    /// Element `index`'s gains towards the layout after `updates`.
    private func gains(_ placement: ObjectAudioPlacement, _ index: Int) -> [Float] {
        var snapshot = ObjectAudioGainSnapshot()
        placement.snapshot(into: &snapshot)
        let n = placement.layout.channelCount
        return Array(snapshot.layoutGains[index * n..<(index + 1) * n])
    }

    @Test("bed channels and LFE sit on their speakers")
    func bedOnItsSpeakers() {
        let layout = SpatialSpeakerLayout.l714
        let placement = ObjectAudioPlacement(layout: layout, roles: [.bed(.left), .lfe, .bed(.topMiddleLeft)])
        #expect(gains(placement, 0)[layout.speakers.firstIndex(of: .left)!] == 1)
        #expect(power(gains(placement, 0)) == 1)
        #expect(gains(placement, 1)[layout.lfeIndex] == 1)
        #expect(power(gains(placement, 1)) == 1)
        // 7.1.4 has no top-middle pair: the bed's Ltm becomes a phantom between Ltf and Ltr.
        let ltm = gains(placement, 2)
        #expect(abs(ltm[layout.speakers.firstIndex(of: .topFrontLeft)!] - cos(Float.pi / 4)) < 1e-5)
        #expect(abs(ltm[layout.speakers.firstIndex(of: .topRearLeft)!] - cos(Float.pi / 4)) < 1e-5)
    }

    @Test("an object is placed nowhere until its first metadata, then jumps to each new position")
    func objectFollowsMetadata() {
        let layout = SpatialSpeakerLayout.l714
        let placement = ObjectAudioPlacement(layout: layout, roles: [.object])
        #expect(gains(placement, 0).allSatisfy { $0 == 0 })
        var snapshot = ObjectAudioGainSnapshot()
        placement.snapshot(into: &snapshot)
        #expect(snapshot.positions[0] == nil)

        let l = layout.speakers.firstIndex(of: .left)!, r = layout.speakers.firstIndex(of: .right)!
        placement.apply([.init(frameOffset: 10, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0))])])
        #expect(gains(placement, 0)[l] == 1)
        placement.apply([.init(frameOffset: 0, states: [ObjectAudioElementState(position: SIMD3(1, 0, 0), gain: 0.5)])])
        #expect(gains(placement, 0)[r] == 0.5 && gains(placement, 0)[l] == 0)
        // A restatement that leaves the object out keeps it where it is.
        placement.apply([.init(frameOffset: 0, states: [nil])])
        #expect(gains(placement, 0)[r] == 0.5)
    }

    @Test("a reset forgets object positions and brings beds back at unit gain")
    func resetForgetsObjects() {
        let layout = SpatialSpeakerLayout.l714
        let placement = ObjectAudioPlacement(layout: layout, roles: [.object, .bed(.left)])
        placement.apply([.init(frameOffset: 0, states: [ObjectAudioElementState(position: SIMD3(0, 0, 0)),
                                                        ObjectAudioElementState(gain: 0)])])
        placement.reset()
        #expect(gains(placement, 0).allSatisfy { $0 == 0 })
        #expect(gains(placement, 1)[layout.speakers.firstIndex(of: .left)!] == 1)
    }

    @Test("7.1 bed surrounds sit on a 5.1 layout's surround pair, never in the front", arguments: [
        SpatialSpeakerLayout.l512, .l514])
    func bedSurroundsFoldOnFiveOne(layout: SpatialSpeakerLayout) {
        let placement = ObjectAudioPlacement(layout: layout, roles: [.bed(.sideLeft), .bed(.rearRight)])
        #expect(gains(placement, 0)[layout.speakers.firstIndex(of: .surroundLeft)!] == 1)
        #expect(power(gains(placement, 0)) == 1)
        #expect(gains(placement, 1)[layout.speakers.firstIndex(of: .surroundRight)!] == 1)
        #expect(power(gains(placement, 1)) == 1)
    }

    @Test("a 5.1 bed's surrounds sit on a 7.1 layout's sides")
    func fiveOneSurroundsOnSevenOne() {
        let layout = SpatialSpeakerLayout.l714
        let placement = ObjectAudioPlacement(layout: layout, roles: [.bed(.surroundLeft)])
        #expect(gains(placement, 0)[layout.speakers.firstIndex(of: .sideLeft)!] == 1)
    }

    @Test("a bed channel at a position the room names no speaker for is placed without any metadata")
    func fixedBedWithoutMetadata() {
        let layout = SpatialSpeakerLayout.l714
        let placement = ObjectAudioPlacement(layout: layout, roles: [.fixed(SIMD3(0.5, 1, 0))])
        let g = gains(placement, 0)
        let half = cos(Float.pi / 4)
        #expect(abs(g[layout.speakers.firstIndex(of: .rearLeft)!] - half) < 1e-5)
        #expect(abs(g[layout.speakers.firstIndex(of: .rearRight)!] - half) < 1e-5)
        #expect(abs(power(g) - 1) < 1e-5)
    }
}
#endif
