import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// 3D sources (`StereoVideoSignal`): which signal a source gets, the `vexu` box Apple's own writer
/// produces for a packed frame, its place in the init segment, and the master's REQ-VIDEO-LAYOUT.
@Suite("Stereo video signal")
struct StereoVideoSignalTests {

    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + Array(type.utf8) + payload }
    private func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }

    private func resolve(_ presentation: StereoPresentation, _ codec: AVCodecID = AV_CODEC_ID_HEVC,
                         multilayer: Bool = false, container: (AVStereo3DType, Bool)? = nil,
                         stereoSystem: Bool = true) -> StereoVideoSignal? {
        StereoVideoSignal.resolve(presentation: presentation, codecID: codec, multilayer: multilayer,
                                  containerStereo: container.map { (type: $0.0, inverted: $0.1) },
                                  systemPresentsStereo: stereoSystem).signal
    }

    @Test("an MV-HEVC stream keeps its second view, and the container's packing is presented")
    func automatic() {
        #expect(resolve(.automatic, multilayer: true) == .multiview)
        #expect(resolve(.automatic, container: (AV_STEREO3D_SIDEBYSIDE, false))
                == .framePacked(.init(kind: .sideBySide, reversed: false)))
        #expect(resolve(.automatic, container: (AV_STEREO3D_TOPBOTTOM, true))
                == .framePacked(.init(kind: .overUnder, reversed: true)))
        #expect(resolve(.automatic) == nil)
        #expect(resolve(.automatic, container: (AV_STEREO3D_FRAMESEQUENCE, false)) == nil)
    }

    @Test("the host's choice wins: a name says side by side, or the user wants 2D")
    func hostChoice() {
        #expect(resolve(.sideBySide) == .framePacked(.init(kind: .sideBySide, reversed: false)))
        #expect(resolve(.overUnder, container: (AV_STEREO3D_SIDEBYSIDE, false))
                == .framePacked(.init(kind: .overUnder, reversed: false)))
        #expect(resolve(.mono, multilayer: true) == nil)
        #expect(resolve(.mono, container: (AV_STEREO3D_SIDEBYSIDE, false)) == nil)
    }

    @Test("frame packing is HEVC only, and only a system that shows stereo gets any signal")
    func gates() {
        // AVPlayer refuses a packed H.264 init over HLS (-12927, visionOS 27 simulator): 2D instead of an error.
        #expect(resolve(.sideBySide, AV_CODEC_ID_H264) == nil)
        #expect(resolve(.automatic, AV_CODEC_ID_H264, container: (AV_STEREO3D_SIDEBYSIDE, false)) == nil)
        #expect(resolve(.automatic, multilayer: true, stereoSystem: false) == nil)
        #expect(resolve(.sideBySide, stereoSystem: false) == nil)
    }

    @Test("the vexu box is the one AVAssetWriter writes for ViewPackingKind")
    func appleLayout() {
        // AVAssetWriter, macOS 27: ViewPackingKind SideBySide + HasLeft/RightStereoEyeView on an avc1 entry.
        let apple = "000000357665787500000015657965730000000d737472690000000003000000187061636b00000010706b696e0000000073696465"
        let side = StereoVideoSignal.viewPackingBox(.init(kind: .sideBySide, reversed: false))
        #expect(side.map { String(format: "%02x", $0) }.joined() == apple)
        let over = StereoVideoSignal.viewPackingBox(.init(kind: .overUnder, reversed: true))
        #expect(Array(over[49...]) == Array("over".utf8))
        #expect(over[28] == 0x0B)   // both eyes, eye_views_reversed
    }

    @Test("the init's video entry gains the vexu, loses the source's st3d, and every ancestor size follows")
    func installsInVideoEntry() throws {
        let hvcC = box("hvcC", [UInt8](repeating: 1, count: 30))
        let entry = box("hvc1", [UInt8](repeating: 0, count: 78) + hvcC + box("st3d", [0, 0, 0, 0, 2])
            + box("pasp", [0, 0, 0, 1, 0, 0, 0, 1]))
        let videoTrak = box("trak", box("tkhd", [UInt8](repeating: 0, count: 84))
            + box("mdia", box("mdhd", [UInt8](repeating: 0, count: 24))
                + box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("vide".utf8) + [UInt8](repeating: 0, count: 13))
                + box("minf", box("vmhd", [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
                    + box("stbl", box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + entry) + box("stts", [0, 0, 0, 0, 0, 0, 0, 0])))))
        let soundTrak = box("trak", box("mdia", box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("soun".utf8) + [0])))
        let initBytes = box("ftyp", Array("iso5".utf8) + [0, 0, 0, 1])
            + box("moov", box("mvhd", [UInt8](repeating: 0, count: 100)) + soundTrak + videoTrak + box("mvex", []))

        let packing = StereoVideoSignal.FramePacking(kind: .sideBySide, reversed: false)
        let b = [UInt8](try #require(StereoVideoSignal.installingViewPacking(packing, in: Data(initBytes))))
        let vexu = StereoVideoSignal.viewPackingBox(packing)
        #expect(b.count == initBytes.count + vexu.count - 13)

        func children(_ start: Int, _ end: Int) -> [(type: String, start: Int, end: Int)] {
            var o = start, out: [(String, Int, Int)] = []
            while o + 8 <= end { let s = u32(b, o); out.append((String(bytes: b[o + 4..<o + 8], encoding: .ascii)!, o, o + s)); o += s }
            #expect(o == end)
            return out.map { (type: $0.0, start: $0.1, end: $0.2) }
        }
        func child(_ parent: (type: String, start: Int, end: Int), _ type: String) throws -> (type: String, start: Int, end: Int) {
            try #require(children(parent.start + 8, parent.end).first { $0.type == type })
        }
        let moov = try #require(children(0, b.count).first { $0.type == "moov" })
        let traks = children(moov.start + 8, moov.end).filter { $0.type == "trak" }
        #expect(traks.count == 2)
        #expect(Array(b[traks[0].start..<traks[0].end]) == soundTrak)
        let stsd = try child(child(child(child(traks[1], "mdia"), "minf"), "stbl"), "stsd")
        let hvc1 = try #require(children(stsd.start + 16, stsd.end).first)
        #expect(hvc1.type == "hvc1" && hvc1.end == stsd.end)
        #expect(children(hvc1.start + 86, hvc1.end).map(\.type) == ["hvcC", "pasp", "vexu"])
        #expect(Array(b[(hvc1.end - vexu.count)..<hvc1.end]) == vexu)
    }

    @Test("an init with no video entry is left alone")
    func noVideoEntry() {
        let soundOnly = box("moov", box("trak", box("mdia", box("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("soun".utf8) + [0]))))
        #expect(StereoVideoSignal.installingViewPacking(.init(kind: .sideBySide, reversed: false), in: Data(soundOnly)) == nil)
    }

    @Test("a stereo master declares CH-STEREO at version 12; a 2D one stays as it was")
    func master() {
        let stereo = HLSLocalServer.buildMasterPlaylistText(provider: LayoutMockProvider(layout: "CH-STEREO"))
        #expect(stereo.contains("#EXT-X-VERSION:12"))
        #expect(stereo.contains("REQ-VIDEO-LAYOUT=\"CH-STEREO\""))
        let flat = HLSLocalServer.buildMasterPlaylistText(provider: LayoutMockProvider(layout: nil))
        #expect(flat.contains("#EXT-X-VERSION:7"))
        #expect(!flat.contains("REQ-VIDEO-LAYOUT"))
    }
}

private final class LayoutMockProvider: HLSSegmentProvider, @unchecked Sendable {
    let layout: String?
    init(layout: String?) { self.layout = layout }
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.1.6.L120.90,mp4a.40.2" }
    var masterVideoRange: HLSVideoRange? { .sdr }
    var masterVideoLayout: String? { layout }
}
