// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation

/// Canonical Metal source for the Dolby Vision FEL composer.
///
/// `DoviFelComposer` compiles ``source`` at runtime with
/// `MTLDevice.makeLibrary(source:)` on demand.
enum DoviShaderSource {

    /// Metal-side spelling of the fixed-width typedefs the shared block uses.
    static let preamble = """
#include <metal_stdlib>
using namespace metal;

typedef uint dovi_u32;
typedef int  dovi_i32;
"""

    /// Definitions of the parameters and structs consumed by the Metal kernels.
    static let sharedStructs = """
/* DOVI_SHARED_STRUCTS_BEGIN */
/* ---- Target output modes (informational; the composer always emits
   video-range 10-bit P010, so this does not currently switch clamping) ---- */
#define DOVI_TARGET_MODE_PROFILE_8_1  0 /* Rec.2020 YCbCr PQ 10-bit limited range */
#define DOVI_TARGET_MODE_PROFILE_5    1 /* Dolby IPTPQc2 10-bit full range */

/* ---- Dither modes ---- */
#define DOVI_DITHER_NONE              0 /* round to nearest */
#define DOVI_DITHER_BAYER_8X8         1 /* ordered dither, inverted on odd frames */
#define DOVI_DITHER_FULL_PRECISION    3 /* keep the VDR bits below the 10-bit code in P010's low 6 bits */
#define DOVI_DEBUG_RAW_VDR            2 /* test only: write the un-quantised VDR code << 4 (12-bit in 16) */

/* ---- nlq_method_idc (ETSI GS CCM 001). Anything other than LINEAR yields no
   residual rather than a wrong inverse, degrading to base-layer output. ---- */
#define DOVI_NLQ_METHOD_LINEAR        0
#define DOVI_NLQ_METHOD_NONE          0xFFFFFFFFu

/* ---- mapping_idc, per reshaping piece ---- */
#define DOVI_MAPPING_POLYNOMIAL       0
#define DOVI_MAPPING_MMR              1

/* ---- flags ---- */
#define DOVI_FLAG_DISABLE_RESIDUAL    0x1u /* disable_residual_flag, or el_type == MEL */
#define DOVI_FLAG_LUMA_MMR            0x2u /* luma curve has at least one MMR piece */

/* Piecewise reshaping curve for one component.
 *
 * num_pivots < 2 means "identity passthrough"; the parser installs that as the
 * fail-safe whenever a curve cannot be trusted, so a malformed RPU degrades to
 * the base layer instead of to black.
 *
 * pivots are absolute (prefix-summed) BL code values, ascending, and pivots[0]
 * / pivots[num_pivots - 1] bound the evaluation domain. method[i] selects how
 * piece i is evaluated. The syntax lets a component mix polynomial and MMR
 * pieces, but libdovi keeps one mapping_idc per component (the last piece's) and
 * one coefficient list per method, so a mixed curve cannot be read back
 * through its C API, and DoviRpuGuard refuses it before it gets here: in
 * practice every piece of a component has the same method. order[i] is
 * the polynomial order for a polynomial piece and the MMR order for an MMR
 * piece. coef[i][j] is Q(coef_shift[i]) and is evaluated against inputs
 * normalised by dividing the BL code value by 2^bl_bit_depth (bl_max + 1), the
 * fixed-point convention of the spec's pseudo-code. */
struct DoviPolynomialParams {
    dovi_u32 num_pivots;
    dovi_u32 pivots[9];
    dovi_u32 method[8];
    dovi_u32 order[8];
    dovi_i32 coef[8][3];
    dovi_u32 coef_shift[8];
};

/* Multiple-model regression coefficients, one set per reshaping piece.
 *
 * The piece count, the per-piece MMR order and the piece selection all live in
 * the matching DoviPolynomialParams; this block only carries the coefficients,
 * laid out as coef[piece][order * 7 + term] over the seven cross terms
 * [y, u, v, yu, yv, uv, yuv]. Order o contributes those terms raised to the
 * power o + 1. Every coefficient is Q(coef_shift) against normalised inputs. */
struct DoviMmrParams {
    dovi_i32 mmr_constant[8];
    dovi_i32 coef[8][21];
    dovi_u32 coef_shift;
};

/* Inverse non-linear quantisation for one component.
 *
 * nlq_scale and nlq_threshold are Q(coefficient_log2_denom) in the normalised
 * residual domain; nlq_shift = coefficient_log2_denom - vdr_bit_depth converts
 * that product into VDR code units. vdr_in_max is the ceiling already reduced
 * to VDR code units by the parser. */
struct DoviNlqParams {
    dovi_u32 nlq_method;
    dovi_i32 nlq_offset;
    dovi_i32 nlq_scale;
    dovi_i32 nlq_threshold;
    dovi_i32 vdr_in_max;
    dovi_u32 nlq_shift;
    dovi_u32 nlq_pivots[2];
};

struct DoviMetalParams {
    dovi_u32 bl_width;
    dovi_u32 bl_height;
    dovi_u32 el_width;
    dovi_u32 el_height;

    dovi_u32 target_mode;
    dovi_u32 dither_mode;
    dovi_u32 frame_index;
    dovi_u32 flags;

    struct DoviPolynomialParams poly_y;
    struct DoviMmrParams        mmr_y;
    struct DoviNlqParams        nlq_y;

    struct DoviPolynomialParams poly_cb;
    struct DoviMmrParams        mmr_cb;
    struct DoviNlqParams        nlq_cb;

    struct DoviPolynomialParams poly_cr;
    struct DoviMmrParams        mmr_cr;
    struct DoviNlqParams        nlq_cr;

    dovi_u32 min_pq;
    dovi_u32 max_pq;
    dovi_u32 avg_pq;

    /* Bit-depth derived constants, so the kernels carry no literal 1023/4095.
       bl_max   = (1 << bl_bit_depth) - 1
       vdr_max  = (1 << vdr_bit_depth) - 1
       vdr_scale = 1 << (vdr_bit_depth - bl_bit_depth)
       Curve inputs are normalised by 2^bl_bit_depth (bl_max + 1) and a normalised
       prediction is denormalised by (bl_max + 1) * vdr_scale = 2^vdr_bit_depth, the
       same scale both ways, so an identity curve is bit-exact and a neutral chroma
       (code 512) maps to exactly 2048 (DoViBaker agrees; scaling by bl_max instead
       puts it at 2049, and up to 2041 through an MMR constant). */
    dovi_u32 bl_max;
    dovi_u32 vdr_max;
    dovi_u32 vdr_scale;
};
/* DOVI_SHARED_STRUCTS_END */
"""

    /// Kernel bodies and their helpers: the only place the composition math is
    /// written down, shared by both consumers unchanged.
    static let kernels = """

/* ============================================================================
   Ordered dither
   ========================================================================= */

constant float dovi_bayer_8x8[64] = {
     0.0f/64.0f, 32.0f/64.0f,  8.0f/64.0f, 40.0f/64.0f,  2.0f/64.0f, 34.0f/64.0f, 10.0f/64.0f, 42.0f/64.0f,
    48.0f/64.0f, 16.0f/64.0f, 56.0f/64.0f, 24.0f/64.0f, 50.0f/64.0f, 18.0f/64.0f, 58.0f/64.0f, 26.0f/64.0f,
    12.0f/64.0f, 44.0f/64.0f,  4.0f/64.0f, 36.0f/64.0f, 14.0f/64.0f, 46.0f/64.0f,  6.0f/64.0f, 38.0f/64.0f,
    60.0f/64.0f, 28.0f/64.0f, 52.0f/64.0f, 20.0f/64.0f, 62.0f/64.0f, 30.0f/64.0f, 54.0f/64.0f, 22.0f/64.0f,
     3.0f/64.0f, 35.0f/64.0f, 11.0f/64.0f, 43.0f/64.0f,  1.0f/64.0f, 33.0f/64.0f,  9.0f/64.0f, 41.0f/64.0f,
    51.0f/64.0f, 19.0f/64.0f, 59.0f/64.0f, 27.0f/64.0f, 49.0f/64.0f, 17.0f/64.0f, 57.0f/64.0f, 25.0f/64.0f,
    15.0f/64.0f, 47.0f/64.0f,  7.0f/64.0f, 39.0f/64.0f, 13.0f/64.0f, 45.0f/64.0f,  5.0f/64.0f, 37.0f/64.0f,
    63.0f/64.0f, 31.0f/64.0f, 55.0f/64.0f, 23.0f/64.0f, 61.0f/64.0f, 29.0f/64.0f, 53.0f/64.0f, 21.0f/64.0f
};

// Ordered dither offset in [0.5/64, 63.5/64], whose mean over the cell is
// exactly 0.5 -- the same rounding bias the undithered branch applies.
//
// The raw Bayer table holds k/64 for k in 0..63 and averages 31.5/64 = 0.4921875,
// 1/128 of a code low. That bias is invisible at any bit depth a Dolby Vision
// stream can ask for: the value reaching the rounding step has a fraction of
// j/vdr_scale, and for vdr_scale <= 64 the raw and centred tables select exactly
// the same cells at every j, so 10-bit BL into 12-bit VDR (vdr_scale = 4) is
// bit-identical either way. It becomes visible only at the vdr_scale >= 128 that
// setBitDepths still accepts, where the raw table's worst per-level error is
// 0.0117 codes against the centred table's 0.0078. Centring costs one add, makes
// the mean exactly 0.5 as claimed, and removes the case where it would matter.
//
// phase translates the cell so that two components written from the same value do
// not receive the same pattern. Not every translation does that: this matrix
// satisfies M[(y + 4) % 8][(x + 4) % 8] == M[y][x] +/- 1, so the (4, 4) diagonal
// is its own near-symmetry (a Cr phase there leaves Cb and Cr disagreeing on
// an average of 1 pixel in 64 -- at the 50% level, where the selected set is a
// checkerboard in (x + y) parity and a (4, 4) shift preserves parity, on zero
// pixels). Translations of odd parity are the ones that decorrelate, averaging 32
// pixels in 64. Parity is additive, so three mutually odd offsets do not exist;
// (0, 0) / (1, 0) / (1, 1) makes the two chroma components and the luma-Cb pair
// odd and leaves luma-Cr, which is also the pair that differs in plane and in
// resolution, at 16 in 64.
static inline float dovi_dither(uint2 gid, uint frame_index, uint2 phase) {
    uint dx = (gid.x + phase.x) % 8u;
    uint dy = (gid.y + phase.y) % 8u;
    float d = dovi_bayer_8x8[dy * 8u + dx];
    if (frame_index & 1u) {
        // Inversion is over the raw table, so the frame pair still covers every
        // cell exactly once; the half-step is added to both frames afterwards.
        d = (63.0f / 64.0f) - d;
    }
    return d + (0.5f / 64.0f);
}

/* ============================================================================
   Reshaping curve evaluation
   ========================================================================= */

// Index of the piece owning bl_val: the last pivot that bl_val reaches.
// Deliberately last-match-wins rather than first, because adjacent pivots can
// repeat (a zero-width piece) and the spec assigns the sample to the later one.
static inline int dovi_select_piece(constant struct DoviPolynomialParams &curve, int bl_val) {
    int last_piece = int(curve.num_pivots) - 2;
    int piece = 0;
    for (int i = 0; i <= last_piece; ++i) {
        if (bl_val >= int(curve.pivots[i])) {
            piece = i;
        }
    }
    return clamp(piece, 0, max(last_piece, 0));
}

// Polynomial piece, evaluated on the input normalised by `bl_max`. Callers pass
// bl_max + 1 (= 2^bl_bit_depth), the same normaliser as the y/u/v inputs.
// Returns the prediction in normalised units; dovi_denormalize clamps it to [0, vdr_max] before the
// residual is added (DoViBaker clamps `vv`/`rr` to [0, 0xffff] there), and the sum is clamped again afterwards.
static inline float dovi_eval_poly(
    constant struct DoviPolynomialParams &curve,
    int piece,
    int bl_val,
    uint bl_max)
{
    int lo = int(curve.pivots[0]);
    int hi = int(curve.pivots[curve.num_pivots - 1]);
    float x = float(clamp(bl_val, lo, hi)) / float(bl_max);

    float inv = ldexp(1.0f, -int(curve.coef_shift[piece]));
    float pred = float(curve.coef[piece][0]) * inv;
    uint order = curve.order[piece];
    if (order >= 1u) {
        pred = fma(float(curve.coef[piece][1]) * inv, x, pred);
    }
    if (order >= 2u) {
        pred = fma(float(curve.coef[piece][2]) * inv, x * x, pred);
    }
    return pred;
}

// An MMR input clamped to the pivot range of its own component (luma to poly_y's, Cb to poly_cb's,
// Cr to poly_cr's), as DoViBaker's `mmrMapping` does before it forms the cross terms. A component with
// no usable curve (num_pivots < 2) has no range and is left as is.
static inline float dovi_clamp_mmr_input(constant struct DoviPolynomialParams &curve, float norm, float scale) {
    if (curve.num_pivots < 2u) {
        return norm;
    }
    float lo = float(curve.pivots[0]) / scale;
    float hi = float(curve.pivots[curve.num_pivots - 1u]) / scale;
    return clamp(norm, lo, hi);
}

// MMR piece: a regression over the seven cross terms of all three normalised
// base-layer components, with order o contributing those terms raised to o + 1.
static inline float dovi_eval_mmr(
    constant struct DoviPolynomialParams &curve,
    constant struct DoviMmrParams &mmr,
    int piece,
    float y_norm, float u_norm, float v_norm)
{
    // y_norm, u_norm and v_norm are already clamped to their components' pivot ranges.
    float inv = ldexp(1.0f, -int(mmr.coef_shift));
    float s = float(mmr.mmr_constant[piece]) * inv;

    float base[7] = {
        y_norm,
        u_norm,
        v_norm,
        y_norm * u_norm,
        y_norm * v_norm,
        u_norm * v_norm,
        y_norm * u_norm * v_norm
    };
    float t[7];
    for (int k = 0; k < 7; ++k) {
        t[k] = base[k];
    }

    uint order = min(curve.order[piece], 3u);
    for (uint o = 0u; o < order; ++o) {
        for (int k = 0; k < 7; ++k) {
            s = fma(float(mmr.coef[piece][o * 7u + uint(k)]) * inv, t[k], s);
        }
        if (o + 1u < order) {
            for (int k = 0; k < 7; ++k) {
                t[k] *= base[k];
            }
        }
    }
    return s;
}

// One component's reshaping prediction, in normalised [0, 1] units.
// num_pivots < 2 is the parser's fail-safe for a curve it could not trust, and
// means identity: the base layer passes through untouched.
static inline float dovi_eval_curve(
    constant struct DoviPolynomialParams &curve,
    constant struct DoviMmrParams &mmr,
    constant struct DoviPolynomialParams &poly_y,
    constant struct DoviPolynomialParams &poly_cb,
    constant struct DoviPolynomialParams &poly_cr,
    int bl_val,
    float y_norm, float u_norm, float v_norm,
    uint bl_max)
{
    if (curve.num_pivots < 2u) {
        return float(bl_val) / float(bl_max);
    }
    int piece = dovi_select_piece(curve, bl_val);
    if (curve.method[piece] == DOVI_MAPPING_MMR) {
        float scale = float(bl_max);
        return dovi_eval_mmr(curve, mmr, piece,
                             dovi_clamp_mmr_input(poly_y, y_norm, scale),
                             dovi_clamp_mmr_input(poly_cb, u_norm, scale),
                             dovi_clamp_mmr_input(poly_cr, v_norm, scale));
    }
    return dovi_eval_poly(curve, piece, bl_val, bl_max);
}

// Normalised prediction back into VDR code units. Callers pass bl_max + 1, so the
// scale is (bl_max + 1) * vdr_scale = 2^vdr_bit_depth rather than vdr_max, which is
// what makes an identity curve bit-exact end to end.
static inline int dovi_denormalize(float pred_norm, uint bl_max, uint vdr_scale, uint vdr_max) {
    // The prediction is clamped to the VDR range before the residual is added, as DoViBaker does for both
    // the polynomial and the MMR result, so a prediction outside it cannot be pulled back in by the
    // residual: a negative one starts from 0, one above full scale from vdr_max.
    return clamp(int(rint(pred_norm * float(bl_max) * float(vdr_scale))), 0, int(vdr_max));
}

/* ============================================================================
   Inverse NLQ
   ========================================================================= */

// Inverse linear-deadzone quantiser, in VDR code units.
//
// mag_fp is Q(coefficient_log2_denom) of the normalised residual, so the shift
// by nlq_shift = coefficient_log2_denom - vdr_bit_depth lands it in VDR code
// units. That reading is corroborated by the RPUs themselves: both test streams
// carry linear_deadzone_slope = 2048 and vdr_in_max = 0.125 at denom 23, and
// 512 * 2048 >> 11 is exactly 512, i.e. the slope is tuned so the enhancement
// layer's full +/-512 swing lands precisely on vdr_in_max. Shifting by denom
// instead (the convention the vc4 composer uses) collapses every residual to
// zero, and no other shift makes the two fields agree.
//
// The threshold is ADDED to the magnitude, in the same Q(coefficient_log2_denom) domain as
// (|r| - 1/2) * slope, and there is no early zero: that is the spec's pseudo-code, and DoViBaker
// implements it (`dq += T * sign`). Every real stream carries linear_deadzone_threshold == 0 (RPU
// survey, 9,816 RPUs), where all readings agree. Subtracting it, or zeroing anything inside the
// deadzone, would be a different reading and does not match a second implementation.
static inline int dovi_eval_inv_nlq(constant struct DoviNlqParams &nlq, int el_val) {
    if (nlq.nlq_method != DOVI_NLQ_METHOD_LINEAR || nlq.nlq_scale == 0) {
        return 0;
    }
    int r = el_val - nlq.nlq_offset;
    if (r == 0) {
        return 0;
    }
    // Reconstruction at the middle of the quantisation step, (|r| - 1/2) * scale, in doubled fixed
    // point so the half step stays exact.
    long mag_fp = (2L * long(abs(r)) - 1L) * long(nlq.nlq_scale);
    long threshold2 = 2L * long(nlq.nlq_threshold);
    long mag = (mag_fp + threshold2) >> (nlq.nlq_shift + 1u);
    if (nlq.vdr_in_max > 0 && mag > long(nlq.vdr_in_max)) {
        mag = long(nlq.vdr_in_max);
    }
    return (r < 0) ? -int(mag) : int(mag);
}

/* ============================================================================
   Output quantisation
   ========================================================================= */

// Full-precision sample: v/vdr_scale in 10-bit codes with 6 fractional bits, clamped to the
// video-range limits. The top 10 bits are the truncated code; the rest is what P010 leaves unused.
static inline int dovi_full_precision(int vdr_val, uint vdr_scale, int lo, int hi) {
    int v = (vdr_val * 64 + int(vdr_scale >> 1)) / int(vdr_scale);
    return clamp(v, lo << 6, hi << 6);
}

// VDR code value down to the 10-bit output plane, dithered or rounded.
static inline int dovi_quantize(
    int vdr_val,
    uint vdr_scale,
    uint dither_mode,
    float dither,
    int lo,
    int hi)
{
    float v = float(vdr_val) / float(vdr_scale);
    // Both branches have mean 0.5, so enabling dither redistributes the rounding
    // error without moving the average level.
    float bias = (dither_mode == DOVI_DITHER_NONE) ? 0.5f : dither;
    return clamp(int(floor(v + bias)), lo, hi);
}

/* ============================================================================
   Enhancement layer upsampling
   ========================================================================= */

// EL upsampling: one hardware bilinear fetch.
//
// el_spatial_resampling_filter_flag advertises that the encoder used its own
// separable filter, whose taps the RPU does not carry, so no bit-exact inverse
// is available from the stream. Against the DoViBaker oracle on a fine-detail set (gratings, zone plate,
// band-limited noise) a 4-fetch Catmull-Rom bought about 0.7% of per-pixel error sd over bilinear, with chroma
// unchanged, for four times the EL reads. `tex_size` is unused by bilinear; it is
// kept so a wider filter can replace this one without touching the callers.
static inline float dovi_sample_el_1d(
    texture2d<float, access::sample> tex,
    sampler s,
    float2 uv,
    float2 tex_size)
{
    return tex.sample(s, uv).r;
}

static inline float2 dovi_sample_el_2d(
    texture2d<float, access::sample> tex,
    sampler s,
    float2 uv,
    float2 tex_size)
{
    return tex.sample(s, uv).rg;
}

// UNORM [0, 1] from a 10-in-16 MSB-aligned P010 plane back to a code value.
// 65535 / 64 is exact: the hardware divides the stored ushort by 65535, and the
// code value is that ushort >> 6.
constant float dovi_unorm_to_code = 65535.0f / 64.0f;

/* ============================================================================
   Composition kernels
   ========================================================================= */

// Luma: BL luma + reshaping curve + inverse-NLQ residual -> 10-bit P010 plane.
//
// bl_uv_tex is bound only because a luma curve may carry MMR pieces, which need
// all three components. No observed profile 7 stream has an MMR luma curve (libdovi
// would report it as mapping_idc = 1 for component 0), so the DOVI_FLAG_LUMA_MMR gate
// normally skips the fetch entirely. When it does fire, the chroma pair is taken
// nearest-neighbour from the 4:2:0 plane: the reshaping model is defined on 4:4:4
// input, and reconstructing chroma to full resolution here would cost a separate
// pass for a case that does not occur in practice.
kernel void dovi_compose_luma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<float, access::sample>       el_y_tex      [[texture(2)]],
    texture2d<ushort, access::write>       out_y_tex     [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    constant float*                        luma_lut      [[buffer(1)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    if (gid.x >= params.bl_width || gid.y >= params.bl_height) {
        return;
    }

    int bl_y = int(bl_y_tex.read(gid).r >> 6);

    float pred;
    if ((params.flags & DOVI_FLAG_LUMA_MMR) == 0u) {
        pred = luma_lut[bl_y];
    } else {
        float y_norm = float(bl_y) / float(params.bl_max + 1u);
        ushort4 bl_uv = bl_uv_tex.read(uint2(gid.x >> 1, gid.y >> 1));
        float u_norm = float(int(bl_uv.r >> 6)) / float(params.bl_max + 1u);
        float v_norm = float(int(bl_uv.g >> 6)) / float(params.bl_max + 1u);
        pred = dovi_eval_curve(params.poly_y, params.mmr_y,
                               params.poly_y, params.poly_cb, params.poly_cr, bl_y,
                               y_norm, u_norm, v_norm, params.bl_max + 1u);
    }
    int vdr_y = dovi_denormalize(pred, params.bl_max + 1u, params.vdr_scale, params.vdr_max);

    if ((params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u &&
        params.nlq_y.nlq_method == DOVI_NLQ_METHOD_LINEAR &&
        params.nlq_y.nlq_scale != 0) {
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = (float2(gid) + 0.5f) / float2(params.bl_width, params.bl_height);
        float el = dovi_sample_el_1d(el_y_tex, s, uv,
                                     float2(params.el_width, params.el_height)) * dovi_unorm_to_code;
        vdr_y += dovi_eval_inv_nlq(params.nlq_y, int(rint(el)));
    }

    vdr_y = clamp(vdr_y, 0, int(params.vdr_max));

    int out_y = dovi_quantize(vdr_y, params.vdr_scale, params.dither_mode,
                              dovi_dither(gid, params.frame_index, uint2(0u, 0u)), 64, 940);
    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        out_y_tex.write(ushort4(ushort(vdr_y << 4), 0, 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        out_y_tex.write(ushort4(ushort(dovi_full_precision(vdr_y, params.vdr_scale, 64, 940)), 0, 0, 0), gid);
        return;
    }
    out_y_tex.write(ushort4(ushort(out_y << 6), 0, 0, 0), gid);
}

// Chroma: both chroma planes in one pass, since an MMR curve for Cb and for Cr
// reads the same three base-layer components.
kernel void dovi_compose_chroma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<float, access::sample>       el_uv_tex     [[texture(2)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    uint uv_width = params.bl_width / 2u;
    uint uv_height = params.bl_height / 2u;

    if (gid.x >= uv_width || gid.y >= uv_height) {
        return;
    }

    // Base-layer luma at the chroma site, for the cross-component terms: [1 2 1]
    // around the even column in each of the cell's two rows, then the rows
    // averaged, in integers, edges clamped. This is DoViBaker's reading, and
    // Dolby-encoded streams agree with it: on one with order-3 MMR chroma the
    // coded residual matches it at about half the error of the plain vertical
    // 2-tap this kernel used before.
    uint lx = min(gid.x * 2u, params.bl_width - 1u);
    uint lxl = lx > 0u ? lx - 1u : 0u;
    uint lxr = min(lx + 1u, params.bl_width - 1u);
    int bl_y = 0;
    for (uint r = 0u; r < 2u; ++r) {
        uint ly = min(gid.y * 2u + r, params.bl_height - 1u);
        int row = int(bl_y_tex.read(uint2(lxl, ly)).r >> 6)
                + 2 * int(bl_y_tex.read(uint2(lx, ly)).r >> 6)
                + int(bl_y_tex.read(uint2(lxr, ly)).r >> 6);
        bl_y += (row + 2) >> 2;
    }
    bl_y = (bl_y + 1) >> 1;

    ushort4 bl_uv = bl_uv_tex.read(gid);
    int bl_cb = int(bl_uv.r >> 6);
    int bl_cr = int(bl_uv.g >> 6);

    float y_norm = float(bl_y) / float(params.bl_max + 1u);
    float u_norm = float(bl_cb) / float(params.bl_max + 1u);
    float v_norm = float(bl_cr) / float(params.bl_max + 1u);

    float pred_cb = dovi_eval_curve(params.poly_cb, params.mmr_cb,
                                    params.poly_y, params.poly_cb, params.poly_cr, bl_cb,
                                    y_norm, u_norm, v_norm, params.bl_max + 1u);
    float pred_cr = dovi_eval_curve(params.poly_cr, params.mmr_cr,
                                    params.poly_y, params.poly_cb, params.poly_cr, bl_cr,
                                    y_norm, u_norm, v_norm, params.bl_max + 1u);

    int vdr_cb = dovi_denormalize(pred_cb, params.bl_max + 1u, params.vdr_scale, params.vdr_max);
    int vdr_cr = dovi_denormalize(pred_cr, params.bl_max + 1u, params.vdr_scale, params.vdr_max);

    if ((params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u) {
        bool cb_active = (params.nlq_cb.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cb.nlq_scale != 0);
        bool cr_active = (params.nlq_cr.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cr.nlq_scale != 0);
        if (cb_active || cr_active) {
            constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
            // Chroma is co-sited with the top-left luma sample (chroma location type 2, as HDR10 and
            // Dolby Vision streams carry it), so the enhancement chroma grid and the base chroma grid
            // share their first sample rather than their outer edge: base chroma sample n sits at EL
            // chroma texel n * el / bl, and a quarter-resolution EL gives the even samples exactly and
            // the odd ones half way between two texels. This is DoViBaker's phase (`upsampleChromaEven`
            // copies, `upsampleChromaOdd` interpolates at 0.5); a centre-aligned fetch puts every
            // sample a quarter of an EL chroma texel up and to the left. Same-resolution EL is unchanged.
            float2 el_uv_size = float2(params.el_width / 2u, params.el_height / 2u);
            float2 uv = float2(gid) / float2(uv_width, uv_height) + 0.5f / el_uv_size;
            float2 el = dovi_sample_el_2d(el_uv_tex, s, uv, el_uv_size) * dovi_unorm_to_code;
            if (cb_active) {
                vdr_cb += dovi_eval_inv_nlq(params.nlq_cb, int(rint(el.r)));
            }
            if (cr_active) {
                vdr_cr += dovi_eval_inv_nlq(params.nlq_cr, int(rint(el.g)));
            }
        }
    }

    vdr_cb = clamp(vdr_cb, 0, int(params.vdr_max));
    vdr_cr = clamp(vdr_cr, 0, int(params.vdr_max));

    int out_cb = dovi_quantize(vdr_cb, params.vdr_scale, params.dither_mode,
                               dovi_dither(gid, params.frame_index, uint2(1u, 0u)), 64, 960);
    int out_cr = dovi_quantize(vdr_cr, params.vdr_scale, params.dither_mode,
                               dovi_dither(gid, params.frame_index, uint2(1u, 1u)), 64, 960);

    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        out_uv_tex.write(ushort4(ushort(vdr_cb << 4), ushort(vdr_cr << 4), 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        out_uv_tex.write(ushort4(ushort(dovi_full_precision(vdr_cb, params.vdr_scale, 64, 960)),
                                 ushort(dovi_full_precision(vdr_cr, params.vdr_scale, 64, 960)), 0, 0), gid);
        return;
    }
    out_uv_tex.write(ushort4(ushort(out_cb << 6), ushort(out_cr << 6), 0, 0), gid);
}

/* ============================================================================
   Layout probe
   ========================================================================= */

// Reads sentinels back out of the parameter block the host actually uploaded,
// so the Swift serialiser and this shader's struct definitions are checked
// against each other on the GPU rather than by hand. Metal has no static_assert
// and the offline metal compiler is not always installed, so slot 0 carries
// sizeof(DoviMetalParams), slots 1-35 the scalars and the last element of each
// sub-block, and slots 36 onwards, per component, the first element of every array
// and every NLQ scalar: any offset drift or swapped neighbours moves a sentinel
// and the test fails.
kernel void dovi_layout_probe(
    constant struct DoviMetalParams& params [[buffer(0)]],
    device uint*                     out    [[buffer(1)]],
    uint                             tid    [[thread_position_in_grid]])
{
    if (tid != 0u) {
        return;
    }

    out[0] = uint(sizeof(struct DoviMetalParams));

    out[1] = params.bl_width;
    out[2] = params.bl_height;
    out[3] = params.el_width;
    out[4] = params.el_height;
    out[5] = params.target_mode;
    out[6] = params.dither_mode;
    out[7] = params.frame_index;
    out[8] = params.flags;

    out[9]  = params.poly_y.num_pivots;
    out[10] = params.poly_y.pivots[8];
    out[11] = params.poly_y.method[7];
    out[12] = params.poly_y.order[7];
    out[13] = uint(params.poly_y.coef[7][2]);
    out[14] = params.poly_y.coef_shift[7];
    out[15] = uint(params.mmr_y.mmr_constant[7]);
    out[16] = uint(params.mmr_y.coef[7][20]);
    out[17] = params.mmr_y.coef_shift;
    out[18] = uint(params.nlq_y.vdr_in_max);
    out[19] = params.nlq_y.nlq_pivots[1];

    out[20] = params.poly_cb.num_pivots;
    out[21] = params.poly_cb.coef_shift[7];
    out[22] = uint(params.mmr_cb.coef[7][20]);
    out[23] = params.mmr_cb.coef_shift;
    out[24] = params.nlq_cb.nlq_pivots[1];

    out[25] = params.poly_cr.num_pivots;
    out[26] = params.poly_cr.coef_shift[7];
    out[27] = uint(params.mmr_cr.coef[7][20]);
    out[28] = params.mmr_cr.coef_shift;
    out[29] = params.nlq_cr.nlq_pivots[1];

    out[30] = params.min_pq;
    out[31] = params.max_pq;
    out[32] = params.avg_pq;
    out[33] = params.bl_max;
    out[34] = params.vdr_max;
    out[35] = params.vdr_scale;

    // --- y: first element of every array and every NLQ scalar ---
    out[36] = params.poly_y.pivots[0];
    out[37] = params.poly_y.pivots[1];
    out[38] = params.poly_y.method[0];
    out[39] = params.poly_y.order[0];
    out[40] = uint(params.poly_y.coef[0][0]);
    out[41] = uint(params.poly_y.coef[0][1]);
    out[42] = uint(params.poly_y.coef[1][0]);
    out[43] = params.poly_y.coef_shift[0];
    out[44] = uint(params.mmr_y.mmr_constant[0]);
    out[45] = uint(params.mmr_y.coef[0][0]);
    out[46] = uint(params.mmr_y.coef[0][1]);
    out[47] = uint(params.mmr_y.coef[1][0]);
    out[48] = params.nlq_y.nlq_method;
    out[49] = uint(params.nlq_y.nlq_offset);
    out[50] = uint(params.nlq_y.nlq_scale);
    out[51] = uint(params.nlq_y.nlq_threshold);
    out[52] = params.nlq_y.nlq_shift;
    out[53] = uint(params.nlq_y.vdr_in_max);
    out[54] = params.nlq_y.nlq_pivots[0];
    out[55] = params.nlq_y.nlq_pivots[1];
    // --- cb: first element of every array and every NLQ scalar ---
    out[56] = params.poly_cb.pivots[0];
    out[57] = params.poly_cb.pivots[1];
    out[58] = params.poly_cb.method[0];
    out[59] = params.poly_cb.order[0];
    out[60] = uint(params.poly_cb.coef[0][0]);
    out[61] = uint(params.poly_cb.coef[0][1]);
    out[62] = uint(params.poly_cb.coef[1][0]);
    out[63] = params.poly_cb.coef_shift[0];
    out[64] = uint(params.mmr_cb.mmr_constant[0]);
    out[65] = uint(params.mmr_cb.coef[0][0]);
    out[66] = uint(params.mmr_cb.coef[0][1]);
    out[67] = uint(params.mmr_cb.coef[1][0]);
    out[68] = params.nlq_cb.nlq_method;
    out[69] = uint(params.nlq_cb.nlq_offset);
    out[70] = uint(params.nlq_cb.nlq_scale);
    out[71] = uint(params.nlq_cb.nlq_threshold);
    out[72] = params.nlq_cb.nlq_shift;
    out[73] = uint(params.nlq_cb.vdr_in_max);
    out[74] = params.nlq_cb.nlq_pivots[0];
    out[75] = params.nlq_cb.nlq_pivots[1];
    // --- cr: first element of every array and every NLQ scalar ---
    out[76] = params.poly_cr.pivots[0];
    out[77] = params.poly_cr.pivots[1];
    out[78] = params.poly_cr.method[0];
    out[79] = params.poly_cr.order[0];
    out[80] = uint(params.poly_cr.coef[0][0]);
    out[81] = uint(params.poly_cr.coef[0][1]);
    out[82] = uint(params.poly_cr.coef[1][0]);
    out[83] = params.poly_cr.coef_shift[0];
    out[84] = uint(params.mmr_cr.mmr_constant[0]);
    out[85] = uint(params.mmr_cr.coef[0][0]);
    out[86] = uint(params.mmr_cr.coef[0][1]);
    out[87] = uint(params.mmr_cr.coef[1][0]);
    out[88] = params.nlq_cr.nlq_method;
    out[89] = uint(params.nlq_cr.nlq_offset);
    out[90] = uint(params.nlq_cr.nlq_scale);
    out[91] = uint(params.nlq_cr.nlq_threshold);
    out[92] = params.nlq_cr.nlq_shift;
    out[93] = uint(params.nlq_cr.vdr_in_max);
    out[94] = params.nlq_cr.nlq_pivots[0];
    out[95] = params.nlq_cr.nlq_pivots[1];
}
"""

    /// Runtime-compiled form: typedefs, struct block and kernels in one string.
    static var source: String {
        preamble + "\n" + sharedStructs + "\n" + kernels + "\n"
    }
}
#endif
