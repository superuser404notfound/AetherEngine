// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
@testable import AetherEngine

/// Hostile parameter blocks and content thrown at the composition kernels. The RPU guard and the
/// parser should never let such values through, but the kernels are the last line: whatever arrives,
/// they must neither hang nor write outside the legal output range, and must be deterministic.
@Suite(.offCooperativePoolOneLane)
struct DoviGpuAdversarialTests {

    typealias H = DoviGpuCurveSweepTests

    struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s ^ (s >> 29) }
    }

    static let extremes: [Int32] = [0, 1, -1, 2, 1 << 15, -(1 << 15), 1 << 23, -(1 << 23), 1 << 30, Int32.max, Int32.min, Int32.min + 1]

    static func i32(_ r: inout RNG) -> Int32 {
        r.next() % 3 == 0 ? extremes[Int(r.next() % UInt64(extremes.count))] : Int32(truncatingIfNeeded: r.next())
    }
    static func u32(_ r: inout RNG, _ cap: UInt32) -> UInt32 {
        r.next() % 4 == 0 ? [0, 1, cap, cap + 1, UInt32.max][Int(r.next() % 5)] : UInt32(r.next() % UInt64(cap + 1))
    }

    static func hostileCurve(_ r: inout RNG) -> DoviPolynomialParams {
        var c = DoviPolynomialParams()
        c.numPivots = u32(&r, 12)
        for i in 0..<c.pivots.count { c.pivots[i] = u32(&r, 1100) }   // not sorted on purpose
        for i in 0..<DoviPolynomialParams.maxPieces {
            c.method[i] = r.next() % 2 == 0 ? 0 : (r.next() % 2 == 0 ? 1 : UInt32.max)
            c.order[i] = u32(&r, 5)
            c.coef[i] = [i32(&r), i32(&r), i32(&r)]
            c.coefShift[i] = u32(&r, 40)
        }
        return c
    }

    static func hostileMmr(_ r: inout RNG) -> DoviMmrParams {
        var m = DoviMmrParams()
        for i in 0..<m.constant.count {
            m.constant[i] = i32(&r)
            for j in 0..<m.coef[i].count { m.coef[i][j] = i32(&r) }
        }
        m.coefShift = u32(&r, 40)
        return m
    }

    static func hostileNlq(_ r: inout RNG) -> DoviNlqParams {
        var n = DoviNlqParams()
        n.nlqMethod = r.next() % 4 == 0 ? .none : .linear
        n.nlqOffset = i32(&r); n.nlqScale = i32(&r); n.nlqThreshold = i32(&r); n.vdrInMax = i32(&r)
        n.nlqShift = u32(&r, 40)
        return n
    }

    static func hostile(_ r: inout RNG, w: Int, h: Int) -> DoviMetalParams {
        var p = DoviMetalParams()
        p.blWidth = UInt32(w); p.blHeight = UInt32(h); p.elWidth = UInt32(w / 2); p.elHeight = UInt32(h / 2)
        p.ditherMode = [.none, .bayer8x8, .fullPrecision][Int(r.next() % 3)]
        p.frameIndex = UInt32(truncatingIfNeeded: r.next())
        var f = DoviComposerFlags()
        if r.next() % 4 == 0 { f.insert(.disableResidual) }
        if r.next() % 2 == 0 { f.insert(.lumaMmr) }
        p.flags = f
        p.polyY = hostileCurve(&r); p.polyCb = hostileCurve(&r); p.polyCr = hostileCurve(&r)
        p.mmrY = hostileMmr(&r); p.mmrCb = hostileMmr(&r); p.mmrCr = hostileMmr(&r)
        p.nlqY = hostileNlq(&r); p.nlqCb = hostileNlq(&r); p.nlqCr = hostileNlq(&r)
        // Bit depths straight from the parser's validated set, plus one the setter refuses.
        let depths = [(10, 12), (10, 10), (8, 12), (10, 16), (12, 12), (16, 16)]
        let d = depths[Int(r.next() % UInt64(depths.count))]
        _ = p.setBitDepths(bl: d.0, vdr: d.1)
        if r.next() % 8 == 0 { p.blMax = u32(&r, 70000); p.vdrMax = u32(&r, 70000); p.vdrScale = u32(&r, 70000) }
        return p
    }

    static func words(_ b: CVPixelBuffer, plane: Int) -> [UInt16] {
        CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(b, plane)!
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
        let w = CVPixelBufferGetWidthOfPlane(b, plane) * (plane == 0 ? 1 : 2), hh = CVPixelBufferGetHeightOfPlane(b, plane)
        var out: [UInt16] = []
        for y in 0..<hh {
            let row = (base + y * bpr).assumingMemoryBound(to: UInt16.self)
            out.append(contentsOf: UnsafeBufferPointer(start: row, count: w))
        }
        return out
    }

    @Test("hostile parameters and random content: always finishes, stays in the legal range, is deterministic",
          arguments: Array(UInt64(1)...48))
    func hostileParameters(seed: UInt64) throws {
        var r = RNG(s: seed &* 0x9E3779B97F4A7C15)
        let composer = try #require(DoviFelComposer())
        let w = 96, h = 48
        for iter in 0..<40 {
            let params = Self.hostile(&r, w: w, h: h)
            let bl = try #require(H.makeBuffer(width: w, height: h))
            let el = try #require(H.makeBuffer(width: w / 2, height: h / 2))
            var s = RNG(s: UInt64(iter) &+ seed &* 77)
            let full = s.next() % 3 == 0   // sometimes use the full 16-bit word range, not just 10-bit codes
            func code(_ s: inout RNG) -> Int { full ? Int(s.next() & 0xFFFF) >> 6 : Int(s.next() % 1024) }
            H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in code(&s) }
            H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in code(&s) }
            H.fillPlane(el, plane: 0, components: 1) { _, _, _ in code(&s) }
            H.fillPlane(el, plane: 1, components: 2) { _, _, _ in code(&s) }

            let a = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 0),
                                 "seed \(seed) iter \(iter) refused a well-formed buffer pair")
            let aY = Self.words(a, plane: 0), aC = Self.words(a, plane: 1)
            let b = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 0))
            #expect(aY == Self.words(b, plane: 0) && aC == Self.words(b, plane: 1), "seed \(seed) iter \(iter) is not deterministic")

            let bad = aY.filter { ($0 >> 6) < 64 || ($0 >> 6) > 940 }.count + aC.filter { ($0 >> 6) < 64 || ($0 >> 6) > 960 }.count
            #expect(bad == 0, "seed \(seed) iter \(iter): \(bad) samples outside video range (dither \(params.ditherMode), blMax \(params.blMax), vdrMax \(params.vdrMax), vdrScale \(params.vdrScale))")
        }
    }

    @Test("parameters that lie about the buffer size cannot read or write out of bounds")
    func lyingGeometry() throws {
        let composer = try #require(DoviFelComposer())
        let bl = try #require(H.makeBuffer(width: 64, height: 32))
        let el = try #require(H.makeBuffer(width: 32, height: 16))
        H.fillPlane(bl, plane: 0, components: 1) { x, y, _ in (x * 7 + y * 13) & 1023 }
        H.fillPlane(bl, plane: 1, components: 2) { x, y, _ in (x * 5 + y * 3) & 1023 }
        H.fillPlane(el, plane: 0, components: 1) { x, y, _ in (x * 11 + y) & 1023 }
        H.fillPlane(el, plane: 1, components: 2) { x, y, _ in (x + y * 9) & 1023 }
        let cases: [(UInt32, UInt32, UInt32, UInt32)] = [
            (0, 0, 0, 0), (1, 1, 1, 1), (64, 32, 0, 0), (64, 32, 1, 1), (64, 32, 4096, 4096),
            (4096, 4096, 32, 16), (UInt32.max, UInt32.max, UInt32.max, UInt32.max), (64, 32, 31, 15), (65, 33, 32, 16),
        ]
        for (bw, bh, ew, eh) in cases {
            var p = DoviGpuEdgeCaseTests.params()
            p.blWidth = bw; p.blHeight = bh; p.elWidth = ew; p.elHeight = eh
            // Either refused or composed at the real buffer geometry; never a crash or a hang.
            if let out = composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p, frameIndex: 0) {
                #expect(CVPixelBufferGetWidth(out) == 64 && CVPixelBufferGetHeight(out) == 32, "output must follow the real base buffer, not the claimed size")
                let y = Self.words(out, plane: 0)
                #expect(y.allSatisfy { ($0 >> 6) >= 64 && ($0 >> 6) <= 940 })
            }
        }
    }
}

extension DoviGpuAdversarialTests {
    /// Production drives the composer through the async API, which owns the in-flight slot accounting;
    /// the synchronous `compose` is single-threaded by contract.
    @Test("concurrent async composes at changing resolutions neither deadlock nor corrupt each other")
    func concurrentComposeWithResolutionChanges() async throws {
        let composer = try #require(DoviFelComposer())
        let sizes = [(64, 16), (128, 32), (96, 48), (256, 64)]
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for t in 0..<6 {
                group.addTask {
                    var ok = true
                    for i in 0..<60 {
                        let (w, h) = sizes[(t + i / 5) % sizes.count]
                        guard let bl = H.makeBuffer(width: w, height: h), let el = H.makeBuffer(width: w / 2, height: h / 2) else { return false }
                        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 + t * 10 }
                        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
                        H.fillPlane(el, plane: 0, components: 1) { _, _, _ in 612 }
                        H.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }
                        let good: Bool = await withCheckedContinuation { c in
                            composer.composeAsync(baseBuffer: bl, enhancementBuffer: el,
                                                  params: DoviGpuEdgeCaseTests.params(), frameIndex: UInt32(i)) { out in
                                guard let out else { c.resume(returning: false); return }
                                c.resume(returning: CVPixelBufferGetWidth(out) == w && Set(Self.words(out, plane: 0)).count == 1)
                            }
                        }
                        ok = ok && good
                    }
                    return ok
                }
            }
            var r: [Bool] = []
            for await v in group { r.append(v) }
            return r
        }
        #expect(results.count == 6 && results.allSatisfy { $0 })
        composer.acquireSlot(); composer.releaseSlot()
    }
}

extension DoviGpuAdversarialTests {
    /// The spec's fixed-point pseudo-code and the DoViBaker oracle normalise by 2^bits both
    /// ways, so a curve value of exactly one half is exactly the middle of the VDR range. Normalising by
    /// 2^bits - 1 put the same neutral chroma at 2049 (clip A) and as low as 2041 (clip B).
    @Test("a curve value of one half lands on exactly 2048, through polynomial and MMR constants",
          arguments: [false, true])
    func halfIsExactlyMidRange(mmr: Bool) throws {
        let composer = try #require(DoviFelComposer())
        var p = DoviGpuEdgeCaseTests.params(flags: [.disableResidual])
        p.ditherMode = .debugRawVDR
        var curve = DoviPolynomialParams()
        curve.numPivots = 2; curve.pivots[0] = 0; curve.pivots[1] = 1023
        curve.order[0] = 1; curve.coefShift[0] = 23
        if mmr {
            curve.method[0] = DoviMapping.mmr.rawValue
            var m = DoviMmrParams(); m.constant[0] = 1 << 22; m.coefShift = 23
            p.mmrCb = m; p.mmrCr = m
        } else {
            curve.method[0] = DoviMapping.polynomial.rawValue
            curve.coef[0] = [1 << 22, 0, 0]
        }
        p.polyCb = curve; p.polyCr = curve
        let out = try DoviGpuEdgeCaseTests.composeConstant(composer, bl: (512, 700, 300), el: (512, 512, 512), params: p)
        for plane in DoviTestSupport.rawVDR(out)[1...] { #expect(Set(plane) == [2048]) }
    }
}
#endif
