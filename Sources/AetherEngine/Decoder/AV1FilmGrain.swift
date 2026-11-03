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
        lumaGrain = luma.map { Int16($0) }
        var chroma = [Int16](repeating: 0, count: 2 * Self.chromaWidth * Self.chromaHeight)
        let hasLuma = aom.num_y_points > 0
        if u.applyCb != 0 {
            let cb = Self.chromaTemplate(seed: seed ^ 0xB524, shift: shift, lag: lag, coeffs: arCb,
                                         arShift: arShift, luma: luma, addsLuma: hasLuma)
            for i in 0..<cb.count { chroma[i] = Int16(cb[i]) }
        }
        if u.applyCr != 0 {
            let cr = Self.chromaTemplate(seed: seed ^ 0x49D8, shift: shift, lag: lag, coeffs: arCr,
                                         arShift: arShift, luma: luma, addsLuma: hasLuma)
            let base = Self.chromaWidth * Self.chromaHeight
            for i in 0..<cr.count { chroma[base + i] = Int16(cr[i]) }
        }
        chromaGrain = chroma

        var tables = [UInt8](repeating: 0, count: 3 * Self.scalingSize)
        if u.applyY != 0 || u.chromaFromLuma != 0 { Self.fillScaling(&tables, table: 0, points: yPoints) }
        if aom.num_uv_points.0 > 0 { Self.fillScaling(&tables, table: 1, points: cbPoints) }
        if aom.num_uv_points.1 > 0 { Self.fillScaling(&tables, table: 2, points: crPoints) }
        scaling = tables

        // The seed of block row r, then one 8-bit draw per block across the row. dav1d draws the row
        // above again from its own seed for the overlap, which is this same table one row up.
        var table = [UInt8](repeating: 0, count: blockRows * blockCols)
        for row in 0..<blockRows {
            var rowSeed = seed
            rowSeed ^= UInt32(((row * 37 + 178) & 0xFF) << 8)
            rowSeed ^= UInt32((row * 173 + 105) & 0xFF)
            for col in 0..<blockCols {
                table[row * blockCols + col] = UInt8(Self.random(8, &rowSeed))
            }
        }
        offsets = table
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

    /// `generate_grain_y_c`.
    static func lumaTemplate(seed: UInt32, shift: Int, lag: Int, coeffs: [Int8], arShift: Int) -> [Int] {
        let w = lumaWidth, h = lumaHeight
        var buf = [Int](repeating: 0, count: w * h)
        var state = seed
        let gaussian = AV1GaussianSequence.values
        buf.withUnsafeMutableBufferPointer { b in
            for i in 0..<(w * h) {
                b[i] = round2(Int(gaussian[random(11, &state)]), shift)
            }
            for y in 3..<h {
                for x in 3..<(w - 3) {
                    var sum = 0
                    var k = 0
                    rows: for dy in -lag...0 {
                        for dx in -lag...lag {
                            if dx == 0 && dy == 0 { break rows }
                            sum += Int(coeffs[k]) * b[(y + dy) * w + x + dx]
                            k += 1
                        }
                    }
                    b[y * w + x] = min(max(b[y * w + x] + round2(sum, arShift), grainMin), grainMax)
                }
            }
        }
        return buf
    }

    /// `generate_grain_uv_c` at 4:2:0. The last coefficient weighs the co-sited luma grain, averaged
    /// over its 2x2 block, and only when the frame grains luma at all.
    static func chromaTemplate(seed: UInt32, shift: Int, lag: Int, coeffs: [Int8], arShift: Int,
                               luma: [Int], addsLuma: Bool) -> [Int] {
        let w = chromaWidth, h = chromaHeight, lw = lumaWidth
        var buf = [Int](repeating: 0, count: w * h)
        var state = seed
        let gaussian = AV1GaussianSequence.values
        buf.withUnsafeMutableBufferPointer { b in
            for i in 0..<(w * h) {
                b[i] = round2(Int(gaussian[random(11, &state)]), shift)
            }
            for y in 3..<h {
                for x in 3..<(w - 3) {
                    var sum = 0
                    var k = 0
                    rows: for dy in -lag...0 {
                        for dx in -lag...lag {
                            if dx == 0 && dy == 0 {
                                guard addsLuma else { break rows }
                                let lx = ((x - 3) << 1) + 3
                                let ly = ((y - 3) << 1) + 3
                                let l = luma[ly * lw + lx] + luma[ly * lw + lx + 1]
                                    + luma[(ly + 1) * lw + lx] + luma[(ly + 1) * lw + lx + 1]
                                sum += round2(l, 2) * Int(coeffs[k])
                                break rows
                            }
                            sum += Int(coeffs[k]) * b[(y + dy) * w + x + dx]
                            k += 1
                        }
                    }
                    b[y * w + x] = min(max(b[y * w + x] + round2(sum, arShift), grainMin), grainMax)
                }
            }
        }
        return buf
    }

    /// `generate_scaling` at 10 bits: the piecewise-linear function over the 8-bit points, then each
    /// step of four filled in between.
    static func fillScaling(_ tables: inout [UInt8], table: Int, points: [(x: Int, y: Int)]) {
        let shiftX = bitDepth - 8
        let size = scalingSize
        let base = table * size
        guard let first = points.first, let last = points.last else { return }
        var s = [Int](repeating: 0, count: size)
        for i in 0..<min(first.x << shiftX, size) { s[i] = first.y }
        for i in 0..<(points.count - 1) {
            let bx = points[i].x, by = points[i].y
            let dx = points[i + 1].x - bx, dy = points[i + 1].y - by
            guard dx > 0 else { continue }
            let delta = dy * ((0x10000 + (dx >> 1)) / dx)
            var d = 0x8000
            for x in 0..<dx {
                s[(bx + x) << shiftX] = (by + (d >> 16)) & 0xFF
                d += delta
            }
        }
        let n = last.x << shiftX
        for i in n..<size { s[i] = last.y }
        let pad = 1 << shiftX, rnd = pad >> 1
        for i in 0..<(points.count - 1) {
            let bx = points[i].x << shiftX
            let dx = (points[i + 1].x << shiftX) - bx
            var x = 0
            while x < dx {
                let range = s[bx + x + pad] - s[bx + x]
                var r = rnd
                for n in 1..<pad {
                    r += range
                    s[bx + x + n] = (s[bx + x] + (r >> shiftX)) & 0xFF
                }
                x += pad
            }
        }
        for i in 0..<size { tables[base + i] = UInt8(s[i]) }
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
