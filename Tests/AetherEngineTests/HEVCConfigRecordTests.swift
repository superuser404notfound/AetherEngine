import Testing
@testable import AetherEngine

/// AE#187: the VOD muxer forwarded the source hvcC verbatim, including libx265's large SEI_PREFIX array,
/// which Apple TV hardware rejects (asset tracks count=0 / CoreMediaErrorDomain -12848). These cover the
/// pure canonicalizer that strips every non-parameter-set NAL array so the init sample description matches
/// the canonical VPS/SPS/PPS-only form the live-TS and direct-fMP4 paths already emit.
@Suite("HEVCConfigRecord canonicalization")
struct HEVCConfigRecordTests {

    /// 22-byte hvcC fixed header (configurationVersion=1, lengthSizeMinusOne=3). Only [0], [21], [22] are read
    /// by the canonicalizer; the rest are plausible filler.
    static func header22() -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 22)
        h[0] = 1        // configurationVersion
        h[21] = 0xFF    // reserved(6 bits, 1)=0xFC | lengthSizeMinusOne=3
        return h
    }

    /// Encode one hvcC NAL array: (completeness<<7 | type), numNalus(2B), then each NAL as len(2B)+bytes.
    static func encodeArray(type: UInt8, completeness: Bool, nals: [[UInt8]]) -> [UInt8] {
        var a: [UInt8] = [(completeness ? 0x80 : 0) | (type & 0x3F)]
        a.append(UInt8(nals.count >> 8)); a.append(UInt8(nals.count & 0xFF))
        for nal in nals {
            a.append(UInt8(nal.count >> 8)); a.append(UInt8(nal.count & 0xFF))
            a.append(contentsOf: nal)
        }
        return a
    }

    static func buildHvcC(_ arrays: [[UInt8]]) -> [UInt8] {
        var r = header22()
        r.append(UInt8(arrays.count))
        for a in arrays { r.append(contentsOf: a) }
        return r
    }

    @Test("Drops the SEI_PREFIX array, keeps VPS/SPS/PPS in order")
    func stripsSeiPrefix() {
        let vps: [UInt8] = Array(repeating: 0xA1, count: 24)
        let sps: [UInt8] = Array(repeating: 0xB2, count: 43)
        let pps: [UInt8] = Array(repeating: 0xC3, count: 7)
        let sei: [UInt8] = Array(repeating: 0xD4, count: 2316)  // x265 options SEI, the AE#187 payload
        let source = Self.buildHvcC([
            Self.encodeArray(type: 32, completeness: true, nals: [vps]),
            Self.encodeArray(type: 33, completeness: true, nals: [sps]),
            Self.encodeArray(type: 34, completeness: true, nals: [pps]),
            Self.encodeArray(type: 39, completeness: false, nals: [sei]),
        ])

        let canonical = HLSVideoEngine.canonicalizeHEVCConfigRecord(source)
        let expected = Self.buildHvcC([
            Self.encodeArray(type: 32, completeness: true, nals: [vps]),
            Self.encodeArray(type: 33, completeness: true, nals: [sps]),
            Self.encodeArray(type: 34, completeness: true, nals: [pps]),
        ])
        #expect(canonical == expected)
        // 23-byte header + VPS(5+24) + SPS(5+43) + PPS(5+7) = 112 B, matching a clean packager's hvcC payload.
        #expect(canonical?.count == 112)
        #expect(canonical?[22] == 3)                     // numOfArrays rewritten to 3
        #expect(Array(canonical![0..<22]) == Array(source[0..<22]))  // header preserved
    }

    @Test("Already-canonical record returns nil (no rewrite)")
    func canonicalReturnsNil() {
        let source = Self.buildHvcC([
            Self.encodeArray(type: 32, completeness: true, nals: [[0xA1, 0xA2]]),
            Self.encodeArray(type: 33, completeness: true, nals: [[0xB1, 0xB2]]),
            Self.encodeArray(type: 34, completeness: true, nals: [[0xC1]]),
        ])
        #expect(HLSVideoEngine.canonicalizeHEVCConfigRecord(source) == nil)
    }

    @Test("Also strips SEI_SUFFIX(40) and unknown arrays")
    func stripsSuffixAndUnknown() {
        let source = Self.buildHvcC([
            Self.encodeArray(type: 33, completeness: true, nals: [[0xB1]]),
            Self.encodeArray(type: 40, completeness: false, nals: [[0xE1, 0xE2, 0xE3]]),  // SEI_SUFFIX
            Self.encodeArray(type: 34, completeness: true, nals: [[0xC1]]),
            Self.encodeArray(type: 62, completeness: false, nals: [[0xF1]]),               // unspecified
        ])
        let canonical = HLSVideoEngine.canonicalizeHEVCConfigRecord(source)
        let expected = Self.buildHvcC([
            Self.encodeArray(type: 33, completeness: true, nals: [[0xB1]]),
            Self.encodeArray(type: 34, completeness: true, nals: [[0xC1]]),
        ])
        #expect(canonical == expected)
        #expect(canonical?[22] == 2)
    }

    @Test("numOfArrays=0 returns nil (handled by the in-band rebuild path)")
    func emptyArraysReturnsNil() {
        var r = Self.header22()
        r.append(0)  // numOfArrays = 0
        #expect(HLSVideoEngine.canonicalizeHEVCConfigRecord(r) == nil)
    }

    @Test("Non-hvcC / Annex-B extradata returns nil (configurationVersion != 1)")
    func nonHvcCReturnsNil() {
        let annexB: [UInt8] = [0x00, 0x00, 0x00, 0x01] + Array(repeating: 0x42, count: 40)
        #expect(HLSVideoEngine.canonicalizeHEVCConfigRecord(annexB) == nil)
    }

    @Test("Truncated record returns nil rather than corrupting")
    func truncatedReturnsNil() {
        var source = Self.buildHvcC([
            Self.encodeArray(type: 33, completeness: true, nals: [Array(repeating: 0xB2, count: 40)]),
            Self.encodeArray(type: 39, completeness: false, nals: [Array(repeating: 0xD4, count: 100)]),
        ])
        source.removeLast(50)  // chop the SEI array mid-NAL
        #expect(HLSVideoEngine.canonicalizeHEVCConfigRecord(source) == nil)
    }

    @Test("Too-short buffer returns nil")
    func tooShortReturnsNil() {
        #expect(HLSVideoEngine.canonicalizeHEVCConfigRecord([1, 2, 3]) == nil)
    }
}
