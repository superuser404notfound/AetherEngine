import Testing
import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The rendered object-audio bed can leave the engine as 24-bit PCM instead of APAC. What has to hold:
/// the samples survive bit for bit within 24 bits, the channels keep the bed's order and are described
/// so AVFoundation reads the CoreAudio Atmos layout back, and `.render` chooses PCM everywhere but on
/// an AirPlay route.
@Suite("Rendered bed as PCM")
struct RenderedBedAsPCMTests {

    @Test("samples are interleaved as signed 24-bit little endian, rounded and clamped to full scale")
    func interleavesSigned24() {
        let a = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        let b = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        defer { a.deallocate(); b.deallocate() }
        a.update(from: [0.5, 1.5, 0], count: 3)
        b.update(from: [-1, -0.5, 1.0 / 8_388_608], count: 3)
        let data = [UInt8](PCMBedPacker.interleave([a, b], from: 0, frames: 3))
        #expect(data == [
            0x00, 0x00, 0x40, 0x00, 0x00, 0x80,
            0xFF, 0xFF, 0x7F, 0x00, 0x00, 0xC0,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        ])
    }

    @Test("a submit comes back as 1024-frame packets on their own first frames, the last one shorter")
    func packetsStampedPerFrame() {
        let packer = PCMBedPacker(channels: 2, bufferFrames: 4096)
        let buffer = packer.takeInitialBuffer()
        _ = packer.submit(buffer, frames: 2548, position: 10_000)
        let packets = packer.collect().packets
        #expect(packets.map(\.pts) == [10_000, 11_024, 12_048])
        #expect(packets.map(\.frames) == [1024, 1024, 500])
        #expect(packets.map(\.data.count) == [1024 * 6, 1024 * 6, 500 * 6])
        #expect(packets.allSatisfy { $0.isSync })
        #expect(packer.collect().packets.isEmpty)
    }

    @Test("the codec parameters carry the bed's own channel order", arguments: SpatialSpeakerLayout.allCases)
    func codecparKeepsBedOrder(layout: SpatialSpeakerLayout) throws {
        let cp = try #require(PCMBedPacker.makeCodecpar(layout: layout, sampleRate: 48_000))
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = cp; avcodec_parameters_free(&p) }
        #expect(cp.pointee.codec_id == AV_CODEC_ID_PCM_S24LE)
        #expect(Int(cp.pointee.ch_layout.nb_channels) == layout.channelCount)
        #expect(cp.pointee.ch_layout.order == AV_CHANNEL_ORDER_CUSTOM)
        let ids = (0..<layout.channelCount).map { cp.pointee.ch_layout.u.map[$0].id }
        #expect(ids == layout.speakers.map(\.avChannel))
    }

    @Test("the renderer's format is packed 24-bit PCM tagged with the bed's CoreAudio layout",
          arguments: SpatialSpeakerLayout.allCases)
    func formatDescriptionCarriesLayout(layout: SpatialSpeakerLayout) throws {
        let description = try #require(PCMBedPacker.formatDescription(layout: layout, sampleRate: 48_000))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatLinearPCM)
        #expect(Int(asbd.mChannelsPerFrame) == layout.channelCount)
        #expect(asbd.mBitsPerChannel == 24 && Int(asbd.mBytesPerFrame) == layout.channelCount * 3)
        var size = 0
        let acl = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size))
        #expect(acl.pointee.mChannelLayoutTag == layout.channelLayoutTag)
    }

    @Test("render picks PCM unless an AirPlay port is in the route; apac and lpcm are fixed")
    func bedFormatByRoute() {
        #expect(SpatialBedFormat.forRoute(portTypes: ["HDMIOutput"]) == .lpcm)
        #expect(SpatialBedFormat.forRoute(portTypes: ["BluetoothA2DPOutput"]) == .lpcm)
        #expect(SpatialBedFormat.forRoute(portTypes: []) == .lpcm)
        #expect(SpatialBedFormat.forRoute(portTypes: ["HDMIOutput", "AirPlay"]) == .apac)
        #expect(ObjectAudioRendering.render(.l916).bedFormat(routeFormat: .lpcm) == .lpcm)
        #expect(ObjectAudioRendering.render(.l916).bedFormat(routeFormat: .apac) == .apac)
        #expect(ObjectAudioRendering.apac(.l916).bedFormat(routeFormat: .lpcm) == .apac)
        #expect(ObjectAudioRendering.lpcm(.l714).bedFormat(routeFormat: .apac) == .lpcm)
        #expect(ObjectAudioRendering.off.bedFormat(routeFormat: .lpcm) == nil)
        #expect(ObjectAudioRendering.render(.l916).layout == .l916)
        #expect(ObjectAudioRendering.lpcm(.l714).layout == .l714)
    }

    @Test("the software host renders TrueHD Atmos into a PCM bed when the route takes PCM")
    func softwareRouteTakesPCMBed() {
        let expected: SoftwareAtmosRoute = AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn
            ? .pcmBed(.l916) : .pcm
        #expect(SoftwareAtmosRoute.route(
            codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, sampleRate: 48_000, channels: 8,
            framesPerPacket: 0, isLive: false, rendering: .render(.l916), confirmedJOC: false,
            osSupportsAPAC: true, routeFormat: .lpcm) == expected)
        #expect(SoftwareAtmosRoute.pcmBed(.l916).carriesDolbyAtmos(sourceCodec: AV_CODEC_ID_TRUEHD))
        #expect(!SoftwareAtmosRoute.pcmBed(.l916).carriesDolbyAtmos(sourceCodec: AV_CODEC_ID_DTS))
        #expect(AetherEngine.softwareAudioDecoderLabel(
            audioTracks: [TrackInfo(id: 1, name: "", codec: "truehd", language: nil, isDefault: true)],
            activeIndex: 1, route: .pcmBed(.l916)) == "TRUEHD Atmos → PCM 9.1.6")
    }
}
