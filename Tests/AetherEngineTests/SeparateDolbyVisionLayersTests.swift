import Foundation
import Testing
@testable import AetherEngine

// The bytes of a joined unit: what the dual-layer decoder reads from a single-track remux, built from a split source.
@Suite("Separate Dolby Vision layer units")
struct SeparateDolbyVisionLayersTests {

    private static func lp(_ nals: [UInt8]...) -> [UInt8] {
        nals.flatMap { n -> [UInt8] in
            let c = n.count
            return [UInt8(c >> 24 & 0xFF), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)] + n
        }
    }

    private static func annexB(_ nals: [UInt8]...) -> [UInt8] { nals.flatMap { [0, 0, 0, 1] + $0 } }

    // NAL headers: type << 1, layer 0, tid 1.
    private static let aud: [UInt8] = [0x46, 0x01, 0x50]
    private static let idr: [UInt8] = [0x26, 0x01, 0xAA, 0xBB]        // type 19
    private static let trail: [UInt8] = [0x02, 0x01, 0xCC]            // type 1
    private static let vps: [UInt8] = [0x40, 0x01, 0x0C]              // 32
    private static let sps: [UInt8] = [0x42, 0x01, 0x01, 0x02]        // 33
    private static let pps: [UInt8] = [0x44, 0x01, 0xC1]              // 34
    private static let rpuBase: [UInt8] = [0x7C, 0x01, 0x19, 0x08, 0x80]
    private static let rpuEnh: [UInt8] = [0x7C, 0x01, 0x19, 0x09, 0x80]

    @Test("the join needs a base layer with four-byte lengths or Annex-B framing")
    func joinNeedsFourByteLengths() {
        #expect(SeparateDolbyVisionLayers.canJoin(baseFraming: .annexB))
        #expect(SeparateDolbyVisionLayers.canJoin(baseFraming: .lengthPrefixed(size: 4)))
        #expect(!SeparateDolbyVisionLayers.canJoin(baseFraming: .lengthPrefixed(size: 2)))
        #expect(!SeparateDolbyVisionLayers.canJoin(baseFraming: .lengthPrefixed(size: 1)))
        #expect(!SeparateDolbyVisionLayers.canJoin(baseFraming: .lengthPrefixed(size: 3)))
    }

    private static func raw(_ bytes: [UInt8], _ body: (UnsafeRawBufferPointer) -> [UInt8]) -> [UInt8] {
        bytes.withUnsafeBytes(body)
    }

    @Test("a length-prefixed unit gives its RPU in the Annex-B form the fold appends")
    func rpuFromLengthPrefixed() {
        let unit = Self.lp(Self.aud, Self.idr, Self.rpuEnh)
        let rpu = unit.withUnsafeBytes { DolbyVisionLayerUnits.rpu(in: $0, framing: .lengthPrefixed(size: 4)) }
        #expect(rpu == [0, 0, 1] + Self.rpuEnh)
        let none = Self.lp(Self.aud, Self.idr).withUnsafeBytes { DolbyVisionLayerUnits.rpu(in: $0, framing: .lengthPrefixed(size: 4)) }
        #expect(none == nil)
    }

    @Test("an Annex-B unit gives the same RPU as a length-prefixed one")
    func rpuFromAnnexB() {
        let unit = Self.annexB(Self.aud, Self.idr, Self.rpuEnh)
        let rpu = unit.withUnsafeBytes { DolbyVisionLayerUnits.rpu(in: $0, framing: .annexB) }
        #expect(rpu == [0, 0, 1] + Self.rpuEnh)
    }

    @Test("IRAP is a slice of type 16 to 23 in either framing, and nothing else")
    func irapDetection() {
        let irap = Self.lp(Self.aud, Self.idr)
        let plain = Self.lp(Self.aud, Self.trail)
        #expect(irap.withUnsafeBytes { DolbyVisionLayerUnits.isIRAP($0, framing: .lengthPrefixed(size: 4)) })
        #expect(!plain.withUnsafeBytes { DolbyVisionLayerUnits.isIRAP($0, framing: .lengthPrefixed(size: 4)) })
        #expect(Self.annexB(Self.aud, Self.idr).withUnsafeBytes { DolbyVisionLayerUnits.isIRAP($0, framing: .annexB) })
        #expect(!Self.annexB(Self.aud, Self.trail).withUnsafeBytes { DolbyVisionLayerUnits.isIRAP($0, framing: .annexB) })
    }

    @Test("the joined unit is the base NALs, every enhancement NAL wrapped as unspec63, then the enhancement RPU last")
    func composeLayout() {
        let base = Self.lp(Self.aud, Self.idr, Self.rpuBase)
        let enh = Self.lp(Self.aud, Self.idr, Self.rpuEnh)
        let out = base.withUnsafeBytes { b in
            enh.withUnsafeBytes { e in
                DolbyVisionLayerUnits.compose(base: b, baseFraming: .lengthPrefixed(size: 4),
                                              enhancement: e, enhancementFraming: .lengthPrefixed(size: 4))
            }
        }
        let wrap: ([UInt8]) -> [UInt8] = { [0x7E, 0x01] + $0 }
        #expect(out == Self.lp(Self.aud, Self.idr, wrap(Self.aud), wrap(Self.idr), Self.rpuEnh))
    }

    @Test("a unit whose enhancement partner is missing keeps the base layer's own RPU")
    func composeWithoutEnhancement() {
        let base = Self.lp(Self.aud, Self.idr, Self.rpuBase)
        let out = base.withUnsafeBytes { b in
            DolbyVisionLayerUnits.compose(base: b, baseFraming: .lengthPrefixed(size: 4),
                                          enhancement: nil, enhancementFraming: .lengthPrefixed(size: 4))
        }
        #expect(out == base)
    }

    @Test("an Annex-B base layer and enhancement layer come out length-prefixed")
    func composeFromTransportStream() {
        let base = Self.annexB(Self.aud, Self.vps, Self.sps, Self.pps, Self.idr)
        let enh = Self.annexB(Self.aud, Self.idr, Self.rpuEnh)
        let out = base.withUnsafeBytes { b in
            enh.withUnsafeBytes { e in
                DolbyVisionLayerUnits.compose(base: b, baseFraming: .annexB, enhancement: e, enhancementFraming: .annexB)
            }
        }
        let wrap: ([UInt8]) -> [UInt8] = { [0x7E, 0x01] + $0 }
        #expect(out == Self.lp(Self.aud, Self.vps, Self.sps, Self.pps, Self.idr, wrap(Self.aud), wrap(Self.idr), Self.rpuEnh))
    }

    @Test("parameter sets that only the enhancement track's record carries are injected ahead of its NALs, once, when asked")
    func composeInjectsParameterSets() {
        let base = Self.lp(Self.aud, Self.idr)
        let enh = Self.lp(Self.aud, Self.idr, Self.rpuEnh)
        func compose(inject: Bool, enh: [UInt8]) -> [UInt8] {
            base.withUnsafeBytes { b in
                enh.withUnsafeBytes { e in
                    DolbyVisionLayerUnits.compose(base: b, baseFraming: .lengthPrefixed(size: 4),
                                                  enhancement: e, enhancementFraming: .lengthPrefixed(size: 4),
                                                  parameterSets: [Self.vps, Self.sps, Self.pps], injectParameterSets: inject)
                }
            }
        }
        let wrap: ([UInt8]) -> [UInt8] = { [0x7E, 0x01] + $0 }
        #expect(compose(inject: true, enh: enh)
                == Self.lp(Self.aud, Self.idr, wrap(Self.vps), wrap(Self.sps), wrap(Self.pps), wrap(Self.aud), wrap(Self.idr), Self.rpuEnh))
        #expect(compose(inject: false, enh: enh) == Self.lp(Self.aud, Self.idr, wrap(Self.aud), wrap(Self.idr), Self.rpuEnh))
        // A unit that repeats its own sets in band does not get a second copy.
        let own = Self.lp(Self.aud, Self.vps, Self.sps, Self.pps, Self.idr, Self.rpuEnh)
        #expect(compose(inject: true, enh: own)
                == Self.lp(Self.aud, Self.idr, wrap(Self.aud), wrap(Self.vps), wrap(Self.sps), wrap(Self.pps), wrap(Self.idr), Self.rpuEnh))
    }
}
