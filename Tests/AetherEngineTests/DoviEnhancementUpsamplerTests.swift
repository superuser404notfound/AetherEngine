// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Foundation
import Testing
import Metal
import CoreVideo
@testable import AetherEngine

/// The enhancement layer is upsampled to the base-layer grid: luma bilinearly, from explicit texel reads with exact
/// weights and rounded half up (`dovi_upsample_el`, `dovi_el_code`); chroma by the ETSI GS CCM 001 Annex B.3
/// default filter (`dovi_annexb_chroma`) when the EL is half the base layer, else by the same exact-weight
/// bilinear read. These tests run the production composer and read the residual back out of the un-quantised VDR
/// plane, so a different filter (a Catmull-Rom, or nearest), inexact weights or another rounding fail them.
@Suite(.offCooperativePoolOneLane, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct DoviEnhancementUpsamplerTests {

    typealias H = DoviGpuCurveSweepTests

    /// BL luma constant 512 (VDR 2048), EL luma `elColumn(x)` at half resolution, residual scale 2048: the
    /// output is 2048 + floor((2|r| - 1) * 2048 / 4096) with r = el - 512, i.e. |r| - 1 for the codes used here
    /// (|r| of 88 or more is far from the half-step rounding), and the first row is returned.
    private func composeLuma(elColumn: (Int) -> Int) throws -> [Int] {
        let composer = try #require(DoviFelComposer())
        var p = DoviGpuEdgeCaseTests.params(nlqY: DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095))
        p.ditherMode = .debugRawVDR
        let bl = try #require(H.makeBuffer(width: 64, height: 8))
        let el = try #require(H.makeBuffer(width: 32, height: 4))
        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { x, _, _ in elColumn(x) }
        H.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        return Array(DoviTestSupport.rawVDR(out)[0][0..<64])
    }

    /// Residual in VDR codes for an EL code, from the DoViBaker formula (positive side): ((2r - 1) * 2048) >> 12.
    private func residual(_ el: Int) -> Double {
        Double(((2 * (el - 512) - 1) * 2048) >> 12)
    }

    @Test("a linear EL ramp is reproduced between EL texel centres, one bilinear step per base-layer pixel")
    func rampIsLinearlyInterpolated() throws {
        // EL column x is 600 + 4x. BL pixel gx samples EL coordinate gx / 2 - 0.25 (centres at x + 0.5).
        let row = try composeLuma { 600 + 4 * $0 }
        for gx in 2..<62 {
            let elValue = 600.0 + 4.0 * (Double(gx) / 2.0 - 0.25)
            let expected = 2048.0 + (elValue - 512.0) - 0.5     // linear in el: |r| - 1/2
            #expect(abs(Double(row[gx]) - expected) <= 1.5, "gx \(gx): \(row[gx]) vs \(expected)")
        }
    }

    /// Raw VDR code of a mid-grey base (2048) plus the residual of EL code `e` at offset 512, scale 2048:
    /// (|r| - 1) away from zero, nothing at r = 0. The filters overshoot, so a code can fall below 512.
    private static func vdr(el e: Int) -> Int { 2048 + (e > 512 ? e - 513 : e < 512 ? e - 511 : 0) }

    /// Deterministic EL code in 560...899 (all above the NLQ offset 512, so the residual is `e - 513`, linear).
    private static func hashCode(_ x: Int, _ y: Int, _ c: Int) -> Int {
        var h = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ c &* 83492791)
        h ^= h >> 13; h = h &* 0x5bd1e995; h ^= h >> 15
        return 560 + Int(h % 340)
    }

    /// BL constant 512, EL luma/chroma from `elLuma` / `elChroma`, residual on in all three planes; raw 12-bit VDR out.
    private func compose(blWidth: Int, blHeight: Int, elWidth: Int, elHeight: Int, flags: DoviComposerFlags = [],
                         elLuma: (Int, Int) -> Int, elChroma: (Int, Int, Int) -> Int)
        throws -> (planes: [[Int]], params: DoviMetalParams, elBuffer: CVPixelBuffer) {
        let composer = try #require(DoviFelComposer())
        let n = DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095)
        var p = DoviGpuEdgeCaseTests.params(flags: flags, nlqY: n, nlqCb: n, nlqCr: n)
        p.ditherMode = .debugRawVDR
        let bl = try #require(H.makeBuffer(width: blWidth, height: blHeight))
        let el = try #require(H.makeBuffer(width: elWidth, height: elHeight))
        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { x, y, _ in elLuma(x, y) }
        H.fillPlane(el, plane: 1, components: 2) { x, y, c in elChroma(x, y, c) }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        return (DoviTestSupport.rawVDR(out), p, el)
    }

    @Test("EL chroma is the Annex B filter: GPU equals the independent integer model exactly, on every sample, edges included")
    func chromaIsAnnexB() throws {
        // BL 96 x 32, EL 48 x 16, EL chroma 24 x 8 under base chroma 48 x 16: every filter phase, both axes, and
        // the 4-sample edge replication either side.
        let r = try compose(blWidth: 96, blHeight: 32, elWidth: 48, elHeight: 16, elLuma: { _, _ in 512 },
                            elChroma: { x, y, c in Self.hashCode(x, y, c) })
        let model = DoviCpuModelTests.Model(r.params)
        let elUV = DoviCpuModelTests.plane(r.elBuffer, 1, components: 2)
        for c in 0..<2 {
            for y in 0..<16 {
                for x in 0..<48 {
                    let want = Self.vdr(el: model.elChromaCode(elUV, comp: c, x: x, y: y, baseW: 48, baseH: 16))
                    #expect(r.planes[1 + c][y * 48 + x] == want, "c\(c) (\(x), \(y)): \(r.planes[1 + c][y * 48 + x]) vs \(want)")
                }
            }
        }
    }

    @Test("EL chroma at an odd base-layer size (bl + 1 == 2 * el) is the Annex B filter too: GPU equals the model")
    func chromaIsAnnexBAtOddSize() throws {
        // BL 98 x 34 gives base chroma 49 x 17; EL 49 x 17 gives EL chroma 25 x 9, so 49 + 1 == 2 * 25.
        let r = try compose(blWidth: 98, blHeight: 34, elWidth: 49, elHeight: 17, elLuma: { _, _ in 512 },
                            elChroma: { x, y, c in Self.hashCode(x, y, c) })
        let model = DoviCpuModelTests.Model(r.params)
        let elUV = DoviCpuModelTests.plane(r.elBuffer, 1, components: 2)
        for c in 0..<2 {
            for y in 0..<17 {
                for x in 0..<49 {
                    let want = Self.vdr(el: model.elChromaCode(elUV, comp: c, x: x, y: y, baseW: 49, baseH: 17))
                    #expect(r.planes[1 + c][y * 49 + x] == want, "c\(c) (\(x), \(y)): \(r.planes[1 + c][y * 49 + x]) vs \(want)")
                }
            }
        }
    }

    @Test("Annex B chroma impulse response: vertical (64, 192) / 256, horizontal copy on even and the 8-tap on odd samples")
    func chromaImpulseResponse() throws {
        // One EL chroma texel (Cb at column 12, row 4) lifted to 1000 over a plateau of 600 (Cr stays flat).
        let big = 1000
        let r = try compose(blWidth: 96, blHeight: 32, elWidth: 48, elHeight: 16, elLuma: { _, _ in 512 },
                            elChroma: { x, y, c in c == 0 && x == 12 && y == 4 ? big : 600 })
        let cb = r.planes[1], cr = r.planes[2]
        // Vertical response at EL row 4: rows 8 (n = 4, even: 192/256 of the texel, 64/256 of row 3's), 9 (192) and
        // 7 (64 of row 4, odd row n = 3 weights its n + 1), 10 (64 of row 4). Everything else: the plateau.
        func vdr(_ code: Int) -> Int { Self.vdr(el: code) }
        func vert(_ y: Int) -> Int {
            switch y {
            case 8, 9: return (192 * big + 64 * 600 + 128) >> 8
            case 7, 10: return (64 * big + 192 * 600 + 128) >> 8
            default: return 600
            }
        }
        let taps = [22, 94, -524, 2456, 2456, -524, 94, 22]
        for y in 0..<16 {
            for x in 0..<48 {
                let m = x >> 1
                var want = 600
                if x & 1 == 0 {
                    want = m == 12 ? vert(y) : 600
                } else {
                    var acc = 2048
                    for k in 0..<8 { acc += taps[k] * ((min(max(m + k - 3, 0), 23)) == 12 ? vert(y) : 600) }
                    want = acc >> 12
                }
                #expect(cb[y * 48 + x] == vdr(want), "Cb (\(x), \(y)): \(cb[y * 48 + x]) vs \(vdr(want))")
                #expect(cr[y * 48 + x] == vdr(600), "Cr (\(x), \(y)) is flat")
            }
        }
    }

    @Test("an EL at the base layer's size is read texel for texel, in chroma too")
    func sameSizeElChromaIsExact() throws {
        let r = try compose(blWidth: 32, blHeight: 16, elWidth: 32, elHeight: 16, elLuma: { _, _ in 512 },
                            elChroma: { x, y, c in Self.hashCode(x, y, c) })
        for c in 0..<2 {
            for y in 0..<8 {
                for x in 0..<16 {
                    #expect(r.planes[1 + c][y * 16 + x] == 2048 + Self.hashCode(x, y, c) - 513, "c\(c) (\(x), \(y))")
                }
            }
        }
    }

    #if DEBUG
    @Test("DEBUG A/B: with debugCositedElChroma the chroma is read as before, co-sited: even samples on EL texels, odd ones half way")
    func chromaCositedVariant() throws {
        // Quarter-resolution EL: EL chroma 16 x 4 under base chroma 32 x 8. Cb ramps across columns, Cr down
        // rows, 16 codes per EL texel. Base chroma sample n sits at EL texel n / 2, so even samples read one
        // texel exactly; a centre-aligned fetch would read n / 2 - 0.25 and land 4 codes low.
        let r = try compose(blWidth: 64, blHeight: 16, elWidth: 32, elHeight: 8, flags: [.debugCositedElChroma],
                            elLuma: { _, _ in 512 }, elChroma: { x, y, c in 600 + 16 * (c == 0 ? x : y) })
        let cb = r.planes[1], cr = r.planes[2]
        /// EL code at base chroma index n along an axis of `elCount` texels, clamped at the far edge.
        func elAt(_ n: Int, _ elCount: Int) -> Double { 600.0 + 16.0 * min(Double(n) / 2.0, Double(elCount - 1)) }
        /// 2048 + ((2r - 1) * 2048) >> 12 = 2048 + r - 1 for the positive r used here.
        func vdr(_ e: Double) -> Int { 2048 + Int(e.rounded()) - 512 - 1 }
        for y in 0..<8 {
            for x in 0..<32 {
                // Exact on odd samples too: the half-way weight is exact, not the sampler's fixed point.
                let gotCb = cb[y * 32 + x], wantCb = vdr(elAt(x, 16))
                #expect(gotCb == wantCb, "Cb (\(x), \(y)): \(gotCb) vs \(wantCb)")
                let gotCr = cr[y * 32 + x], wantCr = vdr(elAt(y, 4))
                #expect(gotCr == wantCr, "Cr (\(x), \(y)): \(gotCr) vs \(wantCr)")
            }
        }
    }

    /// The Annex B luma filter (B.3), from the standard's equations: vertical 4-tap (/ 128, rounded) then the
    /// same horizontal 8-tap as chroma.
    private static func annexBLuma(_ el: [[Int]], x: Int, y: Int) -> Int {
        let h = el.count, w = el[0].count
        func code(_ c: Int, _ r: Int) -> Int { el[min(max(r, 0), h - 1)][min(max(c, 0), w - 1)] }
        func vertical(_ c: Int) -> Int {
            let n = y >> 1
            let v = y & 1 == 0 ? -3 * code(c, n - 2) + 29 * code(c, n - 1) + 111 * code(c, n) - 9 * code(c, n + 1)
                               : -9 * code(c, n - 1) + 111 * code(c, n) + 29 * code(c, n + 1) - 3 * code(c, n + 2)
            return min(max((v + 64) >> 7, 0), 65535)
        }
        let m = x >> 1
        if x & 1 == 0 { return vertical(min(m, w - 1)) }
        let taps = [22, 94, -524, 2456, 2456, -524, 94, 22]
        var acc = 2048
        for k in 0..<8 { acc += taps[k] * vertical(min(max(m + k - 3, 0), w - 1)) }
        return min(max(acc >> 12, 0), 65535)
    }

    @Test("DEBUG: with debugAnnexBElLuma the luma is the Annex B filter, exactly; without it, still the bilinear read")
    func lumaAnnexBVariant() throws {
        let elW = 48, elH = 16
        let grid = (0..<elH).map { y in (0..<elW).map { x in Self.hashCode(x, y, 0) } }
        let on = try compose(blWidth: 96, blHeight: 32, elWidth: elW, elHeight: elH, flags: [.debugAnnexBElLuma],
                             elLuma: { x, y in grid[y][x] }, elChroma: { _, _, _ in 512 })
        let off = try compose(blWidth: 96, blHeight: 32, elWidth: elW, elHeight: elH,
                              elLuma: { x, y in grid[y][x] }, elChroma: { _, _, _ in 512 })
        var differs = 0
        var bad = [String]()
        for y in 0..<32 {
            for x in 0..<96 {
                let want = Self.vdr(el: Self.annexBLuma(grid, x: x, y: y))
                if on.planes[0][y * 96 + x] != want { bad.append("Y (\(x), \(y)): \(on.planes[0][y * 96 + x]) vs \(want)") }
                if on.planes[0][y * 96 + x] != off.planes[0][y * 96 + x] { differs += 1 }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) mismatches, first: \(bad.prefix(8))")
        #expect(differs > 1000, "the flag must change the luma read (\(differs) samples differ)")
        // The flag off is the centred bilinear read: a 2 x 2 neighbourhood at weights 9 / 3 / 3 / 1 over 16.
        for y in 2..<30 {
            for x in 2..<94 {
                let ex = x >> 1, ey = y >> 1
                let nx = x & 1 == 0 ? max(ex - 1, 0) : min(ex + 1, elW - 1)
                let ny = y & 1 == 0 ? max(ey - 1, 0) : min(ey + 1, elH - 1)
                let v = Double(9 * grid[ey][ex] + 3 * grid[ey][nx] + 3 * grid[ny][ex] + grid[ny][nx]) / 16.0
                #expect(abs(Double(off.planes[0][y * 96 + x]) - (2048.0 + v - 513.0)) <= 1.0, "bilinear Y (\(x), \(y))")
            }
        }
    }
    #endif

    /// Exact bilinear EL code at base-layer column `gx` of a 64-wide row over a 32-wide EL (centre-aligned),
    /// rounded half up.
    private func exactLumaCode(_ gx: Int, _ elColumn: (Int) -> Int) -> Int {
        let u = (Double(gx) + 0.5) / 2.0 - 0.5
        let x0 = Int(floor(u)), fx = u - Double(x0)
        let a = Double(elColumn(min(max(x0, 0), 31))), b = Double(elColumn(min(max(x0 + 1, 0), 31)))
        return Int(floor(a * (1 - fx) + b * fx + 0.5))
    }

    @Test("luma: interpolated EL codes are exact and an exact half rounds up, not to even")
    func lumaHalfRoundsUp() throws {
        // Columns alternate 602 / 600: at the 2:1 quarter weights every base pixel lands on x.5
        // (0.25 * 602 + 0.75 * 600 = 600.5, 0.75 * 602 + 0.25 * 600 = 601.5). Ties-to-even would give 600 and
        // 602, half up gives 601 and 602. Above 512 the residual here is code - 513.
        let column: (Int) -> Int = { $0 % 2 == 0 ? 602 : 600 }
        let row = try composeLuma(elColumn: column)
        for gx in 0..<64 {
            let want = 2048 + exactLumaCode(gx, column) - 513
            #expect(row[gx] == want, "gx \(gx): \(row[gx]) vs \(want)")
        }
        #expect(row.contains(2048 + 601 - 513), "the 600.5 sites round up to 601")
    }

    #if DEBUG
    @Test("DEBUG A/B: the co-sited bilinear chroma read (the fallback for ratios Annex B does not cover) rounds a half-way code up")
    func chromaHalfRoundsUp() throws {
        // Quarter-resolution EL chroma alternating 601 / 600 by column: odd base samples sit half way, at 600.5,
        // which rounds up to 601 (ties-to-even would give 600). Even samples read one texel exactly. The 2:1 chroma
        // of a real stream takes the Annex B filter (integers throughout, half up, tested against its model above),
        // so this reaches the bilinear read through the DEBUG co-sited variant.
        let composer = try #require(DoviFelComposer())
        var p = DoviGpuEdgeCaseTests.params()
        p.ditherMode = .debugRawVDR
        p.flags.formUnion(.debugCositedElChroma)
        let bl = try #require(H.makeBuffer(width: 64, height: 16))
        let el = try #require(H.makeBuffer(width: 32, height: 8))
        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(el, plane: 1, components: 2) { x, _, _ in x % 2 == 0 ? 601 : 600 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        let cb = DoviTestSupport.rawVDR(out, chromaOnly: true)[1]
        for x in 0..<32 {
            let n = x / 2
            let code: Int
            if x % 2 == 0 { code = n % 2 == 0 ? 601 : 600 } else { code = n + 1 > 15 ? (n % 2 == 0 ? 601 : 600) : 601 }
            #expect(cb[x] == 2048 + code - 513, "Cb \(x): \(cb[x]) vs \(2048 + code - 513)")
        }
    }
    #endif

    @Test("a step edge in the EL is blended, never overshot, and the plateaus are exact")
    func stepHasNoRinging() throws {
        let low = 600, high = 700
        let row = try composeLuma { $0 < 16 ? low : high }
        let lo = 2048 + Int(residual(low)), hi = 2048 + Int(residual(high))
        for gx in 0..<64 {
            #expect(row[gx] >= lo && row[gx] <= hi, "gx \(gx) = \(row[gx]) leaves [\(lo), \(hi)]: the filter rings")
        }
        #expect(row[10] == lo)
        #expect(row[53] == hi)
        // The edge sits between EL columns 15 and 16, i.e. BL pixels 31 and 32: one pixel each side is strictly inside.
        let inside = (28..<36).filter { row[$0] > lo && row[$0] < hi }
        #expect(inside.count >= 2 && inside.count <= 4, "edge transition spans \(inside.count) pixels")
        for gx in 1..<64 { #expect(row[gx] >= row[gx - 1], "monotone at \(gx)") }
    }

    @Test("the Annex B filters also read integer EL planes (ushort >> 6): same codes as the model, chroma and luma")
    func annexBReadsIntegerPlanes() throws {
        // Compiles the production shader source plus one probe kernel that runs the filters on r16Uint / rg16Uint
        // textures, the binding a composer that reads the EL as integers would use. 24 x 8 chroma, 48 x 16 luma.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let kernel = """
        kernel void dovi_test_annexb_uint(texture2d<ushort, access::read> uv [[texture(0)]],
                                          texture2d<ushort, access::sample> y [[texture(1)]],
                                          device int4* out [[buffer(0)]],
                                          uint2 gid [[thread_position_in_grid]]) {
            int2 c = dovi_annexb_chroma(uv, gid, int2(int(uv.get_width()), int(uv.get_height())));
            int l = -1;
        #ifdef DOVI_DEBUG_EL_VARIANTS
            l = dovi_annexb_luma(y, gid, int2(int(y.get_width()), int(y.get_height())));
        #endif
            out[gid.y * 48u + gid.x] = int4(c, l, 0);
        }
        """
        let library = try device.makeLibrary(source: DoviShaderSource.source + "\n" + kernel, options: nil)
        let pso = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "dovi_test_annexb_uint")))

        let cw = 24, ch = 8, lw = 48, lh = 16
        var uvWords = [UInt16](repeating: 0, count: cw * ch * 2)
        for y in 0..<ch { for x in 0..<cw { for c in 0..<2 { uvWords[(y * cw + x) * 2 + c] = UInt16(Self.hashCode(x, y, c) << 6) } } }
        var grid = [[Int]](repeating: [Int](repeating: 0, count: lw), count: lh)
        var yWords = [UInt16](repeating: 0, count: lw * lh)
        for y in 0..<lh { for x in 0..<lw { grid[y][x] = Self.hashCode(x, y, 5); yWords[y * lw + x] = UInt16(grid[y][x] << 6) } }
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ words: [UInt16], _ comps: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            let t = try #require(device.makeTexture(descriptor: d))
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: words, bytesPerRow: w * comps * 2)
            return t
        }
        let uvTex = try texture(.rg16Uint, cw, ch, uvWords, 2)
        let yTex = try texture(.r16Uint, lw, lh, yWords, 1)
        let out = try #require(device.makeBuffer(length: lw * lh * MemoryLayout<SIMD4<Int32>>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let cb = try #require(queue.makeCommandBuffer())
        let enc = try #require(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pso)
        enc.setTexture(uvTex, index: 0); enc.setTexture(yTex, index: 1); enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: 48, height: 16, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)

        // The model's chroma, from the same words (the model reads a Plane of raw words).
        let plane = DoviCpuModelTests.Plane(width: cw, height: ch, components: 2, raw: uvWords)
        let model = DoviCpuModelTests.Model(DoviGpuEdgeCaseTests.params())
        let got = out.contents().bindMemory(to: SIMD4<Int32>.self, capacity: lw * lh)
        var bad = [String]()
        for y in 0..<lh {
            for x in 0..<lw {
                let g = got[y * lw + x]
                for c in 0..<2 where Int(g[c]) != model.elChromaCode(plane, comp: c, x: x, y: y, baseW: 48, baseH: 16) {
                    bad.append("chroma c\(c) (\(x), \(y))")
                }
                #if DEBUG
                if Int(g[2]) != Self.annexBLuma(grid, x: x, y: y) { bad.append("luma (\(x), \(y))") }
                #endif
            }
        }
        #expect(bad.isEmpty, "\(bad.count) mismatches, first: \(bad.prefix(6))")
    }
}
#endif
