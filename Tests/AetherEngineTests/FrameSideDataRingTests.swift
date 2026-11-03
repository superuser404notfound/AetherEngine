// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import AetherLibavutil
@testable import AetherEngine

@Suite("FrameSideDataRing unit tests")
struct FrameSideDataRingTests {

    @Test("matches within ±300 ticks")
    func matchesWithinTolerance() {
        var ring = FrameSideDataRing()
        let dmNAL: [UInt8] = [0x7C, 0x01, 0x01]
        ring.insert(key: 10_000, params: DoviMetalParams(), dmNAL: dmNAL)

        // Exact match
        #expect(ring.find(key: 10_000) != nil)
        #expect(ring.find(key: 10_000)?.key == 10_000)

        // Positive boundary: +300 ticks
        #expect(ring.find(key: 10_300) != nil)
        #expect(ring.find(key: 10_300)?.key == 10_000)

        // Negative boundary: -300 ticks
        #expect(ring.find(key: 9_700) != nil)
        #expect(ring.find(key: 9_700)?.key == 10_000)

        // Intermediate offset: +150 ticks
        #expect(ring.find(key: 10_150) != nil)
        #expect(ring.find(key: 10_150)?.key == 10_000)
    }

    @Test("misses at 301 ticks")
    func missesAt301() {
        var ring = FrameSideDataRing()
        ring.insert(key: 10_000, params: DoviMetalParams(), dmNAL: [0x01])

        // +301 ticks: strictly outside ±300 tolerance
        #expect(ring.find(key: 10_301) == nil)

        // -301 ticks: strictly outside ±300 tolerance
        #expect(ring.find(key: 9_699) == nil)

        // Far away
        #expect(ring.find(key: 20_000) == nil)
    }

    @Test("overwrites the oldest entry when capacity 32 is exceeded")
    func overwritesOldest() {
        var ring = FrameSideDataRing()
        #expect(FrameSideDataRing.capacity == 32)

        // Insert 32 items, keys 1_000, 2_000, ..., 32_000 (well separated, > 300 apart)
        for i in 1...32 {
            ring.insert(key: Int64(i * 1_000), params: DoviMetalParams(), dmNAL: [UInt8(i)])
        }

        #expect(ring.count == 32)
        #expect(ring.find(key: 1_000) != nil)
        #expect(ring.find(key: 32_000) != nil)

        // Insert 33rd item: key 33_000
        ring.insert(key: 33_000, params: DoviMetalParams(), dmNAL: [33])

        // Total count stays capped at 32
        #expect(ring.count == 32)

        // The oldest entry (key 1_000) was overwritten and is now gone
        #expect(ring.find(key: 1_000) == nil)

        // Key 2_000 is now the oldest surviving entry
        #expect(ring.find(key: 2_000) != nil)

        // Key 33_000 is present
        #expect(ring.find(key: 33_000) != nil)
    }

    @Test("selects nearest entry when multiple entries are within ±300 ticks")
    func selectsNearest() {
        var ring = FrameSideDataRing()
        ring.insert(key: 1_000, params: DoviMetalParams(), dmNAL: [1])
        ring.insert(key: 1_200, params: DoviMetalParams(), dmNAL: [2])

        // Query 1_050: distance to 1_000 is 50, distance to 1_200 is 150 -> selects 1_000
        #expect(ring.find(key: 1_050)?.key == 1_000)

        // Query 1_180: distance to 1_200 is 20, distance to 1_000 is 180 -> selects 1_200
        #expect(ring.find(key: 1_180)?.key == 1_200)

        // Query 1_100: exact midpoint (distance 100 to both) -> picks first encountered
        #expect(ring.find(key: 1_100) != nil)
    }

    @Test("display metadata and parameters can be removed independently")
    func independentRemoval() {
        var ring = FrameSideDataRing()
        let nal: [UInt8] = [0x7C, 0x01, 0xAA]
        ring.insert(key: 5_000, params: DoviMetalParams(), dmNAL: nal)

        #expect(ring.dmNALCount == 1)
        #expect(ring.paramsCount == 1)

        // Remove display metadata first
        let extractedNAL = ring.removeDisplayMetadata(key: 5_050)
        #expect(extractedNAL == nal)
        #expect(ring.dmNALCount == 0)
        #expect(ring.paramsCount == 1)

        // Second removal of display metadata returns nil
        #expect(ring.removeDisplayMetadata(key: 5_000) == nil)

        // Parameters are still intact and can be removed
        let extractedParams = ring.removeParams(key: 4_950)
        #expect(extractedParams != nil)
        #expect(ring.paramsCount == 0)

        // Second removal of parameters returns nil
        #expect(ring.removeParams(key: 5_000) == nil)
    }

    @Test("inserting for identical key updates in place without consuming a slot")
    func inPlaceUpdate() {
        var ring = FrameSideDataRing()
        ring.insert(key: 5_000, params: DoviMetalParams(), dmNAL: nil)
        #expect(ring.count == 1)
        #expect(ring.paramsCount == 1)
        #expect(ring.dmNALCount == 0)

        let nal: [UInt8] = [0x7C, 0x01, 0xBB]
        ring.insert(key: 5_000, params: nil, dmNAL: nal)
        #expect(ring.count == 1)
        #expect(ring.paramsCount == 1)
        #expect(ring.dmNALCount == 1)

        #expect(ring.removeDisplayMetadata(key: 5_000) == nal)
        #expect(ring.removeParams(key: 5_000) != nil)
    }

    @Test("removeAll clears all entries")
    func removeAll() {
        var ring = FrameSideDataRing()
        ring.insert(key: 1_000, params: DoviMetalParams(), dmNAL: [1])
        ring.insert(key: 2_000, params: DoviMetalParams(), dmNAL: [2])
        #expect(!ring.isEmpty)
        #expect(ring.count == 2)

        ring.removeAll()
        #expect(ring.isEmpty)
        #expect(ring.count == 0)
        #expect(ring.paramsCount == 0)
        #expect(ring.dmNALCount == 0)
        #expect(ring.find(key: 1_000) == nil)
    }

    @Test("keys from a 1/1000 time base are rescaled to 90 kHz before they reach the ring, so frames do not share side data")
    func millisecondTimeBaseKeysAreCanonical() {
        // 24 fps in Matroska's 1/1000: frames at 0, 41.7, 83.3, 125 ms round to these raw ticks.
        let tb = AVRational(num: 1, den: 1000)
        let raw: [Int64] = [0, 42, 83, 125]
        let keys = raw.map { DualLayerVideoDecoder.canonicalKey(rawPTS: $0, timeBase: tb) }
        // 90 ticks per millisecond
        #expect(keys == [0, 3_780, 7_470, 11_250])
        // Raw millisecond values would sit inside one ±300 window of each other's neighbours' scale
        // (42 ms apart < 300); the canonical keys are 3 000+ ticks apart, outside the window.
        #expect(FrameSideDataRing.isWithinJitter(raw[0], raw[1]))
        #expect(!FrameSideDataRing.isWithinJitter(keys[0], keys[1]))

        var ring = FrameSideDataRing()
        for (i, k) in keys.enumerated() {
            ring.insert(key: k, params: DoviMetalParams(), dmNAL: [UInt8(i)])
        }
        for (i, k) in keys.enumerated() {
            #expect(ring.find(key: k)?.dmNAL == [UInt8(i)], "frame \(i) resolves to its own side data")
        }
        // A timestamp 1 ms off (the demuxer's rounding) still finds its own frame, not a neighbour.
        let off = DualLayerVideoDecoder.canonicalKey(rawPTS: 84, timeBase: tb)
        #expect(ring.find(key: off)?.key == keys[2])
    }
}
#endif
