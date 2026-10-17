// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
@testable import AetherEngine

/// M8: an independent model of the composition, written from the RPU syntax and the reshaping
/// equations rather than from the shader, and compared with the GPU on frames captured from real
/// titles. The real titles carry what synthetic test content cannot produce (multi-piece luma curves,
/// MMR chroma, large NLQ scales), so this is the check on those paths.
///
/// The model works in `Double` and `Int64`, evaluates the curves with explicit `pow`, and samples the
/// enhancement layer with its own bilinear filter. It compares the un-quantised 12-bit VDR code
/// (`DoviDither.debugRawVDR`), so the final rounding cannot hide a disagreement.
///
/// What it settles: arithmetic, piece selection, MMR term layout, NLQ, clamps. What it cannot: the
/// spec readings the shader and the model share by construction (the chroma-site luma filter, the
/// half-step NLQ reconstruction); those were settled against DoViBaker, an independent implementation.
@Suite(.offCooperativePoolOneLane)
struct DoviCpuModelTests {

    // MARK: - Planes

    /// One P010 plane as 10-bit codes, `components` interleaved samples per pixel.
    struct Plane {
        let width: Int, height: Int, components: Int
        let raw: [UInt16]
        func code(_ x: Int, _ y: Int, _ c: Int = 0) -> Int {
            Int(raw[(y * width + x) * components + c] >> 6)
        }
        /// Raw 16-bit word, for the enhancement-layer filter (the GPU filters the UNORM word).
        func word(_ x: Int, _ y: Int, _ c: Int = 0) -> Double {
            Double(raw[(y * width + x) * components + c])
        }
    }

    static func plane(_ b: CVPixelBuffer, _ index: Int, components: Int) -> Plane {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(b, index), h = CVPixelBufferGetHeightOfPlane(b, index)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(b, index) / 2
        let base = CVPixelBufferGetBaseAddressOfPlane(b, index)!.assumingMemoryBound(to: UInt16.self)
        var out = [UInt16](); out.reserveCapacity(w * h * components)
        for y in 0..<h { for x in 0..<(w * components) { out.append(base[y * stride + x]) } }
        return Plane(width: w, height: h, components: components, raw: out)
    }

    // MARK: - The model

    struct Model {
        let p: DoviMetalParams
        let blMax: Double
        let scale: Double

        init(_ p: DoviMetalParams) {
            self.p = p
            blMax = Double(p.blMax) + 1   // 2^bits, as the kernels normalise
            scale = Double(p.vdrScale)
        }

        /// The piece that owns `v`: the last pivot `v` has reached.
        func piece(_ c: DoviPolynomialParams, _ v: Int) -> Int {
            let last = Int(c.numPivots) - 2
            var k = 0
            for i in 0...max(last, 0) where v >= Int(c.pivots[i]) { k = i }
            return min(max(k, 0), max(last, 0))
        }

        /// Normalised prediction of one component.
        func predict(_ c: DoviPolynomialParams, _ mmr: DoviMmrParams, blValue: Int,
                     y: Double, u: Double, v: Double) -> Double {
            if c.numPivots < 2 { return Double(blValue) / blMax }
            let k = piece(c, blValue)
            if c.method[k] == DoviMapping.mmr.rawValue {
                let inv = pow(2.0, -Double(mmr.coefShift))
                var s = Double(mmr.constant[k]) * inv
                let terms = [y, u, v, y * u, y * v, u * v, y * u * v]
                let order = min(Int(c.order[k]), 3)
                for o in 0..<order {
                    for t in 0..<7 {
                        s += Double(mmr.coef[k][o * 7 + t]) * inv * pow(terms[t], Double(o + 1))
                    }
                }
                return s
            }
            let lo = Int(c.pivots[0]), hi = Int(c.pivots[Int(c.numPivots) - 1])
            let x = Double(min(max(blValue, lo), hi)) / blMax
            let inv = pow(2.0, -Double(c.coefShift[k]))
            var s = Double(c.coef[k][0]) * inv
            if c.order[k] >= 1 { s += Double(c.coef[k][1]) * inv * x }
            if c.order[k] >= 2 { s += Double(c.coef[k][2]) * inv * x * x }
            return s
        }

        func denormalize(_ n: Double) -> Int { Int((n * blMax * scale).rounded(.toNearestOrEven)) }

        /// Inverse NLQ in `Int64`, reconstructing at the middle of the quantisation step.
        func inverseNlq(_ n: DoviNlqParams, _ el: Int) -> Int {
            guard n.nlqMethod == .linear, n.nlqScale != 0 else { return 0 }
            let r = Int64(el) - Int64(n.nlqOffset)
            if r == 0 { return 0 }
            let magFp = (2 * abs(r) - 1) * Int64(n.nlqScale)
            let thr2 = 2 * Int64(n.nlqThreshold)
            var mag = (magFp + thr2) >> Int64(n.nlqShift + 1)
            if n.vdrInMax > 0 && mag > Int64(n.vdrInMax) { mag = Int64(n.vdrInMax) }
            return Int(r < 0 ? -mag : mag)
        }

        func nlqActive(_ n: DoviNlqParams) -> Bool {
            !p.flags.contains(.disableResidual) && n.nlqMethod == .linear && n.nlqScale != 0
        }

        /// Bilinear sample of an enhancement-layer plane at base-layer sample (x, y) of a plane `baseW` x
        /// `baseH`, as a 10-bit code (the word is UNORM x 65535 / 64). Luma samples sit at pixel centres;
        /// chroma (`cosited`) is co-sited with the top-left luma sample, so the two grids share sample 0.
        func elCode(_ el: Plane, comp: Int, x: Int, y: Int, baseW: Int, baseH: Int, cosited: Bool = false) -> Int {
            let centre = cosited ? 0.0 : 0.5
            let u = (Double(x) + centre) / Double(baseW) * Double(el.width) - centre
            let v = (Double(y) + centre) / Double(baseH) * Double(el.height) - centre
            let x0 = Int(floor(u)), y0 = Int(floor(v))
            let fx = u - Double(x0), fy = v - Double(y0)
            func w(_ xx: Int, _ yy: Int) -> Double {
                el.word(min(max(xx, 0), el.width - 1), min(max(yy, 0), el.height - 1), comp)
            }
            let top = w(x0, y0) * (1 - fx) + w(x0 + 1, y0) * fx
            let bot = w(x0, y0 + 1) * (1 - fx) + w(x0 + 1, y0 + 1) * fx
            let word = top * (1 - fy) + bot * fy
            return Int((word / 64.0).rounded(.toNearestOrEven))
        }

        /// One component's pieces before any clamp: the normalised prediction, the VDR code it
        /// denormalises to, the enhancement-layer code and the residual it decodes to.
        struct Parts { var predNorm = 0.0; var pred = 0; var elCode = 0; var residual = 0; var active = false
            var total: Int { pred + residual } }

        func lumaParts(bl: Plane, blUV: Plane, el: Plane, x: Int, y: Int) -> Parts {
            let by = bl.code(x, y)
            let cx = min(x >> 1, blUV.width - 1), cy = min(y >> 1, blUV.height - 1)
            let yn = Double(by) / blMax
            let un = Double(blUV.code(cx, cy, 0)) / blMax
            let vn = Double(blUV.code(cx, cy, 1)) / blMax
            var r = Parts()
            r.predNorm = predict(p.polyY, p.mmrY, blValue: by, y: yn, u: un, v: vn)
            r.pred = denormalize(r.predNorm)
            if nlqActive(p.nlqY) {
                r.active = true
                r.elCode = elCode(el, comp: 0, x: x, y: y, baseW: bl.width, baseH: bl.height)
                r.residual = inverseNlq(p.nlqY, r.elCode)
            }
            return r
        }

        /// Luma at the chroma site: [1 2 1] around the even column in both rows of the cell, rounded per
        /// row, then the two rows averaged; edges clamped (DoViBaker's reading, which Dolby's EL confirms).
        static func chromaSiteLuma(_ bl: Plane, x: Int, y: Int) -> Int {
            func at(_ c: Int, _ r: Int) -> Int { bl.code(min(max(c, 0), bl.width - 1), min(r, bl.height - 1)) }
            let rows = [y * 2, y * 2 + 1].map { r in (at(x * 2 - 1, r) + 2 * at(x * 2, r) + at(x * 2 + 1, r) + 2) >> 2 }
            return (rows[0] + rows[1] + 1) >> 1
        }

        func chromaParts(bl: Plane, blUV: Plane, elUV: Plane, x: Int, y: Int) -> (cb: Parts, cr: Parts) {
            let by = Self.chromaSiteLuma(bl, x: x, y: y)
            let cb = blUV.code(x, y, 0), cr = blUV.code(x, y, 1)
            let yn = Double(by) / blMax, un = Double(cb) / blMax, vn = Double(cr) / blMax
            var a = Parts(), b = Parts()
            a.predNorm = predict(p.polyCb, p.mmrCb, blValue: cb, y: yn, u: un, v: vn)
            b.predNorm = predict(p.polyCr, p.mmrCr, blValue: cr, y: yn, u: un, v: vn)
            a.pred = denormalize(a.predNorm); b.pred = denormalize(b.predNorm)
            if !p.flags.contains(.disableResidual) {
                if nlqActive(p.nlqCb) {
                    a.active = true
                    a.elCode = elCode(elUV, comp: 0, x: x, y: y, baseW: blUV.width, baseH: blUV.height, cosited: true)
                    a.residual = inverseNlq(p.nlqCb, a.elCode)
                }
                if nlqActive(p.nlqCr) {
                    b.active = true
                    b.elCode = elCode(elUV, comp: 1, x: x, y: y, baseW: blUV.width, baseH: blUV.height, cosited: true)
                    b.residual = inverseNlq(p.nlqCr, b.elCode)
                }
            }
            return (a, b)
        }

        func luma(bl: Plane, blUV: Plane, el: Plane, x: Int, y: Int) -> Int {
            let by = bl.code(x, y)
            let cx = min(x >> 1, blUV.width - 1), cy = min(y >> 1, blUV.height - 1)
            let yn = Double(by) / blMax
            let un = Double(blUV.code(cx, cy, 0)) / blMax
            let vn = Double(blUV.code(cx, cy, 1)) / blMax
            var v = denormalize(predict(p.polyY, p.mmrY, blValue: by, y: yn, u: un, v: vn))
            if nlqActive(p.nlqY) {
                v += inverseNlq(p.nlqY, elCode(el, comp: 0, x: x, y: y, baseW: bl.width, baseH: bl.height))
            }
            return min(max(v, 0), Int(p.vdrMax))
        }

        func chroma(bl: Plane, blUV: Plane, elUV: Plane, x: Int, y: Int) -> (Int, Int) {
            let by = Self.chromaSiteLuma(bl, x: x, y: y)
            let cb = blUV.code(x, y, 0), cr = blUV.code(x, y, 1)
            let yn = Double(by) / blMax, un = Double(cb) / blMax, vn = Double(cr) / blMax
            var vcb = denormalize(predict(p.polyCb, p.mmrCb, blValue: cb, y: yn, u: un, v: vn))
            var vcr = denormalize(predict(p.polyCr, p.mmrCr, blValue: cr, y: yn, u: un, v: vn))
            if !p.flags.contains(.disableResidual) {
                if nlqActive(p.nlqCb) {
                    vcb += inverseNlq(p.nlqCb, elCode(elUV, comp: 0, x: x, y: y, baseW: blUV.width, baseH: blUV.height, cosited: true))
                }
                if nlqActive(p.nlqCr) {
                    vcr += inverseNlq(p.nlqCr, elCode(elUV, comp: 1, x: x, y: y, baseW: blUV.width, baseH: blUV.height, cosited: true))
                }
            }
            let m = Int(p.vdrMax)
            return (min(max(vcb, 0), m), min(max(vcr, 0), m))
        }
    }

    // MARK: - Comparison

    struct Stat {
        var n = 0, exact = 0, over1 = 0, maxAbs = 0, sum = 0
        mutating func add(_ d: Int) {
            n += 1; let a = abs(d)
            if a == 0 { exact += 1 }
            if a > 1 { over1 += 1 }
            maxAbs = max(maxAbs, a); sum += d
        }
        var exactPct: Double { n == 0 ? 0 : 100 * Double(exact) / Double(n) }
        var over1Pct: Double { n == 0 ? 0 : 100 * Double(over1) / Double(n) }
        var description: String {
            String(format: "n=%d exact %.2f%% |d|>1 %.3f%% max %d mean %+.3f", n, exactPct, over1Pct, maxAbs,
                   n == 0 ? 0 : Double(sum) / Double(n))
        }
    }

    static func describe(_ c: DoviPolynomialParams, _ mmr: DoviMmrParams) -> String {
        guard c.numPivots >= 2 else { return "identity" }
        let pieces = Int(c.numPivots) - 1
        let kinds = (0..<pieces).map { c.method[$0] == DoviMapping.mmr.rawValue ? "mmr\(c.order[$0])" : "poly\(c.order[$0])" }
        return "\(pieces) pieces [\(kinds.joined(separator: ","))] shift \(c.coefShift[0])/\(mmr.coefShift)"
    }

    @Test("the independent CPU model reproduces the GPU's 12-bit VDR on real titles, MMR chroma and multi-piece curves included",
          .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func modelMatchesGpu(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        let caps = rec.captures
        try #require(!caps.isEmpty, "no frames reached the composer")

        var yStat = Stat(), cbStat = Stat(), crStat = Stat()
        for (i, cap) in caps.enumerated() {
            var params = cap.params
            params.ditherMode = .debugRawVDR
            let out = try #require(rec.inner.compose(baseBuffer: cap.bl, enhancementBuffer: cap.el, params: params, frameIndex: 0))
            let gy = Self.plane(out, 0, components: 1), guv = Self.plane(out, 1, components: 2)
            let bl = Self.plane(cap.bl, 0, components: 1), blUV = Self.plane(cap.bl, 1, components: 2)
            let el = Self.plane(cap.el, 0, components: 1), elUV = Self.plane(cap.el, 1, components: 2)
            let model = Model(params)
            if i == 0 {
                print("[m8] \(name): Y \(Self.describe(params.polyY, params.mmrY)); Cb \(Self.describe(params.polyCb, params.mmrCb)); Cr \(Self.describe(params.polyCr, params.mmrCr)); flags \(params.flags.rawValue); nlqY scale \(params.nlqY.nlqScale) thr \(params.nlqY.nlqThreshold) max \(params.nlqY.vdrInMax) shift \(params.nlqY.nlqShift); nlqCb scale \(params.nlqCb.nlqScale)")
            }
            // The raw-VDR planes hold the 12-bit code shifted left 4 in a 16-bit word.
            func gpu(_ p: Plane, _ x: Int, _ y: Int, _ c: Int) -> Int { Int(p.raw[(y * p.width + x) * p.components + c] >> 4) }
            for y in stride(from: 3, to: bl.height, by: 7) {
                for x in stride(from: 5, to: bl.width, by: 11) {
                    yStat.add(model.luma(bl: bl, blUV: blUV, el: el, x: x, y: y) - gpu(gy, x, y, 0))
                }
            }
            for y in stride(from: 1, to: blUV.height, by: 5) {
                for x in stride(from: 2, to: blUV.width, by: 7) {
                    let (cb, cr) = model.chroma(bl: bl, blUV: blUV, elUV: elUV, x: x, y: y)
                    cbStat.add(cb - gpu(guv, x, y, 0))
                    crStat.add(cr - gpu(guv, x, y, 1))
                }
            }
        }
        print("[m8] \(name): Y \(yStat.description)")
        print("[m8] \(name): Cb \(cbStat.description)")
        print("[m8] \(name): Cr \(crStat.description)")
        // The enhancement-layer filter is the one place the two are not the same arithmetic (the
        // hardware bilinear weights are fixed point), so a residual code can land one off; anything
        // beyond that is a disagreement about the maths.
        for (label, st) in [("Y", yStat), ("Cb", cbStat), ("Cr", crStat)] {
            #expect(st.over1Pct < 0.5, "\(label): \(st.description)")
            #expect(st.exactPct > 90, "\(label): \(st.description)")
        }
    }

    // MARK: - Loss census (M1) and error attribution (M3, M4, M6)

    /// Counts, per plane, every pixel at a point where information can be lost. Fractions of the
    /// sampled pixels. The output range clamps are video range: 64...940 luma, 64...960 chroma.
    struct Census {
        var n = 0
        var predBelow0 = 0, predAbove1 = 0
        var nlqAtMax = 0, residualPixels = 0
        var vdrBelow0 = 0, vdrAboveMax = 0
        var outBelowLo = 0, outAboveHi = 0
        var elAt0 = 0, elAt1023 = 0
        var worstOvershoot = 0
        mutating func add(_ q: Model.Parts, _ nlq: DoviNlqParams, vdrMax: Int, scale: Double, lo: Int, hi: Int) {
            n += 1
            if q.predNorm < 0 { predBelow0 += 1 }
            if q.predNorm > 1 { predAbove1 += 1 }
            if q.active {
                residualPixels += 1
                if abs(q.residual) >= Int(nlq.vdrInMax) && nlq.vdrInMax > 0 { nlqAtMax += 1 }
                if q.elCode <= 0 { elAt0 += 1 }
                if q.elCode >= 1023 { elAt1023 += 1 }
            }
            let t = q.total
            if t < 0 { vdrBelow0 += 1 }
            if t > vdrMax { vdrAboveMax += 1 }
            let c = min(max(t, 0), vdrMax)
            let out = Int(floor(Double(c) / scale + 0.5))
            if out < lo { outBelowLo += 1; worstOvershoot = max(worstOvershoot, lo - out) }
            if out > hi { outAboveHi += 1; worstOvershoot = max(worstOvershoot, out - hi) }
        }
        var line: String {
            func f(_ v: Int) -> String { String(format: "%.4f%%", n == 0 ? 0 : 100 * Double(v) / Double(n)) }
            return "n=\(n) pred<0 \(f(predBelow0)) pred>1 \(f(predAbove1)) | residual px \(f(residualPixels)) at vdr_in_max \(f(nlqAtMax)) EL=0 \(f(elAt0)) EL=1023 \(f(elAt1023)) | vdr<0 \(f(vdrBelow0)) vdr>max \(f(vdrAboveMax)) | out<lo \(f(outBelowLo)) out>hi \(f(outAboveHi)) worst overshoot \(worstOvershoot) codes"
        }
    }

    @Test("M1: loss census on real titles, every clamp counted", .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func lossCensus(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        var y = Census(), cb = Census(), cr = Census()
        for cap in rec.captures {
            let p = cap.params
            let m = Model(p)
            let bl = Self.plane(cap.bl, 0, components: 1), blUV = Self.plane(cap.bl, 1, components: 2)
            let el = Self.plane(cap.el, 0, components: 1), elUV = Self.plane(cap.el, 1, components: 2)
            for yy in stride(from: 3, to: bl.height, by: 5) {
                for xx in stride(from: 5, to: bl.width, by: 7) {
                    y.add(m.lumaParts(bl: bl, blUV: blUV, el: el, x: xx, y: yy), p.nlqY, vdrMax: Int(p.vdrMax), scale: m.scale, lo: 64, hi: 940)
                }
            }
            for yy in stride(from: 1, to: blUV.height, by: 3) {
                for xx in stride(from: 2, to: blUV.width, by: 5) {
                    let (a, b) = m.chromaParts(bl: bl, blUV: blUV, elUV: elUV, x: xx, y: yy)
                    cb.add(a, p.nlqCb, vdrMax: Int(p.vdrMax), scale: m.scale, lo: 64, hi: 960)
                    cr.add(b, p.nlqCr, vdrMax: Int(p.vdrMax), scale: m.scale, lo: 64, hi: 960)
                }
            }
        }
        print("[m1] \(name): Y  \(y.line)")
        print("[m1] \(name): Cb \(cb.line)")
        print("[m1] \(name): Cr \(cr.line)")
    }

    @Test("M3/M4/M6: where the GPU and the exact model still differ, split by cause", .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func errorAttribution(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        var lumaNoRes = Stat(), chromaNoRes = Stat(), lumaRes = Stat(), chromaRes = Stat()
        for cap in rec.captures {
            let bl = Self.plane(cap.bl, 0, components: 1), blUV = Self.plane(cap.bl, 1, components: 2)
            let el = Self.plane(cap.el, 0, components: 1), elUV = Self.plane(cap.el, 1, components: 2)
            for residual in [false, true] {
                var params = cap.params
                params.ditherMode = .debugRawVDR
                if !residual { params.flags.insert(.disableResidual) }
                let out = try #require(rec.inner.compose(baseBuffer: cap.bl, enhancementBuffer: cap.el, params: params, frameIndex: 0))
                let gy = Self.plane(out, 0, components: 1), guv = Self.plane(out, 1, components: 2)
                let m = Model(params)
                func g(_ p: Plane, _ x: Int, _ y: Int, _ c: Int) -> Int { Int(p.raw[(y * p.width + x) * p.components + c] >> 4) }
                for yy in stride(from: 3, to: bl.height, by: 5) {
                    for xx in stride(from: 5, to: bl.width, by: 7) {
                        let d = m.luma(bl: bl, blUV: blUV, el: el, x: xx, y: yy) - g(gy, xx, yy, 0)
                        if residual { lumaRes.add(d) } else { lumaNoRes.add(d) }
                    }
                }
                for yy in stride(from: 1, to: blUV.height, by: 3) {
                    for xx in stride(from: 2, to: blUV.width, by: 5) {
                        let (a, b) = m.chroma(bl: bl, blUV: blUV, elUV: elUV, x: xx, y: yy)
                        let d1 = a - g(guv, xx, yy, 0), d2 = b - g(guv, xx, yy, 1)
                        if residual { chromaRes.add(d1); chromaRes.add(d2) } else { chromaNoRes.add(d1); chromaNoRes.add(d2) }
                    }
                }
            }
        }
        print("[m3] \(name): luma, no residual (table + float): \(lumaNoRes.description)")
        print("[m4] \(name): chroma, no residual (MMR float):   \(chromaNoRes.description)")
        print("[m6] \(name): luma, with residual (+ EL sampling): \(lumaRes.description)")
        print("[m6] \(name): chroma, with residual:               \(chromaRes.description)")
    }

    /// M7: how much the chroma MMR output depends on how the luma is brought down to the chroma site.
    /// Each variant replaces only the luma input of the cross terms; the production reading is the baseline.
    @Test("M7: chroma MMR sensitivity to the luma downsampling at the chroma site", .enabled(if: !DoviFelRealFileTests.availableFixtures.isEmpty, DoviFelRealFileTests.needsClips),
          arguments: DoviFelRealFileTests.availableFixtures)
    func lumaSiteSensitivity(name: String) throws {
        let rec = try #require(DoviFelRealFileTests.RecordingComposer(limit: 6, stride: 40))
        let s = try DoviFelRealFileTests.open(name, composer: rec)
        defer { s.decoder.close(); s.demuxer.close() }
        DoviFelRealFileTests.feed(s, count: 300)
        s.decoder.flush()
        let names = ["top row", "2x2 box", "vertical 2-tap", "bottom row"]
        var sq = [Double](repeating: 0, count: names.count), mx = [Int](repeating: 0, count: names.count)
        var n = 0
        for cap in rec.captures {
            let p = cap.params
            let m = Model(p)
            let bl = Self.plane(cap.bl, 0, components: 1), blUV = Self.plane(cap.bl, 1, components: 2)
            func at(_ x: Int, _ y: Int) -> Int { bl.code(min(max(x, 0), bl.width - 1), min(max(y, 0), bl.height - 1)) }
            for yy in stride(from: 1, to: blUV.height, by: 3) {
                for xx in stride(from: 2, to: blUV.width, by: 5) {
                    let cb = blUV.code(xx, yy, 0), cr = blUV.code(xx, yy, 1)
                    let un = Double(cb) / m.blMax, vn = Double(cr) / m.blMax
                    func pred(_ luma: Double) -> (Int, Int) {
                        let yn = luma / m.blMax
                        return (m.denormalize(m.predict(p.polyCb, p.mmrCb, blValue: cb, y: yn, u: un, v: vn)),
                                m.denormalize(m.predict(p.polyCr, p.mmrCr, blValue: cr, y: yn, u: un, v: vn)))
                    }
                    let x0 = xx * 2, y0 = yy * 2
                    let base = pred(Double(Model.chromaSiteLuma(bl, x: xx, y: yy)))
                    let box = (at(x0, y0) + at(x0 + 1, y0) + at(x0, y0 + 1) + at(x0 + 1, y0 + 1))
                    let variants = [pred(Double(at(x0, y0))), pred(Double(box) / 4),
                                    pred(Double((at(x0, y0) + at(x0, y0 + 1) + 1) >> 1)), pred(Double(at(x0, y0 + 1)))]
                    for (i, v) in variants.enumerated() {
                        for d in [v.0 - base.0, v.1 - base.1] { sq[i] += Double(d * d); mx[i] = max(mx[i], abs(d)) }
                    }
                    n += 2
                }
            }
        }
        for i in 0..<names.count {
            print(String(format: "[m7] %@: %@ vs [1 2 1] x 2-row: RMS %.3f codes (12-bit), max %d", name, names[i], (sq[i] / Double(n)).squareRoot(), mx[i]))
        }
    }
}
#endif
