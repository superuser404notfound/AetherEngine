#if DualLayerDolbyVision
import CoreVideo
import Foundation
import Metal
import Testing
@testable import AetherEngine

/// The chroma sampling switch. 4:2:0 is the composition itself; 4:2:2 and 4:4:4 are that composition stepped
/// up by co-sited means. With dither off, every 4:2:0 site they keep is the 4:2:0 output bit for bit, and the
/// samples between sites are their means.
@Suite(.offCooperativePoolOneLane, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct DoviChromaFormatTests {

    typealias Fixture = DoviFelInPlaceComposeTests

    static let width = 256
    static let height = 128

    /// One frame composed at `format` with dither off (round to nearest), so every sample is exact.
    static func compose(_ composer: DoviFelComposer, format: DoviFelChromaFormat, chroma: Fixture.ChromaCurves) throws -> CVPixelBuffer {
        composer.chromaFormat = format
        let (bl, el) = try #require(Fixture.makeBaseAndEnhancement(width: width, height: height, seed: 3))
        let params = Fixture.params(dither: .none, residual: true, chroma: chroma)
        return try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 0))
    }

    /// The raw (Cb, Cr) words at chroma position (x, y), for a chroma plane `planeWidth` samples wide.
    static func pair(_ words: [UInt16], planeWidth: Int, x: Int, y: Int) -> (cb: Int, cr: Int) {
        let i = y * planeWidth * 2 + x * 2
        return (Int(words[i]), Int(words[i + 1]))
    }

    /// One 10-bit code is 64 in the raw words. A mean of two or four quantised codes can differ from the
    /// quantised mean by one code, so the between-site checks allow that much.
    static let oneCode = 64

    // MARK: - Layout

    @Test("each chroma format writes its own 10-bit biplanar layout at its own chroma size",
          arguments: DoviFelChromaFormat.allCases)
    func layoutFollowsFormat(format: DoviFelChromaFormat) throws {
        let composer = try #require(DoviFelComposer())
        let out = try Self.compose(composer, format: format, chroma: .polynomial)
        #expect(CVPixelBufferGetPixelFormatType(out) == format.pixelFormat)
        #expect(CVPixelBufferGetWidthOfPlane(out, 0) == Self.width)
        let size = format.chromaSize(width: Self.width, height: Self.height)
        #expect(CVPixelBufferGetWidthOfPlane(out, 1) == size.width)
        #expect(CVPixelBufferGetHeightOfPlane(out, 1) == size.height)
    }

    @Test("odd luma sizes compose in every format, at the rounded chroma size",
          arguments: DoviFelChromaFormat.allCases)
    func oddLumaSizesCompose(format: DoviFelChromaFormat) throws {
        let composer = try #require(DoviFelComposer())
        composer.chromaFormat = format
        let (bl, el) = try #require(Fixture.makeBaseAndEnhancement(width: 255, height: 127, seed: 3))
        let params = Fixture.params(dither: .none, residual: true, chroma: .polynomial)
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 0))
        let size = format.chromaSize(width: 255, height: 127)
        #expect(CVPixelBufferGetWidthOfPlane(out, 0) == 255)
        #expect(CVPixelBufferGetWidthOfPlane(out, 1) == size.width)
        #expect(CVPixelBufferGetHeightOfPlane(out, 1) == size.height)
    }

    @Test("switching back to 4:2:0 on one composer reproduces the first 4:2:0 frame")
    func switchingBackReproducesFourTwoZero() throws {
        let composer = try #require(DoviFelComposer())
        let first = try Self.compose(composer, format: .yuv420, chroma: .polynomial)
        _ = try Self.compose(composer, format: .yuv444, chroma: .polynomial)
        let again = try Self.compose(composer, format: .yuv420, chroma: .polynomial)
        #expect(Fixture.visibleWords(first, plane: 0) == Fixture.visibleWords(again, plane: 0))
        #expect(Fixture.visibleWords(first, plane: 1) == Fixture.visibleWords(again, plane: 1))
    }

    @Test("odd luma sizes round the 4:2:0 chroma up, and 4:2:2 keeps the full height")
    func chromaSizesRoundUp() {
        #expect(DoviFelChromaFormat.yuv420.chromaSize(width: 255, height: 127) == (128, 64))
        #expect(DoviFelChromaFormat.yuv422.chromaSize(width: 255, height: 127) == (128, 127))
        #expect(DoviFelChromaFormat.yuv444.chromaSize(width: 255, height: 127) == (255, 127))
    }

    @Test("AETHER_FEL_CHROMA picks 4:2:2 or 4:4:4, and any other value keeps 4:2:0")
    func environmentValueChoosesFormat() {
        #expect(DoviFelChromaFormat.from(environmentValue: "422") == .yuv422)
        #expect(DoviFelChromaFormat.from(environmentValue: " 444 ") == .yuv444)
        #expect(DoviFelChromaFormat.from(environmentValue: "420p") == .yuv420)
        #expect(DoviFelChromaFormat.from(environmentValue: nil) == .yuv420)
    }

    // MARK: - Samples

    @Test("4:2:2 keeps every 4:2:0 site row bit for bit, on one composer that changes format between frames",
          arguments: [Fixture.ChromaCurves.polynomial, Fixture.ChromaCurves.mmrTwoPieces])
    func fourTwoTwoKeepsSiteRows(chroma: Fixture.ChromaCurves) throws {
        let composer = try #require(DoviFelComposer())
        let site = try Self.compose(composer, format: .yuv420, chroma: chroma)
        let wide = try Self.compose(composer, format: .yuv422, chroma: chroma)
        let siteWords = Fixture.visibleWords(site, plane: 1)
        let wideWords = Fixture.visibleWords(wide, plane: 1)
        let cw = Self.width / 2
        for r in 0..<(Self.height / 2) {
            for x in 0..<cw {
                let a = Self.pair(siteWords, planeWidth: cw, x: x, y: r)
                let b = Self.pair(wideWords, planeWidth: cw, x: x, y: 2 * r)
                #expect(a == b, "site (\(x), \(r)) differs from its 4:2:2 row \(2 * r)")
            }
        }
    }

    @Test("4:2:2 rows between two site rows are the mean of those rows, within one code",
          arguments: [Fixture.ChromaCurves.polynomial, Fixture.ChromaCurves.mmrTwoPieces])
    func fourTwoTwoMeansBetweenSites(chroma: Fixture.ChromaCurves) throws {
        let composer = try #require(DoviFelComposer())
        let site = try Self.compose(composer, format: .yuv420, chroma: chroma)
        let wide = try Self.compose(composer, format: .yuv422, chroma: chroma)
        let siteWords = Fixture.visibleWords(site, plane: 1)
        let wideWords = Fixture.visibleWords(wide, plane: 1)
        let cw = Self.width / 2
        let lastSiteRow = Self.height / 2 - 1
        for r in 0...lastSiteRow {
            for x in 0..<cw {
                let lo = Self.pair(siteWords, planeWidth: cw, x: x, y: r)
                let hi = Self.pair(siteWords, planeWidth: cw, x: x, y: min(r + 1, lastSiteRow))
                let odd = Self.pair(wideWords, planeWidth: cw, x: x, y: 2 * r + 1)
                #expect(abs(odd.cb - (lo.cb + hi.cb + 1) / 2) <= Self.oneCode, "Cb at (\(x), \(2 * r + 1))")
                #expect(abs(odd.cr - (lo.cr + hi.cr + 1) / 2) <= Self.oneCode, "Cr at (\(x), \(2 * r + 1))")
            }
        }
    }

    @Test("4:4:4 keeps every 4:2:0 site bit for bit",
          arguments: [Fixture.ChromaCurves.polynomial, Fixture.ChromaCurves.mmrTwoPieces])
    func fourFourFourKeepsSites(chroma: Fixture.ChromaCurves) throws {
        let composer = try #require(DoviFelComposer())
        let site = try Self.compose(composer, format: .yuv420, chroma: chroma)
        let full = try Self.compose(composer, format: .yuv444, chroma: chroma)
        let siteWords = Fixture.visibleWords(site, plane: 1)
        let fullWords = Fixture.visibleWords(full, plane: 1)
        let cw = Self.width / 2
        for r in 0..<(Self.height / 2) {
            for x in 0..<cw {
                let a = Self.pair(siteWords, planeWidth: cw, x: x, y: r)
                let b = Self.pair(fullWords, planeWidth: Self.width, x: 2 * x, y: 2 * r)
                #expect(a == b, "site (\(x), \(r)) differs from its 4:4:4 sample")
            }
        }
    }

    @Test("4:4:4 samples between sites are the mean of the sites around them, within one code",
          arguments: [Fixture.ChromaCurves.polynomial, Fixture.ChromaCurves.mmrTwoPieces])
    func fourFourFourMeansBetweenSites(chroma: Fixture.ChromaCurves) throws {
        let composer = try #require(DoviFelComposer())
        let site = try Self.compose(composer, format: .yuv420, chroma: chroma)
        let full = try Self.compose(composer, format: .yuv444, chroma: chroma)
        let siteWords = Fixture.visibleWords(site, plane: 1)
        let fullWords = Fixture.visibleWords(full, plane: 1)
        let cw = Self.width / 2
        let ch = Self.height / 2
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let cx = x / 2, cy = y / 2
                let nx = x % 2 == 1 ? min(cx + 1, cw - 1) : cx
                let ny = y % 2 == 1 ? min(cy + 1, ch - 1) : cy
                let corners = [
                    Self.pair(siteWords, planeWidth: cw, x: cx, y: cy),
                    Self.pair(siteWords, planeWidth: cw, x: nx, y: cy),
                    Self.pair(siteWords, planeWidth: cw, x: cx, y: ny),
                    Self.pair(siteWords, planeWidth: cw, x: nx, y: ny),
                ]
                let got = Self.pair(fullWords, planeWidth: Self.width, x: x, y: y)
                let meanCb = (corners.reduce(0) { $0 + $1.cb } + 2) / 4
                let meanCr = (corners.reduce(0) { $0 + $1.cr } + 2) / 4
                #expect(abs(got.cb - meanCb) <= Self.oneCode, "Cb at (\(x), \(y))")
                #expect(abs(got.cr - meanCr) <= Self.oneCode, "Cr at (\(x), \(y))")
            }
        }
    }

    // MARK: - Pool and in-place

    @Test("in-place composition is refused for 4:2:2 and 4:4:4 output, and allowed for 4:2:0",
          arguments: DoviFelChromaFormat.allCases)
    func inPlaceFollowsFormat(format: DoviFelChromaFormat) throws {
        let composer = try #require(DoviFelComposer())
        composer.chromaFormat = format
        let (bl, _) = try #require(Fixture.makeBaseAndEnhancement(width: Self.width, height: Self.height, seed: 1))
        let params = Fixture.params(dither: .none, residual: true, chroma: .polynomial)
        let decision = composer.inPlaceDecision(baseBuffer: bl, params: params)
        if format == .yuv420 {
            #expect(decision == nil)
        } else {
            #expect(decision == .outputChroma)
        }
    }
}
#endif
