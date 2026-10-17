import Foundation
import Testing
@testable import AetherEngine

// A UHD Blu-ray's Dolby Vision is two PIDs in one clip; the base layer gets the enhancement layer's RPUs.
@Suite("Blu-ray Dolby Vision layer fold")
struct BluRayDolbyVisionLayerFoldTests {

    /// An enhancement-layer access unit as the disc carries it: AUD, a slice, then the RPU (unspec62), Annex-B.
    private static let enhancementUnit: [UInt8] =
        [0, 0, 0, 1, 0x46, 0x01, 0x50]                         // AUD (type 35)
        + [0, 0, 1, 0x02, 0x01, 0xAA, 0xBB, 0xCC]               // TRAIL_R slice (type 1)
        + [0, 0, 0, 1, 0x7C, 0x01, 0x19, 0x08, 0x09, 0x80]      // RPU (type 62), stop bit
        + [0, 0]                                                // padding before the next unit

    @Test("The RPU comes out with its own start code and without trailing zeros")
    func rpuIsExtracted() throws {
        let rpu = try #require(Self.enhancementUnit.withUnsafeBytes { BluRayDolbyVisionLayers.rpu(inAnnexB: $0) })
        #expect(rpu == [0, 0, 1, 0x7C, 0x01, 0x19, 0x08, 0x09, 0x80])
    }

    @Test("A unit without an RPU gives none")
    func noRPU() {
        let unit: [UInt8] = [0, 0, 0, 1, 0x46, 0x01, 0x50, 0, 0, 1, 0x02, 0x01, 0xAA]
        #expect(unit.withUnsafeBytes { BluRayDolbyVisionLayers.rpu(inAnnexB: $0) } == nil)
    }

    @Test("The level follows the luma sample rate: UHD at 23.976 is 6, at 60 is 9, 1080p24 is 3")
    func levels() {
        #expect(BluRayDolbyVisionLayers.level(width: 3840, height: 2160, fps: 24000.0 / 1001) == 6)
        #expect(BluRayDolbyVisionLayers.level(width: 3840, height: 2160, fps: 24) == 6)
        #expect(BluRayDolbyVisionLayers.level(width: 3840, height: 2160, fps: 60) == 9)
        #expect(BluRayDolbyVisionLayers.level(width: 1920, height: 1080, fps: 24) == 3)
    }
}
