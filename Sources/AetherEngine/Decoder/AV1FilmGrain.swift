// Ported from dav1d's film grain synthesis (src/filmgrain_tmpl.c, src/fg_apply_tmpl.c, dav1d 1.5.4) so
// the output is dav1d's sample for sample. dav1d's notice, which its BSD 2-clause licence asks to keep:
//
// Copyright © 2018, Niklas Haas
// Copyright © 2018, VideoLAN and dav1d authors
// Copyright © 2018, Two Orioles, LLC
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
import AetherLibavutil

/// The per-frame half of AV1 film grain synthesis (AV1 7.18.3), for a 10-bit 4:2:0 picture: the grain
/// templates, the scaling functions and the block offsets, computed on the CPU the way dav1d's
/// `dav1d_prep_grain` and `fg*_32x32xn_c` compute them, so the picture `GPUFrameConverter` grains is
/// bit for bit the one dav1d would have output. Everything per pixel runs on the GPU.
///
/// dav1d applying grain itself costs about a tenth of a 4K decode (a 4K film at 54 Mbit/s, 4.7 of 45 CPU
/// seconds on an M5 Pro), on the same cores the decode needs; on a fanless Apple TV that
/// share is heat it does not have to make. The tables below are about 30 KB and well under a
/// millisecond of work.
///
/// They are built once per frame on the decoder's thread, so the loops run over raw pointers with
/// `while`: in a debug build (the package unoptimised, as a host's Debug configuration compiles it)
/// every `Array` subscript and every `for ... in` step is a call, and the same arithmetic took 40.8 ms
/// a frame on an M1. On an Apple TV 4K (A15) the encode around it took 40 to 44 ms, the whole frame
/// interval at 23.976 fps. Written this way the tables take well under 2 ms unoptimised
/// and under 1 ms optimised on the M1 (see measurements.md).
struct AV1FilmGrainTables {

    /// `GRAIN_WIDTH` x `GRAIN_HEIGHT`: the luma template.
    static let lumaWidth = 82
    static let lumaHeight = 73
    /// `SUB_GRAIN_WIDTH` x `SUB_GRAIN_HEIGHT`: a chroma template at 4:2:0.
    static let chromaWidth = 44
    static let chromaHeight = 38
    static let blockSize = 32
    static let bitDepth = 10
    static let scalingSize = 1 << bitDepth

    /// Mirrors `FGUniforms` in `AV1FilmGrainShaderSource`, field for field (all 32-bit, no padding).
    struct Uniforms {
        var width: Int32 = 0
        var height: Int32 = 0
        var chromaWidth: Int32 = 0
        var chromaHeight: Int32 = 0
        var blockCols: Int32 = 0
        var strideY: Int32 = 0
        var strideC: Int32 = 0
        var scalingShift: Int32 = 0
        var overlap: Int32 = 0
        var applyY: Int32 = 0
        var applyCb: Int32 = 0
        var applyCr: Int32 = 0
        var chromaFromLuma: Int32 = 0
        var uvMultCb: Int32 = 0
        var uvMultCr: Int32 = 0
        var uvLumaMultCb: Int32 = 0
        var uvLumaMultCr: Int32 = 0
        var uvOffsetCb: Int32 = 0
        var uvOffsetCr: Int32 = 0
        var minY: Int32 = 0
        var maxY: Int32 = 1023
        var minC: Int32 = 0
        var maxC: Int32 = 1023
    }

    var uniforms = Uniforms()
    /// `lumaHeight` rows of `lumaWidth`.
    var lumaGrain: [Int16]
    /// `chromaHeight` rows of `chromaWidth`, Cb then Cr.
    var chromaGrain: [Int16]
    /// Three `scalingSize` tables: luma, Cb, Cr.
    var scaling: [UInt8]
    /// One 8-bit offset per 32x32 luma block (16x16 chroma), row-major, `uniforms.blockCols` wide.
    var offsets: [UInt8]

    /// Nil when the parameters are not ones this path grains: not AV1's, not 10-bit 4:2:0.
    init?(params: AVFilmGrainParams, width: Int, height: Int, identityMatrix: Bool) {
        guard params.type == AV_FILM_GRAIN_PARAMS_AV1,
              params.subsampling_x == 1, params.subsampling_y == 1,
              params.bit_depth_luma == 0 || params.bit_depth_luma == Int32(Self.bitDepth),
              width > 0, height > 0
        else { return nil }
        let aom = params.codec.aom
        let seed = UInt32(truncatingIfNeeded: params.seed) & 0xFFFF
        let lag = Int(aom.ar_coeff_lag)
        guard (0...3).contains(lag), (8...11).contains(aom.scaling_shift),
              (6...9).contains(aom.ar_coeff_shift), (0...3).contains(aom.grain_scale_shift)
        else { return nil }

        var u = Uniforms()
        u.width = Int32(width)
        u.height = Int32(height)
        u.chromaWidth = Int32((width + 1) >> 1)
        u.chromaHeight = Int32((height + 1) >> 1)
        let blockCols = (width + Self.blockSize - 1) / Self.blockSize
        let blockRows = (height + Self.blockSize - 1) / Self.blockSize
        u.blockCols = Int32(blockCols)
        u.scalingShift = aom.scaling_shift
        u.overlap = aom.overlap_flag != 0 ? 1 : 0
        u.chromaFromLuma = aom.chroma_scaling_from_luma != 0 ? 1 : 0
        u.applyY = aom.num_y_points > 0 ? 1 : 0
        u.applyCb = (aom.num_uv_points.0 > 0 || u.chromaFromLuma != 0) ? 1 : 0
        u.applyCr = (aom.num_uv_points.1 > 0 || u.chromaFromLuma != 0) ? 1 : 0
        u.uvMultCb = aom.uv_mult.0
        u.uvMultCr = aom.uv_mult.1
        u.uvLumaMultCb = aom.uv_mult_luma.0
        u.uvLumaMultCr = aom.uv_mult_luma.1
        u.uvOffsetCb = aom.uv_offset.0
        u.uvOffsetCr = aom.uv_offset.1
        let depthShift = Int32(Self.bitDepth - 8)
        if aom.limit_output_range != 0 {
            u.minY = 16 << depthShift
            u.maxY = 235 << depthShift
            u.minC = 16 << depthShift
            u.maxC = (identityMatrix ? 235 : 240) << depthShift
        }
        uniforms = u

        let yPoints = Self.points(aom.y_points, count: Int(aom.num_y_points), limit: 14)
        let cbPoints = Self.points(aom.uv_points.0, count: Int(aom.num_uv_points.0), limit: 10)
        let crPoints = Self.points(aom.uv_points.1, count: Int(aom.num_uv_points.1), limit: 10)
        let arY = Self.int8s(aom.ar_coeffs_y)
        let arCb = Self.int8s(aom.ar_coeffs_uv.0)
        let arCr = Self.int8s(aom.ar_coeffs_uv.1)
        let shift = 4 - Int(depthShift) + Int(aom.grain_scale_shift)
        let arShift = Int(aom.ar_coeff_shift)

        let luma = Self.lumaTemplate(seed: seed, shift: shift, lag: lag, coeffs: arY, arShift: arShift)
        var lumaOut = [Int16](repeating: 0, count: luma.count)
        Self.narrow(luma, into: &lumaOut)
        lumaGrain = lumaOut
        var chroma = [Int16](repeating: 0, count: 2 * Self.chromaWidth * Self.chromaHeight)
        let hasLuma = aom.num_y_points > 0
        if u.applyCb != 0 {
            let cb = Self.chromaTemplate(seed: seed ^ 0xB524, shift: shift, lag: lag, coeffs: arCb,
                                         arShift: arShift, luma: luma, addsLuma: hasLuma)
            Self.narrow(cb, into: &chroma)
        }
        if u.applyCr != 0 {
            let cr = Self.chromaTemplate(seed: seed ^ 0x49D8, shift: shift, lag: lag, coeffs: arCr,
                                         arShift: arShift, luma: luma, addsLuma: hasLuma)
            Self.narrow(cr, into: &chroma, at: Self.chromaWidth * Self.chromaHeight)
        }
        chromaGrain = chroma

        var tables = [UInt8](repeating: 0, count: 3 * Self.scalingSize)
        if u.applyY != 0 || u.chromaFromLuma != 0 { Self.fillScaling(&tables, table: 0, points: yPoints) }
        if aom.num_uv_points.0 > 0 { Self.fillScaling(&tables, table: 1, points: cbPoints) }
        if aom.num_uv_points.1 > 0 { Self.fillScaling(&tables, table: 2, points: crPoints) }
        scaling = tables

        offsets = Self.blockOffsets(seed: seed, blockCols: blockCols, blockRows: blockRows)
    }

    // MARK: - dav1d's arithmetic

    /// `get_random_number`: the 16-bit LFSR of AV1 7.18.3.2.
    @inline(__always)
    static func random(_ bits: Int, _ state: inout UInt32) -> Int {
        let r = state
        let bit = ((r >> 0) ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
        state = (r >> 1) | (bit << 15)
        return Int((state >> UInt32(16 - bits)) & ((1 << UInt32(bits)) - 1))
    }

    @inline(__always)
    static func round2(_ x: Int, _ shift: Int) -> Int {
        (x + ((1 << shift) >> 1)) >> shift
    }

    private static let grainMin = -(128 << (bitDepth - 8))
    private static let grainMax = (128 << (bitDepth - 8)) - 1

    /// The offset of each 32x32 block: the seed of block row r, then one 8-bit draw per block across the
    /// row. dav1d draws the row above again from its own seed for the overlap, which is this same table one
    /// row up.
    static func blockOffsets(seed: UInt32, blockCols: Int, blockRows: Int) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: blockRows * blockCols)
        let frameSeed = Int(seed)
        table.withUnsafeMutableBufferPointer { tp in
            guard let t = tp.baseAddress else { return }
            var row = 0
            while row < blockRows {
                var state = frameSeed ^ (((row * 37 + 178) & 0xFF) << 8) ^ ((row * 173 + 105) & 0xFF)
                var col = 0
                while col < blockCols {
                    // `random(8, &state)`, written out (see `lumaTemplate`).
                    let bit = (state ^ (state >> 1) ^ (state >> 3) ^ (state >> 12)) & 1
                    state = (state >> 1) | (bit << 15)
                    t[row * blockCols + col] = UInt8(truncatingIfNeeded: state >> 8)
                    col += 1
                }
                row += 1
            }
        }
        return table
    }

    /// The neighbours the auto-regressive filter weighs, as offsets into a template `width` wide, in
    /// coefficient order: rows `-lag...0`, columns `-lag...lag`, up to the sample itself.
    static func neighbours(lag: Int, width: Int) -> [Int] {
        var out: [Int] = []
        var dy = -lag
        while dy <= 0 {
            var dx = -lag
            while dx <= lag {
                if dy == 0 && dx == 0 { return out }
                out.append(dy * width + dx)
                dx += 1
            }
            dy += 1
        }
        return out
    }

    /// `AV1GaussianSequence.values` widened once, so the per-sample reads need no conversion.
    private static let gaussian: [Int] = AV1GaussianSequence.values.map { Int($0) }

    /// `generate_grain_y_c`. `random(11, &state)` and `round2` are written out in the loops: unoptimised,
    /// a call per sample was most of the cost (see the type's comment).
    static func lumaTemplate(seed: UInt32, shift: Int, lag: Int, coeffs: [Int8], arShift: Int) -> [Int] {
        let w = lumaWidth, h = lumaHeight
        var buf = [Int](repeating: 0, count: w * h)
        let offsets = neighbours(lag: lag, width: w)
        let count = offsets.count
        let weights = coeffs.prefix(count).map { Int($0) } + [0]
        let rounding = (1 << shift) >> 1, arRounding = (1 << arShift) >> 1
        let lo = grainMin, hi = grainMax
        var state = Int(seed)
        gaussian.withUnsafeBufferPointer { gp in
        offsets.withUnsafeBufferPointer { op in
        weights.withUnsafeBufferPointer { wp in
        buf.withUnsafeMutableBufferPointer { bp in
            let g = gp.baseAddress!, c = wp.baseAddress!, b = bp.baseAddress!
            var i = 0
            while i < w * h {
                let bit = (state ^ (state >> 1) ^ (state >> 3) ^ (state >> 12)) & 1
                state = (state >> 1) | (bit << 15)
                b[i] = (g[(state >> 5) & 0x7FF] + rounding) >> shift
                i += 1
            }
            guard count > 0, let off = op.baseAddress else { return }
            var y = 3
            while y < h {
                var x = 3
                while x < w - 3 {
                    let at = y * w + x
                    var sum = 0
                    var k = 0
                    while k < count {
                        sum += c[k] * b[at + off[k]]
                        k += 1
                    }
                    var v = b[at] + ((sum + arRounding) >> arShift)
                    if v < lo { v = lo } else if v > hi { v = hi }
                    b[at] = v
                    x += 1
                }
                y += 1
            }
        }}}}
        return buf
    }

    /// `generate_grain_uv_c` at 4:2:0. The last coefficient weighs the co-sited luma grain, averaged
    /// over its 2x2 block, and only when the frame grains luma at all.
    static func chromaTemplate(seed: UInt32, shift: Int, lag: Int, coeffs: [Int8], arShift: Int,
                               luma: [Int], addsLuma: Bool) -> [Int] {
        let w = chromaWidth, h = chromaHeight, lw = lumaWidth
        var buf = [Int](repeating: 0, count: w * h)
        let offsets = neighbours(lag: lag, width: w)
        let count = offsets.count
        let weights = coeffs.prefix(count + 1).map { Int($0) } + [0]
        let lumaWeight = addsLuma ? weights[count] : 0
        let rounding = (1 << shift) >> 1, arRounding = (1 << arShift) >> 1
        let lo = grainMin, hi = grainMax
        var state = Int(seed)
        gaussian.withUnsafeBufferPointer { gp in
        offsets.withUnsafeBufferPointer { op in
        weights.withUnsafeBufferPointer { wp in
        luma.withUnsafeBufferPointer { lp in
        buf.withUnsafeMutableBufferPointer { bp in
            let g = gp.baseAddress!, c = wp.baseAddress!, l = lp.baseAddress!, b = bp.baseAddress!
            var i = 0
            while i < w * h {
                let bit = (state ^ (state >> 1) ^ (state >> 3) ^ (state >> 12)) & 1
                state = (state >> 1) | (bit << 15)
                b[i] = (g[(state >> 5) & 0x7FF] + rounding) >> shift
                i += 1
            }
            let off = op.baseAddress
            var y = 3
            while y < h {
                var x = 3
                while x < w - 3 {
                    let at = y * w + x
                    var sum = 0
                    var k = 0
                    while k < count {
                        sum += c[k] * b[at + off![k]]
                        k += 1
                    }
                    if addsLuma {
                        let la = (((y - 3) << 1) + 3) * lw + ((x - 3) << 1) + 3
                        sum += ((l[la] + l[la + 1] + l[la + lw] + l[la + lw + 1] + 2) >> 2) * lumaWeight
                    }
                    var v = b[at] + ((sum + arRounding) >> arShift)
                    if v < lo { v = lo } else if v > hi { v = hi }
                    b[at] = v
                    x += 1
                }
                y += 1
            }
        }}}}}
        return buf
    }

    /// `values` into `destination` from `offset` on, narrowed to 16 bits (a template stays within the
    /// 10-bit grain range). A pointer loop, for the reason the type's comment gives.
    static func narrow(_ values: [Int], into destination: inout [Int16], at offset: Int = 0) {
        values.withUnsafeBufferPointer { sp in
        destination.withUnsafeMutableBufferPointer { dp in
            guard let s = sp.baseAddress, let d = dp.baseAddress, offset >= 0, offset + sp.count <= dp.count else { return }
            var i = 0
            while i < sp.count {
                d[offset + i] = Int16(truncatingIfNeeded: s[i])
                i += 1
            }
        }}
    }

    /// `generate_scaling` at 10 bits: the piecewise-linear function over the 8-bit points, then each
    /// step of four filled in between. Written over a pointer, for the reason the type's comment gives.
    static func fillScaling(_ tables: inout [UInt8], table: Int, points: [(x: Int, y: Int)]) {
        let shiftX = bitDepth - 8
        let size = scalingSize
        guard let first = points.first, let last = points.last, table >= 0, (table + 1) * size <= tables.count
        else { return }
        let xs = points.map(\.x), ys = points.map(\.y)
        let segments = points.count - 1
        var s = [Int](repeating: 0, count: size)
        s.withUnsafeMutableBufferPointer { sp in
            let v = sp.baseAddress!
            // Up to the first point: its value.
            let firstEnd = min(first.x << shiftX, size)
            var i = 0
            while i < firstEnd {
                v[i] = first.y
                i += 1
            }
            // Between points: the line through them, every fourth entry.
            var p = 0
            while p < segments {
                let bx = xs[p], by = ys[p]
                let dx = xs[p + 1] - bx, dy = ys[p + 1] - by
                if dx > 0 {
                    let delta = dy * ((0x10000 + (dx >> 1)) / dx)
                    var d = 0x8000
                    var x = 0
                    while x < dx {
                        v[(bx + x) << shiftX] = (by + (d >> 16)) & 0xFF
                        d += delta
                        x += 1
                    }
                }
                p += 1
            }
            // From the last point on: its value.
            i = last.x << shiftX
            while i < size {
                v[i] = last.y
                i += 1
            }
            // The three entries between each pair of those.
            let pad = 1 << shiftX, rnd = pad >> 1
            p = 0
            while p < segments {
                let bx = xs[p] << shiftX
                let dx = (xs[p + 1] << shiftX) - bx
                var x = 0
                while x < dx {
                    let range = v[bx + x + pad] - v[bx + x]
                    var r = rnd
                    var k = 1
                    while k < pad {
                        r += range
                        v[bx + x + k] = (v[bx + x] + (r >> shiftX)) & 0xFF
                        k += 1
                    }
                    x += pad
                }
                p += 1
            }
        }
        s.withUnsafeBufferPointer { sp in
        tables.withUnsafeMutableBufferPointer { tp in
            let v = sp.baseAddress!, t = tp.baseAddress! + table * size
            var i = 0
            while i < size {
                t[i] = UInt8(truncatingIfNeeded: v[i])
                i += 1
            }
        }}
    }

    // MARK: - Reading the C tuples

    private static func points<T>(_ tuple: T, count: Int, limit: Int) -> [(x: Int, y: Int)] {
        withUnsafeBytes(of: tuple) { raw in
            (0..<min(max(count, 0), limit)).map { (x: Int(raw[2 * $0]), y: Int(raw[2 * $0 + 1])) }
        }
    }

    private static func int8s<T>(_ tuple: T) -> [Int8] {
        withUnsafeBytes(of: tuple) { raw in raw.map { Int8(bitPattern: $0) } }
    }
}
