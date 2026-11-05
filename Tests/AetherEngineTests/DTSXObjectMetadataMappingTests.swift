// Only with the DTSXObjectAudio trait (off by default): the decoder is not built without it.
#if DTSXObjectAudio
import Testing
import Foundation
import AetherLibavutil
@testable import AetherEngine

/// FFmpeg's dca decoder returns DTS:X's standard presentation as 7.1.4 (FFmpegBuild's `x_heights`
/// patch), and `DTSXObjectAudioDecoder` names its channels and the heights' folds into the bed. These
/// pin what a listener would hear wrong: a bed or height channel on the wrong speaker, a height taken
/// out of the wrong bed channel, or a channel outside the twelve slipping through to be panned.
@Suite("DTS:X channels map onto the renderer's speakers")
struct DTSXObjectMetadataMappingTests {

    @Test("bed and height channels route to the matching speaker, LFE to LFE")
    func speakerRoles() {
        let expected: [(AVChannel, ObjectAudioRole)] = [
            (AV_CHAN_FRONT_CENTER, .bed(.center)), (AV_CHAN_FRONT_LEFT, .bed(.left)),
            (AV_CHAN_FRONT_RIGHT, .bed(.right)), (AV_CHAN_SIDE_LEFT, .bed(.sideLeft)),
            (AV_CHAN_SIDE_RIGHT, .bed(.sideRight)), (AV_CHAN_LOW_FREQUENCY, .lfe),
            (AV_CHAN_BACK_LEFT, .bed(.rearLeft)), (AV_CHAN_BACK_RIGHT, .bed(.rearRight)),
            (AV_CHAN_TOP_FRONT_LEFT, .bed(.topFrontLeft)), (AV_CHAN_TOP_FRONT_RIGHT, .bed(.topFrontRight)),
            (AV_CHAN_TOP_BACK_LEFT, .bed(.topRearLeft)), (AV_CHAN_TOP_BACK_RIGHT, .bed(.topRearRight)),
        ]
        #expect(DTSXObjectAudioDecoder.channels.count == expected.count)
        for ((channel, role), (wantChannel, wantRole)) in zip(DTSXObjectAudioDecoder.channels, expected) {
            #expect(channel == wantChannel && role == wantRole, "\(channel.rawValue)")
        }
    }

    @Test("the bed is the first eight channels, the heights the elements, each folded into the one under it")
    func bedAndFolds() {
        #expect(DTSXObjectAudioDecoder.bedRoles == DTSXObjectAudioDecoder.channels.prefix(8).map(\.1))
        #expect(DTSXObjectAudioDecoder.roles == [.bed(.topFrontLeft), .bed(.topFrontRight), .bed(.topRearLeft), .bed(.topRearRight)])
        let under: [ObjectAudioRole] = DTSXObjectAudioDecoder.folds.map { DTSXObjectAudioDecoder.bedRoles[$0.plane] }
        #expect(DTSXObjectAudioDecoder.folds.map(\.element) == [0, 1, 2, 3])
        #expect(under == [.bed(.left), .bed(.right), .bed(.rearLeft), .bed(.rearRight)])
        #expect(DTSXObjectAudioDecoder.folds.allSatisfy { $0.gain == 23170 / 32768 })
    }

    @Test("the standard channels play one to one on 7.1.4 and 9.1.6, and only there")
    func oneToOneLayouts() {
        for layout in SpatialSpeakerLayout.allCases {
            #expect(layout.carriesDTSXOneToOne == (layout == .l714 || layout == .l916), "\(layout.rawValue)")
        }
    }

    @Test("a channel plays at unity on its speaker")
    func channelState() {
        let state = DTSXObjectAudioDecoder.state(for: .bed(.topFrontLeft))
        #expect(state.position == SpatialSpeaker.topFrontLeft.position)
        #expect(state.gain == 1)
        #expect(DTSXObjectAudioDecoder.state(for: .lfe).gain == 1)
    }

    @Test("the decoder opens, takes input and asks for more")
    func decoderLifecycle() throws {
        let decoder = try DTSXObjectAudioDecoder()
        try [UInt8](repeating: 0, count: 64).withUnsafeBytes { try decoder.push($0) }
        #expect(try decoder.nextBlock() == nil)
        decoder.releaseHeldBlocks()
        #expect(try decoder.nextBlock() == nil)
        decoder.reset()
        #expect(decoder.selfResetCount == 0)
    }

    @Test("input with no DTS frame in it gives no verdict, so the session keeps the channel bridge")
    func verdictOnNonDTS() throws {
        let decoder = try DTSXObjectAudioDecoder()
        let garbage = [UInt8](repeating: 0x55, count: 1 << 20)
        #expect(garbage.withUnsafeBytes { decoder.verdict(feeding: $0) } == nil)
    }
}
#endif
