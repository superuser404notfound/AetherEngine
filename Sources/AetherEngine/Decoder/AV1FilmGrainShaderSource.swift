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

/// Metal source for `GPUFrameConverter`: a planar 10-bit 4:2:0 frame (`yuv420p10le`) into the two planes of a
/// P010 pixel buffer, with AV1 film grain applied on the way when the frame carries its parameters.
///
/// Per pixel this is dav1d's `fgy_32x32xn_c` and `fguv_32x32xn_c` (420): the grain sample of the pixel's
/// block at its random offset, blended over two columns (one in chroma) with the block to the left and two
/// rows (one) with the block above when the stream asks for overlap, scaled by the scaling function at the
/// pixel's own value and added. Integer arithmetic throughout, in the order dav1d does it, so the output is
/// identical to dav1d's. `fg_*` read the frame from buffers and write the destination through `ushort`
/// textures (`r16Uint` / `rg16Uint`), so nothing is ever converted through a float.
enum AV1FilmGrainShaderSource {
    static let source = """
#include <metal_stdlib>
using namespace metal;

struct FGUniforms {
    int width; int height;
    int chromaWidth; int chromaHeight;
    int blockCols;
    int strideY; int strideC;
    int scalingShift;
    int overlap;
    int applyY; int applyCb; int applyCr;
    int chromaFromLuma;
    int uvMultCb; int uvMultCr;
    int uvLumaMultCb; int uvLumaMultCr;
    int uvOffsetCb; int uvOffsetCr;
    int minY; int maxY;
    int minC; int maxC;
};

constant int LUMA_W = 82;
constant int CHROMA_W = 44;
constant int CHROMA_PLANE = 44 * 38;
constant int GRAIN_MIN = -512;
constant int GRAIN_MAX = 511;

inline int round2(int x, int shift) { return (x + ((1 << shift) >> 1)) >> shift; }

/// `sample_lut` for luma: the template sample of block (bx, by) relative to the current one.
inline int luma_grain(device const short *lut, int rv, int bx, int by, int x, int y) {
    int offx = 3 + 2 * (3 + (rv >> 4));
    int offy = 3 + 2 * (3 + (rv & 0xF));
    return lut[(offy + y + 32 * by) * LUMA_W + offx + x + 32 * bx];
}

inline int chroma_grain(device const short *lut, int rv, int bx, int by, int x, int y) {
    int offx = 3 + (3 + (rv >> 4));
    int offy = 3 + (3 + (rv & 0xF));
    return lut[(offy + y + 16 * by) * CHROMA_W + offx + x + 16 * bx];
}

inline int blend(int old_g, int cur_g, int w_old, int w_cur) {
    return clamp(round2(old_g * w_old + cur_g * w_cur, 5), GRAIN_MIN, GRAIN_MAX);
}

kernel void fg_luma(
    device const ushort *src_y       [[buffer(0)]],
    constant FGUniforms &u           [[buffer(1)]],
    device const short *grain_y      [[buffer(2)]],
    device const uchar *scaling      [[buffer(3)]],
    device const uchar *offsets      [[buffer(4)]],
    texture2d<ushort, access::write> out_y [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int x = int(gid.x), y = int(gid.y);
    if (x >= u.width || y >= u.height) return;
    int v = int(src_y[y * u.strideY + x]);
    if (u.applyY != 0) {
        int col = x >> 5, row = y >> 5, lx = x & 31, ly = y & 31;
        int g = luma_grain(grain_y, offsets[row * u.blockCols + col], 0, 0, lx, ly);
        bool left = u.overlap != 0 && col > 0 && lx < 2;
        bool top = u.overlap != 0 && row > 0 && ly < 2;
        int wl0 = lx == 0 ? 27 : 17, wl1 = lx == 0 ? 17 : 27;
        if (left) {
            int old_g = luma_grain(grain_y, offsets[row * u.blockCols + col - 1], 1, 0, lx, ly);
            g = blend(old_g, g, wl0, wl1);
        }
        if (top) {
            int t = luma_grain(grain_y, offsets[(row - 1) * u.blockCols + col], 0, 1, lx, ly);
            if (left) {
                int old_t = luma_grain(grain_y, offsets[(row - 1) * u.blockCols + col - 1], 1, 1, lx, ly);
                t = blend(old_t, t, wl0, wl1);
            }
            int wt0 = ly == 0 ? 27 : 17, wt1 = ly == 0 ? 17 : 27;
            g = blend(t, g, wt0, wt1);
        }
        int noise = round2(int(scaling[v]) * g, u.scalingShift);
        v = clamp(v + noise, u.minY, u.maxY);
    }
    out_y.write(ushort(v << 6), gid);
}

/// One chroma plane's grain at (cx, cy); `which` 0 is Cb, 1 is Cr.
inline int chroma_value(int v, int avg, int which, int cx, int cy,
                        constant FGUniforms &u, device const short *grain_c,
                        device const uchar *scaling, device const uchar *offsets) {
    int col = cx >> 4, row = cy >> 4, lx = cx & 15, ly = cy & 15;
    device const short *lut = grain_c + which * CHROMA_PLANE;
    int g = chroma_grain(lut, offsets[row * u.blockCols + col], 0, 0, lx, ly);
    bool left = u.overlap != 0 && col > 0 && lx < 1;
    bool top = u.overlap != 0 && row > 0 && ly < 1;
    if (left) {
        int old_g = chroma_grain(lut, offsets[row * u.blockCols + col - 1], 1, 0, lx, ly);
        g = blend(old_g, g, 23, 22);
    }
    if (top) {
        int t = chroma_grain(lut, offsets[(row - 1) * u.blockCols + col], 0, 1, lx, ly);
        if (left) {
            int old_t = chroma_grain(lut, offsets[(row - 1) * u.blockCols + col - 1], 1, 1, lx, ly);
            t = blend(old_t, t, 23, 22);
        }
        g = blend(t, g, 23, 22);
    }
    int index = avg;
    device const uchar *table = scaling;
    if (u.chromaFromLuma == 0) {
        int combined = avg * (which == 0 ? u.uvLumaMultCb : u.uvLumaMultCr)
                     + v * (which == 0 ? u.uvMultCb : u.uvMultCr);
        index = clamp((combined >> 6) + (which == 0 ? u.uvOffsetCb : u.uvOffsetCr) * 4, 0, 1023);
        table = scaling + (1 + which) * 1024;
    }
    int noise = round2(int(table[index]) * g, u.scalingShift);
    return clamp(v + noise, u.minC, u.maxC);
}

kernel void fg_chroma(
    device const ushort *src_y       [[buffer(0)]],
    constant FGUniforms &u           [[buffer(1)]],
    device const short *grain_c      [[buffer(2)]],
    device const uchar *scaling      [[buffer(3)]],
    device const uchar *offsets      [[buffer(4)]],
    device const ushort *src_cb      [[buffer(5)]],
    device const ushort *src_cr      [[buffer(6)]],
    texture2d<ushort, access::write> out_uv [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    int cx = int(gid.x), cy = int(gid.y);
    if (cx >= u.chromaWidth || cy >= u.chromaHeight) return;
    int cb = int(src_cb[cy * u.strideC + cx]);
    int cr = int(src_cr[cy * u.strideC + cx]);
    if (u.applyCb != 0 || u.applyCr != 0) {
        int lx = cx << 1, ly = cy << 1;
        int l0 = int(src_y[ly * u.strideY + lx]);
        int l1 = int(src_y[ly * u.strideY + min(lx + 1, u.width - 1)]);
        int avg = (l0 + l1 + 1) >> 1;
        if (u.applyCb != 0) cb = chroma_value(cb, avg, 0, cx, cy, u, grain_c, scaling, offsets);
        if (u.applyCr != 0) cr = chroma_value(cr, avg, 1, cx, cy, u, grain_c, scaling, offsets);
    }
    out_uv.write(ushort4(ushort(cb << 6), ushort(cr << 6), 0, 0), gid);
}
"""
}
