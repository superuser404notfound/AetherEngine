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

    /// A held base picture; `rpu` is what the pairing appended to it.
    private final class Picture {
        let pts: Int64
        var rpu: [UInt8]?
        init(_ pts: Int64) { self.pts = pts }
    }

    private typealias Pairing = DolbyVisionLayerPairing<Picture>
    private static func attach(_ picture: Picture, _ rpu: [UInt8]) -> Bool { picture.rpu = rpu; return true }
    /// One release, outside the expectation macros (they capture their operands immutably).
    private static func next(_ pairing: inout Pairing, atEnd: Bool = false) -> (unit: Picture, paired: Bool)? {
        pairing.release(atEnd: atEnd)
    }
    private static func rpu(_ pts: Int64) -> [UInt8] { [0, 0, 1, 0x7C, 0x01, UInt8(truncatingIfNeeded: pts)] }

    @Test("A base picture waits for the enhancement unit that follows it, then goes out with its RPU")
    func rpuAfterItsPicture() throws {
        var pairing = Pairing()
        pairing.addBase(Picture(10), pts: 10, attach: Self.attach)
        #expect(Self.next(&pairing) == nil)
        pairing.addRPU(Self.rpu(10), pts: 10, attach: Self.attach)
        let out = try #require(Self.next(&pairing))
        #expect(out.paired && out.unit.pts == 10 && out.unit.rpu == Self.rpu(10))
        #expect(pairing.heldCount == 0)
    }

    @Test("With a tolerance, times that differ by rounding pair; further apart or unknown ones never do")
    func toleranceMatchesRoundedTimes() throws {
        var pairing = Pairing(tolerance: 2_000)
        // The base track counts 1/16000 s, the enhancement track 1/24000: the same picture lands 1 us and 1.3 ms apart.
        pairing.addBase(Picture(41_708), pts: 41_708, attach: Self.attach)
        pairing.addRPU(Self.rpu(1), pts: 41_709, attach: Self.attach)
        pairing.addRPU(Self.rpu(2), pts: 83_417 + 1_300, attach: Self.attach)
        pairing.addBase(Picture(83_417), pts: 83_417, attach: Self.attach)
        let first = try #require(Self.next(&pairing)), second = try #require(Self.next(&pairing))
        #expect(first.paired && first.unit.rpu == Self.rpu(1))
        #expect(second.paired && second.unit.rpu == Self.rpu(2))
        // Further than the tolerance, or without a time: no pair.
        pairing.addBase(Picture(125_000), pts: 125_000, attach: Self.attach)
        pairing.addRPU(Self.rpu(3), pts: 125_000 + 3_000, attach: Self.attach)
        pairing.addBase(Picture(Int64.min), pts: Int64.min, attach: Self.attach)
        pairing.addRPU(Self.rpu(4), pts: Int64.min, attach: Self.attach)
        #expect(Self.next(&pairing) == nil)
        let rest = pairing.drain()
        #expect(rest.count == 2 && rest.allSatisfy { $0.rpu == nil })
    }

    @Test("An RPU that comes before its picture is attached when the picture arrives")
    func rpuBeforeItsPicture() throws {
        var pairing = Pairing()
        pairing.addRPU(Self.rpu(20), pts: 20, attach: Self.attach)
        pairing.addBase(Picture(20), pts: 20, attach: Self.attach)
        let out = try #require(Self.next(&pairing))
        #expect(out.paired && out.unit.rpu == Self.rpu(20))
    }

    @Test("Pictures leave in read order: a later picture's RPU does not let it overtake an earlier one")
    func readOrderHolds() throws {
        var pairing = Pairing()
        pairing.addBase(Picture(1), pts: 1, attach: Self.attach)
        pairing.addBase(Picture(2), pts: 2, attach: Self.attach)
        pairing.addRPU(Self.rpu(2), pts: 2, attach: Self.attach)
        #expect(Self.next(&pairing) == nil)
        pairing.addRPU(Self.rpu(1), pts: 1, attach: Self.attach)
        #expect(try #require(Self.next(&pairing)).unit.pts == 1)
        #expect(try #require(Self.next(&pairing)).unit.pts == 2)
    }

    @Test("Past the hold limit the oldest picture goes out without an RPU, so a missing enhancement unit stalls nothing")
    func holdLimitReleasesUnpaired() throws {
        var pairing = Pairing()
        for pts in 0..<Int64(Pairing.holdLimit) { pairing.addBase(Picture(pts), pts: pts, attach: Self.attach) }
        #expect(Self.next(&pairing) == nil)
        pairing.addBase(Picture(99), pts: 99, attach: Self.attach)
        let out = try #require(Self.next(&pairing))
        #expect(!out.paired && out.unit.pts == 0 && out.unit.rpu == nil)
        #expect(Self.next(&pairing) == nil)
    }

    @Test("A chunk-interleaved file holds a whole chunk of base pictures before the first RPU arrives, and pairs every one")
    func chunkInterleavedPairsAll() throws {
        var pairing = Pairing()
        let step: Int64 = 16_667  // 60 fps, one second of base pictures first, then one second of enhancement units
        let pts = (0..<60).map { Int64($0) * step }
        for p in pts {
            pairing.addBase(Picture(p), pts: p, attach: Self.attach)
            #expect(Self.next(&pairing) == nil, "no picture may go out unpaired inside the chunk")
        }
        for p in pts { pairing.addRPU(Self.rpu(p), pts: p, attach: Self.attach) }
        for p in pts {
            let out = try #require(Self.next(&pairing))
            #expect(out.paired && out.unit.pts == p && out.unit.rpu != nil)
        }
        #expect(Self.next(&pairing) == nil)
    }

    @Test("Pictures spanning more than the hold span release the oldest unpaired, however few are held")
    func spanReleasesUnpaired() throws {
        var pairing = Pairing()
        pairing.addBase(Picture(0), pts: 0, attach: Self.attach)
        pairing.addBase(Picture(DolbyVisionLayerPairing<Picture>.holdSpan), pts: DolbyVisionLayerPairing<Picture>.holdSpan, attach: Self.attach)
        #expect(Self.next(&pairing) == nil)
        pairing.addBase(Picture(DolbyVisionLayerPairing<Picture>.holdSpan + 1), pts: DolbyVisionLayerPairing<Picture>.holdSpan + 1, attach: Self.attach)
        let out = try #require(Self.next(&pairing))
        #expect(!out.paired && out.unit.pts == 0)
    }

    @Test("At the end of the source the last pictures go out whether paired or not")
    func endReleasesEverything() throws {
        var pairing = Pairing()
        pairing.addBase(Picture(1), pts: 1, attach: Self.attach)
        pairing.addBase(Picture(2), pts: 2, attach: Self.attach)
        #expect(try #require(Self.next(&pairing, atEnd: true)).unit.pts == 1)
        #expect(try #require(Self.next(&pairing, atEnd: true)).unit.pts == 2)
        #expect(Self.next(&pairing, atEnd: true) == nil)
    }

    @Test("A drain (seek, reopen, close) hands back every held picture and forgets the early RPUs")
    func drainForgetsEverything() {
        var pairing = Pairing()
        pairing.addBase(Picture(1), pts: 1, attach: Self.attach)
        pairing.addRPU(Self.rpu(5), pts: 5, attach: Self.attach)
        let drained = pairing.drain().map(\.pts)
        #expect(drained == [1])
        let after = Picture(5)
        pairing.addBase(after, pts: 5, attach: Self.attach)
        #expect(after.rpu == nil)
    }

    @Test("A failed append leaves the picture unpaired, so it waits for the limit instead of going out as paired")
    func failedAppendStaysUnpaired() {
        var pairing = Pairing()
        pairing.addBase(Picture(1), pts: 1, attach: Self.attach)
        pairing.addRPU(Self.rpu(1), pts: 1) { _, _ in false }
        #expect(Self.next(&pairing) == nil)
    }
}
